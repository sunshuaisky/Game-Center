#if canImport(GameCenterSaveSupport)
import GameCenterSaveSupport
#endif
import AppKit
import Foundation

enum MacSaveSync {
    static func isPlaying(root: String?) -> Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            guard app.bundleIdentifier != Bundle.main.bundleIdentifier else { return false }
            guard let path = app.bundleURL?.path else { return false }
            return path.contains("/Emulators/") || (root.map { path.hasPrefix($0 + "/") } ?? false)
        }
    }

    static func slots(root: String?) throws -> [CloudSaveSlot] {
        guard let root else { return [] }
        let directory = URL(fileURLWithPath: root)
        let fm = FileManager.default
        let switchRoot = directory.lastPathComponent.lowercased() == "switch" ? directory : directory.appendingPathComponent("switch")
        var slots: [CloudSaveSlot] = []
        let apps = (try? fm.contentsOfDirectory(at: switchRoot, includingPropertiesForKeys: nil)) ?? []
        for app in apps where app.pathExtension == "app" {
            let resources = app.appendingPathComponent("Contents/Resources")
            let s2arm = resources.appendingPathComponent("S2ArmStandalone/standalone.json")
            let nx = resources.appendingPathComponent("dm/launcher.json")
            let engine = fm.fileExists(atPath: s2arm.path) ? "S2Arm" : "NXNative"
            guard let data = try? Data(contentsOf: engine == "S2Arm" ? s2arm : nx),
                  let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = (info[engine == "S2Arm" ? "gameID" : "game"] as? String)?.uppercased(),
                  MobileLibraryFormat.isTitleID(id) else { continue }
            if !isPlaying(root: root) {
                _ = try MacGameSaveStorage.prepareSwitch(app: app, root: GameSaveLayout.root(besidePlatformDirectory: switchRoot), updateLauncher: false)
            }
            let canonical = GameSaveLayout.folder(root: GameSaveLayout.root(besidePlatformDirectory: switchRoot), platform: "switch", game: id)
            slots.append(.init(id: "switch/\(id)", title: app.deletingPathExtension().lastPathComponent,
                               location: canonical))
        }
        // VBA-M's battery file is a raw SRAM/flash image, matching libretro.
        let files = fm.enumerator(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants])
        while let rom = files?.nextObject() as? URL {
            if ["switch", "build", "save", "saves", "ios", "bios"].contains(rom.lastPathComponent.lowercased()) {
                files?.skipDescendants()
                continue
            }
            let platform: String
            switch rom.pathExtension.lowercased() {
            case "gb": platform = "gb"
            case "gbc": platform = "gbc"
            case "gba": platform = "gba"
            default: continue
            }
            if !isPlaying(root: root) {
                let old = rom.deletingPathExtension().appendingPathExtension("sav")
                let target = GameSaveLayout.folder(root: directory, platform: platform, game: rom.deletingPathExtension().lastPathComponent).appendingPathComponent(old.lastPathComponent)
                try GameSaveLayout.migrate(old, to: target, saveRoot: directory.appendingPathComponent("save"))
            }
            slots.append(.init(id: "rom/\(platform)/" + rom.deletingPathExtension().lastPathComponent.lowercased(),
                               title: rom.deletingPathExtension().lastPathComponent,
                               location: GameSaveLayout.folder(root: directory, platform: platform, game: rom.deletingPathExtension().lastPathComponent).appendingPathComponent(rom.deletingPathExtension().lastPathComponent + ".sav"), fileName: "battery.srm"))
        }
        var seen = Set<String>()
        return slots.filter { seen.insert($0.id).inserted }.sorted { $0.title < $1.title }
    }
}
