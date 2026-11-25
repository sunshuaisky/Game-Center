import AppKit
import SwiftUI

enum AppleAccountSigning {
    static let preference = "GameCenter.UseAppleAccountSigning"
    static func executable() throws -> URL {
        let root = try MobileAppBuilder.script("apple-id-sign.py").deletingLastPathComponent().deletingLastPathComponent()
        let path = "ThirdParty/Impactor/plumesign-macos-universal"
        for directory in ["AppleSigning", "Vendor/AppleSigning"] {
            let tool = root.appendingPathComponent(directory).appendingPathComponent(path)
            if FileManager.default.isExecutableFile(atPath: tool.path) { return tool }
        }
        throw SwitchBuildError.missingTool("应用缺少 Apple ID 签名工具，请重新安装 Game Center。")
    }
    static let home = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Game Center/AppleSigning")
    struct Account { let email: String; let team: String }

    static var account: Account? {
        guard let data = try? Data(contentsOf: home.appendingPathComponent("PlumeImpactor/accounts.json")),
              let store = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let email = store["selected_account"] as? String,
              let entries = store["accounts"] as? [String: [String: Any]],
              let team = entries[email]?["team_id"] as? String,
              team.range(of: "^[A-Za-z0-9]{10}$", options: .regularExpression) != nil else { return nil }
        return Account(email: email, team: team)
    }

    static func selected() throws -> Account? {
        guard UserDefaults.standard.bool(forKey: preference) else { return nil }
        guard let account else { throw SwitchBuildError.commandFailed("请在设置中重新登录用于签名的 Apple ID。") }
        return account
    }

    static func helper(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-I", "-B", try MobileAppBuilder.script("apple-id-sign.py").path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let message = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw SwitchBuildError.commandFailed(message) }
        return message
    }

    static func gameEnvironment(_ input: [String: String] = ProcessInfo.processInfo.environment) throws -> [String: String] {
        guard let account = try selected() else { return try MobileSigning.gameEnvironment(input) }
        let targets = MobileSigning.installedTargets().filter { $0.team == account.team }
        let bundle = try MobileSigning.bundleID(team: account.team, targets: targets, explicit: nil)
        let receipts = targets.filter { $0.bundle == bundle }
        let allowed = try MobileSigning.authorizedCertificates(receipts)
        // AltStore can use a different key from Plume even for the same team.
        if let local = try? MobileSigning.gameEnvironment(input, targets: receipts),
           local["GAME_CENTER_IOS_TEAM_ID"] == account.team, local["GAME_CENTER_IOS_BUNDLE_ID"] == bundle,
           let identity = local["GAME_CENTER_IOS_SIGN_IDENTITY"], allowed.contains(identity) { return local }
        let fingerprint: String
        do { fingerprint = try helper(["fingerprint", account.team]) }
        catch {
            throw SwitchBuildError.commandFailed("无法取得与手机签名匹配的私钥。若使用 AltStore 安装，请在 Mac 上使用 AltStore 签名时的证书及私钥。\n" + error.localizedDescription)
        }
        guard allowed.contains(fingerprint) else {
            throw SwitchBuildError.commandFailed("手机 App 的描述文件不接受这个 Apple ID 当前使用的证书。请在 Mac 钥匙串中导入安装时的开发证书及私钥，或以同一签名安装基础 IPA，再连接手机重新识别。")
        }
        var result = input
        result["GAME_CENTER_IOS_TEAM_ID"] = account.team
        result["GAME_CENTER_IOS_BUNDLE_ID"] = bundle
        result["GAME_CENTER_IOS_SIGN_IDENTITY"] = fingerprint
        result["GAME_CENTER_PLUME_SIGN"] = "1"
        return result
    }

    static func appBundleID(_ account: Account) throws -> String {
        let targets = MobileSigning.installedTargets().filter { $0.team == account.team }
        if targets.isEmpty { return MobileSigning.defaultBundleID + "." + account.team.lowercased() }
        return try MobileSigning.bundleID(team: account.team, targets: targets, explicit: nil)
    }
}

@MainActor
private final class SigningLogin: ObservableObject {
    @Published var busy = false
    @Published var needsCode = false
    @Published var message = ""
    @Published var current = AppleAccountSigning.account
    private var process: Process?
    private var input: FileHandle?
    private var timeout: Task<Void, Never>?

    func start(email: String, password: String, logout: Bool = false) {
        guard !busy else { return }
        let child = Process(), output = Pipe(), stdin = Pipe()
        do {
            try FileManager.default.createDirectory(at: AppleAccountSigning.home, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            child.executableURL = try AppleAccountSigning.executable()
            child.arguments = logout ? ["account", "logout"] : ["account", "login", "-u", email]
            child.environment = ProcessInfo.processInfo.environment.merging(["XDG_CONFIG_HOME": AppleAccountSigning.home.path,
                "RUST_LOG": "info"]) { _, new in new }
            child.standardInput = stdin
            child.standardOutput = output
            child.standardError = output
            try child.run()
            busy = true
            process = child
            input = stdin.fileHandleForWriting
            message = logout ? "正在退出账号…" : "正在登录 Apple 开发者服务…"
            if logout { try input?.close() } else { try input?.write(contentsOf: Data((password + "\n").utf8)) }
            timeout = Task {
                try? await Task.sleep(for: .seconds(600))
                guard !Task.isCancelled, process === child else { return }
                cancel()
                message = "操作超时，请重新登录。"
            }
            Task {
                // Only recognise prompts. Raw authentication output never reaches the UI or logs.
                var text = ""
                var reason: String?
                func recognizeFailure(_ line: String) {
                    let lower = line.lowercased()
                    if lower.contains("-21669") || lower.contains("incorrect verification code") {
                        reason = "Apple 拒绝了验证码，请使用最近收到的六位数验证码。"
                    } else if lower.contains("-20101") || lower.contains("entered incorrectly") {
                        reason = "Apple 拒绝了账号或密码，请核对后重新登录。"
                    } else if lower.contains("-80046") {
                        reason = "Apple 未接受本次设备验证，请在受信任设备上确认账号状态。"
                    } else if lower.contains("anisette error") {
                        reason = "登录用的设备验证服务暂时不可用，请稍后重试。"
                    } else if lower.contains("http request error 5") {
                        reason = "Apple 登录服务暂时拒绝了请求，请稍后重试。"
                    } else if lower.contains("dns error") || lower.contains("error sending request") {
                        reason = "无法连接登录服务，请检查 Mac 的网络连接。"
                    }
                }
                do {
                    for try await byte in output.fileHandleForReading.bytes {
                        guard process === child else { break }
                        if byte == 10 { recognizeFailure(text); text = ""; continue }
                        text.append(Character(UnicodeScalar(byte)))
                        text = String(text.suffix(600))
                        if text.localizedCaseInsensitiveContains("enter the code sent") || text.localizedCaseInsensitiveContains("enter 2fa code") {
                            needsCode = true
                            message = "请输入 Apple 发到受信任设备或手机的六位验证码。"
                            text = ""
                        }
                    }
                } catch {}
                guard process === child else { return }
                recognizeFailure(text)
                child.waitUntilExit()
                let ok = child.terminationStatus == 0
                finish()
                current = AppleAccountSigning.account
                if ok && (logout || current?.email.caseInsensitiveCompare(email) == .orderedSame) {
                    UserDefaults.standard.set(!logout, forKey: AppleAccountSigning.preference)
                    message = logout ? "已退出 Apple ID。" : "已启用 Apple ID 签名。"
                } else if ok {
                    message = "账号验证已完成，但签名工具还没有选定可用的开发团队。"
                } else {
                    message = reason ?? "签名工具未完成登录（退出码 \(child.terminationStatus)）。"
                }
            }
        } catch {
            if child.isRunning { child.terminate() }
            finish()
            message = "无法启动签名工具，请检查 Game Center 是否安装完整后重试。"
        }
    }

    func verify(_ code: String) {
        guard needsCode, code.range(of: "^[0-9]{6}$", options: .regularExpression) != nil else { return }
        do {
            try input?.write(contentsOf: Data((code + "\n").utf8))
            needsCode = false
            message = "正在验证…"
        } catch { cancel(); message = "登录会话已结束，请重新登录。" }
    }

    func cancel() {
        if let process, process.isRunning { process.terminate() }
        finish()
    }

    private func finish() {
        timeout?.cancel()
        timeout = nil
        try? input?.close()
        input = nil
        process = nil
        busy = false
        needsCode = false
    }
}

struct AppleSigningSettings: View {
    @StateObject private var login = SigningLogin()
    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    @AppStorage(AppleAccountSigning.preference) private var enabled = false
    @Environment(\.dismiss) private var dismiss

    private enum Field { case email, password, code }
    @FocusState private var focus: Field?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "person.badge.key.fill")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .frame(width: 44, height: 44)
                    .background(GameCenterColors.surfaceElevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(GameCenterColors.border, lineWidth: 1))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Apple ID 与 iOS 签名").font(.system(size: 18, weight: .semibold))
                    Text("签署基础 IPA、S2Arm 和 NXNative 游戏包")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                SheetCloseButton {
                    login.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }

            VStack(alignment: .leading, spacing: 0) {
                if let account = login.current {
                    HStack(spacing: 12) {
                        Image(systemName: "person.crop.circle").font(.title).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(account.email).font(.headline).textSelection(.enabled)
                            Text("开发团队 " + account.team)
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                    .padding(14)
                    Divider().opacity(0.4)
                    Toggle("使用此账号签名", isOn: $enabled)
                        .toggleStyle(.switch).disabled(login.busy).padding(14)
                } else if login.needsCode {
                    VStack(alignment: .leading, spacing: 9) {
                        Label("双重认证", systemImage: "lock.shield").font(.headline)
                        SecureField("六位验证码", text: $code)
                            .textContentType(.oneTimeCode).focused($focus, equals: .code)
                            .font(.title3.monospacedDigit()).controlSize(.large)
                    }
                    .padding(14)
                } else {
                    fieldRow("Apple ID", icon: "at") {
                        TextField("邮箱地址", text: $email)
                            .textContentType(.username).focused($focus, equals: .email)
                            .onSubmit { focus = .password }
                    }
                    Divider().opacity(0.4).padding(.leading, 42)
                    fieldRow("密码", icon: "lock") {
                        SecureField("Apple ID 密码", text: $password)
                            .textContentType(.password).focused($focus, equals: .password)
                            .onSubmit { signIn() }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GameCenterColors.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(GameCenterColors.border) }

            if !login.message.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if login.busy && !login.needsCode { ProgressView().controlSize(.mini) }
                    Text(login.message).textSelection(.enabled)
                }
                .font(.system(size: 12))
            } else if login.current == nil {
                Label("登录会话和签名密钥保存在这台 Mac 上。", systemImage: "lock.fill")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }

            Divider().opacity(0.4)
            HStack(spacing: 10) {
                if let account = login.current {
                    Button("退出账号", role: .destructive) {
                        login.start(email: account.email, password: "", logout: true)
                    }
                    .buttonStyle(TactileActionButtonStyle(appearance: .destructive, minHeight: 36, fontSize: 12))
                    .disabled(login.busy)
                    Spacer()
                }
                Button(login.busy || login.current == nil ? "取消" : "完成") {
                    login.cancel()
                    dismiss()
                }
                .buttonStyle(TactileActionButtonStyle(appearance: login.current == nil ? .secondary : .primary, minHeight: 36, fontSize: 12))
                if login.current == nil {
                    Spacer()
                    if login.needsCode {
                        Button("验证并继续") { login.verify(code); code = "" }
                            .buttonStyle(TactileActionButtonStyle(appearance: .primary, minHeight: 36, fontSize: 12))
                            .disabled(code.range(of: "^[0-9]{6}$", options: .regularExpression) == nil)
                            .keyboardShortcut(.defaultAction)
                    } else {
                        Button("登录并启用签名", action: signIn)
                            .buttonStyle(TactileActionButtonStyle(appearance: .primary, minHeight: 36, fontSize: 12))
                            .disabled(!canSignIn)
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 450)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.dark)
        .overlay {
            OutsideClickDismissMonitor {
                if !login.busy { dismiss() }
            }
            .allowsHitTesting(false)
        }
        .onAppear { if login.current == nil { focus = .email } }
        .onChange(of: login.needsCode) { if login.needsCode { focus = .code } }
        .onDisappear { login.cancel(); password = ""; code = "" }
    }

    private var canSignIn: Bool {
        !login.busy && !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty
    }

    private func signIn() {
        guard canSignIn else { return }
        login.start(email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
        password = ""
    }

    private func fieldRow<Content: View>(_ title: LocalizedStringKey, icon: String,
                                         @ViewBuilder input: () -> Content) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 18).accessibilityHidden(true)
            Text(title).font(.callout.weight(.medium)).frame(width: 62, alignment: .leading)
            input().textFieldStyle(.plain).disabled(login.busy)
        }
        .padding(.horizontal, 14).frame(minHeight: 44)
    }
}
