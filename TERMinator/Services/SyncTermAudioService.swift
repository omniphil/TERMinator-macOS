import Foundation
import AVFoundation
import os.log

private let logger = Logger(subsystem: "com.terminator.macos", category: "SyncTermAudio")

/// Plays the SyncTERM audio APC mix (`ESC _ SyncTERM:A;...`) that doors such as SyncDOOM drive: the native mixer
/// in `Bridge/apc/apc_mixer.c` holds the channels, and this pulls its S16 stereo 44.1 kHz output through an
/// `AVAudioSourceNode` (the same shape as `ModPlayer`).
///
/// Mirrors the Windows client's `AudioService.PrepareSyncTermAudio` / `SyncTermAudioSource`:
/// * the mix is **pulled even when silent or muted**, so native channels drain and `A;Update` notifications and
///   `A;Wait` still resolve;
/// * it plays at the soundtrack volume (`soundtrack_volume` × the master gain) and is silent while
///   `soundtrack_enabled` is off — and native is told so, so doors hear there is no audio.
///
/// Unlike Windows (one always-open mixer input), macOS has no shared output to join, so this owns an engine that
/// runs from connect to disconnect.
final class SyncTermAudioService {

    static let shared = SyncTermAudioService()

    private static let sampleRate: Double = 44100
    /// Same as `SoundtrackManager.masterGain`
    private static let masterGain: Float = 0.85
    /// Frames pulled per native call; the render block loops for anything larger.
    private static let chunkFrames = 4096

    private var engine: AVAudioEngine?
    private var defaultsObserver: NSObjectProtocol?
    private var configObserver: NSObjectProtocol?
    /// Read on the audio thread, written on the main thread. A torn read of a Float costs one buffer's volume.
    private var gain: Float = 0
    /// S16 interleaved scratch for the render block, allocated once (no allocation on the audio thread).
    private let pcm = UnsafeMutablePointer<Int16>.allocate(capacity: SyncTermAudioService.chunkFrames * 2)

    private init() {
        pcm.initialize(repeating: 0, count: Self.chunkFrames * 2)
    }

    // MARK: - TRACE module sound

    private static let traceLock = NSLock()
    private static var traceStreams: [TraceAudioStream] = []

    /// A running TRACE module's sound joins the mix (EngineModuleHost, once the module first makes sound).
    static func addTraceStream(_ stream: TraceAudioStream) {
        traceLock.lock()
        if !traceStreams.contains(where: { $0 === stream }) {
            traceStreams.append(stream)
        }
        traceLock.unlock()
    }

    /// The module stopped.
    static func removeTraceStream(_ stream: TraceAudioStream) {
        traceLock.lock()
        traceStreams.removeAll { $0 === stream }
        traceLock.unlock()
    }

    /// For the render block (audio thread).
    fileprivate static func currentTraceStreams() -> [TraceAudioStream] {
        traceLock.lock()
        defer { traceLock.unlock() }
        return traceStreams
    }

    /// At connect, before any data is processed: tells native whether audio is on and starts the output.
    func start() {
        applySettings()
        if defaultsObserver == nil {
            defaultsObserver = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                self?.applySettings()
            }
        }
        guard engine == nil else { return }
        startEngine()
    }

    /// Builds and starts the engine. If it won't start, native is told audio is off: nothing would pull the mix,
    /// so channels would never drain and every `A;Wait` would sit out its cap.
    private func startEngine() {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate,
                                   channels: 2, interleaved: false)!
        let pcm = self.pcm
        let node = AVAudioSourceNode { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let frames = Int(frameCount)
            let gain = self?.gain ?? 0
            var done = 0
            while done < frames {
                let n = min(frames - done, SyncTermAudioService.chunkFrames)
                // Pulled even when muted, so native channels drain (see the type comment)
                let audible = Int(native_apc_audio_pull(pcm, Int32(n)))
                let scale = audible > 0 ? gain / 32768 : 0
                for ch in 0..<min(2, buffers.count) {
                    guard let out = buffers[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
                    if scale == 0 {
                        (out + done).update(repeating: 0, count: n)
                    } else {
                        for i in 0..<n {
                            out[done + i] = Float(pcm[i * 2 + ch]) * scale
                        }
                    }
                }
                // TRACE module sound rides the same output at the same volume (Windows mixes TraceAudioStream into
                // AudioOutput.Effects at the soundtrack volume). Drained even while muted, like the door mix.
                let traceStreams = SyncTermAudioService.currentTraceStreams()
                if !traceStreams.isEmpty, buffers.count > 0,
                   let left = buffers[0].mData?.assumingMemoryBound(to: Float.self) {
                    let right = buffers.count > 1 ? buffers[1].mData?.assumingMemoryBound(to: Float.self) : nil
                    for stream in traceStreams {
                        stream.mix(into: left, right, offset: done, frames: n, scale: gain / 32768)
                    }
                }
                done += n
            }
            return noErr
        }

        let audioEngine = AVAudioEngine()
        audioEngine.attach(node)
        audioEngine.connect(node, to: audioEngine.mainMixerNode, format: format)
        do {
            try audioEngine.start()
            engine = audioEngine
            // An output device change stops the engine; start a fresh one (Windows' WASAPI output follows the
            // default device the same way)
            configObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: audioEngine, queue: .main
            ) { [weak self] _ in
                guard let self = self, self.engine === audioEngine else { return }
                logger.info("SyncTERM audio output configuration changed; restarting")
                self.teardownEngine()
                self.startEngine()
            }
        } catch {
            logger.error("SyncTERM audio output failed to start: \(error.localizedDescription)")
            NativeBridge.shared.setApcAudioEnabled(false)
        }
    }

    private func teardownEngine() {
        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
            configObserver = nil
        }
        engine?.stop()
        engine = nil
    }

    /// At disconnect. Native frees its slots and channels itself (session reset).
    func stop() {
        teardownEngine()
        if let observer = defaultsObserver {
            NotificationCenter.default.removeObserver(observer)
            defaultsObserver = nil
        }
    }

    private func applySettings() {
        let defaults = UserDefaults.standard
        let enabled = defaults.object(forKey: SoundtrackManager.keySoundtrackEnabled) as? Bool ?? true
        let volume = defaults.object(forKey: SoundtrackManager.keySoundtrackVolume) as? Int ?? 10
        // With no running engine nothing pulls the mix, so doors must hear there is no audio
        NativeBridge.shared.setApcAudioEnabled(enabled && (engine != nil || defaultsObserver == nil))
        let linear = Float(max(0, min(10, volume))) / 10
        gain = enabled && linear > 0 ? min(linear * Self.masterGain, 1) : 0
    }
}
