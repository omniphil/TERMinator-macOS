import AppKit

/// A local key-down monitor for the full-window overlays (boot screen, Konami rain), plus the Konami
/// key tracking on the home screen. The command line takes its keys in its own AppKit text field
/// instead (`ConsoleInputField`), so Tab and the arrows never reach a SwiftUI control.
///
/// Windows routes these through the window's `PreviewKeyDown`; on macOS a SwiftUI overlay can't
/// reliably take first responder away from whatever the content view left focused, so the overlays
/// watch the key stream directly instead. The handler returns true to **swallow** the event (the
/// overlay consumed it) or false to let it carry on to the app.
///
/// ⚠️ Events carrying ⌘ are always passed through untouched, so the menu bar's key equivalents
/// (⌘Q, ⌘,) still work while an overlay is up.
final class KeyEventMonitor {
    private var monitor: Any?
    private var handler: ((NSEvent) -> Bool)?

    var isRunning: Bool { monitor != nil }

    /// Starts watching. Replaces any monitor already running on this object.
    func start(_ handler: @escaping (NSEvent) -> Bool) {
        stop()
        self.handler = handler
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, let handler = self.handler else { return event }
            if event.modifierFlags.contains(.command) { return event }
            return handler(event) ? nil : event
        }
    }

    func stop() {
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        handler = nil
    }

    deinit {
        stop()
    }
}

/// The virtual key codes the flair needs (`Carbon.HIToolbox` isn't linked in this target).
enum KeyCode {
    static let leftArrow: UInt16 = 123
    static let rightArrow: UInt16 = 124
    static let downArrow: UInt16 = 125
    static let upArrow: UInt16 = 126
    static let a: UInt16 = 0
    static let b: UInt16 = 11
}
