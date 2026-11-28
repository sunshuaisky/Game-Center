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
    @State private var showMoreMenu = false

    private var isPaused: Bool {
        if case .paused = session.status { return true }
        return false
    }

    private var shouldShowBar: Bool {
        isHoveringTop || isHoveringBar || isPaused || showSaveStates || showCoreOptions || showControlsGuide || showMoreMenu
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            MetalGameView(
                frameRing: session.frameRing,
                crispPixels: session.crispPixels,
                isPaused: isPaused,
                onPointerAndMouse: { pointer, buttons, dx, dy, wheelY in
                    session.inputCapture.updatePointerAndMouse(
                        pointer: pointer,
                        buttonMask: buttons,
                        deltaX: dx,
                        deltaY: dy,
                        wheelY: wheelY
                    )
                },
                onMouseHoverTop: { hovering in
                    withAnimation(.easeInOut(duration: 0.16)) {
                        isHoveringTop = hovering
                    }
                }
            )
            .ignoresSafeArea()

            // Loading / Failure / Pause overlays
            switch session.status {
            case .starting:
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                    Text("正在启动 \(session.game.displayTitle)…")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                    Text("\(session.descriptor.displayName) · 独立内置引擎")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .padding(24)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 1))

            case .failed(let message):
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(BuildPalette.building)
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
                        .buttonStyle(TactileActionButtonStyle(appearance: .primary, minHeight: 36, fontSize: 12))

                        if let onFallbackExternal {
                            Button("使用外部模拟器打开") {
                                onFallbackExternal()
                            }
                            .buttonStyle(TactileActionButtonStyle(appearance: .secondary, minHeight: 36, fontSize: 12))
                        }

                        Button("关闭窗口") {
                            onCloseWindow()
                        }
                        .buttonStyle(TactileActionButtonStyle(appearance: .secondary, minHeight: 36, fontSize: 12))
                    }
                }
                .padding(24)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white.opacity(0.14), lineWidth: 1))

            case .paused:
                if !showSaveStates && !showCoreOptions && !showControlsGuide {
                    VStack(spacing: 14) {
                        VStack(spacing: 4) {
                            Text("游戏已暂停")
                                .font(.system(size: 19, weight: .bold))
                                .foregroundStyle(.white)
                            Text("按 Esc 或点击继续回到游戏")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        VStack(spacing: 9) {
                            Button {
                                session.setPaused(false)
                            } label: {
                                Text("继续游戏").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(TactileActionButtonStyle(appearance: .primary, cornerRadius: 11, minHeight: 38, fontSize: 13))

                            HStack(spacing: 9) {
                                Button {
                                    showSaveStates = true
                                } label: {
                                    Text("即时存档").frame(maxWidth: .infinity)
                                }
                                .buttonStyle(TactileActionButtonStyle(appearance: .secondary, cornerRadius: 11, minHeight: 36, fontSize: 12))

                                Button {
                                    showControlsGuide = true
                                } label: {
                                    Text("键位说明").frame(maxWidth: .infinity)
                                }
                                .buttonStyle(TactileActionButtonStyle(appearance: .secondary, cornerRadius: 11, minHeight: 36, fontSize: 12))
                            }

                            Button {
                                onCloseWindow()
                            } label: {
                                Text("退出游戏").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(TactileActionButtonStyle(appearance: .destructive, cornerRadius: 11, minHeight: 36, fontSize: 12))
                        }
                    }
                    .padding(24)
                    .frame(width: 340)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white.opacity(0.14), lineWidth: 1))
                    .shadow(color: .black.opacity(0.55), radius: 24, y: 12)
                }

            case .running:
                EmptyView()
            }

            // Top HUD bar + Toast
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
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().stroke(.white.opacity(0.16), lineWidth: 1))
                        .padding(.bottom, 20)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.16), value: shouldShowBar)
            .animation(.easeInOut(duration: 0.16), value: session.statusToast)

            // Side drawers
            Group {
                if showSaveStates {
                    drawerContainer(title: "即时存档", onClose: { showSaveStates = false }) {
                        saveStatesDrawer
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                } else if showCoreOptions {
                    drawerContainer(title: "\(session.descriptor.displayName) 核心选项", onClose: { showCoreOptions = false }) {
                        coreOptionsDrawer
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                } else if showControlsGuide {
                    drawerContainer(title: "键盘 / 鼠标 / 手柄操作", onClose: { showControlsGuide = false }) {
                        controlsGuideDrawer
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.2), value: showSaveStates)
            .animation(.easeOut(duration: 0.2), value: showCoreOptions)
            .animation(.easeOut(duration: 0.2), value: showControlsGuide)
        }
        .preferredColorScheme(.dark)
        .frame(minWidth: 640, minHeight: 480)
    }

    private var hudDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.14))
            .frame(width: 1, height: 18)
            .padding(.horizontal, 3)
    }

    private var topControlBar: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.game.displayTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("\(session.game.platform.shortTitle) · \(session.descriptor.displayName)")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }

            Spacer(minLength: 10)

            // Group 1: Playback
            HUDIconButton(icon: isPaused ? "play.fill" : "pause.fill", help: isPaused ? "继续 (Esc)" : "暂停 (Esc)") {
                session.togglePause()
            }
            HUDIconButton(icon: "forward.fill", help: "快进 (按住 Space)", active: session.fastForward) {
                session.setFastForward(!session.fastForward)
            }

            hudDivider

            // Group 2: Save & Display
            HUDIconButton(icon: "square.and.arrow.down.on.square", title: "存档", help: "即时存档 (⌘S / ⌘L)", active: showSaveStates) {
                showCoreOptions = false
                showControlsGuide = false
                showSaveStates.toggle()
            }
            HUDIconButton(icon: session.crispPixels ? "square.grid.3x3.fill" : "sparkles", help: session.crispPixels ? "画面：像素锐化" : "画面：双线性平滑", active: session.crispPixels) {
                session.crispPixels.toggle()
            }
            if session.descriptor.isDualScreen {
                HUDIconButton(icon: "rectangle.split.2x1", help: "切换双屏布局（上下/左右/主屏放大/单屏）") {
                    session.cycleDualScreenLayout()
                }
            }

            hudDivider

            // Group 3: Audio
            HUDIconButton(icon: session.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", help: session.isMuted ? "取消静音" : "静音") {
                session.updateAudio(muted: !session.isMuted)
            }
            Slider(
                value: Binding(
                    get: { Double(session.volume) },
                    set: { session.updateAudio(volume: Float($0), muted: false) }
                ),
                in: 0...1
            )
            .tint(GameCenterColors.action)
            .frame(width: 66)

            hudDivider

            // Group 4: Overflow menu + Fullscreen
            HUDIconButton(icon: "ellipsis", help: "更多设置（核心选项 / 键位 / 失焦暂停 / 重启）", active: showMoreMenu || showCoreOptions || showControlsGuide) {
                showMoreMenu.toggle()
            }
            .popover(isPresented: $showMoreMenu, arrowEdge: .bottom) {
                hudOverflowPopover
            }

            HUDIconButton(icon: "arrow.up.left.and.arrow.down.right", help: "全屏 (⌘F)") {
                onToggleFullscreen()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.white.opacity(0.14), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 16, y: 6)
        .padding(.horizontal, 18)
        .padding(.top, 36)
        .onHover { hovering in
            isHoveringBar = hovering
        }
    }

    private var hudOverflowPopover: some View {
        VStack(alignment: .leading, spacing: 4) {
            hudOverflowRow(title: "核心选项", icon: "slider.horizontal.3", trailing: showCoreOptions ? "已打开" : nil) {
                showMoreMenu = false
                showSaveStates = false
                showControlsGuide = false
                showCoreOptions.toggle()
            }
            hudOverflowRow(title: "键盘与手柄说明", icon: "keyboard", trailing: showControlsGuide ? "已打开" : nil) {
                showMoreMenu = false
                showSaveStates = false
                showCoreOptions = false
                showControlsGuide.toggle()
            }
            hudOverflowRow(
                title: "失焦自动暂停",
                icon: autoPauseWhenInactive ? "pause.circle.fill" : "pause.circle",
                trailing: autoPauseWhenInactive ? "已开启" : "已关闭",
                trailingAccent: autoPauseWhenInactive ? BuildPalette.ready : .secondary
            ) {
                autoPauseWhenInactive.toggle()
            }
            Divider().opacity(0.4).padding(.vertical, 2)
            hudOverflowRow(title: "重新启动游戏", icon: "arrow.counterclockwise", foreground: BuildPalette.building) {
                showMoreMenu = false
                session.resetGame()
            }
        }
        .padding(8)
        .frame(width: 224)
        .preferredColorScheme(.dark)
    }

    private func hudOverflowRow(
        title: String,
        icon: String,
        trailing: String? = nil,
        trailingAccent: Color = .secondary,
        foreground: Color = .primary,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Spacer(minLength: 8)
                if let trailing {
                    Text(trailing)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(trailingAccent)
                }
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(HUDPopoverRowStyle())
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
                    SheetCloseButton(action: onClose)
                }
                Divider().overlay(GameCenterColors.border)
                ScrollView {
                    content()
                }
            }
            .padding(16)
            .frame(width: 348)
            .frame(maxHeight: .infinity)
            .background(.ultraThinMaterial)
            .background(Color.black.opacity(0.68))
            .overlay(Rectangle().frame(width: 1).foregroundStyle(.white.opacity(0.12)), alignment: .leading)
            .padding(.top, 88)
        }
    }

    private var saveStatesDrawer: some View {
        VStack(spacing: 10) {
            ForEach(session.saveSlots) { slot in
                HStack(spacing: 12) {
                    Group {
                        if slot.exists, let nsImage = session.slotThumbnails[slot.slot] {
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
                    .frame(width: 74, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                    VStack(alignment: .leading, spacing: 4) {
                        Text("槽位 \(slot.slot)")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                        if let date = slot.modifiedAt {
                            Text(date.formatted(date: .abbreviated, time: .shortened))
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.6))
                        } else {
                            Text("空槽位")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                        HStack(spacing: 6) {
                            Button("保存") { session.saveState(slot: slot.slot) }
                                .buttonStyle(TactileActionButtonStyle(appearance: .primary, cornerRadius: 7, minHeight: 26, horizontalPadding: 10, fontSize: 11))
                            Button("读取") { session.loadState(slot: slot.slot) }
                                .buttonStyle(TactileActionButtonStyle(appearance: .secondary, cornerRadius: 7, minHeight: 26, horizontalPadding: 10, fontSize: 11))
                                .disabled(!slot.exists)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
                .background(GameCenterColors.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(GameCenterColors.border, lineWidth: 1))
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
                    VStack(alignment: .leading, spacing: 6) {
                        Text(option.description)
                            .font(.system(size: 12, weight: .medium))
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
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(GameCenterColors.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(GameCenterColors.border, lineWidth: 1))
                }
            }
        }
    }

    private var controlsGuideDrawer: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(GameInputCapture.defaultHints) { hint in
                VStack(alignment: .leading, spacing: 4) {
                    Text(hint.action)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("键盘：\(hint.keyboard)")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.75))
                    Text("手柄：\(hint.gamepad)")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(GameCenterColors.surface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(GameCenterColors.border, lineWidth: 1))
            }
        }
    }
}

private struct HUDIconButton: View {
    let icon: String
    var title: String? = nil
    let help: String
    var active = false
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                if let title {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .foregroundStyle(active ? Color(white: 0.06) : .white.opacity(0.92))
            .padding(.horizontal, title == nil ? 0 : 10)
            .frame(minWidth: 30, minHeight: 30)
            .background(
                active
                    ? GameCenterColors.action
                    : Color.white.opacity(isHovered ? 0.18 : 0.09),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(CursorButtonStyle())
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isHovered)
        .help(help)
    }
}

private struct HUDPopoverRowStyle: ButtonStyle {
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isHovered ? Color.white.opacity(0.14) : Color.clear)
            )
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .onHover { isHovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovered)
            .pointingHandCursor()
    }
}
