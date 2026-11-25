import AppKit
import CoreHostIPC
import SwiftUI

struct EmbeddedGameWindowView: View {
    @ObservedObject var session: CoreSessionController
    @Binding var autoPauseWhenInactive: Bool
    let onToggleFullscreen: () -> Void
    let onFallbackExternal: (() -> Void)?
    let onCloseWindow: () -> Void

    @State private var isHoveringTop = false
    @State private var isHoveringBar = false
    @State private var showSaveStates = false
    @State private var showCoreOptions = false
    @State private var showControlsGuide = false

    private var isPaused: Bool {
        if case .paused = session.status { return true }
        return false
    }

    private var shouldShowBar: Bool {
        isHoveringTop || isHoveringBar || isPaused || showSaveStates || showCoreOptions || showControlsGuide
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            MetalGameView(
                frameRing: session.frameRing,
                crispPixels: session.crispPixels,
                isPaused: isPaused,
                onPointerChange: { nx, ny, pressed in
                    session.inputCapture.updatePointer(normalizedX: nx, normalizedY: ny, pressed: pressed)
                },
                onMouseEvent: { buttons, dx, dy, wheelY in
                    session.inputCapture.updateMouse(buttonMask: buttons, deltaX: dx, deltaY: dy, wheelY: wheelY)
                },
                onMouseHoverTop: { hovering in
                    withAnimation(.easeInOut(duration: 0.16)) {
                        isHoveringTop = hovering
                    }
                }
            )
            .ignoresSafeArea()

            // Loading / Failure states
            switch session.status {
            case .starting:
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text("正在启动 \(session.game.displayTitle)…")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                    Text("\(session.descriptor.displayName) · 独立内置引擎")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .padding(24)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            case .failed(let message):
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.yellow)
                    Text("内置引擎启动异常")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.75))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                    HStack(spacing: 10) {
                        Button("重新启动") {
                            session.restartAfterFailure()
                        }
                        .buttonStyle(.borderedProminent)

                        if let onFallbackExternal {
                            Button("使用外部模拟器打开") {
                                onFallbackExternal()
                            }
                            .buttonStyle(.bordered)
                        }

                        Button("关闭窗口") {
                            onCloseWindow()
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(24)
                .background(Color.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.white.opacity(0.14), lineWidth: 1))

            case .paused:
                if !showSaveStates && !showCoreOptions && !showControlsGuide {
                    VStack(spacing: 12) {
                        Text("已暂停")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.white)
                        Text("按 Esc 或点击继续回到游戏")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.65))
                        HStack(spacing: 10) {
                            Button("继续游戏") { session.setPaused(false) }
                                .buttonStyle(.borderedProminent)
                            Button("即时存档") { showSaveStates = true }
                                .buttonStyle(.bordered)
                            Button("键位说明") { showControlsGuide = true }
                                .buttonStyle(.bordered)
                            Button("退出游戏") { onCloseWindow() }
                                .buttonStyle(.bordered)
                        }
                    }
                    .padding(22)
                    .background(Color.black.opacity(0.84), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.white.opacity(0.14), lineWidth: 1))
                }

            case .running:
                EmptyView()
            }

            // Top HUD bar
            VStack {
                if shouldShowBar {
                    topControlBar
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer()
                if let toast = session.statusToast {
                    Text(toast)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.8), in: Capsule())
                        .overlay(Capsule().stroke(.white.opacity(0.16), lineWidth: 1))
                        .padding(.bottom, 20)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.16), value: shouldShowBar)
            .animation(.easeInOut(duration: 0.16), value: session.statusToast)

            // Side drawers
            if showSaveStates {
                drawerContainer(title: "即时存档", onClose: { showSaveStates = false }) {
                    saveStatesDrawer
                }
            } else if showCoreOptions {
                drawerContainer(title: "\(session.descriptor.displayName) 核心选项", onClose: { showCoreOptions = false }) {
                    coreOptionsDrawer
                }
            } else if showControlsGuide {
                drawerContainer(title: "键盘 / 鼠标 / 手柄操作", onClose: { showControlsGuide = false }) {
                    controlsGuideDrawer
                }
            }
        }
        .preferredColorScheme(.dark)
        .frame(minWidth: 640, minHeight: 480)
    }

    private var topControlBar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(session.game.displayTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("\(session.game.platform.shortTitle) · \(session.descriptor.displayName)")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.6))
            }

            Spacer(minLength: 12)

            hudButton(icon: isPaused ? "play.fill" : "pause.fill", help: isPaused ? "继续 (Esc)" : "暂停 (Esc)") {
                session.togglePause()
            }

            hudButton(icon: "forward.fill", help: "快进 (按住 Space)", active: session.fastForward) {
                session.setFastForward(!session.fastForward)
            }

            hudButton(icon: "square.and.arrow.down.on.square", help: "即时存档 (⌘S / ⌘L)", active: showSaveStates) {
                showCoreOptions = false
                showControlsGuide = false
                showSaveStates.toggle()
            }

            hudButton(icon: session.crispPixels ? "square.grid.3x3.fill" : "sparkles", help: session.crispPixels ? "画面：像素锐化" : "画面：双线性平滑") {
                session.crispPixels.toggle()
            }

            if session.descriptor.isDualScreen {
                hudButton(icon: "rectangle.split.2x1", help: "切换双屏布局（上下/左右/主屏放大/单屏）") {
                    session.cycleDualScreenLayout()
                }
            }

            hudButton(icon: session.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", help: session.isMuted ? "取消静音" : "静音") {
                session.updateAudio(muted: !session.isMuted)
            }

            Slider(
                value: Binding(
                    get: { Double(session.volume) },
                    set: { session.updateAudio(volume: Float($0), muted: false) }
                ),
                in: 0...1
            )
            .frame(width: 72)

            hudButton(icon: "slider.horizontal.3", help: "核心选项", active: showCoreOptions) {
                showSaveStates = false
                showControlsGuide = false
                showCoreOptions.toggle()
            }

            hudButton(icon: "keyboard", help: "键位与鼠键说明", active: showControlsGuide) {
                showSaveStates = false
                showCoreOptions = false
                showControlsGuide.toggle()
            }

            hudButton(icon: autoPauseWhenInactive ? "pause.circle.fill" : "pause.circle", help: autoPauseWhenInactive ? "失焦自动暂停：开" : "失焦自动暂停：关", active: autoPauseWhenInactive) {
                autoPauseWhenInactive.toggle()
            }

            hudButton(icon: "arrow.counterclockwise", help: "重启游戏") {
                session.resetGame()
            }

            hudButton(icon: "arrow.up.left.and.arrow.down.right", help: "全屏 (⌘F)") {
                onToggleFullscreen()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white.opacity(0.14), lineWidth: 1))
        .padding(.horizontal, 16)
        .padding(.top, 36)
        .onHover { hovering in
            isHoveringBar = hovering
        }
    }

    private func hudButton(icon: String, help: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(active ? .black : .white)
                .frame(width: 28, height: 28)
                .background(active ? GameCenterColors.action : Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func drawerContainer<Content: View>(title: String, onClose: @escaping () -> Void, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Spacer()
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    Button {
                        onClose()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white.opacity(0.8))
                            .frame(width: 24, height: 24)
                            .background(.white.opacity(0.1), in: Circle())
                    }
                    .buttonStyle(.plain)
                }
                Divider()
                ScrollView {
                    content()
                }
            }
            .padding(16)
            .frame(width: 340)
            .frame(maxHeight: .infinity)
            .background(Color.black.opacity(0.92))
            .overlay(Rectangle().frame(width: 1).foregroundStyle(.white.opacity(0.12)), alignment: .leading)
            .padding(.top, 84)
        }
    }

    private var saveStatesDrawer: some View {
        VStack(spacing: 10) {
            ForEach(session.saveSlots) { slot in
                HStack(spacing: 10) {
                    Group {
                        if slot.exists, let nsImage = NSImage(contentsOf: slot.thumbnailURL) {
                            Image(nsImage: nsImage)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else {
                            ZStack {
                                Color.white.opacity(0.06)
                                Image(systemName: "photo")
                                    .foregroundStyle(.white.opacity(0.3))
                            }
                        }
                    }
                    .frame(width: 72, height: 50)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                    VStack(alignment: .leading, spacing: 3) {
                        Text("槽位 \(slot.slot)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                        if let date = slot.modifiedAt {
                            Text(date.formatted(date: .abbreviated, time: .shortened))
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.6))
                        } else {
                            Text("空槽位")
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                        HStack(spacing: 6) {
                            Button("保存") { session.saveState(slot: slot.slot) }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            Button("读取") { session.loadState(slot: slot.slot) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(!slot.exists)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(8)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
        }
    }

    private var coreOptionsDrawer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if session.coreOptions.isEmpty {
                Text("当前核心未声明可调选项。")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
            } else {
                ForEach(session.coreOptions.filter { !$0.choices.isEmpty }) { option in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(option.description)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                        Picker("", selection: Binding(
                            get: { option.currentValue },
                            set: { session.setCoreOption(key: option.key, value: $0) }
                        )) {
                            ForEach(option.choices, id: \.value) { choice in
                                Text(choice.label).tag(choice.value)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
    }

    private var controlsGuideDrawer: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(GameInputCapture.defaultHints) { hint in
                VStack(alignment: .leading, spacing: 3) {
                    Text(hint.action)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                    HStack {
                        Text("键盘：\(hint.keyboard)")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.75))
                        Spacer()
                    }
                    Text("手柄：\(hint.gamepad)")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }
}
