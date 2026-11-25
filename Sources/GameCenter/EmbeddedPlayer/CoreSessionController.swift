import AppKit
import CoreGraphics
import CoreHostIPC
import Darwin
import Foundation

struct EmbeddedSaveSlotInfo: Identifiable, Hashable {
    let slot: Int
    let stateURL: URL
    let thumbnailURL: URL
    let modifiedAt: Date?

    var id: Int { slot }
    var exists: Bool { modifiedAt != nil }
}

enum EmbeddedSessionStatus: Equatable {
    case starting
    case running
    case paused
    case failed(String)
}

/// Manages a single `GameCenterCoreHelper` subprocess, shared memory transport,
/// control socket, save states, thumbnails, and persistent core options.
@MainActor
final class CoreSessionController: ObservableObject {
    let game: Game
    let romURL: URL
    let descriptor: MacCoreDescriptor
    let libraryRoot: URL
    let inputRegion: SharedInputRegion
    let frameRing: SharedFrameRing
    let inputCapture: GameInputCapture

    @Published private(set) var status: EmbeddedSessionStatus = .starting
    @Published private(set) var fps: Double = 60.0
    @Published private(set) var coreOptions: [CoreOptionDTO] = []
    @Published private(set) var saveSlots: [EmbeddedSaveSlotInfo] = []
    @Published var crispPixels: Bool
    @Published var isMuted: Bool = false
    @Published var volume: Float = 1.0
    @Published var fastForward: Bool = false
    @Published var statusToast: String?

    private var saveContext: EmbeddedSaveContext?
    private var controlChannel: ControlSocketChannel?
    private var helperPID: pid_t = 0
    private var processExitSource: DispatchSourceProcess?
    private var isStopping = false
    private var pendingActions: [String: (Bool, String?) -> Void] = [:]
    private var toastTask: Task<Void, Never>?

    init(game: Game, romURL: URL, descriptor: MacCoreDescriptor, libraryRoot: URL) throws {
        self.game = game
        self.romURL = romURL
        self.descriptor = descriptor
        self.libraryRoot = libraryRoot
        self.crispPixels = descriptor.defaultCrispPixels
        self.inputRegion = try SharedInputRegion()
        self.frameRing = try SharedFrameRing()
        let mirrorStick = [.gb, .gbc, .gba, .nds, .famicom, .superFamicom, .megaDrive].contains(game.platform)
        self.inputCapture = GameInputCapture(inputRegion: inputRegion, mirrorLeftStickToDPad: mirrorStick)
        self.inputCapture.onControllerChanged = { [weak self] message in
            guard let self, let message else { return }
            self.showToast(message)
        }
    }

    func start() {
        isStopping = false
        status = .starting

        guard let helperURL = MacCoreCatalog.helperExecutableURL() else {
            status = .failed("找不到内置模拟器宿主进程 GameCenterCoreHelper。请重新构建 Game Center。")
            return
        }
        guard let coreURL = MacCoreCatalog.coreURL(for: game.platform) else {
            status = .failed("找不到 \(game.platform.shortTitle) 的内置核心 \(descriptor.moduleName)。请运行 scripts/fetch-mac-cores.sh 或重新构建。")
            return
        }

        do {
            let context = try MacEmbeddedSaveBridge.prepare(
                platform: game.platform,
                rom: romURL,
                root: libraryRoot
            )
            saveContext = context
            refreshSaveSlots()

            let (parentChannel, childControlFD) = try ControlSocketChannel.makePair()
            controlChannel = parentChannel

            let pid = try spawnHelper(
                executableURL: helperURL,
                controlFD: childControlFD,
                inputFD: inputRegion.memory.fileDescriptor,
                frameFD: frameRing.memory.fileDescriptor
            )
            Darwin.close(childControlFD)
            helperPID = pid

            let exitSource = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
            exitSource.setEventHandler { [weak self] in
                guard let self else { return }
                var exitStatus: Int32 = 0
                _ = waitpid(pid, &exitStatus, WNOHANG)
                self.helperPID = 0
                self.processExitSource?.cancel()
                self.processExitSource = nil
                if !self.isStopping {
                    if case .failed = self.status { return }
                    let signalCode = exitStatus & 0x7f
                    let detail = signalCode != 0
                        ? "模拟器子进程异常终止（信号 \(signalCode)），Game Center 主程序未受影响。"
                        : "模拟器子进程已意外退出。"
                    self.status = .failed(detail)
                }
            }
            exitSource.resume()
            processExitSource = exitSource

            var mergedOptions = descriptor.defaultOptions
            for (k, v) in loadSavedCoreOptions() {
                mergedOptions[k] = v
            }

            let loadReq = CoreLoadRequest(
                corePath: coreURL.path,
                romPath: romURL.path,
                systemDir: context.systemDir.path,
                saveDir: context.saveDir.path,
                batteryPath: context.batteryURL?.path,
                moltenVKPath: MacCoreCatalog.moltenVKURL()?.path,
                initialOptions: mergedOptions
            )

            startEventReader(channel: parentChannel, loadRequest: loadReq)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func setPaused(_ paused: Bool) {
        guard case .running = status, paused else {
            if case .paused = status, !paused {
                status = .running
                inputCapture.setPaused(false)
                try? controlChannel?.send(HostCommand.setPaused(false))
            }
            return
        }
        status = .paused
        inputCapture.setPaused(true)
        try? controlChannel?.send(HostCommand.setPaused(true))
    }

    func togglePause() {
        switch status {
        case .running: setPaused(true)
        case .paused: setPaused(false)
        default: break
        }
    }

    func setFastForward(_ enabled: Bool) {
        fastForward = enabled
        inputCapture.setManualFastForward(enabled)
    }

    func updateAudio(volume: Float? = nil, muted: Bool? = nil) {
        if let volume { self.volume = min(max(volume, 0), 1) }
        if let muted { self.isMuted = muted }
        try? controlChannel?.send(HostCommand.setAudio(volume: self.volume, muted: self.isMuted))
    }

    func resetGame() {
        try? controlChannel?.send(HostCommand.reset)
        showToast("已重启游戏")
    }

    func setCoreOption(key: String, value: String) {
        try? controlChannel?.send(HostCommand.setOption(key: key, value: value))
        var saved = loadSavedCoreOptions()
        saved[key] = value
        persistCoreOptions(saved)
    }

    func cycleDualScreenLayout() {
        let layoutKey: String
        let layouts: [(value: String, label: String)]
        switch game.platform {
        case .nds:
            layoutKey = "desmume_screens_layout"
            layouts = [
                ("top/bottom", "上下双屏"),
                ("left/right", "左右并排"),
                ("hybrid/top", "主屏放大"),
                ("top only", "仅主屏")
            ]
        case .threeDS:
            layoutKey = "citra_layout_option"
            layouts = [
                ("default", "上下双屏"),
                ("side_by_side", "左右并排"),
                ("large_screen", "主屏放大"),
                ("single_screen", "仅主屏")
            ]
        default:
            return
        }
        let current = coreOptions.first(where: { $0.key == layoutKey })?.currentValue
            ?? loadSavedCoreOptions()[layoutKey]
            ?? layouts[0].value
        let nextIndex = ((layouts.firstIndex(where: { $0.value == current }) ?? -1) + 1) % layouts.count
        let next = layouts[nextIndex]
        setCoreOption(key: layoutKey, value: next.value)
        showToast("屏幕布局：\(next.label)")
    }

    func saveState(slot: Int) {
        guard let info = saveSlots.first(where: { $0.slot == slot }) else { return }
        let reqID = UUID().uuidString
        pendingActions[reqID] = { [weak self] ok, message in
            guard let self else { return }
            if ok {
                self.captureCurrentFrameThumbnail(to: info.thumbnailURL)
                self.refreshSaveSlots()
                self.showToast("已保存到即时存档槽位 \(slot)")
            } else {
                self.showToast(message ?? "保存即时存档失败")
            }
        }
        try? controlChannel?.send(HostCommand.saveState(requestID: reqID, path: info.stateURL.path))
    }

    func loadState(slot: Int) {
        guard let info = saveSlots.first(where: { $0.slot == slot }), info.exists else {
            showToast("槽位 \(slot) 暂无存档")
            return
        }
        let reqID = UUID().uuidString
        pendingActions[reqID] = { [weak self] ok, message in
            guard let self else { return }
            self.showToast(ok ? "已读取即时存档槽位 \(slot)" : (message ?? "读取即时存档失败"))
        }
        try? controlChannel?.send(HostCommand.loadState(requestID: reqID, path: info.stateURL.path))
    }

    func restartAfterFailure() {
        stopSync()
        start()
    }

    /// Synchronously flushes battery SRAM and cleanly terminates the helper process.
    func stopSync() {
        guard !isStopping else { return }
        isStopping = true
        inputCapture.detach()

        if let channel = controlChannel {
            try? channel.send(HostCommand.flushSave(requestID: "shutdown-flush"))
            try? channel.send(HostCommand.shutdown)
            channel.close()
            controlChannel = nil
        }

        let pid = helperPID
        if pid > 0 {
            let deadline = Date().addingTimeInterval(1.2)
            var exited = false
            var st: Int32 = 0
            while Date() < deadline {
                if waitpid(pid, &st, WNOHANG) == pid {
                    exited = true
                    break
                }
                usleep(15_000)
            }
            if !exited {
                kill(pid, SIGTERM)
                usleep(120_000)
                if waitpid(pid, &st, WNOHANG) != pid {
                    kill(pid, SIGKILL)
                    _ = waitpid(pid, &st, 0)
                }
            }
            helperPID = 0
        }

        processExitSource?.cancel()
        processExitSource = nil
        pendingActions.removeAll()
        toastTask?.cancel()
    }

    private func startEventReader(channel: ControlSocketChannel, loadRequest: CoreLoadRequest) {
        let reader = Thread { [weak self] in
            while true {
                do {
                    let event = try channel.receive(HelperEvent.self)
                    Task { @MainActor [weak self] in
                        self?.handle(event: event, channel: channel, loadRequest: loadRequest)
                    }
                } catch {
                    break
                }
            }
        }
        reader.name = "GameCenter.CoreSessionReader"
        reader.start()
    }

    private func handle(event: HelperEvent, channel: ControlSocketChannel, loadRequest: CoreLoadRequest) {
        switch event {
        case .ready:
            try? channel.send(HostCommand.setAudio(volume: volume, muted: isMuted))
            try? channel.send(HostCommand.load(loadRequest))

        case .loaded(let info):
            fps = info.fps
            coreOptions = info.options
            status = .running
            inputCapture.setPaused(false)

        case .optionsUpdated(let updated):
            coreOptions = updated

        case .actionResult(let reqID, let ok, let message):
            if let callback = pendingActions.removeValue(forKey: reqID) {
                callback(ok, message)
            }

        case .fatalError(let message):
            status = .failed(message)
        }
    }

    private func showToast(_ text: String) {
        toastTask?.cancel()
        statusToast = text
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if !Task.isCancelled {
                self?.statusToast = nil
            }
        }
    }

    private func refreshSaveSlots() {
        guard let dir = saveContext?.statesDir else { return }
        let fm = FileManager.default
        saveSlots = (1...5).map { slot in
            let stateURL = dir.appendingPathComponent("slot-\(slot).state")
            let thumbURL = dir.appendingPathComponent("slot-\(slot).png")
            let attrs = try? fm.attributesOfItem(atPath: stateURL.path)
            let modified = attrs?[.modificationDate] as? Date
            return EmbeddedSaveSlotInfo(slot: slot, stateURL: stateURL, thumbnailURL: thumbURL, modifiedAt: modified)
        }
    }

    private func captureCurrentFrameThumbnail(to url: URL) {
        guard let latest = frameRing.latestFrame(after: 0),
              let ptr = frameRing.pixelBufferPointer(slotIndex: latest.slotIndex) else { return }
        let byteCount = latest.bytesPerRow * latest.height
        let data = Data(bytes: ptr, count: byteCount)
        guard let provider = CGDataProvider(data: data as CFData) else { return }
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let cgImage = CGImage(
            width: latest.width,
            height: latest.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: latest.bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else { return }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: url, options: .atomic)
        }
    }

    private func coreOptionsFileURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = support.appendingPathComponent("Game Center/CoreOptions", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("\(game.platform.id).json")
    }

    private func loadSavedCoreOptions() -> [String: String] {
        guard let data = try? Data(contentsOf: coreOptionsFileURL()),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return dict
    }

    private func persistCoreOptions(_ values: [String: String]) {
        if let data = try? JSONEncoder().encode(values) {
            try? data.write(to: coreOptionsFileURL(), options: .atomic)
        }
    }

    /// Launches `GameCenterCoreHelper` via `posix_spawn`, explicitly mapping control/input/frame FDs
    /// to descriptors 3, 4, and 5 so Foundation's `Process` (`POSIX_SPAWN_CLOEXEC_DEFAULT`) cannot close them.
    private func spawnHelper(
        executableURL: URL,
        controlFD: Int32,
        inputFD: Int32,
        frameFD: Int32
    ) throws -> pid_t {
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        let targetControl: Int32 = 3
        let targetInput: Int32 = 4
        let targetFrame: Int32 = 5

        // Duplicate to high temporary descriptors first to avoid collisions if source FDs happen to be 3/4/5.
        let tmpControl = fcntl(controlFD, F_DUPFD_CLOEXEC, 32)
        let tmpInput = fcntl(inputFD, F_DUPFD_CLOEXEC, 32)
        let tmpFrame = fcntl(frameFD, F_DUPFD_CLOEXEC, 32)
        guard tmpControl >= 0, tmpInput >= 0, tmpFrame >= 0 else {
            if tmpControl >= 0 { Darwin.close(tmpControl) }
            if tmpInput >= 0 { Darwin.close(tmpInput) }
            if tmpFrame >= 0 { Darwin.close(tmpFrame) }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "无法准备子进程通信描述符"])
        }
        defer {
            Darwin.close(tmpControl)
            Darwin.close(tmpInput)
            Darwin.close(tmpFrame)
        }

        posix_spawn_file_actions_adddup2(&fileActions, tmpControl, targetControl)
        posix_spawn_file_actions_adddup2(&fileActions, tmpInput, targetInput)
        posix_spawn_file_actions_adddup2(&fileActions, tmpFrame, targetFrame)

        let argvStrings = [
            executableURL.path,
            "--control-fd", "\(targetControl)",
            "--input-fd", "\(targetInput)",
            "--frame-fd", "\(targetFrame)"
        ]
        var cArgs: [UnsafeMutablePointer<CChar>?] = argvStrings.map { strdup($0) }
        cArgs.append(nil)
        defer {
            for ptr in cArgs where ptr != nil { free(ptr) }
        }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executableURL.path, &fileActions, nil, &cArgs, environ)
        guard rc == 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(rc),
                userInfo: [NSLocalizedDescriptionKey: "无法启动模拟器子进程 (posix_spawn: \(rc))"]
            )
        }
        return pid
    }
}
