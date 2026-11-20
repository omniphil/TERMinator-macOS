/*
 * apc_mixer.c -- the stream mixer behind SyncTERM's audio APC, ported for the WPF bridge.
 *
 * This is upstream SyncTERM's xpbeep mixer core (src/xpdev/xpbeep.c: the xp_audio_* streams,
 * xp_mixer_pull, and xptone_makewave for A;Synth) without its device backends. A stream is a FIFO of
 * S16 stereo 44.1 kHz buffers with per-buffer dB volume, equal-power fade-in/out, loop and crossfade
 * overlays, a per-stream equal-power volume ramp, and one tanh soft-clip over the sum. The app's audio
 * output (Services/SyncTermAudioService.swift, an AVAudioSourceNode) pulls the mix through
 * native_apc_audio_pull() (apc_bridge.c).
 *
 * macOS: ported 2026-09-16 from the Windows client (TERMinator-Windows/native/apc_mixer.c), which is the master.
 * pthread mutexes stand in for CRITICAL_SECTION, a condition variable for the progress event, pthread_once for
 * INIT_ONCE. xp_audio_drain is capped (APC_DRAIN_CAP_MS) far lower than Windows' 10 s: the macOS poll loop runs
 * on the main thread, so A;Wait blocks the UI for as long as it waits.
 */

#include <pthread.h>
#include <time.h>
#include <unistd.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "apc_mixer.h"

#define S_RATE       XPBEEP_SAMPLE_RATE
#define S_CHANNELS   2
#define S_FRAMESIZE  XPBEEP_FRAMESIZE

#define XP_AUDIO_MAX_STREAMS      32
#define XP_AUDIO_FADE_TABLE_SIZE  1024
#define XP_AUDIO_POLL_MS          100
#define APC_DRAIN_CAP_MS          1000    /* Windows: 10000 -- see the header comment */
#define APC_OUTPUT_LATENCY_MS     30      /* AVAudioEngine's IO buffer (Windows: 100, its WASAPI buffer) */

#define WAVE_PI   3.14159265358979323846
#define WAVE_TPI  6.28318530717958647692

struct xp_audio_buf {
	int16_t             *frames;         /* owned -- free()d on drop */
	size_t               nframes;
	size_t               consumed;
	float                volume_l;       /* dB, sums with the stream base */
	float                volume_r;
	size_t               fade_in;
	size_t               fade_out;
	bool                 loop;
	size_t               loop_iter;
	size_t               overlay_total;
	size_t               overlay_elapsed;
	struct xp_audio_buf *next;
};

struct xp_audio_stream {
	struct xp_audio_buf *head;
	struct xp_audio_buf *tail;
	float                volume_l;       /* dB, live */
	float                volume_r;
	float                ramp_start_amp_l;
	float                ramp_start_amp_r;
	float                ramp_target_amp_l;
	float                ramp_target_amp_r;
	float                ramp_target_l;
	float                ramp_target_r;
	size_t               ramp_elapsed;
	size_t               ramp_total;
	bool                 finished;
	bool                 done;
	pthread_cond_t       progress;       /* broadcast when bufs are consumed or dropped; waits on `mutex` */
	pthread_mutex_t      mutex;
};

static struct xp_audio_stream *mixer_streams[XP_AUDIO_MAX_STREAMS];
static pthread_mutex_t         mixer_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_once_t          mixer_once = PTHREAD_ONCE_INIT;
static int16_t                 fade_gain_table[XP_AUDIO_FADE_TABLE_SIZE];   /* Q1.15 */

static void
mixer_init(void)
{
	int i;

	/* Equal-power fade curve gain = sin(t * pi/2); its cos complement (callers pass total-1-pos)
	 * keeps a crossfade at constant combined power. */
	for (i = 0; i < XP_AUDIO_FADE_TABLE_SIZE; i++) {
		double t    = (double)i / (double)(XP_AUDIO_FADE_TABLE_SIZE - 1);
		double gain = sin(t * WAVE_PI * 0.5);
		int    q15  = (int)(gain * 32767.0 + 0.5);
		if (q15 > 32767) q15 = 32767;
		if (q15 < 0)     q15 = 0;
		fade_gain_table[i] = (int16_t)q15;
	}
}

static void
mixer_ensure_init(void)
{
	pthread_once(&mixer_once, mixer_init);
}

static int16_t
fade_gain_q15(size_t pos, size_t total)
{
	double norm;
	double idx_f;
	int    idx;
	double frac;

	if (total == 0 || pos >= total)
		return 32767;
	norm  = (double)pos / (double)total;
	idx_f = norm * (double)(XP_AUDIO_FADE_TABLE_SIZE - 1);
	idx   = (int)idx_f;
	if (idx >= XP_AUDIO_FADE_TABLE_SIZE - 1)
		return fade_gain_table[XP_AUDIO_FADE_TABLE_SIZE - 1];
	frac = idx_f - (double)idx;
	return (int16_t)(fade_gain_table[idx] * (1.0 - frac) + fade_gain_table[idx + 1] * frac);
}

static struct xp_audio_stream *
stream_from_handle(xp_audio_handle_t h)
{
	struct xp_audio_stream *s;

	if (h < 0 || h >= XP_AUDIO_MAX_STREAMS)
		return NULL;
	mixer_ensure_init();
	pthread_mutex_lock(&mixer_lock);
	s = mixer_streams[h];
	pthread_mutex_unlock(&mixer_lock);
	return s;
}

static void
free_buf(struct xp_audio_buf *b)
{
	free(b->frames);
	free(b);
}

/* s->mutex held */
static void
drop_all_bufs_locked(struct xp_audio_stream *s)
{
	struct xp_audio_buf *b = s->head;

	while (b) {
		struct xp_audio_buf *next = b->next;
		free_buf(b);
		b = next;
	}
	s->head = s->tail = NULL;
}

/* Mixes one buf into the int32 accumulator for up to `frames` frames; returns true when the buf
 * should be dropped (natural end or overlay expiry). */
static bool
mix_one_buf(struct xp_audio_buf *b, int32_t *accum, size_t frames, float vl, float vr, size_t *written)
{
	size_t j;
	bool   drop   = false;
	float  gain_l = powf(10.0f, (vl + b->volume_l) / 20.0f);
	float  gain_r = powf(10.0f, (vr + b->volume_r) / 20.0f);

	for (j = 0; j < frames; j++) {
		int16_t s_l;
		int16_t s_r;
		int32_t gain_q15 = 32767;
		int32_t l_val;
		int32_t r_val;

		if (b->overlay_total > 0 && b->overlay_elapsed >= b->overlay_total) {
			drop = true;
			break;
		}
		if (b->consumed >= b->nframes) {
			if (b->loop) {
				b->consumed = 0;
				b->loop_iter++;
			}
			else {
				drop = true;
				break;
			}
		}

		s_l = b->frames[b->consumed * 2 + 0];
		s_r = b->frames[b->consumed * 2 + 1];

		if (b->loop_iter == 0 && b->fade_in > 0 && b->consumed < b->fade_in) {
			int16_t g = fade_gain_q15(b->consumed, b->fade_in);
			gain_q15 = (gain_q15 * g) >> 15;
		}
		if (!b->loop && b->fade_out > 0 && b->consumed + b->fade_out >= b->nframes) {
			int16_t g = fade_gain_q15(b->nframes - 1 - b->consumed, b->fade_out);
			gain_q15 = (gain_q15 * g) >> 15;
		}
		if (b->overlay_total > 0) {
			int16_t g = fade_gain_q15(b->overlay_total - 1 - b->overlay_elapsed, b->overlay_total);
			gain_q15 = (gain_q15 * g) >> 15;
		}

		l_val = ((int32_t)s_l * gain_q15) >> 15;
		r_val = ((int32_t)s_r * gain_q15) >> 15;
		l_val = (int32_t)((float)l_val * gain_l);
		r_val = (int32_t)((float)r_val * gain_r);

		accum[j * 2 + 0] += l_val;
		accum[j * 2 + 1] += r_val;

		b->consumed++;
		if (b->overlay_total > 0)
			b->overlay_elapsed++;
	}
	*written = j;
	if (!drop && b->overlay_total > 0 && b->overlay_elapsed >= b->overlay_total)
		drop = true;
	if (!drop && b->consumed >= b->nframes && !b->loop)
		drop = true;
	return drop;
}

static int16_t
soft_clip_narrow(int32_t sum)
{
	float   x   = (float)sum / 32767.0f;
	float   y   = tanhf(x);
	int32_t out = (int32_t)(y * 32767.0f);

	if (out > 32767)       out = 32767;
	else if (out < -32768) out = -32768;
	return (int16_t)out;
}

/* s->mutex held */
static void
advance_volume_ramp_locked(struct xp_audio_stream *s, size_t frames)
{
	size_t remaining;
	size_t step;
	size_t pos;
	float  rising_curve;
	float  falling_curve;
	float  amp_l;
	float  amp_r;

	if (s->ramp_total == 0)
		return;
	remaining = s->ramp_total - s->ramp_elapsed;
	step      = frames < remaining ? frames : remaining;
	s->ramp_elapsed += step;
	if (s->ramp_elapsed >= s->ramp_total) {
		s->volume_l   = s->ramp_target_l;
		s->volume_r   = s->ramp_target_r;
		s->ramp_total = 0;
		return;
	}
	pos           = s->ramp_elapsed;
	rising_curve  = (float)fade_gain_q15(pos, s->ramp_total) / 32767.0f;
	falling_curve = (float)fade_gain_q15(s->ramp_total - 1 - pos, s->ramp_total) / 32767.0f;
	if (s->ramp_target_amp_l >= s->ramp_start_amp_l)
		amp_l = s->ramp_start_amp_l + (s->ramp_target_amp_l - s->ramp_start_amp_l) * rising_curve;
	else
		amp_l = s->ramp_target_amp_l + (s->ramp_start_amp_l - s->ramp_target_amp_l) * falling_curve;
	if (s->ramp_target_amp_r >= s->ramp_start_amp_r)
		amp_r = s->ramp_start_amp_r + (s->ramp_target_amp_r - s->ramp_start_amp_r) * rising_curve;
	else
		amp_r = s->ramp_target_amp_r + (s->ramp_start_amp_r - s->ramp_target_amp_r) * falling_curve;
	s->volume_l = (amp_l > 1e-6f) ? 20.0f * log10f(amp_l) : -60.0f;
	s->volume_r = (amp_r > 1e-6f) ? 20.0f * log10f(amp_r) : -60.0f;
}

size_t
xp_mixer_pull(int16_t *out, size_t frames)
{
	static int32_t *accum     = NULL;
	static size_t   accum_cap = 0;
	int             i;
	size_t          j;
	size_t          max_n = 0;

	mixer_ensure_init();
	pthread_mutex_lock(&mixer_lock);

	if (accum_cap < frames) {
		int32_t *p = (int32_t *)realloc(accum, frames * S_CHANNELS * sizeof(int32_t));
		if (!p) {
			pthread_mutex_unlock(&mixer_lock);
			memset(out, 0, frames * S_FRAMESIZE);
			return 0;
		}
		accum     = p;
		accum_cap = frames;
	}
	memset(accum, 0, frames * S_CHANNELS * sizeof(int32_t));

	for (i = 0; i < XP_AUDIO_MAX_STREAMS; i++) {
		struct xp_audio_stream *s = mixer_streams[i];
		struct xp_audio_buf    *head;
		struct xp_audio_buf    *next;
		float                   vl;
		float                   vr;
		bool                    dropped_any = false;
		size_t                  off;
		size_t                  written;
		bool                    drop;
		bool                    drop_next;

		if (!s)
			continue;
		pthread_mutex_lock(&s->mutex);
		advance_volume_ramp_locked(s, frames);
		if (s->done || !s->head) {
			pthread_mutex_unlock(&s->mutex);
			continue;
		}
		vl = s->volume_l;
		vr = s->volume_r;

		/* FIFO with gapless hand-off; a crossfade pair (head decaying, next rising) mixes concurrently. */
		off = 0;
		for (;;) {
			head = s->head;
			if (head == NULL || off >= frames)
				break;
			next = head->next;

			if (head->overlay_total > 0 && next) {
				struct xp_audio_buf *after_next = next->next;

				written = 0;
				drop = mix_one_buf(head, accum + off * S_CHANNELS, frames - off, vl, vr, &written);
				if (off + written > max_n)
					max_n = off + written;
				drop_next = mix_one_buf(next, accum + off * S_CHANNELS, frames - off, vl, vr, &written);
				if (off + written > max_n)
					max_n = off + written;
				if (drop_next) {
					head->next = after_next;
					if (s->tail == next)
						s->tail = head;
					free_buf(next);
					dropped_any = true;
				}
				if (drop) {
					s->head = head->next;
					if (s->tail == head)
						s->tail = NULL;
					free_buf(head);
					dropped_any = true;
				}
				break;
			}

			written = 0;
			drop = mix_one_buf(head, accum + off * S_CHANNELS, frames - off, vl, vr, &written);
			off += written;
			if (off > max_n)
				max_n = off;
			if (!drop)
				break;

			s->head = head->next;
			if (s->tail == head)
				s->tail = NULL;
			free_buf(head);
			dropped_any = true;
		}

		if (s->finished && !s->head && !s->done)
			s->done = true;
		if (dropped_any || s->head == NULL)
			pthread_cond_broadcast(&s->progress);
		pthread_mutex_unlock(&s->mutex);
	}

	for (j = 0; j < frames * S_CHANNELS; j++)
		out[j] = soft_clip_narrow(accum[j]);

	pthread_mutex_unlock(&mixer_lock);
	return max_n;
}

/* mixer_lock held, stream already unlinked */
static void
free_stream_locked(struct xp_audio_stream *s)
{
	drop_all_bufs_locked(s);
	pthread_cond_destroy(&s->progress);
	pthread_mutex_destroy(&s->mutex);
	free(s);
}

xp_audio_handle_t
xp_audio_open(float volume_l, float volume_r)
{
	struct xp_audio_stream *s;
	xp_audio_handle_t       handle = -1;
	int                     i;

	mixer_ensure_init();
	s = calloc(1, sizeof(*s));
	if (!s)
		return -1;
	s->volume_l = volume_l;
	s->volume_r = volume_r;
	if (pthread_mutex_init(&s->mutex, NULL) != 0) {
		free(s);
		return -1;
	}
	if (pthread_cond_init(&s->progress, NULL) != 0) {
		pthread_mutex_destroy(&s->mutex);
		free(s);
		return -1;
	}

	pthread_mutex_lock(&mixer_lock);
	for (i = 0; i < XP_AUDIO_MAX_STREAMS; i++) {
		if (!mixer_streams[i]) {
			mixer_streams[i] = s;
			handle = i;
			break;
		}
	}
	if (handle < 0)
		free_stream_locked(s);
	pthread_mutex_unlock(&mixer_lock);
	return handle;
}

void
xp_audio_close(xp_audio_handle_t h)
{
	struct xp_audio_stream *s;

	if (h < 0 || h >= XP_AUDIO_MAX_STREAMS)
		return;
	mixer_ensure_init();
	pthread_mutex_lock(&mixer_lock);
	s = mixer_streams[h];
	mixer_streams[h] = NULL;
	if (s) {
		pthread_mutex_lock(&s->mutex);
		s->done = true;
		pthread_cond_broadcast(&s->progress);
		pthread_mutex_unlock(&s->mutex);
		free_stream_locked(s);
	}
	pthread_mutex_unlock(&mixer_lock);
}

bool
xp_audio_append(xp_audio_handle_t h, int16_t *frames, size_t nframes, const xp_audio_opts_t *opts)
{
	struct xp_audio_stream *s = stream_from_handle(h);
	struct xp_audio_buf    *node;

	if (!s || !frames || nframes == 0) {
		free(frames);
		return false;
	}
	node = calloc(1, sizeof(*node));
	if (!node) {
		free(frames);
		return false;
	}
	node->frames   = frames;
	node->nframes  = nframes;
	node->volume_l = 0.0f;
	node->volume_r = 0.0f;
	if (opts) {
		node->fade_in  = (opts->fade_in_frames  < nframes) ? opts->fade_in_frames  : nframes;
		node->fade_out = (opts->fade_out_frames < nframes) ? opts->fade_out_frames : nframes;
		if (node->fade_in + node->fade_out > nframes) {
			size_t sum    = node->fade_in + node->fade_out;
			size_t new_fi = (size_t)((uint64_t)nframes * node->fade_in / sum);
			node->fade_out = nframes - new_fi;
			node->fade_in  = new_fi;
		}
		node->loop     = opts->loop;
		node->volume_l = opts->volume_l;
		node->volume_r = opts->volume_r;
	}

	pthread_mutex_lock(&s->mutex);
	if (s->finished || s->done) {
		pthread_mutex_unlock(&s->mutex);
		free_buf(node);
		return false;
	}
	/* Crossfade: the current tail starts decaying over the new buf's fade-in. */
	if (opts && opts->crossfade && opts->fade_in_frames > 0 && s->tail) {
		s->tail->overlay_total   = opts->fade_in_frames;
		s->tail->overlay_elapsed = 0;
	}
	if (s->tail)
		s->tail->next = node;
	else
		s->head = node;
	s->tail = node;
	pthread_cond_broadcast(&s->progress);
	pthread_mutex_unlock(&s->mutex);
	return true;
}

void
xp_audio_set_volume(xp_audio_handle_t h, float volume_l, float volume_r)
{
	struct xp_audio_stream *s = stream_from_handle(h);

	if (!s)
		return;
	pthread_mutex_lock(&s->mutex);
	s->volume_l   = volume_l;
	s->volume_r   = volume_r;
	s->ramp_total = 0;
	pthread_mutex_unlock(&s->mutex);
}

void
xp_audio_ramp_volume(xp_audio_handle_t h, float target_l, float target_r, size_t nframes)
{
	struct xp_audio_stream *s = stream_from_handle(h);

	if (!s)
		return;
	pthread_mutex_lock(&s->mutex);
	if (nframes == 0) {
		s->volume_l   = target_l;
		s->volume_r   = target_r;
		s->ramp_total = 0;
	}
	else {
		s->ramp_start_amp_l  = powf(10.0f, s->volume_l / 20.0f);
		s->ramp_start_amp_r  = powf(10.0f, s->volume_r / 20.0f);
		s->ramp_target_amp_l = powf(10.0f, target_l / 20.0f);
		s->ramp_target_amp_r = powf(10.0f, target_r / 20.0f);
		s->ramp_target_l     = target_l;
		s->ramp_target_r     = target_r;
		s->ramp_elapsed      = 0;
		s->ramp_total        = nframes;
	}
	pthread_mutex_unlock(&s->mutex);
}

void
xp_audio_get_volume(xp_audio_handle_t h, float *volume_l, float *volume_r)
{
	struct xp_audio_stream *s = stream_from_handle(h);

	if (!s)
		return;
	pthread_mutex_lock(&s->mutex);
	if (volume_l)
		*volume_l = s->volume_l;
	if (volume_r)
		*volume_r = s->volume_r;
	pthread_mutex_unlock(&s->mutex);
}

bool
xp_audio_is_idle(xp_audio_handle_t h)
{
	struct xp_audio_stream *s = stream_from_handle(h);
	bool                    idle;

	if (!s)
		return true;
	pthread_mutex_lock(&s->mutex);
	idle = (s->head == NULL) || s->done;
	pthread_mutex_unlock(&s->mutex);
	return idle;
}

void
xp_audio_finish(xp_audio_handle_t h)
{
	struct xp_audio_stream *s = stream_from_handle(h);
	struct xp_audio_buf    *b;

	if (!s)
		return;
	pthread_mutex_lock(&s->mutex);
	s->finished = true;
	/* End in-flight loops: nothing will arrive to end them by crossfade now. */
	for (b = s->head; b; b = b->next) {
		if (b->loop) {
			b->loop = false;
			if (b->fade_out > 0) {
				size_t remaining = b->nframes - b->consumed;
				if (remaining < b->fade_out) {
					b->overlay_total   = remaining;
					b->overlay_elapsed = 0;
				}
			}
		}
	}
	if (!s->head && !s->done)
		s->done = true;
	pthread_cond_broadcast(&s->progress);
	pthread_mutex_unlock(&s->mutex);
}

void
xp_audio_stop(xp_audio_handle_t h)
{
	struct xp_audio_stream *s = stream_from_handle(h);

	if (!s)
		return;
	pthread_mutex_lock(&s->mutex);
	drop_all_bufs_locked(s);
	s->finished = true;
	s->done     = true;
	pthread_cond_broadcast(&s->progress);
	pthread_mutex_unlock(&s->mutex);
}

void
xp_audio_clear(xp_audio_handle_t h)
{
	struct xp_audio_stream *s = stream_from_handle(h);

	if (!s)
		return;
	pthread_mutex_lock(&s->mutex);
	drop_all_bufs_locked(s);
	pthread_cond_broadcast(&s->progress);
	pthread_mutex_unlock(&s->mutex);
}

/* Blocks until the stream's queued (non-looping) bufs are consumed, the stream is done, or the cap
 * passes. Streams are only closed by audio_apc_cleanup(), which runs under the bridge's g_lock -- the
 * same lock the only caller (A;Wait, inside cterm_write) holds -- so `s` can't be freed mid-wait. */
static uint64_t
monotonic_ms(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000u + (uint64_t)(ts.tv_nsec / 1000000);
}

static void
xp_audio_mixer_sync(xp_audio_handle_t h)
{
	struct xp_audio_stream *s     = stream_from_handle(h);
	uint64_t                start = monotonic_ms();

	if (!s)
		return;
	pthread_mutex_lock(&s->mutex);
	while (s->head && !s->done) {
		struct timespec deadline;

		if (s->head->loop && s->head->overlay_total == 0)
			break;
		if (monotonic_ms() - start >= APC_DRAIN_CAP_MS)
			break;
#ifdef __APPLE__
		/* Relative, so a wall-clock step can't stretch one wait (macOS has no pthread_condattr_setclock) */
		deadline.tv_sec  = 0;
		deadline.tv_nsec = XP_AUDIO_POLL_MS * 1000000L;
		(void)pthread_cond_timedwait_relative_np(&s->progress, &s->mutex, &deadline);
#else
		/* pthread_cond_timedwait takes a CLOCK_REALTIME deadline */
		clock_gettime(CLOCK_REALTIME, &deadline);
		deadline.tv_nsec += XP_AUDIO_POLL_MS * 1000000L;
		if (deadline.tv_nsec >= 1000000000L) {
			deadline.tv_sec++;
			deadline.tv_nsec -= 1000000000L;
		}
		(void)pthread_cond_timedwait(&s->progress, &s->mutex, &deadline);
#endif
	}
	pthread_mutex_unlock(&s->mutex);
}

void
xp_audio_drain(xp_audio_handle_t h)
{
	xp_audio_mixer_sync(h);
	usleep(APC_OUTPUT_LATENCY_MS * 1000);
}

/* Upstream's tone generator, unchanged apart from the types. SINE/SAWTOOTH/SQUARE compute in S16; the
 * noisy shapes keep their original U8 arithmetic artifacts on purpose. */
void
xptone_makewave(double freq, int16_t *wave, int samples, unsigned long shape)
{
	int      i;
	int      midpoint;
	double   inc;
	double   pos;
	bool     endhigh;
	int      crossings;
	int      numcross = 0;
	bool     noisy;
	int16_t *mono;

	if (samples <= 0)
		return;
	if (freq == 0) {
		memset(wave, 0, (size_t)samples * S_FRAMESIZE);
		return;
	}

	midpoint = samples / 2;
	inc      = 8.0 * atan(1.0);
	inc     *= ((double)freq / (double)S_RATE);
	mono     = wave;

	switch (shape & APC_WAVE_SHAPE_MASK) {
		case APC_WAVE_SHAPE_SINE_HARM:
		case APC_WAVE_SHAPE_SINE_SAW:
		case APC_WAVE_SHAPE_SINE_SAW_CHORD:
		case APC_WAVE_SHAPE_SINE_SAW_HARM:
			noisy = true;
			break;
		default:
			noisy = false;
			break;
	}

	for (i = 0; i < samples; i++) {
		pos  = (inc * (double)i);
		pos -= (int)(pos / WAVE_TPI) * WAVE_TPI;
		if (noisy) {
			unsigned char u8 = 0;
			switch (shape & APC_WAVE_SHAPE_MASK) {
				case APC_WAVE_SHAPE_SINE_HARM:
					u8 = (unsigned char)((sin(pos)) * 64 + 128);
					u8 = (unsigned char)((sin((inc * 2) * (double)i)) * 24);
					u8 = (unsigned char)((sin((inc * 3) * (double)i)) * 16);
					break;
				case APC_WAVE_SHAPE_SINE_SAW:
					u8 = (unsigned char)((((sin(pos)) * 127 + 128) + ((WAVE_TPI - pos) * 40.5)) / 2);
					break;
				case APC_WAVE_SHAPE_SINE_SAW_CHORD:
					u8  = (unsigned char)((((sin(pos)) * 64 + 128) + ((WAVE_TPI - pos) * 6.2)) / 2);
					u8 += (unsigned char)((sin((inc / 2) * (double)i)) * 24);
					u8 += (unsigned char)((sin((inc / 3) * (double)i)) * 16);
					break;
				case APC_WAVE_SHAPE_SINE_SAW_HARM:
					u8  = (unsigned char)((((sin(pos)) * 64 + 128) + ((WAVE_TPI - pos) * 6.2)) / 2);
					u8 += (unsigned char)((sin((inc * 2) * (double)i)) * 24);
					u8 += (unsigned char)((sin((inc * 3) * (double)i)) * 16);
					break;
			}
			mono[i] = (int16_t)(((int)u8 - 128) << 8);
		}
		else {
			double v = 0.0;
			switch (shape & APC_WAVE_SHAPE_MASK) {
				case APC_WAVE_SHAPE_SINE:
					v = sin(pos) * 32767.0;
					break;
				case APC_WAVE_SHAPE_SAWTOOTH:
					v = 32767.0 - (pos / WAVE_TPI) * 65535.0;
					break;
				case APC_WAVE_SHAPE_SQUARE:
					v = (pos < WAVE_PI) ? 32767.0 : -32768.0;
					break;
			}
			mono[i] = (int16_t)v;
		}
	}

	if ((shape & APC_WAVE_SHAPE_NO_CLEAN) == 0) {
		/* Click prevention: trim the trailing partial wave, ramp the first/last zero crossings. */
		endhigh = (mono[samples - 1] > 0);
		i = samples - 1;
		if (mono[i] != 0) {
			for (; i > midpoint; i--) {
				if (endhigh && mono[i] < 0)
					break;
				if (!endhigh && mono[i] > 0)
					break;
				mono[i] = 0;
			}
		}

		numcross = (int)(freq / 100);
		if (numcross) {
			int d;
			crossings = 0;
			for (i = 0; i < (samples - 1); i++) {
				if (((mono[i] < 0 && mono[i + 1] >= 0) || (mono[i] > 0 && mono[i + 1] <= 0)) && i > 2) {
					crossings++;
					if (crossings >= numcross)
						break;
				}
				d = numcross - crossings;
				mono[i] = (int16_t)(mono[i] / (d * d));
			}
			crossings = 0;
			for (i = samples - 1; i > 0; i--) {
				if (((mono[i] < 0 && mono[i - 1] >= 0) || (mono[i] > 0 && mono[i - 1] <= 0)) && i > 2) {
					crossings++;
					if (crossings >= numcross)
						break;
				}
				d = numcross - crossings;
				mono[i] = (int16_t)(mono[i] / (d * d));
			}
		}
	}

	/* Expand mono to stereo in place, high to low. */
	for (i = samples - 1; i >= 0; i--) {
		int16_t v = mono[i];
		wave[i * 2]     = v;
		wave[i * 2 + 1] = v;
	}
}
