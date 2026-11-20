import AppKit
import SwiftUI

/// Main content view that switches between app screens.
/// Uses enum-based navigation (no NavigationStack) like Windows ContentControl.
struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var deepLinkManager: DeepLinkManager

    @State private var showingAbout = false
    @State private var showingHelp = false
    @State private var showingSshDebug = false
    @State private var sshDebugLog = ""

    // MARK: Hacker flair (spec §5)

    /// The boot screen's lines while it is up, nil the rest of the time.
    @State private var bootLines: [String]?
    /// The Konami easter egg's rain overlay. The console's `matrix` plays the same one.
    @State private var showingRain = false
    @StateObject private var konami = KonamiWatcher()

    // MARK: Command line mode (spec §6)

    /// One console for the app's lifetime, so its scrollback and history survive every visit.
    @ObservedObject private var console = CommandLineConsole.shared
    /// The Elite confirmation, shown before the console when it is asked for from the home screen.
    @State private var showingEliteConfirm = false

    // MARK: Idle screensaver (spec §8)

    /// The screensaver's slides while it is up, nil the rest of the time.
    @State private var screensaverSlides: [ScreensaverSlide]?

    /// True while the main window is in the Dock. Minimizing doesn't make SwiftUI call onDisappear, so
    /// without this the home screen's marquee, glitch, static, scanline, CRT-thumbnail and facts-ticker
    /// timers all kept running (and burning CPU) with nothing on screen. Windows/Linux pause the same set.
    @State private var mainWindowMinimized = false
    @StateObject private var idle = IdleWatcher()
    /// View > Screensaver. Turning it on restarts the idle countdown.
    @AppStorage(AppPreferences.screensaverEnabled) private var screensaverEnabled = true

    // MARK: Modem, phosphor, Boss Hide

    /// Call > Modem Speed / Preferences / the console's `baud`: pushed to the native bridge whenever it changes.
    @AppStorage(AppPreferences.emulatedBaud) private var emulatedBaud = 0
    /// Phosphor for the screens that don't tint themselves (Phonebook, Preferences).
    @AppStorage(AppPreferences.phosphor) private var phosphor = PhosphorMode.color.rawValue
    /// ⌃⇧B / F15 put Boss Hide up; any key takes it down. Watches the key stream before the terminal does.
    @State private var bossKeys = KeyEventMonitor()

    /// The boot screen belongs to the launch, not to every window: considered exactly once.
    private static var didConsiderBoot = false

    /// Konami is tracked only on a quiet home screen — never while an overlay is up — and the key
    /// history is cleared whenever tracking stops.
    private var konamiEnabled: Bool {
        appState.currentView == .home && bootLines == nil && !showingRain && !console.isVisible
            && screensaverSlides == nil && !showingAbout && !showingHelp && !showingSshDebug
            && !showingEliteConfirm && !appState.bossHideActive
    }

    /// The idle timer's "quiet home screen" test (Windows: home view showing and nothing in the
    /// effect overlay host): the screensaver never starts over a session, the console, the boot
    /// screen, the rain or a dialog.
    private var quietHome: Bool {
        appState.currentView == .home && bootLines == nil && !showingRain && !console.isVisible
            && screensaverSlides == nil && !showingAbout && !showingHelp && !showingSshDebug
            && !showingEliteConfirm && !appState.bossHideActive
            // Never over a running TRACE module (Windows: EngineHost has children)
            && TraceSessionManager.shared.sessions.isEmpty
    }

    private var phosphorMode: PhosphorMode {
        PhosphorMode(rawValue: phosphor) ?? .color
    }

    var body: some View {
        // The whole content goes through the old-tube power transform (spec §7); the glowing line and
        // dot live on their own layer above it.
        CrtPowerScreen {
            screens
        }
    }

    private var screens: some View {
        ZStack {
            // Dark background
            Color.background.ignoresSafeArea()

            // Content based on current navigation state
            Group {
                switch appState.currentView {
                case .home:
                    // A BBS window (SessionMode) never shows the home screen: going home closes it, and the
                    // window stays black while it does
                    if SessionMode.isSession {
                        Color.black
                    } else {
                        // Torn down while minimized (see hiddenKeepingLayout) so every home timer stops;
                        // only the home case, so a minimized BBS session is never touched
                        HomeView()
                            .hiddenKeepingLayout(mainWindowMinimized)
                    }

                case .phonebook:
                    // Phosphor tints every screen. Home and the console tint themselves; the terminal tints its
                    // Metal canvas in its own shader (TerminalMetalView) and its status bar with this modifier.
                    PhonebookView()
                        .screenEffect(phosphor: phosphorMode)

                case .terminal(let entry):
                    TerminalView(entry: entry)

                case .settings:
                    SettingsView()
                        .screenEffect(phosphor: phosphorMode)
                }
            }
            // The window opens black while the boot screen runs. The content stays laid out (so the
            // home window fit still measures the real layout) but isn't drawn. macOS's menu bar is
            // system-wide, so unlike Windows there is no in-window menu to hide with it.
            // The screensaver is opaque: stop drawing the home screen under it, or every frame of
            // the drifting picture re-renders the cards' glows below it (the biggest lag source on
            // Windows). Opacity keeps the layout, so the window never resizes.
            .hiddenKeepingLayout(bootLines != nil || screensaverSlides != nil)

            // Boot sequence on launch
            if let lines = bootLines {
                BootSequenceView(lines: lines,
                                 onFinished: {
                                     self.bootLines = nil
                                 },
                                 onCommandLine: {
                                     self.bootLines = nil
                                     // The same notification View > Command Line Mode posts, with
                                     // skipConfirmation so the boot prompt's "C" goes straight in
                                     // (no Elite confirmation, §6).
                                     NotificationCenter.default.post(name: .showCommandLine, object: nil,
                                                                     userInfo: ["skipConfirmation": true])
                                 })
                    .ignoresSafeArea()
                    .zIndex(10)
            }

            // Settings over a live session (AppState.openSettings): the terminal stays underneath, connected.
            if appState.settingsOverTerminal {
                SettingsView()
                    .screenEffect(phosphor: phosphorMode)
                    .ignoresSafeArea()
                    .zIndex(11)
            }

            // Command line mode: above everything, and it stays up behind a session it started.
            if console.isVisible {
                CommandLineView(console: console)
                    .ignoresSafeArea()
                    .zIndex(12)
            }

            // Konami easter egg: digital rain + GOD MODE ACTIVATED. Also the console's "matrix",
            // which is why it sits above the console — and hands the keyboard back when it ends.
            if showingRain {
                MatrixRainOverlay {
                    self.showingRain = false
                    if self.console.isVisible {
                        self.console.focusInput()
                    }
                }
                .ignoresSafeArea()
                .zIndex(14)
            }

            // Idle screensaver (spec §8). Only ever over a quiet home screen, so nothing else can be
            // up behind it; dismissing it restarts the idle countdown.
            if let slides = screensaverSlides {
                ScreensaverView(slides: slides) {
                    self.screensaverSlides = nil
                    self.idle.restart()
                }
                .ignoresSafeArea()
                .zIndex(16)
            }

            // Boss Hide: a boring spreadsheet over everything (any key brings TERMinator back)
            if appState.bossHideActive {
                BossHideView()
                    .ignoresSafeArea()
                    .zIndex(20)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            if !Self.didConsiderBoot {
                Self.didConsiderBoot = true
                // A BBS window (SessionMode, §12.57) goes straight to its board: no boot screen, no power-on
                if !SessionMode.isSession {
                    if UserDefaults.standard.bool(forKey: AppPreferences.showBootSequence) {
                        self.bootLines = BootSequenceView.launchLines()
                    }
                    // CRT power-on (spec §7): the tube opens the boot screen, or the home screen when the
                    // boot sequence is off. Collapse the picture now and start the effect on the next turn
                    // of the main loop, once the window is really showing, so its start isn't missed
                    // (Windows waits for ContentRendered). App start only — never on connect.
                    CrtPowerModel.shared.prepareForPowerOn()
                    DispatchQueue.main.async {
                        CrtPowerModel.shared.powerOn()
                    }
                }

                // The stored modem speed, and the key clicks warmed up before the first keystroke
                NativeBridge.shared.setEmulatedBps(emulatedBaud)
                if UserDefaults.standard.bool(forKey: AppPreferences.keyClicksEnabled) {
                    DispatchQueue.main.async {
                        KeyClickService.shared.warmUp()
                    }
                }
            }

            // Boss Hide keys. Events carrying ⌘ pass straight through (KeyEventMonitor), so ⌘Q still quits.
            self.bossKeys.start { event in
                if AppState.shared.bossHideActive {
                    if !event.isARepeat {
                        BossHide.set(false)
                    }
                    return true
                }
                let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                let chord = modifiers == [.control, .shift] && event.charactersIgnoringModifiers?.lowercased() == "b"
                if chord || event.keyCode == 113 { // 113 = F15, where Pause sits on a Mac extended keyboard
                    if !event.isARepeat {
                        BossHide.set(true)
                    }
                    return true
                }
                return false
            }
            self.konami.onMatch = {
                self.showingRain = true
            }
            self.konami.setEnabled(self.konamiEnabled)

            // The console's two app-side actions (Windows' ICommandLineHost).
            self.console.onConnect = { entry in
                self.startConsoleSession(entry)
            }
            self.console.onMatrix = {
                self.showingRain = true
            }

            // Idle screensaver: 3 minutes without input, checked every 5 s, quiet home screen only.
            self.idle.isQuiet = { self.quietHome }
            self.idle.onIdle = {
                guard self.screensaverSlides == nil else { return }
                self.screensaverSlides = ScreensaverView.buildSlides()
            }
            self.idle.start()
        }
        // Settings over the terminal goes with the session: a hang-up or leaving the terminal closes it (the
        // edits stand, as when Settings is left any other way)
        .onChange(of: appState.isConnected) { connected in
            if !connected && appState.settingsOverTerminal {
                appState.settingsOverTerminal = false
            }
        }
        .onChange(of: appState.currentView) { view in
            // A BBS window has no home screen: where the main window would go home (disconnect, failed
            // connect, cancel), it closes (§12.57)
            if SessionMode.isSession, view == .home {
                SessionMode.close()
                return
            }
            if case .terminal = view {
                return
            }
            if appState.settingsOverTerminal {
                appState.settingsOverTerminal = false
            }
        }
        .onChange(of: konamiEnabled) { enabled in
            konami.setEnabled(enabled)
        }
        .onDisappear {
            konami.setEnabled(false)
            idle.stop()
            bossKeys.stop()
        }
        // Call > Modem Speed, Preferences or the console's "baud": applies at once, mid-session included
        .onChange(of: emulatedBaud) { bps in
            NativeBridge.shared.setEmulatedBps(bps)
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleBossHide)) { _ in
            BossHide.set(!appState.bossHideActive)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didMiniaturizeNotification)) { note in
            guard note.object as? NSWindow === WindowSizeManager.mainWindow else { return }
            mainWindowMinimized = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didDeminiaturizeNotification)) { note in
            guard note.object as? NSWindow === WindowSizeManager.mainWindow else { return }
            mainWindowMinimized = false
        }
        // Preferences > Display > Screensaver TEST
        .onReceive(NotificationCenter.default.publisher(for: .startScreensaver)) { _ in
            guard screensaverSlides == nil else { return }
            screensaverSlides = ScreensaverView.buildSlides()
        }
        // Enabling the screensaver in the View menu restarts the idle timer (Windows does the same).
        .onChange(of: screensaverEnabled) { enabled in
            if enabled {
                idle.restart()
            }
        }
        .sheet(isPresented: $showingAbout) {
            AboutView()
        }
        .sheet(isPresented: $showingHelp) {
            HelpView()
        }
        .sheet(isPresented: $showingSshDebug) {
            SshDebugView(logText: sshDebugLog)
        }
        .sheet(isPresented: $showingEliteConfirm) {
            CommandLineConfirmView {
                console.show(notice: nil, boot: true)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showAbout)) { _ in
            showingAbout = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .showChangelog)) { _ in
            ChangelogWindow.show()
        }
        .onReceive(NotificationCenter.default.publisher(for: .showUpdates)) { _ in
            MainActor.assumeIsolated { UpdateWindow.show() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showHelp)) { _ in
            showingHelp = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .showCrtSettings)) { _ in
            CrtSettingsWindow.show()
        }
        // View > Command Line Mode, the COMMAND tile (both from the home screen only) and the boot
        // prompt's "C", which skips the Elite confirmation.
        .onReceive(NotificationCenter.default.publisher(for: .showCommandLine)) { note in
            if note.userInfo?["skipConfirmation"] as? Bool == true {
                console.show(notice: nil)
            } else if appState.currentView == .home && !console.isVisible {
                showingEliteConfirm = true
            }
        }
        // A session started from the console returns there when it ends, fails or is cancelled.
        .onChange(of: appState.currentView) { destination in
            guard destination == .home, let session = appState.consoleSession else { return }
            appState.consoleSession = nil
            let notice: String
            if !session.reachedTerminal {
                notice = "connection cancelled"
            } else if session.connected {
                notice = "Disconnected from \(session.board)"
            } else {
                notice = "Couldn't connect to \(session.board)"
            }
            console.show(notice: notice)
        }
        .onReceive(NotificationCenter.default.publisher(for: .showSshDebugLog)) { _ in
            sshDebugLog = NativeBridge.shared.getSshDebugLog()
            showingSshDebug = true
        }
        .onChange(of: deepLinkManager.pendingConnection) { connection in
            if let conn = connection {
                // A BBS window already has its board; the link is left for the main instance's kind of window
                if SessionMode.isSession {
                    deepLinkManager.clearPending()
                    return
                }
                let entry = BBSEntry(
                    name: conn.name,
                    host: conn.host,
                    port: conn.port,
                    connectionProtocol: .telnet
                )
                // A window of its own, or here (Options > Separate Window per BBS)
                SessionLauncher.connect(entry)
                deepLinkManager.clearPending()
            }
        }
    }

    /// Leaves the console and connects. The session is remembered so the console comes back with the
    /// right notice when it ends (spec §6).
    private func startConsoleSession(_ entry: BBSEntry) {
        // The board opens in a window of its own and the command line stays where it is (§12.57)
        if SessionLauncher.launchesSessions {
            SessionLauncher.launch(entry)
            return
        }
        console.hide()
        appState.consoleSession = AppState.ConsoleSession(board: entry.name)
        appState.currentView = .terminal(entry)
    }
}

// MARK: - Hidden but laid out

extension View {
    /// WPF's `Visibility.Hidden` (and Windows' `ContentArea.Visibility = Hidden`): the view is not
    /// drawn but still takes up its space, so hiding the app content behind the boot screen or the
    /// screensaver never resizes the window. `.opacity(0)` is not the same thing — SwiftUI still
    /// rasterizes the hierarchy, which is exactly the per-frame card-glow re-render the screensaver
    /// has to stop (spec §8).
    ///
    /// ⚠️ The `if` means the wrapped view's IDENTITY changes when `hidden` flips, so SwiftUI tears the
    /// subtree down and rebuilds it. That is wanted here: while the saver is up the home screen's
    /// ticker and glitch timers stop instead of running under an opaque overlay, and on dismiss the
    /// rebuild replays the decrypt effects, which spec §5 asks for on every return to the home screen.
    /// `HomeWindowFit.didInitialFit` is already set by then, so the rebuild never re-fits the window.
    @ViewBuilder
    func hiddenKeepingLayout(_ hidden: Bool) -> some View {
        if hidden { self.hidden() } else { self }
    }
}

// MARK: - About View

/// About TERMinator (spec §11): the cracktro across the full width, then a panel with
/// `TERMinator - BBS Terminal` / `Version <v>` / `─── Credits ───` / `MOD Tracker Music by Jester of
/// Sanity` and the credits with their clickable links (scrolls only past 360 high),
/// and the two buttons: Open Source Licenses...
/// (left, 170 wide) and OK (right, 90 wide, Enter/Esc). Width 540, height sized to content.
/// The What's New list moved to its own window (`ChangelogWindow`).
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showingLicenses = false

    var body: some View {
        VStack(spacing: 0) {
            // The cracktro (spec §11): starfield, parallax planets, the tumbling 3D splash card,
            // the bouncing logo, the Gradius shooter, the rainbow sine scroller, the water
            // reflection and the rainbow lines. 220 high, across the full width.
            // (There are no copper bars: that layer was removed from all three clients.)
            CracktroView(text: HomeView.originalMarqueeText)
                .frame(height: 220)
                .frame(maxWidth: .infinity)
                .clipped()

            VStack(alignment: .leading, spacing: 0) {
                ScrollView(.vertical) {
                    Text(creditsText)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxHeight: 360) // room for the music credit line without a scrollbar

                // Button bar (matches Windows: Licenses left, OK right)
                HStack {
                    Button("Open Source Licenses...") {
                        showingLicenses = true
                    }
                    .frame(width: 170)

                    Spacer()

                    Button("OK") {
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .frame(width: 90)
                }
                .padding(.top, 12)
            }
            .padding(EdgeInsets(top: 16, leading: 20, bottom: 12, trailing: 20))

            // Esc closes too (OK is the default button).
            Button("") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
        }
        .frame(width: 540)
        .background(Color.surface)
        .onExitCommand { dismiss() }
        // Elysium (Jester of Sanity), played once (spec §12.8). onDisappear fires however the sheet goes
        // away (OK, Esc, the window closing); the Licenses sheet on top of it doesn't count.
        .onAppear { SoundtrackManager.shared.playAboutMusic() }
        .onDisappear { SoundtrackManager.shared.stopAboutMusic() }
        .sheet(isPresented: $showingLicenses) {
            OpenSourceLicensesView()
        }
    }

    /// The credits from `AppInfo.credits`, links clickable (amber, underlined). Colorized like the
    /// console's `about` command: the logo colors on the name, amber header, green credits.
    private var creditsText: AttributedString {
        func piece(_ text: String, _ color: Color, bold: Bool = false) -> AttributedString {
            var piece = AttributedString(text)
            piece.foregroundColor = color
            if bold { piece.font = .system(size: 12, weight: .bold, design: .monospaced) }
            return piece
        }
        var result = piece("TERM", .termLightMagenta, bold: true)
        result.append(piece("inator", .termLightCyan, bold: true))
        result.append(piece(" - BBS Terminal\n", .textPrimary))
        result.append(piece("Version \(AppInfo.version)\n\n", .textSecondary))
        result.append(piece("\u{2500}\u{2500}\u{2500} Credits \u{2500}\u{2500}\u{2500}\n\n", .amberAccent, bold: true))
        result.append(piece("MOD Tracker Music by Jester of Sanity\n\n", .tickerGreen)) // credit for the About music
        for run in AppInfo.credits {
            var part = AttributedString(run.text)
            if let url = run.url {
                part.link = url
                part.foregroundColor = Color.amberAccent
                part.underlineStyle = .single
            } else {
                part.foregroundColor = Color.tickerGreen
            }
            result.append(part)
        }
        return result
    }
}

// MARK: - Open Source Licenses View

struct OpenSourceLicensesView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("Open Source Licenses")
                .font(.system(size: 18, weight: .bold, design: .monospaced))
                .foregroundColor(.termLightGreen)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("TERMinator includes the following open source software:")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.textPrimary)
                        .padding(.bottom, 16)

                    licenseEntry(
                        name: "SyncTERM 1.8b",
                        copyright: "Copyright 2007 Stephen Hurd",
                        license: "GNU GPL v2",
                        url: "syncterm.net",
                        fullURL: "https://syncterm.net"
                    )

                    licenseDivider

                    licenseEntry(
                        name: "cryptlib",
                        copyright: "Copyright 1992-2023 Peter Gutmann",
                        license: "Sleepycat License",
                        url: "cryptlib.com",
                        fullURL: "https://www.cryptlib.com"
                    )

                    licenseDivider

                    licenseEntry(
                        name: "libxmp 4.6.0",
                        copyright: "Copyright 1996-2024 Claudio Matsuoka & Hipolito Carraro Jr",
                        license: "MIT",
                        url: "github.com/libxmp/libxmp",
                        fullURL: "https://github.com/libxmp/libxmp"
                    )
                }
                .padding()
            }
            // Height to content, capped (spec §11) — the same pattern the About box's credits use.
            // With only three dependencies left a fixed 360 was mostly empty space.
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxHeight: 360)

            HStack {
                Spacer()
                Button("OK") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .frame(width: 90)
            }
        }
        .padding(24)
        .frame(width: 640)
        .background(Color.surface)
    }

    private func licenseEntry(name: String, copyright: String, license: String, url: String, fullURL: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundColor(.textPrimary)
            Text(copyright)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.textPrimary)
            Text("License: \(license)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.textPrimary)
            if let linkURL = URL(string: fullURL) {
                Link(url, destination: linkURL)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.amberAccent)
            }
        }
        .padding(.vertical, 8)
    }

    private var licenseDivider: some View {
        Text(String(repeating: "\u{2500}", count: 40))
            .font(.system(size: 12, design: .monospaced))
            .foregroundColor(.textSecondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 4)
    }
}
