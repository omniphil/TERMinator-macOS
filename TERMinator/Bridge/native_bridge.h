/**
 * Native Bridge Header
 *
 * Declares the C functions that Swift will call via @_silgen_name.
 * These functions are implemented in syncterm_macos.c and macos_ciolib.c.
 */

#ifndef NATIVE_BRIDGE_H
#define NATIVE_BRIDGE_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// ============================================================================
// MARK: - Initialization
// ============================================================================

/**
 * Set the files directory for SSH keys and other data.
 */
void native_set_files_dir(const char *path);

/**
 * Initialize the native terminal system.
 * Returns true on success, false on failure.
 */
bool native_init(void);

/**
 * Clean up native resources.
 */
void native_destroy(void);

// ============================================================================
// MARK: - Connection Management
// ============================================================================

/**
 * Connect to a server.
 * @param host Hostname or IP address
 * @param port Port number
 * @param protocol CONN_TYPE_TELNET (3), CONN_TYPE_RAW (4), CONN_TYPE_SSH (5),
 *                CONN_TYPE_TELNETS (13), CONN_TYPE_WEBSOCKET (14) or
 *                CONN_TYPE_WEBSOCKETS (15)
 * @param username Username for SSH (NULL for Telnet)
 * @param password Password for SSH (NULL for Telnet)
 * @return true on success, false on failure
 */
bool native_connect(const char *host, int32_t port, int32_t protocol,
                    const char *username, const char *password);

/**
 * Disconnect from the server.
 */
void native_disconnect(void);

/**
 * Check if connected.
 */
bool native_is_connected(void);

// ============================================================================
// MARK: - Data Transfer
// ============================================================================

/**
 * Send raw data to the server.
 * @return Bytes sent, or -1 on error
 */
int32_t native_send_data(const uint8_t *data, int32_t count);

/**
 * Queue raw data for the server and return immediately (safe on the main thread).
 * A background thread sends it in order through the same connection; a disconnect
 * drops whatever is still queued. Up to 4 MB may be pending.
 * @return count when queued, or -1 if not connected / the queue is full
 */
int32_t native_send_data_nowait(const uint8_t *data, int32_t count);

/**
 * Send a key code to the server.
 * @return 1 on success, -1 on error
 */
int32_t native_send_key(int32_t keyCode);

/**
 * Send a string to the server.
 * @return Bytes sent, or -1 on error
 */
int32_t native_send_string(const char *str);

/**
 * Process incoming data.
 * @return Bytes processed, -100 for ZMODEM download, -101 for upload ready
 */
int32_t native_process_data(void);

/**
 * Check if data is waiting.
 * @return Bytes waiting
 */
int32_t native_data_waiting(void);

/**
 * Block up to timeout_ms until received data is waiting (1 ms checks). Safe off the main thread.
 * @return Bytes waiting, or 0 on timeout / not connected
 */
int32_t native_wait_for_data(int32_t timeout_ms);

// ============================================================================
// MARK: - SyncTERM APC (Bridge/apc/)
// ============================================================================

/**
 * The board's APC cache directory (absolute UTF-8 path, created if missing). NULL or "" turns caching off.
 * Set before connecting.
 */
void native_set_apc_cache_dir(const char *utf8dir);

/**
 * The soundtrack setting for SyncTERM audio: while off, doors are told there is no audio and A;* is ignored.
 */
void native_set_apc_audio_enabled(bool enabled);

/**
 * Pull `frames` frames of the SyncTERM audio mix (S16 stereo 44.1 kHz, interleaved) into `out`
 * (2 * frames samples). Called from the audio render thread.
 * @return Leading frames that carried audio; the rest is silence
 */
int32_t native_apc_audio_pull(int16_t *out, int32_t frames);

// ============================================================================
// MARK: - Physical key reports (CSI = 1 h / CSI = 2 h), syncterm_macos.c
// ============================================================================

/**
 * Current key modes: bit 0 = physical key reports on (CSI = 1 h), bit 1 = typed bytes suppressed (CSI = 2 h).
 * 0 when not connected. Lock-free; safe from the UI thread at any time.
 */
int32_t native_get_key_modes(void);

/**
 * One physical key edge as a Linux evdev code (Services/PhysicalKeys.swift maps NSEvent keyCodes).
 * Auto-repeat presses and releases of keys never reported are dropped.
 * @return 1 when a report was sent
 */
int32_t native_key_event(int32_t evdev_code, int32_t pressed);

/**
 * Focus left the terminal: report every key still held as released, in one sequence.
 */
void native_key_release_all(void);

// ============================================================================
// MARK: - TRACE (TERMinator Render And Compute Engine), Bridge/apc/trace_bridge.c
// ============================================================================

/**
 * What TRACE can run, for the reply to a door's TRACE;Query ("wasm=1;audio=1;..."). "" = switched off: the Query
 * then goes unanswered, as on a terminal without TRACE.
 */
void native_trace_set_modules(const char *capabilities);

/**
 * Takes the oldest queued TRACE command (the text after "TERMinator:TRACE;") into buffer, NUL-terminated.
 * @return Its length, 0 when none is queued, -1 when buffer is too small (the command stays queued)
 */
int32_t native_trace_poll(char *buffer, int32_t buffer_len);

/**
 * Seqlock copy of the newest complete frame out of a module's mapped frame buffer (engine_contract.h) into dest
 * (room for capacity_width * capacity_height * 4 bytes, BGRA).
 * @return 1 with *width, *height, *flags set when a frame was copied, else 0
 */
int32_t native_trace_frame_copy(const void *base, int32_t capacity_width, int32_t capacity_height, void *dest,
                                int32_t *width, int32_t *height, uint32_t *flags);

// ============================================================================
// MARK: - xterm mouse reporting (CSI ? 9/1000/1002/1003 h, SGR 1006), Bridge/mouse_bridge.c
// ============================================================================

/**
 * The app can deliver mouse events: cterm's device attributes then advertise a mouse and a board's tracking mode is
 * kept. Off drops any mode a board set. (Windows: syncterm_mouse_set_enabled.)
 */
void native_mouse_set_enabled(int32_t enabled);

/**
 * The board's tracking mode (0, 9, 1000, 1002 or 1003), plus 0x10000 when it asked for SGR coordinates.
 */
int32_t native_mouse_mode(void);

/**
 * One mouse event: kind 0 press / 1 release / 2 move; button 0 left, 1 middle, 2 right, 3 wheel up, 4 wheel down
 * (a move passes the lowest held button, or -1); x, y 1-based cells.
 * @return Bytes sent, or 0 when the board's mode doesn't report it (the app keeps it)
 */
int32_t native_mouse_event(int32_t kind, int32_t button, int32_t x, int32_t y);

// ============================================================================
// MARK: - Rainwire's window protocol (Rainwire:WM;...), Bridge/apc/wm_bridge.c
// ============================================================================

/**
 * Switches the protocol on (1) or off (0). Off, a board's Query goes unanswered and nothing is queued.
 */
void native_wm_set_enabled(int32_t enabled);

/**
 * Takes the oldest queued message (the text after "Rainwire:WM;") into buffer, NUL-terminated.
 * @return Its length, 0 when none is queued, -1 when buffer is too small (the message stays queued)
 */
int32_t native_wm_poll(char *buffer, int32_t buffer_len);

// ============================================================================
// MARK: - Rainwire's pictures (TERMinator:Pic;...), Bridge/apc/pic_bridge.c (Rainwire docs/PICTURES.md, protocol A)
// ============================================================================

/**
 * Takes the oldest queued Pic command into buffer, NUL-terminated, in the order the board sent them:
 * "Show;id=<0-7>;rect=<r1>,<c1>,<r2>,<c2>;path=<full UTF-8 path>" (path last, to the end), "Hide;id=<0-7>" or
 * "HideAll" (also queued by a full screen clear).
 * @return Its length, 0 when none is queued, -1 when buffer is too small (the command stays queued)
 */
int32_t native_pic_poll(char *buffer, int32_t buffer_len);

// ============================================================================
// MARK: - Rainwire's menus drawn by the app (Rainwire:UI;...), Bridge/apc/ui_bridge.c (1.1.6; Rainwire docs/MENU_GFX.md)
// ============================================================================

/**
 * Takes the oldest queued Rainwire:UI message into buffer, NUL-terminated, in the order the board sent them:
 * "<Verb>[;b64=<base64>][;path=<full UTF-8 path of the header picture>]" (path last, to the end; only on a Menu).
 * @return Its length, 0 when none is queued, -1 when buffer is too small (the message stays queued)
 */
int32_t native_ui_poll(char *buffer, int32_t buffer_len);

// ============================================================================
// MARK: - OSC 0/2 title, OSC 8 hyperlinks, OSC 52 clipboard (Bridge/apc/osc_ext.c, PORT_TO_MAC_LINUX.md 12.62)
// The same names as Windows/Linux (osc_ext.c is one file in every client).
// ============================================================================

/** A title the board set since the last call (UTF-8, NUL-terminated): its length, 0 = cleared, -1 = nothing new. */
int syncterm_osc_poll_title(char *buffer, int buffer_len);

/** Clipboard text the board sent since the last call (latest only): its length, 0 = none, -1 = buffer too small. */
int syncterm_osc_poll_clipboard(char *buffer, int buffer_len);

/**
 * The OSC 8 link under screen cell (col, row), 0-based; ch = the CP437 character shown there (-1 = don't check).
 * @return URI length (copied, NUL-terminated), 0 = no link, -1 = buffer too small. span_* = the link's run on the row.
 */
int syncterm_osc_link_at(int col, int row, int ch, char *buffer, int buffer_len, int *span_start, int *span_end);

/** 1 once the board has drawn a link this session. */
int syncterm_osc_links_active(void);

/**
 * 12.72: the app's own keys for the Rainwire:Caps answer, ";"-separated key=value ("app=1.5.1;lang=en-US;..."). Call
 * before each connect; NULL or "" = none. Pairs with anything but [A-Za-z0-9._+/-] are dropped natively.
 */
void syncterm_osc_set_info(const char *keys);

/**
 * 12.72: the oldest OSC 777 notification not yet taken (UTF-8, NUL-terminated, cut to fit): 1, or 0 = none waiting.
 * Buffers of 65 (title) and 257 (body) bytes always fit.
 */
int syncterm_osc_poll_notify(char *title, int title_len, char *body, int body_len);

/**
 * 12.73: the oldest Rainwire:Link request not yet taken (Rainwire docs/MRC_WINDOW.md): "key=value" lines joined by
 * "\n" in the order sent (kind always, token on every Open, then title and any other keys; values unescaped and
 * cleaned). Returns 1 = Open, 2 = Raise, 0 = none waiting, -1 = it didn't fit (dropped). 2336 bytes
 * (OSC_EXT_LINK_POLL_MAX) always fit.
 */
int syncterm_osc_poll_link(char *buffer, int buffer_len);

// ============================================================================
// MARK: - Screen State
// ============================================================================

/**
 * Get the screen buffer as packed integers.
 * Each int: character | (attr << 8) | (fg << 16) | (bg << 24)
 * @param count Output: number of cells
 * @return Pointer to screen buffer (do not free)
 */
const int32_t* native_get_screen_buffer(int32_t *count);

/**
 * True-colour variant of native_get_screen_buffer: the same packed cells, plus per-cell RGB overrides.
 * fg/bg[i] is 0xFFRRGGBB when cell i carries a literal 24-bit colour (ESC[38;2;R;G;Bm / 48;2), else 0
 * (use the packed palette index). Filled in the same locked pass as the cells.
 * @param count Output: number of cells
 * @param fg Output: foreground overrides, count entries (do not free); NULL when the result is NULL
 * @param bg Output: background overrides, same contract
 * @return Pointer to screen buffer (do not free)
 */
const int32_t* native_get_screen_buffer_rgb(int32_t *count, const int32_t **fg, const int32_t **bg);

/**
 * Get the color palette.
 * @param count Output: number of colors (16)
 * @return Pointer to palette (do not free)
 */
const int32_t* native_get_palette(int32_t *count);

/* --- macOS PETSCII 2026-09-04 ---------------------------------------------
 * native_mode_no_blink(): does the active video mode treat attribute bit 7 as
 * BACKGROUND BRIGHTNESS rather than the ANSI blink attribute? True for the
 * Commodore modes (BGBRIGHT|NOBLINK). The screen packer already strips the bit
 * in those modes, so this is available for a renderer that wants to check.
 * native_get_display_aspect(): forced pixel aspect as [num, den] (6:5 for the
 * 40-column Commodore modes, 4:3 for C128 80x25), or 0,0 for ordinary modes.
 * Both are vparams/screen-mode derived, so they cannot drift from the geometry
 * cterm is drawing into. */
bool native_mode_no_blink(void);
void native_get_display_aspect(int32_t *num, int32_t *den);

/**
 * Get the screen size.
 */
void native_get_screen_size(int32_t *columns, int32_t *rows);

/**
 * Get cursor position.
 */
void native_get_cursor_pos(int32_t *x, int32_t *y);

/**
 * Check if cursor is visible.
 */
bool native_is_cursor_visible(void);

/**
 * Check if BBS explicitly changed cursor type (read and clear).
 */
bool native_cursor_type_changed(void);

/**
 * Get the current cursor type:
 *   _NOCURSOR   (0)  — hidden
 *   _SOLIDCURSOR(1)  — full block
 *   _NORMALCURSOR(2) — underline (default)
 *   _HALFCURSOR (3)  — half-cell
 */
int32_t native_get_cursor_type(void);

/**
 * Top scanline of cursor within a character cell (0 = top).
 */
int32_t native_get_cursor_start(void);

/**
 * Bottom scanline of cursor within a character cell.
 */
int32_t native_get_cursor_end(void);

/**
 * Returns 1 if the cursor blinks, 0 if it is steady.
 */
int32_t native_get_cursor_blinks(void);

/**
 * Check if the screen has changed since last render.
 */
bool native_is_screen_dirty(void);

/**
 * Get dirty region bounds for partial redraw optimization.
 * @return true if there is a dirty region
 */
bool native_get_dirty_region(int32_t *minX, int32_t *minY, int32_t *maxX, int32_t *maxY);

// ============================================================================
// MARK: - Terminal Control
// ============================================================================

/**
 * Set terminal size.
 */
void native_set_terminal_size(int32_t width, int32_t height);

/**
 * Set font by name.
 * @return true on success
 */
bool native_set_font(const char *fontName);

/**
 * Set font by ID.
 * @return true on success
 */
bool native_set_font_by_id(int32_t fontId);

/**
 * Clear the screen.
 */
void native_clear_screen(void);

/**
 * Reset terminal state completely (screen + scrollback).
 * Call this when connecting to a new BBS.
 */
void native_reset_terminal(void);

/**
 * Reset ANSI parser state (colors, bold, ice mode).
 * Call this when starting a new connection.
 */
void cterm_reset_ansi_state(void);

/**
 * Push input data to the terminal.
 */
void native_push_input(const uint8_t *data, int32_t count);

/**
 * Hide or show the status line.
 */
void native_set_hide_status_line(bool hide);

/**
 * SSH blank login, set before every connect: true = no credentials and never a prompt (ssh.c ssh_blank_login).
 */
void native_set_ssh_blank_login(bool on);

/**
 * Set screen mode (0=80x25, 1=80x30, 2=80x50, 3=132x25, 4=132x50, 5=80x40).
 */
void native_set_screen_mode(int32_t mode);

// ============================================================================
// MARK: - Status
// ============================================================================

/**
 * Get status information string.
 */
const char* native_get_status_info(void);

/**
 * Get connection statistics.
 * @return true on success
 */
bool native_get_connection_stats(int64_t *sent, int64_t *received,
                                  int64_t *connectTime, int64_t *currentTime);

/**
 * Modem speed emulation in bps; 0 = full speed (a board's own CSI * r still applies).
 */
void native_set_emulated_bps(int32_t bps);

/**
 * The speed incoming data is metered at: the user's setting, else the board's; 0 = full speed.
 */
int32_t native_get_effective_bps(void);

// ============================================================================
// MARK: - Font Bitmap
// ============================================================================

/**
 * Get the current font ID (as set by BBS via escape sequences or user selection).
 */
int32_t native_get_current_font_id(void);

/**
 * Get font bitmap data.
 * @param width Output: font width (8)
 * @param height Output: font height (8, 14, or 16)
 * @param count Output: data size in bytes
 * @return Pointer to bitmap data (do not free)
 */
const uint8_t* native_get_font_bitmap(int32_t *width, int32_t *height, int32_t *count);

// ============================================================================
// MARK: - File Transfer (ZMODEM)
// ============================================================================

/**
 * Initialize the file transfer subsystem.
 */
bool native_transfer_init(void);

/**
 * Set the download directory.
 */
void native_set_download_dir(const char *dir);

/**
 * Start a ZMODEM receive operation.
 * @return 0 on success, negative on error
 */
int32_t native_zmodem_receive(void);

/**
 * Start a ZMODEM send operation.
 * @return 0 on success, negative on error
 */
int32_t native_zmodem_send(const char *filePath);

/* ---------------------------------------------------------------------------
 * X / YMODEM
 *
 * Nothing here auto-detects. ZMODEM announces itself with "**\x18B00" and the
 * download dialog pops off the back of that; an X/YMODEM sender just starts
 * NAKing into the void, so the user tells the BBS which protocol to use and
 * then picks the same one from the Transfer menu.
 *
 * `mode` is the sbbs3/sexyz.h bit set — see the XferMode constants on the Swift
 * side, which mirror it. Both calls block for the whole transfer, so run them
 * off the main thread exactly like the ZMODEM ones.
 * ------------------------------------------------------------------------- */

/**
 * Receive via X/YMODEM.
 * @param savePath full destination path; REQUIRED for XMODEM (the protocol
 *                 carries no filename) and ignored by YMODEM, which takes the
 *                 name from its header block and uses the download directory.
 * @return number of files received, or negative on error
 */
int32_t native_xmodem_receive(const char *savePath, int32_t mode);

/**
 * Send one file via X/YMODEM.
 * @return 0 on success, negative on error
 */
int32_t native_xmodem_send(const char *filePath, int32_t mode);

/**
 * Cancel the current transfer.
 */
void native_transfer_cancel(void);

/**
 * Get the current transfer state.
 * 0=idle, 1=receiving, 2=sending, 3=complete, 4=error, 5=cancelled
 */
int32_t native_get_transfer_state(void);

/**
 * Drain protocol status lines produced since the last call. Each line is a
 * severity char ('I', 'W', 'E', 'S') followed by the message, '\n' separated.
 * Returns bytes written; lines are handed out once.
 */
int32_t native_get_transfer_log(char *buffer, int32_t buffer_len);

/** Discard pending status lines so a new transfer starts with a clean feed. */
void native_clear_transfer_log(void);

/**
 * Get transfer progress.
 * @return true on success
 */
bool native_get_transfer_progress(int64_t *transferred, int64_t *total);

/**
 * Get the name of the file being transferred.
 */
const char* native_get_transfer_file_name(void);

/**
 * Get the error message from the last failed transfer.
 */
const char* native_get_transfer_error(void);

/**
 * Reset transfer state after completion or error.
 */
void native_transfer_reset(void);

/**
 * Cleanup file transfer resources.
 */
void native_transfer_cleanup(void);

// ============================================================================
// MARK: - ZMODEM Auto-Detection
// ============================================================================

/**
 * Check if ZMODEM was auto-detected.
 */
bool native_is_zmodem_detected(void);

/**
 * Get buffered ZMODEM data from detection.
 * @param count Output: buffer size
 * @return Pointer to buffer (do not free)
 */
const uint8_t* native_get_zmodem_buffer(int32_t *count);

/**
 * Clear ZMODEM detection state.
 */
void native_clear_zmodem_detected(void);

/**
 * Push buffered ZMODEM data back into connection buffer.
 */
int32_t native_push_zmodem_buffer(void);

// ============================================================================
// MARK: - Upload Queue
// ============================================================================

/**
 * Queue a file for upload.
 */
void native_queue_upload(const char *filePath);

/**
 * Check if a file is queued for upload.
 */
bool native_is_upload_queued(void);

/**
 * Check if the BBS is ready for upload (ZRINIT received).
 */
bool native_is_upload_ready(void);

/**
 * Get the path of the queued upload file.
 */
const char* native_get_queued_upload(void);

/**
 * Clear the upload queue.
 */
void native_clear_upload_queue(void);

// ============================================================================
// MARK: - Batch Upload Queue (multi-file ZMODEM)
// ============================================================================

/**
 * Clear the batch upload queue.
 * @return 0
 */
int32_t native_upload_queue_clear(void);

/**
 * Append a file path to the batch upload queue.
 * @return new count on success, -1 on error/full
 */
int32_t native_upload_queue_add(const char *filePath);

/**
 * Get the number of files currently in the batch upload queue.
 */
int32_t native_upload_queue_count(void);

/**
 * Send all queued files as a single ZMODEM batch session.
 * @return number of files sent (>=0) on success, negative on error
 */
int32_t native_zmodem_send_batch(void);

/**
 * Get the current file index and total for a batch transfer.
 * Values are 1-based; total 0/1 indicates a single-file transfer.
 * @return 0
 */
int32_t native_get_transfer_file_index(int32_t *current, int32_t *total);

// ============================================================================
// MARK: - Scrollback Buffer
// ============================================================================

/**
 * Get scrollback buffer info.
 * @return true on success
 */
bool native_get_scrollback_info(int32_t *filled, int32_t *capacity, int32_t *columns);

/**
 * Get scrollback buffer content.
 * @param offset Lines from current position
 * @param count Lines to retrieve
 * @param resultCount Output: cells returned
 * @return Pointer to buffer (do not free)
 */
const int32_t* native_get_scrollback_buffer(int32_t offset, int32_t count, int32_t *resultCount);

/** True-colour variant of native_get_scrollback_buffer -- see native_get_screen_buffer_rgb. */
const int32_t* native_get_scrollback_buffer_rgb(int32_t offset, int32_t count, int32_t *resultCount,
                                                const int32_t **fg, const int32_t **bg);

// ============================================================================
// MARK: - Bell Detection
// ============================================================================

/**
 * Check if a bell (BEL character) was received and clear the flag.
 */
bool native_check_bell(void);

// ============================================================================
// MARK: - Session Logging
// ============================================================================

/**
 * Enable or disable session logging.
 */
void native_set_logging_enabled(bool enabled);

/**
 * Get and clear logged data from the buffer.
 * @param count Output: data size
 * @return Pointer to log buffer (do not free)
 */
const uint8_t* native_get_logged_data(int32_t *count);

// ============================================================================
// MARK: - SSH Debug Log
// ============================================================================

/**
 * Get the accumulated SSH connection debug log.
 * @param buffer Output buffer (caller-allocated)
 * @param bufferLen Size of output buffer
 * @return Bytes written (excluding trailing NUL)
 */
int32_t native_get_ssh_debug_log(char *buffer, int32_t bufferLen);

/**
 * Clear the SSH connection debug log.
 */
void native_clear_ssh_debug_log(void);

// ============================================================================
// MARK: - Audio Command (OSC 800 / TAP)
// ============================================================================

/**
 * Check if an audio command is pending (lockless volatile read).
 */
bool native_check_audio_command(void);

/**
 * Get the pending audio command string and clear the flag.
 * @return Pointer to command string (static buffer, do not free), or NULL
 */
const char* native_get_audio_command(void);

// ============================================================================
// MARK: - MOD Player (libxmp)
// ============================================================================

/**
 * Load a tracker module file and start the player.
 * @param filePath Path to MOD/S3M/XM/IT file
 * @return true on success
 */
bool native_mod_load(const char *filePath);

/**
 * Render PCM frames from the loaded module.
 * Output: interleaved 16-bit stereo samples.
 * @param buffer Output buffer for PCM data
 * @param frames Number of frames to render
 * @return Frames rendered, or -1 on end/error
 */
int32_t native_mod_get_pcm(int16_t *buffer, int32_t frames);

/**
 * Stop and release the current module.
 */
void native_mod_stop(void);

/**
 * Set MOD playback volume (0.0 - 1.0).
 */
void native_mod_set_volume(float volume);

/**
 * Check if a module is currently playing.
 */
bool native_mod_is_playing(void);

/**
 * Seek to a position in the current module (milliseconds).
 */
void native_mod_restart(void);
void native_mod_seek(int32_t position_ms);

// ============================================================================
// MARK: - Sixel Graphics
// ============================================================================

/**
 * Check if any sixel pixel data has been written.
 */
bool native_has_sixel_data(void);

/**
 * Check if sixel pixel data has been updated since last read.
 */
bool native_is_sixel_dirty(void);

/**
 * Get sixel pixel buffer dimensions.
 * @return true if there is sixel data
 */
bool native_get_sixel_dimensions(int32_t *width, int32_t *height);

/**
 * Get sixel pixel buffer contents.
 * @param buffer Output buffer for pixel data (ARGB format)
 * @param bufferLen Size of output buffer in pixels
 * @return Number of pixels written
 */
int32_t native_get_sixel_buffer(int32_t *buffer, int32_t bufferLen);

/**
 * Copy only the sixel layer's changed rectangle into `dest` (dest_w x dest_h ARGB, dest_stride pixels per row)
 * and clear the dirty state; `full` copies everything.
 * @return Pixels copied (the rectangle in *x,*y,*w,*h), 0 for nothing, -1 when dest isn't the layer's size
 *         (*bw x *bh is the size to re-create it at; always set)
 */
int32_t native_copy_sixel_pixels(uint32_t *dest, int32_t dest_w, int32_t dest_h, int32_t dest_stride, bool full,
                                 int32_t *x, int32_t *y, int32_t *w, int32_t *h, int32_t *bw, int32_t *bh);

// ============================================================================
// MARK: - Fast Terminal Rendering
// ============================================================================

/**
 * Render the terminal screen to a pixel buffer (fast C implementation).
 * @param pixels Output buffer (BGRA, size: cellWidth*cols * cellHeight*rows * 4)
 * @param screenBuffer Screen buffer from native_get_screen_buffer
 * @param cols Number of columns
 * @param rows Number of rows
 * @param cellWidth Cell width in pixels (scaled)
 * @param cellHeight Cell height in pixels (scaled)
 * @param fontData Font bitmap from native_get_font_bitmap
 * @param fontWidth Native font width (8)
 * @param fontHeight Native font height (16)
 * @param palette 16-color palette from native_get_palette
 */
void native_render_terminal(uint8_t *pixels,
                            int32_t pixelBufferSize,
                            const int32_t *screenBuffer,
                            int32_t screenBufferCount,
                            int32_t cols, int32_t rows,
                            int32_t cellWidth, int32_t cellHeight,
                            const uint8_t *fontData,
                            int32_t fontDataSize,
                            int32_t fontWidth, int32_t fontHeight,
                            const uint32_t *palette);

#ifdef __cplusplus
}
#endif

#endif /* NATIVE_BRIDGE_H */
