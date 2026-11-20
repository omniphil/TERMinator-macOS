import SwiftUI

/// The connecting overlay (spec §5): a live connection log instead of a bare "Connecting…".
/// Mirrors the Windows client's `Views/TerminalView.xaml` connecting overlay.
///
/// Dim backdrop + a centered card (max width 780, margin 24, `#0D0D1A` at 95%, amber 1 pt border,
/// radius 8, padding 18×14) holding the title, the log box (280 high, `#050508`, `#2A2A4A` border,
/// radius 4), the status line and a red CANCEL button.
struct ConnectionLogView: View {
    @ObservedObject var log: ConnectionLog
    /// CANCEL: hides the overlay at once and goes home ("aborted by user" is written but rarely seen).
    let onCancel: () -> Void

    private static let bottomAnchor = "connection-log-bottom"

    var body: some View {
        ZStack {
            Color.black.opacity(0.8)

            VStack(alignment: .leading, spacing: 0) {
                Text(log.title)
                    .font(.system(size: 20, weight: .semibold, design: .monospaced))
                    .foregroundColor(.amberAccent)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.bottom, 10)

                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(log.lines) { line in
                                Text(line.shown)
                                    .font(.system(size: 15, design: .monospaced))
                                    .foregroundColor(line.kind.logColor)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            // Keeps the newest line in view.
                            Color.clear
                                .frame(height: 1)
                                .id(Self.bottomAnchor)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // The box is 280 tall including its padding, as on Windows.
                        .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
                    }
                    .onChange(of: log.revision) { _ in
                        proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                    }
                }
                .frame(height: 280)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.deepBlack)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.panelBorder, lineWidth: 1)
                )

                Text(log.status.isEmpty ? " " : log.status)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.top, 8)

                HStack {
                    Spacer()
                    RetroButton("CANCEL", style: .danger) {
                        guard log.isCancellable else { return }
                        onCancel()
                    }
                }
                .padding(.top, 10)
            }
            .padding(EdgeInsets(top: 14, leading: 18, bottom: 14, trailing: 18))
            .frame(maxWidth: 780)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.background.opacity(0.95))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.amberAccent, lineWidth: 1)
            )
            .padding(24)
        }
    }
}

private extension ConnectionTracer.LineKind {
    /// Command lines amber, info `#55DD55`, success `#33FF33`, errors `#FF5555`.
    var logColor: Color {
        switch self {
        case .command: return .amberAccent
        case .info: return .tickerGreen
        case .success: return .accentGreen
        case .error: return .termLightRed
        }
    }
}

/// The connection log's state and typewriter, and the owner of the `ConnectionTracer`.
///
/// One shared instance: `TerminalViewModel.connect` drives it (the way Windows' MainWindow drives its
/// terminal view) and `TerminalView` renders it while `isVisible`. Lines type out at 16 ms steps,
/// `3 + 3 × queued lines` characters per step, so a backlog speeds up; at most 300 lines are kept.
final class ConnectionLog: ObservableObject {
    static let shared = ConnectionLog()

    private static let maxLines = 300
    /// Shortest time the log stays up on a successful connect, from when it appeared.
    private static let minDisplay: TimeInterval = 1.2
    /// Longest a successful connect waits for the log to finish typing out.
    private static let maxTypingWait: TimeInterval = 2.5

    struct Line: Identifiable {
        let id: Int
        let kind: ConnectionTracer.LineKind
        let text: String
        /// What is on screen: the typed prefix, with a `█` cursor while the line is still typing.
        var shown: String
    }

    @Published private(set) var isVisible = false
    @Published private(set) var title = ""
    @Published private(set) var lines: [Line] = []
    @Published private(set) var status = ""
    /// True only while the attempt is still running. Windows detaches the CANCEL handler as soon as
    /// the attempt finishes, so the button is inert during the success hold (the session is live by
    /// then) and behind the failure dialog.
    @Published private(set) var isCancellable = false
    /// Bumped on every visible change, so the view can scroll to the newest line.
    @Published private(set) var revision = 0

    private var tracer: ConnectionTracer?
    private var queue: [(text: String, kind: ConnectionTracer.LineKind)] = []
    private var typingText = ""
    private var typingPosition = 0
    /// Index in `lines` of the line currently typing, nil between lines.
    private var typingIndex: Int?
    private var typeTimer: Timer?
    private var nextLineId = 0
    private var shownAt = Date()
    /// Bumped by every `begin`, so a hold from an earlier attempt can never hide a newer overlay.
    private var generation = 0
    private var holdDeadline: Date?
    /// A board's linked window (12.73): its call is already up in the window that opened it, so the log runs out
    /// of sight and shows only if the connect fails.
    private var quiet = false

    private init() {}

    var isTyping: Bool { typeTimer != nil }

    // MARK: - Attempt lifecycle

    /// Shows the overlay for a fresh attempt. Call before anything else (the tracer starts later, so
    /// "waiting for the previous attempt" can be written first).
    func begin(entry: BBSEntry) {
        generation += 1
        tracer = nil
        stopTyping()
        queue.removeAll()
        lines.removeAll()
        status = ""
        title = "Connecting to \(entry.name)..."
        shownAt = Date()
        isCancellable = true
        quiet = SessionMode.isLinked
        isVisible = !quiet
        revision += 1
    }

    /// An earlier attempt was cancelled or timed out and its native connect hasn't returned yet.
    func noteWaitingForPreviousAttempt() {
        append("waiting for the previous attempt to release the line...", kind: .info)
    }

    /// Starts the tracer's narration. Call just before the native connect is started.
    func startTracing(entry: BBSEntry) {
        let tracer = ConnectionTracer(entry: entry,
                                      log: { [weak self] text, kind in self?.append(text, kind: kind) },
                                      setStatus: { [weak self] text in self?.status = text })
        self.tracer = tracer
        tracer.start()
    }

    /// Writes the outcome. On success the caller then calls `holdThenHide`; on failure the log stays
    /// visible behind the failure dialog and `hide()` is called when that closes.
    func complete(success: Bool, timedOut: Bool, cancelled: Bool) {
        tracer?.complete(success: success, timedOut: timedOut, cancelled: cancelled)
        isCancellable = false
        if quiet && !success && !cancelled {
            isVisible = true   // a linked window's failed connect: the log is the explanation
        }
    }

    /// CANCEL: write "aborted by user" and hide at once.
    func cancelAttempt() {
        complete(success: false, timedOut: false, cancelled: true)
        hide()
    }

    /// Success: keep the overlay up at least `minDisplay` from when it appeared **and** until the log
    /// has finished typing (capped at `maxTypingWait`), then hide. The session is already live and the
    /// board's output draws behind the overlay.
    func holdThenHide() {
        if quiet {
            hide()
            return
        }
        holdDeadline = Date().addingTimeInterval(Self.maxTypingWait)
        pollHold(generation: generation)
    }

    private func pollHold(generation: Int) {
        guard generation == self.generation else { return }
        if isTyping, let deadline = holdDeadline, Date() < deadline {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.pollHold(generation: generation)
            }
            return
        }
        let remaining = max(0, Self.minDisplay - Date().timeIntervalSince(shownAt))
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in
            guard let self = self, generation == self.generation else { return }
            self.hide()
        }
    }

    /// Hides the overlay and drops the log.
    func hide() {
        isCancellable = false
        stopTyping()
        queue.removeAll()
        tracer = nil
        isVisible = false
        lines.removeAll()
        status = ""
        revision += 1
    }

    // MARK: - Typewriter

    /// Queues a line; it types out after any lines ahead of it.
    func append(_ text: String, kind: ConnectionTracer.LineKind) {
        // Command lines are prefixed "> ".
        queue.append((text: kind == .command ? "> " + text : text, kind: kind))
        startTyping()
    }

    private func startTyping() {
        guard typeTimer == nil else { return }
        let timer = Timer(timeInterval: 0.016, repeats: true) { [weak self] _ in
            self?.typeTick()
        }
        RunLoop.main.add(timer, forMode: .common)
        typeTimer = timer
    }

    private func typeTick() {
        // A few characters per tick, faster when lines are backing up (SSH can report several at once).
        var budget = 3 + queue.count * 3
        while budget > 0 {
            if typingIndex == nil {
                guard !queue.isEmpty else {
                    stopTyping()
                    return
                }
                let next = queue.removeFirst()
                typingText = next.text
                typingPosition = 0
                lines.append(Line(id: nextLineId, kind: next.kind, text: next.text, shown: "\u{2588}"))
                nextLineId += 1
                if lines.count > Self.maxLines {
                    lines.removeFirst(lines.count - Self.maxLines)
                }
                typingIndex = lines.count - 1
            }
            guard let index = typingIndex, index >= 0, index < lines.count else {
                typingIndex = nil
                break
            }

            let take = min(budget, typingText.count - typingPosition)
            typingPosition += take
            budget -= take

            let done = typingPosition >= typingText.count
            let typed = String(typingText.prefix(typingPosition))
            lines[index].shown = done ? typed : typed + "\u{2588}"
            revision += 1

            if done {
                typingIndex = nil
            } else {
                break   // budget spent mid-line; the cursor stays on it
            }
        }
    }

    private func stopTyping() {
        typeTimer?.invalidate()
        typeTimer = nil
        typingText = ""
        typingPosition = 0
        typingIndex = nil
    }
}
