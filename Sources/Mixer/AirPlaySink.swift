import AVFoundation
import CoreMedia
import Foundation
import os

/// Single-producer / single-consumer ring of interleaved stereo Float32 frames.
final class AudioRingBuffer {
    private let capacity: Int  // in frames
    private let storage: UnsafeMutablePointer<Float>
    private var writeIndex = 0
    private var readIndex = 0
    private var count = 0
    private let lock = OSAllocatedUnfairLock()

    init(capacityFrames: Int) {
        capacity = capacityFrames
        storage = .allocate(capacity: capacityFrames * 2)
        storage.initialize(repeating: 0, count: capacityFrames * 2)
    }

    deinit { storage.deallocate() }

    var availableFrames: Int { lock.withLock { count } }

    /// Called from the real-time thread. Drops the oldest audio if the reader falls behind.
    func write(_ source: UnsafePointer<Float>, frames: Int) {
        lock.withLock {
            for frame in 0..<frames {
                storage[writeIndex * 2] = source[frame * 2]
                storage[writeIndex * 2 + 1] = source[frame * 2 + 1]
                writeIndex = (writeIndex + 1) % capacity
                if count == capacity {
                    readIndex = (readIndex + 1) % capacity
                } else {
                    count += 1
                }
            }
        }
    }

    /// Copies up to `frames` frames into `destination`; returns how many were copied.
    func read(into destination: UnsafeMutablePointer<Float>?, frames: Int) -> Int {
        lock.withLock {
            let n = min(frames, count)
            for frame in 0..<n {
                if let destination {
                    destination[frame * 2] = storage[readIndex * 2]
                    destination[frame * 2 + 1] = storage[readIndex * 2 + 1]
                }
                readIndex = (readIndex + 1) % capacity
            }
            count -= n
            return n
        }
    }
}

/// Plays captured audio through AVFoundation, which follows the AirPlay
/// destination chosen with Mixer's AirPlay button (instead of the Mac's output).
final class AirPlaySink {
    let ring: AudioRingBuffer

    private let sampleRate: Double
    private let renderer = AVSampleBufferAudioRenderer()
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private let queue = DispatchQueue(label: "mixer.airplay.sink", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var format: CMAudioFormatDescription?
    private var framesEnqueued: Int64 = 0
    private var started = false

    /// How far ahead of playback we try to keep queued audio.
    private let prerollSeconds = 0.25
    private let maxLeadSeconds = 0.8

    init(sampleRate: Double) throws {
        self.sampleRate = sampleRate
        ring = AudioRingBuffer(capacityFrames: Int(sampleRate * 3))

        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        try check(CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format),
            "Creating the AirPlay audio format")

        synchronizer.addRenderer(renderer)

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10))
        timer.setEventHandler { [weak self] in self?.pump() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
        queue.sync {
            synchronizer.setRate(0, time: .zero)
            renderer.flush()
            synchronizer.removeRenderer(renderer, at: .zero)
        }
    }

    deinit { stop() }

    private func pump() {
        let available = ring.availableFrames

        guard started else {
            if Double(available) >= sampleRate * prerollSeconds {
                enqueue(frames: available)
                synchronizer.setRate(1, time: .zero)
                started = true
            }
            return
        }

        if renderer.status == .failed {
            renderer.flush()
            framesEnqueued = 0
            started = false
            synchronizer.setRate(0, time: .zero)
            return
        }

        let now = synchronizer.currentTime().seconds
        let queuedEnd = Double(framesEnqueued) / sampleRate
        let lead = queuedEnd - now

        if lead > maxLeadSeconds, available > 0 {
            // Clocks drifted apart: skip a little audio to keep the delay short.
            let excess = Int((lead - prerollSeconds) * sampleRate)
            _ = ring.read(into: nil, frames: min(excess, available))
        }

        let ready = ring.availableFrames
        if ready > 0 {
            enqueue(frames: ready)
        } else if lead < 0.03 {
            enqueueSilence(frames: Int(sampleRate * 0.05))
        }
    }

    private func enqueue(frames: Int) {
        makeBuffer(frames: frames) { pointer in
            let copied = ring.read(into: pointer, frames: frames)
            if copied < frames {
                (pointer + copied * 2).update(repeating: 0, count: (frames - copied) * 2)
            }
        }
    }

    private func enqueueSilence(frames: Int) {
        makeBuffer(frames: frames) { $0.update(repeating: 0, count: frames * 2) }
    }

    private func makeBuffer(frames: Int, fill: (UnsafeMutablePointer<Float>) -> Void) {
        guard frames > 0, let format else { return }
        let bytes = frames * 8
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
            let block
        else { return }

        var data: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(
            block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: nil, dataPointerOut: &data) == noErr,
            let data
        else { return }
        data.withMemoryRebound(to: Float.self, capacity: frames * 2) { fill($0) }

        var sample: CMSampleBuffer?
        let pts = CMTime(value: framesEnqueued, timescale: CMTimeScale(sampleRate))
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: frames, presentationTimeStamp: pts, packetDescriptions: nil,
            sampleBufferOut: &sample) == noErr,
            let sample
        else { return }

        renderer.enqueue(sample)
        framesEnqueued += Int64(frames)
    }
}
