import AppKit
import SwiftUI

@MainActor
final class MobileAppBuildSession: ObservableObject {
    @Published private(set) var isBuilding = false
    @Published private(set) var progress = MobileAppBuildProgress()
    @Published private(set) var output: URL?
    @Published private(set) var error: String?
    @Published private(set) var logs: [String] = []
    @Published private(set) var destination: URL?
    @Published private(set) var startedAt: Date?
    @Published private(set) var requiresSigning = false

    func start(directory: URL, libraryRoot: URL?, games: [MobileLibraryFormat.SwitchEntry]) {
        guard !isBuilding else { return }
        progress = .init()
        output = nil
        error = nil
        logs = []
        destination = directory
        startedAt = .now
        requiresSigning = ProcessInfo.processInfo.environment["GAME_CENTER_IOS_PROFILE"] == nil
        isBuilding = true
        Task { [self] in
            defer {
                isBuilding = false
            }
            do {
                output = try await Task.detached(priority: .userInitiated) { [self] in
                    try MobileAppBuilder.build(to: directory, libraryRoot: libraryRoot, knownGames: games) { update in
                        Task { @MainActor [self] in
                            guard self.isBuilding, update.step >= self.progress.step else { return }
                            self.progress = update
                            if let log = update.log { self.logs = Array((self.logs + [log]).suffix(80)) }
                        }
                    }
                }.value
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct MobileAppBuildButton: View {
    @ObservedObject var session: MobileAppBuildSession
    @Binding var isPresented: Bool
    @State private var isHovered = false
    let chooseDirectory: () -> Void

    var body: some View {
        Button { isPresented.toggle() } label: {
            HStack(spacing: 8) {
                if session.isBuilding {
                    ProgressView().controlSize(.mini).tint(.white)
                } else {
                    Image(systemName: session.error != nil ? "exclamationmark.circle" :
                            session.output == nil ? "iphone" : "checkmark.circle.fill")
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.isBuilding ? "正在生成 IPA" : session.error != nil ? "IPA 生成失败" :
                            session.output == nil ? "生成 iOS App" : "IPA 已生成")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                    if session.isBuilding {
                        Text("\(min(session.progress.step, 6))/6 · \(MobileAppBuildProgress.steps[min(session.progress.step - 1, 5)])")
                            .font(.system(size: 11)).lineLimit(1)
                    }
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(isPresented ? 180 : 0))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(Color.white.opacity(isHovered ? 0.16 : 0.08), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(CursorButtonStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(session.isBuilding ? "正在生成 IPA，\(session.progress.step)/6，\(MobileAppBuildProgress.steps[min(session.progress.step - 1, 5)])" :
                            session.error != nil ? "IPA 生成失败，查看详情" : session.output == nil ? "生成 iOS App" : "IPA 已生成，查看文件")
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.16), value: isHovered)
        .help(session.isBuilding ? "查看 IPA 生成进度" : "生成用于 iPhone 和 iPad 的 Game Center")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            MobileAppBuildView(session: session, chooseDirectory: chooseDirectory)
        }
    }
}

private struct MobileAppBuildView: View {
    @ObservedObject var session: MobileAppBuildSession
    @State private var showsLogs = false
    let chooseDirectory: () -> Void
    private let accent = GameCenterColors.action

    private var complete: Bool { session.output != nil && !session.isBuilding }
    private var title: String {
        session.isBuilding ? "正在生成 Game Center" : session.error != nil ? "生成未完成" :
            complete ? "IPA 已准备好" : "生成 iOS App"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: complete ? "checkmark.circle" : "iphone")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(accent)
                    .frame(width: 40, height: 46)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.system(size: 17, weight: .semibold))
                    Text("Game Center.ipa")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
                Spacer()
                if session.isBuilding, let started = session.startedAt {
                    TimelineView(.periodic(from: started, by: 1)) { timeline in
                        let seconds = max(0, Int(timeline.date.timeIntervalSince(started)))
                        Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
            }

            if session.startedAt == nil {
                Text("包含 iOS 模拟器核心与当前 Switch 游戏清单。安装后，把 ROM 和 Switch 构建包导入手机即可。")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 7) {
                    Image(systemName: "folder")
                    Text("选择保存位置后开始生成")
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ProgressView(value: complete ? 6 : Double(session.progress.step - 1), total: 6)
                        .tint(accent)
                        .animation(.easeOut(duration: 0.25), value: session.progress.step)
                        .accessibilityLabel("构建步骤进度")
                    ForEach(Array(MobileAppBuildProgress.steps.enumerated()), id: \.offset) { index, step in
                        let done = complete || index + 1 < session.progress.step
                        let active = !complete && index + 1 == session.progress.step
                        HStack(spacing: 10) {
                            ZStack {
                                if done {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(accent)
                                } else if active && session.isBuilding {
                                    ProgressView().controlSize(.mini).tint(accent)
                                } else {
                                    Image(systemName: active && session.error != nil ? "exclamationmark.circle.fill" : "circle")
                                        .foregroundStyle(active && session.error != nil ? Color.red : Color.secondary.opacity(0.45))
                                }
                            }
                            .frame(width: 17, height: 17)
                            Text(step).font(.system(size: 12, weight: active ? .semibold : .regular))
                                .foregroundStyle(done || active ? Color.primary : .secondary)
                            Spacer()
                            if active && session.isBuilding {
                                Text("\(index + 1) / 6").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if session.isBuilding {
                    Text(session.progress.detail)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(2).frame(height: 30, alignment: .topLeading)
                }
            }

            if let error = session.error {
                Text(error).font(.system(size: 11)).foregroundStyle(.red)
                    .lineLimit(5).textSelection(.enabled)
            }
            if complete && session.requiresSigning {
                Text("用 AltStore / SideStore 安装此 IPA，游戏构建会自动使用本机开发证书。请使用同一 Apple 账号。")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let directory = session.destination {
                Label(directory.path, systemImage: "folder")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(2).textSelection(.enabled)
            }
            if !session.logs.isEmpty {
                DisclosureGroup("构建日志", isExpanded: $showsLogs) {
                    ScrollView {
                        Text(session.logs.joined(separator: "\n"))
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 120).padding(.top, 8)
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Divider()
            if complete, let output = session.output {
                Button { NSWorkspace.shared.activateFileViewerSelecting([output]) } label: {
                    Label("在 Finder 中显示 IPA", systemImage: "folder")
                        .frame(maxWidth: .infinity).frame(height: 38)
                        .foregroundStyle(.black).background(accent, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(CursorButtonStyle())
                Button("重新生成", action: chooseDirectory)
                    .buttonStyle(PlainHandButtonStyle()).frame(maxWidth: .infinity)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else if session.isBuilding {
                Label("可收起面板，构建会继续进行", systemImage: "arrow.up.right")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                Button(action: chooseDirectory) {
                    Label(session.error == nil ? "选择位置并生成" : "重新选择位置并生成", systemImage: "hammer")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity).frame(height: 40)
                        .foregroundStyle(.black).background(accent, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(CursorButtonStyle())
            }
        }
        .padding(22).frame(width: 360)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.dark)
    }
}
