/*
 * trace_bridge.h -- TRACE (TERMinator Render And Compute Engine) escape handling. See trace_bridge.c.
 * Ported from the Windows client (TERMinator-Windows/native/trace_bridge.h).
 */
#ifndef TRACE_BRIDGE_H
#define TRACE_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>

/* Called for every APC string before anything else looks at it. Returns true when it was a TRACE command
 * ("TERMinator:TRACE;..."), which is then answered (Query) or queued for the app. */
bool trace_apc_handler(const char *strbuf, size_t slen);

/* Hands on received text: the bytes to give cterm, in order. */
typedef void (*trace_text_fn)(const char *text, size_t len, void *ctx);

/* Feeds received bytes through the binary-frame filter: TRACE binary frames (ESC _ TERMinator:TRACE;Bin;... ESC \)
 * are lifted out and queued for the app, everything else goes to text() in order, so a frame queues after the text
 * (and any text TRACE commands in it) that came before it. Keeps state across calls: a frame or its prefix can be
 * split between reads. */
void trace_stream_feed(const char *in, size_t len, trace_text_fn text, void *ctx);

/* Disconnect: drops queued commands. */
void trace_session_reset(void);

#endif /* TRACE_BRIDGE_H */
