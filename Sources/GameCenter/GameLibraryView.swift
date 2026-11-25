import AppKit
import GameController
import SwiftUI
import UniformTypeIdentifiers

private enum GameLibrarySheet: Identifiable {
    case details(Game)
    case cheats(Game)
    case history(Game)

    var id: String {
        switch self {
        case .details(let game): "details-\(game.id.uuidString)"
        case .cheats(let game): "cheats-\(game.id.uuidString)"
        case .history(let game): "history-\(game.id.uuidString)"
        }
    }

    var game: Game {
        switch self {
        case .details(let game), .cheats(let game), .history(let game): game
        }
    }
}

struct GameLibraryView: View {
    @ObservedObject var library: GameLibrary
    let language: AppLanguage
    let onLanguageChange: (AppLanguage) -> Void

    @State private var platform: GamePlatform = .gba
    @State private var libraryFilter: LibraryFilter = .recent
    @State private var selectedGameID: UUID?
    @State private var isSettingsVisible = false
    @StateObject private var mobileBuildSession = MobileAppBuildSession()
    @State private var isMobileBuildVisible = false
    @State private var mobileBuildNotice: String?
    @State private var actionMenuGameID: UUID?
    @State private var actionMenuSelection: Int?
    @State private var settingsSelection = 0
    @State private var showingAppleSigning = false
    @State private var showingSaveSync = false
    @State private var activeSheet: GameLibrarySheet?
    @State private var buildGame: Game?
    @State private var buildSourceURL: URL?
    @StateObject private var switchBuildSession = SwitchBuildSession()
    @State private var launchError: String?
    @State private var showingLaunchError = false
    @State private var windowSize = CGSize(width: 1000, height: 678)
    @AppStorage(MacCoreCatalog.externalFullscreenKey) private var launchExternalFullscreen = true
    @ObservedObject private var externalSession = ExternalGameSessionMonitor.shared
    @StateObject private var gamepad = GamepadManager()
    @StateObject private var controllerNavigation = ControllerNavigation()

    private let launcher = GameLaunchService()

    private var inverseColor: Color { Color(nsColor: .windowBackgroundColor) }

    private var visibleGames: [Game] {
        let filtered = library.games.filter { game in
            guard game.platform.isEnabled else { return false }
            return switch libraryFilter {
            case .all: true
            case .recent: game.lastPlayedAt != nil
            case .favorites: game.isFavorite
            case .platform(let value): game.platform == value
            }
        }
        return filtered
            .sorted { lhs, rhs in
                if libraryFilter == .recent {
                    return (lhs.lastPlayedAt ?? .distantPast) > (rhs.lastPlayedAt ?? .distantPast)
                }
                return lhs.displayTitle.localizedStandardCompare(rhs.displayTitle) == .orderedAscending
            }
    }

    private var selectedGame: Game? {
        visibleGames.first(where: { $0.id == selectedGameID }) ?? visibleGames.first
    }

    private var cheatsSwitchDirectory: URL? {
        SwitchCheatService.switchDirectory(from: library.gameDirectoryPath)
    }

    private var selectedGameRequiresBuild: Bool {
        guard let selectedGame else { return false }
        return selectedGame.platform == .switchConsole && !selectedGame.isDirectlyLaunchable
    }

    private var buildStatusTitle: String {
        let stage = switchBuildSession.progress.stage
        let detail = switchBuildSession.progress.detail
        let visibleStage = stage == "构建中" && !detail.isEmpty ? detail : stage
        return visibleStage.isEmpty ? AppLanguage.localized("构建中") : "\(AppLanguage.localized("构建中")) · \(visibleStage)"
    }

    private func presentBuild(for game: Game) {
        controllerNavigation.reset()
        let displayedGame = switchBuildSession.isBuilding ? switchBuildSession.game ?? game : game
        buildSourceURL = library.resolvedGameURL(for: displayedGame)
        buildGame = displayedGame
    }

    private func detailSheet(for game: Game) -> some View {
        let currentGame = library.games.first(where: { $0.id == game.id }) ?? game
        return GameDetailView(
            game: currentGame,
            availableSize: windowSize,
            controllerNavigation: controllerNavigation,
            onFavorite: { library.toggleFavorite(for: game.id) },
            onLaunch: { launch(game) },
            onChooseArtwork: {
                if let url = GameImporter.chooseArtwork() { library.setArtwork(from: url, for: game.id) }
            },
            onRemove: {
                library.remove(game.id)
                activeSheet = nil
                selectedGameID = nil
            },
            onBuild: {
                presentBuild(for: game)
                activeSheet = nil
            },
            onRefreshMetadata: { library.refreshMetadata(for: game.id, language: language.scrapeLanguage, force: true) }
        )
    }

    @ViewBuilder
    private func cheatSheet(for game: Game) -> some View {
        if let switchDirectory = cheatsSwitchDirectory,
           let titleID = SwitchCheatService.titleID(for: game) {
            SwitchCheatManagerView(
                title: game.displayTitle,
                titleID: titleID,
                directory: SwitchCheatService.directory(switchDirectory: switchDirectory, titleID: titleID),
                availableSize: windowSize,
                controllerNavigation: controllerNavigation
            )
            .preferredColorScheme(.dark)
        } else {
            CheatUnavailableView(message: cheatsSwitchDirectory == nil
                ? "请先在设置中选择 Switch 游戏目录。"
                : "无法识别游戏程序 ID，请确认游戏文件名或应用信息中包含 16 位游戏 ID。")
        }
    }

    var body: some View {
        GeometryReader { container in
            let footerHeight = max(container.size.height * 0.60, 270)
            ZStack {
                if let buildGame {
                    VStack(spacing: 0) {
                        Divider().opacity(0.3)
                        buildPage(for: buildGame)
                    }
                } else {
                    backdrop
                    VStack(spacing: 0) {
                        hero
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .padding(.horizontal, 34)

                        VStack(spacing: 0) {
                            platformPicker
                                .frame(height: 52)
                                .padding(.horizontal, 34)
                                .padding(.top, 16)

                            gameCarousel
                                .frame(maxWidth: .infinity, maxHeight: .infinity)

                            if let runningTitle = externalSession.activeGameTitle {
                                HStack(spacing: 10) {
                                    Circle()
                                        .fill(Color.green)
                                        .frame(width: 7, height: 7)
                                    Text("运行中：\(runningTitle)（\(externalSession.activePlatformName ?? "")）· 长按手柄 Menu+Options 退出返回")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.9))
                                        .lineLimit(1)
                                    Spacer(minLength: 8)
                                    Button("切回游戏") { externalSession.focusExternalGame() }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                    Button("结束游戏") { externalSession.terminateExternalGameAndReturn() }
                                        .buttonStyle(.borderedProminent)
                                        .controlSize(.small)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(Color.black.opacity(0.72), in: Capsule())
                                .overlay(Capsule().stroke(.white.opacity(0.14), lineWidth: 1))
                                .padding(.horizontal, 34)
                                .padding(.bottom, 6)
                            }

                            if gamepad.controllerName != nil {
                                bottomHints
                                    .padding(.top, 8)
                                    .padding(.bottom, 12)
                                    .padding(.horizontal, 34)
                            }
                        }
                        .frame(height: footerHeight)
                        .background {
                            Rectangle()
                                .fill(.regularMaterial.opacity(0.38))
                                .mask {
                                    LinearGradient(
                                        stops: [
                                            .init(color: .clear, location: 0),
                                            .init(color: .black.opacity(0.24), location: 0.06),
                                            .init(color: .black.opacity(0.78), location: 0.2),
                                            .init(color: .black, location: 0.38),
                                            .init(color: .black, location: 1)
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                }
                                .overlay {
                                    LinearGradient(
                                        stops: [
                                            .init(color: .clear, location: 0),
                                            .init(color: .black.opacity(0.02), location: 0.16),
                                            .init(color: .black.opacity(0.07), location: 0.48),
                                            .init(color: .black.opacity(0.1), location: 1)
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                }
                        }
                    }
                    .frame(minWidth: 780, minHeight: 560)
                }
            }
            .onAppear { windowSize = container.size }
            .onChange(of: container.size) { _, size in windowSize = size }
        }
        .frame(minWidth: 780, minHeight: 560)
        .toolbar { libraryToolbar }
        .toolbarBackground(.hidden, for: .windowToolbar)
        .background {
            if buildGame != nil {
                Rectangle().fill(.regularMaterial).ignoresSafeArea()
            }
        }
        .foregroundStyle(.primary)
        .sheet(item: $activeSheet) { destination in
            switch destination {
            case .details(let game):
                detailSheet(for: game)
            case .cheats(let game):
                cheatSheet(for: game)
            case .history(let game):
                GamePlayHistoryView(game: library.games.first(where: { $0.id == game.id }) ?? game)
            }
        }
        .sheet(isPresented: $showingAppleSigning) { AppleSigningSettings() }
        .sheet(isPresented: $showingSaveSync) {
            CloudSaveSyncView(saveRoot: {
                guard let path = library.gameDirectoryPath else { throw CloudSaveDirectorySync.Failure("请先在设置中选择游戏目录。") }
                // Adopt saves from older game builds before mirroring the tree.
                _ = try MacSaveSync.slots(root: path)
                return URL(fileURLWithPath: path).lastPathComponent.lowercased() == "switch"
                    ? URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("save")
                    : URL(fileURLWithPath: path).appendingPathComponent("save")
            },
                              isPlaying: { MacSaveSync.isPlaying(root: library.gameDirectoryPath) })
        }
        .alert("无法启动游戏", isPresented: $showingLaunchError) {
            Button("好", role: .cancel) { }
        } message: {
            Text(launchError ?? AppLanguage.localized("请稍后重试。"))
        }
        .alert("游戏资料库", isPresented: Binding(
            get: { library.errorMessage != nil },
            set: { if !$0 { library.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { library.errorMessage = nil }
        } message: {
            Text(library.errorMessage ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in
            gamepad.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) { _ in
            gamepad.refresh()
        }
        .onChange(of: visibleGames.map(\.id)) { _, ids in
            if !(selectedGameID.map(ids.contains) ?? false) {
                selectedGameID = ids.first
            }
        }
        .onChange(of: libraryFilter) { _, _ in
            selectedGameID = visibleGames.first?.id
        }
        .onChange(of: language) { _, value in
            library.refreshMissingMetadata(language: value.scrapeLanguage)
        }
        .onAppear {
            selectedGameID = visibleGames.first?.id
            library.refreshMissingMetadata(language: language.scrapeLanguage)
            gamepad.refresh()
            bindGamepadActions()
        }
        .onChange(of: gamepad.connectionVersion) { _, _ in
            bindGamepadActions()
        }

    }

    private func count(for value: GamePlatform) -> Int {
        library.games.filter { $0.platform == value }.count
    }

    private var backdrop: some View {
        GeometryReader { geometry in
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                if let selectedGame {
                    GameArtwork(game: selectedGame, compact: true)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .transition(.opacity)
                } else {
                    LinearGradient(
                        colors: [Color(white: 0.16), Color(white: 0.055)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
                LinearGradient(stops: [
                    .init(color: .black.opacity(0.65), location: 0),
                    .init(color: .black.opacity(0.28), location: 0.38),
                    .init(color: .clear, location: 0.75)
                ], startPoint: .leading, endPoint: .trailing)
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.62), location: 0),
                        .init(color: .black.opacity(0.32), location: 0.18),
                        .init(color: .black.opacity(0.08), location: 0.42),
                        .init(color: .black.opacity(0.30), location: 0.62),
                        .init(color: .black.opacity(0.88), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .overlay(alignment: .topTrailing) {
                RadialGradient(colors: [.black.opacity(0.38), .clear], center: .topTrailing,
                               startRadius: 0, endRadius: 360)
                    .frame(width: 360, height: 360).allowsHitTesting(false)
            }
            .clipped()
            .ignoresSafeArea()
        }
        .ignoresSafeArea()
        .animation(.easeOut(duration: 0.24), value: selectedGame?.id)
    }

    @ToolbarContentBuilder
    private var libraryToolbar: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .navigation) {
                toolbarBrand
            }
            .sharedBackgroundVisibility(.hidden)

            ToolbarSpacer(.flexible, placement: .primaryAction)

            ToolbarItem(placement: .primaryAction) {
                toolbarActions
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .navigation) {
                toolbarBrand
            }

            ToolbarItem(placement: .automatic) { Spacer() }

            ToolbarItem(placement: .primaryAction) {
                toolbarActions
            }
        }
    }

    private var toolbarBrand: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .renderingMode(.original).resizable().scaledToFit()
                .frame(width: 26, height: 26).accessibilityHidden(true)
            Text("GAME CENTER")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .tracking(1.1)
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.45), radius: 4, y: 1)
    }

    private var toolbarActions: some View {
        HStack(spacing: 12) {
            if switchBuildSession.isBuilding {
                Button {
                    if let game = switchBuildSession.game { presentBuild(for: game) }
                } label: {
                    HStack(spacing: 7) {
                        if let fraction = switchBuildSession.overallFraction {
                            ProgressView(value: fraction)
                                .progressViewStyle(.linear)
                                .tint(.white)
                                .frame(width: 42)
                        } else {
                            ProgressView().controlSize(.small).tint(.white)
                        }
                        Text(buildStatusTitle)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                        if let fraction = switchBuildSession.overallFraction {
                            Text("\(Int(fraction * 100))%")
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(.white.opacity(0.12), in: Capsule())
                }
                .buttonStyle(CursorButtonStyle())
                .help(AppLanguage.localized("查看构建进度"))
                .accessibilityLabel(AppLanguage.localized("查看构建进度"))
            }

            Label(gamepad.controllerName ?? AppLanguage.localized("未连接手柄"), systemImage: "gamecontroller")
                .labelStyle(.titleAndIcon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .shadow(color: .black.opacity(0.45), radius: 3, y: 1)

            MobileAppBuildButton(session: mobileBuildSession, isPresented: $isMobileBuildVisible,
                                 chooseDirectory: buildMobileApp)
            .alert("生成 iOS App", isPresented: Binding(
                get: { mobileBuildNotice != nil },
                set: { if !$0 { mobileBuildNotice = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(mobileBuildNotice ?? "")
            }

            Button {
                isSettingsVisible.toggle()
                settingsSelection = 0
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(.white.opacity(isSettingsVisible ? 0.16 : 0.08), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(CursorButtonStyle())
            .help("设置")
            .accessibilityLabel("设置")
            .popover(isPresented: $isSettingsVisible, arrowEdge: .bottom) {
                settingsPopover
            }
        }
    }

    private func buildMobileApp() {
        guard !mobileBuildSession.isBuilding else { return }
        isMobileBuildVisible = false
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "生成"
        panel.message = "选择 Game Center.ipa 的输出目录"
        panel.begin { result in
            guard result == .OK, let directory = panel.url else {
                isMobileBuildVisible = true
                return
            }
            let root = library.gameDirectoryPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
            let games = library.switchCatalog()
            mobileBuildSession.start(directory: directory, libraryRoot: root, games: games)
            isMobileBuildVisible = true
        }
    }

    private func buildPage(for game: Game) -> some View {
        SwitchBuildView(
            game: game,
            initialSourceURL: buildSourceURL,
            gameLibraryPath: library.gameDirectoryPath,
            metadataLanguage: language.scrapeLanguage,
            session: switchBuildSession,
            controllerNavigation: controllerNavigation,
            onBack: { buildGame = nil }
        ) {
            if let resultURL = switchBuildSession.resultURL {
                library.registerBuiltGame(at: resultURL, replacing: game.id)
            } else {
                library.scanGameDirectory()
            }
        }
    }

    private var settingsPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("设置")
                .font(.system(size: 15, weight: .semibold))
            VStack(alignment: .leading, spacing: 7) {
                Text("语言").font(.caption).foregroundStyle(.secondary)
                ForEach(Array(AppLanguage.allCases.enumerated()), id: \.offset) { index, value in
                    HoverMenuRow(isControllerFocused: isSettingsVisible && settingsSelection == index) {
                        onLanguageChange(value)
                    } label: {
                        Label(AppLanguage.localized(value.titleKey), systemImage: language == value ? "checkmark" : "character.bubble")
                    }
                }
            }

            Divider()

            HoverMenuRow(isControllerFocused: isSettingsVisible && settingsSelection == AppLanguage.allCases.count) {
                if let url = GameImporter.chooseGameDirectory() {
                    library.setGameDirectory(url)
                }
            } label: {
                Label(library.gameDirectoryPath == nil ? "选择游戏文件夹…" : "更改游戏文件夹…", systemImage: "folder")
            }
            if let gameDirectoryPath = library.gameDirectoryPath {
                Text(gameDirectoryPath)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                HoverMenuRow(isControllerFocused: isSettingsVisible && settingsSelection == AppLanguage.allCases.count + 1) {
                    library.scanGameDirectory(refreshAllMetadata: true, language: language.scrapeLanguage)
                } label: {
                    if library.isScanning {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在扫描并更新资料…")
                        }
                    } else {
                        Label("立即扫描", systemImage: "arrow.clockwise")
                    }
                }
            }
            Divider()
            HoverMenuRow(isControllerFocused: isSettingsVisible && settingsSelection == settingsItemCount - 3) {
                launchExternalFullscreen.toggle()
            } label: {
                Label(
                    launchExternalFullscreen ? "外部模拟器直启全屏" : "外部模拟器窗口启动",
                    systemImage: launchExternalFullscreen ? "arrow.up.left.and.arrow.down.right" : "macwindow"
                )
            }
            HoverMenuRow(isControllerFocused: isSettingsVisible && settingsSelection == settingsItemCount - 2) {
                isSettingsVisible = false
                showingSaveSync = true
            } label: {
                Label("同步存档", systemImage: "arrow.triangle.2.circlepath.icloud")
            }
            HoverMenuRow(isControllerFocused: isSettingsVisible && settingsSelection == settingsItemCount - 1) {
                isSettingsVisible = false
                showingAppleSigning = true
            } label: {
                Label("Apple ID 与 iOS 签名", systemImage: "person.badge.key")
            }
            .disabled(switchBuildSession.isBuilding || mobileBuildSession.isBuilding)

        }
        .padding(18)
        .frame(width: 235)
        .background(Color.black.opacity(0.96), in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(.white.opacity(0.1), lineWidth: 1))
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 12)

            if let selectedGame {
                HStack(alignment: .center, spacing: 30) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(platform.title.uppercased())
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .tracking(2.1)
                            .foregroundStyle(.primary.opacity(0.68))

                        Text(selectedGame.displayTitle)
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .tracking(-0.7)
                            .lineLimit(2)
                            .foregroundStyle(.primary)
                            .shadow(color: .black.opacity(0.22), radius: 10, y: 2)

                        HStack(spacing: 14) {
                            Text(AppLanguage.localized(selectedGame.isFavorite ? "已收藏" : "游戏库"))
                            Text("·")
                            Text(AppLanguage.localized(selectedGame.lastPlayedAt.map {
                                AppLanguage.format("上次游玩 %@", $0.formatted(date: .abbreviated, time: .omitted))
                            } ?? "尚未游玩"))
                            Text("·")
                            Text(AppLanguage.format("%d 款游戏", visibleGames.count))
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.72))

                        HStack(spacing: 10) {
                            if selectedGame.isDirectlyLaunchable {
                                Button(action: playSelected) {
                                    Label("开始游玩", systemImage: "play.fill")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(inverseColor)
                                        .padding(.horizontal, 18)
                                        .frame(height: 38)
                                        .background(Color.primary, in: Capsule())
                                }
                                .buttonStyle(CursorButtonStyle())
                            }

                            if selectedGame.platform == .switchConsole {
                                Button { presentBuild(for: selectedGame) } label: {
                                    Label("构建 Switch 游戏", systemImage: "hammer")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(inverseColor)
                                        .padding(.horizontal, 18)
                                        .frame(height: 38)
                                        .background(Color.primary, in: Capsule())
                                }
                                .buttonStyle(CursorButtonStyle())
                            }

                            Button {
                                library.toggleFavorite(for: selectedGame.id)
                            } label: {
                                Image(systemName: selectedGame.isFavorite ? "heart.fill" : "heart")
                                    .foregroundStyle(.white)
                                    .frame(width: 38, height: 38)
                                    .background(Color.white.opacity(0.14), in: Circle())
                            }
                            .buttonStyle(CursorButtonStyle())
                .help(AppLanguage.localized(selectedGame.isFavorite ? "取消收藏" : "加入收藏"))
                        }
                        .padding(.top, 4)
                    }
                    .frame(maxWidth: 520, alignment: .leading)

                    Spacer(minLength: 0)
                }
                .transition(.opacity.combined(with: .move(edge: .leading)))
            } else {
                emptyHero
            }

            Spacer(minLength: 20)
        }
        .padding(.top, 16)
        .animation(.easeOut(duration: 0.2), value: selectedGame?.id)
    }

    private var emptyHero: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(libraryFilter.title.uppercased())
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(2.1)
                .foregroundStyle(.primary.opacity(0.65))
            Text(AppLanguage.localized(visibleGames.isEmpty ? (libraryFilter == .recent ? "还没有游玩记录" : libraryFilter == .favorites ? "还没有收藏的游戏" : "这个平台还没有游戏") : "没有找到匹配的游戏"))
                .font(.system(size: 29, weight: .semibold, design: .rounded))
            Text(AppLanguage.localized(visibleGames.isEmpty
                 ? (libraryFilter == .recent ? "启动过的游戏会按最近游玩时间排列在这里。" : libraryFilter == .favorites ? "收藏的游戏会集中显示在这里。" : library.gameDirectoryPath == nil ? "选择游戏库根目录，每个平台的游戏放在对应的子文件夹内。" : "已监控游戏目录，放入对应平台文件夹后会自动识别。")
                 : "换个关键词试试，或切换到其他平台。"))
                .font(.system(size: 12))
                .foregroundStyle(.primary.opacity(0.7))

            if case .platform(let value) = libraryFilter, GamePlatform.macSystems[value] != nil {
                Text(AppLanguage.format("游戏子文件夹：%@", value.id))
                    .font(.callout.monospaced())
            }

            if visibleGames.isEmpty && libraryFilter == .platform(platform) && library.gameDirectoryPath == nil {
                Button {
                    if let url = GameImporter.chooseGameDirectory() {
                        library.setGameDirectory(url)
                    }
                } label: {
                    Label("选择游戏文件夹", systemImage: "folder")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(inverseColor)
                        .padding(.horizontal, 16)
                        .frame(height: 36)
                        .background(Color.primary, in: Capsule())
                }
                .buttonStyle(CursorButtonStyle())
                .padding(.top, 3)
            }
        }
        .padding(.vertical, 22)
    }

    private var platformPicker: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 24) {
                        filterButton(.recent, title: "最近游玩")
                        filterButton(.favorites, title: "收藏")

                        ForEach(GamePlatform.allCases) { value in
                            filterButton(.platform(value), title: value.shortTitle == "macOS" ? "Mac 游戏" : value.shortTitle)
                        }
                    }
                    .padding(.horizontal, 16)
                    .frame(minWidth: geometry.size.width, alignment: .center)
                }
                .onChange(of: libraryFilter) { _, value in
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(value.id, anchor: .center)
                    }
                }
            }
        }
    }

    private var gameCarousel: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(libraryFilter == .recent || libraryFilter == .favorites
                    ? libraryFilter.title
                    : AppLanguage.format("%@ 游戏", AppLanguage.localized(platform.shortTitle)))
                    .font(.system(size: 12, weight: .semibold))
                Text("\(visibleGames.count)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.56))
                Spacer()
            }
            .padding(.horizontal, 2)

            if visibleGames.isEmpty {
                HStack(spacing: 9) {
                    Image(systemName: "square.stack.3d.up")
                    Text(AppLanguage.localized("扫描到的游戏封面会排列在这里"))
                }
                .font(.system(size: 11))
                .foregroundStyle(.primary.opacity(0.54))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: true) {
                        LazyHStack(alignment: .top, spacing: 13) {
                            ForEach(visibleGames) { game in
                                gameTile(game, isSelected: game.id == selectedGame?.id)
                                    .id(game.id)
                            }
                        }
                        .padding(.horizontal, 3)
                        .padding(.vertical, 4)
                    }
                    .onChange(of: selectedGame?.id) { _, id in
                        guard let id else { return }
                        withAnimation(.easeOut(duration: 0.18)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 34)
        .padding(.top, 4)
        .padding(.bottom, 10)
    }

    private func gameTile(_ game: Game, isSelected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                Button {
                    selectedGameID = game.id
                    if switchBuildSession.isBuilding, switchBuildSession.game?.id == game.id {
                        presentBuild(for: game)
                    }
                } label: {
                    GameArtwork(game: game)
                        .frame(width: 126, height: 150)
                        .overlay {
                            if switchBuildSession.isBuilding, switchBuildSession.game?.id == game.id {
                                buildProgressOverlay
                            }
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.primary.opacity(isSelected ? 0.98 : 0.15), lineWidth: isSelected ? 2.5 : 1)
                        }
                        .shadow(color: isSelected ? .black.opacity(0.35) : .clear, radius: 12, y: 5)
                }
                .buttonStyle(CursorButtonStyle())

                Button {
                    actionMenuGameID = game.id
                    actionMenuSelection = nil
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 27, height: 27)
                        .background(.black.opacity(0.62), in: Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.35)))
                }
                .buttonStyle(CursorButtonStyle())
                .padding(8)
                .help("更多操作")
                .accessibilityLabel("更多操作")
                .popover(isPresented: Binding(
                    get: { actionMenuGameID == game.id },
                    set: { if !$0 && actionMenuGameID == game.id { actionMenuGameID = nil } }
                ), attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
                    actionMenu(for: game)
                }
            }

            Text(game.displayTitle)
                .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(Color.primary.opacity(isSelected ? 1 : 0.72))
                .lineLimit(1)
                .frame(width: 126, alignment: .leading)
        }
        .scaleEffect(isSelected ? 1.025 : 1)
        .animation(.easeOut(duration: 0.16), value: isSelected)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
    }

    private var buildProgressOverlay: some View {
        ZStack {
            Color.black.opacity(0.76)
            VStack(spacing: 8) {
                if let fraction = switchBuildSession.progress.fraction {
                    ZStack {
                        Circle().stroke(.white.opacity(0.2), lineWidth: 3)
                        Circle().trim(from: 0, to: fraction)
                            .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Text("\(Int(fraction * 100))%")
                            .font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
                    }
                    .frame(width: 45, height: 45)
                } else {
                    ProgressView().controlSize(.regular).tint(.white).frame(height: 45)
                }
                Text(switchBuildSession.progress.stage)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                Text(switchBuildSession.progress.detail.isEmpty ? "正在处理游戏文件" : switchBuildSession.progress.detail)
                    .font(.system(size: 8))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text("点击查看详情")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .padding(8)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func actionMenu(for game: Game) -> some View {
        let items = actionMenuItems(for: game)
        return VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HoverMenuRow(isDestructive: item.destructive, isControllerFocused: actionMenuSelection == index, action: item.action) {
                    Label(item.title, systemImage: item.symbol)
                }
                .onHover { hovering in
                    if hovering { actionMenuSelection = nil }
                }
            }
        }
        .padding(10)
        .frame(width: 205)
        .background(Color.black.opacity(0.96), in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(.white.opacity(0.1), lineWidth: 1))
    }

    private var bottomHints: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "dpad").accessibilityHidden(true)
            Text(AppLanguage.localized(selectedGameRequiresBuild
                 ? "十字键/左摇杆浏览   LB/RB 切换平台   LT 收藏   A 详情   Y 选项   Menu/Options 设置   B 返回"
                 : "十字键/左摇杆浏览   LB/RB 切换平台   LT 收藏   X 游玩   A 详情   Y 选项   Menu/Options 设置   B 返回"))
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(Color.white)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bindGamepadActions() {
        gamepad.onMoveHorizontal = { direction in
            guard !isSettingsVisible else { return }
            if activeSheet != nil || buildGame != nil {
                controllerNavigation.send(.moveHorizontal(direction))
            } else if actionMenuGameID == nil && !isSettingsVisible {
                moveSelection(by: direction)
            }
        }
        gamepad.onMoveVertical = { direction in
            if isSettingsVisible {
                moveControllerVertical(by: direction)
            } else if activeSheet != nil || buildGame != nil {
                controllerNavigation.send(.moveVertical(direction))
            } else {
                moveControllerVertical(by: direction)
            }
        }
        gamepad.onPlay = { if actionMenuGameID == nil && !isSettingsVisible && activeSheet == nil && buildGame == nil { playSelected() } }
        gamepad.onDetails = {
            if actionMenuGameID != nil { activateActionMenuSelection() }
            else if isSettingsVisible { activateSettingsSelection() }
            else if activeSheet != nil || buildGame != nil { controllerNavigation.send(.confirm) }
            else if activeSheet == nil { showDetails() }
        }
        gamepad.onGameActions = {
            guard activeSheet == nil, buildGame == nil, !isSettingsVisible else { return }
            showSelectedGameActions()
        }
        gamepad.onFavorite = {
            guard actionMenuGameID == nil, !isSettingsVisible, activeSheet == nil, buildGame == nil,
                  let selectedGame else { return }
            library.toggleFavorite(for: selectedGame.id)
        }
        gamepad.onBack = {
            if actionMenuGameID != nil {
                actionMenuGameID = nil
            } else if activeSheet != nil {
                activeSheet = nil
            } else if isSettingsVisible {
                isSettingsVisible = false
            } else if buildGame != nil {
                buildGame = nil
            }
        }
        gamepad.onOptions = {
            guard activeSheet == nil, actionMenuGameID == nil else { return }
            isSettingsVisible = true
            settingsSelection = 0
        }
        gamepad.onNextPlatform = { movePlatform(by: 1) }
        gamepad.onPreviousPlatform = { movePlatform(by: -1) }
    }

    private func moveControllerVertical(by delta: Int) {
        if let gameID = actionMenuGameID, let game = library.games.first(where: { $0.id == gameID }) {
            let count = actionMenuItems(for: game).count
            guard count > 0 else { return }
            if let selection = actionMenuSelection {
                actionMenuSelection = min(max(selection + delta, 0), count - 1)
            } else {
                actionMenuSelection = delta < 0 ? count - 1 : 0
            }
        } else if isSettingsVisible {
            settingsSelection = min(max(settingsSelection + delta, 0), settingsItemCount - 1)
        }
    }

    private var settingsItemCount: Int { AppLanguage.allCases.count + 4 + (library.gameDirectoryPath == nil ? 0 : 1) }

    private func activateSettingsSelection() {
        let count = AppLanguage.allCases.count
        if settingsSelection < count {
            onLanguageChange(AppLanguage.allCases[settingsSelection])
        } else if settingsSelection == count {
            if let url = GameImporter.chooseGameDirectory() { library.setGameDirectory(url) }
        } else if settingsSelection == settingsItemCount - 1 {
            guard !switchBuildSession.isBuilding, !mobileBuildSession.isBuilding else { return }
            isSettingsVisible = false
            showingAppleSigning = true
        } else if settingsSelection == settingsItemCount - 2 {
            isSettingsVisible = false
            showingSaveSync = true
        } else if settingsSelection == settingsItemCount - 3 {
            launchExternalFullscreen.toggle()
        } else {
            library.scanGameDirectory(refreshAllMetadata: true, language: language.scrapeLanguage)
        }
    }

    private struct ActionMenuItem {
        let title: String
        let symbol: String
        var destructive = false
        let action: () -> Void
    }

    private func actionMenuItems(for game: Game) -> [ActionMenuItem] {
        var items = [ActionMenuItem(title: "游戏详情", symbol: "info.circle", action: { showDetails(for: game) })]
        if game.platform == .switchConsole {
            items.append(ActionMenuItem(title: "金手指", symbol: "curlybraces", action: { actionMenuGameID = nil; controllerNavigation.reset(); activeSheet = .cheats(game) }))
        }
        items.append(ActionMenuItem(title: "游玩记录", symbol: "clock.arrow.circlepath", action: { actionMenuGameID = nil; controllerNavigation.reset(); activeSheet = .history(game) }))
        if game.platform == .switchConsole {
            items.append(ActionMenuItem(title: "构建 Switch 游戏", symbol: "hammer", action: { actionMenuGameID = nil; presentBuild(for: game) }))
        }
        items.append(ActionMenuItem(title: "删除游戏", symbol: "trash", destructive: true, action: { removeFromLibrary(game) }))
        return items
    }

    private func activateActionMenuSelection() {
        guard let gameID = actionMenuGameID, let game = library.games.first(where: { $0.id == gameID }) else { return }
        let items = actionMenuItems(for: game)
        guard let selection = actionMenuSelection, items.indices.contains(selection) else { return }
        items[selection].action()
    }

    private func moveSelection(by delta: Int) {
        guard !visibleGames.isEmpty else { return }
        let currentIndex = visibleGames.firstIndex(where: { $0.id == selectedGame?.id }) ?? 0
        let nextIndex = (currentIndex + delta + visibleGames.count) % visibleGames.count
        selectedGameID = visibleGames[nextIndex].id
    }

    private func movePlatform(by delta: Int) {
        let filters: [LibraryFilter] = [.recent, .favorites] + GamePlatform.allCases.map(LibraryFilter.platform)
        let currentIndex = filters.firstIndex(of: libraryFilter) ?? 2
        let nextIndex = (currentIndex + delta + filters.count) % filters.count
        selectFilter(filters[nextIndex])
    }

    private func switchPlatform(to value: GamePlatform) {
        guard value != platform || libraryFilter != .platform(value) else { return }
        platform = value
        libraryFilter = .platform(value)
    }

    private func selectFilter(_ filter: LibraryFilter) {
        guard filter != libraryFilter else { return }
        if case .platform(let value) = filter {
            platform = value
        }
        libraryFilter = filter
    }

    private func filterButton(_ filter: LibraryFilter, title: String) -> some View {
        let isSelected = libraryFilter == filter
        return Button {
            selectFilter(filter)
        } label: {
            Text(AppLanguage.localized(title))
                .font(.system(size: 20, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.black : Color.white)
                .padding(.horizontal, 14)
                .frame(height: 40)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.white.opacity(0.94))
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(CursorButtonStyle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .id(filter.id)
    }

    private func playSelected() {
        guard let selectedGame, selectedGame.isDirectlyLaunchable else { return }
        launch(selectedGame)
    }

    private func showDetails() {
        guard let selectedGame else { return }
        controllerNavigation.reset()
        activeSheet = .details(selectedGame)
    }

    private func showDetails(for game: Game) {
        actionMenuGameID = nil
        controllerNavigation.reset()
        activeSheet = .details(game)
    }

    private func showSelectedGameActions() {
        guard let selectedGame else { return }
        actionMenuSelection = nil
        actionMenuGameID = selectedGame.id
    }

    private func removeFromLibrary(_ game: Game) {
        actionMenuGameID = nil
        if activeSheet?.game.id == game.id { activeSheet = nil }
        if selectedGameID == game.id { selectedGameID = nil }
        library.remove(game.id)
    }

    private func launch(_ game: Game) {
        launcher.launch(game, libraryRoot: library.gameDirectoryPath.map { URL(fileURLWithPath: $0) }) { result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    library.markPlayed(game.id)
                case .failure(let error):
                    launchError = error.localizedDescription
                    showingLaunchError = true
                }
            }
        }
    }
}

private struct CheatUnavailableView: View {
    let message: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 23))
                .foregroundStyle(.secondary)
            Text("无法打开金手指")
                .font(.system(size: 14, weight: .semibold))
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("完成") { dismiss() }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 16)
                .frame(height: 34)
                .background(GameCenterColors.action, in: RoundedRectangle(cornerRadius: 8))
                .buttonStyle(CursorButtonStyle())
        }
        .padding(20)
        .frame(width: 360, height: 190)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.dark)
        .overlay {
            OutsideClickDismissMonitor { dismiss() }
                .allowsHitTesting(false)
        }
    }
}

private struct GamePlayHistoryView: View {
    let game: Game
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 13) {
                GameArtwork(game: game)
                    .frame(width: 54, height: 70)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 5) {
                    Text("游玩记录")
                        .font(.system(size: 17, weight: .semibold))
                    Text(game.displayTitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }

            VStack(spacing: 0) {
                historyRow(
                    title: "最近游玩",
                    value: game.lastPlayedAt?.formatted(date: .long, time: .shortened) ?? "还没有游玩记录",
                    symbol: "clock"
                )
                Divider().overlay(.white.opacity(0.06))
                historyRow(
                    title: "加入游戏库",
                    value: game.addedAt.formatted(date: .long, time: .omitted),
                    symbol: "calendar"
                )
            }
            .padding(.horizontal, 13)
            .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.07), lineWidth: 1))

            Text("这里显示游戏库保存的最近游玩时间。")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .padding(22)
        .frame(width: 460, height: 280)
        .background(Color(nsColor: .windowBackgroundColor))
        .foregroundStyle(.primary)
        .preferredColorScheme(.dark)
        .overlay {
            OutsideClickDismissMonitor { dismiss() }
                .allowsHitTesting(false)
        }
    }

    private func historyRow(title: String, value: String, symbol: String) -> some View {
        HStack(spacing: 11) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(title)
                .font(.system(size: 11, weight: .medium))
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 13)
    }
}

private struct HoverMenuRow<Content: View>: View {
    var isDestructive = false
    var isControllerFocused = false
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var isHovered = false

    init(isDestructive: Bool = false, isControllerFocused: Bool = false, action: @escaping () -> Void, @ViewBuilder label: @escaping () -> Content) {
        self.isDestructive = isDestructive
        self.isControllerFocused = isControllerFocused
        self.action = action
        self.content = label
    }

    var body: some View {
        Button(action: action) {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .frame(height: 36)
                .foregroundStyle(isDestructive ? Color.red : Color.primary)
                .background {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isHovered || isControllerFocused ? Color.white.opacity(0.19) : Color.clear)
                }
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(CursorButtonStyle())
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}

struct CursorButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .pointingHandCursor()
    }
}

@MainActor
private final class GamepadManager: ObservableObject {
    @Published private(set) var controllerName: String?
    @Published private(set) var connectionVersion = 0

    var onMoveHorizontal: ((Int) -> Void)?
    var onMoveVertical: ((Int) -> Void)?
    var onPlay: (() -> Void)?
    var onDetails: (() -> Void)?
    var onGameActions: (() -> Void)?
    var onFavorite: (() -> Void)?
    var onBack: (() -> Void)?
    var onOptions: (() -> Void)?
    var onNextPlatform: (() -> Void)?
    var onPreviousPlatform: (() -> Void)?

    private weak var boundController: GCController?
    private var lastStickHorizontalDirection = 0
    private var lastStickVerticalDirection = 0

    func refresh() {
        let controller = GCController.controllers().first(where: { $0.extendedGamepad != nil })
        controllerName = controller?.vendorName ?? (controller == nil ? nil : AppLanguage.localized("手柄已连接"))
        guard controller !== boundController else { return }
        if let oldPad = boundController?.extendedGamepad {
            clearDirectionHandlers(oldPad.dpad)
            clearDirectionHandlers(oldPad.leftThumbstick)
            oldPad.buttonX.pressedChangedHandler = nil
            oldPad.buttonA.pressedChangedHandler = nil
            oldPad.buttonY.pressedChangedHandler = nil
            oldPad.buttonB.pressedChangedHandler = nil
            oldPad.buttonMenu.pressedChangedHandler = nil
            oldPad.buttonOptions?.pressedChangedHandler = nil
            oldPad.leftTrigger.pressedChangedHandler = nil
            oldPad.leftShoulder.pressedChangedHandler = nil
            oldPad.rightShoulder.pressedChangedHandler = nil
        }
        boundController = controller
        connectionVersion += 1
        guard let gamepad = controller?.extendedGamepad else { return }

        bindDirectionHandlers(gamepad.dpad)
        bindThumbstickHandler(gamepad.leftThumbstick)
        gamepad.buttonX.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { Task { @MainActor in self?.dispatchLibraryAction(self?.onPlay) } }
        }
        gamepad.buttonA.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { Task { @MainActor in self?.dispatchLibraryAction(self?.onDetails) } }
        }
        gamepad.buttonY.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { Task { @MainActor in self?.dispatchLibraryAction(self?.onGameActions) } }
        }
        gamepad.buttonB.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { Task { @MainActor in self?.dispatchLibraryAction(self?.onBack) } }
        }
        gamepad.buttonMenu.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { Task { @MainActor in self?.dispatchLibraryAction(self?.onOptions) } }
        }
        gamepad.buttonOptions?.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { Task { @MainActor in self?.dispatchLibraryAction(self?.onOptions) } }
        }
        gamepad.leftTrigger.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { Task { @MainActor in self?.dispatchLibraryAction(self?.onFavorite) } }
        }
        gamepad.leftShoulder.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { Task { @MainActor in self?.dispatchLibraryAction(self?.onPreviousPlatform) } }
        }
        gamepad.rightShoulder.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { Task { @MainActor in self?.dispatchLibraryAction(self?.onNextPlatform) } }
        }
    }

    @MainActor
    private func dispatchLibraryAction(_ action: (() -> Void)?) {
        guard NSApp.isActive, !EmbeddedPlayCoordinator.shared.hasKeyPlayWindow else { return }
        action?()
    }

    private func bindDirectionHandlers(_ directionPad: GCControllerDirectionPad) {
        directionPad.left.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { Task { @MainActor in self?.dispatchLibraryAction { self?.onMoveHorizontal?(-1) } } }
        }
        directionPad.right.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { Task { @MainActor in self?.dispatchLibraryAction { self?.onMoveHorizontal?(1) } } }
        }
        directionPad.up.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { Task { @MainActor in self?.dispatchLibraryAction { self?.onMoveVertical?(-1) } } }
        }
        directionPad.down.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { Task { @MainActor in self?.dispatchLibraryAction { self?.onMoveVertical?(1) } } }
        }
    }

    private func bindThumbstickHandler(_ thumbstick: GCControllerDirectionPad) {
        lastStickHorizontalDirection = 0
        lastStickVerticalDirection = 0
        thumbstick.valueChangedHandler = { [weak self] _, x, y in
            guard let self else { return }
            Task { @MainActor in
                guard NSApp.isActive, !EmbeddedPlayCoordinator.shared.hasKeyPlayWindow else { return }
                self.updateStickDirection(x, axis: &self.lastStickHorizontalDirection, callback: self.onMoveHorizontal)
                self.updateStickDirection(y, axis: &self.lastStickVerticalDirection, callback: self.onMoveVertical)
            }
        }
    }

    private func updateStickDirection(_ value: Float, axis: inout Int, callback: ((Int) -> Void)?) {
        let next = value > 0.58 ? 1 : (value < -0.58 ? -1 : 0)
        if next == 0 {
            if abs(value) < 0.25 { axis = 0 }
            return
        }
        guard next != axis else { return }
        axis = next
        callback?(next)
    }

    private func clearDirectionHandlers(_ directionPad: GCControllerDirectionPad) {
        directionPad.valueChangedHandler = nil
        directionPad.left.pressedChangedHandler = nil
        directionPad.right.pressedChangedHandler = nil
        directionPad.up.pressedChangedHandler = nil
        directionPad.down.pressedChangedHandler = nil
    }
}
