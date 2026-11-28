import CryptoKit
import ImageIO
import SwiftUI
import UIKit

@MainActor
final class PhoneGameMetadata: ObservableObject {
    struct LookupTarget: Sendable {
        let id: String
        let title: String
        let platformID: String
        let source: URL?
        let titleID: String?
    }

    struct Record: Codable {
        var title: String?
        var synopsis: String?
        var source: String?
        var cover: String?
        var backdrop: String?
        var status: String?
        var language: String
        var updated: Date
    }

    @Published private(set) var records: [String: Record] = [:]
    @Published private(set) var searching: Set<String> = []
    @Published private(set) var messages: [String: String] = [:]
    @Published private(set) var imageRevision: UInt64 = 0

    private let service: GameMetadataService
    private let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("GameCenter/Metadata")
    private let imageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 160
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()
    private var inFlightImages: Set<String> = []

    private struct QueueJob {
        let target: LookupTarget
        let language: String
        let force: Bool
    }
    private var queue: [QueueJob] = []
    private var queuedIDs: Set<String> = []
    private var activeWorkers = 0

    init(service: GameMetadataService = GameMetadataService()) {
        self.service = service
        let indexURL = root.appendingPathComponent("index.json")
        if let data = try? Data(contentsOf: indexURL),
           let saved = try? JSONDecoder().decode([String: Record].self, from: data) {
            records = saved
        }
    }

    func image(for id: String, backdrop: Bool = false) -> UIImage? {
        _ = imageRevision
        guard let record = records[id],
              let file = backdrop ? (record.backdrop ?? record.cover) : record.cover else { return nil }
        let variantKey = (backdrop ? "bg:" : "cv:") + file
        if let cached = imageCache.object(forKey: variantKey as NSString) {
            return cached
        }
        preloadImage(file: file, variantKey: variantKey, maxPixelSize: backdrop ? 1920 : 512)
        return nil
    }

    private func preloadImage(file: String, variantKey: String, maxPixelSize: Int) {
        guard inFlightImages.insert(variantKey).inserted else { return }
        let url = root.appendingPathComponent(file)
        Task.detached(priority: .userInitiated) { [weak self] in
            let decoded = Self.downsampleImage(at: url, maxPixelSize: maxPixelSize)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.inFlightImages.remove(variantKey)
                if let (image, cost) = decoded {
                    self.imageCache.setObject(image, forKey: variantKey as NSString, cost: max(1, cost))
                    self.imageRevision &+= 1
                }
            }
        }
    }

    nonisolated private static func downsampleImage(at url: URL, maxPixelSize: Int) -> (UIImage, Int)? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else {
            return nil
        }
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
            return nil
        }
        return (UIImage(cgImage: cgImage), cgImage.width * cgImage.height * 4)
    }

    func bundledImage(named name: String?) -> UIImage? {
        guard let name else { return nil }
        return UIImage(named: name)
    }

    private func needsRefresh(id: String, language: String) -> Bool {
        let fm = FileManager.default
        guard let record = records[id] else { return true }
        let hasCover = record.cover.map { fm.fileExists(atPath: root.appendingPathComponent($0).path) } ?? false
        let hasBackdrop = record.backdrop.map { fm.fileExists(atPath: root.appendingPathComponent($0).path) } ?? false
        let effectiveStatus = record.status ?? ((record.synopsis != nil || hasCover || hasBackdrop) ? "found" : nil)
        return MetadataRefreshPolicy.needsRefresh(
            status: effectiveStatus,
            savedLanguage: record.language,
            language: language,
            hasSynopsis: record.synopsis?.isEmpty == false,
            hasArtwork: hasCover,
            hasBackdrop: hasBackdrop,
            updated: record.updated
        )
    }

    /// Enqueues missing or outdated metadata across all games using the exact same
    /// refresh policy and bounded background workers as macOS.
    func enqueueMissing(for targets: [LookupTarget], force: Bool = false) {
        let language = MetadataRefreshPolicy.preferredLanguage()
        var effectiveForce = force
        if UserDefaults.standard.integer(forKey: MetadataRefreshPolicy.queryVersionDefaultsKey) < MetadataRefreshPolicy.currentQueryVersion {
            UserDefaults.standard.set(MetadataRefreshPolicy.currentQueryVersion, forKey: MetadataRefreshPolicy.queryVersionDefaultsKey)
            effectiveForce = true
        }
        for target in targets {
            enqueue(target, language: language, force: effectiveForce, prioritize: false)
        }
        processQueue()
    }

    /// Prioritizes a specific game (e.g. currently selected or opened in detail sheet)
    /// to the front of the background lookup queue.
    func prioritize(_ target: LookupTarget, force: Bool = false) {
        let language = MetadataRefreshPolicy.preferredLanguage()
        enqueue(target, language: language, force: force, prioritize: true)
        processQueue()
    }

    private func enqueue(_ target: LookupTarget, language: String, force: Bool, prioritize: Bool) {
        guard GameMetadataPlatform(platformID: target.platformID) != nil else { return }
        guard !searching.contains(target.id) else { return }
        if !force && !needsRefresh(id: target.id, language: language) { return }

        if queuedIDs.contains(target.id) {
            if prioritize, let idx = queue.firstIndex(where: { $0.target.id == target.id }) {
                let existing = queue.remove(at: idx)
                let upgraded = QueueJob(target: target, language: language, force: existing.force || force)
                queue.insert(upgraded, at: 0)
            }
            return
        }

        let job = QueueJob(target: target, language: language, force: force)
        queuedIDs.insert(target.id)
        if prioritize {
            queue.insert(job, at: 0)
        } else {
            queue.append(job)
        }
    }

    private func processQueue() {
        while activeWorkers < 2, !queue.isEmpty {
            activeWorkers += 1
            Task { [weak self] in
                guard let self else { return }
                defer {
                    self.activeWorkers -= 1
                    self.processQueue()
                }
                while !self.queue.isEmpty {
                    let job = self.queue.removeFirst()
                    self.queuedIDs.remove(job.target.id)
                    await self.performLookup(target: job.target, language: job.language, force: job.force)
                }
            }
        }
    }

    func lookup(id: String, title: String, platformID: String, source: URL?, titleID: String?, force: Bool = false) async {
        let language = MetadataRefreshPolicy.preferredLanguage()
        let target = LookupTarget(id: id, title: title, platformID: platformID, source: source, titleID: titleID)
        await performLookup(target: target, language: language, force: force)
    }

    private func persistIndex() async {
        let rootDir = root
        let snapshot = records
        do {
            try await Task.detached(priority: .utility) {
                try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
                try JSONEncoder().encode(snapshot).write(to: rootDir.appendingPathComponent("index.json"), options: .atomic)
            }.value
        } catch {
            // Non-fatal: caller reports errors when saving final record.
        }
    }

    private func applyText(_ result: GameMetadataResult, id: String, language: String) async {
        var record = records[id] ?? Record(status: "searching", language: language, updated: .distantPast)
        if let title = result.title { record.title = title }
        if let synopsis = result.synopsis { record.synopsis = synopsis }
        if let source = result.metadataSourceURL { record.source = source }
        var updated = records
        updated[id] = record
        records = updated
        await persistIndex()
    }

    private func applyBackdrop(_ data: Data, id: String, language: String) async {
        guard MetadataRefreshPolicy.isValidImageData(data) else { return }
        let rootDir = root
        let oldBackdrop = records[id]?.backdrop
        let newFile: String? = try? await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
            let stem = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined() + "-" + UUID().uuidString
            let file = stem + "-backdrop.image"
            try data.write(to: rootDir.appendingPathComponent(file), options: .atomic)
            return file
        }.value
        guard let newFile else { return }

        var record = records[id] ?? Record(status: "searching", language: language, updated: .distantPast)
        record.backdrop = newFile
        var updated = records
        updated[id] = record
        records = updated
        if let oldBackdrop, oldBackdrop != newFile {
            imageCache.removeObject(forKey: ("bg:" + oldBackdrop) as NSString)
            let staleURL = rootDir.appendingPathComponent(oldBackdrop)
            Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: staleURL) }
        }
        imageRevision &+= 1
        await persistIndex()
    }

    private func performLookup(target: LookupTarget, language: String, force: Bool) async {
        let id = target.id
        guard !searching.contains(id), let platform = GameMetadataPlatform(platformID: target.platformID) else { return }
        if !force && !needsRefresh(id: id, language: language) { return }

        searching.insert(id)
        messages[id] = nil
        if var existing = records[id] {
            existing.status = "searching"
            var updated = records
            updated[id] = existing
            records = updated
        }
        defer { searching.remove(id) }

        let result = await service.lookup(
            title: target.title,
            platform: platform,
            language: language,
            sourceURL: target.source,
            titleID: MetadataRefreshPolicy.normalizedSwitchTitleID(target.titleID),
            onText: { [weak self] partial in
                await self?.applyText(partial, id: id, language: language)
            },
            onBackdrop: { [weak self] data in
                await self?.applyBackdrop(data, id: id, language: language)
            }
        )

        let rootDir = root
        let existingRecord = records[id]
        guard result.hasMetadata else {
            var record = existingRecord ?? Record(status: "notFound", language: language, updated: .now)
            record.status = (record.synopsis != nil || record.cover != nil || record.backdrop != nil) ? "found" : "notFound"
            record.language = language
            record.updated = .now
            var updated = records
            updated[id] = record
            records = updated
            await persistIndex()
            messages[id] = "暂未查到游戏信息，请检查网络或稍后重试。已有信息会保留。"
            return
        }

        let existingBackdropFile = existingRecord?.backdrop
        do {
            struct WrittenMedia {
                var coverFile: String?
                var backdropFile: String?
                var clearExistingBackdrop = false
            }
            let written = try await Task.detached(priority: .utility) { () throws -> WrittenMedia in
                try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
                let stem = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined() + "-" + UUID().uuidString
                var media = WrittenMedia()
                if let image = result.artworkData, MetadataRefreshPolicy.isValidImageData(image) {
                    let file = stem + "-cover.image"
                    try image.write(to: rootDir.appendingPathComponent(file), options: .atomic)
                    media.coverFile = file
                }
                if let image = result.backdropData, MetadataRefreshPolicy.isValidImageData(image) {
                    let file = stem + "-backdrop.image"
                    try image.write(to: rootDir.appendingPathComponent(file), options: .atomic)
                    media.backdropFile = file
                } else if let existingBackdropFile {
                    let existingURL = rootDir.appendingPathComponent(existingBackdropFile)
                    if !MetadataRefreshPolicy.isAcceptableBackdrop(at: existingURL) {
                        media.clearExistingBackdrop = true
                    }
                }
                return media
            }.value

            var record = records[id] ?? Record(language: language, updated: .now)
            if let title = result.title { record.title = title }
            if let synopsis = result.synopsis { record.synopsis = synopsis }
            if let source = result.metadataSourceURL { record.source = source }
            if let newCover = written.coverFile { record.cover = newCover }
            if let newBackdrop = written.backdropFile {
                record.backdrop = newBackdrop
            } else if written.clearExistingBackdrop {
                record.backdrop = nil
            }
            record.status = "found"
            record.language = language
            record.updated = .now

            let old = records[id]
            var updated = records
            updated[id] = record
            records = updated
            let snapshot = updated
            let staleFiles = [old?.cover, old?.backdrop].compactMap { $0 }.filter { $0 != record.cover && $0 != record.backdrop }
            for file in staleFiles {
                imageCache.removeObject(forKey: ("cv:" + file) as NSString)
                imageCache.removeObject(forKey: ("bg:" + file) as NSString)
            }
            try await Task.detached(priority: .utility) {
                try JSONEncoder().encode(snapshot).write(to: rootDir.appendingPathComponent("index.json"), options: .atomic)
                for file in staleFiles {
                    try? FileManager.default.removeItem(at: rootDir.appendingPathComponent(file))
                }
            }.value
            imageRevision &+= 1
            messages[id] = "游戏信息已更新"
        } catch {
            var record = records[id] ?? Record(status: "error", language: language, updated: .now)
            record.status = record.synopsis == nil ? "error" : "found"
            record.language = language
            record.updated = .now
            var updated = records
            updated[id] = record
            records = updated
            await persistIndex()
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
                    .foregroundStyle(.white.opacity(0.92))
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(Color.white.opacity(0.09), in: Capsule())
                    .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 0.75))
                }
                .buttonStyle(PhoneTactileButtonStyle())
                .disabled(metadata.searching.contains(id))
            }

            if let synopsis = metadata.records[id]?.synopsis, !synopsis.isEmpty {
                Text(synopsis)
                    .font(.system(size: 13.5))
                    .lineSpacing(4.5)
                    .foregroundStyle(.white.opacity(0.82))
                    .textSelection(.enabled)
            } else {
                Text(metadata.searching.contains(id) ? "正在联网查找简介与封面…" : "点击「刷新资料」自动匹配在线简介与封面。")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.50))
            }

            if let message = metadata.messages[id] {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.56))
            }

            if let source = metadata.records[id]?.source,
               let url = URL(string: source),
               ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                Divider().overlay(Color.white.opacity(0.08))
                HStack {
                    Text("简介来源")
                        .font(.system(size: 11, weight: .medium))
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
                        .foregroundStyle(.white.opacity(0.86))
                    }
                }
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.10), lineWidth: 0.75))
    }
}
