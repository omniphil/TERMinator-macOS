import AppKit

/// xterm mouse reporting for the main terminal, as SyncTERM does it. When a board or door turns the mouse on
/// (CSI ? 1000 h, 1002, 1003, 9, with 1006 for SGR), clicks, drags and the wheel over the terminal go to it as
/// mouse reports (Bridge/mouse_bridge.c encodes and sends them); otherwise the mouse is TERMinator's own, exactly as
/// before: left-drag selects, a click opens a URL, the wheel scrolls back, right-click opens the context menu. Shift
/// always keeps the mouse for TERMinator, so Shift+drag still selects (and Shift+right-click still opens the menu)
/// while a board has the mouse.
///
/// Port of the Windows client's `Controls/TerminalMouse.cs`, which listens to the canvas's Preview mouse events. Here
/// `TerminalMouseTrackingView` (the transparent view over the terminal that already takes its mouse) asks this first
/// and skips its own handling when the board took the event. Layers above it (TRACE modules, Rainwire's windows, the
/// transfer box) are hit first and keep their mouse; `overlayOwnsPointer` keeps tracking-area moves from reaching the
/// board through them. macOS differences: a click while scrolled back returns to the live screen only while the
/// board has the mouse (without it, the click selects in scrollback as before); a trackpad's wheel stream becomes one
/// report per 20 points, a mouse wheel one per event.
final class TerminalMouse {
    private typealias R = TerminalMouseRules

    /// TerminalView.onAppear: switches reporting on in the bridge (Windows: TerminalCanvas's constructor).
    static func enable() {
        native_mouse_set_enabled(1)
    }

    // What the tracking view's owner (TerminalView) knows: the cell under a point, the screen size, scrollback
    var cellAt: ((NSPoint) -> (col: Int, row: Int))?
    var screenSize: (() -> (cols: Int, rows: Int))?
    var isScrolledBack: (() -> Bool)?
    /// A board's OSC 8 link at a 0-based cell (12.62): a left click there is the terminal's (it opens the link)
    var isLinkCell: ((Int, Int) -> Bool)?
    var returnToLive: (() -> Void)?
    var cancelSelection: (() -> Void)?

    private var held = 0                    // a bit per button (left, middle, right) whose press went to the board
    private var swallowed = 0               // a bit per button whose press returned to the live screen
    private var last = (x: -1, y: -1)       // the last cell reported, so a move within a cell sends nothing
    private var wheelRemainder: CGFloat = 0
    private var observer: NSObjectProtocol?

    init() {
        // Switching away mid-press (Windows: LostMouseCapture): the board hears the buttons go up
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            self?.releaseAll()
        }
    }

    deinit {
        if let observer = observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private static func mode() -> Int { R.mode(Int(native_mouse_mode())) }

    private static func send(_ kind: Int, _ button: Int, _ cell: (x: Int, y: Int)) {
        _ = native_mouse_event(Int32(kind), Int32(button), Int32(cell.x), Int32(cell.y))
    }

    private func cell(_ point: NSPoint) -> (x: Int, y: Int)? {
        guard let cellAt = cellAt, let size = screenSize?() else { return nil }
        let c = cellAt(point)
        return R.reportCell(c.col, c.row, size.cols, size.rows)
    }

    private static func shift(_ event: NSEvent) -> Bool { event.modifierFlags.contains(.shift) }

    /// A press (left, middle or right). True when it went to the board (or returned to the live screen) and the
    /// terminal must not act on it.
    func down(_ button: Int, at point: NSPoint, event: NSEvent) -> Bool {
        let mode = TerminalMouse.mode()
        let scrolledBack = isScrolledBack?() ?? false
        if !R.pressToBoard(mode, button, shift: TerminalMouse.shift(event), scrolledBack: scrolledBack) {
            if mode != R.off && scrolledBack && !TerminalMouse.shift(event) && button >= R.left && button <= R.right {
                // While scrolled back, a click returns to the live screen (it isn't sent to the board)
                returnToLive?()
                swallowed |= 1 << button
                return true
            }
            return false
        }
        guard let cell = cell(point) else { return false }
        if button == R.left, isLinkCell?(cell.x - 1, cell.y - 1) == true {
            return false   // a click on a board's OSC 8 link is ours, never reported (12.62)
        }
        cancelSelection?()
        held |= 1 << button
        last = cell
        TerminalMouse.send(R.press, button, cell)
        return true
    }

    /// A release. True when its press was the board's (or was swallowed), so the terminal must not act on it.
    func up(_ button: Int, at point: NSPoint) -> Bool {
        guard button >= R.left, button <= R.right else { return false }
        if swallowed & (1 << button) != 0 {
            swallowed &= ~(1 << button)
            return true
        }
        if held & (1 << button) == 0 {
            return false   // not a press the board had (Shift+click, or before it turned the mouse on)
        }
        held &= ~(1 << button)
        TerminalMouse.send(R.release, button, cell(point) ?? last)
        return true
    }

    /// A move with a button down. True while the board has a button held (no selection then).
    func dragged(at point: NSPoint, event: NSEvent) -> Bool {
        moved(at: point, event: event)
        return held != 0 || swallowed != 0
    }

    /// A move: reported in any-event tracking, and with a button held in button-event tracking.
    func moved(at point: NSPoint, event: NSEvent) {
        guard R.moveToBoard(TerminalMouse.mode(), anyHeld: held != 0, shift: TerminalMouse.shift(event)),
              let cell = cell(point), cell != last else { return }
        last = cell
        TerminalMouse.send(R.move, R.moveButton(held), cell)
    }

    /// The wheel. True when it went to the board.
    func wheel(_ event: NSEvent, at point: NSPoint) -> Bool {
        guard R.wheelToBoard(TerminalMouse.mode(), shift: TerminalMouse.shift(event),
                             scrolledBack: isScrolledBack?() ?? false) else { return false }
        let dy = event.scrollingDeltaY
        guard dy != 0, let cell = cell(point) else { return true }
        if event.hasPreciseScrollingDeltas {
            wheelRemainder += dy
            while abs(wheelRemainder) >= 20 {
                TerminalMouse.send(R.press, wheelRemainder > 0 ? R.wheelUp : R.wheelDown, cell)
                wheelRemainder -= wheelRemainder > 0 ? 20 : -20
            }
        } else {
            TerminalMouse.send(R.press, dy > 0 ? R.wheelUp : R.wheelDown, cell)
        }
        return true
    }

    /// Nothing may stay held on the board's side.
    func releaseAll() {
        for b in R.left...R.right where held & (1 << b) != 0 {
            TerminalMouse.send(R.release, b, last)
        }
        held = 0
        swallowed = 0
    }

    /// True when a layer over the terminal that keeps its own mouse (a Rainwire window, a TRACE module) is under the
    /// pointer: tracking-area moves reach the terminal's tracking view even there.
    static func overlayOwnsPointer(_ event: NSEvent) -> Bool {
        guard let content = event.window?.contentView else { return false }
        let p = content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
        var v = content.hitTest(p)
        while let cur = v {
            if cur is RainwireDeskLayerView || cur is EngineHostLayerView || cur is RainwireMenuView {
                return true
            }
            v = cur.superview
        }
        return false
    }
}
