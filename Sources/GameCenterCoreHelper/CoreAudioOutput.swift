import AudioToolbox
import Foundation
import os

/// Low-latency stereo Int16 audio output backed by CoreAudio's DefaultOutput AudioUnit.
final class CoreAudioOutput: @unchecked Sendable {
    private var audioUnit: AudioComponentInstance?
    private let capacityFrames: Int
    private var ringBuffer: [Int16]
    private var readIndex: Int = 0
    private var writeIndex: Int = 0
    private var availableFrames: Int = 0
    private var lock = os_unfair_lock_s()
    private var volume: Float = 1.0
    private var muted: Bool = false
    private var running: Bool = false

    init(capacityFrames: Int = 16384) {
        self.capacityFrames = capacityFrames
        self.ringBuffer = [Int16](repeating: 0, count: capacityFrames * 2)
    }

    deinit {
        stop()
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
        os_unfair_lock_lock(&lock)
        readIndex = 0
        writeIndex = 0
        availableFrames = 0
        os_unfair_lock_unlock(&lock)
    }

    func setAudio(volume: Float, muted: Bool) {
        os_unfair_lock_lock(&lock)
        self.volume = min(max(volume, 0), 1)
        self.muted = muted
        os_unfair_lock_unlock(&lock)
    }

    /// Fraction of the target buffer (~64 ms) currently filled, used for gentle frame pacing adjustment.
    func fillRatio(targetFrames: Int) -> Double {
        os_unfair_lock_lock(&lock)
        let avail = availableFrames
        os_unfair_lock_unlock(&lock)
        return Double(avail) / Double(max(targetFrames, 1))
    }

    func enqueue(samples: UnsafePointer<Int16>, frameCount: Int) {
        guard running, frameCount > 0 else { return }
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        let freeFrames = capacityFrames - availableFrames
        let toWrite = min(frameCount, freeFrames)
        guard toWrite > 0 else { return }

        let firstChunk = min(toWrite, capacityFrames - writeIndex)
        ringBuffer.withUnsafeMutableBufferPointer { dst in
            guard let base = dst.baseAddress else { return }
            base.advanced(by: writeIndex * 2).update(from: samples, count: firstChunk * 2)
            let remaining = toWrite - firstChunk
            if remaining > 0 {
                base.update(from: samples.advanced(by: firstChunk * 2), count: remaining * 2)
            }
        }
        writeIndex = (writeIndex + toWrite) % capacityFrames
        availableFrames += toWrite
    }

    private func render(ioData: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) {
        let buffers = UnsafeMutableAudioBufferListPointer(ioData)
        guard let first = buffers.first, let mData = first.mData else { return }
        let outPtr = mData.assumingMemoryBound(to: Int16.self)

        os_unfair_lock_lock(&lock)
        let toRead = min(frameCount, availableFrames)
        let gain = muted ? 0.0 : volume
        if toRead > 0 {
            let firstChunk = min(toRead, capacityFrames - readIndex)
            ringBuffer.withUnsafeBufferPointer { src in
                guard let base = src.baseAddress else { return }
                if gain == 1.0 {
                    outPtr.update(from: base.advanced(by: readIndex * 2), count: firstChunk * 2)
                    let rem = toRead - firstChunk
                    if rem > 0 {
                        outPtr.advanced(by: firstChunk * 2).update(from: base, count: rem * 2)
                    }
                } else if gain <= 0.0001 {
                    memset(outPtr, 0, toRead * 4)
                } else {
                    for i in 0..<(firstChunk * 2) {
                        outPtr[i] = Int16(max(-32768, min(32767, Int(Float(base[readIndex * 2 + i]) * gain))))
                    }
                    let rem = toRead - firstChunk
                    for i in 0..<(rem * 2) {
                        outPtr[firstChunk * 2 + i] = Int16(max(-32768, min(32767, Int(Float(base[i]) * gain))))
                    }
                }
            }
            readIndex = (readIndex + toRead) % capacityFrames
            availableFrames -= toRead
        }
        os_unfair_lock_unlock(&lock)

        if toRead < frameCount {
            memset(outPtr.advanced(by: toRead * 2), 0, (frameCount - toRead) * 4)
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
