import SwiftUI
import AppKit

/// Konami-code easter egg (spec §5): a full-window overlay of black at 93% + the digital rain, with a
/// decrypting "GOD MODE ACTIVATED" in a bordered box. Mirrors the Windows client's
/// `Controls/MatrixRainOverlay.cs`.
///
/// Auto-dismisses after 6.5 s, or on any key or click, fading out over 0.4 s.
struct MatrixRainOverlay: View {
    /// Called once the fade-out has finished: the host removes the overlay.
    let onFinished: () -> Void

    @State private var opacity: Double = 1
    @State private var bannerTrigger: Int = 0
    @State private var closing = false
    @State private var autoCloseWork: DispatchWorkItem?
    @StateObject private var keys = KeyMonitorHolder()

    var body: some View {
        ZStack {
            Color.black.opacity(0.93)

            DigitalRainView()

            DecryptText(text: "GOD MODE ACTIVATED", duration: 1.1, replayTrigger: bannerTrigger)
                .font(.system(size: 42, weight: .bold, design: .monospaced))
                .foregroundColor(.accentGreen)
                .shadow(color: Color.accentGreen.opacity(1), radius: 12)
                .padding(EdgeInsets(top: 18, leading: 36, bottom: 18, trailing: 36))
                .background(Color.black.opacity(0.85))
                .overlay(
                    Rectangle().strokeBorder(Color.accentGreen, lineWidth: 1)
                )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(opacity)
        .contentShape(Rectangle())
        .onTapGesture { self.dismiss() }
        .onAppear {
            self.bannerTrigger += 1
            self.keys.monitor.start { _ in
                self.dismiss()
                return true    // the rain owns the keyboard while it is up
            }
            let work = DispatchWorkItem { self.dismiss() }
            self.autoCloseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.5, execute: work)
        }
        .onDisappear {
            self.keys.monitor.stop()
            self.autoCloseWork?.cancel()
        }
    }

    private func dismiss() {
        guard !closing else { return }
        closing = true
        autoCloseWork?.cancel()
        keys.monitor.stop()
        // Windows animates Opacity with a plain DoubleAnimation, i.e. linear.
        withAnimation(.linear(duration: 0.4)) {
            opacity = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            self.onFinished()
        }
    }
}

/// Watches for ↑ ↑ ↓ ↓ ← → ← → B A (the last 10 keys). The host only runs it on a quiet home screen —
/// not while any overlay is up — and the history is cleared whenever it stops, so a half-typed code
/// never survives a trip to the phonebook. Keys are observed, never swallowed.
final class KonamiWatcher: ObservableObject {
    private static let code: [UInt16] = [
        KeyCode.upArrow, KeyCode.upArrow, KeyCode.downArrow, KeyCode.downArrow,
        KeyCode.leftArrow, KeyCode.rightArrow, KeyCode.leftArrow, KeyCode.rightArrow,
        KeyCode.b, KeyCode.a,
    ]

    /// Called on the main thread when the code is entered.
    var onMatch: (() -> Void)?

    private let monitor = KeyEventMonitor()
    private var recent: [UInt16] = []

    func setEnabled(_ enabled: Bool) {
        guard enabled else {
            monitor.stop()
            recent.removeAll()
            return
        }
        guard !monitor.isRunning else { return }
        recent.removeAll()
        monitor.start { [weak self] event in
            self?.track(event.keyCode)
            return false      // never swallow: the home screen keeps working normally
        }
    }

    private func track(_ keyCode: UInt16) {
        recent.append(keyCode)
        if recent.count > Self.code.count {
            recent.removeFirst(recent.count - Self.code.count)
        }
        if recent == Self.code {
            recent.removeAll()
            onMatch?()
        }
    }
}
