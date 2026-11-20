import SwiftUI
import AVKit
import UniformTypeIdentifiers
import os.log

private let termLogger = Logger(subsystem: "com.terminator.macos", category: "TerminalView")

/// NSView subclass that handles keyboard input for the terminal.
/// Uses NSView's keyDown/keyUp/flagsChanged for reliable key handling on macOS.
final class TerminalKeyboardView: NSView {
    var onCharacter: ((Character) -> Void)?
    var onString: ((String) -> Void)?
    var onPaste: ((String) -> Void)?
    var onCopy: (() -> Void)?
    var onSelectAll: (() -> Void)?
    var onToggleBuffer: (() -> Void)?
    var onPageScroll: ((Bool) -> Void)?
    var isInScrollback: Bool = false

    override var acceptsFirstResponder: Bool { true }

    // Intercept key equivalents so ESC, Tab, arrows, and other special keys
    // aren't swallowed by the responder chain (sheets, menus, focus navigation).
    // This mirrors iOS's wantsPriorityOverSystemBehavior = true approach.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Let Cmd shortcuts go through to the menu system; and while Settings covers the session
        // (AppState.settingsOverTerminal) no key belongs to the board
        if event.modifierFlags.contains(.command) || AppState.shared.settingsOverTerminal
            || AppState.shared.disconnectOverlayUp {
            return super.performKeyEquivalent(with: event)
        }
        // The door asked for no typed bytes (SyncTERM CSI = 2 h): it reads physical key reports instead
        // (TerminalKeyMonitor), and Ctrl is fire in Doom, so no shortcut runs either
        if NativeBridge.shared.keyModes & 2 != 0 {
            return true
        }

        let keyCode = event.keyCode
        switch keyCode {
        case 53: // Escape
            onCharacter?(Character(UnicodeScalar(0x1B)))
            return true
        case 36: // Return/Enter
            onCharacter?(Character("\r"))
            return true
        case 76: // Numpad Enter
            onCharacter?(Character("\r"))
            return true
        case 48: // Tab
            onCharacter?(Character(UnicodeScalar(9)))
            return true
        case 51: // Backspace/Delete
            onCharacter?(Character(UnicodeScalar(8)))
            return true
        case 126: // Up arrow
            onString?("\u{1B}[A")
            return true
        case 125: // Down arrow
            onString?("\u{1B}[B")
            return true
        case 124: // Right arrow
            onString?("\u{1B}[C")
            return true
        case 123: // Left arrow
            onString?("\u{1B}[D")
            return true
        case 114: // Help/Insert (Windows TerminalCanvas: ESC[2~)
            onString?("\u{1B}[2~")
            return true
        case 117: // Forward Delete
            onString?("\u{1B}[3~")
            return true
        case 115: // Home
            onString?("\u{1B}[H")
            return true
        case 119: // End
            onString?("\u{1B}[F")
            return true
        case 116: // Page Up
            onString?("\u{1B}[5~")
            return true
        case 121: // Page Down
            onString?("\u{1B}[6~")
            return true
        case 122: // F1
            onString?("\u{1B}OP")
            return true
        case 120: // F2
            onString?("\u{1B}OQ")
            return true
        case 99: // F3
            onString?("\u{1B}OR")
            return true
        case 118: // F4
            onString?("\u{1B}OS")
            return true
        case 96: // F5
            onString?("\u{1B}[15~")
            return true
        case 97: // F6
            onString?("\u{1B}[17~")
            return true
        case 98: // F7
            onString?("\u{1B}[18~")
            return true
        case 100: // F8
            onString?("\u{1B}[19~")
            return true
        case 101: // F9
            onString?("\u{1B}[20~")
            return true
        case 109: // F10
            onString?("\u{1B}[21~")
            return true
        case 103: // F11
            onString?("\u{1B}[23~")
            return true
        case 111: // F12
            onString?("\u{1B}[24~")
            return true
        default:
            break
        }

        // Ctrl+B: toggle scrollback buffer mode
        if event.modifierFlags.contains(.control),
           let chars = event.charactersIgnoringModifiers?.lowercased(),
           chars == "b" {
            onToggleBuffer?()
            return true
        }

        // Control+letter — intercept before system handles it
        if event.modifierFlags.contains(.control),
           let chars = event.charactersIgnoringModifiers?.lowercased(),
           let first = chars.first, first.isLetter {
            if let ascii = first.asciiValue {
                onCharacter?(Character(UnicodeScalar(ascii & 0x1F)))
            }
            return true
        }

        // Regular characters (letters, numbers, symbols, space, etc.)
        // Must be handled here because this view may not be first responder,
        // and keyDown only goes to the first responder. performKeyEquivalent
        // propagates through the entire view hierarchy.
        if let chars = event.characters, !chars.isEmpty {
            for char in chars {
                if char == "\n" {
                    onCharacter?(Character("\r"))
                } else {
                    onCharacter?(char)
                }
            }
            return true
        }

        return false
    }

    override func keyDown(with event: NSEvent) {
        if AppState.shared.settingsOverTerminal {
            super.keyDown(with: event)
            return
        }
        // CSI = 2 h: no typed bytes and no terminal shortcuts (paste, copy, scrollback) while the door reads
        // physical key reports
        if NativeBridge.shared.keyModes & 2 != 0 {
            return
        }
        let keyCode = event.keyCode
        let flags = event.modifierFlags

        // Cmd+V paste: the whole clipboard as one send (TerminalViewModel.sendPaste), with no key clicks
        if flags.contains(.command) && event.charactersIgnoringModifiers == "v" {
            if let clipboard = NSPasteboard.general.string(forType: .string) {
                onPaste?(clipboard)
            }
            return
        }

        // Cmd+C copy selected text
        if flags.contains(.command) && event.charactersIgnoringModifiers == "c" {
            onCopy?()
            return
        }

        // Cmd+A select all terminal text
        if flags.contains(.command) && event.charactersIgnoringModifiers == "a" {
            onSelectAll?()
            return
        }

        // NOTE: Cmd+= / Cmd+- / Cmd+0 were swallowed here to drive a zoom that never
        // reached the renderer. Removed 2026-09-12 so the keys fall through to the BBS
        // like any other input.

        // Ctrl+B: toggle scrollback buffer mode
        if flags.contains(.control), event.charactersIgnoringModifiers?.lowercased() == "b" {
            onToggleBuffer?()
            return
        }

        // Control+letter (Ctrl+A through Ctrl+Z)
        if flags.contains(.control), let chars = event.charactersIgnoringModifiers?.lowercased(), let first = chars.first, first.isLetter {
            if let ascii = first.asciiValue {
                onCharacter?(Character(UnicodeScalar(ascii & 0x1F)))
            }
            return
        }

        // Special keys — these are also in performKeyEquivalent as a safety net,
        // but keyDown handles them if they make it through the responder chain
        switch keyCode {
        case 53: // Escape
            onCharacter?(Character(UnicodeScalar(0x1B)))
        case 126: // Up arrow
            onString?("\u{1B}[A")
        case 125: // Down arrow
            onString?("\u{1B}[B")
        case 124: // Right arrow
            onString?("\u{1B}[C")
        case 123: // Left arrow
            onString?("\u{1B}[D")
        case 48: // Tab
            onCharacter?(Character(UnicodeScalar(9)))
        case 36: // Return/Enter
            onCharacter?(Character("\r"))
        case 76: // Numpad Enter
            onCharacter?(Character("\r"))
        case 51: // Backspace/Delete
            onCharacter?(Character(UnicodeScalar(8)))
        case 114: // Help/Insert (Windows TerminalCanvas: ESC[2~)
            onString?("\u{1B}[2~")
        case 117: // Forward Delete
            onString?("\u{1B}[3~")
        case 115: // Home
            onString?("\u{1B}[H")
        case 119: // End
            onString?("\u{1B}[F")
        case 116: // Page Up
            if isInScrollback {
                onPageScroll?(true)
            } else {
                onString?("\u{1B}[5~")
            }
        case 121: // Page Down
            if isInScrollback {
                onPageScroll?(false)
            } else {
                onString?("\u{1B}[6~")
            }
        case 122: // F1
            onString?("\u{1B}OP")
        case 120: // F2
            onString?("\u{1B}OQ")
        case 99: // F3
            onString?("\u{1B}OR")
        case 118: // F4
            onString?("\u{1B}OS")
        case 96: // F5
            onString?("\u{1B}[15~")
        case 97: // F6
            onString?("\u{1B}[17~")
        case 98: // F7
            onString?("\u{1B}[18~")
        case 100: // F8
            onString?("\u{1B}[19~")
        case 101: // F9
            onString?("\u{1B}[20~")
        case 109: // F10
            onString?("\u{1B}[21~")
        case 103: // F11
            onString?("\u{1B}[23~")
        case 111: // F12
            onString?("\u{1B}[24~")
        default:
            // Regular characters
            if let chars = event.characters {
                for char in chars {
                    if char == "\n" {
                        onCharacter?(Character("\r"))
                    } else {
                        onCharacter?(char)
                    }
                }
            }
        }
    }

    override func flagsChanged(with event: NSEvent) {
        // Not used directly for terminal input (physical key reports see modifiers in TerminalKeyMonitor)
    }

    override func resignFirstResponder() -> Bool {
        // Nothing may stay held on the board when the keyboard goes elsewhere (PORT_SYNCDOOM_TO_MAC_LINUX §11.3)
        NativeBridge.shared.keyReleaseAll()
        return super.resignFirstResponder()
    }

    // Scroll wheel for scrollback
    override func scrollWheel(with event: NSEvent) {
        // Forward to parent
        super.scrollWheel(with: event)
    }
}

/// NSViewRepresentable wrapper for the keyboard input view.
struct TerminalKeyboardViewRepresentable: NSViewRepresentable {
    var onCharacter: (Character) -> Void
    var onString: (String) -> Void
    var onPaste: (String) -> Void
    var onCopy: () -> Void
    var onSelectAll: () -> Void
    var onToggleBuffer: () -> Void
    var isInScrollback: Bool
    var onPageScroll: (Bool) -> Void

    func makeNSView(context: Context) -> TerminalKeyboardView {
        let view = TerminalKeyboardView()
        view.onCharacter = onCharacter
        view.onString = onString
        view.onPaste = onPaste
        view.onCopy = onCopy
        view.onSelectAll = onSelectAll
        view.onToggleBuffer = onToggleBuffer
        view.isInScrollback = isInScrollback
        view.onPageScroll = onPageScroll
        return view
    }

    func updateNSView(_ nsView: TerminalKeyboardView, context: Context) {
        nsView.onCharacter = onCharacter
        nsView.onString = onString
        nsView.onPaste = onPaste
        nsView.onCopy = onCopy
        nsView.onSelectAll = onSelectAll
        nsView.onToggleBuffer = onToggleBuffer
        nsView.isInScrollback = isInScrollback
        nsView.onPageScroll = onPageScroll
    }
}

// MARK: - Terminal Mouse Tracking View

/// NSView subclass that tracks mouse events for text selection, URL clicking, and context menu.
/// While a board has asked for the mouse (xterm modes 9/1000/1002/1003), `mouse` (TerminalMouse.swift) takes the
/// events first and sends them to the board; Shift keeps them for TERMinator.
final class TerminalMouseTrackingView: NSView {
    let mouse = TerminalMouse()
    var onMouseDown: ((NSPoint) -> Void)?
    var onMouseDragged: ((NSPoint) -> Void)?
    var onMouseUp: ((NSPoint, Bool) -> Void)?  // (point, wasDrag)
    var onMouseMoved: ((NSPoint) -> Void)?
    var contextMenuProvider: (() -> NSMenu)?

    private var isDragging = false
    private var mouseDownPoint: NSPoint = .zero
    private let dragThreshold: CGFloat = 3.0

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if mouse.down(TerminalMouseRules.left, at: location, event: event) {
            isDragging = false
            return
        }
        mouseDownPoint = location
        isDragging = false
        onMouseDown?(location)
    }

    override func mouseDragged(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if mouse.dragged(at: location, event: event) {
            return
        }
        let dx = location.x - mouseDownPoint.x
        let dy = location.y - mouseDownPoint.y
        if sqrt(dx * dx + dy * dy) >= dragThreshold {
            isDragging = true
        }
        if isDragging {
            onMouseDragged?(location)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if mouse.up(TerminalMouseRules.left, at: location) {
            isDragging = false
            return
        }
        onMouseUp?(location, isDragging)
        isDragging = false
    }

    override func mouseMoved(with event: NSEvent) {
        // The tracking area sees moves over the layers above too (a Rainwire window, a TRACE module): theirs
        if TerminalMouse.overlayOwnsPointer(event) {
            return
        }
        let location = convert(event.locationInWindow, from: nil)
        mouse.moved(at: location, event: event)
        onMouseMoved?(location)
    }

    // Right button: the board's while it has the mouse, else the context menu as before (super shows menu(for:))
    override func rightMouseDown(with event: NSEvent) {
        if mouse.down(TerminalMouseRules.right, at: convert(event.locationInWindow, from: nil), event: event) {
            return
        }
        super.rightMouseDown(with: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        if mouse.up(TerminalMouseRules.right, at: convert(event.locationInWindow, from: nil)) {
            return
        }
        super.rightMouseUp(with: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        if mouse.dragged(at: convert(event.locationInWindow, from: nil), event: event) {
            return
        }
        super.rightMouseDragged(with: event)
    }

    // Middle button (button number 2)
    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2,
           mouse.down(TerminalMouseRules.middle, at: convert(event.locationInWindow, from: nil), event: event) {
            return
        }
        super.otherMouseDown(with: event)
    }

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2, mouse.up(TerminalMouseRules.middle, at: convert(event.locationInWindow, from: nil)) {
            return
        }
        super.otherMouseUp(with: event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        if mouse.dragged(at: convert(event.locationInWindow, from: nil), event: event) {
            return
        }
        super.otherMouseDragged(with: event)
    }

    // The wheel: the board's while it asked for it (not in X10), else scrollback as before
    override func scrollWheel(with event: NSEvent) {
        if mouse.wheel(event, at: convert(event.locationInWindow, from: nil)) {
            return
        }
        super.scrollWheel(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenuProvider?()
    }
}

/// NSViewRepresentable wrapper for the mouse tracking view.
struct TerminalMouseTrackingRepresentable: NSViewRepresentable {
    var onMouseDown: (NSPoint) -> Void
    var onMouseDragged: (NSPoint) -> Void
    var onMouseUp: (NSPoint, Bool) -> Void
    var onMouseMoved: (NSPoint) -> Void
    var contextMenuProvider: (() -> NSMenu)?
    /// For mouse reports (TerminalMouse): the 0-based cell under a point, the screen size, scrollback
    var cellAt: (NSPoint) -> (col: Int, row: Int)
    var screenSize: () -> (cols: Int, rows: Int)
    var isScrolledBack: () -> Bool
    /// A board's OSC 8 link at a 0-based cell: a left click there is TerminalView's, never reported (12.62)
    var isLinkCell: (Int, Int) -> Bool = { _, _ in false }
    var returnToLive: () -> Void
    var cancelSelection: () -> Void

    func makeNSView(context: Context) -> TerminalMouseTrackingView {
        let view = TerminalMouseTrackingView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: TerminalMouseTrackingView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: TerminalMouseTrackingView) {
        view.onMouseDown = onMouseDown
        view.onMouseDragged = onMouseDragged
        view.onMouseUp = onMouseUp
        view.onMouseMoved = onMouseMoved
        view.contextMenuProvider = contextMenuProvider
        view.mouse.cellAt = cellAt
        view.mouse.screenSize = screenSize
        view.mouse.isScrolledBack = isScrolledBack
        view.mouse.isLinkCell = isLinkCell
        view.mouse.returnToLive = returnToLive
        view.mouse.cancelSelection = cancelSelection
    }
}

/// Terminal view that renders the screen buffer using Metal for pixel-perfect display.
/// Desktop-optimized: keyboard input via NSView, scroll wheel for scrollback, right-click paste.
struct TerminalView: View {
    let entry: BBSEntry
    @StateObject private var viewModel = TerminalViewModel()
    @EnvironmentObject var appState: AppState

    /// The connecting overlay's live connection log (spec §5). `TerminalViewModel.connect` drives it;
    /// this view just renders it while it is visible, under the failure dialog.
    @ObservedObject private var connectLog = ConnectionLog.shared

    /// The status bar's modem front-panel lights (View > Modem Lights).
    @StateObject private var modemLights = ModemLightsModel()
    @AppStorage(AppPreferences.showModemLights) private var showModemLights = true
    /// View > Phosphor: the canvas tints itself in its Metal shader; the SwiftUI status bar takes the SwiftUI tint.
    @AppStorage(AppPreferences.phosphor) private var phosphor = PhosphorMode.color.rawValue

    // Scroll state
    @State private var scrollAccumulator: CGFloat = 0
    private let scrollThreshold: CGFloat = 20

    // Mouse hover state for URL detection
    @State private var hoveredURL: String?
    /// The real address of the board's OSC 8 link under the mouse, shown at the bottom left (12.62)
    @State private var hoveredBoardLink: String?
    @State private var hoveredCol: Int = -1
    @State private var hoveredRow: Int = -1

    // SSH debug log state
    @State private var showingSshDebug = false
    @State private var sshDebugLog = ""
    /// True when the SSH debug window is standing in for the connection-failed dialog, so closing it
    /// has to end the session and go home (spec §5). False when it was opened on demand from a plain
    /// DISCONNECTED dialog, where the OK button does the teardown instead.
    @State private var sshDebugEndsSession = false
    /// Seconds left before the DISCONNECTED notice closes itself (like the transfer window; user 2026-10-08)
    @State private var disconnectSecondsLeft = 10

    // The window frame before adjustWindowForTerminal fitted it lives in
    // AppState.preConnectFrame: restored (position AND size) on exit so the home screen
    // doesn't inherit a narrow portrait window from an 80x50 board, and saved instead of
    // the terminal's frame if the app is closed mid-session (WindowSizeManager).

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                ZStack(alignment: .top) {
                // Background
                Color.black.ignoresSafeArea()

                // Keyboard input handler (invisible, receives key events)
                TerminalKeyboardViewRepresentable(
                    onCharacter: { char in
                        // IBM Model M click per keystroke (muted during a paste); space gets the spacebar clip
                        KeyClickService.shared.play(space: char == " ")
                        viewModel.sendCharacter(char)
                    },
                    onString: { string in
                        KeyClickService.shared.play()
                        viewModel.sendString(string)
                    },
                    onPaste: { text in
                        viewModel.sendPaste(text)
                    },
                    onCopy: {
                        copySelectedText()
                    },
                    onSelectAll: {
                        selectAllText()
                    },
                    onToggleBuffer: {
                        _ = viewModel.toggleBufferMode()
                    },
                    isInScrollback: viewModel.isInScrollback,
                    onPageScroll: { isUp in
                        viewModel.scrollPage(up: isUp)
                    }
                )
                .frame(width: 1, height: 1)
                .opacity(0)

                // TAP+ background image underlay (behind terminal text)
                if appState.showTapPlus && viewModel.bgActive && !viewModel.isInScrollback, let bgImage = viewModel.bgImageData {
                    bgImageOverlay(image: bgImage, in: geometry)
                }

                // TAP+ tile map underlay (behind terminal text)
                if appState.showTapPlus && viewModel.tileMapActive && !viewModel.tileAtlasPixels.isEmpty && !viewModel.isInScrollback {
                    tileMapOverlay(in: geometry)
                }

                // Metal terminal renderer
                TerminalMetalViewRepresentable(viewModel: viewModel) {
                    viewModel.rendererDidBecomeReady()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .onScrollWheel { delta in
                    handleScrollWheel(delta: delta)
                }

                // Selection overlay
                if viewModel.isSelecting {
                    selectionOverlay(in: geometry)
                }

                // URL underline overlays
                urlUnderlineOverlays(in: geometry)

                // Where a board's OSC 8 link really goes, while the mouse is over it (12.62)
                if let link = hoveredBoardLink {
                    Text(link.count > 200 ? String(link.prefix(200)) + "\u{2026}" : link)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.8))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .allowsHitTesting(false)
                }

                // A short notice ("Copied from the BBS" after an OSC 52 clipboard write, 12.62)
                if let toast = viewModel.toastMessage {
                    Text(toast)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(Color(red: 1.0, green: 0.667, blue: 0.0))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(red: 0.10, green: 0.10, blue: 0.18).opacity(0.9)))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(red: 1.0, green: 0.667, blue: 0.0), lineWidth: 1))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 24)
                        .allowsHitTesting(false)
                }

                // Mouse tracking overlay (transparent, captures mouse events)
                TerminalMouseTrackingRepresentable(
                    onMouseDown: { point in
                        let cell = cellSizeInPoints(in: geometry)
                        let origin = terminalOrigin(in: geometry)
                        let col = Self.cellIndex((point.x - origin.x) / cell.w)
                        // NSView coordinates are flipped (origin at bottom-left)
                        let row = Self.cellIndex((geometry.size.height - point.y - origin.y) / cell.h)
                        viewModel.startSelection(col: col, row: row)
                    },
                    onMouseDragged: { point in
                        let cell = cellSizeInPoints(in: geometry)
                        let origin = terminalOrigin(in: geometry)
                        let col = Self.cellIndex((point.x - origin.x) / cell.w)
                        let row = Self.cellIndex((geometry.size.height - point.y - origin.y) / cell.h)
                        viewModel.updateSelection(col: col, row: row)
                    },
                    onMouseUp: { point, wasDrag in
                        let cell = cellSizeInPoints(in: geometry)
                        let origin = terminalOrigin(in: geometry)
                        let col = Self.cellIndex((point.x - origin.x) / cell.w)
                        let row = Self.cellIndex((geometry.size.height - point.y - origin.y) / cell.h)

                        if !wasDrag {
                            // Single click: check for URL, otherwise cancel selection
                            if let link = viewModel.linkAt(column: col, row: row) {
                                viewModel.cancelSelection()
                                if link.isBoardLink {
                                    OscExtras.open(link.url)   // a board's OSC 8 link (12.62)
                                } else {
                                    viewModel.openURL(link.url)
                                }
                            } else {
                                viewModel.cancelSelection()
                            }
                        }
                        // If it was a drag, the selection stays active
                    },
                    onMouseMoved: { point in
                        let cell = cellSizeInPoints(in: geometry)
                        let origin = terminalOrigin(in: geometry)
                        let col = Self.cellIndex((point.x - origin.x) / cell.w)
                        let row = Self.cellIndex((geometry.size.height - point.y - origin.y) / cell.h)
                        let url = viewModel.urlAt(column: col, row: row)
                        hoveredURL = url
                        // A board's OSC 8 link shows where it really goes, whatever its text says (12.62)
                        let boardLink = viewModel.linkAt(column: col, row: row)
                        hoveredBoardLink = boardLink?.isBoardLink == true ? boardLink?.url : nil
                        hoveredCol = col
                        hoveredRow = row

                        // Change cursor to pointing hand when hovering a URL
                        if url != nil {
                            NSCursor.pointingHand.set()
                        } else {
                            NSCursor.iBeam.set()
                        }
                    },
                    contextMenuProvider: { buildContextMenu() },
                    cellAt: { point in
                        // The same mapping as selection (NSView coordinates are flipped: origin at bottom-left)
                        let cell = cellSizeInPoints(in: geometry)
                        let origin = terminalOrigin(in: geometry)
                        let x = (point.x - origin.x) / cell.w
                        let y = (geometry.size.height - point.y - origin.y) / cell.h
                        return (Self.cellIndex(x.rounded(.down)), Self.cellIndex(y.rounded(.down)))
                    },
                    screenSize: { (viewModel.screenColumns, viewModel.screenRows) },
                    isScrolledBack: { viewModel.isInScrollback },
                    isLinkCell: { col, row in viewModel.linkAt(column: col, row: row)?.isBoardLink == true },
                    returnToLive: { viewModel.resetScrollback() },
                    cancelSelection: { viewModel.cancelSelection() }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // TAP+ overlays (always shown; TAP+ itself is switched off in Preferences)
                if appState.showTapPlus {
                    // TAP+ video overlay
                    if viewModel.videoActive && !viewModel.isInScrollback, let player = viewModel.videoPlayer {
                        videoOverlay(player: player, in: geometry)
                    }

                    // TAP+ multi-channel image overlays (channels 0-7)
                    ForEach(0..<8, id: \.self) { ch in
                        if viewModel.imageChannels[ch].active && !viewModel.isInScrollback, let image = viewModel.imageChannels[ch].data {
                            imageOverlay(image: image, channel: ch, in: geometry)
                        }
                    }

                    // TAP+ logo overlay
                    if viewModel.logoActive && !viewModel.isInScrollback, let logoImage = viewModel.logoImageData {
                        logoOverlay(image: logoImage, in: geometry)
                    }

                    // TAP+ visualizer overlay
                    if viewModel.visualizerActive && !viewModel.isInScrollback {
                        visualizerOverlay(in: geometry)
                    }
                }

                // TERMinator:Pic slots (Rainwire's pictures, Bridge/apc/pic_bridge.c): their own eight, above the text
                // and TAP+, not under TAP+'s Preferences switch; hidden in scroll-back like TAP+'s
                ForEach(0..<TerminalViewModel.maxPicSlots, id: \.self) { id in
                    if viewModel.picSlots[id].active && !viewModel.isInScrollback, let image = viewModel.picSlots[id].image {
                        picOverlay(image: image, slot: id, in: geometry)
                    }
                }

                // TRACE engine layer (BBSGames/Doom/ENGINE.md): a running module's picture over the terminal area.
                // Its own layer, separate from the terminal and TAP+; empty unless a module is running.
                TraceEngineLayer(manager: TraceSessionManager.shared,
                                 cellWidth: cellSizeInPoints(in: geometry).w,
                                 cellHeight: cellSizeInPoints(in: geometry).h,
                                 originX: terminalOrigin(in: geometry).x,
                                 originY: terminalOrigin(in: geometry).y,
                                 columns: viewModel.screenColumns,
                                 rows: viewModel.screenRows,
                                 size: geometry.size,
                                 scrolledBack: viewModel.isInScrollback)

                // Rainwire's client-drawn windows (RainwireWm/, Rainwire docs/WINDOWS.md): a Rainwire board's windows
                // over the terminal, which stays behind them as the desktop. Hidden unless a board has handed us its
                // windows; its empty parts let the mouse through.
                RainwireDeskLayer(originX: terminalOrigin(in: geometry).x,
                                  originY: terminalOrigin(in: geometry).y,
                                  cellWidth: cellSizeInPoints(in: geometry).w,
                                  cellHeight: cellSizeInPoints(in: geometry).h,
                                  columns: viewModel.screenColumns,
                                  rows: viewModel.screenRows)
                    .frame(width: geometry.size.width, height: geometry.size.height)

                // Rainwire's menus drawn here (Views/RainwireMenu.swift, Rainwire docs/MENU_GFX.md, 1.1.6): a board's menu
                // over the terminal area while the board shows one (the status bar below stays in sight); the mouse
                // goes through it otherwise. pictureRect: the terminal picture, for the header's rows and the rain.
                RainwireMenuLayer(pictureRect: pictureRect(in: geometry))
                    .frame(width: geometry.size.width, height: geometry.size.height)

                // Rainwire file drops (files=1, RainwireWm/RainwireFileDrops.swift): OS files dropped on the Files
                // TRACE module or the desk. Takes drags of files only; the mouse goes straight through it.
                RainwireFileDropTarget()
                    .frame(width: geometry.size.width, height: geometry.size.height)

                // Logging indicator
                if viewModel.isLogging {
                    loggingIndicator
                }

                // Transfer progress overlay
                if viewModel.showTransferView, let transferInfo = viewModel.transferInfo {
                    TransferProgressView(info: transferInfo,
                                         logLines: viewModel.transferLogLines) {
                        viewModel.cancelTransfer()
                    } onDismiss: {
                        viewModel.showTransferView = false
                    }
                }

                // Scrollback indicator
                if viewModel.isInScrollback {
                    scrollbackIndicator
                }

                // Connection log (the connecting overlay): stays up behind the failure dialog below,
                // which is why it is added first.
                if connectLog.isVisible {
                    ConnectionLogView(log: connectLog) {
                        cancelConnect()
                    }
                }

                // Disconnect overlay. An SSH / TelnetS *connect* failure shows the SSH debug log
                // window instead (Windows MainWindow.ShowConnectionFailedDialog does the same), so
                // the dialog is skipped for that case and the connection log stays visible behind it.
                // Not while a BBS window is closing (SessionMode, §12.57): it goes without a Disconnected dialog.
                if case .error(let message) = viewModel.connectionState,
                   !showsSshLogInsteadOfDialog(message), !SessionMode.closing {
                    disconnectOverlay(message: message)
                        .onAppear { AppState.shared.disconnectOverlayUp = true }
                        .onDisappear { AppState.shared.disconnectOverlayUp = false }
                }
            }
            .onAppear {
                // Connect captures the exact pre-connect bounds.
                // WindowSizeManager.mainWindow, not keyWindow: the CRT panel can be frontmost,
                // and its frame would then be restored onto the main window on disconnect.
                appState.preConnectFrame = WindowSizeManager.mainWindow?.frame
                // TRACE modules and physical key reports belong to the terminal while it's on screen
                TraceSessionManager.shared.setTerminalActive(true)
                TerminalKeyMonitor.shared.start()
                // xterm mouse reports and Rainwire's window protocol: switched on in the bridge before connecting
                TerminalMouse.enable()
                RainwireDesk.shared.enable()
                // Rainwire file drops (files=1): FileNo reasons as a 6 s toast; FileGo's send and FileGet's receive
                let dropsVm = viewModel
                RainwireFileDrops.shared.attach(
                    toast: { [weak dropsVm] text in dropsVm?.showToast(text, seconds: 6) },
                    runSend: { [weak dropsVm] paths in dropsVm?.runDropSend(paths) },
                    runReceive: { [weak dropsVm] folder, done in
                        if let vm = dropsVm {
                            vm.runDropReceive(folder, done)
                        } else {
                            done(false)
                        }
                    })
                viewModel.containerSize = geometry.size
                viewModel.loadFontBitmap()
                viewModel.connect(to: entry)
                appState.isConnected = true
                appState.connectedEntry = entry
                // A session started from the command line got as far as the terminal (spec §6).
                appState.consoleSession?.reachedTerminal = true
            }
            .onChange(of: geometry.size) { newSize in
                viewModel.containerSize = newSize
            }
            .onChange(of: viewModel.screenColumns) { _ in
                adjustWindowForTerminal()
            }
            .onChange(of: viewModel.screenRows) { _ in
                adjustWindowForTerminal()
            }
            // Set on connect; an 80x25 board never changes cols/rows, so without
            // this the window was never fitted at all.
            .onChange(of: viewModel.displayAspect) { _ in
                adjustWindowForTerminal()
            }
            // Settings over the session: on Windows the terminal leaves the screen, which closes TRACE; and no key
            // may stay held on the board underneath
            .onChange(of: appState.settingsOverTerminal) { covered in
                if covered {
                    TraceSessionManager.shared.closeAll()
                    TerminalKeyMonitor.shared.focusLost()
                }
            }
            .onChange(of: viewModel.showUploadPicker) { show in
                if show {
                    presentUploadPanel()
                }
            }
            .onDisappear {
                // The board may have hung up (or the user left) while the connection log was still
                // holding: it must never outlive the terminal.
                ConnectionLog.shared.hide()
                // The terminal left the screen: TRACE closes everything, held keys go up
                TerminalKeyMonitor.shared.stop()
                TraceSessionManager.shared.setTerminalActive(false)
                viewModel.disconnect()
                appState.isConnected = false
                appState.connectedEntry = nil
                // Release aspect-ratio lock so non-terminal screens resize freely.
                // ⚠️ Do NOT set contentAspectRatio = .zero here. Aspect ratio and resize
                // increments cancel each other and the LAST one set wins, so .zero after
                // the increments left a live 0:0 aspect lock — the next edge-drag divided
                // by zero and AppKit trapped in _adjustNeedsDisplayRegionForNewFrame
                // (crash on BBS exit, 2026-09-13). Setting the increments is the
                // documented way to clear the aspect ratio.
                if let window = WindowSizeManager.mainWindow {
                    window.resizeIncrements = NSSize(width: 1, height: 1)
                    window.contentResizeIncrements = NSSize(width: 1, height: 1)
                    // Disconnect restores the exact pre-connect position and size. Not in a BBS window, which is
                    // closing and remembers the terminal's own frame (SessionMode.saveWindow).
                    if !SessionMode.isSession,
                       let frame = appState.preConnectFrame, frame.width > 0, frame.height > 0 {
                        window.setFrame(frame, display: true, animate: false)
                    }
                }
                appState.preConnectFrame = nil
            }
            .onChange(of: viewModel.connectionState) { state in
                guard case .error(let message) = state, showsSshLogInsteadOfDialog(message) else { return }
                presentSshLogForFailure()
            }
            // Hosted here, not inside `disconnectOverlay`: for an SSH / TelnetS connect failure that
            // dialog is never built, so a sheet attached to it would not exist to be presented.
            .sheet(isPresented: $showingSshDebug, onDismiss: {
                guard sshDebugEndsSession else { return }
                sshDebugEndsSession = false
                endFailedSession()
            }) {
                SshDebugView(logText: sshDebugLog)
            }
            .onReceive(NotificationCenter.default.publisher(for: .sendLoginRequested)) { _ in
                viewModel.sendLoginSequence()
            }
            .onReceive(NotificationCenter.default.publisher(for: .sendFileRequested)) { _ in
                viewModel.showUploadPicker = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .xmodemSendRequested)) { note in
                presentXmodemSendPanel(note)
            }
            .onReceive(NotificationCenter.default.publisher(for: .xmodemReceiveRequested)) { note in
                presentXmodemReceive(note)
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleLogging)) { _ in
                if viewModel.isLogging {
                    viewModel.stopLogging()
                } else {
                    viewModel.startLogging()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .captureScreenshot)) { _ in
                presentScreenshotSavePanel()
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleScrollback)) { _ in
                toggleScrollbackWithNotice()
            }
            .onReceive(NotificationCenter.default.publisher(for: .saveSnapshot)) { _ in
                if let data = viewModel.captureSnapshotData() {
                    viewModel.saveSnapshot(data)
                }
            }
            }

            statusBar
                .screenEffect(phosphor: PhosphorMode(rawValue: phosphor) ?? .color)
        }
        .background(Color.black.ignoresSafeArea())
    }

    // MARK: - Cancel a connect

    /// CANCEL in the connection log: hide the overlay at once and go home ("aborted by user" is
    /// written but rarely seen). The blocking native connect can't be cancelled, only interrupted —
    /// `native_disconnect()` sets `conn_api.terminate`, which is what makes it return; the next
    /// attempt still waits for it through `NativeBridge.isConnectInFlight`.
    private func cancelConnect() {
        connectLog.cancelAttempt()
        NativeBridge.shared.disconnect()
        appState.isConnected = false
        appState.connectedEntry = nil
        appState.currentView = .home
    }

    // MARK: - Copy Selected Text

    private func copySelectedText() {
        if let text = viewModel.getSelectedText(), !text.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            viewModel.cancelSelection()
        }
    }

    private func selectAllText() {
        viewModel.isSelecting = true
        viewModel.selectionAnchorCol = 0
        viewModel.selectionAnchorRow = 0
        viewModel.selectionEndCol = viewModel.screenColumns - 1
        viewModel.selectionEndRow = viewModel.screenRows - 1
    }

    // MARK: - Right-Click Context Menu

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()

        func addAction(_ title: String, to m: NSMenu, enabled: Bool = true, action: @escaping () -> Void) {
            let handler = ContextMenuActions(action)
            let item = NSMenuItem(title: title, action: #selector(ContextMenuActions.performAction(_:)), keyEquivalent: "")
            item.target = handler
            item.representedObject = handler  // prevent ARC from releasing the handler
            item.isEnabled = enabled
            m.addItem(item)
        }

        // Copy
        let hasSelection = viewModel.isSelecting && (viewModel.getSelectedText()?.isEmpty == false)
        addAction("Copy", to: menu, enabled: hasSelection) { [self] in
            copySelectedText()
        }

        // Paste
        let hasClipboard = NSPasteboard.general.string(forType: .string) != nil
        addAction("Paste", to: menu, enabled: hasClipboard) { [self] in
            // Sent straight to the view model, not through the typing path, so a paste never clicks
            if let clipboard = NSPasteboard.general.string(forType: .string) {
                viewModel.sendPaste(clipboard)
            }
        }

        addAction(viewModel.isInScrollback ? "Back to Live Screen" : "Scrollback", to: menu,
                  enabled: viewModel.connectionState == .connected) { [self] in
            toggleScrollbackWithNotice()
        }

        menu.addItem(.separator())

        // Show/Hide Cursor
        let cursorTitle = viewModel.userHideCursor ? "Show Cursor" : "Hide Cursor"
        addAction(cursorTitle, to: menu) { [self] in
            viewModel.userHideCursor.toggle()
        }

        menu.addItem(.separator())

        // Send File (ZMODEM)
        addAction("Send File (ZMODEM)...", to: menu) { [self] in
            viewModel.showUploadPicker = true
        }

        menu.addItem(.separator())

        // Capture Screenshot
        addAction("Capture Screenshot...", to: menu) { [self] in
            presentScreenshotSavePanel()
        }

        // Snapshot — same name as every other client's phonebook-image action. Not in a board's linked window (12.73):
        // it has no phonebook entry.
        if !SessionMode.isLinked {
            addAction("Snapshot", to: menu) { [self] in
                if let data = viewModel.captureSnapshotData() {
                    viewModel.saveSnapshot(data)
                }
            }
        }

        menu.addItem(.separator())

        // Toggle Logging
        let logTitle = viewModel.isLogging ? "Stop Logging" : "Start Logging"
        addAction(logTitle, to: menu) { [self] in
            if viewModel.isLogging {
                viewModel.stopLogging()
            } else {
                viewModel.startLogging()
            }
        }

        menu.addItem(.separator())

        // Disconnect
        addAction("Disconnect", to: menu) { [self] in
            viewModel.disconnect()
            appState.isConnected = false
            appState.connectedEntry = nil
            appState.currentView = .home
        }

        return menu
    }

    // MARK: - File Upload Panel

    private func presentUploadPanel() {
        let panel = NSOpenPanel()
        panel.title = "Select File to Upload"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true

        panel.begin { response in
            DispatchQueue.main.async {
                viewModel.showUploadPicker = false
                if response == .OK {
                    let urls = panel.urls
                    if urls.count > 1 {
                        viewModel.queueUploadBatch(fileURLs: urls)
                    } else if let url = urls.first {
                        viewModel.queueUpload(fileURL: url)
                    }
                }
            }
        }
    }

    // MARK: - X / YMODEM Panels

    /// Pull the mode bits and display name out of a menu notification.
    private func xmodemRequest(_ note: Notification) -> (mode: Int, name: String)? {
        guard let mode = note.userInfo?["mode"] as? Int else { return nil }
        let name = note.userInfo?["protocolName"] as? String ?? "XMODEM"
        return (mode, name)
    }

    private func presentXmodemSendPanel(_ note: Notification) {
        guard let req = xmodemRequest(note) else { return }

        let panel = NSOpenPanel()
        panel.title = "Select a file to send via \(req.name)"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        // X/YMODEM batch is not supported — see startXmodemSend
        panel.allowsMultipleSelection = false

        panel.begin { response in
            DispatchQueue.main.async {
                guard response == .OK, let url = panel.urls.first else { return }
                viewModel.startXmodemSend(fileURL: url, mode: req.mode)
            }
        }
    }

    private func presentXmodemReceive(_ note: Notification) {
        guard let req = xmodemRequest(note) else { return }

        // YMODEM sends the name in its header block and goes straight to the
        // download directory. XMODEM carries no filename at all, so the only way
        // to know where this lands is to ask BEFORE the transfer starts.
        guard (req.mode & NativeBridge.XferMode.xmodem) != 0 else {
            viewModel.startXmodemReceive(savePath: nil, mode: req.mode)
            return
        }

        let downloadDir = TransferManager.resolveDownloadDirectory()
        try? FileManager.default.createDirectory(at: downloadDir, withIntermediateDirectories: true)

        let panel = NSSavePanel()
        panel.title = "Save the incoming XMODEM file as"
        panel.directoryURL = downloadDir
        panel.nameFieldStringValue = "download.bin"

        panel.begin { response in
            DispatchQueue.main.async {
                guard response == .OK, let url = panel.url else { return }

                // The save panel has already asked about an existing file and
                // the user said yes, so tell the native side to honour that.
                // Without the flag xmodem_recv_files() side-steps the collision
                // via xmodem_unique_path() and writes "download (1).bin" instead
                // — which looks exactly like a transfer that silently did
                // nothing, because the file the user is watching never changes.
                let mode = req.mode | NativeBridge.XferMode.overwrite
                viewModel.startXmodemReceive(savePath: url.path, mode: mode)
            }
        }
    }

    // MARK: - Screenshot / Snapshot

    private func presentScreenshotSavePanel() {
        guard let pngData = viewModel.captureSnapshotData() else {
            termLogger.warning("Failed to capture screenshot data")
            return
        }

        let panel = NSSavePanel()
        panel.title = "Save Screenshot"
        panel.nameFieldStringValue = "TERMinator_Screenshot.png"
        panel.allowedContentTypes = [.png]

        panel.begin { response in
            if response == .OK, let url = panel.url {
                do {
                    try pngData.write(to: url)
                    termLogger.info("Screenshot saved to \(url.path)")
                } catch {
                    termLogger.error("Failed to save screenshot: \(error.localizedDescription)")
                }
            }
        }

        // Also update the phonebook thumbnail (not from a board's linked window, 12.73: that's another screen of the
        // same board)
        if !SessionMode.isLinked {
            viewModel.saveSnapshot(pngData)
        }
    }

    // MARK: - Selection Overlay

    private func selectionOverlay(in geometry: GeometryProxy) -> some View {
        let cell = cellSizeInPoints(in: geometry)
        let origin = terminalOrigin(in: geometry)
        let minCol = viewModel.selectionMinCol
        let maxCol = viewModel.selectionMaxCol
        let minRow = viewModel.selectionMinRow
        let maxRow = viewModel.selectionMaxRow

        let x = origin.x + CGFloat(minCol) * cell.w
        let y = origin.y + CGFloat(minRow) * cell.h
        let w = CGFloat(maxCol - minCol + 1) * cell.w
        let h = CGFloat(maxRow - minRow + 1) * cell.h

        return Rectangle()
            .fill(Color.blue.opacity(0.3))
            .border(Color.blue.opacity(0.5), width: 1)
            .frame(width: w, height: h)
            .position(x: x + w / 2, y: y + h / 2)
            .allowsHitTesting(false)
    }

    // MARK: - URL Underline Overlays

    private func urlUnderlineOverlays(in geometry: GeometryProxy) -> some View {
        let cell = cellSizeInPoints(in: geometry)
        let origin = terminalOrigin(in: geometry)

        return ForEach(Array(viewModel.detectedURLs.enumerated()), id: \.offset) { _, detected in
            let x = origin.x + CGFloat(detected.startColumn) * cell.w
            let y = origin.y + CGFloat(detected.row) * cell.h + cell.h - 1
            let w = CGFloat(detected.endColumn - detected.startColumn) * cell.w

            Rectangle()
                .fill(paletteColor(detected.fgColorIndex))
                .frame(width: w, height: 1)
                .position(x: x + w / 2, y: y)
                .allowsHitTesting(false)
        }
    }

    /// Convert a palette index to a SwiftUI Color (palette stores BGRA as Int32)
    private func paletteColor(_ index: Int) -> Color {
        guard index >= 0, index < viewModel.palette.count else { return .white }
        let bgra = UInt32(bitPattern: viewModel.palette[index])
        let b = Double((bgra >> 0) & 0xFF) / 255.0
        let g = Double((bgra >> 8) & 0xFF) / 255.0
        let r = Double((bgra >> 16) & 0xFF) / 255.0
        return Color(red: r, green: g, blue: b)
    }

    /// View > Scrollback and the terminal's right-click menu (Ctrl+B in the keyboard view does the same, quietly).
    private func toggleScrollbackWithNotice() {
        if !viewModel.toggleBufferMode() {
            viewModel.showToast("Nothing to scroll back to yet")
        } else if viewModel.isInScrollback {
            viewModel.showToast("Scrollback: mouse wheel scrolls, any key returns")
        }
    }

    // MARK: - Scroll Wheel

    private func handleScrollWheel(delta: CGFloat) {
        scrollAccumulator += delta
        if abs(scrollAccumulator) >= scrollThreshold {
            let lines = Int(scrollAccumulator / scrollThreshold)
            viewModel.setScrollbackOffset(viewModel.scrollbackOffset - lines)
            scrollAccumulator = scrollAccumulator.truncatingRemainder(dividingBy: scrollThreshold)
        }
    }

    // MARK: - Cell Size Helpers

    private func cellSizeInPoints(in geometry: GeometryProxy) -> (w: CGFloat, h: CGFloat) {
        let fontW = viewModel.fontWidth > 0 ? CGFloat(viewModel.fontWidth) : 8
        let fontH = viewModel.fontHeight > 0 ? CGFloat(viewModel.fontHeight) : 16
        let cols = CGFloat(viewModel.screenColumns > 0 ? viewModel.screenColumns : 80)
        let rows = CGFloat(viewModel.screenRows > 0 ? viewModel.screenRows : 25)
        let terminalNativeWidth = cols * fontW
        let terminalNativeHeight = rows * fontH
        guard terminalNativeWidth > 0, terminalNativeHeight > 0,
              geometry.size.width > 0, geometry.size.height > 0 else {
            return (fontW, fontH)
        }

        // ⚠️ macOS PETSCII 2026-09-04: SAME algorithm as the Metal renderer's quad,
        // INCLUDING the forced display aspect. EVERY mode forces one now — 4:3 for the
        // ANSI modes, 6:5 for the 40-column Commodore ones — so this is the normal
        // path, not a PETSCII special case.
        // A forced aspect makes the two axis scales differ, so cell
        // width and cell height must be derived separately — sharing one scale puts
        // every click and overlay a growing distance off down the screen. With
        // displayAspect nil this is arithmetically identical to the min() scale it
        // replaced.
        let naturalAspect = terminalNativeWidth / terminalNativeHeight
        let aspect = viewModel.displayAspect ?? naturalAspect
        var renderW = geometry.size.width
        var renderH = aspect > 0 ? renderW / aspect : geometry.size.height
        if renderH > geometry.size.height {
            renderH = geometry.size.height
            renderW = renderH * aspect
        }

        return (renderW / cols, renderH / rows)
    }

    /// A point's column or row from its offset in cells. While a window closes its geometry collapses to zero, so
    /// the cell size is 0 and the offset infinite or NaN; Int() of that traps (a linked Dead Modem TV window crashed
    /// on a mouse-move during quit). Off-grid answers -1, and a finite value is clamped well inside Int.
    private static func cellIndex(_ cells: CGFloat) -> Int {
        guard cells.isFinite else { return -1 }
        return Int(max(-1, min(cells, 100_000)))
    }

    /// Origin offset for aspect-fit centering (matches Metal quad centering)
    private func terminalOrigin(in geometry: GeometryProxy) -> (x: CGFloat, y: CGFloat) {
        // Derived from cellSizeInPoints so it includes the forced displayAspect — a
        // separate uniform min() scale here put the origin in the wrong place and
        // shifted every click sideways.
        let cell = cellSizeInPoints(in: geometry)
        let cols = CGFloat(viewModel.screenColumns > 0 ? viewModel.screenColumns : 80)
        let renderW = cell.w * cols
        // Center horizontally, top-align vertically (matches Metal quad)
        return ((geometry.size.width - renderW) / 2.0, 0)
    }

    /// The terminal picture inside the terminal area (top-left origin): where the text screen is drawn, which
    /// leaves out any letterbox bands. Rainwire's menu drawn here puts its header and rain on it (1.1.6).
    private func pictureRect(in geometry: GeometryProxy) -> CGRect {
        let cell = cellSizeInPoints(in: geometry)
        let origin = terminalOrigin(in: geometry)
        let cols = CGFloat(viewModel.screenColumns > 0 ? viewModel.screenColumns : 80)
        let rows = CGFloat(viewModel.screenRows > 0 ? viewModel.screenRows : 25)
        return CGRect(x: origin.x, y: origin.y, width: cell.w * cols, height: cell.h * rows)
    }

    // MARK: - TAP+ Overlays
    // ⚠️ 2026-09-18: every overlay adds terminalOrigin(in:) — the Metal quad is centred
    // horizontally, so in a height-limited area (zoomed/full screen, wider than 4:3) the
    // picture starts at origin.x, not 0. Without it TAP+ drifted left of the text
    // (Windows/Linux offset by GetBbsScreenRect().X the same way).

    private func videoOverlay(player: AVPlayer, in geometry: GeometryProxy) -> some View {
        let cell = cellSizeInPoints(in: geometry)
        let origin = terminalOrigin(in: geometry)
        let x = origin.x + CGFloat(viewModel.videoCol - 1) * cell.w
        let y = origin.y + CGFloat(viewModel.videoRow - 1) * cell.h
        let w = CGFloat(viewModel.videoCellW) * cell.w
        let h = CGFloat(viewModel.videoCellH) * cell.h

        // Size the view to match the video's native aspect ratio within the
        // cell bounding box — no letterboxing, matching Android's fitWithinRect.
        let nw = viewModel.videoNativeWidth
        let nh = viewModel.videoNativeHeight
        let fitW: CGFloat
        let fitH: CGFloat
        let offX: CGFloat
        let offY: CGFloat
        if nw > 0 && nh > 0 {
            let scale = min(w / nw, h / nh)
            fitW = nw * scale
            fitH = nh * scale
            offX = x + (w - fitW) / 2
            offY = y + (h - fitH) / 2
        } else {
            fitW = w
            fitH = h
            offX = x
            offY = y
        }

        return AVPlayerLayerView(player: player)
            .frame(width: fitW, height: fitH)
            .position(x: offX + fitW / 2, y: offY + fitH / 2)
            .allowsHitTesting(false)
    }

    private func imageOverlay(image: NSImage, channel: Int, in geometry: GeometryProxy) -> some View {
        let ch = viewModel.imageChannels[channel]
        let cell = cellSizeInPoints(in: geometry)
        let origin = terminalOrigin(in: geometry)
        let x = origin.x + CGFloat(ch.col - 1) * cell.w
        let y = origin.y + CGFloat(ch.row - 1) * cell.h
        let w = CGFloat(ch.cellW) * cell.w
        let h = CGFloat(ch.cellH) * cell.h

        // Aspect-fit within the bounding box, matching iOS behavior.
        let bw = image.size.width
        let bh = image.size.height
        let imgScale = min(w / max(bw, 1), h / max(bh, 1))
        let fitW = bw * imgScale
        let fitH = bh * imgScale

        return AnimatedImageView(image: image, scaleToFill: false)
            .frame(width: fitW, height: fitH)
            .position(x: x + w / 2, y: y + h / 2)
            .allowsHitTesting(false)
    }

    /// A TERMinator:Pic slot: fitted inside its cell rect keeping its aspect, centred (as imageOverlay). Recomputed
    /// from the geometry on every layout, so it follows resize, font, zoom and full screen.
    private func picOverlay(image: NSImage, slot: Int, in geometry: GeometryProxy) -> some View {
        let pic = viewModel.picSlots[slot]
        let cell = cellSizeInPoints(in: geometry)
        let origin = terminalOrigin(in: geometry)
        let x = origin.x + CGFloat(pic.col1 - 1) * cell.w
        let y = origin.y + CGFloat(pic.row1 - 1) * cell.h
        let w = CGFloat(pic.col2 - pic.col1 + 1) * cell.w
        let h = CGFloat(pic.row2 - pic.row1 + 1) * cell.h

        var fitW = w
        var fitH = h
        if pic.pixelW > 0 && pic.pixelH > 0 {
            // Fit as if cells were 8x16 (how the board draws the still under it), then stretch with the
            // screen: on cells taller than 1:2 an aspect fit sat lower and left the art's edge rows showing.
            let picW = pic.pixelW * cell.w / 8, picH = pic.pixelH * cell.h / 16
            let scale = min(w / picW, h / picH)
            fitW = picW * scale
            fitH = picH * scale
        }

        return AnimatedImageView(image: image, scaleToFill: true)
            .frame(width: fitW, height: fitH)
            .position(x: x + w / 2, y: y + h / 2)
            .allowsHitTesting(false)
    }

    private func bgImageOverlay(image: NSImage, in geometry: GeometryProxy) -> some View {
        let cell = cellSizeInPoints(in: geometry)
        let origin = terminalOrigin(in: geometry)
        let x = origin.x + CGFloat(viewModel.bgCol) * cell.w
        let y = origin.y + CGFloat(viewModel.bgRow) * cell.h
        let w = CGFloat(viewModel.bgCellW) * cell.w
        let h = CGFloat(viewModel.bgCellH) * cell.h

        return AnimatedImageView(image: image, scaleToFill: true)
            .frame(width: w, height: h)
            .position(x: x + w / 2, y: y + h / 2)
            .opacity(viewModel.bgOpacity)
            .allowsHitTesting(false)
    }

    private func tileMapOverlay(in geometry: GeometryProxy) -> some View {
        let cell = cellSizeInPoints(in: geometry)
        let gridRows = viewModel.tileMapRow2 - viewModel.tileMapRow1 + 1
        let gridCols = viewModel.tileMapCol2 - viewModel.tileMapCol1 + 1
        let origin = terminalOrigin(in: geometry)
        let x = origin.x + CGFloat(viewModel.tileMapCol1) * cell.w
        let y = origin.y + CGFloat(viewModel.tileMapRow1) * cell.h
        let w = CGFloat(gridCols) * cell.w
        let h = CGFloat(gridRows) * cell.h

        return TileMapCanvasView(viewModel: viewModel)
            .frame(width: w, height: h)
            .position(x: x + w / 2, y: y + h / 2)
            .opacity(viewModel.tileOpacity)
            .allowsHitTesting(false)
    }

    private func logoOverlay(image: NSImage, in geometry: GeometryProxy) -> some View {
        let cell = cellSizeInPoints(in: geometry)
        let maxCols = CGFloat(viewModel.screenColumns)
        let maxRows = CGFloat(viewModel.screenRows)
        let clampedW = min(CGFloat(viewModel.logoCellW), maxCols)
        let clampedH = min(CGFloat(viewModel.logoCellH), maxRows)
        let origin = terminalOrigin(in: geometry)
        let x = origin.x + CGFloat(viewModel.logoCol - 1) * cell.w
        let y = origin.y + CGFloat(viewModel.logoRow - 1) * cell.h
        let w = clampedW * cell.w
        let h = clampedH * cell.h

        // Fill the full cell area — scaleToFill stretches the logo to fill,
        // matching Android's fillRect + scaleType="fitXY" behavior
        return AnimatedImageView(image: image, scaleToFill: true)
            .frame(width: w, height: h)
            .position(x: x + w / 2, y: y + h / 2)
            .allowsHitTesting(false)
    }

    private func visualizerOverlay(in geometry: GeometryProxy) -> some View {
        let cell = cellSizeInPoints(in: geometry)
        let origin = terminalOrigin(in: geometry)
        return VisualizerOverlayView(
            audioAnalyzer: SoundtrackManager.shared.audioAnalyzer,
            row: viewModel.visualizerRow,
            col: viewModel.visualizerCol,
            cellsWide: viewModel.visualizerCellW,
            cellsHigh: viewModel.visualizerCellH,
            style: viewModel.visualizerStyle,
            cellWidth: cell.w,
            cellHeight: cell.h,
            panOffsetX: origin.x,
            panOffsetY: origin.y
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Disconnect Overlay

    private func disconnectOverlay(message: String) -> some View {
        // Match Windows ShowDisconnectedDialog / ShowConnectionFailedDialog titles
        let title: String
        let body: String
        let lower = message.lowercased()
        if lower.contains("timed out") || lower.contains("timeout") {
            title = "CONNECTION TIMED OUT"
            body = "Could not reach \(entry.name) within \(AppPreferences.connectionTimeout) seconds."
        } else if lower.contains("failed to") {
            title = "CONNECTION FAILED"
            body = "Failed to connect to \(entry.name)."
        } else {
            title = "DISCONNECTED"
            body = "Session with \(entry.name) has ended."
        }

        return ZStack {
            Color.black.opacity(0.6)

            VStack(spacing: 16) {
                Text(title)
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundColor(.termLightRed)

                Text(body)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(.termLightGreen)
                    .multilineTextAlignment(.center)

                if title == "DISCONNECTED" {
                    Text("Closing in \(disconnectSecondsLeft)s")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.gray)
                }

                HStack(spacing: 12) {
                    // TelnetS too: it runs the same SSH-side debug log, and gating on .ssh alone
                    // meant a TelnetS session could never show it.
                    if entry.connectionProtocol == .ssh || entry.connectionProtocol == .telnetS {
                        RetroButton("View SSH Log", style: .green) {
                            sshDebugLog = NativeBridge.shared.getSshDebugLog()
                            // On demand from this dialog: closing the log must NOT end the session,
                            // the OK button below does that.
                            sshDebugEndsSession = false
                            showingSshDebug = true
                        }
                        .frame(width: 140)
                    }

                    RetroButton("OK", style: .amber) {
                        // The connection log sat behind this dialog; it goes with it.
                        endFailedSession()
                    }
                    .keyboardShortcut(.defaultAction)
                    .frame(width: 120)
                }
                .padding(.top, 8)
            }
            .padding(32)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.termLightRed, lineWidth: 2)
            )
        }
        // Only a plain disconnect counts down; a failed or timed-out connect waits for OK. Leaving the
        // overlay (OK) cancels the task.
        .task(id: message) {
            guard title == "DISCONNECTED" else { return }
            disconnectSecondsLeft = 10
            while disconnectSecondsLeft > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                disconnectSecondsLeft -= 1
            }
            endFailedSession()   // what OK does
        }
    }

    /// True for a *connect* failure on SSH or TelnetS — the case where Windows shows the SSH debug
    /// log window in place of the connection-failed dialog. A plain mid-session disconnect, and every
    /// other protocol, still gets the dialog.
    private func showsSshLogInsteadOfDialog(_ message: String) -> Bool {
        guard entry.connectionProtocol == .ssh || entry.connectionProtocol == .telnetS else { return false }
        let lower = message.lowercased()
        return lower.contains("timed out") || lower.contains("timeout") || lower.contains("failed to")
    }

    /// Opens the SSH debug log in place of the connection-failed dialog. An empty native log still
    /// gets a window, with the same placeholder Windows writes.
    private func presentSshLogForFailure() {
        var log = NativeBridge.shared.getSshDebugLog()
        if log.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let name = entry.connectionProtocol == .telnetS ? "TelnetS" : "SSH"
            log = "Connection to \(entry.host):\(entry.port) failed.\n"
                + "Protocol: \(name)\n"
                + "Username: \(entry.username.isEmpty ? "(none)" : entry.username)\n\n"
                + "(No \(name) debug log was captured \u{2014} the connection may have failed before "
                + "negotiation started.)"
        }
        sshDebugLog = log
        sshDebugEndsSession = true
        showingSshDebug = true
    }

    /// Ends a failed session: the connection log sat behind the dialog / debug window and goes with it.
    private func endFailedSession() {
        ConnectionLog.shared.hide()
        viewModel.disconnect()
        appState.isConnected = false
        appState.connectedEntry = nil
        appState.currentView = .home
    }

    // MARK: - Status Indicators

    private var loggingIndicator: some View {
        VStack {
            HStack {
                Spacer()
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                    Text("REC")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                }
                .padding(4)
                .background(Color.black.opacity(0.6))
                .cornerRadius(4)
                .padding(8)
            }
            Spacer()
        }
    }

    /// The SCROLLBACK banner, as Windows `TerminalCanvas.OnRender` draws it: "SCROLLBACK (N lines)" in white
    /// 12 pt monospace (Consolas there, Menlo here), centred at the very top of the terminal on an 80%-black
    /// (0xCC) box padded 6 pt left/right and 2 pt top/bottom, square corners. Shown only while scrolled back.
    private var scrollbackIndicator: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                Text("SCROLLBACK (\(viewModel.scrollbackOffset) lines)")
                    .font(.custom("Menlo", size: 12))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.8))
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
        }
        .allowsHitTesting(false)
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack(spacing: 16) {
            // BBS name & protocol
            Text("\(entry.name) [\(entry.connectionProtocol.displayName)]")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(.termBrown)

            // Connection duration
            if let connectedAt = viewModel.connectedAt {
                Text(connectedAt, style: .timer)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.termLightGreen)
            }

            Spacer()

            // A Rainwire board's tray gadgets (1.1.6 scenes v6: RainwireMenu.swift RainwireTrayView): pills that open
            // the gadget in a popover; empty (and hidden) unless the board keeps GF_TRAY gadgets. Windows: the
            // RainwireTrayHost in the status bar's column 1, right-aligned.
            RainwireTrayLayer()
                .fixedSize()
                .frame(height: 20)

            // Modem front-panel lights (between the connection time and the screen mode, as on Windows)
            if showModemLights {
                ModemLightsView(model: modemLights)
            }

            // Screen mode
            Text(entry.screenMode.displayName)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.textSecondary)

            // Logging indicator
            if viewModel.isLogging {
                HStack(spacing: 3) {
                    Circle()
                        .fill(Color.termLightRed)
                        .frame(width: 6, height: 6)
                    Text("LOG")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.termLightRed)
                }
            }

            // Byte counters
            Text("↑\(formatBytes(viewModel.bytesSent))  ↓\(formatBytes(viewModel.bytesReceived))")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.termLightCyan)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.85))
        .onAppear {
            let viewModel = self.viewModel
            modemLights.readCounters = {
                guard viewModel.connectionState == .connected,
                      let stats = NativeBridge.shared.getConnectionStats() else { return nil }
                return (stats.bytesSent, stats.bytesReceived)
            }
            modemLights.readEffectiveBps = { NativeBridge.shared.effectiveBps() }
            if viewModel.connectedAt != nil {
                modemLights.start()
            }
        }
        // Lights run for as long as the call is up
        .onChange(of: viewModel.connectedAt) { connectedAt in
            if connectedAt != nil {
                modemLights.start()
            } else {
                modemLights.stop()
            }
        }
        .onDisappear {
            modemLights.stop()
        }
    }

    private func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes)B" }
        if bytes < 1024 * 1024 { return String(format: "%.1fK", Double(bytes) / 1024) }
        return String(format: "%.1fM", Double(bytes) / (1024 * 1024))
    }

    // MARK: - Window Auto-sizing (matches Windows AdjustWindowForTerminal)

    /// Resize the window so the terminal area has the shape the renderer draws.
    /// Preserves the current width when possible; clamps to screen height.
    private func adjustWindowForTerminal() {
        let cols = viewModel.screenColumns
        let rows = viewModel.screenRows
        let fontW = viewModel.fontWidth > 0 ? viewModel.fontWidth : 8
        let fontH = viewModel.fontHeight > 0 ? viewModel.fontHeight : 16
        guard cols > 0, rows > 0 else { return }

        // ⚠️ Size to the aspect the Metal quad ACTUALLY draws, including the forced
        // displayAspect (4:3 per 25 rows for the ANSI modes). Sizing to the raw bitmap
        // (cols*fontW : rows*fontH) left the picture pillarboxed — 80x50 draws at 2:3
        // but the window was shaped 1.6:1 — with dead space left and right.
        let bitmapAspect = CGFloat(cols * fontW) / CGFloat(rows * fontH)
        let aspect = viewModel.displayAspect ?? bitmapAspect
        guard aspect > 0 else { return }

        // Defer until layout settles so window.frame reflects current state.
        DispatchQueue.main.async {
            guard let window = NSApp.keyWindow ?? NSApp.windows.first else { return }
            guard let screen = window.screen ?? NSScreen.main else { return }

            let currentFrame = window.frame
            let contentRect = window.contentRect(forFrameRect: currentFrame)
            let chromeH = currentFrame.height - contentRect.height

            // Content that is not terminal area (the status bar). containerSize is
            // the terminal GeometryReader's size, so the difference is exact.
            let terminalArea = viewModel.containerSize
            let extraH = terminalArea.height > 0 ? max(0, contentRect.height - terminalArea.height) : 0

            var termW = contentRect.width
            var termH = (termW / aspect).rounded()

            // Clamp to screen visible area, narrowing the window to keep the aspect.
            let workArea = screen.visibleFrame
            let maxTermH = workArea.height - chromeH - extraH
            if termH > maxTermH {
                termH = maxTermH
                termW = (termH * aspect).rounded()
            }

            // Never hand AppKit a degenerate size — a zero or non-finite aspect traps it.
            guard termW > 0, termH > 0, termW.isFinite, termH.isFinite else { return }

            // Lock window aspect ratio for manual resizes.
            window.contentAspectRatio = NSSize(width: termW, height: termH + extraH)

            // Keep top-left corner stable so window doesn't jump around.
            let newH = termH + extraH + chromeH
            let newFrame = NSRect(
                x: currentFrame.minX,
                y: max(workArea.minY, currentFrame.maxY - newH),
                width: termW,
                height: newH
            )
            window.setFrame(newFrame, display: true, animate: false)
        }
    }
}

// MARK: - Window Accessor

// MARK: - Scroll Wheel Modifier

extension View {
    func onScrollWheel(perform action: @escaping (CGFloat) -> Void) -> some View {
        self.background(ScrollWheelView(onScroll: action))
    }
}

struct ScrollWheelView: NSViewRepresentable {
    let onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> ScrollWheelNSView {
        let view = ScrollWheelNSView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: ScrollWheelNSView, context: Context) {
        nsView.onScroll = onScroll
    }
}

class ScrollWheelNSView: NSView {
    var onScroll: ((CGFloat) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        // macOS turns Shift+wheel sideways; Shift+wheel is how scrollback is reached while a board has the wheel
        var delta = event.scrollingDeltaY
        if delta == 0 && event.modifierFlags.contains(.shift) {
            delta = event.scrollingDeltaX
        }
        onScroll?(delta)
    }
}

// MARK: - Context Menu Action Helper

/// Helper class that allows NSMenuItem to fire Swift closures.
/// Set an instance as both the target and representedObject of the menu item.
final class ContextMenuActions: NSObject {
    let closure: () -> Void

    init(_ closure: @escaping () -> Void) {
        self.closure = closure
    }

    @objc func performAction(_ sender: Any?) {
        closure()
    }
}

// MARK: - AVPlayer Layer View (lightweight video rendering without controls)

struct AVPlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> NSView {
        let view = PlayerContainerView()
        view.wantsLayer = true
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let container = nsView as? PlayerContainerView else { return }
        if container.playerLayer.player !== player {
            container.playerLayer.player = player
        }
    }

    private class PlayerContainerView: NSView {
        override func makeBackingLayer() -> CALayer { AVPlayerLayer() }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

// MARK: - Animated Image View (supports animated GIFs via NSImageView)

struct AnimatedImageView: NSViewRepresentable {
    let image: NSImage
    var scaleToFill: Bool = false

    func makeNSView(context: Context) -> NSImageView {
        let iv = NSImageView()
        iv.imageScaling = scaleToFill ? .scaleAxesIndependently : .scaleProportionallyUpOrDown
        iv.animates = true
        iv.canDrawSubviewsIntoLayer = true
        iv.wantsLayer = true
        iv.layer?.backgroundColor = NSColor.clear.cgColor
        // Ensure NSImageView respects its SwiftUI frame instead of using intrinsic image size
        iv.setContentHuggingPriority(.defaultLow, for: .horizontal)
        iv.setContentHuggingPriority(.defaultLow, for: .vertical)
        iv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        iv.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return iv
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        nsView.imageScaling = scaleToFill ? .scaleAxesIndependently : .scaleProportionallyUpOrDown
        if nsView.image !== image {
            nsView.image = image
            nsView.animates = true
        }
    }
}

/// Renders the tile map grid as an NSImage from atlas pixel data.
struct TileMapCanvasView: NSViewRepresentable {
    @ObservedObject var viewModel: TerminalViewModel

    func makeNSView(context: Context) -> NSImageView {
        let iv = NSImageView()
        iv.imageScaling = .scaleAxesIndependently
        iv.wantsLayer = true
        iv.layer?.backgroundColor = NSColor.clear.cgColor
        iv.setContentHuggingPriority(.defaultLow, for: .horizontal)
        iv.setContentHuggingPriority(.defaultLow, for: .vertical)
        iv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        iv.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return iv
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        let grid = viewModel.tileGrid
        let atlasPixels = viewModel.tileAtlasPixels
        let atlasW = viewModel.tileAtlasWidth
        let spriteW = viewModel.tileSpriteW
        let spriteH = viewModel.tileSpriteH
        guard !grid.isEmpty, !atlasPixels.isEmpty, atlasW > 0, spriteW > 0, spriteH > 0 else {
            nsView.image = nil
            return
        }

        // Auto-detect tile scale from sprite dimensions:
        // 8x16 = 1x, 16x32 = 2x, 32x64 = 4x
        let tileScale: Int
        if viewModel.tileScaleOverride > 0 {
            tileScale = viewModel.tileScaleOverride
        } else if spriteW >= 32 && spriteH >= 64 {
            tileScale = 4
        } else if spriteW >= 16 && spriteH >= 32 {
            tileScale = 2
        } else {
            tileScale = 1
        }

        // Scaled cell dimensions for the composited image
        let cellW = 8 * tileScale
        let cellH = 16 * tileScale

        let gridH = grid.count
        let gridW = grid.first?.count ?? 0
        let imgW = gridW * cellW
        let imgH = gridH * cellH
        guard imgW > 0, imgH > 0 else { return }

        let spritesPerRow = max(1, atlasW / spriteW)

        var pixels = [UInt32](repeating: 0, count: imgW * imgH)  // transparent
        for tRow in 0..<gridH {
            for tCol in 0..<gridW {
                let spriteId = grid[tRow][tCol]
                guard spriteId >= 0 else { continue }
                let srcCol = spriteId % spritesPerRow
                let srcRow = spriteId / spritesPerRow
                let srcX = srcCol * spriteW
                let srcY = srcRow * spriteH
                let dstX = tCol * cellW
                let dstY = tRow * cellH
                for y in 0..<cellH {
                    let sy = spriteH == cellH ? y : y * spriteH / cellH
                    let srcOff = (srcY + sy) * atlasW + srcX
                    let dstOff = (dstY + y) * imgW + dstX
                    for x in 0..<cellW {
                        let sx = spriteW == cellW ? x : x * spriteW / cellW
                        if srcOff + sx < atlasPixels.count {
                            pixels[dstOff + x] = atlasPixels[srcOff + sx]
                        }
                    }
                }
            }
        }

        // Create CGImage from pixel data (BGRA)
        let data = Data(bytes: pixels, count: pixels.count * 4)
        guard let provider = CGDataProvider(data: data as CFData),
              let cgImage = CGImage(width: imgW, height: imgH,
                                     bitsPerComponent: 8, bitsPerPixel: 32,
                                     bytesPerRow: imgW * 4,
                                     space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                                     provider: provider, decode: nil,
                                     shouldInterpolate: false,
                                     intent: .defaultIntent) else { return }
        nsView.image = NSImage(cgImage: cgImage, size: NSSize(width: imgW, height: imgH))
    }
}
