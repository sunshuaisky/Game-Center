import CryptoKit
import Foundation
#if canImport(GameCenterSaveSupport)
import GameCenterSaveSupport
#endif

/// Synchronizes the save tree itself. Missing files are copied, never interpreted
/// as deletions. Copying preserves modification dates so downloads don't become
/// newer edits on the next device.
final class CloudSaveDirectorySync {
    struct Result: Sendable {
        var uploaded = 0
        var downloaded = 0
        var unchanged = 0
        var sameDateConflicts: [String] = []
    }
    struct SwitchTransfer: Sendable {
        let title: String
        let upload: Bool
    }
    private struct File {
        let url: URL
        let date: Date
        let size: Int
    }
    private static let lock = NSLock()
    private let fm = FileManager.default

    func sync(local: URL, cloud: URL, macBatteryNames: Bool = false, switchTransfer: SwitchTransfer? = nil, progress: @Sendable (String) -> Void = { _ in }) throws -> Result {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let local = local.resolvingSymlinksInPath().standardizedFileURL
        let cloud = cloud.resolvingSymlinksInPath().standardizedFileURL
        guard local.path != cloud.path, !local.path.hasPrefix(cloud.path + "/"), !cloud.path.hasPrefix(local.path + "/") else {
            throw Failure("本机存档和 iCloud 存档目录不能相同或相互包含。")
        }
        try fm.createDirectory(at: local, withIntermediateDirectories: true)
        try fm.createDirectory(at: cloud, withIntermediateDirectories: true)
        try repairSwitchFolders(local)
        _ = try downloadedFiles(cloud, progress: progress)
        try repairSwitchFolders(cloud)
        let localFiles = try files(local, macBatteryNames: macBatteryNames)
        let cloudFiles = try downloadedFiles(cloud, progress: progress)
        let batch = UUID().uuidString
        var result = try syncSwitch(local: local, cloud: cloud, localFiles: localFiles, cloudFiles: cloudFiles, batch: batch, transfer: switchTransfer)
        if switchTransfer != nil { return result }
        for path in Set(localFiles.keys).union(cloudFiles.keys).sorted() {
            if path.hasPrefix("switch/") { continue }
            let a = localFiles[path], b = cloudFiles[path]
            if let a, let b {
                if try digest(a) == digest(b) { result.unchanged += 1; continue }
                // Identical dates do not identify a winner. Leave both versions
                // untouched and make the exception visible instead of guessing.
                if a.date == b.date { result.sameDateConflicts.append(path); continue }
                if a.date > b.date {
                    try copy(a, over: b, to: b.url, allowedRoot: cloud, backup: cloud.deletingLastPathComponent().appendingPathComponent("Backups/\(batch)/\(path)"))
                    result.uploaded += 1
                } else {
                    try copy(b, over: a, to: a.url, allowedRoot: local, backup: local.appendingPathComponent("SyncBackups/\(batch)/\(path)"))
                    result.downloaded += 1
                }
            } else if let a {
                try copy(a, over: nil, to: cloud.appendingPathComponent(path), allowedRoot: cloud, backup: nil)
                result.uploaded += 1
            } else if let b {
                let destination = local.appendingPathComponent(localPath(path, macBatteryNames: macBatteryNames))
                try copy(b, over: nil, to: destination, allowedRoot: local, backup: nil)
                result.downloaded += 1
            }
        }
        return result
    }

    private struct SwitchCommit: Codable {
        let schema: Int
        let hashes: [String: String]
    }
    private let commitName = ".gamecenter-commit.json"

    /// Account data, its index and device data must come from one committed
    /// snapshot. Per-file merging can combine an empty index with valid slots.
    private func syncSwitch(local: URL, cloud: URL, localFiles: [String: File], cloudFiles: [String: File], batch: String, transfer: SwitchTransfer?) throws -> Result {
        var result = Result()
        let paths = Set(localFiles.keys).union(cloudFiles.keys).filter { $0.hasPrefix("switch/") }
        let titles = Set(paths.compactMap { path -> String? in
            let parts = path.split(separator: "/"); return parts.count >= 3 ? String(parts[1]) : nil
        })
        if let transfer, !titles.contains(transfer.title) { throw Failure("这款游戏还没有可以传输的存档。") }
        for title in titles.sorted() where transfer == nil || transfer?.title == title {
            let prefix = "switch/" + title + "/"
            let a = localFiles.filter { $0.key.hasPrefix(prefix) }
            let b = cloudFiles.filter { $0.key.hasPrefix(prefix) }
            func hashes(_ files: [String: File]) throws -> [String: String] {
                try files.mapValues { try digest($0).map { String(format: "%02x", $0) }.joined() }
            }
            let ah = try hashes(a), bh = try hashes(b)
            let remoteCommit = cloud.appendingPathComponent(prefix + commitName)
            if fm.fileExists(atPath: remoteCommit.path) {
                let manifest = try JSONDecoder().decode(SwitchCommit.self, from: Data(contentsOf: remoteCommit))
                guard manifest.schema == 1, manifest.hashes == bh else {
                    throw Failure("iCloud 正在传输一整份 Switch 存档，文件尚未齐全。请稍后再次同步；本机进度已保留。")
                }
            }
            // File dates can survive an emulator export. Use the last snapshot this
            // device actually synchronized to distinguish a local edit from a pull.
            let baselineURL = local.appendingPathComponent(".gcsync-baselines/" + title + ".json")
            let baseline = (try? Data(contentsOf: baselineURL)).flatMap { try? JSONDecoder().decode(SwitchCommit.self, from: $0) }
            func record(_ hashes: [String: String]) throws {
                guard baseline?.hashes != hashes else { return }
                try fm.createDirectory(at: baselineURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(SwitchCommit(schema: 1, hashes: hashes)).write(to: baselineURL, options: .atomic)
            }
            if let transfer, (transfer.upload ? a : b).isEmpty {
                throw Failure(transfer.upload ? "本机没有这款游戏的存档。" : "iCloud 还没有这款游戏的存档。")
            }
            if ah == bh {
                try record(ah)
                if !b.isEmpty, !fm.fileExists(atPath: remoteCommit.path) {
                    try JSONEncoder().encode(SwitchCommit(schema: 1, hashes: bh)).write(to: remoteCommit, options: .atomic)
                }
                result.unchanged += a.count; continue
            }
            // Account identity is not a game commit; its timestamp must never
            // make an otherwise stale snapshot win over actual progress.
            func newest(_ files: [String: File]) -> Date {
                files.filter { $0.key != prefix + "user" }.values.map(\.date).max() ?? .distantPast
            }
            let upload: Bool
            if let transfer { upload = transfer.upload }
            else if b.isEmpty { upload = true }
            else if a.isEmpty { upload = false }
            else if baseline?.hashes == ah { upload = false }
            else if baseline?.hashes == bh { upload = true }
            else if newest(a) == newest(b) {
                result.sameDateConflicts.append(prefix + "（整份存档）"); continue
            } else { upload = newest(a) > newest(b) }
            let source = upload ? a : b
            let expected = upload ? ah : bh
            let existing = upload ? b : a
            let destinationRoot = upload ? cloud : local
            let destination = destinationRoot.appendingPathComponent("switch/" + title)
            let backupRoot = upload ? cloud.deletingLastPathComponent().appendingPathComponent("Backups") : local.appendingPathComponent("SyncBackups")
            let backup = backupRoot.appendingPathComponent(batch + "/switch/" + title)
            let stage = destination.deletingLastPathComponent().appendingPathComponent(".gcsync-" + UUID().uuidString)
            try fm.createDirectory(at: stage, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: stage) }
            for (path, file) in source {
                try verify(file)
                let target = stage.appendingPathComponent(String(path.dropFirst(prefix.count)))
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: file.url, to: target)
                let values = try target.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                guard let date = values.contentModificationDate, let size = values.fileSize,
                      try digest(File(url: target, date: date, size: size)).map({ String(format: "%02x", $0) }).joined() == expected[path] else {
                    throw Failure("Switch 存档复制校验失败，原进度已保留。")
                }
            }
            guard try hashes(source) == expected else { throw Failure("游戏在同步期间修改了存档，请退出游戏后重试。") }
            if upload {
                try JSONEncoder().encode(SwitchCommit(schema: 1, hashes: expected)).write(to: stage.appendingPathComponent(commitName), options: .atomic)
            }
            var coordinationError: NSError?
            var outcome: Swift.Result<Void, Error>?
            NSFileCoordinator().coordinate(writingItemAt: destination, options: .forReplacing, error: &coordinationError) { coordinated in
                outcome = Swift.Result {
                    for file in existing.values { try verify(file) }
                    // A fresh enumeration rejects concurrent files as well as
                    // edits; replacing a snapshot must not discard new progress.
                    if fm.fileExists(atPath: coordinated.path) {
                        let current = try files(coordinated, macBatteryNames: false)
                        let relative = Set(existing.keys.map { String($0.dropFirst(prefix.count)) })
                        guard Set(current.keys) == relative else { throw Failure("Switch 存档在同步期间发生变化，已保留两端。") }
                        try fm.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try fm.copyItem(at: coordinated, to: backup)
                        _ = try fm.replaceItemAt(coordinated, withItemAt: stage, options: .usingNewMetadataOnly)
                    } else {
                        try fm.moveItem(at: stage, to: coordinated)
                    }
                }
            }
            if let coordinationError { throw coordinationError }
            guard let outcome else { throw Failure("无法协调 Switch 存档更新，请稍后重试。") }
            try outcome.get()
            try record(expected)
            if upload { result.uploaded += source.count } else { result.downloaded += source.count }
        }
        return result
    }

    private func repairSwitchFolders(_ root: URL) throws {
        try GameSaveLayout.evacuateSwitchCaches(saveRoot: root, cache: fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("GameCenter/SaveRepair"))
        let directory = root.appendingPathComponent("switch")
        guard fm.fileExists(atPath: directory.path) else { return }
        for folder in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            if folder.lastPathComponent.hasPrefix(".") { continue }
            let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw Failure("Switch 存档目录包含别名，已停止同步。") }
            if values.isDirectory == true {
                try GameSaveLayout.prepareSwitchFolder(folder, cache: fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("GameCenter/SaveRepair/" + folder.lastPathComponent))
            }
        }
    }

    private struct DownloadPending: Error { let count: Int }
    private func downloadedFiles(_ root: URL, progress: @Sendable (String) -> Void) throws -> [String: File] {
        let deadline = Date().addingTimeInterval(60)
        while true {
            do { return try files(root, macBatteryNames: false) }
            catch let pending as DownloadPending {
                guard Date() < deadline else { throw Failure("iCloud 尚有 \(pending.count) 个文件未下载完成。已请求全部下载，请保持联网后再次同步。") }
                progress("iCloud 正在下载 \(pending.count) 个存档文件，下载完成后将自动继续同步…")
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
    }

    private func files(_ root: URL, macBatteryNames: Bool) throws -> [String: File] {
        var result: [String: File] = [:]
        var pending = 0
        var error: Error?
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey,
                                         .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: Array(keys), errorHandler: { _, failure in error = failure; return false }) else {
            throw Failure("无法读取存档目录：\(root.lastPathComponent)")
        }
        for case let url as URL in enumerator {
            if ["MigrationBackups", "SyncBackups", ".DS_Store"].contains(url.lastPathComponent) || url.lastPathComponent.hasPrefix(".gcsync-") {
                enumerator.skipDescendants(); continue
            }
            let components = url.pathComponents.dropFirst(root.pathComponents.count)
            // Only committed account/device saves and account identity belong
            // in the Switch interchange tree. Never hydrate shader caches or
            // an engine's in-progress .work/.new transaction from iCloud.
            if components.first == "switch", components.count >= 3,
               !["save", "save_device", "user", commitName].contains(Array(components)[2]) {
                enumerator.skipDescendants(); continue
            }
            let values = try url.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true else { throw Failure("存档目录包含别名，已停止同步：\(url.lastPathComponent)") }
            guard values.isRegularFile == true else { continue }
            // Directory download status may be absent on iOS File Provider.
            // Only actual, explicitly not-downloaded files belong in this queue.
            if values.isUbiquitousItem == true, values.ubiquitousItemDownloadingStatus == .notDownloaded {
                try fm.startDownloadingUbiquitousItem(at: url)
                pending += 1
                continue
            }
            if url.lastPathComponent == commitName { continue }
            let relative = url.resolvingSymlinksInPath().pathComponents.dropFirst(root.resolvingSymlinksInPath().pathComponents.count).joined(separator: "/")
            let path = cloudPath(relative, macBatteryNames: macBatteryNames)
            guard result[path] == nil else { throw Failure("同一游戏出现两份对应的电池存档：\(path)") }
            guard let date = values.contentModificationDate, let size = values.fileSize else { throw Failure("无法读取存档更新时间：\(relative)") }
            result[path] = File(url: url, date: date, size: size)
        }
        if let error { throw error }
        if pending > 0 { throw DownloadPending(count: pending) }
        return result
    }

    private func cloudPath(_ path: String, macBatteryNames: Bool) -> String {
        let parts = path.split(separator: "/").map(String.init)
        if parts.count == 3, parts[0] == "nds", parts[2] == parts[1] + ".dsv" {
            return "nds/battery/" + parts[2]
        }
        if macBatteryNames, parts.count == 3, ["gb", "gbc", "gba"].contains(parts[0]), parts[2] == parts[1] + ".sav" {
            return parts[0] + "/" + parts[1] + "/battery.srm"
        }
        return path
    }
    private func localPath(_ path: String, macBatteryNames: Bool) -> String {
        let parts = path.split(separator: "/").map(String.init)
        if !macBatteryNames, parts.count == 3, parts[0] == "nds", parts[1] == "battery", parts[2].hasSuffix(".dsv") {
            return "nds/" + String(parts[2].dropLast(4)) + "/" + parts[2]
        }
        if macBatteryNames, parts.count == 3, ["gb", "gbc", "gba"].contains(parts[0]), parts[2] == "battery.srm" {
            return parts[0] + "/" + parts[1] + "/" + parts[1] + ".sav"
        }
        return path
    }
    private func verify(_ file: File) throws {
        let current = try file.url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isSymbolicLinkKey])
        guard current.isSymbolicLink != true, current.contentModificationDate == file.date, current.fileSize == file.size else {
            NSLog("Save sync changed %@: expected date %.9f size %d, actual date %.9f size %d", file.url.path, file.date.timeIntervalSince1970, file.size, current.contentModificationDate?.timeIntervalSince1970 ?? -1, current.fileSize ?? -1)
            throw Failure("存档在同步期间发生变化，已停止覆盖：\(file.url.lastPathComponent)。请退出游戏后重试。")
        }
    }
    private func digest(_ file: File) throws -> Data {
        var coordinationError: NSError?
        var outcome: Swift.Result<Data, Error>?
        NSFileCoordinator().coordinate(readingItemAt: file.url, options: .withoutChanges, error: &coordinationError) { coordinated in
            outcome = Swift.Result {
                try verify(file)
                let handle = try FileHandle(forReadingFrom: coordinated)
                defer { try? handle.close() }
                var hash = SHA256()
                while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hash.update(data: chunk) }
                try verify(file)
                return Data(hash.finalize())
            }
        }
        if let coordinationError { throw coordinationError }
        guard let outcome else { throw Failure("iCloud 文件读取尚未就绪，请稍后重试。") }
        return try outcome.get()
    }
    private func copy(_ source: File, over existing: File?, to destination: URL, allowedRoot: URL, backup: URL?) throws {
        let parent = destination.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        // Reject symlinked ancestors, including directories created after scanning.
        let actualParent = parent.resolvingSymlinksInPath().standardizedFileURL.path
        let actualRoot = allowedRoot.resolvingSymlinksInPath().standardizedFileURL.path
        guard actualParent == actualRoot || actualParent.hasPrefix(actualRoot + "/") else { throw Failure("目标存档目录包含指向外部的别名，已取消覆盖。") }
        let stage = parent.appendingPathComponent(".gcsync-" + UUID().uuidString)
        defer { try? fm.removeItem(at: stage) }
        let before = try digest(source)
        try fm.copyItem(at: source.url, to: stage)
        let stagedValues = try stage.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        guard let stagedDate = stagedValues.contentModificationDate, stagedValues.fileSize == source.size else {
            throw Failure("存档复制不完整，原存档已保留。")
        }
        let copied = File(url: stage, date: stagedDate, size: source.size)
        guard try digest(copied) == before, try digest(source) == before else { throw Failure("复制存档时校验失败，原存档已保留。") }
        var coordinationError: NSError?
        var outcome: Swift.Result<Void, Error>?
        NSFileCoordinator().coordinate(writingItemAt: destination, options: .forReplacing, error: &coordinationError) { coordinated in
            outcome = Swift.Result {
                if let existing {
                    try verify(existing)
                    if let backup {
                        try fm.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try fm.copyItem(at: existing.url, to: backup)
                    }
                    // copyItem preserves the native timestamp without a lossy
                    // Date -> filesystem conversion; retain the incoming metadata.
                    _ = try fm.replaceItemAt(coordinated, withItemAt: stage, options: .usingNewMetadataOnly)
                } else {
                    guard !fm.fileExists(atPath: coordinated.path), (try? fm.destinationOfSymbolicLink(atPath: coordinated.path)) == nil else {
                        throw Failure("同步期间出现了新的存档文件，请重新同步。")
                    }
                    try fm.moveItem(at: stage, to: coordinated)
                }
            }
        }
        if let coordinationError { throw coordinationError }
        guard let outcome else { throw Failure("无法协调 iCloud 文件访问，请稍后重试。") }
        try outcome.get()
    }
    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
