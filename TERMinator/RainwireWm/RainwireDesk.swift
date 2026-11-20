import AppKit

/// Rainwire's client-drawn windows (Rainwire docs/WINDOWS.md, protocol v1): the compositor. A Rainwire board asks at
/// connect whether this terminal draws windows itself; Bridge/apc/wm_bridge.c says yes (framed mode, no extra SSH
/// channels) and queues the board's messages, which this takes on the main thread and hands to WmSession. The desk
/// layer (RainwireDeskLayerView, in TerminalView's ZStack over the TRACE layer) draws the windows over the main screen.
///
/// Port of the Windows client's `RainwireWm/RainwireDesk.cs`. macOS differences:
/// * One shared desk for the app (each BBS is its own app instance, §12.57), because SwiftUI may re-create the layer
///   view; the layer attaches to the session and rebuilds its frames from it.
/// * TerminalViewModel.pollData calls `poll()` right after the TRACE queue, so window messages are taken in the same
///   pass as the data that carried them. That pass stops while a transfer holds the data (ZMODEM), so while a board's
///   desk is up a 15 ms timer of our own (Windows' poll timer) takes the queue whenever pollData hasn't lately.
///   Both run on the main thread and drain the same queue (wm_bridge.c locks it) oldest first, so whichever runs
///   takes the next messages in order and the other finds fewer or none.
/// * The keyboard comes from TerminalKeyMonitor (one app-wide NSEvent monitor, as for TRACE), which hands a key to
///   `handleKey` first; it goes to the window whose surface is the first responder.
final class RainwireDesk {
    static let shared = RainwireDesk()

    let session: WmSession
    private var buffer = [CChar](repeating: 0, count: 16384)
    private(set) var font: WmFont?
    private var enabled = false
    /// The fallback poll (Windows' 15 ms DispatcherTimer), while a desk is up.
    private var pollTimer: Timer?
    private var lastPoll: TimeInterval = 0
    private var polling = false
    /// The layer drawing the desk, while TerminalView is on screen.
    weak var layer: RainwireDeskLayerView?

    private init() {
        session = WmSession(send: WmNative.send)
        // The session's events go to whichever layer view is drawing the desk (Windows: the layer subscribes)
        // While no layer is attached (SwiftUI re-creating TerminalView) these find nil and do nothing: the session
        // keeps the windows, and the next layer's rebuild() brings them up as these events would have
        session.started.append { [weak self] in
            self?.font = RainwireDesk.loadFont()
            self?.startPollTimer()
            self?.layer?.sessionStarted()
        }
        session.themeChanged = { [weak self] in self?.layer?.onThemeChanged() }
        session.ended = { [weak self] in
            self?.stopPollTimer()
            self?.layer?.endDesk()
        }
        session.opened = { [weak self] win in self?.layer?.onOpened(win) }
        session.closed = { [weak self] id in self?.layer?.onClosed(id) }
        session.titleChanged = { [weak self] win in self?.layer?.onTitleChanged(win) }
        session.output = { [weak self] win in self?.layer?.onOutput(win) }
        session.suspendChanged = { [weak self] in self?.layer?.onSuspendChanged() }
        session.dragInfo = { [weak self] id, ok, label in self?.layer?.onDragInfo(id, ok, label) }
    }

    /// Switches the protocol on in the native bridge (TerminalView.onAppear, before connecting). Once is enough.
    func enable() {
        guard !enabled else { return }
        enabled = true
        WmNative.enable(true)
    }

    /// A board's windows are on screen.
    var active: Bool { session.active }

    /// A layer view attached (RainwireDeskLayerView.init): a desk already running needs the timer too.
    func layerAttached() {
        if session.active {
            startPollTimer()
        }
    }

    private func startPollTimer() {
        guard pollTimer == nil else { return }
        // .common, so it keeps firing under a modal transfer window or a menu, as Windows' timer does
        let t = Timer(timeInterval: 0.015, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if ProcessInfo.processInfo.systemUptime - self.lastPoll >= 0.015 {
                self.poll()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    private func stopPollTimer() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// A drag the board said ok to (DragInfo) left the TERMinator window with the button down: start the OS drag
    /// (from, x, y as Drag said, the label; the view and mouse event it starts from). True if it started. Set by
    /// RainwireFileDrops (files=1). Windows: RainwireDeskLayer.DragOutOfWindow (the layer view can be re-created
    /// here, so the hook lives on the desk).
    var dragOutOfWindow: ((Int, Int, Int, String, NSView, NSEvent) -> Bool)?

    /// Everything queued since the last pass, in order; a burst of window output can be many messages.
    func poll() {
        // Not re-entered: a handler that spins the run loop (a drag session starting) must not take later messages
        // ahead of the one it's handling
        guard enabled, !polling else { return }
        polling = true
        defer {
            polling = false
            lastPoll = ProcessInfo.processInfo.systemUptime
        }
        for _ in 0..<4096 {
            let n = WmNative.poll(&buffer)
            if n == -1 {
                buffer = [CChar](repeating: 0, count: buffer.count * 2)
                continue
            }
            if n <= 0 {
                return
            }
            // A bad message from a board must never take the terminal down. Swift can't catch a trap as Windows'
            // try/catch does, so instead WmMessage.parse refuses anything malformed and every handler below clamps or
            // ignores what's out of range (WmSession.warnOnce logs it).
            session.handle(buffer[0..<n].map { UInt8(bitPattern: $0) })
        }
    }

    /// After a transfer's dialog: the keyboard back to the top window (see RainwireDeskLayerView.refocusAfterDialog).
    func refocusAfterDialog() {
        layer?.refocusAfterDialog()
    }

    /// The connection went: drop the desk and anything queued.
    func reset() {
        session.reset()
        stopPollTimer()
        font = nil
    }

    /// A key while the terminal owns the keyboard (TerminalKeyMonitor): true when a Rainwire window, or the open
    /// start menu, took it.
    func handleKey(_ event: NSEvent) -> Bool {
        guard session.active, !session.suspended else { return false }
        switch event.window?.firstResponder {
        case let surface as RainwireWindowSurfaceView:
            return surface.handleKey(event)
        case let cells as WmCellView:
            return cells.onKey?(event) ?? false
        default:
            return false
        }
    }

    private static func loadFont() -> WmFont? {
        guard let info = NativeBridge.shared.getFontBitmap(), info.width == 8,
              info.height > 0, info.height <= 32, info.data.count >= 256 * info.height else { return nil }
        return WmFont(data: [UInt8](info.data), height: info.height)
    }
}
