import Darwin
import Foundation

/// Serializes builds sharing a cache and removes complete, regenerable cache units.
final class SwitchBuildCache {
    private let descriptor: Int32
    private let root: URL

    init(outputDirectory: URL) throws {
        root = outputDirectory.appendingPathComponent("build/cache", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        descriptor = open(root.appendingPathComponent("maintenance.lock").path,
                          O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw NSError(domain: "SwitchBuildCache", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "这个 Switch 目录正在构建游戏，请等待当前构建结束后重试。"])
        }
        try? Self.prune(root: root)
    }

    func finish() {
        try? Self.prune(root: root)
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    /// Cache namespaces are atomic units, so databases and compiler manifests stay together.
    static func prune(root: URL, budget: Int64 = 2 * 1024 * 1024 * 1024,
                      maximumAge: TimeInterval = 30 * 86400) throws {
        let fm = FileManager.default
        func children(_ folder: URL) -> [URL] {
            guard let values = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true else { return [] }
            return (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        }
        let units = children(root.appendingPathComponent("nxnative")) +
            children(root.appendingPathComponent("S2Arm")).flatMap { children($0) }
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isRegularFileKey,
                                       .totalFileAllocatedSizeKey, .contentModificationDateKey]
        var entries: [(url: URL, bytes: Int64, modified: Date)] = []
        for unit in units {
            guard let values = try? unit.resourceValues(forKeys: keys), values.isSymbolicLink != true else { continue }
            var bytes = Int64(values.totalFileAllocatedSize ?? 0)
            var modified = values.contentModificationDate ?? .distantPast
            if let walker = fm.enumerator(at: unit, includingPropertiesForKeys: Array(keys)) {
                for case let file as URL in walker {
                    let info = try file.resourceValues(forKeys: keys)
                    if info.isSymbolicLink == true { walker.skipDescendants(); continue }
                    bytes += Int64(info.totalFileAllocatedSize ?? 0)
                    modified = max(modified, info.contentModificationDate ?? .distantPast)
                }
            }
            entries.append((unit, bytes, modified))
        }
        var total = entries.reduce(Int64(0)) { $0 + $1.bytes }
        let cutoff = Date().addingTimeInterval(-maximumAge)
        for entry in entries.sorted(by: { $0.modified < $1.modified }) {
            guard total > budget || entry.modified < cutoff else { continue }
            try fm.removeItem(at: entry.url)
            total -= entry.bytes
        }
    }
}
