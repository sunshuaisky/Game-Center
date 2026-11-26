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

    /// Migrates any legacy Switch or GB/GBC/GBA battery saves into the unified `save/` tree before sync.
    static func prepareForSync(root: String?) throws {
        guard let root, !isPlaying(root: root) else { return }
        let directory = URL(fileURLWithPath: root)
        let fm = FileManager.default
        let switchRoot = directory.lastPathComponent.lowercased() == "switch" ? directory : directory.appendingPathComponent("switch")
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
            _ = try MacGameSaveStorage.prepareSwitch(
                app: app,
                root: GameSaveLayout.root(besidePlatformDirectory: switchRoot),
                updateLauncher: false
            )
        }
        // VBA-M's battery file is a raw SRAM/flash image, matching libretro.
        let saveRoot = directory.appendingPathComponent("save")
        let skippedFolders: Set<String> = ["switch", "build", "save", "saves", "ios", "bios"]
        let files = fm.enumerator(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants])
        while let rom = files?.nextObject() as? URL {
            if skippedFolders.contains(rom.lastPathComponent.lowercased()) {
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
            let old = rom.deletingPathExtension().appendingPathExtension("sav")
            let target = GameSaveLayout.folder(root: directory, platform: platform, game: rom.deletingPathExtension().lastPathComponent)
                .appendingPathComponent(old.lastPathComponent)
            try GameSaveLayout.migrate(old, to: target, saveRoot: saveRoot)
        }
    }
}
