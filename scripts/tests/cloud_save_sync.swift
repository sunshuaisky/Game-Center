import Foundation

@main struct SyncTests {
    static func main() throws {
        func check(_ value: @autoclosure () throws -> Bool) throws { let passed = try value(); assert(passed) }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("gc-cloud-test-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let cloud = root.appendingPathComponent("cloud")
        let a = CloudSaveSlot(id: "switch/test", title: "Test", location: root.appendingPathComponent("a/save"))
        let b = CloudSaveSlot(id: a.id, title: a.title, location: root.appendingPathComponent("b/save"))
        let first = try CloudSaveSyncStore(stateRoot: root.appendingPathComponent("state-a"))
        let second = try CloudSaveSyncStore(stateRoot: root.appendingPathComponent("state-b"))
        func write(_ text: String, _ slot: CloudSaveSlot) throws {
            try fm.createDirectory(at: slot.location, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: slot.location.appendingPathComponent("progress"))
        }
        func read(_ slot: CloudSaveSlot) throws -> String { try String(contentsOf: slot.location.appendingPathComponent("progress"), encoding: .utf8) }
        try write("start", a)
        try check(try first.sync([a], cloud: cloud).uploaded == 1)
        try check(try second.sync([b], cloud: cloud).downloaded == 1)
        try check(try read(b) == "start")
        try write("mac progress", a)
        try write("phone progress", b)
        try check(try first.sync([a], cloud: cloud).uploaded == 1)
        let conflict = try second.sync([b], cloud: cloud)
        assert(conflict.conflicts.count == 1)
        try check(try read(b) == "phone progress")
        let revision = conflict.conflicts[0].revisions[0]
        _ = try second.sync([b], cloud: cloud, choice: (b.id, revision.id))
        try check(try read(b) == "mac progress")
        let backups = root.appendingPathComponent("state-b/Backups")
        try check(try fm.contentsOfDirectory(atPath: backups.path).count == 1)
        try write("phone next", b)
        try check(try second.sync([b], cloud: cloud).uploaded == 1)
        try check(try first.sync([a], cloud: cloud).downloaded == 1)
        try check(try read(a) == "phone next")
        // A corrupt remote revision must not replace an existing local save.
        try write("remote new", b)
        _ = try second.sync([b], cloud: cloud)
        let paths = fm.enumerator(at: cloud, includingPropertiesForKeys: nil)!
        for case let file as URL in paths where file.lastPathComponent == "progress" {
            if (try String(contentsOf: file, encoding: .utf8)) == "remote new" { try Data("broken".utf8).write(to: file) }
        }
        do { _ = try first.sync([a], cloud: cloud); assertionFailure("corrupt snapshot accepted") }
        catch { try check(try read(a) == "phone next") }
        // File adapters map different local names onto one portable battery file.
        let batteryCloud = root.appendingPathComponent("battery-cloud")
        let fa = CloudSaveSlot(id: "gba/test", title: "Battery", location: root.appendingPathComponent("game.sav"), fileName: "battery.srm")
        let fb = CloudSaveSlot(id: fa.id, title: fa.title, location: root.appendingPathComponent("battery.srm"), fileName: "battery.srm")
        try Data("sram".utf8).write(to: fa.location)
        _ = try first.sync([fa], cloud: batteryCloud)
        _ = try second.sync([fb], cloud: batteryCloud)
        try check(try Data(contentsOf: fb.location) == Data("sram".utf8))
        try fm.removeItem(at: fa.location)
        _ = try first.sync([fa], cloud: batteryCloud)
        _ = try second.sync([fb], cloud: batteryCloud)
        assert(!fm.fileExists(atPath: fb.location.path))
        // Two devices can publish while offline, producing independent heads.
        let offlineA = root.appendingPathComponent("offline-a")
        let offlineB = root.appendingPathComponent("offline-b")
        let ca = CloudSaveSlot(id: "offline", title: "Offline", location: root.appendingPathComponent("offline-save-a"))
        let cb = CloudSaveSlot(id: ca.id, title: ca.title, location: root.appendingPathComponent("offline-save-b"))
        try write("common", ca)
        _ = try first.sync([ca], cloud: offlineA)
        _ = try second.sync([cb], cloud: offlineA)
        try fm.copyItem(at: offlineA, to: offlineB)
        try write("edit a", ca)
        try write("edit b", cb)
        _ = try first.sync([ca], cloud: offlineA)
        _ = try second.sync([cb], cloud: offlineB)
        let branchFiles = fm.enumerator(at: offlineB, includingPropertiesForKeys: nil)!
        for case let file as URL in branchFiles {
            let relative = file.resolvingSymlinksInPath().pathComponents.dropFirst(offlineB.resolvingSymlinksInPath().pathComponents.count).joined(separator: "/")
            let target = offlineA.appendingPathComponent(relative)
            if !fm.fileExists(atPath: target.path) { try fm.copyItem(at: file, to: target) }
        }
        let branches = try first.sync([ca], cloud: offlineA)
        assert(branches.conflicts.count == 1 && branches.conflicts[0].revisions.count == 2)
        try check(try read(ca) == "edit a")
        print("PASS upload, download, conflict, backup, merge, corrupt snapshot rejection, battery mapping and deletion")
    }
}
