import SwiftUI
import AppKit
import IOSurface

/// TRACE's display layer (TERMinator Render And Compute Engine): shows a running module's frames over the terminal
/// area. Its own layer in TerminalView, separate from the Metal terminal canvas and from every TAP+ overlay, which
/// carry on untouched underneath. See BBSGames/Doom/ENGINE.md.
///
/// Port of the Windows client's `Controls/EngineHostLayer.cs`: frames are drawn nearest-neighbour, at 4:3 when the
/// module flags it (Doom's tall pixels) and with square pixels otherwise, centred on black; the device-pixel size
/// it's shown at is reported to the module (TE_IN_RESIZE). The keyboard side of a module that owns the keyboard
/// (Windows' `ThreadPreprocessMessage` hook) lives in `TerminalKeyMonitor` + `TraceSessionManager.handleExclusiveKey`,
/// because on macOS one app-wide monitor sees keys before the responder chain, including key-ups and modifiers.
///
/// The mouse is here (Windows: `Controls/EngineHostLayer.Mouse.cs`), in the mode the module picked
/// (engine_contract.h TE_MOUSE_*): 0 off, the mouse stays the terminal's; 1 pointer, positions in the module's frame
/// pixels and buttons; 2 the same with the pointer hidden over the picture; 3 captured, relative movement with the
/// pointer hidden and held in place for mouselook. Captured mode uses
/// `CGAssociateMouseAndMouseCursorPosition(false)`, so the deltas come from `NSEvent` and the pointer doesn't move,
/// which is the Mac equivalent of Windows' raw input plus ClipCursor. A module drawn over part of the screen becomes
/// hit-testable once it picks a mode, and takes the clicks over its picture while the keyboard stays with the door.
final class EngineHostLayerView: NSView {
    private let host: EngineModuleHost
    private let exclusive: Bool
    private var mouseMode = 0
    private var captured = false
    private var buttonsHeld = 0            // pointer modes: bit0 left, bit1 middle, bit2 right
    private var capturedButtons = Set<Int>()
    private var wheelRemainder = 0.0
    private var lastPos: (x: Int, y: Int, over: Bool, buttons: Int)?
    private var trackingArea: NSTrackingArea?
    private var cursorHidden = false
    private var appObservers: [NSObjectProtocol] = []
    private let imageLayer = CALayer()
    // A direct-present game's frames (EngineModuleHost.directWanted, exclusive layers only): copied once into one of
    // two IOSurfaces, which the layer shows as they are -- no Data copy, no CGImage, no upload to the card. Two, so
    // the one on screen is never the one being written. A CGImage still goes to onFrameDrawn for the first frame and
    // then once a second (the held picture, Close;hold=1, is at most that old).
    private var surfaces: [IOSurface] = []
    private var surfaceNext = 0
    private var surfaceImageAt = 0.0
    private var lastFrame: Int64 = 0
    private var frameWidth = 0
    private var frameHeight = 0
    private var aspect43 = true
    private var sentWidth = 0
    private var sentScale = 0
    private var sentHeight = 0
    private let pendingLock = NSLock()
    private var framePending = false

    /// Every frame drawn, as the picture shown and its 4:3 flag: the session keeps the newest, for a held picture
    /// (Close;hold=1) and to know the module's first frame is up (TraceSessionManager).
    var onFrameDrawn: ((CGImage, Bool) -> Void)?

    // ---- Rainwire file drops: a drag out of the module onto the OS (RainwireWm/RainwireFileDrops.swift) ----
    private var externalDrag = false
    /// The newest mouseDragged (an OS drag has to start from a mouse event).
    private(set) var lastDragEvent: NSEvent?
    /// The left button is held (pointer modes) and the pointer has left the TERMinator window.
    var pointerLeftWindow: ((EngineHostLayerView, NSEvent) -> Void)?

    init(host: EngineModuleHost, exclusive: Bool) {
        self.host = host
        self.exclusive = exclusive
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        imageLayer.magnificationFilter = .nearest
        imageLayer.minificationFilter = .nearest
        imageLayer.contentsGravity = .resize
        imageLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "frame": NSNull()]
        layer?.addSublayer(imageLayer)

        // The reader thread says a frame is in; draw it on the next main-thread turn (Windows: on the next
        // CompositionTarget.Rendering). Several frames arriving before then are drawn once.
        host.onFrame = { [weak self] in
            self?.frameArrived()
        }
        // Switching away lets a captured pointer go, and nothing stays held down in the module
        let center = NotificationCenter.default
        appObservers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil,
                                               queue: .main) { [weak self] _ in self?.mouseLost() })
        appObservers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: nil,
                                               queue: .main) { [weak self] _ in self?.mouseLost() })
        // ...and take it straight back when we come forward again, as Windows' MouseRegained does: without this a
        // mouselook game was left with no capture and a visible pointer until the player clicked.
        appObservers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                               queue: .main) { [weak self] _ in self?.mouseRegained() })
        appObservers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil,
                                               queue: .main) { [weak self] _ in self?.mouseRegained() })
    }

    deinit {
        // Never leave the pointer disconnected or hidden because a module went away
        if captured {
            CGAssociateMouseAndMouseCursorPosition(1)
        }
        if cursorHidden {
            NSCursor.unhide()
        }
        for observer in appObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Mouse: an exclusive game's layer takes the clicks (nothing reaches the terminal behind it); a drawing module
    /// leaves the mouse with the terminal until its module picks a mouse mode, and then takes the clicks over its
    /// own picture.
    override func hitTest(_ point: NSPoint) -> NSView? {
        (exclusive || mouseMode != 0) ? super.hitTest(point) : nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            lastFrame = 0          // a re-created view (Show after Hide) draws the newest frame at once
            drawNewestFrame()
            reportSize()
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layoutImage()   // the fit is in device pixels
        reportSize()
    }

    override func layout() {
        super.layout()
        layoutImage()
        reportSize()
    }

    private func frameArrived() {
        pendingLock.lock()
        if framePending {
            pendingLock.unlock()
            return
        }
        framePending = true
        pendingLock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.pendingLock.lock()
            self.framePending = false
            self.pendingLock.unlock()
            self.drawNewestFrame()
        }
    }

    /// Copies a frame (BGRA, width * 4 bytes a row) into the next IOSurface and returns it, or nil (then the CGImage
    /// path draws it).
    private func surfaceFrame(_ pixels: UnsafeRawPointer, _ width: Int, _ height: Int) -> IOSurface? {
        if surfaces.count != 2 || surfaces[0].width != width || surfaces[0].height != height {
            surfaces = []
            let props: [IOSurfacePropertyKey: Any] = [
                .width: width, .height: height, .bytesPerElement: 4,
                .pixelFormat: UInt32(0x4247_5241),   // 'BGRA' (kCVPixelFormatType_32BGRA)
            ]
            for _ in 0..<2 {
                guard let s = IOSurface(properties: props) else {
                    surfaces = []
                    return nil
                }
                surfaces.append(s)
            }
        }
        let surface = surfaces[surfaceNext]
        surfaceNext ^= 1
        _ = surface.lock(options: [], seed: nil)
        let dst = surface.baseAddress
        let dstRow = surface.bytesPerRow
        let srcRow = width * 4
        for y in 0..<height {
            memcpy(dst + y * dstRow, pixels + y * srcRow, srcRow)
        }
        _ = surface.unlock(options: [], seed: nil)
        return surface
    }

    private func drawNewestFrame() {
        if exclusive && host.directWanted {
            var shown: IOSurface?
            var still: CGImage?
            var w = 0, h = 0, a43 = false
            let now = ProcessInfo.processInfo.systemUptime
            host.tryConsumeFrame(lastSerial: &lastFrame) { pixels, width, height, aspect in
                w = width
                h = height
                a43 = aspect
                shown = surfaceFrame(pixels, width, height)
                if shown == nil || frameWidth == 0 || now - surfaceImageAt >= 1.0 {
                    surfaceImageAt = now
                    let bytes = Data(bytes: pixels, count: width * height * 4)
                    if let provider = CGDataProvider(data: bytes as CFData) {
                        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                                                | CGBitmapInfo.byteOrder32Little.rawValue)
                        still = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info,
                                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
                    }
                }
            }
            guard shown != nil || still != nil else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if let surface = shown {
                imageLayer.contents = surface
            } else {
                imageLayer.contents = still
            }
            CATransaction.commit()
            if w != frameWidth || h != frameHeight || a43 != aspect43 {
                frameWidth = w
                frameHeight = h
                aspect43 = a43
                layoutImage()
            }
            if let still = still {
                onFrameDrawn?(still, a43)
            }
            return
        }
        var image: CGImage?
        var w = 0, h = 0, a43 = false
        host.tryConsumeFrame(lastSerial: &lastFrame) { pixels, width, height, aspect in
            w = width
            h = height
            a43 = aspect
            // BGRA little-endian, alpha ignored (Windows: PixelFormats.Bgr32)
            let bytes = Data(bytes: pixels, count: width * height * 4)
            guard let provider = CGDataProvider(data: bytes as CFData) else { return }
            let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                                    | CGBitmapInfo.byteOrder32Little.rawValue)
            image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info,
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        }
        guard let frame = image else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = frame
        CATransaction.commit()
        if w != frameWidth || h != frameHeight || a43 != aspect43 {
            frameWidth = w
            frameHeight = h
            aspect43 = a43
            layoutImage()
        }
        onFrameDrawn?(frame, a43)
    }

    // MARK: - The mouse (Windows: Controls/EngineHostLayer.Mouse.cs)

    /// The mouse mode the module picked, from the session (TraceSessionManager keeps it).
    func applyMouseMode(_ mode: Int) {
        setMouseMode(mode)
    }

    private func setMouseMode(_ mode: Int) {
        guard mode != mouseMode else { return }
        releaseCapture()
        releasePointerButtons()
        mouseMode = mode
        lastPos = nil
        updateTrackingArea()
        window?.invalidateCursorRects(for: self)
        // Modes 2 and 3: the module draws its own pointer, or there shouldn't be one at all. Over the layer only, by
        // a blank cursor rect (Windows: Cursor = Cursors.None), so the menu bar and other windows keep the pointer;
        // NSCursor.hide() is app-wide and is left to captured mode (captureRelative).
        if mode == 3 && exclusive && isPointerInside {
            captureRelative()
        }
    }

    private func setCursorHidden(_ hidden: Bool) {
        guard hidden != cursorHidden else { return }
        cursorHidden = hidden
        if hidden {
            NSCursor.hide()
        } else {
            NSCursor.unhide()
        }
    }

    private var isPointerInside: Bool {
        guard let window = window else { return false }
        let inView = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return bounds.contains(inView)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        updateTrackingArea()
    }

    /// A click that brings the window forward still reaches the module (Windows raises MouseDown on an inactive
    /// window): without this the first click on the picture after using another window was swallowed.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { mouseMode != 0 }

    /// Pointer mode: the ordinary arrow over the picture (Windows: Cursor = null), not whatever the terminal set last
    override func resetCursorRects() {
        if mouseMode == 1 {
            addCursorRect(bounds, cursor: .arrow)
        } else if mouseMode == 2 || mouseMode == 3 {
            addCursorRect(bounds, cursor: Self.blankCursor)
        }
    }

    /// A fully transparent pointer, for the modes where the module draws its own (or there is none)
    private static let blankCursor: NSCursor = {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in true }   // draws nothing
        return NSCursor(image: image, hotSpot: .zero)
    }()

    private func updateTrackingArea() {
        if let area = trackingArea {
            removeTrackingArea(area)
            trackingArea = nil
        }
        guard mouseMode != 0 else { return }
        // .activeInKeyWindow: a module only tracks the mouse while its window is the key one, which is also when
        // it is allowed to act on it (mouseLost clears everything when focus goes)
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    /// Where a point in the view falls in the module's frame; nil before the first frame.
    private func toFrame(_ event: NSEvent) -> (x: Int, y: Int, over: Bool)? {
        guard frameWidth > 0, frameHeight > 0, imageLayer.frame.width > 0, imageLayer.frame.height > 0 else {
            return nil
        }
        let inView = convert(event.locationInWindow, from: nil)
        let picture = imageLayer.frame
        // The frame's y runs down; an NSView's runs up
        let fx = (inView.x - picture.minX) * CGFloat(frameWidth) / picture.width
        let fy = (picture.maxY - inView.y) * CGFloat(frameHeight) / picture.height
        let over = fx >= 0 && fy >= 0 && fx < CGFloat(frameWidth) && fy < CGFloat(frameHeight)
        return (min(max(Int(fx.rounded(.down)), 0), frameWidth - 1),
                min(max(Int(fy.rounded(.down)), 0), frameHeight - 1), over)
    }

    private func sendPos(_ x: Int, _ y: Int, _ over: Bool) {
        let pos = (x: x, y: y, over: over, buttons: buttonsHeld)
        if let last = lastPos, last == pos {
            return
        }
        lastPos = pos
        host.sendMousePos(x: x, y: y, over: over, buttons: buttonsHeld)
    }

    private static func heldBit(_ button: Int) -> Int {
        switch button {
        case 1: return 1
        case 2: return 2
        case 3: return 4
        default: return 0
        }
    }

    override func mouseMoved(with event: NSEvent) { pointerMoved(event) }
    override func mouseDragged(with event: NSEvent) { pointerMoved(event) }
    override func rightMouseDragged(with event: NSEvent) { pointerMoved(event) }
    override func otherMouseDragged(with event: NSEvent) { pointerMoved(event) }

    private func pointerMoved(_ event: NSEvent) {
        if externalDrag {
            return
        }
        if mouseMode == 3 {
            guard captured else { return }
            let dx = Int(event.deltaX.rounded()), dy = Int(event.deltaY.rounded())
            if dx != 0 || dy != 0 {
                host.sendMouseMove(dx: dx, dy: dy)
            }
            return
        }
        guard mouseMode == 1 || mouseMode == 2, let p = toFrame(event) else { return }
        sendPos(p.x, p.y, p.over)
        if event.type == .leftMouseDragged {
            lastDragEvent = event
        }
        if (buttonsHeld & 1) != 0, let left = pointerLeftWindow, RainwireFileDrops.pointerOutsideWindow(self) {
            left(self, event)
        }
    }

    /// The left button is held in a pointer mode and the pointer is outside the TERMinator window.
    func leftHeldOutsideWindow() -> Bool {
        (mouseMode == 1 || mouseMode == 2) && !externalDrag && (buttonsHeld & 1) != 0
            && NSEvent.pressedMouseButtons & 1 != 0 && RainwireFileDrops.pointerOutsideWindow(self)
    }

    /// An OS drag takes over the held press: the module keeps seeing the button down until it ends.
    func beginExternalDrag() {
        externalDrag = true
    }

    /// The OS drag ended: the module sees the left button let go off its picture.
    func endExternalDrag() {
        externalDrag = false
        if (buttonsHeld & 1) == 0 {
            return
        }
        buttonsHeld &= ~1
        sendPos(lastPos?.x ?? 0, lastPos?.y ?? 0, false)
        host.sendMouseButton(1, pressed: false)
    }

    /// Where an OS file drop (a point in window coordinates) falls in the module's frame pixels; nil off the picture.
    func framePoint(windowPoint: NSPoint) -> (x: Int, y: Int)? {
        guard frameWidth > 0, frameHeight > 0, imageLayer.frame.width > 0, imageLayer.frame.height > 0 else {
            return nil
        }
        let inView = convert(windowPoint, from: nil)
        let picture = imageLayer.frame
        // The frame's y runs down; an NSView's runs up
        let fx = (inView.x - picture.minX) * CGFloat(frameWidth) / picture.width
        let fy = (picture.maxY - inView.y) * CGFloat(frameHeight) / picture.height
        if fx < 0 || fy < 0 || fx >= CGFloat(frameWidth) || fy >= CGFloat(frameHeight) {
            return nil
        }
        return (Int(fx), Int(fy))
    }

    override func mouseExited(with event: NSEvent) {
        if (mouseMode == 1 || mouseMode == 2) && buttonsHeld == 0 {
            sendPos(lastPos?.x ?? 0, lastPos?.y ?? 0, false)
        }
    }

    override func mouseDown(with event: NSEvent) { pointerDown(event, button: 1) }
    override func rightMouseDown(with event: NSEvent) { pointerDown(event, button: 3) }
    override func otherMouseDown(with event: NSEvent) {
        pointerDown(event, button: event.buttonNumber == 2 ? 2 : (event.buttonNumber == 3 ? 6 : 7))
    }

    override func mouseUp(with event: NSEvent) { pointerUp(event, button: 1) }
    override func rightMouseUp(with event: NSEvent) { pointerUp(event, button: 3) }
    override func otherMouseUp(with event: NSEvent) {
        pointerUp(event, button: event.buttonNumber == 2 ? 2 : (event.buttonNumber == 3 ? 6 : 7))
    }

    private func pointerDown(_ event: NSEvent, button: Int) {
        switch mouseMode {
        case 1, 2:
            guard let p = toFrame(event) else { return }
            sendPos(p.x, p.y, p.over)
            buttonsHeld |= Self.heldBit(button)
            host.sendMouseButton(button, pressed: true)
            sendPos(p.x, p.y, p.over)   // the held buttons changed
        case 3:
            if !captured {
                captureRelative()   // this click only takes the mouse; the module doesn't see it
            } else if capturedButtons.insert(button).inserted {
                host.sendMouseButton(button, pressed: true)
            }
        default:
            break
        }
    }

    private func pointerUp(_ event: NSEvent, button: Int) {
        if mouseMode == 3 {
            if capturedButtons.remove(button) != nil {
                host.sendMouseButton(button, pressed: false)
            }
            return
        }
        guard mouseMode == 1 || mouseMode == 2 else { return }
        let bit = Self.heldBit(button)
        if bit != 0 && (buttonsHeld & bit) == 0 {
            return   // pressed before the mode was picked (or an OS drag already let it go)
        }
        buttonsHeld &= ~bit
        if let p = toFrame(event) {
            sendPos(p.x, p.y, p.over)
        }
        host.sendMouseButton(button, pressed: false)
    }

    override func scrollWheel(with event: NSEvent) {
        guard mouseMode != 0 else { return }
        if mouseMode == 1 || mouseMode == 2, let p = toFrame(event) {
            sendPos(p.x, p.y, p.over)
        }
        // A wheel notch is 1 line; trackpads send fractions, which add up to a notch the same way.
        // `isDirectionInvertedFromDevice` is macOS' natural scrolling, which has already flipped the delta: undo it,
        // so button 4 is always the wheel pushed away from the player as it is on Windows (WM_MOUSEWHEEL is the raw
        // direction and has no such setting). A game's "wheel up = next weapon" must follow the wheel, not a
        // document-scrolling preference.
        let lines = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 10.0 : event.scrollingDeltaY
        sendWheel(event.isDirectionInvertedFromDevice ? -lines : lines)
    }

    /// Wheel movement in notches: a press then a release each.
    private func sendWheel(_ notches: Double) {
        wheelRemainder += notches
        while abs(wheelRemainder) >= 1.0 {
            let button = wheelRemainder > 0 ? 4 : 5
            host.sendMouseButton(button, pressed: true)
            host.sendMouseButton(button, pressed: false)
            wheelRemainder -= wheelRemainder > 0 ? 1 : -1
        }
    }

    private func releasePointerButtons() {
        for button in [1, 2, 3] where (buttonsHeld & Self.heldBit(button)) != 0 {
            host.sendMouseButton(button, pressed: false)
        }
        buttonsHeld = 0
        wheelRemainder = 0
    }

    /// Captured mode: the pointer stops moving and its movement comes to us as deltas (mouselook). This is the Mac
    /// equivalent of Windows' raw input + ClipCursor -- there is nothing to clip, since the pointer stays put.
    private func captureRelative() {
        guard !captured, mouseMode == 3, window?.isKeyWindow == true, !isHiddenOrHasHiddenAncestor else { return }
        captured = true
        CGAssociateMouseAndMouseCursorPosition(0)
        setCursorHidden(true)
    }

    private func releaseCapture() {
        guard captured else { return }
        captured = false
        CGAssociateMouseAndMouseCursorPosition(1)
        setCursorHidden(false)   // the blank cursor rect still covers modes 2 and 3 over the layer
        for button in capturedButtons {
            host.sendMouseButton(button, pressed: false)   // nothing stays held down in the game
        }
        capturedButtons.removeAll()
    }

    /// The window became active again: an exclusive game in captured mode takes the mouse straight back.
    private func mouseRegained() {
        if mouseMode == 3 && exclusive && isPointerInside {
            captureRelative()
        }
    }

    /// The window lost focus or the layer went away: give the mouse back and let go of held buttons.
    private func mouseLost() {
        releaseCapture()
        releasePointerButtons()
    }

    /// Tells the module the device-pixel size it's shown at, so it can render 1:1 (the fractal module does).
    private func reportSize() {
        guard let window = window, bounds.width > 0, bounds.height > 0 else { return }
        let scale = window.backingScaleFactor
        let w = Int((bounds.width * scale).rounded())
        let h = Int((bounds.height * scale).rounded())
        let percent = Int((scale * 100).rounded())   // backingScaleFactor: 200 on a Retina screen
        if w == sentWidth && h == sentHeight && percent == sentScale {
            return
        }
        sentWidth = w
        sentHeight = h
        sentScale = percent
        host.sendResize(width: w, height: h, scalePercent: percent)
    }

    /// Fits the picture in the layer: 4:3 when the module asks for it (Doom's tall pixels), else square pixels.
    /// Worked in whole device pixels (§12.70): nearest-neighbour scaling drops a row or column whenever the picture is
    /// even one pixel smaller than the frame, and the old point-based fit often came out a pixel short. A UI module
    /// renders exactly the size reportSize sends, so that is now shown 1:1.
    private func layoutImage() {
        guard frameWidth > 0, frameHeight > 0, bounds.width > 0, bounds.height > 0 else { return }
        let scale = window?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = traceFitRect(bounds: bounds, scale: scale, frameWidth: frameWidth,
                                        frameHeight: frameHeight, aspect43: aspect43)
        CATransaction.commit()
    }
}

/// Where a module's picture goes in a view of `bounds`: the most of it that keeps the picture's shape, worked in whole
/// device pixels with integer maths (so a frame of exactly the view's device size is shown 1:1, with nothing dropped
/// by the nearest-neighbour filter), centred on a whole device pixel. Windows: EngineHostLayer.FitDevice.
func traceFitRect(bounds: CGRect, scale: CGFloat, frameWidth: Int, frameHeight: Int, aspect43: Bool) -> CGRect {
    let availW = Int((bounds.width * scale).rounded()), availH = Int((bounds.height * scale).rounded())
    let num = aspect43 ? 4 : frameWidth, den = aspect43 ? 3 : frameHeight
    guard availW > 0, availH > 0, num > 0, den > 0 else { return .zero }
    var w = availW, h = availH
    if availW * den <= availH * num {
        h = availW * den / num   // width-limited
    } else {
        w = availH * num / den
    }
    let x = ((bounds.width * scale - CGFloat(w)) / 2).rounded(.down) / scale
    let y = ((bounds.height * scale - CGFloat(h)) / 2).rounded(.down) / scale
    return CGRect(x: x, y: y, width: CGFloat(w) / scale, height: CGFloat(h) / scale)
}

/// SwiftUI wrapper for one module's layer.
struct EngineHostLayerRepresentable: NSViewRepresentable {
    let session: TraceSessionManager.Session
    /// The mode the module picked, carried as a VALUE and not read off `session` inside `updateNSView`.
    /// SwiftUI skips a representable's update when all of its stored properties compare equal, and a class
    /// reference always does: with `session` the only property, `TraceSessionManager`'s `objectWillChange` re-ran
    /// this view's parent but never called `updateNSView`, so `applyMouseMode` only ever ran from `makeNSView`,
    /// while the mode was still 0 -- which installs no `NSTrackingArea` and makes every handler bail. That was the
    /// whole of "the mouse does nothing" (keys were unaffected: they come through TerminalKeyMonitor, not here).
    let mouseMode: Int

    func makeNSView(context: Context) -> EngineHostLayerView {
        let view = EngineHostLayerView(host: session.host, exclusive: session.module.exclusive)
        view.applyMouseMode(mouseMode)
        // The newest frame stays with the session (a held picture, Close;hold=1), and its first one is news
        let owner = session
        view.onFrameDrawn = { [weak owner] image, aspect43 in
            owner?.frameDrawn(image, aspect43)
        }
        owner.layerView = view
        TraceSessionManager.shared.layerViewCreated(owner, view)
        return view
    }

    func updateNSView(_ nsView: EngineHostLayerView, context: Context) {
        nsView.applyMouseMode(mouseMode)
    }
}

/// The engine layer over the terminal area (Windows MainWindow's `EngineHost` grid): every running module, a drawing
/// module over its terminal cells (placed with the same cell geometry the Metal renderer and TAP+ overlays use), an
/// exclusive one over the whole terminal area. Empty unless a module is running.
struct TraceEngineLayer: View {
    @ObservedObject var manager: TraceSessionManager
    /// Terminal cell size and the BBS screen's top-left, in this view's points.
    let cellWidth: CGFloat
    let cellHeight: CGFloat
    let originX: CGFloat
    let originY: CGFloat
    let columns: Int
    let rows: Int
    let size: CGSize
    /// The terminal is showing history. A drawing module's picture sits over live-screen cells, which then show
    /// history, so it would stay put while the text scrolls under it: hidden until back on the live screen.
    /// Exclusive (full-window game) modules are untouched.
    var scrolledBack: Bool = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Held pictures (Close;hold=1): a module Rainwire closed to run a transfer, its last frame dimmed, under
            // the module's new layer once it reopens (Windows inserts it where the layer was)
            ForEach(manager.heldFrames) { held in
                if !(scrolledBack && !held.exclusive) {
                    placedHeld(held)
                }
            }
            ForEach(manager.sessions) { session in
                if !session.hidden && !(scrolledBack && !session.module.exclusive) {
                    placed(session)
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    @ViewBuilder
    private func placed(_ session: TraceSessionManager.Session) -> some View {
        if session.module.exclusive {
            // Games fill the whole terminal area
            EngineHostLayerRepresentable(session: session, mouseMode: session.mouseMode)
                .frame(width: size.width, height: size.height)
                .position(x: size.width / 2, y: size.height / 2)
        } else {
            let rect = cellsRect(session)
            EngineHostLayerRepresentable(session: session, mouseMode: session.mouseMode)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                // Mode 0 (the default): clicks go straight through to the terminal, as before
                .allowsHitTesting(session.mouseMode != 0)
        }
    }

    @ViewBuilder
    private func placedHeld(_ held: TraceSessionManager.HeldFrame) -> some View {
        if held.exclusive {
            HeldFrameRepresentable(held: held)
                .frame(width: size.width, height: size.height)
                .position(x: size.width / 2, y: size.height / 2)
        } else {
            let rect = cellsRect(row1: held.row1, col1: held.col1, row2: held.row2, col2: held.col2)
            HeldFrameRepresentable(held: held)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
        }
    }

    /// The session's cells (1-based, inclusive, clipped to the screen), rounded to whole points like Windows.
    private func cellsRect(_ s: TraceSessionManager.Session) -> CGRect {
        cellsRect(row1: s.row1, col1: s.col1, row2: s.row2, col2: s.col2)
    }

    private func cellsRect(row1: Int, col1: Int, row2 r2: Int, col2 c2: Int) -> CGRect {
        let cols = max(columns, 1)
        let rowCount = max(rows, 1)
        let row2 = min(r2, rowCount)
        let col2 = min(c2, cols)
        let x = originX + CGFloat(col1 - 1) * cellWidth
        let y = originY + CGFloat(row1 - 1) * cellHeight
        let w = CGFloat(max(0, col2 - col1 + 1)) * cellWidth
        let h = CGFloat(max(0, row2 - row1 + 1)) * cellHeight
        return CGRect(x: x.rounded(), y: y.rounded(), width: w.rounded(), height: h.rounded())
    }
}

/// A held picture (Close;hold=1): the module's last frame as a still, dimmed to about 60% on black, fitted as the
/// module's own layer fits it (4:3 or square pixels, centred). It takes the clicks over its area so nothing reaches
/// the terminal text underneath, and gives the module nothing (it isn't running). Windows: EngineHostLayer.HeldSnapshot.
final class HeldFrameView: NSView {
    private let imageLayer = CALayer()
    private let frameWidth: Int
    private let frameHeight: Int
    private let aspect43: Bool

    init(image: CGImage, aspect43: Bool) {
        frameWidth = image.width
        frameHeight = image.height
        self.aspect43 = aspect43
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        imageLayer.contents = image
        imageLayer.opacity = 0.6   // on black: about 60% brightness
        imageLayer.magnificationFilter = .nearest
        imageLayer.minificationFilter = .nearest
        imageLayer.contentsGravity = .resize
        imageLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "frame": NSNull()]
        layer?.addSublayer(imageLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func layout() {
        super.layout()
        guard frameWidth > 0, frameHeight > 0, bounds.width > 0, bounds.height > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = traceFitRect(bounds: bounds, scale: window?.backingScaleFactor ?? 2, frameWidth: frameWidth,
                                        frameHeight: frameHeight, aspect43: aspect43)
        CATransaction.commit()
    }

    // Clicks stop here, not on the terminal text underneath
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func rightMouseUp(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
    override func otherMouseUp(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
    override func menu(for event: NSEvent) -> NSMenu? { nil }
}

/// SwiftUI wrapper for one held picture.
struct HeldFrameRepresentable: NSViewRepresentable {
    let held: TraceSessionManager.HeldFrame

    func makeNSView(context: Context) -> HeldFrameView {
        HeldFrameView(image: held.image, aspect43: held.aspect43)
    }

    func updateNSView(_ nsView: HeldFrameView, context: Context) {}
}
