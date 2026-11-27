import Foundation
@main struct RefreshTests {
    static func main() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = now.addingTimeInterval(-7200)
        func needs(_ synopsis: Bool = true, _ cover: Bool = true, _ backdrop: Bool = true, updated: Date? = nil, status: String = "found", language: String = "zh") -> Bool {
            MetadataRefreshPolicy.needsRefresh(status: status, savedLanguage: language, language: "zh", hasSynopsis: synopsis, hasArtwork: cover, hasBackdrop: backdrop, updated: updated ?? old, now: now)
        }
        precondition(needs(true, true, false), "A cached synopsis must not permanently suppress a missing background")
        precondition(needs(true, false, true), "A missing cover also needs completion")
        precondition(needs(false, true, true), "A missing synopsis needs completion")
        precondition(!needs(), "A complete successful record should stay cached")
        precondition(!needs(true, true, false, updated: now), "Back off a recent failed artwork request")
        precondition(needs(status: "error"), "Retry stale failures")
        precondition(needs(updated: now, status: "searching"), "Resume an interrupted request on next launch")
        precondition(needs(language: "en"), "Refresh a different language")
        precondition(MetadataRefreshPolicy.normalizedSwitchTitleID("01008cf01baac000") == "01008CF01BAAC000")
        precondition(MetadataRefreshPolicy.normalizedSwitchTitleID("1F140E62-99BA-4D4B-AB35-91F2A7CDFF9B") == nil)
        precondition(MetadataRefreshPolicy.isAcceptableBackdrop(width: 1920, height: 1080))
        precondition(!MetadataRefreshPolicy.isAcceptableBackdrop(width: 400, height: 240))
        precondition(!MetadataRefreshPolicy.isAcceptableBackdrop(width: 600, height: 900))
        precondition(MetadataRefreshPolicy.isWideImage(width: 1280, height: 720))
        precondition(!MetadataRefreshPolicy.isWideImage(width: 600, height: 900))
        precondition(MetadataRefreshPolicy.preferredLanguage(from: ["zh-Hans-CN"]) == "zh")
        precondition(MetadataRefreshPolicy.preferredLanguage(from: ["ja-JP"]) == "ja")
        precondition(MetadataRefreshPolicy.preferredLanguage(from: ["en-US"]) == "en")
        print("PASS: partial success completion, complete cache retention, retry backoff, stale errors, interrupted work, language change, TitleID validation, backdrop rules")
    }
}
