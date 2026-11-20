/**
 * SyncTERM iOS Native Bridge
 *
 * Provides C functions to connect Swift with the native
 * SyncTERM terminal emulator and Telnet/SSH connection code.
 *
 * This is the iOS equivalent of Android's syncterm_jni.c
 */

#include <string.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <pthread.h>
#include <sys/time.h>
#include <unistd.h>
#include <time.h>

// Logging — write to stderr so it's unbuffered
#define IOS_LOG(fmt, ...) fprintf(stderr, "[NativeBridge] " fmt "\n", ##__VA_ARGS__)

// SSH debug log helpers — defined in macos_stubs.c
extern void ssh_debug_log(const char *fmt, ...);
extern void ssh_debug_clear_log(void);
extern void ssh_debug_reset_retry_count(void);

// Include SyncTERM headers
#include "cterm.h"
#include "ciolib.h"
#include "conn.h"
#include "conn_telnet.h"
#include "bbslist.h"
#include "genwrap.h"
#include "sockwrap.h"
#include "rlogin.h"       /* rlogin_sock: the telnet/raw TCP socket, for TCP_NODELAY */

#ifndef WITHOUT_CRYPTLIB
#include "ssh.h"
#ifdef WITH_WEBSOCKET
#include "conn_websocket.h"

// Route WebSocket diagnostics into the SSH debug log window
static void websocket_bridge_log(const char *msg) {
    ssh_debug_log("[ws] %s\n", msg);
}
#endif
#endif

// iOS-specific ciolib implementation
#include "macos_ciolib.h"

// macOS MIGRATION 2026-09-04: terminal-engine selector (USE_REAL_CTERM).
// The BEL(0x07) scan (now in feed_terminal(), which native_process_data() feeds) is unconditional on macOS
// and stays correct either way, so unlike iOS this file needs no #if of its own.
#include "cterm_mode.h"

// Native bridge header (function declarations)
#include "native_bridge.h"

// SyncTERM APC: cache, JPEG XL / PPM images, audio (Bridge/apc/, ported from Windows 2026-09-16)
#include "apc_bridge.h"

// TRACE: TERMinator Render And Compute Engine escapes, including the binary-frame filter (Bridge/apc/trace_bridge.c)
#include "trace_bridge.h"

// xterm mouse reports (CSI ? 1000 h and friends), as SyncTERM sends them (Bridge/mouse_bridge.c)
#include "mouse_bridge.h"

// ZMODEM implementation
#include "zmodem_macos.h"

// Maximum scrollback buffer size (100 MB)
#define MAX_SCROLLBACK_BYTES (100 * 1024 * 1024)

// Log buffer size for session logging
#define LOG_BUFFER_SIZE (64 * 1024)

// Global state
static struct cterminal *g_cterm = NULL;
static struct vmem_cell *g_scrollback = NULL;
static int g_scrollback_lines = 1000;
static int g_connected = 0;
static int g_initialized = 0;
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;

/* Background send queue (native_send_data_nowait): see the section after native_send_data.
 * g_send_lock is held around every conn_send the drain thread makes and around conn_close, so
 * the connection buffers cannot be torn down mid-send. Lock order: g_send_lock, then g_lock. */
static pthread_mutex_t g_send_lock = PTHREAD_MUTEX_INITIALIZER;
static void sendq_end_session(void);

/* Physical key reports (CSI = 1 h / CSI = 2 h): see the section above native_send_key */
static void keyev_attach(struct cterminal *cterm);
static void keyev_sync_modes(struct cterminal *cterm);
static void keyev_reset(void);

// Terminal dimensions
// Non-static: also used by ios_stubs.c for get_cterm_size/get_term_win_size
int g_term_width = 80;
int g_term_height = 25;

// Current font ID (non-static: also updated by macos_ciolib.c setfont callback)
int g_current_font_id = 0;
// macOS PETSCII 2026-09-04: cterm emulation, derived from the screen mode.
static int g_emulation = CTERM_EMULATION_ANSI_BBS;

// Connection settings
static int g_hide_status_line = 1;
static int g_ssh_blank_login = 0;   /* SSH with no credentials: the board logs the caller in (ssh.c ssh_blank_login) */
static int g_screen_mode = 0;  // SCREEN_MODE_80X25
static char g_font_name[256] = "Codepage 437 English";

// Connection config
struct bbslist g_bbs_config;

// ZMODEM state
static volatile int g_zmodem_detected = 0;
static volatile int g_zmodem_upload_ready = 0;
static unsigned char g_zmodem_buffer[4096];
static int g_zmodem_buffer_len = 0;
static pthread_mutex_t g_zmodem_lock = PTHREAD_MUTEX_INITIALIZER;

// Cross-buffer ZMODEM detection: save last byte from previous read
static unsigned char g_prev_last_byte = 0;
static int g_has_prev_byte = 0;

// Upload queue (single-slot, used by auto-detect path)
static char g_upload_queued_file[512] = {0};
static volatile int g_upload_file_queued = 0;

// Batch upload queue (multi-file). Populated by the UI thread via
// native_upload_queue_add() before native_zmodem_send_batch(); population and
// consumption never overlap (queue is filled, then the batch send runs).
#define MAX_UPLOAD_FILES 256
static char g_upload_batch[MAX_UPLOAD_FILES][512];
static int g_upload_batch_count = 0;

// Bell detection
static volatile int g_bell_detected = 0;

// TAP+ command queue - receives OSC 800 commands from cterm
#define TAP_CMD_BUFFER_SIZE 4096
#define TAP_CMD_QUEUE_SIZE 64
static char g_tap_cmd_queue[TAP_CMD_QUEUE_SIZE][TAP_CMD_BUFFER_SIZE];
static int  g_tap_cmd_lengths[TAP_CMD_QUEUE_SIZE];
static volatile int g_tap_queue_head = 0;   // Next slot to write
static volatile int g_tap_queue_tail = 0;   // Next slot to read
static volatile int g_tap_queue_count = 0;  // Number of commands pending
static pthread_mutex_t g_audio_lock = PTHREAD_MUTEX_INITIALIZER;

// Connection statistics
static volatile uint64_t g_bytes_sent = 0;
static volatile uint64_t g_bytes_received = 0;
static volatile int64_t g_connect_time_ms = 0;

// Modem speed emulation, in bps (0 = full speed). The user's setting wins; without one, a board can set its own
// speed with CSI Ps1 ; Ps2 * r. Incoming data is metered with a token bucket in native_process_data. Same as the
// Windows and Linux bridges.
static _Atomic int g_emulated_bps = 0;
static _Atomic int g_host_bps = 0;
static double g_bps_credit = 0;    // characters the emulated line may still deliver; guarded by g_lock
static int64_t g_bps_last_ms = 0;  // when the credit was last topped up; guarded by g_lock

// Look-ahead for terminal queries in data still queued behind the speed meter (see find_pending_query_end)
static unsigned char g_query_peek[32768];              // guarded by g_lock
static size_t g_query_scan_waiting = (size_t)-1;       // queue length at the last scan that found nothing

// Session logging
static unsigned char g_log_buffer[LOG_BUFFER_SIZE];
static volatile int g_log_buffer_len = 0;
static volatile int g_logging_enabled = 0;
static pthread_mutex_t g_log_lock = PTHREAD_MUTEX_INITIALIZER;

// Files directory for SSH keys
static char g_files_dir[512] = {0};

// Transfer state
static int g_transfer_state = 0;  // idle
static int64_t g_transfer_bytes = 0;
static int64_t g_transfer_total = 0;
static char g_transfer_filename[256] = {0};
static char g_transfer_error[256] = {0};
static char g_download_dir[512] = {0};

// Helper: Get current time in milliseconds
static int64_t get_current_time_ms(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (int64_t)tv.tv_sec * 1000 + (int64_t)tv.tv_usec / 1000;
}

// ZMODEM frame types
#define ZMODEM_FRAME_ZRQINIT  0x00
#define ZMODEM_FRAME_ZRINIT   0x01

// Check if a byte is a valid ZMODEM header type indicator
// Standard: 'A' (ZBIN/CRC16), 'B' (ZHEX), 'C' (ZBIN32/CRC32)
// Variable-length: 'a' (ZVBIN), 'b' (ZVHEX), 'c' (ZVBIN32), 'd' (ZVBINR32)
static int is_zmodem_header_type(unsigned char c) {
    return c == 'A' || c == 'B' || c == 'C' ||
           c == 'a' || c == 'b' || c == 'c' || c == 'd';
}

// Check if a header type byte indicates hex encoding
static int is_hex_header(unsigned char c) {
    return c == 'B' || c == 'b';
}

// Detect ZMODEM header in buffer
typedef struct {
    int position;
    int frame_type;
} zmodem_detect_result_t;

static zmodem_detect_result_t detect_zmodem_ex(const unsigned char *buf, int len) {
    zmodem_detect_result_t result = { -1, -1 };

    if (len < 1) return result;

    for (int i = 0; i < len - 1; i++) {
        // Look for ZDLE (0x18) followed by header type
        if (buf[i] == 0x18 && is_zmodem_header_type(buf[i+1])) {
            int start = i;
            // Back up to include ZPAD bytes
            while (start > 0 && buf[start - 1] == 0x2a) {
                start--;
            }

            int frame_type = -1;
            if (is_hex_header(buf[i+1]) && i + 3 < len) {
                char hex[3] = { buf[i+2], buf[i+3], 0 };
                frame_type = (int)strtol(hex, NULL, 16);
            } else if (!is_hex_header(buf[i+1]) && i + 2 < len) {
                frame_type = buf[i+2];
            }

            result.position = start;
            result.frame_type = frame_type;
            return result;
        }
    }

    // Check if the LAST byte is ZDLE (could be split across reads)
    // Save it for cross-buffer detection on the next call
    if (len >= 1 && buf[len - 1] == 0x18) {
        g_has_prev_byte = 1;
        g_prev_last_byte = 0x18;
    } else {
        g_has_prev_byte = 0;
    }

    return result;
}

// ============================================================================
// MARK: - Initialization Functions
// ============================================================================

// Forward declaration - defined in macos_stubs.c
extern void ios_set_files_dir(const char *path);

void native_set_files_dir(const char *path) {
    if (path) {
        strncpy(g_files_dir, path, sizeof(g_files_dir) - 1);
        g_files_dir[sizeof(g_files_dir) - 1] = '\0';
        // Also set the path used by get_syncterm_filename() in macos_stubs.c
        ios_set_files_dir(path);
    }
}

bool native_init(void) {
    pthread_mutex_lock(&g_lock);

    if (g_initialized) {
        pthread_mutex_unlock(&g_lock);
        return true;
    }

#ifndef WITHOUT_CRYPTLIB
    // Initialize cryptlib for SSH
    init_crypt();
#endif

    // Initialize ciolib (iOS-specific implementation)
    if (initciolib(CIOLIB_MODE_AUTO) != 0) {
        pthread_mutex_unlock(&g_lock);
        return false;
    }

    // Allocate scrollback buffer
    int scrollback_cols = g_term_width > 132 ? g_term_width : 132;
    size_t scrollback_size = (size_t)g_scrollback_lines * scrollback_cols * sizeof(struct vmem_cell);

    if (scrollback_size > MAX_SCROLLBACK_BYTES) {
        pthread_mutex_unlock(&g_lock);
        return false;
    }

    g_scrollback = calloc(1, scrollback_size);
    if (!g_scrollback) {
        pthread_mutex_unlock(&g_lock);
        return false;
    }

    // Initialize terminal emulator
    g_cterm = cterm_init(g_term_height, g_term_width, 1, 1,
                         g_scrollback_lines, scrollback_cols,
                         g_scrollback, g_emulation);   // macOS PETSCII 2026-09-04
    if (!g_cterm) {
        free(g_scrollback);
        g_scrollback = NULL;
        pthread_mutex_unlock(&g_lock);
        return false;
    }

    cterm_start(g_cterm);
    g_initialized = 1;

    pthread_mutex_unlock(&g_lock);
    return true;
}

void native_destroy(void) {
    sendq_end_session();
    pthread_mutex_lock(&g_send_lock);
    pthread_mutex_lock(&g_lock);

    if (g_connected) {
        conn_close();
        g_connected = 0;
    }
    pthread_mutex_unlock(&g_send_lock);

    if (g_cterm) {
        cterm_end(g_cterm, 0);
        g_cterm = NULL;
    }
    macos_apc_session_reset();
    keyev_reset();
    mouse_bridge_reset();

    if (g_scrollback) {
        free(g_scrollback);
        g_scrollback = NULL;
    }

    macos_ciolib_cleanup();
    g_initialized = 0;

    // Reset terminal dimensions so the next native_set_terminal_size()
    // call (from setScreenMode) will detect a change and properly resize
    // ios_ciolib, which macos_ciolib_init() always resets to 80x25.
    g_term_width = 80;
    g_term_height = 25;

    // Reset font state
    g_current_font_id = 0;
    memset(g_font_name, 0, sizeof(g_font_name));
    strncpy(g_font_name, "Codepage 437 English", sizeof(g_font_name) - 1);

    // Reset connection statistics
    g_bytes_sent = 0;
    g_bytes_received = 0;
    g_connect_time_ms = 0;

    // Reset bell detection
    g_bell_detected = 0;

    // Reset ZMODEM state
    g_zmodem_detected = 0;
    g_zmodem_upload_ready = 0;
    g_zmodem_buffer_len = 0;
    g_prev_last_byte = 0;
    g_has_prev_byte = 0;
    g_upload_file_queued = 0;
    g_upload_queued_file[0] = '\0';
    g_upload_batch_count = 0;

    // Reset transfer state
    g_transfer_state = 0;
    g_transfer_bytes = 0;
    g_transfer_total = 0;
    g_transfer_filename[0] = '\0';
    g_transfer_error[0] = '\0';

    // Reset TAP+ audio command queue under lock
    pthread_mutex_lock(&g_audio_lock);
    g_tap_queue_head = 0;
    g_tap_queue_tail = 0;
    g_tap_queue_count = 0;
    pthread_mutex_unlock(&g_audio_lock);

    // Reset log buffer under lock
    pthread_mutex_lock(&g_log_lock);
    g_log_buffer_len = 0;
    g_logging_enabled = 0;
    pthread_mutex_unlock(&g_log_lock);

    pthread_mutex_unlock(&g_lock);
}

// ============================================================================
// MARK: - Connection Functions
// ============================================================================

bool native_connect(const char *host, int32_t port, int32_t protocol,
                    const char *username, const char *password) {
    if (!g_initialized || g_connected) {
        return false;
    }

    pthread_mutex_lock(&g_lock);

    // Set up connection config
    memset(&g_bbs_config, 0, sizeof(g_bbs_config));
    strncpy(g_bbs_config.name, "iOS Connection", LIST_NAME_MAX);
    g_bbs_config.name[LIST_NAME_MAX] = '\0';
    strncpy(g_bbs_config.addr, host, LIST_ADDR_MAX);
    g_bbs_config.addr[LIST_ADDR_MAX] = '\0';
    g_bbs_config.port = (uint16_t)port;

    if (protocol == 5) {  // SSH
#ifndef WITHOUT_CRYPTLIB
        g_bbs_config.type = CONN_TYPE_SSH;
        g_bbs_config.conn_type = CONN_TYPE_SSH;

        // Blank login: no prompts; ssh.c logs in as "bbs" with a password Rainwire ignores, so none of the
        // "guest" defaults below (Rainwire counts guest as a trap name).
        ssh_blank_login = g_ssh_blank_login;
        ssh_offer_key = 0;  /* never the client key: the entry's own account logs in (ssh.c ssh_offer_key) */
        if (ssh_blank_login) {
            if (username && username[0]) {
                strncpy(g_bbs_config.user, username, MAX_USER_LEN);
                g_bbs_config.user[MAX_USER_LEN] = '\0';
            }
        } else if (username && username[0]) {
            strncpy(g_bbs_config.user, username, MAX_USER_LEN);
            g_bbs_config.user[MAX_USER_LEN] = '\0';
        } else {
            // Default to "guest" — the uifcinput stub can't prompt interactively
            strncpy(g_bbs_config.user, "guest", MAX_USER_LEN);
            g_bbs_config.user[MAX_USER_LEN] = '\0';
        }
        if (ssh_blank_login) {
            // no password at all
        } else if (password && password[0]) {
            strncpy(g_bbs_config.password, password, MAX_PASSWD_LEN);
            g_bbs_config.password[MAX_PASSWD_LEN] = '\0';
        } else {
            // Provide empty password so ssh_connect won't try to prompt
            strncpy(g_bbs_config.password, "guest", MAX_PASSWD_LEN);
            g_bbs_config.password[MAX_PASSWD_LEN] = '\0';
        }
#else
        g_bbs_config.type = CONN_TYPE_TELNET;
        g_bbs_config.conn_type = CONN_TYPE_TELNET;
#endif
    } else if (protocol == 13) {  // TelnetS (Telnet over TLS)
        g_bbs_config.type = CONN_TYPE_TELNETS;
        g_bbs_config.conn_type = CONN_TYPE_TELNETS;
    } else if (protocol == CONN_TYPE_RAW) {
        // Raw: a plain 8-bit socket, NO telnet negotiation and no IAC handling.
        //
        // Not every board on port 23 actually speaks telnet. Against one that does not,
        // our telnet layer eats any 0xFF in the stream as an IAC command. ZMODEM shrugs
        // that off because it escapes IAC itself before the bytes reach the wire, but
        // X/YMODEM blocks ARE raw file bytes, so a download CRCs, retries and dies while
        // ZMODEM on the same board is perfectly happy. This is the escape hatch for that,
        // and it is why IcyTerm exposes a connection-type picker too.
        //
        // conn.c dispatches CONN_TYPE_RAW to raw_connect/raw_close and leaves
        // conn_api.binary_mode_on NULL; conn_binary_mode_on() null-checks it, so the
        // X/YMODEM session's binary-mode override is a harmless no-op on a raw link.
        g_bbs_config.type = CONN_TYPE_RAW;
        g_bbs_config.conn_type = CONN_TYPE_RAW;
    } else if (protocol == CONN_TYPE_WEBSOCKET || protocol == CONN_TYPE_WEBSOCKETS) {
        // WebSocket / Secure WebSocket (RFC 6455 carrying a telnet stream)
#if !defined(WITHOUT_CRYPTLIB) && defined(WITH_WEBSOCKET)
        g_bbs_config.type = protocol;
        g_bbs_config.conn_type = protocol;
        websocket_log_cb = websocket_bridge_log;
#else
        // Not built in — fall back rather than dialling a protocol we cannot speak
        g_bbs_config.type = CONN_TYPE_TELNET;
        g_bbs_config.conn_type = CONN_TYPE_TELNET;
#endif
    } else {
        g_bbs_config.type = CONN_TYPE_TELNET;
        g_bbs_config.conn_type = CONN_TYPE_TELNET;
    }

    g_bbs_config.screen_mode = g_screen_mode;
    g_bbs_config.hidepopups = 1;
    g_bbs_config.nostatus = g_hide_status_line;
    strncpy(g_bbs_config.font, g_font_name, sizeof(g_bbs_config.font) - 1);

    // Initialize palette
    g_bbs_config.palette[0]  = 0x000000;
    g_bbs_config.palette[1]  = 0x0000AA;
    g_bbs_config.palette[2]  = 0x00AA00;
    g_bbs_config.palette[3]  = 0x00AAAA;
    g_bbs_config.palette[4]  = 0xAA0000;
    g_bbs_config.palette[5]  = 0xAA00AA;
    g_bbs_config.palette[6]  = 0xAA5500;
    g_bbs_config.palette[7]  = 0xAAAAAA;
    g_bbs_config.palette[8]  = 0x555555;
    g_bbs_config.palette[9]  = 0x5555FF;
    g_bbs_config.palette[10] = 0x55FF55;
    g_bbs_config.palette[11] = 0x55FFFF;
    g_bbs_config.palette[12] = 0xFF5555;
    g_bbs_config.palette[13] = 0xFF55FF;
    g_bbs_config.palette[14] = 0xFFFF55;
    g_bbs_config.palette[15] = 0xFFFFFF;

    // Reset ANSI parser state from any previous connection
    cterm_reset_ansi_state();

    // Start fresh SSH debug log for this connection attempt
    ssh_debug_clear_log();
    ssh_debug_reset_retry_count();
    ssh_debug_log("=== SSH Connection Attempt ===\n");
    const char *proto_name = (protocol == 5) ? "SSH"
                           : (protocol == 13) ? "TelnetS"
                           : (protocol == CONN_TYPE_RAW) ? "Raw"
                           : (protocol == CONN_TYPE_WEBSOCKET) ? "WebSocket"
                           : (protocol == CONN_TYPE_WEBSOCKETS) ? "Secure WebSocket"
                           : "Telnet";
    ssh_debug_log("Host: %s  Port: %d  Protocol: %d (%s)\n",
                  host, (int)port, (int)protocol, proto_name);
    ssh_debug_log("Username: '%s'  Password: %s  Screen: %dx%d\n",
                  g_bbs_config.user,
                  g_bbs_config.password[0] ? "[provided]" : "[empty]",
                  g_term_width, g_term_height);

    IOS_LOG("[native_connect] Calling conn_connect for %{public}s:%d (type=%d)",
           g_bbs_config.addr, g_bbs_config.port, g_bbs_config.conn_type);

    // IMPORTANT: Release lock during conn_connect() because it can block
    // waiting for threads to start, and other code (like native_is_connected)
    // needs to acquire the lock. This prevents deadlock.
    pthread_mutex_unlock(&g_lock);

    bool terminated = conn_connect(&g_bbs_config);

    pthread_mutex_lock(&g_lock);
    IOS_LOG("[native_connect] conn_connect returned terminated=%d", terminated);

    if (!terminated) {
        g_connected = 1;
        g_bytes_sent = 0;
        g_bytes_received = 0;
        g_connect_time_ms = get_current_time_ms();
        g_host_bps = 0;
        g_bps_credit = 0;
        g_bps_last_ms = 0;
        g_query_scan_waiting = (size_t)-1;

        /* Plain telnet/raw sockets come out of conn_socket_connect() with Nagle on, so the OS holds back each small
         * write until the previous one is ACKed: key reports and the cursor-position replies SyncDOOM paces its frames
         * on. SSH, TelnetS and WebSocket already turn it off. Same as Windows (1.1.1); it lives in the bridge, not the
         * shared conn.c. Telnet and raw (raw_connect is rlogin_connect) both keep their socket in rlogin_sock. */
        if (g_bbs_config.conn_type == CONN_TYPE_TELNET || g_bbs_config.conn_type == CONN_TYPE_RAW) {
            int on = 1;
            if (setsockopt(rlogin_sock, IPPROTO_TCP, TCP_NODELAY, (char *)&on, sizeof(on)) != 0)
                IOS_LOG("[native_connect] setsockopt(TCP_NODELAY) failed: %s", strerror(errno));
        }

        ssh_debug_log("\n=== Connection SUCCEEDED ===\n");
        IOS_LOG("[native_connect] Connection established, g_connected=1");
    } else {
        ssh_debug_log("\n=== Connection FAILED ===\n");
        IOS_LOG("[native_connect] Connection failed");
    }

    pthread_mutex_unlock(&g_lock);
    return !terminated;
}

void native_disconnect(void) {
    extern struct conn_api conn_api;
    conn_api.terminate = true;

    sendq_end_session();
    pthread_mutex_lock(&g_send_lock);
    pthread_mutex_lock(&g_lock);

    if (g_connected) {
        conn_close();
        g_connected = 0;
    }
    pthread_mutex_unlock(&g_send_lock);
    macos_apc_session_reset();
    keyev_reset();
    mouse_bridge_reset();

    pthread_mutex_unlock(&g_lock);
}

/* Blocks up to timeout_ms until received data is waiting and returns as soon as it is, so a door that paces frames
 * on our cursor-position replies (SyncDoom) is answered the moment its frame lands instead of on the next poll
 * tick. Checks every 1 ms under g_lock: conn_close() tears conn_inbuf down under the same lock, so a disconnect
 * can't free it mid-wait (conn_buf_wait_bytes would sleep on that buffer without the lock). Windows
 * syncterm_wait_for_data, 2026-09-15. Returns the bytes waiting, or 0 on timeout or when not connected. */
static int64_t monotonic_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

int32_t native_wait_for_data(int32_t timeout_ms) {
    /* Monotonic, like Windows' timeGetTime: a wall-clock change mustn't stretch the wait */
    int64_t start = monotonic_ms();
    int64_t span = timeout_ms > 0 ? timeout_ms : 0;

    for (;;) {
        size_t waiting = 0;
        int connected;

        pthread_mutex_lock(&g_lock);
        connected = g_connected;
        if (connected) {
            waiting = conn_data_waiting();
        }
        pthread_mutex_unlock(&g_lock);

        if (!connected) {
            return 0;
        }
        if (waiting > 0) {
            return waiting > INT32_MAX ? INT32_MAX : (int32_t)waiting;
        }
        if (monotonic_ms() - start >= span) {
            return 0;
        }
        usleep(1000);
    }
}

bool native_is_connected(void) {
    pthread_mutex_lock(&g_lock);
    bool conn_state = conn_connected();
    bool result = g_connected && conn_state;
    pthread_mutex_unlock(&g_lock);
    return result;
}

// ============================================================================
// MARK: - Data Transfer Functions
// ============================================================================

int32_t native_send_data(const uint8_t *data, int32_t count) {
    if (!g_connected || count <= 0) {
        return -1;
    }

    int sent = conn_send(data, (size_t)count, 1000);
    if (sent > 0) {
        pthread_mutex_lock(&g_lock);
        g_bytes_sent += sent;
        pthread_mutex_unlock(&g_lock);
    }
    return (int32_t)sent;
}

/* ------------------------------------------------------------------ */
/* Non-blocking send (native_send_data_nowait)                         */
/* ------------------------------------------------------------------ */
/* native_send_data waits up to a second for room in the output buffer, which stalls the UI when a module streams
 * a lot to a door. The nowait variant copies the bytes into a FIFO and returns at once; one background thread
 * drains it through conn_send in slices small enough (expanded <= 2 KB, the buffer is 16 KB) that a slice is never
 * split. Chunks are tagged with the session they were queued in, and a disconnect empties the queue, so nothing
 * queued for one connection can reach the next. */

#define SENDQ_MAX_BYTES (4 * 1024 * 1024)
#define SENDQ_SLICE     1024

struct sendq_chunk {
    struct sendq_chunk *next;
    unsigned            session;
    size_t              len;
    uint8_t             data[];
};

static pthread_mutex_t     g_sendq_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t      g_sendq_cond = PTHREAD_COND_INITIALIZER;
static struct sendq_chunk *g_sendq_head = NULL;
static struct sendq_chunk *g_sendq_tail = NULL;
static size_t              g_sendq_bytes = 0;
static unsigned            g_sendq_session = 0;
static bool                g_sendq_thread_running = false;

static bool sendq_session_current(unsigned session) {
    pthread_mutex_lock(&g_sendq_lock);
    bool current = (session == g_sendq_session);
    pthread_mutex_unlock(&g_sendq_lock);
    return current;
}

static void *sendq_thread(void *arg) {
    (void)arg;
    for (;;) {
        pthread_mutex_lock(&g_sendq_lock);
        while (g_sendq_head == NULL)
            pthread_cond_wait(&g_sendq_cond, &g_sendq_lock);
        struct sendq_chunk *chunk = g_sendq_head;
        g_sendq_head = chunk->next;
        if (g_sendq_head == NULL)
            g_sendq_tail = NULL;
        g_sendq_bytes -= chunk->len;
        pthread_mutex_unlock(&g_sendq_lock);

        size_t off = 0;
        while (off < chunk->len && g_connected && sendq_session_current(chunk->session)) {
            size_t n = chunk->len - off;
            if (n > SENDQ_SLICE)
                n = SENDQ_SLICE;
            pthread_mutex_lock(&g_send_lock);
            int sent = 0;
            if (g_connected && sendq_session_current(chunk->session))
                sent = conn_send(chunk->data + off, n, 250);
            pthread_mutex_unlock(&g_send_lock);
            if (sent > 0) {
                off += n;
                pthread_mutex_lock(&g_lock);
                g_bytes_sent += sent;
                pthread_mutex_unlock(&g_lock);
            }
            /* sent == 0: output buffer still full after 250 ms; retry the same slice */
        }
        free(chunk);
    }
    return NULL;
}

/* Drop everything queued and retire the session's tag (disconnect / destroy). */
static void sendq_end_session(void) {
    pthread_mutex_lock(&g_sendq_lock);
    struct sendq_chunk *chunk = g_sendq_head;
    g_sendq_head = g_sendq_tail = NULL;
    g_sendq_bytes = 0;
    g_sendq_session++;
    pthread_mutex_unlock(&g_sendq_lock);
    while (chunk) {
        struct sendq_chunk *next = chunk->next;
        free(chunk);
        chunk = next;
    }
}

int32_t native_send_data_nowait(const uint8_t *data, int32_t count) {
    if (!g_connected || !data || count <= 0)
        return -1;

    struct sendq_chunk *chunk = malloc(sizeof(*chunk) + (size_t)count);
    if (!chunk)
        return -1;
    chunk->next = NULL;
    chunk->len = (size_t)count;
    memcpy(chunk->data, data, (size_t)count);

    pthread_mutex_lock(&g_sendq_lock);
    if (g_sendq_bytes + chunk->len > SENDQ_MAX_BYTES) {
        pthread_mutex_unlock(&g_sendq_lock);
        free(chunk);
        return -1;
    }
    if (!g_sendq_thread_running) {
        pthread_t tid;
        if (pthread_create(&tid, NULL, sendq_thread, NULL) != 0) {
            pthread_mutex_unlock(&g_sendq_lock);
            free(chunk);
            return -1;
        }
        pthread_detach(tid);
        g_sendq_thread_running = true;
    }
    chunk->session = g_sendq_session;
    if (g_sendq_tail)
        g_sendq_tail->next = chunk;
    else
        g_sendq_head = chunk;
    g_sendq_tail = chunk;
    g_sendq_bytes += chunk->len;
    pthread_cond_signal(&g_sendq_cond);
    pthread_mutex_unlock(&g_sendq_lock);

    return count;
}

/* ------------------------------------------------------------------ */
/* Physical key reports (CSI = 1 h / CSI = 2 h)                        */
/* ------------------------------------------------------------------ */
/* Ported from the Windows bridge (TERMinator-Windows/native/syncterm_bridge.c, same section), which follows upstream
 * SyncTERM (sbbs ee025717 "Add physical key event reporting": cterm.c cterm_pk_*, cg_events.m, key.c).  A door sends
 * CSI = 1 h to get CSI = Pk K on every physical key press and CSI = Pk k on every release (Pk = Linux evdev code),
 * and CSI = 2 h to stop the normal typed bytes.  Doors built on termgfx (SyncDoom, SyncDuke, ...) turn it on when our
 * CSI < c reply lists capability 8, which the cterm fork adds once key_event_mode_change is set.
 *
 * cterm keeps the mode flags; g_key_modes mirrors them after every cterm_write so the UI thread can read them without
 * g_lock (held for the whole of a large frame, and g_cterm is re-created on resize / font change).  The Swift side
 * (Services/PhysicalKeys.swift) maps NSEvent keyCodes to evdev itself and calls native_key_event; it drops its own
 * typed bytes while bit 1 is set.  Windows: CRITICAL_SECTION -> pthread mutex, InterlockedExchange -> C11-style
 * atomics, and native_key_event takes the evdev code directly (no win32 scancode table). */

#define PK_MAX_EVDEV 1024
static pthread_mutex_t g_pk_lock = PTHREAD_MUTEX_INITIALIZER;
static int g_key_modes = 0;                        /* bit 0: CSI = 1 h, bit 1: CSI = 2 h; atomic */
static uint8_t g_pk_reported[PK_MAX_EVDEV / 8];    /* keys whose press the board was sent; guarded by g_pk_lock */

static void keyev_clear_reported(void) {
    pthread_mutex_lock(&g_pk_lock);
    memset(g_pk_reported, 0, sizeof(g_pk_reported));
    pthread_mutex_unlock(&g_pk_lock);
}

/* CSI = 1 h / l, called from inside cterm_write.  Either way the remembered key state starts clean: upstream clears
 * it on disable, and the settle window in termgfx expects no stale presses on enable. */
static void keyev_mode_change(int enable, void *cbdata) {
    (void)enable;
    (void)cbdata;
    keyev_clear_reported();
}

static void keyev_attach(struct cterminal *cterm) {
    if (cterm && cterm->key_event_mode_change != keyev_mode_change) {
        cterm->key_event_mode_change = keyev_mode_change;
        cterm->key_event_mode_change_cbdata = NULL;
    }
}

static void keyev_sync_modes(struct cterminal *cterm) {
    int modes = 0;
    if (cterm) {
        if (cterm->pk_mode)
            modes |= 1;
        if (cterm->suppress_translated_keys)
            modes |= 2;
    }
    __atomic_store_n(&g_key_modes, modes, __ATOMIC_SEQ_CST);
}

static void keyev_reset(void) {
    __atomic_store_n(&g_key_modes, 0, __ATOMIC_SEQ_CST);
    keyev_clear_reported();
}

/* Sends CSI = Pk[;Pk...] K|k for the listed keys; caller holds g_pk_lock so reports go out in edge order */
static void keyev_emit_locked(const uint16_t *keys, size_t count, int pressed) {
    char buf[1024];
    size_t pos;

    if (count == 0 || !g_connected)
        return;
    pos = (size_t)snprintf(buf, sizeof(buf), "\x1b[=");
    for (size_t i = 0; i < count; i++) {
        int n = snprintf(buf + pos, sizeof(buf) - pos, "%s%u", i == 0 ? "" : ";", (unsigned)keys[i]);
        if (n < 0 || (size_t)n >= sizeof(buf) - pos)
            return;
        pos += (size_t)n;
    }
    if (pos + 1 >= sizeof(buf))
        return;
    buf[pos++] = pressed ? 'K' : 'k';
    if (conn_send(buf, pos, 1000) > 0)
        __atomic_fetch_add(&g_bytes_sent, (uint64_t)pos, __ATOMIC_RELAXED);
}

/* Current key modes: bit 0 = physical key reports on, bit 1 = typed bytes suppressed.  0 when not connected. */
int32_t native_get_key_modes(void) {
    return g_connected ? (int32_t)__atomic_load_n(&g_key_modes, __ATOMIC_SEQ_CST) : 0;
}

/* One physical key edge as a Linux evdev code (pressed = 1 down, 0 up).  Auto-repeat downs and releases of keys the
 * board never saw pressed are dropped.  Returns 1 when a report was sent. */
int32_t native_key_event(int32_t evdev_code, int32_t pressed) {
    uint16_t evdev;
    int was;

    if (!g_connected || !(__atomic_load_n(&g_key_modes, __ATOMIC_SEQ_CST) & 1))
        return 0;
    if (evdev_code <= 0 || evdev_code >= PK_MAX_EVDEV)
        return 0;
    evdev = (uint16_t)evdev_code;

    pthread_mutex_lock(&g_pk_lock);
    was = (g_pk_reported[evdev / 8] & (1 << (evdev % 8))) != 0;
    if (was == (pressed != 0)) {
        pthread_mutex_unlock(&g_pk_lock);
        return 0;
    }
    if (pressed)
        g_pk_reported[evdev / 8] |= (uint8_t)(1 << (evdev % 8));
    else
        g_pk_reported[evdev / 8] &= (uint8_t)~(1 << (evdev % 8));
    keyev_emit_locked(&evdev, 1, pressed);
    pthread_mutex_unlock(&g_pk_lock);
    return 1;
}

/* Focus left the terminal: report every key the board still thinks is held as released, in one sequence
 * (upstream's ciokey_focus_lost + cterm_pk_resync).  Otherwise a Cmd-Tab mid-game leaves the player running. */
void native_key_release_all(void) {
    uint16_t batch[64];
    size_t count = 0;
    int reporting = __atomic_load_n(&g_key_modes, __ATOMIC_SEQ_CST) & 1;

    pthread_mutex_lock(&g_pk_lock);
    for (uint16_t evdev = 0; evdev < PK_MAX_EVDEV; evdev++) {
        if (!(g_pk_reported[evdev / 8] & (1 << (evdev % 8))))
            continue;
        g_pk_reported[evdev / 8] &= (uint8_t)~(1 << (evdev % 8));
        batch[count++] = evdev;
        if (count == sizeof(batch) / sizeof(batch[0])) {
            if (reporting)
                keyev_emit_locked(batch, count, 0);
            count = 0;
        }
    }
    if (count > 0 && reporting)
        keyev_emit_locked(batch, count, 0);
    pthread_mutex_unlock(&g_pk_lock);
}

int32_t native_send_key(int32_t keyCode) {
    if (!g_connected) {
        return -1;
    }

    unsigned char c = (unsigned char)keyCode;
    int sent = conn_send(&c, 1, 1000);
    if (sent > 0) {
        pthread_mutex_lock(&g_lock);
        g_bytes_sent += sent;
        pthread_mutex_unlock(&g_lock);
    }
    return (int32_t)sent;
}

int32_t native_send_string(const char *str) {
    if (!g_connected || !str) {
        return -1;
    }

    size_t len = strlen(str);
    int sent = conn_send(str, len, 1000);
    if (sent > 0) {
        pthread_mutex_lock(&g_lock);
        g_bytes_sent += sent;
        pthread_mutex_unlock(&g_lock);
    }
    return (int32_t)sent;
}

// Speed emulation vs. terminal detection. Boards detect ANSI by sending a query (CSI 6 n, CSI c ...) and waiting a
// second or two for the reply. On a real line, everything before the query had already reached the caller when the
// board sent it. Here the network delivers it all at once and the meter holds it back, so a query queued behind a
// screenful of text was answered seconds late and boards (Mystic, for one) fell back to no graphics. So when a
// complete query is waiting in the queue, everything up to and including it is delivered at once: the reply goes out
// on time, and after whatever came before it (a CPR still reports the right cursor position).
//
// Scans the queued raw bytes (for telnet these still carry IAC doubling, which never touches an escape sequence) and
// returns how many to deliver so every complete query in the look-ahead window is answered, or 0 for none.
// Caller holds g_lock.
static size_t find_pending_query_end(void) {
    pthread_mutex_lock(&conn_inbuf.mutex);
    size_t waiting = conn_buf_bytes(&conn_inbuf);
    if (waiting == g_query_scan_waiting) {
        // Nothing new since a scan that found no query
        pthread_mutex_unlock(&conn_inbuf.mutex);
        return 0;
    }
    size_t n = conn_buf_peek(&conn_inbuf, g_query_peek, sizeof(g_query_peek));
    pthread_mutex_unlock(&conn_inbuf.mutex);

    size_t end = 0;
    for (size_t i = 0; i < n; i++) {
        unsigned char c = g_query_peek[i];
        if (c == 0x05) {
            end = i + 1;  // ENQ: answerback
            continue;
        }
        if (c != 0x1b || i + 1 >= n) {
            continue;
        }
        unsigned char kind = g_query_peek[i + 1];
        if (kind == '[') {
            // CSI: parameters, intermediates, final byte
            size_t j = i + 2;
            bool dollar = false;
            while (j < n && g_query_peek[j] >= 0x30 && g_query_peek[j] <= 0x3f) {
                j++;
            }
            while (j < n && g_query_peek[j] >= 0x20 && g_query_peek[j] <= 0x2f) {
                if (g_query_peek[j] == '$') {
                    dollar = true;
                }
                j++;
            }
            if (j >= n) {
                break;  // the rest of it hasn't arrived yet
            }
            unsigned char final = g_query_peek[j];
            // n: DSR / CPR (incl. SyncTERM's CSI = n)   c: device attributes   t: window reports   $p: DECRQM
            if (final == 'n' || final == 'c' || final == 't' || (final == 'p' && dollar)) {
                end = j + 1;
            }
            i = j;
        } else if (kind == '_' || kind == ']' || kind == 'P') {
            // APC / OSC / DCS strings (SyncTERM and xterm queries live here), ended by ST or BEL
            size_t j = i + 2;
            while (j < n && g_query_peek[j] != 0x07
                   && !(g_query_peek[j] == 0x1b && j + 1 < n && g_query_peek[j + 1] == '\\')) {
                j++;
            }
            if (j >= n) {
                break;
            }
            end = g_query_peek[j] == 0x07 ? j + 1 : j + 2;
            i = end - 1;
        }
    }

    if (end == 0) {
        g_query_scan_waiting = waiting;
    }
    return end;
}

/* What cterm answered while the received text went through it (terminal queries), and any speed the board set. */
struct terminal_feed {
    char   ret[1024];
    size_t ret_len;
    int    speed;
};

static const char *current_font_bitmap(int *height);

/* Queue one reply behind whatever cterm answered earlier in this feed (see feed_terminal). */
static void feed_reply(struct terminal_feed *feed, const char *reply, size_t len)
{
    if (feed->ret_len + len > sizeof(feed->ret)) {
        /* A run of queries in one read: send what we have and carry on, rather than lose the rest */
        if (feed->ret_len > 0 && conn_send(feed->ret, feed->ret_len, 1000) > 0)
            g_bytes_sent += feed->ret_len;
        feed->ret_len = 0;
    }
    if (len <= sizeof(feed->ret)) {
        memcpy(feed->ret + feed->ret_len, reply, len);
        feed->ret_len += len;
    }
}

/* XTWINOPS size reports. cterm's CSI t is only SyncTERM's 24-bit colour form, so ESC[14t (text
 * area in pixels), ESC[16t (cell size in pixels) and ESC[18t (text area in cells) are never
 * answered there, and Rainwire asks for the first two at login to size its pictures (it falls
 * back to 8x16 without them). Answered here from the cell the renderer really draws: 8 wide and
 * the current font's height. The scan state carries over between feeds, as a query can arrive
 * split across two reads. */
static struct {
    int  state;        /* 0 = text, 1 = after ESC, 2 = inside CSI */
    bool plain;        /* the CSI so far is digits only (no private prefix, intermediates or ';') */
    char params[4];
    int  len;
} g_winop_scan;

static void answer_winops(struct terminal_feed *feed, const char *text, size_t len)
{
    if (g_emulation != CTERM_EMULATION_ANSI_BBS)
        return;   /* ESC is not a control introducer in PETSCII */
    for (size_t i = 0; i < len; i++) {
        unsigned char c = (unsigned char)text[i];
        if (c == 0x1b) {
            g_winop_scan.state = 1;
            continue;
        }
        if (g_winop_scan.state == 1) {
            g_winop_scan.state = (c == '[') ? 2 : 0;
            g_winop_scan.plain = true;
            g_winop_scan.len = 0;
            continue;
        }
        if (g_winop_scan.state != 2 || c < 0x20)
            continue;
        if (c < 0x40) {
            if (c >= '0' && c <= '9' && g_winop_scan.len < (int)sizeof(g_winop_scan.params) - 1)
                g_winop_scan.params[g_winop_scan.len++] = (char)c;
            else
                g_winop_scan.plain = false;
            continue;
        }
        g_winop_scan.state = 0;
        if (c != 't' || !g_winop_scan.plain || !g_cterm)
            continue;
        g_winop_scan.params[g_winop_scan.len] = 0;

        int op = atoi(g_winop_scan.params);
        int cell_h = 16;
        current_font_bitmap(&cell_h);
        char reply[48];
        int n = 0;
        switch (op) {
            case 14: n = snprintf(reply, sizeof(reply), "\x1b[4;%d;%dt", g_cterm->height * cell_h, g_cterm->width * 8); break;
            case 16: n = snprintf(reply, sizeof(reply), "\x1b[6;%d;%dt", cell_h, 8); break;
            case 18: n = snprintf(reply, sizeof(reply), "\x1b[8;%d;%dt", g_cterm->height, g_cterm->width); break;
            default: break;
        }
        if (n > 0 && n < (int)sizeof(reply))
            feed_reply(feed, reply, (size_t)n);
    }
}

/* trace_stream_feed's text callback: a run of ordinary received bytes, through the terminal emulator.
 * (g_lock is held throughout, as it is for the cterm_write this replaces.) */
static void feed_terminal(const char *text, size_t len, void *ctx)
{
    struct terminal_feed *feed = (struct terminal_feed *)ctx;
    char retbuf[256];
    int speed = -1;
    size_t ret_len;


    for (size_t i = 0; i < len; i++) {
        if (text[i] == 0x07) {
            g_bell_detected = 1;   /* (a TRACE binary frame never gets here, so its bytes can't ring the bell) */
            break;
        }
    }
    memset(retbuf, 0, sizeof(retbuf));
    ret_len = cterm_write(g_cterm, text, len, retbuf, sizeof(retbuf), &speed);
    if (speed >= 0)
        feed->speed = speed;
    if (ret_len > 0)
        feed_reply(feed, retbuf, ret_len);
    /* After cterm_write, so a font switched earlier in the same text is the one reported */
    answer_winops(feed, text, len);
}

int32_t native_process_data(void) {
    pthread_mutex_lock(&g_lock);

    if (!g_connected || !g_cterm) {
        pthread_mutex_unlock(&g_lock);
        return 0;
    }

    // Check if ZMODEM already detected or upload ready (file picker open)
    pthread_mutex_lock(&g_zmodem_lock);
    if (g_zmodem_detected) {
        pthread_mutex_unlock(&g_zmodem_lock);
        pthread_mutex_unlock(&g_lock);
        return -100;
    }
    if (g_zmodem_upload_ready) {
        pthread_mutex_unlock(&g_zmodem_lock);
        pthread_mutex_unlock(&g_lock);
        return 0;  // Don't consume data; upload handler already shown
    }
    pthread_mutex_unlock(&g_zmodem_lock);

    size_t waiting = conn_data_waiting();

    if (waiting == 0) {
        pthread_mutex_unlock(&g_lock);
        return 0;
    }

    unsigned char buffer[4096];
    size_t max_read = sizeof(buffer);

    // Modem speed emulation: deliver only the characters the emulated line has carried since the last call
    // (10 bits per character). The rest stays queued in the connection buffer, the way a real line holds it back.
    // The credit is capped at ~50 ms of data so a burst after a quiet spell doesn't blast out at once. -102 tells
    // the poll loop that data is waiting on the meter.
    int bps = g_emulated_bps > 0 ? (int)g_emulated_bps : (int)g_host_bps;
    bool query_flush = false;
    if (bps > 0) {
        int64_t now = get_current_time_ms();
        double cps = bps / 10.0;
        if (g_bps_last_ms == 0 || now < g_bps_last_ms) {
            g_bps_last_ms = now;
        }
        g_bps_credit += (double)(now - g_bps_last_ms) * cps / 1000.0;
        g_bps_last_ms = now;
        double cap = cps * 0.05;
        if (cap < 1.0) {
            cap = 1.0;
        }
        if (g_bps_credit > cap) {
            g_bps_credit = cap;
        }

        size_t query_end = find_pending_query_end();
        if (query_end > 0) {
            // A terminal query is waiting: deliver through it now, unmetered (see find_pending_query_end)
            query_flush = true;
            extern struct conn_api conn_api;
            max_read = query_end;
            if (conn_api.rx_parse_cb != NULL) {
                max_read *= 2;  // conn_recv_upto takes half the requested size in raw bytes when it has to expand
            }
            if (max_read > sizeof(buffer) - 16) {
                max_read = sizeof(buffer) - 16;
            }
        } else {
            if (g_bps_credit < 1.0) {
                pthread_mutex_unlock(&g_lock);
                return -102;
            }
            max_read = (size_t)g_bps_credit;
            if (max_read > sizeof(buffer) - 16) {
                max_read = sizeof(buffer) - 16;  // leaves room to finish a ZMODEM header, below
            }
        }
    } else {
        g_bps_credit = 0;
        g_bps_last_ms = 0;
    }

    int len = conn_recv_upto(buffer, max_read, 0);

    if (len <= 0) {
        pthread_mutex_unlock(&g_lock);
        return len;
    }

    if (bps > 0) {
        if (!query_flush) {
            g_bps_credit -= len;
        }
        g_query_scan_waiting = (size_t)-1;  // the queue moved: look again next time

        // ZMODEM detection needs ZDLE and the header type in the same buffer, with the ZPADs before them. A
        // metered read can stop in the middle of that, and the transfer would never auto-start. When the chunk
        // ends in a possible header start, pull the rest of the header in unmetered.
        int tail_start = len > 3 ? len - 3 : 0;
        for (int i = tail_start; i < len; i++) {
            if ((buffer[i] == 0x2a || buffer[i] == 0x18) && conn_data_waiting() > 0) {
                int extra = conn_recv_upto(buffer + len, 16, 0);
                if (extra > 0) {
                    len += extra;
                }
                break;
            }
        }
    }

    g_bytes_received += len;  // Protected by g_lock

    // Log data if enabled
    if (g_logging_enabled) {
        pthread_mutex_lock(&g_log_lock);
        int space = LOG_BUFFER_SIZE - g_log_buffer_len;
        int to_copy = (len < space) ? len : space;
        if (to_copy > 0) {
            memcpy(g_log_buffer + g_log_buffer_len, buffer, to_copy);
            g_log_buffer_len += to_copy;
        }
        pthread_mutex_unlock(&g_log_lock);
    }

    // Cross-buffer ZMODEM detection: check if previous read ended with ZDLE
    // and this read starts with a header type byte
    if (g_has_prev_byte && g_prev_last_byte == 0x18 && len >= 1 && is_zmodem_header_type(buffer[0])) {
        // ZMODEM header split across reads: ZDLE was last byte of previous read
        // The ZDLE was already sent to terminal (unavoidable), but we catch the rest here
        (void)0;  // Start from beginning of this buffer

        // Save ZMODEM data (prepend the ZDLE we missed)
        pthread_mutex_lock(&g_zmodem_lock);
        g_zmodem_buffer[0] = 0x18;  // ZDLE from previous read
        g_zmodem_buffer_len = len + 1;
        if (g_zmodem_buffer_len > (int)sizeof(g_zmodem_buffer)) {
            g_zmodem_buffer_len = sizeof(g_zmodem_buffer);
        }
        memcpy(g_zmodem_buffer + 1, buffer, g_zmodem_buffer_len - 1);

        // Determine frame type from the reconstructed header
        int frame_type = -1;
        if (is_hex_header(buffer[0]) && len >= 3) {
            char hex[3] = { buffer[1], buffer[2], 0 };
            frame_type = (int)strtol(hex, NULL, 16);
        } else if (!is_hex_header(buffer[0]) && len >= 2) {
            frame_type = buffer[1];
        }

        g_has_prev_byte = 0;

        if (frame_type == ZMODEM_FRAME_ZRINIT) {
            g_zmodem_upload_ready = 1;
            g_zmodem_detected = 0;
            pthread_mutex_unlock(&g_zmodem_lock);
            pthread_mutex_unlock(&g_lock);
            return -101;
        } else {
            g_zmodem_detected = 1;
            g_zmodem_upload_ready = 0;
            pthread_mutex_unlock(&g_zmodem_lock);
            pthread_mutex_unlock(&g_lock);
            return -100;
        }
    }

    // Check for ZMODEM in this buffer
    zmodem_detect_result_t zmodem_result = detect_zmodem_ex(buffer, len);
    if (zmodem_result.position >= 0 && zmodem_result.position < len) {
        int zmodem_pos = zmodem_result.position;

        // Process data before ZMODEM (through the TRACE filter, like the normal path: a binary frame that ended
        // just before a transfer started must not reach cterm as stray bytes)
        if (zmodem_pos > 0) {
            struct terminal_feed feed;
            feed.ret_len = 0;
            feed.speed = -1;
            macos_apc_attach(g_cterm);
            keyev_attach(g_cterm);
            mouse_bridge_attach(g_cterm);
            trace_stream_feed((const char *)buffer, (size_t)zmodem_pos, feed_terminal, &feed);
            keyev_sync_modes(g_cterm);
            if (feed.speed >= 0) {
                g_host_bps = feed.speed;  // the board set its own speed (CSI * r)
            }
            if (feed.ret_len > 0 && conn_send(feed.ret, feed.ret_len, 1000) > 0) {
                g_bytes_sent += feed.ret_len;  // g_lock is held here
            }
        }

        // Save ZMODEM data
        pthread_mutex_lock(&g_zmodem_lock);
        g_zmodem_buffer_len = len - zmodem_pos;
        if (g_zmodem_buffer_len > (int)sizeof(g_zmodem_buffer)) {
            g_zmodem_buffer_len = sizeof(g_zmodem_buffer);
        }
        memcpy(g_zmodem_buffer, buffer + zmodem_pos, g_zmodem_buffer_len);

        if (zmodem_result.frame_type == ZMODEM_FRAME_ZRINIT) {
            g_zmodem_upload_ready = 1;
            g_zmodem_detected = 0;
            pthread_mutex_unlock(&g_zmodem_lock);
            pthread_mutex_unlock(&g_lock);
            return -101;
        } else {
            g_zmodem_detected = 1;
            g_zmodem_upload_ready = 0;
            pthread_mutex_unlock(&g_zmodem_lock);
            pthread_mutex_unlock(&g_lock);
            return -100;
        }
    }

    // Process through terminal. TRACE binary frames come out first (Bridge/apc/trace_bridge.c): cterm would drop
    // them (it only takes printable text inside an APC), so the filter queues them for the app and hands the text
    // around them to feed_terminal() in order -- which is also where the BEL scan now lives, so a frame's bytes
    // can't ring the bell.
    struct terminal_feed feed;
    feed.ret_len = 0;
    feed.speed = -1;
    macos_apc_attach(g_cterm);   /* SyncTERM:... APCs (cache, JXL images, audio) -- Bridge/apc/apc_bridge.c */
    keyev_attach(g_cterm);       /* CSI = 1 h physical key reports -- see above native_send_key */
    mouse_bridge_attach(g_cterm);  /* CSI ? 1000 h mouse reports -- Bridge/mouse_bridge.c */
    trace_stream_feed((const char *)buffer, (size_t)len, feed_terminal, &feed);
    keyev_sync_modes(g_cterm);
    if (feed.speed >= 0) {
        g_host_bps = feed.speed;  // the board set its own speed (CSI * r)
    }
    macos_apc_poll();

    char *retbuf = feed.ret;
    size_t ret_len = feed.ret_len;

    pthread_mutex_unlock(&g_lock);

    if (ret_len > 0) {
        int sent = conn_send(retbuf, ret_len, 1000);
        if (sent > 0) {
            pthread_mutex_lock(&g_lock);
            g_bytes_sent += sent;
            pthread_mutex_unlock(&g_lock);
        }
    }

    return len;
}

int32_t native_data_waiting(void) {
    if (!g_connected) {
        return 0;
    }
    return (int32_t)conn_data_waiting();
}

// ============================================================================
// MARK: - Screen State Functions
// ============================================================================

// Static buffers for screen data (returned to Swift)
/* Largest screen the app offers: 132x60 (BBSEntry.mode132x60). This was 132*50, so a 132x60 session got a NULL
 * screen from native_get_screen_buffer (7920 cells > 6600) and drew nothing. Windows/Linux size their buffers from
 * the live screen instead. Keep NativeBridge.maxScreenBufferCount in step with this. */
#define MAX_SCREEN_CELLS (132 * 60)

static int32_t g_screen_buffer_cache[MAX_SCREEN_CELLS];
/* True colour, per cell, in lockstep with g_screen_buffer_cache: 0xFFRRGGBB (ready for the renderer's BGRA
 * pixels) when the cell carries a literal 24-bit colour (ESC[38;2;R;G;Bm / 48;2), 0 when it doesn't. 0 means "use
 * the packed palette index exactly as before", so only real RGB cells change -- an RGB black is 0xFF000000, not 0.
 * Windows/Linux resolve every cell to RGB natively (cell_colour_rgb); macOS keeps its renderer's palette, default
 * palette and blink handling for indexed cells, so it only needs the override. */
static int32_t g_screen_fg_rgb_cache[MAX_SCREEN_CELLS];
static int32_t g_screen_bg_rgb_cache[MAX_SCREEN_CELLS];
static int32_t g_palette_cache[16];

/// Convert an RGB color (0x00RRGGBB) to the closest 16-color palette index.
/// Uses squared Euclidean distance in RGB space.
static unsigned int rgb_to_palette_index(uint32_t rgb, const uint32_t *palette) {
    int best = 0;
    int bestDist = 0x7FFFFFFF;
    int r = (rgb >> 16) & 0xFF;
    int g = (rgb >> 8) & 0xFF;
    int b = rgb & 0xFF;

    for (int i = 0; i < 16; i++) {
        int pr = (palette[i] >> 16) & 0xFF;
        int pg = (palette[i] >> 8) & 0xFF;
        int pb = palette[i] & 0xFF;
        int dr = r - pr;
        int dg = g - pg;
        int db = b - pb;
        int dist = dr*dr + dg*dg + db*db;
        if (dist < bestDist) {
            bestDist = dist;
            best = i;
        }
        if (dist == 0) break;  // Exact match
    }
    return (unsigned int)best;
}

/* A cell's RGB override (g_screen_fg_rgb_cache): its literal 24-bit colour, or for a 256-colour cell (ESC[38;5;Nm,
 * stored as palette entry N + 16) the palette's colour now, so OSC 4 changes show -- Rainwire pulses "NEW" by
 * re-colouring a slot, as Windows draws it (cell_colour_rgb). 0 for the 16 attribute colours: the renderer's own. */
static int32_t cell_rgb_override(uint32_t raw, const uint32_t *palette) {
    if (raw & 0x80000000u)
        return (int32_t)(0xFF000000u | (raw & 0x00FFFFFFu));
    if (palette && raw >= 16 && raw < 65536)
        return (int32_t)(0xFF000000u | (palette[raw] & 0x00FFFFFFu));
    return 0;
}

/* What attribute bit 7 means right now, from the ciolib video flags cterm keeps (CSI ?33h iCE
 * colours = BGBRIGHT, CSI ?34h = NOBLINK) plus the explicit Commodore modes, which are
 * BGBRIGHT|NOBLINK (see the PETSCII note in native_get_screen_buffer). Only ATTR7_BLINK leaves
 * the bit in the packed attribute for the renderer to blink on; ATTR7_BRIGHT_BG keeps the
 * background 8-15 steady, ATTR7_NONE drops the bit's brightness as well (bitmap_con.c).
 * Lock-free reads, so it is safe inside macos_ciolib_lock(). */
enum { ATTR7_BLINK, ATTR7_BRIGHT_BG, ATTR7_NONE };

static int attr_bit7_meaning(void) {
    int flags = macos_ciolib_get_video_flags();
    if (macos_ciolib_mode_no_blink())
        flags |= CIOLIB_VIDEO_BGBRIGHT | CIOLIB_VIDEO_NOBLINK;
    if (flags & CIOLIB_VIDEO_BGBRIGHT)
        return ATTR7_BRIGHT_BG;
    if (flags & CIOLIB_VIDEO_NOBLINK)
        return ATTR7_NONE;
    return ATTR7_BLINK;
}

const int32_t* native_get_screen_buffer(int32_t *count) {
    pthread_mutex_lock(&g_lock);

    macos_ciolib_lock();

    int width = macos_ciolib_get_screen_width();
    int height = macos_ciolib_get_screen_height();
    int size = width * height;

    if (size <= 0 || size > MAX_SCREEN_CELLS) {
        macos_ciolib_unlock();
        pthread_mutex_unlock(&g_lock);
        *count = 0;
        return NULL;
    }

    struct vmem_cell *screen = macos_ciolib_get_screen_buffer();
    if (!screen) {
        macos_ciolib_unlock();
        pthread_mutex_unlock(&g_lock);
        *count = 0;
        return NULL;
    }

    // Get current palette for RGB-to-palette conversion
    uint32_t *current_palette = macos_ciolib_get_palette();

    /* ⚠️ macOS PETSCII 2026-09-04 — BRIGHT-BACKGROUND MODES: attribute bit 7 is NOT blink.
     *
     * `set_bright_bg` in cterm.c deliberately sets attr bit 7 in any CIOLIB_VIDEO_BGBRIGHT
     * mode to mean "background colour 8-15", and the Commodore modes are BGBRIGHT|NOBLINK.
     * Treating that bit as the ANSI blink attribute does two visible things on a PETSCII
     * board: every reverse-video cell flickers in step with the text-blink timer (and most
     * PETSCII artwork IS reverse-video blocks), and the background gets masked down to 0-7
     * so the colours come out plain wrong. In a NOBLINK mode we therefore keep the bright
     * background AND strip the bit from the packed attribute. */
    const int attr7 = attr_bit7_meaning();
    const unsigned int blink_bit = (attr7 == ATTR7_BLINK) ? 0x80u : 0u;

    // Pack cell data
    // Note: vmem_cell.fg/bg are uint32_t:
    //   - If high bit (0x80000000) clear: palette index in low bits
    //   - If high bit set: direct RGB color (0x80RRGGBB)
    for (int i = 0; i < size; i++) {
        unsigned int ch = screen[i].ch & 0xFF;
        unsigned int attr = screen[i].legacy_attr & 0xFF;

        // ⚠️ The "puttext leaves fg/bg at 0" claim that used to be here was WRONG: clrscr()
        // and putch() write fg_color/bg_color into every cell they touch, so a puttext() cell
        // that did not set them kept a STALE colour, and the fg_raw != 0 branch below then used
        // it. puttext() now derives fg/bg from the attribute byte, so the branches agree and the
        // legacy_attr fallback is only a backstop.
        uint32_t fg_raw = screen[i].fg;
        uint32_t bg_raw = screen[i].bg;
        unsigned int fg, bg;

        // Check if vmem_cell.fg/bg were actually populated (non-zero or RGB mode)
        if ((fg_raw & 0x80000000) && current_palette) {
            // Direct RGB color - convert to closest palette index
            fg = rgb_to_palette_index(fg_raw & 0x00FFFFFF, current_palette);
        } else if (fg_raw != 0 && !(fg_raw & 0xFF000000)) {
            // Non-zero palette index with no flag bits in upper byte
            fg = fg_raw & 0x0F;
        } else {
            // Use legacy_attr as canonical source (always set by both code paths)
            fg = attr & 0x0F;
        }

        if ((bg_raw & 0x80000000) && current_palette) {
            // Direct RGB color - convert to closest palette index
            bg = rgb_to_palette_index(bg_raw & 0x00FFFFFF, current_palette);
        } else if (bg_raw != 0 && !(bg_raw & 0xFF000000)) {
            // Non-zero palette index with no flag bits in upper byte
            bg = bg_raw & 0x0F;
        } else {
            // Use legacy_attr as canonical source (always set by both code paths)
            bg = (attr >> 4) & 0x0F;
        }
        if (attr7 == ATTR7_NONE && !(bg_raw & 0x80000000))
            bg &= 0x07u;   // CSI ?34h without iCE: bit 7 neither blinks nor brightens

        fg &= 0x7Fu; // Mask to 7 bits so color values don't collide with underline bit
        if (screen[i].flags & VMEM_FLAG_UNDERLINE)
            fg |= 0x80u;
        /* macOS PETSCII 2026-09-04 — see blink_bit above: strip attribute bit 7 in a
           NOBLINK mode (and with iCE colours on, see attr_bit7_meaning) so the renderer
           cannot read it as the ANSI blink attribute. */
        g_screen_buffer_cache[i] = (int32_t)(ch | ((attr & ~(0x80u ^ blink_bit)) << 8)
                                                | (fg << 16) | (bg << 24));

        /* True colour: the real 24-bit value instead of the nearest-of-16 above. */
        g_screen_fg_rgb_cache[i] = cell_rgb_override(fg_raw, current_palette);
        g_screen_bg_rgb_cache[i] = cell_rgb_override(bg_raw, current_palette);
    }

    macos_ciolib_clear_dirty();
    macos_ciolib_unlock();
    pthread_mutex_unlock(&g_lock);

    *count = size;
    return g_screen_buffer_cache;
}

/* True-colour variant: the same packed cells, plus the per-cell RGB overrides (see g_screen_fg_rgb_cache) filled in
 * the same locked pass, so all three describe one frame and the dirty flag is cleared once. fg/bg are NULL whenever
 * the cells are. */
const int32_t* native_get_screen_buffer_rgb(int32_t *count, const int32_t **fg, const int32_t **bg) {
    const int32_t *cells = native_get_screen_buffer(count);
    if (fg) *fg = cells ? g_screen_fg_rgb_cache : NULL;
    if (bg) *bg = cells ? g_screen_bg_rgb_cache : NULL;
    return cells;
}

/* macOS PETSCII 2026-09-04
 * Does the active video mode treat attribute bit 7 as BACKGROUND BRIGHTNESS rather than the
 * ANSI blink attribute? True for the Commodore modes (BGBRIGHT|NOBLINK). The renderer must
 * gate its blink handling on this or every reverse-video cell on a PETSCII screen flickers. */
bool native_mode_no_blink(void) {
    return macos_ciolib_mode_no_blink() ? true : false;
}

/* macOS PETSCII 2026-09-04
 * Pixel aspect for the active mode as [numerator, denominator] — 6:5 for the 40-column
 * Commodore modes (320x200 stretched to 4:3) and 4:3 for C128 80x25. vparams owns these
 * numbers, so the renderer can never drift from the geometry cterm is drawing into.
 * Returns 0,0 when the mode has no forced aspect (ordinary ANSI modes). */
void native_get_display_aspect(int32_t *num, int32_t *den) {
    int n = 0, d = 0;
    pthread_mutex_lock(&g_lock);
    switch (g_screen_mode) {
        case SCREEN_MODE_C64:
        case SCREEN_MODE_C128_40:
            n = 6; d = 5;   // 320x200 stretched to a 4:3 screen
            break;
        case SCREEN_MODE_C128_80:
            n = 4; d = 3;
            break;
        default:
            break;
    }
    pthread_mutex_unlock(&g_lock);
    if (num) *num = n;
    if (den) *den = d;
}

const int32_t* native_get_palette(int32_t *count) {
    macos_ciolib_lock();
    uint32_t *palette = macos_ciolib_get_palette();

    if (!palette) {
        macos_ciolib_unlock();
        *count = 0;
        return NULL;
    }

    for (int i = 0; i < 16; i++) {
        g_palette_cache[i] = (int32_t)palette[i];
    }

    macos_ciolib_unlock();
    *count = 16;
    return g_palette_cache;
}

void native_get_screen_size(int32_t *columns, int32_t *rows) {
    *columns = macos_ciolib_get_screen_width();
    *rows = macos_ciolib_get_screen_height();
}

void native_get_cursor_pos(int32_t *x, int32_t *y) {
    *x = macos_ciolib_get_cursor_x();
    *y = macos_ciolib_get_cursor_y();
}

bool native_is_cursor_visible(void) {
    return macos_ciolib_is_cursor_visible();
}

bool native_cursor_type_changed(void) {
    return macos_ciolib_cursor_type_changed();
}

bool native_is_screen_dirty(void) {
    return macos_ciolib_is_dirty();
}

bool native_get_dirty_region(int32_t *minX, int32_t *minY, int32_t *maxX, int32_t *maxY) {
    macos_ciolib_lock();
    int has_dirty = macos_ciolib_get_dirty_region(minX, minY, maxX, maxY);
    macos_ciolib_unlock();
    return has_dirty;
}

// ============================================================================
// MARK: - Terminal Control Functions
// ============================================================================

void native_set_terminal_size(int32_t width, int32_t height) {
    if (width <= 0 || height <= 0 || width > 1000 || height > 1000) {
        return;
    }

    pthread_mutex_lock(&g_lock);

    if (g_term_width == width && g_term_height == height) {
        pthread_mutex_unlock(&g_lock);
        return;
    }

    g_term_width = width;
    g_term_height = height;

    macos_ciolib_resize(width, height);

    if (g_cterm && g_initialized) {
        struct cterminal *old_cterm = g_cterm;
        g_cterm = NULL;
        cterm_end(old_cterm, 0);

        int scrollback_cols = width > 132 ? width : 132;
        size_t scrollback_size = (size_t)g_scrollback_lines * scrollback_cols * sizeof(struct vmem_cell);

        struct vmem_cell *old_scrollback = g_scrollback;
        g_scrollback = calloc(1, scrollback_size);

        if (g_scrollback) {
            free(old_scrollback);
            g_cterm = cterm_init(height, width, 1, 1,
                                 g_scrollback_lines, scrollback_cols,
                                 g_scrollback, g_emulation);   // macOS PETSCII 2026-09-04
            if (g_cterm) {
                cterm_start(g_cterm);
            }
        } else {
            g_scrollback = old_scrollback;
        }
    }

    pthread_mutex_unlock(&g_lock);
}

bool native_set_font(const char *fontName) {
    if (!g_initialized || !fontName) {
        return false;
    }

    pthread_mutex_lock(&g_lock);

    int font_id = -1;
    for (int i = 0; i < 256; i++) {
        if (conio_fontdata[i].desc != NULL &&
            strcmp(conio_fontdata[i].desc, fontName) == 0) {
            font_id = i;
            break;
        }
    }

    if (font_id >= 0) {
        strncpy(g_font_name, fontName, sizeof(g_font_name) - 1);
        g_current_font_id = font_id;
        int result = ciolib_setfont(font_id, 1, 0);
        /* cterm snapshots getfont(1) into altfont[] at init and re-applies altfont on
           every write, so a cterm created before this call (screen-mode change) would
           keep flipping back to the old font. Keep its primary slot in step.
           ⚠️ Missing here (but present on iOS) since the 2026-09-04 cterm migration:
           resolved_font_id() reads altfont[0], so without this every saved font —
           Topaz included — rendered as CP437. */
        if (result != 0 && g_cterm)
            g_cterm->altfont[0] = font_id;
        pthread_mutex_unlock(&g_lock);
        return result != 0;   /* ciolib setfont: nonzero = success (matches cterm + Windows) */
    }

    pthread_mutex_unlock(&g_lock);
    return false;
}

bool native_set_font_by_id(int32_t fontId) {
    if (!g_initialized || fontId < 0 || fontId >= 256) {
        return false;
    }

    pthread_mutex_lock(&g_lock);
    g_current_font_id = fontId;
    int result = ciolib_setfont(fontId, 1, 0);
    /* Same altfont[0] rule as native_set_font — see resolved_font_id(). */
    if (result != 0 && g_cterm)
        g_cterm->altfont[0] = fontId;
    pthread_mutex_unlock(&g_lock);

    return result != 0;
}

/* macOS PETSCII 2026-09-04
 * Destroy and recreate cterm with fresh state (caller holds g_lock).
 * cterm caches BOTH the emulation and the mode's default attribute at init time,
 * so a screen-mode change has to go through here, not just resize. */
static void recreate_cterm_locked(void) {
    if (!(g_cterm && g_initialized))
        return;

    cterm_end(g_cterm, 0);
    g_cterm = NULL;

    if (g_scrollback) {
        int scrollback_cols = g_term_width > 132 ? g_term_width : 132;
        size_t scrollback_size = (size_t)g_scrollback_lines * scrollback_cols * sizeof(struct vmem_cell);
        if (scrollback_size <= MAX_SCROLLBACK_BYTES) {
            memset(g_scrollback, 0, scrollback_size);
        }
    }

    int scrollback_cols = g_term_width > 132 ? g_term_width : 132;
    g_cterm = cterm_init(g_term_height, g_term_width, 1, 1,
                         g_scrollback_lines, scrollback_cols,
                         g_scrollback, g_emulation);
    if (g_cterm) {
        cterm_start(g_cterm);
    }
}

void native_clear_screen(void) {
    pthread_mutex_lock(&g_lock);
    if (g_cterm && g_initialized) {
        // Destroy old cterm to fully reset terminal state (colors, cursor, modes)
        cterm_end(g_cterm, 0);
        g_cterm = NULL;

        // Clear and reuse existing scrollback buffer
        if (g_scrollback) {
            int scrollback_cols = g_term_width > 132 ? g_term_width : 132;
            size_t scrollback_size = (size_t)g_scrollback_lines * scrollback_cols * sizeof(struct vmem_cell);
            if (scrollback_size <= MAX_SCROLLBACK_BYTES) {
                memset(g_scrollback, 0, scrollback_size);
            }
        }

        // Recreate cterm with fresh state
        int scrollback_cols = g_term_width > 132 ? g_term_width : 132;
        g_cterm = cterm_init(g_term_height, g_term_width, 1, 1,
                             g_scrollback_lines, scrollback_cols,
                             g_scrollback, g_emulation);   // macOS PETSCII 2026-09-04
        if (g_cterm) {
            cterm_start(g_cterm);
        }
    } else if (g_cterm) {
        cterm_clearscreen(g_cterm, 7);
    }
    pthread_mutex_unlock(&g_lock);
}

void native_reset_terminal(void) {
    pthread_mutex_lock(&g_lock);
    if (g_cterm) {
        // Clear the screen
        cterm_clearscreen(g_cterm, 7);

        // Reset scrollback - clear the backfilled count so old data isn't shown
        g_cterm->backfilled = 0;

        // Clear the scrollback buffer itself
        if (g_scrollback) {
            int scrollback_cols = g_term_width > 132 ? g_term_width : 132;
            size_t scrollback_size = (size_t)g_scrollback_lines * scrollback_cols * sizeof(struct vmem_cell);
            memset(g_scrollback, 0, scrollback_size);
        }
    }
    pthread_mutex_unlock(&g_lock);
}

void native_push_input(const uint8_t *data, int32_t count) {
    if (count <= 0) return;
    macos_ciolib_push_input_buffer(data, count);
}

// SSH blank login (call before every connect): true = log in with no credentials and never prompt, for boards that
// log the caller in inside the BBS (Rainwire); a board that wants a password fails with a message saying so.
// false = the username/password given to native_connect, as always. See ssh_blank_login in ssh.c.
void native_set_ssh_blank_login(bool on) {
    pthread_mutex_lock(&g_lock);
    g_ssh_blank_login = on ? 1 : 0;
    pthread_mutex_unlock(&g_lock);
}

void native_set_hide_status_line(bool hide) {
    pthread_mutex_lock(&g_lock);
    g_hide_status_line = hide ? 1 : 0;
    pthread_mutex_unlock(&g_lock);
}

// Declare the Swift bridge function
extern void swift_telnet_set_terminal_size(int width, int height);

// iOS mode indices to native SyncTERM SCREEN_MODE_* enum values
static const int ios_to_native_screen_mode[] = {
    SCREEN_MODE_80X25,   // iOS 0 -> 80x25
    SCREEN_MODE_80X30,   // iOS 1 -> 80x30
    SCREEN_MODE_80X50,   // iOS 2 -> 80x50
    SCREEN_MODE_132X25,  // iOS 3 -> 132x25
    SCREEN_MODE_132X50,  // iOS 4 -> 132x50
    SCREEN_MODE_80X43,   // iOS 5 -> 80x40 (closest: 80x43)
    SCREEN_MODE_132X30,  // iOS 6 -> 132x30
    SCREEN_MODE_132X43,  // iOS 7 -> 132x40 (closest: 132x43)
    SCREEN_MODE_132X60,  // iOS 8 -> 132x60
    // macOS PETSCII 2026-09-04
    SCREEN_MODE_C64,     // 9  -> Commodore 64 40x25 (PETSCII)
    SCREEN_MODE_C128_40, // 10 -> Commodore 128 40x25 (PETSCII)
    SCREEN_MODE_C128_80, // 11 -> Commodore 128 80x25 (PETSCII)
};
#define IOS_SCREEN_MODE_COUNT (sizeof(ios_to_native_screen_mode) / sizeof(ios_to_native_screen_mode[0]))

void native_set_screen_mode(int32_t mode) {
    pthread_mutex_lock(&g_lock);
    if (mode >= 0 && mode < (int)IOS_SCREEN_MODE_COUNT) {
        g_screen_mode = ios_to_native_screen_mode[mode];
    } else {
        g_screen_mode = SCREEN_MODE_80X25;
    }

    /* macOS PETSCII 2026-09-04
     * Derive the cterm emulation and the explicit ciolib video mode from the screen
     * mode, the same way bbslist.c's get_emulation() does upstream. There is no
     * separate emulation setting — PETSCII is what "Commodore screen mode" MEANS.
     *
     * ⚠️ UNCONDITIONAL — do NOT put this behind an "only if the mode changed" test.
     * Nothing resets the native side between connections (native_init early-returns
     * once g_initialized is set), so on a SECOND connection to the same board the
     * emulation and vmode already match and the work would be skipped — cterm would
     * carry the previous session's c64reversemode / attribute / cursor / margins into
     * the new one, which on a PETSCII board draws as corrupt artwork. That exact bug
     * was found on Android 2026-09-04. set_screen_mode is only ever called from the
     * connect path, so applying the mode's starting state every time is right. */
    {
        int emulation = CTERM_EMULATION_ANSI_BBS;
        int vmode = -1;
        switch (g_screen_mode) {
            case SCREEN_MODE_C64:     emulation = CTERM_EMULATION_PETASCII; vmode = C64_40X25;  break;
            case SCREEN_MODE_C128_40: emulation = CTERM_EMULATION_PETASCII; vmode = C128_40X25; break;
            case SCREEN_MODE_C128_80: emulation = CTERM_EMULATION_PETASCII; vmode = C128_80X25; break;
            default: break;
        }
        g_emulation = emulation;
        macos_ciolib_set_video_mode(vmode);

        /* cterm caches emulation and the mode's default attribute at init time */
        recreate_cterm_locked();

        /* Commodore modes START in the Lower (text) character set: C64 terminal
         * programs run in text mode and boards send lowercase ASCII before any
         * PETSCII detection, which is graphics junk in the UPPER set. The BBS
         * switches it itself with 0x0E / 0x8E from here on.
         * ⚠️ altfont[0] must be kept in step — cterm_write reinstalls it on every
         * call, so setting only the ciolib font would be undone immediately. */
        if (emulation == CTERM_EMULATION_PETASCII) {
            int cbm_font = (g_screen_mode == SCREEN_MODE_C64) ? 33 : 35;
            if (ciolib_setfont(cbm_font, 1, 0)) {
                g_current_font_id = cbm_font;
                if (g_cterm)
                    g_cterm->altfont[0] = cbm_font;
            }
        }
    }
    pthread_mutex_unlock(&g_lock);

    // Convert screen mode to dimensions and resize terminal
    int width = 80, height = 25;
    switch (mode) {
        case 0: width = 80;  height = 25; break;
        case 1: width = 80;  height = 30; break;
        case 2: width = 80;  height = 50; break;
        case 3: width = 132; height = 25; break;
        case 4: width = 132; height = 50; break;
        case 5: width = 80;  height = 40; break;
        case 6: width = 132; height = 30; break;
        case 7: width = 132; height = 40; break;
        case 8: width = 132; height = 60; break;
        // macOS PETSCII 2026-09-04
        case 9:  width = 40; height = 25; break;   // C64 40x25
        case 10: width = 40; height = 25; break;   // C128 40x25
        case 11: width = 80; height = 25; break;   // C128 80x25
        default: width = 80; height = 25; break;
    }

    // Resize native terminal buffer
    native_set_terminal_size(width, height);

    // Also update TelnetConnection so NAWS reports correct size
    swift_telnet_set_terminal_size(width, height);
}

// ============================================================================
// MARK: - Status Functions
// ============================================================================

static char g_status_info[256];

const char* native_get_status_info(void) {
    if (!g_initialized) {
        snprintf(g_status_info, sizeof(g_status_info), "Not initialized");
    } else if (!g_connected) {
        snprintf(g_status_info, sizeof(g_status_info), "Disconnected");
    } else {
        snprintf(g_status_info, sizeof(g_status_info), "Connected to %s:%d (%dx%d)",
                 g_bbs_config.addr, g_bbs_config.port,
                 g_term_width, g_term_height);
    }
    return g_status_info;
}

// Modem speed emulation: the user's setting in bps, 0 = full speed (a board's own CSI * r still applies)
void native_set_emulated_bps(int32_t bps) {
    g_emulated_bps = bps > 0 ? bps : 0;
}

// The speed incoming data is actually metered at: the user's setting, else the board's, 0 = full speed
int32_t native_get_effective_bps(void) {
    int user = g_emulated_bps;
    return user > 0 ? user : (int32_t)g_host_bps;
}

bool native_get_connection_stats(int64_t *sent, int64_t *received,
                                  int64_t *connectTime, int64_t *currentTime) {
    pthread_mutex_lock(&g_lock);
    *sent = (int64_t)g_bytes_sent;
    *received = (int64_t)g_bytes_received;
    *connectTime = g_connect_time_ms;
    pthread_mutex_unlock(&g_lock);
    *currentTime = get_current_time_ms();
    return true;
}

// ============================================================================
// MARK: - Font Bitmap Functions
// ============================================================================

/**
 * macOS PETSCII 2026-09-04
 * The font the TERMINAL is using, which is `cterm->altfont[0]` and NOT the live ciolib font.
 *
 * ⚠️ THIS DISTINCTION IS THE WHOLE BUG BEHIND "PETSCII CASE MODE DOES NOTHING".
 * `cterm_write` saves the host's fonts at entry, installs `cterm->altfont[]`, processes the
 * data, and RESTORES the saved fonts before returning. So a font change made *during* the call
 * — which is exactly what the PETSCII 0x0E / 0x8E case-switch does — has already been undone by
 * the time cterm_write returns. Upstream SyncTERM never notices because bitmap_con draws inside
 * that window; we poll from Swift afterwards, so we must read the value that PERSISTS.
 *
 * Caller must hold g_lock.
 */
static int resolved_font_id(void) {
    if (g_cterm) {
        int f = g_cterm->altfont[0];
        if (f >= 0 && f < 256 && conio_fontdata[f].desc != NULL)
            return f;
    }
    return g_current_font_id;
}

int32_t native_get_current_font_id(void) {
    /* macOS PETSCII 2026-09-04: altfont[0], not g_current_font_id — see resolved_font_id(). */
    return resolved_font_id();
}

static uint8_t g_font_bitmap_cache[256 * 16 + 2];  // Max size + header

/* The glyph bitmap the renderer draws with and its height (8 wide, 8/14/16 high), or NULL when
 * not even font 0 has one. Shared by native_get_font_bitmap and the ESC[14t / ESC[16t pixel
 * reports, so a board is told the cell size actually on screen. Caller holds g_lock. */
static const char *current_font_bitmap(int *height) {
    const char *bitmap_data = NULL;
    int font_height = 16;

    // Try current font
    /* macOS PETSCII 2026-09-04: resolved_font_id(), NOT g_current_font_id — cterm_write
       restores the host font before returning, so the PETSCII case switch only survives in
       cterm->altfont[0]. See resolved_font_id(). */
    int font_id = resolved_font_id();

    /* Commodore modes are natively 8x8 (320x200); take that slot first so the picture keeps
       the machine's real geometry instead of the row-doubled 8x16. */
    int mode_h = macos_ciolib_get_mode_char_height();
    if (mode_h == 8 && font_id >= 0 && font_id < 256 &&
        conio_fontdata[font_id].eight_by_eight != NULL) {
        bitmap_data = conio_fontdata[font_id].eight_by_eight;
        font_height = 8;
    } else if (font_id >= 0 && font_id < 256) {
        if (conio_fontdata[font_id].eight_by_sixteen != NULL) {
            bitmap_data = conio_fontdata[font_id].eight_by_sixteen;
            font_height = 16;
        } else if (conio_fontdata[font_id].eight_by_fourteen != NULL) {
            bitmap_data = conio_fontdata[font_id].eight_by_fourteen;
            font_height = 14;
        } else if (conio_fontdata[font_id].eight_by_eight != NULL) {
            bitmap_data = conio_fontdata[font_id].eight_by_eight;
            font_height = 8;
        }
    }

    // Fallback to font 0
    if (bitmap_data == NULL) {
        if (conio_fontdata[0].eight_by_sixteen != NULL) {
            bitmap_data = conio_fontdata[0].eight_by_sixteen;
            font_height = 16;
        }
    }

    *height = font_height;
    return bitmap_data;
}

const uint8_t* native_get_font_bitmap(int32_t *width, int32_t *height, int32_t *count) {
    pthread_mutex_lock(&g_lock);

    int font_height = 16;
    const char *bitmap_data = current_font_bitmap(&font_height);

    if (bitmap_data == NULL) {
        pthread_mutex_unlock(&g_lock);
        *count = 0;
        return NULL;
    }

    int data_size = 256 * font_height;
    int max_data = (int)sizeof(g_font_bitmap_cache) - 2;
    if (data_size > max_data) {
        data_size = max_data;
    }
    g_font_bitmap_cache[0] = 8;
    g_font_bitmap_cache[1] = (uint8_t)font_height;
    memcpy(g_font_bitmap_cache + 2, bitmap_data, data_size);

    /* Update char_pixel_height for sixel scroll calculations */
    macos_ciolib_set_char_pixel_height(font_height);

    *width = 8;
    *height = font_height;
    *count = data_size;

    pthread_mutex_unlock(&g_lock);
    return g_font_bitmap_cache + 2;  // Return pointer past header
}

// ============================================================================
// MARK: - ZMODEM Functions
// ============================================================================

bool native_is_zmodem_detected(void) {
    pthread_mutex_lock(&g_zmodem_lock);
    bool result = g_zmodem_detected;
    pthread_mutex_unlock(&g_zmodem_lock);
    return result;
}

const uint8_t* native_get_zmodem_buffer(int32_t *count) {
    pthread_mutex_lock(&g_zmodem_lock);
    if (g_zmodem_buffer_len <= 0) {
        pthread_mutex_unlock(&g_zmodem_lock);
        *count = 0;
        return NULL;
    }
    *count = g_zmodem_buffer_len;
    pthread_mutex_unlock(&g_zmodem_lock);
    return g_zmodem_buffer;
}

void native_clear_zmodem_detected(void) {
    pthread_mutex_lock(&g_zmodem_lock);
    g_zmodem_detected = 0;
    g_zmodem_upload_ready = 0;
    g_zmodem_buffer_len = 0;
    g_has_prev_byte = 0;
    pthread_mutex_unlock(&g_zmodem_lock);
}

int32_t native_push_zmodem_buffer(void) {
    pthread_mutex_lock(&g_zmodem_lock);

    // Don't push data back - zmodem_recv_init() sends ZRINIT on its own
    // and doesn't need to see the ZRQINIT. Pushing decoded data back into
    // conn_inbuf would cause rx_parse_cb to process it again.
    g_zmodem_buffer_len = 0;
    g_zmodem_detected = 0;
    g_has_prev_byte = 0;
    pthread_mutex_unlock(&g_zmodem_lock);

    // CRITICAL (matches Android's nativePushZmodemBuffer): drain any stale data
    // left in conn_inbuf between ZMODEM detection and the start of the receive
    // (trailing/retransmitted ZRQINIT, terminal output, split frames). If left
    // in place, zmodem_recv_header() reads it first and desyncs, so the
    // ZRINIT/ZFILE handshake never completes. The BBS is waiting for our ZRINIT
    // before sending ZFILE, so nothing important is discarded here.
    #define ZMODEM_MAX_DRAIN_BYTES 4096
    if (conn_data_waiting() > 0) {
        unsigned char drain_buf[256];
        size_t total_drained = 0;
        while (conn_data_waiting() > 0 && total_drained < ZMODEM_MAX_DRAIN_BYTES) {
            int n = conn_recv_upto(drain_buf, sizeof(drain_buf), 10);  // 10ms timeout
            if (n <= 0) break;
            total_drained += (size_t)n;
        }
    }
    #undef ZMODEM_MAX_DRAIN_BYTES

    return 0;
}

// ============================================================================
// MARK: - Upload Queue Functions
// ============================================================================

void native_queue_upload(const char *filePath) {
    if (!filePath) return;
    pthread_mutex_lock(&g_zmodem_lock);
    strncpy(g_upload_queued_file, filePath, sizeof(g_upload_queued_file) - 1);
    g_upload_file_queued = 1;
    pthread_mutex_unlock(&g_zmodem_lock);
}

bool native_is_upload_queued(void) {
    pthread_mutex_lock(&g_zmodem_lock);
    bool result = g_upload_file_queued;
    pthread_mutex_unlock(&g_zmodem_lock);
    return result;
}

bool native_is_upload_ready(void) {
    pthread_mutex_lock(&g_zmodem_lock);
    bool result = g_zmodem_upload_ready;
    pthread_mutex_unlock(&g_zmodem_lock);
    return result;
}

const char* native_get_queued_upload(void) {
    pthread_mutex_lock(&g_zmodem_lock);
    if (g_upload_file_queued && g_upload_queued_file[0] != '\0') {
        pthread_mutex_unlock(&g_zmodem_lock);
        return g_upload_queued_file;
    }
    pthread_mutex_unlock(&g_zmodem_lock);
    return NULL;
}

void native_clear_upload_queue(void) {
    pthread_mutex_lock(&g_zmodem_lock);
    g_upload_file_queued = 0;
    g_upload_queued_file[0] = '\0';
    g_zmodem_upload_ready = 0;
    pthread_mutex_unlock(&g_zmodem_lock);
}

// ============================================================================
// MARK: - Scrollback Functions
// ============================================================================

/// Save one screen line into the cterm scrollback ring buffer.
/// IMPORTANT: Caller must already hold g_lock. The call chain is:
///   native_process_data() [holds g_lock] → cterm_write() → ios_wscroll()
/// so g_lock is always held when this function is reached.
void scrollback_save_line(const struct vmem_cell *line, int width) {
    if (!g_cterm || !g_cterm->scrollback || width <= 0) {
        return;
    }

    int cols = g_cterm->backwidth;
    int cap  = g_cterm->backlines;
    int pos  = g_cterm->backpos;

    if (cols <= 0 || cap <= 0) {
        return;
    }

    // Copy the line into the ring buffer at the current write position
    int copy_cols = (width < cols) ? width : cols;
    struct vmem_cell *dest = g_cterm->scrollback + pos * cols;
    memcpy(dest, line, copy_cols * sizeof(struct vmem_cell));

    // Blank any remaining columns (if screen is narrower than scrollback)
    for (int i = copy_cols; i < cols; i++) {
        dest[i].ch = ' ';
        dest[i].legacy_attr = 7;
        dest[i].fg = 7;
        dest[i].bg = 0;
        dest[i].font = 0;
    }

    // Advance ring position
    g_cterm->backpos = (pos + 1) % cap;
    if (g_cterm->backfilled < cap) {
        g_cterm->backfilled++;
    }
}

bool native_get_scrollback_info(int32_t *filled, int32_t *capacity, int32_t *columns) {
    pthread_mutex_lock(&g_lock);

    if (!g_cterm || !g_cterm->scrollback) {
        pthread_mutex_unlock(&g_lock);
        return false;
    }

    *filled = g_cterm->backfilled;
    *capacity = g_cterm->backlines;
    *columns = g_cterm->backwidth;

    pthread_mutex_unlock(&g_lock);
    return true;
}

static int32_t g_scrollback_cache[132 * 100];  // Cache for scrollback
/* RGB overrides for the scrollback, same contract as g_screen_fg_rgb_cache: history is stored as whole vmem_cells,
 * so it keeps its true colours. */
static int32_t g_scrollback_fg_rgb_cache[132 * 100];
static int32_t g_scrollback_bg_rgb_cache[132 * 100];

const int32_t* native_get_scrollback_buffer(int32_t offset, int32_t count, int32_t *resultCount) {
    pthread_mutex_lock(&g_lock);

    if (!g_cterm || !g_cterm->scrollback || g_cterm->backfilled <= 0) {
        pthread_mutex_unlock(&g_lock);
        *resultCount = 0;
        return NULL;
    }

    int filled = g_cterm->backfilled;
    int capacity = g_cterm->backlines;
    int back_cols = g_cterm->backwidth;   // ring buffer stride (may be 132)
    int screen_cols = g_cterm->width;     // visible screen width (typically 80)
    int backpos = g_cterm->backpos;

    if (offset < 0 || count <= 0 || offset >= filled) {
        pthread_mutex_unlock(&g_lock);
        *resultCount = 0;
        return NULL;
    }

    if (count > filled - offset) {
        count = filled - offset;
    }

    // Output uses screen_cols per row so it matches the display buffer stride
    int out_cols = (screen_cols > 0 && screen_cols < back_cols) ? screen_cols : back_cols;
    int size = count * out_cols;
    if (size > (132 * 100)) {
        size = 132 * 100;
        count = size / out_cols;
    }

    struct vmem_cell *scrollback = g_cterm->scrollback;
    int arr_idx = 0;
    /* Same bit-7 rule as the screen packer: strip it unless it currently means blink */
    const int attr7 = attr_bit7_meaning();
    const unsigned int attr_mask = (attr7 == ATTR7_BLINK) ? 0xFFu : 0x7Fu;
    const unsigned int bg_mask = (attr7 == ATTR7_NONE) ? 0x07u : 0x0Fu;

    // Iterate oldest-first so the output is in chronological order.
    // offset+count-1 is the oldest visible line, offset is the most recent.
    for (int line = count - 1; line >= 0 && arr_idx < size; line--) {
        int lines_back = offset + line;
        int ring_idx = (backpos - 1 - lines_back + capacity * 2) % capacity;
        if (ring_idx < 0 || ring_idx >= capacity) continue;

        // Output only out_cols (screen width) cells, but index into
        // the ring at back_cols stride
        for (int col = 0; col < out_cols && arr_idx < size; col++) {
            int cell_idx = ring_idx * back_cols + col;
            if (cell_idx < 0 || cell_idx >= capacity * back_cols) continue;
            struct vmem_cell *cell = &scrollback[cell_idx];

            unsigned int ch = cell->ch & 0xFF;
            unsigned int attr = cell->legacy_attr & 0xFF;
            // Use legacy_attr as canonical color source — ios_puttext() (the
            // legacy path used by cterm) only sets ch + legacy_attr, leaving
            // vmem_cell.fg/bg at 0. This matches native_get_screen_buffer().
            unsigned int fg = attr & 0x0F;
            if (cell->flags & VMEM_FLAG_UNDERLINE)
                fg |= 0x80u;
            unsigned int bg = (attr >> 4) & bg_mask;
            g_scrollback_fg_rgb_cache[arr_idx] = cell_rgb_override(cell->fg, macos_ciolib_get_palette());
            g_scrollback_bg_rgb_cache[arr_idx] = cell_rgb_override(cell->bg, macos_ciolib_get_palette());
            g_scrollback_cache[arr_idx++] = (int32_t)(ch | ((attr & attr_mask) << 8) | (fg << 16) | (bg << 24));
        }
    }

    pthread_mutex_unlock(&g_lock);
    *resultCount = arr_idx;
    return g_scrollback_cache;
}

/* True-colour variant -- see native_get_screen_buffer_rgb. */
const int32_t* native_get_scrollback_buffer_rgb(int32_t offset, int32_t count, int32_t *resultCount,
                                                const int32_t **fg, const int32_t **bg) {
    const int32_t *cells = native_get_scrollback_buffer(offset, count, resultCount);
    if (fg) *fg = cells ? g_scrollback_fg_rgb_cache : NULL;
    if (bg) *bg = cells ? g_scrollback_bg_rgb_cache : NULL;
    return cells;
}

// ============================================================================
// MARK: - Bell Detection
// ============================================================================

bool native_check_bell(void) {
    pthread_mutex_lock(&g_lock);
    int detected = g_bell_detected;
    g_bell_detected = 0;
    pthread_mutex_unlock(&g_lock);
    return detected;
}

// ============================================================================
// MARK: - TAP+ Command Queue (OSC 800)
// ============================================================================

/// Called from syncterm_stubs.c when an OSC 800 sequence is parsed.
/// Pushes to a 16-entry circular queue so rapid commands aren't dropped.
void ios_audio_command(const char *cmd, int len) {
    if (!cmd || len <= 0 || len >= TAP_CMD_BUFFER_SIZE) return;

    pthread_mutex_lock(&g_audio_lock);
    if (g_tap_queue_count < TAP_CMD_QUEUE_SIZE) {
        memcpy(g_tap_cmd_queue[g_tap_queue_head], cmd, len);
        g_tap_cmd_queue[g_tap_queue_head][len] = '\0';
        g_tap_cmd_lengths[g_tap_queue_head] = (int)len;
        g_tap_queue_head = (g_tap_queue_head + 1) % TAP_CMD_QUEUE_SIZE;
        g_tap_queue_count++;
    }
    pthread_mutex_unlock(&g_audio_lock);
}

bool native_check_audio_command(void) {
    return g_tap_queue_count > 0;
}

const char* native_get_audio_command(void) {
    pthread_mutex_lock(&g_audio_lock);
    if (g_tap_queue_count <= 0) {
        pthread_mutex_unlock(&g_audio_lock);
        return NULL;
    }
    g_tap_cmd_queue[g_tap_queue_tail][g_tap_cmd_lengths[g_tap_queue_tail]] = '\0';
    const char *result = g_tap_cmd_queue[g_tap_queue_tail];
    g_tap_queue_tail = (g_tap_queue_tail + 1) % TAP_CMD_QUEUE_SIZE;
    g_tap_queue_count--;
    pthread_mutex_unlock(&g_audio_lock);
    return result;
}

// ============================================================================
// MARK: - Session Logging
// ============================================================================

void native_set_logging_enabled(bool enabled) {
    pthread_mutex_lock(&g_log_lock);
    g_logging_enabled = enabled ? 1 : 0;
    if (!enabled) {
        g_log_buffer_len = 0;
    }
    pthread_mutex_unlock(&g_log_lock);
}

const uint8_t* native_get_logged_data(int32_t *count) {
    pthread_mutex_lock(&g_log_lock);

    if (g_log_buffer_len <= 0) {
        pthread_mutex_unlock(&g_log_lock);
        *count = 0;
        return NULL;
    }

    *count = g_log_buffer_len;
    // Note: Caller should copy data before next call
    g_log_buffer_len = 0;

    pthread_mutex_unlock(&g_log_lock);
    return g_log_buffer;
}

// ============================================================================
// MARK: - Cursor State (granular getters)
// ============================================================================

/* Return the cursor type: _NORMALCURSOR (underline), _SOLIDCURSOR (block),
 * _NOCURSOR (hidden), or _HALFCURSOR. */
int32_t native_get_cursor_type(void) {
    return (int32_t)macos_ciolib_get_cursor_type();
}

/* Start scanline (top) of cursor within a character cell. */
int32_t native_get_cursor_start(void) {
    return (int32_t)macos_ciolib_get_cursor_start();
}

/* End scanline (bottom) of cursor within a character cell. */
int32_t native_get_cursor_end(void) {
    return (int32_t)macos_ciolib_get_cursor_end();
}

/* Returns 1 if the cursor blinks, 0 if it is steady. */
int32_t native_get_cursor_blinks(void) {
    return (int32_t)macos_ciolib_get_cursor_blinks();
}

// ============================================================================
// MARK: - SSH Debug Log
// ============================================================================

// Defined in macos_stubs.c
extern int  ssh_debug_get_log(char *buf, int buflen);

/* Get accumulated SSH debug log — returns bytes written */
int32_t native_get_ssh_debug_log(char *buffer, int32_t bufferLen) {
    return (int32_t)ssh_debug_get_log(buffer, (int)bufferLen);
}

/* Clear the SSH debug log */
void native_clear_ssh_debug_log(void) {
    ssh_debug_clear_log();
}

// ============================================================================
// MARK: - File Transfer Functions (ZMODEM Implementation)
// ============================================================================

bool native_transfer_init(void) {
    // Initialize both the local state and ZMODEM subsystem
    g_transfer_state = 0;
    g_transfer_bytes = 0;
    g_transfer_total = 0;
    g_transfer_filename[0] = '\0';
    g_transfer_error[0] = '\0';

    return zmodem_macos_init() != 0;
}

void native_set_download_dir(const char *dir) {
    if (dir) {
        strncpy(g_download_dir, dir, sizeof(g_download_dir) - 1);
        g_download_dir[sizeof(g_download_dir) - 1] = '\0';
        zmodem_macos_set_download_dir(dir);
    }
}

int32_t native_zmodem_receive(void) {
    // Clear ZMODEM detected flag since we're handling it
    pthread_mutex_lock(&g_zmodem_lock);
    g_zmodem_detected = 0;
    pthread_mutex_unlock(&g_zmodem_lock);

    int result = zmodem_macos_receive();
    return (int32_t)result;
}

int32_t native_zmodem_send(const char *filePath) {
    if (!filePath) {
        return -1;
    }

    // Clear upload ready flag and pre-seed recv buffer with captured ZRINIT
    pthread_mutex_lock(&g_zmodem_lock);
    g_zmodem_upload_ready = 0;
    zmodem_macos_preseed_recv_buffer(g_zmodem_buffer, g_zmodem_buffer_len);
    g_zmodem_buffer_len = 0;
    pthread_mutex_unlock(&g_zmodem_lock);

    int result = zmodem_macos_send(filePath);
    return (int32_t)result;
}

// ============================================================================
// MARK: - X / YMODEM
//
// No ZMODEM buffer handling here: native_zmodem_receive()/send() drain the
// detected-ZMODEM buffer back into the engine, but X/YMODEM has no such
// announcement to catch — the receiver speaks first (it sends the NAK/'C') and
// the BBS answers, so there is never anything sitting in that buffer for us.
// ============================================================================

int32_t native_xmodem_receive(const char *savePath, int32_t mode) {
    return (int32_t)xmodem_macos_receive(savePath, (int)mode);
}

int32_t native_xmodem_send(const char *filePath, int32_t mode) {
    if (!filePath) {
        return -1;
    }
    return (int32_t)xmodem_macos_send(filePath, (int)mode);
}

// ============================================================================
// MARK: - Batch Upload Queue
// ============================================================================

int32_t native_upload_queue_clear(void) {
    g_upload_batch_count = 0;
    return 0;
}

int32_t native_upload_queue_add(const char *filePath) {
    if (!filePath) return -1;
    if (g_upload_batch_count >= MAX_UPLOAD_FILES) return -1;
    strncpy(g_upload_batch[g_upload_batch_count], filePath, 511);
    g_upload_batch[g_upload_batch_count][511] = '\0';
    g_upload_batch_count++;
    return g_upload_batch_count;
}

int32_t native_upload_queue_count(void) {
    return g_upload_batch_count;
}

void native_zmodem_set_8k(int32_t enable) {
    zmodem_macos_set_8k((int)enable);
}

int32_t native_zmodem_largest_rx_block(void) {
    return (int32_t)zmodem_macos_largest_rx_block();
}

int32_t native_zmodem_send_batch(void) {
    if (g_upload_batch_count <= 0) {
        return -3;
    }

    // Mirror native_zmodem_send's pre-send setup ONCE for the whole batch:
    // clear the upload-ready flag and pre-seed the recv buffer with the
    // captured ZRINIT so the sender finds it immediately.
    pthread_mutex_lock(&g_zmodem_lock);
    g_zmodem_upload_ready = 0;
    zmodem_macos_preseed_recv_buffer(g_zmodem_buffer, g_zmodem_buffer_len);
    g_zmodem_buffer_len = 0;
    pthread_mutex_unlock(&g_zmodem_lock);

    const char *ptrs[MAX_UPLOAD_FILES];
    for (int i = 0; i < g_upload_batch_count; i++) {
        ptrs[i] = g_upload_batch[i];
    }
    int result = zmodem_macos_send_batch(ptrs, g_upload_batch_count);
    return (int32_t)result;
}

int32_t native_get_transfer_file_index(int32_t *current, int32_t *total) {
    zmodem_macos_get_file_index(current, total);
    return 0;
}

void native_transfer_cancel(void) {
    zmodem_macos_cancel();
}

int32_t native_get_transfer_state(void) {
    return (int32_t)zmodem_macos_get_state();
}

int32_t native_get_transfer_log(char *buffer, int32_t buffer_len) {
    return (int32_t)zmodem_macos_get_log(buffer, (int)buffer_len);
}

void native_clear_transfer_log(void) {
    zmodem_macos_clear_log();
}

bool native_get_transfer_progress(int64_t *transferred, int64_t *total) {
    zmodem_macos_get_progress(transferred, total);
    return true;
}

const char* native_get_transfer_file_name(void) {
    const char* filename = zmodem_macos_get_filename();
    if (filename && filename[0]) {
        return filename;
    }
    return NULL;
}

const char* native_get_transfer_error(void) {
    const char* error = zmodem_macos_get_error();
    if (error && error[0]) {
        return error;
    }
    return NULL;
}

void native_transfer_reset(void) {
    zmodem_macos_reset();

    // Also reset local state
    g_transfer_state = 0;
    g_transfer_bytes = 0;
    g_transfer_total = 0;
    g_transfer_filename[0] = '\0';
    g_transfer_error[0] = '\0';
}

void native_transfer_cleanup(void) {
    zmodem_macos_cleanup();
    native_transfer_reset();
}

// ============================================================================
// Sixel Graphics Bridge
// ============================================================================

bool native_has_sixel_data(void) {
    return macos_ciolib_has_sixel_data() != 0;
}

bool native_is_sixel_dirty(void) {
    return macos_ciolib_is_pixel_dirty() != 0;
}

bool native_get_sixel_dimensions(int32_t *width, int32_t *height) {
    if (!width || !height) return false;
    if (!macos_ciolib_has_sixel_data()) {
        *width = 0;
        *height = 0;
        return false;
    }
    *width = macos_ciolib_get_pixel_width();
    *height = macos_ciolib_get_pixel_height();
    return true;
}

int32_t native_get_sixel_buffer(int32_t *buffer, int32_t bufferLen) {
    if (!buffer || bufferLen <= 0) return 0;
    if (!macos_ciolib_has_sixel_data()) return 0;

    macos_ciolib_lock();

    int pw = macos_ciolib_get_pixel_width();
    int ph = macos_ciolib_get_pixel_height();
    uint32_t *src = macos_ciolib_get_pixel_buffer();

    if (!src || pw <= 0 || ph <= 0) {
        macos_ciolib_unlock();
        return 0;
    }

    int total = pw * ph;
    if (total > bufferLen) total = bufferLen;

    memcpy(buffer, src, (size_t)total * sizeof(int32_t));
    macos_ciolib_clear_pixel_dirty();

    macos_ciolib_unlock();
    return total;
}

/* Copy only the pixel layer's changed rectangle straight into the app's buffer (dest_w x dest_h, dest_stride pixels
 * per row); full = everything. Returns pixels copied, 0 for nothing, -1 when the layer isn't dest's size (*bw x *bh
 * is the size to re-create the buffer at). Windows syncterm_copy_sixel_pixels, 2026-09-15. */
int32_t native_copy_sixel_pixels(uint32_t *dest, int32_t dest_w, int32_t dest_h, int32_t dest_stride, bool full,
                                 int32_t *x, int32_t *y, int32_t *w, int32_t *h, int32_t *bw, int32_t *bh) {
    if (!x || !y || !w || !h || !bw || !bh) return 0;
    return macos_ciolib_copy_dirty_pixels(dest, dest_w, dest_h, dest_stride, full ? 1 : 0, x, y, w, h, bw, bh);
}

// ============================================================================
// Fast C-based terminal rendering
// ============================================================================

/**
 * Render the terminal screen to a pixel buffer.
 * This is MUCH faster than doing the pixel loop in Swift.
 *
 * @param pixels Output pixel buffer (BGRA format, must be cellWidth*cols * cellHeight*rows * 4 bytes)
 * @param screenBuffer Screen buffer (packed: ch | attr<<8 | fg<<16 | bg<<24)
 * @param cols Number of columns
 * @param rows Number of rows
 * @param cellWidth Width of each cell in pixels (scaled)
 * @param cellHeight Height of each cell in pixels (scaled)
 * @param fontData Font bitmap data (1 bit per pixel, 8 pixels per row)
 * @param fontWidth Native font width (typically 8)
 * @param fontHeight Native font height (typically 16)
 * @param palette 16-entry color palette (RGB format: 0x00RRGGBB)
 */
void native_render_terminal(uint8_t *pixels,
                            int pixelBufferSize,
                            const int32_t *screenBuffer,
                            int screenBufferCount,
                            int cols, int rows,
                            int cellWidth, int cellHeight,
                            const uint8_t *fontData,
                            int fontDataSize,
                            int fontWidth, int fontHeight,
                            const uint32_t *palette) {
    if (!pixels || !screenBuffer || !fontData || !palette) return;
    if (cols <= 0 || rows <= 0 || cellWidth <= 0 || cellHeight <= 0) return;
    if (fontWidth <= 0 || fontHeight <= 0) return;

    // Integer overflow checks on pixel dimensions
    if (cols > 10000 || rows > 10000 || cellWidth > 100 || cellHeight > 100) return;
    int termWidthPx = cols * cellWidth;
    int termHeightPx = rows * cellHeight;
    int requiredPixelBytes = termWidthPx * termHeightPx * 4;
    if (requiredPixelBytes <= 0 || requiredPixelBytes > pixelBufferSize) return;
    if (cols * rows > screenBufferCount) return;

    for (int row = 0; row < rows; row++) {
        for (int col = 0; col < cols; col++) {
            int idx = row * cols + col;
            uint32_t cell = (uint32_t)screenBuffer[idx];

            int charCode = cell & 0xFF;
            int fgIndex = (cell >> 16) & 0x0F;
            int bgIndex = (cell >> 24) & 0x0F;

            // Get colors from palette (0x00RRGGBB format)
            uint32_t fgColor = palette[fgIndex];
            uint32_t bgColor = palette[bgIndex];

            // Extract RGB components
            uint8_t fgR = (fgColor >> 16) & 0xFF;
            uint8_t fgG = (fgColor >> 8) & 0xFF;
            uint8_t fgB = fgColor & 0xFF;
            uint8_t bgR = (bgColor >> 16) & 0xFF;
            uint8_t bgG = (bgColor >> 8) & 0xFF;
            uint8_t bgB = bgColor & 0xFF;

            // Glyph offset in font bitmap
            int glyphOffset = charCode * fontHeight;
            if (glyphOffset + fontHeight > fontDataSize) continue;

            // Cell position in output buffer
            int cellStartX = col * cellWidth;
            int cellStartY = row * cellHeight;

            // Render scaled glyph
            for (int destY = 0; destY < cellHeight; destY++) {
                // Center-sampling: ((2 * destY + 1) * fontHeight) / (2 * cellHeight)
                // This samples from pixel centers, avoiding empty scanlines at glyph boundaries
                int srcY = ((2 * destY + 1) * fontHeight) / (2 * cellHeight);
                if (srcY >= fontHeight) srcY = fontHeight - 1;

                uint8_t rowByte = fontData[glyphOffset + srcY];

                int termY = cellStartY + destY;
                int rowStart = termY * termWidthPx;

                for (int destX = 0; destX < cellWidth; destX++) {
                    // Center-sampling for X
                    int srcX = ((2 * destX + 1) * fontWidth) / (2 * cellWidth);
                    if (srcX >= fontWidth) srcX = fontWidth - 1;

                    int bitIndex = 7 - srcX;
                    int isSet = (rowByte >> bitIndex) & 1;

                    int termX = cellStartX + destX;
                    int pixelIdx = (rowStart + termX) * 4;

                    // Write BGRA (CGImage noneSkipFirst + byteOrder32Little expects B,G,R,X)
                    if (isSet) {
                        pixels[pixelIdx + 0] = fgB;
                        pixels[pixelIdx + 1] = fgG;
                        pixels[pixelIdx + 2] = fgR;
                        pixels[pixelIdx + 3] = 0xFF;
                    } else {
                        pixels[pixelIdx + 0] = bgB;
                        pixels[pixelIdx + 1] = bgG;
                        pixels[pixelIdx + 2] = bgR;
                        pixels[pixelIdx + 3] = 0xFF;
                    }
                }
            }
        }
    }
}
