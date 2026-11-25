#if canImport(GameCenterSaveSupport)
import GameCenterSaveSupport
#endif
import AppKit
import Foundation

enum GameLaunchError: LocalizedError {
    case bundledEmulatorMissing(String)
    case unsupportedPlatform(GamePlatform)

    var errorDescription: String? {
        switch self {
        case .bundledEmulatorMissing(let name):
            AppLanguage.format("找不到内置的 %@ 模拟器。请重新构建 Game Center。", name)
        case .unsupportedPlatform(let platform):
            AppLanguage.format("暂不支持启动%@游戏。", AppLanguage.localized(platform.shortTitle))
        }
    }
}

struct GameLaunchService {
    func launch(
        _ game: Game,
        libraryRoot: URL? = nil,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard game.platform.isEnabled else {
            completion(.failure(GameLaunchError.unsupportedPlatform(game.platform)))
            return
        }
        var accessedResource: URL?
        do {
            let gameURL = try game.resolvedURL()
            let hasAccess = gameURL.startAccessingSecurityScopedResource()
            if hasAccess { accessedResource = gameURL }

            switch game.platform {
            case .macOS:
                NSWorkspace.shared.openApplication(
                    at: gameURL,
                    configuration: NSWorkspace.OpenConfiguration()
                ) { _, error in
                    if hasAccess { gameURL.stopAccessingSecurityScopedResource() }
                    Self.finish(error: error, completion: completion)
                }
            case .switchConsole:
                guard gameURL.pathExtension.lowercased() == "app" else {
                    if hasAccess { gameURL.stopAccessingSecurityScopedResource() }
                    completion(.failure(GameLaunchError.unsupportedPlatform(.switchConsole)))
                    return
                }
                let root = GameSaveLayout.root(besidePlatformDirectory: libraryRoot ?? gameURL.deletingLastPathComponent())
                let configuration = try MacGameSaveStorage.prepareSwitch(app: gameURL, root: root)
                NSWorkspace.shared.openApplication(
                    at: gameURL,
                    configuration: configuration
                ) { runningApp, error in
                    if hasAccess { gameURL.stopAccessingSecurityScopedResource() }
                    if let runningApp, error == nil {
                        Task { @MainActor in
                            ExternalGameSessionMonitor.shared.track(runningApp: runningApp, game: game)
                        }
                    }
                    Self.finish(error: error, completion: completion)
                }
            default:
                let platform = game.platform
                let root = libraryRoot ?? gameURL.deletingLastPathComponent()
                if let descriptor = MacCoreCatalog.descriptor(for: platform) {
                    guard MacCoreCatalog.canRunEmbedded(platform: platform) else {
                        if hasAccess { gameURL.stopAccessingSecurityScopedResource() }
                        completion(.failure(GameLaunchError.bundledEmulatorMissing(descriptor.displayName)))
                        return
                    }
                    Task { @MainActor in
                        do {
                            try EmbeddedPlayCoordinator.shared.open(
                                game: game,
                                romURL: gameURL,
                                hasSecurityScope: hasAccess,
                                descriptor: descriptor,
                                libraryRoot: root
                            )
                            completion(.success(()))
                        } catch {
                            if hasAccess { gameURL.stopAccessingSecurityScopedResource() }
                            completion(.failure(error))
                        }
                    }
                    return
                }
                launchExternalEmulator(
                    game: game,
                    gameURL: gameURL,
                    hasAccess: hasAccess,
                    libraryRoot: libraryRoot,
                    completion: completion
                )
            }
        } catch {
            accessedResource?.stopAccessingSecurityScopedResource()
            completion(.failure(error))
        }
    }

    private func launchExternalEmulator(
        game: Game,
        libraryRoot: URL?,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        do {
            let gameURL = try game.resolvedURL()
            let hasAccess = gameURL.startAccessingSecurityScopedResource()
            launchExternalEmulator(
                game: game,
                gameURL: gameURL,
                hasAccess: hasAccess,
                libraryRoot: libraryRoot,
                completion: completion
            )
        } catch {
            completion(.failure(error))
        }
    }

    private func launchExternalEmulator(
        game: Game,
        gameURL: URL,
        hasAccess: Bool,
        libraryRoot: URL?,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let platform = game.platform
        do {
            let emulatorURL = try bundledEmulator(for: game.platform)
            let root = libraryRoot ?? gameURL.deletingLastPathComponent()
            let configuration = try MacGameSaveStorage.prepare(game: game, rom: gameURL, root: root, emulator: emulatorURL)
            let didOpen: (NSRunningApplication?, Error?) -> Void = { runningApp, error in
                if hasAccess { gameURL.stopAccessingSecurityScopedResource() }
                if let runningApp, error == nil {
                    Task { @MainActor in
                        ExternalGameSessionMonitor.shared.track(runningApp: runningApp, game: game)
                    }
                }
                Self.finish(error: error, completion: completion)
            }
            let directFullscreen = MacCoreCatalog.launchExternalFullscreen
            if let system = GamePlatform.macSystems[platform] {
                configuration.createsNewApplicationInstance = true
                switch platform {
                case .gamecube, .wii:
                    configuration.arguments = ["-b", "-e", gameURL.path]
                case .wiiu:
                    let tmd = gameURL.appendingPathComponent("title.tmd")
                    let code = gameURL.appendingPathComponent("code")
                    let rpx = ((try? FileManager.default.contentsOfDirectory(at: code, includingPropertiesForKeys: nil)) ?? [])
                        .sorted { $0.path < $1.path }.first { $0.pathExtension.lowercased() == "rpx" }
                    let entry = FileManager.default.fileExists(atPath: tmd.path) ? tmd : rpx ?? gameURL
                    configuration.arguments = directFullscreen ? ["-f", "-g", entry.path] : ["-g", entry.path]
                case .ps3:
                    configuration.arguments = ["--no-gui", gameURL.path]
                case .psv:
                    configuration.arguments = directFullscreen ? ["-F", gameURL.path] : [gameURL.path]
                case .xbox:
                    configuration.arguments = ["-dvd_path", gameURL.path]
                case .ps4:
                    configuration.arguments = ["-g", gameURL.appendingPathComponent("eboot.bin").path]
                default:
                    if system.emulator == "ares" {
                        let saves = GameSaveLayout.folder(root: root, platform: platform.id)
                        configuration.arguments = ["--system", system.title, "--setting", "Paths/Saves=" + saves.path + "/", gameURL.path]
                    } else {
                        configuration.arguments = [gameURL.path]
                    }
                }
            }
            if [.threeDS, .psp, .ps1].contains(platform) {
                configuration.arguments.append(gameURL.path)
            }
            if [.gb, .gbc, .gba, .threeDS, .psp, .ps1].contains(game.platform) || GamePlatform.macSystems[platform] != nil {
                NSWorkspace.shared.openApplication(at: emulatorURL, configuration: configuration, completionHandler: didOpen)
            } else {
                NSWorkspace.shared.open([gameURL], withApplicationAt: emulatorURL, configuration: configuration, completionHandler: didOpen)
            }
        } catch {
            if hasAccess { gameURL.stopAccessingSecurityScopedResource() }
            completion(.failure(error))
        }
    }

    func bundledEmulator(for platform: GamePlatform) throws -> URL {
        let appName: String
        switch platform {
        case .gba: appName = "mGBA.app"
        case .gb, .gbc: appName = "mGBA.app"
        case .nds: appName = "DeSmuME.app"
        case .threeDS: appName = "Azahar.app"
        case .psp: appName = "PPSSPP.app"
        case .famicom, .superFamicom, .n64, .megaDrive: appName = "ares.app"
        case .ps1: appName = "DuckStation.app"
        default:
            guard let system = GamePlatform.macSystems[platform] else { throw GameLaunchError.unsupportedPlatform(platform) }
            appName = system.emulator + ".app"
        }

        guard let url = Bundle.main.resourceURL?
            .appendingPathComponent("Emulators", isDirectory: true)
            .appendingPathComponent(appName, isDirectory: true),
              FileManager.default.fileExists(atPath: url.path)
        else {
            throw GameLaunchError.bundledEmulatorMissing(appName)
        }
        try MacGameSaveStorage.preferChinese(emulator: url)
        return url
    }

    private static func finish(
        error: Error?,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        if let error {
            completion(.failure(error))
        } else {
            completion(.success(()))
        }
    }
}
