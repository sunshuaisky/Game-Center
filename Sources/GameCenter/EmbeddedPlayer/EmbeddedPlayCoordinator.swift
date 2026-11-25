import AppKit
import Foundation
import SwiftUI

/// Owns the dedicated Game Center play window (a separate NSWindow inside the same app,
/// with zero external Dock icon or menu bar). Enforces single-session auto-save-and-replace
/// and default auto-pause when the play window resigns key status.
@MainActor
final class EmbeddedPlayCoordinator: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = EmbeddedPlayCoordinator()

    @Published private(set) var hasKeyPlayWindow = false
    @Published var autoPauseWhenInactive: Bool = MacCoreCatalog.autoPauseWhenInactive {
        didSet {
            MacCoreCatalog.autoPauseWhenInactive = autoPauseWhenInactive
        }
    }

    private var playWindow: NSWindow?
    private var activeSession: CoreSessionController?
    private var activeAccessedROMURL: URL?
    private var pausedByWindowResign = false
    private var fallbackHandler: (() -> Void)?

    private override init() {
        super.init()
    }

    func open(
        game: Game,
        romURL: URL,
        hasSecurityScope: Bool,
        descriptor: MacCoreDescriptor,
        libraryRoot: URL,
        fallbackExternal: (() -> Void)? = nil
    ) throws {
        // User requirement #1: Auto-save and replace existing play window when launching a new game.
        closeActiveSessionAndWindow()

        let session = try CoreSessionController(
            game: game,
            romURL: romURL,
            descriptor: descriptor,
            libraryRoot: libraryRoot
        )
        activeSession = session
        activeAccessedROMURL = hasSecurityScope ? romURL : nil
        fallbackHandler = fallbackExternal
        pausedByWindowResign = false

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = game.displayTitle
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary]
        window.center()
        window.delegate = self

        let rootView = EmbeddedGameWindowView(
            session: session,
            autoPauseWhenInactive: Binding(
                get: { [weak self] in self?.autoPauseWhenInactive ?? true },
                set: { [weak self] newValue in self?.autoPauseWhenInactive = newValue }
            ),
            onToggleFullscreen: { [weak window] in
                window?.toggleFullScreen(nil)
            },
            onFallbackExternal: fallbackExternal == nil ? nil : { [weak self] in
                guard let self else { return }
                let fallback = self.fallbackHandler
                self.closeActiveSessionAndWindow()
                fallback?()
            },
            onCloseWindow: { [weak self] in
                self?.closeActiveSessionAndWindow()
            }
        )

        window.contentViewController = NSHostingController(rootView: rootView)
        playWindow = window

        session.inputCapture.onTogglePauseOverlay = { [weak session] in
            session?.togglePause()
        }
        session.inputCapture.onQuickSave = { [weak session] in
            session?.saveState(slot: 1)
        }
        session.inputCapture.onQuickLoad = { [weak session] in
            session?.loadState(slot: 1)
        }
        session.inputCapture.onToggleFullscreen = { [weak window] in
            window?.toggleFullScreen(nil)
        }
        session.inputCapture.attach(to: window)

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        hasKeyPlayWindow = true
        session.start()
    }

    func closeActiveSessionAndWindow() {
        let windowToClose = playWindow
        playWindow = nil
        hasKeyPlayWindow = false
        pausedByWindowResign = false
        fallbackHandler = nil

        if let session = activeSession {
            session.stopSync()
            activeSession = nil
        }
        if let accessed = activeAccessedROMURL {
            accessed.stopAccessingSecurityScopedResource()
            activeAccessedROMURL = nil
        }
        if let windowToClose {
            windowToClose.delegate = nil
            windowToClose.orderOut(nil)
            windowToClose.close()
        }
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        guard (notification.object as? NSWindow) === playWindow else { return }
        hasKeyPlayWindow = true
        if pausedByWindowResign {
            pausedByWindowResign = false
            activeSession?.setPaused(false)
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        guard (notification.object as? NSWindow) === playWindow else { return }
        hasKeyPlayWindow = false
        // User requirement #2: Default auto-pause when play window loses focus.
        if autoPauseWhenInactive, let session = activeSession, case .running = session.status {
            pausedByWindowResign = true
            session.setPaused(true)
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === playWindow else { return }
        playWindow = nil
        hasKeyPlayWindow = false
        pausedByWindowResign = false
        fallbackHandler = nil
        if let session = activeSession {
            session.stopSync()
            activeSession = nil
        }
        if let accessed = activeAccessedROMURL {
            accessed.stopAccessingSecurityScopedResource()
            activeAccessedROMURL = nil
        }
    }
}
