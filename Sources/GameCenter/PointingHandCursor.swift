import AppKit
import SwiftUI

extension View {
    func pointingHandCursor() -> some View {
        background(PointingHandCursor())
    }
}

struct PlainHandButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(isEnabled ? (configuration.isPressed ? 0.78 : 1) : 0.45)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.975 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
            .pointingHandCursor()
    }
}

private struct PointingHandCursor: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context: Context) -> CursorView {
        CursorView()
    }

    func updateNSView(_ view: CursorView, context: Context) {
        view.isEnabled = isEnabled
        view.window?.invalidateCursorRects(for: view)
    }

    final class CursorView: NSView {
        var isEnabled = true

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func resetCursorRects() {
            super.resetCursorRects()
            if isEnabled {
                addCursorRect(visibleRect, cursor: .pointingHand)
            }
        }

        override func layout() {
            super.layout()
            window?.invalidateCursorRects(for: self)
        }
    }
}
