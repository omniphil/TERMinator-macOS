import SwiftUI

/// Retro DOS-style view showing file transfer progress.
/// Styled to look like classic ZMODEM transfer screens.
struct TransferProgressView: View {
    let info: TransferInfo
    let onCancel: () -> Void
    let onDismiss: (() -> Void)?

    private let progressWidth = 25
    private let filledChar: Character = "█"
    private let emptyChar: Character = "░"
    private let autoCloseSeconds = 5

    @State private var bellPlayed: Bool = false
    @State private var autoCloseSecondsLeft: Int? = nil
    @State private var autoCloseTimer: Timer? = nil
    @State private var showingCancelConfirm: Bool = false

    init(info: TransferInfo, onCancel: @escaping () -> Void, onDismiss: (() -> Void)? = nil) {
        self.info = info
        self.onCancel = onCancel
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                // Title bar
                Text(titleText)
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background(Color.logoTermColor)
                    .padding(.bottom, 12)

                VStack(alignment: .leading, spacing: 0) {
                    // File info
                    HStack(spacing: 0) {
                        Text("File: ")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.appPrimary)
                        Text(info.fileName ?? "--")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.appPrimaryLight)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer()
                    }
                    .padding(.bottom, 6)

                    // Progress bar
                    HStack(spacing: 0) {
                        Text(buildProgressBar())
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.appPrimary)
                            .tracking(-0.5)
                        Spacer()
                        Text(String(format: "%3d%%", info.progressPercent))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.appPrimaryLight)
                            .frame(minWidth: 44, alignment: .trailing)
                    }
                    .padding(.bottom, 6)

                    // Bytes
                    Text("Bytes: \(info.bytesTransferred) / \(info.totalBytes)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.appPrimary)
                        .padding(.bottom, 2)

                    // Speed
                    Text("Speed: \(info.bytesPerSecond) cps")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.appPrimary)
                        .padding(.bottom, 8)

                    // Status
                    HStack {
                        Spacer()
                        Text(statusText)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(statusColor)
                        Spacer()
                    }
                    .padding(.bottom, 12)

                    // Buttons
                    HStack(spacing: 0) {
                        Spacer()
                        if shouldShowCancel {
                            Button {
                                showingCancelConfirm = true
                            } label: {
                                Text("[ Cancel ]")
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(.termLightRed)
                                    .padding(8)
                            }
                            .buttonStyle(.plain)
                        }
                        if shouldShowClose {
                            Button(action: { onDismiss?() }) {
                                Text("[  OK  ]")
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(.accent)
                                    .padding(8)
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer()
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
            .frame(width: 300)
            .background(Color.crtBackground)
        }
        .padding(2)
        .background(Color.logoTermColor)
        .onAppear { handleStateChange(info.state) }
        .onChange(of: info.state) { newState in handleStateChange(newState) }
        .onDisappear {
            autoCloseTimer?.invalidate()
            autoCloseTimer = nil
        }
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
        default:
            break
        }
    }

    private func onTransferEnded() {
        if !bellPlayed {
            bellPlayed = true
            BellManager.shared.playBell()
        }
        guard autoCloseTimer == nil else { return }
        autoCloseSecondsLeft = autoCloseSeconds
        autoCloseTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
            if let secondsLeft = autoCloseSecondsLeft, secondsLeft > 1 {
                autoCloseSecondsLeft = secondsLeft - 1
            } else {
                timer.invalidate()
                autoCloseTimer = nil
                onDismiss?()
            }
        }
    }

    private func buildProgressBar() -> String {
        let percent = info.progressPercent
        let filled = max(0, min(progressWidth, (percent * progressWidth) / 100))
        let empty = progressWidth - filled
        return "[" + String(repeating: filledChar, count: filled) + String(repeating: emptyChar, count: empty) + "]"
    }

    private var titleText: String {
        switch info.direction {
        case .send: return " ZMODEM Send "
        case .receive: return " ZMODEM Recv "
        case .none: return " ZMODEM Transfer "
        }
    }

    private var statusText: String {
        let baseText: String
        switch info.state {
        case .idle: baseText = "Waiting for remote..."
        case .receiving, .sending: baseText = "Transferring..."
        case .complete: baseText = "Transfer OK!"
        case .error(let message): baseText = "ERROR: \(message)"
        case .cancelled: baseText = "Transfer ABORTED"
        }
        if let secondsLeft = autoCloseSecondsLeft {
            return "\(baseText) (closing in \(secondsLeft)s)"
        }
        return baseText
    }

    private var statusColor: Color {
        switch info.state {
        case .idle: return .termYellow
        case .receiving, .sending: return .accent
        case .complete: return .accent
        case .error: return .termLightRed
        case .cancelled: return .termYellow
        }
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
