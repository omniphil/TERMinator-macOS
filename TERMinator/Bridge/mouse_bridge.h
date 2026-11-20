/*
 * mouse_bridge.h -- xterm mouse reporting for the main terminal, as SyncTERM does it. See mouse_bridge.c.
 * Ported from the Windows client (TERMinator-Windows/native/mouse_bridge.h, the master): keep the two in step.
 */
#ifndef MOUSE_BRIDGE_H
#define MOUSE_BRIDGE_H

#include <stddef.h>

struct cterminal;

/* What the app reports (native_mouse_event's kind) */
#define MOUSE_PRESS    0
#define MOUSE_RELEASE  1
#define MOUSE_MOVE     2

/* Buttons: 0 left, 1 middle, 2 right, 3 wheel up, 4 wheel down. A move passes the lowest held button, or -1. */
#define MOUSE_WHEEL_UP    3
#define MOUSE_WHEEL_DOWN  4

/* The tracking modes a board can set (CSI ? Pm h), as SyncTERM keeps them: one at a time, the last set wins */
#define MOUSE_MODE_OFF     0
#define MOUSE_MODE_X10     9
#define MOUSE_MODE_NORMAL  1000
#define MOUSE_MODE_BUTTON  1002
#define MOUSE_MODE_ANY     1003
#define MOUSE_SGR          1006

/* Installs the mode callbacks on cterm (it keeps no mouse state of its own). Called before every feed into cterm,
 * next to keyev_attach, since cterm is re-created on resize and font changes. */
void mouse_bridge_attach(struct cterminal *cterm);

/* Disconnect: the next board starts with reporting off. */
void mouse_bridge_reset(void);

/* The report for one event under the given mode, or 0 when that mode doesn't report it. x and y are 1-based cells.
 * Separate from the rest so it can be tested without a connection. */
int mouse_encode(char *buf, size_t bufsz, int mode, int sgr, int kind, int button, int x, int y);

#endif /* MOUSE_BRIDGE_H */
