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
    private var connectObserver: NSObjectProtocol?
    private var disconnectObserver: NSObjectProtocol?
    private var chordTimer: Timer?
    private var chordHoldStart: Date?

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
            MainActor.assumeIsolated {
                guard let self, app.processIdentifier == self.trackedPID else { return }
                self.clearTracking()
                self.restoreGameCenterToFront()
            }
        }

        connectObserver = NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateChordTimer() }
        }
        disconnectObserver = NotificationCenter.default.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateChordTimer() }
        }
        updateChordTimer()
    }

    private func updateChordTimer() {
        let hasController = trackedApp != nil && GCController.controllers().contains { $0.extendedGamepad != nil }
        if hasController {
            if chordTimer == nil {
                let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.checkExitChord() }
                }
                RunLoop.main.add(timer, forMode: .common)
                chordTimer = timer
            }
        } else {
            chordTimer?.invalidate()
            chordTimer = nil
            chordHoldStart = nil
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
        if let observer = connectObserver {
            NotificationCenter.default.removeObserver(observer)
            connectObserver = nil
        }
        if let observer = disconnectObserver {
            NotificationCenter.default.removeObserver(observer)
            disconnectObserver = nil
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
