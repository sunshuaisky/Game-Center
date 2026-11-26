import CRetroHost
import Darwin
import Foundation

public enum SharedMemoryError: LocalizedError {
    case createFailed(Int32)
    case resizeFailed(Int32)
    case mapFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .createFailed(let code): "无法创建共享内存文件描述符 (errno \(code))"
        case .resizeFailed(let code): "无法分配共享内存大小 (errno \(code))"
        case .mapFailed(let code): "无法映射共享内存区域 (errno \(code))"
        }
    }
}

/// Anonymous unlinked temporary-file-backed shared memory region.
/// Works identically in bare SwiftPM debug runs (`dev.sh`) and bundled `.app` builds,
/// and leaves zero files behind even if either process is killed with SIGKILL.
public final class AnonymousSharedMemory: @unchecked Sendable {
    public let fileDescriptor: Int32
    public let size: Int
    public let basePointer: UnsafeMutableRawPointer
    private var closed = false

    public init(size: Int) throws {
        let template = (NSTemporaryDirectory() as NSString).appendingPathComponent("gc-shm-XXXXXX")
        var buffer = Array(template.utf8CString)
        let fd = buffer.withUnsafeMutableBufferPointer { ptr in
            mkstemp(ptr.baseAddress)
        }
        guard fd >= 0 else { throw SharedMemoryError.createFailed(errno) }
        /* Unlink immediately while keeping the inode alive through open FDs. */
        buffer.withUnsafeBufferPointer { ptr in
            _ = unlink(ptr.baseAddress)
        }
        guard ftruncate(fd, off_t(size)) == 0 else {
            let err = errno
            Darwin.close(fd)
            throw SharedMemoryError.resizeFailed(err)
        }
        guard let mapped = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0),
              mapped != MAP_FAILED else {
            let err = errno
            Darwin.close(fd)
            throw SharedMemoryError.mapFailed(err)
        }
        self.fileDescriptor = fd
        self.size = size
        self.basePointer = mapped
    }

    public init(inheritedFileDescriptor fd: Int32, size: Int) throws {
        guard let mapped = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0),
              mapped != MAP_FAILED else {
            throw SharedMemoryError.mapFailed(errno)
        }
        self.fileDescriptor = fd
        self.size = size
        self.basePointer = mapped
    }

    deinit {
        close()
    }

    public func close() {
        guard !closed else { return }
        closed = true
        munmap(basePointer, size)
        if fileDescriptor >= 0 {
            Darwin.close(fileDescriptor)
        }
    }
}

public final class SharedInputRegion: @unchecked Sendable {
    public let memory: AnonymousSharedMemory
    private var lastSnapshot = GCSharedInputState()
    public var pointer: UnsafeMutablePointer<GCSharedInputState> {
        memory.basePointer.assumingMemoryBound(to: GCSharedInputState.self)
    }

    public init() throws {
        let size = max(Int(gc_shm_input_size()), 4096)
        memory = try AnonymousSharedMemory(size: size)
        memset(memory.basePointer, 0, size)
    }

    public init(inheritedFileDescriptor fd: Int32) throws {
        let size = max(Int(gc_shm_input_size()), 4096)
        memory = try AnonymousSharedMemory(inheritedFileDescriptor: fd, size: size)
    }

    public func write(
        buttonsPointer: UnsafePointer<UInt16>,
        axesPointer: UnsafePointer<Int16>,
        pointerX: Int16,
        pointerY: Int16,
        pointerPressed: Bool,
        mouseButtons: UInt8,
        mouseDXDelta: Int32 = 0,
        mouseDYDelta: Int32 = 0,
        mouseWheelDelta: Int32 = 0,
        fastForward: UInt8 = 1,
        paused: Bool = false
    ) {
        gc_shm_input_write(
            pointer,
            buttonsPointer,
            axesPointer,
            pointerX,
            pointerY,
            pointerPressed ? 1 : 0,
            mouseButtons,
            mouseDXDelta,
            mouseDYDelta,
            mouseWheelDelta,
            fastForward,
            paused ? 1 : 0
        )
    }

    public func write(
        buttons: [UInt16],
        axes: [Int16],
        pointerX: Int16,
        pointerY: Int16,
        pointerPressed: Bool,
        mouseButtons: UInt8,
        mouseDXDelta: Int32 = 0,
        mouseDYDelta: Int32 = 0,
        mouseWheelDelta: Int32 = 0,
        fastForward: UInt8 = 1,
        paused: Bool = false
    ) {
        var paddedButtons: (UInt16, UInt16, UInt16, UInt16) = (0, 0, 0, 0)
        var paddedAxes: (Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16, Int16) =
            (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeMutablePointer(to: &paddedButtons) { bRaw in
            bRaw.withMemoryRebound(to: UInt16.self, capacity: Int(GC_MAX_PLAYERS)) { bPtr in
                for i in 0..<min(buttons.count, Int(GC_MAX_PLAYERS)) { bPtr[i] = buttons[i] }
                withUnsafeMutablePointer(to: &paddedAxes) { aRaw in
                    aRaw.withMemoryRebound(to: Int16.self, capacity: Int(GC_MAX_PLAYERS) * 4) { aPtr in
                        for i in 0..<min(axes.count, Int(GC_MAX_PLAYERS) * 4) { aPtr[i] = axes[i] }
                        write(
                            buttonsPointer: bPtr,
                            axesPointer: aPtr,
                            pointerX: pointerX,
                            pointerY: pointerY,
                            pointerPressed: pointerPressed,
                            mouseButtons: mouseButtons,
                            mouseDXDelta: mouseDXDelta,
                            mouseDYDelta: mouseDYDelta,
                            mouseWheelDelta: mouseWheelDelta,
                            fastForward: fastForward,
                            paused: paused
                        )
                    }
                }
            }
        }
    }

    public func read() -> (snapshot: GCSharedInputState, mouseDX: Int32, mouseDY: Int32, mouseWheelY: Int32) {
        var snap = lastSnapshot
        var dx: Int32 = 0
        var dy: Int32 = 0
        var wy: Int32 = 0
        gc_shm_input_read(pointer, &snap, &dx, &dy, &wy)
        lastSnapshot = snap
        return (snap, dx, dy, wy)
    }
}

public struct SharedFrameSnapshot: Sendable {
    public let slotIndex: UInt32
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public let aspectRatio: Float
    public let sequence: UInt64
}

public final class SharedFrameRing: @unchecked Sendable {
    public let memory: AnonymousSharedMemory
    public var ringPointer: UnsafeMutablePointer<GCSharedFrameRing> {
        memory.basePointer.assumingMemoryBound(to: GCSharedFrameRing.self)
    }

    public init() throws {
        let size = Int(gc_shm_frame_ring_size())
        memory = try AnonymousSharedMemory(size: size)
        gc_shm_frame_init(ringPointer)
    }

    public init(inheritedFileDescriptor fd: Int32) throws {
        let size = Int(gc_shm_frame_ring_size())
        memory = try AnonymousSharedMemory(inheritedFileDescriptor: fd, size: size)
    }

    public func pixelBufferPointer(slotIndex: UInt32) -> UnsafeMutablePointer<UInt8>? {
        gc_shm_frame_slot_ptr(ringPointer, slotIndex)
    }

    public func nextWriteSlot() -> UInt32 {
        gc_shm_frame_next_write_slot(ringPointer)
    }

    public func commit(slotIndex: UInt32, width: UInt32, height: UInt32, bytesPerRow: UInt32, aspectRatio: Float) {
        gc_shm_frame_commit(ringPointer, slotIndex, width, height, bytesPerRow, aspectRatio)
    }

    public func latestFrame(after lastSeenSequence: UInt64) -> SharedFrameSnapshot? {
        var slot: UInt32 = 0
        var w: UInt32 = 0
        var h: UInt32 = 0
        var bpr: UInt32 = 0
        var aspect: Float = 4.0 / 3.0
        var seq: UInt64 = 0
        guard gc_shm_frame_latest(ringPointer, lastSeenSequence, &slot, &w, &h, &bpr, &aspect, &seq) else {
            return nil
        }
        return SharedFrameSnapshot(
            slotIndex: slot,
            width: Int(w),
            height: Int(h),
            bytesPerRow: Int(bpr),
            aspectRatio: aspect,
            sequence: seq
        )
    }
}
