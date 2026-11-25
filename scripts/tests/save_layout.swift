import Foundation

@main struct SaveLayoutTests {
    static func main() throws {
        func check(_ condition: Bool) { precondition(condition) }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let saves = root.appendingPathComponent("save")
        let shared = GameSaveLayout.folder(root: root, platform: "switch", game: "0100000000000000")
        let oldS2 = root.appendingPathComponent("Switch/0100000000000000/UserData/S2Arm/SaveData")
        let oldNX = root.appendingPathComponent("Switch/0100000000000000/UserData/NXNative/Saves")
        func put(_ text: String, _ file: URL) throws {
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
        }
        try put("S2 progress", oldS2.appendingPathComponent("save/account/slot"))
        try put("device", oldS2.appendingPathComponent("save_device/device"))
        try put("NX extra", oldNX.appendingPathComponent("account/other"))
        try put("NX conflicting progress", oldNX.appendingPathComponent("account/slot"))
        try GameSaveLayout.migrate(oldS2, to: shared, saveRoot: saves)
        try GameSaveLayout.migrate(oldNX, to: shared.appendingPathComponent("save"), saveRoot: saves)
        check((try String(contentsOf: oldNX.appendingPathComponent("account/slot"), encoding: .utf8)) == "S2 progress")
        check((try String(contentsOf: oldS2.appendingPathComponent("save/account/other"), encoding: .utf8)) == "NX extra")
        try put("NX updated", oldNX.appendingPathComponent("account/slot"))
        check((try String(contentsOf: oldS2.appendingPathComponent("save/account/slot"), encoding: .utf8)) == "NX updated")
        let backups = fm.enumerator(at: saves.appendingPathComponent("MigrationBackups"), includingPropertiesForKeys: [.isRegularFileKey])!
        var preservedConflict = false
        while let url = backups.nextObject() as? URL {
            if (try? String(contentsOf: url, encoding: .utf8)) == "NX conflicting progress" { preservedConflict = true }
        }
        check(preservedConflict)
        try GameSaveLayout.migrate(oldS2, to: shared, saveRoot: saves)
        try GameSaveLayout.migrate(oldNX, to: shared.appendingPathComponent("save"), saveRoot: saves)
        check((try String(contentsOf: shared.appendingPathComponent("save/account/slot"), encoding: .utf8)) == "NX updated")
        let oldBattery = root.appendingPathComponent("ROMs/GB/Test.sav")
        let battery = GameSaveLayout.folder(root: root, platform: "gb", game: "Test").appendingPathComponent("Test.sav")
        try put("battery", oldBattery)
        try GameSaveLayout.migrate(oldBattery, to: battery, saveRoot: saves)
        check((try String(contentsOf: battery, encoding: .utf8)) == "battery")
        let relocated = root.appendingPathComponent("oldUserData/SaveData")
        try fm.createDirectory(at: relocated.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: relocated.path, withDestinationPath: "/missing/old-ios-container/Documents/GameLibrary/save/switch/0100000000000000")
        try GameSaveLayout.migrate(relocated, to: shared, saveRoot: saves)
        check((try String(contentsOf: relocated.appendingPathComponent("save/account/slot"), encoding: .utf8)) == "NX updated")
        check(!(try fm.destinationOfSymbolicLink(atPath: relocated.path)).hasPrefix("/"))
        let renamed = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try fm.moveItem(at: root, to: renamed)
        defer { try? fm.removeItem(at: renamed) }
        check((try String(contentsOf: renamed.appendingPathComponent("oldUserData/SaveData/save/account/slot"), encoding: .utf8)) == "NX updated")
        try fm.moveItem(at: renamed, to: root)
        let nested = root.appendingPathComponent("legacy")
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        do {
            try GameSaveLayout.migrate(nested, to: nested.appendingPathComponent("child"), saveRoot: saves)
            preconditionFailure("Recursive migration must be rejected")
        } catch {}
        print("PASS: engine-shared account/device saves, legacy alias writes, conflict backup, repeat migration, battery files, recursive-path rejection")
    }
}
