import SwiftUI

enum GameCenterColors {
    static let action = Color(white: 0.94)
    static let actionHover = Color.white
    static let progress = Color(white: 0.88)

    static let surface = Color.white.opacity(0.045)
    static let surfaceElevated = Color.white.opacity(0.085)
    static let surfaceHover = Color.white.opacity(0.14)
    static let border = Color.white.opacity(0.09)
    static let borderStrong = Color.white.opacity(0.16)

    static let destructiveForeground = Color(red: 1.0, green: 0.52, blue: 0.56)
    static let destructiveBackground = Color.red.opacity(0.14)
    static let destructiveBackgroundHover = Color.red.opacity(0.22)
    static let destructiveBorder = Color.red.opacity(0.28)

    static let favoriteForeground = Color(red: 1.0, green: 0.52, blue: 0.58)
    static let favoriteBackground = Color.red.opacity(0.18)
    static let favoriteBackgroundHover = Color.red.opacity(0.26)
    static let favoriteBorder = Color.red.opacity(0.35)
}

struct TactileActionButtonStyle: ButtonStyle {
    enum Appearance { case secondary, primary, destructive }

    var appearance: Appearance = .secondary
    var cornerRadius: CGFloat = 9
    var minHeight: CGFloat = 36
    var horizontalPadding: CGFloat = 13
    var fontSize: CGFloat = 12
    var isControllerFocused = false

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        configuration.label
            .font(.system(size: fontSize, weight: appearance == .primary ? .semibold : .medium))
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, horizontalPadding)
            .frame(minHeight: minHeight)
            .background(backgroundColor(pressed: configuration.isPressed), in: shape)
            .overlay(shape.stroke(borderColor, lineWidth: 1))
            .overlay(shape.stroke(Color.white, lineWidth: isControllerFocused ? 2 : 0))
            .contentShape(shape)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { isHovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isHovered)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
            .pointingHandCursor()
    }

    private var foregroundColor: Color {
        switch appearance {
        case .primary: Color(white: 0.06)
        case .destructive: GameCenterColors.destructiveForeground
        case .secondary: .primary
        }
    }

    private func backgroundColor(pressed: Bool) -> Color {
        switch appearance {
        case .primary:
            pressed ? Color(white: 0.82) : (isHovered ? GameCenterColors.actionHover : GameCenterColors.action)
        case .destructive:
            pressed ? Color.red.opacity(0.26) : (isHovered ? GameCenterColors.destructiveBackgroundHover : GameCenterColors.destructiveBackground)
        case .secondary:
            pressed ? Color.white.opacity(0.18) : (isHovered ? GameCenterColors.surfaceHover : GameCenterColors.surfaceElevated)
        }
    }

    private var borderColor: Color {
        switch appearance {
        case .primary: Color.white.opacity(0.18)
        case .destructive: GameCenterColors.destructiveBorder
        case .secondary: isHovered ? GameCenterColors.borderStrong : Color.white.opacity(0.12)
        }
    }
}

struct SheetCloseButton: View {
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(isHovered ? 1 : 0.72))
                .frame(width: 28, height: 28)
                .background(Color.white.opacity(isHovered ? 0.16 : 0.08), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(PlainHandButtonStyle())
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isHovered)
        .help(AppLanguage.localized("关闭"))
        .accessibilityLabel(AppLanguage.localized("关闭"))
    }
}
