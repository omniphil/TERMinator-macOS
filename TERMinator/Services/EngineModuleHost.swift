import Foundation
import Darwin
import os.log

private let engineLogger = Logger(subsystem: "com.terminator.macos", category: "TRACE")

/// Runs one TRACE module (the sandboxed WebAssembly host, `gamesandbox`) and trades frames, input, sound and door
/// data with it over the engine contract: a shared BGRA frame buffer with a seqlock, 8-byte input records on the
/// module's stdin, and the same kind of records coming back on its stdout (data for the door, sound, log lines, and
/// on POSIX a "frame ready" record). The contract lives in trace/include/engine_contract.h and the design in
/// BBSGames/Doom/ENGINE.md. Nothing here is game-specific, and nothing here touches TAP+.
///
/// Port of the Windows client's `Services/EngineModuleHost.cs` (the master). The POSIX contract differs in two places:
/// * the frame buffer is a regular file in the app's temp directory (`-frame <path>`), sized
///   TE_FRAME_HEADER_SIZE + capacity * 4, which both sides mmap MAP_SHARED, instead of a named Win32 mapping;
/// * there is no frame-ready event: the host writes a `TE_OUT_FRAME` (5) record, no payload, after each frame, and
///   the stdout reader does the seqlock copy then (`native_trace_frame_copy`, Bridge/apc/trace_bridge.c).
final class EngineModuleHost {
    // engine_contract.h
    private static let frameMagic: UInt32 = 0x4246_4554   // "TEFB"
    private static let headerSize = 64
    private static let offMagic = 0, offVersion = 4, offCapacityWidth = 28, offCapacityHeight = 32
    private static let flagAspect43: UInt32 = 0x01

    static let inKey: UInt8 = 1, inText: UInt8 = 2, inMouseMove: UInt8 = 3, inMouseButton: UInt8 = 4
    static let inFocus: UInt8 = 5, inQuit: UInt8 = 6, inData: UInt8 = 7, inResize: UInt8 = 8
    static let inAudioRoom: UInt8 = 9, inSendRoom: UInt8 = 10
    static let inPadButton: UInt8 = 11, inPadAxis: UInt8 = 12, inMousePos: UInt8 = 13, inPadDevice: UInt8 = 14
    static let inPaste: UInt8 = 15

    /// The most one paste carries (engine_contract.h TE_PASTE_MAX), in UTF-16 units.
    static let pasteMax = 4096
    /// How long after a click or key in the module a door may open a link or ask for a paste (ms).
    static let gestureWindowMs: UInt64 = 3000

    private static let outData: UInt8 = 1, outAudio: UInt8 = 2, outTick: UInt8 = 3, outLog: UInt8 = 4
    private static let outFrame: UInt8 = 5   // POSIX only: a frame is complete in the shared buffer
    private static let outTextInput: UInt8 = 6, outMouseMode: UInt8 = 7, outPadRumble: UInt8 = 8
    private static let outDirect: UInt8 = 9   // 1.1.6: the module presents with TRACE_GPU_PRESENT_DIRECT

    /// The most a module may send the door in one go (trace_api.h TRACE_SEND_MAX).
    static let sendMax = 4096

    /// How fast a module may send the door, as a first cut: a window of at most `sendMax` bytes outstanding,
    /// refilled at this rate. A game's inputs are a few hundred bytes a second, while a BBS link is usually
    /// 200 KB/s in total, so this leaves the terminal's own traffic plenty of room.
    private static let sendBytesPerSecond = 32 * 1024

    enum StartError: Error {
        case frameBuffer(String)
    }

    private let capacityWidth: Int
    private let capacityHeight: Int

    // The shared frame buffer
    private let framePath: String
    private let frameFd: Int32
    private let frameBytes: Int
    private let base: UnsafeMutableRawPointer

    private let process: Process
    private let stdinHandle: FileHandle
    private let stdinFd: Int32
    private let inputLock = NSLock()
    private let gestureLock = NSLock()
    private var gestureAt: UInt64 = 0   // ms (monotonic) of the player's last click or key press here; 0 = none
    // Guards the mapping against the reader thread while dispose() unmaps it
    private let mapLock = NSLock()
    private var unmapped = false
    private var inputClosed = false
    private let stateLock = NSLock()
    private var stoppingFlag = false
    private var disposed = false

    // Frames: the reader copies into scratch, then swaps it with pixels under frameLock
    private let frameLock = NSLock()
    private var pixels: UnsafeMutableRawPointer
    private var scratch: UnsafeMutableRawPointer
    private var width = 0
    private var height = 0
    private var aspect43 = false
    private var frameSerial: Int64 = 0

    private let outputLock = NSLock()
    private var outputTailLines: [String] = []
    private var stderrPartial = Data()

    private var audio: TraceAudioStream?
    private var audioAttached = false
    private var lastAudioRoomSent = -1
    private var audioSinceRoomReport = false  // the module sent sound since the last TE_IN_AUDIO_ROOM
    private let flowLock = NSLock()
    private var sendRoomTicks: UInt64 = 0   // ms, when the send window was last refilled
    private var sendRoom: Double = 0        // bytes the module may still send the door
    private var lastSendRoomSent = -1
    private var sentSinceRoomReport = false   // the module sent the door something since the last TE_IN_SEND_ROOM

    /// A new frame is ready (called on the record reader thread).
    var onFrame: (() -> Void)?

    /// The module process ended, with its exit code (called on a background thread).
    var onExit: ((Int) -> Void)?

    /// The module sent bytes for the door (called on the record reader thread).
    var onDataForDoor: ((Data) -> Void)?

    /// The module turned typed-text input on or off (called on the record reader thread).
    var onTextInputChanged: ((Bool) -> Void)?

    /// The module picked a mouse mode, 0-3 (engine_contract.h TE_MOUSE_*; record reader thread).
    var onMouseModeChanged: ((Int) -> Void)?

    /// The module asked to present straight into the window (TE_OUT_DIRECT, 1.1.6). macOS has no public way for the
    /// sandbox to draw into our window, so it sends no TE_IN_SURFACE and the frames keep coming through the frame
    /// buffer; an exclusive layer then shows them through an IOSurface of its own (EngineHostLayerView), which
    /// saves a copy and the upload to the card. Set on the record reader thread, read on the main thread.
    var directWanted: Bool {
        directLock.lock()
        defer { directLock.unlock() }
        return directFlag
    }
    private let directLock = NSLock()
    private var directFlag = false

    /// The module wants a pad to rumble: pad, low motor, high motor (0-32767), milliseconds (record reader thread).
    var onPadRumble: ((Int, Int, Int, Int) -> Void)?

    private var stopping: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stoppingFlag
    }

    private func setStopping() {
        stateLock.lock()
        stoppingFlag = true
        stateLock.unlock()
    }

    private static func nowMs() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds / 1_000_000
    }

    /// Starts a module executable with a frame buffer that holds up to capacityWidth x capacityHeight. Throws if it
    /// can't be started. withAudio lets the module make sound (mixed at the soundtrack volume).
    init(exePath: String, moduleArgs: [String], capacityWidth: Int = 1280, capacityHeight: Int = 1024,
         withAudio: Bool = true) throws {
        self.capacityWidth = capacityWidth
        self.capacityHeight = capacityHeight
        frameBytes = Self.headerSize + capacityWidth * capacityHeight * 4

        // A write to the module's stdin after it died must fail with EPIPE, not kill TERMinator
        signal(SIGPIPE, SIG_IGN)

        let name = "TRACE-\(getpid())-\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(name + ".frame").path
        framePath = path
        let fd = open(path, O_RDWR | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else {
            throw StartError.frameBuffer("open \(path): errno \(errno)")
        }
        guard ftruncate(fd, off_t(frameBytes)) == 0 else {
            let err = errno
            close(fd)
            unlink(path)
            throw StartError.frameBuffer("ftruncate: errno \(err)")
        }
        // MAP_FAILED is a cast macro Swift doesn't import: it's (void *)-1
        let mapped: UnsafeMutableRawPointer? = mmap(nil, frameBytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
        guard let mappedBase = mapped, mappedBase != UnsafeMutableRawPointer(bitPattern: -1) else {
            let err = errno
            close(fd)
            unlink(path)
            throw StartError.frameBuffer("mmap: errno \(err)")
        }
        frameFd = fd
        base = mappedBase
        // The module reads the capacity before mapping the whole buffer (engine_contract.h)
        base.storeBytes(of: Self.frameMagic, toByteOffset: Self.offMagic, as: UInt32.self)
        base.storeBytes(of: UInt32(1), toByteOffset: Self.offVersion, as: UInt32.self)
        base.storeBytes(of: UInt32(capacityWidth), toByteOffset: Self.offCapacityWidth, as: UInt32.self)
        base.storeBytes(of: UInt32(capacityHeight), toByteOffset: Self.offCapacityHeight, as: UInt32.self)

        let pixelBytes = capacityWidth * capacityHeight * 4
        pixels = UnsafeMutableRawPointer.allocate(byteCount: pixelBytes, alignment: 16)
        scratch = UnsafeMutableRawPointer.allocate(byteCount: pixelBytes, alignment: 16)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exePath)
        proc.arguments = ["-engine", name, "-frame", path] + moduleArgs
        proc.currentDirectoryURL = URL(fileURLWithPath: exePath).deletingLastPathComponent()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe
        process = proc
        stdinHandle = stdinPipe.fileHandleForWriting
        stdinFd = stdinHandle.fileDescriptor
        _ = fcntl(stdinFd, F_SETNOSIGPIPE, 1)

        proc.terminationHandler = { [weak self] p in
            guard let self = self else { return }
            self.setStopping()
            self.onExit?(Int(p.terminationStatus))
        }
        // stdout carries records, so only stderr is text
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self?.keepOutput(data)
        }

        do {
            try proc.run()
        } catch {
            // deinit -> dispose() unmaps and deletes the frame buffer
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }
        // Our copies of the child's ends
        try? stdinPipe.fileHandleForReading.close()
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()

        // The queue exists from the start, so the module is told how much room it has before it makes any sound;
        // it only joins the mix once it actually sends some (a module that stays silent costs nothing).
        if withAudio {
            audio = TraceAudioStream()
        }

        let stdoutFd = stdoutPipe.fileHandleForReading.fileDescriptor
        let records = Thread { [weak self] in
            self?.readRecords(fd: stdoutFd)
            // Keep the pipe's read end open until the reader is done with its descriptor
            withExtendedLifetime(stdoutPipe) {}
        }
        records.name = "Engine record reader"
        records.qualityOfService = .userInteractive
        records.start()
        startFlowReports()
    }

    deinit {
        dispose()
        pixels.deallocate()
        scratch.deallocate()
    }

    /// True once the module process has ended.
    var hasExited: Bool {
        !process.isRunning
    }

    /// The module's exit code, or -1 while it's running.
    var exitCode: Int {
        process.isRunning ? -1 : Int(process.terminationStatus)
    }

    /// The last lines the module printed, for error reports.
    var outputTail: String {
        outputLock.lock()
        defer { outputLock.unlock() }
        return outputTailLines.joined(separator: "\n")
    }

    /// Why the module stopped, in a few words, for the Closed report the door gets: the sandbox host's own line when
    /// it caught a trap ("gamesandbox: running the module: wasm trap: ..."), else the last thing the module itself
    /// logged; for a trap, its cause and where it happened too. Empty when it said nothing, which is what a clean exit
    /// looks like. Cut down to something that can travel in a TRACE field: no ";" (the field separator), no ESC, no
    /// control characters, 300 characters at most.
    var crashReason: String {
        outputLock.lock()
        let lines = outputTailLines
        outputLock.unlock()
        // The host's line says what killed it; the module's last line says what it was doing, which is usually the
        // more useful half. Both when we have both.
        let host = lines.last(where: { $0.hasPrefix("gamesandbox:") })
        let module = lines.last(where: { $0.hasPrefix("module:") })
        guard var line = host ?? module ?? lines.last else {
            return ""
        }
        if host != nil {   // a trap: its cause and where, from the lines under it (the board logs the whole report)
            if let c = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("Caused by:") }),
               let cause = lines[(c + 1)...].first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                line += " | cause: " + cause.trimmingCharacters(in: .whitespaces)
            }
            if let at = lines.first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("0:") }) {
                line += " | at " + String(at.trimmingCharacters(in: .whitespaces).dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
        }
        if host != nil, let module {
            line += " | last: " + module
        }
        let cleaned = String(line.map { ch -> Character in
            if ch == ";" || ch.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
                return " "
            }
            return ch
        })
        let collapsed = cleaned.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return String(collapsed.prefix(300))
    }

    private func keepOutput(_ data: Data) {
        outputLock.lock()
        defer { outputLock.unlock() }
        stderrPartial.append(data)
        while let newline = stderrPartial.firstIndex(of: 0x0A) {
            let lineData = stderrPartial.subdata(in: stderrPartial.startIndex..<newline)
            stderrPartial.removeSubrange(stderrPartial.startIndex...newline)
            appendLineLocked(String(decoding: lineData, as: UTF8.self))
        }
        if stderrPartial.count > 4096 {   // a runaway line without a newline
            appendLineLocked(String(decoding: stderrPartial, as: UTF8.self))
            stderrPartial.removeAll()
        }
    }

    private func keepLine(_ line: String) {
        outputLock.lock()
        appendLineLocked(line)
        outputLock.unlock()
    }

    private func appendLineLocked(_ rawLine: String) {
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
        engineLogger.debug("[engine] \(line, privacy: .public)")
        outputTailLines.append(line)
        while outputTailLines.count > 20 {
            outputTailLines.removeFirst()
        }
    }

    // MARK: - Records from the module (stdout)

    private func readExactly(fd: Int32, into buffer: UnsafeMutableRawPointer, count: Int) -> Bool {
        var have = 0
        while have < count {
            let got = read(fd, buffer + have, count - have)
            if got < 0 && errno == EINTR {
                continue
            }
            if got <= 0 {
                return false
            }
            have += got
        }
        return true
    }

    /// Reads the records the module sends back (engine contract): bytes for the door, sound, the tick rate it
    /// wants, log lines and (POSIX) frame-ready. Unknown record types are skipped along with their payload (none
    /// here: only the known types carry one), so a newer module still runs.
    private func readRecords(fd: Int32) {
        let header = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        defer { header.deallocate() }
        while !stopping {
            guard readExactly(fd: fd, into: header, count: 8) else {
                break   // the module is going away; onExit follows
            }
            let bytes = header.assumingMemoryBound(to: UInt8.self)
            let type = bytes[0]
            let flags = bytes[1]
            let a = Int(UInt16(bytes[2]) | UInt16(bytes[3]) << 8)
            let b = Int16(bitPattern: UInt16(bytes[4]) | UInt16(bytes[5]) << 8)
            let c = Int16(bitPattern: UInt16(bytes[6]) | UInt16(bytes[7]) << 8)
            let payloadBytes: Int
            switch type {
            case Self.outData, Self.outLog: payloadBytes = a
            case Self.outAudio: payloadBytes = a * 4   // S16 stereo frames
            default: payloadBytes = 0
            }
            var payload = Data(count: payloadBytes)
            if payloadBytes > 0 {
                let ok = payload.withUnsafeMutableBytes { raw -> Bool in
                    guard let p = raw.baseAddress else { return false }
                    return readExactly(fd: fd, into: p, count: payloadBytes)
                }
                if !ok {
                    break
                }
            }

            switch type {
            case Self.outFrame:
                copyFrame()
            case Self.outData:
                onDataForDoor?(payload)
            case Self.outAudio:
                playAudio(payload, frames: a)
            case Self.outTick:
                engineLogger.debug("[engine] module asked for \(b) updates/s")
            case Self.outLog:
                keepLine("module: " + String(decoding: payload, as: UTF8.self))
            case Self.outTextInput:
                onTextInputChanged?(b != 0)
            case Self.outMouseMode:
                onMouseModeChanged?((0...3).contains(b) ? Int(b) : 0)
            case Self.outPadRumble:
                onPadRumble?(Int(flags & 3), max(Int(b), 0), max(Int(c), 0), a)
            case Self.outDirect:
                directLock.lock()
                directFlag = (flags & 1) != 0
                directLock.unlock()
            default:
                break
            }
        }
    }

    /// The module finished a frame: copy it out of the shared buffer (seqlock) and tell the layer.
    private func copyFrame() {
        var w: Int32 = 0
        var h: Int32 = 0
        var flags: UInt32 = 0
        var copied = false
        mapLock.lock()
        if !unmapped {
            copied = native_trace_frame_copy(base, Int32(capacityWidth), Int32(capacityHeight), scratch,
                                             &w, &h, &flags) == 1
        }
        mapLock.unlock()
        guard copied else {
            return
        }
        frameLock.lock()
        let done = pixels
        pixels = scratch
        scratch = done
        width = Int(w)
        height = Int(h)
        aspect43 = (flags & Self.flagAspect43) != 0
        frameSerial += 1
        frameLock.unlock()
        onFrame?()
    }

    /// Hands the newest frame (BGRA, width * 4 bytes a row) to `consume` if it's newer than `lastSerial`. The
    /// pixels are only valid during the call.
    @discardableResult
    func tryConsumeFrame(lastSerial: inout Int64,
                         _ consume: (UnsafeRawPointer, Int, Int, Bool) -> Void) -> Bool {
        frameLock.lock()
        defer { frameLock.unlock() }
        if frameSerial == lastSerial || width == 0 {
            return false
        }
        lastSerial = frameSerial
        consume(UnsafeRawPointer(pixels), width, height, aspect43)
        return true
    }

    // MARK: - Sound and flow control

    /// Queues module sound into TERMinator's own output.
    private func playAudio(_ payload: Data, frames: Int) {
        guard let audio = audio, frames > 0 else { return }
        if !audioAttached {
            audioAttached = true
            SyncTermAudioService.addTraceStream(audio)   // the door-audio output: stays in step with the picture
        }
        payload.withUnsafeBytes { raw in
            guard let p = raw.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            audio.write(p, sampleCount: min(frames * 2, raw.count / 2))
        }
        flowLock.lock()
        audioSinceRoomReport = true
        flowLock.unlock()
        reportAudioRoom()
    }

    /// Keeps the module told how much room is left: audio frames the queue can take, and bytes it may send the door.
    /// Without this a module would either run ahead of the sound card or flood a BBS link.
    private func startFlowReports() {
        sendRoomTicks = Self.nowMs()
        let flow = Thread { [weak self] in
            while true {
                guard let self = self, !self.stopping else { break }
                self.reportAudioRoom()
                self.reportSendRoom()
                Thread.sleep(forTimeInterval: 0.010)
            }
        }
        flow.name = "Engine flow control"
        flow.start()
    }

    private func reportAudioRoom() {
        guard let audio = audio else { return }
        let room = min(audio.roomFrames, Int(UInt16.max))
        flowLock.lock()
        // The sandbox counts its own TE_OUT_AUDIO writes down from the last room it was told (gamesandbox.c
        // host_audio_write), so after the module sent sound the room must be said again even if our figure barely
        // moved, or the sandbox's copy drains and the module stops writing (audio gaps). Windows does the same.
        if abs(room - lastAudioRoomSent) < 256 && !audioSinceRoomReport {
            flowLock.unlock()
            return   // only when it moved enough to matter
        }
        lastAudioRoomSent = room
        audioSinceRoomReport = false
        flowLock.unlock()
        send(Self.inAudioRoom, 0, UInt16(room))
    }

    private func reportSendRoom() {
        let now = Self.nowMs()
        flowLock.lock()
        sendRoom = min(Double(Self.sendMax),
                       sendRoom + Double(now &- sendRoomTicks) * Double(Self.sendBytesPerSecond) / 1000.0)
        sendRoomTicks = now
        let room = Int(sendRoom) / 64   // the record carries 64-byte units
        // The sandbox takes the room as an absolute value and counts its own sends down from it
        // (gamesandbox.c trace_send), so after the module sent anything the room must be said again even when our
        // figure looks the same: it refills to the cap within one 10 ms tick, faster than DMTV's 96-byte reports use
        // it, so "unchanged" skipped every report and the sandbox's copy drained to nothing in ~11 s. The module
        // then dropped its "buf" reports, the door stopped streaming (frozen picture) and clicks never arrived.
        // (Windows gets away with it only because TickCount64 moves in 15.6 ms steps.)
        if room == lastSendRoomSent && !sentSinceRoomReport {
            flowLock.unlock()
            return
        }
        lastSendRoomSent = room
        sentSinceRoomReport = false
        flowLock.unlock()
        send(Self.inSendRoom, 0, UInt16(min(room, Int(UInt16.max))))
    }

    /// Counts what the module sent the door against its send window.
    func countSent(_ bytes: Int) {
        flowLock.lock()
        sendRoom = max(0, sendRoom - Double(bytes))
        sentSinceRoomReport = true
        flowLock.unlock()
    }

    // MARK: - Input records (stdin)

    private func writeAll(_ pointer: UnsafeRawPointer, _ count: Int) -> Bool {
        var done = 0
        while done < count {
            let n = write(stdinFd, pointer + done, count - done)
            if n < 0 && errno == EINTR {
                continue
            }
            if n <= 0 {
                return false
            }
            done += n
        }
        return true
    }

    private func send(_ type: UInt8, _ flags: UInt8, _ a: UInt16, _ b: Int16 = 0, _ c: Int16 = 0,
                      payload: Data? = nil) {
        let ub = UInt16(bitPattern: b)
        let uc = UInt16(bitPattern: c)
        let record: [UInt8] = [type, flags,
                               UInt8(a & 0xFF), UInt8(a >> 8),
                               UInt8(ub & 0xFF), UInt8(ub >> 8),
                               UInt8(uc & 0xFF), UInt8(uc >> 8)]
        inputLock.lock()
        defer { inputLock.unlock() }
        if inputClosed || stopping {
            return
        }
        var ok = record.withUnsafeBytes { raw in writeAll(raw.baseAddress!, 8) }
        if ok, let payload = payload, !payload.isEmpty {
            ok = payload.withUnsafeBytes { raw in writeAll(raw.baseAddress!, raw.count) }
        }
        if !ok {
            inputClosed = true   // the module is going away; onExit follows
        }
    }

    private func noteGesture() {
        gestureLock.lock()
        gestureAt = Self.nowMs()
        gestureLock.unlock()
    }

    /// True when the player clicked or pressed a key in this module in the last `gestureWindowMs`, and uses that up:
    /// a door's OpenUrl or Paste needs one each, so a board can't open pages or read the clipboard by itself.
    func takeGesture() -> Bool {
        gestureLock.lock()
        let at = gestureAt
        gestureAt = 0
        gestureLock.unlock()
        return at != 0 && Self.nowMs() - at <= Self.gestureWindowMs
    }

    /// The clipboard's text as a paste (engine_contract.h TE_IN_PASTE): line breaks as '\n', tabs kept, every other
    /// control character dropped, at most `pasteMax` units (never half a surrogate pair), all its records written in
    /// one go. Only while the module has text input on.
    func sendPaste(_ text: String) {
        let units = Self.cleanPaste(text)
        if units.isEmpty {
            return
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity((units.count + 2) * 8)
        func record(_ type: UInt8, _ flags: UInt8, _ a: UInt16) {
            bytes += [type, flags, UInt8(a & 0xFF), UInt8(a >> 8), 0, 0, 0, 0]
        }
        record(Self.inPaste, 1, UInt16(units.count))
        for unit in units {
            record(Self.inText, 0, unit)
        }
        record(Self.inPaste, 0, 0)
        inputLock.lock()
        defer { inputLock.unlock() }
        if inputClosed || stopping {
            return
        }
        if !bytes.withUnsafeBytes({ raw in writeAll(raw.baseAddress!, raw.count) }) {
            inputClosed = true
        }
    }

    /// Text for a paste: CR LF and CR become LF, tabs and LF stay, other control characters go, capped.
    static func cleanPaste(_ text: String) -> [UInt16] {
        let u = Array(text.utf16)
        var out: [UInt16] = []
        out.reserveCapacity(min(u.count, pasteMax))
        var i = 0
        while i < u.count && out.count < pasteMax {
            var c = u[i]
            i += 1
            if c == 0x0D {
                if i < u.count && u[i] == 0x0A {
                    i += 1
                }
                c = 0x0A
            } else if (c < 0x20 && c != 0x0A && c != 0x09) || (c >= 0x7F && c < 0xA0) {
                continue
            }
            if (0xD800..<0xDC00).contains(c) {
                if i >= u.count || !(0xDC00..<0xE000).contains(u[i]) || out.count + 2 > pasteMax {
                    break
                }
                out.append(c)
                out.append(u[i])
                i += 1
                continue
            }
            if (0xDC00..<0xE000).contains(c) {
                continue   // half a pair on its own
            }
            out.append(c)
        }
        return out
    }

    /// A physical key: set-1 scancode, E0-extended flag and Windows virtual key (Services/PhysicalKeys.swift).
    func sendKey(scanCode: Int, extended: Bool, virtualKey: Int, pressed: Bool) {
        if pressed {
            noteGesture()
        }
        send(Self.inKey, UInt8((pressed ? 1 : 0) | (extended ? 2 : 0)), UInt16(truncatingIfNeeded: scanCode),
             Int16(truncatingIfNeeded: virtualKey))
    }

    /// A typed character, one UTF-16 code unit (a surrogate pair is two calls). Only sent in text input mode.
    func sendText(_ codeUnit: UInt16) {
        send(Self.inText, 0, codeUnit)
    }

    func sendMouseMove(dx: Int, dy: Int) {
        send(Self.inMouseMove, 0, 0, Int16(clamping: dx), Int16(clamping: dy))
    }

    /// button: 1 left, 2 middle, 3 right, 4 wheel up, 5 wheel down, 6 back, 7 forward.
    func sendMouseButton(_ button: Int, pressed: Bool) {
        if pressed && (1...3).contains(button) {
            noteGesture()
        }
        send(Self.inMouseButton, pressed ? 1 : 0, UInt16(truncatingIfNeeded: button))
    }

    /// Pointer modes: where the pointer is in the module's frame pixels, whether it's over the picture, and the
    /// buttons held (bit0 left, bit1 middle, bit2 right).
    func sendMousePos(x: Int, y: Int, over: Bool, buttons: Int) {
        send(Self.inMousePos, over ? 1 : 0, UInt16(truncatingIfNeeded: buttons),
             Int16(clamping: x), Int16(clamping: y))
    }

    /// A gamepad button (engine_contract.h TE_PAD_BUTTON_*) on pad 0-3.
    func sendPadButton(pad: Int, button: Int, pressed: Bool) {
        send(Self.inPadButton, pressed ? 1 : 0, UInt16(truncatingIfNeeded: button), Int16(clamping: pad))
    }

    /// A stick or trigger (TE_PAD_AXIS_*) on pad 0-3: sticks -32768..32767 (down/right positive), triggers 0..32767.
    func sendPadAxis(pad: Int, axis: Int, value: Int) {
        send(Self.inPadAxis, 0, UInt16(truncatingIfNeeded: axis), Int16(clamping: value), Int16(clamping: pad))
    }

    /// A pad was plugged in or removed.
    func sendPadDevice(pad: Int, connected: Bool) {
        send(Self.inPadDevice, connected ? 1 : 0, UInt16(truncatingIfNeeded: pad))
    }

    func sendFocus(_ focused: Bool) {
        send(Self.inFocus, focused ? 1 : 0, 0)
    }

    /// Data from the door for this module (up to 65535 bytes), e.g. the fractal viewport.
    func sendData(_ payload: Data) {
        if payload.count > 0 && payload.count <= Int(UInt16.max) {
            send(Self.inData, 0, UInt16(payload.count), payload: payload)
        }
    }

    /// The device-pixel size the module is shown at, and the display scale in percent (0 = unknown; 1.1.6).
    func sendResize(width: Int, height: Int, scalePercent: Int = 0) {
        send(Self.inResize, 0, UInt16(clamping: max(0, scalePercent)),
             Int16(clamping: max(0, width)), Int16(clamping: max(0, height)))
    }

    /// Asks the module to quit the way it normally would (Doom shows its quit prompt).
    func requestQuit() {
        send(Self.inQuit, 0, 0)
    }

    // MARK: - Shutdown

    /// Stops the module: EOF on its stdin (it quits by itself), then a kill after 2 s. Safe to call twice.
    func dispose() {
        stateLock.lock()
        if disposed {
            stateLock.unlock()
            return
        }
        disposed = true
        stoppingFlag = true
        stateLock.unlock()

        if let audio = audio {
            if audioAttached {
                SyncTermAudioService.removeTraceStream(audio)
            }
            audio.clear()
        }
        inputLock.lock()
        if !inputClosed {
            inputClosed = true
        }
        try? stdinHandle.close()   // EOF: the module quits by itself
        inputLock.unlock()

        if process.isRunning {
            let deadline = Date().addingTimeInterval(2.0)
            while process.isRunning && Date() < deadline {
                usleep(10_000)
            }
            if process.isRunning {
                process.terminate()
                let killAt = Date().addingTimeInterval(0.5)
                while process.isRunning && Date() < killAt {
                    usleep(10_000)
                }
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
        }

        // The reader thread may still be inside a copy: take the map lock before the mapping goes
        mapLock.lock()
        unmapped = true
        munmap(base, frameBytes)
        close(frameFd)
        unlink(framePath)   // the session's frame file is deleted when it ends
        mapLock.unlock()
    }
}
