import CRetroHost
import CoreHostIPC
import Darwin
import Foundation

@main
struct CoreHostIPCTests {
    static func main() throws {
        guard CommandLine.arguments.count >= 2 else {
            fputs("Usage: core_host_ipc <path-to-GameCenterCoreHelper>\n", stderr)
            exit(64)
        }
        let helperPath = CommandLine.arguments[1]
        precondition(FileManager.default.isExecutableFile(atPath: helperPath), "Helper executable missing: \(helperPath)")

        // 1. Test lock-free shared input (buttons + analog + pointer + mouse delta accumulation/reset)
        let input = try SharedInputRegion()
        input.write(
            buttons: [0x0105, 0x0020, 0, 0],
            axes: [1234, -5678, 300, -400],
            pointerX: 10000,
            pointerY: -20000,
            pointerPressed: true,
            mouseButtons: 0b101,
            mouseDXDelta: 12,
            mouseDYDelta: -8,
            mouseWheelDelta: 2,
            fastForward: 3,
            paused: false
        )
        input.write(
            buttons: [0x0105, 0x0020, 0, 0],
            axes: [1234, -5678, 300, -400],
            pointerX: 10000,
            pointerY: -20000,
            pointerPressed: true,
            mouseButtons: 0b101,
            mouseDXDelta: 5,
            mouseDYDelta: 3,
            mouseWheelDelta: -1,
            fastForward: 3,
            paused: false
        )
        let firstRead = input.read()
        precondition(firstRead.snapshot.buttons.0 == 0x0105)
        precondition(firstRead.snapshot.buttons.1 == 0x0020)
        precondition(firstRead.snapshot.pointer_x == 10000)
        precondition(firstRead.snapshot.pointer_y == -20000)
        precondition(firstRead.snapshot.pointer_pressed == 1)
        precondition(firstRead.snapshot.mouse_buttons == 0b101)
        precondition(firstRead.mouseDX == 17, "Expected accumulated dx=17, got \(firstRead.mouseDX)")
        precondition(firstRead.mouseDY == -5, "Expected accumulated dy=-5, got \(firstRead.mouseDY)")
        precondition(firstRead.mouseWheelY == 1, "Expected accumulated wheel=1, got \(firstRead.mouseWheelY)")
        precondition(firstRead.snapshot.fast_forward == 3)

        let secondRead = input.read()
        precondition(secondRead.mouseDX == 0 && secondRead.mouseDY == 0 && secondRead.mouseWheelY == 0, "Mouse deltas must reset after read")

        // 2. Test triple-buffered frame ring
        let frames = try SharedFrameRing()
        precondition(frames.latestFrame(after: 0) == nil)
        let slot = frames.nextWriteSlot()
        guard let pixels = frames.pixelBufferPointer(slotIndex: slot) else {
            fatalError("Missing pixel slot")
        }
        pixels[0] = 0x11
        pixels[1] = 0x22
        pixels[2] = 0x33
        pixels[3] = 0xFF
        frames.commit(slotIndex: slot, width: 240, height: 160, bytesPerRow: 240 * 4, aspectRatio: 1.5)
        let latest = frames.latestFrame(after: 0)
        precondition(latest != nil)
        precondition(latest!.width == 240 && latest!.height == 160 && latest!.sequence == 1)
        precondition(frames.latestFrame(after: latest!.sequence) == nil)

        // 3. Test real GameCenterCoreHelper subprocess handshake, error path, and parent-disconnect auto-exit
        let (parentChannel, childControlFD) = try ControlSocketChannel.makePair()
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        let tmpControl = fcntl(childControlFD, F_DUPFD_CLOEXEC, 40)
        let tmpInput = fcntl(input.memory.fileDescriptor, F_DUPFD_CLOEXEC, 40)
        let tmpFrame = fcntl(frames.memory.fileDescriptor, F_DUPFD_CLOEXEC, 40)
        precondition(tmpControl >= 0 && tmpInput >= 0 && tmpFrame >= 0)
        defer {
            Darwin.close(tmpControl)
            Darwin.close(tmpInput)
            Darwin.close(tmpFrame)
        }
        posix_spawn_file_actions_adddup2(&fileActions, tmpControl, 3)
        posix_spawn_file_actions_adddup2(&fileActions, tmpInput, 4)
        posix_spawn_file_actions_adddup2(&fileActions, tmpFrame, 5)

        let argvStrings = [helperPath, "--control-fd", "3", "--input-fd", "4", "--frame-fd", "5"]
        var cArgs: [UnsafeMutablePointer<CChar>?] = argvStrings.map { strdup($0) }
        cArgs.append(nil)
        defer { for p in cArgs where p != nil { free(p) } }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, helperPath, &fileActions, nil, &cArgs, environ)
        precondition(rc == 0, "posix_spawn failed: \(rc)")
        Darwin.close(childControlFD)

        let readyEvent = try parentChannel.receive(HelperEvent.self)
        guard case .ready = readyEvent else {
            fatalError("Expected .ready event, got \(readyEvent)")
        }

        // Send a load command for a nonexistent core and verify graceful fatalError
        try parentChannel.send(HostCommand.load(CoreLoadRequest(
            corePath: "/nonexistent/missing_core.dylib",
            romPath: "/nonexistent/game.gba",
            systemDir: "/tmp",
            saveDir: "/tmp",
            batteryPath: nil
        )))
        let errEvent = try parentChannel.receive(HelperEvent.self)
        guard case .fatalError(let msg) = errEvent, !msg.isEmpty else {
            fatalError("Expected .fatalError event, got \(errEvent)")
        }

        // Close parent socket abruptly without sending .shutdown; verify helper watchdog exits within 1s
        parentChannel.close()
        let deadline = Date().addingTimeInterval(1.5)
        var status: Int32 = 0
        var exited = false
        while Date() < deadline {
            if waitpid(pid, &status, WNOHANG) == pid {
                exited = true
                break
            }
            usleep(20_000)
        }
        if !exited {
            kill(pid, SIGKILL)
            _ = waitpid(pid, &status, 0)
            fatalError("Helper did not auto-exit after parent socket closed")
        }

        print("PASS: shared input/mouse/frame ring, real helper handshake, error reporting, and parent-disconnect auto-exit")
    }
}
