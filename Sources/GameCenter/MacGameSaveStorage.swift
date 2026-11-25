import AppKit
import Foundation
import GameController
#if canImport(GameCenterSaveSupport)
import GameCenterSaveSupport
#endif

/// Save routing for the exact bundled emulator frontends, before they open a ROM.
enum MacGameSaveStorage {
    static func preferChinese(emulator: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        if let identifier = Bundle(url: emulator)?.bundleIdentifier, !identifier.isEmpty {
            UserDefaults(suiteName: identifier)?.set(["zh-Hans", "zh-CN", "en"], forKey: "AppleLanguages")
        }
        let support = home.appendingPathComponent("Library/Application Support")
        let settings: (URL, String, String, String)?
        switch emulator.deletingPathExtension().lastPathComponent {
        case "PCSX2": settings = (support.appendingPathComponent("PCSX2/inis/PCSX2.ini"), "UI", "Language", "zh-CN")
        case "DuckStation": settings = (support.appendingPathComponent("DuckStation/settings.ini"), "Main", "Language", "zh-CN")
        case "Azahar": settings = (support.appendingPathComponent("Azahar/config/qt-config.ini"), "UI", "language", "zh_CN")
        case "PPSSPP": settings = (home.appendingPathComponent(".config/ppsspp/PSP/SYSTEM/ppsspp.ini"), "General", "Language", "zh_CN")
        case "mGBA": settings = (home.appendingPathComponent(".config/mgba/qt.ini"), "General", "language", "zh-CN")
        default: settings = nil
        }
        if let (file, section, key, value) = settings {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try setINI(at: file, section: section, key: key, value: value)
            if emulator.deletingPathExtension().lastPathComponent == "Azahar" {
                try setINI(at: file, section: section, key: "language\\default", value: "false")
            }
        }
        if emulator.deletingPathExtension().lastPathComponent == "RPCS3" {
            // Game Center ships pinned RPCS3 builds; a self-update inside the
            // bundle is reverted by the next app rebuild and would re-prompt
            // on every launch. RPCS3 reads this GUI setting from CurrentSettings.ini.
            let guiSettings = support.appendingPathComponent("rpcs3/CurrentSettings.ini")
            try FileManager.default.createDirectory(at: guiSettings.deletingLastPathComponent(), withIntermediateDirectories: true)
            try setINI(at: guiSettings, section: "Meta", key: "checkUpdateStart", value: "false")
        }
    }

    static func createLayout(root: URL) throws {
        try GameSaveLayout.evacuateSwitchCaches(saveRoot: root.appendingPathComponent("save"), cache: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("GameCenter/SaveRepair"))
        for platform in GamePlatform.allCases {
            try FileManager.default.createDirectory(at: GameSaveLayout.folder(root: root, platform: platform.id), withIntermediateDirectories: true)
        }
    }

    static func prepare(game: Game, rom: URL, root: URL, emulator: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> NSWorkspace.OpenConfiguration {
        try createLayout(root: root)
        let fm = FileManager.default
        let folder = GameSaveLayout.folder(root: root, platform: game.platform.id)
        let perGame = folder.appendingPathComponent(rom.deletingPathExtension().lastPathComponent)
        let support = home.appendingPathComponent("Library/Application Support")
        let saveRoot = root.appendingPathComponent("save")
        func route(_ old: URL, _ target: URL) throws {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try GameSaveLayout.migrate(old, to: target, saveRoot: saveRoot)
            if !fm.fileExists(atPath: target.path) { try fm.createDirectory(at: target, withIntermediateDirectories: true) }
            if !fm.fileExists(atPath: old.path) && (try? fm.destinationOfSymbolicLink(atPath: old.path)) == nil {
                try fm.createDirectory(at: old.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.createSymbolicLink(at: old, withDestinationURL: target)
            }
        }
        let config = NSWorkspace.OpenConfiguration()
        switch game.platform {
        case .gb, .gbc, .gba:
            try fm.createDirectory(at: perGame, withIntermediateDirectories: true)
            let battery = rom.deletingPathExtension().appendingPathExtension("sav")
            let stem = rom.deletingPathExtension().lastPathComponent
            let settings = [support.appendingPathComponent("visualboyadvance-m/vbam.ini"), home.appendingPathComponent(".config/visualboyadvance-m/vbam.ini")]
            func configuredDirectory(_ key: String) -> URL {
                guard let value = settings.lazy.compactMap({ iniValue(at: $0, section: "General", key: key) }).first, !value.isEmpty else { return rom.deletingLastPathComponent() }
                return value.hasPrefix("/") ? URL(fileURLWithPath: value) : rom.deletingLastPathComponent().appendingPathComponent(value)
            }
            for source in [battery, configuredDirectory("BatteryDir").appendingPathComponent(battery.lastPathComponent)] {
                try GameSaveLayout.migrate(source, to: perGame.appendingPathComponent(battery.lastPathComponent), saveRoot: saveRoot)
            }
            for source in Set([rom.deletingLastPathComponent(), configuredDirectory("StateDir")]) where source.standardizedFileURL != perGame.standardizedFileURL {
                for state in (try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)) ?? [] where state.pathExtension.lowercased() == "sgm" && state.lastPathComponent.hasPrefix(stem) {
                    let suffix = state.deletingPathExtension().lastPathComponent.dropFirst(stem.count)
                    guard suffix.isEmpty || suffix.allSatisfy(\.isNumber) else { continue }
                    try GameSaveLayout.migrate(state, to: perGame.appendingPathComponent(state.lastPathComponent), saveRoot: saveRoot)
                }
            }
            config.arguments = ["-C", "savegamePath=" + perGame.path, "-C", "savestatePath=" + perGame.path, rom.path]
            config.createsNewApplicationInstance = true
        case .nds:
            let sibling = rom.deletingPathExtension().appendingPathExtension("dsv")
            try GameSaveLayout.migrate(sibling, to: folder.appendingPathComponent("battery/" + sibling.lastPathComponent), saveRoot: saveRoot)
            let version = Bundle(url: emulator)?.infoDictionary?["CFBundleVersion"] as? String ?? "0.9.13"
            for (old, new) in [("Battery", "battery"), ("States", "states") ] {
                try route(support.appendingPathComponent("DeSmuME/\(version)/\(old)"), folder.appendingPathComponent(new))
            }
        case .threeDS:
            // Azahar prefers an existing XDG profile; otherwise its macOS profile.
            let xdg = URL(fileURLWithPath: ProcessInfo.processInfo.environment["XDG_DATA_HOME"] ?? home.appendingPathComponent(".local/share").path).appendingPathComponent("azahar")
            let profile = fm.fileExists(atPath: xdg.path) ? xdg : support.appendingPathComponent("Azahar")
            for name in ["sdmc", "nand", "states"] { try route(profile.appendingPathComponent(name), folder.appendingPathComponent(name)) }
        case .psp:
            let defaults = UserDefaults(suiteName: "org.ppsspp.ppsspp")!
            let old = URL(fileURLWithPath: defaults.string(forKey: "UserPreferredMemoryStickDirectoryPath") ?? home.appendingPathComponent(".config/ppsspp").path)
            for name in ["SAVEDATA", "PPSSPP_STATE"] { try route(old.appendingPathComponent("PSP/" + name), folder.appendingPathComponent(name)) }
            // Keep configuration/BIOS where PPSSPP expects them; only saves move.
        case .ps1:
            SystemFileRestorer.preparePS1BIOS(support: support)
            let profile = support.appendingPathComponent("DuckStation")
            let ini = profile.appendingPathComponent("settings.ini")
            for (section, key, fallback, name) in [("MemoryCards", "Directory", "memcards", "memcards"), ("Folders", "SaveStates", "savestates", "states")] {
                let value = iniValue(at: ini, section: section, key: key) ?? fallback
                let old = value.hasPrefix("/") ? URL(fileURLWithPath: value) : profile.appendingPathComponent(value)
                try route(old, folder.appendingPathComponent(name))
                try setINI(at: ini, section: section, key: key, value: folder.appendingPathComponent(name).path)
            }
        case .famicom, .superFamicom, .n64, .megaDrive:
            let system: String
            switch game.platform {
            case .famicom: system = "Famicom"
            case .superFamicom: system = "Super Famicom"
            case .n64: system = "Nintendo 64"
            default: system = "Mega Drive"
            }
            let gameSaves = folder.appendingPathComponent(system)
            try fm.createDirectory(at: gameSaves, withIntermediateDirectories: true)
            let stem = rom.deletingPathExtension().lastPathComponent
            for file in (try? fm.contentsOfDirectory(at: rom.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? [] {
                let suffix = String(file.lastPathComponent.dropFirst(stem.count))
                if file.lastPathComponent.hasPrefix(stem + "."), [".sav", ".srm", ".ram", ".rtc", ".eeprom", ".pak", ".bs0", ".bs1", ".bs2", ".bs3", ".bs4", ".bs5", ".bs6", ".bs7", ".bs8", ".bs9"].contains(suffix.lowercased()) {
                    try GameSaveLayout.migrate(file, to: gameSaves.appendingPathComponent(file.lastPathComponent), saveRoot: saveRoot)
                }
            }
            config.arguments = ["--setting", "Paths/Saves=" + folder.path + "/"]
            config.createsNewApplicationInstance = true
        case .ps2:
            SystemFileRestorer.preparePS2BIOS(support: support)
            // PCSX2 keeps every path in PCSX2.ini; relative entries resolve
            // against the PCSX2 folder itself. Point memory cards and
            // savestates at the library save folder after migrating existing data.
            let root = support.appendingPathComponent("PCSX2", isDirectory: true)
            let ini = root.appendingPathComponent("inis/PCSX2.ini")
            for (key, fallback, name) in [("MemoryCards", "memcards", "memcards"), ("Savestates", "sstates", "states")] {
                let value = iniValue(at: ini, section: "Folders", key: key) ?? fallback
                let old = value.hasPrefix("/") ? URL(fileURLWithPath: value) : root.appendingPathComponent(value)
                try route(old, folder.appendingPathComponent(name))
                try setINI(at: ini, section: "Folders", key: key, value: folder.appendingPathComponent(name).path)
            }
        case .ps3:
            // RPCS3 stores per-account saves and trophies inside its HDD image;
            // alias the account directories into the library save folder.
            let account = support.appendingPathComponent("rpcs3/dev_hdd0/home/00000001")
            for name in ["savedata", "trophy"] { try route(account.appendingPathComponent(name), folder.appendingPathComponent(name)) }
            // Auto-configure SDL gamepad for Player 1 on first launch if a controller is connected
            // and the user has not saved a custom RPCS3 input profile yet.
            ensureRPCS3GamepadConfigIfNeeded(support: support)
        case .psv:
            // Vita3K keeps savedata and trophies under ux0; alias them out.
            let account = support.appendingPathComponent("Vita3K/Vita3K/fs/ux0/user/00")
            for name in ["savedata", "trophy"] { try route(account.appendingPathComponent(name), folder.appendingPathComponent(name)) }
        case .wiiu:
            // Cemu stores saves and digital titles in its mlc01 NAND; point the
            // whole directory at the library save folder via settings.xml.
            let settings = support.appendingPathComponent("Cemu/settings.xml")
            let nand = folder.appendingPathComponent("mlc01")
            try route(support.appendingPathComponent("Cemu/mlc01"), nand)
            try setCemuMLCPath(at: settings, to: nand.path)
        case .wii:
            // Dolphin: memory cards, savestates and the Wii NAND move to the
            // library folder; config and caches stay in place.
            for (name, target) in [("GC", "GC"), ("StateSaves", "states"), ("Wii", "Wii")] {
                try route(support.appendingPathComponent("Dolphin/" + name), folder.appendingPathComponent(target))
            }
        default: break
        }
        return config
    }

    static func prepareSwitch(app: URL, root: URL, updateLauncher: Bool = true) throws -> NSWorkspace.OpenConfiguration {
        let fm = FileManager.default
        let resources = app.appendingPathComponent("Contents/Resources")
        let s2 = resources.appendingPathComponent("S2ArmStandalone/standalone.json")
        let isS2 = fm.fileExists(atPath: s2.path)
        let json = isS2 ? s2 : resources.appendingPathComponent("dm/launcher.json")
        let configuration = NSWorkspace.OpenConfiguration()
        guard let data = try? Data(contentsOf: json),
              let info = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = (info[isS2 ? "gameID" : "game"] as? String)?.uppercased(), MobileLibraryFormat.isTitleID(id) else { return configuration }
        let canonical = GameSaveLayout.folder(root: root, platform: "switch", game: id)
        let old = app.deletingLastPathComponent().appendingPathComponent("save/" + id)
        let wrapped = fm.fileExists(atPath: old.appendingPathComponent("save").path) || fm.fileExists(atPath: old.appendingPathComponent("save_device").path)
        try GameSaveLayout.migrate(old, to: wrapped ? canonical : canonical.appendingPathComponent("save"), saveRoot: root.appendingPathComponent("save"))
        try fm.createDirectory(at: canonical.appendingPathComponent("save"), withIntermediateDirectories: true)
        try fm.createDirectory(at: canonical.appendingPathComponent("save_device"), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: old.path) && (try? fm.destinationOfSymbolicLink(atPath: old.path)) == nil {
            try fm.createDirectory(at: old.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: old, withDestinationURL: isS2 ? canonical : canonical.appendingPathComponent("save"))
        }
        // Also adopt saves from games built outside Game Center before routing.
        if !isS2 {
            let legacy = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/nxnative/" + id)
            for name in ["save", "save_device"] { try GameSaveLayout.migrate(legacy.appendingPathComponent(name), to: canonical.appendingPathComponent(name), saveRoot: root.appendingPathComponent("save")) }
        }
        let cache = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("GameCenter/Switch/" + id)
        try GameSaveLayout.prepareSwitchFolder(canonical, cache: cache)
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        configuration.environment = ["DM_SAVE": canonical.appendingPathComponent("save").path, "DM_SAVE_SYNC": "0",
                                     "DM_PSO_USER": cache.appendingPathComponent("pso_user.tsv").path,
                                     "DM_PSO_ARCHIVE": cache.appendingPathComponent("pso_archive").path]
        if isS2 && updateLauncher, let launcher = Bundle.main.resourceURL?.appendingPathComponent("Tools/S2ArmStandaloneLauncher") {
            let target = app.appendingPathComponent("Contents/MacOS/S2ArmGameLauncher")
            let replacement = try Data(contentsOf: launcher)
            if try Data(contentsOf: target) != replacement {
                // Existing S2Arm apps need the new write-back path as well as new builds.
                let previous = try Data(contentsOf: target)
                do {
                    try replacement.write(to: target, options: .atomic)
                    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
                    try sign(app)
                } catch {
                    try previous.write(to: target, options: .atomic)
                    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
                    try? sign(app)
                    throw error
                }
            }
        }
        return configuration
    }
    private static func sign(_ app: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--sign", "-", app.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw GameSaveLayout.Failure("无法更新游戏的存档入口，请重新构建此 Mac 游戏。") }
    }

    /// Auto-configure RPCS3 Player 1 for SDL gamepads when a controller is connected
    /// and the user has not yet saved any custom global RPCS3 input profile.
    private static func ensureRPCS3GamepadConfigIfNeeded(support: URL) {
        guard GCController.controllers().contains(where: { $0.extendedGamepad != nil }) else { return }
        let fm = FileManager.default
        let inputRoot = support.appendingPathComponent("rpcs3/input_configs", isDirectory: true)
        let globalDir = inputRoot.appendingPathComponent("global", isDirectory: true)
        let defaultYml = globalDir.appendingPathComponent("Default.yml")
        guard !fm.fileExists(atPath: defaultYml.path) else { return }
        do {
            try fm.createDirectory(at: globalDir, withIntermediateDirectories: true)
            let yaml = """
            Player 1 Input:
              Handler: SDL
              Device: "SDL Gamepad 1"
            """
            try (yaml + "\n").write(to: defaultYml, atomically: true, encoding: .utf8)
            let activeFile = inputRoot.appendingPathComponent("active_input_configurations.yml")
            if !fm.fileExists(atPath: activeFile.path) {
                try "Active Configurations:\n  global: Default\n".write(to: activeFile, atomically: true, encoding: .utf8)
            }
        } catch {
            // Non-fatal: RPCS3 still launches with its built-in defaults.
        }
    }

    /// Point Cemu's emulated NAND (mlc01) at the library save folder.
    private static func setCemuMLCPath(at file: URL, to value: String) throws {
        var xml = (try? String(contentsOf: file, encoding: .utf8))
            ?? "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<content>\n</content>\n"
        let tag = "mlc_path"
        let escaped = value.replacingOccurrences(of: "&", with: "&amp;")
        if let range = xml.range(of: "<\(tag)>[^<]*</\(tag)>", options: .regularExpression) {
            xml.replaceSubrange(range, with: "<\(tag)>\(escaped)</\(tag)>")
        } else if let range = xml.range(of: "</content>") {
            xml.insert(contentsOf: "    <\(tag)>\(escaped)</\(tag)>\n", at: range.lowerBound)
        } else {
            throw GameSaveLayout.Failure("Cemu 配置里找不到 mlc_path 设置项。")
        }
        try xml.write(to: file, atomically: true, encoding: .utf8)
    }

    static func iniValue(at file: URL, section: String, key: String) -> String? {
        var current = ""
        for line in ((try? String(contentsOf: file, encoding: .utf8)) ?? "").components(separatedBy: .newlines) {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("["), text.hasSuffix("]") { current = String(text.dropFirst().dropLast()) }
            if current == section, let equal = text.firstIndex(of: "="), text[..<equal].trimmingCharacters(in: .whitespaces) == key {
                return text[text.index(after: equal)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
    static func setINI(at file: URL, section: String, key: String, value: String) throws {
        var lines = ((try? String(contentsOf: file, encoding: .utf8)) ?? "").components(separatedBy: .newlines)
        if let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "[\(section)]" }) {
            let end = lines[(start + 1)...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") }) ?? lines.endIndex
            if let index = lines[(start + 1)..<end].firstIndex(where: { $0.split(separator: "=", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces) == key }) { lines[index] = "\(key) = \(value)" }
            else { lines.insert("\(key) = \(value)", at: end) }
        } else { lines += ["[\(section)]", "\(key) = \(value)"] }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
    }
}
