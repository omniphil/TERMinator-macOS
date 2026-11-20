import Foundation
import Combine

/// Transfer state enumeration.
enum TransferState: Equatable {
    case idle
    case receiving
    case sending
    case complete
    case error(String)
    case cancelled
}

/// Transfer direction.
enum TransferDirection {
    case none
    case send
    case receive
}

/// One line of the protocol status feed.
///
/// `level` is the severity the native side stamped on it and drives the colour:
/// "I" protocol info, "W" warning, "E" error, "S" one of our own notes,
/// "G" a native diagnostic line (shown as-is, green).
struct TransferLogLine: Identifiable, Equatable {
    let id = UUID()
    let level: String
    let text: String
}

/// Rewrites the protocol engine's own wording for a human reader.
///
/// The engine speaks in C function names and frame mnemonics
/// ("zmodem_recv_header frame: ZRINIT"), which is right for a trace and wrong
/// for a window someone is watching. The trace file still gets the raw text;
/// only what reaches the screen is rewritten. Order matters: specific patterns
/// must precede the catch-alls.
///
/// A line-for-line port of Windows `TransferViewModel.FriendlyText` /
/// `DroppedText` / `Prettify` (52 rewrites, 4 drops) -- keep them in step.
enum TransferMessage {
    private static let friendlyText: [(pattern: String, replacement: String)] = [
        (#"^ZMODEM session started for (\w+).*$"#,                "Connected over $1"),
        (#"^Starting ZMODEM send: .*[\\/]([^\\/]+)$"#,            "Preparing to send $1"),
        (#"^Starting ZMODEM send: (.+)$"#,                        "Preparing to send $1"),
        (#"^Sending ZRQINIT.*$"#,                                 "Requesting transfer"),
        (#"^zmodem_get_zrinit$"#,                                 "Waiting for the receiver"),
        // The native log joins the engine's two-line message with spaces; keep the flags
        (#"^Receiver requested mode \(0x[0-9A-Fa-f]+\):\s*(.+)$"#,  "Receiver options: $1"),
        (#"^Receiver requested mode.*$"#,                         "Receiver options:"),
        (#"^Receiver specified buffer size of: (\d+)$"#,          "Receiver buffer: $1 bytes"),
        (#"^Sending ZFILE frame.*$"#,                             "Sending file details"),
        (#"^Purging data in receive buffer.*$"#,                  "Clearing the receive buffer"),
        (#"^Received valid ZACK$"#,                               "Acknowledged"),
        (#"^Back-channel traffic detected$"#,                     "Receiver sent data back"),
        (#"^Unexpected back-channel data received: (.+)$"#,       "Receiver sent $1"),
        (#"^Sending End-of-File \(ZEOF\) frame$"#,                "End of file sent"),
        (#"^Sending ZNAK.*$"#,                                    "Requesting a resend"),
        (#"^Sending ZSKIP.*$"#,                                   "Skipping this file"),
        (#"^zmodem_get_zfin$"#,                                   "Closing the session"),
        (#"^Finishing Session \(Sending ZFIN\)$"#,                "Closing the session"),
        (#"^zmodem_recv_header frame: ZRINIT$"#,                  "Receiver ready"),
        (#"^zmodem_recv_header frame: ZRPOS$"#,                   "Receiver set the start position"),
        (#"^zmodem_recv_header frame: ZACK$"#,                    "Acknowledged"),
        (#"^zmodem_recv_header frame: ZFIN$"#,                    "Receiver closed the session"),
        (#"^zmodem_recv_header frame: ZCAN$"#,                    "Receiver cancelled the transfer"),
        (#"^zmodem_recv_header frame: (\w+)$"#,                   "Received $1"),
        (#"^Whole file delivered \(\d+ bytes\); waiting up to (\d+) seconds.*$"#,
                                                                  "File delivered - waiting up to $1s for the receiver to confirm"),
        (#"^No acknowledgement of ZEOF after (\d+) seconds.*$"#,
                                                                  "No confirmation after $1s - treating the file as delivered"),
        (#"^Treating transfer as complete.*$"#,                   "The whole file was delivered"),
        (#"^Treating '(.+)' as complete.*$"#,                     "$1 was delivered in full"),
        (#"^zmodem_recv_raw TIMEOUT \((\d+) seconds\)$"#,         "Timed out after $1s waiting for the receiver"),
        (#"^zmodem_recv_header TIMEOUT$"#,                        "Timed out waiting for a reply"),
        (#"^ERROR #(\d+): TIMEOUT$"#,                             "Error $1: timed out"),
        (#"^Transfer failed on receipt of: ZCAN$"#,               "The receiver cancelled the transfer"),
        (#"^Aborting receive$"#,                                  "Aborting"),
        (#"^ZMODEM send cancelled$"#,                             "Transfer cancelled"),
        (#"^ZMODEM send failed$"#,                                "Transfer failed"),
        (#"^ZMODEM receive cancelled$"#,                          "Transfer cancelled"),
        (#"^Forcing Telnet binary mode.*$"#,                      "Switched the link to binary mode"),
        (#"^Starting ZMODEM receive to: (.+)$"#,                  "Receiving into $1"),
        (#"^Batch send file (\d+)/(\d+): (.+)$"#,                 "File $1 of $2: $3"),
        (#"^Incoming: (.+?) \(.*$"#,                              "Incoming file: $1"),
        (#"^No ZFIN from the receiver.*$"#,                       "Receiver did not sign off, but the file was delivered"),
        (#"^IDLE WATCHDOG: no transfer progress for (\d+) seconds.*$"#,
                                                                  "No progress for $1s - giving up"),
        (#"^Too many errors \((\d+)\).*$"#,                       "Too many errors ($1) - giving up"),
        (#"^Falling back to 8-bit Checksum mode.*$"#,             "Falling back to 8-bit checksum"),
        (#"^Fetching YMODEM header block$"#,                      "Reading the YMODEM header"),
        (#"^Sending YMODEM termination block$"#,                  "Ending the batch"),
        (#"^Received YMODEM termination block$"#,                 "Sender ended the batch"),
        (#"^No YMODEM header block after transfer.*$"#,           "No further files"),
        (#"^Sender is XMODEM, not YMODEM.*$"#,                    "Sender is XMODEM, falling back"),
        (#"^No ACK after the YMODEM terminating block$"#,         "Receiver did not acknowledge the end of the batch"),
        (#"^Cancelled locally$"#,                                 "Cancelled"),
        (#"^Failed to open file: (.+?) - .*$"#,                   "Could not open $1"),
        (#"^Sending ([^\s].*\.[A-Za-z0-9]{1,8})$"#,               "Transferring $1"),
    ]

    /// Internal bookkeeping that means nothing to someone watching a transfer.
    /// Still written to the trace file; just never shown.
    private static let droppedText: [String] = [
        #"^Calling zmodem_recv_files"#,
        #"^Download directory (set to|not set|was not set)"#,
        #"^.+ is an existing directory$"#,
        #"^zmodem_recv_files returned"#,
    ]

    private static let completeWithBytes = #"^ZMODEM (send|receive) complete: (\d+) bytes$"#

    /// Turn a raw protocol message into something worth a line on screen, or
    /// "" to drop it.
    ///
    /// The leading byte position goes: the progress readout above already shows
    /// it, and repeating it here just pushes the useful lines off the top. The
    /// data-phase messages collapse to one "Transferring..." which, being
    /// identical each time, is then deduplicated to a single line.
    static func friendly(_ raw: String) -> String {
        var text = raw
        if let r = text.range(of: #"^\d+\s+"#, options: .regularExpression) {
            text.removeSubrange(r)
        }

        if text.contains("data subpacket")
            || text.hasPrefix("Progress:")
            || text.hasPrefix("zmodem_send_from")
            || text.hasPrefix("Sending ZDATA") {
            return "Transferring..."
        }

        // Byte counts read better as KB/MB than as a bare 8-digit number.
        if let regex = try? NSRegularExpression(pattern: completeWithBytes),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let verbRange = Range(match.range(at: 1), in: text),
           let bytesRange = Range(match.range(at: 2), in: text),
           let completed = Int64(text[bytesRange]) {
            let verb = text[verbRange] == "send" ? "sent" : "received"
            return "Transfer complete - \(TransferInfo.formatBytes(completed)) \(verb)"
        }

        for pattern in droppedText
        where text.range(of: pattern, options: .regularExpression) != nil {
            return ""
        }

        for rule in friendlyText
        where text.range(of: rule.pattern, options: .regularExpression) != nil {
            return text.replacingOccurrences(of: rule.pattern, with: rule.replacement,
                                             options: .regularExpression)
        }
        return text
    }
}

/// Transfer progress information.
struct TransferInfo {
    var state: TransferState = .idle
    var direction: TransferDirection = .none
    var fileName: String?
    var bytesTransferred: Int64 = 0
    var totalBytes: Int64 = 0
    var bytesPerSecond: Int64 = 0
    /// 1-based index of the file being transferred within a batch (0 = n/a).
    var fileIndex: Int = 0
    /// Total number of files in the batch (0/1 = single file).
    var fileTotal: Int = 0
    /// Protocol label for the transfer window title — "ZMODEM", "XMODEM",
    /// "YMODEM". Declared after the original fields so the memberwise
    /// initialiser keeps working at every existing call site; TransferManager.publish()
    /// stamps it, because a TransferInfo built fresh in a dozen places would
    /// otherwise silently reset the title back to ZMODEM halfway through an
    /// XMODEM transfer.
    var protocolName: String = "ZMODEM"
    /// Speed readout beside the bytes ("12.3 KB/s   ETA 0:42", "12.3 KB/s avg"
    /// once finished), or "" while not yet meaningful. Windows `SpeedText`.
    var speedText: String = ""
    /// The board declined every byte (ZSKIP: it usually has a file by that name already) and the engine still ended
    /// the session "complete": the window says "Skipped by the board" instead of "Transfer complete". Windows
    /// `TransferViewModel._skipped` + `_completedBytes == 0`.
    var skippedByBoard: Bool = false

    /// "(2/5)" style counter, or nil for single-file transfers.
    var fileCountText: String? {
        guard fileTotal > 1 else { return nil }
        return "(\(fileIndex)/\(fileTotal))"
    }

    /// Bar fill, 0...1.
    var progressFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(bytesTransferred) / Double(totalBytes)))
    }

    /// "42%" over the bar, or "" when the size is unknown (Windows `PercentText`, F0).
    var percentText: String {
        guard totalBytes > 0 else { return "" }
        return String(format: "%.0f%%", Double(bytesTransferred) / Double(totalBytes) * 100.0)
    }

    /// "26.4 MB of 60.0 MB", or just the count when the size is unknown
    /// (plain XMODEM carries no length). Windows `BytesText`.
    var bytesText: String {
        totalBytes > 0
            ? "\(Self.formatBytes(bytesTransferred)) of \(Self.formatBytes(totalBytes))"
            : Self.formatBytes(bytesTransferred)
    }

    /// Windows `TransferViewModel.FormatBytes`.
    static func formatBytes(_ bytes: Int64) -> String {
        switch bytes {
        case ..<1024:
            return "\(bytes) B"
        case ..<1_048_576:
            return String(format: "%.1f KB", Double(bytes) / 1024.0)
        case ..<1_073_741_824:
            return String(format: "%.1f MB", Double(bytes) / 1_048_576.0)
        default:
            return String(format: "%.2f GB", Double(bytes) / 1_073_741_824.0)
        }
    }
}

/// Transfer result.
enum TransferResult {
    case success(fileName: String, bytesTransferred: Int64)
    case error(String)
    case cancelled
}

/// Manages ZMODEM file transfers.
/// Provides progress updates and handles transfer lifecycle.
class TransferManager: ObservableObject {

    static let shared = TransferManager()

    @Published private(set) var transferInfo = TransferInfo()

    /// Running protocol status feed shown under the progress bar.
    @Published private(set) var logLines: [TransferLogLine] = []

    /// Windows `TransferViewModel.MaxLogLines`.
    private static let maxLogLines = 500

    /// Highest byte count shown for the current file.
    ///
    /// The protocol can legitimately report a position that moves BACKWARDS --
    /// an error rewinds the sender to the last acknowledged offset -- and a
    /// byte readout that counts down looks like the transfer is undoing itself.
    /// The bar and the readout only ever move forward; the status log is where
    /// a rewind is reported, in words. Main thread only, as is everything down
    /// to `finalized`.
    private var displayHighWater: Int64 = 0
    @Published private(set) var isTransferring = false

    private var initialized = false
    private let initLock = NSLock()
    private var transferQueue = DispatchQueue(label: "com.terminator.transfer", qos: .userInitiated)
    private var progressTimer: Timer?

    // Milestone annotations (Windows AnnotateProgress). The protocol itself says
    // almost nothing between "sending" and "end of file" -- on a slow link that
    // is several minutes of a frozen-looking window -- so the manager narrates
    // the gap from data it already has. These are OUR lines, not the board's,
    // marked level "S" (or "W") so they are coloured differently.
    private var transferStartUptime: TimeInterval = 0
    private var lastRawPosition: Int64 = 0
    private var lastMovementUptime: TimeInterval = 0
    private var stallAnnounced = false
    private var confirmWaitStartUptime: TimeInterval = 0
    private var lastConfirmNoticeUptime: TimeInterval = 0
    private var announcedFileSize = false
    /// A file the board declined (ZSKIP: it usually has one by that name already). The engine still ends the
    /// session "complete", so without this the window said "the file was delivered" for 0 bytes sent.
    private var skipped = false
    private var completedBytes: Int64 = -1
    /// Total of the current file at the last poll; completion shows "total of total".
    private var lastPolledTotal: Int64 = 0
    /// Set once the terminal state has been published, whichever path got there first.
    private var finalized = false

    /// How often to re-report a stalled wait for the receiver (ms).
    private static let confirmNoticeIntervalMs: Double = 15000
    /// Silence on the wire before we call it a stall (ms).
    private static let stallNoticeMs: Double = 12000

    // Throughput tracking (per file, so a batch restarts the meter on each one).
    private var speedFileIndex: Int = -1
    private var speedStartUptime: TimeInterval = 0
    private var speedStartBytes: Int64 = 0
    private var speedLastUptime: TimeInterval = 0
    private var speedLastBytes: Int64 = 0
    private var speedCps: Double = 0

    private var _isCancelled = false
    private let stateLock = NSLock()  // Protects mutable state accessed from multiple threads
    /// Protocol label stamped onto everything this manager publishes. Written
    /// synchronously at the top of each start method, before any of that
    /// method's async work is dispatched, so the dispatch itself orders the
    /// write ahead of every read.
    private var activeProtocolName = "ZMODEM"

    /// Thread-safe access to isCancelled flag
    private var isCancelled: Bool {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _isCancelled
        }
        set {
            stateLock.lock()
            defer { stateLock.unlock() }
            _isCancelled = newValue
        }
    }

    private init() {}

    // MARK: - Publishing & Failure Reporting

    /// Publish a TransferInfo, stamping the active protocol label on it.
    /// EVERY assignment to `transferInfo` goes through here.
    private func publish(_ info: TransferInfo) {
        var stamped = info
        stamped.protocolName = activeProtocolName
        transferInfo = stamped
    }

    /// Native failure text: the native error string when there is one, ALWAYS
    /// with the numeric return code appended, and the code alone when there is
    /// not.
    ///
    /// ⚠️ `getTransferError()` returns an EMPTY STRING rather than nil when the
    /// native side never set a message, so the old `?? "…"` fallback could never
    /// fire and the dialog showed a bare "ERROR: " with nothing after it. Several
    /// native codes never set a message at all (-1 not initialised, -2 not
    /// connected, -3 busy, -6 bad mode word, -7 XMODEM with no destination path),
    /// so the code is the only thing that says what actually went wrong.
    private func nativeErrorText(code: Int, fallback: String) -> String {
        if let detail = NativeBridge.shared.getTransferError(), !detail.isEmpty {
            return "\(detail) (code \(code))"
        }
        return "\(fallback) (code \(code))"
    }

    /// Surface a failure that stopped a transfer before it ever started.
    ///
    /// Without this, a transfer that never gets off the ground leaves the
    /// progress window sitting on "Waiting for remote..." with nothing published
    /// — indistinguishable from a BBS that never answered. Anything that stops a
    /// transfer starting has to be visible.
    ///
    /// ⚠️ Only ever called AFTER the "already transferring" guard has passed, so
    /// it cannot clobber the display of a transfer that is genuinely running.
    private func reportStartFailure(_ message: String, direction: TransferDirection,
                                    fileName: String? = nil) {
        DispatchQueue.main.async {
            self.publish(TransferInfo(state: .error(message), direction: direction, fileName: fileName))
            self.isTransferring = false
        }
    }

    // MARK: - Initialization

    /// Initialize the transfer subsystem.
    func initialize() -> Bool {
        initLock.lock()
        defer { initLock.unlock() }

        if initialized { return true }

        let success = NativeBridge.shared.transferInit()
        if success {
            let downloadDir = TransferManager.resolveDownloadDirectory()

            // Create directory if needed
            try? FileManager.default.createDirectory(at: downloadDir, withIntermediateDirectories: true)

            NativeBridge.shared.setDownloadDir(downloadDir.path)
            initialized = true
        }
        return success
    }

    /// Resolve the active download directory — honors the "download_directory"
    /// user setting, falling back to ~/Downloads/TERMinator.
    static func resolveDownloadDirectory() -> URL {
        let configured = UserDefaults.standard.string(forKey: "download_directory") ?? ""
        if !configured.isEmpty {
            return URL(fileURLWithPath: configured)
        }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return downloads.appendingPathComponent("TERMinator")
    }

    // MARK: - Receive

    /// Start a ZMODEM receive operation.
    /// - Parameters:
    ///   - downloadDir: where the files go this time, instead of the download directory setting (a Rainwire file
    ///     drop receives into a temporary folder, RainwireFileDrops); the caller puts the setting back after.
    ///   - completion: Completion handler called on main thread
    func startReceive(downloadDir override: URL? = nil, completion: @escaping (TransferResult) -> Void) {
        guard !isTransferring else {
            completion(.error("Transfer already in progress"))
            return
        }

        activeProtocolName = "ZMODEM"

        guard initialize() else {
            reportStartFailure("Failed to initialize transfer subsystem", direction: .receive)
            completion(.error("Failed to initialize transfer subsystem"))
            return
        }

        // Re-apply the user-configured download directory in case it was
        // changed in Settings after transferInit was first called.
        let downloadDir = override ?? TransferManager.resolveDownloadDirectory()
        try? FileManager.default.createDirectory(at: downloadDir, withIntermediateDirectories: true)
        NativeBridge.shared.setDownloadDir(downloadDir.path)

        NativeBridge.shared.transferReset()
        isCancelled = false

        DispatchQueue.main.async {
            self.isTransferring = true
            self.publish(TransferInfo(state: .receiving, direction: .receive))
        }

        // Push buffered ZMODEM data back into connection
        let _ = NativeBridge.shared.pushZmodemBuffer()

        startProgressMonitor()

        transferQueue.async { [weak self] in
            guard let self = self else { return }

            let result = NativeBridge.shared.zmodemReceive()

            // result > 0 means success (count of files)
            let transferResult: TransferResult
            if result > 0 {
                let fileName = NativeBridge.shared.getTransferFileName() ?? "unknown"
                let progress = NativeBridge.shared.getTransferProgress()
                let bytesTransferred = progress?.bytesTransferred ?? 0

                DispatchQueue.main.async {
                    self.finishTransfer(TransferInfo(
                        state: .complete,
                        direction: .receive,
                        fileName: fileName,
                        bytesTransferred: bytesTransferred,
                        totalBytes: bytesTransferred
                    ))
                }
                transferResult = .success(fileName: fileName, bytesTransferred: bytesTransferred)
            } else if self.isCancelled {
                DispatchQueue.main.async {
                    self.finishTransfer(TransferInfo(state: .cancelled, direction: .receive))
                }
                transferResult = .cancelled
            } else {
                let error = self.nativeErrorText(code: result, fallback: "ZMODEM receive failed")
                DispatchQueue.main.async {
                    self.finishTransfer(TransferInfo(state: .error(error), direction: .receive))
                }
                transferResult = .error(error)
            }

            DispatchQueue.main.async {
                self.isTransferring = false
                completion(transferResult)
            }
        }
    }

    // MARK: - Send

    /// Start a ZMODEM send operation.
    /// - Parameters:
    ///   - fileURL: URL of the file to send
    ///   - completion: Completion handler called on main thread
    func startSend(fileURL: URL, completion: @escaping (TransferResult) -> Void) {
        guard !isTransferring else {
            completion(.error("Transfer already in progress"))
            return
        }

        // Uploads are the only direction the 8K toggle changes, so only they say so
        activeProtocolName = applyZmodem8k()

        guard initialize() else {
            reportStartFailure("Failed to initialize transfer subsystem", direction: .send)
            completion(.error("Failed to initialize transfer subsystem"))
            return
        }

        // Verify file exists and get info
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            reportStartFailure("File not found: \(fileURL.lastPathComponent)", direction: .send)
            completion(.error("File not found"))
            return
        }

        let fileName = fileURL.lastPathComponent
        let fileSize: Int64
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            fileSize = (attributes[.size] as? Int64) ?? 0
        } catch {
            reportStartFailure("Failed to get file size: \(error.localizedDescription)",
                               direction: .send, fileName: fileName)
            completion(.error("Failed to get file size"))
            return
        }

        NativeBridge.shared.transferReset()
        isCancelled = false

        DispatchQueue.main.async {
            self.isTransferring = true
            self.publish(TransferInfo(
                state: .sending,
                direction: .send,
                fileName: fileName,
                totalBytes: fileSize
            ))
        }

        startProgressMonitor()

        transferQueue.async { [weak self] in
            guard let self = self else { return }

            let result = NativeBridge.shared.zmodemSend(filePath: fileURL.path)

            let transferResult: TransferResult
            if result == 0 {
                let progress = NativeBridge.shared.getTransferProgress()
                let bytesTransferred = progress?.bytesTransferred ?? fileSize

                DispatchQueue.main.async {
                    self.finishTransfer(TransferInfo(
                        state: .complete,
                        direction: .send,
                        fileName: fileName,
                        bytesTransferred: bytesTransferred,
                        totalBytes: fileSize
                    ))
                }
                transferResult = .success(fileName: fileName, bytesTransferred: bytesTransferred)
            } else if self.isCancelled {
                DispatchQueue.main.async {
                    self.finishTransfer(TransferInfo(state: .cancelled, direction: .send, fileName: fileName))
                }
                transferResult = .cancelled
            } else {
                let error = self.nativeErrorText(code: result, fallback: "ZMODEM send failed")
                DispatchQueue.main.async {
                    self.finishTransfer(TransferInfo(state: .error(error), direction: .send, fileName: fileName))
                }
                transferResult = .error(error)
            }

            DispatchQueue.main.async {
                self.isTransferring = false
                completion(transferResult)
            }
        }
    }

    /// Start a ZMODEM batch send operation (multiple files in one session).
    /// Falls back to the single-file path when exactly one file is supplied.
    /// - Parameters:
    ///   - fileURLs: URLs of the files to send
    ///   - completion: Completion handler called on main thread
    func startSendBatch(fileURLs: [URL], completion: @escaping (TransferResult) -> Void) {
        guard !isTransferring else {
            completion(.error("Transfer already in progress"))
            return
        }

        activeProtocolName = applyZmodem8k()

        guard initialize() else {
            reportStartFailure("Failed to initialize transfer subsystem", direction: .send)
            completion(.error("Failed to initialize transfer subsystem"))
            return
        }

        // Keep only files that actually exist
        let urls = fileURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else {
            reportStartFailure("File not found", direction: .send)
            completion(.error("File not found"))
            return
        }

        // Single file: reuse the proven single-file path
        if urls.count == 1 {
            startSend(fileURL: urls[0], completion: completion)
            return
        }

        let totalBytes: Int64 = urls.reduce(0) { acc, url in
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64
            return acc + (size ?? 0)
        }
        let firstName = urls[0].lastPathComponent
        let fileCount = urls.count

        NativeBridge.shared.transferReset()
        isCancelled = false

        DispatchQueue.main.async {
            self.isTransferring = true
            self.publish(TransferInfo(
                state: .sending,
                direction: .send,
                fileName: firstName,
                totalBytes: totalBytes,
                fileIndex: 1,
                fileTotal: fileCount
            ))
        }

        startProgressMonitor()

        transferQueue.async { [weak self] in
            guard let self = self else { return }

            NativeBridge.shared.uploadQueueClear()
            for url in urls {
                NativeBridge.shared.uploadQueueAdd(filePath: url.path)
            }

            let result = NativeBridge.shared.zmodemSendBatch()

            let transferResult: TransferResult
            // Batch send returns the number of files sent (>0) on success.
            if result > 0 {
                let fileName = NativeBridge.shared.getTransferFileName() ?? firstName
                DispatchQueue.main.async {
                    self.finishTransfer(TransferInfo(
                        state: .complete,
                        direction: .send,
                        fileName: fileName,
                        bytesTransferred: totalBytes,
                        totalBytes: totalBytes,
                        fileIndex: fileCount,
                        fileTotal: fileCount
                    ))
                }
                transferResult = .success(fileName: "\(result) file(s)", bytesTransferred: totalBytes)
            } else if self.isCancelled {
                DispatchQueue.main.async {
                    self.finishTransfer(TransferInfo(state: .cancelled, direction: .send, fileName: firstName))
                }
                transferResult = .cancelled
            } else {
                let error = self.nativeErrorText(code: result, fallback: "ZMODEM batch send failed")
                DispatchQueue.main.async {
                    self.finishTransfer(TransferInfo(state: .error(error), direction: .send, fileName: firstName))
                }
                transferResult = .error(error)
            }

            DispatchQueue.main.async {
                self.isTransferring = false
                completion(transferResult)
            }
        }
    }

    // MARK: - X / YMODEM

    /// Start an X/YMODEM receive.
    ///
    /// Nothing auto-detects here the way ZMODEM does — the BBS is already NAKing
    /// and the user has told us which protocol they picked on the board.
    ///
    /// - Parameters:
    ///   - savePath: full destination path; REQUIRED for XMODEM (the protocol has
    ///     no filename in it) and ignored by YMODEM, which takes the name from
    ///     its header block and lands in the download directory.
    ///   - mode: `NativeBridge.XferMode` bit set.
    ///   - completion: called on the main thread.
    func startXmodemReceive(savePath: String?, mode: Int, completion: @escaping (TransferResult) -> Void) {
        guard !isTransferring else {
            completion(.error("Transfer already in progress"))
            return
        }

        // Title the transfer window for the protocol actually in use, derived
        // from the mode word rather than passed in separately.
        activeProtocolName = (mode & NativeBridge.XferMode.ymodem) != 0 ? "YMODEM" : "XMODEM"

        guard initialize() else {
            reportStartFailure("Failed to initialize transfer subsystem", direction: .receive)
            completion(.error("Failed to initialize transfer subsystem"))
            return
        }

        // Re-apply the user-configured download directory in case it changed in
        // Settings since transferInit(). YMODEM writes into it; XMODEM was handed
        // a full destination path and does not use it.
        let downloadDir = TransferManager.resolveDownloadDirectory()
        try? FileManager.default.createDirectory(at: downloadDir, withIntermediateDirectories: true)
        NativeBridge.shared.setDownloadDir(downloadDir.path)

        NativeBridge.shared.transferReset()
        isCancelled = false

        let fileName = savePath.map { ($0 as NSString).lastPathComponent }

        DispatchQueue.main.async {
            self.isTransferring = true
            self.publish(TransferInfo(state: .receiving, direction: .receive, fileName: fileName))
        }

        // NOTE: no pushZmodemBuffer() here. That drains the connection buffer into
        // ZMODEM's own; X/YMODEM has no such buffer, and the receiver is the one
        // that speaks first anyway — we send the NAK/'C', the BBS answers.

        startProgressMonitor()

        transferQueue.async { [weak self] in
            guard let self = self else { return }

            let result = NativeBridge.shared.xmodemReceive(savePath: savePath, mode: mode)

            let transferResult: TransferResult
            // Receive returns the number of files received (>0) on success.
            if result > 0 {
                let name = NativeBridge.shared.getTransferFileName() ?? fileName ?? "unknown"
                let progress = NativeBridge.shared.getTransferProgress()
                let bytesTransferred = progress?.bytesTransferred ?? 0

                DispatchQueue.main.async {
                    self.finishTransfer(TransferInfo(
                        state: .complete,
                        direction: .receive,
                        fileName: name,
                        bytesTransferred: bytesTransferred,
                        totalBytes: bytesTransferred
                    ))
                }
                transferResult = .success(fileName: name, bytesTransferred: bytesTransferred)
            } else if self.isCancelled {
                DispatchQueue.main.async {
                    self.finishTransfer(TransferInfo(state: .cancelled, direction: .receive, fileName: fileName))
                }
                transferResult = .cancelled
            } else {
                let error = self.nativeErrorText(code: result, fallback: "X/YMODEM receive failed")
                DispatchQueue.main.async {
                    self.finishTransfer(TransferInfo(state: .error(error), direction: .receive, fileName: fileName))
                }
                transferResult = .error(error)
            }

            DispatchQueue.main.async {
                self.isTransferring = false
                completion(transferResult)
            }
        }
    }

    /// Start an X/YMODEM send. Single file only — the boards that need X/YMODEM
    /// at all do not offer batch uploads.
    func startXmodemSend(fileURL: URL, mode: Int, completion: @escaping (TransferResult) -> Void) {
        guard !isTransferring else {
            completion(.error("Transfer already in progress"))
            return
        }

        activeProtocolName = (mode & NativeBridge.XferMode.ymodem) != 0 ? "YMODEM" : "XMODEM"

        guard initialize() else {
            reportStartFailure("Failed to initialize transfer subsystem", direction: .send)
            completion(.error("Failed to initialize transfer subsystem"))
            return
        }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            reportStartFailure("File not found: \(fileURL.lastPathComponent)", direction: .send)
            completion(.error("File not found"))
            return
        }

        let fileName = fileURL.lastPathComponent
        let fileSize = ((try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.size] as? Int64) ?? 0

        NativeBridge.shared.transferReset()
        isCancelled = false

        DispatchQueue.main.async {
            self.isTransferring = true
            self.publish(TransferInfo(
                state: .sending,
                direction: .send,
                fileName: fileName,
                totalBytes: fileSize
            ))
        }

        startProgressMonitor()

        transferQueue.async { [weak self] in
            guard let self = self else { return }

            let result = NativeBridge.shared.xmodemSend(filePath: fileURL.path, mode: mode)

            let transferResult: TransferResult
            if result == 0 {
                let progress = NativeBridge.shared.getTransferProgress()
                let bytesTransferred = progress?.bytesTransferred ?? fileSize

                DispatchQueue.main.async {
                    self.finishTransfer(TransferInfo(
                        state: .complete,
                        direction: .send,
                        fileName: fileName,
                        bytesTransferred: bytesTransferred,
                        totalBytes: fileSize
                    ))
                }
                transferResult = .success(fileName: fileName, bytesTransferred: bytesTransferred)
            } else if self.isCancelled {
                DispatchQueue.main.async {
                    self.finishTransfer(TransferInfo(state: .cancelled, direction: .send, fileName: fileName))
                }
                transferResult = .cancelled
            } else {
                let error = self.nativeErrorText(code: result, fallback: "X/YMODEM send failed")
                DispatchQueue.main.async {
                    self.finishTransfer(TransferInfo(state: .error(error), direction: .send, fileName: fileName))
                }
                transferResult = .error(error)
            }

            DispatchQueue.main.async {
                self.isTransferring = false
                completion(transferResult)
            }
        }
    }

    // MARK: - Cancel

    /// Cancel the current transfer.
    func cancelTransfer() {
        isCancelled = true
        NativeBridge.shared.transferCancel()
    }

    // MARK: - Progress Monitoring

    /// Monotonic seconds (never 0 in practice, so 0 can mean "unset").
    private static func uptime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func startProgressMonitor() {
        // Start each transfer with a clean feed on both sides of the boundary.
        NativeBridge.shared.clearTransferLog()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.logLines = []
            self.displayHighWater = 0
            self.finalized = false
            self.transferStartUptime = Self.uptime()
            self.lastRawPosition = 0
            self.lastMovementUptime = 0
            self.stallAnnounced = false
            self.confirmWaitStartUptime = 0
            self.lastConfirmNoticeUptime = 0
            self.announcedFileSize = false
            self.skipped = false
            self.completedBytes = -1
            self.lastPolledTotal = 0
            self.speedFileIndex = -1
            self.speedStartUptime = 0
            self.speedCps = 0
            self.progressTimer?.invalidate()
            // 200 ms, as the Windows poll loop.
            self.progressTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                self?.updateProgress()
            }
        }
    }

    /// The timer lives on the main run loop, so it is invalidated there.
    private func stopProgressMonitor() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.stopProgressMonitor() }
            return
        }
        progressTimer?.invalidate()
        progressTimer = nil
    }

    /// Append one line, dropping it if it merely repeats the line above.
    /// Main thread only.
    private func appendLogLine(_ level: String, _ text: String) {
        if let last = logLines.last, last.level == level, last.text == text {
            return
        }
        var lines = logLines
        lines.append(TransferLogLine(level: level, text: text))
        if lines.count > Self.maxLogLines {
            lines.removeFirst(lines.count - Self.maxLogLines)
        }
        logLines = lines
    }

    /// Transfer > ZMODEM 8K Blocks: pushes the setting to the native bridge before an
    /// upload and returns the window title's protocol name ("ZMODEM 8K" / "ZMODEM").
    private func applyZmodem8k() -> String {
        let on = UserDefaults.standard.bool(forKey: AppPreferences.zmodem8k)
        NativeBridge.shared.setZmodem8k(on)
        return on ? "ZMODEM 8K" : "ZMODEM"
    }

    /// Pull new native status lines into `logLines`, rewritten for a reader and
    /// with consecutive duplicates collapsed (one "Transferring..." rather than
    /// several hundred).
    private func drainLog() {
        let incoming = NativeBridge.shared.drainTransferLog()
        guard !incoming.isEmpty else { return }

        var appended = logLines
        for entry in incoming {
            if entry.text.contains("File skipped by receiver") {
                skipped = true
            }
            if let completed = Self.completedByteCount(entry.text) {
                completedBytes = completed
            }
            // "G" = the native diagnostics, already written for people: shown as-is
            var text = entry.level == "G" ? entry.text : TransferMessage.friendly(entry.text)
            if skipped && text == "Receiver did not sign off, but the file was delivered" {
                text = "Receiver did not sign off"
            }
            if skipped && completedBytes == 0 && text.hasPrefix("Transfer complete") {
                text = "Nothing sent: the board skipped the file (it may already have one by that name)"
            }
            guard !text.isEmpty else { continue }   // dropped as internal bookkeeping
            if let last = appended.last, last.level == entry.level, last.text == text {
                continue
            }
            appended.append(TransferLogLine(level: entry.level, text: text))
        }

        if appended.count > Self.maxLogLines {
            appended.removeFirst(appended.count - Self.maxLogLines)
        }
        logLines = appended
    }

    /// The byte count of a "ZMODEM send/receive complete: N bytes" line (leading byte position ignored), else nil.
    private static func completedByteCount(_ raw: String) -> Int64? {
        var text = raw
        if let r = text.range(of: #"^\d+\s+"#, options: .regularExpression) {
            text.removeSubrange(r)
        }
        guard let r = text.range(of: #"^ZMODEM (send|receive) complete: \d+ bytes$"#, options: .regularExpression),
              let digits = text[r].split(separator: " ").dropLast().last else {
            return nil
        }
        return Int64(digits)
    }

    /// Feeds a progress sample into the throughput meter and returns the
    /// display string ("12.3 KB/s   ETA 0:42"), or "" when not yet meaningful.
    /// Windows `TransferViewModel.UpdateSpeed`.
    private func updateSpeed(fileIndex: Int, current: Int64, total: Int64) -> String {
        let now = Self.uptime()

        // Restart the meter for each file of a batch
        if fileIndex != speedFileIndex {
            speedFileIndex = fileIndex
            speedStartUptime = 0
            speedCps = 0
            displayHighWater = 0   // a new file starts its readout from zero
        }

        if current <= 0 {
            return ""
        }

        if speedStartUptime == 0 {
            speedStartUptime = now
            speedLastUptime = now
            speedStartBytes = current
            speedLastBytes = current
            return ""
        }

        let deltaMs = (now - speedLastUptime) * 1000
        if deltaMs >= 500 {
            var sampleCps = Double(current - speedLastBytes) * 1000.0 / deltaMs
            if sampleCps < 0 { sampleCps = 0 }
            // Light smoothing so the readout doesn't jitter every tick
            speedCps = speedCps <= 0 ? sampleCps : (speedCps * 0.6) + (sampleCps * 0.4)
            speedLastUptime = now
            speedLastBytes = current
        } else if speedCps <= 0 {
            let elapsedMs = (now - speedStartUptime) * 1000
            if elapsedMs <= 0 { return "" }
            speedCps = Double(current - speedStartBytes) * 1000.0 / elapsedMs
        }

        if speedCps <= 0 {
            return ""
        }

        var speed = "\(TransferInfo.formatBytes(Int64(speedCps)))/s"

        if total > current {
            let etaSeconds = Double(total - current) / speedCps
            if etaSeconds < 100 * 3600 {
                let secs = Int(etaSeconds)
                speed += secs >= 3600
                    ? String(format: "   ETA %d:%02d:%02d", secs / 3600, (secs % 3600) / 60, secs % 60)
                    : String(format: "   ETA %d:%02d", (secs % 3600) / 60, secs % 60)
            }
        }

        return speed
    }

    /// Average throughput over the whole (last) file. Windows `FormatAverageSpeed`.
    private func formatAverageSpeed(fallback: String) -> String {
        let elapsedMs = Int64((Self.uptime() - speedStartUptime) * 1000)
        if speedStartUptime == 0 || elapsedMs <= 0 {
            return fallback
        }
        let bytes = speedLastBytes - speedStartBytes
        if bytes <= 0 {
            return fallback
        }
        return "\(TransferInfo.formatBytes(bytes * 1000 / elapsedMs))/s avg"
    }

    /// Windows `TransferViewModel.FormatDuration`.
    private static func formatDuration(ms: Int64) -> String {
        let totalSeconds = ms / 1000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours >= 1 { return "\(hours)h \(minutes)m \(seconds)s" }
        if totalSeconds >= 60 { return "\(minutes)m \(seconds)s" }
        return "\(seconds)s"
    }

    /// Narrate the parts of a transfer the protocol is silent through: the size
    /// up front and -- the one that matters most -- a heartbeat while we sit
    /// waiting for a receiver that has taken delivery but not yet confirmed.
    /// That wait can legitimately run into minutes, and without a line here the
    /// window is indistinguishable from a hang. Windows `AnnotateProgress`.
    private func annotateProgress(raw: Int64, shown: Int64, total: Int64) {
        let now = Self.uptime()

        // A position that moves BACKWARDS means the receiver rejected something
        // and the sender has rewound to the last acknowledged offset. The bar
        // deliberately hides that, so this is the only place it is visible.
        if lastRawPosition > 0 && raw > 0 && raw < lastRawPosition - 1024 {
            appendLogLine("W", "Receiver rejected data - resending from \(TransferInfo.formatBytes(raw))")
        }

        // Stall detection. Not redundant with the bar: a bar that has stopped
        // moving looks identical to a slow link, and this says which it is.
        if raw != lastRawPosition {
            lastRawPosition = raw
            lastMovementUptime = now
            stallAnnounced = false
        } else if !stallAnnounced && lastMovementUptime > 0
                    && (now - lastMovementUptime) * 1000 >= Self.stallNoticeMs
                    && (total <= 0 || shown < total) {
            stallAnnounced = true
            appendLogLine("W", "No data moved for \(Int64((now - lastMovementUptime) * 1000) / 1000)s")
        }

        if total <= 0 {
            return
        }

        if !announcedFileSize {
            announcedFileSize = true
            appendLogLine("S", "File size: \(TransferInfo.formatBytes(total))")
        }

        if shown < total {
            confirmWaitStartUptime = 0
            return
        }

        // Every byte is out but the transfer has not finished: we are waiting
        // on the receiver's acknowledgement.
        if confirmWaitStartUptime == 0 {
            confirmWaitStartUptime = now
            lastConfirmNoticeUptime = now
            appendLogLine("S", "All bytes sent - waiting for the receiver to confirm")
            return
        }

        if (now - lastConfirmNoticeUptime) * 1000 >= Self.confirmNoticeIntervalMs {
            lastConfirmNoticeUptime = now
            appendLogLine("S", "Still waiting for the receiver... (\(Int64((now - confirmWaitStartUptime) * 1000) / 1000)s)")
        }
    }

    private func updateProgress() {
        guard !finalized else { return }

        // Native state first: it moves to a terminal state even while the
        // native call is still unwinding.
        let nativeState = NativeBridge.shared.getTransferState()

        drainLog()

        guard let progress = NativeBridge.shared.getTransferProgress() else { return }

        let fileName = NativeBridge.shared.getTransferFileName()
        let fileIdx = NativeBridge.shared.getTransferFileIndex()
        let current = progress.bytesTransferred
        let total = progress.totalBytes

        let speed = updateSpeed(fileIndex: fileIdx.current, current: current, total: total)

        // Never let the readout run backwards (see displayHighWater).
        if current > displayHighWater {
            displayHighWater = current
        }
        let shown = displayHighWater
        annotateProgress(raw: current, shown: shown, total: total)
        lastPolledTotal = total

        // ZMODEM downloads: the board picks the block size, so say 8K only once one arrives
        if transferInfo.direction == .receive && activeProtocolName == "ZMODEM" &&
            NativeBridge.shared.zmodemLargestRxBlock() >= 8192 {
            activeProtocolName = "ZMODEM 8K"
        }

        var info = transferInfo
        info.fileName = (fileName?.isEmpty == false) ? fileName : transferInfo.fileName
        info.bytesTransferred = shown
        info.totalBytes = total
        info.speedText = speed
        info.fileIndex = fileIdx.current
        info.fileTotal = max(fileIdx.total, transferInfo.fileTotal)
        publish(info)

        switch nativeState {
        case .complete:
            finishTransfer(TransferInfo(state: .complete, direction: info.direction,
                                        fileName: info.fileName,
                                        bytesTransferred: shown, totalBytes: total,
                                        fileIndex: info.fileIndex, fileTotal: info.fileTotal))
        case .error:
            // getTransferError() returns "" rather than nil when the native
            // side set no message.
            let detail = NativeBridge.shared.getTransferError()
            let error = (detail?.isEmpty == false) ? detail! : "Transfer error"
            finishTransfer(TransferInfo(state: .error(error), direction: info.direction,
                                        fileName: info.fileName,
                                        bytesTransferred: shown, totalBytes: total,
                                        fileIndex: info.fileIndex, fileTotal: info.fileTotal))
        case .cancelled:
            finishTransfer(TransferInfo(state: .cancelled, direction: info.direction,
                                        fileName: info.fileName,
                                        bytesTransferred: shown, totalBytes: total,
                                        fileIndex: info.fileIndex, fileTotal: info.fileTotal))
        default:
            break
        }
    }

    /// Publish the terminal state ONCE, from whichever path sees it first -- the
    /// poll (native state went terminal) or the transfer queue (native call
    /// returned). Main thread only.
    ///
    /// The native side sets the terminal state and THEN logs its closing lines,
    /// so one more drain after a short beat (60 ms, as on Windows) is what puts
    /// "send complete" / the failure reason on screen. A completed transfer
    /// then shows 100%, "total of total", the average speed, and a
    /// "Finished in ... - average ..." line.
    private func finishTransfer(_ final: TransferInfo) {
        guard !finalized else { return }
        finalized = true
        stopProgressMonitor()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            guard let self = self else { return }
            self.drainLog()

            var info = final
            if case .complete = info.state {
                let total = self.lastPolledTotal > 0 ? self.lastPolledTotal : info.totalBytes
                if total > 0 {
                    info.totalBytes = total
                    info.bytesTransferred = total
                }
                let average = self.formatAverageSpeed(fallback: self.transferInfo.speedText)
                info.speedText = average
                info.skippedByBoard = self.skipped && self.completedBytes == 0
                let elapsedMs = Int64((Self.uptime() - self.transferStartUptime) * 1000)
                self.appendLogLine("S", "Finished in \(Self.formatDuration(ms: elapsedMs)) - average \(average)")
            }
            self.publish(info)
        }
    }

    // MARK: - Reset & Cleanup

    /// Reset state after transfer completion.
    func reset() {
        NativeBridge.shared.transferReset()
        publish(TransferInfo())
        isTransferring = false
        isCancelled = false
    }

    /// Clean up resources.
    func cleanup() {
        cancelTransfer()
        stopProgressMonitor()

        if initialized {
            NativeBridge.shared.transferCleanup()
            initialized = false
        }
    }

    // MARK: - Upload Queue

    /// Paths queued for a (possibly multi-file) upload. Mirrors the native
    /// single-slot queue but retains the full list for batch sends.
    private(set) var queuedUploadPaths: [String] = []

    /// Queue a file for upload.
    func queueUpload(fileURL: URL) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        queuedUploadPaths = [fileURL.path]
        NativeBridge.shared.queueUpload(filePath: fileURL.path)
    }

    /// Queue multiple files for a batch upload. The native single-slot queue is
    /// also primed with the first path so isUploadQueued()/auto-start still fire.
    func queueUploadBatch(fileURLs: [URL]) {
        let existing = fileURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { return }
        queuedUploadPaths = existing.map { $0.path }
        NativeBridge.shared.queueUpload(filePath: existing[0].path)
    }

    /// Check if a file is queued for upload.
    var isUploadQueued: Bool {
        NativeBridge.shared.isUploadQueued()
    }

    /// Check if the BBS is ready for upload.
    var isUploadReady: Bool {
        NativeBridge.shared.isUploadReady()
    }

    /// Get the queued upload file path.
    var queuedUploadPath: String? {
        NativeBridge.shared.getQueuedUpload()
    }

    /// Clear the upload queue (both the native single-slot and the Swift list).
    func clearUploadQueue() {
        queuedUploadPaths = []
        NativeBridge.shared.clearUploadQueue()
    }

    // MARK: - File Helpers

    /// Get the downloads directory URL.
    var downloadsDirectory: URL {
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return documentsDir.appendingPathComponent("Downloads")
    }

    /// Get list of downloaded files.
    func getDownloadedFiles() -> [URL] {
        guard FileManager.default.fileExists(atPath: downloadsDirectory.path) else {
            return []
        }

        do {
            return try FileManager.default.contentsOfDirectory(at: downloadsDirectory,
                                                                includingPropertiesForKeys: [.contentModificationDateKey],
                                                                options: .skipsHiddenFiles)
                .sorted { url1, url2 in
                    let date1 = (try? url1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
                    let date2 = (try? url2.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
                    return date1 > date2
                }
        } catch {
            return []
        }
    }
}
