import SwiftUI
import AppKit

/// Views on the desk stack by `z` (Windows: Panel.ZIndex); `RainwireDeskLayerView.restack` sorts by it.
protocol RainwireStacked: AnyObject {
    var z: Int { get }
}

/// The desk: the board's windows drawn over the main screen, which stays behind them as the desktop, with a taskbar
/// on the main screen's bottom row (the start button, then a button per window) and the start menu above it.
///
/// TERMinator is only the engine here. Everything is drawn as cells on the main screen's own grid, with the bitmap
/// font, in the colours and glyphs the board sent in its Theme (and a font it sent, if it names one), exactly as
/// Rainwire's server-drawn desktop looks. Windows sit and move in whole main-screen cells, so their text lines up
/// with the main screen's. Empty parts of the layer let the mouse through to the main screen.
///
/// What the user does here goes to the board through WmSession: Moved when a move ends, one Resized when a resize
/// ends, State on minimize, maximize and restore, Focused when a window comes to the front, Close from the close
/// button (the window goes when the board says so), Launch from the start menu, Drag and Drop between windows.
///
/// Port of the Windows client's `RainwireWm/RainwireDeskLayer.cs` (a WPF Canvas). Flipped, so y grows downwards as on
/// Windows. The main screen's picture origin, cell size and size in cells come from TerminalView (`setMetrics`), the
/// same numbers its TAP+ and TRACE overlays use (Windows reads them from the canvas's picture rect). The start menu's
/// mouse capture is a local event monitor while it's open; its keys come through RainwireDesk.handleKey. Font
/// smoothing follows the "font_smoothing" preference at every draw (Windows: ApplySmoothing), and the desk redraws
/// when the preferences change.
final class RainwireDeskLayerView: NSView {
    private let desk: RainwireDesk
    private var session: WmSession { desk.session }
    private var frames: [Int: RainwireWindowFrameView] = [:]
    private var opened: [Int] = []   // taskbar order
    private var taskbar: WmCellView!
    private var startMenu: WmCellView!
    private var dragLabel: WmCellView!
    private var zCounter = 1
    private var focusedId = 0
    /// The first setMetrics hasn't come yet: the frames for a running desk are built then, at the real screen size.
    private var needsRebuild = true
    /// A rebuilt desk gives its focused window the keyboard once the layer is in a window.
    private var refocusPending = false
    private var dragCancelObservers: [NSObjectProtocol] = []

    // Taskbar and start menu hit areas, in cells
    private var startHit = (from: 0, to: 0)
    private var taskHits: [(from: Int, to: Int, id: Int)] = []
    private var menuSel = -1   // -1: the start menu is shut
    private var startArmed = false   // the start button is pressed: the menu opens on the release over it
    private var menuMonitor: Any?
    private var defaultsObserver: NSObjectProtocol?
    // The graphical look (WmChrome.swift): drawn under the taskbar's and menu's cell views, which keep taking the clicks
    private var barLook: WmBarChrome!
    private var menuLook: WmMenuChrome!

    // The main screen's picture: top-left in this view, cell size (points), and size in cells
    private var screenOrigin = CGPoint.zero
    private var cellW: CGFloat = 8
    private var cellH: CGFloat = 16
    private var screenCols = 80
    private var screenRows = 25

    override var isFlipped: Bool { true }

    init(desk: RainwireDesk) {
        self.desk = desk
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        isHidden = true

        let font: () -> WmFont? = { [weak self] in self?.fontFor("") }
        taskbar = WmCellView(font: font)
        taskbar.z = Int.max - 3
        taskbar.onMouseDown = { [weak self] e in self?.taskbarDown(e) }
        taskbar.onMouseUp = { [weak self] e in self?.taskbarUp(e) }
        taskbar.onMouseMoved = { [weak self] e in self?.taskbarHover(e) }
        taskbar.onMouseExited = { [weak self] _ in self?.startHover(false) }
        addSubview(taskbar)
        let lookTheme: () -> WmTheme = { [weak self] in self?.theme ?? WmTheme() }
        barLook = WmBarChrome(theme: lookTheme)
        barLook.z = Int.max - 4
        addSubview(barLook)

        startMenu = WmCellView(font: font)
        startMenu.z = Int.max - 1
        startMenu.focusable = true
        startMenu.isHidden = true
        startMenu.onMouseMoved = { [weak self] e in self?.menuHover(e) }
        startMenu.onMouseDragged = { [weak self] e in self?.menuHover(e) }
        startMenu.onMouseUp = { [weak self] e in self?.menuClick(e) }
        startMenu.onMouseDown = { _ in }
        startMenu.onKey = { [weak self] e in self?.menuKey(e) ?? false }
        startMenu.onResignFocus = { [weak self] in self?.closeMenu() }
        addSubview(startMenu)
        // Just under the menu (Windows: same z, added before it)
        menuLook = WmMenuChrome(theme: lookTheme)
        menuLook.z = Int.max - 2
        menuLook.isHidden = true
        addSubview(menuLook)

        dragLabel = WmCellView(font: font)
        dragLabel.z = Int.max
        dragLabel.passThrough = true
        dragLabel.isHidden = true
        addSubview(dragLabel)

        // The Font smoothing preference: redraw everything with the new scaling (Windows: ApplySmoothing)
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                                                  object: nil, queue: .main) { [weak self] _ in
            self?.refreshAll()
            // The Graphical Windows setting (Windows: MainWindow calls ApplyLook after Settings are saved)
            if let self = self, RainwireDeskLayerView.graphicalSetting != WmLook.graphical {
                self.applyLook(RainwireDeskLayerView.graphicalSetting)
            }
        }

        // A move or resize the user can't finish (TERMinator lost the keyboard or went to the background) is
        // abandoned, not committed (Windows: LostMouseCapture -> EndDrag(false))
        let cancel: (Notification) -> Void = { [weak self] note in
            guard let self = self else { return }
            if note.name == NSWindow.didResignKeyNotification && note.object as? NSWindow !== self.window {
                return
            }
            self.cancelDrags()
        }
        for name in [NSWindow.didResignKeyNotification, NSApplication.didResignActiveNotification] {
            dragCancelObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main,
                                                                              using: cancel))
        }

        restack()
        desk.layer = self
        desk.layerAttached()
        applyLook(RainwireDeskLayerView.graphicalSetting)
        // rebuild() waits for the first setMetrics (makeNSView calls it next), so a desk built now fits the real screen
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    deinit {
        if let o = defaultsObserver {
            NotificationCenter.default.removeObserver(o)
        }
        if let m = menuMonitor {
            NSEvent.removeMonitor(m)
        }
        for o in dragCancelObservers {
            NotificationCenter.default.removeObserver(o)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            cancelDrags()
        } else if refocusPending {
            refocusRebuilt()
        }
    }

    /// Abandons any move or resize in progress: the frame goes back where it was and the board hears nothing.
    private func cancelDrags() {
        for f in frames.values {
            f.cancelDrag()
        }
    }

    /// Empty parts of the desk let the mouse through to the main screen.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let v = super.hitTest(point)
        return v === self ? nil : v
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if taskbar != nil {
            relayout()
        }
    }

    /// The main screen's geometry, from TerminalView's cell helpers.
    func setMetrics(originX: CGFloat, originY: CGFloat, cellWidth: CGFloat, cellHeight: CGFloat, columns: Int, rows: Int) {
        let o = CGPoint(x: originX, y: originY)
        let cw = cellWidth > 0 ? cellWidth : 8, ch = cellHeight > 0 ? cellHeight : 16
        let cols = max(1, columns), rws = max(2, rows)
        let first = needsRebuild
        needsRebuild = false
        if !first && o == screenOrigin && cw == cellW && ch == cellH && cols == screenCols && rws == screenRows {
            return
        }
        screenOrigin = o
        cellW = cw
        cellH = ch
        screenCols = cols
        screenRows = rws
        relayout()
        if first {
            rebuild()
        }
    }

    /// The board's look.
    var theme: WmTheme { session.theme }

    /// The font to draw with: a font the board sent by that name, else the one its theme names, else the terminal's
    /// own (the main screen's).
    func fontFor(_ name: String) -> WmFont? {
        session.fontNamed(name) ?? session.fontNamed(session.theme.font) ?? desk.font
    }

    private func refreshAll() {
        for f in frames.values {
            f.refresh()
        }
        taskbar.refresh()
        startMenu.refresh()
        dragLabel.refresh()
        barLook.needsDisplay = true
        menuLook.needsDisplay = true
    }

    /// Settings > Graphical Windows on Rainwire Boards (AppPreferences.rainwireGraphicalWindows, default on).
    static var graphicalSetting: Bool { UserDefaults.standard.bool(forKey: AppPreferences.rainwireGraphicalWindows) }

    /// The look setting changed: the graphical look, or the board's cells (WmChrome.swift).
    func applyLook(_ graphical: Bool) {
        WmLook.graphical = graphical
        taskbar.alphaValue = graphical ? 0 : 1
        startMenu.alphaValue = graphical ? 0 : 1
        barLook.isHidden = !graphical
        for f in frames.values {
            f.applyLook()
        }
        refreshTaskbar()
        if menuSel >= 0 {
            menuLook.isHidden = !graphical
            drawMenu()
        }
    }

    private func taskbarHover(_ e: NSEvent) {
        let (x, _) = taskbar.cellAt(taskbar.convert(e.locationInWindow, from: nil))
        startHover(x >= startHit.from && x < startHit.to)
    }

    private func startHover(_ over: Bool) {
        if barLook.startHover == over {
            return
        }
        barLook.startHover = over
        barLook.needsDisplay = true
    }

    // MARK: - Geometry: everything is in the main screen's cells

    /// One main-screen cell's size in points.
    func cellSize() -> (cellW: CGFloat, cellH: CGFloat) { (cellW, cellH) }

    /// Puts a frame at its cell position.
    func place(_ frame: RainwireWindowFrameView) {
        frame.setFrameOrigin(NSPoint(x: screenOrigin.x + CGFloat(frame.cellX) * cellW,
                                     y: screenOrigin.y + CGFloat(frame.cellY) * cellH))
    }

    /// The desk or the main screen changed size: everything again, on the grid.
    private func relayout() {
        for f in frames.values {
            f.fit(cellW: cellW, cellH: cellH)
            place(f)
        }
        refreshTaskbar()
        if menuSel >= 0 {
            drawMenu()
        }
    }

    /// Stacking order: windows by their z, then the taskbar, the menu, the outline and the drag label on top.
    func restack() {
        sortSubviews({ a, b, _ in
            let za = (a as? RainwireStacked)?.z ?? 0
            let zb = (b as? RainwireStacked)?.z ?? 0
            return za < zb ? .orderedAscending : (za > zb ? .orderedDescending : .orderedSame)
        }, context: nil)
    }

    // MARK: - Session events (routed here by RainwireDesk)

    func sessionStarted() {
        isHidden = false
        // The first Open usually comes in the same pass as Hello: lay out now, so window sizes see the desk's size
        superview?.layoutSubtreeIfNeeded()
        relayout()
    }

    func onThemeChanged() {
        refreshAll()
        relayout()   // a shadow may have come or gone
    }

    /// A re-created layer (SwiftUI rebuilt TerminalView) takes over a desk that's already running, and ends up as the
    /// Windows client's would (its layer is never rebuilt, so it saw every event): windows an earlier layer laid out
    /// come back where they were, in their stacking order, minimized or maximized as they were, with nothing sent;
    /// windows the board opened while no layer was up are taken now as their Open would have been (fitted to the
    /// desk, their state applied, the board told). Then the keyboard goes to the window the board last heard was
    /// focused, or the top one. The session holds everything, so events that came with no layer need no queue.
    private func rebuild() {
        guard session.active else { return }
        isHidden = session.suspended
        let wins = Array(session.windows.values)
        zCounter = max(zCounter, wins.map { $0.deskZ }.max() ?? 0)
        for win in wins.filter({ $0.deskX != nil }).sorted(by: { $0.deskZ < $1.deskZ }) {
            let frame = makeFrame(win)
            frame.fit(cellW: cellW, cellH: cellH)
            place(frame)
            frame.setMaximized(win.restore != nil)
            frame.isHidden = win.state == "min"
        }
        for win in wins.filter({ $0.deskX == nil }).sorted(by: { $0.id < $1.id }) {
            onOpened(win)
        }
        opened.sort()   // the taskbar in the order they opened
        refreshTaskbar()

        if let f = frames[session.focusedId], !f.isHidden {
            focusedId = f.id
        } else {
            focusedId = frames.values.filter({ !$0.isHidden }).max(by: { $0.z < $1.z })?.id ?? 0
        }
        for f in frames.values {
            f.setFocused(f.id == focusedId)
        }
        refreshTaskbar()
        refocusPending = true
        if window != nil {
            refocusRebuilt()
        }
    }

    /// The rebuilt desk's focused window takes the keyboard (it can't before the layer is in a window).
    private func refocusRebuilt() {
        refocusPending = false
        guard session.active, !session.suspended else { return }
        if let f = frames[focusedId], !f.isHidden {
            activate(f.id)
        } else {
            focusTopmostOrMain()
        }
    }

    private func makeFrame(_ win: WmWindow) -> RainwireWindowFrameView {
        let fontName = win.font
        let surface = RainwireWindowSurfaceView(win: win, session: session, desk: self,
                                                font: { [weak self] in self?.fontFor(fontName) })
        let frame = RainwireWindowFrameView(surface: surface, desk: self)
        frames[win.id] = frame
        opened.append(win.id)
        zCounter += 1
        frame.z = zCounter
        addSubview(frame)
        restack()
        return frame
    }

    func onOpened(_ win: WmWindow) {
        let frame = makeFrame(win)
        // The board suggests a size; fit it inside the desk if it's too big (the client decides), and say so.
        // The desk is every row but the taskbar's; a window is two columns and one row bigger than its content.
        let maxCols = max(WmTerminal.minWidth, screenCols - 2), maxRows = max(WmTerminal.minHeight, screenRows - 2)
        if win.terminal.width > maxCols || win.terminal.height > maxRows {
            session.resized(win.id, min(win.terminal.width, maxCols), min(win.terminal.height, maxRows))
        }
        frame.fit(cellW: cellW, cellH: cellH)
        frame.cellX = min(max(win.x, 0), max(0, screenCols - frame.outerW))
        frame.cellY = min(max(win.y, 0), max(0, screenRows - 1 - frame.outerH))
        place(frame)

        let state = win.state
        win.state = "normal"   // setState reports only changes: start from what the frame shows
        if state == "max" {
            toggleMaximize(frame)
        } else if state == "min" {
            minimize(frame)
        }
        refreshTaskbar()
        if state != "min" {
            activate(win.id)
        }
    }

    func onClosed(_ id: Int) {
        guard let frame = frames.removeValue(forKey: id) else { return }
        let hadKeyboard = window?.firstResponder === frame.surface
        frame.removeFromSuperview()
        opened.removeAll { $0 == id }
        refreshTaskbar()
        if focusedId == id || hadKeyboard {
            focusedId = 0
            focusTopmostOrMain()
        }
    }

    func onTitleChanged(_ win: WmWindow) {
        frames[win.id]?.setTitle(win.title)
        refreshTaskbar()
    }

    func onOutput(_ win: WmWindow) {
        frames[win.id]?.surface.markDirty()
    }

    func onDragInfo(_ id: Int, _ ok: Bool, _ label: String) {
        frames[id]?.surface.onDragInfo(ok, label)
    }

    // MARK: - Windows

    /// The keyboard goes back to the main screen (Windows: focusMain).
    private func focusMain() {
        if let r = window?.firstResponder as? NSView, r.isDescendant(of: self) {
            window?.makeFirstResponder(nil)
        }
    }

    private func focusTopmostOrMain() {
        if let top = frames.values.filter({ !$0.isHidden }).max(by: { $0.z < $1.z }) {
            activate(top.id)
        } else {
            focusMain()
        }
    }

    /// Brings a window to the front, gives it the keyboard, and tells the board.
    func activate(_ id: Int) {
        guard let frame = frames[id] else { return }
        if frame.isHidden {
            frame.isHidden = false
            session.setState(id, frame.restore != nil ? "max" : "normal")
        }
        zCounter += 1
        frame.z = zCounter
        restack()
        for f in frames.values {
            f.setFocused(f === frame)
        }
        focusedId = id
        if window?.firstResponder !== frame.surface {
            window?.makeFirstResponder(frame.surface)
        }
        session.focusedWindow(id)
        refreshTaskbar()
    }

    /// Ctrl+Tab: the next (or previous) window, by taskbar order.
    func cycleFocus(forward: Bool) {
        let order = frames.values.sorted { (opened.firstIndex(of: $0.id) ?? 0) < (opened.firstIndex(of: $1.id) ?? 0) }
        if order.isEmpty {
            return
        }
        let at = order.firstIndex { $0.id == focusedId } ?? 0
        let next = (at + (forward ? 1 : -1) + order.count) % order.count
        activate(order[next].id)
    }

    func minimize(_ frame: RainwireWindowFrameView) {
        frame.isHidden = true
        frame.setFocused(false)
        session.setState(frame.id, "min")
        if focusedId == frame.id {
            focusedId = 0
            focusTopmostOrMain()
        }
        refreshTaskbar()
    }

    func toggleMaximize(_ frame: RainwireWindowFrameView) {
        let t = frame.surface.win.terminal
        if let r = frame.restore {
            frame.restore = nil
            session.resized(frame.id, r.cols, r.rows)
            frame.cellX = r.x
            frame.cellY = r.y
            frame.setMaximized(false)
            session.setState(frame.id, "normal")
        } else {
            frame.restore = (frame.cellX, frame.cellY, t.width, t.height)
            // Every cell above the taskbar, as the server-drawn desktop maximizes
            session.resized(frame.id, screenCols - 2, screenRows - 2)
            frame.cellX = 0
            frame.cellY = 0
            frame.setMaximized(true)
            session.setState(frame.id, "max")
        }
        frame.fit(cellW: cellW, cellH: cellH)
        place(frame)
        frame.surface.markDirty()
    }

    /// The grip was released: the window takes its new size, and the board hears once.
    func resize(_ frame: RainwireWindowFrameView, cols: Int, rows: Int) {
        if frame.restore != nil {
            frame.restore = nil
            frame.setMaximized(false)
            session.setState(frame.id, "normal")
        }
        session.resized(frame.id, cols, rows)
        frame.fit(cellW: cellW, cellH: cellH)
        place(frame)
        frame.surface.markDirty()
    }

    /// A move ended: tell the board where, in main-screen cells, for the saved layout.
    func moved(_ frame: RainwireWindowFrameView) {
        session.moved(frame.id, frame.cellX, frame.cellY)
    }

    /// Moves a frame to a cell and tells the board, as a finished drag does.
    func moveTo(_ frame: RainwireWindowFrameView, _ x: Int, _ y: Int) {
        frame.cellX = x
        frame.cellY = max(0, y)
        place(frame)
        moved(frame)
    }

    func requestClose(_ frame: RainwireWindowFrameView) {
        session.requestClose(frame.id)
    }

    // MARK: - Suspend, resume, the end

    func onSuspendChanged() {
        // A full-screen program (a raw or TRACE door) runs on the main screen: the windows step aside until Resume
        closeMenu()
        isHidden = session.suspended
        if session.suspended {
            focusMain()
        } else {
            focusTopmostOrMain()
        }
    }

    /// A transfer's dialog (the file picker or the transfer window) just went. Resume usually came while it was still
    /// up, so the keyboard may have stayed where the dialog left it, which the board ignores while windows are open
    /// (Windows: RefocusAfterDialog, after the modal TransferDialog had kept keys on the main screen until a click).
    func refocusAfterDialog() {
        if session.active && !session.suspended {
            focusTopmostOrMain()
        }
    }

    func endDesk() {
        closeMenu()
        for id in Array(frames.keys) {
            onClosed(id)
        }
        hideDragLabel()
        isHidden = true
        focusMain()
    }

    // MARK: - The taskbar: the main screen's bottom row, as the server-drawn desktop draws it

    private func refreshTaskbar() {
        let th = theme
        let cols = screenCols
        taskbar.resize(cols, 1)
        taskbar.frame = NSRect(x: screenOrigin.x, y: screenOrigin.y + CGFloat(screenRows - 1) * cellH,
                               width: CGFloat(cols) * cellW, height: cellH)
        taskbar.fill(0, 0, cols, 1, th.barFg, th.barBg)
        barLook.frame = taskbar.frame
        barLook.cols = cols
        barLook.tasks = []
        barLook.needsDisplay = true

        // The graphical look's start button is just the menu mark and an R (sysop 2026-10-05), so it takes less room
        let start = WmLook.graphical
            ? WmTheme.cp(" ") + th.start + WmTheme.cp(" R ")
            : WmTheme.cp(" ") + th.start + WmTheme.cp(" ") + th.startText + WmTheme.cp(" ")
        let open = menuSel >= 0
        taskbar.text(0, 0, start, open ? th.selFg : th.hot, open ? th.selBg : th.barBg)
        startHit = (0, start.count)
        barLook.start = startHit
        barLook.menuOpen = open

        taskHits.removeAll()
        var x = start.count + 1
        let list = opened.filter { frames[$0] != nil }
        let room = cols - 2 - x
        if list.isEmpty || room < 6 {
            return
        }
        let each = min(22, room / list.count)
        var i = 0
        while i < list.count && each >= 5 {
            guard let frame = frames[list[i]] else { break }
            let digit = Character(UnicodeScalar(UInt8(ascii: "1") + UInt8(min(i, 8))))
            var label = WmTheme.cp(" \(digit) \(frame.surface.win.title)")
            if label.count > each - 1 {
                label = Array(label.prefix(each - 1))
            }
            var fg = th.barFg, bg = th.barBg
            let focused = list[i] == focusedId && !frame.isHidden
            if focused {
                fg = th.taskFg
                bg = th.taskBg
            } else if frame.isHidden {
                fg = th.dimFg
            }
            taskbar.fill(x, 0, each - 1, 1, fg, bg)
            taskbar.text(x, 0, label, fg, bg)
            taskHits.append((x, x + each - 1, list[i]))
            barLook.tasks.append(WmBarChrome.Task(from: x, to: x + each - 1, label: "\(digit)  \(frame.surface.win.title)",
                                                  focused: focused, minimized: frame.isHidden))
            x += each
            i += 1
        }
    }

    private func taskbarDown(_ e: NSEvent) {
        let (x, _) = taskbar.cellAt(taskbar.convert(e.locationInWindow, from: nil))
        if x >= startHit.from && x < startHit.to {
            // Opens on the release, as the Windows client does (sysop 2026-10-12); a press while it's open shuts it.
            // AppKit sends the release to the view that had the press.
            if menuSel >= 0 {
                closeMenu()
            } else {
                startArmed = true
            }
            return
        }
        for hit in taskHits {
            guard x >= hit.from, x < hit.to, let frame = frames[hit.id] else { continue }
            // The focused window's button minimizes it; any other brings that window up
            if hit.id == focusedId && !frame.isHidden {
                minimize(frame)
            } else {
                activate(hit.id)
            }
            return
        }
    }

    private func taskbarUp(_ e: NSEvent) {
        guard startArmed else { return }
        startArmed = false
        let p = taskbar.convert(e.locationInWindow, from: nil)
        let (x, _) = taskbar.cellAt(p)
        let over = taskbar.bounds.contains(p) && x >= startHit.from && x < startHit.to
        if over && menuSel < 0 {
            openMenu()   // let go anywhere else: nothing, as a button does
        }
    }

    // MARK: - The start menu: a box above the start button with the board's Items

    /// Opens the start menu, as the start button does.
    func openMenu() {
        if session.items.isEmpty {
            return
        }
        menuSel = 0
        startMenu.isHidden = false
        menuLook.isHidden = !WmLook.graphical
        drawMenu()
        refreshTaskbar()
        window?.makeFirstResponder(startMenu)
        // A press anywhere else shuts it, and is used up (Windows: the menu captures the mouse)
        if menuMonitor == nil {
            menuMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) {
                [weak self] event in
                guard let self = self, self.menuSel >= 0 else { return event }
                let p = self.startMenu.convert(event.locationInWindow, from: nil)
                if event.window === self.window && self.startMenu.bounds.contains(p) {
                    return event
                }
                self.closeMenu()
                return nil
            }
        }
    }

    private func closeMenu() {
        if menuSel < 0 {
            return
        }
        menuSel = -1
        startMenu.isHidden = true
        menuLook.isHidden = true
        if let m = menuMonitor {
            NSEvent.removeMonitor(m)
            menuMonitor = nil
        }
        refreshTaskbar()
        if let f = frames[focusedId], !f.isHidden {
            window?.makeFirstResponder(f.surface)
        } else if window?.firstResponder === startMenu {
            window?.makeFirstResponder(nil)
        }
    }

    private func drawMenu() {
        let th = theme
        let items = session.items
        var wid = th.menuText.count + 4
        for it in items {
            wid = max(wid, it.label.utf16.count + 8)
        }
        wid = min(wid, max(screenCols, 12))   // a board's long label is cut at the screen's edge, not drawn off it
        let h = items.count + 2
        startMenu.resize(wid, h)
        startMenu.frame = NSRect(x: screenOrigin.x, y: screenOrigin.y + CGFloat(max(0, screenRows - 1 - h)) * cellH,
                            width: CGFloat(wid) * cellW, height: CGFloat(h) * cellH)
        menuLook.frame = startMenu.frame
        menuLook.cols = wid
        menuLook.rows = h
        menuLook.selected = menuSel
        menuLook.items = items.map { (key: $0.key, label: $0.label) }
        menuLook.needsDisplay = true

        startMenu.fill(0, 0, wid, h, th.popFg, th.popBg)
        for x in 1..<max(1, wid - 1) {
            startMenu.put(x, 0, th.h, th.frameFocus, th.popBg)
            startMenu.put(x, h - 1, th.h, th.frameFocus, th.popBg)
        }
        for y in 1..<max(1, h - 1) {
            startMenu.put(0, y, th.v, th.frameFocus, th.popBg)
            startMenu.put(wid - 1, y, th.v, th.frameFocus, th.popBg)
        }
        startMenu.put(0, 0, th.tl, th.frameFocus, th.popBg)
        startMenu.put(wid - 1, 0, th.tr, th.frameFocus, th.popBg)
        startMenu.put(0, h - 1, th.bl, th.frameFocus, th.popBg)
        startMenu.put(wid - 1, h - 1, th.br, th.frameFocus, th.popBg)
        startMenu.text(2, 0, WmTheme.cp(" ") + th.menuText + WmTheme.cp(" "), th.hot, th.popBg)
        for (i, item) in items.enumerated() {
            var fg = th.popFg, bg = th.popBg
            if i == menuSel {
                fg = th.selFg
                bg = th.selBg
            }
            startMenu.fill(1, 1 + i, wid - 2, 1, fg, bg)
            startMenu.text(1, 1 + i, " \(item.key)  \(item.label)", fg, bg)
            startMenu.text(2, 1 + i, item.key, th.hot, bg)
        }
    }

    private func menuItemAt(_ e: NSEvent) -> Int {
        let p = startMenu.convert(e.locationInWindow, from: nil)
        if !startMenu.bounds.contains(p) {
            return -1
        }
        let (x, y) = startMenu.cellAt(p)
        let i = y - 1
        return x > 0 && x < startMenu.cols - 1 && i >= 0 && i < session.items.count ? i : -1
    }

    private func menuHover(_ e: NSEvent) {
        let i = menuItemAt(e)
        if menuSel >= 0 && i >= 0 && i != menuSel {
            menuSel = i
            drawMenu()
        }
    }

    private func menuClick(_ e: NSEvent) {
        let i = menuItemAt(e)
        if i >= 0 {
            pick(i)
        }
    }

    /// A key while the menu is open: arrows and Tab move, Return or Space picks, Escape shuts it, a hotkey picks its
    /// item. Any other key isn't the menu's and goes on as if the menu weren't there (Windows: e.Handled = false, so
    /// it reaches the terminal); Command keys stay the app's.
    private func menuKey(_ e: NSEvent) -> Bool {
        guard menuSel >= 0, e.type == .keyDown else { return false }
        if e.modifierFlags.contains(.command) {
            return false
        }
        let items = session.items
        if items.isEmpty {
            closeMenu()
            return true
        }
        switch e.keyCode {
        case 126:   // Up
            menuSel = (menuSel + items.count - 1) % items.count
            drawMenu()
            return true
        case 125, 48:   // Down, Tab
            menuSel = (menuSel + 1) % items.count
            drawMenu()
            return true
        case 36, 76, 49:   // Return, keypad Enter, Space
            pick(menuSel)
            return true
        case 53:   // Escape
            closeMenu()
            return true
        default:
            break
        }
        // A hotkey picks its item
        if let k = e.charactersIgnoringModifiers?.uppercased(), k.count == 1,
           let c = k.first, c.isASCII, c.isLetter || c.isNumber,
           let at = items.firstIndex(where: { $0.key.uppercased() == k }) {
            pick(at)
            return true
        }
        return false
    }

    private func pick(_ i: Int) {
        let items = session.items
        if i < 0 || i >= items.count {
            return
        }
        let id = items[i].id
        closeMenu()
        session.launch(id)
    }

    // MARK: - Drag and drop

    func showDragLabel(_ text: String, at point: NSPoint) {
        let th = theme
        let label = WmTheme.cp(" » " + text + " ")
        dragLabel.resize(label.count, 1)
        dragLabel.setFrameSize(NSSize(width: CGFloat(label.count) * cellW, height: cellH))
        dragLabel.text(0, 0, label, th.selFg, th.selBg)
        dragLabel.isHidden = false
        moveDragLabel(point)
    }

    func moveDragLabel(_ point: NSPoint) {
        dragLabel.setFrameOrigin(NSPoint(x: point.x + cellW, y: point.y + cellH))
    }

    func hideDragLabel() {
        dragLabel.isHidden = true
    }

    /// Where a drop landed: the topmost window under the point and the cell in it, or the desktop (0).
    func dropTarget(_ layerPoint: NSPoint) -> (to: Int, x: Int, y: Int) {
        for f in frames.values.filter({ !$0.isHidden }).sorted(by: { $0.z > $1.z }) {
            let p = f.surface.convert(layerPoint, from: self)
            if f.surface.bounds.contains(p) {
                let cell = f.surface.cellAt(p)
                return (f.id, cell.x, cell.y)
            }
        }
        return (0, 0, 0)
    }
}

/// SwiftUI wrapper: the desk over the terminal area (Windows MainWindow's `RainwireDeskHost` grid). Hidden, and so
/// invisible to the mouse, unless a Rainwire board has handed us its windows.
struct RainwireDeskLayer: NSViewRepresentable {
    let originX: CGFloat
    let originY: CGFloat
    let cellWidth: CGFloat
    let cellHeight: CGFloat
    let columns: Int
    let rows: Int

    func makeNSView(context: Context) -> RainwireDeskLayerView {
        let view = RainwireDeskLayerView(desk: RainwireDesk.shared)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ nsView: RainwireDeskLayerView, context: Context) {
        nsView.setMetrics(originX: originX, originY: originY, cellWidth: cellWidth, cellHeight: cellHeight,
                          columns: columns, rows: rows)
    }

    static func dismantleNSView(_ nsView: RainwireDeskLayerView, coordinator: ()) {
        if RainwireDesk.shared.layer === nsView {
            RainwireDesk.shared.layer = nil
        }
    }
}
