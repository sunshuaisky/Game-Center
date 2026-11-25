import SwiftUI

struct GameDetailView: View {
    let game: Game
    let availableSize: CGSize
    @ObservedObject var controllerNavigation: ControllerNavigation
    let onFavorite: () -> Void
    let onLaunch: () -> Void
    let onChooseArtwork: () -> Void
    let onRemove: () -> Void
    let onBuild: () -> Void
    let onRefreshMetadata: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var controllerSelection = 2

    private var modalWidth: CGFloat { min(560, max(420, availableSize.width - 32)) }
    private var modalHeight: CGFloat { min(680, max(400, availableSize.height - 32)) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    hero
                    synopsisSection
                }
                .padding(22)
            }

            footer
        }
        .frame(width: modalWidth, height: modalHeight)
        .background(Color(nsColor: .windowBackgroundColor))
        .foregroundStyle(.primary)
        .preferredColorScheme(.dark)
        .overlay {
            OutsideClickDismissMonitor { dismiss() }
                .allowsHitTesting(false)
        }
        .onReceive(controllerNavigation.$event.compactMap { $0 }) { event in
            switch event.action {
            case .moveHorizontal(let direction), .moveVertical(let direction):
                controllerSelection = (controllerSelection + direction + 4) % 4
            case .confirm:
                activateControllerSelection()
            }
        }
    }

    private var hero: some View {
        HStack(alignment: .center, spacing: 18) {
            GameArtwork(game: game)
                .frame(width: 132, height: 174)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(.white.opacity(0.1), lineWidth: 1))

            VStack(alignment: .leading, spacing: 11) {
                Text(game.displayTitle)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(3)

                Label(game.platform.title, systemImage: game.platform.symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                    Text(statusTitle)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Button(action: onFavorite) {
                    Label(game.isFavorite ? "已收藏" : "收藏", systemImage: game.isFavorite ? "heart.fill" : "heart")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(game.isFavorite ? Color(red: 1, green: 0.5, blue: 0.57) : Color.primary)
                        .padding(.horizontal, 13)
                        .frame(height: 36)
                        .background(game.isFavorite ? Color.red.opacity(0.15) : Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(game.isFavorite ? Color.red.opacity(0.34) : Color.white.opacity(0.12), lineWidth: 1))
                }
                .buttonStyle(CursorButtonStyle())
                .overlay(Circle().stroke(.white, lineWidth: controllerSelection == 0 ? 2 : 0))
                .help(AppLanguage.localized(game.isFavorite ? "取消收藏" : "加入收藏"))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 174)
        }
    }

    private var synopsisSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("游戏简介").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(action: onRefreshMetadata) {
                    HStack(spacing: 6) {
                        if game.metadataStatus == "searching" { ProgressView().controlSize(.small) }
                        Text(game.metadataStatus == "searching" ? "正在查找…" : "查找游戏信息")
                    }.font(.system(size: 11)).padding(.horizontal, 10).padding(.vertical, 8)
                        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(CursorButtonStyle()).disabled(game.metadataStatus == "searching")
            }

            Group {
                if let synopsis = game.synopsis, !synopsis.isEmpty {
                    Text(synopsis)
                        .foregroundStyle(.primary.opacity(0.88))
                } else {
                    Text(AppLanguage.localized(game.metadataStatus == "searching"
                         ? "正在联网查找游戏简介和封面…"
                         : "暂时没有匹配到简介。可为游戏手动选择封面。"))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 12))
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.07), lineWidth: 1))
        }
    }

    private var footer: some View {
        HStack(spacing: 9) {
            Button("从资料库移除", role: .destructive, action: onRemove)
                .buttonStyle(DetailButtonStyle(appearance: .destructive, isControllerFocused: controllerSelection == 3))

            Spacer(minLength: 2)

            Button("更换封面…", systemImage: "photo", action: onChooseArtwork)
                .buttonStyle(DetailButtonStyle(isControllerFocused: controllerSelection == 1))
            if game.platform == .switchConsole && !game.isDirectlyLaunchable {
                Button("构建游戏", systemImage: "hammer", action: onBuild)
                    .buttonStyle(DetailButtonStyle(isControllerFocused: controllerSelection == 2))
            }
            if game.isDirectlyLaunchable {
                Button("启动游戏", systemImage: "play.fill", action: onLaunch)
                    .buttonStyle(DetailButtonStyle(appearance: .primary, isControllerFocused: controllerSelection == 2))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color.black.opacity(0.24))
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.07)).frame(height: 1) }
    }

    private func activateControllerSelection() {
        switch controllerSelection {
        case 0: onFavorite()
        case 1: onChooseArtwork()
        case 2: game.platform == .switchConsole && !game.isDirectlyLaunchable ? onBuild() : onLaunch()
        case 3: onRemove()
        default: break
        }
    }

    private var statusTitle: String {
        switch game.metadataStatus {
        case "searching": AppLanguage.localized("正在获取")
        case "found": AppLanguage.localized("已获取")
        case "notFound": AppLanguage.localized("没有匹配结果")
        case "error": AppLanguage.localized("获取失败")
        default: AppLanguage.localized("尚未获取")
        }
    }

    private var statusColor: Color {
        switch game.metadataStatus {
        case "searching": .orange
        case "found": .green
        case "error": .red
        default: .secondary
        }
    }
}

private struct DetailButtonStyle: ButtonStyle {
    enum Appearance { case secondary, primary, destructive }
    var appearance: Appearance = .secondary
    var isControllerFocused = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 11)
            .frame(minHeight: 36)
            .background(backgroundColor, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(borderColor, lineWidth: 1))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white, lineWidth: isControllerFocused ? 2 : 0))
            .pointingHandCursor()
    }

    private var foregroundColor: Color {
        switch appearance {
        case .primary: .black
        case .destructive: Color(red: 1, green: 0.46, blue: 0.5)
        case .secondary: .primary
        }
    }

    private var backgroundColor: Color {
        switch appearance {
        case .primary: GameCenterColors.action
        case .destructive: Color.red.opacity(0.12)
        case .secondary: Color.white.opacity(0.07)
        }
    }

    private var borderColor: Color {
        switch appearance {
        case .primary: Color.white.opacity(0.18)
        case .destructive: Color.red.opacity(0.25)
        case .secondary: Color.white.opacity(0.12)
        }
    }
}
