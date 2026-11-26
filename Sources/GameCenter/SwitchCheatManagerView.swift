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

    private var modalWidth: CGFloat { min(590, max(440, availableSize.width - 32)) }
    private var modalHeight: CGFloat { min(540, max(380, availableSize.height - 32)) }

    private var buildGroups: [CheatBuildGroup] {
        let grouped = Dictionary(grouping: catalog?.items ?? [], by: \.buildID)
        return grouped.keys.sorted().map { CheatBuildGroup(buildID: $0, items: grouped[$0] ?? []) }
    }

    private var toggleItems: [SwitchCheatItem] {
        buildGroups.flatMap(\.items).filter { !$0.isMaster }
    }

    private var controllerActionCount: Int { toggleItems.count + 2 }

    var body: some View {
        let groups = buildGroups
        let toggles = groups.flatMap(\.items).filter { !$0.isMaster }
        let toggleIndexByID = Dictionary(uniqueKeysWithValues: toggles.enumerated().map { ($0.element.id, $0.offset) })
        let actionCount = toggles.count + 2

        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("金手指")
                        .font(.system(size: 16, weight: .semibold))
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button("打开文件夹…", systemImage: "folder", action: { SwitchCheatService.openFolder(directory) })
                    .buttonStyle(TactileActionButtonStyle(appearance: .secondary, cornerRadius: 8, minHeight: 32, horizontalPadding: 11, fontSize: 12, isControllerFocused: controllerSelection == 0))
                SheetCloseButton { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 15)

            Divider().overlay(GameCenterColors.border)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "info.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        Text("文件按游戏 ID 和 Build ID 匹配。运行时只会读取版本完全匹配的金手指；新文件默认关闭。开关在下次启动或引擎重新加载后生效。")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(GameCenterColors.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(GameCenterColors.border, lineWidth: 1))

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if groups.isEmpty {
                        emptyState
                    } else {
                        ForEach(groups) { group in
                            let buildID = group.buildID
                            let items = group.items
                            VStack(alignment: .leading, spacing: 0) {
                                HStack(spacing: 8) {
                                    Image(systemName: "number")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                    Text(buildID)
                                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    Text("· \(items.filter { !$0.isMaster }.count) 条")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)

                                ForEach(items) { item in
                                    HStack(spacing: 11) {
                                        if item.isMaster {
                                            Image(systemName: "lock.fill")
                                                .font(.system(size: 11))
                                                .foregroundStyle(.secondary)
                                                .frame(width: 16)
                                            Text(item.name)
                                                .font(.system(size: 13, weight: .medium))
                                            Spacer()
                                            Text("随启用条目运行")
                                                .font(.system(size: 11))
                                                .foregroundStyle(.secondary)
                                        } else {
                                            Text(item.name)
                                                .font(.system(size: 13, weight: .medium))
                                                .lineLimit(1)
                                            Spacer(minLength: 8)
                                            Toggle("", isOn: Binding(
                                                get: { item.isEnabled },
                                                set: { value in update(item, enabled: value) }
                                            ))
                                            .labelsHidden()
                                            .toggleStyle(.switch)
                                            .controlSize(.small)
                                        }
                                    }
                                    .padding(.horizontal, 14)
                                    .frame(height: 42)
                                    .background {
                                        if !item.isMaster,
                                           toggleIndexByID[item.id].map({ controllerSelection == $0 + 1 }) == true {
                                            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.16))
                                        }
                                    }
                                    if item.id != items.last?.id {
                                        Divider().overlay(.white.opacity(0.05)).padding(.leading, 40)
                                    }
                                }
                            }
                            .background(GameCenterColors.surface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(GameCenterColors.border, lineWidth: 1))
                        }
                    }

                    if let catalog, !catalog.unsupportedFiles.isEmpty {
                        Text("未识别的文件：\(catalog.unsupportedFiles.joined(separator: "、"))。请使用 16 位 Build ID 命名的 Atmosphère .txt 文件。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(18)
            }

            HStack {
                Text("\(directory.path)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(TactileActionButtonStyle(appearance: .primary, cornerRadius: 9, minHeight: 34, horizontalPadding: 16, fontSize: 12, isControllerFocused: controllerSelection == actionCount - 1))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 13)
            .background(Color.black.opacity(0.24))
            .overlay(alignment: .top) { Divider().overlay(GameCenterColors.border) }
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
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.secondary)
            Text("还没有金手指文件")
                .font(.system(size: 14, weight: .semibold))
            Text("将 Atmosphère 格式的 .txt 放入上方文件夹，文件名使用 16 位 Build ID。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button("打开金手指文件夹…", systemImage: "folder", action: { SwitchCheatService.openFolder(directory) })
                .buttonStyle(TactileActionButtonStyle(appearance: .secondary, cornerRadius: 9, minHeight: 34, horizontalPadding: 14, fontSize: 12))
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private func refresh() {
        let titleID = self.titleID
        let directory = self.directory
        Task {
            do {
                let loaded = try await Task.detached(priority: .userInitiated) {
                    try SwitchCheatService.load(titleID: titleID, directory: directory)
                }.value
                catalog = loaded
                errorMessage = nil
            } catch {
                errorMessage = AppLanguage.format("读取金手指目录失败：%@", error.localizedDescription)
            }
        }
    }

    private func update(_ item: SwitchCheatItem, enabled: Bool) {
        guard let currentCatalog = catalog else { return }
        Task {
            do {
                let updated = try await Task.detached(priority: .userInitiated) {
                    try SwitchCheatService.setEnabled(enabled, item: item, catalog: currentCatalog)
                }.value
                catalog = updated
                errorMessage = nil
            } catch {
                errorMessage = AppLanguage.format("保存金手指开关失败：%@", error.localizedDescription)
            }
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
