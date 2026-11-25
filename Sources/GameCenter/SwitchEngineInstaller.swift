import CryptoKit
import Foundation

struct SwitchEngineInstallInfo: Codable {
    let method: SwitchBuildMethod
    let version: String
    let digest: String
    let installedAt: Date
}

enum SwitchEngineInstaller {
    private struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let digest: String?
            let browserDownloadURL: URL
            enum CodingKeys: String, CodingKey {
                case name, digest
                case browserDownloadURL = "browser_download_url"
            }
        }
        let tagName: String
        let assets: [Asset]
        enum CodingKeys: String, CodingKey {
            case assets
            case tagName = "tag_name"
        }
    }

    private struct GitHubCommit: Decodable {
        struct Commit: Decodable { let message: String }
        let sha: String
        let commit: Commit
    }

    private static var installsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Game Center/SwitchEngines", isDirectory: true)
    }

    static func installInfo(for method: SwitchBuildMethod) -> SwitchEngineInstallInfo? {
        let root = installRoot(for: method)
        guard let data = try? Data(contentsOf: root.appendingPathComponent("game-center-engine.json")),
              let info = try? JSONDecoder().decode(SwitchEngineInstallInfo.self, from: data),
              info.method == method,
              isComplete(root, method: method) else { return nil }
        return info
    }

    static func installRoot(for method: SwitchBuildMethod) -> URL {
        installsDirectory.appendingPathComponent(method == .s2arm ? "S2Arm" : "nxnative", isDirectory: true)
    }

    static func ensureInstalled(
        _ method: SwitchBuildMethod,
        forceUpdate: Bool = false,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> URL {
        if !forceUpdate, let installedInfo = installInfo(for: method) {
            let bundledIsNewer = method == .s2arm
                && (bundledS2ArmEngine().map {
                    $0.version.compare(installedInfo.version, options: .numeric) == .orderedDescending
                } ?? false)
            if !bundledIsNewer {
                let installed = installRoot(for: method)
                if method == .s2arm { try applyS2ArmCheatsCompatibility(to: installed) }
                if method == .nxnative { try applyNXNativeDiskSpaceCompatibility(to: installed) }
                return installed
            }
        }

        // The app bundle carries a pinned S2Arm release so a fresh Mac can
        // install the engine without network access; explicit updates still
        // fall through to the latest GitHub release below.
        if method == .s2arm, !forceUpdate, let bundled = bundledS2ArmEngine() {
            let fileManager = FileManager.default
            try fileManager.createDirectory(at: installsDirectory, withIntermediateDirectories: true)
            let staging = installsDirectory.appendingPathComponent(".install-\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: staging) }
            progress("安装应用包内置的 S2Arm \(bundled.version)…")
            let payload = staging.appendingPathComponent("payload", isDirectory: true)
            try fileManager.createDirectory(at: payload, withIntermediateDirectories: true)
            try copyS2ArmResources(from: bundled.resources, into: payload)
            try applyS2ArmCheatsCompatibility(to: payload)
            try finishInstall(of: payload,
                              info: .init(method: method, version: bundled.version, digest: "bundled", installedAt: .now),
                              progress: progress)
            return installRoot(for: method)
        }

        let version: String
        let archiveURL: URL
        let archiveName: String
        let expectedDigest: String?
        if method == .s2arm {
            let release = try await latestRelease()
            let assetName = "S2Arm-mac-arm64.dmg"
            guard let asset = release.assets.first(where: { $0.name == assetName }) else {
                throw SwitchBuildError.missingTool("S2Arm 最新发布版没有 macOS Apple Silicon 引擎包。")
            }
            guard let digest = asset.digest?.split(separator: ":").last.map(String.init), digest.count == 64 else {
                throw SwitchBuildError.missingTool("S2Arm 发布包没有 SHA-256 校验值，已停止安装。")
            }
            version = release.tagName
            archiveURL = asset.browserDownloadURL
            archiveName = asset.name
            expectedDigest = digest
        } else {
            let commit = try await latestNXNativeCommit()
            version = String(commit.sha.prefix(12))
            archiveURL = URL(string: "https://api.github.com/repos/seedds/nxnative/zipball/\(commit.sha)")!
            archiveName = "nxnative-\(version).zip"
            expectedDigest = nil
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: installsDirectory, withIntermediateDirectories: true)
        let staging = installsDirectory.appendingPathComponent(".install-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        progress(method == .s2arm ? "下载 S2Arm \(version)…" : "下载 nxnative 官方源码 \(version)…")
        var request = URLRequest(url: archiveURL)
        request.setValue("GameCenter/1.0", forHTTPHeaderField: "User-Agent")
        let (downloadedURL, response) = try await URLSession.shared.download(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw SwitchBuildError.commandFailed("下载 \(method.title) 引擎失败，请检查网络后重试。")
        }
        let archive = staging.appendingPathComponent(archiveName)
        try fileManager.moveItem(at: downloadedURL, to: archive)
        progress("校验下载文件…")
        let actualDigest = try sha256(of: archive).lowercased()
        if let expectedDigest, actualDigest != expectedDigest.lowercased() {
            throw SwitchBuildError.commandFailed("引擎发布包的 SHA-256 校验失败，未安装文件。")
        }

        let payload = staging.appendingPathComponent("payload", isDirectory: true)
        try fileManager.createDirectory(at: payload, withIntermediateDirectories: true)
        if method == .s2arm {
            progress("解包 S2Arm 引擎…")
            try installS2Arm(from: archive, into: payload)
            try applyS2ArmCheatsCompatibility(to: payload)
        } else {
            progress("解包 nxnative 官方源码…")
            let extracted = staging.appendingPathComponent("source", isDirectory: true)
            try fileManager.createDirectory(at: extracted, withIntermediateDirectories: true)
            try runTool("/usr/bin/unzip", arguments: ["-q", archive.path, "-d", extracted.path])
            let sourceFolders = try fileManager.contentsOfDirectory(at: extracted, includingPropertiesForKeys: [.isDirectoryKey])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            guard let source = sourceFolders.first,
                  fileManager.fileExists(atPath: source.appendingPathComponent("scripts/build_ipa_from_nsp.py").path) else {
                throw SwitchBuildError.missingTool("nxnative 源码压缩包结构无效。")
            }
            try fileManager.moveItem(at: source, to: payload.appendingPathComponent("engine", isDirectory: true))
            try applyNXNativeDiskSpaceCompatibility(to: payload)
            // Preserve reusable local Python and tool binaries across source updates.
            let previous = installRoot(for: method)
            for name in ["python", "tools"] {
                let oldComponent = previous.appendingPathComponent(name, isDirectory: true)
                if fileManager.fileExists(atPath: oldComponent.path) {
                    try fileManager.copyItem(at: oldComponent, to: payload.appendingPathComponent(name, isDirectory: true))
                }
            }
        }

        let info = SwitchEngineInstallInfo(method: method, version: version, digest: actualDigest, installedAt: .now)
        try finishInstall(of: payload, info: info, progress: progress)
        return installRoot(for: method)
    }

    private static func finishInstall(
        of payload: URL,
        info: SwitchEngineInstallInfo,
        progress: @escaping @Sendable (String) -> Void
    ) throws {
        let fileManager = FileManager.default
        let infoData = try JSONEncoder().encode(info)
        try infoData.write(to: payload.appendingPathComponent("game-center-engine.json"), options: .atomic)
        guard isComplete(payload, method: info.method) else {
            throw SwitchBuildError.missingTool("\(info.method.title) 引擎资源不完整，未替换当前安装。")
        }

        let destination = installRoot(for: info.method)
        let backup = installsDirectory.appendingPathComponent(".previous-\(UUID().uuidString)", isDirectory: true)
        if fileManager.fileExists(atPath: destination.path) { try fileManager.moveItem(at: destination, to: backup) }
        do {
            try fileManager.moveItem(at: payload, to: destination)
            try? fileManager.removeItem(at: backup)
        } catch {
            if fileManager.fileExists(atPath: backup.path) { try? fileManager.moveItem(at: backup, to: destination) }
            throw error
        }
        progress("\(info.method.title) \(info.version) 已集成到 Game Center。")
    }

    private static func latestRelease() async throws -> GitHubRelease {
        let url = URL(string: "https://api.github.com/repos/jhaizhou-ops/S2Arm/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("GameCenter/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw SwitchBuildError.commandFailed("无法读取 S2Arm 的最新发布版本。")
        }
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    static func latestNXNativeVersion() async throws -> String {
        let commit = try await latestNXNativeCommit()
        return String(commit.sha.prefix(12))
    }

    static func latestVersion(for method: SwitchBuildMethod) async throws -> String {
        switch method {
        case .s2arm: return try await latestRelease().tagName
        case .nxnative: return try await latestNXNativeVersion()
        }
    }

    private static func latestNXNativeCommit() async throws -> GitHubCommit {
        let url = URL(string: "https://api.github.com/repos/seedds/nxnative/commits/main")!
        var request = URLRequest(url: url)
        request.setValue("GameCenter/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw SwitchBuildError.commandFailed("无法读取 nxnative main 的最新版本。")
        }
        return try JSONDecoder().decode(GitHubCommit.self, from: data)
    }

    private static func bundledS2ArmEngine() -> (resources: URL, version: String)? {
        guard let resources = Bundle.main.resourceURL?
            .appendingPathComponent("S2ArmEngine", isDirectory: true) else { return nil }
        let fileManager = FileManager.default
        for name in ["Engine", "Jobs", "Runtime", "Shell", "Fonts", "Licenses"] {
            guard fileManager.fileExists(atPath: resources.appendingPathComponent(name).path) else { return nil }
        }
        guard let version = try? String(contentsOf: resources.appendingPathComponent("engine-version.txt"), encoding: .utf8),
              !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return (resources, version.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func installS2Arm(from diskImage: URL, into destination: URL) throws {
        let output = try runTool("/usr/bin/hdiutil", arguments: ["attach", "-nobrowse", "-readonly", "-plist", diskImage.path])
        guard let plist = try PropertyListSerialization.propertyList(from: output, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              let mountPath = entities.compactMap({ $0["mount-point"] as? String }).first else {
            throw SwitchBuildError.commandFailed("无法挂载 S2Arm 发布映像。")
        }
        let mount = URL(fileURLWithPath: mountPath, isDirectory: true)
        defer { _ = try? runTool("/usr/bin/hdiutil", arguments: ["detach", mount.path]) }
        try copyS2ArmResources(from: mount.appendingPathComponent("S2Arm.app/Contents/Resources", isDirectory: true), into: destination)
    }

    private static func copyS2ArmResources(from resources: URL, into destination: URL) throws {
        let fileManager = FileManager.default
        for name in ["Engine", "Jobs", "Runtime", "Shell", "Fonts", "Licenses"] {
            let source = resources.appendingPathComponent(name, isDirectory: true)
            guard fileManager.fileExists(atPath: source.path) else {
                throw SwitchBuildError.missingTool("S2Arm 引擎缺少 \(name) 组件。")
            }
            try fileManager.copyItem(at: source, to: destination.appendingPathComponent(name, isDirectory: true))
        }
    }

    private static func applyS2ArmCheatsCompatibility(to root: URL) throws {
        // S2Arm's portable runtime used to strip Homebrew from PATH even though its
        // host build invokes CMake/Ninja for glslang. Keep bundled tools first, then
        // expose the standard Apple Silicon and Intel Homebrew locations.
        let coreURL = root.appendingPathComponent("Jobs/core.py")
        guard let originalCore = try? String(contentsOf: coreURL, encoding: .utf8) else {
            throw SwitchBuildError.missingTool("S2Arm 缺少运行环境配置，无法加载构建所需的 CMake/Ninja。")
        }
        var core = originalCore
        let corePathsAnchor = #"paths = [str(runtime / "python/bin"), str(runtime / "bin"), "/usr/bin", "/bin", "/usr/sbin", "/sbin"]"#
        let corePathsReplacement = #"paths = [str(runtime / "python/bin"), str(runtime / "bin"), "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]"#
        if !core.contains(#""/opt/homebrew/bin", "/usr/local/bin""#) {
            guard core.contains(corePathsAnchor) else {
                throw SwitchBuildError.missingTool("当前 S2Arm 运行环境的 PATH 配置有变化，无法启用已安装的 CMake/Ninja。请检查引擎更新。")
            }
            core = core.replacingOccurrences(of: corePathsAnchor, with: corePathsReplacement)
        }
        let cacheDefault = #"        cache = self.work_root / "cache""#
        let cacheChoice = #"        cache = Path(self.r["gameCenterCompilerCache"]) if self.r.get("gameCenterCompilerCache") else self.work_root / "cache""#
        if core.contains(cacheDefault) { core = core.replacingOccurrences(of: cacheDefault, with: cacheChoice) }
        if originalCore != core {
            try Data(core.utf8).write(to: coreURL, options: .atomic)
        }

        let loaderURL = root.appendingPathComponent("Engine/runtime/src/loader.c")
        guard var loader = try? String(contentsOf: loaderURL, encoding: .utf8) else {
            throw SwitchBuildError.missingTool("S2Arm 缺少 Mac 金手指接入所需的运行时源码。请更新 S2Arm 引擎后重试。")
        }
        let originalLoaderLine = #"const char *s2a_cheats_dir(void) { static char d[1024]; if (!atomic_load(&g_cheats_host)) return ""; s2a_docs_path(d, sizeof d, "cheats"); return d; }"#
        let patchedLoaderLine = #"const char *s2a_cheats_dir(void) { static char d[1024]; const char *external = getenv("S2A_CHEATS"); if (external && *external) return external; if (!atomic_load(&g_cheats_host)) return ""; s2a_docs_path(d, sizeof d, "cheats"); return d; }"#
        let hasNativeCheatDirectory = loader.contains(#"getenv("S2A_CHEATS_DIR")"#)
        if !hasNativeCheatDirectory, !loader.contains(#"getenv("S2A_CHEATS")"#) {
            guard loader.contains(originalLoaderLine) else {
                throw SwitchBuildError.missingTool("当前 S2Arm 版本的金手指目录入口有变化，Game Center 无法安全接入。请检查引擎更新。")
            }
            loader = loader.replacingOccurrences(of: originalLoaderLine, with: patchedLoaderLine)
            try Data(loader.utf8).write(to: loaderURL, options: .atomic)
        }

        let buildURL = root.appendingPathComponent("Jobs/build.py")
        guard let originalBuild = try? String(contentsOf: buildURL, encoding: .utf8) else {
            throw SwitchBuildError.missingTool("S2Arm 缺少 Mac 构建脚本，无法配置金手指目录。")
        }
        var build = originalBuild
        let anchor = #"               S2A_INPUT_GUIDE_PREFS=str(c.private / "input-guides" / (game["id"] + ".json")))"#
        let addition = anchor + #"""
    # Game Center stores Switch cheats beside the library and passes only this dedicated path into the Mac host.
    cheats_directory = c.r.get("cheatsDirectory")
    if cheats_directory:
        cheat_path = Path(cheats_directory).expanduser().resolve()
        cheat_path.mkdir(parents=True, exist_ok=True)
        env["S2A_CHEATS"] = str(cheat_path)
"""#
        if !hasNativeCheatDirectory, !build.contains(#"env["S2A_CHEATS"] = str(cheat_path)"#) {
            guard build.contains(anchor) else {
                throw SwitchBuildError.missingTool("当前 S2Arm 版本的 Mac 构建流程有变化，Game Center 无法传递金手指目录。请检查引擎更新。")
            }
            build = build.replacingOccurrences(of: anchor, with: addition)
        }

        let hostChoice = ##"        host, trial = host_update.choose(c, game["id"], runtime, manifest)   # 公共宿主：兼容就换上本版的（这局是试玩），否则用原来的"##
        let pinnedHostChoice = [
            #"        if c.r.get("preferPinnedHost") is True:"#,
            #"            host = layout.game_info(c, game["id"]).get("hostMac")"#,
            #"            if not host or not host_update.host_exe(c, host).is_file():"#,
            #"                raise Failure("独立游戏应用缺少随包 Mac 宿主，请重新构建。", code="runtime_invalid")"#,
            #"            trial = False"#,
            #"        else:"#,
            ##"            host, trial = host_update.choose(c, game["id"], runtime, manifest)   # 公共宿主：兼容就换上本版的（这局是试玩），否则用原来的"##
        ].joined(separator: "\n")
        if !build.contains("preferPinnedHost") {
            guard build.contains(hostChoice) else {
                throw SwitchBuildError.missingTool("当前 S2Arm 版本的 Mac 宿主选择流程有变化，Game Center 无法固定游戏宿主。请检查引擎更新。")
            }
            build = build.replacingOccurrences(of: hostChoice, with: pinnedHostChoice)
        }

        if !build.contains("standaloneImagePath") {
            let validationAnchor = #"    layout.require_in_location(c, root)"#
            let validationReplacement = [
                #"    standalone_image = c.r.get("standaloneImagePath")"#,
                #"    if standalone_image:"#,
                #"        expected = resolve_path(Path(standalone_image).expanduser())"#,
                #"        if root != expected:"#,
                #"            raise Failure("独立应用的运行镜像路径不匹配。", code="runtime_invalid")"#,
                #"    else:"#,
                #"        layout.require_in_location(c, root)"#
            ].joined(separator: "\n")
            let runtimeLine = #"        runtime = layout.image_mac(c, game["id"], create=False)"#
            // Keep each release's own refresh operations on ordinary library launches.
            let refreshBlock = #"(?m)^        from rewrite_refresh import (?:refresh_mac, )?kept_nros_mac[^\n]*\n(?:        refresh_mac\(c, game\["id"\], runtime\)[^\n]*\n)?        kept_nros_mac\(c, game\["id"\], runtime\)[^\n]*"#
            guard build.contains(validationAnchor), build.contains(runtimeLine),
                  let range = build.range(of: refreshBlock, options: .regularExpression) else {
                throw SwitchBuildError.missingTool("当前 S2Arm 版本的独立应用启动流程有变化，无法启用内置只读游戏镜像。请检查引擎更新。")
            }
            let guardedRefresh = build[range].components(separatedBy: "\n").map { "    " + $0 }.joined(separator: "\n")
            build.replaceSubrange(range, with: "        if not standalone_image:\n" + guardedRefresh)
            build = build.replacingOccurrences(of: validationAnchor, with: validationReplacement)
            build = build.replacingOccurrences(of: runtimeLine, with: [
                #"        standalone_image = c.r.get("standaloneImagePath")"#,
                #"        runtime = Path(standalone_image).expanduser().resolve() if standalone_image else layout.image_mac(c, game["id"], create=False)"#
            ].joined(separator: "\n"))
        }
        build = build.replacingOccurrences(of: "            if keep_runtime_nros(", with: "            if not standalone_image and keep_runtime_nros(")

        if !build.contains(#"c.r.get("cheatMenuLibrary")"#) {
            let menuLibraryAnchor = "    return env\n\n\ndef collect_pipeline_seed"
            let menuLibraryReplacement = [
                #"    cheat_menu_library = c.r.get("cheatMenuLibrary")"#,
                #"    if cheat_menu_library:"#,
                #"        menu_path = Path(cheat_menu_library).expanduser().resolve()"#,
                #"        if menu_path.is_file():"#,
                #"            existing = env.get("DYLD_INSERT_LIBRARIES", "")"#,
                #"            env["DYLD_INSERT_LIBRARIES"] = str(menu_path) + ((":" + existing) if existing else "")"#,
                "    return env",
                "",
                "",
                "def collect_pipeline_seed"
            ].joined(separator: "\n")
            guard build.contains(menuLibraryAnchor) else {
                throw SwitchBuildError.missingTool("当前 S2Arm 版本的宿主环境流程有变化，无法加载金手指菜单组件。请检查引擎更新。")
            }
            build = build.replacingOccurrences(of: menuLibraryAnchor, with: menuLibraryReplacement)
        }

        let bundledHostLine = #"    bundled = artifact(c, "S2ArmGame.app")"#
        let customHostLine = #"    bundled = None if c.r.get("cheatsDirectory") else artifact(c, "S2ArmGame.app")"#
        if hasNativeCheatDirectory, build.contains(customHostLine) {
            // Current S2Arm releases already ship a Mac host with native cheat support.
            // Reuse it: the portable runtime intentionally contains no .NET SDK and
            // therefore cannot rebuild the NativeAOT host on the user's machine.
            build = build.replacingOccurrences(of: customHostLine, with: bundledHostLine)
        } else if !hasNativeCheatDirectory, !build.contains(customHostLine) {
            guard build.contains(bundledHostLine) else {
                throw SwitchBuildError.missingTool("当前 S2Arm 版本的 Mac 宿主构建流程有变化，Game Center 无法编译金手指兼容宿主。请检查引擎更新。")
            }
            build = build.replacingOccurrences(of: bundledHostLine, with: customHostLine)
        }
        // A release host already contains the native cheat interface. The make
        // fallback belongs only to source builds and varies between releases.
        if hasNativeCheatDirectory, FileManager.default.isExecutableFile(atPath:
            root.appendingPathComponent("Engine/Binaries/S2ArmGame.app/Contents/MacOS/s2arm-host").path) {
            if build != originalBuild { try Data(build.utf8).write(to: buildURL, options: .atomic) }
            return
        }
        let hostCacheAnchor = #"    host_root = c.private / "tools/mac-host" / fingerprint"#
        let hostCacheReplacement = [
            "    # Frozen app bundles intentionally have no source-tree fingerprint; their engine id is the stable host cache key.",
            #"    host_fingerprint = fingerprint or read(c.engine / "engine.json", {}).get("id")"#,
            #"    if not host_fingerprint:"#,
            #"        raise Failure("S2Arm Mac 宿主缺少引擎版本标识。", code="runtime_invalid")"#,
            #"    host_root = c.private / "tools/mac-host" / host_fingerprint"#
        ].joined(separator: "\n")
        if !build.contains("host_fingerprint = fingerprint or read(") {
            guard build.contains(hostCacheAnchor) else {
                throw SwitchBuildError.missingTool("当前 S2Arm Mac 宿主缓存结构有变化，Game Center 无法生成稳定缓存键。请检查引擎更新。")
            }
            build = build.replacingOccurrences(of: hostCacheAnchor, with: hostCacheReplacement)
        }
        let makeArgsAnchor = [
            #"    args = ["make", "-C", c.engine, "host", "S2A_CS=1", "S2A_MAC_FRONTEND=1","#,
            #"            "BUILD=" + str(host_root / "build"), "DEVELOPER_DIR=" + env["DEVELOPER_DIR"]]"#
        ].joined(separator: "\n")
        let makeArgsReplacement = [
            "    def gamecenter_nospace(path):",
            "        return subprocess.run(",
            #"            ["bash", "-c", 'source "$1"; s2a_nospace "$2"', "s2a_nospace", "#,
            #"             str(c.engine / "tools/nospace.sh"), str(path)],"#,
            "            check=True, capture_output=True, text=True).stdout.strip()",
            "    engine_alias = gamecenter_nospace(c.engine)",
            #"    build_alias = gamecenter_nospace(host_root / "build")"#,
            "    cache_dir = env.get(\"S2A_CS_CACHE\")",
            "    if cache_dir:",
            "        env[\"S2A_CS_CACHE\"] = gamecenter_nospace(cache_dir)",
            "    if not engine_alias or not build_alias:",
            #"        raise Failure("无法为 S2Arm 宿主构建路径创建无空格别名。", code="runtime_invalid")"#,
            #"    args = ["make", "-C", engine_alias, "host", "S2A_CS=1", "S2A_MAC_FRONTEND=1", "#,
            #"            "BUILD=" + build_alias, "DEVELOPER_DIR=" + env["DEVELOPER_DIR"]]"#
        ].joined(separator: "\n")
        if !build.contains("def gamecenter_nospace(path):") {
            guard build.contains(makeArgsAnchor) else {
                throw SwitchBuildError.missingTool("当前 S2Arm Mac 宿主构建命令有变化，Game Center 无法处理带空格的构建路径。请检查引擎更新。")
            }
            build = build.replacingOccurrences(of: makeArgsAnchor, with: makeArgsReplacement)
        }
        // Static libraries are passed to clang by Makefiles. Their cache paths must also
        // use a no-space alias: quoting an environment value in the shell does not help
        // once Make expands it into a compiler command line (e.g. `Application Support`).
        let hostCacheAliasAnchor = #"        env["S2A_CS_CACHE"] = gamecenter_nospace(cache_dir)"#
        let hostCacheAliasReplacement = [
            #"        env["S2A_CS_CACHE"] = gamecenter_nospace(cache_dir)"#,
            "    for cache_key in (\"S2A_VPX_CACHE\", \"S2A_OPUS_CACHE\", \"S2A_DAV1D_CACHE\", \"S2A_GLSLANG_CACHE\"):",
            "        cache_path = env.get(cache_key)",
            "        if cache_path:",
            "            env[cache_key] = gamecenter_nospace(cache_path)"
        ].joined(separator: "\n")
        if !build.contains("for cache_key in (\"S2A_VPX_CACHE\"") {
            guard build.contains(hostCacheAliasAnchor) else {
                throw SwitchBuildError.missingTool("当前 S2Arm 宿主缓存路径处理流程有变化，Game Center 无法传递无空格静态库路径。请检查引擎更新。")
            }
            build = build.replacingOccurrences(of: hostCacheAliasAnchor, with: hostCacheAliasReplacement)
        }
        if !build.contains("build_dir.mkdir(parents=True, exist_ok=True)") {
            let buildAliasAnchor = #"    build_alias = gamecenter_nospace(host_root / "build")"#
            let buildAliasReplacement = [
                #"    build_dir = host_root / "build""#,
                #"    build_dir.mkdir(parents=True, exist_ok=True)"#,
                #"    build_alias = gamecenter_nospace(build_dir)"#
            ].joined(separator: "\n")
            guard build.contains(buildAliasAnchor) else {
                throw SwitchBuildError.missingTool("当前 S2Arm 宿主构建目录流程有变化，Game Center 无法预先创建无空格构建目录。请检查引擎更新。")
            }
            build = build.replacingOccurrences(of: buildAliasAnchor, with: buildAliasReplacement)
        }
        // Recursive Makefiles (notably graphics/metal) derive ROOT with abspath ../..;
        // when Make follows the app-support symlink that becomes a path containing spaces.
        // Pass the already-created no-space engine alias as a command-line variable so it
        // propagates through MAKEFLAGS to every nested make invocation.
        let makeRootAnchor = #""BUILD=" + build_alias, "DEVELOPER_DIR=" + env["DEVELOPER_DIR"]]"#
        let makeRootReplacement = #""BUILD=" + build_alias, "DEVELOPER_DIR=" + env["DEVELOPER_DIR"], "ROOT=" + engine_alias]"#
        if !build.contains(#""ROOT=" + engine_alias"#) {
            guard build.contains(makeRootAnchor) else {
                throw SwitchBuildError.missingTool("当前 S2Arm Mac 宿主构建命令有变化，Game Center 无法把无空格引擎路径传递到子构建。请检查引擎更新。")
            }
            build = build.replacingOccurrences(of: makeRootAnchor, with: makeRootReplacement)
        }
        if build != originalBuild { try Data(build.utf8).write(to: buildURL, options: .atomic) }

        // `make` starts from Engine/, so NuGet does not discover services/nuget.config on its own.
        // That config is required for the vendored Ryujinx.LibHac alpha package; without it restore
        // silently checks nuget.org only and reports NU1102 during NativeAOT host compilation.
        let nxaotURL = root.appendingPathComponent("Engine/services/nxaot.sh")
        guard var nxaot = try? String(contentsOf: nxaotURL, encoding: .utf8) else {
            throw SwitchBuildError.missingTool("S2Arm 缺少 NativeAOT 构建脚本，无法配置本地 LibHac 包源。")
        }
        let nxaotAnchor = #"-p:UseSharedCompilation=false"#
        let nxaotReplacement = nxaotAnchor + #" -p:RestoreConfigFile="$ROOT/services/nuget.config""#
        if !nxaot.contains("-p:RestoreConfigFile=") {
            guard nxaot.contains(nxaotAnchor) else {
                throw SwitchBuildError.missingTool("当前 S2Arm NativeAOT 构建命令有变化，无法启用本地 LibHac 包源。请检查引擎更新。")
            }
            nxaot = nxaot.replacingOccurrences(of: nxaotAnchor, with: nxaotReplacement)
            try Data(nxaot.utf8).write(to: nxaotURL, options: .atomic)
        }

        let sizeAbiURL = root.appendingPathComponent("Engine/runtime/tests/mk/nvn_size_abi.mk")
        // New release bundles omit this developer-only test makefile.
        // Apply the legacy ripgrep workaround only when that file ships with the engine.
        if FileManager.default.fileExists(atPath: sizeAbiURL.path) {
            var sizeAbi = try String(contentsOf: sizeAbiURL, encoding: .utf8)
            let rgSourcesAnchor = #"$(shell rg --files graphics/tools/direct/dsh translator/dmsh_xlate \"#
            let findSourcesReplacement = #"$(shell find graphics/tools/direct/dsh translator/dmsh_xlate \"#
            if !sizeAbi.contains("$(shell find graphics/tools/direct/dsh translator/dmsh_xlate") {
                guard sizeAbi.contains(rgSourcesAnchor) else {
                    throw SwitchBuildError.missingTool("当前 S2Arm NVN 测试源清单有变化，无法移除 ripgrep 依赖。请检查引擎更新。")
                }
                sizeAbi = sizeAbi.replacingOccurrences(of: rgSourcesAnchor, with: findSourcesReplacement)
                let extensionsAnchor = #"    -g '*.cs' -g '*.csproj' -g '*.glsl') graphics/widen/SpirvCbufUseText.cs \"#
                let findExtensionsReplacement = #"    \( -type d \( -name .git -o -name obj -o -name bin \) -prune \) -o \( -type f \( -name '*.cs' -o -name '*.csproj' -o -name '*.glsl' \) -print \) | sort) graphics/widen/SpirvCbufUseText.cs \"#
                guard sizeAbi.contains(extensionsAnchor) else {
                    throw SwitchBuildError.missingTool("当前 S2Arm NVN 测试源清单格式有变化，无法安全替换 ripgrep 过滤参数。请检查引擎更新。")
                }
                sizeAbi = sizeAbi.replacingOccurrences(of: extensionsAnchor, with: findExtensionsReplacement)
                try Data(sizeAbi.utf8).write(to: sizeAbiURL, options: .atomic)
            }
        }


        // S2Arm's runtime already executes Atmosphere cheats, but its macOS host does not expose the
        // in-game menu present on nxnative. Add a native menu to the game host and persist toggles
        // to the enabled.txt file watched by S2A.Services.Cheats.
        let macHostURL = root.appendingPathComponent("Engine/macos/front_mac.m")
        guard let originalMacHost = try? String(contentsOf: macHostURL, encoding: .utf8) else {
            throw SwitchBuildError.missingTool("S2Arm 缺少 Mac 宿主界面源码，无法添加游戏内金手指菜单。")
        }
        var macHost = originalMacHost
        let cheatsEnvironmentVariable = hasNativeCheatDirectory ? "S2A_CHEATS_DIR" : "S2A_CHEATS"
        let frontAnchor = "void s2a_front_run(void (*guest_main)(void)) {"
        let frontInsertion = #"""
// Game Center adds the same in-game Atmosphere cheat menu that nxnative exposes on macOS.
// The S2Arm service reloads enabled.txt itself, so menu changes take effect without restarting.
extern void s2a_cheats_host_enable(void);
extern const char *s2a_main_build_id(void);

@interface S2AGameCenterCheatsMenu : NSObject <NSMenuDelegate>
@property(nonatomic, copy) NSString *directory;
@property(nonatomic, strong) NSMutableSet<NSString *> *enabled;
@property(nonatomic, strong) NSArray<NSDictionary *> *entries;
@end

@implementation S2AGameCenterCheatsMenu
- (instancetype)init {
    if ((self = [super init])) {
        const char *path = getenv("\#(cheatsEnvironmentVariable)");
        self.directory = path && *path ? [NSString stringWithUTF8String:path] : @"";
        self.enabled = [NSMutableSet set];
        [self reloadEnabled];
    }
    return self;
}
- (NSURL *)enabledURL { return [NSURL fileURLWithPath:[self.directory stringByAppendingPathComponent:@"enabled.txt"]]; }
- (void)reloadEnabled {
    NSString *text = [NSString stringWithContentsOfURL:[self enabledURL] encoding:NSUTF8StringEncoding error:nil] ?: @"";
    self.enabled = [NSMutableSet setWithArray:[text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]];
    [self.enabled removeObject:@""];
}
- (NSString *)currentBuildPrefix {
    const char *build = s2a_main_build_id();
    NSString *value = build ? [NSString stringWithUTF8String:build] : @"";
    return value.length >= 16 ? [[value substringToIndex:16] uppercaseString] : @"";
}
- (NSArray<NSDictionary *> *)readEntries {
    if (self.directory.length == 0) return @[];
    NSString *build = [self currentBuildPrefix];
    if (build.length != 16) return @[];
    NSArray<NSString *> *files = [[NSFileManager.defaultManager contentsOfDirectoryAtPath:self.directory error:nil] sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
    NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
    NSRegularExpression *hex = [NSRegularExpression regularExpressionWithPattern:@"^[0-9A-Fa-f]{16}$" options:0 error:nil];
    for (NSString *file in files) {
        if (![file.pathExtension.lowercaseString isEqualToString:@"txt"] || [@[@"enabled.txt", @"status.txt"] containsObject:file.lowercaseString]) continue;
        NSString *stem = file.stringByDeletingPathExtension;
        if ([hex numberOfMatchesInString:stem options:0 range:NSMakeRange(0, stem.length)] == 0 || ![stem.uppercaseString isEqualToString:build]) continue;
        NSString *text = [NSString stringWithContentsOfFile:[self.directory stringByAppendingPathComponent:file] encoding:NSUTF8StringEncoding error:nil];
        for (NSString *raw in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
            NSString *line = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (line.length < 2 || ![line hasPrefix:@"["] || ![line hasSuffix:@"]"]) continue; // master-code sections are implicit in S2Arm
            NSString *name = [[line substringWithRange:NSMakeRange(1, line.length - 2)] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (name.length == 0) name = @"未命名";
            [items addObject:@{@"file": file, @"name": name, @"key": [NSString stringWithFormat:@"%@/%@", file, name]}];
        }
    }
    return items;
}
- (void)menuNeedsUpdate:(NSMenu *)menu {
    [menu removeAllItems];
    if (self.directory.length == 0) {
        NSMenuItem *missing = [menu addItemWithTitle:s2a_ui_zh() ? @"金手指目录不可用" : @"Cheats folder unavailable" action:nil keyEquivalent:@""];
        missing.enabled = NO;
        return;
    }
    self.entries = [self readEntries];
    [self reloadEnabled];
    if (self.entries.count == 0) {
        NSMenuItem *empty = [menu addItemWithTitle:s2a_ui_zh() ? @"没有当前版本的金手指" : @"No cheats for this build" action:nil keyEquivalent:@""];
        empty.enabled = NO;
    } else {
        for (NSDictionary *entry in self.entries) {
            NSMenuItem *item = [menu addItemWithTitle:entry[@"name"] action:@selector(toggleCheat:) keyEquivalent:@""];
            item.target = self;
            item.representedObject = entry;
            item.state = [self.enabled containsObject:entry[@"key"]] ? NSControlStateValueOn : NSControlStateValueOff;
        }
    }
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *open = [menu addItemWithTitle:s2a_ui_zh() ? @"打开金手指文件夹…" : @"Open Cheats Folder…" action:@selector(openCheatsFolder:) keyEquivalent:@""];
    open.target = self;
    NSMenuItem *reload = [menu addItemWithTitle:s2a_ui_zh() ? @"重新载入金手指" : @"Reload Cheats" action:@selector(reloadCheats:) keyEquivalent:@""];
    reload.target = self;
}
- (void)toggleCheat:(NSMenuItem *)item {
    NSString *key = item.representedObject[@"key"];
    if (item.state == NSControlStateValueOn) [self.enabled removeObject:key]; else [self.enabled addObject:key];
    NSString *body = [[self.enabled.allObjects sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@"\n"];
    NSError *error = nil;
    if (![([body stringByAppendingString:body.length ? @"\n" : @""]) writeToURL:[self enabledURL] atomically:YES encoding:NSUTF8StringEncoding error:&error]) {
        NSAlert *alert = [NSAlert new];
        alert.messageText = s2a_ui_zh() ? @"无法保存金手指设置" : @"Couldn’t Save Cheat Settings";
        alert.informativeText = error.localizedDescription ?: @"";
        [alert runModal];
        [self reloadEnabled];
    }
}
- (void)openCheatsFolder:(id)sender { (void)sender; if (self.directory.length) [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:self.directory isDirectory:YES]]; }
- (void)reloadCheats:(id)sender { (void)sender; [self reloadEnabled]; }
@end
static S2AGameCenterCheatsMenu *g_s2a_game_center_cheats;

"""# + frontAnchor
        if !macHost.contains("S2AGameCenterCheatsMenu") {
            guard macHost.contains(frontAnchor) else {
                throw SwitchBuildError.missingTool("当前 S2Arm Mac 宿主菜单结构有变化，Game Center 无法添加游戏内金手指选项。请检查引擎更新。")
            }
            macHost = macHost.replacingOccurrences(of: frontAnchor, with: frontInsertion)
        }
        let menuAnchor = #"""
        root.submenu = application;
        NSMenuItem *inputRoot
"""#
        let menuInsertion = #"""
        root.submenu = application;
        if (getenv("\#(cheatsEnvironmentVariable)") && *getenv("\#(cheatsEnvironmentVariable)")) {
            s2a_cheats_host_enable();
            g_s2a_game_center_cheats = [S2AGameCenterCheatsMenu new];
            NSMenuItem *cheatsRoot = [NSMenuItem new];
            NSMenu *cheatsMenu = [[NSMenu alloc] initWithTitle:s2a_ui_zh() ? @"金手指" : @"Cheats"];
            cheatsMenu.delegate = g_s2a_game_center_cheats;
            cheatsMenu.autoenablesItems = NO;
            [g_s2a_game_center_cheats menuNeedsUpdate:cheatsMenu];
            cheatsRoot.title = s2a_ui_zh() ? @"金手指" : @"Cheats";
            cheatsRoot.submenu = cheatsMenu;
            [menu addItem:cheatsRoot];
        }
        NSMenuItem *inputRoot
"""#
        if !macHost.contains(#"g_s2a_game_center_cheats = [S2AGameCenterCheatsMenu new]"#) {
            guard macHost.contains(menuAnchor) else {
                throw SwitchBuildError.missingTool("当前 S2Arm Mac 菜单结构有变化，Game Center 无法挂载游戏内金手指菜单。请检查引擎更新。")
            }
            macHost = macHost.replacingOccurrences(of: menuAnchor, with: menuInsertion)
        }
        if macHost != originalMacHost { try Data(macHost.utf8).write(to: macHostURL, options: .atomic) }

        let engineManifestURL = root.appendingPathComponent("Engine/engine.json")
        guard let engineData = try? Data(contentsOf: engineManifestURL),
              var engineManifest = try? JSONSerialization.jsonObject(with: engineData) as? [String: Any],
              var files = engineManifest["files"] as? [String: Any],
              let engineID = engineManifest["id"] as? String else {
            throw SwitchBuildError.missingTool("S2Arm 引擎清单无效，无法登记 Game Center 金手指兼容补丁。")
        }
        let loaderData = try Data(contentsOf: loaderURL)
        files["runtime/src/loader.c"] = [loaderData.count, SHA256.hash(data: loaderData).map { String(format: "%02x", $0) }.joined()]
        let nxaotData = try Data(contentsOf: nxaotURL)
        files["services/nxaot.sh"] = [nxaotData.count, SHA256.hash(data: nxaotData).map { String(format: "%02x", $0) }.joined()]
        if FileManager.default.fileExists(atPath: sizeAbiURL.path) {
            let sizeAbiData = try Data(contentsOf: sizeAbiURL)
            files["runtime/tests/mk/nvn_size_abi.mk"] = [sizeAbiData.count, SHA256.hash(data: sizeAbiData).map { String(format: "%02x", $0) }.joined()]
        }
        let macHostData = try Data(contentsOf: macHostURL)
        files["macos/front_mac.m"] = [macHostData.count, SHA256.hash(data: macHostData).map { String(format: "%02x", $0) }.joined()]
        engineManifest["files"] = files
        if engineManifest["gameCenterCheatsPatch"] as? String != "v8" {
            let patchIdentity = Data("\(engineID):GameCenter.SwitchCheats.v8".utf8)
            engineManifest["id"] = SHA256.hash(data: patchIdentity).map { String(format: "%02x", $0) }.joined()
            engineManifest["gameCenterCheatsPatch"] = "v8"
        }
        let updatedEngineData = try JSONSerialization.data(withJSONObject: engineManifest, options: [.sortedKeys])
        try updatedEngineData.write(to: engineManifestURL, options: .atomic)
    }

    private static func isComplete(_ root: URL, method: SwitchBuildMethod) -> Bool {
        let fm = FileManager.default
        switch method {
        case .s2arm:
            let runtimeReady = ["Runtime/bin/s2a-rewrite", "Runtime/bin/dotnet"]
                .contains { fm.isExecutableFile(atPath: root.appendingPathComponent($0).path) }
            let tools = ["Runtime/python/bin/python3.12", "Runtime/bin/zstd", "Runtime/bin/glslangValidator",
                         "Engine/Binaries/Reader/nx_unpack", "Engine/Binaries/Prepare/shbake/S2A.ShBake",
                         "Engine/Binaries/Prepare/romfs/romfs_index"]
            return runtimeReady && tools.allSatisfy { fm.isExecutableFile(atPath: root.appendingPathComponent($0).path) }
                && ["Jobs/program_pack.py", "Fonts/nintendo_udsg-r_std_003.bfttf", "Shell/manifest.json", "Engine/engine.json", "Jobs/main.py", "Runtime/python/bin/python3.12", "Shell"]
                .allSatisfy { fm.fileExists(atPath: root.appendingPathComponent($0).path) }
        case .nxnative:
            return ["engine/scripts/build_ipa_from_nsp.py", "engine/LICENSE"]
                .allSatisfy { fm.fileExists(atPath: root.appendingPathComponent($0).path) }
        }
    }

    private static func applyNXNativeDiskSpaceCompatibility(to root: URL) throws {
        let scriptURL = root.appendingPathComponent("engine/dm/gfx/tools/dmsh_build.py")
        guard var script = try? String(contentsOf: scriptURL, encoding: .utf8) else {
            throw SwitchBuildError.missingTool("nxnative 缺少着色器构建脚本，无法配置磁盘空间回退。")
        }
        guard !script.contains("Game Center: discard the incomplete image") else { return }
        let anchor = [
            "    except (OSError, ValueError) as e:",
            "        print(f'[RED] could not write {image}, the library stays the folder {d}: {e}', flush=True)",
            "        for n in STORE.names(prefix): STORE.to_file(n, os.path.join(d, n[len(prefix):]))"
        ].joined(separator: "\n")
        let replacement = [
            "    except (OSError, ValueError) as e:",
            "        print(f'[RED] could not write {image}, the library stays the folder {d}: {e}', flush=True)",
            "        # Game Center: discard the incomplete image before restoring staged files.",
            "        # Otherwise the .part consumes all remaining space and makes the documented folder fallback fail too.",
            "        try:",
            "            os.unlink(image + '.part')",
            "        except FileNotFoundError:",
            "            pass",
            "        for n in STORE.names(prefix): STORE.to_file(n, os.path.join(d, n[len(prefix):]))"
        ].joined(separator: "\n")
        guard script.contains(anchor) else {
            throw SwitchBuildError.missingTool("当前 nxnative 着色器发布流程有变化，无法启用低磁盘空间回退。请更新 Game Center。")
        }
        script = script.replacingOccurrences(of: anchor, with: replacement)
        try Data(script.utf8).write(to: scriptURL, options: .atomic)
    }

    private static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    private static func runTool(_ path: String, arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw SwitchBuildError.commandFailed(detail.isEmpty ? "引擎组件解包失败。" : detail)
        }
        return data
    }
}
