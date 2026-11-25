import Foundation

/// Descriptor for a macOS arm64 Libretro core executed inside `GameCenterCoreHelper`.
struct MacCoreDescriptor: Identifiable, Hashable, Sendable {
    let platform: GamePlatform
    let displayName: String
    let moduleName: String
    let supportsPointer: Bool
    let supportsMouse: Bool
    let isDualScreen: Bool
    let defaultCrispPixels: Bool
    let requiresHardwareRender: Bool
    let defaultOptions: [String: String]
    let sourceURL: URL

    var id: GamePlatform { platform }
}

enum MacCoreCatalog {
    static let autoPauseWhenInactiveKey = "embeddedPlayerAutoPause"
    static let externalFullscreenKey = "externalEmulatorDirectFullscreen"

    static var autoPauseWhenInactive: Bool {
        get {
            if UserDefaults.standard.object(forKey: autoPauseWhenInactiveKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: autoPauseWhenInactiveKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: autoPauseWhenInactiveKey)
        }
    }

    static var launchExternalFullscreen: Bool {
        get {
            if UserDefaults.standard.object(forKey: externalFullscreenKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: externalFullscreenKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: externalFullscreenKey)
        }
    }

    static let descriptors: [MacCoreDescriptor] = [
        // Phase 1: Handhelds & PS1
        .init(
            platform: .gb,
            displayName: "mGBA",
            moduleName: "mgba_libretro.dylib",
            supportsPointer: false,
            supportsMouse: false,
            isDualScreen: false,
            defaultCrispPixels: true,
            requiresHardwareRender: false,
            defaultOptions: [
                "mgba_gb_model": "Autodetect",
                "mgba_use_bios": "ON"
            ],
            sourceURL: URL(string: "https://github.com/mgba-emu/mgba")!
        ),
        .init(
            platform: .gbc,
            displayName: "mGBA",
            moduleName: "mgba_libretro.dylib",
            supportsPointer: false,
            supportsMouse: false,
            isDualScreen: false,
            defaultCrispPixels: true,
            requiresHardwareRender: false,
            defaultOptions: [
                "mgba_gb_model": "Autodetect",
                "mgba_use_bios": "ON"
            ],
            sourceURL: URL(string: "https://github.com/mgba-emu/mgba")!
        ),
        .init(
            platform: .gba,
            displayName: "mGBA",
            moduleName: "mgba_libretro.dylib",
            supportsPointer: false,
            supportsMouse: false,
            isDualScreen: false,
            defaultCrispPixels: true,
            requiresHardwareRender: false,
            defaultOptions: [
                "mgba_use_bios": "ON"
            ],
            sourceURL: URL(string: "https://github.com/mgba-emu/mgba")!
        ),
        .init(
            platform: .nds,
            displayName: "DeSmuME",
            moduleName: "desmume_libretro.dylib",
            supportsPointer: true,
            supportsMouse: false,
            isDualScreen: true,
            defaultCrispPixels: true,
            requiresHardwareRender: false,
            defaultOptions: [
                "desmume_pointer_type": "touch",
                "desmume_screens_layout": "top/bottom",
                "desmume_pointer_mouse": "enabled"
            ],
            sourceURL: URL(string: "https://github.com/libretro/desmume")!
        ),
        .init(
            platform: .ps1,
            displayName: "SwanStation",
            moduleName: "swanstation_libretro.dylib",
            supportsPointer: false,
            supportsMouse: true,
            isDualScreen: false,
            defaultCrispPixels: false,
            requiresHardwareRender: false,
            defaultOptions: [
                "swanstation_GPU_Renderer": "Vulkan",
                "swanstation_GPU_ResolutionScale": "2",
                "swanstation_CPU_ExecutionMode": "Recompiler",
                "swanstation_MemoryCards_Card1Type": "Shared",
                "swanstation_Controller1_Type": "AnalogController"
            ],
            sourceURL: URL(string: "https://github.com/libretro/swanstation")!
        ),
        // Phase 2: 3D Hardware-Rendered Consoles (Vulkan via MoltenVK / OpenGL Core 4.1)
        .init(
            platform: .psp,
            displayName: "PPSSPP",
            moduleName: "ppsspp_libretro.dylib",
            supportsPointer: false,
            supportsMouse: false,
            isDualScreen: false,
            defaultCrispPixels: false,
            requiresHardwareRender: true,
            defaultOptions: [
                "ppsspp_backend": "vulkan",
                "ppsspp_cpu_core": "JIT",
                "ppsspp_software_rendering": "disabled",
                "ppsspp_internal_resolution": "1440x816"
            ],
            sourceURL: URL(string: "https://github.com/hrydgard/ppsspp")!
        ),
        .init(
            platform: .threeDS,
            displayName: "Azahar",
            moduleName: "azahar_libretro.dylib",
            supportsPointer: true,
            supportsMouse: false,
            isDualScreen: true,
            defaultCrispPixels: false,
            requiresHardwareRender: true,
            defaultOptions: [
                "citra_graphics_api": "Vulkan",
                "citra_use_cpu_jit": "enabled",
                "citra_resolution_factor": "2",
                "citra_layout_option": "default",
                "citra_enable_mouse_touchscreen": "enabled"
            ],
            sourceURL: URL(string: "https://github.com/azahar-emu/azahar")!
        ),
        .init(
            platform: .wii,
            displayName: "Dolphin",
            moduleName: "dolphin_libretro.dylib",
            supportsPointer: true,
            supportsMouse: true,
            isDualScreen: false,
            defaultCrispPixels: false,
            requiresHardwareRender: true,
            defaultOptions: [
                "dolphin_renderer": "Hardware",
                "dolphin_cpu_core": "0",
                "dolphin_widescreen": "enabled"
            ],
            sourceURL: URL(string: "https://github.com/libretro/dolphin")!
        ),
        .init(
            platform: .ps2,
            displayName: "PCSX2 / PCEE2",
            moduleName: "pcee2_libretro.dylib",
            supportsPointer: false,
            supportsMouse: false,
            isDualScreen: false,
            defaultCrispPixels: false,
            requiresHardwareRender: true,
            defaultOptions: [
                "pcsx2_renderer": "vulkan",
                "pcsx2_cpu_recompiler": "enabled",
                "pcsx2_widescreen_patches": "enabled"
            ],
            sourceURL: URL(string: "https://github.com/WizzardSK/pcee2-libretro")!
        )
    ]

    static func descriptor(for platform: GamePlatform) -> MacCoreDescriptor? {
        descriptors.first { $0.platform == platform }
    }

    static func helperExecutableURL() -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/GameCenterCoreHelper", isDirectory: false)
        ]
        if let executable = Bundle.main.executableURL {
            candidates.append(executable.deletingLastPathComponent().appendingPathComponent("GameCenterCoreHelper"))
        }
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
        candidates.append(cwd.appendingPathComponent(".build/debug/GameCenterCoreHelper"))
        candidates.append(cwd.appendingPathComponent(".build/release/GameCenterCoreHelper"))
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
    }

    static func coreSearchDirectories() -> [URL] {
        let fm = FileManager.default
        var searchDirs: [URL] = []
        if let envDir = ProcessInfo.processInfo.environment["GAME_CENTER_MAC_CORE_DIR"], !envDir.isEmpty {
            searchDirs.append(URL(fileURLWithPath: envDir, isDirectory: true))
        }
        if let resourceURL = Bundle.main.resourceURL {
            searchDirs.append(resourceURL.appendingPathComponent("Cores", isDirectory: true))
        }
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
        searchDirs.append(cwd.appendingPathComponent("build/mac-cores", isDirectory: true))
        if let executable = Bundle.main.executableURL {
            var dir = executable.deletingLastPathComponent()
            for _ in 0..<5 {
                let probe = dir.appendingPathComponent("build/mac-cores", isDirectory: true)
                if fm.fileExists(atPath: probe.path) {
                    searchDirs.append(probe)
                    break
                }
                dir = dir.deletingLastPathComponent()
            }
        }
        return searchDirs
    }

    static func coreURL(for platform: GamePlatform) -> URL? {
        guard let descriptor = descriptor(for: platform) else { return nil }
        let fm = FileManager.default
        for dir in coreSearchDirectories() {
            let candidate = dir.appendingPathComponent(descriptor.moduleName)
            if fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    static func moltenVKURL() -> URL? {
        let fm = FileManager.default
        for dir in coreSearchDirectories() {
            let candidate = dir.appendingPathComponent("libMoltenVK.dylib")
            if fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        // Fallback to kept standalone emulators' MoltenVK framework
        if let emulators = Bundle.main.resourceURL?.appendingPathComponent("Emulators", isDirectory: true) {
            for app in ["Cemu.app", "Vita3K.app"] {
                let candidate = emulators.appendingPathComponent("\(app)/Contents/Frameworks/libMoltenVK.dylib")
                if fm.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        let cwdFallback = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("build/emulators/Emulators/Cemu.app/Contents/Frameworks/libMoltenVK.dylib")
        return fm.fileExists(atPath: cwdFallback.path) ? cwdFallback : nil
    }

    static func bundledSystemAssetsDirectory(for folderName: String) -> URL? {
        let fm = FileManager.default
        for dir in coreSearchDirectories() {
            let candidate = dir.appendingPathComponent("System/\(folderName)", isDirectory: true)
            if fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    static func canRunEmbedded(platform: GamePlatform) -> Bool {
        guard let descriptor = descriptor(for: platform),
              helperExecutableURL() != nil,
              coreURL(for: platform) != nil else {
            return false
        }
        if descriptor.requiresHardwareRender && moltenVKURL() == nil {
            return false
        }
        return true
    }
}
