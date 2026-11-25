import Foundation

enum GamePlatform: String, Codable, CaseIterable, Identifiable {
    case gba
    case gb
    case gbc
    case nds
    case threeDS
    case psp
    case famicom
    case superFamicom
    case n64
    case megaDrive
    case ps1
    case psv, ps2, ps3, ps4, gamecube, wii, wiiu, dreamcast, xbox
    case switchConsole
    case macOS
    case atari2600, colecovision, msx, msx2, pce, pcecd, sgx, sgxcd
    case sms, gg, segacd, sega32x, segacd32x, sg1000, sc3000, ws, wsc
    case ngp, ngpc, aes, mvs, n64dd, dendy, fds, pcv2, myvision, zx, zx128, arcade, megald, pcld

    // macOS-only systems share the same catalog for scanning, display and launch.
    struct MacSystem {
        let title: String
        let shortTitle: String
        let emulator: String
        let extensions: Set<String>

        init(_ title: String, _ shortTitle: String, _ emulator: String, _ extensions: [String]) {
            self.title = title
            self.shortTitle = shortTitle
            self.emulator = emulator
            self.extensions = Set(extensions)
        }
    }

    static let macSystems: [GamePlatform: MacSystem] = [
        .psv: .init("PlayStation Vita", "PS Vita", "Vita3K", ["vpk", "zip"]),
        .ps2: .init("PlayStation 2", "PS2", "PCSX2", ["iso", "chd", "cso", "bin", "gz", "elf"]),
        .ps3: .init("PlayStation 3", "PS3", "RPCS3", ["iso", "self"]),
        .ps4: .init("PlayStation 4", "PS4", "shadPS4", []),
        .gamecube: .init("Nintendo GameCube", "GameCube", "Dolphin", ["gcm", "iso", "rvz", "gcz", "ciso", "tgc", "dol", "elf"]),
        .wii: .init("Nintendo Wii", "Wii", "Dolphin", ["iso", "wbfs", "rvz", "gcz", "ciso", "wad", "dol", "elf"]),
        .wiiu: .init("Nintendo Wii U", "Wii U", "Cemu", ["wua", "wux", "wud", "rpx", "wuhb"]),
        .dreamcast: .init("Sega Dreamcast", "Dreamcast", "Flycast", ["gdi", "cdi", "chd", "cue"]),
        .xbox: .init("Xbox", "Xbox", "xemu", ["iso"]),
        .atari2600: .init("Atari 2600", "Atari 2600", "ares", ["a26", "bin"]),
        .colecovision: .init("ColecoVision", "ColecoVision", "ares", ["col"]),
        .msx: .init("MSX", "MSX", "ares", ["rom", "msx", "cas"]),
        .msx2: .init("MSX2", "MSX2", "ares", ["rom", "msx2", "cas"]),
        .pce: .init("PC Engine", "PC Engine", "ares", ["pce"]),
        .pcecd: .init("PC Engine CD", "PC Engine CD", "ares", ["cue", "chd"]),
        .sgx: .init("SuperGrafx", "SuperGrafx", "ares", ["sgx"]),
        .sgxcd: .init("SuperGrafx CD", "SuperGrafx CD", "ares", ["cue", "chd"]),
        .sms: .init("Master System", "Master System", "ares", ["sms", "ms"]),
        .gg: .init("Game Gear", "Game Gear", "ares", ["gg"]),
        .segacd: .init("Mega CD", "Mega CD", "ares", ["cue", "chd"]),
        .sega32x: .init("Mega 32X", "Mega 32X", "ares", ["32x"]),
        .segacd32x: .init("Mega CD 32X", "Mega CD 32X", "ares", ["cue", "chd"]),
        .sg1000: .init("SG-1000", "SG-1000", "ares", ["sg", "sg1000"]),
        .sc3000: .init("SC-3000", "SC-3000", "ares", ["sc", "sg"]),
        .ws: .init("WonderSwan", "WonderSwan", "ares", ["ws"]),
        .wsc: .init("WonderSwan Color", "WonderSwan Color", "ares", ["wsc"]),
        .ngp: .init("Neo Geo Pocket", "Neo Geo Pocket", "ares", ["ngp"]),
        .ngpc: .init("Neo Geo Pocket Color", "Neo Geo Pocket Color", "ares", ["ngpc", "ngc"]),
        .aes: .init("Neo Geo AES", "Neo Geo AES", "ares", ["ng", "zip"]),
        .mvs: .init("Neo Geo MVS", "Neo Geo MVS", "ares", ["ng", "zip"]),
        .n64dd: .init("Nintendo 64DD", "Nintendo 64DD", "ares", ["ndd", "d64", "n64dd"]),
        .dendy: .init("Dendy", "Dendy", "ares", ["nes"]),
        .fds: .init("Famicom Disk System", "Famicom Disk System", "ares", ["fds"]),
        .pcv2: .init("Pocket Challenge V2", "Pocket Challenge V2", "ares", ["pc2", "pcv2"]),
        .myvision: .init("MyVision", "MyVision", "ares", ["myv"]),
        .zx: .init("ZX Spectrum", "ZX Spectrum", "ares", ["tap", "tzx", "wav"]),
        .zx128: .init("ZX Spectrum 128", "ZX Spectrum 128", "ares", ["tap", "tzx", "wav"]),
        .arcade: .init("Arcade", "Arcade", "ares", ["zip"]),
        .megald: .init("LaserActive (SEGA PAC)", "LaserActive (SEGA PAC)", "ares", ["mmi"]),
        .pcld: .init("LaserActive (NEC PAC)", "LaserActive (NEC PAC)", "ares", ["mmi"]),
    ]

    static let allCases: [GamePlatform] = [
        .gb, .gbc, .gba, .nds, .threeDS, .wii, .wiiu,
        .switchConsole, .psp, .psv, .ps1, .ps2, .ps3, .macOS
    ]

    var isEnabled: Bool { Self.allCases.contains(self) }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gba: AppLanguage.localized("Game Boy Advance")
        case .gb: AppLanguage.localized("Game Boy")
        case .gbc: AppLanguage.localized("Game Boy Color")
        case .nds: AppLanguage.localized("Nintendo DS")
        case .threeDS: AppLanguage.localized("Nintendo 3DS")
        case .psp: AppLanguage.localized("PlayStation Portable")
        case .famicom: AppLanguage.localized("红白机")
        case .superFamicom: AppLanguage.localized("超任")
        case .n64: AppLanguage.localized("Nintendo 64")
        case .megaDrive: AppLanguage.localized("Mega Drive")
        case .ps1: AppLanguage.localized("PlayStation")
        case .switchConsole: AppLanguage.localized("Nintendo Switch")
        case .macOS: AppLanguage.localized("macOS 原生游戏")
        default: Self.macSystems[self]!.title
        }
    }

    var shortTitle: String {
        switch self {
        case .gba: "GBA"
        case .gb: "GB"
        case .gbc: "GBC"
        case .nds: "NDS"
        case .threeDS: "3DS"
        case .psp: "PSP"
        case .famicom: "红白机"
        case .superFamicom: "超任"
        case .n64: "N64"
        case .megaDrive: "MD"
        case .ps1: "PS1"
        case .switchConsole: "Switch"
        case .macOS: "macOS"
        default: Self.macSystems[self]!.shortTitle
        }
    }

    var symbol: String {
        switch self {
        case .gba, .gb, .gbc, .psp: "gamecontroller"
        case .nds, .threeDS: "rectangle.split.2x1"
        case .famicom, .superFamicom, .n64, .megaDrive, .ps1: "gameconsole"
        case .switchConsole: "gamecontroller.fill"
        case .macOS: "macwindow"
        default: "gameconsole"
        }
    }

    var isRetroConsole: Bool {
        switch self {
        case .gba, .gb, .gbc, .nds, .threeDS, .psp, .famicom, .superFamicom, .n64, .megaDrive, .ps1: true
        case .switchConsole, .macOS: false
        default: true
        }
    }

    static func detect(for url: URL) -> GamePlatform? {
        switch url.pathExtension.lowercased() {
        case "gba": .gba
        case "gb": .gb
        case "gbc": .gbc
        case "nds": .nds
        case "3ds", "3dsx", "cci", "cxi", "cia": .threeDS
        case "iso", "cso", "pbp": .psp
        case "nes", "unf", "unif", "fds": .famicom
        case "sfc", "smc", "fig", "swc": .superFamicom
        case "n64", "v64", "z64", "ndd": .n64
        case "gen", "md", "smd": .megaDrive
        case "cue", "chd", "m3u": .ps1
        case "app": .macOS
        default: nil
        }
    }

    static func detect(for url: URL, under root: URL) -> GamePlatform? {
        let folderNames: [String: GamePlatform] = [
            "gba": .gba,
            "gb": .gb,
            "gbc": .gbc,
            "nds": .nds,
            "3ds": .threeDS,
            "3dsx": .threeDS,
            "psp": .psp,
            "famicom": .famicom,
            "fc": .famicom,
            "nes": .famicom,
            "superfamicom": .superFamicom,
            "sfc": .superFamicom,
            "snes": .superFamicom,
            "n64": .n64,
            "md": .megaDrive,
            "megadrive": .megaDrive,
            "mega drive": .megaDrive,
            "ps1": .ps1,
            "psx": .ps1,
            "vita": .psv, "psvita": .psv, "ps vita": .psv,
            "gc": .gamecube, "ngc": .gamecube, "dc": .dreamcast, "wii u": .wiiu,
            "mac": .macOS,
            "macos": .macOS,
            "switch": .switchConsole
        ]
        let rootComponents = root.standardizedFileURL.pathComponents
        let fileComponents = url.deletingLastPathComponent().standardizedFileURL.pathComponents
        guard fileComponents.starts(with: rootComponents) else { return nil }
        let relativeDirectories = Array(fileComponents.dropFirst(rootComponents.count))
        func platform(for name: String) -> GamePlatform? {
            let key = name.lowercased()
            return folderNames[key] ?? GamePlatform(rawValue: key)
        }
        let platformFolder = relativeDirectories.reversed().compactMap(platform(for:)).first
            ?? platform(for: root.lastPathComponent)
        guard let platformFolder, platformFolder.isEnabled else { return nil }
        let fileExtension = url.pathExtension.lowercased()
        if platformFolder == .switchConsole && isSwitch2DumpFolder(url) {
            return .switchConsole
        }
        if let system = macSystems[platformFolder] {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                let marker: String
                switch platformFolder {
                case .wiiu:
                    return MobileLibraryFormat.isGameFolder(url, runtime: "cemu") ? .wiiu : nil
                case .ps3:
                    return MobileLibraryFormat.isGameFolder(url, runtime: "rpcs3") ? .ps3 : nil
                case .ps4: marker = "eboot.bin"
                case .psv: return MobileLibraryFormat.isVitaGameFolder(url) ? .psv : nil
                default: return nil
                }
                guard FileManager.default.fileExists(atPath: url.appendingPathComponent(marker).path) else { return nil }
                return platformFolder
            }
            // Installed PS3 digital titles can also be launched via their USRDIR executable.
            if platformFolder == .ps3, url.lastPathComponent.uppercased() == "EBOOT.BIN",
               url.deletingLastPathComponent().lastPathComponent.uppercased() == "USRDIR" { return .ps3 }
            return system.extensions.contains(fileExtension) ? platformFolder : nil
        }
        switch platformFolder {
        case .gba where fileExtension == "gba": return .gba
        case .gb where ["gb", "zip"].contains(fileExtension): return .gb
        case .gbc where ["gbc", "zip"].contains(fileExtension): return .gbc
        case .nds where fileExtension == "nds": return .nds
        case .threeDS where ["3ds", "3dsx", "cci", "cxi", "app"].contains(fileExtension): return .threeDS
        case .psp where ["iso", "cso", "pbp", "chd"].contains(fileExtension): return .psp
        case .famicom where ["nes", "unf", "unif", "fds", "zip"].contains(fileExtension): return .famicom
        case .superFamicom where ["sfc", "smc", "fig", "swc", "zip"].contains(fileExtension): return .superFamicom
        case .n64 where ["n64", "v64", "z64", "ndd", "zip"].contains(fileExtension): return .n64
        case .megaDrive where ["md", "gen", "smd", "bin", "zip"].contains(fileExtension): return .megaDrive
        case .ps1 where ["cue", "ccd", "img", "chd", "m3u", "pbp", "iso", "bin"].contains(fileExtension): return .ps1
        case .macOS where fileExtension == "app": return .macOS
        case .switchConsole where ["app", "nsp", "xci", "nsz", "xcz", "nup", "nro", "nso", "nca"].contains(fileExtension): return .switchConsole
        default: return nil
        }
    }

    static func isSwitch2DumpFolder(_ url: URL) -> Bool {
        let fileManager = FileManager.default
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
              let children = try? fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
              ) else { return false }

        // A folder may simply contain a packed NUP, or it may be an unpacked
        // nxnative dump. The latter is either exefs/ + romfs/ at the root or
        // base/exefs/ + base/romfs/. Updates can carry the complete game on
        // their own, so inspect version folders under updates as well.
        if children.contains(where: { $0.pathExtension.lowercased() == "nup" }) { return true }

        func hasDumpLayout(_ folder: URL) -> Bool {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { return false }
            let directories = Set(entries.compactMap { entry -> String? in
                guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
                return entry.lastPathComponent.lowercased()
            })
            return directories.contains("exefs") && directories.contains("romfs")
        }

        if hasDumpLayout(url) { return true }
        if let base = children.first(where: { $0.lastPathComponent.lowercased() == "base" }), hasDumpLayout(base) {
            return true
        }
        guard let updates = children.first(where: { $0.lastPathComponent.lowercased() == "updates" }),
              let versions = try? fileManager.contentsOfDirectory(
                at: updates,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
              ) else { return false }
        return versions.contains(where: hasDumpLayout)
    }
}

struct Game: Identifiable, Codable, Hashable {
    var id: UUID
    var title: String
    var platform: GamePlatform
    var bookmark: Data
    var artworkBookmark: Data?
    var synopsis: String?
    var metadataTitle: String?
    var metadataSourceURL: String?
    var artworkSourceURL: String?
    var metadataArtworkPath: String?
    var metadataBackdropPath: String?
    var metadataStatus: String?
    var metadataLastUpdated: Date?
    var metadataLanguage: String?
    var addedAt: Date
    var lastPlayedAt: Date?
    var isFavorite: Bool

    var isDirectlyLaunchable: Bool {
        platform != .switchConsole || ((try? resolvedURL().pathExtension.lowercased()) == "app")
    }

    /// Always derives the user-visible title from the game's file/folder name (never online metadata).
    var displayTitle: String {
        if let url = try? resolvedURL() {
            let ext = url.pathExtension.lowercased()
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if isDir && ext != "app" {
                let name = url.lastPathComponent
                if !name.isEmpty { return name }
            } else {
                let name = url.deletingPathExtension().lastPathComponent
                if !name.isEmpty { return name }
            }
        }
        return title
    }

    init(
        id: UUID = UUID(),
        title: String,
        platform: GamePlatform,
        bookmark: Data,
        artworkBookmark: Data? = nil,
        synopsis: String? = nil,
        metadataTitle: String? = nil,
        metadataSourceURL: String? = nil,
        artworkSourceURL: String? = nil,
        metadataArtworkPath: String? = nil,
        metadataBackdropPath: String? = nil,
        metadataStatus: String? = nil,
        metadataLastUpdated: Date? = nil,
        metadataLanguage: String? = nil,
        addedAt: Date = .now,
        lastPlayedAt: Date? = nil,
        isFavorite: Bool = false
    ) {
        self.id = id
        self.title = title
        self.platform = platform
        self.bookmark = bookmark
        self.artworkBookmark = artworkBookmark
        self.synopsis = synopsis
        self.metadataTitle = metadataTitle
        self.metadataSourceURL = metadataSourceURL
        self.artworkSourceURL = artworkSourceURL
        self.metadataArtworkPath = metadataArtworkPath
        self.metadataBackdropPath = metadataBackdropPath
        self.metadataStatus = metadataStatus
        self.metadataLastUpdated = metadataLastUpdated
        self.metadataLanguage = metadataLanguage
        self.addedAt = addedAt
        self.lastPlayedAt = lastPlayedAt
        self.isFavorite = isFavorite
    }

    func resolvedURL() throws -> URL {
        var isStale = false
        do {
            return try URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            // SwiftPM Debug runs are not sandboxed. Bookmarks created by the
            // library picker may therefore resolve without a security scope.
            return try URL(
                resolvingBookmarkData: bookmark,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        }
    }
}

enum LibraryFilter: Hashable, Identifiable {
    case all
    case recent
    case favorites
    case platform(GamePlatform)

    var id: String {
        switch self {
        case .all: "all"
        case .recent: "recent"
        case .favorites: "favorites"
        case .platform(let platform): platform.rawValue
        }
    }

    var title: String {
        switch self {
        case .all: AppLanguage.localized("全部游戏")
        case .recent: AppLanguage.localized("最近游玩")
        case .favorites: AppLanguage.localized("收藏")
        case .platform(let platform): platform.title
        }
    }

    var symbol: String {
        switch self {
        case .all: "square.grid.2x2"
        case .recent: "clock"
        case .favorites: "heart"
        case .platform(let platform): platform.symbol
        }
    }
}
