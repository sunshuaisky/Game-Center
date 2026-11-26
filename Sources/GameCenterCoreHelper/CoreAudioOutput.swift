import AudioToolbox
import CRetroHost
import Foundation

/// Low-latency stereo Int16 audio output backed by CoreAudio's DefaultOutput AudioUnit
/// and a lock-free SPSC ring buffer so the real-time HAL render thread never blocks.
final class CoreAudioOutput: @unchecked Sendable {
    private var audioUnit: AudioComponentInstance?
    private let ring: OpaquePointer?
    private var volume: Float = 1.0
    private var muted: Bool = false
    private var running: Bool = false

    init(capacityFrames: UInt32 = 16384) {
        self.ring = gc_audio_ring_create(capacityFrames)
    }

    deinit {
        stop()
        if let ring {
            gc_audio_ring_destroy(ring)
        }
    }

    func start(sampleRate: Double) {
        stop()
        let rate = (sampleRate >= 8000 && sampleRate <= 192000) ? sampleRate : 44100.0

        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_DefaultOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &desc) else { return }

        var unit: AudioComponentInstance?
        guard AudioComponentInstanceNew(component, &unit) == noErr, let unit else { return }

        var asbd = AudioStreamBasicDescription(
            mSampleRate: rate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        let asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            0,
            &asbd,
            asbdSize
        ) == noErr else {
            AudioComponentInstanceDispose(unit)
            return
        }

        var callbackStruct = AURenderCallbackStruct(
            inputProc: CoreAudioOutput.renderCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        let cbSize = UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        guard AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Input,
            0,
            &callbackStruct,
            cbSize
        ) == noErr else {
            AudioComponentInstanceDispose(unit)
            return
        }

        guard AudioUnitInitialize(unit) == noErr else {
            AudioComponentInstanceDispose(unit)
            return
        }
        AudioUnitSetParameter(unit, kHALOutputParam_Volume, kAudioUnitScope_Output, 0, muted ? 0.0 : volume, 0)
        guard AudioOutputUnitStart(unit) == noErr else {
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            return
        }

        self.audioUnit = unit
        self.running = true
    }

    func stop() {
        if let unit = audioUnit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            audioUnit = nil
        }
        running = false
        clear()
    }

    func clear() {
        if let ring {
            gc_audio_ring_clear(ring)
        }
    }

    func setAudio(volume: Float, muted: Bool) {
        self.volume = min(max(volume, 0), 1)
        self.muted = muted
        if let ring {
            gc_audio_ring_set_muted(ring, muted || self.volume <= 0.0001)
        }
        if let unit = audioUnit {
            AudioUnitSetParameter(unit, kHALOutputParam_Volume, kAudioUnitScope_Output, 0, muted ? 0.0 : self.volume, 0)
        }
    }

    /// Fraction of the target buffer (~55 ms) currently filled, used for gentle frame pacing adjustment.
    func fillRatio(targetFrames: Int) -> Double {
        let avail = ring.map { Int(gc_audio_ring_available($0)) } ?? 0
        return Double(avail) / Double(max(targetFrames, 1))
    }

    func enqueue(samples: UnsafePointer<Int16>, frameCount: Int) {
        guard running, frameCount > 0, let ring else { return }
        _ = gc_audio_ring_write(ring, samples, UInt32(frameCount))
    }

    private func render(ioData: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) {
        let buffers = UnsafeMutableAudioBufferListPointer(ioData)
        guard let first = buffers.first, let mData = first.mData else { return }
        let outPtr = mData.assumingMemoryBound(to: Int16.self)

        let read = ring.map { Int(gc_audio_ring_read($0, outPtr, UInt32(frameCount))) } ?? 0
        if read < frameCount {
            memset(outPtr.advanced(by: read * 2), 0, (frameCount - read) * 4)
        }
    }

    private static let renderCallback: AURenderCallback = { (
        inRefCon,
        _,
        _,
        _,
        inNumberFrames,
        ioData
    ) -> OSStatus in
        guard let ioData else { return noErr }
        let output = Unmanaged<CoreAudioOutput>.fromOpaque(inRefCon).takeUnretainedValue()
        output.render(ioData: ioData, frameCount: Int(inNumberFrames))
        return noErr
    }
}
