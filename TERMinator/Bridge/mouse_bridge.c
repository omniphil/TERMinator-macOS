/*
 * mouse_bridge.c -- xterm mouse reporting for the main terminal, as SyncTERM does it.
 * Ported from the Windows client (TERMinator-Windows/native/mouse_bridge.c, the master): keep the two in step.
 *
 * A board or door that wants the mouse sends CSI ? Pm h with a tracking mode (9 X10, 1000 normal, 1002 button
 * event, 1003 any event) and optionally 1006 for SGR coordinates. cterm parses those but keeps no mouse state of its
 * own: it calls mouse_state_change / mouse_state_query, which upstream SyncTERM installs in term.c (not built here)
 * and every TERMinator client left unset, so reporting was always off. This file installs them, keeps the mode the
 * way term.c does (one tracking mode at a time, the last set wins, resetting the current one turns tracking off;
 * 1006 a separate flag; 1001, 1004, 1005, 1007 and 1015 ignored), and turns the app's mouse events into the same
 * reports term.c's fill_mevent() sends:
 *   classic  ESC [ M Cb Cx Cy   (32 + button code, 33 + 0-based column and row, each capped at 222)
 *   SGR      ESC [ < b ; x ; y M   on press and move, ... m on release
 * Button codes: 0 left, 1 middle, 2 right, 64/65 wheel up/down, +32 for a move; a classic release is code 3. Like
 * SyncTERM, no modifier bits are sent.
 *
 * What each mode reports (SyncTERM's setup_mouse_events):
 *   9     presses of the three buttons only; the wheel stays scrollback
 *   1000  presses and releases, and the wheel
 *   1002  as 1000, plus moves while a button is held
 *   1003  as 1000, plus every move
 *
 * The app switches this on (native_mouse_set_enabled) once it can deliver mouse events. Until then nothing
 * changes: cterm's CTerm device attributes don't claim a mouse (CSI < ... ; 7 c), and no report is ever sent. The
 * app reads the mode (native_mouse_mode) to decide whether a click is the board's or its own (selection,
 * scrollback), and hands the board's to native_mouse_event.
 *
 * macOS differences from Windows: InterlockedExchange -> C11 atomics; the exports are native_mouse_* (declared in
 * native_bridge.h) instead of __declspec(dllexport) syncterm_mouse_*. The app calls them from the main thread while
 * the poll feeds cterm; conn_send is what native_send_data uses too.
 */

#include <stdatomic.h>
#include <stdio.h>
#include <string.h>

#include "mouse_bridge.h"

#ifndef MOUSE_BRIDGE_TEST
#include "cterm.h"   /* same order as syncterm_macos.c */
#include "ciolib.h"
#include "conn.h"
#include "native_bridge.h"
#endif

static atomic_int g_enabled;
static atomic_int g_mode;   /* MOUSE_MODE_* */
static atomic_int g_sgr;

/* ---- the mode, as SyncTERM's term.c keeps it ---- */

static void mouse_state_change(int type, int action, void *cbdata)
{
	(void)cbdata;
	if (!action) {
		if (type == atomic_load(&g_mode))
			atomic_store(&g_mode, MOUSE_MODE_OFF);
		if (type == MOUSE_SGR)
			atomic_store(&g_sgr, 0);
		return;
	}
	switch (type) {
		case MOUSE_MODE_X10:
		case MOUSE_MODE_NORMAL:
		case MOUSE_MODE_BUTTON:
		case MOUSE_MODE_ANY:
			atomic_store(&g_mode, type);
			break;
		case MOUSE_SGR:
			atomic_store(&g_sgr, 1);
			break;
	}
}

static int mouse_state_query(int type, void *cbdata)
{
	(void)cbdata;
	if (type == MOUSE_SGR)
		return atomic_load(&g_sgr) != 0;
	return type == atomic_load(&g_mode);
}

void mouse_bridge_reset(void)
{
	atomic_store(&g_mode, MOUSE_MODE_OFF);
	atomic_store(&g_sgr, 0);
}

/* ---- the report ---- */

int mouse_encode(char *buf, size_t bufsz, int mode, int sgr, int kind, int button, int x, int y)
{
	int code;
	int ret;

	if (buf == NULL || bufsz == 0)
		return 0;
	switch (mode) {
		case MOUSE_MODE_X10:
			if (kind != MOUSE_PRESS || button < 0 || button > 2)
				return 0;
			break;
		case MOUSE_MODE_NORMAL:
		case MOUSE_MODE_BUTTON:
		case MOUSE_MODE_ANY:
			if (kind == MOUSE_MOVE) {
				if (mode == MOUSE_MODE_NORMAL)
					return 0;
				if (button < 0 && mode == MOUSE_MODE_BUTTON)
					return 0;
			}
			else if (button == MOUSE_WHEEL_UP || button == MOUSE_WHEEL_DOWN) {
				if (kind != MOUSE_PRESS)
					return 0;  /* the wheel reports presses only */
			}
			break;
		default:
			return 0;
	}
	if (kind == MOUSE_MOVE && button < 0)
		button = 3;  /* no button held (any-event tracking) */
	if (button < 0 || button > MOUSE_WHEEL_DOWN)
		return 0;
	code = button;
	if (kind != MOUSE_MOVE && button >= MOUSE_WHEEL_UP)
		code = button + 61;  /* 64 / 65 */
	if (kind == MOUSE_MOVE)
		code += 32;

	if (!sgr) {
		if (bufsz < 6)
			return 0;
		if (kind == MOUSE_RELEASE)
			code = 3;
		x--;
		y--;
		if (x < 0)
			x = 0;
		if (x > 222)
			x = 222;
		if (y < 0)
			y = 0;
		if (y > 222)
			y = 222;
		buf[0] = '\x1b';
		buf[1] = '[';
		buf[2] = 'M';
		buf[3] = (char)(' ' + code);
		buf[4] = (char)('!' + x);
		buf[5] = (char)('!' + y);
		return 6;
	}
	if (x < 1)
		x = 1;
	if (y < 1)
		y = 1;
	ret = snprintf(buf, bufsz, "\x1b[<%d;%d;%d%c", code, x, y, kind == MOUSE_RELEASE ? 'm' : 'M');
	if (ret < 0 || (size_t)ret >= bufsz)
		return 0;
	return ret;
}

#ifndef MOUSE_BRIDGE_TEST

void mouse_bridge_attach(struct cterminal *cterm)
{
	if (!atomic_load(&g_enabled))
		return;
	/* Advertised in the CTerm device attributes, as SyncTERM does when it has a mouse. initciolib clears cio_api,
	 * so this is set again before every feed. */
	cio_api.mouse = 1;
	if (cterm && cterm->mouse_state_change != mouse_state_change) {
		cterm->mouse_state_change = mouse_state_change;
		cterm->mouse_state_change_cbdata = NULL;
		cterm->mouse_state_query = mouse_state_query;
		cterm->mouse_state_query_cbdata = NULL;
	}
}

/* The app can deliver mouse events. Off again (the app closing, or a setting) drops any mode a board set. */
void native_mouse_set_enabled(int32_t enabled)
{
	atomic_store(&g_enabled, enabled ? 1 : 0);
	if (!enabled)
		mouse_bridge_reset();
}

/* The board's tracking mode (0, 9, 1000, 1002 or 1003), plus 0x10000 when it asked for SGR coordinates. */
int32_t native_mouse_mode(void)
{
	if (!atomic_load(&g_enabled))
		return 0;
	return (int32_t)atomic_load(&g_mode) | (atomic_load(&g_sgr) ? 0x10000 : 0);
}

/* One mouse event from the app (kind MOUSE_*, button as in mouse_bridge.h, 1-based cell). Returns the bytes sent,
 * or 0 when the board's mode doesn't report it -- the app then keeps it (selection, scrollback). */
int32_t native_mouse_event(int32_t kind, int32_t button, int32_t x, int32_t y)
{
	char buf[32];
	int  n;

	if (!atomic_load(&g_enabled))
		return 0;
	n = mouse_encode(buf, sizeof(buf), atomic_load(&g_mode), atomic_load(&g_sgr) != 0, kind, button, x, y);
	if (n <= 0)
		return 0;
	return conn_send(buf, (size_t)n, 1000) > 0 ? n : 0;
}

#endif /* MOUSE_BRIDGE_TEST */
