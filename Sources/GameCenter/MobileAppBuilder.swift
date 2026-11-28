import Foundation

struct MobileAppBuildProgress: Sendable {
    static let steps = ["整理游戏清单", "准备 Switch 运行环境", "编译 iOS 应用", "嵌入模拟器核心", "签名与验证", "打包 IPA"]
    var step = 1
    var detail = "正在扫描当前游戏目录"
    var log: String?
}

enum MobileAppBuilder {
    static func switchCatalog(_ games: [Game], resolve: (Game) -> URL?) -> [MobileLibraryFormat.SwitchEntry] {
        games.filter { $0.platform == .switchConsole }.map { game in
            let titleID = resolve(game).flatMap(GameDirectoryScanner.switchTitleID)
            return .init(id: game.id.uuidString, title: game.displayTitle, titleID: titleID)
        }
    }

    static func script(_ name: String) throws -> URL {
        let fm = FileManager.default
        let resources = [
            Bundle.main.resourceURL?.appendingPathComponent("MobileBuild"),
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        ].compactMap { $0 }
        guard let script = resources.map({ $0.appendingPathComponent("scripts/\(name)") }).first(where: { fm.fileExists(atPath: $0.path) }) else {
            throw SwitchBuildError.missingTool("缺少 Game Center iOS 构建资源。请重新构建 macOS 应用。")
        }
        return script
    }

    static func build(
        to directory: URL, libraryRoot: URL?, knownGames: [MobileLibraryFormat.SwitchEntry],
        progress: @escaping @Sendable (MobileAppBuildProgress) -> Void = { _ in }
    ) throws -> URL {
        progress(.init())
        let fm = FileManager.default
        let request = fm.temporaryDirectory.appendingPathComponent("gc-mobile-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: request, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: request) }
        var games = knownGames
        if let libraryRoot {
            for url in GameDirectoryScanner.scan(root: libraryRoot) where GamePlatform.detect(for: url, under: libraryRoot) == .switchConsole {
                let title = GameImporter.title(for: url, platform: .switchConsole)
                let titleID = GameDirectoryScanner.switchTitleID(url)
                guard !games.contains(where: { ($0.titleID != nil && $0.titleID == titleID)
                    || (($0.titleID == nil || titleID == nil) && $0.title.caseInsensitiveCompare(title) == .orderedSame) }) else { continue }
                games.append(.init(id: titleID ?? UUID().uuidString, title: title, titleID: titleID))
            }
        }
        let encoder = JSONEncoder()
        try encoder.encode(games.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending })
            .write(to: request.appendingPathComponent("catalog.json"), options: .atomic)
        try encoder.encode(IOSCoreCatalog.mobilePlatforms)
            .write(to: request.appendingPathComponent("platforms.json"), options: .atomic)
        progress(.init(detail: "已整理 \(games.count) 款 Switch 游戏，正在检查构建环境"))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        let simulator = ProcessInfo.processInfo.environment["GAME_CENTER_IOS_SDK"] == "iphonesimulator"
        let output = directory.appendingPathComponent(simulator ? "Game Center.app" : "Game Center.ipa")
        let account = simulator ? nil : try AppleAccountSigning.selected()
        var environment = account == nil ? try MobileSigning.environment() : ProcessInfo.processInfo.environment
        if account != nil {
            environment.removeValue(forKey: "GAME_CENTER_IOS_PROFILE")
            environment["GAME_CENTER_IOS_SIGN_IDENTITY"] = "-"
        }
        process.environment = environment
        let buildOutput = account == nil ? output : request.appendingPathComponent("Game Center.ipa")
        process.arguments = [try script("build-ios-app.sh").path, request.path, buildOutput.path]
        let log = Pipe()
        process.standardOutput = log
        process.standardError = log
        try process.run()
        var pending = Data()
        var lines: [String] = []
        var current = MobileAppBuildProgress()
        func receive(_ line: String) {
            guard !line.isEmpty else { return }
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            if fields.count == 3, fields[0] == "GC_MOBILE_STAGE", let step = Int(fields[1]),
               (2...6).contains(step), step >= current.step {
                lines.removeAll()
                current = .init(step: step, detail: String(fields[2]))
            } else if line.hasPrefix("GC_MOBILE_DETAIL\t") {
                current.detail = String(line.dropFirst("GC_MOBILE_DETAIL\t".count))
                current.log = nil
            } else {
                lines.append(line)
                lines = Array(lines.suffix(80))
                current.log = line
            }
            progress(current)
        }
        while true {
            let data = log.fileHandleForReading.availableData
            guard !data.isEmpty else { break }
            pending.append(data)
            while let newline = pending.firstIndex(of: 10) {
                receive(String(decoding: pending.prefix(upTo: newline), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines))
                pending.removeSubrange(...newline)
            }
        }
        if !pending.isEmpty { receive(String(decoding: pending, as: UTF8.self)) }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = lines.suffix(15).joined(separator: "\n")
            throw SwitchBuildError.commandFailed(detail)
        }
        if let account {
            progress(.init(step: 6, detail: "正在使用 Apple ID 签署并验证 IPA"))
            let stage = directory.appendingPathComponent(".gc-sign-" + UUID().uuidString + ".ipa")
            defer { try? fm.removeItem(at: stage) }
            _ = try AppleAccountSigning.helper(["ipa", account.team, buildOutput.path, stage.path, try AppleAccountSigning.appBundleID(account)])
            if fm.fileExists(atPath: output.path) { _ = try fm.replaceItemAt(output, withItemAt: stage) }
            else { try fm.moveItem(at: stage, to: output) }
        }
        return output
    }
}
