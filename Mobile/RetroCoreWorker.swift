import Foundation

/// All libretro calls share one serial queue because the ABI uses global callbacks.
final class RetroCoreWorker: @unchecked Sendable {
    static let queue = DispatchQueue(label: "GameCenter.RetroCore", qos: .userInitiated)
    private var core: OpaquePointer?
    private var sequence: UInt64 = 0
    private var audioScratch = [Int16](repeating: 0, count: 32768)

    struct Output: Sendable {
        let pixels: Data?
        let width: Int
        let height: Int
        let audio: [Int16]
    }

    func open(module: String, rom: String, bios: String, saves: String) throws -> (Double, Double) {
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
        return (fps, gc_retro_sample_rate(core))
    }

    func step(count: Int, buttons: UInt16, axes: [Int16], pointer: (Int16, Int16, Bool), save: Bool) -> Output {
        guard let core else { return .init(pixels: nil, width: 0, height: 0, audio: []) }
        gc_retro_set_analog(core, axes[0], axes[1], axes[2], axes[3])
        gc_retro_set_pointer(core, pointer.0, pointer.1, pointer.2)
        for _ in 0..<count { gc_retro_run(core, buttons) }
        if save { gc_retro_save(core) }
        let frames = audioScratch.withUnsafeMutableBufferPointer { gc_retro_audio(core, $0.baseAddress, $0.count / 2) }
        let samples = frames > 0 ? Array(audioScratch.prefix(frames * 2)) : []
        var width: Int32 = 0, height: Int32 = 0
        var serial: UInt64 = 0
        let frame = gc_retro_frame(core, &width, &height, &serial)
        var pixels: Data?
        if let frame, serial != sequence, width > 0, height > 0 {
            pixels = Data(bytes: frame, count: Int(width) * Int(height) * 4)
            sequence = serial
        }
        return .init(pixels: pixels, width: Int(width), height: Int(height), audio: samples)
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
