import CryptoKit
import Foundation

struct CloudSaveSlot: Identifiable, Sendable {
    let id: String
    let title: String
    let location: URL
    var fileName: String? = nil
}

// Immutable snapshots keep competing offline edits available until the user
// chooses a revision. A manifest is published only after every file is copied.
final class CloudSaveSyncStore {
    struct Revision: Codable, Identifiable, Sendable {
        let id: String
        let slot: String
        let title: String
        let parents: [String]
        let digest: String
        let files: [String: String]
        let created: Date
    }
    struct Conflict: Identifiable, Sendable {
        let slot: CloudSaveSlot
        let revisions: [Revision]
        var id: String { slot.id }
    }
    struct Result: Sendable {
        var uploaded = 0
        var downloaded = 0
        var conflicts: [Conflict] = []
    }
    private struct State: Codable {
        var digest: String
        var heads: [String]
    }
    private static let lock = NSLock()
    private let fm = FileManager.default
    private let localState: URL
    private let backupRoot: URL
    private var states: [String: State]
    private let encoder = JSONEncoder()

    init(stateRoot: URL? = nil) throws {
        let support = try stateRoot ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("GameCenter/SaveSync")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        localState = support.appendingPathComponent("state.json")
        #if os(iOS)
        backupRoot = try stateRoot.map { $0.appendingPathComponent("Backups") } ?? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Export/SaveSyncBackups")
        #else
        backupRoot = support.appendingPathComponent("Backups")
        #endif
        states = (try? JSONDecoder().decode([String: State].self, from: Data(contentsOf: localState))) ?? [:]
        encoder.outputFormatting = [.sortedKeys]
    }

    func sync(_ slots: [CloudSaveSlot], cloud: URL, choice: (slot: String, revision: String?)? = nil) throws -> Result {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        guard Set(slots.map(\.id)).count == slots.count else {
            throw Failure("发现重复的游戏标识，请检查同名 ROM 后重新同步。")
        }
        let ordered = slots.sorted { $0.location.resolvingSymlinksInPath().path < $1.location.resolvingSymlinksInPath().path }
        for (previous, next) in zip(ordered, ordered.dropFirst()) {
            let left = previous.location.resolvingSymlinksInPath().path
            let right = next.location.resolvingSymlinksInPath().path
            if left == right || (previous.fileName == nil && right.hasPrefix(left + "/")) {
                throw Failure("“\(previous.title)”和“\(next.title)”的本机存档位置重叠，请分别选择各自实际使用的存档位置。")
            }
        }
        // Another settings window may have completed a sync while we waited.
        states = (try? JSONDecoder().decode([String: State].self, from: Data(contentsOf: localState))) ?? states
        var result = Result()
        for slot in slots {
            let folder = cloud.appendingPathComponent("GameCenterSaves-v1/" + hash(Data(slot.id.utf8)))
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let revisions = try readRevisions(folder, slot: slot.id)
            let parents = Set(revisions.flatMap(\.parents))
            let heads = revisions.filter { !parents.contains($0.id) }
            let localFiles = try files(slot)
            let digest = fingerprint(localFiles)
            let state = states[slot.id]
            let selecting = choice?.slot == slot.id
            if selecting, let revisionID = choice?.revision {
                guard let revision = revisions.first(where: { $0.id == revisionID }) else { throw Failure("所选云端版本还未下载完成，请稍后重试。") }
                try restore(revision, folder: folder, slot: slot)
                // Publish a merge revision so all other devices see resolution.
                let merged = try publish(slot, folder: folder, parents: heads.map(\.id))
                states[slot.id] = State(digest: merged.digest, heads: [merged.id])
                result.downloaded += 1
            } else if selecting {
                let revision = try publish(slot, folder: folder, parents: heads.map(\.id))
                states[slot.id] = State(digest: revision.digest, heads: [revision.id])
                result.uploaded += 1
            } else if heads.count == 1, let head = heads.first, head.digest == digest {
                states[slot.id] = State(digest: digest, heads: [head.id])
            } else if heads.isEmpty {
                if !localFiles.isEmpty {
                    let revision = try publish(slot, folder: folder, parents: [])
                    states[slot.id] = State(digest: revision.digest, heads: [revision.id])
                    result.uploaded += 1
                }
            } else if heads.count == 1, let head = heads.first,
                      (state?.digest == digest || (state == nil && localFiles.isEmpty)) {
                try restore(head, folder: folder, slot: slot)
                states[slot.id] = State(digest: head.digest, heads: [head.id])
                result.downloaded += 1
            } else if let state, Set(state.heads) == Set(heads.map(\.id)) {
                let revision = try publish(slot, folder: folder, parents: heads.map(\.id))
                states[slot.id] = State(digest: revision.digest, heads: [revision.id])
                result.uploaded += 1
            } else {
                result.conflicts.append(Conflict(slot: slot, revisions: heads))
            }
            try encoder.encode(states).write(to: localState, options: .atomic)
        }
        return result
    }

    private func readRevisions(_ folder: URL, slot: String) throws -> [Revision] {
        var revisions: [Revision] = []
        for file in try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) where file.pathExtension == "json" {
            try download(file)
            let revision = try JSONDecoder().decode(Revision.self, from: Data(contentsOf: file))
            guard revision.slot == slot, UUID(uuidString: revision.id) != nil,
                  revision.files.keys.allSatisfy(validPath), revision.parents.allSatisfy({ UUID(uuidString: $0) != nil }) else {
                throw Failure("云端存档清单无效，已停止同步。")
            }
            revisions.append(revision)
        }
        return revisions
    }

    private func publish(_ slot: CloudSaveSlot, folder: URL, parents: [String]) throws -> Revision {
        let before = try files(slot)
        let id = UUID().uuidString
        let target = folder.appendingPathComponent(id)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        do {
            for path in before.keys {
                let destination = target.appendingPathComponent(path)
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: source(slot, path: path), to: destination)
                guard hash(try Data(contentsOf: destination)) == before[path] else { throw Failure("存档在读取期间发生变化，请退出游戏后重新同步。") }
            }
            guard try files(slot) == before else { throw Failure("存档在同步期间发生变化，请退出游戏后重新同步。") }
            let revision = Revision(id: id, slot: slot.id, title: slot.title, parents: parents,
                                    digest: fingerprint(before), files: before, created: .now)
            try encoder.encode(revision).write(to: folder.appendingPathComponent(id + ".json"), options: .atomic)
            return revision
        } catch {
            try? fm.removeItem(at: target)
            throw error
        }
    }

    private func restore(_ revision: Revision, folder: URL, slot: CloudSaveSlot) throws {
        let localBeforeDownload = try files(slot)
        guard fingerprint(revision.files) == revision.digest else { throw Failure("云端存档摘要校验失败。") }
        let parent = slot.location.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let stage = parent.appendingPathComponent(".save-sync-" + UUID().uuidString)
        defer { try? fm.removeItem(at: stage) }
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        for (path, digest) in revision.files {
            let file = folder.appendingPathComponent(revision.id).appendingPathComponent(path)
            try download(file)
            let data = try Data(contentsOf: file)
            guard hash(data) == digest else { throw Failure("云端存档还未完整下载或校验失败，请稍后重试。") }
            let destination = stage.appendingPathComponent(path)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: destination)
        }
        let incoming = slot.fileName.map { stage.appendingPathComponent($0) } ?? stage
        guard try files(slot) == localBeforeDownload else { throw Failure("本机存档在下载期间发生变化，已取消覆盖，请退出游戏后重试。") }
        if slot.fileName != nil, revision.files.isEmpty {
            if fm.fileExists(atPath: slot.location.path) {
                let backup = backupRoot.appendingPathComponent(UUID().uuidString)
                try fm.createDirectory(at: backup, withIntermediateDirectories: true)
                try fm.copyItem(at: slot.location, to: backup.appendingPathComponent(slot.location.lastPathComponent))
                try fm.removeItem(at: slot.location)
            }
            return
        }
        if slot.fileName != nil, !fm.fileExists(atPath: incoming.path) { throw Failure("云端版本缺少此模拟器的存档文件。") }
        if fm.fileExists(atPath: slot.location.path) {
            let backup = backupRoot.appendingPathComponent(UUID().uuidString)
            try fm.createDirectory(at: backup, withIntermediateDirectories: true)
            try fm.copyItem(at: slot.location, to: backup.appendingPathComponent(slot.location.lastPathComponent))
            _ = try fm.replaceItemAt(slot.location, withItemAt: incoming)
        } else {
            try fm.moveItem(at: incoming, to: slot.location)
        }
    }

    private func files(_ slot: CloudSaveSlot) throws -> [String: String] {
        guard fm.fileExists(atPath: slot.location.path) else { return [:] }
        if let name = slot.fileName {
            let values = try slot.location.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw Failure("存档文件类型无效。") }
            return [name: hash(try Data(contentsOf: slot.location))]
        }
        var result: [String: String] = [:]
        var traversalError: Error?
        let root = slot.location.resolvingSymlinksInPath().standardizedFileURL
        guard let files = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                                        errorHandler: { _, error in traversalError = error; return false }) else { return [:] }
        for case let file as URL in files {
            if file.lastPathComponent == ".DS_Store" { continue }
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw Failure("存档内包含目录别名，请选择实际存档目录。") }
            if values.isRegularFile == true {
                let path = file.standardizedFileURL.pathComponents.dropFirst(root.pathComponents.count).joined(separator: "/")
                result[path] = hash(try Data(contentsOf: file))
            }
        }
        if let traversalError { throw traversalError }
        return result
    }

    private func source(_ slot: CloudSaveSlot, path: String) -> URL {
        slot.fileName == nil ? slot.location.appendingPathComponent(path) : slot.location
    }
    private func download(_ file: URL) throws {
        let values = try file.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        if values.isUbiquitousItem == true,
           values.ubiquitousItemDownloadingStatus != .current,
           values.ubiquitousItemDownloadingStatus != .downloaded {
            try fm.startDownloadingUbiquitousItem(at: file)
            throw Failure("iCloud 正在下载存档，请稍后再次同步。")
        }
    }
    private func validPath(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("/") && value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    private func fingerprint(_ values: [String: String]) -> String {
        hash(Data(values.keys.sorted().map { $0 + "\t" + values[$0]! }.joined(separator: "\n").utf8))
    }
    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
