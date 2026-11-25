// Progress bar, sweep and pulse adapted from NX2Apple (see NX2Apple-LICENSE.txt).
import SwiftUI
import CoreText

enum BuildPalette {
    static let cream = Color(red: 1, green: 0.94, blue: 0.84)
    static let building = Color(red: 1, green: 0.78, blue: 0.24)
    static let ready = Color(red: 0.25, green: 0.84, blue: 0.47)
}

extension Font {
    private static let buildDescriptor: CTFontDescriptor? = {
        let bundled = Bundle.main.url(forResource: "GameCenter_GameCenter", withExtension: "bundle").flatMap(Bundle.init(url:))
        guard let url = (bundled ?? Bundle.module).url(forResource: "Manrope", withExtension: "ttf"),
              let data = try? Data(contentsOf: url) else { return nil }
        return CTFontManagerCreateFontDescriptorFromData(data as CFData)
    }()

    static func buildFace(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        guard let buildDescriptor else { return .system(size: size, weight: weight) }
        let axis: CGFloat = switch weight {
        case .heavy, .black: 800
        case .bold: 700
        case .semibold: 600
        case .medium: 500
        default: 400
        }
        let descriptor = CTFontDescriptorCreateCopyWithAttributes(buildDescriptor,
            [kCTFontVariationAttribute: [0x77676874: axis]] as CFDictionary)
        return Font(CTFontCreateWithFontDescriptor(descriptor, size, nil))
    }
}

struct BuildActionStyle: ButtonStyle {
    var primary = false
    var prominent = true
    var focused = false
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        configuration.label.font(.buildFace(prominent ? 16 : 13, .semibold))
            .lineLimit(1).padding(.horizontal, 16)
            .frame(minWidth: 80, minHeight: prominent ? 48 : 36)
            .foregroundStyle(primary ? Color(white: 0.055) : Color.white.opacity(0.92))
            .background(primary ? BuildPalette.cream.opacity(hovered ? 0.93 : 1)
                        : Color.white.opacity(hovered ? 0.11 : 0.065), in: shape)
            .overlay(shape.strokeBorder(focused ? Color.white : .white.opacity(primary ? 0 : 0.10), lineWidth: focused ? 2 : 1))
            .contentShape(shape).opacity(enabled ? 1 : 0.45).onHover { hovered = $0 }
    }
}

struct LauncherProgressBar: View {
    var value: Double?
    var height: CGFloat = 8
    var tint: Color = BuildPalette.building

    init(value: Double?, height: CGFloat = 8, tint: Color = BuildPalette.building) {
        self.value = value; self.height = height; self.tint = tint
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.white.opacity(0.12))
            if let value {
                GeometryReader { g in
                    Capsule().fill(tint).frame(width: g.size.width * min(max(value, 0), 1))
                        .animation(.easeOut(duration: 0.3), value: value)
                }
            } else {
                Capsule().fill(tint.opacity(0.16))   // an amber-tinted track under soft stripes
                TimelineView(.animation) { context in
                    Canvas { canvas, size in
                        // One stripe and one gap per period; the pattern moves one period every 1.2 s, linearly
                        let period = height * 3, stripe = height * 1.5
                        let t = context.date.timeIntervalSinceReferenceDate
                        let phase = CGFloat(t.truncatingRemainder(dividingBy: 1.2) / 1.2) * period
                        var x = -size.height - period + phase
                        while x < size.width {
                            var p = Path()
                            p.move(to: CGPoint(x: x, y: size.height))
                            p.addLine(to: CGPoint(x: x + size.height, y: 0))
                            p.addLine(to: CGPoint(x: x + size.height + stripe, y: 0))
                            p.addLine(to: CGPoint(x: x + stripe, y: size.height))
                            p.closeSubpath()
                            canvas.fill(p, with: .color(tint.opacity(0.45)))
                            x += period
                        }
                    }
                }
            }
        }
        .frame(height: height)
        .clipShape(Capsule())
        .accessibilityElement()
        .accessibilityValue(value.map { "\(Int($0 * 100))%" } ?? "")
    }
}

struct ProgressSweep: View {
    @State private var moving = false
    var body: some View {
        GeometryReader { g in
            LinearGradient(colors: [.clear, Color.white.opacity(0.55), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: max(40, g.size.width * 0.35))
                .offset(x: moving ? g.size.width : -max(40, g.size.width * 0.35))
        }
        .clipped()
        .allowsHitTesting(false)
        .onAppear { withAnimation(.linear(duration: 1.7).repeatForever(autoreverses: false)) { moving = true } }
    }
}

/// 当前步骤前面呼吸的小圆点。
struct PulseDot: View {
    @State private var on = false
    var body: some View {
        ZStack {
            Circle().fill(BuildPalette.cream.opacity(on ? 0 : 0.35)).frame(width: on ? 26 : 12, height: on ? 26 : 12)
            Circle().fill(BuildPalette.cream).frame(width: 10, height: 10)
        }
        .frame(width: 26, height: 26)
        .onAppear { withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { on = true } }
    }
}

