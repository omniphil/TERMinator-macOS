/*
 * apc_mixer.h -- upstream SyncTERM's xpbeep stream mixer (xp_audio_*), ported for the macOS bridge from the
 * Windows client (TERMinator-Windows/native/apc_mixer.h). See apc_mixer.c. Not xpbeep.h: its tone prototypes
 * clash with the bridge stubs.
 */
#ifndef APC_MIXER_H
#define APC_MIXER_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define XPBEEP_SAMPLE_RATE  44100
#define XPBEEP_FRAMESIZE    4       /* S16 stereo */

/* Same values as xpbeep.h's enum WAVE_SHAPE */
#define APC_WAVE_SHAPE_SINE            0
#define APC_WAVE_SHAPE_SAWTOOTH        1
#define APC_WAVE_SHAPE_SQUARE          2
#define APC_WAVE_SHAPE_SINE_SAW        3
#define APC_WAVE_SHAPE_SINE_HARM       4
#define APC_WAVE_SHAPE_SINE_SAW_CHORD  5
#define APC_WAVE_SHAPE_SINE_SAW_HARM   6
#define APC_WAVE_SHAPE_MASK            0x7FFFFFFFUL
#define APC_WAVE_SHAPE_NO_CLEAN        0x80000000UL

typedef int xp_audio_handle_t;

/* Per-append options; all volumes in dB (0 = unity). See upstream xpbeep.h for the full semantics:
 * fade_in applies to a loop's first iteration only, fade_out only at a natural end, crossfade overlays
 * a fade-out of length fade_in_frames on the previous tail, loop wraps until a later append ends it. */
typedef struct {
	float  volume_l;
	float  volume_r;
	size_t fade_in_frames;
	size_t fade_out_frames;
	bool   crossfade;
	bool   loop;
} xp_audio_opts_t;

#define XP_AUDIO_OPTS_INIT { 0.0f, 0.0f, 0, 0, false, false }

xp_audio_handle_t xp_audio_open(float volume_l, float volume_r);
void              xp_audio_close(xp_audio_handle_t h);
/* Takes ownership of the malloc()d `frames` (freed on failure too). */
bool              xp_audio_append(xp_audio_handle_t h, int16_t *frames, size_t nframes,
                                  const xp_audio_opts_t *opts);
void              xp_audio_set_volume(xp_audio_handle_t h, float volume_l, float volume_r);
void              xp_audio_ramp_volume(xp_audio_handle_t h, float target_l, float target_r, size_t nframes);
void              xp_audio_get_volume(xp_audio_handle_t h, float *volume_l, float *volume_r);
bool              xp_audio_is_idle(xp_audio_handle_t h);
void              xp_audio_finish(xp_audio_handle_t h);
void              xp_audio_stop(xp_audio_handle_t h);
void              xp_audio_clear(xp_audio_handle_t h);
void              xp_audio_drain(xp_audio_handle_t h);

/* Mixes every stream into `frames` S16 stereo frames (silence when idle). Returns how many leading
 * frames carried audio from at least one stream. */
size_t            xp_mixer_pull(int16_t *out, size_t frames);

/* `samples` frames of S16 stereo into `wave` (A;Synth). */
void              xptone_makewave(double freq, int16_t *wave, int samples, unsigned long shape);

#endif /* APC_MIXER_H */
