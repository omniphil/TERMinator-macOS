/*
 * apc_sndfile.c -- libsndfile decoding for the audio APC, ported from upstream SyncTERM's
 * src/syncterm/xp_sndfile.c (its WITH_SNDFILE runtime-load mode).
 *
 * macOS: ported 2026-09-16 from the Windows client (TERMinator-Windows/native/apc_sndfile.c), which is the
 * master. libsndfile is dlopen()ed from the app bundle's Contents/Frameworks (vendored and signed by
 * scripts/vendor-apc-libs.sh + the "Embed APC libraries" build phase), falling back to the normal dyld search.
 * Paths are UTF-8 already, so plain sf_open (Windows needs sf_wchar_open).
 */

#include <dlfcn.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <sndfile.h>

#include "apc_sndfile.h"

#define SNDFILE_FORMAT_TYPE_SHIFT 16
#define XPBEEP_TARGET_RATE        44100
#define APC_SNDFILE_MAX_RAW_BYTES ((size_t)1 << 30)   /* refuse absurd decodes (~1 GiB of PCM) */

static struct {
	void        *dl;
	SNDFILE   *(*open_fn)(const char *path, int mode, SF_INFO *info);
	SNDFILE   *(*open_virtual_fn)(SF_VIRTUAL_IO *sfvirtual, int mode, SF_INFO *sfinfo, void *user_data);
	sf_count_t (*readf_short)(SNDFILE *sf, short *ptr, sf_count_t frames);
	int        (*close_fn)(SNDFILE *sf);
	int        (*format_check)(const SF_INFO *info);
} sf_api;

static pthread_once_t sf_once = PTHREAD_ONCE_INIT;
static bool           sf_loaded;

static void
sndfile_load(void)
{
	sf_api.dl = dlopen("@executable_path/../Frameworks/libsndfile.1.dylib", RTLD_NOW | RTLD_LOCAL);
	if (sf_api.dl == NULL)   /* rarely loads: library validation refuses another team's dylib (see apc_image.c) */
		sf_api.dl = dlopen("libsndfile.1.dylib", RTLD_NOW | RTLD_LOCAL);
	if (sf_api.dl == NULL)
		return;
	sf_api.open_fn         = dlsym(sf_api.dl, "sf_open");
	sf_api.open_virtual_fn = dlsym(sf_api.dl, "sf_open_virtual");
	sf_api.readf_short     = dlsym(sf_api.dl, "sf_readf_short");
	sf_api.close_fn        = dlsym(sf_api.dl, "sf_close");
	sf_api.format_check    = dlsym(sf_api.dl, "sf_format_check");
	if (sf_api.open_fn == NULL || sf_api.open_virtual_fn == NULL || sf_api.readf_short == NULL
	    || sf_api.close_fn == NULL || sf_api.format_check == NULL) {
		dlclose(sf_api.dl);
		sf_api.dl = NULL;
		return;
	}
	sf_loaded = true;
}

static bool
sndfile_ensure_loaded(void)
{
	pthread_once(&sf_once, sndfile_load);
	return sf_loaded;
}

bool
sndfile_available(void)
{
	return sndfile_ensure_loaded();
}

bool
sndfile_format_available(uint32_t major, uint32_t subtype)
{
	SF_INFO  info;
	uint32_t max_major = SF_FORMAT_TYPEMASK >> SNDFILE_FORMAT_TYPE_SHIFT;

	if (!sndfile_ensure_loaded())
		return false;
	if (major == 0 || major > max_major || subtype == 0 || subtype > SF_FORMAT_SUBMASK)
		return false;
	memset(&info, 0, sizeof(info));
	info.samplerate = XPBEEP_TARGET_RATE;
	info.channels   = 2;
	info.format     = (int)(((major << SNDFILE_FORMAT_TYPE_SHIFT) & SF_FORMAT_TYPEMASK)
	                        | (subtype & SF_FORMAT_SUBMASK));
	return sf_api.format_check(&info) != 0;
}

/* Linear-interpolation resample to 44100 and channel remap to stereo (mono doubled, >2 takes L/R). */
static int16_t *
resample_to_s16_stereo_44100(const int16_t *src, size_t src_nframes, int src_channels,
                             int src_rate, size_t *out_nframes)
{
	int16_t *dst;
	size_t   dst_nframes;
	size_t   j;

	if (src_rate <= 0 || src_channels <= 0 || src_nframes == 0) {
		*out_nframes = 0;
		return NULL;
	}

	dst_nframes = (size_t)(((uint64_t)src_nframes * XPBEEP_TARGET_RATE + (src_rate / 2)) / src_rate);
	if (dst_nframes == 0)
		dst_nframes = 1;

	dst = (int16_t *)malloc(dst_nframes * 2 * sizeof(int16_t));
	if (dst == NULL) {
		*out_nframes = 0;
		return NULL;
	}

	for (j = 0; j < dst_nframes; j++) {
		/* Integer index and remainder kept apart so j * src_rate * 2^32 never overflows. */
		uint64_t whole_pos = (uint64_t)j * (uint64_t)src_rate;
		uint64_t idx_int   = whole_pos / (uint64_t)XPBEEP_TARGET_RATE;
		uint64_t rem       = whole_pos - idx_int * (uint64_t)XPBEEP_TARGET_RATE;
		uint32_t idx_frac  = (uint32_t)((rem * 0x100000000ULL) / (uint64_t)XPBEEP_TARGET_RATE);
		size_t   lidx_a;
		size_t   lidx_b;
		size_t   ridx_a;
		size_t   ridx_b;
		int32_t  la;
		int32_t  lb;
		int32_t  ra;
		int32_t  rb;
		int32_t  l_interp;
		int32_t  r_interp;

		if (idx_int >= src_nframes) {
			idx_int  = src_nframes - 1;
			idx_frac = 0;
		}

		lidx_a = (size_t)idx_int * (size_t)src_channels;
		lidx_b = (idx_int + 1 < src_nframes) ? lidx_a + (size_t)src_channels : lidx_a;
		ridx_a = lidx_a;
		ridx_b = lidx_b;
		if (src_channels >= 2) {
			ridx_a = lidx_a + 1;
			ridx_b = lidx_b + 1;
		}

		la = src[lidx_a];
		lb = src[lidx_b];
		ra = src[ridx_a];
		rb = src[ridx_b];
		l_interp = (int32_t)(la + (((int64_t)(lb - la) * idx_frac) >> 32));
		r_interp = (int32_t)(ra + (((int64_t)(rb - ra) * idx_frac) >> 32));

		if (l_interp >  32767) l_interp =  32767;
		if (l_interp < -32768) l_interp = -32768;
		if (r_interp >  32767) r_interp =  32767;
		if (r_interp < -32768) r_interp = -32768;
		dst[j * 2 + 0] = (int16_t)l_interp;
		dst[j * 2 + 1] = (int16_t)r_interp;
	}

	*out_nframes = dst_nframes;
	return dst;
}

static bool
decode_sndfile(SNDFILE *sf, const SF_INFO *info, int16_t **out_frames, size_t *out_nframes)
{
	int16_t   *raw       = NULL;
	int16_t   *converted = NULL;
	size_t     raw_bytes;
	sf_count_t read;
	size_t     converted_n;

	if (info->frames <= 0 || info->channels <= 0 || info->samplerate <= 0)
		goto fail;
	if ((uint64_t)info->frames > APC_SNDFILE_MAX_RAW_BYTES / sizeof(int16_t) / (uint64_t)info->channels)
		goto fail;

	raw_bytes = (size_t)info->frames * (size_t)info->channels * sizeof(int16_t);
	raw = (int16_t *)malloc(raw_bytes);
	if (raw == NULL)
		goto fail;
	read = sf_api.readf_short(sf, raw, info->frames);
	if (read <= 0)
		goto fail;

	converted = resample_to_s16_stereo_44100(raw, (size_t)read, info->channels, info->samplerate,
	                                         &converted_n);
	if (converted == NULL)
		goto fail;

	free(raw);
	*out_frames  = converted;
	*out_nframes = converted_n;
	return true;

fail:
	free(raw);
	return false;
}

bool
sndfile_decode(const char *utf8path, int16_t **out_frames, size_t *out_nframes)
{
	SNDFILE *sf;
	SF_INFO  info;
	bool     ret;

	if (out_frames)  *out_frames  = NULL;
	if (out_nframes) *out_nframes = 0;
	if (utf8path == NULL || out_frames == NULL || out_nframes == NULL)
		return false;
	if (!sndfile_ensure_loaded())
		return false;

	memset(&info, 0, sizeof(info));
	sf = sf_api.open_fn(utf8path, SFM_READ, &info);
	if (sf == NULL)
		return false;
	ret = decode_sndfile(sf, &info, out_frames, out_nframes);
	sf_api.close_fn(sf);
	return ret;
}

struct sndfile_mem {
	const uint8_t *data;
	sf_count_t     len;
	sf_count_t     pos;
};

static sf_count_t
sndfile_mem_len(void *user_data)
{
	return ((struct sndfile_mem *)user_data)->len;
}

static sf_count_t
sndfile_mem_seek(sf_count_t offset, int whence, void *user_data)
{
	struct sndfile_mem *mem = user_data;
	sf_count_t          pos;

	switch (whence) {
		case SEEK_SET:
			pos = offset;
			break;
		case SEEK_CUR:
			pos = mem->pos + offset;
			break;
		case SEEK_END:
			pos = mem->len + offset;
			break;
		default:
			return -1;
	}
	if (pos < 0 || pos > mem->len)
		return -1;
	mem->pos = pos;
	return mem->pos;
}

static sf_count_t
sndfile_mem_read(void *ptr, sf_count_t count, void *user_data)
{
	struct sndfile_mem *mem = user_data;
	sf_count_t          avail;

	if (count <= 0)
		return 0;
	avail = mem->len - mem->pos;
	if (count > avail)
		count = avail;
	memcpy(ptr, mem->data + mem->pos, (size_t)count);
	mem->pos += count;
	return count;
}

static sf_count_t
sndfile_mem_write(const void *ptr, sf_count_t count, void *user_data)
{
	(void)ptr;
	(void)count;
	(void)user_data;
	return 0;
}

static sf_count_t
sndfile_mem_tell(void *user_data)
{
	return ((struct sndfile_mem *)user_data)->pos;
}

bool
sndfile_decode_mem(const void *data, size_t len, int16_t **out_frames, size_t *out_nframes)
{
	SF_VIRTUAL_IO      vio;
	struct sndfile_mem mem;
	SNDFILE           *sf;
	SF_INFO            info;
	bool               ret;

	if (out_frames)  *out_frames  = NULL;
	if (out_nframes) *out_nframes = 0;
	if (data == NULL || len == 0 || len > (size_t)INT64_MAX || out_frames == NULL || out_nframes == NULL)
		return false;
	if (!sndfile_ensure_loaded())
		return false;

	vio.get_filelen = sndfile_mem_len;
	vio.seek        = sndfile_mem_seek;
	vio.read        = sndfile_mem_read;
	vio.write       = sndfile_mem_write;
	vio.tell        = sndfile_mem_tell;
	mem.data = data;
	mem.len  = (sf_count_t)len;
	mem.pos  = 0;
	memset(&info, 0, sizeof(info));
	sf = sf_api.open_virtual_fn(&vio, SFM_READ, &info, &mem);
	if (sf == NULL)
		return false;
	ret = decode_sndfile(sf, &info, out_frames, out_nframes);
	sf_api.close_fn(sf);
	return ret;
}
