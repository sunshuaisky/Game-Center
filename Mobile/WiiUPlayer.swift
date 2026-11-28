import AVFoundation
import Darwin
import GameController
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import QuartzCore

final class NativeMetalView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    var resized: (() -> Void)?
    private var lastSize: CGSize = .zero
    private var lastScale: CGFloat = 0

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.screen.scale ?? traitCollection.displayScale
        contentScaleFactor = scale
        if bounds.width > 1 && bounds.height > 1 && (bounds.size != lastSize || scale != lastScale) {
            lastSize = bounds.size
            lastScale = scale
            resized?()
        }
    }
}

/// Cemu's device framework exports a C ABI independently of the desktop app.
// Engine initialization and shutdown use queue. The retained render view and
// resize/input bridge calls are accessed from the main thread.
private final class WiiUCore: @unchecked Sendable {
    typealias Initialize = @convention(c) (UnsafePointer<CChar>) -> Void
    typealias Boot = @convention(c) (UnsafePointer<CChar>) -> Int32
    typealias Surface = @convention(c) (UnsafeMutableRawPointer, Int32, Int32, Double) -> Void
    typealias Resize = @convention(c) (Int32, Int32, Double, Bool) -> Void
    typealias Action = @convention(c) () -> Void
    typealias Button = @convention(c) (Int32, Bool) -> Void
    typealias Stick = @convention(c) (Int32, Float, Float) -> Void
    typealias Touch = @convention(c) (Double, Double, Bool) -> Void
    typealias Route = @convention(c) (Bool, Bool) -> Void
    typealias Available = @convention(c) () -> Bool
    typealias SetInt = @convention(c) (Int32) -> Void
    typealias SetBool = @convention(c) (Bool) -> Void
    typealias CountKeys = @convention(c) () -> Int32
    typealias StatusText = @convention(c) () -> UnsafePointer<CChar>?

    private static var instance: WiiUCore?
    let initialize: Initialize
    let boot: Boot
    let surface: Surface
    let resize: Resize
    let stop: Action
    let pause: Action
    let resume: Action
    let releaseButtons: Action
    let button: Button
    let stick: Stick
    let touch: Touch
    let route: Route
    let prepareKeys: Initialize?
    let reloadKeys: CountKeys?
    let setGraphicsAPI: SetInt?
    let setRecompiler: SetBool?
    let refreshInputDevices: Action?
    let statusText: StatusText?
    let queue = DispatchQueue(label: "GameCenter.WiiU", qos: .userInitiated)
    // Keep the render view alive across SwiftUI transitions and until the GPU stops.
    let view = NativeMetalView()
    private var root: URL?
    private var surfaceRetained = false

    static func shared() throws -> WiiUCore {
        if let instance { return instance }
        let loaded = try WiiUCore()
        instance = loaded
        return loaded
    }

    private init() throws {
        // Preload MoltenVK if bundled so Vulkan fallback works cleanly alongside native Metal.
        let mvkPath = Bundle.main.bundleURL.appendingPathComponent("Frameworks/MoltenVK.framework/MoltenVK").path
        if FileManager.default.fileExists(atPath: mvkPath) {
            setenv("MUFFIN_MOLTENVK_PATH", mvkPath, 0)
        }
        let path = Bundle.main.bundleURL.appendingPathComponent("Frameworks/Cemu.framework/Cemu").path
        guard let library = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            let reason = dlerror().map { String(cString: $0) } ?? ""
            throw Failure("无法加载 Wii U 引擎，请重新生成并安装包含 Cemu 核心的 iOS 应用。" + (reason.isEmpty ? "" : "\n" + reason))
        }
        func symbol<T>(_ name: String, as type: T.Type) throws -> T {
            guard let address = dlsym(library, name) else { throw Failure("Wii U 核心接口不完整：" + name) }
            return unsafeBitCast(address, to: type)
        }
        func optionalSymbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let address = dlsym(library, name) else { return nil }
            return unsafeBitCast(address, to: type)
        }
        do {
            let available = try symbol("cemu_bridge_core_available", as: Available.self)
            guard available() else { throw Failure("Wii U 核心未包含模拟器运行代码。") }
            initialize = try symbol("cemu_bridge_initialize", as: Initialize.self)
            boot = try symbol("cemu_bridge_boot_title", as: Boot.self)
            surface = try symbol("cemu_bridge_register_render_surface", as: Surface.self)
            resize = try symbol("cemu_bridge_resize_render_surface", as: Resize.self)
            stop = try symbol("cemu_bridge_shutdown_title", as: Action.self)
            pause = try symbol("cemu_bridge_pause", as: Action.self)
            resume = try symbol("cemu_bridge_resume", as: Action.self)
            releaseButtons = try symbol("cemu_bridge_release_all_buttons", as: Action.self)
            button = try symbol("cemu_bridge_set_button_state", as: Button.self)
            stick = try symbol("cemu_bridge_set_stick_axis", as: Stick.self)
            route = try symbol("cemu_bridge_set_output_sources", as: Route.self)
            touch = try symbol("cemu_bridge_set_pad_touch", as: Touch.self)
            prepareKeys = optionalSymbol("cemu_bridge_prepare_keys_before_init", as: Initialize.self)
            reloadKeys = optionalSymbol("cemu_bridge_reload_and_count_keys", as: CountKeys.self)
            setGraphicsAPI = optionalSymbol("cemu_bridge_set_graphics_api", as: SetInt.self)
            setRecompiler = optionalSymbol("cemu_bridge_set_recompiler_enabled", as: SetBool.self)
            refreshInputDevices = optionalSymbol("cemu_bridge_refresh_input_devices", as: Action.self)
            statusText = optionalSymbol("cemu_bridge_status_text", as: StatusText.self)
        } catch {
            dlclose(library)
            throw error
        }
        view.backgroundColor = .black
        view.isMultipleTouchEnabled = false
    }

    func prepare(root: URL) throws {
        if let current = self.root {
            if current.standardizedFileURL != root.standardizedFileURL {
                throw Failure("Wii U 核心已使用另一个存档目录，请退出并重新打开 Game Center。")
            }
            return
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.root = root
        root.path.withCString { cPath in
            prepareKeys?(cPath)
            initialize(cPath)
        }
        _ = reloadKeys?()
    }

    func registerSurface(width: Int32, height: Int32, scale: Double) {
        let pointer: UnsafeMutableRawPointer
        if surfaceRetained {
            pointer = Unmanaged.passUnretained(view).toOpaque()
        } else {
            surfaceRetained = true
            pointer = Unmanaged.passRetained(view).toOpaque()
        }
        surface(pointer, width, height, scale)
    }

    func latestStatus() -> String? {
        guard let raw = statusText?() else { return nil }
        let text = String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}

private final class WiiUDisplayLinkProxy: NSObject {
    weak var target: WiiUSession?
    init(target: WiiUSession) { self.target = target }
    @objc func tick() {
        MainActor.assumeIsolated {
            target?.pollGamepad()
        }
    }
}

@MainActor
private final class WiiUSession: NSObject, ObservableObject {
    @Published var error: String?
    @Published var starting = true
    @Published var stopping = false
    @Published var gamePad = false
    @Published fileprivate var core: WiiUCore?
    private var closing = false
    private var launched = false
    private var bootSucceeded = false
    private var displayLink: CADisplayLink?
    private var connectObserver: NSObjectProtocol?
    private var disconnectObserver: NSObjectProtocol?
    private var touchButtonsMask: UInt32 = 0
    private var touchSticks: [(Float, Float)] = [(0, 0), (0, 0)]
    private var lastSentButtonsMask: UInt32 = 0
    private var lastSentSticks: [(Float, Float)] = [(0, 0), (0, 0)]

    func setTouchButton(_ id: Int32, pressed: Bool) {
        guard id >= 1 && id <= 31 else { return }
        let bit: UInt32 = 1 << UInt32(id)
        if pressed { touchButtonsMask |= bit } else { touchButtonsMask &= ~bit }
        pollGamepad()
    }

    func setTouchStick(_ index: Int, x: Float, y: Float) {
        guard index == 0 || index == 1 else { return }
        touchSticks[index] = (x, y)
        pollGamepad()
    }

    private func startGamepadPolling() {
        guard connectObserver == nil else { return }
        GCController.startWirelessControllerDiscovery(completionHandler: nil)
        connectObserver = NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.core?.refreshInputDevices?()
                self?.updateGamepadDisplayLink()
            }
        }
        disconnectObserver = NotificationCenter.default.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.core?.refreshInputDevices?()
                self?.updateGamepadDisplayLink()
            }
        }
        updateGamepadDisplayLink()
    }

    private func updateGamepadDisplayLink() {
        let hasController = !GCController.controllers().isEmpty
        if hasController && !closing && bootSucceeded {
            if displayLink == nil {
                let proxy = WiiUDisplayLinkProxy(target: self)
                let link = CADisplayLink(target: proxy, selector: #selector(WiiUDisplayLinkProxy.tick))
                link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
                link.add(to: .main, forMode: .common)
                displayLink = link
            }
        } else {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    private func stopGamepadPolling() {
        displayLink?.invalidate()
        displayLink = nil
        GCController.stopWirelessControllerDiscovery()
        if let connectObserver { NotificationCenter.default.removeObserver(connectObserver); self.connectObserver = nil }
        if let disconnectObserver { NotificationCenter.default.removeObserver(disconnectObserver); self.disconnectObserver = nil }
        touchButtonsMask = 0
        touchSticks = [(0, 0), (0, 0)]
        lastSentButtonsMask = 0
        lastSentSticks = [(0, 0), (0, 0)]
    }

    func pollGamepad() {
        guard let core, bootSucceeded, !closing else { return }
        var buttons = touchButtonsMask
        var leftStick = touchSticks[0]
        var rightStick = touchSticks[1]

        if let pad = (GCController.current ?? GCController.controllers().first)?.extendedGamepad {
            // Nintendo layout: East(B) -> A(1), South(A) -> B(2), North(Y) -> X(3), West(X) -> Y(4)
            if pad.buttonB.isPressed { buttons |= (1 << 1) }
            if pad.buttonA.isPressed { buttons |= (1 << 2) }
            if pad.buttonY.isPressed { buttons |= (1 << 3) }
            if pad.buttonX.isPressed { buttons |= (1 << 4) }
            if pad.leftShoulder.isPressed { buttons |= (1 << 5) }
            if pad.rightShoulder.isPressed { buttons |= (1 << 6) }
            if pad.leftTrigger.value > 0.25 { buttons |= (1 << 7) }
            if pad.rightTrigger.value > 0.25 { buttons |= (1 << 8) }
            if pad.buttonMenu.isPressed { buttons |= (1 << 9) }
            if pad.buttonOptions?.isPressed == true { buttons |= (1 << 10) }
            if pad.dpad.up.isPressed { buttons |= (1 << 11) }
            if pad.dpad.down.isPressed { buttons |= (1 << 12) }
            if pad.dpad.left.isPressed { buttons |= (1 << 13) }
            if pad.dpad.right.isPressed { buttons |= (1 << 14) }
            if pad.leftThumbstickButton?.isPressed == true { buttons |= (1 << 15) }
            if pad.rightThumbstickButton?.isPressed == true { buttons |= (1 << 16) }

            let lx = pad.leftThumbstick.xAxis.value
            let ly = pad.leftThumbstick.yAxis.value
            if abs(lx) > 0.05 || abs(ly) > 0.05 { leftStick = (lx, ly) }
            let rx = pad.rightThumbstick.xAxis.value
            let ry = pad.rightThumbstick.yAxis.value
            if abs(rx) > 0.05 || abs(ry) > 0.05 { rightStick = (rx, ry) }
        } else if let micro = (GCController.current ?? GCController.controllers().first)?.microGamepad {
            if micro.buttonX.isPressed { buttons |= (1 << 1) }
            if micro.buttonA.isPressed { buttons |= (1 << 2) }
            if micro.buttonMenu.isPressed { buttons |= (1 << 9) }
            if micro.dpad.up.isPressed { buttons |= (1 << 11) }
            if micro.dpad.down.isPressed { buttons |= (1 << 12) }
            if micro.dpad.left.isPressed { buttons |= (1 << 13) }
            if micro.dpad.right.isPressed { buttons |= (1 << 14) }
        }

        let changed = buttons ^ lastSentButtonsMask
        if changed != 0 {
            var remaining = changed
            while remaining != 0 {
                let bitIndex = remaining.trailingZeroBitCount
                remaining &= remaining - 1
                core.button(Int32(bitIndex), (buttons & (1 << UInt32(bitIndex))) != 0)
            }
            lastSentButtonsMask = buttons
        }

        if leftStick != lastSentSticks[0] {
            core.stick(0, leftStick.0, leftStick.1)
            lastSentSticks[0] = leftStick
        }
        if rightStick != lastSentSticks[1] {
            core.stick(1, rightStick.0, rightStick.1)
            lastSentSticks[1] = rightStick
        }
    }

    func start(rom: PhoneLibrary.ROM, library: PhoneLibrary) {
        guard !launched, !closing else { return }
        error = nil
        starting = true
        // Release S2Arm's unused 60+ GiB constructor VA window before Cemu's MMU
        // reserves 4 GiB via vm_allocate (otherwise Cemu MMU.cpp exits immediately).
        if gc_s2arm_release_va_window() != 0 {
            self.error = "当前进程已运行过 Switch 游戏并占用虚拟地址空间，请彻底关闭并重新打开 Game Center 后再启动 Wii U 游戏。"
            starting = false
            return
        }
        let existingCore = self.core
        Task { [weak self] in
            do {
                let setup: (WiiUCore, URL, String) = try await Task.detached(priority: .userInitiated) {
                    let core = try existingCore ?? WiiUCore.shared()
                    library.seedSystemFiles(for: rom.platform)
                    let root = library.root.appendingPathComponent("save/wiiu/mlc", isDirectory: true)
                    let biosCandidates = [
                        library.bios.appendingPathComponent("\(rom.platform.folder)/keys.txt"),
                        library.bios.appendingPathComponent("WiiU/keys.txt")
                    ]
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                    if let bios = biosCandidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                        let data = try Data(contentsOf: bios)
                        try data.write(to: root.appendingPathComponent("keys.txt"), options: .atomic)
                        let keysDir = library.documents.appendingPathComponent("keys", isDirectory: true)
                        try FileManager.default.createDirectory(at: keysDir, withIntermediateDirectories: true)
                        try data.write(to: keysDir.appendingPathComponent("keys.txt"), options: .atomic)
                    }
                    let bootPath = Self.resolveBootPath(for: rom.url)
                    return (core, root, bootPath)
                }.value

                guard let self, !self.closing else { return }
                let (core, root, bootPath) = setup
                self.core = core
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
                try AVAudioSession.sharedInstance().setActive(true)

                let surface = core.view
                let handleSurfaceLayout: () -> Void = { [weak self] in
                    guard let self, !self.closing else { return }
                    let scale = max(1.0, Double(surface.contentScaleFactor))
                    let width = Int32(max(1, surface.bounds.width))
                    let height = Int32(max(1, surface.bounds.height))
                    guard width > 1, height > 1 else { return }

                    if self.launched {
                        core.resize(width, height, scale, true)
                        return
                    }
                    self.launched = true
                    core.registerSurface(width: width, height: height, scale: scale)
                    core.queue.async { [weak self] in
                        var failure: String?
                        do {
                            try core.prepare(root: root)
                            // Native Metal renderer (2 = Metal, 1 = Vulkan); recompiler falls back to interpreter without JIT.
                            core.setGraphicsAPI?(2)
                            core.setRecompiler?(true)
                            let status = bootPath.withCString(core.boot)
                            if status != 0 {
                                let detail = core.latestStatus().map { "\n" + $0 } ?? ""
                                switch status {
                                case 3, 4, 9:
                                    failure = "缺少此加密 Wii U 游戏的密钥。请点击右上角「导入 keys.txt」或将 keys.txt 放入 BIOS/wiiu 后重试。"
                                case 6:
                                    failure = "选中的是更新或 DLC，请先导入并启动基础游戏。"
                                default:
                                    failure = "Wii U 核心无法载入此游戏，错误码 " + String(status) + detail
                                }
                            }
                        } catch {
                            failure = error.localizedDescription
                        }
                        DispatchQueue.main.async { [weak self] in
                            guard let self else { return }
                            self.starting = false
                            self.error = failure
                            if failure == nil {
                                self.bootSucceeded = true
                                self.startGamepadPolling()
                            } else {
                                self.launched = false
                            }
                        }
                    }
                }

                surface.resized = handleSurfaceLayout
                if surface.bounds.width > 1 && surface.bounds.height > 1 {
                    handleSurfaceLayout()
                } else {
                    surface.setNeedsLayout()
                }
            } catch {
                self?.error = error.localizedDescription
                self?.starting = false
            }
        }
    }

    nonisolated private static func resolveBootPath(for url: URL) -> String {
        let fm = FileManager.default
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            return url.path
        }
        let code = url.appendingPathComponent("code", isDirectory: true)
        if let rpx = ((try? fm.contentsOfDirectory(at: code, includingPropertiesForKeys: nil)) ?? [])
            .sorted(by: { $0.path < $1.path })
            .first(where: { $0.pathExtension.lowercased() == "rpx" }) {
            return rpx.path
        }
        return url.path
    }

    func setPaused(_ paused: Bool) {
        guard let core, bootSucceeded, !closing else { return }
        core.releaseButtons()
        core.queue.async { paused ? core.pause() : core.resume() }
    }

    func close(completion: @escaping () -> Void) {
        guard !closing else { return }
        closing = true
        stopping = true
        stopGamepadPolling()
        guard let core else { completion(); return }
        core.view.resized = nil
        core.releaseButtons()
        let shouldStop = bootSucceeded || launched
        core.queue.async {
            if shouldStop { core.stop() }
            DispatchQueue.main.async {
                self.stopping = false
                completion()
            }
        }
    }

    func displayGamePad(_ enabled: Bool) {
        guard let core else { return }
        core.route(enabled, false)
        gamePad = enabled
    }
}

private struct WiiUSurface: UIViewRepresentable {
    let core: WiiUCore
    func makeUIView(context: Context) -> UIView { core.view }
    func updateUIView(_ view: UIView, context: Context) {}
}

struct WiiUPlayer: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session = WiiUSession()
    @State private var importingKeys = false
    @State private var keysNotice: String?
    @State private var showingPauseMenu = false
    @State private var hasController = !GCController.controllers().isEmpty
    @State private var showVirtualPad = GCController.controllers().isEmpty
    @AppStorage("phone.player.padOpacity") private var padOpacity = 0.86
    @AppStorage(TouchPadHaptics.defaultsKey) private var hapticsEnabled = true
    let rom: PhoneLibrary.ROM
    let library: PhoneLibrary

    var body: some View {
        FullScreenReader { fullSize, safeInsets in
            let wide = fullSize.width > fullSize.height
            ZStack {
                Color.black

                if let error = session.error {
                    VStack(spacing: 16) {
                        ContentUnavailableView {
                            Label("无法启动", systemImage: "exclamationmark.circle")
                        } description: {
                            Text(error)
                        } actions: {
                            Button("导入 keys.txt") { importingKeys = true }
                                .buttonStyle(.bordered)
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
                    // Keep WiiUSurface at one stable SwiftUI identity across portrait/landscape
                    // rotations so UIKit never detaches the CAMetalLayer while Cemu renders.
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

                        wiiUSurfaceView(rounded: !wide)
                            .frame(maxWidth: .infinity, maxHeight: wide ? .infinity : nil)
                            .padding(.horizontal, wide ? 0 : 10)
                            .padding(.bottom, wide ? 0 : 10)

                        if !wide {
                            if showVirtualPad {
                                VStack(spacing: 12) {
                                    HStack {
                                        HStack(spacing: 6) { padButton("L", 5); padButton("ZL", 7) }
                                        Spacer()
                                        HStack(spacing: 6) { padButton("ZR", 8); padButton("R", 6) }
                                    }
                                    HStack {
                                        TouchDPad { state in
                                            session.setTouchButton(11, pressed: state.up)
                                            session.setTouchButton(12, pressed: state.down)
                                            session.setTouchButton(13, pressed: state.left)
                                            session.setTouchButton(14, pressed: state.right)
                                        }
                                        .frame(width: 124, height: 124)
                                        Spacer()
                                        TouchDiamondPad(labels: .init(top: "X", left: "Y", right: "A", bottom: "B")) { state in
                                            session.setTouchButton(3, pressed: state.top)
                                            session.setTouchButton(4, pressed: state.left)
                                            session.setTouchButton(1, pressed: state.right)
                                            session.setTouchButton(2, pressed: state.bottom)
                                        }
                                        .frame(width: 124, height: 124)
                                    }
                                    HStack {
                                        TouchAnalogStick(invertY: true) { x, y in
                                            session.setTouchStick(0, x: x, y: y)
                                        }
                                        .frame(width: 74, height: 74)
                                        Spacer()
                                        HStack(spacing: 12) { padButton("−", 10); padButton("+", 9) }
                                        Spacer()
                                        TouchAnalogStick(invertY: true) { x, y in
                                            session.setTouchStick(1, x: x, y: y)
                                        }
                                        .frame(width: 74, height: 74)
                                    }
                                }
                                .padding(.horizontal, max(max(safeInsets.leading, safeInsets.trailing), 18))
                                .padding(.top, 14)
                                .padding(.bottom, max(safeInsets.bottom, 16) + 4)
                                .background(Color.white.opacity(0.035))
                                .overlay(alignment: .top) {
                                    Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.75)
                                }
                                .opacity(padOpacity)
                                .transition(.opacity)
                            } else {
                                VStack(spacing: 6) {
                                    Image(systemName: "gamecontroller.fill")
                                        .font(.system(size: 20))
                                        .foregroundStyle(.white.opacity(0.45))
                                    Text(hasController ? "已连接实体手柄 · 虚拟按键已自动隐藏" : "虚拟按键已隐藏")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.6))
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.top, 28)
                                .padding(.bottom, max(safeInsets.bottom, 28) + 8)
                            }
                        }
                    }
                    .overlay {
                        if wide && showVirtualPad {
                            HStack {
                                leftWiiUControls
                                Spacer()
                                rightWiiUControls
                            }
                            .padding(.leading, max(safeInsets.leading, 14))
                            .padding(.trailing, max(safeInsets.trailing, 14))
                            .padding(.top, max(safeInsets.top, 12))
                            .padding(.bottom, max(safeInsets.bottom, 12))
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
                        Text(session.stopping ? "正在保存并退出…" : "正在载入 Wii U 游戏…")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    .padding(22)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 1))
                }

                if showingPauseMenu && !session.starting {
                    PlayerPauseOverlay(
                        title: rom.title,
                        subtitle: "Wii U · Cemu",
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
                        Toggle("显示 GamePad 副屏", isOn: Binding(get: { session.gamePad }, set: session.displayGamePad))
                            .font(.system(size: 13, weight: .medium))
                            .tint(.white)
                        Button {
                            importingKeys = true
                        } label: {
                            HStack {
                                Label("导入 Wii U keys.txt…", systemImage: "key")
                                    .font(.system(size: 12, weight: .medium))
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.45))
                            }
                            .foregroundStyle(.white.opacity(0.88))
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(PhoneTactileButtonStyle())
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
        .task {
            syncControllerState()
            session.start(rom: rom, library: library)
        }
        .interactiveDismissDisabled()
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in
            syncControllerState()
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) { _ in
            syncControllerState()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in session.setPaused(true) }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            if !showingPauseMenu { session.setPaused(false) }
        }
        .onDisappear { session.close {} }
        .fileImporter(isPresented: $importingKeys, allowedContentTypes: [.plainText, .data]) { result in
            do {
                let source = try result.get()
                let access = source.startAccessingSecurityScopedResource()
                defer { if access { source.stopAccessingSecurityScopedResource() } }
                let folder = library.bios.appendingPathComponent(rom.platform.folder, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let data = try Data(contentsOf: source)
                try data.write(to: folder.appendingPathComponent("keys.txt"), options: .atomic)
                keysNotice = "已导入 keys.txt，重新打开 Game Center 后将自动生效。"
            } catch {
                keysNotice = error.localizedDescription
            }
        }
        .alert("Wii U 密钥", isPresented: Binding(get: { keysNotice != nil }, set: { if !$0 { keysNotice = nil } })) {
            Button("好") { keysNotice = nil }
        } message: {
            Text(keysNotice ?? "")
        }
    }

    @ViewBuilder
    private func wiiUSurfaceView(rounded: Bool) -> some View {
        if let core = session.core {
            WiiUSurface(core: core)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: rounded ? 12 : 0, style: .continuous))
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    let size = core.view.bounds.size
                    guard session.gamePad, size.width > 0, size.height > 0 else { return }
                    let scale = max(1.0, Double(core.view.contentScaleFactor))
                    let x = min(size.width, max(0, value.location.x)) * scale
                    let y = min(size.height, max(0, value.location.y)) * scale
                    core.touch(x, y, true)
                }.onEnded { _ in core.touch(0, 0, false) })
        } else {
            Color.black.aspectRatio(16 / 9, contentMode: .fit)
        }
    }

    private var leftWiiUControls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                padButton("L", 5)
                padButton("ZL", 7)
            }
            Spacer(minLength: 0)
            TouchDPad { state in
                session.setTouchButton(11, pressed: state.up)
                session.setTouchButton(12, pressed: state.down)
                session.setTouchButton(13, pressed: state.left)
                session.setTouchButton(14, pressed: state.right)
            }
            .frame(width: 118, height: 118)
            TouchAnalogStick(invertY: true) { x, y in
                session.setTouchStick(0, x: x, y: y)
            }
            .frame(width: 72, height: 72)
            Spacer(minLength: 0)
            padButton("−", 10)
        }
    }

    private var rightWiiUControls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                padButton("ZR", 8)
                padButton("R", 6)
            }
            Spacer(minLength: 0)
            TouchDiamondPad(labels: .init(top: "X", left: "Y", right: "A", bottom: "B")) { state in
                session.setTouchButton(3, pressed: state.top)
                session.setTouchButton(4, pressed: state.left)
                session.setTouchButton(1, pressed: state.right)
                session.setTouchButton(2, pressed: state.bottom)
            }
            .frame(width: 118, height: 118)
            TouchAnalogStick(invertY: true) { x, y in
                session.setTouchStick(1, x: x, y: y)
            }
            .frame(width: 72, height: 72)
            Spacer(minLength: 0)
            padButton("+", 9)
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
        }
    }

    private func padButton(_ title: String, _ id: Int32) -> some View {
        TouchPadButton(title: title) { pressed in
            session.setTouchButton(id, pressed: pressed)
        }
        .frame(width: 56, height: 34)
    }
}
