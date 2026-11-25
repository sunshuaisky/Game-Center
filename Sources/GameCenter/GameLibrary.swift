import Combine
import CoreServices
import Foundation
import ImageIO

@MainActor
final class GameLibrary: ObservableObject {
    @Published private(set) var games: [Game] = []
    @Published private(set) var gameDirectoryPath: String?
    @Published private(set) var isScanning = false
    @Published var errorMessage: String?

    private let fileManager = FileManager.default
    private let metadataService = GameMetadataService(trace: MetadataTraceLog.write)
    private var activeMetadataLookups = Set<UUID>()
    private struct MetadataJob {
        let id: UUID
        let language: String
    }

    private var metadataQueue: [MetadataJob] = []
    private var metadataWorkers = 0
    private var preferredMetadataLanguage = "en"
    private var gameDirectoryURL: URL?
    private var securityScopedDirectoryURL: URL?
    private var directoryEventStream: FSEventStreamRef?
    private var watcherGeneration = 0
    private var pendingScan: Task<Void, Never>?

    init() {
        do {
            games = try Self.loadGames()
        } catch {
            errorMessage = AppLanguage.format("读取游戏资料库失败：%@", error.localizedDescription)
        }
        let selectedLanguage = AppLanguage(
            rawValue: UserDefaults.standard.string(forKey: "appLanguage") ?? AppLanguage.system.rawValue
        ) ?? .system
        preferredMetadataLanguage = selectedLanguage.scrapeLanguage
        restoreGameDirectory()
        refreshMissingMetadata(language: preferredMetadataLanguage)
    }

    func games(matching filter: LibraryFilter, search: String) -> [Game] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return games
            .filter { game in
                switch filter {
                case .all: true
                case .recent: game.lastPlayedAt != nil
                case .favorites: game.isFavorite
                case .platform(let platform): game.platform == platform
                }
            }
            .filter { game in
                query.isEmpty
                    || (game.metadataTitle ?? game.title).localizedCaseInsensitiveContains(query)
                    || game.title.localizedCaseInsensitiveContains(query)
                    || game.platform.shortTitle.localizedCaseInsensitiveContains(query)
            }
            .sorted { lhs, rhs in
                switch filter {
                case .recent:
                    (lhs.lastPlayedAt ?? .distantPast) > (rhs.lastPlayedAt ?? .distantPast)
                default:
                    lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                }
            }
    }

    func count(for platform: GamePlatform) -> Int {
        games.filter { $0.platform == platform }.count
    }

    func resolvedGameURL(for game: Game) -> URL? {
        if let resolved = try? game.resolvedURL(), fileManager.fileExists(atPath: resolved.path) {
            return resolved
        }
        guard let root = gameDirectoryURL else { return nil }

        var stagingCandidates: [URL] = []
        if game.platform == .switchConsole {
            let switchRoot = root.lastPathComponent.lowercased() == "switch"
                ? root
                : (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]))?
                    .first(where: { $0.lastPathComponent.lowercased() == "switch" }) ?? root.appendingPathComponent("switch", isDirectory: true)
            let names = [game.title, game.metadataTitle].compactMap { $0 }.map(Self.safeGameFolderName)
            for name in names {
                let buildRoot = switchRoot.appendingPathComponent("build", isDirectory: true)
                let inputDirectories = [
                    buildRoot.appendingPathComponent("nxnative", isDirectory: true).appendingPathComponent(name, isDirectory: true),
                    buildRoot.appendingPathComponent("S2Arm/inputs", isDirectory: true).appendingPathComponent(name, isDirectory: true)
                ]
                for inputDirectory in inputDirectories {
                    stagingCandidates += (try? fileManager.contentsOfDirectory(at: inputDirectory, includingPropertiesForKeys: nil)) ?? []
                }
            }
        }
        let stagedSource = stagingCandidates.first { Self.isSwitchBuildSource($0) && fileManager.fileExists(atPath: $0.path) }
        let candidates = GameDirectoryScanner.scan(root: root)

        let wanted = Set([game.title, game.metadataTitle].compactMap { $0 }.map(Self.normalizedGameName))
        let source = stagedSource ?? candidates.first { candidate in
            fileManager.fileExists(atPath: candidate.path)
                && GamePlatform.detect(for: candidate, under: root) == game.platform
                && wanted.contains(Self.normalizedGameName(candidate.deletingPathExtension().lastPathComponent))
        }
        guard let source else { return nil }

        let bookmark = (try? source.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? (try? source.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
        if let bookmark, let index = games.firstIndex(where: { $0.id == game.id }) {
            games[index].bookmark = bookmark
            saveChanges()
        }
        return source
    }

    func setGameDirectory(_ url: URL) {
        do {
            let bookmark = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmark, forKey: Self.gameDirectoryBookmarkKey)
            UserDefaults(suiteName: Self.settingsSuiteName)?.set(bookmark, forKey: Self.gameDirectoryBookmarkKey)
            stopWatchingDirectory()
            if let securityScopedDirectoryURL {
                securityScopedDirectoryURL.stopAccessingSecurityScopedResource()
            }
            startWatchingDirectory(url)
        } catch {
            errorMessage = AppLanguage.format("保存游戏文件夹失败：%@", error.localizedDescription)
        }
    }

    func scanGameDirectory(refreshAllMetadata: Bool = false, language: String? = nil) {
        guard let root = gameDirectoryURL else { return }
        pendingScan?.cancel()
        isScanning = true
        pendingScan = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            let urls = await Task.detached(priority: .utility) {
                GameDirectoryScanner.scan(root: root)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.addDiscoveredGames(urls, under: root)
            if refreshAllMetadata {
                let targetLanguage = language ?? self.preferredMetadataLanguage
                self.preferredMetadataLanguage = targetLanguage
                for index in self.games.indices {
                    let currentName = self.games[index].displayTitle
                    if !currentName.isEmpty && self.games[index].title != currentName {
                        self.games[index].title = currentName
                    }
                }
                self.saveChanges()
                // Force full refresh of synopsis, cover artwork, and backdrop for every game.
                let queuedIDs = Set(self.metadataQueue.map(\.id))
                self.metadataQueue.removeAll()
                self.activeMetadataLookups.subtract(queuedIDs)
                for game in self.games {
                    self.refreshMetadata(for: game.id, language: targetLanguage, force: true)
                }
            }
            self.isScanning = false
        }
    }

    func toggleFavorite(for id: UUID) {
        guard let index = games.firstIndex(where: { $0.id == id }) else { return }
        games[index].isFavorite.toggle()
        saveChanges()
    }

    func markPlayed(_ id: UUID) {
        guard let index = games.firstIndex(where: { $0.id == id }) else { return }
        games[index].lastPlayedAt = .now
        saveChanges()
    }

    func registerBuiltGame(at url: URL, replacing id: UUID) {
        guard url.pathExtension.lowercased() == "app",
              fileManager.fileExists(atPath: url.path),
              let index = games.firstIndex(where: { $0.id == id }) else {
            scanGameDirectory()
            return
        }
        do {
            let bookmark: Data
            if let scopedBookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
                bookmark = scopedBookmark
            } else {
                bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            }
            games[index].bookmark = bookmark
            let builtTitle = GameImporter.title(for: url, platform: .switchConsole)
            if !builtTitle.isEmpty { games[index].title = builtTitle }
            saveChanges()
        } catch {
            errorMessage = AppLanguage.format("保存构建结果失败：%@", error.localizedDescription)
        }
        scanGameDirectory()
    }

    func setArtwork(from url: URL, for id: UUID) {
        guard let index = games.firstIndex(where: { $0.id == id }) else { return }
        do {
            games[index].artworkBookmark = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            saveChanges()
        } catch {
            errorMessage = AppLanguage.format("设置封面失败：%@", error.localizedDescription)
        }
    }

    func refreshMetadata(for id: UUID, language: String, force: Bool = true) {
        guard !activeMetadataLookups.contains(id),
              let index = games.firstIndex(where: { $0.id == id }) else { return }
        if !force, !needsMetadataRefresh(games[index], language: language) { return }

        activeMetadataLookups.insert(id)
        games[index].metadataStatus = "searching"
        saveChanges()
        metadataQueue.append(MetadataJob(id: id, language: language))
        processMetadataQueue()
    }

    func refreshMissingMetadata(language: String) {
        preferredMetadataLanguage = language
        if UserDefaults.standard.integer(forKey: "metadataMatchingVersion") < 11 {
            UserDefaults.standard.set(11, forKey: "metadataMatchingVersion")
            games.forEach { refreshMetadata(for: $0.id, language: language, force: true) }
        }
        let switch2MetadataVersionKey = "switch2MetadataVersion"
        if UserDefaults.standard.integer(forKey: switch2MetadataVersionKey) < 5 {
            UserDefaults.standard.set(5, forKey: switch2MetadataVersionKey)
            games.filter { $0.platform == .switchConsole }.forEach {
                refreshMetadata(for: $0.id, language: language, force: true)
            }
        }
        let artworkQualityKey = "artworkQualityVersion"
        if UserDefaults.standard.integer(forKey: artworkQualityKey) < 15 {
            UserDefaults.standard.set(15, forKey: artworkQualityKey)
            games.forEach { refreshMetadata(for: $0.id, language: language, force: true) }
            return
        }
        games.filter { needsMetadataRefresh($0, language: language) }
            .forEach { refreshMetadata(for: $0.id, language: language, force: false) }
    }

    private func needsMetadataRefresh(_ game: Game, language: String) -> Bool {
        func exists(_ path: String?) -> Bool { path.map { fileManager.fileExists(atPath: $0) } ?? false }
        return MetadataRefreshPolicy.needsRefresh(status: game.metadataStatus, savedLanguage: game.metadataLanguage, language: language,
            hasSynopsis: game.synopsis?.isEmpty == false, hasArtwork: exists(game.metadataArtworkPath),
            hasBackdrop: exists(game.metadataBackdropPath), updated: game.metadataLastUpdated)
    }

    private func processMetadataQueue() {
        while metadataWorkers < 2, !metadataQueue.isEmpty {
            metadataWorkers += 1
            Task { [self] in
                defer { metadataWorkers -= 1; processMetadataQueue() }
                while !metadataQueue.isEmpty {
                    let job = metadataQueue.removeFirst()
                    guard let game = games.first(where: { $0.id == job.id }) else {
                        activeMetadataLookups.remove(job.id)
                        continue
                    }
                    let result = await metadataService.lookup(
                        title: game.displayTitle,
                        platform: GameMetadataPlatform(rawValue: game.platform.rawValue)!,
                        language: job.language,
                        sourceURL: try? game.resolvedURL(),
                        onText: { partial in await self.applyText(partial, to: job.id, language: job.language) },
                        onBackdrop: { data in await self.applyBackdrop(data, to: job.id, language: job.language) }
                    )
                    apply(result, to: job.id, language: job.language)
                    if preferredMetadataLanguage != job.language {
                        refreshMetadata(for: job.id, language: preferredMetadataLanguage, force: false)
                    }
                }
            }
        }
    }

    private func applyBackdrop(_ data: Data, to id: UUID, language: String) {
        guard preferredMetadataLanguage == language, let index = games.firstIndex(where: { $0.id == id }) else { return }
        let url = artworkDirectory.appendingPathComponent(id.uuidString + "-backdrop.jpg")
        do {
            try fileManager.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            games[index].metadataBackdropPath = url.path
            games[index].metadataLastUpdated = .now
            saveChanges()
        } catch { errorMessage = "保存游戏背景图失败：" + error.localizedDescription }
    }

    private func applyText(_ result: GameMetadataResult, to id: UUID, language: String) {
        guard preferredMetadataLanguage == language, let index = games.firstIndex(where: { $0.id == id }) else { return }
        if let title = result.title { games[index].metadataTitle = title }
        if let synopsis = result.synopsis { games[index].synopsis = synopsis }
        if let source = result.metadataSourceURL { games[index].metadataSourceURL = source }
        // Keep the lookup active while artwork finishes; persist the text now
        // so a slow cover server cannot hide a successfully identified game.
        saveChanges()
    }

    private func apply(_ result: GameMetadataResult, to id: UUID, language: String) {
        defer { activeMetadataLookups.remove(id) }
        guard let index = games.firstIndex(where: { $0.id == id }) else { return }
        if let metadataTitle = result.title { games[index].metadataTitle = metadataTitle }
        if let synopsis = result.synopsis { games[index].synopsis = synopsis }
        if let source = result.metadataSourceURL { games[index].metadataSourceURL = source }
        if let artworkSource = result.artworkSourceURL { games[index].artworkSourceURL = artworkSource }

        if let artworkData = result.artworkData {
            let requestedExtension = result.artworkExtension?.lowercased() ?? ""
            let fileExtension = ["png", "jpg", "jpeg", "webp"].contains(requestedExtension)
                ? requestedExtension
                : "png"
            let artworkURL = artworkDirectory
                .appendingPathComponent(id.uuidString)
                .appendingPathExtension(fileExtension)
            do {
                try fileManager.createDirectory(
                    at: artworkDirectory,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
                try artworkData.write(to: artworkURL, options: .atomic)
                games[index].metadataArtworkPath = artworkURL.path
            } catch {
                if games[index].synopsis == nil { games[index].metadataStatus = "error" }
            }
        }

        if let backdropData = result.backdropData {
            let backdropURL = artworkDirectory
                .appendingPathComponent(id.uuidString + "-backdrop")
                .appendingPathExtension("jpg")
            do {
                try fileManager.createDirectory(
                    at: artworkDirectory,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
                try backdropData.write(to: backdropURL, options: .atomic)
                games[index].metadataBackdropPath = backdropURL.path
            } catch {
                if games[index].synopsis == nil { games[index].metadataStatus = "error" }
            }
        } else if let existingBackdrop = games[index].metadataBackdropPath {
            // Clear stale low-res (< 960x540) backdrop so GameArtwork falls back to softly blurred HD box art.
            let isTooSmall: Bool = {
                let url = URL(fileURLWithPath: existingBackdrop)
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let w = props[kCGImagePropertyPixelWidth] as? Int,
                      let h = props[kCGImagePropertyPixelHeight] as? Int else { return true }
                return w < 960 || h < 540
            }()
            if isTooSmall {
                try? fileManager.removeItem(atPath: existingBackdrop)
                games[index].metadataBackdropPath = nil
            }
        }

        games[index].metadataStatus = result.hasMetadata || games[index].synopsis != nil
            ? "found"
            : "notFound"
        games[index].metadataLastUpdated = .now
        games[index].metadataLanguage = language
        saveChanges()
    }

    func remove(_ id: UUID) {
        games.removeAll { $0.id == id }
        saveChanges()
    }

    private static var libraryURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("Game Center", isDirectory: true)
            .appendingPathComponent("library.json")
    }

    private static let gameDirectoryBookmarkKey = "gameDirectoryBookmark"
    private static let settingsSuiteName = "com.phoenixicarus.gamecenter"

    private var artworkDirectory: URL {
        Self.libraryURL.deletingLastPathComponent().appendingPathComponent("Artwork", isDirectory: true)
    }

    private static func loadGames() throws -> [Game] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: libraryURL.path) else { return [] }
        let data = try Data(contentsOf: libraryURL)
        return try JSONDecoder().decode([Game].self, from: data)
    }

    static func savedSwitchCatalog() throws -> [MobileLibraryFormat.SwitchEntry] {
        try MobileAppBuilder.switchCatalog(loadGames()) { try? $0.resolvedURL() }
    }

    func switchCatalog() -> [MobileLibraryFormat.SwitchEntry] {
        MobileAppBuilder.switchCatalog(games, resolve: resolvedGameURL)
    }

    private func saveChanges() {
        do {
            try saveGames()
        } catch {
            errorMessage = AppLanguage.format("保存游戏资料库失败：%@", error.localizedDescription)
        }
    }

    private func saveGames() throws {
        let directory = Self.libraryURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(games).write(to: Self.libraryURL, options: .atomic)
    }

    private func restoreGameDirectory() {
        guard let bookmark = UserDefaults.standard.data(forKey: Self.gameDirectoryBookmarkKey)
                ?? UserDefaults(suiteName: Self.settingsSuiteName)?.data(forKey: Self.gameDirectoryBookmarkKey) else { return }
        do {
            var isStale = false
            let url: URL
            do {
                url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &isStale)
            } catch {
                url = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale)
            }
            if isStale {
                let refreshed: Data
                if let scoped = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
                    refreshed = scoped
                } else {
                    refreshed = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
                }
                UserDefaults.standard.set(refreshed, forKey: Self.gameDirectoryBookmarkKey)
                UserDefaults(suiteName: Self.settingsSuiteName)?.set(refreshed, forKey: Self.gameDirectoryBookmarkKey)
            }
            startWatchingDirectory(url)
        } catch {
            errorMessage = AppLanguage.format("无法访问游戏文件夹：%@", error.localizedDescription)
        }
    }

    private func startWatchingDirectory(_ url: URL) {
        _ = url.startAccessingSecurityScopedResource()
        securityScopedDirectoryURL = url
        gameDirectoryURL = url
        gameDirectoryPath = url.path
        do { try MacGameSaveStorage.createLayout(root: url.lastPathComponent.lowercased() == "switch" ? url.deletingLastPathComponent() : url) }
        catch { NSLog("Cannot create save folders: %@", error.localizedDescription) }
        watcherGeneration += 1
        let generation = watcherGeneration
        let infoAddress = UInt(bitPattern: Unmanaged.passUnretained(self).toOpaque())
        let watchedPath = url.path

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let paths = [watchedPath] as CFArray
            var context = FSEventStreamContext(
                version: 0,
                info: UnsafeMutableRawPointer(bitPattern: infoAddress),
                retain: nil,
                release: nil,
                copyDescription: nil
            )
            let stream = FSEventStreamCreate(
                kCFAllocatorDefault,
                { _, info, _, _, _, _ in
                    guard let info else { return }
                    let library = Unmanaged<GameLibrary>.fromOpaque(info).takeUnretainedValue()
                    Task { @MainActor in library.scanGameDirectory() }
                },
                &context,
                paths,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                0.6,
                FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer)
            )
            guard let stream else { return }
            FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
            guard FSEventStreamStart(stream) else {
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                return
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.watcherGeneration == generation else {
                    FSEventStreamStop(stream)
                    FSEventStreamInvalidate(stream)
                    FSEventStreamRelease(stream)
                    return
                }
                self.directoryEventStream = stream
            }
        }
        scanGameDirectory()
    }

    private func stopWatchingDirectory() {
        watcherGeneration += 1
        if let directoryEventStream {
            FSEventStreamStop(directoryEventStream)
            FSEventStreamInvalidate(directoryEventStream)
            FSEventStreamRelease(directoryEventStream)
            self.directoryEventStream = nil
        }
        pendingScan?.cancel()
        pendingScan = nil
        isScanning = false
    }

    private func addDiscoveredGames(_ urls: [URL], under root: URL) {
        guard fileManager.isReadableFile(atPath: root.path) else { return }
        let shadowedPackages = GameDirectoryScanner.switchPackagesShadowedByApps(in: urls, under: root)
        let candidates = GameDirectoryScanner.uniqueCandidates(
            urls.filter { !shadowedPackages.contains(GameDirectoryScanner.canonicalPath($0)) },
            under: root
        )
        let discoveredPaths = Set(candidates.map(GameDirectoryScanner.canonicalPath))
        let switchCandidatesByID = Dictionary(
            candidates.compactMap { url -> (String, URL)? in
                guard GamePlatform.detect(for: url, under: root) == .switchConsole,
                      let id = GameDirectoryScanner.switchTitleID(url) else { return nil }
                return (id, url)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let rootPath = GameDirectoryScanner.canonicalPath(root)
        let previousGames = games
        var reconciled: [Game] = []
        var unresolvedGames: [Game] = []
        var retainedPaths = Set<String>()

        func merge(_ source: Game, into target: inout Game) {
            target.isFavorite = target.isFavorite || source.isFavorite
            if (source.lastPlayedAt ?? .distantPast) > (target.lastPlayedAt ?? .distantPast) {
                target.lastPlayedAt = source.lastPlayedAt
            }
            if target.synopsis == nil { target.synopsis = source.synopsis }
            if target.metadataTitle == nil { target.metadataTitle = source.metadataTitle }
            if target.metadataSourceURL == nil { target.metadataSourceURL = source.metadataSourceURL }
            if target.metadataArtworkPath == nil { target.metadataArtworkPath = source.metadataArtworkPath }
            if target.metadataBackdropPath == nil { target.metadataBackdropPath = source.metadataBackdropPath }
        }

        for var game in games {
            guard let url = try? game.resolvedURL() else {
                unresolvedGames.append(game)
                continue
            }
            var path = GameDirectoryScanner.canonicalPath(url)
            let isInsideScannedRoot = path == rootPath || path.hasPrefix(rootPath + "/")
            if isInsideScannedRoot && !discoveredPaths.contains(path) {
                guard game.platform == .switchConsole,
                      let titleID = GameDirectoryScanner.switchTitleID(url),
                      let replacement = switchCandidatesByID[titleID],
                      let replacementBookmark = try? replacement.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) else {
                    continue
                }
                game.bookmark = replacementBookmark
                path = GameDirectoryScanner.canonicalPath(replacement)
                if game.title.count >= 16 && game.title.range(of: #"^[0-9a-fA-F]{16}$"#, options: .regularExpression) != nil {
                    game.title = GameImporter.title(for: replacement, platform: .switchConsole)
                }
            }
            guard retainedPaths.insert(path).inserted else {
                if let index = reconciled.firstIndex(where: { (try? $0.resolvedURL()).map(GameDirectoryScanner.canonicalPath) == path }) {
                    merge(game, into: &reconciled[index])
                }
                continue
            }
            reconciled.append(game)
        }

        for game in unresolvedGames {
            let names = Set([game.metadataTitle, game.title].compactMap { $0 }.map(Self.normalizedGameName).filter { !$0.isEmpty })
            if let index = reconciled.firstIndex(where: { existing in
                guard existing.platform == game.platform else { return false }
                let existingNames = Set([existing.metadataTitle, existing.title].compactMap { $0 }.map(Self.normalizedGameName).filter { !$0.isEmpty })
                return !names.isDisjoint(with: existingNames)
            }) {
                merge(game, into: &reconciled[index])
            }
            // A configured folder is the source of truth. Do not keep stale
            // bookmarks for games that are no longer among its scan results.
            // This also removes legacy Switch build-input cards after their
            // corresponding runnable .app has been discovered and merged.
        }
        games = reconciled
        let knownPaths = Set(games.compactMap { try? $0.resolvedURL() }.map(GameDirectoryScanner.canonicalPath))
        let newURLs = candidates.filter { !knownPaths.contains(GameDirectoryScanner.canonicalPath($0)) }
        guard !newURLs.isEmpty else {
            if games != previousGames { saveChanges() }
            return
        }

        var discoveredIDs: [UUID] = []
        for url in newURLs {
            guard let platform = GamePlatform.detect(for: url, under: root) else { continue }
            do {
                let bookmark = try url.bookmarkData(
                    options: [.withSecurityScope],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                let game = Game(title: GameImporter.title(for: url, platform: platform), platform: platform, bookmark: bookmark)
                games.append(game)
                discoveredIDs.append(game.id)
            } catch {
                errorMessage = AppLanguage.format("无法读取游戏文件：%@", error.localizedDescription)
            }
        }
        saveChanges()
        discoveredIDs.forEach { refreshMetadata(for: $0, language: preferredMetadataLanguage) }
    }

    private static func safeGameFolderName(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\0")
        let name = value.components(separatedBy: invalid).filter { !$0.isEmpty }.joined(separator: "-")
        return name.isEmpty ? "Switch Game" : name
    }

    private static func normalizedGameName(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .filter { $0.isLetter || $0.isNumber }
    }

    private static func isSwitchBuildSource(_ url: URL) -> Bool {
        ["nsp", "xci", "nsz", "xcz", "nup"].contains(url.pathExtension.lowercased())
    }

    private static func hasSwitch2NUPSource(_ game: Game) -> Bool {
        guard game.platform == .switchConsole, let url = try? game.resolvedURL() else { return false }
        if url.pathExtension.lowercased() == "nup" { return true }
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
              let children = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return false }
        return children.contains { $0.pathExtension.lowercased() == "nup" }
    }
}

enum GameDirectoryScanner {
    private static let switchPackageExtensions: Set<String> = ["nsp", "xci", "nsz", "xcz", "nup", "nro", "nso", "nca"]

    static func switchPackagesShadowedByApps(in urls: [URL], under root: URL) -> Set<String> {
        let switchApps = urls.filter { url in
            guard url.pathExtension.lowercased() == "app",
                  GamePlatform.detect(for: url, under: root) == .switchConsole else { return false }
            return true
        }
        let switchAppIDs = Set(switchApps.compactMap(switchTitleID))
        let switchAppNames = Set(switchApps.map(switchComparableName).filter { !$0.isEmpty })
        return Set(urls.compactMap { url -> String? in
            let isBuildSource = switchPackageExtensions.contains(url.pathExtension.lowercased())
                || GamePlatform.isSwitch2DumpFolder(url)
            guard isBuildSource else { return nil }
            if switchTitleID(url).map(switchAppIDs.contains) == true
                || switchAppNames.contains(switchComparableName(url)) {
                return canonicalPath(url)
            }
            return nil
        })
    }

    private static func switchComparableName(_ url: URL) -> String {
        let extensionName = url.pathExtension.lowercased()
        var name = (switchPackageExtensions.contains(extensionName) || extensionName == "app")
            ? url.deletingPathExtension().lastPathComponent
            : url.lastPathComponent
        for pattern in [#"\[[^\]]*\]"#, #"\([^)]*\)"#] {
            name = name.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .filter { $0.isLetter || $0.isNumber }
    }

    static func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    static func uniqueCandidates(_ urls: [URL], under root: URL) -> [URL] {
        var byPath: [String: URL] = [:]
        for url in urls {
            byPath[canonicalPath(url)] = url
        }
        let pathUnique = Array(byPath.values)
        let switchCandidates = pathUnique.filter { GamePlatform.detect(for: $0, under: root) == .switchConsole }
        let otherCandidates = pathUnique.filter { GamePlatform.detect(for: $0, under: root) != .switchConsole }
        var bestByTitleID: [String: URL] = [:]
        for url in switchCandidates {
            guard let id = switchTitleID(url) else { continue }
            if let current = bestByTitleID[id], switchPriority(current) <= switchPriority(url) { continue }
            bestByTitleID[id] = url
        }
        let deduplicatedSwitchIDs = Set(bestByTitleID.values.map(canonicalPath))
        let switchWithoutIDs = switchCandidates.filter { switchTitleID($0) == nil }
        return (otherCandidates + switchWithoutIDs + Array(bestByTitleID.values))
            .sorted { canonicalPath($0).localizedStandardCompare(canonicalPath($1)) == .orderedAscending }
            .filter { GamePlatform.detect(for: $0, under: root) != .switchConsole || deduplicatedSwitchIDs.contains(canonicalPath($0)) || switchTitleID($0) == nil }
    }

    private static func switchPriority(_ url: URL) -> Int {
        switch url.pathExtension.lowercased() {
        case "app": 0
        case "xci", "xcz": 1
        case "nsp", "nsz": 2
        default: 3
        }
    }

    static func switchTitleID(_ url: URL) -> String? {
        if let match = url.lastPathComponent.range(of: #"[0-9a-fA-F]{16}"#, options: .regularExpression) {
            return String(url.lastPathComponent[match]).uppercased()
        }
        if url.pathExtension.lowercased() == "app" {
            let manifest = url.appendingPathComponent("Contents/Resources/S2ArmStandalone/standalone.json")
            if let data = try? Data(contentsOf: manifest),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let id = object["gameID"] as? String {
                return id.uppercased()
            }
            if let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier,
               let match = identifier.range(of: #"[0-9a-fA-F]{16}"#, options: .regularExpression) {
                return String(identifier[match]).uppercased()
            }
        }
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
           let data = try? Data(contentsOf: url.appendingPathComponent("game.json")),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let id = object["id"] as? String {
            return id.uppercased()
        }
        return nil
    }

    static func scan(root: URL) -> [URL] {
        var results: [URL] = []
        var pendingDirectories = [root]
        var visitedDirectories = Set<String>()

        while let directory = pendingDirectories.popLast() {
            let directoryPath = directory.standardizedFileURL.path
            guard visitedDirectories.insert(directoryPath).inserted,
                  let children = try? FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles]
                  ) else { continue }

            for url in children {
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                let fileExtension = url.pathExtension.lowercased()
                if fileExtension == "app", values?.isDirectory == true,
                   GamePlatform.detect(for: url, under: root) != nil {
                    results.append(url)
                    continue
                }

                guard values?.isSymbolicLink != true else { continue }
                if values?.isDirectory == true {
                    if ["build", "runtime", "ios"].contains(url.lastPathComponent.lowercased()),
                       url.deletingLastPathComponent().lastPathComponent.lowercased() == "switch" {
                        continue
                    }
                    if directory.standardizedFileURL.path == root.standardizedFileURL.path && url.lastPathComponent.lowercased() == "save" { continue }
                    if let platform = GamePlatform.detect(for: url, under: root), GamePlatform.macSystems[platform] != nil {
                        results.append(url)
                        continue
                    }
                    if GamePlatform.detect(for: url, under: root) == .switchConsole && GamePlatform.isSwitch2DumpFolder(url) {
                        results.append(url)
                    } else {
                        pendingDirectories.append(url)
                    }
                } else if GamePlatform.detect(for: url, under: root) != nil {
                    results.append(url)
                }
            }
        }
        let shadowedPackages = switchPackagesShadowedByApps(in: results, under: root)
        return MobileLibraryFormat.playableEntries(results.filter { !shadowedPackages.contains($0.standardizedFileURL.path) })
    }
}

/// Scraping diagnosis log: the requests and verdicts behind every lookup, in
/// ~/Library/Logs/GameCenter-metadata.log. One file per launch, capped.
private enum MetadataTraceLog {
    private static let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/GameCenter-metadata.log")
    private static let queue = DispatchQueue(label: "GameCenter.MetadataTrace")
    private static var opened = false
    private static var bytes = 0

    static func write(_ message: String) {
        queue.async {
            if !opened {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? Data().write(to: url, options: .atomic)
                opened = true
            }
            guard bytes < 1_000_000,
                  let line = (ISO8601DateFormatter().string(from: .now) + " " + message + "\n").data(using: .utf8),
                  let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
            bytes += line.count
        }
    }
}
