import AppKit

/// The graphical look for a board's windows (2026-10-05, sysop: "TERMinator can get the full graphical windows"): title
/// bars, buttons, borders, the taskbar and the start menu drawn with CoreGraphics and the system font in the board's
/// Theme colours, instead of as cells of the bitmap font. Only the drawing changes. The cell views (WmCellView) stay
/// where they were, still taking every click at alpha 0, so the geometry, the hit testing and everything sent to the
/// board are the same in both looks. Off (Settings: the board's text look), the cell views show as before.
///
/// Port of the Windows client's `RainwireWm/WmChrome.cs` (WPF FrameworkElements drawn in OnRender). Segoe UI there is
/// the system font here; WPF brushes are `WmBrush`; the drop shadows are NSShadows on the layer-backed views.
enum WmLook {
    /// The setting (AppPreferences.rainwireGraphicalWindows): the graphical look (true) or the board's own cells
    /// (false). Set by RainwireDeskLayerView.applyLook.
    static var graphical = true

    /// The text faces: Windows' Title (SemiBold), Label (Normal) and Bold.
    static let title = NSFont.Weight.semibold
    static let label = NSFont.Weight.regular
    static let bold = NSFont.Weight.bold

    static let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    private static func channel(_ v: UInt32, _ shift: UInt32) -> CGFloat { CGFloat((v >> shift) & 0xFF) / 255 }

    /// 0xAARRGGBB as a colour.
    static func c(_ argb: UInt32) -> NSColor {
        NSColor(srgbRed: channel(argb, 16), green: channel(argb, 8), blue: channel(argb, 0), alpha: channel(argb, 24))
    }

    /// 0xAARRGGBB at alpha (its own alpha ignored).
    static func c(_ argb: UInt32, _ alpha: CGFloat) -> NSColor {
        NSColor(srgbRed: channel(argb, 16), green: channel(argb, 8), blue: channel(argb, 0), alpha: min(max(alpha, 0), 1))
    }

    /// White or black at a byte alpha (Windows Color.FromArgb(a, 255, 255, 255) and the like).
    static func white(_ a: Int) -> NSColor { NSColor(srgbRed: 1, green: 1, blue: 1, alpha: CGFloat(a) / 255) }
    static func black(_ a: Int) -> NSColor { NSColor(srgbRed: 0, green: 0, blue: 0, alpha: CGFloat(a) / 255) }

    static func solid(_ argb: UInt32) -> WmBrush { .solid(c(argb)) }

    /// Left to right from a to b; flat a when there's no b.
    static func fade(_ a: UInt32, _ b: UInt32?) -> WmBrush {
        if let to = b, to != a {
            return .linear(c(a), c(to), false)
        }
        return solid(a)
    }

    /// The board's logo colours: its start fade (Rainwire's blue to purple), else its focus fade. The graphical look
    /// uses them as see-through tints over the dark panels rather than solid fills (sysop 2026-10-05: the first colours
    /// were "a bit harsh"; "theme colored to the rainwire logo colors or just softer").
    static func accent(_ th: WmTheme) -> (a: UInt32, b: UInt32) {
        let a = th.startFrom ?? th.focusBg
        return (a, th.startTo ?? th.focusBg2 ?? a)
    }

    /// The logo fade, left to right, at alpha.
    static func tint(_ th: WmTheme, _ alpha: CGFloat) -> WmBrush {
        let (a, b) = accent(th)
        return .linear(c(a, alpha), c(b, alpha), false)
    }

    /// A colour at alpha.
    static func soft(_ argb: UInt32, _ alpha: CGFloat) -> WmBrush { .solid(c(argb, alpha)) }

    /// A colour taken k of the way to white: text that reads on dark without glaring.
    static func light(_ argb: UInt32, _ k: CGFloat) -> NSColor {
        NSColor(srgbRed: lift(channel(argb, 16), k), green: lift(channel(argb, 8), k), blue: lift(channel(argb, 0), k),
                alpha: 1)
    }

    /// Top to bottom, a little lighter at the top: depth on a flat colour.
    static func sheen(_ argb: UInt32, _ by: CGFloat = 0.10) -> WmBrush {
        let top = NSColor(srgbRed: lift(channel(argb, 16), by), green: lift(channel(argb, 8), by),
                          blue: lift(channel(argb, 0), by), alpha: 1)
        return .linear(top, c(argb), true)
    }

    /// Windows lifts bytes and clamps them; channels here are 0...1, so the same sum, rounded to a byte.
    private static func lift(_ v: CGFloat, _ by: CGFloat) -> CGFloat {
        (min(max(v + (1 - v) * by, 0), 1) * 255).rounded(.down) / 255
    }

    /// One line of text, cut with an ellipsis to fit maxW.
    static func text(_ s: String, _ weight: NSFont.Weight, _ size: CGFloat, _ color: NSColor, _ maxW: CGFloat) -> WmText {
        let font = NSFont.systemFont(ofSize: max(size, 1), weight: weight)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let limit = max(1, maxW)
        var str = NSAttributedString(string: s, attributes: attrs)
        if str.size().width > limit {
            var chars = Array(s)
            str = NSAttributedString(string: "", attributes: attrs)
            while !chars.isEmpty {
                chars.removeLast()
                let cut = NSAttributedString(string: String(chars) + "…", attributes: attrs)
                if cut.size().width <= limit {
                    str = cut
                    break
                }
            }
        }
        // The line's height even when the text is empty, as WPF's FormattedText measures it
        let line = NSAttributedString(string: "Ag", attributes: attrs).size().height
        return WmText(string: str, width: str.size().width, height: line)
    }

    /// A text size that suits a cell height.
    static func size(_ cellH: CGFloat, _ k: CGFloat = 0.62) -> CGFloat { min(max(cellH * k, 8), 40) }

    /// A rounded rectangle; the radius shrinks to fit (CGPath asserts on a radius bigger than half a side).
    static func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath {
        let rad = max(0, min(radius, r.width / 2, r.height / 2))
        if rad <= 0 {
            return CGPath(rect: r, transform: nil)
        }
        return CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil)
    }

    /// The drop shadow WPF's DropShadowEffect gave (Direction 270 is straight down). NSShadow's offset is in
    /// unflipped space whatever the view, so down is a negative height.
    static func shadow(blur: CGFloat, depth: CGFloat, opacity: CGFloat) -> NSShadow {
        let s = NSShadow()
        s.shadowBlurRadius = blur
        s.shadowOffset = NSSize(width: 0, height: -depth)
        s.shadowColor = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: opacity)
        return s
    }

    /// The current drawing context, in a view's draw(_:).
    static var context: CGContext? { NSGraphicsContext.current?.cgContext }
}

/// A WPF Brush: a flat colour or a two-stop linear fade over the bounds of what it fills (left to right, or top to
/// bottom when vertical).
enum WmBrush {
    case solid(NSColor)
    case linear(NSColor, NSColor, Bool)

    func fill(_ path: CGPath, _ g: CGContext) {
        switch self {
        case .solid(let colour):
            g.addPath(path)
            g.setFillColor(colour.cgColor)
            g.fillPath()
        case .linear(let a, let b, let vertical):
            let r = path.boundingBoxOfPath
            guard let grad = CGGradient(colorsSpace: WmLook.space, colors: [a.cgColor, b.cgColor] as CFArray,
                                        locations: [0, 1]) else { return }
            g.saveGState()
            g.addPath(path)
            g.clip()
            let end = vertical ? CGPoint(x: r.minX, y: r.maxY) : CGPoint(x: r.maxX, y: r.minY)
            g.drawLinearGradient(grad, start: CGPoint(x: r.minX, y: r.minY), end: end,
                                 options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            g.restoreGState()
        }
    }

    func fill(_ rect: CGRect, _ g: CGContext) {
        fill(CGPath(rect: rect, transform: nil), g)
    }

    /// A pen of this brush along the path (centred on it, as WPF's is).
    func stroke(_ path: CGPath, _ g: CGContext, width: CGFloat = 1) {
        fill(path.copy(strokingWithWidth: width, lineCap: .butt, lineJoin: .miter, miterLimit: 10), g)
    }
}

/// One measured line of text (WPF's FormattedText).
struct WmText {
    let string: NSAttributedString
    let width: CGFloat
    let height: CGFloat

    /// Draws with its top-left at p, in a flipped view.
    func draw(at p: CGPoint) {
        string.draw(at: p)
    }
}

/// One window's frame in the graphical look: rounded corners, a soft shadow, the title bar (the board's fade when it
/// sends one), the title in the system font, and minimize, maximize and close drawn as icons that light up under the
/// pointer. It covers exactly the cells the board's frame does (the title row, a column each side, the bottom row), so
/// the window content sits where it always did.
final class WmFrameChrome: NSView {
    private let theme: () -> WmTheme

    var focused = false, max = false
    var title = ""
    /// The title button under the pointer (0 minimize, 1 maximize, 2 close), or -1.
    var hover = -1
    var cols = 0, rows = 0   // the frame's outside size in cells

    init(theme: @escaping () -> WmTheme) {
        self.theme = theme
        super.init(frame: .zero)
        wantsLayer = true
        shadow = WmLook.shadow(blur: 10, depth: 3, opacity: 0.55)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var isFlipped: Bool { true }

    /// Never takes the mouse (Windows: IsHitTestVisible = false): the cell view above it does.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard cols >= 3, rows >= 2, bounds.width >= 1, let g = WmLook.context else { return }
        let th = theme()
        let w = bounds.width, h = bounds.height
        let cw = w / CGFloat(cols), ch = h / CGFloat(rows)
        let r: CGFloat = max ? 0 : Swift.min(8, ch * 0.45)
        let outer = CGRect(x: 0.5, y: 0.5, width: w - 1, height: h - 1)
        let outerPath = WmLook.rounded(outer, r)

        // The body: the window's own background shows in the side and bottom margins
        WmLook.solid(th.popBg).fill(outerPath, g)

        // The title bar, clipped to the top corners
        let bar = CGRect(x: outer.minX, y: outer.minY, width: outer.width, height: ch)
        g.saveGState()
        g.addPath(outerPath)
        g.clip()
        WmLook.sheen(th.titleBg, 0.05).fill(bar, g)
        if focused {
            WmLook.tint(th, 0.42).fill(bar, g)   // the logo fade, softened over the bar
        }
        // a hairline of light along its top edge, and a darker one under it
        WmBrush.solid(WmLook.white(focused ? 60 : 28)).fill(CGRect(x: bar.minX, y: bar.minY, width: bar.width, height: 1), g)
        WmBrush.solid(WmLook.black(70)).fill(CGRect(x: bar.minX, y: bar.maxY - 1, width: bar.width, height: 1), g)

        // The buttons: three cells each from the right, as the board's frame lays them out
        let tfg = focused ? th.focusFg : th.titleFg
        let bx = w - 9 * cw, bw = 3 * cw
        for i in 0..<3 {
            let b = CGRect(x: bx + CGFloat(i) * bw, y: bar.minY, width: bw, height: ch)
            if hover == i {
                let hl = i == 2 ? NSColor(srgbRed: 0xE8 / 255.0, green: 0x11 / 255.0, blue: 0x23 / 255.0, alpha: 1)
                                : WmLook.white(48)
                WmBrush.solid(hl).fill(b, g)
            }
            drawButton(g, i, b, WmLook.c(hover == 2 && i == 2 ? 0xFFFFFFFF : tfg), ch)
        }

        // The title
        let titleText = WmLook.text(title.isEmpty ? "Rainwire" : title, WmLook.title, WmLook.size(ch),
                                    WmLook.c(tfg), Swift.max(1, bx - cw * 1.2))
        titleText.draw(at: CGPoint(x: cw * 0.9, y: bar.minY + (ch - titleText.height) / 2))
        g.restoreGState()

        // The border: the board's frame colour, brighter when focused
        let pen = focused ? WmLook.soft(WmLook.accent(th).a, 0.45) : WmLook.soft(th.frame, 0.35)
        pen.stroke(outerPath, g, width: 1)

        // The resize grip: three dots in the bottom-right corner
        if !max {
            g.setFillColor(WmLook.c(th.frame, 0.9).cgColor)
            let s = Swift.max(1.5, ch / 10), gx = w - cw * 0.45, gy = h - ch * 0.4
            let rad = s * 0.55
            for i in 0..<3 {
                for j in 0...i {
                    let cx = gx - CGFloat(i - j) * s * 2.2, cy = gy - CGFloat(j) * s * 2.2
                    g.fillEllipse(in: CGRect(x: cx - rad, y: cy - rad, width: rad * 2, height: rad * 2))
                }
            }
        }
    }

    private func drawButton(_ g: CGContext, _ which: Int, _ b: CGRect, _ fg: NSColor, _ ch: CGFloat) {
        g.saveGState()
        g.setStrokeColor(fg.cgColor)
        g.setLineWidth(Swift.max(1, (ch / 14).rounded()))
        let s = Swift.min(b.width, b.height) * 0.34
        let c = CGPoint(x: b.midX, y: b.midY)
        func line(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) {
            g.strokeLineSegments(between: [CGPoint(x: x1, y: y1), CGPoint(x: x2, y: y2)])
        }
        switch which {
        case 0:   // minimize: a bar
            line(c.x - s / 2, c.y + s / 3, c.x + s / 2, c.y + s / 3)
        case 1 where max:   // restore: two squares
            g.stroke(CGRect(x: c.x - s / 2, y: c.y - s / 2 + s * 0.25, width: s * 0.75, height: s * 0.75))
            line(c.x - s / 2 + s * 0.25, c.y - s / 2 + s * 0.25, c.x - s / 2 + s * 0.25, c.y - s / 2)
            line(c.x - s / 2 + s * 0.25, c.y - s / 2, c.x + s / 2, c.y - s / 2)
            line(c.x + s / 2, c.y - s / 2, c.x + s / 2, c.y + s / 2 - s * 0.25)
        case 1:   // maximize: a square
            g.stroke(CGRect(x: c.x - s / 2, y: c.y - s / 2, width: s, height: s))
        default:  // close: a cross
            line(c.x - s / 2, c.y - s / 2, c.x + s / 2, c.y + s / 2)
            line(c.x + s / 2, c.y - s / 2, c.x - s / 2, c.y + s / 2)
        }
        g.restoreGState()
    }
}

/// While a window is resized: a see-through box in the board's outline colour, with the new size in it.
final class WmOutlineChrome: NSView, RainwireStacked {
    var z = 0
    private let theme: () -> WmTheme
    var cols = 0, rows = 0   // the content's new size, shown in the middle

    init(theme: @escaping () -> WmTheme) {
        self.theme = theme
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let g = WmLook.context else { return }
        let th = theme()
        let rect = CGRect(x: 1, y: 1, width: max(1, bounds.width - 2), height: max(1, bounds.height - 2))
        let box = WmLook.rounded(rect, 6)
        WmBrush.solid(WmLook.c(th.outline, 0.12)).fill(box, g)
        WmBrush.solid(WmLook.c(th.outline, 0.95)).stroke(box, g, width: 2)
        let t = WmLook.text("\(cols) × \(rows)", WmLook.bold, 15, WmLook.c(th.outline), rect.width)
        let at = CGPoint(x: rect.minX + (rect.width - t.width) / 2, y: rect.minY + (rect.height - t.height) / 2)
        WmBrush.solid(WmLook.black(170)).fill(
            WmLook.rounded(CGRect(x: at.x - 10, y: at.y - 4, width: t.width + 20, height: t.height + 8), 6), g)
        t.draw(at: at)
    }
}

/// The taskbar in the graphical look: the board's bar colour with some depth, the start button as a pill in the board's
/// start fade, and a rounded button per window (the focused one in the board's fade, a minimized one dimmed). The spans
/// are the cell ranges the desk layer hit-tests, so a click lands where it's drawn.
final class WmBarChrome: NSView, RainwireStacked {
    struct Task {
        let from: Int, to: Int
        let label: String
        let focused: Bool, minimized: Bool
    }

    var z = 0
    private let theme: () -> WmTheme

    var cols = 0
    var start = (from: 0, to: 0)
    var menuOpen = false, startHover = false
    var tasks: [Task] = []

    init(theme: @escaping () -> WmTheme) {
        self.theme = theme
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard cols >= 1, bounds.width >= 1, let g = WmLook.context else { return }
        let th = theme()
        let cw = bounds.width / CGFloat(cols), h = bounds.height
        WmLook.sheen(th.barBg, 0.08).fill(CGRect(x: 0, y: 0, width: bounds.width, height: h), g)
        WmLook.tint(th, 0.25).fill(CGRect(x: 0, y: 0, width: bounds.width, height: 1), g)

        let pad = max(1.5, h * 0.12), r = (h - 2 * pad) / 2
        // The start button
        let sb = CGRect(x: CGFloat(start.from) * cw + pad, y: pad,
                        width: CGFloat(start.to - start.from) * cw - 2 * pad, height: h - 2 * pad)
        if sb.width > 2 {
            // Just the menu mark and an R (sysop 2026-10-05), in the logo fade
            let pill = WmLook.rounded(sb, r)
            WmLook.tint(th, menuOpen ? 0.75 : startHover ? 0.62 : 0.5).fill(pill, g)
            WmLook.tint(th, 0.6).stroke(pill, g)
            let t = WmLook.text("≡ R", WmLook.bold, WmLook.size(h, 0.6), WmLook.light(WmLook.accent(th).a, 0.8), sb.width)
            t.draw(at: CGPoint(x: sb.minX + (sb.width - t.width) / 2, y: sb.minY + (sb.height - t.height) / 2))
        }
        // A button per window
        for task in tasks {
            let b = CGRect(x: CGFloat(task.from) * cw + pad, y: pad,
                           width: CGFloat(task.to - task.from) * cw - 2 * pad, height: h - 2 * pad)
            if b.width < 4 {
                continue
            }
            let shape = WmLook.rounded(b, 4)
            if task.focused {
                WmLook.tint(th, 0.36).fill(shape, g)
                WmLook.tint(th, 0.5).stroke(shape, g)
            } else {
                WmBrush.solid(WmLook.white(task.minimized ? 8 : 18)).fill(shape, g)
            }
            let fg = task.focused ? th.taskFg : task.minimized ? th.dimFg : th.barFg
            let t = WmLook.text(task.label, task.focused ? WmLook.title : WmLook.label, WmLook.size(h, 0.54),
                                WmLook.c(fg), b.width - 12)
            t.draw(at: CGPoint(x: b.minX + 6, y: b.minY + (b.height - t.height) / 2))
        }
    }
}

/// The start menu in the graphical look: a rounded panel in the board's popup colours, its title, and one row per item
/// with the hotkey in a little badge; the selected row in the board's fade. Rows are the cell rows the desk layer
/// hit-tests.
final class WmMenuChrome: NSView, RainwireStacked {
    var z = 0
    private let theme: () -> WmTheme

    var cols = 0, rows = 0, selected = -1
    var items: [(key: String, label: String)] = []

    init(theme: @escaping () -> WmTheme) {
        self.theme = theme
        super.init(frame: .zero)
        wantsLayer = true
        shadow = WmLook.shadow(blur: 11, depth: 3, opacity: 0.6)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard cols >= 3, rows >= 3, bounds.width >= 1, let g = WmLook.context else { return }
        let th = theme()
        let width = bounds.width
        let cw = width / CGFloat(cols), ch = bounds.height / CGFloat(rows)
        let outer = WmLook.rounded(CGRect(x: 0.5, y: 0.5, width: width - 1, height: bounds.height - 1), 8)
        let accent = WmLook.accent(th).a
        WmLook.sheen(th.popBg, 0.05).fill(outer, g)
        WmLook.soft(accent, 0.35).stroke(outer, g)
        let title = WmLook.text(th.menuLabel, WmLook.bold, WmLook.size(ch, 0.6), WmLook.light(accent, 0.35), width - 2 * cw)
        title.draw(at: CGPoint(x: cw * 1.2, y: (ch - title.height) / 2))
        WmLook.tint(th, 0.18).fill(CGRect(x: cw, y: ch - 1, width: width - 2 * cw, height: 1), g)

        var i = 0
        while i < items.count && i < rows - 2 {
            let row = CGRect(x: cw * 0.5, y: CGFloat(i + 1) * ch, width: width - cw, height: ch)
            let sel = i == selected
            if sel {
                let shape = WmLook.rounded(row, 5)
                WmLook.tint(th, 0.32).fill(shape, g)
                WmLook.tint(th, 0.5).stroke(shape, g)
            }
            let key = WmLook.text(items[i].key, WmLook.bold, WmLook.size(ch, 0.55), WmLook.light(accent, 0.5), cw * 2)
            let badge = CGRect(x: row.minX + cw * 0.5, y: row.minY + ch * 0.14,
                               width: max(cw * 1.6, key.width + 8), height: ch * 0.72)
            WmLook.soft(accent, sel ? 0.28 : 0.14).fill(WmLook.rounded(badge, 4), g)
            key.draw(at: CGPoint(x: badge.minX + (badge.width - key.width) / 2, y: badge.minY + (badge.height - key.height) / 2))
            let label = WmLook.text(items[i].label, sel ? WmLook.title : WmLook.label, WmLook.size(ch, 0.58),
                                    sel ? WmLook.c(th.focusFg) : WmLook.c(th.popFg, 0.88), row.maxX - badge.maxX - cw)
            label.draw(at: CGPoint(x: badge.maxX + cw * 0.8, y: row.minY + (ch - label.height) / 2))
            i += 1
        }
    }
}
