import Foundation
import Darwin

/// Narrates a connection attempt for the connecting overlay's log (spec §5): which stage it has
/// reached and how long it has sat there, so a board that doesn't answer shows where it stalled.
/// Mirrors the Windows client's `Services/ConnectionTracer.cs`.
///
/// It only observes and never opens its own connection to the board:
/// - **resolve**: its own DNS lookup of the host, for display (the native connect resolves
///   independently)
/// - **handshake**: TLS / SSH / WebSocket / telnet negotiation until the native connect returns
///
/// ⚠️ **macOS has no TCP stage.** Windows watches this process's row in the OS TCP table and Linux
/// reads `/proc/net/tcp`; macOS has no cheap per-process TCP table, and no hook is available either:
/// the live socket belongs to SyncTERM's own `conn.c` inside the native library (`native_connect` →
/// `conn_connect`), not to `TelnetConnection.swift`'s `NWConnection`, whose state handler would have
/// given us `.preparing` / `.ready`. `Bridge/syncterm_stubs.c` says as much — its Swift connection
/// bridge is not the live path. So, exactly as the port spec allows, the log goes straight from
/// `resolve` to the handshake stage: no `open tcp`, `SYN sent` or `established` lines.
///
/// Lines the native side writes to its debug log (SSH steps, error messages) are streamed in as they
/// appear. Create it, `start()` it and `complete(...)` it on the main thread.
final class ConnectionTracer {
    enum LineKind: Equatable {
        case command, info, success, error
    }

    private enum Stage: Equatable {
        case resolve, handshake, done
    }

    /// What the DNS lookup came back with: the numeric addresses, or the resolver's message.
    /// (A plain `Result` can't carry a `String` failure — its `Failure` must conform to `Error`.)
    private enum LookupOutcome {
        case addresses([String])
        case failure(String)
    }

    private let host: String
    private let port: Int
    private let connectionProtocol: ConnectionProtocol
    private let log: (String, LineKind) -> Void
    private let setStatus: (String) -> Void

    private var timer: Timer?
    private var stage: Stage = .resolve
    private var stageLabel = ""
    private var stageStarted = Date()
    private var nativeLinesSeen = 0

    init(entry: BBSEntry,
         log: @escaping (String, LineKind) -> Void,
         setStatus: @escaping (String) -> Void) {
        self.host = entry.host
        self.port = entry.port
        self.connectionProtocol = entry.connectionProtocol
        self.log = log
        self.setStatus = setStatus
    }

    deinit {
        timer?.invalidate()
    }

    /// Starts narrating. Call just before the native connect is started.
    func start() {
        // Only this attempt's native lines (the native connect clears the log again itself, which is
        // harmless).
        NativeBridge.shared.clearSshDebugLog()
        nativeLinesSeen = 0

        log("dial \(host):\(port) --proto \(connectionProtocol.tracerName)", .command)
        enterStage(.resolve, command: "resolve \(host)")

        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        resolve()
    }

    /// Stops narrating and writes the outcome. Safe to call more than once; only the first counts.
    func complete(success: Bool, timedOut: Bool, cancelled: Bool) {
        guard stage != .done else { return }

        timer?.invalidate()
        timer = nil
        pumpNativeLog()
        let stuckAt = stageLabel
        let seconds = Date().timeIntervalSince(stageStarted)
        stage = .done

        if success {
            log("CONNECT", .success)
            setStatus("[online]")
        } else if cancelled {
            log("aborted by user", .info)
            setStatus("[aborted during: \(stuckAt)]")
        } else {
            let why = timedOut
                ? "no response after \(Self.oneDecimal(seconds))s"
                : "failed after \(Self.oneDecimal(seconds))s"
            log("NO CARRIER: stuck at \(stuckAt) (\(why))", .error)
            setStatus("[stuck at: \(stuckAt)]")
        }
    }

    // MARK: - Stages

    private func enterStage(_ stage: Stage, command: String) {
        self.stage = stage
        stageLabel = command
        stageStarted = Date()
        log(command, .command)
        updateStatus()
    }

    private func tick() {
        pumpNativeLog()
        if stage != .done {
            updateStatus()
        }
    }

    private func updateStatus() {
        setStatus("[\(stageLabel)]  \(Self.oneDecimal(Date().timeIntervalSince(stageStarted)))s")
    }

    /// The app's own DNS lookup, display only. An IP literal skips it and is shown straight away.
    private func resolve() {
        let host = self.host
        if Self.isIPLiteral(host) {
            guard stage == .resolve else { return }
            log("  -> \(host) (0 ms)", .info)
            enterStage(.handshake, command: Self.handshakeCommand(connectionProtocol))
            return
        }

        let clock = Date()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Self.lookup(host: host)
            let milliseconds = Int((Date().timeIntervalSince(clock) * 1000).rounded())
            DispatchQueue.main.async {
                guard let self = self, self.stage == .resolve else { return }
                switch result {
                case .addresses(let addresses):
                    let shown = addresses.prefix(3).joined(separator: ", ")
                        + (addresses.count > 3 ? ", ..." : "")
                    self.log("  -> \(shown) (\(milliseconds) ms)", .info)
                    self.enterStage(.handshake, command: Self.handshakeCommand(self.connectionProtocol))
                case .failure(let message):
                    // Stay on the resolve stage: the native connect will fail on the same lookup.
                    self.log("  !! lookup failed: \(message)", .error)
                }
            }
        }
    }

    /// Streams whole new lines from the native debug log (SSH steps, error messages).
    private func pumpNativeLog() {
        let text = NativeBridge.shared.getSshDebugLog()
        var lines = text.components(separatedBy: "\n")
        // The last piece is either empty (the text ended with a newline) or a partial line: never
        // emit it, so a line always arrives whole.
        if !lines.isEmpty {
            lines.removeLast()
        }
        if lines.count < nativeLinesSeen {
            nativeLinesSeen = 0     // the native connect cleared the log
        }
        guard lines.count > nativeLinesSeen else { return }

        for raw in lines[nativeLinesSeen..<lines.count] {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // The bridge's attempt header repeats what the dial line already says.
            if line.isEmpty || line.hasPrefix("===") || line.hasPrefix("Host:") || line.hasPrefix("Username:") {
                continue
            }
            let isError = line.range(of: "ERROR", options: .caseInsensitive) != nil
                || line.hasPrefix("[uifcmsg")
                || line.hasPrefix("[error]")
            log("  " + line, isError ? .error : .info)
        }
        nativeLinesSeen = lines.count
    }

    // MARK: - Helpers

    private static func handshakeCommand(_ connectionProtocol: ConnectionProtocol) -> String {
        switch connectionProtocol {
        case .telnetS: return "tls handshake"
        case .ssh: return "ssh handshake + login"
        case .secureWebSocket: return "tls handshake + websocket upgrade"
        case .webSocket: return "websocket upgrade"
        case .raw: return "raw session"
        case .telnet: return "telnet session"
        }
    }

    static func oneDecimal(_ seconds: Double) -> String {
        String(format: "%.1f", max(0, seconds))
    }

    private static func isIPLiteral(_ host: String) -> Bool {
        var v4 = in_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 { return true }
        var v6 = in6_addr()
        return host.withCString { inet_pton(AF_INET6, $0, &v6) } == 1
    }

    /// A plain `getaddrinfo`: no connection is opened, and the board's port is irrelevant here.
    private static func lookup(host: String) -> LookupOutcome {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM

        var info: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &info)
        guard status == 0, let first = info else {
            // The console's resolver words an unknown host the same way.
            return .failure(status == EAI_NONAME ? "host not found" : String(cString: gai_strerror(status)))
        }
        defer { freeaddrinfo(info) }

        var addresses: [String] = []
        var node: UnsafeMutablePointer<addrinfo>? = first
        while let current = node {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if let address = current.pointee.ai_addr,
               getnameinfo(address, current.pointee.ai_addrlen,
                           &buffer, socklen_t(buffer.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                let text = String(cString: buffer)
                if !text.isEmpty && !addresses.contains(text) {
                    addresses.append(text)
                }
            }
            node = current.pointee.ai_next
        }
        return addresses.isEmpty ? .failure("host not found") : .addresses(addresses)
    }
}

extension ConnectionProtocol {
    /// The lowercase protocol word the connection log's `--proto` uses — and, uppercased, the
    /// target-lock caption's PROTO. The command line takes the same words.
    var tracerName: String {
        switch self {
        case .telnet: return "telnet"
        case .raw: return "raw"
        case .ssh: return "ssh"
        case .telnetS: return "telnets"
        case .webSocket: return "ws"
        case .secureWebSocket: return "wss"
        }
    }
}
