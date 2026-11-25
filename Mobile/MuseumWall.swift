import SwiftUI

struct MuseumWall: View {
    let code: String
    let gallery: Bool
    var artwork: UIImage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var started = Date()
    private static let motes: [[Double]] = {
        guard let url = Bundle.main.url(forResource: "motes", withExtension: "json", subdirectory: "Museum"),
              let data = try? Data(contentsOf: url),
              let values = try? JSONDecoder().decode([[Double]].self, from: data) else { return [] }
        return values.filter { $0.count == 5 }
    }()

    private var accent: Color {
        if let artwork { return Color(uiColor: artwork.museumTint) }
        switch code {
        case "SWITCH", "FC": return Color(red: 0.49, green: 0.20, blue: 0.17)
        case "GB", "GBC": return Color(red: 0.37, green: 0.43, blue: 0.21)
        default: return Color(red: 0.30, green: 0.26, blue: 0.48)
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let base = Color(red: 11/255, green: 10/255, blue: 22/255)
            ZStack {
                base
                RadialGradient(colors: [accent.opacity(0.82), accent.opacity(0.31), .clear], center: UnitPoint(x: 0.5, y: 0.42), startRadius: 0, endRadius: size.width * 0.65)
                if gallery && artwork != nil {
                    Canvas { context, bounds in
                        var grid = Path()
                        for column in stride(from: 0, through: bounds.width, by: 4) {
                            grid.move(to: CGPoint(x: column, y: 0)); grid.addLine(to: CGPoint(x: column, y: bounds.height))
                        }
                        for row in stride(from: 0, through: bounds.height, by: 4) {
                            grid.move(to: CGPoint(x: 0, y: row)); grid.addLine(to: CGPoint(x: bounds.width, y: row))
                        }
                        context.stroke(grid, with: .color(.black.opacity(0.22)), lineWidth: 0.8)
                    }
                }
                TimelineView(.animation(minimumInterval: 1/30, paused: reduceMotion)) { timeline in
                    Canvas { context, bounds in
                        let elapsed = reduceMotion ? 0 : timeline.date.timeIntervalSince(started)
                        let unit = min(bounds.width / 1280, bounds.height / 720)
                        for mote in Self.motes {
                            let travel = mote[1] - elapsed * mote[3]
                            let vertical = travel - floor(travel)
                            let phase = elapsed * 0.05 + mote[4]
                            let alpha = 0.5 * sin((phase - floor(phase)) * .pi)
                            let side = mote[2] * unit
                            let horizontal = bounds.width * mote[0] + sin(elapsed * 0.3 + mote[4] * 6) * 6 * unit
                            let rect = CGRect(x: horizontal - side/2, y: vertical * bounds.height - side/2, width: side, height: side)
                            context.fill(Path(rect), with: .color(.white.opacity(alpha)))
                        }
                    }
                }
                VStack(spacing: 0) {
                    Spacer()
                    LinearGradient(colors: [base.opacity(0.62), base.opacity(0.96)], startPoint: .top, endPoint: .bottom)
                        .frame(height: size.height * (gallery ? 0.35 : 0.29))
                }
                Ellipse().strokeBorder(accent.opacity(0.25), lineWidth: max(1, size.height * 0.004))
                    .frame(width: size.width * 0.39, height: size.height * 0.095)
                    .position(x: size.width * 0.5, y: size.height * (gallery ? 0.65 : 0.74))
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

private extension UIImage {
    static let tintCache = NSCache<UIImage, UIColor>()
    var museumTint: UIColor {
        if let cached = Self.tintCache.object(forKey: self) { return cached }
        var bytes = [UInt8](repeating: 0, count: 4)
        guard let cgImage, let context = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return .darkGray }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let tint = UIColor(red: CGFloat(bytes[0])/255, green: CGFloat(bytes[1])/255, blue: CGFloat(bytes[2])/255, alpha: 1)
        Self.tintCache.setObject(tint, forKey: self)
        return tint
    }
}
