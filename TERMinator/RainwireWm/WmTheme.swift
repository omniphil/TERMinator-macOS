import Foundation

/// A bitmap font: 256 CP437 glyphs, 8 pixels wide, one byte per row (bit 7 on the left).
final class WmFont {
    var data: [UInt8]
    let height: Int

    init(data: [UInt8], height: Int) {
        self.data = data
        self.height = height
    }
}

/// How the board wants its windows to look (the Theme message): the colours, the frame and button glyphs, the start
/// button's text and the font. TERMinator is only the engine: it draws the frames, taskbar and start menu as cells in
/// these colours and glyphs, with the same bitmap font as the window text, exactly as Rainwire's server-drawn desktop
/// would. Glyphs are CP437 codes (the board sends characters CP437 has). No AppKit.
/// Port of the Windows client's `RainwireWm/WmTheme.cs`; colours are 0xAARRGGBB.
final class WmTheme {
    var bg: UInt32, frame: UInt32, frameFocus: UInt32, titleFg: UInt32, titleBg: UInt32, focusFg: UInt32
    var focusBg: UInt32, outline: UInt32
    var barFg: UInt32, barBg: UInt32, taskFg: UInt32, taskBg: UInt32, dimFg: UInt32, hot: UInt32
    var popFg: UInt32, popBg: UInt32, selFg: UInt32, selBg: UInt32
    /// The colour of a window's shadow, or nil for no shadow.
    var shadow: UInt32?
    /// The fades a look like the board's modern one draws (Rainwire 0.9.19): the focused title bar and the start menu's
    /// selection from focusBg to focusBg2, the focused taskbar button from taskBg to taskBg2, and the start button from
    /// startFrom to startTo with its text in startFg. Nil when the board sent none: draw those flat. Only the
    /// graphical look (WmChrome.swift) reads them.
    var focusBg2: UInt32?, taskBg2: UInt32?, startFrom: UInt32?, startTo: UInt32?, startFg: UInt32?

    /// Frame corners and lines: top-left, top-right, bottom-left, bottom-right, horizontal, vertical.
    var box = WmTheme.cp("╔╗╚╝═║")
    /// The title bar's buttons: minimize, maximize, close.
    var buttons = WmTheme.cp("-■x")
    var start = WmTheme.cp("≡"), grip = WmTheme.cp("┘")
    var startText = WmTheme.cp("Rainwire"), menuText = WmTheme.cp("Start")
    /// The same two texts as the board sent them, for the graphical look's own fonts.
    var startLabel = "Rainwire", menuLabel = "Start"
    /// A font the board sent (Font messages) to draw with; "" for the terminal's own.
    var font = ""

    /// What to draw with until the board says: the classic look, as Rainwire draws it for SyncTERM.
    init() {
        bg = WmTheme.rgb(0x000000)
        frame = WmTheme.rgb(0xAAAAAA); frameFocus = WmTheme.rgb(0xFFFFFF)
        titleFg = WmTheme.rgb(0xAAAAAA); titleBg = WmTheme.rgb(0x0000AA)
        focusFg = WmTheme.rgb(0xFFFFFF); focusBg = WmTheme.rgb(0x00AAAA)
        outline = WmTheme.rgb(0xFFFF55)
        barFg = WmTheme.rgb(0x000000); barBg = WmTheme.rgb(0x00AAAA)
        taskFg = WmTheme.rgb(0xFFFFFF); taskBg = WmTheme.rgb(0x0000AA)
        dimFg = WmTheme.rgb(0x555555); hot = WmTheme.rgb(0xFFFF55)
        popFg = WmTheme.rgb(0xFFFFFF); popBg = WmTheme.rgb(0x0000AA)
        selFg = WmTheme.rgb(0x000000); selBg = WmTheme.rgb(0x00AAAA)
    }

    var tl: UInt8 { box[0] }
    var tr: UInt8 { box[1] }
    var bl: UInt8 { box[2] }
    var br: UInt8 { box[3] }
    var h: UInt8 { box[4] }
    var v: UInt8 { box[5] }

    /// The look from a Theme message; anything missing or malformed keeps its default.
    static func from(_ m: WmMessage) -> WmTheme {
        let t = WmTheme()
        func col(_ key: String) -> UInt32? { parseRgb(m.get(key)) }
        if let c = col("bg") { t.bg = c }
        if let c = col("frame") { t.frame = c }
        if let c = col("frame_focus") { t.frameFocus = c }
        if let c = col("title_fg") { t.titleFg = c }
        if let c = col("title_bg") { t.titleBg = c }
        if let c = col("focus_fg") { t.focusFg = c }
        if let c = col("focus_bg") { t.focusBg = c }
        if let c = col("outline") { t.outline = c }
        if let c = col("bar_fg") { t.barFg = c }
        if let c = col("bar_bg") { t.barBg = c }
        if let c = col("task_fg") { t.taskFg = c }
        if let c = col("task_bg") { t.taskBg = c }
        if let c = col("dim_fg") { t.dimFg = c }
        if let c = col("hot") { t.hot = c }
        if let c = col("pop_fg") { t.popFg = c }
        if let c = col("pop_bg") { t.popBg = c }
        if let c = col("sel_fg") { t.selFg = c }
        if let c = col("sel_bg") { t.selBg = c }
        t.shadow = col("shadow")
        t.focusBg2 = col("focus_bg2")
        t.taskBg2 = col("task_bg2")
        t.startFrom = col("start_from")
        t.startTo = col("start_to")
        t.startFg = col("start_fg")

        let box = cp(m.get("box"))
        if box.count == 6 { t.box = box }
        let buttons = cp(m.get("buttons"))
        if buttons.count == 3 { t.buttons = buttons }
        let start = cp(m.get("start"))
        if start.count == 1 { t.start = start }
        let grip = cp(m.get("grip"))
        if grip.count == 1 { t.grip = grip }
        // Lengths in UTF-16 units, as .NET's string.Length counts them
        let startText = m.get("start_text"), menuText = m.get("menu_text")
        if startText.utf16.count > 0 && startText.utf16.count <= 40 {
            t.startText = cp(startText)
            t.startLabel = startText
        }
        if menuText.utf16.count > 0 && menuText.utf16.count <= 40 {
            t.menuText = cp(menuText)
            t.menuLabel = menuText
        }
        let font = m.get("font")
        if font.utf16.count <= 64 { t.font = font }
        return t
    }

    /// rrggbb as an opaque ARGB colour, or nil.
    static func parseRgb(_ s: String) -> UInt32? {
        let chars = Array(s.utf8)
        if chars.count != 6 {
            return nil
        }
        var v: UInt32 = 0
        for c in chars {
            let d: UInt32
            switch c {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): d = UInt32(c - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): d = UInt32(c - UInt8(ascii: "a")) + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): d = UInt32(c - UInt8(ascii: "A")) + 10
            default: return nil
            }
            v = v * 16 + d
        }
        return rgb(v)
    }

    static func rgb(_ rgb: UInt32) -> UInt32 { 0xFF000000 | rgb }

    /// Text as CP437 codes for the bitmap font: '?' for anything CP437 lacks, and never a control code.
    static func cp(_ s: String) -> [UInt8] {
        s.map { Cp437.fromChar($0) ?? UInt8(ascii: "?") }
    }
}
