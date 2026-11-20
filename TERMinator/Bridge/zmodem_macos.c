/**
 * ZMODEM iOS Bridge
 *
 * Provides C functions to connect iOS/Swift with the native
 * ZMODEM file transfer protocol implementation.
 *
 * This is the iOS equivalent of Android's zmodem_jni.c
 */

#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <stdarg.h>
#include <pthread.h>
#include <errno.h>
#include <sys/stat.h>
#include <unistd.h>
#include <time.h>
#include <sys/time.h>
#include <inttypes.h>

// Type definitions
#include "gen_defs.h"
#include "genwrap.h"
#include "filewrap.h"
#include "dirwrap.h"

// ZMODEM protocol
#include "zmodem.h"

// X/YMODEM protocol + the shared SEND/RECV/XMODEM/YMODEM/CRC/GMODE mode bits
// and the get_block result codes (SUCCESS/NOINP/NOT_YMODEM/NOT_XMODEM).
#include "xmodem.h"
#include "sexyz.h"

// Connection API (declared in conn.h)
#include "conn.h"

// BBS config (for connection type detection)
#include "bbslist.h"

extern struct bbslist g_bbs_config;

/* Transfer diagnostics -- one emitter behind all four macros, as on Windows
 * (native/zmodem_bridge.c): stderr (syncterm_macos.c logs the same way; there
 * is no os_log channel wired up on this side of the bridge), the trace file,
 * and the live status pane in the transfer window all see the same message.
 * The severity is carried as a single char so the UI can colour it.
 *
 * LOGD is the per-block chatter -- one "Sending ZCRCG data subpacket" and one
 * "Progress:" per 1024 bytes -- which goes to stderr and the trace file only,
 * never the status pane, where it would bury the lines that say what went
 * wrong. */
static void zm_emit(char level, const char* msg);

#define LOGI(fmt, ...) do { char _buf[512]; snprintf(_buf, sizeof(_buf), fmt, ##__VA_ARGS__); zm_emit('I', _buf); } while(0)
#define LOGD(fmt, ...) do { char _buf[512]; snprintf(_buf, sizeof(_buf), fmt, ##__VA_ARGS__); zm_emit('D', _buf); } while(0)
#define LOGE(fmt, ...) do { char _buf[512]; snprintf(_buf, sizeof(_buf), fmt, ##__VA_ARGS__); zm_emit('E', _buf); } while(0)
#define LOGW(fmt, ...) do { char _buf[512]; snprintf(_buf, sizeof(_buf), fmt, ##__VA_ARGS__); zm_emit('W', _buf); } while(0)

// Swift bridge: enable/disable raw mode on telnet connection
extern void swift_telnet_set_raw_mode(int enabled);

// Transfer states
typedef enum {
    TRANSFER_IDLE = 0,
    TRANSFER_RECEIVING = 1,
    TRANSFER_SENDING = 2,
    TRANSFER_COMPLETE = 3,
    TRANSFER_ERROR = 4,
    TRANSFER_CANCELLED = 5
} transfer_state_t;

/* Which engine owns the line right now. Cancel has to know: a ZMODEM abort and
 * an X/YMODEM CAN sequence are different bytes, and sending the wrong one leaves
 * the BBS waiting out its own timeout while garbage lands mid-stream. */
typedef enum {
    XFER_PROTO_NONE = 0,
    XFER_PROTO_ZMODEM = 1,
    XFER_PROTO_XYMODEM = 2
} xfer_protocol_t;

// Transfer context
typedef struct {
    zmodem_t zm;
    xmodem_t xm;
    transfer_state_t state;
    xfer_protocol_t protocol;
    int cancelled;
    int64_t current_pos;
    int64_t total_size;
    char current_file[MAX_PATH + 1];
    char download_dir[MAX_PATH + 1];
    char error_message[256];
    int log_level;
    int current_file_index;   // 1-based index of file being sent in a batch (0 = n/a)
    int total_files;          // total files in the current batch (0/1 = single)
    pthread_mutex_t lock;
} transfer_context_t;

// Global transfer context
static transfer_context_t g_zmodem_transfer = {
    .state = TRANSFER_IDLE,
    .protocol = XFER_PROTO_NONE,
    .cancelled = 0,
    .current_pos = 0,
    .total_size = 0,
    .current_file = "",
    .download_dir = "",
    .error_message = "",
    .log_level = LOG_DEBUG
};

static int g_zmodem_initialized = 0;

// Forward declarations for callbacks
static int zmodem_lputs_cb(void* cbdata, int level, const char* str);
static int zmodem_send_byte_cb(void* cbdata, BYTE ch, unsigned timeout);
static int zmodem_recv_byte_cb(void* cbdata, unsigned timeout);
static void zmodem_progress_cb(void* cbdata, int64_t current_pos);
static BOOL zmodem_is_connected_cb(void* cbdata);
static BOOL zmodem_is_cancelled_cb(void* cbdata);
static BOOL zmodem_data_waiting_cb(void* cbdata, unsigned timeout);
static void zmodem_flush_cb(void* cbdata);

// ============================================================================
// MARK: - ZMODEM Callbacks
// ============================================================================

/* ------------------------------------------------------------------
 * Live status ring for the transfer window
 *
 * A running protocol log under the progress bar is the single most useful
 * thing on that screen when a transfer misbehaves: it is where "the board
 * went quiet after ZEOF" becomes visible instead of invisible.
 *
 * A fixed ring, drained by the UI's poll timer. The producer is the transfer
 * thread and the consumer is the main queue, hence the mutex. Overrun drops
 * the OLDEST lines rather than blocking the transfer.
 *
 * LOG_DEBUG never reaches this ring: that level is the per-block chatter --
 * one line per 1024 bytes, ~61,000 of them for a 62 MB upload -- which would
 * bury the handful of lines that actually say what happened.
 * ------------------------------------------------------------------ */
#define ZM_UILOG_LINES     512
#define ZM_UILOG_LINE_MAX  208

/* ------------------------------------------------------------------
 * Protocol trace file
 *
 * The status ring above drives the UI and deliberately drops LOG_DEBUG. This
 * writes EVERYTHING, debug included, to $HOME/terminator-zmodem.log -- the same
 * facility that made the Windows client's ZMODEM problems diagnosable.
 *
 * Opened and closed per line ON PURPOSE: the point is diagnosing a hang or a
 * crash, and a buffered FILE* loses exactly the last few lines -- the ones
 * that say where it stopped -- when the process dies.
 *
 * Truncated once per app run, at the first transfer session (see
 * zmodem_trace_begin_if_first), exactly as on Windows/Linux.
 * ------------------------------------------------------------------ */
static BOOL g_trace_enabled = FALSE;  /* OFF for shipping: a 62 MB upload writes ~11 MB
                                       * here. The transfer window's status pane covers
                                       * the everyday case; flip to TRUE to capture a
                                       * full protocol trace when chasing a bad board. */

static void zm_trace_path(char* out, size_t len) {
    const char* home = getenv("HOME");
    snprintf(out, len, "%s/terminator-zmodem.log", home ? home : ".");
}

/* `line` is the full tagged line from zm_emit(), newline included. */
static void zm_trace(const char* line) {
    if (!g_trace_enabled || line == NULL)
        return;

    char path[1024];
    zm_trace_path(path, sizeof(path));

    FILE* f = fopen(path, "a");
    if (f == NULL)
        return;

    struct timeval tv;
    gettimeofday(&tv, NULL);
    struct tm lt;
    time_t secs = tv.tv_sec;
    localtime_r(&secs, &lt);

    fprintf(f, "%02d:%02d:%02d.%03d %s",
            lt.tm_hour, lt.tm_min, lt.tm_sec, (int)(tv.tv_usec / 1000), line);
    fclose(f);
}

/** Start a fresh trace file and stamp what we are about to do. */
static void zm_trace_begin(const char* what) {
    if (!g_trace_enabled)
        return;

    char path[1024];
    zm_trace_path(path, sizeof(path));

    FILE* f = fopen(path, "w");   /* truncate */
    if (f != NULL) {
        time_t now = time(NULL);
        struct tm lt;
        localtime_r(&now, &lt);
        fprintf(f, "=== %04d-%02d-%02d %02d:%02d:%02d  %s ===\n",
                lt.tm_year + 1900, lt.tm_mon + 1, lt.tm_mday,
                lt.tm_hour, lt.tm_min, lt.tm_sec, what);
        fclose(f);
    }
}

static pthread_mutex_t g_uilog_lock = PTHREAD_MUTEX_INITIALIZER;
static char     g_uilog[ZM_UILOG_LINES][ZM_UILOG_LINE_MAX];
static unsigned g_uilog_written = 0;   /* total ever produced */
static unsigned g_uilog_taken   = 0;   /* total handed to the UI */

static void zm_uilog_push(char level, const char* msg) {
    if (msg == NULL || level == 'D')   /* per-block chatter: trace file only */
        return;

    pthread_mutex_lock(&g_uilog_lock);

    char* slot = g_uilog[g_uilog_written % ZM_UILOG_LINES];
    slot[0] = level;
    strncpy(slot + 1, msg, ZM_UILOG_LINE_MAX - 2);
    slot[ZM_UILOG_LINE_MAX - 1] = '\0';

    /* Newlines would break the one-line-per-entry framing the UI relies on. */
    for (char* q = slot + 1; *q; q++) {
        if (*q == '\r' || *q == '\n')
            *q = ' ';
    }

    g_uilog_written++;
    if (g_uilog_written - g_uilog_taken > ZM_UILOG_LINES)
        g_uilog_taken = g_uilog_written - ZM_UILOG_LINES;

    pthread_mutex_unlock(&g_uilog_lock);
}

static void zm_emit(char level, const char* msg) {
    if (msg == NULL)
        return;
    const char* tag = (level == 'E') ? "SyncTERM-ZMODEM ERROR: "
                    : (level == 'W') ? "SyncTERM-ZMODEM WARN: "
                                     : "SyncTERM-ZMODEM: ";
    char out[ZM_UILOG_LINE_MAX + 320];
    snprintf(out, sizeof(out), "%s%s\n", tag, msg);
    fputs(out, stderr);
    zm_trace(out);
    zm_uilog_push(level, msg);
}

/* Transfer > ZMODEM 8K Blocks ("Super ZMODEM 8K"). Only changes what we SEND:
 * the engine starts every upload at 1K and doubles after each clean block up
 * to max_block_size, halving again on errors. Downloads need nothing -- the
 * sender picks the size and rx_data_subpacket already holds 8192.
 * Ported from Windows native/zmodem_bridge.c (syncterm_zmodem_set_8k). */
static int g_zmodem_8k = 0;

void zmodem_macos_set_8k(int enable) {
    g_zmodem_8k = enable ? 1 : 0;
}

/* Defined with the end-of-file guard further down */
static int64_t g_progress_high_water;

/* ------------------------------------------------------------------
 * Transfer diagnostics -- level 'G' lines in the transfer window.
 *
 * The engine's detail (which frame the board sent, where it asked us to
 * resend from, the bytes it threw away) is all LOG_DEBUG, which only ever
 * reaches the trace file. This picks out the parts that explain a failure
 * and turns them into a handful of plain lines, so a bad transfer can be
 * diagnosed from the window without a trace build. Nothing here is per
 * block except block-size CHANGES, and runs of discarded bytes collapse to
 * one line. The engine (zmodem.c) is untouched.
 * Ported from Windows native/zmodem_bridge.c.
 * ------------------------------------------------------------------ */
#define LOGG(fmt, ...) do { char _buf[512]; snprintf(_buf, sizeof(_buf), fmt, ##__VA_ARGS__); zm_emit('G', _buf); } while(0)

static struct {
    BOOL active;
    int64_t start_ms;
    int64_t last_rx_ms;                 /* last byte the board sent us */
    int64_t last_pos;                   /* previous progress position */
    uint64_t moved;                     /* forward movement, resends included */
    unsigned last_block, largest_block; /* sends: our block size */
    unsigned largest_rx_block;          /* receives: largest subpacket */
    unsigned zrpos, znak, other_frames, crc_errors, timeouts;
    unsigned purged, purged_total;
    char purged_sample[48];
} g_diag;

/* Largest subpacket received in this transfer: the board picks the download
 * block size, so the window title says 8K once an 8K block arrives. */
unsigned zmodem_macos_largest_rx_block(void) {
    return g_diag.largest_rx_block;
}

static int64_t diag_now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static void diag_bytes(char* out, size_t len, uint64_t n) {
    if (n < 1024)
        snprintf(out, len, "%llu B", (unsigned long long)n);
    else if (n < 1024ULL * 1024)
        snprintf(out, len, "%.1f KB", n / 1024.0);
    else
        snprintf(out, len, "%.1f MB", n / 1048576.0);
}

static void diag_block(char* out, size_t len, unsigned n) {
    if (n >= 1024 && n % 1024 == 0)
        snprintf(out, len, "%uK", n / 1024);
    else
        snprintf(out, len, "%u bytes", n);
}

static double diag_silence_secs(void) {
    if (g_diag.last_rx_ms == 0)
        return (diag_now_ms() - g_diag.start_ms) / 1000.0;
    return (diag_now_ms() - g_diag.last_rx_ms) / 1000.0;
}

static BOOL diag_sending(void) {
    pthread_mutex_lock(&g_zmodem_transfer.lock);
    BOOL sending = (g_zmodem_transfer.state == TRANSFER_SENDING);
    pthread_mutex_unlock(&g_zmodem_transfer.lock);
    return sending;
}

static void diag_flush_purge(void) {
    if (g_diag.purged == 0)
        return;
    LOGG("Discarded %u stray byte%s from the board: %s", g_diag.purged,
         g_diag.purged == 1 ? "" : "s", g_diag.purged_sample);
    g_diag.purged = 0;
    g_diag.purged_sample[0] = '\0';
}

static void diag_begin(BOOL is_ssh) {
    memset(&g_diag, 0, sizeof(g_diag));
    g_diag.active = TRUE;
    g_diag.start_ms = diag_now_ms();
    /* No binary-mode report here, unlike Windows: this client puts the Telnet
     * layer in raw mode for every ZMODEM transfer (swift_telnet_set_raw_mode). */
    LOGG("Link: %s, IAC escaping %s, CR escaping %s, timeouts %us, uploads up to %s blocks",
         is_ssh ? "SSH" : "Telnet (raw mode during transfer)",
         g_zmodem_transfer.zm.escape_telnet_iac ? "on" : "off",
         g_zmodem_transfer.zm.escape_cr ? "on" : "off",
         g_zmodem_transfer.zm.recv_timeout,
         g_zmodem_8k ? "8K" : "1K");
}

/* Called with every engine log line, before it is routed by level */
static void diag_on_engine_line(int level, const char* str) {
    static const char purge_tag[] = "Purging data in receive buffer: ";
    static const char frame_tag[] = "zmodem_recv_header frame: ";
    const char* p;

    if (!g_diag.active || str == NULL)
        return;

    if ((p = strstr(str, purge_tag)) != NULL) {
        size_t have = strlen(g_diag.purged_sample);
        p += sizeof(purge_tag) - 1;
        g_diag.purged++;
        g_diag.purged_total++;
        if (have + strlen(p) + 2 < sizeof(g_diag.purged_sample)) {
            if (have)
                strcat(g_diag.purged_sample, " ");
            strcat(g_diag.purged_sample, p);
        } else if (have + 5 < sizeof(g_diag.purged_sample) &&
                   strstr(g_diag.purged_sample, " ...") == NULL) {
            strcat(g_diag.purged_sample, " ...");
        }
        return;
    }
    diag_flush_purge();

    /* Receives: remember the largest subpacket the board sent */
    if ((p = strstr(str, "Successful receipt of subpacket type: ")) != NULL) {
        const char* paren = strrchr(str, '(');
        unsigned n;
        if (paren != NULL && sscanf(paren, "(%u bytes)", &n) == 1 &&
            n > g_diag.largest_rx_block)
            g_diag.largest_rx_block = n;
        return;
    }

    if (strstr(str, "CRC ERROR") != NULL) {
        g_diag.crc_errors++;
        LOGG("CRC error: %s", str);
        return;
    }

    /* One timeout logs several lines; count the raw one: "... TIMEOUT (N seconds)" */
    if (level <= LOG_WARNING && strstr(str, " TIMEOUT (") != NULL) {
        g_diag.timeouts++;
        LOGG("Board silent for %.1fs (timeout)", diag_silence_secs());
        return;
    }

    /* Frames the board sends while we upload. The receive side sees a frame
     * per data block, so only sends are reported. */
    if ((p = strstr(str, frame_tag)) != NULL && diag_sending()) {
        char want[32], had[32];
        p += sizeof(frame_tag) - 1;
        if (strcmp(p, "ZACK") == 0 || strcmp(p, "ZRINIT") == 0 ||
            strcmp(p, "ZFIN") == 0)
            return;
        diag_bytes(had, sizeof(had), (uint64_t)g_zmodem_transfer.zm.current_file_pos);
        if (strcmp(p, "ZRPOS") == 0) {
            if (g_progress_high_water <= 0)
                return;     /* the normal "start here" before any data */
            g_diag.zrpos++;
            diag_bytes(want, sizeof(want), (uint64_t)g_zmodem_transfer.zm.rxd_header_pos);
            LOGG("Board asked for a resend from %s (we had sent %s)", want, had);
            return;
        }
        if (strcmp(p, "ZNAK") == 0) {
            g_diag.znak++;
            LOGG("Board rejected our last header (ZNAK) at %s", had);
            return;
        }
        g_diag.other_frames++;
        LOGG("Board sent %s at %s", p, had);
    }
}

/* Sends: report block-size changes (the ramp up, and drops after errors) */
static void diag_on_progress(int64_t current_pos, BOOL sending) {
    if (!g_diag.active)
        return;
    if (current_pos > g_diag.last_pos)
        g_diag.moved += (uint64_t)(current_pos - g_diag.last_pos);
    g_diag.last_pos = current_pos;

    if (!sending)
        return;
    unsigned bs = g_zmodem_transfer.zm.block_size;
    if (bs != g_diag.last_block) {
        char blk[32];
        diag_block(blk, sizeof(blk), bs);
        if (g_diag.last_block != 0 && bs < g_diag.last_block)
            LOGG("Block size dropped to %s after an error", blk);
        else
            LOGG("Block size now %s", blk);
        g_diag.last_block = bs;
        if (bs > g_diag.largest_block)
            g_diag.largest_block = bs;
    }
}

static void diag_end(void) {
    char moved[32], rate[32], blk[32];
    double secs;

    if (!g_diag.active)
        return;
    diag_flush_purge();
    secs = (diag_now_ms() - g_diag.start_ms) / 1000.0;
    diag_bytes(moved, sizeof(moved), g_diag.moved);
    diag_bytes(rate, sizeof(rate), secs > 0 ? (uint64_t)(g_diag.moved / secs) : 0);
    LOGG("Summary: %u error%s (%u resend, %u NAK, %u CRC, %u timeout, %u other), "
         "%u stray byte%s discarded, %s moved in %.0fs (%s/s)",
         g_zmodem_transfer.zm.errors, g_zmodem_transfer.zm.errors == 1 ? "" : "s",
         g_diag.zrpos, g_diag.znak, g_diag.crc_errors, g_diag.timeouts,
         g_diag.other_frames, g_diag.purged_total,
         g_diag.purged_total == 1 ? "" : "s", moved, secs, rate);
    if (g_diag.largest_block) {
        diag_block(blk, sizeof(blk), g_diag.largest_block);
        LOGG("Receiver: %s-duplex, overlapped I/O %s, CRC-%u, buffer %s; largest block sent %s",
             g_zmodem_transfer.zm.can_full_duplex ? "full" : "half",
             g_zmodem_transfer.zm.can_overlap_io ? "yes" : "no",
             g_zmodem_transfer.zm.can_fcs_32 ? 32 : 16,
             g_zmodem_transfer.zm.recv_bufsize ? "limited" : "unlimited", blk);
    } else if (g_diag.largest_rx_block) {
        diag_block(blk, sizeof(blk), g_diag.largest_rx_block);
        LOGG("Largest block received %s", blk);
    }
    g_diag.active = FALSE;
}

/**
 * ZMODEM Callback: Log output — relays the engine's own messages, stamping
 * each with a severity the UI can colour. LOG_DEBUG reaches stderr and the
 * trace file only.
 */
static int zmodem_lputs_cb(void* cbdata, int level, const char* str) {
    (void)cbdata;

    if (str == NULL)
        return 0;

    diag_on_engine_line(level, str);

    switch (level) {
        case LOG_EMERG:
        case LOG_ALERT:
        case LOG_CRIT:
        case LOG_ERR:
            LOGE("%s", str);
            break;
        case LOG_WARNING:
            LOGW("%s", str);
            break;
        case LOG_NOTICE:
        case LOG_INFO:
            LOGI("%s", str);
            break;
        case LOG_DEBUG:
        default:
            LOGD("%s", str);
            break;
    }

    return 0;
}

/**
 * Drain new status lines into <buffer>, one per line, each prefixed with its
 * severity char ('I', 'W', 'E'). Returns bytes written. Lines are handed
 * out once, so polling repeatedly never repeats a line.
 */
int zmodem_macos_get_log(char* buffer, int bufferLen) {
    if (buffer == NULL || bufferLen <= 1)
        return 0;

    int used = 0;
    pthread_mutex_lock(&g_uilog_lock);

    while (g_uilog_taken < g_uilog_written) {
        const char* line = g_uilog[g_uilog_taken % ZM_UILOG_LINES];
        int len = (int)strlen(line);

        if (used + len + 2 > bufferLen)
            break;

        memcpy(buffer + used, line, (size_t)len);
        used += len;
        buffer[used++] = '\n';
        g_uilog_taken++;
    }

    pthread_mutex_unlock(&g_uilog_lock);
    buffer[used] = '\0';
    return used;
}

/** Drop anything pending, so a new transfer starts with a clean feed. */
void zmodem_macos_clear_log(void) {
    pthread_mutex_lock(&g_uilog_lock);
    g_uilog_taken = g_uilog_written;
    pthread_mutex_unlock(&g_uilog_lock);
}

/**
 * ZMODEM Callback: Send a byte with timeout
 */
static int zmodem_send_byte_cb(void* cbdata, BYTE ch, unsigned timeout) {
    (void)cbdata;

    if (!conn_connected()) {
        return -1;
    }

    /* ⚠️ conn_send() returns the count of bytes it queued *after* Telnet
     * expansion, not the number of OURS it consumed: telnet_tx_parse_cb ->
     * st_telnet_expand() doubles every IAC (0xFF) on the way out, so handing it
     * n bytes can legitimately come back as anything from n to 2n. One byte
     * carrying 0xFF therefore returns 2, and the old `== 1` test called a
     * successful write a failure. That matters far more for X/YMODEM than for
     * ZMODEM — ZMODEM escapes IAC itself before its bytes ever reach here, while
     * X/YMODEM puts RAW FILE BYTES through this callback, so a binary file full
     * of 0xFF exercises the expansion on every block.
     *
     * ⚠️ AND THIS IS WHY THERE IS NO STAGING BUFFER HERE, AND WHY NOBODY SHOULD
     * ADD ONE WITHOUT READING THIS. A short return cannot be mapped back onto
     * the input: you would have to know where in YOUR buffer the expanded cut
     * landed, and st_telnet_expand() is STATEFUL across calls (it carries CR/LF
     * state), so re-running it to find out would itself corrupt the stream.
     * Re-sending a mis-cut prefix is strictly worse than failing. Writing a
     * single byte per call, as below, sidesteps the whole question: the write
     * either happened or it did not.
     *
     * In practice a short/zero return means the link is dead, not busy —
     * conn_buf_wait_free() waits for room for the WHOLE expanded payload and
     * only returns less after its timeout, by which point the 10-30s protocol
     * timeouts have long since fired and the transfer is over anyway. */
    int sent = conn_send(&ch, 1, timeout * 1000);  // Convert to milliseconds
    return (sent >= 1) ? 0 : -1;
}

/**
 * ZMODEM Callback: Receive a byte with timeout
 *
 * Uses an internal read-ahead buffer to avoid calling conn_recv_upto()
 * for every single byte (which is extremely slow due to mutex overhead).
 */
static BYTE recv_buf[4096];
static int recv_buf_pos = 0;
static int recv_buf_len = 0;
/* TRUE only between zmodem_macos_preseed_recv_buffer() actually staging bytes
 * and the send that consumes them. Without this, "is there anything in
 * recv_buf?" cannot tell a deliberate ZRINIT pre-seed from leftovers the last
 * transfer never drained — and leftovers fed into a new handshake break it. */
static BOOL recv_buf_preseeded = FALSE;

static int zmodem_recv_byte_cb(void* cbdata, unsigned timeout) {
    (void)cbdata;
    static unsigned recv_call_count = 0;

    recv_call_count++;

    // Return buffered byte if available
    if (recv_buf_pos < recv_buf_len) {
        return recv_buf[recv_buf_pos++];
    }

    if (!conn_connected()) {
        LOGE("recv_byte: conn_connected() returned false! (call #%u)", recv_call_count);
        return -1;
    }

    // Poll for data with actual timeout.
    // conn_recv_upto() ignores its timeout parameter (returns immediately),
    // so we must poll here to give the BBS time to respond.
    //
    // Cap only to keep the ms multiplication in range (max ~4294 s), as Windows
    // does. NOT 300 s: the end-of-file guard raises recv_timeout to as much as
    // 600 s (60 + 5 s/MB), and a 300 s cap made the engine time out -- and
    // rewind and re-send the whole file -- before the guard's deadline on any
    // upload of 48 MB or more.
    unsigned clamped_timeout = (timeout > 4000000) ? 4000000 : timeout;
    unsigned timeout_ms = clamped_timeout * 1000;
    unsigned elapsed_ms = 0;

    while (elapsed_ms < timeout_ms) {
        recv_buf_pos = 0;
        recv_buf_len = conn_recv_upto(recv_buf, sizeof(recv_buf), 0);

        if (recv_buf_len > 0) {
            g_diag.last_rx_ms = diag_now_ms();
            return recv_buf[recv_buf_pos++];
        }
        recv_buf_len = 0;

        if (!conn_connected()) {
            return -1;
        }

        // Check for cancellation
        pthread_mutex_lock(&g_zmodem_transfer.lock);
        int cancelled = g_zmodem_transfer.cancelled;
        pthread_mutex_unlock(&g_zmodem_transfer.lock);
        if (cancelled) {
            return -1;
        }

        usleep(10000);  // 10ms
        elapsed_ms += 10;
    }

    return -1;  // Timeout
}

/* ------------------------------------------------------------------
 * End-of-file delivery guard
 *
 * Some boards never send the ZRINIT that should follow our ZEOF until long
 * after the protocol's recv_timeout. zmodem_send_file() reads that silence as
 * a mid-stream data error and does the protocol-correct thing for one: rewind
 * to the last ACKed position and re-send with a halved block size. On a
 * streaming (ZCRCG) transfer the only ACK ever received is for the opening
 * handshake block, so the rewind target is ~1024 -- the engine restarts a
 * whole multi-megabyte file from the top, max_errors (10) times over, and
 * every one of those bytes lands on the board's COMMAND PROMPT rather than in
 * its receiver.
 *
 * Measured against one board: a 62 MB upload over SSH took 146 seconds to be
 * acknowledged, and the same board over telnet took 8.9s against a 10s
 * timeout -- i.e. barely inside it. So once the last byte is out, silence
 * means "the board is still chewing", not "the data went bad": wait, scaled
 * by file size, and never re-send.
 *
 * Ported from the Windows client (native/zmodem_bridge.c).
 * ------------------------------------------------------------------ */
#define POST_EOF_WAIT_BASE_SECS    60   /* fixed overhead, any size */
#define POST_EOF_WAIT_SECS_PER_MB   5   /* measured ~2.4 s/MB; 2x margin */
#define POST_EOF_WAIT_MAX_SECS     600  /* never wait more than 10 minutes */

static int64_t zmodem_now_ms(void);
static void zmodem_watchdog_kick(void);
static void zmodem_watchdog_arm(void);
static void zmodem_watchdog_disarm(void);

static int64_t g_eof_deadline_ms = 0;              /* 0 = disarmed */
static BOOL    g_eof_delivered = FALSE;            /* whole file reached the wire */
static BOOL    g_eof_completed_on_timeout = FALSE; /* deadline fired; report success */
static unsigned g_eof_wait_secs = 0;               /* window actually chosen */
static int64_t g_progress_high_water = -1;         /* furthest position reached */

static unsigned post_eof_wait_secs(int64_t file_size) {
    int64_t mb = file_size / (1024 * 1024);
    int64_t secs = POST_EOF_WAIT_BASE_SECS + mb * POST_EOF_WAIT_SECS_PER_MB;
    if (secs > POST_EOF_WAIT_MAX_SECS)
        secs = POST_EOF_WAIT_MAX_SECS;
    return (unsigned)secs;
}

static void zmodem_eof_guard_reset(void) {
    g_eof_deadline_ms = 0;
    g_eof_delivered = FALSE;
    g_eof_completed_on_timeout = FALSE;
    g_eof_wait_secs = 0;
    g_progress_high_water = -1;
}

/**
 * ZMODEM Callback: Progress update
 */
static void zmodem_progress_cb(void* cbdata, int64_t current_pos) {
    (void)cbdata;

    /* Only genuine forward movement counts as progress. A retry that rewinds
     * and re-sends ground we already covered must NOT refresh the watchdog --
     * that is exactly how a 30s retry loop kept a 60s deadline permanently out
     * of reach and turned a dead board into a five-minute hang. */
    if (current_pos > g_progress_high_water) {
        g_progress_high_water = current_pos;
        zmodem_watchdog_kick();
    }

    /* Last byte of the file is on the wire: from here on, silence means the
     * board took delivery and stopped talking, not that the data went bad.
     *
     * SENDS ONLY. This callback also fires on a receive, where "the last byte
     * arrived" says nothing about a silent board -- and a receive has no
     * per-file hook to reset the guard, so in a batch DOWNLOAD file 1's
     * deadline cut file 2 off mid-stream and reported it complete (19 B then
     * 1.5 MB at 15 KB/s stopped at 931,840 bytes). A receive never arms it. */
    pthread_mutex_lock(&g_zmodem_transfer.lock);
    BOOL sending = (g_zmodem_transfer.state == TRANSFER_SENDING);
    pthread_mutex_unlock(&g_zmodem_transfer.lock);
    diag_on_progress(current_pos, sending);
    int64_t file_size = g_zmodem_transfer.zm.current_file_size;
    if (sending && !g_eof_delivered && file_size > 0 && current_pos >= file_size) {
        g_eof_delivered = TRUE;
        g_eof_wait_secs = post_eof_wait_secs(file_size);
        g_eof_deadline_ms = zmodem_now_ms() + ((int64_t)g_eof_wait_secs + 5) * 1000;
        /* Stop the engine timing out (and rewinding) before our deadline. */
        g_zmodem_transfer.zm.recv_timeout = g_eof_wait_secs;
        /* Hand the wait over to the EOF deadline. The idle watchdog measures
         * PROGRESS, and after the last byte there is none by definition -- left
         * armed it fires at 60s every time and pre-empts this guard entirely. */
        zmodem_watchdog_disarm();
        LOGI("Whole file delivered (%lld bytes); waiting up to %d seconds for "
             "the receiver to acknowledge", (long long)file_size,
             (int)g_eof_wait_secs);
    }

    int64_t total_size;
    char current_file[MAX_PATH + 1];

    pthread_mutex_lock(&g_zmodem_transfer.lock);
    g_zmodem_transfer.current_pos = current_pos;

    // Also update from zmodem structure
    g_zmodem_transfer.total_size = g_zmodem_transfer.zm.current_file_size;
    if (g_zmodem_transfer.zm.current_file_name[0] != '\0') {
        // Strip path components to prevent path traversal from malicious BBS
        const char *safe_name = strrchr(g_zmodem_transfer.zm.current_file_name, '/');
        safe_name = safe_name ? safe_name + 1 : g_zmodem_transfer.zm.current_file_name;
        strncpy(g_zmodem_transfer.current_file, safe_name, MAX_PATH);
        g_zmodem_transfer.current_file[MAX_PATH] = '\0';
    }

    /* Copy for logging outside the lock */
    total_size = g_zmodem_transfer.total_size;
    strncpy(current_file, g_zmodem_transfer.current_file, MAX_PATH);
    current_file[MAX_PATH] = '\0';
    pthread_mutex_unlock(&g_zmodem_transfer.lock);

    LOGD("Progress: %lld / %lld - %s",
         (long long)current_pos,
         (long long)total_size,
         current_file);
}

/**
 * ZMODEM Callback: Check if connected
 */
static BOOL zmodem_is_connected_cb(void* cbdata) {
    (void)cbdata;
    BOOL connected = conn_connected() ? TRUE : FALSE;
    if (!connected) {
        LOGE("is_connected_cb: returning FALSE!");
    }
    return connected;
}

/**
 * ZMODEM Callback: Check if cancelled
 */
/* Wall-clock deadline for the end-of-session ZFIN exchange; 0 = not armed.
 * See zmodem_finish_session() for why this has to exist. */
static int64_t g_zfin_deadline_ms = 0;

static int64_t zmodem_now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

/* ------------------------------------------------------------------
 * IDLE WATCHDOG - the backstop the ZFIN deadline alone does not provide.
 *
 * zmodem_get_zfin() is NOT the only place that can hang forever. EVERY call to
 * zmodem_recv_header() shares the same flaw: its scan loop in
 * zmodem_recv_header_raw() only gives up after recv_timeout seconds of TOTAL
 * SILENCE, so a board that keeps talking - printing its post-upload screen, or
 * echoing junk back at us - feeds that loop indefinitely. The wait for ZRINIT
 * right after ZEOF is exactly such a call, and it sits BEFORE the ZFIN
 * handshake, so the ZFIN deadline never gets a chance to fire.
 *
 * Rather than bound each call site, bound PROGRESS: the progress callback fires
 * on every block read from the file, so during a healthy transfer this is
 * refreshed constantly and never trips. It only trips when we are stuck on a
 * board that will not answer.
 *
 * 60s is 6x the 10s protocol recv_timeout - long enough that no healthy slow
 * board trips it, short enough that the user is not staring at a dead window.
 * Armed before each zmodem_send_file(), disarmed at EOF (the EOF guard takes
 * over) and in transfer_end_session(). Ported from Windows native/zmodem_bridge.c.
 * ------------------------------------------------------------------ */
#define TRANSFER_IDLE_LIMIT_MS 60000
static int64_t g_last_progress_ms = 0;   /* 0 = watchdog disarmed */
static BOOL g_trace_started = FALSE;

static void zmodem_trace_begin_if_first(void) {
    if (!g_trace_started) {
        zm_trace_begin("transfer session");
        g_trace_started = TRUE;
    }
}

static void zmodem_watchdog_arm(void)    { g_last_progress_ms = zmodem_now_ms(); }
static void zmodem_watchdog_disarm(void) { g_last_progress_ms = 0; }
static void zmodem_watchdog_kick(void)   { if (g_last_progress_ms) g_last_progress_ms = zmodem_now_ms(); }

static BOOL zmodem_is_cancelled_cb(void* cbdata) {
    (void)cbdata;

    /* The ZFIN watchdog rides on the cancel check because that is the ONLY
     * predicate the engine consults inside its innermost receive loops. */
    if (g_zfin_deadline_ms != 0 && zmodem_now_ms() > g_zfin_deadline_ms) {
        return TRUE;
    }

    /* The file is already delivered and the board has gone quiet. Break out
     * before zmodem_send_file() can "recover" by re-sending it. */
    if (g_eof_deadline_ms != 0 && zmodem_now_ms() > g_eof_deadline_ms) {
        if (!g_eof_completed_on_timeout) {
            g_eof_completed_on_timeout = TRUE;
            LOGW("No acknowledgement of ZEOF after %d seconds. The whole file "
                 "was sent, so this counts as delivered -- closing instead of "
                 "re-sending it.", (int)g_eof_wait_secs);
        }
        return TRUE;
    }

    if (g_last_progress_ms != 0 &&
        zmodem_now_ms() - g_last_progress_ms > TRANSFER_IDLE_LIMIT_MS) {
        LOGE("IDLE WATCHDOG: no transfer progress for %d seconds - giving up. "
             "The board stopped answering; if the file shows as received on the "
             "board, it arrived and only the handshake was lost.",
             TRANSFER_IDLE_LIMIT_MS / 1000);
        return TRUE;
    }

    pthread_mutex_lock(&g_zmodem_transfer.lock);
    int cancelled = g_zmodem_transfer.cancelled;
    pthread_mutex_unlock(&g_zmodem_transfer.lock);

    return cancelled ? TRUE : FALSE;
}

/* How long the whole end-of-session ZFIN exchange gets, start to finish. */
#define ZFIN_TIMEOUT_MS 8000

/**
 * Close a ZMODEM session: send ZFIN, wait for the peer's ZFIN, answer with OO.
 *
 * ⚠️ NEVER call zmodem_get_zfin() bare -- it can hang forever.
 *
 * By the time we get here the FILE IS ALREADY DELIVERED: the receiver commits it
 * when it answers our ZEOF with ZRINIT, which is what made zmodem_send_file()
 * return TRUE. Everything below is just the goodbye handshake, and a board that
 * has already dropped back to its menu will never answer it.
 *
 * Left to itself, zmodem_get_zfin() then behaves very badly:
 *   - it retries max_errors (10) times, ALTERNATING ZFIN and ZABORT, so we spray
 *     ZABORT at a board that has already banked the file, and the hex headers
 *     land as junk on its command prompt;
 *   - each attempt calls zmodem_recv_header(), whose scan loop has NO wall-clock
 *     bound -- it only gives up after recv_timeout seconds of TOTAL SILENCE. A
 *     board that is printing its post-upload screen (or echoing the junk we just
 *     typed at it) keeps that loop fed indefinitely, so the transfer sits at 100%
 *     and never finishes.
 *
 * So: one ZFIN, no ZABORT, and a hard wall-clock deadline enforced through the
 * cancel callback -- the only predicate the engine consults in its innermost
 * receive loops. The transfer is still reported COMPLETE either way; whether the
 * board bothered to say goodbye has no bearing on whether the file arrived.
 */
static void zmodem_finish_session(void) {
    unsigned saved_max_errors   = g_zmodem_transfer.zm.max_errors;
    unsigned saved_recv_timeout = g_zmodem_transfer.zm.recv_timeout;

    g_zmodem_transfer.zm.max_errors = 1;              /* one ZFIN, never a ZABORT */
    if (g_zmodem_transfer.zm.recv_timeout > 5)
        g_zmodem_transfer.zm.recv_timeout = 5;
    g_zfin_deadline_ms = zmodem_now_ms() + ZFIN_TIMEOUT_MS;

    int type = zmodem_get_zfin(&g_zmodem_transfer.zm);

    g_zfin_deadline_ms = 0;
    g_zmodem_transfer.zm.max_errors   = saved_max_errors;
    g_zmodem_transfer.zm.recv_timeout = saved_recv_timeout;
    /* is_cancelled() ASSIGNS zm->cancelled from the callback, so the watchdog
     * firing latches it. Clear it -- the session is over and the flag would
     * otherwise leak into the next transfer's error handling. */
    g_zmodem_transfer.zm.cancelled = FALSE;

    if (type != ZFIN)
        LOGW("No ZFIN from the receiver; the file was already delivered, closing anyway");
}

/**
 * ZMODEM Callback: Check if data is waiting
 */
static BOOL zmodem_data_waiting_cb(void* cbdata, unsigned timeout) {
    (void)cbdata;

    // Check read-ahead buffer first
    if (recv_buf_pos < recv_buf_len) {
        return TRUE;
    }

    if (!conn_connected()) {
        return FALSE;
    }

    // Poll for data with timeout
    // Cap to prevent overflow in the multiplication (max ~4294 s), as Windows;
    // see zmodem_recv_byte_cb for why it is not 300 s.
    unsigned clamped_timeout = (timeout > 4000000) ? 4000000 : timeout;
    unsigned elapsed = 0;
    while (elapsed < clamped_timeout * 1000) {
        size_t waiting = conn_data_waiting();
        if (waiting > 0) {
            return TRUE;
        }

        // Check for cancellation
        pthread_mutex_lock(&g_zmodem_transfer.lock);
        int cancelled = g_zmodem_transfer.cancelled;
        pthread_mutex_unlock(&g_zmodem_transfer.lock);
        if (cancelled) {
            return FALSE;
        }

        usleep(10000);  // 10ms
        elapsed += 10;
    }

    return conn_data_waiting() > 0 ? TRUE : FALSE;
}

/**
 * ZMODEM Callback: Flush output
 */
static void zmodem_flush_cb(void* cbdata) {
    (void)cbdata;
    // Connection is already unbuffered, nothing to do
}

/**
 * ZMODEM Callback: Handle duplicate filename
 *
 * Called when a file already exists and has different CRC (corrupt partial)
 * or is larger than remote. Deletes the existing file and returns TRUE
 * to retry the download from scratch.
 */
static BOOL zmodem_duplicate_filename_cb(void* cbdata, void* zm_ptr) {
    (void)cbdata;
    zmodem_t* zm = (zmodem_t*)zm_ptr;

    // Build path to existing file (strip path components for safety)
    const char *safe_name = strrchr(zm->current_file_name, '/');
    safe_name = safe_name ? safe_name + 1 : zm->current_file_name;

    char fpath[MAX_PATH * 2 + 2];
    pthread_mutex_lock(&g_zmodem_transfer.lock);
    snprintf(fpath, sizeof(fpath), "%s/%s",
             g_zmodem_transfer.download_dir, safe_name);
    pthread_mutex_unlock(&g_zmodem_transfer.lock);

    // Delete the corrupt/mismatched file so we can re-download
    if (remove(fpath) == 0) {
        return TRUE;  // Retry - file is gone, download will proceed
    } else {
        return FALSE;  // Can't delete, skip
    }
}

// ============================================================================
// MARK: - Public API (called from syncterm_ios.c)
// ============================================================================

/**
 * Initialize the ZMODEM transfer system
 */
int zmodem_macos_init(void) {
    LOGD("zmodem_macos_init called");

    if (g_zmodem_initialized) {
        LOGI("Transfer system already initialized");
        return 1;
    }

    // Initialize mutex
    if (pthread_mutex_init(&g_zmodem_transfer.lock, NULL) != 0) {
        return 0;
    }

    // Initialize ZMODEM structure
    zmodem_init(&g_zmodem_transfer.zm,
                &g_zmodem_transfer,        // cbdata
                zmodem_lputs_cb,           // lputs
                zmodem_progress_cb,        // progress
                zmodem_send_byte_cb,       // send_byte
                zmodem_recv_byte_cb,       // recv_byte
                zmodem_is_connected_cb,    // is_connected
                zmodem_is_cancelled_cb,    // is_cancelled
                zmodem_data_waiting_cb,    // data_waiting
                zmodem_flush_cb);          // flush

    // Configure ZMODEM
    g_zmodem_transfer.zm.log_level = &g_zmodem_transfer.log_level;
    g_zmodem_transfer.zm.max_errors = 10;
    g_zmodem_transfer.zm.recv_timeout = 10;
    g_zmodem_transfer.zm.send_timeout = 10;
    g_zmodem_transfer.zm.escape_telnet_iac = TRUE;   // Escape 0xFF (IAC) for Telnet
    g_zmodem_transfer.zm.recv_bufsize = 0;  /* no ZRINIT buffer limit, so senders stream (was 16384: a ZACK stop every 16 KB); conn_inbuf back-pressures, never drops */
    // Match Android's working config: do NOT request ESCCTL. With it set, the
    // receiver drops any control byte the sender didn't ZDLE-escape (zmodem_rx),
    // which silently loses ZFILE/subpacket bytes when the sender doesn't honor
    // ESCCTL -> CRC never validates -> the ZRINIT/ZFILE handshake never completes.
    g_zmodem_transfer.zm.escape_ctrl_chars = FALSE;
    g_zmodem_transfer.zm.duplicate_filename = zmodem_duplicate_filename_cb;

    g_zmodem_transfer.state = TRANSFER_IDLE;
    g_zmodem_transfer.cancelled = 0;
    g_zmodem_initialized = 1;

    LOGI("Transfer system initialized successfully");
    return 1;
}

/**
 * Start a ZMODEM session.
 *
 * zmodem_init() memsets the whole zmodem_t, so this has to run before EVERY
 * transfer rather than once at startup. The engine carries a lot of
 * per-session state that is never otherwise cleared: block_size and
 * max_block_size are halved on each error and never restored, frame_in_transit
 * records whether a ZDATA header still has to be emitted, cancelled latches on
 * a received ZCAN, and ack_file_pos / current_file_pos / current_file_size all
 * describe the *previous* file. Carrying any of that into the next transfer is
 * what makes an upload look finished and then re-send part of the file.
 * SyncTERM's own term.c re-inits per transfer for the same reason.
 *
 * Also settles the connection-type specific tuning.
 */
static void zmodem_begin_session(void) {
    int conn_type = g_bbs_config.conn_type;
    int is_ssh = (conn_type == CONN_TYPE_SSH || conn_type == CONN_TYPE_SSHNA);

    zmodem_trace_begin_if_first();
    zmodem_eof_guard_reset();

    pthread_mutex_lock(&g_zmodem_transfer.lock);
    g_zmodem_transfer.protocol = XFER_PROTO_ZMODEM;
    pthread_mutex_unlock(&g_zmodem_transfer.lock);

    zmodem_init(&g_zmodem_transfer.zm,
                &g_zmodem_transfer,        // cbdata
                zmodem_lputs_cb,           // lputs
                zmodem_progress_cb,        // progress
                zmodem_send_byte_cb,       // send_byte
                zmodem_recv_byte_cb,       // recv_byte
                zmodem_is_connected_cb,    // is_connected
                zmodem_is_cancelled_cb,    // is_cancelled
                zmodem_data_waiting_cb,    // data_waiting
                zmodem_flush_cb);          // flush

    g_zmodem_transfer.zm.log_level = &g_zmodem_transfer.log_level;
    g_zmodem_transfer.zm.max_errors = 10;
    g_zmodem_transfer.zm.recv_bufsize = 0;  /* no ZRINIT buffer limit, so senders stream (was 16384: a ZACK stop every 16 KB); conn_inbuf back-pressures, never drops */
    // Match Android's working config: do NOT request ESCCTL. With it set, the
    // receiver drops any control byte the sender didn't ZDLE-escape (zmodem_rx),
    // which silently loses ZFILE/subpacket bytes when the sender doesn't honor
    // ESCCTL -> CRC never validates -> the ZRINIT/ZFILE handshake never completes.
    g_zmodem_transfer.zm.escape_ctrl_chars = FALSE;
    g_zmodem_transfer.zm.duplicate_filename = zmodem_duplicate_filename_cb;

    if (is_ssh) {
        /* IAC (0xFF) and CR escaped on SSH too (2026-10-09): many boards' SSH servers hand the session to their
         * telnet code, which eats a raw 0xFF as a telnet command -- a board failed every upload block over SSH
         * while telnet (always escaped) worked. Each costs ~0.4%; every receiver decodes ZDLE escapes. */
        g_zmodem_transfer.zm.escape_telnet_iac = TRUE;
        g_zmodem_transfer.zm.escape_cr = TRUE;
        g_zmodem_transfer.zm.recv_timeout = 30;    /* SSH rekeying and crypto overhead */
        g_zmodem_transfer.zm.send_timeout = 30;
        LOGI("ZMODEM session started for SSH (IAC and CR escaped, 30s timeouts)");
    } else {
        g_zmodem_transfer.zm.escape_telnet_iac = TRUE;   // Escape 0xFF (IAC) for Telnet
        g_zmodem_transfer.zm.escape_cr = TRUE;           // a board's telnet code can mangle a raw CR
        g_zmodem_transfer.zm.recv_timeout = 10;
        g_zmodem_transfer.zm.send_timeout = 10;
        LOGI("ZMODEM session started for Telnet (IAC and CR escaped, 10s timeouts)");
    }
    if (g_zmodem_8k) {
        g_zmodem_transfer.zm.max_block_size = sizeof(g_zmodem_transfer.zm.tx_data_subpacket);
        LOGI("ZMODEM 8K blocks enabled (uploads grow 1K -> %u)", g_zmodem_transfer.zm.max_block_size);
    }
    diag_begin(is_ssh);
}

static void transfer_end_session(void);

/**
 * Set download directory
 */
void zmodem_macos_set_download_dir(const char* dir) {
    if (!g_zmodem_initialized) return;   /* the lock does not exist yet */
    if (!dir) {
        LOGE("Download directory was not set");
        return;
    }

    pthread_mutex_lock(&g_zmodem_transfer.lock);
    strncpy(g_zmodem_transfer.download_dir, dir, MAX_PATH - 1);
    g_zmodem_transfer.download_dir[MAX_PATH - 1] = '\0';
    pthread_mutex_unlock(&g_zmodem_transfer.lock);

    LOGI("Download directory set to: %s", dir);
}

/**
 * Receive files via ZMODEM
 * Returns: number of files received, or negative on error
 */
int zmodem_macos_receive(void) {
    // Reset read-ahead buffer for fresh transfer
    recv_buf_pos = 0;
    recv_buf_len = 0;
    recv_buf_preseeded = FALSE;

    LOGD("zmodem_macos_receive called");

    if (!g_zmodem_initialized) {
        LOGE("Transfer system not initialized");
        return -1;
    }

    if (!conn_connected()) {
        LOGE("Not connected");
        return -2;
    }

    pthread_mutex_lock(&g_zmodem_transfer.lock);
    if (g_zmodem_transfer.state != TRANSFER_IDLE) {
        pthread_mutex_unlock(&g_zmodem_transfer.lock);
        LOGE("Transfer already in progress");
        return -3;
    }

    g_zmodem_transfer.state = TRANSFER_RECEIVING;
    g_zmodem_transfer.cancelled = 0;
    g_zmodem_transfer.current_pos = 0;
    g_zmodem_transfer.total_size = 0;
    g_zmodem_transfer.current_file[0] = '\0';
    g_zmodem_transfer.error_message[0] = '\0';

    char download_dir[MAX_PATH + 1];
    strncpy(download_dir, g_zmodem_transfer.download_dir, MAX_PATH);
    download_dir[MAX_PATH] = '\0';
    pthread_mutex_unlock(&g_zmodem_transfer.lock);

    zmodem_begin_session();

    if (download_dir[0] == '\0') {
        LOGE("Download directory not set");
        pthread_mutex_lock(&g_zmodem_transfer.lock);
        g_zmodem_transfer.state = TRANSFER_ERROR;
        strncpy(g_zmodem_transfer.error_message, "Download directory not set",
                sizeof(g_zmodem_transfer.error_message) - 1);
        pthread_mutex_unlock(&g_zmodem_transfer.lock);
        transfer_end_session();
        return -4;
    }

    // Create download directory if it doesn't exist
    int mkdir_result = mkdir(download_dir, 0755);
    int saved_errno = errno;
    if (mkdir_result != 0 && saved_errno != EEXIST) {
        LOGE("Failed to create download directory: %s", strerror(saved_errno));
        pthread_mutex_lock(&g_zmodem_transfer.lock);
        g_zmodem_transfer.state = TRANSFER_ERROR;
        snprintf(g_zmodem_transfer.error_message, sizeof(g_zmodem_transfer.error_message),
                 "Failed to create directory: %s", strerror(saved_errno));
        pthread_mutex_unlock(&g_zmodem_transfer.lock);
        transfer_end_session();
        return -5;
    }

    LOGI("Starting ZMODEM receive to: %s", download_dir);

    // Perform ZMODEM receive
    uint64_t bytes_received = 0;
    LOGI("Calling zmodem_recv_files...");
    swift_telnet_set_raw_mode(1);  // Bypass telnet IAC parsing during binary transfer
    int result = zmodem_recv_files(&g_zmodem_transfer.zm, download_dir, &bytes_received);
    swift_telnet_set_raw_mode(0);  // Restore telnet parsing
    LOGI("zmodem_recv_files returned: %d, bytes_received: %llu", result, (unsigned long long)bytes_received);

    transfer_end_session();

    pthread_mutex_lock(&g_zmodem_transfer.lock);
    if (g_zmodem_transfer.cancelled) {
        g_zmodem_transfer.state = TRANSFER_CANCELLED;
        LOGI("ZMODEM receive cancelled");
    } else if (result < 0) {
        g_zmodem_transfer.state = TRANSFER_ERROR;
        snprintf(g_zmodem_transfer.error_message, sizeof(g_zmodem_transfer.error_message),
                 "ZMODEM receive failed (code %d)", result);
        LOGE("ZMODEM receive failed: %d, file: %s, pos: %lld/%lld",
             result, g_zmodem_transfer.current_file,
             (long long)g_zmodem_transfer.current_pos, (long long)g_zmodem_transfer.total_size);
    } else if (result == 0 && bytes_received == 0) {
        g_zmodem_transfer.state = TRANSFER_ERROR;
        snprintf(g_zmodem_transfer.error_message, sizeof(g_zmodem_transfer.error_message),
                 "No files received - check BBS is sending");
        LOGE("ZMODEM receive: no files received");
    } else {
        g_zmodem_transfer.state = TRANSFER_COMPLETE;
        LOGI("ZMODEM receive complete: %d files, %llu bytes", result, (unsigned long long)bytes_received);
    }
    pthread_mutex_unlock(&g_zmodem_transfer.lock);

    return result;
}

/**
 * Pre-seed the recv buffer with already-telnet-parsed ZRINIT data.
 * Must be called before zmodem_macos_send() to inject captured ZRINIT.
 */
void zmodem_macos_preseed_recv_buffer(const unsigned char *data, int len) {
    /* Nothing to stage (the common case: an upload the user started from the
     * menu, with no BBS-announced ZRINIT captured). Clear rather than return —
     * returning early used to leave the previous transfer's residue in place,
     * which the send path then mistook for a pre-seed. */
    if (!data || len <= 0 || len > (int)sizeof(recv_buf)) {
        recv_buf_pos = 0;
        recv_buf_len = 0;
        recv_buf_preseeded = FALSE;
        return;
    }
    memcpy(recv_buf, data, len);
    recv_buf_pos = 0;
    recv_buf_len = len;
    recv_buf_preseeded = TRUE;
}

/**
 * Send a file via ZMODEM
 * Returns: 0 on success, negative on error
 */
int zmodem_macos_send(const char* file_path) {
    // Reset the read-ahead buffer unless it holds a genuine pre-seeded ZRINIT.
    // Testing recv_buf_len here instead would never clear anything, because a
    // non-empty buffer is exactly the case that needs clearing.
    if (!recv_buf_preseeded) {
        recv_buf_pos = 0;
        recv_buf_len = 0;
    }
    recv_buf_preseeded = FALSE;   // consumed by this session either way

    LOGD("zmodem_macos_send called");

    if (!g_zmodem_initialized) {
        LOGE("Transfer system not initialized");
        return -1;
    }

    if (!conn_connected()) {
        LOGE("Not connected");
        return -2;
    }

    if (!file_path) {
        LOGE("NULL file path");
        return -3;
    }

    pthread_mutex_lock(&g_zmodem_transfer.lock);
    if (g_zmodem_transfer.state != TRANSFER_IDLE) {
        pthread_mutex_unlock(&g_zmodem_transfer.lock);
        LOGE("Transfer already in progress");
        return -4;
    }

    g_zmodem_transfer.state = TRANSFER_SENDING;
    g_zmodem_transfer.cancelled = 0;
    g_zmodem_transfer.current_pos = 0;
    g_zmodem_transfer.total_size = 0;
    strncpy(g_zmodem_transfer.current_file, file_path, MAX_PATH);
    g_zmodem_transfer.current_file[MAX_PATH] = '\0';
    g_zmodem_transfer.error_message[0] = '\0';
    pthread_mutex_unlock(&g_zmodem_transfer.lock);

    zmodem_begin_session();

    LOGI("Starting ZMODEM send: %s", file_path);

    g_zmodem_transfer.zm.current_file_num = g_zmodem_transfer.zm.total_files = 1;

    // Open the file
    FILE *fp = fopen(file_path, "rb");
    if (!fp) {
        int saved_errno = errno;
        LOGE("Failed to open file: %s - %s", file_path, strerror(saved_errno));
        pthread_mutex_lock(&g_zmodem_transfer.lock);
        g_zmodem_transfer.state = TRANSFER_ERROR;
        snprintf(g_zmodem_transfer.error_message, sizeof(g_zmodem_transfer.error_message),
                 "Failed to open file: %s", strerror(saved_errno));
        pthread_mutex_unlock(&g_zmodem_transfer.lock);
        transfer_end_session();
        return -5;
    }

    // Get file name from path
    const char *filename = strrchr(file_path, '/');
    if (filename) {
        filename++;  // Skip the slash
    } else {
        filename = file_path;
    }

    // Make a mutable copy of filename for zmodem_send_file
    char name_buf[MAX_PATH + 1];
    strncpy(name_buf, filename, MAX_PATH);
    name_buf[MAX_PATH] = '\0';

    // Perform ZMODEM send
    time_t start_time = 0;
    uint64_t bytes_sent = 0;
    swift_telnet_set_raw_mode(1);  // Bypass telnet IAC parsing during binary transfer
    zmodem_watchdog_arm();
    BOOL success = zmodem_send_file(&g_zmodem_transfer.zm, name_buf, fp, TRUE, &start_time, &bytes_sent);

    fclose(fp);

    // End the ZMODEM session while raw mode is STILL ON. zmodem_get_zfin()
    // sends a ZFIN hex header (which ends in CR LF), waits for the peer's ZFIN
    // and then sends OO — running any of that with telnet parsing back in the
    // path, and with BINARY being negotiated off underneath it, corrupts the
    // teardown. Skipped on failure/cancel to avoid a pointless timeout waiting
    // for a response that will not come. Matches zmodem_macos_send_batch().
    pthread_mutex_lock(&g_zmodem_transfer.lock);
    int cancelled_now = g_zmodem_transfer.cancelled;
    pthread_mutex_unlock(&g_zmodem_transfer.lock);

    if (g_eof_completed_on_timeout && !cancelled_now) {
        /* Delivered, but the board stopped answering. Skip the ZFIN handshake:
         * it has already left ZMODEM, so those bytes would land on its command
         * prompt -- the very thing this guard exists to stop. */
        success = TRUE;
        g_zmodem_transfer.zm.cancelled = FALSE;
        LOGI("Treating transfer as complete: the whole file was delivered");
    } else if (success && !cancelled_now) {
        zmodem_finish_session();
    }

    swift_telnet_set_raw_mode(0);  // Restore telnet parsing
    transfer_end_session();        // watchdog off, read-ahead dropped

    // Publish the terminal state only once all ZMODEM I/O is finished, so the
    // UI poll loop cannot resume normal connection reads mid-teardown.
    pthread_mutex_lock(&g_zmodem_transfer.lock);
    if (g_zmodem_transfer.cancelled) {
        g_zmodem_transfer.state = TRANSFER_CANCELLED;
        LOGI("ZMODEM send cancelled");
    } else if (!success) {
        g_zmodem_transfer.state = TRANSFER_ERROR;
        strncpy(g_zmodem_transfer.error_message, "ZMODEM send failed",
                sizeof(g_zmodem_transfer.error_message) - 1);
        LOGE("ZMODEM send failed");
    } else {
        g_zmodem_transfer.state = TRANSFER_COMPLETE;
        LOGI("ZMODEM send complete: %llu bytes", (unsigned long long)bytes_sent);
    }
    pthread_mutex_unlock(&g_zmodem_transfer.lock);

    return success ? 0 : -6;
}

/**
 * Send multiple files via ZMODEM in a single session (batch).
 *
 * ZMODEM natively supports batch transfers: the ZRQINIT handshake is issued
 * only for the first file (request_init=TRUE), subsequent files reuse the open
 * session (request_init=FALSE), and a single zmodem_get_zfin() closes it after
 * the last file. This mirrors zmodem_macos_send() but loops over the paths and
 * applies session-level setup (raw mode) once around the whole batch.
 *
 * Returns: number of files sent (>=0) on success, negative on error.
 */
int zmodem_macos_send_batch(const char* const* paths, int count) {
    // Reset the read-ahead buffer unless it holds a genuine pre-seeded ZRINIT.
    // See zmodem_macos_send() — testing recv_buf_len never clears anything.
    if (!recv_buf_preseeded) {
        recv_buf_pos = 0;
        recv_buf_len = 0;
    }
    recv_buf_preseeded = FALSE;   // consumed by this session either way

    LOGD("zmodem_macos_send_batch called (%d files)", count);

    if (!g_zmodem_initialized) {
        LOGE("Transfer system not initialized");
        return -1;
    }

    if (!conn_connected()) {
        LOGE("Not connected");
        return -2;
    }

    if (!paths || count <= 0) {
        LOGE("Upload queue is empty");
        return -3;
    }

    pthread_mutex_lock(&g_zmodem_transfer.lock);
    if (g_zmodem_transfer.state != TRANSFER_IDLE) {
        pthread_mutex_unlock(&g_zmodem_transfer.lock);
        LOGE("Transfer already in progress");
        return -4;
    }

    g_zmodem_transfer.state = TRANSFER_SENDING;
    g_zmodem_transfer.cancelled = 0;
    g_zmodem_transfer.current_pos = 0;
    g_zmodem_transfer.total_size = 0;
    g_zmodem_transfer.current_file[0] = '\0';
    g_zmodem_transfer.error_message[0] = '\0';
    g_zmodem_transfer.current_file_index = 0;
    g_zmodem_transfer.total_files = count;
    pthread_mutex_unlock(&g_zmodem_transfer.lock);

    zmodem_begin_session();

    g_zmodem_transfer.zm.total_files = (unsigned)count;

    // Whether the ZMODEM session handshake (ZRQINIT) has been sent yet.
    // Tracked as a flag (not "i == 0") so that if the first file(s) fail to
    // open, the first file that DOES open still carries the init.
    BOOL initialized = FALSE;
    BOOL overall = TRUE;
    int files_sent = 0;
    uint64_t total_bytes_sent = 0;

    // Session-level setup once: bypass telnet IAC parsing for the whole batch
    swift_telnet_set_raw_mode(1);

    for (int i = 0; i < count; i++) {
        // Honour a cancel requested between files
        pthread_mutex_lock(&g_zmodem_transfer.lock);
        int cancelled = g_zmodem_transfer.cancelled;
        pthread_mutex_unlock(&g_zmodem_transfer.lock);
        if (cancelled) {
            overall = FALSE;
            break;
        }

        const char *file_path = paths[i];
        if (!file_path) {
            overall = FALSE;
            break;
        }
        LOGI("Batch send file %d/%d: %s", i + 1, count, file_path);

        FILE *fp = fopen(file_path, "rb");
        if (!fp) {
            int saved_errno = errno;
            LOGE("Failed to open file: %s - %s", file_path, strerror(saved_errno));
            pthread_mutex_lock(&g_zmodem_transfer.lock);
            snprintf(g_zmodem_transfer.error_message, sizeof(g_zmodem_transfer.error_message),
                     "Failed to open file: %s", strerror(saved_errno));
            pthread_mutex_unlock(&g_zmodem_transfer.lock);
            overall = FALSE;
            break;  // v1 policy: abort the whole batch on a bad file
        }

        // Get file name from path
        const char *filename = strrchr(file_path, '/');
        if (filename) {
            filename++;  // Skip the slash
        } else {
            filename = file_path;
        }

        char name_buf[MAX_PATH + 1];
        strncpy(name_buf, filename, MAX_PATH);
        name_buf[MAX_PATH] = '\0';

        // Publish per-file progress state for the poll thread
        pthread_mutex_lock(&g_zmodem_transfer.lock);
        g_zmodem_transfer.current_file_index = i + 1;
        g_zmodem_transfer.current_pos = 0;
        g_zmodem_transfer.total_size = 0;
        strncpy(g_zmodem_transfer.current_file, name_buf, MAX_PATH);
        g_zmodem_transfer.current_file[MAX_PATH] = '\0';
        pthread_mutex_unlock(&g_zmodem_transfer.lock);

        g_zmodem_transfer.zm.current_file_num = (unsigned)(i + 1);

        // request_init (ZRQINIT) only for the first file actually sent
        time_t start_time = 0;
        uint64_t bytes_sent = 0;
        zmodem_watchdog_arm();

        /* Each file gets its own end-of-file window. zmodem_begin_session()
         * runs ONCE for the whole batch, so without this the guard state from
         * file 1 survives into file 2: g_eof_delivered stays TRUE so the guard
         * never re-arms, and the stale deadline is already in the past, which
         * would abort the next file the moment it starts. */
        zmodem_eof_guard_reset();

        BOOL success = zmodem_send_file(&g_zmodem_transfer.zm, name_buf, fp,
                                        initialized ? FALSE : TRUE,
                                        &start_time, &bytes_sent);
        fclose(fp);

        if (g_eof_completed_on_timeout) {
            /* Delivered, but the board stopped answering. Same reasoning as the
             * single-file send: the file arrived, so carry on with the batch. */
            success = TRUE;
            g_zmodem_transfer.zm.cancelled = FALSE;
            LOGI("Treating '%s' as complete: the whole file was delivered", name_buf);
        }

        if (!success) {
            overall = FALSE;
            break;
        }

        initialized = TRUE;
        files_sent++;
        total_bytes_sent += bytes_sent;
    }

    // Close the ZMODEM session ONCE, after the last file. Only if we actually
    // opened a session (sent >=1 file) and weren't cancelled/failed — skipping
    // ZFIN on failure avoids a needless timeout. Mirrors the single-file send.
    if (initialized && overall && !g_eof_completed_on_timeout) {
        pthread_mutex_lock(&g_zmodem_transfer.lock);
        int cancelled = g_zmodem_transfer.cancelled;
        pthread_mutex_unlock(&g_zmodem_transfer.lock);
        if (!cancelled) {
            zmodem_finish_session();
        }
    }

    swift_telnet_set_raw_mode(0);  // Restore telnet parsing
    transfer_end_session();        // watchdog off, read-ahead dropped

    pthread_mutex_lock(&g_zmodem_transfer.lock);
    if (g_zmodem_transfer.cancelled) {
        g_zmodem_transfer.state = TRANSFER_CANCELLED;
        LOGI("ZMODEM batch send cancelled after %d file(s)", files_sent);
    } else if (!overall) {
        g_zmodem_transfer.state = TRANSFER_ERROR;
        if (g_zmodem_transfer.error_message[0] == '\0') {
            strncpy(g_zmodem_transfer.error_message, "ZMODEM send failed",
                    sizeof(g_zmodem_transfer.error_message) - 1);
        }
        LOGE("ZMODEM batch send failed after %d file(s)", files_sent);
    } else {
        g_zmodem_transfer.state = TRANSFER_COMPLETE;
        LOGI("ZMODEM batch send complete: %d file(s), %llu bytes",
             files_sent, (unsigned long long)total_bytes_sent);
    }
    pthread_mutex_unlock(&g_zmodem_transfer.lock);

    return overall ? files_sent : -6;
}

// ============================================================================
// MARK: - X / YMODEM
//
// Why this exists next to ZMODEM: plenty of boards never offer ZMODEM at all —
// Commodore ones especially — and XMODEM is the lowest common denominator that
// every one of them speaks.
//
// ⚠️ TELNET IS FINE. A RAW SOCKET IS **NOT** REQUIRED. The obvious worry —
// "XMODEM is 8-bit binary, surely it needs a raw socket" — is already answered
// by the connection layer: conn_send() runs the outgoing bytes through
// telnet_tx_parse_cb (which doubles IAC), conn_recv_upto() runs the incoming
// ones through telnet_rx_parse_cb (which eats IAC sequences), and the session
// below forces Telnet binary mode so CR is not rewritten to CR LF in either
// direction. SSH is natively 8-bit clean and needs none of it.
//
// ⚠️ sbbs3/xmodem.c IS ONLY HALF A PROTOCOL. It gives us xmodem_send_file() for
// the send side, but there is deliberately no xmodem_recv_file(): upstream
// drives the receive loop from the CALLER, in SyncTERM's term.c:xmodem_download().
// xmodem_recv_files() below is that loop, ported with the uifc/curses parts
// taken out. If the shared xmodem.c ever changes, diff it against term.c again.
// ============================================================================
//
// ⚠️ AMENDED 2026-09-03 — the claim above holds ONLY FOR A BOARD THAT REALLY
// SPEAKS TELNET. Verified against a fake telnet BBS on loopback, both ends
// telnet, byte-exact with a hostile payload. But not every board on port 23 is
// actually speaking telnet, and against one that is not, OUR telnet layer eats
// any 0xFF in the stream as an IAC command. ZMODEM survives that because it
// escapes IAC itself before the bytes ever reach the wire; X/YMODEM blocks ARE
// raw file bytes, so the download CRCs, retries and dies while ZMODEM on the
// same board is fine. That is why there is now a RAW connection type
// (CONN_TYPE_RAW) in the phonebook — no negotiation, no IAC handling. Do NOT
// silently switch a transfer to raw; it is the USER's choice of link type.

#ifndef XMODEM_128B
#define XMODEM_128B (1 << 10)  // mirrors syncterm/term.h
#endif

/* xmodem_t keeps a POINTER to the mode word and rewrites it in place as the
 * transfer degrades — CRC-16 back to checksum, YMODEM back to XMODEM, -g back
 * to plain. So the storage has to outlive the call, and reading it afterwards
 * tells you what actually happened on the wire. Only one transfer runs at a
 * time (guarded by g_zmodem_transfer.state), so one static is enough. */
static long g_xm_mode = 0;

/* Set when this session was the one that turned Telnet binary mode on, so the
 * teardown only undoes what it did. */
static BOOL g_restore_binary_mode = FALSE;

/**
 * X/YMODEM Callback: Progress update.
 * Different shape from ZMODEM's — block/offset/size/start rather than a bare
 * position — so it cannot share zmodem_progress_cb.
 */
static void xmodem_progress_cb(void* cbdata, unsigned block_num, int64_t offset,
                               int64_t fsize, time_t start) {
    (void)cbdata; (void)block_num; (void)start;

    pthread_mutex_lock(&g_zmodem_transfer.lock);
    g_zmodem_transfer.current_pos = offset;
    /* Plain XMODEM carries no file length, and the receive loop stands in
     * 0x7fffffff for "unknown". Report 0 so the UI falls back to a plain byte
     * counter instead of drawing a progress bar against a bogus 2 GB. */
    g_zmodem_transfer.total_size = (fsize >= 0x7fffffff) ? 0 : fsize;
    pthread_mutex_unlock(&g_zmodem_transfer.lock);
}

/**
 * Start an X/YMODEM session. Mirrors zmodem_begin_session(): fresh engine
 * state, connection-type tuning, and Telnet binary mode for the duration.
 */
static void xmodem_begin_session(long mode) {
    int conn_type = g_bbs_config.conn_type;
    int is_ssh = (conn_type == CONN_TYPE_SSH || conn_type == CONN_TYPE_SSHNA);

    pthread_mutex_lock(&g_zmodem_transfer.lock);
    g_zmodem_transfer.protocol = XFER_PROTO_XYMODEM;
    pthread_mutex_unlock(&g_zmodem_transfer.lock);

    // Drop anything left in the ZMODEM read-ahead buffer from a previous run
    recv_buf_pos = 0;
    recv_buf_len = 0;
    recv_buf_preseeded = FALSE;

    g_xm_mode = mode;

    xmodem_init(&g_zmodem_transfer.xm,
                &g_zmodem_transfer.xm,     // cbdata (our callbacks ignore it)
                &g_xm_mode,
                zmodem_lputs_cb,           // lputs      — protocol-agnostic
                xmodem_progress_cb,        // progress   — X/YMODEM shape
                zmodem_send_byte_cb,       // send_byte  — protocol-agnostic
                zmodem_recv_byte_cb,       // recv_byte  — protocol-agnostic
                zmodem_is_connected_cb,
                zmodem_is_cancelled_cb,
                zmodem_flush_cb);

    g_zmodem_transfer.xm.log_level = &g_zmodem_transfer.log_level;
    g_zmodem_transfer.xm.max_errors = 10;

    if (is_ssh) {
        g_zmodem_transfer.xm.recv_timeout = 30;
        g_zmodem_transfer.xm.send_timeout = 30;
        g_zmodem_transfer.xm.ack_timeout  = 30;
    } else {
        g_zmodem_transfer.xm.recv_timeout = 10;
        g_zmodem_transfer.xm.send_timeout = 10;
        g_zmodem_transfer.xm.ack_timeout  = 10;
    }

    /* 128-byte blocks. XMODEM_128B is not just a preference on old boards: a
     * C64 BBS that only knows 128-byte SOH blocks will reject the 1K STX
     * blocks xmodem_init() defaults to.
     *
     * ⚠️ block_size is what we SEND; max_block_size is the largest we will
     * ACCEPT. Clamping the latter too would make us reject a sender's 1K
     * blocks, so it stays wide open on the receive side — a receiver has no
     * reason to be fussy, it just reads whatever SOH/STX arrives. */
    if (mode & XMODEM_128B) {
        g_zmodem_transfer.xm.block_size = XMODEM_MIN_BLOCK_SIZE;
        if (mode & SEND)
            g_zmodem_transfer.xm.max_block_size = XMODEM_MIN_BLOCK_SIZE;
    }

    /* An X/YMODEM stream is binary: raw CR bytes appear all through the file
     * data and in the YMODEM header block. If the Telnet layer is not in binary
     * mode it expands CR to CR LF on the way out and holds CR back on the way
     * in, corrupting the stream in both directions. */
    g_restore_binary_mode = FALSE;
    if (!is_ssh && !conn_api.binary_mode) {
        LOGI("Forcing Telnet binary mode for the duration of the transfer");
        conn_binary_mode_on();
        g_restore_binary_mode = TRUE;
    }

    LOGI("X/YMODEM session started: mode=0x%lx block_size=%u %s",
             mode, g_zmodem_transfer.xm.block_size, is_ssh ? "(SSH)" : "(Telnet)");
}

/**
 * End a transfer session — ZMODEM or X/YMODEM: disarm the idle watchdog, drop
 * the read-ahead, and undo the binary mode override if we were the ones who
 * turned it on. (There is no staged TX buffer to flush — this file's send_byte
 * callback writes straight through conn_send().)
 */
static void transfer_end_session(void) {
    diag_end();
    zmodem_watchdog_disarm();
    recv_buf_pos = 0;
    recv_buf_len = 0;
    recv_buf_preseeded = FALSE;

    pthread_mutex_lock(&g_zmodem_transfer.lock);
    g_zmodem_transfer.protocol = XFER_PROTO_NONE;
    pthread_mutex_unlock(&g_zmodem_transfer.lock);

    if (g_restore_binary_mode) {
        conn_binary_mode_off();
        g_restore_binary_mode = FALSE;
    }
}

/* Publish the name being transferred to the progress poller. */
static void xmodem_set_current_file(const char* path) {
    pthread_mutex_lock(&g_zmodem_transfer.lock);
    strncpy(g_zmodem_transfer.current_file, getfname(path), MAX_PATH);
    g_zmodem_transfer.current_file[MAX_PATH] = '\0';
    pthread_mutex_unlock(&g_zmodem_transfer.lock);
}

/**
 * Pick a path that does not collide with an existing file.
 *
 * term.c stops and asks the user (overwrite / rename / abort) via uifc. We are
 * on a background transfer thread with no way to ask, and silently overwriting
 * somebody's file is the one outcome that loses data, so append " (n)" before
 * the extension instead — the same thing a browser download does.
 */
static void xmodem_unique_path(char* path, size_t pathsize) {
    char base[MAX_PATH + 1];
    char ext[MAX_PATH + 1];
    char* dot;

    if (access(path, F_OK) != 0)
        return;   /* nothing there — use it as-is */

    strncpy(base, path, MAX_PATH);
    base[MAX_PATH] = '\0';
    ext[0] = '\0';

    /* Split at the LAST dot, but only if it is in the file name rather than a
     * directory component. */
    dot = strrchr(base, '.');
    if (dot != NULL && strchr(dot, '/') == NULL) {
        strncpy(ext, dot, MAX_PATH);
        ext[MAX_PATH] = '\0';
        *dot = '\0';
    }

    for (int n = 1; n < 1000; n++) {
        snprintf(path, pathsize, "%s (%d)%s", base, n, ext);
        if (access(path, F_OK) != 0)
            return;
    }
    /* 1000 collisions: fall through with the last candidate and let fopen fail. */
}

/* Create the download directory, tolerating "it is already there". Matches
 * zmodem_macos_receive() — a single level, not a recursive mkdir -p. */
static int xmodem_mkdownloaddir(const char* dir) {
    if (dir == NULL || dir[0] == '\0')
        return -1;
    if (mkdir(dir, 0755) != 0 && errno != EEXIST)
        return -1;
    return 0;
}

/**
 * Receive one or more files via X/YMODEM.
 *
 * Ported from SyncTERM term.c:xmodem_download(). Returns the number of files
 * received, or negative on failure.
 *
 * save_path is the full target path and applies to XMODEM only, which has no
 * filename in the protocol. YMODEM takes the name from the header block and
 * writes into the download directory; pass NULL/"" for it.
 */
static int xmodem_recv_files(const char* save_path) {
    xmodem_t* xm = &g_zmodem_transfer.xm;
    uchar     block[XMODEM_MAX_BLOCK_SIZE];
    char      path[MAX_PATH + 1];
    char      tmp_path[MAX_PATH + 1];
    char      fname[MAX_PATH + 1];
    char      dldir[MAX_PATH + 1];
    int       i = 0;
    unsigned  errors;
    unsigned  block_num;
    unsigned  total_files = 0;
    unsigned  wr;
    int       files_received = 0;
    BOOL      success = FALSE;
    BOOL      extra_pass = FALSE;
    long      fmode = 0;
    long      serial_num = -1;
    ulong     tmpftime = 0;
    int64_t   file_bytes = 0, file_bytes_left = 0, total_bytes = 0;
    FILE*     fp = NULL;
    time_t    startfile, ftime = 0;

    pthread_mutex_lock(&g_zmodem_transfer.lock);
    strncpy(dldir, g_zmodem_transfer.download_dir, MAX_PATH);
    dldir[MAX_PATH] = '\0';
    pthread_mutex_unlock(&g_zmodem_transfer.lock);

    path[0] = '\0';
    fname[0] = '\0';

    while (conn_connected()) {
        if (g_xm_mode & XMODEM) {
            /* XMODEM: no name, no size. The caller told us where to put it. */
            if (save_path != NULL && save_path[0] != '\0')
                snprintf(path, sizeof(path), "%s", save_path);
            else
                snprintf(path, sizeof(path), "%s/XMODEM.DAT", dldir);
            strncpy(fname, getfname(path), MAX_PATH);
            fname[MAX_PATH] = '\0';
            file_bytes = file_bytes_left = 0x7fffffff;
        }
        else {
            /* YMODEM: block 0 carries name, size, mtime and the batch counts. */
            LOGI("Fetching YMODEM header block");
            for (errors = 0; errors <= xm->max_errors && !xm->cancelled; errors++) {
                xmodem_put_nak(xm, /* expected_block: */ 0);
                i = xmodem_get_block(xm, block, /* expected_block: */ 0);
                if (i == SUCCESS) {
                    if (!(g_xm_mode & GMODE))
                        zmodem_send_byte_cb(xm, ACK, 10);
                    break;
                }
                if (extra_pass) {
                    /* Upstream's hack for sz 0.12.21rc: no header after a
                     * completed file means the batch is simply over. */
                    LOGI("No YMODEM header block after transfer, assuming end of batch");
                    goto done;
                }
                if (i == NOINP && (g_xm_mode & GMODE)) {
                    g_xm_mode &= ~GMODE;
                    LOGW("YMODEM-g timed out, falling back to %s",
                             (g_xm_mode & CRC) ? "CRC-16" : "Checksum");
                }
                if (i == NOT_YMODEM) {
                    /* The sender is really doing XMODEM. term.c prompts for a
                     * filename here; we cannot, so use the caller's path if it
                     * gave one and otherwise land it in the download dir under
                     * a fixed name rather than dropping the transfer. */
                    LOGW("Sender is XMODEM, not YMODEM — falling back");
                    g_xm_mode &= ~YMODEM;
                    g_xm_mode |= XMODEM | CRC;
                    if (save_path != NULL && save_path[0] != '\0')
                        snprintf(path, sizeof(path), "%s", save_path);
                    else
                        snprintf(path, sizeof(path), "%s/XMODEM.DAT", dldir);
                    strncpy(fname, getfname(path), MAX_PATH);
                    fname[MAX_PATH] = '\0';
                    file_bytes = file_bytes_left = 0x7fffffff;
                    break;
                }
                if ((errors + 1 > xm->max_errors / 3) && (g_xm_mode & CRC)
                    && !(g_xm_mode & GMODE)) {
                    LOGI("Falling back to 8-bit Checksum mode");
                    g_xm_mode &= ~CRC;
                }
            }
            if (errors > xm->max_errors || xm->cancelled) {
                xmodem_cancel(xm);
                goto done;
            }
            if (i != NOT_YMODEM) {
                if (!block[0]) {
                    LOGI("Received YMODEM termination block");
                    goto done;
                }
                extra_pass = FALSE;
                file_bytes = total_bytes = 0;
                total_files = 0;
                sscanf(((char*)block) + strlen((char*)block) + 1,
                       "%" PRId64 " %lo %lo %lo %u %" PRId64,
                       &file_bytes,   /* file size (decimal) */
                       &tmpftime,     /* file time (octal unix format) */
                       &fmode,        /* file mode (not used) */
                       &serial_num,   /* program serial number */
                       &total_files,  /* remaining files to be sent */
                       &total_bytes); /* remaining bytes to be sent */
                ftime = (time_t)tmpftime;

                strncpy(fname, (char*)block, MAX_PATH);
                fname[MAX_PATH] = '\0';

                if (!file_bytes)
                    file_bytes = 0x7fffffff;
                file_bytes_left = file_bytes;
                if (!total_files)
                    total_files = 1;
                if (total_bytes < file_bytes)
                    total_bytes = file_bytes;

                snprintf(path, sizeof(path), "%s/%s", dldir, getfname(fname));
                LOGI("Incoming: %s (%" PRId64 " bytes, %u file(s) to come)",
                         getfname(fname), file_bytes, total_files);
            }
        }

        if (isdir(path)) {
            LOGE("%s is an existing directory", path);
            xmodem_cancel(xm);
            goto done;
        }
        if (!(g_xm_mode & OVERWRITE))
            xmodem_unique_path(path, sizeof(path));

        if (xmodem_mkdownloaddir(dldir) != 0)
            LOGW("Could not create download directory %s", dldir);

        /* ⚠️ Receive into a SIDECAR and only put it in place once the file is
         * complete.
         *
         * The obvious thing — fopen(path, "wb") — truncates the destination
         * BEFORE the handshake has even succeeded, so picking an existing file
         * in the Save-As and then having the transfer fail (wrong protocol on
         * the board, carrier dropped, anything) DESTROYS that file. Upstream
         * term.c does exactly that, and it only escaped notice there because
         * nothing ever set the OVERWRITE bit, so xmodem_unique_path() always
         * steered around existing files. The moment overwrite works as the user
         * asked, the data-loss window opens.
         *
         * XMODEM has no resume, so a partial download is worthless — on failure
         * the sidecar is simply deleted and the user's file is untouched. */
        snprintf(tmp_path, sizeof(tmp_path), "%s.part", path);
        xmodem_unique_path(tmp_path, sizeof(tmp_path));  /* skip a stale sidecar */

        if ((fp = fopen(tmp_path, "wb")) == NULL) {
            LOGE("Error %d creating %s", errno, tmp_path);
            pthread_mutex_lock(&g_zmodem_transfer.lock);
            snprintf(g_zmodem_transfer.error_message, sizeof(g_zmodem_transfer.error_message),
                     "Cannot create %s", getfname(tmp_path));
            pthread_mutex_unlock(&g_zmodem_transfer.lock);
            xmodem_cancel(xm);
            goto done;
        }

        xmodem_set_current_file(path);
        pthread_mutex_lock(&g_zmodem_transfer.lock);
        g_zmodem_transfer.current_file_index = files_received + 1;
        g_zmodem_transfer.total_files = (int)total_files;
        g_zmodem_transfer.current_pos = 0;
        g_zmodem_transfer.total_size = (file_bytes >= 0x7fffffff) ? 0 : file_bytes;
        pthread_mutex_unlock(&g_zmodem_transfer.lock);

        LOGI("Receiving %s via %s %s", path,
                 (g_xm_mode & XMODEM) ? ((g_xm_mode & GMODE) ? "XMODEM-g" : "XMODEM")
                                      : ((g_xm_mode & GMODE) ? "YMODEM-g" : "YMODEM"),
                 (g_xm_mode & CRC) ? "CRC-16" : "Checksum");

        startfile = time(NULL);
        success = FALSE;
        errors = 0;
        block_num = 1;

        /* On the NOT_YMODEM path block 1 is already sitting in block[] — it is
         * what told us this was XMODEM — so do not NAK for it again. */
        if (i != NOT_YMODEM)
            xmodem_put_nak(xm, block_num);

        while (conn_connected()) {
            xmodem_progress_cb(xm, block_num, ftello(fp), file_bytes, startfile);

            if (xm->is_cancelled(xm->cbdata)) {
                LOGW("Cancelled locally");
                xmodem_cancel(xm);
                goto done;
            }

            if (i == NOT_YMODEM)
                i = SUCCESS;             /* consume the block already in hand */
            else
                i = xmodem_get_block(xm, block, block_num);

            if (i != SUCCESS) {
                if (i == EOT) {          /* end of this file */
                    success = TRUE;
                    xmodem_put_ack(xm);
                    break;
                }
                if (i == CAN) {          /* remote cancelled */
                    xm->cancelled = TRUE;
                    break;
                }
                if (g_xm_mode & GMODE) {
                    /* -g has no retransmission: one bad block ends it. */
                    LOGE("Too many errors (%u) in streaming mode", ++errors);
                    goto done;
                }
                if (++errors > xm->max_errors) {
                    LOGE("Too many errors (%u)", errors);
                    xmodem_cancel(xm);
                    break;
                }
                if (i != NOT_XMODEM && block_num == 1
                    && errors > (xm->max_errors / 3)
                    && (g_xm_mode & CRC) && !(g_xm_mode & GMODE)) {
                    LOGI("Falling back to 8-bit Checksum mode (error=%d)", i);
                    g_xm_mode &= ~CRC;
                }
                xmodem_put_nak(xm, block_num);
                continue;
            }

            if (!(g_xm_mode & GMODE))
                zmodem_send_byte_cb(xm, ACK, 10);
            if (file_bytes_left <= 0) {
                LOGW("Sender sent more bytes than its header specified");
                break;
            }
            wr = xm->block_size;
            if (wr > (unsigned)file_bytes_left)
                wr = (unsigned)file_bytes_left;
            if (fwrite(block, 1, wr, fp) != wr) {
                LOGE("Error writing %u bytes at offset %" PRId64, wr, (int64_t)ftello(fp));
                xmodem_cancel(xm);
                goto done;
            }
            file_bytes_left -= wr;
            block_num++;
        }

        fflush(fp);

        /* XMODEM pads the last block to the block size with ^Z, and its
         * "length" was our 0x7fffffff placeholder, so for XMODEM the file on
         * disk IS the length — only YMODEM can truncate to a real size. */
        if (file_bytes < (int64_t)filelength(fileno(fp))) {
            LOGI("Truncating file to %" PRId64 " bytes", file_bytes);
            if (chsize(fileno(fp), file_bytes) != 0)
                LOGE("Error %d truncating file", errno);
        } else {
            file_bytes = filelength(fileno(fp));
        }
        fclose(fp);
        fp = NULL;

        if (success) {
            /* rename() replaces atomically on POSIX and — the point of the whole
             * exercise — leaves the destination alone if the rename itself fails.
             * Do NOT "simplify" this to remove()+rename(); that reopens the very
             * window this closes. */
            if (rename(tmp_path, path) != 0) {
                LOGE("Could not put %s in place as %s (error %d)", tmp_path, path, errno);
                pthread_mutex_lock(&g_zmodem_transfer.lock);
                snprintf(g_zmodem_transfer.error_message, sizeof(g_zmodem_transfer.error_message),
                         "Received the file but could not save it as %s", getfname(path));
                pthread_mutex_unlock(&g_zmodem_transfer.lock);
                success = FALSE;
            }
        }

        if (success) {
            time_t t = time(NULL) - startfile;
            if (!t) t = 1;
            files_received++;
            if (!(g_xm_mode & XMODEM) && ftime)
                setfdate(path, ftime);
            LOGI("Received %s: %" PRId64 " bytes in %lus (%lu CPS)",
                     getfname(path), file_bytes, (ulong)t, (ulong)(file_bytes / t));
        } else {
            LOGE("Transfer %s", xm->cancelled ? "cancelled" : "failed");
            /* Bin the sidecar. The destination was never opened, so whatever
             * the user already had at `path` is still sitting there intact. */
            remove(tmp_path);
        }

        if (g_xm_mode & XMODEM)
            break;                       /* XMODEM is one file, full stop */

        if (total_files == 0 || --total_files == 0)
            extra_pass = TRUE;
        if (file_bytes < total_bytes)
            total_bytes -= file_bytes;
        else
            total_bytes = 0;
    }

done:
    if (fp)
        fclose(fp);
    return files_received;
}

/**
 * Receive via X/YMODEM.
 *
 * save_path is the full destination path and is REQUIRED for XMODEM, which has
 * no filename in the protocol. For YMODEM pass NULL — the name comes from the
 * header block and the file lands in the download directory.
 *
 * mode is the sexyz.h bit set: XMODEM or YMODEM, optionally | CRC | GMODE, and
 * | XMODEM_128B to pin 128-byte blocks.
 *
 * Returns the number of files received, or negative on error.
 */
int xmodem_macos_receive(const char* save_path, int mode) {
    LOGD("xmodem_macos_receive called: mode=0x%x path=%s", mode, save_path ? save_path : "(none)");

    if (!g_zmodem_initialized) {
        LOGE("Transfer system not initialized");
        return -1;
    }
    if (!conn_connected()) {
        LOGE("Not connected");
        return -2;
    }
    if ((mode & (XMODEM | YMODEM)) == 0) {
        LOGE("Neither XMODEM nor YMODEM requested (mode=0x%x)", mode);
        return -6;
    }
    if ((mode & XMODEM) && (save_path == NULL || save_path[0] == '\0')) {
        LOGE("XMODEM receive needs a destination path — the protocol has no filename");
        return -7;
    }

    pthread_mutex_lock(&g_zmodem_transfer.lock);
    if (g_zmodem_transfer.state != TRANSFER_IDLE) {
        pthread_mutex_unlock(&g_zmodem_transfer.lock);
        LOGE("Transfer already in progress");
        return -3;
    }
    g_zmodem_transfer.state = TRANSFER_RECEIVING;
    g_zmodem_transfer.cancelled = 0;
    g_zmodem_transfer.current_pos = 0;
    g_zmodem_transfer.total_size = 0;
    g_zmodem_transfer.current_file_index = 0;
    g_zmodem_transfer.total_files = 0;
    g_zmodem_transfer.current_file[0] = '\0';
    g_zmodem_transfer.error_message[0] = '\0';

    char download_dir[MAX_PATH + 1];
    strncpy(download_dir, g_zmodem_transfer.download_dir, MAX_PATH);
    download_dir[MAX_PATH] = '\0';
    pthread_mutex_unlock(&g_zmodem_transfer.lock);

    /* YMODEM has nowhere to put its files without one; XMODEM was handed a
     * full destination path above and does not care. */
    if (download_dir[0] == '\0' && !(mode & XMODEM)) {
        LOGE("Download directory not set");
        pthread_mutex_lock(&g_zmodem_transfer.lock);
        g_zmodem_transfer.state = TRANSFER_ERROR;
        strncpy(g_zmodem_transfer.error_message, "Download directory not set",
                sizeof(g_zmodem_transfer.error_message) - 1);
        pthread_mutex_unlock(&g_zmodem_transfer.lock);
        return -4;
    }
    if (download_dir[0] != '\0' && xmodem_mkdownloaddir(download_dir) != 0) {
        int saved_errno = errno;
        LOGE("Failed to create download directory: %s", strerror(saved_errno));
        pthread_mutex_lock(&g_zmodem_transfer.lock);
        g_zmodem_transfer.state = TRANSFER_ERROR;
        snprintf(g_zmodem_transfer.error_message, sizeof(g_zmodem_transfer.error_message),
                 "Failed to create directory: %s", strerror(saved_errno));
        pthread_mutex_unlock(&g_zmodem_transfer.lock);
        return -5;
    }

    xmodem_begin_session((long)(mode | RECV));

    int files = xmodem_recv_files(save_path);

    transfer_end_session();

    pthread_mutex_lock(&g_zmodem_transfer.lock);
    if (g_zmodem_transfer.cancelled) {
        g_zmodem_transfer.state = TRANSFER_CANCELLED;
        LOGI("X/YMODEM receive cancelled");
    } else if (files <= 0) {
        g_zmodem_transfer.state = TRANSFER_ERROR;
        if (g_zmodem_transfer.error_message[0] == '\0') {
            snprintf(g_zmodem_transfer.error_message, sizeof(g_zmodem_transfer.error_message),
                     "No files received — is the BBS sending %s?",
                     (mode & YMODEM) ? "YMODEM" : "XMODEM");
        }
        LOGE("X/YMODEM receive failed");
    } else {
        g_zmodem_transfer.state = TRANSFER_COMPLETE;
        LOGI("X/YMODEM receive complete: %d file(s)", files);
    }
    pthread_mutex_unlock(&g_zmodem_transfer.lock);

    return files > 0 ? files : -8;
}

/**
 * Send a file via X/YMODEM.
 *
 * mode is the sexyz.h bit set, as for the receive above. Returns 0 on success,
 * negative on error.
 *
 * Single file only: YMODEM batch would need the remaining-files/bytes counters
 * fed per file, and the boards this exists for do not offer batch anyway.
 */
int xmodem_macos_send(const char* file_path, int mode) {
    LOGD("xmodem_macos_send called: mode=0x%x path=%s", mode, file_path ? file_path : "(null)");

    if (!g_zmodem_initialized) {
        LOGE("Transfer system not initialized");
        return -1;
    }
    if (!conn_connected()) {
        LOGE("Not connected");
        return -2;
    }
    if (!file_path || !file_path[0]) {
        LOGE("NULL file path");
        return -3;
    }
    if ((mode & (XMODEM | YMODEM)) == 0) {
        LOGE("Neither XMODEM nor YMODEM requested (mode=0x%x)", mode);
        return -6;
    }

    pthread_mutex_lock(&g_zmodem_transfer.lock);
    if (g_zmodem_transfer.state != TRANSFER_IDLE) {
        pthread_mutex_unlock(&g_zmodem_transfer.lock);
        LOGE("Transfer already in progress");
        return -4;
    }
    g_zmodem_transfer.state = TRANSFER_SENDING;
    g_zmodem_transfer.cancelled = 0;
    g_zmodem_transfer.current_pos = 0;
    g_zmodem_transfer.total_size = 0;
    g_zmodem_transfer.current_file_index = 0;
    g_zmodem_transfer.total_files = 0;
    g_zmodem_transfer.error_message[0] = '\0';
    pthread_mutex_unlock(&g_zmodem_transfer.lock);

    FILE* fp = fopen(file_path, "rb");
    if (fp == NULL) {
        LOGE("Failed to open %s (errno %d)", file_path, errno);
        pthread_mutex_lock(&g_zmodem_transfer.lock);
        g_zmodem_transfer.state = TRANSFER_ERROR;
        snprintf(g_zmodem_transfer.error_message, sizeof(g_zmodem_transfer.error_message),
                 "Cannot open %s", getfname(file_path));
        pthread_mutex_unlock(&g_zmodem_transfer.lock);
        return -5;
    }

    xmodem_set_current_file(file_path);

    xmodem_begin_session((long)(mode | SEND));

    g_zmodem_transfer.xm.total_files = 1;
    g_zmodem_transfer.xm.total_bytes = filelength(fileno(fp));

    pthread_mutex_lock(&g_zmodem_transfer.lock);
    g_zmodem_transfer.total_size = g_zmodem_transfer.xm.total_bytes;
    pthread_mutex_unlock(&g_zmodem_transfer.lock);

    BOOL success = xmodem_send_file(&g_zmodem_transfer.xm, file_path, fp, NULL, NULL);

    /* YMODEM signs a batch off with an empty header block; without it the
     * receiver sits waiting for the next file. */
    if (success && (g_xm_mode & YMODEM)) {
        if (xmodem_get_mode(&g_zmodem_transfer.xm)) {
            uchar term_block[XMODEM_MIN_BLOCK_SIZE];
            LOGI("Sending YMODEM termination block");
            memset(term_block, 0, sizeof(term_block));
            xmodem_put_block(&g_zmodem_transfer.xm, term_block, sizeof(term_block), 0);
            if (xmodem_get_ack(&g_zmodem_transfer.xm, /* tries: */ 6, /* block_num: */ 0) != ACK)
                LOGW("No ACK after the YMODEM terminating block");
        }
    }

    fclose(fp);
    transfer_end_session();

    pthread_mutex_lock(&g_zmodem_transfer.lock);
    if (g_zmodem_transfer.cancelled) {
        g_zmodem_transfer.state = TRANSFER_CANCELLED;
        LOGI("X/YMODEM send cancelled");
    } else if (!success) {
        g_zmodem_transfer.state = TRANSFER_ERROR;
        if (g_zmodem_transfer.error_message[0] == '\0') {
            snprintf(g_zmodem_transfer.error_message, sizeof(g_zmodem_transfer.error_message),
                     "%s send failed", (mode & YMODEM) ? "YMODEM" : "XMODEM");
        }
        LOGE("X/YMODEM send failed");
    } else {
        g_zmodem_transfer.state = TRANSFER_COMPLETE;
        LOGI("X/YMODEM send complete");
    }
    pthread_mutex_unlock(&g_zmodem_transfer.lock);

    return success ? 0 : -7;
}

/**
 * Cancel current transfer
 */
void zmodem_macos_cancel(void) {
    LOGD("zmodem_macos_cancel called");

    if (!g_zmodem_initialized) {
        return;   /* the lock does not exist yet */
    }

    pthread_mutex_lock(&g_zmodem_transfer.lock);
    g_zmodem_transfer.cancelled = 1;
    xfer_protocol_t proto = g_zmodem_transfer.protocol;
    pthread_mutex_unlock(&g_zmodem_transfer.lock);

    /* Send the canonical cancel sequence (8x CAN, 10x BS) straight down the
     * connection, as Windows syncterm_transfer_cancel() does. It is what a
     * ZMODEM peer watches for (5+ CAN) and exactly what an X/YMODEM peer
     * expects (xmodem_cancel() sends the same bytes).
     *
     * Deliberately NOT zmodem_send_zabort() / xmodem_cancel() from here:
     *   - ZABORT is a hex header, which a receiver in the middle of a data
     *     subpacket reads as corrupt data rather than an abort;
     *   - xmodem_cancel() checks is_cancelled() first, and the flag set just
     *     above makes it return WITHOUT SENDING ANYTHING, so an X/YMODEM
     *     cancel used to leave the board waiting out its own timeout;
     *   - both would run the engine from this (UI) thread while the transfer
     *     thread is inside it.
     * conn_send() has its own lock, so the 18 bytes go out as one piece. The
     * transfer thread sees the flag on its next is_cancelled() check and
     * unwinds the session itself.
     *
     * Only while a transfer is running (macOS-only gate): TransferManager.cleanup()
     * also calls cancel, and CAN/BS typed at an idle board's prompt is junk. */
    if (proto != XFER_PROTO_NONE && conn_connected()) {
        static const unsigned char cancel_seq[] = {
            0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18,   /* CAN x8 */
            0x08, 0x08, 0x08, 0x08, 0x08,
            0x08, 0x08, 0x08, 0x08, 0x08                      /* BS  x10 */
        };
        conn_send((void *)cancel_seq, sizeof(cancel_seq), 1000);
    }
}

/**
 * Get current transfer state
 */
int zmodem_macos_get_state(void) {
    pthread_mutex_lock(&g_zmodem_transfer.lock);
    int state = (int)g_zmodem_transfer.state;
    pthread_mutex_unlock(&g_zmodem_transfer.lock);
    return state;
}

/**
 * Get transfer progress
 */
void zmodem_macos_get_progress(int64_t *transferred, int64_t *total) {
    pthread_mutex_lock(&g_zmodem_transfer.lock);
    *transferred = g_zmodem_transfer.current_pos;
    *total = g_zmodem_transfer.total_size;
    pthread_mutex_unlock(&g_zmodem_transfer.lock);
}

/**
 * Get current file name being transferred
 */
const char* zmodem_macos_get_filename(void) {
    static char filename_copy[MAX_PATH + 1];
    pthread_mutex_lock(&g_zmodem_transfer.lock);
    strncpy(filename_copy, g_zmodem_transfer.current_file, MAX_PATH);
    filename_copy[MAX_PATH] = '\0';
    pthread_mutex_unlock(&g_zmodem_transfer.lock);
    return filename_copy;
}

/**
 * Get last error message
 */
const char* zmodem_macos_get_error(void) {
    static char error_copy[256];
    pthread_mutex_lock(&g_zmodem_transfer.lock);
    strncpy(error_copy, g_zmodem_transfer.error_message, sizeof(error_copy) - 1);
    error_copy[sizeof(error_copy) - 1] = '\0';
    pthread_mutex_unlock(&g_zmodem_transfer.lock);
    return error_copy;
}

/**
 * Reset transfer state to idle
 */
void zmodem_macos_reset(void) {
    pthread_mutex_lock(&g_zmodem_transfer.lock);
    g_zmodem_transfer.state = TRANSFER_IDLE;
    g_zmodem_transfer.protocol = XFER_PROTO_NONE;
    g_zmodem_transfer.cancelled = 0;
    g_zmodem_transfer.current_pos = 0;
    g_zmodem_transfer.total_size = 0;
    g_zmodem_transfer.current_file[0] = '\0';
    g_zmodem_transfer.error_message[0] = '\0';
    g_zmodem_transfer.current_file_index = 0;
    g_zmodem_transfer.total_files = 0;
    pthread_mutex_unlock(&g_zmodem_transfer.lock);
    g_diag.largest_rx_block = 0;   /* no stale "8K" title from the last download */
}

/**
 * Get the current file index / total for a batch send.
 * current/total are 1-based; total 0/1 means a single-file transfer.
 */
void zmodem_macos_get_file_index(int32_t *current, int32_t *total) {
    pthread_mutex_lock(&g_zmodem_transfer.lock);
    if (current) *current = (int32_t)g_zmodem_transfer.current_file_index;
    if (total) *total = (int32_t)g_zmodem_transfer.total_files;
    pthread_mutex_unlock(&g_zmodem_transfer.lock);
}

/**
 * Cleanup transfer system
 */
void zmodem_macos_cleanup(void) {
    if (!g_zmodem_initialized) {
        return;
    }

    pthread_mutex_destroy(&g_zmodem_transfer.lock);
    g_zmodem_initialized = 0;
}
