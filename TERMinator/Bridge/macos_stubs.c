/**
 * macos_stubs.c - iOS-specific stub implementations for SyncTERM
 *
 * Provides stub implementations of UI and platform-specific functions
 * required by the SyncTERM codebase but not needed on iOS.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <stdarg.h>
#include <pthread.h>
#include <sys/stat.h>
#include <unistd.h>

#include "gen_defs.h"
#include "bbslist.h"

// Forward declarations for iOS-specific functions
extern const char* ios_get_documents_directory(void);

// g_bbs_config is defined in syncterm_macos.c — used by uifcinput to supply credentials
extern struct bbslist g_bbs_config;

// ============================================================================
// SSH Debug Log — ring buffer visible to Swift via native_get_ssh_debug_log
// ============================================================================
#define SSH_DEBUG_LOG_SIZE 16384
static char g_ssh_debug_log[SSH_DEBUG_LOG_SIZE];
static int  g_ssh_debug_log_len = 0;
static pthread_mutex_t g_ssh_debug_lock = PTHREAD_MUTEX_INITIALIZER;

/* Append a formatted message to the SSH debug log (thread-safe). */
void ssh_debug_log(const char *fmt, ...) {
    char buf[1024];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    if (n <= 0) return;

    pthread_mutex_lock(&g_ssh_debug_lock);
    int avail = SSH_DEBUG_LOG_SIZE - 1 - g_ssh_debug_log_len;
    if (n > avail) n = avail;
    if (n > 0) {
        memcpy(g_ssh_debug_log + g_ssh_debug_log_len, buf, n);
        g_ssh_debug_log_len += n;
        g_ssh_debug_log[g_ssh_debug_log_len] = '\0';
    }
    pthread_mutex_unlock(&g_ssh_debug_lock);
}

/* Retrieve the accumulated SSH debug log. Returns bytes written. */
int ssh_debug_get_log(char *buf, int buflen) {
    if (!buf || buflen <= 0) return 0;
    pthread_mutex_lock(&g_ssh_debug_lock);
    int copy = g_ssh_debug_log_len;
    if (copy >= buflen) copy = buflen - 1;
    if (copy > 0) memcpy(buf, g_ssh_debug_log, copy);
    buf[copy] = '\0';
    pthread_mutex_unlock(&g_ssh_debug_lock);
    return copy;
}

/* Clear the SSH debug log. */
void ssh_debug_clear_log(void) {
    pthread_mutex_lock(&g_ssh_debug_lock);
    g_ssh_debug_log_len = 0;
    g_ssh_debug_log[0] = '\0';
    pthread_mutex_unlock(&g_ssh_debug_lock);
}

/* Reset password retry counter (called before each new connection attempt). */
static int g_password_retry_count = 0;
#define MAX_PASSWORD_RETRIES 2

void ssh_debug_reset_retry_count(void) {
    g_password_retry_count = 0;
}

// ============================================================================
// File Path Functions
// ============================================================================

// SYNCTERM path type enum values (must match syncterm.h)
// These are defined here to avoid circular includes
enum {
    IOS_SYNCTERM_PATH_INI = 0,
    IOS_SYNCTERM_PATH_LIST = 1,
    IOS_SYNCTERM_DEFAULT_TRANSFER_PATH = 2,
    IOS_SYNCTERM_PATH_CACHE = 3,
    IOS_SYNCTERM_PATH_KEYS = 4,
    IOS_SYNCTERM_PATH_SYSTEM_CACHE = 5
};

static char g_ios_files_dir[1024] = "";

void ios_set_files_dir(const char *path) {
    if (path) {
        strncpy(g_ios_files_dir, path, sizeof(g_ios_files_dir) - 1);
        g_ios_files_dir[sizeof(g_ios_files_dir) - 1] = '\0';
    }
}

char *get_syncterm_filename(char *fn, int fnlen, int type, bool shared) {
    const char *filename = NULL;
    (void)shared;  // Unused on iOS

    switch (type) {
        case IOS_SYNCTERM_PATH_KEYS:  // 4
            filename = "ssh_keys.p15";  // SSH key storage
            break;
        case IOS_SYNCTERM_PATH_INI:  // 0
            filename = "syncterm.ini";
            break;
        case IOS_SYNCTERM_PATH_LIST:  // 1
            filename = "bbslist.ini";
            break;
        default:
            filename = "unknown";
            break;
    }

    if (g_ios_files_dir[0] != '\0') {
        snprintf(fn, fnlen, "%s/%s", g_ios_files_dir, filename);
    } else {
        // Fallback - try to use a reasonable default
        snprintf(fn, fnlen, "/tmp/%s", filename);
    }

    return fn;
}

// ============================================================================
// UI Stub Functions
// ============================================================================

// These are called by SyncTERM but we handle UI differently on iOS

int uifcmsg(const char *msg, const char *helptext) {
    if (msg) {
        printf("[SyncTERM] Message: %s\n", msg);
        ssh_debug_log("[uifcmsg] %s\n", msg);
    }
    if (helptext && helptext[0]) {
        ssh_debug_log("[uifcmsg detail] %s\n", helptext);
    }
    return 0;
}

int uifcinput(const char *title, int maxlen, char *buf, int mode, const char *help) {
    (void)mode;
    (void)help;
    // Provide credentials from g_bbs_config so SSH connections don't try
    // to prompt interactively (there is no UI to prompt from in bridge mode).
    if (title && buf && maxlen > 0) {
        if (strcmp(title, "UserID") == 0 && g_bbs_config.user[0] != '\0') {
            strncpy(buf, g_bbs_config.user, maxlen);
            buf[maxlen - 1] = '\0';
            ssh_debug_log("[auth] Username provided: %s\n", buf);
            return (int)strlen(buf);
        }
        if (strcmp(title, "Password") == 0) {
            if (g_password_retry_count >= MAX_PASSWORD_RETRIES) {
                ssh_debug_log("[auth] ERROR: Max password retries (%d) reached, aborting\n",
                              MAX_PASSWORD_RETRIES);
                g_password_retry_count = 0;
                return -1;
            }
            if (g_bbs_config.password[0] != '\0') {
                strncpy(buf, g_bbs_config.password, maxlen);
                buf[maxlen - 1] = '\0';
                g_password_retry_count++;
                ssh_debug_log("[auth] Password provided (attempt %d, length=%zu)\n",
                              g_password_retry_count, strlen(buf));
                return (int)strlen(buf);
            }
            ssh_debug_log("[auth] No password available for prompt\n");
        }
    }
    ssh_debug_log("[auth] uifcinput cancelled for title='%s'\n", title ? title : "(null)");
    return -1;  // Cancelled
}

int uifcyesno(const char *title, const char *question) {
    (void)title;
    printf("[SyncTERM] Question: %s\n", question ? question : "(null)");
    return 0;  // No by default
}

void uifcbail(void) {
    // Nothing to do on iOS
}

int uifcinit(void) {
    return 0;
}

// ============================================================================
// Window/UI Stub Functions
// ============================================================================

// Note: win_t is defined in uifc.h

// ============================================================================
// Sound/Beep Stub Functions
// ============================================================================

void xp_beep(unsigned int freq, unsigned int dur) {
    (void)freq;
    (void)dur;
    // Bell is handled in Swift via BellManager
}

void xptone_open(void) {
    // Nothing needed
}

void xptone_close(void) {
    // Nothing needed
}

int xptone(double freq, int dur, int device) {
    (void)freq;
    (void)dur;
    (void)device;
    return 0;
}

// ============================================================================
// Serial Port Stub Functions (not used on iOS)
// ============================================================================

int comOpen(const char *device) {
    (void)device;
    return -1;
}

int comClose(int port) {
    (void)port;
    return -1;
}

int comReadByte(int port) {
    (void)port;
    return -1;
}

int comWriteByte(int port, unsigned char byte) {
    (void)port;
    (void)byte;
    return -1;
}

// ============================================================================
// Miscellaneous Stub Functions
// ============================================================================

// Popup dialogs - we don't use these on iOS
void popupmsg(const char *msg, int wait) {
    (void)wait;
    printf("[Popup] %s\n", msg ? msg : "(null)");
}

// Status line updates
void update_status_line(const char *status) {
    printf("[Status] %s\n", status ? status : "(null)");
}

// Get terminal type string
const char *get_terminal_type(void) {
    return "ANSI";
}

// Logging function
void lprintf(int level, const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    printf("[Log %d] ", level);
    vprintf(fmt, args);
    printf("\n");
    va_end(args);
}

// Note: mkpath() is now provided by xpdev/dirwrap.c

// ============================================================================
// Connection Type Stubs (not supported on iOS)
// ============================================================================

// Modem connections - not supported on iOS
int modem_connect(void *bbs) {
    (void)bbs;
    return -1;
}

int modem_close(void) {
    return -1;
}

// PTY connections - not supported on iOS
int pty_connect(void *bbs) {
    (void)bbs;
    return -1;
}

int pty_close(void) {
    return -1;
}

// RLogin connections - implemented in rlogin.c (not stubbed)
// The real implementations handle Telnet as well via shared thread code

// Serial connections - not supported on iOS
int serial_close(void) {
    return -1;
}

// Telnet+TLS (TelnetS) - uses socketpair + NWConnection TLS proxy in Swift
#include "conn.h"
#include "conn_telnet.h"
#include "rlogin.h"

// From telnet_io.h (can't include directly due to sbbs3/telnet.h type conflicts)
extern unsigned char telnet_local_option[0x100];
extern unsigned char telnet_remote_option[0x100];

extern int telnet_log_level;

// Swift bridge functions for TelnetS
extern int swift_telnets_connect(const char *host, int port);
extern void swift_telnets_disconnect(void);

int telnets_connect(void *arg) {
    struct bbslist *bbs = (struct bbslist *)arg;

    telnet_log_level = bbs->telnet_loglevel;

    // Call Swift to establish TLS connection and get socketpair fd
    int fd = swift_telnets_connect(bbs->addr, bbs->port);
    if (fd < 0)
        return -1;

    rlogin_sock = fd;

    // Create connection buffers (same as telnet_connect)
    if (!create_conn_buf(&conn_inbuf, BUFFER_SIZE)) {
        closesocket(rlogin_sock);
        rlogin_sock = INVALID_SOCKET;
        swift_telnets_disconnect();
        return -1;
    }
    if (!create_conn_buf(&conn_outbuf, BUFFER_SIZE)) {
        destroy_conn_buf(&conn_inbuf);
        closesocket(rlogin_sock);
        rlogin_sock = INVALID_SOCKET;
        swift_telnets_disconnect();
        return -1;
    }

    conn_api.rd_buf = (unsigned char *)malloc(BUFFER_SIZE);
    if (!conn_api.rd_buf) {
        destroy_conn_buf(&conn_inbuf);
        destroy_conn_buf(&conn_outbuf);
        closesocket(rlogin_sock);
        rlogin_sock = INVALID_SOCKET;
        swift_telnets_disconnect();
        return -1;
    }
    conn_api.rd_buf_size = BUFFER_SIZE;

    conn_api.wr_buf = (unsigned char *)malloc(BUFFER_SIZE);
    if (!conn_api.wr_buf) {
        FREE_AND_NULL(conn_api.rd_buf);
        destroy_conn_buf(&conn_inbuf);
        destroy_conn_buf(&conn_outbuf);
        closesocket(rlogin_sock);
        rlogin_sock = INVALID_SOCKET;
        swift_telnets_disconnect();
        return -1;
    }
    conn_api.wr_buf_size = BUFFER_SIZE;

    // Set up telnet parse callbacks (reuse telnet's IAC parsing)
    memset(telnet_local_option, 0, sizeof(telnet_local_option));
    memset(telnet_remote_option, 0, sizeof(telnet_remote_option));
    conn_api.rx_parse_cb = telnet_rx_parse_cb;
    conn_api.tx_parse_cb = telnet_tx_parse_cb;

    telnet_deferred = bbs->defer_telnet_negotiation;
    telnet_no_binary = bbs->telnet_no_binary;
    strlcpy(term_name, get_emulation_str(bbs), sizeof(term_name));

    // Start rlogin I/O threads (they read/write rlogin_sock)
    _beginthread(rlogin_output_thread, 0, NULL);
    _beginthread(rlogin_input_thread, 0, bbs);

    if (!telnet_deferred)
        send_initial_state();

    return 0;
}

int telnets_close(void) {
    // Use rlogin_close to shut down threads and close socket
    int ret = rlogin_close();
    // Then tear down the Swift-side TLS proxy
    swift_telnets_disconnect();
    return ret;
}

// ============================================================================
// Terminal Function Stubs
// ============================================================================

extern int g_term_width;
extern int g_term_height;

void get_cterm_size(int *cols, int *rows, int ns) {
    if (cols) *cols = g_term_width;
    if (rows) *rows = g_term_height;
}

void get_term_win_size(int *width, int *height, int *pixelw, int *pixelh, int *nostatus) {
    if (width) *width = g_term_width;
    if (height) *height = g_term_height;
    if (pixelw) *pixelw = 0;
    if (pixelh) *pixelh = 0;
    if (nostatus) *nostatus = 1;
}

// ============================================================================
// UIFC Stubs
// ============================================================================

// Stub uifc structure - minimal implementation
#include "uifc.h"

uifcapi_t uifc = {0};

int init_uifc(bool usemouse, bool allow_redraw) {
    (void)usemouse;
    (void)allow_redraw;
    return 0;
}

// ============================================================================
// INI and BBS List Stubs
// ============================================================================

#include "bbslist.h"
#include "ini_file.h"

ini_style_t ini_style = {0};

str_list_t iniReadBBSList(FILE *fp, bool userList) {
    (void)fp;
    (void)userList;
    return NULL;
}

// ============================================================================
// Logging Stubs
// ============================================================================

FILE *log_fp = NULL;
char *log_levels[] = { "EMERG", "ALERT", "CRIT", "ERR", "WARNING", "NOTICE", "INFO", "DEBUG", NULL };

// ============================================================================
// Global Settings Stub
// ============================================================================

#include "syncterm.h"

struct syncterm_settings settings = {0};

// ============================================================================
// Telnet Option Descriptors
// ============================================================================

const char *telnet_cmd_desc(int cmd) {
    static char buf[32];
    snprintf(buf, sizeof(buf), "CMD_%d", cmd);
    return buf;
}

const char *telnet_opt_desc(int opt) {
    static char buf[32];
    snprintf(buf, sizeof(buf), "OPT_%d", opt);
    return buf;
}

// Acknowledge a telnet option: DO↔WILL, DONT↔WONT
unsigned char telnet_opt_ack(unsigned char cmd) {
    switch (cmd) {
        case 253: return 251;  // DO   → WILL
        case 254: return 252;  // DONT → WONT
        case 251: return 253;  // WILL → DO
        case 252: return 254;  // WONT → DONT
        default:  return cmd;
    }
}

// Negative-acknowledge a telnet option: DO→WONT, WILL→DONT
unsigned char telnet_opt_nak(unsigned char cmd) {
    switch (cmd) {
        case 253: return 252;  // DO   → WONT
        case 254: return 252;  // DONT → WONT (already negative)
        case 251: return 254;  // WILL → DONT
        case 252: return 254;  // WONT → DONT (already negative)
        default:  return cmd;
    }
}

// ============================================================================
// Terminal Emulation Stubs
// ============================================================================

#include "cterm.h"

/* Mirrors bbslist.c's get_emulation(): the screen mode decides the emulation.
 * macOS only offers the Commodore modes besides ANSI (see native_set_screen_mode). */
cterm_emulation_t get_emulation(struct bbslist *bbs) {
    if (!bbs)
        return CTERM_EMULATION_ANSI_BBS;
    switch (bbs->screen_mode) {
        case SCREEN_MODE_C64:
        case SCREEN_MODE_C128_40:
        case SCREEN_MODE_C128_80:
            return CTERM_EMULATION_PETASCII;
        default:
            return CTERM_EMULATION_ANSI_BBS;
    }
}

/* Telnet TTYPE: the entry's terminal name if set, else SyncTERM's per-emulation name —
 * bbslist.c's get_emulation_str(), as Windows and ssh.c already send. */
const char *get_emulation_str(struct bbslist *bbs) {
    if (bbs && bbs->term_name[0])
        return bbs->term_name;

    switch (get_emulation(bbs)) {
        case CTERM_EMULATION_PETASCII:
            return "PETSCII";
        case CTERM_EMULATION_ANSI_BBS:
        default:
            return "syncterm";
    }
}

// ============================================================================
// ciolib Pixel/Graphics Stubs
// ============================================================================

#include "ciolib.h"
#include "macos_ciolib.h"

// Pixel manipulation - forwards to ios_ciolib for sixel graphics rendering
int ciolib_setpixels(uint32_t sx, uint32_t sy, uint32_t ex, uint32_t ey,
                     uint32_t x_off, uint32_t y_off, uint32_t mx_off, uint32_t my_off,
                     struct ciolib_pixels *pixels, struct ciolib_mask *mask) {
    return macos_ciolib_setpixels(sx, sy, ex, ey, x_off, y_off, mx_off, my_off, pixels, mask);
}

struct ciolib_pixels *ciolib_getpixels(uint32_t sx, uint32_t sy, uint32_t ex, uint32_t ey, int force) {
    (void)sx; (void)sy; (void)ex; (void)ey; (void)force;
    return NULL;  // Not supported
}

void ciolib_freepixels(struct ciolib_pixels *pixels) {
    (void)pixels;
    // No-op
}

// Custom cursor — matches bitmap_getcustomcursor/bitmap_setcustomcursor from bitmap_con.c
void ciolib_getcustomcursor(int *startline, int *endline, int *range, int *blink, int *visible) {
    if (startline) *startline = macos_ciolib_get_cursor_start();
    if (endline) *endline = macos_ciolib_get_cursor_end();
    if (range) {
        int h = macos_ciolib_get_char_pixel_height();
        *range = h > 0 ? h : 16;
    }
    if (blink) *blink = macos_ciolib_get_cursor_blinks();
    if (visible) *visible = macos_ciolib_is_cursor_visible();
}

void ciolib_setcustomcursor(int startline, int endline, int range, int blink, int visible) {
    macos_ciolib_set_custom_cursor(startline, endline, range, blink, visible);
}

// ---------------------------------------------------------------------------
// macOS MIGRATION 2026-09-04 — ciolib functions required by the real cterm.c
// engine (USE_REAL_CTERM, see Bridge/cterm_mode.h).
//
// Ported verbatim from the shipping iOS build's ios_stubs.c, which took them
// from Android's android_stubs.c / android_ciolib.c. They complete the canvas
// API surface cterm.c expects. Harmless if the legacy parser is active — they
// are simply never called — so they do NOT need to be removed on a rollback.
// ---------------------------------------------------------------------------

// Write a string one character at a time via ciolib_putch (matches Android).
int ciolib_cputs(const char *str) {
    extern int ciolib_putch(int);
    if (!str) return 0;
    int count = 0;
    while (*str) {
        ciolib_putch((unsigned char)*str++);
        count++;
    }
    return count;
}

// Pack an RGB triple (16-bit components) into a ciolib RGB color value.
uint32_t ciolib_map_rgb(uint16_t r, uint16_t g, uint16_t b) {
    return CIOLIB_COLOR_RGB | ((uint32_t)(r >> 8) << 16)
                            | ((uint32_t)(g >> 8) << 8)
                            |  (uint32_t)(b >> 8);
}

// Board-loaded fonts (CTerm:Font DCS / CSI = n;m{ upload), bitmap_con.c's bitmap_replace_font().
// Only the free slots may be replaced; cterm hands over malloc'd name and data, owned from here.
// The renderer picks the glyphs up through native_get_font_bitmap() once the slot is selected.
extern struct conio_font_data_struct conio_fontdata[257];

void ciolib_replace_font(uint8_t id, char *name, void *data, size_t size) {
    char **slot = NULL;

    if (id >= CONIO_FIRST_FREE_FONT) {
        switch (size) {
            case 10240: slot = &conio_fontdata[id].twelve_by_twenty;  break;
            case 4096:  slot = &conio_fontdata[id].eight_by_sixteen;  break;
            case 3584:  slot = &conio_fontdata[id].eight_by_fourteen; break;
            case 2048:  slot = &conio_fontdata[id].eight_by_eight;    break;
            default:    break;
        }
    }
    if (!slot) {
        free(name);
        free(data);
        return;
    }
    free(*slot);
    *slot = data;
    free(conio_fontdata[id].desc);
    conio_fontdata[id].desc = name;
}

/* ---------------------------------------------------------------------------
 * macOS MIGRATION: xpbeep stubs.
 *
 * The real cterm engine (Bridge/conio/cterm.c) calls into xpdev's xpbeep for
 * ANSI music and tone playback. macOS has no xpbeep.c — the plain BEL is
 * handled separately by native_check_bell()/BellManager, so these are no-ops
 * that just keep the link satisfied. ANSI music is silent in this build.
 * ------------------------------------------------------------------------- */
void xpbeep(double freq, uint32_t duration) {
    (void)freq; (void)duration;
}

void xptone_complete(void) {
}
