import AVFoundation
import GameController
import SwiftUI
import UIKit
#if canImport(GameCenterSaveSupport)
import GameCenterSaveSupport
#endif

struct RetroPlayer: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session = RetroSession()
    @State private var showingPauseMenu = false
    @State private var hasController = !GCController.controllers().isEmpty
    @State private var showVirtualPad = GCController.controllers().isEmpty
    @AppStorage("phone.player.padOpacity") private var padOpacity = 0.86
    @AppStorage(TouchPadHaptics.defaultsKey) private var hapticsEnabled = true
    let rom: PhoneLibrary.ROM
    let library: PhoneLibrary

    private var isPlayStation: Bool { ["psp", "ps1", "ps2"].contains(rom.platform.id) }
    private var isTwoButton: Bool { ["gb", "gbc", "gba", "famicom"].contains(rom.platform.id) }
    private var hasShoulders: Bool { !["gb", "gbc", "famicom"].contains(rom.platform.id) }
    private var hasTriggers: Bool { ["ps1", "ps2", "wii"].contains(rom.platform.id) }
    private var hasLeftStick: Bool { ["threeDS", "psp", "ps1", "ps2", "wii", "n64"].contains(rom.platform.id) }
    private var hasRightStick: Bool { ["ps1", "ps2", "wii"].contains(rom.platform.id) }

    private var faceLabels: TouchDiamondPadUIView.Labels {
        if isPlayStation {
            return .init(top: "△", left: "□", right: "○", bottom: "×")
        }
        if isTwoButton {
            return .init(top: nil, left: nil, right: "A", bottom: "B")
        }
        return .init(top: "X", left: "Y", right: "A", bottom: "B")
    }

    var body: some View {
        GeometryReader { size in
            let wide = size.size.width > size.size.height
            let padSide: CGFloat = wide ? min(132, size.size.height * 0.42) : min(136, size.size.width * 0.36)

            ZStack {
                Color.black.ignoresSafeArea()

                if let error = session.error {
                    VStack(spacing: 16) {
                        ContentUnavailableView("无法启动", systemImage: "exclamationmark.circle", description: Text(error))
                            .foregroundStyle(.white)
                        Button("返回游戏库") { dismiss() }
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color(white: 0.06))
                            .padding(.horizontal, 22)
                            .frame(height: 42)
                            .background(Color(white: 0.94), in: Capsule())
                            .buttonStyle(.plain)
                    }
                    .padding(24)
                } else if wide {
                    ZStack {
                        screenArea
                            .ignoresSafeArea(edges: showVirtualPad ? [] : .all)

                        if showVirtualPad {
                            HStack {
                                leftControls(padSide: padSide)
                                Spacer()
                                rightControls(padSide: padSide)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .opacity(padOpacity)
                            .transition(.opacity)
                        }
                    }
                    .overlay(alignment: .top) {
                        PlayerFloatingPill(title: rom.title, hasController: hasController) {
                            openPauseMenu()
                        }
                        .padding(.top, 10)
                    }
                } else {
                    VStack(spacing: 0) {
                        HStack {
                            Spacer()
                            PlayerFloatingPill(title: rom.title, hasController: hasController) {
                                openPauseMenu()
                            }
                            Spacer()
                        }
                        .padding(.top, 6)
                        .padding(.bottom, 8)

                        screenArea
                            .padding(.horizontal, 10)
                            .padding(.bottom, 10)

                        if showVirtualPad {
                            VStack(spacing: 14) {
                                if hasShoulders {
                                    HStack {
                                        HStack(spacing: 8) {
                                            shoulderButton(isPlayStation ? "L1" : "L", bit: 10)
                                            if hasTriggers { shoulderButton("L2", bit: 12) }
                                        }
                                        Spacer()
                                        HStack(spacing: 8) {
                                            if hasTriggers { shoulderButton("R2", bit: 13) }
                                            shoulderButton(isPlayStation ? "R1" : "R", bit: 11)
                                        }
                                    }
                                }

                                HStack(alignment: .center) {
                                    TouchDPad { state in
                                        session.setButton(4, pressed: state.up)
                                        session.setButton(5, pressed: state.down)
                                        session.setButton(6, pressed: state.left)
                                        session.setButton(7, pressed: state.right)
                                    }
                                    .frame(width: padSide, height: padSide)

                                    Spacer()

                                    TouchDiamondPad(labels: faceLabels) { state in
                                        session.setButton(9, pressed: state.top)
                                        session.setButton(1, pressed: state.left)
                                        session.setButton(8, pressed: state.right)
                                        session.setButton(0, pressed: state.bottom)
                                    }
                                    .frame(width: padSide, height: padSide)
                                }

                                if hasLeftStick || hasRightStick {
                                    HStack {
                                        if hasLeftStick {
                                            TouchAnalogStick(invertY: false) { x, y in
                                                session.setAnalog(0, x: x, y: y)
                                            }
                                            .frame(width: 74, height: 74)
                                        }
                                        Spacer()
                                        if hasRightStick {
                                            TouchAnalogStick(invertY: false) { x, y in
                                                session.setAnalog(1, x: x, y: y)
                                            }
                                            .frame(width: 74, height: 74)
                                        }
                                    }
                                    .padding(.horizontal, 12)
                                }

                                HStack(spacing: 18) {
                                    TouchPadButton(title: "SELECT") { pressed in
                                        session.setButton(2, pressed: pressed)
                                    }
                                    .frame(width: 82, height: 34)

                                    TouchPadButton(title: "START") { pressed in
                                        session.setButton(3, pressed: pressed)
                                    }
                                    .frame(width: 82, height: 34)
                                }
                            }
                            .padding(.horizontal, 20)
                            .padding(.top, 14)
                            .padding(.bottom, 16)
                            .background(Color.white.opacity(0.03))
                            .overlay(alignment: .top) {
                                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
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
                                Text("点击顶部菜单可随时重新显示")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white.opacity(0.38))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 36)
                        }
                    }
                }

                if showingPauseMenu {
                    PlayerPauseOverlay(
                        title: rom.title,
                        hasController: hasController,
                        showVirtualPad: $showVirtualPad,
                        padOpacity: $padOpacity,
                        hapticsEnabled: $hapticsEnabled,
                        onResume: { closePauseMenu() },
                        onExit: { dismiss() }
                    )
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.18), value: showVirtualPad)
            .animation(.easeOut(duration: 0.16), value: showingPauseMenu)
        }
        .statusBarHidden(true)
        .task {
            syncControllerState()
            session.start(rom: rom, library: library)
        }
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
        .onDisappear { session.stop() }
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

    private var screenArea: some View {
        ZStack {
            RetroScreenView(view: session.screenView)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            if !session.hasFrame {
                ProgressView("正在读取游戏")
                    .tint(.white)
                    .foregroundStyle(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func leftControls(padSide: CGFloat) -> some View {
        VStack(spacing: 8) {
            if hasShoulders {
                HStack(spacing: 8) {
                    shoulderButton(isPlayStation ? "L1" : "L", bit: 10)
                    if hasTriggers { shoulderButton("L2", bit: 12) }
                }
            }
            Spacer(minLength: 0)
            TouchDPad { state in
                session.setButton(4, pressed: state.up)
                session.setButton(5, pressed: state.down)
                session.setButton(6, pressed: state.left)
                session.setButton(7, pressed: state.right)
            }
            .frame(width: padSide, height: padSide)

            if hasLeftStick {
                TouchAnalogStick(invertY: false) { x, y in
                    session.setAnalog(0, x: x, y: y)
                }
                .frame(width: 72, height: 72)
            }

            Spacer(minLength: 0)
            TouchPadButton(title: "Select") { pressed in
                session.setButton(2, pressed: pressed)
            }
            .frame(width: 76, height: 32)
        }
    }

    private func rightControls(padSide: CGFloat) -> some View {
        VStack(spacing: 8) {
            if hasShoulders {
                HStack(spacing: 8) {
                    if hasTriggers { shoulderButton("R2", bit: 13) }
                    shoulderButton(isPlayStation ? "R1" : "R", bit: 11)
                }
            }
            Spacer(minLength: 0)
            TouchDiamondPad(labels: faceLabels) { state in
                session.setButton(9, pressed: state.top)
                session.setButton(1, pressed: state.left)
                session.setButton(8, pressed: state.right)
                session.setButton(0, pressed: state.bottom)
            }
            .frame(width: padSide, height: padSide)

            if hasRightStick {
                TouchAnalogStick(invertY: false) { x, y in
                    session.setAnalog(1, x: x, y: y)
                }
                .frame(width: 72, height: 72)
            }

            Spacer(minLength: 0)
            TouchPadButton(title: "Start") { pressed in
                session.setButton(3, pressed: pressed)
            }
            .frame(width: 76, height: 32)
        }
    }

    private func shoulderButton(_ title: String, bit: UInt16) -> some View {
        TouchPadButton(title: title) { pressed in
            session.setButton(bit, pressed: pressed)
        }
        .frame(width: hasTriggers ? 56 : 82, height: 36)
    }
}

private final class RetroDisplayLinkProxy: NSObject {
    weak var target: RetroSession?
    init(target: RetroSession) { self.target = target }
    @objc func tick(_ link: CADisplayLink) {
        MainActor.assumeIsolated {
            target?.runFrame(link)
        }
    }
}

@MainActor
private final class RetroSession: NSObject, ObservableObject {
    private static let rgbColorSpace = CGColorSpaceCreateDeviceRGB()

    @Published var hasFrame = false
    @Published var error: String?
    let screenView = RetroScreenUIView()

    private let worker = RetroCoreWorker()
    private var heldButtons: UInt16 = 0
    private var latchFrames = [Int](repeating: 0, count: 16)
    private var axes: [Int16] = [0, 0, 0, 0]
    private var pointer: (Int16, Int16, Bool) = (0, 0, false)
    private var mirrorStickToDPad = false

    private var opened = false
    private var starting = false
    private var inFlight = false
    private var frameRate = 60.0
    private var generation = 0
    private var displayLink: CADisplayLink?
    private var lastFrame = 0.0
    private var nextFrame = 0.0
    private var audioEngine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var audioFormat: AVAudioFormat?
    private var audioFrames = 0
    private var audioGeneration = 0

    func start(rom: PhoneLibrary.ROM, library: PhoneLibrary) {
        guard !opened, !starting else { return }
        guard rom.platform.runtime == nil else {
            error = "此游戏需要通过对应的原生模拟器入口启动。"
            return
        }
        starting = true
        mirrorStickToDPad = ["gb", "gbc", "gba", "nds", "famicom", "superFamicom", "megaDrive"].contains(rom.platform.id)
        GCController.startWirelessControllerDiscovery(completionHandler: nil)
        screenView.onPointer = { [weak self] x, y, pressed in
            self?.setPointer(x: x, y: y, pressed: pressed)
        }

        if ["ps2", "wii", "threeDS", "psp"].contains(rom.platform.id) {
            let vaStatus = gc_s2arm_release_va_window()
            if vaStatus != 0 && rom.platform.id == "ps2" {
                starting = false
                error = "当前进程已运行过 Switch 游戏并占用虚拟地址空间，请重启 Game Center 后再启动 PS2 游戏。"
                return
            }
        }
        let name = String(rom.platform.module.dropLast(".dylib".count))
        let path = Bundle.main.bundleURL.appendingPathComponent("Frameworks/\(name).framework/\(name)")
        guard FileManager.default.fileExists(atPath: path.path) else {
            starting = false
            error = "该平台核心尚未随应用安装"
            return
        }

        let token = generation
        let worker = self.worker
        RetroCoreWorker.queue.async { [weak self] in
            let openResult: Result<(Double, Double), Error> = Result {
                let saves = library.saveFolder(rom)
                try FileManager.default.createDirectory(at: saves, withIntermediateDirectories: true)
                let bios = library.bios.appendingPathComponent(rom.platform.folder)
                try FileManager.default.createDirectory(at: bios, withIntermediateDirectories: true)
                // Ensure bundled BIOS / PPSSPP / Dolphin assets are fully copied before opening the core.
                library.seedSystemFiles(for: rom.platform)
                if rom.platform.id == "ps2" {
                    let profile = bios.appendingPathComponent("pcsx2")
                    for subdir in ["memcards", "sstates"] {
                        let old = profile.appendingPathComponent(subdir)
                        let target = library.root.appendingPathComponent("save/ps2/" + subdir)
                        try GameSaveLayout.migrate(old, to: target, saveRoot: library.root.appendingPathComponent("save"))
                        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                        if !FileManager.default.fileExists(atPath: old.path),
                           (try? FileManager.default.destinationOfSymbolicLink(atPath: old.path)) == nil {
                            try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
                            try FileManager.default.createSymbolicLink(at: old, withDestinationURL: target)
                        }
                    }
                }
                return try worker.open(module: path.path, rom: rom.url.path, bios: bios.path, saves: saves.path)
            }
            DispatchQueue.main.async {
                guard let self, self.generation == token else {
                    if case .success = openResult {
                        RetroCoreWorker.queue.async { worker.close() }
                    }
                    return
                }
                self.starting = false
                switch openResult {
                case let .success((fps, rate)):
                    self.opened = true
                    self.frameRate = fps
                    let proxy = RetroDisplayLinkProxy(target: self)
                    let link = CADisplayLink(target: proxy, selector: #selector(RetroDisplayLinkProxy.tick(_:)))
                    link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
                    link.add(to: .main, forMode: .common)
                    self.displayLink = link
                    self.startAudio(sampleRate: rate)
                case let .failure(err):
                    let instructions: [String: String] = [
                        "ps1": "应用已内置标准 PS1 BIOS（scph5500/5501/5502）；如仍无法启动，请检查光盘镜像（.cue/.bin/.chd/.pbp）是否完整。",
                        "ps2": "应用已内置 PS2 BIOS 并启用 Metal 渲染/解释器；如仍无法启动，请确认 ISO/CHD 文件完整。"
                    ]
                    self.error = instructions[rom.platform.id].map { err.localizedDescription + "\n" + $0 } ?? err.localizedDescription
                }
            }
        }
    }

    func setPaused(_ paused: Bool) {
        displayLink?.isPaused = paused
        if paused {
            let worker = worker
            RetroCoreWorker.queue.async { worker.save() }
            player?.pause()
            heldButtons = 0
            for i in 0..<16 { latchFrames[i] = 0 }
            axes = [0, 0, 0, 0]
            pointer = (0, 0, false)
        } else {
            nextFrame = 0
            if let engine = audioEngine, !engine.isRunning {
                do { try engine.start() } catch { return }
            }
            player?.play()
        }
    }

    func setButton(_ bit: UInt16, pressed: Bool) {
        let index = Int(bit)
        guard index >= 0 && index < 16 else { return }
        let mask: UInt16 = 1 << bit
        let wasPressed = (heldButtons & mask) != 0
        if pressed {
            heldButtons |= mask
            if !wasPressed {
                // Guarantee even brief taps survive slow software-rendered frames (3DS/PSP/PS2).
                latchFrames[index] = max(latchFrames[index], 2)
            }
        } else {
            heldButtons &= ~mask
        }
    }

    func setAnalog(_ index: Int, x: Float, y: Float) {
        guard index == 0 || index == 1 else { return }
        axes[index * 2] = Int16(min(32767, max(-32767, x * 32767)))
        axes[index * 2 + 1] = Int16(min(32767, max(-32767, y * 32767)))
    }

    func setPointer(x: CGFloat, y: CGFloat, pressed: Bool) {
        let px = Int16(min(32767, max(-32767, x * 65534 - 32767)))
        let py = Int16(min(32767, max(-32767, y * 65534 - 32767)))
        pointer = (px, py, pressed)
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        GCController.stopWirelessControllerDiscovery()
        player?.stop()
        audioEngine?.stop()
        audioGeneration += 1
        audioFrames = 0
        audioEngine = nil
        player = nil
        generation += 1
        starting = false
        opened = false
        screenView.onPointer = nil
        let worker = worker
        RetroCoreWorker.queue.async { worker.close() }
    }

    private func consumeInput(frames: Int) -> (buttons: UInt16, axes: [Int16], pointer: (Int16, Int16, Bool)) {
        var mask = heldButtons
        for i in 0..<16 where latchFrames[i] > 0 {
            mask |= (1 << UInt16(i))
            latchFrames[i] = max(0, latchFrames[i] - max(1, frames))
        }
        var currentAxes = axes
        let currentPointer = pointer

        if let pad = (GCController.current ?? GCController.controllers().first)?.extendedGamepad {
            let lx = pad.leftThumbstick.xAxis.value
            let ly = -pad.leftThumbstick.yAxis.value
            let rx = pad.rightThumbstick.xAxis.value
            let ry = -pad.rightThumbstick.yAxis.value
            if abs(lx) > 0.05 { currentAxes[0] = Int16(min(32767, max(-32767, lx * 32767))) }
            if abs(ly) > 0.05 { currentAxes[1] = Int16(min(32767, max(-32767, ly * 32767))) }
            if abs(rx) > 0.05 { currentAxes[2] = Int16(min(32767, max(-32767, rx * 32767))) }
            if abs(ry) > 0.05 { currentAxes[3] = Int16(min(32767, max(-32767, ry * 32767))) }
            mask |= controllerButtons(pad)
            if mirrorStickToDPad {
                if pad.leftThumbstick.yAxis.value > 0.45 { mask |= (1 << 4) }
                if pad.leftThumbstick.yAxis.value < -0.45 { mask |= (1 << 5) }
                if pad.leftThumbstick.xAxis.value < -0.45 { mask |= (1 << 6) }
                if pad.leftThumbstick.xAxis.value > 0.45 { mask |= (1 << 7) }
            }
        } else if let micro = (GCController.current ?? GCController.controllers().first)?.microGamepad {
            if micro.buttonA.isPressed { mask |= (1 << 0) }
            if micro.buttonX.isPressed { mask |= (1 << 8) }
            if micro.buttonMenu.isPressed { mask |= (1 << 3) }
            if micro.dpad.up.isPressed { mask |= (1 << 4) }
            if micro.dpad.down.isPressed { mask |= (1 << 5) }
            if micro.dpad.left.isPressed { mask |= (1 << 6) }
            if micro.dpad.right.isPressed { mask |= (1 << 7) }
        }
        return (mask, currentAxes, currentPointer)
    }

    func runFrame(_ link: CADisplayLink) {
        guard opened, !inFlight else { return }
        let duration = 1 / frameRate
        if nextFrame == 0 || link.timestamp - nextFrame > 0.15 { nextFrame = link.timestamp }
        if lastFrame == 0 { lastFrame = link.timestamp }
        var count = 0
        while nextFrame <= link.timestamp + 0.001, count < 4 {
            nextFrame += duration
            count += 1
        }
        guard count > 0 else { return }
        let save = link.timestamp - lastFrame > 10
        if save { lastFrame = link.timestamp }

        let snapshot = consumeInput(frames: count)
        let worker = worker
        let token = generation
        inFlight = true
        RetroCoreWorker.queue.async { [weak self] in
            let output = worker.step(
                count: count,
                buttons: snapshot.buttons,
                axes: snapshot.axes,
                pointer: snapshot.pointer,
                save: save
            )
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight = false
                guard self.opened, self.generation == token else { return }
                self.enqueueAudio(output.audio)
                guard let bytes = output.pixels, let provider = CGDataProvider(data: bytes as CFData) else { return }
                let bitmap = CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue))
                if let cgImage = CGImage(
                    width: output.width, height: output.height, bitsPerComponent: 8, bitsPerPixel: 32,
                    bytesPerRow: output.width * 4, space: Self.rgbColorSpace, bitmapInfo: bitmap,
                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
                ) {
                    self.screenView.update(image: cgImage)
                    if !self.hasFrame { self.hasFrame = true }
                }
            }
        }
    }

    private func controllerButtons(_ pad: GCExtendedGamepad) -> UInt16 {
        var flags: UInt16 = 0
        if pad.buttonA.isPressed { flags |= (1 << 0) }
        if pad.buttonX.isPressed { flags |= (1 << 1) }
        if pad.buttonOptions?.isPressed == true { flags |= (1 << 2) }
        if pad.buttonMenu.isPressed { flags |= (1 << 3) }
        if pad.dpad.up.isPressed { flags |= (1 << 4) }
        if pad.dpad.down.isPressed { flags |= (1 << 5) }
        if pad.dpad.left.isPressed { flags |= (1 << 6) }
        if pad.dpad.right.isPressed { flags |= (1 << 7) }
        if pad.buttonB.isPressed { flags |= (1 << 8) }
        if pad.buttonY.isPressed { flags |= (1 << 9) }
        if pad.leftShoulder.isPressed { flags |= (1 << 10) }
        if pad.rightShoulder.isPressed { flags |= (1 << 11) }
        if pad.leftTrigger.isPressed { flags |= (1 << 12) }
        if pad.rightTrigger.isPressed { flags |= (1 << 13) }
        if pad.leftThumbstickButton?.isPressed == true { flags |= (1 << 14) }
        if pad.rightThumbstickButton?.isPressed == true { flags |= (1 << 15) }
        return flags
    }

    private func startAudio(sampleRate: Double) {
        guard (8_000...192_000).contains(sampleRate),
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else { return }
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            try engine.start()
            node.play()
            audioEngine = engine
            player = node
            audioFormat = format
        } catch {
            engine.stop()
        }
    }

    private func enqueueAudio(_ samples: [Int16]) {
        let frames = samples.count / 2
        guard frames > 0, let player, let format = audioFormat, audioFrames < Int(format.sampleRate / 8),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channels = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames {
            channels[0][i] = Float(samples[i * 2]) / 32768
            channels[1][i] = Float(samples[i * 2 + 1]) / 32768
        }
        audioFrames += frames
        let generation = audioGeneration
        player.scheduleBuffer(buffer, completionCallbackType: .dataConsumed) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.audioGeneration == generation else { return }
                self.audioFrames -= frames
            }
        }
    }
}
