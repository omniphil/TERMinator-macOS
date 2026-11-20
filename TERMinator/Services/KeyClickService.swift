import AVFoundation

/// IBM Model M key clicks while typing into a board or the command line. The clips are real buckling-spring
/// recordings cut into single presses: "Typing - Model M 1986.ogg" by Raymangold22 (CC0) and "Modelm.ogg" by
/// Cpuwhiz13 (public domain), both from Wikimedia Commons — the same 8 key + 2 spacebar clips the Windows and Linux
/// clients use (Resources/modelm_key1-8.wav, modelm_space1-2.wav).
///
/// One AVAudioEngine kept running, with a small pool of player nodes: each click goes to the next node, so fast typing
/// overlaps clicks instead of cutting each one off (BellManager's single node stops what's playing).
final class KeyClickService {
    static let shared = KeyClickService()

    private let engine = AVAudioEngine()
    private var nodes: [AVAudioPlayerNode] = []
    private var keyBuffers: [AVAudioPCMBuffer] = []
    private var spaceBuffers: [AVAudioPCMBuffer] = []
    private var nextNode = 0
    private var lastKey = -1
    private var loaded = false

    private static let poolSize = 8

    private init() {}

    /// Loads the clips and starts the engine ahead of the first keystroke, so the first click isn't late.
    func warmUp() {
        _ = ensureReady()
    }

    /// One keystroke, if key clicks are on (and not muted by a paste or the Boss Hide screen).
    /// `space` uses the deeper spacebar sound.
    func play(space: Bool = false) {
        let defaults = UserDefaults.standard
        guard !AppState.shared.bossHideActive,
              defaults.bool(forKey: AppPreferences.keyClicksEnabled) else { return }
        playAt(volume: defaults.integer(forKey: AppPreferences.keyClickVolume), space: space)
    }

    /// Preferences' Test Click: plays at the given volume even while key clicks are off.
    func playPreview(volume: Int) {
        playAt(volume: volume, space: false)
    }

    private func playAt(volume: Int, space: Bool) {
        guard volume > 0, ensureReady() else { return }

        let buffer: AVAudioPCMBuffer
        if space, let spaceClip = spaceBuffers.randomElement() {
            buffer = spaceClip
        } else {
            // Never the same clip twice running, so a held-down rhythm doesn't sound like a loop
            var index = Int.random(in: 0..<keyBuffers.count)
            if index == lastKey && keyBuffers.count > 1 {
                index = (index + 1) % keyBuffers.count
            }
            lastKey = index
            buffer = keyBuffers[index]
        }

        let node = nodes[nextNode]
        nextNode = (nextNode + 1) % nodes.count
        node.volume = Float(min(max(volume, 0), 10)) / 10 * Float.random(in: 0.85...1.0)
        node.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
        if !node.isPlaying {
            node.play()
        }
    }

    private func ensureReady() -> Bool {
        if !loaded {
            loaded = true
            load()
        }
        guard !keyBuffers.isEmpty, !nodes.isEmpty else { return false }
        if engine.isRunning {
            return true
        }
        do {
            engine.prepare()
            try engine.start()
            return true
        } catch {
            return false
        }
    }

    private func load() {
        for index in 1...8 {
            if let buffer = Self.buffer(named: "modelm_key\(index)") {
                keyBuffers.append(buffer)
            }
        }
        for index in 1...2 {
            if let buffer = Self.buffer(named: "modelm_space\(index)") {
                spaceBuffers.append(buffer)
            }
        }
        guard let format = keyBuffers.first?.format else { return }
        for _ in 0..<Self.poolSize {
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            nodes.append(node)
        }
    }

    private static func buffer(named name: String) -> AVAudioPCMBuffer? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "wav"),
              let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.length)) else { return nil }
        do {
            try file.read(into: buffer)
        } catch {
            return nil
        }
        return buffer
    }
}
