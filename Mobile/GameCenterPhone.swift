import GameController
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@objc(ShellLibrary)
final class ShellLibrary: NSObject {
    @MainActor @objc(makeControllerWithInitialURL:)
    static func makeController(initialURL: URL?) -> UIViewController {
        UIHostingController(rootView: LibraryView())
    }

    @MainActor @objc static func handleOpenURL(_ url: URL) -> Bool { false }
}

private enum PhoneTheme {
    static let action = Color(white: 0.94)
    static let inverseText = Color(white: 0.06)
    static let surface = Color.white.opacity(0.055)
    static let border = Color.white.opacity(0.11)
    static let favoriteForeground = Color(red: 1.0, green: 0.52, blue: 0.58)
    static let favoriteBackground = Color.red.opacity(0.20)
    static let favoriteBorder = Color.red.opacity(0.36)
    static let destructiveForeground = Color(red: 1.0, green: 0.52, blue: 0.56)
    static let destructiveBackground = Color.red.opacity(0.14)
    static let destructiveBorder = Color.red.opacity(0.28)
    static let ready = Color(red: 0.28, green: 0.84, blue: 0.50)
}

@MainActor
private enum PhoneHaptics {
    static let light = UIImpactFeedbackGenerator(style: .light)
    static let medium = UIImpactFeedbackGenerator(style: .medium)
    static let selection = UISelectionFeedbackGenerator()
}

private enum PhoneFilter: Hashable, Identifiable {
    case recent
    case favorites
    case platform(String)

    var id: String {
        switch self {
        case .recent: "recent"
        case .favorites: "favorites"
        case .platform(let value): "platform:" + value
        }
    }
}

private struct LibraryView: View {
    @StateObject private var metadata = PhoneGameMetadata()
    @StateObject private var gamepad = PhoneGamepadNavigator()

    @State private var library: PhoneLibrary?
    @State private var roms: [PhoneLibrary.ROM] = []
    @State private var switchGames: [PhoneLibrary.SwitchGame] = []
    @State private var activeFilter: PhoneFilter = .recent
    @State private var selectedEntryID: String?
    @State private var searchText = ""
    @State private var showingPortraitSearch = false
    @FocusState private var searchFocused: Bool

    @State private var importing = false
    @State private var refreshing = false
    @State private var importingFiles = false
    @State private var notice: String?
    @State private var selectedROM: PhoneLibrary.ROM?
    @State private var detailEntry: Entry?
    @State private var pendingDeleteEntry: Entry?
    @State private var showingSaveSync = false

    @AppStorage("phone.library.favorites") private var favoriteData = Data()
    @AppStorage("museum.recent") private var recentData = Data()
    @AppStorage("phone.library.hideEmptyPlatforms") private var hideEmptyPlatforms = true
    @State private var cachedFavorites: Set<String> = []
    @State private var cachedRecentIDs: [String] = []
    @Namespace private var filterPillNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var switchPackageType: UTType {
        UTType(exportedAs: "com.phoenixicarus.gamecenter.switch-build", conformingTo: .package)
    }

    private enum Entry: Identifiable, Hashable {
        case rom(PhoneLibrary.ROM, String)
        case console(PhoneLibrary.SwitchGame)

        var id: String {
            switch self {
            case let .rom(_, path): "rom:" + path
            case let .console(game): "switch:" + game.id
            }
        }

        var title: String {
            switch self {
            case let .rom(rom, _): rom.title
            case let .console(game): game.title
            }
        }

        var platformID: String {
            switch self {
            case let .rom(rom, _): rom.platform.id
            case .console: "switch"
            }
        }

        var platformTitle: String {
            switch self {
            case let .rom(rom, _): rom.platform.name
            case .console: "Nintendo Switch"
            }
        }

        var shortLabel: String {
            switch self {
            case let .rom(rom, _): rom.platform.folder.uppercased()
            case .console: "SWITCH"
            }
        }

        var isLaunchable: Bool {
            switch self {
            case .rom: true
            case let .console(game): !game.builds.isEmpty
            }
        }

        var isDeletable: Bool {
            switch self {
            case .rom: true
            case let .console(game): !game.builds.isEmpty
            }
        }

        static func == (lhs: Entry, rhs: Entry) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    private struct LibrarySnapshot {
        let allEntries: [Entry]
        let entriesByID: [String: Entry]
        let favorites: Set<String>
        let recentCount: Int
        let favoritesCount: Int
        let platformCounts: [String: Int]
        let visibleFilters: [PhoneFilter]
        let visibleEntries: [Entry]
        let selectedEntry: Entry?

        func count(for filter: PhoneFilter) -> Int {
            switch filter {
            case .recent: recentCount
            case .favorites: favoritesCount
            case let .platform(id): platformCounts[id] ?? 0
            }
        }
    }

    private var favorites: Set<String> { cachedFavorites }
    private var recentIDs: [String] { cachedRecentIDs }

    private var allPlatforms: [(id: String, name: String, short: String)] {
        [("switch", "Nintendo Switch", "Switch")] + (library?.platforms.map {
            ($0.id, $0.name, shortPlatformName(for: $0.id, fallback: $0.folder))
        } ?? [])
    }

    private func makeSnapshot() -> LibrarySnapshot {
        let rootComponentCount = library?.root.pathComponents.count ?? 0
        var entries: [Entry] = []
        entries.reserveCapacity(switchGames.count + roms.count)
        for game in switchGames {
            entries.append(.console(game))
        }
        for rom in roms {
            let path = rom.url.pathComponents.dropFirst(rootComponentCount).joined(separator: "/")
            entries.append(.rom(rom, path))
        }

        var entriesByID: [String: Entry] = Dictionary(minimumCapacity: entries.count)
        var platformCounts: [String: Int] = [:]
        var favoritesCount = 0
        let favs = cachedFavorites
        for entry in entries {
            entriesByID[entry.id] = entry
            platformCounts[entry.platformID, default: 0] += 1
            if favs.contains(entry.id) { favoritesCount += 1 }
        }
        let recentMatches = cachedRecentIDs.compactMap { entriesByID[$0] }

        let platforms = allPlatforms
        let nonEmpty = platforms.filter { (platformCounts[$0.id] ?? 0) > 0 }
        let platformsToShow = (hideEmptyPlatforms && !nonEmpty.isEmpty) ? nonEmpty : platforms
        let filters: [PhoneFilter] = [.recent, .favorites] + platformsToShow.map { .platform($0.id) }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseList: [Entry]
        switch activeFilter {
        case .recent:
            baseList = recentMatches
        case .favorites:
            baseList = entries
                .filter { favs.contains($0.id) }
                .sorted { displayTitle($0).localizedStandardCompare(displayTitle($1)) == .orderedAscending }
        case let .platform(id):
            baseList = entries
                .filter { $0.platformID == id }
                .sorted { displayTitle($0).localizedStandardCompare(displayTitle($1)) == .orderedAscending }
        }
        let visible: [Entry]
        if query.isEmpty {
            visible = baseList
        } else {
            visible = baseList.filter { entry in
                displayTitle(entry).localizedCaseInsensitiveContains(query)
                    || entry.title.localizedCaseInsensitiveContains(query)
                    || entry.platformTitle.localizedCaseInsensitiveContains(query)
                    || entry.shortLabel.localizedCaseInsensitiveContains(query)
            }
        }
        let selected = visible.first(where: { $0.id == selectedEntryID }) ?? visible.first
        return LibrarySnapshot(
            allEntries: entries,
            entriesByID: entriesByID,
            favorites: favs,
            recentCount: recentMatches.count,
            favoritesCount: favoritesCount,
            platformCounts: platformCounts,
            visibleFilters: filters,
            visibleEntries: visible,
            selectedEntry: selected
        )
    }

    private var visibleFilters: [PhoneFilter] { makeSnapshot().visibleFilters }

    private var activeImportPlatform: PhoneLibrary.Format.Platform? {
        guard case let .platform(id) = activeFilter else { return nil }
        return library?.platforms.first { $0.id == id }
    }

    private var visibleEntries: [Entry] { makeSnapshot().visibleEntries }

    private var selectedEntry: Entry? { makeSnapshot().selectedEntry }

    var body: some View {
        let snapshot = makeSnapshot()
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height
            let gridColumnsCount = isLandscape
                ? max(4, Int((geometry.size.width - 48) / 118))
                : (geometry.size.width >= 600 ? 5 : 3)

            ZStack {
                backdrop(size: geometry.size, isLandscape: isLandscape, selectedEntry: snapshot.selectedEntry)

                VStack(spacing: 0) {
                    topBar(isLandscape: isLandscape)

                    if showingPortraitSearch && !isLandscape {
                        portraitSearchBar
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    if isLandscape {
                        landscapeHero(entry: snapshot.selectedEntry)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                            .padding(.horizontal, 24)
                    } else {
                        portraitHero(entry: snapshot.selectedEntry)
                            .padding(.horizontal, 20)
                            .padding(.top, 10)
                            .padding(.bottom, 14)
                    }

                    bottomDock(
                        isLandscape: isLandscape,
                        dockHeight: isLandscape ? max(geometry.size.height * 0.60, 210) : nil,
                        columnsCount: gridColumnsCount,
                        snapshot: snapshot
                    )
                }
            }
            .onChange(of: snapshot.selectedEntry?.id) { _, _ in
                if let entry = snapshot.selectedEntry {
                    metadata.prioritize(lookupTarget(for: entry))
                }
            }
            .onChange(of: snapshot.visibleEntries.map(\.id)) { _, ids in
                if !(selectedEntryID.map(ids.contains) ?? false) {
                    selectedEntryID = ids.first
                }
            }
            .onChange(of: activeFilter) { _, _ in
                selectedEntryID = makeSnapshot().visibleEntries.first?.id
            }
            .onChange(of: hideEmptyPlatforms) { _, _ in
                if !makeSnapshot().visibleFilters.contains(activeFilter) {
                    activeFilter = .recent
                }
            }
            .onChange(of: gamepad.connectionVersion) { _, _ in
                bindGamepad(columnsCount: gridColumnsCount)
            }
            .onChange(of: gridColumnsCount) { _, count in
                bindGamepad(columnsCount: count)
            }
            .onAppear {
                cachedFavorites = (try? JSONDecoder().decode(Set<String>.self, from: favoriteData)) ?? []
                cachedRecentIDs = (try? JSONDecoder().decode([String].self, from: recentData)) ?? []
                gamepad.refresh()
                bindGamepad(columnsCount: gridColumnsCount)
            }
            .onChange(of: favoriteData) { _, data in
                cachedFavorites = (try? JSONDecoder().decode(Set<String>.self, from: data)) ?? []
            }
            .onChange(of: recentData) { _, data in
                cachedRecentIDs = (try? JSONDecoder().decode([String].self, from: data)) ?? []
            }
        }
        .background(Color(white: 0.045).ignoresSafeArea())
        .preferredColorScheme(.dark)
        .tint(.white)
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("DMShellDidReturnToLibrary"))) { _ in
            Task { await refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in
            gamepad.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) { _ in
            gamepad.refresh()
        }
        .sheet(item: $detailEntry) { entry in
            detailSheet(for: entry)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(26)
                .presentationBackground(.ultraThinMaterial)
        }
        .sheet(isPresented: $showingSaveSync) {
            CloudSaveSyncView(
                saveRoot: {
                    guard let library else { throw CloudSaveDirectorySync.Failure("游戏库尚未准备好，请稍后重试。") }
                    try library.createFolders()
                    return library.root.appendingPathComponent("save")
                },
                isPlaying: { gc_s2arm_active() != 0 || dm_shell_active_game_id() != nil || selectedROM != nil }
            )
        }
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: [switchPackageType, .json, .data, .folder],
            allowsMultipleSelection: true
        ) { result in
            Task { await handleImport(result) }
        }
        .fullScreenCover(item: $selectedROM) { rom in
            if let library {
                if rom.platform.runtime == "cemu" {
                    WiiUPlayer(rom: rom, library: library)
                } else {
                    RetroPlayer(rom: rom, library: library)
                }
            }
        }
        .confirmationDialog(
            "从设备删除游戏？",
            isPresented: Binding(
                get: { pendingDeleteEntry != nil },
                set: { if !$0 { pendingDeleteEntry = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("确认删除", role: .destructive) {
                if let entry = pendingDeleteEntry {
                    deleteEntry(entry)
                }
                pendingDeleteEntry = nil
            }
            Button("取消", role: .cancel) {
                pendingDeleteEntry = nil
            }
        } message: {
            if let entry = pendingDeleteEntry {
                Text("将删除「\(displayTitle(entry))」的游戏文件或构建包，你的游戏存档会安全保留在 save 目录中。")
            }
        }
        .alert("Game Center", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("好", role: .cancel) { notice = nil }
        } message: {
            Text(notice ?? "")
        }
    }

    // MARK: - Backdrop

    private func backdrop(size: CGSize, isLandscape: Bool, selectedEntry: Entry?) -> some View {
        ZStack {
            Color(white: 0.045)
            if let entry = selectedEntry, let image = backdropImage(for: entry) {
                let shouldBlur = !MetadataRefreshPolicy.isWideImage(width: image.size.width, height: image.size.height) && isLandscape
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .scaleEffect(shouldBlur ? 1.12 : 1.0)
                    .blur(radius: shouldBlur ? 18 : 0)
                    .clipped()
                    .transition(.opacity)
            } else if let entry = selectedEntry {
                LinearGradient(colors: placeholderPalette(for: entry), startPoint: .topLeading, endPoint: .bottomTrailing)
                    .transition(.opacity)
            } else {
                LinearGradient(colors: [Color(white: 0.12), Color(white: 0.045)], startPoint: .topLeading, endPoint: .bottomTrailing)
            }

            if isLandscape {
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.78), location: 0),
                        .init(color: .black.opacity(0.40), location: 0.44),
                        .init(color: .black.opacity(0.08), location: 0.82)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }

            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.55), location: 0),
                    .init(color: .black.opacity(0.18), location: 0.24),
                    .init(color: .black.opacity(0.54), location: 0.56),
                    .init(color: .black.opacity(0.95), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
        .animation(reduceMotion ? nil : .easeOut(duration: 0.28), value: selectedEntry?.id)
    }

    // MARK: - Top Bar

    private func topBar(isLandscape: Bool) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.28, green: 0.31, blue: 0.90), Color(red: 0.76, green: 0.23, blue: 0.84), Color(red: 1.0, green: 0.60, blue: 0.51)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 24, height: 24)
                    .overlay {
                        Text("GC")
                            .font(.system(size: 11, weight: .black, design: .rounded))
                            .foregroundStyle(.white)
                    }
                Text("GAME CENTER")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .tracking(1.3)
                    .foregroundStyle(.white.opacity(0.95))
            }

            Spacer(minLength: 8)

            if isLandscape {
                landscapeSearchPill
                if let name = gamepad.controllerName {
                    Label(name, systemImage: "gamecontroller.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .frame(height: 32)
                        .background(Color.white.opacity(0.12), in: Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1))
                }
            } else {
                topCircleButton(icon: showingPortraitSearch ? "xmark" : "magnifyingglass", label: "搜索") {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                        showingPortraitSearch.toggle()
                        if showingPortraitSearch {
                            searchFocused = true
                        } else {
                            searchText = ""
                            searchFocused = false
                        }
                    }
                }
            }

            if isLandscape {
                Button {
                    importing = true
                } label: {
                    Label(importingFiles ? "导入中…" : "导入", systemImage: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.92))
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background(Color.white.opacity(0.10), in: Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.13), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(library == nil || refreshing || importingFiles)
            } else {
                topCircleButton(icon: "plus", label: "导入游戏") {
                    importing = true
                }
                .disabled(library == nil || refreshing || importingFiles)
            }

            topCircleButton(icon: "arrow.triangle.2.circlepath.icloud", label: "同步存档") {
                showingSaveSync = true
            }

            Menu {
                Toggle("隐藏空平台", isOn: $hideEmptyPlatforms)
                Button("刷新游戏库", systemImage: "arrow.clockwise") {
                    Task { await refresh() }
                }
                Button("刷新全部游戏资料", systemImage: "photo.on.rectangle.angled") {
                    let targets = makeSnapshot().allEntries.map(lookupTarget)
                    metadata.enqueueMissing(for: targets, force: true)
                }
                Button("同步存档 (iCloud)", systemImage: "arrow.triangle.2.circlepath.icloud") {
                    showingSaveSync = true
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 34, height: 34)
                    .background(Color.white.opacity(0.10), in: Circle())
                    .overlay(Circle().stroke(Color.white.opacity(0.13), lineWidth: 1))
            }
            .accessibilityLabel("更多设置")
        }
        .padding(.horizontal, isLandscape ? 24 : 20)
        .padding(.top, isLandscape ? 8 : 6)
        .padding(.bottom, 4)
    }

    private func topCircleButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .frame(width: 34, height: 34)
                .background(Color.white.opacity(0.10), in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.13), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var landscapeSearchPill: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
            TextField("搜索游戏…", text: $searchText)
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .focused($searchFocused)
                .frame(width: 120)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 32)
        .background(Color.black.opacity(0.32), in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1))
    }

    private var portraitSearchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.55))
            TextField("搜索游戏名或平台…", text: $searchText)
                .font(.system(size: 14))
                .foregroundStyle(.white)
                .focused($searchFocused)
                .submitLabel(.search)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(0.55))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(Color.black.opacity(0.42), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.16), lineWidth: 1))
        .padding(.horizontal, 20)
        .padding(.top, 6)
    }

    // MARK: - Hero (Portrait & Landscape)

    private func portraitHero(entry: Entry?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let entry {
                HStack(spacing: 8) {
                    Text(entry.platformTitle.uppercased())
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .tracking(1.2)
                        .foregroundStyle(.white.opacity(0.92))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3.5)
                        .background(Color.white.opacity(0.13), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 1))

                    if !entry.isLaunchable {
                        Text("未导入构建包")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3.5)
                            .background(Color.orange.opacity(0.16), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }

                Text(displayTitle(entry))
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .tracking(-0.4)
                    .lineLimit(2)
                    .foregroundStyle(.white)

                if let synopsis = metadata.records[entry.id]?.synopsis, !synopsis.isEmpty {
                    Text(synopsis)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.74))
                        .lineLimit(2)
                        .lineSpacing(2)
                }

                HStack(spacing: 10) {
                    Button {
                        launchOrInspect(entry)
                    } label: {
                        Label(entry.isLaunchable ? "开始游玩" : "查看导入说明", systemImage: entry.isLaunchable ? "play.fill" : "info.circle")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(PhoneTheme.inverseText)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .background(PhoneTheme.action, in: Capsule())
                    }
                    .buttonStyle(.plain)

                    Button {
                        detailEntry = entry
                    } label: {
                        Text("详情")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white.opacity(0.92))
                            .padding(.horizontal, 18)
                            .frame(height: 44)
                            .background(Color.white.opacity(0.11), in: Capsule())
                            .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1))
                    }
                    .buttonStyle(.plain)

                    favoriteButton(for: entry, size: 44)
                }
                .padding(.top, 2)
            } else {
                emptyHero(compact: false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func landscapeHero(entry: Entry?) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if let entry {
                HStack(spacing: 8) {
                    Text(entry.platformTitle.uppercased())
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .tracking(1.2)
                        .foregroundStyle(.white.opacity(0.92))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.white.opacity(0.13), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    if !entry.isLaunchable {
                        Text("未导入构建包")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.orange)
                    }
                }

                Text(displayTitle(entry))
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                    .tracking(-0.4)
                    .lineLimit(1)
                    .foregroundStyle(.white)

                if let synopsis = metadata.records[entry.id]?.synopsis, !synopsis.isEmpty {
                    Text(synopsis)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                }

                HStack(spacing: 9) {
                    Button {
                        launchOrInspect(entry)
                    } label: {
                        Label(entry.isLaunchable ? "开始游玩" : "查看详情", systemImage: entry.isLaunchable ? "play.fill" : "info.circle")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(PhoneTheme.inverseText)
                            .padding(.horizontal, 18)
                            .frame(height: 36)
                            .background(PhoneTheme.action, in: Capsule())
                    }
                    .buttonStyle(.plain)

                    Button {
                        detailEntry = entry
                    } label: {
                        Text("详情")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.92))
                            .padding(.horizontal, 15)
                            .frame(height: 36)
                            .background(Color.white.opacity(0.11), in: Capsule())
                            .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1))
                    }
                    .buttonStyle(.plain)

                    favoriteButton(for: entry, size: 36)
                }
                .padding(.top, 2)
            } else {
                emptyHero(compact: true)
            }
        }
        .frame(maxWidth: 480, alignment: .leading)
    }

    private func emptyHero(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 10) {
            Text(filterTitle(activeFilter).uppercased())
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(1.4)
                .foregroundStyle(.white.opacity(0.55))
            Text(!searchText.isEmpty ? "没有找到匹配的游戏" : (activeFilter == .recent ? "还没有游玩记录" : activeFilter == .favorites ? "还没有收藏的游戏" : "这个平台还没有游戏"))
                .font(.system(size: compact ? 20 : 24, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text(!searchText.isEmpty ? "换个关键词试试，或切换到其他平台。" : "点击右上角「＋」导入 ROM 或 Switch .gcimport 游戏包，或通过「文件」App 放入 GameLibrary 目录。")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.65))
                .lineLimit(2)

            if !searchText.isEmpty {
                Button("清除搜索") { searchText = "" }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .background(Color.white.opacity(0.12), in: Capsule())
                    .buttonStyle(.plain)
            } else if activeFilter != .favorites {
                Button {
                    importing = true
                } label: {
                    Label("导入游戏", systemImage: "square.and.arrow.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(PhoneTheme.inverseText)
                        .padding(.horizontal, 16)
                        .frame(height: 36)
                        .background(PhoneTheme.action, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func favoriteButton(for entry: Entry, size: CGFloat) -> some View {
        let isFav = favorites.contains(entry.id)
        return Button {
            toggleFavorite(entry)
        } label: {
            Image(systemName: isFav ? "heart.fill" : "heart")
                .font(.system(size: size > 40 ? 15 : 13, weight: .semibold))
                .foregroundStyle(isFav ? PhoneTheme.favoriteForeground : .white.opacity(0.9))
                .frame(width: size, height: size)
                .background(isFav ? PhoneTheme.favoriteBackground : Color.white.opacity(0.10), in: Circle())
                .overlay(Circle().stroke(isFav ? PhoneTheme.favoriteBorder : Color.white.opacity(0.14), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isFav ? "取消收藏" : "加入收藏")
    }

    // MARK: - Bottom Glass Dock (Platform Tabs + Pure Multi-Row Grid)

    private func bottomDock(isLandscape: Bool, dockHeight: CGFloat?, columnsCount: Int, snapshot: LibrarySnapshot) -> some View {
        let horizontalInset: CGFloat = isLandscape ? 24 : 20
        let columns = Array(repeating: GridItem(.flexible(), spacing: isLandscape ? 14 : 12, alignment: .top), count: columnsCount)

        return VStack(spacing: 0) {
            // Sliding Platform Tabs (trailing fade only — leading edge stays 100% crisp)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(snapshot.visibleFilters) { filter in
                            let isSelected = activeFilter == filter
                            Button {
                                PhoneHaptics.light.impactOccurred()
                                withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.86)) {
                                    activeFilter = filter
                                }
                            } label: {
                                HStack(spacing: 5) {
                                    Text(filterTitle(filter))
                                        .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                                    Text("\(snapshot.count(for: filter))")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(isSelected ? Color.black.opacity(0.52) : Color.white.opacity(0.42))
                                }
                                .foregroundStyle(isSelected ? PhoneTheme.inverseText : Color.white.opacity(0.76))
                                .padding(.horizontal, 12)
                                .frame(height: 34)
                                .background {
                                    if isSelected {
                                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                                            .fill(PhoneTheme.action)
                                            .matchedGeometryEffect(id: "phoneFilterPill", in: filterPillNamespace)
                                    } else {
                                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                                            .fill(Color.white.opacity(0.06))
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .id(filter.id)
                        }
                    }
                    .padding(.trailing, 24)
                    .padding(.vertical, 2)
                }
                .mask(trailingFadeMask)
                .onChange(of: activeFilter) { _, value in
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                        proxy.scrollTo(value.id, anchor: .center)
                    }
                }
            }
            .padding(.horizontal, horizontalInset)
            .padding(.top, isLandscape ? 10 : 12)
            .padding(.bottom, 6)

            // Multi-row Pure Cover Grid (no redundant header row, no top-left platform badge)
            if snapshot.visibleEntries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(.white.opacity(0.36))
                    Text("导入后的游戏封面会整齐排列在这里")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.48))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVGrid(columns: columns, spacing: isLandscape ? 14 : 16) {
                            ForEach(snapshot.visibleEntries) { entry in
                                coverTile(
                                    entry: entry,
                                    isSelected: entry.id == snapshot.selectedEntry?.id,
                                    isFavorite: snapshot.favorites.contains(entry.id)
                                )
                                .id(entry.id)
                            }
                        }
                        .padding(.horizontal, horizontalInset)
                        .padding(.top, 8)
                        .padding(.bottom, isLandscape ? 16 : 28)
                    }
                    .mask(bottomFadeMask)
                    .onChange(of: snapshot.selectedEntry?.id) { _, id in
                        guard let id else { return }
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }

            if isLandscape && gamepad.controllerName != nil {
                HStack(spacing: 14) {
                    Text("◀▶▲▼ 浏览")
                    Text("LB/RB 切换平台")
                    Text("A 开始游玩")
                    Text("X 详情")
                    Text("Y 收藏")
                    Spacer()
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.62))
                .padding(.horizontal, horizontalInset)
                .padding(.bottom, 6)
            }
        }
        .frame(height: dockHeight)
        .frame(maxHeight: dockHeight == nil ? .infinity : nil)
        .background {
            Rectangle()
                .fill(.regularMaterial.opacity(0.55))
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black.opacity(0.45), location: 0.06),
                            .init(color: .black, location: 0.20),
                            .init(color: .black, location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black.opacity(0.24), location: 0.16),
                            .init(color: .black.opacity(0.55), location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .ignoresSafeArea(edges: .bottom)
        }
    }

    private func coverTile(entry: Entry, isSelected: Bool, isFavorite isFav: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                coverArtView(entry: entry, cornerRadius: 11)
                    .aspectRatio(0.8, contentMode: .fit)
                    .overlay {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(
                                Color.white.opacity(isSelected ? 0.96 : 0.14),
                                lineWidth: isSelected ? 2 : 1
                            )
                    }
                    .shadow(color: isSelected ? .black.opacity(0.55) : .clear, radius: 10, y: 4)

                if isFav {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(PhoneTheme.favoriteForeground)
                        .padding(7)
                        .shadow(color: .black.opacity(0.55), radius: 3, y: 1)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .onTapGesture {
                if isSelected {
                    launchOrInspect(entry)
                } else {
                    PhoneHaptics.selection.selectionChanged()
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                        selectedEntryID = entry.id
                    }
                }
            }
            .contextMenu {
                if entry.isLaunchable {
                    Button("开始游玩", systemImage: "play.fill") { launchOrInspect(entry) }
                }
                Button("游戏详情", systemImage: "info.circle") { detailEntry = entry }
                Button(isFav ? "取消收藏" : "加入收藏", systemImage: isFav ? "heart.slash" : "heart") {
                    toggleFavorite(entry)
                }
                Button("刷新游戏资料", systemImage: "arrow.clockwise") {
                    Task { await lookupMetadata(entry, force: true) }
                }
                if entry.isDeletable {
                    Divider()
                    Button("从设备删除…", systemImage: "trash", role: .destructive) {
                        pendingDeleteEntry = entry
                    }
                }
            }

            Text(displayTitle(entry))
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(.white.opacity(isSelected ? 1 : 0.72))
                .lineLimit(1)
        }
        .scaleEffect(isSelected && !reduceMotion ? 1.02 : 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isSelected)
    }

    private func coverArtView(entry: Entry, cornerRadius: CGFloat) -> some View {
        ZStack {
            if let image = coverImage(for: entry) {
                Color.clear
                    .overlay {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    }
            } else {
                LinearGradient(colors: placeholderPalette(for: entry), startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(
                    colors: [.white.opacity(0.18), .clear],
                    center: .topTrailing,
                    startRadius: 2,
                    endRadius: 90
                )
                Image(systemName: platformSymbol(for: entry.platformID))
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.white.opacity(0.84))
            }
        }
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    // MARK: - Unified Dark Detail Sheet

    private func detailSheet(for entry: Entry) -> some View {
        let isFav = favorites.contains(entry.id)
        return VStack(spacing: 0) {
            HStack {
                Text("游戏详情")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button {
                    detailEntry = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 30, height: 30)
                        .background(Color.white.opacity(0.10), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭")
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 12)

            Divider().overlay(PhoneTheme.border)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top, spacing: 16) {
                        coverArtView(entry: entry, cornerRadius: 12)
                            .frame(width: 96, height: 120)
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.14), lineWidth: 1))

                        VStack(alignment: .leading, spacing: 8) {
                            Text(displayTitle(entry))
                                .font(.system(size: 20, weight: .bold, design: .rounded))
                                .fixedSize(horizontal: false, vertical: true)
                                .lineLimit(3)

                            Text(entry.platformTitle)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.65))

                            if case let .console(game) = entry {
                                Text(game.status)
                                    .font(.system(size: 12))
                                    .foregroundStyle(game.builds.isEmpty ? Color.orange : PhoneTheme.ready)
                            } else if case let .rom(rom, _) = entry, let note = rom.platform.runtimeNote {
                                Text(note)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white.opacity(0.55))
                            }

                            HStack(spacing: 8) {
                                Button {
                                    toggleFavorite(entry)
                                } label: {
                                    Label(isFav ? "已收藏" : "收藏", systemImage: isFav ? "heart.fill" : "heart")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(isFav ? PhoneTheme.favoriteForeground : .white)
                                        .padding(.horizontal, 12)
                                        .frame(height: 34)
                                        .background(isFav ? PhoneTheme.favoriteBackground : Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(isFav ? PhoneTheme.favoriteBorder : Color.white.opacity(0.13), lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.top, 2)
                        }
                        Spacer(minLength: 0)
                    }

                    // Launch Action(s)
                    switch entry {
                    case let .rom(rom, _):
                        Button {
                            detailEntry = nil
                            remember(entry)
                            selectedROM = rom
                        } label: {
                            Label("开始游戏", systemImage: "play.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(PhoneTheme.inverseText)
                                .frame(maxWidth: .infinity)
                                .frame(height: 46)
                                .background(PhoneTheme.action, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                        }
                        .buttonStyle(.plain)

                    case let .console(game):
                        if game.builds.isEmpty {
                            HStack(spacing: 10) {
                                Image(systemName: "desktopcomputer")
                                    .foregroundStyle(.white.opacity(0.75))
                                Text("尚未导入此游戏的 iOS 构建包。请在 Mac 端 Game Center 构建 .gcimport 后，点右上角「＋」导入。")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white.opacity(0.68))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(PhoneTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(PhoneTheme.border, lineWidth: 1))
                        } else if game.builds.count == 1, let build = game.builds.first {
                            Button {
                                detailEntry = nil
                                launchSwitch(build, entry: entry)
                            } label: {
                                Label("运行游戏 (\(build.engine.rawValue))", systemImage: "play.fill")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(PhoneTheme.inverseText)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 46)
                                    .background(PhoneTheme.action, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("选择运行引擎")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.55))
                                HStack(spacing: 10) {
                                    ForEach(Array(game.builds.enumerated()), id: \.element.engine) { idx, build in
                                        Button {
                                            detailEntry = nil
                                            launchSwitch(build, entry: entry)
                                        } label: {
                                            Label(build.engine.rawValue, systemImage: "play.fill")
                                                .font(.system(size: 14, weight: .semibold))
                                                .foregroundStyle(idx == 0 ? PhoneTheme.inverseText : .white)
                                                .frame(maxWidth: .infinity)
                                                .frame(height: 44)
                                                .background(idx == 0 ? PhoneTheme.action : Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(idx == 0 ? 0 : 0.14), lineWidth: 1))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }

                    PhoneMetadataSection(metadata: metadata, id: entry.id) {
                        Task { await lookupMetadata(entry, force: true) }
                    }

                    if entry.isDeletable {
                        Button {
                            detailEntry = nil
                            pendingDeleteEntry = entry
                        } label: {
                            Label("从设备删除游戏…", systemImage: "trash")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(PhoneTheme.destructiveForeground)
                                .frame(maxWidth: .infinity)
                                .frame(height: 42)
                                .background(PhoneTheme.destructiveBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(PhoneTheme.destructiveBorder, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(20)
            }
        }
        .preferredColorScheme(.dark)
        .task(id: entry.id) { await lookupMetadata(entry) }
    }

    // MARK: - Helpers & Masks

    private var trailingFadeMask: some View {
        LinearGradient(
            stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: 0.92),
                .init(color: .clear, location: 1)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private var bottomFadeMask: some View {
        LinearGradient(
            stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: 0.92),
                .init(color: .clear, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func filterTitle(_ filter: PhoneFilter) -> String {
        switch filter {
        case .recent: "最近游玩"
        case .favorites: "收藏"
        case let .platform(id): allPlatforms.first(where: { $0.id == id })?.short ?? id.uppercased()
        }
    }

    private func count(for filter: PhoneFilter) -> Int {
        makeSnapshot().count(for: filter)
    }

    private func shortPlatformName(for id: String, fallback: String) -> String {
        switch id {
        case "threeDS": "3DS"
        case "famicom": "FC"
        case "superFamicom": "SFC"
        case "megaDrive": "MD"
        case "wiiu": "Wii U"
        case "psv": "PS Vita"
        default: fallback.uppercased()
        }
    }

    private func platformSymbol(for id: String) -> String {
        switch id {
        case "nds", "threeDS": "rectangle.split.2x1.fill"
        case "switch", "gba", "gb", "gbc", "psp", "psv": "gamecontroller.fill"
        default: "opticaldisc.fill"
        }
    }

    private func placeholderPalette(for entry: Entry) -> [Color] {
        let key = displayTitle(entry).lowercased()
        if key.contains("zelda") || key.contains("塞尔达") || key.contains("pokemon") || key.contains("宝可梦") {
            return [Color(red: 0.16, green: 0.44, blue: 0.36), Color(red: 0.06, green: 0.16, blue: 0.16)]
        }
        if key.contains("mario") || key.contains("马力欧") || key.contains("metroid") {
            return [Color(red: 0.66, green: 0.20, blue: 0.22), Color(red: 0.18, green: 0.08, blue: 0.14)]
        }
        let palettes: [[Color]] = [
            [Color(red: 0.18, green: 0.30, blue: 0.44), Color(red: 0.07, green: 0.11, blue: 0.18)],
            [Color(red: 0.36, green: 0.22, blue: 0.44), Color(red: 0.11, green: 0.07, blue: 0.16)],
            [Color(red: 0.42, green: 0.28, blue: 0.18), Color(red: 0.14, green: 0.10, blue: 0.08)],
            [Color(red: 0.18, green: 0.38, blue: 0.32), Color(red: 0.07, green: 0.14, blue: 0.13)]
        ]
        let hash = entry.title.utf8.reduce(0) { ($0 + Int($1)) % palettes.count }
        return palettes[hash]
    }

    private func coverImage(for entry: Entry) -> UIImage? {
        if let cached = metadata.image(for: entry.id, backdrop: false) { return cached }
        guard case let .console(game) = entry else { return nil }
        return metadata.bundledImage(named: game.coverName)
    }

    private func backdropImage(for entry: Entry) -> UIImage? {
        if let cached = metadata.image(for: entry.id, backdrop: true) { return cached }
        guard case let .console(game) = entry else { return nil }
        return metadata.bundledImage(named: game.coverName)
    }

    private func displayTitle(_ entry: Entry) -> String {
        metadata.records[entry.id]?.title ?? entry.title
    }

    private func remember(_ entry: Entry) {
        let updated = Array(([entry.id] + cachedRecentIDs.filter { $0 != entry.id }).prefix(100))
        cachedRecentIDs = updated
        recentData = (try? JSONEncoder().encode(updated)) ?? Data()
    }

    private func toggleFavorite(_ entry: Entry) {
        PhoneHaptics.light.impactOccurred()
        var updated = cachedFavorites
        if !updated.insert(entry.id).inserted { updated.remove(entry.id) }
        cachedFavorites = updated
        if let data = try? JSONEncoder().encode(updated) { favoriteData = data }
    }

    private func launchOrInspect(_ entry: Entry) {
        PhoneHaptics.medium.impactOccurred()
        switch entry {
        case let .rom(rom, _):
            remember(entry)
            selectedROM = rom
        case let .console(game):
            if game.builds.count == 1, let build = game.builds.first {
                launchSwitch(build, entry: entry)
            } else {
                detailEntry = entry
            }
        }
    }

    private func launchSwitch(_ build: PhoneLibrary.Format.SwitchBuild, entry: Entry) {
        guard let library else { return }
        do {
            switch build.engine {
            case .nxnative: try NXGameLauncher.launch(build, library: library)
            case .s2arm: try S2ArmGameLauncher.launch(build, library: library)
            }
            remember(entry)
        } catch {
            notice = error.localizedDescription
        }
    }

    private func deleteEntry(_ entry: Entry) {
        guard let library else { return }
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    switch entry {
                    case let .rom(rom, _):
                        try library.deleteROM(rom)
                    case let .console(game):
                        try library.deleteSwitchBuilds(for: game)
                    }
                }.value
                await refresh()
            } catch {
                notice = "删除失败：" + error.localizedDescription
            }
        }
    }

    private func lookupTarget(for entry: Entry) -> PhoneGameMetadata.LookupTarget {
        let source: URL?
        let titleID: String?
        switch entry {
        case let .rom(rom, _):
            source = rom.url
            titleID = nil
        case let .console(game):
            source = library?.switchRoot.appendingPathComponent(game.id)
            titleID = MetadataRefreshPolicy.normalizedSwitchTitleID(game.id)
        }
        return PhoneGameMetadata.LookupTarget(
            id: entry.id,
            title: entry.title,
            platformID: entry.platformID,
            source: source,
            titleID: titleID
        )
    }

    private func lookupMetadata(_ entry: Entry, force: Bool = false) async {
        let target = lookupTarget(for: entry)
        await metadata.lookup(
            id: target.id,
            title: target.title,
            platformID: target.platformID,
            source: target.source,
            titleID: target.titleID,
            force: force
        )
    }

    // MARK: - Gamepad Binding

    private func bindGamepad(columnsCount: Int) {
        gamepad.isActive = {
            selectedROM == nil && !showingSaveSync && !importing && pendingDeleteEntry == nil
        }
        gamepad.onMoveHorizontal = { delta in
            guard detailEntry == nil, !visibleEntries.isEmpty else { return }
            let idx = visibleEntries.firstIndex(where: { $0.id == selectedEntry?.id }) ?? 0
            selectedEntryID = visibleEntries[(idx + delta + visibleEntries.count) % visibleEntries.count].id
        }
        gamepad.onMoveVertical = { delta in
            guard detailEntry == nil, !visibleEntries.isEmpty else { return }
            let idx = visibleEntries.firstIndex(where: { $0.id == selectedEntry?.id }) ?? 0
            let next = idx + delta * columnsCount
            if visibleEntries.indices.contains(next) {
                selectedEntryID = visibleEntries[next].id
            }
        }
        gamepad.onShiftFilter = { delta in
            guard detailEntry == nil, !visibleFilters.isEmpty else { return }
            let idx = visibleFilters.firstIndex(of: activeFilter) ?? 0
            withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.86)) {
                activeFilter = visibleFilters[(idx + delta + visibleFilters.count) % visibleFilters.count]
            }
        }
        gamepad.onPlay = {
            if let entry = detailEntry {
                detailEntry = nil
                launchOrInspect(entry)
            } else if let entry = selectedEntry {
                launchOrInspect(entry)
            }
        }
        gamepad.onDetails = {
            if detailEntry == nil, let entry = selectedEntry {
                detailEntry = entry
            }
        }
        gamepad.onFavorite = {
            if let entry = detailEntry ?? selectedEntry {
                toggleFavorite(entry)
            }
        }
        gamepad.onBack = {
            if detailEntry != nil { detailEntry = nil }
        }
    }

    // MARK: - Library Refresh & Import

    private func refresh() async {
        guard !refreshing, !importingFiles, dm_shell_active_game_id() == nil, gc_s2arm_active() == 0 else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let data = try await Task.detached(priority: .utility) {
                let library = try PhoneLibrary.open()
                let error = library.importSwitchPackages()
                return (library, library.roms(), library.switchGames(), error)
            }.value
            (library, roms, switchGames) = (data.0, data.1, data.2)
            // If Recent is empty on first launch but user already has games, default to the first non-empty platform.
            if activeFilter == .recent && visibleEntries.isEmpty,
               let firstPlatform = allPlatforms.first(where: { count(for: .platform($0.id)) > 0 }) {
                activeFilter = .platform(firstPlatform.id)
            }
            if selectedEntryID == nil { selectedEntryID = visibleEntries.first?.id }
            let snapshot = makeSnapshot()
            if let selected = snapshot.selectedEntry {
                metadata.prioritize(lookupTarget(for: selected))
            }
            metadata.enqueueMissing(for: snapshot.allEntries.map(lookupTarget))
            if let error = data.3 { notice = error }
        } catch {
            notice = error.localizedDescription
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) async {
        guard let library, !refreshing, !importingFiles else { return }
        importingFiles = true
        let target = activeImportPlatform
        let errors = await Task.detached(priority: .userInitiated) {
            do {
                return try result.get().compactMap { url -> String? in
                    do {
                        try library.importItem(url, into: target)
                        return nil
                    } catch {
                        return "\(url.lastPathComponent) · \(error.localizedDescription)"
                    }
                }
            } catch {
                return [error.localizedDescription]
            }
        }.value
        importingFiles = false
        await refresh()
        if !errors.isEmpty { notice = errors.joined(separator: "\n") }
    }
}

@MainActor
private final class PhoneGamepadNavigator: ObservableObject {
    @Published private(set) var controllerName: String?
    @Published private(set) var connectionVersion = 0

    var isActive: () -> Bool = { true }
    var onMoveHorizontal: ((Int) -> Void)?
    var onMoveVertical: ((Int) -> Void)?
    var onShiftFilter: ((Int) -> Void)?
    var onPlay: (() -> Void)?
    var onDetails: (() -> Void)?
    var onFavorite: (() -> Void)?
    var onBack: (() -> Void)?

    private weak var boundController: GCController?
    private var lastStickX = 0
    private var lastStickY = 0

    func refresh() {
        let controller = GCController.controllers().first(where: { $0.extendedGamepad != nil })
        controllerName = controller?.vendorName ?? (controller == nil ? nil : "手柄已连接")
        guard controller !== boundController else { return }
        if let old = boundController?.extendedGamepad {
            old.dpad.left.pressedChangedHandler = nil
            old.dpad.right.pressedChangedHandler = nil
            old.dpad.up.pressedChangedHandler = nil
            old.dpad.down.pressedChangedHandler = nil
            old.leftThumbstick.valueChangedHandler = nil
            old.buttonA.pressedChangedHandler = nil
            old.buttonB.pressedChangedHandler = nil
            old.buttonX.pressedChangedHandler = nil
            old.buttonY.pressedChangedHandler = nil
            old.leftShoulder.pressedChangedHandler = nil
            old.rightShoulder.pressedChangedHandler = nil
        }
        boundController = controller
        connectionVersion += 1
        guard let pad = controller?.extendedGamepad else { return }

        pad.dpad.left.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { Task { @MainActor in self?.dispatch { self?.onMoveHorizontal?(-1) } } }
        }
        pad.dpad.right.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { Task { @MainActor in self?.dispatch { self?.onMoveHorizontal?(1) } } }
        }
        pad.dpad.up.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { Task { @MainActor in self?.dispatch { self?.onMoveVertical?(-1) } } }
        }
        pad.dpad.down.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { Task { @MainActor in self?.dispatch { self?.onMoveVertical?(1) } } }
        }
        pad.leftThumbstick.valueChangedHandler = { [weak self] _, x, y in
            Task { @MainActor in
                guard let self, self.isActive() else { return }
                self.handleAxis(x, state: &self.lastStickX, action: self.onMoveHorizontal)
                self.handleAxis(-y, state: &self.lastStickY, action: self.onMoveVertical)
            }
        }
        pad.buttonA.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { Task { @MainActor in self?.dispatch { self?.onPlay?() } } }
        }
        pad.buttonB.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { Task { @MainActor in self?.dispatch { self?.onBack?() } } }
        }
        pad.buttonX.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { Task { @MainActor in self?.dispatch { self?.onDetails?() } } }
        }
        pad.buttonY.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { Task { @MainActor in self?.dispatch { self?.onFavorite?() } } }
        }
        pad.leftShoulder.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { Task { @MainActor in self?.dispatch { self?.onShiftFilter?(-1) } } }
        }
        pad.rightShoulder.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { Task { @MainActor in self?.dispatch { self?.onShiftFilter?(1) } } }
        }
    }

    private func dispatch(_ action: () -> Void) {
        guard isActive() else { return }
        action()
    }

    private func handleAxis(_ value: Float, state: inout Int, action: ((Int) -> Void)?) {
        let next = value > 0.6 ? 1 : (value < -0.6 ? -1 : 0)
        if next == 0 {
            if abs(value) < 0.25 { state = 0 }
            return
        }
        guard next != state else { return }
        state = next
        action?(next)
    }
}
