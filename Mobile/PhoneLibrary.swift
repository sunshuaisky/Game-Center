#if canImport(GameCenterSaveSupport)
import GameCenterSaveSupport
#endif
import Foundation
import CryptoKit

struct PhoneLibrary {
    typealias Format = MobileLibraryFormat
    let documents: URL
    let platforms: [Format.Platform]

    struct ROM: Identifiable {
        let url: URL
        let platform: Format.Platform
        var id: URL { url }
        var title: String {
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        }
    }

    struct SwitchGame: Identifiable {
        let id: String
        let title: String
        let builds: [Format.SwitchBuild]
        var coverName: String? = nil
        var status: String {
            builds.isEmpty ? "未导入 iOS 构建包" : "已导入 · \(builds.map(\.engine.rawValue).joined(separator: " / "))"
        }
    }

    static func open() throws -> Self {
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        guard let config = Bundle.main.url(forResource: "platforms", withExtension: "json") else { throw Error.missingConfiguration }
        let library = try Self(documents: documents, platforms: Format.read([Format.Platform].self, at: config))
        try library.createFolders()
        try library.writeSigningReceipt()
        return library
    }

    var root: URL { documents.appendingPathComponent(Format.library, isDirectory: true) }
    var switchRoot: URL { root.appendingPathComponent("switch", isDirectory: true) }
    var bios: URL { documents.appendingPathComponent("BIOS", isDirectory: true) }

    /// Bundled BIOS and system files for a platform, as the app carries them.
    static func coreAssets(folder: String) -> URL? {
        let base = Bundle.main.bundleURL.appendingPathComponent("CoreAssets", isDirectory: true)
        let exact = base.appendingPathComponent(folder, isDirectory: true)
        if FileManager.default.fileExists(atPath: exact.path) { return exact }
        if let entries = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles),
           let match = entries.first(where: { $0.lastPathComponent.caseInsensitiveCompare(folder) == .orderedSame }) {
            return match
        }
        return nil
    }

    /// Fills `destination` with whatever it is missing from `source` and
    /// reports how many files were written. Existing files — including ones
    /// the user placed by hand — are never replaced.
    @discardableResult
    static func mergeTree(from source: URL, into destination: URL) -> Int {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey]) else { return 0 }
        var written = 0
        for item in items {
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            let target = destination.appendingPathComponent(item.lastPathComponent, isDirectory: isDirectory)
            if isDirectory {
                guard fm.fileExists(atPath: target.path)
                    || (try? fm.createDirectory(at: target, withIntermediateDirectories: true)) != nil else { continue }
                written += mergeTree(from: item, into: target)
            } else if !fm.fileExists(atPath: target.path), (try? fm.copyItem(at: item, to: target)) != nil {
                written += 1
            }
        }
        return written
    }

    /// One writer per BIOS/<platform>: a game that starts while the launch-time
    /// install is still copying waits here instead of reading a half-written file.
    private static let systemFilesQueue = DispatchQueue(label: "GameCenter.SystemFiles")

    /// Installs the BIOS and firmware bundled for `platform` into BIOS/<platform>,
    /// the folder its core reads and the one visible in the Files app.
    @discardableResult
    func seedSystemFiles(for platform: Format.Platform) -> Int {
        guard let source = Self.coreAssets(folder: platform.folder) else { return 0 }
        return Self.systemFilesQueue.sync {
            Self.mergeTree(from: source, into: bios.appendingPathComponent(platform.folder, isDirectory: true))
        }
    }

    /// Puts the bundled BIOS and firmware in place as soon as the app opens, so
    /// they are there from the first launch rather than appearing only once a
    /// game of that platform is started.
    func installBundledSystemFiles() {
        let all = platforms
        DispatchQueue.global(qos: .utility).async {
            for platform in all { self.seedSystemFiles(for: platform) }
        }
    }

    // A public receipt lets the paired Mac match the actual installed app and
    // the certificates authorized by its profile, without collecting passwords.
    private func writeSigningReceipt() throws {
        var receipt: [String: Any] = ["schema": 1, "bundleIdentifier": Bundle.main.bundleIdentifier ?? ""]
        if let profile = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
           let data = try? Data(contentsOf: profile),
           let start = data.range(of: Data("<?xml".utf8)),
           let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
           let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], format: nil) as? [String: Any] {
            if let team = (plist["TeamIdentifier"] as? [String])?.first { receipt["teamIdentifier"] = team }
            if let expiry = plist["ExpirationDate"] as? Date { receipt["profileExpiry"] = expiry.timeIntervalSince1970 }
            if let certificates = plist["DeveloperCertificates"] as? [Data] {
                receipt["certificateFingerprints"] = certificates.map { Insecure.SHA1.hash(data: $0).map { String(format: "%02X", $0) }.joined() }
            }
        }
        try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]).write(to: documents.appendingPathComponent("Export/GameCenter-signing.json"), options: .atomic)
    }

    func cloudSaveSlots() throws -> [CloudSaveSlot] {
        try migrateSwitchSaves()
        var result = switchGames().compactMap { game -> CloudSaveSlot? in
            guard let build = game.builds.first else { return nil }
            return .init(id: "switch/\(build.titleID)", title: game.title,
                         location: GameSaveLayout.folder(root: root, platform: "switch", game: build.titleID))
        }
        for rom in roms() where ["gb", "gbc", "gba"].contains(rom.platform.id) {
            result.append(.init(id: "rom/\(rom.platform.id)/" + rom.title.lowercased(), title: rom.title,
                                location: saveFolder(rom).appendingPathComponent("battery.srm"), fileName: "battery.srm"))
        }
        return result.sorted { $0.title < $1.title }
    }

    func romFolder(_ platform: Format.Platform) -> URL {
        root.appendingPathComponent(platform.folder, isDirectory: true)
    }

    func saveFolder(_ rom: ROM) -> URL {
        GameSaveLayout.folder(root: root, platform: rom.platform.id, game: rom.title)
    }

    private static func isSameItem(_ a: URL, _ b: URL) -> Bool {
        guard let idA = try? a.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier,
              let idB = try? b.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier else {
            return false
        }
        return idA.isEqual(idB)
    }

    private static func moveFolderContents(from legacy: URL, to target: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacy.path) else { return }
        if isSameItem(legacy, target) {
            if legacy.lastPathComponent != target.lastPathComponent {
                let tmp = legacy.deletingLastPathComponent().appendingPathComponent(".rename-\(UUID().uuidString)", isDirectory: true)
                if (try? fm.moveItem(at: legacy, to: tmp)) != nil {
                    try? fm.moveItem(at: tmp, to: target)
                }
            }
            return
        }
        try? fm.createDirectory(at: target, withIntermediateDirectories: true)
        if let items = try? fm.contentsOfDirectory(at: legacy, includingPropertiesForKeys: [.isDirectoryKey]) {
            for item in items {
                let dest = target.appendingPathComponent(item.lastPathComponent)
                if !fm.fileExists(atPath: dest.path) {
                    try? fm.moveItem(at: item, to: dest)
                } else {
                    let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                    if isDir {
                        moveFolderContents(from: item, to: dest)
                    }
                }
            }
        }
        if ((try? fm.contentsOfDirectory(atPath: legacy.path)) ?? []).isEmpty {
            try? fm.removeItem(at: legacy)
        }
    }

    private func migrateLegacyDirectories() {
        let fm = FileManager.default
        // Migrate legacy GameLibrary/Switch -> GameLibrary/switch
        Self.moveFolderContents(from: root.appendingPathComponent("Switch", isDirectory: true), to: switchRoot)
        // Migrate legacy GameLibrary/ROMs/<Folder> -> GameLibrary/<mac_lowercase_folder>
        let legacyROMs = root.appendingPathComponent("ROMs", isDirectory: true)
        if let entries = try? fm.contentsOfDirectory(at: legacyROMs, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles) {
            for entry in entries {
                if let platform = platforms.first(where: { $0.folder.caseInsensitiveCompare(entry.lastPathComponent) == .orderedSame }) {
                    Self.moveFolderContents(from: entry, to: romFolder(platform))
                }
            }
            if ((try? fm.contentsOfDirectory(atPath: legacyROMs.path)) ?? []).isEmpty {
                try? fm.removeItem(at: legacyROMs)
            }
        }
        // Migrate legacy uppercase BIOS/<Folder> -> BIOS/<mac_lowercase_folder>
        if let entries = try? fm.contentsOfDirectory(at: bios, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles) {
            for entry in entries {
                if let platform = platforms.first(where: { $0.folder.caseInsensitiveCompare(entry.lastPathComponent) == .orderedSame }),
                   entry.lastPathComponent != platform.folder {
                    Self.moveFolderContents(from: entry, to: bios.appendingPathComponent(platform.folder, isDirectory: true))
                }
            }
        }
    }

    func createFolders() throws {
        try GameSaveLayout.evacuateSwitchCaches(saveRoot: root.appendingPathComponent("save"), cache: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("GameCenter/SaveRepair"))
        migrateLegacyDirectories()
        let fm = FileManager.default
        for folder in [switchRoot, GameSaveLayout.folder(root: root, platform: "switch"), documents.appendingPathComponent("Export")] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        for rom in roms() {
            let relative = rom.url.pathComponents.dropFirst(romFolder(rom.platform).pathComponents.count)
            let old = relative.reduce(documents.appendingPathComponent("Saves/\(rom.platform.folder)")) { $0.appendingPathComponent($1) }
            try GameSaveLayout.migrate(old, to: saveFolder(rom), saveRoot: root.appendingPathComponent("save"))
        }
        try migrateSwitchSaves()
        for platform in platforms {
            for folder in [romFolder(platform), bios.appendingPathComponent(platform.folder),
                           GameSaveLayout.folder(root: root, platform: platform.id)] {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            }
        }
        installBundledSystemFiles()
    }

    func migrateSwitchSaves() throws {
        let fm = FileManager.default
        let saveRoot = root.appendingPathComponent("save")
        for title in children(switchRoot) where Format.isTitleID(title.lastPathComponent) {
            let target = GameSaveLayout.folder(root: root, platform: "switch", game: title.lastPathComponent)
            try GameSaveLayout.migrate(title.appendingPathComponent("UserData/S2Arm/SaveData"), to: target, saveRoot: saveRoot)
            try GameSaveLayout.migrate(title.appendingPathComponent("UserData/NXNative/Saves"), to: target.appendingPathComponent("save"), saveRoot: saveRoot)
            try GameSaveLayout.migrate(title.appendingPathComponent("UserData/NXNative/Saves_device"), to: target.appendingPathComponent("save_device"), saveRoot: saveRoot)
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
        }
    }

    func roms() -> [ROM] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey]
        return platforms.flatMap { platform -> [ROM] in
            guard let files = FileManager.default.enumerator(at: romFolder(platform), includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
            let candidates: [ROM] = files.compactMap { item in
                guard let file = item as? URL,
                      let values = try? file.resourceValues(forKeys: Set(keys)),
                      values.isSymbolicLink != true else { return nil }
                if values.isDirectory == true {
                    guard Format.isGameFolder(file, runtime: platform.runtime) else { return nil }
                    files.skipDescendants()
                    return ROM(url: file, platform: platform)
                }
                guard values.isRegularFile == true,
                      platform.extensions.contains(file.pathExtension.lowercased()) else { return nil }
                return ROM(url: file, platform: platform)
            }
            let playable = Set(Format.playableEntries(candidates.map(\.url)))
            return candidates.filter { playable.contains($0.url) }
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func switchGames() -> [SwitchGame] {
        let local = switchRoot.appendingPathComponent(Format.catalog)
        let catalog = (try? Format.read([Format.SwitchEntry].self, at: local))
            ?? Bundle.main.url(forResource: "catalog", withExtension: "json").flatMap { try? Format.read([Format.SwitchEntry].self, at: $0) }
            ?? []
        let installed = children(switchRoot).filter { Format.isTitleID($0.lastPathComponent) }
            .reduce(into: [String: [Format.SwitchBuild]]()) { result, folder in
                let id = folder.lastPathComponent
                let builds = Format.Engine.allCases.compactMap { engine -> Format.SwitchBuild? in
                    let path = folder.appendingPathComponent("Builds/\(engine.rawValue)")
                    guard let build = try? validateBuild(at: path), build.titleID == id, build.engine == engine else { return nil }
                    return build
                }
                if !builds.isEmpty { result[id] = builds }
            }
        var used = Set<String>()
        var games: [SwitchGame] = []
        for item in catalog {
            let names = installed.keys.sorted().filter { id in
                installed[id]?.contains { $0.title.caseInsensitiveCompare(item.title) == .orderedSame } == true
            }
            let matched = item.titleID ?? (names.count == 1 ? names.first : nil)
            let id = matched ?? item.id
            guard used.insert(id).inserted else { continue }
            games.append(.init(id: id, title: item.title, builds: matched.flatMap { installed[$0] } ?? [],
                               coverName: UUID(uuidString: item.id).map { "Covers/\($0.uuidString).jpg" }))
        }
        for (id, builds) in installed where used.insert(id).inserted {
            if let build = builds.first { games.append(.init(id: id, title: build.title, builds: builds)) }
        }
        return games.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func importItem(_ url: URL, into platform: Format.Platform?) throws {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var result: Result<Void, Swift.Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { source in
            result = Result {
                if source.pathExtension.lowercased() == "gcimport" {
                    try importSwitch(source)
                } else if source.lastPathComponent == Format.catalog {
                    _ = try Format.read([Format.SwitchEntry].self, at: source)
                    try Data(contentsOf: source).write(to: switchRoot.appendingPathComponent(Format.catalog), options: .atomic)
                } else {
                    let ext = source.pathExtension.lowercased()
                    let resolvedPlatform: Format.Platform? = platform
                        ?? platforms.first(where: { $0.extensions.contains(ext) })
                        ?? platforms.first(where: { $0.runtime != nil && Format.isGameFolder(source, runtime: $0.runtime) })
                    guard let resolvedPlatform,
                          resolvedPlatform.extensions.contains(ext)
                            || Format.isGameFolder(source, runtime: resolvedPlatform.runtime) else { throw Error.wrongFile }
                    try copyROM(source, platform: resolvedPlatform)
                }
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw Error.wrongFile }
        try result.get()
    }

    func importSwitchPackages() -> String? {
        var failures: [String] = []
        // Finish packages copied with earlier versions without creating the old directory.
        let legacyInbox = documents.appendingPathComponent("Import/Pending", isDirectory: true)
        let packages = children(switchRoot).filter { $0.pathExtension.lowercased() == "gcimport" }
            + children(legacyInbox).filter { $0.pathExtension.lowercased() == "gcimport" || $0.lastPathComponent == Format.catalog }
        for url in packages {
            do {
                try importItem(url, into: nil)
                try FileManager.default.removeItem(at: url)
            } catch {
                failures.append("\(url.lastPathComponent) · \(error.localizedDescription)")
            }
        }
        return failures.isEmpty ? nil : failures.joined(separator: "\n")
    }

    private func copyROM(_ source: URL, platform: Format.Platform) throws {
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
        let valid = values.isRegularFile == true || (values.isDirectory == true && Format.isGameFolder(source, runtime: platform.runtime))
        guard valid, values.isSymbolicLink != true else { throw Error.wrongFile }
        try FileManager.default.copyItem(at: source, to: romFolder(platform).appendingPathComponent(source.lastPathComponent))
    }

    private func importSwitch(_ source: URL) throws {
        let fm = FileManager.default
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw Error.wrongFile }
        let staging = switchRoot.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        try fm.copyItem(at: source, to: staging)
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        var traversalError: Swift.Error?
        guard let files = fm.enumerator(at: staging, includingPropertiesForKeys: keys, errorHandler: { _, error in
            traversalError = error
            return false
        }) else { throw Error.incompleteBuild }
        for case let file as URL in files {
            let values = try file.resourceValues(forKeys: Set(keys))
            guard values.isSymbolicLink != true, values.isRegularFile == true || values.isDirectory == true else {
                throw Error.incompleteBuild
            }
        }
        if let traversalError { throw traversalError }
        let build = try validateBuild(at: staging)
        let target = switchRoot.appendingPathComponent("\(build.titleID)/Builds/\(build.engine.rawValue)", isDirectory: true)
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: target.path) {
            _ = try fm.replaceItemAt(target, withItemAt: staging)
        } else {
            try fm.moveItem(at: staging, to: target)
        }
    }

    private func validateBuild(at folder: URL) throws -> Format.SwitchBuild {
        let build = try Format.read(Format.SwitchBuild.self, at: folder.appendingPathComponent("manifest.json"))
        guard build.schema == 1, Format.isTitleID(build.titleID), !build.title.isEmpty else { throw Error.incompleteBuild }
        let binary = folder.appendingPathComponent(build.executable)
        let image = folder.appendingPathComponent("Content/\(build.image)")
        let binaryValues = try binary.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
        guard binaryValues.isSymbolicLink != true,
              build.engine == .s2arm ? binaryValues.isRegularFile == true : binaryValues.isDirectory == true,
              let values = try? image.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, (values.fileSize ?? 0) > 0 else { throw Error.incompleteBuild }
        if build.engine == .nxnative {
            try NXGameLauncher.validate(at: binary, titleID: build.titleID)
        } else if FileManager.default.fileExists(atPath: folder.appendingPathComponent("catalogue.json").path) {
            try S2ArmGameLauncher.validate(at: folder, titleID: build.titleID)
        }
        return build
    }

    func deleteROM(_ rom: ROM) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: rom.url.path) {
            try fm.removeItem(at: rom.url)
        }
    }

    func deleteSwitchBuilds(for game: SwitchGame) throws {
        let fm = FileManager.default
        let buildsFolder = switchRoot.appendingPathComponent("\(game.id)/Builds", isDirectory: true)
        if fm.fileExists(atPath: buildsFolder.path) {
            try fm.removeItem(at: buildsFolder)
        }
    }

    private func children(_ url: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
    }

    enum Error: LocalizedError {
        case missingConfiguration, wrongFile, incompleteBuild
        var errorDescription: String? {
            switch self {
            case .missingConfiguration: "应用缺少平台清单"
            case .wrongFile: "请选择与当前平台匹配的 ROM、Switch 构建包或游戏清单"
            case .incompleteBuild: "Switch 构建包缺少有效的清单、程序或游戏资源"
            }
        }
    }
}
