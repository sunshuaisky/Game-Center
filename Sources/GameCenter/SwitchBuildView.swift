import AppKit
import Combine
import SwiftUI

struct SwitchBuildPhase: Identifiable, Equatable {
    enum State: Equatable { case waiting, active, complete, failed, stopped }
    var id: String
    var title: String
    var purpose = ""
    var expected: Double?
    var reused = false
    var began: Date?
    var ended: Date?
    var detail: String = ""
    var fraction: Double?
    var state: State = .waiting
}

@MainActor
final class SwitchBuildSession: ObservableObject {
    @Published private(set) var isBuilding = false
    @Published private(set) var isStopping = false
    @Published private(set) var progress = SwitchBuildProgress()
    @Published private(set) var progressPhases: [SwitchBuildPhase] = []
    @Published var errorMessage: String?
    @Published private(set) var game: Game?
    @Published private(set) var method: SwitchBuildMethod = .nxnative
    @Published private(set) var target: SwitchBuildTarget = .macOS
    @Published private(set) var targets: [SwitchBuildTarget] = [.macOS]
    @Published private(set) var results: [SwitchBuildTarget: URL] = [:]
    @Published private(set) var iosOptions = SwitchIOSBuildOptions()
    @Published private(set) var resultURL: URL?

    @Published private(set) var startedAt = Date()
    @Published private(set) var finishedAt: Date?

    private var nxStageCount = 0
    private var task: Task<Void, Never>?

    var overallFraction: Double? {
        guard isBuilding, let index = targets.firstIndex(of: target) else { return progress.fraction }
        return (Double(index) + (progress.fraction ?? 0)) / Double(targets.count)
    }

    func start(game: Game, method: SwitchBuildMethod, targets: Set<SwitchBuildTarget>, source: URL, updatePackage: URL?, dlcPackages: [URL], keys: URL?, outputDirectory: URL, metadataTitle: String?, iosOptions: SwitchIOSBuildOptions = .init(), onBuilt: @escaping @MainActor () -> Void) {
        let orderedTargets = SwitchBuildTarget.allCases.filter { targets.contains($0) }
        guard !isBuilding, let first = orderedTargets.first else { return }
        self.game = game
        self.method = method
        self.target = first
        self.targets = orderedTargets
        self.iosOptions = iosOptions
        results = [:]
        errorMessage = nil
        resultURL = nil
        startedAt = Date()
        finishedAt = nil
        isBuilding = true
        isStopping = false
        progress = SwitchBuildProgress(stage: "准备构建")
        progressPhases = [SwitchBuildPhase(id: "准备构建", title: "准备构建", detail: "检查游戏文件", state: .active)]
        var buildGame = game
        buildGame.metadataTitle = metadataTitle ?? game.metadataTitle

        task = Task {
            let sourceAccess = source.startAccessingSecurityScopedResource()
            let updateAccess = updatePackage?.startAccessingSecurityScopedResource() ?? false
            let dlcAccess = dlcPackages.map { $0.startAccessingSecurityScopedResource() }
            let keyAccess = keys?.startAccessingSecurityScopedResource() ?? false
            defer {
                if sourceAccess { source.stopAccessingSecurityScopedResource() }
                if updateAccess { updatePackage?.stopAccessingSecurityScopedResource() }
                for (index, access) in dlcAccess.enumerated() where access { dlcPackages[index].stopAccessingSecurityScopedResource() }
                if keyAccess { keys?.stopAccessingSecurityScopedResource() }
            }
            var failures: [String] = []
            for buildTarget in orderedTargets {
                guard !Task.isCancelled, !isStopping else { break }
                nxStageCount = 0
                target = buildTarget
                progress.stage = "正在构建 \(buildTarget.title)"
                progress.detail = "准备 \(buildTarget.title) 构建环境"
                progress.fraction = nil
                do {
                    let result = try await SwitchBuildService.build(game: buildGame, method: method, target: buildTarget, source: source, updatePackage: updatePackage, dlcPackages: dlcPackages, keys: keys, outputDirectory: outputDirectory, iosOptions: iosOptions) { value in
                        Task { @MainActor in
                            guard self.isBuilding, self.target == buildTarget else { return }
                            self.consume(value)
                        }
                    }
                    results[buildTarget] = result
                    resultURL = results[.macOS] ?? result
                    progressPhases = progressPhases.map { phase in
                        var updated = phase
                        if updated.state == .active { updated.state = .complete }
                        return updated
                    }
                    onBuilt()
                } catch {
                    let stopped = isStopping || Task.isCancelled
                    progressPhases = progressPhases.map { phase in
                        var updated = phase
                        if updated.state == .active { updated.state = stopped ? .stopped : .failed }
                        return updated
                    }
                    if stopped { break }
                    failures.append("\(buildTarget.title)：\(error.localizedDescription)")
                }
            }
            errorMessage = failures.isEmpty ? nil : failures.joined(separator: "\n\n")
            if isStopping || Task.isCancelled {
                progress.stage = "已停止"
            } else {
                progress.stage = failures.isEmpty ? "构建完成" : "构建结束"
                progress.detail = results.isEmpty ? "没有生成构建产物" : "\(results.count) 个平台已生成"
                progress.fraction = failures.isEmpty ? 1 : nil
            }
            isStopping = false
            finishedAt = Date()
            isBuilding = false
            task = nil
        }
    }

    func stop() {
        guard isBuilding else { return }
        isStopping = true
        task?.cancel()
        SwitchBuildService.cancelCurrentProcess()
    }

    private func consume(_ value: SwitchBuildProgress) {
        let prefix = target.rawValue + ":"
        let phaseID = prefix + (value.stageNumber.map { "nx-stage-\($0)" } ?? value.milestone ?? value.stage)
        progress.log = Array((progress.log + value.log).suffix(240))
        if !value.plan.isEmpty {
            let existing = progressPhases
            progressPhases = value.plan.map { item in
                var phase = existing.first { $0.id == prefix + item.id } ?? item
                phase.id = prefix + item.id
                phase.expected = item.expected
                phase.reused = item.reused
                return phase
            }
            progress.fraction = value.fraction ?? 0
            return
        }
        if value.stage == "S2Arm 构建中" && value.milestone == nil { return }
        progress.stage = "\(target.title) · \(value.stage)"
        progress.detail = value.detail
        if let number = value.stageNumber, number > 0 {
            if let count = value.stageCount, count >= number, count <= 512 {
                if nxStageCount == 0 { progressPhases.removeAll() }
                if count > nxStageCount {
                    for k in (nxStageCount + 1)...count {
                        progressPhases.append(SwitchBuildPhase(id: prefix + "nx-stage-\(k)", title: "阶段 \(k)"))
                    }
                }
                nxStageCount = count
            }
            if let index = progressPhases.firstIndex(where: { $0.id == phaseID }) {
                progressPhases[index].title = value.stage
            }
            let step = value.phaseEvent == "stage_end" && value.stageSucceeded != false ? 1 : value.stepFraction ?? 0
            progress.fraction = min(1, (Double(number - 1) + step) / Double(max(nxStageCount, number)))
        } else if let fraction = value.fraction { progress.fraction = fraction }
        if value.milestone == nil && progressPhases.contains(where: { !$0.purpose.isEmpty })
            && value.phaseEvent != nil { return }
        if value.stage == "构建中" {
            if let index = progressPhases.lastIndex(where: { $0.state == .active }), !value.detail.isEmpty { progressPhases[index].detail = value.detail }
            return
        }
        for index in progressPhases.indices where progressPhases[index].state == .active && progressPhases[index].id != phaseID {
            progressPhases[index].state = .complete
            progressPhases[index].ended = Date()
        }
        if value.stage == "构建完成" {
            progressPhases = progressPhases.map { phase in
                var updated = phase
                if updated.state == .active { updated.state = .complete }
                return updated
            }
            return
        }
        if value.phaseEvent == "stage_end" {
            if let index = progressPhases.firstIndex(where: { $0.id == phaseID }) {
                progressPhases[index].state = value.stageSucceeded == false ? .failed : .complete
                progressPhases[index].ended = Date()
                progressPhases[index].detail = value.detail
                progressPhases[index].fraction = value.stageSucceeded == false ? progressPhases[index].fraction : 1
            }
            return
        }
        if let index = progressPhases.firstIndex(where: { $0.id == phaseID }) {
            progressPhases[index].began = progressPhases[index].began ?? Date()
            progressPhases[index].state = .active
            progressPhases[index].detail = value.detail
            progressPhases[index].fraction = value.milestone == nil ? value.fraction : value.stepFraction
        } else {
            progressPhases = progressPhases.map { phase in
                var updated = phase
                if updated.state == .active { updated.state = .complete }
                return updated
            }
            progressPhases.append(SwitchBuildPhase(id: phaseID, title: value.stage, began: Date(), detail: value.detail, fraction: value.fraction, state: .active))
        }
    }
}

struct SwitchBuildView: View {
    private static let prodKeysBookmarkKey = "GameCenter.SwitchBuild.prodKeysBookmark"
    private static let preferredBuildMethodKey = "GameCenter.SwitchBuild.preferredMethod"
    private static let preferredBuildTargetKey = "GameCenter.SwitchBuild.preferredTarget"
    private static let preferredBuildTargetsKey = "GameCenter.SwitchBuild.preferredTargets"

    let game: Game
    let initialSourceURL: URL?
    let gameLibraryPath: String?
    let metadataLanguage: String
    @ObservedObject var session: SwitchBuildSession
    @ObservedObject var controllerNavigation: ControllerNavigation
    let onBack: () -> Void
    let onBuilt: () -> Void

    @State private var method: SwitchBuildMethod = .nxnative
    @State private var targets: Set<SwitchBuildTarget> = [.macOS]
    @State private var gameFolderURL: URL?
    @State private var sourceURL: URL?
    @State private var sourceRecoveryMessage: String?
    @State private var updateURL: URL?
    @State private var dlcURLs: [URL] = []
    @State private var keysURL: URL?
    @State private var keysNeedReselect = false
    @State private var showingProgress = false
    @State private var isCheckingDependencies = false
    @State private var dependencies: [SwitchBuildDependency] = []
    @State private var installingDependencyID: String?
    @State private var installingDependencyMethod: SwitchBuildMethod?
    @State private var dependencyRefreshID = UUID()
    @State private var engineUpdateMessages: [String: String] = [:]
    @State private var dependencyInstallMessage: String?
    @State private var showExtras = false
    @State private var showBuildSettings = false
    @State private var showBuildLog = false
    @State private var resolvedGameTitle: String?
    @State private var titleLookupTask: Task<Void, Never>?
    @State private var controllerActionSelection = 0
    @AppStorage("GameCenter.SwitchBuild.s2ArmSGrade") private var s2ArmSGrade = true
    @AppStorage("GameCenter.SwitchBuild.s2ArmOptimizeDevice") private var s2ArmOptimizeDevice = false
    @AppStorage("GameCenter.SwitchBuild.s2ArmDeviceID") private var s2ArmDeviceID = ""
    @AppStorage("GameCenter.SwitchBuild.nxCompatibleOlderDevices") private var nxCompatibleOlderDevices = false
    @State private var deviceChoices: S2ArmDeviceChoices?
    @State private var deviceChoicesError: String?
    @State private var isLoadingDevices = false

    private var selectedDevice: S2ArmDeviceTarget? {
        deviceChoices?.models.first { $0.id == s2ArmDeviceID }
    }

    private var selectedIOSOptions: SwitchIOSBuildOptions {
        switch method {
        case .s2arm: .init(s2ArmSGrade: s2ArmSGrade, s2ArmDevice: s2ArmOptimizeDevice ? selectedDevice : nil)
        case .nxnative: .init(nxCompatibleOlderDevices: nxCompatibleOlderDevices)
        }
    }

    private var isSwitch2: Bool {
        guard let sourceURL else { return false }
        return sourceURL.pathExtension.lowercased() == "nup" || GamePlatform.isSwitch2DumpFolder(sourceURL)
    }

    private var sourceIsDirectory: Bool {
        guard let sourceURL else { return false }
        return (try? sourceURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private var supportsSeparateExtras: Bool {
        guard let sourceURL else { return true }
        return !sourceIsDirectory && sourceURL.pathExtension.lowercased() != "nup"
    }

    private var selectedFolderPath: String {
        gameFolderURL?.path ?? defaultSwitchDirectory.path
    }

    private var sourceDescription: String {
        guard let sourceURL else { return sourceRecoveryMessage ?? "选择 NSP、XCI、NSZ、XCZ、NUP 或文件夹" }
        if (try? sourceURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            return "自动扫描文件夹中的游戏文件"
        }
        return sourceURL.lastPathComponent
    }

    private var dlcDescription: String {
        guard !dlcURLs.isEmpty else { return "未选择（可选，可多选）" }
        let names = dlcURLs.prefix(2).map(\.lastPathComponent).joined(separator: "、")
        return dlcURLs.count > 2 ? "\(names) 等 \(dlcURLs.count) 个文件" : names
    }

    private var actionColor: Color { BuildPalette.cream }
    private var buildCanStart: Bool {
        guard sourceURL != nil, !targets.isEmpty, !session.isBuilding else { return false }
        if targets.contains(.iOS), method == .s2arm, s2ArmOptimizeDevice,
           selectedDevice == nil { return false }
        if !isSwitch2 && keysURL == nil { return false }
        if isCheckingDependencies || installingDependencyID != nil || dependencies.isEmpty || dependencies.contains(where: { !$0.isReady }) { return false }
        return true
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: showingProgress ? 34 : 22) {
                    HStack(spacing: 24) {
                        GameArtwork(game: game, compact: true)
                            .frame(width: 236, height: 236 / 1.8)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 8) {
                            Text(game.displayTitle)
                                .font(.system(size: 36, weight: .heavy)).tracking(-1)
                            Text(sourceDescription).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if showingProgress {
                        progressContent
                    } else {
                        configurationContent
                    }

                }
                .padding(.horizontal, 48)
                .padding(.top, 22)
                .padding(.bottom, 40)
            }

            Divider().opacity(0.3)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .preferredColorScheme(.dark)
        .onAppear {
            if let initialSourceURL, initialSourceURL.pathExtension.lowercased() != "app",
               FileManager.default.fileExists(atPath: initialSourceURL.path) {
                sourceURL = initialSourceURL
                gameFolderURL = inputFolder(for: initialSourceURL)
            } else {
                restoreBuildDefaults()
            }
            // A game card supplies initialSourceURL on the normal build path, which skips
            // restoreBuildDefaults(). Restore the saved key bookmark independently so the
            // current game's source selection does not make prod.keys appear unselected.
            restoreSavedKeys()
            method = SwitchBuildMethod(rawValue: UserDefaults.standard.string(forKey: Self.preferredBuildMethodKey) ?? "") ?? .nxnative
            let saved = UserDefaults.standard.stringArray(forKey: Self.preferredBuildTargetsKey)
                ?? [UserDefaults.standard.string(forKey: Self.preferredBuildTargetKey) ?? SwitchBuildTarget.macOS.rawValue]
            let restored = Set(saved.compactMap(SwitchBuildTarget.init(rawValue:)))
            targets = restored.isEmpty ? [.macOS] : restored
            if session.isBuilding {
                method = session.method
                targets = Set(session.targets)
                showingProgress = true
            }
            refreshDependencies()
            resolveGameTitle(for: sourceURL)
        }
        .onReceive(controllerNavigation.$event.compactMap { $0 }) { event in
            switch event.action {
            case .moveHorizontal(let direction):
                if showingProgress {
                    let count = controllerFooterActionCount
                    controllerActionSelection = (controllerActionSelection + direction + count) % count
                } else {
                    cycleBuildMethod(by: direction)
                }
            case .moveVertical(let direction):
                if showingProgress {
                    let count = controllerFooterActionCount
                    controllerActionSelection = (controllerActionSelection + direction + count) % count
                } else {
                    cycleBuildTarget(by: direction)
                }
            case .confirm:
                activateControllerAction()
            }
        }
    }

    private var configurationContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeading("游戏文件", subtitle: "选择游戏文件和构建输出")
                VStack(spacing: 0) {
                    fileRow(title: "已选择游戏文件夹", value: selectedFolderPath, button: "更换…") {
                        if let folder = chooseDirectory() {
                            gameFolderURL = folder
                            sourceURL = folder
                            updateURL = nil
                            dlcURLs = []
                            resolveGameTitle(for: folder)
                        }
                    }
                    rowDivider
                    fileRow(title: "游戏本体", value: sourceDescription, button: "更换…") {
                        if let selected = chooseGameSource() { selectGameSource(selected) }
                    }
                    rowDivider
                    fileRow(title: "主机密钥 prod.keys", value: keysURL?.lastPathComponent ?? (isSwitch2 ? "Switch 2 NUP 不需要密钥" : (keysNeedReselect ? "已保存的密钥找不到，请重新选择" : "选择你自己的 prod.keys")), button: keysURL == nil ? "选择…" : "更换…", showsClear: keysURL != nil, clear: clearSavedKeys) {
                        if let selectedKeys = chooseKeys() { saveKeysBookmark(for: selectedKeys) }
                    }
                    if !isSwitch2 {
                        Text("密钥只在本机读取，不会上传，也不会放进生成的应用。")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 35).padding(.bottom, 12)
                    }
                    rowDivider
                    Button { withAnimation(.easeInOut(duration: 0.18)) { showExtras.toggle() } } label: {
                        HStack(spacing: 7) {
                            Text("更新和 DLC（可选）").font(.system(size: 12, weight: .medium))
                            Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                                .rotationEffect(.degrees(showExtras ? 180 : 0))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle()).padding(.horizontal, 16).padding(.vertical, 13)
                    }
                    .buttonStyle(PlainHandButtonStyle())
                    if showExtras {
                        rowDivider
                        if supportsSeparateExtras {
                            fileRow(title: "更新包", value: updateURL?.lastPathComponent ?? "未选择（可选）", button: updateURL == nil ? "选择…" : "更换…", showsClear: updateURL != nil, clear: { updateURL = nil }) {
                                updateURL = chooseUpdatePackage()
                            }
                            rowDivider
                            fileRow(title: "DLC", value: dlcDescription, button: dlcURLs.isEmpty ? "选择…" : "更换…", showsClear: !dlcURLs.isEmpty, clear: { dlcURLs = [] }) {
                                dlcURLs = chooseDLCPackages()
                            }
                        } else {
                            Text("当前选择的游戏文件夹或 NUP 已包含游戏内容；请把更新放入 updates、DLC 放入 dlc 子文件夹。")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true).padding(14)
                        }
                    }
                    rowDivider
                    fileRow(title: "保存到", value: defaultSwitchDirectory.path, button: nil, action: {})
                }
                .background(panelFill, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.08), lineWidth: 1))
            }

            VStack(alignment: .leading, spacing: 10) {
                sectionHeading("目标平台", subtitle: "可同时勾选，按 macOS、iOS 的顺序构建")
                targetSettings
                if targets.isEmpty {
                    Text("至少选择一个目标平台").font(.system(size: 11)).foregroundStyle(.orange)
                }
                if targets.contains(.iOS) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "iphone").foregroundStyle(actionColor)
                        Text("把 .gcimport 放到手机 Game Center 的 GameLibrary/switch，或在 Switch 游戏库中点「导入」。基础 IPA 可在主窗口顶栏生成。")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                sectionHeading("构建引擎", subtitle: targets.contains(.iOS) ? "两种引擎使用相同的导入入口" : "选择一种构建方式，两个引擎都会将游戏放在 switch 文件夹")
                engineSettings
                if targets.contains(.iOS) { iosOptimizationSettings }
                dependencyRows
            }

            if !session.progress.log.isEmpty { buildLogDisclosure }
        }
    }

    private var targetSettings: some View {
        HStack(spacing: 14) {
            ForEach(SwitchBuildTarget.allCases) { option in
                Button {
                    if targets.contains(option) { targets.remove(option) }
                    else { targets.insert(option) }
                    saveSelectedTargets()
                    refreshDependencies()
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: option == .iOS ? "iphone" : "laptopcomputer")
                                .font(.system(size: 22, weight: .light))
                            Spacer()
                            Image(systemName: targets.contains(option) ? "checkmark.square.fill" : "square")
                        }
                        .foregroundStyle(targets.contains(option) ? actionColor : .secondary)
                        Text(option.title).font(.headline)
                        Text(option.description).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, minHeight: 126, alignment: .leading)
                    .background(Color.white.opacity(targets.contains(option) ? 0.075 : 0.035), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(targets.contains(option) ? actionColor.opacity(0.75) : Color.white.opacity(0.08), lineWidth: targets.contains(option) ? 1.5 : 1))
                }
                .buttonStyle(PlainHandButtonStyle())
                .accessibilityAddTraits(targets.contains(option) ? .isSelected : [])
                .disabled(session.isBuilding)
            }
        }
    }

    private var engineSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                ForEach(SwitchBuildMethod.allCases) { option in
                    let optionInfo = SwitchEngineInstaller.installInfo(for: option)
                    Button {
                        method = option
                        UserDefaults.standard.set(option.rawValue, forKey: Self.preferredBuildMethodKey)
                        refreshDependencies()
                    } label: {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: option == .s2arm ? "shippingbox" : "hammer")
                                    .font(.system(size: 22, weight: .light))
                                    .foregroundStyle(method == option ? actionColor : .secondary)
                                Spacer(minLength: 2)
                                if method == option {
                                    Circle().strokeBorder(actionColor, lineWidth: 5).frame(width: 15, height: 15)
                                } else {
                                    Circle().strokeBorder(.secondary.opacity(0.55), lineWidth: 1.3).frame(width: 15, height: 15)
                                }
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(option.title).font(.system(size: 15, weight: .semibold))
                                Text(optionInfo.map { "版本 \($0.version)" } ?? "首次构建时自动安装")
                                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .frame(height: 112)
                        .background(Color.white.opacity(method == option ? 0.075 : 0.035), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(method == option ? actionColor.opacity(0.75) : Color.white.opacity(0.08), lineWidth: method == option ? 1.5 : 1))
                    }
                    .buttonStyle(PlainHandButtonStyle())
                    .disabled(session.isBuilding)
                }
            }
        }
    }

    private var dependencyRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("设备依赖").font(.system(size: 13, weight: .semibold))
                Text(isCheckingDependencies ? "正在检测…" : "\(dependencies.filter(\.isReady).count)/\(dependencies.count) 已就绪")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button("重新检测") { refreshDependencies() }
                    .buttonStyle(BuildActionStyle(prominent: false))
                    .disabled(isCheckingDependencies || installingDependencyID != nil)
            }
            VStack(spacing: 0) {
                if isCheckingDependencies && dependencies.isEmpty {
                    HStack(spacing: 10) { ProgressView().controlSize(.small); Text("正在检测 \(method.title) 所需依赖…").font(.system(size: 11)).foregroundStyle(.secondary); Spacer() }
                        .padding(.horizontal, 16).padding(.vertical, 13)
                } else {
                    ForEach(Array(dependencies.enumerated()), id: \.element.id) { index, dependency in
                        HStack(spacing: 10) {
                            Circle().fill(dependency.isReady ? Color.green : Color.orange).frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(dependencyTitle(dependency.id)).font(.system(size: 11, weight: .medium))
                                Text(dependency.id == "engine" ? (engineUpdateMessages[method.rawValue] ?? dependency.detail) : dependency.detail)
                                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                                if installingDependencyID == dependency.id && installingDependencyMethod == method,
                                   ["python", "python-packages"].contains(dependency.id),
                                   let dependencyInstallMessage {
                                    Text(dependencyInstallMessage).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer(minLength: 8)
                            if installingDependencyID == dependency.id && installingDependencyMethod == method {
                                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("处理中…").font(.system(size: 10)) }
                                    .foregroundStyle(.secondary).frame(width: 90, height: 30)
                            } else {
                                Button(dependencyButtonTitle(dependency)) {
                                    install(dependency)
                                }
                                .buttonStyle(BuildActionStyle(prominent: false))
                    .disabled((dependency.isReady && dependency.id != "engine") || installingDependencyID != nil)
                            }
                        }
                        .padding(.horizontal, 15).padding(.vertical, 10)
                        if index < dependencies.count - 1 { rowDivider.padding(.leading, 32) }
                    }
                }
            }
            .background(panelFill, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.07), lineWidth: 1))
            if let dependencyInstallMessage {
                Text(dependencyInstallMessage).font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let runningMethod = installingDependencyMethod, installingDependencyID == "engine", runningMethod != method {
                Text("正在继续更新 \(runningMethod.title)；切换构建方式不会中断更新。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    private var iosOptimizationSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeading("iOS 构建选项", subtitle: method == .s2arm ? "S2Arm 优化设置" : "nxnative / NX2Apple 兼容设置")
            VStack(alignment: .leading, spacing: 14) {
                if method == .s2arm {
                    Toggle("S 级优化（Beta）", isOn: $s2ArmSGrade)
                        .pointingHandCursor()
                    Text("打入匹配当前游戏版本的社区补丁与金手指，效果取决于游戏和版本支持。")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    Divider()
                    HStack(spacing: 12) {
                        Toggle("指定目标机型", isOn: $s2ArmOptimizeDevice)
                            .fixedSize()
                            .pointingHandCursor()
                        Spacer(minLength: 0)
                        if s2ArmOptimizeDevice {
                            if isLoadingDevices {
                                ProgressView().controlSize(.small)
                                    .accessibilityLabel("正在读取 Xcode 机型列表")
                            } else if let choices = deviceChoices {
                                Picker("目标机型", selection: $s2ArmDeviceID) {
                                    Text("请选择 iPhone / iPad").tag("")
                                    ForEach(choices.models) { device in
                                        Text(device.name).tag(device.id)
                                    }
                                }
                                .labelsHidden()
                                .frame(maxWidth: 260)
                                .pointingHandCursor()
                            }
                        }
                    }
                    Text("向 S2Arm 提供目标机型信息，标准 iOS 包可用于多个机型。未指定时由引擎识别已连接的设备。")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    if s2ArmOptimizeDevice {
                        if !isLoadingDevices, deviceChoices != nil {
                            if selectedDevice == nil {
                                Text("选择目标机型后即可构建").font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            Text("当前 Game Center iOS 容器要求 iOS / iPadOS 26 或更新版本。")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        if let error = deviceChoicesError {
                            Text(error).font(.system(size: 10)).foregroundStyle(.secondary)
                            Button("重新读取机型列表") { Task { await loadDeviceChoices() } }
                                .buttonStyle(PlainHandButtonStyle())
                        }
                    }
                } else {
                    Toggle("兼容老机型（CPU 解码 BC 纹理）", isOn: $nxCompatibleOlderDevices)
                        .pointingHandCursor()
                    Text("用于 GPU 不支持 BC 纹理的设备，例如 A15、A16 及更早的芯片。开启会增加 CPU 负担，不保证所有游戏均可运行。")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 11))
            .toggleStyle(.checkbox)
            .frame(maxWidth: .infinity, alignment: .leading)
            .tint(actionColor)
            .padding(16)
            .background(panelFill, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.08)))
            .disabled(session.isBuilding)
        }
        .task(id: method) {
            if method == .s2arm && deviceChoices == nil { await loadDeviceChoices() }
        }
    }

    private func loadDeviceChoices() async {
        guard !isLoadingDevices else { return }
        isLoadingDevices = true
        deviceChoicesError = nil
        defer { isLoadingDevices = false }
        do {
            let choices = try await SwitchBuildService.s2ArmDeviceChoices()
            deviceChoices = choices
        } catch {
            deviceChoicesError = error.localizedDescription
        }
    }

    private func refreshDependencies() {
        let selectedMethod = method
        let refreshID = UUID()
        dependencyRefreshID = refreshID
        isCheckingDependencies = true
        Task {
            let selectedTargets = SwitchBuildTarget.allCases.filter { targets.contains($0) }
            var result: [SwitchBuildDependency] = []
            for selectedTarget in selectedTargets {
                let checks = await SwitchBuildService.detectBuildDependencies(for: selectedMethod, target: selectedTarget)
                for dependency in checks {
                    if let existing = result.firstIndex(where: { $0.id == dependency.id }) {
                        if !dependency.isReady { result[existing] = dependency }
                    } else {
                        result.append(dependency)
                    }
                }
            }
            guard dependencyRefreshID == refreshID else { return }
            dependencies = result
            isCheckingDependencies = false
        }
    }

    private func install(_ dependency: SwitchBuildDependency) {
        guard installingDependencyID == nil else { return }
        dependencyInstallMessage = nil
        if dependency.id == "signing" { refreshDependencies(); return }
        if dependency.id == "homebrew" {
            NSWorkspace.shared.open(URL(string: "https://brew.sh")!)
            return
        }
        if dependency.id == "xcode" {
            NSWorkspace.shared.open(URL(string: "macappstore://itunes.apple.com/app/id497799835")!)
            dependencyInstallMessage = "已打开 App Store 的 Xcode 页面。安装完成后点击「重新检测」。"
            return
        }
        installingDependencyID = dependency.id
        let actionTarget: SwitchBuildTarget = targets.contains(.iOS) ? .iOS : .macOS
        let actionMethod = method
        installingDependencyMethod = actionMethod
        if dependency.id == "python" {
            dependencyInstallMessage = "正在启动 Homebrew 安装 Python 3.14…"
        } else if dependency.id == "python-packages" {
            dependencyInstallMessage = "正在准备 nxnative Python 环境并安装构建依赖…"
        }
        Task {
            do {
                if dependency.id == "engine", dependency.isReady {
                    let currentVersion = SwitchEngineInstaller.installInfo(for: actionMethod)?.version ?? "未知"
                    engineUpdateMessages[actionMethod.rawValue] = "当前版本 \(currentVersion) · 正在检查最新版本…"
                    dependencyInstallMessage = "正在检查 \(actionMethod.title) 更新…"
                    let status = try await SwitchBuildService.checkAndUpdateEngine(actionMethod) { line in
                        Task { @MainActor in
                            engineUpdateMessages[actionMethod.rawValue] = line
                            dependencyInstallMessage = line
                        }
                    }
                    engineUpdateMessages[actionMethod.rawValue] = status
                    dependencyInstallMessage = status
                } else {
                    try await SwitchBuildService.installBuildDependency(id: dependency.id, method: actionMethod, target: actionTarget) { line in
                        Task { @MainActor in dependencyInstallMessage = line }
                    }
                    dependencyInstallMessage = "\(dependencyTitle(dependency.id)) 安装完成。"
                }
            } catch {
                dependencyInstallMessage = error.localizedDescription
            }
            installingDependencyID = nil
            installingDependencyMethod = nil
            if method == actionMethod { refreshDependencies() }
        }
    }

    private func dependencyTitle(_ id: String) -> String {
        switch id {
        case "engine": "\(method.title) 内置引擎"
        case "xcode": "Xcode"
        case "metal": "Metal Toolchain"
        case "s2arm-runtime": "S2Arm 内置运行环境"
        case "s2arm-ios-host": "S2Arm iOS 退出宿主"
        case "signing": "iPhone 游戏签名"
        case "nx-shell": "NX2Apple iOS 构建源码"
        case "nx-translator", "nx-ios-translator": "着色器转换器"
        case "homebrew": "Homebrew"
        case "ios-sdk": "iOS SDK"
        case "python": "Python 3.12+（Apple Silicon）"
        case "python-packages": "Python 构建依赖"
        case "zstd": "zstd"
        case "glslang": "glslangValidator"
        case "xcodegen": "XcodeGen"
        case "dotnet": ".NET SDK 10"
        case "spirv-cross": "spirv-cross（内置着色器工具）"
        default: id
        }
    }

    private func dependencyButtonTitle(_ dependency: SwitchBuildDependency) -> String {
        if installingDependencyID == dependency.id && installingDependencyMethod == method { return "处理中…" }
        if dependency.id == "engine" { return dependency.isReady ? "检查更新" : "安装" }
        if dependency.id == "signing" { return dependency.isReady ? "已验证" : "重新检测" }
        return dependency.isReady ? "已安装" : "安装"
    }

    private var progressContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Circle().fill(statusColor).frame(width: 9, height: 9)
                    Text(session.isBuilding ? (session.isStopping ? "正在停止" : "出包中") : session.progress.stage)
                        .font(.buildFace(14, .bold)).foregroundStyle(statusColor)
                    if session.isBuilding {
                        Text("· 第 \((session.targets.firstIndex(of: session.target) ?? 0) + 1) / \(session.targets.count) 个平台：\(session.target.title)")
                            .font(.buildFace(13, .medium)).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.bottom, 26)
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(Int((session.overallFraction ?? 0) * 100))%")
                        .font(.buildFace(58, .heavy)).tracking(-2).monospacedDigit().contentTransition(.numericText())
                    Text("整体进度").font(.buildFace(14, .semibold)).foregroundStyle(.secondary)
                    Spacer()
                }
                LauncherProgressBar(value: session.overallFraction ?? 0, height: 10, tint: actionColor)
                    .padding(.vertical, 14)
                VStack(alignment: .leading, spacing: 6) {
                    Text("总用时").font(.buildFace(13, .semibold)).foregroundStyle(.secondary)
                    TimelineView(.periodic(from: session.startedAt, by: 1)) { context in
                        Text(elapsed(session.startedAt, until: session.finishedAt ?? context.date))
                            .font(.buildFace(30, .bold)).tracking(-0.6).monospacedDigit()
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 26)
                ForEach(session.progressPhases) { phase in
                    phaseRow(phase, last: phase.id == session.progressPhases.last?.id)
                }
            }
            if let error = session.errorMessage {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(14).background(panelFill, in: RoundedRectangle(cornerRadius: 10))
            }
            ForEach(session.targets.filter { session.results[$0] != nil }) { builtTarget in
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(builtTarget.title) 已生成").font(.system(size: 12, weight: .semibold))
                        Text(session.results[builtTarget]?.path ?? "").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }
                .padding(14).background(panelFill, in: RoundedRectangle(cornerRadius: 10))
            }
            if session.results.isEmpty && session.errorMessage == nil {
                Text("返回游戏库后，可从游戏卡片查看进度。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { showBuildSettings.toggle() }
                } label: {
                    HStack(spacing: 7) {
                        Text("设置").font(.system(size: 12, weight: .medium))
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                            .rotationEffect(.degrees(showBuildSettings ? 180 : 0)).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .contentShape(Rectangle()).padding(.vertical, 8)
                }
                .buttonStyle(PlainHandButtonStyle())
                if showBuildSettings {
                VStack(alignment: .leading, spacing: 5) {
                    Text("引擎：\(session.method.title)")
                    Text("目标：\(session.targets.map(\.title).joined(separator: " + "))")
                    Text("游戏：\(sourceDescription)")
                    if let keysURL { Text("密钥：\(keysURL.lastPathComponent)") }
                    Text("输出：\(defaultSwitchDirectory.path)")
                    Text("存档：\(defaultSwitchDirectory.appendingPathComponent("save", isDirectory: true).path)")
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.top, 8)
                }
            }
            .padding(.horizontal, 4)

            buildLogDisclosure
        }
    }

    private var buildLogDisclosure: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { showBuildLog.toggle() }
            } label: {
                HStack(spacing: 7) {
                    Text("构建日志").font(.system(size: 12, weight: .medium))
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(showBuildLog ? 180 : 0)).foregroundStyle(.secondary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainHandButtonStyle())
            if showBuildLog {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(session.progress.log.suffix(80).enumerated()), id: \.offset) { _, entry in
                            Text(entry)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                }
                .frame(height: 150)
                .padding(.top, 8)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(panelFill, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.07), lineWidth: 1))
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 16) {
            Text("大游戏首次出包可能需要几十分钟，请接通电源并保持 Mac 唤醒")
                .font(.buildFace(13)).foregroundStyle(.secondary)
            Spacer(minLength: 6)
            Button(session.isBuilding ? "回到游戏库，后台继续" : showingProgress ? "返回游戏库" : "取消", action: onBack)
                .buttonStyle(BuildActionStyle()).keyboardShortcut(.cancelAction)
            if showingProgress && session.isBuilding {
                Button(session.isStopping ? "正在停止…" : "取消", systemImage: "stop.fill", role: .destructive) {
                    stopBuild()
                }
                .buttonStyle(BuildActionStyle(primary: true, focused: controllerNavigation.event != nil && controllerActionSelection == 0))
                .disabled(session.isStopping)
            } else if showingProgress, session.resultURL != nil {
                Button("在 Finder 中显示", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting(session.targets.compactMap { session.results[$0] })
                }
                .buttonStyle(BuildActionStyle(focused: controllerNavigation.event != nil && controllerActionSelection == 0))
                if let macURL = session.results[.macOS] {
                Button("启动游戏", systemImage: "play.fill") {
                    NSWorkspace.shared.open(macURL)
                    onBack()
                }
                .buttonStyle(BuildActionStyle(primary: true, focused: controllerNavigation.event != nil && controllerActionSelection == 1))
                }
            } else {
                Button(session.errorMessage == nil ? "开始出包" : "重新构建", systemImage: session.errorMessage == nil ? "shippingbox.fill" : "arrow.clockwise") {
                    startBuild()
                }
                    .buttonStyle(BuildActionStyle(primary: true, focused: controllerNavigation.event != nil && controllerActionSelection == 0))
                    .disabled(!buildCanStart)
            }
        }
        .padding(.horizontal, 48)
        .padding(.vertical, 16)
    }

    private var rowDivider: some View {
        Rectangle().fill(.white.opacity(0.06)).frame(height: 1)
    }

    private var panelFill: Color { Color(red: 0.10, green: 0.10, blue: 0.11).opacity(0.75) }

    private func sectionHeading(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private func fileRow(
        title: String,
        value: String,
        button: String?,
        showsClear: Bool = false,
        clear: (() -> Void)? = nil,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(fileRowStatus(title) ? Color.green : Color.secondary.opacity(0.6))
                .frame(width: 7, height: 7)
                .opacity(title == "保存到" ? 0 : 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(value)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if showsClear, let clear {
                Button("清除", action: clear)
                    .font(.system(size: 10))
                    .buttonStyle(PlainHandButtonStyle())
                    .foregroundStyle(.secondary)
            }
            if let button {
                Button(button, action: action)
                    .buttonStyle(BuildActionStyle(prominent: false))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func fileRowStatus(_ title: String) -> Bool {
        switch title {
        case "已选择游戏文件夹": gameFolderURL != nil
        case "游戏本体": sourceURL != nil
        case "主机密钥 prod.keys": keysURL != nil
        case "更新包": updateURL != nil
        case "DLC": !dlcURLs.isEmpty
        default: false
        }
    }

    private var statusColor: Color {
        if session.isBuilding { return BuildPalette.building }
        if session.errorMessage != nil { return .red }
        return session.progress.stage == "已停止" ? .secondary : BuildPalette.ready
    }

    private func elapsed(_ start: Date, until end: Date) -> String {
        Duration.seconds(max(0, Int(end.timeIntervalSince(start)))).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))
    }

    private func phaseRow(_ phase: SwitchBuildPhase, last: Bool) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                Group {
                    switch phase.state {
                    case .active: PulseDot()
                    case .complete: Image(systemName: "checkmark.circle.fill").font(.system(size: 18)).foregroundStyle(BuildPalette.ready)
                    case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                    case .stopped: Image(systemName: "pause.circle.fill").foregroundStyle(.secondary)
                    case .waiting: Circle().strokeBorder(.white.opacity(0.22), lineWidth: 1.5).frame(width: 14, height: 14)
                    }
                }.frame(width: 26, height: 26)
                if !last { Rectangle().fill(.white.opacity(0.09)).frame(width: 1).frame(maxHeight: .infinity) }
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(phase.title).font(.buildFace(phase.state == .active ? 17 : 14.5, phase.state == .waiting ? .medium : .bold))
                        .foregroundStyle(phase.state == .waiting ? .secondary : .primary)
                    if phase.reused {
                        Text("复用").font(.buildFace(11, .semibold)).foregroundStyle(BuildPalette.ready)
                            .padding(.horizontal, 7).padding(.vertical, 2).background(BuildPalette.ready.opacity(0.12), in: Capsule())
                    }
                    Spacer()
                    Group {
                        if phase.state == .active, let start = phase.began {
                            TimelineView(.periodic(from: start, by: 1)) { t in Text("本步 \(elapsed(start, until: t.date))") }
                        } else if let start = phase.began, let end = phase.ended {
                            Text(elapsed(start, until: end))
                        } else if phase.state == .waiting, let seconds = phase.expected, seconds > 0 {
                            Text("预计 \(Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated)))")
                        }
                    }.font(.buildFace(12.5)).monospacedDigit().foregroundStyle(.secondary)
                }
                if !phase.purpose.isEmpty { Text(phase.purpose).font(.buildFace(12.5)).foregroundStyle(.secondary) }
                if phase.state == .active {
                    LauncherProgressBar(value: phase.fraction, height: 6)
                        .overlay { if phase.fraction != nil { ProgressSweep().clipShape(Capsule()) } }.padding(.top, 6)
                    Text(phase.fraction.map { "\(Int($0 * 100))%" } ?? " ").font(.buildFace(12.5, .medium)).foregroundStyle(.secondary)
                    Text(phase.detail.isEmpty ? " " : phase.detail).font(.buildFace(12.5)).lineLimit(1).foregroundStyle(.secondary)
                }
            }.padding(.bottom, last ? 0 : 16)
        }.fixedSize(horizontal: false, vertical: true).accessibilityElement(children: .combine)
    }

    private func startBuild() {
        guard let sourceURL else { return }
        showingProgress = true
        session.errorMessage = nil
        session.start(
            game: game,
            method: method,
            targets: targets,
            source: sourceURL,
            updatePackage: updateURL,
            dlcPackages: dlcURLs,
            keys: keysURL,
            outputDirectory: defaultSwitchDirectory,
            metadataTitle: resolvedGameTitle ?? game.metadataTitle,
            iosOptions: selectedIOSOptions,
            onBuilt: onBuilt
        )
    }

    private func stopBuild() {
        session.stop()
    }

    private var controllerFooterActionCount: Int {
        showingProgress && session.results[.macOS] != nil && !session.isBuilding ? 2 : 1
    }

    private func activateControllerAction() {
        if showingProgress && session.isBuilding {
            stopBuild()
        } else if showingProgress, session.resultURL != nil {
            if controllerActionSelection == 0 {
                NSWorkspace.shared.activateFileViewerSelecting(session.targets.compactMap { session.results[$0] })
            } else if let macURL = session.results[.macOS] {
                NSWorkspace.shared.open(macURL)
                onBack()
            }
        } else if buildCanStart {
            startBuild()
        }
    }

    private func cycleBuildMethod(by direction: Int) {
        let methods = SwitchBuildMethod.allCases
        guard let index = methods.firstIndex(of: method) else { return }
        method = methods[(index + direction + methods.count) % methods.count]
        UserDefaults.standard.set(method.rawValue, forKey: Self.preferredBuildMethodKey)
        refreshDependencies()
    }

    private func cycleBuildTarget(by direction: Int) {
        let choices: [Set<SwitchBuildTarget>] = [[.macOS], [.iOS], [.macOS, .iOS]]
        let index = choices.firstIndex(of: targets) ?? 0
        targets = choices[(index + direction + choices.count) % choices.count]
        saveSelectedTargets()
        refreshDependencies()
    }

    private func saveSelectedTargets() {
        UserDefaults.standard.set(SwitchBuildTarget.allCases.filter { targets.contains($0) }.map(\.rawValue),
                                  forKey: Self.preferredBuildTargetsKey)
    }

    private var defaultSwitchDirectory: URL {
        if let gameFolderURL, let match = switchFolder(containing: gameFolderURL) { return match }
        if let sourceURL, let match = switchFolder(containing: sourceURL) { return match }
        if let gameLibraryPath {
            let root = URL(fileURLWithPath: gameLibraryPath, isDirectory: true)
            if let existing = existingPlatformFolder(named: "switch", under: root) { return existing }
            return root.appendingPathComponent("switch", isDirectory: true)
        }
        if let gameFolderURL { return gameFolderURL }
        if let sourceURL { return sourceIsDirectory ? sourceURL : sourceURL.deletingLastPathComponent() }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Game/switch", isDirectory: true)
    }

    private func switchFolder(containing url: URL) -> URL? {
        var directory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            ? url : url.deletingLastPathComponent()
        while true {
            if directory.lastPathComponent.lowercased() == "switch" { return directory }
            let parent = directory.deletingLastPathComponent()
            if parent == directory { break }
            directory = parent
        }
        return nil
    }

    private func existingPlatformFolder(named name: String, under root: URL) -> URL? {
        guard let children = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return nil }
        return children.first {
            $0.lastPathComponent.lowercased() == name &&
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }

    private func inputFolder(for source: URL) -> URL {
        return (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            ? source : source.deletingLastPathComponent()
    }

    private func restoreBuildDefaults() {
        if let resolved = try? game.resolvedURL(), resolved.pathExtension.lowercased() != "app",
           FileManager.default.fileExists(atPath: resolved.path) {
            sourceURL = resolved
            gameFolderURL = inputFolder(for: resolved)
        } else if let recovered = recoverGameSource() {
            sourceURL = recovered
            gameFolderURL = inputFolder(for: recovered)
            sourceRecoveryMessage = nil
        } else if let gameLibraryPath {
            let root = URL(fileURLWithPath: gameLibraryPath, isDirectory: true)
            gameFolderURL = existingPlatformFolder(named: "switch", under: root)
                ?? root.appendingPathComponent("switch", isDirectory: true)
            sourceRecoveryMessage = "请选择游戏本体文件或原始游戏文件夹，以构建其他平台版本。"
        }
    }

    private func recoverGameSource() -> URL? {
        guard let gameLibraryPath else { return nil }
        let fileManager = FileManager.default
        let libraryRoot = URL(fileURLWithPath: gameLibraryPath, isDirectory: true)
        let switchRoot = libraryRoot.lastPathComponent.lowercased() == "switch"
            ? libraryRoot
            : (existingPlatformFolder(named: "switch", under: libraryRoot)
                ?? libraryRoot.appendingPathComponent("switch", isDirectory: true))
        let packageExtensions: Set<String> = ["nsp", "xci", "nsz", "xcz", "nup"]
        let buildRoot = switchRoot.appendingPathComponent("build", isDirectory: true)
        let inputDirectories = [
            buildRoot.appendingPathComponent("nxnative", isDirectory: true).appendingPathComponent(safeBuildName(game.title), isDirectory: true),
            buildRoot.appendingPathComponent("S2Arm/inputs", isDirectory: true).appendingPathComponent(safeBuildName(game.title), isDirectory: true)
        ]
        for inputDirectory in inputDirectories {
            if let staged = try? fileManager.contentsOfDirectory(at: inputDirectory, includingPropertiesForKeys: nil),
               let source = staged.first(where: { packageExtensions.contains($0.pathExtension.lowercased()) && fileManager.fileExists(atPath: $0.path) }) {
                return source
            }
        }

        let wantedNames = Set([game.title, game.metadataTitle].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        let gameID = initialSourceURL.flatMap(GameDirectoryScanner.switchTitleID)
            ?? (try? game.resolvedURL()).flatMap(GameDirectoryScanner.switchTitleID)
        func matches(_ candidate: URL) -> Bool {
            let titleID = GameDirectoryScanner.switchTitleID(candidate)
            if let gameID, titleID == gameID { return true }
            let stem = candidate.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return wantedNames.contains(stem)
        }
        guard let enumerator = fileManager.enumerator(at: switchRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return nil }
        while let candidate = enumerator.nextObject() as? URL {
            let isDirectory = (try? candidate.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if isDirectory {
                if candidate.pathExtension.lowercased() == "app"
                    || candidate.standardizedFileURL == buildRoot.standardizedFileURL
                    || candidate.lastPathComponent.lowercased() == "ios" {
                    enumerator.skipDescendants()
                    continue
                }
                if matches(candidate), GamePlatform.isSwitch2DumpFolder(candidate) { return candidate }
                continue
            }
            guard packageExtensions.contains(candidate.pathExtension.lowercased()), fileManager.fileExists(atPath: candidate.path) else { continue }
            if matches(candidate) { return candidate }
        }
        return nil
    }

    private func safeBuildName(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\0")
        let name = value.components(separatedBy: invalid).filter { !$0.isEmpty }.joined(separator: "-")
        return name.isEmpty ? "Switch Game" : name
    }

    private func restoreSavedKeys() {
        guard let bookmark = UserDefaults.standard.data(forKey: Self.prodKeysBookmarkKey) else { return }
        do {
            var stale = false
            let url: URL
            do {
                url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
            } catch {
                url = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
            }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard FileManager.default.fileExists(atPath: url.path) else {
                invalidateSavedKeys()
                return
            }
            keysURL = url
            keysNeedReselect = false
            if stale { saveKeysBookmark(for: url) }
        } catch {
            invalidateSavedKeys()
        }
    }

    private func saveKeysBookmark(for url: URL) {
        let bookmark = (try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? (try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
        guard let bookmark else {
            session.errorMessage = "无法保存密钥文件书签，请重新选择 prod.keys。"
            keysURL = nil
            keysNeedReselect = true
            return
        }
        UserDefaults.standard.set(bookmark, forKey: Self.prodKeysBookmarkKey)
        keysURL = url
        keysNeedReselect = false
        session.errorMessage = nil
    }

    private func invalidateSavedKeys() {
        UserDefaults.standard.removeObject(forKey: Self.prodKeysBookmarkKey)
        keysURL = nil
        keysNeedReselect = true
    }

    private func clearSavedKeys() {
        UserDefaults.standard.removeObject(forKey: Self.prodKeysBookmarkKey)
        keysURL = nil
        keysNeedReselect = false
    }

    private func selectGameSource(_ url: URL) {
        sourceURL = url
        sourceRecoveryMessage = nil
        gameFolderURL = inputFolder(for: url)
        updateURL = nil
        dlcURLs = []
        resolveGameTitle(for: url)
    }

    private func resolveGameTitle(for url: URL?) {
        titleLookupTask?.cancel()
        resolvedGameTitle = game.metadataTitle
        guard let url else { return }
        titleLookupTask = Task {
            if let title = await GameMetadataService().switchTitle(for: url, language: metadataLanguage),
               !Task.isCancelled {
                resolvedGameTitle = title
            }
        }
    }

    private func chooseGameSource() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "选择 Switch 游戏或 Switch 2 NUP"
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func chooseKeys() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "选择自己的 prod.keys"
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func chooseDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func chooseUpdatePackage() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "选择游戏更新包"
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func chooseDLCPackages() -> [URL] {
        let panel = NSOpenPanel()
        panel.title = "选择 DLC"
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.urls : []
    }
}
