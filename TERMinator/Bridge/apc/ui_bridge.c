/*
 * ui_bridge.c -- Rainwire:UI, a Rainwire board's menus drawn by TERMinator itself (1.1.6; Rainwire
 * docs/MENU_GFX.md, "Native menus (TERMinator 1.1.6)"), for the macOS bridge.
 * Ported from the Windows client (TERMinator-Windows/native/ui_bridge.c, the master): keep the two in step.
 *
 * The client says it draws them with ui=3;uiscreens=menu+dialog in its Rainwire:Caps;Info answer (the app's keys,
 * OscExtras.swift). The board then sends, as APC strings:
 *   Rainwire:UI;Hello;b64=<MU_S_HELLO>                   once a call
 *   Rainwire:UI;Tick;b64=<MU_S_TICK>                     the clock and minutes left
 *   Rainwire:UI;Menu;hdr=<cache name or empty>;b64=<MU_S_MENU>    a menu's head (its header picture stored before
 *                                                        with SyncTERM's C;S)
 *   Rainwire:UI;Items;b64=<MU_S_ITEMS>                   its items, as many as it takes
 *   Rainwire:UI;Dialog;b64=<MU_S_DIALOG>                 a box over the menu that waits for a key
 *   Rainwire:UI;Show / Rainwire:UI;Hide                  draw it now / give the terminal back
 * The packets are Rainwire's Menu module protocol (Rainwire modules/menu/src/protocol.h), unchanged.
 *
 * Messages are checked here and queued for the app in stream order (it polls with native_ui_poll), each as
 *   <Verb>[;b64=<base64>][;path=<full UTF-8 path of the header picture>]
 * path is last (it runs to the end) and only on a Menu whose hdr names a file that is in the board's cache. The app
 * draws (Views/RainwireMenu.swift) and answers the board itself (Shown, Pick, Back, Key, Ping, Closed).
 *
 * macOS differences from Windows: CRITICAL_SECTION + INIT_ONCE -> a statically initialised pthread mutex (as
 * pic_bridge.c), GetFileAttributesW -> stat() on the UTF-8 path; the export is native_ui_poll (declared in
 * native_bridge.h) instead of __declspec(dllexport) syncterm_ui_poll.
 */

#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include "apc_bridge.h"
#include "ui_bridge.h"
#include "native_bridge.h"

#define UI_PREFIX      "Rainwire:UI;"
#define UI_PREFIX_LEN  (sizeof(UI_PREFIX) - 1)
#define UI_MSG_MAX     8192   /* a message: a 4000-byte packet is ~5.4 KB of base64; longer is dropped */
#define UI_NAME_MAX    128
#define UI_PATH_MAX    1024   /* as apc_bridge.c's APC_PATH_MAX */
#define UI_QUEUE_MAX   256

static pthread_mutex_t  g_lock = PTHREAD_MUTEX_INITIALIZER;
static char            *g_queue[UI_QUEUE_MAX];
static int              g_head, g_count;

/* Queues a message for the app, in arrival order; the oldest goes when the queue is full. */
static void enqueue(char *msg)
{
	pthread_mutex_lock(&g_lock);
	if (g_count == UI_QUEUE_MAX) {
		free(g_queue[g_head]);
		g_head = (g_head + 1) % UI_QUEUE_MAX;
		g_count--;
	}
	g_queue[(g_head + g_count) % UI_QUEUE_MAX] = msg;
	g_count++;
	pthread_mutex_unlock(&g_lock);
}

/* ^[A-Za-z0-9._-]{1,128}$ and no "..": a flat name in the board's cache folder (as pic_bridge.c) */
static bool valid_name(const char *s, size_t n)
{
	size_t i;

	if (n < 1 || n > UI_NAME_MAX)
		return false;
	for (i = 0; i < n; i++) {
		char c = s[i];
		if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '.' || c == '_'
		      || c == '-'))
			return false;
		if (c == '.' && i + 1 < n && s[i + 1] == '.')
			return false;
	}
	return true;
}

static bool file_exists(const char *utf8)
{
	struct stat st;

	return stat(utf8, &st) == 0 && S_ISREG(st.st_mode);
}

/* The value of key in a ';'-separated list (not NUL-terminated): its start and length, or NULL. */
static const char *field(const char *p, const char *end, const char *key, size_t *vlen)
{
	size_t klen = strlen(key);

	while (p < end) {
		const char *semi = memchr(p, ';', (size_t)(end - p));
		const char *fend = semi ? semi : end;
		if ((size_t)(fend - p) > klen && strncmp(p, key, klen) == 0 && p[klen] == '=') {
			*vlen = (size_t)(fend - p - klen - 1);
			return p + klen + 1;
		}
		p = semi ? semi + 1 : end;
	}
	return NULL;
}

/* base64's characters only, so nothing else rides along to the app */
static bool valid_b64(const char *s, size_t n)
{
	size_t i;

	for (i = 0; i < n; i++) {
		char c = s[i];
		if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '+' || c == '/'
		      || c == '='))
			return false;
	}
	return true;
}

bool ui_apc_handler(const char *strbuf, size_t slen)
{
	const char *p, *end, *semi, *b64, *hdr;
	size_t      vlen, blen = 0, hlen = 0, n;
	char        path[UI_PATH_MAX], name[UI_NAME_MAX + 1];
	char       *msg;
	bool        have_path = false;

	if (strbuf == NULL || slen < UI_PREFIX_LEN || strncmp(strbuf, UI_PREFIX, UI_PREFIX_LEN) != 0)
		return false;
	p = strbuf + UI_PREFIX_LEN;
	end = strbuf + slen;
	if ((size_t)(end - p) > UI_MSG_MAX)
		return true;   /* ours, but oversized: dropped */
	semi = memchr(p, ';', (size_t)(end - p));
	vlen = (size_t)((semi ? semi : end) - p);
	if (vlen < 1 || vlen > 16)
		return true;
	for (n = 0; n < vlen; n++)
		if (!((p[n] >= 'A' && p[n] <= 'Z') || (p[n] >= 'a' && p[n] <= 'z')))
			return true;
	b64 = semi ? field(semi + 1, end, "b64", &blen) : NULL;
	if (b64 != NULL && !valid_b64(b64, blen))
		return true;
	hdr = semi ? field(semi + 1, end, "hdr", &hlen) : NULL;
	if (hdr != NULL && hlen > 0 && valid_name(hdr, hlen)) {
		memcpy(name, hdr, hlen);
		name[hlen] = 0;
		have_path = apc_cache_path(name, path, sizeof(path)) && file_exists(path);
	}
	msg = malloc(vlen + blen + strlen(have_path ? path : "") + 16);
	if (msg == NULL)
		return true;
	memcpy(msg, p, vlen);
	n = vlen;
	if (b64 != NULL) {
		memcpy(msg + n, ";b64=", 5);
		memcpy(msg + n + 5, b64, blen);
		n += 5 + blen;
	}
	if (have_path) {
		memcpy(msg + n, ";path=", 6);
		strcpy(msg + n + 6, path);
		n += 6 + strlen(path);
	}
	msg[n] = 0;
	enqueue(msg);
	return true;
}

void ui_session_reset(void)
{
	pthread_mutex_lock(&g_lock);
	while (g_count > 0) {
		free(g_queue[g_head]);
		g_head = (g_head + 1) % UI_QUEUE_MAX;
		g_count--;
	}
	pthread_mutex_unlock(&g_lock);
}

/* Takes the oldest queued message (see the top of this file, NUL-terminated) into buffer. Returns its length, 0 when
 * none is queued, or -1 when buffer is too small (the message stays queued). */
int32_t native_ui_poll(char *buffer, int32_t buffer_len)
{
	int32_t result = 0;

	pthread_mutex_lock(&g_lock);
	if (g_count > 0) {
		size_t len = strlen(g_queue[g_head]);
		if (buffer == NULL || buffer_len <= 0 || len >= (size_t)buffer_len) {
			result = -1;
		} else {
			memcpy(buffer, g_queue[g_head], len + 1);
			free(g_queue[g_head]);
			g_head = (g_head + 1) % UI_QUEUE_MAX;
			g_count--;
			result = (int32_t)len;
		}
	}
	pthread_mutex_unlock(&g_lock);
	return result;
}
