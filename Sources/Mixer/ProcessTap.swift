import CoreAudio
import Foundation

/// Gain shared between the main thread (writer) and the real-time audio thread (reader).
final class TapState {
    var targetGain: Float
    var currentGain: Float
    /// Set by the audio thread once any non-silent sample arrives.
    var receivedSignal = false
    /// When set, audio goes to AirPlay instead of the output device.
    var airPlaySink: AirPlaySink?
    /// Preallocated interleaving buffer for the AirPlay path (frames * 2 channels).
    let scratchFrames = 16384
    let scratch: UnsafeMutablePointer<Float>

    init(gain: Float) {
        targetGain = gain
        currentGain = gain
        scratch = .allocate(capacity: scratchFrames * 2)
        scratch.initialize(repeating: 0, count: scratchFrames * 2)
    }

    deinit { scratch.deallocate() }
}

/// Captures the audio of a group of processes (silencing their normal output),
/// applies a gain, and plays the result on a chosen output device.
final class ProcessTap {
    let processObjectIDs: [AudioObjectID]
    let outputUID: String
    let toAirPlay: Bool
    let createdAt = Date()

    private let state: TapState
    private var tapID = AudioObjectID.unknown
    private var aggregateID = AudioObjectID.unknown
    private var ioProcID: AudioDeviceIOProcID?
    private var isInvalidated = false

    var receivedSignal: Bool { state.receivedSignal }

    /// - Parameter toAirPlay: send the audio to Mixer's AirPlay destination; `outputUID`
    ///   then only provides the clock and stays silent.
    init(processObjectIDs: [AudioObjectID], outputUID: String, toAirPlay: Bool = false, gain: Float) throws {
        self.processObjectIDs = processObjectIDs
        self.outputUID = outputUID
        self.toAirPlay = toAirPlay
        self.state = TapState(gain: gain)
        do {
            try start()
        } catch {
            invalidate()
            throw error
        }
    }

    deinit { invalidate() }

    func setGain(_ gain: Float) {
        state.targetGain = gain
    }

    private func start() throws {
        let description = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        description.uuid = UUID()
        description.name = "Mixer per-app volume"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped

        try check(AudioHardwareCreateProcessTap(description, &tapID), "Creating the audio tap")

        let format = try tapID.get(propertyAddress(kAudioTapPropertyFormat), initial: AudioStreamBasicDescription())
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32
        else {
            throw CoreAudioError(status: -1, context: "Unsupported tap format")
        }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Mixer Output",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "Creating the output device")

        if toAirPlay {
            let rate = (try? aggregateID.get(propertyAddress(kAudioDevicePropertyNominalSampleRate), initial: Float64(0)))
                ?? format.mSampleRate
            state.airPlaySink = try AirPlaySink(sampleRate: rate > 0 ? rate : format.mSampleRate)
        }

        let state = self.state
        try check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) { _, input, _, output, _ in
            TapRenderer.render(input: input, output: output, state: state)
        }, "Creating the audio callback")

        try check(AudioDeviceStart(aggregateID, ioProcID), "Starting audio")
    }

    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        if aggregateID != .unknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != .unknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        state.airPlaySink?.stop()
        state.airPlaySink = nil
        ioProcID = nil
        aggregateID = .unknown
        tapID = .unknown
    }
}

/// Real-time safe rendering: no allocation, no locks.
enum TapRenderer {
    static func render(
        input: UnsafePointer<AudioBufferList>,
        output: UnsafeMutablePointer<AudioBufferList>,
        state: TapState
    ) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)

        var inputChannels = 0
        for buffer in inputs { inputChannels += Int(buffer.mNumberChannels) }

        let startGain = state.currentGain
        let endGain = state.targetGain
        let limit = max(startGain, endGain) > 1.0001

        if let sink = state.airPlaySink {
            for buffer in outputs {
                if let raw = buffer.mData { memset(raw, 0, Int(buffer.mDataByteSize)) }
            }
            guard inputChannels > 0,
                  let left = channelPointer(inputs, 0),
                  let right = channelPointer(inputs, min(1, inputChannels - 1))
            else { return }
            let count = min(left.frames, right.frames, state.scratchFrames)
            guard count > 0 else { return }
            let step = (endGain - startGain) / Float(count)
            var gain = startGain
            var sawSignal = false
            let out = state.scratch
            for frame in 0..<count {
                gain += step
                let l = left.pointer[frame * left.stride]
                let r = right.pointer[frame * right.stride]
                if l != 0 || r != 0 { sawSignal = true }
                out[frame * 2] = limit ? softClip(l * gain) : l * gain
                out[frame * 2 + 1] = limit ? softClip(r * gain) : r * gain
            }
            if sawSignal { state.receivedSignal = true }
            sink.ring.write(out, frames: count)
            state.currentGain = endGain
            return
        }

        var outputChannel = 0
        for buffer in outputs {
            guard let raw = buffer.mData else { continue }
            memset(raw, 0, Int(buffer.mDataByteSize))
            let channels = Int(buffer.mNumberChannels)
            guard channels > 0 else { continue }
            let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            let out = raw.assumingMemoryBound(to: Float.self)

            for channel in 0..<channels {
                let globalChannel = outputChannel + channel
                // Stereo source goes to the device's first two channels.
                guard globalChannel < 2, inputChannels > 0,
                      let source = channelPointer(inputs, min(globalChannel, inputChannels - 1))
                else { continue }

                let count = min(frames, source.frames)
                guard count > 0 else { continue }
                let step = (endGain - startGain) / Float(count)
                var gain = startGain
                var sawSignal = false
                for frame in 0..<count {
                    gain += step
                    let sample = source.pointer[frame * source.stride]
                    if sample != 0 { sawSignal = true }
                    let scaled = sample * gain
                    out[frame * channels + channel] = limit ? softClip(scaled) : scaled
                }
                if sawSignal { state.receivedSignal = true }
            }
            outputChannel += channels
        }
        state.currentGain = endGain
    }

    private static func channelPointer(
        _ list: UnsafeMutableAudioBufferListPointer, _ index: Int
    ) -> (pointer: UnsafePointer<Float>, stride: Int, frames: Int)? {
        var remaining = index
        for buffer in list {
            let channels = Int(buffer.mNumberChannels)
            if remaining < channels {
                guard let data = buffer.mData, channels > 0 else { return nil }
                let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
                return (UnsafePointer(data.assumingMemoryBound(to: Float.self)) + remaining, channels, frames)
            }
            remaining -= channels
        }
        return nil
    }

    /// Gentle limiter used only when boosting, so loud peaks round off instead of crackling.
    @inline(__always)
    private static func softClip(_ x: Float) -> Float {
        let magnitude = abs(x)
        guard magnitude > 0.8 else { return x }
        let shaped = 0.8 + 0.2 * tanhf((magnitude - 0.8) / 0.2)
        return x < 0 ? -shaped : shaped
    }
}
