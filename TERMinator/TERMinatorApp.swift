import SwiftUI

/// Manages deep link (telnet:// URL) connections
class DeepLinkManager: ObservableObject {
    static let shared = DeepLinkManager()

    @Published var pendingConnection: QuickConnection?

    struct QuickConnection: Identifiable, Equatable {
        let id = UUID()
        let host: String
        let port: Int
        let name: String

        static func == (lhs: QuickConnection, rhs: QuickConnection) -> Bool {
            lhs.id == rhs.id
        }
    }

    /// Parse a telnet:// URL and create a quick connection
    func handleURL(_ url: URL) {
        guard url.scheme == "telnet" else { return }

        let host = url.host ?? ""
        let port = url.port ?? 23

        guard !host.isEmpty else { return }

        pendingConnection = QuickConnection(
            host: host,
            port: port,
            name: "Quick Connect"
        )
    }

    /// Clear the pending connection after handling
    func clearPending() {
        pendingConnection = nil
    }
}

/// Navigation state for the app
enum NavigationDestination: Hashable {
    case home
    case phonebook
    case terminal(BBSEntry)
    case settings
}

/// App-wide state
class AppState: ObservableObject {
    static let shared = AppState()

    /// A BBS session instance (SessionMode, §12.57) has no home screen: it starts on its board's terminal.
    @Published var currentView: NavigationDestination = SessionMode.connection.map { NavigationDestination.terminal($0) } ?? .home
    @Published var connectedEntry: BBSEntry?
    @Published var isConnected: Bool = false
    /// TAP+ overlays are always shown; the menu toggle was removed (Preferences covers switching TAP+ off).
    @Published var showTapPlus: Bool = true
    /// A session transcript is being written (Call > Log Session's check). Set by `TerminalViewModel`.
    @Published var isLogging: Bool = false
    /// The Boss Hide spreadsheet covers the window (bells and key clicks stay quiet meanwhile).
    @Published var bossHideActive: Bool = false
    /// Settings is up over a live session. Windows swaps the screen but keeps the connection and returns to the
    /// terminal after SAVE / CANCEL (`NavigateAfterSettings`); here the terminal view owns its session and a
    /// disconnect runs when it leaves the screen, so Settings covers it instead of replacing it.
    @Published var settingsOverTerminal: Bool = false
    /// The DISCONNECTED / connect-failed overlay is up: Return goes to its OK button (.defaultAction), not the
    /// terminal's performKeyEquivalent (which swallowed it, user 2026-11-06).
    var disconnectOverlayUp: Bool = false

    /// Preferences…: over the terminal while connected, as its own screen otherwise.
    func openSettings() {
        // A BBS window has no screen but its terminal (leaving it would close the window), so always over it
        if SessionMode.isSession {
            settingsOverTerminal = true
        } else if isConnected, case .terminal = currentView {
            settingsOverTerminal = true
        } else {
            currentView = .settings
        }
    }

    /// SAVE / CANCEL: back to the terminal when Settings was opened over one, else home (Windows
    /// `NavigateAfterSettings`).
    func closeSettings() {
        if settingsOverTerminal {
            settingsOverTerminal = false
        } else {
            currentView = .home
        }
    }
    /// The window frame captured when a connection starts (TerminalView.onAppear). Disconnect
    /// restores this exact position AND size, and closing the app mid-session saves it instead
    /// of the terminal's frame, since launch always opens the home screen. Not published: it is
    /// window bookkeeping, not UI state.
    var preConnectFrame: NSRect?

    /// A session started from the command line (spec §6), kept while it runs so the console can be
    /// re-shown with the right notice when it ends. Not published: bookkeeping, not UI state.
    struct ConsoleSession {
        /// The board's name, for the return notice.
        let board: String
        /// The terminal actually appeared. A connect that bails out before it (Windows: a cancelled
        /// SSH password prompt) brings the console back with "connection cancelled" instead.
        var reachedTerminal = false
        /// The connect succeeded, which tells a disconnect from a call that never got through.
        var connected = false
    }

    var consoleSession: ConsoleSession?

    private init() {}
}

class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set once the power-off has played, so the real termination goes straight through.
    private var poweredOffForClose = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    /// Closing the app plays the old-tube power-off first (spec §7, Windows' `OnClosing`): cancel this
    /// termination, run the effect, then reply for real. Only while the window is actually visible and
    /// not minimized — quitting with the window already closed or minimized just quits, so nothing
    /// hangs on an effect nobody can see.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Main instance with BBS windows still open: ask once, then close them all with it (§12.57)
        guard SessionLauncher.confirmCloseIfNeeded() else { return .terminateCancel }
        // A BBS window quitting (its own ⌘Q, or the main instance closing it): no Disconnected dialog from here on
        if SessionMode.isSession {
            SessionMode.closing = true
        }

        guard !poweredOffForClose,
              let window = WindowSizeManager.mainWindow,
              window.isVisible,
              !window.isMiniaturized else { return .terminateNow }

        poweredOffForClose = true
        CrtPowerModel.shared.powerOff {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // TRACE: what a door's TRACE;Query is told (nothing while it's switched off in Preferences)
        TraceSessionManager.shared.applySettings()
        TraceModules.logHostAtLaunch()

        // One window per BBS (§12.57): a session closes with its main instance; the main instance's window asks
        // before closing over open BBS windows
        SessionMode.watchParent()

        // The board's OSC 777 notifications (12.72): clicks bring the BBS window that posted one to front
        BoardNotifier.install()

        // A board's linked windows (12.73): the caller's keys and clicks on the call allow an Open; a linked window
        // comes forward when its opener says so
        LinkedWindows.install()

        // Style the title bar to match the retro dark theme (BackgroundMedium #1A1A2E)
        DispatchQueue.main.async {
            if let window = NSApp.keyWindow ?? NSApp.windows.first {
                window.titlebarAppearsTransparent = true
                window.backgroundColor = NSColor(red: 0x1A/255.0, green: 0x1A/255.0, blue: 0x2E/255.0, alpha: 1.0)
                // The screensaver's idle timer watches mouse movement, which a window only reports
                // when it is asked to (`IdleWatcher` sets this too, in case this runs first).
                window.acceptsMouseMovedEvents = true
                // A BBS window isn't brought back by state restoration: it belongs to the main instance's launch
                if SessionMode.isSession {
                    window.isRestorable = false
                }
            }
            SessionLauncher.installMainWindowHooks()
        }
    }
}

@main
struct TERMinatorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var deepLinkManager = DeepLinkManager.shared
    @StateObject private var appState = AppState.shared

    init() {
        // Settings defaults + the first-run rule (side-by-side on a fresh install), before
        // anything else touches UserDefaults.
        AppPreferences.registerDefaults()
        TraceModules.migrateCacheDefault()

        // The console's "uptime" counts from here.
        AppLaunch.markStart()

        // Initialize native bridge
        let filesDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].path
        NativeBridge.shared.setFilesDir(filesDir)

        // Restore window size on next run cycle
        // (a BBS window opens where that board's window was last left, else cascaded from the main window)
        DispatchQueue.main.async {
            if SessionMode.isSession {
                SessionMode.restoreWindow()
            } else {
                WindowSizeManager.restoreWindowSize()
            }
        }

        // Save window size on quit, and close a call still in progress in the call log (the session's views don't
        // get onDisappear at termination; the native byte counters are still readable here). No call open = no-op.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { _ in
            // A BBS window remembers its own place, for the next time that board is opened, and leaves the main
            // window's alone; and it hangs up
            if SessionMode.isSession {
                SessionMode.saveWindow()
                SessionMode.hangUpForQuit()
                return
            }
            WindowSizeManager.saveWindowSize()
            let stats = NativeBridge.shared.getConnectionStats()
            CallStatsService.shared.endCall(bytesSent: stats?.bytesSent ?? 0, bytesReceived: stats?.bytesReceived ?? 0)
        }

        // Track the window's normal frame so the saved bounds are the restored ones even
        // when the app quits zoomed or full screen.
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
                if let window = note.object as? NSWindow {
                    WindowSizeManager.noteFrameChanged(window)
                }
            }
        }
    }

    // View menu checks, bound straight to UserDefaults (see AppPreferences): restoring them
    // at startup is just reading the stored value, so nothing gets re-saved.
    @AppStorage(AppPreferences.homeSideBySide) private var homeSideBySide = false
    @AppStorage(AppPreferences.showBootSequence) private var showBootSequence = true
    @AppStorage(AppPreferences.screensaverEnabled) private var screensaverEnabled = true
    @AppStorage(AppPreferences.phosphor) private var phosphor = PhosphorMode.color.rawValue
    @AppStorage(AppPreferences.emulatedBaud) private var emulatedBaud = 0
    @AppStorage(AppPreferences.showModemLights) private var showModemLights = true
    @AppStorage(AppPreferences.keyClicksEnabled) private var keyClicksEnabled = false
    @AppStorage(AppPreferences.zmodem8k) private var zmodem8k = false
    @AppStorage(AppPreferences.multiWindow) private var multiWindow = true
    @AppStorage(AppPreferences.linkedWindows) private var linkedWindows = true

    /// A BBS window (SessionMode): the menus have no home-screen items.
    private let isSession = SessionMode.isSession
    /// A board's linked window (12.73): no login to send, no phonebook entry to snapshot for, and View > Always on Top.
    private let isLinked = SessionMode.isLinked
    /// View > Always on Top in a linked window, as it was left for this one ("<parentId>-<kind>").
    @State private var alwaysOnTop = SessionMode.link.map { LinkedWindows.isOnTop($0.id) } ?? false

    /// The terminal needs a narrower floor: an 80x50 board draws at 2:3, so on a laptop-height
    /// screen the fitted window is well under 800pt wide and an 800 minimum padded it out with
    /// dead space left and right. The home screen scales its layout to any size and its aspect
    /// lock has to be able to win at small sizes, so it gets the lowest floor of all.
    private var minWindowWidth: CGFloat {
        if appState.currentView == .home { return 400 }
        return appState.isConnected ? 480 : 800
    }

    private var minWindowHeight: CGFloat {
        appState.currentView == .home ? 300 : 600
    }

    var body: some Scene {
        // "<BBS> - TERMinator" in a BBS window
        WindowGroup(SessionMode.windowTitle) {
            ContentView()
                .environmentObject(deepLinkManager)
                .environmentObject(appState)
                .onOpenURL { url in
                    deepLinkManager.handleURL(url)
                }
                .frame(minWidth: minWindowWidth, minHeight: minWindowHeight)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1024, height: 768)
        .commands {
            // Menu layout (all three desktop clients): File · Edit · Call · Transfer · View · Options · Help.
            // File: the phonebook and saving output. Call: the current connection. View: what's on screen now.
            // Options: preferences that stick (every one is also in Preferences, which lives in the app menu here,
            // as does Quit). Import / export are here as on Windows; Preferences > Backup & Restore runs the same flows.

            // File Menu
            CommandGroup(replacing: .newItem) {
                // Home-screen items: not in a BBS window
                if !isSession {
                    Button("Phonebook") {
                        appState.currentView = .phonebook
                    }
                    .keyboardShortcut("p")

                    Divider()

                    // Windows File > Import Phonebook... / Export Phonebook... (no shortcuts there either).
                    Button("Import Phonebook...") {
                        ImportExportManager.shared.runImportFlow()
                    }

                    Button("Export Phonebook...") {
                        ImportExportManager.shared.runExportFlow()
                    }

                    Divider()
                }

                Button("Save Screenshot...") {
                    NotificationCenter.default.post(name: .captureScreenshot, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!appState.isConnected)

                if !isLinked {
                    Button("Take BBS Snapshot") {
                        NotificationCenter.default.post(name: .saveSnapshot, object: nil)
                    }
                    .disabled(!appState.isConnected)
                }
            }

            // Edit Menu - keep defaults (Copy, Paste, Select All)

            // Call Menu: the current connection. Disconnect keeps ⌘D here (Windows/Linux use Alt+H; on a Mac,
            // Option+letter types characters).
            CommandMenu("Call") {
                Button("Disconnect") {
                    if appState.isConnected {
                        NativeBridge.shared.disconnect()
                        appState.isConnected = false
                        appState.connectedEntry = nil
                        appState.currentView = .home
                    }
                }
                .keyboardShortcut("d")
                .disabled(!appState.isConnected)

                if !isLinked {
                    Button("Send Login") {
                        NotificationCenter.default.post(name: .sendLoginRequested, object: nil)
                    }
                    .keyboardShortcut("i", modifiers: [.option])
                    .disabled(!appState.isConnected || appState.connectedEntry == nil
                        || (appState.connectedEntry?.username.isEmpty ?? true)
                        || !(appState.connectedEntry?.hasPassword ?? false))
                }

                Divider()

                // One checked speed. Preferences and the console's "baud" write the same key; ContentView pushes
                // it to the native bridge whenever it changes, mid-session included.
                Menu("Modem Speed") {
                    Picker("Modem Speed", selection: $emulatedBaud) {
                        ForEach(ModemSpeeds.rates, id: \.self) { bps in
                            Text(ModemSpeeds.label(bps)).tag(bps)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                // Checked while a transcript is being written, however logging was started
                Toggle("Log Session", isOn: Binding(
                    get: { appState.isLogging },
                    set: { _ in NotificationCenter.default.post(name: .toggleLogging, object: nil) }
                ))
                .disabled(!appState.isConnected)

                Divider()

                Button("Show SSH Debug Log") {
                    NotificationCenter.default.post(name: .showSshDebugLog, object: nil)
                }
            }

            // Transfer Menu
            CommandMenu("Transfer") {
                Button("Send File...") {
                    NotificationCenter.default.post(name: .sendFileRequested, object: nil)
                }
                .keyboardShortcut("u")
                .disabled(!appState.isConnected)

                Button("Receive File") {
                    NotificationCenter.default.post(name: .receiveFileRequested, object: nil)
                }
                .disabled(!appState.isConnected)

                // "Super ZMODEM 8K": uploads grow to 8K subpackets. Downloads take
                // whatever size the BBS sends, so this only affects sending. Not
                // tied to a connection -- it is set before the transfer starts.
                Toggle("ZMODEM 8K Blocks", isOn: $zmodem8k)

                Divider()

                // X/YMODEM. Nothing here auto-detects the way ZMODEM does: start
                // the transfer on the BBS first, then pick the SAME protocol here.
                //
                // ⚠️ There is deliberately no "-G" item on the SEND side.
                // xmodem_get_mode() lets the RECEIVER choose checksum / CRC / -g,
                // so the flag would do nothing on a send.
                Menu("Send File via") {
                    // 128-byte FIRST, deliberately: the 8-bit boards this feature
                    // exists for usually speak only 128-byte SOH blocks, and
                    // xmodem_send_file() only falls back from 1K after 3 failed
                    // blocks. The safer choice is the one that reads first.
                    Button("XMODEM (128-byte blocks)...") {
                        postXmodem(.xmodemSendRequested,
                                   mode: NativeBridge.XferMode.xmodem | NativeBridge.XferMode.crc
                                       | NativeBridge.XferMode.xmodem128B,
                                   name: "XMODEM")
                    }
                    Button("XMODEM (1K blocks)...") {
                        postXmodem(.xmodemSendRequested,
                                   mode: NativeBridge.XferMode.xmodem | NativeBridge.XferMode.crc,
                                   name: "XMODEM")
                    }

                    Divider()

                    Button("YMODEM...") {
                        postXmodem(.xmodemSendRequested,
                                   mode: NativeBridge.XferMode.ymodem | NativeBridge.XferMode.crc,
                                   name: "YMODEM")
                    }
                }
                .disabled(!appState.isConnected)

                // 1K vs 128 is a SEND-side choice only — a receiver just reads
                // whatever SOH/STX arrives — so the receive menu has one XMODEM.
                Menu("Receive File via") {
                    Button("XMODEM...") {
                        postXmodem(.xmodemReceiveRequested,
                                   mode: NativeBridge.XferMode.xmodem | NativeBridge.XferMode.crc,
                                   name: "XMODEM")
                    }

                    Divider()

                    Button("YMODEM") {
                        postXmodem(.xmodemReceiveRequested,
                                   mode: NativeBridge.XferMode.ymodem | NativeBridge.XferMode.crc,
                                   name: "YMODEM")
                    }
                    Button("YMODEM-G") {
                        postXmodem(.xmodemReceiveRequested,
                                   mode: NativeBridge.XferMode.ymodem | NativeBridge.XferMode.crc
                                       | NativeBridge.XferMode.gMode,
                                   name: "YMODEM-G")
                    }
                }
                .disabled(!appState.isConnected)
            }

            // View Menu (Windows order: Full Screen · Boss Hide | Command Line Mode · Side-by-Side Home Screen |
            // Phosphor ▸ · CRT / Scanline Effect… | Modem Lights)
            CommandMenu("View") {
                Button("Full Screen") {
                    NSApp.keyWindow?.toggleFullScreen(nil)
                }
                .keyboardShortcut(.return, modifiers: [.command, .option])

                // ⌃⇧B (or F15, where a Mac keyboard has one) is caught by ContentView's key monitor before the
                // terminal sees it; the shortcut here advertises it. Any key brings TERMinator back.
                Button("Boss Hide") {
                    NotificationCenter.default.post(name: .toggleBossHide, object: nil)
                }
                .keyboardShortcut("b", modifiers: [.control, .shift])

                // Back to the live screen if scrolled back, else half a screen up into history. ⌃B in the terminal
                // (TerminalKeyboardView) does the same and reaches it first; the shortcut here advertises it.
                Button("Scrollback") {
                    NotificationCenter.default.post(name: .toggleScrollback, object: nil)
                }
                .keyboardShortcut("b", modifiers: [.control])
                .disabled(!appState.isConnected)

                // A board's linked window (12.73) can stay above the others, remembered per linked window
                if isLinked {
                    Toggle("Always on Top", isOn: Binding(
                        get: { alwaysOnTop },
                        set: { on in
                            alwaysOnTop = on
                            LinkedWindows.setOnTop(on)
                        }
                    ))
                }

                // Home-screen items: not in a BBS window
                if !isSession {
                    Divider()

                    // ContentView shows the Elite confirmation, then the console. Never disabled — it
                    // just does nothing away from the home screen.
                    Button("Command Line Mode") {
                        NotificationCenter.default.post(name: .showCommandLine, object: nil)
                    }

                    // HomeView observes the same value: the LAYOUT tile flips it too.
                    Toggle("Side-by-Side Home Screen", isOn: $homeSideBySide)
                }

                Divider()

                // Exactly one checked. The console's "phosphor" writes the same key, and the tint
                // itself (home screen + command line) reads it (`ScreenEffectModifier`).
                Menu("Phosphor") {
                    Picker("Phosphor", selection: $phosphor) {
                        ForEach(PhosphorMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Button("CRT / Scanline Effect...") {
                    NotificationCenter.default.post(name: .showCrtSettings, object: nil)
                }

                // NOTE: no Zoom In / Zoom Out / Actual Size here. They existed until
                // 2026-09-12 and did NOTHING: the zoom level was stored, clamped and even
                // persisted to the phonebook, but no render path ever read it. Windows and
                // Linux have no zoom either. If terminal zoom is ever wanted it has to be
                // built for real in the renderer first — do not re-add the menu items alone.

                Divider()

                // The terminal status bar's modem front-panel lights
                Toggle("Modem Lights", isOn: $showModemLights)
            }

            // Options Menu: preferences that stick
            CommandMenu("Options") {
                if !isSession {
                    // ContentView reads this at launch and shows the boot screen (BootSequenceView).
                    Toggle("Boot Sequence on Startup", isOn: $showBootSequence)

                    // The idle screensaver reads this (`IdleWatcher`); ContentView restarts the idle
                    // countdown whenever it is switched back on.
                    Toggle("Screensaver", isOn: $screensaverEnabled)
                }

                Toggle("Model M Key Clicks", isOn: $keyClicksEnabled)

                // Each connection in a window (and an instance) of its own (§12.57). Applies from the next
                // connection; a call already running stays where it is. Not in a BBS window.
                if !isSession {
                    Toggle("Separate Window per BBS", isOn: $multiWindow)
                }

                // mw=1 in the Rainwire:Caps answer: a board may open a linked window onto the call (12.73). Applies
                // from the next connection.
                Toggle("Let Boards Open Extra Windows", isOn: $linkedWindows)
            }

            // Preferences (app menu)
            CommandGroup(replacing: .appSettings) {
                Button("Preferences...") {
                    appState.openSettings()
                }
                .keyboardShortcut(",")
            }

            // Help Menu
            CommandGroup(replacing: .help) {
                Button("TERMinator Help") {
                    NotificationCenter.default.post(name: .showHelp, object: nil)
                }
                .keyboardShortcut("?")

                // Manual only, as on Windows (Help, after Changelog there; Changelog is in the app menu here).
                // Main window only: installing quits every TERMinator window.
                if !isSession {
                    Button("Check for Updates") {
                        NotificationCenter.default.post(name: .showUpdates, object: nil)
                    }
                }
            }

            // Application menu: About TERMinator with Changelog directly next to it (Windows
            // keeps both under Help; on macOS they belong in the app menu).
            CommandGroup(replacing: .appInfo) {
                Button("About TERMinator") {
                    NotificationCenter.default.post(name: .showAbout, object: nil)
                }

                Button("Changelog") {
                    NotificationCenter.default.post(name: .showChangelog, object: nil)
                }
            }
        }
    }
}

// MARK: - Window Size Persistence

/// Remembers the window's position (monitor included) and shape.
///
/// Save on close: the window's *normal* (restored) bounds, even if it is zoomed or full screen,
/// plus the zoomed flag. Closing mid-session saves the pre-connect (home screen) bounds instead,
/// since launch always opens home. Restore on launch: the saved frame is in global screen
/// coordinates, so it lands on the same monitor; a monitor that is gone falls back to a visible
/// one. No saved bounds → the window is fitted to the home layout (`HomeWindowFit`).
enum WindowSizeManager {
    static let widthKey = "window_width"
    private static let heightKey = "window_height"
    private static let xKey = "window_x"
    private static let yKey = "window_y"
    /// macOS "maximized" = zoomed. Full screen is saved as a normal window.
    private static let zoomedKey = "window_zoomed"

    /// The last normal (not zoomed, not full screen) frame, tracked live from the window
    /// notifications so the normal bounds are known even while the window is zoomed or full
    /// screen at quit.
    static var lastNormalFrame: NSRect?

    /// The terminal window, never the CRT panel — `keyWindow ?? windows.first` will
    /// happily hand back the CRT panel if it is frontmost, which then saves that
    /// panel's frame as the app's window size (and stretches it on the next launch).
    static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.title.hasPrefix("TERMinator") || $0.title == SessionMode.windowTitle
            || $0.title == BossHideView.fakeTitle
            // a linked window's title follows the board (12.73): the old one is still up while the new one is set
            || (SessionMode.isLinked && $0.title.hasSuffix(" - TERMinator")) }
            ?? NSApp.windows.first { $0.title != "CRT & Scanline Effects" && $0.title != "Changelog" }
    }

    /// True once a window frame has ever been saved: a first run has none.
    static var hasSavedBounds: Bool {
        UserDefaults.standard.object(forKey: widthKey) != nil
    }

    static func isNormal(_ window: NSWindow) -> Bool {
        !window.styleMask.contains(.fullScreen) && !window.isZoomed && !window.isMiniaturized
    }

    static func noteFrameChanged(_ window: NSWindow) {
        guard window === mainWindow, isNormal(window) else { return }
        lastNormalFrame = window.frame
    }

    static func saveWindowSize() {
        guard let window = mainWindow else { return }

        let frame: NSRect
        if let preConnect = AppState.shared.preConnectFrame, preConnect.width > 0, preConnect.height > 0 {
            // Mid-session: the home screen's bounds, not the terminal's.
            frame = preConnect
        } else if isNormal(window) {
            frame = window.frame
        } else {
            frame = lastNormalFrame ?? window.frame
        }

        let defaults = UserDefaults.standard
        defaults.set(Double(frame.width), forKey: widthKey)
        defaults.set(Double(frame.height), forKey: heightKey)
        defaults.set(Double(frame.origin.x), forKey: xKey)
        defaults.set(Double(frame.origin.y), forKey: yKey)
        defaults.set(window.isZoomed && !window.styleMask.contains(.fullScreen), forKey: zoomedKey)
    }

    static func restoreWindowSize() {
        let width = UserDefaults.standard.double(forKey: widthKey)
        let height = UserDefaults.standard.double(forKey: heightKey)
        // Only restore something plausible. The floor is low on purpose: the home screen
        // scales to small windows now, so a saved 500-wide window is legitimate.
        guard width >= 200, height >= 150 else { return }

        guard let window = mainWindow else { return }
        let x = UserDefaults.standard.double(forKey: xKey)
        let y = UserDefaults.standard.double(forKey: yKey)

        place(window, frame: NSRect(x: x, y: y, width: width, height: height))

        if UserDefaults.standard.bool(forKey: zoomedKey), !window.isZoomed {
            window.zoom(nil)
        }
    }

    /// Puts the window at `frame` (global screen coordinates) on the monitor it was on, clamped inside that monitor's
    /// work area. Also a BBS window's remembered or cascaded frame (SessionMode.restoreWindow).
    static func place(_ window: NSWindow, frame requested: NSRect) {
        var frame = requested

        // The monitor the window was on: the screen holding the frame's center, else the one
        // it overlaps most, else the main screen. Then clamp inside that screen's work area so
        // the window is never off-screen or larger than the display (settings saved on a
        // bigger external display).
        let center = NSPoint(x: frame.midX, y: frame.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(center) }
            ?? NSScreen.screens.max { overlapArea($0.visibleFrame, frame) < overlapArea($1.visibleFrame, frame) }
                .flatMap { overlapArea($0.visibleFrame, frame) > 0 ? $0 : nil }
            ?? NSScreen.main
        if let screen = screen {
            let work = screen.visibleFrame
            frame.size.width = min(frame.width, work.width)
            frame.size.height = min(frame.height, work.height)
            frame.origin.x = min(max(frame.origin.x, work.minX), max(work.minX, work.maxX - frame.width))
            frame.origin.y = min(max(frame.origin.y, work.minY), max(work.minY, work.maxY - frame.height))
        }

        window.setFrame(frame, display: true)
        lastNormalFrame = frame
    }

    private static func overlapArea(_ a: NSRect, _ b: NSRect) -> CGFloat {
        let r = a.intersection(b)
        return r.isNull || r.isEmpty ? 0 : r.width * r.height
    }
}

// MARK: - Home screen window fit

/// Home screen window behavior (spec §2): the window is fitted to the home layout (content +
/// margins + chrome, capped to the work area of the monitor it is on) on a first run and
/// whenever the layout is toggled, then handed back to normal manual resizing; while it is
/// on the home screen a drag resize keeps the content area at the layout's aspect ratio
/// (`NSWindow.contentAspectRatio`, each layout has its own). Not applied when zoomed or full
/// screen, and the terminal's own aspect sizing takes over on connect.
enum HomeWindowFit {
    private static var didInitialFit = false

    /// HomeView.onAppear: first run → fit; otherwise just lock the aspect ratio.
    static func homeDidAppear(sideBySide: Bool) {
        if !didInitialFit {
            didInitialFit = true
            if !WindowSizeManager.hasSavedBounds {
                fitToLayout(sideBySide: sideBySide)
                return
            }
            // The saved frame needn't have the layout's shape (a different layout, or saved before the lock):
            // contentAspectRatio only bites on a drag, so without this the window opened at the wrong aspect and
            // snapped to it the moment the user started resizing
            applyAspectLock(sideBySide: sideBySide)
            conformToAspect(sideBySide: sideBySide)
            return
        }
        applyAspectLock(sideBySide: sideBySide)
    }

    /// Reshape the window's content to the layout's aspect ratio, keeping its width (shrinking both if the height
    /// won't fit the work area) and its top edge where it was. A zoomed / full screen window is left alone.
    static func conformToAspect(sideBySide: Bool) {
        guard let window = WindowSizeManager.mainWindow,
              !window.styleMask.contains(.fullScreen), !window.isZoomed,
              let screen = window.screen ?? NSScreen.main else { return }
        let natural = HomeMetrics.naturalSize(sideBySide: sideBySide)
        guard natural.width > 0, natural.height > 0 else { return }

        let frame = window.frame
        let content = window.contentRect(forFrameRect: frame)
        let chromeW = max(0, frame.width - content.width)
        let chromeH = max(0, frame.height - content.height)
        let work = screen.visibleFrame

        var contentW = content.width
        var contentH = (contentW * natural.height / natural.width).rounded()
        let maxContentH = max(1, work.height - chromeH)
        if contentH > maxContentH {
            contentH = maxContentH
            contentW = (contentH * natural.width / natural.height).rounded()
        }
        guard contentW > 0, contentH > 0, abs(contentH - content.height) >= 1 || abs(contentW - content.width) >= 1
        else { return }

        let size = NSSize(width: contentW + chromeW, height: contentH + chromeH)
        var origin = NSPoint(x: frame.minX, y: frame.maxY - size.height)   // keep the top edge
        origin.x = min(max(origin.x, work.minX), max(work.minX, work.maxX - size.width))
        origin.y = min(max(origin.y, work.minY), max(work.minY, work.maxY - size.height))
        window.setFrame(NSRect(origin: origin, size: size), display: true, animate: false)
        WindowSizeManager.noteFrameChanged(window)
    }

    static func applyAspectLock(sideBySide: Bool) {
        guard let window = WindowSizeManager.mainWindow,
              !window.styleMask.contains(.fullScreen) else { return }
        let natural = HomeMetrics.naturalSize(sideBySide: sideBySide)
        guard natural.width > 0, natural.height > 0 else { return }
        window.contentAspectRatio = NSSize(width: natural.width, height: natural.height)
    }

    /// HomeView.onDisappear: release the lock so the phonebook / settings resize freely.
    /// ⚠️ Not `contentAspectRatio = .zero` — see TerminalView.onDisappear for the crash that
    /// caused; setting the resize increments is the documented way to clear the aspect lock.
    static func releaseAspectLock() {
        guard let window = WindowSizeManager.mainWindow else { return }
        window.resizeIncrements = NSSize(width: 1, height: 1)
        window.contentResizeIncrements = NSSize(width: 1, height: 1)
    }

    /// Size the window to the layout's natural size (shrink-only against the work area of the
    /// monitor the window is on — the home view scales down if it still doesn't fit), keeping
    /// it centered where it was and clamped inside the work area. A zoomed / full screen
    /// window is left alone. Overlays never contribute: the size comes from `HomeMetrics`.
    static func fitToLayout(sideBySide: Bool) {
        guard let window = WindowSizeManager.mainWindow else { return }
        guard AppState.shared.currentView == .home else { return }
        if window.styleMask.contains(.fullScreen) || window.isZoomed {
            applyAspectLock(sideBySide: sideBySide)
            return
        }
        guard let screen = window.screen ?? NSScreen.main else { return }

        let work = screen.visibleFrame
        let natural = HomeMetrics.naturalSize(sideBySide: sideBySide)
        guard natural.width > 0, natural.height > 0 else { return }

        let frame = window.frame
        let contentRect = window.contentRect(forFrameRect: frame)
        let chromeW = max(0, frame.width - contentRect.width)
        let chromeH = max(0, frame.height - contentRect.height)

        // Measure at natural size, shrink only.
        let maxContentW = max(1, work.width - chromeW)
        let maxContentH = max(1, work.height - chromeH)
        let scale = min(1, maxContentW / natural.width, maxContentH / natural.height)
        let contentW = (natural.width * scale).rounded()
        let contentH = (natural.height * scale).rounded()
        let newSize = NSSize(width: contentW + chromeW, height: contentH + chromeH)
        guard newSize.width > 0, newSize.height > 0, newSize.width.isFinite, newSize.height.isFinite else { return }

        var origin = NSPoint(x: frame.midX - newSize.width / 2, y: frame.midY - newSize.height / 2)
        origin.x = min(max(origin.x, work.minX), max(work.minX, work.maxX - newSize.width))
        origin.y = min(max(origin.y, work.minY), max(work.minY, work.maxY - newSize.height))

        window.contentAspectRatio = NSSize(width: natural.width, height: natural.height)
        window.setFrame(NSRect(origin: origin, size: newSize), display: true, animate: false)
        WindowSizeManager.noteFrameChanged(window)
    }
}

// MARK: - Notification Names

// MARK: - CRT Settings Window

/// The CRT panel as a plain AppKit window rather than a SwiftUI `Window` scene.
///
/// ⚠️ A `Window` scene declared alongside the main `WindowGroup` is auto-opened at
/// launch and TAKES the launch window — the app came up showing only the CRT panel
/// with no terminal behind it, and declaration order makes no difference. The
/// SwiftUI cure is `.defaultLaunchBehavior(.suppressed)`, which is macOS 15+; this
/// app deploys to 14.0, so the panel is built by hand and opened on demand instead.
///
/// A separate window rather than a sheet: it is resizable, and being modeless it
/// leaves the terminal running behind it so the look can be dialed in against live
/// ANSI art. Matches the Windows dialog.
enum CrtSettingsWindow {
    private static var controller: NSWindowController?

    static func show() {
        if let controller {
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            return
        }

        // Never open taller/wider than the display will actually show. On a small
        // screen the stock 620x600 would push RESET/DONE off the bottom edge.
        let visible = (NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)).size
        let size = NSSize(width: min(620, visible.width - 40),
                          height: min(600, visible.height - 40))

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "CRT & Scanline Effects"
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(red: 0x1A/255.0, green: 0x1A/255.0, blue: 0x2E/255.0, alpha: 1.0)
        window.isReleasedWhenClosed = false   // the controller outlives each close

        // ⚠️ This panel is the one window that is NOT inside ContentView, so it does
        // not inherit ContentView's `.preferredColorScheme(.dark)`. Without this the
        // panel keeps the system appearance while still painting its own hardcoded
        // dark background — so on a Light Mode Mac the AppKit-drawn controls (the
        // "Enable CRT effect" checkbox and its label, the Preset picker, RESET/DONE)
        // render dark-on-dark and are effectively invisible. A user then cannot turn
        // the effect on, which also leaves every slider `.disabled` and dimmed, so
        // the whole panel looks broken. Reported from the field 2026-09-07.
        window.appearance = NSAppearance(named: .darkAqua)

        window.contentView = NSHostingView(
            rootView: CrtSettingsView(onDone: { close() }).preferredColorScheme(.dark)
        )
        // Match the SwiftUI content's own minimum so the window can never be sized
        // smaller than the layout it hosts.
        window.contentMinSize = NSSize(width: 500, height: 340)
        window.center()
        // Excluded from the main-window frame persistence below by title prefix.
        let controller = NSWindowController(window: window)
        self.controller = controller
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    static func close() {
        controller?.window?.close()
    }
}

/// Post an X/YMODEM menu request. `mode` is a `NativeBridge.XferMode` bit set;
/// `name` is the label the transfer window shows ("XMODEM", "YMODEM-G", ...).
private func postXmodem(_ notification: Notification.Name, mode: Int, name: String) {
    NotificationCenter.default.post(name: notification, object: nil,
                                    userInfo: ["mode": mode, "protocolName": name])
}

extension Notification.Name {
    static let sendFileRequested = Notification.Name("sendFileRequested")
    static let receiveFileRequested = Notification.Name("receiveFileRequested")
    /// userInfo: ["mode": Int (NativeBridge.XferMode bits), "protocolName": String]
    static let xmodemSendRequested = Notification.Name("xmodemSendRequested")
    static let xmodemReceiveRequested = Notification.Name("xmodemReceiveRequested")
    static let toggleLogging = Notification.Name("toggleLogging")
    static let showAbout = Notification.Name("showAbout")
    static let showChangelog = Notification.Name("showChangelog")
    /// Help > Check for Updates (main instance only)
    static let showUpdates = Notification.Name("showUpdates")
    /// View > Command Line Mode and the COMMAND shortcut tile: ContentView shows the Elite
    /// confirmation, then the console (home screen only). `userInfo["skipConfirmation"] = true`
    /// (the boot prompt's "C") goes straight in.
    static let showCommandLine = Notification.Name("showCommandLine")
    static let showHelp = Notification.Name("showHelp")
    static let showSshDebugLog = Notification.Name("showSshDebugLog")
    static let showCrtSettings = Notification.Name("showCrtSettings")
    static let captureScreenshot = Notification.Name("captureScreenshot")
    static let saveSnapshot = Notification.Name("saveSnapshot")
    static let sendLoginRequested = Notification.Name("sendLoginRequested")
    /// View > Boss Hide: ContentView puts the spreadsheet up or takes it down.
    static let toggleBossHide = Notification.Name("toggleBossHide")
    /// View > Scrollback: TerminalView toggles scrollback (with a notice).
    static let toggleScrollback = Notification.Name("toggleScrollback")
    /// Preferences > Display > Screensaver TEST: ContentView plays the screensaver now.
    static let startScreensaver = Notification.Name("startScreensaver")
}
