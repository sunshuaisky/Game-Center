import AVFoundation
import Darwin
import GameController
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import QuartzCore
import Metal

final class NativeMetalView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    var resized: (() -> Void)?
    override func layoutSubviews() {
        super.layoutSubviews()
        contentScaleFactor = window?.screen.scale ?? traitCollection.displayScale
        if bounds.width > 1 && bounds.height > 1 { resized?() }
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

    private static var instance: WiiUCore?
    private let handle: UnsafeMutableRawPointer
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
    let queue = DispatchQueue(label: "GameCenter.WiiU", qos: .userInitiated)
    // Keep the render view alive across SwiftUI transitions and until the GPU stops.
    let view = NativeMetalView()
    private var root: URL?

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
        } catch {
            dlclose(library)
            throw error
        }
        handle = library
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

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
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
    private var displayLink: CADisplayLink?
    private var connectObserver: NSObjectProtocol?
    private var disconnectObserver: NSObjectProtocol?
    private var touchButtons = Set<Int32>()
    private var touchSticks: [(Float, Float)] = [(0, 0), (0, 0)]
    private var lastSentButtons = Set<Int32>()
    private var lastSentSticks: [(Float, Float)] = [(0, 0), (0, 0)]

    func setTouchButton(_ id: Int32, pressed: Bool) {
        if pressed { touchButtons.insert(id) } else { touchButtons.remove(id) }
        pollGamepad()
    }

    func setTouchStick(_ index: Int, x: Float, y: Float) {
        guard index == 0 || index == 1 else { return }
        touchSticks[index] = (x, y)
        pollGamepad()
    }

    private func startGamepadPolling() {
        guard displayLink == nil else { return }
        GCController.startWirelessControllerDiscovery(completionHandler: nil)
        connectObserver = NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.core?.refreshInputDevices?() }
        }
        disconnectObserver = NotificationCenter.default.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.core?.refreshInputDevices?() }
        }
        let link = CADisplayLink(target: self, selector: #selector(pollGamepad))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopGamepadPolling() {
        displayLink?.invalidate()
        displayLink = nil
        GCController.stopWirelessControllerDiscovery()
        if let connectObserver { NotificationCenter.default.removeObserver(connectObserver); self.connectObserver = nil }
        if let disconnectObserver { NotificationCenter.default.removeObserver(disconnectObserver); self.disconnectObserver = nil }
        touchButtons.removeAll()
        touchSticks = [(0, 0), (0, 0)]
        lastSentButtons.removeAll()
        lastSentSticks = [(0, 0), (0, 0)]
    }

    @objc private func pollGamepad() {
        guard let core, launched, !closing else { return }
        var buttons = touchButtons
        var leftStick = touchSticks[0]
        var rightStick = touchSticks[1]

        if let pad = (GCController.current ?? GCController.controllers().first)?.extendedGamepad {
            // Nintendo layout: East(B) -> A(1), South(A) -> B(2), North(Y) -> X(3), West(X) -> Y(4)
            if pad.buttonB.isPressed { buttons.insert(1) }
            if pad.buttonA.isPressed { buttons.insert(2) }
            if pad.buttonY.isPressed { buttons.insert(3) }
            if pad.buttonX.isPressed { buttons.insert(4) }
            if pad.leftShoulder.isPressed { buttons.insert(5) }
            if pad.rightShoulder.isPressed { buttons.insert(6) }
            if pad.leftTrigger.value > 0.25 { buttons.insert(7) }
            if pad.rightTrigger.value > 0.25 { buttons.insert(8) }
            if pad.buttonMenu.isPressed { buttons.insert(9) }
            if pad.buttonOptions?.isPressed == true { buttons.insert(10) }
            if pad.dpad.up.isPressed { buttons.insert(11) }
            if pad.dpad.down.isPressed { buttons.insert(12) }
            if pad.dpad.left.isPressed { buttons.insert(13) }
            if pad.dpad.right.isPressed { buttons.insert(14) }
            if pad.leftThumbstickButton?.isPressed == true { buttons.insert(15) }
            if pad.rightThumbstickButton?.isPressed == true { buttons.insert(16) }

            let lx = pad.leftThumbstick.xAxis.value
            let ly = pad.leftThumbstick.yAxis.value
            if abs(lx) > 0.05 || abs(ly) > 0.05 { leftStick = (lx, ly) }
            let rx = pad.rightThumbstick.xAxis.value
            let ry = pad.rightThumbstick.yAxis.value
            if abs(rx) > 0.05 || abs(ry) > 0.05 { rightStick = (rx, ry) }
        } else if let micro = (GCController.current ?? GCController.controllers().first)?.microGamepad {
            if micro.buttonX.isPressed { buttons.insert(1) }
            if micro.buttonA.isPressed { buttons.insert(2) }
            if micro.buttonMenu.isPressed { buttons.insert(9) }
            if micro.dpad.up.isPressed { buttons.insert(11) }
            if micro.dpad.down.isPressed { buttons.insert(12) }
            if micro.dpad.left.isPressed { buttons.insert(13) }
            if micro.dpad.right.isPressed { buttons.insert(14) }
        }

        let changed = buttons.symmetricDifference(lastSentButtons)
        for id in changed {
            core.button(id, buttons.contains(id))
        }
        lastSentButtons = buttons

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
        do {
            let core = try self.core ?? WiiUCore.shared()
            self.core = core
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
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)

            let surface = core.view
            let bootPath = Self.resolveBootPath(for: rom.url)

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
                core.surface(Unmanaged.passUnretained(surface).toOpaque(), width, height, scale)
                core.queue.async {
                    var failure: String?
                    do {
                        try core.prepare(root: root)
                        // Native Metal renderer (2 = Metal, 1 = Vulkan); recompiler falls back to interpreter without JIT.
                        core.setGraphicsAPI?(2)
                        core.setRecompiler?(true)
                        let status = bootPath.withCString(core.boot)
                        if status != 0 {
                            switch status {
                            case 3, 4, 9:
                                failure = "缺少此加密 Wii U 游戏的密钥。请点击右上角「导入 keys.txt」或将 keys.txt 放入 BIOS/wiiu 后重试。"
                            case 6:
                                failure = "选中的是更新或 DLC，请先导入并启动基础游戏。"
                            default:
                                failure = "Wii U 核心无法载入此游戏，错误码 " + String(status)
                            }
                        }
                    } catch {
                        failure = error.localizedDescription
                    }
                    DispatchQueue.main.async {
                        self.starting = false
                        self.error = failure
                        if failure == nil {
                            self.startGamepadPolling()
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
            self.error = error.localizedDescription
            starting = false
        }
    }

    private static func resolveBootPath(for url: URL) -> String {
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
        guard let core, launched, !closing else { return }
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
        let wasLaunched = launched
        core.queue.async {
            if wasLaunched { core.stop() }
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
    func updateUIView(_ view: UIView, context: Context) {
        view.setNeedsLayout()
    }
}

struct WiiUPlayer: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session = WiiUSession()
    @State private var importingKeys = false
    @State private var keysNotice: String?
    let rom: PhoneLibrary.ROM
    let library: PhoneLibrary

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Button("返回", systemImage: "xmark") { session.close { dismiss() } }
                    .foregroundStyle(.white)
                    .disabled(session.stopping)
                Spacer()
                Text(rom.title).foregroundStyle(.white).lineLimit(1)
                Spacer()
                Button("导入 keys.txt") { importingKeys = true }
                    .foregroundStyle(.white)
                    .disabled(session.stopping)
                Toggle("GamePad", isOn: Binding(get: { session.gamePad }, set: session.displayGamePad))
                    .toggleStyle(.button)
            }
            if let error = session.error {
                ContentUnavailableView {
                    Label("无法启动", systemImage: "exclamationmark.circle")
                } description: {
                    Text(error)
                } actions: {
                    Button("导入 keys.txt") { importingKeys = true }
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 12) {
                    VStack(spacing: 10) {
                        HStack(spacing: 6) {
                            padButton("L", 5)
                            padButton("ZL", 7)
                        }
                        TouchDPad { state in
                            session.setTouchButton(11, pressed: state.up)
                            session.setTouchButton(12, pressed: state.down)
                            session.setTouchButton(13, pressed: state.left)
                            session.setTouchButton(14, pressed: state.right)
                        }
                        .frame(width: 126, height: 126)
                        TouchAnalogStick(invertY: true) { x, y in
                            session.setTouchStick(0, x: x, y: y)
                        }
                        .frame(width: 78, height: 78)
                        padButton("−", 10)
                    }
                    if let core = session.core {
                        WiiUSurface(core: core)
                            .aspectRatio(16 / 9, contentMode: .fit)
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
                    VStack(spacing: 10) {
                        HStack(spacing: 6) {
                            padButton("ZR", 8)
                            padButton("R", 6)
                        }
                        TouchDiamondPad(labels: .init(top: "X", left: "Y", right: "A", bottom: "B")) { state in
                            session.setTouchButton(3, pressed: state.top)
                            session.setTouchButton(4, pressed: state.left)
                            session.setTouchButton(1, pressed: state.right)
                            session.setTouchButton(2, pressed: state.bottom)
                        }
                        .frame(width: 126, height: 126)
                        TouchAnalogStick(invertY: true) { x, y in
                            session.setTouchStick(1, x: x, y: y)
                        }
                        .frame(width: 78, height: 78)
                        padButton("+", 9)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    if session.starting || session.stopping {
                        ProgressView(session.stopping ? "正在退出" : "正在载入 Wii U 游戏")
                            .tint(.white)
                            .foregroundStyle(.white)
                    }
                }
            }
        }
        .padding(12)
        .background(Color.black.ignoresSafeArea())
        .task { session.start(rom: rom, library: library) }
        .interactiveDismissDisabled()
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in session.setPaused(true) }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in session.setPaused(false) }
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

    private func padButton(_ title: String, _ id: Int32) -> some View {
        TouchPadButton(title: title) { pressed in
            session.setTouchButton(id, pressed: pressed)
        }
        .frame(width: 58, height: 36)
    }
}
