import AppKit
import Foundation
import GameController

/// Tracks standalone external emulator / Switch `.app` launches (Phase 3):
/// 1. Automatically brings Game Center back to the front as soon as the external game terminates.
/// 2. Listens in the background for a 1.5-second `Menu + Options` gamepad hold so controller-only
///    players can cleanly exit RPCS3 / Cemu / Vita3K / Switch and return to Game Center.
@MainActor
final class ExternalGameSessionMonitor: ObservableObject {
    static let shared = ExternalGameSessionMonitor()

    @Published private(set) var activeGameTitle: String?
    @Published private(set) var activePlatformName: String?

    private var trackedApp: NSRunningApplication?
    private var trackedPID: pid_t = 0
    private var terminationObserver: NSObjectProtocol?
    private var chordTimer: Timer?
    private var chordHoldStart: Date?

    var isExternalGameActive: Bool {
        trackedApp != nil && trackedApp?.isTerminated == false
    }

    private init() {}

    func track(runningApp: NSRunningApplication, game: Game) {
        clearTracking()
        trackedApp = runningApp
        trackedPID = runningApp.processIdentifier
        activeGameTitle = game.displayTitle
        activePlatformName = game.platform.shortTitle

        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor [weak self] in
                guard let self, app.processIdentifier == self.trackedPID else { return }
                self.clearTracking()
                self.restoreGameCenterToFront()
            }
        }

        // Start lightweight gamepad chord watcher (hold Menu + Options for 1.5s to exit & return)
        chordTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkExitChord()
            }
        }
        if let chordTimer {
            RunLoop.main.add(chordTimer, forMode: .common)
        }
    }

    func focusExternalGame() {
        trackedApp?.activate(options: [.activateAllWindows])
    }

    func terminateExternalGameAndReturn() {
        guard let app = trackedApp else {
            clearTracking()
            return
        }
        if !app.isTerminated {
            _ = app.terminate()
        }
        clearTracking()
        restoreGameCenterToFront()
    }

    private func checkExitChord() {
        guard let app = trackedApp else {
            clearTracking()
            return
        }
        if app.isTerminated {
            clearTracking()
            restoreGameCenterToFront()
            return
        }

        let holdingChord = GCController.controllers().contains { controller in
            guard let pad = controller.extendedGamepad else { return false }
            return pad.buttonMenu.isPressed && (pad.buttonOptions?.isPressed == true)
        }

        if holdingChord {
            if let start = chordHoldStart {
                if Date().timeIntervalSince(start) >= 1.5 {
                    chordHoldStart = nil
                    terminateExternalGameAndReturn()
                }
            } else {
                chordHoldStart = Date()
            }
        } else {
            chordHoldStart = nil
        }
    }

    private func restoreGameCenterToFront() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeKey && window.isVisible {
            window.makeKeyAndOrderFront(nil)
            break
        }
    }

    private func clearTracking() {
        if let observer = terminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            terminationObserver = nil
        }
        chordTimer?.invalidate()
        chordTimer = nil
        chordHoldStart = nil
        trackedApp = nil
        trackedPID = 0
        activeGameTitle = nil
        activePlatformName = nil
    }
}
