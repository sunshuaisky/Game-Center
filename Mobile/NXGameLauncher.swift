#if canImport(GameCenterSaveSupport)
import GameCenterSaveSupport
#endif
import Foundation

enum NXGameLauncher {
    private struct Manifest: Decodable {
        let schema: Int
        let titleID: String
        let loader: String
        let frameworkExecutable: String
        let imageMarker: String
        let profile: String
        let shaderMap: String
        let modules: [String]
        enum CodingKeys: String, CodingKey {
            case schema, loader, profile, modules
            case titleID = "title_id"
            case frameworkExecutable = "framework_executable"
            case imageMarker = "image_marker"
            case shaderMap = "shader_map"
        }
    }

    static func validate(at framework: URL, titleID: String) throws {
        _ = try loadManifest(at: framework, titleID: titleID)
    }

    private static func loadManifest(at framework: URL, titleID: String) throws -> Manifest {
        let manifest = try MobileLibraryFormat.read(Manifest.self, at: framework.appendingPathComponent("game.manifest.json"))
        guard manifest.schema == 1, manifest.titleID.uppercased() == titleID,
              manifest.loader == "FH", !manifest.modules.isEmpty,
              [manifest.frameworkExecutable, manifest.profile, manifest.shaderMap].allSatisfy(isRelativePath),
              !manifest.frameworkExecutable.contains("/") else {
            throw Failure("nxnative 游戏清单与手机 Shell 不兼容")
        }
        let executable = framework.appendingPathComponent(manifest.frameworkExecutable)
        let values = try executable.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) > 0 else {
            throw Failure("nxnative Framework 缺少游戏程序")
        }
        return manifest
    }

    @MainActor static func launch(_ build: MobileLibraryFormat.SwitchBuild, library: PhoneLibrary) throws {
        guard gc_s2arm_active() == 0 else {
            throw Failure("切换游戏需要先关闭并重新打开 Game Center。")
        }
        let titleFolder = library.switchRoot.appendingPathComponent(build.titleID, isDirectory: true)
        let buildFolder = titleFolder.appendingPathComponent("Builds/NXNative", isDirectory: true)
        let framework = buildFolder.appendingPathComponent(build.executable, isDirectory: true)
        let manifest = try loadManifest(at: framework, titleID: build.titleID)
        let content = buildFolder.appendingPathComponent("Content", isDirectory: true)
        let user = titleFolder.appendingPathComponent("UserData/NXNative", isDirectory: true)
        let canonical = GameSaveLayout.folder(root: library.root, platform: "switch", game: build.titleID)
        let save = canonical.appendingPathComponent("save", isDirectory: true)
        try GameSaveLayout.migrate(user.appendingPathComponent("Saves"), to: save, saveRoot: library.root.appendingPathComponent("save"))
        try GameSaveLayout.migrate(user.appendingPathComponent("Saves_device"), to: canonical.appendingPathComponent("save_device"), saveRoot: library.root.appendingPathComponent("save"))
        let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let temp = caches.appendingPathComponent("Switch/\(build.titleID)/NXNative", isDirectory: true)
        for folder in [user, save, temp] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try GameSaveLayout.prepareSwitchFolder(canonical, cache: temp)
        var env = [
            "DM_PROFILE": framework.appendingPathComponent(manifest.profile).path,
            "DM_ROMFS": content.appendingPathComponent("romfs.img").path,
            "DM_SAVE": save.path,
            "DM_SAVE_SYNC": "0",
            "DM_PSO_USER": temp.appendingPathComponent("pso_user.tsv").path,
            "DM_PSO_ARCHIVE": temp.appendingPathComponent("pso_archive").path,
            "DM_TEMP": temp.path,
            "DM_NVN_SHMAP": framework.appendingPathComponent(manifest.shaderMap).path,
            "DM_LAUNCHER": "0",
            "DM_PROF_TEX_BC_CPU": "0"
        ]
        let environmentURL = framework.appendingPathComponent("dm/env.txt")
        if let settings = try? String(contentsOf: environmentURL, encoding: .utf8) {
            for line in settings.split(whereSeparator: \.isNewline) {
                let pair = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if pair.count == 2, pair[0] == "DM_PROF_TEX_BC_CPU", ["0", "1"].contains(pair[1]) {
                    env[pair[0]] = pair[1]
                }
            }
        }
        for (key, relative, base) in [
            ("DM_MSL_DIR", "msl", framework), ("DM_PSO_BUNDLE", "pso", framework),
            ("DM_AOC_DIR", "aoc", content), ("DM_FONT_DIR", "font", content)
        ] {
            let url = base.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: url.path) { env[key] = url.path }
        }
        let pairs = env.sorted { $0.key < $1.key }
        let argv = ["dmhost", framework.appendingPathComponent("dm").path] + manifest.modules
        let error = withCStrings(pairs.map(\.key)) { keys in
            withCStrings(pairs.map(\.value)) { values in
                withCStrings(argv) { arguments in
                    dm_shell_start_game(keys, values, Int32(pairs.count), arguments, Int32(argv.count),
                                        framework.appendingPathComponent(manifest.frameworkExecutable).path,
                                        manifest.imageMarker, user.appendingPathComponent("runtime.log").path,
                                        user.path, build.titleID)
                }
            }
        }
        if let error { throw Failure(String(cString: error)) }
        dm_shell_present_game()
    }

    private static func isRelativePath(_ path: String) -> Bool {
        !path.isEmpty && path.components(separatedBy: "/").allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func withCStrings<R>(_ values: [String], _ body: (UnsafePointer<UnsafePointer<CChar>?>) -> R) -> R {
        let strings = values.map { UnsafePointer(strdup($0)) } + [nil]
        defer { strings.forEach { free(UnsafeMutablePointer(mutating: $0)) } }
        return strings.withUnsafeBufferPointer { body($0.baseAddress!) }
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
