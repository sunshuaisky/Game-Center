import Foundation
import ImageIO

struct GameMetadataResult: Sendable {
    let title: String?
    let synopsis: String?
    let metadataSourceURL: String?
    let artworkData: Data?
    let artworkExtension: String?
    let artworkSourceURL: String?
    let backdropData: Data?

    var hasMetadata: Bool {
        title != nil || synopsis != nil || artworkData != nil || backdropData != nil
    }
}

actor GameMetadataService {
    private let session: URLSession
    private let trace: @Sendable (String) -> Void
    private static let networkSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GameCenter/HTTP", isDirectory: true)
        configuration.urlCache = URLCache(memoryCapacity: 8 * 1024 * 1024,
                                          diskCapacity: 64 * 1024 * 1024, directory: directory)
        configuration.timeoutIntervalForRequest = 18
        configuration.timeoutIntervalForResource = 35
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()
    init(session: URLSession? = nil, trace: @escaping @Sendable (String) -> Void = { _ in }) {
        self.session = session ?? Self.networkSession; self.trace = trace
    }
    private var artworkCatalogs: [GameMetadataPlatform: [String]] = [:]
    private var screenshotCatalogs: [GameMetadataPlatform: [String]] = [:]
    // Base URL each cached filename resolves against — the libretro index or
    // its jsDelivr mirror, whichever produced the catalog.
    private var artworkCatalogSources: [GameMetadataPlatform: URL] = [:]
    private var screenshotCatalogSources: [GameMetadataPlatform: URL] = [:]
    private var gameTDBCatalogs: [String: [(id: String, title: String)]] = [:]
    private var switchCatalogs: [String: [(id: String, title: String)]] = [:]

    func lookup(title: String, platform: GameMetadataPlatform, language: String, sourceURL: URL?, titleID explicitTitleID: String? = nil, onText: @escaping @Sendable (GameMetadataResult) async -> Void = { _ in }, onBackdrop: @escaping @Sendable (Data) async -> Void = { _ in }) async -> GameMetadataResult {
        let switch2Metadata = platform == .switchConsole
            ? sourceURL.flatMap { readSwitch2ContainerMetadata(from: $0, language: language) }
            : nil
        let titleID = platform == .switchConsole
            ? (explicitTitleID ?? sourceURL.flatMap(switchTitleID(from:)) ?? switch2Metadata?.titleID)
            : nil
        let knownSwitchMetadata = platform == .switchConsole
            ? knownSwitchGameMetadata(titleID: titleID, title: title, language: language)
            : nil
        let filenameTitle = searchableGameName(from: sourceURL, fallback: title)
        let codeMetadata: SwitchTitleMetadata?
        if let titleID {
            codeMetadata = await switchTitleMetadata(for: titleID, language: language)
        } else {
            codeMetadata = nil
        }
        let searchTitle = codeMetadata?.title ?? switch2Metadata?.title ?? knownSwitchMetadata?.title ?? filenameTitle ?? title
        let aliasHint = Self.chineseFranchiseHint(for: [title, filenameTitle, searchTitle].compactMap { $0 }.joined(separator: " "), platform: platform)
        let effectiveSearchTitle = aliasHint?.zh ?? searchTitle

        async let wikiTask = wikipediaResult(for: effectiveSearchTitle, language: language, localizedTitle: filenameTitle ?? effectiveSearchTitle)
        async let baikeTask = baikeLookupTask(title: effectiveSearchTitle, filenameTitle: filenameTitle, language: language)
        async let bannerTask = switchBanner(titleID: titleID, platform: platform)

        let wiki = await wikiTask
        let baike = await baikeTask
        let resolvedTitle: String?
        if language == "en" {
            resolvedTitle = codeMetadata?.title ?? wiki?.title ?? knownSwitchMetadata?.title ?? switch2Metadata?.title ?? aliasHint?.en
        } else {
            resolvedTitle = wiki?.title ?? knownSwitchMetadata?.title ?? switch2Metadata?.title ?? codeMetadata?.title
                ?? baike?.title ?? aliasHint?.zh
        }
        let resolvedSynopsis: String?
        if language == "en" {
            resolvedSynopsis = codeMetadata?.synopsis ?? wiki?.synopsis ?? knownSwitchMetadata?.synopsis
        } else {
            resolvedSynopsis = wiki?.synopsis ?? codeMetadata?.synopsis ?? knownSwitchMetadata?.synopsis
                ?? baike?.synopsis
        }

        let text = GameMetadataResult(title: resolvedTitle, synopsis: resolvedSynopsis,
            metadataSourceURL: wiki?.pageURL ?? baike?.pageURL.absoluteString ?? codeMetadata?.sourceURL ?? knownSwitchMetadata?.sourceURL,
            artworkData: nil, artworkExtension: nil, artworkSourceURL: nil, backdropData: nil)

        if text.hasMetadata { await onText(text) }
        let banner = await bannerTask
        if let banner { await onBackdrop(banner.data) }

        // Build deduplicated Romanized / English title candidates for LaunchBox, GameTDB, Libretro, and Steam.
        var romanizedCandidates: [String] = []
        for raw in [aliasHint?.en, wiki?.alternateTitle, baike?.latinTitle, wiki?.title, searchTitle, filenameTitle].compactMap({ $0 }) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if !romanizedCandidates.contains(where: { normalize($0) == normalize(trimmed) }) {
                romanizedCandidates.append(trimmed)
            }
        }
        let englishCandidates = romanizedCandidates.filter { !GameTitleMatcher.hasHan($0) }

        // 1. Query LaunchBox GamesDB (curated per-platform Box-Front + 1080p/4K Fanart-Background)
        //    and Steam 16:9 HD media in parallel.
        async let launchBoxTask: LaunchBoxMediaResult? = {
            for candidateTitle in englishCandidates.prefix(3) {
                if let res = await self.launchBoxMedia(for: candidateTitle, platform: platform, language: language) {
                    return res
                }
            }
            return nil
        }()
        async let steamTask: SteamMediaResult? = {
            for candidateTitle in englishCandidates.prefix(3) {
                if let res = await self.steamMedia(for: candidateTitle, platform: platform) {
                    return res
                }
            }
            return nil
        }()

        let launchBox = await launchBoxTask
        let steamResult = await steamTask

        // 2. Build dedicated game-database cover candidates first (so movie/anime posters from
        //    Baidu Baike never override real game box art).
        var gameCoverCandidates: [DownloadedArtwork] = []
        if let lbCover = launchBox?.cover { gameCoverCandidates.append(lbCover) }
        if let steamCover = steamResult?.cover { gameCoverCandidates.append(steamCover) }
        if let icon = switch2Metadata?.icon { gameCoverCandidates.append(icon) }
        if let artworkURL = knownSwitchMetadata?.artworkURL,
           let data = try? await download(artworkURL) {
            gameCoverCandidates.append(DownloadedArtwork(data: data, fileExtension: "jpg", sourceURL: artworkURL.absoluteString))
        }

        if gameCoverCandidates.isEmpty {
            for candidateTitle in romanizedCandidates {
                if let tdb = await gameTDBBoxart(for: candidateTitle, platform: platform, language: language) {
                    gameCoverCandidates.append(tdb)
                    break
                }
            }
        }
        if gameCoverCandidates.isEmpty {
            for candidateTitle in romanizedCandidates {
                if let libretroCover = await boxartData(for: candidateTitle, platform: platform, language: language) {
                    gameCoverCandidates.append(libretroCover)
                    break
                }
            }
        }

        // Fallback to encyclopedia / Switch icon only if dedicated game databases had no cover.
        var fallbackCoverCandidates: [DownloadedArtwork] = []
        if gameCoverCandidates.isEmpty {
            if let artworkURL = wiki?.artworkURL,
               let data = try? await download(artworkURL) {
                fallbackCoverCandidates.append(DownloadedArtwork(
                    data: data,
                    fileExtension: artworkURL.pathExtension.isEmpty ? "jpg" : artworkURL.pathExtension,
                    sourceURL: artworkURL.absoluteString
                ))
            }
            if let artworkURL = baike?.artworkURL,
               let data = try? await download(artworkURL, userAgent: Self.baikeUserAgent) {
                fallbackCoverCandidates.append(DownloadedArtwork(data: data, fileExtension: "jpg", sourceURL: artworkURL.absoluteString))
            }
            if fallbackCoverCandidates.isEmpty,
               let iconString = codeMetadata?.iconURL,
               let iconURL = URL(string: iconString),
               let iconData = try? await download(iconURL) {
                fallbackCoverCandidates.append(DownloadedArtwork(
                    data: iconData,
                    fileExtension: iconURL.pathExtension.isEmpty ? "jpg" : iconURL.pathExtension,
                    sourceURL: iconURL.absoluteString
                ))
            }
        }
        let selectedArtwork = (gameCoverCandidates.isEmpty ? fallbackCoverCandidates : gameCoverCandidates)
            .max { pixelArea($0.data) < pixelArea($1.data) }

        // 3. Select true HD 16:9 backdrop (never stretch tiny 400x240 emulator screenshots).
        let knownBackdrop: DownloadedArtwork?
        if let url = knownSwitchMetadata?.backdropURL, let data = try? await download(url) {
            knownBackdrop = DownloadedArtwork(data: data, fileExtension: "jpg", sourceURL: url.absoluteString)
        } else {
            knownBackdrop = nil
        }

        var wideArtwork = banner ?? knownBackdrop ?? launchBox?.backdrop ?? steamResult?.backdrop
        if wideArtwork == nil, let wikiTitle = wiki?.alternateTitle ?? wiki?.title {
            let wikiLang = wiki?.alternateTitle != nil ? "en" : language
            wideArtwork = await wikipediaWideImage(for: wikiTitle, language: wikiLang)
        }
        if wideArtwork == nil {
            wideArtwork = steamResult?.panoramicBackdrop
        }
        if let wide = wideArtwork, banner == nil {
            await onBackdrop(wide.data)
        }

        return GameMetadataResult(
            title: resolvedTitle,
            synopsis: resolvedSynopsis,
            metadataSourceURL: wiki?.pageURL ?? codeMetadata?.sourceURL ?? knownSwitchMetadata?.sourceURL,
            artworkData: selectedArtwork?.data,
            artworkExtension: selectedArtwork?.fileExtension,
            artworkSourceURL: selectedArtwork?.sourceURL,
            backdropData: wideArtwork?.data
        )
    }

    private func knownSwitchGameMetadata(titleID: String?, title: String, language: String) -> KnownSwitchGameMetadata? {
        let isPokopia = titleID?.uppercased() == "0400A3A01EE4C000"
            || title.localizedCaseInsensitiveContains("pokopia")
            || title.contains("ぽこ あ ポケモン")
        guard isPokopia else { return nil }

        let localizedTitle: String
        let synopsis: String
        switch language.lowercased() {
        case "zh", "zh-hans":
            localizedTitle = "宝可梦 Pokopia"
            synopsis = "以百变怪为主角的慢生活沙盒游戏。收集材料、制作家具、培育蔬菜，并与宝可梦伙伴一起建设适合居住的城镇。"
        case "ja":
            localizedTitle = "ぽこ あ ポケモン"
            synopsis = "メタモンが主人公のスローライフ・サンドボックスゲーム。素材を集め、家具を作り、ポケモンたちと暮らす街を作ります。"
        default:
            localizedTitle = "Pokémon Pokopia"
            synopsis = "A cozy life simulation sandbox starring Ditto. Gather materials, craft furniture, grow crops, and build a welcoming town alongside Pokémon."
        }
        return KnownSwitchGameMetadata(
            title: localizedTitle,
            synopsis: synopsis,
            artworkURL: URL(string: "https://cdn.uc.assets.prezly.com/8448c70f-4d93-43e5-a5cc-d06d8bc75ce0/-/format/auto/Pokemon_Pokopia_Key_Visual.png"),
            backdropURL: URL(string: "https://cdn.uc.assets.prezly.com/8448c70f-4d93-43e5-a5cc-d06d8bc75ce0/-/format/auto/Pokemon_Pokopia_Key_Visual.png"),
            sourceURL: "https://www.pocoapokemon.jp/ja/lineup/260227_01/"
        )
    }

    private func searchableGameName(from sourceURL: URL?, fallback title: String) -> String? {
        var candidates = [title]
        if let sourceURL {
            // A folder is the game itself; stripping its "extension" would cut
            // the name at the last dot ("…[中文][1.05][DLC]").
            candidates.append(sourceURL.hasDirectoryPath
                ? sourceURL.lastPathComponent : sourceURL.deletingPathExtension().lastPathComponent)
            candidates.append(sourceURL.deletingLastPathComponent().lastPathComponent)
        }

        let ignored = Set(["switch", "switch2", "switch 2", "games", "game", "roms", "nup", "nsp", "xci", "nsz", "xcz", "base", "updates", "dlc", "mod"])
        let titleIDPattern = try? NSRegularExpression(pattern: #"(?i)\b[0-9a-f]{16}\b"#)
        // Full-width brackets are common in Chinese release names (（汉化版）, 【简】).
        let noisePattern = try? NSRegularExpression(pattern: #"(?i)\[[^\]]*\]|\([^)]*\)|（[^）]*）|【[^】]*】|\b(?:xci|nsp|nsz|xcz|nup|mod|v\d+(?:\.\d+)*)\b"#)

        for candidate in candidates {
            var cleaned = candidate
            let fullRange = NSRange(cleaned.startIndex..., in: cleaned)
            cleaned = titleIDPattern?.stringByReplacingMatches(in: cleaned, range: fullRange, withTemplate: " ") ?? cleaned
            let noiseRange = NSRange(cleaned.startIndex..., in: cleaned)
            cleaned = noisePattern?.stringByReplacingMatches(in: cleaned, range: noiseRange, withTemplate: " ") ?? cleaned
            // Dumps usually lead with a release serial ("3191 - …",
            // "PS3CH032 - …"). It is not part of the game name and dilutes the
            // matcher's score against clean catalogue titles.
            cleaned = cleaned.replacingOccurrences(
                of: #"^\s*(?=[A-Za-z0-9]{4,12}\s*[-–—])(?=[A-Za-z0-9]*\d)[A-Za-z0-9]+\s*[-–—]+\s*"#,
                with: "", options: .regularExpression)
            // Serials glued to the name ("骇客追忆PCSH10079", "BLUS12345") go too.
            cleaned = cleaned.replacingOccurrences(
                of: #"(?<![A-Za-z0-9])[A-Z]{2,4}-?\d{4,6}(?![0-9])"#, with: " ", options: .regularExpression)
            cleaned = cleaned
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))

            guard !cleaned.isEmpty,
                  !ignored.contains(cleaned.lowercased()),
                  // Bare release serials ("PCSH10079") are not names; the next
                  // candidate (the real directory or file name) is the title.
                  cleaned.range(of: #"^[A-Za-z]*\d[\w-]*$"#, options: .regularExpression) == nil,
                  cleaned.range(of: #"^[\d\s.-]+$"#, options: .regularExpression) == nil else { continue }
            return cleaned
        }
        return nil
    }

    func switchTitle(for sourceURL: URL, language: String) async -> String? {
        let local = readSwitch2ContainerMetadata(from: sourceURL, language: language)
        guard let titleID = switchTitleID(from: sourceURL) ?? local?.titleID else { return local?.title }
        let codeTitle = await switchTitleMetadata(for: titleID, language: language)?.title
        guard let candidate = codeTitle ?? local?.title else { return nil }
        guard language != "en" else { return codeTitle ?? local?.title }
        return await wikipediaResult(for: candidate, language: language)?.title ?? candidate
    }

    private func switchTitleMetadata(for titleID: String, language: String) async -> SwitchTitleMetadata? {
        let preferredLanguage: String
        switch language {
        case "zh-Hans", "zh": preferredLanguage = "zh"
        case "ja": preferredLanguage = "ja"
        default: preferredLanguage = "en"
        }

        let preferred = await fetchSwitchTitleMetadata(titleID: titleID, language: preferredLanguage)
        guard preferredLanguage != "en",
              preferred?.title == nil || preferred?.synopsis == nil else { return preferred }

        let english = await fetchSwitchTitleMetadata(titleID: titleID, language: "en")
        guard let preferred else { return english }
        return SwitchTitleMetadata(
            title: preferred.title ?? english?.title,
            synopsis: preferred.synopsis ?? english?.synopsis,
            iconURL: preferred.iconURL ?? english?.iconURL,
            sourceURL: preferred.sourceURL
        )
    }

    private func fetchSwitchTitleMetadata(titleID: String, language: String) async -> SwitchTitleMetadata? {
        guard var components = URLComponents(string: "https://api.nlib.cc/nx/\(titleID)") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "lang", value: language),
            URLQueryItem(name: "fields", value: "name,description,intro,icon")
        ]
        guard let url = components.url,
              let data = try? await download(url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let title = (json["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = (json["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let intro = (json["intro"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let synopsis = (description?.isEmpty == false ? description : nil) ?? (intro?.isEmpty == false ? intro : nil)
        var iconComponents = (json["icon"] as? String).flatMap(URLComponents.init(string:))
        if iconComponents?.scheme == "http" { iconComponents?.scheme = "https" }
        return SwitchTitleMetadata(
            title: title?.isEmpty == false ? title : nil,
            synopsis: synopsis.map(cleanSynopsis),
            iconURL: iconComponents?.url?.absoluteString,
            sourceURL: url.absoluteString
        )
    }

    private struct SteamMediaResult {
        let cover: DownloadedArtwork?
        let backdrop: DownloadedArtwork?
        let panoramicBackdrop: DownloadedArtwork?
    }

    private struct LaunchBoxMediaResult {
        let cover: DownloadedArtwork?
        let backdrop: DownloadedArtwork?
    }

    private static let browserUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    /// LaunchBox GamesDB provides human-curated per-platform `Box - Front` covers and
    /// 16:9 HD `Fanart - Background` wallpapers specifically intended for game launcher backdrops.
    private func launchBoxMedia(for title: String, platform: GameMetadataPlatform, language: String) async -> LaunchBoxMediaResult? {
        guard !title.isEmpty, !GameTitleMatcher.hasHan(title),
              let encoded = title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let searchURL = URL(string: "https://gamesdb.launchbox-app.com/games/results/\(encoded)"),
              let data = try? await download(searchURL, userAgent: Self.browserUserAgent),
              let html = String(data: data, encoding: .utf8) else { return nil }

        guard let cardRegex = try? NSRegularExpression(
            pattern: #"href="/games/details/(\d+)[^"]*"[^>]*>(.*?)</a>"#,
            options: [.dotMatchesLineSeparators]
        ) else { return nil }

        let targetPlatform = launchBoxPlatformName(for: platform)?.lowercased()
        let matches = cardRegex.matches(in: html, range: NSRange(html.startIndex..., in: html))
        struct Card {
            let id: String
            let titleScore: Double
            let platformMatch: Bool
            let isHack: Bool
        }
        var cards: [Card] = []
        var seenIDs = Set<String>()
        for match in matches.prefix(24) {
            guard let idRange = Range(match.range(at: 1), in: html),
                  let bodyRange = Range(match.range(at: 2), in: html) else { continue }
            let id = String(html[idRange])
            guard seenIDs.insert(id).inserted else { continue }
            let rawBody = String(html[bodyRange])
            let stripped = Self.unescapeHTML(
                rawBody.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
                    .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !stripped.isEmpty else { continue }
            let lower = stripped.lowercased()
            let isHack = lower.contains("rom hack") || lower.contains("homebrew") || lower.contains("unlicensed")
            let platformMatch = targetPlatform.map { lower.contains($0) } ?? false
            // Extract the title prefix before the platform name or "Add to collection" for clean scoring.
            let titlePart = stripped
                .replacingOccurrences(of: #"\s+(?:Nintendo|Sony|Sega|Microsoft|Windows|Add to collection|Released).*$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let candidateTitle = titlePart.isEmpty ? stripped : titlePart
            var score = matchScore(title, candidateTitle)
            let normQuery = normalize(title)
            let normCandidate = normalize(candidateTitle)
            if normQuery.count >= 6, normCandidate.contains(normQuery) {
                score = max(score, platformMatch ? 0.88 : 0.78)
            }
            guard score >= 0.72 else { continue }
            cards.append(Card(id: id, titleScore: score, platformMatch: platformMatch, isHack: isHack))
        }
        guard !cards.isEmpty else { return nil }

        // Prefer non-hack, then platform-matched, then highest title similarity.
        let ordered = cards.sorted { lhs, rhs in
            if lhs.isHack != rhs.isHack { return !lhs.isHack }
            if lhs.platformMatch != rhs.platformMatch { return lhs.platformMatch }
            return lhs.titleScore > rhs.titleScore
        }

        var bestCover: DownloadedArtwork?
        var bestBackdrop: DownloadedArtwork?

        for card in ordered.prefix(3) {
            if bestCover != nil && bestBackdrop != nil { break }
            guard let imgPageURL = URL(string: "https://gamesdb.launchbox-app.com/games/images/\(card.id)"),
                  let imgData = try? await download(imgPageURL, userAgent: Self.browserUserAgent),
                  let imgHTML = String(data: imgData, encoding: .utf8),
                  let itemRegex = try? NSRegularExpression(
                    pattern: #"href="(https://images\.launchbox-app\.com/[^"]+)"[^>]*data-title="([^"]*)""#
                  ) else { continue }

            var fanartURLs: [URL] = []
            var boxFrontURLs: [(url: URL, priority: Int)] = []
            for m in itemRegex.matches(in: imgHTML, range: NSRange(imgHTML.startIndex..., in: imgHTML)) {
                guard let uRange = Range(m.range(at: 1), in: imgHTML),
                      let lRange = Range(m.range(at: 2), in: imgHTML),
                      let imgURL = URL(string: String(imgHTML[uRange])) else { continue }
                let label = Self.unescapeHTML(String(imgHTML[lRange]))
                if label.contains("Fanart - Background") {
                    fanartURLs.append(imgURL)
                } else if label.contains("Box - Front") && card.platformMatch {
                    let prio: Int
                    if label.contains("World") || label.contains("North America") || label.contains("United States") { prio = 3 }
                    else if (language == "ja" || language == "zh") && (label.contains("Japan") || label.contains("Asia")) { prio = 4 }
                    else if label.contains("Europe") || label.contains("Japan") { prio = 2 }
                    else { prio = 1 }
                    boxFrontURLs.append((imgURL, prio))
                }
            }

            if bestCover == nil, let topBox = boxFrontURLs.sorted(by: { $0.priority > $1.priority }).first {
                if let bytes = try? await download(topBox.url, userAgent: Self.browserUserAgent),
                   pixelArea(bytes) >= 250 * 250 {
                    let ext = topBox.url.pathExtension.lowercased() == "png" ? "png" : "jpg"
                    bestCover = DownloadedArtwork(data: bytes, fileExtension: ext, sourceURL: topBox.url.absoluteString)
                }
            }

            if bestBackdrop == nil {
                var hdCandidates: [DownloadedArtwork] = []
                for url in fanartURLs.prefix(4) {
                    if let bytes = try? await download(url, userAgent: Self.browserUserAgent),
                       let dims = pixelDimensions(bytes),
                       dims.width >= 960, dims.height >= 540 {
                        let ratio = Double(dims.width) / Double(dims.height)
                        if ratio >= 1.35 && ratio <= 2.35 {
                            let ext = url.pathExtension.lowercased() == "png" ? "png" : "jpg"
                            hdCandidates.append(DownloadedArtwork(data: bytes, fileExtension: ext, sourceURL: url.absoluteString))
                            if dims.width >= 1920 && dims.height >= 1080 { break }
                        }
                    }
                }
                bestBackdrop = hdCandidates.max { pixelArea($0.data) < pixelArea($1.data) }
            }
        }

        guard bestCover != nil || bestBackdrop != nil else { return nil }
        return LaunchBoxMediaResult(cover: bestCover, backdrop: bestBackdrop)
    }

    private func launchBoxPlatformName(for platform: GameMetadataPlatform) -> String? {
        switch platform {
        case .gba: return "Game Boy Advance"
        case .gb: return "Game Boy"
        case .gbc: return "Game Boy Color"
        case .nds: return "Nintendo DS"
        case .threeDS: return "Nintendo 3DS"
        case .psp: return "Sony PSP"
        case .psv: return "Sony Playstation Vita"
        case .ps1: return "Sony Playstation"
        case .ps2: return "Sony Playstation 2"
        case .ps3: return "Sony Playstation 3"
        case .wii: return "Nintendo Wii"
        case .wiiu: return "Nintendo Wii U"
        case .switchConsole: return "Nintendo Switch"
        default: return nil
        }
    }

    private func steamMedia(for title: String, platform: GameMetadataPlatform) async -> SteamMediaResult? {
        guard !title.isEmpty, !GameTitleMatcher.hasHan(title) else { return nil }
        guard var components = URLComponents(string: "https://store.steampowered.com/api/storesearch/") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "term", value: title),
            URLQueryItem(name: "l", value: "english"),
            URLQueryItem(name: "cc", value: "US")
        ]
        guard let searchURL = components.url,
              let searchData = try? await download(searchURL),
              let root = try? JSONSerialization.jsonObject(with: searchData) as? [String: Any],
              let items = root["items"] as? [[String: Any]] else { return nil }

        let normQuery = normalize(title)
        let match = items
            .filter { ($0["type"] as? String) == "app" }
            .compactMap { item -> (id: Int, score: Double)? in
                guard let id = item["id"] as? Int, let name = item["name"] as? String else { return nil }
                var score = matchScore(title, name)
                let normName = normalize(name)
                if normName.hasPrefix(normQuery) || normQuery.hasPrefix(normName) {
                    score = max(score, 0.86)
                }
                return (id, score)
            }
            .max { $0.score < $1.score }
        guard let match, match.score >= 0.78 else { return nil }

        var backdrop16x9: DownloadedArtwork?
        var panoramic: DownloadedArtwork?
        var cover: DownloadedArtwork?

        // 1. Prefer true 16:9 HD background_raw / full-res screenshots over narrow 3.1:1 library_hero strips.
        if let detailsURL = URL(string: "https://store.steampowered.com/api/appdetails?appids=\(match.id)&l=english&cc=US"),
           let detailsData = try? await download(detailsURL),
           let details = try? JSONSerialization.jsonObject(with: detailsData) as? [String: Any],
           let app = details[String(match.id)] as? [String: Any],
           let data = app["data"] as? [String: Any] {
            var imageURLs: [URL] = []
            for key in ["background_raw", "background"] {
                if let value = data[key] as? String, let url = URL(string: value) { imageURLs.append(url) }
            }
            if let screenshots = data["screenshots"] as? [[String: Any]] {
                imageURLs.append(contentsOf: screenshots.prefix(3).compactMap { ($0["path_full"] as? String).flatMap(URL.init(string:)) })
            }
            for url in imageURLs {
                if let imageData = try? await download(url),
                   let dims = pixelDimensions(imageData),
                   dims.width >= 1200, dims.height >= 675 {
                    let ratio = Double(dims.width) / Double(dims.height)
                    if ratio >= 1.4 && ratio <= 2.2 {
                        backdrop16x9 = DownloadedArtwork(data: imageData, fileExtension: "jpg", sourceURL: url.absoluteString)
                        break
                    }
                }
            }
        }

        // 2. Fallback to Steam panoramic library_hero only when no 16:9 artwork was found.
        if backdrop16x9 == nil {
            for urlStr in [
                "https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/\(match.id)/page_bg_raw.jpg",
                "https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/\(match.id)/library_hero_2x.jpg",
                "https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/\(match.id)/library_hero.jpg"
            ] {
                guard let url = URL(string: urlStr),
                      let data = try? await download(url),
                      let dims = pixelDimensions(data),
                      dims.width >= 960, dims.height >= 400 else { continue }
                panoramic = DownloadedArtwork(data: data, fileExtension: "jpg", sourceURL: url.absoluteString)
                break
            }
        }

        for urlStr in [
            "https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/\(match.id)/library_600x900_2x.jpg",
            "https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/\(match.id)/library_600x900.jpg"
        ] {
            guard let url = URL(string: urlStr),
                  let data = try? await download(url),
                  pixelArea(data) >= 300 * 400 else { continue }
            cover = DownloadedArtwork(data: data, fileExtension: "jpg", sourceURL: url.absoluteString)
            break
        }

        guard cover != nil || backdrop16x9 != nil || panoramic != nil else { return nil }
        return SteamMediaResult(cover: cover, backdrop: backdrop16x9, panoramicBackdrop: panoramic)
    }

    /// Maps common Chinese ROM hack / fan-translation names to canonical Chinese & English game titles.
    private static func chineseFranchiseHint(for text: String, platform: GameMetadataPlatform) -> (zh: String, en: String)? {
        let rules: [(patterns: [String], zh: String, en: String)] = [
            (["欧米伽红宝石", "红宝石"], "宝可梦 欧米伽红宝石", "Pokemon Omega Ruby"),
            (["阿尔法蓝宝石", "蓝宝石"], "宝可梦 阿尔法蓝宝石", "Pokemon Alpha Sapphire"),
            (["心金"], "宝可梦 心金", "Pokemon HeartGold Version"),
            (["魂银"], "宝可梦 魂银", "Pokemon SoulSilver Version"),
            (["漆黑的魅影", "绿宝石"], "宝可梦 绿宝石", "Pokemon Emerald Version"),
            (["火红"], "宝可梦 火红", "Pokemon FireRed Version"),
            (["叶绿"], "宝可梦 叶绿", "Pokemon LeafGreen Version"),
            (["白金"], "宝可梦 白金", "Pokemon Platinum Version"),
            (["数码宝贝物语", "网络侦探", "骇客追忆"], "数码宝贝物语 网络侦探", "Digimon Story Cyber Sleuth"),
            (["数码宝贝大冒险"], "数码宝贝大冒险", "Digimon Adventure"),
            (["刀剑神域", "失落之歌"], "刀剑神域 失落之歌", "Sword Art Online: Lost Song"),
            (["勇者斗恶龙怪兽篇"], "勇者斗恶龙怪兽篇", "Dragon Quest Monsters"),
            (["哈利波特", "消失的密室"], "哈利·波特与密室", "Harry Potter and the Chamber of Secrets"),
            (["哈利波特", "魔法石"], "哈利·波特与魔法石", "Harry Potter and the Sorcerer's Stone"),
            (["塞尔达传说", "风之杖"], "塞尔达传说 风之杖", "The Legend of Zelda: The Wind Waker"),
            (["塞尔达传说", "智慧的再现"], "塞尔达传说 智慧的再现", "The Legend of Zelda: Echoes of Wisdom")
        ]
        for rule in rules {
            // Require either a specific single subtitle match or all listed keywords when multi-word.
            if rule.patterns.count == 1 {
                if text.contains(rule.patterns[0]) {
                    if rule.patterns[0] == "红宝石" && platform == .gba {
                        return ("宝可梦 红宝石", "Pokemon Ruby Version")
                    }
                    if rule.patterns[0] == "蓝宝石" && platform == .gba {
                        return ("宝可梦 蓝宝石", "Pokemon Sapphire Version")
                    }
                    return (rule.zh, rule.en)
                }
            } else {
                // Match if the primary franchise + subtitle match OR any unique subtitle matches.
                let hitCount = rule.patterns.filter { text.contains($0) }.count
                if hitCount >= 2 || (rule.patterns.contains("欧米伽红宝石") && text.contains("欧米伽红宝石"))
                    || (rule.patterns.contains("阿尔法蓝宝石") && text.contains("阿尔法蓝宝石"))
                    || (rule.patterns.contains("漆黑的魅影") && text.contains("漆黑的魅影"))
                    || (rule.patterns.contains("网络侦探") && (text.contains("网络侦探") || text.contains("骇客追忆")))
                    || (rule.patterns.contains("失落之歌") && text.contains("失落之歌"))
                    || (rule.patterns.contains("消失的密室") && text.contains("消失的密室")) {
                    return (rule.zh, rule.en)
                }
            }
        }
        return nil
    }

    private func gameTDBBoxart(for title: String, platform: GameMetadataPlatform, language: String) async -> DownloadedArtwork? {
        let tdbInfo: (db: String, artPrefix: String, idPattern: String)? = {
            switch platform {
            case .nds: return ("dstdb", "ds", #"^[A-Za-z0-9]{4}$"#)
            case .threeDS: return ("3dstdb", "3ds", #"^[A-Za-z0-9]{4}$"#)
            case .wii: return ("wiitdb", "wii", #"^[A-Za-z0-9]{4,6}$"#)
            case .wiiu: return ("wiiutdb", "wiiu", #"^[A-Za-z0-9]{4,6}$"#)
            case .ps3: return ("ps3tdb", "ps3", #"^[A-Za-z]{4}\d{5}$"#)
            default: return nil
            }
        }()
        guard let tdbInfo else { return nil }
        let cacheKey = "\(tdbInfo.db)-EN"
        let entries: [(id: String, title: String)]
        if let cached = gameTDBCatalogs[cacheKey] {
            entries = cached
        } else {
            guard let url = URL(string: "https://www.gametdb.com/\(tdbInfo.db).txt?LANG=EN"),
                  let data = try? await download(url),
                  let text = String(data: data, encoding: .utf8) else { return nil }
            entries = text.split(whereSeparator: \.isNewline).compactMap { line in
                guard let sep = line.range(of: " = ") else { return nil }
                let id = String(line[..<sep.lowerBound]).trimmingCharacters(in: .whitespaces)
                let name = String(line[sep.upperBound...]).trimmingCharacters(in: .whitespaces)
                guard id.range(of: tdbInfo.idPattern, options: .regularExpression) != nil, !name.isEmpty else { return nil }
                return (id: id, title: name)
            }
            guard !entries.isEmpty else { return nil }
            gameTDBCatalogs[cacheKey] = entries
        }

        let candidate = entries
            .map { (entry: $0, score: matchScore(title, $0.title)) }
            .max { $0.score < $1.score }
        guard let candidate, candidate.score >= max(0.78, minimumMatchScore(for: title)) else { return nil }

        let regions = language == "ja" ? ["JA", "US", "EN"] : ["US", "EN", "JA"]
        for coverType in ["coverHQ", "cover"] {
            for region in regions {
                for ext in ["jpg", "png"] {
                    guard let url = URL(string: "https://art.gametdb.com/\(tdbInfo.artPrefix)/\(coverType)/\(region)/\(candidate.entry.id).\(ext)"),
                          let data = try? await download(url), pixelArea(data) > 10000 else { continue }
                    return DownloadedArtwork(data: data, fileExtension: ext, sourceURL: url.absoluteString)
                }
            }
        }
        return nil
    }

    private func wikipediaWideImage(for pageTitle: String, language: String) async -> DownloadedArtwork? {
        guard var components = URLComponents(string: "https://\(language).wikipedia.org/w/api.php") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "generator", value: "images"),
            URLQueryItem(name: "titles", value: pageTitle),
            URLQueryItem(name: "gimlimit", value: "12"),
            URLQueryItem(name: "prop", value: "imageinfo"),
            URLQueryItem(name: "iiprop", value: "url|size|mime"),
            URLQueryItem(name: "iiurlwidth", value: "1600"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "formatversion", value: "2")
        ]
        guard let url = components.url,
              let data = try? await download(url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let query = root["query"] as? [String: Any],
              let pages = query["pages"] as? [[String: Any]] else { return nil }

        var candidates: [(url: URL, area: Int)] = []
        for page in pages {
            let fileTitle = (page["title"] as? String ?? "").lowercased()
            if fileTitle.contains("logo") || fileTitle.contains("icon") || fileTitle.contains("flag")
                || fileTitle.contains("commons") || fileTitle.contains("wiki") || fileTitle.hasSuffix(".svg") {
                continue
            }
            guard let info = (page["imageinfo"] as? [[String: Any]])?.first,
                  let mime = info["mime"] as? String, (mime == "image/jpeg" || mime == "image/png"),
                  let w = info["width"] as? Int, let h = info["height"] as? Int,
                  w >= 960, h >= 540, Double(w) / Double(h) >= 1.35, Double(w) / Double(h) <= 2.35,
                  let imgURLStr = (info["thumburl"] as? String) ?? (info["url"] as? String),
                  let imgURL = URL(string: imgURLStr) else { continue }
            candidates.append((imgURL, w * h))
        }
        for item in candidates.sorted(by: { $0.area > $1.area }).prefix(3) {
            if let imgData = try? await download(item.url),
               let dims = pixelDimensions(imgData),
               dims.width >= 960, dims.height >= 540 {
                let ratio = Double(dims.width) / Double(dims.height)
                if ratio >= 1.35 && ratio <= 2.35 {
                    let ext = item.url.pathExtension.lowercased() == "png" ? "png" : "jpg"
                    return DownloadedArtwork(data: imgData, fileExtension: ext, sourceURL: item.url.absoluteString)
                }
            }
        }
        return nil
    }

    private func switchBanner(titleID: String?, platform: GameMetadataPlatform) async -> DownloadedArtwork? {
        guard platform == .switchConsole, let titleID,
              let url = URL(string: "https://api.nlib.cc/nx/\(titleID)/banner/1080p"),
              let data = try? await download(url),
              pixelArea(data) >= 1920 * 900 else { return nil }
        return DownloadedArtwork(data: data, fileExtension: "jpg", sourceURL: url.absoluteString)
    }

    private func switchTitleID(from sourceURL: URL) -> String? {
        var candidates = [sourceURL.lastPathComponent]
        for (relative, key) in [("Contents/Resources/dm/launcher.json", "game"), ("Contents/Resources/S2ArmStandalone/standalone.json", "gameID"), ("manifest.json", "titleID")] {
            if let data = try? Data(contentsOf: sourceURL.appendingPathComponent(relative)),
               let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let id = info[key] as? String {
                candidates.insert(id, at: 0)
            }
        }
        if let identifier = Bundle(url: sourceURL)?.bundleIdentifier {
            candidates.insert(identifier, at: 0)
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory), isDirectory.boolValue,
           let children = try? FileManager.default.contentsOfDirectory(at: sourceURL, includingPropertiesForKeys: nil) {
            candidates.append(contentsOf: children.map(\.lastPathComponent))
        }
        let regex = try? NSRegularExpression(pattern: #"(?i)(?<![0-9a-f])[0-9a-f]{16}(?![0-9a-f])"#)
        for candidate in candidates {
            let range = NSRange(candidate.startIndex..., in: candidate)
            if let match = regex?.firstMatch(in: candidate, range: range),
               let matchRange = Range(match.range, in: candidate) {
                return String(candidate[matchRange]).uppercased()
            }
        }
        return readSwitch2ContainerMetadata(from: sourceURL, language: "en")?.titleID
    }

    private func readSwitch2ContainerMetadata(from sourceURL: URL, language: String) -> Switch2ContainerMetadata? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if sourceURL.pathExtension.lowercased() == "nup" {
            candidates = [sourceURL]
        } else if (try? sourceURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let children = try? fm.contentsOfDirectory(at: sourceURL, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            candidates = children.filter { $0.pathExtension.lowercased() == "nup" }
            if candidates.isEmpty, let dumpMetadata = readSwitch2DumpMetadata(in: sourceURL, language: language) {
                return dumpMetadata
            }
        }
        for file in candidates {
            if let metadata = readNUPMetadata(at: file, language: language) { return metadata }
        }
        return nil
    }

    private func readSwitch2DumpMetadata(in root: URL, language: String) -> Switch2ContainerMetadata? {
        let fm = FileManager.default
        var versionFolders = [root, root.appendingPathComponent("base", isDirectory: true)]
        let updates = root.appendingPathComponent("updates", isDirectory: true)
        if let updateFolders = try? fm.contentsOfDirectory(at: updates, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            versionFolders.append(contentsOf: updateFolders.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true })
        }
        var titleID: String?
        var title: String?
        var icon: DownloadedArtwork?
        for folder in versionFolders {
            let npdmCandidates = [
                folder.appendingPathComponent("exefs/main.npdm"),
                folder.appendingPathComponent("program/exefs/main.npdm")
            ]
            for npdmURL in npdmCandidates where titleID == nil {
                guard let size = (try? fm.attributesOfItem(atPath: npdmURL.path)[.size] as? NSNumber)?.uint64Value,
                      size >= 0x88, size <= 1024 * 1024,
                      let data = try? Data(contentsOf: npdmURL), data.prefix(4) == Data("META".utf8),
                      let aciOffset = Self.readLittleEndian(data, at: 0x70, as: UInt32.self).map(Int.init),
                      let aciSize = Self.readLittleEndian(data, at: 0x74, as: UInt32.self),
                      aciOffset >= 0, aciSize >= 0x18, aciOffset + 0x18 <= data.count,
                      data.subdata(in: aciOffset..<(aciOffset + 4)) == Data("ACI0".utf8),
                      let programID = Self.readLittleEndian(data, at: aciOffset + 0x10, as: UInt64.self), programID != 0 else { continue }
                titleID = String(format: "%016llX", programID)
            }

            let nacpCandidates = [folder.appendingPathComponent("control.nacp"), folder.appendingPathComponent("control/control.nacp")]
            if title == nil, let nacpURL = nacpCandidates.first(where: { fm.fileExists(atPath: $0.path) }),
               let data = try? Data(contentsOf: nacpURL) {
                title = nupTitle(from: data, language: language)
            }
            let iconCandidates = [folder.appendingPathComponent("icon.jpg"), folder.appendingPathComponent("icon.png"),
                                  folder.appendingPathComponent("control/icon.jpg"), folder.appendingPathComponent("control/icon.png")]
            if icon == nil, let iconURL = iconCandidates.first(where: { fm.fileExists(atPath: $0.path) }),
               let data = try? Data(contentsOf: iconURL), let ext = imageExtension(for: data) {
                icon = DownloadedArtwork(data: data, fileExtension: ext, sourceURL: iconURL.path)
            }
            if titleID != nil && title != nil && icon != nil { break }
        }
        guard titleID != nil || title != nil || icon != nil else { return nil }
        return Switch2ContainerMetadata(titleID: titleID, title: title, icon: icon)
    }

    private static func readLittleEndian<T: FixedWidthInteger>(_ data: Data, at offset: Int, as: T.Type) -> T? {
        let size = MemoryLayout<T>.size
        guard offset >= 0, offset + size <= data.count else { return nil }
        var value: T = 0
        for byte in 0..<size { value |= T(data[offset + byte]) << (byte * 8) }
        return value
    }

    private func readNUPMetadata(at url: URL, language: String) -> Switch2ContainerMetadata? {
        let fm = FileManager.default
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              let attributes = try? fm.attributesOfItem(atPath: url.path),
              let fileSize = (attributes[.size] as? NSNumber)?.uint64Value,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        func read(_ offset: UInt64, _ count: Int) -> Data? {
            guard count >= 0, count <= 8 * 1024 * 1024,
                  offset <= fileSize, UInt64(count) <= fileSize - offset,
                  (try? handle.seek(toOffset: offset)) != nil else { return nil }
            let data = try? handle.read(upToCount: count)
            guard let data, data.count == count else { return nil }
            return data
        }
        func littleEndian<T: FixedWidthInteger>(_ data: Data, at offset: Int, as: T.Type) -> T? {
            let size = MemoryLayout<T>.size
            guard offset >= 0, offset + size <= data.count else { return nil }
            var value: T = 0
            for byte in 0..<size { value |= T(data[offset + byte]) << (byte * 8) }
            return value
        }

        guard let header = read(0, 128), header.prefix(3) == Data("NUP".utf8),
              let tocOffset = littleEndian(header, at: 8, as: UInt64.self),
              let tocSize = littleEndian(header, at: 16, as: UInt64.self),
              let declaredSize = littleEndian(header, at: 64, as: UInt64.self),
              let packageCount = littleEndian(header, at: 72, as: UInt32.self),
              declaredSize == fileSize, packageCount > 0, packageCount <= 2048,
              tocOffset <= fileSize, tocSize <= fileSize - tocOffset,
              UInt64(48) + UInt64(packageCount) * 64 <= tocSize,
              let tocHeader = read(tocOffset, 48), tocHeader.prefix(4) == Data([0x54, 0x4f, 0x43, 0x01]),
              littleEndian(tocHeader, at: 4, as: UInt32.self) == packageCount,
              let packageTable = read(tocOffset + 48, Int(packageCount) * 64) else { return nil }

        struct PackageRecord {
            let titleID: UInt64
            let kind: UInt8
            let metadataOffset: UInt64
            let metadataSize: UInt32
        }
        var packages: [PackageRecord] = []
        for index in 0..<Int(packageCount) {
            let offset = index * 64
            guard let titleID = littleEndian(packageTable, at: offset, as: UInt64.self),
                  let kind = littleEndian(packageTable, at: offset + 24, as: UInt8.self),
                  let metadataOffset = littleEndian(packageTable, at: offset + 28, as: UInt64.self),
                  let metadataSize = littleEndian(packageTable, at: offset + 36, as: UInt32.self),
                  metadataSize <= 2 * 1024 * 1024 else { return nil }
            packages.append(PackageRecord(titleID: titleID, kind: kind, metadataOffset: metadataOffset, metadataSize: metadataSize))
        }

        let orderedPackages = packages.sorted { lhs, rhs in
            if (lhs.kind == 0) != (rhs.kind == 0) { return lhs.kind == 0 }
            return lhs.titleID < rhs.titleID
        }
        var titleID: String?
        var localTitle: String?
        var localIcon: DownloadedArtwork?
        for package in orderedPackages where package.metadataSize > 0 {
            if titleID == nil, package.titleID != 0, package.kind != 2 {
                titleID = String(format: "%016llX", package.titleID)
            }
            guard let metadata = read(package.metadataOffset, Int(package.metadataSize)) else { continue }
            var values: [UInt16: Data] = [:]
            var cursor = 0
            while cursor + 8 <= metadata.count {
                guard let type = littleEndian(metadata, at: cursor, as: UInt16.self),
                      let length = littleEndian(metadata, at: cursor + 4, as: UInt32.self) else { break }
                cursor += 8
                let payloadLength = Int(length)
                guard payloadLength <= metadata.count - cursor else { break }
                if values[type] == nil { values[type] = metadata.subdata(in: cursor..<(cursor + payloadLength)) }
                cursor += payloadLength
            }
            if localTitle == nil, let nacp = values[2] {
                localTitle = nupTitle(from: nacp, language: language)
            }
            if localIcon == nil {
                let icon = values[3] ?? values[10].flatMap { localizedNUPIcon($0, language: language) }
                if let icon, let ext = imageExtension(for: icon) {
                    localIcon = DownloadedArtwork(data: icon, fileExtension: ext, sourceURL: url.path)
                }
            }
            if localTitle != nil && localIcon != nil { break }
        }
        guard titleID != nil || localTitle != nil || localIcon != nil else { return nil }
        return Switch2ContainerMetadata(titleID: titleID, title: localTitle, icon: localIcon)
    }

    private func nupTitle(from nacp: Data, language: String) -> String? {
        guard nacp.count >= 0x300 else { return nil }
        let preferredSlots: [Int]
        switch language.lowercased() {
        case "zh-hans", "zh": preferredSlots = [14, 13]
        case "ja": preferredSlots = [2]
        case "en": preferredSlots = [0, 1]
        default: preferredSlots = []
        }
        let allSlots = preferredSlots + (0..<16).filter { !preferredSlots.contains($0) }
        for slot in allSlots where slot * 0x300 < nacp.count {
            let start = slot * 0x300
            let end = min(start + 0x200, nacp.count)
            guard start < end else { continue }
            let bytes = nacp.subdata(in: start..<end).prefix { $0 != 0 }
            guard let value = String(data: Data(bytes), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty, value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { continue }
            return value
        }
        return nil
    }

    private func localizedNUPIcon(_ data: Data, language: String) -> Data? {
        var records: [(String, Data)] = []
        var cursor = 0
        while cursor < data.count {
            let tagLength = Int(data[cursor]); cursor += 1
            guard tagLength > 0, cursor + tagLength + 4 <= data.count,
                  let tag = String(data: data[cursor..<(cursor + tagLength)], encoding: .utf8) else { return nil }
            cursor += tagLength
            let count = Int(data[cursor]) | (Int(data[cursor + 1]) << 8) | (Int(data[cursor + 2]) << 16) | (Int(data[cursor + 3]) << 24)
            cursor += 4
            guard count >= 0, count <= data.count - cursor else { return nil }
            records.append((tag.lowercased(), data.subdata(in: cursor..<(cursor + count))))
            cursor += count
        }
        let requested = language.lowercased()
        let tags: [String]
        if requested.hasPrefix("zh-hans") || requested == "zh" { tags = ["zh-hans", "zh"] }
        else if requested.hasPrefix("zh-hant") { tags = ["zh-hant"] }
        else if requested.hasPrefix("ja") { tags = ["ja"] }
        else { tags = ["en-us", "en-gb", "en"] }
        for tag in tags {
            if let icon = records.first(where: { $0.0 == tag })?.1 { return icon }
        }
        return records.first?.1
    }

    private func imageExtension(for data: Data) -> String? {
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "png" }
        return nil
    }

    private func wikipediaResult(for title: String, language: String, localizedTitle: String? = nil) async -> WikipediaGamePage? {
        if language == "en" { return await searchWikipedia(language: "en", title: title) }
        let query = localizedTitle.flatMap { GameTitleMatcher.hasHan($0) ? $0 : nil } ?? title
        async let preferredLookup = searchWikipedia(language: language, title: query)
        async let englishLookup = searchWikipedia(language: "en", title: title)
        let (preferredPage, englishPage) = await (preferredLookup, englishLookup)
        let linkedPreferredPage: WikipediaGamePage?
        if preferredPage == nil, let englishPage {
            linkedPreferredPage = await wikipediaLanguageLinkPage(from: englishPage.title, language: language)
        } else { linkedPreferredPage = nil }
        guard let preferredPage = preferredPage ?? linkedPreferredPage else { return englishPage }

        // Boxart catalogues are romanized; the English article title is the
        // key into them. When the direct English search missed (the cleaned
        // name was Chinese), read the language link off the matched page.
        let englishTitle: String?
        if let direct = englishPage?.title {
            englishTitle = direct
        } else {
            englishTitle = await wikipediaEnglishTitle(from: preferredPage.title, language: language)
        }
        return WikipediaGamePage(
            title: language == "zh" ? simplifiedChineseTitle(in: preferredPage.synopsis) ?? preferredPage.title : preferredPage.title,
            synopsis: preferredPage.synopsis ?? englishPage?.synopsis,
            pageURL: preferredPage.pageURL,
            artworkURL: preferredPage.artworkURL ?? englishPage?.artworkURL,
            alternateTitle: englishTitle
        )
    }

    private func wikipediaEnglishTitle(from pageTitle: String, language: String) async -> String? {
        guard var components = URLComponents(string: "https://\(language).wikipedia.org/w/api.php") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "prop", value: "langlinks"),
            URLQueryItem(name: "titles", value: pageTitle),
            URLQueryItem(name: "lllang", value: "en"),
            URLQueryItem(name: "lllimit", value: "1"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "formatversion", value: "2")
        ]
        guard let url = components.url,
              let data = try? await download(url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let query = root["query"] as? [String: Any],
              let pages = query["pages"] as? [[String: Any]],
              let linkedTitle = pages.first?["langlinks"] as? [[String: Any]],
              let english = linkedTitle.first?["title"] as? String else { return nil }
        return english
    }

    // MARK: Baidu Baike

    private struct BaikePage {
        let title: String
        let synopsis: String
        let pageURL: URL
        let artworkURL: URL?
        let latinTitle: String?
    }

    private static let baikeUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    /// Baidu Baike covers Chinese-context games Wikipedia misses — regional
    /// releases, Chinese translations and ROM hacks — and its image CDN is
    /// reachable where upload.wikimedia.org is not. The mobile endpoints
    /// serve plain HTML; an unknown lemma is resolved through the search page.
    private func baikeLookupTask(title: String, filenameTitle: String?, language: String) async -> BaikePage? {
        guard language == "zh" else { return nil }
        let candidate = filenameTitle ?? title
        guard GameTitleMatcher.hasHan(candidate) else { return nil }
        return await baikePage(for: candidate)
    }

    private func baikePage(for title: String) async -> BaikePage? {
        trace("baike: query \(title)")
        if let page = await baikeDirectPage(for: title) { return page }
        // Release names rarely match a lemma verbatim. Search the full name
        // and then each of its words, and keep the result whose title overlaps
        // the game name most, so a franchise tag such as "口袋妖怪改版" cannot
        // settle for the generic series page.
        var queries = [title]
        queries += title.split(separator: " ").map(String.init).filter { GameTitleMatcher.hasHan($0) && $0.count >= 3 }
        var best: (page: BaikePage, overlap: Int)?
        var seen = Set<String>()
        var fetched = 0
        nextQuery: for query in queries {
            // Result links live in the searchList container; other /item/
            // hrefs on the page are footer navigation (user agreements and
            // the like) and must not be followed.
            guard fetched < 8,
                  let search = baikeSearchURL(for: query),
                  let data = try? await download(search, userAgent: Self.baikeUserAgent),
                  let html = String(data: data, encoding: .utf8),
                  let list = html.range(of: #"id="searchList""#, options: .regularExpression),
                  let regex = try? NSRegularExpression(pattern: #"/item/([^"?]+)/\d+"#) else { continue }
            let results = String(html[list.lowerBound...])
            for match in regex.matches(in: results, range: NSRange(results.startIndex..., in: results)).prefix(4) {
                guard fetched < 8 else { break nextQuery }
                guard let captured = Range(match.range(at: 1), in: results),
                      let lemma = baikeLemmaURL(String(results[captured])),
                      seen.insert(lemma.path).inserted else { continue }
                fetched += 1
                guard let page = await baikePage(at: lemma) else { continue }
                let overlap = Self.hanBigramOverlap(page.title, title)
                trace("baike: candidate \(page.title) for \(title) · \(overlap.count) bigrams, \(Int(overlap.ratio * 100))%")
                if overlap.count >= 3, overlap.ratio >= 0.6, overlap.count > (best?.overlap ?? 0) {
                    best = (page, overlap.count)
                }
            }
        }
        return best?.page
    }

    /// A lemma named exactly like the game resolves directly.
    private func baikeDirectPage(for title: String) async -> BaikePage? {
        guard let url = baikeLemmaURL(title) else { return nil }
        guard let page = await baikePage(at: url), Self.sharesHan(page.title, title) else { return nil }
        return page
    }

    private func baikeSearchURL(for query: String) -> URL? {
        // /search/word answers with a redirect to plain http, which App
        // Transport Security refuses; /search/none is the same page over https.
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "https://wapbaike.baidu.com/search/none?word=" + encoded)
    }

    /// Search results carry percent-encoded paths. Decode before encoding
    /// once; re-encoding them as they come doubles the escapes and misses.
    private func baikeLemmaURL(_ href: String) -> URL? {
        let path = href.removingPercentEncoding ?? href
        guard let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: "https://wapbaike.baidu.com/item/" + encoded)
    }

    private func baikePage(at url: URL) async -> BaikePage? {
        guard let data = try? await download(url, userAgent: Self.baikeUserAgent),
              let html = String(data: data, encoding: .utf8),
              let title = Self.firstCapture(in: html, pattern: #"og:title" content="([^"]+)"#).flatMap(Self.unescapeHTML),
              let synopsis = Self.firstCapture(in: html, pattern: #"name="description" content="([^"]+)"#).flatMap(Self.unescapeHTML),
              synopsis.count >= 20 else {
            trace("baike: lemma miss \(url.path.prefix(60))")
            return nil
        }
        let cover = Self.firstCapture(in: html, pattern: #"bkimg\.cdn\.bcebos\.com/smart/([0-9a-f]+)"#)
            .flatMap { hash in URL(string: "https://bkimg.cdn.bcebos.com/pic/\(hash)?x-bce-process=image/resize,m_lfit,w_1200/quality,Q_85") }
        let latin = Self.longestLatinRun(in: title + " " + synopsis)
        return BaikePage(title: title, synopsis: synopsis, pageURL: url, artworkURL: cover, latinTitle: latin)
    }

    /// How much of the lemma title is covered by character pairs of the game
    /// name. Chinese has no word boundaries, so bigram overlap is the signal.
    private static func hanBigramOverlap(_ lemma: String, _ title: String) -> (count: Int, ratio: Double) {
        let needle = hanBigrams(lemma), haystack = hanBigrams(title)
        let count = needle.intersection(haystack).count
        return (count, needle.isEmpty ? 0 : Double(count) / Double(needle.count))
    }

    private static func hanBigrams(_ text: String) -> Set<String> {
        let han = text.unicodeScalars.filter { (0x3400...0x9fff).contains($0.value) }.map(Character.init)
        return Set(zip(han, han.dropFirst()).map { String([$0, $1]) })
    }

    private static func sharesHan(_ left: String, _ right: String) -> Bool {
        let han = Set(right.unicodeScalars.filter { (0x3400...0x9fff).contains($0.value) })
        guard !han.isEmpty else { return true }
        return left.unicodeScalars.contains { han.contains($0) }
    }

    private static func firstCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let captured = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[captured])
    }

    private static func unescapeHTML(_ value: String) -> String {
        var result = value.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
        if let regex = try? NSRegularExpression(pattern: #"&#(x[0-9A-Fa-f]+|\d+);"#) {
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed()
            for match in matches {
                guard let fullRange = Range(match.range, in: result),
                      let codeRange = Range(match.range(at: 1), in: result) else { continue }
                let token = String(result[codeRange])
                let codePoint: UInt32?
                if token.hasPrefix("x") || token.hasPrefix("X") {
                    codePoint = UInt32(token.dropFirst(), radix: 16)
                } else {
                    codePoint = UInt32(token, radix: 10)
                }
                if let cp = codePoint, let scalar = UnicodeScalar(cp) {
                    result.replaceSubrange(fullRange, with: String(scalar))
                }
            }
        }
        return result
    }

    private static func longestLatinRun(in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"[A-Za-z][A-Za-z0-9'’:&!? ]{5,60}[A-Za-z!?]"#) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        let candidate = regex.matches(in: text, range: range)
            .compactMap { Range($0.range, in: text).map { String(text[$0]) } }
            .filter { run in
                let letters = run.filter(\.isLetter)
                return letters.count >= 5 && letters.count * 10 >= run.count * 6
            }
            .max { $0.count < $1.count }
        return candidate?.trimmingCharacters(in: .whitespaces)
    }

    private func simplifiedChineseTitle(in synopsis: String?) -> String? {
        guard let synopsis else { return nil }
        let pattern = #"《([^》]{2,80})》"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: synopsis, range: NSRange(synopsis.startIndex..., in: synopsis)),
              let range = Range(match.range(at: 1), in: synopsis) else { return nil }
        return String(synopsis[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func wikipediaLanguageLinkPage(from englishTitle: String, language: String) async -> WikipediaGamePage? {
        guard var components = URLComponents(string: "https://en.wikipedia.org/w/api.php") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "prop", value: "langlinks"),
            URLQueryItem(name: "titles", value: englishTitle),
            URLQueryItem(name: "lllang", value: language),
            URLQueryItem(name: "lllimit", value: "1"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "formatversion", value: "2")
        ]
        guard let url = components.url,
              let data = try? await download(url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let query = root["query"] as? [String: Any],
              let pages = query["pages"] as? [[String: Any]],
              let linkedTitle = pages.first?["langlinks"] as? [[String: Any]],
              let translatedTitle = linkedTitle.first?["title"] as? String else { return nil }

        guard var articleComponents = URLComponents(string: "https://\(language).wikipedia.org/w/api.php") else { return nil }
        articleComponents.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "titles", value: translatedTitle),
            URLQueryItem(name: "redirects", value: "1"),
            URLQueryItem(name: "prop", value: "extracts|pageimages|info"),
            URLQueryItem(name: "exintro", value: "1"),
            URLQueryItem(name: "explaintext", value: "1"),
            URLQueryItem(name: "inprop", value: "url"),
            URLQueryItem(name: "piprop", value: "thumbnail|original"),
            URLQueryItem(name: "pithumbsize", value: "2560"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "formatversion", value: "2")
        ]
        if language == "zh" {
            articleComponents.queryItems?.append(URLQueryItem(name: "variant", value: "zh-cn"))
        }
        guard let articleURL = articleComponents.url,
              let articleData = try? await download(articleURL),
              let articleRoot = try? JSONSerialization.jsonObject(with: articleData) as? [String: Any],
              let articleQuery = articleRoot["query"] as? [String: Any],
              let articlePages = articleQuery["pages"] as? [[String: Any]],
              let article = articlePages.first else { return nil }
        return wikipediaPage(from: article)
    }

    private func searchWikipedia(language: String, title: String) async -> WikipediaGamePage? {
        guard var components = URLComponents(string: "https://\(language).wikipedia.org/w/api.php") else {
            return nil
        }
        components.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "generator", value: "search"),
            URLQueryItem(name: "gsrsearch", value: title),
            URLQueryItem(name: "gsrlimit", value: "6"),
            URLQueryItem(name: "prop", value: "extracts|pageimages|info"),
            URLQueryItem(name: "exintro", value: "1"),
            URLQueryItem(name: "explaintext", value: "1"),
            URLQueryItem(name: "inprop", value: "url"),
            URLQueryItem(name: "piprop", value: "thumbnail|original"),
            URLQueryItem(name: "pithumbsize", value: "2560"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "formatversion", value: "2")
        ]
        guard let url = components.url,
              let data = try? await download(url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let query = root["query"] as? [String: Any],
              let pages = query["pages"] as? [[String: Any]] else {
            return nil
        }

        let best = pages
            .compactMap { page -> (score: Double, page: [String: Any])? in
                guard let pageTitle = page["title"] as? String else { return nil }
                let alias = simplifiedChineseTitle(in: page["extract"] as? String)
                return (max(matchScore(title, pageTitle), alias.map { matchScore(title, $0) } ?? 0), page)
            }
            .max { $0.score < $1.score }

        guard let best, best.score >= minimumWikipediaMatchScore(for: title) else {
            return nil
        }

        return wikipediaPage(from: best.page)
    }

    private func wikipediaPage(from page: [String: Any]) -> WikipediaGamePage? {
        guard let pageTitle = page["title"] as? String else { return nil }
        let rawSynopsis = page["extract"] as? String
        let synopsis = rawSynopsis.map(cleanSynopsis).flatMap { $0.isEmpty ? nil : $0 }
        let thumbnail = page["thumbnail"] as? [String: Any]
        let original = page["original"] as? [String: Any]
        let originalWidth = original?["width"] as? Int ?? 0
        let originalHeight = original?["height"] as? Int ?? 0
        let originalURL = original?["source"] as? String
        let thumbnailURL = thumbnail?["source"] as? String
        let selectedArtworkURL = (max(originalWidth, originalHeight) <= 4096 ? originalURL : nil) ?? thumbnailURL
        let pageURL = page["canonicalurl"] as? String
        return WikipediaGamePage(
            title: pageTitle,
            synopsis: synopsis,
            pageURL: pageURL,
            artworkURL: selectedArtworkURL.flatMap(URL.init(string:)),
            alternateTitle: nil
        )
    }

    private func boxartData(for title: String, platform: GameMetadataPlatform, language: String) async -> DownloadedArtwork? {
        if platform == .switchConsole {
            return await switchBoxartData(for: title, language: language)
        }
        guard platform.isRetroConsole,
              let match = await closestBoxart(to: title, platform: platform),
              let encoded = match.filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: encoded, relativeTo: match.source)?.absoluteURL else {
            return nil
        }
        // The libretro host is intermittently reachable: a listing that came
        // through may still be followed by failing file downloads. Fall back
        // to the raw.githubusercontent mirror for the bytes themselves.
        if let data = try? await download(url) {
            return DownloadedArtwork(data: data, fileExtension: url.pathExtension.isEmpty ? "png" : url.pathExtension, sourceURL: url.absoluteString)
        }
        guard let mirror = mirrorArtworkURL(for: encoded, platform: platform, snaps: false),
              let data = try? await download(mirror) else { return nil }
        return DownloadedArtwork(data: data, fileExtension: mirror.pathExtension.isEmpty ? "png" : mirror.pathExtension, sourceURL: mirror.absoluteString)
    }

    private func mirrorArtworkURL(for encodedFilename: String, platform: GameMetadataPlatform, snaps: Bool) -> URL? {
        guard let systemFolder = retroSystemFolder(for: platform) else { return nil }
        let repository = systemFolder.replacingOccurrences(of: " ", with: "_")
        let directory = snaps ? "Named_Snaps" : "Named_Boxarts"
        return URL(string: "https://raw.githubusercontent.com/libretro-thumbnails/\(repository)/master/\(directory)/\(encodedFilename)")
    }

    private func switchBoxartData(for title: String, language: String) async -> DownloadedArtwork? {
        let catalogLanguage: String
        let coverLanguage: String
        switch language {
        case "ja": catalogLanguage = "JA"; coverLanguage = "JA"
        case "zh", "zh-Hans": catalogLanguage = "ZHCN"; coverLanguage = "ZH"
        default: catalogLanguage = "EN"; coverLanguage = "EN"
        }

        let entries: [(id: String, title: String)]
        if let cached = switchCatalogs[catalogLanguage] {
            entries = cached
        } else {
            guard let url = URL(string: "https://www.gametdb.com/switchtdb.txt?LANG=\(catalogLanguage)"),
                  let data = try? await download(url),
                  let text = String(data: data, encoding: .utf8) else { return nil }
            entries = text.split(whereSeparator: \.isNewline).compactMap { line in
                guard let separator = line.range(of: " = ") else { return nil }
                let id = String(line[..<separator.lowerBound]).trimmingCharacters(in: .whitespaces)
                let name = String(line[separator.upperBound...]).trimmingCharacters(in: .whitespaces)
                guard id.range(of: #"^[A-Za-z0-9]{5}$"#, options: .regularExpression) != nil, !name.isEmpty else { return nil }
                return (id: id, title: name)
            }
            guard !entries.isEmpty else { return nil }
            switchCatalogs[catalogLanguage] = entries
        }

        let candidate = entries
            .map { (entry: $0, score: matchScore(title, $0.title)) }
            .max { $0.score < $1.score }
        guard let candidate, candidate.score >= max(0.82, minimumMatchScore(for: title)) else { return nil }

        var regions: [String] = []
        for region in [coverLanguage, "EN", "US"] where !regions.contains(region) {
            regions.append(region)
        }
        for coverType in ["coverHQ", "cover"] {
            for region in regions {
                guard let url = URL(string: "https://art.gametdb.com/switch/\(coverType)/\(region)/\(candidate.entry.id).jpg"),
                      let data = try? await download(url), pixelArea(data) > 0 else { continue }
                return DownloadedArtwork(data: data, fileExtension: "jpg", sourceURL: url.absoluteString)
            }
        }
        return nil
    }

    private func closestBoxart(to title: String, platform: GameMetadataPlatform) async -> (filename: String, source: URL)? {
        let filenames: [String]
        if let cached = artworkCatalogs[platform] {
            filenames = cached
        } else {
            filenames = await boxartCatalog(platform: platform, snaps: false)
            if !filenames.isEmpty { artworkCatalogs[platform] = filenames }
        }
        let source = artworkCatalogSources[platform] ?? boxartIndexURL(for: platform)

        let match = filenames
            .map { (filename: $0, score: matchScore(title, $0)) }
            .max { $0.score < $1.score }
        guard let match, match.score >= minimumMatchScore(for: title),
              let source else { return nil }
        return (match.filename, source)
    }

    /// The libretro thumbnail index is unreachable from some networks. Fall
    /// back to the GitHub mirror through jsDelivr, which serves the same
    /// Named_Boxarts / Named_Snaps trees one system per repository.
    private func boxartCatalog(platform: GameMetadataPlatform, snaps: Bool) async -> [String] {
        if let indexURL = snaps ? screenshotIndexURL(for: platform) : boxartIndexURL(for: platform),
           let data = try? await download(indexURL),
           let html = String(data: data, encoding: .utf8) {
            let filenames = boxartFilenames(in: html)
            if !filenames.isEmpty {
                if snaps { screenshotCatalogSources[platform] = indexURL }
                else { artworkCatalogSources[platform] = indexURL }
                return filenames
            }
        }
        guard let systemFolder = retroSystemFolder(for: platform) else { return [] }
        let repository = systemFolder.replacingOccurrences(of: " ", with: "_")
        let directory = snaps ? "Named_Snaps" : "Named_Boxarts"
        // The GitHub mirror keeps one system per repository. Walk the root tree
        // to the artwork directory, then list its blobs; files come straight
        // from raw.githubusercontent.com — jsDelivr resolves these tagless
        // repositories unreliably.
        let trees = "https://api.github.com/repos/libretro-thumbnails/\(repository)/git/trees"
        guard let rootURL = URL(string: trees + "/master"),
              let rootData = try? await download(rootURL),
              let rootJSON = try? JSONSerialization.jsonObject(with: rootData) as? [String: Any],
              let rootTree = rootJSON["tree"] as? [[String: Any]],
              let directorySHA = rootTree.first(where: { $0["path"] as? String == directory })?["sha"] as? String,
              let subtreeURL = URL(string: trees + "/" + directorySHA),
              let subtreeData = try? await download(subtreeURL),
              let subtreeJSON = try? JSONSerialization.jsonObject(with: subtreeData) as? [String: Any],
              let entries = subtreeJSON["tree"] as? [[String: Any]] else { return [] }
        let filenames = entries.compactMap { entry -> String? in
            guard let path = entry["path"] as? String, path.lowercased().hasSuffix(".png") else { return nil }
            return path
        }
        if !filenames.isEmpty {
            let base = URL(string: "https://raw.githubusercontent.com/libretro-thumbnails/\(repository)/master/\(directory)/")
            if snaps { screenshotCatalogSources[platform] = base } else { artworkCatalogSources[platform] = base }
        }
        return filenames
    }

    private func retroScreenshot(for title: String, platform: GameMetadataPlatform) async -> DownloadedArtwork? {
        guard platform.isRetroConsole else { return nil }
        let filenames: [String]
        if let cached = screenshotCatalogs[platform] {
            filenames = cached
        } else {
            filenames = await boxartCatalog(platform: platform, snaps: true)
            if !filenames.isEmpty { screenshotCatalogs[platform] = filenames }
        }
        let source = screenshotCatalogSources[platform] ?? screenshotIndexURL(for: platform)

        let match = filenames
            .map { (filename: $0, score: matchScore(title, $0)) }
            .max { $0.score < $1.score }
        guard let match, match.score >= minimumMatchScore(for: title),
              let source,
              let encoded = match.filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: encoded, relativeTo: source)?.absoluteURL else { return nil }
        var data = try? await download(url)
        if data == nil, let mirror = mirrorArtworkURL(for: encoded, platform: platform, snaps: true) {
            data = try? await download(mirror)
        }
        guard let data, aspectRatio(data) >= 1.3 else { return nil }
        return DownloadedArtwork(data: data, fileExtension: url.pathExtension.isEmpty ? "png" : url.pathExtension, sourceURL: url.absoluteString)
    }

    private func boxartFilenames(in html: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"href=[\"']([^\"']+\.png)[\"']"#,
            options: [.caseInsensitive]
        ) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        return regex.matches(in: html, range: range).compactMap { match in
            guard let matchRange = Range(match.range(at: 1), in: html) else { return nil }
            let link = String(html[matchRange])
            guard let filename = URL(string: link)?.lastPathComponent.removingPercentEncoding,
                  !filename.isEmpty else { return nil }
            return filename
        }
    }

    private func retroSystemFolder(for platform: GameMetadataPlatform) -> String? {
        switch platform {
        case .gba: return "Nintendo - Game Boy Advance"
        case .gb: return "Nintendo - Game Boy"
        case .gbc: return "Nintendo - Game Boy Color"
        case .nds: return "Nintendo - Nintendo DS"
        case .threeDS: return "Nintendo - Nintendo 3DS"
        case .psp: return "Sony - PlayStation Portable"
        case .famicom: return "Nintendo - Nintendo Entertainment System"
        case .superFamicom: return "Nintendo - Super Nintendo Entertainment System"
        case .n64: return "Nintendo - Nintendo 64"
        case .megaDrive: return "Sega - Mega Drive - Genesis"
        case .ps1: return "Sony - PlayStation"
        case .ps2: return "Sony - PlayStation 2"
        case .ps3: return "Sony - PlayStation 3"
        case .psv: return "Sony - PlayStation Vita"
        case .wii: return "Nintendo - Wii"
        case .wiiu: return "Nintendo - Wii U"
        default: return nil
        }
    }

    private func boxartIndexURL(for platform: GameMetadataPlatform) -> URL? {
        guard let systemFolder = retroSystemFolder(for: platform) else { return nil }
        let encodedFolder = systemFolder.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? systemFolder
        return URL(string: "https://thumbnails.libretro.com/\(encodedFolder)/Named_Boxarts/")
    }

    private func screenshotIndexURL(for platform: GameMetadataPlatform) -> URL? {
        guard let systemFolder = retroSystemFolder(for: platform) else { return nil }
        let encodedFolder = systemFolder.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? systemFolder
        return URL(string: "https://thumbnails.libretro.com/\(encodedFolder)/Named_Snaps/")
    }

    private func download(_ url: URL, userAgent: String? = nil) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 18
        request.setValue(userAgent ?? "GameCenter/0.2 (game library)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, text/html, image/*", forHTTPHeaderField: "Accept")
        trace("GET " + url.absoluteString)
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { trace("FAILED \(url.host ?? "") \(error.localizedDescription)"); throw error }
        trace("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0) \(data.count) bytes \(url.host ?? "")")
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private func pixelDimensions(_ data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        return (width, height)
    }

    private func pixelArea(_ data: Data) -> Int {
        guard let dims = pixelDimensions(data) else { return 0 }
        return dims.width * dims.height
    }

    private func aspectRatio(_ data: Data) -> Double {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              height > 0 else { return 0 }
        return Double(width) / Double(height)
    }

    private func normalize(_ value: String) -> String { GameTitleMatcher.normalize(value) }
    private func matchScore(_ source: String, _ candidate: String) -> Double { GameTitleMatcher.score(source, candidate) }
    private func minimumMatchScore(for title: String) -> Double { GameTitleMatcher.threshold(title) }
    private func minimumWikipediaMatchScore(for title: String) -> Double { GameTitleMatcher.threshold(title, wikipedia: true) }

    private func cleanSynopsis(_ synopsis: String) -> String {
        let flattened = synopsis.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flattened.count > 650 else { return flattened }
        let limit = flattened.index(flattened.startIndex, offsetBy: 650)
        let prefix = String(flattened[..<limit])
        if let end = prefix.lastIndex(where: { ".。！？!?".contains($0) }) {
            return String(prefix[...end])
        }
        return prefix + "…"
    }
}

private struct WikipediaGamePage {
    let title: String
    let synopsis: String?
    let pageURL: String?
    let artworkURL: URL?
    var alternateTitle: String? = nil
}

private struct Switch2ContainerMetadata {
    let titleID: String?
    let title: String?
    let icon: DownloadedArtwork?
}

private struct KnownSwitchGameMetadata {
    let title: String
    let synopsis: String
    let artworkURL: URL?
    let backdropURL: URL?
    let sourceURL: String
}

private struct SwitchTitleMetadata: Sendable {
    let title: String?
    let synopsis: String?
    let iconURL: String?
    let sourceURL: String
}

private struct DownloadedArtwork {
    let data: Data
    let fileExtension: String
    let sourceURL: String
}
