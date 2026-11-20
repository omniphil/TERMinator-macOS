import AppKit
import os.log

private let sceneLogger = Logger(subsystem: "com.terminator.macos", category: "RainwireScene")

/// A little-endian u32 from v at o (0 past the end).
private func sceneLE32(_ v: [UInt8], _ o: Int) -> UInt32 {
    guard o >= 0, o + 4 <= v.count else { return 0 }
    return UInt32(v[o]) | UInt32(v[o + 1]) << 8 | UInt32(v[o + 2]) << 16 | UInt32(v[o + 3]) << 24
}

/// Scenes (1.1.6; Rainwire docs/SCENES.md, "Wire format v1"): any board screen sent as a tree of general blocks
/// (panels, rows, columns, scrolls, grids, text, images, character cells, buttons, fields, choices, checks, lists) that
/// this lays out and draws in the space a menu box goes, under the header art and over the status bar. The board sends
/// a Menu head with MuSMenu.screen = 2 (ScrScene), then Scene (colors, focus, how many block records), SceneBlocks,
/// SceneCells, SceneImage, Backdrop and Show; ScenePatch changes the tree later. It never decides anything: it says
/// which button was pressed (Press;id=), a field's Enter (Submit;id=;b64=), a choice's, check's or live field's change
/// (Change;id=;...), a list's selection and Enter (Select / Activate;id=;i=), any key nothing used (Key;vk=;key=;focus=)
/// and Esc (Back). Block kinds and properties a newer board sends are skipped by their lengths; an unknown kind keeps its
/// place and shows its alt text. Layout follows the spec's "Layout": sizes in units of the menu rows' text size,
/// rows and columns as flexbox (gap, padding, grow, shrink to min, align, self, justify, wrap).
///
/// Port of the Windows client's `Controls/RainwireScene.cs` (the master), nearly line for line: keep the two in step.
/// Written 2026-10-21 without a Mac to build on (uncompiled; see PORT_TO_MAC_LINUX.md, Scenes). macOS differences:
/// text is TextKit 1 (NSLayoutManager + NSTextContainer: wrapping, maximumNumberOfLines with a tail ellipsis, span
/// backgrounds from enumerateEnclosingRects) where Windows has FormattedText; a field's value is Characters (grapheme
/// clusters), not UTF-16 units, so P_MAX counts what the caller sees; opacity (disabled blocks, the fade-in) is a
/// CGContext transparency layer; the keyboard comes as NSEvents through `handleKey` (keys and typed characters in one),
/// paste is Cmd+V (Ctrl+V in a field too, as Windows); clicks act on the release, as the rest of this menu.
///
/// Scenes version 2 and 3 (Rainwire docs/SCENES_V2.md) are the second extension at the end of this file, a port of
/// Windows' `Controls/RainwireSceneV2.cs` (written 2026-10-22, uncompiled); this part calls into it from its layout,
/// drawing, keys and mouse code, as Windows' RainwireScene.cs does.
extension RainwireMenuView {
    /// The scene protocol version this draws: the scene= key in the Rainwire:Caps answer (OscExtras.appInfo).
    /// Version 2: the second extension below (Rainwire docs/SCENES_V2.md); 3: flat boxes, SF_BLEED, the board's pick
    /// and keys with fields (Messages, Files and MRC as their modules look); 4: MRC (P_HOVERBG, P_HOVERONLY, fn= and
    /// alt=1;ch= keys, shift=1); 5: Files (drops and drags, the viewer's whole scales, shared grid tiles, the board's
    /// scrolling, Click's Ctrl and Shift: the third extension at the end of this file); 6: scroll positions, dividers,
    /// click points, clocks, charts, sliders, canvases, the gadget engine (the fourth extension at the end of this file,
    /// and RainwireMenu.swift's widgets; Rainwire docs/SCENES_V6.md).
    static let sceneVersion = 6

    /// The block kinds this draws: the scenekinds= key ('+' between them; Rainwire scene.KindNames).
    static let sceneKinds =
        "panel+row+column+stack+scroll+grid+text+image+cells+rule+progress+spacer+icon+button+field+choice+check+list+item"
        + "+input+vlist+menu+popover+chip+drawer+viewer+split+chart+slider+canvas"

    /// Rainwire internal/scene/protocol.go, and the spec's limits ("Limits and security"): more and the scene is
    /// refused (Closed;error=), so the board falls back to text. Cells are capped here too: they become one bitmap of
    /// 8 x the font's height pixels a cell.
    enum Sn {
        static let sfFull: UInt8 = 0x01, sfOver: UInt8 = 0x02, sfBleed: UInt8 = 0x04   // SF_BLEED (version 2): the whole window
        static let bkPanel: UInt8 = 1, bkRow: UInt8 = 2, bkColumn: UInt8 = 3, bkStack: UInt8 = 4, bkScroll: UInt8 = 5,
                   bkGrid: UInt8 = 6, bkText: UInt8 = 10, bkImage: UInt8 = 11, bkCells: UInt8 = 12, bkRule: UInt8 = 13,
                   bkProgress: UInt8 = 14, bkSpacer: UInt8 = 15, bkIcon: UInt8 = 16, bkButton: UInt8 = 20, bkField: UInt8 = 21,
                   bkChoice: UInt8 = 22, bkCheck: UInt8 = 23, bkList: UInt8 = 24, bkItem: UInt8 = 25
        static let tU8: UInt8 = 1, tU16: UInt8 = 2, tU32: UInt8 = 3, tF32: UInt8 = 4, tStr: UInt8 = 5, tSpans: UInt8 = 6,
                   tStrs: UInt8 = 7, tF32s: UInt8 = 8
        static let pHidden: UInt8 = 1, pDisabled: UInt8 = 2, pTooltip: UInt8 = 3, pAlt: UInt8 = 4, pRole: UInt8 = 5,
                   pWidth: UInt8 = 6, pHeight: UInt8 = 7, pGrow: UInt8 = 8, pMinW: UInt8 = 9, pMinH: UInt8 = 10,
                   pFg: UInt8 = 11, pBg: UInt8 = 12, pPad: UInt8 = 13, pSelf: UInt8 = 14
        static let pGap: UInt8 = 32, pAlign: UInt8 = 33, pJustify: UInt8 = 34, pWrap: UInt8 = 35, pTitle: UInt8 = 36,
                   pAxis: UInt8 = 37, pFollow: UInt8 = 38, pColumns: UInt8 = 39, pTileW: UInt8 = 40, pTileH: UInt8 = 41, pAuto: UInt8 = 42
        static let pSpans: UInt8 = 64, pText: UInt8 = 65, pLines: UInt8 = 66, pTAlign: UInt8 = 67, pFit: UInt8 = 68,
                   pSmooth: UInt8 = 69, pCols: UInt8 = 70, pRows: UInt8 = 71, pValue: UInt8 = 72, pLabel: UInt8 = 73,
                   pKey: UInt8 = 74, pSubmit: UInt8 = 75, pPlace: UInt8 = 76, pMax: UInt8 = 77, pSecret: UInt8 = 78,
                   pMulti: UInt8 = 79, pLive: UInt8 = 80, pValueStr: UInt8 = 81, pOptions: UInt8 = 82,
                   pIndex: UInt8 = 83, pChecked: UInt8 = 84, pWidths: UInt8 = 85, pHeaders: UInt8 = 86,
                   pCellText: UInt8 = 87, pIFlags: UInt8 = 88, pIcon: UInt8 = 89
        static let aStart = 0, aCenter = 1, aEnd = 2, aStretch = 3
        static let jStart = 0, jCenter = 1, jEnd = 2, jBetween = 3
        static let fitContain = 0, fitCover = 1, fitStretch = 2, fitNone = 3
        static let ifBold = 1, ifDim = 2, ifHeading = 4
        static let opSet: UInt8 = 1, opReplace: UInt8 = 2, opRemove: UInt8 = 3, opInsert: UInt8 = 4, opFocus: UInt8 = 5
        static let rText = 0, rTitle = 1, rHeading = 2, rDim = 3, rAccent = 4, rMono = 5, rSmall = 6, rGood = 7,
                   rBad = 8, rPanel = 9, rButton = 10, rHot = 11
        static let maxBlocks = 5000, maxDepth = 32, maxBytes = 2 << 20
        static let vMaxRows: UInt32 = 1_000_000   // a list's rows at most (the board's longest, Files', is 37,440)
        static let cellsMaxCols = 400, cellsMaxRows = 2000, cellsMax = 65536, fieldMulti = 4000
        static let textInf: CGFloat = 1e7   // an unconstrained text container's width

        // ---- version 2 (Rainwire internal/scene/protocol.go; the second extension below) ----
        static let bkInput: UInt8 = 26, bkVList: UInt8 = 27, bkMenu: UInt8 = 28, bkPopover: UInt8 = 29, bkChip: UInt8 = 30,
                   bkDrawer: UInt8 = 31, bkViewer: UInt8 = 32
        static let pHoverShow: UInt8 = 90, pHoverRoot: UInt8 = 91, pHoverAsk: UInt8 = 92, pAnim: UInt8 = 93, pGrad: UInt8 = 94,
                   pDrift: UInt8 = 95, pGlow: UInt8 = 96, pBar: UInt8 = 97, pEvents: UInt8 = 98, pSelectable: UInt8 = 99,
                   pWMin: UInt8 = 100, pWMax: UInt8 = 101, pPane: UInt8 = 102, pDrop: UInt8 = 103, pDrag: UInt8 = 104,
                   pMaxBytes: UInt8 = 105, pPipes: UInt8 = 106, pCounter: UInt8 = 107, pWarn: UInt8 = 108,
                   pComplete: UInt8 = 109, pTrigger: UInt8 = 110, pHistory: UInt8 = 111, pPaste: UInt8 = 112,
                   pKeys: UInt8 = 113, pDebounce: UInt8 = 114, pAutosave: UInt8 = 115, pWrapCols: UInt8 = 116,
                   pMaxLines: UInt8 = 117, pMono: UInt8 = 118, pTotal: UInt8 = 119, pRowH: UInt8 = 120, pKeep: UInt8 = 121,
                   pNewLabel: UInt8 = 122, pOlder: UInt8 = 123, pSeen: UInt8 = 124, pSelect: UInt8 = 125,
                   pSettle: UInt8 = 126, pGroup: UInt8 = 127, pSort: UInt8 = 128, pSortDir: UInt8 = 129,
                   pDivider: UInt8 = 130, pContext: UInt8 = 131, pAnchor: UInt8 = 132, pSide: UInt8 = 133,
                   pMenuBtn: UInt8 = 134, pReport: UInt8 = 135, pClose: UInt8 = 136, pCount: UInt8 = 137, pOn: UInt8 = 138,
                   pOpens: UInt8 = 139, pScale: UInt8 = 141, pFont: UInt8 = 142, pAnimMs: UInt8 = 143, pAsset: UInt8 = 144
        // version 3: a row, column or stack's flat box (Messages, Files and MRC as the modules draw them), and a row
        // child's width as a share of the row, between lp limits (the modules' clampf(LW * f, lo, hi))
        static let pRadius: UInt8 = 145, pStroke: UInt8 = 146, pFillA: UInt8 = 147
        static let pFrac: UInt8 = 148, pFracMin: UInt8 = 149, pFracMax: UInt8 = 150
        // version 4 (MRC): a flat box's fill under the pointer; a block shown only then
        static let pHoverBg: UInt8 = 151, pHoverOnly: UInt8 = 152
        // version 5 (Files): a viewer's width-only fit and largest scale, a grid's shared tiles, the board's scrolling
        static let pFitW: UInt8 = 153, pScaleMax: UInt8 = 154, pTileMin: UInt8 = 155, pTileRatio: UInt8 = 156,
                   pScrollBy: UInt8 = 157
        static let opRows: UInt8 = 6, opScrollTo: UInt8 = 7, opAnimate: UInt8 = 8
        static let rowsSet: UInt8 = 0, rowsInsert: UInt8 = 1, rowsRemove: UInt8 = 2
        static let animSlide: UInt8 = 1, animGlow: UInt8 = 2, animFlash: UInt8 = 3, animPop: UInt8 = 4, animFade: UInt8 = 5
        static let evClick = 1, evDouble = 2, evTriple = 4, evRight = 8, evLong = 16
        static let fxLink: UInt8 = 8
        static let sideBelow = 0, sideAbove = 1, sideRight = 2, sideLeft = 3

        // ---- version 6 (Rainwire internal/scene/v6.go; the fourth extension below) ----
        static let bkSplit: UInt8 = 33, bkChart: UInt8 = 34, bkSlider: UInt8 = 35, bkCanvas: UInt8 = 36
        static let pReportScroll: UInt8 = 158, pScrollPos: UInt8 = 159, pSplitAt: UInt8 = 160, pSplitMin: UInt8 = 161,
                   pClock: UInt8 = 162, pAt: UInt8 = 163, pChart: UInt8 = 164, pData: UInt8 = 165, pData2: UInt8 = 166,
                   pLabels: UInt8 = 167, pMinV: UInt8 = 168, pMaxV: UInt8 = 169, pStep: UInt8 = 170, pSpin: UInt8 = 171,
                   pViewW: UInt8 = 172, pViewH: UInt8 = 173, pUnit: UInt8 = 174, pAxes: UInt8 = 175
        static let evMiddle = 0x20, evMove = 0x40, evWheel = 0x80
        static let sfSize: UInt8 = 0x08
        static let clockTime = 1, clockTimeSec = 2, clockDate = 3, clockDateTime = 4, clockCountdown = 5, clockElapsed = 6,
                   clockAgo = 7, clockAt = 8
        static let chartLine = 0, chartBar = 1, chartArea = 2, chartSpark = 3
        static let axesLabels = 1, axesGrid = 2, axesTip = 4
        static let drawReplace: UInt8 = 0, drawAppend: UInt8 = 1
        static let dTag: UInt8 = 1, dLine: UInt8 = 2, dRect: UInt8 = 3, dEllipse: UInt8 = 4, dPoly: UInt8 = 5, dText: UInt8 = 6,
                   dImage: UInt8 = 7, dClear: UInt8 = 8
        static let canvasMaxOps = 20000, canvasMaxBytes = 1 << 20
    }

    /// The Scene packet's color slots (C_*); a newer board's extra slots are skipped.
    enum Sc: Int, CaseIterable {
        case bg, panel, border, title, text, dim, accent, accent2, buttonBg, buttonFg, buttonHot, fieldBg, fieldFg, focus,
             selBg, selFg, good, bad
    }

    /// A character cell: a CP437 code and its colors (0x00RRGGBB; `none`: not set).
    struct SCell {
        var ch: UInt8
        var fg: UInt32
        var bg: UInt32
    }

    /// A text block laid out once (TextKit 1): the storage, its layout manager and container, and the size it took.
    final class SText {
        let storage: NSTextStorage
        let layout = NSLayoutManager()
        let box: NSTextContainer
        let size: CGSize

        init(_ s: NSAttributedString, width: CGFloat, lines: Int) {
            storage = NSTextStorage(attributedString: s)
            box = NSTextContainer(size: NSSize(width: width, height: RainwireMenuView.Sn.textInf))
            box.lineFragmentPadding = 0
            box.maximumNumberOfLines = max(lines, 0)
            box.lineBreakMode = lines > 0 ? .byTruncatingTail : .byWordWrapping   // the last line's: with an ellipsis
            layout.addTextContainer(box)
            storage.addLayoutManager(layout)
            layout.ensureLayout(for: box)
            let used = layout.usedRect(for: box)
            size = CGSize(width: used.maxX, height: used.height)
        }

        var glyphs: NSRange { layout.glyphRange(for: box) }
    }

    /// One block: its kind, id, parent and properties (only known keys of the right type are kept), its children in
    /// order, what the caller changed (a field's text, a choice's or list's index, a check), and where the last layout
    /// put it.
    final class SBlock {
        var kind: UInt8 = 0
        var id: UInt16 = 0, parentId: UInt16 = 0
        weak var parent: SBlock?
        var depth = 0, bytes = 0
        var props: [UInt8: [UInt8]] = [:]
        var kids: [SBlock] = []

        // the caller's side of a control
        var value: [Character] = []
        var cur = 0, index = 0
        var on = false

        // a scroll's, a list's or a multi-line field's place
        var scroll: CGFloat = 0, scrollMax: CGFloat = 0, view: CGFloat = 0
        var atEnd = true, showSel = true
        var autoHold = Date.distantPast   // P_AUTO: still until then (at the top, at the end, after the wheel)
        var autoEnded = false             // P_AUTO: it reached the end and holds there before starting over

        // version 2 (the second extension below)
        var rows: [SBlock?]?                         // a vlist's rows by index (nil: not here yet)
        var rowY: [CGFloat] = [], rowH: [CGFloat] = []   // a vlist's rows' places and heights, as last laid out
        var rowsW: CGFloat = -1                      // ... for this width
        var anchorRow = -1                           // a vlist's first row in view, kept still when rows come above it
        var anchorOff: CGFloat = 0                   // ... its distance from the view's top
        var newCount = 0                             // a vlist's rows added at the end while scrolled back
        var sel = Set<Int>()                         // a vlist's selected rows
        var selAnchor = -1, selCur = -1              // ... the range anchor and the current row
        var selAt = Date.distantPast, seenAt = Date.distantPast   // ... when the selection, the view last moved (settle)
        var selSent = true, seenSent = true          // ... reported since
        var asked = (from: -1, to: -1)               // a vlist's last Rows request
        var askedAt = Date.distantPast, olderAt = Date.distantPast
        var anim: UInt8 = 0                          // P_ANIM / OP_ANIMATE playing, and when it started
        var animAt = Date.distantPast
        var animMs: Double = 0
        var closed = false                           // a pop-up or drawer the caller closed (until the board sends it again)
        var open = false                             // a context menu or a button's menu the caller opened, or a drawer
        var openAt: CGPoint?                         // ... where (a context menu: the pointer)
        var history: [[Character]] = []              // an input's submitted values (P_HISTORY), newest last
        var histAt = -1                              // ... where Up/Down are; -1 the draft
        var draft: [Character] = []
        var changedAt = Date.distantPast, savedAt = Date.distantPast   // an input's last edit, and last autosave
        var changePending = false                    // ... a debounced Change not sent yet
        var completeAt = -1                          // ... where the word being completed starts

        // a cells block's rows, and the picture they're painted into
        var cells: [[SCell]] = []
        var cellsImage: NSImage?
        var cellsDirty = true, cellsSmooth = false

        var image: NSImage?
        var imageW = 0, imageH = 0   // its pixels

        // version 6 (the fourth extension below)
        var splitAt: CGFloat = -1                    // a split's share the caller dragged it to (-1: the board's)
        var splitBar = CGRect.zero                   // ... its divider, as laid out
        var repCur: (pos: CGFloat, max: CGFloat, view: CGFloat) = (.nan, 0, 0)   // P_REPORTSCROLL: the view now
        var repAt = Date.distantPast                 // ... when it last moved
        var repPending = false                       // ... a Scrolled not sent yet
        var clockText = ""                           // P_CLOCK: the text it shows now
        var timerFor: UInt32 = 0                     // ... the P_AT its Timer was sent for
        var numV: CGFloat = .nan                     // a slider's value as the caller has it (NaN: P_VALUE)
        var numSent: CGFloat = .nan                  // ... the last one sent
        var numAt = Date.distantPast                 // ... when
        var drawOps: [(op: UInt8, pay: [UInt8])]?    // a canvas's commands (SceneDraw)
        var drawBytes = 0, drawAssets = -1           // ... their size; the assets there were when it was built
        var drawCache: [SCanvasItem]?                // ... built once, in canvas coordinates
        var drawTags: [(tag: Int, path: CGPath)]?    // ... its tagged shapes' hit areas, topmost last
        var picRect = CGRect.zero                    // where a cells block's, image's, viewer's or canvas's picture was drawn
        var plot = CGRect.zero                       // a chart's plot area, as drawn
        var vLines: [(start: Int, end: Int)]?        // a multi-line field's or input's drawn (wrapped) lines
        var wrapV: [Character] = []                  // ... the text, width and font they were wrapped for
        var wrapW: CGFloat = -1
        var wrapFace = ""

        // the layout: the pass that placed it (an older one: hidden now), its box, inside its padding, what of it shows
        var pass = -1
        var box = CGRect.zero, inner = CGRect.zero, clip = CGRect.zero
        var off = false   // disabled, or inside a disabled block
        var mGen = -1, mInfGen = -1, nGen = -1, ftGen = -1, ftNatGen = -1
        var mw: CGFloat = 0, nw: CGFloat = 0, ftW: CGFloat = 0, nMin: CGFloat = 0
        var mSize = CGSize.zero, mInf = CGSize.zero
        var ft: SText?, ftNat: SText?
        var runs: [(start: Int, len: Int, span: Span)] = []   // a text's spans, UTF-16 ranges in its string
        var links: [(start: Int, len: Int, url: String)] = []  // version 2: its link spans, UTF-16 ranges
        var hits: [(rect: CGRect, i: Int)] = []               // drawn this frame: a choice's pills, a list's rows
        var textX: CGFloat = 0, textY: CGFloat = 0, lineH: CGFloat = 0   // a field's text origin and line, this frame

        func has(_ k: UInt8) -> Bool { props[k] != nil }

        func num(_ k: UInt8, _ def: Int = 0) -> Int {
            guard let v = props[k] else { return def }
            switch v.count {
            case 1: return Int(v[0])
            case 2: return Int(v[0]) | Int(v[1]) << 8
            case 4: return Int(sceneLE32(v, 0) & 0x7FFF_FFFF)
            default: return def
            }
        }

        func u32(_ k: UInt8) -> UInt32 {
            guard let v = props[k], v.count == 4 else { return RainwireMenuView.none }
            return sceneLE32(v, 0)
        }

        func real(_ k: UInt8, _ def: CGFloat = 0) -> CGFloat {
            guard let v = props[k], v.count == 4 else { return def }
            let f = Float(bitPattern: sceneLE32(v, 0))
            return f.isFinite ? CGFloat(f) : def
        }

        func flag(_ k: UInt8) -> Bool { num(k) != 0 }

        func str(_ k: UInt8) -> String {
            guard let v = props[k] else { return "" }
            return String(decoding: v, as: UTF8.self)
        }

        func strs(_ k: UInt8) -> [String] {
            guard let v = props[k], !v.isEmpty else { return [] }
            var l: [String] = []
            var o = 1
            for _ in 0..<Int(v[0]) {
                guard o < v.count else { break }
                let n = Int(v[o])
                o += 1
                if o + n > v.count {
                    break
                }
                l.append(String(decoding: v[o..<(o + n)], as: UTF8.self))
                o += n
            }
            return l
        }

        func f32s(_ k: UInt8) -> [CGFloat] {
            guard let v = props[k], !v.isEmpty else { return [] }
            let n = min(Int(v[0]), (v.count - 1) / 4)
            return (0..<n).map { i in
                let f = Float(bitPattern: sceneLE32(v, 1 + 4 * i))
                return f.isFinite ? CGFloat(f) : 0
            }
        }

        /// Spans, their colors with any high byte (0xFF000000: not set) as `none`, as the menus' spans keep them.
        func spans(_ k: UInt8) -> [Span] {
            guard let v = props[k], !v.isEmpty else { return [] }
            var l: [Span] = []
            var o = 1
            for _ in 0..<Int(v[0]) {
                guard o + 10 <= v.count else { break }
                let fg = sceneLE32(v, o), bg = sceneLE32(v, o + 4)
                let fx = v[o + 8]
                let n = min(Int(v[o + 9]), v.count - o - 10)
                let none = RainwireMenuView.none
                l.append(Span(fg: fg & 0xFF00_0000 != 0 ? none : fg, bg: bg & 0xFF00_0000 != 0 ? none : bg, fx: fx,
                              text: String(decoding: v[(o + 10)..<(o + 10 + n)], as: UTF8.self)))
                o += 10 + n
            }
            return l
        }
    }

    /// A whole scene: its head, the tree under `top` (a column of the roots), and its last layout.
    final class SceneTree {
        var flags: UInt8 = 0
        var focus: UInt16 = 0
        var colors = [UInt32](repeating: 0, count: Sc.allCases.count)
        var want = 0, got = 0, count = 0, bytes = 0, pass = 0
        let top: SBlock = {
            let b = SBlock()
            b.kind = Sn.bkColumn
            return b
        }()
        var byId: [UInt16: SBlock] = [:]
        var under: SceneTree?          // SF_OVER: the scene it's over, drawn dimmed behind it
        var order: [SBlock] = []       // the blocks the layout placed, in the tree's order
        var scroll: CGFloat = 0, scrollMax: CGFloat = 0   // the whole scene's, when it can't fit even shrunk
        var space = CGRect.zero
        var laidSpace = CGRect.null, laidU: CGFloat = 0, laidGen = -1, laidArr = -1
        var autoTick = Date()            // P_AUTO's last step
        var pops: [SBlock] = []          // pop-ups and drawers open, bottom first (the second extension below)
        var bars: [SBar] = []            // version 6: the scroll bars drawn this frame, for dragging (the fourth extension)
        var sizeCur: (w: CGFloat, h: CGFloat) = (-1, -1)   // version 6: SF_SIZE, the space now and when it changed
        var sizeAt = Date.distantPast
        var sizePending = false
    }

    // ================================================================
    // Messages from the board
    // ================================================================

    private static func sU8(_ p: [UInt8], _ o: Int) -> Int { o >= 0 && o < p.count ? Int(p[o]) : 0 }
    private static func sU16(_ p: [UInt8], _ o: Int) -> Int { sU8(p, o) | sU8(p, o + 1) << 8 }
    private static func sU32(_ p: [UInt8], _ o: Int) -> UInt32 {
        UInt32(sU8(p, o)) | UInt32(sU8(p, o + 1)) << 8 | UInt32(sU8(p, o + 2)) << 16 | UInt32(sU8(p, o + 3)) << 24
    }

    /// The type each known property must have (anything else is ignored); 0: a key this doesn't know.
    private static func sKeyType(_ k: UInt8) -> UInt8 {
        switch k {
        case Sn.pHidden, Sn.pDisabled, Sn.pRole, Sn.pSelf, Sn.pAlign, Sn.pJustify, Sn.pWrap, Sn.pAxis, Sn.pFollow,
             Sn.pColumns, Sn.pLines, Sn.pTAlign, Sn.pFit, Sn.pSmooth, Sn.pSubmit, Sn.pSecret, Sn.pMulti, Sn.pLive,
             Sn.pChecked, Sn.pIFlags, Sn.pAuto, Sn.pIcon:
            return Sn.tU8
        case Sn.pCols, Sn.pRows, Sn.pMax, Sn.pIndex: return Sn.tU16
        case Sn.pFg, Sn.pBg, Sn.pKey: return Sn.tU32
        case Sn.pWidth, Sn.pHeight, Sn.pGrow, Sn.pMinW, Sn.pMinH, Sn.pPad, Sn.pGap, Sn.pTileW, Sn.pTileH, Sn.pValue:
            return Sn.tF32
        case Sn.pTooltip, Sn.pAlt, Sn.pTitle, Sn.pText, Sn.pLabel, Sn.pPlace, Sn.pValueStr: return Sn.tStr
        case Sn.pSpans: return Sn.tSpans
        case Sn.pOptions, Sn.pHeaders, Sn.pCellText: return Sn.tStrs
        case Sn.pWidths: return Sn.tF32s
        default: return sKeyTypeV2(k)   // version 2's (the second extension below)
        }
    }

    /// Properties from p[o..<end]: repeated u8 key, u8 type, u16 len, value. Unknown keys and known ones of another
    /// type (or the wrong length) are skipped by their length; false when the list runs past its end.
    @discardableResult
    private static func sReadProps(_ p: [UInt8], _ start: Int, _ end0: Int, _ into: inout [UInt8: [UInt8]]) -> Bool {
        let end = min(end0, p.count)
        var o = start
        while o < end {
            if o + 4 > end {
                return false
            }
            let k = p[o], t = p[o + 1]
            let len = sU16(p, o + 2)
            o += 4
            if o + len > end {
                return false
            }
            let want = sKeyType(k)
            let fits: Bool
            switch t {
            case Sn.tU8: fits = len == 1
            case Sn.tU16: fits = len == 2
            case Sn.tU32, Sn.tF32: fits = len == 4
            default: fits = true
            }
            if want != 0 && want == t && fits {
                into[k] = Array(p[o..<(o + len)])
            }
            o += len
        }
        return true
    }

    /// n block records from p[o..<end] (u8 kind, u16 id, u16 parent, u16 len, properties); a short one ends it.
    private static func sReadRecords(_ p: [UInt8], _ start: Int, _ end0: Int, _ n: Int) -> [SBlock] {
        let end = min(end0, p.count)
        var o = start
        var list: [SBlock] = []
        for _ in 0..<max(n, 0) {
            if o + 7 > end {
                break
            }
            let b = SBlock()
            b.kind = p[o]
            b.id = UInt16(sU16(p, o + 1))
            b.parentId = UInt16(sU16(p, o + 3))
            let len = sU16(p, o + 5)
            o += 7
            if o + len > end || !sReadProps(p, o, o + len, &b.props) {
                break
            }
            b.bytes = len + 7
            o += len
            list.append(b)
        }
        return list
    }

    /// A string as a field's value: Characters, line breaks as "\n" only.
    private static func sChars(_ s: String) -> [Character] {
        Array(s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
    }

    /// The colors until the Scene packet says (a board that sends fewer slots): the menu's.
    private func sceneDefaultColors(_ c: inout [UInt32]) {
        c[Sc.bg.rawValue] = mc(.bg)
        c[Sc.panel.rawValue] = mc(.menuBg)
        c[Sc.border.rawValue] = mc(.menuBorder)
        c[Sc.title.rawValue] = mc(.panelTitle)
        c[Sc.text.rawValue] = mc(.text)
        c[Sc.dim.rawValue] = mc(.dim)
        c[Sc.accent.rawValue] = mc(.accent)
        c[Sc.accent2.rawValue] = mc(.accent2)
        c[Sc.buttonBg.rawValue] = mc(.menuBg)
        c[Sc.buttonFg.rawValue] = mc(.menuLabel)
        c[Sc.buttonHot.rawValue] = mc(.selBg)
        c[Sc.fieldBg.rawValue] = mc(.menuBg)
        c[Sc.fieldFg.rawValue] = mc(.text)
        c[Sc.focus.rawValue] = mc(.selMarker)
        c[Sc.selBg.rawValue] = mc(.selBg)
        c[Sc.selFg.rawValue] = mc(.selFg)
        c[Sc.good.rawValue] = 0x55_FF55
        c[Sc.bad.rawValue] = 0xFF_5555
    }

    /// A scene's head (Scene, type 19): version, flags, the block records to come, the block focused first, the colors
    /// by slot, the status bar's title. The scene shows once every record has come.
    func onScene(_ p: [UInt8]) {
        guard isScene, p.count >= 12 else { return }   // a scene only follows its Menu head
        let (s, title) = sceneHeadRead(p)
        if !title.isEmpty {
            head.title = title
        }
        waiting = false
        complete = false
        cellFont = nil          // the terminal's font may have changed since the last scene
        cellFontTried = false
        if s.want > Sn.maxBlocks {
            sceneTooBig()
            return
        }
        if s.flags & Sn.sfOver != 0, let prev = scenePrev {
            s.under = prev   // a pop-up over the scene before it
            prev.under = nil
        }
        scenePrev = nil
        scene = s
        sceneGen += 1
        if s.want == 0 {
            sceneReady()
        }
    }

    /// A Scene packet's tree, empty: its flags, how many records come, the block focused first, its colors; and its
    /// title. p is at least 12 bytes.
    func sceneHeadRead(_ p: [UInt8]) -> (SceneTree, String) {
        let s = SceneTree()
        s.flags = p[5]
        s.want = Self.sU16(p, 6)
        s.focus = UInt16(Self.sU16(p, 8))
        let colors = Int(p[10]), titleLen = Int(p[11])
        var o = 12
        sceneDefaultColors(&s.colors)
        for i in 0..<colors {
            guard o + 4 <= p.count else { break }
            if i < s.colors.count {
                s.colors[i] = Self.sU32(p, o) & 0xFF_FFFF
            }
            o += 4
        }
        let n = max(0, min(titleLen, p.count - o))
        return (s, o <= p.count ? String(decoding: p[o..<(o + n)], as: UTF8.self) : "")
    }

    /// Block records (SceneBlocks, type 20), in order: each goes under its parent (one that came before), or is a root
    /// (parent 0); a record whose parent isn't there is left out.
    func onSceneBlocks(_ p: [UInt8]) {
        guard let s = scene, isScene else { return }
        let r = Self.sceneBlocksInto(s, p)
        if r < 0 {
            sceneTooBig()
        } else if r > 0 {
            sceneReady()
        }
    }

    /// SceneBlocks into tree s (a screen's or a gadget's): -1 over the limits, 1 when every record has come, else 0.
    static func sceneBlocksInto(_ s: SceneTree, _ p: [UInt8]) -> Int {
        guard p.count >= 8 else { return 0 }
        let first = sU16(p, 4), count = sU16(p, 6)
        guard first == s.got, s.got < s.want else { return 0 }   // out of order: a stale scene's
        for b in sReadRecords(p, 8, p.count, min(count, s.want - s.got)) {
            if !sceneAdd(s, b, -1) {
                return -1
            }
        }
        s.got = min(s.got + count, s.want)
        return s.got >= s.want ? 1 : 0
    }

    /// Character cells (SceneCells, type 21) for a cells block: rows from firstRow, each runs of one color pair (u16 len,
    /// u32 fg, u32 bg, len CP437 codes). A piece arriving, or rows of it changing.
    func onSceneCells(_ p: [UInt8]) {
        if let s = scene, isScene {
            sceneCellsInto(s, p)
        }
    }

    /// SceneCells into tree s (a screen's or a gadget's).
    func sceneCellsInto(_ s: SceneTree, _ p: [UInt8]) {
        guard p.count >= 10 else { return }
        let first = Self.sU16(p, 6), rows = Self.sU16(p, 8)
        var o = 10
        var target = s.byId[UInt16(Self.sU16(p, 4))]
        if target?.kind != Sn.bkCells {
            target = nil
        }
        let before = target.map { Self.sCellDims($0) }
        for r in 0..<rows {
            guard o + 2 <= p.count else { break }
            let runs = Self.sU16(p, o)
            o += 2
            var row: [SCell] = []
            for _ in 0..<runs {
                guard o + 10 <= p.count else { break }
                var n = Self.sU16(p, o)
                let fg = Self.sU32(p, o + 2), bg = Self.sU32(p, o + 6)
                o += 10
                n = min(n, p.count - o)
                for k in 0..<n where row.count < Sn.cellsMaxCols {
                    row.append(SCell(ch: p[o + k], fg: fg, bg: bg))
                }
                o += n
            }
            let at = first + r
            guard let b = target, at < Sn.cellsMaxRows else { continue }
            while b.cells.count <= at {
                b.cells.append([])
            }
            b.cells[at] = row
        }
        guard let b = target else { return }
        b.cellsDirty = true
        if let before = before, Self.sCellDims(b) != before {
            sceneGen += 1   // its size changed: lay out again
        }
        redraw()
    }

    /// An image block's picture (SceneImage, type 22): the picture-cache file the message's hdr= named.
    func onSceneImage(_ p: [UInt8], _ path: String?) {
        if let s = scene, isScene {
            sceneImageInto(s, p, path)
        }
    }

    /// SceneImage into tree s (a screen's or a gadget's).
    func sceneImageInto(_ s: SceneTree, _ p: [UInt8], _ path: String?) {
        guard p.count >= 6 else { return }
        guard let b = s.byId[UInt16(Self.sU16(p, 4))], b.kind == Sn.bkImage else { return }
        b.image = path.flatMap { sceneLoadImage($0) }
        b.imageW = 0
        b.imageH = 0
        if let img = b.image {
            for rep in img.representations where rep.pixelsWide > 0 && rep.pixelsHigh > 0 {
                b.imageW = rep.pixelsWide
                b.imageH = rep.pixelsHigh
                break
            }
            if b.imageW <= 0 || b.imageH <= 0 {
                b.imageW = Int(img.size.width)
                b.imageH = Int(img.size.height)
            }
        }
        sceneGen += 1
        redraw()
    }

    /// A picture from the cache, kept while the scene's blocks may name it again. Read whole (Data), so the cache
    /// file isn't held (the board may store it again), as the header is.
    private func sceneLoadImage(_ path: String) -> NSImage? {
        if let had = sceneImages[path] {
            return had
        }
        let url = URL(fileURLWithPath: (path as NSString).standardizingPath)
        guard let data = try? Data(contentsOf: url), let image = NSImage(data: data) else {
            sceneLogger.warning("RainwireScene: image \(path, privacy: .public) couldn't load")
            return nil
        }
        if sceneImages.count >= 64 {
            sceneImages.removeAll()
        }
        sceneImages[path] = image
        return image
    }

    /// Changes to the scene (ScenePatch, type 23): set, replace, remove, insert, focus; the board has answered, so the
    /// caller may act again.
    func onScenePatch(_ p: [UInt8]) {
        guard let s = scene, isScene, p.count >= 6 else { return }
        waiting = false
        scenePressed = 0
        if !scenePatchInto(s, p) {
            sceneTooBig()
        }
    }

    /// ScenePatch into tree s (a screen's or a gadget's); false when it takes s over the limits.
    func scenePatchInto(_ s: SceneTree, _ p: [UInt8]) -> Bool {
        guard p.count >= 6 else { return true }
        let n = Self.sU16(p, 4)
        var o = 6
        for _ in 0..<n {
            guard o + 5 <= p.count else { break }
            let op = p[o]
            let id = UInt16(Self.sU16(p, o + 1))
            let len = Self.sU16(p, o + 3)
            o += 5
            if o + len > p.count {
                break
            }
            if !scenePatchOne(s, op, id, p, o, len) {
                return false
            }
            o += len
        }
        sceneGen += 1
        redraw()
        return true
    }

    /// One patch record; false when it takes the scene over its limits. Unknown ops are skipped.
    private func scenePatchOne(_ s: SceneTree, _ op: UInt8, _ id: UInt16, _ p: [UInt8], _ o: Int, _ len: Int) -> Bool {
        let end = o + len
        switch op {
        case Sn.opSet:
            guard let b = s.byId[id] else { return true }
            var props: [UInt8: [UInt8]] = [:]
            Self.sReadProps(p, o, end, &props)
            for (k, v) in props {
                let was = b.props[k].map { $0.count + 4 } ?? 0
                b.props[k] = v
                b.bytes += v.count + 4 - was
                s.bytes += v.count + 4 - was
            }
            if props[Sn.pValueStr] != nil {
                b.value = Self.sChars(b.str(Sn.pValueStr))
                b.cur = b.value.count
            }
            if props[Sn.pIndex] != nil {
                b.index = b.num(Sn.pIndex)
                b.showSel = true
                if b.kind == Sn.bkVList {
                    Self.vSetSel(b, b.index)   // version 2: the board picks a row (Messages' click opens it)
                }
            }
            if props[Sn.pChecked] != nil {
                b.on = b.flag(Sn.pChecked)
            }
            if props[Sn.pCols] != nil || props[Sn.pRows] != nil {
                b.cellsDirty = true
            }
            if let by = props[Sn.pScrollBy] {   // version 5: the board's keys (the third extension)
                sScrollBy(s, b, by)
            }
            if props[Sn.pSplitAt] != nil {      // version 6: the board moves a divider
                b.splitAt = -1
            }
            if props[Sn.pValue] != nil {        // ... or a slider
                b.numV = .nan
            }
            if props[Sn.pData] != nil || props[Sn.pData2] != nil {
                b.plot = .zero
            }
            return s.bytes <= Sn.maxBytes
        case Sn.opRemove:
            if let gone = s.byId[id] {
                Self.sceneRemove(s, gone)
            }
            return true
        case Sn.opReplace, Sn.opInsert:
            var q = o, index = -1
            if op == Sn.opInsert {
                if q + 2 > end {
                    return true
                }
                let ix = Self.sU16(p, q)
                if ix != 0xFFFF {
                    index = ix
                }
                q += 2
            }
            if q + 2 > end {
                return true
            }
            let bs = Self.sReadRecords(p, q + 2, end, Self.sU16(p, q))
            guard let first = bs.first else { return true }
            if op == Sn.opReplace {
                guard let old = s.byId[id] else { return true }
                let par = old.parent ?? s.top
                first.parentId = par === s.top ? 0 : par.id
                index = par.kids.firstIndex(where: { $0 === old }) ?? -1
                Self.sceneRemove(s, old)
            } else {
                first.parentId = id
            }
            if !Self.sceneAdd(s, first, index) {
                return false
            }
            for b in bs.dropFirst() {
                if !Self.sceneAdd(s, b, -1) {
                    return false
                }
            }
            return true
        case Sn.opFocus:
            s.focus = id
            if let f = s.byId[id] {
                sceneIntoView(s, f)
            }
            return true
        case Sn.opRows, Sn.opScrollTo, Sn.opAnimate:
            return scenePatchV2(s, op, id, p, o, len)   // version 2 (the second extension below)
        default:
            return true
        }
    }

    /// Puts b under its parent at index (-1: last); false when the scene goes over its limits.
    private static func sceneAdd(_ s: SceneTree, _ b: SBlock, _ index: Int) -> Bool {
        var par = s.top
        if b.parentId != 0 {
            guard let found = s.byId[b.parentId] else { return true }   // no such parent: left out
            par = found
        }
        b.parent = par
        b.depth = par === s.top ? 1 : par.depth + 1
        if b.depth > Sn.maxDepth {
            return false
        }
        if index < 0 || index >= par.kids.count {
            par.kids.append(b)
        } else {
            par.kids.insert(b, at: index)
        }
        if b.id != 0 {
            s.byId[b.id] = b
        }
        s.count += 1
        s.bytes += b.bytes
        b.value = sChars(b.str(Sn.pValueStr))
        b.cur = b.value.count
        b.index = b.num(Sn.pIndex)
        if b.kind == Sn.bkVList && b.has(Sn.pIndex) {
            vSetSel(b, b.index)
        }
        b.on = b.flag(Sn.pChecked)
        return s.count <= Sn.maxBlocks && s.bytes <= Sn.maxBytes
    }

    /// Takes b and its descendants out of the tree.
    private static func sceneRemove(_ s: SceneTree, _ b: SBlock) {
        func drop(_ x: SBlock) {
            if x.id != 0, let y = s.byId[x.id], y === x {
                s.byId[x.id] = nil
            }
            s.count -= 1
            s.bytes -= x.bytes
            for k in x.kids {
                drop(k)
            }
        }
        drop(b)
        if let par = b.parent, let i = par.kids.firstIndex(where: { $0 === b }) {
            par.kids.remove(at: i)
        }
    }

    private func sceneReady() {
        caretAt = Date()
        sceneGen += 1
        needsLayout = true   // SF_BLEED: the header picture goes (or comes back)
        newsReady()
    }

    /// Over the spec's limits: refused, so the board shows the screen's text version.
    private func sceneTooBig() {
        scene = nil
        complete = false
        reply("Closed;error=scene too big")
        redraw()
    }

    // ================================================================
    // Layout (docs/SCENES.md "Layout"): measure (natural sizes, cached per block while nothing changed), then place
    // ================================================================

    /// The unit: the menu rows' text size (rows.size), in points.
    /// The scene's text size: the menu rows' (rows.size), times sScale (gadgets draw smaller).
    var sSize: CGFloat { st.size * sScale }
    private var su: CGFloat { sSize * u }
    private var sSmallSize: CGFloat { sSize * 0.85 }
    private func sUnits(_ b: SBlock, _ k: UInt8) -> CGFloat { max(b.real(k), 0) * su }
    private func sFieldLineH() -> CGFloat { Self.fontLine(font(false, sSize)) + 2 * u }
    private func scol(_ i: Sc) -> UInt32 { sceneColors[i.rawValue] }
    private static func ucol(_ b: SBlock, _ k: UInt8) -> UInt32? {
        b.has(k) && b.u32(k) & 0xFF00_0000 == 0 ? b.u32(k) : nil
    }

    /// The monospaced font (Windows: Consolas) at size module pixels.
    private func sMono(_ size: CGFloat) -> NSFont { NSFont.monospacedSystemFont(ofSize: size * u, weight: .regular) }

    private static func sR(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x, y: y, width: max(w, 0), height: max(h, 0))
    }

    /// r inset by d on every side (negative: outset), never below 0 wide or tall (CGRect.insetBy would give null).
    private static func sInset(_ r: CGRect, _ d: CGFloat) -> CGRect {
        sR(r.minX + d, r.minY + d, r.width - 2 * d, r.height - 2 * d)
    }

    private static func sCenterIn(_ r: CGRect, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        sR(r.minX + (r.width - w) / 2, r.minY + (r.height - h) / 2, w, h)
    }

    /// Whether a and b touch, edges included (WPF's IntersectsWith; CGRect.intersects is false for empty rects).
    private static func sMeets(_ a: CGRect, _ b: CGRect) -> Bool {
        !a.isNull && !b.isNull && a.minX <= b.maxX && b.minX <= a.maxX && a.minY <= b.maxY && b.minY <= a.maxY
    }

    private static func sKnown(_ k: UInt8) -> Bool {
        (Sn.bkPanel...Sn.bkGrid).contains(k) || (Sn.bkText...Sn.bkIcon).contains(k) || (Sn.bkButton...Sn.bkItem).contains(k)
            || (Sn.bkInput...Sn.bkViewer).contains(k) || (Sn.bkSplit...Sn.bkCanvas).contains(k)   // version 6
    }

    private static func sIsControl(_ k: UInt8) -> Bool {
        k == Sn.bkButton || k == Sn.bkField || k == Sn.bkChoice || k == Sn.bkCheck || k == Sn.bkList || k == Sn.bkInput
            || k == Sn.bkVList || k == Sn.bkSlider   // version 6: a slider
    }

    /// A block's children that take space: not hidden, not a list's items; version 2: not pop-ups, hover toolbars,
    /// an input's chips, or blocks this width leaves out (P_WMIN, P_WMAX).
    private static func sVisibleKids(_ b: SBlock) -> [SBlock] {
        b.kids.filter { k in
            !k.flag(Sn.pHidden) && k.kind != Sn.bkItem && !sIsPop(k.kind) && !k.flag(Sn.pHoverShow) && sWidthOk(k)
                && !(k.kind == Sn.bkChip && b.kind == Sn.bkInput)
        }
    }

    /// Padding inside a block: a panel's 1 unit unless it says; controls keep their own.
    private func sPad(_ b: SBlock) -> CGFloat {
        switch b.kind {
        case Sn.bkPanel: return (b.has(Sn.pPad) ? max(b.real(Sn.pPad), 0) : 1) * su
        case Sn.bkButton, Sn.bkField, Sn.bkChoice, Sn.bkCheck, Sn.bkList, Sn.bkItem, Sn.bkInput, Sn.bkVList, Sn.bkChip,
             Sn.bkSlider, Sn.bkSplit:   // version 6
            return 0
        default: return sUnits(b, Sn.pPad)
        }
    }

    /// A rule across its box (in a column), or down it (in a row).
    private static func sRuleAcross(_ b: SBlock) -> Bool { b.parent?.kind != Sn.bkRow }

    /// b's natural size when at most maxW wide (text wraps to fit; fixed sizes and minimums apply).
    private func sMeasure(_ b: SBlock, _ maxW: CGFloat) -> CGSize {
        if b.flag(Sn.pHidden) {
            return .zero
        }
        let inf = maxW.isInfinite
        if inf && b.mInfGen == sceneGen {
            return b.mInf
        }
        if !inf && b.mGen == sceneGen && abs(b.mw - maxW) < 0.25 {
            return b.mSize
        }
        let fw = sUnits(b, Sn.pWidth), fh = sUnits(b, Sn.pHeight), pad = sPad(b)
        let inner = max((fw > 0 ? fw : maxW) - 2 * pad, 0)
        let c = sNatural(b, inner, fh > 0 ? max(fh - 2 * pad, 0) : -1)
        let w = fw > 0 ? fw : c.width + 2 * pad, h = fh > 0 ? fh : c.height + 2 * pad
        let size = CGSize(width: max(w, sUnits(b, Sn.pMinW)), height: max(h, sUnits(b, Sn.pMinH)))
        if inf {
            b.mInfGen = sceneGen
            b.mInf = size
        } else {
            b.mGen = sceneGen
            b.mw = maxW
            b.mSize = size
        }
        return size
    }

    /// The content's natural size inside the padding.
    private func sNatural(_ b: SBlock, _ inner: CGFloat, _ fixH: CGFloat) -> CGSize {
        let su = self.su
        switch b.kind {
        case Sn.bkPanel:   // its children, and room for the title on its border
            let s = sFlexNatural(b, inner, false)
            let title = b.str(Sn.pTitle)
            let tw = !title.isEmpty && st.title != 2 ? Self.textW(title, font(true, 17)) + 40 * u - 2 * sPad(b) : 0
            return CGSize(width: min(max(s.width, tw), max(inner, s.width)), height: s.height)
        case Sn.bkColumn: return sFlexNatural(b, inner, false)
        case Sn.bkRow: return sFlexNatural(b, inner, true)
        case Sn.bkStack:
            var w: CGFloat = 0, h: CGFloat = 0
            for k in Self.sVisibleKids(b) {
                let s = sMeasure(k, inner)
                w = max(w, s.width)
                h = max(h, s.height)
            }
            return CGSize(width: w, height: h)
        case Sn.bkScroll:
            guard let kid = Self.sVisibleKids(b).first else { return .zero }
            return b.num(Sn.pAxis) == 1 ? sMeasure(kid, .infinity) : sMeasure(kid, inner)
        case Sn.bkGrid:
            let n = Self.sVisibleKids(b).count
            if n == 0 {
                return .zero
            }
            let g = sGridDims(b, inner, n)
            let rows = (n + g.cols - 1) / g.cols
            let gap = sUnits(b, Sn.pGap)
            return CGSize(width: CGFloat(g.cols) * g.tw + gap * CGFloat(g.cols - 1),
                          height: CGFloat(rows) * g.th + gap * CGFloat(rows - 1))
        case Sn.bkImage, Sn.bkCells: return sPicNatural(b, inner, fixH)
        case Sn.bkRule: return Self.sRuleAcross(b) ? CGSize(width: 0, height: su) : CGSize(width: su, height: 0)
        case Sn.bkProgress:
            let label = b.str(Sn.pLabel)
            let lw = label.isEmpty ? 0 : Self.textW(label, font(false, sSmallSize)) + 0.6 * su
            return CGSize(width: 12 * su + lw, height: max(0.8 * su, lw > 0 ? Self.fontLine(font(false, sSmallSize)) : 0))
        case Sn.bkSpacer, Sn.bkItem: return .zero
        case Sn.bkIcon: return CGSize(width: 1.5 * su, height: 1.5 * su)   // P_WIDTH / P_HEIGHT size it
        case Sn.bkMenu, Sn.bkPopover, Sn.bkDrawer: return sFlexNatural(b, inner, false)   // a pop-up, measured for itself
        case Sn.bkInput, Sn.bkVList, Sn.bkViewer, Sn.bkChip: return sNaturalV2(b, inner, fixH)
        case Sn.bkSplit, Sn.bkChart, Sn.bkSlider, Sn.bkCanvas: return sNaturalV6(b, inner, fixH)   // version 6
        case Sn.bkButton: return CGSize(width: sButtonTextW(b) + 2 * sButtonPadX(b), height: 1.6 * su)
        case Sn.bkField:
            return CGSize(width: 16 * su, height: b.flag(Sn.pMulti) ? 1.6 * su + 3 * sFieldLineH() : 1.6 * su)
        case Sn.bkChoice:
            var w: CGFloat = 0, h = 1.6 * su
            for r in sPillPlaces(b, inner) {
                w = max(w, r.maxX)
                h = max(h, r.maxY + 0.1 * su)
            }
            return CGSize(width: w, height: h)
        case Sn.bkCheck: return CGSize(width: 1.5 * su + Self.textW(b.str(Sn.pLabel), font(false, sSize)), height: 1.5 * su)
        case Sn.bkList:
            let ws = b.f32s(Sn.pWidths), heads = b.strs(Sn.pHeaders)
            let cols = max(ws.count, max(heads.count, 1))
            var fix: CGFloat = 0
            var flex = ws.count < cols
            for x in ws {
                if x > 0 {
                    fix += x * su
                } else {
                    flex = true
                }
            }
            let headH = heads.isEmpty ? 0 : 1.5 * su
            return CGSize(width: max(fix + (flex ? 10 * su : 0), 12 * su) + 0.6 * su + 10 * u,
                          height: headH + 10 * 1.5 * su + 0.6 * su)
        default:   // text, or a kind this doesn't know: its alt text in its place
            return sTextNatural(b, inner)
        }
    }

    /// A row's or column's natural size: a column's widest child and their heights; a row's children's natural widths
    /// (shrunk when they don't fit, then their heights at those widths), or its lines when it wraps.
    private func sFlexNatural(_ b: SBlock, _ inner: CGFloat, _ horiz: Bool) -> CGSize {
        let kids = Self.sVisibleKids(b)
        if kids.isEmpty {
            return .zero
        }
        let gap = sUnits(b, Sn.pGap)
        if !horiz {
            var w: CGFloat = 0, h: CGFloat = 0
            for k in kids {
                let s = sMeasure(k, inner)
                w = max(w, s.width)
                h += s.height
            }
            return CGSize(width: w, height: h + gap * CGFloat(kids.count - 1))
        }
        if b.flag(Sn.pWrap) && !inner.isInfinite {
            let lines = sWrapLines(kids, inner, gap)
            var w: CGFloat = 0, h: CGFloat = 0
            for line in lines {
                let rw = sRowWidths(line, inner, gap)
                var lh: CGFloat = 0
                for i in line.indices {
                    lh = max(lh, sMeasure(line[i], rw.sizes[i]).height)
                }
                w = max(w, rw.natural <= inner ? rw.natural : rw.sizes.reduce(0, +) + gap * CGFloat(line.count - 1))
                h += lh
            }
            return CGSize(width: w, height: h + gap * CGFloat(lines.count - 1))
        }
        let rw = sRowWidths(kids, inner, gap)
        var rh: CGFloat = 0
        for i in kids.indices {
            rh = max(rh, sMeasure(kids[i], rw.sizes[i]).height)
        }
        return CGSize(width: rw.natural <= inner ? rw.natural : rw.sizes.reduce(0, +) + gap * CGFloat(kids.count - 1),
                      height: rh)
    }

    /// Children's widths across inner: each its P_WIDTH or natural width; spare room shared by P_GROW; short of room,
    /// the growing ones shrink first (to P_MINW), then the rest, each to its minimum. Natural is their sum before.
    private func sRowWidths(_ kids: [SBlock], _ inner: CGFloat, _ gap: CGFloat)
        -> (sizes: [CGFloat], natural: CGFloat, grew: Bool) {
        let n = kids.count
        var size = [CGFloat](repeating: 0, count: n)
        var mins = [CGFloat](repeating: 0, count: n)
        for i in 0..<n {
            let k = kids[i]
            let fw = sFracW(k, inner - gap * CGFloat(max(n - 1, 0))) ?? sUnits(k, Sn.pWidth)   // version 3: a share of the row
            size[i] = fw > 0 ? fw : sMeasure(k, .infinity).width
            if !size[i].isFinite {
                size[i] = 0   // never let one child's size poison the row's sums
            }
            mins[i] = fw > 0 ? fw : sMinW(k, size[i])
            if !mins[i].isFinite {
                mins[i] = 0
            }
        }
        let natural = size.reduce(0, +) + gap * CGFloat(max(n - 1, 0))
        if inner.isInfinite {
            return (size, natural, false)
        }
        var grew = false
        let spare = inner - natural
        if spare > 0 {
            let g = kids.reduce(CGFloat(0)) { $0 + max($1.real(Sn.pGrow), 0) }
            if g > 0 {
                for i in 0..<n {
                    size[i] += spare * max(kids[i].real(Sn.pGrow), 0) / g
                }
                grew = true
            }
        } else if spare < 0 {
            Self.sShrink(&size, mins, -spare) { kids[$0].real(Sn.pGrow) > 0 }
            let left = size.reduce(0, +) + gap * CGFloat(max(n - 1, 0)) - inner
            if left > 0 {
                Self.sShrink(&size, mins, left) { _ in true }
            }
        }
        return (size, natural, grew)
    }

    /// Takes over off the sizes picked, each in proportion to its room above its minimum.
    private static func sShrink(_ size: inout [CGFloat], _ mins: [CGFloat], _ over: CGFloat, _ pick: (Int) -> Bool) {
        var room: CGFloat = 0
        for i in size.indices where pick(i) && size[i] > mins[i] {
            room += size[i] - mins[i]
        }
        if room <= 0 {
            return
        }
        let take = min(over, room)
        for i in size.indices where pick(i) && size[i] > mins[i] {
            size[i] -= (size[i] - mins[i]) * take / room
        }
    }

    /// How narrow a block may get in a row that runs short of room (nat: its natural width).
    private func sMinW(_ k: SBlock, _ nat: CGFloat) -> CGFloat {
        if k.has(Sn.pMinW) {
            return sUnits(k, Sn.pMinW)
        }
        if sUnits(k, Sn.pWidth) > 0 {
            return nat
        }
        let su = self.su, pad = sPad(k)
        func natW(_ c: SBlock) -> CGFloat { sUnits(c, Sn.pWidth) > 0 ? sUnits(c, Sn.pWidth) : sMeasure(c, .infinity).width }
        switch k.kind {
        case Sn.bkText: return min(nat, 6 * su)
        case Sn.bkButton, Sn.bkCheck, Sn.bkRule: return nat
        case Sn.bkChoice, Sn.bkField, Sn.bkProgress, Sn.bkImage, Sn.bkCells, Sn.bkScroll, Sn.bkVList, Sn.bkViewer,
             Sn.bkInput, Sn.bkChart, Sn.bkCanvas, Sn.bkSlider:
            return min(nat, 3 * su)
        case Sn.bkSplit: return min(nat, 2 * sMinPane(k) + 0.6 * su)   // version 6
        case Sn.bkList: return min(nat, 8 * su)
        case Sn.bkRow:
            let kids = Self.sVisibleKids(k)
            let gap = sUnits(k, Sn.pGap)
            var sum: CGFloat = 0, most: CGFloat = 0
            for c in kids {
                let m = sMinW(c, natW(c))
                sum += m
                most = max(most, m)
            }
            return min(nat, (k.flag(Sn.pWrap) ? most : sum + gap * CGFloat(max(kids.count - 1, 0))) + 2 * pad)
        case Sn.bkPanel, Sn.bkColumn, Sn.bkStack:
            var most: CGFloat = 0
            for c in Self.sVisibleKids(k) {
                most = max(most, sMinW(c, natW(c)))
            }
            return min(nat, most + 2 * pad)
        case Sn.bkGrid: return min(nat, sGridDims(k, .infinity, 1).tw + 2 * pad)
        default: return 0
        }
    }

    /// How short a block may get in a column that runs short of room, w wide (nat: its natural height): scrolls,
    /// lists and pictures give way; containers as their children do; text and controls don't.
    private func sMinH(_ k: SBlock, _ w: CGFloat, _ nat: CGFloat) -> CGFloat {
        if k.has(Sn.pMinH) {
            return sUnits(k, Sn.pMinH)
        }
        if sUnits(k, Sn.pHeight) > 0 {
            return nat
        }
        if k.nGen == sceneGen && abs(k.nw - w) < 0.25 {
            return min(k.nMin, nat)
        }
        let su = self.su, pad = sPad(k), iw = max(w - 2 * pad, 0)
        var m = nat
        switch k.kind {
        case Sn.bkScroll: m = min(nat, 3 * su)
        case Sn.bkSplit, Sn.bkChart, Sn.bkCanvas: m = min(nat, 2 * su)   // version 6
        case Sn.bkList: m = min(nat, 6 * su)
        case Sn.bkImage, Sn.bkCells: m = min(nat, 2 * su)
        case Sn.bkField:
            if k.flag(Sn.pMulti) {
                m = min(nat, 1.6 * su)
            }
        case Sn.bkPanel, Sn.bkColumn:
            let kids = Self.sVisibleKids(k)
            var h: CGFloat = 0
            for c in kids {
                let cw = sUnits(c, Sn.pWidth) > 0 ? sUnits(c, Sn.pWidth) : iw
                h += sMinH(c, cw, sMeasure(c, cw).height)
            }
            m = min(nat, h + sUnits(k, Sn.pGap) * CGFloat(max(kids.count - 1, 0)) + 2 * pad)
        case Sn.bkRow where !k.flag(Sn.pWrap):
            let kids = Self.sVisibleKids(k)
            let rw = sRowWidths(kids, iw, sUnits(k, Sn.pGap))
            var h: CGFloat = 0
            for i in kids.indices {
                h = max(h, sMinH(kids[i], rw.sizes[i], sMeasure(kids[i], rw.sizes[i]).height))
            }
            m = min(nat, h + 2 * pad)
        case Sn.bkStack:
            var h: CGFloat = 0
            for c in Self.sVisibleKids(k) {
                h = max(h, sMinH(c, iw, sMeasure(c, iw).height))
            }
            m = min(nat, h + 2 * pad)
        default: break
        }
        k.nGen = sceneGen
        k.nw = w
        k.nMin = m
        return m
    }

    /// A row that wraps: its children in lines, each as many as fit w at their natural widths.
    private func sWrapLines(_ kids: [SBlock], _ w: CGFloat, _ gap: CGFloat) -> [[SBlock]] {
        var lines: [[SBlock]] = [[]]
        var x: CGFloat = 0
        for k in kids {
            let kw = sUnits(k, Sn.pWidth) > 0 ? sUnits(k, Sn.pWidth) : min(sMeasure(k, .infinity).width, w)
            if !lines[lines.count - 1].isEmpty && x + gap + kw > w {
                lines.append([])
                x = 0
            }
            x += (lines[lines.count - 1].isEmpty ? 0 : gap) + kw
            lines[lines.count - 1].append(k)
        }
        return lines
    }

    /// A grid's tiles a row and a tile's size: P_TILEW x P_TILEH units (8 x 6 by default, or the width shared by
    /// P_COLUMNS), P_COLUMNS a row or as many as fit w.
    private func sGridDims(_ b: SBlock, _ w: CGFloat, _ n: Int) -> (cols: Int, tw: CGFloat, th: CGFloat) {
        let su = self.su, gap = sUnits(b, Sn.pGap)
        if let shared = sGridShared(b, w) {   // version 5: the gallery's tiles (the third extension)
            return shared
        }
        var tw = sUnits(b, Sn.pTileW), th = sUnits(b, Sn.pTileH)
        var cols = b.num(Sn.pColumns)
        let inf = w.isInfinite
        if tw <= 0 {
            tw = cols > 0 && !inf ? max((w - gap * CGFloat(cols - 1)) / CGFloat(cols), su) : 8 * su
        }
        if th <= 0 {
            th = sUnits(b, Sn.pTileW) > 0 || cols == 0 ? 6 * su * tw / (8 * su) : tw * 0.75
        }
        if cols <= 0 {
            cols = inf ? min(max(n, 1), 4) : max(1, Int((w + gap) / max(tw + gap, 1)))
        }
        return (cols, tw, th)
    }

    /// An image's or cells block's natural size: its pixels (cells: 8 x 16 a cell) at the window's scale, its shape
    /// kept, made smaller to fit maxW (or as tall as a fixed height).
    private func sPicNatural(_ b: SBlock, _ maxW: CGFloat, _ fixH: CGFloat) -> CGSize {
        let px = sPicPixels(b)
        guard px.w > 0, px.h > 0 else { return .zero }
        var w = px.w * u, h = px.h * u
        if fixH > 0 {
            w *= fixH / h
            h = fixH
        }
        if w > maxW {
            h *= maxW / w
            w = maxW
        }
        return CGSize(width: w, height: h)
    }

    private func sPicPixels(_ b: SBlock) -> (w: CGFloat, h: CGFloat) {
        if b.kind == Sn.bkCells {
            let d = Self.sCellDims(b)
            return (CGFloat(d.cols * 8), CGFloat(d.rows * 16))
        }
        if b.image != nil {
            return (CGFloat(b.imageW), CGFloat(b.imageH))
        }
        if let a = sAsset(b) {   // version 2: an image may name an asset (P_ASSET) instead of carrying one
            return (CGFloat(a.w), CGFloat(a.h))
        }
        return (0, 0)
    }

    /// A cells block's size in cells: P_COLS x P_ROWS, or the rows sent if more, within the caps.
    private static func sCellDims(_ b: SBlock) -> (cols: Int, rows: Int) {
        var cols = b.num(Sn.pCols)
        var rows = max(b.num(Sn.pRows), b.cells.count)
        for r in b.cells {
            cols = max(cols, r.count)
        }
        cols = min(cols, Sn.cellsMaxCols)
        rows = cols > 0 ? min(rows, min(Sn.cellsMaxRows, Sn.cellsMax / cols)) : 0
        return (cols, rows)
    }

    private func sTextEmpty(_ b: SBlock) -> Bool {
        b.kind == Sn.bkText ? b.spans(Sn.pSpans).isEmpty && b.str(Sn.pText).isEmpty && !b.has(Sn.pClock)   // version 6: a clock
            : b.str(Sn.pAlt).isEmpty
    }

    /// A text's natural size: its longest line, or wrapped to maxW; its lines' height.
    private func sTextNatural(_ b: SBlock, _ maxW0: CGFloat) -> CGSize {
        let maxW = maxW0.isNaN || maxW0 < 0 ? 0 : maxW0   // never lay text out to a NaN width
        if sTextEmpty(b) {
            return b.kind == Sn.bkText ? CGSize(width: 0, height: sTextLayout(b, .infinity).size.height) : .zero
        }
        let t = sTextLayout(b, .infinity)
        let nw = ceil(t.size.width) + 1   // +1 so it doesn't wrap at its own width
        if nw <= maxW {
            return CGSize(width: nw, height: t.size.height)
        }
        let wrapped = sTextLayout(b, maxW)
        return CGSize(width: min(ceil(wrapped.size.width) + 1, maxW), height: wrapped.size.height)
    }

    /// A text's font and color by its role (docs/SCENES.md "Colors and roles"), P_FG over it.
    private func sTextLook(_ b: SBlock) -> (font: NSFont, fg: UInt32) {
        var size = sSize
        var bold = false, mono = false
        var fg = Self.sKnown(b.kind) ? scol(.text) : scol(.dim)
        switch b.num(Sn.pRole) {
        case Sn.rTitle:
            fg = scol(.title)
            bold = true
            size *= 1.3
        case Sn.rHeading:
            fg = scol(.accent)
            bold = true
        case Sn.rDim: fg = scol(.dim)
        case Sn.rAccent: fg = scol(.accent)
        case Sn.rMono: mono = true
        case Sn.rSmall:
            fg = scol(.dim)
            size *= 0.85
        case Sn.rGood: fg = scol(.good)
        case Sn.rBad: fg = scol(.bad)
        default: break
        }
        if let c = Self.ucol(b, Sn.pFg) {
            fg = c
        }
        if b.flag(Sn.pMono) {   // version 2
            mono = true
        }
        return (mono ? sMono(size) : font(bold, size), fg)
    }

    /// A role's color for a rule or a progress bar's fill (def when it has none).
    private func sRoleColor(_ b: SBlock, _ def: UInt32) -> UInt32 {
        guard b.has(Sn.pRole) else { return def }
        switch b.num(Sn.pRole) {
        case Sn.rTitle: return scol(.title)
        case Sn.rHeading, Sn.rAccent: return scol(.accent)
        case Sn.rDim, Sn.rSmall: return scol(.dim)
        case Sn.rGood: return scol(.good)
        case Sn.rBad: return scol(.bad)
        case Sn.rText, Sn.rMono: return scol(.text)
        default: return def
        }
    }

    /// A text block (or an unknown kind's alt text) laid out once: its spans' colors set on their ranges, wrapped at w
    /// (infinite: one line a '\n'), at most P_LINES lines with an ellipsis, aligned by P_TALIGN. Kept (one natural,
    /// one wrapped) while nothing changed.
    private func sTextLayout(_ b: SBlock, _ w: CGFloat) -> SText {
        let inf = w.isInfinite
        if inf, b.ftNatGen == sceneGen, let t = b.ftNat {
            return t
        }
        if !inf, b.ftGen == sceneGen, let t = b.ft, abs(b.ftW - w) < 0.25 {
            return t
        }
        let look = sTextLook(b)
        let clock = b.kind == Sn.bkText && b.has(Sn.pClock)   // version 6: the client's own text (the fourth extension)
        let spans = b.kind == Sn.bkText && !clock ? b.spans(Sn.pSpans) : []
        b.runs.removeAll()
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        if !inf {
            switch b.num(Sn.pTAlign) {
            case 1: para.alignment = .center
            case 2: para.alignment = .right
            default: para.alignment = .left
            }
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: look.font, .foregroundColor: Self.color(look.fg),
                                                    .paragraphStyle: para]
        let str = NSMutableAttributedString()
        if !spans.isEmpty {
            b.links.removeAll()
            for sp0 in spans {
                var sp = sp0
                // version 2: a link span is its text, U+0001, then its address
                if sp.fx == Sn.fxLink, let cut = sp.text.firstIndex(of: "\u{1}") {
                    let shown = String(sp.text[..<cut])
                    b.links.append((start: str.length, len: (shown as NSString).length,
                                    url: String(sp.text[sp.text.index(after: cut)...])))
                    sp = Span(fg: sp.fg, bg: sp.bg, fx: 0, text: shown)
                }
                let start = str.length
                str.append(NSAttributedString(string: sp.text, attributes: attrs))
                b.runs.append((start: start, len: str.length - start, span: sp))
            }
        } else {
            str.append(NSAttributedString(string: clock ? sClockString(b) : b.kind == Sn.bkText ? b.str(Sn.pText) : b.str(Sn.pAlt),
                                          attributes: attrs))
        }
        if str.length == 0 {
            str.append(NSAttributedString(string: " ", attributes: attrs))
        }
        for r in b.runs where r.len > 0 && r.span.fg != Self.none {
            str.addAttribute(.foregroundColor, value: Self.color(r.span.fg), range: NSRange(location: r.start, length: r.len))
        }
        let t = SText(str, width: inf ? Sn.textInf : w.isNaN ? 1 : max(w, 1), lines: b.num(Sn.pLines))
        if inf {
            b.ftNat = t
            b.ftNatGen = sceneGen
        } else {
            b.ft = t
            b.ftGen = sceneGen
            b.ftW = w
        }
        return t
    }

    private func sButtonPadX(_ b: SBlock) -> CGFloat { (b.has(Sn.pPad) ? max(b.real(Sn.pPad), 0) : 0.6) * su }

    private func sButtonTextW(_ b: SBlock) -> CGFloat {
        let f = font(true, sSize)
        let spans = b.spans(Sn.pSpans)
        return spans.isEmpty ? Self.textW(b.str(Sn.pLabel), f) : spans.reduce(CGFloat(0)) { $0 + Self.textW($1.text, f) }
    }

    /// A choice's pills, from its top left, wrapped at w.
    private func sPillPlaces(_ b: SBlock, _ w: CGFloat) -> [CGRect] {
        let su = self.su, ph = 1.4 * su, gap = 0.4 * su, f = font(false, sSize)
        var x: CGFloat = 0, y = 0.1 * su
        var list: [CGRect] = []
        for o in b.strs(Sn.pOptions) {
            let pw = Self.textW(o, f) + 1.2 * su
            if x > 0 && x + pw > w {
                x = 0
                y += ph + gap
            }
            list.append(CGRect(x: x, y: y, width: pw, height: ph))
            x += pw + gap
        }
        return list
    }

    /// A whole-window scene is up (SF_BLEED): the menu's header, gadgets and status bar make way.
    var sceneBleeds: Bool {
        guard complete, isScene, let t = scene else { return false }
        return t.flags & Sn.sfBleed != 0
    }

    /// The scene's space: where a menu box goes, under the header art and over the status bar, less a unit.
    private func sceneSpace(_ w: CGFloat, _ h: CGFloat, _ hdrBottom: CGFloat) -> CGRect {
        if sceneBleeds {
            return Self.sR(0, 0, w, h)   // no header, no status bar, no margin: Messages, Files, MRC
        }
        var top = hdrBottom
        let bottom = h - statusH * u
        if bottom - top < 120 * u {
            top = max(bottom - 120 * u, 0)
        }
        return Self.sInset(Self.sR(0, top, w, bottom - top), su)
    }

    /// The whole scene placed in space: as wide as it (SF_OVER: its natural size, centered), its natural height placed
    /// as the menu box is (box.valign; SF_FULL: all of it). Too tall even with every scroll, list and picture at its
    /// minimum, the scene itself scrolls.
    private func layoutScene(_ s: SceneTree, _ space: CGRect) {
        s.pass += 1
        s.order.removeAll()
        Self.sSceneW = space.width / max(u, 0.01)   // P_WMIN/P_WMAX are in layout units (the modules' lp)
        s.space = space
        let root = s.top
        let sw = space.width, sh = space.height
        let isOver = s.flags & Sn.sfOver != 0, full = s.flags & Sn.sfFull != 0 && !isOver
        var nat = sMeasure(root, sw)
        let w = isOver ? min(nat.width, sw) : sw
        if w != sw {
            nat = sMeasure(root, w)
        }
        var h = full ? sh : min(nat.height, sh)
        s.scrollMax = 0
        if nat.height > sh {
            let m = sMinH(root, w, nat.height)
            if m > sh {
                h = m
                s.scrollMax = m - sh
            }
        }
        s.scroll = min(max(s.scroll, 0), s.scrollMax)
        let x = space.minX + (sw - w) / 2
        let y: CGFloat
        if s.scrollMax > 0 {
            y = space.minY - s.scroll
        } else if isOver || st.valign == 0 || st.valign == 2 {
            y = space.minY + (sh - h) / 2
        } else {
            y = st.valign == 1 ? space.minY : space.minY + sh - h
        }
        let clip = s.scrollMax > 0 ? space : Self.sInset(space, -2 * su)
        sArrange(s, root, Self.sR(x, y, w, h), clip, false)
        sLayoutPops(s, space)   // version 2: menus, popovers and drawers over it, last (so they're hit first)
    }

    /// Places b in r (its clip: what of it can show) and its children in it.
    private func sArrange(_ s: SceneTree, _ b: SBlock, _ r: CGRect, _ clip: CGRect, _ off: Bool) {
        b.pass = s.pass
        b.box = r
        b.clip = clip
        b.off = off || b.flag(Sn.pDisabled)
        s.order.append(b)
        let inner = Self.sInset(r, sPad(b))
        b.inner = inner
        switch b.kind {
        case Sn.bkPanel, Sn.bkColumn: sArrangeFlex(s, b, inner, false, clip)
        case Sn.bkRow: sArrangeFlex(s, b, inner, true, clip)
        case Sn.bkStack:
            let align = b.has(Sn.pAlign) ? b.num(Sn.pAlign) : Sn.aStretch
            for k in Self.sVisibleKids(b) {
                let a = k.has(Sn.pSelf) ? k.num(Sn.pSelf) : align
                if a == Sn.aStretch {
                    sArrange(s, k, inner, clip, b.off)
                    continue
                }
                let m = sMeasure(k, inner.width)
                let kw = min(m.width, inner.width), kh = min(m.height, inner.height)
                let f: CGFloat = a == Sn.aCenter ? 0.5 : a == Sn.aEnd ? 1 : 0
                sArrange(s, k, Self.sR(inner.minX + (inner.width - kw) * f, inner.minY + (inner.height - kh) * f, kw, kh),
                         clip, b.off)
            }
        case Sn.bkScroll: sArrangeScroll(s, b, inner, clip)
        case Sn.bkVList: sArrangeVList(s, b, inner, clip)
        case Sn.bkSplit: sArrangeSplit(s, b, inner, clip)   // version 6
        case Sn.bkGrid:
            let kids = Self.sVisibleKids(b)
            let gap = sUnits(b, Sn.pGap)
            let g = sGridDims(b, inner.width, kids.count)
            for i in kids.indices {
                sArrange(s, kids[i], Self.sR(inner.minX + CGFloat(i % g.cols) * (g.tw + gap),
                                             inner.minY + CGFloat(i / g.cols) * (g.th + gap), g.tw, g.th), clip, b.off)
            }
        default: break
        }
        // version 2: hover-only blocks (P_HOVERSHOW) sit over the top-right of their hover root, out of the flow
        for k in b.kids where k.flag(Sn.pHoverShow) && !k.flag(Sn.pHidden) {
            let m = sMeasure(k, .infinity)
            sArrange(s, k, Self.sR(r.maxX - m.width - 0.4 * su, r.minY - m.height * 0.45, m.width, m.height),
                     Self.sInset(clip, -su), b.off)
        }
    }

    /// A row's or column's children along it (wrapping into lines when a row may).
    private func sArrangeFlex(_ s: SceneTree, _ b: SBlock, _ inner: CGRect, _ horiz: Bool, _ clip: CGRect) {
        let kids = Self.sVisibleKids(b)
        if kids.isEmpty {
            return
        }
        let gap = sUnits(b, Sn.pGap)
        let align = b.has(Sn.pAlign) ? b.num(Sn.pAlign) : Sn.aStretch, just = b.num(Sn.pJustify)
        if horiz && b.flag(Sn.pWrap) {
            var y = inner.minY
            for line in sWrapLines(kids, inner.width, gap) {
                let rw = sRowWidths(line, inner.width, gap)
                var lh: CGFloat = 0
                for i in line.indices {
                    lh = max(lh, sUnits(line[i], Sn.pHeight) > 0 ? sUnits(line[i], Sn.pHeight)
                                                                  : sMeasure(line[i], rw.sizes[i]).height)
                }
                sPlaceLine(s, b, line, rw.sizes, Self.sR(inner.minX, y, inner.width, lh), true, align, just, gap, rw.grew, clip)
                y += lh + gap
            }
            return
        }
        if horiz {
            let rw = sRowWidths(kids, inner.width, gap)
            sPlaceLine(s, b, kids, rw.sizes, inner, true, align, just, gap, rw.grew, clip)
            return
        }
        // a column: each child's width first (stretched, or its own), then the heights along it
        let n = kids.count
        var size = [CGFloat](repeating: 0, count: n)
        var mins = [CGFloat](repeating: 0, count: n)
        for i in 0..<n {
            let k = kids[i]
            let a = k.has(Sn.pSelf) ? k.num(Sn.pSelf) : align
            let cw = sUnits(k, Sn.pWidth) > 0 ? sUnits(k, Sn.pWidth)
                : a == Sn.aStretch ? inner.width : min(sMeasure(k, inner.width).width, inner.width)
            let fh = sUnits(k, Sn.pHeight)
            size[i] = fh > 0 ? fh : sMeasure(k, cw).height
            mins[i] = fh > 0 ? fh : sMinH(k, cw, size[i])
        }
        let spare = inner.height - size.reduce(0, +) - gap * CGFloat(n - 1)
        var grow = false
        // SF_FULL: the scene's own blocks fill the space (they sat at their natural height, the Wall's list short)
        let fill = b === s.top && s.flags & Sn.sfFull != 0 && s.flags & Sn.sfOver == 0
        func gr(_ k: SBlock) -> CGFloat { fill && !k.has(Sn.pGrow) ? 1 : max(k.real(Sn.pGrow), 0) }
        if spare > 0 {
            let g = kids.reduce(CGFloat(0)) { $0 + gr($1) }
            if g > 0 {
                for i in 0..<n {
                    size[i] += spare * gr(kids[i]) / g
                }
                grow = true
            }
        } else if spare < 0 {
            Self.sShrink(&size, mins, -spare) { kids[$0].real(Sn.pGrow) > 0 }
            let left = size.reduce(0, +) + gap * CGFloat(n - 1) - inner.height
            if left > 0 {
                Self.sShrink(&size, mins, left) { _ in true }
            }
        }
        sPlaceLine(s, b, kids, size, inner, false, align, just, gap, grow, clip)
    }

    /// Children along r with their main sizes: P_JUSTIFY places them when nothing grew; across, P_ALIGN (a child's
    /// P_SELF over it) stretches them or puts them at the start, center or end.
    private func sPlaceLine(_ s: SceneTree, _ b: SBlock, _ kids: [SBlock], _ main: [CGFloat], _ r: CGRect, _ horiz: Bool,
                            _ align: Int, _ just: Int, _ gap: CGFloat, _ grew: Bool, _ clip: CGRect) {
        let n = kids.count
        let len = horiz ? r.width : r.height
        var pos = horiz ? r.minX : r.minY, extra: CGFloat = 0
        let spare = len - main.reduce(0, +) - gap * CGFloat(n - 1)
        if !grew && spare > 0 {
            switch just {
            case Sn.jCenter: pos += spare / 2
            case Sn.jEnd: pos += spare
            case Sn.jBetween:
                if n > 1 {
                    extra = spare / CGFloat(n - 1)
                }
            default: break
            }
        }
        let cross = horiz ? r.height : r.width
        for i in 0..<n {
            let k = kids[i]
            let a = k.has(Sn.pSelf) ? k.num(Sn.pSelf) : align
            let fixedCross = sUnits(k, horiz ? Sn.pHeight : Sn.pWidth)
            let cs: CGFloat
            if fixedCross > 0 {
                cs = fixedCross
            } else if a == Sn.aStretch {
                cs = cross
            } else {
                cs = min(horiz ? sMeasure(k, main[i]).height : sMeasure(k, cross).width, cross)
            }
            let co = a == Sn.aCenter ? (cross - cs) / 2 : a == Sn.aEnd ? cross - cs : 0
            sArrange(s, k, horiz ? Self.sR(pos, r.minY + co, main[i], cs) : Self.sR(r.minX + co, pos, cs, main[i]), clip, b.off)
            pos += main[i] + gap + extra
        }
    }

    /// A scroll's one child at its natural size along the axis (at least the view), moved by the scroll and clipped
    /// to the view; P_FOLLOW keeps it at the end while it was there.
    private func sArrangeScroll(_ s: SceneTree, _ b: SBlock, _ view: CGRect, _ clip: CGRect) {
        b.scrollMax = 0
        guard let kid = Self.sVisibleKids(b).first else { return }
        let c = clip.intersection(view)
        var bar = 10 * u
        if b.num(Sn.pAxis) == 1 {
            let cw = sMeasure(kid, .infinity).width
            b.scrollMax = max(cw - view.width, 0)
            b.view = view.width
            Self.sFollowClamp(b)
            sScrollPosApply(b)   // version 6: P_SCROLLPOS
            sArrange(s, kid, Self.sR(view.minX - b.scroll, view.minY, max(cw, view.width),
                                     view.height - (b.scrollMax > 0 ? bar : 0)), c, b.off)
            return
        }
        var ch = sMeasure(kid, view.width).height
        if ch > view.height {
            ch = sMeasure(kid, max(view.width - bar, 0)).height
        } else {
            bar = 0
        }
        b.scrollMax = max(ch - view.height, 0)
        b.view = view.height
        Self.sFollowClamp(b)
        sScrollPosApply(b)   // version 6: P_SCROLLPOS
        // on whole device pixels, so what's in it moves as one (each line snapped on its own steps separately)
        let sc = window?.backingScaleFactor ?? 2
        let sy = ((view.minY - b.scroll) * sc).rounded() / sc
        sArrange(s, kid, Self.sR(view.minX, sy, view.width - bar, max(ch, view.height)), c, b.off)
    }

    /// P_AUTO scrolls crawl by themselves (a news ticker): P_AUTO units a second at 1x, still while the pointer is over
    /// them or just after the wheel; at the end they hold, then start over at the top.
    private func sAutoScroll(_ s: SceneTree) {
        let now = Date()
        let dt = CGFloat(min(now.timeIntervalSince(s.autoTick), 0.25))
        s.autoTick = now
        let mouse = wireMouse ?? pointer
        for b in s.order where b.kind == Sn.bkScroll && b.has(Sn.pAuto) && b.pass == s.pass && b.scrollMax > 0 {
            if now < b.autoHold {
                continue
            }
            if let m = mouse, b.box.contains(m), b.clip.contains(m) {
                continue
            }
            if b.scroll >= b.scrollMax - 0.5 {
                if !b.autoEnded {
                    b.autoEnded = true
                    b.autoHold = now.addingTimeInterval(2.5)
                } else {
                    b.autoEnded = false
                    sSetScroll(b, 0)
                    b.autoHold = now.addingTimeInterval(1.5)
                }
                continue
            }
            sSetScroll(b, b.scroll + CGFloat(b.num(Sn.pAuto)) * u * dt)
        }
    }

    private static func sFollowClamp(_ b: SBlock) {
        if b.flag(Sn.pFollow) && b.atEnd {
            b.scroll = b.scrollMax
        }
        b.scroll = min(max(b.scroll, 0), b.scrollMax)
    }

    private func sSetScroll(_ b: SBlock, _ v: CGFloat) {
        b.scroll = min(max(v, 0), b.scrollMax)
        b.anchorRow = -1   // a vlist scrolled by hand: no anchor row until it's laid out again
        b.atEnd = b.scroll >= b.scrollMax - 1
        sceneArr += 1
    }

    /// Scrolls b's scrolls (and the scene) so b shows: the focus moved to it.
    private func sceneIntoView(_ s: SceneTree, _ b: SBlock) {
        guard b.pass == s.pass else { return }
        var a = b.parent
        while let sc = a {
            if sc.kind == Sn.bkScroll && sc.pass == s.pass && sc.scrollMax > 0 && sc.num(Sn.pAxis) != 1 {
                if b.box.minY < sc.inner.minY {
                    sSetScroll(sc, sc.scroll - (sc.inner.minY - b.box.minY))
                } else if b.box.maxY > sc.inner.maxY {
                    sSetScroll(sc, sc.scroll + min(b.box.maxY - sc.inner.maxY, b.box.minY - sc.inner.minY))
                }
            }
            a = sc.parent
        }
        if s.scrollMax > 0 {
            if b.box.minY < s.space.minY {
                s.scroll = max(s.scroll - (s.space.minY - b.box.minY), 0)
            } else if b.box.maxY > s.space.maxY {
                s.scroll = min(s.scroll + b.box.maxY - s.space.maxY, s.scrollMax)
            }
            sceneArr += 1
        }
    }

    // ================================================================
    // Drawing (in this flipped view: y down, as WPF)
    // ================================================================

    /// body drawn at alpha (Windows' PushOpacity): one transparency layer, so what overlaps inside doesn't show through.
    private func sFaded(_ alpha: CGFloat, _ body: () -> Void) {
        guard alpha < 1, let cg = NSGraphicsContext.current?.cgContext else {
            body()
            return
        }
        cg.saveGState()
        cg.setAlpha(max(alpha, 0))
        cg.beginTransparencyLayer(auxiliaryInfo: nil)
        body()
        cg.endTransparencyLayer()
        cg.restoreGState()
    }

    private func sFillRR(_ r: CGRect, _ radius: CGFloat, _ c: UInt32, _ a: CGFloat = 1) {
        Self.color(c, a).setFill()
        NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
    }

    private func sStrokeRR(_ r: CGRect, _ radius: CGFloat, _ width: CGFloat, _ c: UInt32, _ a: CGFloat = 1) {
        Self.color(c, a).setStroke()
        let p = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
        p.lineWidth = width
        p.stroke()
    }

    /// The scene in its space: SF_OVER over the scene before it, dimmed; the tooltip of what's under the pointer.
    func drawScene(_ w: CGFloat, _ h: CGFloat, _ hdrBottom: CGFloat) {
        guard let s = scene else { return }
        if sceneU != u || sceneSize != st.size || sceneDpi != sDpi {
            sceneU = u
            sceneSize = st.size
            sceneDpi = sDpi
            sceneGen += 1
        }
        let space = sceneSpace(w, h, hdrBottom)
        sSceneSizeCheck(s, space)   // version 6: SF_SIZE
        if s.flags & Sn.sfOver != 0 {
            if let under = s.under {
                sDrawTree(under, space)
            }
            NSColor(white: 0, alpha: 110.0 / 255).setFill()
            CGRect(x: 0, y: 0, width: w, height: max(h - statusH * u, 0)).fill(using: .sourceOver)
        }
        sFaded(fadeIn()) {
            sDrawTree(s, space)
        }
        sceneColors = s.colors
        sceneTooltip(s, w, h)
        sDrawSceneDrop()           // version 5: a drop target lit, a row's drag label (the third extension)
        sDrawSceneDrag(w, h)
    }

    private func sDrawTree(_ s: SceneTree, _ space: CGRect) {
        sceneColors = s.colors
        s.bars.removeAll()   // version 6: drawn again below, for dragging
        sAutoScroll(s)
        sceneTimers(s)   // version 2: debounced changes, autosave, settled selections, hover asks
        sceneTimers6(s)  // version 6: clocks, countdowns, scroll positions (the fourth extension)
        if s.laidSpace != space || s.laidU != u || s.laidGen != sceneGen || s.laidArr != sceneArr {
            layoutScene(s, space)
            s.laidSpace = space
            s.laidU = u
            s.laidGen = sceneGen
            s.laidArr = sceneArr
        }
        if s.scrollMax > 0 {
            NSGraphicsContext.saveGraphicsState()
            space.clip()
            sDrawBlock(s, s.top, space)
            NSGraphicsContext.restoreGraphicsState()
            sScrollbar(Self.sInset(space, -0.5 * su), s.scroll, s.scrollMax, false, s, nil)
        } else {
            sDrawBlock(s, s.top, Self.sInset(space, -2 * su))
        }
        sDrawPops(s)   // version 2: menus, popovers and drawers over everything
    }

    /// One block and what's in it; a disabled one dim. Anything outside clip isn't drawn; version 2: nor pop-ups
    /// (sDrawPops draws them) or hover-only blocks while their root isn't hovered.
    private func sDrawBlock(_ s: SceneTree, _ b: SBlock, _ clip: CGRect) {
        guard b.pass == s.pass, Self.sMeets(b.box, clip), !Self.sIsPop(b.kind), !sHoverHidden(b) else { return }
        sAnimated(b) {   // version 2: P_ANIM and OP_ANIMATE
            sDrawDecor(b)
            // an input inside the board's own box (P_STROKE none) isn't dimmed when off: the board's box shows its state
            let boxless = b.kind == Sn.bkInput && b.has(Sn.pStroke) && Self.ucol(b, Sn.pStroke) == nil
            sFaded(b.flag(Sn.pDisabled) && !boxless ? 0.45 : 1) {
                sDrawBlockBody(s, b, clip)
            }
            sAnimAfter(b)
        }
    }

    private func sDrawBlockBody(_ s: SceneTree, _ b: SBlock, _ clip: CGRect) {
        // rows, columns, stacks and grids: sDrawFlat (corners, gradient, wash)
        let ownBg = [Sn.bkPanel, Sn.bkButton, Sn.bkField, Sn.bkChoice, Sn.bkCheck, Sn.bkList, Sn.bkProgress,
                     Sn.bkRow, Sn.bkColumn, Sn.bkStack, Sn.bkGrid]
        if let bg = Self.ucol(b, Sn.pBg), !ownBg.contains(b.kind) {
            Self.color(bg).setFill()
            b.box.fill()
        }
        switch b.kind {
        case Sn.bkPanel:
            sDrawPanel(b)
            sDrawKids(s, b, clip)
        case Sn.bkRow, Sn.bkColumn, Sn.bkStack, Sn.bkGrid:
            sDrawFlat(b)   // version 3: a flat box under them, when it has one
            sDrawKids(s, b, clip)
        case Sn.bkScroll:
            let c = clip.intersection(b.inner)
            if !c.isEmpty {
                NSGraphicsContext.saveGraphicsState()
                c.clip()
                sDrawKids(s, b, c)
                NSGraphicsContext.restoreGraphicsState()
            }
            sScrollbar(b.inner, b.scroll, b.scrollMax, b.num(Sn.pAxis) == 1, s, b)
            if b.flag(Sn.pPane) && sFocused(s, b) {   // version 6: a pane clicked into
                sDrawPaneFocus(b)
            }
        case Sn.bkText: sDrawText(b)
        case Sn.bkImage:   // version 6: where the picture went (click positions)
            if let img = b.image, b.imageW > 0, b.imageH > 0 {
                b.picRect = sDrawFitted(img, CGFloat(b.imageW), CGFloat(b.imageH), b.inner, b.num(Sn.pFit), b.flag(Sn.pSmooth))
            } else if b.image == nil, let a = sAsset(b), a.w > 0, a.h > 0 {   // version 2: an asset (P_ASSET)
                b.picRect = sDrawFitted(a.image, CGFloat(a.w), CGFloat(a.h), b.inner, b.num(Sn.pFit), b.flag(Sn.pSmooth))
            }
        case Sn.bkCells:
            let d = Self.sCellDims(b)
            if let img = sCellsImage(b) {
                b.picRect = sDrawFitted(img, CGFloat(d.cols * 8), CGFloat(d.rows * 16), b.inner, b.num(Sn.pFit),
                                        b.flag(Sn.pSmooth))
            }
        case Sn.bkRule:
            let r = b.box
            var c = scol(.border), a: CGFloat = 160.0 / 255
            if let fg = Self.ucol(b, Sn.pFg) {
                c = fg
                a = 1
            } else if b.has(Sn.pRole) {
                c = sRoleColor(b, scol(.border))
                a = 1
            }
            let t = max(1 * u, 1)
            Self.color(c, a).setFill()
            (Self.sRuleAcross(b) ? Self.sR(r.minX, r.minY + (r.height - t) / 2, r.width, t)
                                 : Self.sR(r.minX + (r.width - t) / 2, r.minY, t, r.height)).fill(using: .sourceOver)
        case Sn.bkProgress: sDrawProgress(b)
        case Sn.bkSpacer, Sn.bkItem: break
        case Sn.bkIcon:   // the client's own icons (RainwireMenu.swift drawIcon): its color P_FG, else its role's
            drawIcon(b.num(Sn.pIcon), Self.ucol(b, Sn.pFg) ?? sRoleColor(b, scol(.text)), b.inner)
        case Sn.bkButton: sDrawButton(s, b)
        case Sn.bkField: sDrawField(s, b)
        case Sn.bkChoice: sDrawChoice(s, b)
        case Sn.bkCheck: sDrawCheck(s, b)
        case Sn.bkList: sDrawList(s, b)
        case Sn.bkInput, Sn.bkVList, Sn.bkChip, Sn.bkViewer: sDrawV2(s, b, clip)
        case Sn.bkSplit: sDrawSplit(s, b, clip)   // version 6 (the fourth extension)
        case Sn.bkChart: sDrawChart(b)
        case Sn.bkSlider: sDrawSlider(s, b)
        case Sn.bkCanvas: sDrawCanvas(b)
        default: sDrawText(b)   // a kind this doesn't know: its alt text
        }
    }

    private func sDrawKids(_ s: SceneTree, _ b: SBlock, _ clip: CGRect) {
        for k in b.kids {
            sDrawBlock(s, k, clip)
        }
    }

    /// version 6: a gadget that has the keys (gFocus) shows its focus too.
    private func sFocused(_ s: SceneTree, _ b: SBlock) -> Bool {
        (s === scene || s === gFocus?.tree) && s.focus != 0 && s.focus == b.id
    }

    private func sIsHover(_ b: SBlock) -> Bool {
        guard let p = pointer else { return false }
        return !b.off && b.box.contains(p) && b.clip.contains(p)
    }

    /// A panel in the sysop's box style (radius, border, opacity, shadow), its title on the top border.
    private func sDrawPanel(_ b: SBlock) {
        let bg = Self.ucol(b, Sn.pBg) ?? scol(.panel)
        panel(b.box, bg, scol(.border), radiusScale: 8.0 / 6)
        if b.has(Sn.pGrad) {   // version 2: a gradient to P_GRAD, drifting with P_DRIFT
            sDrawGradPanel(b, bg, st.border > 0 ? st.border * u : 0, st.radius * u * 8.0 / 6)
        }
        let title = b.str(Sn.pTitle)
        guard !title.isEmpty, st.title != 2 else { return }
        let f = font(true, 17)
        let tx = b.box.minX + 20 * u
        let shown = Self.fitText(title, f, max(b.box.width - 40 * u, 1))
        let t = Self.text(shown, f, Self.ucol(b, Sn.pFg) ?? scol(.title))
        borderCut(tx - 8 * u, b.box.minY, t.size().width + 16 * u, bg)
        t.draw(at: CGPoint(x: tx, y: Self.capY(f, b.box.minY)))
    }

    /// Styled text in its box: span backgrounds, pulsing (between its color and the panel's), shimmering (a glint
    /// sweeping across), blinking backgrounds, as the menus' spans.
    private func sDrawText(_ b: SBlock) {
        let r = b.inner
        guard !sTextEmpty(b), r.width > 0 else { return }
        let t = sTextLayout(b, r.width)
        let origin = CGPoint(x: r.minX, y: r.minY)
        let def = sTextLook(b).fg
        let now = nowMs
        let noSel = NSRange(location: NSNotFound, length: 0)
        // every rect first (they lay the text out), then the colors (they edit it)
        var recolor: [(range: NSRange, color: UInt32)] = []
        for run in b.runs where run.len > 0 {
            let sp = run.span
            let cr = NSRange(location: run.start, length: run.len)
            let gr = t.layout.glyphRange(forCharacterRange: cr, actualCharacterRange: nil)
            if sp.bg != Self.none && !(sp.fx == Self.fxBlink && Int(now / 500) % 2 == 1) {
                Self.color(sp.bg).setFill()
                t.layout.enumerateEnclosingRects(forGlyphRange: gr, withinSelectedGlyphRange: noSel, in: t.box) { rect, _ in
                    rect.offsetBy(dx: origin.x, dy: origin.y).fill()
                }
            }
            let fg = sp.fg != Self.none ? sp.fg : def
            if sp.fx == Self.fxPulse {
                let k = CGFloat(0.5 + 0.5 * sin(now / 1000 * 3.6))
                recolor.append((cr, Self.mix(Self.mix(fg, scol(.panel), 0.5), fg, k)))
            } else if sp.fx == Self.fxShimmer {
                let bx = t.layout.boundingRect(forGlyphRange: gr, in: t.box)
                let pos = bx.minX + CGFloat(now / 1400).truncatingRemainder(dividingBy: 1.8) * (bx.width + 60 * u) - 30 * u
                let reach = 24 * u
                (t.storage.string as NSString).enumerateSubstrings(in: cr, options: .byComposedCharacterSequences) { _, sub, _, _ in
                    let cb = t.layout.boundingRect(forGlyphRange: t.layout.glyphRange(forCharacterRange: sub,
                                                                                      actualCharacterRange: nil), in: t.box)
                    let glint = 1 - min(max(abs(cb.midX - pos) / reach, 0), 1)
                    recolor.append((sub, RainwireMenuView.mix(fg, 0xFF_FFFF, glint * 0.85)))
                }
            }
        }
        // version 2: gradient text (P_GRAD, no spans): each character its color across the text, left to right
        if let c2 = Self.ucol(b, Sn.pGrad), b.runs.isEmpty {
            let all = NSRange(location: 0, length: t.storage.length)
            let bx = t.layout.boundingRect(forGlyphRange: t.glyphs, in: t.box)
            (t.storage.string as NSString).enumerateSubstrings(in: all, options: .byComposedCharacterSequences) { _, sub, _, _ in
                let cb = t.layout.boundingRect(forGlyphRange: t.layout.glyphRange(forCharacterRange: sub,
                                                                                  actualCharacterRange: nil), in: t.box)
                let k = bx.width > 0 ? (cb.midX - bx.minX) / bx.width : 0
                recolor.append((sub, RainwireMenuView.mix(def, c2, k)))
            }
        }
        if !recolor.isEmpty {
            t.storage.beginEditing()
            for rc in recolor {
                t.storage.addAttribute(.foregroundColor, value: Self.color(rc.color), range: rc.range)
            }
            t.storage.endEditing()
        }
        NSGraphicsContext.saveGraphicsState()
        Self.sInset(b.box, -2 * u).clip()
        t.layout.drawGlyphs(forGlyphRange: t.glyphs, at: origin)
        sDrawLinks(b, t, origin)   // version 2: link spans underlined
        NSGraphicsContext.restoreGraphicsState()
    }

    /// A picture (pw x ph its shape) in r by P_FIT: contain, cover, stretch or its natural size, centered; by nearest
    /// pixel unless smooth. Version 6: returns where it went (click positions).
    @discardableResult
    private func sDrawFitted(_ img: NSImage, _ pw: CGFloat, _ ph: CGFloat, _ r: CGRect, _ fit: Int, _ smooth: Bool) -> CGRect {
        guard r.width > 0, r.height > 0, pw > 0, ph > 0 else { return .zero }
        let d: CGRect
        switch fit {
        case Sn.fitStretch:
            d = r
        case Sn.fitCover:
            let k = max(r.width / pw, r.height / ph)
            d = Self.sCenterIn(r, pw * k, ph * k)
        case Sn.fitNone:
            d = Self.sCenterIn(r, pw * u, ph * u)
        default:
            let k = min(r.width / pw, r.height / ph)
            d = Self.sCenterIn(r, pw * k, ph * k)
        }
        NSGraphicsContext.saveGraphicsState()
        if fit == Sn.fitCover || fit == Sn.fitNone {
            r.clip()
        }
        NSGraphicsContext.current?.imageInterpolation = smooth ? .high : .none
        img.draw(in: d, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        return d
    }

    /// The terminal's bitmap font (TERMinator's window manager draws with the same one: RainwireDesk.loadFont); nil
    /// without it.
    private func sCellFont() -> WmFont? {
        if cellFont != nil || cellFontTried {
            return cellFont
        }
        cellFontTried = true
        if let info = NativeBridge.shared.getFontBitmap(), info.width == 8, info.height > 0, info.height <= 32,
           info.data.count >= 256 * info.height {
            cellFont = WmFont(data: [UInt8](info.data), height: info.height)
        }
        return cellFont
    }

    /// ARGB words (0xAARRGGBB) as an image, as WmPaint.image makes them, its interpolation the block's.
    private static func sCGImage(_ px: [UInt32], _ w: Int, _ h: Int, _ smooth: Bool) -> CGImage? {
        guard w > 0, h > 0, px.count >= w * h else { return nil }
        let data = px.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                                | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: smooth, intent: .defaultIntent)
    }

    /// A cells block painted once into a picture, 8 x the font's height pixels a cell, exactly as the window manager
    /// paints a window (WmPaint.glyph): unset colors light gray on clear. Without the font, the backgrounds and each
    /// character in the mono font instead.
    private func sCellsImage(_ b: SBlock) -> NSImage? {
        let d = Self.sCellDims(b)
        guard d.cols > 0, d.rows > 0 else { return nil }
        let font = sCellFont()
        let fh = font?.height ?? 16, pw = d.cols * 8, ph = d.rows * fh
        let smooth = b.flag(Sn.pSmooth)
        if !b.cellsDirty, b.cellsSmooth == smooth, let img = b.cellsImage, Int(img.size.width) == pw,
           Int(img.size.height) == ph {
            return img
        }
        var px = [UInt32](repeating: 0, count: pw * ph)
        let blank = SCell(ch: 32, fg: Self.none, bg: Self.none)
        for y in 0..<d.rows {
            let row = y < b.cells.count ? b.cells[y] : []
            for x in 0..<d.cols {
                let c = x < row.count ? row[x] : blank
                let fg: UInt32 = c.fg & 0xFF00_0000 != 0 ? 0xFFAA_AAAA : 0xFF00_0000 | c.fg
                let bg: UInt32 = c.bg & 0xFF00_0000 != 0 ? 0 : 0xFF00_0000 | c.bg
                WmPaint.glyph(&px, pw, x, y, c.ch, fg, bg, font, fh)
            }
        }
        guard let cg = Self.sCGImage(px, pw, ph, smooth) else { return nil }
        let size = NSSize(width: pw, height: ph)
        var img = NSImage(cgImage: cg, size: size)
        if font == nil {
            let cells = b.cells, rows = d.rows, cols = d.cols
            img = NSImage(size: size, flipped: true) { _ in
                NSImage(cgImage: cg, size: size).draw(in: NSRect(origin: .zero, size: size), from: .zero,
                                                      operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                let mf = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
                for y in 0..<min(rows, cells.count) {
                    for x in 0..<min(cells[y].count, cols) {
                        let c = cells[y][x]
                        if c.ch == 0 || c.ch == 32 || c.ch == 255 {
                            continue
                        }
                        let t = RainwireMenuView.text(String(Cp437.toChar(c.ch)), mf,
                                                      c.fg & 0xFF00_0000 != 0 ? 0xAA_AAAA : c.fg)
                        let ts = t.size()
                        t.draw(at: CGPoint(x: CGFloat(x * 8) + (8 - ts.width) / 2,
                                           y: CGFloat(y * fh) + (CGFloat(fh) - ts.height) / 2))
                    }
                }
                return true
            }
        }
        b.cellsImage = img
        b.cellsDirty = false
        b.cellsSmooth = smooth
        return img
    }

    /// A bar: its fill to P_VALUE percent (below 0: a piece sliding to and fro, busy), its label right of it.
    private func sDrawProgress(_ b: SBlock) {
        let su = self.su, v = b.real(Sn.pValue)
        let r = b.inner
        let label = b.str(Sn.pLabel)
        var lw: CGFloat = 0
        if !label.isEmpty {
            let f = font(false, sSmallSize)
            let t = Self.text(Self.fitText(label, f, max(r.width * 0.5, 1)), f, scol(.dim))
            let tw = t.size().width
            lw = tw + 0.6 * su
            t.draw(at: CGPoint(x: r.maxX - tw, y: Self.capY(f, r.midY)))
        }
        let th = min(0.5 * su, r.height), rad = th / 2
        let track = Self.sR(r.minX, r.minY + (r.height - th) / 2, r.width - lw, th)
        sFillRR(track, rad, scol(.text), 40.0 / 255)
        let fill = Self.ucol(b, Sn.pFg) ?? sRoleColor(b, scol(.accent))
        if v < 0 {
            let seg = track.width * 0.3, t = (nowMs / 1300).truncatingRemainder(dividingBy: 2)
            var f = CGFloat(t < 1 ? t : 2 - t)
            f = f * f * (3 - 2 * f)
            sFillRR(Self.sR(track.minX + (track.width - seg) * f, track.minY, seg, th), rad, fill)
        } else if v > 0 {
            sFillRR(Self.sR(track.minX, track.minY, track.width * min(v, 100) / 100, th), rad, fill)
        }
    }

    /// A key as a label shows it.
    private static func sKeyName(_ key: Int) -> String {
        switch key {
        case 27: return "Esc"
        case 13: return "Enter"
        case 32: return "Space"
        case 9: return "Tab"
        case 8: return "Backspace"
        default:
            guard key > 32, let sc = Unicode.Scalar(UInt32(key)) else { return "" }   // nil for surrogates, > 10FFFF
            return String(Character(sc))
        }
    }

    /// A button: rounded, lit under the pointer, a ring when focused, darker while the board answers its press; its
    /// label centered, the hotkey in it marked ("K Keep": the K in the hot color; else the key's first letter
    /// underlined).
    private func sDrawButton(_ s: SceneTree, _ b: SBlock) {
        let size = sSize
        let r = b.box
        let hot = b.num(Sn.pRole) == Sn.rHot, focus = sFocused(s, b), hover = s === scene && !waiting && sIsHover(b)
        let pressed = s === scene && waiting && scenePressed != 0 && scenePressed == b.id
        var bg = Self.ucol(b, Sn.pBg) ?? (hot ? scol(.buttonHot) : scol(.buttonBg))
        let fg = Self.ucol(b, Sn.pFg) ?? (hot ? scol(.selFg) : scol(.buttonFg))
        if pressed {
            bg = Self.mix(bg, 0, 0.25)
        } else if hover {
            bg = hot ? Self.mix(bg, 0xFF_FFFF, 0.15) : Self.mix(bg, scol(.buttonHot), 0.3)
        }
        let box = Self.sInset(r, 0.5 * u)
        let rad = min(box.height / 2, max(st.selRadius, 4) * u)
        let path = NSBezierPath(roundedRect: box, xRadius: rad, yRadius: rad)
        Self.color(bg).setFill()
        path.fill()
        Self.color(focus ? (hot ? scol(.focus) : scol(.buttonHot)) : scol(.border), focus ? 1 : 200.0 / 255).setStroke()
        path.lineWidth = (focus ? 2 : 1) * u
        path.stroke()
        let px = sButtonPadX(b)
        let room = Self.sR(r.minX + px, r.minY, r.width - 2 * px, r.height)
        let f = font(true, size)
        let spans = b.spans(Sn.pSpans)
        if !spans.isEmpty {
            let tw = spans.reduce(CGFloat(0)) { $0 + Self.textW($1.text, f) }
            let x = room.minX + max((room.width - tw) / 2, 0)
            drawSpans(f, spans, x, r.minY, room.maxX - x, r.height, fg, bg)
            return
        }
        let label = b.str(Sn.pLabel)
        guard !label.isEmpty, room.width > 0 else { return }
        let shown = Self.fitText(label, f, room.width + u)   // + u: a button at its natural width cut its label ("Answ…")
        let t = NSMutableAttributedString(attributedString: Self.text(shown, f, fg))
        let sl = (shown as NSString).length
        let key = b.num(Sn.pKey)
        let name = Self.sKeyName(key)
        let ln = label as NSString
        let prefix = name.isEmpty ? NSRange(location: NSNotFound, length: 0)
            : ln.range(of: name, options: [.caseInsensitive, .anchored])
        let underline = NSUnderlineStyle.single.rawValue
        if prefix.location == 0 && prefix.length < ln.length && ln.character(at: prefix.length) == 0x20 {
            let range = NSRange(location: 0, length: min(prefix.length, sl))
            if hot {
                t.addAttribute(.underlineStyle, value: underline, range: range)
            } else {
                t.addAttribute(.foregroundColor, value: Self.color(scol(.buttonHot)), range: range)
            }
        } else if !name.isEmpty && key > 32 {
            let at = (shown as NSString).range(of: name, options: .caseInsensitive)
            if at.location != NSNotFound {
                t.addAttribute(.underlineStyle, value: underline, range: at)
                if !hot {
                    t.addAttribute(.foregroundColor, value: Self.color(scol(.buttonHot)), range: at)
                }
            }
        }
        let tw = t.size().width
        t.draw(at: CGPoint(x: room.minX + max((room.width - tw) / 2, 0), y: Self.capY(f, r.midY)))
    }

    /// A text field as the forms draw theirs: rounded, lit and marked when focused, the caret blinking, the placeholder
    /// while empty, a secret as dots; more lines when P_MULTI, scrolled to the caret.
    private func sDrawField(_ s: SceneTree, _ b: SBlock) {
        let su = self.su, size = sSize
        let r = b.box
        let on = sFocused(s, b), multi = b.flag(Sn.pMulti), secret = b.flag(Sn.pSecret)
        let bg = Self.ucol(b, Sn.pBg) ?? scol(.fieldBg), fg = Self.ucol(b, Sn.pFg) ?? scol(.fieldFg)
        let fr = st.selRadius * u
        let path = NSBezierPath(roundedRect: Self.sInset(r, 0.5 * u), xRadius: fr, yRadius: fr)
        Self.color(bg, on ? 1 : 200.0 / 255).setFill()
        path.fill()
        Self.color(on ? scol(.focus) : scol(.border), on ? 1 : 150.0 / 255).setStroke()
        path.lineWidth = (on ? 1.5 : 1) * u
        path.stroke()
        if on && st.marker {
            Self.color(scol(.focus)).setFill()
            CGRect(x: r.minX, y: r.minY, width: 3 * u, height: r.height).fill()
        }
        let room = Self.sR(r.minX + 0.5 * su, r.minY, r.width - su, r.height)
        let caretOn = on && !waiting && (Date().timeIntervalSince(caretAt) < 0.6 || Int(nowMs / 530) % 2 == 0)
        let shown: [Character] = secret ? Array(repeating: "\u{2022}", count: b.value.count) : b.value
        let cur = min(max(b.cur, 0), b.value.count)
        let f = font(false, size)
        NSGraphicsContext.saveGraphicsState()
        room.clip()
        let place = b.str(Sn.pPlace)
        if b.value.isEmpty && !place.isEmpty {
            Self.text(Self.fitText(place, f, max(room.width, 1)), f, scol(.dim))
                .draw(at: CGPoint(x: room.minX, y: multi ? r.minY + 0.3 * su : Self.capY(f, r.midY)))
        }
        if !multi || secret {
            let cxw = Self.textW(String(shown[0..<cur]), f)
            let shift = cxw > room.width - 4 * u ? cxw - (room.width - 4 * u) : 0
            Self.text(String(shown), f, fg).draw(at: CGPoint(x: room.minX - shift, y: Self.capY(f, r.midY)))
            if caretOn {
                Self.color(scol(.focus)).setFill()
                Self.sR(room.minX - shift + cxw, r.minY + 0.3 * su, 2 * u, r.height - 0.6 * su).fill()
            }
            b.textX = room.minX - shift
        } else {
            // version 6: lines wrapped by words at the field's width (or P_WRAPCOLS), as typed (the fourth extension);
            // no shift sideways any more
            let lh = sFieldLineH(), top = r.minY + 0.3 * su, viewH = max(r.height - 0.6 * su, lh)
            let vl = sWrapValue(b, shown, f, room.width - 4 * u)
            b.vLines = vl
            let line = Self.sVLineOf(vl, cur)
            let cy = CGFloat(line) * lh
            if cy - b.scroll > viewH - lh {
                b.scroll = cy - (viewH - lh)
            }
            if cy < b.scroll {
                b.scroll = cy
            }
            b.scroll = max(b.scroll, 0)
            let cxw = Self.textW(String(shown[min(vl[line].start, cur)..<cur]), f)
            for i in vl.indices {
                let y = top + CGFloat(i) * lh - b.scroll
                if y + lh < r.minY || y > r.maxY {
                    continue
                }
                Self.text(String(shown[vl[i].start..<vl[i].end]), f, fg).draw(at: CGPoint(x: room.minX, y: y))
            }
            if caretOn {
                Self.color(scol(.focus)).setFill()
                Self.sR(room.minX + cxw, top + cy - b.scroll + 2 * u, 2 * u, lh - 4 * u).fill()
            }
            b.textX = room.minX
            b.textY = top - b.scroll
            b.lineH = lh
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// A choice as a row of pills (wrapping when they don't fit): the chosen one filled, a ring on it when focused.
    private func sDrawChoice(_ s: SceneTree, _ b: SBlock) {
        let r = b.box
        let opts = b.strs(Sn.pOptions)
        let on = sFocused(s, b)
        let f = font(false, sSize)
        b.hits.removeAll()
        let places = sPillPlaces(b, r.width)
        for i in 0..<min(places.count, opts.count) {
            let pill = places[i].offsetBy(dx: r.minX, dy: r.minY)
            let rad = pill.height / 2
            let sel = i == b.index
            let hv = s === scene && !b.off && pointer.map { pill.contains($0) && b.clip.contains($0) } == true
            if sel {
                sFillRR(pill, rad, scol(.selBg))
                if on {
                    sStrokeRR(pill, rad, 2 * u, scol(.focus))
                }
            } else {
                if hv {
                    sFillRR(pill, rad, scol(.selBg), 60.0 / 255)
                }
                sStrokeRR(pill, rad, 1 * u, on ? scol(.focus) : scol(.border), 160.0 / 255)
            }
            let t = Self.text(Self.fitText(opts[i], f, pill.width), f, sel ? scol(.selFg) : Self.ucol(b, Sn.pFg) ?? scol(.text))
            t.draw(at: CGPoint(x: pill.minX + (pill.width - t.size().width) / 2, y: Self.capY(f, pill.midY)))
            b.hits.append((rect: pill, i: i))
        }
    }

    /// A checkbox and its label: filled with a tick when on, a ring when focused.
    private func sDrawCheck(_ s: SceneTree, _ b: SBlock) {
        let su = self.su
        let r = b.box
        let on = sFocused(s, b), hv = s === scene && sIsHover(b)
        let bs = max(min(0.9 * su, r.height - 2 * u), 4 * u)
        let box = CGRect(x: r.minX + 0.1 * su, y: r.minY + (r.height - bs) / 2, width: bs, height: bs)
        let fill = b.on ? scol(.accent) : hv ? Self.mix(scol(.fieldBg), scol(.selBg), 0.3) : scol(.fieldBg)
        sFillRR(box, 3 * u, fill)
        sStrokeRR(box, 3 * u, (on ? 2 : 1) * u, on ? scol(.focus) : scol(.border), on ? 1 : 200.0 / 255)
        if b.on {
            let tick = NSBezierPath()
            tick.move(to: CGPoint(x: box.minX + bs * 0.22, y: box.minY + bs * 0.52))
            tick.line(to: CGPoint(x: box.minX + bs * 0.42, y: box.minY + bs * 0.72))
            tick.line(to: CGPoint(x: box.minX + bs * 0.78, y: box.minY + bs * 0.30))
            tick.lineWidth = 2 * u
            tick.lineCapStyle = .round
            tick.lineJoinStyle = .round
            Self.color(Self.luma(fill) > 140 ? 0x10_1010 : 0xFF_FFFF).setStroke()
            tick.stroke()
        }
        let label = b.str(Sn.pLabel)
        guard !label.isEmpty else { return }
        let lx = box.maxX + 0.5 * su
        let f = font(false, sSize)
        Self.text(Self.fitText(label, f, max(r.maxX - lx, 1)), f, Self.ucol(b, Sn.pFg) ?? scol(.text))
            .draw(at: CGPoint(x: lx, y: Self.capY(f, r.midY)))
    }

    /// A list's columns' left edges and widths across w: P_WIDTHS in units, those of 0 (or none) sharing the rest.
    private func sListCols(_ b: SBlock, _ x0: CGFloat, _ w: CGFloat, _ n: Int) -> (x: [CGFloat], w: [CGFloat]) {
        let ws = b.f32s(Sn.pWidths)
        let su = self.su
        var fix: CGFloat = 0
        var flex = 0
        for c in 0..<n {
            if c < ws.count && ws[c] > 0 {
                fix += ws[c] * su
            } else {
                flex += 1
            }
        }
        let scale: CGFloat = flex == 0 && fix > w ? w / fix : fix > w ? 0.5 * w / fix : 1
        let rest = max(w - fix * scale, 0)
        var cx = [CGFloat](repeating: 0, count: n), cw = [CGFloat](repeating: 0, count: n)
        var x = x0
        for c in 0..<n {
            cw[c] = c < ws.count && ws[c] > 0 ? ws[c] * su * scale : rest / CGFloat(max(flex, 1))
            cx[c] = x
            x += cw[c]
        }
        return (cx, cw)
    }

    /// A list's items (its BK_ITEM children; an item's index is its place among them).
    private static func sItems(_ list: SBlock) -> [SBlock] { list.kids.filter { $0.kind == Sn.bkItem } }

    private static func sItemOk(_ it: SBlock) -> Bool { !it.flag(Sn.pHidden) && it.num(Sn.pIFlags) & Sn.ifHeading == 0 }

    /// A list as today's lists: column titles and a rule, items as rows 1.5 units tall (headings bold in the second
    /// accent, never selected; bold and dim items), the selection lit (dimmer without the focus), scrolled to it.
    private func sDrawList(_ s: SceneTree, _ b: SBlock) {
        let su = self.su, size = sSize, rowH = 1.5 * su
        let r = b.box
        let on = sFocused(s, b)
        let fr = st.selRadius * u
        let outline = Self.sInset(r, 0.5 * u)
        if let lbg = Self.ucol(b, Sn.pBg) {
            sFillRR(outline, fr, lbg)
        }
        sStrokeRR(outline, fr, 1 * u, on ? scol(.focus) : scol(.border), (on ? 220.0 : 110.0) / 255)
        let inner = Self.sInset(r, 0.3 * su)
        let heads = b.strs(Sn.pHeaders)
        let items = Self.sItems(b)
        var ncols = max(heads.count, max(b.f32s(Sn.pWidths).count, 1))
        for it in items {
            ncols = max(ncols, min(it.strs(Sn.pCellText).count, 16))
        }
        let rowsW = max(inner.width - 10 * u, 1)
        let cols = sListCols(b, inner.minX, rowsW, ncols)
        let uf = font(false, size), bf = font(true, size)
        var y = inner.minY
        if !heads.isEmpty {
            for c in 0..<min(heads.count, ncols) where !heads[c].isEmpty && cols.w[c] > 8 * u {
                Self.text(Self.fitText(heads[c], bf, cols.w[c] - 8 * u), bf, scol(.accent))
                    .draw(at: CGPoint(x: cols.x[c] + 4 * u, y: Self.capY(bf, y + rowH / 2)))
            }
            Self.color(scol(.border), 160.0 / 255).setFill()
            Self.sR(inner.minX, y + rowH, inner.width, max(1 * u, 1)).fill(using: .sourceOver)
            y += rowH + 0.2 * su
        }
        let view = Self.sR(inner.minX, y, inner.width, inner.maxY - y)
        var total: CGFloat = 0, selY: CGFloat = -1
        for (i, it) in items.enumerated() where !it.flag(Sn.pHidden) {
            if i == b.index {
                selY = total
            }
            total += rowH
        }
        b.view = view.height
        b.scrollMax = max(total - view.height, 0)
        if b.showSel && selY >= 0 {
            if selY < b.scroll {
                b.scroll = selY
            }
            if selY + rowH > b.scroll + view.height {
                b.scroll = selY + rowH - view.height
            }
            b.showSel = false
        }
        b.scroll = min(max(b.scroll, 0), b.scrollMax)
        b.hits.removeAll()
        NSGraphicsContext.saveGraphicsState()
        view.clip()
        var yy: CGFloat = 0
        let sr = st.selRadius * u
        for (i, it) in items.enumerated() where !it.flag(Sn.pHidden) {
            let ry = view.minY + yy - b.scroll
            yy += rowH
            if ry + rowH < view.minY || ry > view.maxY {
                continue
            }
            let flags = it.num(Sn.pIFlags)
            let heading = flags & Sn.ifHeading != 0, sel = !heading && i == b.index
            let bar = Self.sR(view.minX, ry + 1 * u, rowsW, rowH - 2 * u)
            if sel {
                sFillRR(bar, sr, scol(.selBg), on ? 1 : 150.0 / 255)
                if st.marker && on {
                    Self.color(scol(.focus)).setFill()
                    CGRect(x: bar.minX, y: bar.minY, width: 3 * u, height: bar.height).fill()
                }
            } else if !heading && s === scene && !b.off && pointer.map({ bar.contains($0) && b.clip.contains($0) }) == true {
                sFillRR(bar, sr, scol(.selBg), 60.0 / 255)
            }
            let f = heading || flags & Sn.ifBold != 0 ? bf : uf
            let col = sel ? scol(.selFg) : heading ? scol(.accent2)
                : Self.ucol(it, Sn.pFg) ?? (flags & Sn.ifDim != 0 ? scol(.dim) : scol(.text))
            let texts = it.strs(Sn.pCellText)
            if heading {
                Self.text(Self.fitText(texts.joined(separator: "  "), f, max(rowsW - 8 * u, 1)), f, col)
                    .draw(at: CGPoint(x: view.minX + 4 * u, y: Self.capY(f, ry + rowH / 2)))
                continue
            }
            for c in 0..<min(texts.count, ncols) where cols.w[c] > 8 * u && !texts[c].isEmpty {
                Self.text(Self.fitText(texts[c], f, cols.w[c] - 8 * u), f, col)
                    .draw(at: CGPoint(x: cols.x[c] + 4 * u, y: Self.capY(f, ry + rowH / 2)))
            }
            b.hits.append((rect: CGRect(x: view.minX, y: ry, width: rowsW, height: rowH).intersection(view), i: i))
        }
        NSGraphicsContext.restoreGraphicsState()
        sScrollbar(view, b.scroll, b.scrollMax, false, s, b)
    }

    /// A thin bar on view's right (or bottom) edge when there's more than shows; the thumb at least 24 units (or the
    /// whole bar, when that's shorter). Version 6: wider under the pointer, the dragged thumb in the accent, and kept
    /// (s.bars, for block b; nil: the scene's own) so it can be dragged (the fourth extension).
    private func sScrollbar(_ view: CGRect, _ scroll: CGFloat, _ maxScroll: CGFloat, _ horiz: Bool, _ s: SceneTree? = nil,
                            _ b: SBlock? = nil) {
        guard maxScroll > 0, !view.isEmpty else { return }
        let c = scol(.border)
        let track = horiz ? Self.sR(view.minX, view.maxY - 10 * u, view.width, 10 * u)
                          : Self.sR(view.maxX - 10 * u, view.minY, 10 * u, view.height)
        let dragged = s != nil && (drag6.map { $0.kind == .bar && $0.s === s && $0.b === b } ?? false)
        let hot = dragged || (pointer.map { track.contains($0) } ?? false)
        let t = hot ? 7 * u : 4 * u, off = hot ? 8 * u : 6 * u, a = t / 2
        let trackA = CGFloat(hot ? 80 : 50) / 255
        let thumbC = dragged ? scol(.accent) : c
        if horiz {
            let iw = view.width
            let tw = min(max(iw * iw / (iw + maxScroll), min(24 * u, iw)), iw)
            let tx = view.minX + (iw - tw) * (scroll / maxScroll)
            sFillRR(CGRect(x: view.minX, y: view.maxY - off, width: iw, height: t), a, c, trackA)
            sFillRR(CGRect(x: tx, y: view.maxY - off, width: tw, height: t), a, thumbC, 220.0 / 255)
            s?.bars.append(SBar(b: b, track: track, thumb: Self.sR(tx, track.minY, tw, track.height), horiz: true,
                                scrollMax: maxScroll, room: iw - tw))
            return
        }
        let ih = view.height
        let th = min(max(ih * ih / (ih + maxScroll), min(24 * u, ih)), ih)
        let ty = view.minY + (ih - th) * (scroll / maxScroll)
        sFillRR(CGRect(x: view.maxX - off, y: view.minY, width: t, height: ih), a, c, trackA)
        sFillRR(CGRect(x: view.maxX - off, y: ty, width: t, height: th), a, thumbC, 220.0 / 255)
        s?.bars.append(SBar(b: b, track: track, thumb: Self.sR(track.minX, ty, track.width, th), horiz: false,
                            scrollMax: maxScroll, room: ih - th))
    }

    /// P_TOOLTIP of what's under the pointer, once it has rested there half a second.
    private func sceneTooltip(_ s: SceneTree, _ w: CGFloat, _ h: CGFloat) {
        guard Date().timeIntervalSince(sceneMoveAt) >= 0.5, let mouse = pointer else { return }
        var hit: SBlock?
        for b in s.order.reversed() where b.pass == s.pass && b.has(Sn.pTooltip) && b.box.contains(mouse)
            && b.clip.contains(mouse) {
            hit = b
            break
        }
        guard let tip = hit else { return }
        let t = Self.text(tip.str(Sn.pTooltip), font(false, 13), scol(.text))
        let maxW = max(min(400 * u, w - 40 * u), 1)
        let tb = t.boundingRect(with: NSSize(width: maxW, height: 10_000), options: [.usesLineFragmentOrigin, .usesFontLeading])
        let tw = ceil(tb.width), th = ceil(tb.height)
        let bw = tw + 16 * u, bh = th + 10 * u
        var bx = mouse.x + 14 * u, by = mouse.y + 18 * u
        if bx + bw > w - 4 * u {
            bx = max(mouse.x - bw - 10 * u, 4 * u)
        }
        if by + bh > h - 4 * u {
            by = max(mouse.y - bh - 6 * u, 4 * u)
        }
        let box = CGRect(x: bx, y: by, width: bw, height: bh)
        sFillRR(box.offsetBy(dx: 2 * u, dy: 3 * u), 6 * u, 0, 90.0 / 255)
        sFillRR(box, 6 * u, Self.mix(scol(.panel), 0, 0.25), 245.0 / 255)
        sStrokeRR(box, 6 * u, 1 * u, scol(.border))
        t.draw(with: CGRect(x: bx + 8 * u, y: by + 5 * u, width: tw + 1, height: th + 1),
               options: [.usesLineFragmentOrigin, .usesFontLeading])
    }

    // ================================================================
    // Input (docs/SCENES.md "Events"; handleKey, mouseMoved, mouseUp and scrollWheel branch here when isScene)
    // ================================================================

    /// A control that can have the focus: an id (else it sends nothing), placed, not disabled.
    private static func sFocusable(_ s: SceneTree, _ b: SBlock) -> Bool {
        b.id != 0 && b.pass == s.pass && !b.off
            && ((sIsControl(b.kind)
                 // a list nothing is picked in (MRC's log) leaves the keys where they were
                 && !(b.kind == Sn.bkVList && b.num(Sn.pSelect) == 0 && !b.flag(Sn.pPane)))
                // version 6: a pane takes the focus (its keys) when clicked or tabbed to
                || (b.kind == Sn.bkScroll && b.flag(Sn.pPane)))
    }

    private static func sceneFocused(_ s: SceneTree) -> SBlock? {
        guard s.focus != 0, let b = s.byId[s.focus], sFocusable(s, b) else { return nil }
        return b
    }

    private static func sFocusables(_ s: SceneTree) -> [SBlock] { s.order.filter { sFocusable(s, $0) } }

    private func sFocusTo(_ s: SceneTree, _ b: SBlock) {
        s.focus = b.id
        caretAt = Date()
        sceneIntoView(s, b)
    }

    /// Tab / Shift+Tab: the next or previous control in the tree's order, round; false when there's none.
    private func sFocusStep(_ s: SceneTree, _ d: Int) -> Bool {
        let list = Self.sFocusables(s)
        guard !list.isEmpty else { return false }
        let at = Self.sceneFocused(s).flatMap { f in list.firstIndex(where: { $0 === f }) } ?? -1
        sFocusTo(s, list[at < 0 ? (d > 0 ? 0 : list.count - 1) : (at + d + list.count) % list.count])
        return true
    }

    /// An arrow: the nearest control that way (as the menus' move2D); false when there's none.
    private func sFocusMove(_ s: SceneTree, _ f: SBlock?, _ dx: Int, _ dy: Int) -> Bool {
        let list = Self.sFocusables(s)
        guard !list.isEmpty else { return false }
        guard let f = f else {
            sFocusTo(s, dx + dy > 0 ? list[0] : list[list.count - 1])
            return true
        }
        let cur = f.box
        var best: SBlock?
        var bestD = CGFloat.greatestFiniteMagnitude
        for b in list where b !== f {
            let ddx = b.box.midX - cur.midX, ddy = b.box.midY - cur.midY
            if dx != 0 && (dx > 0 ? ddx <= 1 : ddx >= -1) {
                continue
            }
            if dy != 0 && (dy > 0 ? ddy <= 1 : ddy >= -1) {
                continue
            }
            let d = dx != 0 ? abs(ddx) + 3 * abs(ddy) : abs(ddy) + 3 * abs(ddx)
            if d < bestD {
                bestD = d
                best = b
            }
        }
        guard let to = best else { return false }
        sFocusTo(s, to)
        return true
    }

    /// k and cp the same key: equal, or letters either case.
    private static func sKeyMatch(_ k: Int, _ cp: Int) -> Bool {
        if k == cp {
            return true
        }
        guard k > 32, k < 0x10000, cp > 32, cp < 0x10000,
              let a = Unicode.Scalar(UInt32(k)), let b = Unicode.Scalar(UInt32(cp)) else { return false }
        return String(Character(a)).uppercased() == String(Character(b)).uppercased()
    }

    /// The button whose P_KEY is cp (letters either case), placed and enabled.
    private static func sHotkeyButton(_ s: SceneTree, _ cp: Int) -> SBlock? {
        s.order.first { b in
            b.kind == Sn.bkButton && b.pass == s.pass && !b.off && b.id != 0 && b.has(Sn.pKey) && sKeyMatch(b.num(Sn.pKey), cp)
        }
    }

    /// The board said nothing for 2 s after a press, submit or key (one it had no answer for): input again.
    private func sceneWaitCheck() {
        if waiting && Date().timeIntervalSince(sceneWaitAt) > 2 {
            waiting = false
            scenePressed = 0
        }
    }

    private func sceneWait(_ pressed: UInt16) {
        waiting = true
        sceneWaitAt = Date()
        scenePressed = pressed
    }

    /// Every field's value, for Submit and a submitting Press: repeated u16 id, u16 len, UTF-8, in base64.
    private static func sceneFieldsB64(_ s: SceneTree) -> String {
        var bytes: [UInt8] = []
        func walk(_ b: SBlock) {
            if (b.kind == Sn.bkField || b.kind == Sn.bkInput) && b.id != 0 {
                let v = Array(String(b.value).utf8)
                let n = min(v.count, 0xFFFF)
                bytes += [UInt8(b.id & 0xFF), UInt8(b.id >> 8), UInt8(n & 0xFF), UInt8(n >> 8)]
                bytes += v[0..<n]
            }
            for k in b.kids {
                walk(k)
            }
        }
        walk(s.top)
        return Data(bytes).base64EncodedString()
    }

    private func scenePress(_ s: SceneTree, _ b: SBlock) {
        guard !waiting, !b.off, b.id != 0 else { return }
        sceneWait(b.id)
        reply("Press;id=\(b.id)" + (b.flag(Sn.pSubmit) ? ";b64=" + Self.sceneFieldsB64(s) : ""))
    }

    private func sceneSubmit(_ s: SceneTree, _ f: SBlock) {
        guard !waiting, !f.off, f.id != 0 else { return }
        sceneWait(0)
        reply("Submit;id=\(f.id);b64=\(Self.sceneFieldsB64(s))")
        if f.kind == Sn.bkInput {
            Self.inputSubmitted(f)
        }
    }

    private func sceneBack() {
        guard !waiting else { return }
        sceneWait(0)
        reply("Back")
    }

    /// A key nothing on the scene used: to the board with the focused block (vk and key as a list's Key); version 3:
    /// with the fields (base64, as a press has them) when a key an input passes needs what's typed.
    private func sceneSendKey(_ s: SceneTree, _ vk: Int, _ alt: Bool, _ ctrl: Bool, _ cp: Int, _ fields: String? = nil) {
        guard !waiting else { return }
        sceneWait(0)
        let shift = NSEvent.modifierFlags.contains(.shift)
        reply("Key;vk=\(vk);key=\(cp);focus=\(Self.sceneFocused(s)?.id ?? 0)" + (alt ? ";alt=1" : "") + (ctrl ? ";ctrl=1" : "")
              + (shift ? ";shift=1" : "") + (fields.map { ";b64=" + $0 } ?? ""))
    }

    /// A key only a screen that asks for it uses (F2-F12 as fn=, Option plus a letter or digit as alt=1;ch=): key=0
    /// so an older board drops it, and no wait for an answer (a screen that doesn't use it sends none).
    private func sceneSendKeyX(_ s: SceneTree, _ what: String) {
        guard !waiting else { return }
        let mods = NSEvent.modifierFlags
        reply("Key;vk=0;key=0;focus=\(Self.sceneFocused(s)?.id ?? 0);\(what)" + (mods.contains(.control) ? ";ctrl=1" : "")
              + (mods.contains(.shift) ? ";shift=1" : ""))
    }

    private func sChoiceSet(_ b: SBlock, _ i: Int) {
        guard !b.off, i != b.index, i >= 0, i < b.strs(Sn.pOptions).count else { return }
        b.index = i
        if b.id != 0 {
            reply("Change;id=\(b.id);i=\(i)")
        }
    }

    private func sCheckToggle(_ b: SBlock) {
        guard !b.off else { return }
        b.on.toggle()
        if b.id != 0 {
            reply("Change;id=\(b.id);on=\(b.on ? 1 : 0)")
        }
    }

    /// A P_LIVE field's value goes as it changes (with P_DEBOUNCE, when typing pauses: the timers send it); every
    /// edit stamps changedAt, which P_AUTOSAVE counts from.
    private func sFieldChanged(_ b: SBlock) {
        b.changedAt = Date()
        guard b.flag(Sn.pLive) && b.id != 0 else { return }
        if b.has(Sn.pDebounce) {
            b.changePending = true
        } else {
            reply("Change;id=\(b.id);b64=\(Data(String(b.value).utf8).base64EncodedString())")
        }
    }

    private func sListSelect(_ b: SBlock, _ i: Int) {
        guard i != b.index else { return }
        b.index = i
        b.showSel = true
        if b.id != 0 {
            reply("Select;id=\(b.id);i=\(i)")
        }
    }

    private func sListActivate(_ b: SBlock, _ i: Int) {
        guard !waiting, !b.off, b.id != 0 else { return }
        sceneWait(0)
        reply("Activate;id=\(b.id);i=\(i)")
    }

    /// A key on the scene (from handleKey, which takes every key but Command shortcuts while the menu is up): the
    /// focused control's own keys, Tab, Esc, Enter, arrows, paging, then typed characters (sceneText).
    func sceneKey(_ event: NSEvent) {
        let code = event.keyCode
        guard let s = scene, complete else {
            if code == 53 {
                newsBack()   // Esc while the scene is still coming
            }
            return
        }
        sceneWaitCheck()
        let flags = event.modifierFlags
        let alt = flags.contains(.option), ctrl = flags.contains(.control), shift = flags.contains(.shift)
        let f = Self.sceneFocused(s)
        // version 2: Esc closes the topmost pop-up first (an input's completion menu closes in sInputKey)
        var inputMenu = false
        if let f = f, f.kind == Sn.bkInput, sOpenMenuFor(s, f) != nil {
            inputMenu = true
        }
        if code == 53 && !inputMenu && sPopClose(s) {
            return
        }
        if f != nil {
            caretAt = Date()
        }
        if let f = f, !alt {
            let used: Bool
            switch f.kind {
            case Sn.bkField: used = sFieldKey(s, f, event, ctrl)
            case Sn.bkInput: used = sInputKey(s, f, event, ctrl, shift) || sInputEdit(s, f, event, ctrl, shift)   // version 2
            case Sn.bkVList: used = sVListKey(s, f, event, ctrl, shift)
            case Sn.bkList: used = !ctrl && sListKey(f, code)
            case Sn.bkChoice: used = !ctrl && (code == 123 || code == 124) && sChoiceStep(f, code == 123 ? -1 : 1)
            case Sn.bkScroll: used = !ctrl && sPaneKey(s, f, code)   // version 6 (the fourth extension)
            case Sn.bkSlider: used = !ctrl && sSliderKey(f, code)
            default: used = false
            }
            if used {
                return
            }
        }
        switch code {
        case 48:                                                     // Tab, Shift+Tab
            if ctrl || !sFocusStep(s, shift ? -1 : 1) {
                sceneSendKey(s, Self.vkTab, alt, ctrl, 0)
            }
        case 53:                                                     // Esc
            if let esc = Self.sHotkeyButton(s, 27) {
                scenePress(s, esc)
            } else {
                sceneBack()
            }
        case 36, 76:                                                 // Return, keypad Enter
            if let f = f, f.kind == Sn.bkButton {
                scenePress(s, f)
            } else if let f = f, f.kind == Sn.bkCheck {
                sCheckToggle(f)
            } else if let enter = Self.sHotkeyButton(s, 13) {
                scenePress(s, enter)
            } else {
                sceneSendKey(s, Self.vkEnter, alt, ctrl, 0)
            }
        case 123, 124, 125, 126:                                     // Left, Right, Down, Up
            let dx = code == 123 ? -1 : code == 124 ? 1 : 0, dy = code == 126 ? -1 : code == 125 ? 1 : 0
            if alt || ctrl || !sFocusMove(s, f, dx, dy) {
                let vk = code == 123 ? Self.vkLeft : code == 124 ? Self.vkRight : code == 126 ? Self.vkUp : Self.vkDown
                sceneSendKey(s, vk, alt, ctrl, 0)
            }
        case 116, 121, 115, 119:                                     // Page Up, Page Down, Home, End
            if alt || ctrl || !sceneScrollKey(s, code) {
                let vk = code == 116 ? Self.vkPgUp : code == 121 ? Self.vkPgDn : code == 115 ? Self.vkHome : Self.vkEnd
                sceneSendKey(s, vk, alt, ctrl, 0)
            }
        case 117: sceneSendKey(s, Self.vkDelete, alt, ctrl, 0)       // Forward Delete
        case 51: sceneSendKey(s, Self.vkBackspace, alt, ctrl, 0)     // Delete (Backspace)
        case 122: sceneSendKey(s, Self.vkF1, alt, ctrl, 0)           // F1
        default:
            if let fn = Self.sFKeys[code], fn >= 2 {   // F2-F12
                sceneSendKeyX(s, "fn=\(fn)")
            } else if ctrl {   // Ctrl+letter: a key, not text
                if let c = event.charactersIgnoringModifiers?.uppercased().unicodeScalars.first,
                   c.value >= 0x41 && c.value <= 0x5A {
                    sceneSendKey(s, Self.vkChar, alt, true, Int(c.value))
                }
            } else if alt, let ch = Self.sAltChar(event) {   // Option+letter or digit (MRC's Alt+1...9, Alt+V)
                sceneSendKeyX(s, "alt=1;ch=\(ch)")
            } else if let chars = event.characters, !chars.isEmpty {
                sceneText(chars)   // typed characters (the keyboard layout's, Shift and dead keys worked out)
            }
        }
    }

    /// Typed text: a focused field takes it; else the first character is a button's hotkey, Space presses a focused
    /// button or toggles a check, a letter picks a focused choice's option it starts, or it goes to the board as a Key.
    private func sceneText(_ text: String) {
        guard let s = scene, complete else { return }
        let f = Self.sceneFocused(s)
        if let f = f, f.kind == Sn.bkInput {   // version 2: limits, "empty+" keys, completion
            sInputText(s, f, text)
            caretAt = Date()
            return
        }
        if let f = f, f.kind == Sn.bkField {
            if sFieldInsert(f, text) {
                sFieldChanged(f)
            }
            caretAt = Date()
            return
        }
        for scalar in text.unicodeScalars {
            let cp = Int(scalar.value)
            if cp < 0x20 || cp == 0x7F || (0xF700...0xF8FF).contains(cp) {   // control and AppKit function-key characters
                continue
            }
            if let hk = Self.sHotkeyButton(s, cp) {
                scenePress(s, hk)
            } else if let f = f, cp == 0x20, f.kind == Sn.bkCheck {
                sCheckToggle(f)
            } else if let f = f, cp == 0x20, f.kind == Sn.bkButton {
                scenePress(s, f)
            } else if let f = f, cp == 0x20, f.kind == Sn.bkChoice {
                sChoiceStep(f, 1)
            } else if let f = f, f.kind == Sn.bkChoice, sChoiceLetter(f, cp) {
                // the option it starts is chosen
            } else {
                sceneSendKey(s, Self.vkChar, false, false, cp)
            }
            break
        }
    }

    /// Cmd+V (handleKey): the clipboard's text into the focused field (version 2: or input, with its limits).
    func scenePaste() {
        guard let s = scene, complete, let f = Self.sceneFocused(s) else { return }
        if f.kind == Sn.bkInput {
            sInputPaste(s, f)
        } else if f.kind == Sn.bkField {
            sScenePasteInto(f)
        } else {
            return
        }
        caretAt = Date()
    }

    /// Paste, to the field's max (one line: its line breaks as spaces).
    private func sScenePasteInto(_ b: SBlock) {
        guard !b.off, let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        let multi = b.flag(Sn.pMulti) && !b.flag(Sn.pSecret)
        let t = text.replacingOccurrences(of: "\r", with: "")
        if sFieldInsert(b, multi ? t : t.replacingOccurrences(of: "\n", with: " ")) {
            sFieldChanged(b)
        }
    }

    @discardableResult
    private func sChoiceStep(_ b: SBlock, _ d: Int) -> Bool {
        let n = b.strs(Sn.pOptions).count
        if n > 0 {
            sChoiceSet(b, ((b.index + d) % n + n) % n)
        }
        return true
    }

    /// A letter picks the next option it starts (round from the chosen one); false when none does.
    private func sChoiceLetter(_ b: SBlock, _ cp: Int) -> Bool {
        let opts = b.strs(Sn.pOptions)
        guard !opts.isEmpty else { return false }
        for k in 1...opts.count {
            let i = ((b.index + k) % opts.count + opts.count) % opts.count
            if let first = opts[i].unicodeScalars.first, Self.sKeyMatch(Int(first.value), cp) {
                sChoiceSet(b, i)
                return true
            }
        }
        return false
    }

    /// A focused list's keys: Up/Down to the next item that isn't a heading (Select), Page Up/Down a view's worth,
    /// Home/End, Enter Activate.
    private func sListKey(_ b: SBlock, _ code: UInt16) -> Bool {
        let items = Self.sItems(b)
        func next(_ from: Int, _ d: Int) -> Int {
            var i = from + d
            while i >= 0 && i < items.count {
                if Self.sItemOk(items[i]) {
                    return i
                }
                i += d
            }
            return -1
        }
        let page = max(Int(b.view / (1.5 * su)) - 1, 1)
        var to = -1
        switch code {
        case 126: to = next(b.index, -1)                             // Up
        case 125: to = next(b.index, 1)                              // Down
        case 115: to = next(-1, 1)                                   // Home
        case 119: to = next(items.count, -1)                         // End
        case 116, 121:                                               // Page Up, Page Down
            let d = code == 116 ? -1 : 1
            var at = b.index
            for _ in 0..<page {
                let n = next(at, d)
                if n < 0 {
                    break
                }
                to = n
                at = n
            }
        case 36, 76:                                                 // Return, keypad Enter
            if b.index >= 0 && b.index < items.count && Self.sItemOk(items[b.index]) {
                sListActivate(b, b.index)
            }
            return true
        default: return false
        }
        if to >= 0 {
            sListSelect(b, to)
        }
        return true
    }

    /// Option plus a letter or a digit-row key: the upper-case letter's or the digit's code point (Windows' Key.A-Z,
    /// D0-D9), else nil.
    private static func sAltChar(_ event: NSEvent) -> Int? {
        if let d = sDigitKeys[event.keyCode], event.keyCode < 80 {   // the digit row, not the keypad (Windows: D0-D9 only)
            return 0x30 + d
        }
        if let c = sLetter(event), let sc = c.unicodeScalars.first {
            return Int(sc.value) - 0x20
        }
        return nil
    }

    /// Page Up/Down, Home, End with nothing focused that takes them: the scroll under the pointer (or the first one
    /// that scrolls), else the whole scene; false when nothing scrolls.
    private func sceneScrollKey(_ s: SceneTree, _ code: UInt16) -> Bool {
        let under = pointer.flatMap { Self.sScrollAt(s, $0, false) }
        let log = s.order.first(where: { $0.kind == Sn.bkVList && $0.flag(Sn.pFollow) && $0.pass == s.pass && $0.scrollMax > 0 })   // a log (MRC's)
        if let sc = under ?? log ?? s.order.first(where: { $0.kind == Sn.bkScroll && $0.pass == s.pass && $0.scrollMax > 0
                                                             && !$0.flag(Sn.pPane) }) {
            if sc.flag(Sn.pPane) {
                return false   // version 5: a pane's keys are the board's (P_SCROLLBY answers)
            }
            let page = sc.view * 0.9
            sSetScroll(sc, code == 116 ? sc.scroll - page : code == 121 ? sc.scroll + page : code == 115 ? 0 : sc.scrollMax)
            return true
        }
        guard s.scrollMax > 0 else { return false }
        let sp = s.space.height * 0.9
        let to = code == 116 ? s.scroll - sp : code == 121 ? s.scroll + sp : code == 115 ? 0 : s.scrollMax
        s.scroll = min(max(to, 0), s.scrollMax)
        sceneArr += 1
        return true
    }

    /// The innermost scroll (or list, with lists) under p that has more than shows.
    private static func sScrollAt(_ s: SceneTree, _ p: CGPoint, _ lists: Bool) -> SBlock? {
        s.order.last { b in
            (b.kind == Sn.bkScroll || b.kind == Sn.bkVList || b.kind == Sn.bkViewer || lists && b.kind == Sn.bkList)
                && b.pass == s.pass && b.scrollMax > 0
                && b.box.contains(p) && b.clip.contains(p)
        }
    }

    /// A focused field's editing keys (the form's, and lines when P_MULTI); true when used.
    private func sFieldKey(_ s: SceneTree, _ b: SBlock, _ event: NSEvent, _ ctrl: Bool) -> Bool {
        let multi = b.flag(Sn.pMulti) && !b.flag(Sn.pSecret)
        let code = event.keyCode
        if ctrl {
            if code == 36 || code == 76 {   // Ctrl+Enter submits
                sceneSubmit(s, b)
                return true
            }
            if event.charactersIgnoringModifiers?.lowercased() == "v" {   // Ctrl+V pastes, as on Windows (Cmd+V too)
                sScenePasteInto(b)
                return true
            }
            return false   // other Ctrl keys go to the board
        }
        if b.off {
            return false
        }
        let v = b.value
        b.cur = min(max(b.cur, 0), v.count)
        switch code {
        case 123:                                                    // Left
            b.cur = max(b.cur - 1, 0)
            return true
        case 124:                                                    // Right
            b.cur = min(b.cur + 1, v.count)
            return true
        case 115:                                                    // Home (version 6: of the drawn, wrapped line)
            b.cur = multi ? sVLineStart(b, v, b.cur) : 0
            return true
        case 119:                                                    // End
            b.cur = multi ? sVLineEnd(b, v, b.cur) : v.count
            return true
        case 51:                                                     // Delete (Backspace)
            if b.cur > 0 {
                b.value.remove(at: b.cur - 1)
                b.cur -= 1
                sFieldChanged(b)
            }
            return true
        case 117:                                                    // Forward Delete
            if b.cur < v.count {
                b.value.remove(at: b.cur)
                sFieldChanged(b)
            }
            return true
        case 36, 76:                                                 // Return, keypad Enter
            if !multi {
                sceneSubmit(s, b)
            } else if sFieldInsert(b, "\n") {
                sFieldChanged(b)
            }
            return true
        case 126, 125:                                               // Up, Down
            if !multi {
                return false   // one line: the arrows move the focus
            }
            if Self.sVLinesNow(b) != nil {   // version 6: by drawn lines (stale just after typing: by its own lines below)
                return sVLineStep(b, v, code == 126 ? -1 : 1)
            }
            let ls = Self.sLineStart(v, b.cur)
            let x = Self.textW(String(v[ls..<b.cur]), font(false, sSize))
            if code == 126 {
                if ls == 0 {
                    return true
                }
                let ps = Self.sLineStart(v, ls - 1)
                b.cur = sColumnAt(v, ps, ls - 1, x)
            } else {
                let le = Self.sLineEnd(v, b.cur)
                if le >= v.count {
                    return true
                }
                b.cur = sColumnAt(v, le + 1, Self.sLineEnd(v, le + 1), x)
            }
            return true
        default:
            return false
        }
    }

    private static func sLineStart(_ v: [Character], _ at: Int) -> Int {
        var i = min(at, v.count) - 1
        while i >= 0 {
            if v[i] == "\n" {
                return i + 1
            }
            i -= 1
        }
        return 0
    }

    private static func sLineEnd(_ v: [Character], _ at: Int) -> Int {
        var i = max(min(at, v.count), 0)
        while i < v.count {
            if v[i] == "\n" {
                return i
            }
            i += 1
        }
        return v.count
    }

    /// The place in v[start..<end] nearest x from the line's start.
    private func sColumnAt(_ v: [Character], _ start: Int, _ end: Int, _ x: CGFloat) -> Int {
        let f = font(false, sSize)
        var at = start
        while true {
            if Self.textW(String(v[start..<at]), f) >= x {
                return at
            }
            if at >= end {
                return end
            }
            at += 1
        }
    }

    /// Typed text into a field at the caret, as far as P_MAX characters and the byte cap allow (one line: the form's
    /// 1000 bytes); true when anything went in.
    private func sFieldInsert(_ b: SBlock, _ text: String) -> Bool {
        guard !b.off else { return false }
        let multi = b.flag(Sn.pMulti) && !b.flag(Sn.pSecret)
        let most = b.num(Sn.pMax), cap = multi ? Sn.fieldMulti : Self.maxValue
        var n = b.value.count, bytes = String(b.value).utf8.count
        b.cur = min(max(b.cur, 0), b.value.count)
        var add: [Character] = []
        for c in text {
            guard let sc = c.unicodeScalars.first else { continue }
            if (sc.value < 0x20 && !(multi && c == "\n")) || sc.value == 0x7F || (0xF700...0xF8FF).contains(sc.value) {
                continue   // control and AppKit function-key characters
            }
            if most > 0 && n >= most {
                break
            }
            let cb = String(c).utf8.count
            if bytes + cb > cap {
                break
            }
            add.append(c)
            n += 1
            bytes += cb
        }
        guard !add.isEmpty else { return false }
        b.value.insert(contentsOf: add, at: b.cur)
        b.cur += add.count
        return true
    }

    /// The control under p (the innermost, drawn last), or nil; version 2: not a hover-only one that's hidden.
    private func sceneHit(_ s: SceneTree, _ p: CGPoint) -> SBlock? {
        s.order.last(where: { Self.sIsControl($0.kind) && $0.pass == s.pass && $0.box.contains(p) && $0.clip.contains(p)
                                  && !sHoverHidden($0) })
    }

    /// The pointer moved (mouseMoved has set the arrow): a hand over controls (version 2: and links, chips and blocks
    /// with click events; not a vlist that doesn't select), an I-beam over fields and inputs; hover redraws.
    func sceneMove(_ p: CGPoint) {
        if sceneDrag6(p) {   // version 6: a scroll bar, divider or slider being dragged (the fourth extension)
            return
        }
        sceneMoveAt = Date()
        pointer = p
        guard let s = scene, complete else { return }
        if let c = sCursorAt6(s, p) {   // version 6: dividers, bars, sliders, canvas tags, charts
            c.set()
        } else if let hit = sceneHit(s, p), !hit.off {
            if hit.kind == Sn.bkField || hit.kind == Sn.bkInput {
                NSCursor.iBeam.set()
            } else if !(hit.kind == Sn.bkVList && hit.num(Sn.pSelect) == 0) {
                NSCursor.pointingHand.set()
            }
        } else if sceneHandAt(s, p) {
            NSCursor.pointingHand.set()
        }
        sMoveEvents(s, p)   // version 6: P_EVENTS move
        needsDisplay = true
    }

    /// A click (on the release): a button presses (and takes the focus), a field takes the focus with the caret under
    /// the pointer, a pill picks its option, a check toggles, a list row is selected (the selected one activated).
    func sceneClick(_ p: CGPoint) {
        guard let s = scene, complete else { return }
        sceneWaitCheck()
        pointer = p
        if sceneClickV2(s, p) {   // version 2: pop-ups, menu buttons, chips, vlist rows, click events, links
            redraw()
            return
        }
        guard let b = sceneHit(s, p), !b.off else {
            if let pane = Self.sPaneAt(s, p) {   // version 6: a click in a pane gives it the keys
                s.focus = pane.id
                redraw()
            }
            return
        }
        if Self.sFocusable(s, b) {
            s.focus = b.id
        }
        caretAt = Date()
        switch b.kind {
        case Sn.bkButton: scenePress(s, b)
        case Sn.bkField, Sn.bkInput: sFieldClick(b, p)
        case Sn.bkChoice:
            if let hit = b.hits.first(where: { $0.rect.contains(p) }) {
                sChoiceSet(b, hit.i)
            }
        case Sn.bkCheck: sCheckToggle(b)
        case Sn.bkList:
            if let hit = b.hits.first(where: { $0.rect.contains(p) }) {
                if hit.i == b.index {
                    sListActivate(b, hit.i)
                } else {
                    sListSelect(b, hit.i)
                }
            }
        default: break
        }
        redraw()
    }

    /// The caret to the click (as the form's): by line, then by the text's width from the field's left.
    private func sFieldClick(_ b: SBlock, _ p: CGPoint) {
        let v = b.value
        if b.flag(Sn.pSecret) {
            b.cur = v.count
            return
        }
        var start = 0, end = v.count
        if b.flag(Sn.pMulti) && b.lineH > 0, let vl = b.vLines, !vl.isEmpty {   // version 6: the drawn (wrapped) lines
            let li = min(max(Int(((p.y - b.textY) / b.lineH).rounded(.down)), 0), vl.count - 1)
            b.cur = sColumnAt(v, min(vl[li].start, v.count), min(Self.sVLineEffEnd(vl, li), v.count), p.x - b.textX)
            return
        }
        if b.flag(Sn.pMulti) && b.lineH > 0 {
            let line = max(Int((p.y - b.textY) / b.lineH), 0)
            var k = 0
            while k < line && Self.sLineEnd(v, start) < v.count {
                start = Self.sLineEnd(v, start) + 1
                k += 1
            }
            end = Self.sLineEnd(v, start)
        }
        b.cur = sColumnAt(v, start, end, p.x - b.textX)
    }

    /// The wheel (version 6: the fourth extension's sWheelIn): a block that takes it (P_EVENTS wheel), a slider, the
    /// scroll, list or viewer under the pointer (sideways: a horizontal one first), the focused pane, else the whole
    /// scene; a trackpad by its points, a mouse wheel 4.5 units a notch.
    func sceneWheel(_ event: NSEvent) {
        guard let s = scene, complete else { return }
        let w = Self.sWheelDelta(event)
        guard w.delta != 0 else { return }
        sWheelIn(s, convert(event.locationInWindow, from: nil), w.delta, w.precise, w.horiz)
        redraw()
    }

    // ================================================================
    // Scene gadgets (Rainwire docs/GADGETS.md): the parts that need this file's own helpers; the column, the buttons
    // and the icons are in RainwireMenu.swift
    // ================================================================

    /// The scene text scale inside a gadget: smaller than a screen's.
    static let gadgetScale: CGFloat = 0.72

    /// A scene packet for a gadget (slot, 3 reserved, then the packet whole): read into its tree as a screen's is.
    /// Over the limits, the gadget is dropped (the menu goes on).
    func onGadgetPart(_ verb: String, _ p: [UInt8], _ path: String?) {
        guard p.count >= 9, let g = gadgets[Int(p[4])] else { return }
        let inner = Array(p[8...])
        var ok = true
        switch verb {
        case "GadgetScene":
            guard inner.count >= 12 else { return }
            let (t, _) = sceneHeadRead(inner)
            t.flags = (t.flags | Sn.sfFull) & ~Sn.sfOver   // it fills its box
            ok = t.want <= Sn.maxBlocks
            g.tree = t
        case "GadgetBlocks":
            if let t = g.tree {
                ok = Self.sceneBlocksInto(t, inner) >= 0
            }
        case "GadgetCells":
            if let t = g.tree {
                sceneCellsInto(t, inner)
            }
        case "GadgetImage":
            if let t = g.tree {
                sceneImageInto(t, inner, path)
            }
        case "GadgetPatch":
            if let t = g.tree {
                ok = scenePatchInto(t, inner)
            }
        case "GadgetDraw":   // version 6: a canvas's drawing (the fourth extension)
            if let t = g.tree {
                sceneDrawInto(t, inner)
            }
        default: break
        }
        if !ok {
            gadgets[g.slot] = nil
        }
        sceneGen += 1
        needsLayout = true
        trayUpdate()   // version 6: one that just became ready may go in the tray (RainwireMenu.swift)
        redraw()
    }

    // version 6: clicks, the wheel, keys and drags in a gadget run as the screen's scene would (inGadget, in the
    // fourth extension); gadgetControlAt, gadgetControl and gadgetWheel are gone (Windows' GadgetControl too)

    /// A gadget's scene in rect inner, at gadgetScale.
    func drawGadgetTree(_ t: SceneTree, _ inner: CGRect) {
        let was = sScale
        sScale = Self.gadgetScale
        defer { sScale = was }
        sDrawTree(t, inner)
    }
}

// ================================================================
// Scenes version 2 and 3
// ================================================================

/// Scenes version 2 (Rainwire docs/SCENES_V2.md): what the four TERMinator modules did (The Wall, Messages, Files, MRC)
/// as general blocks, so those screens can be scenes built on the board. This extension: the new blocks (input, vlist,
/// menu, popover, chip, drawer, viewer), the properties any block may carry (hover toolbars, animations, gradients,
/// glow, accent bars, click events, width ranges), the row ops (OP_ROWS, OP_SCROLLTO, OP_ANIMATE), assets
/// (SceneAsset), and the board's Clipboard, Open, Sound and SceneToast messages. Version 3: flat boxes (P_RADIUS,
/// P_STROKE, P_FILLA) and a row child's share of the row (P_FRAC). The extension above calls in here from its layout,
/// drawing, keys and mouse code.
///
/// Port of the Windows client's `Controls/RainwireSceneV2.cs`, nearly line for line (written 2026-10-22 without a Mac
/// to build on: uncompiled). It is in this file, not one of its own, so the first extension's private helpers are
/// reachable and the Xcode project is unchanged. macOS differences: an input's value is Characters, as a field's;
/// keys come as NSEvents (key codes, P_KEYS names from them); Ctrl or Cmd toggles a vlist row (Windows: Ctrl);
/// the board's sounds are the system's Basso, Ping and Glass.
extension RainwireMenuView {
    /// An asset picture (SceneAsset): registered once a call, shown by number; its pixels.
    struct SAsset {
        let image: NSImage
        let w: Int, h: Int
    }

    /// A piece of an input's text with pipe codes (P_PIPES): its Characters, color, and background.
    struct SPipeRun {
        let start: Int, len: Int
        let fg: UInt32
        let alpha: CGFloat
        let bg: UInt32?
    }

    /// The v2 properties' types (sKeyType asks here for keys it doesn't know).
    private static func sKeyTypeV2(_ k: UInt8) -> UInt8 {
        switch k {
        case Sn.pHoverShow, Sn.pHoverRoot, Sn.pAnim, Sn.pDrift, Sn.pEvents, Sn.pSelectable, Sn.pPane, Sn.pDrop, Sn.pDrag,
             Sn.pPipes, Sn.pCounter, Sn.pComplete, Sn.pHistory, Sn.pPaste, Sn.pMono, Sn.pOlder, Sn.pSeen, Sn.pSelect,
             Sn.pDivider, Sn.pContext, Sn.pSide, Sn.pMenuBtn, Sn.pReport, Sn.pClose, Sn.pOn, Sn.pScale, Sn.pFont,
             Sn.pSortDir, Sn.pSort, Sn.pFillA, Sn.pHoverOnly, Sn.pFitW, Sn.pScaleMax:
            return Sn.tU8
        case Sn.pHoverAsk, Sn.pWMin, Sn.pWMax, Sn.pMaxBytes, Sn.pWarn, Sn.pDebounce, Sn.pAutosave, Sn.pWrapCols,
             Sn.pMaxLines, Sn.pKeep, Sn.pSettle, Sn.pGroup, Sn.pAnchor, Sn.pOpens, Sn.pAnimMs, Sn.pAsset:
            return Sn.tU16
        case Sn.pGrad, Sn.pGlow, Sn.pBar, Sn.pTrigger, Sn.pTotal, Sn.pCount, Sn.pStroke, Sn.pHoverBg: return Sn.tU32
        case Sn.pRowH, Sn.pRadius, Sn.pFrac, Sn.pFracMin, Sn.pFracMax, Sn.pTileMin, Sn.pTileRatio, Sn.pScrollBy: return Sn.tF32
        case Sn.pNewLabel: return Sn.tStr
        case Sn.pKeys: return Sn.tStrs
        default: return sKeyTypeV6(k)   // version 6's (the fourth extension below)
        }
    }

    private static func sIsPop(_ k: UInt8) -> Bool { k == Sn.bkMenu || k == Sn.bkPopover || k == Sn.bkDrawer }

    /// The scene's width in layout units while laying out (P_WMIN/P_WMAX).
    static var sSceneW: CGFloat = 0

    /// Whether b shows at this width (P_WMIN, P_WMAX).
    private static func sWidthOk(_ b: SBlock) -> Bool {
        (!b.has(Sn.pWMin) || sSceneW >= CGFloat(b.num(Sn.pWMin))) && (!b.has(Sn.pWMax) || sSceneW <= CGFloat(b.num(Sn.pWMax)))
    }

    /// Device pixels a point (Windows' _dpi).
    private var sDpi: CGFloat { max(window?.backingScaleFactor ?? 2, 1) }

    // ================================================================
    // Assets (SceneAsset): pictures registered once a call, shown by number
    // ================================================================

    /// A picture's pixels (its first bitmap rep's), else its size.
    private static func sImagePixels(_ img: NSImage) -> (w: Int, h: Int) {
        for rep in img.representations where rep.pixelsWide > 0 && rep.pixelsHigh > 0 {
            return (rep.pixelsWide, rep.pixelsHigh)
        }
        return (Int(img.size.width), Int(img.size.height))
    }

    /// SceneAsset (u16 id after the header; path= the picture-cache file): kept for the call (RainwireMenu.reset).
    func onSceneAsset(_ p: [UInt8], _ path: String?) {
        guard p.count >= 6, let path = path, let img = sceneLoadImage(path) else { return }
        if sceneAssets.count >= 2000 {
            sceneAssets.removeAll()
        }
        let px = Self.sImagePixels(img)
        sceneAssets[Self.sU16(p, 4)] = SAsset(image: img, w: px.w, h: px.h)
        sceneGen += 1
        redraw()
    }

    private func sAsset(_ b: SBlock) -> SAsset? { b.has(Sn.pAsset) ? sceneAssets[b.num(Sn.pAsset)] : nil }

    // ================================================================
    // Board messages: Clipboard, Open, Sound, SceneToast
    // ================================================================

    /// The v2 messages that carry no packet: text is their b64= field decoded (UTF-8), msg the whole message.
    func handleV2(_ verb: String, _ msg: String, _ text: String) {
        switch verb {
        case "Clipboard":
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
        case "Open":
            let low = text.lowercased()
            if low.hasPrefix("https://") || low.hasPrefix("http://") {
                openLink(text)
            }
        case "Sound":
            let name = msg.contains("name=alert") ? "Basso" : msg.contains("name=ping") ? "Ping" : "Glass"   // else chime
            if let snd = NSSound(named: NSSound.Name(name)) {
                snd.play()
            } else {
                NSSound.beep()
            }
        case "SceneToast":
            sceneToast(text, 8)
        default: break
        }
    }

    // ================================================================
    // Patch ops: OP_ROWS, OP_SCROLLTO, OP_ANIMATE
    // ================================================================

    private func scenePatchV2(_ s: SceneTree, _ op: UInt8, _ id: UInt16, _ p: [UInt8], _ o: Int, _ len: Int) -> Bool {
        let end = o + len
        switch op {
        case Sn.opRows:
            guard let v = s.byId[id], v.kind == Sn.bkVList else { return true }
            return sVRows(s, v, p, o, end)
        case Sn.opScrollTo:
            if let t = s.byId[id], len >= 1, o < p.count {
                sScrollToBlock(s, t, p[o] & 1 != 0, p[o] & 2 != 0)
            }
            return true
        case Sn.opAnimate:
            if let a = s.byId[id], len >= 3, o < p.count {
                sStartAnim(a, p[o], Self.sU16(p, o + 1))
            }
            return true
        default:
            return true
        }
    }

    /// An OP_ROWS payload into vlist v: set, insert or remove rows; row records name parents by place.
    private func sVRows(_ s: SceneTree, _ v: SBlock, _ p: [UInt8], _ start: Int, _ end0: Int) -> Bool {
        let end = min(end0, p.count)
        var o = start
        if v.rows == nil {
            v.rows = []
        }
        if o + 7 > end {
            return true
        }
        let mode = p[o]
        let first = Int(min(Self.sU32(p, o + 1), Sn.vMaxRows)), n = Self.sU16(p, o + 5)
        o += 7
        var rows = v.rows ?? []
        let count = rows.count
        if mode == Sn.rowsRemove {
            if first >= count {
                return true
            }
            let k = min(n, count - first)
            for i in first..<(first + k) {
                if let gone = rows[i] {
                    Self.sRowDrop(s, gone)
                }
            }
            rows.removeSubrange(first..<(first + k))
            v.rows = rows
            if v.anchorRow >= first + k {
                v.anchorRow -= k
            } else if v.anchorRow >= first {
                v.anchorRow = first
            }
            Self.sSelShift(v, first, -k)
            v.rowsW = -1
            return true
        }
        var added: [SBlock] = []
        var i = 0
        while i < n && o + 2 <= end {
            let k = Self.sU16(p, o)
            o += 2
            let recs = Self.sReadRecords(p, o, end, k)
            if recs.isEmpty {
                break
            }
            o += recs.reduce(0) { $0 + $1.bytes }
            let root = recs[0]
            root.parent = v
            root.parentId = v.id
            root.depth = v.depth + 1
            for j in 1..<max(recs.count, 1) {
                let pi = Int(recs[j].parentId)
                if pi < 1 || pi > j {
                    continue   // a parent by place comes before its children
                }
                let par = recs[pi - 1]
                recs[j].parent = par
                recs[j].parentId = par.id
                recs[j].depth = par.depth + 1
                if recs[j].depth > Sn.maxDepth {
                    return false
                }
                par.kids.append(recs[j])
            }
            for b in recs {
                if b.id != 0 {
                    s.byId[b.id] = b
                }
                s.bytes += b.bytes
                b.value = Self.sChars(b.str(Sn.pValueStr))
                b.cur = b.value.count
                b.index = b.num(Sn.pIndex)
                b.on = b.flag(Sn.pChecked)
                if b.has(Sn.pAnim) {
                    sStartAnim(b, UInt8(truncatingIfNeeded: b.num(Sn.pAnim)), b.num(Sn.pAnimMs))
                }
            }
            if s.bytes > Sn.maxBytes {
                return false
            }
            added.append(root)
            i += 1
        }
        while rows.count < first {
            rows.append(nil)
        }
        if mode == Sn.rowsInsert {
            rows.insert(contentsOf: added.map { Optional($0) }, at: first)
            if v.anchorRow >= first && first < count {
                v.anchorRow += added.count   // rows above the view: it stays put
            }
            Self.sSelShift(v, first, added.count)
            if first >= count && !v.atEnd && v.flag(Sn.pFollow) {
                v.newCount += added.count   // appended to a log while scrolled back
            }
        } else {
            for (j, r) in added.enumerated() {
                if first + j < rows.count {
                    if let old = rows[first + j] {
                        Self.sRowDrop(s, old)
                    }
                    rows[first + j] = r
                } else {
                    rows.append(r)
                }
            }
        }
        v.rows = rows
        v.rowsW = -1
        return true
    }

    private static func sRowDrop(_ s: SceneTree, _ b: SBlock) {
        if b.id != 0, let y = s.byId[b.id], y === b {
            s.byId[b.id] = nil
        }
        s.bytes -= b.bytes
        for k in b.kids {
            sRowDrop(s, k)
        }
    }

    private static func sSelShift(_ v: SBlock, _ at: Int, _ by: Int) {
        guard !v.sel.isEmpty else { return }
        v.sel = Set(v.sel.map { $0 >= at ? $0 + by : $0 }.filter { $0 >= 0 })
    }

    private static func sVTotal(_ v: SBlock) -> Int { min(max(v.num(Sn.pTotal), v.rows?.count ?? 0), Int(Sn.vMaxRows)) }

    // ================================================================
    // Animations (P_ANIM, OP_ANIMATE)
    // ================================================================

    private func sStartAnim(_ b: SBlock, _ kind: UInt8, _ ms: Int) {
        b.anim = kind
        b.animAt = Date()
        if ms > 0 {
            b.animMs = Double(ms)
        } else {
            switch kind {
            case Sn.animSlide: b.animMs = 450
            case Sn.animGlow: b.animMs = 2600
            case Sn.animFlash: b.animMs = 900
            case Sn.animPop: b.animMs = 320
            default: b.animMs = 400
            }
        }
        redraw()
    }

    /// b's animation now, 0...1 (1: done or none).
    private static func sAnimT(_ b: SBlock) -> CGFloat {
        if b.anim == 0 {
            return 1
        }
        let t = Date().timeIntervalSince(b.animAt) * 1000 / max(b.animMs, 1)
        if t >= 1 {
            b.anim = 0
            return 1
        }
        return CGFloat(max(t, 0))
    }

    /// A block drawn under its animation's transform and opacity (Windows' AnimPush and the pops after it).
    private func sAnimated(_ b: SBlock, _ body: () -> Void) {
        guard b.anim != 0 else {
            body()
            return
        }
        let t = Self.sAnimT(b)
        guard t < 1, let cg = NSGraphicsContext.current?.cgContext else {
            body()
            return
        }
        let r = b.box
        switch b.anim {
        case Sn.animSlide:
            let e = (1 - t) * (1 - t), dpi = sDpi
            cg.saveGState()
            cg.translateBy(x: 0, y: (e * 14 * u * dpi).rounded() / dpi)
            sFaded(min(t * 1.6, 1), body)
            cg.restoreGState()
        case Sn.animFade:
            sFaded(t, body)
        case Sn.animPop:
            let k = 1 + 0.28 * sin(t * .pi)
            cg.saveGState()
            cg.translateBy(x: r.midX, y: r.midY)
            cg.scaleBy(x: k, y: k)
            cg.translateBy(x: -r.midX, y: -r.midY)
            body()
            cg.restoreGState()
        default:
            body()
        }
    }

    /// After a block draws: the glow and flash animations over it.
    private func sAnimAfter(_ b: SBlock) {
        guard b.anim == Sn.animGlow || b.anim == Sn.animFlash || b.anim == Sn.animSlide else { return }
        let t = Self.sAnimT(b)
        guard t < 1 else { return }
        let acc = scol(.accent), r = 6 * u
        if b.anim == Sn.animFlash {
            sFillRR(b.box, r, acc, 90 * sin(t * .pi) / 255)
            return
        }
        // glow (and a slide-in's glow, as the Wall's live posts: 2.6 s from when it came)
        let gt: CGFloat = b.anim == Sn.animGlow ? t : 0
        let fade = 1 - gt
        sFillRR(b.box, r, acc, 45 * fade / 255)
        sStrokeRR(b.box, r, 1.2 * u, acc, 220 * fade / 255)
    }

    // ================================================================
    // Any block's v2 look: accent bar, glow, gradient panel, flat boxes, hover-only blocks
    // ================================================================

    /// Whether a P_HOVERSHOW block is hidden now: its hover root isn't hovered (or selected).
    private func sHoverHidden(_ b: SBlock) -> Bool {
        var x: SBlock? = b
        while let cur = x {
            x = cur.parent
            if cur.flag(Sn.pHoverOnly) {   // P_HOVERONLY: in the flow, shown only while its box (P_HOVERBG) is under the pointer
                var box = cur.parent
                while let bx = box, !bx.has(Sn.pHoverBg) {
                    box = bx.parent
                }
                guard let hb = box, sIsHover(hb) else { return true }
            }
            if !cur.flag(Sn.pHoverShow) {
                continue
            }
            var root = cur.parent
            while let r = root, !r.flag(Sn.pHoverRoot), r.parent?.kind != Sn.bkVList {
                root = r.parent
            }
            guard let rt = root else { return true }
            var sel = false
            if let v = rt.parent, v.kind == Sn.bkVList, let rows = v.rows,
               let i = rows.firstIndex(where: { $0 === rt }) {
                sel = v.sel.contains(i)
            }
            let over = pointer.map { cur.box.contains($0) } ?? false
            if !(sIsHover(rt) || sel || over) {
                return true
            }
        }
        return false
    }

    /// P_BAR and P_GLOW around b, before it draws.
    private func sDrawDecor(_ b: SBlock) {
        if let g = Self.ucol(b, Sn.pGlow) {
            for i in stride(from: 3, through: 1, by: -1) {
                let d = CGFloat(i)
                sStrokeRR(Self.sInset(b.box, -d * u), 8 * u, 2 * d * u, g, CGFloat(40 / i) / 255)
            }
        }
        if let c = Self.ucol(b, Sn.pBar) {
            sFillRR(Self.sR(b.box.minX, b.box.minY + 4 * u, 3 * u, max(b.box.height - 8 * u, 2 * u)), 1.5 * u, c)
        }
    }

    /// A row child's width as a share of the row (P_FRAC of inner, kept within P_FRACMIN...P_FRACMAX lp), or nil.
    private func sFracW(_ k: SBlock, _ inner: CGFloat) -> CGFloat? {
        guard k.has(Sn.pFrac), inner.isFinite else { return nil }
        var w = inner * k.real(Sn.pFrac)
        let lo = k.real(Sn.pFracMin) * u, hi = k.real(Sn.pFracMax) * u
        if hi > 0 {
            w = min(w, hi)
        }
        return max(w, lo)
    }

    /// A row, column, stack or grid's own box, flat as the modules draw theirs: P_BG filled (to P_GRAD across),
    /// P_STROKE its outline, P_RADIUS its corners in the modules' logical pixels, P_FILLA the fill's opacity. Nothing
    /// when it has none of them.
    private func sDrawFlat(_ b: SBlock) {
        var bg = Self.ucol(b, Sn.pBg)
        let line = Self.ucol(b, Sn.pStroke)
        if b.has(Sn.pHoverBg) && !waiting && sIsHover(b), let hb = Self.ucol(b, Sn.pHoverBg) {   // P_HOVERBG: lit under the pointer
            bg = hb
        }
        guard bg != nil || line != nil else { return }
        let lw = max(u, 1)
        let box = line != nil ? Self.sInset(b.box, lw / 2) : b.box
        let r = b.real(Sn.pRadius) * u
        let path = r > 0 ? NSBezierPath(roundedRect: box, xRadius: r, yRadius: r) : NSBezierPath(rect: box)
        if let c = bg {
            let a: CGFloat = b.has(Sn.pFillA) ? CGFloat(b.num(Sn.pFillA)) / 255 : 1   // a wash: the modules' dialogs dim what's behind
            if let c2 = Self.ucol(b, Sn.pGrad), let g = NSGradient(starting: Self.color(c, a), ending: Self.color(c2)) {
                g.draw(in: path, angle: 0)
            } else {
                Self.color(c, a).setFill()
                path.fill()
            }
        }
        if let lc = line {
            Self.color(lc).setStroke()
            path.lineWidth = lw
            path.stroke()
        }
    }

    /// A panel's background as a gradient from its color to P_GRAD and back, corner to corner, drifting when P_DRIFT
    /// (the Wall's topic banner); over the plain fill, with the border again when lineW > 0.
    private func sDrawGradPanel(_ b: SBlock, _ bg: UInt32, _ lineW: CGFloat, _ radius: CGFloat) {
        guard let c2 = Self.ucol(b, Sn.pGrad) else { return }
        let shift = CGFloat(b.flag(Sn.pDrift) ? 0.5 + 0.5 * sin(nowMs / 4000) : 0.5)
        let locs: [CGFloat] = [0, shift, 1]
        let path = NSBezierPath(roundedRect: b.box, xRadius: radius, yRadius: radius)
        let colors = [Self.color(bg), Self.color(Self.mix(bg, c2, 0.75)), Self.color(bg)]
        if let g = NSGradient(colors: colors, atLocations: locs, colorSpace: .sRGB) {
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            g.draw(from: CGPoint(x: b.box.minX, y: b.box.minY), to: CGPoint(x: b.box.maxX, y: b.box.maxY), options: [])
            NSGraphicsContext.restoreGraphicsState()
        }
        if lineW > 0 {
            Self.color(scol(.border)).setStroke()
            path.lineWidth = lineW
            path.stroke()
        }
    }

    // ================================================================
    // Layout of the new blocks
    // ================================================================

    private func sNaturalV2(_ b: SBlock, _ inner: CGFloat, _ fixH: CGFloat) -> CGSize {
        let su = self.su
        switch b.kind {
        case Sn.bkInput:
            let lines = b.flag(Sn.pMulti) ? CGFloat(max(b.num(Sn.pLines, 3), 1)) : 1
            return CGSize(width: 16 * su, height: b.flag(Sn.pMulti) ? 0.6 * su + lines * sFieldLineH() : 1.8 * su)
        // as wide as they're let be; measured with no limit (a row sizing its children), a fixed natural width: an
        // infinite one made the row's sums NaN (Windows)
        case Sn.bkVList: return CGSize(width: inner.isInfinite ? 24 * su : inner, height: fixH > 0 ? fixH : 8 * su)
        case Sn.bkViewer: return CGSize(width: inner.isInfinite ? 24 * su : inner, height: fixH > 0 ? fixH : 12 * su)
        case Sn.bkChip: return sChipSize(b)
        default: return .zero   // pop-ups take no room in the flow
        }
    }

    private func sChipSize(_ b: SBlock) -> CGSize {
        let su = self.su, h = 1.35 * su
        var w = 0.9 * su
        let t = b.str(Sn.pText)
        let f = font(true, sSmallSize)
        if b.has(Sn.pIcon) || b.has(Sn.pAsset) {
            w += 1.0 * su + (!t.isEmpty || b.has(Sn.pCount) ? 0.3 * su : 0)
        }
        if !t.isEmpty {
            w += Self.textW(t, f)
        }
        if b.has(Sn.pCount) {
            w += Self.textW(String(b.num(Sn.pCount)), f) + (!t.isEmpty ? 0.35 * su : 0)
        }
        if b.flag(Sn.pClose) {
            w += 1.0 * su
        }
        return CGSize(width: w, height: h)
    }

    /// A vlist's rows placed: every row's height (measured when it's here and the width changed, else the estimate),
    /// the scroll kept (following the end, or the anchor row still), and the rows in view arranged.
    private func sArrangeVList(_ s: SceneTree, _ v: SBlock, _ view: CGRect, _ clip: CGRect) {
        if v.rows == nil {
            v.rows = []
        }
        let rows = v.rows ?? []
        let total = Self.sVTotal(v)
        let est = (v.has(Sn.pRowH) ? v.real(Sn.pRowH) : 1.6) * su, w = view.width - 10 * u
        let remeasure = abs(v.rowsW - w) > 0.25
        if v.rowH.count < total {
            v.rowH.append(contentsOf: repeatElement(est, count: total - v.rowH.count))
        }
        if v.rowH.count > total {
            v.rowH.removeSubrange(total..<v.rowH.count)
        }
        for i in 0..<total {
            guard i < rows.count, let row = rows[i] else {
                v.rowH[i] = est
                continue
            }
            if remeasure || row.mGen != sceneGen {
                v.rowH[i] = row.flag(Sn.pDivider) ? 1.7 * su : sMeasure(row, w).height
            }
        }
        v.rowsW = w
        v.rowY.removeAll(keepingCapacity: true)
        var y: CGFloat = 0
        for i in 0..<total {
            v.rowY.append(y)
            y += v.rowH[i]
        }
        let was = v.scroll
        v.scrollMax = max(y - view.height, 0)
        v.view = view.height
        if v.flag(Sn.pFollow) && v.atEnd {
            v.scroll = v.scrollMax
        } else if v.anchorRow >= 0 && v.anchorRow < total {
            v.scroll = v.rowY[v.anchorRow] - v.anchorOff
        }
        v.scroll = min(max(v.scroll, 0), v.scrollMax)
        sScrollPosApply(v)   // version 6: P_SCROLLPOS
        v.atEnd = v.scroll >= v.scrollMax - 1
        if v.atEnd {
            v.newCount = 0
        }
        if abs(was - v.scroll) > 0.5 {
            v.seenAt = Date()
            v.seenSent = false
        }
        // the rows in view (and a little either side), placed on whole device pixels so they move as one
        let dpi = sDpi
        let top = ((view.minY - v.scroll) * dpi).rounded() / dpi
        let c = clip.intersection(view)
        var firstVis = -1, firstMissing = -1, lastMissing = -1
        for i in 0..<total {
            let ry = top + v.rowY[i]
            if ry + v.rowH[i] < view.minY - 200 * u || ry > view.maxY + 200 * u {
                continue
            }
            let inView = ry + v.rowH[i] > view.minY && ry < view.maxY
            if inView && firstVis < 0 {
                firstVis = i
                v.anchorOff = v.rowY[i] - v.scroll
            }
            guard i < rows.count, let row = rows[i] else {
                if firstMissing < 0 {
                    firstMissing = i
                }
                lastMissing = i
                continue
            }
            sArrange(s, row, Self.sR(view.minX, ry, w, v.rowH[i]), c, v.off)
        }
        v.anchorRow = firstVis
        v.selCur = min(v.selCur, total - 1)
        // rows the board hasn't sent: ask for them (64 at a time around what's missing), and older rows near the top
        if firstMissing >= 0 && v.id != 0 {
            let from = max(firstMissing - 16, 0), to = min(max(lastMissing + 16, from + 63), total - 1)
            if from != v.asked.from || to != v.asked.to || Date().timeIntervalSince(v.askedAt) > 5 {
                v.asked = (from: from, to: to)
                v.askedAt = Date()
                reply("Rows;id=\(v.id);from=\(from);to=\(to)")
            }
        }
        if v.flag(Sn.pOlder) && v.id != 0 && v.scroll < view.height * 0.25 && Date().timeIntervalSince(v.olderAt) > 2 {
            v.olderAt = Date()
            reply("Older;id=\(v.id)")
        }
        v.inner = view
    }

    /// Bring b into view (centered, flashed) by scrolling the vlist or scrolls it's in.
    private func sScrollToBlock(_ s: SceneTree, _ b: SBlock, _ center: Bool, _ flash: Bool) {
        var row: SBlock? = b
        while let r = row, let par = r.parent, par.kind != Sn.bkVList {
            row = par
        }
        if let r = row, let v = r.parent, v.kind == Sn.bkVList, let rows = v.rows {
            if let i = rows.firstIndex(where: { $0 === r }), i < v.rowY.count, i < v.rowH.count {
                v.scroll = min(max(v.rowY[i] - (center ? (v.view - v.rowH[i]) / 2 : 0), 0), v.scrollMax)
                v.anchorRow = -1
                v.atEnd = v.scroll >= v.scrollMax - 1
                sceneArr += 1
            }
        } else {
            sceneIntoView(s, b)
        }
        if flash {
            sStartAnim(b, Sn.animFlash, 1300)
        }
        redraw()
    }

    // ================================================================
    // Drawing the new blocks
    // ================================================================

    private func sDrawV2(_ s: SceneTree, _ b: SBlock, _ clip: CGRect) {
        switch b.kind {
        case Sn.bkInput: sDrawInput(s, b)
        case Sn.bkVList: sDrawVList(s, b, clip)
        case Sn.bkChip: sDrawChip(b)
        case Sn.bkViewer: sDrawViewer(s, b)
        default: break
        }
    }

    private func sDrawVList(_ s: SceneTree, _ v: SBlock, _ clip: CGRect) {
        let c = clip.intersection(v.inner)
        v.hits.removeAll()
        if !c.isEmpty, let rows = v.rows {
            NSGraphicsContext.saveGraphicsState()
            c.clip()
            let focused = sFocused(s, v)
            for i in rows.indices {
                guard let row = rows[i], row.pass == s.pass else { continue }
                let sel = v.sel.contains(i), hot = v.num(Sn.pSelect) > 0 && sIsHover(row)
                if sel {
                    sFillRR(row.box, 6 * u, scol(.selBg), 120.0 / 255)
                } else if hot || (i == v.selCur && focused) {
                    sFillRR(row.box, 6 * u, scol(.buttonHot), 60.0 / 255)
                }
                if row.flag(Sn.pDivider) {
                    sDrawDivider(row)
                } else {
                    sDrawBlock(s, row, c)
                }
            }
            // rows not here yet: quiet placeholders
            let n = min(v.rowY.count, v.rowH.count, Self.sVTotal(v))
            for i in 0..<n {
                if i < rows.count && rows[i] != nil {
                    continue
                }
                let ry = v.inner.minY - v.scroll + v.rowY[i]
                if ry + v.rowH[i] < c.minY || ry > c.maxY {
                    continue
                }
                sFillRR(Self.sR(v.inner.minX + 4 * u, ry + 4 * u, v.inner.width * 0.6, max(v.rowH[i] - 8 * u, 2)), 4 * u,
                        scol(.dim), 30.0 / 255)
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        sScrollbar(v.inner, v.scroll, v.scrollMax, false, s, v)
        if v.newCount > 0 {   // "N new ↓": scrolled back while rows came
            var label = v.str(Sn.pNewLabel)
            label = label.isEmpty ? "\(v.newCount) new \u{2193}" : label.replacingOccurrences(of: "%d", with: String(v.newCount))
            let su = self.su, f = font(true, sSmallSize)
            let w = Self.textW(label, f) + 1.4 * su, h = 1.5 * su
            let r = Self.sR(v.inner.minX + (v.inner.width - w) / 2, v.inner.maxY - h - 0.6 * su, w, h)
            sFillRR(r, h / 2, scol(.accent))
            Self.text(label, f, 0).draw(at: CGPoint(x: r.minX + 0.7 * su, y: Self.capY(f, r.midY)))
            v.hits.append((rect: r, i: -2))   // the chip: a click jumps to the end
        }
    }

    private func sDrawDivider(_ row: SBlock) {
        let r = row.box
        let label = row.str(Sn.pText)
        let acc = Self.ucol(row, Sn.pFg) ?? scol(.accent)
        let cy = r.minY + r.height / 2, t = max(1 * u, 1)
        if label.isEmpty {
            Self.color(acc, 160.0 / 255).setFill()
            Self.sR(r.minX, cy, r.width, t).fill(using: .sourceOver)
            return
        }
        let f = font(true, sSmallSize)
        let tl = Self.text(label, f, acc)
        let tw = tl.size().width + 1.2 * su, x0 = r.minX + (r.width - tw) / 2
        Self.color(acc, 140.0 / 255).setFill()
        Self.sR(r.minX, cy, max(x0 - r.minX, 0), t).fill(using: .sourceOver)
        Self.sR(x0 + tw, cy, max(r.maxX - x0 - tw, 0), t).fill(using: .sourceOver)
        tl.draw(at: CGPoint(x: x0 + 0.6 * su, y: Self.capY(f, r.midY)))
    }

    private func sDrawChip(_ b: SBlock) {
        let r = b.box
        let su = self.su, h = r.height
        let on = b.flag(Sn.pOn)
        let bg = Self.ucol(b, Sn.pBg) ?? (on ? Self.mix(scol(.panel), scol(.accent), 0.35) : Self.mix(scol(.panel), scol(.text), 0.08))
        let fg = Self.ucol(b, Sn.pFg) ?? (on ? scol(.text) : sRoleColor(b, scol(.text)))
        let hot = sIsHover(b) && (b.id != 0 || b.flag(Sn.pClose))
        let path = NSBezierPath(roundedRect: r, xRadius: h / 2, yRadius: h / 2)
        Self.color(hot ? Self.mix(bg, scol(.text), 0.12) : bg).setFill()
        path.fill()
        Self.color(on ? scol(.accent) : scol(.border), on ? 1 : 160.0 / 255).setStroke()
        path.lineWidth = (on ? 1.3 : 1) * u
        path.stroke()
        var x = r.minX + 0.45 * su
        let iconBox = Self.sR(x, r.minY + (h - 1.0 * su) / 2, 1.0 * su, 1.0 * su)
        if let a = sAsset(b) {
            sDrawFitted(a.image, CGFloat(a.w), CGFloat(a.h), iconBox, Sn.fitContain, true)
            x += 1.0 * su + 0.3 * su
        } else if b.has(Sn.pIcon) {
            drawIcon(b.num(Sn.pIcon), fg, iconBox)
            x += 1.0 * su + 0.3 * su
        }
        let f = font(true, sSmallSize)
        let t = b.str(Sn.pText)
        if !t.isEmpty {
            let tt = Self.text(t, f, fg)
            tt.draw(at: CGPoint(x: x, y: Self.capY(f, r.midY)))
            x += tt.size().width + 0.35 * su
        }
        if b.has(Sn.pCount) {
            Self.text(String(b.num(Sn.pCount)), f, fg).draw(at: CGPoint(x: x, y: Self.capY(f, r.midY)))
        }
        if b.flag(Sn.pClose) {
            let cx = r.maxX - 0.6 * su, cy = r.minY + h / 2, a = 0.22 * su
            let p = NSBezierPath()
            p.move(to: CGPoint(x: cx - a, y: cy - a))
            p.line(to: CGPoint(x: cx + a, y: cy + a))
            p.move(to: CGPoint(x: cx - a, y: cy + a))
            p.line(to: CGPoint(x: cx + a, y: cy - a))
            p.lineWidth = 1.3 * u
            p.lineCapStyle = .round
            Self.color(fg).setStroke()
            p.stroke()
        }
    }

    /// A picture (an asset) at a whole-number scale, scrolled (version 5): P_SCALE, else the largest that fits (its
    /// width only with P_FITW), up to P_SCALEMAX (4), counted in the module's logical pixels (u points each); under 1
    /// shrunk to fit, smoothly. Placed on device pixels; centered, or from the top with P_FITW, the rest scrolling.
    private func sDrawViewer(_ s: SceneTree, _ b: SBlock) {
        let r = b.inner
        guard let a = sAsset(b), a.w > 0, a.h > 0, r.width > 0, r.height > 0 else { return }
        let dpi = sDpi
        let pw = CGFloat(a.w), ph = CGFloat(a.h), sc = sViewerScale(b, r, pw, ph)
        let w = pw * sc * u, h = ph * sc * u
        let x = ((r.minX + max((r.width - w) / 2, 0)) * dpi).rounded() / dpi
        let y = ((b.flag(Sn.pFitW) ? r.minY : r.minY + max((r.height - h) / 2, 0)) * dpi).rounded() / dpi
        // version 6 (as Windows' DrawViewer): the scroll known before drawing, P_SCROLLPOS, where the picture went, a bar
        b.scrollMax = max(h - r.height, 0)
        b.view = r.height
        b.scroll = min(max(b.scroll, 0), b.scrollMax)
        sScrollPosApply(b)
        NSGraphicsContext.saveGraphicsState()
        r.clip()
        b.picRect = sDrawFitted(a.image, pw, ph, Self.sR(x, y - b.scroll, w, h), Sn.fitStretch, sc < 1)
        NSGraphicsContext.restoreGraphicsState()
        sScrollbar(r, b.scroll, b.scrollMax, false, s, b)   // version 6: a bar to drag
    }

    // ================================================================
    // The rich input (P_PIPES, P_COUNTER, chips, completion, history, keys)
    // ================================================================

    /// The Rainwire pipe colors |00-|15 (foreground) and |16-|23 (background), as the board's markup.
    private static let sPipeFg: [UInt32] = [
        0x00_0000, 0x00_00AA, 0x00_AA00, 0x00_AAAA, 0xAA_0000, 0xAA_00AA, 0xAA_5500, 0xAA_AAAA,
        0x55_5555, 0x55_55FF, 0x55_FF55, 0x55_FFFF, 0xFF_5555, 0xFF_55FF, 0xFF_FF55, 0xFF_FFFF,
    ]

    /// The input's text as colored runs: a pipe code drawn dim, what follows it in its color.
    private func sPipeRuns(_ v: [Character], _ def: UInt32) -> [SPipeRun] {
        var runs: [SPipeRun] = []
        var fg = def
        var bg: UInt32?
        var at = 0, i = 0
        while i < v.count {
            if v[i] == "|" && i + 2 < v.count && v[i + 1].isASCII && v[i + 2].isASCII,
               let d1 = v[i + 1].wholeNumberValue, let d2 = v[i + 2].wholeNumberValue {
                if i > at {
                    runs.append(SPipeRun(start: at, len: i - at, fg: fg, alpha: 1, bg: bg))
                }
                runs.append(SPipeRun(start: i, len: 3, fg: scol(.dim), alpha: 150.0 / 255, bg: nil))
                let n = d1 * 10 + d2
                if n < 16 {
                    fg = n == 0 ? def : Self.sPipeFg[n]
                } else if n < 24 {
                    bg = n == 16 ? nil : Self.sPipeFg[n - 16]
                }
                i += 3
                at = i
                continue
            }
            i += 1
        }
        if at < v.count {
            runs.append(SPipeRun(start: at, len: v.count - at, fg: fg, alpha: 1, bg: bg))
        }
        return runs
    }

    /// The input: a field, plus chips before the text, live pipe colors, and the counter at the right.
    private func sDrawInput(_ s: SceneTree, _ b: SBlock) {
        let su = self.su, size = sSize
        let r = b.box
        let on = sFocused(s, b), multi = b.flag(Sn.pMulti)
        let bg = Self.ucol(b, Sn.pBg) ?? scol(.fieldBg), fg = Self.ucol(b, Sn.pFg) ?? scol(.fieldFg)
        let fr = st.selRadius * u
        if !(b.has(Sn.pStroke) && Self.ucol(b, Sn.pStroke) == nil) {   // P_STROKE none: no box of its own (it's inside the board's)
            let path = NSBezierPath(roundedRect: Self.sInset(r, 0.5 * u), xRadius: fr, yRadius: fr)
            Self.color(bg, on ? 1 : 220.0 / 255).setFill()
            path.fill()
            Self.color(on ? scol(.focus) : scol(.border), on ? 1 : 150.0 / 255).setStroke()
            path.lineWidth = (on ? 1.5 : 1) * u
            path.stroke()
        }
        // chips first, inside the left edge
        var x = r.minX + 0.5 * su
        for k in b.kids where k.kind == Sn.bkChip && !k.flag(Sn.pHidden) {
            let cs = sChipSize(k)
            k.box = Self.sR(x, r.minY + (multi ? 0.3 * su : (r.height - cs.height) / 2), cs.width, cs.height)
            k.pass = s.pass
            k.clip = r
            sDrawChip(k)
            x += cs.width + 0.35 * su
        }
        // the counter at the right
        let maxBytes = b.num(Sn.pMaxBytes)
        let most = maxBytes > 0 ? maxBytes : b.num(Sn.pMax)
        var right = r.maxX - 0.5 * su
        if b.flag(Sn.pCounter) && most > 0 {
            let n = maxBytes > 0 ? String(b.value).utf8.count : b.value.count
            let warn = b.has(Sn.pWarn) ? b.num(Sn.pWarn) : most * 9 / 10
            let cc: UInt32 = n >= most ? 0xFF_5555 : n >= warn ? 0xFF_B84D : scol(.dim)
            let sf = font(false, sSmallSize)
            let ct = Self.text("\(n)/\(most)", sf, cc)
            let cw = ct.size().width
            ct.draw(at: CGPoint(x: right - cw, y: multi ? r.maxY - ct.size().height - 0.25 * su : Self.capY(sf, r.midY)))
            right -= cw + 0.5 * su
        }
        let room = Self.sR(x, r.minY, max(right - x, 1), r.height)
        let caretOn = on && !waiting && (Date().timeIntervalSince(caretAt) < 0.6 || Int(nowMs / 530) % 2 == 0)
        let secret = b.flag(Sn.pSecret)
        let shown: [Character] = secret ? Array(repeating: "\u{2022}", count: b.value.count) : b.value
        let cur = min(max(b.cur, 0), shown.count)
        let f = b.flag(Sn.pMono) ? sMono(size) : font(false, size)
        NSGraphicsContext.saveGraphicsState()
        room.clip()
        let place = b.str(Sn.pPlace)
        if b.value.isEmpty && !place.isEmpty {
            Self.text(Self.fitText(place, f, max(room.width, 1)), f, scol(.dim))
                .draw(at: CGPoint(x: room.minX, y: multi ? r.minY + 0.3 * su : Self.capY(f, r.midY)))
        }
        let lh = Self.fontLine(f) + 2 * u
        // version 6: a multi-line input's lines wrapped by words at its width (or P_WRAPCOLS), as typed
        let vl: [(start: Int, end: Int)]? = multi ? sWrapValue(b, shown, f, room.width - 4 * u) : nil
        if multi {
            b.vLines = vl
        }
        let lines: [ArraySlice<Character>]
        let curLine: Int, lineStart: Int
        if let vl = vl {
            lines = vl.map { shown[$0.start..<$0.end] }
            curLine = Self.sVLineOf(vl, cur)
            lineStart = min(vl[curLine].start, cur)
        } else {
            let before = shown[0..<cur]
            lines = shown.split(separator: "\n", omittingEmptySubsequences: false)
            curLine = before.filter { $0 == "\n" }.count
            lineStart = (before.lastIndex(of: "\n") ?? -1) + 1
        }
        let top = multi ? r.minY + 0.3 * su : 0
        if multi {
            let cy = CGFloat(curLine) * lh, viewH = max(r.height - 0.6 * su, lh)
            if cy - b.scroll > viewH - lh {
                b.scroll = cy - (viewH - lh)
            }
            if cy < b.scroll {
                b.scroll = cy
            }
            b.scroll = max(b.scroll, 0)
        }
        let cxw = Self.textW(String(shown[lineStart..<cur]), f)
        let shift = cxw > room.width - 4 * u ? cxw - (room.width - 4 * u) : 0
        let x0 = room.minX - shift
        let pipes = b.flag(Sn.pPipes) && !secret
        for (li, line) in lines.enumerated() {
            let ly = multi ? top + CGFloat(li) * lh - b.scroll : Self.capY(f, r.midY)
            if multi && (ly + lh < r.minY || ly > r.maxY) {
                continue
            }
            let chars = Array(line)
            if pipes {
                let str = NSMutableAttributedString()
                var px = x0
                for run in sPipeRuns(chars, fg) where run.len > 0 {
                    let seg = Self.text(String(chars[run.start..<(run.start + run.len)]), f, run.fg, run.alpha)
                    let sw = seg.size().width
                    if let bc = run.bg {
                        Self.color(bc).setFill()
                        Self.sR(px, ly, sw, Self.fontLine(f)).fill()
                    }
                    str.append(seg)
                    px += sw
                }
                str.draw(at: CGPoint(x: x0, y: ly))
            } else {
                Self.text(String(chars), f, fg).draw(at: CGPoint(x: x0, y: ly))
            }
        }
        if caretOn {
            Self.color(scol(.focus)).setFill()
            let cy = multi ? top + CGFloat(curLine) * lh - b.scroll + 2 * u : r.minY + 0.3 * su
            Self.sR(x0 + cxw, cy, 2 * u, multi ? lh - 4 * u : r.height - 0.6 * su).fill()
        }
        b.textX = x0
        b.textY = multi ? top - b.scroll : r.minY
        b.lineH = lh
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Function keys' key codes, for P_KEYS names ("f2").
    private static let sFKeys: [UInt16: Int] = [122: 1, 120: 2, 99: 3, 118: 4, 96: 5, 97: 6, 98: 7, 100: 8, 101: 9,
                                                109: 10, 103: 11, 111: 12]
    /// The digit keys' key codes (the row and the keypad), as Windows' D0-D9 and NumPad0-9.
    private static let sDigitKeys: [UInt16: Int] = [29: 0, 18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9,
                                                    82: 0, 83: 1, 84: 2, 85: 3, 86: 4, 87: 5, 88: 6, 89: 7, 91: 8, 92: 9]

    /// A letter key's letter (a-z, the keyboard layout's), else nil.
    private static func sLetter(_ event: NSEvent) -> Character? {
        guard let c = event.charactersIgnoringModifiers?.lowercased(), c.count == 1, let sc = c.unicodeScalars.first,
              sc.value >= 0x61 && sc.value <= 0x7A else { return nil }
        return Character(sc)
    }

    /// A key as P_KEYS names it: "ctrl+" and (for named keys) "shift+" before enter, esc, up, f2, q, 5...
    private static func sKeyNameV2(_ event: NSEvent, _ ctrl: Bool, _ shift: Bool) -> String {
        let k: String
        switch event.keyCode {
        case 36, 76: k = "enter"
        case 117: k = "delete"
        case 51: k = "backspace"
        case 53: k = "esc"
        case 48: k = "tab"
        case 126: k = "up"
        case 125: k = "down"
        case 123: k = "left"
        case 124: k = "right"
        case 116: k = "pgup"
        case 121: k = "pgdn"
        case 115: k = "home"
        case 119: k = "end"
        default:
            if let fn = sFKeys[event.keyCode] {
                k = "f\(fn)"
            } else if let d = sDigitKeys[event.keyCode] {
                k = String(d)
            } else if let c = sLetter(event) {
                k = String(c)
            } else {
                k = ""
            }
        }
        return (ctrl ? "ctrl+" : "") + (shift && k.count > 1 ? "shift+" : "") + k
    }

    private static func sVkFor(_ code: UInt16) -> Int {
        switch code {
        case 123: return vkLeft
        case 124: return vkRight
        case 126: return vkUp
        case 125: return vkDown
        case 117: return vkDelete
        case 51: return vkBackspace
        case 48: return vkTab
        case 122: return vkF1
        case 36, 76: return vkEnter
        case 116: return vkPgUp
        case 121: return vkPgDn
        case 115: return vkHome
        case 119: return vkEnd
        default: return vkChar
        }
    }

    private static func sCharFor(_ event: NSEvent) -> Int {
        if let d = sDigitKeys[event.keyCode] {
            return 0x30 + d
        }
        if let c = sLetter(event), let sc = c.unicodeScalars.first {
            return Int(sc.value)
        }
        return 0
    }

    /// A key on a focused input before the field's own editing: keys passed to the board (P_KEYS, "empty+" ones only
    /// while it's empty), the completion menu, history; true when used.
    private func sInputKey(_ s: SceneTree, _ b: SBlock, _ event: NSEvent, _ ctrl: Bool, _ shift: Bool) -> Bool {
        let code = event.keyCode
        let name = Self.sKeyNameV2(event, ctrl, shift)
        for k in b.strs(Sn.pKeys) {
            let emptyOnly = k.hasPrefix("empty+")
            let kk = emptyOnly ? String(k.dropFirst(6)) : k
            if kk == name && (!emptyOnly || b.value.isEmpty) {
                // with the fields, as a press has them: a key that sends (Messages' Ctrl+Enter) needs what's typed
                if let fn = Self.sFKeys[code], fn > 1 {   // F2-F12 (F3 finds again in MRC)
                    sceneSendKeyX(s, "fn=\(fn)")
                } else {
                    sceneSendKey(s, Self.sVkFor(code), event.modifierFlags.contains(.option), ctrl, Self.sCharFor(event),
                                 Self.sceneFieldsB64(s))
                }
                return true
            }
        }
        // a completion menu hanging from this input: it has the arrows, Tab and Enter
        if let menu = sOpenMenuFor(s, b) {
            let items = menu.kids.filter { $0.kind == Sn.bkButton && !$0.flag(Sn.pHidden) }
            if !items.isEmpty {
                let i = items.firstIndex(where: { $0.on }) ?? 0
                switch code {
                case 126:   // Up
                    items[i].on = false
                    items[(i + items.count - 1) % items.count].on = true
                    return true
                case 125:   // Down
                    items[i].on = false
                    items[(i + 1) % items.count].on = true
                    return true
                case 48, 36, 76:   // Tab, Return, keypad Enter
                    sCompletePick(s, b, items[i])
                    return true
                case 53:    // Esc
                    menu.closed = true
                    return true
                default: break
                }
            }
        }
        if code == 48 && !ctrl && b.num(Sn.pComplete) != 0 {
            let word = Self.sCompleteWord(b)
            if !word.isEmpty {
                if b.num(Sn.pComplete) == 2 {
                    sCompleteLocal(b, word)
                } else {
                    sCompleteAsk(b)
                }
                return true
            }
        }
        // history: Up on the first line, Down on the last
        let hist = b.num(Sn.pHistory)
        if hist > 0 && (code == 126 || code == 125) && !ctrl {
            let multi = b.flag(Sn.pMulti)
            let cur = min(max(b.cur, 0), b.value.count)
            if multi, let vl = b.vLines, !vl.isEmpty {   // version 6: the first and last drawn lines
                let at = Self.sVLineOf(vl, cur)
                if (code == 126 && at > 0) || (code == 125 && at < vl.count - 1) {
                    return false
                }
            } else if multi && code == 126 && b.value[..<cur].contains("\n") {
                return false
            } else if multi && code == 125 && b.value[cur...].contains("\n") {
                return false
            }
            if b.history.isEmpty {
                return true
            }
            if b.histAt < 0 {
                b.draft = b.value
            }
            if code == 126 {
                b.histAt = b.histAt < 0 ? b.history.count - 1 : max(b.histAt - 1, 0)
            } else {
                b.histAt = b.histAt < 0 ? -1 : b.histAt + 1 >= b.history.count ? -1 : b.histAt + 1
            }
            b.value = b.histAt < 0 ? b.draft : b.history[b.histAt]
            b.cur = b.value.count
            sFieldChanged(b)
            return true
        }
        return false
    }

    /// Typed text into an input: limits (P_MAX characters, P_MAXBYTES bytes), "empty+" keys, and the completion
    /// trigger; true when it went in.
    @discardableResult
    private func sInputText(_ s: SceneTree, _ b: SBlock, _ text0: String) -> Bool {
        var text = text0
        if b.value.isEmpty && text.count == 1, let c = text.first {
            let want = "empty+" + String(c).lowercased()
            if b.strs(Sn.pKeys).contains(want) {
                sceneSendKey(s, Self.vkChar, false, false, Int(c.unicodeScalars.first?.value ?? 0))
                return true
            }
        }
        let maxBytes = b.num(Sn.pMaxBytes)
        if maxBytes > 0 {
            var have = String(b.value).utf8.count
            var kept = ""
            for c in text {
                let n = String(c).utf8.count
                if have + n > maxBytes {
                    break
                }
                kept.append(c)
                have += n
            }
            text = kept
        }
        if text.isEmpty || !sFieldInsert(b, text) {
            return false
        }
        b.histAt = -1
        sFieldChanged(b)
        let trigger = b.u32(Sn.pTrigger)
        if b.num(Sn.pComplete) == 1 && b.has(Sn.pTrigger) && text.unicodeScalars.contains(where: { $0.value == trigger }) {
            sCompleteAsk(b)
        } else if sOpenMenuFor(s, b) != nil && !Self.sCompleteWord(b).isEmpty {
            sCompleteAsk(b)   // narrow it as they type
        }
        return true
    }

    /// The word before the caret (back to a space), empty for none; where it starts goes in completeAt.
    private static func sCompleteWord(_ b: SBlock) -> [Character] {
        let i = min(max(b.cur, 0), b.value.count)
        var st = i
        while st > 0 && !b.value[st - 1].isWhitespace {
            st -= 1
        }
        b.completeAt = st
        return Array(b.value[st..<i])
    }

    private func sCompleteAsk(_ b: SBlock) {
        guard b.id != 0 else { return }
        let w = String(Self.sCompleteWord(b))
        reply("Complete;id=\(b.id);q=\(Data(w.utf8).base64EncodedString())")
    }

    /// The word (from completeAt to the caret) replaced by ins.
    private static func sReplaceWord(_ b: SBlock, _ ins: [Character]) {
        let at = min(max(b.completeAt, 0), b.value.count), cur = min(max(b.cur, at), b.value.count)
        b.value = Array(b.value[..<at]) + ins + Array(b.value[cur...])
        b.cur = at + ins.count
    }

    /// Tab completion from P_OPTIONS (MRC's nicks): the next option starting with the word.
    private func sCompleteLocal(_ b: SBlock, _ word: [Character]) {
        let opts = b.strs(Sn.pOptions)
        let w = String(word), d = String(b.draft)
        let stem = !d.isEmpty && w.lowercased().hasPrefix(d.lowercased()) ? d : w
        let hits = opts.filter { $0.lowercased().hasPrefix(stem.lowercased()) }
        guard !hits.isEmpty else { return }
        let i = hits.firstIndex(where: { $0.caseInsensitiveCompare(w) == .orderedSame }) ?? -1
        let pick = Array(hits[(i + 1) % hits.count])
        b.draft = Array(stem)
        Self.sReplaceWord(b, pick)
        sFieldChanged(b)
    }

    /// A completion picked from the menu hanging from input b: the word replaced by the item's label.
    private func sCompletePick(_ s: SceneTree, _ b: SBlock, _ item: SBlock) {
        var label = item.str(Sn.pLabel)
        if label.isEmpty {
            label = item.str(Sn.pText)
        }
        _ = Self.sCompleteWord(b)
        Self.sReplaceWord(b, Array(label) + [" "])
        if let m = sOpenMenuFor(s, b) {
            m.closed = true
        }
        sFieldChanged(b)
        redraw()
    }

    private func sOpenMenuFor(_ s: SceneTree, _ b: SBlock) -> SBlock? {
        guard b.id != 0 else { return nil }
        return s.pops.last(where: { $0.kind == Sn.bkMenu && !$0.closed && $0.num(Sn.pAnchor) == Int(b.id) })
    }

    /// A paste into an input: P_PASTE 1 (or one line) joins lines with spaces; the limits cut it, with a toast.
    private func sInputPaste(_ s: SceneTree, _ b: SBlock) {
        guard !b.off, let text = NSPasteboard.general.string(forType: .string) else { return }
        var t = text.replacingOccurrences(of: "\r", with: "")
        if b.num(Sn.pPaste) == 1 || !b.flag(Sn.pMulti) {
            t = t.split(separator: "\n").joined(separator: " ")
        }
        let before = b.value.count
        sInputText(s, b, t)
        if b.value.count - before < t.count {
            sceneToast("Pasted text was cut to fit", 4)
        }
    }

    /// An input submitted: its value kept for history (P_HISTORY).
    private static func inputSubmitted(_ b: SBlock) {
        let hist = b.num(Sn.pHistory)
        guard hist > 0, !b.value.isEmpty else { return }
        b.history.append(b.value)
        if b.history.count > hist {
            b.history.removeFirst()
        }
        b.histAt = -1
    }

    // ================================================================
    // Timers, every frame: debounced changes, autosave, settled selection and view, hover asks
    // ================================================================

    private func sceneTimers(_ s: SceneTree) {
        let now = Date()
        for b in s.order where b.pass == s.pass && b.id != 0 {
            if b.kind == Sn.bkInput {
                if b.changePending && b.has(Sn.pDebounce)
                    && now.timeIntervalSince(b.changedAt) * 1000 >= Double(b.num(Sn.pDebounce)) {
                    b.changePending = false
                    reply("Change;id=\(b.id);b64=\(Data(String(b.value).utf8).base64EncodedString())")
                }
                if b.has(Sn.pAutosave) && b.changedAt > b.savedAt
                    && now.timeIntervalSince(b.savedAt) >= Double(b.num(Sn.pAutosave)) {
                    b.savedAt = now
                    reply("Change;id=\(b.id);b64=\(Data(String(b.value).utf8).base64EncodedString())")
                }
            } else if b.kind == Sn.bkVList {
                if !b.selSent && now.timeIntervalSince(b.selAt) * 1000 >= Double(b.has(Sn.pSettle) ? b.num(Sn.pSettle) : 0) {
                    b.selSent = true
                    reply("Select;id=\(b.id);rows=\(Self.sRowList(b.sel))")
                }
                if b.flag(Sn.pSeen) && !b.seenSent && now.timeIntervalSince(b.seenAt) >= 0.3 && !b.rowY.isEmpty {
                    b.seenSent = true
                    let first = max(b.anchorRow, 0)
                    var last = first
                    while last + 1 < b.rowY.count && b.rowY[last + 1] < b.scroll + b.view {
                        last += 1
                    }
                    reply("Seen;id=\(b.id);first=\(first);last=\(last);bottom=\(b.atEnd ? 1 : 0)")
                }
            }
        }
        // hover asks (P_HOVERASK): the board fills the tooltip
        var hov: SBlock?
        for b in s.order.reversed() where b.pass == s.pass && b.id != 0 && b.has(Sn.pHoverAsk) && sIsHover(b) {
            hov = b
            break
        }
        if hov !== hoverBlock {
            hoverBlock = hov
            hoverSince = now
            if hov == nil {
                hoverAsked = 0
            }
        }
        if let h = hov, hoverAsked != h.id && now.timeIntervalSince(hoverSince) * 1000 >= Double(h.num(Sn.pHoverAsk)) {
            hoverAsked = h.id
            reply("Hover;id=\(h.id)")
        }
    }

    /// "3,5-9" for a set of rows.
    private static func sRowList(_ sel: Set<Int>) -> String {
        let l = sel.sorted()
        var parts: [String] = []
        var i = 0
        while i < l.count {
            var j = i
            while j + 1 < l.count && l[j + 1] == l[j] + 1 {
                j += 1
            }
            parts.append(j > i ? "\(l[i])-\(l[j])" : "\(l[i])")
            i = j + 1
        }
        return parts.joined(separator: ",")
    }

    // ================================================================
    // Pop-ups: menus, popovers and drawers (context, anchored, a button's, the board's)
    // ================================================================

    /// The pop-ups to show now: the board's anchored menus and popovers in the tree (unless closed by the caller),
    /// drawers open, and context or button menus the caller opened. Laid out over the scene.
    private func sLayoutPops(_ s: SceneTree, _ space: CGRect) {
        s.pops.removeAll()
        func walk(_ b: SBlock) {
            for k in b.kids {
                if k.flag(Sn.pHidden) {
                    continue
                }
                if Self.sIsPop(k.kind) {
                    let show = k.kind == Sn.bkDrawer ? (k.open || k.flag(Sn.pOn)) && !k.closed
                        : k.open || (k.has(Sn.pAnchor) && !k.flag(Sn.pContext) && !k.closed)
                    if show {
                        s.pops.append(k)
                    }
                    continue
                }
                walk(k)
            }
            if let rows = b.rows {
                for case let row? in rows {
                    walk(row)
                }
            }
        }
        walk(s.top)
        let su = self.su
        for m in s.pops {
            if m.kind == Sn.bkDrawer {
                let w = min(max(sMeasure(m, space.width * 0.8).width, 16 * su), space.width * 0.85)
                let dr = m.num(Sn.pSide) == Sn.sideRight ? Self.sR(space.maxX - w, space.minY, w, space.height)
                    : Self.sR(space.minX, space.minY, w, space.height)
                sArrangePop(s, m, dr, space)
                continue
            }
            let nat = sMeasure(m, min(space.width * 0.6, 40 * su))
            let mw = max(nat.width, m.kind == Sn.bkMenu ? 10 * su : 0), mh = min(nat.height, space.height - su)
            let anchor: CGRect
            if m.has(Sn.pAnchor), let a = s.byId[UInt16(truncatingIfNeeded: m.num(Sn.pAnchor))] {
                anchor = a.box
            } else if m.open, let at = m.openAt {
                anchor = CGRect(x: at.x, y: at.y, width: 1, height: 1)
            } else {
                anchor = m.parent?.box ?? space
            }
            var x = anchor.minX, y = anchor.maxY + 0.2 * su
            switch m.num(Sn.pSide) {
            case Sn.sideAbove: y = anchor.minY - mh - 0.2 * su
            case Sn.sideRight:
                x = anchor.maxX + 0.2 * su
                y = anchor.minY
            case Sn.sideLeft:
                x = anchor.minX - mw - 0.2 * su
                y = anchor.minY
            default: break
            }
            if y + mh > space.maxY {
                y = anchor.minY - mh - 0.2 * su   // no room below: above
            }
            x = min(max(x, space.minX), max(space.maxX - mw, space.minX))
            y = min(max(y, space.minY), max(space.maxY - mh, space.minY))
            sArrangePop(s, m, Self.sR(x, y, mw, mh), space)
        }
    }

    private func sArrangePop(_ s: SceneTree, _ m: SBlock, _ r: CGRect, _ space: CGRect) {
        m.pass = s.pass
        m.box = r
        m.clip = space
        m.off = m.flag(Sn.pDisabled)
        s.order.append(m)
        let inner = Self.sInset(r, 0.4 * su)
        m.inner = inner
        sArrangeFlex(s, m, inner, false, space)
    }

    private func sDrawPops(_ s: SceneTree) {
        for m in s.pops where m.pass == s.pass {
            let r: CGFloat = (m.kind == Sn.bkDrawer ? 0 : 8) * u
            let bg = Self.mix(scol(.panel), 0, 0.1)
            sFillRR(CGRect(x: m.box.minX + 3 * u, y: m.box.minY + 4 * u, width: m.box.width, height: m.box.height), r, 0,
                    110.0 / 255)
            sFillRR(m.box, r, bg)
            sStrokeRR(m.box, r, 1 * u, scol(.border))
            if m.kind == Sn.bkMenu {
                for k in m.kids where k.kind == Sn.bkButton && k.pass == s.pass && (k.on || sIsHover(k)) {
                    sFillRR(k.box, 5 * u, scol(.selBg), 140.0 / 255)
                }
            }
            sDrawKids(s, m, m.box)
        }
    }

    /// The pop-up under p, if any (the topmost).
    private static func sPopAt(_ s: SceneTree, _ p: CGPoint) -> SBlock? { s.pops.last(where: { $0.box.contains(p) }) }

    /// Esc or a click outside: the topmost pop-up closes (true), before anything else.
    @discardableResult
    private func sPopClose(_ s: SceneTree) -> Bool {
        guard let m = s.pops.last else { return false }
        m.open = false
        m.closed = true
        if m.flag(Sn.pReport) && m.id != 0 {
            reply("Back;id=\(m.id)")
        }
        s.pops.removeLast()
        sceneArr += 1
        redraw()
        return true
    }

    /// A right-click at p (RainwireMenu.swift rightMouseUp): the context menu of the block under it (P_CONTEXT), else a
    /// Click;btn=r for a block that asks for it; true when used.
    func sceneRightClick(_ s: SceneTree, _ p: CGPoint) -> Bool {
        for b in s.order.reversed() {
            if b.pass != s.pass || !b.box.contains(p) || !b.clip.contains(p) || sHoverHidden(b) {
                continue
            }
            if let menu = b.kids.first(where: { $0.kind == Sn.bkMenu && $0.flag(Sn.pContext) }) {
                for pop in s.pops {
                    pop.open = false
                }
                menu.open = true
                menu.closed = false
                menu.openAt = p
                sceneArr += 1
                redraw()
                return true
            }
            if b.num(Sn.pEvents) & Sn.evRight != 0 && b.id != 0 {
                reply("Click;id=\(b.id);n=1;btn=r" + sClickWhere(b, p))   // version 6: where
                return true
            }
        }
        return false
    }

    // ================================================================
    // Clicks for v2: pop-ups, chips, vlist rows, click events, menu buttons, drawers
    // ================================================================

    /// A click before the v1 controls get it; true when used.
    private func sceneClickV2(_ s: SceneTree, _ p: CGPoint) -> Bool {
        // a chip inside an input (its x, or the chip itself): a press
        for inp in s.order where inp.kind == Sn.bkInput && inp.pass == s.pass {
            for k in inp.kids where k.kind == Sn.bkChip && k.pass == s.pass && k.box.contains(p) && k.id != 0 {
                scenePress(s, k)
                return true
            }
        }
        // a link span
        if let link = sLinkAt(s, p) {
            reply("Link;id=\(link.block.id);url=\(Data(link.url.utf8).base64EncodedString())")
            return true
        }
        // a pop-up open: a click outside closes it (and does nothing else)
        if !s.pops.isEmpty && Self.sPopAt(s, p) == nil {
            sPopClose(s)
            return true
        }
        // a menu item in a pop-up: a completion picked, or a press (the menu closes)
        if let pop = Self.sPopAt(s, p), pop.kind == Sn.bkMenu {
            guard let item = pop.kids.first(where: { $0.kind == Sn.bkButton && $0.box.contains(p) && !$0.off }) else {
                return true
            }
            let aid = pop.num(Sn.pAnchor)
            if aid > 0, let anchor = s.byId[UInt16(truncatingIfNeeded: aid)], anchor.kind == Sn.bkInput {
                sCompletePick(s, anchor, item)
            } else {
                pop.open = false
                if pop.has(Sn.pAnchor) {
                    pop.closed = true
                }
                scenePress(s, item)
            }
            return true
        }
        for b in s.order.reversed() {
            if b.pass != s.pass || b.off || !b.box.contains(p) || !b.clip.contains(p) || sHoverHidden(b) {
                continue
            }
            // a button that opens a menu or a drawer
            if b.kind == Sn.bkButton && b.flag(Sn.pMenuBtn), let bm = b.kids.first(where: { $0.kind == Sn.bkMenu }) {
                bm.open.toggle()
                bm.closed = false
                bm.openAt = bm.has(Sn.pAnchor) ? nil : CGPoint(x: b.box.minX, y: b.box.maxY)
                sceneArr += 1
                return true
            }
            if b.kind == Sn.bkButton && b.has(Sn.pOpens), let dr = s.byId[UInt16(truncatingIfNeeded: b.num(Sn.pOpens))],
               dr.kind == Sn.bkDrawer {
                dr.open.toggle()
                dr.closed = false
                sceneArr += 1
                return true
            }
            // a sortable header (P_SORT): Sort;id=;col=
            if b.kind == Sn.bkButton && b.has(Sn.pSort) && b.id != 0 {
                reply("Sort;id=\(b.id);col=\(b.num(Sn.pSort))")
                return true
            }
            // a chip: a press when it has an id
            if b.kind == Sn.bkChip && b.id != 0 {
                scenePress(s, b)
                return true
            }
            // a vlist: the "N new" chip, a row picked
            if b.kind == Sn.bkVList {
                if b.hits.contains(where: { $0.i == -2 && $0.rect.contains(p) }) {
                    b.scroll = b.scrollMax
                    b.atEnd = true
                    b.newCount = 0
                    b.anchorRow = -1
                    sceneArr += 1
                    return true
                }
                if b.num(Sn.pSelect) > 0, let rows = b.rows {
                    for j in rows.indices {
                        if let rb = rows[j], rb.pass == s.pass, rb.box.contains(p) {
                            sVSelectClick(s, b, j)
                            return true
                        }
                    }
                }
            }
            // a plain block with click events
            let ev = b.num(Sn.pEvents)
            if ev & (Sn.evClick | Sn.evDouble | Sn.evTriple) != 0 && b.id != 0 {
                let now = Date()
                clickN = clickId == b.id && now.timeIntervalSince(clickAt) < 0.4 ? min(clickN + 1, 3) : 1
                clickId = b.id
                clickAt = now
                if (clickN == 1 && ev & Sn.evClick != 0) || (clickN == 2 && ev & Sn.evDouble != 0)
                    || (clickN == 3 && ev & Sn.evTriple != 0) {
                    // version 5: Ctrl (or Cmd, as a vlist's picks take it) and Shift held (the Files list's picks)
                    let km = NSEvent.modifierFlags
                    reply("Click;id=\(b.id);n=\(clickN);btn=l"
                          + (km.contains(.control) || km.contains(.command) ? ";ctrl=1" : "")
                          + (km.contains(.shift) ? ";shift=1" : "") + sClickWhere(b, p))   // version 6: where
                }
                return true
            }
            if Self.sIsControl(b.kind) {
                return false   // the v1 click has it
            }
        }
        return false
    }

    /// A row clicked in a selecting vlist: one, Ctrl (or Cmd) toggles, Shift a range; the selected one again (or a
    /// double-click) activates.
    private func sVSelectClick(_ s: SceneTree, _ v: SBlock, _ row: Int) {
        let mods = NSEvent.modifierFlags
        let ctrl = mods.contains(.control) || mods.contains(.command), shift = mods.contains(.shift)
        let many = v.num(Sn.pSelect) == 2
        let now = Date()
        let dbl = v.selCur == row && now.timeIntervalSince(clickAt) < 0.4
        clickAt = now
        if v.id != 0 {
            s.focus = v.id
        }
        if dbl || (!ctrl && !shift && v.sel.count == 1 && v.sel.contains(row) && !many) {
            if v.id != 0 {
                reply("Activate;id=\(v.id);i=\(row)")
            }
            return
        }
        if many && ctrl {
            if v.sel.remove(row) == nil {
                v.sel.insert(row)
            }
            v.selAnchor = row
        } else if many && shift && v.selAnchor >= 0 {
            v.sel.removeAll()
            for i in min(v.selAnchor, row)...max(v.selAnchor, row) {
                v.sel.insert(i)
            }
        } else {
            v.sel.removeAll()
            v.sel.insert(row)
            v.selAnchor = row
        }
        v.selCur = row
        v.selAt = now
        v.selSent = false
        redraw()
    }

    /// The board's pick (P_INDEX set on a vlist): that row alone selected, not reported back as a Select.
    private static func vSetSel(_ v: SBlock, _ row: Int) {
        v.sel.removeAll()
        v.sel.insert(row)
        v.selCur = row
        v.selAnchor = row
        v.selSent = true
    }

    /// A focused selecting vlist's keys: arrows, Home/End, Page Up/Down, Shift ranges, Ctrl+A, Enter.
    private func sVListKey(_ s: SceneTree, _ v: SBlock, _ event: NSEvent, _ ctrl: Bool, _ shift: Bool) -> Bool {
        let total = Self.sVTotal(v)
        guard total > 0 else { return false }
        let code = event.keyCode
        let cur = min(max(v.selCur, 0), total - 1)
        let rows = v.view / max((v.has(Sn.pRowH) ? v.real(Sn.pRowH) : 1.6) * su, 1)
        let page = max((rows.isFinite && rows < 1e6 ? Int(rows) : 1) - 1, 1)
        var to: Int?
        switch code {
        case 126: to = cur - 1                                       // Up
        case 125: to = cur + 1                                       // Down
        case 115: to = 0                                             // Home
        case 119: to = total - 1                                     // End
        case 116: to = cur - page                                    // Page Up
        case 121: to = cur + page                                    // Page Down
        default: to = nil
        }
        if ctrl && v.num(Sn.pSelect) == 2 && Self.sLetter(event) == "a" {
            v.sel = Set(0..<total)
            v.selAt = Date()
            v.selSent = false
            return true
        }
        if (code == 36 || code == 76) && v.id != 0 {
            reply("Activate;id=\(v.id);i=\(cur)")
            return true
        }
        guard let want = to else { return false }
        let t = min(max(want, 0), total - 1)
        if shift && v.num(Sn.pSelect) == 2 {
            if v.selAnchor < 0 {
                v.selAnchor = cur
            }
            v.sel = Set(min(v.selAnchor, t)...max(v.selAnchor, t))
        } else {
            v.sel = [t]
            v.selAnchor = t
        }
        v.selCur = t
        v.selAt = Date()
        v.selSent = false
        if t < v.rowY.count && t < v.rowH.count {   // keep it in view
            if v.rowY[t] < v.scroll {
                v.scroll = v.rowY[t]
            } else if v.rowY[t] + v.rowH[t] > v.scroll + v.view {
                v.scroll = v.rowY[t] + v.rowH[t] - v.view
            }
            v.anchorRow = -1
            sceneArr += 1
        }
        return true
    }

    /// A focused input's editing (after sInputKey): paste (P_PASTE and the limits), Enter submitting a multi-line
    /// input with P_SUBMIT (Shift+Enter a new line), then the field's own keys.
    private func sInputEdit(_ s: SceneTree, _ b: SBlock, _ event: NSEvent, _ ctrl: Bool, _ shift: Bool) -> Bool {
        let code = event.keyCode
        if ctrl && event.charactersIgnoringModifiers?.lowercased() == "v" {
            sInputPaste(s, b)
            return true
        }
        if (code == 36 || code == 76) && b.flag(Sn.pMulti) {
            if b.flag(Sn.pSubmit) && !shift {
                sceneSubmit(s, b)
                return true
            }
            if !ctrl && sInputText(s, b, "\n") {
                return true
            }
        }
        return sFieldKey(s, b, event, ctrl)
    }

    /// A link span's boxes in text t laid out at origin.
    private func sLinkRects(_ t: SText, _ start: Int, _ len: Int, _ origin: CGPoint) -> [CGRect] {
        guard start >= 0, len > 0, start + len <= t.storage.length else { return [] }
        let gr = t.layout.glyphRange(forCharacterRange: NSRange(location: start, length: len), actualCharacterRange: nil)
        var rects: [CGRect] = []
        t.layout.enumerateEnclosingRects(forGlyphRange: gr, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                         in: t.box) { rect, _ in
            rects.append(rect.offsetBy(dx: origin.x, dy: origin.y))
        }
        return rects
    }

    /// The link span under p (its block and address), if any.
    private func sLinkAt(_ s: SceneTree, _ p: CGPoint) -> (block: SBlock, url: String)? {
        for b in s.order.reversed() {
            guard b.kind == Sn.bkText, b.pass == s.pass, !b.links.isEmpty, b.box.contains(p), b.clip.contains(p),
                  b.inner.width > 0 else { continue }
            let t = sTextLayout(b, b.inner.width)
            for l in b.links where l.len > 0 {
                if sLinkRects(t, l.start, l.len, b.inner.origin).contains(where: { $0.contains(p) }) {
                    return (b, l.url)
                }
            }
        }
        return nil
    }

    /// Whether the pointer at p is over something a click does (a link, a chip, a block with click events): the hand.
    private func sceneHandAt(_ s: SceneTree, _ p: CGPoint) -> Bool {
        if sLinkAt(s, p) != nil {
            return true
        }
        for b in s.order.reversed() {
            if b.pass != s.pass || !b.box.contains(p) || !b.clip.contains(p) || sHoverHidden(b) {
                continue
            }
            if (b.kind == Sn.bkChip && b.id != 0) || b.num(Sn.pEvents) & (Sn.evClick | Sn.evDouble) != 0 {
                return true
            }
        }
        return false
    }

    /// Links drawn underlined (always, as a web page's), after their text; brighter under the pointer.
    private func sDrawLinks(_ b: SBlock, _ t: SText, _ origin: CGPoint) {
        for l in b.links where l.len > 0 {
            let rects = sLinkRects(t, l.start, l.len, origin)
            guard var box = rects.first else { continue }
            for r in rects.dropFirst() {
                box = box.union(r)
            }
            let hot = pointer.map { p in rects.contains(where: { $0.contains(p) }) } ?? false
            Self.color(scol(.accent), hot ? 1 : 170.0 / 255).setFill()
            Self.sR(box.minX, box.maxY - 1.5 * u, box.width, max(u, 1)).fill(using: .sourceOver)
        }
    }
}

// MARK: - Scenes version 5: Files as a scene

/// Scenes version 5 (Rainwire docs/SCENES_V2.md, "Files as built"): what the Files scene needs beyond version 4, so it
/// looks and behaves as the Files TRACE module does. A port of Windows' `Controls/RainwireSceneFiles.cs` (written
/// 2026-10-22, uncompiled); its state is in RainwireMenu.swift (an extension can't add stored properties), and it's in
/// this file so it can use the two extensions' private helpers.
///   - P_DROP: Finder files dragged over a drop target light it; dropped, they go the module's way
///     (RainwireWm/RainwireFileDrops.swift): one Rainwire:WM FileOffer each, with module=rwfiles and scene=<block>.
///   - P_DRAG: a row pressed and moved past 6 points (lp) sends DragOut;id=<row> (the module's FM_C_DRAG) and shows a
///     label by the pointer; the board answers with the window protocol's DragFile (scene=, label=, hint=); taken out
///     of the window with the button down, it's the module's OS drag (RainwireFileDrops: a file promise), let go on
///     Finder: DropOut with scene=. Let go inside the window: DragOut;id=0.
///   - P_FITW, P_SCALEMAX: a viewer's whole-number scale fitting its width only (ANSI art, from the top), and the
///     largest it takes. P_TILEMIN, P_TILERATIO: a grid's tiles as many a row as fit, sharing the row, their height
///     following their width (the gallery). P_SCROLLBY (a Set): a scroll, vlist or viewer scrolled by the board's keys;
///     P_PANE on a scroll or vlist leaves Page Up/Down, Home and End to the board.
extension RainwireMenuView {
    // ================================================================
    // Rows dragged out (P_DRAG)
    // ================================================================

    /// The scene row being dragged out (DragOut sent), or 0.
    var sceneDragRow: UInt16 { sDragging ? (sDragRow?.id ?? 0) : 0 }

    /// The left button went down at p: a drag out may start from a P_DRAG row there.
    func sceneButtonDown(_ p: CGPoint) {
        sDragRow = nil
        sDragging = false
        sDragOk = false
        sDragLeft = false
        sDragEvent = nil
        guard let s = scene, complete, isScene, s.pops.isEmpty else { return }
        for b in s.order.reversed() where b.pass == s.pass && b.flag(Sn.pDrag) && b.id != 0 && b.box.contains(p)
            && b.clip.contains(p) {
            sDragRow = b
            sDragFrom = p
            return
        }
    }

    /// The pointer moved with the left button down (mouseDragged): true while a row is being dragged (nothing else
    /// happens under it).
    func sceneDragMove(_ p: CGPoint, _ event: NSEvent) -> Bool {
        guard let row = sDragRow else { return false }
        if NSEvent.pressedMouseButtons & 1 == 0 {
            if !sDragging {
                sDragRow = nil
            }
            return sDragging
        }
        sDragEvent = event
        if !sDragging {
            if abs(p.x - sDragFrom.x) + abs(p.y - sDragFrom.y) <= 6 * u {
                return false
            }
            sDragging = true
            sDragLabel = Self.sRowLabel(row)
            sDragHint = ""
            reply("DragOut;id=\(row.id)")
        }
        pointer = p
        let outside = RainwireFileDrops.pointerOutsideWindow(self)
        if !sDragLeft && outside {
            sDragLeft = true
            sceneDragLeftWindow?(row.id, event)
        } else if sDragLeft && !outside {
            sDragLeft = false
        }
        NSCursor.arrow.set()
        needsDisplay = true
        return true
    }

    /// The left button came up: true when it ended a drag (no click). Let go inside: DragOut;id=0.
    func sceneButtonUp() -> Bool {
        guard sDragging else {
            sDragRow = nil
            return false
        }
        if !RainwireFileDrops.pointerOutsideWindow(self) {
            reply("DragOut;id=0")
        }
        sceneDragEnd()
        return true
    }

    func sceneDragEnd() {   // not private: reset() and onMenu() (RainwireMenu.swift) end a drag too
        sDragRow = nil
        sDragging = false
        sDragOk = false
        sDragLeft = false
        sDragEvent = nil
        redraw()
    }

    /// DragFile for scene row id: allowed (the label and hint to show by the pointer), or not (the board says why in
    /// the status bar; the drag ends).
    func sceneDragAnswer(_ id: UInt16, _ ok: Bool, _ label: String, _ hint: String) {
        guard sDragging, let row = sDragRow, row.id == id else { return }
        if !ok {
            sceneDragEnd()
            return
        }
        sDragOk = true
        if !label.isEmpty {
            sDragLabel = label
        }
        sDragHint = hint
        redraw()
    }

    /// The row being dragged is held outside the window (an OS drag may start now).
    func sceneDragHeldOutside() -> Bool {
        sDragging && NSEvent.pressedMouseButtons & 1 != 0 && RainwireFileDrops.pointerOutsideWindow(self)
    }

    /// The OS drag starts (it has the mouse until it ends; no mouseUp comes here) and ends.
    func sceneBeginExternalDrag() {}

    func sceneEndExternalDrag() {
        sceneDragEnd()
    }

    /// A row's label until the board's comes: its longest text (the file's name).
    private static func sRowLabel(_ row: SBlock) -> String {
        var best = ""
        func walk(_ b: SBlock) {
            if best.isEmpty && b.kind == Sn.bkText {
                let t = b.str(Sn.pText)
                if t.count > 1 {
                    best = t
                }
            }
            for k in b.kids {
                walk(k)
            }
        }
        walk(row)
        return best
    }

    /// The label beside the pointer (filesmod.c's draw_drag): the file, and the hint once the board allowed it.
    fileprivate func sDrawSceneDrag(_ w: CGFloat, _ h: CGFloat) {
        guard sDragging, !sDragLeft, !sDragLabel.isEmpty, let mouse = pointer else { return }
        let lf = font(true, sSize)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let label = NSAttributedString(string: sDragLabel, attributes: [
            .font: lf, .foregroundColor: Self.color(sDragOk ? scol(.buttonFg) : scol(.dim)), .paragraphStyle: style])
        let lw = min(ceil(label.size().width), 360 * u)
        let hint: NSAttributedString? = sDragHint.isEmpty ? nil : Self.text(sDragHint, font(false, sSmallSize), scol(.dim))
        let hw = hint.map { ceil($0.size().width) } ?? 0
        let bw = max(lw, hw) + 24 * u, bh = (hint != nil ? 44 : 26) * u
        let x = min(max(mouse.x + 16 * u, 0), max(w - bw, 0)), y = min(max(mouse.y + 14 * u, 0), max(h - bh, 0))
        sFillRR(CGRect(x: x, y: y, width: bw, height: bh), 6 * u, scol(.buttonBg), (sDragOk ? 235 : 150) / 255.0)
        label.draw(with: CGRect(x: x + 12 * u, y: y + 4 * u, width: lw + 1, height: Self.fontLine(lf) + 1),
                   options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        hint?.draw(at: CGPoint(x: x + 12 * u, y: y + 24 * u))
    }

    // ================================================================
    // Files dropped from Finder (P_DROP)
    // ================================================================

    /// The P_DROP block under an OS drag (a point in window coordinates) and the point in this view, or nil: the
    /// scene showing and taking files.
    func sceneDropTarget(windowPoint: NSPoint) -> (id: UInt16, at: CGPoint)? {
        guard isUp, !isHidden, window != nil, let s = scene, complete, isScene else { return nil }
        let p = convert(windowPoint, from: nil)
        for b in s.order.reversed() where b.pass == s.pass && b.flag(Sn.pDrop) && b.id != 0 && b.box.contains(p) {
            return (b.id, p)
        }
        return nil
    }

    /// Lights drop target id while files are dragged over it (0: none).
    func sceneDropHover(_ id: UInt16) {
        if sDropLit == id {
            return
        }
        sDropLit = id
        redraw()
    }

    fileprivate func sDrawSceneDrop() {
        guard sDropLit != 0, let s = scene, let b = s.byId[sDropLit], b.pass == s.pass else { return }
        sStrokeRR(Self.sInset(b.box, 1.5 * u), 6 * u, 2 * u, scol(.accent), 200.0 / 255)
    }

    // ================================================================
    // The board's scrolling, a grid's shared tiles, the viewer's scale
    // ================================================================

    /// A Set's P_SCROLLBY: b scrolled once by that many units (±1e6: to an end); the key isn't kept.
    fileprivate func sScrollBy(_ s: SceneTree, _ b: SBlock, _ v: [UInt8]) {
        if let gone = b.props.removeValue(forKey: Sn.pScrollBy) {
            b.bytes -= gone.count + 4
            s.bytes -= gone.count + 4
        }
        guard v.count == 4 else { return }
        let f = Float(bitPattern: sceneLE32(v, 0))
        guard f.isFinite else { return }
        let by = CGFloat(f)
        sSetScroll(b, by > 1e5 ? b.scrollMax : by < -1e5 ? 0 : b.scroll + by * su)
    }

    /// P_TILEMIN: as many tiles a row as fit (at least two), sharing it; each P_TILEH + its width x P_TILERATIO high.
    /// Nil when b doesn't say.
    fileprivate func sGridShared(_ b: SBlock, _ w: CGFloat) -> (cols: Int, tw: CGFloat, th: CGFloat)? {
        let minW = sUnits(b, Sn.pTileMin)
        guard minW > 0, !w.isInfinite, b.num(Sn.pColumns) <= 0 else { return nil }
        let gap = sUnits(b, Sn.pGap)
        let cols = max(2, Int((w + gap) / (minW + gap)))
        let tw = max((w - gap * CGFloat(cols - 1)) / CGFloat(cols), su)
        return (cols, tw, sUnits(b, Sn.pTileH) + tw * max(b.real(Sn.pTileRatio), 0))
    }

    /// A viewer's whole-number scale (the module's logical pixels to a picture pixel, as its previews show them):
    /// P_SCALE, else the largest that fits (its width only with P_FITW), up to P_SCALEMAX (4); under 1 the picture is
    /// shrunk to fit, smoothly.
    fileprivate func sViewerScale(_ b: SBlock, _ r: CGRect, _ pw: CGFloat, _ ph: CGFloat) -> CGFloat {
        let fixed = b.num(Sn.pScale)
        if fixed > 0 {
            return CGFloat(fixed)
        }
        let dw = r.width / u, dh = r.height / u
        let sc = b.flag(Sn.pFitW) ? dw / pw : min(dw / pw, dh / ph)
        guard sc.isFinite else { return 1 }
        let most = b.num(Sn.pScaleMax) > 0 ? b.num(Sn.pScaleMax) : 4
        return sc >= 1 ? min(sc.rounded(.down), CGFloat(most)) : sc
    }
}

// MARK: - Scenes version 6: mouse, scrolling, new blocks

/// Scenes version 6 (Rainwire docs/SCENES_V6.md), the last of 1.1.6: the scroll position reported (P_REPORTSCROLL ->
/// Scrolled) and set (P_SCROLLPOS); scroll bars dragged and their tracks clicked; a click in a pane (P_PANE) giving it
/// the keys; multi-line fields and inputs wrapped by words as typed (their width or P_WRAPCOLS); the split block (a
/// divider the caller drags: Split;id=;at=); clicks that say where (x, y, w, h; col, row on cells; px, py on a picture;
/// cx, cy, tag on a canvas; i on a chart), the middle button, Move and Wheel events, the mouse's back and forward
/// buttons; the scene's size (SF_SIZE -> Size); clocks and countdowns the client keeps (P_CLOCK, P_AT -> Timer); charts;
/// sliders and number boxes; and the canvas, drawn by SceneDraw commands. The gadget engine (places, drags, the tray)
/// is RainwireMenu.swift's widgets extension; the parts of it that need this file's private helpers (running a click,
/// key, wheel or drag in a gadget's scene: inGadget) are at the end of this one.
///
/// Port of the Windows client's `Controls/RainwireSceneV6.cs` (and the scene half of `RainwireGadgets.cs`), nearly
/// line for line; written 2026-11-02 without a Mac to build on (uncompiled). It's in this file, not one of its own, so
/// the other extensions' private helpers are reachable and the Xcode project is unchanged; its state is in
/// RainwireMenu.swift (drag6, splitClicked, moveOn...) and on SBlock/SceneTree above. macOS differences: the canvas is
/// parsed once into CGPaths (SCanvasItem) and drawn each frame through a CGContext transform, where Windows builds one
/// frozen DrawingGroup; an open polyline's hit area is its stroke widened (WPF: its fill, i.e. nothing); a field's
/// value and its wrapped lines are Characters, not UTF-16 units; the wheel's sideways scroll is a trackpad's or tilt
/// wheel's deltaX (or Shift, which macOS already turns into deltaX for a mouse); a touchpad's delta is points, a
/// "notch" for Wheel;d= is 4.5 units of them; clocks use DateFormatter's short/medium styles for .NET's t, T, d, g.
extension RainwireMenuView {
    /// A scroll bar as drawn (sScrollbar): its block (nil: the scene's own), track, thumb, axis, how far it scrolls and
    /// how far the thumb travels.
    struct SBar {
        let b: SBlock?
        let track: CGRect, thumb: CGRect
        let horiz: Bool
        let scrollMax: CGFloat, room: CGFloat
    }

    enum Drag6Kind { case bar, split, slider }

    /// A scroll bar, divider or slider being dragged: in which tree, which block (a bar's nil: the scene's own), where
    /// in the thumb it was taken, and the gadget it's in (nil: the screen).
    struct SDrag6 {
        let kind: Drag6Kind
        let s: SceneTree
        let b: SBlock?
        let grab: CGFloat
        let g: SGadgetM?
    }

    /// A canvas command parsed (SceneDraw): a shape (its path, fill, stroke), a text, a picture, or the canvas filled.
    enum SCanvasItem {
        case shape(path: CGPath, fill: UInt32?, stroke: UInt32?, width: CGFloat)
        case text(NSAttributedString, CGPoint)
        case image(NSImage, CGRect, Bool)
        case clear(UInt32)
    }

    private static func sF1(_ v: CGFloat) -> String { String(format: "%.1f", Double(v.isFinite ? v : 0)) }
    private static func sR10(_ v: CGFloat) -> CGFloat { (v * 10).rounded() / 10 }

    /// The v6 properties' types (sKeyTypeV2 asks here for keys it doesn't know).
    private static func sKeyTypeV6(_ k: UInt8) -> UInt8 {
        switch k {
        case Sn.pClock, Sn.pChart, Sn.pSpin, Sn.pAxes: return Sn.tU8
        case Sn.pReportScroll: return Sn.tU16
        case Sn.pAt: return Sn.tU32
        case Sn.pScrollPos, Sn.pSplitAt, Sn.pSplitMin, Sn.pMinV, Sn.pMaxV, Sn.pStep, Sn.pViewW, Sn.pViewH: return Sn.tF32
        case Sn.pUnit: return Sn.tStr
        case Sn.pLabels: return Sn.tStrs
        case Sn.pData, Sn.pData2: return Sn.tF32s
        default: return 0
        }
    }

    /// The pointer where the drawing code looks (pointer: the screen's, or a gadget's while one runs), or far away.
    private var sMouse: CGPoint { pointer ?? CGPoint(x: -1e9, y: -1e9) }

    // ================================================================
    // Scroll position: P_SCROLLPOS applied, P_REPORTSCROLL reported
    // ================================================================

    /// P_SCROLLPOS (in a record or a Set): the view put there once it's laid out, then the key forgotten so a later
    /// Set of other properties doesn't move it again.
    private func sScrollPosApply(_ b: SBlock) {
        guard let v = b.props[Sn.pScrollPos], v.count == 4 else { return }
        var at = CGFloat(Float(bitPattern: sceneLE32(v, 0)))
        if !at.isFinite {
            at = 0
        }
        b.props[Sn.pScrollPos] = nil
        b.scroll = at >= 1e6 ? b.scrollMax : min(max(at * su, 0), b.scrollMax)
        b.atEnd = b.scroll >= b.scrollMax - 1
        b.anchorRow = -1
    }

    /// Every frame for each tree: the clocks' text, countdowns reaching zero, and scroll positions that came to rest
    /// (Scrolled).
    private func sceneTimers6(_ s: SceneTree) {
        let now = Date()
        let nowU = UInt32(clamping: Int64(now.timeIntervalSince1970))
        for b in s.order where b.pass == s.pass {
            if b.kind == Sn.bkText && b.has(Sn.pClock) {
                let t = Self.sClockCompute(b)
                if t != b.clockText {
                    b.clockText = t
                    sceneGen += 1   // measured again: "9:59" to "10:00" is wider
                }
                if b.num(Sn.pClock) == Sn.clockCountdown && b.id != 0 && b.has(Sn.pAt) && b.timerFor != b.u32(Sn.pAt)
                    && nowU >= b.u32(Sn.pAt) {
                    b.timerFor = b.u32(Sn.pAt)
                    reply("Timer;id=\(b.id)")
                }
            }
            if b.id != 0 && b.has(Sn.pReportScroll) && (b.kind == Sn.bkScroll || b.kind == Sn.bkVList || b.kind == Sn.bkViewer) {
                let su = self.su
                let cur = (pos: Self.sR10(b.scroll / su), max: Self.sR10(b.scrollMax / su), view: Self.sR10(b.view / su))
                if cur != b.repCur {
                    b.repCur = cur
                    b.repAt = now
                    b.repPending = true
                }
                if b.repPending && now.timeIntervalSince(b.repAt) * 1000 >= Double(max(b.num(Sn.pReportScroll), 50)) {
                    b.repPending = false
                    let end = b.scrollMax - b.scroll <= su
                    reply("Scrolled;id=\(b.id);pos=\(Self.sF1(cur.pos));max=\(Self.sF1(cur.max));view=\(Self.sF1(cur.view))"
                          + ";end=\(end ? 1 : 0)")
                }
            }
        }
    }

    /// SF_SIZE: Size;w=;h= (units) when the scene is shown, and again once its space has been still 300 ms after
    /// changing.
    private func sSceneSizeCheck(_ s: SceneTree, _ space: CGRect) {
        guard s.flags & Sn.sfSize != 0, s === scene else { return }
        let cur = (w: Self.sR10(space.width / su), h: Self.sR10(space.height / su))
        let now = Date()
        if cur != s.sizeCur {
            let first = s.sizeCur.w < 0
            s.sizeCur = cur
            s.sizeAt = first ? now.addingTimeInterval(-1) : now
            s.sizePending = true
        }
        if s.sizePending && now.timeIntervalSince(s.sizeAt) >= 0.3 {
            s.sizePending = false
            reply("Size;w=\(Self.sF1(cur.w));h=\(Self.sF1(cur.h))")
        }
    }

    // ================================================================
    // Clocks (P_CLOCK, P_AT)
    // ================================================================

    private static func sFormatter(_ date: DateFormatter.Style, _ time: DateFormatter.Style) -> DateFormatter {
        let f = DateFormatter()
        f.dateStyle = date
        f.timeStyle = time
        return f
    }

    // .NET's "t", "T", "d", "g" in the device's own way
    private static let sFmtT = sFormatter(.none, .short), sFmtTs = sFormatter(.none, .medium),
                       sFmtD = sFormatter(.short, .none), sFmtG = sFormatter(.short, .short)

    /// The text a clock block shows (computed when it has none yet).
    private func sClockString(_ b: SBlock) -> String {
        if b.clockText.isEmpty {
            b.clockText = Self.sClockCompute(b)
        }
        return b.clockText
    }

    private static func sClockCompute(_ b: SBlock) -> String {
        let now = Date()
        let at: Int64 = b.has(Sn.pAt) ? Int64(b.u32(Sn.pAt)) : 0
        let nowU = Int64(now.timeIntervalSince1970)
        switch b.num(Sn.pClock) {
        case Sn.clockTime: return sFmtT.string(from: now)
        case Sn.clockTimeSec: return sFmtTs.string(from: now)
        case Sn.clockDate: return sFmtD.string(from: now)
        case Sn.clockDateTime: return sFmtG.string(from: now)
        case Sn.clockCountdown: return sClockSpan(max(at - nowU, 0))
        case Sn.clockElapsed: return sClockSpan(max(nowU - at, 0))
        case Sn.clockAgo: return sAgo(nowU - at)
        case Sn.clockAt: return at > 0 ? sFmtG.string(from: Date(timeIntervalSince1970: TimeInterval(at))) : ""
        default: return ""
        }
    }

    /// 4:05, 1:02:03, 2d 4:05:06.
    private static func sClockSpan(_ secs: Int64) -> String {
        let d = secs / 86400, h = secs / 3600 % 24, m = secs / 60 % 60, sec = secs % 60
        if d > 0 {
            return String(format: "%lldd %lld:%02lld:%02lld", d, h, m, sec)
        }
        if h > 0 {
            return String(format: "%lld:%02lld:%02lld", h, m, sec)
        }
        return String(format: "%lld:%02lld", m, sec)
    }

    /// "just now", "5 min ago", "3 h ago", "yesterday", "4 days ago"; ahead: "in 5 min"...
    private static func sAgo(_ secs: Int64) -> String {
        let ahead = secs < 0
        let a = abs(secs)
        if a < 45 {
            return "just now"
        }
        let t: String
        if a < 90 * 60 {
            t = "\(max(a / 60, 1)) min"
        } else if a < 24 * 3600 {
            t = "\(a / 3600) h"
        } else if a < 48 * 3600 {
            return ahead ? "tomorrow" : "yesterday"
        } else {
            t = "\(a / 86400) days"
        }
        return ahead ? "in " + t : t + " ago"
    }

    // ================================================================
    // The split block
    // ================================================================

    private func sMinPane(_ b: SBlock) -> CGFloat { (b.has(Sn.pSplitMin) ? max(b.real(Sn.pSplitMin), 0) : 6) * su }

    private func sSplitShare(_ b: SBlock) -> CGFloat {
        min(max(b.splitAt >= 0 ? b.splitAt : b.has(Sn.pSplitAt) ? b.real(Sn.pSplitAt) : 0.5, 0.05), 0.95)
    }

    private func sNaturalV6(_ b: SBlock, _ inner: CGFloat, _ fixH: CGFloat) -> CGSize {
        let su = self.su
        switch b.kind {
        case Sn.bkSplit:
            let kids = Self.sVisibleKids(b)
            let div = 0.6 * su
            if kids.isEmpty {
                return .zero
            }
            if kids.count == 1 {
                return sMeasure(kids[0], inner)
            }
            if b.num(Sn.pAxis) == 0 {
                let each = inner.isInfinite ? inner : max((inner - div) / 2, 0)
                let a = sMeasure(kids[0], each), c = sMeasure(kids[1], each)
                return CGSize(width: a.width + div + c.width, height: max(a.height, c.height))
            }
            let x = sMeasure(kids[0], inner), y = sMeasure(kids[1], inner)
            return CGSize(width: max(x.width, y.width), height: x.height + div + y.height)
        case Sn.bkChart:
            return b.num(Sn.pChart) == Sn.chartSpark ? CGSize(width: 8 * su, height: 1.5 * su) : CGSize(width: 16 * su, height: 6 * su)
        case Sn.bkSlider:
            let sides = sSliderSides(b)
            return CGSize(width: sides.l + 12 * su + sides.v, height: 1.6 * su)
        case Sn.bkCanvas:
            let vw = Self.sCanvasW(b), vh = Self.sCanvasH(b)
            let w = inner.isInfinite ? 16 * su : min(16 * su, inner)
            if fixH > 0 {
                return CGSize(width: fixH * vw / vh, height: fixH)
            }
            return CGSize(width: w, height: w * vh / vw)
        default:
            return .zero
        }
    }

    /// The two panes either side of the divider, each at least P_SPLITMIN; one child fills the box.
    private func sArrangeSplit(_ s: SceneTree, _ b: SBlock, _ inner: CGRect, _ clip: CGRect) {
        let kids = Self.sVisibleKids(b)
        b.splitBar = .zero
        if kids.isEmpty {
            return
        }
        if kids.count == 1 {
            sArrange(s, kids[0], inner, clip, b.off)
            return
        }
        let across = b.num(Sn.pAxis) == 0
        let div = 0.6 * su, total = (across ? inner.width : inner.height) - div, least = sMinPane(b)
        var a = total < 2 * least ? total / 2 : min(max(total * sSplitShare(b), least), total - least)
        a = (a * sDpi).rounded() / sDpi
        if across {
            sArrange(s, kids[0], Self.sR(inner.minX, inner.minY, a, inner.height), clip, b.off)
            b.splitBar = Self.sR(inner.minX + a, inner.minY, div, inner.height)
            sArrange(s, kids[1], Self.sR(inner.minX + a + div, inner.minY, max(total - a, 0), inner.height), clip, b.off)
        } else {
            sArrange(s, kids[0], Self.sR(inner.minX, inner.minY, inner.width, a), clip, b.off)
            b.splitBar = Self.sR(inner.minX, inner.minY + a, inner.width, div)
            sArrange(s, kids[1], Self.sR(inner.minX, inner.minY + a + div, inner.width, max(total - a, 0)), clip, b.off)
        }
    }

    /// The panes, then the divider: a line, brighter under the pointer or while dragged, with a grip.
    private func sDrawSplit(_ s: SceneTree, _ b: SBlock, _ clip: CGRect) {
        sDrawKids(s, b, clip)
        guard !b.splitBar.isEmpty else { return }
        let bar = b.splitBar
        let across = b.num(Sn.pAxis) == 0
        let dragged = drag6.map { $0.kind == .split && $0.b === b } ?? false
        let hot = dragged || (Self.sInset(bar, -3 * u).contains(sMouse) && !b.off)
        let c = hot ? scol(.accent) : scol(.border), a: CGFloat = hot ? 1 : 170.0 / 255
        let t = max(hot ? 2 * u : 1 * u, 1)
        Self.color(c, a).setFill()
        (across ? Self.sR(bar.minX + (bar.width - t) / 2, bar.minY, t, bar.height)
                : Self.sR(bar.minX, bar.minY + (bar.height - t) / 2, bar.width, t)).fill(using: .sourceOver)
        // the grip: three dots in the middle
        let cx = bar.midX, cy = bar.midY, g = 4 * u, r = max(1.4 * u, 1)
        for i in -1...1 {
            let p = across ? CGPoint(x: cx, y: cy + CGFloat(i) * g) : CGPoint(x: cx + CGFloat(i) * g, y: cy)
            NSBezierPath(ovalIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)).fill()
        }
    }

    // ================================================================
    // Panes: a click gives one the keys
    // ================================================================

    private static func sPaneAt(_ s: SceneTree, _ p: CGPoint) -> SBlock? {
        s.order.last { b in
            (b.kind == Sn.bkScroll || b.kind == Sn.bkVList) && b.flag(Sn.pPane) && sFocusable(s, b) && b.box.contains(p)
                && b.clip.contains(p)
        }
    }

    /// A focused pane's keys: the arrows and paging go to the board (a pane's keys are the board's, which answers with
    /// P_SCROLLBY); Left and Right move the focus as usual.
    private func sPaneKey(_ s: SceneTree, _ f: SBlock, _ code: UInt16) -> Bool {
        guard f.flag(Sn.pPane) else { return false }
        let vk: Int
        switch code {
        case 126: vk = Self.vkUp
        case 125: vk = Self.vkDown
        case 116: vk = Self.vkPgUp
        case 121: vk = Self.vkPgDn
        case 115: vk = Self.vkHome
        case 119: vk = Self.vkEnd
        default: return false
        }
        sceneSendKey(s, vk, false, false, 0)
        return true
    }

    private func sDrawPaneFocus(_ b: SBlock) {
        sStrokeRR(Self.sInset(b.box, 0.6 * u), 5 * u, max(1.2 * u, 1), scol(.focus), 150.0 / 255)
    }

    // ================================================================
    // Wrapping multi-line fields and inputs as typed
    // ================================================================

    /// v's drawn lines (start, end) wrapped by words at width, or P_WRAPCOLS columns of the font when that's narrower;
    /// the value keeps its own line breaks (a "\n" ends a line, and isn't in it). A word wider than a line breaks where
    /// it must. Kept on b while the text, width and font stay the same.
    private func sWrapValue(_ b: SBlock, _ v: [Character], _ f: NSFont, _ width: CGFloat) -> [(start: Int, end: Int)] {
        var w = max(width, 10 * u)
        let cols = b.num(Sn.pWrapCols)
        if cols > 0 {
            w = min(w, CGFloat(cols) * Self.textW("0", f))
        }
        let face = "\(f.fontName)/\(f.pointSize)"
        if let vl = b.vLines, b.wrapV == v, abs(b.wrapW - w) < 0.5, b.wrapFace == face {
            return vl
        }
        var lines: [(start: Int, end: Int)] = []
        var ps = 0
        while true {
            var pe = ps
            while pe < v.count && v[pe] != "\n" {
                pe += 1
            }
            sWrapPara(v, ps, pe, f, w, &lines)
            if pe >= v.count {
                break
            }
            ps = pe + 1
        }
        b.wrapV = v
        b.wrapW = w
        b.wrapFace = face
        b.vLines = lines
        return lines
    }

    private func sWrapPara(_ v: [Character], _ ps: Int, _ pe: Int, _ f: NSFont, _ w: CGFloat,
                           _ lines: inout [(start: Int, end: Int)]) {
        if ps >= pe {
            lines.append((ps, pe))
            return
        }
        func tw(_ a: Int, _ b: Int) -> CGFloat { Self.textW(String(v[a..<b]), f) }
        var start = ps
        while start < pe {
            if tw(start, pe) <= w {
                lines.append((start, pe))
                return
            }
            var brk = -1
            var i = start
            while i < pe {
                var j = i
                while j < pe && v[j] != " " {
                    j += 1   // the word's end
                }
                if j > start && tw(start, j) > w {
                    break
                }
                var jj = j
                while jj < pe && v[jj] == " " {
                    jj += 1   // its spaces stay on this line
                }
                brk = jj
                i = jj
            }
            if brk > start && brk < pe {
                lines.append((start, brk))
                start = brk
                continue
            }
            // a word wider than the line: as many characters as fit
            var k = start + 1
            while k < pe && tw(start, k + 1) <= w {
                k += 1
            }
            lines.append((start, k))
            start = k
        }
    }

    /// The drawn line the caret at cur is on: the last that starts at or before it.
    private static func sVLineOf(_ vl: [(start: Int, end: Int)], _ cur: Int) -> Int {
        var at = 0
        for i in vl.indices {
            if vl[i].start <= cur {
                at = i
            } else {
                break
            }
        }
        return at
    }

    /// Where the caret may go at the end of drawn line i: before a soft break's last character (the space it broke
    /// at), so it doesn't show on the next line.
    private static func sVLineEffEnd(_ vl: [(start: Int, end: Int)], _ i: Int) -> Int {
        let e = vl[i].end
        return i + 1 < vl.count && vl[i + 1].start == e && e > vl[i].start ? e - 1 : e
    }

    /// The drawn lines for b's value now, if they were drawn for it (nil: they're stale, use "\n" lines).
    private static func sVLinesNow(_ b: SBlock) -> [(start: Int, end: Int)]? {
        guard let vl = b.vLines, !vl.isEmpty, b.wrapV == b.value, !b.flag(Sn.pSecret) else { return nil }
        return vl
    }

    private func sVLineStart(_ b: SBlock, _ v: [Character], _ cur: Int) -> Int {
        if let vl = Self.sVLinesNow(b) {
            return vl[Self.sVLineOf(vl, cur)].start
        }
        return Self.sLineStart(v, cur)
    }

    private func sVLineEnd(_ b: SBlock, _ v: [Character], _ cur: Int) -> Int {
        if let vl = Self.sVLinesNow(b) {
            return Self.sVLineEffEnd(vl, Self.sVLineOf(vl, cur))
        }
        return Self.sLineEnd(v, cur)
    }

    /// Up (-1) or Down (1) by drawn lines, keeping the caret's x.
    private func sVLineStep(_ b: SBlock, _ v: [Character], _ d: Int) -> Bool {
        guard let vl = Self.sVLinesNow(b) else { return false }
        let li = Self.sVLineOf(vl, b.cur), t = li + d
        if t < 0 || t >= vl.count {
            return true
        }
        let cur = min(b.cur, v.count)
        let x = Self.textW(String(v[min(vl[li].start, cur)..<cur]), font(false, sSize))
        b.cur = sColumnAt(v, vl[t].start, max(Self.sVLineEffEnd(vl, t), vl[t].start), x)
        return true
    }

    // ================================================================
    // Charts
    // ================================================================

    private func sChartRange(_ b: SBlock, _ a: [CGFloat], _ c: [CGFloat]) -> (lo: CGFloat, hi: CGFloat) {
        var lo = CGFloat.greatestFiniteMagnitude, hi = -CGFloat.greatestFiniteMagnitude
        for v in a + c {
            lo = min(lo, v)
            hi = max(hi, v)
        }
        if lo == CGFloat.greatestFiniteMagnitude {
            lo = 0
            hi = 1
        }
        if b.num(Sn.pChart) == Sn.chartBar {
            lo = min(lo, 0)
            hi = max(hi, 0)
        }
        if b.has(Sn.pMinV) {
            lo = b.real(Sn.pMinV)
        }
        if b.has(Sn.pMaxV) {
            hi = b.real(Sn.pMaxV)
        }
        if hi - lo < 1e-9 {
            hi = lo + 1
        }
        return (lo, hi)
    }

    /// v with at most n decimals, trailing zeros dropped (.NET's "0.#", "0.##"), invariant.
    private static func sTrim(_ v: CGFloat, _ n: Int) -> String {
        var t = String(format: "%.\(n)f", Double(v))
        if t.contains(".") {
            while t.hasSuffix("0") {
                t.removeLast()
            }
            if t.hasSuffix(".") {
                t.removeLast()
            }
        }
        return t == "-0" ? "0" : t
    }

    private static func sChartNum(_ v: CGFloat) -> String {
        if abs(v) >= 1e6 {
            return sTrim(v / 1e6, 1) + "M"
        }
        if abs(v) >= 1e4 {
            return sTrim(v / 1e3, 1) + "k"
        }
        if abs(v - v.rounded()) < 1e-6 {
            return String(Int64(v.rounded()))
        }
        return sTrim(v, 2)
    }

    /// A line, bar, area or sparkline chart of P_DATA (and P_DATA2) in the block, with value labels, grid lines, the
    /// labels under it, and a tip at the point nearest the pointer, as P_AXES says.
    private func sDrawChart(_ b: SBlock) {
        let a = b.f32s(Sn.pData), c = b.f32s(Sn.pData2)
        let r = b.inner
        let kind = b.num(Sn.pChart)
        let su = self.su
        let axes = b.has(Sn.pAxes) ? b.num(Sn.pAxes) : kind == Sn.chartSpark ? Sn.axesTip : Sn.axesLabels | Sn.axesGrid | Sn.axesTip
        guard r.width >= 4, r.height >= 4, !a.isEmpty else {
            b.plot = .zero
            return
        }
        let range = sChartRange(b, a, c)
        let lo = range.lo, hi = range.hi
        let unit = b.str(Sn.pUnit)
        let labels = b.strs(Sn.pLabels)
        let fs = sSmallSize * 0.9
        let lf = font(false, fs)
        var lw: CGFloat = 0, lh: CGFloat = 0
        if axes & Sn.axesLabels != 0 && kind != Sn.chartSpark {
            lw = max(Self.textW(Self.sChartNum(hi) + unit, lf), Self.textW(Self.sChartNum(lo) + unit, lf)) + 0.4 * su
            if !labels.isEmpty {
                lh = Self.fontLine(lf) + 0.15 * su
            }
        }
        let topPad = kind == Sn.chartSpark ? 0 : 0.3 * su
        let plot = Self.sR(r.minX + lw, r.minY + topPad, r.width - lw, r.height - lh - topPad)
        b.plot = plot
        guard plot.width >= 2, plot.height >= 2 else { return }
        func y(_ v: CGFloat) -> CGFloat { plot.maxY - (min(max(v, lo), hi) - lo) / (hi - lo) * plot.height }
        let dim = scol(.dim)
        if axes & Sn.axesGrid != 0 && kind != Sn.chartSpark {
            Self.color(scol(.border), 70.0 / 255).setFill()
            for i in 0...2 {
                let gy = plot.minY + plot.height * CGFloat(i) / 2
                Self.sR(plot.minX, (gy * sDpi).rounded() / sDpi, plot.width, max(u * 0.8, 1 / sDpi)).fill(using: .sourceOver)
            }
        }
        if lw > 0 {
            let top = Self.text(Self.sChartNum(hi) + unit, lf, dim), bot = Self.text(Self.sChartNum(lo) + unit, lf, dim)
            top.draw(at: CGPoint(x: r.minX + lw - 0.3 * su - top.size().width, y: plot.minY - top.size().height / 2))
            bot.draw(at: CGPoint(x: r.minX + lw - 0.3 * su - bot.size().width, y: plot.maxY - bot.size().height / 2))
        }
        let c1 = Self.ucol(b, Sn.pFg) ?? scol(.accent), c2 = Self.ucol(b, Sn.pGrad) ?? scol(.accent2)
        let n = max(a.count, c.count)
        func x(_ i: Int) -> CGFloat { n <= 1 ? plot.midX : plot.minX + plot.width * CGFloat(i) / CGFloat(n - 1) }
        if kind == Sn.chartBar {
            let series = c.isEmpty ? 1 : 2
            let slot = plot.width / CGFloat(n), bw = max(slot * 0.7 / CGFloat(series), 1), y0 = y(min(max(0, lo), hi))
            for i in 0..<n {
                for k in 0..<series {
                    let d = k == 0 ? a : c
                    if i >= d.count {
                        continue
                    }
                    let bx = plot.minX + slot * CGFloat(i) + slot * 0.15 + bw * CGFloat(k), by = y(d[i])
                    sFillRR(Self.sR(bx, min(by, y0), bw, max(abs(y0 - by), 1)), 1.5 * u, k == 0 ? c1 : c2)
                }
            }
        } else {
            for (d, col) in [(a, c1), (c, c2)] where !d.isEmpty {
                let line = NSBezierPath()
                line.move(to: CGPoint(x: x(0), y: y(d[0])))
                for i in 1..<max(d.count, 1) {
                    line.line(to: CGPoint(x: x(i), y: y(d[i])))
                }
                if kind == Sn.chartArea || kind == Sn.chartSpark {
                    let area = NSBezierPath()
                    area.move(to: CGPoint(x: x(0), y: plot.maxY))
                    for i in 0..<d.count {
                        area.line(to: CGPoint(x: x(i), y: y(d[i])))
                    }
                    area.line(to: CGPoint(x: x(d.count - 1), y: plot.maxY))
                    area.close()
                    Self.color(col, CGFloat(kind == Sn.chartSpark ? 40 : 80) / 255).setFill()
                    area.fill()
                }
                line.lineWidth = max((kind == Sn.chartSpark ? 1.4 : 1.8) * u, 1)
                line.lineJoinStyle = .round
                Self.color(col).setStroke()
                line.stroke()
            }
        }
        if lh > 0 {   // labels under it, as many as fit
            let room = plot.width / CGFloat(max(n, 1))
            let widest = labels.map { Self.textW($0, lf) + 0.4 * su }.max() ?? 0
            let every = max(1, Int((widest / max(room, 1)).rounded(.up)))
            var i = 0
            while i < labels.count && i < n {
                let t = Self.text(labels[i], lf, dim)
                let tw = t.size().width
                let cx = kind == Sn.chartBar ? plot.minX + room * (CGFloat(i) + 0.5) : x(i)
                t.draw(at: CGPoint(x: min(max(cx - tw / 2, r.minX), r.maxX - tw), y: plot.maxY + 0.15 * su))
                i += every
            }
        }
        // the tip at the point nearest the pointer
        let m = sMouse
        if axes & Sn.axesTip != 0 && !b.off && plot.contains(m) && b.clip.contains(m) {
            let hi2 = sChartIndexAt(b, m)
            guard hi2 >= 0 else { return }
            let cx = kind == Sn.chartBar ? plot.minX + plot.width / CGFloat(n) * (CGFloat(hi2) + 0.5) : x(hi2)
            Self.color(scol(.text), 60.0 / 255).setFill()
            Self.sR(cx, plot.minY, max(u, 1), plot.height).fill(using: .sourceOver)
            let tip = (hi2 < labels.count ? labels[hi2] + ": " : "") + (hi2 < a.count ? Self.sChartNum(a[hi2]) + unit : "")
                + (hi2 < c.count ? " / " + Self.sChartNum(c[hi2]) + unit : "")
            let tf = font(true, sSmallSize)
            let ft = Self.text(tip, tf, scol(.text))
            let bw = ft.size().width + 0.8 * su, bh = ft.size().height + 0.3 * su
            let bx = min(max(cx + 0.4 * su, r.minX), max(r.maxX - bw, r.minX)), by = plot.minY
            sFillRR(Self.sR(bx, by, bw, bh), 4 * u, Self.mix(scol(.panel), 0, 0.3), 235.0 / 255)
            ft.draw(at: CGPoint(x: bx + 0.4 * su, y: by + 0.15 * su))
        }
    }

    /// The chart's point nearest p across (-1: not over the plot).
    private func sChartIndexAt(_ b: SBlock, _ p: CGPoint) -> Int {
        let plot = b.plot
        let n = max(b.f32s(Sn.pData).count, b.f32s(Sn.pData2).count)
        if plot.isEmpty || n == 0 || p.x < plot.minX - 4 * u || p.x > plot.maxX + 4 * u {
            return -1
        }
        if b.num(Sn.pChart) == Sn.chartBar {
            return min(max(Int(((p.x - plot.minX) / (plot.width / CGFloat(n))).rounded(.towardZero)), 0), n - 1)
        }
        return n <= 1 ? 0 : min(max(Int(((p.x - plot.minX) / plot.width * CGFloat(n - 1)).rounded()), 0), n - 1)
    }

    // ================================================================
    // Sliders and number boxes
    // ================================================================

    private static func sLo(_ b: SBlock) -> CGFloat { b.has(Sn.pMinV) ? b.real(Sn.pMinV) : 0 }
    private static func sHi(_ b: SBlock) -> CGFloat { max(b.has(Sn.pMaxV) ? b.real(Sn.pMaxV) : 100, sLo(b)) }
    private static func sSliderValue(_ b: SBlock) -> CGFloat {
        min(max(b.numV.isNaN ? b.real(Sn.pValue) : b.numV, sLo(b)), sHi(b))
    }

    private static func sSliderText(_ b: SBlock, _ v: CGFloat) -> String {
        let step = b.real(Sn.pStep)
        let places = step >= 1 || (step <= 0 && sHi(b) - sLo(b) >= 20) ? 0 : step >= 0.1 || step <= 0 ? 1 : 2
        return String(format: "%.\(places)f", locale: Locale.current, Double(v)) + b.str(Sn.pUnit)
    }

    /// The room a slider's label takes at its left and its value at its right.
    private func sSliderSides(_ b: SBlock) -> (l: CGFloat, v: CGFloat) {
        let su = self.su
        let label = b.str(Sn.pLabel)
        let lw = label.isEmpty ? 0 : Self.textW(label, font(false, sSize)) + 0.6 * su
        let bf = font(true, sSize)
        let vw = b.flag(Sn.pSpin) ? 0
            : max(Self.textW(Self.sSliderText(b, Self.sHi(b)), bf), Self.textW(Self.sSliderText(b, Self.sLo(b)), bf)) + 0.6 * su
        return (lw, vw)
    }

    /// A slider's parts: its track (or a number box's value), and a number box's - and + buttons.
    private func sSliderParts(_ b: SBlock) -> (track: CGRect, minus: CGRect, plus: CGRect) {
        let r = b.box, su = self.su
        let sides = sSliderSides(b)
        let room = Self.sR(r.minX + sides.l, r.minY, r.width - sides.l - sides.v, r.height)
        if !b.flag(Sn.pSpin) {
            return (Self.sR(room.minX + 0.5 * su, room.minY, room.width - su, room.height), .zero, .zero)
        }
        let s = min(room.height, 1.6 * su)
        let minus = Self.sR(room.minX, room.minY + (room.height - s) / 2, s, s)
        let plus = Self.sR(room.maxX - s, minus.minY, s, s)
        return (Self.sR(minus.maxX, minus.minY, plus.minX - minus.maxX, s), minus, plus)
    }

    /// v as .NET's "R" (round-trip, invariant): whole numbers without ".0".
    private static func sRoundTrip(_ v: CGFloat) -> String {
        let d = Double(v)
        if d == d.rounded() && abs(d) < 1e15 {
            return String(Int64(d))
        }
        return "\(d)"
    }

    /// A slider's value set to v (on its step, in its range); sent now when final, or while dragging when P_LIVE (at
    /// most 10 a second).
    private func sSliderSet(_ b: SBlock, _ v0: CGFloat, _ final: Bool) {
        let lo = Self.sLo(b), hi = Self.sHi(b), step = b.real(Sn.pStep)
        var v = v0
        if step > 0 {
            v = lo + ((v - lo) / step).rounded() * step
        }
        v = min(max(v, lo), hi)
        b.numV = v
        let now = Date()
        if b.id != 0 && !b.off && v != b.numSent && (final || (b.flag(Sn.pLive) && now.timeIntervalSince(b.numAt) >= 0.1)) {
            b.numSent = v
            b.numAt = now
            reply("Change;id=\(b.id);v=\(Self.sRoundTrip(v))")
        }
        redraw()
    }

    private static func sSliderStep(_ b: SBlock) -> CGFloat { b.real(Sn.pStep) > 0 ? b.real(Sn.pStep) : (sHi(b) - sLo(b)) / 100 }

    private func sSliderKey(_ b: SBlock, _ code: UInt16) -> Bool {
        let v = Self.sSliderValue(b), st = Self.sSliderStep(b)
        switch code {
        case 123, 125: sSliderSet(b, v - st, true)          // Left, Down
        case 124, 126: sSliderSet(b, v + st, true)          // Right, Up
        case 121: sSliderSet(b, v - 10 * st, true)          // Page Down
        case 116: sSliderSet(b, v + 10 * st, true)          // Page Up
        case 115: sSliderSet(b, Self.sLo(b), true)          // Home
        case 119: sSliderSet(b, Self.sHi(b), true)          // End
        default: return false
        }
        return true
    }

    private func sDrawSlider(_ s: SceneTree, _ b: SBlock) {
        let su = self.su
        let r = b.box
        let focus = sFocused(s, b)
        let v = Self.sSliderValue(b), lo = Self.sLo(b), hi = Self.sHi(b), f = hi > lo ? (v - lo) / (hi - lo) : 0
        let m = sMouse
        let label = b.str(Sn.pLabel)
        if !label.isEmpty {
            let lf = font(false, sSize)
            Self.text(Self.fitText(label, lf, max(r.width * 0.5, 1)), lf, Self.ucol(b, Sn.pFg) ?? scol(.text))
                .draw(at: CGPoint(x: r.minX, y: Self.capY(lf, r.midY)))
        }
        let parts = sSliderParts(b)
        let bf = font(true, sSize)
        let vt = Self.text(Self.sSliderText(b, v), bf, scol(.text))
        if b.flag(Sn.pSpin) {
            let rad = max(st.selRadius, 4) * u
            let box = Self.sR(parts.minus.minX, parts.minus.minY, parts.plus.maxX - parts.minus.minX, parts.minus.height)
            sFillRR(box, rad, scol(.fieldBg))
            sStrokeRR(box, rad, (focus ? 1.5 : 1) * u, focus ? scol(.focus) : scol(.border), focus ? 1 : 170.0 / 255)
            for (bx, sign) in [(parts.minus, -1), (parts.plus, 1)] {
                if !b.off && bx.contains(m) {
                    sFillRR(Self.sInset(bx, 2 * u), rad, scol(.selBg), 90.0 / 255)
                }
                let g = NSBezierPath()
                g.lineWidth = 1.6 * u
                g.lineCapStyle = .round
                let cx = bx.midX, cy = bx.midY, a = bx.height * 0.2
                g.move(to: CGPoint(x: cx - a, y: cy))
                g.line(to: CGPoint(x: cx + a, y: cy))
                if sign > 0 {
                    g.move(to: CGPoint(x: cx, y: cy - a))
                    g.line(to: CGPoint(x: cx, y: cy + a))
                }
                Self.color(scol(.text)).setStroke()
                g.stroke()
            }
            let t = parts.track
            vt.draw(at: CGPoint(x: t.minX + (t.width - vt.size().width) / 2, y: Self.capY(bf, t.midY)))
            return
        }
        let track = parts.track
        let th = 0.3 * su, cy2 = r.midY
        let line = Self.sR(track.minX, cy2 - th / 2, track.width, th)
        sFillRR(line, th / 2, scol(.text), 45.0 / 255)
        let acc = Self.ucol(b, Sn.pFg) ?? scol(.accent)
        sFillRR(Self.sR(line.minX, line.minY, line.width * f, th), th / 2, acc)
        let kx = track.minX + track.width * f, kr = 0.45 * su
        let dragged = drag6.map { $0.kind == .slider && $0.b === b } ?? false
        let hot = !b.off && (dragged || Self.sInset(Self.sR(kx - kr, cy2 - kr, 2 * kr, 2 * kr), -3 * u).contains(m))
        if focus {
            let ring = NSBezierPath(ovalIn: CGRect(x: kx - kr - 3 * u, y: cy2 - kr - 3 * u, width: 2 * (kr + 3 * u),
                                                   height: 2 * (kr + 3 * u)))
            ring.lineWidth = 2 * u
            Self.color(scol(.focus), 160.0 / 255).setStroke()
            ring.stroke()
        }
        let knob = NSBezierPath(ovalIn: CGRect(x: kx - kr, y: cy2 - kr, width: 2 * kr, height: 2 * kr))
        Self.color(hot ? Self.mix(acc, 0xFF_FFFF, 0.25) : acc).setFill()
        knob.fill()
        knob.lineWidth = max(u, 1)
        Self.color(Self.mix(acc, 0, 0.3)).setStroke()
        knob.stroke()
        vt.draw(at: CGPoint(x: r.maxX - vt.size().width, y: Self.capY(bf, r.midY)))
    }

    // ================================================================
    // The canvas (SceneDraw)
    // ================================================================

    private static func sCanvasW(_ b: SBlock) -> CGFloat { b.has(Sn.pViewW) && b.real(Sn.pViewW) > 0 ? b.real(Sn.pViewW) : 100 }
    private static func sCanvasH(_ b: SBlock) -> CGFloat { b.has(Sn.pViewH) && b.real(Sn.pViewH) > 0 ? b.real(Sn.pViewH) : 100 }

    /// SceneDraw (RainwireMenu.swift handle): into the screen's scene.
    func onSceneDraw(_ p: [UInt8]) {
        if let s = scene, isScene {
            sceneDrawInto(s, p)
        }
    }

    /// SceneDraw into tree s (a screen's or a gadget's): u16 id, u8 mode, u8 reserved, u16 count, then commands (u8 op,
    /// u16 len, payload); unknown ops are kept and skipped when drawn. Past the caps, the drawing stops there.
    func sceneDrawInto(_ s: SceneTree, _ p: [UInt8]) {
        guard p.count >= 10, let b = s.byId[UInt16(Self.sU16(p, 4))], b.kind == Sn.bkCanvas else { return }
        if p[6] == Sn.drawReplace || b.drawOps == nil {
            b.drawOps = []
            b.drawBytes = 0
        }
        let n = Self.sU16(p, 8)
        var o = 10
        var ops = b.drawOps ?? []
        var i = 0
        while i < n && o + 3 <= p.count {
            let len = Self.sU16(p, o + 1)
            if o + 3 + len > p.count {
                break
            }
            if ops.count < Sn.canvasMaxOps && b.drawBytes + len <= Sn.canvasMaxBytes {
                ops.append((op: p[o], pay: Array(p[(o + 3)..<(o + 3 + len)])))
                b.drawBytes += len + 3
            }
            o += 3 + len
            i += 1
        }
        b.drawOps = ops
        b.drawCache = nil
        redraw()
    }

    private static func sDCol(_ c: UInt32) -> UInt32? { c & 0xFF00_0000 != 0 ? nil : c }

    /// The canvas's commands parsed into shapes in its own coordinates, and its tagged shapes' hit areas; built again
    /// when the commands or the call's pictures change.
    @discardableResult
    private func sCanvasBuild(_ b: SBlock) -> [SCanvasItem] {
        if let c = b.drawCache, b.drawAssets == sceneAssets.count {
            return c
        }
        var items: [SCanvasItem] = []
        var tags: [(tag: Int, path: CGPath)] = []
        let vw = Self.sCanvasW(b)
        var tag = 0
        for (op, d) in b.drawOps ?? [] {
            func f(_ at: Int) -> CGFloat {
                guard at + 4 <= d.count else { return 0 }
                let v = Float(bitPattern: sceneLE32(d, at))
                return v.isFinite ? CGFloat(v) : 0
            }
            func c(_ at: Int) -> UInt32 { at + 4 <= d.count ? sceneLE32(d, at) : 0xFF00_0000 }
            var hit: CGPath?
            switch op {
            case Sn.dTag:
                if d.count >= 2 {
                    tag = Int(d[0]) | Int(d[1]) << 8
                }
            case Sn.dLine:
                if d.count >= 24, let col = Self.sDCol(c(16)), f(20) > 0 {
                    let ln = CGMutablePath()
                    ln.move(to: CGPoint(x: f(0), y: f(4)))
                    ln.addLine(to: CGPoint(x: f(8), y: f(12)))
                    items.append(.shape(path: ln, fill: nil, stroke: col, width: f(20)))
                    hit = ln.copy(strokingWithWidth: max(f(20), vw / 100), lineCap: .round, lineJoin: .round, miterLimit: 10)
                }
            case Sn.dRect:
                if d.count >= 32 {
                    let rect = CGRect(x: f(0), y: f(4), width: max(f(8), 0), height: max(f(12), 0))
                    let rad = min(max(f(28), 0), rect.width / 2, rect.height / 2)
                    let rg = CGPath(roundedRect: rect, cornerWidth: rad, cornerHeight: rad, transform: nil)
                    items.append(.shape(path: rg, fill: Self.sDCol(c(16)), stroke: f(24) > 0 ? Self.sDCol(c(20)) : nil, width: f(24)))
                    hit = rg
                }
            case Sn.dEllipse:
                if d.count >= 28 {
                    let rx = abs(f(8)), ry = abs(f(12))
                    let eg = CGPath(ellipseIn: CGRect(x: f(0) - rx, y: f(4) - ry, width: 2 * rx, height: 2 * ry), transform: nil)
                    items.append(.shape(path: eg, fill: Self.sDCol(c(16)), stroke: f(24) > 0 ? Self.sDCol(c(20)) : nil, width: f(24)))
                    hit = eg
                }
            case Sn.dPoly:
                if d.count >= 15 {
                    let n = Int(d[13]) | Int(d[14]) << 8
                    if n < 2 || 15 + 8 * n > d.count {
                        break
                    }
                    let closed = d[12] != 0
                    let pg = CGMutablePath()
                    pg.move(to: CGPoint(x: f(15), y: f(19)))
                    for k in 1..<n {
                        pg.addLine(to: CGPoint(x: f(15 + 8 * k), y: f(19 + 8 * k)))
                    }
                    if closed {
                        pg.closeSubpath()
                    }
                    let fill = closed ? Self.sDCol(c(0)) : nil
                    items.append(.shape(path: pg, fill: fill, stroke: f(8) > 0 ? Self.sDCol(c(4)) : nil, width: f(8)))
                    hit = fill != nil ? pg
                        : pg.copy(strokingWithWidth: max(f(8), vw / 100), lineCap: .round, lineJoin: .round, miterLimit: 10)
                }
            case Sn.dText:
                if d.count >= 20 {
                    let len = Int(d[18]) | Int(d[19]) << 8
                    guard 20 + len <= d.count, f(8) > 0, let tc = Self.sDCol(c(12)) else { break }
                    let tf = NSFont.systemFont(ofSize: f(8), weight: d[17] != 0 ? .semibold : .regular)
                    let t = Self.text(String(decoding: d[20..<(20 + len)], as: UTF8.self), tf, tc)
                    let sz = t.size()
                    let x = f(0) - (d[16] == 1 ? sz.width / 2 : d[16] == 2 ? sz.width : 0)
                    items.append(.text(t, CGPoint(x: x, y: f(4))))
                    hit = CGPath(rect: CGRect(x: x, y: f(4), width: sz.width, height: sz.height), transform: nil)
                }
            case Sn.dImage:
                if d.count >= 19, let a = sceneAssets[Int(d[0]) | Int(d[1]) << 8] {
                    let rect = CGRect(x: f(2), y: f(6), width: max(f(10), 0), height: max(f(14), 0))
                    items.append(.image(a.image, rect, d[18] != 0))
                    hit = CGPath(rect: rect, transform: nil)
                }
            case Sn.dClear:
                if let cc = Self.sDCol(c(0)) {
                    items.append(.clear(cc))
                }
            default:
                break   // a newer op: skipped
            }
            if let h = hit, tag != 0 {
                tags.append((tag, h))
            }
        }
        b.drawCache = items
        b.drawTags = tags
        b.drawAssets = sceneAssets.count
        return items
    }

    /// The canvas's coordinates into its box by P_FIT: (offset, scale x, scale y).
    private func sCanvasMap(_ b: SBlock) -> (x: CGFloat, y: CGFloat, sx: CGFloat, sy: CGFloat) {
        let r = b.inner
        let vw = Self.sCanvasW(b), vh = Self.sCanvasH(b)
        var sx = r.width / vw, sy = r.height / vh
        switch b.num(Sn.pFit) {
        case Sn.fitStretch: break
        case Sn.fitCover:
            sx = max(sx, sy)
            sy = sx
        case Sn.fitNone:
            sx = u
            sy = u
        default:
            sx = min(sx, sy)
            sy = sx
        }
        return (r.minX + (r.width - vw * sx) / 2, r.minY + (r.height - vh * sy) / 2, sx, sy)
    }

    private func sDrawCanvas(_ b: SBlock) {
        let r = b.inner
        guard r.width >= 1, r.height >= 1, b.drawOps != nil, let cg = NSGraphicsContext.current?.cgContext else { return }
        let items = sCanvasBuild(b)
        let m = sCanvasMap(b)
        let vw = Self.sCanvasW(b), vh = Self.sCanvasH(b)
        b.picRect = Self.sR(m.x, m.y, vw * m.sx, vh * m.sy)
        NSGraphicsContext.saveGraphicsState()
        r.clip()
        cg.translateBy(x: m.x, y: m.y)
        cg.scaleBy(x: m.sx, y: m.sy)
        if b.has(Sn.pSmooth) && !b.flag(Sn.pSmooth) {
            cg.setShouldAntialias(false)   // P_SMOOTH 0: crisp, for pixel art
            NSGraphicsContext.current?.imageInterpolation = .none
        }
        for item in items {
            switch item {
            case let .shape(path, fill, stroke, width):
                if let fc = fill {
                    cg.addPath(path)
                    cg.setFillColor(Self.color(fc).cgColor)
                    cg.fillPath()
                }
                if let sc = stroke, width > 0 {
                    cg.addPath(path)
                    cg.setStrokeColor(Self.color(sc).cgColor)
                    cg.setLineWidth(width)
                    cg.setLineCap(.round)
                    cg.setLineJoin(.round)
                    cg.strokePath()
                }
            case let .text(t, at):
                t.draw(at: at)
            case let .image(img, rect, smooth):
                NSGraphicsContext.current?.imageInterpolation = smooth ? .high : .none
                img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            case let .clear(cc):
                cg.setFillColor(Self.color(cc).cgColor)
                cg.fill(CGRect(x: 0, y: 0, width: vw, height: vh))
            }
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// A point in the canvas's coordinates.
    private func sCanvasPoint(_ b: SBlock, _ p: CGPoint) -> CGPoint {
        let m = sCanvasMap(b)
        return CGPoint(x: (p.x - m.x) / max(m.sx, 1e-9), y: (p.y - m.y) / max(m.sy, 1e-9))
    }

    /// The topmost tagged shape at p (0: none).
    private func sCanvasTagAt(_ b: SBlock, _ p: CGPoint) -> Int {
        guard b.kind == Sn.bkCanvas, b.drawOps != nil else { return 0 }
        sCanvasBuild(b)
        let cp = sCanvasPoint(b, p)
        guard let tags = b.drawTags else { return 0 }
        for t in tags.reversed() where t.path.contains(cp) {
            return t.tag
        }
        return 0
    }

    // ================================================================
    // Where a click, move or wheel landed
    // ================================================================

    /// ";x=;y=;w=;h=" in units from b's top-left, then what's under p on cells (col, row), a picture or viewer (px, py),
    /// a canvas (cx, cy, tag) or a chart (i).
    private func sClickWhere(_ b: SBlock, _ p: CGPoint) -> String {
        let su = self.su
        var out = ";x=\(Self.sF1((p.x - b.box.minX) / su));y=\(Self.sF1((p.y - b.box.minY) / su))"
            + ";w=\(Self.sF1(b.box.width / su));h=\(Self.sF1(b.box.height / su))"
        let pr = b.picRect
        var pix: (w: Int, h: Int) = (0, 0)
        if b.kind == Sn.bkImage {
            if b.image != nil {
                pix = (b.imageW, b.imageH)
            } else if let a = sAsset(b) {
                pix = (a.w, a.h)
            }
        } else if b.kind == Sn.bkViewer, let a = sAsset(b) {
            pix = (a.w, a.h)
        }
        if b.kind == Sn.bkCells && !pr.isEmpty && pr.contains(p) {
            let d = Self.sCellDims(b)
            let col = min(Int((p.x - pr.minX) / pr.width * CGFloat(d.cols)), d.cols - 1)
            let row = min(Int((p.y - pr.minY) / pr.height * CGFloat(d.rows)), d.rows - 1)
            out += ";col=\(col);row=\(row)"
        } else if (b.kind == Sn.bkViewer || b.kind == Sn.bkImage) && !pr.isEmpty && pr.contains(p) && pix.w > 0 && pix.h > 0 {
            let px = min(Int((p.x - pr.minX) / pr.width * CGFloat(pix.w)), pix.w - 1)
            let py = min(Int((p.y - pr.minY) / pr.height * CGFloat(pix.h)), pix.h - 1)
            out += ";px=\(px);py=\(py)"
        } else if b.kind == Sn.bkCanvas {
            let cp = sCanvasPoint(b, p)
            out += ";cx=\(Self.sF1(cp.x));cy=\(Self.sF1(cp.y))"
            let tag = sCanvasTagAt(b, p)
            if tag > 0 {
                out += ";tag=\(tag)"
            }
        } else if b.kind == Sn.bkChart {
            let i = sChartIndexAt(b, p)
            if i >= 0 {
                out += ";i=\(i)"
            }
        }
        return out
    }

    // ================================================================
    // Move and wheel events, the middle button, back and forward
    // ================================================================

    /// P_EVENTS move: Move as the pointer goes over a block (at most 10 a second; on cells and canvases only when the
    /// cell or tag changes), and Move;out=1 when it leaves.
    private func sMoveEvents(_ s: SceneTree, _ p: CGPoint) {
        let hit = s.order.last { b in
            b.pass == s.pass && b.id != 0 && !b.off && b.num(Sn.pEvents) & Sn.evMove != 0 && b.box.contains(p) && b.clip.contains(p)
        }
        if let on = moveOn, on.s !== s || on.b !== hit {
            if on.s === s {
                reply("Move;id=\(on.b.id);out=1")
            }
            moveOn = nil
            moveKey = ""
        }
        guard let h = hit else { return }
        moveOn = (s, h)
        let at = sClickWhere(h, p)
        var key = at
        if h.kind == Sn.bkCells {
            key = Self.sPart(at, "col") + "," + Self.sPart(at, "row")
        } else if h.kind == Sn.bkCanvas {
            key = Self.sPart(at, "tag").isEmpty ? Self.sPart(at, "tag") + "," + Self.sPart(at, "cx") + "," + Self.sPart(at, "cy")
                : Self.sPart(at, "tag")
        }
        let now = Date()
        if key == moveKey || now.timeIntervalSince(moveAt) < 0.1 {
            return
        }
        moveKey = key
        moveAt = now
        reply("Move;id=\(h.id)" + at)
    }

    private static func sPart(_ fields: String, _ k: String) -> String {
        guard let r = fields.range(of: ";" + k + "=") else { return "" }
        let rest = fields[r.upperBound...]
        if let end = rest.firstIndex(of: ";") {
            return String(rest[..<end])
        }
        return String(rest)
    }

    /// An NSEvent's wheel: the delta along the way it scrolls most (positive: up or left, as Windows' delta), whether
    /// it's a trackpad's points, and whether sideways (deltaX, or Shift held).
    static func sWheelDelta(_ event: NSEvent) -> (delta: CGFloat, precise: Bool, horiz: Bool) {
        let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        let side = abs(dx) > abs(dy)
        return (side ? dx : dy, event.hasPreciseScrollingDeltas, side || event.modifierFlags.contains(.shift))
    }

    /// The wheel in tree s at p: a block that takes it (P_EVENTS wheel), a slider, the scroll, list or viewer under the
    /// pointer (sideways: a horizontal one first), the focused pane, else the whole scene. A mouse wheel: 4.5 units a
    /// notch; a trackpad scrolls by as much as it says (a "notch" for Wheel;d= is 4.5 units of it).
    private func sWheelIn(_ s: SceneTree, _ p: CGPoint, _ delta: CGFloat, _ precise: Bool, _ shift: Bool) {
        let unit = 4.5 * su
        let notches: CGFloat = precise ? delta / max(unit, 1) : (delta > 0 ? 1 : delta < 0 ? -1 : 0)
        for b in s.order.reversed() {
            if b.pass != s.pass || b.off || !b.box.contains(p) || !b.clip.contains(p) {
                continue
            }
            if b.num(Sn.pEvents) & Sn.evWheel != 0 && b.id != 0 {
                reply("Wheel;id=\(b.id);d=\(Self.sTrim(-notches, 2))" + sClickWhere(b, p))
                return
            }
            if b.kind == Sn.bkSlider {
                sSliderSet(b, Self.sSliderValue(b) + (notches > 0 ? 1 : notches < 0 ? -1 : 0) * Self.sSliderStep(b), true)
                return
            }
        }
        let step = unit * -notches
        var target: SBlock?, across: SBlock?
        for b in s.order.reversed() {
            if !(b.kind == Sn.bkScroll || b.kind == Sn.bkVList || b.kind == Sn.bkViewer || b.kind == Sn.bkList)
                || b.pass != s.pass || b.scrollMax <= 0 || !b.box.contains(p) || !b.clip.contains(p) {
                continue
            }
            let horiz = b.kind == Sn.bkScroll && b.num(Sn.pAxis) == 1
            if horiz == shift {
                target = b
                break
            }
            if across == nil {
                across = b
            }
        }
        if target == nil {
            target = across
        }
        if target == nil, let f = Self.sceneFocused(s), f.kind == Sn.bkScroll || f.kind == Sn.bkVList, f.scrollMax > 0 {
            target = f
        }
        if let t = target {
            sScrollBlock(t, t.scroll + step)
            t.autoHold = Date().addingTimeInterval(4)   // a crawling one holds a while
            t.autoEnded = false
        } else if s.scrollMax > 0 {
            s.scroll = min(max(s.scroll + step, 0), s.scrollMax)
            sceneArr += 1
        }
    }

    /// b scrolled to v by the caller (wheel, bar), each kind its own way.
    private func sScrollBlock(_ b: SBlock, _ v: CGFloat) {
        if b.kind == Sn.bkList || b.kind == Sn.bkViewer {
            b.scroll = min(max(v, 0), b.scrollMax)
            b.showSel = false
        } else {
            sSetScroll(b, v)
        }
        redraw()
    }

    /// The middle button at p: Click;btn=m for a block that asks for it (P_EVENTS middle).
    func sceneMiddle(_ s: SceneTree, _ p: CGPoint) {
        for b in s.order.reversed() {
            if b.pass != s.pass || b.off || b.id == 0 || !b.box.contains(p) || !b.clip.contains(p) || sHoverHidden(b) {
                continue
            }
            if b.num(Sn.pEvents) & Sn.evMiddle != 0 {
                reply("Click;id=\(b.id);n=1;btn=m" + sClickWhere(b, p))
                return
            }
        }
    }

    /// The mouse's forward button on a scene: a key only screens that know it use (Key;nav=fwd).
    func sceneNavForward() {
        guard isScene, let s = scene, complete else { return }
        sceneSendKeyX(s, "nav=fwd")
    }

    // ================================================================
    // Dragging: scroll bars, dividers, sliders
    // ================================================================

    /// The left button went down at p in tree s: a scroll bar (its thumb dragged, its track paged), a divider or a
    /// slider; true when it was one (no click follows). AppKit keeps sending mouseDragged to this view while the
    /// button is held (Windows captures the mouse).
    func sceneDown6(_ s: SceneTree, _ p: CGPoint, _ g: SGadgetM?) -> Bool {
        for bar in s.bars.reversed() where bar.track.contains(p) {
            if bar.thumb.contains(p) {
                drag6 = SDrag6(kind: .bar, s: s, b: bar.b, grab: bar.horiz ? p.x - bar.thumb.minX : p.y - bar.thumb.minY, g: g)
            } else {
                let view = bar.b.map { $0.view > 0 ? $0.view : s.space.height } ?? s.space.height
                let cur = bar.b?.scroll ?? s.scroll
                let fwd = bar.horiz ? p.x > bar.thumb.maxX : p.y > bar.thumb.maxY
                sBarSet(s, bar.b, cur + (fwd ? 1 : -1) * view * 0.9)
            }
            redraw()
            return true
        }
        for b in s.order.reversed() {
            if b.pass != s.pass || b.off || !b.clip.contains(p) {
                continue
            }
            if b.kind == Sn.bkSplit && !b.splitBar.isEmpty && Self.sInset(b.splitBar, -3 * u).contains(p) {
                let now = Date()
                if splitClicked === b && now.timeIntervalSince(splitClickedAt) < 0.4 {   // a double-click: the board's place
                    b.splitAt = -1
                    sceneArr += 1
                    if b.id != 0 {
                        reply("Split;id=\(b.id);at=\(String(format: "%.3f", Double(sSplitShare(b))))")
                    }
                    splitClicked = nil
                    redraw()
                    return true
                }
                splitClicked = b
                splitClickedAt = now
                drag6 = SDrag6(kind: .split, s: s, b: b, grab: 0, g: g)
                return true
            }
            if b.kind == Sn.bkSlider && b.box.contains(p) {
                if b.id != 0 {
                    s.focus = b.id
                }
                let parts = sSliderParts(b)
                if b.flag(Sn.pSpin) {
                    if parts.minus.contains(p) {
                        sSliderSet(b, Self.sSliderValue(b) - Self.sSliderStep(b), true)
                    } else if parts.plus.contains(p) {
                        sSliderSet(b, Self.sSliderValue(b) + Self.sSliderStep(b), true)
                    }
                    return true
                }
                drag6 = SDrag6(kind: .slider, s: s, b: b, grab: 0, g: g)
                sSliderFromX(b, parts.track, p.x, false)
                return true
            }
        }
        return false
    }

    private func sSliderFromX(_ b: SBlock, _ track: CGRect, _ x: CGFloat, _ final: Bool) {
        let f = track.width > 0 ? min(max((x - track.minX) / track.width, 0), 1) : 0
        sSliderSet(b, Self.sLo(b) + f * (Self.sHi(b) - Self.sLo(b)), final)
    }

    /// b's scroll (nil: the scene's own) set to v by its bar.
    private func sBarSet(_ s: SceneTree, _ b: SBlock?, _ v: CGFloat) {
        if let b = b {
            sScrollBlock(b, v)
        } else {
            s.scroll = min(max(v, 0), s.scrollMax)
            sceneArr += 1
        }
    }

    /// The pointer moved while something is dragged: true while it is.
    func sceneDrag6(_ p: CGPoint) -> Bool {
        guard let d = drag6 else { return false }
        if NSEvent.pressedMouseButtons & 1 == 0 {
            _ = sceneUp6()
            return true
        }
        let go: () -> Void = { [self] in
            switch d.kind {
            case .bar:
                guard let bar = d.s.bars.first(where: { $0.b === d.b }), !bar.track.isEmpty, bar.room > 0 else { break }
                let at = bar.horiz ? p.x - d.grab - bar.track.minX : p.y - d.grab - bar.track.minY
                sBarSet(d.s, d.b, min(max(at / bar.room, 0), 1) * bar.scrollMax)
            case .split:
                guard let b = d.b else { break }
                let inner = b.inner
                let across = b.num(Sn.pAxis) == 0
                let total = (across ? inner.width : inner.height) - 0.6 * su
                if total <= 0 {
                    break
                }
                let a = (across ? p.x - inner.minX : p.y - inner.minY) - 0.3 * su
                b.splitAt = min(max(a / total, 0.05), 0.95)
                sceneArr += 1
            case .slider:
                if let b = d.b {
                    sSliderFromX(b, sSliderParts(b).track, p.x, false)
                }
            }
        }
        if let g = d.g {
            wireMouse = p
            inGadget(g, go)
        } else {
            pointer = p
            go()
        }
        redraw()
        return true
    }

    /// The left button came up: a drag ends (a divider says where it went, a slider sends its value); true when one
    /// did (no click follows).
    func sceneUp6() -> Bool {
        guard let d = drag6 else { return false }
        drag6 = nil
        let done: () -> Void = { [self] in
            if d.kind == .split, let b = d.b, b.id != 0, b.splitAt >= 0 {
                reply("Split;id=\(b.id);at=\(String(format: "%.3f", Double(sSplitShare(b))))")
            }
            if d.kind == .slider, let sl = d.b {
                sSliderSet(sl, Self.sSliderValue(sl), true)
            }
        }
        if let g = d.g {
            inGadget(g, done)
        } else {
            done()
        }
        redraw()
        return true
    }

    /// The pointer's shape over what v6 adds: the sizing arrows over a divider, a hand over a slider, a tagged canvas
    /// shape or a chart that takes clicks, the arrow over a scroll bar. Nil: none of those.
    private func sCursorAt6(_ s: SceneTree, _ p: CGPoint) -> NSCursor? {
        if let d = drag6 {
            if d.kind == .split, let b = d.b {
                return b.num(Sn.pAxis) == 0 ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown
            }
            return NSCursor.arrow
        }
        if s.bars.contains(where: { $0.track.contains(p) }) {
            return .arrow
        }
        for b in s.order.reversed() {
            if b.pass != s.pass || b.off || !b.clip.contains(p) {
                continue
            }
            if b.kind == Sn.bkSplit && !b.splitBar.isEmpty && Self.sInset(b.splitBar, -3 * u).contains(p) {
                return b.num(Sn.pAxis) == 0 ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown
            }
            if !b.box.contains(p) {
                continue
            }
            if b.kind == Sn.bkSlider {
                return .pointingHand
            }
            let ev = b.num(Sn.pEvents)
            if b.kind == Sn.bkCanvas && ev & (Sn.evClick | Sn.evDouble) != 0 && sCanvasTagAt(b, p) > 0 {
                return .pointingHand
            }
            if b.kind == Sn.bkChart && ev & Sn.evClick != 0 && sChartIndexAt(b, p) >= 0 {
                return .pointingHand
            }
        }
        return nil
    }

    // ================================================================
    // Gadget scenes run as the screen's (RainwireMenu.swift's widgets call these)
    // ================================================================

    /// Runs f as if gadget g's scene were the screen's (the scene code works on `scene`): its replies say g=, at the
    /// gadget's text scale, the pointer the menu's (wireMouse); the menu's own state is put back after.
    @discardableResult
    func inGadget<T>(_ g: SGadgetM, _ f: () -> T) -> T {
        let wasScene = scene, wasIsScene = isScene, wasWaiting = waiting, wasPressed = scenePressed, wasTag = gTag,
            wasScale = sScale, wasComplete = complete, wasPointer = pointer
        scene = g.tree
        isScene = true
        waiting = false
        gTag = g.name
        sScale = Self.gadgetScale
        complete = true
        pointer = wireMouse
        defer {
            scene = wasScene
            isScene = wasIsScene
            waiting = wasWaiting
            scenePressed = wasPressed
            gTag = wasTag
            sScale = wasScale
            complete = wasComplete
            pointer = wasPointer
        }
        return f()
    }

    /// The pointer over gadget g at p: its Move events, and its cursor (nil: the arrow).
    func gadgetCursor(_ g: SGadgetM, _ p: CGPoint) -> NSCursor? {
        guard let t = g.tree else { return nil }
        return inGadget(g) { () -> NSCursor? in
            sMoveEvents(t, p)
            if let c = sCursorAt6(t, p) {
                return c
            }
            if let hit = sceneHit(t, p), !hit.off {
                return hit.kind == Sn.bkField || hit.kind == Sn.bkInput ? NSCursor.iBeam : NSCursor.pointingHand
            }
            return g.flags & 0x04 != 0 || sceneHandAt(t, p) ? NSCursor.pointingHand : nil
        }
    }

    /// A click in gadget g at p: anything clickable goes through sceneClick (every block kind works in gadgets); one
    /// that focuses a field, input, slider, list or pane gives the gadget the keys. False: nothing clickable there.
    func gadgetSceneClick(_ g: SGadgetM, _ p: CGPoint) -> Bool {
        guard let t = g.tree else { return false }
        let control = (sceneHit(t, p).map { !$0.off } ?? false)
            || inGadget(g) { sceneHandAt(t, p) || Self.sPaneAt(t, p) != nil }
        guard control else { return false }
        inGadget(g) { sceneClick(p) }
        if let f = Self.sceneFocused(t), [Sn.bkField, Sn.bkInput, Sn.bkSlider, Sn.bkVList, Sn.bkList, Sn.bkScroll].contains(f.kind) {
            gFocus = g
        }
        return true
    }

    /// The left button down in gadget g: its bars, dividers and sliders.
    func gadgetSceneDown(_ g: SGadgetM, _ p: CGPoint) -> Bool {
        guard let t = g.tree else { return false }
        return inGadget(g) { sceneDown6(t, p, g) }
    }

    /// The wheel over gadget g.
    func gadgetWheelIn(_ g: SGadgetM, _ p: CGPoint, _ event: NSEvent) {
        guard let t = g.tree else { return }
        let w = Self.sWheelDelta(event)
        guard w.delta != 0 else { return }
        inGadget(g) { sWheelIn(t, p, w.delta, w.precise, w.horiz) }
    }

    /// Whether gadget g's tree has a pop-up open (Esc closes it before giving the keys back).
    func gadgetHasPops(_ g: SGadgetM) -> Bool { !(g.tree?.pops.isEmpty ?? true) }
}
