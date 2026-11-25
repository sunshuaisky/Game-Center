import Foundation

@main
struct CacheChecks {
    static func main() throws {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: temporary) }
        let root = temporary.appendingPathComponent("build/cache")
        func unit(_ name: String, age: TimeInterval) throws -> URL {
            let folder = root.appendingPathComponent(name)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("cache.bin")
            try Data(repeating: 42, count: 65536).write(to: file)
            for item in [file, folder] {
                try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: item.path)
            }
            return folder
        }
        let old = try unit("S2Arm/old/nuget", age: 40 * 86400)
        let older = try unit("S2Arm/current/air", age: 1000)
        let newest = try unit("nxnative/iOS", age: 0)
        let save = temporary.appendingPathComponent("save")
        try Data("save".utf8).write(to: save)
        try fm.createSymbolicLink(at: root.appendingPathComponent("nxnative/external"), withDestinationURL: temporary)
        try SwitchBuildCache.prune(root: root, budget: 100000)
        precondition(!fm.fileExists(atPath: old.path))
        precondition(!fm.fileExists(atPath: older.path))
        precondition(fm.fileExists(atPath: newest.appendingPathComponent("cache.bin").path))
        let savedData = try Data(contentsOf: save)
        precondition(savedData == Data("save".utf8))
        let lease = try SwitchBuildCache(outputDirectory: temporary)
        do {
            _ = try SwitchBuildCache(outputDirectory: temporary)
            fatalError("Concurrent build should be rejected")
        } catch {}
        withExtendedLifetime(lease) {}
        print("PASS: cache budget, expiry, symlink protection, save preservation and build lock")
    }
}
