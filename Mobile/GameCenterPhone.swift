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

private struct LibraryView: View {
    @StateObject private var metadata = PhoneGameMetadata()
    @State private var library: PhoneLibrary?
    @State private var roms: [PhoneLibrary.ROM] = []
    @State private var switchGames: [PhoneLibrary.SwitchGame] = []
    @State private var platformID = "switch"
    @State private var importing = false
    @State private var refreshing = false
    @State private var importingFiles = false
    @State private var notice: String?
    @State private var selectedROM: PhoneLibrary.ROM?
    @State private var showingSaveSync = false

    private var platform: PhoneLibrary.Format.Platform? { library?.platforms.first { $0.id == platformID } }
    private var switchPackageType: UTType { UTType(exportedAs: "com.phoenixicarus.gamecenter.switch-build", conformingTo: .package) }

    @State private var inGallery = false
    @State private var approaching = false
    @State private var hallExpanded = true
    @State private var flight: Task<Void, Never>?
    @State private var gameIndex = 0
    @State private var showingFavorites = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("phone.library.favorites") private var favoriteData = Data()

    private enum Entry: Identifiable {
        case rom(PhoneLibrary.ROM, String), console(PhoneLibrary.SwitchGame)
        var id: String {
            switch self { case let .rom(_, path): "rom:" + path; case let .console(game): "switch:" + game.id }
        }
        var title: String {
            switch self { case let .rom(rom, _): rom.title; case let .console(game): game.title }
        }
        var platform: String {
            switch self { case let .rom(rom, _): rom.platform.id; case .console: "switch" }
        }
        var label: String {
            switch self { case let .rom(rom, _): rom.platform.folder.uppercased(); case .console: "SWITCH" }
        }
    }

    private var entries: [Entry] {
        switchGames.map(Entry.console) + roms.map { rom in
            let path = rom.url.pathComponents.dropFirst(library?.root.pathComponents.count ?? 0).joined(separator: "/")
            return .rom(rom, path)
        }
    }
    private var favorites: Set<String> { (try? JSONDecoder().decode(Set<String>.self, from: favoriteData)) ?? [] }
    private var platforms: [(id: String, name: String)] {
        [("switch", "Nintendo Switch")] + (library?.platforms.map { ($0.id, $0.name) } ?? [])
    }

    var body: some View {
        NavigationStack {
            museum
                .sheet(isPresented: $showingFavorites) {
                    NavigationStack {
                        ScrollView {
                            let saved = entries.filter { favorites.contains($0.id) }
                            if saved.isEmpty { ContentUnavailableView("还没有收藏", systemImage: "star") }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140))]) {
                                ForEach(saved) { tile($0) }
                            }.padding()
                        }.navigationTitle("收藏")
                        .toolbar { Button("完成") { showingFavorites = false } }
                    }
                }
                .sheet(isPresented: $showingSaveSync) {
                    CloudSaveSyncView(saveRoot: {
                        guard let library else { throw CloudSaveDirectorySync.Failure("游戏库尚未准备好，请稍后重试。") }
                        try library.createFolders()
                        return library.root.appendingPathComponent("save")
                    },
                                      isPlaying: { gc_s2arm_active() != 0 || dm_shell_active_game_id() != nil || selectedROM != nil })
                }
        }
        .preferredColorScheme(.dark)
        .task {
            if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }) {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape))
            }
        }
            .task { await refresh() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                Task { await refresh() }
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("DMShellDidReturnToLibrary"))) { _ in
                Task { await refresh() }
            }
            .fileImporter(isPresented: $importing,
                          allowedContentTypes: platform == nil ? [switchPackageType, .json, .folder] : platform?.runtime == nil ? [.data] : [.data, .folder],
                          allowsMultipleSelection: true) { result in
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
            .alert("Game Center", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
                Button("好", role: .cancel) { notice = nil }
            } message: {
                Text(notice ?? "")
            }
    }

    private enum Wing: String, CaseIterable { case recent = "最近", saved = "收藏", all = "全部" }
    @State private var wing: Wing = .all
    @AppStorage("museum.recent") private var recentData = Data()
    private var recent: [String] { (try? JSONDecoder().decode([String].self, from: recentData)) ?? [] }
    private func remember(_ entry: Entry) {
        recentData = (try? JSONEncoder().encode(Array(([entry.id] + recent.filter { $0 != entry.id }).prefix(100)))) ?? Data()
    }
    private var platformGames: [Entry] { entries.filter { $0.platform == platformID } }
    private var displayedGames: [Entry] {
        let games = platformGames
        switch wing {
        case .all: return games
        case .saved: return games.filter { favorites.contains($0.id) }
        case .recent: return recent.compactMap { key in games.first { $0.id == key } }
        }
    }

    private func machineCode(_ id: String) -> String {
        ["threeDS":"N3DS", "famicom":"FC", "superFamicom":"SFC", "megaDrive":"MD"][id] ?? id.uppercased()
    }

    private var museum: some View {
        let machines = platforms
        let index = machines.firstIndex { $0.id == platformID } ?? 0
        let games = displayedGames
        let focus = min(gameIndex, max(0, games.count - 1))
        let code = machineCode(platformID)
        let year = ["SWITCH":"2017", "GB":"1989", "GBC":"1998", "GBA":"2001", "NDS":"2004", "N3DS":"2011", "FC":"1983", "SFC":"1990", "MD":"1988", "PSP":"2004", "PS1":"1994", "PS2":"2000", "PS3":"2006", "PSV":"2011", "WII":"2006", "WIIU":"2012", "N64":"1996"][code] ?? ""
        let maker = ["PSP","PS1","PS2","PS3","PSV"].contains(code) ? "索尼" : code == "MD" ? "世嘉" : "任天堂"
        return GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let floor = height * (inGallery ? 0.65 : 0.71)
            let hero = min(height * 0.49, width * 0.54)
            let sizes = games.lazy.map { boxSize($0, height: hero) }
            let gap = min(24, width * 0.025)
            ZStack {
                if inGallery {
                    if games.indices.contains(focus) {
                        Text(games[focus].title.uppercased()).font(.system(size: height * 0.085, weight: .black))
                            .foregroundStyle(.white.opacity(0.12)).lineLimit(1).minimumScaleFactor(0.65)
                            .frame(width: width * 0.64).position(x: width / 2, y: height * 0.095).allowsHitTesting(false).accessibilityHidden(true)
                    }
                    ForEach(max(0, focus - 3)..<min(games.count, focus + 4), id: \.self) { slot in
                        let distance = slot - focus
                        let tier = min(3, abs(distance))
                        let scale = shelfScale(tier)
                        let boxHeight = sizes[slot].height * scale
                        let boxWidth = sizes[slot].width * scale
                        let offset = shelfOffset(from: focus, to: slot, sizes: sizes, gap: gap)
                        let box = boxFace(games[slot]).frame(width: boxWidth, height: boxHeight)
                        VStack(spacing: 0) {
                            box
                            box.scaleEffect(x: 1, y: -1).opacity(0.16)
                                .mask(LinearGradient(stops: [.init(color: .white, location: 0), .init(color: .clear, location: 0.36)], startPoint: .top, endPoint: .bottom))
                        }
                        .rotation3DEffect(.degrees(distance == 0 ? -3 : distance > 0 ? -10 : 10), axis: (x: 0, y: 1, z: 0))
                        .opacity([1, 0.85, 0.5, 0][tier])
                        .position(x: width / 2 + (distance < 0 ? -offset : offset), y: floor)
                        .allowsHitTesting(false)
                        if distance != 0 && tier < 3 {
                            Button { move(distance) } label: { Color.clear.contentShape(Rectangle()) }
                                .frame(width: boxWidth, height: boxHeight)
                                .position(x: width / 2 + (distance < 0 ? -offset : offset), y: floor - boxHeight / 2)
                                .accessibilityLabel("选择" + displayTitle(games[slot]))
                        }
                    }
                    if games.isEmpty {
                        ContentUnavailableView(wing == .all ? "展台还没有游戏" : "暂无" + wing.rawValue, systemImage: "shippingbox")
                    } else {
                        if ["GB", "GBC", "GBA", "N3DS", "NDS"].contains(code) {
                            MuseumExhibit(code: code + "-cart", entering: false, reducedMotion: reduceMotion)
                                .id(code).frame(width: hero * 0.54, height: hero * 0.46)
                                .position(x: width / 2 + hero * 0.45, y: floor - hero * 0.15)
                                .allowsHitTesting(false)
                        }
                        NavigationLink { detail(games[focus]) } label: { Color.clear.contentShape(Rectangle()) }
                            .frame(width: sizes[focus].width, height: sizes[focus].height)
                            .position(x: width / 2, y: floor - sizes[focus].height / 2)
                            .accessibilityLabel(displayTitle(games[focus]))
                        VStack(alignment: .leading, spacing: height * 0.014) {
                            Text(String(format: "正在展出  %02d / %02d", focus + 1, games.count))
                                .font(.footnote.monospaced().bold()).foregroundStyle(Color(red: 0.83, green: 0.69, blue: 0.41))
                            Text(displayTitle(games[focus])).font(.system(size: max(17, height * 0.049), weight: .bold)).lineLimit(1)
                            Text(code).font(.footnote.monospaced().bold()).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                            .padding(.leading, width * 0.042).padding(.bottom, height * 0.04).allowsHitTesting(false)
                    }
                } else {
                    Text(machines[index].name.uppercased()).font(.system(size: min(width * 0.09, height * 0.095), weight: .black))
                        .lineLimit(1).minimumScaleFactor(0.65).frame(width: width * 0.68)
                        .foregroundStyle(.white.opacity(0.65)).position(x: width / 2, y: height * 0.13)
                    ForEach(max(0,index-1)..<min(machines.count,index+2), id: \.self) { slot in
                        let distance = slot - index
                        let center = width * (distance == 0 ? (platformGames.isEmpty ? 0.5 : 0.44) : distance < 0 ? 0.025 : 0.975)
                        let extent = min(width * 0.55, height * 0.77) * (distance == 0 ? 1 : 0.42)
                        Ellipse().fill(.black.opacity(distance == 0 ? 0.46 : 0.22)).frame(width: extent * 0.78, height: extent * 0.055)
                            .blur(radius: 5).position(x: center, y: floor).allowsHitTesting(false)
                        MuseumExhibit(code: machineCode(machines[slot].id), entering: approaching && slot == index, reducedMotion: reduceMotion)
                            .frame(width: extent, height: extent)
                            .scaleEffect(approaching && slot == index ? 1.34 : 1)
                            .opacity(distance == 0 ? 1 : approaching ? 0 : 0.48)
                            .position(x: center, y: floor - extent * 0.36)
                            .allowsHitTesting(false)
                        if distance != 0 {
                            Button { move(distance) } label: { Text(distance < 0 ? "‹ " + machineCode(machines[slot].id) : machineCode(machines[slot].id) + " ›").font(.subheadline.bold()).padding(.horizontal, 12).frame(minHeight: 44) }
                                .position(x: distance < 0 ? width * 0.09 : width * 0.91, y: floor + height * 0.07)
                        }
                    }
                    if let first = platformGames.first {
                        let printSize = boxSize(first, height: hero * 0.57)
                        boxFace(first).frame(width: printSize.width, height: printSize.height)
                            .rotation3DEffect(.degrees(-14), axis: (x: 0, y: 1, z: 0))
                            .position(x: width * 0.735, y: floor - printSize.height * 0.5).allowsHitTesting(false)
                    }
                    Button { changeGallery(true) } label: { Color.clear.contentShape(Rectangle()) }
                        .frame(width: width * 0.62, height: height * 0.58)
                        .accessibilityLabel("进入" + machines[index].name)
                    Text(year + "  ·  " + maker).font(.footnote.monospaced().bold()).tracking(2)
                        .foregroundStyle(.secondary).position(x: width / 2, y: height * 0.92)
                }
                VStack {
                    HStack(spacing: 14) {
                        if inGallery {
                            Button { changeGallery(false) } label: { Image(systemName: "chevron.backward").font(.title3.weight(.semibold)).frame(width: 44, height: 44).contentShape(Rectangle()) }.accessibilityLabel("返回大厅")
                            ForEach(Wing.allCases, id: \.self) { item in
                                Button { wing = item; gameIndex = 0 } label: {
                                    Text(item.rawValue).font(.subheadline.weight(item == wing ? .bold : .regular))
                                        .foregroundStyle(item == wing ? .white : .gray)
                                        .frame(minHeight: 44).overlay(alignment: .bottom) {
                                            if item == wing { Capsule().fill(.white).frame(width: 18, height: 2) }
                                        }
                                }
                            }
                        }
                        Spacer()
                        Button { showingSaveSync = true } label: { Image(systemName: "arrow.triangle.2.circlepath.icloud").font(.title3.weight(.semibold)).frame(width: 44, height: 44).contentShape(Rectangle()) }.accessibilityLabel("同步存档")
                        if inGallery { Button { importing = true } label: { Image(systemName: "square.and.arrow.down").font(.title3.weight(.semibold)).frame(width: 44, height: 44).contentShape(Rectangle()) }.accessibilityLabel("导入游戏").disabled(library == nil || refreshing || importingFiles) }
                        else { Button { showingFavorites = true } label: { Image(systemName: "star").font(.title3.weight(.semibold)).frame(width: 44, height: 44).contentShape(Rectangle()) }.accessibilityLabel("收藏") }
                    }.padding(.horizontal, max(16, width * 0.04)).padding(.top, 6)
                    Spacer()
                    if !inGallery {
                        Button { changeGallery(true) } label: {
                            Label("进入展厅", systemImage: "chevron.forward").labelStyle(.titleAndIcon)
                                .font(.headline).padding(.horizontal, 16).frame(minHeight: 44)
                                .background(.white.opacity(0.13), in: Capsule())
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.horizontal, max(16, width * 0.04)).padding(.bottom, 6)
                    }
                }
            }.clipped().scaleEffect(inGallery && !hallExpanded ? 0.17 : 1)
            .background {
                MuseumWall(code: code, gallery: inGallery, artwork: inGallery && games.indices.contains(focus) ? image(for: games[focus]) : nil)
                    .ignoresSafeArea()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle()).simultaneousGesture(DragGesture(minimumDistance: 28).onEnded { drag in
                if abs(drag.translation.width) > abs(drag.translation.height) { move(drag.translation.width < 0 ? 1 : -1) }
            })
        }.background(Color(red: 11/255, green: 10/255, blue: 22/255).ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar).tint(.white)
    }

    private func boxAspect(_ entry: Entry) -> CGFloat {
        if let art = image(for: entry), art.size.height > 0 { return min(1.8, max(0.55, art.size.width / art.size.height)) }
        return switch entry.label { case "SWITCH": 0.63; case "NDS", "3DS", "PS1": 1; case "PSP": 0.59; default: 0.82 }
    }

    private func boxSize(_ entry: Entry, height: CGFloat) -> CGSize {
        let aspect = boxAspect(entry)
        let fitted = min(height, height * sqrt(0.88 / aspect))
        return CGSize(width: fitted * aspect, height: fitted)
    }

    private func shelfScale(_ distance: Int) -> CGFloat { [1, 0.72, 0.54, 0.42][min(distance, 3)] }

    private func shelfOffset(from focus: Int, to slot: Int, sizes: LazyMapCollection<[Entry], CGSize>, gap: CGFloat) -> CGFloat {
        guard focus != slot else { return 0 }
        let direction = slot > focus ? 1 : -1
        let distance = abs(slot - focus)
        var offset = sizes[focus].width / 2 + gap * CGFloat(distance)
        for tier in 1...distance {
            offset += sizes[focus + direction * tier].width * shelfScale(tier) * (tier == distance ? 0.5 : 1)
        }
        return offset
    }

    private func image(for entry: Entry) -> UIImage? {
        if let image = metadata.image(for: entry.id, backdrop: true) { return image }
        return bundledCover(entry)
    }

    private func bundledCover(_ entry: Entry) -> UIImage? {
        guard case let .console(game) = entry, let name = game.coverName else { return nil }
        return UIImage(named: name)
    }
    private func displayTitle(_ entry: Entry) -> String { metadata.records[entry.id]?.title ?? entry.title }
    private func lookupMetadata(_ entry: Entry, force: Bool = false) async {
        let source: URL?
        let titleID: String?
        switch entry {
        case let .rom(rom, _): source = rom.url; titleID = nil
        case let .console(game): source = library?.switchRoot.appendingPathComponent(game.id); titleID = game.id
        }
        await metadata.lookup(id: entry.id, title: entry.title, platformID: entry.platform, source: source, titleID: titleID, force: force)
    }

    private func boxFace(_ entry: Entry) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                if let image = metadata.image(for: entry.id) ?? bundledCover(entry) {
                    Image(uiImage: image).resizable().scaledToFill().frame(width: geometry.size.width, height: geometry.size.height)
                } else {
                    LinearGradient(colors: [Color(red: 0.43, green: 0.40, blue: 0.59), Color(red: 0.24, green: 0.22, blue: 0.37)], startPoint: .topTrailing, endPoint: .bottomLeading)
                    VStack(alignment: .leading) {
                        Text(entry.label).font(.system(size: geometry.size.height * 0.055, weight: .bold, design: .monospaced))
                        Spacer()
                        Text(displayTitle(entry)).font(.system(size: geometry.size.height * 0.093, weight: .bold)).lineLimit(3)
                    }.padding(geometry.size.width * 0.10)
                }
                Rectangle().fill(.black.opacity(0.65)).frame(width: max(2, geometry.size.width * 0.035))
            }.clipped()
        }
    }

    private func changeGallery(_ entering: Bool) {
        flight?.cancel()
        if reduceMotion {
            approaching = false; hallExpanded = true; inGallery = entering; gameIndex = 0; wing = .all
            return
        }
        if entering {
            withAnimation(.timingCurve(0.55, 0.055, 0.675, 0.19, duration: 1.4)) { approaching = true }
            flight = Task { @MainActor in
                do { try await Task.sleep(for: .milliseconds(540)) } catch { return }
                var initial = Transaction()
                initial.disablesAnimations = true
                withTransaction(initial) { hallExpanded = false; inGallery = true; gameIndex = 0; wing = .all }
                do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
                withAnimation(.timingCurve(0.215, 0.61, 0.355, 1, duration: 0.84)) { hallExpanded = true }
            }
        } else {
            withAnimation(.easeOut(duration: 0.3)) { inGallery = false }
            withAnimation(.timingCurve(0.215, 0.61, 0.355, 1, duration: 1.4)) { approaching = false }
        }
    }

    private func move(_ delta: Int) {
        guard inGallery || !approaching else { return }
        withAnimation(reduceMotion ? nil : .timingCurve(0.215, 0.61, 0.355, 1, duration: 0.52)) {
            if inGallery {
                gameIndex = min(max(0, gameIndex + delta), max(0, displayedGames.count - 1))
            } else if let index = platforms.firstIndex(where: { $0.id == platformID }), platforms.indices.contains(index + delta) {
                platformID = platforms[index + delta].id
            }
        }
    }

    private func tile(_ entry: Entry) -> some View {
        NavigationLink { detail(entry) } label: {
            VStack(alignment: .leading, spacing: 8) {
                cover(entry)
                Text(displayTitle(entry)).font(.subheadline.weight(.semibold)).lineLimit(2)
            }
        }.buttonStyle(.plain).accessibilityLabel(displayTitle(entry) + "，" + entry.label)
    }

    private func cover(_ entry: Entry) -> some View {
        let palette: [Color] = [Color(red: 0.16, green: 0.26, blue: 0.35), Color(red: 0.38, green: 0.18, blue: 0.17), Color(red: 0.16, green: 0.30, blue: 0.25), Color(red: 0.30, green: 0.23, blue: 0.38)]
        let index = entry.title.utf8.reduce(0) { ($0 + Int($1)) % palette.count }
        return Rectangle().fill(palette[index]).aspectRatio(1, contentMode: .fit)
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "opticaldisc").resizable().scaledToFit().foregroundStyle(.white.opacity(0.09)).offset(x: 36, y: 36)
            }
            .overlay {
                VStack(alignment: .leading) {
                    Text(entry.label).font(.footnote.monospaced().bold())
                    Spacer()
                    Text(displayTitle(entry)).font(.title3.bold()).lineLimit(3)
                }.foregroundStyle(.white).padding(14).frame(maxWidth: .infinity, alignment: .leading)
            }.overlay {
                if let image = metadata.image(for: entry.id) ?? bundledCover(entry) {
                    GeometryReader { bounds in
                        Image(uiImage: image).resizable().scaledToFill().frame(width: bounds.size.width, height: bounds.size.height)
                    }
                }
            }.clipShape(RoundedRectangle(cornerRadius: 10)).accessibilityHidden(true)
    }

    private func detail(_ entry: Entry) -> some View {
        GeometryReader { bounds in
            let wide = bounds.size.width >= 580
            let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 32))
                              : AnyLayout(VStackLayout(alignment: .leading, spacing: 20))
            ScrollView {
                layout {
                    cover(entry)
                        .frame(width: wide ? min(220, bounds.size.width * 0.29) : min(240, bounds.size.width * 0.60))
                        .frame(maxWidth: wide ? nil : .infinity)
                    detailActions(entry)
                }
                .padding(.horizontal, wide ? 32 : 20)
                .padding(.vertical, 20)
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }.navigationTitle("游戏详情").navigationBarTitleDisplayMode(.inline)
        .task(id: entry.id) { await lookupMetadata(entry) }
        .toolbar {
            Button(favorites.contains(entry.id) ? "取消收藏" : "加入收藏", systemImage: favorites.contains(entry.id) ? "star.fill" : "star") {
                var updated = favorites
                if !updated.insert(entry.id).inserted { updated.remove(entry.id) }
                if let data = try? JSONEncoder().encode(updated) { favoriteData = data }
            }
        }
    }

    private func detailActions(_ entry: Entry) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(displayTitle(entry)).font(.title.bold()).fixedSize(horizontal: false, vertical: true)
            switch entry {
            case let .rom(rom, _):
                Text(rom.platform.name).foregroundStyle(.secondary)
                if let note = rom.platform.runtimeNote {
                    Text(note).font(.callout).foregroundStyle(.secondary)
                }
                Button("开始游戏", systemImage: "play.fill") { remember(entry); selectedROM = rom }.buttonStyle(.borderedProminent).controlSize(.large)
            case let .console(game):
                Text(game.status).foregroundStyle(.secondary)
                ForEach(game.builds, id: \.engine) { build in
                    Button("运行 " + build.engine.rawValue, systemImage: "play.fill") {
                        guard let library else { return }
                        do {
                            switch build.engine {
                            case .nxnative: try NXGameLauncher.launch(build, library: library)
                            case .s2arm: try S2ArmGameLauncher.launch(build, library: library)
                            }
                            remember(entry)
                        } catch { notice = error.localizedDescription }
                    }.buttonStyle(.borderedProminent).controlSize(.large)
                }
            }
            PhoneMetadataSection(metadata: metadata, id: entry.id) {
                Task { await lookupMetadata(entry, force: true) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

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
            if let error = data.3 { notice = error }
        } catch {
            notice = error.localizedDescription
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) async {
        guard let library, !refreshing, !importingFiles else { return }
        importingFiles = true
        let target = platform
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

