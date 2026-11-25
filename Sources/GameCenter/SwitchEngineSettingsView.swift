import AppKit
import SwiftUI

struct SwitchEngineSettingsView: View {
    @State private var checkingEngine: SwitchBuildMethod?
    @State private var engineMessages: [SwitchBuildMethod: String] = [:]
    @State private var isCheckingDependencies = false
    @State private var dependencies: [SwitchBuildDependency] = []
    @State private var dependencyMethod: SwitchBuildMethod = .s2arm
    @State private var dependencyTarget: SwitchBuildTarget = .iOS
    @State private var dependenciesOpen = false

    private var panelFill: Color { Color.white.opacity(0.035) }
    private var accent: Color { GameCenterColors.action }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 7) {
                Text("构建设置").font(.system(size: 25, weight: .bold))
                Text("管理 S2Arm、nxnative 引擎版本和构建所需的设备依赖。")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 30).padding(.top, 26).padding(.bottom, 17)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("构建引擎").font(.system(size: 13, weight: .semibold))
                        VStack(spacing: 0) {
                            ForEach(Array(SwitchBuildMethod.allCases.enumerated()), id: \.element.id) { index, method in
                                engineRow(method)
                                if index < SwitchBuildMethod.allCases.count - 1 { divider }
                            }
                        }
                        .background(panelFill, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.08), lineWidth: 1))
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("设备依赖").font(.system(size: 13, weight: .semibold))
                        HStack {
                            Picker("构建方式", selection: $dependencyMethod) {
                                ForEach(SwitchBuildMethod.allCases) { Text($0.title).tag($0) }
                            }
                            Picker("目标平台", selection: $dependencyTarget) {
                                ForEach(SwitchBuildTarget.allCases) { Text($0.rawValue).tag($0) }
                            }
                        }
                        .onChange(of: dependencyMethod) { refreshDependencies() }
                        .onChange(of: dependencyTarget) { refreshDependencies() }
                        dependencyRows
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("文件位置").font(.system(size: 13, weight: .semibold))
                        VStack(spacing: 0) {
                            locationRow(title: "构建引擎缓存", path: SwitchEngineInstaller.installRoot(for: .nxnative).deletingLastPathComponent().path, actionTitle: "在 Finder 中显示") {
                                let url = SwitchEngineInstaller.installRoot(for: .nxnative).deletingLastPathComponent()
                                try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            }
                            divider
                            locationRow(title: "构建输出", path: "保存到当前 switch 文件夹")
                            divider
                            locationRow(title: "游戏存档", path: "switch/save")
                        }
                        .background(panelFill, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.08), lineWidth: 1))
                    }
                }
                .padding(.horizontal, 30).padding(.bottom, 26)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: refreshDependencies)
        .overlay {
            OutsideClickDismissMonitor { }
                .allowsHitTesting(false)
        }
    }

    private func engineRow(_ method: SwitchBuildMethod) -> some View {
        let info = SwitchEngineInstaller.installInfo(for: method)
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                Circle().fill(info == nil ? Color.secondary.opacity(0.6) : Color.green).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 4) {
                    Text(method.title).font(.system(size: 12, weight: .medium))
                    Text(info.map { "版本 \($0.version)" } ?? "尚未安装")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if checkingEngine == method { ProgressView().controlSize(.small) }
                Button(checkingEngine == method ? "检查中…" : "检查更新") {
                    checkUpdates(for: method)
                }
                .buttonStyle(PlainHandButtonStyle())
                .frame(width: 116, height: 34)
                .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.1), lineWidth: 1))
                .disabled(checkingEngine != nil)
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            if let message = engineMessages[method] {
                Text(message).font(.system(size: 10)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 35).padding(.trailing, 16).padding(.bottom, 11)
            }
        }
    }

    private var dependencyRows: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { dependenciesOpen.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Circle().fill(isCheckingDependencies ? Color.secondary : (dependencies.allSatisfy(\.isReady) && !dependencies.isEmpty ? Color.green : Color.orange)).frame(width: 7, height: 7)
                        Text("设备依赖").font(.system(size: 12, weight: .medium))
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                            .rotationEffect(.degrees(dependenciesOpen ? 180 : 0)).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainHandButtonStyle())
                Text(dependencySummary).font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button(isCheckingDependencies ? "检测中…" : "重新检测") { refreshDependencies() }
                    .buttonStyle(PlainHandButtonStyle()).font(.system(size: 10, weight: .medium))
                    .frame(width: 104, height: 32)
                    .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.1), lineWidth: 1))
                    .disabled(isCheckingDependencies)
            }
            .contentShape(Rectangle()).padding(.horizontal, 15).padding(.vertical, 12)

            if dependenciesOpen {
                divider
                ForEach(Array(dependencies.enumerated()), id: \.element.id) { index, dependency in
                    HStack(spacing: 10) {
                        Circle().fill(dependency.isReady ? Color.green : Color.orange).frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(dependency.id).font(.system(size: 11, weight: .medium))
                            Text(dependency.detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    if index < dependencies.count - 1 { divider.padding(.leading, 33) }
                }
                if dependencies.isEmpty && isCheckingDependencies {
                    HStack { ProgressView().controlSize(.small); Text("正在检查依赖…").font(.system(size: 10)).foregroundStyle(.secondary); Spacer() }
                        .padding(14)
                }
            }
        }
        .background(panelFill, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.08), lineWidth: 1))
    }

    private var dependencySummary: String {
        if isCheckingDependencies && dependencies.isEmpty { return "正在检查…" }
        let missing = dependencies.filter { !$0.isReady }.count
        return missing == 0 ? "全部就绪" : "缺少 \(missing) 项"
    }

    private var divider: some View { Rectangle().fill(.white.opacity(0.06)).frame(height: 1) }

    private func locationRow(title: String, path: String, actionTitle: String? = nil, action: (() -> Void)? = nil) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(path).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(PlainHandButtonStyle()).font(.system(size: 10, weight: .medium))
                    .frame(width: 132, height: 32)
                    .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.1), lineWidth: 1))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private func refreshDependencies() {
        let method = dependencyMethod, target = dependencyTarget
        isCheckingDependencies = true
        Task {
            let rows = await SwitchBuildService.detectBuildDependencies(for: method, target: target)
            guard method == dependencyMethod, target == dependencyTarget else { return }
            dependencies = rows
            isCheckingDependencies = false
        }
    }

    private func checkUpdates(for method: SwitchBuildMethod) {
        guard checkingEngine == nil else { return }
        checkingEngine = method
        engineMessages[method] = "正在检查 \(method.title) 的最新版本…"
        Task {
            defer { checkingEngine = nil }
            do {
                let latest = try await SwitchEngineInstaller.latestVersion(for: method)
                let installed = SwitchEngineInstaller.installInfo(for: method)
                if installed?.version == latest {
                    engineMessages[method] = "已是最新版本（\(latest)）。"
                    return
                }
                engineMessages[method] = installed == nil ? "发现版本 \(latest)，正在安装…" : "发现新版本 \(latest)，正在更新…"
                _ = try await SwitchEngineInstaller.ensureInstalled(method, forceUpdate: true) { line in
                    Task { @MainActor in engineMessages[method] = line }
                }
                engineMessages[method] = "已更新至 \(latest)。"
            } catch {
                engineMessages[method] = error.localizedDescription
            }
        }
    }
}
