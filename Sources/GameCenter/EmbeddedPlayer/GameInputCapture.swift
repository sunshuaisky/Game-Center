import AppKit
import CoreHostIPC
import Foundation
import GameController

/// Aggregates keyboard, mouse (pointer + relative deltas/buttons/wheel), and up to 4 GCControllers
/// into the lock-free `SharedInputRegion` read by `GameCenterCoreHelper`.
@MainActor
final class GameInputCapture {
    struct BindingHint: Identifiable {
        let id = UUID()
        let action: String
        let keyboard: String
        let gamepad: String
    }

    static let defaultHints: [BindingHint] = [
        .init(action: "方向键", keyboard: "↑ ↓ ← → / W A S D", gamepad: "十字键 / 左摇杆"),
        .init(action: "A / B", keyboard: "X (或 J)  /  Z (或 K)", gamepad: "B / A（东/南键）"),
        .init(action: "X / Y", keyboard: "V (或 I)  /  C (或 U)", gamepad: "Y / X（北/西键）"),
        .init(action: "L / R", keyboard: "Q (或 O)  /  E (或 P)", gamepad: "L1 / R1"),
        .init(action: "L2 / R2", keyboard: "1  /  2", gamepad: "L2 / R2"),
        .init(action: "Start / Select", keyboard: "Enter  /  Tab 或 右 Shift", gamepad: "Menu / Options"),
        .init(action: "触屏 / 鼠标", keyboard: "窗口内左键点击拖动（NDS/鼠标游戏）", gamepad: "指针由鼠标控制"),
        .init(action: "快进（按住）", keyboard: "Space", gamepad: "—"),
        .init(action: "暂停 / 菜单", keyboard: "Esc", gamepad: "同时按 Menu + Options"),
        .init(action: "快捷存档 / 读档", keyboard: "⌘S  /  ⌘L（槽位 1）", gamepad: "暂停菜单内操作"),
        .init(action: "切换全屏", keyboard: "⌘F", gamepad: "—")
    ]

    // Libretro joypad button bit indices
    private enum RetroButton: UInt16 {
        case b = 0
        case y = 1
        case select = 2
        case start = 3
        case up = 4
        case down = 5
        case left = 6
        case right = 7
        case a = 8
        case x = 9
        case l = 10
        case r = 11
        case l2 = 12
        case r2 = 13
        case l3 = 14
        case r3 = 15
    }

    private weak var targetWindow: NSWindow?
    private let inputRegion: SharedInputRegion
    private let mirrorLeftStickToDPad: Bool
    private var keyMonitor: Any?
    private var pollTimer: Timer?
    private var connectObserver: NSObjectProtocol?
    private var disconnectObserver: NSObjectProtocol?
    private var connectedControllers: [GCController] = []

    private var keyboardButtons: UInt16 = 0
    private var keyboardFastForward = false
    private var manualFastForward = false
    private var isPaused = false

    private var pointerX: Int16 = 0
    private var pointerY: Int16 = 0
    private var pointerPressed = false
    private var mouseButtons: UInt8 = 0
    private var pendingMouseDX: Int32 = 0
    private var pendingMouseDY: Int32 = 0
    private var pendingMouseWheelY: Int32 = 0

    private var lastPauseChordPressed = false

    var onTogglePauseOverlay: (() -> Void)?
    var onQuickSave: (() -> Void)?
    var onQuickLoad: (() -> Void)?
    var onToggleFullscreen: (() -> Void)?
    var onControllerChanged: ((String?) -> Void)?

    init(inputRegion: SharedInputRegion, mirrorLeftStickToDPad: Bool = true) {
        self.inputRegion = inputRegion
        self.mirrorLeftStickToDPad = mirrorLeftStickToDPad
    }

    deinit {
        pollTimer?.invalidate()
        if let connectObserver { NotificationCenter.default.removeObserver(connectObserver) }
        if let disconnectObserver { NotificationCenter.default.removeObserver(disconnectObserver) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    func attach(to window: NSWindow) {
        detach()
        targetWindow = window

        GCController.startWirelessControllerDiscovery(completionHandler: nil)
        connectObserver = NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
            let name = (note.object as? GCController)?.vendorName ?? "外接手柄"
            MainActor.assumeIsolated {
                self?.refreshControllers()
                self?.onControllerChanged?("已连接手柄：\(name)")
            }
        }
        disconnectObserver = NotificationCenter.default.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshControllers()
                self?.onControllerChanged?("外接手柄已断开")
            }
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self, let target = self.targetWindow, event.window === target else {
                return event
            }
            return self.handleKeyEvent(event) ? nil : event
        }

        refreshControllers()
    }

    private func refreshControllers() {
        connectedControllers = Array(
            GCController.controllers()
                .filter { $0.extendedGamepad != nil || $0.microGamepad != nil }
                .prefix(4)
        )
        updatePollTimer()
        flushToSharedMemory()
    }

    private func updatePollTimer() {
        let shouldPoll = targetWindow != nil && !connectedControllers.isEmpty
        if shouldPoll {
            if pollTimer == nil {
                let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.flushToSharedMemory()
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                pollTimer = timer
            }
        } else {
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }

    func detach() {
        GCController.stopWirelessControllerDiscovery()
        if let connectObserver {
            NotificationCenter.default.removeObserver(connectObserver)
            self.connectObserver = nil
        }
        if let disconnectObserver {
            NotificationCenter.default.removeObserver(disconnectObserver)
            self.disconnectObserver = nil
        }
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        pollTimer?.invalidate()
        pollTimer = nil
        connectedControllers.removeAll()
        keyboardButtons = 0
        keyboardFastForward = false
        pointerPressed = false
        mouseButtons = 0
        pendingMouseDX = 0
        pendingMouseDY = 0
        pendingMouseWheelY = 0
        targetWindow = nil
        flushToSharedMemory()
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        if paused {
            keyboardButtons = 0
            keyboardFastForward = false
            pointerPressed = false
            mouseButtons = 0
        }
        flushToSharedMemory()
    }

    func setManualFastForward(_ enabled: Bool) {
        manualFastForward = enabled
        flushToSharedMemory()
    }

    func updatePointerAndMouse(
        pointer: (Double, Double, Bool)?,
        buttonMask: UInt8,
        deltaX: Int32 = 0,
        deltaY: Int32 = 0,
        wheelY: Int32 = 0
    ) {
        if let (normalizedX, normalizedY, pressed) = pointer {
            let clampedX = min(max(normalizedX, 0.0), 1.0)
            let clampedY = min(max(normalizedY, 0.0), 1.0)
            pointerX = Int16((clampedX * 2.0 - 1.0) * 32767.0)
            pointerY = Int16((clampedY * 2.0 - 1.0) * 32767.0)
            pointerPressed = pressed
        }
        mouseButtons = buttonMask
        pendingMouseDX += deltaX
        pendingMouseDY += deltaY
        pendingMouseWheelY += wheelY
        flushToSharedMemory()
    }

    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if event.type == .keyDown {
            // Command shortcuts
            if modifiers.contains(.command) {
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "s":
                    if !event.isARepeat { onQuickSave?() }
                    return true
                case "l":
                    if !event.isARepeat { onQuickLoad?() }
                    return true
                case "f":
                    if !event.isARepeat { onToggleFullscreen?() }
                    return true
                case "w", "q", "m", "h":
                    return false // Allow standard macOS window/app shortcuts
                default:
                    return false
                }
            }

            // Escape toggles pause overlay
            if event.keyCode == 53 {
                if !event.isARepeat { onTogglePauseOverlay?() }
                return true
            }
        }

        if event.type == .flagsChanged {
            // Right Shift (keyCode 60) -> Select
            if event.keyCode == 60 {
                let down = modifiers.contains(.shift)
                setKeyboardButton(.select, pressed: down)
                return true
            }
            return false
        }

        guard !isPaused else { return false }

        let pressed = (event.type == .keyDown)
        // Space -> Hold Fast Forward
        if event.keyCode == 49 {
            keyboardFastForward = pressed
            flushToSharedMemory()
            return true
        }

        if let button = mapKeyCode(event.keyCode) {
            setKeyboardButton(button, pressed: pressed)
            return true
        }
        return false
    }

    private func setKeyboardButton(_ button: RetroButton, pressed: Bool) {
        let mask: UInt16 = 1 << button.rawValue
        if pressed {
            keyboardButtons |= mask
        } else {
            keyboardButtons &= ~mask
        }
        flushToSharedMemory()
    }

    private func mapKeyCode(_ keyCode: UInt16) -> RetroButton? {
        switch keyCode {
        // D-Pad: Arrows + WASD
        case 126, 13: return .up     // Up Arrow / W
        case 125, 1:  return .down   // Down Arrow / S -> wait: S is also X? No, keep WASD clean!
        case 123, 0:  return .left   // Left Arrow / A
        case 124, 2:  return .right  // Right Arrow / D
        // Face buttons (right hand cluster + classic emulator cluster)
        case 6, 40:   return .b      // Z / K
        case 7, 38:   return .a      // X / J
        case 32, 8:   return .y      // U / C
        case 34, 9:   return .x      // I / V
        // Shoulders & Triggers
        case 12, 31:  return .l      // Q / O
        case 14, 35:  return .r      // E / P
        case 18:      return .l2     // 1
        case 19:      return .r2     // 2
        // Start / Select
        case 36, 76:  return .start  // Return / Enter
        case 48, 51:  return .select // Tab / Backspace
        default:      return nil
        }
    }

    private func flushToSharedMemory() {
        var buttons: (UInt16, UInt16, UInt16, UInt16) = (isPaused ? 0 : keyboardButtons, 0, 0, 0)
        var axes: (Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16) =
            (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)

        withUnsafeMutablePointer(to: &buttons) { bRaw in
            bRaw.withMemoryRebound(to: UInt16.self, capacity: 4) { bPtr in
                withUnsafeMutablePointer(to: &axes) { aRaw in
                    aRaw.withMemoryRebound(to: Int16.self, capacity: 16) { aPtr in
                        for idx in 0..<connectedControllers.count {
                            let controller = connectedControllers[idx]
                            if let pad = controller.extendedGamepad {
                                // Check pause chord on player 1 (Menu + Options)
                                if idx == 0 {
                                    let chord = pad.buttonMenu.isPressed && (pad.buttonOptions?.isPressed == true)
                                    if chord && !lastPauseChordPressed {
                                        onTogglePauseOverlay?()
                                    }
                                    lastPauseChordPressed = chord
                                }

                                guard !isPaused else { continue }

                                var mask: UInt16 = 0
                                if pad.buttonA.isPressed { mask |= (1 << RetroButton.b.rawValue) }
                                if pad.buttonB.isPressed { mask |= (1 << RetroButton.a.rawValue) }
                                if pad.buttonX.isPressed { mask |= (1 << RetroButton.y.rawValue) }
                                if pad.buttonY.isPressed { mask |= (1 << RetroButton.x.rawValue) }
                                if pad.buttonOptions?.isPressed == true { mask |= (1 << RetroButton.select.rawValue) }
                                if pad.buttonMenu.isPressed { mask |= (1 << RetroButton.start.rawValue) }
                                if pad.dpad.up.isPressed || (mirrorLeftStickToDPad && pad.leftThumbstick.yAxis.value > 0.45) { mask |= (1 << RetroButton.up.rawValue) }
                                if pad.dpad.down.isPressed || (mirrorLeftStickToDPad && pad.leftThumbstick.yAxis.value < -0.45) { mask |= (1 << RetroButton.down.rawValue) }
                                if pad.dpad.left.isPressed || (mirrorLeftStickToDPad && pad.leftThumbstick.xAxis.value < -0.45) { mask |= (1 << RetroButton.left.rawValue) }
                                if pad.dpad.right.isPressed || (mirrorLeftStickToDPad && pad.leftThumbstick.xAxis.value > 0.45) { mask |= (1 << RetroButton.right.rawValue) }
                                if pad.leftShoulder.isPressed { mask |= (1 << RetroButton.l.rawValue) }
                                if pad.rightShoulder.isPressed { mask |= (1 << RetroButton.r.rawValue) }
                                if pad.leftTrigger.value > 0.25 { mask |= (1 << RetroButton.l2.rawValue) }
                                if pad.rightTrigger.value > 0.25 { mask |= (1 << RetroButton.r2.rawValue) }
                                if pad.leftThumbstickButton?.isPressed == true { mask |= (1 << RetroButton.l3.rawValue) }
                                if pad.rightThumbstickButton?.isPressed == true { mask |= (1 << RetroButton.r3.rawValue) }
                                bPtr[idx] |= mask

                                let base = idx * 4
                                aPtr[base + 0] = Int16(max(-32767, min(32767, Int(pad.leftThumbstick.xAxis.value * 32767.0))))
                                aPtr[base + 1] = Int16(max(-32767, min(32767, Int(-pad.leftThumbstick.yAxis.value * 32767.0))))
                                aPtr[base + 2] = Int16(max(-32767, min(32767, Int(pad.rightThumbstick.xAxis.value * 32767.0))))
                                aPtr[base + 3] = Int16(max(-32767, min(32767, Int(-pad.rightThumbstick.yAxis.value * 32767.0))))
                            } else if let micro = controller.microGamepad, !isPaused {
                                var mask: UInt16 = 0
                                if micro.buttonA.isPressed { mask |= (1 << RetroButton.b.rawValue) }
                                if micro.buttonX.isPressed { mask |= (1 << RetroButton.a.rawValue) }
                                if micro.buttonMenu.isPressed { mask |= (1 << RetroButton.start.rawValue) }
                                if micro.dpad.up.isPressed { mask |= (1 << RetroButton.up.rawValue) }
                                if micro.dpad.down.isPressed { mask |= (1 << RetroButton.down.rawValue) }
                                if micro.dpad.left.isPressed { mask |= (1 << RetroButton.left.rawValue) }
                                if micro.dpad.right.isPressed { mask |= (1 << RetroButton.right.rawValue) }
                                bPtr[idx] |= mask
                            }
                        }

                        let dx = pendingMouseDX
                        let dy = pendingMouseDY
                        let wy = pendingMouseWheelY
                        pendingMouseDX = 0
                        pendingMouseDY = 0
                        pendingMouseWheelY = 0

                        let speed: UInt8 = (keyboardFastForward || manualFastForward) ? 3 : 1
                        inputRegion.write(
                            buttonsPointer: bPtr,
                            axesPointer: aPtr,
                            pointerX: pointerX,
                            pointerY: pointerY,
                            pointerPressed: isPaused ? false : pointerPressed,
                            mouseButtons: isPaused ? 0 : mouseButtons,
                            mouseDXDelta: isPaused ? 0 : dx,
                            mouseDYDelta: isPaused ? 0 : dy,
                            mouseWheelDelta: isPaused ? 0 : wy,
                            fastForward: speed,
                            paused: isPaused
                        )
                    }
                }
            }
        }
    }
}
