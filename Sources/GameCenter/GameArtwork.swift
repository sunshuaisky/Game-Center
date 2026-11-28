import AppKit
import ImageIO
import SwiftUI

private final class GameArtworkCache: @unchecked Sendable {
    static let shared = GameArtworkCache()
    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 180
        cache.totalCostLimit = 160 * 1024 * 1024
    }

    func image(for key: String) -> NSImage? {
        cache.object(forKey: key as NSString)
    }

    func store(_ image: NSImage, for key: String, pixelCost: Int? = nil) {
        let cost: Int
        if let pixelCost {
            cost = max(1, pixelCost)
        } else if let rep = image.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            cost = max(1, rep.pixelsWide * rep.pixelsHigh * 4)
        } else {
            cost = max(1, Int(image.size.width * image.size.height) * 4)
        }
        cache.setObject(image, forKey: key as NSString, cost: cost)
    }
}

struct GameArtwork: View {
    let game: Game
    var compact = false
    var cornerRadius: CGFloat = 10
    var showPlatformBadge = true

    @State private var coverImage: NSImage?
    @State private var isBlurredFallbackBackdrop = false

    private var palette: [Color] {
        let key = (game.metadataTitle ?? game.title).lowercased()
        if key.contains("mario") || key.contains("metroid") { return [Color(red: 0.82, green: 0.34, blue: 0.24), Color(red: 0.28, green: 0.14, blue: 0.22)] }
        if key.contains("zelda") || key.contains("pokemon") { return [Color(red: 0.34, green: 0.56, blue: 0.44), Color(red: 0.12, green: 0.26, blue: 0.26)] }
        if key.contains("hollow") || key.contains("inside") { return [Color(red: 0.34, green: 0.38, blue: 0.48), Color(red: 0.10, green: 0.12, blue: 0.16)] }
        if key.contains("stardew") || key.contains("animal") { return [Color(red: 0.44, green: 0.64, blue: 0.50), Color(red: 0.16, green: 0.34, blue: 0.34)] }
        return [Color(red: 0.54, green: 0.40, blue: 0.48), Color(red: 0.18, green: 0.21, blue: 0.30)]
    }

    private var artworkSymbol: String {
        switch game.platform {
        case .gba, .gb, .gbc, .psp: "gamecontroller.fill"
        case .nds, .threeDS: "rectangle.split.2x1.fill"
        case .famicom, .superFamicom, .n64, .megaDrive, .ps1: "gameconsole.fill"
        case .switchConsole: "gamecontroller.fill"
        case .macOS: "sparkle"
        default: "gameconsole.fill"
        }
    }

    private var loadKey: String {
        [
            game.id.uuidString,
            compact ? "backdrop" : "tile",
            game.artworkBookmark.map { String($0.hashValue) } ?? "",
            game.artworkSourceURL ?? "",
            game.metadataArtworkPath ?? "",
            game.metadataBackdropPath ?? "",
            game.metadataLastUpdated.map { String($0.timeIntervalSince1970) } ?? ""
        ].joined(separator: "|")
    }

    var body: some View {
        let key = loadKey
        let displayedImage = coverImage ?? GameArtworkCache.shared.image(for: key)
        let displayedBlurred = displayedImage.map { compact && !Self.isWide($0) } ?? isBlurredFallbackBackdrop

        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                if let displayedImage {
                    Image(nsImage: displayedImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .scaleEffect(displayedBlurred ? 1.14 : (compact ? 1.02 : 1.0))
                        .blur(radius: displayedBlurred ? 20 : 0)
                        .saturation(displayedBlurred ? 1.12 : 1.0)
                        .clipped()
                } else {
                    LinearGradient(colors: palette, startPoint: .topLeading, endPoint: .bottomTrailing)

                    Circle()
                        .fill(.white.opacity(0.14))
                        .frame(width: compact ? 92 : 150, height: compact ? 92 : 150)
                        .blur(radius: compact ? 22 : 30)
                        .offset(x: compact ? 44 : 76, y: compact ? -38 : -64)

                    Image(systemName: artworkSymbol)
                        .font(.system(size: compact ? 28 : 38, weight: .light))
                        .foregroundStyle(.white.opacity(0.84))
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }

                if !compact && showPlatformBadge {
                    Text(game.platform.shortTitle)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .tracking(0.5)
                        .foregroundStyle(.white.opacity(0.92))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3.5)
                        .background(.black.opacity(0.48), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .stroke(.white.opacity(0.12), lineWidth: 0.75)
                        )
                        .padding(8)
                }

                // Only render inner title on generated placeholder covers so real cover art stays clean
                // and does not duplicate the title below the card or collide with the bottom-right menu button.
                if !compact && displayedImage == nil {
                    LinearGradient(colors: [.clear, .black.opacity(0.56)], startPoint: .center, endPoint: .bottom)
                        .allowsHitTesting(false)

                    Text(game.displayTitle)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .lineLimit(2)
                        .foregroundStyle(.white.opacity(0.92))
                        .padding(.horizontal, 10)
                        .padding(.bottom, 10)
                        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottomLeading)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipShape(RoundedRectangle(cornerRadius: compact ? 0 : cornerRadius, style: .continuous))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityHidden(true)
        .task(id: key) {
            await loadCoverAsync(key: key)
        }
    }

    private func loadCoverAsync(key: String) async {
        if let cached = GameArtworkCache.shared.image(for: key) {
            coverImage = cached
            isBlurredFallbackBackdrop = compact && !Self.isWide(cached)
            return
        }

        let bookmark = game.artworkBookmark
        let backdropPath = game.metadataBackdropPath
        let artworkPath = game.metadataArtworkPath
        let platform = game.platform
        let isCompact = compact
        let maxPixels = isCompact ? 1920 : 512
        let gameSnapshot = game

        let loaded: (NSImage, Bool, Int)? = await Task.detached(priority: .userInitiated) {
            if let bookmark, let url = Self.resolvedBookmark(bookmark) {
                let hasAccess = url.startAccessingSecurityScopedResource()
                defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
                if let decoded = Self.decodeImage(at: url, maxPixelSize: maxPixels) {
                    return (decoded.0, isCompact && !Self.isWide(decoded.0), decoded.1)
                }
            }

            if isCompact, let path = backdropPath {
                if let decoded = Self.decodeImage(at: URL(fileURLWithPath: path), maxPixelSize: maxPixels) {
                    return (decoded.0, !Self.isWide(decoded.0), decoded.1)
                }
            }

            if let path = artworkPath {
                if let decoded = Self.decodeImage(at: URL(fileURLWithPath: path), maxPixelSize: maxPixels) {
                    return (decoded.0, isCompact && !Self.isWide(decoded.0), decoded.1)
                }
            }

            return nil
        }.value

        guard !Task.isCancelled else { return }
        if let (image, blurred, cost) = loaded {
            GameArtworkCache.shared.store(image, for: key, pixelCost: cost)
            coverImage = image
            isBlurredFallbackBackdrop = blurred
            return
        }

        if !isCompact && (platform == .macOS || platform == .switchConsole),
           let url = try? gameSnapshot.resolvedURL(),
           url.pathExtension.lowercased() == "app" {
            let hasAccess = url.startAccessingSecurityScopedResource()
            defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            GameArtworkCache.shared.store(icon, for: key)
            coverImage = icon
            isBlurredFallbackBackdrop = false
            return
        }

        coverImage = nil
        isBlurredFallbackBackdrop = false
    }

    nonisolated private static func decodeImage(at url: URL, maxPixelSize: Int) -> (NSImage, Int)? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else {
            return nil
        }
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
            return nil
        }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        return (image, cgImage.width * cgImage.height * 4)
    }

    nonisolated private static func isWide(_ image: NSImage) -> Bool {
        MetadataRefreshPolicy.isWideImage(width: image.size.width, height: image.size.height)
    }

    nonisolated private static func resolvedBookmark(_ bookmark: Data) -> URL? {
        var isStale = false
        if let scoped = try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) {
            return scoped
        }
        return try? URL(
            resolvingBookmarkData: bookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }
}
