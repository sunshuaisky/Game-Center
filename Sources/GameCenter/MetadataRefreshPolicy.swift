import Foundation
import ImageIO

/// Unified refresh policy, language normalization, and artwork/backdrop validation
/// shared between macOS and iOS.
enum MetadataRefreshPolicy {
    /// Increment when unified metadata lookup or media selection improves so both
    /// macOS and iOS refresh incomplete or outdated cached assets once.
    static let currentQueryVersion = 16
    static let queryVersionDefaultsKey = "unifiedMetadataQueryVersion"

    /// Minimum dimensions for a dedicated backdrop image (16:9 / wide hero background).
    static let minimumBackdropWidth = 640
    static let minimumBackdropHeight = 360
    static let preferredHDWidth = 960
    static let preferredHDHeight = 540
    static let minimumWideAspectRatio = 1.30
    static let maximumWideAspectRatio = 3.60

    /// Minimum pixel area for cover artwork so tiny broken icons are rejected.
    static let minimumCoverDimension = 120

    static func preferredLanguage(from preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        let preferred = preferredLanguages.first?.lowercased() ?? "en"
        if preferred.hasPrefix("zh") { return "zh" }
        if preferred.hasPrefix("ja") { return "ja" }
        return "en"
    }

    static func needsRefresh(status: String?, savedLanguage: String?, language: String,
                             hasSynopsis: Bool, hasArtwork: Bool, hasBackdrop: Bool,
                             updated: Date?, now: Date = .now) -> Bool {
        if status == nil || status == "searching" || savedLanguage != language { return true }
        if status == "found", hasSynopsis, hasArtwork, hasBackdrop { return false }
        // A partial success is still incomplete. Back off failed network work,
        // but never cache a missing background permanently as a success.
        return (updated ?? .distantPast) <= now.addingTimeInterval(-3600)
    }

    static func imageDimensions(at url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        return (width, height)
    }

    static func imageDimensions(data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        return (width, height)
    }

    static func isValidImageData(_ data: Data) -> Bool {
        imageDimensions(data: data) != nil
    }

    static func isWideImage(width: Double, height: Double) -> Bool {
        guard height > 0 else { return false }
        return (width / height) >= minimumWideAspectRatio
    }

    static func isAcceptableBackdrop(width: Int, height: Int) -> Bool {
        guard width >= minimumBackdropWidth, height >= minimumBackdropHeight else { return false }
        let ratio = Double(width) / Double(height)
        return ratio >= minimumWideAspectRatio && ratio <= maximumWideAspectRatio
    }

    static func isAcceptableBackdrop(at url: URL) -> Bool {
        guard let dims = imageDimensions(at: url) else { return false }
        return isAcceptableBackdrop(width: dims.width, height: dims.height)
    }

    static func isValidSwitchTitleID(_ value: String?) -> Bool {
        guard let value else { return false }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count == 16 else { return false }
        return trimmed.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 70) || ($0 >= 97 && $0 <= 102)
        }
    }

    static func normalizedSwitchTitleID(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return isValidSwitchTitleID(trimmed) ? trimmed.uppercased() : nil
    }
}
