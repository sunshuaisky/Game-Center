import Foundation

enum SwitchBuildError: LocalizedError {
    case commandFailed(String)
    var errorDescription: String? { if case let .commandFailed(message) = self { return message }; return nil }
}
@main struct SigningTests {
    static func main() throws {
        let valid = Date.now.addingTimeInterval(3600)
        let identities = [MobileSigning.Identity(fingerprint: "old", team: "TEAM_A", expires: valid),
                          .init(fingerprint: "new", team: "TEAM_A", expires: valid.addingTimeInterval(3600)),
                          .init(fingerprint: "other", team: "TEAM_B", expires: valid),
                          .init(fingerprint: "expired", team: "TEAM_C", expires: .distantPast)]
        let selected = try MobileSigning.select(identities, teams: ["TEAM_A"])
        precondition(selected.fingerprint == "new")
        do { _ = try MobileSigning.select(identities, teams: []); preconditionFailure("Ambiguous teams must fail") } catch {}
        do { _ = try MobileSigning.select(identities, teams: ["TEAM_C"]); preconditionFailure("Expired identity must fail") } catch {}
        do { _ = try MobileSigning.select(identities, teams: ["TEAM_D"]); preconditionFailure("Mismatched team must fail") } catch {}
        let target = MobileSigning.Target(team: "TEAM_A", bundle: "com.example.GameCenter.TEAM_A")
        let installedID = try MobileSigning.bundleID(team: "TEAM_A", targets: [target], explicit: nil)
        precondition(installedID == "com.example.GameCenter.TEAM_A")
        do { _ = try MobileSigning.bundleID(team: "TEAM_A", targets: [target], explicit: "com.example.GameCenter"); preconditionFailure("Unsuffixed identifier must be rejected") } catch {}
        do { _ = try MobileSigning.bundleID(team: "TEAM_A", targets: [], explicit: nil); preconditionFailure("Never guess an unobserved installed identifier") } catch {}
        let automatic = try MobileSigning.gameEnvironment([:])
        precondition(automatic["GAME_CENTER_IOS_BUNDLE_ID"] != MobileSigning.defaultBundleID)
        precondition(automatic["GAME_CENTER_IOS_SIGN_IDENTITY"] != "-")
        print("PASS: automatic keychain selection, actual certificate OU team = \(automatic["GAME_CENTER_IOS_TEAM_ID"] ?? "missing"), account matching, newest valid certificate, ambiguity/expiry/mismatch rejection")
    }
}
