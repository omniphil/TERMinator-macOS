/*
 * wm_bridge.c -- Rainwire's window protocol for the macOS bridge (Rainwire docs/WINDOWS.md, protocol v1).
 * Ported from the Windows client (TERMinator-Windows/native/wm_bridge.c, the master): keep the two in step.
 *
 * A Rainwire BBS can hand its windows to the terminal to draw. It talks to the terminal with APC strings in the
 * normal stream, in their own namespace beside TRACE:
 *   ESC _ Rainwire:WM;Query ESC \                       -> answered here, at once (detection):
 *       ESC _ Rainwire:WM;Info;v=1;channels=0;framed=1;files=1 ESC \
 *       (files=1: OS file drops to and from the board, on desk windows and the Files TRACE module; the app handles
 *       FileOffer/FileGo/FileNo/FileGet/DropOut/DragFile, all queued here like the other verbs)
 *   ESC _ Rainwire:WM;Hello;v=1;mode=framed ESC \       -> queued for the app, as are Item, Open, Title, Data,
 *   ...                                                    Close, DragInfo, Suspend, Resume and Bye
 *
 * The Query reply goes out from inside cterm's APC handling, so it reaches the board before cterm answers the
 * cursor-position report that follows it in the same probe, which is what the board waits for.
 *
 * channels=0: cryptlib's SSH client only opens "session" and "direct-tcpip" channels, so a second channel of type
 * "rainwire-window" isn't possible here. Every window's screen travels in Data messages on the one connection
 * (framed mode). The app answers nothing until it has switched the protocol on (native_wm_set_enabled), so with the
 * compositor off the board gets Rainwire's server-drawn windows as before.
 *
 * Separate from TRACE (trace_bridge.c) and the SyncTERM APCs (apc_bridge.c); the app does all the drawing.
 *
 * macOS differences from Windows: CRITICAL_SECTION + INIT_ONCE -> a statically initialised pthread mutex (as in
 * trace_bridge.c), InterlockedExchange -> a C11 atomic; the exports are native_wm_* (declared in native_bridge.h)
 * instead of __declspec(dllexport) syncterm_wm_*.
 */

#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "apc_bridge.h"
#include "wm_bridge.h"
#include "native_bridge.h"

#define WM_PREFIX       "Rainwire:WM;"
#define WM_PREFIX_LEN   (sizeof(WM_PREFIX) - 1)
#define WM_INFO         "\x1b_Rainwire:WM;Info;v=1;channels=0;framed=1;files=1\x1b\\"
/* A Data message carries at most 2048 bytes of window output, about 2.8 KB once base64'd; leave room */
#define WM_COMMAND_MAX  8192
/* A burst of window output between two polls: 4096 messages is 8 MB of screen data */
#define WM_QUEUE_MAX    4096
#define WM_QUEUE_BYTES  (16 * 1024 * 1024)

typedef struct {
	char   *data;
	size_t  len;
} wm_queued_t;

static pthread_mutex_t  g_lock = PTHREAD_MUTEX_INITIALIZER;
static wm_queued_t      g_queue[WM_QUEUE_MAX];
static int              g_head, g_count;
static size_t           g_queued_bytes;
static atomic_int       g_enabled;

bool wm_apc_handler(const char *strbuf, size_t slen)
{
	const char *cmd;
	size_t      len;

	if (strbuf == NULL || slen < WM_PREFIX_LEN || strncmp(strbuf, WM_PREFIX, WM_PREFIX_LEN) != 0)
		return false;
	if (!atomic_load(&g_enabled))
		return true;   /* ours, but the compositor is off: say nothing, like a terminal without it */
	cmd = strbuf + WM_PREFIX_LEN;
	len = slen - WM_PREFIX_LEN;

	if (len == 5 && strncmp(cmd, "Query", 5) == 0) {
		apc_send(WM_INFO, sizeof(WM_INFO) - 1);
		return true;
	}
	if (len == 0 || len >= WM_COMMAND_MAX)
		return true;   /* empty or oversized: dropped */

	pthread_mutex_lock(&g_lock);
	if (g_count < WM_QUEUE_MAX && g_queued_bytes + len + 1 <= WM_QUEUE_BYTES) {
		char *copy = (char *)malloc(len + 1);
		if (copy != NULL) {
			memcpy(copy, cmd, len);
			copy[len] = 0;
			g_queue[(g_head + g_count) % WM_QUEUE_MAX].data = copy;
			g_queue[(g_head + g_count) % WM_QUEUE_MAX].len = len;
			g_queued_bytes += len;
			g_count++;
		}
	}
	pthread_mutex_unlock(&g_lock);
	return true;
}

void wm_session_reset(void)
{
	pthread_mutex_lock(&g_lock);
	while (g_count > 0) {
		free(g_queue[g_head].data);
		g_head = (g_head + 1) % WM_QUEUE_MAX;
		g_count--;
	}
	g_queued_bytes = 0;
	pthread_mutex_unlock(&g_lock);
}

/* Switches the protocol on (1) or off (0). Off, a Query goes unanswered and nothing is queued. */
void native_wm_set_enabled(int32_t enabled)
{
	atomic_store(&g_enabled, enabled ? 1 : 0);
	if (!enabled)
		wm_session_reset();
}

/* Takes the oldest queued message (the text after "Rainwire:WM;", NUL-terminated) into buffer. Returns its length,
 * 0 when none is queued, or -1 when buffer is too small (the message stays queued). */
int32_t native_wm_poll(char *buffer, int32_t buffer_len)
{
	int32_t result = 0;

	pthread_mutex_lock(&g_lock);
	if (g_count > 0) {
		size_t len = g_queue[g_head].len;
		if (buffer == NULL || buffer_len <= 0 || len >= (size_t)buffer_len) {
			result = -1;
		} else {
			memcpy(buffer, g_queue[g_head].data, len + 1);
			free(g_queue[g_head].data);
			g_queued_bytes -= len;
			g_head = (g_head + 1) % WM_QUEUE_MAX;
			g_count--;
			result = (int32_t)len;
		}
	}
	pthread_mutex_unlock(&g_lock);
	return result;
}
