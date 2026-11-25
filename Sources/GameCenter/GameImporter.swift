import AppKit
import UniformTypeIdentifiers

enum GameImporter {
    @MainActor
    static func chooseArtwork() -> URL? {
        let panel = NSOpenPanel()
        panel.title = AppLanguage.localized("选择游戏封面")
        panel.message = AppLanguage.localized("选择一张图片作为游戏封面。")
        panel.prompt = AppLanguage.localized("选择封面")
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    static func title(for url: URL, platform: GamePlatform) -> String {
        if platform == .ps3 && url.lastPathComponent.uppercased() == "EBOOT.BIN" {
            return url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
        }
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        if isDir && url.pathExtension.lowercased() != "app" {
            return url.lastPathComponent
        }
        return url.deletingPathExtension().lastPathComponent
    }

    @MainActor
    static func chooseGameDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.title = AppLanguage.localized("选择游戏文件夹")
        panel.message = AppLanguage.localized("选择游戏库根目录，每个平台的游戏放在对应的子文件夹内。")
        panel.prompt = AppLanguage.localized("选择文件夹")
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
