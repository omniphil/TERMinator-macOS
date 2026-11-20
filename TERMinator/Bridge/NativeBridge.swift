import Foundation

/// JNI-style bridge to native SyncTERM terminal emulator code.
/// This interfaces with C code compiled for iOS.
final class NativeBridge {

    static let shared = NativeBridge()

    private var isLibraryLoaded = false

    // Connection type constants
    static let CONN_TYPE_TELNET = 3
    static let CONN_TYPE_SSH = 5
    static let CONN_TYPE_TELNETS = 13

    // Transfer state constants
    enum TransferState: Int {
        case idle = 0
        case receiving = 1
        case sending = 2
        case complete = 3
        case error = 4
        case cancelled = 5
    }

    private init() {
        // Native library is linked at compile time for iOS
        isLibraryLoaded = true
    }

    /// Check if the native library is available.
    func isNativeLibraryLoaded() -> Bool {
        return isLibraryLoaded
    }

    // MARK: - Initialization

    /// Set the files directory for SSH keys and other data.
    func setFilesDir(_ path: String) {
        native_set_files_dir(path)
    }

    /// Initialize the native terminal system.
    func initialize() -> Bool {
        return native_init()
    }

    /// Clean up native resources.
    func destroy() {
        native_destroy()
    }

    // MARK: - Connect in flight (connection log, spec §5)

    /// True while a `native_connect()` started here has not returned yet — **including** after
    /// `connectAsync` gave up on it (cancel / timeout), because the blocking native call keeps running
    /// until its socket is torn down. The connection log shows "waiting for the previous attempt to
    /// release the line..." and waits, instead of starting a call that `native_connect` would refuse.
    private let connectFlightLock = NSLock()
    private var connectFlightCount = 0

    var isConnectInFlight: Bool {
        connectFlightLock.lock()
        defer { connectFlightLock.unlock() }
        return connectFlightCount > 0
    }

    private func beginConnectFlight() {
        connectFlightLock.lock()
        connectFlightCount += 1
        connectFlightLock.unlock()
    }

    private func endConnectFlight() {
        connectFlightLock.lock()
        connectFlightCount = max(0, connectFlightCount - 1)
        connectFlightLock.unlock()
    }

    /// Waits for an outstanding native connect to return, polling every 50 ms. Capped so a wedged
    /// native call can never hang the new attempt for good: the connection timeout setting + 5 s (it was a fixed 15 s
    /// over a fixed 10 s connect), so an attempt that ran its full course still gets to let go.
    func waitForConnectToRelease(timeout: TimeInterval = TimeInterval(AppPreferences.connectionTimeout + 5)) async {
        let deadline = Date().addingTimeInterval(timeout)
        while isConnectInFlight, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    // MARK: - Connection Management

    /// Connect to a server (synchronous - use connectAsync for non-blocking).
    /// - Parameters:
    ///   - host: Hostname or IP address
    ///   - port: Port number
    ///   - protocol: CONN_TYPE_TELNET (3) or CONN_TYPE_SSH (5)
    ///   - username: Username for SSH (nil for Telnet)
    ///   - password: Password for SSH (nil for Telnet)
    func connect(host: String, port: Int, protocol connProtocol: Int = CONN_TYPE_TELNET,
                 username: String? = nil, password: String? = nil) -> Bool {
        return native_connect(host, Int32(port), Int32(connProtocol), username, password)
    }

    /// Connect to a server asynchronously (non-blocking).
    /// Wraps the blocking native_connect() with a timeout (spec §5: the attempt is abandoned after
    /// `timeoutSeconds`, the Preferences connection timeout, which is also what the connection log reports as
    /// "no response after").
    /// If the timeout fires, disconnect() is called to interrupt the native call
    /// via conn_api.terminate, and the method returns false.
    func connectAsync(host: String, port: Int, protocol connProtocol: Int = CONN_TYPE_TELNET,
                      username: String? = nil, password: String? = nil,
                      timeoutSeconds: Int = 10) async -> Bool {
        let timeoutNs = UInt64(max(1, timeoutSeconds)) * 1_000_000_000
        return await withTaskGroup(of: Bool.self) { group in
            // The actual connect task
            group.addTask {
                return await withCheckedContinuation { continuation in
                    // Tracked so a later attempt can wait for this one to release the line even if
                    // the timeout below stops waiting for it (see isConnectInFlight).
                    self.beginConnectFlight()
                    DispatchQueue.global(qos: .userInteractive).async {
                        let result = native_connect(host, Int32(port), Int32(connProtocol), username, password)
                        self.endConnectFlight()
                        continuation.resume(returning: result)
                    }
                }
            }

            // Timeout task — returns false after the connection timeout
            group.addTask {
                do {
                    try await Task.sleep(nanoseconds: timeoutNs)
                } catch {
                    // Task was cancelled because the connect finished first
                    return true  // placeholder, won't be used
                }
                // Timeout fired — interrupt the blocking native_connect
                self.disconnect()
                return false
            }

            // Take the first result (whichever finishes first)
            let result = await group.next() ?? false
            // Cancel the remaining task (the timeout if connect won, or vice versa)
            group.cancelAll()
            return result
        }
    }

    /// Disconnect from the server.
    func disconnect() {
        native_disconnect()
    }

    /// Check if connected.
    func isConnected() -> Bool {
        return native_is_connected()
    }

    // MARK: - Data Transfer

    /// Send raw data to the server.
    func sendData(_ data: Data) -> Int {
        return data.withUnsafeBytes { buffer in
            guard let ptr = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return -1
            }
            return Int(native_send_data(ptr, Int32(data.count)))
        }
    }

    /// Send a key code to the server.
    func sendKey(_ keyCode: Int) -> Int {
        return Int(native_send_key(Int32(keyCode)))
    }

    /// Send a string to the server.
    func sendString(_ str: String) -> Int {
        return Int(native_send_string(str))
    }

    /// Process incoming data.
    /// Returns bytes processed, or -100 for ZMODEM download detected, -101 for upload ready.
    func processData() -> Int {
        return Int(native_process_data())
    }

    /// Check if data is waiting.
    func dataWaiting() -> Int {
        return Int(native_data_waiting())
    }

    /// Block up to `timeoutMs` until received data is waiting. Returns the bytes waiting, 0 on timeout or when
    /// not connected. Off the main thread only: it sleeps (the data pump in TerminalViewModel calls it).
    func waitForData(timeoutMs: Int) -> Int {
        return Int(native_wait_for_data(Int32(timeoutMs)))
    }

    // MARK: - SyncTERM APC

    /// The board's APC cache directory (created if missing); nil turns caching off. Set before connecting.
    func setApcCacheDir(_ path: String?) {
        native_set_apc_cache_dir(path)
    }

    /// The soundtrack setting for SyncTERM audio (doors are told there's no audio while it's off).
    func setApcAudioEnabled(_ enabled: Bool) {
        native_set_apc_audio_enabled(enabled)
    }

    // MARK: - Physical key reports (CSI = 1 h / CSI = 2 h)

    /// Bit 0: the board wants physical key reports; bit 1: it wants no typed bytes. 0 when not connected.
    var keyModes: Int {
        return Int(native_get_key_modes())
    }

    /// One physical key edge (Linux evdev code). The bridge drops repeats and releases of keys never reported.
    func keyEvent(evdev: Int, pressed: Bool) {
        _ = native_key_event(Int32(evdev), pressed ? 1 : 0)
    }

    /// Releases every key the board still thinks is held (focus left the terminal).
    func keyReleaseAll() {
        native_key_release_all()
    }

    // MARK: - TRACE (TERMinator Render And Compute Engine)

    /// What TRACE can run, for the reply to a door's TRACE;Query; "" leaves the Query unanswered.
    func traceSetModules(_ capabilities: String) {
        native_trace_set_modules(capabilities)
    }

    /// Scratch for `tracePoll`: a text command is under 8192 bytes, a binary frame a header line plus up to 64 KB.
    /// Main thread only.
    private var traceBuffer = [CChar](repeating: 0, count: 72 * 1024)

    /// One queued TRACE item: a text command (the text after "TERMinator:TRACE;"), or a binary frame's raw bytes
    /// (a header line, '\n', then the payload), in the order the board sent them.
    enum TraceItem {
        case text(String)
        case binary(Data)
    }

    /// The oldest queued TRACE item, or nil when none is queued.
    func tracePoll() -> TraceItem? {
        let count = Int32(traceBuffer.count)
        let len = traceBuffer.withUnsafeMutableBufferPointer { buf -> Int32 in
            native_trace_poll(buf.baseAddress, count)
        }
        guard len > 0 else { return nil }
        if traceBuffer[0] == 0x01 {   // a binary frame (trace_bridge.c BIN_MARK)
            return traceBuffer.withUnsafeBufferPointer { buf -> TraceItem in
                .binary(Data(bytes: buf.baseAddress! + 1, count: Int(len) - 1))
            }
        }
        // NUL-terminated by native_trace_poll; invalid UTF-8 is repaired, as Windows' Encoding.UTF8.GetString does
        return traceBuffer.withUnsafeBufferPointer { buf -> TraceItem in
            .text(String(cString: buf.baseAddress!))
        }
    }

    // MARK: - TERMinator:Pic (Rainwire's pictures, Bridge/apc/pic_bridge.c)

    /// Scratch for `picPoll`: a Show carries its resolved cache path (at most 1024 bytes). Main thread only.
    private var picBuffer = [CChar](repeating: 0, count: 2048)

    /// The oldest queued Pic command ("Show;id=n;rect=r1,c1,r2,c2;path=...", "Hide;id=n" or "HideAll"), or nil
    /// when none is queued.
    func picPoll() -> String? {
        let count = Int32(picBuffer.count)
        let len = picBuffer.withUnsafeMutableBufferPointer { buf -> Int32 in
            native_pic_poll(buf.baseAddress, count)
        }
        guard len > 0 else { return nil }
        // NUL-terminated by native_pic_poll
        return picBuffer.withUnsafeBufferPointer { buf -> String in
            String(cString: buf.baseAddress!)
        }
    }

    // MARK: - Rainwire:UI (a Rainwire board's menus drawn here, Bridge/apc/ui_bridge.c, 1.1.6)

    /// Scratch for `uiPoll`: a message is at most 8 KB of base64 plus a header picture's path. Main thread only.
    private var uiBuffer = [CChar](repeating: 0, count: 16384)

    /// The oldest queued Rainwire:UI message ("Verb[;b64=...][;path=...]"), or nil when none is queued.
    func uiPoll() -> String? {
        let count = Int32(uiBuffer.count)
        let len = uiBuffer.withUnsafeMutableBufferPointer { buf -> Int32 in
            native_ui_poll(buf.baseAddress, count)
        }
        guard len > 0 else { return nil }
        // NUL-terminated by native_ui_poll
        return uiBuffer.withUnsafeBufferPointer { buf -> String in
            String(cString: buf.baseAddress!)
        }
    }

    // MARK: - Screen State

    /// Get the screen buffer as packed integers.
    /// Each int: character | (attr << 8) | (fg << 16) | (bg << 24)
    /// Maximum screen buffer size: 132 cols * 60 rows = 7920 cells (the 132x60 mode).
    /// Must match MAX_SCREEN_CELLS in syncterm_macos.c.
    private static let maxScreenBufferCount: Int32 = 132 * 60

    func getScreenBuffer() -> [Int32]? {
        var count: Int32 = 0
        guard let ptr = native_get_screen_buffer(&count),
              count > 0, count <= NativeBridge.maxScreenBufferCount else {
            return nil
        }
        let buffer = Array(UnsafeBufferPointer(start: ptr, count: Int(count)))
        // Note: Caller should not free ptr as it points to internal buffer
        return buffer
    }

    /// True-colour screen fetch: the packed cells, plus per-cell RGB overrides from the same native pass.
    /// fg/bg[i] is 0xFFRRGGBB (ready to use as a BGRA pixel) when cell i carries a literal 24-bit colour
    /// (ESC[38;2;R;G;Bm / 48;2), and 0 when the packed palette index should be used as before.
    func getScreenBufferRGB() -> (cells: [Int32], fg: [UInt32], bg: [UInt32])? {
        var count: Int32 = 0
        var fgPtr: UnsafePointer<Int32>? = nil
        var bgPtr: UnsafePointer<Int32>? = nil
        guard let ptr = native_get_screen_buffer_rgb(&count, &fgPtr, &bgPtr),
              count > 0, count <= NativeBridge.maxScreenBufferCount,
              let fgPtr = fgPtr, let bgPtr = bgPtr else {
            return nil
        }
        let n = Int(count)
        return (Array(UnsafeBufferPointer(start: ptr, count: n)),
                UnsafeBufferPointer(start: fgPtr, count: n).map { UInt32(bitPattern: $0) },
                UnsafeBufferPointer(start: bgPtr, count: n).map { UInt32(bitPattern: $0) })
    }

    /// Get the color palette.
    func getPalette() -> [Int32]? {
        var count: Int32 = 0
        guard let ptr = native_get_palette(&count), count > 0, count <= 256 else {
            return nil
        }
        return Array(UnsafeBufferPointer(start: ptr, count: Int(count)))
    }

    /// Get the screen size as [columns, rows].
    func getScreenSize() -> (columns: Int, rows: Int) {
        var columns: Int32 = 0
        var rows: Int32 = 0
        native_get_screen_size(&columns, &rows)
        return (Int(columns), Int(rows))
    }

    /// Get cursor position as [x, y].
    func getCursorPos() -> (x: Int, y: Int) {
        var x: Int32 = 0
        var y: Int32 = 0
        native_get_cursor_pos(&x, &y)
        return (Int(x), Int(y))
    }

    /// Check if cursor is visible.
    func isCursorVisible() -> Bool {
        return native_is_cursor_visible()
    }

    /// Check if BBS explicitly changed cursor type (read and clear).
    func cursorTypeChanged() -> Bool {
        return native_cursor_type_changed()
    }

    /// Cursor type values (matching ciolib.h _*CURSOR constants).
    enum CursorType: Int32 {
        case noCursor = 0      // _NOCURSOR
        case solidCursor = 1   // _SOLIDCURSOR (full block)
        case normalCursor = 2  // _NORMALCURSOR (underline, default)
        case halfCursor = 3    // _HALFCURSOR
    }

    /// Current cursor type (_NOCURSOR / _SOLIDCURSOR / _NORMALCURSOR / _HALFCURSOR).
    func getCursorType() -> CursorType {
        return CursorType(rawValue: native_get_cursor_type()) ?? .normalCursor
    }

    /// Top scanline of cursor within a character cell.
    func getCursorStart() -> Int {
        return Int(native_get_cursor_start())
    }

    /// Bottom scanline of cursor within a character cell.
    func getCursorEnd() -> Int {
        return Int(native_get_cursor_end())
    }

    /// Whether the cursor blinks (true) or is steady (false).
    func getCursorBlinks() -> Bool {
        return native_get_cursor_blinks() != 0
    }

    /// Check if the screen has changed since last render.
    func isScreenDirty() -> Bool {
        return native_is_screen_dirty()
    }

    /// Get dirty region bounds for partial redraw optimization.
    func getDirtyRegion() -> (minX: Int, minY: Int, maxX: Int, maxY: Int)? {
        var minX: Int32 = 0, minY: Int32 = 0, maxX: Int32 = 0, maxY: Int32 = 0
        if native_get_dirty_region(&minX, &minY, &maxX, &maxY) {
            return (Int(minX), Int(minY), Int(maxX), Int(maxY))
        }
        return nil
    }

    // MARK: - Terminal Control

    /// Set terminal size.
    func setTerminalSize(width: Int, height: Int) {
        native_set_terminal_size(Int32(width), Int32(height))
    }

    /// Set font by name.
    func setFont(_ fontName: String) -> Bool {
        return native_set_font(fontName)
    }

    /// Set font by ID.
    func setFontById(_ fontId: Int) -> Bool {
        return native_set_font_by_id(Int32(fontId))
    }

    /// Clear the screen.
    func clearScreen() {
        native_clear_screen()
    }

    /// Reset terminal state completely (screen + scrollback).
    /// Call this when connecting to a new BBS.
    func resetTerminal() {
        native_reset_terminal()
    }

    /// Push input data to the terminal.
    func pushInput(_ data: Data) {
        data.withUnsafeBytes { buffer in
            guard let ptr = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return
            }
            native_push_input(ptr, Int32(data.count))
        }
    }

    /// Hide or show the status line.
    func setHideStatusLine(_ hide: Bool) {
        native_set_hide_status_line(hide)
    }

    /// SSH blank login, set before every connect: no credentials and never a prompt (ssh.c ssh_blank_login).
    func setSshBlankLogin(_ on: Bool) {
        native_set_ssh_blank_login(on)
    }

    /// Set screen mode (0=80x25, 1=80x30, 2=80x50, 3=132x25, 4=132x50, 5=80x40).
    func setScreenMode(_ mode: Int) {
        native_set_screen_mode(Int32(mode))
    }

    // MARK: - Status

    /// Get status information string.
    func getStatusInfo() -> String {
        guard let cStr = native_get_status_info() else {
            return ""
        }
        return String(cString: cStr)
    }

    /// Get connection statistics: [bytesSent, bytesReceived, connectTimeMs, currentTimeMs].
    func getConnectionStats() -> (bytesSent: Int64, bytesReceived: Int64, connectTimeMs: Int64, currentTimeMs: Int64)? {
        var sent: Int64 = 0, received: Int64 = 0, connectTime: Int64 = 0, currentTime: Int64 = 0
        if native_get_connection_stats(&sent, &received, &connectTime, &currentTime) {
            return (sent, received, connectTime, currentTime)
        }
        return nil
    }

    /// Modem speed emulation in bps; 0 = full speed (a board's own ESC[*r still applies).
    func setEmulatedBps(_ bps: Int) {
        native_set_emulated_bps(Int32(max(0, bps)))
    }

    /// The speed incoming data is metered at: the user's setting, else the board's; 0 = full speed.
    func effectiveBps() -> Int {
        Int(native_get_effective_bps())
    }

    // MARK: - Font Bitmap

    /// Get the current font ID (as set by BBS via escape sequences or user selection).
    func getCurrentFontId() -> Int {
        return Int(native_get_current_font_id())
    }

    /// Get font dimensions only (width and height).
    func getFontDimensions() -> (width: Int, height: Int) {
        var width: Int32 = 0
        var height: Int32 = 0
        var count: Int32 = 0
        _ = native_get_font_bitmap(&width, &height, &count)
        return (Int(width), Int(height))
    }

    /// Get font bitmap data.
    /// Returns (width, height, bitmapData).
    /// Maximum font bitmap size: 256 chars * 32 height * 2 bytes/row = 16384
    private static let maxFontBitmapSize: Int32 = 256 * 32 * 2

    func getFontBitmap() -> (width: Int, height: Int, data: Data)? {
        var width: Int32 = 0
        var height: Int32 = 0
        var count: Int32 = 0
        guard let ptr = native_get_font_bitmap(&width, &height, &count),
              count > 0, count <= NativeBridge.maxFontBitmapSize else {
            return nil
        }
        let data = Data(bytes: ptr, count: Int(count))
        return (Int(width), Int(height), data)
    }

    // MARK: - Sixel Graphics

    /// Check if any sixel pixel data has been written.
    func hasSixelData() -> Bool {
        return native_has_sixel_data()
    }

    /// Check if sixel data has been updated since last read.
    func isSixelDirty() -> Bool {
        return native_is_sixel_dirty()
    }

    /// Get sixel pixel buffer dimensions.
    func getSixelDimensions() -> (width: Int, height: Int)? {
        var width: Int32 = 0
        var height: Int32 = 0
        guard native_get_sixel_dimensions(&width, &height), width > 0, height > 0 else {
            return nil
        }
        return (Int(width), Int(height))
    }

    /// Copy only the sixel layer's changed rectangle into `dest` (width x height ARGB, one row per `width`),
    /// clearing the dirty state; `full` copies everything. Returns the pixels copied (0 = nothing), or -1 when
    /// `dest` isn't the layer's size — `layerSize` is always the size to re-create it at. `rect` is what was copied.
    func copySixelPixels(into dest: inout [UInt32], width: Int, height: Int, full: Bool)
        -> (copied: Int, rect: CGRect?, layerSize: (width: Int, height: Int)) {
        var x: Int32 = 0, y: Int32 = 0, w: Int32 = 0, h: Int32 = 0, bw: Int32 = 0, bh: Int32 = 0
        let copied = dest.withUnsafeMutableBufferPointer { buffer -> Int32 in
            // Too small (or empty): ask for the size only; nothing is copied and the layer stays dirty
            let base = buffer.count >= width * height && width > 0 && height > 0 ? buffer.baseAddress : nil
            return native_copy_sixel_pixels(base, Int32(width), Int32(height), Int32(width), full,
                                            &x, &y, &w, &h, &bw, &bh)
        }
        let rect = copied > 0 ? CGRect(x: Int(x), y: Int(y), width: Int(w), height: Int(h)) : nil
        return (Int(copied), rect, (Int(bw), Int(bh)))
    }

    /// Get sixel pixel buffer contents as UInt32 array (ARGB format).
    func getSixelBuffer(width: Int, height: Int) -> [UInt32]? {
        let totalPixels = width * height
        guard totalPixels > 0, totalPixels <= 8192 * 8192 else { return nil }
        var pixelData = [Int32](repeating: 0, count: totalPixels)
        let written = native_get_sixel_buffer(&pixelData, Int32(totalPixels))
        guard written > 0 else { return nil }
        // Convert Int32 array to UInt32 array
        return pixelData.map { UInt32(bitPattern: $0) }
    }

    // MARK: - File Transfer (ZMODEM)

    /// Initialize the file transfer subsystem.
    func transferInit() -> Bool {
        return native_transfer_init()
    }

    /// Set the download directory.
    func setDownloadDir(_ dir: String) {
        native_set_download_dir(dir)
    }

    /// Start a ZMODEM receive operation (blocks until complete).
    func zmodemReceive() -> Int {
        return Int(native_zmodem_receive())
    }

    /// Start a ZMODEM send operation (blocks until complete).
    func zmodemSend(filePath: String) -> Int {
        return Int(native_zmodem_send(filePath))
    }

    // MARK: - X / YMODEM
    //
    // Nothing here auto-detects. ZMODEM announces itself with "**\u{18}B00" and
    // the download dialog pops off the back of that; an X/YMODEM sender just
    // starts NAKing into the void, so the user tells the BBS which protocol to
    // use and then picks the same one from the Transfer menu. Both calls block
    // for the whole transfer — run them off the main thread, exactly like the
    // ZMODEM ones.

    /// Mode bits for the X/YMODEM calls. Values mirror sbbs3/sexyz.h (and
    /// syncterm/term.h for `xmodem128B`) — do not renumber.
    enum XferMode {
        static let xmodem     = 1 << 2
        static let ymodem     = 1 << 3
        static let crc        = 1 << 5   // CRC-16 instead of 8-bit checksum
        static let gMode      = 1 << 6   // streaming -g variant (no per-block ACK)
        static let overwrite  = 1 << 9   // clobber an existing file instead of renaming
        static let xmodem128B = 1 << 10  // pin 128-byte blocks (what 8-bit boards want)
    }

    /// Receive via X/YMODEM (blocks until complete).
    /// `savePath` is REQUIRED for XMODEM — the protocol carries no filename — and
    /// ignored for YMODEM, which takes the name from its header block and writes
    /// to the download directory.
    /// Returns the number of files received, or negative on error.
    func xmodemReceive(savePath: String?, mode: Int) -> Int {
        if let savePath = savePath {
            return Int(native_xmodem_receive(savePath, Int32(mode)))
        }
        return Int(native_xmodem_receive(nil, Int32(mode)))
    }

    /// Send one file via X/YMODEM (blocks until complete).
    /// Returns 0 on success, negative on error.
    func xmodemSend(filePath: String, mode: Int) -> Int {
        return Int(native_xmodem_send(filePath, Int32(mode)))
    }

    /// Clear the batch upload queue.
    func uploadQueueClear() {
        _ = native_upload_queue_clear()
    }

    /// Append a file path to the batch upload queue. Returns new count, or -1 on error.
    @discardableResult
    func uploadQueueAdd(filePath: String) -> Int {
        return Int(native_upload_queue_add(filePath))
    }

    /// Number of files currently queued for a batch upload.
    func uploadQueueCount() -> Int {
        return Int(native_upload_queue_count())
    }

    /// Send all queued files as a single ZMODEM batch (blocks until complete).
    /// Returns the number of files sent (>=0) on success, negative on error.
    func zmodemSendBatch() -> Int {
        return Int(native_zmodem_send_batch())
    }

    /// Transfer > ZMODEM 8K Blocks: let uploads grow to 8K subpackets. Takes
    /// effect when the next ZMODEM session begins; downloads are unaffected.
    func setZmodem8k(_ enabled: Bool) {
        native_zmodem_set_8k(enabled ? 1 : 0)
    }

    /// Largest subpacket received in this transfer (downloads: the board's block size).
    func zmodemLargestRxBlock() -> Int {
        Int(native_zmodem_largest_rx_block())
    }

    /// Current file index and total for an in-progress transfer.
    /// Values are 1-based; total 0/1 indicates a single-file transfer.
    func getTransferFileIndex() -> (current: Int, total: Int) {
        var current: Int32 = 0
        var total: Int32 = 0
        _ = native_get_transfer_file_index(&current, &total)
        return (Int(current), Int(total))
    }

    /// Cancel the current transfer.
    func transferCancel() {
        native_transfer_cancel()
    }

    /// Get the current transfer state.
    func getTransferState() -> TransferState {
        let state = Int(native_get_transfer_state())
        return TransferState(rawValue: state) ?? .idle
    }

    /// Drain protocol status lines produced since the last call.
    ///
    /// Each returned element is `(level, text)` where level is the severity the
    /// native side stamped on it: "I" protocol info, "W" warning, "E" error,
    /// "S" one of our own status notes. Lines are handed out once, so this can
    /// be polled as often as you like without repeating itself.
    func drainTransferLog() -> [(level: String, text: String)] {
        var buffer = [CChar](repeating: 0, count: 16384)
        let written = buffer.withUnsafeMutableBufferPointer { ptr -> Int32 in
            guard let base = ptr.baseAddress else { return 0 }
            return native_get_transfer_log(base, Int32(ptr.count))
        }
        guard written > 0 else { return [] }

        let blob = String(cString: buffer)
        return blob.split(separator: "\n").compactMap { line in
            guard line.count >= 2 else { return nil }
            return (String(line.prefix(1)), String(line.dropFirst()))
        }
    }

    /// Discard pending status lines so a new transfer starts with a clean feed.
    func clearTransferLog() {
        native_clear_transfer_log()
    }

    /// Get transfer progress: [bytesTransferred, totalBytes].
    func getTransferProgress() -> (bytesTransferred: Int64, totalBytes: Int64)? {
        var transferred: Int64 = 0
        var total: Int64 = 0
        if native_get_transfer_progress(&transferred, &total) {
            return (transferred, total)
        }
        return nil
    }

    /// Get the name of the file being transferred.
    func getTransferFileName() -> String? {
        guard let cStr = native_get_transfer_file_name() else {
            return nil
        }
        return String(cString: cStr)
    }

    /// Get the error message from the last failed transfer.
    func getTransferError() -> String? {
        guard let cStr = native_get_transfer_error() else {
            return nil
        }
        return String(cString: cStr)
    }

    /// Reset transfer state after completion or error.
    func transferReset() {
        native_transfer_reset()
    }

    /// Cleanup file transfer resources.
    func transferCleanup() {
        native_transfer_cleanup()
    }

    // MARK: - ZMODEM Auto-Detection

    /// Check if ZMODEM was auto-detected.
    func isZmodemDetected() -> Bool {
        return native_is_zmodem_detected()
    }

    /// Get buffered ZMODEM data from detection.
    func getZmodemBuffer() -> Data? {
        var count: Int32 = 0
        guard let ptr = native_get_zmodem_buffer(&count), count > 0 else {
            return nil
        }
        return Data(bytes: ptr, count: Int(count))
    }

    /// Clear ZMODEM detection state.
    func clearZmodemDetected() {
        native_clear_zmodem_detected()
    }

    /// Push buffered ZMODEM data back into connection buffer.
    func pushZmodemBuffer() -> Int {
        return Int(native_push_zmodem_buffer())
    }

    // MARK: - Upload Queue

    /// Queue a file for upload.
    func queueUpload(filePath: String) {
        native_queue_upload(filePath)
    }

    /// Check if a file is queued for upload.
    func isUploadQueued() -> Bool {
        return native_is_upload_queued()
    }

    /// Check if the BBS is ready for upload (ZRINIT received).
    func isUploadReady() -> Bool {
        return native_is_upload_ready()
    }

    /// Get the path of the queued upload file.
    func getQueuedUpload() -> String? {
        guard let cStr = native_get_queued_upload() else {
            return nil
        }
        return String(cString: cStr)
    }

    /// Clear the upload queue.
    func clearUploadQueue() {
        native_clear_upload_queue()
    }

    // MARK: - Scrollback Buffer

    /// Get scrollback buffer info: [filledLines, totalCapacity, columns].
    func getScrollbackInfo() -> (filledLines: Int, totalCapacity: Int, columns: Int)? {
        var filled: Int32 = 0, capacity: Int32 = 0, columns: Int32 = 0
        if native_get_scrollback_info(&filled, &capacity, &columns) {
            return (Int(filled), Int(capacity), Int(columns))
        }
        return nil
    }

    /// Get scrollback buffer content.
    /// Maximum scrollback result: 132 cols * 100 rows = 13200 cells
    private static let maxScrollbackCount: Int32 = 132 * 100

    func getScrollbackBuffer(offset: Int, count: Int) -> [Int32]? {
        var resultCount: Int32 = 0
        guard let ptr = native_get_scrollback_buffer(Int32(clamping: offset), Int32(clamping: count), &resultCount),
              resultCount > 0, resultCount <= NativeBridge.maxScrollbackCount else {
            return nil
        }
        return Array(UnsafeBufferPointer(start: ptr, count: Int(resultCount)))
    }

    /// True-colour scrollback fetch -- same override contract as getScreenBufferRGB.
    func getScrollbackBufferRGB(offset: Int, count: Int) -> (cells: [Int32], fg: [UInt32], bg: [UInt32])? {
        var resultCount: Int32 = 0
        var fgPtr: UnsafePointer<Int32>? = nil
        var bgPtr: UnsafePointer<Int32>? = nil
        guard let ptr = native_get_scrollback_buffer_rgb(Int32(clamping: offset), Int32(clamping: count),
                                                         &resultCount, &fgPtr, &bgPtr),
              resultCount > 0, resultCount <= NativeBridge.maxScrollbackCount,
              let fgPtr = fgPtr, let bgPtr = bgPtr else {
            return nil
        }
        let n = Int(resultCount)
        return (Array(UnsafeBufferPointer(start: ptr, count: n)),
                UnsafeBufferPointer(start: fgPtr, count: n).map { UInt32(bitPattern: $0) },
                UnsafeBufferPointer(start: bgPtr, count: n).map { UInt32(bitPattern: $0) })
    }

    // MARK: - Bell Detection

    /// Check if a bell (BEL character) was received and clear the flag.
    func checkBell() -> Bool {
        return native_check_bell()
    }

    // MARK: - Audio Command (OSC 800 / TAP)

    /// Check if an audio command is pending.
    func checkAudioCommand() -> Bool {
        return native_check_audio_command()
    }

    /// Get the pending audio command string and clear the flag.
    func getAudioCommand() -> String? {
        guard let cStr = native_get_audio_command() else { return nil }
        return String(cString: cStr)
    }

    // MARK: - MOD Player (libxmp)

    /// Load a tracker module file.
    func modLoad(_ filePath: String) -> Bool {
        return native_mod_load(filePath)
    }

    /// Render PCM frames from the loaded module.
    /// Returns frames rendered, or -1 on end/error.
    func modGetPcm(_ buffer: UnsafeMutablePointer<Int16>, frames: Int) -> Int {
        return Int(native_mod_get_pcm(buffer, Int32(frames)))
    }

    /// Stop and release the current module.
    func modStop() {
        native_mod_stop()
    }

    /// Set MOD playback volume (0.0 - 1.0).
    func modSetVolume(_ volume: Float) {
        native_mod_set_volume(volume)
    }

    /// Check if a module is currently playing.
    func modIsPlaying() -> Bool {
        return native_mod_is_playing()
    }

    /// Restart the current module from the beginning.
    func modRestart() {
        native_mod_restart()
    }

    /// Seek to a position in the current module (milliseconds).
    func modSeek(_ positionMs: Int) {
        native_mod_seek(Int32(positionMs))
    }

    // MARK: - Session Logging

    /// Enable or disable session logging.
    func setLoggingEnabled(_ enabled: Bool) {
        native_set_logging_enabled(enabled)
    }

    /// Get and clear logged data from the buffer.
    func getLoggedData() -> Data? {
        var count: Int32 = 0
        guard let ptr = native_get_logged_data(&count), count > 0 else {
            return nil
        }
        return Data(bytes: ptr, count: Int(count))
    }

    // MARK: - SSH Debug Log

    /// Get the accumulated SSH connection debug log as a string.
    func getSshDebugLog() -> String {
        let bufferSize = 16384
        var buffer = [CChar](repeating: 0, count: bufferSize)
        let written = buffer.withUnsafeMutableBufferPointer { ptr -> Int32 in
            guard let base = ptr.baseAddress else { return 0 }
            return native_get_ssh_debug_log(base, Int32(bufferSize))
        }
        guard written > 0 else { return "" }
        return String(cString: buffer)
    }

    /// Clear the SSH connection debug log.
    func clearSshDebugLog() {
        native_clear_ssh_debug_log()
    }

    // MARK: - Helper Functions

    /// Unpack character from packed cell value.
    static func unpackChar(_ cell: Int32) -> Character {
        return Character(UnicodeScalar(Int(cell & 0xFF)) ?? UnicodeScalar(32))
    }

    /// Unpack legacy attribute from packed cell value.
    static func unpackAttr(_ cell: Int32) -> Int {
        return Int((cell >> 8) & 0xFF)
    }

    /// Get foreground color from attribute byte.
    static func attrToFg(_ attr: Int) -> Int {
        return attr & 0x0F
    }

    /// Get background color from attribute byte (4 bits for iCE bright backgrounds).
    static func attrToBg(_ attr: Int) -> Int {
        return (attr >> 4) & 0x0F
    }

    /// Check if cell has underline attribute (bit 23 of packed int).
    static func isUnderline(_ cell: Int32) -> Bool {
        return ((cell >> 23) & 1) == 1
    }

}

// MARK: - C Function Declarations

// These are the C functions that need to be implemented in the native library.
// For now they are declared as stubs that will link to the actual implementation.

@_silgen_name("native_set_files_dir")
private func native_set_files_dir(_ path: UnsafePointer<CChar>)

@_silgen_name("native_init")
private func native_init() -> Bool

@_silgen_name("native_destroy")
private func native_destroy()

@_silgen_name("native_connect")
private func native_connect(_ host: UnsafePointer<CChar>, _ port: Int32, _ protocol: Int32,
                            _ username: UnsafePointer<CChar>?, _ password: UnsafePointer<CChar>?) -> Bool

@_silgen_name("native_disconnect")
private func native_disconnect()

@_silgen_name("native_is_connected")
private func native_is_connected() -> Bool

@_silgen_name("native_send_data")
private func native_send_data(_ data: UnsafePointer<UInt8>, _ count: Int32) -> Int32

@_silgen_name("native_send_key")
private func native_send_key(_ keyCode: Int32) -> Int32

@_silgen_name("native_send_string")
private func native_send_string(_ str: UnsafePointer<CChar>) -> Int32

@_silgen_name("native_process_data")
private func native_process_data() -> Int32

@_silgen_name("native_data_waiting")
private func native_data_waiting() -> Int32

@_silgen_name("native_get_screen_buffer")
private func native_get_screen_buffer(_ count: UnsafeMutablePointer<Int32>) -> UnsafePointer<Int32>?

@_silgen_name("native_get_screen_buffer_rgb")
private func native_get_screen_buffer_rgb(_ count: UnsafeMutablePointer<Int32>,
                                          _ fg: UnsafeMutablePointer<UnsafePointer<Int32>?>,
                                          _ bg: UnsafeMutablePointer<UnsafePointer<Int32>?>) -> UnsafePointer<Int32>?

@_silgen_name("native_get_palette")
private func native_get_palette(_ count: UnsafeMutablePointer<Int32>) -> UnsafePointer<Int32>?

@_silgen_name("native_get_screen_size")
private func native_get_screen_size(_ columns: UnsafeMutablePointer<Int32>, _ rows: UnsafeMutablePointer<Int32>)

@_silgen_name("native_get_cursor_pos")
private func native_get_cursor_pos(_ x: UnsafeMutablePointer<Int32>, _ y: UnsafeMutablePointer<Int32>)

@_silgen_name("native_is_cursor_visible")
private func native_is_cursor_visible() -> Bool

@_silgen_name("native_cursor_type_changed")
private func native_cursor_type_changed() -> Bool

@_silgen_name("native_get_cursor_type")
private func native_get_cursor_type() -> Int32

@_silgen_name("native_get_cursor_start")
private func native_get_cursor_start() -> Int32

@_silgen_name("native_get_cursor_end")
private func native_get_cursor_end() -> Int32

@_silgen_name("native_get_cursor_blinks")
private func native_get_cursor_blinks() -> Int32

@_silgen_name("native_is_screen_dirty")
private func native_is_screen_dirty() -> Bool

@_silgen_name("native_get_dirty_region")
private func native_get_dirty_region(_ minX: UnsafeMutablePointer<Int32>, _ minY: UnsafeMutablePointer<Int32>,
                                     _ maxX: UnsafeMutablePointer<Int32>, _ maxY: UnsafeMutablePointer<Int32>) -> Bool

@_silgen_name("native_set_terminal_size")
private func native_set_terminal_size(_ width: Int32, _ height: Int32)

@_silgen_name("native_set_font")
private func native_set_font(_ fontName: UnsafePointer<CChar>) -> Bool

@_silgen_name("native_set_font_by_id")
private func native_set_font_by_id(_ fontId: Int32) -> Bool

@_silgen_name("native_clear_screen")
private func native_clear_screen()

@_silgen_name("native_reset_terminal")
private func native_reset_terminal()

@_silgen_name("native_push_input")
private func native_push_input(_ data: UnsafePointer<UInt8>, _ count: Int32)

@_silgen_name("native_set_hide_status_line")
private func native_set_hide_status_line(_ hide: Bool)

@_silgen_name("native_set_ssh_blank_login")
private func native_set_ssh_blank_login(_ on: Bool)

@_silgen_name("native_set_screen_mode")
private func native_set_screen_mode(_ mode: Int32)

@_silgen_name("native_get_status_info")
private func native_get_status_info() -> UnsafePointer<CChar>?

@_silgen_name("native_get_connection_stats")
private func native_get_connection_stats(_ sent: UnsafeMutablePointer<Int64>, _ received: UnsafeMutablePointer<Int64>,
                                         _ connectTime: UnsafeMutablePointer<Int64>, _ currentTime: UnsafeMutablePointer<Int64>) -> Bool

@_silgen_name("native_set_emulated_bps")
private func native_set_emulated_bps(_ bps: Int32)

@_silgen_name("native_get_effective_bps")
private func native_get_effective_bps() -> Int32

@_silgen_name("native_get_current_font_id")
private func native_get_current_font_id() -> Int32

@_silgen_name("native_get_font_bitmap")
private func native_get_font_bitmap(_ width: UnsafeMutablePointer<Int32>, _ height: UnsafeMutablePointer<Int32>,
                                    _ count: UnsafeMutablePointer<Int32>) -> UnsafePointer<UInt8>?

@_silgen_name("native_transfer_init")
private func native_transfer_init() -> Bool

@_silgen_name("native_set_download_dir")
private func native_set_download_dir(_ dir: UnsafePointer<CChar>)

@_silgen_name("native_zmodem_receive")
private func native_zmodem_receive() -> Int32

@_silgen_name("native_zmodem_send")
private func native_zmodem_send(_ filePath: UnsafePointer<CChar>) -> Int32

@_silgen_name("native_upload_queue_clear")
private func native_upload_queue_clear() -> Int32

@_silgen_name("native_upload_queue_add")
private func native_upload_queue_add(_ filePath: UnsafePointer<CChar>) -> Int32

@_silgen_name("native_upload_queue_count")
private func native_upload_queue_count() -> Int32

@_silgen_name("native_zmodem_send_batch")
private func native_zmodem_send_batch() -> Int32

@_silgen_name("native_zmodem_set_8k")
private func native_zmodem_set_8k(_ enable: Int32)

@_silgen_name("native_zmodem_largest_rx_block")
private func native_zmodem_largest_rx_block() -> Int32

@_silgen_name("native_get_transfer_file_index")
private func native_get_transfer_file_index(_ current: UnsafeMutablePointer<Int32>, _ total: UnsafeMutablePointer<Int32>) -> Int32

@_silgen_name("native_transfer_cancel")
private func native_transfer_cancel()

@_silgen_name("native_get_transfer_state")
private func native_get_transfer_state() -> Int32

@_silgen_name("native_get_transfer_progress")
private func native_get_transfer_progress(_ transferred: UnsafeMutablePointer<Int64>, _ total: UnsafeMutablePointer<Int64>) -> Bool

@_silgen_name("native_get_transfer_file_name")
private func native_get_transfer_file_name() -> UnsafePointer<CChar>?

@_silgen_name("native_get_transfer_error")
private func native_get_transfer_error() -> UnsafePointer<CChar>?

@_silgen_name("native_transfer_reset")
private func native_transfer_reset()

@_silgen_name("native_transfer_cleanup")
private func native_transfer_cleanup()

@_silgen_name("native_is_zmodem_detected")
private func native_is_zmodem_detected() -> Bool

@_silgen_name("native_get_zmodem_buffer")
private func native_get_zmodem_buffer(_ count: UnsafeMutablePointer<Int32>) -> UnsafePointer<UInt8>?

@_silgen_name("native_clear_zmodem_detected")
private func native_clear_zmodem_detected()

@_silgen_name("native_push_zmodem_buffer")
private func native_push_zmodem_buffer() -> Int32

@_silgen_name("native_queue_upload")
private func native_queue_upload(_ filePath: UnsafePointer<CChar>)

@_silgen_name("native_is_upload_queued")
private func native_is_upload_queued() -> Bool

@_silgen_name("native_is_upload_ready")
private func native_is_upload_ready() -> Bool

@_silgen_name("native_get_queued_upload")
private func native_get_queued_upload() -> UnsafePointer<CChar>?

@_silgen_name("native_clear_upload_queue")
private func native_clear_upload_queue()

@_silgen_name("native_get_scrollback_info")
private func native_get_scrollback_info(_ filled: UnsafeMutablePointer<Int32>, _ capacity: UnsafeMutablePointer<Int32>,
                                        _ columns: UnsafeMutablePointer<Int32>) -> Bool

@_silgen_name("native_get_scrollback_buffer")
private func native_get_scrollback_buffer(_ offset: Int32, _ count: Int32,
                                          _ resultCount: UnsafeMutablePointer<Int32>) -> UnsafePointer<Int32>?

@_silgen_name("native_get_scrollback_buffer_rgb")
private func native_get_scrollback_buffer_rgb(_ offset: Int32, _ count: Int32,
                                              _ resultCount: UnsafeMutablePointer<Int32>,
                                              _ fg: UnsafeMutablePointer<UnsafePointer<Int32>?>,
                                              _ bg: UnsafeMutablePointer<UnsafePointer<Int32>?>) -> UnsafePointer<Int32>?

@_silgen_name("native_check_bell")
private func native_check_bell() -> Bool

@_silgen_name("native_set_logging_enabled")
private func native_set_logging_enabled(_ enabled: Bool)

@_silgen_name("native_get_logged_data")
private func native_get_logged_data(_ count: UnsafeMutablePointer<Int32>) -> UnsafePointer<UInt8>?

// SSH Debug Log
@_silgen_name("native_get_ssh_debug_log")
private func native_get_ssh_debug_log(_ buffer: UnsafeMutablePointer<CChar>, _ bufferLen: Int32) -> Int32

@_silgen_name("native_clear_ssh_debug_log")
private func native_clear_ssh_debug_log()

// Audio Command (OSC 800 / TAP)
@_silgen_name("native_check_audio_command")
private func native_check_audio_command() -> Bool

@_silgen_name("native_get_audio_command")
private func native_get_audio_command() -> UnsafePointer<CChar>?

// MOD Player (libxmp)
@_silgen_name("native_mod_load")
private func native_mod_load(_ filePath: UnsafePointer<CChar>) -> Bool

@_silgen_name("native_mod_get_pcm")
private func native_mod_get_pcm(_ buffer: UnsafeMutablePointer<Int16>, _ frames: Int32) -> Int32

@_silgen_name("native_mod_stop")
private func native_mod_stop()

@_silgen_name("native_mod_set_volume")
private func native_mod_set_volume(_ volume: Float)

@_silgen_name("native_mod_is_playing")
private func native_mod_is_playing() -> Bool

@_silgen_name("native_mod_restart")
private func native_mod_restart()

@_silgen_name("native_mod_seek")
private func native_mod_seek(_ positionMs: Int32)

