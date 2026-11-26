import GameCenterSaveSupport
import AppKit
import Darwin
import Foundation

private struct StandaloneManifest: Decodable {
    let gameID: String
    let title: String
    let folderName: String
    let libraryID: String
    let assetVersion: String
}

private struct StandaloneSaveConnection {
    let external: URL
    let runtime: URL
    let sessionMarker: URL
}

@MainActor
private final class Launcher: NSObject, NSApplicationDelegate {
    private let fileManager = FileManager.default
    private var window: NSWindow?
    private var titleLabel: NSTextField?
    private var detailLabel: NSTextField?
    private var progressBar: NSProgressIndicator?
    private var runner: Process?
    private var showingFailure = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let resources = try requiredResource("S2ArmStandalone")
            let manifestURL = resources.appendingPathComponent("standalone.json")
            let manifest = try JSONDecoder().decode(StandaloneManifest.self, from: Data(contentsOf: manifestURL))
            let engine = resources.appendingPathComponent("Engine", isDirectory: true)
            let libraryPayload = resources.appendingPathComponent("Library", isDirectory: true)
            let switchDirectory = Bundle.main.bundleURL.deletingLastPathComponent()
            let cheatsDirectory = switchDirectory
                .appendingPathComponent("cheat", isDirectory: true)
                .appendingPathComponent(manifest.gameID.uppercased(), isDirectory: true)
                .appendingPathComponent("cheats", isDirectory: true)
            let support = supportDirectory(for: manifest.gameID)
            try migrateLegacySupportDirectory(for: manifest.gameID, switchDirectory: switchDirectory, destination: support)
            let library = support.appendingPathComponent("Library", isDirectory: true)
            let privateRoot = support.appendingPathComponent("Private", isDirectory: true)

            let bundledVersion = (try? String(contentsOf: libraryPayload.appendingPathComponent("standalone-version"), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? manifest.assetVersion
            let currentVersion = bundledVersion + "-embedded-image-v1"
            let installedVersion = (try? String(contentsOf: library.appendingPathComponent("standalone-version"), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let runtimeGame = library.appendingPathComponent("games", isDirectory: true)
                .appendingPathComponent(manifest.folderName, isDirectory: true)
            let runtimeLayoutIsCurrent = fileManager.fileExists(atPath: runtimeGame.appendingPathComponent("game.json").path)
                && !fileManager.fileExists(atPath: runtimeGame.appendingPathComponent("image").path)

            if installedVersion != currentVersion || !runtimeLayoutIsCurrent {
                showProgress(title: installedVersion == nil ? "正在准备独立游戏" : "正在更新游戏文件", detail: "正在准备日志、缓存和存档目录；游戏镜像直接从应用内读取。")
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    do {
                        var lastUpdate = DispatchTime.now().uptimeNanoseconds
                        try StandaloneInstaller.install(from: libraryPayload, to: library, manifest: manifest, version: currentVersion) { copied, total, path in
                            let now = DispatchTime.now().uptimeNanoseconds
                            if copied >= total || now &- lastUpdate >= 50_000_000 {
                                lastUpdate = now
                                DispatchQueue.main.async { [weak self] in self?.updateProgress(copied: copied, total: total, path: path) }
                            }
                        }
                        DispatchQueue.main.async { [weak self] in self?.launchGame(manifest: manifest, resources: resources, engine: engine, library: library, privateRoot: privateRoot, cheatsDirectory: cheatsDirectory, retryBusErrorOnce: true) }
                    } catch {
                        DispatchQueue.main.async { [weak self] in self?.showFailure(error.localizedDescription) }
                    }
                }
                return
            }

            launchGame(manifest: manifest, resources: resources, engine: engine, library: library, privateRoot: privateRoot, cheatsDirectory: cheatsDirectory, retryBusErrorOnce: true)
        } catch {
            showFailure(error.localizedDescription)
        }
    }

    private func launchGame(manifest: StandaloneManifest, resources: URL, engine: URL, library: URL, privateRoot: URL, cheatsDirectory: URL, retryBusErrorOnce: Bool) {
        do {
            try fileManager.createDirectory(at: privateRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fileManager.createDirectory(at: privateRoot.appendingPathComponent("requests", isDirectory: true), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fileManager.createDirectory(at: library.appendingPathComponent("temp", isDirectory: true).appendingPathComponent(manifest.gameID, isDirectory: true), withIntermediateDirectories: true)
            try fileManager.createDirectory(at: cheatsDirectory, withIntermediateDirectories: true)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: privateRoot.path)
            let saveConnection = try StandaloneInstaller.connectSaveDirectory(
                library: library,
                gameID: manifest.gameID,
                folderName: manifest.folderName,
                switchDirectory: Bundle.main.bundleURL.deletingLastPathComponent()
            )

            let taskID = UUID().uuidString.lowercased()
            let requestURL = privateRoot.appendingPathComponent("requests", isDirectory: true).appendingPathComponent(taskID + ".json")
            let markerData = try Data(contentsOf: library.appendingPathComponent(".s2arm-location.json"))
            let marker = try JSONSerialization.jsonObject(with: markerData) as? [String: Any] ?? [:]
            let request: [String: Any] = [
                "schema": 1,
                "taskId": taskID,
                "operation": "launch",
                "privateRoot": privateRoot.path,
                "resources": engine.path,
                "engineDir": engine.appendingPathComponent("Engine").path,
                // `engine` is the packaged S2Arm root (Jobs/, Runtime/, Engine/, …).
                // embedded.install expects the immutable engine snapshot itself, whose
                // engine.json and file manifest live in the nested Engine/ directory.
                "engineBundle": engine.appendingPathComponent("Engine").path,
                "library": library.path,
                "libraryId": marker["id"] as? String ?? manifest.libraryID,
                "developerDir": "",
                "fontsDir": engine.appendingPathComponent("Fonts").path,
                "gameId": manifest.gameID,
                "preferPinnedHost": true,
                "standaloneImagePath": resources.appendingPathComponent("Library/games/\(manifest.folderName)/image/mac", isDirectory: true).path,
                "cheatMenuLibrary": resources.appendingPathComponent("S2ArmCheatMenu.dylib").path,
                "cheatsDirectory": cheatsDirectory.path,
                "uiLanguage": Locale.preferredLanguages.first?.hasPrefix("zh") == true ? "zh-Hans" : "en"
            ]
            try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys]).write(to: requestURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: requestURL.path)

            let runtime = engine.appendingPathComponent("Runtime", isDirectory: true)
            let python = runtime.appendingPathComponent("python/bin/python3.12")
            let jobs = engine.appendingPathComponent("Jobs/main.py")
            guard fileManager.isExecutableFile(atPath: python.path), fileManager.fileExists(atPath: jobs.path) else {
                throw LauncherError.invalidBundle("应用内的 S2Arm 运行环境不完整。")
            }

            let logURL = privateRoot.appendingPathComponent("logs", isDirectory: true).appendingPathComponent(taskID + "-launch.log")
            try fileManager.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            fileManager.createFile(atPath: logURL.path, contents: nil)
            let log = try FileHandle(forWritingTo: logURL)
            let process = Process()
            process.executableURL = python
            process.arguments = ["-B", "-I", jobs.path, "run", "--request", requestURL.path]
            process.currentDirectoryURL = library.appendingPathComponent("games", isDirectory: true).appendingPathComponent(manifest.folderName, isDirectory: true)
            var environment = ProcessInfo.processInfo.environment
            environment["DOTNET_ROOT"] = runtime.appendingPathComponent("dotnet").path
            environment["DOTNET_MULTILEVEL_LOOKUP"] = "0"
            environment["PYTHONUNBUFFERED"] = "1"
            environment["PYTHONDONTWRITEBYTECODE"] = "1"
            environment["PYTHONNOUSERSITE"] = "1"
            environment.removeValue(forKey: "PYTHONPATH")
            environment.removeValue(forKey: "PYTHONHOME")
            environment["PATH"] = [runtime.appendingPathComponent("python/bin").path, runtime.appendingPathComponent("bin").path, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].joined(separator: ":")
            process.environment = environment
            process.standardOutput = log
            process.standardError = log
            process.terminationHandler = { [weak self] process in
                let saveError: Error?
                do {
                    try StandaloneInstaller.disconnectSaveDirectory(saveConnection)
                    saveError = nil
                } catch {
                    saveError = error
                }
                try? log.synchronize()
                try? log.close()
                let logText = process.terminationStatus != 0 ? (try? String(contentsOf: logURL, encoding: .utf8)) : nil
                let shouldRetryBusError = retryBusErrorOnce
                    && process.terminationStatus != 0
                    && saveError == nil
                    && (logText?.contains(#""exitCode": 138"#) == true)
                Task { @MainActor in
                    self?.runner = nil
                    if let saveError {
                        self?.showFailure("游戏已退出，但存档写回 switch/save 失败：\(saveError.localizedDescription)\n\n库内临时存档仍保留，未删除。")
                    } else if shouldRetryBusError {
                        do {
                            try self?.disableUnstableFrameRate(library: library, folderName: manifest.folderName)
                            self?.showProgress(title: "正在兼容模式重启", detail: "检测到 60 帧补丁导致的内存执行异常，已关闭该补丁并自动重试。")
                            self?.launchGame(manifest: manifest, resources: resources, engine: engine, library: library, privateRoot: privateRoot, cheatsDirectory: cheatsDirectory, retryBusErrorOnce: false)
                        } catch {
                            self?.showFailure("游戏异常退出，并且无法保存兼容设置：\(error.localizedDescription)\n\n诊断日志：\n\(logURL.path)")
                        }
                    } else if process.terminationStatus == 0 {
                        NSApp.terminate(nil)
                    } else {
                        self?.showFailure(Self.failureMessage(from: logURL, logText: logText, processStatus: process.terminationStatus))
                    }
                }
            }
            runner = process
            try process.run()
            hideProgress()
            NSApp.setActivationPolicy(.prohibited)
        } catch {
            showFailure(error.localizedDescription)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { showingFailure }

    private func disableUnstableFrameRate(library: URL, folderName: String) throws {
        let launchURL = library.appendingPathComponent("games", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent("launch.json")
        var launch: [String: Any] = [:]
        if let data = try? Data(contentsOf: launchURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            launch = existing
        }
        launch["schema"] = 1
        var settings = launch["settings"] as? [String: Any] ?? [:]
        settings["fps60"] = false
        launch["settings"] = settings
        if launch["patches"] == nil { launch["patches"] = [String: Bool]() }
        try JSONSerialization.data(withJSONObject: launch, options: [.sortedKeys])
            .write(to: launchURL, options: .atomic)
    }

    private static func failureMessage(from logURL: URL, logText: String?, processStatus: Int32) -> String {
        if let text = logText ?? (try? String(contentsOf: logURL, encoding: .utf8)) {
            for line in text.split(whereSeparator: \.isNewline).reversed() {
                guard let data = String(line).data(using: .utf8),
                      let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      event["type"] as? String == "result",
                      let message = event["message"] as? String,
                      !message.isEmpty else { continue }
                return "\(message)\n\n诊断日志：\n\(logURL.path)"
            }
        }
        return "游戏启动失败（任务退出码 \(processStatus)）。\n\n诊断日志：\n\(logURL.path)"
    }


    private func showProgress(title: String, detail: String) {
        NSApp.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 170), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Game Center"
        window.center()
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = content

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        let progress = NSProgressIndicator()
        progress.style = .bar
        progress.minValue = 0
        progress.maxValue = 1
        progress.isIndeterminate = false
        for view in [titleLabel, detailLabel, progress] { view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view) }
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 26), titleLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -26), titleLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 28),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor), detailLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor), detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
            progress.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor), progress.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor), progress.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 20)
        ])
        self.titleLabel = titleLabel
        self.detailLabel = detailLabel
        self.progressBar = progress
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func updateProgress(copied: Int64, total: Int64, path: String) {
        progressBar?.doubleValue = Double(copied) / Double(total)
        detailLabel?.stringValue = "已准备 \(ByteCountFormatter.string(fromByteCount: copied, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file)) · \(path)"
    }

    private func hideProgress() {
        window?.orderOut(nil)
        window = nil
    }

    private func showFailure(_ message: String) {
        showingFailure = true
        if window == nil { showProgress(title: "无法启动游戏", detail: message) }
        window?.styleMask.insert(.closable)
        titleLabel?.stringValue = "无法启动游戏"
        detailLabel?.stringValue = message
        progressBar?.isHidden = true
    }

    private func requiredResource(_ name: String) throws -> URL {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent(name, isDirectory: true), fileManager.fileExists(atPath: url.path) else {
            throw LauncherError.invalidBundle("独立应用缺少运行资源：\(name)")
        }
        return url
    }

    private func supportDirectory(for gameID: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Game Center/SwitchEngines/S2ArmData", isDirectory: true)
            .appendingPathComponent("runtime", isDirectory: true)
            .appendingPathComponent(gameID.uppercased(), isDirectory: true)
    }

    private func migrateLegacySupportDirectory(for gameID: String, switchDirectory: URL, destination: URL) throws {
        guard !fileManager.fileExists(atPath: destination.path) else { return }
        let candidates = [
            switchDirectory.appendingPathComponent("runtime/S2Arm/\(gameID.uppercased())", isDirectory: true),
            switchDirectory.appendingPathComponent("build/S2Arm/runtime/\(gameID.uppercased())", isDirectory: true)
        ]
        guard let legacy = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }) else { return }
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.moveItem(at: legacy, to: destination)

        // Remove only empty containers below switch/runtime or switch/build.
        var candidate = legacy.deletingLastPathComponent()
        while candidate.path.hasPrefix(switchDirectory.path + "/"), candidate != switchDirectory {
            try? fileManager.removeItem(at: candidate.appendingPathComponent(".DS_Store"))
            guard (try? fileManager.contentsOfDirectory(atPath: candidate.path).isEmpty) == true else { break }
            try? fileManager.removeItem(at: candidate)
            candidate.deleteLastPathComponent()
        }
    }
}

private enum StandaloneInstaller {
    static func connectSaveDirectory(library: URL, gameID: String, folderName: String, switchDirectory: URL) throws -> StandaloneSaveConnection {
        let fm = FileManager.default
        let root = GameSaveLayout.root(besidePlatformDirectory: switchDirectory)
        let target = GameSaveLayout.folder(root: root, platform: "switch", game: gameID)
        try GameSaveLayout.migrate(switchDirectory.appendingPathComponent("save/" + gameID), to: target, saveRoot: root.appendingPathComponent("save"))
        let runtimeSave = library.appendingPathComponent("saves", isDirectory: true).appendingPathComponent(gameID, isDirectory: true)
        let gameSave = library.appendingPathComponent("games", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent("SaveData", isDirectory: true)
        let sessionMarker = gameSave.deletingLastPathComponent().appendingPathComponent(".gamecenter-save-session")
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: runtimeSave.deletingLastPathComponent(), withIntermediateDirectories: true)

        // S2Arm requires SaveData/ to live inside its managed library while running.
        // Keep save/switch/<id> as the durable source of truth, mirror it into the
        // managed library for the session, then atomically write it back on exit.
        let runtimeIsLink = (try? runtimeSave.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
        if runtimeIsLink {
            try fm.removeItem(at: runtimeSave)
        }
        try fm.createDirectory(at: runtimeSave, withIntermediateDirectories: true)

        let targetIsLink = (try? target.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
        if targetIsLink {
            let formerTarget = target.resolvingSymlinksInPath().standardizedFileURL
            try fm.removeItem(at: target)
            if fm.fileExists(atPath: formerTarget.path) {
                try replaceDirectory(at: target, withCopyOf: formerTarget)
            } else {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
            }
        } else if !fm.fileExists(atPath: target.path) {
            if fm.fileExists(atPath: gameSave.path) {
                try replaceDirectory(at: target, withCopyOf: gameSave)
            } else {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
            }
        }

        // A leftover runtime directory means the previous session did not reach its
        // normal disconnect path. Prefer that newer working copy before relaunching.
        if fm.fileExists(atPath: sessionMarker.path), fm.fileExists(atPath: gameSave.path), !targetIsLink {
            try replaceDirectory(at: target, withCopyOf: gameSave)
        }
        try replaceDirectory(at: gameSave, withCopyOf: target)
        try Data("active\n".utf8).write(to: sessionMarker, options: .atomic)
        return StandaloneSaveConnection(external: target, runtime: gameSave, sessionMarker: sessionMarker)
    }

    static func disconnectSaveDirectory(_ connection: StandaloneSaveConnection) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: connection.runtime.path) else { return }
        try replaceDirectory(at: connection.external, withCopyOf: connection.runtime)
        try fm.removeItem(at: connection.runtime)
        try? fm.removeItem(at: connection.sessionMarker)
    }

    private static func replaceDirectory(at destination: URL, withCopyOf source: URL) throws {
        let fm = FileManager.default
        let parent = destination.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let stage = parent.appendingPathComponent(".\(destination.lastPathComponent).stage-\(UUID().uuidString)", isDirectory: true)
        let backup = parent.appendingPathComponent(".\(destination.lastPathComponent).backup-\(UUID().uuidString)", isDirectory: true)
        try fm.copyItem(at: source, to: stage)
        let hadDestination = fm.fileExists(atPath: destination.path)
            || (try? destination.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
        if hadDestination { try fm.moveItem(at: destination, to: backup) }
        do {
            try fm.moveItem(at: stage, to: destination)
            if hadDestination { try? fm.removeItem(at: backup) }
        } catch {
            try? fm.removeItem(at: stage)
            if hadDestination, !fm.fileExists(atPath: destination.path) {
                try? fm.moveItem(at: backup, to: destination)
            }
            throw error
        }
    }

    static func install(from source: URL, to destination: URL, manifest: StandaloneManifest, version: String, progress: @escaping (Int64, Int64, String) -> Void) throws {
        let fm = FileManager.default
        let stage = destination.deletingLastPathComponent().appendingPathComponent(".install-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stage) }

        let gameDestination = stage.appendingPathComponent("games", isDirectory: true).appendingPathComponent(manifest.folderName, isDirectory: true)
        let imageRelativePath = "games/\(manifest.folderName)/image"
        try copyTree(from: source, to: stage, excluding: [imageRelativePath], progress: progress)

        let embeddedImage = source.appendingPathComponent(imageRelativePath, isDirectory: true).appendingPathComponent("mac", isDirectory: true)
        guard fm.fileExists(atPath: embeddedImage.appendingPathComponent("manifest.json").path) else {
            throw LauncherError.invalidBundle("应用内缺少 S2Arm 游戏镜像。")
        }

        let oldGame = destination.appendingPathComponent("games", isDirectory: true).appendingPathComponent(manifest.folderName, isDirectory: true)
        let newGame = gameDestination
        for name in ["saves", "save-backups", "SaveData", "shader-cache", "input.json", "custom.json"] {
            let old = oldGame.appendingPathComponent(name)
            let new = newGame.appendingPathComponent(name)
            guard fm.fileExists(atPath: old.path) else { continue }
            if fm.fileExists(atPath: new.path) { try? fm.removeItem(at: new) }
            try copyTree(from: old, to: new, excluding: [], progress: { _, _, _ in })
        }

        try Data((version + "\n").utf8).write(to: stage.appendingPathComponent("standalone-version"), options: .atomic)
        if fm.fileExists(atPath: destination.path) {
            let old = destination.deletingLastPathComponent().appendingPathComponent(".previous-\(UUID().uuidString)", isDirectory: true)
            try fm.moveItem(at: destination, to: old)
            do {
                try fm.moveItem(at: stage, to: destination)
                try? fm.removeItem(at: old)
            } catch {
                try? fm.moveItem(at: old, to: destination)
                throw error
            }
        } else {
            try fm.moveItem(at: stage, to: destination)
        }
    }

    private static func copyTree(from source: URL, to destination: URL, excluding: Set<String>, progress: (Int64, Int64, String) -> Void) throws {
        let fm = FileManager.default
        var entries: [(URL, URL, Bool, Bool, Int64)] = []
        guard let enumerator = fm.enumerator(at: source, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey], options: [], errorHandler: { _, _ in false }) else {
            throw LauncherError.invalidBundle("无法读取应用内游戏文件。")
        }
        let prefix = source.path.hasSuffix("/") ? source.path : source.path + "/"
        for case let item as URL in enumerator {
            guard item.path.hasPrefix(prefix) else { continue }
            let relative = String(item.path.dropFirst(prefix.count))
            if excluding.contains(relative) { enumerator.skipDescendants(); continue }
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
            let target = destination.appendingPathComponent(relative)
            let size = Int64(values.fileSize ?? 0)
            entries.append((item, target, values.isDirectory == true, values.isSymbolicLink == true, size))
        }
        let total = max(1, entries.reduce(Int64.zero) { $0 + ($1.2 ? 0 : $1.4) })
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        var copied: Int64 = 0
        for (sourceItem, target, isDirectory, isSymlink, size) in entries {
            if isDirectory {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
            } else {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if isSymlink {
                    try fm.createSymbolicLink(atPath: target.path, withDestinationPath: (try fm.destinationOfSymbolicLink(atPath: sourceItem.path)))
                } else if clonefile(sourceItem.path, target.path, 0) != 0 {
                    try fm.copyItem(at: sourceItem, to: target)
                }
                copied += size
            }
            progress(min(copied, total), total, sourceItem.lastPathComponent)
        }
    }


}

private enum LauncherError: LocalizedError {
    case invalidBundle(String)
    var errorDescription: String? {
        switch self {
        case .invalidBundle(let message): message
        }
    }
}

@main
private enum StandaloneLauncherMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = Launcher()
        app.delegate = delegate
        app.run()
    }
}
