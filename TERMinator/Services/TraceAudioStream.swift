import Foundation

/// Sound from a TRACE module (engine contract: TE_OUT_AUDIO records, S16 stereo at TE_AUDIO_RATE = 44100). The module
/// writes frames as it makes them and this carries them into TERMinator's own output, so the player's volume control
/// covers module sound like everything else. A short queue holds them in between; when it runs dry the mix gets
/// silence rather than a glitch, and TERMinator keeps telling the module how much room is left (TE_IN_AUDIO_ROOM) so
/// it never runs ahead.
///
/// Port of the Windows client's `Services/TraceAudioStream.cs`. Windows adds it to `AudioOutput.Effects`; macOS has
/// no shared mixer, so `SyncTermAudioService` (the SyncTERM door mix, running from connect to disconnect) pulls every
/// registered stream in its render block and plays it at the same soundtrack volume.
final class TraceAudioStream {
    /// Half a second of stereo frames: enough to ride out a stall, short enough to stay responsive.
    static let capacityFrames = 22050

    private let capacitySamples = TraceAudioStream.capacityFrames * 2
    private let ring: UnsafeMutablePointer<Int16>
    private let lock = NSLock()
    private var readIndex = 0   // samples (not frames)
    private var count = 0

    init() {
        ring = UnsafeMutablePointer<Int16>.allocate(capacity: TraceAudioStream.capacityFrames * 2)
        ring.initialize(repeating: 0, count: TraceAudioStream.capacityFrames * 2)
    }

    deinit {
        ring.deallocate()
    }

    /// Frames the queue can still take.
    var roomFrames: Int {
        lock.lock()
        defer { lock.unlock() }
        return (capacitySamples - count) / 2
    }

    /// Queues interleaved S16 stereo samples from a module. Returns the frames taken (the rest is dropped: the module
    /// was too fast).
    @discardableResult
    func write(_ samples: UnsafePointer<Int16>, sampleCount: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let take = min(sampleCount, capacitySamples - count)
        var write = (readIndex + count) % capacitySamples
        for i in 0..<max(0, take) {
            ring[write] = samples[i]
            write = write + 1 == capacitySamples ? 0 : write + 1
        }
        count += max(0, take)
        return max(0, take) / 2
    }

    /// Throws away what's queued (the module stopped, or its sound is no longer wanted).
    func clear() {
        lock.lock()
        readIndex = 0
        count = 0
        lock.unlock()
    }

    /// Adds up to `frames` queued frames into the two channel buffers, scaled by `scale` (gain / 32768), from
    /// frame `offset`. An underrun leaves the rest as it was (silence, or the door mix). Called on the audio thread.
    func mix(into left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>?, offset: Int, frames: Int,
             scale: Float) {
        lock.lock()
        defer { lock.unlock() }
        let take = min(frames, count / 2)
        for i in 0..<max(0, take) {
            let l = Float(ring[readIndex]) * scale
            readIndex = readIndex + 1 == capacitySamples ? 0 : readIndex + 1
            let r = Float(ring[readIndex]) * scale
            readIndex = readIndex + 1 == capacitySamples ? 0 : readIndex + 1
            left[offset + i] += l
            if let right = right {
                right[offset + i] += r
            }
        }
        count -= max(0, take) * 2
    }
}
