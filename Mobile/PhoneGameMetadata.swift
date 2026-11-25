import SwiftUI
import UIKit
import CryptoKit

@MainActor
final class PhoneGameMetadata: ObservableObject {
    struct Record: Codable {
        var title: String?
        var synopsis: String?
        var source: String?
        var cover: String?
        var backdrop: String?
        var language: String
        var updated: Date
    }
    @Published private(set) var records: [String: Record] = [:]
    @Published private(set) var searching: Set<String> = []
    @Published private(set) var messages: [String: String] = [:]
    private let service: GameMetadataService
    private let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("GameCenter/Metadata")

    init(service: GameMetadataService = GameMetadataService()) {
        self.service = service
        if let data = try? Data(contentsOf: root.appendingPathComponent("index.json")),
           let saved = try? JSONDecoder().decode([String: Record].self, from: data) { records = saved }
    }
    func image(for id: String, backdrop: Bool = false) -> UIImage? {
        guard let record = records[id], let file = backdrop ? record.backdrop ?? record.cover : record.cover else { return nil }
        return UIImage(contentsOfFile: root.appendingPathComponent(file).path)
    }
    private func applyText(_ result: GameMetadataResult, id: String, language: String) {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var record = records[id] ?? Record(language: language, updated: .distantPast)
            if let title = result.title { record.title = title }
            if let synopsis = result.synopsis { record.synopsis = synopsis }
            if let source = result.metadataSourceURL { record.source = source }
            var updated = records; updated[id] = record
            try JSONEncoder().encode(updated).write(to: root.appendingPathComponent("index.json"), options: .atomic)
            records = updated
        } catch { messages[id] = "保存游戏信息失败：" + error.localizedDescription }
    }

    func lookup(id: String, title: String, platformID: String, source: URL?, titleID: String?, force: Bool = false) async {
        guard !searching.contains(id), let platform = GameMetadataPlatform(platformID: platformID) else { return }
        let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
        let language = preferred.hasPrefix("zh") ? "zh" : preferred.hasPrefix("ja") ? "ja" : "en"
        if !force, let cached = records[id], cached.language == language,
           cached.updated > Date.now.addingTimeInterval(-86400) { return }
        searching.insert(id); messages[id] = nil
        defer { searching.remove(id) }
        let result = await service.lookup(title: title, platform: platform, language: language, sourceURL: source, titleID: titleID,
            onText: { [weak self] partial in await self?.applyText(partial, id: id, language: language) })
        guard result.hasMetadata else {
            messages[id] = "暂未查到游戏信息，请检查网络或稍后重试。已有信息会保留。"
            return
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var record = records[id] ?? Record(language: language, updated: .now)
            if let title = result.title { record.title = title }
            if let synopsis = result.synopsis { record.synopsis = synopsis }
            if let source = result.metadataSourceURL { record.source = source }
            // Store the whole lookup in a new generation before committing the
            // index; a failed download/write cannot overwrite a cached cover.
            let stem = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined() + "-" + UUID().uuidString
            if let image = result.artworkData, UIImage(data: image) != nil {
                let file = stem + "-cover.image"
                try image.write(to: root.appendingPathComponent(file), options: .atomic); record.cover = file
            }
            if let image = result.backdropData, UIImage(data: image) != nil {
                let file = stem + "-backdrop.image"
                try image.write(to: root.appendingPathComponent(file), options: .atomic); record.backdrop = file
            }
            record.language = language; record.updated = .now
            var updated = records; updated[id] = record
            try JSONEncoder().encode(updated).write(to: root.appendingPathComponent("index.json"), options: .atomic)
            let old = records[id]; records = updated
            for file in [old?.cover, old?.backdrop].compactMap({ $0 }) where file != record.cover && file != record.backdrop {
                try? FileManager.default.removeItem(at: root.appendingPathComponent(file))
            }
            messages[id] = "游戏信息已更新"
        } catch { messages[id] = "保存游戏信息失败：" + error.localizedDescription }
    }
}

struct PhoneMetadataSection: View {
    @ObservedObject var metadata: PhoneGameMetadata
    let id: String
    let lookup: () -> Void
    var body: some View {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Text("游戏信息").font(.headline)
                        Spacer()
                        Button {
                            lookup()
                        } label: {
                            HStack(spacing: 8) {
                                if metadata.searching.contains(id) { ProgressView().controlSize(.small) }
                                Image(systemName: "magnifyingglass")
                                Text(metadata.searching.contains(id) ? "正在查找…" : "查找游戏信息")
                            }.font(.subheadline).padding(.horizontal, 12).padding(.vertical, 10)
                                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(PhoneMetadataButtonStyle()).disabled(metadata.searching.contains(id))
                    }
                    if let synopsis = metadata.records[id]?.synopsis {
                        Text(synopsis).font(.body).foregroundStyle(.secondary).textSelection(.enabled)
                    } else {
                        Text(metadata.searching.contains(id) ? "正在联网查找简介与封面…" : "查找游戏简介与封面，结果会保存在本机。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    if let message = metadata.messages[id] { Text(message).font(.caption).foregroundStyle(.secondary) }
                    if let source = metadata.records[id]?.source, let url = URL(string: source), ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                        Link("查看信息来源", destination: url).font(.caption).tint(.secondary)
                    }
                }.padding(16).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct PhoneMetadataButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}
