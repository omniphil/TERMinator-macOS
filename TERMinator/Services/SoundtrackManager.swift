import Foundation
import AVFoundation
import os.log

private let logger = Logger(subsystem: "com.terminator.macos", category: "Soundtrack")

/// Manages BBS soundtrack playback via OSC 800 / TAP+ protocol.
///
/// TAP+ extensions:
///   - 4 audio channels (0-3) for simultaneous playback
///   - Seek to absolute position in current track
///   - Channel 0 supports all formats (tracker + streaming)
///   - Channels 1-3 support streaming formats only (MP3/WAV/OGG)
///   - Video/image file caching for TAP+ multimedia commands
///
/// Commands not handled here (visualizer, images, video) return false
/// so TerminalViewModel can route them to handleTapPlusCommand().
class SoundtrackManager: ObservableObject {

    static let shared = SoundtrackManager()

    // MARK: - Constants

    private static let cacheDirName = "soundtracks"
    private static let maxURLLength = 2048
    private static let maxFilenameLength = 128
    private static let maxFileSize: Int64 = 50 * 1024 * 1024  // 50MB per file (video support)
    private static let defaultCacheLimitMB = 250
    private static let masterGain: Float = 0.85
    /// Stall timeout: URLSession's timeoutIntervalForRequest is an idle timeout (no data for this long).
    private static let downloadTimeoutSeconds: TimeInterval = 15
    /// Total cap for one download once it has started. Generous, since queueing is now ours (see cacheFile).
    private static let downloadResourceTimeoutSeconds: TimeInterval = 300
    private static let maxConcurrentDownloads = 4
    private static let pendingPlayWaitMs = 60_000  // a play waits this long for a file that is queued or downloading
    private static let unknownPlayWaitMs = 10_000  // ...and this long for one no download is known for
    /// A missing file whose download fails (stall, dropped connection, 5xx) is tried again after these delays.
    private static let retryDelaysSec = [30, 60, 120]

    /// RFC 1123 HTTP date (If-Modified-Since / Last-Modified). DateFormatter is thread-safe for use.
    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter
    }()

    private static let numChannels = 4

    private static let videoExtensions: Set<String> = ["mp4", "m4v", "webm"]
    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp"]
    private static let allowedExtensions: Set<String> = [
        "mp3", "wav", "ogg", "mod", "s3m", "xm", "it",
        "mp4", "m4v", "webm",
        "jpg", "jpeg", "png", "gif", "webp"
    ]
    private static let trackerExtensions: Set<String> = ["mod", "s3m", "xm", "it"]
    private static let filenamePattern = try! NSRegularExpression(pattern: "^[a-zA-Z0-9._ -]+$")

    // Settings keys
    static let keySoundtrackEnabled = "soundtrack_enabled"
    static let keySoundtrackVolume = "soundtrack_volume"
    static let keySoundtrackCacheLimit = "soundtrack_cache_limit"

    // MARK: - Published State

    @Published var cacheSize: Int64 = 0

    // MARK: - Audio Analyzer

    let audioAnalyzer = AudioAnalyzer()

    // MARK: - Per-Channel State

    private class AudioChannel {
        let index: Int
        // Engine-based streaming playback (with PCM tap for visualizer)
        var audioEngine: AVAudioEngine?
        var playerNode: AVAudioPlayerNode?
        var audioFile: AVAudioFile?
        var looping: Bool = false
        // Tracker playback
        var modPlayer: ModPlayer?
        var volume: Float = 1.0
        var fadeTimer: Timer?
        var playing = false
        var currentFilename: String?
        // Generation counter — incremented each time a new track starts.
        // Completion handlers capture the generation at schedule time and
        // ignore the callback if it no longer matches (stale).
        var generation: Int = 0
        // Bumped by every play/stop (main thread only), so a play still waiting on a download
        // knows it has been superseded.
        var playGeneration: Int = 0

        // Queue for auto-advance playback
        var queue: [(filename: String, delaySec: Int)] = []
        var queueIndex: Int = 0
        var queueTimer: DispatchWorkItem?

        init(index: Int) {
            self.index = index
        }

        func stopInternal() {
            playerNode?.stop()
            if let engine = audioEngine {
                engine.mainMixerNode.removeTap(onBus: 0)
                engine.stop()
                if let node = playerNode {
                    engine.detach(node)
                }
            }
            audioEngine = nil
            playerNode = nil
            audioFile = nil
            looping = false

            modPlayer?.stop()
            modPlayer = nil

            playing = false
            currentFilename = nil
        }

    }

    // MARK: - Private State

    private let cacheDir: URL
    private var channels: [AudioChannel] = []
    private let downloadSession: URLSession

    // Maps TAP display names to actual cached filenames (e.g. "Axel F" -> "AxelF.mod")
    private var displayNameMap: [String: String] = [:]

    // Download queue (cacheFile / pumpDownloads). Everything below is only touched on downloadStateQueue.
    private let downloadStateQueue = DispatchQueue(label: "SoundtrackManager.downloads")
    private var missingQueue: [DownloadJob] = []    // not cached yet: first
    private var freshnessQueue: [DownloadJob] = []  // cached: check for a newer copy
    private var queuedDownloads: Set<String> = []   // queued, waiting for a retry, or running
    private var urlByFilename: [String: URL] = [:]
    private var activeDownloads = 0
    private var retryWaiting: [String: DownloadJob] = [:]  // failed, retry timer running

    // MARK: - Init

    private init() {
        let cacheBase = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDir = cacheBase.appendingPathComponent(SoundtrackManager.cacheDirName)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = SoundtrackManager.downloadTimeoutSeconds
        config.timeoutIntervalForResource = SoundtrackManager.downloadResourceTimeoutSeconds
        downloadSession = URLSession(configuration: config)

        for i in 0..<SoundtrackManager.numChannels {
            channels.append(AudioChannel(index: i))
        }

        // Register defaults so values are correct before user visits Settings
        UserDefaults.standard.register(defaults: [
            SoundtrackManager.keySoundtrackEnabled: true,
            SoundtrackManager.keySoundtrackVolume: 10,
            SoundtrackManager.keySoundtrackCacheLimit: SoundtrackManager.defaultCacheLimitMB
        ])

        applySettingsVolume()
        updateCacheSize()
    }

    // MARK: - Command Handling

    /// Parse and execute an OSC 800 command string.
    /// Returns true if the command was handled, false if it should be
    /// routed elsewhere (e.g. visualizer, image commands).
    @discardableResult
    func handleCommand(_ cmd: String) -> Bool {
        guard isEnabled() else { return true }

        let parts = cmd.components(separatedBy: ";")
        guard !parts.isEmpty else { return true }

        switch parts[0].lowercased() {
        case "cache":
            if parts.count >= 3 {
                cacheFile(url: parts[1], displayName: parts[2])
            }
        case "play":
            if parts.count >= 2 {
                let loop = parts.count >= 3 && parts[2] == "1"
                let channel = parts.count >= 4 ? (Int(parts[3]) ?? 0) : 0
                // Explicit play clears any existing queue
                if let ch = getChannel(channel) {
                    ch.queue.removeAll()
                    ch.queueIndex = 0
                    ch.queueTimer?.cancel()
                    ch.queueTimer = nil
                }
                play(filename: parts[1], loop: loop, channelIdx: channel)
            }
        case "queue":
            // queue;filename;channel;delay_seconds
            if parts.count >= 4 {
                let channel = Int(parts[2]) ?? 0
                let delay = max(0, Int(parts[3]) ?? 3)
                if let ch = getChannel(channel) {
                    ch.queue.append((filename: parts[1], delaySec: delay))
                    logger.info("Queued '\(parts[1])' on ch\(channel) (delay=\(delay)s, queue=\(ch.queue.count))")
                }
            }
        case "stop":
            let channel = parts.count >= 2 ? Int(parts[1]) : nil
            if let channel = channel {
                stopChannel(channel)
            } else {
                stopAll()
            }
        case "pause":
            let channel = parts.count >= 2 ? Int(parts[1]) : nil
            if let channel = channel {
                pauseChannel(channel)
            } else {
                for ch in channels { pauseChannel(ch.index) }
            }
        case "resume":
            let channel = parts.count >= 2 ? Int(parts[1]) : nil
            if let channel = channel {
                resumeChannel(channel)
            } else {
                for ch in channels { resumeChannel(ch.index) }
            }
        case "volume":
            if parts.count >= 2, let vol = Int(parts[1]) {
                let channel = parts.count >= 3 ? Int(parts[2]) : nil
                if let channel = channel {
                    setVolume(vol, channelIdx: channel)
                } else {
                    for ch in channels { setVolume(vol, channelIdx: ch.index) }
                }
            }
        case "fade":
            if parts.count >= 3, let targetVol = Int(parts[1]), let durationMs = Int(parts[2]) {
                let channel = parts.count >= 4 ? Int(parts[3]) : nil
                if let channel = channel {
                    fade(targetVolPercent: targetVol, durationMs: durationMs, channelIdx: channel)
                } else {
                    for ch in channels { fade(targetVolPercent: targetVol, durationMs: durationMs, channelIdx: ch.index) }
                }
            }
        case "seek":
            if parts.count >= 2, let posMs = Int(parts[1]) {
                let channel = parts.count >= 3 ? (Int(parts[2]) ?? 0) : 0
                seek(positionMs: posMs, channelIdx: channel)
            }
        default:
            return false  // Not an audio command — route to TAP+ handler
        }
        return true
    }

    // MARK: - Download & Cache

    /// One file to fetch for the cache. A class so the retry bookkeeping (attempt) is shared
    /// between the queue and the retry-waiting table. Only touched on downloadStateQueue.
    private final class DownloadJob {
        let url: URL
        let safeFilename: String
        let targetFile: URL
        /// Already cached: only replace it if the server's copy is newer (If-Modified-Since).
        let freshnessOnly: Bool
        /// Retries used so far (see retryDelaysSec).
        var attempt = 0

        init(url: URL, safeFilename: String, targetFile: URL, freshnessOnly: Bool) {
            self.url = url
            self.safeFilename = safeFilename
            self.targetFile = targetFile
            self.freshnessOnly = freshnessOnly
        }
    }

    private enum DownloadResult {
        case done
        case retryableFailure
        case permanentFailure
    }

    /// Queue a file from a URL for the cache.
    /// The display name from TAP is used as a key; the actual filename from the URL is used for storage.
    /// Downloads go through a small queue (maxConcurrentDownloads at a time): a door can send a hundred
    /// cache commands in one burst (Skyraiders sends ~127), and starting them all at once made most of
    /// them time out, because URLSession's resource timeout also counts the time a task spends waiting
    /// for a connection to the host.
    private func cacheFile(url urlString: String, displayName: String) {
        guard isValidUrl(urlString) else {
            logger.warning("Invalid URL rejected: \(urlString)")
            return
        }

        guard let url = URL(string: urlString) else { return }
        let realFilename = url.lastPathComponent

        guard let safeFilename = sanitizeFilename(realFilename) else {
            logger.warning("Invalid filename from URL rejected: \(realFilename)")
            return
        }

        if !displayName.isEmpty {
            displayNameMap[displayName] = safeFilename
        }

        let targetFile = cacheDir.appendingPathComponent(safeFilename)
        let cached = FileManager.default.fileExists(atPath: targetFile.path)
        downloadStateQueue.async { [weak self] in
            guard let self = self else { return }
            self.urlByFilename[safeFilename] = url  // lets play() retry a download that failed
            guard !self.queuedDownloads.contains(safeFilename) else { return }  // already queued or downloading
            self.queuedDownloads.insert(safeFilename)
            let job = DownloadJob(url: url, safeFilename: safeFilename, targetFile: targetFile, freshnessOnly: cached)
            // Missing files go before freshness checks of files we already have
            if cached {
                self.freshnessQueue.append(job)
            } else {
                self.missingQueue.append(job)
            }
            self.pumpDownloads()
        }
    }

    /// Starts queued downloads while there are free slots; missing files first.
    /// Must be called on downloadStateQueue.
    private func pumpDownloads() {
        dispatchPrecondition(condition: .onQueue(downloadStateQueue))
        while activeDownloads < SoundtrackManager.maxConcurrentDownloads {
            let job: DownloadJob
            if !missingQueue.isEmpty {
                job = missingQueue.removeFirst()
            } else if !freshnessQueue.isEmpty {
                job = freshnessQueue.removeFirst()
            } else {
                break
            }
            activeDownloads += 1
            startDownload(job)
        }
    }

    /// Creates and resumes the URLSession task for a job that has a slot. The task is only created
    /// here, so its resource timeout never covers time spent waiting in our queue.
    private func startDownload(_ job: DownloadJob) {
        var request = URLRequest(url: job.url)
        request.httpMethod = "GET"
        if job.freshnessOnly,
           let attrs = try? FileManager.default.attributesOfItem(atPath: job.targetFile.path),
           let modDate = attrs[.modificationDate] as? Date {
            request.setValue(SoundtrackManager.httpDateFormatter.string(from: modDate),
                             forHTTPHeaderField: "If-Modified-Since")
        }

        logger.info("\(job.freshnessOnly ? "Checking for newer" : "Downloading"): \(job.url.absoluteString)")
        let task = downloadSession.downloadTask(with: request) { [weak self] tempURL, response, error in
            guard let self = self else { return }
            // The temp file is only valid until this handler returns, so it is handled right here
            let result = self.finishDownload(job: job, tempURL: tempURL, response: response, error: error)
            self.downloadStateQueue.async {
                self.downloadFinished(job: job, result: result)
            }
        }
        task.resume()
    }

    /// Checks the response of one download and moves the file into the cache.
    /// Runs on URLSession's delegate queue (not downloadStateQueue): touches no queue state.
    private func finishDownload(job: DownloadJob, tempURL: URL?, response: URLResponse?, error: Error?) -> DownloadResult {
        if let error = error {
            // Includes timeoutIntervalForRequest firing, i.e. no data for downloadTimeoutSeconds
            logger.error("Download error for \(job.safeFilename): \(error.localizedDescription)")
            return .retryableFailure
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            logger.error("Download error for \(job.safeFilename): no HTTP response")
            return .retryableFailure
        }

        let code = httpResponse.statusCode
        if job.freshnessOnly && code == 304 {
            logger.debug("Cache up-to-date: \(job.safeFilename)")
            return .done
        }
        guard code == 200 else {
            logger.warning("Download failed: HTTP \(code) for \(job.url.absoluteString)")
            // Server trouble or throttling may pass; a 404 and the like won't
            return (code >= 500 || code == 408 || code == 429) ? .retryableFailure : .permanentFailure
        }
        guard let tempURL = tempURL else {
            logger.error("Download error for \(job.safeFilename): no file")
            return .retryableFailure
        }

        let fm = FileManager.default
        var fileSize: Int64 = 0
        if let attrs = try? fm.attributesOfItem(atPath: tempURL.path),
           let size = attrs[.size] as? Int64 {
            fileSize = size
        }
        guard fileSize <= SoundtrackManager.maxFileSize else {
            logger.warning("File too large: \(fileSize) bytes (max: \(SoundtrackManager.maxFileSize))")
            return .permanentFailure
        }

        // Move it next to the target first (URLSession's temp dir may be on another volume), then into place
        let tmpFile = cacheDir.appendingPathComponent(job.safeFilename + ".tmp")
        do {
            if fm.fileExists(atPath: tmpFile.path) {
                try? fm.removeItem(at: tmpFile)
            }
            try fm.moveItem(at: tempURL, to: tmpFile)
            if fm.fileExists(atPath: job.targetFile.path) {
                try fm.removeItem(at: job.targetFile)
            }
            try fm.moveItem(at: tmpFile, to: job.targetFile)
        } catch {
            try? fm.removeItem(at: tmpFile)
            logger.error("Cache move error for \(job.safeFilename): \(error.localizedDescription)")
            return .permanentFailure
        }

        // Stamp the file with the server's Last-Modified: the next visit's If-Modified-Since sends it back,
        // and nginx (if_modified_since exact, its default) answers 304 only to that exact date. With the
        // download time instead, every cached file was downloaded again on every visit.
        if let lastModified = httpResponse.value(forHTTPHeaderField: "Last-Modified"),
           let serverDate = SoundtrackManager.httpDateFormatter.date(from: lastModified) {
            // Best effort: without it the file still works, it's just re-fetched in full next time
            try? fm.setAttributes([.modificationDate: serverDate], ofItemAtPath: job.targetFile.path)
        }

        logger.info("\(job.freshnessOnly ? "Updated" : "Cached"): \(job.safeFilename) (\(fileSize) bytes)")
        if !job.freshnessOnly {
            pruneCache()
        }
        DispatchQueue.main.async { [weak self] in
            self?.updateCacheSize()
        }
        return .done
    }

    /// Frees the job's slot, schedules a retry if it earned one, and starts the next download.
    /// Must be called on downloadStateQueue.
    private func downloadFinished(job: DownloadJob, result: DownloadResult) {
        dispatchPrecondition(condition: .onQueue(downloadStateQueue))
        activeDownloads -= 1
        // Only files we don't have are retried; a failed freshness check just leaves the cached copy in place
        let retry = result == .retryableFailure && !job.freshnessOnly
            && job.attempt < SoundtrackManager.retryDelaysSec.count
        if retry {
            retryWaiting[job.safeFilename] = job  // stays in queuedDownloads: still pending
            let delaySec = SoundtrackManager.retryDelaysSec[job.attempt]
            job.attempt += 1
            logger.info("Will retry \(job.safeFilename) in \(delaySec)s (retry \(job.attempt) of \(SoundtrackManager.retryDelaysSec.count))")
            downloadStateQueue.asyncAfter(deadline: .now() + .seconds(delaySec)) { [weak self] in
                guard let self = self else { return }
                // Gone already if a play pulled it forward
                guard let waiting = self.retryWaiting[job.safeFilename], waiting === job else { return }
                self.retryWaiting.removeValue(forKey: job.safeFilename)
                self.missingQueue.append(job)
                self.pumpDownloads()
            }
        } else {
            queuedDownloads.remove(job.safeFilename)
        }
        pumpDownloads()
    }

    /// True while a file is waiting in the download queue, waiting for a retry, or downloading.
    private func isDownloadPending(_ safeFilename: String) -> Bool {
        return downloadStateQueue.sync { queuedDownloads.contains(safeFilename) }
    }

    /// A play wants a file that isn't cached: move it to the front of the download queue, or queue it
    /// again if an earlier download of it failed. Returns true if it is now queued or downloading.
    private func requestDownloadNow(_ safeFilename: String) -> Bool {
        return downloadStateQueue.sync { () -> Bool in
            if let idx = missingQueue.firstIndex(where: { $0.safeFilename == safeFilename }) {
                let job = missingQueue.remove(at: idx)
                missingQueue.insert(job, at: 0)
                logger.info("Moved \(safeFilename) to the front of the download queue")
                return true
            }
            if let idx = freshnessQueue.firstIndex(where: { $0.safeFilename == safeFilename }) {
                // Its cached copy went (pruned) before its freshness check ran: fetch it in full, first
                let old = freshnessQueue.remove(at: idx)
                let job = DownloadJob(url: old.url, safeFilename: safeFilename,
                                      targetFile: old.targetFile, freshnessOnly: false)
                missingQueue.insert(job, at: 0)
                logger.info("Moved \(safeFilename) to the front of the download queue (was a freshness check)")
            } else if let waiting = retryWaiting.removeValue(forKey: safeFilename) {
                missingQueue.insert(waiting, at: 0)  // a play wants it now: skip the rest of its back-off
                logger.info("Retrying \(safeFilename) now (a play wants it)")
            } else if queuedDownloads.contains(safeFilename) {
                return true  // downloading right now
            } else {
                guard let url = urlByFilename[safeFilename] else { return false }  // never cached by the board
                queuedDownloads.insert(safeFilename)
                let job = DownloadJob(url: url, safeFilename: safeFilename,
                                      targetFile: cacheDir.appendingPathComponent(safeFilename),
                                      freshnessOnly: false)
                missingQueue.insert(job, at: 0)
                logger.info("Re-queued failed download at the front: \(safeFilename)")
            }
            pumpDownloads()
            return true
        }
    }

    // MARK: - Playback

    /// Auto-advance to the next track in the channel's queue.
    private func playNextFromQueue(_ channelIdx: Int) {
        guard let ch = getChannel(channelIdx), !ch.queue.isEmpty else { return }

        let track = ch.queue[ch.queueIndex]
        ch.queueIndex = (ch.queueIndex + 1) % ch.queue.count

        logger.info("Auto-advance ch\(channelIdx) -> '\(track.filename)' in \(track.delaySec)s")

        ch.queueTimer?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.play(filename: track.filename, loop: false, channelIdx: channelIdx)
        }
        ch.queueTimer = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .seconds(track.delaySec),
            execute: workItem
        )
    }

    /// Play a cached file on a channel. If it isn't cached yet (still queued or downloading),
    /// it is pulled to the front of the download queue and played when it arrives.
    /// Main thread only.
    private func play(filename: String, loop: Bool, channelIdx: Int) {
        guard let ch = getChannel(channelIdx) else { return }

        // Any wait for an earlier play on this channel is now stale
        ch.playGeneration += 1
        let playGen = ch.playGeneration

        let resolved = displayNameMap[filename]
        if let resolved = resolved {
            logger.info("Resolved display name '\(filename)' -> '\(resolved)'")
        }

        var safeName = sanitizeFilename(resolved ?? filename)
        if safeName == nil {
            safeName = findCachedFile(baseName: filename)
        }
        guard let safeFilename = safeName else {
            logger.warning("No cached file found for: \(filename)")
            return
        }

        let file = cacheDir.appendingPathComponent(safeFilename)

        if !FileManager.default.fileExists(atPath: file.path) {
            let pending = requestDownloadNow(safeFilename)
            let waitMs = pending ? SoundtrackManager.pendingPlayWaitMs : SoundtrackManager.unknownPlayWaitMs
            logger.info("File not cached yet, waiting up to \(waitMs / 1000)s: \(safeFilename)\(pending ? "" : " (no download known for it)")")
            waitAndPlay(file: file, safeFilename: safeFilename, loop: loop, channelIdx: channelIdx,
                        playGen: playGen, waitMs: waitMs, pending: pending, elapsedMs: 0)
            return
        }

        playInternal(file: file, safeFilename: safeFilename, loop: loop, channelIdx: channelIdx)
    }

    /// Polls for a file a play is waiting on, every 250ms on the main thread, until it arrives,
    /// the channel gets a newer play/stop, its download fails, or waitMs runs out.
    private func waitAndPlay(file: URL, safeFilename: String, loop: Bool, channelIdx: Int,
                             playGen: Int, waitMs: Int, pending: Bool, elapsedMs: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250)) { [weak self] in
            guard let self = self, let ch = self.getChannel(channelIdx) else { return }
            let elapsed = elapsedMs + 250
            guard ch.playGeneration == playGen else {
                logger.info("Dropped wait for \(safeFilename): ch\(channelIdx) got a newer play/stop")
                return
            }
            if FileManager.default.fileExists(atPath: file.path) {
                logger.info("File ready after \(elapsed)ms: \(safeFilename)")
                self.playInternal(file: file, safeFilename: safeFilename, loop: loop, channelIdx: channelIdx)
                return
            }
            // Its download failed while we waited: there is nothing left to wait for
            if pending && !self.isDownloadPending(safeFilename) {
                logger.warning("Gave up on \(safeFilename): its download failed")
                return
            }
            guard elapsed < waitMs else {
                logger.warning("Timed out waiting for file: \(safeFilename)")
                return
            }
            self.waitAndPlay(file: file, safeFilename: safeFilename, loop: loop, channelIdx: channelIdx,
                             playGen: playGen, waitMs: waitMs, pending: pending, elapsedMs: elapsed)
        }
    }

    private func findCachedFile(baseName: String) -> String? {
        guard !baseName.isEmpty, baseName.count <= SoundtrackManager.maxFilenameLength else { return nil }
        for ext in SoundtrackManager.allowedExtensions {
            let candidate = "\(baseName).\(ext)"
            if sanitizeFilename(candidate) != nil {
                let file = cacheDir.appendingPathComponent(candidate)
                if FileManager.default.fileExists(atPath: file.path) {
                    return candidate
                }
            }
        }
        return nil
    }

    private func playInternal(file: URL, safeFilename: String, loop: Bool, channelIdx: Int) {
        guard let ch = getChannel(channelIdx) else { return }

        ch.fadeTimer?.invalidate()
        ch.fadeTimer = nil
        // Bump generation so any in-flight completion handlers from the
        // previous track will see a stale generation and skip auto-advance.
        ch.generation += 1
        ch.playing = false
        ch.stopInternal()

        let ext = (safeFilename as NSString).pathExtension.lowercased()
        if SoundtrackManager.trackerExtensions.contains(ext) {
            if channelIdx != 0 {
                logger.warning("Tracker formats only supported on channel 0, redirecting")
                playInternal(file: file, safeFilename: safeFilename, loop: loop, channelIdx: 0)
                return
            }
            playTracker(ch: ch, file: file, loop: loop)
        } else {
            playAudioPlayer(ch: ch, file: file, loop: loop)
        }

        ch.currentFilename = safeFilename
        ch.playing = true
    }

    private func playAudioPlayer(ch: AudioChannel, file: URL, loop: Bool) {
        do {
            let audioFile = try AVAudioFile(forReading: file)
            let engine = AVAudioEngine()
            let playerNode = AVAudioPlayerNode()

            engine.attach(playerNode)
            engine.connect(playerNode, to: engine.mainMixerNode, format: audioFile.processingFormat)

            // Install PCM tap for visualizer (any channel feeds the analyzer)
            let tapFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 2, interleaved: false)
            engine.mainMixerNode.installTap(onBus: 0, bufferSize: 2048, format: tapFormat) { [weak self] buffer, _ in
                guard let self = self else { return }
                let frameCount = Int(buffer.frameLength)
                guard let channelData = buffer.floatChannelData, buffer.format.channelCount >= 1 else { return }

                var pcmBuffer = [Int16](repeating: 0, count: frameCount * 2)
                let ch0 = channelData[0]
                let ch1 = buffer.format.channelCount >= 2 ? channelData[1] : channelData[0]
                for i in 0..<frameCount {
                    pcmBuffer[i * 2] = Int16(max(-1, min(1, ch0[i])) * 32767)
                    pcmBuffer[i * 2 + 1] = Int16(max(-1, min(1, ch1[i])) * 32767)
                }
                self.audioAnalyzer.feedPcm(buffer: pcmBuffer, frames: frameCount)
            }

            try engine.start()

            ch.audioEngine = engine
            ch.playerNode = playerNode
            ch.audioFile = audioFile
            ch.looping = loop

            scheduleStreamingFile(ch: ch)
            playerNode.play()
            playerNode.volume = toPerceptualVolume(ch.volume)

            logger.info("Ch\(ch.index) playing (engine): \(file.lastPathComponent) (loop=\(loop))")
        } catch {
            logger.error("Ch\(ch.index) engine play error: \(error.localizedDescription)")
        }
    }

    private func scheduleStreamingFile(ch: AudioChannel) {
        guard let playerNode = ch.playerNode, let audioFile = ch.audioFile else { return }
        let gen = ch.generation  // capture current generation
        playerNode.scheduleFile(audioFile, at: nil) { [weak self] in
            guard let self = self else { return }
            // If generation changed, a new track replaced us — ignore this callback.
            guard ch.generation == gen else { return }
            if ch.looping && ch.playing {
                audioFile.framePosition = 0
                self.scheduleStreamingFile(ch: ch)
            } else if ch.playing {
                // Playback ended naturally — auto-advance from queue
                DispatchQueue.main.async {
                    guard ch.generation == gen else { return }
                    ch.playing = false
                    ch.currentFilename = nil
                    self.playNextFromQueue(ch.index)
                }
            }
        }
    }

    private func playTracker(ch: AudioChannel, file: URL, loop: Bool) {
        stopAboutMusic() // one native libxmp player: a BBS tune takes it over from the About box
        let player = ModPlayer()
        guard player.load(file.path) else {
            logger.error("ModPlayer load failed: \(file.lastPathComponent)")
            return
        }
        player.setVolume(toPerceptualVolume(ch.volume))
        player.setLooping(loop)

        // Feed PCM to the audio analyzer for visualizer
        player.pcmListener = { [weak self] buffer, frames in
            self?.audioAnalyzer.feedPcm(buffer: buffer, frames: frames)
        }

        let gen = ch.generation  // capture current generation
        player.completionHandler = { [weak self] in
            guard let self = self else { return }
            // If generation changed, a new track replaced us — ignore.
            guard ch.generation == gen else { return }
            ch.modPlayer = nil
            ch.playing = false
            ch.currentFilename = nil
            self.playNextFromQueue(ch.index)
        }

        player.start()
        ch.modPlayer = player
        logger.info("Ch\(ch.index) playing tracker: \(file.lastPathComponent) (loop=\(loop))")
    }

    // MARK: - About Box Music

    /// "Elysium" by Jester of Sanity (spec §12.8), a plain bundle resource (not the asset catalog).
    private static let aboutMusicResource = "ELYSIUM"
    private static let aboutMusicExtension = "MOD"
    private static let aboutMusicGain: Float = 0.4 // 60% quieter than a BBS tune at the same setting

    /// The About box's player. Kept off the channels, so it never feeds the audio analyzer.
    private var aboutPlayer: ModPlayer?

    /// Play the About box's module once through, no looping.
    /// Skipped while a BBS tracker tune is playing -- libxmp is a single native player, so loading
    /// this would cut the BBS off.
    func playAboutMusic() {
        stopAboutMusic()
        guard !channels.contains(where: { $0.modPlayer != nil }) else { return }

        guard let url = Bundle.main.url(forResource: SoundtrackManager.aboutMusicResource,
                                        withExtension: SoundtrackManager.aboutMusicExtension) else {
            logger.error("About music missing from the app bundle")
            return
        }
        // libxmp loads from a path; the bundle's copy is used directly
        let player = ModPlayer()
        guard player.load(url.path) else {
            logger.error("About music load failed")
            return
        }

        // Same volume path as a BBS tune (the settings volume x master gain), then aboutMusicGain
        let setting = UserDefaults.standard.integer(forKey: SoundtrackManager.keySoundtrackVolume)
        let volume = Float(max(0, min(10, setting))) / 10.0
        player.setVolume(toPerceptualVolume(volume) * SoundtrackManager.aboutMusicGain)
        player.setLooping(false) // libxmp's play-once mode ends it where the last pattern jumps back

        player.completionHandler = { [weak self, weak player] in
            // Song ended on its own; a manual stop (or a BBS tune taking over) has already cleared the field
            guard let self = self, let player = player, self.aboutPlayer === player else { return }
            self.stopAboutMusic()
        }

        aboutPlayer = player
        player.start()
        logger.info("Playing About music")
    }

    /// Stop the About music at once (the box closed, or a BBS tune needs the player).
    func stopAboutMusic() {
        guard let player = aboutPlayer else { return }
        // Nil first so a completion already queued for this player leaves things alone
        aboutPlayer = nil
        player.stop(releaseNative: !channels.contains(where: { $0.modPlayer != nil }))
    }

    // MARK: - Stop / Pause / Resume

    func stopAll() {
        for ch in channels {
            ch.playGeneration += 1  // drops any play still waiting on a download
            ch.fadeTimer?.invalidate()
            ch.fadeTimer = nil
            ch.queue.removeAll()
            ch.queueIndex = 0
            ch.queueTimer?.cancel()
            ch.queueTimer = nil
            ch.stopInternal()
        }
        audioAnalyzer.reset()
    }

    private func stopChannel(_ channelIdx: Int) {
        guard let ch = getChannel(channelIdx) else { return }
        ch.playGeneration += 1  // drops any play still waiting on a download
        ch.fadeTimer?.invalidate()
        ch.fadeTimer = nil
        ch.queue.removeAll()
        ch.queueIndex = 0
        ch.queueTimer?.cancel()
        ch.queueTimer = nil
        ch.stopInternal()
        audioAnalyzer.reset()
    }

    func stop() { stopAll() }

    private func pauseChannel(_ channelIdx: Int) {
        guard let ch = getChannel(channelIdx) else { return }
        ch.playerNode?.pause()
        ch.audioEngine?.pause()
        ch.modPlayer?.pause()
    }

    private func resumeChannel(_ channelIdx: Int) {
        guard let ch = getChannel(channelIdx) else { return }
        try? ch.audioEngine?.start()
        ch.playerNode?.play()
        ch.modPlayer?.resume()
    }

    // MARK: - Volume / Fade

    private func setVolume(_ volumePercent: Int, channelIdx: Int) {
        guard let ch = getChannel(channelIdx) else { return }
        let clamped = max(0, min(100, volumePercent))
        applyVolume(ch: ch, vol: Float(clamped) / 100.0)
    }

    private func toPerceptualVolume(_ linear: Float) -> Float {
        guard linear > 0 else { return 0 }
        return min(linear * SoundtrackManager.masterGain, 1)
    }

    private func applyVolume(ch: AudioChannel, vol: Float) {
        ch.volume = max(0, min(1, vol))
        let amplitude = toPerceptualVolume(ch.volume)
        ch.playerNode?.volume = amplitude
        ch.modPlayer?.setVolume(amplitude)
    }

    private func fade(targetVolPercent: Int, durationMs: Int, channelIdx: Int) {
        guard let ch = getChannel(channelIdx) else { return }

        guard durationMs > 0 else {
            setVolume(targetVolPercent, channelIdx: channelIdx)
            return
        }

        ch.fadeTimer?.invalidate()

        let targetVol = Float(max(0, min(100, targetVolPercent))) / 100.0
        let startVol = ch.volume
        let steps = max(1, min(200, durationMs / 50))
        let stepDelay = TimeInterval(durationMs) / TimeInterval(steps) / 1000.0
        let volStep = (targetVol - startVol) / Float(steps)
        var currentStep = 0

        ch.fadeTimer = Timer.scheduledTimer(withTimeInterval: stepDelay, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            currentStep += 1
            if currentStep >= steps {
                timer.invalidate()
                ch.fadeTimer = nil
                self.applyVolume(ch: ch, vol: targetVol)
                if targetVol <= 0 {
                    self.stopChannel(channelIdx)
                }
            } else {
                self.applyVolume(ch: ch, vol: startVol + volStep * Float(currentStep))
            }
        }
    }

    // MARK: - Seek

    private func seek(positionMs: Int, channelIdx: Int) {
        guard let ch = getChannel(channelIdx), ch.playing else { return }

        // Engine-based streaming seek
        if let playerNode = ch.playerNode, let audioFile = ch.audioFile {
            let sampleRate = audioFile.processingFormat.sampleRate
            let targetFrame = AVAudioFramePosition(Double(positionMs) / 1000.0 * sampleRate)
            let clampedFrame = max(0, min(targetFrame, audioFile.length))
            let remainingFrames = AVAudioFrameCount(audioFile.length - clampedFrame)
            guard remainingFrames > 0 else { return }

            playerNode.stop()
            audioFile.framePosition = clampedFrame
            playerNode.scheduleSegment(audioFile, startingFrame: clampedFrame, frameCount: remainingFrames, at: nil) { [weak self] in
                guard let self = self, ch.looping, ch.playing else { return }
                audioFile.framePosition = 0
                self.scheduleStreamingFile(ch: ch)
            }
            playerNode.play()
        }

        if ch.modPlayer != nil {
            NativeBridge.shared.modSeek(positionMs)
        }
        logger.info("Ch\(channelIdx) seek to \(positionMs)ms")
    }

    // MARK: - Helpers

    private func getChannel(_ index: Int) -> AudioChannel? {
        guard index >= 0 && index < SoundtrackManager.numChannels else {
            logger.warning("Invalid channel: \(index)")
            return nil
        }
        return channels[index]
    }

    // MARK: - Public API

    /// Resolve a TAP display name to a cached file URL, or nil if not found.
    func resolveFile(displayName: String) -> URL? {
        let resolved = displayNameMap[displayName]
        let safeFilename: String?
        if let resolved = resolved {
            safeFilename = sanitizeFilename(resolved)
        } else {
            safeFilename = sanitizeFilename(displayName) ?? findCachedFile(baseName: displayName)
        }
        guard let safeFilename = safeFilename else { return nil }
        let file = cacheDir.appendingPathComponent(safeFilename)
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    // MARK: - Validation

    private func sanitizeFilename(_ filename: String) -> String? {
        guard filename.count <= SoundtrackManager.maxFilenameLength else { return nil }
        let range = NSRange(filename.startIndex..., in: filename)
        guard SoundtrackManager.filenamePattern.firstMatch(in: filename, range: range) != nil else { return nil }
        guard !filename.contains("..") else { return nil }
        let ext = (filename as NSString).pathExtension.lowercased()
        guard SoundtrackManager.allowedExtensions.contains(ext) else { return nil }
        return filename
    }

    private func isValidUrl(_ urlString: String) -> Bool {
        guard urlString.count <= SoundtrackManager.maxURLLength else { return false }
        guard let url = URL(string: urlString) else { return false }
        return url.scheme == "http" || url.scheme == "https"
    }

    // MARK: - Settings

    private func isEnabled() -> Bool {
        return UserDefaults.standard.bool(forKey: SoundtrackManager.keySoundtrackEnabled)
    }

    private func getCacheLimitBytes() -> Int64 {
        let limitMB = UserDefaults.standard.integer(forKey: SoundtrackManager.keySoundtrackCacheLimit)
        return Int64(limitMB > 0 ? limitMB : SoundtrackManager.defaultCacheLimitMB) * 1024 * 1024
    }

    func applySettingsVolume() {
        let vol = UserDefaults.standard.integer(forKey: SoundtrackManager.keySoundtrackVolume)
        let volume = Float(max(0, min(10, vol))) / 10.0
        for ch in channels {
            applyVolume(ch: ch, vol: volume)
        }
    }

    // MARK: - Cache Management

    private func pruneCache() {
        let limit = getCacheLimitBytes()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: cacheDir, includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey, .fileSizeKey]
        ) else { return }

        let validFiles = files.filter { !$0.lastPathComponent.hasSuffix(".tmp") }
        var totalSize: Int64 = validFiles.compactMap {
            (try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
        }.reduce(0, +)

        guard totalSize > limit else { return }

        let playingFiles = Set(channels.compactMap { $0.currentFilename })

        // Oldest download first. By creation date, not modification date: a downloaded file's
        // modification date is the server's Last-Modified (see finishDownload), which can be years
        // old and would get a file pruned straight after it was fetched.
        func downloadedAt(_ url: URL) -> Date {
            let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            return values?.creationDate ?? values?.contentModificationDate ?? .distantPast
        }
        let sorted = validFiles.sorted { downloadedAt($0) < downloadedAt($1) }

        for file in sorted {
            guard totalSize > limit else { break }
            if playingFiles.contains(file.lastPathComponent) { continue }
            if let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                try? FileManager.default.removeItem(at: file)
                totalSize -= Int64(size)
                logger.info("Pruned: \(file.lastPathComponent)")
            }
        }
    }

    func updateCacheSize() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: cacheDir, includingPropertiesForKeys: [.fileSizeKey]
        ) else {
            cacheSize = 0
            return
        }
        cacheSize = files.filter { !$0.lastPathComponent.hasSuffix(".tmp") }.compactMap {
            (try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
        }.reduce(0, +)
    }

    func clearCache() {
        stop()
        if let files = try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil) {
            for file in files {
                try? FileManager.default.removeItem(at: file)
            }
        }
        updateCacheSize()
        logger.info("Cache cleared")
    }
}
