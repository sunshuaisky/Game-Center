#if canImport(GameCenterSaveSupport)
import GameCenterSaveSupport
#endif
import AppKit
import CryptoKit
import Darwin
import Foundation

enum SwitchBuildMethod: String, CaseIterable, Identifiable, Codable {
    case s2arm
    case nxnative

    var id: String { rawValue }

    var title: String {
        switch self {
        case .s2arm: "S2Arm"
        case .nxnative: "nxnative"
        }
    }
}

enum SwitchBuildTarget: String, CaseIterable, Identifiable, Codable {
    case macOS
    case iOS

    var id: String { rawValue }
    var title: String { rawValue }

    var description: String {
        switch self {
        case .macOS: "生成可直接双击运行的 Mac 应用"
        case .iOS: "生成导入手机 Game Center 的游戏包"
        }
    }
}

struct SwitchBuildProgress: Equatable {
    var stage = "准备构建"
    var detail = ""
    var fraction: Double?
    var log: [String] = []
    var phaseEvent: String?
    var plan: [SwitchBuildPhase] = []
    var milestone: String?
    var stepFraction: Double?
    var stageNumber: Int?
    var stageCount: Int?
    var stageSucceeded: Bool?
}

struct SwitchBuildDependency: Identifiable, Equatable {
    let id: String
    let detail: String
    let isReady: Bool
}

private final class SwitchBuildProgressGate: @unchecked Sendable {
    private let lock = NSLock()
    private var lastUpdate = Date.distantPast

    func shouldReport(final: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        guard final || now.timeIntervalSince(lastUpdate) >= 0.15 else { return false }
        lastUpdate = now
        return true
    }
}

enum SwitchBuildError: LocalizedError {
    case missingTool(String)
    case commandFailed(String)
    case missingGameID

    var errorDescription: String? {
        switch self {
        case .missingTool(let message), .commandFailed(let message): message
        case .missingGameID: "S2Arm 已导入游戏，但无法从游戏库中找到对应的游戏编号。"
        }
    }
}

enum SwitchBuildService {
    private static let processLock = NSLock()
    private static var activeProcess: Process?
    private static let nxNativePythonImportCheck = "import sys,platform,lz4.block,capstone,fontTools,zbic,nsz,numpy,PIL,texture2ddecoder,zstandard; assert platform.machine() == 'arm64' and sys.version_info >= (3,12) and capstone.cs_version()[0] == 5; exec('import compression.zstd' if sys.version_info >= (3,14) else 'import backports.zstd')"

    static func cancelCurrentProcess() {
        processLock.lock()
        let process = activeProcess
        processLock.unlock()
        if process?.isRunning == true { process?.interrupt() }
    }

    static func s2ArmDeviceChoices() async throws -> S2ArmDeviceChoices {
        let root = SwitchEngineInstaller.installRoot(for: .s2arm)
        let python = root.appendingPathComponent("Runtime/python/bin/python3.12")
        let jobs = root.appendingPathComponent("Jobs")
        guard FileManager.default.isExecutableFile(atPath: python.path),
              FileManager.default.fileExists(atPath: jobs.appendingPathComponent("target.py").path),
              let developer = developerDirectory() else {
            throw SwitchBuildError.missingTool("安装 S2Arm 内置引擎和 Xcode 后，可读取支持的 iPhone / iPad 机型。")
        }
        let script = """
        import sys, json
        sys.path.insert(0, sys.argv[1])
        import target
        print(json.dumps(dict(models=target.models(sys.argv[2]))))
        """
        let result = try await capture(python, arguments: ["-B", "-I", "-c", script, jobs.path, developer])
        guard result.status == 0, let last = result.output.split(whereSeparator: \.isNewline).last,
              let data = last.data(using: .utf8) else {
            throw SwitchBuildError.commandFailed("读取 S2Arm 机型列表失败。\(result.output)")
        }
        return try JSONDecoder().decode(S2ArmDeviceChoices.self, from: data)
    }

    static func detectBuildDependencies(for method: SwitchBuildMethod, target: SwitchBuildTarget = .macOS) async -> [SwitchBuildDependency] {
        let engineInfo = SwitchEngineInstaller.installInfo(for: method)
        var dependencies = [SwitchBuildDependency(
            id: "engine",
            detail: engineInfo.map { "已安装 · 版本 \($0.version)" } ?? "内置构建引擎尚未安装",
            isReady: engineInfo != nil
        )]

        if method == .s2arm {
            let root = SwitchEngineInstaller.installRoot(for: method)
            let python = root.appendingPathComponent("Runtime/python/bin/python3.12")
            let imports = try? await capture(python, arguments: ["-IB", "-c", "import capstone,lz4,numpy,zstandard"])
            let tools = ["spirv-as", "spirv-val", "timeout", "zstd", "glslangValidator"]
            let ready = imports?.status == 0 && tools.allSatisfy {
                FileManager.default.isExecutableFile(atPath: root.appendingPathComponent("Runtime/bin/" + $0).path)
            }
            dependencies.append(.init(id: "s2arm-runtime", detail: ready ? "已就绪 · 内置 Python、压缩和着色器工具" : "请安装或修复 S2Arm 内置运行环境", isReady: ready))
        }

        let developer = try? await capture(URL(fileURLWithPath: "/usr/bin/xcode-select"), arguments: ["-p"])
        let developerPath = developer?.output.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let developerRoot = URL(fileURLWithPath: developerPath)
        let xcodebuild = developerRoot.appendingPathComponent("usr/bin/xcodebuild")
        let setup = try? await capture(xcodebuild, arguments: ["-checkFirstLaunchStatus"])
        let make = try? await capture(URL(fileURLWithPath: "/usr/bin/xcrun"), arguments: ["--find", "make"])
        let xcodeReady = developer?.status == 0 && setup?.status == 0 && make?.status == 0 && !developerPath.contains("CommandLineTools")
        let xcodeDisplayName = URL(fileURLWithPath: developerPath).deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
        dependencies.append(.init(
            id: "xcode",
            detail: xcodeReady ? "已就绪 · \(xcodeDisplayName)" : "请安装并选择完整 Xcode，打开一次完成许可及组件设置",
            isReady: xcodeReady
        ))

        let xcrun = executable(named: "xcrun", in: nxNativeEnvironment(SwitchEngineInstaller.installRoot(for: method)))
        let metalSDK = target == .iOS ? "iphoneos" : "macosx"
        let metal: (status: Int32, output: String)? = if let xcrun {
            try? await capture(xcrun, arguments: ["-sdk", metalSDK, "metal", "--version"])
        } else { nil }
        let metalReady = metal?.status == 0 && metal?.output.contains("Apple metal version") == true
        dependencies.append(.init(
            id: "metal",
            detail: metalReady ? "已就绪 · Metal Toolchain" : "需要下载 Xcode Metal Toolchain",
            isReady: metalReady
        ))

        if target == .iOS {
            let iosSDK: (status: Int32, output: String)? = if let xcrun {
                try? await capture(xcrun, arguments: ["--sdk", "iphoneos", "--show-sdk-version"])
            } else { nil }
            dependencies.append(.init(
                id: "ios-sdk",
                detail: iosSDK?.status == 0 ? "已就绪 · iOS SDK \(iosSDK?.output.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")" : "需要通过 Xcode 下载 iOS SDK",
                isReady: iosSDK?.status == 0
            ))
            do {
                if UserDefaults.standard.bool(forKey: AppleAccountSigning.preference) {
                    _ = try AppleAccountSigning.helper(["check"])
                }
                _ = try AppleAccountSigning.gameEnvironment()
                dependencies.append(.init(id: "signing", detail: "手机授权证书与本机签名身份匹配", isReady: true))
            } catch {
                dependencies.append(.init(id: "signing", detail: error.localizedDescription, isReady: false))
            }
            if method == .s2arm {
                let root = SwitchEngineInstaller.installRoot(for: method)
                let checker = try? MobileAppBuilder.script("prepare-s2arm-exit-host.py")
                let check = if let checker {
                    try? await capture(URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-IB", checker.path, root.path, "--check"])
                } else { nil as (status: Int32, output: String)? }
                let ready = check?.status == 0
                dependencies.append(.init(id: "s2arm-ios-host", detail: ready ? "已就绪 · 宿主版本与引擎匹配" :
                    (check?.output.trimmingCharacters(in: .whitespacesAndNewlines) ?? "找不到随附的 iOS 宿主检查工具"), isReady: ready))
                return dependencies
            }
        } else if method == .s2arm {
            return dependencies
        }

        let root = SwitchEngineInstaller.installRoot(for: .nxnative)
        let environment = nxNativeEnvironment(root)
        var sourceRoot = root.appendingPathComponent("engine")
        if target == .iOS {
            if let helper = try? MobileAppBuilder.script("prepare-nx-shell.sh"),
               let result = try? await capture(URL(fileURLWithPath: "/bin/bash"), arguments: [helper.path, "engine-path"], environment: environment), result.status == 0 {
                sourceRoot = URL(fileURLWithPath: result.output.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            let script = try? String(contentsOf: sourceRoot.appendingPathComponent("scripts/build_ipa_from_nsp.py"), encoding: .utf8)
            let ready = script?.contains("--shell-framework") == true
            dependencies.append(.init(id: "nx-shell", detail: ready ? "已就绪 · iOS 共享宿主构建源码" : "需下载并准备 NX2Apple 的 iOS 构建源码", isReady: ready))
            let xcodegen = executable(named: "xcodegen", in: environment)
            dependencies.append(.init(id: "xcodegen", detail: xcodegen.map { "已就绪 · \($0.path)" }
                                      ?? "需要通过 Homebrew 安装 xcodegen", isReady: xcodegen != nil))
        }
        do {
            let python = try await findCompatiblePython(environment: environment)
            dependencies.append(.init(id: "python", detail: "已就绪 · \(python.path)", isReady: true))
        } catch {
            dependencies.append(.init(id: "python", detail: "需要 Apple Silicon Python 3.12 或更新版本", isReady: false))
        }

        let runtime = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Game Center/SwitchEngines/nxnative-runtime/bin/python3")
        let packageCheck: (status: Int32, output: String)? = if FileManager.default.isExecutableFile(atPath: runtime.path) {
            try? await capture(runtime, arguments: ["-c", nxNativePythonImportCheck])
        } else { nil }
        let requirements = try? Data(contentsOf: sourceRoot.appendingPathComponent(".github/requirements/tools.txt"))
        let digest = requirements.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
        let marker = runtime.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("requirements.sha256")
        let packagesReady = packageCheck?.status == 0 && digest != nil && digest == (try? String(contentsOf: marker, encoding: .utf8))
        dependencies.append(.init(
            id: "python-packages",
            detail: packagesReady ? "已就绪 · Python 构建依赖" : "安装 lz4、capstone、fonttools、zbic 等依赖",
            isReady: packagesReady
        ))

        for (id, tool, name) in [
            ("zstd", "zstd", "zstd"),
            ("glslang", "glslangValidator", "glslangValidator")
        ] {
            let path = executable(named: tool, in: environment)
            let ready = path != nil
            dependencies.append(.init(id: id, detail: ready ? "已就绪 · \(path?.path ?? "")" : "需要通过 Homebrew 安装 \(name)", isReady: ready))
        }

        let translator = sourceRoot.appendingPathComponent("dm/gfx/tools/dmsh_xlate_bin/dmsh_xlate")
        let probe = try? await capture(translator, arguments: ["--source-sha"], environment: environment)
        let ready = probe?.status == 0 && probe?.output.isEmpty == false
        dependencies.append(.init(id: target == .iOS ? "nx-ios-translator" : "nx-translator", detail: ready ? "已就绪 · dmsh_xlate" : "缺少可运行的着色器转换器，请修复引擎资源", isReady: ready))
        let spirvCross = root.appendingPathComponent("engine/dm/gfx/tools/spirv_cross_bin/spirv-cross")
        dependencies.append(.init(id: "spirv-cross", detail: FileManager.default.isExecutableFile(atPath: spirvCross.path) ? "已随引擎内置" : "引擎资源缺少着色器工具，请更新 nxnative", isReady: FileManager.default.isExecutableFile(atPath: spirvCross.path)))
        if dependencies.contains(where: { ["python", "xcodegen", "zstd", "glslang"].contains($0.id) && !$0.isReady }),
           (try? brewExecutable()) == nil {
            dependencies.append(.init(id: "homebrew", detail: "缺少的命令行工具可通过 Homebrew 安装", isReady: false))
        }
        return dependencies
    }

    static func installBuildDependency(
        id: String,
        method: SwitchBuildMethod,
        target: SwitchBuildTarget,
        progress: @escaping @Sendable (String) -> Void
    ) async throws {
        if id == "engine" {
            _ = try await SwitchEngineInstaller.ensureInstalled(method) { progress($0) }
            return
        }
        if id == "nx-shell" || id == "nx-ios-translator" {
            let script = try MobileAppBuilder.script("prepare-nx-shell.sh")
            let result = try await capture(URL(fileURLWithPath: "/bin/bash"), arguments: [script.path, "engine"],
                                           environment: nxNativeEnvironment(SwitchEngineInstaller.installRoot(for: method)), progress: progress)
            guard result.status == 0 else { throw SwitchBuildError.commandFailed(result.output) }
            return
        }
        if id == "spirv-cross" || id == "nx-translator" || id == "s2arm-runtime" || id == "s2arm-ios-host" {
            _ = try await SwitchEngineInstaller.ensureInstalled(method, forceUpdate: true) { progress($0) }
            return
        }
        if id == "python-packages" {
            let root = SwitchEngineInstaller.installRoot(for: .nxnative)
            let environment = nxNativeEnvironment(root)
            var source = root.appendingPathComponent("engine", isDirectory: true)
            if target == .iOS {
                let script = try MobileAppBuilder.script("prepare-nx-shell.sh")
                let result = try await capture(URL(fileURLWithPath: "/bin/bash"), arguments: [script.path, "engine"], environment: environment)
                guard result.status == 0, let last = result.output.split(whereSeparator: \.isNewline).last, last.hasPrefix("/") else {
                    throw SwitchBuildError.commandFailed(result.output)
                }
                source = URL(fileURLWithPath: String(last)).appendingPathComponent("engine")
            }
            _ = try await prepareNXNativePython(
                engineRoot: root,
                sourceRoot: source,
                environment: environment,
                progress: { value in progress(value.detail) }
            )
            return
        }

        let executable: URL
        let arguments: [String]
        switch id {
        case "metal":
            executable = URL(fileURLWithPath: "/usr/bin/xcodebuild")
            arguments = ["-downloadComponent", "MetalToolchain"]
        case "ios-sdk":
            executable = URL(fileURLWithPath: "/usr/bin/xcodebuild")
            arguments = ["-downloadPlatform", "iOS"]
        case "python":
            guard let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].map(URL.init(fileURLWithPath:)).first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
                throw SwitchBuildError.missingTool("未检测到 Homebrew。请先安装 Homebrew，再点击 Python 依赖的安装按钮。")
            }
            executable = brew
            arguments = ["install", "python@3.14"]
        case "zstd":
            executable = try brewExecutable()
            arguments = ["install", "zstd"]
        case "glslang":
            executable = try brewExecutable()
            arguments = ["install", "glslang"]
        case "xcodegen":
            executable = try brewExecutable()
            arguments = ["install", "xcodegen"]
        case "dotnet":
            executable = try brewExecutable()
            arguments = ["install", "--cask", "dotnet-sdk"]
        default:
            throw SwitchBuildError.missingTool("此依赖无法由 Game Center 自动安装，请检查其安装来源。")
        }
        progress("开始安装…")
        let result = try await capture(executable, arguments: arguments) { progress($0) }
        guard result.status == 0 else {
            throw SwitchBuildError.commandFailed(result.output.isEmpty ? "安装失败（退出码 \(result.status)）。" : result.output)
        }
    }

    static func checkAndUpdateEngine(
        _ method: SwitchBuildMethod,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        let latest = try await SwitchEngineInstaller.latestVersion(for: method)
        let installed = SwitchEngineInstaller.installInfo(for: method)
        let current = installed?.version ?? "未安装"
        if installed?.version == latest {
            return "当前版本 \(current) · 最新版本 \(latest)（已是最新）"
        }
        progress("当前版本 \(current) · 最新版本 \(latest)，正在自动更新…")
        _ = try await SwitchEngineInstaller.ensureInstalled(method, forceUpdate: installed != nil) { line in
            progress("当前版本 \(current) · 最新版本 \(latest) · \(line)")
        }
        return "当前版本 \(latest) · 最新版本 \(latest)（已更新）"
    }

    private static func brewExecutable() throws -> URL {
        guard let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].map(URL.init(fileURLWithPath:)).first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw SwitchBuildError.missingTool("未检测到 Homebrew。请先安装 Homebrew，再安装此依赖。")
        }
        return brew
    }

    private static func executable(named name: String, in environment: [String: String]) -> URL? {
        let paths = (environment["PATH"] ?? "").split(separator: ":")
        return paths
            .map { URL(fileURLWithPath: String($0), isDirectory: true).appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func build(
        game: Game,
        method: SwitchBuildMethod,
        target: SwitchBuildTarget = .macOS,
        source: URL,
        updatePackage: URL?,
        dlcPackages: [URL],
        keys: URL?,
        outputDirectory: URL,
        iosOptions: SwitchIOSBuildOptions = .init(),
        progress: @escaping @Sendable (SwitchBuildProgress) -> Void
    ) async throws -> URL {
        if target == .iOS {
            let signing = try AppleAccountSigning.gameEnvironment()
            progress(.init(stage: "签名检查", detail: "开发团队 " + (signing["GAME_CENTER_IOS_TEAM_ID"] ?? ""), fraction: nil, log: []))
        }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let cacheLease = try SwitchBuildCache(outputDirectory: outputDirectory)
        defer { cacheLease.finish(); withExtendedLifetime(cacheLease) {} }
        try migrateLegacyBuildData(in: outputDirectory)
        let preparedSource = try prepareInput(source, game: game, updatePackage: updatePackage,
                                              dlcPackages: dlcPackages, method: method, outputDirectory: outputDirectory)
        let engineRoot = try await SwitchEngineInstaller.ensureInstalled(method) { detail in
            progress(.init(stage: "准备内置引擎", detail: detail, fraction: nil, log: []))
        }
        let appURL: URL
        switch method {
        case .nxnative:
            appURL = try await buildWithNXNative(
                game: game,
                target: target,
                source: preparedSource,
                keys: keys,
                outputDirectory: outputDirectory,
                engineRoot: engineRoot,
                iosOptions: iosOptions,
                progress: progress
            )
        case .s2arm:
            appURL = try await buildWithS2Arm(
                game: game,
                target: target,
                source: preparedSource,
                keys: keys,
                outputDirectory: outputDirectory,
                engineRoot: engineRoot,
                iosOptions: iosOptions,
                progress: progress
            )
        }
        return appURL
    }

    private static func migrateLegacyBuildData(in outputDirectory: URL) throws {
        let fm = FileManager.default
        let legacy = outputDirectory.appendingPathComponent(".GameCenterBuildInputs", isDirectory: true)
        let destination = outputDirectory
            .appendingPathComponent("build", isDirectory: true)
            .appendingPathComponent("nxnative", isDirectory: true)
        if fm.fileExists(atPath: legacy.path) {
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: destination.path) {
                try fm.moveItem(at: legacy, to: destination)
            } else {
                for item in try fm.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil) {
                    let target = destination.appendingPathComponent(item.lastPathComponent)
                    if !fm.fileExists(atPath: target.path) {
                        try fm.moveItem(at: item, to: target)
                    }
                }
                if (try? fm.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil).isEmpty) == true {
                    try fm.removeItem(at: legacy)
                }
            }
        }

        // S2ArmData is the persistent home for standalone runtime logs/caches.
        // Build inputs and products are independently staged under switch/build.
    }

    private static func prepareInput(
        _ source: URL,
        game: Game,
        updatePackage: URL?,
        dlcPackages: [URL],
        method: SwitchBuildMethod,
        outputDirectory: URL
    ) throws -> URL {
        guard source.pathExtension.lowercased() != "app" else {
            throw SwitchBuildError.commandFailed("请选择原始游戏本体或游戏文件夹，再构建其他平台版本。")
        }
        let values = try? source.resourceValues(forKeys: [.isDirectoryKey])
        let extras = [updatePackage].compactMap { $0 } + dlcPackages
        if values?.isDirectory == true {
            guard extras.isEmpty else {
                throw SwitchBuildError.commandFailed("选择游戏文件夹时，请把更新放入 updates 子文件夹、DLC 放入 dlc 子文件夹，再选择该游戏文件夹。")
            }
        }

        let extensions: Set<String> = ["nsp", "xci", "nsz", "xcz", "nup"]
        guard values?.isDirectory == true || extensions.contains(source.pathExtension.lowercased()) else {
            throw SwitchBuildError.commandFailed("请选择 NSP、XCI、NSZ、XCZ、NUP 文件或包含游戏文件的目录。")
        }
        guard extras.allSatisfy({ extensions.contains($0.pathExtension.lowercased()) }) else {
            throw SwitchBuildError.commandFailed("更新包和 DLC 需要是 NSP、XCI、NSZ 或 XCZ 文件。")
        }
        if source.pathExtension.lowercased() == "nup", !extras.isEmpty {
            throw SwitchBuildError.commandFailed("NUP 文件已包含游戏内容，请不要另外选择更新或 DLC。")
        }
        let methodBuildRoot = outputDirectory
            .appendingPathComponent("build", isDirectory: true)
            .appendingPathComponent(method == .nxnative ? "nxnative" : "S2Arm", isDirectory: true)
        let inputRoot = method == .nxnative
            ? methodBuildRoot
            : methodBuildRoot.appendingPathComponent("inputs", isDirectory: true)
        let staging = inputRoot.appendingPathComponent(safeName(game.metadataTitle ?? game.title), isDirectory: true)
        if source.standardizedFileURL == staging.standardizedFileURL { return source }
        let fm = FileManager.default
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        let selectedFiles: [URL]
        if values?.isDirectory == true {
            selectedFiles = (try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        } else {
            let sourceID = titleID(in: source.lastPathComponent)
            let siblings = (try? fm.contentsOfDirectory(at: source.deletingLastPathComponent(), includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
            selectedFiles = siblings.filter { candidate in
                guard extensions.contains(candidate.pathExtension.lowercased()) else { return false }
                if candidate.standardizedFileURL == source.standardizedFileURL { return true }
                guard let sourceID, let siblingID = titleID(in: candidate.lastPathComponent) else { return false }
                return sourceID.prefix(12) == siblingID.prefix(12)
            }
        }
        var files = selectedFiles.isEmpty ? [source] : selectedFiles
        files.append(contentsOf: extras)
        var seen = Set<String>()
        files = files.filter { seen.insert($0.standardizedFileURL.path).inserted }
        let inputNames = Set(files.map(\.lastPathComponent))
        for existing in (try? fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? [] {
            guard (try? existing.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true,
                  !inputNames.contains(existing.lastPathComponent) else { continue }
            try fm.removeItem(at: existing)
        }
        for file in files {
            let link = staging.appendingPathComponent(file.lastPathComponent)
            if fm.fileExists(atPath: link.path) || (try? link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                try fm.removeItem(at: link)
            }
            try fm.createSymbolicLink(at: link, withDestinationURL: file)
        }
        return staging
    }

    private static func titleID(in filename: String) -> String? {
        guard let range = filename.range(of: #"[0-9a-fA-F]{16}"#, options: .regularExpression) else { return nil }
        return filename[range].uppercased()
    }

    private static func buildWithNXNative(
        game: Game,
        target: SwitchBuildTarget,
        source: URL,
        keys: URL?,
        outputDirectory: URL,
        engineRoot: URL,
        iosOptions: SwitchIOSBuildOptions,
        progress: @escaping @Sendable (SwitchBuildProgress) -> Void
    ) async throws -> URL {
        let environment = nxNativeEnvironment(engineRoot)
        try await checkNXNativePrerequisites(environment: environment)
        let sourceRoot: URL
        if target == .iOS {
            guard executable(named: "xcodegen", in: environment) != nil else {
                throw SwitchBuildError.missingTool("nxnative iOS 构建需要 xcodegen。请用 Homebrew 安装 xcodegen。")
            }
            let helper = try MobileAppBuilder.script("prepare-nx-shell.sh")
            let root = try await capture(URL(fileURLWithPath: "/bin/bash"), arguments: [helper.path, "engine"], environment: environment) { line in
                progress(.init(stage: "准备 NX2Apple", detail: line, fraction: nil, log: [line]))
            }
            guard root.status == 0, let path = root.output.split(whereSeparator: \.isNewline).last, path.hasPrefix("/") else {
                throw SwitchBuildError.commandFailed("无法准备带共享 Shell 的 NX2Apple 引擎。\(root.output)")
            }
            sourceRoot = URL(fileURLWithPath: String(path), isDirectory: true).appendingPathComponent("engine")
        } else {
            sourceRoot = engineRoot.appendingPathComponent("engine", isDirectory: true)
        }
        let script = sourceRoot.appendingPathComponent("scripts/build_ipa_from_nsp.py")
        guard FileManager.default.fileExists(atPath: script.path) else {
            throw SwitchBuildError.missingTool("Game Center 内置的 nxnative 引擎资源不完整，请在构建设置中更新引擎。")
        }
        let python = try await prepareNXNativePython(engineRoot: engineRoot, sourceRoot: sourceRoot,
                                                     environment: environment, progress: progress)

        let methodBuildRoot = outputDirectory.appendingPathComponent("build/nxnative", isDirectory: true)
        let shaderCacheDirectory = outputDirectory.appendingPathComponent("build/cache/nxnative/" + target.rawValue)
        try FileManager.default.createDirectory(at: shaderCacheDirectory, withIntermediateDirectories: true)
        let shaderCacheRoot = shaderCacheDirectory.appendingPathComponent("cas.db")
        let workDirectory = methodBuildRoot.appendingPathComponent("work", isDirectory: true)
        let temporaryDirectory = methodBuildRoot.appendingPathComponent("tmp", isDirectory: true)
        let stagedOutputDirectory = methodBuildRoot.appendingPathComponent("output", isDirectory: true)
        let available = try outputDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage ?? 0
        let minimumFreeSpace: Int64 = 30 * 1024 * 1024 * 1024
        guard available >= minimumFreeSpace else {
            throw SwitchBuildError.commandFailed(
                "nxnative 构建至少需要 30GB 可用空间，当前约 \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file))。请清理磁盘或选择其他磁盘后重试。"
            )
        }
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stagedOutputDirectory, withIntermediateDirectories: true)
        var completed = false
        defer {
            if !completed {
                try? cleanupSuccessfulBuildData(methodBuildRoot, outputDirectory: outputDirectory)
            }
        }

        let platformArgument = target == .iOS ? "ios" : "mac-app"
        var arguments = [script.path, source.path, "--platform", platformArgument, "--work-dir", workDirectory.path]
        if let keys { arguments += ["-k", keys.path] }
        let outputExtension = target == .iOS ? ".gcimport" : ".app"
        if target == .iOS {
            let environmentFile = stagedOutputDirectory.appendingPathComponent("ios.env")
            try Data(iosOptions.nxEnvironmentFile.utf8).write(to: environmentFile, options: .atomic)
            arguments += ["--shell-framework", stagedOutputDirectory.appendingPathComponent("framework").path,
                          "--shader-files", "--progress", "json", "--env-file", environmentFile.path]
            var buildEnvironment = environment
            buildEnvironment["DMSH_CAS"] = shaderCacheRoot.path
            buildEnvironment["TMPDIR"] = temporaryDirectory.path + "/"
            let result = try await capture(python, arguments: arguments, environment: buildEnvironment) { line in
                progress(parseNXProgress(line))
            }
            guard result.status == 0 else {
                throw SwitchBuildError.commandFailed("nxnative iOS 构建失败（退出码 \(result.status)）。请查看构建日志。")
            }
            let frameworks = try FileManager.default.contentsOfDirectory(at: stagedOutputDirectory.appendingPathComponent("framework"), includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "framework" }
            guard frameworks.count == 1, let framework = frameworks.first else {
                throw SwitchBuildError.commandFailed("nxnative 没有生成唯一的游戏 Framework。")
            }
            let metadataURL = framework.appendingPathComponent("game.manifest.json")
            guard let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any],
                  let id = (metadata["title_id"] as? String)?.uppercased(),
                  MobileLibraryFormat.isTitleID(id), metadata["loader"] as? String == "FH",
                  let image = nxBuiltROMFS(result.output, under: workDirectory) else {
                throw SwitchBuildError.commandFailed("nxnative 没有返回兼容的 Framework 或 RomFS IMG。")
            }
            let signingEnvironment = try AppleAccountSigning.gameEnvironment(environment)
            let signing = mobileSigning(signingEnvironment)
            if signingEnvironment["GAME_CENTER_PLUME_SIGN"] == "1" {
                _ = try AppleAccountSigning.helper(["framework", signing.team, signing.identity, signing.bundleID, framework.path])
            } else {
                let status = try await run(URL(fileURLWithPath: "/usr/bin/codesign"), arguments: [
                    "--force", "--sign", signing.identity, "--identifier", signing.bundleID, framework.path
                ]) { line in progress(.init(stage: "签名", detail: line, fraction: nil, log: [line])) }
                guard status == 0 else { throw SwitchBuildError.commandFailed("nxnative Framework 签名失败。") }
            }
            let verified = try await capture(URL(fileURLWithPath: "/usr/bin/codesign"), arguments: ["--verify", "--strict", framework.path])
            let signature = try await capture(URL(fileURLWithPath: "/usr/bin/codesign"), arguments: ["-dv", framework.path])
            guard verified.status == 0, signature.status == 0,
                  signature.output.split(whereSeparator: \.isNewline).contains(Substring("TeamIdentifier=" + signing.team)),
                  signature.output.split(whereSeparator: \.isNewline).contains(Substring("Identifier=" + signing.bundleID)) else {
                throw SwitchBuildError.commandFailed("nxnative 游戏签名团队校验失败。")
            }
            try MobileSigning.verifyLeafCertificate(framework, fingerprint: signing.identity)
            let build = MobileLibraryFormat.SwitchBuild(titleID: id, title: game.metadataTitle ?? game.title, engine: .nxnative)
            let resultURL = try makeMobileImport(build, program: framework, image: image,
                                                   workDirectory: workDirectory, staging: stagedOutputDirectory,
                                                   outputDirectory: outputDirectory)
            try cleanupSuccessfulBuildData(methodBuildRoot, outputDirectory: outputDirectory)
            completed = true
            progress(.init(stage: "构建完成", detail: resultURL.lastPathComponent, fraction: 1, log: []))
            return resultURL
        }
        let appURL = outputDirectory.appendingPathComponent(safeName(game.metadataTitle ?? game.title) + outputExtension, isDirectory: target == .macOS)
        let stagedAppURL = stagedOutputDirectory.appendingPathComponent(appURL.lastPathComponent, isDirectory: target == .macOS)
        let stagedTitleID = (try? FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil))?
            .compactMap { titleID(in: $0.lastPathComponent) }.first
        let titleID = titleID(in: source.lastPathComponent) ?? stagedTitleID ?? titleID(in: game.title)
        let saveName = titleID ?? game.id.uuidString.uppercased()
        let saveDirectory = GameSaveLayout.folder(root: GameSaveLayout.root(besidePlatformDirectory: outputDirectory), platform: "switch", game: saveName).appendingPathComponent("save", isDirectory: true)
        let legacySave = outputDirectory.appendingPathComponent("save/" + saveName)
        let wrapped = FileManager.default.fileExists(atPath: legacySave.appendingPathComponent("save").path)
        try GameSaveLayout.migrate(legacySave, to: wrapped ? saveDirectory.deletingLastPathComponent() : saveDirectory,
                                   saveRoot: GameSaveLayout.root(besidePlatformDirectory: outputDirectory).appendingPathComponent("save"))
        try FileManager.default.createDirectory(at: saveDirectory, withIntermediateDirectories: true)
        let environmentFile = source.appendingPathComponent("\(saveName).env")
        let cheatDirectory = titleID.map {
            outputDirectory.appendingPathComponent("cheat", isDirectory: true)
                .appendingPathComponent($0, isDirectory: true)
                .appendingPathComponent("cheats", isDirectory: true)
        }
        if let cheatDirectory {
            try FileManager.default.createDirectory(at: cheatDirectory, withIntermediateDirectories: true)
        }
        let shaderCache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GameCenter/Switch/" + saveDirectory.deletingLastPathComponent().lastPathComponent)
        try FileManager.default.createDirectory(at: shaderCache, withIntermediateDirectories: true)
        var gameEnvironment = "DM_SAVE=\(saveDirectory.path)\nDM_PSO_USER=\(shaderCache.appendingPathComponent("pso_user.tsv").path)\nDM_PSO_ARCHIVE=\(shaderCache.appendingPathComponent("pso_archive").path)\n"
        if let cheatDirectory { gameEnvironment += "DM_CHEATS=\(cheatDirectory.path)\n" }
        try Data(gameEnvironment.utf8).write(to: environmentFile, options: .atomic)
        arguments += ["--env-file", environmentFile.path]
        arguments += ["-o", stagedAppURL.path, "--progress", "json"]

        var buildEnvironment = environment
        buildEnvironment["DMSH_CAS"] = shaderCacheRoot.path
        buildEnvironment["TMPDIR"] = temporaryDirectory.path + "/"
        buildEnvironment["TMP"] = temporaryDirectory.path
        buildEnvironment["TEMP"] = temporaryDirectory.path

        progress(.init(stage: "nxnative", detail: "正在启动 Game Center 内置构建引擎…", fraction: nil, log: []))
        let result = try await capture(python, arguments: arguments, environment: buildEnvironment) { line in
            progress(parseNXProgress(line))
        }
        guard result.status == 0, FileManager.default.fileExists(atPath: stagedAppURL.path) else {
            if result.output.localizedCaseInsensitiveContains("No space left on device") {
                throw SwitchBuildError.commandFailed("nxnative 构建时磁盘空间耗尽；本次临时文件已自动清理。请释放更多空间或将 switch 目录移到容量更大的磁盘后重试。")
            }
            throw SwitchBuildError.commandFailed("nxnative 构建失败（退出码 \(result.status)）。本次临时文件已自动清理，请查看构建日志。")
        }
        if target == .macOS, try await installGameIcon(for: game, in: stagedAppURL, temporaryDirectory: temporaryDirectory, progress: progress) {
            let signingStatus = try await run(URL(fileURLWithPath: "/usr/bin/codesign"), arguments: ["--force", "--deep", "--sign", "-", stagedAppURL.path]) { line in
                progress(.init(stage: "应用图标", detail: line, fraction: 0.98, log: []))
            }
            guard signingStatus == 0 else { throw SwitchBuildError.commandFailed("写入游戏图标后，nxnative 应用重新签名失败。") }
        }
        try publishBuiltApplication(from: stagedAppURL, to: appURL, backupDirectory: methodBuildRoot.appendingPathComponent("previous", isDirectory: true))
        progress(.init(stage: "清理临时文件", detail: "正在删除 nxnative 构建目录…", fraction: 0.99, log: []))
        try cleanupSuccessfulBuildData(
            outputDirectory.appendingPathComponent("build/nxnative", isDirectory: true),
            outputDirectory: outputDirectory
        )
        completed = true
        progress(.init(stage: "构建完成", detail: appURL.lastPathComponent, fraction: 1, log: []))
        return appURL
    }

    private static func nxBuiltROMFS(_ output: String, under root: URL) -> URL? {
        for line in output.split(whereSeparator: \.isNewline).reversed() {
            guard let data = line.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let message = event["msg"] as? String,
                  let range = message.range(of: "game files: "), message[range.upperBound...].hasPrefix("/") else { continue }
            let file = URL(fileURLWithPath: String(message[range.upperBound...])).resolvingSymlinksInPath()
            guard file.pathComponents.starts(with: root.resolvingSymlinksInPath().pathComponents),
                  file.pathExtension.lowercased() == "img",
                  (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            return file
        }
        return nil
    }

    private static func mobileSigning(_ environment: [String: String]) -> (identity: String, team: String, bundleID: String) {
        return (environment["GAME_CENTER_IOS_SIGN_IDENTITY"] ?? "-", environment["GAME_CENTER_IOS_TEAM_ID"] ?? "",
         environment["GAME_CENTER_IOS_BUNDLE_ID"] ?? MobileSigning.defaultBundleID)
    }

    private static func makeMobileImport(
        _ manifest: MobileLibraryFormat.SwitchBuild, program: URL, image: URL, workDirectory: URL,
        staging: URL, outputDirectory: URL
    ) throws -> URL {
        let fm = FileManager.default
        let scratch = staging.appendingPathComponent("package-\(UUID().uuidString)", isDirectory: true)
        let content = scratch.appendingPathComponent("Content", isDirectory: true)
        try fm.createDirectory(at: content, withIntermediateDirectories: true)
        if manifest.engine == .s2arm {
            for item in try fm.contentsOfDirectory(at: program, includingPropertiesForKeys: nil)
                where ![".key", "meta.json"].contains(item.lastPathComponent) {
                try fm.copyItem(at: item, to: scratch.appendingPathComponent(item.lastPathComponent))
            }
            for item in try fm.contentsOfDirectory(at: image.deletingLastPathComponent(), includingPropertiesForKeys: nil) {
                try fm.copyItem(at: item, to: content.appendingPathComponent(item.lastPathComponent))
            }
        } else {
            try fm.moveItem(at: program, to: scratch.appendingPathComponent(manifest.executable))
            try fm.moveItem(at: image, to: content.appendingPathComponent(manifest.image))
            let sibling = image.appendingPathExtension("id")
            if fm.fileExists(atPath: sibling.path) {
                try fm.moveItem(at: sibling, to: content.appendingPathComponent(manifest.image + ".id"))
            }
            var ancestor = image.deletingLastPathComponent()
            let workPath = workDirectory.resolvingSymlinksInPath().pathComponents
            while ancestor.pathComponents.starts(with: workPath) {
                let aoc = ancestor.appendingPathComponent("aoc", isDirectory: true)
                if (try? aoc.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    try fm.moveItem(at: aoc, to: content.appendingPathComponent("aoc"))
                    break
                }
                ancestor.deleteLastPathComponent()
            }
        }
        try JSONEncoder().encode(manifest).write(to: scratch.appendingPathComponent("manifest.json"), options: .atomic)
        let destinationRoot = outputDirectory.appendingPathComponent("iOS", isDirectory: true)
        try fm.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        let destination = destinationRoot.appendingPathComponent("\(manifest.titleID)-\(manifest.engine.rawValue).gcimport", isDirectory: true)
        try publishBuiltApplication(from: scratch, to: destination, backupDirectory: staging.appendingPathComponent("previous"))
        return destination
    }

    private static func checkNXNativePrerequisites(environment: [String: String]) async throws {
        let xcode = try await capture(URL(fileURLWithPath: "/usr/bin/xcode-select"), arguments: ["-p"], environment: environment)
        guard xcode.status == 0 else {
            throw SwitchBuildError.missingTool("nxnative 构建需要 Xcode 及其 Metal Toolchain。请安装并选择受支持的 Xcode 版本。")
        }
        // NXNative's mac-app target does not generate an Xcode project, so xcodegen is not needed.
        let requiredTools = ["xcodebuild", "zstd", "glslangValidator"]
        let missing = requiredTools.filter { tool in
            let candidates = (environment["PATH"] ?? "").split(separator: ":").map {
                URL(fileURLWithPath: String($0), isDirectory: true).appendingPathComponent(tool)
            }
            return !candidates.contains(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
        }
        guard missing.isEmpty else {
            throw SwitchBuildError.missingTool("nxnative 缺少构建工具：\(missing.joined(separator: "、"))。请按官方说明安装 Homebrew 工具，并安装 Xcode Metal Toolchain。")
        }
    }

    private static func prepareNXNativePython(
        engineRoot: URL,
        sourceRoot: URL,
        environment: [String: String],
        progress: @escaping @Sendable (SwitchBuildProgress) -> Void
    ) async throws -> URL {
        let runtime = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Game Center/SwitchEngines/nxnative-runtime", isDirectory: true)
        // `python -m venv runtime.path` creates bin/python3 directly below runtime.
        // Keep detection and installation pointed at that same environment root.
        let python = runtime.appendingPathComponent("bin/python3")
        let requirement = sourceRoot.appendingPathComponent(".github/requirements/tools.txt")
        guard FileManager.default.fileExists(atPath: requirement.path) else {
            throw SwitchBuildError.missingTool("nxnative 源码包未包含 Python 依赖清单。")
        }
        let requirementDigest = SHA256.hash(data: try Data(contentsOf: requirement))
            .map { String(format: "%02x", $0) }.joined()
        let marker = runtime.appendingPathComponent("requirements.sha256")
        if FileManager.default.isExecutableFile(atPath: python.path),
           (try? String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) == requirementDigest {
            let packageCheck = try? await capture(python, arguments: ["-c", nxNativePythonImportCheck], environment: environment)
            if packageCheck?.status == 0 { return python }
        }

        let basePython = try await findCompatiblePython(environment: environment)
        try FileManager.default.createDirectory(at: runtime.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.isExecutableFile(atPath: python.path) {
            progress(.init(stage: "准备 nxnative Python 环境", detail: "创建独立依赖环境…", fraction: nil, log: []))
            let status = try await run(basePython, arguments: ["-m", "venv", runtime.path], environment: environment) { line in
                progress(.init(stage: "准备 nxnative Python 环境", detail: line, fraction: nil, log: [line]))
            }
            guard status == 0 else {
                throw SwitchBuildError.missingTool("无法创建 nxnative Python 环境。请安装 Python 3.12 或更新版本，并确保其包含 pip/venv。")
            }
        }
        progress(.init(stage: "安装 nxnative 依赖", detail: "首次配置时会从 PyPI 下载所需 Python 包…", fraction: nil, log: []))
        let status = try await run(
            python,
            arguments: ["-m", "pip", "install", "-r", requirement.path, "backports.zstd; python_version < '3.14'"],
            environment: environment
        ) { line in
            progress(.init(stage: "安装 nxnative 依赖", detail: line, fraction: nil, log: [line]))
        }
        guard status == 0 else {
            throw SwitchBuildError.commandFailed("nxnative Python 依赖安装失败。检查网络连接后可重试。")
        }
        try Data(requirementDigest.utf8).write(to: marker, options: .atomic)
        return python
    }

    private static func findCompatiblePython(environment: [String: String]) async throws -> URL {
        var candidates = [
            "/opt/homebrew/bin/python3.14", "/opt/homebrew/bin/python3.13", "/opt/homebrew/bin/python3.12",
            "/usr/local/bin/python3.14", "/usr/local/bin/python3.13", "/usr/local/bin/python3.12"
        ].map { URL(fileURLWithPath: $0) }
        candidates += (environment["PATH"] ?? "").split(separator: ":").map {
            URL(fileURLWithPath: String($0), isDirectory: true).appendingPathComponent("python3")
        }
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
            let result = try await capture(candidate, arguments: ["-c", "import platform,sys,venv,ensurepip; print(sys.version_info.major, sys.version_info.minor); print(sys.platform, platform.machine())"])
            guard result.status == 0 else { continue }
            let lines = result.output.split(whereSeparator: \.isNewline)
            guard lines.count >= 2, lines[1] == "darwin arm64" else { continue }
            let version = lines[0].split(separator: " ").compactMap { Int($0) }
            if version.count == 2, version[0] == 3, version[1] >= 12 { return candidate }
        }
        throw SwitchBuildError.missingTool("直接构建 nxnative 需要 Apple Silicon Python 3.12 或更新版本。可通过 Homebrew 安装 Python。")
    }

    private static func buildWithS2Arm(
        game: Game,
        target: SwitchBuildTarget,
        source: URL,
        keys: URL?,
        outputDirectory: URL,
        engineRoot: URL,
        iosOptions: SwitchIOSBuildOptions,
        progress: @escaping @Sendable (SwitchBuildProgress) -> Void
    ) async throws -> URL {
        guard FileManager.default.isExecutableFile(atPath: engineRoot.appendingPathComponent("Runtime/python/bin/python3.12").path),
              FileManager.default.fileExists(atPath: engineRoot.appendingPathComponent("Jobs/main.py").path) else {
            throw SwitchBuildError.missingTool("Game Center 内置的 S2Arm 引擎资源不完整，请在构建设置中更新引擎。")
        }
        let dataRoot = outputDirectory
            .appendingPathComponent("build", isDirectory: true)
            .appendingPathComponent("S2Arm", isDirectory: true)
        let privateRoot = dataRoot.appendingPathComponent("private", isDirectory: true)
        let library = dataRoot.appendingPathComponent("library", isDirectory: true)
        var completed = false
        defer {
            if !completed {
                try? cleanupSuccessfulBuildData(dataRoot, outputDirectory: outputDirectory)
            }
        }
        if target == .iOS, !FileManager.default.fileExists(atPath: engineRoot.appendingPathComponent("Jobs/program_pack.py").path) {
            throw SwitchBuildError.missingTool("当前 S2Arm 引擎没有通用壳 program_pack。请更新至提供该功能的 S2Arm 版本。")
        }
        let setup = try await runS2ArmJob("setup", gameID: nil, extra: [:], engineRoot: engineRoot,
                                          privateRoot: privateRoot, library: library, progress: progress)
        let libraryMarker = library.appendingPathComponent(".s2arm-library.json")
        guard let markerData = try? Data(contentsOf: libraryMarker),
              let marker = try? JSONSerialization.jsonObject(with: markerData) as? [String: Any],
              let libraryID = marker["id"] as? String else {
            throw SwitchBuildError.commandFailed("S2Arm 引擎无法创建游戏库。\(setup.message)")
        }
        if let keys {
            _ = try await runS2ArmJob("keys", gameID: nil, extra: ["path": keys.path], engineRoot: engineRoot,
                                      privateRoot: privateRoot, library: library, libraryID: libraryID, progress: progress)
        }

        let imported = try await runS2ArmJob("import", gameID: nil, extra: ["paths": [source.path]], engineRoot: engineRoot,
                                              privateRoot: privateRoot, library: library, libraryID: libraryID, progress: progress)
        let importedIDs = (imported.result["imports"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        guard let gameID = importedIDs.last ?? titleID(in: source.lastPathComponent) else {
            throw SwitchBuildError.missingGameID
        }

        let cheatDirectory = outputDirectory.appendingPathComponent("cheat", isDirectory: true)
            .appendingPathComponent(gameID.uppercased(), isDirectory: true)
            .appendingPathComponent("cheats", isDirectory: true)
        try FileManager.default.createDirectory(at: cheatDirectory, withIntermediateDirectories: true)
        let importedGameDirectory = try s2ArmGameDirectory(in: library, gameID: gameID)
        try linkS2ArmCheatDirectory(gameDirectory: importedGameDirectory, destination: cheatDirectory)

        if target == .iOS {
            let id = gameID.uppercased()
            guard MobileLibraryFormat.isTitleID(id) else { throw SwitchBuildError.missingGameID }
            let signingEnvironment = try AppleAccountSigning.gameEnvironment()
            let signing = mobileSigning(signingEnvironment)
            guard signing.identity == "-" || !signing.team.isEmpty else {
                throw SwitchBuildError.commandFailed("S2Arm 程序包签名需要 GAME_CENTER_IOS_TEAM_ID。")
            }
            var request = iosOptions.s2ArmRequest
            if signingEnvironment["GAME_CENTER_PLUME_SIGN"] == "1" { request["appleAccountSigning"] = true }
            request.merge(["signIdentity": signing.identity, "teamID": signing.team, "bundleID": signing.bundleID]) { _, value in value }
            let built = try await runS2ArmJob("ipa", gameID: id, extra: request,
                engineRoot: engineRoot, privateRoot: privateRoot, library: library, libraryID: libraryID,
                entryOverride: MobileAppBuilder.script("export-s2arm-ios.py"),
                progress: progress)
            let manifest = MobileLibraryFormat.SwitchBuild(titleID: id, title: game.metadataTitle ?? game.title, engine: .s2arm)
            guard let program = built.result["programPath"] as? String, let content = built.result["contentPath"] as? String else {
                throw SwitchBuildError.commandFailed("S2Arm 没有返回独立的程序包和资源包。")
            }
            let programURL = URL(fileURLWithPath: program, isDirectory: true)
            let image = URL(fileURLWithPath: content, isDirectory: true).appendingPathComponent(manifest.image)
            guard FileManager.default.fileExists(atPath: programURL.appendingPathComponent(manifest.executable).path),
                  FileManager.default.fileExists(atPath: image.path) else {
                throw SwitchBuildError.commandFailed("S2Arm 构建没有生成独立程序 dylib 或 game.img。")
            }
            try MobileSigning.verifyLeafCertificate(programURL.appendingPathComponent(manifest.executable), fingerprint: signing.identity)
            let result = try makeMobileImport(manifest, program: programURL, image: image, workDirectory: dataRoot,
                                              staging: dataRoot, outputDirectory: outputDirectory)
            try cleanupSuccessfulBuildData(dataRoot, outputDirectory: outputDirectory)
            completed = true
            progress(.init(stage: "构建完成", detail: result.lastPathComponent, fraction: 1, log: []))
            return result
        }

        let built = try await runS2ArmJob("build", gameID: gameID, extra: ["cheatsDirectory": cheatDirectory.path], engineRoot: engineRoot,
                                          privateRoot: privateRoot, library: library, libraryID: libraryID, progress: progress)
        guard let outputPath = built.result["outputPath"] as? String else {
            throw SwitchBuildError.commandFailed("S2Arm 引擎完成任务，但没有返回运行资源位置。")
        }

        let runtimeURL = URL(fileURLWithPath: outputPath, isDirectory: true)
        let gameDirectory = runtimeURL.deletingLastPathComponent().deletingLastPathComponent()
        let saveDirectory = GameSaveLayout.folder(root: GameSaveLayout.root(besidePlatformDirectory: outputDirectory), platform: "switch", game: gameID)
        let oldSave = outputDirectory.appendingPathComponent("save/" + gameID)
        let wrapped = FileManager.default.fileExists(atPath: oldSave.appendingPathComponent("save").path)
        try GameSaveLayout.migrate(oldSave, to: wrapped ? saveDirectory : saveDirectory.appendingPathComponent("save"),
                                   saveRoot: GameSaveLayout.root(besidePlatformDirectory: outputDirectory).appendingPathComponent("save"))
        try linkS2ArmSaveDirectory(library: library, gameID: gameID, destination: saveDirectory)
        let displayTitle = game.metadataTitle ?? game.title
        let appURL = try await makeS2ArmStandaloneApp(
            at: outputDirectory.appendingPathComponent(safeName(displayTitle) + ".app", isDirectory: true),
            gameID: gameID,
            title: displayTitle,
            game: game,
            gameDirectory: gameDirectory,
            runtimeURL: runtimeURL,
            engineRoot: engineRoot,
            library: library,
            stagingRoot: dataRoot.appendingPathComponent("package", isDirectory: true),
            progress: progress
        )
        progress(.init(stage: "清理临时文件", detail: "正在删除 S2Arm 构建目录…", fraction: 0.99, log: []))
        try cleanupSuccessfulBuildData(dataRoot, outputDirectory: outputDirectory)
        completed = true
        progress(.init(stage: "构建完成", detail: appURL.lastPathComponent, fraction: 1, log: []))
        return appURL
    }

    private static func cleanupSuccessfulBuildData(_ directory: URL, outputDirectory: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: directory.path) {
            try fm.removeItem(at: directory)
        }
        let buildRoot = outputDirectory.appendingPathComponent("build", isDirectory: true)
        var candidate = directory.deletingLastPathComponent()
        while candidate.path.hasPrefix(buildRoot.path), candidate != outputDirectory {
            try? fm.removeItem(at: candidate.appendingPathComponent(".DS_Store"))
            guard fm.fileExists(atPath: candidate.path),
                  (try? fm.contentsOfDirectory(atPath: candidate.path).isEmpty) == true else { break }
            try fm.removeItem(at: candidate)
            if candidate == buildRoot { break }
            candidate.deleteLastPathComponent()
        }
    }

    private static func publishBuiltApplication(from stagedURL: URL, to destinationURL: URL, backupDirectory: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let backup = backupDirectory.appendingPathComponent(destinationURL.lastPathComponent, isDirectory: true)
        try? fm.removeItem(at: backup)
        if fm.fileExists(atPath: destinationURL.path) {
            try fm.moveItem(at: destinationURL, to: backup)
        }
        do {
            try fm.moveItem(at: stagedURL, to: destinationURL)
            try? fm.removeItem(at: backup)
        } catch {
            if fm.fileExists(atPath: backup.path), !fm.fileExists(atPath: destinationURL.path) {
                try? fm.moveItem(at: backup, to: destinationURL)
            }
            throw error
        }
    }

    private static func s2ArmGameDirectory(in library: URL, gameID: String) throws -> URL {
        let games = library.appendingPathComponent("games", isDirectory: true)
        let candidates = (try? FileManager.default.contentsOfDirectory(
            at: games,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for candidate in candidates {
            let values = try? candidate.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true,
                  let data = try? Data(contentsOf: candidate.appendingPathComponent("game.json")),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (object["id"] as? String)?.uppercased() == gameID.uppercased() else { continue }
            return candidate
        }
        throw SwitchBuildError.commandFailed("S2Arm 已导入游戏，但无法定位其游戏数据目录。")
    }

    private static func linkS2ArmCheatDirectory(gameDirectory: URL, destination: URL) throws {
        let fm = FileManager.default
        let source = gameDirectory.appendingPathComponent("cheats", isDirectory: true)
        let sourceIsLink = (try? source.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
        if sourceIsLink {
            if source.resolvingSymlinksInPath().standardizedFileURL == destination.standardizedFileURL { return }
            try fm.removeItem(at: source)
        } else if fm.fileExists(atPath: source.path) {
            try mergeSaveTree(from: source, to: destination)
            try fm.removeItem(at: source)
        }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: source, withDestinationURL: destination)
    }

    private static func linkS2ArmSaveDirectory(library: URL, gameID: String, destination: URL) throws {
        let fm = FileManager.default
        let librarySave = library.appendingPathComponent("saves", isDirectory: true).appendingPathComponent(gameID, isDirectory: true)
        // Back up and merge existing engine-managed progress before relinking.
        let saveRoot = destination.deletingLastPathComponent().deletingLastPathComponent()
        try GameSaveLayout.migrate(librarySave, to: destination, saveRoot: saveRoot)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        if (try? fm.destinationOfSymbolicLink(atPath: librarySave.path)) == nil {
            try fm.createDirectory(at: librarySave.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: librarySave, withDestinationURL: destination)
        }
    }

    private static func mergeSaveTree(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: []) else { return }
        for item in items {
            let target = destination.appendingPathComponent(item.lastPathComponent)
            guard !fm.fileExists(atPath: target.path) else { continue }
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isDirectory == true && values.isSymbolicLink != true {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                try mergeSaveTree(from: item, to: target)
            } else {
                try fm.copyItem(at: item, to: target)
            }
        }
    }

    private struct S2ArmJobOutcome {
        let result: [String: Any]
        let message: String
    }

    private static func runS2ArmJob(
        _ operation: String,
        gameID: String?,
        extra: [String: Any],
        engineRoot: URL,
        privateRoot: URL,
        library: URL,
        libraryID: String = "",
        entryOverride: URL? = nil,
        environmentOverrides: [String: String] = [:],
        progress: @escaping @Sendable (SwitchBuildProgress) -> Void
    ) async throws -> S2ArmJobOutcome {
        let python = engineRoot.appendingPathComponent("Runtime/python/bin/python3.12")
        let entry = engineRoot.appendingPathComponent("Jobs/main.py")
        let requestDirectory = privateRoot.appendingPathComponent("requests", isDirectory: true)
        try FileManager.default.createDirectory(at: requestDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: privateRoot.path)

        let taskID = UUID().uuidString.lowercased()
        var request: [String: Any] = [
            "schema": 1,
            "taskId": taskID,
            "operation": operation,
            "privateRoot": privateRoot.path,
            "gameCenterCompilerCache": privateRoot.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("cache/S2Arm/" + (SwitchEngineInstaller.installInfo(for: .s2arm)?.version ?? "local")).path,
            "resources": engineRoot.path,
            "engineDir": engineRoot.appendingPathComponent("Engine").path,
            "engineBundle": engineRoot.appendingPathComponent("Engine").path,
            "library": library.path,
            "libraryId": libraryID,
            "developerDir": developerDirectory() ?? "",
            "fontsDir": engineRoot.appendingPathComponent("Fonts").path,
            "buildId": "GameCenter"
        ]
        if let gameID { request["gameId"] = gameID }
        extra.forEach { request[$0.key] = $0.value }

        let requestURL = requestDirectory.appendingPathComponent(taskID + ".json")
        let requestData = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
        try requestData.write(to: requestURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: requestURL.path)

        progress(.init(stage: s2ArmStage(operation), detail: "正在运行 Game Center 内置 S2Arm 作业…", fraction: nil, log: []))
        let output = OutputLines()
        var environment = ProcessInfo.processInfo.environment
        let runtime = engineRoot.appendingPathComponent("Runtime")
        environment["PATH"] = [runtime.appendingPathComponent("python/bin").path,
                                runtime.appendingPathComponent("bin").path,
                                "/usr/bin", "/bin", "/usr/sbin", "/sbin"].joined(separator: ":")
        if FileManager.default.isExecutableFile(atPath: runtime.appendingPathComponent("dotnet/dotnet").path) {
            environment["DOTNET_ROOT"] = runtime.appendingPathComponent("dotnet").path
            environment["DOTNET_MULTILEVEL_LOOKUP"] = "0"
        }
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["PYTHONNOUSERSITE"] = "1"
        environment.merge(environmentOverrides) { _, value in value }
        environment.removeValue(forKey: "PYTHONPATH")
        environment.removeValue(forKey: "PYTHONHOME")
        let arguments = entryOverride.map { ["-B", "-I", $0.path, entry.path, requestURL.path] }
            ?? ["-B", "-I", entry.path, "run", "--request", requestURL.path]
        let status = try await run(python, arguments: arguments, environment: environment) { line in
            output.append(line)
            progress(parseS2ArmProgress(line))
        }
        let events = output.lines.compactMap { line -> [String: Any]? in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        let terminal = events.last(where: { $0["type"] as? String == "result" })
        let message = terminal?["message"] as? String ?? "S2Arm 作业已结束。"
        guard status == 0, terminal?["state"] as? String == "succeeded" else {
            let diagnostics = terminal?["diagnostics"] as? [[String: Any]] ?? []
            let errors = diagnostics.filter { $0["severity"] as? String == "error" }
            let detail = errors.compactMap { $0["detail"] as? String }.joined(separator: "\n")
            let diskDetails = ([message, detail] + errors.compactMap { $0["summary"] as? String }).joined(separator: "\n")
            if errors.contains(where: { $0["code"] as? String == "disk_full" }) ||
                diskDetails.localizedCaseInsensitiveContains("No space left on device") ||
                diskDetails.contains("磁盘空间不足") || diskDetails.contains("直连库开工前空间不足") {
                if message.contains("已在耗时构建前停止") {
                    throw SwitchBuildError.commandFailed(message)
                }
                throw SwitchBuildError.commandFailed("S2Arm 构建失败：磁盘空间不足。本次失败的临时文件会自动清理；存档和上次成功的游戏包保留。请释放更多空间，或将整个游戏目录移到空间充足的磁盘后重试。")
            }
            throw SwitchBuildError.commandFailed(message)
        }
        return S2ArmJobOutcome(result: terminal?["result"] as? [String: Any] ?? [:], message: message)
    }

    private static func s2ArmStage(_ operation: String) -> String {
        switch operation {
        case "setup": "准备 S2Arm 游戏库"
        case "keys": "导入密钥"
        case "import": "读取游戏"
        case "build": "构建游戏"
        case "ipa": "构建 iOS Game Center"
        default: "S2Arm 引擎"
        }
    }

    private static func developerDirectory() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        } catch { return nil }
    }

    private static func makeS2ArmStandaloneApp(
        at url: URL,
        gameID: String,
        title: String,
        game: Game,
        gameDirectory: URL,
        runtimeURL: URL,
        engineRoot: URL,
        library: URL,
        stagingRoot: URL,
        progress: @escaping @Sendable (SwitchBuildProgress) -> Void
    ) async throws -> URL {
        let fm = FileManager.default
        let launcherCandidates = [
            Bundle.main.resourceURL?.appendingPathComponent("Tools/S2ArmStandaloneLauncher"),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("S2ArmStandaloneLauncher")
        ].compactMap { $0 }
        guard let launcher = launcherCandidates.first(where: { fm.isExecutableFile(atPath: $0.path) }) else {
            throw SwitchBuildError.missingTool("独立应用启动器未随 Game Center 安装，请重新打包 Game Center 后再构建。")
        }
        let cheatMenuCandidates = [
            Bundle.main.resourceURL?.appendingPathComponent("Tools/S2ArmCheatMenu.dylib"),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("S2ArmCheatMenu.dylib")
        ].compactMap { $0 }
        guard let cheatMenuLibrary = cheatMenuCandidates.first(where: { fm.fileExists(atPath: $0.path) }) else {
            throw SwitchBuildError.missingTool("S2Arm 金手指菜单组件未随 Game Center 安装，请重新打包 Game Center 后再构建。")
        }
        let gameInfoURL = gameDirectory.appendingPathComponent("game.json")
        guard let gameInfoData = try? Data(contentsOf: gameInfoURL),
              let gameInfo = try? JSONSerialization.jsonObject(with: gameInfoData) as? [String: Any],
              let hostID = gameInfo["hostMac"] as? String else {
            throw SwitchBuildError.commandFailed("S2Arm 没有生成可运行的 Mac 宿主，无法封装独立应用。")
        }
        guard let hostRelativePath = s2ArmMacHostRelativePath(in: library, hostID: hostID, fileManager: fm) else {
            throw SwitchBuildError.commandFailed("Mac 宿主缺失（\(hostID)），不能封装独立应用。")
        }
        guard fm.fileExists(atPath: runtimeURL.appendingPathComponent("manifest.json").path) else {
            throw SwitchBuildError.commandFailed("运行镜像缺失（manifest.json），不能封装独立应用。")
        }
        let hostApp = library.appendingPathComponent(hostRelativePath, isDirectory: true)
        let markerURL = library.appendingPathComponent(".s2arm-library.json")
        guard let markerData = try? Data(contentsOf: markerURL),
              let libraryMarker = try? JSONSerialization.jsonObject(with: markerData) as? [String: Any],
              let resolvedLibraryID = libraryMarker["id"] as? String else {
            throw SwitchBuildError.commandFailed("S2Arm 游戏库标识缺失，无法创建独立应用。")
        }
        let assetVersion = (gameInfo["imageKey"] as? String) ?? gameID
        let engineVersion = SwitchEngineInstaller.installInfo(for: .s2arm)?.version ?? "unknown"
        let version = "\(assetVersion)-\(engineVersion)"
        try fm.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        let stage = stagingRoot.appendingPathComponent("\(UUID().uuidString).partial", isDirectory: true)
        defer { try? fm.removeItem(at: stage) }
        let contents = stage.appendingPathComponent("Contents", isDirectory: true)
        let executableDirectory = contents.appendingPathComponent("MacOS", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        let executableURL = executableDirectory.appendingPathComponent("S2ArmGameLauncher")
        let standaloneResources = resources.appendingPathComponent("S2ArmStandalone", isDirectory: true)
        let embeddedEngine = standaloneResources.appendingPathComponent("Engine", isDirectory: true)
        let embeddedLibrary = standaloneResources.appendingPathComponent("Library", isDirectory: true)
        try fm.createDirectory(at: executableDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: embeddedEngine.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: launcher, to: executableURL)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
        try fm.copyItem(at: cheatMenuLibrary, to: standaloneResources.appendingPathComponent("S2ArmCheatMenu.dylib"))

        progress(.init(stage: "封装独立应用", detail: "复制 S2Arm 运行环境…", fraction: 0.02, log: []))
        let engineProgressGate = SwitchBuildProgressGate()
        try copyTree(from: engineRoot, to: embeddedEngine) { copied, total, path in
            guard engineProgressGate.shouldReport(final: copied >= total) else { return }
            let copiedText = ByteCountFormatter.string(fromByteCount: copied, countStyle: .file)
            let totalText = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
            progress(.init(stage: "封装独立应用", detail: "S2Arm 引擎 · \(copiedText) / \(totalText) · \(path)", fraction: 0.02 + 0.18 * Double(copied) / Double(max(total, 1)), log: []))
        }

        try fm.createDirectory(at: embeddedLibrary, withIntermediateDirectories: true)
        let markerNames = [".s2arm-library.json", ".s2arm-layout.json"]
        for name in markerNames {
            let source = library.appendingPathComponent(name)
            if fm.fileExists(atPath: source.path) {
                try copyTree(from: source, to: embeddedLibrary.appendingPathComponent(name)) { _, _, _ in }
            }
        }
        let embeddedLocation = embeddedLibrary.appendingPathComponent(".s2arm-location.json")
        let layoutVersion = s2ArmLayoutVersion(in: library, hostRelativePath: hostRelativePath)
        let locationData = try JSONSerialization.data(withJSONObject: ["schema": 1, "id": resolvedLibraryID, "version": layoutVersion], options: [.sortedKeys])
        try locationData.write(to: embeddedLocation, options: .atomic)
        let catalogURL = library.appendingPathComponent("catalog.json")
        if let catalogData = try? Data(contentsOf: catalogURL),
           var catalog = try? JSONSerialization.jsonObject(with: catalogData) as? [String: Any],
           var games = catalog["games"] as? [[String: Any]],
           let gameIndex = games.firstIndex(where: { ($0["id"] as? String)?.uppercased() == gameID.uppercased() }) {
            var standaloneGame = games[gameIndex]
            if var packages = standaloneGame["packages"] as? [[String: Any]] {
                packages = packages.map { package in
                    var sanitized = package
                    sanitized.removeValue(forKey: "path")
                    return sanitized
                }
                standaloneGame["packages"] = packages
            }
            games = [standaloneGame]
            catalog["games"] = games
            try JSONSerialization.data(withJSONObject: catalog, options: [.sortedKeys]).write(to: embeddedLibrary.appendingPathComponent("catalog.json"), options: .atomic)
        } else {
            throw SwitchBuildError.commandFailed("S2Arm 游戏目录没有当前游戏记录，无法封装可独立运行的应用。")
        }
        let bundledGameDirectory = embeddedLibrary.appendingPathComponent("games", isDirectory: true).appendingPathComponent(gameDirectory.lastPathComponent, isDirectory: true)
        let gameProgressGate = SwitchBuildProgressGate()
        // Cheats are supplied by the launcher through the external Switch/cheat
        // directory.  The library entry may itself be an absolute symlink to that
        // directory; embedding it would make the app bundle impossible to sign.
        try copyTree(
            from: gameDirectory,
            to: bundledGameDirectory,
            excluding: ["build", "image/ios", "cheats", "image/mac/extract/s2x"]
        ) { copied, total, path in
            guard gameProgressGate.shouldReport(final: copied >= total) else { return }
            let copiedText = ByteCountFormatter.string(fromByteCount: copied, countStyle: .file)
            let totalText = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
            progress(.init(stage: "封装独立应用", detail: "游戏运行文件 · \(copiedText) / \(totalText) · \(path)", fraction: 0.20 + 0.75 * Double(copied) / Double(max(total, 1)), log: []))
        }
        try makeS2ArmRuntimePortable(in: bundledGameDirectory)
        let hostDestination = embeddedLibrary.appendingPathComponent(hostRelativePath, isDirectory: true)
        try copyTree(from: hostApp, to: hostDestination) { _, _, _ in }
        let versionURL = embeddedLibrary.appendingPathComponent("standalone-version")
        try Data((version + "\n").utf8).write(to: versionURL, options: .atomic)
        let manifestURL = standaloneResources.appendingPathComponent("standalone.json")
        let standaloneManifest: [String: Any] = [
            "gameID": gameID,
            "title": title,
            "folderName": gameDirectory.lastPathComponent,
            "libraryID": resolvedLibraryID,
            "assetVersion": version
        ]
        try JSONSerialization.data(withJSONObject: standaloneManifest, options: [.sortedKeys]).write(to: manifestURL, options: .atomic)

        let info: [String: Any] = [
            "CFBundleExecutable": "S2ArmGameLauncher",
            "CFBundleIdentifier": "com.phoenixicarus.gamecenter.switch.\(gameID.lowercased())",
            "CFBundleName": title,
            "CFBundleDisplayName": title,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": String(Int(Date.now.timeIntervalSince1970)),
            "LSMinimumSystemVersion": "14.0",
            "NSHighResolutionCapable": true
        ]
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"), options: .atomic)
        _ = try await installGameIcon(
            for: game,
            in: stage,
            temporaryDirectory: stagingRoot.appendingPathComponent("icons", isDirectory: true),
            progress: progress
        )
        progress(.init(stage: "封装独立应用", detail: "校验并签名游戏应用…", fraction: 0.98, log: []))
        let signingStatus = try await run(URL(fileURLWithPath: "/usr/bin/codesign"), arguments: ["--force", "--deep", "--sign", "-", stage.path]) { line in
            progress(.init(stage: "封装独立应用", detail: line, fraction: 0.99, log: []))
        }
        guard signingStatus == 0 else { throw SwitchBuildError.commandFailed("独立游戏应用签名失败。") }
        try publishBuiltApplication(from: stage, to: url, backupDirectory: stagingRoot.appendingPathComponent("previous", isDirectory: true))
        progress(.init(stage: "封装独立应用", detail: "独立应用已准备完成", fraction: 1, log: []))
        return url
    }

    static func s2ArmMacHostRelativePath(
        in library: URL,
        hostID: String,
        fileManager: FileManager = .default
    ) -> String? {
        guard !hostID.isEmpty else { return nil }
        // S2Arm layout v5+ stores Mac hosts under hosts/mac.noindex to prevent
        // Spotlight/Launchpad indexing; older libraries use hosts/mac.
        let candidates = [
            "hosts/mac.noindex/\(hostID)/S2ArmGame.app",
            "hosts/mac/\(hostID)/S2ArmGame.app"
        ]
        return candidates.first {
            fileManager.fileExists(atPath: library.appendingPathComponent($0, isDirectory: true).path)
        }
    }

    static func s2ArmLayoutVersion(in library: URL, hostRelativePath: String) -> Int {
        let layoutURL = library.appendingPathComponent(".s2arm-layout.json")
        if let data = try? Data(contentsOf: layoutURL),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let version = object["version"] as? Int {
            return version
        }
        return hostRelativePath.hasPrefix("hosts/mac.noindex/") ? 5 : 4
    }

    private static func makeS2ArmRuntimePortable(in gameDirectory: URL) throws {
        let fm = FileManager.default
        let image = gameDirectory.appendingPathComponent("image/mac", isDirectory: true)
        let extract = image.appendingPathComponent("extract", isDirectory: true)
        let mainsURL = extract.appendingPathComponent("mains.lst")
        let romsURL = extract.appendingPathComponent("roms.lst")
        let manifestURL = image.appendingPathComponent("manifest.json")
        let capabilitiesURL = image.appendingPathComponent("s2a_caps.tsv")
        guard fm.fileExists(atPath: manifestURL.path) else { return }

        // S2Arm keeps these shader-extraction source lists in the finished image
        // and its post-crash integrity check expects them. Their original content
        // points into the disposable build library, so replace it with equivalent
        // image-relative paths instead of deleting the files.
        let aocRoot = image.appendingPathComponent("aoc", isDirectory: true)
        let aocDirectories = ((try? fm.contentsOfDirectory(
            at: aocRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { lhs, rhs in
                lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
            }
        let romLines = ["../romfs"] + aocDirectories.map { "../aoc/\($0.lastPathComponent)" }
        let mainLines = Array(repeating: "../main", count: romLines.count)
        let mainsData = Data((mainLines.joined(separator: "\n") + "\n").utf8)
        let romsData = Data((romLines.joined(separator: "\n") + "\n").utf8)
        try fm.createDirectory(at: extract, withIntermediateDirectories: true)
        try mainsData.write(to: mainsURL, options: .atomic)
        try romsData.write(to: romsURL, options: .atomic)

        // Community-only 60 FPS patches have not been validated against every
        // executable-memory layout. Keep them available in the image, but make
        // standalone apps start at the game's native frame rate. The launcher
        // also persists this fallback automatically if an older app exits with
        // the corresponding bus-error status.
        var capabilitiesData: Data?
        if let original = try? String(contentsOf: capabilitiesURL, encoding: .utf8),
           original.contains("fps60\t1"), original.contains("只用社区补丁") {
            let safe = original.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
                guard line.hasPrefix("fps60\t1") else { return String(line) }
                return "fps60\t0\t# 独立应用默认使用游戏原生帧率；社区 60 帧补丁可在确认稳定后手动开启"
            }.joined(separator: "\n")
            let data = Data(safe.utf8)
            try data.write(to: capabilitiesURL, options: .atomic)
            capabilitiesData = data
        }

        let manifestData = try Data(contentsOf: manifestURL)
        guard var manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
              var files = manifest["files"] as? [String: Any] else {
            throw SwitchBuildError.commandFailed("S2Arm Mac 运行文件清单格式无效，无法封装独立应用。")
        }
        // `extract/s2x` is a shader-extraction work tree. The finished image uses
        // extract/pkg plus shaders/direct, and some S2Arm versions delete s2x
        // after snapshotting it. Do not ship it or keep stale integrity entries.
        files = files.filter { !$0.key.hasPrefix("extract/s2x/") }
        files["extract/mains.lst"] = [mainsData.count, ""]
        files["extract/roms.lst"] = [romsData.count, ""]
        if let capabilitiesData { files["s2a_caps.tsv"] = [capabilitiesData.count, ""] }
        manifest["files"] = files
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: manifestURL, options: .atomic)
    }

    @discardableResult
    private static func installGameIcon(
        for game: Game,
        in appURL: URL,
        temporaryDirectory: URL,
        progress: @escaping @Sendable (SwitchBuildProgress) -> Void
    ) async throws -> Bool {
        guard let image = gameIconImage(for: game) else { return false }
        let contents = appURL.appendingPathComponent("Contents", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let iconset = temporaryDirectory.appendingPathComponent("GameCenterIcon-\(UUID().uuidString).iconset", isDirectory: true)
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: iconset) }

        let representations: [(String, Int)] = [
            ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
            ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
            ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
            ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
            ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
        ]
        for (name, size) in representations {
            try writeIconRepresentation(image, size: size, to: iconset.appendingPathComponent(name))
        }

        let iconURL = resources.appendingPathComponent("GameIcon.icns")
        progress(.init(stage: "应用图标", detail: "正在生成高清游戏图标…", fraction: 0.96, log: []))
        let iconStatus = try await run(URL(fileURLWithPath: "/usr/bin/iconutil"), arguments: ["-c", "icns", iconset.path, "-o", iconURL.path]) { line in
            progress(.init(stage: "应用图标", detail: line, fraction: 0.97, log: []))
        }
        guard iconStatus == 0 else { throw SwitchBuildError.commandFailed("生成游戏应用图标失败。") }

        let plistURL = contents.appendingPathComponent("Info.plist")
        if let data = try? Data(contentsOf: plistURL),
           var info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            info["CFBundleIconFile"] = "GameIcon.icns"
            info.removeValue(forKey: "CFBundleIconName")
            let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try plist.write(to: plistURL, options: .atomic)
        }
        return true
    }

    private static func gameIconImage(for game: Game) -> NSImage? {
        if let bookmark = game.artworkBookmark {
            var stale = false
            let artworkURL = (try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale))
                ?? (try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale))
            if let artworkURL {
                let hasAccess = artworkURL.startAccessingSecurityScopedResource()
                let image = NSImage(contentsOf: artworkURL)
                if hasAccess { artworkURL.stopAccessingSecurityScopedResource() }
                if let image { return image }
            }
        }
        if let path = game.metadataArtworkPath, let image = NSImage(contentsOfFile: path) { return image }
        if let source = try? game.resolvedURL(), source.pathExtension.lowercased() == "app" {
            return NSWorkspace.shared.icon(forFile: source.path)
        }
        return nil
    }

    private static func writeIconRepresentation(_ source: NSImage, size: Int, to url: URL) throws {
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: size,
            pixelsHigh: size,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: representation) else {
            throw SwitchBuildError.commandFailed("创建应用图标位图失败。")
        }
        let sourceWidth = source.size.width
        let sourceHeight = source.size.height
        let side = min(sourceWidth, sourceHeight)
        let sourceRect = NSRect(x: (sourceWidth - side) / 2, y: (sourceHeight - side) / 2, width: side, height: side)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        source.draw(
            in: NSRect(x: 0, y: 0, width: size, height: size),
            from: sourceRect,
            operation: .copy,
            fraction: 1,
            respectFlipped: false,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        guard let data = representation.representation(using: .png, properties: [:]) else {
            throw SwitchBuildError.commandFailed("编码应用图标失败。")
        }
        try data.write(to: url, options: .atomic)
    }

    private static func copyTree(from source: URL, to destination: URL, excluding: Set<String> = [], progress: @escaping @Sendable (Int64, Int64, String) -> Void) throws {
        let fm = FileManager.default
        var entries: [(URL, URL, Bool, Bool, Int64)] = []
        if let values = try? source.resourceValues(forKeys: [.isDirectoryKey]), values.isDirectory != true {
            entries = [(source, destination, false, (try? source.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true, (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0)]
        } else {
            guard let enumerator = fm.enumerator(at: source, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey], options: [], errorHandler: { _, _ in false }) else {
                throw SwitchBuildError.commandFailed("无法读取 S2Arm 运行文件：\(source.path)")
            }
            for case let item as URL in enumerator {
                let relative = String(item.path.dropFirst(source.path.count + 1))
                if excluding.contains(relative) || excluding.contains(where: { relative.hasPrefix($0 + "/") }) {
                    enumerator.skipDescendants()
                    continue
                }
                let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
                entries.append((item, destination.appendingPathComponent(relative), values.isDirectory == true, values.isSymbolicLink == true, Int64(values.fileSize ?? 0)))
            }
        }
        let total = max(1, entries.reduce(Int64.zero) { $0 + ($1.2 ? 0 : $1.4) })
        let sourceIsDirectory = (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        let rootDir = sourceIsDirectory ? destination : destination.deletingLastPathComponent()
        try fm.createDirectory(at: rootDir, withIntermediateDirectories: true)
        var createdDirs: Set<String> = [rootDir.path]
        var copied: Int64 = 0
        for (sourceItem, target, isDirectory, isSymlink, size) in entries {
            if isSymlink {
                let parent = target.deletingLastPathComponent()
                if createdDirs.insert(parent.path).inserted {
                    try fm.createDirectory(at: parent, withIntermediateDirectories: true)
                }
                try fm.createSymbolicLink(atPath: target.path, withDestinationPath: try fm.destinationOfSymbolicLink(atPath: sourceItem.path))
            } else if isDirectory {
                if createdDirs.insert(target.path).inserted {
                    try fm.createDirectory(at: target, withIntermediateDirectories: true)
                }
            } else {
                let parent = target.deletingLastPathComponent()
                if createdDirs.insert(parent.path).inserted {
                    try fm.createDirectory(at: parent, withIntermediateDirectories: true)
                }
                if clonefile(sourceItem.path, target.path, 0) != 0 {
                    try fm.copyItem(at: sourceItem, to: target)
                }
                copied += size
            }
            progress(copied, total, sourceItem.lastPathComponent)
        }
    }

    private static func parseNXProgress(_ line: String) -> SwitchBuildProgress {
        guard let data = line.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .init(stage: "构建中", detail: line, fraction: nil, log: [line])
        }
        let eventType = event["ev"] as? String ?? event["type"] as? String ?? ""
        let stage = event["stage"] as? String ?? event["name"] as? String
            ?? event["code"] as? String ?? (eventType.isEmpty ? "构建中" : eventType)
        var detail = event["message"] as? String ?? event["msg"] as? String
            ?? event["summary"] as? String ?? event["step"] as? String ?? ""
        if let done = event["done"] as? NSNumber, let total = event["total"] as? NSNumber {
            let unit = event["unit"] as? String ?? ""
            let count = "\(done.intValue)/\(total.intValue)\(unit.isEmpty ? "" : " \(unit)")"
            detail = detail.isEmpty ? count : "\(detail) · \(count)"
        }
        if let seconds = event["eta"] as? NSNumber, seconds.doubleValue > 0 {
            let minutes = Int(seconds.doubleValue) / 60
            let remainder = Int(seconds.doubleValue) % 60
            detail += detail.isEmpty ? "" : " · "
            detail += "剩余 \(minutes):\(String(format: "%02d", remainder))"
        }
        let fraction = (event["overall"] as? NSNumber)?.doubleValue
            ?? (event["fraction"] as? NSNumber)?.doubleValue
            ?? event["progress"] as? Double
            ?? (event["frac"] as? NSNumber)?.doubleValue
            ?? progressFraction(done: event["done"] as? NSNumber, total: event["total"] as? NSNumber)
        guard ["stage", "step", "progress", "stage_end"].contains(eventType) else {
            return .init(stage: "构建中", detail: detail, fraction: nil, log: [line])
        }
        return .init(stage: stage, detail: detail, fraction: fraction.map { min(max($0, 0), 1) }, log: [line], phaseEvent: eventType,
                     stepFraction: fraction, stageNumber: event["k"] as? Int, stageCount: event["n"] as? Int,
                     stageSucceeded: event["ok"] as? Bool)
    }

    private static func parseS2ArmProgress(_ line: String) -> SwitchBuildProgress {
        guard let data = line.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .init(stage: "S2Arm 构建中", detail: line, fraction: nil, log: [line])
        }
        let stage = event["stage"] as? String ?? "S2Arm 构建中"
        let detail = event["message"] as? String ?? ""
        let done = event["done"] as? NSNumber
        let total = event["total"] as? NSNumber
        let reportedFraction = (event["overall"] as? NSNumber)?.doubleValue
            ?? (event["fraction"] as? NSNumber)?.doubleValue
            ?? progressFraction(done: done, total: total)
        let fraction = reportedFraction.map { min(max($0, 0), 1) }
        var description = detail
        if let done, let total, total.doubleValue > 0 {
            description = "\(detail)  ·  \(Int(done.doubleValue))/\(Int(total.doubleValue))"
        }
        let plan = (event["milestones"] as? [[String: Any]] ?? []).compactMap { item -> SwitchBuildPhase? in
            guard let id = item["id"] as? String, let title = item["label"] as? String else { return nil }
            return SwitchBuildPhase(id: id, title: title, purpose: item["purpose"] as? String ?? "",
                                    expected: item["expected"] as? Double, reused: item["reuse"] as? Bool ?? false)
        }
        return .init(stage: stage, detail: description, fraction: fraction, log: [line],
                     phaseEvent: event["type"] as? String, plan: plan, milestone: event["milestone"] as? String,
                     stepFraction: progressFraction(done: done, total: total) ?? event["fraction"] as? Double)
    }

    private static func progressFraction(done: NSNumber?, total: NSNumber?) -> Double? {
        guard let done, let total, total.doubleValue > 0 else { return nil }
        return min(max(done.doubleValue / total.doubleValue, 0), 1)
    }

    private static func nxNativeEnvironment(_ root: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let python = root.appendingPathComponent("python/bin").path
        let tools = root.appendingPathComponent("tools/bin").path
        let candidates = [tools, python, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        environment["PATH"] = candidates.joined(separator: ":")
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["PYTHONNOUSERSITE"] = "1"
        environment.removeValue(forKey: "PYTHONPATH")
        environment.removeValue(forKey: "PYTHONHOME")
        environment["SPIRV_CROSS"] = root.appendingPathComponent("engine/dm/gfx/tools/spirv_cross_bin/spirv-cross").path
        return environment
    }

    private static func run(
        _ executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> Int32 {
        let result = try await capture(
            executable,
            arguments: arguments,
            environment: environment,
            trackAsActive: true,
            maxOutputBytes: 512 * 1024,
            progress: progress
        )
        return result.status
    }

    private static func capture(
        _ executable: URL,
        arguments: [String],
        environment processEnvironment: [String: String]? = nil,
        trackAsActive: Bool = false,
        maxOutputBytes: Int? = nil,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = executable.deletingLastPathComponent()
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        if let processEnvironment { environment.merge(processEnvironment) { _, new in new } }
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        var allOutput = Data()
        var pending = Data()
        let queue = DispatchQueue(label: "GameCenter.SwitchBuildProcessOutput")
        let handle = pipe.fileHandleForReading

        func emitLines(from buffer: inout Data, flushRemainder: Bool) {
            while let newline = buffer.firstIndex(of: 10) {
                let lineData = buffer.prefix(upTo: newline)
                buffer.removeSubrange(...newline)
                let line = String(decoding: lineData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if !line.isEmpty { progress?(line) }
            }
            if flushRemainder && !buffer.isEmpty {
                let line = String(decoding: buffer, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                buffer.removeAll(keepingCapacity: false)
                if !line.isEmpty { progress?(line) }
            }
        }

        func appendOutput(_ chunk: Data) {
            guard !chunk.isEmpty else { return }
            allOutput.append(chunk)
            if let limit = maxOutputBytes, allOutput.count > limit * 2 {
                allOutput.removeFirst(allOutput.count - limit)
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            handle.readabilityHandler = { fileHandle in
                let data = fileHandle.availableData
                guard !data.isEmpty else {
                    fileHandle.readabilityHandler = nil
                    return
                }
                queue.async {
                    appendOutput(data)
                    if progress != nil {
                        pending.append(data)
                        emitLines(from: &pending, flushRemainder: false)
                    }
                }
            }
            process.terminationHandler = { process in
                handle.readabilityHandler = nil
                if trackAsActive {
                    processLock.lock()
                    if activeProcess === process { activeProcess = nil }
                    processLock.unlock()
                }
                queue.async {
                    let rest = handle.readDataToEndOfFile()
                    try? handle.close()
                    appendOutput(rest)
                    if progress != nil {
                        pending.append(rest)
                        emitLines(from: &pending, flushRemainder: true)
                    }
                    continuation.resume(returning: (process.terminationStatus, String(decoding: allOutput, as: UTF8.self)))
                }
            }
            do {
                if trackAsActive {
                    processLock.lock()
                    activeProcess = process
                    processLock.unlock()
                }
                try process.run()
            } catch {
                handle.readabilityHandler = nil
                try? handle.close()
                if trackAsActive {
                    processLock.lock()
                    if activeProcess === process { activeProcess = nil }
                    processLock.unlock()
                }
                continuation.resume(throwing: error)
            }
        }
    }

    private static func safeName(_ title: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\0")
        let name = title.components(separatedBy: invalid).filter { !$0.isEmpty }.joined(separator: "-")
        return name.isEmpty ? "Switch Game" : name
    }

}

private final class OutputLines: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ line: String) { lock.lock(); storage.append(line); lock.unlock() }
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return storage }
}
