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
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool
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
    @State private var pendingRemoveGame: Game?
    @State private var windowSize = CGSize(width: 1000, height: 678)
    @AppStorage(MacCoreCatalog.externalFullscreenKey) private var launchExternalFullscreen = true
    @AppStorage("GameCenter.HideEmptyPlatforms") private var hideEmptyPlatforms = true
    @ObservedObject private var externalSession = ExternalGameSessionMonitor.shared
    @StateObject private var gamepad = GamepadManager()
    @StateObject private var controllerNavigation = ControllerNavigation()
    @Namespace private var platformPillNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let launcher = GameLaunchService()

    private var inverseColor: Color { Color(white: 0.06) }

    private var activePlatforms: [GamePlatform] {
        guard hideEmptyPlatforms else { return GamePlatform.allCases }
        let nonEmpty = GamePlatform.allCases.filter { count(for: $0) > 0 }
        return nonEmpty.isEmpty ? GamePlatform.allCases : nonEmpty
    }

    private var availableFilters: [LibraryFilter] {
        [.recent, .favorites] + activePlatforms.map(LibraryFilter.platform)
    }

    private var visibleGames: [Game] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = library.games.filter { game in
            guard game.platform.isEnabled else { return false }
            let matchesFilter: Bool = switch libraryFilter {
            case .all: true
            case .recent: game.lastPlayedAt != nil
            case .favorites: game.isFavorite
            case .platform(let value): game.platform == value
            }
            guard matchesFilter else { return false }
            if query.isEmpty { return true }
            return game.displayTitle.localizedCaseInsensitiveContains(query)
                || game.title.localizedCaseInsensitiveContains(query)
                || game.platform.shortTitle.localizedCaseInsensitiveContains(query)
                || game.platform.title.localizedCaseInsensitiveContains(query)
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

    private func revealInFinder(_ game: Game) {
        if let url = library.resolvedGameURL(for: game) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else if let path = library.gameDirectoryPath {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
    }

    private func requestRemove(_ game: Game) {
        actionMenuGameID = nil
        pendingRemoveGame = game
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
                activeSheet = nil
                pendingRemoveGame = currentGame
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

    private var gridColumnCount: Int {
        let usableWidth = max(windowSize.width - 72, 132)
        return max(1, Int((usableWidth + 18) / (132 + 18)))
    }

    var body: some View {
        GeometryReader { container in
            let footerHeight = max(container.size.height * 0.60, 336)
            let isCompactHero = container.size.height < 740
            ZStack {
                if let buildGame {
                    VStack(spacing: 0) {
                        Divider().opacity(0.25)
                        buildPage(for: buildGame)
                    }
                } else {
                    backdrop
                    VStack(spacing: 0) {
                        hero(compact: isCompactHero)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .padding(.horizontal, 36)

                        VStack(spacing: 0) {
                            platformPicker
                                .frame(height: 46)
                                .padding(.horizontal, 36)
                                .padding(.top, 14)

                            gameGrid
                                .frame(maxWidth: .infinity, maxHeight: .infinity)

                            if let runningTitle = externalSession.activeGameTitle {
                                externalSessionBanner(title: runningTitle)
                            }

                            if gamepad.controllerName != nil {
                                bottomHints
                                    .padding(.top, 4)
                                    .padding(.bottom, 12)
                                    .padding(.horizontal, 36)
                            }
                        }
                        .frame(height: footerHeight)
                        .background {
                            Rectangle()
                                .fill(.regularMaterial.opacity(0.55))
                                .mask {
                                    LinearGradient(
                                        stops: [
                                            .init(color: .clear, location: 0),
                                            .init(color: .black.opacity(0.32), location: 0.08),
                                            .init(color: .black.opacity(0.84), location: 0.22),
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
                                            .init(color: .black.opacity(0.16), location: 0.22),
                                            .init(color: .black.opacity(0.38), location: 1)
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
        .overlay {
            LibraryKeyEventMonitor(
                isActive: {
                    activeSheet == nil
                        && !showingAppleSigning
                        && !showingSaveSync
                        && pendingRemoveGame == nil
                        && !EmbeddedPlayCoordinator.shared.hasKeyPlayWindow
                },
                onFind: {
                    guard buildGame == nil else { return }
                    isSearchFocused = true
                },
                onEscape: {
                    if !searchText.isEmpty || isSearchFocused {
                        searchText = ""
                        isSearchFocused = false
                        return true
                    }
                    if actionMenuGameID != nil {
                        actionMenuGameID = nil
                        return true
                    }
                    if isSettingsVisible {
                        isSettingsVisible = false
                        return true
                    }
                    if buildGame != nil && !switchBuildSession.isBuilding {
                        buildGame = nil
                        return true
                    }
                    return false
                },
                onMoveHorizontal: { delta in
                    guard buildGame == nil, !isSearchFocused, actionMenuGameID == nil, !isSettingsVisible else { return false }
                    moveSelection(by: delta)
                    return true
                },
                onMoveVertical: { delta in
                    guard buildGame == nil, !isSearchFocused, actionMenuGameID == nil, !isSettingsVisible else { return false }
                    moveSelectionVertically(by: delta)
                    return true
                },
                onConfirm: {
                    guard buildGame == nil, !isSearchFocused, actionMenuGameID == nil, !isSettingsVisible, let selectedGame else { return false }
                    if selectedGame.isDirectlyLaunchable {
                        launch(selectedGame)
                    } else if selectedGame.platform == .switchConsole {
                        presentBuild(for: selectedGame)
                    }
                    return true
                }
            )
            .allowsHitTesting(false)
        }
        .toolbar { libraryToolbar }
        .toolbarBackground(.hidden, for: .windowToolbar)
        .background {
            if buildGame != nil {
                Color(white: 0.075).ignoresSafeArea()
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
                _ = try MacSaveSync.slots(root: path)
                return URL(fileURLWithPath: path).lastPathComponent.lowercased() == "switch"
                    ? URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("save")
                    : URL(fileURLWithPath: path).appendingPathComponent("save")
            },
                              isPlaying: { MacSaveSync.isPlaying(root: library.gameDirectoryPath) })
        }
        .confirmationDialog(
            AppLanguage.localized("从资料库移除游戏？"),
            isPresented: Binding(
                get: { pendingRemoveGame != nil },
                set: { if !$0 { pendingRemoveGame = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(AppLanguage.localized("确认移除"), role: .destructive) {
                if let game = pendingRemoveGame {
                    removeFromLibrary(game)
                }
                pendingRemoveGame = nil
            }
            Button(AppLanguage.localized("取消"), role: .cancel) {
                pendingRemoveGame = nil
            }
        } message: {
            if let game = pendingRemoveGame {
                Text("确定将「\(game.displayTitle)」从列表移除？磁盘上的原始游戏文件不会被删除。")
            }
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
        .onChange(of: hideEmptyPlatforms) { _, _ in
            if !availableFilters.contains(libraryFilter) {
                libraryFilter = .recent
            }
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

    private func count(for filter: LibraryFilter) -> Int {
        switch filter {
        case .all: library.games.filter { $0.platform.isEnabled }.count
        case .recent: library.games.filter { $0.platform.isEnabled && $0.lastPlayedAt != nil }.count
        case .favorites: library.games.filter { $0.platform.isEnabled && $0.isFavorite }.count
        case .platform(let value): count(for: value)
        }
    }

    private func externalSessionBanner(title runningTitle: String) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(BuildPalette.ready)
                .frame(width: 7, height: 7)
            Text("运行中：\(runningTitle)（\(externalSession.activePlatformName ?? "")）· 长按手柄 Menu+Options 退出返回")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
            Spacer(minLength: 8)
            Button("切回游戏") { externalSession.focusExternalGame() }
                .buttonStyle(TactileActionButtonStyle(appearance: .secondary, cornerRadius: 8, minHeight: 28, horizontalPadding: 10, fontSize: 11))
            Button("结束游戏") { externalSession.terminateExternalGameAndReturn() }
                .buttonStyle(TactileActionButtonStyle(appearance: .destructive, cornerRadius: 8, minHeight: 28, horizontalPadding: 10, fontSize: 11))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.14), lineWidth: 1))
        .padding(.horizontal, 36)
        .padding(.bottom, 6)
    }

    private var backdrop: some View {
        GeometryReader { geometry in
            ZStack {
                Color(white: 0.055)
                if let selectedGame {
                    GameArtwork(game: selectedGame, compact: true)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .transition(.opacity)
                } else {
                    LinearGradient(
                        colors: [Color(white: 0.14), Color(white: 0.055)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
                LinearGradient(stops: [
                    .init(color: .black.opacity(0.76), location: 0),
                    .init(color: .black.opacity(0.40), location: 0.42),
                    .init(color: .black.opacity(0.05), location: 0.80)
                ], startPoint: .leading, endPoint: .trailing)
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.58), location: 0),
                        .init(color: .black.opacity(0.20), location: 0.20),
                        .init(color: .black.opacity(0.10), location: 0.46),
                        .init(color: .black.opacity(0.44), location: 0.70),
                        .init(color: .black.opacity(0.90), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .overlay(alignment: .topTrailing) {
                RadialGradient(colors: [.black.opacity(0.42), .clear], center: .topTrailing,
                               startRadius: 0, endRadius: 380)
                    .frame(width: 380, height: 380).allowsHitTesting(false)
            }
            .clipped()
            .ignoresSafeArea()
        }
        .ignoresSafeArea()
        .animation(reduceMotion ? nil : .easeOut(duration: 0.28), value: selectedGame?.id)
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
        HStack(spacing: 9) {
            if buildGame != nil {
                Button {
                    buildGame = nil
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                        Text(AppLanguage.localized("返回"))
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(Color.white.opacity(0.09), in: Capsule())
                    .overlay(Capsule().stroke(Color.white.opacity(0.11), lineWidth: 1))
                }
                .buttonStyle(CursorButtonStyle())
            }
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .renderingMode(.original).resizable().scaledToFit()
                .frame(width: 24, height: 24).accessibilityHidden(true)
            Text("GAME CENTER")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .tracking(1.3)
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.45), radius: 4, y: 1)
    }

    private var toolbarActions: some View {
        HStack(spacing: 10) {
            if switchBuildSession.isBuilding && buildGame == nil {
                Button {
                    if let game = switchBuildSession.game { presentBuild(for: game) }
                } label: {
                    HStack(spacing: 7) {
                        if let fraction = switchBuildSession.overallFraction {
                            ProgressView(value: fraction)
                                .progressViewStyle(.linear)
                                .tint(.white)
                                .frame(width: 38)
                        } else {
                            ProgressView().controlSize(.mini).tint(.white)
                        }
                        Text(buildStatusTitle)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        if let fraction = switchBuildSession.overallFraction {
                            Text("\(Int(fraction * 100))%")
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 11)
                    .frame(height: 30)
                    .background(.white.opacity(0.12), in: Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.14), lineWidth: 1))
                }
                .buttonStyle(CursorButtonStyle())
                .help(AppLanguage.localized("查看构建进度"))
                .accessibilityLabel(AppLanguage.localized("查看构建进度"))
            }

            if buildGame == nil {
                searchField
            }

            gamepadIndicator

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
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .frame(width: 30, height: 30)
                    .background(.white.opacity(isSettingsVisible ? 0.18 : 0.09), in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.11), lineWidth: 1))
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

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.62))
            TextField(AppLanguage.localized("搜索"), text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .focused($isSearchFocused)
                .frame(width: isSearchFocused || !searchText.isEmpty ? 136 : 92)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .buttonStyle(PlainHandButtonStyle())
                .help(AppLanguage.localized("关闭搜索"))
            } else if !isSearchFocused {
                Text("⌘F")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.42))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1.5)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Color.black.opacity(isSearchFocused ? 0.42 : 0.24), in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(isSearchFocused ? 0.28 : 0.11), lineWidth: 1))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isSearchFocused)
    }

    private var gamepadIndicator: some View {
        HStack(spacing: 6) {
            Image(systemName: "gamecontroller")
                .font(.system(size: 12, weight: .medium))
            if let name = gamepad.controllerName {
                Text(name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(.white.opacity(gamepad.controllerName == nil ? 0.48 : 0.92))
        .padding(.horizontal, gamepad.controllerName == nil ? 8 : 11)
        .frame(height: 30)
        .background(Color.white.opacity(gamepad.controllerName == nil ? 0.06 : 0.12), in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(gamepad.controllerName == nil ? 0.08 : 0.14), lineWidth: 1))
        .help(gamepad.controllerName ?? AppLanguage.localized("未连接手柄"))
        .accessibilityLabel(gamepad.controllerName ?? AppLanguage.localized("未连接手柄"))
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
        VStack(alignment: .leading, spacing: 12) {
            Text("设置")
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 4)

            VStack(alignment: .leading, spacing: 6) {
                Text("语言")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                ForEach(Array(AppLanguage.allCases.enumerated()), id: \.offset) { index, value in
                    HoverMenuRow(isControllerFocused: isSettingsVisible && settingsSelection == index) {
                        onLanguageChange(value)
                    } label: {
                        HStack {
                            Label(AppLanguage.localized(value.titleKey), systemImage: language == value ? "checkmark" : "character.bubble")
                            Spacer()
                        }
                    }
                }
            }

            Divider().opacity(0.45)

            VStack(alignment: .leading, spacing: 4) {
                HoverMenuRow(isControllerFocused: isSettingsVisible && settingsSelection == AppLanguage.allCases.count) {
                    if let url = GameImporter.chooseGameDirectory() {
                        library.setGameDirectory(url)
                    }
                } label: {
                    Label(library.gameDirectoryPath == nil ? "选择游戏文件夹…" : "更改游戏文件夹…", systemImage: "folder")
                }
                if let gameDirectoryPath = library.gameDirectoryPath {
                    Text(gameDirectoryPath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 2)
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
            }

            Divider().opacity(0.45)

            VStack(alignment: .leading, spacing: 4) {
                HoverMenuRow(isControllerFocused: isSettingsVisible && settingsSelection == settingsItemCount - 4) {
                    hideEmptyPlatforms.toggle()
                } label: {
                    Label(
                        hideEmptyPlatforms ? "隐藏空平台：开" : "隐藏空平台：关",
                        systemImage: hideEmptyPlatforms ? "eye.slash" : "eye"
                    )
                }
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
        }
        .padding(14)
        .frame(width: 260)
        .preferredColorScheme(.dark)
    }

    private func hero(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 8)

            if let selectedGame {
                HStack(alignment: .center, spacing: 30) {
                    VStack(alignment: .leading, spacing: compact ? 8 : 11) {
                        HStack(spacing: 8) {
                            Text(selectedGame.platform.title.uppercased())
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .tracking(1.3)
                                .foregroundStyle(.white.opacity(0.92))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 3.5)
                                .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                                )

                            if selectedGameRequiresBuild {
                                Text("需先构建")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(BuildPalette.building)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3.5)
                                    .background(BuildPalette.building.opacity(0.15), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .stroke(BuildPalette.building.opacity(0.28), lineWidth: 1)
                                    )
                            }
                        }

                        Text(selectedGame.displayTitle)
                            .font(.system(size: compact ? 30 : 34, weight: .bold, design: .rounded))
                            .tracking(-0.6)
                            .lineLimit(compact ? 1 : 2)
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.28), radius: 12, y: 2)

                        if let synopsis = selectedGame.synopsis, !synopsis.isEmpty {
                            Text(synopsis)
                                .font(.system(size: 12.5))
                                .foregroundStyle(.white.opacity(0.76))
                                .lineLimit(compact ? 1 : 2)
                                .lineSpacing(2.5)
                        }

                        HStack(spacing: 10) {
                            Text(AppLanguage.localized(selectedGame.isFavorite ? "已收藏" : "游戏库"))
                            Text("·")
                            Text(AppLanguage.localized(selectedGame.lastPlayedAt.map {
                                AppLanguage.format("上次游玩 %@", $0.formatted(date: .abbreviated, time: .omitted))
                            } ?? "尚未游玩"))
                            Text("·")
                            Text(AppLanguage.format("%d 款游戏", visibleGames.count))
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.62))

                        HStack(spacing: 10) {
                            if selectedGame.isDirectlyLaunchable {
                                Button(action: playSelected) {
                                    Label("开始游玩", systemImage: "play.fill")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(inverseColor)
                                        .padding(.horizontal, 19)
                                        .frame(height: 38)
                                        .background(GameCenterColors.action, in: Capsule())
                                }
                                .buttonStyle(CursorButtonStyle())
                            }

                            if selectedGame.platform == .switchConsole {
                                let isPrimaryBuild = !selectedGame.isDirectlyLaunchable
                                Button { presentBuild(for: selectedGame) } label: {
                                    Label(isPrimaryBuild ? "构建 Switch 游戏" : "构建版本", systemImage: "hammer")
                                        .font(.system(size: 13, weight: isPrimaryBuild ? .semibold : .medium))
                                        .foregroundStyle(isPrimaryBuild ? inverseColor : .white)
                                        .padding(.horizontal, isPrimaryBuild ? 19 : 16)
                                        .frame(height: 38)
                                        .background(
                                            isPrimaryBuild ? GameCenterColors.action : Color.white.opacity(0.11),
                                            in: Capsule()
                                        )
                                        .overlay {
                                            if !isPrimaryBuild {
                                                Capsule().stroke(Color.white.opacity(0.15), lineWidth: 1)
                                            }
                                        }
                                }
                                .buttonStyle(CursorButtonStyle())
                            }

                            Button { showDetails(for: selectedGame) } label: {
                                Text(AppLanguage.localized("详情"))
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.92))
                                    .padding(.horizontal, 15)
                                    .frame(height: 38)
                                    .background(Color.white.opacity(0.10), in: Capsule())
                                    .overlay(Capsule().stroke(Color.white.opacity(0.13), lineWidth: 1))
                            }
                            .buttonStyle(CursorButtonStyle())

                            Button {
                                library.toggleFavorite(for: selectedGame.id)
                            } label: {
                                Image(systemName: selectedGame.isFavorite ? "heart.fill" : "heart")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(selectedGame.isFavorite ? GameCenterColors.favoriteForeground : .white.opacity(0.9))
                                    .frame(width: 38, height: 38)
                                    .background(
                                        selectedGame.isFavorite ? GameCenterColors.favoriteBackground : Color.white.opacity(0.10),
                                        in: Circle()
                                    )
                                    .overlay(
                                        Circle().stroke(
                                            selectedGame.isFavorite ? GameCenterColors.favoriteBorder : Color.white.opacity(0.13),
                                            lineWidth: 1
                                        )
                                    )
                            }
                            .buttonStyle(CursorButtonStyle())
                            .help(AppLanguage.localized(selectedGame.isFavorite ? "取消收藏" : "加入收藏"))
                        }
                        .padding(.top, 2)
                    }
                    .frame(maxWidth: 540, alignment: .leading)

                    Spacer(minLength: 0)
                }
                .id(selectedGame.id)
                .transition(.opacity)
            } else {
                emptyHero
            }

            Spacer(minLength: 10)
        }
        .padding(.top, 4)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: selectedGame?.id)
    }

    private var emptyHero: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(libraryFilter.title.uppercased())
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(1.6)
                .foregroundStyle(.white.opacity(0.68))
            Text(AppLanguage.localized(!searchText.isEmpty ? "没有找到匹配的游戏" : (libraryFilter == .recent ? "还没有游玩记录" : libraryFilter == .favorites ? "还没有收藏的游戏" : "这个平台还没有游戏")))
                .font(.system(size: 30, weight: .semibold, design: .rounded))
            Text(AppLanguage.localized(!searchText.isEmpty
                 ? "换个关键词试试，或切换到其他平台。"
                 : (libraryFilter == .recent ? "启动过的游戏会按最近游玩时间排列在这里。" : libraryFilter == .favorites ? "收藏的游戏会集中显示在这里。" : library.gameDirectoryPath == nil ? "选择游戏库根目录，每个平台的游戏放在对应的子文件夹内。" : "已监控游戏目录，放入对应平台文件夹后会自动识别。")))
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.72))

            if case .platform(let value) = libraryFilter, GamePlatform.macSystems[value] != nil, searchText.isEmpty {
                Text(AppLanguage.format("游戏子文件夹：%@", value.id))
                    .font(.callout.monospaced())
            }

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Text("清除搜索")
                }
                .buttonStyle(TactileActionButtonStyle(appearance: .secondary, cornerRadius: 999, minHeight: 36, horizontalPadding: 16, fontSize: 12))
                .padding(.top, 4)
            } else if visibleGames.isEmpty && library.gameDirectoryPath == nil {
                Button {
                    if let url = GameImporter.chooseGameDirectory() {
                        library.setGameDirectory(url)
                    }
                } label: {
                    Label("选择游戏文件夹", systemImage: "folder")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(inverseColor)
                        .padding(.horizontal, 18)
                        .frame(height: 38)
                        .background(GameCenterColors.action, in: Capsule())
                }
                .buttonStyle(CursorButtonStyle())
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 20)
    }

    private var platformPicker: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(availableFilters, id: \.id) { filter in
                        filterButton(filter)
                    }
                }
                .padding(.trailing, 24)
                .padding(.vertical, 2)
            }
            .mask(trailingFadeMask)
            .onChange(of: libraryFilter) { _, value in
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) {
                    proxy.scrollTo(value.id, anchor: .center)
                }
            }
        }
    }

    private var trailingFadeMask: some View {
        LinearGradient(
            stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: 0.95),
                .init(color: .clear, location: 1)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private var verticalFadeMask: some View {
        LinearGradient(
            stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: 0.94),
                .init(color: .clear, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var gameGrid: some View {
        let columns = Array(repeating: GridItem(.fixed(132), spacing: 18, alignment: .top), count: gridColumnCount)
        return Group {
            if visibleGames.isEmpty {
                HStack(spacing: 9) {
                    Image(systemName: "square.stack.3d.up")
                    Text(AppLanguage.localized("扫描到的游戏封面会排列在这里"))
                }
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.52))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.top, 18)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                            ForEach(visibleGames) { game in
                                GameCoverTile(
                                    game: game,
                                    cardWidth: 132,
                                    cardHeight: 160,
                                    isSelected: game.id == selectedGame?.id,
                                    isBuildingThisGame: switchBuildSession.isBuilding && switchBuildSession.game?.id == game.id,
                                    isMenuOpen: actionMenuGameID == game.id,
                                    buildOverlay: { buildProgressOverlay },
                                    actionMenu: { actionMenu(for: game) },
                                    onSelect: {
                                        selectedGameID = game.id
                                        if switchBuildSession.isBuilding, switchBuildSession.game?.id == game.id {
                                            presentBuild(for: game)
                                        }
                                    },
                                    onDoubleClick: {
                                        selectedGameID = game.id
                                        if game.isDirectlyLaunchable {
                                            launch(game)
                                        } else if game.platform == .switchConsole {
                                            presentBuild(for: game)
                                        }
                                    },
                                    onOpenMenu: {
                                        actionMenuGameID = game.id
                                        actionMenuSelection = nil
                                    },
                                    onCloseMenu: {
                                        if actionMenuGameID == game.id { actionMenuGameID = nil }
                                    },
                                    contextMenuItems: {
                                        Button("游戏详情", systemImage: "info.circle") { showDetails(for: game) }
                                        if game.isDirectlyLaunchable {
                                            Button("开始游玩", systemImage: "play.fill") { launch(game) }
                                        }
                                        if game.platform == .switchConsole {
                                            Button("金手指", systemImage: "curlybraces") {
                                                controllerNavigation.reset()
                                                activeSheet = .cheats(game)
                                            }
                                            Button("构建 Switch 游戏", systemImage: "hammer") {
                                                presentBuild(for: game)
                                            }
                                        }
                                        Button("游玩记录", systemImage: "clock.arrow.circlepath") {
                                            controllerNavigation.reset()
                                            activeSheet = .history(game)
                                        }
                                        Button("在访达中显示", systemImage: "folder") { revealInFinder(game) }
                                        Divider()
                                        Button(game.isFavorite ? "取消收藏" : "加入收藏", systemImage: game.isFavorite ? "heart.slash" : "heart") {
                                            library.toggleFavorite(for: game.id)
                                        }
                                        Divider()
                                        Button("从资料库移除…", systemImage: "trash", role: .destructive) {
                                            requestRemove(game)
                                        }
                                    }
                                )
                                .id(game.id)
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.top, 12)
                        .padding(.bottom, 20)
                    }
                    .mask(verticalFadeMask)
                    .padding(.horizontal, -6)
                    .onChange(of: selectedGame?.id) { _, id in
                        guard let id else { return }
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 36)
        .padding(.top, 2)
        .padding(.bottom, 6)
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
                    .frame(width: 44, height: 44)
                } else {
                    ProgressView().controlSize(.regular).tint(.white).frame(height: 44)
                }
                Text(switchBuildSession.progress.stage)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Text(switchBuildSession.progress.detail.isEmpty ? "正在处理游戏文件" : switchBuildSession.progress.detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text("点击查看详情")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .padding(10)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func actionMenu(for game: Game) -> some View {
        let items = actionMenuItems(for: game)
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if item.destructive && index > 0 {
                    Divider().opacity(0.45).padding(.vertical, 2)
                }
                HoverMenuRow(isDestructive: item.destructive, isControllerFocused: actionMenuSelection == index, action: item.action) {
                    Label(item.title, systemImage: item.symbol)
                }
                .onHover { hovering in
                    if hovering { actionMenuSelection = nil }
                }
            }
        }
        .padding(8)
        .frame(width: 210)
        .preferredColorScheme(.dark)
    }

    private var bottomHints: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "dpad").accessibilityHidden(true)
            Text(AppLanguage.localized(selectedGameRequiresBuild
                 ? "十字键/左摇杆浏览   LB/RB 切换平台   LT 收藏   A 详情   Y 选项   Menu/Options 设置   B 返回"
                 : "十字键/左摇杆浏览   LB/RB 切换平台   LT 收藏   X 游玩   A 详情   Y 选项   Menu/Options 设置   B 返回"))
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.white.opacity(0.76))
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
        } else {
            moveSelectionVertically(by: delta)
        }
    }

    private func moveSelectionVertically(by rowDelta: Int) {
        guard !visibleGames.isEmpty else { return }
        let currentIndex = visibleGames.firstIndex(where: { $0.id == selectedGame?.id }) ?? 0
        let target = currentIndex + rowDelta * gridColumnCount
        guard visibleGames.indices.contains(target) else { return }
        selectedGameID = visibleGames[target].id
    }

    private var settingsItemCount: Int { AppLanguage.allCases.count + 5 + (library.gameDirectoryPath == nil ? 0 : 1) }

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
        } else if settingsSelection == settingsItemCount - 4 {
            hideEmptyPlatforms.toggle()
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
        items.append(ActionMenuItem(title: "在访达中显示", symbol: "folder", action: { actionMenuGameID = nil; revealInFinder(game) }))
        if game.platform == .switchConsole {
            items.append(ActionMenuItem(title: "构建 Switch 游戏", symbol: "hammer", action: { actionMenuGameID = nil; presentBuild(for: game) }))
        }
        items.append(ActionMenuItem(title: "从资料库移除…", symbol: "trash", destructive: true, action: { requestRemove(game) }))
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
        let filters = availableFilters
        let currentIndex = filters.firstIndex(of: libraryFilter) ?? 0
        let nextIndex = (currentIndex + delta + filters.count) % filters.count
        selectFilter(filters[nextIndex])
    }

    private func selectFilter(_ filter: LibraryFilter) {
        guard filter != libraryFilter else { return }
        withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.86)) {
            if case .platform(let value) = filter {
                platform = value
            }
            libraryFilter = filter
        }
    }

    private func title(for filter: LibraryFilter) -> String {
        switch filter {
        case .all: AppLanguage.localized("全部游戏")
        case .recent: AppLanguage.localized("最近游玩")
        case .favorites: AppLanguage.localized("收藏")
        case .platform(let value): AppLanguage.localized(value.shortTitle == "macOS" ? "Mac 游戏" : value.shortTitle)
        }
    }

    private func filterButton(_ filter: LibraryFilter) -> some View {
        let isSelected = libraryFilter == filter
        let itemCount = count(for: filter)
        return PlatformTabButton(
            title: title(for: filter),
            count: itemCount,
            isSelected: isSelected,
            namespace: platformPillNamespace,
            action: { selectFilter(filter) }
        )
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

private struct PlatformTabButton: View {
    let title: String
    let count: Int
    let isSelected: Bool
    let namespace: Namespace.ID
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 14, weight: isSelected ? .semibold : .medium))
                Text("\(count)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(isSelected ? Color.black.opacity(0.55) : Color.white.opacity(0.42))
            }
            .foregroundStyle(isSelected ? Color(white: 0.06) : Color.white.opacity(isHovered ? 0.96 : 0.72))
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(GameCenterColors.action)
                        .matchedGeometryEffect(id: "activePlatformPill", in: namespace)
                } else if isHovered {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.09))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(CursorButtonStyle())
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isHovered)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct GameCoverTile<BuildOverlay: View, ActionMenu: View, ContextMenuContent: View>: View {
    let game: Game
    let cardWidth: CGFloat
    let cardHeight: CGFloat
    let isSelected: Bool
    let isBuildingThisGame: Bool
    let isMenuOpen: Bool
    @ViewBuilder let buildOverlay: () -> BuildOverlay
    @ViewBuilder let actionMenu: () -> ActionMenu
    let onSelect: () -> Void
    let onDoubleClick: () -> Void
    let onOpenMenu: () -> Void
    let onCloseMenu: () -> Void
    @ViewBuilder let contextMenuItems: () -> ContextMenuContent

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                ZStack(alignment: .topTrailing) {
                    GameArtwork(game: game, showPlatformBadge: false)
                        .frame(width: cardWidth, height: cardHeight)
                        .overlay {
                            if isBuildingThisGame {
                                buildOverlay()
                            }
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(
                                    Color.white.opacity(isSelected ? 0.96 : (isHovered ? 0.42 : 0.14)),
                                    lineWidth: isSelected ? 2 : 1
                                )
                        }
                        .shadow(
                            color: isSelected ? .black.opacity(0.55) : (isHovered ? .black.opacity(0.35) : .clear),
                            radius: isSelected ? 14 : 10,
                            y: isSelected ? 6 : 4
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .onTapGesture(count: 2, perform: onDoubleClick)
                        .onTapGesture(count: 1, perform: onSelect)
                        .pointingHandCursor()

                    if game.isFavorite {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(GameCenterColors.favoriteForeground)
                            .padding(9)
                            .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                            .allowsHitTesting(false)
                    }
                }

                Button(action: onOpenMenu) {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(.black.opacity(0.68), in: Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.28), lineWidth: 1))
                }
                .buttonStyle(CursorButtonStyle())
                .padding(9)
                .opacity(isHovered || isSelected || isMenuOpen ? 1 : 0)
                .allowsHitTesting(isHovered || isSelected || isMenuOpen)
                .help("更多操作")
                .accessibilityLabel("更多操作")
                .popover(isPresented: Binding(
                    get: { isMenuOpen },
                    set: { if !$0 { onCloseMenu() } }
                ), attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
                    actionMenu()
                }
            }

            Text(game.displayTitle)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(.white.opacity(isSelected ? 1 : (isHovered ? 0.92 : 0.72)))
                .lineLimit(1)
                .frame(width: cardWidth, alignment: .leading)
        }
        .offset(y: (isSelected || isHovered) && !reduceMotion ? -4 : 0)
        .scaleEffect(isSelected && !reduceMotion ? 1.03 : 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isSelected)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isHovered)
        .onHover { isHovered = $0 }
        .contextMenu { contextMenuItems() }
        .accessibilityElement(children: .contain)
    }
}

private struct LibraryKeyEventMonitor: NSViewRepresentable {
    let isActive: () -> Bool
    let onFind: () -> Void
    let onEscape: () -> Bool
    let onMoveHorizontal: (Int) -> Bool
    let onMoveVertical: (Int) -> Bool
    let onConfirm: () -> Bool

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        updateCallbacks(on: view)
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        updateCallbacks(on: view)
        view.installIfNeeded()
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) {
        view.removeMonitor()
    }

    private func updateCallbacks(on view: MonitorView) {
        view.isActive = isActive
        view.onFind = onFind
        view.onEscape = onEscape
        view.onMoveHorizontal = onMoveHorizontal
        view.onMoveVertical = onMoveVertical
        view.onConfirm = onConfirm
    }

    final class MonitorView: NSView {
        var isActive: () -> Bool = { false }
        var onFind: () -> Void = {}
        var onEscape: () -> Bool = { false }
        var onMoveHorizontal: (Int) -> Bool = { _ in false }
        var onMoveVertical: (Int) -> Bool = { _ in false }
        var onConfirm: () -> Bool = { false }
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            installIfNeeded()
        }

        func installIfNeeded() {
            guard monitor == nil, window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window, self.isActive() else {
                    return event
                }
                let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "f" {
                    DispatchQueue.main.async { self.onFind() }
                    return nil
                }
                if event.keyCode == 53 { // Escape
                    if self.onEscape() { return nil }
                    return event
                }
                if window.firstResponder is NSTextView {
                    return event
                }
                guard modifiers.isDisjoint(with: [.command, .control, .option]) else { return event }
                switch event.keyCode {
                case 123: // Left arrow
                    return self.onMoveHorizontal(-1) ? nil : event
                case 124: // Right arrow
                    return self.onMoveHorizontal(1) ? nil : event
                case 125: // Down arrow
                    return self.onMoveVertical(1) ? nil : event
                case 126: // Up arrow
                    return self.onMoveVertical(-1) ? nil : event
                case 36, 76: // Return / Enter
                    return self.onConfirm() ? nil : event
                default:
                    return event
                }
            }
        }

        func removeMonitor() {
            guard let monitor else { return }
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }

        deinit {
            removeMonitor()
        }
    }
}

private struct CheatUnavailableView: View {
    let message: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Spacer()
                SheetCloseButton { dismiss() }
            }
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
            Text("无法打开金手指")
                .font(.system(size: 15, weight: .semibold))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("完成") { dismiss() }
                .buttonStyle(TactileActionButtonStyle(appearance: .primary, minHeight: 34, horizontalPadding: 18, fontSize: 12))
                .keyboardShortcut(.defaultAction)
        }
        .padding(20)
        .frame(width: 370, height: 220)
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
            HStack(alignment: .center, spacing: 14) {
                GameArtwork(game: game, showPlatformBadge: false)
                    .frame(width: 54, height: 70)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 5) {
                    Text("游玩记录")
                        .font(.system(size: 17, weight: .semibold))
                    Text(game.displayTitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                SheetCloseButton { dismiss() }
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
            .padding(.horizontal, 14)
            .background(GameCenterColors.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(GameCenterColors.border, lineWidth: 1))

            Text("这里显示游戏库保存的最近游玩时间。")
                .font(.system(size: 11))
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
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(title)
                .font(.system(size: 12, weight: .medium))
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 12))
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(isDestructive: Bool = false, isControllerFocused: Bool = false, action: @escaping () -> Void, @ViewBuilder label: @escaping () -> Content) {
        self.isDestructive = isDestructive
        self.isControllerFocused = isControllerFocused
        self.action = action
        self.content = label
    }

    var body: some View {
        Button(action: action) {
            content()
                .font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .frame(height: 34)
                .foregroundStyle(isDestructive ? GameCenterColors.destructiveForeground : Color.primary)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isHovered || isControllerFocused ? (isDestructive ? GameCenterColors.destructiveBackground : Color.white.opacity(0.14)) : Color.clear)
                }
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(CursorButtonStyle())
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovered)
    }
}

struct CursorButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
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
