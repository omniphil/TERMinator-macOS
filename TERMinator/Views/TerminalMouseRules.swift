import Foundation

/// Who gets a mouse event on the main terminal: the board (an xterm mouse report, Bridge/mouse_bridge.c) or
/// TERMinator itself (selection, scrollback, URL clicks). Plain values only.
/// Port of the Windows client's `Controls/TerminalMouseRules.cs`.
enum TerminalMouseRules {
    // The board's tracking modes, as Bridge/mouse_bridge.c reports them (native_mouse_mode, low 16 bits)
    static let off = 0, x10 = 9, normal = 1000, buttonEvent = 1002, anyEvent = 1003

    // Event kinds and buttons, as native_mouse_event takes them
    static let press = 0, release = 1, move = 2
    static let left = 0, middle = 1, right = 2, wheelUp = 3, wheelDown = 4

    /// The tracking mode from native_mouse_mode's value (which also carries the SGR flag).
    static func mode(_ modeWord: Int) -> Int { modeWord & 0xFFFF }

    /// Whether a button press goes to the board. Shift keeps the mouse for TERMinator (Shift+drag selects), as in
    /// most terminals; so does a scrolled-back view, where a click first returns to the live screen.
    static func pressToBoard(_ mode: Int, _ button: Int, shift: Bool, scrolledBack: Bool) -> Bool {
        mode != off && !shift && !scrolledBack && button >= left && button <= right
    }

    /// Whether the wheel goes to the board. X10 never reports the wheel (SyncTERM keeps it for scrollback there);
    /// the other modes report it, and Shift+wheel still scrolls back.
    static func wheelToBoard(_ mode: Int, shift: Bool, scrolledBack: Bool) -> Bool {
        (mode == normal || mode == buttonEvent || mode == anyEvent) && !shift && !scrolledBack
    }

    /// Whether a move to a new cell is reported: every move in any-event tracking, and moves with a button held in
    /// button-event tracking. Shift with no button held is the user's own (starting a selection).
    static func moveToBoard(_ mode: Int, anyHeld: Bool, shift: Bool) -> Bool {
        (mode == anyEvent && !(shift && !anyHeld)) || (mode == buttonEvent && anyHeld)
    }

    /// The lowest held button for a move report, or -1 when none is held. held is a bit per button.
    static func moveButton(_ held: Int) -> Int {
        held & 1 != 0 ? left : held & 2 != 0 ? middle : held & 4 != 0 ? right : -1
    }

    /// A 0-based cell as the 1-based position reports use, or nil outside the screen.
    static func reportCell(_ col: Int, _ row: Int, _ cols: Int, _ rows: Int) -> (x: Int, y: Int)? {
        col < 0 || row < 0 || col >= cols || row >= rows ? nil : (col + 1, row + 1)
    }
}
