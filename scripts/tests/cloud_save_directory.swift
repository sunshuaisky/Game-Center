import Foundation

@main struct DirectorySyncTests {
    static func main() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: base) }
        let mac = base.appendingPathComponent("mac/save")
        let phone = base.appendingPathComponent("phone/save")
        let cloud = base.appendingPathComponent("cloud/Game Center存档/save")
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        // Native save timestamps have sub-microsecond precision. Reapplying a
        // Foundation Date can round them and falsely report an in-flight edit.
        let precise = Date(timeIntervalSince1970: 1_794_102_490.569250822)
        let newer = old.addingTimeInterval(30)
        func write(_ root: URL, _ path: String, _ text: String, _ date: Date) throws {
            let file = root.appendingPathComponent(path)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
            try fm.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        }
        func read(_ root: URL, _ path: String) throws -> String { try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) }
        func check(_ value: Bool) { precondition(value) }
        let sync = CloudSaveDirectorySync()
        let save = "switch/0100000000000000/save/account/progress"
        try write(mac, "switch/precise/save/file", "precision", precise)
        try write(mac, save, "mac progress", old)
        try write(mac, "SyncBackups/old", "exclude", old)
        try write(mac, "MigrationBackups/old", "exclude", old)
        let first = try sync.sync(local: mac, cloud: cloud, macBatteryNames: true)
        check(first.uploaded == 2)
        check(!fm.fileExists(atPath: cloud.appendingPathComponent("SyncBackups").path))
        _ = try sync.sync(local: phone, cloud: cloud)
        check((try read(phone, save)) == "mac progress")
        check((try phone.appendingPathComponent(save).resourceValues(forKeys: [.contentModificationDateKey])).contentModificationDate == old)
        try write(phone, save, "phone newer", newer)
        _ = try sync.sync(local: phone, cloud: cloud)
        let restored = try sync.sync(local: mac, cloud: cloud, macBatteryNames: true)
        check(restored.downloaded == 1)
        check((try read(mac, save)) == "phone newer")
        let noLoop = try sync.sync(local: mac, cloud: cloud, macBatteryNames: true)
        check(noLoop.uploaded == 0 && noLoop.downloaded == 0)
        check((try fm.contentsOfDirectory(atPath: mac.appendingPathComponent("SyncBackups").path)).count > 1)
        check((try fm.contentsOfDirectory(atPath: cloud.deletingLastPathComponent().appendingPathComponent("Backups").path)).count == 1)
        // A cloud-only game restores even if no ROM or built app is installed.
        try write(cloud, "nds/unknown-game/battery.srm", "cloud-only", newer)
        _ = try sync.sync(local: mac, cloud: cloud, macBatteryNames: true)
        check((try read(mac, "nds/unknown-game/battery.srm")) == "cloud-only")
        try write(mac, "gb/Game/Game.sav", "battery", old)
        _ = try sync.sync(local: mac, cloud: cloud, macBatteryNames: true)
        _ = try sync.sync(local: phone, cloud: cloud)
        check((try read(phone, "gb/Game/battery.srm")) == "battery")
        try write(phone, "gb/Game/battery.srm", "phone battery", newer)
        _ = try sync.sync(local: phone, cloud: cloud)
        _ = try sync.sync(local: mac, cloud: cloud, macBatteryNames: true)
        check((try read(mac, "gb/Game/Game.sav")) == "phone battery")
        try write(mac, "gba/New Game/New Game.sav", "new mac battery", newer)
        _ = try sync.sync(local: mac, cloud: cloud, macBatteryNames: true)
        let freshMac = base.appendingPathComponent("freshMac/save")
        _ = try sync.sync(local: freshMac, cloud: cloud, macBatteryNames: true)
        check((try read(freshMac, "gba/New Game/New Game.sav")) == "new mac battery")
        try write(phone, "gb/Game/battery.srm", "different but same date", newer)
        let conflict = try sync.sync(local: phone, cloud: cloud)
        check(conflict.sameDateConflicts == ["gb/Game/battery.srm"])
        check((try read(phone, "gb/Game/battery.srm")) == "different but same date")
        // Local deletion never erases the cloud copy: missing files are restored.
        try fm.removeItem(at: mac.appendingPathComponent(save))
        _ = try sync.sync(local: mac, cloud: cloud, macBatteryNames: true)
        check((try read(mac, save)) == "phone newer")
        // Reproduce NXNative shader pollution and the old S2Arm wrapper import.
        let title = "switch/01008CF01BAAC000/"
        try write(mac, title + "save/slot01/main.bin", "NX committed progress", newer)
        try write(mac, title + "save.work/slot01/main.bin", "uncommitted", newer.addingTimeInterval(100))
        try write(mac, title + "pso_archive/shader", "cache", newer)
        try write(mac, title + "pso_user.tsv", "cache index", newer)
        try write(mac, title + "user", "account", old)
        _ = try sync.sync(local: mac, cloud: cloud, macBatteryNames: true)
        check(!fm.fileExists(atPath: cloud.appendingPathComponent(title + "pso_archive").path))
        check(!fm.fileExists(atPath: cloud.appendingPathComponent(title + "save.work").path))
        // Older iOS imports included the wrapper itself inside account data.
        try write(phone, title + "save/save/slot01/main.bin", "NX committed progress", newer)
        try write(phone, title + "save/user", "account", old)
        try write(phone, title + "save/slot00/main.bin", "new empty slot", old)
        try write(phone, title + "save/save/save.meta", "committed index", newer)
        try write(phone, title + "save/save.meta", "empty index from failed launch", newer.addingTimeInterval(60))
        _ = try sync.sync(local: phone, cloud: cloud)
        check((try read(phone, title + "save/save.meta")) == "committed index")
        check((try read(phone, title + "save/slot01/main.bin")) == "NX committed progress")
        check(!fm.fileExists(atPath: phone.appendingPathComponent(title + "save/save").path))
        check(!fm.fileExists(atPath: phone.appendingPathComponent(title + "save/user").path))
        check((try read(phone, title + "user")) == "account")
        check(fm.fileExists(atPath: phone.appendingPathComponent("MigrationBackups").path))
        // A Switch commit is replaced as a unit, even if one old file has
        // a newer timestamp than that file in the incoming coherent snapshot.
        let coherent = "switch/01000000000000AA/"
        try write(mac, coherent + "save/index", "mac index", old)
        try write(mac, coherent + "save/progress", "mac data", newer)
        _ = try sync.sync(local: mac, cloud: cloud, macBatteryNames: true)
        _ = try sync.sync(local: phone, cloud: cloud)
        try write(phone, coherent + "save/index", "phone index", newer.addingTimeInterval(100))
        try write(phone, coherent + "save/progress", "phone data", old)
        try write(phone, coherent + "save/stale", "will be removed", old)
        _ = try sync.sync(local: phone, cloud: cloud)
        _ = try sync.sync(local: mac, cloud: cloud, macBatteryNames: true)
        check((try read(mac, coherent + "save/progress")) == "phone data")
        // Exported progress can retain an older timestamp than the previous session.
        try write(mac, coherent + "save/progress", "mac continuation", old)
        _ = try sync.sync(local: mac, cloud: cloud, macBatteryNames: true)
        _ = try sync.sync(local: phone, cloud: cloud)
        check((try read(phone, coherent + "save/progress")) == "mac continuation")
        try write(mac, "nds/battery/HeartGold.dsv", "Mac DS progress", old)
        _ = try sync.sync(local: mac, cloud: cloud, macBatteryNames: true)
        _ = try sync.sync(local: phone, cloud: cloud)
        check((try read(phone, "nds/HeartGold/HeartGold.dsv")) == "Mac DS progress")
        try write(phone, "nds/HeartGold/HeartGold.dsv", "phone DS progress", newer)
        _ = try sync.sync(local: phone, cloud: cloud)
        _ = try sync.sync(local: mac, cloud: cloud, macBatteryNames: true)
        check((try read(mac, "nds/battery/HeartGold.dsv")) == "phone DS progress")
        // A deliberate one-title restore also works when the first sync has
        // no local baseline and the phone's obsolete slot has a newer date.
        let stalePhone = base.appendingPathComponent("oldPhone/save")
        try write(stalePhone, coherent + "save/obsolete", "obsolete slot", newer.addingTimeInterval(500))
        let manual = try sync.sync(local: stalePhone, cloud: cloud, switchTransfer: .init(title: "01000000000000AA", upload: false))
        check(manual.downloaded > 0 && manual.uploaded == 0)
        check((try read(stalePhone, coherent + "save/progress")) == "mac continuation")
        check(!fm.fileExists(atPath: stalePhone.appendingPathComponent("nds").path))
        check(!fm.fileExists(atPath: stalePhone.appendingPathComponent(coherent + "save/obsolete").path))
        // Incomplete iCloud delivery must not become a playable local save.
        try write(cloud, coherent + "save/progress", "partial upload", newer.addingTimeInterval(200))
        do { _ = try sync.sync(local: mac, cloud: cloud); preconditionFailure("Partial Switch snapshot must be rejected") } catch {}
        check((try read(mac, coherent + "save/progress")) == "mac continuation")
        try write(cloud, coherent + "save/progress", "mac continuation", old)
        let link = phone.appendingPathComponent("unsafe")
        try fm.createSymbolicLink(at: link, withDestinationURL: base)
        do { _ = try sync.sync(local: phone, cloud: cloud); preconditionFailure("Symlinks must be rejected") } catch {}
        print("PASS whole save tree + atomic Switch snapshots, incomplete-cloud rejection, wrapper repair, cache exclusion: newer upload/download, timestamp preservation, no ping-pong, backups, empty-library restore, battery name mapping, equal-date conflict, missing-file recovery, symlink rejection")
    }
}
