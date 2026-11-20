import AppKit

/// What one Mac key is on a PC keyboard: the Linux evdev code (SyncTERM physical key reports, CSI = Pk K / k), and
/// the set-1 scancode + E0 flag + Windows virtual key that TRACE's TE_IN_KEY record carries (engine_contract.h:
/// a = set-1 scancode, flags bit1 = extended, b = Windows VK), so a module sees the same key on every client.
struct PCKey {
    let evdev: Int
    let scan: Int
    let extended: Bool
    let vk: Int
}

/// NSEvent `keyCode` (Carbon kVK_*) to PC key. Built from upstream SyncTERM's `cg_events.m` (`vk_to_at[]` +
/// `cg_evdev_from_vk()`, TERMinator-Windows/reference/upstream-physical-keys/) plus the Windows VKs and set-1
/// scancodes the Windows client gets from WM_KEYDOWN. Windows reports Shift/Ctrl/Alt as the generic VK_SHIFT /
/// VK_CONTROL / VK_MENU with the scancode (and E0) telling left from right, so these do the same.
/// Beyond upstream: ISO § (KEY_102ND), keypad / and = , keypad Clear as Num Lock, Help as Insert (where a PC
/// keyboard has it).
enum PCKeys {
    static func key(_ keyCode: UInt16) -> PCKey? {
        return table[keyCode]
    }

    private static func k(_ evdev: Int, _ scan: Int, _ vk: Int, _ extended: Bool = false) -> PCKey {
        PCKey(evdev: evdev, scan: scan, extended: extended, vk: vk)
    }

    private static let table: [UInt16: PCKey] = [
        // Letters (evdev = set-1 scancode for the base PC keyboard)
        0x00: k(30, 0x1E, 0x41),  // A
        0x0B: k(48, 0x30, 0x42),  // B
        0x08: k(46, 0x2E, 0x43),  // C
        0x02: k(32, 0x20, 0x44),  // D
        0x0E: k(18, 0x12, 0x45),  // E
        0x03: k(33, 0x21, 0x46),  // F
        0x05: k(34, 0x22, 0x47),  // G
        0x04: k(35, 0x23, 0x48),  // H
        0x22: k(23, 0x17, 0x49),  // I
        0x26: k(36, 0x24, 0x4A),  // J
        0x28: k(37, 0x25, 0x4B),  // K
        0x25: k(38, 0x26, 0x4C),  // L
        0x2E: k(50, 0x32, 0x4D),  // M
        0x2D: k(49, 0x31, 0x4E),  // N
        0x1F: k(24, 0x18, 0x4F),  // O
        0x23: k(25, 0x19, 0x50),  // P
        0x0C: k(16, 0x10, 0x51),  // Q
        0x0F: k(19, 0x13, 0x52),  // R
        0x01: k(31, 0x1F, 0x53),  // S
        0x11: k(20, 0x14, 0x54),  // T
        0x20: k(22, 0x16, 0x55),  // U
        0x09: k(47, 0x2F, 0x56),  // V
        0x0D: k(17, 0x11, 0x57),  // W
        0x07: k(45, 0x2D, 0x58),  // X
        0x10: k(21, 0x15, 0x59),  // Y
        0x06: k(44, 0x2C, 0x5A),  // Z
        // Number row
        0x12: k(2, 0x02, 0x31),   // 1
        0x13: k(3, 0x03, 0x32),   // 2
        0x14: k(4, 0x04, 0x33),   // 3
        0x15: k(5, 0x05, 0x34),   // 4
        0x17: k(6, 0x06, 0x35),   // 5
        0x16: k(7, 0x07, 0x36),   // 6
        0x1A: k(8, 0x08, 0x37),   // 7
        0x1C: k(9, 0x09, 0x38),   // 8
        0x19: k(10, 0x0A, 0x39),  // 9
        0x1D: k(11, 0x0B, 0x30),  // 0
        0x1B: k(12, 0x0C, 0xBD),  // -  VK_OEM_MINUS
        0x18: k(13, 0x0D, 0xBB),  // =  VK_OEM_PLUS
        // Punctuation
        0x21: k(26, 0x1A, 0xDB),  // [  VK_OEM_4
        0x1E: k(27, 0x1B, 0xDD),  // ]  VK_OEM_6
        0x29: k(39, 0x27, 0xBA),  // ;  VK_OEM_1
        0x27: k(40, 0x28, 0xDE),  // '  VK_OEM_7
        0x32: k(41, 0x29, 0xC0),  // `  VK_OEM_3
        0x2A: k(43, 0x2B, 0xDC),  // \  VK_OEM_5
        0x2B: k(51, 0x33, 0xBC),  // ,  VK_OEM_COMMA
        0x2F: k(52, 0x34, 0xBE),  // .  VK_OEM_PERIOD
        0x2C: k(53, 0x35, 0xBF),  // /  VK_OEM_2
        0x0A: k(86, 0x56, 0xE2),  // ISO §  KEY_102ND / VK_OEM_102
        // Editing and whitespace
        0x35: k(1, 0x01, 0x1B),   // Escape
        0x33: k(14, 0x0E, 0x08),  // Delete (backspace)
        0x30: k(15, 0x0F, 0x09),  // Tab
        0x24: k(28, 0x1C, 0x0D),  // Return
        0x31: k(57, 0x39, 0x20),  // Space
        // Modifiers (flagsChanged)
        0x38: k(42, 0x2A, 0x10),          // Shift         KEY_LEFTSHIFT
        0x3C: k(54, 0x36, 0x10),          // Right Shift   KEY_RIGHTSHIFT
        0x3B: k(29, 0x1D, 0x11),          // Control       KEY_LEFTCTRL
        0x3E: k(97, 0x1D, 0x11, true),    // Right Control KEY_RIGHTCTRL
        0x3A: k(56, 0x38, 0x12),          // Option        KEY_LEFTALT
        0x3D: k(100, 0x38, 0x12, true),   // Right Option  KEY_RIGHTALT
        0x37: k(125, 0x5B, 0x5B, true),   // Command       KEY_LEFTMETA / VK_LWIN
        0x36: k(126, 0x5C, 0x5C, true),   // Right Command KEY_RIGHTMETA / VK_RWIN
        0x39: k(58, 0x3A, 0x14),          // Caps Lock
        // Function keys
        0x7A: k(59, 0x3B, 0x70),  // F1
        0x78: k(60, 0x3C, 0x71),  // F2
        0x63: k(61, 0x3D, 0x72),  // F3
        0x76: k(62, 0x3E, 0x73),  // F4
        0x60: k(63, 0x3F, 0x74),  // F5
        0x61: k(64, 0x40, 0x75),  // F6
        0x62: k(65, 0x41, 0x76),  // F7
        0x64: k(66, 0x42, 0x77),  // F8
        0x65: k(67, 0x43, 0x78),  // F9
        0x6D: k(68, 0x44, 0x79),  // F10
        0x67: k(87, 0x57, 0x7A),  // F11
        0x6F: k(88, 0x58, 0x7B),  // F12
        0x69: k(183, 0x64, 0x7C), // F13
        0x6B: k(184, 0x65, 0x7D), // F14
        0x71: k(185, 0x66, 0x7E), // F15
        0x6A: k(186, 0x67, 0x7F), // F16
        0x40: k(187, 0x68, 0x80), // F17
        0x4F: k(188, 0x69, 0x81), // F18
        0x50: k(189, 0x6A, 0x82), // F19
        0x5A: k(190, 0x6B, 0x83), // F20
        // Navigation (E0-extended on a PC)
        0x72: k(110, 0x52, 0x2D, true),  // Help -> Insert
        0x75: k(111, 0x53, 0x2E, true),  // Forward Delete
        0x73: k(102, 0x47, 0x24, true),  // Home
        0x77: k(107, 0x4F, 0x23, true),  // End
        0x74: k(104, 0x49, 0x21, true),  // Page Up
        0x79: k(109, 0x51, 0x22, true),  // Page Down
        0x7E: k(103, 0x48, 0x26, true),  // Up
        0x7D: k(108, 0x50, 0x28, true),  // Down
        0x7B: k(105, 0x4B, 0x25, true),  // Left
        0x7C: k(106, 0x4D, 0x27, true),  // Right
        // Keypad
        0x52: k(82, 0x52, 0x60),         // 0
        0x53: k(79, 0x4F, 0x61),         // 1
        0x54: k(80, 0x50, 0x62),         // 2
        0x55: k(81, 0x51, 0x63),         // 3
        0x56: k(75, 0x4B, 0x64),         // 4
        0x57: k(76, 0x4C, 0x65),         // 5
        0x58: k(77, 0x4D, 0x66),         // 6
        0x59: k(71, 0x47, 0x67),         // 7
        0x5B: k(72, 0x48, 0x68),         // 8
        0x5C: k(73, 0x49, 0x69),         // 9
        0x41: k(83, 0x53, 0x6E),         // .
        0x43: k(55, 0x37, 0x6A),         // *
        0x45: k(78, 0x4E, 0x6B),         // +
        0x4E: k(74, 0x4A, 0x6D),         // -
        0x4B: k(98, 0x35, 0x6F, true),   // /  KEY_KPSLASH
        0x4C: k(96, 0x1C, 0x0D, true),   // Enter  KEY_KPENTER
        0x51: k(117, 0x59, 0x92),        // =  KEY_KPEQUAL / VK_OEM_NEC_EQUAL
        0x47: k(69, 0x45, 0x90),         // Clear -> Num Lock
    ]

    /// Modifier keys arrive as flagsChanged with no up/down of their own: whether this one is now down, from the
    /// device-dependent bits of the flags (IOKit NX_DEVICE*KEYMASK: left / right told apart), or nil when the event
    /// isn't for a modifier we map. Caps Lock reports its lock state; callers send it as a tap (`capsLock`).
    static func modifierPressed(_ event: NSEvent) -> Bool? {
        let raw = event.modifierFlags.rawValue
        switch event.keyCode {
        case 0x3B: return raw & 0x0000_0001 != 0   // left Control   NX_DEVICELCTLKEYMASK
        case 0x38: return raw & 0x0000_0002 != 0   // left Shift     NX_DEVICELSHIFTKEYMASK
        case 0x3C: return raw & 0x0000_0004 != 0   // right Shift    NX_DEVICERSHIFTKEYMASK
        case 0x37: return raw & 0x0000_0008 != 0   // left Command   NX_DEVICELCMDKEYMASK
        case 0x36: return raw & 0x0000_0010 != 0   // right Command  NX_DEVICERCMDKEYMASK
        case 0x3A: return raw & 0x0000_0020 != 0   // left Option    NX_DEVICELALTKEYMASK
        case 0x3D: return raw & 0x0000_0040 != 0   // right Option   NX_DEVICERALTKEYMASK
        case 0x3E: return raw & 0x0000_2000 != 0   // right Control  NX_DEVICERCTLKEYMASK
        case 0x39: return event.modifierFlags.contains(.capsLock)
        default: return nil
        }
    }

    /// Caps Lock's flagsChanged comes once per toggle with the lock state, not per press and release, so it is
    /// reported as a tap -- press then release -- every time (what a PC keyboard sends: Windows WM_KEYDOWN/UP, evdev).
    static let capsLock: UInt16 = 0x39

    static func isModifier(_ keyCode: UInt16) -> Bool {
        (0x36...0x3E).contains(keyCode)
    }

    /// The last Command key went up. AppKit delivers no keyUp for a key let go while Command was down, so any
    /// non-modifier key we still count as held may already be up: true when it is no longer physically down.
    static func commandReleased(_ event: NSEvent) -> Bool {
        event.type == .flagsChanged && (event.keyCode == 0x37 || event.keyCode == 0x36)
            && !event.modifierFlags.contains(.command)
    }

    static func isPhysicallyUp(_ keyCode: UInt16) -> Bool {
        !CGEventSource.keyState(.hidSystemState, key: CGKeyCode(keyCode))
    }

    /// ⌘⌥Return (View > Full Screen) or the system's ⌃⌘F: the one key TRACE never takes (Windows keeps Alt+Enter).
    static func isFullScreenToggle(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if (event.keyCode == 0x24 || event.keyCode == 0x4C) && mods.contains(.command) && mods.contains(.option) {
            return true
        }
        return event.keyCode == 0x03 && mods.contains(.command) && mods.contains(.control)
    }
}

/// The terminal's raw key stream: physical key reports for SyncTERM doors (CSI = 1 h / 2 h, PORT_SYNCDOOM_TO_MAC_LINUX
/// §11) and the keyboard of a TRACE module that owns it. One local NSEvent monitor for keyDown / keyUp / flagsChanged,
/// running while the terminal is on screen, sees every key before the responder chain does, which matters because
/// `TerminalKeyboardView` gets most keys through `performKeyEquivalent`, where there is no key-up at all.
///
/// * A TRACE module owning the keyboard -- an exclusive one (a game), or any module with text input on: it gets the
///   key (and nothing else does, app-wide in the main window) except the full-screen toggle
///   (`TraceSessionManager.handleExclusiveKey`, which also sends the typed characters while text input is on).
/// * Otherwise, while the board has physical key reports on (bit 0 of `native_get_key_modes`): presses count only
///   while the terminal owns the keyboard (main window key, no Settings / Boss Hide / text field over it), releases
///   always go (the bridge drops ones it never reported). The event carries on to the normal typed-byte path, which
///   itself goes quiet while bit 1 is set (TerminalKeyboardView).
/// * Focus leaving (window resigns key, app resigns active, terminal leaves the screen): every held key is released.
final class TerminalKeyMonitor {
    static let shared = TerminalKeyMonitor()

    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var reported = Set<UInt16>()   // non-modifier keys reported pressed, for the release on Command up

    private init() {}

    /// TerminalView.onAppear.
    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self = self else { return event }
            return self.handle(event) ? nil : event
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: nil,
                                            queue: .main) { [weak self] note in
            guard let window = note.object as? NSWindow, window === WindowSizeManager.mainWindow else { return }
            self?.focusLost()
        })
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            self?.focusLost()
        })
    }

    /// TerminalView.onDisappear.
    func stop() {
        focusLost()
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }

    /// Focus left the terminal: nothing may stay held on the board (upstream cg_key_focus_lost).
    func focusLost() {
        reported.removeAll()
        NativeBridge.shared.keyReleaseAll()
    }

    /// True when the terminal owns the keyboard: its window is the key window and nothing covers it.
    static func terminalHasKeyboard(_ event: NSEvent) -> Bool {
        guard let window = event.window, window === WindowSizeManager.mainWindow, window.isKeyWindow else {
            return false
        }
        if AppState.shared.settingsOverTerminal || AppState.shared.bossHideActive {
            return false
        }
        // A text field being edited (the field editor is an NSTextView) keeps its keys
        if window.firstResponder is NSTextView {
            return false
        }
        return true
    }

    /// Returns true to swallow the event.
    private func handle(_ event: NSEvent) -> Bool {
        // Keys let go while Command was down never got their keyUp: release them now (the bridge drops releases of
        // keys it never reported, and a key still physically down keeps going)
        if PCKeys.commandReleased(event) {
            TraceSessionManager.shared.releaseKeysAfterCommand()
            for keyCode in reported where PCKeys.isPhysicallyUp(keyCode) {
                reported.remove(keyCode)
                if let key = PCKeys.key(keyCode) {
                    NativeBridge.shared.keyEvent(evdev: key.evdev, pressed: false)
                }
            }
        }

        // Pressed state of a modifier: flagsChanged has none of its own
        var pressed = event.type == .keyDown
        if event.type == .flagsChanged {
            guard let down = PCKeys.modifierPressed(event) else { return false }
            pressed = down
        }

        // An exclusive TRACE module owns the keyboard
        if TraceSessionManager.shared.handleExclusiveKey(event, pressed: pressed) {
            return true
        }

        // A Rainwire window with the keyboard (its surface is the first responder) takes the key as the window's
        // input (RainwireWm/RainwireDesk.swift); the main screen behind it never sees it
        if event.type == .keyDown && Self.terminalHasKeyboard(event) && RainwireDesk.shared.handleKey(event) {
            return true
        }

        // A Rainwire board's menu drawn here (1.1.6, Views/RainwireMenu.swift) takes every key but Command shortcuts
        // while it's up: arrows, Enter, Esc and hotkeys (Windows: the menu holds the keyboard focus)
        if event.type == .keyDown && Self.terminalHasKeyboard(event) && RainwireMenuView.shared.handleKey(event) {
            return true
        }

        // SyncTERM physical key reports
        if NativeBridge.shared.keyModes & 1 != 0, let key = PCKeys.key(event.keyCode) {
            if event.keyCode == PCKeys.capsLock {
                if Self.terminalHasKeyboard(event) {   // a tap on every toggle
                    NativeBridge.shared.keyEvent(evdev: key.evdev, pressed: true)
                    NativeBridge.shared.keyEvent(evdev: key.evdev, pressed: false)
                }
            } else if !pressed {
                reported.remove(event.keyCode)
                NativeBridge.shared.keyEvent(evdev: key.evdev, pressed: false)
            } else if !event.isARepeatSafe && Self.terminalHasKeyboard(event) {
                if !PCKeys.isModifier(event.keyCode) {
                    reported.insert(event.keyCode)
                }
                NativeBridge.shared.keyEvent(evdev: key.evdev, pressed: true)
            }
        }
        return false
    }
}

extension NSEvent {
    /// `isARepeat` raises for flagsChanged events; this is false for them.
    var isARepeatSafe: Bool {
        (type == .keyDown || type == .keyUp) ? isARepeat : false
    }
}
