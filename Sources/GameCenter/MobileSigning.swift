import CryptoKit
import Foundation

enum MobileSigning {
    static let defaultBundleID = "com.phoenixicarus.gamecenter.ios"

    static func gameEnvironment(_ input: [String: String] = ProcessInfo.processInfo.environment, targets observedTargets: [Target]? = nil) throws -> [String: String] {
        var result = try environment(input)
        let targets = observedTargets ?? installedTargets()
        if let identity = result["GAME_CENTER_IOS_SIGN_IDENTITY"], identity != "-" {
            guard let team = result["GAME_CENTER_IOS_TEAM_ID"], !team.isEmpty else {
                throw SwitchBuildError.commandFailed("自动签名缺少开发团队信息，请检查本机侧载账号配置。")
            }
            result["GAME_CENTER_IOS_BUNDLE_ID"] = try bundleID(team: team, targets: targets, explicit: result["GAME_CENTER_IOS_BUNDLE_ID"])
            let receipts = targets.filter { $0.team == team && $0.bundle == result["GAME_CENTER_IOS_BUNDLE_ID"] }
            guard try authorizedCertificates(receipts).contains(identity.uppercased()) else {
                throw SwitchBuildError.commandFailed("指定的签名证书与手机描述文件不匹配。请检查本机证书及私钥。")
            }
            result["GAME_CENTER_IOS_SIGN_IDENTITY"] = identity.uppercased()
            return result
        }
        let identities = String(decoding: try command("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"]), as: UTF8.self)
        let fingerprints = Set(identities.split(whereSeparator: \.isWhitespace).map(String.init).filter {
            $0.count == 40 && $0.allSatisfy(\.isHexDigit)
        })
        let certificates = String(decoding: try command("/usr/bin/security", ["find-certificate", "-a", "-p"]), as: UTF8.self)
        let expiryFormatter = DateFormatter()
        expiryFormatter.locale = Locale(identifier: "en_US_POSIX")
        expiryFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        expiryFormatter.dateFormat = "MMM d HH:mm:ss yyyy zzz"
        var candidates: [Identity] = []
        for part in certificates.components(separatedBy: "-----END CERTIFICATE-----") {
            guard let start = part.range(of: "-----BEGIN CERTIFICATE-----") else { continue }
            let pem = String(part[start.lowerBound...]) + "-----END CERTIFICATE-----\n"
            let base64 = pem.components(separatedBy: .newlines).filter { !$0.hasPrefix("-----") }.joined()
            guard let data = Data(base64Encoded: base64) else { continue }
            let fingerprint = Insecure.SHA1.hash(data: data).map { String(format: "%02X", $0) }.joined()
            guard fingerprints.contains(fingerprint) else { continue }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pem")
            try Data(pem.utf8).write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            let subject = String(decoding: try command("/usr/bin/openssl", ["x509", "-in", file.path, "-noout", "-subject", "-nameopt", "RFC2253", "-enddate"]), as: UTF8.self)
            // Developer ID / Mac-only certificates cannot authorize an iOS game.
            guard subject.contains("CN=Apple Development:") || subject.contains("CN=iPhone Developer:") else { continue }
            guard let team = subject.components(separatedBy: ",").map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }).first(where: { $0.hasPrefix("OU=") }).map({ String($0.dropFirst(3)) }), !team.isEmpty else { continue }
            let expiry = subject.components(separatedBy: "notAfter=").last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            candidates.append(.init(fingerprint: fingerprint, team: team, expires: expiryFormatter.date(from: expiry) ?? .distantPast))
        }
        let authorized = try candidates.filter { identity in
            let matching = targets.filter { $0.team == identity.team }
            guard !matching.isEmpty else { return false }
            let bundle = try bundleID(team: identity.team, targets: matching, explicit: result["GAME_CENTER_IOS_BUNDLE_ID"])
            return try authorizedCertificates(matching.filter { $0.bundle == bundle }).contains(identity.fingerprint)
        }
        let identity = try select(authorized, teams: Set(targets.map(\.team)))
        result["GAME_CENTER_IOS_SIGN_IDENTITY"] = identity.fingerprint
        result["GAME_CENTER_IOS_TEAM_ID"] = identity.team
        result["GAME_CENTER_IOS_BUNDLE_ID"] = try bundleID(team: identity.team, targets: targets, explicit: result["GAME_CENTER_IOS_BUNDLE_ID"])
        return result
    }

    struct Identity {
        let fingerprint: String
        let team: String
        let expires: Date
    }
    static func select(_ identities: [Identity], teams: Set<String>) throws -> Identity {
        let valid = identities.filter { $0.expires > .now }
        guard !valid.isEmpty else {
            throw SwitchBuildError.commandFailed("本机没有可用的 iOS 开发证书及私钥，无法生成可在手机运行的游戏。请先在本机完成侧载工具的账号配置；无需选择描述文件。")
        }
        let matching = teams.isEmpty ? valid : valid.filter { teams.contains($0.team) }
        guard !matching.isEmpty else {
            throw SwitchBuildError.commandFailed("手机上 Game Center 的账号与本机开发证书不一致。请让侧载工具使用本机已有证书的 Apple 账号，再重新构建游戏。无需选择描述文件。")
        }
        guard Set(matching.map(\.team)).count == 1 else {
            throw SwitchBuildError.commandFailed("检测到多个开发账号，暂时无法确定目标手机。请连接安装了 Game Center 的 iPhone，系统会自动识别签名账号。")
        }
        return matching.sorted { $0.expires == $1.expires ? $0.fingerprint < $1.fingerprint : $0.expires > $1.expires }[0]
    }

    struct Target: Codable, Equatable {
        let team: String
        let bundle: String
        var certificates: [String]? = nil
        var profileExpiry: Date? = nil
    }
    static func authorizedCertificates(_ targets: [Target]) throws -> Set<String> {
        guard let first = targets.first, targets.allSatisfy({ !($0.certificates ?? []).isEmpty }) else {
            throw SwitchBuildError.commandFailed("请打开手机上的 Game Center，连接并信任 Mac 后重新检测，以读取签名授权。")
        }
        guard targets.allSatisfy({ ($0.profileExpiry ?? .distantFuture) > .now }) else {
            throw SwitchBuildError.commandFailed("手机上的 Game Center 描述文件已过期。请续签后打开应用，再连接 Mac 重新检测。")
        }
        return targets.reduce(Set(first.certificates ?? [])) { $0.intersection($1.certificates ?? []) }
    }

    static func verifyLeafCertificate(_ code: URL, fingerprint: String) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let prefix = folder.appendingPathComponent("cert").path
        _ = try command("/usr/bin/codesign", ["-d", "--extract-certificates=" + prefix, code.path])
        let der = try Data(contentsOf: URL(fileURLWithPath: prefix + "0"))
        let actual = Insecure.SHA1.hash(data: der).map { String(format: "%02X", $0) }.joined()
        guard actual == fingerprint.uppercased() else {
            throw SwitchBuildError.commandFailed("游戏成品的签名证书与手机授权证书不匹配，请重新检查签名。")
        }
    }

    static func bundleID(team: String, targets: [Target], explicit: String?) throws -> String {
        let bundles = Set(targets.filter { $0.team == team }.map(\.bundle))
        if let explicit {
            guard bundles.isEmpty || bundles.contains(explicit) else {
                throw SwitchBuildError.commandFailed("配置的签名标识与手机上实际安装的 Game Center 不一致。请移除旧的 GAME_CENTER_IOS_BUNDLE_ID 配置后重新构建。")
            }
            return explicit
        }
        guard bundles.count == 1, let bundle = bundles.first else {
            throw SwitchBuildError.commandFailed(bundles.isEmpty
                ? "尚未识别手机上 Game Center 的完整签名标识。请先安装 Game Center，再连接这台 Mac 并信任设备；只需识别一次，之后可离线构建。无需输入 Apple ID 密码。"
                : "同一账号有多份 Game Center 安装，无法唯一确定签名标识。请仅连接本次要使用的手机后重试。")
        }
        return bundle
    }
    static func refreshInstalledTarget() { _ = installedTargets() }

    // Team equality alone isn't enough: external code registration also needs
    // the actual installed signing identifier, including AltStore's suffix.
    static func installedTargets() -> [Target] {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func json(_ arguments: [String], name: String) -> [String: Any]? {
            let file = folder.appendingPathComponent(name)
            guard (try? command("/usr/bin/xcrun", ["devicectl"] + arguments + ["--json-output", file.path, "--timeout", "5"])) != nil,
                  let data = try? Data(contentsOf: file) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["result"] as? [String: Any]
        }
        let devices = json(["list", "devices"], name: "devices.json")?["devices"] as? [[String: Any]] ?? []
        var targets: [Target] = []
        for device in devices {
            let properties = device["properties"] as? [String: Any] ?? [:]
            let hardware = properties["hardware"] as? [String: Any] ?? device["hardwareProperties"] as? [String: Any] ?? [:]
            let connection = properties["connection"] as? [String: Any] ?? device["connectionProperties"] as? [String: Any] ?? [:]
            // A paired phone may be listed as disconnected until the first
            // device-info request opens its tunnel. Do not skip that phone.
            guard hardware["reality"] as? String == "physical", connection["pairingState"] as? String == "paired",
                  let identifier = device["identifier"] as? String else { continue }
            let apps = json(["device", "info", "apps", "--device", identifier], name: identifier + ".json")?["apps"] as? [[String: Any]] ?? []
            for app in apps {
                guard let bundle = app["bundleIdentifier"] as? String,
                      bundle == defaultBundleID || bundle.hasPrefix(defaultBundleID + ".") else { continue }
                let receiptFile = folder.appendingPathComponent("receipt-" + identifier + ".json")
                let copied = try? command("/usr/bin/xcrun", ["devicectl", "device", "copy", "from", "--device", identifier,
                    "--domain-type", "appDataContainer", "--domain-identifier", bundle,
                    "--source", "Documents/Export/GameCenter-signing.json", "--destination", receiptFile.path, "--timeout", "5"])
                let receipt = copied.flatMap { _ in try? Data(contentsOf: receiptFile) }
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                let verifiedReceipt = receipt?["bundleIdentifier"] as? String == bundle ? receipt : nil
                let suffix = bundle.split(separator: ".").last.map(String.init) ?? ""
                let team = verifiedReceipt?["teamIdentifier"] as? String ?? app["teamIdentifier"] as? String ??
                    (suffix.count == 10 && suffix.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber) } ? suffix : "")
                if !team.isEmpty {
                    let target = Target(team: team, bundle: bundle, certificates: verifiedReceipt?["certificateFingerprints"] as? [String],
                                        profileExpiry: (verifiedReceipt?["profileExpiry"] as? Double).map(Date.init(timeIntervalSince1970:)))
                    if !targets.contains(target) { targets.append(target) }
                }
            }
        }
        if !targets.isEmpty, let encoded = try? JSONEncoder().encode(targets) {
            UserDefaults.standard.set(encoded, forKey: "mobileObservedSigningTargets")
            return targets
        }
        guard let data = UserDefaults.standard.data(forKey: "mobileObservedSigningTargets") else { return [] }
        return (try? JSONDecoder().decode([Target].self, from: data)) ?? []
    }

    static func environment(_ input: [String: String] = ProcessInfo.processInfo.environment) throws -> [String: String] {
        var environment = input
        guard let path = environment["GAME_CENTER_IOS_PROFILE"] else {
            return environment
        }
        let profile = try decodedProfile(path)
        guard let expires = profile["ExpirationDate"] as? Date, expires > .now,
              let entitlements = profile["Entitlements"] as? [String: Any],
              let appID = entitlements["application-identifier"] as? String,
              let dot = appID.firstIndex(of: "."),
              let team = (profile["TeamIdentifier"] as? [String])?.first,
              let certificates = profile["DeveloperCertificates"] as? [Data] else {
            throw SwitchBuildError.commandFailed("iOS 描述文件无效或已过期。")
        }
        let configuredID = String(appID[appID.index(after: dot)...])
        let bundleID = environment["GAME_CENTER_IOS_BUNDLE_ID"] ?? (configuredID == "*" ? defaultBundleID : configuredID)
        guard configuredID == bundleID || configuredID == "*" else {
            throw SwitchBuildError.commandFailed("描述文件与 iOS Bundle ID 不匹配。")
        }
        let identities = try command("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"])
        let installedIdentities = Set(String(decoding: identities, as: UTF8.self).split(whereSeparator: \.isWhitespace))
        let fingerprints = certificates.map { Insecure.SHA1.hash(data: $0).map { String(format: "%02X", $0) }.joined() }
        if environment["GAME_CENTER_IOS_SIGN_IDENTITY"] == nil {
            guard let identity = fingerprints.first(where: { installedIdentities.contains(Substring($0)) }) else {
                throw SwitchBuildError.commandFailed("钥匙串中没有此描述文件对应的签名身份。")
            }
            environment["GAME_CENTER_IOS_SIGN_IDENTITY"] = identity
        }
        environment["GAME_CENTER_IOS_TEAM_ID"] = team
        environment["GAME_CENTER_IOS_BUNDLE_ID"] = bundleID
        environment["GAME_CENTER_IOS_PROFILE"] = path
        return environment
    }

    private static func decodedProfile(_ path: String) throws -> [String: Any] {
        let data = try command("/usr/bin/security", ["cms", "-D", "-i", path])
        guard let result = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw SwitchBuildError.commandFailed("无法读取 iOS 描述文件。")
        }
        return result
    }

    private static func command(_ path: String, _ args: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw SwitchBuildError.commandFailed("无法读取描述文件或钥匙串签名身份。")
        }
        return data
    }
}
