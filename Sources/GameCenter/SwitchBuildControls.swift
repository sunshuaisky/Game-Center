// Progress bar, sweep and pulse adapted from NX2Apple (see NX2Apple-LICENSE.txt).
import SwiftUI

enum BuildPalette {
    static let cream = GameCenterColors.action
    static let building = Color(red: 1, green: 0.78, blue: 0.28)
    static let ready = Color(red: 0.28, green: 0.84, blue: 0.50)
}

extension Font {
    static func buildFace(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}

struct BuildActionStyle: ButtonStyle {
    var primary = false
    var destructive = false
    var prominent = true
    var focused = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        configuration.label
            .font(.system(size: prominent ? 13 : 12, weight: primary || destructive ? .semibold : .medium))
            .lineLimit(1)
            .padding(.horizontal, prominent ? 16 : 12)
            .frame(minWidth: prominent ? 84 : 70, minHeight: prominent ? 38 : 32)
            .foregroundStyle(foregroundColor)
            .background(backgroundColor(pressed: configuration.isPressed), in: shape)
            .overlay(shape.strokeBorder(borderColor, lineWidth: focused ? 2 : 1))
            .contentShape(shape)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(enabled ? 1 : 0.42)
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hovered)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
            .pointingHandCursor()
    }

    private var foregroundColor: Color {
        if primary { return Color(white: 0.06) }
        if destructive { return GameCenterColors.destructiveForeground }
        return Color.white.opacity(0.92)
    }

    private func backgroundColor(pressed: Bool) -> Color {
        if primary {
            return pressed ? Color(white: 0.82) : (hovered ? GameCenterColors.actionHover : GameCenterColors.action)
        }
        if destructive {
            return pressed ? Color.red.opacity(0.26) : (hovered ? GameCenterColors.destructiveBackgroundHover : GameCenterColors.destructiveBackground)
        }
        return pressed ? Color.white.opacity(0.18) : Color.white.opacity(hovered ? 0.14 : 0.08)
    }

    private var borderColor: Color {
        if focused { return .white }
        if primary { return .white.opacity(0.18) }
        if destructive { return GameCenterColors.destructiveBorder }
        return .white.opacity(hovered ? 0.18 : 0.11)
    }
}

struct LauncherProgressBar: View {
    var value: Double?
    var height: CGFloat = 8
    var tint: Color = GameCenterColors.action

    init(value: Double?, height: CGFloat = 8, tint: Color = GameCenterColors.action) {
        self.value = value
        self.height = height
        self.tint = tint
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
                Capsule().fill(tint.opacity(0.16))
                TimelineView(.animation) { context in
                    Canvas { canvas, size in
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { g in
            if !reduceMotion {
                LinearGradient(colors: [.clear, Color.white.opacity(0.55), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: max(40, g.size.width * 0.35))
                    .offset(x: moving ? g.size.width : -max(40, g.size.width * 0.35))
            }
        }
        .clipped()
        .allowsHitTesting(false)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 1.7).repeatForever(autoreverses: false)) { moving = true }
        }
    }
}

/// 当前步骤前面呼吸的小圆点。
struct PulseDot: View {
    @State private var on = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if !reduceMotion {
                Circle().fill(GameCenterColors.action.opacity(on ? 0 : 0.38)).frame(width: on ? 24 : 11, height: on ? 24 : 11)
            }
            Circle().fill(GameCenterColors.action).frame(width: 9, height: 9)
        }
        .frame(width: 24, height: 24)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { on = true }
        }
    }
}
