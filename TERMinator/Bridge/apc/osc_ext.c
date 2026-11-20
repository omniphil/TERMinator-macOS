/*
 * osc_ext.c -- xterm-style OSC extras for the board, and the capability answer that tells it they're here
 * (PORT_TO_MAC_LINUX.md 12.62, Rainwire/docs/CLIENT_CAPS.md). Windows is the master; the same file, unchanged, is in
 * every client (see osc_ext.h).
 *
 *   ESC ] 8 ; params ; URI ST  text  ESC ] 8 ; ; ST     hyperlink: the text's cells remember the URI, the app shows
 *                                                      a cue and asks "Open <URI>?" on a click/tap. Only http,
 *                                                      https, mailto, telnet and ssh, at most 2048 bytes, printable
 *                                                      ASCII; anything else draws its text unlinked.
 *   ESC ] 52 ; Pc ; base64 ST                          clipboard write (any Pc), at most 64 KB decoded; bad base64
 *                                                      is ignored. A read ("?") is NEVER answered.
 *   ESC ] 0 ; title ST,  ESC ] 2 ; title ST            window title: control characters removed, 128 bytes kept;
 *                                                      empty = back to the normal title. OSC 1 (icon) is ignored.
 *   ESC ] 777 ; notify ; title ; body ST                a notification (12.72): queued for the app, which shows it
 *                                                      only when TERMinator isn't in front. Title 64 bytes, body
 *                                                      256, cleaned like a window title.
 *   ESC _ Rainwire:Caps;Query ESC \                    answered at once, in order with the other probe replies:
 *       ESC _ Rainwire:Caps;Info;v=1;osc8=1;osc52=1;title=1;truecolor=1;pic=1;plat=win ESC \
 *       followed by the app's own keys (12.72, syncterm_osc_set_info): ;app=1.4.9;lang=en-US;tz=...;notify=1;touch=1
 *   ESC _ Rainwire:Link;Open;kind=mrc;token=<26>;title=<text>[;key=value...] ESC \
 *   ESC _ Rainwire:Link;Raise;kind=mrc ESC \        a linked window (12.73, Rainwire/docs/MRC_WINDOW.md): queued for
 *                                                      the app, which decides whether to open or raise it. Values use
 *                                                      %XX for % ; = and controls (as Rainwire:WM). Only sent to a
 *                                                      client whose app keys say mw=1; others never poll the queue.
 *                                                      kind and token are checked here; every other key=value goes to
 *                                                      the app as it is (unescaped, cleaned), so a new optional key
 *                                                      needs only app changes. Unknown verbs are ignored.
 * ST is ESC \ or BEL (cterm.c takes both for an OSC since 12.62).
 *
 * The link map: cterm.c calls cell_hook for every printable character it places while link_track is on, and
 * region_hook for clears and scrolls, so each screen cell carries the id of the link it was drawn under (0 = none)
 * and the character drawn. A lookup also checks that character against what the app shows, which catches the
 * paths that bypass the hooks (insert/delete line, RIS, sixel); a stale cell just stops being a link.
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#include <windows.h>
#else
#include <pthread.h>
#endif

#include "cterm.h"
#include "osc_ext.h"

/* apc_bridge.c, in every client */
void apc_send(const char *buf, size_t len);

#define CAPS_PREFIX      "Rainwire:Caps;"
#define CAPS_PREFIX_LEN  (sizeof(CAPS_PREFIX) - 1)
#define LINK_PREFIX      "Rainwire:Link;"
#define LINK_PREFIX_LEN  (sizeof(LINK_PREFIX) - 1)

#define MAP_COLS   512
#define MAP_ROWS   256
#define LINK_SLOTS 1024    /* ids 1..LINK_SLOTS-1, reused round-robin (a reused id's old cells are wiped) */

/* ---- lock ---- */

#if defined(_WIN32)
static INIT_ONCE        g_once = INIT_ONCE_STATIC_INIT;
static CRITICAL_SECTION g_cs;
static BOOL CALLBACK init_once(PINIT_ONCE once, PVOID param, PVOID *ctx)
{
	(void)once; (void)param; (void)ctx;
	InitializeCriticalSection(&g_cs);
	return TRUE;
}
static void lock(void)   { InitOnceExecuteOnce(&g_once, init_once, NULL, NULL); EnterCriticalSection(&g_cs); }
static void unlock(void) { LeaveCriticalSection(&g_cs); }
#else
static pthread_mutex_t g_mutex = PTHREAD_MUTEX_INITIALIZER;
static void lock(void)   { pthread_mutex_lock(&g_mutex); }
static void unlock(void) { pthread_mutex_unlock(&g_mutex); }
#endif

/* ---- state (under the lock) ---- */

static uint16_t *g_cell_id;     /* MAP_COLS * MAP_ROWS, allocated on the first link */
static uint8_t  *g_cell_ch;
static char     *g_links[LINK_SLOTS];
static int       g_next_id = 1;
static int       g_open_id;     /* the link new text is drawn under, 0 = none */
static int       g_last_id;     /* the link opened last */
static int       g_active;      /* a link was drawn this session */

static char      g_title[OSC_EXT_TITLE_MAX + 1];
static int       g_title_pending;

static uint8_t  *g_clip;
static size_t    g_clip_len;
static int       g_clip_pending;

struct note {
	char title[OSC_EXT_NOTE_TITLE_MAX + 1];
	char body[OSC_EXT_NOTE_BODY_MAX + 1];
};
static struct note g_notes[OSC_EXT_NOTE_QUEUE];
static int         g_note_count;

static char      g_info[OSC_EXT_INFO_MAX + 1];   /* the app's keys for the Caps answer, "" = none */

struct link_arg {
	char key[OSC_EXT_LINK_KEY_MAX + 1];           /* [a-z0-9_] */
	char value[OSC_EXT_LINK_VALUE_MAX + 1];       /* UTF-8, controls removed, may be "" */
};
struct link_req {
	int             verb;                         /* OSC_EXT_LINK_OPEN / OSC_EXT_LINK_RAISE */
	int             argc;
	struct link_arg args[OSC_EXT_LINK_ARGS];      /* in the order sent, each key once (the last value wins) */
};
static struct link_req g_link_reqs[OSC_EXT_LINK_QUEUE];
static int             g_link_count;

/* ---- helpers ---- */

static int ieq_prefix(const char *s, size_t len, const char *prefix)
{
	size_t n = strlen(prefix), i;

	if (len < n)
		return 0;
	for (i = 0; i < n; i++) {
		char c = s[i];
		if (c >= 'A' && c <= 'Z')
			c = (char)(c - 'A' + 'a');
		if (c != prefix[i])
			return 0;
	}
	return 1;
}

/* http(s)://x, mailto:x, telnet://x, ssh://x; printable ASCII only (spaces etc. must be %-escaped) */
static int uri_allowed(const char *uri, size_t len)
{
	size_t i, skip;

	if (len == 0 || len > OSC_EXT_URI_MAX)
		return 0;
	for (i = 0; i < len; i++)
		if ((unsigned char)uri[i] <= 0x20 || (unsigned char)uri[i] >= 0x7f)
			return 0;
	if (ieq_prefix(uri, len, "http://"))
		skip = 7;
	else if (ieq_prefix(uri, len, "https://"))
		skip = 8;
	else if (ieq_prefix(uri, len, "mailto:"))
		skip = 7;
	else if (ieq_prefix(uri, len, "telnet://"))
		skip = 9;
	else if (ieq_prefix(uri, len, "ssh://"))
		skip = 6;
	else
		return 0;
	return len > skip;
}

static int b64_value(unsigned char c)
{
	if (c >= 'A' && c <= 'Z') return c - 'A';
	if (c >= 'a' && c <= 'z') return c - 'a' + 26;
	if (c >= '0' && c <= '9') return c - '0' + 52;
	if (c == '+') return 62;
	if (c == '/') return 63;
	return -1;
}

/* Strict base64 (padding optional, nothing after it). Returns the decoded length, or -1. out holds len*3/4+3. */
static long b64_decode(const char *in, size_t len, uint8_t *out)
{
	uint32_t acc = 0;
	int      bits = 0;
	size_t   i, n = 0, pad = 0;

	for (i = 0; i < len; i++) {
		unsigned char c = (unsigned char)in[i];
		int v;

		if (c == '=') {
			pad++;
			continue;
		}
		if (pad)
			return -1;          /* data after padding */
		v = b64_value(c);
		if (v < 0)
			return -1;
		acc = (acc << 6) | (uint32_t)v;
		bits += 6;
		if (bits >= 8) {
			bits -= 8;
			out[n++] = (uint8_t)(acc >> bits);
		}
	}
	if (pad > 2 || bits >= 6)
		return -1;              /* a lone sextet can't be a byte */
	return (long)n;
}

static int map_ready(void)
{
	if (g_cell_id != NULL)
		return 1;
	g_cell_id = (uint16_t *)calloc((size_t)MAP_COLS * MAP_ROWS, sizeof(*g_cell_id));
	g_cell_ch = (uint8_t *)calloc((size_t)MAP_COLS * MAP_ROWS, 1);
	if (g_cell_id == NULL || g_cell_ch == NULL) {
		free(g_cell_id);
		free(g_cell_ch);
		g_cell_id = NULL;
		g_cell_ch = NULL;
		return 0;
	}
	return 1;
}

/* Clamps a 1-based screen rectangle to the map, 0-based. False when nothing is left. */
static int clamp_rect(int *sx, int *sy, int *ex, int *ey)
{
	if (*sx < 1) *sx = 1;
	if (*sy < 1) *sy = 1;
	if (*ex > MAP_COLS) *ex = MAP_COLS;
	if (*ey > MAP_ROWS) *ey = MAP_ROWS;
	if (*sx > *ex || *sy > *ey)
		return 0;
	(*sx)--; (*sy)--; (*ex)--; (*ey)--;
	return 1;
}

/* ---- cterm hooks (cterm's thread) ---- */

static void cell_hook(struct cterminal *cterm, int sx, int sy, unsigned char ch)
{
	size_t i;

	(void)cterm;
	if (sx < 1 || sy < 1 || sx > MAP_COLS || sy > MAP_ROWS)
		return;
	i = (size_t)(sy - 1) * MAP_COLS + (size_t)(sx - 1);
	lock();
	if (g_cell_id != NULL) {
		g_cell_id[i] = (uint16_t)g_open_id;
		g_cell_ch[i] = ch;
	}
	unlock();
}

static void region_hook(struct cterminal *cterm, int op, int sx, int sy, int ex, int ey)
{
	int y;
	size_t w;

	(void)cterm;
	if (!clamp_rect(&sx, &sy, &ex, &ey))
		return;
	w = (size_t)(ex - sx + 1);
	lock();
	if (g_cell_id != NULL) {
		switch (op) {
			case CTERM_REGION_UP:
				for (y = sy; y < ey; y++) {
					memmove(g_cell_id + (size_t)y * MAP_COLS + sx, g_cell_id + (size_t)(y + 1) * MAP_COLS + sx, w * sizeof(*g_cell_id));
					memmove(g_cell_ch + (size_t)y * MAP_COLS + sx, g_cell_ch + (size_t)(y + 1) * MAP_COLS + sx, w);
				}
				memset(g_cell_id + (size_t)ey * MAP_COLS + sx, 0, w * sizeof(*g_cell_id));
				break;
			case CTERM_REGION_DOWN:
				for (y = ey; y > sy; y--) {
					memmove(g_cell_id + (size_t)y * MAP_COLS + sx, g_cell_id + (size_t)(y - 1) * MAP_COLS + sx, w * sizeof(*g_cell_id));
					memmove(g_cell_ch + (size_t)y * MAP_COLS + sx, g_cell_ch + (size_t)(y - 1) * MAP_COLS + sx, w);
				}
				memset(g_cell_id + (size_t)sy * MAP_COLS + sx, 0, w * sizeof(*g_cell_id));
				break;
			default:   /* CTERM_REGION_CLEAR */
				for (y = sy; y <= ey; y++)
					memset(g_cell_id + (size_t)y * MAP_COLS + sx, 0, w * sizeof(*g_cell_id));
				break;
		}
	}
	unlock();
}

/* ---- OSC handlers (cterm's thread, lock held) ---- */

static void open_link(const char *uri, size_t len)
{
	int id;
	size_t i;

	if (!map_ready())
		return;
	/* The same URI as the link just drawn (a link split over several lines or SGR runs): keep its id */
	if (g_last_id != 0 && g_links[g_last_id] != NULL && strlen(g_links[g_last_id]) == len
	    && memcmp(g_links[g_last_id], uri, len) == 0) {
		g_open_id = g_last_id;
		return;
	}
	id = g_next_id;
	g_next_id = id + 1 >= LINK_SLOTS ? 1 : id + 1;
	if (g_links[id] != NULL) {   /* reusing an id: its old cells stop being links */
		for (i = 0; i < (size_t)MAP_COLS * MAP_ROWS; i++)
			if (g_cell_id[i] == id)
				g_cell_id[i] = 0;
		free(g_links[id]);
	}
	g_links[id] = (char *)malloc(len + 1);
	if (g_links[id] == NULL) {
		g_open_id = 0;
		return;
	}
	memcpy(g_links[id], uri, len);
	g_links[id][len] = 0;
	g_open_id = id;
	g_last_id = id;
	g_active = 1;
}

/* "8;params;URI" (body after "8;") */
static void handle_link(struct cterminal *cterm, const char *body, size_t len)
{
	const char *semi = memchr(body, ';', len);
	const char *uri;
	size_t      ulen;

	if (semi == NULL)
		return;   /* malformed: leave the current link state alone */
	uri = semi + 1;
	ulen = len - (size_t)(uri - body);
	if (ulen == 0 || !uri_allowed(uri, ulen)) {
		g_open_id = 0;   /* the end of a link, or one we won't open: following text is plain */
		return;
	}
	open_link(uri, ulen);
	if (g_open_id != 0 && cterm != NULL) {
		cterm->cell_hook = cell_hook;
		cterm->region_hook = region_hook;
		cterm->link_track = true;
	}
}

/* "52;Pc;data" (body after "52;") */
static void handle_clipboard(const char *body, size_t len)
{
	const char *semi = memchr(body, ';', len);
	const char *data;
	size_t      dlen, j, k;
	uint8_t    *out;
	long        n;

	if (semi == NULL)
		return;
	data = semi + 1;
	dlen = len - (size_t)(data - body);
	if (dlen == 0 || memchr(data, '?', dlen) != NULL)
		return;   /* clear / READ request: never answered, never acted on */
	if (dlen > ((size_t)OSC_EXT_CLIP_MAX + 2) / 3 * 4 + 4)
		return;   /* too big */
	out = (uint8_t *)malloc(dlen / 4 * 3 + 4);
	if (out == NULL)
		return;
	n = b64_decode(data, dlen, out);
	if (n <= 0 || n > OSC_EXT_CLIP_MAX) {
		free(out);
		return;
	}
	for (j = k = 0; j < (size_t)n; j++)   /* no NULs: the app treats it as a C string */
		if (out[j] != 0)
			out[k++] = out[j];
	if (k == 0) {
		free(out);
		return;
	}
	free(g_clip);
	g_clip = out;
	g_clip_len = k;
	g_clip_pending = 1;
}

/* Copies text into out (room for max bytes + NUL) the way a title is kept: tab becomes a space, C0/DEL/C1 controls
 * are dropped, a cut never ends inside a UTF-8 sequence, spaces are trimmed at both ends. Returns the length. */
static size_t clean_text(const char *in, size_t len, char *out, size_t max)
{
	size_t i, n = 0;

	for (i = 0; i < len && n < max; i++) {
		unsigned char c = (unsigned char)in[i];
		if (c == '\t')
			c = ' ';
		if (c < 0x20 || c == 0x7f)
			continue;
		/* UTF-8 C1 controls (U+0080..U+009F = C2 80..C2 9F) */
		if (c == 0xc2 && i + 1 < len && (unsigned char)in[i + 1] >= 0x80 && (unsigned char)in[i + 1] <= 0x9f) {
			i++;
			continue;
		}
		out[n++] = (char)c;
	}
	/* Don't end inside a UTF-8 sequence */
	if (n == max && i < len) {
		size_t back = n;
		while (back > 0 && ((unsigned char)out[back - 1] & 0xc0) == 0x80)
			back--;
		if (back > 0 && ((unsigned char)out[back - 1] & 0x80))
			back--;   /* the lead byte of the cut sequence */
		n = back;
	}
	/* Trim spaces at both ends */
	while (n > 0 && out[n - 1] == ' ')
		n--;
	out[n] = 0;
	i = 0;
	while (out[i] == ' ')
		i++;
	if (i > 0)
		memmove(out, out + i, n - i + 1);
	return n - i;
}

/* "0;title" / "2;title" (body after the ';') */
static void handle_title(const char *body, size_t len)
{
	clean_text(body, len, g_title, OSC_EXT_TITLE_MAX);
	g_title_pending = 1;
}

/* "777;notify;title;body" (body after "777;"): queued for the app, oldest dropped when full. Other 777 verbs (rxvt's
 * extensions) are ignored. An empty title and body is ignored. */
static void handle_notify(const char *body, size_t len)
{
	const char *title, *semi;
	struct note nt;

	if (len < 7 || strncmp(body, "notify;", 7) != 0)
		return;
	title = body + 7;
	len -= 7;
	semi = memchr(title, ';', len);
	clean_text(title, semi ? (size_t)(semi - title) : len, nt.title, OSC_EXT_NOTE_TITLE_MAX);
	if (semi != NULL)
		clean_text(semi + 1, len - (size_t)(semi + 1 - title), nt.body, OSC_EXT_NOTE_BODY_MAX);
	else
		nt.body[0] = 0;
	if (nt.title[0] == 0 && nt.body[0] == 0)
		return;
	if (g_note_count == OSC_EXT_NOTE_QUEUE) {
		memmove(&g_notes[0], &g_notes[1], sizeof(g_notes[0]) * (OSC_EXT_NOTE_QUEUE - 1));
		g_note_count--;
	}
	g_notes[g_note_count++] = nt;
}

static int hex_value(unsigned char c)
{
	if (c >= '0' && c <= '9') return c - '0';
	if (c >= 'a' && c <= 'f') return c - 'a' + 10;
	if (c >= 'A' && c <= 'F') return c - 'A' + 10;
	return -1;
}

/* Undoes Rainwire:WM's %XX escaping into out (room for max bytes + NUL), cut at max; a bad escape is kept as it
 * is. Returns the length. */
static long unescape(const char *in, size_t len, char *out, size_t max)
{
	size_t i, n = 0;

	for (i = 0; i < len; i++) {
		unsigned char c = (unsigned char)in[i];
		if (c == '%' && i + 2 < len && hex_value((unsigned char)in[i + 1]) >= 0 &&
		    hex_value((unsigned char)in[i + 2]) >= 0) {
			c = (unsigned char)(hex_value((unsigned char)in[i + 1]) * 16 + hex_value((unsigned char)in[i + 2]));
			i += 2;
		}
		if (n == max)
			break;
		out[n++] = (char)c;
	}
	out[n] = 0;
	return (long)n;
}

/* The board's token: exactly OSC_EXT_LINK_TOKEN_LEN characters of upper-case Crockford base32 */
static int token_ok(const char *t)
{
	size_t i;

	for (i = 0; t[i]; i++) {
		char c = t[i];
		if (!((c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z')) || c == 'I' || c == 'L' || c == 'O' || c == 'U')
			return 0;
	}
	return i == OSC_EXT_LINK_TOKEN_LEN;
}

/* The value of key in r, or NULL */
static const char *link_arg(const struct link_req *r, const char *key)
{
	int i;

	for (i = 0; i < r->argc; i++)
		if (strcmp(r->args[i].key, key) == 0)
			return r->args[i].value;
	return NULL;
}

/* "Open;kind=..;token=..;title=..;..." / "Raise;kind=..;..." (body after "Rainwire:Link;"): checked and queued for
 * the app, oldest dropped when full. Unknown verbs, bad kinds and bad tokens drop the request; any other key=value
 * is kept for the app (keys [a-z0-9_], at most OSC_EXT_LINK_KEY_MAX; a bad key, a field without '=' and keys past
 * OSC_EXT_LINK_ARGS are skipped). Values are unescaped and cleaned like a window title, cut at
 * OSC_EXT_LINK_VALUE_MAX bytes (title at OSC_EXT_LINK_TITLE_MAX). Called under the lock. */
static void handle_link_apc(const char *body, size_t len)
{
	struct link_req r;
	const char     *p = body, *end = body + len, *v;
	char            val[OSC_EXT_LINK_VALUE_MAX * 4 + 1];
	size_t          i;
	int             first = 1;

	memset(&r, 0, sizeof(r));
	while (p <= end) {
		const char *semi = memchr(p, ';', (size_t)(end - p));
		const char *fend = semi ? semi : end;
		size_t      flen = (size_t)(fend - p);

		if (first) {
			if (flen == 4 && strncmp(p, "Open", 4) == 0)
				r.verb = OSC_EXT_LINK_OPEN;
			else if (flen == 5 && strncmp(p, "Raise", 5) == 0)
				r.verb = OSC_EXT_LINK_RAISE;
			else
				return;
			first = 0;
		} else {
			const char *eq = memchr(p, '=', flen);
			size_t      klen = eq ? (size_t)(eq - p) : 0;
			int         ok = klen > 0 && klen <= OSC_EXT_LINK_KEY_MAX, k;

			for (i = 0; ok && i < klen; i++)
				ok = (p[i] >= 'a' && p[i] <= 'z') || (p[i] >= '0' && p[i] <= '9') || p[i] == '_';
			if (ok) {
				long vlen = unescape(eq + 1, (size_t)(fend - eq - 1), val, sizeof(val) - 1);
				int  is_kind = klen == 4 && strncmp(p, "kind", 4) == 0;
				int  is_token = klen == 5 && strncmp(p, "token", 5) == 0;
				int  is_title = klen == 5 && strncmp(p, "title", 5) == 0;

				if (is_kind) {
					if (vlen <= 0 || vlen > OSC_EXT_LINK_KIND_MAX)
						return;
					for (i = 0; i < (size_t)vlen; i++)
						if (!((val[i] >= 'a' && val[i] <= 'z') || (val[i] >= '0' && val[i] <= '9') || val[i] == '_'))
							return;
				} else if (is_token && vlen != OSC_EXT_LINK_TOKEN_LEN) {
					return;
				}
				for (k = 0; k < r.argc; k++)
					if (strlen(r.args[k].key) == klen && strncmp(r.args[k].key, p, klen) == 0)
						break;
				if (k < OSC_EXT_LINK_ARGS) {
					if (k == r.argc) {
						memcpy(r.args[k].key, p, klen);
						r.args[k].key[klen] = 0;
						r.argc++;
					}
					if (is_kind || is_token)
						memcpy(r.args[k].value, val, (size_t)vlen + 1);
					else
						clean_text(val, (size_t)vlen, r.args[k].value,
						           is_title ? OSC_EXT_LINK_TITLE_MAX : OSC_EXT_LINK_VALUE_MAX);
				}
			}
		}
		if (semi == NULL)
			break;
		p = semi + 1;
	}
	v = link_arg(&r, "kind");
	if (v == NULL || (r.verb == OSC_EXT_LINK_OPEN && ((v = link_arg(&r, "token")) == NULL || !token_ok(v))))
		return;
	if (g_link_count == OSC_EXT_LINK_QUEUE) {
		memmove(&g_link_reqs[0], &g_link_reqs[1], sizeof(g_link_reqs[0]) * (OSC_EXT_LINK_QUEUE - 1));
		g_link_count--;
	}
	g_link_reqs[g_link_count++] = r;
}

void osc_ext_handle_osc(struct cterminal *cterm, const char *strbuf, size_t len)
{
	if (strbuf == NULL)
		return;
	lock();
	if (len >= 2 && strbuf[0] == '8' && strbuf[1] == ';')
		handle_link(cterm, strbuf + 2, len - 2);
	else if (len >= 3 && strbuf[0] == '5' && strbuf[1] == '2' && strbuf[2] == ';')
		handle_clipboard(strbuf + 3, len - 3);
	else if (len >= 2 && (strbuf[0] == '0' || strbuf[0] == '2') && strbuf[1] == ';')
		handle_title(strbuf + 2, len - 2);
	else if (len >= 4 && strncmp(strbuf, "777;", 4) == 0)
		handle_notify(strbuf + 4, len - 4);
	unlock();
}

/* ---- the bridge ---- */

void osc_ext_attach(struct cterminal *cterm)
{
	if (cterm == NULL)
		return;
	if (cterm->osc_handler != osc_ext_handle_osc)
		cterm->osc_handler = osc_ext_handle_osc;
	if (g_active && !cterm->link_track) {   /* a new cterm in the same session (RIP, resize): keep tracking */
		cterm->cell_hook = cell_hook;
		cterm->region_hook = region_hook;
		cterm->link_track = true;
	}
}

bool osc_ext_apc_handler(const char *strbuf, size_t slen)
{
	if (strbuf != NULL && slen >= LINK_PREFIX_LEN && strncmp(strbuf, LINK_PREFIX, LINK_PREFIX_LEN) == 0) {
		lock();
		handle_link_apc(strbuf + LINK_PREFIX_LEN, slen - LINK_PREFIX_LEN);
		unlock();
		return true;   /* never reaches cterm */
	}
	if (strbuf == NULL || slen < CAPS_PREFIX_LEN || strncmp(strbuf, CAPS_PREFIX, CAPS_PREFIX_LEN) != 0)
		return false;
	if (slen - CAPS_PREFIX_LEN == 5 && strncmp(strbuf + CAPS_PREFIX_LEN, "Query", 5) == 0) {
		char reply[sizeof(OSC_EXT_CAPS_FIXED) + OSC_EXT_INFO_MAX + 8];
		int  n;

		lock();
		n = snprintf(reply, sizeof(reply), "\x1b_%s%s%s\x1b\\", OSC_EXT_CAPS_FIXED, g_info[0] ? ";" : "", g_info);
		unlock();
		if (n > 0 && (size_t)n < sizeof(reply))
			apc_send(reply, (size_t)n);
	}
	return true;   /* anything else in our namespace is ignored */
}

void osc_ext_session_reset(void)
{
	int i;

	lock();
	free(g_cell_id);
	free(g_cell_ch);
	g_cell_id = NULL;
	g_cell_ch = NULL;
	for (i = 0; i < LINK_SLOTS; i++) {
		free(g_links[i]);
		g_links[i] = NULL;
	}
	g_next_id = 1;
	g_open_id = 0;
	g_last_id = 0;
	g_active = 0;
	g_title[0] = 0;
	g_title_pending = 0;
	free(g_clip);
	g_clip = NULL;
	g_clip_len = 0;
	g_clip_pending = 0;
	g_note_count = 0;
	g_link_count = 0;
	unlock();
}

OSC_EXT_EXPORT int syncterm_osc_poll_title(char *buffer, int buffer_len)
{
	int n = -1;

	lock();
	if (g_title_pending && buffer != NULL && buffer_len > 0) {
		n = (int)strlen(g_title);
		if (n >= buffer_len)
			n = buffer_len - 1;
		memcpy(buffer, g_title, (size_t)n);
		buffer[n] = 0;
		g_title_pending = 0;
	}
	unlock();
	return n;
}

OSC_EXT_EXPORT int syncterm_osc_poll_clipboard(char *buffer, int buffer_len)
{
	int n = 0;

	lock();
	if (g_clip_pending && g_clip != NULL) {
		if (buffer == NULL || buffer_len <= 0 || g_clip_len >= (size_t)buffer_len) {
			n = -1;
		} else {
			memcpy(buffer, g_clip, g_clip_len);
			buffer[g_clip_len] = 0;
			n = (int)g_clip_len;
			free(g_clip);
			g_clip = NULL;
			g_clip_len = 0;
			g_clip_pending = 0;
		}
	}
	unlock();
	return n;
}

OSC_EXT_EXPORT int syncterm_osc_link_at(int col, int row, int ch, char *buffer, int buffer_len,
                                        int *span_start, int *span_end)
{
	int    n = 0, id, x;
	size_t base;

	if (col < 0 || row < 0 || col >= MAP_COLS || row >= MAP_ROWS)
		return 0;
	base = (size_t)row * MAP_COLS;
	lock();
	if (g_cell_id != NULL) {
		id = g_cell_id[base + (size_t)col];
		if (id != 0 && g_links[id] != NULL && (ch < 0 || g_cell_ch[base + (size_t)col] == (uint8_t)ch)) {
			if (span_start != NULL) {
				for (x = col; x > 0 && g_cell_id[base + (size_t)x - 1] == id; x--)
					;
				*span_start = x;
			}
			if (span_end != NULL) {
				for (x = col; x + 1 < MAP_COLS && g_cell_id[base + (size_t)x + 1] == id; x++)
					;
				*span_end = x;
			}
			n = (int)strlen(g_links[id]);
			if (buffer == NULL || n >= buffer_len)
				n = -1;   /* a link, but no room for it (spans are filled in all the same) */
			else
				memcpy(buffer, g_links[id], (size_t)n + 1);
		}
	}
	unlock();
	return n;
}

OSC_EXT_EXPORT int syncterm_osc_links_active(void)
{
	int a;

	lock();
	a = g_active;
	unlock();
	return a;
}

/* Keeps the app's ";"-separated key=value pairs whose key and value are only [A-Za-z0-9._+/-] (anything else could
 * break the APC answer); the rest are dropped. Kept across calls until set again. */
OSC_EXT_EXPORT void syncterm_osc_set_info(const char *keys)
{
	size_t n = 0;
	const char *p = keys;

	lock();
	while (p != NULL && *p) {
		const char *end = strchr(p, ';'), *c;
		size_t      plen = end ? (size_t)(end - p) : strlen(p);
		int         eq = 0, ok = plen > 2;

		for (c = p; ok && c < p + plen; c++) {
			if (*c == '=') {
				ok = eq++ == 0 && c > p && c + 1 < p + plen;
				continue;
			}
			ok = (*c >= 'a' && *c <= 'z') || (*c >= 'A' && *c <= 'Z') || (*c >= '0' && *c <= '9') ||
			     *c == '.' || *c == '_' || *c == '+' || *c == '/' || *c == '-';
		}
		if (ok && eq == 1 && n + (n ? 1 : 0) + plen <= OSC_EXT_INFO_MAX) {
			if (n)
				g_info[n++] = ';';
			memcpy(g_info + n, p, plen);
			n += plen;
		}
		p = end ? end + 1 : NULL;
	}
	g_info[n] = 0;
	unlock();
}

OSC_EXT_EXPORT int syncterm_osc_poll_notify(char *title, int title_len, char *body, int body_len)
{
	int got = 0;

	if (title == NULL || body == NULL || title_len <= 0 || body_len <= 0)
		return 0;
	lock();
	if (g_note_count > 0) {
		snprintf(title, (size_t)title_len, "%s", g_notes[0].title);
		snprintf(body, (size_t)body_len, "%s", g_notes[0].body);
		memmove(&g_notes[0], &g_notes[1], sizeof(g_notes[0]) * (OSC_EXT_NOTE_QUEUE - 1));
		g_note_count--;
		got = 1;
	}
	unlock();
	return got;
}

OSC_EXT_EXPORT int syncterm_osc_poll_link(char *buffer, int buffer_len)
{
	int    verb = 0, i;
	size_t n = 0;

	if (buffer == NULL || buffer_len <= 0)
		return 0;
	lock();
	if (g_link_count > 0) {
		const struct link_req *r = &g_link_reqs[0];

		verb = r->verb;
		buffer[0] = 0;
		for (i = 0; i < r->argc && verb > 0; i++) {
			size_t klen = strlen(r->args[i].key), vlen = strlen(r->args[i].value);

			if (n + (n ? 1 : 0) + klen + 1 + vlen + 1 > (size_t)buffer_len) {
				verb = -1;   /* doesn't fit: dropped all the same, so it can't block the queue */
				break;
			}
			if (n)
				buffer[n++] = '\n';
			memcpy(buffer + n, r->args[i].key, klen);
			n += klen;
			buffer[n++] = '=';
			memcpy(buffer + n, r->args[i].value, vlen);
			n += vlen;
			buffer[n] = 0;
		}
		memmove(&g_link_reqs[0], &g_link_reqs[1], sizeof(g_link_reqs[0]) * (OSC_EXT_LINK_QUEUE - 1));
		g_link_count--;
	}
	unlock();
	return verb;
}
