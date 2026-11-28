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
    static let supportedPlatforms: Set<GamePlatform> = [.gb, .gbc, .gba, .nds, .threeDS, .psp, .psv, .ps1, .wiiu, .wii, .ps2]

    static let descriptors: [IOSCoreDescriptor] = [
        .init(platform: .gb, displayName: "Gambatte", moduleName: "gambatte_libretro_ios.dylib", requiresJIT: false, sourceURL: URL(string: "https://github.com/libretro/gambatte-libretro")!),
        .init(platform: .gbc, displayName: "Gambatte", moduleName: "gambatte_libretro_ios.dylib", requiresJIT: false, sourceURL: URL(string: "https://github.com/libretro/gambatte-libretro")!),
        .init(platform: .gba, displayName: "mGBA", moduleName: "mgba_libretro.dylib", requiresJIT: false, sourceURL: URL(string: "https://github.com/libretro/mgba")!),
        .init(platform: .nds, displayName: "DeSmuME", moduleName: "desmume_libretro_ios.dylib", requiresJIT: false, sourceURL: URL(string: "https://github.com/libretro/desmume")!),
        .init(platform: .threeDS, displayName: "Citra / Manic EMU", moduleName: "Citra", requiresJIT: false, sourceURL: URL(string: "https://github.com/Manic-EMU/ManicEMU")!),
        .init(platform: .psp, displayName: "PPSSPP (Manic EMU)", moduleName: "ppsspp_libretro.dylib", requiresJIT: false, sourceURL: URL(string: "https://github.com/Manic-EMU/ManicEMU")!),
        .init(platform: .psv, displayName: "Vita3K / Veeb", moduleName: "Vita3KCore", requiresJIT: true, sourceURL: URL(string: "https://github.com/veebteam/Veeb")!),
        .init(platform: .wiiu, displayName: "Cemu / MuffinEMU", moduleName: "Cemu", requiresJIT: false, sourceURL: URL(string: "https://github.com/MuffinEMU/Muffin-EMU/tree/v11.8")!),
        .init(platform: .wii, displayName: "Dolphin", moduleName: "dolphin_libretro.dylib", requiresJIT: false, sourceURL: URL(string: "https://github.com/libretro/dolphin")!),
        .init(platform: .ps2, displayName: "PCSX2 / PCEE2", moduleName: "pcee2_libretro.dylib", requiresJIT: false, sourceURL: URL(string: "https://github.com/WizzardSK/pcee2-libretro")!),
        .init(platform: .famicom, displayName: "FCEUmm", moduleName: "fceumm_libretro_ios.dylib", requiresJIT: false, sourceURL: URL(string: "https://github.com/libretro/libretro-fceumm")!),
        .init(platform: .superFamicom, displayName: "Snes9x", moduleName: "snes9x_libretro_ios.dylib", requiresJIT: false, sourceURL: URL(string: "https://github.com/libretro/snes9x")!),
        .init(platform: .n64, displayName: "Mupen64Plus-Next", moduleName: "mupen64plus_next_libretro_ios.dylib", requiresJIT: false, sourceURL: URL(string: "https://github.com/libretro/mupen64plus-libretro-nx")!),
        .init(platform: .megaDrive, displayName: "Genesis Plus GX", moduleName: "genesis_plus_gx_libretro_ios.dylib", requiresJIT: false, sourceURL: URL(string: "https://github.com/libretro/Genesis-Plus-GX")!),
        .init(platform: .ps1, displayName: "PCSX-ReARMed", moduleName: "pcsx_rearmed_libretro_ios.dylib", requiresJIT: false, sourceURL: URL(string: "https://github.com/libretro/pcsx_rearmed")!)
    ].filter { supportedPlatforms.contains($0.platform) }

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
        case .psv: (folder, extensions) = ("psv", ["vpk", "zip", "pkg"])
        case .famicom: (folder, extensions) = ("fc", ["nes", "unf", "unif", "fds"])
        case .superFamicom: (folder, extensions) = ("sfc", ["sfc", "smc", "fig", "swc"])
        case .n64: (folder, extensions) = ("n64", ["n64", "v64", "z64", "ndd"])
        case .megaDrive: (folder, extensions) = ("md", ["md", "gen", "smd", "bin"])
        case .wii: (folder, extensions) = ("wii", ["iso", "wbfs", "rvz", "gcz", "ciso", "wad", "dol", "elf"])
        case .ps2: (folder, extensions) = ("ps2", ["iso", "chd", "cso", "bin", "gz", "elf"])
        case .wiiu: (folder, extensions) = ("wiiu", ["wua", "wux", "wud", "rpx", "wuhb"])
        case .ps1: (folder, extensions) = ("ps1", ["cue", "ccd", "img", "chd", "m3u", "pbp", "iso", "bin"])
        default: preconditionFailure("Missing iOS ROM layout for \(core.platform)")
        }
        return .init(id: core.platform.rawValue, folder: folder, name: core.platform.title,
                     extensions: extensions, module: core.moduleName, source: core.sourceURL,
                     runtimeNote: [
                        .threeDS: "Manic EMU 原生 3DS 核心（Metal/Vulkan 硬件渲染 + 低时钟无 JIT 优化），支持暂停菜单切换流畅/均衡/画质。",
                        .psp: "PPSSPP 使用软件渲染，无 JIT 时使用 IR 解释器。",
                        .psv: "Vita3K / Veeb 原生 Vulkan(MoltenVK) 核心 + Zeta 风格流畅预设（异步管线、禁用表面同步、着色器缓存），支持 VPK/ZIP/PKG/文件夹与前/后触控；需配合 JIT（如 StikDebug）运行。",
                        .ps1: "软件渲染与解释执行，标准 BIOS 已随应用内置。",
                        .wii: "Vulkan 硬件渲染与缓存解释器，性能取决于设备和游戏。",
                        .ps2: "Metal 硬件渲染 + Zeta 风格无 JIT 降频/跳帧/MTVU 加速，支持暂停菜单切换流畅/均衡/画质。",
                        .wiiu: "Cemu / MuffinEMU 原生 Metal 渲染（支持 MoltenVK 切换），内置多核/异步着色器/跳过隐藏屏/自动时基流畅优化，无 JIT 自动回退解释器，支持暂停菜单实时调优与 GamePad 副屏切换。"
                     ][core.platform],
                     runtime: [.wiiu: "cemu", .threeDS: "citra", .psv: "vita3k"][core.platform])
    }
}
