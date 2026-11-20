import AppKit
import Foundation

/// The idle timer behind the screensaver (spec §8): after **3 minutes** without mouse movement,
/// clicks or keys — checked every 5 s — the host is asked to show the screensaver, but only on a
/// **quiet home screen**. Mirrors the Windows client's `MainWindow.StartIdleWatch`.
///
/// Input is watched with one local `NSEvent` monitor that never swallows anything (the overlays do
/// their own key handling, see `KeyEventMonitor`). `NSWindow` only reports mouse-moved events when it
/// is asked to, so the watcher turns that on for the main window.
final class IdleWatcher: ObservableObject {
    /// Windows: `ScreensaverIdleTime`.
    static let idleTime: TimeInterval = 3 * 60
    private static let checkInterval: TimeInterval = 5

    /// Called on the main thread when the app has been idle long enough.
    var onIdle: (() -> Void)?
    /// The host's "quiet home screen" test: not connected, home screen showing, no overlay up.
    var isQuiet: (() -> Bool)?

    private var monitor: Any?
    private var timer: Timer?
    private var lastInput = Date()
    private var running = false

    deinit {
        stop()
    }

    func start() {
        guard !running else { return }
        running = true
        restart()

        WindowSizeManager.mainWindow?.acceptsMouseMovedEvents = true

        let mask: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .otherMouseDown,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel,
            .keyDown, .flagsChanged,
        ]
        monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.restart()
            return event      // never swallowed: this only watches
        }

        let timer = Timer(timeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            self?.check()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        timer?.invalidate()
        timer = nil
        running = false
    }

    /// Restarts the countdown. Also called when the screensaver is enabled in the View menu and when
    /// a running saver finishes.
    func restart() {
        lastInput = Date()
    }

    private func check() {
        guard UserDefaults.standard.bool(forKey: AppPreferences.screensaverEnabled) else { return }
        guard let window = WindowSizeManager.mainWindow, window.isVisible, !window.isMiniaturized else { return }
        // `start()` runs before the window necessarily exists, and mouse-moved events are only
        // reported when the window asks for them — so make sure of it here too, or a session spent
        // only moving the mouse would look idle.
        if !window.acceptsMouseMovedEvents {
            window.acceptsMouseMovedEvents = true
        }
        guard isQuiet?() ?? false else { return }
        guard Date().timeIntervalSince(lastInput) >= Self.idleTime else { return }
        onIdle?()
    }
}
