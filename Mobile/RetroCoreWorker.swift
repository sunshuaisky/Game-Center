import Foundation

/// All libretro calls share one serial queue because the ABI uses global callbacks.
final class RetroCoreWorker: @unchecked Sendable {
    static let queue = DispatchQueue(label: "GameCenter.RetroCore", qos: .userInitiated)
    private var core: OpaquePointer?
    private var sequence: UInt64 = 0
    private var audioScratch = [Int16](repeating: 0, count: 32768)

    struct OpenInfo: Sendable {
        let fps: Double
        let sampleRate: Double
        let isHardwareRendered: Bool
        let jitAvailable: Bool
    }

    struct Output: @unchecked Sendable {
        let presentedFrame: Bool
        let audio: [Int16]
        let shutdownRequested: Bool
        let lastLogError: String?
    }

    func open(
        module: String,
        rom: String,
        bios: String,
        saves: String,
        moltenVKPath: String?,
        performanceProfile: Int
    ) throws -> OpenInfo {
        if let moltenVKPath, !moltenVKPath.isEmpty {
            gc_retro_set_moltenvk_path(moltenVKPath)
        } else {
            gc_retro_set_moltenvk_path(nil)
        }
        gc_retro_set_performance_profile(Int32(performanceProfile))
        guard let core = gc_retro_open(module, rom, bios, saves) else {
            throw Failure(String(cString: gc_retro_error()))
        }
        self.core = core
        let fps = gc_retro_fps(core)
        guard fps.isFinite, fps > 0, fps < 240 else {
            gc_retro_close(core)
            self.core = nil
            throw Failure("核心返回了无效的帧率")
        }
        return OpenInfo(
            fps: fps,
            sampleRate: gc_retro_sample_rate(core),
            isHardwareRendered: gc_retro_is_hw_rendered(core),
            jitAvailable: gc_ios_jit_available()
        )
    }

    func setPerformanceProfile(_ profile: Int) {
        gc_retro_set_performance_profile(Int32(profile))
        if let core {
            gc_retro_apply_performance_profile(core, Int32(profile))
        }
    }

    func step(
        count: Int,
        buttons: UInt16,
        axes: [Int16],
        pointer: (Int16, Int16, Bool),
        save: Bool,
        smoothVideo: Bool,
        presentFrame: (UnsafeRawPointer, Int, Int, Bool) -> Void
    ) -> Output {
        guard let core else {
            return .init(presentedFrame: false, audio: [], shutdownRequested: false, lastLogError: nil)
        }
        gc_retro_set_analog(core, axes[0], axes[1], axes[2], axes[3])
        gc_retro_set_pointer(core, pointer.0, pointer.1, pointer.2)
        for _ in 0..<count {
            gc_retro_run(core, buttons)
            if gc_retro_shutdown_requested(core) { break }
        }
        if save { gc_retro_save(core) }
        let frames = audioScratch.withUnsafeMutableBufferPointer { gc_retro_audio(core, $0.baseAddress, $0.count / 2) }
        let samples = frames > 0 ? Array(audioScratch.prefix(frames * 2)) : []
        var width: Int32 = 0, height: Int32 = 0
        var serial: UInt64 = 0
        var presented = false
        if let frame = gc_retro_frame(core, &width, &height, &serial),
           serial != sequence, width > 0, height > 0 {
            presentFrame(frame, Int(width), Int(height), smoothVideo)
            sequence = serial
            presented = true
        }
        let shutdown = gc_retro_shutdown_requested(core)
        let logErr: String? = shutdown ? {
            let text = String(cString: gc_retro_last_log_error())
            return text.isEmpty ? nil : text
        }() : nil
        return .init(presentedFrame: presented, audio: samples, shutdownRequested: shutdown, lastLogError: logErr)
    }

    func save() {
        if let core { gc_retro_save(core) }
    }

    func close() {
        if let core { gc_retro_close(core) }
        core = nil
        sequence = 0
    }

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
