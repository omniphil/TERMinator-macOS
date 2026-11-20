import AppKit
import Compression
import CryptoKit
import os.log

private let traceLogger = Logger(subsystem: "com.terminator.macos", category: "TRACE")

/// Runs the TRACE (TERMinator Render And Compute Engine) modules a door asks for during a BBS session. The door sends
/// APC commands in the terminal stream, which the native bridge queues (Bridge/apc/trace_bridge.c):
///   Open;module=fractal;wasm=<sha256>;size=<bytes>;rect=1,1,23,79[;exclusive=1]
///                                            run the door's WebAssembly module (sandboxed) over those terminal cells
///                                            (rows/cols, 1-based). Cached: reply Ready. Not cached: reply Need, and the
///                                            door uploads it with Put;module=fractal;offset=<n>;data=<base64> chunks
///                                            then PutDone;module=fractal; TRACE checks the SHA-256, caches and runs it.
///   Data;module=fractal;<payload>            pass the payload to the module (the fractal viewport); with
///                                            "b64=<base64>" instead, the payload is binary. A module sends bytes
///                                            back the same way: TERMinator relays them as Data;module=<id>;b64=...
///   Asset;module=doom;sha256=<hex>;size=<n>  an asset the module will read (a WAD): reply Have when it's already
///                                            cached, else NeedAsset and the door uploads it with the same Put /
///                                            PutDone chunks, plus asset=<hex>
///   Put;...;enc=gz                           (Query reply gz=1) the chunks are a gzip stream of the module or asset:
///                                            offsets count the compressed bytes, every chunk of the upload carries
///                                            enc=gz, and TRACE inflates it (never past the declared size) before the
///                                            SHA-256 check. Size and sha256 in Open/Asset stay the real file's.
///   OpenUrl;module=x;url=<base64>        (Query reply url=1) open an http/https address (at most 2048 bytes) in the
///                                            player's browser: a link clicked in the module. Only within 3 s of a
///                                            click or key in that module, one per click (EngineModuleHost.takeGesture)
///   Paste;module=x                           (Query reply paste=1) paste the clipboard into the module (TE_IN_PASTE),
///                                            as Cmd+V / Ctrl+V does, for a Paste item in its own menu: text input on,
///                                            and the same click-or-key rule, so a board can't read the clipboard unasked
///   Hide|Show;module=fractal                 hide the picture (e.g. while the door shows ANSI help) or show it again.
///                                            (Query reply keep=1, 1.1.6) a hidden module keeps running without the
///                                            keyboard, mouse or gamepads; an Open of it answers Ready;resumed=1 at
///                                            once, the module as it was. Closed;code=0;error=expired after 10 minutes
///                                            hidden, or when another module needs its place
///   Close;module=fractal                     stop the module
/// A drawing module (fractal) sits over its terminal cells and the keyboard stays with the terminal, so the door keeps
/// reading keys. An exclusive module (doom) fills the terminal area and takes the keyboard until it quits. When a
/// module ends by itself, or can't start, the door is told:
/// ESC _ TERMinator:TRACE;Closed;module=<id>;code=<n>[;error=...] ESC \.
///
/// Port of the Windows client's `Services/TraceSessionManager.cs` (the master). Pictures sit in TerminalView's
/// engine layer (`TraceEngineLayer`), separate from TAP+. Main thread only (TerminalViewModel's poll drains the
/// native queue into `handle`).
final class TraceSessionManager: ObservableObject {
    static let shared = TraceSessionManager()

    private static let maxSessions = 2

    final class Session: Identifiable {
        let module: TraceModules.Module
        let host: EngineModuleHost
        var row1 = 1, col1 = 1, row2 = Int.max, col2 = Int.max
        var hidden = false
        /// Closes a hidden module (keep=1) in time (`hiddenKeep`).
        var hiddenTimer: Timer?
        /// The door opened it with bin=1: its messages go back as binary frames, not base64.
        var binary = false
        /// The module has text input on: it has the keyboard, and typed characters go to it.
        var textInputOn = false
        /// The mouse mode it picked (engine_contract.h TE_MOUSE_*; 0 = the mouse stays the terminal's).
        var mouseMode = 0

        /// The layer drawing it now (SwiftUI may re-create it; Show after Hide does).
        weak var layerView: EngineHostLayerView?
        /// Its newest frame as shown, for a held picture (Close;hold=1).
        private(set) var lastImage: CGImage?
        private(set) var lastAspect43 = true
        private var shownFrame = false
        /// The module's first frame is on screen (a held picture of its last run can go).
        var onFirstFrame: (() -> Void)?

        init(module: TraceModules.Module, host: EngineModuleHost) {
            self.module = module
            self.host = host
        }

        /// The layer drew a frame (EngineHostLayerView.onFrameDrawn).
        func frameDrawn(_ image: CGImage, _ aspect43: Bool) {
            lastImage = image
            lastAspect43 = aspect43
            if !shownFrame {
                shownFrame = true
                // On the next turn, so the frame is on screen before what's under it goes (Windows: Render priority)
                DispatchQueue.main.async { [weak self] in
                    self?.onFirstFrame?()
                }
            }
        }

        var id: ObjectIdentifier { ObjectIdentifier(self) }
        var moduleId: String { module.id }
    }

    /// Running modules, in the order they opened (the engine layer draws them in this order).
    @Published private(set) var sessions: [Session] = []

    /// True while the terminal is on screen with a session (TerminalView). Off: nothing starts, and everything that
    /// was running is closed (Windows: `_terminal()` returns null once the terminal leaves the content area).
    private(set) var terminalActive = false

    /// A module or an asset being uploaded, and (for a module) the Open that asked for it.
    private final class Upload {
        let sha256: String
        let size: Int
        let openArgs: String
        var data = Data()
        /// An asset (a WAD or similar) rather than the module itself.
        let isAsset: Bool
        /// Its Puts carry enc=gz (`gunzip`): data is the gzip stream, offsets count it, and finishUpload inflates it
        /// to size bytes before the hash check. Set by the first chunk; every later one must agree.
        var gzip = false

        init(sha256: String, size: Int, openArgs: String, isAsset: Bool) {
            self.sha256 = sha256
            self.size = size
            self.openArgs = openArgs
            self.isAsset = isAsset
        }
    }

    /// Keyed by the lower-cased module id, or module + "#" + hash for an asset (several can be in flight).
    private var uploads: [String: Upload] = [:]

    /// Assets each module has been given (cached paths), so the cache limit never drops one in use.
    private var assets: [String: [URL]] = [:]

    /// The board this session is with (TerminalViewModel sets it on connect), recorded beside what its doors cache
    /// (Settings lists it). Windows passes it to the constructor as `bbsName`.
    var bbsName: String?

    /// The same board as host:port, which the player's permissions for their imported files are kept by
    /// (TerminalViewModel sets it on connect, as it does bbsName).
    var bbsKey: String?

    /// An Import is waiting on the player (only one question at a time).
    private var importAsking = false

    /// Gamepads, watched while any module runs; their events go to every running module.
    private let pads = GamepadService()

    /// Keys an exclusive module has been told are down (keyCodes), so they can be released when focus leaves.
    private var held = Set<UInt16>()

    private var windowObservers: [NSObjectProtocol] = []
    private var appObservers: [NSObjectProtocol] = []
    private var defaultsObserver: NSObjectProtocol?
    private var lastEnabled: Bool?

    private init() {
        pads.onDeviceChanged = { [weak self] pad, connected in
            self?.forEachHost { $0.sendPadDevice(pad: pad, connected: connected) }
        }
        pads.onButtonChanged = { [weak self] pad, button, pressed in
            self?.forEachHost { $0.sendPadButton(pad: pad, button: button, pressed: pressed) }
        }
        pads.onAxisChanged = { [weak self] pad, axis, value in
            self?.forEachHost { $0.sendPadAxis(pad: pad, axis: axis, value: value) }
        }
        let center = NotificationCenter.default
        appObservers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                               queue: .main) { [weak self] _ in self?.pads.active = true })
        appObservers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil,
                                               queue: .main) { [weak self] _ in self?.pads.active = false })
        // TRACE on/off takes effect as soon as it changes: what doors are told when they ask, and running modules
        // stop when it's switched off (Windows does this on SAVE; here every Preferences control applies at once)
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.applySettings()
        }
    }

    /// App start and every settings change: the Query reply, and stop modules when TRACE was switched off.
    func applySettings() {
        let enabled = TraceModules.enabled
        NativeBridge.shared.traceSetModules(TraceModules.capabilities(enabled: enabled))
        if lastEnabled == true && !enabled {
            disable()
        }
        lastEnabled = enabled
    }

    /// TerminalView appeared / went away.
    func setTerminalActive(_ active: Bool) {
        terminalActive = active
        if !active {
            closeAll()
        }
    }

    /// True while a module that owns the keyboard (a game) is running and showing (a hidden one, kept running for
    /// the board, has given the keyboard back).
    var hasExclusive: Bool {
        sessions.contains { $0.module.exclusive && !$0.hidden }
    }

    /// True while a module has the keyboard: an exclusive one, or any with text input on. Every key in the main
    /// window then stops at TRACE (Windows: MainWindow's PreviewKeyDown checks `OwnsKeyboard`). Not a hidden one.
    var ownsKeyboard: Bool {
        sessions.contains { !$0.hidden && ($0.module.exclusive || $0.textInputOn) }
    }

    /// The session keys go to right now: a module with text input on comes first, so a text-input module and a
    /// running game never both act on one key. A hidden module (keep=1) gets none.
    private var keyboardSession: Session? {
        sessions.first { !$0.hidden && $0.textInputOn } ?? sessions.first { !$0.hidden && $0.module.exclusive }
    }

    /// Runs body for every module showing (the pad events go to all of them; a hidden one, kept running for the
    /// board, gets none, as Windows' UpdatePadTargets leaves it out).
    private func forEachHost(_ body: (EngineModuleHost) -> Void) {
        for session in sessions where !session.hidden {
            body(session.host)
        }
    }

    /// Polls the pads only while a module runs.
    private func updatePads() {
        if sessions.isEmpty {
            pads.stop()
        } else {
            pads.start()
        }
    }

    private func session(_ id: String) -> Session? {
        sessions.first { $0.module.id.caseInsensitiveCompare(id) == .orderedSame }
    }

    private static func uploadKey(_ id: String, _ assetHash: String?) -> String {
        let key = id.lowercased()
        return assetHash.map { key + "#" + $0 } ?? key
    }

    private func tellDoorClosed(_ id: String, _ code: Int, _ error: String? = nil) {
        tellDoor("Closed;module=\(id);code=\(code)" + (error.map { ";error=\($0)" } ?? ""))
    }

    private func tellDoor(_ message: String) {
        guard let data = "\u{1B}_TERMinator:TRACE;\(message)\u{1B}\\".data(using: .utf8) else { return }
        sendToDoor(data)
    }

    /// Everything TRACE sends the door goes out on one serial queue, in the order it was asked for: conn_send waits
    /// up to 1 s for room when the link's out buffer is full, which on the main thread froze the UI while a module
    /// streamed. conn_send is thread-safe (it locks conn_outbuf); the bridge counts the bytes (g_bytes_sent).
    private let doorQueue = DispatchQueue(label: "TRACE door send")

    private func sendToDoor(_ data: Data) {
        doorQueue.async {
            _ = NativeBridge.shared.sendData(data)
        }
    }

    /// Fields "a=b;c=d" (keys case-insensitive, first one wins).
    private static func parseFields(_ args: String) -> [String: String] {
        var fields: [String: String] = [:]
        for field in args.components(separatedBy: ";") {
            guard let eq = field.firstIndex(of: "=") else { continue }
            let key = String(field[field.startIndex..<eq]).lowercased()
            if fields[key] == nil {
                fields[key] = String(field[field.index(after: eq)...])
            }
        }
        return fields
    }

    private static func isHex64(_ s: String) -> Bool {
        s.count == 64 && s.allSatisfy { $0.isHexDigit }
    }

    private static func fromBase64(_ text: String) -> Data {
        Data(base64Encoded: text) ?? Data()
    }

    /// One queued command, without its "TERMinator:TRACE;" prefix. Unknown or malformed commands are ignored.
    func handle(_ command: String) {
        // Verb;module=<id>[;rest] -- for Data the rest is the module's payload, passed on untouched
        let parts = command.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, parts[1].lowercased().hasPrefix("module=") else { return }
        let verb = parts[0]
        let id = String(parts[1].dropFirst("module=".count))
        let rest = parts.count > 2 ? parts[2] : ""
        let current = session(id)

        switch verb {
        case "Open":
            open(id, current, rest)
        case "Data":
            guard let current = current else { return }
            // Text as the door wrote it, or "b64=<base64>" when it's binary (a game's state updates)
            let payload = rest.lowercased().hasPrefix("b64=")
                ? Self.fromBase64(String(rest.dropFirst(4)))
                : Data(rest.utf8)
            if payload.count > 0 && payload.count <= Int(UInt16.max) {
                current.host.sendData(payload)
            }
        case "OpenUrl":
            guard let current = current else { return }
            openUrl(current, Self.parseFields(rest)["url"])
        case "Paste":
            guard let current = current else { return }
            if !current.hidden && current.textInputOn && current.host.takeGesture() {
                Self.pasteFromClipboard(current)
            }
        case "Hide":
            guard let current = current else { return }
            hide(current)
        case "Show":
            guard let current = current else { return }
            unhide(current)
            objectWillChange.send()
        case "Close":
            if let current = current {
                // hold=1: Rainwire closed it only to run a transfer (it reopens after): keep its last frame up,
                // dimmed, until it does. Unknown keys are ignored.
                if Self.parseFields(rest)["hold"] == "1" {
                    hold(current)
                }
                close(current)
            } else {
                // Closed before its module or assets finished uploading
                let key = id.lowercased()
                for k in uploads.keys where k == key || k.hasPrefix(key + "#") {
                    uploads.removeValue(forKey: k)
                }
            }
        case "Asset":
            offerAsset(id, rest)
        case "Import":
            importOwnFile(id, rest)
        case "Put":
            receiveChunk(id, rest)
        case "PutDone":
            finishUpload(id, Self.parseFields(rest)["asset"])
        default:
            break
        }
    }

    /// A door's OpenUrl: the address (base64 UTF-8) opens in the player's browser when it's http or https, at most
    /// 2048 bytes with no spaces or control characters, and the player clicked or pressed a key in that module in the
    /// last few seconds (used up, so one click opens one page). Anything else is dropped without a word.
    private func openUrl(_ session: Session, _ b64: String?) {
        guard let b64 = b64, !b64.isEmpty, b64.count <= 4096, !session.hidden,
              let data = Data(base64Encoded: b64), let text = String(data: data, encoding: .utf8),
              Self.isWebUrl(text), let url = URL(string: text), session.host.takeGesture() else { return }
        NSWorkspace.shared.open(url)
    }

    /// An http or https address with a host, no user name, no spaces or control characters, not too long.
    static func isWebUrl(_ text: String) -> Bool {
        if text.isEmpty || text.utf8.count > 2048
            || text.unicodeScalars.contains(where: { $0.value <= 0x20 || ($0.value >= 0x7F && $0.value < 0xA0) }) {
            return false
        }
        guard let parts = URLComponents(string: text), let scheme = parts.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil else { return false }
        return true
    }

    /// Pastes the clipboard's text into a module with text input on (TE_IN_PASTE): Cmd+V / Ctrl+V / Shift+Insert, or
    /// the door's Paste request (which checked the player just clicked or pressed a key there).
    private static func pasteFromClipboard(_ session: Session) {
        guard session.textInputOn, let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        session.host.sendPaste(text)
    }

    /// Cmd+V or Ctrl+V (no Shift or Option), or Shift+Insert (the Help key on a Mac keyboard, 114): a paste.
    private static func isPasteKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.keyCode == 9 {   // kVK_ANSI_V
            return mods == .command || mods == .control
        }
        return event.keyCode == 114 && mods == .shift
    }

    /// A binary frame from the door: a header line (the command, as in a text command) then the raw payload. Data
    /// goes to the module and Put is an upload chunk, both without base64; anything else is handled as its header.
    func handleBinary(_ frame: Data) {
        let newline = frame.firstIndex(of: 0x0A)
        let headerEnd = newline ?? frame.endIndex
        let header = String(decoding: frame[frame.startIndex..<headerEnd], as: UTF8.self)
        let payload = newline.map { Data(frame[frame.index(after: $0)...]) } ?? Data()
        let parts = header.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, parts[1].lowercased().hasPrefix("module=") else { return }
        let id = String(parts[1].dropFirst("module=".count))
        let rest = parts.count > 2 ? parts[2] : ""
        switch parts[0] {
        case "Data":
            if let current = session(id), payload.count > 0 && payload.count <= Int(UInt16.max) {
                current.host.sendData(payload)
            }
        case "Put":
            receiveChunk(id, Self.parseFields(rest), payload)
        default:
            handle(header)
        }
    }

    /// Wraps bytes as a binary frame for the door: '=' and the byte + 64 stands for a byte that mustn't travel raw,
    /// the escaping the door uses towards us (trace_bridge.c). The door escapes only the nine bytes a link could
    /// touch on the way here; this way every control byte is escaped too, since a door often reads through a
    /// pseudo-terminal that would act on Ctrl-C, Ctrl-Z or XON/XOFF or turn CR into LF. It's the small direction
    /// (input, saves), so the few percent extra don't matter. The decoding is the same either way.
    private static func binaryFrame(_ header: String, _ payload: Data) -> Data {
        var frame = Data("\u{1B}_TERMinator:TRACE;Bin;".utf8)
        frame.reserveCapacity(header.utf8.count + payload.count + payload.count / 16 + 32)
        func put(_ b: UInt8) {
            if b < 0x20 || b == UInt8(ascii: "=") || b == 0x7F || b == 0xFF {
                frame.append(UInt8(ascii: "="))
                frame.append(b &+ 64)
            } else {
                frame.append(b)
            }
        }
        for b in Data((header + "\n").utf8) {
            put(b)
        }
        for b in payload {
            put(b)
        }
        frame.append(0x1B)
        frame.append(UInt8(ascii: "\\"))
        return frame
    }

    // MARK: - The player's own copy of a file (Import)

    /// The door asks for the player's own copy of a file (Import). Nothing crosses the link: the player picks the
    /// file, TRACE checks its hash against what the door expects and keeps it like an asset, so the module reads it
    /// by hash. Every board is asked about once per file, and the answer is kept (Settings lists and deletes them).
    private func importOwnFile(_ id: String, _ args: String) {
        let fields = Self.parseFields(args)
        // The door lists them in ITS preference order (newest release first, say), so keep that order and only
        // drop repeats -- Windows does the same with .Distinct().Take(16).
        var seen = Set<String>()
        let hashes = (fields["sha256"] ?? "").lowercased().components(separatedBy: ",")
            .filter { Self.isHex64($0) && seen.insert($0).inserted }
            .prefix(16).map { $0 }
        var name = String((fields["name"] ?? "")
            .filter { ch in ch.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) } }
            .prefix(60)).trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            name = "a file"
        }
        guard TraceModules.enabled else {
            tellDoor("NoImport;module=\(id);reason=disabled")
            return
        }
        guard !hashes.isEmpty else {
            tellDoor("NoImport;module=\(id);reason=bad-import")
            return
        }
        guard !importAsking else {
            tellDoor("NoImport;module=\(id);reason=busy")
            return
        }
        let key = bbsKey ?? "unknown"
        let board = bbsName ?? key
        importAsking = true

        // Imported before: this board may use it if the player allowed it, or says so now
        for hash in hashes {
            let path = TraceModules.cachedAssetPath(hash)
            guard FileManager.default.fileExists(atPath: path.path), TraceModules.isImported(path) else { continue }
            if !TraceModules.isGranted(path, bbsKey: key) {
                let known = TraceModules.importedName(path) ?? name
                let allowed = ask(title: "USE YOUR FILE?",
                                  message: "\(board) would like its door to use your copy of \(known), which you "
                                         + "imported earlier.\n\nThe file stays on your Mac: the board never "
                                         + "receives it.",
                                  yes: "ALLOW", no: "DON'T ALLOW")
                if !allowed {
                    importAsking = false
                    tellDoor("NoImport;module=\(id);reason=declined")
                    return
                }
            }
            TraceModules.recordImport(path, name: name, bbsKey: key, bbsName: board)
            keepAsset(id, path)
            importAsking = false
            tellDoor("Have;module=\(id);sha256=\(hash)")
            return
        }

        // Not here yet: ask the player for their copy
        var question = "\(board) would like to use your own copy of \(name).\n\nChoose the file and TERMinator "
                     + "checks it is the right one. It stays on your Mac: the board never receives it."
        while true {
            guard ask(title: "USE YOUR OWN FILE", message: question, yes: "CHOOSE FILE...", no: "NOT NOW") else {
                importAsking = false
                tellDoor("NoImport;module=\(id);reason=declined")
                return
            }
            let panel = NSOpenPanel()
            panel.title = "Choose your copy of \(name)"
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.canChooseFiles = true
            guard panel.runModal() == .OK, let chosen = panel.url else {
                continue   // back to the question
            }
            let (hash, kept) = TraceModules.importFile(chosen, expected: hashes)
            if kept, let hash = hash {
                let path = TraceModules.cachedAssetPath(hash)
                TraceModules.recordImport(path, name: name, bbsKey: key, bbsName: board)
                keepAsset(id, path)
                importAsking = false
                tellDoor("Have;module=\(id);sha256=\(hash)")
                return
            }
            question = hash == nil
                ? "That file couldn't be read, or is over \(TraceModules.maxImportBytes >> 20) MB."
                  + "\n\n\(board) is asking for your own copy of \(name)."
                : "That file isn't the copy of \(name) this door knows (it may be a different version or release)."
                  + "\n\nTry another file?"
        }
    }

    /// A question for the player: true for yes, false for no. Modal, like the file picker it leads to.
    private func ask(title: String, message: String, yes: String, no: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: yes)
        alert.addButton(withTitle: no)
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Every cached file a running module might still be reading, so the cache limit leaves them alone.
    private func inUse(_ extra: URL...) -> [URL] {
        extra + assets.values.flatMap { $0 }
    }

    /// The cached files running modules are using (their .wasm and the assets they were given), which Settings
    /// won't delete: a module reads its assets while it runs.
    var filesInUse: [URL] {
        sessions.compactMap { $0.module.cachePath } + assets.values.flatMap { $0 }
    }

    /// The door offers an asset its module will read (a WAD, a tileset). Cached already: say so and the door moves
    /// on. Otherwise it uploads it in the same chunks as a module, and the hash is checked the same way.
    private func offerAsset(_ id: String, _ args: String) {
        let fields = Self.parseFields(args)
        let hash = (fields["sha256"] ?? "").lowercased()
        let size = Int(fields["size"] ?? "") ?? 0
        let validSize = size > 0 && size <= TraceModules.maxAssetBytes
        guard TraceModules.enabled, Self.isHex64(hash), validSize else {
            tellDoorClosed(id, -1, !TraceModules.enabled ? "disabled" : "bad-asset")
            return
        }
        let path = TraceModules.cachedAssetPath(hash)
        // A file the player imported is only this board's to use if they said so (Import asks); otherwise it's as
        // if it weren't here, so a door can't find out what the player owns by offering its hash
        let hidden = TraceModules.isImported(path)
            && !TraceModules.isGranted(path, bbsKey: bbsKey ?? "")
        if !hidden, let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
           let length = attrs[.size] as? NSNumber, length.intValue == size {
            keepAsset(id, path)
            tellDoor("Have;module=\(id);sha256=\(hash)")
            return
        }
        uploads[Self.uploadKey(id, hash)] = Upload(sha256: hash, size: size, openArgs: "", isAsset: true)
        tellDoor("NeedAsset;module=\(id);sha256=\(hash)")
    }

    /// Remembers that this module uses an asset, marks the file as recently used for the cache limit, and records
    /// what it is beside it (Settings lists it).
    private func keepAsset(_ id: String, _ path: URL) {
        let key = id.lowercased()
        var list = assets[key] ?? []
        if !list.contains(where: { $0.path == path.path }) {
            list.append(path)
        }
        assets[key] = list
        TraceModules.touch(path)
        TraceModules.recordUse(path, moduleId: id, isAsset: true, bbs: bbsName)
    }

    private func receiveChunk(_ id: String, _ args: String) {
        let fields = Self.parseFields(args)
        receiveChunk(id, fields, Self.fromBase64(fields["data"] ?? ""))
    }

    /// One upload chunk, from a text Put (base64) or a binary one (raw).
    private func receiveChunk(_ id: String, _ fields: [String: String], _ chunk: Data) {
        let key = Self.uploadKey(id, fields["asset"]?.lowercased())
        guard let upload = uploads[key] else { return }
        // enc=gz (offered as gz=1): the chunks are a gzip stream of the file; any other encoding is one we don't know
        let enc = fields["enc"]
        let gzip = enc == "gz"
        let limit = gzip ? Self.maxCompressed(upload.size) : upload.size
        // Chunks must arrive in order, all in the same encoding, and never run past the size the door declared
        guard let offset = Int(fields["offset"] ?? ""), offset == upload.data.count,
              chunk.count > 0, upload.data.count + chunk.count <= limit,
              enc == nil || gzip, offset == 0 || gzip == upload.gzip else {
            uploads.removeValue(forKey: key)
            tellDoorClosed(id, -1, "bad-upload")
            return
        }
        upload.gzip = gzip
        upload.data.append(chunk)
    }

    private func finishUpload(_ id: String, _ assetHash: String?) {
        let key = Self.uploadKey(id, assetHash?.lowercased())
        guard let upload = uploads.removeValue(forKey: key) else { return }
        // A gzip upload is inflated first (never past the declared size), then checked like any other
        guard let data = upload.gzip ? Self.gunzip(upload.data, size: upload.size) : Optional(upload.data) else {
            tellDoorClosed(id, -1, upload.isAsset ? "bad-asset" : "bad-module")
            return
        }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard data.count == upload.size, hash == upload.sha256 else {
            tellDoorClosed(id, -1, upload.isAsset ? "bad-asset" : "bad-module")
            return
        }
        let path = upload.isAsset ? TraceModules.cachedAssetPath(hash) : TraceModules.cachedModulePath(hash)
        do {
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: path, options: .atomic)
            if !upload.isAsset {
                TraceModules.recordUse(path, moduleId: id, isAsset: false, bbs: bbsName)  // an asset's: keepAsset
            }
            TraceModules.enforceCacheLimit(TraceModules.cacheLimitMb, keep: inUse(path))
        } catch {
            tellDoorClosed(id, -1, "cache")
            return
        }
        if upload.isAsset {
            keepAsset(id, path)
            tellDoor("Have;module=\(id);sha256=\(hash)")
            return
        }
        open(id, session(id), upload.openArgs)
    }

    /// The most a gzip stream for a file of `size` bytes may be: gzip of data that won't compress is a little bigger
    /// than the data (5 bytes per 64 KB stored block, 18 of header and trailer). Windows: TraceGzip.MaxCompressed.
    static func maxCompressed(_ size: Int) -> Int { size + size / 64 + 1024 }

    /// The file a gzip upload carries (Windows: TraceGzip.Gunzip): exactly `size` bytes (the size the door declared,
    /// already held to the module / asset caps), or nil when the stream is broken, comes out shorter, or would come
    /// out longer. Inflating stops one byte past the declared size, so a zip bomb never gets further than that.
    /// One gzip member (RFC 1952): the header is skipped here and the raw DEFLATE body goes to the Compression
    /// framework (COMPRESSION_ZLIB is raw DEFLATE, RFC 1951); the trailer's length must match. The SHA-256 check
    /// after this covers the content, so the trailer's CRC isn't checked again.
    static func gunzip(_ gz: Data, size: Int) -> Data? {
        let b = [UInt8](gz)
        guard size > 0, b.count >= 18, b[0] == 0x1F, b[1] == 0x8B, b[2] == 8 else { return nil }
        let flags = b[3]
        guard flags & 0xE0 == 0 else { return nil }   // reserved bits
        var at = 10
        if flags & 0x04 != 0 {   // FEXTRA
            guard at + 2 <= b.count else { return nil }
            let xlen = Int(b[at]) | (Int(b[at + 1]) << 8)
            at += 2 + xlen
        }
        for flag: UInt8 in [0x08, 0x10] where flags & flag != 0 {   // FNAME, FCOMMENT: zero-terminated
            while at < b.count && b[at] != 0 { at += 1 }
            at += 1
        }
        if flags & 0x02 != 0 { at += 2 }   // FHCRC
        let end = b.count - 8
        guard at < end else { return nil }
        let isize = UInt32(b[end + 4]) | UInt32(b[end + 5]) << 8 | UInt32(b[end + 6]) << 16 | UInt32(b[end + 7]) << 24
        guard isize == UInt32(truncatingIfNeeded: size) else { return nil }
        let capacity = size + 1
        var output = [UInt8](repeating: 0, count: capacity)
        let written = output.withUnsafeMutableBufferPointer { dst -> Int in
            b.withUnsafeBufferPointer { src -> Int in
                guard let d = dst.baseAddress, let s = src.baseAddress else { return 0 }
                return compression_decode_buffer(d, capacity, s + at, end - at, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { return nil }
        return Data(output[0..<size])
    }

    private func open(_ id: String, _ existing: Session?, _ args: String) {
        let fields = Self.parseFields(args)

        // rect=row1,col1,row2,col2 (inclusive); the whole screen when it's missing or malformed
        var rect = (row1: 1, col1: 1, row2: Int.max, col2: Int.max)
        if let text = fields["rect"] {
            let n = text.components(separatedBy: ",").map { Int($0) }
            if n.count == 4, let r1 = n[0], let c1 = n[1], let r2 = n[2], let c2 = n[3],
               r1 >= 1, c1 >= 1, r2 >= r1, c2 >= c1 {
                rect = (r1, c1, r2, c2)
            }
        }

        var target = existing
        if target == nil {
            // A door that waits for an answer must always get one, including when nothing starts
            if !TraceModules.enabled {
                tellDoorClosed(id, -1, "disabled")
                return
            }
            var found: TraceModules.Module?
            if var sha256 = fields["wasm"] {
                // The door's own WebAssembly module: run it from the cache, or ask the door to send it
                sha256 = sha256.lowercased()
                let size = Int(fields["size"] ?? "") ?? 0
                let validSize = size > 0 && size <= TraceModules.maxModuleBytes
                if !Self.isHex64(sha256) || !validSize {
                    tellDoorClosed(id, -1, "bad-module")
                    return
                }
                if TraceModules.hostPath == nil || !terminalActive {
                    tellDoorClosed(id, -1, "not-installed")
                    return
                }
                let exclusive = fields["exclusive"] == "1"
                found = TraceModules.wasmModule(id: id, sha256: sha256, exclusive: exclusive)
                if found == nil {
                    uploads[Self.uploadKey(id, nil)] = Upload(sha256: sha256, size: size, openArgs: args,
                                                              isAsset: false)
                    tellDoor("Need;module=\(id);wasm=\(sha256)")
                    return
                }
                if let cached = found?.cachePath {
                    TraceModules.recordUse(cached, moduleId: id, isAsset: false, bbs: bbsName)
                }
            }
            // Every module comes from the door (wasm=...); there are no built-in ones
            guard let module = found, terminalActive else {
                tellDoorClosed(id, -1, "not-installed")
                return
            }
            makeRoom()
            if sessions.count >= Self.maxSessions || (module.exclusive && hasExclusive) {
                tellDoorClosed(id, -1, "busy")
                return
            }
            if let v = fields["v"], let version = Int(v), version > module.version {
                tellDoorClosed(id, -1, "version")  // the door needs a newer module than we have
                return
            }

            let host: EngineModuleHost
            do {
                host = try EngineModuleHost(exePath: module.exePath, moduleArgs: module.args,
                                            capacityWidth: module.capacityWidth,
                                            capacityHeight: module.capacityHeight, withAudio: true)
            } catch {
                traceLogger.error("TRACE: couldn't start \(module.exePath, privacy: .public): \(String(describing: error), privacy: .public)")
                tellDoorClosed(id, -1, "start-failed")
                return
            }
            let started = Session(module: module, host: host)
            // The module answering the door: a game's key presses, a score, whatever it sends. Base64 keeps it
            // binary-safe, and the send window (EngineModuleHost) keeps it from flooding the link.
            host.onDataForDoor = { [weak self, weak started] bytes in
                DispatchQueue.main.async {
                    guard let self = self, let started = started, !bytes.isEmpty,
                          self.sessions.contains(where: { $0 === started }) else { return }
                    started.host.countSent(bytes.count)
                    if started.binary {
                        self.sendToDoor(Self.binaryFrame("Data;module=\(started.module.id)", bytes))
                    } else {
                        self.tellDoor("Data;module=\(started.module.id);b64=\(bytes.base64EncodedString())")
                    }
                }
            }
            // Text input: the module takes the keyboard while it's on, and gives it back when it goes off
            host.onTextInputChanged = { [weak self, weak started] on in
                DispatchQueue.main.async {
                    guard let self = self, let started = started,
                          self.sessions.contains(where: { $0 === started }) else { return }
                    started.textInputOn = on
                    if !on {
                        // Send the ups rather than dropping them, or those keys stay down inside the module
                        self.releaseHeldKeys()
                    }
                    self.objectWillChange.send()
                }
            }
            host.onMouseModeChanged = { [weak self, weak started] mode in
                DispatchQueue.main.async {
                    guard let self = self, let started = started,
                          self.sessions.contains(where: { $0 === started }) else { return }
                    started.mouseMode = mode
                    self.objectWillChange.send()
                }
            }
            host.onPadRumble = { [weak self] pad, low, high, ms in
                DispatchQueue.main.async {
                    self?.pads.rumble(pad: pad, low: low, high: high, ms: ms)
                }
            }
            // The module ended by itself (the player quit Doom, or it crashed): tell the door
            host.onExit = { [weak self, weak started] code in
                DispatchQueue.main.async {
                    guard let self = self, let started = started,
                          self.sessions.contains(where: { $0 === started }) else { return }
                    // A module that died rather than quitting takes its reason with it, and the door is the only
                    // place anyone can see it: a sysop reads the door's log, a player never sees the debug output.
                    let reason = code != 0 ? started.host.crashReason : ""
                    self.close(started)
                    self.tellDoorClosed(started.module.id, code, reason.isEmpty ? nil : reason)
                }
            }
            sessions.append(started)
            if let heldNow = heldFrames.first(where: { $0.moduleId == id.lowercased() }) {
                // Reopened after a transfer: the held picture stays under the new layer until its first frame
                let serial = heldNow.id
                started.onFirstFrame = { [weak self] in
                    self?.releaseHeld(id)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self, weak started] in
                    guard let self = self, self.heldFrames.contains(where: { $0.id == serial }) else { return }
                    let current = self.session(id)
                    if current == nil || current === started {
                        self.releaseHeld(id)
                    }
                }
            }
            // The window observers release held keys when focus leaves; any module that can own the keyboard needs
            // them, not just an exclusive one (text input gives a drawing module the keyboard too).
            startExclusiveInput(started)
            updatePads()
            // Pads already plugged in (and held) are news to a module that has just started
            pads.replay(device: { host.sendPadDevice(pad: $0, connected: $1) },
                        button: { host.sendPadButton(pad: $0, button: $1, pressed: $2) },
                        axis: { host.sendPadAxis(pad: $0, axis: $1, value: $2) })
            target = started
            if host.hasExited {
                // Died before the handler was set: report it the same way
                let code = host.exitCode
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.sessions.contains(where: { $0 === started }) else { return }
                    // A module that died rather than quitting takes its reason with it, and the door is the only
                    // place anyone can see it: a sysop reads the door's log, a player never sees the debug output.
                    let reason = code != 0 ? started.host.crashReason : ""
                    self.close(started)
                    self.tellDoorClosed(started.module.id, code, reason.isEmpty ? nil : reason)
                }
            }
        }

        guard let session = target else { return }
        session.row1 = rect.row1
        session.col1 = rect.col1
        session.row2 = rect.row2
        session.col2 = rect.col2
        let resumed = session.hidden
        unhide(session)
        session.binary = fields["bin"] == "1"
        objectWillChange.send()
        if fields["wasm"] != nil {
            // also when re-opening one that's already running; resumed=1: it was hidden and kept running (keep=1)
            tellDoor("Ready;module=\(id)" + (resumed ? ";resumed=1" : ""))
        }
    }

    /// How long a hidden module is kept running for the board before it is closed (keep=1, 1.1.6).
    private static let hiddenKeep: TimeInterval = 10 * 60

    /// Hide: the picture goes and the module keeps running, without the keyboard, mouse or gamepads (keep=1 in the
    /// Query answer, 1.1.6). A board can open it again at once (Ready;resumed=1) and find it as it was, instead of
    /// starting it over. It is closed after `hiddenKeep` hidden, or when another module needs its place. Windows:
    /// TraceSessionManager.Hide + EngineHostLayer.Suspend; here the layer view goes with the picture (TraceEngineLayer
    /// draws no hidden session), which takes the mouse with it.
    private func hide(_ session: Session) {
        guard !session.hidden else { return }
        // Keys the module was told are down go up first, while it is still the keyboard's session
        if keyboardSession === session {
            releaseHeldKeys()
        }
        if session.module.exclusive {
            session.host.sendFocus(false)
        }
        session.hidden = true
        session.hiddenTimer?.invalidate()
        session.hiddenTimer = Timer.scheduledTimer(withTimeInterval: Self.hiddenKeep, repeats: false) { [weak self, weak session] _ in
            guard let self = self, let session = session, session.hidden,
                  self.sessions.contains(where: { $0 === session }) else { return }
            self.close(session)
            self.tellDoorClosed(session.module.id, 0, "expired")
        }
        objectWillChange.send()
    }

    /// Show again after Hide (a Show, or an Open of the same module): the keyboard and input come back.
    private func unhide(_ session: Session) {
        session.hiddenTimer?.invalidate()
        session.hiddenTimer = nil
        guard session.hidden else { return }
        session.hidden = false
        if session.module.exclusive && WindowSizeManager.mainWindow?.isKeyWindow == true {
            session.host.sendFocus(true)
        }
    }

    /// Room for one more module when all `maxSessions` are taken: hidden ones (kept for the board, keep=1) go.
    /// A hidden game never blocks another (hasExclusive leaves it out).
    private func makeRoom() {
        for s in sessions where s.hidden {
            if sessions.count < Self.maxSessions {
                break
            }
            close(s)
            tellDoorClosed(s.module.id, 0, "expired")
        }
    }

    private func close(_ session: Session) {
        session.hiddenTimer?.invalidate()
        session.hiddenTimer = nil
        guard let index = sessions.firstIndex(where: { $0 === session }) else { return }
        sessions.remove(at: index)
        assets.removeValue(forKey: session.module.id.lowercased())  // stay cached, but may now be trimmed
        session.textInputOn = false   // the keyboard goes back (ownsKeyboard reads the live sessions)
        if sessions.isEmpty {
            stopExclusiveInput()      // the last module went: the window observers go with it
        }
        updatePads()
        session.host.dispose()
    }

    // MARK: - Held pictures: a module closed for a transfer (Close;hold=1) stays on screen, dimmed, till it reopens

    /// A module's last frame, kept on screen while Rainwire runs a transfer with the module closed.
    struct HeldFrame: Identifiable {
        let id: Int              // a serial: a new hold of the same module is a new picture
        let moduleId: String     // lowercased
        let image: CGImage
        let aspect43: Bool
        let exclusive: Bool
        let row1: Int, col1: Int, row2: Int, col2: Int
    }

    /// Held pictures, drawn under the running modules (TraceEngineLayer).
    @Published private(set) var heldFrames: [HeldFrame] = []
    private var heldSerial = 0
    private var heldTimer: Timer?
    private var transfers = 0

    /// A module's layer view was made (RainwireFileDrops watches the Files module's). Windows: LayerOpened, raised
    /// once per start; here every time SwiftUI makes the view, which is when there's a new one to watch.
    var layerViewOpened: ((String, EngineHostLayerView) -> Void)?

    /// EngineHostLayerRepresentable made a view for session.
    func layerViewCreated(_ session: Session, _ view: EngineHostLayerView) {
        layerViewOpened?(session.module.id, view)
    }

    /// The running module's layer, or nil.
    func layerFor(_ id: String) -> EngineHostLayerView? {
        guard let s = session(id), !s.hidden else { return nil }
        return s.layerView
    }

    private func hold(_ session: Session) {
        guard !session.hidden, let image = session.lastImage else { return }
        releaseHeld(session.module.id)
        heldSerial += 1
        heldFrames.append(HeldFrame(id: heldSerial, moduleId: session.module.id.lowercased(), image: image,
                                    aspect43: session.lastAspect43, exclusive: session.module.exclusive,
                                    row1: session.row1, col1: session.col1, row2: session.row2, col2: session.col2))
        // A transfer normally starts within moments; if none does, the picture goes after a minute
        armHeldTimer(transfers > 0 ? nil : 60)
    }

    private func releaseHeld(_ id: String) {
        let key = id.lowercased()
        if heldFrames.contains(where: { $0.moduleId == key }) {
            heldFrames.removeAll { $0.moduleId == key }
        }
    }

    private func releaseAllHeld() {
        if !heldFrames.isEmpty {
            heldFrames.removeAll()
        }
        heldTimer?.invalidate()
        heldTimer = nil
    }

    private func armHeldTimer(_ after: TimeInterval?) {
        heldTimer?.invalidate()
        heldTimer = nil
        guard let after = after, !heldFrames.isEmpty else { return }
        heldTimer = Timer.scheduledTimer(withTimeInterval: after, repeats: false) { [weak self] _ in
            self?.releaseAllHeld()
        }
    }

    /// A file picker or the transfer window opened: held pictures stay while it's up.
    func transferStarted() {
        transfers += 1
        heldTimer?.invalidate()
        heldTimer = nil
    }

    /// It closed: held pictures go 15 s later unless their module reopens first.
    func transferEnded() {
        transfers = max(0, transfers - 1)
        if transfers == 0 {
            armHeldTimer(15)
        }
    }

    /// TRACE was switched off: stop every module and tell the doors, so they fall back to their own graphics.
    func disable() {
        releaseAllHeld()
        uploads.removeAll()
        assets.removeAll()
        for session in sessions {
            close(session)
            tellDoorClosed(session.module.id, -1, "disabled")
        }
    }

    /// Stops every module (disconnect, or the terminal left the screen).
    func closeAll() {
        releaseAllHeld()
        uploads.removeAll()
        assets.removeAll()
        for session in sessions {
            close(session)
        }
        // What's still queued for the door goes before the caller disconnects, never onto a later call's link
        doorQueue.sync {}
    }

    // MARK: - Keyboard of an exclusive module

    /// The exclusive session, if one is running and showing.
    private var exclusiveSession: Session? {
        sessions.first { $0.module.exclusive && !$0.hidden }
    }

    /// Installs the window observers that release held keys when focus leaves and report focus to an exclusive
    /// module. Every module that can own the keyboard needs them, and they belong to the manager rather than to one
    /// session, so a second module opening doesn't add a second copy.
    private func startExclusiveInput(_ session: Session) {
        held.removeAll()
        guard windowObservers.isEmpty else {
            if session.module.exclusive && WindowSizeManager.mainWindow?.isKeyWindow == true {
                session.host.sendFocus(true)
            }
            return
        }
        let center = NotificationCenter.default
        windowObservers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: nil,
                                                  queue: .main) { [weak self] note in
            guard let window = note.object as? NSWindow, window === WindowSizeManager.mainWindow else { return }
            self?.releaseHeldKeys()
            self?.exclusiveSession?.host.sendFocus(false)
        })
        windowObservers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil,
                                                  queue: .main) { [weak self] note in
            guard let window = note.object as? NSWindow, window === WindowSizeManager.mainWindow else { return }
            self?.exclusiveSession?.host.sendFocus(true)
        })
        if session.module.exclusive && WindowSizeManager.mainWindow?.isKeyWindow == true {
            session.host.sendFocus(true)
        }
        // Whatever the board was told is held goes up now: the module has the keyboard
        NativeBridge.shared.keyReleaseAll()
    }

    private func stopExclusiveInput() {
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        windowObservers.removeAll()
        held.removeAll()
    }

    private func releaseHeldKeys() {
        guard let session = keyboardSession else {
            held.removeAll()
            return
        }
        for keyCode in held {
            if let key = PCKeys.key(keyCode) {
                session.host.sendKey(scanCode: key.scan, extended: key.extended, virtualKey: key.vk, pressed: false)
            }
        }
        held.removeAll()
    }

    /// From `TerminalKeyMonitor`, when the last Command key went up: AppKit sent no keyUp for keys let go while it was
    /// down, so those still in `held` that are physically up are released now (nothing sticks in the game).
    func releaseKeysAfterCommand() {
        let gone = held.filter { !PCKeys.isModifier($0) && PCKeys.isPhysicallyUp($0) }
        guard !gone.isEmpty else { return }
        held.subtract(gone)
        guard let session = keyboardSession else { return }
        for keyCode in gone {
            if let key = PCKeys.key(keyCode) {
                session.host.sendKey(scanCode: key.scan, extended: key.extended, virtualKey: key.vk, pressed: false)
            }
        }
    }

    /// From `TerminalKeyMonitor`: true when a module took the key (it then goes nowhere else). While a module owns
    /// the keyboard -- an exclusive one (a game), or any with text input on -- a key in the main window stops here
    /// rather than reaching the controls behind it (Enter would open a board card); Windows swallows everything but
    /// Alt+Enter in MainWindow's PreviewKeyDown for the same reason. The full-screen toggle, a key while the picture
    /// is hidden, and anything typed while Preferences is over the terminal are NOT taken, and carry on as usual.
    /// Presses reach the module while its picture is showing and the main window is key; releases of keys it was
    /// told about always go through, so nothing sticks. Other windows (a sheet, the CRT panel) keep their keys.
    ///
    /// With text input on, the typed characters go with the keys: `event.characters` is what the player's keyboard
    /// layout made of it (Shift, AltGr and dead keys are already worked out by then, as Windows' TranslateMessage
    /// does), sent one UTF-16 unit at a time. Control characters are left out: Enter, Backspace, Tab, Esc and
    /// Ctrl-letter already went as keys.
    func handleExclusiveKey(_ event: NSEvent, pressed: Bool) -> Bool {
        guard let session = keyboardSession else { return false }
        guard let window = event.window, window === WindowSizeManager.mainWindow else { return false }
        if PCKeys.isFullScreenToggle(event) {
            return false
        }
        let keyCode = event.keyCode
        // Caps Lock: a tap (press + release) on every toggle, as a PC keyboard sends it; never left in `held`
        if keyCode == PCKeys.capsLock && event.type == .flagsChanged {
            guard !session.hidden, window.isKeyWindow, !AppState.shared.settingsOverTerminal,
                  let key = PCKeys.key(keyCode) else { return false }
            session.host.sendKey(scanCode: key.scan, extended: key.extended, virtualKey: key.vk, pressed: true)
            session.host.sendKey(scanCode: key.scan, extended: key.extended, virtualKey: key.vk, pressed: false)
            return true
        }
        if pressed {
            // 🚨 Only swallow a key we actually took. Settings is drawn over the terminal in the SAME window here,
            // so returning true regardless left Preferences (and any text field) with a dead keyboard while a
            // module was up. Windows does the same thing by leaving `handled` false -- EngineHostLayer.cs.
            guard !session.hidden, window.isKeyWindow, !AppState.shared.settingsOverTerminal else {
                return false
            }
            // Cmd+V, Ctrl+V and Shift+Insert paste into a module that's taking text (TE_IN_PASTE); the key itself
            // isn't sent, and its release goes by untouched since it never went in `held`.
            if session.textInputOn && event.type == .keyDown && Self.isPasteKey(event) {
                Self.pasteFromClipboard(session)
                return true
            }
            if let key = PCKeys.key(keyCode) {
                held.insert(keyCode)
                session.host.sendKey(scanCode: key.scan, extended: key.extended, virtualKey: key.vk, pressed: true)
            }
            // 🚨 .characters throws NSInternalInconsistencyException on anything that isn't a key event, and the
            // monitor also feeds us flagsChanged (a modifier going down arrives here as pressed) -- so asking a
            // Shift press for its characters killed the app outright. Uncatchable from Swift.
            // Arrows, F-keys, Home/End, PgUp/PgDn and the rest come through as AppKit's function-key characters
            // (U+F700-U+F8FF, Right = U+F703). They already went as keys; typed, the module got junk text and
            // Rainwire's menu redrew instead of moving (Windows makes no WM_CHAR for them).
            if session.textInputOn, event.type == .keyDown, let typed = event.characters {
                for unit in typed.utf16 where unit >= 0x20 && unit != 0x7F && !(0xF700...0xF8FF).contains(unit) {
                    session.host.sendText(unit)
                }
            }
            return true
        }
        // A release only belongs to the module when it was told about the press; anything else carries on as normal
        guard held.remove(keyCode) != nil else {
            return false
        }
        if let key = PCKeys.key(keyCode) {
            session.host.sendKey(scanCode: key.scan, extended: key.extended, virtualKey: key.vk, pressed: false)
        }
        return true
    }
}
