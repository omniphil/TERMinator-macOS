/*
 * wm_bridge.h -- Rainwire's window protocol (ESC _ Rainwire:WM;... ST) for the macOS bridge. See wm_bridge.c.
 * Ported from the Windows client (TERMinator-Windows/native/wm_bridge.h).
 */
#ifndef WM_BRIDGE_H
#define WM_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>

/* Called for every APC string, next to trace_apc_handler. Returns true when it was a Rainwire:WM message, which is
 * then answered (Query) or queued for the app; it never reaches cterm or the SyncTERM handler. */
bool wm_apc_handler(const char *strbuf, size_t slen);

/* Disconnect: drops queued messages. */
void wm_session_reset(void);

#endif /* WM_BRIDGE_H */
