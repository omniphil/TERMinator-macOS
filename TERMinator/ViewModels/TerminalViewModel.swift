import Foundation
import Combine
import AppKit
import ImageIO
import AVFoundation
import os.log

private let logger = Logger(subsystem: "com.terminator.macos", category: "Terminal")

/// Connection state for the terminal.
enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case disconnecting
    case error(String)
}

/// Represents a detected URL in the terminal screen.
struct DetectedURL {
    let url: String
    let startColumn: Int
    let endColumn: Int
    let row: Int
    let fgColorIndex: Int  // foreground color of the URL text
    /// A board's OSC 8 link (12.62): a click opens its real address, not the text
    var isBoardLink: Bool = false
}

/// ViewModel for the terminal view.
/// Manages connection, screen state, logging, and file transfers.
@MainActor
class TerminalViewModel: ObservableObject {

    // MARK: - Published Properties

    @Published var connectionState: ConnectionState = .disconnected
    @Published var screenBuffer: [Int32] = []
    @Published var screenColumns: Int = 80
    @Published var screenRows: Int = 25
    @Published var cursorX: Int = 0
    @Published var cursorY: Int = 0
    @Published var cursorVisible: Bool = true  // BBS-controlled via escape codes
    @Published var userHideCursor: Bool = false   // Cursor on by default; idle threshold hides during active drawing

    // Cursor shape — driven by the BBS via SGR / ciolib setcursortype + setcustomcursor
    @Published var cursorType: NativeBridge.CursorType = .normalCursor
    @Published var cursorStart: Int = 14  // top scanline within cell (default: underline near bottom)
    @Published var cursorEnd: Int = 15    // bottom scanline within cell
    @Published var cursorBlinks: Bool = true

    // ---- macOS PETSCII 2026-09-04 (mirrors the shipping iOS build) ----------
    /// Forced display aspect (width/height) for the Commodore modes, nil elsewhere.
    /// 320x200 at 6:5 for the 40-column modes, 640x200 at 4:3 for C128 80x25 —
    /// deliberately non-square pixels, exactly as on the real machine.
    @Published var displayAspect: CGFloat? = nil
    /// True while a Commodore (PETSCII) screen mode is active. The renderer must
    /// gate its BLINK handling on this: attribute bit 7 means background-brightness,
    /// not blink, in those modes, and most PETSCII artwork is reverse-video blocks.
    @Published var petsciiMode: Bool = false
    @Published var palette: [Int32] = []

    @Published var isLogging: Bool = false
    @Published var transferInfo: TransferInfo?

    /// Protocol status feed shown under the transfer progress bar.
    @Published var transferLogLines: [TransferLogLine] = []
    @Published var showTransferView: Bool = false
    @Published var showUploadPicker: Bool = false
    @Published var connectedAt: Date?


    @Published var detectedURLs: [DetectedURL] = []
    /// A short notice over the terminal ("Copied from the BBS"), cleared after two seconds (12.62)
    @Published var toastMessage: String?
    private var toastWork: DispatchWorkItem?

    // TAP+ multimedia overlay state — multi-channel images (8 channels)
    struct ImageChannel {
        var active: Bool = false
        var data: NSImage? = nil
        var row: Double = 1.0
        var col: Double = 1.0
        var cellW: Double = 78.0
        var cellH: Double = 23.0
        var positionSet: Bool = false
    }
    @Published var imageChannels: [ImageChannel] = Array(repeating: ImageChannel(), count: 8)

    // TERMinator:Pic slots (Rainwire's pictures, Bridge/apc/pic_bridge.c): eight of their own, separate from TAP+'s
    // channels and not affected by its commands or its Preferences switch
    static let maxPicSlots = 8
    struct PicSlot {
        var active: Bool = false
        var image: NSImage? = nil
        var row1: Int = 1, col1: Int = 1, row2: Int = 1, col2: Int = 1   // 1-based cells, inclusive
        var pixelW: CGFloat = 0, pixelH: CGFloat = 0                     // the picture's own size, for the aspect fit
    }
    @Published var picSlots: [PicSlot] = Array(repeating: PicSlot(), count: TerminalViewModel.maxPicSlots)

    // Background image underlay state
    @Published var bgActive: Bool = false
    @Published var bgImageData: NSImage? = nil
    @Published var bgRow: Double = 0.0
    @Published var bgCol: Double = 0.0
    @Published var bgCellW: Double = 80.0
    @Published var bgCellH: Double = 25.0
    @Published var bgOpacity: Double = 1.0
    private var bgPositionSet: Bool = false

    // Tile atlas system state
    @Published var tileAtlasImage: NSImage? = nil
    @Published var tileAtlasPixels: [UInt32] = []
    @Published var tileAtlasWidth: Int = 0
    @Published var tileAtlasHeight: Int = 0
    @Published var tileSpriteW: Int = 16
    @Published var tileSpriteH: Int = 16
    @Published var tileGrid: [[Int]] = []       // 2D grid of sprite IDs (-1 = empty)
    @Published var tileMapRow1: Int = 0          // 0-based origin row
    @Published var tileMapCol1: Int = 0          // 0-based origin col
    @Published var tileMapRow2: Int = 0          // 0-based end row
    @Published var tileMapCol2: Int = 0          // 0-based end col
    @Published var tileMapActive: Bool = false
    @Published var tileOpacity: Double = 1.0
    private var tileBatchMode = false
    private var _tileGridBatch: [[Int]]? = nil  // backing grid during batch mode

    /// The working grid: returns the batch buffer if in batch mode, otherwise the published grid.
    private var workingGrid: [[Int]] {
        get { _tileGridBatch ?? tileGrid }
        set {
            if tileBatchMode {
                _tileGridBatch = newValue
            } else {
                tileGrid = newValue
            }
        }
    }
    @Published var tileScaleOverride: Int = 0 // 0 = auto-detect, 1/2/4 = explicit
    @Published var videoActive: Bool = false
    @Published var videoURL: URL?
    @Published var videoPlayer: AVPlayer?
    @Published var videoRow: Double = 1.0
    @Published var videoCol: Double = 1.0
    @Published var videoCellW: Double = 80.0
    @Published var videoCellH: Double = 25.0
    @Published var videoNativeWidth: CGFloat = 0
    @Published var videoNativeHeight: CGFloat = 0
    @Published var visualizerActive: Bool = false
    @Published var visualizerRow: Double = 1.0
    @Published var visualizerCol: Double = 1.0
    @Published var visualizerCellW: Double = 80.0
    @Published var visualizerCellH: Double = 25.0
    @Published var visualizerStyle: String = "bars"

    // Logo overlay state (fractional cell coordinates, auto-sized on load)
    @Published var logoActive: Bool = false
    @Published var logoImageData: NSImage?
    @Published var logoRow: Double = 22.0
    @Published var logoCol: Double = 64.0
    @Published var logoCellW: Double = 16.0
    @Published var logoCellH: Double = 3.0
    private var logoPositionSet: Bool = false

    /// Container size from GeometryReader, used for pan clamping
    var containerSize: CGSize = .zero

    // Text selection state
    @Published var isSelecting: Bool = false
    @Published var selectionAnchorCol: Int = -1
    @Published var selectionAnchorRow: Int = -1
    @Published var selectionEndCol: Int = -1
    @Published var selectionEndRow: Int = -1
    var selectionMinCol: Int { min(selectionAnchorCol, selectionEndCol) }
    var selectionMinRow: Int { min(selectionAnchorRow, selectionEndRow) }
    var selectionMaxCol: Int { max(selectionAnchorCol, selectionEndCol) }
    var selectionMaxRow: Int { max(selectionAnchorRow, selectionEndRow) }

    // Scrollback state
    @Published var scrollbackOffset: Int = 0  // 0 = live, >0 = lines scrolled back
    var isInScrollback: Bool { scrollbackOffset > 0 }
    private(set) var displayBuffer: [Int32] = []
    private(set) var displayBufferVersion: Int = 0

    // True colour: per-cell RGB overrides in lockstep with screenBuffer / displayBuffer. 0xFFRRGGBB when the
    // cell carries a literal 24-bit colour (ESC[38;2;R;G;Bm / 48;2), 0 = use the packed palette index. Kept out
    // of the packed cell so every indexed cell renders exactly as before; the renderer treats a missing or
    // short array as "no overrides".
    private(set) var screenFgRGB: [UInt32] = []
    private(set) var screenBgRGB: [UInt32] = []
    private(set) var displayFgRGB: [UInt32] = []
    private(set) var displayBgRGB: [UInt32] = []

    // Byte counters
    @Published var bytesReceived: Int = 0
    @Published var bytesSent: Int = 0

    // Font dimensions (from native font bitmap)
    @Published var fontWidth: Int = 0
    @Published var fontHeight: Int = 0

    // Renderer readiness state (for proper first-render timing)
    @Published var rendererReady = false

    // Screen buffer version counter - incremented when buffer changes.
    // Used by Metal renderer to skip re-rendering when nothing changed.
    private(set) var screenBufferVersion: Int = 0

    // Cursor blink state (separate from ANSI character blink)
    private(set) var cursorBlinkOn: Bool = true
    private var lastCursorBlinkToggle: TimeInterval = 0
    private let cursorBlinkInterval: TimeInterval = 0.133  // 133ms, matches SyncTERM/Windows

    // Text blink state (SGR 5/6 — ANSI blink attribute)
    private(set) var textBlinkOn: Bool = true
    private var blinkTickCount: Int = 0
    private(set) var hasBlinkingCells: Bool = false

    // Idle-based cursor hide: suppress cursor while data is streaming in
    private var lastScreenUpdateTime: TimeInterval = 0
    private let cursorIdleThreshold: TimeInterval = 0.15  // Show cursor after 150ms of no screen updates
    private(set) var cursorIdle: Bool = false  // true when no data streaming

    // MARK: - Private Properties

    private var entry: BBSEntry?
    /// No first byte within this long after connecting = give up. The Preferences connection timeout, read at
    /// connect time (Windows `ConnectionManager.PollLoop`, PORT_TO_MAC_LINUX §12.27).
    private var noDataTimeoutSeconds: TimeInterval = 10.0

    private var pollingTimer: Timer?
    private var appNapActivity: NSObjectProtocol?
    /// The data pump's shared state (see `startDataPump`).
    private let pumpState = DataPumpState()
    private var cancellables = Set<AnyCancellable>()
    private var isTransferInProgress = false
    private var pendingStartAfterConnect = false
    private var hasReceivedData: Bool = false
    private var connectionStartTime: Date?

    // Bitmap font data
    // Exposed for Metal renderer access
    private(set) var fontBitmap: Data?
    private var glyphCache = NSCache<NSString, CGImage>()

    // Sixel graphics state (internal access for Metal renderer)
    private(set) var sixelPixels: [UInt32]?
    private(set) var sixelWidth = 0
    private(set) var sixelHeight = 0
    private(set) var hasSixelData = false
    /// Bumped whenever `sixelPixels` changes, with the changed rectangle in `sixelDirtyRect` (unioned until the
    /// renderer takes it), so a graphics-only frame (sixel / JPEG XL) is composited and uploaded without redrawing
    /// every glyph. A change of layer size bumps `displayBufferVersion` instead (a full redraw).
    private(set) var sixelVersion = 0
    private var sixelDirtyRect: CGRect?

    // ZMODEM detection return codes from native layer
    // These MUST match values in native code (conn_api.c)
    private let ZMODEM_DOWNLOAD_DETECTED = -100  // ZRQINIT received - BBS wants to send file
    private let ZMODEM_UPLOAD_READY = -101       // ZRINIT received - BBS ready to receive file

    // URL detection regex - initialized lazily to avoid crash on invalid pattern
    private lazy var urlPattern: NSRegularExpression? = {
        do {
            return try NSRegularExpression(
                pattern: "(https?://|ftp://|www\\.)[^\\s<>\\[\\](){}'\"`,;]+[^\\s<>\\[\\](){}'\"`,;.!?]",
                options: .caseInsensitive
            )
        } catch {
            print("TerminalViewModel: Failed to create URL pattern: \(error)")
            return nil
        }
    }()

    // CP437 to Unicode mapping table
    private let cp437ToUnicode: [Character] = [
        // 0x00-0x1F: Control characters displayed as graphics in CP437
        "\u{0000}", "\u{263A}", "\u{263B}", "\u{2665}", "\u{2666}", "\u{2663}", "\u{2660}", "\u{2022}",
        "\u{25D8}", "\u{25CB}", "\u{25D9}", "\u{2642}", "\u{2640}", "\u{266A}", "\u{266B}", "\u{263C}",
        "\u{25BA}", "\u{25C4}", "\u{2195}", "\u{203C}", "\u{00B6}", "\u{00A7}", "\u{25AC}", "\u{21A8}",
        "\u{2191}", "\u{2193}", "\u{2192}", "\u{2190}", "\u{221F}", "\u{2194}", "\u{25B2}", "\u{25BC}",
        // 0x20-0x7E: Standard ASCII
        " ", "!", "\"", "#", "$", "%", "&", "'", "(", ")", "*", "+", ",", "-", ".", "/",
        "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", ":", ";", "<", "=", ">", "?",
        "@", "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O",
        "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z", "[", "\\", "]", "^", "_",
        "`", "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o",
        "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z", "{", "|", "}", "~", "\u{2302}",
        // 0x80-0xFF: Extended characters
        "\u{00C7}", "\u{00FC}", "\u{00E9}", "\u{00E2}", "\u{00E4}", "\u{00E0}", "\u{00E5}", "\u{00E7}",
        "\u{00EA}", "\u{00EB}", "\u{00E8}", "\u{00EF}", "\u{00EE}", "\u{00EC}", "\u{00C4}", "\u{00C5}",
        "\u{00C9}", "\u{00E6}", "\u{00C6}", "\u{00F4}", "\u{00F6}", "\u{00F2}", "\u{00FB}", "\u{00F9}",
        "\u{00FF}", "\u{00D6}", "\u{00DC}", "\u{00A2}", "\u{00A3}", "\u{00A5}", "\u{20A7}", "\u{0192}",
        "\u{00E1}", "\u{00ED}", "\u{00F3}", "\u{00FA}", "\u{00F1}", "\u{00D1}", "\u{00AA}", "\u{00BA}",
        "\u{00BF}", "\u{2310}", "\u{00AC}", "\u{00BD}", "\u{00BC}", "\u{00A1}", "\u{00AB}", "\u{00BB}",
        "\u{2591}", "\u{2592}", "\u{2593}", "\u{2502}", "\u{2524}", "\u{2561}", "\u{2562}", "\u{2556}",
        "\u{2555}", "\u{2563}", "\u{2551}", "\u{2557}", "\u{255D}", "\u{255C}", "\u{255B}", "\u{2510}",
        "\u{2514}", "\u{2534}", "\u{252C}", "\u{251C}", "\u{2500}", "\u{253C}", "\u{255E}", "\u{255F}",
        "\u{255A}", "\u{2554}", "\u{2569}", "\u{2566}", "\u{2560}", "\u{2550}", "\u{256C}", "\u{2567}",
        "\u{2568}", "\u{2564}", "\u{2565}", "\u{2559}", "\u{2558}", "\u{2552}", "\u{2553}", "\u{256B}",
        "\u{256A}", "\u{2518}", "\u{250C}", "\u{2588}", "\u{2584}", "\u{258C}", "\u{2590}", "\u{2580}",
        "\u{03B1}", "\u{00DF}", "\u{0393}", "\u{03C0}", "\u{03A3}", "\u{03C3}", "\u{00B5}", "\u{03C4}",
        "\u{03A6}", "\u{0398}", "\u{03A9}", "\u{03B4}", "\u{221E}", "\u{03C6}", "\u{03B5}", "\u{2229}",
        "\u{2261}", "\u{00B1}", "\u{2265}", "\u{2264}", "\u{2320}", "\u{2321}", "\u{00F7}", "\u{2248}",
        "\u{00B0}", "\u{2219}", "\u{00B7}", "\u{221A}", "\u{207F}", "\u{00B2}", "\u{25A0}", "\u{00A0}"
    ]

    // Amiga Topaz font uses slightly different mapping for some characters
    private let amigaToUnicode: [Character] = [
        // 0x00-0x1F: Control characters (same as CP437 for most)
        "\u{0000}", "\u{263A}", "\u{263B}", "\u{2665}", "\u{2666}", "\u{2663}", "\u{2660}", "\u{2022}",
        "\u{25D8}", "\u{25CB}", "\u{25D9}", "\u{2642}", "\u{2640}", "\u{266A}", "\u{266B}", "\u{263C}",
        "\u{25BA}", "\u{25C4}", "\u{2195}", "\u{203C}", "\u{00B6}", "\u{00A7}", "\u{25AC}", "\u{21A8}",
        "\u{2191}", "\u{2193}", "\u{2192}", "\u{2190}", "\u{221F}", "\u{2194}", "\u{25B2}", "\u{25BC}",
        // 0x20-0x7E: Standard ASCII (same)
        " ", "!", "\"", "#", "$", "%", "&", "'", "(", ")", "*", "+", ",", "-", ".", "/",
        "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", ":", ";", "<", "=", ">", "?",
        "@", "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O",
        "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z", "[", "\\", "]", "^", "_",
        "`", "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o",
        "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z", "{", "|", "}", "~", "\u{2302}",
        // 0x80-0xFF: Extended - Amiga uses ISO-8859-1 style for some
        "\u{00C7}", "\u{00FC}", "\u{00E9}", "\u{00E2}", "\u{00E4}", "\u{00E0}", "\u{00E5}", "\u{00E7}",
        "\u{00EA}", "\u{00EB}", "\u{00E8}", "\u{00EF}", "\u{00EE}", "\u{00EC}", "\u{00C4}", "\u{00C5}",
        "\u{00C9}", "\u{00E6}", "\u{00C6}", "\u{00F4}", "\u{00F6}", "\u{00F2}", "\u{00FB}", "\u{00F9}",
        "\u{00FF}", "\u{00D6}", "\u{00DC}", "\u{00A2}", "\u{00A3}", "\u{00A5}", "\u{20A7}", "\u{0192}",
        "\u{00E1}", "\u{00ED}", "\u{00F3}", "\u{00FA}", "\u{00F1}", "\u{00D1}", "\u{00AA}", "\u{00BA}",
        "\u{00BF}", "\u{2310}", "\u{00AC}", "\u{00BD}", "\u{00BC}", "\u{00A1}", "\u{00AB}", "\u{00BB}",
        "\u{2591}", "\u{2592}", "\u{2593}", "\u{2502}", "\u{2524}", "\u{2561}", "\u{2562}", "\u{2556}",
        "\u{2555}", "\u{2563}", "\u{2551}", "\u{2557}", "\u{255D}", "\u{255C}", "\u{255B}", "\u{2510}",
        "\u{2514}", "\u{2534}", "\u{252C}", "\u{251C}", "\u{2500}", "\u{253C}", "\u{255E}", "\u{255F}",
        "\u{255A}", "\u{2554}", "\u{2569}", "\u{2566}", "\u{2560}", "\u{2550}", "\u{256C}", "\u{2567}",
        "\u{2568}", "\u{2564}", "\u{2565}", "\u{2559}", "\u{2558}", "\u{2552}", "\u{2553}", "\u{256B}",
        "\u{256A}", "\u{2518}", "\u{250C}", "\u{2588}", "\u{2584}", "\u{258C}", "\u{2590}", "\u{2580}",
        "\u{03B1}", "\u{00DF}", "\u{0393}", "\u{03C0}", "\u{03A3}", "\u{03C3}", "\u{00B5}", "\u{03C4}",
        "\u{03A6}", "\u{0398}", "\u{03A9}", "\u{03B4}", "\u{221E}", "\u{03C6}", "\u{03B5}", "\u{2229}",
        "\u{2261}", "\u{00B1}", "\u{2265}", "\u{2264}", "\u{2320}", "\u{2321}", "\u{00F7}", "\u{2248}",
        "\u{00B0}", "\u{2219}", "\u{00B7}", "\u{221A}", "\u{207F}", "\u{00B2}", "\u{25A0}", "\u{00A0}"
    ]

    /// Whether polling was active before the app resigned active.
    /// Used to restore polling only if it was running.
    private var wasPollingBeforeBackground = false

    /// Track previous screen rows to detect mode switches (e.g. 80x25 -> 80x50)
    private var previousScreenRows: Int = 0

    /// Track current font ID to detect mid-session font changes from BBS escape sequences
    private var lastFontId: Int = -1

    // MARK: - Initialization

    init() {
        setupTransferObserver()
        setupLifecycleObservers()
    }

    /// Observe NSApplication lifecycle notifications.
    /// On macOS we keep polling in the background so the BBS connection stays live.
    /// Only pause/resume on actual app termination, not focus changes.
    private func setupLifecycleObservers() {
        // On macOS, do NOT pause polling when the app loses focus.
        // BBS connections should remain active in the background.
    }

    /// Pause polling when the app resigns active.
    /// The connection stays open, but we stop the timer so the C threads
    /// aren't driven during inactivity.
    private func pauseForBackground() {
        wasPollingBeforeBackground = (pollingTimer != nil)
        stopPolling()
    }

    /// Resume polling when the app becomes active again.
    private func resumeFromBackground() {
        guard wasPollingBeforeBackground, connectionState == .connected else { return }

        // Check if the connection survived
        if NativeBridge.shared.isConnected() {
            startPolling()
            updateScreen()
        } else {
            // Connection died while inactive
            handleDisconnection()
        }
    }

    private func setupTransferObserver() {
        TransferManager.shared.$transferInfo
            .receive(on: DispatchQueue.main)
            .sink { [weak self] info in
                self?.transferInfo = info
            }
            .store(in: &cancellables)

        TransferManager.shared.$logLines
            .receive(on: DispatchQueue.main)
            .sink { [weak self] lines in
                self?.transferLogLines = lines
            }
            .store(in: &cancellables)

        TransferManager.shared.$isTransferring
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isTransferring in
                self?.isTransferInProgress = isTransferring
                if isTransferring {
                    self?.showTransferView = true
                }
            }
            .store(in: &cancellables)

        // The file picker or the transfer window is up: a TRACE module Rainwire closed for the transfer stays on
        // screen, dimmed (Close;hold=1), until it's gone (Windows: TransferStarted/TransferEnded around the
        // picker and the TransferDialog). The publishers fire as the values change, so read the new value given.
        Publishers.CombineLatest($showTransferView, $showUploadPicker)
            .map { $0 || $1 }
            .removeDuplicates()
            .dropFirst()
            .sink { up in
                if up {
                    TraceSessionManager.shared.transferStarted()
                } else {
                    TraceSessionManager.shared.transferEnded()
                    RainwireDesk.shared.refocusAfterDialog()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Connection

    /// Connect to a BBS entry.
    func connect(to entry: BBSEntry) {
        // Only allow connection if truly disconnected and not already connecting
        guard connectionState == .disconnected else {
            logger.info("Connect called but state is \(String(describing: self.connectionState))")
            return
        }

        logger.info("Connecting to \(entry.host):\(entry.port) font=\(entry.font.rawValue)")

        self.entry = entry
        connectionState = .connecting
        // The board a door's TRACE modules came from, recorded beside them in the cache (Settings lists it)
        let boardName = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
        TraceSessionManager.shared.bbsName = boardName.isEmpty ? entry.host : boardName
        // ...and as host:port, which the player's permissions for their imported files are kept by
        TraceSessionManager.shared.bbsKey =
            "\(entry.host.trimmingCharacters(in: .whitespaces).lowercased()):\(entry.port)"

        // The connecting overlay is a live connection log (spec §5): show it before anything else, so
        // a wait for a previous attempt is narrated too.
        ConnectionLog.shared.begin(entry: entry)

        // Reset terminal state for clean connection
        resetState()

        Task {
            // An earlier attempt that was cancelled or timed out may still be holding the line: its
            // blocking native connect keeps running until the socket is torn down, and a new
            // native_connect() would just be refused. Narrate the wait and let it finish.
            //
            // ⚠️ This has to come BEFORE destroy(): tearing the native system down while a previous
            // native_connect() is still inside it pulls the rug out from under that call. Windows
            // waits for the aborted attempt first and only then touches the native side.
            if NativeBridge.shared.isConnectInFlight {
                ConnectionLog.shared.noteWaitingForPreviousAttempt()
                await NativeBridge.shared.waitForConnectToRelease()
            }

            // Destroy and reinitialize native system for clean state
            NativeBridge.shared.destroy()

            guard NativeBridge.shared.initialize() else {
                logger.error("Failed to initialize native system")
                connectionState = .error("Failed to initialize terminal")
                return
            }
            logger.info("Native system initialized")

            // Configure terminal settings AFTER initialization
            NativeBridge.shared.setScreenMode(entry.screenMode.rawValue)
            NativeBridge.shared.setHideStatusLine(!entry.showStatusBar)
            // macOS PETSCII 2026-09-04
            self.displayAspect = entry.screenMode.displayAspect
            self.petsciiMode = entry.screenMode.isCommodore
            // Commodore modes drive their own character set: start in the LOWER
            // (text) ROM and let cterm's 0x0E / 0x8E switch take it from there.
            // The saved font is meaningless in those modes.
            if let commodoreFont = entry.screenMode.commodoreFontName {
                _ = NativeBridge.shared.setFont(commodoreFont)
            } else {
                _ = NativeBridge.shared.setFontById(entry.font.rawValue)
            }

            // Modem speed emulation (0 = full speed), set before connecting so the first byte is already metered
            NativeBridge.shared.setEmulatedBps(UserDefaults.standard.integer(forKey: AppPreferences.emulatedBaud))

            // SyncTERM APC cache for this board (C;S stores, C;L lists, images and audio load from it)
            NativeBridge.shared.setApcCacheDir(Self.apcCacheDir(for: entry))

            // Narrate the attempt in the connecting overlay (dial / resolve / handshake), so a stalled
            // board shows where it got stuck.
            ConnectionLog.shared.startTracing(entry: entry)
            let attemptStarted = Date()
            // Preferences > Terminal > Connection Timeout, read now: a change applies to the next connection
            let timeoutSeconds = AppPreferences.connectionTimeout
            self.noDataTimeoutSeconds = TimeInterval(timeoutSeconds)

            // SSH with no saved password logs in blank: no password, no prompts, the board's own login screen.
            // The native flag is global, so it is set EVERY connect.
            // A board's linked window (12.73) never has credentials (and no Keychain lookup for its ad-hoc entry).
            let linkedWindow = SessionMode.isLinked
            let blankLogin = linkedWindow ? entry.connectionProtocol == .ssh : entry.usesBlankSshLogin
            NativeBridge.shared.setSshBlankLogin(blankLogin)

            // The app's own keys in the Rainwire:Caps answer (12.72): version, language, time zone, and notify=1
            // with Settings > Board Notifications on and allowed by macOS. Native keeps them until the next set.
            // 12.73: mw=1 with Options > Let Boards Open Extra Windows on, and a linked window's own link=<token>.
            let notify = await OscExtras.notificationsAllowed()
            let linkCaps = LinkedWindows.capsForConnect()
            OscExtras.setInfo(OscExtras.appInfo(notify: notify, multiWindow: linkCaps.multiWindow,
                                                linkToken: linkCaps.linkToken))

            // Connect asynchronously (non-blocking)
            logger.info("Calling connectAsync...")
            print("[TerminalViewModel] About to call connectAsync to \(entry.host):\(entry.port)")
            let success = await NativeBridge.shared.connectAsync(
                host: entry.host,
                port: entry.port,
                protocol: entry.connectionProtocol.rawValue,
                username: linkedWindow || entry.username.isEmpty ? nil : entry.username,
                password: linkedWindow || blankLogin || entry.password?.isEmpty == true ? nil : entry.password,
                timeoutSeconds: timeoutSeconds
            )
            print("[TerminalViewModel] connectAsync returned: \(success)")
            logger.info("connectAsync returned: \(success)")

            if success {
                logger.info("Connection successful")
                connectionState = .connected
                connectedAt = Date()

                // A linked window (12.73) is part of its opener's call, not a call of its own: no call count, last
                // call, recent list or call log
                if !linkedWindow {
                    // Every successful BBS connection counts toward the elite rank (spec §8).
                    EliteRank.recordSuccessfulCall()

                    // Per-board call log; time online and data are added when the call ends
                    CallStatsService.shared.beginCall(id: entry.id.uuidString, name: entry.name,
                                                      address: "\(entry.host):\(entry.port)")
                }

                // A session started from the command line: the console says "Disconnected from ..."
                // rather than "Couldn't connect to ..." when it ends (spec §6).
                AppState.shared.consoleSession?.connected = true

                // "CONNECT", then the overlay holds briefly so a fast connect isn't a flash: the
                // session is already live and the board draws behind it.
                ConnectionLog.shared.complete(success: true, timedOut: false, cancelled: false)
                ConnectionLog.shared.holdThenHide()

                // SyncTERM audio APC output (and native's audio on/off), before the first byte is processed
                SyncTermAudioService.shared.start()

                // Start polling immediately so telnet negotiation and incoming
                // data are processed without delay.  Screen rendering will begin
                // once the renderer is ready.
                startPolling()

                if rendererReady {
                    startTerminalRendering()
                } else {
                    pendingStartAfterConnect = true
                    logger.info("Waiting for renderer to be ready...")
                }

                // Start logging if enabled in settings
                if UserDefaults.standard.bool(forKey: "logging_enabled") {
                    startLogging()
                }

                // Update last connected (not for a linked window: it isn't in the phonebook)
                if !linkedWindow {
                    BBSEntryStore.shared.updateLastConnected(for: entry)
                }
            } else {
                logger.error("Connection failed to \(entry.host):\(entry.port)")
                // NativeBridge.connectAsync gives up after the connection timeout and can't tell us which happened, so
                // the elapsed time decides between "no response after Ns" and "failed after Ns".
                let timedOut = Date().timeIntervalSince(attemptStarted) >= Double(timeoutSeconds) - 0.5
                ConnectionLog.shared.complete(success: false, timedOut: timedOut, cancelled: false)
                // The log stays visible behind the failure dialog; TerminalView hides it when the
                // dialog closes.
                // A blank SSH login the board turned down (it wants a real SSH username/password): say what to
                // do, in the disconnect dialog rather than the SSH log. ssh.c logs this text in that case.
                let needsCredentials = "This board wants an SSH username/password: tick Save credentials and enter them"
                if blankLogin && NativeBridge.shared.getSshDebugLog().contains(needsCredentials) {
                    connectionState = .error("\(entry.name): \(needsCredentials) in the phonebook entry.")
                } else {
                    connectionState = .error("Failed to connect to \(entry.host):\(entry.port)")
                }
            }
        }
    }

    /// The name a board notification with no title shows (12.72): the board's OSC title, else the phonebook name.
    private var boardDisplayName: String {
        if let title = BoardTitle.current {
            return title
        }
        let name = entry?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? (entry?.host ?? "TERMinator") : name
    }

    /// Disconnect from the current connection.
    func disconnect() {
        guard connectionState == .connected else { return }

        connectionState = .disconnecting
        stopPolling()

        if isLogging {
            stopLogging()
        }

        SoundtrackManager.shared.stop()
        SyncTermAudioService.shared.stop()
        TraceSessionManager.shared.closeAll()   // TRACE modules end with the call
        RainwireDesk.shared.reset()             // and a Rainwire board's windows
        RainwireFileDrops.shared.reset()        // and its file drops
        hideAllPics()                           // and its TERMinator:Pic pictures
        RainwireMenuView.shared.reset()         // and its menu drawn here (Rainwire:UI, 1.1.6)
        BoardTitle.set(nil)                     // and the board's OSC title (12.62)
        BoardNotifier.reset()                   // and a board notification still waiting (12.72)
        clearTapPlusOverlays()
        closeCallLog()
        NativeBridge.shared.disconnect()
        connectedAt = nil
        connectionState = .disconnected
    }

    /// Closes the call in the call log with the native byte counters. They are still readable after a disconnect:
    /// only the next connect (or native_destroy) resets them. Does nothing if no call is open.
    private func closeCallLog() {
        let stats = NativeBridge.shared.getConnectionStats()
        CallStatsService.shared.endCall(bytesSent: stats?.bytesSent ?? 0, bytesReceived: stats?.bytesReceived ?? 0)
    }

    // MARK: - Renderer Readiness

    /// Called when the NSView is attached to a window and has correct scale.
    /// This ensures first render happens with proper backing store.
    func rendererDidBecomeReady() {
        guard !rendererReady else { return }
        rendererReady = true
        logger.info("Renderer ready")

        if pendingStartAfterConnect && connectionState == .connected {
            pendingStartAfterConnect = false
            startTerminalRendering()
        }
    }

    /// Start terminal rendering after both connection and renderer are ready.
    private func startTerminalRendering() {
        loadFontBitmap()
        logger.info("Font loaded: \(self.fontWidth)x\(self.fontHeight)")
        updateScreen()
    }

    // MARK: - Data Polling

    private func startPolling() {
        connectionStartTime = Date()
        hasReceivedData = false
        appNapActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "Active BBS terminal connection"
        )
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollData()
            }
        }
        startDataPump()
    }

    /// Counts received bytes, publishing at most twice a second: bytesReceived is @Published, and setting it on
    /// every pass re-evaluated the whole TerminalView dozens of times a second while a door streamed.
    private var unpublishedReceived = 0
    private var lastReceivedPublish: TimeInterval = 0
    private func addReceived(_ count: Int, flush: Bool = false) {
        unpublishedReceived += count
        let now = ProcessInfo.processInfo.systemUptime
        if unpublishedReceived > 0 && (flush || now - lastReceivedPublish >= 0.5) {
            bytesReceived += unpublishedReceived
            unpublishedReceived = 0
            lastReceivedPublish = now
        }
    }

    /// Publishes the upload counter, at most twice a second like addReceived. It reads the native count, which also
    /// has the bytes sent past this model: TRACE module -> door data, physical key reports, terminal replies.
    private var lastSentPublish: TimeInterval = 0
    private func refreshSent(flush: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard flush || now - lastSentPublish >= 0.5 else { return }
        lastSentPublish = now
        guard let stats = NativeBridge.shared.getConnectionStats() else { return }
        let sent = Int(stats.bytesSent)
        if sent != bytesSent {
            bytesSent = sent
        }
    }

    private func stopPolling() {
        addReceived(0, flush: true)
        refreshSent(flush: true)
        pumpState.stop()
        pollingTimer?.invalidate()
        pollingTimer = nil
        if let activity = appNapActivity {
            ProcessInfo.processInfo.endActivity(activity)
            appNapActivity = nil
        }
    }

    /// A background thread that blocks in `native_wait_for_data` and runs the poll the moment data arrives, so a
    /// door that paces its frames on our cursor-position replies (SyncDOOM) is answered as soon as each frame lands
    /// instead of on the next 16 ms tick. Windows moved its whole poll loop off the UI thread (2026-09-15); here the
    /// processing stays on the main thread, where all of this view model's state lives, and only the wait moves.
    private func startDataPump() {
        let state = pumpState
        let generation = state.start()
        let thread = Thread { [weak self] in
            while state.isCurrent(generation) {
                // Bytes the poll isn't taking yet (modem meter, ZMODEM, a transfer) would end every wait at once:
                // the timer looks after those
                if state.held {
                    Thread.sleep(forTimeInterval: 0.016)
                    continue
                }
                guard NativeBridge.shared.waitForData(timeoutMs: 50) > 0 else {
                    // The wait returns at once when native isn't connected: don't spin until the poll notices
                    if !NativeBridge.shared.isConnected() {
                        Thread.sleep(forTimeInterval: 0.05)
                    }
                    continue
                }
                guard state.isCurrent(generation) else {
                    break
                }
                if state.claimWake() {
                    Task { @MainActor in
                        self?.pumpWake()
                    }
                }
                // Until the poll has taken the data, or the next wait returns at once and spins
                _ = state.pollDone.wait(timeout: .now() + .milliseconds(50))
            }
        }
        thread.name = "TERMinator data pump"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private func pumpWake() {
        pumpState.finishWake()
        // A wake queued just before polling stopped (a disconnect) must not poll again
        if pollingTimer != nil {
            pollData()
        }
        pumpState.pollDone.signal()
    }

    /// `Application Support/TERMinator/cache/<board>/`, as Windows' `ConnectionManager.GetApcCacheDir`: the board's
    /// name (host_port without one), the characters Windows can't put in a file name replaced with `_`, so a cache
    /// folder means the same thing on both.
    private static func apcCacheDir(for entry: BBSEntry) -> String? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let trimmed = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "\(entry.host)_\(entry.port)" : trimmed
        var safe = String(name.map { ch -> Character in
            if "\"<>|:*?\\/".contains(ch) || (ch.asciiValue.map { $0 < 32 } ?? false) {
                return "_"
            }
            return ch
        })
        while safe.hasSuffix(".") || safe.hasSuffix(" ") {
            safe.removeLast()
        }
        if safe.isEmpty {
            safe = "default"
        }
        return support.appendingPathComponent("TERMinator/cache", isDirectory: true)
            .appendingPathComponent(safe, isDirectory: true).path
    }

    private func pollData() {
        guard connectionState == .connected, !isTransferInProgress else {
            pumpState.held = isTransferInProgress
            return
        }

        // Check connection
        if !NativeBridge.shared.isConnected() {
            handleDisconnection()
            return
        }

        // Process everything that's waiting before drawing once (Windows: up to 64 reads per pass), so a frame the
        // size of SyncDOOM's (~20 KB) isn't spread over five ticks at 4 KB a read. Capped at ~12 ms so a flood
        // can't starve the UI; whatever's left is taken on the next pass.
        var result = 0
        var processed = 0
        let batchStart = ProcessInfo.processInfo.systemUptime
        for _ in 0..<64 {
            result = NativeBridge.shared.processData()
            if result > 0 {
                processed += result
            }

            // TAP+ commands (OSC 800) queue natively 64 deep: drain them as the data that carries them goes through
            while NativeBridge.shared.checkAudioCommand() {
                if let cmd = NativeBridge.shared.getAudioCommand() {
                    if !SoundtrackManager.shared.handleCommand(cmd) {
                        handleTapPlusCommand(cmd)
                    } else {
                        handleAudioVisualSideEffects(cmd)
                    }
                }
            }
            // TRACE commands, in the order the board sent them (Bridge/apc/trace_bridge.c queues them 4096 deep)
            while let traceItem = NativeBridge.shared.tracePoll() {
                switch traceItem {
                case .text(let command):
                    TraceSessionManager.shared.handle(command)
                case .binary(let frame):
                    TraceSessionManager.shared.handleBinary(frame)
                }
            }
            // Rainwire's window messages (Bridge/apc/wm_bridge.c queues them 4096 deep), in the same pass
            RainwireDesk.shared.poll()
            // Rainwire's pictures, TERMinator:Pic (Bridge/apc/pic_bridge.c), in the order the board sent them
            while let picCommand = NativeBridge.shared.picPoll() {
                handlePicCommand(picCommand)
            }
            // Rainwire's menus drawn here, Rainwire:UI (Bridge/apc/ui_bridge.c, 1.1.6), in the order the board sent them
            while let uiMessage = NativeBridge.shared.uiPoll() {
                RainwireMenuView.shared.handle(uiMessage)
            }
            // The board's OSC 0/2 window title and OSC 52 clipboard writes (Bridge/apc/osc_ext.c, 12.62)
            if let boardTitle = OscExtras.pollTitle() {
                BoardTitle.set(boardTitle)
            }
            if let clipText = OscExtras.pollClipboard() {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(clipText, forType: .string)
                showToast("Copied from the BBS")
            }
            // ... and its OSC 777 notifications, shown only while this window isn't in front (12.72)
            while let note = OscExtras.pollNotify() {
                BoardNotifier.post(title: note.title, body: note.body, boardName: boardDisplayName)
            }
            // ... and its Rainwire:Link requests (12.73): Open starts a linked window beside this one, Raise brings
            // it forward
            while let link = OscExtras.pollLink() {
                if link.open {
                    LinkedWindows.open(link, from: entry, connected: connectionState == .connected)
                } else {
                    LinkedWindows.raise(kind: link.kind)
                }
            }
            // The session log's native buffer holds 64 KB
            if isLogging, let logData = NativeBridge.shared.getLoggedData() {
                SessionLogger.shared.logData(logData)
            }

            // A running TRACE module (Dead Modem TV streams constantly) gets short passes, so clicks, keys and the
            // module's frames aren't queued behind 12 ms of reading on the main thread (Windows reads off it)
            let passBudget = TraceSessionManager.shared.sessions.isEmpty ? 0.012 : 0.004
            if result <= 0 || ProcessInfo.processInfo.systemUptime - batchStart > passBudget {
                break
            }
        }
        // Waiting bytes this pass didn't take: the modem meter (-102), a ZMODEM hand-off (-100 / -101), or the
        // upload picker being open (native returns 0 and leaves the ZRINIT queued)
        pumpState.held = result < 0 || (processed == 0 && NativeBridge.shared.dataWaiting() > 0)

        // Track bytes received (positive result indicates bytes processed)
        refreshSent()   // also picks up what went out past this model (a TRACE module's door data)
        if processed > 0 {
            addReceived(processed)
            hasReceivedData = true
        } else if result == -102 {
            // Data from the board is waiting on the modem speed meter: it counts against the no-data timeout
            hasReceivedData = true
        }

        // No-data timeout: if connected but no data received within timeout, disconnect
        if !hasReceivedData,
           let startTime = connectionStartTime,
           Date().timeIntervalSince(startTime) >= noDataTimeoutSeconds {
            logger.warning("No data received within \(self.noDataTimeoutSeconds)s, disconnecting")
            stopPolling()
            SoundtrackManager.shared.stop()
            SyncTermAudioService.shared.stop()
            TraceSessionManager.shared.closeAll()   // TRACE modules end with the call
            RainwireDesk.shared.reset()             // and a Rainwire board's windows
            RainwireFileDrops.shared.reset()        // and its file drops
            hideAllPics()                           // and its TERMinator:Pic pictures
            RainwireMenuView.shared.reset()         // and its menu drawn here (Rainwire:UI, 1.1.6)
            clearTapPlusOverlays()
            if isLogging { stopLogging() }
            closeCallLog()
            NativeBridge.shared.disconnect()
            connectedAt = nil
            connectionState = .error("Connection timed out — no data received")
            return
        }

        // Detect mid-session font changes from BBS escape sequences
        let currentFontId = NativeBridge.shared.getCurrentFontId()
        if currentFontId != lastFontId {
            lastFontId = currentFontId
            loadFontBitmapForCurrentFont()
        }

        // Check for ZMODEM detection
        if result == ZMODEM_DOWNLOAD_DETECTED {
            // ZMODEM download detected
            handleZmodemDownload()
            return
        } else if result == ZMODEM_UPLOAD_READY {
            // ZMODEM upload ready
            handleZmodemUploadReady()
            return
        }

        // Check for bell (silent while the Boss Hide screen is up)
        if NativeBridge.shared.checkBell() && !AppState.shared.bossHideActive {
            BellManager.shared.playBell()
        }

        // Toggle cursor blink state
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastCursorBlinkToggle >= cursorBlinkInterval {
            cursorBlinkOn.toggle()
            lastCursorBlinkToggle = now
            // Text blink toggles every 2nd cursor tick = 266ms (matching SyncTERM)
            blinkTickCount += 1
            if blinkTickCount >= 2 {
                blinkTickCount = 0
                textBlinkOn.toggle()
            }
            displayBufferVersion += 1
        }

        // Update screen if dirty. A pass that changed no cell (a sixel / JPEG XL frame) skips the text fetch and
        // URL scan and only refreshes the cursor and the graphics layer (Windows 2026-09-15). Sixel-dirty on its own
        // counts too, so a pure-graphics update isn't dropped.
        let textDirty = NativeBridge.shared.isScreenDirty()
        if textDirty || processed > 0 {
            updateScreen(textChanged: textDirty || screenBuffer.isEmpty)
            lastScreenUpdateTime = now
        } else if NativeBridge.shared.isSixelDirty() {
            refreshSixelOverlay()
        }

        // Idle-based cursor visibility: hide while data streams, show when idle
        let wasIdle = cursorIdle
        cursorIdle = (now - lastScreenUpdateTime) >= cursorIdleThreshold
        if cursorIdle != wasIdle {
            displayBufferVersion += 1
        }

    }

    private func handleDisconnection() {
        // Stop polling first to prevent re-entry
        stopPolling()
        SoundtrackManager.shared.stop()
        SyncTermAudioService.shared.stop()
        TraceSessionManager.shared.closeAll()   // TRACE modules end with the call
        RainwireDesk.shared.reset()             // and a Rainwire board's windows
        RainwireFileDrops.shared.reset()        // and its file drops
        hideAllPics()                           // and its TERMinator:Pic pictures
        RainwireMenuView.shared.reset()         // and its menu drawn here (Rainwire:UI, 1.1.6)
        BoardTitle.set(nil)                     // and the board's OSC title (12.62)
        BoardNotifier.reset()                   // and a board notification still waiting (12.72)
        clearTapPlusOverlays()

        // Process any remaining data in the buffer before showing disconnect
        var processedMore = true
        while processedMore {
            let result = NativeBridge.shared.processData()
            if result > 0 {
                addReceived(result)
            } else {
                processedMore = false
            }
        }

        // Final screen update to show goodbye message
        updateScreen()

        if isLogging {
            stopLogging()
        }

        // The call ended here; the later "disconnect" from the dialog finds nothing open
        closeCallLog()

        // A linked window (12.73) closes quietly, with no Disconnected dialog: the board ends it when the main call
        // ends
        if SessionMode.isLinked {
            SessionMode.close()
            return
        }

        // Delay before showing disconnect alert so user can see final content
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.connectionState = .error("Connection closed by remote host")
        }
    }

    // MARK: - Screen Update

    private func updateScreen(textChanged: Bool = true) {
        // Get screen size
        let size = NativeBridge.shared.getScreenSize()
        // Only on a change: each assignment of a @Published re-evaluates the whole TerminalView
        if screenColumns != size.columns { screenColumns = size.columns }
        if screenRows != size.rows { screenRows = size.rows }

        // Reload font when screen rows change (e.g. 80x25 -> 80x50 mode switch)
        if screenRows != previousScreenRows && previousScreenRows > 0 {
            loadFontBitmap()
        }
        previousScreenRows = screenRows

        // Get screen buffer (skipped when no cell changed; see pollData)
        if !textChanged {
            // Cursor, palette and graphics below still refresh
        } else if case let (buffer, fgRGB, bgRGB)? = NativeBridge.shared.getScreenBufferRGB() {
            // Only log occasionally to avoid spam
            if screenBuffer.isEmpty {
                logger.info("Got screen buffer: \(buffer.count) cells, \(size.columns)x\(size.rows)")

                // Debug: log first 20 non-space cells
                var debugCells: [String] = []
                for (i, cell) in buffer.enumerated() {
                    let charCode = Int(cell & 0xFF)
                    let fg = Int((cell >> 16) & 0xF)
                    let bg = Int((cell >> 24) & 0xF)
                    if charCode != 32 && charCode != 0 {  // Not space or null
                        debugCells.append("[\(i):c\(charCode)/fg\(fg)/bg\(bg)]")
                        if debugCells.count >= 20 { break }
                    }
                }
                if debugCells.isEmpty {
                    logger.info("Screen buffer has no visible chars (all space/null)")
                } else {
                    logger.info("First visible cells: \(debugCells.joined(separator: " "))")
                }
            }
            screenBuffer = buffer
            screenFgRGB = fgRGB
            screenBgRGB = bgRGB
            screenBufferVersion += 1

            // Keep display buffer in sync
            if scrollbackOffset > 0 {
                rebuildDisplayBuffer()
            } else {
                displayBuffer = buffer
                displayFgRGB = fgRGB
                displayBgRGB = bgRGB
                displayBufferVersion += 1
            }

            detectURLs()
        } else {
            logger.warning("getScreenBuffer returned nil!")
        }

        // Get cursor position
        let cursor = NativeBridge.shared.getCursorPos()
        let visible = NativeBridge.shared.isCursorVisible()
        if !textChanged && (cursor.x != cursorX || cursor.y != cursorY || visible != cursorVisible) {
            displayBufferVersion += 1   // the cursor moved without a cell changing: it still has to be redrawn
        }
        // Published: assigned only on a change, now that a pass runs on every data arrival
        if cursorX != cursor.x { cursorX = cursor.x }
        if cursorY != cursor.y { cursorY = cursor.y }
        if cursorVisible != visible { cursorVisible = visible }

        // Sync cursor shape from the BBS (block / underline / custom range / blink)
        let newType = NativeBridge.shared.getCursorType()
        let newStart = NativeBridge.shared.getCursorStart()
        let newEnd = NativeBridge.shared.getCursorEnd()
        let newBlinks = NativeBridge.shared.getCursorBlinks()
        if newType != cursorType { cursorType = newType }
        if newStart != cursorStart { cursorStart = newStart }
        if newEnd != cursorEnd { cursorEnd = newEnd }
        if newBlinks != cursorBlinks { cursorBlinks = newBlinks }

        // Get palette
        if let pal = NativeBridge.shared.getPalette() {
            if pal != palette {
                if !textChanged {
                    displayBufferVersion += 1   // recoloured cells with no cell change still need a redraw
                }
                palette = pal
            }
        }

        // Refresh sixel overlay
        refreshSixelOverlay()
    }

    /// Refresh the sixel pixel overlay from native data: only the rectangle that changed is copied, straight into the
    /// buffer the renderer reads (it used to be the whole layer, copied three times over, on every dirty frame).
    private func refreshSixelOverlay() {
        let hasSixel = NativeBridge.shared.hasSixelData()

        if !hasSixel {
            if hasSixelData {
                sixelPixels = nil
                hasSixelData = false
                sixelWidth = 0
                sixelHeight = 0
                sixelDirtyRect = nil
                displayBufferVersion += 1
            }
            if NativeBridge.shared.isSixelDirty() {
                // An emptied layer stays dirty until it's read, which would ask for this every pass: let native clear it
                var none: [UInt32] = []
                _ = NativeBridge.shared.copySixelPixels(into: &none, width: 0, height: 0, full: false)
            }
            return
        }

        if !NativeBridge.shared.isSixelDirty() && sixelPixels != nil {
            return  // No changes since last read
        }

        // Taken out of the property so the copy below writes the one array in place instead of duplicating it
        var pixels = sixelPixels ?? []
        sixelPixels = nil
        let copy = NativeBridge.shared.copySixelPixels(into: &pixels, width: sixelWidth, height: sixelHeight,
                                                       full: false)
        let layer = copy.layerSize
        if copy.copied < 0 || layer.width != sixelWidth || layer.height != sixelHeight
            || pixels.count != layer.width * layer.height {
            // A new layer size: start again from a clear buffer and take everything
            guard layer.width > 0, layer.height > 0, layer.width <= 8192, layer.height <= 8192 else {
                sixelPixels = pixels.isEmpty ? nil : pixels
                return
            }
            pixels = [UInt32](repeating: 0, count: layer.width * layer.height)
            sixelWidth = layer.width
            sixelHeight = layer.height
            _ = NativeBridge.shared.copySixelPixels(into: &pixels, width: layer.width, height: layer.height,
                                                    full: true)
            sixelPixels = pixels
            hasSixelData = true
            sixelDirtyRect = nil
            displayBufferVersion += 1   // new geometry: full redraw
            return
        }

        sixelPixels = pixels
        hasSixelData = true
        if copy.copied > 0, let rect = copy.rect {
            sixelDirtyRect = sixelDirtyRect.map { $0.union(rect) } ?? rect
            sixelVersion += 1
        }
    }

    /// The sixel rectangle changed since the last call (layer pixels), for the renderer's partial update.
    func takeSixelDirtyRect() -> CGRect? {
        defer { sixelDirtyRect = nil }
        return sixelDirtyRect
    }

    // MARK: - Input

    /// Send a character to the terminal.
    func sendCharacter(_ char: Character) {
        guard connectionState == .connected else { return }

        // TAP+ image overlay: U/J to scale, ESC to dismiss (operates on channel 0)
        if imageChannels[0].active {
            switch char {
            case "u", "U":
                tapPlusScaleImage(up: true)
                return
            case "j", "J":
                tapPlusScaleImage(up: false)
                return
            case "\u{1B}":  // ESC dismisses image channel 0
                imageChannels[0].active = false
                imageChannels[0].data = nil
                return
            default:
                break
            }
        }

        resetScrollback()
        let data = String(char).data(using: .utf8) ?? Data()
        let sent = NativeBridge.shared.sendData(data)
        if sent > 0 {
            refreshSent()
        }
    }

    /// Send pasted text as one buffer (Windows TerminalCanvas Ctrl+V), not a send per character. Line breaks go out
    /// as CR and the rest as UTF-8, the same bytes typing them sends. Never read as TAP+ image overlay controls.
    func sendPaste(_ text: String) {
        guard connectionState == .connected, !text.isEmpty else { return }
        var bytes = Data()
        for char in text {
            if char == "\n" || char == "\r\n" {
                bytes.append(13)
            } else {
                bytes.append(contentsOf: Array(String(char).utf8))
            }
        }
        resetScrollback()
        if NativeBridge.shared.sendData(bytes) > 0 {
            refreshSent()
        }
    }

    /// Send a string to the terminal.
    func sendString(_ string: String) {
        guard connectionState == .connected else { return }

        // TAP+ image overlay: arrow keys to move (operates on channel 0)
        if imageChannels[0].active {
            switch string {
            case "\u{1B}[A":  // Up
                imageChannels[0].row = max(0, imageChannels[0].row - 1)
                return
            case "\u{1B}[B":  // Down
                imageChannels[0].row = min(Double((screenRows > 0 ? screenRows : 25) - 1), imageChannels[0].row + 1)
                return
            case "\u{1B}[C":  // Right
                imageChannels[0].col = min(Double((screenColumns > 0 ? screenColumns : 80) - 1), imageChannels[0].col + 1)
                return
            case "\u{1B}[D":  // Left
                imageChannels[0].col = max(0, imageChannels[0].col - 1)
                return
            default:
                break
            }
        }

        resetScrollback()
        let sent = NativeBridge.shared.sendString(string)
        if sent > 0 {
            refreshSent()
        }
    }

    /// Send a key code to the terminal.
    func sendKey(_ keyCode: Int) {
        guard connectionState == .connected else { return }
        resetScrollback()
        let sent = NativeBridge.shared.sendKey(keyCode)
        if sent > 0 {
            refreshSent()
        }
    }

    /// Send raw data to the terminal.
    func sendData(_ data: Data) {
        guard connectionState == .connected else { return }
        resetScrollback()
        let sent = NativeBridge.shared.sendData(data)
        if sent > 0 {
            refreshSent()
        }
    }

    /// Set cursor visibility manually (for toggle feature).
    func setCursorVisible(_ visible: Bool) {
        userHideCursor = !visible
    }

    // MARK: - Send Login

    /// Sends a login sequence (username + password) character-by-character,
    /// mimicking human typing speed. Matches Android TerminalActivity.sendLoginSequence().
    func sendLoginSequence() {
        guard connectionState == .connected, let entry = entry else { return }

        let username = entry.username
        guard !username.isEmpty, let password = entry.password, !password.isEmpty else { return }

        // ⚠️ Main actor, NOT DispatchQueue.global. sendData() sets @Published bytesSent;
        // doing that off the main thread while pollData() publishes on it deadlocked
        // SwiftUI (both threads parked on the ObservableObjectPublisher lock — the
        // spinning-wheel hang after Send Login, 2026-09-13). Task.sleep keeps the
        // human-typing delays without blocking the main thread.
        Task { @MainActor [weak self] in
            // Send username character by character
            for ch in username {
                let byte = UInt8(ch.asciiValue ?? 0) & 0x7F
                self?.sendData(Data([byte]))
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            // Send Enter (CR)
            self?.sendData(Data([13]))

            // Wait for BBS to show password prompt
            try? await Task.sleep(nanoseconds: 500_000_000)

            // Send password character by character
            for ch in password {
                let byte = UInt8(ch.asciiValue ?? 0) & 0x7F
                self?.sendData(Data([byte]))
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            // Send Enter (CR)
            self?.sendData(Data([13]))
        }
    }

    // MARK: - Logging

    /// Start session logging.
    func startLogging() {
        guard let entry = entry, !isLogging else { return }

        if SessionLogger.shared.startLogging(bbsName: entry.name) {
            isLogging = true
            AppState.shared.isLogging = true  // Call > Log Session's check
            NativeBridge.shared.setLoggingEnabled(true)
        }
    }

    /// Stop session logging.
    func stopLogging() {
        guard isLogging else { return }

        NativeBridge.shared.setLoggingEnabled(false)
        _ = SessionLogger.shared.stopLogging()
        isLogging = false
        AppState.shared.isLogging = false
    }

    // MARK: - File Transfer

    private func handleZmodemDownload() {
        // A Rainwire file drop's transfer runs with no dialog but the progress one (RainwireFileDrops)
        if RainwireFileDrops.shared.handleZmodem(ZMODEM_DOWNLOAD_DETECTED) {
            return
        }
        isTransferInProgress = true
        showTransferView = true

        TransferManager.shared.startReceive { [weak self] result in
            self?.isTransferInProgress = false

            switch result {
            case .success(let fileName, _):
                print("Download complete: \(fileName)")
            case .error(let message):
                print("Download failed: \(message)")
            case .cancelled:
                print("Download cancelled")
            }

            // No timed hide here: the transfer window runs its own 5 s
            // auto-close, which a click inside it stops (Windows parity).
        }
    }

    private func handleZmodemUploadReady() {
        // A Rainwire file drop's FileGo: send exactly those files, with no picker (RainwireFileDrops)
        if RainwireFileDrops.shared.handleZmodem(ZMODEM_UPLOAD_READY) {
            return
        }
        // If file(s) are queued, start the upload
        if TransferManager.shared.isUploadQueued {
            let paths = TransferManager.shared.queuedUploadPaths
            if paths.count > 1 {
                startQueuedUploadBatch(paths: paths)
            } else if let queuedPath = TransferManager.shared.queuedUploadPath {
                startQueuedUpload(path: queuedPath)
            } else if let first = paths.first {
                startQueuedUpload(path: first)
            }
        } else {
            // No file queued - prompt user to pick one
            DispatchQueue.main.async {
                self.showUploadPicker = true
            }
        }
    }

    /// Start uploading an already-queued file.
    func startQueuedUpload(path: String) {
        isTransferInProgress = true
        showTransferView = true

        let fileURL = URL(fileURLWithPath: path)
        TransferManager.shared.startSend(fileURL: fileURL) { [weak self] result in
            self?.isTransferInProgress = false
            TransferManager.shared.clearUploadQueue()

            switch result {
            case .success(let fileName, _):
                print("Upload complete: \(fileName)")
            case .error(let message):
                print("Upload failed: \(message)")
            case .cancelled:
                print("Upload cancelled")
            }

            // The transfer window closes itself (5 s auto-close, stopped by a click).
        }
    }

    /// Start uploading already-queued files as a single ZMODEM batch.
    func startQueuedUploadBatch(paths: [String]) {
        isTransferInProgress = true
        showTransferView = true

        let fileURLs = paths.map { URL(fileURLWithPath: $0) }
        TransferManager.shared.startSendBatch(fileURLs: fileURLs) { [weak self] result in
            self?.isTransferInProgress = false
            TransferManager.shared.clearUploadQueue()

            switch result {
            case .success(let fileName, _):
                print("Batch upload complete: \(fileName)")
            case .error(let message):
                print("Batch upload failed: \(message)")
            case .cancelled:
                print("Batch upload cancelled")
            }

            // The transfer window closes itself (5 s auto-close, stopped by a click).
        }
    }

    // MARK: - Rainwire file drops (RainwireWm/RainwireFileDrops.swift)

    /// FileGo: the board's ZRINIT came; send exactly these files, no picker, the transfer window for progress.
    func runDropSend(_ paths: [String]) {
        isTransferInProgress = true
        showTransferView = true

        let completion: (TransferResult) -> Void = { [weak self] result in
            self?.isTransferInProgress = false
            switch result {
            case .success(let fileName, _):
                print("Drop upload complete: \(fileName)")
            case .error(let message):
                print("Drop upload failed: \(message)")
            case .cancelled:
                print("Drop upload cancelled")
            }
            // The transfer window closes itself (5 s auto-close, stopped by a click).
        }
        let urls = paths.map { URL(fileURLWithPath: $0) }
        if urls.count > 1 {
            TransferManager.shared.startSendBatch(fileURLs: urls, completion: completion)
        } else if let url = urls.first {
            TransferManager.shared.startSend(fileURL: url, completion: completion)
        }
    }

    /// FileGet: the board's ZMODEM send came; receive into a temporary folder with no dialog but the progress one.
    /// done says whether the file arrived whole, as soon as the transfer ends (not when the window closes).
    func runDropReceive(_ folder: URL, _ done: @escaping (Bool) -> Void) {
        isTransferInProgress = true
        showTransferView = true

        TransferManager.shared.startReceive(downloadDir: folder) { [weak self] result in
            self?.isTransferInProgress = false
            // The download directory setting goes back for the next normal transfer
            NativeBridge.shared.setDownloadDir(TransferManager.resolveDownloadDirectory().path)
            switch result {
            case .success(let fileName, _):
                print("Drop download complete: \(fileName)")
                done(true)
            case .error(let message):
                print("Drop download failed: \(message)")
                done(false)
            case .cancelled:
                print("Drop download cancelled")
                done(false)
            }
        }
    }

    // MARK: - X / YMODEM

    /// Receive one or more files via X/YMODEM.
    /// `savePath` is required for XMODEM (no filename in the protocol) and nil
    /// for YMODEM, which names the file from its header block.
    func startXmodemReceive(savePath: String?, mode: Int) {
        isTransferInProgress = true
        showTransferView = true

        TransferManager.shared.startXmodemReceive(savePath: savePath, mode: mode) { [weak self] result in
            self?.isTransferInProgress = false

            switch result {
            case .success(let fileName, _):
                print("X/YMODEM download complete: \(fileName)")
            case .error(let message):
                print("X/YMODEM download failed: \(message)")
            case .cancelled:
                print("X/YMODEM download cancelled")
            }

            // The transfer window closes itself (5 s auto-close, stopped by a click).
        }
    }

    /// Send one file via X/YMODEM.
    func startXmodemSend(fileURL: URL, mode: Int) {
        isTransferInProgress = true
        showTransferView = true

        TransferManager.shared.startXmodemSend(fileURL: fileURL, mode: mode) { [weak self] result in
            self?.isTransferInProgress = false

            switch result {
            case .success(let fileName, _):
                print("X/YMODEM upload complete: \(fileName)")
            case .error(let message):
                print("X/YMODEM upload failed: \(message)")
            case .cancelled:
                print("X/YMODEM upload cancelled")
            }

            // The transfer window closes itself (5 s auto-close, stopped by a click).
        }
    }

    /// Queue a file for upload.
    func queueUpload(fileURL: URL) {
        TransferManager.shared.queueUpload(fileURL: fileURL)
        startQueuedUploadIfReady()
    }

    /// Queue multiple files for a batch upload.
    func queueUploadBatch(fileURLs: [URL]) {
        TransferManager.shared.queueUploadBatch(fileURLs: fileURLs)
        startQueuedUploadIfReady()
    }

    /// Send a just-queued file when the BBS is already sitting at ZRINIT.
    ///
    /// The -101 upload-ready event fires once, and when nothing was queued yet
    /// it only opens the file picker. The native flag then latches, so the read
    /// loop parks and never reports upload-ready again. Without this the file
    /// chosen in that picker is queued and nothing else ever happens: no
    /// transfer, no progress window.
    private func startQueuedUploadIfReady() {
        guard TransferManager.shared.isUploadReady, !isTransferInProgress else { return }

        let paths = TransferManager.shared.queuedUploadPaths
        if paths.count > 1 {
            startQueuedUploadBatch(paths: paths)
        } else if let path = paths.first ?? TransferManager.shared.queuedUploadPath {
            startQueuedUpload(path: path)
        }
    }

    /// Cancel the current transfer.
    func cancelTransfer() {
        TransferManager.shared.cancelTransfer()
    }

    // MARK: - TAP+ Multimedia Commands

    /// Handle non-audio TAP+ commands (visualizer, images, video).
    /// Called when SoundtrackManager doesn't recognize the command.
    func handleTapPlusCommand(_ cmd: String) {
        // TAP+ uses both ; and : as delimiters (coordinates often use :)
        let normalized = cmd.replacingOccurrences(of: ":", with: ";")
        let parts = normalized.components(separatedBy: ";")
        guard !parts.isEmpty else { return }

        switch parts[0].lowercased() {
        case "visualizer":
            if parts.count >= 6, parts[1].lowercased() == "on" {
                guard let row1 = Double(parts[2]), let col1 = Double(parts[3]),
                      let row2 = Double(parts[4]), let col2 = Double(parts[5]) else { return }
                let vizStyle = parts.count >= 7 ? parts[6] : "bars"
                visualizerRow = row1
                visualizerCol = col1
                visualizerCellW = col2 - col1 + 1
                visualizerCellH = row2 - row1 + 1
                visualizerStyle = vizStyle
                visualizerActive = true
            } else if parts.count >= 2, parts[1].lowercased() == "off" {
                visualizerActive = false
            }

        case "video":
            if parts.count >= 6, parts[1].lowercased() == "on" {
                guard let row1 = Double(parts[2]), let col1 = Double(parts[3]),
                      let row2 = Double(parts[4]), let col2 = Double(parts[5]) else { return }
                let displayName = parts.count >= 7 ? parts[6] : nil
                videoRow = row1
                videoCol = col1
                videoCellW = col2 - col1 + 1
                videoCellH = row2 - row1 + 1
                if let displayName = displayName {
                    resolveAndShowVideo(displayName: displayName)
                }
                videoActive = true
            } else if parts.count >= 2, parts[1].lowercased() == "off" {
                videoStatusObserver?.invalidate()
                videoStatusObserver = nil
                videoPlayer?.pause()
                videoPlayer = nil
                videoActive = false
                videoURL = nil
                videoNativeWidth = 0
                videoNativeHeight = 0
            }

        case "videomove":
            guard parts.count >= 3,
                  let r = Double(parts[1]), let c = Double(parts[2]) else { return }
            videoRow = r
            videoCol = c

        case "videoset":
            guard parts.count >= 5,
                  let row1 = Double(parts[1]), let col1 = Double(parts[2]),
                  let row2 = Double(parts[3]), let col2 = Double(parts[4]) else { return }
            videoRow = row1
            videoCol = col1
            videoCellW = col2 - col1 + 1
            videoCellH = row2 - row1 + 1

        case "imgshow":
            guard let displayName = parts.count >= 2 ? parts[1] : nil else { return }
            let ch = parts.count >= 3 ? (Int(parts[2]) ?? 0) : 0
            guard ch >= 0 && ch < 8 else { return }
            resolveAndShowImage(displayName: displayName, channel: ch)

        case "imgmove":
            guard parts.count >= 3,
                  let r = Double(parts[1]), let c = Double(parts[2]) else { return }
            let ch = parts.count >= 4 ? (Int(parts[3]) ?? 0) : 0
            guard ch >= 0 && ch < 8 else { return }
            imageChannels[ch].row = r
            imageChannels[ch].col = c
            imageChannels[ch].positionSet = true

        case "imgresize":
            guard parts.count >= 3,
                  let w = Double(parts[1]), let h = Double(parts[2]) else { return }
            let ch = parts.count >= 4 ? (Int(parts[3]) ?? 0) : 0
            guard ch >= 0 && ch < 8 else { return }
            imageChannels[ch].cellW = w
            imageChannels[ch].cellH = h
            imageChannels[ch].positionSet = true

        case "imgset":
            guard parts.count >= 5,
                  let row1 = Double(parts[1]), let col1 = Double(parts[2]),
                  let row2 = Double(parts[3]), let col2 = Double(parts[4]) else { return }
            let ch = parts.count >= 6 ? (Int(parts[5]) ?? 0) : 0
            guard ch >= 0 && ch < 8 else { return }
            imageChannels[ch].row = row1
            imageChannels[ch].col = col1
            imageChannels[ch].cellW = col2 - col1 + 1
            imageChannels[ch].cellH = row2 - row1 + 1
            imageChannels[ch].positionSet = true

        case "imghide":
            let ch = parts.count >= 2 ? (Int(parts[1]) ?? 0) : 0
            guard ch >= 0 && ch < 8 else { return }
            imageChannels[ch].data = nil
            imageChannels[ch].active = false
            imageChannels[ch].positionSet = false

        case "bgshow":
            guard let displayName = parts.count >= 2 ? parts[1] : nil else { return }
            resolveAndShowBgImage(displayName: displayName)

        case "bgset":
            guard parts.count >= 5,
                  let row1 = Double(parts[1]), let col1 = Double(parts[2]),
                  let row2 = Double(parts[3]), let col2 = Double(parts[4]) else { return }
            // Stored 0-based (the command is 1-based), like Windows TapCoordinateMapper.CellsToPixels (row - 1,
            // col - 1); 0,0 stays the full-screen default
            bgRow = max(row1 - 1, 0)
            bgCol = max(col1 - 1, 0)
            bgCellW = col2 - col1 + 1
            bgCellH = row2 - row1 + 1
            bgPositionSet = true

        case "bghide":
            bgImageData = nil
            bgActive = false
            bgPositionSet = false

        case "bgopacity":
            guard parts.count >= 2, let val = Double(parts[1]) else { return }
            bgOpacity = max(0.0, min(1.0, val))

        case "tileset":
            guard parts.count >= 4,
                  let tileW = Int(parts[2]), let tileH = Int(parts[3]) else { return }
            let displayName = parts[1]
            tileSpriteW = tileW
            tileSpriteH = tileH
            resolveAndLoadTileAtlas(displayName: displayName)

        case "tilemap":
            guard parts.count >= 5,
                  let r1 = Int(parts[1]), let c1 = Int(parts[2]),
                  let r2 = Int(parts[3]), let c2 = Int(parts[4]) else { return }
            tileMapRow1 = r1 - 1
            tileMapCol1 = c1 - 1
            tileMapRow2 = r2 - 1
            tileMapCol2 = c2 - 1
            let gridRows = r2 - r1 + 1
            let gridCols = c2 - c1 + 1
            let newGrid = Array(repeating: Array(repeating: -1, count: gridCols), count: gridRows)
            _tileGridBatch = nil  // reset batch buffer on new tilemap
            workingGrid = newGrid
            tileMapActive = true

        case "tile":
            guard parts.count >= 4,
                  let row = Int(parts[1]), let col = Int(parts[2]),
                  let spriteId = Int(parts[3]) else { return }
            let gr = row - 1 - tileMapRow1
            let gc = col - 1 - tileMapCol1
            var grid = workingGrid
            if gr >= 0 && gr < grid.count && gc >= 0 && gc < (grid.first?.count ?? 0) {
                grid[gr][gc] = spriteId
                workingGrid = grid
            }

        case "tiles":
            guard parts.count >= 4,
                  let row = Int(parts[1]), let startCol = Int(parts[2]) else { return }
            let ids = parts[3].components(separatedBy: ",").compactMap { Int($0) }
            let gr = row - 1 - tileMapRow1
            var grid = workingGrid
            guard gr >= 0 && gr < grid.count else { return }
            for (i, spriteId) in ids.enumerated() {
                let gc = startCol - 1 - tileMapCol1 + i
                if gc >= 0 && gc < (grid.first?.count ?? 0) {
                    grid[gr][gc] = spriteId
                }
            }
            workingGrid = grid

        case "tilefill":
            guard parts.count >= 6,
                  let r1 = Int(parts[1]), let c1 = Int(parts[2]),
                  let r2 = Int(parts[3]), let c2 = Int(parts[4]),
                  let spriteId = Int(parts[5]) else { return }
            var grid = workingGrid
            for row in r1...r2 {
                let gr = row - 1 - tileMapRow1
                guard gr >= 0 && gr < grid.count else { continue }
                for col in c1...c2 {
                    let gc = col - 1 - tileMapCol1
                    if gc >= 0 && gc < (grid.first?.count ?? 0) {
                        grid[gr][gc] = spriteId
                    }
                }
            }
            workingGrid = grid

        case "tilemapclear":
            _tileGridBatch = nil
            tileBatchMode = false
            tileGrid = tileGrid.map { $0.map { _ in -1 } }
            tileMapActive = false
            tileScaleOverride = 0

        case "tilescale":
            guard parts.count >= 2, let val = Int(parts[1]) else { return }
            if val <= 1 { tileScaleOverride = 1 }
            else if val <= 2 { tileScaleOverride = 2 }
            else { tileScaleOverride = 4 }
            // Force re-render (tilescale changes rendering, not grid data)
            if !tileBatchMode { tileGrid = tileGrid }

        case "tileopacity":
            guard parts.count >= 2, let val = Double(parts[1]) else { return }
            tileOpacity = max(0.0, min(1.0, val))

        case "tilebegin":
            tileBatchMode = true
            _tileGridBatch = tileGrid  // snapshot current grid into batch buffer

        case "tileend":
            let finalGrid = _tileGridBatch ?? tileGrid
            _tileGridBatch = nil
            tileBatchMode = false
            tileGrid = finalGrid  // single atomic publish triggers one render

        case "tilerle":
            guard parts.count >= 4,
                  let row = Int(parts[1]), let startCol = Int(parts[2]),
                  tileMapActive else { return }
            let rleTokens = parts[3].components(separatedBy: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            let rleGr = row - 1 - tileMapRow1
            var grid = workingGrid
            guard rleGr >= 0 && rleGr < grid.count,
                  rleTokens.count >= 2 && rleTokens.count % 2 == 0 else { return }
            let rleCols = grid.first?.count ?? 0
            var rleGc = startCol - 1 - tileMapCol1
            var rleIdx = 0
            while rleIdx < rleTokens.count - 1 {
                let id = rleTokens[rleIdx]
                let count = rleTokens[rleIdx + 1]
                for _ in 0..<count {
                    if rleGc >= 0 && rleGc < rleCols {
                        grid[rleGr][rleGc] = id
                    }
                    rleGc += 1
                }
                rleIdx += 2
            }
            workingGrid = grid

        case "tilescroll":
            guard parts.count >= 3,
                  let dx = Int(parts[1]), let dy = Int(parts[2]),
                  tileMapActive else { return }
            let currentGrid = workingGrid
            let scrollRows = currentGrid.count
            let scrollCols = currentGrid.first?.count ?? 0
            guard scrollRows > 0 && scrollCols > 0 && (dx != 0 || dy != 0) else { return }
            var newGrid = Array(repeating: Array(repeating: -1, count: scrollCols), count: scrollRows)
            for r in 0..<scrollRows {
                let srcR = r - dy
                guard srcR >= 0 && srcR < scrollRows else { continue }
                for c in 0..<scrollCols {
                    let srcC = c - dx
                    guard srcC >= 0 && srcC < scrollCols else { continue }
                    newGrid[r][c] = currentGrid[srcR][srcC]
                }
            }
            workingGrid = newGrid

        case "tilecopy":
            guard parts.count >= 7,
                  let cpSrcRow = Int(parts[1]), let cpSrcCol = Int(parts[2]),
                  let cpDstRow = Int(parts[3]), let cpDstCol = Int(parts[4]),
                  let cpW = Int(parts[5]), let cpH = Int(parts[6]),
                  tileMapActive else { return }
            var grid = workingGrid
            let cpRows = grid.count
            let cpCols = grid.first?.count ?? 0
            let sr1 = cpSrcRow - 1 - tileMapRow1
            let sc1 = cpSrcCol - 1 - tileMapCol1
            let dr1 = cpDstRow - 1 - tileMapRow1
            let dc1 = cpDstCol - 1 - tileMapCol1
            var temp = [Int](repeating: -1, count: cpW * cpH)
            for r in 0..<cpH {
                for c in 0..<cpW {
                    let sr = sr1 + r, sc = sc1 + c
                    if sr >= 0 && sr < cpRows && sc >= 0 && sc < cpCols {
                        temp[r * cpW + c] = grid[sr][sc]
                    }
                }
            }
            for r in 0..<cpH {
                for c in 0..<cpW {
                    let dr = dr1 + r, dc = dc1 + c
                    if dr >= 0 && dr < cpRows && dc >= 0 && dc < cpCols {
                        grid[dr][dc] = temp[r * cpW + c]
                    }
                }
            }
            workingGrid = grid

        case "tileswap":
            guard parts.count >= 3,
                  let swapId1 = Int(parts[1]), let swapId2 = Int(parts[2]),
                  tileMapActive else { return }
            var grid = workingGrid
            for r in 0..<grid.count {
                for c in 0..<grid[r].count {
                    if grid[r][c] == swapId1 { grid[r][c] = swapId2 }
                    else if grid[r][c] == swapId2 { grid[r][c] = swapId1 }
                }
            }
            workingGrid = grid

        case "tilesetswap":
            guard parts.count >= 4,
                  let tw = Int(parts[2]), let th = Int(parts[3]) else { return }
            tileSpriteW = tw
            tileSpriteH = th
            resolveAndLoadTileAtlas(displayName: parts[1])

        case "logoshow":
            guard let displayName = parts.count >= 2 ? parts[1] : nil else { return }
            resolveAndShowLogo(displayName: displayName)

        case "logohide":
            logoImageData = nil
            logoActive = false
            logoPositionSet = false

        case "logoset":
            guard parts.count >= 5,
                  let row1 = Double(parts[1]), let col1 = Double(parts[2]),
                  let row2 = Double(parts[3]), let col2 = Double(parts[4]) else { return }
            logoRow = row1
            logoCol = col1
            logoCellW = col2 - col1 + 1
            logoCellH = row2 - row1 + 1
            logoPositionSet = true

        case "stop":
            // stop;channel hides that channel only; bare stop hides everything
            if parts.count >= 2, let ch = Int(parts[1]), ch >= 0, ch < 8 {
                imageChannels[ch].data = nil
                imageChannels[ch].active = false
                imageChannels[ch].positionSet = false
            } else {
                // Hide all image channels
                for i in 0..<8 {
                    imageChannels[i].data = nil
                    imageChannels[i].active = false
                    imageChannels[i].positionSet = false
                }
                // Hide video + visualizer
                videoStatusObserver?.invalidate()
                videoStatusObserver = nil
                videoPlayer?.pause()
                videoPlayer = nil
                videoActive = false
                videoURL = nil
                videoNativeWidth = 0
                videoNativeHeight = 0
                visualizerActive = false
                // Hide bg + tiles
                bgImageData = nil
                bgActive = false
                bgPositionSet = false
                tileMapActive = false
                tileScaleOverride = 0
                tileGrid = tileGrid.map { $0.map { _ in -1 } }
            }

        case "stopall":
            // Stop ALL TAP+ subsystems and audio
            SoundtrackManager.shared.stop()
            clearTapPlusOverlays()

        case "tapquery":
            logger.info("TAP+ query received, sending tapreply")
            let reply = "\u{1b}]800;tapreply\u{1b}\\"
            NativeBridge.shared.sendString(reply)

        default:
            logger.warning("Unknown TAP+ command: \(parts[0])")
        }
    }

    /// Handle visual side-effects of audio commands (play/stop/seek).
    /// Called when SoundtrackManager handled the command for audio, but
    /// we also need to update visual overlay state.
    private func handleAudioVisualSideEffects(_ cmd: String) {
        let parts = cmd.components(separatedBy: ";")
        guard !parts.isEmpty else { return }

        switch parts[0].lowercased() {
        case "play":
            guard let displayName = parts.count >= 2 ? parts[1] : nil else { return }
            if videoActive && videoPlayer == nil {
                // video;on was sent before play — resolve the file and create the player
                resolveAndShowVideo(displayName: displayName)
            } else if !videoActive {
                // Auto-detect video by file extension (no prior video;on)
                let ext = (displayName as NSString).pathExtension.lowercased()
                let videoExts: Set<String> = ["mp4", "m4v", "webm"]
                if videoExts.contains(ext) {
                    let cols = Double(screenColumns > 0 ? screenColumns : 80)
                    let rows = Double(screenRows > 0 ? screenRows : 25)
                    let cellsW = cols * 0.8
                    let cellsH = rows * 0.8
                    videoCol = 1.0 + (cols - cellsW) / 2.0
                    videoRow = 1.0 + (rows - cellsH) / 2.0
                    videoCellW = cellsW
                    videoCellH = cellsH
                    resolveAndShowVideo(displayName: displayName)
                    videoActive = true
                }
            }

        case "stop":
            // Hide all visual overlays
            for i in 0..<8 {
                imageChannels[i].data = nil
                imageChannels[i].active = false
                imageChannels[i].positionSet = false
            }
            videoStatusObserver?.invalidate()
            videoStatusObserver = nil
            videoPlayer?.pause()
            videoPlayer = nil
            videoActive = false
            videoURL = nil
            visualizerActive = false
            bgImageData = nil
            bgActive = false
            bgPositionSet = false
            tileMapActive = false
            tileScaleOverride = 0
            tileGrid = tileGrid.map { $0.map { _ in -1 } }

        case "stopall":
            // Stop ALL TAP+ subsystems and audio
            SoundtrackManager.shared.stop()
            clearTapPlusOverlays()

        case "seek":
            // Seek video player if active
            guard parts.count >= 2, let posMs = Int(parts[1]),
                  let player = videoPlayer else { return }
            let time = CMTime(value: Int64(posMs), timescale: 1000)
            player.seek(to: time)

        default:
            break
        }
    }

    private func resolveAndShowImage(displayName: String, channel: Int = 0) {
        let ch = max(0, min(channel, 7))
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            var file = SoundtrackManager.shared.resolveFile(displayName: displayName)
            if file == nil {
                for _ in 0..<40 {
                    Thread.sleep(forTimeInterval: 0.25)
                    file = SoundtrackManager.shared.resolveFile(displayName: displayName)
                    if file != nil { break }
                }
            }
            guard let file = file else { return }
            let image = Self.loadImage(from: file)
            guard let image = image else { return }
            DispatchQueue.main.async {
                // Default to 60% centered, unless imgset/imgmove/imgresize already set position
                if !self.imageChannels[ch].positionSet {
                    let cols = Double(self.screenColumns > 0 ? self.screenColumns : 80)
                    let rows = Double(self.screenRows > 0 ? self.screenRows : 25)
                    let cellsW = cols * 0.6
                    let cellsH = rows * 0.6
                    self.imageChannels[ch].cellW = cellsW
                    self.imageChannels[ch].cellH = cellsH
                    self.imageChannels[ch].col = 1.0 + (cols - cellsW) / 2.0
                    self.imageChannels[ch].row = 1.0 + (rows - cellsH) / 2.0
                }
                self.imageChannels[ch].data = image
                self.imageChannels[ch].active = true
            }
        }
    }

    private func resolveAndShowBgImage(displayName: String) {
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            var file = SoundtrackManager.shared.resolveFile(displayName: displayName)
            if file == nil {
                for _ in 0..<40 {
                    Thread.sleep(forTimeInterval: 0.25)
                    file = SoundtrackManager.shared.resolveFile(displayName: displayName)
                    if file != nil { break }
                }
            }
            guard let file = file else { return }
            let image = Self.loadImage(from: file)
            guard let image = image else { return }
            DispatchQueue.main.async {
                if !self.bgPositionSet {
                    self.bgRow = 0.0
                    self.bgCol = 0.0
                    self.bgCellW = Double(self.screenColumns > 0 ? self.screenColumns : 80)
                    self.bgCellH = Double(self.screenRows > 0 ? self.screenRows : 25)
                }
                self.bgImageData = image
                self.bgActive = true
            }
        }
    }

    private func resolveAndLoadTileAtlas(displayName: String) {
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            var file = SoundtrackManager.shared.resolveFile(displayName: displayName)
            if file == nil {
                for _ in 0..<40 {
                    Thread.sleep(forTimeInterval: 0.25)
                    file = SoundtrackManager.shared.resolveFile(displayName: displayName)
                    if file != nil { break }
                }
            }
            guard let file = file else { return }
            guard let image = NSImage(contentsOf: file) else { return }
            // Extract pixel data from the atlas image
            guard let tiffData = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiffData) else { return }
            let w = bitmap.pixelsWide
            let h = bitmap.pixelsHigh
            var pixels = [UInt32](repeating: 0, count: w * h)
            for y in 0..<h {
                for x in 0..<w {
                    guard let color = bitmap.colorAt(x: x, y: y) else { continue }
                    let r = UInt32(color.redComponent * 255)
                    let g = UInt32(color.greenComponent * 255)
                    let b = UInt32(color.blueComponent * 255)
                    let a = UInt32(color.alphaComponent * 255)
                    // BGRA format to match Metal texture
                    pixels[y * w + x] = (a << 24) | (r << 16) | (g << 8) | b
                }
            }
            DispatchQueue.main.async {
                self.tileAtlasImage = image
                self.tileAtlasPixels = pixels
                self.tileAtlasWidth = w
                self.tileAtlasHeight = h
            }
        }
    }

    private func resolveAndShowLogo(displayName: String) {
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            var file = SoundtrackManager.shared.resolveFile(displayName: displayName)
            if file == nil {
                for _ in 0..<40 {
                    Thread.sleep(forTimeInterval: 0.25)
                    file = SoundtrackManager.shared.resolveFile(displayName: displayName)
                    if file != nil { break }
                }
            }
            guard let file = file else { return }
            let image = Self.loadImage(from: file)
            guard let image = image else { return }
            DispatchQueue.main.async {
                // Use logoset position if already set, otherwise auto-scale
                if !self.logoPositionSet {
                    let cols = Double(self.screenColumns > 0 ? self.screenColumns : 80)
                    let rows = Double(self.screenRows > 0 ? self.screenRows : 25)
                    let targetW = cols * 0.20
                    let imgAspect = image.size.height / max(image.size.width, 1)
                    let targetH = targetW * imgAspect * 2.0
                    self.logoCellW = max(4, min(targetW, cols))
                    self.logoCellH = max(1, min(targetH, rows * 0.25))
                    self.logoCol = cols - self.logoCellW
                    self.logoRow = rows - self.logoCellH
                }
                self.logoImageData = image
                self.logoActive = true
            }
        }
    }

    /// Load an image from a URL, supporting animated GIFs via ImageIO.
    private static func loadImage(from file: URL) -> NSImage? {
        let ext = file.pathExtension.lowercased()
        if ext == "gif" {
            return loadAnimatedGif(from: file)
        }
        return NSImage(contentsOf: file)
    }

    /// Load an animated GIF as an NSImage.
    /// NSImage can handle animated GIFs natively when loaded from data.
    private static func loadAnimatedGif(from url: URL) -> NSImage? {
        guard let data = try? Data(contentsOf: url),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        if count <= 1 {
            return NSImage(contentsOf: url)
        }
        // For macOS, load the animated GIF as a single NSImage with all frames
        // NSImage can handle animated GIFs natively when loaded from data
        return NSImage(data: data)
    }

    private var videoStatusObserver: NSKeyValueObservation?

    private func resolveAndShowVideo(displayName: String) {
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            var file = SoundtrackManager.shared.resolveFile(displayName: displayName)
            if file == nil {
                for _ in 0..<40 {
                    Thread.sleep(forTimeInterval: 0.25)
                    file = SoundtrackManager.shared.resolveFile(displayName: displayName)
                    if file != nil { break }
                }
            }
            guard let file = file else {
                logger.warning("TAP+ video: could not resolve file '\(displayName)'")
                return
            }
            logger.info("TAP+ video: resolved '\(displayName)' -> \(file.path)")
            DispatchQueue.main.async {
                self.videoURL = file
                let item = AVPlayerItem(url: file)
                let player = AVPlayer(playerItem: item)
                player.isMuted = true  // SoundtrackManager handles audio
                // Observe item status to play only when ready
                self.videoStatusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                    guard item.status == .readyToPlay else {
                        if item.status == .failed {
                            logger.error("TAP+ video failed: \(item.error?.localizedDescription ?? "unknown")")
                        }
                        return
                    }
                    DispatchQueue.main.async {
                        // Extract native video dimensions for aspect-correct overlay sizing
                        let size = item.presentationSize
                        if size.width > 0 && size.height > 0 {
                            self?.videoNativeWidth = size.width
                            self?.videoNativeHeight = size.height
                        }
                        self?.videoPlayer?.play()
                    }
                }
                self.videoPlayer = player
                self.videoActive = true
            }
        }
    }

    /// Scale the active TAP+ image overlay up or down by ~10% (channel 0).
    private func tapPlusScaleImage(up: Bool) {
        let cols = Double(screenColumns > 0 ? screenColumns : 80)
        let rows = Double(screenRows > 0 ? screenRows : 25)
        let factor = up ? 1.1 : 0.9
        var newW = imageChannels[0].cellW * factor
        var newH = imageChannels[0].cellH * factor
        // Clamp: minimum 4x3, maximum full terminal
        newW = max(4, min(newW, cols))
        newH = max(3, min(newH, rows))
        // Re-center after scaling
        let dw = newW - imageChannels[0].cellW
        let dh = newH - imageChannels[0].cellH
        imageChannels[0].cellW = newW
        imageChannels[0].cellH = newH
        imageChannels[0].col = max(1, imageChannels[0].col - dw / 2)
        imageChannels[0].row = max(1, imageChannels[0].row - dh / 2)
    }

    /// Clear all TAP+ overlay state.
    private func clearTapPlusOverlays() {
        for i in 0..<8 {
            imageChannels[i].active = false
            imageChannels[i].data = nil
            imageChannels[i].positionSet = false
        }
        videoStatusObserver?.invalidate()
        videoStatusObserver = nil
        videoPlayer?.pause()
        videoPlayer = nil
        videoActive = false
        videoURL = nil
        visualizerActive = false
        logoActive = false
        logoImageData = nil
        bgImageData = nil
        bgActive = false
        bgPositionSet = false
        tileMapActive = false
        tileScaleOverride = 0
        tileGrid = tileGrid.map { $0.map { _ in -1 } }
    }

    // MARK: - TERMinator:Pic (Rainwire's pictures, Bridge/apc/pic_bridge.c)

    /// "Show;id=n;rect=r1,c1,r2,c2;path=..." (the native side checked the name and found the file in the board's
    /// cache), "Hide;id=n", or "HideAll" (also queued by a full screen clear, in stream order). Main thread.
    private func handlePicCommand(_ command: String) {
        if command == "HideAll" {
            hideAllPics()
            return
        }
        if command.hasPrefix("Hide;id=") {
            if let hideId = Int(command.dropFirst(8)), hideId >= 0, hideId < Self.maxPicSlots {
                hidePic(hideId)
            }
            return
        }
        guard command.hasPrefix("Show;") else { return }
        // Queued just before the call ended: the disconnect has cleared the slots already
        guard connectionState == .connected else { return }

        // path= is last and runs to the end (a folder name may hold ';')
        let body = command.dropFirst(5)
        guard let pathRange = body.range(of: ";path=") else { return }
        let path = String(body[pathRange.upperBound...])
        var id = -1
        var rect: [Int]? = nil
        for part in body[..<pathRange.lowerBound].split(separator: ";") {
            if part.hasPrefix("id="), let n = Int(part.dropFirst(3)) {
                id = n
            } else if part.hasPrefix("rect=") {
                let nums = part.dropFirst(5).split(separator: ",", omittingEmptySubsequences: false).compactMap { Int($0) }
                if nums.count == 4 {
                    rect = nums
                }
            }
        }
        guard id >= 0, id < Self.maxPicSlots, let rect = rect, !path.isEmpty else { return }
        showPic(id, path: path, row1: rect[0], col1: rect[1], row2: rect[2], col2: rect[3])
    }

    private func showPic(_ id: Int, path: String, row1: Int, col1: Int, row2: Int, col2: Int) {
        let file = URL(fileURLWithPath: path)
        // Loaded here, on the main thread, so a Hide or clear right behind the Show finds it in place (the file is
        // local, in the board's cache). TAP+'s loader: GIFs through ImageIO, read whole, so the cache file isn't held.
        guard FileManager.default.fileExists(atPath: file.path), let image = Self.loadImage(from: file) else {
            logger.warning("Pic slot \(id) couldn't load \(path)")
            hidePic(id)
            return
        }
        // An animated GIF loops forever whatever its own loop count says; one frame just shows still
        var pixelW: CGFloat = 0
        var pixelH: CGFloat = 0
        for rep in image.representations {
            if let bitmap = rep as? NSBitmapImageRep {
                bitmap.setProperty(.loopCount, withValue: 0)
            }
            if pixelW <= 0 || pixelH <= 0 {
                pixelW = CGFloat(rep.pixelsWide)
                pixelH = CGFloat(rep.pixelsHigh)
            }
        }
        if pixelW <= 0 || pixelH <= 0 {
            pixelW = image.size.width
            pixelH = image.size.height
        }

        // A Show on a busy slot replaces it
        var slot = PicSlot()
        slot.active = true
        slot.image = image
        slot.row1 = row1
        slot.col1 = col1
        slot.row2 = row2
        slot.col2 = col2
        slot.pixelW = pixelW
        slot.pixelH = pixelH
        picSlots[id] = slot
    }

    private func hidePic(_ id: Int) {
        guard picSlots[id].active || picSlots[id].image != nil else { return }
        picSlots[id] = PicSlot()
    }

    /// Hides every Pic slot: HideAll, a full screen clear, and disconnect.
    func hideAllPics() {
        for i in 0..<Self.maxPicSlots {
            hidePic(i)
        }
    }

    // MARK: - URL Detection

    private func detectURLs() {
        detectedURLs = []

        guard !screenBuffer.isEmpty, screenColumns > 0, screenRows > 0 else { return }

        // The board's OSC 8 links first, so a click on one opens its real address (Bridge/apc/osc_ext.c, 12.62)
        if scrollbackOffset == 0 && OscExtras.linksActive {
            for row in 0..<screenRows {
                var col = 0
                while col < screenColumns {
                    let index = row * screenColumns + col
                    guard index < screenBuffer.count else { break }
                    if let link = OscExtras.linkAt(col: col, row: row, ch: Int(screenBuffer[index] & 0xFF)),
                       link.end >= col {
                        let start = max(0, link.start)
                        let startIndex = row * screenColumns + start
                        let fgIdx = startIndex < screenBuffer.count
                            ? Int((UInt32(bitPattern: screenBuffer[startIndex]) >> 16) & 0x0F) : 7
                        detectedURLs.append(DetectedURL(url: link.url, startColumn: start, endColumn: link.end + 1,
                                                        row: row, fgColorIndex: fgIdx, isBoardLink: true))
                        col = link.end + 1
                    } else {
                        col += 1
                    }
                }
            }
        }

        // Build text from screen buffer, tracking positions
        for row in 0..<screenRows {
            var rowText = ""
            for col in 0..<screenColumns {
                let index = row * screenColumns + col
                if index < screenBuffer.count {
                    let char = NativeBridge.unpackChar(screenBuffer[index])
                    rowText.append(char)
                }
            }

            // Find URLs in this row (skip if regex failed to compile)
            guard let pattern = urlPattern else { continue }
            let range = NSRange(rowText.startIndex..., in: rowText)
            let matches = pattern.matches(in: rowText, options: [], range: range)

            for match in matches {
                if let urlRange = Range(match.range, in: rowText) {
                    let url = String(rowText[urlRange])
                    let startCol = rowText.distance(from: rowText.startIndex, to: urlRange.lowerBound)
                    let endCol = rowText.distance(from: rowText.startIndex, to: urlRange.upperBound)

                    // Get foreground color from first character of URL
                    let fgIdx: Int
                    let cellIndex = row * screenColumns + startCol
                    if cellIndex < screenBuffer.count {
                        let cellUnsigned = UInt32(bitPattern: screenBuffer[cellIndex])
                        fgIdx = Int((cellUnsigned >> 16) & 0x0F)
                    } else {
                        fgIdx = 7
                    }
                    detectedURLs.append(DetectedURL(
                        url: url,
                        startColumn: startCol,
                        endColumn: endCol,
                        row: row,
                        fgColorIndex: fgIdx
                    ))
                }
            }
        }
    }

    /// The detected URL or board link (OSC 8) at a cell, or nil.
    func linkAt(column: Int, row: Int) -> DetectedURL? {
        detectedURLs.first { $0.row == row && column >= $0.startColumn && column < $0.endColumn }
    }

    /// Shows a short notice over the terminal for two seconds (12.62), or as long as asked (file drops: 6).
    func showToast(_ message: String, seconds: Double = 2) {
        toastMessage = message
        toastWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.toastMessage = nil }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Check if a cell position contains a URL.
    func urlAt(column: Int, row: Int) -> String? {
        for detected in detectedURLs {
            if detected.row == row && column >= detected.startColumn && column < detected.endColumn {
                return detected.url
            }
        }
        return nil
    }

    /// Open a URL.
    func openURL(_ urlString: String) {
        var finalURL = urlString

        // Add protocol if missing
        if finalURL.lowercased().hasPrefix("www.") {
            finalURL = "https://" + finalURL
        }

        guard let url = URL(string: finalURL) else { return }
        NSWorkspace.shared.open(url)
    }

    // NOTE: setZoom / resetZoom / updatePan lived here and were removed 2026-09-12.
    // They maintained a zoom level and a clamped pan offset that NO render path ever read,
    // so the View menu's zoom items did nothing. BBSEntry.zoomLevel is still persisted and
    // still travels in the phonebook export — see the note there.

    // MARK: - Scrollback

    /// Set the scrollback offset and rebuild the composite display buffer.
    /// offset 0 = live screen, >0 = number of lines scrolled back into history.
    func setScrollbackOffset(_ offset: Int) {
        guard let info = NativeBridge.shared.getScrollbackInfo() else {
            scrollbackOffset = 0
            return
        }

        let maxOffset = info.filledLines
        let clamped = max(0, min(offset, maxOffset))
        scrollbackOffset = clamped

        rebuildDisplayBuffer()
    }

    /// Reset scrollback to live screen.
    func resetScrollback() {
        guard scrollbackOffset > 0 else { return }
        scrollbackOffset = 0
        displayBuffer = screenBuffer
        displayFgRGB = screenFgRGB
        displayBgRGB = screenBgRGB
        displayBufferVersion += 1
    }

    /// Toggle scrollback buffer mode (Ctrl+B, View > Scrollback, the terminal's right-click menu).
    /// If in scrollback, return to live. Otherwise, jump half a screen up into history (clamped like the scroll
    /// wheel, by setScrollbackOffset). Once scrolled back the wheel scrolls the history even when the board has
    /// mouse reporting on (TerminalMouseRules.wheelToBoard). False when there is no history yet.
    @discardableResult
    func toggleBufferMode() -> Bool {
        if scrollbackOffset > 0 {
            resetScrollback()
            return true
        }
        guard let info = NativeBridge.shared.getScrollbackInfo(), info.filledLines > 0 else { return false }
        setScrollbackOffset(min(max(1, screenRows / 2), info.filledLines))
        return scrollbackOffset > 0
    }

    /// Scroll by one page (screenRows lines) in the given direction.
    func scrollPage(up: Bool) {
        let delta = up ? screenRows : -screenRows
        setScrollbackOffset(scrollbackOffset + delta)
    }

    // MARK: - Text Selection

    /// Start text selection at the given terminal cell.
    func startSelection(col: Int, row: Int) {
        let c = max(0, min(col, screenColumns - 1))
        let r = max(0, min(row, screenRows - 1))
        isSelecting = true
        selectionAnchorCol = c
        selectionAnchorRow = r
        selectionEndCol = c
        selectionEndRow = r
    }

    /// Update the end point of the selection.
    func updateSelection(col: Int, row: Int) {
        guard isSelecting else { return }
        selectionEndCol = max(0, min(col, screenColumns - 1))
        selectionEndRow = max(0, min(row, screenRows - 1))
    }

    /// Update the anchor (start) point of the selection independently.
    func updateSelectionAnchor(col: Int, row: Int) {
        guard isSelecting else { return }
        selectionAnchorCol = max(0, min(col, screenColumns - 1))
        selectionAnchorRow = max(0, min(row, screenRows - 1))
    }

    /// Cancel any active selection.
    func cancelSelection() {
        guard isSelecting else { return }
        isSelecting = false
        selectionAnchorCol = -1
        selectionAnchorRow = -1
        selectionEndCol = -1
        selectionEndRow = -1
    }

    /// Start selection covering the center ~60% of the screen.
    func startSelectionCentered() {
        isSelecting = true
        let padCol = max(1, screenColumns / 5)   // ~20% from each side
        let padRow = max(1, screenRows / 5)
        selectionAnchorCol = padCol
        selectionAnchorRow = padRow
        selectionEndCol = screenColumns - 1 - padCol
        selectionEndRow = screenRows - 1 - padRow
    }

    /// Extract selected text from the terminal buffer, mapping to Unicode.
    func getSelectedText() -> String? {
        guard isSelecting, selectionAnchorCol >= 0 else { return nil }

        let minCol = selectionMinCol
        let maxCol = selectionMaxCol
        let minRow = selectionMinRow
        let maxRow = selectionMaxRow

        let buffer = scrollbackOffset > 0 ? displayBuffer : screenBuffer
        guard !buffer.isEmpty else { return nil }

        var lines: [String] = []
        for row in minRow...maxRow {
            var rowStr = ""
            for col in minCol...maxCol {
                let index = row * screenColumns + col
                guard index >= 0 && index < buffer.count else {
                    rowStr.append(" ")
                    continue
                }
                let cell = buffer[index]
                let charCode = Int(cell & 0xFF)
                let mapped = mapCP437Char(charCode)
                rowStr.append(mapped == "\0" ? " " : mapped)
            }
            // Trim trailing spaces per line
            lines.append(String(rowStr.reversed().drop(while: { $0 == " " }).reversed()))
        }

        let result = lines.joined(separator: "\n")
        return result.isEmpty ? nil : result
    }

    /// Rebuild the composite display buffer from scrollback + screen data.
    private func rebuildDisplayBuffer() {
        if scrollbackOffset == 0 {
            displayBuffer = screenBuffer
            displayFgRGB = screenFgRGB
            displayBgRGB = screenBgRGB
            displayBufferVersion += 1
            return
        }

        guard screenColumns > 0, screenRows > 0 else { return }

        // How many scrollback lines to show at the top of the display
        let scrollbackLinesToShow = min(scrollbackOffset, screenRows)
        // How many live screen lines remain visible at the bottom
        let screenLinesVisible = screenRows - scrollbackLinesToShow

        // Fetch scrollback lines from NativeBridge
        // offset parameter: how far back from most recent scrollback line
        // We want the lines starting at (scrollbackOffset - scrollbackLinesToShow) from the top
        let fetchOffset = scrollbackOffset - scrollbackLinesToShow
        guard case let (scrollbackCells, scrollbackFg, scrollbackBg)? = NativeBridge.shared.getScrollbackBufferRGB(
            offset: fetchOffset, count: scrollbackLinesToShow
        ) else {
            // Fallback: just show live screen
            displayBuffer = screenBuffer
            displayFgRGB = screenFgRGB
            displayBgRGB = screenBgRGB
            displayBufferVersion += 1
            return
        }

        let totalCells = screenRows * screenColumns
        var composite = [Int32](repeating: 0, count: totalCells)
        var compositeFg = [UInt32](repeating: 0, count: totalCells)
        var compositeBg = [UInt32](repeating: 0, count: totalCells)

        // Fill top rows from scrollback
        let scrollbackCellCount = min(scrollbackCells.count, scrollbackLinesToShow * screenColumns, totalCells)
        for i in 0..<scrollbackCellCount {
            composite[i] = scrollbackCells[i]
            compositeFg[i] = scrollbackFg[i]
            compositeBg[i] = scrollbackBg[i]
        }

        // Fill remaining rows from the top of the live screen buffer
        if screenLinesVisible > 0 {
            let screenCellsToCopy = screenLinesVisible * screenColumns
            let destOffset = scrollbackLinesToShow * screenColumns
            let srcCount = min(screenCellsToCopy, screenBuffer.count)
            for i in 0..<srcCount {
                composite[destOffset + i] = screenBuffer[i]
                if i < screenFgRGB.count { compositeFg[destOffset + i] = screenFgRGB[i] }
                if i < screenBgRGB.count { compositeBg[destOffset + i] = screenBgRGB[i] }
            }
        }

        displayBuffer = composite
        displayFgRGB = compositeFg
        displayBgRGB = compositeBg
        displayBufferVersion += 1
    }

    // MARK: - Snapshot

    /// Capture a snapshot of the current terminal screen.
    func captureSnapshot() -> NSImage? {
        guard !screenBuffer.isEmpty, fontWidth > 0, fontHeight > 0 else { return nil }
        guard screenColumns > 0, screenRows > 0 else { return nil }
        let width = screenColumns * fontWidth
        let height = screenRows * fontHeight
        guard width > 0, height > 0, width <= 4096, height <= 4096 else { return nil }

        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4, bitsPerPixel: 32
        )
        guard let rep = rep else { return nil }

        let context = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        guard let cgContext = context?.cgContext else {
            NSGraphicsContext.restoreGraphicsState()
            return nil
        }

        // Fill background
        cgContext.setFillColor(NSColor.black.cgColor)
        cgContext.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let paletteColors = getNSColorPalette()

        // Draw each cell (note: CGContext has flipped Y, origin at bottom-left)
        for row in 0..<screenRows {
            for col in 0..<screenColumns {
                let index = row * screenColumns + col
                guard index < screenBuffer.count else { continue }
                let cell = screenBuffer[index]
                let charCode = Int(cell & 0xFF)
                let cellUnsigned = UInt32(bitPattern: cell)
                // Use packed fg/bg bytes (matching Windows TerminalCanvas.cs)
                var fgIndex = Int((cellUnsigned >> 16) & 0x7F)
                var bgIndex = Int((cellUnsigned >> 24) & 0xFF)

                // Blink attribute: bit 15 of packed cell (bit 7 of legacy_attr)
                if (cell & 0x8000) != 0 {
                    bgIndex = bgIndex & 0x07
                    if !textBlinkOn {
                        fgIndex = bgIndex
                    }
                }
                if fgIndex >= 16 { fgIndex = fgIndex & 0x0F }
                if bgIndex >= 16 { bgIndex = bgIndex & 0x0F }

                let x = CGFloat(col * fontWidth)
                let y = CGFloat(height - (row + 1) * fontHeight) // Flip Y for CGContext
                let rect = CGRect(x: x, y: y, width: CGFloat(fontWidth), height: CGFloat(fontHeight))

                let bgColor = bgIndex < paletteColors.count ? paletteColors[bgIndex] : NSColor.black
                cgContext.setFillColor(bgColor.cgColor)
                cgContext.fill(rect)

                if let glyphImage = getGlyphImage(charCode: charCode, fgIndex: fgIndex, bgIndex: bgIndex,
                                                   targetWidth: fontWidth, targetHeight: fontHeight) {
                    cgContext.draw(glyphImage, in: rect)
                }
            }
        }

        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(rep)
        return image
    }

    /// Capture snapshot as Data for saving.
    func captureSnapshotData() -> Data? {
        guard let image = captureSnapshot(),
              let tiffData = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiffData) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// Save snapshot for the current entry.
    func saveSnapshot(_ data: Data) {
        guard let entry = entry else { return }
        BBSEntryStore.shared.updateSnapshot(data, for: entry)
    }

    /// Get NSColor palette for snapshot rendering.
    private func getNSColorPalette() -> [NSColor] {
        let defaultPalette: [NSColor] = [
            NSColor(red: 0, green: 0, blue: 0, alpha: 1),                    // 0: Black
            NSColor(red: 0, green: 0, blue: 0.667, alpha: 1),                // 1: Blue
            NSColor(red: 0, green: 0.667, blue: 0, alpha: 1),                // 2: Green
            NSColor(red: 0, green: 0.667, blue: 0.667, alpha: 1),            // 3: Cyan
            NSColor(red: 0.667, green: 0, blue: 0, alpha: 1),                // 4: Red
            NSColor(red: 0.667, green: 0, blue: 0.667, alpha: 1),            // 5: Magenta
            NSColor(red: 0.667, green: 0.333, blue: 0, alpha: 1),            // 6: Brown
            NSColor(red: 0.667, green: 0.667, blue: 0.667, alpha: 1),        // 7: Light Gray
            NSColor(red: 0.333, green: 0.333, blue: 0.333, alpha: 1),        // 8: Dark Gray
            NSColor(red: 0.333, green: 0.333, blue: 1, alpha: 1),            // 9: Light Blue
            NSColor(red: 0.333, green: 1, blue: 0.333, alpha: 1),            // 10: Light Green
            NSColor(red: 0.333, green: 1, blue: 1, alpha: 1),                // 11: Light Cyan
            NSColor(red: 1, green: 0.333, blue: 0.333, alpha: 1),            // 12: Light Red
            NSColor(red: 1, green: 0.333, blue: 1, alpha: 1),                // 13: Light Magenta
            NSColor(red: 1, green: 1, blue: 0.333, alpha: 1),                // 14: Yellow
            NSColor(red: 1, green: 1, blue: 1, alpha: 1),                    // 15: White
        ]

        if !palette.isEmpty && palette.count >= 16 {
            return palette.prefix(16).map { value in
                let uval = UInt32(bitPattern: value)
                let r = CGFloat((uval >> 16) & 0xFF) / 255.0
                let g = CGFloat((uval >> 8) & 0xFF) / 255.0
                let b = CGFloat(uval & 0xFF) / 255.0
                return NSColor(red: r, green: g, blue: b, alpha: 1)
            }
        }

        return defaultPalette
    }

    // MARK: - State Reset

    /// Reset all terminal state for a new connection.
    /// Call this before connecting to a new BBS to ensure clean state.
    private func resetState() {
        // Reset no-data timeout tracking
        hasReceivedData = false
        connectionStartTime = nil

        // Reset byte counters
        bytesReceived = 0
        unpublishedReceived = 0
        bytesSent = 0
        lastSentPublish = 0

        // Clear screen buffer (native screen cleared separately after init)
        screenBuffer = []
        screenFgRGB = []
        screenBgRGB = []

        // Reset cursor to home position
        cursorX = 0
        cursorY = 0
        cursorVisible = true
        userHideCursor = false

        // Reset screen dimensions to defaults
        screenColumns = 80
        screenRows = 25

        // Reset palette to defaults
        palette = []

        // Reset scrollback
        scrollbackOffset = 0
        displayBuffer = []
        displayFgRGB = []
        displayBgRGB = []
        displayBufferVersion += 1

        // Clear detected URLs
        detectedURLs = []

        // Clear glyph cache
        glyphCache.removeAllObjects()

        // Clear font data to force reload
        fontBitmap = nil
        fontWidth = 0
        fontHeight = 0

        // Force Metal to re-render after reset
        screenBufferVersion += 1
    }

    // MARK: - Cleanup

    func cleanup() {
        stopPolling()
        if isLogging {
            stopLogging()
        }
        SoundtrackManager.shared.stop()
        SyncTermAudioService.shared.stop()
        TraceSessionManager.shared.closeAll()   // TRACE modules end with the call
        RainwireDesk.shared.reset()             // and a Rainwire board's windows
        RainwireFileDrops.shared.reset()        // and its file drops
        hideAllPics()                           // and its TERMinator:Pic pictures
        RainwireMenuView.shared.reset()         // and its menu drawn here (Rainwire:UI, 1.1.6)
        clearTapPlusOverlays()
        TransferManager.shared.cleanup()
        cancellables.removeAll()
        glyphCache.removeAllObjects()
    }

    deinit {
        // Note: Can't call cleanup() from deinit since it's @MainActor
    }

    // MARK: - Bitmap Font Rendering

    /// Load the font bitmap from native code.
    func loadFontBitmap() {
        // Clear existing cache when font changes
        glyphCache.removeAllObjects()

        let fontIdDebug = entry?.font.rawValue ?? -1
        logger.info("loadFontBitmap called, entry.font.rawValue=\(fontIdDebug)")

        // IMPORTANT: Ensure the correct font ID is set before loading the bitmap
        // This prevents issues where another connection might have changed the font
        if let entry = entry {
            // macOS PETSCII 2026-09-04: in a Commodore mode the saved font is
            // meaningless and re-applying it here would undo the character-set
            // switch the BBS just made with 0x0E / 0x8E.
            if !entry.screenMode.isCommodore {
                _ = NativeBridge.shared.setFontById(entry.font.rawValue)
            }
        }

        // Get font bitmap data including dimensions
        if let fontInfo = NativeBridge.shared.getFontBitmap() {
            fontWidth = fontInfo.width
            fontHeight = fontInfo.height
            fontBitmap = fontInfo.data

            // Validate font dimensions
            let expectedSize = 256 * fontInfo.height * ((fontInfo.width + 7) / 8)
            if fontInfo.data.count != expectedSize {
                logger.warning("Font bitmap size mismatch: got \(fontInfo.data.count), expected \(expectedSize)")
            }

            // Log first few bytes of character 65 ('A') to verify font loaded correctly
            let char65Offset = 65 * fontInfo.height
            if fontInfo.data.count > char65Offset + fontInfo.height {
                var bytes: [String] = []
                for i in 0..<min(fontInfo.height, 16) {
                    bytes.append(String(format: "%02X", fontInfo.data[char65Offset + i]))
                }
                logger.info("Font loaded: \(fontInfo.width)x\(fontInfo.height), fontID=\(fontIdDebug), charA=[\(bytes.joined(separator: " "))]")
            } else {
                logger.info("Font loaded: \(fontInfo.width)x\(fontInfo.height), \(fontInfo.data.count) bytes, fontID=\(fontIdDebug)")
            }

            // Also log character 32 (space) to verify
            let char32Offset = 32 * fontInfo.height
            if fontInfo.data.count > char32Offset + fontInfo.height {
                var spaceBytes: [String] = []
                for i in 0..<min(fontInfo.height, 16) {
                    spaceBytes.append(String(format: "%02X", fontInfo.data[char32Offset + i]))
                }
                logger.info("Space char (32): [\(spaceBytes.joined(separator: " "))]")
            }
        } else {
            // Set default dimensions if font fails to load
            fontWidth = 8
            fontHeight = 16
            logger.error("Failed to load font bitmap, using defaults, fontID=\(fontIdDebug)")
        }
    }

    /// Load font bitmap using the current native font ID (for mid-session BBS font changes).
    /// Unlike loadFontBitmap(), this does NOT reset the font to the phonebook entry.
    private func loadFontBitmapForCurrentFont() {
        glyphCache.removeAllObjects()
        let currentId = NativeBridge.shared.getCurrentFontId()
        logger.info("BBS changed font mid-session to ID \(currentId)")

        if let fontInfo = NativeBridge.shared.getFontBitmap() {
            fontWidth = fontInfo.width
            fontHeight = fontInfo.height
            fontBitmap = fontInfo.data
            logger.info("Font reloaded: \(fontInfo.width)x\(fontInfo.height), fontID=\(currentId)")
        }
    }

    /// Map a CP437 character code to its Unicode equivalent for fallback rendering.
    func mapCP437Char(_ charCode: Int) -> Character {
        guard charCode >= 0 && charCode < 256 else { return " " }

        // Use Amiga mapping for Topaz Plus font, CP437 for others
        if let entry = entry, entry.font == .topazPlus {
            return amigaToUnicode[charCode]
        }
        return cp437ToUnicode[charCode]
    }

    /// Get a cached or newly created glyph image for rendering.
    /// Creates glyphs at the exact target pixel size to avoid scaling artifacts.
    /// - Parameters:
    ///   - charCode: The character code (0-255)
    ///   - fgIndex: Foreground color index (0-15)
    ///   - bgIndex: Background color index (0-7)
    ///   - targetWidth: Target width in pixels (must be > 0)
    ///   - targetHeight: Target height in pixels (must be > 0)
    /// - Returns: A CGImage for the glyph, or nil if bitmap font not available
    func getGlyphImage(charCode: Int, fgIndex: Int, bgIndex: Int, targetWidth: Int, targetHeight: Int) -> CGImage? {
        // Validate font data exists and dimensions are reasonable
        guard let bitmap = fontBitmap, fontWidth > 0, fontHeight > 0 else { return nil }

        // Ensure character code is valid
        guard charCode >= 0 && charCode < 256 else { return nil }

        // Ensure target size is valid
        guard targetWidth > 0 && targetHeight > 0 else { return nil }

        // Validate bitmap has enough data for this character
        let bytesPerGlyphRow = (fontWidth + 7) / 8
        let expectedOffset = (charCode + 1) * fontHeight * bytesPerGlyphRow
        guard bitmap.count >= expectedOffset else { return nil }

        // Cache key includes target size since glyphs are pre-scaled
        let cacheKey = "\(charCode)_\(fgIndex)_\(bgIndex)_\(targetWidth)x\(targetHeight)" as NSString

        // Check cache
        if let cached = glyphCache.object(forKey: cacheKey) {
            return cached
        }

        // Create new glyph image at exact target size (no scaling at draw time)
        if let glyph = createGlyphImage(charCode: charCode, fgIndex: fgIndex, bgIndex: bgIndex,
                                         targetWidth: targetWidth, targetHeight: targetHeight) {
            glyphCache.setObject(glyph, forKey: cacheKey)
            return glyph
        }

        return nil
    }

    /// Render the entire terminal to a single CGImage - like Android's Bitmap approach.
    /// This avoids sub-pixel positioning issues from drawing many small images.
    func renderTerminalImage(columns: Int, rows: Int, cellWidthPx: Int, cellHeightPx: Int) -> CGImage? {
        guard let fontBitmap = fontBitmap,
              fontWidth > 0, fontHeight > 0,
              !screenBuffer.isEmpty,
              columns > 0, rows > 0,
              cellWidthPx > 0, cellHeightPx > 0 else {
            return nil
        }

        let termWidthPx = columns * cellWidthPx
        let termHeightPx = rows * cellHeightPx
        let pixelCount = termWidthPx * termHeightPx

        // Sanity check to prevent huge allocations (max ~16MB at 4 bytes/pixel)
        guard pixelCount <= 4000 * 2000 else { return nil }

        var pixels = [UInt32](repeating: 0xFF000000, count: pixelCount)

        let fontBytes = [UInt8](fontBitmap)
        let bytesPerRow = (fontWidth + 7) / 8

        for row in 0..<rows {
            for col in 0..<columns {
                let index = row * columns + col
                guard index < screenBuffer.count else { continue }

                let cell = screenBuffer[index]
                let cellUnsigned = UInt32(bitPattern: cell)
                let charCode = Int(cellUnsigned & 0xFF)
                // Use packed fg/bg bytes (matching Windows TerminalCanvas.cs)
                var fgIndex = Int((cellUnsigned >> 16) & 0x7F)  // bits 16-22 (7 bits, bit 23 = underline)
                var bgIndex = Int((cellUnsigned >> 24) & 0xFF)  // bits 24-31

                // Blink attribute: bit 15 of packed cell (bit 7 of legacy_attr)
                if (cell & 0x8000) != 0 {
                    bgIndex = bgIndex & 0x07  // Strip leaked blink bit from background
                    if !textBlinkOn {
                        fgIndex = bgIndex  // Hide text during blink-off phase
                    }
                }

                // Clamp to palette range
                if fgIndex >= 16 { fgIndex = fgIndex & 0x0F }
                if bgIndex >= 16 { bgIndex = bgIndex & 0x0F }

                let fgColor = getColorForIndex(fgIndex)
                let bgColor = getColorForIndex(bgIndex)
                let fgPixel: UInt32 = 0xFF000000 | (fgColor & 0xFFFFFF)
                let bgPixel: UInt32 = 0xFF000000 | (bgColor & 0xFFFFFF)

                let glyphOffset = charCode * fontHeight * bytesPerRow
                let cellStartX = col * cellWidthPx
                let cellStartY = row * cellHeightPx

                for destY in 0..<cellHeightPx {
                    // Center-sampling: map destination pixel to source pixel center
                    let srcY = ((2 * destY + 1) * fontHeight) / (2 * cellHeightPx)
                    let rowOffset = glyphOffset + srcY * bytesPerRow
                    let rowByte0: UInt8 = rowOffset < fontBytes.count ? fontBytes[rowOffset] : 0
                    let rowByte1: UInt8 = (bytesPerRow > 1 && rowOffset + 1 < fontBytes.count) ? fontBytes[rowOffset + 1] : 0

                    let termY = cellStartY + destY
                    let rowStart = termY * termWidthPx

                    for destX in 0..<cellWidthPx {
                        // Center-sampling for horizontal axis
                        let srcX = ((2 * destX + 1) * fontWidth) / (2 * cellWidthPx)

                        let isSet: Bool
                        if srcX < 8 {
                            isSet = ((Int(rowByte0) >> (7 - srcX)) & 1) == 1
                        } else {
                            isSet = ((Int(rowByte1) >> (15 - srcX)) & 1) == 1
                        }

                        let termX = cellStartX + destX
                        let pixelIdx = rowStart + termX
                        guard pixelIdx < pixelCount else { continue }
                        pixels[pixelIdx] = isSet ? fgPixel : bgPixel
                    }
                }
            }
        }

        // Overlay sixel pixels onto the terminal image
        if hasSixelData, let sixelBuf = sixelPixels, sixelWidth > 0, sixelHeight > 0, fontWidth > 0, fontHeight > 0 {
            for sy in 0..<sixelHeight {
                for sx in 0..<sixelWidth {
                    let sixelIdx = sy * sixelWidth + sx
                    guard sixelIdx < sixelBuf.count else { continue }
                    let pixel = sixelBuf[sixelIdx]
                    if (pixel & 0xFF000000) != 0 {  // non-transparent
                        let destX = sx * cellWidthPx / fontWidth
                        let destY = sy * cellHeightPx / fontHeight
                        if destX < termWidthPx && destY < termHeightPx {
                            let destIdx = destY * termWidthPx + destX
                            if destIdx >= 0 && destIdx < pixelCount {
                                pixels[destIdx] = pixel
                            }
                        }
                    }
                }
            }
        }

        // Create CGImage from pixel buffer
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)

        let pixelData = pixels.withUnsafeBytes { rawBuffer -> Data in
            Data(rawBuffer)
        }

        guard let provider = CGDataProvider(data: pixelData as CFData) else { return nil }

        return CGImage(
            width: termWidthPx,
            height: termHeightPx,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: termWidthPx * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    /// Create a glyph image from the font bitmap at EXACT target size.
    /// Uses center-sampling from native font size to target size.
    private func createGlyphImage(charCode: Int, fgIndex: Int, bgIndex: Int,
                                   targetWidth: Int, targetHeight: Int) -> CGImage? {
        guard let fontBitmap = fontBitmap,
              fontWidth > 0, fontHeight > 0 else { return nil }

        let bytesPerRow = (fontWidth + 7) / 8
        let glyphOffset = charCode * fontHeight * bytesPerRow

        guard glyphOffset + fontHeight * bytesPerRow <= fontBitmap.count else { return nil }

        let fgColor = getColorForIndex(fgIndex)
        let bgColor = getColorForIndex(bgIndex)
        let fgPixel: UInt32 = 0xFF000000 | (fgColor & 0xFFFFFF)
        let bgPixel: UInt32 = 0xFF000000 | (bgColor & 0xFFFFFF)

        let pixelCount = targetWidth * targetHeight
        var pixels = [UInt32](repeating: bgPixel, count: pixelCount)

        fontBitmap.withUnsafeBytes { (fontPtr: UnsafeRawBufferPointer) in
            guard let fontBase = fontPtr.baseAddress else { return }

            for destY in 0..<targetHeight {
                // Center-sampling with clamp
                let srcY = min(fontHeight - 1, ((2 * destY + 1) * fontHeight) / (2 * targetHeight))
                let rowOffset = glyphOffset + srcY * bytesPerRow
                let rowByte0 = fontBase.load(fromByteOffset: rowOffset, as: UInt8.self)
                let rowByte1: UInt8 = (bytesPerRow > 1 && rowOffset + 1 < fontBitmap.count) ?
                    fontBase.load(fromByteOffset: rowOffset + 1, as: UInt8.self) : 0

                for destX in 0..<targetWidth {
                    let srcX = min(fontWidth - 1, ((2 * destX + 1) * fontWidth) / (2 * targetWidth))

                    let isSet: Bool
                    if srcX < 8 {
                        isSet = ((Int(rowByte0) >> (7 - srcX)) & 1) == 1
                    } else {
                        isSet = ((Int(rowByte1) >> (15 - srcX)) & 1) == 1
                    }

                    pixels[destY * targetWidth + destX] = isSet ? fgPixel : bgPixel
                }
            }
        }

        // Create CGImage from pixel data at target size
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)

        let data = pixels.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }

        return CGImage(
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: targetWidth * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    /// Get RGB color value for a palette index.
    private func getColorForIndex(_ index: Int) -> UInt32 {
        // Default CGA/VGA 16-color palette
        let defaultPalette: [UInt32] = [
            0x000000, // 0: Black
            0x0000AA, // 1: Blue
            0x00AA00, // 2: Green
            0x00AAAA, // 3: Cyan
            0xAA0000, // 4: Red
            0xAA00AA, // 5: Magenta
            0xAA5500, // 6: Brown
            0xAAAAAA, // 7: Light Gray
            0x555555, // 8: Dark Gray
            0x5555FF, // 9: Light Blue
            0x55FF55, // 10: Light Green
            0x55FFFF, // 11: Light Cyan
            0xFF5555, // 12: Light Red
            0xFF55FF, // 13: Light Magenta
            0xFFFF55, // 14: Yellow
            0xFFFFFF  // 15: White
        ]

        // Use custom palette if available
        if index >= 0 && index < palette.count && !palette.isEmpty {
            return UInt32(bitPattern: palette[index])
        }

        // Fall back to default palette
        if index >= 0 && index < defaultPalette.count {
            return defaultPalette[index]
        }

        return 0xFFFFFF // Default to white
    }
}

/// Shared by `TerminalViewModel`'s data pump thread and the main thread; every field sits behind `lock`.
private final class DataPumpState: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = 0
    private var running = false
    private var wakePending = false
    private var heldBytes = false
    /// Signalled by the main thread once a wake's poll has run.
    let pollDone = DispatchSemaphore(value: 0)

    /// Starts a new pump generation; an older thread still inside its wait sees it isn't current and exits.
    func start() -> Int {
        lock.withLock {
            generation += 1
            running = true
            wakePending = false
            heldBytes = false
            return generation
        }
    }

    func stop() {
        lock.withLock {
            running = false
            generation += 1
        }
    }

    func isCurrent(_ gen: Int) -> Bool {
        lock.withLock { running && generation == gen }
    }

    /// Data is waiting that the poll isn't taking yet.
    var held: Bool {
        get { lock.withLock { heldBytes } }
        set { lock.withLock { heldBytes = newValue } }
    }

    /// True when this call gets to schedule the wake (none is pending).
    func claimWake() -> Bool {
        lock.withLock {
            if wakePending {
                return false
            }
            wakePending = true
            return true
        }
    }

    func finishWake() {
        lock.withLock { wakePending = false }
    }
}
