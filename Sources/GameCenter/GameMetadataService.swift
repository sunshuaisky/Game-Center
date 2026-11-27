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
    let backdropSourceURL: String?

    init(
        title: String?,
        synopsis: String?,
        metadataSourceURL: String?,
        artworkData: Data?,
        artworkExtension: String?,
        artworkSourceURL: String?,
        backdropData: Data?,
        backdropSourceURL: String? = nil
    ) {
        self.title = title
        self.synopsis = synopsis
        self.metadataSourceURL = metadataSourceURL
        self.artworkData = artworkData
        self.artworkExtension = artworkExtension
        self.artworkSourceURL = artworkSourceURL
        self.backdropData = backdropData
        self.backdropSourceURL = backdropSourceURL
    }

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
        self.session = session ?? Self.networkSession
        self.trace = trace
    }

    private var artworkCatalogs: [String: [(filename: String, normalized: String)]] = [:]
    private var artworkCatalogTasks: [String: Task<[(filename: String, normalized: String)], Never>] = [:]
    private var artworkCatalogSources: [String: URL] = [:]
    private var gameTDBCatalogs: [String: [(id: String, title: String, normalized: String)]] = [:]
    private var gameTDBCatalogTasks: [String: Task<[(id: String, title: String, normalized: String)], Never>] = [:]
    private var switchCatalogs: [String: [(id: String, title: String, normalized: String)]] = [:]
    private var switchCatalogTasks: [String: Task<[(id: String, title: String, normalized: String)], Never>] = [:]

    private static let boxartHrefRegex = try! NSRegularExpression(pattern: #"href=[\"']([^\"']+\.png)[\"']"#, options: [.caseInsensitive])
    private static let whitespaceRegex = try! NSRegularExpression(pattern: #"\s+"#)
    private static let browserUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    private static let bangumiUserAgent = "GameCenter/0.2 (https://github.com/phoenixicarus/gamecenter)"
    private static let baikeUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    func lookup(
        title: String,
        platform: GameMetadataPlatform,
        language: String,
        sourceURL: URL?,
        titleID explicitTitleID: String? = nil,
        onText: @escaping @Sendable (GameMetadataResult) async -> Void = { _ in },
        onBackdrop: @escaping @Sendable (Data) async -> Void = { _ in }
    ) async -> GameMetadataResult {
        let localMeta = sourceURL.flatMap { readLocalGameMetadata(from: $0, platform: platform, language: language) }
        let switch2Metadata = platform == .switchConsole
            ? sourceURL.flatMap { readSwitch2ContainerMetadata(from: $0, language: language) }
            : nil
        let validatedExplicitID = MetadataRefreshPolicy.normalizedSwitchTitleID(explicitTitleID)
        let titleID = platform == .switchConsole
            ? (validatedExplicitID ?? sourceURL.flatMap(switchTitleID(from:)) ?? switch2Metadata?.titleID)
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

        let searchTitle = codeMetadata?.title
            ?? switch2Metadata?.title
            ?? knownSwitchMetadata?.title
            ?? localMeta?.title
            ?? filenameTitle
            ?? title
        let aliasHint = Self.chineseFranchiseHint(
            for: [title, filenameTitle, searchTitle, localMeta?.title].compactMap { $0 }.joined(separator: " "),
            platform: platform
        )
        let effectiveSearchTitle = aliasHint?.zh ?? searchTitle

        // Stage 1: Fetch text/identity metadata + Switch 1080p banner in parallel.
        async let wikiTask = wikipediaResult(
            for: effectiveSearchTitle,
            language: language,
            localizedTitle: filenameTitle ?? effectiveSearchTitle
        )
        async let bangumiTask = bangumiLookup(
            queries: Self.deduplicatedQueries([aliasHint?.zh, filenameTitle, searchTitle, aliasHint?.en, title]),
            platform: platform,
            language: language
        )
        async let baikeTask = baikeLookupTask(title: effectiveSearchTitle, filenameTitle: filenameTitle, language: language)
        async let bannerTask = switchBanner(titleID: titleID, platform: platform)

        var wiki = await wikiTask
        let bangumi = await bangumiTask
        let baike = await baikeTask

        // Stage 1.5: If Wikipedia missed on the raw/colloquial filename, cross-enrich
        // using canonical titles discovered by Bangumi or Baidu Baike.
        if wiki == nil {
            let enrichmentTitle = bangumi?.englishTitle ?? baike?.latinTitle ?? aliasHint?.en
            let enrichmentLocalized = bangumi?.chineseTitle ?? baike?.title
            if let query = enrichmentTitle ?? enrichmentLocalized,
               normalize(query) != normalize(effectiveSearchTitle) {
                wiki = await wikipediaResult(for: query, language: language, localizedTitle: enrichmentLocalized)
            }
        }

        var resolvedTitle: String?
        if language == "en" {
            resolvedTitle = codeMetadata?.title
                ?? wiki?.title
                ?? knownSwitchMetadata?.title
                ?? switch2Metadata?.title
                ?? bangumi?.englishTitle
                ?? aliasHint?.en
                ?? localMeta?.title
        } else if language == "ja" {
            resolvedTitle = wiki?.title
                ?? codeMetadata?.title
                ?? knownSwitchMetadata?.title
                ?? switch2Metadata?.title
                ?? bangumi?.originalTitle
                ?? bangumi?.chineseTitle
                ?? localMeta?.title
        } else {
            resolvedTitle = wiki?.title
                ?? knownSwitchMetadata?.title
                ?? switch2Metadata?.title
                ?? codeMetadata?.title
                ?? bangumi?.chineseTitle
                ?? baike?.title
                ?? aliasHint?.zh
                ?? localMeta?.title
        }

        var resolvedSynopsis: String?
        if language == "en" {
            resolvedSynopsis = codeMetadata?.synopsis
                ?? wiki?.synopsis
                ?? knownSwitchMetadata?.synopsis
        } else if language == "ja" {
            resolvedSynopsis = wiki?.synopsis
                ?? codeMetadata?.synopsis
                ?? knownSwitchMetadata?.synopsis
        } else {
            resolvedSynopsis = wiki?.synopsis
                ?? codeMetadata?.synopsis
                ?? knownSwitchMetadata?.synopsis
                ?? bangumi?.synopsis
                ?? baike?.synopsis
        }

        var resolvedSourceURL = wiki?.pageURL
            ?? bangumi?.pageURL
            ?? baike?.pageURL.absoluteString
            ?? codeMetadata?.sourceURL
            ?? knownSwitchMetadata?.sourceURL

        let initialText = GameMetadataResult(
            title: resolvedTitle,
            synopsis: resolvedSynopsis,
            metadataSourceURL: resolvedSourceURL,
            artworkData: nil,
            artworkExtension: nil,
            artworkSourceURL: nil,
            backdropData: nil
        )
        if initialText.hasMetadata { await onText(initialText) }

        let banner = await bannerTask
        if let banner { await onBackdrop(banner.data) }

        // Build deduplicated candidates for dedicated game media databases.
        let cleanWikiAlternate: String? = (wiki?.alternateTitle).map(Self.stripWikipediaDisambiguator)
        let cleanWikiTitle: String? = wiki.map { Self.stripWikipediaDisambiguator($0.title) }
        let allCandidates = Self.deduplicatedQueries([
            aliasHint?.en,
            cleanWikiAlternate,
            bangumi?.englishTitle,
            baike?.latinTitle,
            codeMetadata?.title,
            localMeta?.title,
            cleanWikiTitle,
            bangumi?.chineseTitle,
            bangumi?.originalTitle,
            searchTitle,
            filenameTitle,
            title
        ])
        let englishCandidates = allCandidates.filter { !GameTitleMatcher.hasHan($0) && !GameTitleMatcher.hasKana($0) }
        let localizedCandidates = allCandidates.filter { GameTitleMatcher.hasHan($0) || GameTitleMatcher.hasKana($0) }
        let needsFallbackSynopsis = resolvedSynopsis == nil

        // Stage 2: Query LaunchBox GamesDB & Steam in parallel.
        async let launchBoxTask: LaunchBoxMediaResult? = {
            for candidateTitle in englishCandidates.prefix(4) {
                if let res = await self.launchBoxMedia(
                    for: candidateTitle,
                    platform: platform,
                    language: language,
                    fetchSynopsisIfNeeded: needsFallbackSynopsis
                ) {
                    return res
                }
            }
            return nil
        }()

        async let steamTask: SteamMediaResult? = {
            for candidateTitle in englishCandidates.prefix(3) {
                if let res = await self.steamMedia(for: candidateTitle, platform: platform, language: language) {
                    return res
                }
            }
            if language == "zh" || language == "ja" {
                for candidateTitle in localizedCandidates.prefix(2) {
                    if let res = await self.steamMedia(for: candidateTitle, platform: platform, language: language) {
                        return res
                    }
                }
            }
            return nil
        }()

        let launchBox = await launchBoxTask
        let steamResult = await steamTask

        // Enrich missing title / synopsis from Steam or LaunchBox when encyclopedias missed.
        var textEnriched = false
        if resolvedTitle == nil, let fallbackTitle = steamResult?.title ?? launchBox?.title {
            resolvedTitle = fallbackTitle
            textEnriched = true
        }
        if resolvedSynopsis == nil, let fallbackSynopsis = steamResult?.synopsis ?? launchBox?.synopsis {
            resolvedSynopsis = fallbackSynopsis
            textEnriched = true
        }
        if resolvedSourceURL == nil {
            resolvedSourceURL = steamResult?.sourceURL ?? launchBox?.sourceURL
        }
        if textEnriched {
            let enrichedText = GameMetadataResult(
                title: resolvedTitle,
                synopsis: resolvedSynopsis,
                metadataSourceURL: resolvedSourceURL,
                artworkData: nil,
                artworkExtension: nil,
                artworkSourceURL: nil,
                backdropData: nil
            )
            if enrichedText.hasMetadata { await onText(enrichedText) }
        }

        // Stage 3: Tiered cover selection (dedicated game covers always take priority
        // over encyclopedia thumbnails so movie/anime posters never replace real box art).
        var primaryCoverCandidates: [DownloadedArtwork] = []
        if let lbCover = launchBox?.cover { primaryCoverCandidates.append(lbCover) }
        if let steamCover = steamResult?.cover { primaryCoverCandidates.append(steamCover) }
        if let icon = switch2Metadata?.icon { primaryCoverCandidates.append(icon) }

        var knownArtwork: DownloadedArtwork?
        if let artworkURL = knownSwitchMetadata?.artworkURL,
           let data = try? await download(artworkURL),
           pixelArea(data) > 0 {
            let ext = imageExtension(for: data) ?? "jpg"
            let downloaded = DownloadedArtwork(data: data, fileExtension: ext, sourceURL: artworkURL.absoluteString)
            knownArtwork = downloaded
            primaryCoverCandidates.append(downloaded)
        }

        // Tier 2: Console boxart databases (GameTDB, Libretro Named_Boxarts), secondary LaunchBox, Bangumi game cover.
        var secondaryCoverCandidates: [DownloadedArtwork] = []
        if primaryCoverCandidates.isEmpty {
            // Direct GameTDB lookup by local product ID (e.g., PS3 PARAM.SFO / WiiU meta.xml / filename serial)
            let directProductID = localMeta?.productID ?? Self.extractGameTDBID(from: sourceURL, title: title, platform: platform)
            if let directProductID,
               let directTDB = await gameTDBBoxartByID(directProductID, platform: platform, language: language) {
                secondaryCoverCandidates.append(directTDB)
            }
            if secondaryCoverCandidates.isEmpty {
                for candidateTitle in allCandidates.prefix(5) {
                    if let tdb = await gameTDBBoxart(for: candidateTitle, platform: platform, language: language) {
                        secondaryCoverCandidates.append(tdb)
                        break
                    }
                }
            }
            if secondaryCoverCandidates.isEmpty {
                let boxartQueryCandidates = platform == .switchConsole ? allCandidates : englishCandidates + localizedCandidates
                for candidateTitle in boxartQueryCandidates.prefix(5) {
                    if let libretroCover = await boxartData(for: candidateTitle, platform: platform, language: language) {
                        secondaryCoverCandidates.append(libretroCover)
                        break
                    }
                }
            }
            if let secondaryLB = launchBox?.secondaryCover {
                secondaryCoverCandidates.append(secondaryLB)
            }
            if let bgmCoverURL = bangumi?.coverURL,
               let data = try? await download(bgmCoverURL, userAgent: Self.bangumiUserAgent),
               let dims = pixelDimensions(data),
               min(dims.width, dims.height) >= MetadataRefreshPolicy.minimumCoverDimension {
                let ext = imageExtension(for: data) ?? "jpg"
                secondaryCoverCandidates.append(DownloadedArtwork(data: data, fileExtension: ext, sourceURL: bgmCoverURL.absoluteString))
            }
        }

        // Tier 3: Fallbacks only when all dedicated game cover sources missed.
        var fallbackCoverCandidates: [DownloadedArtwork] = []
        if primaryCoverCandidates.isEmpty && secondaryCoverCandidates.isEmpty {
            if let steamHeader = steamResult?.headerCover {
                fallbackCoverCandidates.append(steamHeader)
            }
            if fallbackCoverCandidates.isEmpty && platform.isRetroConsole {
                for candidateTitle in englishCandidates.prefix(3) {
                    if let titleScreen = await libretroMediaData(for: candidateTitle, platform: platform, directory: "Named_Titles") {
                        fallbackCoverCandidates.append(titleScreen)
                        break
                    }
                }
            }
            if let artworkURL = wiki?.artworkURL,
               let data = try? await download(artworkURL),
               pixelArea(data) > 0 {
                let ext = imageExtension(for: data) ?? (artworkURL.pathExtension.isEmpty ? "jpg" : artworkURL.pathExtension)
                fallbackCoverCandidates.append(DownloadedArtwork(data: data, fileExtension: ext, sourceURL: artworkURL.absoluteString))
            }
            if let artworkURL = baike?.artworkURL,
               let data = try? await download(artworkURL, userAgent: Self.baikeUserAgent),
               pixelArea(data) > 0 {
                let ext = imageExtension(for: data) ?? "jpg"
                fallbackCoverCandidates.append(DownloadedArtwork(data: data, fileExtension: ext, sourceURL: artworkURL.absoluteString))
            }
            if fallbackCoverCandidates.isEmpty,
               let iconString = codeMetadata?.iconURL,
               let iconURL = URL(string: iconString),
               let iconData = try? await download(iconURL),
               pixelArea(iconData) > 0 {
                let ext = imageExtension(for: iconData) ?? (iconURL.pathExtension.isEmpty ? "jpg" : iconURL.pathExtension)
                fallbackCoverCandidates.append(DownloadedArtwork(data: iconData, fileExtension: ext, sourceURL: iconURL.absoluteString))
            }
            if fallbackCoverCandidates.isEmpty, let localIcon = localMeta?.icon {
                fallbackCoverCandidates.append(localIcon)
            }
        }

        let coverPool = !primaryCoverCandidates.isEmpty
            ? primaryCoverCandidates
            : (!secondaryCoverCandidates.isEmpty ? secondaryCoverCandidates : fallbackCoverCandidates)
        let selectedArtwork = selectBestCover(from: coverPool)

        // Stage 4: Select true HD wide backdrop (never stretch tiny low-res screenshots).
        let knownBackdrop: DownloadedArtwork?
        if let url = knownSwitchMetadata?.backdropURL {
            if let knownArtwork, knownSwitchMetadata?.artworkURL == url {
                knownBackdrop = knownArtwork
            } else if let data = try? await download(url), pixelArea(data) > 0 {
                let ext = imageExtension(for: data) ?? "jpg"
                knownBackdrop = DownloadedArtwork(data: data, fileExtension: ext, sourceURL: url.absoluteString)
            } else {
                knownBackdrop = nil
            }
        } else {
            knownBackdrop = nil
        }

        var wideArtwork = banner
            ?? knownBackdrop
            ?? launchBox?.backdrop
            ?? steamResult?.backdrop
            ?? localMeta?.backdrop
            ?? launchBox?.secondaryBackdrop

        if wideArtwork == nil {
            var wikiImageQueries: [(title: String, lang: String)] = []
            if let enTitle = wiki?.alternateTitle { wikiImageQueries.append((enTitle, "en")) }
            if let mainTitle = wiki?.title {
                let mainLang = GameTitleMatcher.hasHan(mainTitle) ? "zh" : (GameTitleMatcher.hasKana(mainTitle) ? "ja" : "en")
                if !wikiImageQueries.contains(where: { $0.title == mainTitle && $0.lang == mainLang }) {
                    wikiImageQueries.append((mainTitle, mainLang))
                }
            }
            for item in wikiImageQueries {
                if let wide = await wikipediaWideImage(for: item.title, language: item.lang) {
                    wideArtwork = wide
                    break
                }
            }
        }
        if wideArtwork == nil {
            wideArtwork = steamResult?.panoramicBackdrop ?? launchBox?.bannerBackdrop
        }
        if wideArtwork == nil && platform.isRetroConsole {
            for candidateTitle in englishCandidates.prefix(2) {
                if let snap = await libretroMediaData(for: candidateTitle, platform: platform, directory: "Named_Snaps"),
                   let dims = pixelDimensions(snap.data),
                   MetadataRefreshPolicy.isAcceptableBackdrop(width: dims.width, height: dims.height) {
                    wideArtwork = snap
                    break
                }
            }
        }

        if let wide = wideArtwork, banner == nil {
            await onBackdrop(wide.data)
        }

        return GameMetadataResult(
            title: resolvedTitle,
            synopsis: resolvedSynopsis,
            metadataSourceURL: resolvedSourceURL,
            artworkData: selectedArtwork?.data,
            artworkExtension: selectedArtwork?.fileExtension,
            artworkSourceURL: selectedArtwork?.sourceURL,
            backdropData: wideArtwork?.data,
            backdropSourceURL: wideArtwork?.sourceURL
        )
    }

    private func selectBestCover(from candidates: [DownloadedArtwork]) -> DownloadedArtwork? {
        guard !candidates.isEmpty else { return nil }
        return candidates.max { lhs, rhs in
            coverQualityScore(lhs.data) < coverQualityScore(rhs.data)
        }
    }

    private func coverQualityScore(_ data: Data) -> Double {
        guard let dims = pixelDimensions(data) else { return 0 }
        let area = Double(dims.width * dims.height)
        let ratio = Double(dims.width) / Double(dims.height)
        // Prefer vertical/box-art ratios (0.55...1.15) over wide banners for cover tiles.
        let ratioWeight: Double
        if (0.55...1.15).contains(ratio) {
            ratioWeight = 1.25
        } else if ratio <= 1.5 {
            ratioWeight = 1.0
        } else {
            ratioWeight = 0.72
        }
        return area * ratioWeight
    }

    private static func stripWikipediaDisambiguator(_ value: String) -> String {
        value.replacingOccurrences(
            of: #"\s*[\(（][^\)）]*(?:video\s*game|game|游戏|遊戲|ゲーム)[^\)）]*[\)）]\s*$"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func deduplicatedQueries(_ items: [String?]) -> [String] {
        var result: [String] = []
        for raw in items.compactMap({ $0 }) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let norm = GameTitleMatcher.normalize(trimmed)
            guard !norm.isEmpty else { continue }
            if !result.contains(where: { GameTitleMatcher.normalize($0) == norm }) {
                result.append(trimmed)
            }
        }
        return result
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

        let ignored = Set([
            "switch", "switch2", "switch 2", "games", "game", "roms", "gamelibrary",
            "nup", "nsp", "xci", "nsz", "xcz", "base", "updates", "dlc", "mod",
            "gba", "gb", "gbc", "nds", "3ds", "psp", "psv", "ps1", "ps2", "ps3", "wii", "wiiu", "fc", "sfc", "md", "n64"
        ])
        let titleIDPattern = try? NSRegularExpression(pattern: #"(?i)\b[0-9a-f]{16}\b"#)
        // Full-width brackets are common in Chinese release names (（汉化版）, 【简】).
        let noisePattern = try? NSRegularExpression(
            pattern: #"(?i)\[[^\]]*\]|\([^)]*\)|（[^）]*）|【[^】]*】|\b(?:xci|nsp|nsz|xcz|nup|mod|rev\s*\d+|disc\s*\d+|cd\s*\d+|v\d+(?:\.\d+)*|usa|eur|jpn|chs|cht)\b"#
        )
        let chineseNoisePattern = try? NSRegularExpression(
            pattern: #"(?:完整|完美|最新|最终|官方)?(?:简体|繁体|简繁)?(?:中文|汉化|日文|英文|美|日|欧|港)版|(?:全\s*DLC|整合版|金手指|免安装|修正版|简中|繁中)"#,
            options: [.caseInsensitive]
        )

        for candidate in candidates {
            var cleaned = candidate
            let fullRange = NSRange(cleaned.startIndex..., in: cleaned)
            cleaned = titleIDPattern?.stringByReplacingMatches(in: cleaned, range: fullRange, withTemplate: " ") ?? cleaned
            let noiseRange = NSRange(cleaned.startIndex..., in: cleaned)
            cleaned = noisePattern?.stringByReplacingMatches(in: cleaned, range: noiseRange, withTemplate: " ") ?? cleaned
            let zhNoiseRange = NSRange(cleaned.startIndex..., in: cleaned)
            cleaned = chineseNoisePattern?.stringByReplacingMatches(in: cleaned, range: zhNoiseRange, withTemplate: " ") ?? cleaned
            // Strip leading ROM dump indexes ("001 - …", "3191 - …", "#042 - …", "PS3CH032 - …").
            cleaned = cleaned.replacingOccurrences(
                of: #"^\s*#?(?=[A-Za-z0-9]{2,12}\s*[-–—._])(?=[A-Za-z0-9]*\d)[A-Za-z0-9]+\s*[-–—._]+\s*"#,
                with: "", options: .regularExpression)
            // Serials glued to the name ("骇客追忆PCSH10079", "BLUS12345", "SLUS-20312") go too.
            cleaned = cleaned.replacingOccurrences(
                of: #"(?<![A-Za-z0-9])[A-Z]{2,4}-?\d{4,6}(?![0-9])"#, with: " ", options: .regularExpression)
            cleaned = cleaned
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))

            guard !cleaned.isEmpty,
                  !ignored.contains(cleaned.lowercased()),
                  // Bare release serials ("PCSH10079") or UUIDs are not names.
                  cleaned.range(of: #"^[A-Za-z]*\d[\w-]*$"#, options: .regularExpression) == nil,
                  cleaned.range(of: #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#, options: .regularExpression) == nil,
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

    // MARK: - Local Container Metadata (PS3 / PSV / Wii U)

    private func readLocalGameMetadata(from sourceURL: URL, platform: GameMetadataPlatform, language: String) -> LocalGameMetadata? {
        let fm = FileManager.default
        guard (try? sourceURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }

        switch platform {
        case .ps3:
            let sfoCandidates = [
                sourceURL.appendingPathComponent("PS3_GAME/PARAM.SFO"),
                sourceURL.appendingPathComponent("PARAM.SFO")
            ]
            guard let sfo = sfoCandidates.first(where: { fm.fileExists(atPath: $0.path) }) else { return nil }
            let rawTitle = Self.readSFOString("TITLE", at: sfo)?.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            let productID = Self.readSFOString("TITLE_ID", at: sfo)?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            let base = sfo.deletingLastPathComponent()
            let icon = readLocalArtwork(at: base.appendingPathComponent("ICON0.PNG"))
            let backdrop = readLocalArtwork(at: base.appendingPathComponent("PIC1.PNG"), requireWideBackdrop: true)
            guard rawTitle != nil || productID != nil || icon != nil || backdrop != nil else { return nil }
            return LocalGameMetadata(title: rawTitle, productID: productID, icon: icon, backdrop: backdrop)

        case .psv:
            let sfo = sourceURL.appendingPathComponent("sce_sys/param.sfo")
            guard fm.fileExists(atPath: sfo.path) else { return nil }
            let rawTitle = (Self.readSFOString("TITLE", at: sfo) ?? Self.readSFOString("STITLE", at: sfo))?
                .replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            let productID = Self.readSFOString("TITLE_ID", at: sfo)?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            let icon = readLocalArtwork(at: sourceURL.appendingPathComponent("sce_sys/icon0.png"))
            let backdrop = readLocalArtwork(at: sourceURL.appendingPathComponent("sce_sys/livearea/contents/bg.png"), requireWideBackdrop: true)
                ?? readLocalArtwork(at: sourceURL.appendingPathComponent("sce_sys/pic0.png"), requireWideBackdrop: true)
            guard rawTitle != nil || productID != nil || icon != nil || backdrop != nil else { return nil }
            return LocalGameMetadata(title: rawTitle, productID: productID, icon: icon, backdrop: backdrop)

        case .wiiu:
            let metaXML = sourceURL.appendingPathComponent("meta/meta.xml")
            guard fm.fileExists(atPath: metaXML.path),
                  let data = try? Data(contentsOf: metaXML),
                  let xml = String(data: data, encoding: .utf8) else { return nil }
            let tagOrder: [String]
            switch language {
            case "zh": tagOrder = ["longname_zhs", "longname_zht", "longname_en", "longname_ja"]
            case "ja": tagOrder = ["longname_ja", "longname_en"]
            default: tagOrder = ["longname_en", "longname_ja"]
            }
            var parsedTitle: String?
            for tag in tagOrder {
                if let value = Self.firstCapture(in: xml, pattern: "<\(tag)[^>]*>([^<]+)</\(tag)>") {
                    let cleaned = Self.unescapeHTML(value).replacingOccurrences(of: "\n", with: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !cleaned.isEmpty { parsedTitle = cleaned; break }
                }
            }
            var productID: String?
            if let code = Self.firstCapture(in: xml, pattern: #"<product_code[^>]*>([^<]+)</product_code>"#) {
                let parts = code.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "-")
                if let suffix = parts.last, suffix.count >= 4 {
                    productID = String(suffix).uppercased()
                }
            }
            guard parsedTitle != nil || productID != nil else { return nil }
            return LocalGameMetadata(title: parsedTitle, productID: productID, icon: nil, backdrop: nil)

        default:
            return nil
        }
    }

    private func readLocalArtwork(at url: URL, requireWideBackdrop: Bool = false) -> DownloadedArtwork? {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let dims = pixelDimensions(data),
              let ext = imageExtension(for: data) else { return nil }
        if requireWideBackdrop {
            guard MetadataRefreshPolicy.isAcceptableBackdrop(width: dims.width, height: dims.height) else { return nil }
        }
        return DownloadedArtwork(data: data, fileExtension: ext, sourceURL: url.path)
    }

    private static func readSFOString(_ key: String, at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url), data.count >= 20, data.count <= 1_048_576,
              Array(data.prefix(4)) == [0, 80, 83, 70] else { return nil }
        func number(_ offset: Int, _ count: Int) -> Int {
            guard offset >= 0, offset + count <= data.count else { return -1 }
            return (0..<count).reduce(0) { $0 | Int(data[offset + $1]) << ($1 * 8) }
        }
        let keys = number(8, 4), values = number(12, 4), count = number(16, 4)
        guard count >= 0, count <= (data.count - 20) / 16 else { return nil }
        for entry in 0..<count {
            let index = 20 + entry * 16
            let start = keys + number(index, 2)
            guard start >= 0, start < data.count, let end = data[start...].firstIndex(of: 0),
                  String(data: data[start..<end], encoding: .utf8) == key else { continue }
            let offset = values + number(index + 12, 4), length = number(index + 4, 4)
            guard offset >= 0, length >= 0, offset <= data.count, length <= data.count - offset else { return nil }
            return String(data: data[offset..<(offset + length)].prefix { $0 != 0 }, encoding: .utf8)
        }
        return nil
    }

    private static func extractGameTDBID(from sourceURL: URL?, title: String, platform: GameMetadataPlatform) -> String? {
        let texts = [sourceURL?.lastPathComponent, title].compactMap { $0 }
        let pattern: String?
        switch platform {
        case .ps3: pattern = #"(?i)\b([A-Z]{4}\d{5})\b"#
        case .wii, .gamecube: pattern = #"(?i)[\[\(]([A-Z0-9]{6})[\]\)]"#
        case .wiiu: pattern = #"(?i)[\[\(]([A-Z0-9]{4,6})[\]\)]"#
        case .nds, .threeDS: pattern = #"(?i)[\[\(]([A-Z0-9]{4})[\]\)]"#
        default: pattern = nil
        }
        guard let pattern else { return nil }
        for text in texts {
            if let captured = firstCapture(in: text, pattern: pattern)?.uppercased(),
               isValidGameTDBID(captured, platform: platform) {
                return captured
            }
        }
        return nil
    }

    // MARK: - Switch TitleDB (api.nlib.cc)

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

    // MARK: - Bangumi (api.bgm.tv — dedicated video game database, type=4)

    private struct BangumiGameInfo {
        let chineseTitle: String?
        let originalTitle: String?
        let englishTitle: String?
        let synopsis: String?
        let coverURL: URL?
        let pageURL: String
    }

    private func bangumiLookup(queries: [String], platform: GameMetadataPlatform, language: String) async -> BangumiGameInfo? {
        let candidates = queries.prefix(3)
        for query in candidates {
            guard !query.isEmpty,
                  let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                  let searchURL = URL(string: "https://api.bgm.tv/search/subject/\(encoded)?type=4&responseGroup=medium&max_results=6"),
                  let data = try? await download(searchURL, userAgent: Self.bangumiUserAgent),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = root["list"] as? [[String: Any]], !list.isEmpty else { continue }

            let best = list.compactMap { item -> (id: Int, score: Double)? in
                guard let id = item["id"] as? Int else { return nil }
                let rawName = (item["name"] as? String) ?? ""
                let rawCN = (item["name_cn"] as? String) ?? ""
                let score = max(matchScore(query, rawName), matchScore(query, rawCN))
                return (id, score)
            }.max { $0.score < $1.score }

            let minScore = GameTitleMatcher.hasHan(query) || GameTitleMatcher.hasKana(query) ? 0.68 : max(0.70, minimumMatchScore(for: query))
            guard let best, best.score >= minScore else { continue }

            guard let detailURL = URL(string: "https://api.bgm.tv/v0/subjects/\(best.id)"),
                  let detailData = try? await download(detailURL, userAgent: Self.bangumiUserAgent),
                  let detail = try? JSONSerialization.jsonObject(with: detailData) as? [String: Any] else { continue }

            let name = (detail["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let nameCN = (detail["name_cn"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = (detail["summary"] as? String).map(cleanSynopsis).flatMap { $0.isEmpty ? nil : $0 }

            var englishAlias: String?
            if let infobox = detail["infobox"] as? [[String: Any]] {
                for entry in infobox {
                    let key = (entry["key"] as? String) ?? ""
                    if key == "英文名", let val = entry["value"] as? String {
                        let trimmed = val.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty, !GameTitleMatcher.hasHan(trimmed), !GameTitleMatcher.hasKana(trimmed) {
                            englishAlias = trimmed
                            break
                        }
                    } else if key == "别名", let arr = entry["value"] as? [[String: Any]] {
                        for aliasItem in arr {
                            let k = (aliasItem["k"] as? String) ?? ""
                            let v = (aliasItem["v"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                            if !v.isEmpty, !GameTitleMatcher.hasHan(v), !GameTitleMatcher.hasKana(v),
                               (k.contains("英文") || k.lowercased().contains("english") || k == "欧美版名") {
                                englishAlias = v
                                break
                            }
                        }
                    }
                    if englishAlias != nil { break }
                }
            }
            if englishAlias == nil, let name, !name.isEmpty,
               !GameTitleMatcher.hasHan(name), !GameTitleMatcher.hasKana(name) {
                englishAlias = name
            }

            let images = detail["images"] as? [String: Any]
            let coverString = (images?["large"] as? String) ?? (images?["medium"] as? String) ?? (images?["common"] as? String)
            var coverURLComponents = coverString.flatMap(URLComponents.init(string:))
            if coverURLComponents?.scheme == "http" { coverURLComponents?.scheme = "https" }

            return BangumiGameInfo(
                chineseTitle: nameCN?.isEmpty == false ? nameCN : nil,
                originalTitle: name?.isEmpty == false ? name : nil,
                englishTitle: englishAlias,
                synopsis: summary,
                coverURL: coverURLComponents?.url,
                pageURL: "https://bgm.tv/subject/\(best.id)"
            )
        }
        return nil
    }

    // MARK: - LaunchBox GamesDB

    private struct SteamMediaResult {
        let title: String?
        let synopsis: String?
        let sourceURL: String?
        let cover: DownloadedArtwork?
        let headerCover: DownloadedArtwork?
        let backdrop: DownloadedArtwork?
        let panoramicBackdrop: DownloadedArtwork?
    }

    private struct LaunchBoxMediaResult {
        let title: String?
        let synopsis: String?
        let sourceURL: String?
        let cover: DownloadedArtwork?
        let secondaryCover: DownloadedArtwork?
        let backdrop: DownloadedArtwork?
        let secondaryBackdrop: DownloadedArtwork?
        let bannerBackdrop: DownloadedArtwork?
    }

    /// LaunchBox GamesDB provides human-curated per-platform `Box - Front` covers and
    /// 16:9 HD `Fanart - Background` wallpapers specifically intended for game launcher backdrops.
    private func launchBoxMedia(
        for title: String,
        platform: GameMetadataPlatform,
        language: String,
        fetchSynopsisIfNeeded: Bool
    ) async -> LaunchBoxMediaResult? {
        guard !title.isEmpty, !GameTitleMatcher.hasHan(title), !GameTitleMatcher.hasKana(title),
              let encoded = title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let searchURL = URL(string: "https://gamesdb.launchbox-app.com/games/results/\(encoded)"),
              let data = try? await download(searchURL, userAgent: Self.browserUserAgent),
              let html = String(data: data, encoding: .utf8) else { return nil }

        guard let cardRegex = try? NSRegularExpression(
            pattern: #"href="/games/details/(\d+)[^"]*"[^>]*>(.*?)</a>"#,
            options: [.dotMatchesLineSeparators]
        ) else { return nil }

        let targetPlatforms = launchBoxPlatformNames(for: platform).map { $0.lowercased() }
        let matches = cardRegex.matches(in: html, range: NSRange(html.startIndex..., in: html))
        struct Card {
            let id: String
            let title: String
            let titleScore: Double
            let platformMatch: Bool
            let isHack: Bool
        }
        var cards: [Card] = []
        var seenIDs = Set<String>()
        for match in matches.prefix(28) {
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
            let platformMatch = targetPlatforms.contains { lower.contains($0) }
            let titlePart = stripped
                .replacingOccurrences(
                    of: #"\s+(?:Nintendo|Sony|Sega|Microsoft|Windows|Apple|Arcade|Atari|NEC|SNK|Bandai|Add to collection|Released).*$"#,
                    with: "",
                    options: .regularExpression
                )
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let candidateTitle = titlePart.isEmpty ? stripped : titlePart
            var score = matchScore(title, candidateTitle)
            let normQuery = normalize(title)
            let normCandidate = normalize(candidateTitle)
            if normQuery.count >= 6, normCandidate.contains(normQuery) {
                score = max(score, platformMatch ? 0.88 : 0.78)
            }
            guard score >= 0.72 else { continue }
            cards.append(Card(id: id, title: candidateTitle, titleScore: score, platformMatch: platformMatch, isHack: isHack))
        }
        guard !cards.isEmpty else { return nil }

        let ordered = cards.sorted { lhs, rhs in
            if lhs.isHack != rhs.isHack { return !lhs.isHack }
            if lhs.platformMatch != rhs.platformMatch { return lhs.platformMatch }
            return lhs.titleScore > rhs.titleScore
        }

        var bestCover: DownloadedArtwork?
        var secondaryCover: DownloadedArtwork?
        var bestBackdrop: DownloadedArtwork?
        var secondaryBackdrop: DownloadedArtwork?
        var bannerBackdrop: DownloadedArtwork?

        for card in ordered.prefix(4) {
            if bestCover != nil && bestBackdrop != nil { break }
            guard let imgPageURL = URL(string: "https://gamesdb.launchbox-app.com/games/images/\(card.id)"),
                  let imgData = try? await download(imgPageURL, userAgent: Self.browserUserAgent),
                  let imgHTML = String(data: imgData, encoding: .utf8),
                  let itemRegex = try? NSRegularExpression(
                    pattern: #"href="(https://images\.launchbox-app\.com/[^"]+)"[^>]*data-title="([^"]*)""#
                  ) else { continue }

            var fanartURLs: [URL] = []
            var screenshotURLs: [URL] = []
            var bannerURLs: [URL] = []
            var platformBoxURLs: [(url: URL, priority: Int)] = []
            var fallbackBoxURLs: [(url: URL, priority: Int)] = []

            for m in itemRegex.matches(in: imgHTML, range: NSRange(imgHTML.startIndex..., in: imgHTML)) {
                guard let uRange = Range(m.range(at: 1), in: imgHTML),
                      let lRange = Range(m.range(at: 2), in: imgHTML),
                      let imgURL = URL(string: String(imgHTML[uRange])) else { continue }
                let label = Self.unescapeHTML(String(imgHTML[lRange]))

                if label.contains("Fanart - Background") {
                    fanartURLs.append(imgURL)
                } else if label.contains("Screenshot - Gameplay") || label.contains("Screenshot - Game Title") {
                    screenshotURLs.append(imgURL)
                } else if label.contains("Steam Banner") || label.contains("Banner Image") {
                    bannerURLs.append(imgURL)
                } else if label.contains("Box - Front") || label.contains("Fanart - Box - Front") || label.contains("Box - 3D") {
                    let isFlatFront = label.contains("Box - Front") && !label.contains("Box - Back")
                    var prio = isFlatFront ? 10 : 4
                    if (language == "ja" || language == "zh") && (label.contains("Japan") || label.contains("Asia")) { prio += 4 }
                    else if label.contains("World") || label.contains("North America") || label.contains("United States") { prio += 3 }
                    else if label.contains("Europe") || label.contains("Japan") { prio += 2 }
                    else { prio += 1 }
                    if card.platformMatch && isFlatFront {
                        platformBoxURLs.append((imgURL, prio))
                    } else {
                        fallbackBoxURLs.append((imgURL, prio))
                    }
                }
            }

            if bestCover == nil, let topBox = platformBoxURLs.sorted(by: { $0.priority > $1.priority }).first {
                if let bytes = try? await download(topBox.url, userAgent: Self.browserUserAgent),
                   pixelArea(bytes) >= 200 * 200 {
                    let ext = imageExtension(for: bytes) ?? (topBox.url.pathExtension.lowercased() == "png" ? "png" : "jpg")
                    bestCover = DownloadedArtwork(data: bytes, fileExtension: ext, sourceURL: topBox.url.absoluteString)
                }
            }
            if bestCover == nil && secondaryCover == nil,
               let fallbackBox = fallbackBoxURLs.sorted(by: { $0.priority > $1.priority }).first {
                if let bytes = try? await download(fallbackBox.url, userAgent: Self.browserUserAgent),
                   pixelArea(bytes) >= 200 * 200 {
                    let ext = imageExtension(for: bytes) ?? (fallbackBox.url.pathExtension.lowercased() == "png" ? "png" : "jpg")
                    secondaryCover = DownloadedArtwork(data: bytes, fileExtension: ext, sourceURL: fallbackBox.url.absoluteString)
                }
            }

            if bestBackdrop == nil {
                var hdCandidates: [DownloadedArtwork] = []
                for url in fanartURLs.prefix(4) {
                    if let bytes = try? await download(url, userAgent: Self.browserUserAgent),
                       let dims = pixelDimensions(bytes),
                       dims.width >= MetadataRefreshPolicy.preferredHDWidth,
                       dims.height >= MetadataRefreshPolicy.preferredHDHeight {
                        let ratio = Double(dims.width) / Double(dims.height)
                        if ratio >= 1.35 && ratio <= 2.35 {
                            let ext = imageExtension(for: bytes) ?? (url.pathExtension.lowercased() == "png" ? "png" : "jpg")
                            hdCandidates.append(DownloadedArtwork(data: bytes, fileExtension: ext, sourceURL: url.absoluteString))
                            if dims.width >= 1920 && dims.height >= 1080 { break }
                        }
                    }
                }
                bestBackdrop = hdCandidates.max { pixelArea($0.data) < pixelArea($1.data) }
            }

            if bestBackdrop == nil && secondaryBackdrop == nil {
                for url in screenshotURLs.prefix(3) {
                    if let bytes = try? await download(url, userAgent: Self.browserUserAgent),
                       let dims = pixelDimensions(bytes),
                       dims.width >= MetadataRefreshPolicy.preferredHDWidth,
                       dims.height >= MetadataRefreshPolicy.preferredHDHeight {
                        let ratio = Double(dims.width) / Double(dims.height)
                        if ratio >= 1.35 && ratio <= 2.35 {
                            let ext = imageExtension(for: bytes) ?? (url.pathExtension.lowercased() == "png" ? "png" : "jpg")
                            secondaryBackdrop = DownloadedArtwork(data: bytes, fileExtension: ext, sourceURL: url.absoluteString)
                            break
                        }
                    }
                }
            }

            if bestBackdrop == nil && secondaryBackdrop == nil && bannerBackdrop == nil {
                for url in bannerURLs.prefix(2) {
                    if let bytes = try? await download(url, userAgent: Self.browserUserAgent),
                       let dims = pixelDimensions(bytes),
                       MetadataRefreshPolicy.isAcceptableBackdrop(width: dims.width, height: dims.height) {
                        let ext = imageExtension(for: bytes) ?? (url.pathExtension.lowercased() == "png" ? "png" : "jpg")
                        bannerBackdrop = DownloadedArtwork(data: bytes, fileExtension: ext, sourceURL: url.absoluteString)
                        break
                    }
                }
            }
        }

        var overviewSynopsis: String?
        let topCard = ordered.first
        let detailURLString = topCard.map { "https://gamesdb.launchbox-app.com/games/details/\($0.id)" }
        if fetchSynopsisIfNeeded, let detailURLString, let detailURL = URL(string: detailURLString),
           let detailData = try? await download(detailURL, userAgent: Self.browserUserAgent),
           let detailHTML = String(data: detailData, encoding: .utf8),
           let rawDesc = Self.firstCapture(in: detailHTML, pattern: #"<meta[^>]+name=["']description["'][^>]+content=["']([^"']+)["']"#) {
            let cleaned = cleanSynopsis(Self.unescapeHTML(rawDesc))
            if cleaned.count >= 25 && !cleaned.lowercased().contains("launchbox games database") {
                overviewSynopsis = cleaned
            }
        }

        guard bestCover != nil || secondaryCover != nil || bestBackdrop != nil || secondaryBackdrop != nil || bannerBackdrop != nil || overviewSynopsis != nil else {
            return nil
        }
        return LaunchBoxMediaResult(
            title: topCard?.title,
            synopsis: overviewSynopsis,
            sourceURL: detailURLString,
            cover: bestCover,
            secondaryCover: secondaryCover,
            backdrop: bestBackdrop,
            secondaryBackdrop: secondaryBackdrop,
            bannerBackdrop: bannerBackdrop
        )
    }

    private func launchBoxPlatformNames(for platform: GameMetadataPlatform) -> [String] {
        switch platform {
        case .gba: return ["Game Boy Advance"]
        case .gb: return ["Game Boy"]
        case .gbc: return ["Game Boy Color"]
        case .nds: return ["Nintendo DS"]
        case .threeDS: return ["Nintendo 3DS"]
        case .psp: return ["Sony PSP"]
        case .psv: return ["Sony Playstation Vita"]
        case .ps1: return ["Sony Playstation"]
        case .ps2: return ["Sony Playstation 2"]
        case .ps3: return ["Sony Playstation 3"]
        case .ps4: return ["Sony Playstation 4"]
        case .famicom, .dendy: return ["Nintendo Entertainment System"]
        case .fds: return ["Nintendo Famicom Disk System"]
        case .superFamicom: return ["Super Nintendo Entertainment System"]
        case .n64, .n64dd: return ["Nintendo 64"]
        case .megaDrive: return ["Sega Genesis", "Sega Mega Drive"]
        case .gamecube: return ["Nintendo GameCube"]
        case .wii: return ["Nintendo Wii"]
        case .wiiu: return ["Nintendo Wii U"]
        case .dreamcast: return ["Sega Dreamcast"]
        case .xbox: return ["Microsoft Xbox"]
        case .switchConsole: return ["Nintendo Switch"]
        case .macOS: return ["Apple Mac OS", "Windows"]
        case .atari2600: return ["Atari 2600"]
        case .sms: return ["Sega Master System"]
        case .gg: return ["Sega Game Gear"]
        case .segacd: return ["Sega CD"]
        case .sega32x: return ["Sega 32X"]
        case .pce, .sgx: return ["NEC TurboGrafx-16", "PC Engine"]
        case .pcecd, .sgxcd: return ["NEC TurboGrafx-CD"]
        case .ws: return ["WonderSwan"]
        case .wsc: return ["WonderSwan Color"]
        case .ngp: return ["SNK Neo Geo Pocket"]
        case .ngpc: return ["SNK Neo Geo Pocket Color"]
        case .arcade, .aes, .mvs: return ["Arcade", "SNK Neo Geo AES"]
        default: return []
        }
    }

    // MARK: - Steam Store Media & Localized Synopsis

    private func steamMedia(for title: String, platform: GameMetadataPlatform, language: String) async -> SteamMediaResult? {
        guard !title.isEmpty else { return nil }
        let isCJK = GameTitleMatcher.hasHan(title) || GameTitleMatcher.hasKana(title)
        let searchLang: String
        let searchCC: String
        if GameTitleMatcher.hasHan(title) {
            searchLang = "schinese"; searchCC = "CN"
        } else if GameTitleMatcher.hasKana(title) {
            searchLang = "japanese"; searchCC = "JP"
        } else {
            searchLang = "english"; searchCC = "US"
        }

        guard var components = URLComponents(string: "https://store.steampowered.com/api/storesearch/") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "term", value: title),
            URLQueryItem(name: "l", value: searchLang),
            URLQueryItem(name: "cc", value: searchCC)
        ]
        guard let searchURL = components.url,
              let searchData = try? await download(searchURL),
              let root = try? JSONSerialization.jsonObject(with: searchData) as? [String: Any],
              let items = root["items"] as? [[String: Any]] else { return nil }

        let normQuery = normalize(title)
        let editionSuffixes: Set<String> = [
            "hd", "remaster", "remastered", "definitive", "complete", "deluxe",
            "goty", "special", "ultimate", "collection", "director", "cut", "steam", "pc", "royal", "golden"
        ]
        let match = items
            .filter { ($0["type"] as? String) == "app" }
            .compactMap { item -> (id: Int, name: String, score: Double)? in
                guard let id = item["id"] as? Int, let name = item["name"] as? String else { return nil }
                var score = matchScore(title, name)
                let normName = normalize(name)
                if !isCJK, normQuery.count >= 5 {
                    if normName == normQuery {
                        score = 1.0
                    } else if normName.hasPrefix(normQuery + " ") {
                        let extraTokens = normName.dropFirst(normQuery.count + 1).split(separator: " ").map(String.init)
                        if !extraTokens.isEmpty && extraTokens.allSatisfy({ editionSuffixes.contains($0) }) {
                            score = max(score, 0.88)
                        }
                    } else if normQuery.hasPrefix(normName + " ") {
                        let extraTokens = normQuery.dropFirst(normName.count + 1).split(separator: " ").map(String.init)
                        if !extraTokens.isEmpty && extraTokens.allSatisfy({ editionSuffixes.contains($0) }) {
                            score = max(score, 0.86)
                        }
                    }
                }
                return (id, name, score)
            }
            .max { $0.score < $1.score }
        guard let match, match.score >= (isCJK ? 0.72 : 0.78) else { return nil }

        let detailLang: String
        let detailCC: String
        switch language {
        case "zh": detailLang = "schinese"; detailCC = "CN"
        case "ja": detailLang = "japanese"; detailCC = "JP"
        default: detailLang = "english"; detailCC = "US"
        }

        var localizedTitle: String?
        var localizedSynopsis: String?
        var backdrop16x9: DownloadedArtwork?
        var panoramic: DownloadedArtwork?
        var cover: DownloadedArtwork?
        var headerCover: DownloadedArtwork?

        if let detailsURL = URL(string: "https://store.steampowered.com/api/appdetails?appids=\(match.id)&l=\(detailLang)&cc=\(detailCC)"),
           let detailsData = try? await download(detailsURL),
           let details = try? JSONSerialization.jsonObject(with: detailsData) as? [String: Any],
           let app = details[String(match.id)] as? [String: Any],
           let data = app["data"] as? [String: Any] {
            if let name = (data["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                localizedTitle = name
            }
            if let shortDesc = (data["short_description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !shortDesc.isEmpty {
                let stripped = Self.unescapeHTML(shortDesc.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression))
                let cleaned = cleanSynopsis(stripped)
                if cleaned.count >= 15 { localizedSynopsis = cleaned }
            }

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
                   dims.width >= MetadataRefreshPolicy.preferredHDWidth,
                   dims.height >= MetadataRefreshPolicy.preferredHDHeight {
                    let ratio = Double(dims.width) / Double(dims.height)
                    if ratio >= 1.4 && ratio <= 2.2 {
                        let ext = imageExtension(for: imageData) ?? "jpg"
                        backdrop16x9 = DownloadedArtwork(data: imageData, fileExtension: ext, sourceURL: url.absoluteString)
                        break
                    }
                }
            }

            if let headerStr = data["header_image"] as? String, let headerURL = URL(string: headerStr),
               let headerData = try? await download(headerURL),
               pixelArea(headerData) >= 400 * 180 {
                headerCover = DownloadedArtwork(data: headerData, fileExtension: imageExtension(for: headerData) ?? "jpg", sourceURL: headerURL.absoluteString)
            }
        }

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
                panoramic = DownloadedArtwork(data: data, fileExtension: imageExtension(for: data) ?? "jpg", sourceURL: url.absoluteString)
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
            cover = DownloadedArtwork(data: data, fileExtension: imageExtension(for: data) ?? "jpg", sourceURL: url.absoluteString)
            break
        }

        guard cover != nil || headerCover != nil || backdrop16x9 != nil || panoramic != nil || localizedSynopsis != nil else { return nil }
        return SteamMediaResult(
            title: localizedTitle,
            synopsis: localizedSynopsis,
            sourceURL: "https://store.steampowered.com/app/\(match.id)/",
            cover: cover,
            headerCover: headerCover,
            backdrop: backdrop16x9,
            panoramicBackdrop: panoramic
        )
    }

    // MARK: - Chinese Franchise Hints

    /// Maps common Chinese ROM hack / fan-translation names to canonical Chinese & English game titles.
    private static func chineseFranchiseHint(for text: String, platform: GameMetadataPlatform) -> (zh: String, en: String)? {
        if platform == .gba {
            if text.contains("红宝石") && !text.contains("欧米伽") {
                return ("宝可梦 红宝石", "Pokemon Ruby Version")
            }
            if text.contains("蓝宝石") && !text.contains("阿尔法") {
                return ("宝可梦 蓝宝石", "Pokemon Sapphire Version")
            }
        }
        let rules: [(patterns: [String], zh: String, en: String)] = [
            (["欧米伽红宝石", "红宝石"], "宝可梦 欧米伽红宝石", "Pokemon Omega Ruby"),
            (["阿尔法蓝宝石", "蓝宝石"], "宝可梦 阿尔法蓝宝石", "Pokemon Alpha Sapphire"),
            (["心金"], "宝可梦 心金", "Pokemon HeartGold Version"),
            (["魂银"], "宝可梦 魂银", "Pokemon SoulSilver Version"),
            (["漆黑的魅影", "究极绿宝石", "绿宝石"], "宝可梦 绿宝石", "Pokemon Emerald Version"),
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
            (["塞尔达传说", "智慧的再现"], "塞尔达传说 智慧的再现", "The Legend of Zelda: Echoes of Wisdom"),
            (["塞尔达传说", "旷野之息", "荒野之息"], "塞尔达传说 旷野之息", "The Legend of Zelda: Breath of the Wild"),
            (["塞尔达传说", "王国之泪"], "塞尔达传说 王国之泪", "The Legend of Zelda: Tears of the Kingdom"),
            (["塞尔达传说", "织梦岛"], "塞尔达传说 织梦岛", "The Legend of Zelda: Link's Awakening")
        ]
        for rule in rules {
            if rule.patterns.count == 1 {
                if text.contains(rule.patterns[0]) {
                    return (rule.zh, rule.en)
                }
            } else {
                let hitCount = rule.patterns.filter { text.contains($0) }.count
                if hitCount >= 2
                    || (rule.patterns.contains("欧米伽红宝石") && text.contains("欧米伽红宝石"))
                    || (rule.patterns.contains("阿尔法蓝宝石") && text.contains("阿尔法蓝宝石"))
                    || (rule.patterns.contains("漆黑的魅影") && (text.contains("漆黑的魅影") || text.contains("究极绿宝石")))
                    || (rule.patterns.contains("网络侦探") && (text.contains("网络侦探") || text.contains("骇客追忆")))
                    || (rule.patterns.contains("失落之歌") && text.contains("失落之歌"))
                    || (rule.patterns.contains("消失的密室") && text.contains("消失的密室"))
                    || (rule.patterns.contains("旷野之息") && (text.contains("旷野之息") || text.contains("荒野之息")))
                    || (rule.patterns.contains("王国之泪") && text.contains("王国之泪"))
                    || (rule.patterns.contains("织梦岛") && text.contains("织梦岛")) {
                    return (rule.zh, rule.en)
                }
            }
        }
        return nil
    }

    // MARK: - GameTDB (Switch / 3DS / NDS / Wii / Wii U / GameCube / PS3)

    private static func isValidGameTDBID(_ id: String, platform: GameMetadataPlatform) -> Bool {
        let bytes = Array(id.utf8)
        func isAsciiAlnum(_ b: UInt8) -> Bool {
            (b >= 48 && b <= 57) || (b >= 65 && b <= 90) || (b >= 97 && b <= 122)
        }
        func isAsciiAlpha(_ b: UInt8) -> Bool {
            (b >= 65 && b <= 90) || (b >= 97 && b <= 122)
        }
        func isAsciiDigit(_ b: UInt8) -> Bool {
            b >= 48 && b <= 57
        }
        switch platform {
        case .nds, .threeDS:
            return bytes.count == 4 && bytes.allSatisfy(isAsciiAlnum)
        case .wii, .wiiu, .gamecube:
            return (4...6).contains(bytes.count) && bytes.allSatisfy(isAsciiAlnum)
        case .ps3:
            return bytes.count == 9 && bytes.prefix(4).allSatisfy(isAsciiAlpha) && bytes.dropFirst(4).allSatisfy(isAsciiDigit)
        case .switchConsole:
            return bytes.count == 5 && bytes.allSatisfy(isAsciiAlnum)
        default:
            return false
        }
    }

    private func gameTDBInfo(for platform: GameMetadataPlatform) -> (db: String, artPrefix: String)? {
        switch platform {
        case .nds: return ("dstdb", "ds")
        case .threeDS: return ("3dstdb", "3ds")
        case .wii, .gamecube: return ("wiitdb", "wii")
        case .wiiu: return ("wiiutdb", "wiiu")
        case .ps3: return ("ps3tdb", "ps3")
        default: return nil
        }
    }

    private func gameTDBBoxartByID(_ id: String, platform: GameMetadataPlatform, language: String) async -> DownloadedArtwork? {
        guard let tdbInfo = gameTDBInfo(for: platform), Self.isValidGameTDBID(id, platform: platform) else { return nil }
        let regions = language == "ja" ? ["JA", "US", "EN"] : (language == "zh" ? ["ZH", "US", "EN", "JA"] : ["US", "EN", "JA"])
        for coverType in ["coverHQ", "cover", "cover3D"] {
            for region in regions {
                for ext in ["jpg", "png"] {
                    guard let url = URL(string: "https://art.gametdb.com/\(tdbInfo.artPrefix)/\(coverType)/\(region)/\(id).\(ext)"),
                          let data = try? await download(url), pixelArea(data) > 10000 else { continue }
                    return DownloadedArtwork(data: data, fileExtension: imageExtension(for: data) ?? ext, sourceURL: url.absoluteString)
                }
            }
        }
        return nil
    }

    private func gameTDBBoxart(for title: String, platform: GameMetadataPlatform, language: String) async -> DownloadedArtwork? {
        if platform == .switchConsole {
            return await switchBoxartData(for: title, language: language)
        }
        guard let tdbInfo = gameTDBInfo(for: platform) else { return nil }
        let catalogLang: String
        if GameTitleMatcher.hasHan(title) {
            catalogLang = "ZHCN"
        } else if GameTitleMatcher.hasKana(title) {
            catalogLang = "JA"
        } else {
            catalogLang = "EN"
        }
        let cacheKey = "\(tdbInfo.db)-\(catalogLang)"
        let entries: [(id: String, title: String, normalized: String)]
        if let cached = gameTDBCatalogs[cacheKey] {
            entries = cached
        } else {
            let task: Task<[(id: String, title: String, normalized: String)], Never>
            if let existing = gameTDBCatalogTasks[cacheKey] {
                task = existing
            } else {
                let db = tdbInfo.db
                task = Task { [weak self] in
                    guard let self,
                          let url = URL(string: "https://www.gametdb.com/\(db).txt?LANG=\(catalogLang)"),
                          let data = try? await self.download(url),
                          let text = String(data: data, encoding: .utf8) else { return [] }
                    return text.split(whereSeparator: \.isNewline).compactMap { line in
                        guard let sep = line.range(of: " = ") else { return nil }
                        let id = String(line[..<sep.lowerBound]).trimmingCharacters(in: .whitespaces)
                        let name = String(line[sep.upperBound...]).trimmingCharacters(in: .whitespaces)
                        guard Self.isValidGameTDBID(id, platform: platform), !name.isEmpty else { return nil }
                        return (id: id, title: name, normalized: GameTitleMatcher.normalize(name))
                    }
                }
                gameTDBCatalogTasks[cacheKey] = task
            }
            entries = await task.value
            gameTDBCatalogTasks[cacheKey] = nil
            guard !entries.isEmpty else { return nil }
            gameTDBCatalogs[cacheKey] = entries
        }

        let normalizedQuery = normalize(title)
        let candidate = entries
            .map { (entry: $0, score: GameTitleMatcher.scoreNormalized(normalizedQuery, $0.normalized)) }
            .max { $0.score < $1.score }
        guard let candidate, candidate.score >= max(0.78, minimumMatchScore(for: title)) else { return nil }

        return await gameTDBBoxartByID(candidate.entry.id, platform: platform, language: language)
    }

    // MARK: - Wikipedia Wide Image & Switch Banner

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
                  w >= MetadataRefreshPolicy.preferredHDWidth, h >= MetadataRefreshPolicy.preferredHDHeight,
                  Double(w) / Double(h) >= 1.35, Double(w) / Double(h) <= 2.35,
                  let imgURLStr = (info["thumburl"] as? String) ?? (info["url"] as? String),
                  let imgURL = URL(string: imgURLStr) else { continue }
            candidates.append((imgURL, w * h))
        }
        for item in candidates.sorted(by: { $0.area > $1.area }).prefix(3) {
            if let imgData = try? await download(item.url),
               let dims = pixelDimensions(imgData),
               dims.width >= MetadataRefreshPolicy.preferredHDWidth,
               dims.height >= MetadataRefreshPolicy.preferredHDHeight {
                let ratio = Double(dims.width) / Double(dims.height)
                if ratio >= 1.35 && ratio <= 2.35 {
                    let ext = imageExtension(for: imgData) ?? (item.url.pathExtension.lowercased() == "png" ? "png" : "jpg")
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
        return DownloadedArtwork(data: data, fileExtension: imageExtension(for: data) ?? "jpg", sourceURL: url.absoluteString)
    }

    // MARK: - Switch Title ID & Switch 2 Containers

    private func switchTitleID(from sourceURL: URL) -> String? {
        var candidates = [sourceURL.lastPathComponent]
        let manifestPaths: [(String, String)] = [
            ("Contents/Resources/dm/launcher.json", "game"),
            ("Contents/Resources/S2ArmStandalone/standalone.json", "gameID"),
            ("manifest.json", "titleID"),
            ("Builds/S2Arm/manifest.json", "titleID"),
            ("Builds/NXNative/manifest.json", "titleID")
        ]
        for (relative, key) in manifestPaths {
            if let data = try? Data(contentsOf: sourceURL.appendingPathComponent(relative)),
               let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let id = info[key] as? String {
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
        guard let header = read(0, 128), header.prefix(3) == Data("NUP".utf8),
              let tocOffset = Self.readLittleEndian(header, at: 8, as: UInt64.self),
              let tocSize = Self.readLittleEndian(header, at: 16, as: UInt64.self),
              let declaredSize = Self.readLittleEndian(header, at: 64, as: UInt64.self),
              let packageCount = Self.readLittleEndian(header, at: 72, as: UInt32.self),
              declaredSize == fileSize, packageCount > 0, packageCount <= 2048,
              tocOffset <= fileSize, tocSize <= fileSize - tocOffset,
              UInt64(48) + UInt64(packageCount) * 64 <= tocSize,
              let tocHeader = read(tocOffset, 48), tocHeader.prefix(4) == Data([0x54, 0x4f, 0x43, 0x01]),
              Self.readLittleEndian(tocHeader, at: 4, as: UInt32.self) == packageCount,
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
            guard let titleID = Self.readLittleEndian(packageTable, at: offset, as: UInt64.self),
                  let kind = Self.readLittleEndian(packageTable, at: offset + 24, as: UInt8.self),
                  let metadataOffset = Self.readLittleEndian(packageTable, at: offset + 28, as: UInt64.self),
                  let metadataSize = Self.readLittleEndian(packageTable, at: offset + 36, as: UInt32.self),
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
                guard let type = Self.readLittleEndian(metadata, at: cursor, as: UInt16.self),
                      let length = Self.readLittleEndian(metadata, at: cursor + 4, as: UInt32.self) else { break }
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
        if data.count >= 12,
           data.prefix(4) == Data("RIFF".utf8),
           data.subdata(in: 8..<12) == Data("WEBP".utf8) { return "webp" }
        return nil
    }

    // MARK: - Wikipedia

    private func wikipediaResult(for title: String, language: String, localizedTitle: String? = nil) async -> WikipediaGamePage? {
        if language == "en" { return await searchWikipediaWithGameFallback(language: "en", title: title) }
        let query = localizedTitle.flatMap { GameTitleMatcher.hasHan($0) || GameTitleMatcher.hasKana($0) ? $0 : nil } ?? title
        async let preferredLookup = searchWikipediaWithGameFallback(language: language, title: query)
        async let englishLookup = searchWikipediaWithGameFallback(language: "en", title: title)
        let (preferredPage, englishPage) = await (preferredLookup, englishLookup)
        let preferredIsGame = preferredPage.map { Self.looksLikeVideoGame(title: $0.title, extract: $0.synopsis ?? "") } ?? false
        let englishIsGame = englishPage.map { Self.looksLikeVideoGame(title: $0.title, extract: $0.synopsis ?? "") } ?? false
        let linkedPreferredPage: WikipediaGamePage?
        if (preferredPage == nil || (!preferredIsGame && englishIsGame)), let englishPage {
            linkedPreferredPage = await wikipediaLanguageLinkPage(from: englishPage.title, language: language)
        } else { linkedPreferredPage = nil }
        guard let preferredPage = linkedPreferredPage ?? preferredPage else { return englishPage }

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

    private func searchWikipediaWithGameFallback(language: String, title: String) async -> WikipediaGamePage? {
        let direct = await searchWikipedia(language: language, title: title, searchQuery: title)
        if let direct, Self.looksLikeVideoGame(title: direct.title, extract: direct.synopsis ?? "") {
            return direct
        }
        let suffix: String
        switch language {
        case "zh": suffix = " 电子游戏"
        case "ja": suffix = " ゲーム"
        default: suffix = " video game"
        }
        if let gameFocused = await searchWikipedia(language: language, title: title, searchQuery: title + suffix),
           Self.looksLikeVideoGame(title: gameFocused.title, extract: gameFocused.synopsis ?? "") {
            return gameFocused
        }
        return direct
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

    // MARK: - Baidu Baike

    private struct BaikePage {
        let title: String
        let synopsis: String
        let pageURL: URL
        let artworkURL: URL?
        let latinTitle: String?
    }

    /// Baidu Baike covers Chinese-context games Wikipedia misses — regional
    /// releases, Chinese translations and ROM hacks — and its image CDN is
    /// reachable where upload.wikimedia.org is not.
    private func baikeLookupTask(title: String, filenameTitle: String?, language: String) async -> BaikePage? {
        guard language == "zh" else { return nil }
        let candidate = filenameTitle ?? title
        guard GameTitleMatcher.hasHan(candidate) else { return nil }
        return await baikePage(for: candidate)
    }

    private func baikePage(for title: String) async -> BaikePage? {
        trace("baike: query \(title)")
        if let page = await baikeDirectPage(for: title) { return page }
        var queries = [title]
        queries += title.split(separator: " ").map(String.init).filter { GameTitleMatcher.hasHan($0) && $0.count >= 3 }
        var best: (page: BaikePage, overlap: Int)?
        var seen = Set<String>()
        var fetched = 0
        nextQuery: for query in queries {
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

    private func baikeDirectPage(for title: String) async -> BaikePage? {
        guard let url = baikeLemmaURL(title) else { return nil }
        guard let page = await baikePage(at: url), Self.sharesHan(page.title, title) else { return nil }
        return page
    }

    private func baikeSearchURL(for query: String) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "https://wapbaike.baidu.com/search/none?word=" + encoded)
    }

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
        subjectChineseAliases(in: synopsis).first
    }

    /// Extracts Chinese titles from the lead subject clause of a Wikipedia extract
    /// (e.g. `《塞尔达传说 旷野之息》（……中国大陆译作“……”）`), ignoring book titles
    /// mentioned later in biographies or soundtrack articles.
    private func subjectChineseAliases(in synopsis: String?) -> [String] {
        guard let synopsis else { return [] }
        let trimmed = synopsis.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("《") else { return [] }
        let leadEnd = trimmed.firstIndex(where: { "。！？\n".contains($0) }) ?? trimmed.endIndex
        let lead = String(trimmed[..<leadEnd])
        let pattern = #"《([^》]{2,80})》|“([^”]{2,40})”|「([^」]{2,40})」"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var aliases: [String] = []
        let matches = regex.matches(in: lead, range: NSRange(lead.startIndex..., in: lead))
        for match in matches.prefix(6) {
            for group in 1...3 {
                let r = match.range(at: group)
                if r.location != NSNotFound, let range = Range(r, in: lead) {
                    let value = String(lead[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty { aliases.append(value) }
                }
            }
        }
        return aliases
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

    private func searchWikipedia(language: String, title: String, searchQuery: String) async -> WikipediaGamePage? {
        guard var components = URLComponents(string: "https://\(language).wikipedia.org/w/api.php") else {
            return nil
        }
        components.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "generator", value: "search"),
            URLQueryItem(name: "gsrsearch", value: searchQuery),
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
        if language == "zh" {
            components.queryItems?.append(URLQueryItem(name: "variant", value: "zh-cn"))
        }
        guard let url = components.url,
              let data = try? await download(url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let query = root["query"] as? [String: Any],
              let pages = query["pages"] as? [[String: Any]] else {
            return nil
        }

        let best = pages
            .compactMap { page -> (rawScore: Double, rankedScore: Double, page: [String: Any])? in
                guard let pageTitle = page["title"] as? String else { return nil }
                let extract = page["extract"] as? String ?? ""
                let titleScore = matchScore(title, pageTitle)
                let aliases = subjectChineseAliases(in: extract)
                let aliasScore = aliases.map { matchScore(title, $0) }.max() ?? 0
                let rawScore = max(titleScore, aliasScore)
                let isGameArticle = Self.looksLikeVideoGame(title: pageTitle, extract: extract)
                let isDerivative = Self.looksLikeDerivativeArticle(title: pageTitle)
                let titleBonus = titleScore >= aliasScore ? 0.02 : 0
                let rankedScore = rawScore + (isGameArticle ? 0.05 : 0) + titleBonus - (isDerivative ? 0.20 : 0)
                return (rawScore, rankedScore, page)
            }
            .max { lhs, rhs in
                if abs(lhs.rankedScore - rhs.rankedScore) > 0.001 {
                    return lhs.rankedScore < rhs.rankedScore
                }
                return lhs.rawScore < rhs.rawScore
            }

        guard let best, best.rawScore >= minimumWikipediaMatchScore(for: title),
              !Self.looksLikeDerivativeArticle(title: (best.page["title"] as? String) ?? "") else {
            return nil
        }

        return wikipediaPage(from: best.page)
    }

    private static func looksLikeDerivativeArticle(title: String) -> Bool {
        let lower = title.lowercased()
        let markers = [
            "music of ", "soundtrack", "characters of ", "list of ", "discography",
            "的音乐", "原声", "角色列表", "人物列表", "攻略", "漫画", "小说", "电影版"
        ]
        return markers.contains { lower.contains($0) }
    }

    private static func looksLikeVideoGame(title: String, extract: String) -> Bool {
        let combined = (title + " " + extract).lowercased()
        let keywords = [
            "video game", "action-adventure", "role-playing", "platform game", "platformer",
            "nintendo", "playstation", "xbox", "game boy", "sega", "capcom", "square enix",
            "电子游戏", "动作冒险", "角色扮演", "任天堂", "索尼", "游戏机", "掌机", "电玩", "游戏作品",
            "ゲーム", "ロールプレイング", "アクション"
        ]
        return keywords.contains { combined.contains($0) }
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

    // MARK: - Libretro Thumbnails & SwitchTDB

    private func boxartData(for title: String, platform: GameMetadataPlatform, language: String) async -> DownloadedArtwork? {
        if platform == .switchConsole {
            return await switchBoxartData(for: title, language: language)
        }
        return await libretroMediaData(for: title, platform: platform, directory: "Named_Boxarts")
    }

    private func libretroMediaData(for title: String, platform: GameMetadataPlatform, directory: String) async -> DownloadedArtwork? {
        guard platform.isRetroConsole,
              let match = await closestLibretroAsset(to: title, platform: platform, directory: directory),
              let encoded = match.filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: encoded, relativeTo: match.source)?.absoluteURL else {
            return nil
        }
        if let data = try? await download(url), pixelArea(data) > 0 {
            return DownloadedArtwork(data: data, fileExtension: imageExtension(for: data) ?? "png", sourceURL: url.absoluteString)
        }
        guard let mirror = mirrorArtworkURL(for: encoded, platform: platform, directory: directory),
              let data = try? await download(mirror), pixelArea(data) > 0 else { return nil }
        return DownloadedArtwork(data: data, fileExtension: imageExtension(for: data) ?? "png", sourceURL: mirror.absoluteString)
    }

    private func mirrorArtworkURL(for encodedFilename: String, platform: GameMetadataPlatform, directory: String = "Named_Boxarts") -> URL? {
        guard let systemFolder = retroSystemFolder(for: platform) else { return nil }
        let repository = systemFolder.replacingOccurrences(of: " ", with: "_")
        return URL(string: "https://raw.githubusercontent.com/libretro-thumbnails/\(repository)/master/\(directory)/\(encodedFilename)")
    }

    private func switchBoxartData(for title: String, language: String) async -> DownloadedArtwork? {
        // Match the catalog script to the candidate query so English titles search EN
        // and Chinese titles search ZHCN (instead of comparing English against ZHCN).
        let catalogLanguage: String
        if GameTitleMatcher.hasHan(title) {
            catalogLanguage = "ZHCN"
        } else if GameTitleMatcher.hasKana(title) {
            catalogLanguage = "JA"
        } else {
            catalogLanguage = "EN"
        }
        let coverLanguage: String
        switch language {
        case "ja": coverLanguage = "JA"
        case "zh", "zh-Hans": coverLanguage = "ZH"
        default: coverLanguage = "EN"
        }

        let entries: [(id: String, title: String, normalized: String)]
        if let cached = switchCatalogs[catalogLanguage] {
            entries = cached
        } else {
            let task: Task<[(id: String, title: String, normalized: String)], Never>
            if let existing = switchCatalogTasks[catalogLanguage] {
                task = existing
            } else {
                task = Task { [weak self] in
                    guard let self,
                          let url = URL(string: "https://www.gametdb.com/switchtdb.txt?LANG=\(catalogLanguage)"),
                          let data = try? await self.download(url),
                          let text = String(data: data, encoding: .utf8) else { return [] }
                    return text.split(whereSeparator: \.isNewline).compactMap { line in
                        guard let separator = line.range(of: " = ") else { return nil }
                        let id = String(line[..<separator.lowerBound]).trimmingCharacters(in: .whitespaces)
                        let name = String(line[separator.upperBound...]).trimmingCharacters(in: .whitespaces)
                        guard Self.isValidGameTDBID(id, platform: .switchConsole), !name.isEmpty else { return nil }
                        return (id: id, title: name, normalized: GameTitleMatcher.normalize(name))
                    }
                }
                switchCatalogTasks[catalogLanguage] = task
            }
            entries = await task.value
            switchCatalogTasks[catalogLanguage] = nil
            guard !entries.isEmpty else { return nil }
            switchCatalogs[catalogLanguage] = entries
        }

        let normalizedQuery = normalize(title)
        let candidate = entries
            .map { (entry: $0, score: GameTitleMatcher.scoreNormalized(normalizedQuery, $0.normalized)) }
            .max { $0.score < $1.score }
        guard let candidate, candidate.score >= max(0.80, minimumMatchScore(for: title)) else { return nil }

        var regions: [String] = []
        for region in [coverLanguage, "EN", "US", "JA"] where !regions.contains(region) {
            regions.append(region)
        }
        for coverType in ["coverHQ", "cover"] {
            for region in regions {
                guard let url = URL(string: "https://art.gametdb.com/switch/\(coverType)/\(region)/\(candidate.entry.id).jpg"),
                      let data = try? await download(url), pixelArea(data) > 0 else { continue }
                return DownloadedArtwork(data: data, fileExtension: imageExtension(for: data) ?? "jpg", sourceURL: url.absoluteString)
            }
        }
        return nil
    }

    private func closestLibretroAsset(to title: String, platform: GameMetadataPlatform, directory: String) async -> (filename: String, source: URL)? {
        let cacheKey = "\(platform.rawValue):\(directory)"
        let entries: [(filename: String, normalized: String)]
        if let cached = artworkCatalogs[cacheKey] {
            entries = cached
        } else {
            let task: Task<[(filename: String, normalized: String)], Never>
            if let existing = artworkCatalogTasks[cacheKey] {
                task = existing
            } else {
                task = Task { [weak self] in
                    guard let self else { return [] }
                    let filenames = await self.libretroCatalog(platform: platform, directory: directory, cacheKey: cacheKey)
                    return filenames.map { ($0, GameTitleMatcher.normalize($0)) }
                }
                artworkCatalogTasks[cacheKey] = task
            }
            entries = await task.value
            artworkCatalogTasks[cacheKey] = nil
            if !entries.isEmpty { artworkCatalogs[cacheKey] = entries }
        }
        let source = artworkCatalogSources[cacheKey] ?? libretroIndexURL(for: platform, directory: directory)

        let normalizedQuery = normalize(title)
        let match = entries
            .map { (filename: $0.filename, score: GameTitleMatcher.scoreNormalized(normalizedQuery, $0.normalized)) }
            .max { $0.score < $1.score }
        guard let match, match.score >= minimumMatchScore(for: title),
              let source else { return nil }
        return (match.filename, source)
    }

    private func libretroCatalog(platform: GameMetadataPlatform, directory: String, cacheKey: String) async -> [String] {
        if let indexURL = libretroIndexURL(for: platform, directory: directory),
           let data = try? await download(indexURL),
           let html = String(data: data, encoding: .utf8) {
            let filenames = boxartFilenames(in: html)
            if !filenames.isEmpty {
                artworkCatalogSources[cacheKey] = indexURL
                return filenames
            }
        }
        guard let systemFolder = retroSystemFolder(for: platform) else { return [] }
        let repository = systemFolder.replacingOccurrences(of: " ", with: "_")
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
            artworkCatalogSources[cacheKey] = URL(string: "https://raw.githubusercontent.com/libretro-thumbnails/\(repository)/master/\(directory)/")
        }
        return filenames
    }

    private func boxartFilenames(in html: String) -> [String] {
        let range = NSRange(html.startIndex..., in: html)
        return Self.boxartHrefRegex.matches(in: html, range: range).compactMap { match in
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
        case .famicom, .dendy: return "Nintendo - Nintendo Entertainment System"
        case .fds: return "Nintendo - Family Computer Disk System"
        case .superFamicom: return "Nintendo - Super Nintendo Entertainment System"
        case .n64, .n64dd: return "Nintendo - Nintendo 64"
        case .megaDrive: return "Sega - Mega Drive - Genesis"
        case .ps1: return "Sony - PlayStation"
        case .ps2: return "Sony - PlayStation 2"
        case .ps3: return "Sony - PlayStation 3"
        case .psv: return "Sony - PlayStation Vita"
        case .gamecube: return "Nintendo - GameCube"
        case .wii: return "Nintendo - Wii"
        case .wiiu: return "Nintendo - Wii U"
        case .dreamcast: return "Sega - Dreamcast"
        case .xbox: return "Microsoft - Xbox"
        case .atari2600: return "Atari - 2600"
        case .colecovision: return "Coleco - ColecoVision"
        case .msx: return "Microsoft - MSX"
        case .msx2: return "Microsoft - MSX2"
        case .pce, .sgx: return "NEC - PC Engine - TurboGrafx 16"
        case .pcecd, .sgxcd: return "NEC - PC Engine CD - TurboGrafx-CD"
        case .sms: return "Sega - Master System - Mark III"
        case .gg: return "Sega - Game Gear"
        case .segacd, .segacd32x: return "Sega - Mega-CD - Sega CD"
        case .sega32x: return "Sega - 32X"
        case .sg1000, .sc3000: return "Sega - SG-1000"
        case .ws: return "Bandai - WonderSwan"
        case .wsc: return "Bandai - WonderSwan Color"
        case .ngp: return "SNK - Neo Geo Pocket"
        case .ngpc: return "SNK - Neo Geo Pocket Color"
        case .aes, .mvs: return "SNK - Neo Geo"
        case .arcade: return "FBNeo - Arcade Games"
        case .zx, .zx128: return "Sinclair - ZX Spectrum"
        default: return nil
        }
    }

    private func libretroIndexURL(for platform: GameMetadataPlatform, directory: String) -> URL? {
        guard let systemFolder = retroSystemFolder(for: platform) else { return nil }
        let encodedFolder = systemFolder.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? systemFolder
        return URL(string: "https://thumbnails.libretro.com/\(encodedFolder)/\(directory)/")
    }

    // MARK: - Networking & Utilities

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
        MetadataRefreshPolicy.imageDimensions(data: data)
    }

    private func pixelArea(_ data: Data) -> Int {
        guard let dims = pixelDimensions(data) else { return 0 }
        return dims.width * dims.height
    }

    private func normalize(_ value: String) -> String { GameTitleMatcher.normalize(value) }
    private func matchScore(_ source: String, _ candidate: String) -> Double { GameTitleMatcher.score(source, candidate) }
    private func minimumMatchScore(for title: String) -> Double { GameTitleMatcher.threshold(title) }
    private func minimumWikipediaMatchScore(for title: String) -> Double { GameTitleMatcher.threshold(title, wikipedia: true) }

    private func cleanSynopsis(_ synopsis: String) -> String {
        let singleLine = synopsis.replacingOccurrences(of: "\n", with: " ")
        let range = NSRange(location: 0, length: (singleLine as NSString).length)
        let flattened = Self.whitespaceRegex.stringByReplacingMatches(in: singleLine, range: range, withTemplate: " ")
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

private struct LocalGameMetadata {
    let title: String?
    let productID: String?
    let icon: DownloadedArtwork?
    let backdrop: DownloadedArtwork?
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
