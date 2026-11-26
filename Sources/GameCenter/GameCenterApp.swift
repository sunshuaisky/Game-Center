import AppKit
import SwiftUI

@main
enum GameCenterEntryPoint {
    @MainActor static func main() {
        let arguments = CommandLine.arguments
        guard arguments.dropFirst().first == "--build-ios" else {
            GameCenterApp.main()
            return
        }
        guard arguments.count == 3 || arguments.count == 4 else {
            fputs("用法：GameCenter --build-ios <输出目录> [Mac 游戏目录]\n", stderr)
            exit(64)
        }
        do {
            let output = URL(fileURLWithPath: arguments[2], isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let source = arguments.count == 4 ? URL(fileURLWithPath: arguments[3], isDirectory: true) : nil
            print(try MobileAppBuilder.build(to: output, libraryRoot: source, knownGames: GameLibrary.savedSwitchCatalog()).path)
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}

struct GameCenterApp: App {
    @StateObject private var library = GameLibrary()
    @AppStorage("appLanguage") private var languageRawValue = AppLanguage.system.rawValue

    init() {
        // SwiftPM's debug executable is not wrapped in an .app bundle, so opt in to
        // a regular foreground policy to make its SwiftUI window visible in dev runs.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    private var language: AppLanguage {
        AppLanguage(rawValue: languageRawValue) ?? .system
    }

    var body: some Scene {
        WindowGroup {
            GameLibraryView(
                library: library,
                language: language,
                onLanguageChange: { languageRawValue = $0.rawValue }
            )
            .preferredColorScheme(.dark)
            .environment(\.locale, language.locale)
            .frame(minWidth: 1000, minHeight: 650)
            .onAppear {
                NSApp.activate(ignoringOtherApps: true)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                EmbeddedPlayCoordinator.shared.closeActiveSessionAndWindow()
            }
            .task {
                await Task.detached(priority: .utility) { MobileSigning.refreshInstalledTarget() }.value
                await Task.detached(priority: .utility) { SystemFileRestorer.restoreIfNeeded() }.value
            }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
    }
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case chinese
    case english
    case japanese

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .system: "跟随系统"
        case .chinese: "中文"
        case .english: "英语"
        case .japanese: "日本語"
        }
    }

    var localeIdentifier: String {
        switch self {
        case .system:
            let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
            if preferred.hasPrefix("zh") { return "zh-Hans" }
            if preferred.hasPrefix("ja") { return "ja" }
            return "en"
        case .chinese: return "zh-Hans"
        case .english: return "en"
        case .japanese: return "ja"
        }
    }

    var locale: Locale { Locale(identifier: localeIdentifier) }

    var scrapeLanguage: String {
        switch localeIdentifier {
        case "zh-Hans": "zh"
        case "ja": "ja"
        default: "en"
        }
    }

    private static let bundleCacheLock = NSLock()
    private static var bundleCache: [String: Bundle] = [:]

    private static func bundle(for identifier: String) -> Bundle? {
        bundleCacheLock.lock()
        if let cached = bundleCache[identifier] {
            bundleCacheLock.unlock()
            return cached
        }
        bundleCacheLock.unlock()
        guard let url = Bundle.main.url(forResource: identifier, withExtension: "lproj"),
              let loaded = Bundle(url: url) else { return nil }
        bundleCacheLock.lock()
        bundleCache[identifier] = loaded
        bundleCacheLock.unlock()
        return loaded
    }

    static func localized(_ key: String) -> String {
        let selected = AppLanguage(
            rawValue: UserDefaults.standard.string(forKey: "appLanguage") ?? AppLanguage.system.rawValue
        ) ?? .system
        guard let bundle = bundle(for: selected.localeIdentifier) else { return key }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: localized(key), locale: localeFromDefaults, arguments: arguments)
    }

    private static var localeFromDefaults: Locale {
        let selected = AppLanguage(
            rawValue: UserDefaults.standard.string(forKey: "appLanguage") ?? AppLanguage.system.rawValue
        ) ?? .system
        return selected.locale
    }
}

