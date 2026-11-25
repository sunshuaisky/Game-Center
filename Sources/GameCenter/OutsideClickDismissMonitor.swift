import AppKit
import SwiftUI

struct OutsideClickDismissMonitor: NSViewRepresentable {
    let onDismiss: () -> Void

    func makeNSView(context: Context) -> OutsideClickMonitorView {
        let view = OutsideClickMonitorView()
        view.onDismiss = onDismiss
        return view
    }

    func updateNSView(_ view: OutsideClickMonitorView, context: Context) {
        view.onDismiss = onDismiss
        view.installMonitorIfNeeded()
    }

    static func dismantleNSView(_ view: OutsideClickMonitorView, coordinator: ()) {
        view.removeMonitor()
    }
}

final class OutsideClickMonitorView: NSView {
    var onDismiss: () -> Void = {}
    private var eventMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installMonitorIfNeeded()
    }

    func installMonitorIfNeeded() {
        guard eventMonitor == nil, let observedWindow = window else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self, weak observedWindow] event in
            guard let self, let observedWindow, let eventWindow = event.window else { return event }
            guard eventWindow !== observedWindow, !(eventWindow is NSPanel) else { return event }

            let screenPoint = eventWindow.convertPoint(toScreen: event.locationInWindow)
            guard !observedWindow.frame.contains(screenPoint) else { return event }

            DispatchQueue.main.async { self.onDismiss() }
            return nil
        }
    }

    func removeMonitor() {
        guard let eventMonitor else { return }
        NSEvent.removeMonitor(eventMonitor)
        self.eventMonitor = nil
    }

    deinit {
        removeMonitor()
    }
}
