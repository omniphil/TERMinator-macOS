import AppKit
import SwiftUI
import os.log

private let menuLogger = Logger(subsystem: "com.terminator.macos", category: "RainwireMenu")

/// A Rainwire board's menus drawn by TERMinator itself (1.1.6; Rainwire docs/MENU_GFX.md, "Native menus (TERMinator
/// 1.1.6)"). The board sends the menu as Rainwire:UI messages (Bridge/apc/ui_bridge.c queues them, TerminalViewModel's
/// poll hands them to `handle`): Hello once a call, Tick, Menu + Items, then Show; Hide gives the terminal back; Dialog
/// puts a box over the menu (Quote of the day); a Menu head flagged MU_MF_NEWS, then News + NewsItems, is the Updates &
/// News screen in the box's place (Rainwire docs/MENU_GFX.md, "Updates & News"); MU_MF_PAGE / MU_MF_LIST, then Page +
/// PageLines or List + ListItems, a page of text or a list ("Pages and lists (0.9.141)"); both bits (MU_MF_FORM), then
/// Form + FormFields, a form edited here and sent back whole as FormDone ("Forms (0.9.142)"); MuSMenu.screen
/// MU_SCR_PICTURE, then Picture (+ Chart), tabs and a chart drawn here from its numbers ("Charts (0.9.143)"); 1.1.6:
/// MuSMenu.screen MU_SCR_SCENE, then Scene + SceneBlocks (+ SceneCells, SceneImage, later ScenePatch), any screen as a
/// tree of blocks laid out and drawn here (RainwireScene.swift; Rainwire docs/SCENES.md). The packets are Rainwire's Menu module protocol (Rainwire
/// modules/menu/src/protocol.h), unchanged, and this draws the same screen the module (menumod.c) draws, in AppKit:
///   the header picture (the board's GIF, still playing, or a PNG) over the text screen's header rows
///   the menu box: the title on its top border, "Esc Back" on its bottom one, the items in the menu's layout, each
///     label in its own colors (spans the board worked out), pulsing, shimmering, blinking where it says
///   the text screen's rain behind it, when the board's look has it
///   the help line, and a status bar (the menu, the node, the clock, minutes left, "Rainwire" in the logo's fade)
/// It never decides anything: it says which item was picked (Pick;i= its index, or key= a typed key), Back, Key (a
/// dialog's key), and Ping (active=1 when the caller did something) every 10 s; the board does the rest.
///
/// Port of the Windows client's `Controls/RainwireMenu.cs` (the master): keep the two in step. macOS differences: one
/// shared view (one call per process), hosted by `RainwireMenuLayer` over the terminal area (which already stops above
/// the app's status bar); the keyboard comes from `TerminalKeyMonitor` (`handleKey`), not focus; the system font
/// stands in for Segoe UI, and text is centered on its capitals (`capY`) as Windows' `MidY` does.
///
/// The scenes live in RainwireScene.swift, an extension of this class (Windows: a partial class). Swift's `private` is
/// for this file only, so what the extension uses (the head, the style, `u`, `complete`, `waiting`, the drawing
/// helpers, `reply`...) is declared without it; everything else stays private.
final class RainwireMenuView: NSView {
    static let shared = RainwireMenuView()

    // ---- protocol.h ----
    private static let protoVersion = 3
    static let none: UInt32 = 0xFF00_0000
    private static let layoutColumns = 1, layoutGrid = 2
    private static let posLeft = 1, posRight = 2
    private static let mfGradient = 0x01, mfBrackets = 0x02, mfRoot = 0x04, mfShadow = 0x08, mfRain = 0x10
    private static let mfNews = 0x20, nsLabelFirst = 0x01, maxNews = 60, newsLinksFlag = 0x0001
    private static let mfPage = 0x40, mfList = 0x80, maxPage = 2000, maxList = 500
    static let maxFields = 32, maxValue = 1000, ffSecret = 0x01, ffChoice = 0x02
    private static let cForm: UInt8 = 7, formSubmit: UInt8 = 1, formCancel: UInt8 = 2
    private static let scrPicture = 1, scrScene = 2
    private static let ckBars = 0, ckStacked = 1, ckHbars = 2, ckLine = 3, ckHeat = 4, ckShare = 5, ckGauge = 6, ckSpark = 7
    static let vkEnter = 9, vkPgUp = 10, vkPgDn = 11, vkHome = 12, vkEnd = 13
    private static let lfSubBelow = 0x01, lfBig = 0x02, liHeading = 0x01, liBold = 0x02, liDim = 0x04
    // MuCKey.vk: a list's keys it doesn't use itself
    static let vkChar = 0, vkLeft = 1, vkRight = 2, vkDelete = 3, vkBackspace = 4, vkTab = 5, vkUp = 6,
                       vkDown = 7, vkF1 = 8
    private static let ifSeparator: UInt8 = 0x01, ifColumn: UInt8 = 0x02
    static let fxShimmer: UInt8 = 1, fxPulse: UInt8 = 2, fxBlink: UInt8 = 3
    private static let maxItems = 120, maxLines = 40

    enum Mc: Int, CaseIterable {
        case bg, text, dim, bright, accent, accent2, statusBg, statusText, statusHint, barTitle, barClock, panelTitle,
             panelShadow, selFg, selBg, selBg2, selKey, selMarker, menuBg, menuBorder, menuKey, menuBracket, menuLabel,
             menuTag, menuHelp, rainHead, rainBody, rainTail
    }

    /// The news screen's colors (MU_S_NEWS), in protocol.h's MU_NC_* order.
    private enum Nc: Int, CaseIterable {
        case panelBg, border, title, latestDate, latestHead, latestText, rule, date, head, text, foot, statValue,
             statLabel
    }

    /// The menu protocol version this draws: the ui= key in the Rainwire:Caps answer (OscExtras.appInfo).
    static let version = protoVersion

    /// The board screens this app draws itself: the uiscreens= key ('+' between them as more come).
    static let screens = "menu+dialog+news+page+list+form+picture+art+wire+weather+gadgets"

    struct Span {
        let fg: UInt32, bg: UInt32
        let fx: UInt8
        let text: String
    }

    /// A box over the menu that waits for a key (MU_S_DIALOG): Quote of the day and the like.
    private struct Dialog {
        let title: String, foot: String
        let bg: UInt32, border: UInt32, fg: UInt32, footFg: UInt32
        let lines: [[Span]]
    }

    /// A page's colors (MU_S_PAGE) and a list's (MU_S_LIST), in protocol.h's MU_PC_* / MU_LC_* order.
    private enum Pc: Int, CaseIterable { case panelBg, border, title, header, text, rule, foot }
    private enum Lc: Int, CaseIterable { case panelBg, border, title, text, dim, bright, accent, accent2, mark, foot }

    /// A picture screen's colors (MU_S_PICTURE), in protocol.h's MU_XC_* order.
    private enum Xc: Int, CaseIterable { case panelBg, border, title, text, dim, accent, accent2, grid, tabBg, tabFg }

    /// A chart's series (MU_S_CHART): its color, name and a value per label.
    private struct ChartSeries {
        let color: UInt32
        let name: String
        let v: [CGFloat]
    }

    /// A chart's data (MU_S_CHART), drawn here at this size.
    private struct Chart {
        var kind = 0, every = 1
        var max: CGFloat = 0, value: CGFloat = 0
        var unit = ""
        var labels: [String] = []
        var series: [ChartSeries] = []
        var rowL: [String] = [], colL: [String] = []
        var heat: [CGFloat] = []
    }

    /// A form's colors (MU_S_FORM), in protocol.h's MU_FC_* order.
    private enum Fc: Int, CaseIterable {
        case formBg, border, title, label, labelOn, fieldBg, fieldBgOn, fieldText, marker, hint, error
    }

    /// A form's field (MU_S_FORM_FIELDS), edited here: its value as characters and the caret among them.
    private struct FormField {
        var flags = 0, max = 0
        var label = "", help = "", submitIf = ""
        var value: [Character] = []
        var cur = 0
        var choices: [String] = []
        var isChoice: Bool { flags & RainwireMenuView.ffChoice != 0 }
        var isSecret: Bool { flags & RainwireMenuView.ffSecret != 0 }
    }

    /// A list's row (MU_S_LIST_ITEMS): its columns' spans, a mark left of the first, a sub line; y/h where it lies.
    private struct ListRow {
        var flags = 0, indent = 0
        var mark = "", sub = ""
        var cols: [[Span]] = []
        var y: CGFloat = 0, h: CGFloat = 0
    }

    /// One item of the news screen (MU_S_NEWS_ITEMS): a span's text may hold "\n", a line break.
    private struct NewsItem {
        let date: String
        let title: [Span], text: [Span]
    }

    /// One part of a row of the news screen's stats bar: "11 this week", or label first, "Last caller: Fred".
    private struct NewsStat {
        let labelFirst: Bool
        let value: String, label: String
    }

    private final class Item {
        var key = 0
        var keyFg: UInt32 = 0, keyBg: UInt32 = 0
        var flags: UInt8 = 0
        var spans: [Span] = []
        var tag = "", help = ""
        var box = CGRect.zero        // where the layout put it (points); width 0: not drawn
        var selectable: Bool { flags & (RainwireMenuView.ifSeparator | RainwireMenuView.ifColumn) == 0 }
    }

    /// The sysop's settings for how the next screen is drawn (MU_S_STYLE, the theme's gfx block; Rainwire
    /// docs/MENU_GFX.md "Drawing the style"): each at today's look until a Style sets it.
    struct Style {
        var valign = 0                  // 0 auto, 1 top, 2 middle, 3 bottom
        var x: CGFloat = 0, y: CGFloat = 0, width: CGFloat = 0   // % of the window
        var radius: CGFloat = 6, border: CGFloat = 1.5, padding: CGFloat = 16, opacity: CGFloat = 100
        var shadow = 0                  // 0 soft, 1 hard, 2 none (MU_MF_SHADOW still says whether)
        var title = 0                   // 0 border, 1 inside, 2 none
        var font = 0                    // 0 sans, 1 mono
        var size: CGFloat = 17, height: CGFloat = 26, gap: CGFloat = 0
        var key = 0                     // 0 auto, 1 bracket, 2 spaced, 3 chip, 4 none
        var sel = 0                     // 0 bar, 1 outline, 2 glow, 3 underline
        var marker = true
        var selRadius: CGFloat = 4
        var fit = 0                     // 0 stretch, 1 fit, 2 none
        var help = true, status = true, hover = true
        var dim: CGFloat = 10, fade: CGFloat = 160
    }

    struct Head {
        var selected = 0, count = 0, layout = 0, columns = 0, position = 0, flags = 0, width = 0
        var tileCols = 0, tileRows = 0, hdrRows = 0, screenRows = 0
        var screen = 0                  // MU_SCR_*: a screen the flags don't name (1: a picture screen)
        var title = ""
        var colors = [UInt32](repeating: 0, count: Mc.allCases.count)
    }

    /// Up over the terminal, with the keyboard.
    private(set) var isUp = false

    /// Where the terminal's picture is, in this view's coordinates (top-left origin; nil: all of it). The header
    /// lands on the text screen's header rows and the rain on its cells. Set by `RainwireMenuLayer`.
    var pictureRect: CGRect? {
        didSet {
            if pictureRect != oldValue {
                needsLayout = true
                needsDisplay = true
            }
        }
    }

    private let header = PixelImageView()
    private let overlay = DialogOverlay()   // the dialog, above the header picture
    // How much darker than the theme's colors everything the menu draws is (sysop 2026-10-20: the graphical menus,
    // header art included, read brighter than the text ones): one translucent black layer on top, st.dim % (10).
    private let dimView = DimView()
    private var headerPixelArt = false
    private var defaultsObserver: NSObjectProtocol?
    private var animTimer: Timer?, pingTimer: Timer?, rainTimer: Timer?

    var head = Head()
    var st = Style()
    private var items: [Item] = []
    private var want = 0                // items the current menu's head said are coming
    var complete = false        // every item has come
    private var sel = 0
    var waiting = false         // picked: the board is answering
    private var active = false          // the caller did something since the last message
    private var barEnd = "", clock = ""
    private var node = 0, minutes = 0xFFFF
    private var headerPath: String?
    private var headerW = 0, headerH = 0
    private var shownAt = Date()
    private var dialog: Dialog?         // up over the menu until the board's next Dialog, Menu, Show or Hide
    private var dialogKeyed = false     // its key has gone to the board
    private var toast = ""              // MU_S_TOAST: in the status bar's place until toastUntil (someone logged on...)
    private var backdrop: NSImage?      // MU_S_BACKDROP: the screen's background art, behind the menu
    private var backdropPath: String?
    private var bdScreenCols = 0, bdScreenRows = 0, bdCols = 0, bdRows = 0
    private var toastFg: UInt32 = 0, toastBg: UInt32 = 0
    private var toastUntil = Date.distantPast
    private var wheelRemainder: CGFloat = 0
    private var hideGen = 0             // bumped by every Show and Hide: a delayed hide only if it's still the latest

    // The news screen (MU_S_NEWS, MU_S_NEWS_ITEMS)
    private var isNews = false          // this screen is the news: no menu box
    private var news: [NewsItem] = []
    private var newsWant = 0
    private var newsColors = [UInt32](repeating: 0, count: Nc.allCases.count)
    private var earlier = "", foot = ""
    private var stats: [[NewsStat]] = []
    private var scroll: CGFloat = 0, scrollTo: CGFloat = 0, scrollMax: CGFloat = 0, viewH: CGFloat = 0   // points
    private var vTop: CGFloat = 0, vBot: CGFloat = 0   // the panel's inside: lines outside it aren't drawn
    private var newsLinks = false       // MuSNews.flags MU_NEWS_LINKS: web addresses in the text are links
    private var links: [(rect: CGRect, url: String)] = []   // the links drawn last, for the pointer and clicks
    var pointer: CGPoint?       // where the pointer is over the news (a link under it lights up)

    // The news panel beside the header (Wire, WirePic; the extension at the end of this file)
    var wire: WirePanel?
    var wireKeep: WirePanel?            // the last menu's: the same stories again keep their pictures and scroll
    var wireBox = CGRect.zero, wireList = CGRect.zero
    var wireOff: CGFloat = 0, wireLoop: CGFloat = 0, wireLaidW: CGFloat = -1, wireLaidU: CGFloat = 0
    var wireTick = Date(), wireHeld = Date.distantPast
    var wireHover = -1
    var wireMouse: CGPoint?
    // The weather widget under it, and the widgets' close/expand state for the call (the extension at the end)
    var wx: WxPanel?
    var wxBox = CGRect.zero
    var gClosed = Set<String>(), gWide = Set<String>()   // by name ("news", "weather", a gadget's): closed for the
                                                         // call, expanded until the menu hides
    var widgetBtnHot: (w: String, btn: Int)?   // the button under the pointer (0 close, 1 expand, 2 collapse)
    var gadgets: [Int: SGadgetM] = [:]      // the scene gadgets, by slot (docs/GADGETS.md): they come with each menu
    var gTag: String?                       // replies made now come from this scene gadget: they say g=<name>
    var overWidget = false                  // the pointer is over a widget's box: its cursor is set
    var sScale: CGFloat = 1                 // the scene text scale (gadgets draw smaller; RainwireScene.swift sSize)
    var wxHot = false
    // version 6: the gadget engine (the widgets extension at the end of this file; Rainwire docs/SCENES_V6.md)
    var gPlace: [String: GPlace] = [:]      // where each widget is now, by name (the board's or the caller's)
    var gBoard: [String: GPlace] = [:]      // where the board last put each (Reset layout)
    var gState: [String: (badge: UInt32, color: UInt32, attn: Bool)] = [:]   // GadgetState: its count and attention
    var gStrips: [(name: String, box: CGRect)] = []   // collapsed ones this frame: their title strips
    var gPills: [(name: String, box: CGRect)] = []    // ... or, with the status bar, their pills on it
    var gMovedLater: [String] = []          // GadgetMoved made while no menu is up: sent at Show
    var gArea = CGRect.zero                 // the menu screen's area (floating gadgets' room)
    var gFocus: SGadgetM?                   // the gadget that has the keys (a field clicked in it)
    var gDrag: GDrag?                       // a gadget's title or edge being dragged
    var trayQuiet = false                   // a tray gadget is being drawn while no menu is up: it says nothing
    var trayBar: RainwireTrayView?          // the tray's pills on the status bar (RainwireTrayLayer)
    var trayPop: NSPopover?, trayPopFor: SGadgetM?
    // version 6: scenes (RainwireScene.swift's fourth extension)
    var drag6: SDrag6?                      // a scroll bar, divider or slider being dragged
    var splitClicked: SBlock?               // the divider pressed last, and when (a double-click resets it)
    var splitClickedAt = Date.distantPast
    var moveOn: (s: SceneTree, b: SBlock)?  // P_EVENTS move: the block the pointer is over, its last cell or tag, when
    var moveKey = ""
    var moveAt = Date.distantPast

    // A page (MU_S_PAGE) and a list (MU_S_LIST): screens in the box's place, like the news
    private var isPage = false, isList = false
    private var pageHdr: [Span] = [], pageLines: [[Span]] = [], linesWant = 0
    private var pageColors = [UInt32](repeating: 0, count: Pc.allCases.count)
    private var listColors = [UInt32](repeating: 0, count: Lc.allCases.count)
    private var rows: [ListRow] = [], rowsWant = 0
    private var colW: [Int] = [], colT: [String] = []
    private var lEmpty = "", lFooter = "", lKeys = "", lEdge = ""
    private var lFlags = 0, lStart = 0, lSel = 0
    private var rowHits: [(rect: CGRect, row: Int)] = []   // the rows drawn last, for the pointer and clicks
    private var listSnap = false        // a list just came: its first drawing jumps to the selection, no smooth scroll

    // A picture screen (MU_S_PICTURE, MU_S_CHART): tabs, lines above, the chart, notes
    private var isPic = false
    private var tabs: [String] = [], tab = 0
    private var heads: [[Span]] = [], notes: [[Span]] = []
    private var picColors = [UInt32](repeating: 0, count: Xc.allCases.count)
    private var hasChart = false, chartIn = false
    // MuSPicture.hasChart MU_PIC_IMAGE: an image in the chart's place (Rainwire's ANSI Studio), path= from hdr=;
    // MU_PICF_SMOOTH: a photo, drawn smoothly, else art by whole pixels
    private var picImage: NSImage?, picImagePath: String?, picSmooth = false
    private var chart = Chart()
    private var tabHits: [(rect: CGRect, tab: Int)] = []

    // A form (MU_S_FORM): its fields are edited here and sent back when it ends
    private var isForm = false
    private var fields: [FormField] = [], fieldsWant = 0, fAct = 0
    private var fHint = "", fErr = ""
    private var formColors = [UInt32](repeating: 0, count: Fc.allCases.count)
    var caretAt = Date()   // the last edit or move: the caret shows steadily for a moment after
    private var formHits: [(rect: CGRect, field: Int, choice: Int)] = []   // choice -1: the field's value

    // A scene (MU_SCR_SCENE, 1.1.6): RainwireScene.swift does the rest; its state is here, as an extension can't
    // add stored properties
    var isScene = false
    var scene: SceneTree?, scenePrev: SceneTree?   // the scene up; one that was up and complete, until the next head
    var sceneGen = 0, sceneArr = 0       // bumped when sizes must be measured again / blocks placed again
    var sceneU: CGFloat = 0, sceneSize: CGFloat = 0
    var sceneWaitAt = Date.distantPast, sceneMoveAt = Date.distantPast
    var scenePressed: UInt16 = 0         // the button whose press the board is answering
    var cellFont: WmFont?, cellFontTried = false
    var sceneImages: [String: NSImage] = [:]
    var sceneColors = [UInt32](repeating: 0, count: Sc.allCases.count)   // the tree being laid out or drawn
    // scenes version 2 (RainwireScene.swift's second extension)
    var sceneAssets: [Int: SAsset] = [:]          // SceneAsset pictures by number, for the call
    var hoverAsked: UInt16 = 0                    // P_HOVERASK: the block a Hover went for
    var hoverBlock: SBlock?                       // ... the one under the pointer, and since when
    var hoverSince = Date()
    var clickId: UInt16 = 0, clickN = 0           // P_EVENTS: the last clicked block, its clicks in a row, when
    var clickAt = Date.distantPast
    // scenes version 5 (Files: RainwireScene.swift's third extension): a P_DRAG row being dragged, a lit P_DROP block
    var sDragRow: SBlock?                         // pressed on a P_DRAG row
    var sDragFrom = CGPoint.zero
    var sDragging = false                         // moved past 6 px: DragOut sent, the label shown
    var sDragOk = false, sDragLeft = false        // the board allowed it (DragFile ok=1); the pointer left the window
    var sDragLabel = "", sDragHint = ""
    var sDragEvent: NSEvent?                      // the newest mouseDragged (an OS drag has to start from one)
    var sDropLit: UInt16 = 0
    var sceneDpi: CGFloat = 0                     // the backing scale the scene was measured at
    /// A scene row being dragged left the TERMinator window with the button down (its block id, the newest drag
    /// event): the OS drag may start (RainwireFileDrops, once the board allowed it).
    var sceneDragLeftWindow: ((UInt16, NSEvent) -> Void)?
    // A click is a press and a release both on this view. The release alone was taken as one (Windows, sysop
    // 2026-10-22: a module that closes on its press, Files' Leave, brought the menu back under the button and the
    // release opened the News door from the gadget there).
    private var pressL = false, pressR = false

    /// Replies go out in order on their own queue: conn_send may wait for room on a full link (as TRACE's door queue).
    private let sendQueue = DispatchQueue(label: "Rainwire menu send")

    private init() {
        super.init(frame: .zero)
        isHidden = true
        wantsLayer = true
        header.imageScaling = .scaleAxesIndependently
        header.animates = true
        header.isHidden = true
        addSubview(header)
        overlay.owner = self
        addSubview(overlay)
        dimView.wantsLayer = true
        dimView.layer?.backgroundColor = NSColor.black.withAlphaComponent(st.dim / 100).cgColor
        addSubview(dimView)   // over everything: the menu, the header, the dialog
        // The Font smoothing preference: pixel-art headers follow it, as the terminal picture does
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                                                  object: nil, queue: .main) { [weak self] _ in
            self?.scaleHeader()
            self?.needsDisplay = true   // the background art's scaling too
        }
    }

    /// Pixel art crisp unless the Font smoothing preference is on (the terminal picture is scaled smoothly then), so
    /// the header looks as the same art does on the text screen; any other picture smooth.
    private func scaleHeader() {
        let crisp = headerPixelArt && !UserDefaults.standard.bool(forKey: "font_smoothing")
        if header.crisp != crisp { header.crisp = crisp }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // ================================================================
    // Messages from the board
    // ================================================================

    /// One queued Rainwire:UI message, as Bridge/apc/ui_bridge.c hands it over: "Verb[;b64=...][;path=...]". Main
    /// thread.
    func handle(_ msg: String) {
        var verb = msg
        var b64: String?
        var path: String?
        if let semi = msg.firstIndex(of: ";") {
            verb = String(msg[..<semi])
            var rest = String(msg[msg.index(after: semi)...])
            // path= is last and runs to the end (a folder name may hold ';')
            if rest.hasPrefix("path=") {
                path = String(rest.dropFirst(5))
                rest = ""
            } else if let r = rest.range(of: ";path=") {
                path = String(rest[r.upperBound...])
                rest = String(rest[..<r.lowerBound])
            }
            for f in rest.split(separator: ";") where f.hasPrefix("b64=") {
                b64 = String(f.dropFirst(4))
            }
        }
        var packet: [UInt8]?
        if let b64 = b64 {
            guard let data = Data(base64Encoded: b64) else { return }
            packet = [UInt8](data)
        }
        // A short packet is ignored, as the module does: every read is checked (`Reader`)
        switch verb {
        case "Hello": if let p = packet { onHello(p) }
        case "Tick": if let p = packet { onTick(p) }
        case "Menu": if let p = packet { onMenu(p, path) }
        case "Items": if let p = packet { onItems(p) }
        case "Dialog": if let p = packet { onDialog(p) }
        case "Toast": if let p = packet { onToast(p) }
        case "Backdrop": if let p = packet { onBackdrop(p, path) }
        case "Style": if let p = packet { onStyle(p) }
        case "News": if let p = packet { onNews(p) }
        case "Page": if let p = packet { onPage(p) }
        case "PageLines": if let p = packet { onPageLines(p) }
        case "List": if let p = packet { onList(p) }
        case "ListItems": if let p = packet { onListItems(p) }
        case "Form": if let p = packet { onForm(p) }
        case "Picture": if let p = packet { onPicture(p, path) }
        case "Chart": if let p = packet { onChart(p) }
        case "FormFields": if let p = packet { onFormFields(p) }
        case "NewsItems": if let p = packet { onNewsItems(p) }
        case "Scene": if let p = packet { onScene(p) }
        case "SceneBlocks": if let p = packet { onSceneBlocks(p) }
        case "SceneCells": if let p = packet { onSceneCells(p) }
        case "SceneImage": if let p = packet { onSceneImage(p, path) }
        case "ScenePatch": if let p = packet { onScenePatch(p) }
        case "SceneAsset": if let p = packet { onSceneAsset(p, path) }   // scenes v2 (RainwireScene.swift)
        case "Clipboard", "Open", "Sound", "SceneToast":
            handleV2(verb, msg, packet.map { String(decoding: $0, as: UTF8.self) } ?? "")
        case "Wire": if let p = packet { onWire(p) }
        case "WirePic": if let p = packet { onWirePic(p, path) }
        case "Weather": if let p = packet { onWeather(p) }
        case "Gadget": if let p = packet { onGadget(p) }
        case "GadgetScene", "GadgetBlocks", "GadgetCells", "GadgetImage", "GadgetPatch", "GadgetDraw":
            if let p = packet { onGadgetPart(verb, p, path) }
        case "SceneDraw": if let p = packet { onSceneDraw(p) }         // scenes v6 (RainwireScene.swift)
        case "GadgetPlace": if let p = packet { onGadgetPlace(p) }     // the gadget engine (the widgets extension)
        case "GadgetState": if let p = packet { onGadgetState(p) }
        case "Show": show()
        case "Hide": hide()
        default: break
        }
    }

    /// The call ended: down, and everything forgotten.
    func reset() {
        if sDragRow != nil { sceneDragEnd() }   // a row's drag out: the drag state goes with the screen
        hide(now: true)
        items.removeAll()
        complete = false
        barEnd = ""
        clock = ""
        toast = ""
        backdrop = nil
        backdropPath = nil
        picImage = nil
        picImagePath = nil
        dialog = nil
        isNews = false
        isPage = false
        isList = false
        isForm = false
        isPic = false
        isScene = false
        scene = nil
        scenePrev = nil
        sceneImages.removeAll()
        sceneAssets.removeAll()   // scenes v2: the call's pictures
        hoverBlock = nil
        cellFont = nil
        cellFontTried = false
        fields.removeAll()
        pageLines.removeAll()
        rows.removeAll()
        news.removeAll()
        stats.removeAll()
        wireReset()
        wireKeep = nil
        widgetsForget()   // version 6: every widget open, narrow and where the board puts it; no gadgets, no tray
        drag6 = nil
        moveOn = nil
        setHeader(nil)
    }

    /// Reads a packet little-endian; past the end it reads zeros and `ok` goes false.
    private struct Reader {
        let b: [UInt8]
        var ok = true
        init(_ b: [UInt8]) { self.b = b }
        mutating func u8(_ o: Int) -> Int {
            guard o >= 0, o < b.count else { ok = false; return 0 }
            return Int(b[o])
        }
        mutating func u16(_ o: Int) -> Int { u8(o) | u8(o + 1) << 8 }
        mutating func u32(_ o: Int) -> UInt32 {
            UInt32(u8(o)) | UInt32(u8(o + 1)) << 8 | UInt32(u8(o + 2)) << 16 | UInt32(u8(o + 3)) << 24
        }
        mutating func str(_ o: inout Int, _ n: Int) -> String {
            let n = max(0, min(n, b.count - o))
            guard o >= 0, o <= b.count else { ok = false; return "" }
            let s = String(decoding: b[o..<(o + n)], as: UTF8.self)
            o += n
            return s
        }
    }

    private func onHello(_ p: [UInt8]) {
        var r = Reader(p)
        var o = 4
        let mins = r.u16(o + 2)
        let colours = r.u16(o + 4), len = r.u8(o + 6), nd = r.u8(o + 7)
        o += 8 + 4 * colours
        let end = r.str(&o, len)
        guard r.ok else { return }
        minutes = mins
        node = nd
        barEnd = end
    }

    private func onTick(_ p: [UInt8]) {
        var r = Reader(p)
        let mins = r.u16(4), len = r.u8(6)
        var o = 8
        let c = r.str(&o, len)
        guard r.ok else { return }
        minutes = mins
        clock = c
        if isUp {
            redraw()
        }
    }

    private func onMenu(_ p: [UInt8], _ path: String?) {
        if sDragRow != nil { sceneDragEnd() }   // a new screen mid-drag: no drag state left behind
        var r = Reader(p)
        var o = 4
        var h = Head()
        h.selected = r.u16(o)
        h.count = r.u16(o + 2)
        h.layout = r.u8(o + 6)
        h.columns = r.u8(o + 7)
        h.position = r.u8(o + 8)
        h.flags = r.u8(o + 9)
        h.width = r.u16(o + 10)
        h.tileCols = r.u8(o + 12)
        h.tileRows = r.u8(o + 13)
        h.hdrRows = r.u8(o + 15)
        h.screenRows = r.u8(o + 80)
        h.screen = r.u8(o + 81)
        let titleLen = r.u8(o + 4), colors = r.u8(o + 14)
        o += 84
        for i in 0..<colors {
            if i < Mc.allCases.count {
                h.colors[i] = r.u32(o) & 0xFF_FFFF
            }
            o += 4
        }
        h.title = r.str(&o, titleLen)
        guard r.ok else { return }
        head = h
        dialog = nil
        wireReset()   // a news panel comes with the menu that has one (Wire, before Show)
        items.removeAll()
        want = min(h.count, Self.maxItems)
        // a scene (MU_SCR_SCENE, 1.1.6; RainwireScene.swift): its Scene head and blocks come next; a pop-up scene
        // (SF_OVER) is drawn over the scene before it, so that one is kept until the head says
        let isSceneHead = h.screen == Self.scrScene
        scenePrev = isSceneHead && isScene && complete ? scene : nil
        scene = nil
        isScene = isSceneHead
        isNews = !isSceneHead && h.flags & Self.mfNews != 0
        isPic = h.screen == Self.scrPicture   // first: the screen byte names what the flags can't
        isForm = !isPic && !isSceneHead && (h.flags & (Self.mfPage | Self.mfList)) == (Self.mfPage | Self.mfList)   // both bits: a form
        isPage = !isPic && !isSceneHead && !isForm && h.flags & Self.mfPage != 0
        isList = !isPic && !isSceneHead && !isForm && h.flags & Self.mfList != 0
        complete = want == 0 && !isNews && !isPage && !isList && !isForm && !isPic && !isScene   // those wait for their own packets
        setHeader(path)
        needsLayout = true
    }

    private func onItems(_ p: [UInt8]) {
        var r = Reader(p)
        let first = r.u16(4), count = r.u16(6)
        var o = 8
        guard r.ok, first == items.count else { return }   // out of order: a stale menu's
        var added: [Item] = []
        for _ in 0..<count where items.count + added.count < want {
            let it = Item()
            it.key = Int(r.u32(o))
            it.keyFg = r.u32(o + 4)
            it.keyBg = r.u32(o + 8)
            it.flags = UInt8(r.u8(o + 12))
            let spans = r.u8(o + 13), tagLen = r.u8(o + 14), helpLen = r.u8(o + 15)
            o += 16
            it.spans = readSpans(&r, &o, spans)
            it.tag = r.str(&o, tagLen)
            it.help = r.str(&o, helpLen)
            guard r.ok else { return }
            added.append(it)
        }
        items.append(contentsOf: added)
        if items.count >= want {
            complete = true
            sel = max(0, min(head.selected, items.count - 1))
            while sel < items.count - 1 && !items[sel].selectable {
                sel += 1
            }
        }
    }

    /// MU_S_STYLE, before every Menu head (the news's too): back to today's look, then each key it has (numbers in
    /// tenths), clamped; ids from a newer Rainwire are skipped.
    private func onStyle(_ p: [UInt8]) {
        var r = Reader(p)
        let count = r.u8(5)
        var o = 8
        var s = Style()
        func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { min(max(v, lo), hi) }
        func clampi(_ v: Int, _ lo: Int, _ hi: Int) -> Int { min(max(v, lo), hi) }
        for _ in 0..<count {
            let id = r.u8(o)
            let v = Int(Int16(bitPattern: UInt16(truncatingIfNeeded: r.u16(o + 2))))
            let f = CGFloat(v) / 10
            o += 4
            guard r.ok else { return }
            switch id {
            case 1: s.valign = clampi(v, 0, 3)
            case 2: s.x = clamp(f, -50, 50)
            case 3: s.y = clamp(f, -50, 50)
            case 4: s.width = clamp(f, 0, 100)
            case 5: s.radius = clamp(f, 0, 24)
            case 6: s.border = clamp(f, 0, 4)
            case 7: s.padding = clamp(f, 4, 40)
            case 8: s.opacity = clamp(f, 30, 100)
            case 9: s.shadow = clampi(v, 0, 2)
            case 10: s.title = clampi(v, 0, 2)
            case 11: s.font = clampi(v, 0, 1)
            case 12: s.size = clamp(f, 12, 28)
            case 13: s.height = clamp(f, 18, 48)
            case 14: s.gap = clamp(f, 0, 12)
            case 15: s.key = clampi(v, 0, 4)
            case 16: s.sel = clampi(v, 0, 3)
            case 17: s.marker = v != 0
            case 18: s.selRadius = clamp(f, 0, 16)
            case 19: s.fit = clampi(v, 0, 2)
            case 20: s.help = v != 0
            case 21: s.status = v != 0
            case 22: s.dim = clamp(f, 0, 30)
            case 23: s.fade = clamp(f, 0, 600)
            case 24: s.hover = v != 0
            default: break   // a key from a newer Rainwire
            }
        }
        st = s
        dimView.layer?.backgroundColor = NSColor.black.withAlphaComponent(st.dim / 100).cgColor
        needsLayout = true   // header.fit
        redraw()
    }

    /// The news screen's head (MU_S_NEWS): colors, the "Earlier" heading, the foot, the stats rows. Forgets earlier
    /// news; its items follow in NewsItems.
    private func onNews(_ p: [UInt8]) {
        var r = Reader(p)
        var o = 4
        let count = r.u16(o), colors = r.u8(o + 2), earlierLen = r.u8(o + 3), footLen = r.u8(o + 4)
        let statRows = min(r.u8(o + 5), 4), flags = r.u16(o + 6)
        o += 8
        var nc = [UInt32](repeating: 0, count: Nc.allCases.count)
        for i in 0..<colors {
            if i < nc.count {
                nc[i] = r.u32(o) & 0xFF_FFFF
            }
            o += 4
        }
        let e = r.str(&o, earlierLen), f = r.str(&o, footLen)
        var rows: [[NewsStat]] = []
        for _ in 0..<statRows {
            let parts = r.u8(o)
            o += 1
            var row: [NewsStat] = []
            for _ in 0..<parts {
                let flags = r.u8(o), vl = r.u8(o + 1), ll = r.u8(o + 2)
                o += 4
                let v = r.str(&o, vl), l = r.str(&o, ll)
                row.append(NewsStat(labelFirst: flags & Self.nsLabelFirst != 0, value: v, label: l))
            }
            rows.append(row)
        }
        guard r.ok else { return }
        newsColors = nc
        newsLinks = flags & Self.newsLinksFlag != 0
        earlier = e
        foot = f
        stats = rows
        news.removeAll()
        newsWant = min(count, Self.maxNews)
        if isNews && newsWant == 0 {
            newsReady()
        }
    }

    /// News items (MU_S_NEWS_ITEMS), in order: a date, the title's spans, the text's.
    private func onNewsItems(_ p: [UInt8]) {
        var r = Reader(p)
        let first = r.u16(4), count = r.u16(6)
        var o = 8
        guard r.ok, first == news.count else { return }   // out of order: a stale screen's
        var added: [NewsItem] = []
        for _ in 0..<count where news.count + added.count < newsWant {
            let dl = r.u8(o), nt = r.u8(o + 1), nx = r.u16(o + 2)
            o += 4
            let date = r.str(&o, dl)
            let title = readSpans(&r, &o, nt)
            let text = readSpans(&r, &o, nx)
            guard r.ok else { return }
            added.append(NewsItem(date: date, title: title, text: text))
        }
        news.append(contentsOf: added)
        if isNews && news.count >= newsWant {
            newsReady()
        }
    }

    // ---- pages and lists: reading ----

    /// A page's head (MU_S_PAGE): its colors and the column headings' spans; its lines follow in PageLines.
    private func onPage(_ p: [UInt8]) {
        var r = Reader(p)
        var o = 4
        let lines = r.u16(o), colors = r.u8(o + 2), hdrSpans = r.u8(o + 3)
        o += 8
        var pc = [UInt32](repeating: 0, count: Pc.allCases.count)
        for i in 0..<colors {
            if i < pc.count {
                pc[i] = r.u32(o) & 0xFF_FFFF
            }
            o += 4
        }
        let hdr = readSpans(&r, &o, hdrSpans)
        guard r.ok else { return }
        pageColors = pc
        pageHdr = hdr
        pageLines.removeAll()
        linesWant = min(lines, Self.maxPage)
        if isPage && linesWant == 0 {
            newsReady()
        }
    }

    /// A page's lines, in order: per line u8 spans + spans.
    private func onPageLines(_ p: [UInt8]) {
        var r = Reader(p)
        let first = r.u16(4), count = r.u16(6)
        var o = 8
        guard r.ok, first == pageLines.count else { return }   // out of order: a stale screen's
        var added: [[Span]] = []
        for _ in 0..<count where pageLines.count + added.count < linesWant {
            let n = r.u8(o)
            o += 1
            let line = readSpans(&r, &o, n)
            guard r.ok else { return }
            added.append(line)
        }
        pageLines.append(contentsOf: added)
        if isPage && pageLines.count >= linesWant {
            newsReady()
        }
    }

    /// A list's head (MU_S_LIST): rows to come, the selected one, columns (width in text cells, title), colors,
    /// flags, the empty text, footer, keys line and edge keys.
    private func onList(_ p: [UInt8]) {
        var r = Reader(p)
        var o = 4
        let items = r.u16(o), selected = r.u16(o + 2), cols = r.u8(o + 4), colors = r.u8(o + 5), flags = r.u8(o + 6)
        let emptyLen = r.u8(o + 7), footerLen = r.u8(o + 8), keysLen = r.u8(o + 9), edgeLen = r.u8(o + 10)
        o += 12
        var lc = [UInt32](repeating: 0, count: Lc.allCases.count)
        for i in 0..<colors {
            if i < lc.count {
                lc[i] = r.u32(o) & 0xFF_FFFF
            }
            o += 4
        }
        var widths: [Int] = [], titles: [String] = []
        for c in 0..<cols {
            let wd = r.u8(o), tl = r.u8(o + 1)
            o += 2
            let t = r.str(&o, tl)
            if c < 16 {
                widths.append(wd)
                titles.append(t)
            }
        }
        let empty = r.str(&o, emptyLen), footer = r.str(&o, footerLen), keys = r.str(&o, keysLen), edge = r.str(&o, edgeLen)
        guard r.ok else { return }
        listColors = lc
        colW = widths
        colT = titles
        lEmpty = empty
        lFooter = footer
        lKeys = keys
        lEdge = edge
        lFlags = flags
        lStart = selected
        rows.removeAll()
        rowsWant = min(items, Self.maxList)
        if isList && rowsWant == 0 {
            listReady()
        }
    }

    /// A list's rows, in order: MuListItem + mark + sub + per column u8 spans + spans.
    private func onListItems(_ p: [UInt8]) {
        var r = Reader(p)
        let first = r.u16(4), count = r.u16(6)
        var o = 8
        guard r.ok, first == rows.count else { return }   // out of order: a stale screen's
        var added: [ListRow] = []
        for _ in 0..<count where rows.count + added.count < rowsWant {
            var row = ListRow()
            row.flags = r.u8(o)
            row.indent = r.u8(o + 1)
            let markLen = r.u8(o + 2), subLen = r.u8(o + 3), ncols = r.u8(o + 4)
            o += 8
            row.mark = r.str(&o, markLen)
            row.sub = r.str(&o, subLen)
            for _ in 0..<ncols {
                let n = r.u8(o)
                o += 1
                row.cols.append(readSpans(&r, &o, n))
            }
            guard r.ok else { return }
            added.append(row)
        }
        rows.append(contentsOf: added)
        if isList && rows.count >= rowsWant {
            listReady()
        }
    }

    // ---- picture screens: reading ----

    /// A picture screen (MU_S_PICTURE): colors, tabs, the current tab, lines above the chart and notes under it;
    /// with hasChart its chart follows (Chart).
    /// With MU_PIC_IMAGE the image (path) goes in the chart's place: the ANSI Studio's art, the tabs its keys.
    private func onPicture(_ p: [UInt8], _ path: String?) {
        var r = Reader(p)
        var o = 4
        let ntabs = r.u8(o), cur = r.u8(o + 1), nheads = r.u8(o + 2), nnotes = r.u8(o + 3), colors = r.u8(o + 4)
        let kind = r.u8(o + 5), smooth = r.u8(o + 6) & 0x01 != 0
        let withChart = kind == 1
        o += 8
        var xc = [UInt32](repeating: 0, count: Xc.allCases.count)
        for i in 0..<colors {
            if i < xc.count {
                xc[i] = r.u32(o) & 0xFF_FFFF
            }
            o += 4
        }
        var t: [String] = []
        for _ in 0..<ntabs {
            let l = r.u8(o)
            o += 1
            let s = r.str(&o, l)
            if t.count < 16 {
                t.append(s)
            }
        }
        var hs: [[Span]] = [], ns: [[Span]] = []
        for _ in 0..<min(nheads, 16) {
            let n = r.u8(o)
            o += 1
            hs.append(readSpans(&r, &o, n))
        }
        for _ in 0..<min(nnotes, 16) {
            let n = r.u8(o)
            o += 1
            ns.append(readSpans(&r, &o, n))
        }
        guard r.ok else { return }
        picColors = xc
        tabs = t
        tab = cur
        heads = hs
        notes = ns
        hasChart = withChart
        chartIn = false
        picSmooth = smooth
        if kind == 2, let path = path {
            if path != picImagePath || picImage == nil {
                picImage = NSImage(contentsOfFile: (path as NSString).standardizingPath)
                picImagePath = picImage == nil ? nil : path
            }
        } else {
            picImage = nil
        }
        if isPic && !hasChart {
            newsReady()
        }
    }

    /// A chart's numbers (MU_S_CHART): kind, unit, labels, each series (color, name, a value per label), a heat map's
    /// row and column labels and cells.
    private func onChart(_ p: [UInt8]) {
        var r = Reader(p)
        var o = 4
        func f32(_ at: Int) -> CGFloat {
            let f = Float(bitPattern: r.u32(at))
            return f.isFinite ? CGFloat(f) : 0
        }
        var c = Chart()
        c.kind = r.u8(o)
        let nseries = r.u8(o + 1), nlabels = r.u16(o + 2), hr = r.u8(o + 4), hc = r.u8(o + 5)
        c.every = r.u8(o + 6)
        let unitLen = r.u8(o + 7)
        c.max = f32(o + 8)
        c.value = f32(o + 12)
        o += 16
        c.unit = r.str(&o, unitLen)
        for _ in 0..<nlabels {
            let l = r.u8(o)
            o += 1
            c.labels.append(r.str(&o, l))
        }
        for _ in 0..<min(nseries, 8) {
            let color = r.u32(o) & 0xFF_FFFF, nameLen = r.u8(o + 4)
            o += 8
            let name = r.str(&o, nameLen)
            var v: [CGFloat] = []
            for _ in 0..<c.labels.count {
                v.append(f32(o))
                o += 4
            }
            c.series.append(ChartSeries(color: color, name: name, v: v))
        }
        for _ in 0..<hr {
            let l = r.u8(o)
            o += 1
            c.rowL.append(r.str(&o, l))
        }
        for _ in 0..<hc {
            let l = r.u8(o)
            o += 1
            c.colL.append(r.str(&o, l))
        }
        for _ in 0..<(hr * hc) {
            c.heat.append(f32(o))
            o += 4
        }
        guard r.ok else { return }
        chart = c
        chartIn = true
        if isPic {
            newsReady()
        }
    }

    // ---- forms: reading ----

    /// A form's head (MU_S_FORM): fields to come, the active one, colors, the hint and the error.
    private func onForm(_ p: [UInt8]) {
        var r = Reader(p)
        var o = 4
        let count = r.u8(o), active = r.u8(o + 1), colors = r.u8(o + 2), hintLen = r.u8(o + 3), errLen = r.u8(o + 4)
        o += 8
        var fc = [UInt32](repeating: 0, count: Fc.allCases.count)
        for i in 0..<colors {
            if i < fc.count {
                fc[i] = r.u32(o) & 0xFF_FFFF
            }
            o += 4
        }
        let hint = r.str(&o, hintLen), err = r.str(&o, errLen)
        guard r.ok else { return }
        formColors = fc
        fHint = hint
        fErr = err
        fields.removeAll()
        formHits.removeAll()   // the last form's, until this one is drawn
        fieldsWant = min(count, Self.maxFields)
        fAct = active
    }

    /// A form's fields, in order: MuFormField + label + value + help + submitIf + choices (u8 length + text). The
    /// caret comes as characters from the value's end.
    private func onFormFields(_ p: [UInt8]) {
        var r = Reader(p)
        let first = r.u16(4), count = r.u16(6)
        var o = 8
        guard r.ok, first == fields.count else { return }   // out of order: a stale form's
        var added: [FormField] = []
        for _ in 0..<count where fields.count + added.count < fieldsWant {
            var f = FormField()
            f.flags = r.u8(o)
            let labelLen = r.u8(o + 1)
            f.max = r.u16(o + 2)
            let valueLen = r.u16(o + 4), cursor = r.u16(o + 6)
            let helpLen = r.u8(o + 8), submitLen = r.u8(o + 9), choices = r.u8(o + 10)
            o += 12
            f.label = r.str(&o, labelLen)
            f.value = Array(r.str(&o, valueLen))
            f.help = r.str(&o, helpLen)
            f.submitIf = r.str(&o, submitLen)
            for _ in 0..<choices {
                let l = r.u8(o)
                o += 1
                let c = r.str(&o, l)
                if f.choices.count < 32 {
                    f.choices.append(c)
                }
            }
            guard r.ok else { return }
            f.cur = max(f.value.count - cursor, 0)
            added.append(f)
        }
        fields.append(contentsOf: added)
        if isForm && fields.count >= fieldsWant {
            fAct = min(max(fAct, 0), max(fields.count - 1, 0))
            caretAt = Date()
            newsReady()
        }
    }

    private func rowOK(_ i: Int) -> Bool { i >= 0 && i < rows.count && rows[i].flags & Self.liHeading == 0 }

    private func listReady() {
        lSel = lStart < rows.count ? lStart : 0
        while lSel < rows.count - 1 && !rowOK(lSel) {
            lSel += 1
        }
        newsReady()
        listSnap = true
    }

    func newsReady() {
        complete = true
        scroll = 0
        scrollTo = 0
        if isUp {
            redraw()
        }
    }

    private func readSpans(_ r: inout Reader, _ o: inout Int, _ count: Int) -> [Span] {
        var list: [Span] = []
        for _ in 0..<count {
            let fg = r.u32(o), bg = r.u32(o + 4)
            let fx = UInt8(r.u8(o + 8))
            let len = r.u8(o + 9)
            o += 10
            list.append(Span(fg: fg, bg: bg, fx: fx, text: r.str(&o, len)))
        }
        return list
    }

    /// A dialog over the menu (Rainwire's Quote of the day): drawn until the board sends the menu again; the key or
    /// click that closes it goes back as Key.
    private func onDialog(_ p: [UInt8]) {
        guard isUp else {
            reply("Closed;error=no menu")   // the board only sends one over a menu that is up
            return
        }
        var r = Reader(p)
        var o = 4
        let titleLen = r.u8(o + 1), footLen = r.u8(o + 2), lineCount = min(r.u8(o + 3), Self.maxLines)
        let bg = r.u32(o + 4) & 0xFF_FFFF, border = r.u32(o + 8) & 0xFF_FFFF, fg = r.u32(o + 12) & 0xFF_FFFF
        let footFg = r.u32(o + 16) & 0xFF_FFFF
        o += 20
        let title = r.str(&o, titleLen), foot = r.str(&o, footLen)
        var lines: [[Span]] = []
        for _ in 0..<lineCount {
            let spans = r.u8(o)
            o += 1
            lines.append(readSpans(&r, &o, spans))
        }
        guard r.ok else { return }
        dialog = Dialog(title: title, foot: foot, bg: bg, border: border, fg: fg, footFg: footFg, lines: lines)
        dialogKeyed = false
        redraw()
    }

    /// The screen's background art (art.background), sent with every menu: the caller's screen, the art's cells (0:
    /// none) and its picture (path, from hdr=). Drawn as the text screen places it (`drawBackdrop`).
    private func onBackdrop(_ p: [UInt8], _ path: String?) {
        var r = Reader(p)
        let sc = r.u8(4), sr = r.u8(5), c = r.u8(6), rw = r.u8(7)
        guard r.ok else { return }
        bdScreenCols = sc
        bdScreenRows = sr
        bdCols = c
        bdRows = rw
        if c == 0 || rw == 0 || path == nil {
            backdrop = nil
            backdropPath = nil
        } else if path != backdropPath, let path = path {
            backdrop = NSImage(contentsOfFile: (path as NSString).standardizingPath)
            backdropPath = backdrop == nil ? nil : path
        }
        redraw()
    }

    /// The background art over the terminal picture: from its top, centered across the screen's columns, cols x rows
    /// cells (already cut above the status row), as Rainwire's text screen draws it; crisp unless Font smoothing.
    private func drawBackdrop(_ w: CGFloat, _ h: CGFloat) {
        guard let img = backdrop, bdScreenCols > 0, bdScreenRows > 0 else { return }
        let pic = picture(w, h)
        let cw = pic.width / CGFloat(bdScreenCols), ch = pic.height / CGFloat(bdScreenRows)
        let x0 = max((bdScreenCols - bdCols) / 2, 0)
        let rect = CGRect(x: pic.minX + CGFloat(x0) * cw, y: pic.minY, width: CGFloat(bdCols) * cw,
                          height: CGFloat(bdRows) * ch)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.imageInterpolation = UserDefaults.standard.bool(forKey: "font_smoothing") ? .high : .none
        img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// A line in the status bar's place for 8 s (MU_TOAST_MS), as the text screen's yellow toast: someone logged on
    /// or off, a message waiting.
    private func onToast(_ p: [UInt8]) {
        var r = Reader(p)
        var o = 4
        let fg = r.u32(o) & 0xFF_FFFF, bg = r.u32(o + 4) & 0xFF_FFFF, len = r.u8(o + 8)
        o += 12
        let text = r.str(&o, len)
        guard r.ok else { return }
        toast = text
        toastFg = fg
        toastBg = bg
        toastUntil = Date().addingTimeInterval(8)
        redraw()
    }

    /// A scene's toast (SceneToast, an input's cut paste): text in the status bar's place for seconds, in the
    /// colors the last toast had (Windows sets only the text too).
    func sceneToast(_ text: String, _ seconds: Double) {
        toast = text
        if let ts = scene {   // the scene's own colors (a board Toast's were black on black when none had come)
            toastBg = ts.colors[Sc.panel.rawValue] & 0xFF_FFFF
            toastFg = ts.colors[Sc.text.rawValue] & 0xFF_FFFF
        }
        toastUntil = Date().addingTimeInterval(seconds)
        redraw()
    }

    private func dialogKey(_ s: String) {
        guard !dialogKeyed else { return }
        dialogKeyed = true
        reply(s)
        redraw()
    }

    /// The header picture: the board's GIF (it plays, through NSImageView as TERMinator:Pic's are) or PNG.
    private func setHeader(_ path: String?) {
        guard path != headerPath else { return }
        headerPath = path
        header.image = nil
        headerW = 0
        headerH = 0
        guard let path = path else { return }
        let url = URL(fileURLWithPath: path)
        // Read whole (Data), so the cache file isn't held; the board may store it again
        guard FileManager.default.fileExists(atPath: url.path), let data = try? Data(contentsOf: url),
              let image = NSImage(data: data) else {
            menuLogger.warning("RainwireMenu: header \(path, privacy: .public) couldn't load")
            headerPath = nil
            return
        }
        for rep in image.representations {
            if let bitmap = rep as? NSBitmapImageRep {
                bitmap.setProperty(.loopCount, withValue: 0)   // an animated GIF loops forever
            }
            if headerW <= 0 || headerH <= 0 {
                headerW = rep.pixelsWide
                headerH = rep.pixelsHigh
            }
        }
        if headerW <= 0 || headerH <= 0 {
            headerW = Int(image.size.width)
            headerH = Int(image.size.height)
        }
        let ext = url.pathExtension.lowercased()
        // Pixel art (the board's GIFs, and the VGA PNGs it makes from ANSI headers) stays crisp when enlarged
        headerPixelArt = ext == "gif" || (headerW <= 1280 && Self.isVgaPng(url))
        scaleHeader()
        header.image = image
        header.animates = true
        needsLayout = true
    }

    /// A header Rainwire drew from ANSI art: 8x16 cells, so whole multiples of 8 by 16.
    private static func isVgaPng(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "png" && url.lastPathComponent.hasPrefix("rw-")
    }

    private func show() {
        guard complete else { return }
        hideGen += 1   // a pending hide is off
        let was = isUp
        isUp = true
        gadgetMovesFlush()   // version 6: gadgets the caller moved in the tray while the menu was down
        trayUpdate()
        waiting = false
        dialog = nil
        pressL = false
        pressR = false
        isHidden = false
        if !was {
            startTimers()
        }
        lastInput = Date()
        shownAt = Date()
        needsLayout = true
        redraw()
        reply("Shown")
    }

    /// Down: not up at once (the keyboard goes back to the terminal), but its picture stays ~120 ms, so the terminal
    /// view has repainted the screen Rainwire drew just before Hide (the sysop saw the screen from before the menu
    /// flash after "Log in hidden?", Windows). A Show in that time keeps it; `now` (the call ended) hides at once.
    private func hide(now: Bool = false) {
        hideGen += 1
        pressL = false
        pressR = false
        if isUp {
            isUp = false
            waiting = false
            dialog = nil
            gWide.removeAll()   // a screen or a door (News, Weather...): the gadgets come back at normal width
            stopTimers()
            gFocus = nil
            trayUpdate()   // version 6: tray gadgets show on the status bar while no menu is up
        }
        if now {
            isHidden = true
            return
        }
        let gen = hideGen
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self = self, self.hideGen == gen, !self.isUp else { return }
            self.isHidden = true
        }
    }

    private func startTimers() {
        stopTimers()
        func every(_ seconds: TimeInterval, _ body: @escaping (RainwireMenuView) -> Void) -> Timer {
            let t = Timer(timeInterval: seconds, repeats: true) { [weak self] _ in
                if let self = self {
                    body(self)
                }
            }
            RunLoop.main.add(t, forMode: .common)
            return t
        }
        animTimer = every(0.040) {
            $0.needsDisplay = true
            if $0.wire != nil || $0.wx != nil || !$0.gadgets.isEmpty {
                $0.overlay.needsDisplay = true   // the news panel scrolls, the buttons light
            }
        }
        rainTimer = every(0.150) { $0.rainStep() }
        pingTimer = every(10) { $0.reply($0.active ? "Ping;active=1" : "Ping") }
    }

    private func stopTimers() {
        animTimer?.invalidate()
        rainTimer?.invalidate()
        pingTimer?.invalidate()
        animTimer = nil
        rainTimer = nil
        pingTimer = nil
    }

    /// Sends s; anything but Shown also tells the board about the caller's activity, so it starts over.
    func reply(_ s: String) {
        if trayQuiet {   // version 6: a tray gadget drawn while no menu is up: the board may be in a door
            return
        }
        var s = s
        if let tag = gTag {   // from a scene gadget: it says which, g=<name>, after the verb
            if let semi = s.firstIndex(of: ";") {
                s.insert(contentsOf: ";g=" + tag, at: semi)
            } else {
                s += ";g=" + tag
            }
        }
        if s != "Shown" {
            active = false
        }
        guard let data = "\u{1B}_Rainwire:UI;\(s)\u{1B}\\".data(using: .utf8) else { return }
        sendQueue.async {
            _ = NativeBridge.shared.sendData(data)
        }
    }

    /// Sends s as it is: no g=, not counted as the caller's activity (Windows' Send: GadgetMoved, GadgetSize...).
    func sendRaw(_ s: String) {
        guard let data = "\u{1B}_Rainwire:UI;\(s)\u{1B}\\".data(using: .utf8) else { return }
        sendQueue.async {
            _ = NativeBridge.shared.sendData(data)
        }
    }

    // ================================================================
    // Input (TerminalKeyMonitor hands the keyboard here while the menu is up)
    // ================================================================

    private func isSelectable(_ i: Int) -> Bool {
        i >= 0 && i < items.count && items[i].selectable && items[i].box.width > 0
    }

    private func pick(_ index: Int, _ key: Int) {
        guard !waiting, complete else { return }
        waiting = true
        reply(index >= 0 ? "Pick;i=\(index)" : "Pick;key=\(key)")
        redraw()
    }

    private func step(_ d: Int) {
        var i = sel + d
        while i >= 0 && i < items.count {
            if isSelectable(i) {
                sel = i
                return
            }
            i += d
        }
    }

    /// The nearest item that way: Left/Right to the next column, Up/Down (a grid) to the next row of tiles.
    private func move2D(_ dc: Int, _ dr: Int) {
        guard isSelectable(sel) else {
            step(1)
            return
        }
        let cur = items[sel].box
        var best = -1
        var bestD = CGFloat.greatestFiniteMagnitude
        for i in items.indices where isSelectable(i) && i != sel {
            let b = items[i].box
            let dx = b.midX - cur.midX, dy = b.midY - cur.midY
            if dc != 0 && (dc > 0 ? dx <= 1 : dx >= -1) { continue }
            if dr != 0 && (dr > 0 ? dy <= 1 : dy >= -1) { continue }
            let d = dc != 0 ? abs(dx) + 3 * abs(dy) : abs(dy) + 3 * abs(dx)
            if d < bestD {
                bestD = d
                best = i
            }
        }
        if best >= 0 {
            sel = best
        }
    }

    /// From `TerminalKeyMonitor` (a key down while the terminal has the keyboard): true when the menu took it. While
    /// the menu is up it takes every key but Command shortcuts (Windows: the menu holds the keyboard focus), so
    /// nothing reaches the board under it: arrows, Enter and Esc move and pick; a typed character picks its item
    /// (the board finds it, hidden items too); over a dialog any key closes it.
    func handleKey(_ event: NSEvent) -> Bool {
        guard isUp, event.type == .keyDown else { return false }
        if event.modifierFlags.contains(.command) {
            if dialog == nil && !isScene && event.keyCode == 9, let g = gFocus, g.tree != nil {   // version 6: a gadget's field
                active = true
                inGadget(g) { scenePaste() }
                redraw()
                return true
            }
            if (isForm || isScene) && dialog == nil && event.keyCode == 9 {   // Cmd+V: the clipboard's text into the field
                active = true
                if isScene {
                    scenePaste()   // RainwireScene.swift: the focused field
                } else {
                    formPaste()
                }
                redraw()
                return true
            }
            return false
        }
        active = true
        lastInput = Date()
        let code = event.keyCode
        if dialog == nil && !isScene && gFocus != nil && gadgetKey(event) {   // version 6: a gadget has the keys
            return true
        }
        if dialog != nil {
            // as the text dialog: any key closes it
            switch code {
            case 36, 76: dialogKey("Key;key=13")                      // Return, keypad Enter
            case 53: dialogKey("Key;key=27")                          // Esc
            case 51: dialogKey("Key;key=8")                           // Backspace
            case 48: dialogKey("Key;key=9")                           // Tab
            case 123, 124, 125, 126, 115, 119, 116, 121: dialogKey("Key;key=13")   // arrows, Home, End, paging
            default:
                if let ch = Self.typed(event, minimum: 0x20) {
                    dialogKey("Key;key=\(ch)")
                }
            }
            return true
        }
        if isScene {   // RainwireScene.swift
            sceneKey(event)
            redraw()
            return true
        }
        if isPic {
            picKey(event)
            redraw()
            return true
        }
        if isForm {
            formKey(event)
            redraw()
            return true
        }
        if isList {
            let alt = event.modifierFlags.contains(.option), ctrl = event.modifierFlags.contains(.control)
            switch code {
            case 126: if alt { listKey(Self.vkUp, alt: true) } else { listStep(-1) }     // Up (Alt: the screen's)
            case 125: if alt { listKey(Self.vkDown, alt: true) } else { listStep(1) }    // Down
            case 116: listPage(-1)                                                       // Page Up
            case 121: listPage(1)                                                        // Page Down
            case 115:                                                                    // Home
                lSel = -1
                listStep(1)
            case 119:                                                                    // End
                lSel = rows.count
                listStep(-1)
            case 36, 76: if rowOK(lSel) { pick(lSel, 0) }                                // Return, keypad Enter
            case 53: newsBack()                                                          // Esc
            case 123: listKey(Self.vkLeft, alt: alt)                                     // Left
            case 124: listKey(Self.vkRight, alt: alt)                                    // Right
            case 48: listKey(Self.vkTab)                                                 // Tab
            case 117: listKey(Self.vkDelete)                                             // Forward Delete
            case 51: listKey(Self.vkBackspace)                                           // Delete (Backspace)
            case 122: listKey(Self.vkF1)                                                 // F1
            default:
                if ctrl {   // Ctrl+letter: the letter, as the text list gets it
                    if let c = event.charactersIgnoringModifiers?.uppercased().unicodeScalars.first,
                       c.value >= 0x41 && c.value <= 0x5A {
                        listKey(Self.vkChar, ctrl: true, cp: Int(c.value))
                    }
                } else if let ch = Self.typed(event, minimum: 0x20) {   // an action key (Space too)
                    listKey(Self.vkChar, cp: ch)
                }
            }
            redraw()
            return true
        }
        if isNews || isPage {
            let line = isPage ? pageLineH() : lineH(font(false, 13))
            switch code {
            case 126: newsScroll(-line)                                  // Up
            case 125: newsScroll(line)                                   // Down
            case 116: newsScroll(-viewH * 0.9)                           // Page Up
            case 121, 48: newsScroll(viewH * 0.9)                        // Page Down, Tab
            case 115: scrollTo = 0                                       // Home
            case 119: scrollTo = scrollMax                               // End
            case 36, 76, 53: newsBack()                                  // Return, keypad Enter, Esc
            default:
                if let ch = Self.typed(event, minimum: 0x20), ch == 0x20 || ch == 0x51 || ch == 0x71 {   // Space, Q
                    newsBack()
                }
            }
            redraw()
            return true
        }
        let grid = head.layout == Self.layoutGrid
        switch code {
        case 126: if grid { move2D(0, -1) } else { step(-1) }     // Up
        case 125: if grid { move2D(0, 1) } else { step(1) }       // Down
        case 48: step(1)                                           // Tab
        case 123: if grid { step(-1) } else { move2D(-1, 0) }     // Left
        case 124: if grid { step(1) } else { move2D(1, 0) }       // Right
        case 115, 116:                                             // Home, Page Up
            sel = -1
            step(1)
        case 119, 121:                                             // End, Page Down
            sel = items.count
            step(-1)
        case 36, 76:                                               // Return, keypad Enter
            if isSelectable(sel) {
                pick(sel, 0)
            }
        case 53:                                                   // Esc
            if !waiting && complete {
                waiting = true
                reply("Back")
            }
        default:
            // letters, digits and symbols pick their item; anything else (F-keys...) does nothing here
            if let ch = Self.typed(event, minimum: 0x21) {
                pick(-1, ch)
            }
        }
        redraw()
        return true
    }

    // ---- picture screens: keys (menumod.c pic_key) ----

    /// Every key goes to the screen (it moves tabs, ranges and pages itself) as Key;i=0;vk=;key=[;alt=1][;ctrl=1];
    /// Esc is Back.
    private func picKey(_ event: NSEvent) {
        let alt = event.modifierFlags.contains(.option), ctrl = event.modifierFlags.contains(.control)
        func send(_ vk: Int, alt: Bool = false, ctrl: Bool = false, cp: Int = 0) {
            guard !waiting, complete else { return }
            waiting = true
            reply("Key;i=0;vk=\(vk);key=\(cp)" + (alt ? ";alt=1" : "") + (ctrl ? ";ctrl=1" : ""))
        }
        switch event.keyCode {
        case 53: newsBack()                                         // Esc
        case 123: send(Self.vkLeft, alt: alt)                       // Left
        case 124: send(Self.vkRight, alt: alt)                      // Right
        case 126: send(Self.vkUp, alt: alt)                         // Up
        case 125: send(Self.vkDown, alt: alt)                       // Down
        case 116: send(Self.vkPgUp)                                 // Page Up
        case 121: send(Self.vkPgDn)                                 // Page Down
        case 115: send(Self.vkHome)                                 // Home
        case 119: send(Self.vkEnd)                                  // End
        case 36, 76: send(Self.vkEnter)                             // Return, keypad Enter
        case 48: send(Self.vkTab)                                   // Tab
        case 117: send(Self.vkDelete)                               // Forward Delete
        case 51: send(Self.vkBackspace)                             // Delete (Backspace)
        case 122: send(Self.vkF1)                                   // F1
        default:
            if ctrl {
                if let c = event.charactersIgnoringModifiers?.uppercased().unicodeScalars.first,
                   c.value >= 0x41 && c.value <= 0x5A {
                    send(Self.vkChar, ctrl: true, cp: Int(c.value))
                }
            } else if let ch = Self.typed(event, minimum: 0x20) {
                send(Self.vkChar, cp: ch)
            }
        }
    }

    // ---- forms: editing (menumod.c form_key, form_typed, form_click, form_enter) ----

    /// The form ends: every value back to Rainwire as one MU_C_FORM packet (MuHeader, MuCForm, then each value as a
    /// u16 length and UTF-8), base64 in FormDone.
    private func formSend(_ action: UInt8) {
        guard !waiting, complete, !fields.isEmpty else { return }
        var body: [UInt8] = []
        var n = 0
        for f in fields {
            var v = Array(String(f.value).utf8)
            if v.count > Self.maxValue {
                v = Array(v[0..<Self.maxValue])
            }
            if 8 + body.count + 2 + v.count > 4000 - 16 {   // MU_MAX_PACKET
                break
            }
            body.append(UInt8(v.count & 0xFF))
            body.append(UInt8(v.count >> 8))
            body.append(contentsOf: v)
            n += 1
        }
        let packet: [UInt8] = [Self.cForm, 0, 0, 0, action, UInt8(min(max(fAct, 0), 255)), UInt8(n), 0] + body
        waiting = true
        reply("FormDone;b64=" + Data(packet).base64EncodedString())
    }

    private func formNext(_ d: Int) {
        guard !fields.isEmpty else { return }
        fAct = (fAct + d + fields.count) % fields.count
        caretAt = Date()
    }

    /// Enter: the next field, or on the last one (or a value matching its submitIf) the form is sent.
    private func formEnter() {
        guard fAct >= 0 && fAct < fields.count else { return }
        let f = fields[fAct]
        let v = String(f.value).trimmingCharacters(in: CharacterSet(charactersIn: " "))
        if fAct == fields.count - 1 || (!f.submitIf.isEmpty && v.caseInsensitiveCompare(f.submitIf) == .orderedSame) {
            formSend(Self.formSubmit)
        } else {
            formNext(1)
        }
    }

    private func choiceIndex(_ f: FormField) -> Int { f.choices.firstIndex(of: String(f.value)) ?? -1 }

    private func choiceSet(_ i: Int, _ c: Int) {
        guard i >= 0 && i < fields.count, c >= 0 && c < fields[i].choices.count else { return }
        fields[i].value = Array(fields[i].choices[c])
        fields[i].cur = fields[i].value.count
    }

    /// Characters typed (or pasted) into the active field at the caret, to its max; a choice field: Space steps it,
    /// a letter picks the choice it starts.
    private func formInsert(_ text: String) {
        guard fAct >= 0 && fAct < fields.count else { return }
        caretAt = Date()
        let f = fields[fAct]
        if f.isChoice {
            guard let c = text.first, !f.choices.isEmpty else { return }
            if c == " " {
                choiceSet(fAct, (choiceIndex(f) + 1) % f.choices.count)
            } else if let k = f.choices.firstIndex(where: { $0.first.map { String($0).lowercased() == String(c).lowercased() } ?? false }) {
                choiceSet(fAct, k)
            }
            return
        }
        for c in text {
            guard let sc = c.unicodeScalars.first, sc.value >= 0x20, sc.value != 0x7F,
                  !(0xF700...0xF8FF).contains(sc.value) else { continue }   // control and AppKit function-key characters
            if fields[fAct].max > 0 && fields[fAct].value.count >= fields[fAct].max {
                return
            }
            if String(fields[fAct].value).utf8.count + String(c).utf8.count > Self.maxValue {
                return
            }
            fields[fAct].value.insert(c, at: fields[fAct].cur)
            fields[fAct].cur += 1
        }
    }

    /// Cmd+V: the clipboard's first line into the active field.
    private func formPaste() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        let line = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }).first.map(String.init) ?? ""
        if !line.isEmpty && fAct >= 0 && fAct < fields.count && !fields[fAct].isChoice {
            formInsert(line)
        }
    }

    private func formKey(_ event: NSEvent) {
        guard !fields.isEmpty, fAct >= 0 && fAct < fields.count else { return }
        caretAt = Date()
        let i = fAct
        let choice = fields[i].isChoice
        let n = fields[i].choices.count
        switch event.keyCode {
        case 123:                                                  // Left
            if choice { if n > 0 { choiceSet(i, (choiceIndex(fields[i]) - 1 + n) % n) } }
            else if fields[i].cur > 0 { fields[i].cur -= 1 }
        case 124:                                                  // Right
            if choice { if n > 0 { choiceSet(i, (choiceIndex(fields[i]) + 1) % n) } }
            else if fields[i].cur < fields[i].value.count { fields[i].cur += 1 }
        case 115: if !choice { fields[i].cur = 0 }                 // Home
        case 119: if !choice { fields[i].cur = fields[i].value.count }   // End
        case 51:                                                   // Delete (Backspace)
            if !choice && fields[i].cur > 0 {
                fields[i].value.remove(at: fields[i].cur - 1)
                fields[i].cur -= 1
            }
        case 117:                                                  // Forward Delete
            if !choice && fields[i].cur < fields[i].value.count {
                fields[i].value.remove(at: fields[i].cur)
            }
        case 48: formNext(event.modifierFlags.contains(.shift) ? -1 : 1)   // Tab, Shift+Tab
        case 125: formNext(1)                                      // Down
        case 126: formNext(-1)                                     // Up
        case 36, 76: formEnter()                                   // Return, keypad Enter
        case 53: formSend(Self.formCancel)                         // Esc
        default:
            if !event.modifierFlags.contains(.control), let chars = event.characters, !chars.isEmpty {
                formInsert(chars)
            }
        }
    }

    /// A click on a choice picks it; on a field makes it active with the caret at the nearest character.
    private func formClick(_ p: CGPoint) {
        guard !waiting && complete else { return }   // the fields still coming: the hits are the last form's
        guard let hit = formHits.first(where: { $0.rect.contains(p) && $0.field >= 0 && $0.field < fields.count })
        else { return }
        caretAt = Date()
        fAct = hit.field
        if hit.choice >= 0 {
            choiceSet(hit.field, hit.choice)
            return
        }
        let f = fields[hit.field]
        if f.isSecret {
            fields[hit.field].cur = f.value.count
            return
        }
        let x = p.x - (hit.rect.minX + 10 * u)
        let uf = font(false, 13)
        var best = f.value.count
        for at in 0...f.value.count where Self.textW(String(f.value[0..<at]), uf) >= x {
            best = at
            break
        }
        fields[hit.field].cur = best
    }

    /// A list's moves: to the nearest row that isn't a heading that way.
    private func listStep(_ d: Int) {
        var i = lSel + d
        while i >= 0 && i < rows.count {
            if rowOK(i) {
                lSel = i
                return
            }
            i += d
        }
    }

    /// A page of rows up or down (90% of the view), by where the rows lie.
    private func listPage(_ d: Int) {
        let target = rowOK(lSel) ? rows[lSel].y + CGFloat(d) * viewH * 0.9 : 0
        var best = lSel
        for i in rows.indices where rowOK(i) {
            if d > 0 ? rows[i].y <= target : rows[i].y >= target {
                best = i
                if d < 0 {
                    break
                }
            }
        }
        lSel = best
    }

    /// A key the list doesn't use: the screen acts on it (Key;i= the selected row;vk=;key=;alt=1;ctrl=1).
    private func listKey(_ vk: Int, alt: Bool = false, ctrl: Bool = false, cp: Int = 0) {
        guard !waiting, complete else { return }
        waiting = true
        reply("Key;i=\(max(lSel, 0));vk=\(vk);key=\(cp)" + (alt ? ";alt=1" : "") + (ctrl ? ";ctrl=1" : ""))
    }

    /// The news screen goes: Rainwire goes on (the next menu replaces it in place).
    func newsBack() {
        guard !waiting, complete else { return }
        waiting = true
        reply("Back")
    }

    private func newsScroll(_ by: CGFloat) {
        scrollTo = min(max(scrollTo + by, 0), scrollMax)
    }

    /// The first printable character the key typed (the keyboard layout's, Shift and dead keys worked out), as a
    /// code point at least `minimum` and not DEL, or nil.
    private static func typed(_ event: NSEvent, minimum: UInt32) -> Int? {
        guard let chars = event.characters else { return nil }
        for scalar in chars.unicodeScalars where scalar.value >= minimum && scalar.value != 0x7F
            && !(0xF700...0xF8FF).contains(scalar.value) {   // AppKit's function-key characters
            return Int(scalar.value)
        }
        return nil
    }

    private func hitItem(_ p: CGPoint) -> Int {
        for i in items.indices where isSelectable(i) && items[i].box.contains(p) {
            return i
        }
        return -1
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect,
                                                                 .cursorUpdate],
                                       owner: self, userInfo: nil))
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.arrow.set()
        guard isUp else { return }   // going down (its picture kept a moment): nothing more
        lastInput = Date()
        // version 6: a drag whose release went elsewhere ends here (the button is up)
        if sceneDrag6(convert(event.locationInWindow, from: nil)) || gadgetDragMove(convert(event.locationInWindow, from: nil)) {
            return
        }
        if isScene {   // the control under the pointer lights up, its cursor; tooltips (RainwireScene.swift)
            sceneMove(convert(event.locationInWindow, from: nil))
            return
        }
        if wireMove(convert(event.locationInWindow, from: nil)) {   // over the news panel beside the header
            return
        }
        if isPic {   // the tabs and the chart light up under the pointer, with a tooltip (drawn each frame)
            pointer = convert(event.locationInWindow, from: nil)
            needsDisplay = true
            return
        }
        if isForm {
            return
        }
        if isList || isPage {   // a list: the row under the pointer is selected (style hover)
            let p = convert(event.locationInWindow, from: nil)
            if isList && dialog == nil && !waiting && st.hover, let hit = rowHits.first(where: { $0.rect.contains(p) }),
               hit.row != lSel {
                lSel = hit.row
                active = true
                redraw()
            }
            return
        }
        if isNews && dialog == nil {   // a link under the pointer lights up
            let p = convert(event.locationInWindow, from: nil)
            let was = pointer.flatMap { linkAt($0) }
            pointer = p
            let now = linkAt(p)
            if now != nil {
                NSCursor.pointingHand.set()
            }
            if now != was {
                redraw()
            }
            return
        }
        guard !waiting, dialog == nil, !isNews, st.hover else { return }
        let i = hitItem(convert(event.locationInWindow, from: nil))
        if i >= 0 && i != sel {
            sel = i
            active = true
            redraw()
        }
    }

    override func mouseDown(with event: NSEvent) {
        // taken here, so nothing reaches the terminal under the menu; a click picks on the release (Windows: MouseUp)
        pressL = isUp
        let p = convert(event.locationInWindow, from: nil)
        if isUp && down6(p) {   // version 6: a scroll bar, divider, slider or gadget dragged: no click
            pressL = false
            return
        }
        if isUp && isScene {   // a drag out may start from a P_DRAG row here (version 5, RainwireScene.swift)
            sceneButtonDown(p)
        }
    }

    /// The left button down (version 6): a screen's bars, dividers and sliders, or the gadgets' (their titles, grips,
    /// and what's in them). True when a drag started (no click follows).
    private func down6(_ p: CGPoint) -> Bool {
        guard isUp, dialog == nil else { return false }
        if isScene {
            guard let s = scene, complete else { return false }
            return sceneDown6(s, p, nil)
        }
        wireMouse = p
        return gadgetDown(p)
    }

    /// The left button up (version 6): true when it ended a drag.
    private func up6(_ p: CGPoint) -> Bool {
        let a = sceneUp6()
        let b = gadgetDragEnd(p)
        return a || b
    }

    /// The middle, back and forward buttons (version 6): Click;btn=m for a block that asks (gadgets too); back is Esc;
    /// forward a key only screens that know it use (Key;nav=fwd), nothing on menus.
    override func otherMouseDown(with event: NSEvent) {
        guard isUp else {
            super.otherMouseDown(with: event)
            return
        }
        let p = convert(event.locationInWindow, from: nil)
        active = true
        lastInput = Date()
        switch event.buttonNumber {
        case 2:   // middle
            guard dialog == nil else { return }
            if isScene, let s = scene, complete {
                sceneMiddle(s, p)
            } else if let g = gadgetAt(p), let t = g.tree {
                wireMouse = p
                inGadget(g) { sceneMiddle(t, p) }
            }
        case 3:   // back: what Esc does
            if let esc = NSEvent.keyEvent(with: .keyDown, location: event.locationInWindow, modifierFlags: [],
                                          timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
                                          characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false,
                                          keyCode: 53) {
                _ = handleKey(esc)
            }
        case 4:   // forward
            if dialog == nil {
                sceneNavForward()
            }
        default:
            break
        }
        redraw()
    }

    /// The pointer moved with the left button down: a scene row dragged out (version 5), else what a move does.
    /// AppKit keeps sending these to this view outside the window while the button is held. Version 6: a scroll bar,
    /// divider or slider (a screen's or a gadget's), or a gadget's title or edge, being dragged.
    override func mouseDragged(with event: NSEvent) {
        if isUp {
            let p = convert(event.locationInWindow, from: nil)
            if sceneDrag6(p) || gadgetDragMove(p) {
                lastInput = Date()
                return
            }
        }
        guard isUp, isScene else {
            super.mouseDragged(with: event)   // as before version 5: up the responder chain
            return
        }
        if sceneDragMove(convert(event.locationInWindow, from: nil), event) {
            return
        }
        lastInput = Date()
        sceneMove(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        var pressed = pressL
        pressL = false
        if isScene && sceneButtonUp() {   // a row's drag ended: no click
            pressed = false
        }
        if up6(convert(event.locationInWindow, from: nil)) {   // version 6: a drag ended: no click
            pressed = false
        }
        // going down: a click no longer counts; nor a release whose press wasn't here, or that left the view
        guard isUp, pressed, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        active = true
        lastInput = Date()
        if dialog != nil {
            dialogKey("Key;click=1")
            return
        }
        if isScene {   // the control under the pointer (RainwireScene.swift)
            sceneClick(convert(event.locationInWindow, from: nil))
            return
        }
        if wireClick(convert(event.locationInWindow, from: nil)) {   // a story in the news panel
            return
        }
        if isPic {   // a click on a tab opens it
            let p = convert(event.locationInWindow, from: nil)
            if let hit = tabHits.first(where: { $0.rect.contains(p) }), hit.tab != tab {
                pick(hit.tab, 0)
            }
            return
        }
        if isForm {
            if !waiting {
                formClick(convert(event.locationInWindow, from: nil))
                redraw()
            }
            return
        }
        if isPage {
            newsBack()
            return
        }
        if isList {   // a click selects a row; a click on the selected one opens it
            let p = convert(event.locationInWindow, from: nil)
            if let hit = rowHits.first(where: { $0.rect.contains(p) }), rowOK(hit.row) {
                if hit.row == lSel {
                    pick(lSel, 0)
                } else {
                    lSel = hit.row
                    redraw()
                }
            }
            return
        }
        if isNews {   // a link opens in the browser; anywhere else goes on
            if newsLinks, let address = linkAt(convert(event.locationInWindow, from: nil)) {
                openLink(address)
            } else {
                newsBack()
            }
            return
        }
        let i = hitItem(convert(event.locationInWindow, from: nil))
        if i >= 0 {
            sel = i
            pick(i, 0)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        pressR = isUp
    }

    /// A right-click: a scene's context menu or Click;btn=r (RainwireScene.swift sceneRightClick), its press here too.
    override func rightMouseUp(with event: NSEvent) {
        let pressed = pressR
        pressR = false
        let p = convert(event.locationInWindow, from: nil)
        guard isUp, pressed, bounds.contains(p), dialog == nil else { return }
        active = true
        lastInput = Date()
        if !isScene && widgetRightClick(p) {   // version 6: a gadget's own menu (the widgets extension)
            return
        }
        if isScene, complete, let s = scene, sceneRightClick(s, p) {
            redraw()
        }
    }

    /// The wheel moves the selection: a mouse wheel a step a notch, a trackpad a step every 20 points.
    override func scrollWheel(with event: NSEvent) {
        guard isUp else { return }
        active = true
        lastInput = Date()
        guard dialog == nil, !isForm, !isPic else { return }
        if isScene {   // the scroll or list under the pointer, else the scene (RainwireScene.swift)
            sceneWheel(event)
            return
        }
        if wireWheel(event) {   // over the news panel: its stories
            return
        }
        if isNews || isPage {   // the news and pages scroll smoothly: a trackpad by its points, a wheel 60 a notch
            if event.hasPreciseScrollingDeltas {
                newsScroll(-event.scrollingDeltaY)
            } else if event.scrollingDeltaY != 0 {
                newsScroll(event.scrollingDeltaY > 0 ? -60 * u : 60 * u)
            }
            redraw()
            return
        }
        var steps = 0
        if event.hasPreciseScrollingDeltas {
            wheelRemainder += event.scrollingDeltaY
            while wheelRemainder >= 20 {
                steps -= 1
                wheelRemainder -= 20
            }
            while wheelRemainder <= -20 {
                steps += 1
                wheelRemainder += 20
            }
        } else if event.scrollingDeltaY != 0 {
            steps = event.scrollingDeltaY > 0 ? -1 : 1
        }
        guard steps != 0 else { return }
        for _ in 0..<abs(steps) {
            if isList {   // a list: a row a step
                listStep(steps > 0 ? 1 : -1)
            } else {
                step(steps > 0 ? 1 : -1)
            }
        }
        redraw()
    }

    // ================================================================
    // Drawing (the module's layout, menumod.c, in points: one unit is the module's logical pixel at this size)
    // ================================================================

    private static let keyW: CGFloat = 30
    private static let gap: CGFloat = 18, hdrGap: CGFloat = 26

    // The sysop's style (st): the status bar and help line take no room when off; padding, row height and the key's
    // column are theirs.
    var statusH: CGFloat { st.status ? 26 : 0 }
    private var helpH: CGFloat { st.help ? 28 : 0 }
    private var pad: CGFloat { st.padding }
    private var keyW: CGFloat { st.key == 4 ? 0 : Self.keyW }

    /// The label font: rows.font (sans, or the system's monospaced) at rows.size, bold as the labels always were.
    private func labelFont() -> NSFont {
        st.font == 1 ? NSFont.monospacedSystemFont(ofSize: st.size * u, weight: .semibold) : font(true, st.size)
    }

    /// The room the title takes inside the box (box.title = inside), else 0.
    private var titleInside: CGFloat {
        st.title == 1 && !head.title.isEmpty ? Self.fontLine(font(true, 17)) + 10 * u : 0
    }

    /// The box's fade-in, 0..1 (1: done; box.fade ms, 0: none).
    func fadeIn() -> CGFloat {
        st.fade <= 0 ? 1 : CGFloat(min(max(Date().timeIntervalSince(shownAt) * 1000 / Double(st.fade), 0), 1))
    }

    var u: CGFloat = 1            // points per module logical pixel
    private var rowH: CGFloat = 26
    private var box = CGRect.zero

    func redraw() {
        needsDisplay = true
        overlay.needsDisplay = true
    }

    override func layout() {
        super.layout()
        overlay.frame = bounds
        dimView.frame = bounds
        // the news panel goes over the header's right; a whole-window scene (SF_BLEED) has no header
        let hr = sceneBleeds ? .zero : wireLayout(headerRect(bounds.width, bounds.height))
        header.isHidden = hr.isEmpty
        if !hr.isEmpty {
            header.frame = hr
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
        redraw()
    }

    static func color(_ rgb: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255, alpha: alpha)
    }

    func mc(_ i: Mc) -> UInt32 { head.colors[i.rawValue] }

    static func mix(_ a: UInt32, _ b: UInt32, _ t: CGFloat) -> UInt32 {
        let t = min(max(t, 0), 1)
        func ch(_ s: UInt32) -> UInt32 {
            let x = CGFloat((a >> s) & 0xFF), y = CGFloat((b >> s) & 0xFF)
            return UInt32(x + (y - x) * t) << s
        }
        return ch(16) | ch(8) | ch(0)
    }

    static func luma(_ c: UInt32) -> Int {
        Int(CGFloat((c >> 16) & 0xFF) * 0.299 + CGFloat((c >> 8) & 0xFF) * 0.587 + CGFloat(c & 0xFF) * 0.114)
    }

    func font(_ bold: Bool, _ size: CGFloat) -> NSFont {
        NSFont.systemFont(ofSize: size * u, weight: bold ? .semibold : .regular)
    }

    static func text(_ s: String, _ f: NSFont, _ c: UInt32, _ alpha: CGFloat = 1) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: color(c, alpha)])
    }

    static func textW(_ s: String, _ f: NSFont) -> CGFloat {
        NSAttributedString(string: s, attributes: [.font: f]).size().width
    }

    /// Where to draw text in f (the top of its line, in this flipped view) so its capitals sit centered on
    /// centerY: the line box has more room above the letters than below, so centering the box put the text low in
    /// the selection bar (Windows' MidY, Rainwire 0.9.127).
    static func capY(_ f: NSFont, _ centerY: CGFloat) -> CGFloat {
        centerY + f.capHeight / 2 - f.ascender
    }

    private func labelW(_ it: Item) -> CGFloat {
        let f = labelFont()
        return it.spans.reduce(CGFloat(0)) { $0 + Self.textW($1.text, f) }
    }

    private func tagW(_ it: Item) -> CGFloat {
        it.tag.isEmpty ? 0 : Self.textW(it.tag, font(false, 13)) + 12 * u
    }

    /// The terminal picture's rect, or the whole view.
    private func picture(_ w: CGFloat, _ h: CGFloat) -> CGRect {
        if let r = pictureRect, r.width > 0, r.height > 0 {
            return r
        }
        return CGRect(x: 0, y: 0, width: w, height: h)
    }

    /// The header's place: over the text screen's header rows (the picture's width, hdrRows/screenRows of its
    /// height), else full width in its own shape; at most 60% of the height.
    private func headerRect(_ w: CGFloat, _ h: CGFloat) -> CGRect {
        guard headerPath != nil, headerW > 0, w > 0, h > 0, st.fit != 2 else { return .zero }   // header.fit none
        let pic = picture(w, h)
        var hw = pic.width
        let rows = head.hdrRows > 0 && head.screenRows > 0 ? pic.height * CGFloat(head.hdrRows) / CGFloat(head.screenRows) : 0
        var hh = rows > 0 && st.fit == 0 ? rows : CGFloat(headerH) * hw / CGFloat(headerW)
        if st.fit == 1 && rows > 0 && hh > rows {   // fit: its own shape, no taller than its rows (narrower, centered)
            hw *= rows / hh
            hh = rows
        }
        if hh > h * 0.6 {
            hw *= h * 0.6 / hh
            hh = h * 0.6
        }
        return CGRect(x: pic.minX + (pic.width - hw) / 2, y: pic.minY, width: hw, height: hh)
    }

    private func layoutMenu(_ w: CGFloat, _ h: CGFloat, _ top: CGFloat) {
        for it in items {
            it.box = .zero
        }
        let bottom = h - (statusH + helpH + 6) * u
        let room = bottom - top - (2 * pad + 8) * u
        let vis = items.filter { $0.flags & Self.ifColumn == 0 }
        let breaks = items.filter { $0.flags & Self.ifColumn != 0 }.count
        if head.layout == Self.layoutGrid {
            layoutTiles(w, top, vis)
            return
        }
        var cols: [[Item]] = [[]]
        if breaks > 0 {
            for it in items {
                if it.flags & Self.ifColumn != 0 {
                    if !cols[cols.count - 1].isEmpty && cols.count < 8 {
                        cols.append([])
                    }
                    continue
                }
                cols[cols.count - 1].append(it)
            }
        } else {
            var wantCols = head.layout == Self.layoutColumns ? ((2...4).contains(head.columns) ? head.columns : 2) : 1
            let fits = max(1, Int(room / (22 * u)))
            while wantCols < 8 && (vis.count + wantCols - 1) / wantCols > fits {
                wantCols += 1
            }
            let per = max(1, (vis.count + wantCols - 1) / wantCols)
            cols = stride(from: 0, to: vis.count, by: per).map { Array(vis[$0..<min($0 + per, vis.count)]) }
            if cols.isEmpty {
                cols.append([])
            }
        }
        for c in cols.indices {   // a blank separator at the top of a column takes no row
            while let first = cols[c].first, first.flags & Self.ifSeparator != 0, first.spans.isEmpty {
                cols[c].removeFirst()
            }
        }
        let rows = max(1, cols.map { $0.count }.max() ?? 1)
        let pitch = min(max(room / CGFloat(rows), 20 * u), (st.height + st.gap) * u)   // a row and the gap under it
        rowH = pitch > (st.gap + 14) * u ? pitch - st.gap * u : pitch
        var cw = cols.map { colWidth($0) }
        let total = cw.reduce(0, +)
        var want2 = total + Self.gap * u * CGFloat(cols.count - 1) + 2 * pad * u
        if head.width > 0 {
            let set = (head.width >= 80 ? w : w * CGFloat(head.width) / 80) - 20 * u
            want2 = max(want2, set)
        }
        if st.width > 0 {   // the sysop's width, % of the window
            want2 = max(want2, w * st.width / 100)
        }
        if !head.title.isEmpty && st.title == 0 {   // a title on the top border fits on it, 18 in from either corner
            want2 = max(want2, Self.textW(head.title, font(true, 17)) + 36 * u)
        }
        want2 = min(want2, w - 20 * u)
        let extra = (want2 - 2 * pad * u - Self.gap * u * CGFloat(cols.count - 1) - total) / CGFloat(cols.count)
        let headRoom = titleInside
        let bh = CGFloat(rows) * (rowH + st.gap * u) - st.gap * u + 2 * pad * u + headRoom
        let bx = head.position == Self.posLeft ? 10 * u
            : head.position == Self.posRight ? w - want2 - 10 * u : (w - want2) / 2
        box = CGRect(x: bx, y: top + 6 * u, width: want2, height: bh)
        var x = box.minX + pad * u
        for c in cols.indices {
            cw[c] += extra
            for (k, it) in cols[c].enumerated() {
                it.box = CGRect(x: x, y: box.minY + pad * u + headRoom + CGFloat(k) * (rowH + st.gap * u),
                                width: max(cw[c], 1), height: rowH)
            }
            x += cw[c] + Self.gap * u
        }
        placeBox(w, h, top)
    }

    /// A column's width: its widest item (key, label, tag), at least 120.
    private func colWidth(_ col: [Item]) -> CGFloat {
        var widest: CGFloat = 0
        for it in col {
            widest = max(widest, (keyW + 12 + 16) * u + labelW(it) + tagW(it))
        }
        return max(120 * u, widest)
    }

    private func layoutTiles(_ w: CGFloat, _ top: CGFloat, _ vis: [Item]) {
        let tw = CGFloat(head.tileCols > 0 ? head.tileCols : 18) * 9 * u
        let th = CGFloat(head.tileRows > 0 ? head.tileRows : 5) * 13 * u
        let gap = 10 * u
        let across = max(1, Int((w - (2 * pad + 40) * u) / (tw + gap)))
        var y: CGFloat = 0
        var c = 0, maxc = 1
        var placed: [(Item, CGRect)] = []
        for it in vis {
            if it.flags & Self.ifSeparator != 0 {
                if c > 0 {
                    y += th + gap
                    c = 0
                }
                if !it.spans.isEmpty {
                    placed.append((it, CGRect(x: 0, y: y, width: 1, height: 24 * u)))
                    y += 28 * u
                }
                continue
            }
            if c >= across {
                y += th + gap
                c = 0
            }
            placed.append((it, CGRect(x: CGFloat(c) * (tw + gap), y: y, width: tw, height: th)))
            c += 1
            maxc = max(maxc, c)
        }
        if c > 0 {
            y += th + gap
        }
        let bw = CGFloat(maxc) * (tw + gap) - gap + 2 * pad * u
        let bx = head.position == Self.posLeft ? 10 * u : head.position == Self.posRight ? w - bw - 10 * u : (w - bw) / 2
        box = CGRect(x: bx, y: top + 6 * u, width: bw, height: max(y - gap, 0) + 2 * pad * u)
        for (it, r) in placed {
            it.box = CGRect(x: box.minX + pad * u + r.minX, y: box.minY + pad * u + r.minY,
                            width: it.flags & Self.ifSeparator != 0 ? bw - 2 * pad * u : r.width, height: r.height)
        }
    }

    /// Centered in the room between the header and the help line (the whole height with no header), as the module
    /// does: low under a tall header, in the middle under a small logo.
    private func placeBox(_ w: CGFloat, _ h: CGFloat, _ top: CGFloat) {
        let bottom = h - (statusH + helpH + 4) * u
        var y = box.minY
        switch st.valign {   // box.valign; auto as before: centered in the room, never higher than it starts
        case 1: y = top
        case 2: y = max((h - statusH * u - box.height) / 2, top)
        case 3: y = max(bottom - box.height, top)
        default: y = max(y, top + (bottom - top - box.height) / 2)
        }
        var x = box.minX
        if st.x != 0 || st.y != 0 || st.valign != 0 {   // the sysop's nudge, never off the window
            y += h * st.y / 100
            x += w * st.x / 100
            x = min(max(x, 4 * u), max(w - box.width - 4 * u, 4 * u))
            y = min(max(y, 4 * u), max(h - statusH * u - box.height - 4 * u, 4 * u))
        }
        let dx = x - box.minX, dy = y - box.minY
        box = box.offsetBy(dx: dx, dy: dy)
        for it in items where it.box.width > 0 {
            it.box = it.box.offsetBy(dx: dx, dy: dy)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let w = bounds.width, h = bounds.height
        guard w > 0, h > 0 else { return }
        // a module's screen as a scene (SF_BLEED) is the module's size: never under a device pixel to its logical pixel
        // (gfx.h set_display), so a window under 620 pixels tall lays out as the module does
        u = sceneBleeds ? max(h / 620, 1 / max(window?.backingScaleFactor ?? 2, 0.5)) : max(h / 620, 0.75)
        gArea = CGRect(x: 0, y: 0, width: w, height: max(h - statusH * u, 0))   // version 6: floating gadgets' room
        Self.color(mc(.bg)).setFill()
        bounds.fill()
        drawBackdrop(w, h)
        if head.flags & Self.mfRain != 0 {
            drawRain(w, h)
        }
        let bleeds = sceneBleeds   // a whole-window scene (SF_BLEED): no header, no status bar
        let hr = bleeds ? .zero : wireLayout(headerRect(w, h))
        let top = (hr.isEmpty ? 0 : hr.maxY) + Self.hdrGap * u
        if complete && isScene {
            drawScene(w, h, hr.isEmpty ? 0 : hr.maxY)   // RainwireScene.swift
        } else if complete && isNews {
            drawNews(w, h, hr.isEmpty ? 0 : hr.maxY)
        } else if complete && isPage {
            drawPage(w, h, hr.isEmpty ? 0 : hr.maxY)
        } else if complete && isList {
            drawList(w, h, hr.isEmpty ? 0 : hr.maxY)
        } else if complete && isPic {
            drawPicture(w, h, hr.isEmpty ? 0 : hr.maxY)
        } else if complete && isForm {
            drawForm(w, h, hr.isEmpty ? 0 : hr.maxY)
        } else if complete {
            layoutMenu(w, h, top)
            drawBox()
            for i in items.indices {
                drawItem(i)
            }
            let fade = fadeIn()
            if fade < 1 {
                Self.color(mc(.menuBg), 1 - fade).setFill()
                box.fill(using: .sourceOver)
            }
            if st.help {
                drawHelp(w, h)
            }
        }
        if st.status && !bleeds {
            drawStatus(w, h)
        }
    }

    // ---- the news screen (menumod.c draw_news: the module's look, in points) ----

    private func nc(_ i: Nc) -> UInt32 { newsColors[i.rawValue] }

    /// A font's line box, without the news screen's spacing.
    static func fontLine(_ f: NSFont) -> CGFloat { ceil(f.ascender - f.descender + f.leading) }

    /// A wrapped line of the news: the line box and 6 between lines (the module's NEWS_LINE).
    private func lineH(_ f: NSFont) -> CGFloat { Self.fontLine(f) + 6 * u }

    /// Spans laid out from (x, y), wrapped at words to w (a "\n" breaks the line), drawn when draw and inside the
    /// panel; y ends under the last line. A span keeps its own color (none: def), background, pulse, shimmer, blink.
    private func flow(_ f: NSFont, _ spans: [Span], _ x: CGFloat, _ w: CGFloat, _ y: inout CGFloat, _ def: UInt32,
                      _ draw: Bool) {
        guard !spans.isEmpty else { return }
        let lh = lineH(f)
        let now = nowMs
        var cx = x
        for s in spans {
            var fg = s.fg != Self.none ? s.fg & 0xFF_FFFF : def
            if s.fx == Self.fxPulse {
                let t = 0.5 + 0.5 * sin(now / 1000 * 3.6)
                fg = Self.mix(Self.mix(fg, nc(.panelBg), 0.5), fg, CGFloat(t))
            }
            let chars = Array(s.text)
            var i = 0
            while i < chars.count {
                if chars[i] == "\n" {
                    cx = x
                    y += lh
                    i += 1
                    continue
                }
                var j = i   // a word and the spaces after it
                while j < chars.count && chars[j] != " " && chars[j] != "\n" {
                    j += 1
                }
                let wordEnd = j
                while j < chars.count && chars[j] == " " {
                    j += 1
                }
                var start = i
                let ww = Self.textW(String(chars[start..<wordEnd]), f)
                if cx > x && cx + ww > x + w {
                    cx = x
                    y += lh
                    while start < j && chars[start] == " " {   // no spaces at a line's start
                        start += 1
                    }
                }
                let piece = String(chars[start..<j])
                let pw = Self.textW(piece, f)
                if draw && y + lh >= vTop && y <= vBot {
                    if s.bg != Self.none && !(s.fx == Self.fxBlink && Int(now / 500) % 2 == 1) {
                        Self.color(s.bg & 0xFF_FFFF).setFill()
                        CGRect(x: cx, y: y + 1 * u, width: pw, height: lh - 2 * u).fill()
                    }
                    let ty = Self.capY(f, y + lh / 2)
                    var spanFg = fg
                    let word = start < wordEnd ? Array(chars[start..<wordEnd]) : []   // spaces only: none
                    let ln = newsLinks ? Self.linkLen(word) : 0
                    if ln > 0 {   // a link: underlined, brighter under the pointer, clickable
                        let address = String(word[0..<ln])
                        let lw = Self.textW(address, f)
                        let rect = CGRect(x: cx, y: y, width: lw, height: lh)
                        let on = pointer.map { rect.contains($0) } ?? false
                        if on {
                            spanFg = Self.mix(fg, 0xFF_FFFF, 0.45)
                        }
                        Self.color(spanFg, on ? 1 : 0.6).setFill()
                        CGRect(x: cx, y: ty + f.ascender + 1.5 * u, width: lw, height: max(on ? 1.5 * u : 1 * u, 1))
                            .fill(using: .sourceOver)
                        if y >= vTop - lh / 2 && y + lh <= vBot + lh / 2 {
                            links.append((rect: rect, url: address))
                        }
                    }
                    if s.fx == Self.fxShimmer {
                        let pos = CGFloat(now / 1400).truncatingRemainder(dividingBy: 1.8) * (pw + 60 * u) - 30 * u
                        var gx = cx
                        for ch in piece {
                            let str = String(ch)
                            let cw = Self.textW(str, f)
                            let glint = 1 - min(max(abs(gx + cw / 2 - cx - pos) / (24 * u), 0), 1)
                            Self.text(str, f, Self.mix(spanFg, 0xFF_FFFF, glint * 0.85)).draw(at: CGPoint(x: gx, y: ty))
                            gx += cw
                        }
                    } else {
                        Self.text(piece, f, spanFg).draw(at: CGPoint(x: cx, y: ty))
                    }
                }
                cx += pw
                i = j
            }
        }
        y += lh
    }

    /// How many characters at a word's start are a web address (https://, http:// or www., case-insensitive, at
    /// least 3 characters after it, less trailing punctuation), or 0: Rainwire's module's link_len.
    private static func linkLen(_ word: [Character]) -> Int {
        let lower = String(word).lowercased()
        let skip = lower.hasPrefix("https://") ? 8 : lower.hasPrefix("http://") ? 7 : lower.hasPrefix("www.") ? 4 : 0
        guard skip > 0 else { return 0 }
        var n = word.count
        while n > skip && ".,;:!?)]}'\"".contains(word[n - 1]) {
            n -= 1
        }
        return n - skip >= 3 ? n : 0
    }

    /// The news link at p (drawn last), or nil.
    private func linkAt(_ p: CGPoint) -> String? {
        links.first { $0.rect.contains(p) }?.url
    }

    /// Opens a clicked news link in the browser (www. as http://), when it's a web address the app would open from a
    /// TRACE module's OpenUrl (http or https with a host, at most 2048 bytes). No message to the board.
    func openLink(_ address: String) {
        let text = address.lowercased().hasPrefix("www.") ? "http://" + address : address
        guard TraceSessionManager.isWebUrl(text), let url = URL(string: text) else { return }
        NSWorkspace.shared.open(url)
    }

    /// The news from y (already scrolled), x across w: the newest item with its date over a larger title, then the
    /// "Earlier" rule and the older ones, their dates in a column; returns the y under the last item.
    private func newsBody(_ x: CGFloat, _ w: CGFloat, _ y0: CGFloat, _ draw: Bool) -> CGFloat {
        let bf = font(true, 13), uf = font(false, 13), tf = font(true, 17)
        var y = y0
        var dateW: CGFloat = 0   // the older items' date column: as wide as their widest date
        for it in news.dropFirst() where !it.date.isEmpty {
            dateW = max(dateW, Self.textW(it.date, bf) + 18 * u)
        }
        if dateW > w * 0.3 {
            dateW = 0   // too narrow: dates go over their titles
        }
        for (i, it) in news.enumerated() {
            if i == 0 {
                if !it.date.isEmpty {
                    if draw && y + 20 * u >= vTop && y <= vBot {
                        Self.text(it.date, bf, nc(.latestDate)).draw(at: CGPoint(x: x, y: y))
                    }
                    y += Self.fontLine(bf) + 4 * u
                }
                flow(tf, it.title, x, w, &y, nc(.latestHead), draw)
                y += 2 * u
                flow(uf, it.text, x, w, &y, nc(.latestText), draw)
                continue
            }
            if i == 1 {   // the rule over the older ones, "Earlier" on it
                y += 14 * u
                let lh = Self.fontLine(bf)
                if draw && y + lh >= vTop && y <= vBot {
                    let tw = earlier.isEmpty ? 0 : Self.textW(earlier, bf) + 16 * u
                    if tw > 0 {
                        Self.text(earlier, bf, nc(.title)).draw(at: CGPoint(x: x, y: y))
                    }
                    Self.color(nc(.rule), 200.0 / 255).setFill()
                    CGRect(x: x + tw, y: y + lh / 2, width: max(w - tw, 0), height: max(1, u)).fill(using: .sourceOver)
                }
                y += lh + 12 * u
            } else {
                y += 12 * u
            }
            if !it.date.isEmpty {
                if draw && y + 20 * u >= vTop && y <= vBot {
                    Self.text(it.date, bf, nc(.date)).draw(at: CGPoint(x: x, y: Self.capY(bf, y + lineH(bf) / 2)))
                }
                if dateW == 0 {
                    y += Self.fontLine(bf) + 2 * u
                }
            }
            flow(bf, it.title, x + dateW, w - dateW, &y, nc(.head), draw)
            flow(uf, it.text, x + dateW, w - dateW, &y, nc(.text), draw)
        }
        return y
    }

    /// One row of the stats bar, centered on cx: values bold and bright, labels in the accent, a square between parts.
    private func newsStatsRow(_ row: [NewsStat], _ cx: CGFloat, _ y: CGFloat) {
        let bf = font(true, 13), uf = font(false, 13)
        let gap = 26 * u, rowH = 24 * u
        var parts: [[(String, NSFont, UInt32)]] = []
        for st in row {
            let value = (st.value, bf, nc(.statValue)), label = (st.label, uf, nc(.statLabel))
            parts.append((st.labelFirst ? [label, value] : [value, label]).filter { !$0.0.isEmpty })
        }
        func width(_ p: [(String, NSFont, UInt32)]) -> CGFloat {
            p.reduce(CGFloat(0)) { $0 + Self.textW($1.0, $1.1) } + CGFloat(max(p.count - 1, 0)) * 5 * u
        }
        let total = parts.reduce(CGFloat(0)) { $0 + width($1) } + CGFloat(max(parts.count - 1, 0)) * gap
        var x = cx - total / 2
        for (k, p) in parts.enumerated() {
            if k > 0 {
                Self.color(nc(.border)).setFill()
                CGRect(x: x + gap / 2 - 2.5 * u, y: y + rowH / 2 - 2.5 * u, width: 5 * u, height: 5 * u).fill()
                x += gap
            }
            for (n, (str, f, c)) in p.enumerated() {
                if n > 0 {
                    x += 5 * u
                }
                Self.text(str, f, c).draw(at: CGPoint(x: x, y: Self.capY(f, y + rowH / 2)))
                x += Self.textW(str, f)
            }
        }
    }

    /// The Updates & News screen where the menu box goes: one panel under the header (its title on the top border,
    /// the foot on the bottom one), the news inside scrolled smoothly, a thin bar on the right when it doesn't all
    /// fit, the text fading into the panel at an edge with more beyond it; the stats bar in a strip of its own under it.
    private func drawNews(_ w: CGFloat, _ h: CGFloat, _ hdrBottom: CGFloat) {
        let statsH = stats.isEmpty ? 0 : CGFloat(stats.count) * 24 * u + 10 * u
        let x = 14 * u, pw = w - 28 * u
        var y = hdrBottom + 14 * u
        let bottom = h - statusH * u - 8 * u - statsH - (statsH > 0 ? 8 * u : 0)   // status: off gives the room
        if bottom - y < 80 * u {   // a tall header: the panel still gets room
            y = max(bottom - 80 * u, 14 * u)
        }
        let ph = max(bottom - y, 1)
        let panelRect = CGRect(x: x, y: y, width: pw, height: ph)
        panel(panelRect, nc(.panelBg), nc(.border), radiusScale: 8.0 / 6)   // the sysop's box style; 8 at the default 6
        // the inside, scrolled
        let ix = x + 24 * u, iw = max(pw - 58 * u, 1), iy = y + 22 * u, ih = max(ph - 40 * u, 1)
        vTop = iy
        vBot = iy + ih
        viewH = ih
        let content = newsBody(ix, iw, 0, false)
        scrollMax = max(content - ih, 0)
        scrollTo = min(max(scrollTo, 0), scrollMax)
        scroll += (scrollTo - scroll) * 0.35
        if abs(scrollTo - scroll) < 0.5 {
            scroll = scrollTo
        }
        let inside = CGRect(x: x + 2 * u, y: iy - 6 * u, width: pw - 4 * u, height: ih + 12 * u)
        NSGraphicsContext.saveGraphicsState()
        inside.clip()
        links.removeAll()
        _ = newsBody(ix, iw, iy - scroll, true)
        let bg = nc(.panelBg)
        if scroll < scrollMax - 1 {   // more below: the text fades into the panel
            NSGradient(starting: Self.color(bg, 0), ending: Self.color(bg, 240.0 / 255))?
                .draw(from: CGPoint(x: 0, y: inside.maxY - 32 * u), to: CGPoint(x: 0, y: inside.maxY), options: [])
        }
        if scroll > 1 {
            NSGradient(starting: Self.color(bg, 240.0 / 255), ending: Self.color(bg, 0))?
                .draw(from: CGPoint(x: 0, y: inside.minY), to: CGPoint(x: 0, y: inside.minY + 16 * u), options: [])
        }
        NSGraphicsContext.restoreGraphicsState()
        if scrollMax > 0 {
            let th = min(max(ih * ih / (ih + scrollMax), 24 * u), ih)
            let ty = iy + (ih - th) * (scroll / scrollMax)
            let bx = x + pw - 16 * u
            Self.color(nc(.border), 50.0 / 255).setFill()
            NSBezierPath(roundedRect: CGRect(x: bx, y: iy, width: 4 * u, height: ih), xRadius: 2 * u, yRadius: 2 * u).fill()
            Self.color(nc(.border), 220.0 / 255).setFill()
            NSBezierPath(roundedRect: CGRect(x: bx, y: ty, width: 4 * u, height: th), xRadius: 2 * u, yRadius: 2 * u).fill()
        }
        if !head.title.isEmpty {   // the title on the top border, the border cut under it
            let f = font(true, 17)
            let t = Self.text(head.title, f, nc(.title))
            let tx = x + 20 * u
            Self.color(bg).setFill()
            CGRect(x: tx - 8 * u, y: y - 2 * u, width: t.size().width + 16 * u, height: 4 * u).fill()
            t.draw(at: CGPoint(x: tx, y: Self.capY(f, y)))
        }
        if !foot.isEmpty {   // "Enter continues" on the bottom border, right
            let f = font(false, 13)
            let t = Self.text(foot, f, nc(.foot))
            let tw = t.size().width
            let tx = x + pw - tw - 22 * u
            Self.color(bg).setFill()
            CGRect(x: tx - 6 * u, y: y + ph - 2 * u, width: tw + 12 * u, height: 4 * u).fill()
            t.draw(at: CGPoint(x: tx, y: Self.capY(f, y + ph)))
        }
        let fade = fadeIn()
        if fade < 1 {
            Self.color(bg, 1 - fade).setFill()
            panelRect.fill(using: .sourceOver)
        }
        if statsH > 0 {   // the stats bar: a strip of its own under the panel
            let strip = CGRect(x: x, y: bottom + 8 * u, width: pw, height: statsH)
            panel(strip, bg, nc(.border), borderAlpha: 120.0 / 255, shadow: false, radiusScale: 8.0 / 6)
            for (k, row) in stats.enumerated() {
                newsStatsRow(row, x + pw / 2, strip.minY + 5 * u + CGFloat(k) * 24 * u)
            }
        }
    }

    // ---- pages and lists (menumod.c screen_panel, draw_page, draw_list: the module's look, in points) ----

    private func pc(_ i: Pc) -> UInt32 { pageColors[i.rawValue] }
    private func lc(_ i: Lc) -> UInt32 { listColors[i.rawValue] }

    private func monoFont() -> NSFont { NSFont.monospacedSystemFont(ofSize: 12 * u, weight: .regular) }

    /// A page's line: the mono font's line box and 3.
    private func pageLineH() -> CGFloat { Self.fontLine(monoFont()) + 3 * u }

    /// s cut with an ellipsis to maxW.
    static func fitText(_ s: String, _ f: NSFont, _ maxW: CGFloat) -> String {
        guard textW(s, f) > maxW else { return s }
        var t = s
        while !t.isEmpty && textW(t + "\u{2026}", f) > maxW {
            t.removeLast()
        }
        return t + "\u{2026}"
    }

    /// One line of spans from x in a row y..y+h, cut at w: each span in its color (none: def) and background, pulse,
    /// shimmer, blink, as menu labels.
    func drawSpans(_ f: NSFont, _ spans: [Span], _ x0: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
                           _ def: UInt32, _ under: UInt32) {
        let ty = Self.capY(f, y + h / 2)
        let now = nowMs
        NSGraphicsContext.saveGraphicsState()
        CGRect(x: x0, y: y, width: max(w, 0), height: h).clip()
        var x = x0
        for s in spans {
            if x >= x0 + w {
                break
            }
            var fg = s.fg != Self.none ? s.fg & 0xFF_FFFF : def
            let sw = Self.textW(s.text, f)
            if s.bg != Self.none && !(s.fx == Self.fxBlink && Int(now / 500) % 2 == 1) {
                Self.color(s.bg & 0xFF_FFFF).setFill()
                CGRect(x: x, y: y + 1 * u, width: sw, height: max(h - 2 * u, 1)).fill()
            }
            if s.fx == Self.fxPulse {
                let t = 0.5 + 0.5 * sin(now / 1000 * 3.6)
                fg = Self.mix(Self.mix(fg, under, 0.5), fg, CGFloat(t))
            }
            if s.fx == Self.fxShimmer {
                let pos = CGFloat(now / 1400).truncatingRemainder(dividingBy: 1.8) * (sw + 60 * u) - 30 * u
                var cx = x
                for ch in s.text {
                    let str = String(ch)
                    let cw = Self.textW(str, f)
                    let glint = 1 - min(max(abs(cx + cw / 2 - x - pos) / (24 * u), 0), 1)
                    Self.text(str, f, Self.mix(fg, 0xFF_FFFF, glint * 0.85)).draw(at: CGPoint(x: cx, y: ty))
                    cx += cw
                }
            } else {
                Self.text(s.text, f, fg).draw(at: CGPoint(x: x, y: ty))
            }
            x += sw
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The panel a page or a list goes in, under the header, down to above the status bar (the style's radius x 8/6,
    /// border, opacity, shadow), the title on its top border, "Esc Back" on its bottom border right, a list's edge
    /// keys left of it and its footer left. Returns the panel and its inside.
    private func screenPanel(_ w: CGFloat, _ h: CGFloat, _ hdrBottom: CGFloat, _ bg: UInt32, _ border: UInt32,
                             _ title: UInt32, _ foot: UInt32, edge: String = "", footer: String = "")
        -> (panel: CGRect, inside: CGRect) {
        let big = isList && lFlags & Self.lfBig != 0
        let x = (big ? 8 : 14) * u, pw = w - 2 * x
        var y = hdrBottom + 14 * u
        let bottom = h - statusH * u - 8 * u
        if bottom - y < 80 * u {   // a tall header: the panel still gets room
            y = max(bottom - 80 * u, 14 * u)
        }
        let ph = max(bottom - y, 1)
        let rect = CGRect(x: x, y: y, width: pw, height: ph)
        panel(rect, bg, border, radiusScale: 8.0 / 6)
        if !head.title.isEmpty && st.title != 2 {
            let f = font(true, 17)
            let t = Self.text(head.title, f, title)
            let tx = x + 20 * u
            borderCut(tx - 8 * u, y, t.size().width + 16 * u, bg)
            t.draw(at: CGPoint(x: tx, y: Self.capY(f, y)))
        }
        let f = font(false, 13)
        let by = Self.capY(f, y + ph)
        var rx = x + pw - 22 * u
        for text in ["Esc Back", edge] where !text.isEmpty {   // right to left: "Esc Back", then the edge keys
            let tw = Self.textW(text, f)
            borderCut(rx - tw - 6 * u, y + ph, tw + 12 * u, bg)
            Self.text(text, f, foot).draw(at: CGPoint(x: rx - tw, y: by))
            rx -= tw + 20 * u
        }
        if !footer.isEmpty {
            let tw = Self.textW(footer, f)
            borderCut(x + 14 * u, y + ph, tw + 12 * u, bg)
            Self.text(footer, f, foot).draw(at: CGPoint(x: x + 20 * u, y: by))
        }
        return (rect, CGRect(x: x + 22 * u, y: y + 20 * u, width: max(pw - 54 * u, 1), height: max(ph - 38 * u, 1)))
    }

    /// The scroll bar on the panel's right and the fade at the bottom, as the news.
    private func screenScrollbar(_ inside: CGRect, _ bg: UInt32, _ border: UInt32) {
        guard scrollMax > 0 else { return }
        if scroll < scrollMax - 1 {
            NSGraphicsContext.saveGraphicsState()
            CGRect(x: inside.minX - 8 * u, y: inside.maxY - 24 * u, width: inside.width + 16 * u, height: 24 * u).clip()
            NSGradient(starting: Self.color(bg, 0), ending: Self.color(bg, 240.0 / 255))?
                .draw(from: CGPoint(x: 0, y: inside.maxY - 24 * u), to: CGPoint(x: 0, y: inside.maxY), options: [])
            NSGraphicsContext.restoreGraphicsState()
        }
        let ih = inside.height
        let th = min(max(ih * ih / (ih + scrollMax), 24 * u), ih)
        let ty = inside.minY + (ih - th) * (scroll / scrollMax)
        let bx = inside.maxX + 12 * u
        Self.color(border, 50.0 / 255).setFill()
        NSBezierPath(roundedRect: CGRect(x: bx, y: inside.minY, width: 4 * u, height: ih), xRadius: 2 * u, yRadius: 2 * u).fill()
        Self.color(border, 220.0 / 255).setFill()
        NSBezierPath(roundedRect: CGRect(x: bx, y: ty, width: 4 * u, height: th), xRadius: 2 * u, yRadius: 2 * u).fill()
    }

    private func scrollEase() {
        scrollTo = min(max(scrollTo, 0), scrollMax)
        scroll += (scrollTo - scroll) * 0.35
        if abs(scrollTo - scroll) < 0.5 {
            scroll = scrollTo
        }
    }

    /// The panel's fade-in (box.fade), over everything in it.
    private func screenFade(_ rect: CGRect, _ bg: UInt32) {
        let fade = fadeIn()
        if fade < 1 {
            Self.color(bg, 1 - fade).setFill()
            rect.fill(using: .sourceOver)
        }
    }

    /// A page: its column headings and a rule, then its lines in the mono font (columns lined up with spaces stay
    /// lined up), scrolled smoothly.
    private func drawPage(_ w: CGFloat, _ h: CGFloat, _ hdrBottom: CGFloat) {
        let bg = pc(.panelBg)
        let (rect, box0) = screenPanel(w, h, hdrBottom, bg, pc(.border), pc(.title), pc(.foot))
        let mf = monoFont(), lh = pageLineH()
        var inside = box0
        if !pageHdr.isEmpty {
            drawSpans(mf, pageHdr, inside.minX, inside.minY, inside.width, lh, pc(.header), bg)
            Self.color(pc(.rule), 200.0 / 255).setFill()
            CGRect(x: inside.minX, y: inside.minY + lh + 2 * u, width: inside.width, height: max(1, u)).fill(using: .sourceOver)
            inside = CGRect(x: inside.minX, y: inside.minY + lh + 8 * u, width: inside.width,
                            height: max(inside.height - lh - 8 * u, 1))
        }
        viewH = inside.height
        scrollMax = max(CGFloat(pageLines.count) * lh - inside.height, 0)
        scrollEase()
        NSGraphicsContext.saveGraphicsState()
        inside.insetBy(dx: -4 * u, dy: 0).clip()
        var i = max(Int(scroll / lh), 0)
        while i < pageLines.count {
            let y = inside.minY + CGFloat(i) * lh - scroll
            if y > inside.maxY {
                break
            }
            drawSpans(mf, pageLines[i], inside.minX, y, inside.width, lh, pc(.text), bg)
            i += 1
        }
        NSGraphicsContext.restoreGraphicsState()
        screenScrollbar(inside, bg, pc(.border))
        screenFade(rect, bg)
    }

    /// A row's height: a heading a bold line and 12; else rows.height, and its sub as a small second line.
    private func listRowH(_ r: ListRow) -> CGFloat {
        if r.flags & Self.liHeading != 0 {
            return Self.fontLine(font(true, 13)) + 12 * u
        }
        var h = st.height * u
        if lFlags & Self.lfSubBelow == 0 && !r.sub.isEmpty {
            h += Self.fontLine(font(false, 11)) + 2 * u
        }
        return h
    }

    /// The columns' left edges and widths across the inside: a column's width is its text cells, the ones of width 0
    /// share what's left; all shrunk together when they don't fit.
    private func listCols(_ ix: CGFloat, _ iw: CGFloat) -> [(x: CGFloat, w: CGFloat)] {
        let cell = Self.textW("0", font(false, 13)) + 0.5 * u, markW = 14 * u
        var fixed: CGFloat = 0
        var flex = 0
        for wd in colW {
            if wd > 0 {
                fixed += CGFloat(wd) * cell + 12 * u
            } else {
                flex += 1
            }
        }
        let room = iw - markW
        var scale: CGFloat = 1
        if fixed > room - CGFloat(flex) * 60 * u {
            scale = (room - CGFloat(flex) * 60 * u) / max(fixed, 1)
        }
        scale = max(scale, 0.3)
        let rest = room - fixed * scale
        var x = ix + markW
        var out: [(x: CGFloat, w: CGFloat)] = []
        for wd in colW {
            var cw = wd > 0 ? CGFloat(wd) * cell * scale + 12 * u * scale : (flex > 0 ? rest / CGFloat(flex) : 0)
            cw = max(cw, 20 * u)
            out.append((x: x, w: cw))
            x += cw
        }
        return out
    }

    /// A list: the column titles and a rule; the rows (bold bright, dim dim, headings in accent2 and never selected,
    /// the mark left of the first column, indent 14 a step, the sub as a small second line or the selected row's at
    /// the bottom), the selection in the style's shape and the menu's sel.* colors; the keys line at the bottom.
    private func drawList(_ w: CGFloat, _ h: CGFloat, _ hdrBottom: CGFloat) {
        let bg = lc(.panelBg)
        let (rect, box0) = screenPanel(w, h, hdrBottom, bg, lc(.border), lc(.title), lc(.foot), edge: lEdge, footer: lFooter)
        var inside = box0
        let ix = inside.minX, iw = inside.width
        let cols = listCols(ix, iw)
        let bf = font(true, 13), uf = font(false, 13), sf = font(false, 11)
        rowHits.removeAll()
        if colT.contains(where: { !$0.isEmpty }) {   // the column titles and a rule
            let hh = Self.fontLine(bf) + 6 * u
            for (c, t) in colT.enumerated() where c < cols.count && !t.isEmpty {
                Self.text(Self.fitText(t, bf, cols[c].w - 8 * u), bf, lc(.accent))
                    .draw(at: CGPoint(x: cols[c].x + 4 * u, y: Self.capY(bf, inside.minY + hh / 2)))
            }
            Self.color(lc(.border), 160.0 / 255).setFill()
            CGRect(x: ix, y: inside.minY + hh + 1 * u, width: iw, height: max(1, u)).fill(using: .sourceOver)
            inside = CGRect(x: ix, y: inside.minY + hh + 6 * u, width: iw, height: max(inside.height - hh - 6 * u, 1))
        }
        // the bottom: the selected row's sub (sub below) and the screen's keys, under a rule
        let sub = lFlags & Self.lfSubBelow != 0 && rowOK(lSel) ? rows[lSel].sub : ""
        let foot = (sub.isEmpty ? 0 : Self.fontLine(uf) + 6 * u) + (lKeys.isEmpty ? 0 : Self.fontLine(sf) + 6 * u)
        if foot > 0 {
            inside.size.height = max(inside.height - foot - 8 * u, 1)
            var fy = inside.maxY + 6 * u
            Self.color(lc(.border), 160.0 / 255).setFill()
            CGRect(x: ix, y: fy, width: iw, height: max(1, u)).fill(using: .sourceOver)
            fy += 5 * u
            if !sub.isEmpty {
                Self.text(Self.fitText(sub, uf, iw), uf, lc(.text)).draw(at: CGPoint(x: ix, y: fy))
                fy += Self.fontLine(uf) + 6 * u
            }
            if !lKeys.isEmpty {
                Self.text(Self.fitText(lKeys, sf, iw), sf, lc(.foot)).draw(at: CGPoint(x: ix, y: fy))
            }
        }
        viewH = inside.height
        if rows.isEmpty {
            if !lEmpty.isEmpty {
                let t = Self.text(lEmpty, uf, lc(.dim))
                t.draw(at: CGPoint(x: ix + (iw - t.size().width) / 2, y: inside.midY - 8 * u))
            }
            screenFade(rect, bg)
            return
        }
        var y: CGFloat = 0   // each row's place, from the top of the rows
        for i in rows.indices {
            rows[i].y = y
            rows[i].h = listRowH(rows[i])
            y += rows[i].h
        }
        scrollMax = max(y - inside.height, 0)
        if rowOK(lSel) {   // keep the selection in view
            let r = rows[lSel]
            if r.y < scrollTo {
                scrollTo = r.y
            }
            if r.y + r.h > scrollTo + inside.height {
                scrollTo = r.y + r.h - inside.height
            }
        }
        if listSnap {   // opened at its selection (Last callers: the newest row, at the bottom)
            listSnap = false
            scrollTo = min(max(scrollTo, 0), scrollMax)
            scroll = scrollTo
        }
        scrollEase()
        NSGraphicsContext.saveGraphicsState()
        inside.insetBy(dx: -10 * u, dy: 0).clip()
        let rh = st.height * u
        for (i, r) in rows.enumerated() {
            let ry = inside.minY + r.y - scroll
            if ry + r.h < inside.minY {
                continue
            }
            if ry > inside.maxY {
                break
            }
            if r.flags & Self.liHeading != 0 {
                var x = ix
                for col in r.cols {
                    drawSpans(bf, col, x, ry + 4 * u, iw - (x - ix), r.h - 4 * u, lc(.accent2), bg)
                    x += Self.textW(" ", bf) + col.reduce(CGFloat(0)) { $0 + Self.textW($1.text, bf) }
                }
                continue
            }
            let selected = i == lSel
            var under = bg
            var def = r.flags & Self.liDim != 0 ? lc(.dim) : r.flags & Self.liBold != 0 ? lc(.bright) : lc(.text)
            let bar = CGRect(x: ix - 6 * u, y: ry + 1 * u, width: iw + 12 * u, height: max(rh - 2 * u, 1))
            if selected {
                let a: CGFloat = waiting ? 170.0 / 255 : 1
                let sr = st.selRadius * u
                switch st.sel {
                case 1:   // outline
                    Self.color(mc(.selBg), a).setStroke()
                    let p = NSBezierPath(roundedRect: bar, xRadius: sr, yRadius: sr)
                    p.lineWidth = 1.5 * u
                    p.stroke()
                case 2:   // glow
                    Self.color(mc(.selBg), 55.0 / 255 * a).setFill()
                    NSBezierPath(roundedRect: bar.insetBy(dx: -3 * u, dy: -3 * u), xRadius: sr + 3 * u, yRadius: sr + 3 * u).fill()
                    Self.color(mc(.selBg), 150.0 / 255 * a).setFill()
                    NSBezierPath(roundedRect: bar, xRadius: sr, yRadius: sr).fill()
                    under = Self.mix(under, mc(.selBg), 150.0 / 255)
                case 3:   // underline
                    Self.color(mc(.selBg), a).setFill()
                    CGRect(x: ix, y: ry + rh - 3 * u, width: iw, height: 2 * u).fill()
                default:
                    if head.flags & Self.mfGradient != 0 {
                        NSGradient(starting: Self.color(mc(.selBg), a), ending: Self.color(mc(.selBg2), a))?.draw(in: bar, angle: 0)
                        under = Self.mix(mc(.selBg), mc(.selBg2), 0.5)
                    } else {
                        Self.color(mc(.selBg), a).setFill()
                        NSBezierPath(roundedRect: bar, xRadius: sr, yRadius: sr).fill()
                        under = mc(.selBg)
                    }
                }
                if st.marker && st.sel != 3 {
                    Self.color(mc(.selMarker)).setFill()
                    CGRect(x: bar.minX, y: bar.minY, width: 3 * u, height: bar.height).fill()
                }
                if st.sel == 0 || st.sel == 2 {
                    def = mc(.selFg)
                }
            }
            let f = r.flags & Self.liBold != 0 ? bf : uf
            if !r.mark.isEmpty {
                Self.text(r.mark, uf, selected ? def : lc(.mark)).draw(at: CGPoint(x: ix, y: Self.capY(uf, ry + rh / 2)))
            }
            for c in 0..<min(r.cols.count, cols.count) {
                let ind = c == 0 ? CGFloat(r.indent) * 14 * u : 0
                let cw = cols[c].w - 8 * u - ind
                if cw > 4 * u {
                    drawSpans(f, r.cols[c], cols[c].x + 4 * u + ind, ry, cw, rh, def, under)
                }
            }
            if lFlags & Self.lfSubBelow == 0 && !r.sub.isEmpty, let c0 = cols.first {
                let sx = c0.x + 4 * u + CGFloat(r.indent) * 14 * u
                Self.text(Self.fitText(r.sub, sf, iw - 30 * u), sf, selected ? def : lc(.dim))
                    .draw(at: CGPoint(x: sx, y: ry + rh - 2 * u))
            }
            rowHits.append((rect: CGRect(x: ix - 6 * u, y: ry, width: iw + 12 * u, height: r.h), row: i))
        }
        NSGraphicsContext.restoreGraphicsState()
        screenScrollbar(inside, bg, lc(.border))
        screenFade(rect, bg)
    }

    // ---- picture screens and charts (menumod.c draw_picture, draw_chart: the module's look, in points) ----

    private func xc(_ i: Xc) -> UInt32 { picColors[i.rawValue] }

    private func over(_ r: CGRect) -> Bool { pointer.map { r.contains($0) } ?? false }

    private func fillRR(_ r: CGRect, _ radius: CGFloat, _ c: UInt32, _ a: CGFloat = 1) {
        Self.color(c, a).setFill()
        NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
    }

    private func strokeRR(_ r: CGRect, _ radius: CGFloat, _ width: CGFloat, _ c: UInt32, _ a: CGFloat = 1) {
        Self.color(c, a).setStroke()
        let p = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
        p.lineWidth = width
        p.stroke()
    }

    /// The axis's top: v rounded up to 1, 2, 2.5, 5 or 10 times a power of ten.
    private static func nicef(_ v: CGFloat) -> CGFloat {
        guard v > 0 else { return 1 }
        let e = pow(10, floor(log10(v))), m = v / e
        return (m <= 1 ? 1 : m <= 2 ? 2 : m <= 2.5 ? 2.5 : m <= 5 ? 5 : 10) * e
    }

    /// A number as the axis and the tooltips show it: whole numbers plain, big ones in thousands.
    private static func numstr(_ v: CGFloat) -> String {
        let a = abs(v)
        if a >= 100000 { return String(format: "%.0fk", Double(v / 1000)) }
        if a >= 10000 { return String(format: "%.1fk", Double(v / 1000)) }
        if v == v.rounded(.down) { return String(format: "%.0f", Double(v)) }
        return String(format: "%.1f", Double(v))
    }

    private func chVal(_ s: Int, _ i: Int) -> CGFloat {
        s < chart.series.count && i < chart.series[s].v.count ? chart.series[s].v[i] : 0
    }

    private func chTotal(_ i: Int) -> CGFloat { (0..<chart.series.count).reduce(CGFloat(0)) { $0 + chVal($1, i) } }

    private func textC(_ s: String, _ f: NSFont, _ cx: CGFloat, _ y: CGFloat, _ c: UInt32) {
        let t = Self.text(s, f, c)
        t.draw(at: CGPoint(x: cx - t.size().width / 2, y: y))
    }

    /// The tooltip: lines in a small box by the pointer (a color square before a series' line), kept in the window.
    private func tooltip(_ lines: [(String, UInt32?)]) {
        guard let p = pointer, !lines.isEmpty else { return }
        let sf = font(false, 11), lh = Self.fontLine(sf) + 3 * u
        var w: CGFloat = 0
        for (t, c) in lines {
            w = max(w, Self.textW(t, sf) + (c != nil ? 14 * u : 0))
        }
        var bx = p.x + 14 * u, by = p.y + 10 * u
        let bw = w + 16 * u, bh = CGFloat(lines.count) * lh + 10 * u
        if bx + bw > bounds.width - 4 * u { bx = p.x - bw - 10 * u }
        if by + bh > bounds.height - 4 * u { by = p.y - bh - 6 * u }
        let box = CGRect(x: bx, y: by, width: bw, height: bh)
        fillRR(box.offsetBy(dx: 2 * u, dy: 3 * u), 6 * u, 0, 90.0 / 255)
        fillRR(box, 6 * u, Self.mix(xc(.panelBg), 0, 60.0 / 255), 245.0 / 255)
        strokeRR(box, 6 * u, 1 * u, xc(.border))
        for (i, (t, c)) in lines.enumerated() {
            var tx = bx + 8 * u
            let ty = by + 5 * u + CGFloat(i) * lh
            if let c = c {
                fillRR(CGRect(x: tx, y: ty + lh / 2 - 5 * u, width: 8 * u, height: 8 * u), 2 * u, c)
                tx += 14 * u
            }
            Self.text(t, sf, i == 0 ? xc(.accent) : xc(.text)).draw(at: CGPoint(x: tx, y: ty))
        }
    }

    /// Bars, stacked bars and the line: a y axis to a nice number with four gridlines and their numbers, the x labels
    /// under (as many as fit), a legend for more than one series; the slot under the pointer lit, with a tooltip.
    private func chartVertical(_ area: CGRect) {
        let n = chart.labels.count
        guard n > 0 else { return }
        let stacked = chart.kind == Self.ckStacked, line = chart.kind == Self.ckLine
        let sf = font(false, 11), uf = font(false, 13)
        var top = chart.max
        if top <= 0 {
            for i in 0..<n {
                var v: CGFloat = stacked ? chTotal(i) : 0
                if !stacked {
                    for s in chart.series.indices { v = max(v, chVal(s, i)) }
                }
                top = max(top, v)
            }
        }
        top = Self.nicef(top)
        let aw = Self.textW(Self.numstr(top), sf) + 10 * u, lh = Self.fontLine(sf) + 6 * u
        let leg = chart.series.count > 1 ? Self.fontLine(uf) + 10 * u : 0
        let px = area.minX + aw, pw = area.width - aw, py = area.minY + 6 * u, ph = area.height - lh - 6 * u - leg
        guard pw >= 20 * u, ph >= 20 * u else { return }
        for k in 0...4 {   // gridlines and their numbers
            let gy = py + ph - ph * CGFloat(k) / 4
            Self.color(xc(.grid), k == 0 ? 160.0 / 255 : 50.0 / 255).setFill()
            CGRect(x: px, y: gy, width: pw, height: max(1, u)).fill(using: .sourceOver)
            let t = Self.text(Self.numstr(top * CGFloat(k) / 4), sf, xc(.accent))
            t.draw(at: CGPoint(x: px - 6 * u - t.size().width, y: gy - Self.fontLine(sf) / 2))
        }
        let slot = pw / CGFloat(n), bw = max(slot * 0.72, 1)
        var hov = -1
        if let p = pointer, CGRect(x: px, y: py, width: pw, height: ph + lh).contains(p) {
            hov = min(max(Int((p.x - px) / slot), 0), n - 1)
        }
        if hov >= 0 {
            Self.color(xc(.text), 18.0 / 255).setFill()
            CGRect(x: px + CGFloat(hov) * slot, y: py, width: slot, height: ph).fill(using: .sourceOver)
        }
        if line {   // each series a line with the area under it filled
            for s in chart.series.indices {
                let c = chart.series[s].color
                let path = NSBezierPath()
                path.lineWidth = 2.2 * u
                path.lineJoinStyle = .round
                for i in 0..<n {
                    let cx = px + slot * (CGFloat(i) + 0.5), cy = py + ph - ph * min(max(chVal(s, i) / top, 0), 1)
                    Self.color(c, 40.0 / 255).setFill()
                    CGRect(x: cx - slot / 2, y: cy, width: slot, height: py + ph - cy).fill(using: .sourceOver)
                    if i == 0 { path.move(to: CGPoint(x: cx, y: cy)) } else { path.line(to: CGPoint(x: cx, y: cy)) }
                }
                Self.color(c).setStroke()
                path.stroke()
                for i in 0..<n where slot >= 10 * u || i == hov {
                    let cx = px + slot * (CGFloat(i) + 0.5), cy = py + ph - ph * min(max(chVal(s, i) / top, 0), 1)
                    let r = (i == hov ? 4.5 : 2.5) * u
                    Self.color(c).setFill()
                    NSBezierPath(ovalIn: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r)).fill()
                }
            }
        } else {
            for i in 0..<n {
                let bx = px + slot * CGFloat(i) + (slot - bw) / 2
                var base = py + ph
                let a: CGFloat = i == hov ? 1 : 220.0 / 255
                for s in chart.series.indices {
                    let v = chVal(s, i), bh = ph * min(max(v / top, 0), 1)
                    if !stacked && chart.series.count > 1 {   // side by side
                        let sw = bw / CGFloat(chart.series.count)
                        fillRR(CGRect(x: bx + CGFloat(s) * sw, y: base - bh, width: max(sw - 1 * u, 0.5), height: bh),
                               sw > 6 * u ? 2 * u : 0, chart.series[s].color, a)
                        continue
                    }
                    if bh <= 0 { continue }
                    var topmost = true
                    if stacked {
                        for s2 in (s + 1)..<max(chart.series.count, s + 1) where chVal(s2, i) > 0 { topmost = false }
                    }
                    let bar = CGRect(x: bx, y: base - bh, width: bw, height: bh)
                    if topmost && bw > 6 * u {
                        fillRR(bar, min(3 * u, bh / 2), chart.series[s].color, a)
                    } else {
                        Self.color(chart.series[s].color, a).setFill()
                        bar.fill(using: .sourceOver)
                    }
                    if stacked { base -= bh }
                }
            }
        }
        // the x labels: every few, as many as fit without touching
        let lw = chart.labels.map { Self.textW($0, sf) }.max() ?? 0
        var every = max(chart.every, 1)
        while every < n && slot * CGFloat(every) < lw + 8 * u { every += 1 }
        for i in stride(from: 0, to: n, by: every) {
            textC(chart.labels[i], sf, px + slot * (CGFloat(i) + 0.5), py + ph + 4 * u, xc(.dim))
        }
        if leg > 0 {   // each series' color and name, centered
            let tw = chart.series.reduce(CGFloat(0)) { $0 + Self.textW($1.name, uf) + 34 * u }
            var lx = px + (pw - tw) / 2
            let ly = py + ph + lh + 6 * u
            for sr in chart.series {
                fillRR(CGRect(x: lx, y: ly + Self.fontLine(uf) / 2 - 5 * u, width: 10 * u, height: 10 * u), 2 * u, sr.color)
                Self.text(sr.name, uf, xc(.text)).draw(at: CGPoint(x: lx + 16 * u, y: ly))
                lx += 16 * u + Self.textW(sr.name, uf) + 18 * u
            }
        }
        if hov >= 0 {
            var ls: [(String, UInt32?)] = [(chart.labels[hov], nil)]
            for sr in chart.series.prefix(8) {
                let v = sr.v.indices.contains(hov) ? sr.v[hov] : 0
                ls.append(("\(sr.name)\(sr.name.isEmpty ? "" : ": ")\(Self.numstr(v)) \(chart.unit)", sr.color))
            }
            if stacked && chart.series.count > 1 {
                ls.append(("\(Self.numstr(chTotal(hov))) \(chart.unit)", nil))
            }
            tooltip(ls)
        }
    }

    /// Horizontal bars: a label each, a track and the bar, its number and its share of the total.
    private func chartHbars(_ area: CGRect) {
        let n = chart.labels.count
        guard n > 0 else { return }
        let uf = font(false, 13)
        var top = chart.max, total: CGFloat = 0, lw: CGFloat = 0
        for i in 0..<n {
            let v = chVal(0, i)
            total += v
            if chart.max <= 0 { top = max(top, v) }
            lw = max(lw, Self.textW(chart.labels[i], uf))
        }
        if top <= 0 { top = 1 }
        lw = min(max(lw + 12 * u, 60 * u), area.width * 0.35)
        let rh = min(max(area.height / CGFloat(n), 16 * u), 30 * u), nw = Self.textW("000000 100%", uf) + 12 * u
        let bx = area.minX + lw, bwMax = area.width - lw - nw
        let c = chart.series.first?.color ?? xc(.accent)
        for i in 0..<n {
            let ry = area.minY + CGFloat(i) * rh
            if ry + rh > area.maxY + 1 { break }
            let row = CGRect(x: area.minX, y: ry, width: area.width, height: rh)
            let on = over(row)
            if on {
                Self.color(xc(.text), 16.0 / 255).setFill()
                row.insetBy(dx: -4 * u, dy: 0).fill(using: .sourceOver)
            }
            Self.text(Self.fitText(chart.labels[i], uf, lw - 12 * u), uf, xc(.text))
                .draw(at: CGPoint(x: area.minX, y: Self.capY(uf, ry + rh / 2)))
            let v = chVal(0, i), bwid = bwMax * min(max(v / top, 0), 1)
            fillRR(CGRect(x: bx, y: ry + rh * 0.2, width: max(bwMax, 0), height: rh * 0.6), rh * 0.3, xc(.grid), 40.0 / 255)
            if bwid > 0 {
                fillRR(CGRect(x: bx, y: ry + rh * 0.2, width: max(bwid, rh * 0.6), height: rh * 0.6), rh * 0.3, c,
                       on ? 1 : 225.0 / 255)
            }
            let t = "\(Self.numstr(v))  \(String(format: "%.0f", Double(total > 0 ? 100 * v / total : 0)))%"
            let tx = bx + bwid + 8 * u < bx + bwMax ? bx + bwid + 8 * u : bx + bwMax + 8 * u
            Self.text(t, uf, on ? xc(.accent) : xc(.dim)).draw(at: CGPoint(x: tx, y: Self.capY(uf, ry + rh / 2)))
        }
    }

    /// A heat map: rows by columns, each cell from a dim panel shade to the accent by its value; a tooltip.
    private func chartHeat(_ area: CGRect) {
        let rows = chart.rowL.count, cols = chart.colL.count
        guard rows > 0, cols > 0, chart.heat.count >= rows * cols else { return }
        let sf = font(false, 11)
        var top = chart.max
        if top <= 0 { top = chart.heat.max() ?? 0 }
        if top <= 0 { top = 1 }
        let lw = (chart.rowL.map { Self.textW($0, sf) }.max() ?? 0) + 10 * u
        let lh = Self.fontLine(sf) + 6 * u, cw = (area.width - lw) / CGFloat(cols)
        let rh = min(max((area.height - lh) / CGFloat(rows), 10 * u), 34 * u)
        let hot = xc(.accent), cold = Self.mix(xc(.panelBg), xc(.grid), 50.0 / 255)
        let labw = chart.colL.map { Self.textW($0, sf) }.max() ?? 0
        var every = 1
        while every < cols && cw * CGFloat(every) < labw + 6 * u { every += 1 }
        for c in stride(from: 0, to: cols, by: every) {
            textC(chart.colL[c], sf, area.minX + lw + cw * (CGFloat(c) + 0.5), area.minY, xc(.dim))
        }
        var hr = -1, hc = -1
        for r in 0..<rows {
            let ry = area.minY + lh + CGFloat(r) * rh
            Self.text(chart.rowL[r], sf, xc(.dim)).draw(at: CGPoint(x: area.minX, y: Self.capY(sf, ry + rh / 2)))
            for c in 0..<cols {
                let v = chart.heat[r * cols + c], f = min(max(v / top, 0), 1)
                let cell = CGRect(x: area.minX + lw + CGFloat(c) * cw, y: ry, width: cw, height: rh)
                let inner = cell.insetBy(dx: 1 * u, dy: 1 * u)
                let rad: CGFloat = cw > 10 * u && rh > 10 * u ? 3 * u : 0
                fillRR(inner, rad, Self.mix(cold, hot, f > 0 ? 0.15 + 0.85 * f : 0))
                if over(cell) {
                    hr = r
                    hc = c
                    strokeRR(inner, 3 * u, 1.5 * u, xc(.text))
                }
            }
        }
        if hr >= 0 {
            tooltip([("\(chart.rowL[hr]) \(chart.colL[hc])", nil), ("\(Self.numstr(chart.heat[hr * cols + hc])) \(chart.unit)", nil)])
        }
    }

    /// Parts of a whole as one bar, a legend under it with values and percents.
    private func chartShare(_ area: CGRect) {
        let multi = chart.series.count > 1
        let n = multi ? chart.series.count : chart.labels.count
        let vals: [CGFloat] = (0..<n).map { multi ? chVal($0, 0) : chVal(0, $0) }
        let total = vals.reduce(0, +)
        guard total > 0 else { return }
        let uf = font(false, 13), bh = 30 * u
        let palette: [UInt32] = [0x55_FFFF, 0xFF_55FF, 0xFF_FF55, 0x55_FF55, 0x55_55FF, 0xFF_5555, 0xFF_FFFF, 0xAA_AAAA]
        var cx = area.minX
        for i in 0..<n {
            let v = vals[i], pw = area.width * v / total
            let c = multi ? chart.series[i].color : (i < palette.count ? palette[i] : 0xAA_AAAA)
            if pw > 0.5 {
                Self.color(c, 230.0 / 255).setFill()
                CGRect(x: cx, y: area.minY, width: pw, height: bh).fill(using: .sourceOver)
            }
            let ly = area.minY + bh + 12 * u + CGFloat(i / 3) * (Self.fontLine(uf) + 8 * u)
            let lx = area.minX + CGFloat(i % 3) * (area.width / 3)
            fillRR(CGRect(x: lx, y: ly + 3 * u, width: 10 * u, height: 10 * u), 2 * u, c)
            let name = multi ? chart.series[i].name : (i < chart.labels.count ? chart.labels[i] : "")
            let t = "\(name)  \(Self.numstr(v))  \(String(format: "%.0f", Double(100 * v / total)))%"
            Self.text(t, uf, xc(.text)).draw(at: CGPoint(x: lx + 16 * u, y: ly))
            cx += pw
        }
        strokeRR(CGRect(x: area.minX, y: area.minY, width: area.width, height: bh), 4 * u, 1 * u, xc(.border), 200.0 / 255)
    }

    private func drawChart(_ area: CGRect) {
        switch chart.kind {
        case Self.ckHbars: chartHbars(area)
        case Self.ckHeat: chartHeat(area)
        case Self.ckShare: chartShare(area)
        case Self.ckGauge:   // a bar of value out of max, its caption beside it
            let gw = area.width * 0.6, gh = 22 * u
            let f = chart.max > 0 ? min(max(chart.value / chart.max, 0), 1) : 0
            let c = chart.series.first?.color ?? xc(.accent)
            fillRR(CGRect(x: area.minX, y: area.minY, width: gw, height: gh), gh / 2, xc(.grid), 50.0 / 255)
            if f > 0 {
                fillRR(CGRect(x: area.minX, y: area.minY, width: max(gw * f, gh), height: gh), gh / 2, c, 240.0 / 255)
            }
            if !chart.unit.isEmpty {
                let uf = font(false, 13)
                Self.text(chart.unit, uf, xc(.text)).draw(at: CGPoint(x: area.minX + gw + 14 * u, y: Self.capY(uf, area.minY + gh / 2)))
            }
        case Self.ckSpark:   // a small filled line
            let n = chart.labels.count
            guard n >= 2, !chart.series.isEmpty else { return }
            let sh = min(max(area.height, 20 * u), 60 * u)
            let top = Self.nicef((0..<n).map { chVal(0, $0) }.max() ?? 0)
            let c = chart.series[0].color, step = area.width / CGFloat(n - 1)
            let path = NSBezierPath()
            path.lineWidth = 2 * u
            for i in 0..<n {
                let cx = area.minX + step * CGFloat(i), cy = area.minY + sh - sh * min(max(chVal(0, i) / top, 0), 1)
                Self.color(c, 35.0 / 255).setFill()
                CGRect(x: cx - step / 2, y: cy, width: step, height: area.minY + sh - cy).fill(using: .sourceOver)
                if i == 0 { path.move(to: CGPoint(x: cx, y: cy)) } else { path.line(to: CGPoint(x: cx, y: cy)) }
            }
            Self.color(c).setStroke()
            path.stroke()
        default: chartVertical(area)
        }
    }

    /// A picture screen: the panel; the tabs as pills along the top (the current one lit, a click opens one); the
    /// lines above the chart and the notes under it in the mono font; the chart between.
    private func drawPicture(_ w: CGFloat, _ h: CGFloat, _ hdrBottom: CGFloat) {
        let bg = xc(.panelBg)
        let (rect, box0) = screenPanel(w, h, hdrBottom, bg, xc(.border), xc(.title), xc(.dim))
        var inside = box0
        let bf = font(true, 13), mf = monoFont(), plh = Self.fontLine(mf) + 4 * u
        tabHits.removeAll()
        if !tabs.isEmpty {
            var tx = inside.minX
            let th = 26 * u
            for (i, name) in tabs.enumerated() {
                let tw = Self.textW(name, bf) + 26 * u
                if tx + tw > inside.maxX { break }
                let pill = CGRect(x: tx, y: inside.minY, width: tw, height: th)
                if i == tab {
                    fillRR(pill, th / 2, xc(.tabBg))
                } else if over(pill) {
                    fillRR(pill, th / 2, xc(.tabBg), 70.0 / 255)
                } else {
                    strokeRR(pill, th / 2, 1 * u, xc(.border), 160.0 / 255)
                }
                textC(name, bf, pill.midX, Self.capY(bf, pill.midY), i == tab ? xc(.tabFg) : xc(.text))
                tabHits.append((rect: pill, tab: i))
                tx += tw + 8 * u
            }
            inside = CGRect(x: inside.minX, y: inside.minY + th + 14 * u, width: inside.width,
                            height: max(inside.height - th - 14 * u, 1))
        }
        for line in heads {   // the lines above the chart, in the mono font (their columns line up)
            drawSpans(mf, line, inside.minX, inside.minY, inside.width, plh, xc(.text), bg)
            inside = CGRect(x: inside.minX, y: inside.minY + plh, width: inside.width, height: max(inside.height - plh, 1))
        }
        if !heads.isEmpty {
            inside = CGRect(x: inside.minX, y: inside.minY + 10 * u, width: inside.width, height: max(inside.height - 10 * u, 1))
        }
        let notesH = notes.isEmpty ? 0 : CGFloat(notes.count) * plh + 10 * u
        for (i, line) in notes.enumerated() {
            drawSpans(mf, line, inside.minX, inside.maxY - notesH + 10 * u + CGFloat(i) * plh, inside.width, plh, xc(.dim), bg)
        }
        if hasChart && chartIn {
            drawChart(CGRect(x: inside.minX, y: inside.minY, width: inside.width,
                             height: max(inside.height - notesH - 6 * u, 1)))
        } else if let img = picImage, img.size.width > 0, img.size.height > 0 {
            // The image as large as fits, centered: art crisp (nearest pixel), a photo smoothly.
            let aw = inside.width, ah = max(inside.height - notesH - 6 * u, 1)
            let s = min(aw / img.size.width, ah / img.size.height)   // any scale; art stays crisp (.none)
            let dr = CGRect(x: inside.minX + (aw - img.size.width * s) / 2, y: inside.minY + (ah - img.size.height * s) / 2,
                            width: img.size.width * s, height: img.size.height * s)
            NSGraphicsContext.current?.imageInterpolation = picSmooth ? .high : .none
            img.draw(in: dr, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        screenFade(rect, bg)
    }

    // ---- forms (menumod.c draw_form: the module's look, in points) ----

    private func fc(_ i: Fc) -> UInt32 { formColors[i.rawValue] }

    /// A form in a box like the menu's (the style's radius, border, opacity, shadow, fade, valign and nudge), 62% of
    /// the window wide, centered under the header: labels in a column, each value in a rounded field (the active one
    /// lit, with the marker stripe and a blinking caret), a choice field's choices as pills; the error, then the active
    /// field's help or the hint.
    private func drawForm(_ w: CGFloat, _ h: CGFloat, _ hdrBottom: CGFloat) {
        guard !fields.isEmpty else { return }
        let bf = font(true, 13), uf = font(false, 13), tf = font(true, 17)
        let rowH = 36 * u
        var labelW: CGFloat = 0
        for f in fields {
            labelW = max(labelW, Self.textW(f.label, bf))
        }
        let bw = min(max(w * 0.62, 440 * u), w - 40 * u), pad = (st.padding + 6) * u
        labelW = min(labelW, bw * 0.4)
        let foot = (fErr.isEmpty ? 0 : Self.fontLine(uf) + 6 * u) + Self.fontLine(uf) + 12 * u
        let bh = CGFloat(fields.count) * rowH + 2 * pad + foot + (st.title == 1 ? Self.fontLine(tf) + 10 * u : 0)
        let top = hdrBottom
        let bottom = h - statusH * u - 8 * u
        let x = (w - bw) / 2 + w * st.x / 100
        var y = top + 26 * u + (bottom - top - 26 * u - bh) / 2
        if st.valign == 1 {
            y = top + 26 * u
        } else if st.valign == 3 {
            y = bottom - bh
        }
        y += h * st.y / 100
        if y + bh > bottom {
            y = bottom - bh
        }
        if y < top + 26 * u && bottom - bh >= top + 26 * u {
            y = top + 26 * u
        }
        y = max(y, 4 * u)
        let rect = CGRect(x: x, y: y, width: bw, height: bh)
        let bg = fc(.formBg)
        panel(rect, bg, fc(.border))
        var fy = y + pad
        if !head.title.isEmpty && st.title == 0 {
            let t = Self.text(head.title, tf, fc(.title))
            let tx = x + 18 * u
            borderCut(tx - 8 * u, y, t.size().width + 16 * u, bg)
            t.draw(at: CGPoint(x: tx, y: Self.capY(tf, y)))
        } else if !head.title.isEmpty && st.title == 1 {
            Self.text(head.title, tf, fc(.title)).draw(at: CGPoint(x: x + pad, y: fy - 4 * u))
            fy += Self.fontLine(tf) + 10 * u
        }
        formHits.removeAll()
        let lx = x + pad, vx = lx + labelW + 18 * u, vw = x + bw - pad - vx
        let blink = Date().timeIntervalSince(caretAt) < 0.6 || Int(nowMs / 530) % 2 == 0
        for (i, f) in fields.enumerated() {
            let on = i == fAct
            let ry = fy + CGFloat(i) * rowH, fh = rowH - 8 * u
            Self.text(Self.fitText(f.label, bf, labelW), bf, on ? fc(.labelOn) : fc(.label))
                .draw(at: CGPoint(x: lx, y: Self.capY(bf, ry + fh / 2)))
            if f.isChoice {   // the choices as pills, the value's filled
                var cx = vx
                let sel = choiceIndex(f)
                for (c, choice) in f.choices.enumerated() {
                    let cw = Self.textW(choice, uf) + 22 * u
                    if cx + cw > vx + vw {
                        break
                    }
                    let pill = CGRect(x: cx, y: ry + 2 * u, width: cw, height: max(fh - 4 * u, 1))
                    let pp = NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2)
                    if c == sel {
                        Self.color(fc(.marker)).setFill()
                        pp.fill()
                    } else {
                        Self.color(on ? fc(.labelOn) : fc(.label), 140.0 / 255).setStroke()
                        pp.lineWidth = 1 * u
                        pp.stroke()
                    }
                    let tc: UInt32 = c == sel ? (Self.luma(fc(.marker)) > 140 ? 0x10_1010 : 0xFF_FFFF) : fc(.label)
                    let t = Self.text(choice, uf, tc)
                    t.draw(at: CGPoint(x: cx + (cw - t.size().width) / 2, y: Self.capY(uf, pill.midY)))
                    formHits.append((rect: CGRect(x: cx, y: ry, width: cw, height: fh), field: i, choice: c))
                    cx += cw + 8 * u
                }
                if on {
                    Self.color(fc(.marker)).setFill()
                    CGRect(x: vx - 10 * u, y: ry + 4 * u, width: 3 * u, height: max(fh - 8 * u, 1)).fill()
                }
            } else {
                let field = CGRect(x: vx, y: ry, width: max(vw, 1), height: fh)
                Self.color(on ? fc(.fieldBgOn) : fc(.fieldBg), on ? 1 : 150.0 / 255).setFill()
                NSBezierPath(roundedRect: field, xRadius: st.selRadius * u, yRadius: st.selRadius * u).fill()
                if on && st.marker {
                    Self.color(fc(.marker)).setFill()
                    CGRect(x: vx, y: ry, width: 3 * u, height: fh).fill()
                }
                let shown = f.isSecret ? String(repeating: "\u{2022}", count: f.value.count) : String(f.value)
                let before = f.isSecret ? String(repeating: "\u{2022}", count: f.cur) : String(f.value[0..<f.cur])
                let tx = vx + 10 * u, tw = vw - 20 * u, cxw = Self.textW(before, uf)
                let shift = cxw > tw - 4 * u ? cxw - (tw - 4 * u) : 0   // keep the caret in view
                NSGraphicsContext.saveGraphicsState()
                CGRect(x: tx, y: ry, width: max(tw, 1), height: fh).clip()
                Self.text(shown, uf, fc(.fieldText)).draw(at: CGPoint(x: tx - shift, y: Self.capY(uf, ry + fh / 2)))
                NSGraphicsContext.restoreGraphicsState()
                if on && blink {
                    Self.color(fc(.marker)).setFill()
                    CGRect(x: tx - shift + cxw, y: ry + 6 * u, width: 2 * u, height: max(fh - 12 * u, 1)).fill()
                }
                formHits.append((rect: field, field: i, choice: -1))
            }
        }
        var hy = fy + CGFloat(fields.count) * rowH + 4 * u
        if !fErr.isEmpty {
            Self.text(Self.fitText(fErr, uf, bw - 2 * pad), uf, fc(.error)).draw(at: CGPoint(x: lx, y: hy))
            hy += Self.fontLine(uf) + 6 * u
        }
        let hint = fAct < fields.count && !fields[fAct].help.isEmpty ? fields[fAct].help : fHint
        if !hint.isEmpty {
            Self.text(Self.fitText(hint, uf, bw - 2 * pad), uf, fc(.hint)).draw(at: CGPoint(x: lx, y: hy))
        }
        let fade = fadeIn()
        if fade < 1 {
            Self.color(bg, 1 - fade).setFill()
            rect.fill(using: .sourceOver)
        }
    }

    /// The dialog over the dimmed menu, centered: the title on its top border, the lines, the foot at the bottom
    /// right (render's dialog, look.go, in the module's units). Drawn by `overlay`, above the header picture.
    fileprivate func drawDialog(_ w: CGFloat, _ h: CGFloat) {
        guard let d = dialog else { return }
        NSColor(white: 0, alpha: 110.0 / 255).setFill()
        CGRect(x: 0, y: 0, width: w, height: h).fill(using: .sourceOver)
        let size: CGFloat = 16
        let lineH = 24 * u, padX = 28 * u, padY = 22 * u
        let lf = font(false, size), ff = font(false, 13), tf = font(true, 17)
        var tw: CGFloat = 0
        for line in d.lines {
            tw = max(tw, line.reduce(CGFloat(0)) { $0 + Self.textW($1.text, lf) })
        }
        let foot = Self.text(d.foot, ff, d.footFg)
        let title = Self.text(d.title, tf, mc(.panelTitle))
        let footSize = foot.size(), titleW = title.size().width
        let bw = min(max(max(tw, footSize.width), titleW + 40 * u) + 2 * padX, w - 24 * u)
        let bh = min(CGFloat(d.lines.count) * lineH + 2 * padY + footSize.height + 8 * u, h - 24 * u)
        let dbox = CGRect(x: (w - bw) / 2, y: (h - bh) / 2, width: bw, height: bh)
        panel(dbox, d.bg, d.border)   // box.radius, border, opacity
        if !d.title.isEmpty {
            let tx = dbox.minX + 18 * u
            borderCut(tx - 8 * u, dbox.minY, titleW + 16 * u, d.bg)
            title.draw(at: CGPoint(x: tx, y: Self.capY(tf, dbox.minY)))
        }
        NSGraphicsContext.saveGraphicsState()
        CGRect(x: dbox.minX + padX, y: dbox.minY + padY, width: dbox.width - 2 * padX,
               height: dbox.height - 2 * padY).clip()
        var y = dbox.minY + padY
        for line in d.lines {
            var x = dbox.minX + padX
            for s in line {
                let sw = Self.textW(s.text, lf)
                if s.bg != Self.none {
                    Self.color(s.bg).setFill()
                    CGRect(x: x, y: y + 2 * u, width: sw, height: lineH - 4 * u).fill()
                }
                Self.text(s.text, lf, s.fg != Self.none ? s.fg : d.fg).draw(at: CGPoint(x: x, y: Self.capY(lf, y + lineH / 2)))
                x += sw
            }
            y += lineH
        }
        NSGraphicsContext.restoreGraphicsState()
        if !dialogKeyed {
            foot.draw(at: CGPoint(x: dbox.maxX - padX - footSize.width, y: dbox.maxY - padY / 2 - footSize.height))
        }
    }

    // ---- the rain (Rainwire render/look.go: the "rain" background, on the text screen's grid) ----

    private final class Drop {
        var x = 0, y = 0, n = 0
        var slow = false
    }
    private var drops: [Drop] = []
    private var dropRows = 0, rainTicks = 0
    private var lastInput = Date()
    private static let rainCols = 80
    private static let rainFor: TimeInterval = 30   // as the text screen's animation

    private static func hash(_ a: Int, _ b: Int) -> UInt32 {
        var v = (UInt32(truncatingIfNeeded: a) &* 2_654_435_761) ^ (UInt32(truncatingIfNeeded: b) &* 40503)
        v ^= v >> 13
        v = v &* 0x5BD1_E995
        return v ^ (v >> 15)
    }

    private var rainRows: Int { head.screenRows > 0 ? head.screenRows : 25 }

    /// The streaks, placed as the text screen places them (a column in six, its start and length from it).
    private func rainSeed() {
        drops.removeAll()
        let h = rainRows
        dropRows = h
        for x in 2..<(Self.rainCols - 2) {
            let hx = Self.hash(x, 7)
            if hx % 6 != 0 {
                continue
            }
            let d = Drop()
            d.x = x
            d.y = 1 + Int(hx / 6 % UInt32(max(h - 4, 1)))
            d.n = 2 + Int(hx / 37 % 4)
            d.slow = hx & 0x100 != 0
            drops.append(d)
        }
    }

    /// One row down every 150 ms (slow streaks every other tick); still after 30 s without a key or the mouse.
    private func rainStep() {
        guard isUp, head.flags & Self.mfRain != 0, Date().timeIntervalSince(lastInput) <= Self.rainFor else { return }
        if dropRows != rainRows || drops.isEmpty {
            rainSeed()
        }
        let h = rainRows
        rainTicks += 1
        for d in drops {
            if d.slow && rainTicks % 2 == 0 {
                continue
            }
            d.y += 1
            if d.y >= h - 1 {
                let r = Self.hash(d.x, rainTicks)
                d.n = 2 + Int(r % 4)
                d.y = 1 - d.n - Int(r / 4 % UInt32(max(h / 2, 1)))
            }
        }
        needsDisplay = true
    }

    /// Each streak: its tail faint, its body brighter, its head (dashed, as the text's ╎) brightest; the header and
    /// the box draw over it.
    private func drawRain(_ w: CGFloat, _ h: CGFloat) {
        if dropRows != rainRows || drops.isEmpty {
            rainSeed()
        }
        let pic = picture(w, h)
        let rows = rainRows
        let cw = pic.width / CGFloat(Self.rainCols), ch = pic.height / CGFloat(rows), lw = max(1, cw * 0.14)
        let headC = Self.color(mc(.rainHead)), bodyC = Self.color(mc(.rainBody)), tailC = Self.color(mc(.rainTail))
        for d in drops {
            for i in 0..<d.n {
                let y = d.y + i
                if y < 1 || y >= rows - 1 {
                    continue
                }
                let x = pic.minX + (CGFloat(d.x) + 0.5) * cw - lw / 2, top = pic.minY + CGFloat(y) * ch
                if i == d.n - 1 {
                    headC.setFill()
                    CGRect(x: x, y: top + ch * 0.08, width: lw, height: ch * 0.34).fill()
                    CGRect(x: x, y: top + ch * 0.58, width: lw, height: ch * 0.34).fill()
                } else {
                    (i == 0 ? tailC : bodyC).setFill()
                    CGRect(x: x, y: top, width: lw, height: ch).fill()
                }
            }
        }
    }

    /// A panel in the sysop's box style (box.radius, border, opacity, shadow): the menu's box, the news panel and its
    /// stats strip, dialogs. shadow false: none whatever the style; radiusScale: the news's rounder corners (8 at 6).
    func panel(_ rect: CGRect, _ bg: UInt32, _ border: UInt32, borderAlpha: CGFloat = 1, shadow: Bool = true,
                       radiusScale: CGFloat = 1) {
        let r = st.radius * radiusScale * u
        let a = st.opacity / 100
        if shadow && head.flags & Self.mfShadow != 0 && st.shadow != 2 {
            if st.shadow == 1 {   // hard
                Self.color(mc(.panelShadow), 220.0 / 255).setFill()
                NSBezierPath(roundedRect: rect.offsetBy(dx: 4 * u, dy: 4 * u), xRadius: r, yRadius: r).fill()
            } else {              // soft
                Self.color(mc(.panelShadow), 90.0 / 255 * a).setFill()
                NSBezierPath(roundedRect: rect.offsetBy(dx: 6 * u, dy: 6 * u), xRadius: r, yRadius: r).fill()
            }
        }
        let path = NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r)
        Self.color(bg, a).setFill()
        path.fill()
        if st.border > 0 {
            Self.color(border, borderAlpha).setStroke()
            path.lineWidth = st.border * u
            path.stroke()
        }
    }

    /// Where a border is cut for a title or foot drawn on it, at border y: as tall as the border needs (4 at 1.5).
    func borderCut(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ bg: UInt32) {
        guard st.border > 0 else { return }
        Self.color(bg, st.opacity / 100).setFill()
        CGRect(x: x, y: y - (2 + (st.border - 1.5) / 2) * u, width: width, height: (4 + st.border - 1.5) * u).fill()
    }

    private func drawBox() {
        panel(box, mc(.menuBg), mc(.menuBorder))
        if !head.title.isEmpty && st.title == 0 {   // on the top border, the border cut under it
            let f = font(true, 17)
            let t = Self.text(head.title, f, mc(.panelTitle))
            let tx = box.minX + 18 * u
            borderCut(tx - 8 * u, box.minY, t.size().width + 16 * u, mc(.menuBg))
            t.draw(at: CGPoint(x: tx, y: Self.capY(f, box.minY)))
        } else if !head.title.isEmpty && st.title == 1 {   // inside, as a heading over the items
            Self.text(head.title, font(true, 17), mc(.panelTitle)).draw(at: CGPoint(x: box.minX + (pad + 4) * u,
                                                                                    y: box.minY + (pad - 2) * u))
        }
        if head.flags & Self.mfRoot == 0 {
            let f = font(false, 13)
            let t = Self.text("Esc Back", f, mc(.dim))
            let tw = t.size().width
            let tx = box.maxX - tw - 18 * u
            borderCut(tx - 6 * u, box.maxY, tw + 12 * u, mc(.menuBg))
            t.draw(at: CGPoint(x: tx, y: Self.capY(f, box.maxY)))
        }
    }

    var nowMs: Double { ProcessInfo.processInfo.systemUptime * 1000 }

    /// A label in its spans' colors from x, cut at maxW. On the selection a span keeps its own color only when it
    /// reads there.
    private func drawLabel(_ it: Item, _ x0: CGFloat, _ row: CGRect, _ maxW: CGFloat, _ selected: Bool, _ selBg: UInt32) {
        let baseC = selected ? mc(.selFg) : it.flags & Self.ifSeparator != 0 ? mc(.menuTag) : mc(.menuLabel)
        let under = selected ? selBg : mc(.menuBg)
        let f = labelFont()
        let ty = Self.capY(f, row.midY)
        NSGraphicsContext.saveGraphicsState()
        CGRect(x: x0, y: row.minY, width: max(maxW, 0), height: row.height).clip()
        var x = x0
        let now = nowMs
        for s in it.spans {
            if x >= x0 + maxW {
                break
            }
            var fg = baseC
            if s.fg != Self.none {
                fg = s.fg
                if selected && abs(Self.luma(fg) - Self.luma(selBg)) < 60 {
                    fg = baseC
                }
            }
            let sw = Self.textW(s.text, f)
            if !selected && s.bg != Self.none && !(s.fx == Self.fxBlink && Int(now / 500) % 2 == 1) {
                Self.color(s.bg).setFill()
                CGRect(x: x, y: row.minY + 3 * u, width: sw, height: row.height - 6 * u).fill()
            }
            if s.fx == Self.fxPulse {
                let t = 0.5 + 0.5 * sin(now / 1000 * 3.6)
                fg = Self.mix(Self.mix(fg, under, 0.5), fg, CGFloat(t))
            }
            if s.fx == Self.fxShimmer {
                let pos = CGFloat(now / 1400).truncatingRemainder(dividingBy: 1.8) * (sw + 60 * u) - 30 * u
                var cx = x
                for ch in s.text {
                    let str = String(ch)
                    let cw = Self.textW(str, f)
                    let glint = 1 - min(max(abs(cx + cw / 2 - x - pos) / (24 * u), 0), 1)
                    Self.text(str, f, Self.mix(fg, 0xFF_FFFF, glint * 0.85)).draw(at: CGPoint(x: cx, y: ty))
                    cx += cw
                }
            } else {
                Self.text(s.text, f, fg).draw(at: CGPoint(x: x, y: ty))
            }
            x += sw
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawItem(_ i: Int) {
        let it = items[i]
        guard it.box.width > 0 else { return }
        let r = it.box
        if it.flags & Self.ifSeparator != 0 {
            if !it.spans.isEmpty {
                drawLabel(it, r.minX + 4 * u, r, r.width - 8 * u, false, 0)
            }
            return
        }
        let selected = i == sel, grid = head.layout == Self.layoutGrid
        var selBg = mc(.selBg)
        let bar = CGRect(x: r.minX, y: r.minY + 1 * u, width: r.width, height: max(r.height - 2 * u, 1))
        if selected {
            let a: CGFloat = waiting ? 170.0 / 255 : 1
            let sr = st.selRadius * u
            switch st.sel {   // select.shape
            case 1:   // outline
                Self.color(mc(.selBg), a).setStroke()
                let p = NSBezierPath(roundedRect: bar, xRadius: sr, yRadius: sr)
                p.lineWidth = 1.5 * u
                p.stroke()
                selBg = mc(.menuBg)
            case 2:   // glow: a soft halo and a lighter bar
                Self.color(mc(.selBg), 55.0 / 255 * a).setFill()
                NSBezierPath(roundedRect: r.insetBy(dx: -3 * u, dy: -2 * u), xRadius: sr + 3 * u, yRadius: sr + 3 * u).fill()
                Self.color(mc(.selBg), 150.0 / 255 * a).setFill()
                NSBezierPath(roundedRect: bar, xRadius: sr, yRadius: sr).fill()
                selBg = Self.mix(mc(.menuBg), mc(.selBg), 150.0 / 255)
            case 3:   // underline
                Self.color(mc(.selBg), a).setFill()
                CGRect(x: r.minX + 8 * u, y: r.maxY - 3 * u, width: max(r.width - 16 * u, 0), height: 2 * u).fill()
                selBg = mc(.menuBg)
            default:
                if head.flags & Self.mfGradient != 0 {
                    NSGradient(starting: Self.color(mc(.selBg), a), ending: Self.color(mc(.selBg2), a))?.draw(in: bar, angle: 0)
                    selBg = Self.mix(mc(.selBg), mc(.selBg2), 0.5)
                } else {
                    Self.color(mc(.selBg), a).setFill()
                    NSBezierPath(roundedRect: bar, xRadius: sr, yRadius: sr).fill()
                }
            }
            if st.marker && st.sel != 3 {
                Self.color(mc(.selMarker)).setFill()
                CGRect(x: bar.minX, y: bar.minY, width: 3 * u, height: bar.height).fill()   // the bar's height
            }
        } else if grid {
            Self.color(mc(.menuBorder), 200.0 / 255).setStroke()
            let p = NSBezierPath(roundedRect: r, xRadius: 5 * u, yRadius: 5 * u)
            p.lineWidth = 1 * u
            p.stroke()
        }
        let key = it.key > 0 && it.key <= 0x10FFFF ? (UnicodeScalar(UInt32(it.key)).map { String(Character($0)) } ?? "") : ""
        let kfg: UInt32
        if selected {
            kfg = it.keyFg != Self.none ? 0xFF_FFFF : mc(.selKey)
        } else {
            kfg = it.keyFg != Self.none ? it.keyFg : mc(.menuKey)
        }
        let brackets = head.flags & Self.mfBrackets != 0
        if grid {
            let kf = font(true, 13)
            if st.key == 3 {   // a chip: the key in a pill of its color
                let cw = Self.textW(key, kf) + 14 * u, ch = Self.fontLine(kf) + 4 * u
                Self.color(kfg).setFill()
                NSBezierPath(roundedRect: CGRect(x: r.minX + (r.width - cw) / 2, y: r.minY + 4 * u, width: cw, height: ch),
                             xRadius: ch / 2, yRadius: ch / 2).fill()
                let kt = Self.text(key, kf, Self.luma(kfg) > 140 ? 0x10_1010 : 0xFF_FFFF)
                kt.draw(at: CGPoint(x: r.minX + (r.width - kt.size().width) / 2, y: r.minY + 6 * u))
            } else if st.key != 4 {
                let kt = Self.text(brackets ? "[\(key)]" : key, kf, kfg)
                kt.draw(at: CGPoint(x: r.minX + (r.width - kt.size().width) / 2, y: r.minY + 6 * u))
            }
            let lw = labelW(it), room = r.width - 12 * u
            drawLabel(it, r.minX + (r.width - min(lw, room)) / 2,
                      CGRect(x: r.minX, y: r.midY - 12 * u, width: r.width, height: 26 * u), room, selected, selBg)
            if !it.tag.isEmpty {
                let tt = Self.text(it.tag, font(false, 11), selected ? mc(.selFg) : mc(.menuTag))
                tt.draw(at: CGPoint(x: r.minX + (r.width - tt.size().width) / 2, y: r.maxY - 18 * u))
            }
        } else {
            let kf = labelFont()
            var kx = r.minX + 10 * u
            let bracketC = selected ? mc(.selFg) : mc(.menuBracket)
            let parts: [(String, UInt32)] = brackets ? [("[", bracketC), (key, kfg), ("]", bracketC)] : [(key, kfg)]
            let kw = parts.reduce(CGFloat(0)) { $0 + Self.textW($1.0, kf) }
            if !selected && it.keyBg != Self.none && st.key < 3 {
                Self.color(it.keyBg).setFill()
                CGRect(x: kx - 2 * u, y: r.minY + 3 * u, width: kw + 4 * u, height: r.height - 6 * u).fill()
            }
            let ky = Self.capY(kf, r.midY)
            if st.key == 3 {   // a chip: the key in a pill of its color
                let cw = Self.textW(key, kf) + 12 * u, ch = max(r.height - 8 * u, 1)
                Self.color(kfg).setFill()
                NSBezierPath(roundedRect: CGRect(x: kx - 4 * u, y: r.minY + 4 * u, width: cw, height: ch),
                             xRadius: ch / 2, yRadius: ch / 2).fill()
                Self.text(key, kf, Self.luma(kfg) > 140 ? 0x10_1010 : 0xFF_FFFF).draw(at: CGPoint(x: kx + 2 * u, y: ky))
            } else if st.key != 4 {   // none: no key shown (it still works)
                for (s, c) in parts {
                    Self.text(s, kf, c).draw(at: CGPoint(x: kx, y: ky))
                    kx += Self.textW(s, kf)
                }
            }
            let lx = r.minX + (keyW + 12 + (brackets && st.key < 3 ? 10 : 0)) * u, tw = tagW(it)
            drawLabel(it, lx, r, r.width - (lx - r.minX) - tw - 6 * u, selected, selBg)
            if tw > 0 {
                let tf = font(false, 13)
                let tt = Self.text(it.tag, tf, selected ? mc(.selFg) : mc(.menuTag))
                tt.draw(at: CGPoint(x: r.maxX - 8 * u - tt.size().width, y: Self.capY(tf, r.midY)))
            }
        }
    }

    private func drawHelp(_ w: CGFloat, _ h: CGFloat) {
        var help = isSelectable(sel) ? items[sel].help : ""
        guard !help.isEmpty else { return }
        let f = font(false, 13)
        let maxW = max(w - 40 * u, 1)
        if Self.textW(help, f) > maxW {   // cut with an ellipsis, as Windows' CharacterEllipsis
            while !help.isEmpty && Self.textW(help + "\u{2026}", f) > maxW {
                help.removeLast()
            }
            help += "\u{2026}"
        }
        let t = Self.text(help, f, mc(.menuHelp))
        let y = h - (statusH + helpH) * u
        t.draw(at: CGPoint(x: (w - t.size().width) / 2, y: Self.capY(f, y + helpH * u / 2)))
    }

    private func drawStatus(_ w: CGFloat, _ h: CGFloat) {
        let y = h - statusH * u, sh = statusH * u
        let bf = font(true, 13), f = font(false, 13)
        if !toast.isEmpty && Date() < toastUntil {   // the text screen's toast: the whole bar, its own colors
            Self.color(toastBg).setFill()
            CGRect(x: 0, y: y, width: w, height: sh).fill()
            Self.text(toast, bf, toastFg).draw(at: CGPoint(x: 12 * u, y: Self.capY(bf, y + sh / 2)))
            return
        }
        Self.color(mc(.statusBg)).setFill()
        CGRect(x: 0, y: y, width: w, height: sh).fill()
        let ty = Self.capY(f, y + sh / 2)
        let arrow = Self.text(">", bf, mc(.accent))
        arrow.draw(at: CGPoint(x: 12 * u, y: ty))
        Self.text(head.title, f, mc(.statusText)).draw(at: CGPoint(x: 12 * u + arrow.size().width + 8 * u, y: ty))
        let mins = minutes != 0xFFFF ? " \u{00B7} \(minutes)m left" : ""
        // The text bar's end (Rainwire's bar.version, "Rainwire"): its letters in the logo's blue-to-purple fade, as
        // the text bar draws them (render/look.go rainwireFade)
        let end = NSMutableAttributedString(attributedString: Self.text(barEnd, bf, mc(.barTitle)))
        if let range = barEnd.range(of: "Rainwire") {
            let at = NSRange(range, in: barEnd).location
            for i in 0..<8 {
                end.addAttribute(.foregroundColor, value: Self.color(Self.mix(0x5A_D1FF, 0xA7_8BFA, CGFloat(i) / 7)),
                                 range: NSRange(location: at + i, length: 1))
            }
        }
        let endW = end.size().width
        let right = Self.text("node \(node) \u{00B7} \(clock.isEmpty ? "--:--" : clock)\(mins) \u{00B7} ", f, mc(.statusHint))
        end.draw(at: CGPoint(x: w - 12 * u - endW, y: Self.capY(bf, y + sh / 2)))
        right.draw(at: CGPoint(x: w - 12 * u - endW - right.size().width, y: ty))
    }

    /// The dialog's layer, above the header picture (an image view over the menu's own drawing). Clicks go to the
    /// menu under it (`mouseUp`).
    /// The dim layer: drawn by its layer's color, never takes the mouse.
    fileprivate final class DimView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    fileprivate final class DialogOverlay: NSView {
        weak var owner: RainwireMenuView?
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func draw(_ dirtyRect: NSRect) {
            guard let menu = owner, bounds.width > 0, bounds.height > 0 else { return }
            if !menu.sceneBleeds {   // a whole-window scene (SF_BLEED) has no header for them; a dialog still shows
                menu.drawWire()      // the news panel, over the header picture
                menu.drawWeather()   // and the weather widget under it
                menu.drawGadgets()   // and the scene gadgets
            }
            menu.drawDialog(bounds.width, bounds.height)
        }
    }
}

/// The header picture: an NSImageView (it plays an animated GIF, as TERMinator:Pic's `AnimatedImageView` does) that
/// draws without smoothing when `crisp`, so pixel art stays sharp when enlarged (Windows: NearestNeighbor).
final class PixelImageView: NSImageView {
    var crisp = false {
        didSet {
            // A layer-backed image view may hand its image to the layer and never call draw: set both
            wantsLayer = true
            layer?.magnificationFilter = crisp ? .nearest : .linear
            layer?.minificationFilter = crisp ? .nearest : .linear
            needsDisplay = true
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.imageInterpolation = crisp ? .none : .high
        super.draw(dirtyRect)
    }
}

/// Hosts the shared `RainwireMenuView` over the terminal area in TerminalView (the area stops above the app's status
/// bar, so the connection, modem lights and bytes stay in sight: Windows' FitRainwireMenu). pictureRect is the
/// terminal picture inside it, top-left origin.
struct RainwireMenuLayer: NSViewRepresentable {
    let pictureRect: CGRect

    func makeNSView(context: Context) -> RainwireMenuHostView {
        let host = RainwireMenuHostView()
        let menu = RainwireMenuView.shared
        menu.removeFromSuperview()   // a TerminalView from before (one call per process: there's one at a time)
        menu.frame = host.bounds
        menu.autoresizingMask = [.width, .height]
        host.addSubview(menu)
        menu.pictureRect = pictureRect
        return host
    }

    func updateNSView(_ nsView: RainwireMenuHostView, context: Context) {
        RainwireMenuView.shared.pictureRect = pictureRect
    }
}

/// The menu's container: lets the mouse through wherever the menu isn't up.
final class RainwireMenuHostView: NSView {
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

// MARK: - The news panel beside the header

/// The news panel beside a menu's header art (1.1.6, a port of TERMinator-Windows Controls/RainwireWire.cs; Rainwire
/// docs/MENU_GFX.md, "The news panel"). The board sends Wire (MU_S_WIRE: its width as a share of the header, its scroll
/// speed, colors, title and the stories, newest first) after a Menu's items and before Show, then one WirePic a story
/// (MU_S_WIRE_PIC + path=: its thumbnail in the picture cache). The header art shrinks, keeping its shape, to the left
/// of the panel; the panel is as tall as the art. Stories scroll up slowly and loop; the pointer over the panel holds
/// them still, the wheel scrolls them by hand, a click says Wire;i= (the board opens its news door at that story).
final class WireStory {
    var section = 0
    var hasPicture = false
    var published: UInt32 = 0
    var source = "", title = ""
    var picture: NSImage?
    var y: CGFloat = 0, h: CGFloat = 0   // laid out: from the top of the list, and its height
}

final class WirePanel {
    var width = 30, speed = 18
    var colors = [UInt32](repeating: 0, count: 10)   // MU_WC_*: bg, border, title, text, dim, hover, tech, retro, bbs, today
    var title = ""
    var stories: [WireStory] = []
}

extension RainwireMenuView {
    private static let wiPicture = 0x01
    private static let wireHeadSize: CGFloat = 13.5, wireTagSize: CGFloat = 10.5, wireRowGap: CGFloat = 10

    func wireReset() {
        if wire != nil {
            wireKeep = wire
        }
        wire = nil
        wx = nil   // and the weather widget: each comes with its menu
        gadgetsForMenu()   // and the scene gadgets: they come with each menu too, but kept ones stay (version 6)
        wxBox = .zero
        wxHot = false
        widgetBtnHot = nil
        wireBox = .zero
        wireList = .zero
        wireHover = -1
        wireLaidW = -1
        needsLayout = true
    }

    /// MU_S_WIRE: the panel for the menu whose head came just before. Every read is bounds-checked.
    func onWire(_ p: [UInt8]) {
        func u8(_ o: Int) -> Int { o >= 0 && o < p.count ? Int(p[o]) : 0 }
        func u32(_ o: Int) -> UInt32 { UInt32(u8(o)) | UInt32(u8(o + 1)) << 8 | UInt32(u8(o + 2)) << 16 | UInt32(u8(o + 3)) << 24 }
        func str(_ o: inout Int, _ n: Int) -> String {
            let n = max(0, min(n, p.count - o))
            guard o >= 0, o <= p.count else { return "" }
            let s = String(decoding: p[o..<(o + n)], as: UTF8.self)
            o += n
            return s
        }
        guard p.count >= 12 else { return }
        let count = u8(4), colors = u8(7), titleLen = u8(8)
        let w = WirePanel()
        w.width = min(max(u8(5), 15), 50)
        w.speed = min(max(u8(6), 0), 80)
        var o = 12
        for i in 0..<colors {
            if i < w.colors.count {
                w.colors[i] = u32(o) & 0xFF_FFFF
            }
            o += 4
        }
        w.title = str(&o, titleLen)
        for _ in 0..<count where o + 8 <= p.count {
            let s = WireStory()
            s.section = min(u8(o), 3)
            s.hasPicture = u8(o + 1) & Self.wiPicture != 0
            s.published = u32(o + 4)
            let sl = u8(o + 2), tl = u8(o + 3)
            o += 8
            s.source = str(&o, sl)
            s.title = str(&o, tl)
            w.stories.append(s)
        }
        // the same stories again (the board sends the panel with every showing): keep their pictures and the scroll
        let old = wire ?? wireKeep
        if let old = old {
            for i in 0..<min(old.stories.count, w.stories.count) where old.stories[i].title == w.stories[i].title {
                w.stories[i].picture = old.stories[i].picture
            }
        }
        let same = (old?.stories.first?.title).map { $0 == w.stories.first?.title } ?? false
        wire = w.stories.isEmpty ? nil : w
        if !same {
            wireOff = 0
        }
        wireLaidW = -1
        needsLayout = true
        redraw()
    }

    /// MU_S_WIRE_PIC: story index's thumbnail is the file at path.
    func onWirePic(_ p: [UInt8], _ path: String?) {
        guard p.count >= 6, let w = wire, let path = path else { return }
        let i = Int(p[4]) | Int(p[5]) << 8
        guard i < w.stories.count, let img = NSImage(contentsOfFile: (path as NSString).standardizingPath) else { return }
        w.stories[i].picture = img
        redraw()
    }

    /// Places the panel over the right of header hr (the sysop, 2026-10-22: "have the main ansi stay the same size and
    /// just draw the new box over it"): the art keeps its size, the panel covers its right width %, inset a little, drawn
    /// by the overlay above the header picture. Returns hr unchanged; no panel when it'd be too small.
    func wireLayout(_ hr: CGRect) -> CGRect {
        wireList = .zero
        widgetLayout(hr)   // the column: news on top, weather under it
        guard !wireBox.isEmpty else { return hr }
        // the list's place too, here and not in drawWire: the view lays out and the overlay draws, in either order,
        // and a click needs both
        let pad = 12 * u
        wireList = CGRect(x: wireBox.minX + pad, y: wireBox.minY + pad + 2 * u, width: max(wireBox.width - 2 * pad, 1),
                          height: max(wireBox.height - 2 * pad - 2 * u, 1))
        return hr
    }

    private static func wireSection(_ s: Int) -> String {
        switch s {
        case 1: return "RETRO"
        case 2: return "BBS SCENE"
        case 3: return "ON THIS DAY"
        default: return "TECH"
        }
    }

    private static func wireAgo(_ t: UInt32) -> String {
        let d = max(0, Date().timeIntervalSince1970 - Double(t))
        return d < 3600 ? "\(max(1, Int(d / 60)))m ago" : d < 86400 ? "\(Int(d / 3600))h ago" : "\(Int(d / 86400))d ago"
    }

    private func wcol(_ i: Int) -> UInt32 { wire?.colors[i] ?? 0 }
    /// The news door's placeholder for a story without a picture (newsmodule.c mosaic): a 12 x 9 grid of blocks in the
    /// section's color on a dark ground, denser towards the lower middle, the same seeded sequence; dimmer while a
    /// picture is on its way.
    private func mosaic(_ r: CGRect, _ seed: Int, _ col: UInt32, _ dim: Bool) {
        Self.color(0x0C0E16).setFill()
        r.fill()
        Self.color(col, (dim ? 70 : 150) / 255.0).setFill()
        var q = UInt32(truncatingIfNeeded: seed) &* 2_654_435_761 &+ 12345
        let cw = r.width / 12, ch = r.height / 9, gap = max(cw * 0.08, 0.5)
        for j in 0..<9 {
            for i in 0..<12 {
                q = q &* 1_103_515_245 &+ 12345
                let bias = CGFloat(j) / 9 + 0.35 * (1 - abs(CGFloat(i) - 5.5) / 6)
                if CGFloat((q >> 16) % 100) / 100 < bias - 0.35 {
                    CGRect(x: r.minX + CGFloat(i) * cw + gap / 2, y: r.minY + CGFloat(j) * ch + gap / 2,
                           width: cw - gap, height: ch - gap).fill()
                }
            }
        }
    }

    private func sectionColor(_ s: Int) -> UInt32 { wcol(s == 1 ? 7 : s == 2 ? 8 : s == 3 ? 9 : 6) }

    /// The thumbnail's width in the list (0: the panel is too narrow for pictures).
    private var wireThumbW: CGFloat { wireList.width < 200 * u ? 0 : min(96 * u, wireList.width * 0.36) }

    /// A headline at most three lines tall, wrapped at width.
    private func wireHeadline(_ s: WireStory, _ c: UInt32) -> NSAttributedString {
        let ps = NSMutableParagraphStyle()
        ps.lineBreakMode = .byWordWrapping
        return NSAttributedString(string: s.title, attributes: [.font: font(true, Self.wireHeadSize),
                                                                 .foregroundColor: Self.color(c), .paragraphStyle: ps])
    }

    private func wireHeadlineH(_ t: NSAttributedString, _ width: CGFloat) -> CGFloat {
        let f = font(true, Self.wireHeadSize)
        let one = ceil(f.ascender - f.descender + f.leading)
        let h = t.boundingRect(with: CGSize(width: max(width, 20), height: 10_000), options: [.usesLineFragmentOrigin]).height
        return min(ceil(h), one * 3)
    }

    /// Each story's place and height at the list's width, when the width or scale changed.
    private func wireLay() {
        guard let w = wire, wireLaidW != wireList.width || wireLaidU != u else { return }
        wireLaidW = wireList.width
        wireLaidU = u
        let tw = wireThumbW, textW = wireList.width - (tw > 0 ? tw + 10 * u : 0)
        let tagH = ceil(font(true, Self.wireTagSize).ascender - font(true, Self.wireTagSize).descender)
        var y: CGFloat = 0
        for s in w.stories {
            let h = max(tw * 9 / 16, tagH + 3 * u + wireHeadlineH(wireHeadline(s, 0), textW))
            s.y = y.rounded()   // whole points apart, so the rows keep their distances as the list moves
            s.h = h
            y += h + Self.wireRowGap * u
        }
        wireLoop = y + 18 * u
    }

    /// The panel: its box with the title on the top border, the stories scrolling inside, faded at the edges.
    func drawWire() {
        guard let w = wire, !wireBox.isEmpty else { return }
        let box = wireBox, bg = wcol(0)
        // 80% of the box style's opacity, so the header art shows through (sysop 2026-10-22: "slightly see-through")
        let a = st.opacity / 100 * 0.8, r = st.radius * u
        let path = NSBezierPath(roundedRect: box, xRadius: r, yRadius: r)
        Self.color(bg, a).setFill()
        path.fill()
        if st.border > 0 {
            Self.color(wcol(1)).setStroke()
            path.lineWidth = st.border * u
            path.stroke()
        }
        // the title on the top border
        let tf = font(true, 12)
        let title = Self.text(w.title.uppercased(), tf, wcol(2))
        let tx = box.minX + 14 * u
        if st.border > 0 {   // the border cut under the title, as see-through as the panel
            Self.color(bg, a).setFill()
            CGRect(x: tx - 6 * u, y: box.minY - (2 + st.border / 2) * u, width: title.size().width + 12 * u,
                   height: (4 + st.border) * u).fill()
        }
        title.draw(at: CGPoint(x: tx, y: Self.capY(tf, box.minY)))
        drawWidgetButtons(box, "news", widgetFlags("news"), bg, wcol(1), wcol(2))

        wireLay()
        // the scroll: speed points a second at 1x, held while the pointer is over the panel or just after the wheel
        let now = Date()
        let dt = min(now.timeIntervalSince(wireTick), 0.25)
        wireTick = now
        let loops = wireLoop - 18 * u > wireList.height
        if !loops {
            wireOff = 0
        } else if wireHover < 0 && !(wireMouse.map { wireBox.contains($0) } ?? false) && now > wireHeld {
            wireOff += CGFloat(w.speed) * u * CGFloat(dt)
        }
        if loops {
            wireOff = (wireOff.truncatingRemainder(dividingBy: wireLoop) + wireLoop).truncatingRemainder(dividingBy: wireLoop)
        }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: wireList).addClip()
        let tw = wireThumbW, textW = wireList.width - (tw > 0 ? tw + 10 * u : 0)
        for pass in 0..<(loops ? 2 : 1) {
            // on whole device pixels, so the stories move together a pixel at a time
            let sc = window?.backingScaleFactor ?? 2
            let baseY = ((wireList.minY - wireOff + CGFloat(pass) * wireLoop) * sc).rounded() / sc
            for (i, s) in w.stories.enumerated() {
                let y = baseY + s.y
                if y > wireList.maxY || y + s.h < wireList.minY {
                    continue
                }
                drawWireStory(i, s, wireList.minX, y, tw, textW)
            }
            if loops {   // a thin rule where the list starts over
                Self.color(wcol(1), 90.0 / 255).setFill()
                CGRect(x: wireList.minX, y: baseY + wireLoop - 9 * u, width: wireList.width, height: max(1, u)).fill()
            }
        }
        // the stories fade into the panel at its top and bottom edges. Inside the clip: draw(from:to:) fills the
        // whole clip, so after the restore each fade was a dark band across the full window over the header
        let fade = 16 * u
        NSGradient(starting: Self.color(bg, a), ending: Self.color(bg, 0))?
            .draw(from: CGPoint(x: 0, y: wireList.minY), to: CGPoint(x: 0, y: wireList.minY + fade), options: [])
        NSGradient(starting: Self.color(bg, 0), ending: Self.color(bg, a))?
            .draw(from: CGPoint(x: 0, y: wireList.maxY - fade), to: CGPoint(x: 0, y: wireList.maxY), options: [])
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawWireStory(_ i: Int, _ s: WireStory, _ x0: CGFloat, _ y: CGFloat, _ tw: CGFloat, _ textW: CGFloat) {
        var x = x0
        if i == wireHover {
            Self.color(wcol(5), 70.0 / 255).setFill()
            NSBezierPath(roundedRect: CGRect(x: x - 5 * u, y: y - 4 * u, width: wireList.width + 10 * u, height: s.h + 8 * u),
                         xRadius: 4 * u, yRadius: 4 * u).fill()
        }
        if tw > 0 {
            let pic = CGRect(x: x, y: y, width: tw, height: tw * 9 / 16)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: pic, xRadius: 3 * u, yRadius: 3 * u).addClip()
            if let img = s.picture, img.size.width > 0, img.size.height > 0 {
                let k = max(pic.width / img.size.width, pic.height / img.size.height)
                let dw = img.size.width * k, dh = img.size.height * k
                img.draw(in: CGRect(x: pic.midX - dw / 2, y: pic.midY - dh / 2, width: dw, height: dh), from: .zero,
                         operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            } else {   // none: the news door's mosaic (dim while a picture is on its way)
                mosaic(pic, i, sectionColor(s.section), s.hasPicture)
            }
            NSGraphicsContext.restoreGraphicsState()
            x += tw + 10 * u
        }
        let tagF = font(true, Self.wireTagSize)
        let tag = Self.text(Self.wireSection(s.section), tagF, sectionColor(s.section))
        tag.draw(at: CGPoint(x: x, y: y))
        let tagW = tag.size().width
        let meta = Self.text("  " + (s.source.isEmpty ? "" : s.source + " · ") + Self.wireAgo(s.published),
                             font(false, Self.wireTagSize), wcol(4))
        meta.draw(with: CGRect(x: x + tagW, y: y, width: max(textW - tagW, 10), height: tag.size().height),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        let head = wireHeadline(s, i == wireHover ? 0xFFFFFF : wcol(3))
        let top = y + ceil(tagF.ascender - tagF.descender) + 3 * u
        head.draw(with: CGRect(x: x, y: top, width: textW, height: wireHeadlineH(head, textW)),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    /// The story under p, or -1.
    private func wireAt(_ p: CGPoint) -> Int {
        guard let w = wire, !wireList.isEmpty, wireList.contains(p) else { return -1 }
        let loops = wireLoop - 18 * u > wireList.height
        var ly = p.y - wireList.minY + wireOff
        if loops {
            ly = ly.truncatingRemainder(dividingBy: wireLoop)
        }
        return w.stories.firstIndex { ly >= $0.y - 4 * u && ly < $0.y + $0.h + 4 * u } ?? -1
    }

    /// The pointer moved: true when it is over the panel (the menu's own hover leaves it alone).
    func wireMove(_ p: CGPoint) -> Bool {
        wireMouse = p
        if widgetMove(p) {   // a widget's button, or the weather
            return true
        }
        guard !wireBox.isEmpty, wireBox.contains(p) else {
            if wireHover >= 0 {
                wireHover = -1
                redraw()
            }
            return false
        }
        let i = wireAt(p)
        if i >= 0 {
            NSCursor.pointingHand.set()
        }
        if i != wireHover {
            wireHover = i
            redraw()
        }
        return true
    }

    /// A click: true when it was on the panel (a story opens in the board's news door).
    func wireClick(_ p: CGPoint) -> Bool {
        if widgetClick(p) {   // a widget's button, or the weather
            return true
        }
        guard !wireBox.isEmpty, wireBox.contains(p) else { return false }
        let i = wireAt(p)
        if i >= 0 && !waiting && complete {
            waiting = true
            reply("Wire;i=\(i)")
            redraw()
        }
        return true
    }

    /// The wheel: true when the pointer is over the panel (it scrolls the stories, then they move on their own again
    /// after a few seconds).
    func wireWheel(_ event: NSEvent) -> Bool {
        let p = convert(event.locationInWindow, from: nil)
        if !wxBox.isEmpty && wxBox.contains(p) {
            return true   // the weather doesn't scroll
        }
        if gadgetWheel(p, event) {   // a scene gadget's scrolls, lists and sliders (version 6: sWheelIn)
            return true
        }
        guard !wireBox.isEmpty, wireBox.contains(p) else { return false }
        wireOff -= event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 48 * u
        wireHeld = Date().addingTimeInterval(4)
        wireHover = wireAt(p)
        redraw()
        return true
    }
}

// MARK: - Widgets: the column, the buttons, the weather

/// The weather widget (MU_S_WEATHER; a port of TERMinator-Windows Controls/RainwireWidgets.cs; Rainwire docs/MENU_GFX.md
/// "Widgets"): under the news panel in the column over the right of the header, smaller. Each widget has a close and
/// an expand button on its top border; closing one gives the other the column, expanding makes it twice as wide (both
/// for the call). A click on the weather says Widget;w=weather (the board opens its weather door).
/// A scene gadget (Rainwire docs/GADGETS.md, docs/SCENES_V6.md "The gadget engine"): its head (slot 0-15; flags 1
/// close, 2 expand, 4 click, 8 collapse, 16 move, 32 resize, 64 keep, 128 tray; share of the column; name; title) and
/// its scene tree (RainwireScene.swift reads its wrapped scene packets into it); version 6: its size as last reported.
final class SGadgetM {
    var slot = 0, weight = 1
    var flags: UInt8 = 0
    var name = "", title = ""
    var tree: RainwireMenuView.SceneTree?
    var box = CGRect.zero
    var sizeCur: (w: CGFloat, h: CGFloat) = (-1, -1)   // GadgetSize: its scene space as last measured
    var sizeAt = Date.distantPast
    var sizePending = false
    var ready: Bool { tree.map { $0.got >= $0.want } ?? false }
}

/// Where a widget or gadget goes (version 6, GadgetPlace): a dock (0 right, 1 left, 2 floating, 3 the tray), its order
/// there (-1: its slot's), a floating box or a column's width and its height share (shares of the menu's area or the
/// header), and whether it's collapsed to its title.
final class GPlace {
    var dock: UInt8 = 0
    var order = -1
    var x: CGFloat = 0, y: CGFloat = 0, w: CGFloat = 0, h: CGFloat = 0
    var collapsed = false

    func copy() -> GPlace {
        let p = GPlace()
        p.dock = dock
        p.order = order
        p.x = x
        p.y = y
        p.w = w
        p.h = h
        p.collapsed = collapsed
        return p
    }
}

/// A menu item's action as a closure (the gadgets' context menu): NSMenuItem keeps it as its representedObject.
final class RwMenuAction: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire() { run() }
}

final class WxPanel {
    var kind = 0, width = 22
    var day = true
    var colors = [UInt32](repeating: 0, count: 10)   // MU_WC_*; 6..9: sun, rain, snow, storm
    var title = "", place = "", temp = "", cond = "", line1 = "", line2 = ""
    var days: [(kind: Int, pop: Int, name: String, hi: String, lo: String)] = []
}

extension RainwireMenuView {
    private static let wkMostly = 1, wkPartly = 2, wkCloudy = 3, wkFog = 4, wkDrizzle = 5, wkHeavy = 7, wkFreeze = 8,
                       wkSnow = 9, wkHeavySnow = 10, wkThunder = 11

    /// MU_S_WEATHER. Every read is bounds-checked.
    func onWeather(_ p: [UInt8]) {
        func u8(_ o: Int) -> Int { o >= 0 && o < p.count ? Int(p[o]) : 0 }
        func u32(_ o: Int) -> UInt32 { UInt32(u8(o)) | UInt32(u8(o + 1)) << 8 | UInt32(u8(o + 2)) << 16 | UInt32(u8(o + 3)) << 24 }
        var o = 12
        func str() -> String {
            let n = u8(o)
            o += 1
            let m = max(0, min(n, p.count - o))
            guard o <= p.count else { return "" }
            let s = String(decoding: p[o..<(o + m)], as: UTF8.self)
            o += m
            return s
        }
        guard p.count >= 12 else { return }
        let w = WxPanel()
        w.kind = min(u8(4), Self.wkThunder)
        w.day = u8(5) != 0
        let days = u8(6), colors = u8(7)
        w.width = min(max(u8(8), 15), 50)
        for i in 0..<colors {
            if i < w.colors.count {
                w.colors[i] = u32(o) & 0xFF_FFFF
            }
            o += 4
        }
        w.title = str()
        w.place = str()
        w.temp = str()
        w.cond = str()
        w.line1 = str()
        w.line2 = str()
        for _ in 0..<days where o + 4 <= p.count {
            let k = min(u8(o), Self.wkThunder), pop = u8(o + 1)
            o += 4
            let name = str(), hi = str(), lo = str()
            w.days.append((k, pop == 255 ? -1 : pop, name, hi, lo))
        }
        wx = w
        needsLayout = true
        redraw()
    }

    // ================================================================
    // The gadget engine (version 6): a port of TERMinator-Windows Controls/RainwireGadgets.cs (Rainwire
    // docs/SCENES_V6.md "The gadget engine"), written 2026-11-02 without a Mac (uncompiled). Gadgets are small scenes
    // beside a menu, drawn by RainwireScene.swift into their boxes, with the news panel and the weather:
    //   - the board places each (GadgetPlace): the column over the right or left of the header, in an order, or a box
    //     floating anywhere over the menu screen (shares of it), or the tray only; news and weather take places too;
    //   - the caller drags one by its title (reorder, dock in the other column, float), resizes it (a floating one by
    //     its corner, a docked one's height by its bottom edge), collapses it to its title, and has a right-click menu;
    //     each change says GadgetMoved;g=;dock=;order=;x=;y=;w=;h=;collapsed= (Reset: GadgetReset);
    //   - GadgetState: collapse, expand, a count on the title, the title pulsing for attention, removal;
    //   - GF_KEEP gadgets stay across menus; GF_TRAY ones also show as pills on the status bar while no menu is up,
    //     opening as a popover there, drawn but quiet (trayQuiet: the board may be in a door);
    //   - GadgetSize;g=;w=;h= when a gadget's box changes; a click on a field in one gives it the keys until Esc.
    // macOS differences: the move cursor is the open/closed hand (AppKit has no SizeAll) and a floating gadget's corner
    // grip shows the crosshair (no public diagonal resize cursor); the context menu is an NSMenu popped up at the
    // pointer; the tray is RainwireTrayView in TerminalView's SwiftUI status bar (RainwireTrayLayer) with an NSPopover.
    // ================================================================

    static let gfClose: UInt8 = 0x01, gfExpand: UInt8 = 0x02, gfClick: UInt8 = 0x04, gfCollapse: UInt8 = 0x08,
               gfMove: UInt8 = 0x10, gfResize: UInt8 = 0x20, gfKeep: UInt8 = 0x40, gfTray: UInt8 = 0x80
    static let gadgetSlots = 16
    static let dockRight: UInt8 = 0, dockLeft: UInt8 = 1, dockFloat: UInt8 = 2, dockTray: UInt8 = 3
    static let plCollapsed: UInt8 = 0x01
    static let stAttention: UInt8 = 0x01, stCollapse: UInt8 = 0x02, stExpand: UInt8 = 0x04, stRemove: UInt8 = 0x08
    static let slotNews = 0xFE, slotWeather = 0xFF

    /// A gadget's title strip or edge being dragged: which, moving or resizing, from where, its box then, and the box
    /// it would take now (drawn as a ghost).
    struct GDrag {
        let name: String
        let resize: Bool
        let from: CGPoint
        let start: CGRect
        var ghost: CGRect
        var moved: Bool
    }

    /// One widget or gadget to place this frame.
    struct GEntry {
        let name: String
        let weight: Int
        let defOrder: Int
        let set: (CGRect) -> Void
    }

    private static func gR(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x, y: y, width: max(w, 0), height: max(h, 0))
    }

    private static func g3(_ v: CGFloat) -> String { String(format: "%.3f", Double(v.isFinite ? v : 0)) }

    private static func gLE32(_ p: [UInt8], _ o: Int) -> UInt32 {
        guard o >= 0, o + 4 <= p.count else { return 0 }
        return UInt32(p[o]) | UInt32(p[o + 1]) << 8 | UInt32(p[o + 2]) << 16 | UInt32(p[o + 3]) << 24
    }

    /// A widget's buttons and what the caller may do with it: news and weather may do all of it.
    func widgetFlags(_ name: String) -> UInt8 {
        if name == "news" || name == "weather" {
            return Self.gfClose | Self.gfExpand | Self.gfCollapse | Self.gfMove | Self.gfResize
        }
        return gadgets.values.first { $0.name == name }?.flags ?? 0
    }

    func placeOf(_ name: String) -> GPlace {
        if let p = gPlace[name] {
            return p
        }
        let p = GPlace()
        gPlace[name] = p
        return p
    }

    func collapsedW(_ name: String) -> Bool { gPlace[name]?.collapsed ?? false }

    // ================================================================
    // Messages from the board
    // ================================================================

    /// A scene gadget's head (Gadget): slot, flags, weight, name and title lengths, 3 reserved, name, title. Its scene
    /// follows. Version 6: 16 slots; a gadget of the same name in another slot goes.
    func onGadget(_ p: [UInt8]) {
        guard p.count >= 12, Int(p[4]) < Self.gadgetSlots else { return }
        let nl = Int(p[7]), tl = Int(p[8])
        guard 12 + nl + tl <= p.count, nl > 0 else { return }
        let g = SGadgetM()
        g.slot = Int(p[4])
        g.flags = p[5]
        g.weight = min(max(Int(p[6]), 1), 100)
        g.name = String(decoding: p[12..<(12 + nl)], as: UTF8.self)
        g.title = String(decoding: p[(12 + nl)..<(12 + nl + tl)], as: UTF8.self)
        for other in gadgets.values where other.name == g.name && other.slot != g.slot {
            gadgets[other.slot] = nil
        }
        gadgets[g.slot] = g
        trayUpdate()
        redraw()
    }

    /// The name a GadgetPlace or GadgetState slot means: news, weather or a scene gadget's (nil: none).
    private func slotName(_ slot: Int) -> String? {
        slot == Self.slotNews ? "news" : slot == Self.slotWeather ? "weather" : gadgets[slot]?.name
    }

    /// GadgetPlace: slot, dock, order, flags, then x, y, w, h (f32 shares).
    func onGadgetPlace(_ p: [UInt8]) {
        guard p.count >= 24, let name = slotName(Int(p[4])) else { return }
        func f(_ o: Int) -> CGFloat {
            let v = Float(bitPattern: Self.gLE32(p, o))
            return v.isFinite ? min(max(CGFloat(v), 0), 1) : 0
        }
        let pl = GPlace()
        pl.dock = min(p[5], Self.dockTray)
        pl.order = Int(p[6])
        pl.collapsed = p[7] & Self.plCollapsed != 0
        pl.x = f(8)
        pl.y = f(12)
        pl.w = f(16)
        pl.h = f(20)
        gPlace[name] = pl
        gBoard[name] = pl.copy()
        trayUpdate()
        needsLayout = true
        redraw()
    }

    /// GadgetState: slot, flags (attention, collapse, expand, remove), the count on its title and its color.
    func onGadgetState(_ p: [UInt8]) {
        guard p.count >= 16, let name = slotName(Int(p[4])) else { return }
        let f = p[5]
        if f & Self.stRemove != 0 && Int(p[4]) < Self.gadgetSlots {
            gadgets[Int(p[4])] = nil
            if gFocus?.name == name {
                gFocus = nil
            }
        }
        if f & Self.stCollapse != 0 {
            placeOf(name).collapsed = true
        }
        if f & Self.stExpand != 0 {
            placeOf(name).collapsed = false
        }
        let attn = f & Self.stAttention != 0 || (gState[name]?.attn ?? false)   // until the caller looks
        gState[name] = (Self.gLE32(p, 8), Self.gLE32(p, 12), attn)
        trayUpdate()
        needsLayout = true
        redraw()
    }

    /// A new menu: its gadgets come with it; kept ones (GF_KEEP, GF_TRAY) stay until the board removes them. The keys
    /// go back to the new menu.
    func gadgetsForMenu() {
        for g in Array(gadgets.values) where g.flags & (Self.gfKeep | Self.gfTray) == 0 {
            gadgets[g.slot] = nil
        }
        gFocus = nil
        trayUpdate()
    }

    /// The call ended: every widget open, narrow and where the board puts it; no gadgets.
    func widgetsForget() {
        gClosed.removeAll()
        gWide.removeAll()
        gadgets.removeAll()
        gPlace.removeAll()
        gBoard.removeAll()
        gState.removeAll()
        gMovedLater.removeAll()
        gFocus = nil
        gDrag = nil
        trayClose()
        trayUpdate()
    }

    // ================================================================
    // Layout: the columns and the floating boxes
    // ================================================================

    /// Places every widget and gadget (header hr, the menu's area gArea): the right and left columns, each in order,
    /// sharing their height by weight (a collapsed one only its title strip); floating ones in their boxes. Sets
    /// wireBox, wxBox, each gadget's box and the collapsed strips (.zero for one not drawn).
    func widgetLayout(_ hr: CGRect) {
        wireBox = .zero
        wxBox = .zero
        gStrips.removeAll()
        gPills.removeAll()
        for g in gadgets.values {
            g.box = .zero
        }
        guard complete, !isNews, !isPage, !isList, !isForm, !isPic, !isScene else { return }
        var all: [GEntry] = []
        if wire != nil && !gClosed.contains("news") {
            all.append(GEntry(name: "news", weight: 66, defOrder: 0, set: { self.wireBox = $0 }))
        }
        if wx != nil && !gClosed.contains("weather") {
            all.append(GEntry(name: "weather", weight: 34, defOrder: 1, set: { self.wxBox = $0 }))
        }
        for slot in gadgets.keys.sorted() {
            if let g = gadgets[slot], g.ready, !gClosed.contains(g.name) {
                all.append(GEntry(name: g.name, weight: g.weight, defOrder: 2 + g.slot, set: { g.box = $0 }))
            }
        }
        guard !all.isEmpty else { return }
        // collapsed ones go to the status bar as pills (sysop 2026-11-02: "when minimized maybe it makes sense for them
        // to go to the Rainwire bar at the bottom of the screen"); with no bar, a strip where they were
        if st.status && !gArea.isEmpty {
            statusPills(all.filter { collapsedW($0.name) }.map { $0.name })
            all = all.filter { !collapsedW($0.name) }
        }
        func order(_ e: GEntry) -> Int {
            if let p = gPlace[e.name], p.order >= 0 {
                return p.order
            }
            return e.defOrder
        }
        for dock in [Self.dockRight, Self.dockLeft] {
            let col = all.filter { (gPlace[$0.name]?.dock ?? Self.dockRight) == dock }
                .sorted { a, b in order(a) != order(b) ? order(a) < order(b) : a.defOrder < b.defOrder }
            if !col.isEmpty && !hr.isEmpty {
                layoutColumn(hr, col, dock == Self.dockLeft)
            }
        }
        for e in all {
            guard let p = gPlace[e.name], p.dock == Self.dockFloat, !gArea.isEmpty else { continue }
            let a = gArea
            let w = min(max(p.w > 0 ? p.w * a.width : 220 * u, 110 * u), a.width)
            let h = min(max(p.h > 0 ? p.h * a.height : 160 * u, 60 * u), a.height)
            let x = min(max(a.minX + p.x * a.width, a.minX), a.maxX - w)
            let y = min(max(a.minY + p.y * a.height, a.minY + 10 * u), max(a.maxY - h, a.minY + 10 * u))
            if p.collapsed {
                gStrips.append((e.name, Self.gR(x, y, w, stripH)))
            } else {
                e.set(Self.gR(x, y, w, h))
            }
        }
    }

    var stripH: CGFloat { 24 * u }

    /// A column over the right (or left) of the header: each its weight's share of the height (its place's h share
    /// when the caller sized it), a collapsed one its title strip, an expanded one twice as wide.
    private func layoutColumn(_ hr: CGRect, _ col: [GEntry], _ left: Bool) {
        let pct: CGFloat
        if let p0 = gPlace[col[0].name], p0.w > 0 {
            pct = p0.w * 100
        } else {
            pct = CGFloat(wire?.width ?? wx?.width ?? 22)
        }
        // room above each for its buttons, which sit on its top border
        let inset = 8 * u, gap = 18 * u, cw = hr.width * pct / 100
        let top = hr.minY + 14 * u, h = hr.height - 14 * u - inset
        let open = col.filter { !collapsedW($0.name) }.count
        let strips = CGFloat(col.count - open) * stripH
        let avail = h - gap * CGFloat(col.count - 1) - strips
        if (open > 0 && avail < 60 * u * CGFloat(open)) || cw < 110 * u {
            return   // too cramped to read: the header alone
        }
        // a height the caller dragged (h: its share of the column's room, at least 15%) first; the rest share what's
        // left by weight (sysop 2026-11-02: a float's own height, kept as its column share, docked the weather tiny)
        func share(_ e: GEntry) -> CGFloat {
            if let p = gPlace[e.name], p.h > 0 {
                return min(max(p.h, 0.15), 0.9)
            }
            return 0
        }
        let opened = col.filter { !collapsedW($0.name) }
        let fixedSum = opened.reduce(CGFloat(0)) { $0 + share($1) }
        let weights = opened.filter { share($0) == 0 }.reduce(CGFloat(0)) { $0 + CGFloat($1.weight) }
        let scale: CGFloat = weights > 0 ? min(1, 0.85 / max(fixedSum, 1e-9)) : 1 / max(fixedSum, 1e-9)
        let rest = max(1 - fixedSum * scale, 0)
        var y = top
        for e in col {
            let w = min(cw * (gWide.contains(e.name) ? 2 : 1), hr.width - 2 * inset) - inset
            let x = left ? hr.minX + inset * 2 : hr.maxX - inset - w
            if collapsedW(e.name) {
                gStrips.append((e.name, Self.gR(x, y, w, stripH)))
                y += stripH + gap
                continue
            }
            let hh = share(e) > 0 ? avail * share(e) * scale : weights > 0 ? avail * rest * CGFloat(e.weight) / weights : avail
            e.set(Self.gR(x, y, w, hh))
            y += hh + gap
        }
    }

    // ================================================================
    // The buttons on a widget's top border: close, expand, collapse (right to left)
    // ================================================================

    private static let btnFlags: [UInt8] = [gfClose, gfExpand, gfCollapse]

    private static func hasBtn(_ btn: Int, _ flags: UInt8, _ strip: Bool) -> Bool {
        flags & btnFlags[btn] != 0 && !(strip && btn == 1)
    }

    private func widgetButton(_ box: CGRect, _ btn: Int, _ flags: UInt8, _ strip: Bool) -> CGRect {
        let s = 14 * u
        var x = box.maxX - 12 * u - s
        for i in 0..<btn where Self.hasBtn(i, flags, strip) {
            x -= s + 5 * u
        }
        return CGRect(x: x, y: strip ? box.minY + (box.height - s) / 2 : box.minY - s / 2, width: s, height: s)
    }

    /// A widget's buttons (those its flags have: close, expand, collapse), on its top border at the right (a strip's:
    /// inside it).
    func drawWidgetButtons(_ box: CGRect, _ name: String, _ flags: UInt8, _ bg: UInt32, _ border: UInt32, _ fg: UInt32,
                           strip: Bool = false) {
        for btn in 0..<3 where Self.hasBtn(btn, flags, strip) {
            let b = widgetButton(box, btn, flags, strip)
            let hot = widgetBtnHot.map { $0.w == name && $0.btn == btn } ?? false
            let path = NSBezierPath(roundedRect: b, xRadius: 4 * u, yRadius: 4 * u)
            Self.color(hot ? Self.mix(bg, border, 0.5) : bg, hot ? 1 : 240.0 / 255).setFill()
            path.fill()
            Self.color(hot ? fg : border).setStroke()
            path.lineWidth = max(1, 1.2 * u)
            path.stroke()
            let g = NSBezierPath()
            g.lineWidth = 1.4 * u
            g.lineCapStyle = .round
            g.lineJoinStyle = .round
            let cx = b.midX, cy = b.midY, a = 3 * u
            switch btn {
            case 0:
                g.move(to: CGPoint(x: cx - a, y: cy - a))
                g.line(to: CGPoint(x: cx + a, y: cy + a))
                g.move(to: CGPoint(x: cx - a, y: cy + a))
                g.line(to: CGPoint(x: cx + a, y: cy - a))
            case 1:   // two chevrons pointing out (expand) or in (back to narrow)
                let d: CGFloat = gWide.contains(name) ? -1 : 1, e = 1.5 * u
                for side: CGFloat in [-1, 1] {
                    let tip = cx + side * (e + 2 * u) * d, back = tip - side * 2.5 * u * d
                    g.move(to: CGPoint(x: back, y: cy - 3 * u))
                    g.line(to: CGPoint(x: tip, y: cy))
                    g.line(to: CGPoint(x: back, y: cy + 3 * u))
                }
            default:   // a chevron: down to collapse to the status bar (up with no bar), down to open a strip again
                let d: CGFloat = strip || st.status ? 1 : -1
                g.move(to: CGPoint(x: cx - a, y: cy - d * 1.5 * u))
                g.line(to: CGPoint(x: cx, y: cy + d * 1.5 * u))
                g.line(to: CGPoint(x: cx + a, y: cy - d * 1.5 * u))
            }
            Self.color(fg).setStroke()
            g.stroke()
        }
    }

    /// Every widget drawn now: its name, box, button flags, and whether it's a collapsed strip.
    func widgetBoxes() -> [(name: String, box: CGRect, flags: UInt8, strip: Bool)] {
        var out: [(name: String, box: CGRect, flags: UInt8, strip: Bool)] = []
        if !wireBox.isEmpty {
            out.append(("news", wireBox, widgetFlags("news"), false))
        }
        if !wxBox.isEmpty {
            out.append(("weather", wxBox, widgetFlags("weather"), false))
        }
        for slot in gadgets.keys.sorted() {
            if let g = gadgets[slot], !g.box.isEmpty {
                out.append((g.name, g.box, g.flags, false))
            }
        }
        for s in gStrips {
            out.append((s.name, s.box, widgetFlags(s.name), true))
        }
        return out
    }

    private func widgetButtonAt(_ p: CGPoint) -> (w: String, btn: Int)? {
        for w in widgetBoxes() {
            for btn in 0..<3 where Self.hasBtn(btn, w.flags, w.strip) && widgetButton(w.box, btn, w.flags, w.strip).contains(p) {
                return (w.name, btn)
            }
        }
        return nil
    }

    /// The title strip a drag starts from (the band its title sits on).
    private func titleBand(_ box: CGRect, _ strip: Bool) -> CGRect {
        strip ? box : Self.gR(box.minX, box.minY - 9 * u, box.width, 22 * u)
    }

    /// The grip or title band under p: which widget, resizing or moving, its box.
    private func grabAt(_ p: CGPoint) -> (name: String, resize: Bool, box: CGRect)? {
        for w in widgetBoxes().reversed() {
            let floating = gPlace[w.name]?.dock == Self.dockFloat
            if !w.strip && w.flags & Self.gfResize != 0 {
                let grip = floating ? Self.gR(w.box.maxX - 14 * u, w.box.maxY - 14 * u, 16 * u, 16 * u)
                                    : Self.gR(w.box.minX, w.box.maxY - 4 * u, w.box.width, 9 * u)
                if grip.contains(p) {
                    return (w.name, true, w.box)
                }
            }
            if w.flags & Self.gfMove != 0 && titleBand(w.box, w.strip).contains(p) {
                return (w.name, false, w.box)
            }
        }
        return nil
    }

    func gadgetAt(_ p: CGPoint) -> SGadgetM? {
        gadgets.keys.sorted().compactMap { gadgets[$0] }.first { !$0.box.isEmpty && $0.box.contains(p) }
    }

    // ================================================================
    // The pointer over the widgets: hover, clicks, drags, the wheel, keys
    // ================================================================

    /// The pointer over a widget's button, the weather or a scene gadget: true when it's theirs (hover, the hand over
    /// what a click does, the sizing cursors over a grip).
    func widgetMove(_ p: CGPoint) -> Bool {
        if gDrag != nil {
            return true
        }
        let btn = widgetButtonAt(p)
        let overWx = btn == nil && !wxBox.isEmpty && wxBox.contains(p)
        let g = btn == nil && !overWx ? gadgetAt(p) : nil
        let same = (btn == nil && widgetBtnHot == nil)
            || (btn != nil && widgetBtnHot != nil && btn!.w == widgetBtnHot!.w && btn!.btn == widgetBtnHot!.btn)
        if !same || overWx != wxHot {
            widgetBtnHot = btn
            wxHot = overWx
            redraw()
        }
        // pointing at one ends its call for attention
        for w in widgetBoxes() where w.box.contains(p) {
            if let st = gState[w.name], st.attn {
                gState[w.name] = (st.badge, st.color, false)
                redraw()
            }
        }
        if let pill = pillAt(p) {   // a collapsed one's pill on the status bar: a click opens it
            if let st = gState[pill], st.attn {
                gState[pill] = (st.badge, st.color, false)
            }
            NSCursor.pointingHand.set()
            overWidget = true
            redraw()
            return true
        }
        let grab = btn == nil ? grabAt(p) : nil
        let strip = gStrips.contains { $0.box.contains(p) }
        guard btn != nil || overWx || g != nil || grab != nil || strip else {
            overWidget = false
            return false
        }
        var cur: NSCursor? = btn != nil || overWx ? NSCursor.pointingHand : nil
        if cur == nil, let gr = grab {
            cur = !gr.resize ? NSCursor.openHand : gPlace[gr.name]?.dock == Self.dockFloat ? NSCursor.crosshair : NSCursor.resizeUpDown
        }
        if cur == nil, let g = g, g.tree != nil {
            cur = gadgetCursor(g, p)   // RainwireScene.swift: its Move events, dividers, fields, controls
        }
        (cur ?? .arrow).set()
        overWidget = true
        return true
    }

    /// The left button down at p over the widgets: a title strip or grip starts a drag; a scroll bar, divider or slider
    /// in a gadget starts its own. True when one started (no click follows).
    func gadgetDown(_ p: CGPoint) -> Bool {
        if widgetButtonAt(p) != nil {
            return false
        }
        if let gr = grabAt(p) {
            gDrag = GDrag(name: gr.name, resize: gr.resize, from: p, start: gr.box, ghost: gr.box, moved: false)
            return true
        }
        if let g = gadgetAt(p), g.tree != nil, gadgetSceneDown(g, p) {
            gFocus = g
            return true
        }
        return false
    }

    /// A widget being dragged: its ghost follows the pointer. True while one is.
    func gadgetDragMove(_ p: CGPoint) -> Bool {
        guard var d = gDrag else { return false }
        if NSEvent.pressedMouseButtons & 1 == 0 {
            _ = gadgetDragEnd(p)
            return true
        }
        let dx = p.x - d.from.x, dy = p.y - d.from.y
        let moved = d.moved || abs(dx) + abs(dy) > 5 * u
        let r = d.start
        let floating = gPlace[d.name]?.dock == Self.dockFloat
        let ghost: CGRect
        if !d.resize {
            ghost = r.offsetBy(dx: dx, dy: dy)
        } else if floating {
            ghost = Self.gR(r.minX, r.minY, max(r.width + dx, 110 * u), max(r.height + dy, 60 * u))
        } else {
            ghost = Self.gR(r.minX, r.minY, r.width, max(r.height + dy, 60 * u))
        }
        d.ghost = ghost
        d.moved = moved
        gDrag = d
        (d.resize ? (floating ? NSCursor.crosshair : NSCursor.resizeUpDown) : NSCursor.closedHand).set()
        redraw()
        return true
    }

    /// The drag let go: where the ghost is decides the place (a column's side docks it there at that place in its
    /// order; elsewhere it floats); a resize sets its box or its share of the column. Not moved: a click (false).
    func gadgetDragEnd(_ p: CGPoint) -> Bool {
        guard let d = gDrag else { return false }
        gDrag = nil
        NSCursor.arrow.set()
        guard d.moved else {
            redraw()
            return false   // a press and release in place: a click on its title (GF_CLICK opens its door)
        }
        let pl = placeOf(d.name)
        let a = gArea.isEmpty ? bounds : gArea
        let g = d.ghost
        let hr = headerRect(bounds.width, bounds.height)
        if d.resize {
            if pl.dock == Self.dockFloat {
                pl.w = g.width / max(a.width, 1)
                pl.h = g.height / max(a.height, 1)
            } else {   // its share of the column's room: what the open ones in it take now
                let room = widgetBoxes().filter { !$0.strip && (gPlace[$0.name]?.dock ?? Self.dockRight) == pl.dock }
                    .reduce(CGFloat(0)) { $0 + $1.box.height }
                pl.h = min(max(g.height / max(room, 1), 0.15), 0.9)
            }
            gadgetMovedSay(d.name)
        } else {
            let cx = g.midX, cy = g.midY
            let colW = hr.width * CGFloat(wire?.width ?? wx?.width ?? 22) / 100
            var dock = Self.dockFloat
            if !hr.isEmpty && cy >= hr.minY && cy <= hr.maxY + 20 * u {
                if cx >= hr.maxX - colW {
                    dock = Self.dockRight
                } else if cx <= hr.minX + colW {
                    dock = Self.dockLeft
                }
            }
            if dock == Self.dockFloat {
                pl.dock = Self.dockFloat
                pl.x = min(max((g.minX - a.minX) / max(a.width, 1), 0), 1)
                pl.y = min(max((g.minY - a.minY) / max(a.height, 1), 0), 1)
                if pl.w <= 0 || pl.h <= 0 {
                    pl.w = g.width / max(a.width, 1)
                    pl.h = g.height / max(a.height, 1)
                }
                gadgetMovedSay(d.name)
            } else {
                redock(d.name, dock, cy)
            }
        }
        wireLaidW = -1   // the news list's width may change
        needsLayout = true
        redraw()
        return true
    }

    /// name docked in a column at height y among the others there: every one in that column renumbered (and told to
    /// the board, as each order changed).
    private func redock(_ name: String, _ dock: UInt8, _ y: CGFloat) {
        let pl = placeOf(name)
        let others = widgetBoxes().filter { $0.name != name && (gPlace[$0.name]?.dock ?? Self.dockRight) == dock }
            .sorted { $0.box.minY < $1.box.minY }
        let at = others.filter { $0.box.minY + $0.box.height / 2 < y }.count
        var order = others.map { $0.name }
        order.insert(name, at: min(at, order.count))
        if pl.dock != dock {   // a floating box's size means nothing in a column: its usual height there
            pl.w = 0
            pl.h = 0
        }
        pl.dock = dock
        for (i, n) in order.enumerated() {
            let op = placeOf(n)
            if op.dock != dock || op.order != i || n == name {
                op.dock = dock
                op.order = i
                gadgetMovedSay(n)
            }
        }
    }

    /// GadgetMoved for name as it's placed now (kept until the next Show while no menu is up).
    func gadgetMovedSay(_ name: String) {
        let pl = placeOf(name)
        let msg = "GadgetMoved;g=\(name);dock=\(pl.dock);order=\(max(pl.order, 0));x=\(Self.g3(pl.x));y=\(Self.g3(pl.y));"
            + "w=\(Self.g3(pl.w));h=\(Self.g3(pl.h));collapsed=\(pl.collapsed ? 1 : 0)"
        if isUp {
            sendRaw(msg)
        } else {
            gMovedLater.removeAll { $0.hasPrefix("GadgetMoved;g=\(name);") }
            gMovedLater.append(msg)
        }
        trayUpdate()
    }

    /// The menu came up: the moves made while it was down go to the board.
    func gadgetMovesFlush() {
        for m in gMovedLater {
            sendRaw(m)
        }
        gMovedLater.removeAll()
    }

    /// A click on a widget's button (close, expand or collapse it), the weather (its door), or a scene gadget (a
    /// control in it, else its own click): true when it was one of theirs.
    func widgetClick(_ p: CGPoint) -> Bool {
        if let b = widgetButtonAt(p) {
            switch b.btn {
            case 0:   // closed here at once, and off on the board (news and weather in their doors)
                gClosed.insert(b.w)
                reply("WidgetOff;w=" + b.w)
            case 1:
                if gWide.contains(b.w) {
                    gWide.remove(b.w)
                } else {
                    gWide.insert(b.w)
                }
            default:
                placeOf(b.w).collapsed = !collapsedW(b.w)
                gadgetMovedSay(b.w)
            }
            widgetBtnHot = nil
            wireLaidW = -1   // the news list's width changes
            NSCursor.arrow.set()
            needsLayout = true
            redraw()
            return true
        }
        if let pill = pillAt(p) {   // a pill on the status bar: open again where it was
            placeOf(pill).collapsed = false
            gadgetMovedSay(pill)
            needsLayout = true
            redraw()
            return true
        }
        if gStrips.contains(where: { $0.box.contains(p) }) {
            return true   // a collapsed one's title: its buttons open it
        }
        if !wxBox.isEmpty && wxBox.contains(p) {
            if !waiting && complete {
                waiting = true
                reply("Widget;w=weather")
                redraw()
            }
            return true
        }
        guard let g = gadgetAt(p) else {
            gFocus = nil   // a click outside the gadgets: the keys go back to the menu
            return false
        }
        wireMouse = p
        if !gadgetSceneClick(g, p) && g.flags & Self.gfClick != 0 && !waiting && complete {
            waiting = true
            reply("Widget;w=" + g.name)
        }
        redraw()
        return true
    }

    /// A right-click on a widget's title or strip: the client's own menu for it. True when it was one.
    func widgetRightClick(_ p: CGPoint) -> Bool {
        for w in widgetBoxes() + gPills.map({ (name: $0.name, box: $0.box, flags: widgetFlags($0.name), strip: true) }) {
            if !titleBand(w.box, w.strip).contains(p) && !(w.strip && w.box.contains(p)) {
                continue
            }
            let name = w.name, box = w.box, flags = w.flags
            let menu = NSMenu()
            menu.autoenablesItems = false
            func item(_ label: String, _ enabled: Bool, _ act: @escaping () -> Void) {
                let a = RwMenuAction { [weak self] in
                    act()
                    self?.needsLayout = true
                    self?.redraw()
                }
                let mi = NSMenuItem(title: label, action: #selector(RwMenuAction.fire), keyEquivalent: "")
                mi.target = a
                mi.representedObject = a   // the item keeps its action alive (target is weak)
                mi.isEnabled = enabled
                menu.addItem(mi)
            }
            let pl = placeOf(name)
            if flags & Self.gfCollapse != 0 {
                item(pl.collapsed ? "Expand" : "Collapse", true) { [unowned self] in
                    pl.collapsed = !pl.collapsed
                    self.gadgetMovedSay(name)
                }
            }
            if flags & Self.gfResize != 0 {   // back to its usual size: its weight's share of a column, or a float's 220 x 160
                item("Reset Size", pl.h > 0 || (pl.dock == Self.dockFloat && pl.w > 0)) { [unowned self] in
                    pl.h = 0
                    if pl.dock == Self.dockFloat {
                        pl.w = 0
                    }
                    self.gadgetMovedSay(name)
                }
            }
            if flags & Self.gfMove != 0 {
                item("Dock Right", pl.dock != Self.dockRight) { [unowned self] in
                    self.redock(name, Self.dockRight, .greatestFiniteMagnitude)
                }
                item("Dock Left", pl.dock != Self.dockLeft) { [unowned self] in
                    self.redock(name, Self.dockLeft, .greatestFiniteMagnitude)
                }
                item("Float", pl.dock != Self.dockFloat) { [unowned self] in
                    let a = self.gArea.isEmpty ? self.bounds : self.gArea
                    pl.dock = Self.dockFloat
                    pl.x = min(max((box.minX - a.minX) / max(a.width, 1), 0), 1)
                    pl.y = min(max((box.minY - a.minY) / max(a.height, 1), 0), 1)
                    pl.w = box.width / max(a.width, 1)
                    pl.h = max(box.height, 160 * self.u) / max(a.height, 1)
                    self.gadgetMovedSay(name)
                }
                if gadgets.values.contains(where: { $0.name == name && $0.flags & Self.gfTray != 0 }) {
                    item("Move to the Tray", pl.dock != Self.dockTray) { [unowned self] in
                        pl.dock = Self.dockTray
                        self.gadgetMovedSay(name)
                    }
                }
            }
            if flags & Self.gfClose != 0 {
                item("Hide", true) { [unowned self] in
                    self.gClosed.insert(name)
                    self.reply("WidgetOff;w=" + name)
                }
            }
            if !menu.items.isEmpty {
                menu.addItem(NSMenuItem.separator())
            }
            item("Reset Layout", true) { [unowned self] in
                self.gadgetReset()
            }
            _ = menu.popUp(positioning: nil, at: p, in: self)
            return true
        }
        return false
    }

    /// Reset layout: every widget where the board last put it, and the board forgets the caller's places.
    func gadgetReset() {
        gPlace.removeAll()
        for (k, v) in gBoard {
            gPlace[k] = v.copy()
        }
        gWide.removeAll()
        gMovedLater.removeAll()
        if isUp {
            sendRaw("GadgetReset")
        } else {
            gMovedLater.append("GadgetReset")
        }
        trayUpdate()
    }

    /// The wheel over a scene gadget: the scroll, list or slider under the pointer (a crawling one holds a while).
    /// True when the pointer is over a gadget.
    func gadgetWheel(_ p: CGPoint, _ event: NSEvent) -> Bool {
        guard let g = gadgetAt(p) else { return false }
        if g.tree != nil {
            wireMouse = p
            gadgetWheelIn(g, p, event)
            sceneGen += 1
            redraw()
        }
        return true
    }

    /// A key for the gadget that has the keys (a field clicked in it): its own (sceneKey takes typed text too); Esc
    /// with no pop-up open gives them back to the menu. True when it's taken (always, while one has them).
    func gadgetKey(_ event: NSEvent) -> Bool {
        guard let g = gFocus, g.tree != nil, gadgets.values.contains(where: { $0 === g }) else {
            gFocus = nil
            return false
        }
        if event.keyCode == 53 && !gadgetHasPops(g) {
            gFocus = nil
            redraw()
            return true
        }
        inGadget(g) { sceneKey(event) }
        redraw()
        return true
    }

    // ================================================================
    // Drawing
    // ================================================================

    /// The scene gadgets: each a box like the weather's in its scene's colors, the title on the top border with its
    /// count, its buttons, and its scene inside at gadgetScale; the collapsed strips; and the ghost of one being
    /// dragged.
    func drawGadgets() {
        for slot in gadgets.keys.sorted() {
            guard let g = gadgets[slot], g.ready, !g.box.isEmpty else { continue }
            drawGadget(g, g.box, true)
        }
        for s in gStrips {
            drawStrip(s.name, s.box)
        }
        for s in gPills {
            drawPill(s.name, s.box)
        }
        if let d = gDrag, d.moved {
            let a = mc(.accent)
            let path = NSBezierPath(roundedRect: d.ghost, xRadius: 8 * u, yRadius: 8 * u)
            Self.color(a, 30.0 / 255).setFill()
            path.fill()
            let dash: [CGFloat] = [6 * u, 4 * u]
            path.setLineDash(dash, count: 2, phase: 0)
            path.lineWidth = 2 * u
            Self.color(a, 220.0 / 255).setStroke()
            path.stroke()
        }
    }

    /// The colors a widget's frame takes: a gadget's scene's, the news panel's, the weather's, else the menu's.
    private func frameColors(_ name: String) -> (bg: UInt32, border: UInt32, title: UInt32) {
        if let t = gadgets.values.first(where: { $0.name == name })?.tree {
            return (t.colors[Sc.panel.rawValue], t.colors[Sc.border.rawValue], t.colors[Sc.title.rawValue])
        }
        if name == "news" && wire != nil {
            return (wcol(0), wcol(1), wcol(2))
        }
        if name == "weather" && wx != nil {
            return (xw(0), xw(1), xw(2))
        }
        return (mc(.menuBg), mc(.menuBorder), mc(.panelTitle))
    }

    private func titleOf(_ name: String) -> String {
        if let t = gadgets.values.first(where: { $0.name == name })?.title, !t.isEmpty {   // news and weather are scene gadgets from Rainwire 0.9.196
            return t
        }
        if name == "news" {
            return wire?.title ?? "News"
        }
        if name == "weather" {
            return wx?.title ?? "Weather"
        }
        return gadgets.values.first { $0.name == name }?.title ?? name
    }

    /// The title (pulsing for attention) and its count, at x on the line y; returns the x after them.
    @discardableResult
    private func drawGTitle(_ name: String, _ bg: UInt32, _ tc: UInt32, _ x: CGFloat, _ y: CGFloat, _ onBorder: Bool) -> CGFloat {
        let stt = gState[name] ?? (badge: 0, color: 0, attn: false)
        let col = stt.attn ? Self.mix(tc, mc(.accent), 0.5 + 0.5 * CGFloat(sin(nowMs / 1000 * 5))) : tc
        let tf = font(true, 12)
        let title = Self.text(titleOf(name).uppercased(), tf, col)
        var bw: CGFloat = 0
        var badge: NSAttributedString?
        if stt.badge > 0 {
            let bt = Self.text(stt.badge > 999 ? "999+" : String(stt.badge), font(true, 10.5), 0)
            badge = bt
            bw = bt.size().width + 16 * u
        }
        if onBorder && st.border > 0 {   // the border cut under it, as see-through as the panel
            Self.color(bg, st.opacity / 100 * 0.8).setFill()
            CGRect(x: x - 6 * u, y: y - (2 + st.border / 2) * u, width: title.size().width + bw + 12 * u,
                   height: (4 + st.border) * u).fill()
        }
        title.draw(at: CGPoint(x: x, y: Self.capY(tf, y)))
        var xx = x + title.size().width
        if let bt = badge {
            let bc = stt.color & 0xFF00_0000 == 0 ? stt.color : mc(.accent)
            let sz = bt.size()
            let h = sz.height + 2 * u, bx = xx + 6 * u
            Self.color(bc).setFill()
            NSBezierPath(roundedRect: CGRect(x: bx, y: y - h / 2, width: sz.width + 10 * u, height: h), xRadius: h / 2,
                         yRadius: h / 2).fill()
            bt.draw(at: CGPoint(x: bx + 5 * u, y: y - sz.height / 2))
            xx = bx + sz.width + 10 * u
        }
        return xx
    }

    /// A collapsed widget: a strip with its title, count and buttons.
    /// The collapsed widgets' pills on the status bar, after its title, as many as fit before its right end.
    private func statusPills(_ names: [String]) {
        guard !names.isEmpty else { return }
        let sh = statusH * u, y = gArea.maxY, ph = sh - 8 * u
        let bf = font(true, 13), f = font(false, 13)
        let mins = minutes != 0xFFFF ? " \u{00B7} \(minutes)m left" : ""
        let right = gArea.width - 12 * u - Self.text(barEnd, bf, 0).size().width
            - Self.text("node \(node) \u{00B7} \(clock.isEmpty ? "--:--" : clock)\(mins) \u{00B7} ", f, 0).size().width - 16 * u
        var x = 12 * u + Self.text(">", bf, 0).size().width + 8 * u + Self.text(head.title, f, 0).size().width + 24 * u
        for name in names {
            let w = pillW(name)
            if x + w > right {
                break
            }
            gPills.append((name, Self.gR(x, y + (sh - ph) / 2, w, ph)))
            x += w + 6 * u
        }
    }

    private func pillW(_ name: String) -> CGFloat {
        let tw = Self.text(titleOf(name).uppercased(), font(true, 11), 0).size().width
        return tw + 22 * u + ((gState[name]?.badge ?? 0) > 0 ? 24 * u : 0)
    }

    func pillAt(_ p: CGPoint) -> String? { gPills.first { $0.box.contains(p) }?.name }

    /// A collapsed widget's pill on the status bar: its title and count; lit under the pointer, pulsing for attention.
    /// A click opens it again where it was.
    private func drawPill(_ name: String, _ box: CGRect) {
        let c = frameColors(name)
        let stt = gState[name] ?? (badge: 0, color: 0, attn: false)
        let hot = over(box)
        let acc = mc(.accent)
        let edge = stt.attn ? Self.mix(c.border, acc, 0.5 + 0.5 * CGFloat(sin(nowMs / 1000 * 5))) : hot ? acc : c.border
        let r = box.height / 2
        let path = NSBezierPath(roundedRect: box, xRadius: r, yRadius: r)
        if hot {
            Self.color(Self.mix(c.bg, acc, 0.25)).setFill()
        } else {
            Self.color(c.bg, 0.9).setFill()
        }
        path.fill()
        Self.color(edge).setStroke()
        path.lineWidth = max(u, 1)
        path.stroke()
        let tf = font(true, 11)
        Self.text(titleOf(name).uppercased(), tf, c.title).draw(at: CGPoint(x: box.minX + 11 * u, y: Self.capY(tf, box.midY)))
        if stt.badge > 0 {
            let bt = Self.text(stt.badge > 99 ? "99+" : String(stt.badge), font(true, 10), 0)
            let sz = bt.size()
            let bh = box.height - 6 * u, bw = max(sz.width + 8 * u, bh), bx = box.maxX - 9 * u - bw
            Self.color(stt.color & 0xFF00_0000 == 0 ? stt.color : acc).setFill()
            NSBezierPath(roundedRect: CGRect(x: bx, y: box.minY + 3 * u, width: bw, height: bh), xRadius: bh / 2, yRadius: bh / 2).fill()
            bt.draw(at: CGPoint(x: bx + (bw - sz.width) / 2, y: box.midY - sz.height / 2))
        }
    }

    private func drawStrip(_ name: String, _ box: CGRect) {
        let c = frameColors(name)
        let r = min(st.radius * u, box.height / 2)
        let path = NSBezierPath(roundedRect: box, xRadius: r, yRadius: r)
        Self.color(c.bg, st.opacity / 100 * 0.8).setFill()
        path.fill()
        if st.border > 0 {
            Self.color(c.border).setStroke()
            path.lineWidth = st.border * u
            path.stroke()
        }
        drawGTitle(name, c.bg, c.title, box.minX + 12 * u, box.midY, false)
        drawWidgetButtons(box, name, widgetFlags(name), c.bg, c.border, c.title, strip: true)
    }

    /// Gadget g in box: its frame, title, buttons (with them: on a menu), a resize grip, and its scene. Its replies
    /// made while drawing (timers) say g=; its size is reported when it changes. The tray draws it without buttons
    /// and without the pointer.
    func drawGadget(_ g: SGadgetM, _ box: CGRect, _ buttons: Bool) {
        guard let t = g.tree else { return }
        let bg = t.colors[Sc.panel.rawValue], border = t.colors[Sc.border.rawValue], tc = t.colors[Sc.title.rawValue]
        let r = st.radius * u
        let path = NSBezierPath(roundedRect: box, xRadius: r, yRadius: r)
        Self.color(bg, st.opacity / 100 * 0.8).setFill()
        path.fill()
        let focused = gFocus === g
        if st.border > 0 || focused {   // the gadget that has the keys: an accent border
            Self.color(focused ? mc(.accent) : border).setStroke()
            path.lineWidth = max(st.border, 1) * u
            path.stroke()
        }
        if !g.title.isEmpty {
            drawGTitle(g.name, bg, tc, box.minX + 14 * u, box.minY, true)
        }
        if buttons {
            drawWidgetButtons(box, g.name, g.flags, bg, border, tc)
            if g.flags & Self.gfResize != 0 && gPlace[g.name]?.dock == Self.dockFloat {   // the corner grip
                let gp = NSBezierPath()
                gp.lineWidth = max(u, 1)
                for i in 1...3 {
                    let k = CGFloat(i)
                    gp.move(to: CGPoint(x: box.maxX - 4 * u - 4 * k * u, y: box.maxY - 4 * u))
                    gp.line(to: CGPoint(x: box.maxX - 4 * u, y: box.maxY - 4 * u - 4 * k * u))
                }
                Self.color(border, 200.0 / 255).setStroke()
                gp.stroke()
            }
        }
        let pad = 10 * u
        let inner = CGRect(x: box.minX + pad, y: box.minY + pad + 2 * u, width: max(box.width - 2 * pad, 1),
                           height: max(box.height - 2 * pad - 2 * u, 1))
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: inner).addClip()
        let wasTag = gTag, wasPointer = pointer
        gTag = g.name
        pointer = buttons ? wireMouse : nil
        drawGadgetTree(t, inner)   // RainwireScene.swift: at gadgetScale
        gTag = wasTag
        pointer = wasPointer
        NSGraphicsContext.restoreGraphicsState()
        gadgetSizeCheck(g, inner)
    }

    /// GadgetSize;g=;w=;h= (the scene space in its units) when first drawn and when it changes (after 300 ms), only
    /// while the menu is up.
    private func gadgetSizeCheck(_ g: SGadgetM, _ inner: CGRect) {
        guard isUp else { return }
        let su = max(st.size * Self.gadgetScale * u, 0.01)
        let cur = (w: (inner.width / su * 10).rounded() / 10, h: (inner.height / su * 10).rounded() / 10)
        let now = Date()
        if cur != g.sizeCur {
            let first = g.sizeCur.w < 0
            g.sizeCur = cur
            g.sizeAt = first ? now.addingTimeInterval(-1) : now
            g.sizePending = true
        }
        if g.sizePending && now.timeIntervalSince(g.sizeAt) >= 0.3 {
            g.sizePending = false
            sendRaw("GadgetSize;g=\(g.name);w=\(String(format: "%.1f", Double(cur.w)));h=\(String(format: "%.1f", Double(cur.h)))")
        }
    }

    // ================================================================
    // The tray: GF_TRAY gadgets on the status bar while no menu is up
    // ================================================================

    /// The tray's pills, for TerminalView's status bar (RainwireTrayLayer).
    var tray: RainwireTrayView {
        if let t = trayBar {
            return t
        }
        let t = RainwireTrayView(menu: self)
        trayBar = t
        return t
    }

    /// The gadgets the tray shows now: tray ones while no menu is up, and those put in the tray always.
    func trayGadgets() -> [SGadgetM] {
        gadgets.keys.sorted().compactMap { gadgets[$0] }.filter { g in
            g.ready && !gClosed.contains(g.name)
                && ((g.flags & Self.gfTray != 0 && !isUp) || gPlace[g.name]?.dock == Self.dockTray)
        }
    }

    func trayUpdate() {
        guard let t = trayBar else { return }
        let any = !trayGadgets().isEmpty
        t.isHidden = !any
        t.invalidateIntrinsicContentSize()
        t.needsDisplay = true
        t.ticking(any)
        if !any {
            trayClose()
        }
    }

    func trayClose() {
        trayPop?.close()
        trayPop = nil
        trayPopFor = nil
    }

    /// Gadget g opened from its pill: a popover above the status bar showing it (quiet while no menu is up); its pill
    /// again closes it.
    func trayOpen(_ g: SGadgetM, _ pill: CGRect) {
        if let pop = trayPop, pop.isShown, trayPopFor === g {
            trayClose()
            return
        }
        trayClose()
        guard let bar = trayBar, bar.window != nil else { return }
        let vc = NSViewController()
        vc.view = RainwireTrayGadgetView(menu: self, gadget: g, frame: NSRect(x: 0, y: 0, width: 340, height: 250))
        let pop = NSPopover()
        pop.contentViewController = vc
        pop.contentSize = NSSize(width: 340, height: 250)
        pop.behavior = .transient   // a click outside or Esc closes it (Windows: StaysOpen false)
        pop.animates = false
        trayPop = pop
        trayPopFor = g
        // the bar is flipped: minY is its top edge, so the popover opens above the status bar
        pop.show(relativeTo: pill, of: bar, preferredEdge: .minY)
    }

    /// Icon icon (Rainwire internal/scene Icon*: the weather set 0-11, then dot, star, heart, check, cross, up, down,
    /// clock, moon) in rect r, colored col where it has one color (the weather ones keep their own).
    func drawIcon(_ icon: Int, _ col: UInt32, _ r: CGRect) {
        let s = min(r.width, r.height)
        guard s >= 4 else { return }
        let c = CGPoint(x: r.midX, y: r.midY)
        if icon <= 11 {
            drawWxIcon(icon, true, c, s)
            return
        }
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: c.x + x * s, y: c.y + y * s) }
        func poly(_ pts: [CGPoint]) {
            let g = NSBezierPath()
            g.move(to: pts[0])
            for q in pts.dropFirst() {
                g.line(to: q)
            }
            g.close()
            g.fill()
        }
        func oval(_ cx: CGFloat, _ cy: CGFloat, _ rr: CGFloat) {
            NSBezierPath(ovalIn: CGRect(x: cx - rr, y: cy - rr, width: 2 * rr, height: 2 * rr)).fill()
        }
        Self.color(col).setFill()
        Self.color(col).setStroke()
        let line = NSBezierPath()
        line.lineWidth = max(s * 0.11, 1)
        line.lineCapStyle = .round
        line.lineJoinStyle = .round
        switch icon {
        case 12: oval(c.x, c.y, s * 0.22)
        case 13:
            poly((0..<10).map { i in
                let a = -CGFloat.pi / 2 + CGFloat(i) * .pi / 5, rr: CGFloat = i % 2 == 0 ? 0.48 : 0.2
                return pt(cos(a) * rr, sin(a) * rr + 0.04)
            })
        case 14:
            oval(c.x - 0.18 * s, c.y - 0.12 * s, s * 0.22)
            oval(c.x + 0.18 * s, c.y - 0.12 * s, s * 0.22)
            poly([pt(-0.39, -0.04), pt(0.39, -0.04), pt(0, 0.4)])
        case 15:
            line.move(to: pt(-0.32, 0.02))
            line.line(to: pt(-0.1, 0.26))
            line.line(to: pt(0.34, -0.26))
            line.stroke()
        case 16:
            line.move(to: pt(-0.28, -0.28))
            line.line(to: pt(0.28, 0.28))
            line.move(to: pt(-0.28, 0.28))
            line.line(to: pt(0.28, -0.28))
            line.stroke()
        case 17: poly([pt(0, -0.36), pt(0.36, 0.26), pt(-0.36, 0.26)])
        case 18: poly([pt(0, 0.36), pt(0.36, -0.26), pt(-0.36, -0.26)])
        case 19:
            line.appendOval(in: CGRect(x: c.x - 0.4 * s, y: c.y - 0.4 * s, width: 0.8 * s, height: 0.8 * s))
            line.move(to: c)
            line.line(to: pt(0, -0.24))
            line.move(to: c)
            line.line(to: pt(0.17, 0.06))
            line.stroke()
        case 20: sunOrMoon(false, c, s * 0.5, col)
        default: break
        }
    }

    /// The weather widget's colors; with none (a scene's icon), the icons' defaults Rainwire sends (sun, rain, snow,
    /// storm) and 0 for the rest.
    private func xw(_ i: Int) -> UInt32 {
        if let w = wx {
            return w.colors[i]
        }
        switch i {
        case 6, 9: return 0xF2D23C
        case 7: return 0x5CA8F0
        case 8: return 0xE8F0FF
        default: return 0
        }
    }

    /// One line cut to width with an ellipsis, from its top at y; returns the y under it.
    @discardableResult
    private func wxLine(_ s: String, _ f: NSFont, _ c: UInt32, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat) -> CGFloat {
        guard !s.isEmpty else { return y }
        let t = Self.text(s, f, c)
        let h = ceil(f.ascender - f.descender + f.leading)
        t.draw(with: CGRect(x: x, y: y, width: max(width, 10), height: h), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        return y + h
    }

    /// The weather: a box like the news panel's, the title on the top border; the icon with the temperature, the
    /// conditions and the place beside it, the two detail lines as room allows, and the days ahead along the bottom
    /// (expanded: down the right half).
    func drawWeather() {
        guard let w = wx, !wxBox.isEmpty else { return }
        let box = wxBox, bg = xw(0)
        let a = st.opacity / 100 * 0.8, r = st.radius * u
        let path = NSBezierPath(roundedRect: box, xRadius: r, yRadius: r)
        Self.color(bg, a).setFill()
        path.fill()
        if wxHot {
            Self.color(xw(5), 40.0 / 255).setFill()
            path.fill()
        }
        if st.border > 0 {
            Self.color(xw(1)).setStroke()
            path.lineWidth = st.border * u
            path.stroke()
        }
        let tf = font(true, 12)
        let title = Self.text(w.title.uppercased(), tf, xw(2))
        let tx = box.minX + 14 * u
        if st.border > 0 {
            Self.color(bg, a).setFill()
            CGRect(x: tx - 6 * u, y: box.minY - (2 + st.border / 2) * u, width: title.size().width + 12 * u,
                   height: (4 + st.border) * u).fill()
        }
        title.draw(at: CGPoint(x: tx, y: Self.capY(tf, box.minY)))
        drawWidgetButtons(box, "weather", widgetFlags("weather"), bg, xw(1), xw(2))

        let pad = 12 * u
        let inner = CGRect(x: box.minX + pad, y: box.minY + pad + 2 * u, width: max(box.width - 2 * pad, 1),
                           height: max(box.height - 2 * pad - 2 * u, 1))
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: inner).addClip()
        let wide = gWide.contains("weather") && inner.width > 160 * u   // expanded: the days down the right (360 was more than it has)
        let now = wide ? CGRect(x: inner.minX, y: inner.minY, width: inner.width * 0.40, height: inner.height) : inner
        // compact: the place on its own line; the icon, the temperature, and beside it the conditions over the
        // feels-like and high/low line; then the wind line
        let small = font(false, 10.5)
        let lineH = ceil(small.ascender - small.descender + small.leading)
        var ly = wxLine(w.place, small, xw(4), now.minX, now.minY - 2 * u, now.width) + 2 * u
        let big = font(true, 22)
        let temp = Self.text(w.temp, big, xw(3))
        let rowH = max(min(ceil(big.ascender - big.descender), now.maxY - ly), 0), icon = min(rowH, 32 * u)
        if icon >= 8 * u {
            drawWxIcon(w.kind, w.day, CGPoint(x: now.minX + icon / 2, y: ly + rowH / 2), icon)
        }
        var x = now.minX + (icon >= 8 * u ? icon + 8 * u : 0)
        temp.draw(at: CGPoint(x: x, y: ly))
        x += temp.size().width + 10 * u
        var cy = ly + max(rowH - 2 * lineH - 2 * u, 0) / 2
        cy = wxLine(w.cond, font(true, 12), xw(3), x, cy, max(now.maxX - x, 10))
        wxLine(w.line1, small, xw(4), x, cy, max(now.maxX - x, 10))
        ly += rowH + 2 * u
        if ly + lineH <= now.maxY + 1 {
            ly = wxLine(w.line2, small, xw(4), now.minX, ly, now.width)
        }
        let days = wide ? CGRect(x: now.maxX + 12 * u, y: inner.minY, width: inner.maxX - now.maxX - 12 * u, height: inner.height)
                        : CGRect(x: inner.minX, y: ly + 6 * u, width: inner.width, height: inner.maxY - ly - 6 * u)
        if !w.days.isEmpty && days.height >= 28 * u && days.width >= 60 * u {   // the icons only when there's room
            if !wide {
                Self.color(xw(1), 80.0 / 255).setFill()
                CGRect(x: days.minX, y: days.minY - 4 * u, width: days.width, height: max(1, u)).fill()
            }
            let n = min(w.days.count, max(1, Int(days.width / ((wide ? 32 : 46) * u))))
            let cw = days.width / CGFloat(n)
            let nf = font(true, 10.5)
            let nh = ceil(nf.ascender - nf.descender)
            for i in 0..<n {
                let d = w.days[i]
                let cx = days.minX + cw * CGFloat(i) + cw / 2
                let name = Self.text(d.name, nf, xw(4))
                name.draw(at: CGPoint(x: cx - name.size().width / 2, y: days.minY))
                // the high and low on one line when the column has room, else the high over the low (dimmed)
                let hl = Self.text(d.hi + " " + d.lo, small, xw(3))
                let stack = hl.size().width > cw - 6 * u
                let hi = stack ? Self.text(d.hi, font(true, 10.5), xw(3)) : hl
                let lo: NSAttributedString? = stack ? Self.text(d.lo, small, xw(4)) : nil
                if let lo = lo {
                    // the icon beside the high-over-low, as big as the column leaves
                    let sw = max(hi.size().width, lo.size().width), sh = 2 * lineH - u
                    var ic = min(min(cw - sw - 7 * u, sh), 20 * u)
                    if ic < 8 * u {
                        ic = 0
                    }
                    let gap: CGFloat = ic > 0 ? 3 * u : 0
                    let gx = cx - (ic + gap + sw) / 2, gy = days.minY + nh + u
                    if ic > 0 {
                        drawWxIcon(d.kind, true, CGPoint(x: gx + ic / 2, y: gy + sh / 2), ic)
                    }
                    let sx = gx + ic + gap + sw / 2
                    hi.draw(at: CGPoint(x: sx - hi.size().width / 2, y: gy))
                    lo.draw(at: CGPoint(x: sx - lo.size().width / 2, y: gy + lineH - u))
                    continue
                }
                let ih = min(min(cw * 0.6, days.height - nh - lineH - 4 * u), 34 * u)
                if ih >= 10 * u {
                    drawWxIcon(d.kind, true, CGPoint(x: cx, y: days.minY + nh + ih / 2 + u), ih)
                }
                hi.draw(at: CGPoint(x: cx - hi.size().width / 2, y: days.minY + nh + max(ih, 0) + 2 * u))
            }
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    // ---- the weather icons (MU_WK_*), drawn at size s around center c (this view is flipped: y grows down) ----

    func drawWxIcon(_ kind: Int, _ day: Bool, _ c: CGPoint, _ s: CGFloat) {
        guard s >= 6 else { return }
        let sun = xw(6), rain = xw(7), snow = xw(8), bolt = xw(6)
        let cloud: UInt32 = day ? 0xDCE2EC : 0xA4AEC0, dark: UInt32 = 0x8C96A8
        switch kind {
        case 0:
            sunOrMoon(day, c, s * 0.5, sun)
        case Self.wkMostly, Self.wkPartly:
            sunOrMoon(day, CGPoint(x: c.x - s * 0.14, y: c.y - s * 0.14), s * 0.38, sun)
            cloudShape(CGPoint(x: c.x + s * 0.1, y: c.y + s * 0.14), s * (kind == Self.wkMostly ? 0.5 : 0.66), cloud)
        case Self.wkCloudy:
            cloudShape(CGPoint(x: c.x - s * 0.12, y: c.y - s * 0.1), s * 0.55, dark)
            cloudShape(CGPoint(x: c.x + s * 0.06, y: c.y + s * 0.08), s * 0.78, cloud)
        case Self.wkFog:
            let p = NSBezierPath()
            p.lineWidth = s * 0.08
            p.lineCapStyle = .round
            for i in 0..<3 {
                let y = c.y - s * 0.22 + CGFloat(i) * s * 0.22, inset: CGFloat = i == 1 ? 0.06 : 0
                p.move(to: CGPoint(x: c.x - s * (0.4 - inset), y: y))
                p.line(to: CGPoint(x: c.x + s * (0.4 - inset), y: y))
            }
            Self.color(cloud).setStroke()
            p.stroke()
        default:   // a cloud with something falling, or a storm
            cloudShape(CGPoint(x: c.x, y: c.y - s * 0.14), s * 0.8, kind == Self.wkThunder || kind == Self.wkHeavy ? dark : cloud)
            let y0 = c.y + s * 0.14
            if kind == Self.wkThunder {
                let g = NSBezierPath()
                g.move(to: CGPoint(x: c.x + s * 0.04, y: y0 - s * 0.04))
                g.line(to: CGPoint(x: c.x - s * 0.12, y: y0 + s * 0.2))
                g.line(to: CGPoint(x: c.x, y: y0 + s * 0.2))
                g.line(to: CGPoint(x: c.x - s * 0.08, y: y0 + s * 0.4))
                g.line(to: CGPoint(x: c.x + s * 0.16, y: y0 + s * 0.12))
                g.line(to: CGPoint(x: c.x + s * 0.03, y: y0 + s * 0.12))
                g.close()
                Self.color(bolt).setFill()
                g.fill()
                return
            }
            let flakes = kind == Self.wkSnow || kind == Self.wkHeavySnow
            let n = kind == Self.wkDrizzle || kind == Self.wkSnow ? 3 : 4
            let drop = NSBezierPath()
            drop.lineWidth = s * 0.065
            drop.lineCapStyle = .round
            for i in 0..<n {
                let x = c.x - s * 0.27 + CGFloat(i) * s * 0.54 / CGFloat(n - 1)
                if flakes || (kind == Self.wkFreeze && i % 2 == 1) {
                    let cy = y0 + s * (i % 2 == 0 ? 0.16 : 0.28), rr = s * 0.055
                    Self.color(snow).setFill()
                    NSBezierPath(ovalIn: CGRect(x: x - rr, y: cy - rr, width: 2 * rr, height: 2 * rr)).fill()
                } else {
                    let len: CGFloat = kind == Self.wkDrizzle ? 0.12 : 0.22
                    drop.move(to: CGPoint(x: x + s * 0.04, y: y0 + s * 0.08))
                    drop.line(to: CGPoint(x: x - s * 0.04, y: y0 + s * (0.08 + len)))
                }
            }
            Self.color(rain).setStroke()
            drop.stroke()
        }
    }

    /// The sun (a disc with rays) or, at night, the moon (a crescent: an even-odd path of two circles), radius r.
    func sunOrMoon(_ day: Bool, _ c: CGPoint, _ r: CGFloat, _ sun: UInt32) {
        if !day {
            NSGraphicsContext.saveGraphicsState()
            let cut = NSBezierPath(rect: bounds)
            let rr = r * 0.6
            cut.appendOval(in: CGRect(x: c.x + r * 0.38 - rr, y: c.y - r * 0.28 - rr, width: 2 * rr, height: 2 * rr))
            cut.windingRule = .evenOdd
            cut.addClip()
            Self.color(0xEEE8C8).setFill()
            NSBezierPath(ovalIn: CGRect(x: c.x - r * 0.7, y: c.y - r * 0.7, width: r * 1.4, height: r * 1.4)).fill()
            NSGraphicsContext.restoreGraphicsState()
            return
        }
        let ray = NSBezierPath()
        ray.lineWidth = r * 0.14
        ray.lineCapStyle = .round
        for i in 0..<8 {
            let a = CGFloat(i) * .pi / 4
            ray.move(to: CGPoint(x: c.x + cos(a) * r * 0.68, y: c.y + sin(a) * r * 0.68))
            ray.line(to: CGPoint(x: c.x + cos(a) * r * 0.95, y: c.y + sin(a) * r * 0.95))
        }
        Self.color(sun).setStroke()
        ray.stroke()
        Self.color(sun).setFill()
        NSBezierPath(ovalIn: CGRect(x: c.x - r * 0.48, y: c.y - r * 0.48, width: r * 0.96, height: r * 0.96)).fill()
    }

    /// A cloud w wide centered on c: three puffs on a flat base.
    private func cloudShape(_ c: CGPoint, _ w: CGFloat, _ col: UInt32) {
        let h = w * 0.5
        Self.color(col).setFill()
        NSBezierPath(roundedRect: CGRect(x: c.x - w / 2, y: c.y, width: w, height: h * 0.5), xRadius: h * 0.25, yRadius: h * 0.25).fill()
        for (dx, dy, rr) in [(-0.22, 0.05 * 0.5, 0.2), (0.05, -0.12 * 0.5, 0.27), (0.28, 0.08 * 0.5, 0.18)] {
            let cx = c.x + w * CGFloat(dx), cy = c.y + w * CGFloat(dy), r = w * CGFloat(rr)
            NSBezierPath(ovalIn: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r)).fill()
        }
    }
}

// MARK: - The tray (version 6): GF_TRAY gadgets on TERMinator's status bar

/// The tray's pills (Windows' RainwireGadgets.cs TrayBar): each tray gadget's title and count, pulsing for attention,
/// redrawn twice a second while shown; a click opens the gadget in a popover above it (RainwireMenuView.trayOpen).
/// RainwireTrayLayer puts it in TerminalView's SwiftUI status bar; it sizes itself by its pills (intrinsicContentSize).
final class RainwireTrayView: NSView {
    private weak var owner: RainwireMenuView?
    private var pills: [(box: CGRect, g: SGadgetM)] = []
    private var tick: Timer?
    private static let labelFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    private static let badgeFont = NSFont.systemFont(ofSize: 10.5, weight: .semibold)

    init(menu: RainwireMenuView) {
        self.owner = menu
        super.init(frame: NSRect(x: 0, y: 0, width: 0, height: 20))
        isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func label(_ g: SGadgetM) -> NSAttributedString {
        NSAttributedString(string: g.title.isEmpty ? g.name : g.title,
                           attributes: [.font: Self.labelFont, .foregroundColor: NSColor.white])
    }

    override var intrinsicContentSize: NSSize {
        guard let m = owner else { return NSSize(width: 0, height: 20) }
        var w: CGFloat = 0
        for g in m.trayGadgets() {
            w += ceil(label(g).size().width) + 26 + ((m.gState[g.name]?.badge ?? 0) > 0 ? 26 : 0)
        }
        return NSSize(width: max(w - 6, 0), height: 20)
    }

    /// The redraw timer on while there are pills (counts and attention pulses).
    func ticking(_ on: Bool) {
        if on && tick == nil {
            let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                self?.needsDisplay = true
            }
            RunLoop.main.add(t, forMode: .common)
            tick = t
        } else if !on {
            tick?.invalidate()
            tick = nil
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        pills.removeAll()
        guard let m = owner else { return }
        var x: CGFloat = 0
        let y0 = max((bounds.height - 20) / 2, 0)
        for g in m.trayGadgets() {
            let st = m.gState[g.name] ?? (badge: 0, color: 0, attn: false)
            let ft = label(g)
            let tw = ceil(ft.size().width)
            let w = tw + 20 + (st.badge > 0 ? 26 : 0)
            let box = CGRect(x: x, y: y0, width: w, height: 20)
            let accent = g.tree.map { $0.colors[RainwireMenuView.Sc.accent.rawValue] } ?? 0x55_AAFF
            let a: CGFloat = st.attn ? (120 + 100 * abs(sin(CGFloat(Date().timeIntervalSinceReferenceDate * 2.5)))) / 255
                                     : 70.0 / 255
            let path = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
            RainwireMenuView.color(accent, a).setFill()
            path.fill()
            RainwireMenuView.color(accent).setStroke()
            path.lineWidth = 1
            path.stroke()
            ft.draw(at: CGPoint(x: x + 10, y: y0 + (20 - ft.size().height) / 2))
            if st.badge > 0 {
                let bt = NSAttributedString(string: st.badge > 99 ? "99+" : String(st.badge),
                                            attributes: [.font: Self.badgeFont, .foregroundColor: NSColor.black])
                let bs = bt.size()
                let bb = CGRect(x: x + 14 + tw, y: y0 + 3, width: max(bs.width + 8, 14), height: 14)
                NSColor.white.setFill()
                NSBezierPath(roundedRect: bb, xRadius: 7, yRadius: 7).fill()
                bt.draw(at: CGPoint(x: bb.minX + (bb.width - bs.width) / 2, y: bb.minY + (14 - bs.height) / 2))
            }
            pills.append((box, g))
            x += w + 6
        }
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard let m = owner else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard let hit = pills.first(where: { $0.box.contains(p) }) else { return }
        if let st = m.gState[hit.g.name] {
            m.gState[hit.g.name] = (st.badge, st.color, false)
        }
        m.trayOpen(hit.g, hit.box)
        needsDisplay = true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

/// A tray gadget opened from its pill (Windows' TrayView): drawn as on a menu but without its buttons, quiet while no
/// menu is up (nothing it does reaches the board: the board may be in a door), redrawn twice a second for its clocks.
final class RainwireTrayGadgetView: NSView {
    private weak var owner: RainwireMenuView?
    private let gadget: SGadgetM
    private var tick: Timer?

    init(menu: RainwireMenuView, gadget: SGadgetM, frame: NSRect) {
        self.owner = menu
        self.gadget = gadget
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        tick?.invalidate()
        tick = nil
        if window != nil {
            let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                self?.needsDisplay = true
            }
            RunLoop.main.add(t, forMode: .common)
            tick = t
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let m = owner, gadget.tree != nil, bounds.width > 0 else { return }
        NSColor(srgbRed: 0x10 / 255.0, green: 0x12 / 255.0, blue: 0x1A / 255.0, alpha: 235.0 / 255).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
        let box = CGRect(x: 6, y: 14, width: bounds.width - 12, height: bounds.height - 20)
        m.trayQuiet = !m.isUp
        m.drawGadget(gadget, box, false)
        m.trayQuiet = false
    }
}

/// Hosts the shared tray view in TerminalView's status bar (SwiftUI), as RainwireMenuLayer hosts the menu.
struct RainwireTrayLayer: NSViewRepresentable {
    func makeNSView(context: Context) -> RainwireTrayView {
        let menu = RainwireMenuView.shared
        let t = menu.tray
        t.removeFromSuperview()   // a TerminalView from before (one call per process)
        menu.trayUpdate()
        return t
    }

    func updateNSView(_ nsView: RainwireTrayView, context: Context) {}
}
