/*
 * ui_bridge.h -- Rainwire:UI (ESC _ Rainwire:UI;... ST), a Rainwire board's menus drawn by TERMinator itself (1.1.6;
 * Rainwire docs/MENU_GFX.md, "Native menus"), for the macOS bridge. See ui_bridge.c. Ported from the Windows client
 * (TERMinator-Windows/native/ui_bridge.h).
 */
#ifndef UI_BRIDGE_H
#define UI_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>

/* Called for every APC string, next to pic_apc_handler. Returns true when it was a Rainwire:UI message, which is then
 * checked and queued for the app; it never reaches the SyncTERM handler. */
bool ui_apc_handler(const char *strbuf, size_t slen);

/* Disconnect: drops queued messages. */
void ui_session_reset(void);

#endif /* UI_BRIDGE_H */
