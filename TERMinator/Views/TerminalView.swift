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
    var onCopy: (() -> Void)?
    var onZoomIn: (() -> Void)?
    var onZoomOut: (() -> Void)?
    var onZoomReset: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    // Intercept key equivalents so ESC, Tab, arrows, and other special keys
    // aren't swallowed by the responder chain (sheets, menus, focus navigation).
    // This mirrors iOS's wantsPriorityOverSystemBehavior = true approach.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Let Cmd shortcuts go through to the menu system
        if event.modifierFlags.contains(.command) {
            return super.performKeyEquivalent(with: event)
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
        let keyCode = event.keyCode
        let flags = event.modifierFlags

        // Cmd+V paste
        if flags.contains(.command) && event.charactersIgnoringModifiers == "v" {
            if let clipboard = NSPasteboard.general.string(forType: .string) {
                for char in clipboard {
                    if char == "\n" || char == "\r\n" {
                        onCharacter?(Character("\r"))
                    } else {
                        onCharacter?(char)
                    }
                }
            }
            return
        }

        // Cmd+C copy selected text
        if flags.contains(.command) && event.charactersIgnoringModifiers == "c" {
            onCopy?()
            return
        }

        // Cmd+= or Cmd++ zoom in
        if flags.contains(.command) && (event.charactersIgnoringModifiers == "=" || event.charactersIgnoringModifiers == "+") {
            onZoomIn?()
            return
        }

        // Cmd+- zoom out
        if flags.contains(.command) && event.charactersIgnoringModifiers == "-" {
            onZoomOut?()
            return
        }

        // Cmd+0 reset zoom
        if flags.contains(.command) && event.charactersIgnoringModifiers == "0" {
            onZoomReset?()
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
        case 117: // Forward Delete
            onString?("\u{1B}[3~")
        case 115: // Home
            onString?("\u{1B}[H")
        case 119: // End
            onString?("\u{1B}[F")
        case 116: // Page Up
            onString?("\u{1B}[5~")
        case 121: // Page Down
            onString?("\u{1B}[6~")
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
        // Not used directly for terminal input
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
    var onCopy: () -> Void
    var onZoomIn: () -> Void
    var onZoomOut: () -> Void
    var onZoomReset: () -> Void

    func makeNSView(context: Context) -> TerminalKeyboardView {
        let view = TerminalKeyboardView()
        view.onCharacter = onCharacter
        view.onString = onString
        view.onCopy = onCopy
        view.onZoomIn = onZoomIn
        view.onZoomOut = onZoomOut
        view.onZoomReset = onZoomReset
        return view
    }

    func updateNSView(_ nsView: TerminalKeyboardView, context: Context) {
        nsView.onCharacter = onCharacter
        nsView.onString = onString
        nsView.onCopy = onCopy
        nsView.onZoomIn = onZoomIn
        nsView.onZoomOut = onZoomOut
        nsView.onZoomReset = onZoomReset
    }
}

// MARK: - Terminal Mouse Tracking View

/// NSView subclass that tracks mouse events for text selection, URL clicking, and context menu.
final class TerminalMouseTrackingView: NSView {
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
        mouseDownPoint = location
        isDragging = false
        onMouseDown?(location)
    }

    override func mouseDragged(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
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
        onMouseUp?(location, isDragging)
        isDragging = false
    }

    override func mouseMoved(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        onMouseMoved?(location)
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

    func makeNSView(context: Context) -> TerminalMouseTrackingView {
        let view = TerminalMouseTrackingView()
        view.onMouseDown = onMouseDown
        view.onMouseDragged = onMouseDragged
        view.onMouseUp = onMouseUp
        view.onMouseMoved = onMouseMoved
        view.contextMenuProvider = contextMenuProvider
        return view
    }

    func updateNSView(_ nsView: TerminalMouseTrackingView, context: Context) {
        nsView.onMouseDown = onMouseDown
        nsView.onMouseDragged = onMouseDragged
        nsView.onMouseUp = onMouseUp
        nsView.onMouseMoved = onMouseMoved
        nsView.contextMenuProvider = contextMenuProvider
    }
}

/// Terminal view that renders the screen buffer using Metal for pixel-perfect display.
/// Desktop-optimized: keyboard input via NSView, scroll wheel for scrollback, right-click paste.
struct TerminalView: View {
    let entry: BBSEntry
    @StateObject private var viewModel = TerminalViewModel()
    @EnvironmentObject var appState: AppState

    // Scroll state
    @State private var scrollAccumulator: CGFloat = 0
    private let scrollThreshold: CGFloat = 20

    // Mouse hover state for URL detection
    @State private var hoveredURL: String?
    @State private var hoveredCol: Int = -1
    @State private var hoveredRow: Int = -1

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                // Background
                Color.black.ignoresSafeArea()

                // Keyboard input handler (invisible, receives key events)
                TerminalKeyboardViewRepresentable(
                    onCharacter: { char in
                        viewModel.sendCharacter(char)
                    },
                    onString: { string in
                        viewModel.sendString(string)
                    },
                    onCopy: {
                        copySelectedText()
                    },
                    onZoomIn: {
                        viewModel.setZoom(viewModel.zoomLevel + 0.1)
                    },
                    onZoomOut: {
                        viewModel.setZoom(viewModel.zoomLevel - 0.1)
                    },
                    onZoomReset: {
                        viewModel.resetZoom()
                    }
                )
                .frame(width: 1, height: 1)
                .opacity(0)

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

                // Mouse tracking overlay (transparent, captures mouse events)
                TerminalMouseTrackingRepresentable(
                    onMouseDown: { point in
                        let cell = cellSizeInPoints(in: geometry)
                        let col = Int(point.x / cell.w)
                        // NSView coordinates are flipped (origin at bottom-left)
                        let row = Int((geometry.size.height - point.y) / cell.h)
                        viewModel.startSelection(col: col, row: row)
                    },
                    onMouseDragged: { point in
                        let cell = cellSizeInPoints(in: geometry)
                        let col = Int(point.x / cell.w)
                        let row = Int((geometry.size.height - point.y) / cell.h)
                        viewModel.updateSelection(col: col, row: row)
                    },
                    onMouseUp: { point, wasDrag in
                        let cell = cellSizeInPoints(in: geometry)
                        let col = Int(point.x / cell.w)
                        let row = Int((geometry.size.height - point.y) / cell.h)

                        if !wasDrag {
                            // Single click: check for URL, otherwise cancel selection
                            if let url = viewModel.urlAt(column: col, row: row) {
                                viewModel.openURL(url)
                            } else {
                                viewModel.cancelSelection()
                            }
                        }
                        // If it was a drag, the selection stays active
                    },
                    onMouseMoved: { point in
                        let cell = cellSizeInPoints(in: geometry)
                        let col = Int(point.x / cell.w)
                        let row = Int((geometry.size.height - point.y) / cell.h)
                        let url = viewModel.urlAt(column: col, row: row)
                        hoveredURL = url
                        hoveredCol = col
                        hoveredRow = row

                        // Change cursor to pointing hand when hovering a URL
                        if url != nil {
                            NSCursor.pointingHand.set()
                        } else {
                            NSCursor.iBeam.set()
                        }
                    },
                    contextMenuProvider: { buildContextMenu() }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // TAP+ overlays (toggled by View > Show TAP+ menu)
                if appState.showTapPlus {
                    // TAP+ video overlay
                    if viewModel.videoActive, let player = viewModel.videoPlayer {
                        videoOverlay(player: player, in: geometry)
                    }

                    // TAP+ image overlay
                    if viewModel.imageActive, let image = viewModel.imageData {
                        imageOverlay(image: image, in: geometry)
                    }

                    // TAP+ logo overlay
                    if viewModel.logoActive, let logoImage = viewModel.logoImageData {
                        logoOverlay(image: logoImage, in: geometry)
                    }

                    // TAP+ visualizer overlay
                    if viewModel.visualizerActive {
                        visualizerOverlay(in: geometry)
                    }
                }

                // Logging indicator
                if viewModel.isLogging {
                    loggingIndicator
                }

                // Transfer progress overlay
                if viewModel.showTransferView, let transferInfo = viewModel.transferInfo {
                    TransferProgressView(info: transferInfo) {
                        viewModel.cancelTransfer()
                    } onDismiss: {
                        viewModel.showTransferView = false
                    }
                }

                // Scrollback indicator
                if viewModel.isInScrollback {
                    scrollbackIndicator
                }

                // Disconnect overlay
                if case .error(let message) = viewModel.connectionState {
                    disconnectOverlay(message: message)
                }

                // Status bar
                statusBar
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .onAppear {
                viewModel.containerSize = geometry.size
                viewModel.loadFontBitmap()
                viewModel.connect(to: entry)
                appState.isConnected = true
                appState.connectedEntry = entry
            }
            .onChange(of: geometry.size) { newSize in
                viewModel.containerSize = newSize
            }
            .onChange(of: viewModel.showUploadPicker) { show in
                if show {
                    presentUploadPanel()
                }
            }
            .onDisappear {
                viewModel.disconnect()
                appState.isConnected = false
                appState.connectedEntry = nil
            }
            .onReceive(NotificationCenter.default.publisher(for: .sendFileRequested)) { _ in
                viewModel.showUploadPicker = true
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
            .onReceive(NotificationCenter.default.publisher(for: .saveSnapshot)) { _ in
                if let data = viewModel.captureSnapshotData() {
                    viewModel.saveSnapshot(data)
                }
            }
        }
    }

    // MARK: - Copy Selected Text

    private func copySelectedText() {
        if let text = viewModel.getSelectedText(), !text.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            viewModel.cancelSelection()
        }
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
            if let clipboard = NSPasteboard.general.string(forType: .string) {
                for char in clipboard {
                    if char == "\n" || char == "\r\n" {
                        viewModel.sendCharacter(Character("\r"))
                    } else {
                        viewModel.sendCharacter(char)
                    }
                }
            }
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

        // Save Thumbnail
        addAction("Save Thumbnail", to: menu) { [self] in
            if let data = viewModel.captureSnapshotData() {
                viewModel.saveSnapshot(data)
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
        panel.allowsMultipleSelection = false

        panel.begin { response in
            DispatchQueue.main.async {
                viewModel.showUploadPicker = false
                if response == .OK, let url = panel.url {
                    viewModel.queueUpload(fileURL: url)
                }
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

        // Also update the phonebook thumbnail
        viewModel.saveSnapshot(pngData)
    }

    // MARK: - Selection Overlay

    private func selectionOverlay(in geometry: GeometryProxy) -> some View {
        let cell = cellSizeInPoints(in: geometry)
        let minCol = viewModel.selectionMinCol
        let maxCol = viewModel.selectionMaxCol
        let minRow = viewModel.selectionMinRow
        let maxRow = viewModel.selectionMaxRow

        let x = CGFloat(minCol) * cell.w
        let y = CGFloat(minRow) * cell.h
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

        return ForEach(Array(viewModel.detectedURLs.enumerated()), id: \.offset) { _, detected in
            let x = CGFloat(detected.startColumn) * cell.w
            let y = CGFloat(detected.row) * cell.h + cell.h - 1
            let w = CGFloat(detected.endColumn - detected.startColumn) * cell.w

            Rectangle()
                .fill(Color.cyan.opacity(0.6))
                .frame(width: w, height: 1)
                .position(x: x + w / 2, y: y)
                .allowsHitTesting(false)
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
        let terminalNativeWidth = CGFloat(viewModel.screenColumns) * fontW
        let terminalNativeHeight = CGFloat(viewModel.screenRows) * fontH
        let scaleX = geometry.size.width / terminalNativeWidth
        let scaleY = geometry.size.height / terminalNativeHeight
        let scale = min(scaleX, scaleY)
        return (fontW * scale, fontH * scale)
    }

    // MARK: - TAP+ Overlays

    private func videoOverlay(player: AVPlayer, in geometry: GeometryProxy) -> some View {
        let cell = cellSizeInPoints(in: geometry)
        let x = CGFloat(viewModel.videoCol - 1) * cell.w
        let y = CGFloat(viewModel.videoRow - 1) * cell.h
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

    private func imageOverlay(image: NSImage, in geometry: GeometryProxy) -> some View {
        let cell = cellSizeInPoints(in: geometry)
        let x = CGFloat(viewModel.imageCol - 1) * cell.w
        let y = CGFloat(viewModel.imageRow - 1) * cell.h
        let w = CGFloat(viewModel.imageCellW) * cell.w
        let h = CGFloat(viewModel.imageCellH) * cell.h

        // Aspect-fit within the bounding box, matching iOS behavior.
        let bw = image.size.width
        let bh = image.size.height
        let imgScale = min(w / max(bw, 1), h / max(bh, 1))
        let fitW = bw * imgScale
        let fitH = bh * imgScale

        return Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: fitW, height: fitH)
            .position(x: x + w / 2, y: y + h / 2)
            .allowsHitTesting(false)
    }

    private func logoOverlay(image: NSImage, in geometry: GeometryProxy) -> some View {
        let cell = cellSizeInPoints(in: geometry)
        let maxCols = CGFloat(viewModel.screenColumns)
        let maxRows = CGFloat(viewModel.screenRows)
        let clampedW = min(CGFloat(viewModel.logoCellW), maxCols)
        let clampedH = min(CGFloat(viewModel.logoCellH), maxRows)
        let x = CGFloat(viewModel.logoCol - 1) * cell.w
        let y = CGFloat(viewModel.logoRow - 1) * cell.h
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
        return VisualizerOverlayView(
            audioAnalyzer: SoundtrackManager.shared.audioAnalyzer,
            row: viewModel.visualizerRow,
            col: viewModel.visualizerCol,
            cellsWide: viewModel.visualizerCellW,
            cellsHigh: viewModel.visualizerCellH,
            style: viewModel.visualizerStyle,
            cellWidth: cell.w,
            cellHeight: cell.h,
            panOffsetX: 0,
            panOffsetY: 0
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Disconnect Overlay

    private func disconnectOverlay(message: String) -> some View {
        ZStack {
            Color.black.opacity(0.6)

            VStack(spacing: 16) {
                Text("DISCONNECTED")
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundColor(.termLightRed)

                Text(message)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(.termLightGreen)
                    .multilineTextAlignment(.center)

                RetroButton("OK", style: .amber) {
                    viewModel.disconnect()
                    appState.isConnected = false
                    appState.connectedEntry = nil
                    appState.currentView = .home
                }
                .frame(width: 120)
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

    private var scrollbackIndicator: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Text("SCROLL: -\(viewModel.scrollbackOffset)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.termLightCyan)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.7))
                    .cornerRadius(4)
                Spacer()
            }
            .padding(.bottom, 8)
        }
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
        .background(Color.black.opacity(0.85))
    }

    private func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes)B" }
        if bytes < 1024 * 1024 { return String(format: "%.1fK", Double(bytes) / 1024) }
        return String(format: "%.1fM", Double(bytes) / (1024 * 1024))
    }
}

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
        onScroll?(event.scrollingDeltaY)
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
