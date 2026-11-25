import AppKit
import SwiftUI

struct GameArtwork: View {
    let game: Game
    var compact = false

    @State private var coverImage: NSImage?
    @State private var isBlurredFallbackBackdrop = false

    private var palette: [Color] {
        let key = (game.metadataTitle ?? game.title).lowercased()
        if key.contains("mario") || key.contains("metroid") { return [Color(red: 0.88, green: 0.40, blue: 0.27), Color(red: 0.37, green: 0.19, blue: 0.29)] }
        if key.contains("zelda") || key.contains("pokemon") { return [Color(red: 0.53, green: 0.66, blue: 0.45), Color(red: 0.18, green: 0.35, blue: 0.33)] }
        if key.contains("hollow") || key.contains("inside") { return [Color(red: 0.42, green: 0.43, blue: 0.43), Color(red: 0.12, green: 0.14, blue: 0.16)] }
        if key.contains("stardew") || key.contains("animal") { return [Color(red: 0.53, green: 0.72, blue: 0.57), Color(red: 0.22, green: 0.43, blue: 0.43)] }
        return [Color(red: 0.70, green: 0.53, blue: 0.59), Color(red: 0.27, green: 0.30, blue: 0.40)]
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

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                if let coverImage {
                    Image(nsImage: coverImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .scaleEffect(isBlurredFallbackBackdrop ? 1.12 : 1.0)
                        .blur(radius: isBlurredFallbackBackdrop ? 18 : 0)
                        .clipped()
                } else {
                    LinearGradient(colors: palette, startPoint: .topLeading, endPoint: .bottomTrailing)

                    Circle()
                        .fill(.white.opacity(0.14))
                        .frame(width: compact ? 92 : 160, height: compact ? 92 : 160)
                        .blur(radius: compact ? 22 : 32)
                        .offset(x: compact ? 44 : 82, y: compact ? -38 : -70)

                    Image(systemName: artworkSymbol)
                        .font(.system(size: compact ? 28 : 42, weight: .light))
                        .foregroundStyle(.white.opacity(0.88))
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }

                if !compact {
                    LinearGradient(colors: [.clear, .black.opacity(0.54)], startPoint: .center, endPoint: .bottom)

                    Text(game.platform.shortTitle)
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .tracking(0.8)
                        .foregroundStyle(.white.opacity(0.88))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 4))
                        .padding(9)
                }

                if !compact {
                    Text(game.displayTitle.uppercased())
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .tracking(0.7)
                        .lineLimit(2)
                        .foregroundStyle(.white)
                        .padding(11)
                        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottomLeading)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipShape(RoundedRectangle(cornerRadius: compact ? 0 : 8, style: .continuous))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityHidden(true)
        .onAppear { loadCover() }
        .onChange(of: game.artworkBookmark) { _, _ in loadCover(forceReload: true) }
        .onChange(of: game.artworkSourceURL) { _, _ in loadCover(forceReload: true) }
        .onChange(of: game.metadataArtworkPath) { _, _ in loadCover(forceReload: true) }
        .onChange(of: game.metadataBackdropPath) { _, _ in loadCover(forceReload: true) }
        .onChange(of: game.metadataLastUpdated) { _, _ in loadCover(forceReload: true) }
        .onChange(of: game.id) { _, _ in loadCover(forceReload: true) }
    }

    private func loadCover(forceReload: Bool = false) {
        if forceReload {
            coverImage = nil
            isBlurredFallbackBackdrop = false
        }
        guard coverImage == nil else { return }

        if let bookmark = game.artworkBookmark,
           let url = resolvedBookmark(bookmark) {
            let hasAccess = url.startAccessingSecurityScopedResource()
            if let image = NSImage(contentsOf: url) {
                if !compact || isWide(image) {
                    coverImage = image
                    isBlurredFallbackBackdrop = false
                } else if compact {
                    coverImage = image
                    isBlurredFallbackBackdrop = true
                }
            }
            if hasAccess { url.stopAccessingSecurityScopedResource() }
        }

        if coverImage == nil, compact, let path = game.metadataBackdropPath {
            if let image = NSImage(contentsOfFile: path) {
                coverImage = image
                isBlurredFallbackBackdrop = !isWide(image)
            }
        }

        if coverImage == nil, let path = game.metadataArtworkPath {
            if let image = NSImage(contentsOfFile: path) {
                coverImage = image
                isBlurredFallbackBackdrop = compact && !isWide(image)
            }
        }

        if coverImage == nil, !compact,
           (game.platform == .macOS || game.platform == .switchConsole),
           let url = try? game.resolvedURL(),
           url.pathExtension.lowercased() == "app" {
            let hasAccess = url.startAccessingSecurityScopedResource()
            coverImage = NSWorkspace.shared.icon(forFile: url.path)
            isBlurredFallbackBackdrop = false
            if hasAccess { url.stopAccessingSecurityScopedResource() }
        }
    }

    private func isWide(_ image: NSImage) -> Bool {
        image.size.height > 0 && image.size.width / image.size.height >= 1.3
    }

    private func resolvedBookmark(_ bookmark: Data) -> URL? {
        var isStale = false
        return try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }
}
