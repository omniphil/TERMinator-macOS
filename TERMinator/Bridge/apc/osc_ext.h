/*
 * osc_ext.h -- OSC 8 hyperlinks, OSC 52 clipboard writes, OSC 0/2 window titles and the Rainwire:Caps answer.
 * See osc_ext.c and PORT_TO_MAC_LINUX.md 12.62. The same two files are in every client (Windows is the master):
 *   Windows  native/osc_ext.[ch]            Linux  native/apc/osc_ext.[ch]
 *   macOS    TERMinator/Bridge/apc/osc_ext.[ch]   iOS  TERMinator/Bridge/apc/osc_ext.[ch]
 *   Android  app/src/main/cpp/apc/osc_ext.[ch]
 */
#ifndef OSC_EXT_H
#define OSC_EXT_H

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

struct cterminal;

#if defined(_WIN32)
#define OSC_EXT_EXPORT __declspec(dllexport)
#else
#define OSC_EXT_EXPORT __attribute__((visibility("default")))
#endif

/* The answer to ESC _ Rainwire:Caps;Query ESC \ (Rainwire/docs/CLIENT_CAPS.md): these fixed keys, then the app's
 * own (syncterm_osc_set_info), all inside ESC _ ... ESC \ */
#define OSC_EXT_CAPS_FIXED  "Rainwire:Caps;Info;v=1;osc8=1;osc52=1;title=1;truecolor=1;pic=1;plat=mac"
#define OSC_EXT_INFO_MAX    256           /* bytes of the app's own keys */

#define OSC_EXT_URI_MAX     2048          /* a longer OSC 8 URI is ignored (its text shows, unlinked) */
#define OSC_EXT_TITLE_MAX   128           /* bytes of UTF-8 kept from an OSC 0/2 title */
#define OSC_EXT_CLIP_MAX    (64 * 1024)   /* decoded bytes; a bigger OSC 52 is ignored */
#define OSC_EXT_NOTE_TITLE_MAX  64        /* bytes of UTF-8 kept from an OSC 777 notification's title */
#define OSC_EXT_NOTE_BODY_MAX   256       /* ... and from its body */
#define OSC_EXT_NOTE_QUEUE      4         /* notifications waiting for the app; the oldest is dropped */
#define OSC_EXT_LINK_KIND_MAX   16        /* a linked window's kind, [a-z0-9_] (12.73) */
#define OSC_EXT_LINK_TOKEN_LEN  26        /* its token: upper-case Crockford base32 */
#define OSC_EXT_LINK_TITLE_MAX  64        /* bytes of UTF-8 kept from its title */
#define OSC_EXT_LINK_ARGS       16        /* key=value pairs kept per request (kind and token count) */
#define OSC_EXT_LINK_KEY_MAX    16        /* a key: [a-z0-9_] */
#define OSC_EXT_LINK_VALUE_MAX  128       /* bytes of UTF-8 kept from any other value */
#define OSC_EXT_LINK_POLL_MAX   (OSC_EXT_LINK_ARGS * (OSC_EXT_LINK_KEY_MAX + OSC_EXT_LINK_VALUE_MAX + 2))
#define OSC_EXT_LINK_QUEUE      4         /* link requests waiting for the app; the oldest is dropped */
#define OSC_EXT_LINK_OPEN       1         /* syncterm_osc_poll_link's answers */
#define OSC_EXT_LINK_RAISE      2

/* Installs the OSC handler and link hooks on cterm (cheap; call with the APC attach, before every cterm_write). */
void osc_ext_attach(struct cterminal *cterm);

/* Called for every APC string, next to the TRACE/WM handlers. Returns true for Rainwire:Caps;... (answered here) and
 * Rainwire:Link;... (queued for syncterm_osc_poll_link). */
bool osc_ext_apc_handler(const char *strbuf, size_t slen);

/* Disconnect: forgets links, the open link and anything not yet polled. */
void osc_ext_session_reset(void);

/* The OSC handler itself (cterm->osc_handler); exposed for the unit tests. */
void osc_ext_handle_osc(struct cterminal *cterm, const char *strbuf, size_t len);

/* ---- for the app (any thread) ---- */

/* A title the board set since the last call: copies it (UTF-8, NUL-terminated, control characters removed) and
 * returns its length; 0 = the board cleared it (show the normal title). -1 = nothing new. */
OSC_EXT_EXPORT int syncterm_osc_poll_title(char *buffer, int buffer_len);

/* Text the board put on the clipboard since the last call (only the latest is kept): copies it (raw bytes, normally
 * UTF-8, no NULs) and returns its length. 0 = nothing new, -1 = buffer too small (it stays pending). */
OSC_EXT_EXPORT int syncterm_osc_poll_clipboard(char *buffer, int buffer_len);

/* The link under screen cell (col, row), 0-based. ch is the character the app shows there (CP437 code, 0-255) or
 * -1 to skip the check: a cell whose character changed since the link was drawn is no longer a link. Copies the URI
 * (NUL-terminated) and returns its length, 0 = no link, -1 = a link but buffer is NULL or too small (so a NULL buffer
 * is a cheap "is this a link?"). span_start/span_end (may be NULL) get the first and last column of the link's run
 * on that row, whenever the cell is a link. */
OSC_EXT_EXPORT int syncterm_osc_link_at(int col, int row, int ch, char *buffer, int buffer_len,
                                        int *span_start, int *span_end);

/* The app's own keys for the Caps answer (12.72), ";"-separated key=value, e.g.
 * "app=1.4.9;lang=en-US;tz=America/Chicago;notify=1" (plus "touch=1" on Android/iOS). Call before each connect; NULL
 * or "" = none. Pairs with anything but [A-Za-z0-9._+/-] in the key or value are dropped; OSC_EXT_INFO_MAX bytes. */
OSC_EXT_EXPORT void syncterm_osc_set_info(const char *keys);

/* The oldest notification the board sent (ESC ] 777 ; notify ; title ; body ST) not yet taken: copies its title and
 * body (UTF-8, NUL-terminated, controls removed; cut to fit) and returns 1; 0 = none waiting. A disconnect drops them.
 * Buffers of OSC_EXT_NOTE_TITLE_MAX + 1 and OSC_EXT_NOTE_BODY_MAX + 1 bytes always fit. */
OSC_EXT_EXPORT int syncterm_osc_poll_notify(char *title, int title_len, char *body, int body_len);

/* The oldest linked-window request the board sent (ESC _ Rainwire:Link;Open|Raise;... ESC \, 12.73) not yet taken:
 * copies its arguments as "key=value" lines joined by '\n' (NUL-terminated, in the order sent, each key once; values
 * unescaped, UTF-8, controls removed, may be "") and returns OSC_EXT_LINK_OPEN or OSC_EXT_LINK_RAISE; 0 = none
 * waiting; -1 = it didn't fit in buffer (it's dropped). kind is always there and checked ([a-z0-9_]); on Open so is
 * token (26 characters of Crockford base32); title, cols, rows, place, focus and any later keys are the app's to
 * read or ignore. Bad requests never get here. A disconnect drops them. OSC_EXT_LINK_POLL_MAX bytes always fit. */
OSC_EXT_EXPORT int syncterm_osc_poll_link(char *buffer, int buffer_len);

/* 1 once the board has drawn a link this session (the app can skip link hit-tests until then), else 0. */
OSC_EXT_EXPORT int syncterm_osc_links_active(void);

#ifdef __cplusplus
}
#endif

#endif /* OSC_EXT_H */
