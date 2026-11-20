/*
 * apc_audio.c -- SyncTERM's audio APC dispatcher, ported from upstream SyncTERM's
 * src/syncterm/audio_apc.c (Load / LoadBlob / Synth / Copy / Queue / Flush / Volume / Wait / Update,
 * and the SyncTERM:Q; libsndfile + libsndfileFormat queries). See cterm.adoc upstream for the protocol.
 *
 * State: 256 patch slots of decoded / synthesized S16 stereo 44.1 kHz PCM (a Queue moves a slot's
 * buffer onto the channel, emptying the slot) and channels 2..15, lazy-opened at -12 dB on the mixer
 * in apc_mixer.c.
 *
 * Differences from upstream:
 *   - Ch=0/1 alias cterm's ANSI-music / fx streams upstream. This cterm has neither, so they resolve
 *     to nothing (Queue refuses them upstream too; Flush / Volume / Wait on them are no-ops).
 *   - The CSI = 7 n state DSR needs a cterm hook this cterm lacks; not ported. Update's async
 *     running->stopped notification is.
 *   - Cache paths go through apc_cache_path() instead of clean_path().
 *   - The app's soundtrack setting gates everything (audio_apc_set_enabled).
 *
 * macOS: ported 2026-09-16 from the Windows client (TERMinator-Windows/native/apc_audio.c); only the enable
 * flag changed (C11 atomic instead of InterlockedExchange). Windows is the master.
 */

#include <errno.h>
#include <math.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "genwrap.h"
#include "base64.h"

#include "apc_audio.h"
#include "apc_bridge.h"
#include "apc_mixer.h"
#include "apc_sndfile.h"

#define AUDIO_APC_PATCH_SLOTS            256
#define AUDIO_APC_CHANNELS               16
#define AUDIO_APC_FIRST_APC_CH           2      /* 0,1 = cterm-owned upstream */
#define AUDIO_APC_BASE_DB                -12.0f
#define AUDIO_APC_FEATURE_SNDFILE        100
#define AUDIO_APC_FEATURE_SNDFILE_FORMAT 101
#define APC_AUDIO_PATH_MAX               1024

/* Synth shape sentinel -- not a wave shape; maps freq to 0. */
#define APC_SHAPE_SILENCE                (-2)

struct audio_patch {
	int16_t *frames;
	size_t   nframes;
};

static struct audio_patch patches[AUDIO_APC_PATCH_SLOTS];
static xp_audio_handle_t  apc_channels[AUDIO_APC_CHANNELS - AUDIO_APC_FIRST_APC_CH];
static bool               apc_channels_init = false;
static bool               apc_notify[AUDIO_APC_CHANNELS];
static int                apc_last_state[AUDIO_APC_CHANNELS];
static atomic_int         apc_enabled = 0;   /* written by the app, read on the poll path */

static void
init_state_once(void)
{
	int i;

	if (apc_channels_init)
		return;
	for (i = 0; i < (int)(sizeof(apc_channels) / sizeof(apc_channels[0])); i++)
		apc_channels[i] = -1;
	apc_channels_init = true;
}

void
audio_apc_set_enabled(bool enabled)
{
	atomic_store(&apc_enabled, enabled ? 1 : 0);
}

/* Ch>=2 -> apc_channels[c-2], lazy-opened at -12 dB. -1 for anything else. */
static xp_audio_handle_t
channel_handle(int c)
{
	if (c < AUDIO_APC_FIRST_APC_CH || c >= AUDIO_APC_CHANNELS)
		return -1;
	init_state_once();
	if (apc_channels[c - AUDIO_APC_FIRST_APC_CH] < 0)
		apc_channels[c - AUDIO_APC_FIRST_APC_CH] = xp_audio_open(AUDIO_APC_BASE_DB, AUDIO_APC_BASE_DB);
	return apc_channels[c - AUDIO_APC_FIRST_APC_CH];
}

/* ----- parsers ----- */

/* "<N>" (ms), "<N>ms", "<N>f" (frames) or "<N>p" (periods, Synth only). 0 on any parse error. */
static size_t
apc_parse_duration(const char *s, double freq_hz, bool allow_periods)
{
	char         *end;
	unsigned long n;

	if (s == NULL)
		return 0;
	n = strtoul(s, &end, 10);
	if (end == s)
		return 0;
	if (*end == '\0' || *end == ';')
		return (size_t)((uint64_t)n * XPBEEP_SAMPLE_RATE / 1000);
	if (end[0] == 'm' && end[1] == 's' && (end[2] == '\0' || end[2] == ';'))
		return (size_t)((uint64_t)n * XPBEEP_SAMPLE_RATE / 1000);
	if (end[0] == 'f' && (end[1] == '\0' || end[1] == ';'))
		return (size_t)n;
	if (end[0] == 'p' && (end[1] == '\0' || end[1] == ';')) {
		if (!allow_periods || freq_hz <= 0.0)
			return 0;
		return (size_t)((double)n * (double)XPBEEP_SAMPLE_RATE / freq_hz + 0.5);
	}
	return 0;
}

/* "<pct>" (0..100 linear) or "<dB>dB". Returns dB; 0 pct -> -60 dB; parse errors -> 0 dB. */
static float
apc_parse_volume(const char *s)
{
	char *end;
	float v;

	if (s == NULL)
		return 0.0f;
	v = strtof(s, &end);
	if (end == s)
		return 0.0f;
	if ((end[0] == 'd' || end[0] == 'D') && (end[1] == 'b' || end[1] == 'B')
	    && (end[2] == '\0' || end[2] == ';'))
		return v;
	if (v <= 0.0f)
		return -60.0f;
	if (v > 100.0f)
		v = 100.0f;
	return 20.0f * log10f(v / 100.0f);
}

/* Longest-prefix match so "SIN" doesn't eat "SINE_SAW". */
static int
parse_shape(const char *s)
{
	static const struct {
		const char *name;
		int         value;
	} shapes[] = {
		{ "SINE_SAW_HARM",  APC_WAVE_SHAPE_SINE_SAW_HARM  },
		{ "SINE_SAW_CHORD", APC_WAVE_SHAPE_SINE_SAW_CHORD },
		{ "SINE_HARM",      APC_WAVE_SHAPE_SINE_HARM      },
		{ "SINE_SAW",       APC_WAVE_SHAPE_SINE_SAW       },
		{ "SILENCE",        APC_SHAPE_SILENCE             },
		{ "SAW",            APC_WAVE_SHAPE_SAWTOOTH       },
		{ "SIN",            APC_WAVE_SHAPE_SINE           },
		{ "SQ",             APC_WAVE_SHAPE_SQUARE         },
	};
	size_t i;

	if (s == NULL)
		return -1;
	for (i = 0; i < sizeof(shapes) / sizeof(shapes[0]); i++) {
		size_t len = strlen(shapes[i].name);
		if (strncmp(s, shapes[i].name, len) == 0 && (s[len] == '\0' || s[len] == ';'))
			return shapes[i].value;
	}
	return -1;
}

static void *
apc_b64_decode_alloc(const char *strbuf, size_t slen, size_t *outlen)
{
	char   *ret;
	ssize_t ol;
	size_t  sz;

	sz  = (slen + 3) / 4 * 3 + 1;
	ret = malloc(sz);
	if (!ret)
		return NULL;
	ol = b64_decode(ret, sz, strbuf, slen);
	if (ol == -1) {
		free(ret);
		return NULL;
	}
	if (outlen != NULL)
		*outlen = (size_t)ol;
	return ret;
}

/* ----- verb handlers ----- */

static void
do_load(char *str)
{
	char         *p;
	char         *end;
	char          audiofn[APC_AUDIO_PATH_MAX];
	int16_t      *frames  = NULL;
	size_t        nframes = 0;
	unsigned long slot    = AUDIO_APC_PATCH_SLOTS;

	/* K=V tokens until the first unknown one, which is the filename */
	for (p = str; p && *p == ';'; p = strchr(p + 1, ';')) {
		if (p[1] == 'S' && p[2] == '=') {
			slot = strtoul(p + 3, &end, 10);
			continue;
		}
		break;
	}
	if (slot >= AUDIO_APC_PATCH_SLOTS)
		return;
	if (p == NULL || *p != ';')
		return;
	if (!apc_cache_path(p + 1, audiofn, sizeof(audiofn)))
		return;
	if (!sndfile_available())
		return;
	if (!sndfile_decode(audiofn, &frames, &nframes))
		return;

	free(patches[slot].frames);
	patches[slot].frames  = frames;
	patches[slot].nframes = nframes;
}

static void
do_load_blob(char *str, size_t slen)
{
	char         *p;
	char         *end;
	uint8_t      *blob    = NULL;
	int16_t      *frames  = NULL;
	size_t        bloblen = 0;
	size_t        nframes = 0;
	unsigned long slot    = AUDIO_APC_PATCH_SLOTS;

	for (p = str; p && *p == ';'; p = strchr(p + 1, ';')) {
		if (p[1] == 'S' && p[2] == '=') {
			slot = strtoul(p + 3, &end, 10);
			continue;
		}
		break;
	}
	if (slot >= AUDIO_APC_PATCH_SLOTS)
		goto done;
	if (p == NULL || *p != ';')
		goto done;
	if (slen <= (size_t)(p + 1 - str))
		goto done;
	blob = apc_b64_decode_alloc(p + 1, slen - (size_t)(p + 1 - str), &bloblen);
	if (blob == NULL)
		goto done;
	if (!sndfile_decode_mem(blob, bloblen, &frames, &nframes))
		goto done;

	free(patches[slot].frames);
	patches[slot].frames  = frames;
	patches[slot].nframes = nframes;
	frames = NULL;
done:
	free(blob);
	free(frames);
}

static void
do_synth(char *str)
{
	char         *p;
	char         *end;
	unsigned long slot    = AUDIO_APC_PATCH_SLOTS;
	int           shape   = -1;
	double        freq    = 0.0;
	size_t        nframes = 0;
	int16_t      *buf;

	for (p = str; p && *p == ';'; p = strchr(p + 1, ';')) {
		if (p[1] == 'S' && p[2] == '=')
			slot = strtoul(p + 3, &end, 10);
		else if (p[1] == 'W' && p[2] == '=')
			shape = parse_shape(p + 3);
		else if (p[1] == 'F' && p[2] == '=')
			freq = strtod(p + 3, &end);
		else if (p[1] == 'T' && p[2] == '=')
			nframes = apc_parse_duration(p + 3, freq, true);
	}

	if (slot >= AUDIO_APC_PATCH_SLOTS)
		return;
	if (shape < 0 && shape != APC_SHAPE_SILENCE)
		return;
	if (nframes == 0 || nframes > INT32_MAX)
		return;
	if (shape == APC_SHAPE_SILENCE) {
		freq  = 0.0;
		shape = APC_WAVE_SHAPE_SINE;
	}

	buf = (int16_t *)malloc(nframes * XPBEEP_FRAMESIZE);
	if (buf == NULL)
		return;
	xptone_makewave(freq, buf, (int)nframes, (unsigned long)shape);

	free(patches[slot].frames);
	patches[slot].frames  = buf;
	patches[slot].nframes = nframes;
}

static void
do_copy(char *str)
{
	char         *p;
	char         *end;
	unsigned long src = AUDIO_APC_PATCH_SLOTS;
	unsigned long dst = AUDIO_APC_PATCH_SLOTS;
	int16_t      *copy;

	for (p = str; p && *p == ';'; p = strchr(p + 1, ';')) {
		if (p[1] == 'S' && p[2] == '=')
			src = strtoul(p + 3, &end, 10);
		else if (p[1] == 'D' && p[2] == '=')
			dst = strtoul(p + 3, &end, 10);
	}
	if (src >= AUDIO_APC_PATCH_SLOTS || dst >= AUDIO_APC_PATCH_SLOTS)
		return;
	if (patches[src].frames == NULL || patches[src].nframes == 0)
		return;

	copy = (int16_t *)malloc(patches[src].nframes * XPBEEP_FRAMESIZE);
	if (copy == NULL)
		return;
	memcpy(copy, patches[src].frames, patches[src].nframes * XPBEEP_FRAMESIZE);

	free(patches[dst].frames);
	patches[dst].frames  = copy;
	patches[dst].nframes = patches[src].nframes;
}

static void
do_queue(char *str)
{
	char             *p;
	char             *end;
	unsigned long     ch   = AUDIO_APC_CHANNELS;
	unsigned long     slot = AUDIO_APC_PATCH_SLOTS;
	xp_audio_opts_t   opts = XP_AUDIO_OPTS_INIT;
	xp_audio_handle_t h;

	for (p = str; p && *p == ';'; p = strchr(p + 1, ';')) {
		if (p[1] == 'C' && p[2] == '=') {
			ch = strtoul(p + 3, &end, 10);
		}
		else if (p[1] == 'S' && p[2] == '=') {
			slot = strtoul(p + 3, &end, 10);
		}
		else if (p[1] == 'I' && p[2] == '=') {
			opts.fade_in_frames = apc_parse_duration(p + 3, 0.0, false);
		}
		else if (p[1] == 'O' && p[2] == '=') {
			opts.fade_out_frames = apc_parse_duration(p + 3, 0.0, false);
		}
		else if (p[1] == 'X' && (p[2] == ';' || p[2] == '\0')) {
			opts.crossfade = true;
		}
		else if (p[1] == 'L' && (p[2] == ';' || p[2] == '\0')) {
			opts.loop = true;
		}
		else if (p[1] == 'V' && p[2] == 'L' && p[3] == '=') {
			opts.volume_l = apc_parse_volume(p + 4);
		}
		else if (p[1] == 'V' && p[2] == 'R' && p[3] == '=') {
			opts.volume_r = apc_parse_volume(p + 4);
		}
		else if (p[1] == 'V' && p[2] == '=') {
			float v = apc_parse_volume(p + 3);
			opts.volume_l = v;
			opts.volume_r = v;
		}
	}

	if (ch >= AUDIO_APC_CHANNELS || ch < AUDIO_APC_FIRST_APC_CH)
		return;
	if (slot >= AUDIO_APC_PATCH_SLOTS)
		return;
	if (patches[slot].frames == NULL || patches[slot].nframes == 0)
		return;

	h = channel_handle((int)ch);
	if (h < 0)
		return;

	/* The buffer moves to the mixer; append frees it itself on failure, so empty the slot either way. */
	xp_audio_append(h, patches[slot].frames, patches[slot].nframes, &opts);
	patches[slot].frames  = NULL;
	patches[slot].nframes = 0;
}

static void
do_flush(char *str)
{
	char             *p;
	char             *end;
	unsigned long     ch           = AUDIO_APC_CHANNELS;
	size_t            fadeout      = 0;
	bool              have_fadeout = false;
	xp_audio_handle_t h;

	for (p = str; p && *p == ';'; p = strchr(p + 1, ';')) {
		if (p[1] == 'C' && p[2] == '=') {
			ch = strtoul(p + 3, &end, 10);
		}
		else if (p[1] == 'O' && p[2] == '=') {
			fadeout      = apc_parse_duration(p + 3, 0.0, false);
			have_fadeout = true;
		}
	}
	if (ch >= AUDIO_APC_CHANNELS)
		return;
	h = channel_handle((int)ch);
	if (h < 0)
		return;

	if (have_fadeout && fadeout > 0) {
		/* A silent crossfade buffer whose fade-in is the fade length makes the head decay over it. */
		xp_audio_opts_t opts = XP_AUDIO_OPTS_INIT;
		int16_t        *silence;

		silence = (int16_t *)calloc(fadeout, XPBEEP_FRAMESIZE);
		if (silence == NULL) {
			xp_audio_clear(h);
			return;
		}
		opts.fade_in_frames = fadeout;
		opts.crossfade      = true;
		if (!xp_audio_append(h, silence, fadeout, &opts))
			xp_audio_clear(h);
	}
	else {
		xp_audio_clear(h);
	}
}

static void
do_volume(char *str)
{
	char             *p;
	char             *end;
	unsigned long     ch      = AUDIO_APC_CHANNELS;
	float             vl      = 0.0f;
	float             vr      = 0.0f;
	size_t            nframes = 0;
	bool              have_l  = false;
	bool              have_r  = false;
	xp_audio_handle_t h;

	for (p = str; p && *p == ';'; p = strchr(p + 1, ';')) {
		if (p[1] == 'C' && p[2] == '=') {
			ch = strtoul(p + 3, &end, 10);
		}
		else if (p[1] == 'V' && p[2] == 'L' && p[3] == '=') {
			vl     = apc_parse_volume(p + 4);
			have_l = true;
		}
		else if (p[1] == 'V' && p[2] == 'R' && p[3] == '=') {
			vr     = apc_parse_volume(p + 4);
			have_r = true;
		}
		else if (p[1] == 'V' && p[2] == '=') {
			float v = apc_parse_volume(p + 3);
			vl     = v;
			vr     = v;
			have_l = true;
			have_r = true;
		}
		else if (p[1] == 'T' && p[2] == '=') {
			nframes = apc_parse_duration(p + 3, 0.0, false);
		}
	}
	if (ch >= AUDIO_APC_CHANNELS)
		return;
	h = channel_handle((int)ch);
	if (h < 0)
		return;
	if (!have_l && !have_r)
		return;
	/* A VL-only or VR-only command keeps the other side's current level. */
	if (!have_l || !have_r) {
		float cur_l = AUDIO_APC_BASE_DB;
		float cur_r = AUDIO_APC_BASE_DB;
		xp_audio_get_volume(h, &cur_l, &cur_r);
		if (!have_l) vl = cur_l;
		if (!have_r) vr = cur_r;
	}
	if (nframes > 0)
		xp_audio_ramp_volume(h, vl, vr, nframes);
	else
		xp_audio_set_volume(h, vl, vr);
}

static void
do_wait(char *str)
{
	char             *p;
	char             *end;
	unsigned long     ch = AUDIO_APC_CHANNELS;
	xp_audio_handle_t h;

	for (p = str; p && *p == ';'; p = strchr(p + 1, ';')) {
		if (p[1] == 'C' && p[2] == '=')
			ch = strtoul(p + 3, &end, 10);
	}
	if (ch >= AUDIO_APC_CHANNELS)
		return;
	h = channel_handle((int)ch);
	if (h < 0)
		return;
	xp_audio_drain(h);   /* returns at once on a loop */
}

static void
do_update(char *str)
{
	char         *p;
	char         *end;
	unsigned long ch = AUDIO_APC_CHANNELS;

	for (p = str; p && *p == ';'; p = strchr(p + 1, ';')) {
		if (p[1] == 'C' && p[2] == '=')
			ch = strtoul(p + 3, &end, 10);
	}
	if (ch >= AUDIO_APC_CHANNELS)
		return;
	apc_notify[ch] = true;
}

/* ----- dispatchers ----- */

void
audio_apc_handler(char *strbuf, size_t slen)
{
	if (!apc_enabled)
		return;
	init_state_once();

	if (strncmp(strbuf, "LoadBlob", 8) == 0 && (strbuf[8] == ';' || strbuf[8] == '\0'))
		do_load_blob(strbuf + 8, slen - 8);
	else if (strncmp(strbuf, "Load", 4) == 0 && (strbuf[4] == ';' || strbuf[4] == '\0'))
		do_load(strbuf + 4);
	else if (strncmp(strbuf, "Synth", 5) == 0 && (strbuf[5] == ';' || strbuf[5] == '\0'))
		do_synth(strbuf + 5);
	else if (strncmp(strbuf, "Copy", 4) == 0 && (strbuf[4] == ';' || strbuf[4] == '\0'))
		do_copy(strbuf + 4);
	else if (strncmp(strbuf, "Queue", 5) == 0 && (strbuf[5] == ';' || strbuf[5] == '\0'))
		do_queue(strbuf + 5);
	else if (strncmp(strbuf, "Flush", 5) == 0 && (strbuf[5] == ';' || strbuf[5] == '\0'))
		do_flush(strbuf + 5);
	else if (strncmp(strbuf, "Volume", 6) == 0 && (strbuf[6] == ';' || strbuf[6] == '\0'))
		do_volume(strbuf + 6);
	else if (strncmp(strbuf, "Wait", 4) == 0 && (strbuf[4] == ';' || strbuf[4] == '\0'))
		do_wait(strbuf + 4);
	else if (strncmp(strbuf, "Update", 6) == 0 && (strbuf[6] == ';' || strbuf[6] == '\0'))
		do_update(strbuf + 6);
}

void
feature_query_handler(char *strbuf, size_t slen)
{
	char          tmp[64];
	int           avail = 0;
	int           n;
	char         *end;
	char         *substart;
	unsigned long major;
	unsigned long subtype;

	(void)slen;
	init_state_once();
	if (strcmp(strbuf, "libsndfile") == 0) {
		avail = (apc_enabled && sndfile_available()) ? 1 : 0;
		n = snprintf(tmp, sizeof(tmp), "\x1b[=7;%d;%dn", AUDIO_APC_FEATURE_SNDFILE, avail);
		if (n > 0)
			apc_send(tmp, (size_t)n);
	}
	else if (strncmp(strbuf, "libsndfileFormat;", 17) == 0) {
		errno = 0;
		major = strtoul(strbuf + 17, &end, 0);
		if (end == strbuf + 17 || *end != ';' || errno != 0 || major > UINT32_MAX)
			return;
		substart = end + 1;
		errno = 0;
		subtype = strtoul(substart, &end, 0);
		if (end == substart || *end != '\0' || errno != 0 || subtype > UINT32_MAX)
			return;
		avail = (apc_enabled && sndfile_format_available((uint32_t)major, (uint32_t)subtype)) ? 1 : 0;
		n = snprintf(tmp, sizeof(tmp), "\x1b[=7;%d;%lu;%lu;%dn",
		             AUDIO_APC_FEATURE_SNDFILE_FORMAT, major, subtype, avail);
		if (n > 0)
			apc_send(tmp, (size_t)n);
	}
}

void
audio_apc_poll(void)
{
	int i;

	if (!apc_channels_init)
		return;
	for (i = 0; i < AUDIO_APC_CHANNELS; i++) {
		xp_audio_handle_t h;
		int               state;

		if (!apc_notify[i])
			continue;
		h = channel_handle(i);
		state = (h >= 0 && !xp_audio_is_idle(h)) ? 1 : 0;
		if (apc_last_state[i] == 1 && state == 0) {
			char tmp[32];
			int  n = snprintf(tmp, sizeof(tmp), "\x1b[=7;%d;0n", i);
			if (n > 0)
				apc_send(tmp, (size_t)n);
			apc_notify[i] = false;
		}
		apc_last_state[i] = state;
	}
}

void
audio_apc_cleanup(void)
{
	int i;

	for (i = 0; i < AUDIO_APC_PATCH_SLOTS; i++) {
		free(patches[i].frames);
		patches[i].frames  = NULL;
		patches[i].nframes = 0;
	}
	if (apc_channels_init) {
		for (i = 0; i < AUDIO_APC_CHANNELS - AUDIO_APC_FIRST_APC_CH; i++) {
			if (apc_channels[i] >= 0) {
				xp_audio_close(apc_channels[i]);
				apc_channels[i] = -1;
			}
		}
	}
	for (i = 0; i < AUDIO_APC_CHANNELS; i++) {
		apc_notify[i]     = false;
		apc_last_state[i] = 0;
	}
}
