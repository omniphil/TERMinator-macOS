/*
 * WebSocket (RFC 6455) connection provider for SyncTERM-derived clients.
 *
 * Supports plain ws:// (CONN_TYPE_WEBSOCKET) and wss:// (CONN_TYPE_WEBSOCKETS,
 * TLS via cryptlib). The frame payload is treated as a telnet stream, which is
 * what Synchronet's WebSocket service and WebSockify-fronted telnet ports carry.
 *
 * Only compiled when the wrapper defines WITH_WEBSOCKET (see conn.c).
 */
#ifndef CONN_WEBSOCKET_H
#define CONN_WEBSOCKET_H

#include "bbslist.h"

int websocket_connect(struct bbslist *bbs);
int websocket_close(void);

/* Optional diagnostics sink; wrappers may point this at their debug log. */
extern void (*websocket_log_cb)(const char *msg);

/* Request path used in the HTTP upgrade (default "/"). Wrappers may override. */
extern char websocket_path[256];

#endif /* CONN_WEBSOCKET_H */
