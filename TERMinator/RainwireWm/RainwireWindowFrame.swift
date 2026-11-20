import AppKit

/// The frame around one of the board's windows, drawn as cells in the board's theme exactly as Rainwire's
/// server-drawn desktop draws it: a title row (the title, then minimize, maximize and close on the right), the frame
/// down the sides and along the bottom, a resize grip in the bottom right corner, and a shadow if the theme has one.
/// The window's content (RainwireWindowSurfaceView) sits inside. A window of w x h content cells is w+2 x h+1 cells
/// outside: the app's own header row hides under the title row.
///
/// Moving and resizing go in whole cells of the main screen and happen here with no round trip; the desk layer
/// tells the board the results (Moved, one Resized when a resize ends, State, Focused). The close button only asks:
/// the window goes when the board sends Close.
/// Port of the Windows client's `RainwireWm/RainwireWindowFrame.cs` (a WPF Canvas). AppKit sends the drags and the
/// release of a press to the view that took it, so there's no mouse capture to manage; where Windows ends a drag on
/// LostMouseCapture, `cancelDrag` does (the desk calls it when TERMinator loses the keyboard, and a drag whose button
/// is no longer down, or whose frame leaves the window, cancels itself).
///
/// The position, stacking order and restore rectangle live on the WmWindow, so a re-created desk layer puts the
/// frame back as it was.
final class RainwireWindowFrameView: NSView, RainwireStacked {
    var z: Int {
        get { surface.win.deskZ }
        set { surface.win.deskZ = newValue }
    }
    let surface: RainwireWindowSurfaceView
    private weak var desk: RainwireDeskLayerView?
    private let chrome: WmCellView
    // The graphical look (WmChrome.swift) draws under chrome, which stays as the click layer at alpha 0
    private let look: WmFrameChrome
    private var lookOutline: WmOutlineChrome?
    private var startOrigin = NSPoint.zero   // where the frame was when a move began
    private var focused = false
    private var maximized = false

    private enum Drag { case none, move, resize, button }
    private var drag = Drag.none
    private var dragStart = NSPoint.zero
    private var startX = 0, startY = 0, button = 0
    private var outline: WmCellView?
    private var outlineSize = (cols: 0, rows: 0)
    private var resizeW = false, resizeH = false   // which way the current resize goes (grip: both; an edge: one)
    private var resizeCursor = false               // a resize cursor is showing (set by chromeHover)

    var id: Int { surface.win.id }
    /// Where the frame's top-left corner is, in main-screen cells.
    var cellX: Int {
        get { surface.win.deskX ?? 0 }
        set { surface.win.deskX = newValue }
    }
    var cellY: Int {
        get { surface.win.deskY ?? 0 }
        set { surface.win.deskY = newValue }
    }
    /// Where it was and how big before it was maximized: cell position and content size.
    var restore: (x: Int, y: Int, cols: Int, rows: Int)? {
        get { surface.win.restore }
        set { surface.win.restore = newValue }
    }

    /// Outside size in cells, frame included, shadow not.
    var outerW: Int { surface.win.terminal.width + 2 }
    var outerH: Int { surface.win.terminal.height + 1 }

    override var isFlipped: Bool { true }

    init(surface: RainwireWindowSurfaceView, desk: RainwireDeskLayerView) {
        self.surface = surface
        self.desk = desk
        chrome = WmCellView(font: { [weak desk] in desk?.fontFor("") })
        look = WmFrameChrome(theme: { [weak desk] in desk?.theme ?? WmTheme() })
        super.init(frame: .zero)
        chrome.onMouseDown = { [weak self] e in self?.chromeDown(e) }
        chrome.onMouseDragged = { [weak self] e in self?.chromeMove(e) }
        chrome.onMouseUp = { [weak self] e in self?.chromeUp(e) }
        chrome.onMouseMoved = { [weak self] e in self?.chromeHover(e) }
        chrome.onMouseExited = { [weak self] _ in
            self?.setHover(-1)
            self?.setResizeCursor(false, false)
        }
        addSubview(look)
        addSubview(chrome)
        addSubview(surface)
        applyLook()
    }

    /// The look setting changed (or the frame is new): graphical, or the board's cells.
    func applyLook() {
        let g = WmLook.graphical
        look.isHidden = !g
        chrome.alphaValue = g ? 0 : 1
        redraw()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Only the chrome's drawn cells and the surface take the mouse; a clear shadow corner lets it through.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let v = super.hitTest(point)
        return v === self ? nil : v
    }

    func setTitle(_ title: String) { redraw() }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        // Closed, or the desk went, mid-drag: its mouseUp will never come here
        if newWindow == nil {
            cancelDrag()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override var isHidden: Bool {
        didSet {
            if isHidden {
                cancelDrag()   // minimized mid-drag (the taskbar can't be clicked then, but a board's State can)
            }
        }
    }

    func setFocused(_ f: Bool) {
        focused = f
        redraw()
    }

    func setMaximized(_ m: Bool) {
        maximized = m
        redraw()
    }

    /// Lays the frame out for its window's size at the main screen's cell size.
    func fit(cellW: CGFloat, cellH: CGFloat) {
        guard let desk = desk else { return }
        let t = surface.win.terminal
        let shadow = desk.theme.shadow != nil ? 1 : 0
        chrome.resize(outerW + shadow, outerH + shadow)
        let size = NSSize(width: CGFloat(outerW + shadow) * cellW, height: CGFloat(outerH + shadow) * cellH)
        setFrameSize(size)
        chrome.frame = NSRect(origin: .zero, size: size)
        surface.frame = NSRect(x: cellW, y: cellH, width: CGFloat(t.width) * cellW,
                               height: CGFloat(t.height - RainwireWindowSurfaceView.hiddenRows) * cellH)
        look.frame = NSRect(x: 0, y: 0, width: CGFloat(outerW) * cellW, height: CGFloat(outerH) * cellH)
        redraw()
    }

    /// The theme or font changed.
    func refresh() {
        chrome.refresh()
        surface.refresh()
    }

    /// Draws the frame's cells, as Rainwire's window manager does (internal/wm drawWindow).
    func redraw() {
        look.cols = outerW
        look.rows = outerH
        look.focused = focused
        look.max = maximized
        look.title = surface.win.title
        look.needsDisplay = true
        guard let th = desk?.theme else { return }
        let w = outerW, h = outerH
        if chrome.cols < w || chrome.rows < h {
            return   // not fitted yet
        }
        chrome.clear()
        let frameColour = focused ? th.frameFocus : th.frame
        let tfg = focused ? th.focusFg : th.titleFg, tbg = focused ? th.focusBg : th.titleBg
        if let sh = th.shadow {
            for y in 1...h {
                chrome.put(w, y, 0x20, sh, sh)
            }
            for x in 1...w {
                chrome.put(x, h, 0x20, sh, sh)
            }
        }
        for y in 1..<max(1, h - 1) {
            chrome.put(0, y, th.v, frameColour, th.bg)
            chrome.put(w - 1, y, th.v, frameColour, th.bg)
        }
        chrome.put(0, h - 1, th.bl, frameColour, th.bg)
        for x in 1..<max(1, w - 1) {
            chrome.put(x, h - 1, th.h, frameColour, th.bg)
        }
        chrome.put(w - 1, h - 1, maximized ? th.br : th.grip[0], frameColour, th.bg)

        // The title bar: the title on the left, the buttons on the right
        chrome.fill(0, 0, w, 1, tfg, tbg)
        let btns = RainwireWindowFrameView.buttons(th)
        let t = surface.win.title
        let title = WmTheme.cp(" " + (t.isEmpty ? "Rainwire" : t))
        let room = max(0, w - btns.count - 1)
        chrome.text(0, 0, Array(title.prefix(room)), tfg, tbg)
        chrome.text(w - btns.count, 0, btns, tfg, tbg)
        chrome.put(w - 2, 0, th.buttons[2], th.hot, tbg)
    }

    /// " _  □  × ": the buttons as the title row shows them.
    private static func buttons(_ th: WmTheme) -> [UInt8] {
        [0x20, th.buttons[0], 0x20, 0x20, th.buttons[1], 0x20, 0x20, th.buttons[2], 0x20]
    }

    /// Which title button is at column x of the title row: 0 minimize, 1 maximize, 2 close, -1 none.
    private func buttonAt(_ x: Int) -> Int {
        let from = outerW - 9
        if x < from {
            return -1
        }
        return min((x - from) / 3, 2)
    }

    // MARK: - The mouse on the frame

    private func setHover(_ b: Int) {
        if look.hover == b {
            return
        }
        look.hover = b
        look.needsDisplay = true
    }

    /// Under the pointer (no button down): a title button lights up. The tracking area sees the pointer under other
    /// windows too, so only when this frame's cells are what's on top there (Windows: MouseMove goes to the hit view).
    private func chromeHover(_ e: NSEvent) {
        if drag != .none && e.type == .mouseMoved {
            // AppKit sends mouseMoved only with no button down, after any mouseUp: this drag's release went elsewhere
            cancelDrag()
        }
        guard drag == .none else { return }
        var onTop = false
        if let desk = desk, let host = desk.superview {
            onTop = desk.hitTest(host.convert(e.locationInWindow, from: nil)) === chrome
        }
        let (x, y) = chrome.cellAt(chrome.convert(e.locationInWindow, from: nil))
        setHover(onTop && y == 0 && buttonAt(x) >= 0 ? buttonAt(x) : -1)
        // An edge shows which way it resizes
        let edge = onTop ? edgeAt(x, y) : (w: false, h: false)
        setResizeCursor(edge.w, edge.h)
    }

    /// What a press at cell (x, y) of the frame would resize: the grip both ways, an edge one way (2026-10-05).
    private func edgeAt(_ x: Int, _ y: Int) -> (w: Bool, h: Bool) {
        if maximized || y == 0 {
            return (false, false)
        }
        return (x == outerW - 1, y == outerH - 1)
    }

    /// Windows: SizeWE, SizeNS and SizeNWSE over the edges and the grip, the normal pointer elsewhere. AppKit has no
    /// public diagonal resize cursor before macOS 15; the grip keeps the arrow there.
    private func setResizeCursor(_ w: Bool, _ h: Bool) {
        if w && h {
            if #available(macOS 15.0, *) {
                NSCursor.frameResize(position: .bottomRight, directions: .all).set()
                resizeCursor = true
            } else if resizeCursor {
                NSCursor.arrow.set()
                resizeCursor = false
            }
        } else if w {
            NSCursor.resizeLeftRight.set()
            resizeCursor = true
        } else if h {
            NSCursor.resizeUpDown.set()
            resizeCursor = true
        } else if resizeCursor {
            NSCursor.arrow.set()
            resizeCursor = false
        }
    }

    private func deskPoint(_ e: NSEvent) -> NSPoint {
        desk?.convert(e.locationInWindow, from: nil) ?? .zero
    }

    private func chromeDown(_ e: NSEvent) {
        guard let desk = desk else { return }
        cancelDrag()   // a press with a drag still going: the last one's release never came
        desk.activate(id)
        let (x, y) = chrome.cellAt(chrome.convert(e.locationInWindow, from: nil))
        dragStart = deskPoint(e)
        if y == 0 && buttonAt(x) >= 0 {
            drag = .button
            button = buttonAt(x)
        } else if y == 0 {
            if e.clickCount == 2 {
                desk.toggleMaximize(self)
                return
            }
            drag = .move
            startX = cellX
            startY = cellY
            startOrigin = frame.origin
        } else if edgeAt(x, y).w || edgeAt(x, y).h {
            // The grip both ways; the right or bottom edge one way (2026-10-05)
            (resizeW, resizeH) = edgeAt(x, y)
            drag = .resize
            outlineSize = (surface.win.terminal.width, surface.win.terminal.height)
            if WmLook.graphical {
                let o = WmOutlineChrome(theme: { [weak desk] in desk?.theme ?? WmTheme() })
                o.z = Int.max
                desk.addSubview(o)
                lookOutline = o
            } else {
                let o = WmCellView(font: { [weak desk] in desk?.fontFor("") })
                o.passThrough = true
                o.z = Int.max
                desk.addSubview(o)
                outline = o
            }
            desk.restack()
            drawOutline()
        }
    }

    private func chromeMove(_ e: NSEvent) {
        guard drag == .move || drag == .resize, let desk = desk else { return }
        let p = deskPoint(e)
        let (cw, ch) = desk.cellSize()
        let dx = Int(((p.x - dragStart.x) / cw).rounded()), dy = Int(((p.y - dragStart.y) / ch).rounded())
        if drag == .move {
            cellX = startX + dx
            cellY = max(0, startY + dy)   // keep the title row reachable
            if WmLook.graphical {
                // The window follows the pointer smoothly and lands on the grid when let go (endDrag)
                setFrameOrigin(NSPoint(x: startOrigin.x + p.x - dragStart.x,
                                       y: max(startOrigin.y - CGFloat(startY) * ch, startOrigin.y + p.y - dragStart.y)))
            } else {
                desk.place(self)
            }
        } else {
            let t = surface.win.terminal
            outlineSize = (resizeW ? min(max(t.width + dx, WmTerminal.minWidth), WmTerminal.maxWidth) : t.width,
                           resizeH ? min(max(t.height + dy, WmTerminal.minHeight), WmTerminal.maxHeight) : t.height)
            drawOutline()
        }
    }

    private func chromeUp(_ e: NSEvent) {
        if drag == .button {
            let p = chrome.convert(e.locationInWindow, from: nil)
            let (x, y) = chrome.cellAt(p)
            let over = chrome.bounds.contains(p)
            let b = button
            endDrag(false)
            // Act on release over the same button, like a desktop
            if over && y == 0 && buttonAt(x) == b {
                if b == 0 {
                    desk?.minimize(self)
                } else if b == 1 {
                    desk?.toggleMaximize(self)
                } else {
                    desk?.requestClose(self)
                }
            }
        } else {
            endDrag(true)
        }
    }

    /// An interrupted drag (Windows: LostMouseCapture -> EndDrag(false)): a move goes back where it started, a resize
    /// drops its outline, and the board hears nothing. Nothing happens if there's no drag.
    func cancelDrag() {
        if drag == .none {
            return
        }
        if drag == .move {
            cellX = startX
            cellY = startY
        }
        endDrag(false)
    }

    private func endDrag(_ commit: Bool) {
        let was = drag
        drag = .none
        if was == .move {
            desk?.place(self)   // onto the grid, from wherever the smooth drag left it
        }
        if was == .move && commit && (cellX != startX || cellY != startY) {
            desk?.moved(self)
        }
        if was == .resize, let o = lookOutline {
            o.removeFromSuperview()
            lookOutline = nil
        }
        if was == .resize, let o = outline {
            o.removeFromSuperview()
            outline = nil
        }
        if was == .resize {
            setResizeCursor(false, false)
            let t = surface.win.terminal
            if commit && (outlineSize.cols != t.width || outlineSize.rows != t.height) {
                desk?.resize(self, cols: outlineSize.cols, rows: outlineSize.rows)
            }
        }
    }

    /// While resizing, only an outline in the theme's outline colour follows the pointer.
    private func drawOutline() {
        guard let desk = desk else { return }
        let (cw, ch) = desk.cellSize()
        let w = outlineSize.cols + 2, h = outlineSize.rows + 1
        if let lo = lookOutline {
            lo.cols = outlineSize.cols
            lo.rows = outlineSize.rows
            lo.frame = NSRect(x: frame.minX, y: frame.minY, width: CGFloat(w) * cw, height: CGFloat(h) * ch)
            lo.needsDisplay = true
            return
        }
        guard let o = outline else { return }
        let th = desk.theme
        o.resize(w, h)
        o.frame = NSRect(x: frame.minX, y: frame.minY, width: CGFloat(w) * cw, height: CGFloat(h) * ch)
        for x in 1..<max(1, w - 1) {
            o.put(x, 0, th.h, th.outline, 0)
            o.put(x, h - 1, th.h, th.outline, 0)
        }
        for y in 1..<max(1, h - 1) {
            o.put(0, y, th.v, th.outline, 0)
            o.put(w - 1, y, th.v, th.outline, 0)
        }
        o.put(0, 0, th.tl, th.outline, 0)
        o.put(w - 1, 0, th.tr, th.outline, 0)
        o.put(0, h - 1, th.bl, th.outline, 0)
        o.put(w - 1, h - 1, th.br, th.outline, 0)
    }
}
