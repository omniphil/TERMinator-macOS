import SwiftUI

/// Startup "boot" screen (spec §5): the BIOS / modem lines type out, then it cuts straight to the app
/// — no glitch, no fade. Mirrors the Windows client's `Controls/BootSequenceOverlay.cs`.
///
/// A key or a click while it runs completes the text at once, hides the "press any key to skip" hint
/// and waits on `Press any key to load TERMinator or "C" for command line mode` with a cursor blinking
/// every 0.5 s. At that prompt **C** goes to the command line (no confirmation) and anything else loads
/// the app.
///
/// The screen watches the key stream itself (`KeyEventMonitor`) and swallows what it consumes: at launch
/// nothing in the window has focus, so waiting for first responder would drop the skip key.
///
/// The tube opens this screen from the glowing dot and line (`CrtPowerModel`, spec §7), so the typing
/// only starts once the picture is fully open (~0.92 s = `CrtPowerModel.powerOnDuration`). A key or a
/// click during the power-on still skips straight to the prompt.
struct BootSequenceView: View {
    let lines: [String]
    /// The boot screen is done (typed out, or dismissed at the prompt): show the app.
    let onFinished: () -> Void
    /// C was pressed at the prompt: show the command line, no confirmation.
    let onCommandLine: () -> Void

    @StateObject private var model = BootSequenceModel()
    @StateObject private var keys = KeyMonitorHolder()

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.deepBlack

            Text(model.screen)
                .font(.system(size: 15, design: .monospaced))
                .foregroundColor(.tickerGreen)
                .textSelection(.disabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(EdgeInsets(top: 28, leading: 36, bottom: 28, trailing: 36))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomTrailing) {
            if model.showHint {
                Text("press any key to skip")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.bootHint)
                    .padding(EdgeInsets(top: 0, leading: 0, bottom: 12, trailing: 18))
            }
        }
        .contentShape(Rectangle())
        // A click anywhere does what a key does.
        .onTapGesture {
            self.model.advance(commandLineKey: false)
        }
        .onAppear {
            self.model.onFinished = self.onFinished
            self.model.onCommandLine = self.onCommandLine
            self.model.configure(lines: self.lines)
            // Typing starts when the CRT power-on has finished opening the picture.
            self.model.start(after: CrtPowerModel.powerOnDuration)
            self.keys.monitor.start { event in
                let isC = event.charactersIgnoringModifiers?.lowercased() == "c"
                self.model.advance(commandLineKey: isC)
                return true   // the boot screen owns the keyboard while it is up
            }
        }
        .onDisappear {
            self.keys.monitor.stop()
            self.model.stop()
        }
    }
}

/// Keeps a `KeyEventMonitor` alive for the lifetime of a SwiftUI view.
final class KeyMonitorHolder: ObservableObject {
    let monitor = KeyEventMonitor()
}

/// The boot screen's clock and text. Typing is driven by **elapsed time**, not by counting timer
/// ticks: tick-counting ran well over its intended length on Windows and would here too.
final class BootSequenceModel: ObservableObject {
    /// How long the lines take to type out. Shared with the console's `boot` command.
    static let typingDuration: TimeInterval = 0.5
    private static let holdDuration: TimeInterval = 0.15
    /// The beat after each line, in "characters" of typing time.
    private static let linePauseUnits = 4
    static let loadPrompt = "Press any key to load TERMinator or \"C\" for command line mode"

    @Published private(set) var screen: String = ""
    @Published private(set) var showHint: Bool = true

    var onFinished: (() -> Void)?
    var onCommandLine: (() -> Void)?

    private var lines: [String] = []
    private var totalUnits: Int = 1
    private var startedAt: Date?
    private var startTimer: Timer?
    private var typeTimer: Timer?
    private var holdTimer: Timer?
    private var blinkTimer: Timer?
    private var started = false
    private var waitingForKey = false
    private var finished = false

    deinit {
        stopTimers()
    }

    func configure(lines: [String]) {
        self.lines = lines
        totalUnits = Self.totalUnits(lines)
    }

    /// Starts typing after `delay` (the CRT power-on duration).
    func start(after delay: TimeInterval) {
        guard !started, !waitingForKey, !finished else { return }
        started = true

        guard delay > 0 else {
            beginTyping()
            return
        }
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            self?.beginTyping()
        }
        RunLoop.main.add(timer, forMode: .common)
        startTimer = timer
    }

    /// A key or a click while the boot screen is up. While the text is still typing (or holding) it
    /// finishes at once and waits on the prompt; at the prompt, C opens the command line and anything
    /// else loads the app.
    func advance(commandLineKey: Bool) {
        guard !finished else { return }

        if waitingForKey {
            if commandLineKey {
                stopTimers()
                finished = true     // ignore anything that arrives before the host removes us
                onCommandLine?()
            } else {
                finish()
            }
            return
        }

        stopTimers()
        waitingForKey = true
        showHint = false

        // Every line, a blank line, then the prompt with a blinking cursor.
        let full = Self.buildScreen(lines, units: totalUnits) + "\n" + Self.loadPrompt
        var cursorOn = true
        screen = full + "\u{2588}"
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            cursorOn.toggle()
            self.screen = full + (cursorOn ? "\u{2588}" : " ")
        }
        RunLoop.main.add(timer, forMode: .common)
        blinkTimer = timer
    }

    func stop() {
        stopTimers()
    }

    private func beginTyping() {
        startTimer?.invalidate()
        startTimer = nil
        guard typeTimer == nil, !waitingForKey, !finished else { return }

        startedAt = Date()
        let timer = Timer(timeInterval: 0.015, repeats: true) { [weak self] _ in
            self?.typeTick()
        }
        RunLoop.main.add(timer, forMode: .common)
        typeTimer = timer
        typeTick()
    }

    private func typeTick() {
        let elapsed = Date().timeIntervalSince(startedAt ?? Date())
        let progress = min(1, elapsed / Self.typingDuration)
        let shown = Self.buildScreen(lines, units: Int((progress * Double(totalUnits)).rounded()))

        guard progress >= 1 else {
            screen = shown + "\u{2588}"
            return
        }

        screen = shown
        typeTimer?.invalidate()
        typeTimer = nil

        // Hold the finished screen for a beat before handing over to the app.
        let timer = Timer(timeInterval: Self.holdDuration, repeats: false) { [weak self] _ in
            self?.finish()
        }
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        stopTimers()
        onFinished?()
    }

    private func stopTimers() {
        startTimer?.invalidate()
        typeTimer?.invalidate()
        holdTimer?.invalidate()
        blinkTimer?.invalidate()
        startTimer = nil
        typeTimer = nil
        holdTimer = nil
        blinkTimer = nil
    }

    /// Total typing "units" for `lines`: every character plus a beat after each line.
    static func totalUnits(_ lines: [String]) -> Int {
        max(1, lines.reduce(0) { $0 + $1.count + linePauseUnits })
    }

    /// The text visible after `units` of typing: whole lines (each with its trailing beat) followed by
    /// the part of the current line typed so far. Shared with the console's `boot` command.
    static func buildScreen(_ lines: [String], units: Int) -> String {
        var remaining = units
        var shown = ""
        for line in lines {
            let lineUnits = line.count + linePauseUnits
            if remaining >= lineUnits {
                shown += line + "\n"
                remaining -= lineUnits
                continue
            }
            shown += String(line.prefix(max(0, min(remaining, line.count))))
            break
        }
        return shown
    }
}

// MARK: - The launch text

extension BootSequenceView {
    /// The boot text: fixed BIOS flavor plus the real version, board count, TAP+ and CRT status, and
    /// the elite rank. Same lines and spacing as Windows `MainWindow.BuildBootLines`.
    static func launchLines() -> [String] {
        let boards = BBSEntryStore.shared.entries.count
        let defaults = UserDefaults.standard
        let soundtrackEnabled = defaults.object(forKey: SoundtrackManager.keySoundtrackEnabled) as? Bool ?? true
        // SoundtrackManager registers 250 as its default, but it may not have been created yet at
        // launch and its constant is private — hence the literal fallback.
        let cacheLimitMb = defaults.object(forKey: SoundtrackManager.keySoundtrackCacheLimit) as? Int ?? 250
        let soundtrack = soundtrackEnabled ? "Enabled  (cache limit \(cacheLimitMb) MB)" : "Disabled"
        let crtSettings = CrtSettingsStore.shared.current
        let crt = crtSettings.enabled ? "ON  (\(crtSettings.preset))" : "OFF"
        let calls = EliteRank.totalCalls

        return [
            "TERMinator BIOS v\(AppInfo.version)    (C) 1989-2026 JSONBourne Innovations",
            "",
            "CPU    : 80486DX2-66 ........................ OK",
            "MEMORY : 640K base, 15360K extended ......... OK",
            "UART   : COM1 16550A @ 115200 bps ........... OK",
            "",
            "ATZ",
            "OK",
            "AT&F1 S0=0 E1 Q0 V1",
            "OK",
            "PHONEBOOK : \(boards) board\(boards == 1 ? "" : "s") loaded",
            "TAP+      : \(soundtrack)",
            "CRT MODE  : \(crt)",
            "RANK      : \(EliteRank.summary(for: calls))",
            "",
            "CARRIER DETECT",
            "CONNECT 115200",
        ]
    }
}
