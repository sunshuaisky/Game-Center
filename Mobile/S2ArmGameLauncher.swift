#if canImport(GameCenterSaveSupport)
import GameCenterSaveSupport
#endif
import Foundation
import UIKit

@objc(S2ArmLibrary)
final class S2ArmGameLauncher: NSObject {
    private static var startupCatalogs: [String: Data] = [:]

    // Called by the framework before the official host starts. The aliases
    // preserve its on-device layout without duplicating or moving game data.
    @objc static func prepareRuntime() {
        let fm = FileManager.default
        let libraryRoot = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/GameLibrary")
        let root = libraryRoot.appendingPathComponent("switch")
        let legacyRoot = libraryRoot.appendingPathComponent("Switch")
        if fm.fileExists(atPath: legacyRoot.path), !fm.fileExists(atPath: root.path) {
            try? fm.moveItem(at: legacyRoot, to: root)
        }
        let titles = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for title in titles where MobileLibraryFormat.isTitleID(title.lastPathComponent) {
            let build = title.appendingPathComponent("Builds/S2Arm")
            guard FileManager.default.fileExists(atPath: build.appendingPathComponent("catalogue.json").path) else { continue }
            do {
                try validate(at: build, titleID: title.lastPathComponent)
                try preparePaths(titleID: title.lastPathComponent, build: build, title: title)
                startupCatalogs[title.lastPathComponent] = try Data(contentsOf: build.appendingPathComponent("catalogue.json"))
            } catch {
                NSLog("Game Center: S2Arm runtime paths: %@", error.localizedDescription)
            }
        }
        if ProcessInfo.processInfo.environment["GAME_CENTER_TEST_REOPEN"] == "1" {
            let home = URL(fileURLWithPath: NSHomeDirectory())
            let env = ProcessInfo.processInfo.environment
            if let package = env["GAME_CENTER_TEST_SECOND_PACKAGE"],
               let content = env["GAME_CENTER_TEST_SECOND_CONTENT"],
               let id = env["GAME_CENTER_TEST_SECOND_TITLE"], MobileLibraryFormat.isTitleID(id) {
                do {
                    let build = home.appendingPathComponent(package)
                    try validate(at: build, titleID: id)
                    try link(build.appendingPathComponent("Content"), to: home.appendingPathComponent(content))
                    try preparePaths(titleID: id, build: build, title: home.appendingPathComponent("Library/Caches/GameCenter/IntegrationTitles/" + id))
                    startupCatalogs[id] = try Data(contentsOf: build.appendingPathComponent("catalogue.json"))
                } catch { NSLog("GC_REPEAT second package failed: %@", error.localizedDescription) }
            }
            if let id = env["S2A_LIBRARY_AUTOPLAY"] { prepareIntegrationLaunch(id) }
        }
    }

    // Explicit development-only A/B/A integration fixture. Program files live
    // under Export; the resource image can remain at its existing on-device
    // location, so testing never copies or alters the user's multi-GB image.
    @objc static func prepareIntegrationLaunch(_ titleID: String) {
        guard ProcessInfo.processInfo.environment["GAME_CENTER_TEST_REOPEN"] == "1" else { return }
        do {
            let home = URL(fileURLWithPath: NSHomeDirectory())
            let root = home.appendingPathComponent("Documents/GameLibrary")
            let save = GameSaveLayout.folder(root: root, platform: "switch", game: titleID)
            try GameSaveLayout.prepareSwitchFolder(save, cache: home.appendingPathComponent("Library/Caches/GameCenter/Switch/" + titleID))
            setenv("S2A_SAVE_FOLDER", save.path, 1)
        } catch { NSLog("GC_REPEAT save setup failed: %@", error.localizedDescription) }
    }

    static func validate(at folder: URL, titleID: String) throws {
        let data = try Data(contentsOf: folder.appendingPathComponent("catalogue.json"))
        guard let catalog = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              catalog["schema"] as? Int == 1, catalog["title_id"] as? String == titleID,
              catalog["image"] as? String == "S2AImages-\(titleID).dylib",
              (catalog["host_abi"] as? Int).map({ $0 > 0 }) == true,
              let hash = catalog["image_sha256"] as? String, hash.count == 64,
              hash.allSatisfy({ $0.isASCII && $0.isHexDigit }),
              catalog["dir"] == nil || catalog["dir"] as? String == "",
              FileManager.default.fileExists(atPath: folder.appendingPathComponent("Games/\(titleID)/main.npdm").path) else {
            throw Failure("S2Arm 程序包缺少完整运行清单，请在 Mac 重新构建并导入游戏。")
        }
    }

    @MainActor static func launch(_ build: MobileLibraryFormat.SwitchBuild, library: PhoneLibrary) throws {
        guard gc_s2arm_available() != 0 else {
            throw Failure("当前 IPA 未包含 S2Arm 真机宿主，请重新生成并安装 IPA。模拟器无法运行 S2Arm 游戏。")
        }
        guard dm_shell_active_game_id() == nil else {
            throw Failure("请先退出正在运行的 nxnative 游戏。")
        }
        let title = library.switchRoot.appendingPathComponent(build.titleID)
        let folder = title.appendingPathComponent("Builds/S2Arm")
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("catalogue.json").path) else {
            throw Failure("这份游戏包由旧版 Game Center 导出，缺少 S2Arm 运行清单，请在 Mac 重新构建后导入。")
        }
        try validate(at: folder, titleID: build.titleID)
        try preparePaths(titleID: build.titleID, build: folder, title: title)
        let save = GameSaveLayout.folder(root: library.root, platform: "switch", game: build.titleID)
        try FileManager.default.createDirectory(at: save, withIntermediateDirectories: true)
        try GameSaveLayout.migrate(title.appendingPathComponent("UserData/S2Arm/SaveData"), to: save, saveRoot: library.root.appendingPathComponent("save"))
        try GameSaveLayout.prepareSwitchFolder(save, cache: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("GameCenter/Switch/" + build.titleID))
        setenv("S2A_SAVE_FOLDER", save.path, 1)
        guard startupCatalogs[build.titleID] == (try Data(contentsOf: folder.appendingPathComponent("catalogue.json"))) else {
            throw Failure("游戏已导入。S2Arm 需要在 App 启动时准备地址空间，请关闭并重新打开 Game Center 后运行。")
        }
        // A library launch reads the committed save, including a new cloud
        // download. Snapshot restore is an explicit, separate in-game action.
        unsetenv("S2A_SNAP_RESTORE")
        unsetenv("S2A_SNAP_SAVE_ROLLBACK")
        if let error = gc_s2arm_start_game(build.titleID) { throw Failure(String(cString: error)) }
    }

    private static func preparePaths(titleID: String, build: URL, title: URL) throws {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let runtime = home.appendingPathComponent("Library/Application Support/S2Arm/games/\(titleID)")
        let user = title.appendingPathComponent("UserData/S2Arm")
        let fm = FileManager.default
        try fm.createDirectory(at: runtime, withIntermediateDirectories: true)
        try fm.createDirectory(at: user, withIntermediateDirectories: true)
        try link(runtime.appendingPathComponent("program"), to: build)
        try link(runtime.appendingPathComponent("资源包"), to: build.appendingPathComponent("Content"))
        try link(home.appendingPathComponent("Documents/games/\(titleID)"), to: user)
        let root = home.appendingPathComponent("Documents/GameLibrary")
        let save = GameSaveLayout.folder(root: root, platform: "switch", game: titleID)
        try fm.createDirectory(at: save, withIntermediateDirectories: true)
        try GameSaveLayout.migrate(user.appendingPathComponent("SaveData"), to: save, saveRoot: root.appendingPathComponent("save"))
        try link(user.appendingPathComponent("SaveData"), to: save)
    }

    private static func link(_ alias: URL, to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: alias.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let old = try? fm.destinationOfSymbolicLink(atPath: alias.path) {
            if alias.resolvingSymlinksInPath().path == destination.resolvingSymlinksInPath().path, !old.hasPrefix("/") { return }
            try fm.removeItem(at: alias)
        } else if fm.fileExists(atPath: alias.path) {
            throw Failure("S2Arm 运行目录已存在且无法关联游戏：\(alias.lastPathComponent)")
        }
        try GameSaveLayout.createAlias(at: alias, to: destination)
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
