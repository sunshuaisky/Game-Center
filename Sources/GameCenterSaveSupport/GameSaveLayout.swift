import Foundation

public enum GameSaveLayout {
    public static func platform(_ id: String) -> String {
        ["threeDS": "3ds", "famicom": "nes", "superFamicom": "snes", "megaDrive": "md", "switchConsole": "switch", "macOS": "mac"][id] ?? id.lowercased()
    }
    public static func folder(root: URL, platform id: String, game: String? = nil) -> URL {
        let base = root.appendingPathComponent("save/" + platform(id), isDirectory: true)
        return game.map { base.appendingPathComponent($0, isDirectory: true) } ?? base
    }
    public static func root(besidePlatformDirectory directory: URL) -> URL {
        directory.lastPathComponent.lowercased() == "switch" ? directory.deletingLastPathComponent() : directory
    }

    /// Repair prior migrations too: moving a shader cache into a save backup
    /// still leaves non-save data in `save`. Preserve it in the system cache.
    public static func evacuateSwitchCaches(saveRoot: URL, cache: URL) throws {
        let fm = FileManager.default
        guard let items = fm.enumerator(at: saveRoot, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return }
        var found: [URL] = []
        for case let item as URL in items {
            if try item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { items.skipDescendants(); continue }
            if ["pso_archive", "pso_user.tsv"].contains(item.lastPathComponent) {
                found.append(item); items.skipDescendants()
            }
        }
        for source in found {
            let target = cache.appendingPathComponent("Recovered/" + UUID().uuidString + "/" + source.lastPathComponent)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: source, to: target)
        }
    }

    /// Keep the engine interchange folder unambiguous. NXNative's default
    /// shader cache used to live beside DM_SAVE and made S2Arm import the wrapper
    /// itself as account data. Retain those artifacts outside the save tree.
    public static func prepareSwitchFolder(_ folder: URL, cache: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let artifacts = ["pso_archive", "pso_user.tsv", "save.work", "save.new", "save_device.work", "save_device.new", ".DS_Store"]
        for name in artifacts {
            let source = folder.appendingPathComponent(name)
            guard fm.fileExists(atPath: source.path) else { continue }
            let target = cache.appendingPathComponent("Recovered/" + UUID().uuidString + "/" + name)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: source, to: target)
        }
        // Repair the previously mis-imported wrapper without discarding either
        // version. A user marker plus nested account save identifies this bug;
        // a game directory merely named "save" is not sufficient evidence.
        let account = folder.appendingPathComponent("save")
        if fm.fileExists(atPath: account.appendingPathComponent("user").path),
           fm.fileExists(atPath: account.appendingPathComponent("save").path) {
            for name in artifacts {
                let source = account.appendingPathComponent(name)
                if fm.fileExists(atPath: source.path) {
                    let target = cache.appendingPathComponent("Recovered/" + UUID().uuidString + "/" + name)
                    try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.moveItem(at: source, to: target)
                }
            }
            let backup = folder.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("MigrationBackups/" + UUID().uuidString + "/nested-switch-save")
            try fm.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: folder, to: backup)
            // The nested tree is the committed snapshot imported from the Mac.
            // The outer files were created by the failed launch and can have
            // newer timestamps despite representing an empty game. Restore the
            // complete snapshot, including its index, rather than mix versions.
            let stage = folder.appendingPathComponent(".save-repair-" + UUID().uuidString)
            try fm.copyItem(at: account.appendingPathComponent("save"), to: stage)
            for name in ["save_device", "user"] {
                let source = account.appendingPathComponent(name)
                if fm.fileExists(atPath: source.path) {
                    let target = folder.appendingPathComponent(name)
                    if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                    try fm.copyItem(at: source, to: target)
                }
            }
            try fm.removeItem(at: account)
            try fm.moveItem(at: stage, to: account)
        }
        for name in ["save", "save_device"] {
            try fm.createDirectory(at: folder.appendingPathComponent(name), withIntermediateDirectories: true)
        }
    }

    // Keep the destination authoritative and retain every differing old version
    // in a visible migration backup. Legacy entry points become aliases only
    // after copying succeeds, so old builds continue using the canonical data.
    public static func migrate(_ old: URL, to destination: URL, saveRoot: URL) throws {
        let fm = FileManager.default
        let oldPath = old.standardizedFileURL.path
        let newPath = destination.standardizedFileURL.path
        guard oldPath != newPath else { return }
        let link = try? fm.destinationOfSymbolicLink(atPath: old.path)
        guard fm.fileExists(atPath: old.path) || link != nil else { return }
        if old.resolvingSymlinksInPath().path == destination.resolvingSymlinksInPath().path { return }
        if link != nil, old.resolvingSymlinksInPath().path.hasPrefix(saveRoot.resolvingSymlinksInPath().path + "/") {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            try fm.removeItem(at: old)
            try createAlias(at: old, to: destination)
            return
        }
        if let link, !fm.fileExists(atPath: old.path), fm.fileExists(atPath: destination.path) {
            // AltStore/iOS can relocate the entire data container on upgrade.
            // The real canonical data moved with it, but old absolute aliases
            // still name the previous UUID. Preserve that reference and rebind.
            let record = saveRoot.appendingPathComponent("MigrationBackups/" + UUID().uuidString + "/legacy-alias.txt")
            try fm.createDirectory(at: record.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(link.utf8).write(to: record)
            try fm.removeItem(at: old)
            try createAlias(at: old, to: destination)
            return
        }
        let source = old.resolvingSymlinksInPath()
        guard !destination.resolvingSymlinksInPath().path.hasPrefix(source.path + "/") else {
            throw Failure("新存档目录不能位于旧存档目录内部。")
        }
        let backup = saveRoot.appendingPathComponent("MigrationBackups/" + UUID().uuidString)
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)
        try fm.copyItem(at: source, to: backup.appendingPathComponent(old.lastPathComponent))
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try merge(source, into: destination)
        try fm.removeItem(at: old)
        try createAlias(at: old, to: destination)
    }

    // Relative aliases survive app-container UUID changes and moving a whole
    // library directory. Resolve both parents consistently (/var vs /private/var).
    public static func createAlias(at alias: URL, to destination: URL) throws {
        let from = alias.deletingLastPathComponent().resolvingSymlinksInPath().pathComponents
        let to = destination.resolvingSymlinksInPath().pathComponents
        var common = 0
        while common < min(from.count, to.count), from[common] == to[common] { common += 1 }
        let relative = (Array(repeating: "..", count: from.count - common) + to.dropFirst(common)).joined(separator: "/")
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: relative.isEmpty ? "." : relative)
    }

    private static func merge(_ source: URL, into target: URL) throws {
        let fm = FileManager.default
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw Failure("旧存档内部包含目录别名，已保留原数据，请检查迁移备份。") }
        if values.isDirectory == true {
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            for file in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) where file.lastPathComponent != ".DS_Store" {
                try merge(file, into: target.appendingPathComponent(file.lastPathComponent))
            }
        } else if !fm.fileExists(atPath: target.path) {
            try fm.copyItem(at: source, to: target)
        }
    }
    public struct Failure: LocalizedError {
        public let errorDescription: String?
        public init(_ message: String) { errorDescription = message }
    }
}
