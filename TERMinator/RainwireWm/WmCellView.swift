import AppKit

/// Drawing cells with a bitmap font, shared by window contents and everything around them.
/// Port of the Windows client's `WmPaint` (RainwireWm/WmCellView.cs).
enum WmPaint {
    /// The Font smoothing setting (Preferences, "font_smoothing", which the main screen's Metal sampler reads too):
    /// smoothed scaling when on, crisp pixels when off. Read at every draw, so a change applies on the next redraw.
    static var smooth: Bool { UserDefaults.standard.bool(forKey: "font_smoothing") }

    /// One glyph into an ARGB pixel buffer pw pixels wide, at cell (cx, cy). A clear background stays clear.
    static func glyph(_ px: inout [UInt32], _ pw: Int, _ cx: Int, _ cy: Int, _ ch: UInt8, _ fg: UInt32, _ bg: UInt32,
                      _ font: WmFont?, _ fh: Int, underline: Bool = false) {
        let baseAt = cy * fh * pw + cx * 8
        let glyph = Int(ch) * fh
        for row in 0..<fh {
            var bits: UInt8 = 0
            if let font = font, glyph + row < font.data.count {
                bits = font.data[glyph + row]
            }
            if underline && row == fh - 1 {
                bits = 0xFF
            }
            let at = baseAt + row * pw
            for col in 0..<8 {
                px[at + col] = (bits & (UInt8(0x80) >> UInt8(col))) != 0 ? fg : bg
            }
        }
    }

    /// ARGB words (0xAARRGGBB, little-endian) as an image, the layout TileMapCanvasView uses too.
    static func image(_ pixels: [UInt32], _ w: Int, _ h: Int) -> CGImage? {
        guard w > 0, h > 0, pixels.count >= w * h else { return nil }
        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                                | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: WmPaint.smooth, intent: .defaultIntent)
    }

    /// Draws an image into rect of a flipped view, scaled the way the Font smoothing setting says.
    static func draw(_ image: CGImage, in rect: NSRect) {
        guard let context = NSGraphicsContext.current else { return }
        context.saveGraphicsState()
        context.imageInterpolation = smooth ? .high : .none
        NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            .draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        context.restoreGraphicsState()
    }
}

/// A grid of character cells drawn with the bitmap font and scaled to the main screen's cell size: the frames, the
/// taskbar, the start menu and the drag label are all drawn with it, in the board's colours and glyphs, so they look
/// exactly like the text inside the windows. A cell with a clear background (alpha 0) shows what's behind it and lets
/// the mouse through, unless its glyph has pixels.
///
/// Port of the Windows client's `WmCellView` (a WPF FrameworkElement). The mouse and keyboard handlers WPF attaches
/// as events are closures here; `onKey` is called by RainwireDesk.handleKey while this view is the first responder.
final class WmCellView: NSView, RainwireStacked {
    struct Cell {
        var ch: UInt8
        var fg: UInt32
        var bg: UInt32
    }

    var z = 0
    private let font: () -> WmFont?
    private var cells: [Cell] = []
    private var pixels: [UInt32] = []
    private var image: CGImage?
    private var dirty = true
    private var trackingArea: NSTrackingArea?

    /// Lets every point through to what's behind (Windows: IsHitTestVisible = false).
    var passThrough = false
    var focusable = false
    var onMouseDown: ((NSEvent) -> Void)?
    var onMouseDragged: ((NSEvent) -> Void)?
    var onMouseUp: ((NSEvent) -> Void)?
    var onMouseMoved: ((NSEvent) -> Void)? {
        didSet { updateTrackingAreas() }
    }
    /// The pointer left the view (Windows: MouseLeave); needs onMouseMoved set too.
    var onMouseExited: ((NSEvent) -> Void)?
    /// A key while this view has the keyboard; true when used.
    var onKey: ((NSEvent) -> Bool)?
    var onResignFocus: (() -> Void)?

    private(set) var cols = 0
    private(set) var rows = 0

    init(font: @escaping () -> WmFont?) {
        self.font = font
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { focusable }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        onResignFocus?()
        return ok
    }

    override func keyDown(with event: NSEvent) {
        // Keys arrive through onKey (TerminalKeyMonitor -> RainwireDesk.handleKey); nothing else beeps
    }

    /// A new size in cells, all clear.
    func resize(_ newCols: Int, _ newRows: Int) {
        cols = max(0, newCols)
        rows = max(0, newRows)
        cells = Array(repeating: Cell(ch: 0, fg: 0, bg: 0), count: cols * rows)
        changed()
    }

    /// Everything clear (0) or filled with spaces in bg.
    func clear(_ bg: UInt32 = 0) {
        for i in 0..<cells.count {
            cells[i] = Cell(ch: 0x20, fg: 0, bg: bg)
        }
        changed()
    }

    func put(_ x: Int, _ y: Int, _ ch: UInt8, _ fg: UInt32, _ bg: UInt32) {
        if x < 0 || y < 0 || x >= cols || y >= rows {
            return
        }
        cells[y * cols + x] = Cell(ch: ch, fg: fg, bg: bg)
        changed()
    }

    /// Text from (x, y), clipped to the grid; returns the column after it.
    @discardableResult
    func text(_ x: Int, _ y: Int, _ s: [UInt8], _ fg: UInt32, _ bg: UInt32) -> Int {
        var at = x
        for b in s {
            put(at, y, b, fg, bg)
            at += 1
        }
        return at
    }

    @discardableResult
    func text(_ x: Int, _ y: Int, _ s: String, _ fg: UInt32, _ bg: UInt32) -> Int {
        text(x, y, WmTheme.cp(s), fg, bg)
    }

    func fill(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ fg: UInt32, _ bg: UInt32) {
        var yy = y
        while yy < y + h {
            var xx = x
            while xx < x + w {
                put(xx, yy, 0x20, fg, bg)
                xx += 1
            }
            yy += 1
        }
    }

    /// The font or smoothing changed: draw again.
    func refresh() {
        changed()
    }

    private func changed() {
        dirty = true
        needsDisplay = true
    }

    /// The cell under a point in this view.
    func cellAt(_ p: NSPoint) -> (x: Int, y: Int) {
        let cw = bounds.width / CGFloat(max(1, cols)), ch = bounds.height / CGFloat(max(1, rows))
        let x = Int((p.x / max(cw, 1e-6)).rounded(.down)), y = Int((p.y / max(ch, 1e-6)).rounded(.down))
        return (min(max(x, 0), max(0, cols - 1)), min(max(y, 0), max(0, rows - 1)))
    }

    override func draw(_ dirtyRect: NSRect) {
        if cols == 0 || rows == 0 {
            return
        }
        let f = font()
        let fh = f?.height ?? 16
        let pw = cols * 8, ph = rows * fh
        if pixels.count != pw * ph {
            pixels = [UInt32](repeating: 0, count: pw * ph)
            dirty = true
        }
        if dirty || image == nil {
            for y in 0..<rows {
                for x in 0..<cols {
                    let c = cells[y * cols + x]
                    WmPaint.glyph(&pixels, pw, x, y, c.ch, c.fg, c.bg, f, fh)
                }
            }
            image = WmPaint.image(pixels, pw, ph)
            dirty = false
        }
        if let image = image {
            WmPaint.draw(image, in: bounds)
        }
    }

    /// A clear cell with nothing drawn in it lets the mouse through.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if passThrough || isHidden || cols == 0 || rows == 0 {
            return nil
        }
        let p = convert(point, from: superview)
        if !bounds.contains(p) {
            return nil
        }
        let (x, y) = cellAt(p)
        let c = cells[y * cols + x]
        return (c.bg & 0xFF000000) != 0 || (c.ch != 0x20 && c.ch != 0) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = trackingArea {
            removeTrackingArea(area)
            trackingArea = nil
        }
        if onMouseMoved != nil {
            let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            trackingArea = area
        }
    }

    override func mouseDown(with event: NSEvent) { onMouseDown?(event) }
    override func mouseDragged(with event: NSEvent) { onMouseDragged?(event) }
    override func mouseUp(with event: NSEvent) { onMouseUp?(event) }
    override func mouseMoved(with event: NSEvent) { onMouseMoved?(event) }
    override func mouseExited(with event: NSEvent) { onMouseExited?(event) }

    override func scrollWheel(with event: NSEvent) {
        // The desk's own cells: the wheel over them does nothing (it never reaches the main screen behind)
    }
}
