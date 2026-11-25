import Foundation

/// The emulator implementation used by the iOS Game Center container.
///
/// This deliberately does not refer to the desktop emulator applications
/// bundled by the macOS target. iOS cores are device-arm64 binaries embedded
/// and signed as part of the mobile application.
struct IOSCoreDescriptor: Identifiable, Hashable {
    let platform: GamePlatform
    let displayName: String
    let moduleName: String
    let requiresJIT: Bool
    let sourceURL: URL

    var id: GamePlatform { platform }
}

enum IOSCoreCatalog {
    // iOS availability is independent of the desktop emulator catalog.
    static let supportedPlatforms: Set<GamePlatform> = [.gb, .gbc, .gba, .nds, .threeDS, .psp, .ps1, .wiiu, .wii, .ps2]

    static let descriptors: [IOSCoreDescriptor] = [
        .init(platform: .gb, displayName: "Gambatte", moduleName: "gambatte_libretro_ios.dylib", requiresJIT: false, sourceURL: URL(string: "https://github.com/libretro/gambatte-libretro")!),
        .init(platform: .gbc, displayName: "Gambatte", moduleName: "gambatte_libretro_ios.dylib", requiresJIT: false, sourceURL: URL(string: "https://github.com/libretro/gambatte-libretro")!),
        .init(platform: .gba, displayName: "mGBA", moduleName: "mgba_libretro.dylib", requiresJIT: false, sourceURL: URL(string: "https://github.com/libretro/mgba")!),
        .init(platform: .nds, displayName: "DeSmuME", moduleName: "desmume_libretro_ios.dylib", requiresJIT: false, sourceURL: URL(string: "https://github.com/libretro/desmume")!),
        .init(platform: .threeDS, displayName: "Azahar", moduleName: "azahar_libretro.dylib", requiresJIT: false, sourceURL: URL(string: "https://github.com/azahar-emu/azahar")!),
        .init(platform: .psp, displayName: "PPSSPP", moduleName: "ppsspp_libretro.dylib", requiresJIT: false, sourceURL: URL(string: "https://github.com/hrydgard/ppsspp")!),
        .init(platform: .wiiu, displayName: "Cemu / MuffinEMU", moduleName: "Cemu", requiresJIT: false, sourceURL: URL(string: "https://github.com/MuffinEMU/Muffin-EMU/tree/v11.8")!),
        .init(platform: .wii, displayName: "Dolphin", moduleName: "dolphin_libretro.dylib", requiresJIT: false, sourceURL: URL(string: "https://github.com/libretro/dolphin")!),
        .init(platform: .ps2, displayName: "PCSX2 / PCEE2", moduleName: "pcee2_libretro.dylib", requiresJIT: false, sourceURL: URL(string: "https://github.com/WizzardSK/pcee2-libretro")!),
        .init(platform: .famicom, displayName: "FCEUmm", moduleName: "fceumm_libretro_ios.dylib", requiresJIT: false, sourceURL: URL(string: "https://github.com/libretro/libretro-fceumm")!),
        .init(platform: .superFamicom, displayName: "Snes9x", moduleName: "snes9x_libretro_ios.dylib", requiresJIT: false, sourceURL: URL(string: "https://github.com/libretro/snes9x")!),
        .init(platform: .n64, displayName: "Mupen64Plus-Next", moduleName: "mupen64plus_next_libretro_ios.dylib", requiresJIT: false, sourceURL: URL(string: "https://github.com/libretro/mupen64plus-libretro-nx")!),
        .init(platform: .megaDrive, displayName: "Genesis Plus GX", moduleName: "genesis_plus_gx_libretro_ios.dylib", requiresJIT: false, sourceURL: URL(string: "https://github.com/libretro/Genesis-Plus-GX")!),
        .init(platform: .ps1, displayName: "SwanStation", moduleName: "swanstation_libretro.dylib", requiresJIT: false, sourceURL: URL(string: "https://github.com/libretro/swanstation")!)
    ].filter { supportedPlatforms.contains($0.platform) }

    static func descriptor(for platform: GamePlatform) -> IOSCoreDescriptor? {
        descriptors.first { $0.platform == platform }
    }

    static let mobilePlatforms: [MobileLibraryFormat.Platform] = descriptors.map { core in
        let folder: String
        let extensions: [String]
        switch core.platform {
        case .gb: (folder, extensions) = ("gb", ["gb"])
        case .gbc: (folder, extensions) = ("gbc", ["gbc"])
        case .gba: (folder, extensions) = ("gba", ["gba"])
        case .nds: (folder, extensions) = ("nds", ["nds"])
        case .threeDS: (folder, extensions) = ("3ds", ["3ds", "cci", "cxi"])
        case .psp: (folder, extensions) = ("psp", ["iso", "cso", "pbp", "chd"])
        case .famicom: (folder, extensions) = ("fc", ["nes", "unf", "unif", "fds"])
        case .superFamicom: (folder, extensions) = ("sfc", ["sfc", "smc", "fig", "swc"])
        case .n64: (folder, extensions) = ("n64", ["n64", "v64", "z64", "ndd"])
        case .megaDrive: (folder, extensions) = ("md", ["md", "gen", "smd", "bin"])
        case .wii: (folder, extensions) = ("wii", ["iso", "wbfs", "rvz", "gcz", "ciso", "wad", "dol", "elf"])
        case .ps2: (folder, extensions) = ("ps2", ["iso", "chd", "cso", "bin", "gz", "elf"])
        case .wiiu: (folder, extensions) = ("wiiu", ["wua", "wux", "wud", "rpx"])
        case .ps1: (folder, extensions) = ("ps1", ["cue", "ccd", "img", "chd", "m3u", "pbp", "iso", "bin"])
        default: preconditionFailure("Missing iOS ROM layout for \(core.platform)")
        }
        return .init(id: core.platform.rawValue, folder: folder, name: core.platform.title,
                     extensions: extensions, module: core.moduleName, source: core.sourceURL,
                     runtimeNote: [
                        .threeDS: "软件渲染与解释执行，速度取决于设备和游戏。",
                        .psp: "软件渲染与解释执行，系统字体与资源已随应用内置。",
                        .ps1: "软件渲染与解释执行，标准 BIOS 已随应用内置。",
                        .wii: "使用缓存解释器和软件渲染，性能取决于设备和游戏。",
                        .ps2: "使用软件渲染与解释执行，BIOS 已随应用内置。",
                        .wiiu: "Cemu 原生 Metal 渲染（附带 MoltenVK）。无 JIT 时自动使用解释执行。"
                     ][core.platform],
                     runtime: [.wiiu: "cemu"][core.platform])
    }

    static func summary(for platform: GamePlatform) -> String? {
        guard let descriptor = descriptor(for: platform) else {
            switch platform {
            case .ps3, .psv:
                return "仅支持 macOS 端（iOS 端已移除需 JIT 的核心）"
            default: return nil
            }
        }
        if [.threeDS, .psp, .ps1].contains(platform) {
            return "iOS 核心：\(descriptor.displayName) · 软件渲染 / 解释执行，速度取决于设备和游戏"
        }
        return descriptor.requiresJIT
            ? "iOS 核心：\(descriptor.displayName) · 建议侧载并启用 JIT"
            : "iOS 核心：\(descriptor.displayName)"
    }
}
