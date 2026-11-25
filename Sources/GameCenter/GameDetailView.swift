import AppKit
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
    @State private var isFavoriteHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var modalWidth: CGFloat { min(560, max(440, availableSize.width - 32)) }
    private var modalHeight: CGFloat { min(660, max(420, availableSize.height - 32)) }

    private var resolvedSourceURL: URL? {
        guard let raw = game.metadataSourceURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else { return nil }
        return url
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("游戏详情")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                SheetCloseButton { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 13)
            .overlay(alignment: .bottom) {
                Rectangle().fill(GameCenterColors.border).frame(height: 1)
            }

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
        HStack(alignment: .top, spacing: 18) {
            GameArtwork(game: game, showPlatformBadge: false)
                .frame(width: 132, height: 174)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 1))

            VStack(alignment: .leading, spacing: 10) {
                Text(game.displayTitle)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(3)

                HStack(spacing: 8) {
                    Label(game.platform.title, systemImage: game.platform.symbol)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.86))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(GameCenterColors.surfaceElevated, in: RoundedRectangle(cornerRadius: 6, style: .continuous))

                    HStack(spacing: 5) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 6, height: 6)
                        Text(statusTitle)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }

                Text(AppLanguage.localized(game.lastPlayedAt.map {
                    AppLanguage.format("上次游玩 %@", $0.formatted(date: .abbreviated, time: .shortened))
                } ?? "尚未游玩"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 4)

                HStack(spacing: 8) {
                    Button(action: onFavorite) {
                        Label(game.isFavorite ? "已收藏" : "收藏", systemImage: game.isFavorite ? "heart.fill" : "heart")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(game.isFavorite ? GameCenterColors.favoriteForeground : Color.primary)
                            .padding(.horizontal, 13)
                            .frame(height: 36)
                            .background(
                                game.isFavorite
                                    ? (isFavoriteHovered ? GameCenterColors.favoriteBackgroundHover : GameCenterColors.favoriteBackground)
                                    : (isFavoriteHovered ? GameCenterColors.surfaceHover : GameCenterColors.surfaceElevated),
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .stroke(game.isFavorite ? GameCenterColors.favoriteBorder : Color.white.opacity(0.12), lineWidth: 1)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .stroke(.white, lineWidth: controllerSelection == 0 ? 2 : 0)
                            )
                    }
                    .buttonStyle(CursorButtonStyle())
                    .onHover { isFavoriteHovered = $0 }
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isFavoriteHovered)
                    .help(AppLanguage.localized(game.isFavorite ? "取消收藏" : "加入收藏"))

                    if let fileURL = try? game.resolvedURL(), FileManager.default.fileExists(atPath: fileURL.path) {
                        Button("在访达中显示", systemImage: "folder") {
                            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                        }
                        .buttonStyle(TactileActionButtonStyle(appearance: .secondary, cornerRadius: 9, minHeight: 36, horizontalPadding: 12, fontSize: 12))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 174)
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
                    }
                }
                .buttonStyle(TactileActionButtonStyle(appearance: .secondary, cornerRadius: 8, minHeight: 30, horizontalPadding: 11, fontSize: 11))
                .disabled(game.metadataStatus == "searching")
            }

            VStack(alignment: .leading, spacing: 12) {
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
                .font(.system(size: 13))
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

                if let sourceURL = resolvedSourceURL {
                    Divider().overlay(.white.opacity(0.08))
                    HStack {
                        Text(AppLanguage.localized("简介来源"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Link(destination: sourceURL) {
                            HStack(spacing: 4) {
                                Text(sourceURL.host ?? sourceURL.absoluteString)
                                    .lineLimit(1)
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.82))
                        }
                        .pointingHandCursor()
                    }
                }
            }
            .padding(14)
            .background(GameCenterColors.surface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(GameCenterColors.border, lineWidth: 1))
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("从资料库移除", role: .destructive, action: onRemove)
                .buttonStyle(TactileActionButtonStyle(appearance: .destructive, isControllerFocused: controllerSelection == 3))

            Spacer(minLength: 4)

            Button("更换封面…", systemImage: "photo", action: onChooseArtwork)
                .buttonStyle(TactileActionButtonStyle(appearance: .secondary, isControllerFocused: controllerSelection == 1))

            if game.platform == .switchConsole && !game.isDirectlyLaunchable {
                Button("构建游戏", systemImage: "hammer", action: onBuild)
                    .buttonStyle(TactileActionButtonStyle(appearance: .primary, isControllerFocused: controllerSelection == 2))
            }
            if game.isDirectlyLaunchable {
                Button("启动游戏", systemImage: "play.fill", action: onLaunch)
                    .buttonStyle(TactileActionButtonStyle(appearance: .primary, isControllerFocused: controllerSelection == 2))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color.black.opacity(0.24))
        .overlay(alignment: .top) { Rectangle().fill(GameCenterColors.border).frame(height: 1) }
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
        case "found": BuildPalette.ready
        case "error": GameCenterColors.destructiveForeground
        default: .secondary
        }
    }
}
