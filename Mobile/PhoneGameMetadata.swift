import CryptoKit
import SwiftUI
import UIKit

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
    private let imageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 160
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()

    init(service: GameMetadataService = GameMetadataService()) {
        self.service = service
        if let data = try? Data(contentsOf: root.appendingPathComponent("index.json")),
           let saved = try? JSONDecoder().decode([String: Record].self, from: data) {
            records = saved
        }
    }

    func image(for id: String, backdrop: Bool = false) -> UIImage? {
        guard let record = records[id],
              let file = backdrop ? (record.backdrop ?? record.cover) : record.cover else { return nil }
        let cacheKey = file as NSString
        if let cached = imageCache.object(forKey: cacheKey) {
            return cached
        }
        let path = root.appendingPathComponent(file).path
        guard let loaded = UIImage(contentsOfFile: path) else { return nil }
        let cost = Int(loaded.size.width * loaded.size.height * loaded.scale * loaded.scale * 4)
        imageCache.setObject(loaded, forKey: cacheKey, cost: max(1, cost))
        return loaded
    }

    func bundledImage(named name: String?) -> UIImage? {
        guard let name else { return nil }
        let cacheKey = ("bundle:" + name) as NSString
        if let cached = imageCache.object(forKey: cacheKey) { return cached }
        guard let loaded = UIImage(named: name) else { return nil }
        let cost = Int(loaded.size.width * loaded.size.height * loaded.scale * loaded.scale * 4)
        imageCache.setObject(loaded, forKey: cacheKey, cost: max(1, cost))
        return loaded
    }

    private func applyText(_ result: GameMetadataResult, id: String, language: String) {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var record = records[id] ?? Record(language: language, updated: .distantPast)
            if let title = result.title { record.title = title }
            if let synopsis = result.synopsis { record.synopsis = synopsis }
            if let source = result.metadataSourceURL { record.source = source }
            var updated = records
            updated[id] = record
            try JSONEncoder().encode(updated).write(to: root.appendingPathComponent("index.json"), options: .atomic)
            records = updated
        } catch {
            messages[id] = "保存游戏信息失败：" + error.localizedDescription
        }
    }

    func lookup(id: String, title: String, platformID: String, source: URL?, titleID: String?, force: Bool = false) async {
        guard !searching.contains(id), let platform = GameMetadataPlatform(platformID: platformID) else { return }
        let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
        let language = preferred.hasPrefix("zh") ? "zh" : preferred.hasPrefix("ja") ? "ja" : "en"
        if !force, let cached = records[id], cached.language == language,
           cached.updated > Date.now.addingTimeInterval(-86400) { return }
        searching.insert(id)
        messages[id] = nil
        defer { searching.remove(id) }

        let result = await service.lookup(
            title: title,
            platform: platform,
            language: language,
            sourceURL: source,
            titleID: titleID,
            onText: { [weak self] partial in
                await self?.applyText(partial, id: id, language: language)
            }
        )
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
            let stem = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined() + "-" + UUID().uuidString
            if let image = result.artworkData, UIImage(data: image) != nil {
                let file = stem + "-cover.image"
                try image.write(to: root.appendingPathComponent(file), options: .atomic)
                record.cover = file
            }
            if let image = result.backdropData, UIImage(data: image) != nil {
                let file = stem + "-backdrop.image"
                try image.write(to: root.appendingPathComponent(file), options: .atomic)
                record.backdrop = file
            }
            record.language = language
            record.updated = .now
            var updated = records
            updated[id] = record
            try JSONEncoder().encode(updated).write(to: root.appendingPathComponent("index.json"), options: .atomic)
            let old = records[id]
            records = updated
            for file in [old?.cover, old?.backdrop].compactMap({ $0 }) where file != record.cover && file != record.backdrop {
                imageCache.removeObject(forKey: file as NSString)
                try? FileManager.default.removeItem(at: root.appendingPathComponent(file))
            }
            messages[id] = "游戏信息已更新"
        } catch {
            messages[id] = "保存游戏信息失败：" + error.localizedDescription
        }
    }
}

struct PhoneMetadataSection: View {
    @ObservedObject var metadata: PhoneGameMetadata
    let id: String
    let lookup: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("游戏简介")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                Spacer()
                Button(action: lookup) {
                    HStack(spacing: 6) {
                        if metadata.searching.contains(id) {
                            ProgressView().controlSize(.mini).tint(.white)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        Text(metadata.searching.contains(id) ? "查找中…" : "刷新资料")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 11)
                    .frame(height: 30)
                    .background(Color.white.opacity(0.09), in: Capsule())
                    .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(metadata.searching.contains(id))
            }

            if let synopsis = metadata.records[id]?.synopsis, !synopsis.isEmpty {
                Text(synopsis)
                    .font(.system(size: 13))
                    .lineSpacing(4)
                    .foregroundStyle(.white.opacity(0.78))
                    .textSelection(.enabled)
            } else {
                Text(metadata.searching.contains(id) ? "正在联网查找简介与封面…" : "点击「刷新资料」自动匹配在线简介与封面。")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.48))
            }

            if let message = metadata.messages[id] {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
            }

            if let source = metadata.records[id]?.source,
               let url = URL(string: source),
               ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                Divider().overlay(Color.white.opacity(0.08))
                HStack {
                    Text("简介来源")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                    Spacer()
                    Link(destination: url) {
                        HStack(spacing: 4) {
                            Text(url.host ?? "查看来源")
                                .lineLimit(1)
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.82))
                    }
                }
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.09), lineWidth: 1))
    }
}
