/*
 * apc_sndfile.h -- libsndfile decoding for the audio APC, ported from upstream SyncTERM's
 * src/syncterm/xp_sndfile.c (runtime-loaded libsndfile, output normalized to S16 stereo 44.1 kHz).
 */
#ifndef APC_SNDFILE_H
#define APC_SNDFILE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

bool sndfile_available(void);
/* `major` is the SF_FORMAT_TYPEMASK field shifted right 16, `subtype` the raw SF_FORMAT_SUBMASK. */
bool sndfile_format_available(uint32_t major, uint32_t subtype);
/* On success the caller owns *out_frames (free()). `utf8path` is UTF-8. */
bool sndfile_decode(const char *utf8path, int16_t **out_frames, size_t *out_nframes);
bool sndfile_decode_mem(const void *data, size_t len, int16_t **out_frames, size_t *out_nframes);

#endif /* APC_SNDFILE_H */
