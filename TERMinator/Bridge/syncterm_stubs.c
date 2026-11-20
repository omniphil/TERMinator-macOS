/**
 * SyncTERM Stub Implementations for iOS
 *
 * Provides stub implementations of SyncTERM functions.
 * Connection functions now delegate to Swift TelnetConnection
 * via the swift_telnet_* bridge functions.
 */

#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <stdbool.h>
#include <pthread.h>

#include "ciolib.h"
#include "cterm.h"
#include "macos_ciolib.h"
// macOS MIGRATION 2026-09-04: selects the terminal engine (USE_REAL_CTERM).
#include "cterm_mode.h"
#include "gen_defs.h"
#include "bbslist.h"
#include "conn.h"

// ============================================================================
// Swift Bridge Function Declarations
// ============================================================================

// These are implemented in TelnetConnection.swift via @_cdecl
extern void swift_telnet_set_terminal_size(int width, int height);
extern bool swift_telnet_connect(const char *host, int port);
extern void swift_telnet_disconnect(void);
extern bool swift_telnet_is_connected(void);
extern int swift_telnet_send(const unsigned char *data, int length);
extern int swift_telnet_send_byte(unsigned char byte);
extern int swift_telnet_data_waiting(void);
extern int swift_telnet_receive(unsigned char *buffer, int maxLength);

// These are implemented in SSHConnection.swift via @_cdecl
extern bool swift_ssh_connect(const char *host, int port, const char *username, const char *password);
extern bool swift_ssh_connect_with_key(const char *host, int port, const char *username,
                                        const char *privateKey, const char *publicKey, const char *passphrase);
extern void swift_ssh_disconnect(void);
extern bool swift_ssh_is_connected(void);
extern int swift_ssh_send(const unsigned char *data, int length);
extern int swift_ssh_send_byte(unsigned char byte);
extern int swift_ssh_data_waiting(void);
extern int swift_ssh_receive(unsigned char *buffer, int maxLength);
extern void swift_ssh_set_terminal_size(int width, int height);

// Font data is provided by allfonts.c - declared as extern here
extern struct conio_font_data_struct conio_fontdata[257];

// ============================================================================
// Connection Functions - Now provided by SyncTERM's conn.c
// ============================================================================

/* Note: Connection functions are now provided by conn.c from SyncTERM.
 * The Swift bridge integrates at a higher level via the terminal view model.
 * These stub implementations are kept for reference but commented out.
 */

#if 0  // Connection stubs - replaced by conn.c
bool conn_connect(struct bbslist *bbs) {
    if (!bbs) return false;

    bool success = false;
    g_current_conn_type = bbs->conn_type;

    if (bbs->conn_type == CONN_TYPE_SSH) {
        printf("[conn_connect] Connecting via SSH to %s:%d as %s\n",
               bbs->addr, bbs->port, bbs->user);
        success = swift_ssh_connect(bbs->addr, bbs->port, bbs->user, bbs->password);
    } else {
        printf("[conn_connect] Connecting via Telnet to %s:%d\n", bbs->addr, bbs->port);
        success = swift_telnet_connect(bbs->addr, bbs->port);
    }

    return success;
}

int conn_close(void) {
    if (g_current_conn_type == CONN_TYPE_SSH) {
        swift_ssh_disconnect();
    } else {
        swift_telnet_disconnect();
    }
    return 0;
}

bool conn_connected(void) {
    if (g_current_conn_type == CONN_TYPE_SSH) {
        return swift_ssh_is_connected();
    } else {
        return swift_telnet_is_connected();
    }
}

size_t conn_data_waiting(void) {
    if (g_current_conn_type == CONN_TYPE_SSH) {
        return (size_t)swift_ssh_data_waiting();
    } else {
        return (size_t)swift_telnet_data_waiting();
    }
}

int conn_recv_upto(void *buf, size_t buflen, unsigned int timeout) {
    (void)timeout;
    if (g_current_conn_type == CONN_TYPE_SSH) {
        return swift_ssh_receive((unsigned char *)buf, (int)buflen);
    } else {
        return swift_telnet_receive((unsigned char *)buf, (int)buflen);
    }
}

// Defined in syncterm_macos.c
extern void debug_log_append(const char *fmt, ...);

int conn_send(const void *buf, size_t len, unsigned int timeout) {
    (void)timeout;

    // Log every send through the connection
    {
        const unsigned char *bytes = (const unsigned char *)buf;
        char hexbuf[200];
        int hlen = 0;
        for (size_t i = 0; i < len && i < 32 && hlen < 190; i++) {
            hlen += snprintf(hexbuf + hlen, sizeof(hexbuf) - hlen, " %02X", bytes[i]);
        }
        debug_log_append("conn_send (%zu bytes):%s", len, hexbuf);
    }

    if (g_current_conn_type == CONN_TYPE_SSH) {
        return swift_ssh_send((const unsigned char *)buf, (int)len);
    } else {
        return swift_telnet_send((const unsigned char *)buf, (int)len);
    }
}
#endif  // Connection stubs

// ============================================================================
// CTerm Stubs
// ============================================================================

// ============================================================================
// macOS MIGRATION 2026-09-04 — LEGACY PARSER, NOW OFF BY DEFAULT
//
// This hand-rolled ANSI/Sixel parser is compiled ONLY when the real SyncTERM
// cterm.c engine is disabled (USE_REAL_CTERM 0 in cterm_mode.h). With the flag
// at 1 — the default since the migration — Bridge/conio/cterm.c supplies
// cterm_init/start/end/write/clearscreen instead and this entire block is
// skipped to avoid duplicate symbols.
//
// NOTHING HERE WAS DELETED. Flip USE_REAL_CTERM back to 0 and macOS behaves
// exactly as it did before 2026-09-04. See MIGRATION_CTERM.md.
// ============================================================================
#if !USE_REAL_CTERM

// Global cterm instance
static struct cterminal *g_cterm = NULL;

struct cterminal *cterm_init(int height, int width, int xpos, int ypos,
                             int backlines, int backcols,
                             struct vmem_cell *scrollback,
                             int emulation) {
    if (g_cterm == NULL) {
        g_cterm = calloc(1, sizeof(struct cterminal));
    }
    // Always update dimensions (fix for resize not working)
    if (g_cterm) {
        g_cterm->height = height;
        g_cterm->width = width;
        g_cterm->x = xpos;
        g_cterm->y = ypos;
        g_cterm->backlines = backlines;
        g_cterm->backwidth = backcols;
        g_cterm->scrollback = scrollback;
        g_cterm->emulation = emulation;
    }
    return g_cterm;
}

void cterm_start(struct cterminal *cterm) {
    if (cterm) {
        cterm->started = true;
    }
}

void cterm_end(struct cterminal *cterm, int free_fonts) {
    if (cterm) {
        cterm->started = false;
    }
    (void)free_fonts;  // Unused in stub
}

// Simple ANSI state machine for basic terminal emulation
// States: 0=normal, 1=got ESC, 2=in CSI, 3=in OSC, 4=OSC got ESC (awaiting \)
//         5=DCS params, 6=Sixel data, 7=DCS/Sixel got ESC, 8=skip non-Sixel DCS
static int ansi_state = 0;
static char ansi_params[64];
static int ansi_param_len = 0;

// OSC accumulation buffer (for OSC 800 / TAP and other OSC sequences)
#define OSC_BUFFER_SIZE 4096
static char osc_buffer[OSC_BUFFER_SIZE];
static int osc_buffer_len = 0;

// Forward declaration - implemented in syncterm_ios.c
extern void ios_audio_command(const char *cmd, int len);

// Dispatch completed OSC sequence
static void dispatch_osc(void) {
    if (osc_buffer_len <= 0) return;
    osc_buffer[osc_buffer_len] = '\0';

    // Check for OSC 800 (TAP audio command)
    if (osc_buffer_len > 4 && strncmp(osc_buffer, "800;", 4) == 0) {
        ios_audio_command(osc_buffer + 4, osc_buffer_len - 4);
    }
    // Other OSC sequences can be handled here in the future

    osc_buffer_len = 0;
}

// Response buffer for ANSI queries (like cursor position report)
static char ansi_response[64];
static int ansi_response_len = 0;

// Saved cursor position for ESC[s / ESC[u
static int saved_cursor_x = 1;
static int saved_cursor_y = 1;
static int cterm_cursor = 1;        // DECTCEM state: 1=visible, 0=hidden
static int cterm_cursor_type = _NORMALCURSOR;  // saved cursor type for restore

// Last printed character for ESC[b (REP - repeat previous character)
unsigned char cterm_last_printed_char = 0;

// ANSI color to CGA palette index mapping
// ANSI: 0=Black, 1=Red, 2=Green, 3=Yellow, 4=Blue, 5=Magenta, 6=Cyan, 7=White
// CGA:  0=Black, 1=Blue, 2=Green, 3=Cyan, 4=Red, 5=Magenta, 6=Brown, 7=LightGray
static const int ansi_to_cga[8] = {0, 4, 2, 6, 1, 5, 3, 7};

// iCE mode state - when enabled, background colors should be bright (add 8)
// This persists across SGR commands until reset (SGR 0)
static int ice_mode_enabled = 0;

// Bold/bright mode state - when enabled, foreground colors should be bright (add 8)
// This persists across SGR commands until reset (SGR 0)
static int bold_mode_enabled = 0;

// Underline mode state - tracks ESC[4m / ESC[24m
static int underline_enabled = 0;

// ============================================================================
// DCS / Sixel Graphics State
// ============================================================================

// DCS parameter buffer
static char dcs_params[256];
static int dcs_param_len = 0;

// Sixel image buffer (temporary, freed on completion)
static uint32_t *sixel_image = NULL;
static int sixel_img_w = 0, sixel_img_h = 0;
static int sixel_alloc_w = 0, sixel_alloc_h = 0;

// Sixel drawing state
#define SIXEL_MAX_COLORS 256
static uint32_t sixel_palette[SIXEL_MAX_COLORS];
static int sixel_cur_color = 0;
static int sixel_x = 0, sixel_y = 0;
static int sixel_origin_x = 0, sixel_origin_y = 0;
static int sixel_active = 0;

// Sixel inline command parsing (for #, ", ! commands within sixel data)
static int sixel_cmd = 0;       // 0=none, '#'=color, '"'=raster, '!'=repeat
static int sixel_cmd_params[8];
static int sixel_cmd_count = 0;
static int sixel_cmd_accum = 0;
static int sixel_cmd_has_digit = 0;

// Sixel repeat count
static unsigned long sixel_repeat = 0;

// Forward declarations for sixel functions
static void sixel_begin(void);
static void sixel_end(void);
static void sixel_put_pixel(int x, int y, uint32_t color);
static void sixel_process_data(unsigned char c);
static void sixel_flush_cmd(void);
static void sixel_free(void);

// ============================================================================
// Sixel Helper Functions
// ============================================================================

// Get font height — use char_pixel_height if available, else default 16
static int sixel_get_font_height(void) {
    int h = macos_ciolib_get_char_pixel_height();
    return h > 0 ? h : 16;
}

// Initialize sixel rendering at current cursor position
static void sixel_begin(void) {
    int font_h = sixel_get_font_height();

    // Get cursor position (1-based text coords) and convert to pixel coords
    sixel_origin_x = (ciolib_wherex() - 1) * 8;
    sixel_origin_y = (ciolib_wherey() - 1) * font_h;

    // Initialize first 16 palette entries from terminal palette
    uint32_t *term_palette = macos_ciolib_get_palette();
    if (term_palette) {
        for (int i = 0; i < 16 && i < SIXEL_MAX_COLORS; i++) {
            sixel_palette[i] = 0xFF000000 | (term_palette[i] & 0x00FFFFFF);
        }
    }
    // Remaining entries default to black
    for (int i = 16; i < SIXEL_MAX_COLORS; i++) {
        sixel_palette[i] = 0xFF000000;
    }

    // Allocate initial image buffer (640x384 covers typical 80-col screen)
    sixel_alloc_w = 640;
    sixel_alloc_h = 384;
    sixel_image = calloc((size_t)sixel_alloc_w * sixel_alloc_h, sizeof(uint32_t));
    sixel_img_w = 0;
    sixel_img_h = 0;
    sixel_x = 0;
    sixel_y = 0;
    sixel_cur_color = 0;
    sixel_repeat = 0;
    sixel_cmd = 0;
    sixel_cmd_count = 0;
    sixel_cmd_accum = 0;
    sixel_cmd_has_digit = 0;
    sixel_active = 1;
}

// Grow sixel image buffer if needed to accommodate pixel at (x, y)
static void sixel_grow(int x, int y) {
    if (x < sixel_alloc_w && y < sixel_alloc_h) return;

    int new_w = sixel_alloc_w;
    int new_h = sixel_alloc_h;
    while (new_w <= x) new_w *= 2;
    while (new_h <= y) new_h *= 2;
    if (new_w > 8192) new_w = 8192;
    if (new_h > 8192) new_h = 8192;

    uint32_t *new_buf = calloc((size_t)new_w * new_h, sizeof(uint32_t));
    if (!new_buf) return;

    // Copy old rows
    if (sixel_image) {
        int copy_w = (sixel_alloc_w < new_w) ? sixel_alloc_w : new_w;
        int copy_h = (sixel_alloc_h < new_h) ? sixel_alloc_h : new_h;
        for (int row = 0; row < copy_h; row++) {
            memcpy(new_buf + row * new_w,
                   sixel_image + row * sixel_alloc_w,
                   copy_w * sizeof(uint32_t));
        }
        free(sixel_image);
    }

    sixel_image = new_buf;
    sixel_alloc_w = new_w;
    sixel_alloc_h = new_h;
}

// Write a single pixel into the sixel image buffer
static void sixel_put_pixel(int x, int y, uint32_t color) {
    if (x < 0 || y < 0) return;
    if (x >= 8192 || y >= 8192) return;

    if (x >= sixel_alloc_w || y >= sixel_alloc_h) {
        sixel_grow(x, y);
    }
    if (x >= sixel_alloc_w || y >= sixel_alloc_h) return;

    sixel_image[y * sixel_alloc_w + x] = color;

    // Track actual image extents
    if (x + 1 > sixel_img_w) sixel_img_w = x + 1;
    if (y + 1 > sixel_img_h) sixel_img_h = y + 1;
}

// Process a sixel data byte (0x3F-0x7E maps to 6-bit pattern)
static void sixel_process_data(unsigned char c) {
    int pattern = c - 0x3F;  // 6-bit value: bits 0-5 correspond to rows 0-5
    uint32_t color = sixel_palette[sixel_cur_color];

    int count = (sixel_repeat > 0) ? (int)sixel_repeat : 1;
    sixel_repeat = 0;

    for (int rep = 0; rep < count; rep++) {
        for (int bit = 0; bit < 6; bit++) {
            if (pattern & (1 << bit)) {
                sixel_put_pixel(sixel_x, sixel_y + bit, color);
            }
        }
        sixel_x++;
    }
}

// HLS to RGB conversion helper
static void sixel_hls_to_rgb(int h, int l, int s, int *r, int *g, int *b) {
    if (s == 0) {
        // Achromatic
        *r = *g = *b = (l * 255) / 100;
        return;
    }

    double hue = h / 360.0;
    double light = l / 100.0;
    double sat = s / 100.0;

    double m2 = (light <= 0.5) ? light * (1.0 + sat) : light + sat - light * sat;
    double m1 = 2.0 * light - m2;

    // Helper to convert hue component
    #define HUE_TO_RGB(p, q, t) do { \
        double _t = (t); \
        if (_t < 0) _t += 1.0; \
        if (_t > 1) _t -= 1.0; \
        if (_t < 1.0/6.0) result = (p) + ((q)-(p)) * 6.0 * _t; \
        else if (_t < 0.5) result = (q); \
        else if (_t < 2.0/3.0) result = (p) + ((q)-(p)) * (2.0/3.0 - _t) * 6.0; \
        else result = (p); \
    } while(0)

    double result;
    HUE_TO_RGB(m1, m2, hue + 1.0/3.0);
    *r = (int)(result * 255.0 + 0.5);
    HUE_TO_RGB(m1, m2, hue);
    *g = (int)(result * 255.0 + 0.5);
    HUE_TO_RGB(m1, m2, hue - 1.0/3.0);
    *b = (int)(result * 255.0 + 0.5);

    #undef HUE_TO_RGB
}

// Flush a completed inline command (#, ", !)
static void sixel_flush_cmd(void) {
    // Finalize accumulator into params
    if (sixel_cmd_has_digit && sixel_cmd_count < 8) {
        sixel_cmd_params[sixel_cmd_count++] = sixel_cmd_accum;
    }

    switch (sixel_cmd) {
        case '#': {
            // Color command: #Pc or #Pc;Pu;Px;Py;Pz
            if (sixel_cmd_count < 1) break;
            int pc = sixel_cmd_params[0];
            if (pc < 0 || pc >= SIXEL_MAX_COLORS) break;

            if (sixel_cmd_count == 1) {
                // Select color
                sixel_cur_color = pc;
            } else if (sixel_cmd_count >= 5) {
                int pu = sixel_cmd_params[1];
                int px = sixel_cmd_params[2];
                int py = sixel_cmd_params[3];
                int pz = sixel_cmd_params[4];

                if (pu == 2) {
                    // RGB: values 0-100, scale to 0-255
                    int r = (px * 255 + 50) / 100;
                    int g = (py * 255 + 50) / 100;
                    int b = (pz * 255 + 50) / 100;
                    if (r > 255) r = 255;
                    if (g > 255) g = 255;
                    if (b > 255) b = 255;
                    sixel_palette[pc] = 0xFF000000 | ((uint32_t)r << 16) | ((uint32_t)g << 8) | (uint32_t)b;
                } else if (pu == 1) {
                    // HLS
                    int r, g, b;
                    sixel_hls_to_rgb(px, py, pz, &r, &g, &b);
                    if (r > 255) r = 255; if (r < 0) r = 0;
                    if (g > 255) g = 255; if (g < 0) g = 0;
                    if (b > 255) b = 255; if (b < 0) b = 0;
                    sixel_palette[pc] = 0xFF000000 | ((uint32_t)r << 16) | ((uint32_t)g << 8) | (uint32_t)b;
                }
                sixel_cur_color = pc;
            }
            break;
        }
        case '"': {
            // Raster attributes: "Pan;Pad;Ph;Pv — pre-allocate if dimensions given
            if (sixel_cmd_count >= 4) {
                int ph = sixel_cmd_params[2];
                int pv = sixel_cmd_params[3];
                if (ph > 0 && pv > 0 && ph <= 8192 && pv <= 8192) {
                    sixel_grow(ph - 1, pv - 1);
                }
            }
            break;
        }
        case '!': {
            // Repeat: !Pn — set repeat count for next data byte
            if (sixel_cmd_count >= 1 && sixel_cmd_params[0] > 0) {
                sixel_repeat = (unsigned long)sixel_cmd_params[0];
            }
            break;
        }
    }

    sixel_cmd = 0;
    sixel_cmd_count = 0;
    sixel_cmd_accum = 0;
    sixel_cmd_has_digit = 0;
}

// Finalize sixel image and blit to screen
static void sixel_end(void) {
    if (!sixel_active) return;
    sixel_active = 0;

    // Flush any pending command
    if (sixel_cmd) {
        sixel_flush_cmd();
    }

    if (sixel_image && sixel_img_w > 0 && sixel_img_h > 0) {
        // Blit to screen pixel buffer
        macos_ciolib_blit_sixel(sixel_image, sixel_origin_x, sixel_origin_y,
                                sixel_alloc_w, sixel_img_h);

        // Diagnostic: count non-transparent and non-black pixels
        {
            int nonzero = 0, nonblack = 0;
            for (int py = 0; py < sixel_img_h && py < sixel_alloc_h; py++) {
                for (int px = 0; px < sixel_img_w && px < sixel_alloc_w; px++) {
                    uint32_t p = sixel_image[py * sixel_alloc_w + px];
                    if (p != 0) nonzero++;
                    if (p != 0 && p != 0xFF000000) nonblack++;
                }
            }
        }

        // Position cursor below the image, scrolling if needed.
        // The pixel buffer is scrolled in sync by wscroll(), so the
        // visible portion of the image shifts up correctly.
        int font_h = sixel_get_font_height();
        int rows_used = (sixel_img_h + font_h - 1) / font_h;
        int new_y = ciolib_wherey() + rows_used;

        struct text_info ti;
        ciolib_gettextinfo(&ti);
        while (new_y > ti.screenheight) {
            ciolib_wscroll();
            new_y--;
        }
        ciolib_gotoxy(1, new_y);
    }

    sixel_free();
}

// Free sixel image buffer and reset state
static void sixel_free(void) {
    if (sixel_image) {
        free(sixel_image);
        sixel_image = NULL;
    }
    sixel_alloc_w = 0;
    sixel_alloc_h = 0;
    sixel_img_w = 0;
    sixel_img_h = 0;
    sixel_x = 0;
    sixel_y = 0;
    sixel_cur_color = 0;
    sixel_repeat = 0;
    sixel_cmd = 0;
    sixel_active = 0;
}

// Reset ANSI parser state for clean connection
void cterm_reset_ansi_state(void) {
    ansi_state = 0;
    ansi_param_len = 0;
    ansi_response_len = 0;
    ice_mode_enabled = 0;
    bold_mode_enabled = 0;
    underline_enabled = 0;
    saved_cursor_x = 1;
    saved_cursor_y = 1;
    cterm_last_printed_char = 0;
    osc_buffer_len = 0;
    dcs_param_len = 0;
    sixel_free();
}

static void process_ansi_sequence(void) {
    // Parse CSI parameters
    int params[16] = {0};
    int param_count = 0;
    int has_digits = 0;
    // Track intermediate bytes (0x20-0x2F, e.g. SP in "CSI Ps SP D")
    char intermediate = 0;

    // Parse parameters from ansi_params buffer (excludes the final command char)
    for (int i = 0; i < ansi_param_len; i++) {
        char c = ansi_params[i];
        if (c >= '0' && c <= '9') {
            if (params[param_count] <= 100000)
                params[param_count] = params[param_count] * 10 + (c - '0');
            has_digits = 1;
        } else if (c == ';') {
            if (param_count < 15) param_count++;
            has_digits = 0;
        } else if (c >= 0x20 && c <= 0x2F) {
            // Intermediate byte (space, !, ", #, etc.)
            intermediate = c;
        } else if (c >= '@') {
            // Command character - stop parsing
            break;
        }
    }
    // Count the last parameter if we had digits
    if (has_digits || param_count > 0) {
        param_count++;
    }

    // Get the command character (last char in buffer)
    char cmd = 0;
    for (int i = ansi_param_len - 1; i >= 0; i--) {
        if (ansi_params[i] >= '@' && ansi_params[i] <= '~') {
            cmd = ansi_params[i];
            break;
        }
    }

    // Handle sequences with intermediate bytes first
    if (intermediate == ' ' && cmd == 'D') {
        // CSI Ps1 ; Ps2 SP D — Font Selection (FNT)
        // Ps1 = font slot (0=default, 1=bold, 2=blink, 3=both), Ps2 = font number
        int font_slot = (param_count >= 1) ? params[0] : 0;
        int font_num = (param_count >= 2) ? params[1] : 0;
        if (font_num >= 0 && font_num < 256) {
            ciolib_setfont(font_num, 0, font_slot);
        }
        return;
    }

    // Skip other sequences with intermediate bytes (we don't handle them)
    if (intermediate != 0) return;

    switch (cmd) {
        case 'H': case 'f':  // Cursor position
            {
                int target_x = params[1] > 0 ? params[1] : 1;
                int target_y = params[0] > 0 ? params[0] : 1;
                ciolib_gotoxy(target_x, target_y);
            }
            break;
        case 'A':  // Cursor up - clamp to top of screen
            { int y = ciolib_wherey() - (params[0] > 0 ? params[0] : 1);
              if (y < 1) y = 1;
              ciolib_gotoxy(ciolib_wherex(), y); }
            break;
        case 'B':  // Cursor down - clamp to bottom of screen
            { struct text_info bti;
              ciolib_gettextinfo(&bti);
              int y = ciolib_wherey() + (params[0] > 0 ? params[0] : 1);
              if (y > bti.screenheight) y = bti.screenheight;
              ciolib_gotoxy(ciolib_wherex(), y); }
            break;
        case 'C':  // Cursor forward - clamp to right edge
            { struct text_info cti;
              ciolib_gettextinfo(&cti);
              int x = ciolib_wherex() + (params[0] > 0 ? params[0] : 1);
              if (x > cti.screenwidth) x = cti.screenwidth;
              ciolib_gotoxy(x, ciolib_wherey()); }
            break;
        case 'D':  // Cursor back
            { int x = ciolib_wherex() - (params[0] > 0 ? params[0] : 1);
              if (x < 1) x = 1;
              ciolib_gotoxy(x, ciolib_wherey()); }
            break;
        case 'J':  // Erase in Display
            if (params[0] == 0 || param_count == 0) {
                // ESC[0J or ESC[J - Clear from cursor to end of screen
                ciolib_clreol();  // Clear rest of current line
                {
                    struct text_info jti;
                    ciolib_gettextinfo(&jti);
                    int saved_x = ciolib_wherex();
                    int saved_y = ciolib_wherey();
                    for (int line = saved_y + 1; line <= jti.screenheight; line++) {
                        ciolib_gotoxy(1, line);
                        ciolib_clreol();
                    }
                    ciolib_gotoxy(saved_x, saved_y);
                }
            } else if (params[0] == 1) {
                // ESC[1J - Clear from start of screen to cursor
                {
                    struct text_info jti;
                    ciolib_gettextinfo(&jti);
                    int saved_x = ciolib_wherex();
                    int saved_y = ciolib_wherey();
                    for (int line = 1; line < saved_y; line++) {
                        ciolib_gotoxy(1, line);
                        ciolib_clreol();
                    }
                    // Clear current line from start to cursor
                    ciolib_gotoxy(1, saved_y);
                    for (int i = 1; i <= saved_x; i++) {
                        ciolib_putch(' ');
                    }
                    ciolib_gotoxy(saved_x, saved_y);
                }
            } else if (params[0] == 2) {
                // ESC[2J - Clear entire screen
                ciolib_clrscr();
            }
            break;
        case 'K':  // Erase in Line
            if (params[0] == 0 || param_count == 0) {
                // ESC[0K or ESC[K - Clear from cursor to end of line
                ciolib_clreol();
            } else if (params[0] == 1) {
                // ESC[1K - Clear from start of line to cursor
                {
                    int saved_x = ciolib_wherex();
                    int cur_y = ciolib_wherey();
                    ciolib_gotoxy(1, cur_y);
                    for (int i = 1; i <= saved_x; i++) {
                        ciolib_putch(' ');
                    }
                    ciolib_gotoxy(saved_x, cur_y);
                }
            } else if (params[0] == 2) {
                // ESC[2K - Clear entire line
                {
                    int saved_x = ciolib_wherex();
                    int cur_y = ciolib_wherey();
                    ciolib_gotoxy(1, cur_y);
                    ciolib_clreol();
                    ciolib_gotoxy(saved_x, cur_y);
                }
            }
            break;
        case 'm':  // SGR - Set Graphics Rendition
            if (param_count == 0) {
                // ESC[m with no params means reset
                ciolib_textattr(7);
                ice_mode_enabled = 0;
                bold_mode_enabled = 0;
                underline_enabled = 0;
                ciolib_setunderline(false);
            }
            for (int i = 0; i < param_count; i++) {
                int p = params[i];
                if (p == 0) {
                    ciolib_textattr(7);  // Reset
                    ice_mode_enabled = 0;
                    bold_mode_enabled = 0;
                    underline_enabled = 0;
                    ciolib_setunderline(false);
                }
                else if (p == 1) {
                    // Bold/bright - enable bright foreground mode
                    bold_mode_enabled = 1;
                    ciolib_highvideo();  // Also brighten current foreground
                }
                else if (p == 2 || p == 22) {
                    // Dim or normal intensity - disable bold
                    bold_mode_enabled = 0;
                    ciolib_lowvideo();
                }
                else if (p == 4) {
                    // Underline
                    underline_enabled = 1;
                    ciolib_setunderline(true);
                }
                else if (p == 5) {
                    // Blink/iCE mode - enable bright backgrounds
                    ice_mode_enabled = 1;
                    ciolib_brightbackground();  // Also brighten current background
                }
                else if (p == 7) ciolib_reversevideo();  // Reverse video - swap fg/bg
                else if (p == 24) {
                    // SGR 24 - disable underline
                    underline_enabled = 0;
                    ciolib_setunderline(false);
                }
                else if (p == 25) {
                    // SGR 25 - disable blink/iCE mode
                    ice_mode_enabled = 0;
                }
                else if (p >= 30 && p <= 37) {
                    // Map ANSI color to CGA palette index
                    int fg = ansi_to_cga[p - 30];
                    // If bold mode is enabled, add 8 for bright foreground
                    if (bold_mode_enabled && fg < 8) {
                        fg += 8;
                    }
                    ciolib_textcolor(fg);
                }
                else if (p >= 40 && p <= 47) {
                    // Map ANSI color to CGA palette index
                    int bg = ansi_to_cga[p - 40];
                    // If iCE mode is enabled, add 8 for bright background
                    if (ice_mode_enabled && bg < 8) {
                        bg += 8;
                    }
                    ciolib_textbackground(bg);
                }
                else if (p >= 90 && p <= 97) {
                    // Bright FG colors - map and add 8 for bright
                    ciolib_textcolor(ansi_to_cga[p - 90] + 8);
                }
                else if (p >= 100 && p <= 107) {
                    // Bright BG colors - map and add 8 for bright
                    ciolib_textbackground(ansi_to_cga[p - 100] + 8);
                }
            }
            break;
        case 's':  // Save cursor position
            saved_cursor_x = ciolib_wherex();
            saved_cursor_y = ciolib_wherey();
            break;
        case 'u':  // Restore cursor position
            ciolib_gotoxy(saved_cursor_x, saved_cursor_y);
            break;
        case 'n':  // Device Status Report
            if (params[0] == 6) {
                // Cursor Position Report - respond with ESC[row;colR
                int row = ciolib_wherey();
                int col = ciolib_wherex();
                ansi_response_len = snprintf(ansi_response, sizeof(ansi_response),
                                             "\033[%d;%dR", row, col);
            } else if (params[0] == 5) {
                // Device Status Report - respond "OK"
                ansi_response_len = snprintf(ansi_response, sizeof(ansi_response), "\033[0n");
            }
            break;
        case 'c':  // Device Attributes (DA1)
            // Only respond to ESC[c or ESC[0c (standard DA1 query).
            // Skip if private marker (?, >, <, =) is present — those are
            // different DA variants that BBS systems don't expect responses to,
            // or may be part of ANSI art that accidentally ends with 'c'.
            {
                int has_private = 0;
                for (int pi = 0; pi < ansi_param_len; pi++) {
                    char pc = ansi_params[pi];
                    if (pc == '?' || pc == '>' || pc == '<' || pc == '=') {
                        has_private = 1;
                        break;
                    }
                }
                if (!has_private && (param_count == 0 || (param_count == 1 && params[0] == 0))) {
                    ansi_response_len = snprintf(ansi_response, sizeof(ansi_response), "\033[?6c");
                }
            }
            break;
        case 'G': case '`':  // CHA/HPA - Cursor Horizontal Absolute
            {
                int col = params[0] > 0 ? params[0] : 1;
                ciolib_gotoxy(col, ciolib_wherey());
            }
            break;
        case 'd':  // VPA - Cursor Vertical Absolute (line position)
            {
                int row = params[0] > 0 ? params[0] : 1;
                ciolib_gotoxy(ciolib_wherex(), row);
            }
            break;
        case 'E':  // CNL - Cursor Next Line (move down N lines, to column 1)
            {
                struct text_info eti;
                ciolib_gettextinfo(&eti);
                int n = params[0] > 0 ? params[0] : 1;
                int y = ciolib_wherey() + n;
                if (y > eti.screenheight) y = eti.screenheight;
                ciolib_gotoxy(1, y);
            }
            break;
        case 'F':  // CPL - Cursor Previous Line (move up N lines, to column 1)
            {
                int n = params[0] > 0 ? params[0] : 1;
                int y = ciolib_wherey() - n;
                if (y < 1) y = 1;
                ciolib_gotoxy(1, y);
            }
            break;
        case 'L':  // IL - Insert Line(s)
            {
                int n = params[0] > 0 ? params[0] : 1;
                for (int j = 0; j < n; j++) {
                    ciolib_insline();
                }
            }
            break;
        case 'M':  // DL - Delete Line(s)
            {
                int n = params[0] > 0 ? params[0] : 1;
                for (int j = 0; j < n; j++) {
                    ciolib_delline();
                }
            }
            break;
        case '@':  // ICH - Insert Character(s) (shift line right, insert blanks)
            {
                int n = params[0] > 0 ? params[0] : 1;
                struct text_info ati;
                ciolib_gettextinfo(&ati);
                int cx = ciolib_wherex();
                int cy = ciolib_wherey();
                int w = ati.screenwidth;
                if (cx <= w) {
                    int line_len = w - cx + 1;
                    if (n < line_len) {
                        ciolib_movetext(cx, cy, w - n, cy, cx + n, cy);
                    }
                    // Fill inserted area with spaces
                    ciolib_gotoxy(cx, cy);
                    for (int j = 0; j < n && cx + j <= w; j++) {
                        ciolib_putch(' ');
                    }
                    ciolib_gotoxy(cx, cy);
                }
            }
            break;
        case 'P':  // DCH - Delete Character(s) (shift line left, blank at end)
            {
                int n = params[0] > 0 ? params[0] : 1;
                struct text_info pti;
                ciolib_gettextinfo(&pti);
                int cx = ciolib_wherex();
                int cy = ciolib_wherey();
                int w = pti.screenwidth;
                if (cx <= w) {
                    int chars_remaining = w - cx + 1;
                    if (n < chars_remaining) {
                        // Shift chars left
                        ciolib_movetext(cx + n, cy, w, cy, cx, cy);
                    }
                    // Fill end of line with spaces
                    int blank_start = w - n + 1;
                    if (blank_start < cx) blank_start = cx;
                    int save_x = ciolib_wherex();
                    int save_y = ciolib_wherey();
                    ciolib_gotoxy(blank_start, cy);
                    for (int j = blank_start; j <= w; j++) {
                        ciolib_putch(' ');
                    }
                    ciolib_gotoxy(save_x, save_y);
                }
            }
            break;
        case 'X':  // ECH - Erase Character(s) (overwrite with spaces, don't move cursor)
            {
                int n = params[0] > 0 ? params[0] : 1;
                struct text_info xti;
                ciolib_gettextinfo(&xti);
                int cx = ciolib_wherex();
                int cy = ciolib_wherey();
                for (int j = 0; j < n && cx + j <= xti.screenwidth; j++) {
                    ciolib_gotoxy(cx + j, cy);
                    ciolib_putch(' ');
                }
                ciolib_gotoxy(cx, cy);
            }
            break;
        case 'S':  // SU - Scroll Up
            {
                int n = params[0] > 0 ? params[0] : 1;
                for (int j = 0; j < n; j++) {
                    ciolib_wscroll();
                }
            }
            break;
        case 'T':  // SD - Scroll Down (reverse scroll)
            {
                struct text_info tti;
                ciolib_gettextinfo(&tti);
                int n = params[0] > 0 ? params[0] : 1;
                // Save cursor, go to top, insert lines, restore cursor
                int save_x = ciolib_wherex();
                int save_y = ciolib_wherey();
                ciolib_gotoxy(1, 1);
                for (int j = 0; j < n; j++) {
                    ciolib_insline();
                }
                ciolib_gotoxy(save_x, save_y);
            }
            break;
        case 'b':  // REP - Repeat previous graphic character
            {
                int n = params[0] > 0 ? params[0] : 1;
                if (cterm_last_printed_char != 0) {
                    for (int j = 0; j < n; j++) {
                        ciolib_putch(cterm_last_printed_char);
                    }
                }
            }
            break;
        case 'h':  // SM / DECSET - Set Mode
        case 'l':  // RM / DECRST - Reset Mode
            {
                int is_private = 0;
                int priv_params[16] = {0};
                int priv_count = 0;
                int priv_has_digits = 0;
                for (int pi = 0; pi < ansi_param_len - 1; pi++) {
                    char pc = ansi_params[pi];
                    if (pc == '?') {
                        is_private = 1;
                    } else if (pc >= '0' && pc <= '9') {
                        if (priv_params[priv_count] <= 100000)
                            priv_params[priv_count] = priv_params[priv_count] * 10 + (pc - '0');
                        priv_has_digits = 1;
                    } else if (pc == ';') {
                        if (priv_count < 15) priv_count++;
                        priv_has_digits = 0;
                    }
                }
                if (priv_has_digits || priv_count > 0) priv_count++;

                if (is_private) {
                    for (int pi = 0; pi < priv_count; pi++) {
                        switch (priv_params[pi]) {
                            case 25:  // DECTCEM - Cursor visibility
                                if (cmd == 'h') {
                                    cterm_cursor = 1;
                                    // Restore during cterm_write epilogue
                                } else {
                                    cterm_cursor = 0;
                                    ciolib_setcursortype(_NOCURSOR);
                                }
                                break;
                            case 7:  // DECAWM - Auto-wrap mode
                                break;
                            default:
                                break;
                        }
                    }
                }
            }
            break;
        default:
            break;
    }
}

size_t cterm_write(struct cterminal *cterm, const void *buf, int buflen,
                   char *retbuf, size_t retsize, int *speed) {
    if (speed) *speed = 0;
    if (retbuf && retsize > 0) retbuf[0] = '\0';
    ansi_response_len = 0;  // Clear any previous response

    const unsigned char *data = (const unsigned char *)buf;

    for (int i = 0; i < buflen; i++) {
        unsigned char c = data[i];

        switch (ansi_state) {
            case 0:  // Normal state
                if (c == 27) {  // ESC
                    ansi_state = 1;
                } else if (c == 0x9B) {
                    // 8-bit CSI (used by Amiga terminals instead of ESC[)
                    ansi_state = 2;
                    ansi_param_len = 0;
                    memset(ansi_params, 0, sizeof(ansi_params));
                } else if (c == '\r') {
                    ciolib_gotoxy(1, ciolib_wherey());
                } else if (c == '\n') {
                    int y = ciolib_wherey();
                    struct text_info ti;
                    ciolib_gettextinfo(&ti);
                    if (y >= ti.screenheight) {
                        ciolib_wscroll();
                    } else {
                        ciolib_gotoxy(ciolib_wherex(), y + 1);
                    }
                } else if (c == '\b') {
                    int x = ciolib_wherex();
                    if (x > 1) ciolib_gotoxy(x - 1, ciolib_wherey());
                } else if (c == '\t') {
                    int x = ciolib_wherex();
                    int next_tab = ((x - 1) / 8 + 1) * 8 + 1;
                    ciolib_gotoxy(next_tab, ciolib_wherey());
                } else if (c == 7) {
                    // Bell - handled elsewhere
                } else if (c == 0) {
                    // NUL - ignore (telnet sends CR+NUL for bare carriage return)
                } else {
                    // All printable characters including CP437 graphics (0x01-0x1F)
                    // In CP437, characters 1-31 have graphical glyphs
                    ciolib_putch(c);
                    cterm_last_printed_char = c;
                }
                break;

            case 1:  // Got ESC
                if (c == '[') {
                    ansi_state = 2;
                    ansi_param_len = 0;
                    memset(ansi_params, 0, sizeof(ansi_params));
                } else if (c == ']') {
                    // Start OSC sequence (ESC])
                    ansi_state = 3;
                    osc_buffer_len = 0;
                } else if (c == 'P') {
                    // Start DCS sequence (ESC P)
                    ansi_state = 5;
                    dcs_param_len = 0;
                } else {
                    ansi_state = 0;
                }
                break;

            case 2:  // In CSI sequence
                if (c >= '@' && c <= '~') {
                    // Final character
                    if (ansi_param_len < (int)sizeof(ansi_params) - 1) {
                        ansi_params[ansi_param_len++] = c;
                    }
                    process_ansi_sequence();
                    ansi_state = 0;
                } else if (c >= 0x20 && c <= 0x3F) {
                    // Parameter byte
                    if (ansi_param_len < (int)sizeof(ansi_params) - 1) {
                        ansi_params[ansi_param_len++] = c;
                    } else {
                        // Sequence too long - discard as malformed
                        ansi_state = 0;
                        ansi_param_len = 0;
                    }
                } else {
                    // Invalid, reset
                    ansi_state = 0;
                }
                break;

            case 3:  // In OSC sequence - accumulating characters
                if (c == 0x07) {
                    // BEL terminates OSC (xterm-style)
                    dispatch_osc();
                    ansi_state = 0;
                } else if (c == 27) {
                    // ESC - might be start of ST (ESC\)
                    ansi_state = 4;
                } else {
                    // Accumulate character
                    if (osc_buffer_len < OSC_BUFFER_SIZE - 1) {
                        osc_buffer[osc_buffer_len++] = (char)c;
                    } else {
                        // Buffer overflow - abort OSC
                        osc_buffer_len = 0;
                        ansi_state = 0;
                    }
                }
                break;

            case 4:  // OSC got ESC - awaiting backslash for ST (ESC\)
                if (c == '\\') {
                    // ST complete - dispatch OSC
                    dispatch_osc();
                } else {
                    // Not a valid ST - abort OSC
                    osc_buffer_len = 0;
                }
                ansi_state = 0;
                break;

            case 5:  // DCS parameter collection
                if (c == 0x18 || c == 0x1A) {
                    // CAN or SUB — abort DCS
                    ansi_state = 0;
                } else if (c == 0x9C) {
                    // 8-bit ST — abort (empty DCS)
                    ansi_state = 0;
                } else if (c >= 0x30 && c <= 0x3F) {
                    // Parameter byte (digits, semicolons, etc.)
                    if (dcs_param_len < (int)sizeof(dcs_params) - 1) {
                        dcs_params[dcs_param_len++] = (char)c;
                    }
                } else if (c == 'q') {
                    // Sixel data follows
                    dcs_params[dcs_param_len] = '\0';
                    sixel_begin();
                    ansi_state = 6;
                } else if (c >= 0x40 && c <= 0x7E) {
                    // Non-Sixel DCS final byte — skip body
                    ansi_state = 8;
                } else if (c == 27) {
                    // ESC inside DCS params
                    ansi_state = 7;
                } else if (c >= 0x20 && c <= 0x2F) {
                    // Intermediate byte — still collecting, store
                    if (dcs_param_len < (int)sizeof(dcs_params) - 1) {
                        dcs_params[dcs_param_len++] = (char)c;
                    }
                } else {
                    // Invalid byte — abort
                    ansi_state = 0;
                }
                break;

            case 6: {  // Sixel data stream
                // First check for sequence-aborting control chars
                if (c == 0x18 || c == 0x1A) {
                    // CAN or SUB — abort Sixel
                    sixel_free();
                    ansi_state = 0;
                    break;
                }
                if (c == 0x9C) {
                    // 8-bit ST — end Sixel
                    sixel_end();
                    ansi_state = 0;
                    break;
                }
                if (c == 27) {
                    // ESC — might be ST (ESC \)
                    if (sixel_cmd) sixel_flush_cmd();
                    ansi_state = 7;
                    break;
                }

                if (sixel_cmd != 0) {
                    // We're inside an inline command (#, ", !)
                    if (c >= '0' && c <= '9') {
                        sixel_cmd_accum = sixel_cmd_accum * 10 + (c - '0');
                        sixel_cmd_has_digit = 1;
                    } else if (c == ';') {
                        if (sixel_cmd_count < 8) {
                            sixel_cmd_params[sixel_cmd_count++] = sixel_cmd_accum;
                        }
                        sixel_cmd_accum = 0;
                        sixel_cmd_has_digit = 0;
                    } else {
                        // End of inline command — flush and fall through
                        sixel_flush_cmd();
                        goto sixel_dispatch;
                    }
                } else {
                sixel_dispatch:
                    if (c >= 0x3F && c <= 0x7E) {
                        // Sixel data byte
                        sixel_process_data(c);
                    } else if (c == '#') {
                        sixel_cmd = '#';
                        sixel_cmd_count = 0;
                        sixel_cmd_accum = 0;
                        sixel_cmd_has_digit = 0;
                    } else if (c == '"') {
                        sixel_cmd = '"';
                        sixel_cmd_count = 0;
                        sixel_cmd_accum = 0;
                        sixel_cmd_has_digit = 0;
                    } else if (c == '!') {
                        sixel_cmd = '!';
                        sixel_cmd_count = 0;
                        sixel_cmd_accum = 0;
                        sixel_cmd_has_digit = 0;
                    } else if (c == '$') {
                        // Sixel carriage return
                        sixel_x = 0;
                    } else if (c == '-') {
                        // Sixel new line
                        sixel_y += 6;
                        sixel_x = 0;
                    }
                    // Ignore other bytes (whitespace, etc.)
                }
                break;
            }

            case 7:  // DCS/Sixel got ESC — awaiting backslash for ST
                if (c == '\\') {
                    // String Terminator — end DCS/Sixel
                    if (sixel_active) {
                        sixel_end();
                    }
                } else {
                    // Not ST — abort
                    if (sixel_active) {
                        sixel_free();
                    }
                }
                ansi_state = 0;
                break;

            case 8:  // Skip non-Sixel DCS body
                if (c == 27) {
                    ansi_state = 7;
                } else if (c == 0x9C) {
                    // 8-bit ST — end DCS
                    ansi_state = 0;
                } else if (c == 0x18 || c == 0x1A) {
                    // CAN or SUB — abort DCS
                    ansi_state = 0;
                }
                // Discard everything else until terminator
                break;
        }
    }

    // Copy any ANSI response to retbuf (for cursor position reports, device attributes, etc.)
    size_t response_written = 0;
    if (ansi_response_len > 0 && retbuf && retsize > 0) {
        int copy_len = ansi_response_len;
        if (copy_len >= (int)retsize) {
            copy_len = (int)retsize - 1;
        }
        memcpy(retbuf, ansi_response, copy_len);
        retbuf[copy_len] = '\0';
        response_written = (size_t)copy_len;
        ansi_response_len = 0;  // Clear after copying
    }

    return response_written;
}

void cterm_clearscreen(struct cterminal *cterm, char attr) {
    // Stub - actual clear handled in iOS ciolib implementation
    (void)cterm;
    (void)attr;
}

#else /* USE_REAL_CTERM — macOS MIGRATION 2026-09-04 */

// The real cterm.c supplies cterm_init/start/end/write/clearscreen. This shim
// exists because native_connect() calls cterm_reset_ansi_state() to clear
// leftover escape state between connections. The real engine keeps its parser
// state inside the cterminal struct (re-created per connection via cterm_init),
// so a no-op is correct here — and matches both Android, which has no
// equivalent reset at all, and the shipping iOS build.
void cterm_reset_ansi_state(void) { }

#endif /* USE_REAL_CTERM */

// ============================================================================
// Utility Functions
// ============================================================================

// Note: safe_snprintf() is now provided by xpdev/genwrap.c
