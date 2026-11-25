import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

struct CloudSaveSyncView: View {
    let saveRoot: () throws -> URL
    let isPlaying: () -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var syncing = false
    @State private var pickingFolder = false
    @State private var needsAuthorization = false
    @State private var message = "保存并退出游戏后，点下方按钮同步两端的进度。"
    @State private var cloudPath: String?
    @State private var localPath: String?
    @AppStorage("saveSync.cloudFolder") private var bookmark = Data()

    @State private var outcome: CloudSaveDirectorySync.Result?
    @State private var switchTitles: [String] = []
    @State private var chosenTitle = ""
    @State private var pendingTransfer: CloudSaveDirectorySync.SwitchTransfer?
    @State private var confirmsTransfer = false
    @State private var failed = false
    @State private var lastSync: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var statusTitle: String {
        if syncing { return "正在同步进度" }
        if needsAuthorization { return "连接 iCloud" }
        if failed { return "同步需要处理" }
        return outcome == nil ? "准备同步" : "存档已更新"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("同步存档").font(.headline)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
                        .frame(width: 36, height: 36).background(.white.opacity(0.07), in: Circle()).frame(width: 44, height: 44)
                }.buttonStyle(SyncActionStyle()).accessibilityLabel("关闭")
            }.padding(24)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .top, spacing: 16) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 16).fill(.white.opacity(0.06)).frame(width: 58, height: 58)
                            if syncing { ProgressView().controlSize(.regular) }
                            else { Image(systemName: needsAuthorization ? "icloud" : failed ? "exclamationmark.icloud" : "checkmark.icloud")
                                    .font(.system(size: 26, weight: .light)) }
                        }
                        VStack(alignment: .leading, spacing: 7) {
                            Text(statusTitle).font(.system(size: 23, weight: .semibold))
                            Text(message).font(.subheadline).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            if let lastSync, !syncing {
                                Text(lastSync, format: .dateTime.hour().minute()).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                            }
                        }
                    }.accessibilityElement(children: .combine)
                    if let outcome, !syncing {
                        VStack(spacing: 12) {
                            resultRow("arrow.up", "上传到 iCloud", count: outcome.uploaded)
                            resultRow("arrow.down", "更新到本机", count: outcome.downloaded)
                            resultRow("equal", "内容一致", count: outcome.unchanged)
                        }.padding(18).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
                    }
                    VStack(spacing: 0) {
                        locationRow("本机", subtitle: "save · 按平台保存", symbol: "internaldrive")
                        HStack { Spacer().frame(width: 18); Rectangle().fill(.white.opacity(0.12)).frame(width: 1, height: 20); Spacer() }
                        locationRow("iCloud Drive", subtitle: "Game Center存档", symbol: "icloud")
                    }
                    Text("Switch 按整份存档同步，其余平台按文件更新。覆盖前保留备份，请先保存并退出游戏。")
                        .font(.footnote).foregroundStyle(.secondary).lineSpacing(4)
                    if !switchTitles.isEmpty && !needsAuthorization {
                        DisclosureGroup("恢复指定 Switch 游戏的进度") {
                            VStack(alignment: .leading, spacing: 12) {
                                Picker("游戏编号", selection: $chosenTitle) {
                                    ForEach(switchTitles, id: \.self) { Text($0).tag($0) }
                                }
                                Text("当自动同步选中的进度不对时，可以指定这一款游戏的存档来源。覆盖前会备份原进度。")
                                    .font(.footnote).foregroundStyle(.secondary)
                                Button("使用本机进度更新 iCloud") { confirmTransfer(upload: true) }
                                Button("从 iCloud 恢复到本机") { confirmTransfer(upload: false) }
                            }.padding(.top, 8)
                        }.disabled(syncing)
                    }
                    DisclosureGroup("存档位置与备份") {
                        VStack(alignment: .leading, spacing: 12) {
                            if let localPath { Text("本机：" + localPath).textSelection(.enabled) }
                            if let cloudPath { Text("iCloud：" + cloudPath).textSelection(.enabled) }
                            Text("旧版本保存在 SyncBackups；迁移修复保存在 MigrationBackups。云端备份在 Backups 中。")
                            #if os(macOS)
                            Button("在访达中查看存档") {
                                do { NSWorkspace.shared.open(try saveRoot()) }
                                catch { failed = true; message = error.localizedDescription }
                            }.buttonStyle(SyncActionStyle())
                            #endif
                        }.font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10)
                    }.font(.system(size: 12)).tint(.primary)
                }.padding(.horizontal, 24).padding(.bottom, 24)
            }
            Divider().opacity(0.5)
            VStack(spacing: 10) {
                Button {
                    if needsAuthorization { pickingFolder = true } else { run() }
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: needsAuthorization ? "folder.badge.plus" : "arrow.triangle.2.circlepath")
                        Text(needsAuthorization ? "授权 iCloud 访问" : syncing ? "正在同步…" : "同步存档")
                    }.font(.system(size: 14, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 14)
                        .foregroundStyle(Color.black.opacity(0.9)).background(Color.white.opacity(syncing ? 0.45 : 0.92), in: RoundedRectangle(cornerRadius: 12))
                }.buttonStyle(SyncActionStyle()).disabled(syncing)
                if needsAuthorization {
                    Text("选择 iCloud Drive 中的“Game Center存档”，仅首次需要授权。")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }.padding(24)
        }
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.075))
        .task {
            guard let root = try? saveRoot() else { return }
            switchTitles = ((try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("switch").path)) ?? [])
                .filter { $0.range(of: "^[0-9A-Fa-f]{16}$", options: .regularExpression) != nil }.sorted()
            chosenTitle = switchTitles.first ?? ""
            localPath = root.path
            do { cloudPath = try CloudSaveLocation.resolve(bookmark: bookmark).folder.path }
            catch let failure as CloudSaveLocation.Failure {
                switch failure {
                case .authorizationRequired, .staleAuthorization: needsAuthorization = true
                case .unavailable: failed = true
                }
                message = failure.localizedDescription
            } catch { failed = true; message = error.localizedDescription }
        }
        .confirmationDialog(pendingTransfer?.upload == true ? "使用本机进度更新 iCloud？" : "使用 iCloud 进度更新本机？",
                            isPresented: $confirmsTransfer) {
            Button("备份并更新") { if let transfer = pendingTransfer { run(transfer: transfer) } }
            Button("取消", role: .cancel) {}
        } message: { Text("仅更新游戏 " + chosenTitle + " 的存档。") }
        .preferredColorScheme(.dark)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: syncing)
        #if os(macOS)
        .frame(width: 500, height: 620)
        #endif
        .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
            do {
                let url = try result.get()
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                #if os(macOS)
                bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                #else
                bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
                #endif
                needsAuthorization = false
                message = "已连接 iCloud，可以同步存档。"
            } catch { failed = true; message = error.localizedDescription }
        }
    }

    private func resultRow(_ symbol: String, _ title: String, count: Int) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.footnote).foregroundStyle(.secondary).frame(width: 16)
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            Text(count.formatted()).font(.system(size: 15, weight: .medium, design: .monospaced))
        }
    }

    private func locationRow(_ title: String, subtitle: String, symbol: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 18, weight: .light)).frame(width: 36, height: 36)
            Text(title).font(.system(size: 13, weight: .medium))
            Spacer()
            Text(subtitle).font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func confirmTransfer(upload: Bool) {
        pendingTransfer = .init(title: chosenTitle, upload: upload)
        confirmsTransfer = true
    }

    private func run(transfer: CloudSaveDirectorySync.SwitchTransfer? = nil) {
        guard !syncing else { return }
        guard !isPlaying() else { failed = true; message = "请先退出正在运行的游戏，再同步存档。"; return }
        do {
            let local = try saveRoot()
            localPath = local.path
            let savedBookmark = bookmark
            syncing = true
            failed = false
            #if os(macOS)
            message = "正在检查本机与 iCloud 存档。如系统询问文件访问，请允许后继续。"
            #else
            message = "正在检查本机与 iCloud 存档…"
            #endif
            Task {
                defer { syncing = false }
                do {
                    #if os(macOS)
                    let macNames = true
                    #else
                    let macNames = false
                    #endif
                    let (result, remote) = try await Task.detached(priority: .utility) {
                        let access = try CloudSaveLocation.resolve(bookmark: savedBookmark)
                        let accessed = access.scope?.startAccessingSecurityScopedResource() ?? false
                        defer { if accessed { access.scope?.stopAccessingSecurityScopedResource() } }
                        let result = try CloudSaveDirectorySync().sync(local: local, cloud: access.folder.appendingPathComponent("save"), macBatteryNames: macNames, switchTransfer: transfer) { status in
                            Task { @MainActor in message = status }
                        }
                        return (result, access.folder.path)
                    }.value
                    cloudPath = remote
                    needsAuthorization = false
                    outcome = result
                    lastSync = Date()
                    message = transfer.map { $0.upload ? "已将这款游戏的本机进度写入 iCloud 同步目录。" : "已从 iCloud 恢复这款游戏的进度，可以重新打开游戏。" } ?? "本机与 iCloud 已合并。云端上传完成后，另一台设备即可获取最新进度。"
                    if !result.sameDateConflicts.isEmpty {
                        failed = true
                        message += "\n\(result.sameDateConflicts.count) 项存档修改时间相同但内容不同，已保留两端：\n" + result.sameDateConflicts.prefix(8).joined(separator: "\n")
                    }
                } catch {
                    if let failure = error as? CloudSaveLocation.Failure {
                        switch failure {
                        case .authorizationRequired, .staleAuthorization: needsAuthorization = true
                        case .unavailable: break
                        }
                    }
                    failed = true
                    message = needsAuthorization ? "首次连接时，请授权访问 iCloud Drive 中的“Game Center存档”。之后会自动记住。" : error.localizedDescription
                }
            }
        } catch { failed = true; message = error.localizedDescription }
    }
}

private struct SyncActionStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            #if os(macOS)
            .onHover { hovering in if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
            #endif
    }
}
