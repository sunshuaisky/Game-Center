import Foundation

enum MetadataRefreshPolicy {
    static func needsRefresh(status: String?, savedLanguage: String?, language: String,
                             hasSynopsis: Bool, hasArtwork: Bool, hasBackdrop: Bool,
                             updated: Date?, now: Date = .now) -> Bool {
        if status == nil || status == "searching" || savedLanguage != language { return true }
        if status == "found", hasSynopsis, hasArtwork, hasBackdrop { return false }
        // A partial success is still incomplete. Back off failed network work,
        // but never cache a missing background permanently as a success.
        return (updated ?? .distantPast) <= now.addingTimeInterval(-3600)
    }
}
