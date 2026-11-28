import AVFoundation
import Darwin
import GameController
import QuartzCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers
#if canImport(GameCenterSaveSupport)
import GameCenterSaveSupport
#endif

// MARK: - Dynamic C-ABI Loader for Vita3KCore.framework (veebteam/Veeb)

private final class Vita3KBridge: @unchecked Sendable {
    typealias IntVoid = @convention(c) () -> Int32
    typealias UInt64Void = @convention(c) () -> UInt64
    typealias VoidVoid = @convention(c) () -> Void
    typealias VoidInt = @convention(c) (Int32) -> Void
    typealias VoidPtr = @convention(c) (UnsafeMutableRawPointer) -> Void
    typealias VoidIntInt = @convention(c) (Int32, Int32) -> Void
    typealias IntIntInt = @convention(c) (Int32, Int32) -> Int32
    typealias SessionInit = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>) -> Int32
    typealias FillBuffer = @convention(c) (UnsafeMutablePointer<CChar>, Int) -> Int32
    typealias SessionInstall = @convention(c) (UnsafePointer<CChar>, Int32, UnsafeMutablePointer<CChar>, Int) -> Int32
    typealias SessionLaunch = @convention(c) (UnsafePointer<CChar>, Int32, Int32) -> Int32
    typealias GameConfigSet = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>, UnsafePointer<CChar>) -> Int32
    typealias ClearShaders = @convention(c) (UnsafePointer<CChar>) -> Int32
    typealias TouchEvent = @convention(c) (Int32, Int32, Int32, Int32) -> Void
    typealias VirtualButtons = @convention(c) (UInt32, UInt32) -> Void
    typealias VirtualAxes = @convention(c) (Float, Float, Float, Float) -> Void

    private static var instance: Vita3KBridge?
    private static var sessionInitialized = false

    let csDebugged: IntVoid
    let jitPrepare: IntVoid
    let jitValidateAlive: IntVoid
    let setLayer: VoidPtr
    let setSize: VoidIntInt
    let sessionInit: SessionInit
    let sessionStagingPath: FillBuffer
    let sessionInstall: SessionInstall
    let sessionGetApps: FillBuffer
    let sessionScanApps: IntVoid
    let sessionFirmwareMask: IntVoid
    let gameConfigSet: GameConfigSet
    let clearShaders: ClearShaders
    let sessionLaunch: SessionLaunch
    let sessionStop: IntVoid
    let sessionIsActive: IntVoid
    let sessionPhase: IntVoid
    let sessionFrameCount: UInt64Void
    let sessionLaunchFailed: IntVoid
    let sessionReport: FillBuffer
    let sessionSetPause: IntIntInt
    let sessionSetBackground: VoidInt
    let inputTouchEvent: TouchEvent
    let inputSetRearTouch: VoidInt
    let inputClear: VoidVoid
    let inputVirtualEnabled: VoidInt
    let inputVirtualButtons: VirtualButtons
    let inputVirtualAxes: VirtualAxes

    static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: frameworkBinaryPath)
    }

    private static var frameworkBinaryPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Frameworks/Vita3KCore.framework/Vita3KCore").path
    }

    static var staticAssetsPath: String {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Vita3KAssets", isDirectory: true)
        if FileManager.default.fileExists(atPath: bundled.appendingPathComponent("shaders-builtin").path) {
            return bundled.path
        }
        return Bundle.main.bundleURL.path
    }

    static func shared() throws -> Vita3KBridge {
        if let instance { return instance }
        let loaded = try Vita3KBridge()
        instance = loaded
        return loaded
    }

    private init() throws {
        // Vita3K imports Vulkan entry points through the process-wide symbol table.
        let driver = Bundle.main.bundleURL.appendingPathComponent("Frameworks/MoltenVK.framework/MoltenVK")
        guard dlopen(driver.path, RTLD_NOW | RTLD_GLOBAL) != nil else {
            throw Failure("无法加载 Vita3K 使用的 MoltenVK。")
        }
        let path = Self.frameworkBinaryPath
        guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            let reason = dlerror().map { String(cString: $0) } ?? ""
            throw Failure("无法加载 PS Vita 引擎（Vita3KCore.framework）。请通过 Mac 端重新生成并安装最新版 iOS IPA。" + (reason.isEmpty ? "" : "\n" + reason))
        }
        func sym<T>(_ name: String, as type: T.Type) throws -> T {
            guard let ptr = dlsym(handle, name) else {
                throw Failure("PS Vita 核心接口不完整：" + name)
            }
            return unsafeBitCast(ptr, to: type)
        }
        do {
            csDebugged = try sym("vita3k_ios_cs_debugged", as: IntVoid.self)
            jitPrepare = try sym("vita3k_ios_jit_prepare", as: IntVoid.self)
            jitValidateAlive = try sym("vita3k_ios_jit_validate_alive", as: IntVoid.self)
            setLayer = try sym("vita3k_ios_frame_host_set_layer", as: VoidPtr.self)
            setSize = try sym("vita3k_ios_frame_host_set_size", as: VoidIntInt.self)
            sessionInit = try sym("vita3k_ios_session_init", as: SessionInit.self)
            sessionStagingPath = try sym("vita3k_ios_session_staging_path", as: FillBuffer.self)
            sessionInstall = try sym("vita3k_ios_session_install", as: SessionInstall.self)
            sessionGetApps = try sym("vita3k_ios_session_get_apps", as: FillBuffer.self)
            sessionScanApps = try sym("vita3k_ios_session_scan_apps", as: IntVoid.self)
            sessionFirmwareMask = try sym("vita3k_ios_session_firmware_mask", as: IntVoid.self)
            gameConfigSet = try sym("vita3k_ios_game_config_set", as: GameConfigSet.self)
            clearShaders = try sym("vita3k_ios_clear_shaders", as: ClearShaders.self)
            sessionLaunch = try sym("vita3k_ios_session_launch", as: SessionLaunch.self)
            sessionStop = try sym("vita3k_ios_session_stop", as: IntVoid.self)
            sessionIsActive = try sym("vita3k_ios_session_is_active", as: IntVoid.self)
            sessionPhase = try sym("vita3k_ios_session_phase", as: IntVoid.self)
            sessionFrameCount = try sym("vita3k_ios_session_frame_count", as: UInt64Void.self)
            sessionLaunchFailed = try sym("vita3k_ios_session_launch_failed", as: IntVoid.self)
            sessionReport = try sym("vita3k_ios_session_report", as: FillBuffer.self)
            sessionSetPause = try sym("vita3k_ios_session_set_pause", as: IntIntInt.self)
            sessionSetBackground = try sym("vita3k_ios_session_set_background", as: VoidInt.self)
            inputTouchEvent = try sym("vita3k_ios_input_touch_event", as: TouchEvent.self)
            inputSetRearTouch = try sym("vita3k_ios_input_set_rear_touch", as: VoidInt.self)
            inputClear = try sym("vita3k_ios_input_clear", as: VoidVoid.self)
            inputVirtualEnabled = try sym("vita3k_ios_input_virtual_enabled", as: VoidInt.self)
            inputVirtualButtons = try sym("vita3k_ios_input_virtual_buttons", as: VirtualButtons.self)
            inputVirtualAxes = try sym("vita3k_ios_input_virtual_axes", as: VirtualAxes.self)
        } catch {
            dlclose(handle)
            throw error
        }
    }

    @MainActor
    func ensureSessionInitialized(basePath: String) throws {
        guard !Self.sessionInitialized else { return }
        let rc = basePath.withCString { base in
            Self.staticAssetsPath.withCString { assets in
                sessionInit(base, assets)
            }
        }
        guard rc == 0 else {
            throw Failure("PS Vita 运行环境初始化失败（错误码 \(rc)）。")
        }
        Self.sessionInitialized = true
    }

    func stagingPath() -> String {
        readBuffer(1024, sessionStagingPath)
    }

    func installedAppIDs() -> [String] {
        let raw = readBuffer(16384, sessionGetApps)
        return raw.split(separator: "\n").compactMap { line in
            let id = line.split(separator: "|", maxSplits: 1).first.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return id.isEmpty ? nil : id
        }
    }

    func install(stagedPath: String, replaceExisting: Bool) -> (Int32, String) {
        var buf = [CChar](repeating: 0, count: 8192)
        let rc = stagedPath.withCString { path in
            buf.withUnsafeMutableBufferPointer { ptr in
                sessionInstall(path, replaceExisting ? 1 : 0, ptr.baseAddress!, ptr.count)
            }
        }
        return (rc, Self.cString(buf))
    }

    func report() -> String {
        readBuffer(8192, sessionReport)
    }

    func setConfig(titleID: String, key: String, value: String) {
        _ = titleID.withCString { id in
            key.withCString { k in
                value.withCString { v in
                    gameConfigSet(id, k, v)
                }
            }
        }
    }

    private func readBuffer(_ capacity: Int, _ fn: FillBuffer) -> String {
        var buf = [CChar](repeating: 0, count: capacity)
        _ = buf.withUnsafeMutableBufferPointer { ptr in
            fn(ptr.baseAddress!, ptr.count)
        }
        return Self.cString(buf)
    }

    private static func cString(_ buffer: [CChar]) -> String {
        buffer.withUnsafeBufferPointer { ptr in
            let bytes = ptr.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}

// MARK: - SCE_CTRL Button Masks

private enum VitaButtonBit {
    static let select: UInt32   = 0x0000_0001
    static let start: UInt32    = 0x0000_0008
    static let up: UInt32       = 0x0000_0010
    static let right: UInt32    = 0x0000_0020
    static let down: UInt32     = 0x0000_0040
    static let left: UInt32     = 0x0000_0080
    static let l: UInt32        = 0x0000_0100
    static let r: UInt32        = 0x0000_0200
    static let triangle: UInt32 = 0x0000_1000
    static let circle: UInt32   = 0x0000_2000
    static let cross: UInt32    = 0x0000_4000
    static let square: UInt32   = 0x0000_8000

    static let extL1: UInt32    = 0x0000_0400
    static let extR1: UInt32    = 0x0000_0800
    static let extL2: UInt32    = 0x0000_0100
    static let extR2: UInt32    = 0x0000_0200
}

// MARK: - CAMetalLayer Host Surface with Multi-Touch Forwarding

final class VitaMetalSurfaceView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    var onLayoutDrawable: ((Int32, Int32) -> Void)?
    var onTouchEvent: ((Int32, Int32, Int32, Int32) -> Void)?

    private var drawableWidth: Int32 = 0
    private var drawableHeight: Int32 = 0
    private var fingerIDs: [ObjectIdentifier: Int32] = [:]
    private var nextFingerID: Int32 = 1

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isMultipleTouchEnabled = true
        metalLayer.isOpaque = true
        metalLayer.framebufferOnly = false
        metalLayer.presentsWithTransaction = false
        metalLayer.backgroundColor = UIColor.black.cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    var currentDrawableSize: (Int32, Int32) { (drawableWidth, drawableHeight) }

    var layerPointer: UnsafeMutableRawPointer {
        Unmanaged.passUnretained(metalLayer).toOpaque()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyDrawableSize()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        applyDrawableSize()
    }

    func applyDrawableSize() {
        let scale = max(1.0, window?.screen.nativeScale ?? traitCollection.displayScale)
        if contentScaleFactor != scale { contentScaleFactor = scale }
        guard bounds.width > 1, bounds.height > 1 else { return }
        let w = max(1, Int32((bounds.width * scale).rounded()))
        let h = max(1, Int32((bounds.height * scale).rounded()))
        if w != drawableWidth || h != drawableHeight {
            metalLayer.drawableSize = CGSize(width: Int(w), height: Int(h))
            drawableWidth = w
            drawableHeight = h
            onLayoutDrawable?(w, h)
        }
    }

    private func fingerID(for touch: UITouch) -> Int32 {
        let key = ObjectIdentifier(touch)
        if let existing = fingerIDs[key] { return existing }
        let id = nextFingerID
        nextFingerID += 1
        fingerIDs[key] = id
        return id
    }

    private func touchPixels(_ touch: UITouch) -> (Int32, Int32) {
        let p = touch.location(in: self)
        let scale = max(1.0, contentScaleFactor)
        return (Int32((p.x * scale).rounded()), Int32((p.y * scale).rounded()))
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let (x, y) = touchPixels(touch)
            onTouchEvent?(0, fingerID(for: touch), x, y)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let (x, y) = touchPixels(touch)
            onTouchEvent?(1, fingerID(for: touch), x, y)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let (x, y) = touchPixels(touch)
            onTouchEvent?(2, fingerID(for: touch), x, y)
            fingerIDs[ObjectIdentifier(touch)] = nil
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let (x, y) = touchPixels(touch)
            onTouchEvent?(3, fingerID(for: touch), x, y)
            fingerIDs[ObjectIdentifier(touch)] = nil
        }
    }
}

private struct VitaSurfaceView: UIViewRepresentable {
    let view: VitaMetalSurfaceView
    func makeUIView(context: Context) -> VitaMetalSurfaceView { view }
    func updateUIView(_ uiView: VitaMetalSurfaceView, context: Context) {}
}

// MARK: - PS Vita Session Controller

@MainActor
private final class VitaSession: NSObject, ObservableObject {
    @Published var error: String?
    @Published var jitRequiredError = false
    @Published var statusText = "正在初始化 PS Vita 引擎…"
    @Published var starting = true
    @Published var stopping = false
    @Published var rearTouch = false
    @Published var jitReady = false
    @Published var currentFPS = 0
    @Published var activeTitleID: String?
    @Published var firmwareInstalled = false

    let surfaceView = VitaMetalSurfaceView()
    private var bridge: Vita3KBridge?
    private var closing = false
    private var launched = false
    private var pollTimer: Timer?
    private var lastFrameCount: UInt64 = 0
    private var lastFrameSample = CFAbsoluteTimeGetCurrent()

    private var buttonsMask: UInt32 = 0
    private var buttonsExtMask: UInt32 = 0
    private var leftStick: (Float, Float) = (0, 0)
    private var rightStick: (Float, Float) = (0, 0)

    private nonisolated static let titleMapDefaultsKey = "phone.vita.romTitleMap"

    private static func baseDirectory(library: PhoneLibrary) -> URL {
        library.documents.appendingPathComponent("Vita3K", isDirectory: true)
    }

    /// Bridges Vita3K's `ux0/user/00/savedata` & `trophy` into `Documents/GameLibrary/save/psv`
    /// for seamless macOS/iOS iCloud Save Sync, and seeds bundled firmware if available.
    private nonisolated static func prepareSandbox(library: PhoneLibrary, platform: PhoneLibrary.Format.Platform) throws -> URL {
        let fm = FileManager.default
        let base = library.documents.appendingPathComponent("Vita3K", isDirectory: true)
        let vitaFS = base.appendingPathComponent("vita", isDirectory: true)
        let account = vitaFS.appendingPathComponent("ux0/user/00", isDirectory: true)
        let saveRoot = library.root.appendingPathComponent("save", isDirectory: true)
        let canonical = GameSaveLayout.folder(root: library.root, platform: "psv")

        try fm.createDirectory(at: account, withIntermediateDirectories: true)
        try fm.createDirectory(at: canonical, withIntermediateDirectories: true)

        for sub in ["savedata", "trophy"] {
            let legacy = account.appendingPathComponent(sub, isDirectory: true)
            let target = canonical.appendingPathComponent(sub, isDirectory: true)
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            try GameSaveLayout.migrate(legacy, to: target, saveRoot: saveRoot)
            if (try? fm.destinationOfSymbolicLink(atPath: legacy.path)) == nil {
                try GameSaveLayout.createAlias(at: legacy, to: target)
            }
        }

        // Seed bundled PSV firmware partitions (vs0/pd0/os0/sa0) if present in CoreAssets/PSV.
        if let assets = PhoneLibrary.coreAssets(folder: platform.folder) {
            for partition in ["vs0", "pd0", "os0", "sa0"] {
                let src = assets.appendingPathComponent(partition, isDirectory: true)
                if fm.fileExists(atPath: src.path) {
                    let dst = vitaFS.appendingPathComponent(partition, isDirectory: true)
                    try? fm.createDirectory(at: dst, withIntermediateDirectories: true)
                    PhoneLibrary.mergeTree(from: src, into: dst)
                }
            }
        }
        return base
    }

    func applyZetaPreset(titleID: String, performanceMode: Int, resolutionScale: Double) {
        guard let bridge, !titleID.isEmpty else { return }
        // Zeta-inspired speed tuning for Vita3K:
        // 0 = 极致流畅 (async pipeline, disable surface sync, FPS hack, shader/texture cache, 0.75x~1x)
        // 1 = 均衡 (async pipeline, disable surface sync, standard accuracy, 1x)
        // 2 = 高画质 (high accuracy, surface sync on, 1.5x~2x, 4x AF)
        let res = resolutionScale > 0 ? resolutionScale : (performanceMode == 0 ? 1.0 : (performanceMode == 1 ? 1.0 : 1.5))
        let settings: [(String, String)] = [
            ("cpu_opt", "1"),
            ("high_accuracy", performanceMode == 2 ? "1" : "0"),
            ("disable_surface_sync", performanceMode == 2 ? "0" : "1"),
            ("async_pipeline_compilation", "1"),
            ("shader_cache", "1"),
            ("texture_cache", "1"),
            ("fps_hack", performanceMode == 0 ? "1" : "0"),
            ("resolution_multiplier", String(format: "%.2g", res)),
            ("anisotropic_filtering", performanceMode == 0 ? "1" : (performanceMode == 1 ? "2" : "4")),
            ("log_level", "6")
        ]
        for (key, value) in settings {
            bridge.setConfig(titleID: titleID, key: key, value: value)
        }
    }

    func start(rom: PhoneLibrary.ROM, library: PhoneLibrary, performanceMode: Int, resolutionScale: Double, virtualPadVisible: Bool) {
        guard !launched, !closing else { return }
        error = nil
        jitRequiredError = false
        starting = true
        statusText = "正在准备 PS Vita 运行环境…"

        // Vita3K reserves a 4 GiB contiguous guest address window — release S2Arm's window first.
        if gc_s2arm_release_va_window() != 0 {
            starting = false
            error = "当前进程已运行过 Switch 游戏并占用虚拟地址空间，请彻底关闭并重新打开 Game Center 后再启动 PS Vita 游戏。"
            return
        }

        do {
            let bridge = try Vita3KBridge.shared()
            self.bridge = bridge
            let base = try Self.prepareSandbox(library: library, platform: rom.platform)
            // Must be called on the main thread (initializes SDL audio subsystem).
            try bridge.ensureSessionInitialized(basePath: base.path)
            self.firmwareInstalled = (bridge.sessionFirmwareMask() & 0b111) != 0

            try AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)

            surfaceView.onLayoutDrawable = { [weak bridge] w, h in
                bridge?.setSize(w, h)
            }
            surfaceView.onTouchEvent = { [weak bridge] event, finger, x, y in
                bridge?.inputTouchEvent(event, finger, x, y)
            }
            bridge.inputVirtualEnabled(virtualPadVisible ? 1 : 0)

            Task { [weak self] in
                guard let self else { return }
                await self.prepareJITInstallAndLaunch(
                    bridge: bridge,
                    rom: rom,
                    library: library,
                    performanceMode: performanceMode,
                    resolutionScale: resolutionScale
                )
            }
        } catch {
            self.error = error.localizedDescription
            self.starting = false
        }
    }

    private func prepareJITInstallAndLaunch(
        bridge: Vita3KBridge,
        rom: PhoneLibrary.ROM,
        library: PhoneLibrary,
        performanceMode: Int,
        resolutionScale: Double
    ) async {
        // 1. Check / prepare JIT arena (Vita3K dynarmic requires JIT on iOS device).
        statusText = "正在检测 JIT 加速环境…"
        let jitOK: Bool = await Task.detached(priority: .userInitiated) {
            #if targetEnvironment(simulator)
            return bridge.jitPrepare() == 0
            #else
            if bridge.jitValidateAlive() == 0 { return true }
            for _ in 0..<4 {
                if bridge.csDebugged() == 1 { break }
                try? await Task.sleep(for: .milliseconds(350))
            }
            guard bridge.csDebugged() == 1 else { return false }
            return bridge.jitPrepare() == 0
            #endif
        }.value

        guard !closing else { return }
        jitReady = jitOK
        if !jitOK {
            starting = false
            jitRequiredError = true
            error = "PS Vita 核心（Vita3K）需要启用 JIT 才能流畅运行。\n\n请通过 StikDebug / SideStore / TrollStore 为 Game Center 附加 JIT 后，点击下方「重试检测 JIT」直接启动游戏。"
            return
        }

        // 2. Ensure ROM is installed in Vita3K's ux0/app/<TITLE_ID>.
        statusText = "正在检查并安装 PS Vita 游戏数据…"
        let romURL = rom.url
        let romKey = rom.url.lastPathComponent
        let installResult: Result<String, Error> = await Task.detached(priority: .userInitiated) {
            Self.resolveOrInstallTitleID(bridge: bridge, romURL: romURL, romKey: romKey)
        }.value

        guard !closing else { return }
        let titleID: String
        switch installResult {
        case .success(let id):
            titleID = id
        case .failure(let err):
            starting = false
            error = err.localizedDescription
            return
        }

        activeTitleID = titleID
        applyZetaPreset(titleID: titleID, performanceMode: performanceMode, resolutionScale: resolutionScale)

        // 3. Wait for CAMetalLayer to have valid pixel dimensions, then hand layer & launch.
        statusText = "正在启动 \(titleID)（Vulkan / MoltenVK）…"
        for _ in 0..<25 {
            surfaceView.applyDrawableSize()
            let (w, h) = surfaceView.currentDrawableSize
            if w > 1 && h > 1 { break }
            try? await Task.sleep(for: .milliseconds(40))
        }
        guard !closing else { return }
        let (w, h) = surfaceView.currentDrawableSize
        let width = max(Int32(960), w)
        let height = max(Int32(544), h)

        bridge.setLayer(surfaceView.layerPointer)
        bridge.setSize(width, height)
        launched = true

        let rc = titleID.withCString { id in
            bridge.sessionLaunch(id, width, height)
        }
        guard rc == 0 else {
            launched = false
            starting = false
            error = "无法启动 PS Vita 游戏（错误码 \(rc)）。\n" + bridge.report()
            return
        }

        startStatusPolling()
    }

    private nonisolated static func resolveOrInstallTitleID(
        bridge: Vita3KBridge,
        romURL: URL,
        romKey: String
    ) -> Result<String, Error> {
        _ = bridge.sessionScanApps()
        let beforeList = bridge.installedAppIDs()
        let beforeSet = Set(beforeList)

        // Direct Vita game folder with sce_sys/param.sfo
        let sfoURL = romURL.appendingPathComponent("sce_sys/param.sfo")
        if FileManager.default.fileExists(atPath: sfoURL.path),
           let id = MobileLibraryFormat.sfoString("TITLE_ID", at: sfoURL), !id.isEmpty,
           beforeSet.contains(id) {
            saveMappedTitleID(id, for: romKey)
            return .success(id)
        }

        // Previously mapped VPK / ZIP / PKG
        if let mapped = loadMappedTitleID(for: romKey), beforeSet.contains(mapped) {
            return .success(mapped)
        }

        // Check if filename itself contains an already-installed Title ID (e.g. PCSE00120)
        if let hint = extractTitleID(from: romKey), beforeSet.contains(hint) {
            saveMappedTitleID(hint, for: romKey)
            return .success(hint)
        }

        // Stage into Vita3K's imports/ staging directory and install via vita3k_ios_session_install.
        let stagingDir = URL(fileURLWithPath: bridge.stagingPath(), isDirectory: true)
        guard !stagingDir.path.isEmpty else {
            return .failure(Vita3KBridge.Failure("无法获取 PS Vita 安装缓存目录。"))
        }
        let fm = FileManager.default
        let staged = stagingDir.appendingPathComponent("gc-\(UUID().uuidString)-\(romURL.lastPathComponent)")
        do {
            try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
            if fm.fileExists(atPath: staged.path) { try fm.removeItem(at: staged) }
            try fm.copyItem(at: romURL, to: staged)
        } catch {
            return .failure(Vita3KBridge.Failure("准备 PS Vita 游戏安装包失败：\(error.localizedDescription)"))
        }
        defer { try? fm.removeItem(at: staged) }

        let (rc, report) = bridge.install(stagedPath: staged.path, replaceExisting: false)
        _ = bridge.sessionScanApps()
        let afterList = bridge.installedAppIDs()
        let afterSet = Set(afterList)

        guard rc == 0 else {
            let detail = report.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(Vita3KBridge.Failure("安装 PS Vita 游戏失败（错误码 \(rc)）：" + (detail.isEmpty ? "请确认文件为有效的 .vpk / .zip / .pkg 或解包游戏目录。" : detail)))
        }

        if let sfoID = MobileLibraryFormat.sfoString("TITLE_ID", at: sfoURL), afterSet.contains(sfoID) {
            saveMappedTitleID(sfoID, for: romKey)
            return .success(sfoID)
        }
        if let added = afterSet.subtracting(beforeSet).sorted().first {
            saveMappedTitleID(added, for: romKey)
            return .success(added)
        }
        if let fromReport = extractTitleID(from: report), afterSet.contains(fromReport) {
            saveMappedTitleID(fromReport, for: romKey)
            return .success(fromReport)
        }
        if let fromName = extractTitleID(from: romKey), afterSet.contains(fromName) {
            saveMappedTitleID(fromName, for: romKey)
            return .success(fromName)
        }
        if afterList.count == 1, let only = afterList.first {
            saveMappedTitleID(only, for: romKey)
            return .success(only)
        }
        return .failure(Vita3KBridge.Failure("游戏已安装但无法识别 Title ID，请确认文件包含有效的 sce_sys/param.sfo。"))
    }

    private nonisolated static func extractTitleID(from text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"\b([A-Z]{4}[0-9]{5})\b"#) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let r = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    private nonisolated static func loadMappedTitleID(for key: String) -> String? {
        let dict = UserDefaults.standard.dictionary(forKey: titleMapDefaultsKey) as? [String: String]
        return dict?[key]
    }

    private nonisolated static func saveMappedTitleID(_ id: String, for key: String) {
        var dict = (UserDefaults.standard.dictionary(forKey: titleMapDefaultsKey) as? [String: String]) ?? [:]
        dict[key] = id
        UserDefaults.standard.set(dict, forKey: titleMapDefaultsKey)
    }

    private func startStatusPolling() {
        pollTimer?.invalidate()
        lastFrameCount = bridge?.sessionFrameCount() ?? 0
        lastFrameSample = CFAbsoluteTimeGetCurrent()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollSessionStatus()
            }
        }
    }

    private func pollSessionStatus() {
        guard let bridge, !closing else { return }
        let phase = bridge.sessionPhase()
        if phase == 2 { // Running
            if starting { starting = false }
            let now = CFAbsoluteTimeGetCurrent()
            let count = bridge.sessionFrameCount()
            let dt = now - lastFrameSample
            if dt >= 0.8 {
                let delta = count >= lastFrameCount ? (count - lastFrameCount) : 0
                currentFPS = Int((Double(delta) / dt).rounded())
                lastFrameCount = count
                lastFrameSample = now
            }
        } else if phase == 4 || bridge.sessionLaunchFailed() == 1 {
            pollTimer?.invalidate()
            pollTimer = nil
            starting = false
            launched = false
            let detail = bridge.report().trimmingCharacters(in: .whitespacesAndNewlines)
            let fwHint = firmwareInstalled ? "" : "\n提示：尚未检测到 PS Vita 系统固件（PSVUPDAT.PUP），请在菜单中导入官方固件后重试。"
            error = "PS Vita 游戏启动失败。\n\(detail)\(fwHint)"
        }
    }

    func installFirmware(from url: URL) -> String {
        guard let bridge else { return "PS Vita 引擎尚未初始化。" }
        let stagingDir = URL(fileURLWithPath: bridge.stagingPath(), isDirectory: true)
        let staged = stagingDir.appendingPathComponent("fw-\(UUID().uuidString)-\(url.lastPathComponent)")
        do {
            try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: staged)
        } catch {
            return "复制固件失败：\(error.localizedDescription)"
        }
        defer { try? FileManager.default.removeItem(at: staged) }
        let (rc, report) = bridge.install(stagedPath: staged.path, replaceExisting: true)
        firmwareInstalled = (bridge.sessionFirmwareMask() & 0b111) != 0
        if rc == 0 {
            return "固件已安装成功！重新启动游戏即可生效。"
        }
        return "固件安装失败（错误码 \(rc)）：\(report)"
    }

    func clearShaderCache() {
        guard let bridge else { return }
        let target = activeTitleID ?? ""
        _ = target.withCString { bridge.clearShaders($0) }
    }

    func setVirtualPadEnabled(_ enabled: Bool) {
        bridge?.inputVirtualEnabled(enabled ? 1 : 0)
        if !enabled {
            buttonsMask = 0
            buttonsExtMask = 0
            leftStick = (0, 0)
            rightStick = (0, 0)
            bridge?.inputVirtualButtons(0, 0)
            bridge?.inputVirtualAxes(0, 0, 0, 0)
        }
    }

    func setRearTouch(_ enabled: Bool) {
        rearTouch = enabled
        bridge?.inputSetRearTouch(enabled ? 1 : 0)
    }

    func setButton(_ bit: UInt32, ext: UInt32 = 0, pressed: Bool) {
        if pressed {
            buttonsMask |= bit
            buttonsExtMask |= ext
        } else {
            buttonsMask &= ~bit
            buttonsExtMask &= ~ext
        }
        bridge?.inputVirtualButtons(buttonsMask, buttonsExtMask)
    }

    func setStick(_ index: Int, x: Float, y: Float) {
        if index == 0 { leftStick = (x, y) } else { rightStick = (x, y) }
        bridge?.inputVirtualAxes(leftStick.0, leftStick.1, rightStick.0, rightStick.1)
    }

    func setPaused(_ paused: Bool) {
        guard let bridge, launched, !closing else { return }
        if paused { bridge.inputClear() }
        _ = bridge.sessionSetPause(1, paused ? 1 : 0)
    }

    func setBackground(_ background: Bool) {
        guard let bridge, launched, !closing else { return }
        if background { bridge.inputClear() }
        bridge.sessionSetBackground(background ? 1 : 0)
    }

    func close(completion: @escaping () -> Void) {
        guard !closing else { return }
        closing = true
        stopping = true
        pollTimer?.invalidate()
        pollTimer = nil
        surfaceView.onLayoutDrawable = nil
        surfaceView.onTouchEvent = nil
        guard let bridge, launched else {
            stopping = false
            completion()
            return
        }
        bridge.inputClear()
        bridge.inputVirtualEnabled(0)
        _ = bridge.sessionStop()
        Task.detached(priority: .userInitiated) {
            for _ in 0..<80 {
                if bridge.sessionIsActive() == 0 { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            await MainActor.run {
                self.launched = false
                self.stopping = false
                completion()
            }
        }
    }
}

// MARK: - SwiftUI PS Vita Player View

struct VitaPlayer: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session = VitaSession()
    @State private var showingPauseMenu = false
    @State private var importingFirmware = false
    @State private var noticeText: String?
    @State private var hasController = !GCController.controllers().isEmpty
    @State private var showVirtualPad = GCController.controllers().isEmpty
    @AppStorage("phone.player.padOpacity") private var padOpacity = 0.86
    @AppStorage(TouchPadHaptics.defaultsKey) private var hapticsEnabled = true
    @AppStorage("phone.player.psv.performanceMode") private var performanceMode = 0
    @AppStorage("phone.player.psv.resolution") private var resolutionScale = 1.0

    let rom: PhoneLibrary.ROM
    let library: PhoneLibrary

    private var pauseSubtitle: String {
        let fps = session.currentFPS > 0 ? " · \(session.currentFPS) FPS" : ""
        let jit = session.jitReady ? "JIT" : "待检测"
        return "PS Vita · Vita3K (Vulkan · \(jit)\(fps))"
    }

    var body: some View {
        FullScreenReader { fullSize, safeInsets in
            let wide = fullSize.width > fullSize.height
            let padSide: CGFloat = wide ? min(124, fullSize.height * 0.38) : min(128, fullSize.width * 0.34)

            ZStack {
                Color.black

                if let error = session.error {
                    VStack(spacing: 16) {
                        ContentUnavailableView {
                            Label(session.jitRequiredError ? "需要启用 JIT" : "无法启动 PS Vita",
                                  systemImage: session.jitRequiredError ? "bolt.badge.clock" : "exclamationmark.circle")
                        } description: {
                            Text(error)
                        } actions: {
                            HStack(spacing: 10) {
                                if session.jitRequiredError {
                                    Button("重试检测 JIT") {
                                        session.start(
                                            rom: rom,
                                            library: library,
                                            performanceMode: performanceMode,
                                            resolutionScale: resolutionScale,
                                            virtualPadVisible: showVirtualPad
                                        )
                                    }
                                    .buttonStyle(.borderedProminent)
                                }
                                Button("导入固件 (.PUP)") { importingFirmware = true }
                                    .buttonStyle(.bordered)
                            }
                        }
                        .foregroundStyle(.white)

                        Button("返回游戏库") { session.close { dismiss() } }
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color(white: 0.06))
                            .padding(.horizontal, 22)
                            .frame(height: 42)
                            .background(Color(white: 0.94), in: Capsule())
                            .buttonStyle(PhoneTactileButtonStyle())
                    }
                    .padding(24)
                } else {
                    VStack(spacing: 0) {
                        if !wide {
                            HStack {
                                Spacer()
                                PlayerFloatingPill(title: rom.title, hasController: hasController) {
                                    openPauseMenu()
                                }
                                Spacer()
                            }
                            .padding(.top, max(safeInsets.top, 8) + 4)
                            .padding(.bottom, 8)
                        }

                        VitaSurfaceView(view: session.surfaceView)
                            .aspectRatio(wide ? nil : (960.0 / 544.0), contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: wide ? .infinity : nil)
                            .clipShape(RoundedRectangle(cornerRadius: wide ? 0 : 12, style: .continuous))
                            .padding(.horizontal, wide ? 0 : 10)
                            .padding(.bottom, wide ? 0 : 10)

                        if !wide {
                            if showVirtualPad {
                                VStack(spacing: 10) {
                                    HStack {
                                        HStack(spacing: 6) {
                                            shoulder("L", bit: VitaButtonBit.l, ext: VitaButtonBit.extL1)
                                            shoulder("L2", bit: 0, ext: VitaButtonBit.extL2)
                                        }
                                        Spacer()
                                        HStack(spacing: 6) {
                                            shoulder("R2", bit: 0, ext: VitaButtonBit.extR2)
                                            shoulder("R", bit: VitaButtonBit.r, ext: VitaButtonBit.extR1)
                                        }
                                    }

                                    HStack(alignment: .center) {
                                        TouchDPad { state in
                                            session.setButton(VitaButtonBit.up, pressed: state.up)
                                            session.setButton(VitaButtonBit.down, pressed: state.down)
                                            session.setButton(VitaButtonBit.left, pressed: state.left)
                                            session.setButton(VitaButtonBit.right, pressed: state.right)
                                        }
                                        .frame(width: padSide, height: padSide)

                                        Spacer()

                                        TouchDiamondPad(labels: .init(top: "△", left: "□", right: "○", bottom: "×")) { state in
                                            session.setButton(VitaButtonBit.triangle, pressed: state.top)
                                            session.setButton(VitaButtonBit.square, pressed: state.left)
                                            session.setButton(VitaButtonBit.circle, pressed: state.right)
                                            session.setButton(VitaButtonBit.cross, pressed: state.bottom)
                                        }
                                        .frame(width: padSide, height: padSide)
                                    }

                                    HStack {
                                        TouchAnalogStick(invertY: false) { x, y in
                                            session.setStick(0, x: x, y: y)
                                        }
                                        .frame(width: 74, height: 74)

                                        Spacer()

                                        HStack(spacing: 12) {
                                            TouchPadButton(title: "SELECT") { session.setButton(VitaButtonBit.select, pressed: $0) }
                                                .frame(width: 72, height: 32)
                                            TouchPadButton(title: "START") { session.setButton(VitaButtonBit.start, pressed: $0) }
                                                .frame(width: 72, height: 32)
                                        }

                                        Spacer()

                                        TouchAnalogStick(invertY: false) { x, y in
                                            session.setStick(1, x: x, y: y)
                                        }
                                        .frame(width: 74, height: 74)
                                    }
                                }
                                .padding(.horizontal, max(max(safeInsets.leading, safeInsets.trailing), 16))
                                .padding(.top, 12)
                                .padding(.bottom, max(safeInsets.bottom, 14) + 4)
                                .background(Color.white.opacity(0.035))
                                .overlay(alignment: .top) {
                                    Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.75)
                                }
                                .opacity(padOpacity)
                                .transition(.opacity)
                            } else {
                                VStack(spacing: 6) {
                                    Image(systemName: "gamecontroller.fill")
                                        .font(.system(size: 18))
                                        .foregroundStyle(.white.opacity(0.45))
                                    Text(hasController ? "已连接实体手柄 · 虚拟按键已自动隐藏" : "虚拟按键已隐藏")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.6))
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.top, 24)
                                .padding(.bottom, max(safeInsets.bottom, 24) + 6)
                            }
                        }
                    }
                    .overlay {
                        if wide && showVirtualPad {
                            HStack {
                                VStack(spacing: 8) {
                                    HStack(spacing: 6) {
                                        shoulder("L", bit: VitaButtonBit.l, ext: VitaButtonBit.extL1)
                                        shoulder("L2", bit: 0, ext: VitaButtonBit.extL2)
                                    }
                                    Spacer(minLength: 0)
                                    TouchDPad { state in
                                        session.setButton(VitaButtonBit.up, pressed: state.up)
                                        session.setButton(VitaButtonBit.down, pressed: state.down)
                                        session.setButton(VitaButtonBit.left, pressed: state.left)
                                        session.setButton(VitaButtonBit.right, pressed: state.right)
                                    }
                                    .frame(width: min(padSide, 114), height: min(padSide, 114))
                                    TouchAnalogStick(invertY: false) { x, y in
                                        session.setStick(0, x: x, y: y)
                                    }
                                    .frame(width: 70, height: 70)
                                    Spacer(minLength: 0)
                                    TouchPadButton(title: "Select") { session.setButton(VitaButtonBit.select, pressed: $0) }
                                        .frame(width: 72, height: 30)
                                }
                                Spacer()
                                VStack(spacing: 8) {
                                    HStack(spacing: 6) {
                                        shoulder("R2", bit: 0, ext: VitaButtonBit.extR2)
                                        shoulder("R", bit: VitaButtonBit.r, ext: VitaButtonBit.extR1)
                                    }
                                    Spacer(minLength: 0)
                                    TouchDiamondPad(labels: .init(top: "△", left: "□", right: "○", bottom: "×")) { state in
                                        session.setButton(VitaButtonBit.triangle, pressed: state.top)
                                        session.setButton(VitaButtonBit.square, pressed: state.left)
                                        session.setButton(VitaButtonBit.circle, pressed: state.right)
                                        session.setButton(VitaButtonBit.cross, pressed: state.bottom)
                                    }
                                    .frame(width: min(padSide, 114), height: min(padSide, 114))
                                    TouchAnalogStick(invertY: false) { x, y in
                                        session.setStick(1, x: x, y: y)
                                    }
                                    .frame(width: 70, height: 70)
                                    Spacer(minLength: 0)
                                    TouchPadButton(title: "Start") { session.setButton(VitaButtonBit.start, pressed: $0) }
                                        .frame(width: 72, height: 30)
                                }
                            }
                            .padding(.leading, max(safeInsets.leading, 14))
                            .padding(.trailing, max(safeInsets.trailing, 14))
                            .padding(.top, max(safeInsets.top, 10))
                            .padding(.bottom, max(safeInsets.bottom, 10))
                            .opacity(padOpacity)
                            .transition(.opacity)
                        }
                    }
                    .overlay(alignment: .top) {
                        if wide {
                            PlayerFloatingPill(title: rom.title, hasController: hasController) {
                                openPauseMenu()
                            }
                            .padding(.top, max(safeInsets.top, 10))
                        }
                    }
                }

                if session.starting || session.stopping {
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.large).tint(.white)
                        Text(session.stopping ? "正在保存并退出…" : session.statusText)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                            .multilineTextAlignment(.center)
                    }
                    .padding(22)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 1))
                }

                if showingPauseMenu && !session.starting {
                    PlayerPauseOverlay(
                        title: rom.title,
                        subtitle: pauseSubtitle,
                        hasController: hasController,
                        showVirtualPad: $showVirtualPad,
                        padOpacity: $padOpacity,
                        hapticsEnabled: $hapticsEnabled,
                        isExiting: session.stopping,
                        onResume: { closePauseMenu() },
                        onExit: {
                            showingPauseMenu = false
                            session.close { dismiss() }
                        }
                    ) {
                        Divider().overlay(Color.white.opacity(0.08))

                        Toggle("背部触控板模式（Rear Touch）", isOn: Binding(
                            get: { session.rearTouch },
                            set: { session.setRearTouch($0) }
                        ))
                        .font(.system(size: 13, weight: .medium))
                        .tint(.white)

                        VStack(alignment: .leading, spacing: 6) {
                            Text("性能预设（Zeta 流畅调优 · 下次启动生效）")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.68))
                            Picker("性能模式", selection: $performanceMode) {
                                Text("极致流畅").tag(0)
                                Text("均衡").tag(1)
                                Text("高画质").tag(2)
                            }
                            .pickerStyle(.segmented)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("渲染分辨率（下次启动生效）")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.68))
                            Picker("分辨率", selection: $resolutionScale) {
                                Text("0.5x").tag(0.5)
                                Text("1x 原生").tag(1.0)
                                Text("1.5x").tag(1.5)
                                Text("2x 高清").tag(2.0)
                            }
                            .pickerStyle(.segmented)
                        }

                        HStack(spacing: 10) {
                            Button {
                                importingFirmware = true
                            } label: {
                                Label(session.firmwareInstalled ? "更新固件 (.PUP)" : "导入固件 (.PUP)", systemImage: "cpu")
                                    .font(.system(size: 12, weight: .medium))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                    .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                            .buttonStyle(PhoneTactileButtonStyle())

                            Button {
                                session.clearShaderCache()
                                noticeText = "已清除当前游戏的着色器缓存，下次启动将重新编译。"
                            } label: {
                                Label("清理着色器", systemImage: "trash")
                                    .font(.system(size: 12, weight: .medium))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                    .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                            .buttonStyle(PhoneTactileButtonStyle())
                        }
                        .foregroundStyle(.white.opacity(0.90))
                    }
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.18), value: showVirtualPad)
            .animation(.easeOut(duration: 0.16), value: showingPauseMenu)
        }
        .background(Color.black.ignoresSafeArea())
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .interactiveDismissDisabled()
        .task {
            syncControllerState()
            session.start(
                rom: rom,
                library: library,
                performanceMode: performanceMode,
                resolutionScale: resolutionScale,
                virtualPadVisible: showVirtualPad
            )
        }
        .onChange(of: showVirtualPad) { _, visible in
            session.setVirtualPadEnabled(visible)
        }
        .onChange(of: performanceMode) { _, mode in
            if let id = session.activeTitleID {
                session.applyZetaPreset(titleID: id, performanceMode: mode, resolutionScale: resolutionScale)
            }
        }
        .onChange(of: resolutionScale) { _, scale in
            if let id = session.activeTitleID {
                session.applyZetaPreset(titleID: id, performanceMode: performanceMode, resolutionScale: scale)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in syncControllerState() }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) { _ in syncControllerState() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            session.setBackground(true)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            session.setBackground(false)
            if !showingPauseMenu { session.setPaused(false) }
        }
        .onDisappear { session.close {} }
        .fileImporter(isPresented: $importingFirmware, allowedContentTypes: [.data]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                noticeText = session.installFirmware(from: url)
            } catch {
                noticeText = error.localizedDescription
            }
        }
        .alert("PS Vita", isPresented: Binding(get: { noticeText != nil }, set: { if !$0 { noticeText = nil } })) {
            Button("好") { noticeText = nil }
        } message: {
            Text(noticeText ?? "")
        }
    }

    private func openPauseMenu() {
        session.setPaused(true)
        showingPauseMenu = true
    }

    private func closePauseMenu() {
        showingPauseMenu = false
        session.setPaused(false)
    }

    private func syncControllerState() {
        let connected = !GCController.controllers().isEmpty
        if connected != hasController {
            hasController = connected
            showVirtualPad = !connected
            session.setVirtualPadEnabled(!connected)
        }
    }

    private func shoulder(_ title: String, bit: UInt32, ext: UInt32) -> some View {
        TouchPadButton(title: title) { session.setButton(bit, ext: ext, pressed: $0) }
            .frame(width: 54, height: 32)
    }
}
