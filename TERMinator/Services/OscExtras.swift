import AppKit
import Foundation
import UserNotifications

/// The board's OSC extras (PORT_TO_MAC_LINUX.md 12.62): OSC 0/2 window title, OSC 8 hyperlinks, OSC 52 clipboard
/// writes; since 12.72 also OSC 777 notifications and the app's own keys in the Caps answer; since 12.73 the board's
/// Rainwire:Link requests (a linked window, Rainwire docs/MRC_WINDOW.md). Parsing, limits and the Rainwire:Caps answer are native (Bridge/apc/osc_ext.c, the same file as Windows);
/// this is the app's side, ported from Windows Services/OscExtras.cs. Main thread.
enum OscExtras {
    /// Same caps as osc_ext.h.
    static let uriMax = 2048
    static let clipboardMax = 64 * 1024

    private static var titleBuffer = [CChar](repeating: 0, count: 512)
    private static var clipBuffer = [CChar](repeating: 0, count: 64 * 1024 + 1)
    /// OSC_EXT_NOTE_TITLE_MAX + 1 and OSC_EXT_NOTE_BODY_MAX + 1: always big enough (12.72)
    private static var noteTitleBuffer = [CChar](repeating: 0, count: 64 + 1)
    private static var noteBodyBuffer = [CChar](repeating: 0, count: 256 + 1)
    /// OSC_EXT_LINK_POLL_MAX: a Rainwire:Link request's key=value lines always fit (16 x (16 + 128 + 2)), 12.73
    static let linkPollMax = 16 * (16 + 128 + 2)
    private static var linkBuffer = [CChar](repeating: 0, count: linkPollMax)

    /// A title the board set since the last call ("" = it cleared it), or nil when nothing changed.
    static func pollTitle() -> String? {
        let count = Int32(titleBuffer.count)
        let n = titleBuffer.withUnsafeMutableBufferPointer { syncterm_osc_poll_title($0.baseAddress, count) }
        guard n >= 0 else { return nil }
        let bytes = titleBuffer[0..<Int(n)].map { UInt8(bitPattern: $0) }
        return cleanTitle(String(decoding: bytes, as: UTF8.self))
    }

    /// Text the board put on the clipboard since the last call, or nil.
    static func pollClipboard() -> String? {
        let count = Int32(clipBuffer.count)
        let n = clipBuffer.withUnsafeMutableBufferPointer { syncterm_osc_poll_clipboard($0.baseAddress, count) }
        guard n > 0 else { return nil }
        let bytes = clipBuffer[0..<Int(n)].map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The oldest OSC 777 notification the board sent and the app hasn't taken yet, cleaned, or nil (12.72). Either
    /// part may be empty, not both.
    static func pollNotify() -> (title: String, body: String)? {
        let titleCount = Int32(noteTitleBuffer.count)
        let bodyCount = Int32(noteBodyBuffer.count)
        let got = noteTitleBuffer.withUnsafeMutableBufferPointer { title in
            noteBodyBuffer.withUnsafeMutableBufferPointer { body in
                syncterm_osc_poll_notify(title.baseAddress, titleCount, body.baseAddress, bodyCount)
            }
        }
        guard got == 1 else { return nil }
        return (cleanTitle(utf8z(noteTitleBuffer)), cleanTitle(utf8z(noteBodyBuffer)))
    }

    /// A Rainwire:Link request (12.73). Native has already checked kind ([a-z0-9_], 16 at most) and, on Open, token
    /// (26 characters of Crockford base32); every other key the board sent is in `args` as it came (unescaped,
    /// controls removed): title, the optional Open hints cols, rows, place and focus, and anything later. Unknown keys
    /// are the app's to ignore.
    struct LinkRequest {
        let open: Bool
        let kind: String
        let token: String
        let args: [String: String]

        var title: String { args["title"].map { OscExtras.cleanTitle($0) } ?? "" }

        /// A whole-number argument, or nil when it's missing or not a number.
        func int(_ key: String) -> Int? {
            guard let value = args[key], !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }) else {
                return nil
            }
            return Int(value)
        }
    }

    /// The oldest Rainwire:Link request the board sent and the app hasn't taken yet (12.73), or nil. Native passes
    /// "key=value" lines; kind is always there and token is on every Open.
    static func pollLink() -> LinkRequest? {
        let count = Int32(linkBuffer.count)
        let verb = linkBuffer.withUnsafeMutableBufferPointer { syncterm_osc_poll_link($0.baseAddress, count) }
        guard verb == 1 || verb == 2 else { return nil }
        var args: [String: String] = [:]
        for line in utf8z(linkBuffer).split(separator: "\n", omittingEmptySubsequences: true) {
            guard let eq = line.firstIndex(of: "="), eq != line.startIndex else { continue }
            args[String(line[line.startIndex..<eq])] = String(line[line.index(after: eq)...])
        }
        guard let kind = args["kind"], !kind.isEmpty else { return nil }
        return LinkRequest(open: verb == 1, kind: kind, token: args["token"] ?? "", args: args)
    }

    /// A Rainwire:Link token: exactly 26 characters of upper-case Crockford base32 (no I, L, O or U).
    static func isLinkToken(_ token: String) -> Bool {
        let allowed = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        return token.count == 26 && token.allSatisfy { allowed.contains($0) }
    }

    /// The app's own keys for the Rainwire:Caps answer (12.72); call before each connect.
    static func setInfo(_ keys: String) {
        syncterm_osc_set_info(keys)
    }

    /// "app=1.4.9;lang=en-US;tz=America/Chicago;notify=1" (Rainwire docs/CLIENT_CAPS.md, 12.72): the version the
    /// About box shows, the UI language, the IANA time zone and whether board notifications are shown. A key whose
    /// value has anything but [A-Za-z0-9._+/-] is left out. Never touch=1 on a desktop. 12.73: mw=1 when the board may
    /// open linked windows (Options > Let Boards Open Extra Windows), and link=<token> on a linked window's own
    /// connection (a token that isn't plain Crockford base32 is left out, so the board hangs up on it). 1.1.6: ui=3,
    /// this app draws a Rainwire board's menus itself (Views/RainwireMenu.swift, Rainwire docs/MENU_GFX.md), and
    /// uiscreens= which of a board's screens it draws ("menu+dialog+news+page+list+form+picture"; later ones join with '+').
    /// Also 1.1.6: scene=3 (RainwireMenuView.sceneVersion: scenes version 2 and 3, Rainwire docs/SCENES_V2.md) and
    /// scenekinds= the scene block kinds it draws (Views/RainwireScene.swift, Rainwire docs/SCENES.md). The native side keeps 256 bytes of these keys (OSC_EXT_INFO_MAX) and drops a key that doesn't
    /// fit, so scenekinds goes last (only it can be lost; the board then thinks no kinds are known).
    static func appInfo(notify: Bool, multiWindow: Bool = false, linkToken: String? = nil) -> String {
        var keys: [String] = []
        if isInfoValue(AppInfo.version) {
            keys.append("app=" + AppInfo.version)
        }
        let preferred = Locale.preferredLanguages.first ?? ""
        let lang = (preferred.isEmpty ? Locale.current.identifier : preferred).replacingOccurrences(of: "_", with: "-")
        if isInfoValue(lang) {
            keys.append("lang=" + lang)
        }
        let tz = TimeZone.current.identifier
        if isInfoValue(tz) {
            keys.append("tz=" + tz)
        }
        if notify {
            keys.append("notify=1")
        }
        if multiWindow {
            keys.append("mw=1")
        }
        if let linkToken, isLinkToken(linkToken) {
            keys.append("link=" + linkToken)
        }
        keys.append("ui=\(RainwireMenuView.version)")
        keys.append("uiscreens=" + RainwireMenuView.screens)
        keys.append("scene=\(RainwireMenuView.sceneVersion)")
        keys.append("scenekinds=" + RainwireMenuView.sceneKinds)
        return keys.joined(separator: ";")
    }

    /// notify=1 (12.72): Settings > Board Notifications is on (default off) and macOS lets the app show
    /// notifications. Never asks here: turning the setting on does (BoardNotifier.requestPermission).
    static func notificationsAllowed() async -> Bool {
        guard BoardNotifier.enabled else { return false }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            return true
        default:
            return false
        }
    }

    /// True once the board has drawn an OSC 8 link this session.
    static var linksActive: Bool { syncterm_osc_links_active() != 0 }

    /// The OSC 8 link under screen cell (col, row), 0-based, showing CP437 character ch: its URI and the first and
    /// last column of its run on that row, or nil.
    static func linkAt(col: Int, row: Int, ch: Int) -> (url: String, start: Int, end: Int)? {
        var buf = [CChar](repeating: 0, count: uriMax + 1)
        var start: Int32 = -1
        var end: Int32 = -1
        let count = Int32(buf.count)
        let n = buf.withUnsafeMutableBufferPointer {
            syncterm_osc_link_at(Int32(col), Int32(row), Int32(ch), $0.baseAddress, count, &start, &end)
        }
        guard n > 0 else { return nil }
        let url = String(decoding: buf[0..<Int(n)].map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return isAllowedURI(url) ? (url, Int(start), Int(end)) : nil
    }

    /// The schemes a board may link to (checked natively too; this is the last word before the browser).
    static func isAllowedURI(_ uri: String) -> Bool {
        guard !uri.isEmpty, uri.utf8.count <= uriMax else { return false }
        guard uri.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7f }) else { return false }
        let lower = uri.lowercased()
        return ["http://", "https://", "mailto:", "telnet://", "ssh://"].contains { lower.hasPrefix($0) && lower.count > $0.count }
    }

    /// Native already dropped control characters; this also drops C1, format (bidi) and replacement characters.
    fileprivate static func cleanTitle(_ title: String) -> String {
        let kept = title.unicodeScalars.filter { s in
            !(s.properties.generalCategory == .control || s.properties.generalCategory == .format || s.value == 0xFFFD)
        }
        return String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespaces)
    }

    /// Only [A-Za-z0-9._+/-] may go in a Caps value (native drops anything else; this keeps the rest), 12.72.
    private static func isInfoValue(_ value: String) -> Bool {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._+/-")
        return !value.isEmpty && value.allSatisfy { allowed.contains($0) }
    }

    /// The NUL-terminated UTF-8 in buffer.
    private static func utf8z(_ buffer: [CChar]) -> String {
        let n = buffer.firstIndex(of: 0) ?? buffer.count
        return String(decoding: buffer[0..<n].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Opens a board's link straight away (sysop's call; hovering shows the real address first). Others: ignored.
    static func open(_ url: String) {
        guard isAllowedURI(url), let target = URL(string: url) else { return }
        NSWorkspace.shared.open(target)
    }
}

/// The board's OSC 0/2 title in the window title, "<title> - TERMinator" (SessionMode.windowTitle reads it), until
/// the call ends. Boss Hide keeps its fake title while it's up.
enum BoardTitle {
    private(set) static var current: String?

    static func set(_ title: String?) {
        let value = (title?.isEmpty ?? true) ? nil : title
        guard value != current else { return }
        current = value
        apply()
        DispatchQueue.main.async { apply() }   // a SwiftUI scene update can put its own title back
    }

    private static func apply() {
        guard !AppState.shared.bossHideActive, let window = WindowSizeManager.mainWindow else { return }
        window.title = SessionMode.windowTitle
    }
}

/// The board's OSC 777 notifications as macOS notifications (12.72, Rainwire docs/CLIENT_CAPS.md "Notifications").
/// Only with Settings > Board Notifications on (default off; off, they're still polled and dropped). Dropped while this session's window is the active one (the board says it on screen too) or Boss Hide is up;
/// otherwise shown, at most one every 5 seconds: one arriving inside that wait replaces the one waiting, and the latest
/// is shown when the wait is over. Every BBS window is a process of its own (12.57), so the request identifier is per
/// process and a newer notification replaces the older one in Notification Center. Clicking it brings that window to
/// front, whichever TERMinator instance macOS hands the click to. Main thread.
enum BoardNotifier {
    /// userInfo key: the pid of the instance whose window posted it (our own key; nothing else on macOS posts)
    static let sessionKey = "terminatorBoardSession"
    static let category = "terminator_board_notify"
    private static let minGap: TimeInterval = 5

    private static var lastShown: TimeInterval = -minGap   // systemUptime of the last one shown
    private static var waiting: (title: String, body: String)?
    private static var gapWork: DispatchWorkItem?
    /// UNUserNotificationCenter's delegate is weak: kept here
    private static let delegate = BoardNotifyDelegate()

    private static var identifier: String { "terminator-board-\(ProcessInfo.processInfo.processIdentifier)" }

    /// At launch (applicationDidFinishLaunching): handles the clicks, and takes this window's notification down
    /// when the app comes to front again.
    static func install() {
        UNUserNotificationCenter.current().delegate = delegate
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                               queue: .main) { _ in
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
        }
    }

    /// Settings > Board Notifications (AppPreferences.boardNotifications), default off.
    static var enabled: Bool { UserDefaults.standard.bool(forKey: AppPreferences.boardNotifications) }

    /// The setting was just turned on: ask macOS, unless it was asked before (then this just reports the answer
    /// System Settings holds). completion(allowed) runs on the main thread.
    static func requestPermission(completion: @escaping (Bool) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async {
                completion(granted)
            }
        }
    }

    /// True while a notification must not be shown: the setting is off, the session's window is the active one, or
    /// Boss Hide is up.
    private static var suppressed: Bool {
        if !enabled || AppState.shared.bossHideActive {
            return true
        }
        guard NSApp.isActive, let window = WindowSizeManager.mainWindow else { return false }
        return window.isVisible && !window.isMiniaturized && (window.isKeyWindow || window.isMainWindow)
    }

    /// A notification from the board; an empty title shows boardName.
    static func post(title: String, body: String, boardName: String) {
        guard !(title.isEmpty && body.isEmpty), !suppressed else { return }
        let note = (title: title.isEmpty ? boardName : title, body: body)
        let sinceLast = ProcessInfo.processInfo.systemUptime - lastShown
        if sinceLast < minGap || gapWork != nil {
            // Inside the 5 s: this one replaces any waiting, and is shown when the gap is over
            waiting = note
            if gapWork == nil {
                let work = DispatchWorkItem {
                    gapWork = nil
                    guard let next = waiting else { return }
                    waiting = nil
                    if !suppressed {
                        show(title: next.title, body: next.body)
                    }
                }
                gapWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + max(0.001, minGap - sinceLast), execute: work)
            }
            return
        }
        show(title: note.title, body: note.body)
    }

    /// The call ended: forget the one waiting (native drops its queue too).
    static func reset() {
        gapWork?.cancel()
        gapWork = nil
        waiting = nil
    }

    private static func show(title: String, body: String) {
        lastShown = ProcessInfo.processInfo.systemUptime
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = category
        content.userInfo = [sessionKey: Int(ProcessInfo.processInfo.processIdentifier)]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content,
                                                                     trigger: nil))
    }

    /// A click: this instance's own window to front, or the instance that posted it (one per BBS window, 12.57).
    fileprivate static func bringToFront(pid: pid_t) {
        guard pid != ProcessInfo.processInfo.processIdentifier else {
            NSApp.activate(ignoringOtherApps: true)
            if let window = WindowSizeManager.mainWindow {
                if window.isMiniaturized {
                    window.deminiaturize(nil)
                }
                window.makeKeyAndOrderFront(nil)
            }
            return
        }
        // Gone (its call ended and it quit): nothing to bring back
        NSRunningApplication(processIdentifier: pid)?.activate(options: [])
    }
}

/// UNUserNotificationCenter's delegate (12.72). Board notifications are the only ones the macOS app posts.
private final class BoardNotifyDelegate: NSObject, UNUserNotificationCenterDelegate {
    /// Posted while the app is active but the session's window isn't in front (another window, a panel): show it.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
           let pid = info[BoardNotifier.sessionKey] as? Int {
            DispatchQueue.main.async {
                BoardNotifier.bringToFront(pid: pid_t(pid))
            }
        }
        completionHandler()
    }
}
