import AppKit

/// One Rainwire window's content: its WmTerminal drawn with the main screen's own bitmap font, so boxes, blocks and
/// colours look exactly as they do on the main screen, scaled to the main screen's cell size. Takes the keyboard and
/// mouse for the window and sends them to the board as the window's input. Pressing and dragging (no modifier) starts
/// a Rainwire drag instead; if the board says there's nothing to drag there, the press and release go to the app as a
/// plain click.
///
/// Port of the Windows client's `RainwireWm/RainwireWindowSurface.cs`. macOS differences: the keyboard arrives from
/// TerminalKeyMonitor through `RainwireDesk.handleKey` while this view is the window's first responder (the main
/// terminal takes keys through performKeyEquivalent, which would otherwise see them first); Command keys stay
/// TERMinator's, as Alt keys do on Windows. Trackpad scrolling is turned into wheel notches (one per 20 points).
final class RainwireWindowSurfaceView: NSView {
    /// The app's first row is its header bar (the BBS name and the screen's title), which TERMinator's own title bar
    /// replaces, so it's kept out of sight: the surface shows rows 1 and down, and mouse rows count from there.
    static let hiddenRows = 1

    let win: WmWindow
    private let session: WmSession
    private weak var desk: RainwireDeskLayerView?
    private let font: () -> WmFont?
    private var pixels: [UInt32] = []
    private var image: CGImage?
    private var drawnVersion = -1
    private var drawnWithCursor = false
    private var redrawQueued = false
    private var wheelRemainder: CGFloat = 0

    // Mouse: a left press is held until we know whether it is a click or a drag
    private enum Press { case none, held, dragging, passing }
    private var press = Press.none
    private var pressCell = (x: 0, y: 0)
    private var dragOk: Bool?                // the board's answer, once it comes
    private var releasedAt: NSPoint?         // released before the answer came (desk coordinates)
    private var lastMotionCell = (x: -1, y: -1)
    private var dragLabelText = ""
    private var lastDragEvent: NSEvent?      // the newest mouseDragged, to start an OS drag from

    init(win: WmWindow, session: WmSession, desk: RainwireDeskLayerView, font: @escaping () -> WmFont?) {
        self.win = win
        self.session = session
        self.desk = desk
        self.font = font
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true   // redraw with the cursor
        return true
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .iBeam)
    }

    private var hasKeyboard: Bool { window?.firstResponder === self }

    /// The theme, font or smoothing changed: draw it all again.
    func refresh() {
        image = nil
        drawnVersion = -1
        needsDisplay = true
    }

    /// The window's output changed: redraw once the main thread gets to it.
    func markDirty() {
        if redrawQueued {
            return
        }
        redrawQueued = true
        DispatchQueue.main.async { [weak self] in
            self?.redrawQueued = false
            self?.needsDisplay = true
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        let t = win.terminal
        let f = font()
        let fh = f?.height ?? 16
        let pw = t.width * 8, ph = t.height * fh
        let cursor = hasKeyboard
        if image == nil || image?.width != pw || image?.height != ph || drawnVersion != t.version
            || drawnWithCursor != cursor {
            if pixels.count != pw * ph {
                pixels = [UInt32](repeating: 0, count: pw * ph)
            }
            paint(t, f, pw, fh, cursor)
            image = WmPaint.image(pixels, pw, ph)
            drawnVersion = t.version
            drawnWithCursor = cursor
        }
        guard let image = image else { return }
        let rowH = bounds.height / CGFloat(max(1, t.height - RainwireWindowSurfaceView.hiddenRows))
        let rect = NSRect(x: 0, y: -CGFloat(RainwireWindowSurfaceView.hiddenRows) * rowH, width: bounds.width,
                          height: CGFloat(t.height) * rowH)
        WmPaint.draw(image, in: rect)
    }

    private func paint(_ t: WmTerminal, _ f: WmFont?, _ pw: Int, _ fh: Int, _ cursor: Bool) {
        for cy in 0..<t.height {
            for cx in 0..<t.width {
                let cell = t[cx, cy]
                WmPaint.glyph(&pixels, pw, cx, cy, cell.ch, cell.fg | 0xFF000000, cell.bg | 0xFF000000, f, fh,
                              underline: cell.underline)
            }
        }
        for pic in t.pictures {
            let ox = pic.col * 8, oy = pic.row * fh
            var y = 0
            while y < pic.height && oy + y < t.height * fh {
                var x = 0
                while x < pic.width && ox + x < pw {
                    let p = pic.pixels[y * pic.width + x]
                    if p & 0xFF000000 != 0 {
                        pixels[(oy + y) * pw + ox + x] = p
                    }
                    x += 1
                }
                y += 1
            }
        }
        if cursor && t.cursorVisible && t.cursorX < t.width && t.cursorY < t.height {
            // An underline cursor in the cell's text colour, as the main screen shows it
            let fg = t[t.cursorX, t.cursorY].fg | 0xFF000000
            for row in max(0, fh - 2)..<fh {
                for col in 0..<8 {
                    pixels[(t.cursorY * fh + row) * pw + t.cursorX * 8 + col] = fg
                }
            }
        }
    }

    // MARK: - Keyboard

    /// A key from TerminalKeyMonitor while this window has the keyboard: true when it's taken (anything but a
    /// Command shortcut, so no key falls through to the main screen behind).
    func handleKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if flags.contains(.command) {
            return false   // Command keys are TERMinator's own (menus, full screen), as Alt keys are on Windows
        }
        let control = flags.contains(.control)
        let shift = flags.contains(.shift)

        // Window keys: Ctrl+Tab and Ctrl+Shift+Tab switch windows, Ctrl+F4 closes this one
        if event.keyCode == 48 && control {
            desk?.cycleFocus(forward: !shift)
            return true
        }
        if event.keyCode == 118 && flags == .control {
            session.requestClose(win.id)
            return true
        }

        var seq: String?
        switch event.keyCode {
        case 36, 76: seq = "\r"                        // Return, keypad Enter
        case 51: seq = "\u{08}"                        // Backspace
        case 48: seq = shift ? "\u{1B}[Z" : "\t"       // Tab
        case 53: seq = "\u{1B}"                        // Escape
        case 126: seq = "\u{1B}[A"
        case 125: seq = "\u{1B}[B"
        case 124: seq = "\u{1B}[C"
        case 123: seq = "\u{1B}[D"
        case 115: seq = "\u{1B}[H"                     // Home
        case 119: seq = "\u{1B}[F"                     // End
        case 114: seq = "\u{1B}[2~"                    // Insert (Help)
        case 117: seq = "\u{1B}[3~"                    // Forward Delete
        case 116: seq = "\u{1B}[5~"                    // Page Up
        case 121: seq = "\u{1B}[6~"                    // Page Down
        case 122: seq = "\u{1B}OP"                     // F1
        case 120: seq = "\u{1B}OQ"                     // F2
        case 99: seq = "\u{1B}OR"                      // F3
        case 118: seq = "\u{1B}OS"                     // F4
        case 96: seq = "\u{1B}[15~"                    // F5
        case 97: seq = "\u{1B}[17~"                    // F6
        case 98: seq = "\u{1B}[18~"                    // F7
        case 100: seq = "\u{1B}[19~"                   // F8
        case 101: seq = "\u{1B}[20~"                   // F9
        case 109: seq = "\u{1B}[21~"                   // F10
        case 103: seq = "\u{1B}[23~"                   // F11
        case 111: seq = "\u{1B}[24~"                   // F12
        default: break
        }
        if seq == nil && flags == .control, let key = event.charactersIgnoringModifiers?.lowercased().first {
            if let a = key.asciiValue, key >= "a" && key <= "z" {
                seq = String(UnicodeScalar(a - 96))    // Ctrl+A..Z: 0x01-0x1A
            } else if key == "[" {
                seq = "\u{1B}"
            }
        }
        if let seq = seq {
            session.input(win.id, Array(seq.utf8))
            return true
        }
        // Typed text (Shift, Option and dead keys already applied), as CP437 bytes
        if !control, let chars = event.characters {
            let bytes = chars.compactMap { Cp437.fromChar($0) }
            if !bytes.isEmpty {
                session.input(win.id, bytes)
            }
        }
        return true
    }

    override func keyDown(with event: NSEvent) {
        // Keys arrive through handleKey; anything that still gets here is dropped rather than beeping
    }

    // MARK: - Mouse

    /// The 0-based cell under a point in this view.
    func cellAt(_ p: NSPoint) -> (x: Int, y: Int) {
        let t = win.terminal
        let cw = bounds.width / CGFloat(t.width)
        let ch = bounds.height / CGFloat(max(1, t.height - RainwireWindowSurfaceView.hiddenRows))
        let x = Int((p.x / max(cw, 1e-6)).rounded(.down))
        let y = Int((p.y / max(ch, 1e-6)).rounded(.down)) + RainwireWindowSurfaceView.hiddenRows
        return (min(max(x, 0), t.width - 1), min(max(y, RainwireWindowSurfaceView.hiddenRows), t.height - 1))
    }

    private func report(_ button: Int, _ cell: (x: Int, y: Int), _ pressed: Bool) {
        let t = win.terminal
        if !t.mouseReporting {
            return
        }
        let x = cell.x + 1, y = cell.y + 1   // mouse reports are 1-based within the window
        let b: [UInt8]
        if t.mouseSgr {
            b = Array("\u{1B}[<\(button);\(x);\(y)\(pressed ? "M" : "m")".utf8)
        } else {
            let code = pressed ? button : 3
            b = [0x1B, UInt8(ascii: "["), UInt8(ascii: "M"), UInt8(32 + code), UInt8(min(32 + x, 255)), UInt8(min(32 + y, 255))]
        }
        session.input(win.id, b)
    }

    private func point(_ event: NSEvent) -> NSPoint { convert(event.locationInWindow, from: nil) }

    private func deskPoint(_ event: NSEvent) -> NSPoint {
        desk?.convert(event.locationInWindow, from: nil) ?? .zero
    }

    private func focusHere() {
        if window?.firstResponder !== self {
            window?.makeFirstResponder(self)
        }
        desk?.activate(win.id)
    }

    override func mouseDown(with event: NSEvent) {
        focusHere()
        let cell = cellAt(point(event))
        if event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
            // Held until it's either a click (released in place) or a drag (moved to another cell)
            press = .held
            pressCell = cell
            dragOk = nil
            releasedAt = nil
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        focusHere()
        report(2, cellAt(point(event)), true)
    }

    override func otherMouseDown(with event: NSEvent) {
        focusHere()
        if event.buttonNumber == 2 {
            report(1, cellAt(point(event)), true)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let cell = cellAt(point(event))
        lastDragEvent = event
        switch press {
        case .held where cell != pressCell:
            // Moved off the cell it was pressed in: a drag. The board says what, if anything, is there.
            press = .dragging
            session.drag(win.id, pressCell.x, pressCell.y)
        case .dragging where dragOk == true:
            if tryDragOut(event) {
                break
            }
            desk?.moveDragLabel(deskPoint(event))
        case .passing where win.terminal.mouseMotion && cell != lastMotionCell:
            // A drag the app wants (button-motion reporting): button 0 plus motion
            lastMotionCell = cell
            report(32, cell, true)
        default:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        let cell = cellAt(point(event))
        switch press {
        case .held:
            report(0, pressCell, true)
            report(0, cell, false)
            endPress()
        case .dragging where dragOk == nil:
            releasedAt = deskPoint(event)   // finish when the board answers
        case .dragging:
            finishDrag(deskPoint(event))
        case .passing:
            report(0, cell, false)
            endPress()
        case .none:
            break
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        report(2, cellAt(point(event)), false)
    }

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 {
            report(1, cellAt(point(event)), false)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let dy = event.scrollingDeltaY
        if dy == 0 {
            return
        }
        let cell = cellAt(point(event))
        if event.hasPreciseScrollingDeltas {
            // A trackpad sends a stream of small deltas: one wheel report per 20 points, like the scrollback
            wheelRemainder += dy
            while abs(wheelRemainder) >= 20 {
                report(wheelRemainder > 0 ? 64 : 65, cell, true)
                wheelRemainder -= wheelRemainder > 0 ? 20 : -20
            }
        } else {
            report(dy > 0 ? 64 : 65, cell, true)
        }
    }

    /// The board's answer to our Drag.
    func onDragInfo(_ ok: Bool, _ label: String) {
        if press != .dragging || dragOk != nil {
            return
        }
        dragOk = ok
        if ok {
            if let desk = desk, let w = window {
                desk.showDragLabel(label, at: desk.convert(w.mouseLocationOutsideOfEventStream, from: nil))
            }
            dragLabelText = label
            if let at = releasedAt {
                finishDrag(at)
            } else {
                // Already outside the window? Not from inside the WM poll's pass: start it on the next turn
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.press == .dragging, self.dragOk == true,
                          NSEvent.pressedMouseButtons & 1 != 0, let e = self.lastDragEvent else { return }
                    _ = self.tryDragOut(e)
                }
            }
        } else {
            // Nothing to drag there: it was a click (or a drag the app wants) after all
            press = .passing
            report(0, pressCell, true)
            if let at = releasedAt, let desk = desk {
                report(0, cellAt(convert(at, from: desk)), false)
                endPress()
            }
        }
    }

    /// File drops (item 13): the drag has left the TERMinator window with the button down. It becomes an OS drag;
    /// let go on the OS, the board hears DropOut (RainwireFileDrops). Nothing goes to the app either way. The OS drag
    /// runs on its own from here (NSDraggingSession), so this view sees no mouseUp for this press.
    private func tryDragOut(_ event: NSEvent) -> Bool {
        guard let dragOut = RainwireDesk.shared.dragOutOfWindow, RainwireFileDrops.pointerOutsideWindow(self) else {
            return false
        }
        let cell = pressCell
        press = .none
        desk?.hideDragLabel()
        _ = dragOut(win.id, cell.x, cell.y, dragLabelText, self, event)
        endPress()
        return true
    }

    private func finishDrag(_ deskPoint: NSPoint) {
        if dragOk == true, let desk = desk {
            let target = desk.dropTarget(deskPoint)
            session.drop(win.id, pressCell.x, pressCell.y, target.to, target.x, target.y)
        }
        endPress()
    }

    private func endPress() {
        press = .none
        desk?.hideDragLabel()
    }
}
