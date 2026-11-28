import AVFoundation
import GameController
import MetalKit
import QuartzCore
import SwiftUI
import UIKit
#if canImport(GameCenterSaveSupport)
import GameCenterSaveSupport
#endif

// MARK: - Citra.framework Virtual Input Constants (Manic EMU)

extension GCThreeDSBridge: @unchecked Sendable {}

private enum CitraButton: UInt {
    case a = 700
    case b = 701
    case x = 702
    case y = 703
    case start = 704
    case select = 705
    case home = 706
    case zl = 707
    case zr = 708
    case up = 709
    case down = 710
    case left = 711
    case right = 712
    case l = 773
    case r = 774
}

private enum CitraAnalog: UInt {
    case circlePad = 713
    case cStick = 718
}

// MARK: - Metal View Host with Direct Touch Forwarding

final class ThreeDSMetalUIView: MTKView {
    var onLayoutChange: ((CGSize, CGFloat) -> Void)?
    var onTouchBegan: ((CGPoint) -> Void)?
    var onTouchMoved: ((CGPoint) -> Void)?
    var onTouchEnded: (() -> Void)?

    private var activeTouch: UITouch?
    private var lastSize: CGSize = .zero
    private var lastScale: CGFloat = 0

    init() {
        super.init(frame: .zero, device: MTLCreateSystemDefaultDevice())
        backgroundColor = .black
        isPaused = true
        enableSetNeedsDisplay = false
        isMultipleTouchEnabled = false
        colorPixelFormat = .bgra8Unorm
    }

    required init(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.screen.scale ?? traitCollection.displayScale
        contentScaleFactor = scale
        if bounds.width > 1 && bounds.height > 1 && (bounds.size != lastSize || scale != lastScale) {
            lastSize = bounds.size
            lastScale = scale
            onLayoutChange?(bounds.size, scale)
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard activeTouch == nil, let touch = touches.first else { return }
        activeTouch = touch
        onTouchBegan?(touch.location(in: self))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let activeTouch, touches.contains(activeTouch) else { return }
        onTouchMoved?(activeTouch.location(in: self))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let activeTouch, touches.contains(activeTouch) else { return }
        self.activeTouch = nil
        onTouchEnded?()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let activeTouch, touches.contains(activeTouch) else { return }
        self.activeTouch = nil
        onTouchEnded?()
    }
}

private struct ThreeDSMetalView: UIViewRepresentable {
    let view: ThreeDSMetalUIView
    func makeUIView(context: Context) -> ThreeDSMetalUIView { view }
    func updateUIView(_ uiView: ThreeDSMetalUIView, context: Context) {}
}

// MARK: - DisplayLink Proxy for Physical Gamepad Polling

private final class ThreeDSDisplayLinkProxy: NSObject {
    weak var target: ThreeDSSession?
    init(target: ThreeDSSession) { self.target = target }
    @objc func tick() {
        MainActor.assumeIsolated {
            target?.pollGamepad()
        }
    }
}

// MARK: - 3DS Session Powered by Manic EMU's Citra.framework

@MainActor
private final class ThreeDSSession: NSObject, ObservableObject {
    @Published var error: String?
    @Published var starting = true
    @Published var stopping = false
    @Published var jitAvailable = gc_ios_jit_available()

    let metalView = ThreeDSMetalUIView()
    private var citraCore: GCThreeDSBridge?
    private var booted = false
    private var closing = false
    private var layoutTimer: DispatchWorkItem?
    private var displayLink: CADisplayLink?
    private var connectObserver: NSObjectProtocol?
    private var disconnectObserver: NSObjectProtocol?

    private var touchButtonsMask: UInt32 = 0
    private var lastButtonsMask: UInt32 = 0
    private var touchCirclePad: (Float, Float) = (0, 0)
    private var touchCStick: (Float, Float) = (0, 0)
    private var lastCirclePad: (Float, Float) = (0, 0)
    private var lastCStick: (Float, Float) = (0, 0)
    private var topRectPixels: CGRect = .zero
    private var bottomRectPixels: CGRect = .zero

    static var isAvailable: Bool {
        GCThreeDSBridge.isFrameworkAvailable()
    }

    private static func loadCore() throws -> GCThreeDSBridge {
        try GCThreeDSBridge.loadCore()
    }

    /// Bridges Citra's `/Documents/3DS/sdmc` and `/Documents/3DS/nand` into Game Center's
    /// canonical `Documents/GameLibrary/save/3ds` folder for seamless iCloud Save Sync.
    private static func prepareSaveDirectories(library: PhoneLibrary) throws {
        let fm = FileManager.default
        let citraRoot = library.documents.appendingPathComponent("3DS", isDirectory: true)
        let saveRoot = library.root.appendingPathComponent("save", isDirectory: true)
        let canonical = GameSaveLayout.folder(root: library.root, platform: "threeDS")
        try fm.createDirectory(at: citraRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: canonical, withIntermediateDirectories: true)
        for sub in ["sdmc", "nand"] {
            let legacy = citraRoot.appendingPathComponent(sub, isDirectory: true)
            let target = canonical.appendingPathComponent(sub, isDirectory: true)
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            try GameSaveLayout.migrate(legacy, to: target, saveRoot: saveRoot)
            if (try? fm.destinationOfSymbolicLink(atPath: legacy.path)) == nil {
                try GameSaveLayout.createAlias(at: legacy, to: target)
            }
        }
        for aux in ["shaders", "sysdata", "cheats", "states"] {
            try fm.createDirectory(at: citraRoot.appendingPathComponent(aux, isDirectory: true), withIntermediateDirectories: true)
        }
    }

    func applySettings(performanceMode: Int, resolutionFactor: Int) {
        let jit = gc_ios_jit_available()
        jitAvailable = jit
        let clock: Int
        if jit {
            clock = performanceMode == 0 ? 50 : (performanceMode == 1 ? 60 : 75)
        } else {
            // Exact Manic EMU JIT-less clock targets for smooth frame pacing without JIT.
            clock = performanceMode == 0 ? 15 : (performanceMode == 1 ? 20 : 25)
        }
        let defaults = UserDefaults.standard
        // Citra converts this optional service URL to std::string even for offline games.
        defaults.register(defaults: ["ManicEMU.webAPIURL": ""])
        let settings: [String: Any] = [
            "ManicEMU.cpuJIT": jit,
            "ManicEMU.cpuClockPercentage": clock,
            "ManicEMU.new3DS": performanceMode == 2,
            "ManicEMU.lleApplets": false,
            "ManicEMU.regionValue": -1,
            "ManicEMU.layoutOption": 0,
            "ManicEMU.customLayout": false,
            "ManicEMU.spirvShaderGeneration": true,
            "ManicEMU.useAsyncShaderCompilation": false,
            "ManicEMU.useAsyncPresentation": false,
            "ManicEMU.useHardwareShaders": true,
            "ManicEMU.useDiskShaderCache": true,
            "ManicEMU.useShadersAccurateMul": false,
            "ManicEMU.useNewVSync": true,
            "ManicEMU.useShaderJIT": jit,
            "ManicEMU.resolutionFactor": max(1, min(3, resolutionFactor)),
            "ManicEMU.textureFilter": 0,
            "ManicEMU.textureSampling": 0,
            "ManicEMU.render3D": 0,
            "ManicEMU.factor3D": 0,
            "ManicEMU.monoRender": 0,
            "ManicEMU.disableRightEyeRender": true,
            "ManicEMU.preloadTextures": false,
            "ManicEMU.audioMuted": false,
            "ManicEMU.audioEmulation": 0, // HLE
            "ManicEMU.audioStretching": false,
            "ManicEMU.realtimeAudio": true,
            "ManicEMU.outputType": 3, // OpenAL
            "ManicEMU.inputType": 4,
            "ManicEMU.logLevel": 6
        ]
        for (key, value) in settings {
            defaults.set(value, forKey: key)
        }
        writeCustomLayout(defaults: defaults)
        defaults.synchronize()
        if booted, let core = citraCore, core.running() {
            core.updateSettings(withAdvancedMode: false)
        }
    }

    private func computeDualScreenLayout(size: CGSize, scale: CGFloat) {
        let w = size.width * scale
        let h = size.height * scale
        guard w > 1, h > 1 else { return }
        let isLandscape = w > h
        if isLandscape {
            // 3DS Landscape: large 5:3 top screen on left (72% width), 4:3 bottom touch screen on right.
            let gap = round(min(w, h) * 0.015)
            let topMaxW = (w - gap) * 0.68
            let topH = min(h, topMaxW * (240.0 / 400.0))
            let topW = topH * (400.0 / 240.0)
            let botMaxW = w - topW - gap
            let botW = min(botMaxW, h * (320.0 / 240.0))
            let botH = botW * (240.0 / 320.0)
            let totalW = topW + gap + botW
            let originX = (w - totalW) * 0.5
            topRectPixels = CGRect(x: originX, y: (h - topH) * 0.5, width: topW, height: topH)
            bottomRectPixels = CGRect(x: originX + topW + gap, y: (h - botH) * 0.5, width: botW, height: botH)
        } else {
            // 3DS Portrait: 5:3 top screen stacked cleanly above 4:3 bottom touch screen.
            let gap = round(h * 0.012)
            let combinedAspect = (240.0 / 400.0) + (240.0 / 320.0) * 0.80 // bottom screen 80% of top width
            let topW = min(w, (h - gap) / combinedAspect)
            let topH = topW * (240.0 / 400.0)
            let botW = topW * 0.80
            let botH = botW * (240.0 / 320.0)
            let totalH = topH + gap + botH
            let originY = (h - totalH) * 0.5
            topRectPixels = CGRect(x: (w - topW) * 0.5, y: originY, width: topW, height: topH)
            bottomRectPixels = CGRect(x: (w - botW) * 0.5, y: originY + topH + gap, width: botW, height: botH)
        }
    }

    private func writeCustomLayout(defaults: UserDefaults = .standard) {
        guard topRectPixels.width > 1, bottomRectPixels.width > 1 else { return }
        defaults.set(Double(topRectPixels.minX), forKey: "ManicEMU.customTopLeft")
        defaults.set(Double(topRectPixels.minY), forKey: "ManicEMU.customTopTop")
        defaults.set(Double(topRectPixels.maxX), forKey: "ManicEMU.customTopRight")
        defaults.set(Double(topRectPixels.maxY), forKey: "ManicEMU.customTopBottom")
        defaults.set(Double(bottomRectPixels.minX), forKey: "ManicEMU.customBottomLeft")
        defaults.set(Double(bottomRectPixels.minY), forKey: "ManicEMU.customBottomTop")
        defaults.set(Double(bottomRectPixels.maxX), forKey: "ManicEMU.customBottomRight")
        defaults.set(Double(bottomRectPixels.maxY), forKey: "ManicEMU.customBottomBottom")
    }

    private func currentOrientation() -> UIInterfaceOrientation {
        metalView.window?.windowScene?.effectiveGeometry.interfaceOrientation
            ?? (metalView.bounds.width > metalView.bounds.height ? .landscapeRight : .portrait)
    }

    private func motionRotation(for orientation: UIInterfaceOrientation) -> Int {
        switch orientation {
        case .portrait: 0
        case .landscapeLeft: 1
        case .portraitUpsideDown: 2
        default: 3
        }
    }

    func start(rom: PhoneLibrary.ROM, library: PhoneLibrary, performanceMode: Int, resolutionFactor: Int) {
        guard !booted, !closing else { return }
        error = nil
        starting = true
        _ = gc_s2arm_release_va_window()

        do {
            try Self.prepareSaveDirectories(library: library)
            let core = try Self.loadCore()
            self.citraCore = core
            try AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)

            metalView.onTouchBegan = { [weak self] point in
                self?.citraCore?.touchBegan(at: point)
            }
            metalView.onTouchMoved = { [weak self] point in
                self?.citraCore?.touchMoved(at: point)
            }
            metalView.onTouchEnded = { [weak self] in
                self?.citraCore?.touchEnded()
            }

            let romURL = rom.url
            let handleLayout: (CGSize, CGFloat) -> Void = { [weak self] size, scale in
                guard let self, !self.closing, let core = self.citraCore else { return }
                self.computeDualScreenLayout(size: size, scale: scale)
                self.writeCustomLayout()
                let orientation = self.currentOrientation()
                core.setMotionRotation(self.motionRotation(for: orientation))

                if !self.booted {
                    self.applySettings(performanceMode: performanceMode, resolutionFactor: resolutionFactor)
                    self.booted = true
                    core.allocateVulkanLibrary()
                    if let metalLayer = self.metalView.layer as? CAMetalLayer {
                        core.allocateMetalLayer(metalLayer, size: size, isSecondary: false)
                    }
                    let jit = self.jitAvailable
                    Thread.detachNewThread {
                        Thread.setThreadPriority(1.0)
                        core.insertCartridgeAndBoot(with: romURL, advancedMode: false, jitSupport: jit)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                        guard let self, !self.closing else { return }
                        self.starting = false
                        self.startGamepadPolling()
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
                        guard let self, !self.closing else { return }
                        core.orientationChange(self.currentOrientation(), metalView: self.metalView)
                    }
                } else {
                    self.layoutTimer?.cancel()
                    let work = DispatchWorkItem { [weak self] in
                        guard let self, !self.closing, core.running() else { return }
                        core.updateSettings(withAdvancedMode: false)
                        core.orientationChange(self.currentOrientation(), metalView: self.metalView)
                    }
                    self.layoutTimer = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
                }
            }

            metalView.onLayoutChange = handleLayout
            if metalView.bounds.width > 1 && metalView.bounds.height > 1 {
                handleLayout(metalView.bounds.size, metalView.contentScaleFactor)
            } else {
                metalView.setNeedsLayout()
            }
        } catch {
            self.error = error.localizedDescription
            self.starting = false
        }
    }

    func setPaused(_ paused: Bool) {
        guard let core = citraCore, booted, !closing else { return }
        if !core.stopped() {
            core.pausePlay(!paused)
        }
    }

    func close(completion: @escaping () -> Void) {
        guard !closing else { return }
        closing = true
        stopping = true
        layoutTimer?.cancel()
        layoutTimer = nil
        stopGamepadPolling()
        metalView.onLayoutChange = nil
        metalView.onTouchBegan = nil
        metalView.onTouchMoved = nil
        metalView.onTouchEnded = nil
        guard let core = citraCore else {
            stopping = false
            completion()
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            if !core.stopped() {
                core.stop()
            }
            DispatchQueue.main.async {
                core.deallocateMetalLayers()
                core.deallocateVulkanLibrary()
                self.booted = false
                self.stopping = false
                completion()
            }
        }
    }

    // MARK: - Virtual & Physical Input

    func setTouchButton(_ bit: Int, pressed: Bool) {
        let mask: UInt32 = 1 << UInt32(bit)
        if pressed { touchButtonsMask |= mask } else { touchButtonsMask &= ~mask }
        pollGamepad()
    }

    func setTouchCirclePad(x: Float, y: Float) {
        touchCirclePad = (x, y)
        pollGamepad()
    }

    func setTouchCStick(x: Float, y: Float) {
        touchCStick = (x, y)
        pollGamepad()
    }

    private func startGamepadPolling() {
        guard connectObserver == nil else { return }
        GCController.startWirelessControllerDiscovery(completionHandler: nil)
        connectObserver = NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateDisplayLink() }
        }
        disconnectObserver = NotificationCenter.default.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateDisplayLink() }
        }
        updateDisplayLink()
    }

    private func updateDisplayLink() {
        let hasController = !GCController.controllers().isEmpty
        if hasController && !closing && booted {
            if displayLink == nil {
                let proxy = ThreeDSDisplayLinkProxy(target: self)
                let link = CADisplayLink(target: proxy, selector: #selector(ThreeDSDisplayLinkProxy.tick))
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
    }

    private static let buttonMap: [(bit: Int, citra: CitraButton)] = [
        (0, .b), (1, .y), (2, .select), (3, .start),
        (4, .up), (5, .down), (6, .left), (7, .right),
        (8, .a), (9, .x), (10, .l), (11, .r), (12, .zl), (13, .zr)
    ]

    func pollGamepad() {
        guard let core = citraCore, booted, !closing else { return }
        var buttons = touchButtonsMask
        var circle = touchCirclePad
        var cstick = touchCStick

        if let pad = (GCController.current ?? GCController.controllers().first)?.extendedGamepad {
            // Nintendo layout: South(A)->B(0), East(B)->A(8), West(X)->Y(1), North(Y)->X(9)
            if pad.buttonA.isPressed { buttons |= (1 << 0) }
            if pad.buttonX.isPressed { buttons |= (1 << 1) }
            if pad.buttonOptions?.isPressed == true { buttons |= (1 << 2) }
            if pad.buttonMenu.isPressed { buttons |= (1 << 3) }
            if pad.dpad.up.isPressed { buttons |= (1 << 4) }
            if pad.dpad.down.isPressed { buttons |= (1 << 5) }
            if pad.dpad.left.isPressed { buttons |= (1 << 6) }
            if pad.dpad.right.isPressed { buttons |= (1 << 7) }
            if pad.buttonB.isPressed { buttons |= (1 << 8) }
            if pad.buttonY.isPressed { buttons |= (1 << 9) }
            if pad.leftShoulder.isPressed { buttons |= (1 << 10) }
            if pad.rightShoulder.isPressed { buttons |= (1 << 11) }
            if pad.leftTrigger.value > 0.25 { buttons |= (1 << 12) }
            if pad.rightTrigger.value > 0.25 { buttons |= (1 << 13) }

            let lx = pad.leftThumbstick.xAxis.value
            let ly = pad.leftThumbstick.yAxis.value
            if abs(lx) > 0.05 || abs(ly) > 0.05 { circle = (lx, ly) }
            let rx = pad.rightThumbstick.xAxis.value
            let ry = pad.rightThumbstick.yAxis.value
            if abs(rx) > 0.05 || abs(ry) > 0.05 { cstick = (rx, ry) }
        }

        let changed = buttons ^ lastButtonsMask
        if changed != 0 {
            for entry in Self.buttonMap {
                let bitMask: UInt32 = 1 << UInt32(entry.bit)
                if (changed & bitMask) != 0 {
                    if (buttons & bitMask) != 0 {
                        core.virtualControllerButtonDown(entry.citra.rawValue)
                    } else {
                        core.virtualControllerButtonUp(entry.citra.rawValue)
                    }
                }
            }
            lastButtonsMask = buttons
        }

        if circle != lastCirclePad {
            core.thumbstickMoved(CitraAnalog.circlePad.rawValue, x: circle.0, y: circle.1)
            lastCirclePad = circle
        }
        if cstick != lastCStick {
            core.thumbstickMoved(CitraAnalog.cStick.rawValue, x: cstick.0, y: cstick.1)
            lastCStick = cstick
        }
    }

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}

// MARK: - SwiftUI 3DS Player View

struct ThreeDSPlayer: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session = ThreeDSSession()
    @State private var showingPauseMenu = false
    @State private var hasController = !GCController.controllers().isEmpty
    @State private var showVirtualPad = GCController.controllers().isEmpty
    @AppStorage("phone.player.padOpacity") private var padOpacity = 0.86
    @AppStorage(TouchPadHaptics.defaultsKey) private var hapticsEnabled = true
    @AppStorage("phone.player.3ds.performanceMode") private var performanceMode = 0
    @AppStorage("phone.player.3ds.resolution") private var resolutionFactor = 1

    let rom: PhoneLibrary.ROM
    let library: PhoneLibrary

    static var isCoreInstalled: Bool { ThreeDSSession.isAvailable }

    var body: some View {
        FullScreenReader { fullSize, safeInsets in
            let wide = fullSize.width > fullSize.height
            let padSide: CGFloat = wide ? min(124, fullSize.height * 0.38) : min(128, fullSize.width * 0.34)

            ZStack {
                Color.black

                if let error = session.error {
                    VStack(spacing: 16) {
                        ContentUnavailableView("无法启动 3DS", systemImage: "exclamationmark.circle", description: Text(error))
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
                            .padding(.bottom, 6)
                        }

                        ThreeDSMetalView(view: session.metalView)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                        if !wide {
                            if showVirtualPad {
                                VStack(spacing: 10) {
                                    HStack {
                                        HStack(spacing: 6) {
                                            shoulder("L", bit: 10)
                                            shoulder("ZL", bit: 12)
                                        }
                                        Spacer()
                                        HStack(spacing: 6) {
                                            shoulder("ZR", bit: 13)
                                            shoulder("R", bit: 11)
                                        }
                                    }

                                    HStack(alignment: .center) {
                                        TouchAnalogStick(invertY: true) { x, y in
                                            session.setTouchCirclePad(x: x, y: y)
                                        }
                                        .frame(width: 82, height: 82)

                                        TouchDPad { state in
                                            session.setTouchButton(4, pressed: state.up)
                                            session.setTouchButton(5, pressed: state.down)
                                            session.setTouchButton(6, pressed: state.left)
                                            session.setTouchButton(7, pressed: state.right)
                                        }
                                        .frame(width: 88, height: 88)

                                        Spacer(minLength: 8)

                                        TouchDiamondPad(labels: .init(top: "X", left: "Y", right: "A", bottom: "B")) { state in
                                            session.setTouchButton(9, pressed: state.top)
                                            session.setTouchButton(1, pressed: state.left)
                                            session.setTouchButton(8, pressed: state.right)
                                            session.setTouchButton(0, pressed: state.bottom)
                                        }
                                        .frame(width: padSide, height: padSide)
                                    }

                                    HStack(spacing: 18) {
                                        TouchPadButton(title: "SELECT") { session.setTouchButton(2, pressed: $0) }
                                            .frame(width: 82, height: 32)
                                        TouchPadButton(title: "START") { session.setTouchButton(3, pressed: $0) }
                                            .frame(width: 82, height: 32)
                                    }
                                }
                                .padding(.horizontal, max(max(safeInsets.leading, safeInsets.trailing), 16))
                                .padding(.top, 10)
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
                                .padding(.top, 20)
                                .padding(.bottom, max(safeInsets.bottom, 20) + 6)
                            }
                        }
                    }
                    .overlay {
                        if wide && showVirtualPad {
                            HStack {
                                VStack(spacing: 8) {
                                    HStack(spacing: 6) {
                                        shoulder("L", bit: 10)
                                        shoulder("ZL", bit: 12)
                                    }
                                    Spacer(minLength: 0)
                                    TouchAnalogStick(invertY: true) { x, y in
                                        session.setTouchCirclePad(x: x, y: y)
                                    }
                                    .frame(width: 78, height: 78)
                                    TouchDPad { state in
                                        session.setTouchButton(4, pressed: state.up)
                                        session.setTouchButton(5, pressed: state.down)
                                        session.setTouchButton(6, pressed: state.left)
                                        session.setTouchButton(7, pressed: state.right)
                                    }
                                    .frame(width: min(padSide, 104), height: min(padSide, 104))
                                    Spacer(minLength: 0)
                                    TouchPadButton(title: "Select") { session.setTouchButton(2, pressed: $0) }
                                        .frame(width: 74, height: 30)
                                }
                                Spacer()
                                VStack(spacing: 8) {
                                    HStack(spacing: 6) {
                                        shoulder("ZR", bit: 13)
                                        shoulder("R", bit: 11)
                                    }
                                    Spacer(minLength: 0)
                                    TouchDiamondPad(labels: .init(top: "X", left: "Y", right: "A", bottom: "B")) { state in
                                        session.setTouchButton(9, pressed: state.top)
                                        session.setTouchButton(1, pressed: state.left)
                                        session.setTouchButton(8, pressed: state.right)
                                        session.setTouchButton(0, pressed: state.bottom)
                                    }
                                    .frame(width: padSide, height: padSide)
                                    Spacer(minLength: 0)
                                    TouchPadButton(title: "Start") { session.setTouchButton(3, pressed: $0) }
                                        .frame(width: 74, height: 30)
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
                        Text(session.stopping ? "正在保存并退出…" : "正在启动 Manic EMU 3DS 核心…")
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
                        subtitle: session.jitAvailable ? "3DS · Manic EMU (JIT 已开启)" : "3DS · Manic EMU (Metal/Vulkan 硬件加速)",
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
                        VStack(alignment: .leading, spacing: 6) {
                            Text("性能模式（无 JIT 推荐流畅）")
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
                            Text("渲染分辨率")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.68))
                            Picker("分辨率", selection: $resolutionFactor) {
                                Text("1x 原生").tag(1)
                                Text("2x 高清").tag(2)
                            }
                            .pickerStyle(.segmented)
                        }
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
            session.start(rom: rom, library: library, performanceMode: performanceMode, resolutionFactor: resolutionFactor)
        }
        .onChange(of: performanceMode) { _, mode in
            session.applySettings(performanceMode: mode, resolutionFactor: resolutionFactor)
        }
        .onChange(of: resolutionFactor) { _, res in
            session.applySettings(performanceMode: performanceMode, resolutionFactor: res)
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in syncControllerState() }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) { _ in syncControllerState() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in session.setPaused(true) }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            if !showingPauseMenu { session.setPaused(false) }
        }
        .onDisappear { session.close {} }
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

    private func shoulder(_ title: String, bit: Int) -> some View {
        TouchPadButton(title: title) { session.setTouchButton(bit, pressed: $0) }
            .frame(width: 54, height: 32)
    }
}
