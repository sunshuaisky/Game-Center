import SwiftUI

private struct CheatBuildGroup: Identifiable {
    let buildID: String
    let items: [SwitchCheatItem]
    var id: String { buildID }
}

struct SwitchCheatManagerView: View {
    let title: String
    let titleID: String
    let directory: URL
    let availableSize: CGSize
    @ObservedObject var controllerNavigation: ControllerNavigation

    @Environment(\.dismiss) private var dismiss
    @State private var catalog: SwitchCheatCatalog?
    @State private var errorMessage: String?
    @State private var controllerSelection = 0

    private var modalWidth: CGFloat { min(590, max(420, availableSize.width - 32)) }
    private var modalHeight: CGFloat { min(520, max(360, availableSize.height - 32)) }

    private var buildGroups: [CheatBuildGroup] {
        let grouped = Dictionary(grouping: catalog?.items ?? [], by: \.buildID)
        return grouped.keys.sorted().map { CheatBuildGroup(buildID: $0, items: grouped[$0] ?? []) }
    }

    private var toggleItems: [SwitchCheatItem] {
        buildGroups.flatMap(\.items).filter { !$0.isMaster }
    }

    private var controllerActionCount: Int { toggleItems.count + 2 }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("金手指")
                        .font(.system(size: 18, weight: .semibold))
                    Text(title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button("打开文件夹…", systemImage: "folder", action: { SwitchCheatService.openFolder(directory) })
                    .buttonStyle(CheatActionButtonStyle(isControllerFocused: controllerSelection == 0))
            }
            .padding(.horizontal, 22)
            .padding(.top, 20)
            .padding(.bottom, 14)

            Divider().overlay(.white.opacity(0.06))

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "info.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        Text("文件按游戏 ID 和 Build ID 匹配。运行时只会读取版本完全匹配的金手指；新文件默认关闭。开关在下次启动或引擎重新加载后生效。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 13)
                    .padding(.vertical, 11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if buildGroups.isEmpty {
                        emptyState
                    } else {
                        ForEach(buildGroups) { group in
                            let buildID = group.buildID
                            let items = group.items
                            VStack(alignment: .leading, spacing: 0) {
                                HStack(spacing: 8) {
                                    Image(systemName: "number")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                    Text(buildID)
                                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    Text("· \(items.filter { !$0.isMaster }.count) 条")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 13)
                                .padding(.vertical, 10)

                                ForEach(items) { item in
                                    HStack(spacing: 11) {
                                        if item.isMaster {
                                            Image(systemName: "lock.fill")
                                                .font(.system(size: 10))
                                                .foregroundStyle(.secondary)
                                                .frame(width: 16)
                                            Text(item.name)
                                                .font(.system(size: 12, weight: .medium))
                                            Spacer()
                                            Text("随启用条目运行")
                                                .font(.system(size: 10))
                                                .foregroundStyle(.secondary)
                                        } else {
                                            Text(item.name)
                                                .font(.system(size: 12, weight: .medium))
                                                .lineLimit(1)
                                            Spacer(minLength: 8)
                                            Toggle("", isOn: Binding(
                                                get: { item.isEnabled },
                                                set: { value in update(item, enabled: value) }
                                            ))
                                            .labelsHidden()
                                            .toggleStyle(.switch)
                                            .controlSize(.mini)
                                        }
                                    }
                                    .padding(.horizontal, 13)
                                    .frame(height: 40)
                                    .background {
                                        if !item.isMaster,
                                           toggleItems.firstIndex(where: { $0.id == item.id }).map({ controllerSelection == $0 + 1 }) == true {
                                            RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.16))
                                        }
                                    }
                                    if item.id != items.last?.id {
                                        Divider().overlay(.white.opacity(0.045)).padding(.leading, 40)
                                    }
                                }
                            }
                            .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.07), lineWidth: 1))
                        }
                    }

                    if let catalog, !catalog.unsupportedFiles.isEmpty {
                        Text("未识别的文件：\(catalog.unsupportedFiles.joined(separator: "、"))。请使用 16 位 Build ID 命名的 Atmosphère .txt 文件。")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(18)
            }

            HStack {
                Text("\(directory.path)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(CheatActionButtonStyle(appearance: .primary, isControllerFocused: controllerSelection == controllerActionCount - 1))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 13)
            .overlay(alignment: .top) { Divider().overlay(.white.opacity(0.06)) }
        }
        .frame(width: modalWidth, height: modalHeight)
        .background(Color(nsColor: .windowBackgroundColor))
        .foregroundStyle(.primary)
        .preferredColorScheme(.dark)
        .onAppear(perform: refresh)
        .onReceive(controllerNavigation.$event.compactMap { $0 }) { event in
            switch event.action {
            case .moveHorizontal(let direction), .moveVertical(let direction):
                controllerSelection = (controllerSelection + direction + controllerActionCount) % controllerActionCount
            case .confirm:
                activateControllerSelection()
            }
        }
        .overlay {
            OutsideClickDismissMonitor { dismiss() }
                .allowsHitTesting(false)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "curlybraces")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.secondary)
            Text("还没有金手指文件")
                .font(.system(size: 13, weight: .semibold))
            Text("将 Atmosphère 格式的 .txt 放入上方文件夹，文件名使用 16 位 Build ID。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button("打开金手指文件夹…", systemImage: "folder", action: { SwitchCheatService.openFolder(directory) })
                .buttonStyle(CheatActionButtonStyle())
                .padding(.top, 3)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }

    private func refresh() {
        do {
            catalog = try SwitchCheatService.load(titleID: titleID, directory: directory)
            errorMessage = nil
        } catch {
            errorMessage = "读取金手指目录失败：\(error.localizedDescription)"
        }
    }

    private func update(_ item: SwitchCheatItem, enabled: Bool) {
        guard let catalog else { return }
        do {
            self.catalog = try SwitchCheatService.setEnabled(enabled, item: item, catalog: catalog)
        } catch {
            errorMessage = "保存金手指开关失败：\(error.localizedDescription)"
        }
    }

    private func activateControllerSelection() {
        if controllerSelection == 0 {
            SwitchCheatService.openFolder(directory)
        } else if controllerSelection == controllerActionCount - 1 {
            dismiss()
        } else {
            let item = toggleItems[controllerSelection - 1]
            update(item, enabled: !item.isEnabled)
        }
    }
}

private struct CheatActionButtonStyle: ButtonStyle {
    enum Appearance { case secondary, primary }
    var appearance: Appearance = .secondary
    var isControllerFocused = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(appearance == .primary ? Color.black : Color.primary)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(appearance == .primary ? GameCenterColors.action : Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(appearance == .primary ? 0.18 : 0.12), lineWidth: 1))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white, lineWidth: isControllerFocused ? 2 : 0))
            .pointingHandCursor()
    }
}
