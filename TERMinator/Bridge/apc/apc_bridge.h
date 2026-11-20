/*
 * apc_bridge.h -- SyncTERM's APC handler (ESC _ SyncTERM:... ST) for the macOS bridge. See apc_bridge.c.
 * Ported from the Windows client (TERMinator-Windows/native/apc_bridge.h), where the hooks are wpf_apc_*.
 */
#ifndef APC_BRIDGE_H
#define APC_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>

struct cterminal;

/* Joins `rel` onto the board's cache directory (UTF-8, '/' separators). False when no cache directory
 * is set, `rel` is absolute or has ".." segments, or the result would resolve outside the cache. */
bool apc_cache_path(const char *rel, char *out, size_t outsz);

/* Sends a reply to the BBS. */
void apc_send(const char *buf, size_t len);

/* Installs the handler on `cterm` if it isn't already (cheap; called before every cterm_write, since
 * g_cterm is re-created on resize / font change). */
void macos_apc_attach(struct cterminal *cterm);
/* Once per processed chunk: audio Update notifications. */
void macos_apc_poll(void);
/* Disconnect: frees image buffers, audio slots and channels, and drops queued TRACE commands. */
void macos_apc_session_reset(void);

#endif /* APC_BRIDGE_H */
