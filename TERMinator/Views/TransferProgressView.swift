import SwiftUI

/// File transfer window (ZMODEM, XMODEM, YMODEM), drawn as an overlay on the
/// terminal. Laid out like Windows `Views/TransferDialog.xaml` (§12.29): title +
/// live status, file name + batch counter + dimmed middle-elided path, percent
/// over a 24 pt bar, bytes left / speed + ETA right, the PROTOCOL STATUS feed,
/// and CANCEL / CLOSE (110 wide). 640 x 640, shrinking to 520 x 460 when the
/// terminal is smaller.
struct TransferProgressView: View {
    let info: TransferInfo
    let logLines: [TransferLogLine]
    let onCancel: () -> Void
    let onDismiss: (() -> Void)?

    /// Seconds the finished window stays up before closing itself (Windows
    /// `AutoCloseSeconds`). Any click inside the window stops the countdown.
    private let autoCloseSeconds = 5

    /// Windows RetroTheme AccentCyan (#00FFFF); the shared palette has no exact match.
    private static let accentCyan = Color(red: 0, green: 1, blue: 1)

    @State private var bellPlayed: Bool = false
    @State private var autoCloseSecondsLeft: Int? = nil
    @State private var autoCloseTimer: Timer? = nil
    @State private var showingCancelConfirm: Bool = false
    /// "Auto close" checkbox (Windows `TransferViewModel.AutoClose`). On for every
    /// transfer; untick it to keep the window -- and its diagnostics -- up afterwards.
    @State private var autoClose: Bool = true

    init(info: TransferInfo,
         logLines: [TransferLogLine] = [],
         onCancel: @escaping () -> Void,
         onDismiss: (() -> Void)? = nil) {
        self.info = info
        self.logLines = logLines
        self.onCancel = onCancel
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Title on the left, live status on the right.
            HStack(alignment: .center, spacing: 12) {
                Text("\(info.protocolName) FILE TRANSFER")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(.amberAccent)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(statusText)
                    .font(.system(size: 12))
                    .foregroundColor(Self.accentCyan)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 300, alignment: .trailing)
            }
            .padding(.bottom, 14)

            // File identity: the NAME gets the emphasis; the full PATH sits
            // under it, dimmed and elided in the middle, whole on the tooltip.
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 0) {
                    Text(displayName)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.accentGreen)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 60)
                    if let counter = info.fileCountText {
                        Text(counter)
                            .font(.system(size: 12))
                            .foregroundColor(.textSecondary)
                    }
                }
                if let path = info.fileName, path.contains("/"), displayName != path {
                    Text(elidePath(path))
                        .font(.system(size: 11))
                        .foregroundColor(.textSecondary)
                        .lineLimit(1)
                        // retroTooltip, not .help: §3 makes the readable tooltip app-wide.
                        .retroTooltip(path)
                }
            }
            .padding(.bottom, 12)

            // Percentage sitting on top of the bar.
            VStack(spacing: 4) {
                Text(info.percentText)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.accentGreen)
                    .frame(maxWidth: .infinity)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.background)
                        Rectangle()
                            .fill(Color.accentGreen)
                            .frame(width: geo.size.width * info.progressFraction)
                    }
                    .overlay(Rectangle().stroke(Color.panelBorder, lineWidth: 1))
                }
                .frame(height: 24)
            }
            .padding(.bottom, 6)

            // Bytes on the left, throughput and ETA on the right.
            HStack {
                Text(info.bytesText)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(.textPrimary)
                Spacer()
                Text(info.speedText)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(.amberAccent)
            }
            .padding(.bottom, 16)

            Text("PROTOCOL STATUS")
                .font(.system(size: 11))
                .foregroundColor(.textSecondary)
                .padding(.bottom, 5)

            // The running protocol log: what makes "the board went quiet after
            // ZEOF" visible on screen rather than invisible. Takes the slack.
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(logLines) { line in
                            Text(line.text)
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundColor(colorFor(line.level))
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.background)
                .overlay(Rectangle().stroke(Color.panelBorder, lineWidth: 1))
                .onChange(of: logLines.last?.id) { lastId in
                    // One scroll per batch of new lines (the feed is published
                    // as a whole array per poll), after layout has settled.
                    guard let lastId = lastId else { return }
                    DispatchQueue.main.async {
                        proxy.scrollTo(lastId, anchor: .bottom)
                    }
                }
            }

            HStack(spacing: 10) {
                Spacer()
                Toggle("Auto close", isOn: $autoClose)
                    .toggleStyle(.checkbox)
                    .foregroundColor(.textSecondary)
                    .padding(.trailing, 10)
                    .retroTooltip("Untick to keep this window open after the transfer, e.g. to read the diagnostics")
                if shouldShowCancel {
                    Button {
                        showingCancelConfirm = true
                    } label: {
                        Text("CANCEL").frame(width: 70)
                    }
                    .buttonStyle(RetroButtonStyle(fgColor: RetroButtonPreset.danger.fg,
                                                  borderColor: RetroButtonPreset.danger.border,
                                                  hoverBgColor: RetroButtonPreset.danger.hoverBg))
                }
                if shouldShowClose {
                    Button {
                        stopAutoClose()
                        onDismiss?()
                    } label: {
                        Text("CLOSE").frame(width: 70)
                    }
                    .buttonStyle(RetroButtonStyle(fgColor: RetroButtonPreset.green.fg,
                                                  borderColor: RetroButtonPreset.green.border,
                                                  hoverBgColor: RetroButtonPreset.green.hoverBg))
                }
            }
            .padding(.top, 14)
        }
        .padding(EdgeInsets(top: 18, leading: 20, bottom: 16, trailing: 20))
        .frame(minWidth: 520, idealWidth: 640, maxWidth: 640,
               minHeight: 460, idealHeight: 640, maxHeight: 640)
        .background(Color.backgroundMedium)
        .overlay(Rectangle().stroke(Color.borderHighlight, lineWidth: 1))
        // Any deliberate click inside the window stops the auto-close countdown
        // (Windows: PreviewMouseDown on the dialog). Simultaneous, so buttons
        // and the log's scrolling still get the event.
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { stopAutoClose() })
        .onAppear { handleStateChange(info.state) }
        .onChange(of: info.state) { newState in handleStateChange(newState) }
        .onChange(of: autoClose) { enabled in
            if !enabled { stopAutoClose() }
        }
        .onDisappear { stopAutoClose() }
        .alert("Cancel Transfer?", isPresented: $showingCancelConfirm) {
            Button("Cancel Transfer", role: .destructive) {
                onCancel()
            }
            Button("Continue", role: .cancel) { }
        } message: {
            Text("Are you sure you want to cancel the current file transfer?")
        }
    }

    private func handleStateChange(_ state: TransferState) {
        switch state {
        case .complete, .error, .cancelled:
            onTransferEnded()
        case .sending, .receiving:
            // A new transfer reusing a window that was still counting down.
            stopAutoClose()
            bellPlayed = false
            autoClose = true
        case .idle:
            break
        }
    }

    private func onTransferEnded() {
        if !bellPlayed {
            bellPlayed = true
            BellManager.shared.playBell()
        }
        guard autoClose, autoCloseTimer == nil else { return }
        autoCloseSecondsLeft = autoCloseSeconds
        autoCloseTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
            if let secondsLeft = autoCloseSecondsLeft, secondsLeft > 1 {
                autoCloseSecondsLeft = secondsLeft - 1
            } else {
                timer.invalidate()
                autoCloseTimer = nil
                autoCloseSecondsLeft = nil
                onDismiss?()
            }
        }
    }

    /// Stops the countdown and leaves the status line as-is (no "(closing in Ns)").
    private func stopAutoClose() {
        autoCloseTimer?.invalidate()
        autoCloseTimer = nil
        autoCloseSecondsLeft = nil
    }

    /// Severity colour, as the Windows dialog: protocol traffic TextSecondary,
    /// our own notes cyan, native diagnostics green, warnings amber, errors red.
    private func colorFor(_ level: String) -> Color {
        switch level {
        case "S": return Self.accentCyan
        case "G": return .accentGreen
        case "W": return .amberAccent
        case "E": return .accentRed
        default:  return .textSecondary
        }
    }

    /// Last path segment. The native side hands back a full path early in a
    /// send and a bare name once the protocol takes over.
    private var displayName: String {
        guard let name = info.fileName, !name.isEmpty else { return "" }
        if let cut = name.lastIndex(of: "/"), name.index(after: cut) < name.endIndex {
            return String(name[name.index(after: cut)...])
        }
        return name
    }

    /// Elide the middle of a path so both ends stay readable (Windows
    /// `ElidePath`, max 62). Cutting on separators keeps whole segments.
    private func elidePath(_ path: String, max: Int = 62) -> String {
        guard path.count > max else { return path }
        let name = displayName
        let keepHead = Swift.max(0, max - name.count - 5)
        guard keepHead > 0 else { return name }

        var head = String(path.prefix(keepHead))
        if let cut = head.lastIndex(of: "/"), cut > head.startIndex {
            head = String(head[head.startIndex..<cut])
        }
        return "\(head)/.../\(name)"
    }

    /// Windows `StatusText`: "Receiving..." / "Sending..." while running, then
    /// "Transfer complete" / the error / "Cancelled", with "(closing in Ns)"
    /// during the countdown.
    private var statusText: String {
        let baseText: String
        switch info.state {
        case .idle: baseText = "Idle"
        case .receiving: baseText = "Receiving..."
        case .sending: baseText = "Sending..."
        case .complete: baseText = info.skippedByBoard ? "Skipped by the board" : "Transfer complete"
        case .error(let message): baseText = message
        case .cancelled: baseText = "Cancelled"
        }
        if let secondsLeft = autoCloseSecondsLeft {
            return "\(baseText) (closing in \(secondsLeft)s)"
        }
        return baseText
    }

    private var shouldShowCancel: Bool {
        switch info.state {
        case .receiving, .sending, .idle: return true
        default: return false
        }
    }

    private var shouldShowClose: Bool {
        switch info.state {
        case .complete, .error, .cancelled: return true
        default: return false
        }
    }
}
