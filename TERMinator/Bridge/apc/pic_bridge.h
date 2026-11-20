/*
 * pic_bridge.h -- TERMinator:Pic (ESC _ TERMinator:Pic;... ST), Rainwire's pictures, for the macOS bridge.
 * See pic_bridge.c. Ported from the Windows client (TERMinator-Windows/native/pic_bridge.h).
 */
#ifndef PIC_BRIDGE_H
#define PIC_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>

/* Called for every APC string, next to trace_apc_handler. Returns true when it was a TERMinator:Pic command, which
 * is then checked and queued for the app; it never reaches the SyncTERM handler. */
bool pic_apc_handler(const char *strbuf, size_t slen);

/* A full screen clear (ESC [ 2 J, form feed, RIS): queues a HideAll at this point in the stream. */
void pic_screen_cleared(void);

/* Disconnect: drops queued commands. */
void pic_session_reset(void);

#endif /* PIC_BRIDGE_H */
