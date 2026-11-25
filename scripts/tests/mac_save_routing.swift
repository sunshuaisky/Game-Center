import AppKit
import Foundation

enum GamePlatform: String, CaseIterable {
    case gb, gbc, gba, nds, threeDS, psp, famicom, superFamicom, n64, megaDrive, ps1, switchConsole, macOS
    var id: String { rawValue }
}
struct Game { let platform: GamePlatform }
enum MobileLibraryFormat { static func isTitleID(_ value: String) -> Bool { value.count == 16 } }

@main struct MacSaveRoutingTests {
    static func main() throws {
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: fixture) }
        let home = fixture.appendingPathComponent("Home")
        let root = fixture.appendingPathComponent("Game Library")
        let emulator = fixture.appendingPathComponent("Emulator.app")
        let support = home.appendingPathComponent("Library/Application Support")
        func put(_ text: String, _ file: URL) throws {
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
        }
        func check(_ value: Bool) { precondition(value) }
        let gb = root.appendingPathComponent("GB/Example.gb")
        try put("battery", gb.deletingPathExtension().appendingPathExtension("sav"))
        try put("quick state", gb.deletingLastPathComponent().appendingPathComponent("Example1.sgm"))
        let config = try MacGameSaveStorage.prepare(game: .init(platform: .gb), rom: gb, root: root, emulator: emulator, home: home)
        check(config.arguments.contains("savegamePath=" + root.appendingPathComponent("save/gb/Example").path))
        check(config.createsNewApplicationInstance)
        check((try String(contentsOf: root.appendingPathComponent("save/gb/Example/Example.sav"), encoding: .utf8)) == "battery")
        check((try String(contentsOf: root.appendingPathComponent("save/gb/Example/Example1.sgm"), encoding: .utf8)) == "quick state")
        let gba = root.appendingPathComponent("GBA/中文 Example.gba")
        let gbaSave = root.appendingPathComponent("save/gba/中文 Example")
        let gbaConfig = try MacGameSaveStorage.prepare(game: .init(platform: .gba), rom: gba, root: root, emulator: emulator, home: home)
        check(gbaConfig.createsNewApplicationInstance)
        check(gbaConfig.arguments == ["-C", "savegamePath=" + gbaSave.path, "-C", "savestatePath=" + gbaSave.path, gba.path])
        for (platform, old, new) in [(GamePlatform.nds, "DeSmuME/0.9.13/Battery/example.dsv", "nds/battery/example.dsv"),
                                     (.threeDS, "Azahar/sdmc/test/save", "3ds/sdmc/test/save"),
                                     (.ps1, "DuckStation/memcards/game.mcd", "ps1/memcards/game.mcd")] {
            try put("existing progress", support.appendingPathComponent(old))
            _ = try MacGameSaveStorage.prepare(game: .init(platform: platform), rom: root.appendingPathComponent("example.rom"), root: root, emulator: emulator, home: home)
            check((try String(contentsOf: root.appendingPathComponent("save/" + new), encoding: .utf8)) == "existing progress")
            check((try String(contentsOf: support.appendingPathComponent(old), encoding: .utf8)) == "existing progress")
        }
        let psConfig = try String(contentsOf: support.appendingPathComponent("DuckStation/settings.ini"), encoding: .utf8)
        check(psConfig.contains(root.appendingPathComponent("save/ps1/memcards").path))
        for platform in [GamePlatform.famicom, .superFamicom, .n64, .megaDrive] {
            let config = try MacGameSaveStorage.prepare(game: .init(platform: platform), rom: root.appendingPathComponent("example.rom"), root: root, emulator: emulator, home: home)
            check(config.arguments.contains("Paths/Saves=" + GameSaveLayout.folder(root: root, platform: platform.id).path + "/"))
        }
        let title = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16))
        let app = root.appendingPathComponent("switch/Example.app")
        try put("{\"game\":\"" + title + "\"}", app.appendingPathComponent("Contents/Resources/dm/launcher.json"))
        let canonical = GameSaveLayout.folder(root: root, platform: "switch", game: title)
        try put("pipeline cache", canonical.appendingPathComponent("pso_archive/archive"))
        try put("pipeline index", canonical.appendingPathComponent("pso_user.tsv"))
        try put("committed progress", canonical.appendingPathComponent("save/slot"))
        let nx = try MacGameSaveStorage.prepareSwitch(app: app, root: root)
        check(nx.environment["DM_SAVE"] == canonical.appendingPathComponent("save").path)
        let pipeline = URL(fileURLWithPath: nx.environment["DM_PSO_USER"]!)
        defer { try? fm.removeItem(at: pipeline.deletingLastPathComponent()) }
        check(!pipeline.path.hasPrefix(root.appendingPathComponent("save").path + "/"))
        check(nx.environment["DM_PSO_ARCHIVE"] == pipeline.deletingLastPathComponent().appendingPathComponent("pso_archive").path)
        check(!fm.fileExists(atPath: canonical.appendingPathComponent("pso_archive").path))
        check(!fm.fileExists(atPath: canonical.appendingPathComponent("pso_user.tsv").path))
        check((try String(contentsOf: canonical.appendingPathComponent("save/slot"), encoding: .utf8)) == "committed progress")
        print("PASS: real launch configuration with spaces, VBA battery migration, DeSmuME battery alias, Azahar SDMC alias, DuckStation config/cards, ares path override")
    }
}
