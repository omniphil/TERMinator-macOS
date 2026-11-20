import AppKit
import SwiftUI
import os.log

private let linkLogger = Logger(subsystem: "com.terminator.macos", category: "Link")

// MARK: - One window per BBS (Windows 1.1.4, PORT_TO_MAC_LINUX.md §12.57)
//
// Every BBS opens in a window, and a PROCESS, of its own: the terminal engine (the SyncTERM C in Bridge/) holds
// exactly one session per process (globals everywhere), so a process per board is the whole of the isolation, and a
// crash in one board can't take the others or the phonebook with it. The main instance keeps the home screen and the
// phonebook and never turns into a terminal; for each board it starts a new instance of this same app with
//     --session <base64 JSON of the BBSEntry> --parent <pid> --cascade <left>,<top>,<right>,<bottom> --handoff <token>
// (NSWorkspace, createsNewApplicationInstance). A session instance connects as it opens and quits when its call ends.
//
// Differences from Windows, all forced by macOS:
//  - Each instance has a Dock icon of its own (every one is "TERMinator").
//  - Windows' named event (sessions wait on it) is a distributed notification here, with a watch on the main
//    instance as a fallback: if the main instance goes away, its sessions go with it.
//  - The same connection is also left in a handoff file (Application Support/TERMinator/session-launch/<token>.json),
//    in case launch arguments don't reach an instance started from inside the App Sandbox.
//  - --cascade is in Cocoa screen points (y grows upwards): top is the frame's maxY, bottom its minY.
//
// A board's linked window (12.73, LinkedWindows below) is one more session instance, started with --link as well.

/// This instance as a BBS session (launched with --session), or nil for the main instance.
enum SessionMode {
    struct Launch {
        let entry: BBSEntry
        let parentPid: pid_t
        /// Where to open when this board has no remembered window: the main window's frame, stepped down and right.
        let cascade: NSRect?
        /// A board's linked window (12.73), or nil for an ordinary BBS window.
        var link: LinkLaunch? = nil
    }

    /// What makes a session a board's linked window (12.73, Rainwire docs/MRC_WINDOW.md): the board's single-use
    /// token for its own connection's Caps answer, the kind of window it is, the board's name for its title, and the
    /// opener's entry id, so "<parentId>-<kind>" remembers its own place and Always on Top.
    struct LinkLaunch: Codable {
        var token: String
        var kind: String
        var board: String
        var parentId: String
        /// focus=0: open without taking the focus
        var noActivate: Bool

        /// "<parentId>-<kind>" (Windows' linked SavedConnection.Id)
        var id: String { "\(parentId)-\(kind)" }
    }

    /// Read once, at the first use (TERMinatorApp.init): the arguments, else a handoff file left for this instance.
    static let launch: Launch? = SessionLaunchArguments.read()

    static var isSession: Bool { launch != nil }

    static var connection: BBSEntry? { launch?.entry }

    /// This instance is a board's linked window (12.73): part of its opener's call, not a call of its own.
    static var link: LinkLaunch? { launch?.link }

    static var isLinked: Bool { link != nil }

    /// Closing (quitting): the end of the call shows no Disconnected dialog and nothing reopens.
    static var closing = false

    /// "<BBS> - TERMinator" for a session, the usual title for the main window. The board's OSC 0/2 title is not shown,
    /// except in a linked window (12.73): "<board> — <board's title> - TERMinator", or its Open title until the board
    /// sets one.
    static var windowTitle: String {
        guard let entry = connection else { return "TERMinator v\(AppInfo.version)" }
        if let link, let boardTitle = BoardTitle.current, !boardTitle.isEmpty,
           !link.board.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "\(link.board) — \(boardTitle) - TERMinator"
        }
        let name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(name.isEmpty ? entry.host : name) - TERMinator"
    }

    /// Where the main window would go home (disconnect, failed connect, cancel), a session quits instead.
    static func close() {
        guard isSession, !closing else { return }
        closing = true
        DispatchQueue.main.async {
            NSApp.terminate(nil)
        }
    }

    /// Session, at launch: close when the main instance says so (it asked the user first), or when it's gone.
    static func watchParent() {
        guard let launch = Self.launch else { return }
        let parent = launch.parentPid
        DistributedNotificationCenter.default().addObserver(forName: SessionLauncher.closeSessionsNotification,
                                                            object: String(parent), queue: .main) { _ in
            SessionMode.close()
        }
        guard parent > 0 else { return }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                                          object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if app?.processIdentifier == parent {
                SessionMode.close()
            }
        }
        // Started after the main instance already went (it can't be told any more)
        if NSRunningApplication(processIdentifier: parent) == nil {
            SessionMode.close()
        }
    }

    // MARK: Window placement

    /// A linked window remembers its place by "<parentId>-<kind>" (12.73), every other BBS window by its entry.
    private static func frameKey(_ entry: BBSEntry) -> String {
        "session_window_frame_\(link?.id ?? entry.id.uuidString)"
    }

    /// Session: the board's own remembered window, else cascaded from the main window at the main window's size (the
    /// terminal then sets its height to fit).
    static func restoreWindow() {
        guard let launch = Self.launch, let window = WindowSizeManager.mainWindow else { return }
        let remembered = UserDefaults.standard.string(forKey: frameKey(launch.entry)).map { NSRectFromString($0) }
        if let frame = remembered, frame.width >= 200, frame.height >= 150 {
            WindowSizeManager.place(window, frame: frame)
        } else if let cascade = launch.cascade {
            WindowSizeManager.place(window, frame: cascade)
        }
        // A linked window (12.73): View > Always on Top as it was left for this one
        if let link = launch.link, LinkedWindows.isOnTop(link.id) {
            window.level = .floating
        }
    }

    /// Session, quitting: the window's last normal frame, for the next time this board is opened. The main
    /// window's own saved frame is left alone.
    static func saveWindow() {
        guard let entry = connection else { return }
        guard let frame = WindowSizeManager.lastNormalFrame ?? WindowSizeManager.mainWindow?.frame,
              frame.width >= 200, frame.height >= 150 else { return }
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: frameKey(entry))
        _ = CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
    }

    /// Session, quitting: the call in the call log is closed with its byte counts, and the line hung up.
    static func hangUpForQuit() {
        closing = true
        let stats = NativeBridge.shared.getConnectionStats()
        CallStatsService.shared.endCall(bytesSent: stats?.bytesSent ?? 0, bytesReceived: stats?.bytesReceived ?? 0)
        NativeBridge.shared.disconnect()
    }
}

// MARK: - Launch arguments / handoff

private enum SessionLaunchArguments {
    /// A handoff older than this was never picked up (the launch failed) and is thrown away.
    static let handoffMaxAge: TimeInterval = 60

    static var handoffDir: URL {
        AppDataLock.directory.appendingPathComponent("session-launch", isDirectory: true)
    }

    struct Handoff: Codable {
        var entry: String       // base64 JSON of the BBSEntry, as on the command line
        var parent: Int32
        var cascade: String?
        var created: Date
        /// base64 JSON of a linked window's SessionMode.LinkLaunch (12.73), as on the command line
        var link: String? = nil
    }

    static func read() -> SessionMode.Launch? {
        let args = ProcessInfo.processInfo.arguments
        var session: String?
        var parent: Int32 = 0
        var cascade: String?
        var token: String?
        var link: String?
        var i = 1
        while i + 1 < args.count {
            switch args[i] {
            case "--session": session = args[i + 1]; i += 1
            case "--parent": parent = Int32(args[i + 1]) ?? 0; i += 1
            case "--cascade": cascade = args[i + 1]; i += 1
            case "--handoff": token = args[i + 1]; i += 1
            case "--link": link = args[i + 1]; i += 1
            default: break
            }
            i += 1
        }

        if let session, let entry = decodeEntry(session) {
            if let token {
                try? FileManager.default.removeItem(at: handoffDir.appendingPathComponent("\(token).json"))
            }
            return SessionMode.Launch(entry: entry, parentPid: parent, cascade: parseCascade(cascade),
                                      link: decodeLink(link))
        }
        // A malformed argument is ignored: without --session this is simply the main instance, unless an instance
        // that is still running left a connection for a new instance moments ago
        return claimHandoff()
    }

    static func decodeEntry(_ base64: String) -> BBSEntry? {
        guard let data = Data(base64Encoded: base64) else { return nil }
        return try? JSONDecoder().decode(BBSEntry.self, from: data)
    }

    static func decodeLink(_ base64: String?) -> SessionMode.LinkLaunch? {
        guard let base64, let data = Data(base64Encoded: base64) else { return nil }
        return try? JSONDecoder().decode(SessionMode.LinkLaunch.self, from: data)
    }

    static func encodeLink(_ link: SessionMode.LinkLaunch) -> String? {
        (try? JSONEncoder().encode(link))?.base64EncodedString()
    }

    static func encodeEntry(_ entry: BBSEntry) -> String? {
        var copy = entry
        copy.snapshotData = nil     // the picture isn't needed to call, and would make the argument huge
        return (try? JSONEncoder().encode(copy))?.base64EncodedString()
    }

    static func parseCascade(_ text: String?) -> NSRect? {
        guard let parts = text?.split(separator: ",").compactMap({ Double($0) }), parts.count == 4 else { return nil }
        let (left, top, right, bottom) = (parts[0], parts[1], parts[2], parts[3])
        guard right > left, top > bottom else { return nil }
        return NSRect(x: left, y: bottom, width: right - left, height: top - bottom)
    }

    static func writeHandoff(_ handoff: Handoff, token: String) {
        AppDataLock.withLock {
            try? FileManager.default.createDirectory(at: handoffDir, withIntermediateDirectories: true)
            guard let data = try? JSONEncoder().encode(handoff) else { return }
            try? data.write(to: handoffDir.appendingPathComponent("\(token).json"), options: .atomic)
        }
    }

    /// The oldest recent handoff whose main instance is still running (and isn't this one), taken so no other
    /// instance can have it too. Stale ones are removed on the way.
    private static func claimHandoff() -> SessionMode.Launch? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: handoffDir.path) else { return nil }
        return AppDataLock.withLock { () -> SessionMode.Launch? in
            guard let files = try? fm.contentsOfDirectory(at: handoffDir, includingPropertiesForKeys: nil) else {
                return nil
            }
            let decoder = JSONDecoder()
            var candidates: [(url: URL, handoff: Handoff)] = []
            for url in files where url.pathExtension == "json" {
                guard let data = try? Data(contentsOf: url),
                      let handoff = try? decoder.decode(Handoff.self, from: data),
                      Date().timeIntervalSince(handoff.created) < handoffMaxAge else {
                    try? fm.removeItem(at: url)
                    continue
                }
                candidates.append((url, handoff))
            }
            let me = ProcessInfo.processInfo.processIdentifier
            for candidate in candidates.sorted(by: { $0.handoff.created < $1.handoff.created }) {
                guard candidate.handoff.parent != me,
                      NSRunningApplication(processIdentifier: candidate.handoff.parent)?.bundleIdentifier
                        == Bundle.main.bundleIdentifier,
                      let entry = decodeEntry(candidate.handoff.entry) else { continue }
                try? fm.removeItem(at: candidate.url)
                return SessionMode.Launch(entry: entry, parentPid: candidate.handoff.parent,
                                          cascade: parseCascade(candidate.handoff.cascade),
                                          link: decodeLink(candidate.handoff.link))
            }
            return nil
        }
    }
}

// MARK: - Main instance: starting and closing sessions

enum SessionLauncher {
    /// The main instance tells its sessions to close (object: its pid as a string). A sandboxed app may post a
    /// distributed notification as long as it carries no userInfo.
    static let closeSessionsNotification = Notification.Name("com.terminator.macos.closeSessions")

    /// Main instance: connections open in windows of their own (Options > Separate Window per BBS). Off, the main
    /// window becomes the terminal as it did before.
    static var launchesSessions: Bool {
        !SessionMode.isSession && UserDefaults.standard.bool(forKey: AppPreferences.multiWindow)
    }

    /// The session instances this one started, for closing them with it.
    private static var sessions: [NSRunningApplication] = []
    /// Starts not yet reported back by NSWorkspace, counted for the cascade.
    private static var pendingLaunches = 0
    /// The user already agreed to close them (a second quit request doesn't ask again).
    private static var confirmed = false

    static var openSessions: [NSRunningApplication] {
        sessions.removeAll { $0.isTerminated }
        return sessions
    }

    /// Every connect in the main instance (home screen, phonebook, command line, telnet:// link) comes here: a window
    /// of its own for the board, or, with Separate Window per BBS off, the terminal right here as before.
    static func connect(_ entry: BBSEntry) {
        if launchesSessions {
            launch(entry)
        } else {
            AppState.shared.currentView = .terminal(entry)
        }
    }

    /// Opens `entry` in a new instance of this app. The whole entry goes along (a board typed in the command line
    /// isn't in the phonebook), and so does where to open when the board has no remembered window: cascaded down
    /// from the main window. A board's linked window (12.73) passes `link`, its own first place (`start`) and maybe
    /// `activates: false` (focus=0); it isn't one of `sessions` (the close-all question) but goes to `launched`,
    /// which the caller keeps for Raise (nil: it didn't start).
    static func launch(_ entry: BBSEntry, link: SessionMode.LinkLaunch? = nil, start: NSRect? = nil,
                       activates: Bool = true, launched: ((NSRunningApplication?) -> Void)? = nil) {
        guard let encoded = SessionLaunchArguments.encodeEntry(entry) else {
            launched?(nil)
            return
        }
        let encodedLink = link.flatMap { SessionLaunchArguments.encodeLink($0) }
        if link != nil && encodedLink == nil {
            launched?(nil)
            return
        }
        let parent = ProcessInfo.processInfo.processIdentifier
        let token = UUID().uuidString

        var cascade: String?
        if let start {
            cascade = [start.minX, start.maxY, start.maxX, start.minY]
                .map { String(Int($0.rounded())) }.joined(separator: ",")
        } else if link == nil, let window = WindowSizeManager.mainWindow {
            let here = WindowSizeManager.isNormal(window) ? window.frame
                : (WindowSizeManager.lastNormalFrame ?? window.frame)
            let step = CGFloat(32 * (openSessions.count + pendingLaunches + 1))
            cascade = [here.minX + step, here.maxY - step, here.maxX + step, here.minY - step]
                .map { String(Int($0.rounded())) }.joined(separator: ",")
        }

        SessionLaunchArguments.writeHandoff(.init(entry: encoded, parent: parent, cascade: cascade, created: Date(),
                                                  link: encodedLink),
                                            token: token)

        var arguments = ["--session", encoded, "--parent", String(parent)]
        if let cascade {
            arguments += ["--cascade", cascade]
        }
        if let encodedLink {
            arguments += ["--link", encodedLink]
        }
        arguments += ["--handoff", token]

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = arguments
        configuration.activates = activates
        configuration.addsToRecentItems = false

        let counted = link == nil
        if counted {
            pendingLaunches += 1
        }
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { app, error in
            DispatchQueue.main.async {
                if counted {
                    SessionLauncher.pendingLaunches = max(0, SessionLauncher.pendingLaunches - 1)
                }
                launched?(app)
                if let app {
                    if counted {
                        SessionLauncher.sessions.append(app)
                    }
                    return
                }
                try? FileManager.default.removeItem(
                    at: SessionLaunchArguments.handoffDir.appendingPathComponent("\(token).json"))
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "TERMinator"
                alert.informativeText = "Couldn't open a window for \(entry.name):\n\n"
                    + (error?.localizedDescription ?? "unknown error")
                alert.addButton(withTitle: "OK")
                _ = alert.runModal()
            }
        }
    }

    /// Main instance closing with BBS windows open: close them too? Asks once; true = go ahead (the sessions have
    /// been told to close). Always true in a session or with none open.
    static func confirmCloseIfNeeded() -> Bool {
        guard !SessionMode.isSession, !confirmed else { return true }
        let open = openSessions
        guard !open.isEmpty else { return true }
        guard CloseSessionsDialog.run(count: open.count) else { return false }
        confirmed = true
        DistributedNotificationCenter.default().postNotificationName(
            closeSessionsNotification, object: String(ProcessInfo.processInfo.processIdentifier),
            userInfo: nil, deliverImmediately: true)
        return true
    }

    /// Check for Updates, quitting to install: the BBS windows close with it, without the question (the update
    /// window already warned about them).
    static func closeAllWithoutAsking() {
        guard !SessionMode.isSession else { return }
        confirmed = true
        guard !openSessions.isEmpty else { return }
        DistributedNotificationCenter.default().postNotificationName(
            closeSessionsNotification, object: String(ProcessInfo.processInfo.processIdentifier),
            userInfo: nil, deliverImmediately: true)
    }

    // MARK: Main window hooks

    private static var keyMonitor: Any?
    private static let closeButtonTarget = CloseButtonTarget()

    /// Main instance, once its window exists: the close button and ⌘W ask before closing over open BBS windows,
    /// and coming back to the front brings in what the BBS windows saved meanwhile.
    static func installMainWindowHooks() {
        guard !SessionMode.isSession else { return }
        hookCloseButton()

        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                guard modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "w",
                      let window = WindowSizeManager.mainWindow, event.window === window,
                      !SessionLauncher.openSessions.isEmpty else { return event }
                return SessionLauncher.confirmCloseIfNeeded() ? event : nil
            }
            // Their last calls, snapshots and settings changed there
            NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                   object: nil, queue: .main) { _ in
                SessionLauncher.hookCloseButton()
                BBSEntryStore.shared.reloadIfChanged()
            }
        }
    }

    private static func hookCloseButton() {
        guard let button = WindowSizeManager.mainWindow?.standardWindowButton(.closeButton),
              button.target !== closeButtonTarget else { return }
        closeButtonTarget.originalTarget = button.target
        closeButtonTarget.originalAction = button.action
        button.target = closeButtonTarget
        button.action = #selector(CloseButtonTarget.closeClicked(_:))
    }

    private final class CloseButtonTarget: NSObject {
        weak var originalTarget: AnyObject?
        var originalAction: Selector?

        @objc func closeClicked(_ sender: Any?) {
            guard SessionLauncher.confirmCloseIfNeeded() else { return }
            if let action = originalAction {
                _ = NSApp.sendAction(action, to: originalTarget, from: sender)
            } else {
                (sender as? NSView)?.window?.performClose(nil)
            }
        }
    }
}

// MARK: - Linked windows (Rainwire:Link, 12.73; Rainwire docs/MRC_WINDOW.md)

/// A board can open more windows onto the same call, one per kind: Rainwire's Multi Relay Chat (mrc) or Dead Modem TV
/// (tv), after the caller says yes to "Open ... in a new window?". Any kind the native side passed ([a-z0-9_], 16 at
/// most) is fine: the window only ever connects back to this board, so the kind only names it. It's one more session
/// instance (the terminal engine holds one call per process, §12.57) with an ad-hoc entry for this board (never a host
/// the board names) that sends the board's single-use token in its Caps answer. The board ends it when this call ends,
/// so nothing here tracks it beyond the instance, kept for Raise. Windows MainWindow.OpenLinkedWindow and friends.
/// Main thread.
enum LinkedWindows {
    /// The opener tells its linked window to come to the front (object: the linked instance's pid as a string; no
    /// userInfo, so a sandboxed app may post it). Windows' named event Local\TERMinator-Raise-<pid>.
    static let raiseNotification = Notification.Name("com.terminator.macos.raiseLinked")

    /// How long after the caller's key or click on the call a board may open a linked window.
    private static let gestureWindow: TimeInterval = 10

    /// mw=1 went out in this call's Caps answer (the setting was on when it connected, or this is a linked window).
    private(set) static var onAtConnect = false
    /// systemUptime of the caller's last key or click on the call (0: none since it was used up)
    private static var gestureAt: TimeInterval = 0
    /// The linked windows this window's call opened, by kind.
    private static var children: [String: NSRunningApplication] = [:]
    /// Kinds whose instance is starting (NSWorkspace hasn't answered yet): a second Open meanwhile is ignored.
    private static var starting: Set<String> = []
    private static var gestureMonitor: Any?

    /// Options > Let Boards Open Extra Windows (default on).
    static var settingOn: Bool { UserDefaults.standard.bool(forKey: AppPreferences.linkedWindows) }

    /// At launch (applicationDidFinishLaunching): watch for the caller's keys and clicks; a linked window also
    /// listens for Raise.
    static func install() {
        if gestureMonitor == nil {
            gestureMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { event in
                LinkedWindows.stampGesture(event)
                return event
            }
        }
        guard let link = SessionMode.link else { return }
        DistributedNotificationCenter.default().addObserver(
            forName: raiseNotification, object: String(ProcessInfo.processInfo.processIdentifier),
            queue: .main) { _ in
            LinkedWindows.bringToFront()
        }
        DispatchQueue.main.async {
            guard let window = WindowSizeManager.mainWindow else { return }
            // View > Always on Top as it was left for this one (restoreWindow sets it too, if the window was there)
            if LinkedWindows.isOnTop(link.id) {
                window.level = .floating
            }
            // focus=0: shown above the other windows, without taking the focus (the launch didn't activate it)
            if link.noActivate && !NSApp.isActive {
                window.orderFront(nil)
            }
        }
    }

    /// Before each connect: whether mw=1 goes in the Caps answer, and a linked window's own token (link=).
    static func capsForConnect() -> (multiWindow: Bool, linkToken: String?) {
        AppDataLock.refreshDefaults()
        onAtConnect = settingOn || SessionMode.isLinked
        gestureAt = 0
        return (onAtConnect, SessionMode.link?.token)
    }

    /// A key or click while the call is on screen: the board may open a linked window for the next 10 s.
    private static func stampGesture(_ event: NSEvent) {
        let state = AppState.shared
        guard let window = event.window, window === WindowSizeManager.mainWindow,
              state.isConnected, !state.settingsOverTerminal,
              case .terminal = state.currentView else { return }
        gestureAt = ProcessInfo.processInfo.systemUptime
    }

    /// Rainwire:Link;Open. Opened only when all hold, else ignored without a word (the board falls back after 15 s):
    /// this isn't a linked window itself; the call is connected; the setting was on when it connected and still is;
    /// the caller pressed a key or clicked on the call in the last 10 s (used up); none of that kind is open from
    /// this call. The optional hints (Rainwire docs/MRC_WINDOW.md): cols/rows pick the screen mode (else this
    /// window's), place=right|left|below|above where it first opens (else right), focus=0 opens it without taking the
    /// focus. Any other key is ignored.
    static func open(_ request: OscExtras.LinkRequest, from parent: BBSEntry?, connected: Bool) {
        let kind = request.kind, token = request.token, title = request.title
        // Each refusal is logged (the board only sees nothing open): /usr/bin/log stream --predicate 'category == "Link"'
        let args = request.args.filter { $0.key != "token" }.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ";")
        linkLogger.log("Open kind=\(kind, privacy: .public) \(args, privacy: .public)")
        guard !SessionMode.isLinked, !kind.isEmpty, OscExtras.isLinkToken(token) else {
            linkLogger.log("ignored: linked=\(SessionMode.isLinked, privacy: .public) or bad kind/token")
            return
        }
        guard connected, let parent else {
            linkLogger.log("ignored: not connected")
            return
        }
        AppDataLock.refreshDefaults()
        guard onAtConnect, settingOn else {
            linkLogger.log("ignored: setting onAtConnect=\(onAtConnect, privacy: .public) on=\(settingOn, privacy: .public)")
            return
        }
        let gesture = gestureAt
        gestureAt = 0
        let since = ProcessInfo.processInfo.systemUptime - gesture
        guard gesture > 0, since <= gestureWindow else {
            linkLogger.log("ignored: no key/click in time (gesture=\(gesture > 0, privacy: .public), \(since, privacy: .public) s ago)")
            return
        }
        guard !starting.contains(kind) else {
            linkLogger.log("ignored: a \(kind, privacy: .public) window is still starting")
            return
        }
        if let open = children[kind] {
            if !open.isTerminated {
                linkLogger.log("ignored: a \(kind, privacy: .public) window is already open (pid \(open.processIdentifier, privacy: .public))")
                return
            }
            children[kind] = nil
        }
        linkLogger.log("launching \(kind, privacy: .public) window")

        // The same board as this window, and nothing else from the board but the token and the title text. A new
        // entry id (no Keychain password behind it), so SSH logs in blank and the token does the rest; its place and
        // Always on Top are remembered by "<parentId>-<kind>".
        let trimmed = parent.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let board = trimmed.isEmpty ? parent.host : trimmed
        let mode = screenMode(parent: parent.screenMode, cols: request.int("cols"), rows: request.int("rows"))
        let linked = BBSEntry(
            name: "\(board) — \(title.isEmpty ? kind.uppercased() : title)",
            host: parent.host,
            port: parent.port,
            connectionProtocol: parent.connectionProtocol,
            username: "",
            screenMode: mode,
            font: parent.font,
            showStatusBar: parent.showStatusBar
        )
        let activates = request.args["focus"] != "0"
        let link = SessionMode.LinkLaunch(token: token, kind: kind, board: board, parentId: parent.id.uuidString,
                                          noActivate: !activates)
        // First time: beside this window (place=, right by default), on its screen, as wide as its columns need.
        // Afterwards the window's own remembered place wins.
        let widthScale = Double(mode.columns) / Double(max(1, parent.screenMode.columns))
        let start = startFrame(open: openCount, place: request.args["place"], widthScale: widthScale)
        starting.insert(kind)
        SessionLauncher.launch(linked, link: link, start: start, activates: activates) { app in
            LinkedWindows.starting.remove(kind)
            if let app {
                LinkedWindows.children[kind] = app
            }
        }
    }

    /// Rainwire:Link;Raise: the linked window of this kind comes to the front. This instance (active: the caller
    /// just did something on the call) hands the activation over, and the linked one activates itself.
    static func raise(kind: String) {
        guard let app = children[kind] else { return }
        if app.isTerminated {
            children[kind] = nil
            return
        }
        NSApp.yieldActivation(to: app)
        DistributedNotificationCenter.default().postNotificationName(
            raiseNotification, object: String(app.processIdentifier), userInfo: nil, deliverImmediately: true)
    }

    /// A linked window, told to come forward: restored if minimized, made key, the app activated.
    private static func bringToFront() {
        NSApp.activate()
        guard let window = WindowSizeManager.mainWindow else { return }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
    }

    /// How many of this call's linked windows are still open.
    private static var openCount: Int {
        children.values.filter { !$0.isTerminated }.count
    }

    /// The linked window's screen mode: with no cols/rows hint, the parent's; else the smallest text mode (80/132 by
    /// 25-60) that holds cols x rows, clamped to 20-255 by 5-100 first, or 132x60 when nothing does. The Commodore
    /// modes are never picked for a hint.
    static func screenMode(parent: ScreenMode, cols: Int?, rows: Int?) -> ScreenMode {
        if cols == nil && rows == nil {
            return parent
        }
        let wantCols = min(max(cols ?? parent.columns, 20), 255)
        let wantRows = min(max(rows ?? parent.rows, 5), 100)
        var best = ScreenMode.mode132x60
        var bestArea = Int.max
        let modes: [ScreenMode] = [.mode80x25, .mode80x30, .mode80x40, .mode80x50,
                                   .mode132x25, .mode132x30, .mode132x40, .mode132x50, .mode132x60]
        for mode in modes where mode.columns >= wantCols && mode.rows >= wantRows && mode.columns * mode.rows < bestArea {
            best = mode
            bestArea = mode.columns * mode.rows
        }
        return best
    }

    /// Where a linked window first opens (Cocoa screen points): this window's normal frame moved past its right edge
    /// (place "left", "below", "above": that edge instead; anything else is right), 32 pt further along (and down)
    /// for each linked window already open, kept inside the visible area of this window's screen. widthScale: its
    /// columns over this window's (the terminal then sets its height to fit).
    private static func startFrame(open: Int, place: String?, widthScale: Double) -> NSRect? {
        guard let window = WindowSizeManager.mainWindow else { return nil }
        let here = WindowSizeManager.isNormal(window) ? window.frame
            : (WindowSizeManager.lastNormalFrame ?? window.frame)
        let width = (here.width * CGFloat(min(max(widthScale, 0.25), 4.0))).rounded()
        let height = here.height
        let step = CGFloat(32 * open)
        let origin: NSPoint
        switch place {
        case "left":
            origin = NSPoint(x: here.minX - width - step, y: here.minY - step)
        case "below":
            origin = NSPoint(x: here.minX + step, y: here.minY - step - height)
        case "above":
            origin = NSPoint(x: here.minX + step, y: here.maxY + step)
        default:
            origin = NSPoint(x: here.maxX + step, y: here.minY - step)
        }
        var frame = NSRect(origin: origin, size: NSSize(width: width, height: height))
        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
            frame.origin.x = max(visible.minX, min(frame.origin.x, visible.maxX - width))
            frame.origin.y = max(visible.minY, min(frame.origin.y, visible.maxY - height))
        }
        return frame
    }

    // MARK: Always on Top (linked windows only)

    /// View > Always on Top was left on for this linked window id ("<parentId>-<kind>").
    static func isOnTop(_ id: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: AppPreferences.linkedWindowsOnTop) ?? []).contains(id)
    }

    /// This linked window's View > Always on Top: applied now and remembered for its id.
    static func setOnTop(_ on: Bool) {
        guard let link = SessionMode.link else { return }
        WindowSizeManager.mainWindow?.level = on ? .floating : .normal
        AppDataLock.updateDefaults { defaults in
            var ids = defaults.stringArray(forKey: AppPreferences.linkedWindowsOnTop) ?? []
            ids.removeAll { $0 == link.id }
            if on {
                ids.append(link.id)
            }
            defaults.set(ids, forKey: AppPreferences.linkedWindowsOnTop)
        }
    }
}

// MARK: - "Close TERMinator" confirmation

/// Themed like the app's other questions (CommandLineConfirmView), as Windows' ConfirmCloseSessions is.
enum CloseSessionsDialog {
    static func run(count: Int) -> Bool {
        var answer = false
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 150),
                            styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Close TERMinator"
        panel.titlebarAppearsTransparent = true
        panel.backgroundColor = NSColor(red: 0x1A/255.0, green: 0x1A/255.0, blue: 0x2E/255.0, alpha: 1.0)
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isReleasedWhenClosed = false

        let host = NSHostingView(rootView: CloseSessionsConfirmView(count: count) { closeAll in
            answer = closeAll
            NSApp.stopModal()
        }.preferredColorScheme(.dark))
        panel.contentView = host
        panel.setContentSize(host.fittingSize)

        if let main = WindowSizeManager.mainWindow, main.isVisible, !main.isMiniaturized {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: main.frame.midX - size.width / 2, y: main.frame.midY - size.height / 2))
        } else {
            panel.center()
        }

        NSApp.activate(ignoringOtherApps: true)
        NSApp.runModal(for: panel)
        panel.orderOut(nil)
        return answer
    }
}

private struct CloseSessionsConfirmView: View {
    let count: Int
    let onAnswer: (Bool) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text(count == 1 ? "1 BBS window is still open" : "\(count) BBS windows are still open")
                .font(.system(size: 16, weight: .bold, design: .monospaced))
                .foregroundColor(.amberAccent)
                .multilineTextAlignment(.center)

            Text(count == 1 ? "Closing TERMinator hangs up that call too."
                            : "Closing TERMinator hangs up every one of those calls.")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
                .padding(.bottom, 18)

            HStack(spacing: 10) {
                RetroButton("CLOSE ALL", style: .amber) {
                    onAnswer(true)
                }
                .keyboardShortcut(.defaultAction)

                RetroButton("CANCEL", style: .green) {
                    onAnswer(false)
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(EdgeInsets(top: 24, leading: 28, bottom: 20, trailing: 28))
        .background(Color.surface)
        .fixedSize()
    }
}

// MARK: - Cross-process lock

/// One lock shared by every TERMinator instance, around each read-modify-write of the data they share (the phonebook
/// and the call total in UserDefaults, callstats.json). Each BBS runs in an instance of its own, so the main window and
/// any number of sessions may save at once; every save re-reads under this lock and merges its own change in, instead
/// of writing out a copy loaded minutes ago. An flock on a file in the app's container (all instances share it).
/// Reentrant within the process.
enum AppDataLock {
    /// Application Support/TERMinator (inside the sandbox container), where callstats.json lives too.
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        let dir = base.appendingPathComponent("TERMinator", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static let inProcess = NSRecursiveLock()
    private static var depth = 0
    private static var fd: Int32 = -1

    /// Runs `body` holding the lock. Waits up to 5 s; a lock held longer than that (a hung instance) is ignored
    /// rather than hanging this one.
    static func withLock<T>(_ body: () throws -> T) rethrows -> T {
        inProcess.lock()
        defer { inProcess.unlock() }
        if depth == 0 {
            acquire()
        }
        depth += 1
        defer {
            depth -= 1
            if depth == 0 {
                release()
            }
        }
        return try body()
    }

    private static func acquire() {
        let path = directory.appendingPathComponent("appdata.lock").path
        fd = open(path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        let deadline = Date().addingTimeInterval(5)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            if Date() >= deadline {
                break
            }
            usleep(10_000)
        }
    }

    private static func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    /// UserDefaults as they are now, not as this process last cached them: another instance may have written since.
    static func refreshDefaults() {
        _ = CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
    }

    /// A change to UserDefaults made from the current value (e.g. a counter), under the lock, pushed out before the
    /// lock is let go.
    static func updateDefaults(_ change: (UserDefaults) -> Void) {
        withLock {
            refreshDefaults()
            change(UserDefaults.standard)
            refreshDefaults()
        }
    }

    /// When the file last changed, or nil when it doesn't exist.
    static func stamp(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
