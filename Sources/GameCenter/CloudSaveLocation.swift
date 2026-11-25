import Foundation

enum CloudSaveLocation {
    static let folderName = "Game Center存档"
    struct Access: Sendable {
        let folder: URL
        let scope: URL?
    }
    enum Failure: LocalizedError {
        case authorizationRequired
        case unavailable
        case staleAuthorization
        var errorDescription: String? {
            switch self {
            case .authorizationRequired: "当前侧载签名没有自动访问 iCloud 的权限。请首次授权访问 iCloud Drive；以后会记住授权并自动使用“Game Center存档”。"
            case .unavailable: "iCloud Drive 尚不可用，请在系统设置登录 iCloud 并开启 iCloud Drive 后重试。"
            case .staleAuthorization: "iCloud 访问授权已失效，请重新授权。"
            }
        }
    }

    static func resolve(bookmark: Data) throws -> Access {
        let fm = FileManager.default
        #if os(macOS)
        guard fm.ubiquityIdentityToken != nil else { throw Failure.unavailable }
        // Game Center's desktop app is not sandboxed. Use the existing system
        // iCloud Drive location; never manufacture a local substitute for it.
        let drive = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        guard fm.fileExists(atPath: drive.path) else { throw Failure.unavailable }
        return Access(folder: drive.appendingPathComponent(folderName), scope: nil)
        #else
        if !bookmark.isEmpty {
            var stale = false
            let scope = try URL(resolvingBookmarkData: bookmark, relativeTo: nil, bookmarkDataIsStale: &stale)
            guard !stale else { throw Failure.staleAuthorization }
            let isNamedFolder = [folderName, "Game Center 存档"].contains(scope.lastPathComponent)
            return Access(folder: isNamedFolder ? scope : scope.appendingPathComponent(folderName), scope: scope)
        }
        // An app signed with a valid iCloud Documents container can use it with
        // no picker. Ordinary AltStore/SideStore profiles usually lack this.
        if let container = fm.url(forUbiquityContainerIdentifier: nil) {
            return Access(folder: container.appendingPathComponent("Documents/" + folderName), scope: nil)
        }
        throw Failure.authorizationRequired
        #endif
    }
}
