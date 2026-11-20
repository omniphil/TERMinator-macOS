import Foundation

/// The terminal behind one Rainwire window: a width x height grid of cells, fed the window's output. A window's
/// screen is what a Rainwire session sends any terminal (ANSI with 24-bit colour, cursor positioning, sixel), in the
/// character set the board detected: CP437 here, so each cell keeps its CP437 code and the window draws it with the
/// same bitmap font as the main screen. Deliberately small: the sequences Rainwire's renderers and its door virtual
/// terminal produce, plus the usual cursor and erase commands, not a full VT500. No AppKit, so it's testable alone.
/// Port of the Windows client's `RainwireWm/WmTerminal.cs`. Colours are 0xAARRGGBB, as on Windows.
final class WmTerminal {
    struct Cell {
        var ch: UInt8        // CP437 code
        var fg: UInt32       // ARGB
        var bg: UInt32       // ARGB
        var underline: Bool
    }

    /// A sixel picture, placed with its top-left corner in cell (col, row). Clear pixels are 0.
    final class Picture {
        var col = 0, row = 0, width = 0, height = 0
        var pixels: [UInt32] = []
    }

    static let minWidth = 20, maxWidth = 500, minHeight = 5, maxHeight = 300

    private(set) var width: Int
    private(set) var height: Int
    private(set) var cursorX = 0
    private(set) var cursorY = 0
    private(set) var cursorVisible = true
    /// The app asked for mouse reports (1000, 1002 or 1003).
    var mouseReporting: Bool { mouse1000 || mouse1002 || mouse1003 }
    /// The app asked for button-motion (1002) or any-motion (1003) reports.
    var mouseMotion: Bool { mouse1002 || mouse1003 }
    /// The app asked for SGR mouse coordinates (1006), as Rainwire always does.
    private(set) var mouseSgr = false
    /// Goes up on every change, so a view knows to redraw.
    private(set) var version = 0
    private(set) var pictures: [Picture] = []
    /// Answers to status queries (cursor position, device attributes), to send back to the window.
    var reply: (([UInt8]) -> Void)?

    static let defaultFg: UInt32 = 0xFFAAAAAA
    static let defaultBg: UInt32 = 0xFF000000

    private var cells: [Cell]
    private var fg = WmTerminal.defaultFg, bg = WmTerminal.defaultBg, fgIndex = 7
    private var bold = false, reverse = false, underline = false
    private var pendingWrap = false
    private var top = 0, bottom = 0   // scroll region, inclusive
    private var savedX = 0, savedY = 0
    private var mouse1000 = false, mouse1002 = false, mouse1003 = false

    // Parser
    private enum State { case ground, esc, escSkip, csi, osc, oscEsc, dcs, dcsEsc, ignore, ignoreEsc }
    private var state = State.ground
    private var params: [UInt8] = []
    private var dcs: [UInt8] = []
    private static let dcsMax = 4 * 1024 * 1024

    // The 16 CGA colours, and ANSI colour order to CGA order
    static let cga: [UInt32] = [
        0xFF000000, 0xFF0000AA, 0xFF00AA00, 0xFF00AAAA, 0xFFAA0000, 0xFFAA00AA, 0xFFAA5500, 0xFFAAAAAA,
        0xFF555555, 0xFF5555FF, 0xFF55FF55, 0xFF55FFFF, 0xFFFF5555, 0xFFFF55FF, 0xFFFFFF55, 0xFFFFFFFF,
    ]
    private static let ansiToCga = [0, 4, 2, 6, 1, 5, 3, 7]

    init(_ width: Int, _ height: Int) {
        let w = min(max(width, WmTerminal.minWidth), WmTerminal.maxWidth)
        let h = min(max(height, WmTerminal.minHeight), WmTerminal.maxHeight)
        self.width = w
        self.height = h
        cells = Array(repeating: Cell(ch: 0x20, fg: WmTerminal.defaultFg, bg: WmTerminal.defaultBg, underline: false),
                      count: w * h)
        bottom = h - 1
    }

    subscript(x: Int, y: Int) -> Cell { cells[y * width + x] }

    /// A row as text, trailing blanks trimmed (for drag labels).
    func rowText(_ y: Int) -> String {
        var s = ""
        for x in 0..<width {
            s.append(Cp437.toChar(cells[y * width + x].ch))
        }
        while let last = s.last, last == " " || last == "\u{0000}" {
            s.removeLast()
        }
        return s
    }

    /// The whole screen as text, one line per row.
    func text() -> String {
        (0..<height).map { rowText($0) }.joined(separator: "\n")
    }

    /// New size in cells. The contents stay where they are, cut or padded; pictures are dropped.
    func resize(_ newWidth: Int, _ newHeight: Int) {
        let w = min(max(newWidth, WmTerminal.minWidth), WmTerminal.maxWidth)
        let h = min(max(newHeight, WmTerminal.minHeight), WmTerminal.maxHeight)
        if w == width && h == height {
            return
        }
        var next = Array(repeating: Cell(ch: 0x20, fg: WmTerminal.defaultFg, bg: WmTerminal.defaultBg, underline: false),
                         count: w * h)
        for y in 0..<min(h, height) {
            for x in 0..<min(w, width) {
                next[y * w + x] = cells[y * width + x]
            }
        }
        cells = next
        width = w
        height = h
        top = 0
        bottom = h - 1
        cursorX = min(cursorX, w - 1)
        cursorY = min(cursorY, h - 1)
        pendingWrap = false
        pictures.removeAll()
        version += 1
    }

    func feed(_ data: [UInt8]) {
        for c in data {
            step(c)
        }
        version += 1
    }

    private func step(_ c: UInt8) {
        switch state {
        case .ground:
            ground(c)
        case .esc:
            escape(c)
        case .escSkip:   // the one byte after ESC ( and the like
            state = .ground
        case .csi:
            if c >= 0x40 && c <= 0x7E {
                state = .ground
                csi(params, Character(UnicodeScalar(c)))
            } else if c == 0x1B {
                state = .esc
            } else if c == 0x18 || c == 0x1A {
                state = .ground   // CAN, SUB cancel it
            } else if params.count < 64 {
                params.append(c)
            }
        case .osc:
            if c == 0x07 {
                state = .ground
            } else if c == 0x1B {
                state = .oscEsc
            }
        case .oscEsc:
            state = c == UInt8(ascii: "\\") ? .ground : .osc
        case .dcs:
            if c == 0x1B {
                state = .dcsEsc
            } else if dcs.count < WmTerminal.dcsMax {
                dcs.append(c)
            }
        case .dcsEsc:
            if c == UInt8(ascii: "\\") {
                state = .ground
                dcsDone()
            } else {
                state = .dcs
                if dcs.count < WmTerminal.dcsMax {
                    dcs.append(0x1B)
                    dcs.append(c)
                }
            }
        case .ignore:   // APC, PM, SOS: read to ST and drop
            if c == 0x1B {
                state = .ignoreEsc
            }
        case .ignoreEsc:
            state = c == UInt8(ascii: "\\") ? .ground : .ignore
        }
    }

    private func ground(_ c: UInt8) {
        switch c {
        case 0x00, 0x07:   // bell: the main screen rings for the session
            return
        case 0x08:
            pendingWrap = false
            if cursorX > 0 {
                cursorX -= 1
            }
            return
        case 0x09:
            pendingWrap = false
            cursorX = min((cursorX / 8 + 1) * 8, width - 1)
            return
        case 0x0A, 0x0B, 0x0C:
            pendingWrap = false
            lineFeed()
            return
        case 0x0D:
            pendingWrap = false
            cursorX = 0
            return
        case 0x1B:
            state = .esc
            return
        default:
            break
        }
        // Everything else is a glyph, the other C0 codes included: Rainwire sends 0x10 and 0x11 as the CP437
        // triangles, the way the main screen shows them.
        put(c)
    }

    private func put(_ ch: UInt8) {
        if pendingWrap {
            pendingWrap = false
            cursorX = 0
            lineFeed()
        }
        var f = fg, b = bg
        if bold && fgIndex >= 0 && fgIndex < 8 {
            f = WmTerminal.cga[fgIndex + 8]
        }
        if reverse {
            swap(&f, &b)
        }
        cells[cursorY * width + cursorX] = Cell(ch: ch, fg: f, bg: b, underline: underline)
        if cursorX == width - 1 {
            pendingWrap = true
        } else {
            cursorX += 1
        }
    }

    private func lineFeed() {
        if cursorY == bottom {
            scrollUp(1)
        } else if cursorY < height - 1 {
            cursorY += 1
        }
    }

    private func escape(_ c: UInt8) {
        state = .ground
        switch Character(UnicodeScalar(c)) {
        case "[":
            params.removeAll(keepingCapacity: true)
            state = .csi
        case "]":
            state = .osc
        case "P":
            dcs.removeAll(keepingCapacity: true)
            state = .dcs
        case "_", "^", "X":
            state = .ignore
        case "(", ")", "*", "+", "#", "%":
            state = .escSkip
        case "7":
            savedX = cursorX
            savedY = cursorY
        case "8":
            restoreCursor()
        case "D":
            lineFeed()
        case "E":
            cursorX = 0
            lineFeed()
        case "M":
            if cursorY == top {
                scrollDown(1)
            } else if cursorY > 0 {
                cursorY -= 1
            }
        case "c":
            reset()
        default:
            break
        }
    }

    /// ESC 8, CSI u: back to the saved cursor, kept on the grid (the window may have shrunk since ESC 7).
    private func restoreCursor() {
        cursorX = clamp(savedX, 0, width - 1)
        cursorY = clamp(savedY, 0, height - 1)
        pendingWrap = false
    }

    private func reset() {
        fg = WmTerminal.defaultFg
        bg = WmTerminal.defaultBg
        fgIndex = 7
        bold = false
        reverse = false
        underline = false
        top = 0
        bottom = height - 1
        cursorX = 0
        cursorY = 0
        cursorVisible = true
        pendingWrap = false
        blank(0, cells.count)
        pictures.removeAll()
    }

    private static func numbers(_ raw: [UInt8], _ marker: inout Character) -> [Int] {
        marker = "\0"
        var p = raw[...]
        if let first = p.first, first == UInt8(ascii: "?") || first == UInt8(ascii: "<")
            || first == UInt8(ascii: "=") || first == UInt8(ascii: ">") {
            marker = Character(UnicodeScalar(first))
            p = p.dropFirst()
        }
        if p.isEmpty {
            return []
        }
        return p.split(separator: UInt8(ascii: ";"), omittingEmptySubsequences: false).map { part -> Int in
            var v = 0
            for ch in part {
                if ch < UInt8(ascii: "0") || ch > UInt8(ascii: "9") {
                    break
                }
                v = min(v * 10 + Int(ch - UInt8(ascii: "0")), 99999)
            }
            return v
        }
    }

    private static func arg(_ n: [Int], _ i: Int, _ def: Int) -> Int {
        i < n.count && n[i] > 0 ? n[i] : def
    }

    private func csi(_ p: [UInt8], _ fin: Character) {
        var marker: Character = "\0"
        let n = WmTerminal.numbers(p, &marker)
        let arg = WmTerminal.arg
        if marker == "?" {
            if fin == "h" || fin == "l" {
                privateMode(n, fin == "h")
            }
            return
        }
        if marker != "\0" {
            return   // ESC[=...c, ESC[>c and the like: nothing for a window
        }
        pendingWrap = false
        switch fin {
        case "H", "f":
            cursorY = clamp(arg(n, 0, 1) - 1, 0, height - 1)
            cursorX = clamp(arg(n, 1, 1) - 1, 0, width - 1)
        case "A":
            cursorY = max(cursorY - arg(n, 0, 1), 0)
        case "B":
            cursorY = min(cursorY + arg(n, 0, 1), height - 1)
        case "C":
            cursorX = min(cursorX + arg(n, 0, 1), width - 1)
        case "D":
            cursorX = max(cursorX - arg(n, 0, 1), 0)
        case "E":
            cursorY = min(cursorY + arg(n, 0, 1), height - 1)
            cursorX = 0
        case "F":
            cursorY = max(cursorY - arg(n, 0, 1), 0)
            cursorX = 0
        case "G", "`":
            cursorX = clamp(arg(n, 0, 1) - 1, 0, width - 1)
        case "d":
            cursorY = clamp(arg(n, 0, 1) - 1, 0, height - 1)
        case "J":
            eraseDisplay(n.isEmpty ? 0 : n[0])
        case "K":
            eraseLine(n.isEmpty ? 0 : n[0])
        case "X":
            blank(cursorY * width + cursorX, min(arg(n, 0, 1), width - cursorX))
        case "@":
            insertChars(arg(n, 0, 1))
        case "P":
            deleteChars(arg(n, 0, 1))
        case "L":
            if cursorY >= top && cursorY <= bottom {
                scrollRegion(cursorY, bottom, -arg(n, 0, 1))
            }
        case "M":
            if cursorY >= top && cursorY <= bottom {
                scrollRegion(cursorY, bottom, arg(n, 0, 1))
            }
        case "S":
            scrollUp(arg(n, 0, 1))
        case "T":
            scrollDown(arg(n, 0, 1))
        case "r":
            let t = arg(n, 0, 1) - 1, b = arg(n, 1, height) - 1
            if t < b && b < height {
                top = t
                bottom = b
            } else {
                top = 0
                bottom = height - 1
            }
            cursorX = 0
            cursorY = 0
        case "s":
            savedX = cursorX
            savedY = cursorY
        case "u":
            restoreCursor()
        case "m":
            sgr(n)
        case "n":
            if arg(n, 0, 0) == 6 {
                reply?(Array("\u{1B}[\(cursorY + 1);\(cursorX + 1)R".utf8))
            } else if arg(n, 0, 0) == 5 {
                reply?(Array("\u{1B}[0n".utf8))
            }
        case "c":
            reply?(Array("\u{1B}[?62;22c".utf8))
        default:
            break
        }
    }

    private func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int {
        min(max(v, lo), hi)
    }

    private func privateMode(_ n: [Int], _ on: Bool) {
        for mode in n {
            switch mode {
            case 25:
                cursorVisible = on
            case 9, 1000:
                mouse1000 = on
            case 1002:
                mouse1002 = on
            case 1003:
                mouse1003 = on
            case 1006:
                mouseSgr = on
            case 47, 1047, 1049:
                // The alternate screen: a window has only one, so switching either way starts it blank
                blank(0, cells.count)
                pictures.removeAll()
            default:
                break
            }
        }
    }

    private func sgr(_ input: [Int]) {
        let n = input.isEmpty ? [0] : input
        var i = 0
        while i < n.count {
            let v = n[i]
            switch v {
            case 0:
                fg = WmTerminal.defaultFg
                bg = WmTerminal.defaultBg
                fgIndex = 7
                bold = false
                reverse = false
                underline = false
            case 1:
                bold = true
            case 22:
                bold = false
            case 4:
                underline = true
            case 24:
                underline = false
            case 7:
                reverse = true
            case 27:
                reverse = false
            case 30...37:
                fgIndex = WmTerminal.ansiToCga[v - 30]
                fg = WmTerminal.cga[fgIndex]
            case 90...97:
                fgIndex = -1
                fg = WmTerminal.cga[WmTerminal.ansiToCga[v - 90] + 8]
            case 39:
                fgIndex = 7
                fg = WmTerminal.defaultFg
            case 40...47:
                bg = WmTerminal.cga[WmTerminal.ansiToCga[v - 40]]
            case 100...107:
                bg = WmTerminal.cga[WmTerminal.ansiToCga[v - 100] + 8]
            case 49:
                bg = WmTerminal.defaultBg
            case 38, 48:
                var colour: UInt32?
                if i + 1 < n.count && n[i + 1] == 2 && i + 4 < n.count {
                    let r = UInt32(min(n[i + 2], 255)), g = UInt32(min(n[i + 3], 255)), b = UInt32(min(n[i + 4], 255))
                    colour = 0xFF000000 | (r << 16) | (g << 8) | b
                    i += 4
                } else if i + 1 < n.count && n[i + 1] == 5 && i + 2 < n.count {
                    colour = WmTerminal.colour256(n[i + 2])
                    i += 2
                } else {
                    i = n.count   // malformed: ignore the rest
                }
                if let c = colour {
                    if v == 38 {
                        fg = c
                        fgIndex = -1
                    } else {
                        bg = c
                    }
                }
            default:
                break
            }
            i += 1
        }
    }

    private static func colour256(_ index: Int) -> UInt32 {
        if index < 16 {
            return cga[index < 8 ? ansiToCga[index] : ansiToCga[index - 8] + 8]
        }
        if index < 232 {
            let i = index - 16
            let level: [UInt32] = [0, 95, 135, 175, 215, 255]
            let r = level[i / 36 % 6], g = level[i / 6 % 6], b = level[i % 6]
            return 0xFF000000 | (r << 16) | (g << 8) | b
        }
        let g = UInt32(8 + (min(index, 255) - 232) * 10)
        return 0xFF000000 | (g << 16) | (g << 8) | g
    }

    private func blank(_ from: Int, _ count: Int) {
        let b = reverse ? fg : bg
        var i = max(from, 0)
        while i < from + count && i < cells.count {
            cells[i] = Cell(ch: 0x20, fg: WmTerminal.defaultFg, bg: b, underline: false)
            i += 1
        }
    }

    private func eraseDisplay(_ how: Int) {
        let at = cursorY * width + cursorX
        switch how {
        case 0:
            blank(at, cells.count - at)
        case 1:
            blank(0, at + 1)
        default:
            blank(0, cells.count)
            pictures.removeAll()
        }
    }

    private func eraseLine(_ how: Int) {
        let row = cursorY * width
        switch how {
        case 0:
            blank(row + cursorX, width - cursorX)
        case 1:
            blank(row, cursorX + 1)
        default:
            blank(row, width)
        }
    }

    private func insertChars(_ count: Int) {
        let row = cursorY * width
        let c = min(count, width - cursorX)
        var x = width - 1
        while x >= cursorX + c {
            cells[row + x] = cells[row + x - c]
            x -= 1
        }
        blank(row + cursorX, c)
    }

    private func deleteChars(_ count: Int) {
        let row = cursorY * width
        let c = min(count, width - cursorX)
        var x = cursorX
        while x < width - c {
            cells[row + x] = cells[row + x + c]
            x += 1
        }
        blank(row + width - c, c)
    }

    private func scrollUp(_ count: Int) { scrollRegion(top, bottom, count) }

    private func scrollDown(_ count: Int) { scrollRegion(top, bottom, -count) }

    /// Moves rows top..bottom up by count (down when negative), blanking what opens up.
    private func scrollRegion(_ regionTop: Int, _ regionBottom: Int, _ count: Int) {
        let rows = regionBottom - regionTop + 1
        if count == 0 || rows <= 0 {
            return
        }
        let n = min(abs(count), rows)
        let moved = (rows - n) * width
        if count > 0 {
            let src = (regionTop + n) * width, dst = regionTop * width
            if moved > 0 {
                for k in 0..<moved {
                    cells[dst + k] = cells[src + k]
                }
            }
            blank((regionBottom - n + 1) * width, n * width)
        } else {
            let src = regionTop * width, dst = (regionTop + n) * width
            if moved > 0 {
                for k in stride(from: moved - 1, through: 0, by: -1) {
                    cells[dst + k] = cells[src + k]
                }
            }
            blank(regionTop * width, n * width)
        }
        pictures.removeAll()
    }

    private func dcsDone() {
        // ESC P <params> q <sixel data> ESC \ is a sixel picture; any other DCS is dropped
        guard let q = dcs.firstIndex(of: UInt8(ascii: "q")) else { return }
        for i in 0..<q {
            let c = dcs[i]
            if !((c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9")) || c == UInt8(ascii: ";")) {
                return
            }
        }
        guard let pic = Sixel.decode(Array(dcs[0..<q]), Array(dcs[(q + 1)...]), bg) else { return }
        pic.col = cursorX
        pic.row = cursorY
        if pictures.count >= 16 {
            pictures.removeFirst()
        }
        pictures.append(pic)
    }

    /// A sixel decoder: RGB and HLS colour registers, repeats, raster attributes, clear background.
    enum Sixel {
        static let maxPixels = 2048 * 2048

        static func decode(_ parameters: [UInt8], _ data: [UInt8], _ background: UInt32) -> Picture? {
            let p = String(decoding: parameters, as: UTF8.self).split(separator: ";", omittingEmptySubsequences: false)
            let clear = p.count > 1 && p[1] == "1"   // P2=1: unset pixels stay clear
            var palette = [UInt32](repeating: 0, count: 256)
            for i in 0..<16 {
                palette[i] = WmTerminal.cga[i]
            }
            var colour = palette[0]
            var x = 0, band = 0, w = 0, h = 0
            var set: [Int: UInt32] = [:]   // y * 4096 + x -> colour
            var i2 = 0

            func number(_ at: inout Int) -> Int {
                var v = 0
                while at < data.count && data[at] >= UInt8(ascii: "0") && data[at] <= UInt8(ascii: "9") {
                    v = min(v * 10 + Int(data[at] - UInt8(ascii: "0")), 99999)
                    at += 1
                }
                return v
            }

            func paint(_ bits: Int, _ count: Int) {
                var k = 0
                while k < count && x < 2048 {
                    for dy in 0..<6 where (bits & (1 << dy)) != 0 && band * 6 + dy < 2048 {
                        set[(band * 6 + dy) * 4096 + x] = colour
                    }
                    w = max(w, x + 1)
                    k += 1
                    x += 1
                }
                if bits != 0 {
                    h = max(h, min(band * 6 + 6, 2048))   // rows past 2048 aren't kept, so don't size for them
                }
            }

            while i2 < data.count {
                let c = data[i2]
                if c == UInt8(ascii: "\"") {
                    i2 += 1
                    for k in 0..<4 {   // Pan;Pad;Ph;Pv
                        let v = number(&i2)
                        if k == 2 { w = max(w, min(v, 2048)) }
                        if k == 3 { h = max(h, min(v, 2048)) }
                        if i2 < data.count && data[i2] == UInt8(ascii: ";") { i2 += 1 } else { break }
                    }
                } else if c == UInt8(ascii: "#") {
                    i2 += 1
                    let reg = number(&i2) & 255
                    if i2 < data.count && data[i2] == UInt8(ascii: ";") {
                        i2 += 1
                        let kind = number(&i2)
                        var v = [0, 0, 0]
                        for k in 0..<3 where i2 < data.count && data[i2] == UInt8(ascii: ";") {
                            i2 += 1
                            v[k] = number(&i2)
                        }
                        if kind == 1 {
                            palette[reg] = hls(v[0], v[1], v[2])
                        } else {
                            let r: UInt32 = pct(v[0]), g: UInt32 = pct(v[1]), b: UInt32 = pct(v[2])
                            palette[reg] = 0xFF000000 | (r << 16) | (g << 8) | b
                        }
                    }
                    colour = palette[reg]
                } else if c == UInt8(ascii: "!") {
                    i2 += 1
                    let count = min(number(&i2), 2048)
                    if i2 < data.count && data[i2] >= 63 && data[i2] <= 126 {
                        paint(Int(data[i2]) - 63, count)
                        i2 += 1
                    }
                } else if c == UInt8(ascii: "$") {
                    x = 0
                    i2 += 1
                } else if c == UInt8(ascii: "-") {
                    x = 0
                    band += 1
                    i2 += 1
                } else if c >= 63 && c <= 126 {
                    paint(Int(c) - 63, 1)
                    i2 += 1
                } else {
                    i2 += 1
                }

                if set.count > maxPixels {
                    WmSession.warnOnce("an oversized sixel picture")
                    return nil
                }
            }

            if w == 0 || h == 0 {
                return nil
            }
            var pixels = [UInt32](repeating: clear ? 0 : background, count: w * h)
            for (key, value) in set {
                let py = key / 4096, px = key % 4096
                if px < w && py < h {
                    pixels[py * w + px] = value
                }
            }
            let pic = Picture()
            pic.width = w
            pic.height = h
            pic.pixels = pixels
            return pic
        }

        private static func pct(_ v: Int) -> UInt32 { UInt32((min(v, 100) * 255 + 50) / 100) }

        private static func hls(_ hue: Int, _ light: Int, _ sat: Int) -> UInt32 {
            // Sixel HLS: hue 0-360 with blue at 0, lightness and saturation 0-100
            let hh = Double((hue + 240) % 360) / 360.0, l = Double(min(light, 100)) / 100.0
            let s = Double(min(sat, 100)) / 100.0
            let q = l < 0.5 ? l * (1 + s) : l + s - l * s, p = 2 * l - q
            func channel(_ t0: Double) -> Double {
                let t = (t0.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1)
                return t < 1 / 6.0 ? p + (q - p) * 6 * t : t < 0.5 ? q : t < 2 / 3.0 ? p + (q - p) * (2 / 3.0 - t) * 6 : p
            }
            let r = UInt32(channel(hh + 1 / 3.0) * 255 + 0.5), g = UInt32(channel(hh) * 255 + 0.5)
            let b = UInt32(channel(hh - 1 / 3.0) * 255 + 0.5)
            return 0xFF000000 | (r << 16) | (g << 8) | b
        }
    }
}
