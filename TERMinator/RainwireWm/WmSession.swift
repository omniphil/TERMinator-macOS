import Foundation

/// A start menu entry the board offered (Item).
struct WmItem {
    let id: String
    let key: String
    let label: String
}

/// One of the board's windows, as this terminal draws it.
final class WmWindow {
    let id: Int
    var title: String
    /// Where the board suggested it go, in main-screen cells.
    let x: Int
    let y: Int
    /// normal, min or max.
    var state: String
    let terminal: WmTerminal
    /// The user pressed close; the window goes when the board says Close.
    var closeRequested = false
    /// A font the board sent to draw this window's text with; "" for the theme's.
    let font: String

    // What the desk layer made of it, kept here so a re-created layer (SwiftUI rebuilt TerminalView) puts it back as
    // it was rather than where the board first suggested (Windows' layer is never rebuilt, so it just keeps them)
    /// Where the frame's top-left corner is, in main-screen cells; nil until a layer has placed it.
    var deskX: Int?
    var deskY: Int?
    /// Its stacking order on the desk.
    var deskZ = 0
    /// Where it was and how big before it was maximized (cell position and content size), while it is.
    var restore: (x: Int, y: Int, cols: Int, rows: Int)?

    init(id: Int, title: String, x: Int, y: Int, state: String, terminal: WmTerminal, font: String = "") {
        self.font = font
        self.id = id
        self.title = title
        self.x = x
        self.y = y
        self.state = state
        self.terminal = terminal
    }
}

/// Rainwire's window protocol v1 (Rainwire docs/WINDOWS.md), the terminal's side: what the board has said, and what
/// to tell it. The board runs every window's app and sends each window's screen; this terminal draws the frames and
/// does moving, resizing, stacking and minimizing itself, telling the board only the results.
///
/// TERMinator answers the Query with channels=0 (cryptlib's SSH client can't open "rainwire-window" channels), so
/// every window's screen comes in Data messages and its input goes back in Input messages on the one connection.
///
/// The board is trusted no more than it has to be: sizes are clamped, unknown windows ignored, and Launch only ever
/// sends an item the board offered. No AppKit in here; the desk layer (RainwireDeskLayer) draws what this holds.
/// Port of the Windows client's `RainwireWm/WmSession.cs`; the C# events are closures here.
final class WmSession {
    static let maxWindows = 32

    private let sendBytes: ([UInt8]) -> Void
    private(set) var windows: [Int: WmWindow] = [:]
    private(set) var items: [WmItem] = []
    private var fonts: [String: (font: WmFont, got: Int)] = [:]
    private var focused = 0
    private static var warned: Set<String> = []

    /// The most fonts one board may send (each at most 256 glyphs of 32 rows).
    static let maxFonts = 8

    init(send: @escaping ([UInt8]) -> Void) {
        self.sendBytes = send
    }

    /// The window the board last heard was focused (Focused, or the newest Open); 0 for none.
    var focusedId: Int { focused }

    /// Something from the board was ignored: say so in the log, once per kind, so a misbehaving board can't flood it.
    static func warnOnce(_ kind: String, _ detail: String = "") {
        if warned.count < 64 && warned.insert(kind).inserted {
            NSLog("RainwireWm: ignored %@%@", kind, detail.isEmpty ? "" : " (\(detail))")
        }
    }

    /// Between Hello and Bye: the board's windows are ours to draw.
    private(set) var active = false
    /// channels or framed, from Hello.
    private(set) var mode = ""
    /// A full-screen program (a raw door) has the main screen until Resume.
    private(set) var suspended = false
    /// How the board wants the windows drawn (Theme); the classic look until it says.
    private(set) var theme = WmTheme()

    // Events (the desk layer and RainwireDesk listen; several listeners can be added to `started`)
    var started: [() -> Void] = []
    var itemsChanged: (() -> Void)?
    /// A new Theme, or a font it names finished arriving: redraw everything.
    var themeChanged: (() -> Void)?
    var opened: ((WmWindow) -> Void)?
    var titleChanged: ((WmWindow) -> Void)?
    var output: ((WmWindow) -> Void)?
    var closed: ((Int) -> Void)?
    var suspendChanged: (() -> Void)?
    var ended: (() -> Void)?
    /// The answer to Drag: window, ok, label.
    var dragInfo: ((Int, Bool, String) -> Void)?

    // ---- file drops (files=1; WINDOWS.md "File drops", FILES_GFX.md step 3d) ----
    // These come whether or not the desk is up: the Files TRACE module uses them on a plain (not windowed) session.
    // RainwireFileDrops sets them.

    /// FileGo: send exactly these offered files (their n, in order), with no file dialog.
    var fileGo: (([Int]) -> Void)?
    /// FileNo: n (0 if it answers a DropOut), from (-1 if it answers an offer), reason.
    var fileNo: ((Int, Int, String) -> Void)?
    /// FileGet: the answer to DropOut. from, name, size (-1 if missing).
    var fileGet: ((Int, String, Int64) -> Void)?
    /// DragFile (module drags): module, ok, name, size (-1 if missing), reason.
    var dragFile: ((String, Bool, String, Int64, String) -> Void)?
    /// DragFile for a scene's row (scene=, after dragFile): the row, ok, the label and hint to show.
    var dragFileScene: ((Int, Bool, String, String) -> Void)?

    /// Handles one message from the board, as the native bridge queued it (without the prefix).
    func handle(_ body: [UInt8]) {
        if let m = WmMessage.parse(body) {
            handle(m)
        } else {
            WmSession.warnOnce("a malformed message", "\(body.count) bytes")
        }
    }

    func handle(_ m: WmMessage) {
        if m.verb == "Hello" {
            guard let v = m.int("v"), v >= 1 else { return }
            endDesk()   // a second Hello starts over
            active = true
            mode = m.get("mode")
            for f in started {
                f()
            }
            return
        }
        if handleFileVerb(m) {
            return
        }
        if !active {
            return
        }

        let id = m.int("id") ?? 0
        let win = windows[id]
        switch m.verb {
        case "Item":
            let itemId = m.get("id")
            if !itemId.isEmpty && itemId.count <= 64 && items.count < 64 && !items.contains(where: { $0.id == itemId }) {
                items.append(WmItem(id: itemId, key: m.get("key"), label: m.get("label")))
                itemsChanged?()
            }
        case "Open":
            guard win == nil, id > 0, windows.count < WmSession.maxWindows,
                  let w = m.int("w"), let h = m.int("h") else {
                WmSession.warnOnce("an Open", "id \(id), \(windows.count) windows open")
                return
            }
            let state = m.get("state")
            let font = m.get("font")
            let created = WmWindow(id: id, title: m.get("title"), x: m.int("x") ?? 0, y: m.int("y") ?? 0,
                                   state: state == "min" || state == "max" ? state : "normal",
                                   terminal: WmTerminal(w, h), font: font.utf16.count <= 64 ? font : "")
            created.terminal.reply = { [weak self] bytes in
                self?.input(id, bytes)
            }
            windows[id] = created
            focused = id
            opened?(created)
        case "Theme":
            theme = WmTheme.from(m)
            themeChanged?()
        case "Font":
            addFont(m)
        case "Title":
            if let win = win {
                win.title = m.get("title")
                titleChanged?(win)
            }
        case "Data":
            if let win = win, let data = m.data() {
                win.terminal.feed(data)
                output?(win)
            }
        case "Close":
            if win != nil {
                windows.removeValue(forKey: id)
                if focused == id {
                    focused = 0
                }
                closed?(id)
            }
        case "DragInfo":
            if win != nil {
                dragInfo?(id, m.get("ok") == "1", m.get("label"))
            }
        case "Suspend":
            if !suspended {
                suspended = true
                suspendChanged?()
            }
        case "Resume":
            if suspended {
                suspended = false
                suspendChanged?()
            }
        case "Bye":
            endDesk()
        default:
            break
        }
    }

    /// The file-drop verbs, taken in and out of windowed mode. True when m was one.
    private func handleFileVerb(_ m: WmMessage) -> Bool {
        switch m.verb {
        case "FileGo":
            var list: [Int] = []
            for part in m.get("n").split(separator: ",") {
                let t = part.trimmingCharacters(in: .whitespaces)
                if let n = Int(t), n > 0, n <= 100000, !list.contains(n) {
                    list.append(n)
                }
            }
            if !list.isEmpty {
                fileGo?(list)
            }
            return true
        case "FileNo":
            fileNo?(m.int("n") ?? 0, m.int("from") ?? -1, m.get("reason"))
            return true
        case "FileGet":
            fileGet?(m.int("from") ?? 0, m.get("name"), WmSession.parseSize(m.get("size")))
            return true
        case "DragFile":
            dragFile?(m.get("module"), m.get("ok") == "1", m.get("name"), WmSession.parseSize(m.get("size")),
                      m.get("reason"))
            if let row = Int(m.get("scene")), row > 0 {
                dragFileScene?(row, m.get("ok") == "1", m.get("label"), m.get("hint"))
            }
            return true
        default:
            return false
        }
    }

    /// A byte count (0 to 2^53-1), or -1.
    static func parseSize(_ s: String) -> Int64 {
        guard !s.isEmpty, s.utf8.count <= 16, s.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
              let v = Int64(s), v <= (Int64(1) << 53) - 1 else { return -1 }
        return v
    }

    /// The connection went: forget everything, quietly.
    func reset() {
        endDesk()
    }

    private func endDesk() {
        let was = active
        for id in Array(windows.keys) {
            windows.removeValue(forKey: id)
            closed?(id)
        }
        items.removeAll()
        fonts.removeAll()
        theme = WmTheme()
        active = false
        suspended = false
        mode = ""
        focused = 0
        if was {
            ended?()
        }
    }

    /// A font the board sent, once all of it has arrived; nil for the terminal's own.
    func fontNamed(_ name: String) -> WmFont? {
        guard !name.isEmpty, let f = fonts[name], f.got == f.font.data.count else { return nil }
        return f.font
    }

    /// One piece of a font: name, h (rows per glyph), at (byte offset) and b64, in order.
    private func addFont(_ m: WmMessage) {
        let name = m.get("name")
        guard !name.isEmpty, name.utf16.count <= 64, let h = m.int("h"), h >= 6, h <= 32,
              let at = m.int("at"), let data = m.data() else { return }
        var f: (font: WmFont, got: Int)
        if let have = fonts[name], have.font.height == h, at != 0 {
            f = have
        } else {
            if at != 0 || (fonts[name] == nil && fonts.count >= WmSession.maxFonts) {
                return
            }
            f = (WmFont(data: [UInt8](repeating: 0, count: 256 * h), height: h), 0)
        }
        if at != f.got || at + data.count > f.font.data.count {
            return   // out of order or too long: ignore it, the font stays incomplete
        }
        f.font.data.replaceSubrange(at..<(at + data.count), with: data)
        f.got += data.count
        fonts[name] = f
        if f.got == f.font.data.count {
            themeChanged?()
        }
    }

    // MARK: - To the board

    private func send(_ m: WmMessage) {
        if active {
            sendBytes(m.encode())
        }
    }

    /// The user resized a window: resize its terminal and tell the board, once, when the drag ends.
    func resized(_ id: Int, _ width: Int, _ height: Int) {
        guard let win = windows[id] else { return }
        let w = min(max(width, WmTerminal.minWidth), WmTerminal.maxWidth)
        let h = min(max(height, WmTerminal.minHeight), WmTerminal.maxHeight)
        if w == win.terminal.width && h == win.terminal.height {
            return
        }
        win.terminal.resize(w, h)
        send(WmMessage("Resized", "id", String(id), "w", String(w), "h", String(h)))
    }

    func moved(_ id: Int, _ x: Int, _ y: Int) {
        if windows[id] != nil {
            send(WmMessage("Moved", "id", String(id), "x", String(min(max(x, -99999), 99999)),
                           "y", String(min(max(y, -99999), 99999))))
        }
    }

    func setState(_ id: Int, _ state: String) {
        guard state == "normal" || state == "min" || state == "max", let win = windows[id], win.state != state else {
            return
        }
        win.state = state
        send(WmMessage("State", "id", String(id), "state", state))
    }

    func focusedWindow(_ id: Int) {
        if id == focused || windows[id] == nil {
            return
        }
        focused = id
        send(WmMessage("Focused", "id", String(id)))
    }

    /// The close button: ask, and wait for the board's Close.
    func requestClose(_ id: Int) {
        guard let win = windows[id], !win.closeRequested else { return }
        win.closeRequested = true
        send(WmMessage("Close", "id", String(id)))
    }

    /// A start menu choice. Only an item the board offered is ever sent.
    @discardableResult
    func launch(_ itemId: String) -> Bool {
        if !items.contains(where: { $0.id == itemId }) {
            return false
        }
        send(WmMessage("Launch", "item", itemId))
        return true
    }

    /// Keys and mouse reports for a window, in Input messages of at most 2048 bytes each.
    func input(_ id: Int, _ bytes: [UInt8]) {
        if windows[id] == nil || suspended {
            return
        }
        for m in WmMessage.dataMessages("Input", id, bytes) {
            send(m)
        }
    }

    /// A drag began at (x, y), 0-based cells in the window's content. The board answers DragInfo.
    func drag(_ id: Int, _ x: Int, _ y: Int) {
        if windows[id] != nil {
            send(WmMessage("Drag", "id", String(id), "x", String(x), "y", String(y)))
        }
    }

    /// One file of a batch dropped from the OS: on window id (0 the desktop) at (x, y) in its content cells, or, with
    /// module set, on that TRACE module at (x, y) in its frame pixels. Sent in and out of windowed mode.
    func fileOffer(_ n: Int, _ count: Int, _ id: Int, _ module: String?, _ x: Int, _ y: Int, _ name: String,
                   _ size: Int64, scene: Int = 0) {
        let m = WmMessage("FileOffer", "n", String(n), "count", String(count))
        if let module = module {
            m.args.append(("module", module))
        }
        if scene > 0 {   // dropped on a Rainwire scene's drop target (P_DROP): the Files module's drop, naming the block
            m.args.append(("scene", String(scene)))
        } else {
            m.args.append(("id", String(id)))
        }
        m.args.append(("x", String(min(max(x, -99999), 99999))))
        m.args.append(("y", String(min(max(y, -99999), 99999))))
        m.args.append(("name", name))
        m.args.append(("size", String(size)))
        sendBytes(m.encode())
    }

    /// A drag from window from (at x, y, as Drag said) let go on the OS desktop.
    func dropOut(_ from: Int, _ x: Int, _ y: Int) {
        sendBytes(WmMessage("DropOut", "from", String(from), "x", String(x), "y", String(y)).encode())
    }

    /// A drag out of a TRACE module (armed by DragFile) let go on the OS desktop.
    /// scene: the scene row it came from (Files as a scene), else 0.
    func dropOutModule(_ module: String, scene: Int = 0) {
        let m = WmMessage("DropOut", "module", module)
        if scene > 0 {
            m.args.append(("scene", String(scene)))
        }
        sendBytes(m.encode())
    }

    /// Dropped: the drag began at (x, y) in from and ended at (tx, ty) in to (0 for the desktop).
    func drop(_ from: Int, _ x: Int, _ y: Int, _ to: Int, _ tx: Int, _ ty: Int) {
        if windows[from] == nil {
            return
        }
        let target = to != 0 && windows[to] == nil ? 0 : to
        send(WmMessage("Drop", "from", String(from), "x", String(x), "y", String(y),
                       "to", String(target), "tx", String(tx), "ty", String(ty)))
    }
}
