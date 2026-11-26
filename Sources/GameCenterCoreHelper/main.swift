import CRetroHost
import CoreHostIPC
import Darwin
import Foundation

private final class CommandQueue: @unchecked Sendable {
    private let condition = NSCondition()
    private var commands: [HostCommand] = []
    private var closed = false

    func push(_ command: HostCommand) {
        condition.lock()
        commands.append(command)
        condition.signal()
        condition.unlock()
    }

    func markClosed() {
        condition.lock()
        closed = true
        condition.broadcast()
        condition.unlock()
    }

    func drain() -> (commands: [HostCommand], closed: Bool) {
        condition.lock()
        defer { condition.unlock() }
        let items = commands
        commands.removeAll(keepingCapacity: true)
        return (items, closed)
    }

    func waitForCommand(timeoutSeconds: Double) -> (commands: [HostCommand], closed: Bool) {
        condition.lock()
        defer { condition.unlock() }
        if commands.isEmpty && !closed {
            _ = condition.wait(until: Date().addingTimeInterval(timeoutSeconds))
        }
        let items = commands
        commands.removeAll(keepingCapacity: true)
        return (items, closed)
    }
}

private final class HelperRuntimeContext {
    let frameRing: SharedFrameRing
    let audio: CoreAudioOutput
    var isFastForwarding = false
    var suppressVideo = false

    init(frameRing: SharedFrameRing, audio: CoreAudioOutput) {
        self.frameRing = frameRing
        self.audio = audio
    }
}

private func collectOptions(from host: OpaquePointer) -> [CoreOptionDTO] {
    let count = gc_host_option_count(host)
    var list: [CoreOptionDTO] = []
    list.reserveCapacity(count)
    for i in 0..<count {
        var info = GCRetroOptionInfo()
        guard gc_host_option_at(host, i, &info),
              let keyPtr = info.key,
              let descPtr = info.description,
              let curPtr = info.current_value,
              let defPtr = info.default_value else { continue }
        var choices: [CoreOptionChoiceDTO] = []
        choices.reserveCapacity(info.choice_count)
        for j in 0..<info.choice_count {
            var c = GCRetroOptionChoice()
            if gc_host_option_choice_at(host, i, j, &c),
               let vPtr = c.value,
               let lPtr = c.label {
                choices.append(CoreOptionChoiceDTO(value: String(cString: vPtr), label: String(cString: lPtr)))
            }
        }
        list.append(CoreOptionDTO(
            key: String(cString: keyPtr),
            description: String(cString: descPtr),
            currentValue: String(cString: curPtr),
            defaultValue: String(cString: defPtr),
            choices: choices
        ))
    }
    return list
}

private func parseDescriptor(_ flag: String, from args: [String]) -> Int32? {
    guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else { return nil }
    return Int32(args[idx + 1])
}

enum GameCenterCoreHelperMain {
    static func run() {
        signal(SIGPIPE, SIG_IGN)
        setenv("MVK_CONFIG_LOG_LEVEL", "0", 0)

        let args = CommandLine.arguments
        guard let controlFD = parseDescriptor("--control-fd", from: args),
              let inputFD = parseDescriptor("--input-fd", from: args),
              let frameFD = parseDescriptor("--frame-fd", from: args) else {
            fputs("Usage: GameCenterCoreHelper --control-fd <fd> --input-fd <fd> --frame-fd <fd>\n", stderr)
            exit(64)
        }

        let channel = ControlSocketChannel(fileDescriptor: controlFD)
        let inputRegion: SharedInputRegion
        let frameRing: SharedFrameRing
        do {
            inputRegion = try SharedInputRegion(inheritedFileDescriptor: inputFD)
            frameRing = try SharedFrameRing(inheritedFileDescriptor: frameFD)
        } catch {
            try? channel.send(HelperEvent.fatalError(error.localizedDescription))
            exit(1)
        }

        let audio = CoreAudioOutput()
        let runtimeContext = HelperRuntimeContext(frameRing: frameRing, audio: audio)
        let queue = CommandQueue()

        let readerThread = Thread {
            while true {
                do {
                    let cmd = try channel.receive(HostCommand.self)
                    queue.push(cmd)
                    if case .shutdown = cmd { break }
                } catch {
                    queue.markClosed()
                    break
                }
            }
        }
        readerThread.name = "GameCenterCoreHelper.IPCReader"
        readerThread.start()

        try? channel.send(HelperEvent.ready)

        var host: OpaquePointer?
        var isVulkanCore = false
        var paused = false
        var shouldExit = false
        var fps = 60.0
        var targetAudioFrames = 2400
        var lastSaveCheck = DispatchTime.now().uptimeNanoseconds
        var nextFrameDeadline = DispatchTime.now().uptimeNanoseconds

        let acquireFrame: gc_acquire_frame_fn = { ctx, width, height, outStride, outSlot in
            guard let ctx else { return nil }
            let runtime = Unmanaged<HelperRuntimeContext>.fromOpaque(ctx).takeUnretainedValue()
            if runtime.suppressVideo { return nil }
            let slot = runtime.frameRing.nextWriteSlot()
            guard let ptr = runtime.frameRing.pixelBufferPointer(slotIndex: slot) else { return nil }
            outStride?.pointee = width * 4
            outSlot?.pointee = slot
            return UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: UInt32.self)
        }

        let commitFrame: gc_commit_frame_fn = { ctx, slot, width, height, stride, aspect in
            guard let ctx else { return }
            let runtime = Unmanaged<HelperRuntimeContext>.fromOpaque(ctx).takeUnretainedValue()
            runtime.frameRing.commit(
                slotIndex: slot,
                width: width,
                height: height,
                bytesPerRow: stride,
                aspectRatio: aspect
            )
        }

        let audioBatch: gc_audio_batch_fn = { ctx, samples, count in
            guard let ctx, let samples else { return }
            let runtime = Unmanaged<HelperRuntimeContext>.fromOpaque(ctx).takeUnretainedValue()
            if runtime.isFastForwarding { return }
            runtime.audio.enqueue(samples: samples, frameCount: count)
        }

        let callbacks = GCRetroHostCallbacks(
            context: Unmanaged.passUnretained(runtimeContext).toOpaque(),
            acquire_frame: acquireFrame,
            commit_frame: commitFrame,
            audio_batch: audioBatch
        )

        func handle(_ cmd: HostCommand) {
            switch cmd {
            case .load(let req):
                if let existing = host {
                    gc_host_close(existing)
                    host = nil
                }
                audio.stop()

                let keys = Array(req.initialOptions.keys)
                let values = keys.map { req.initialOptions[$0] ?? "" }
                let cKeys = keys.map { strdup($0) }
                let cValues = values.map { strdup($0) }
                defer {
                    for p in cKeys { free(p) }
                    for p in cValues { free(p) }
                }

                let opened: OpaquePointer? = cKeys.withUnsafeBufferPointer { kBuf in
                    cValues.withUnsafeBufferPointer { vBuf in
                        req.corePath.withCString { cCore in
                            req.romPath.withCString { cRom in
                                req.systemDir.withCString { cSys in
                                    req.saveDir.withCString { cSave in
                                        let keyArg = kBuf.baseAddress.map { UnsafePointer<UnsafePointer<CChar>?>(OpaquePointer($0)) }
                                        let valArg = vBuf.baseAddress.map { UnsafePointer<UnsafePointer<CChar>?>(OpaquePointer($0)) }
                                        func callOpen(_ cBat: UnsafePointer<CChar>?, _ cMvk: UnsafePointer<CChar>?) -> OpaquePointer? {
                                            gc_host_open(cCore, cRom, cSys, cSave, cBat, cMvk, keyArg, valArg, keys.count, callbacks)
                                        }
                                        switch (req.batteryPath, req.moltenVKPath) {
                                        case (let bat?, let mvk?):
                                            return bat.withCString { cBat in mvk.withCString { cMvk in callOpen(cBat, cMvk) } }
                                        case (let bat?, nil):
                                            return bat.withCString { cBat in callOpen(cBat, nil) }
                                        case (nil, let mvk?):
                                            return mvk.withCString { cMvk in callOpen(nil, cMvk) }
                                        case (nil, nil):
                                            return callOpen(nil, nil)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                guard let opened else {
                    let msg = String(cString: gc_host_last_error())
                    try? channel.send(HelperEvent.fatalError(msg.isEmpty ? "无法加载模拟器核心" : msg))
                    return
                }
                host = opened
                isVulkanCore = gc_host_is_vulkan(opened)
                fps = gc_host_fps(opened)
                let rate = gc_host_sample_rate(opened)
                targetAudioFrames = max(Int(rate * 0.055), 1024)
                audio.start(sampleRate: rate)
                paused = false
                nextFrameDeadline = DispatchTime.now().uptimeNanoseconds

                let loadedInfo = CoreLoadedInfo(
                    fps: fps,
                    sampleRate: rate,
                    baseWidth: Int(gc_host_base_width(opened)),
                    baseHeight: Int(gc_host_base_height(opened)),
                    aspectRatio: gc_host_aspect_ratio(opened),
                    options: collectOptions(from: opened)
                )
                try? channel.send(HelperEvent.loaded(loadedInfo))

            case .setPaused(let p):
                paused = p
                if p {
                    audio.clear()
                    if let host { _ = gc_host_save_battery(host, false) }
                } else {
                    nextFrameDeadline = DispatchTime.now().uptimeNanoseconds
                }

            case .reset:
                if let host { gc_host_reset(host) }
                audio.clear()

            case .setAudio(let volume, let muted):
                audio.setAudio(volume: volume, muted: muted)

            case .saveState(let reqID, let path):
                guard let host else {
                    try? channel.send(HelperEvent.actionResult(requestID: reqID, ok: false, message: "游戏尚未运行"))
                    return
                }
                let ok = path.withCString { gc_host_save_state(host, $0) }
                let msg = ok ? nil : String(cString: gc_host_last_error())
                try? channel.send(HelperEvent.actionResult(requestID: reqID, ok: ok, message: msg))

            case .loadState(let reqID, let path):
                guard let host else {
                    try? channel.send(HelperEvent.actionResult(requestID: reqID, ok: false, message: "游戏尚未运行"))
                    return
                }
                audio.clear()
                let ok = path.withCString { gc_host_load_state(host, $0) }
                let msg = ok ? nil : String(cString: gc_host_last_error())
                try? channel.send(HelperEvent.actionResult(requestID: reqID, ok: ok, message: msg))

            case .setOption(let key, let value):
                guard let host else { return }
                _ = key.withCString { cKey in
                    value.withCString { cVal in
                        gc_host_set_option(host, cKey, cVal)
                    }
                }
                try? channel.send(HelperEvent.optionsUpdated(collectOptions(from: host)))

            case .flushSave(let reqID):
                let ok = host.map { gc_host_save_battery($0, true) } ?? true
                try? channel.send(HelperEvent.actionResult(requestID: reqID, ok: ok, message: ok ? nil : "写入电池存档失败"))

            case .shutdown:
                shouldExit = true
            }
        }

        while !shouldExit {
            if host == nil || paused {
                let batch = queue.waitForCommand(timeoutSeconds: 0.05)
                for cmd in batch.commands {
                    handle(cmd)
                    if shouldExit { break }
                }
                if batch.closed { shouldExit = true }
                continue
            }

            let batch = queue.drain()
            for cmd in batch.commands {
                handle(cmd)
                if shouldExit { break }
            }
            if batch.closed {
                shouldExit = true
                break
            }
            guard let activeHost = host, !paused else { continue }

            let (snap, mouseDX, mouseDY, mouseWheelY) = inputRegion.read()
            if snap.paused != 0 {
                usleep(8000)
                nextFrameDeadline = DispatchTime.now().uptimeNanoseconds
                continue
            }

            let speed = max(1, min(Int(snap.fast_forward), 4))
            runtimeContext.isFastForwarding = speed > 1

            for step in 0..<speed {
                var frameInput = snap
                let dx = step == 0 ? mouseDX : 0
                let dy = step == 0 ? mouseDY : 0
                let wy = step == 0 ? mouseWheelY : 0
                runtimeContext.suppressVideo = !isVulkanCore && step < speed - 1
                gc_host_run_frame(activeHost, &frameInput, dx, dy, wy)
            }
            runtimeContext.suppressVideo = false

            let now = DispatchTime.now().uptimeNanoseconds
            if now &- lastSaveCheck >= 20_000_000_000 {
                _ = gc_host_save_battery(activeHost, false)
                lastSaveCheck = now
            }

            /* Gentle Dynamic Rate Control based on CoreAudio ring buffer level. */
            let baseFrameNs = 1_000_000_000.0 / max(fps, 15.0)
            let fill = audio.fillRatio(targetFrames: targetAudioFrames)
            let drcScale: Double
            if speed > 1 {
                drcScale = 1.0
            } else if fill > 1.25 {
                drcScale = 1.005
            } else if fill < 0.75 {
                drcScale = 0.995
            } else {
                drcScale = 1.0
            }
            let frameNs = UInt64(baseFrameNs * drcScale)
            nextFrameDeadline = nextFrameDeadline &+ frameNs
            let afterRun = DispatchTime.now().uptimeNanoseconds
            if nextFrameDeadline > afterRun {
                let waitNs = nextFrameDeadline - afterRun
                if waitNs < 100_000_000 {
                    // Leave ~1.2 ms headroom for nanosleep timer coalescing, then yield briefly.
                    if waitNs > 1_500_000 {
                        var ts = timespec(tv_sec: 0, tv_nsec: Int(waitNs - 1_200_000))
                        nanosleep(&ts, nil)
                    }
                    while DispatchTime.now().uptimeNanoseconds < nextFrameDeadline {
                        sched_yield()
                    }
                }
            } else if afterRun - nextFrameDeadline > 100_000_000 {
                nextFrameDeadline = afterRun
            }
        }

        audio.stop()
        if let activeHost = host {
            gc_host_close(activeHost)
            host = nil
        }
        channel.close()
        exit(0)
    }
}

GameCenterCoreHelperMain.run()
