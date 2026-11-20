/*
 * apc_audio.h -- SyncTERM's audio APC (SyncTERM:A;* verbs, SyncTERM:Q; libsndfile queries), ported
 * from upstream SyncTERM's src/syncterm/audio_apc.c. See apc_audio.c.
 */
#ifndef APC_AUDIO_H
#define APC_AUDIO_H

#include <stdbool.h>
#include <stddef.h>

/* `strbuf` points past "SyncTERM:A;" */
void audio_apc_handler(char *strbuf, size_t slen);
/* `strbuf` points past "SyncTERM:Q;" */
void feature_query_handler(char *strbuf, size_t slen);
/* Once per poll: sends the async CSI = 7 ; <ch> ; 0 n for Update-armed channels that just stopped. */
void audio_apc_poll(void);
/* Frees every slot and closes every channel (disconnect). */
void audio_apc_cleanup(void);
/* The app's soundtrack setting. While off the libsndfile query answers 0 and verbs are ignored. */
void audio_apc_set_enabled(bool enabled);

#endif /* APC_AUDIO_H */
