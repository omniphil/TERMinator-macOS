/*
 * apc_image.c -- PPM / PBM / JPEG XL decoding for SyncTERM's image APCs, ported from upstream SyncTERM's
 * src/syncterm/pixel_image.c (PNM parsing with the BT.709 -> sRGB gamma table) and libjxl.c.
 *
 * macOS: ported 2026-09-16 from the Windows client (TERMinator-Windows/native/apc_image.c), which is the
 * master. libjxl and libjxl_threads are dlopen()ed from the app bundle's Contents/Frameworks (vendored and
 * signed by scripts/vendor-apc-libs.sh + the "Embed APC libraries" build phase, which also point their own
 * dependencies -- brotli, highway, lcms2 -- at @loader_path). If they don't load, JXL is simply unsupported
 * (Q;JXL goes unanswered).
 */

#include <dlfcn.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

#include <jxl/decode.h>
#include <jxl/resizable_parallel_runner.h>

#include "ciolib.h"

#include "apc_image.h"

/* ----- allocation ----- */

static bool
pixel_count(uint32_t width, uint32_t height, size_t *count)
{
	size_t result = (size_t)width * height;

	if (width != 0 && result / width != height)
		return false;
	*count = result;
	return true;
}

struct ciolib_pixels *
apc_image_alloc_pixels(uint32_t width, uint32_t height)
{
	struct ciolib_pixels *pixels;
	size_t                count;

	if (!pixel_count(width, height, &count) || count > SIZE_MAX / sizeof(*pixels->pixels))
		return NULL;
	pixels = calloc(1, sizeof(*pixels));
	if (pixels == NULL)
		return NULL;
	pixels->width  = width;
	pixels->height = height;
	if (count != 0) {
		pixels->pixels = malloc(count * sizeof(*pixels->pixels));
		if (pixels->pixels == NULL) {
			free(pixels);
			return NULL;
		}
	}
	return pixels;
}

struct ciolib_mask *
apc_image_alloc_mask(uint32_t width, uint32_t height)
{
	struct ciolib_mask *mask;
	size_t              count;
	size_t              bytes;

	if (!pixel_count(width, height, &count) || count > SIZE_MAX - 7)
		return NULL;
	bytes = (count + 7) / 8;
	mask  = calloc(1, sizeof(*mask));
	if (mask == NULL)
		return NULL;
	mask->width  = width;
	mask->height = height;
	if (bytes != 0) {
		mask->bits = calloc(bytes, 1);
		if (mask->bits == NULL) {
			free(mask);
			return NULL;
		}
	}
	return mask;
}

void
apc_image_free_pixels(struct ciolib_pixels *pixels)
{
	if (pixels == NULL)
		return;
	free(pixels->pixels);
	free(pixels->pixelsb);
	free(pixels);
}

void
apc_image_free_mask(struct ciolib_mask *mask)
{
	if (mask == NULL)
		return;
	free(mask->bits);
	free(mask);
}

/* ----- PNM ----- */

struct pnm_reader {
	const uint8_t *data;
	size_t         length;
	size_t         position;
};

static bool
pnm_whitespace(uint8_t ch)
{
	return ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n';
}

static bool
pnm_skip_space(struct pnm_reader *reader)
{
	bool skipped = false;

	while (reader->position < reader->length) {
		uint8_t ch = reader->data[reader->position];

		if (pnm_whitespace(ch)) {
			reader->position++;
			skipped = true;
			continue;
		}
		if (ch != '#')
			break;
		skipped = true;
		while (reader->position < reader->length) {
			ch = reader->data[reader->position++];
			if (ch == '\r' || ch == '\n')
				break;
		}
	}
	return skipped && reader->position < reader->length;
}

static bool
pnm_read_number(struct pnm_reader *reader, uintmax_t *value)
{
	uintmax_t result = 0;
	size_t    start;

	if (!pnm_skip_space(reader))
		return false;
	start = reader->position;
	while (reader->position < reader->length) {
		uint8_t ch = reader->data[reader->position];

		if (ch < '0' || ch > '9')
			break;
		if (result > (UINTMAX_MAX - (ch - '0')) / 10)
			return false;
		result = result * 10 + (ch - '0');
		reader->position++;
	}
	if (reader->position == start)
		return false;
	*value = result;
	return true;
}

static void
build_bt709_to_srgb_gamma(uint8_t maxval, uint8_t table[256])
{
	/* Adapted from pnmgamma.c by Bill Davidson and Jef Poskanzer.
	 * Copyright (C) 1991.  Permission is granted to use, copy, modify,
	 * and distribute this software and its documentation without fee. */
	const double  gamma_srgb             = 2.4;
	const double  one_over_gamma_709     = 0.45;
	const double  gamma_709              = 1.0 / one_over_gamma_709;
	const double  one_over_gamma_srgb    = 1.0 / gamma_srgb;
	const double  normalizer             = 1.0 / maxval;
	const uint8_t linear_cutoff_709      = (uint8_t)(maxval * 0.018 + 0.5);
	const double  linear_compression_709 = 0.018 / (1.099 * pow(0.018, one_over_gamma_709) - 0.099);
	const double  linear_cutoff_srgb     = 0.0031308;
	const double  linear_expansion_srgb  = (1.055 * pow(0.0031308, one_over_gamma_srgb) - 0.055) / 0.0031308;

	for (unsigned i = 0; i <= maxval; i++) {
		double normalized = i * normalizer;
		double radiance;
		double srgb;

		if (i < linear_cutoff_709 / linear_compression_709)
			radiance = normalized * linear_compression_709;
		else
			radiance = pow((normalized + 0.099) / 1.099, gamma_709);
		if (radiance > 1.0)
			radiance = 1.0;
		if (radiance < linear_cutoff_srgb * normalizer)
			srgb = radiance * linear_expansion_srgb;
		else
			srgb = 1.055 * pow(normalized, one_over_gamma_srgb) - 0.055;
		if (srgb > 1.0)
			srgb = 1.0;
		table[i] = (uint8_t)(srgb * 255 + 0.5);
	}
}

static bool
pnm_read_text_mask(struct pnm_reader *reader, struct ciolib_mask *mask, size_t count)
{
	for (size_t i = 0; i < count; i++) {
		uintmax_t value;

		if (!pnm_read_number(reader, &value) || value > 1)
			return false;
		if (value != 0)
			mask->bits[i / 8] |= 0x80 >> (i % 8);
	}
	return true;
}

static bool
pnm_read_raw_mask(struct pnm_reader *reader, struct ciolib_mask *mask)
{
	size_t row_bytes = ((size_t)mask->width + 7) / 8;

	if (row_bytes != 0 && mask->height > (reader->length - reader->position) / row_bytes)
		return false;
	for (uint32_t y = 0; y < mask->height; y++) {
		for (size_t byte = 0; byte < row_bytes; byte++) {
			uint8_t value = reader->data[reader->position++];

			for (unsigned bit = 0; bit < 8; bit++) {
				uint32_t x = (uint32_t)(byte * 8 + bit);
				size_t   destination;

				if (x >= mask->width)
					break;
				if ((value & (0x80 >> bit)) == 0)
					continue;
				destination = (size_t)y * mask->width + x;
				mask->bits[destination / 8] |= 0x80 >> (destination % 8);
			}
		}
	}
	return true;
}

static bool
pnm_read_pixels(struct pnm_reader *reader, struct ciolib_pixels *pixels, size_t count, uint8_t maxval,
                bool raw)
{
	uint8_t gamma[256] = {0};

	build_bt709_to_srgb_gamma(maxval, gamma);
	for (size_t i = 0; i < count; i++) {
		uint32_t colour = CIOLIB_COLOR_RGB;

		for (unsigned component = 0; component < 3; component++) {
			uintmax_t value;

			if (raw) {
				if (reader->position >= reader->length)
					return false;
				value = reader->data[reader->position++];
			}
			else if (!pnm_read_number(reader, &value))
				return false;
			if (value > maxval)
				return false;
			colour |= (uint32_t)gamma[value] << (16 - component * 8);
		}
		pixels->pixels[i] = colour;
	}
	return true;
}

static void *
decode_pnm(const void *data, size_t length, bool bitmap)
{
	struct pnm_reader     reader = {data, length, 0};
	struct ciolib_pixels *pixels = NULL;
	struct ciolib_mask   *mask   = NULL;
	uintmax_t             width;
	uintmax_t             height;
	uintmax_t             maxval = 0;
	size_t                count;
	uint8_t               kind;
	bool                  raw;

	if (data == NULL || length < 2 || reader.data[0] != 'P')
		return NULL;
	kind = reader.data[1];
	reader.position = 2;
	if (bitmap) {
		if (kind != '1' && kind != '4')
			return NULL;
	}
	else if (kind != '3' && kind != '6')
		return NULL;
	if (!pnm_read_number(&reader, &width) || width == 0 || width > UINT32_MAX
	    || !pnm_read_number(&reader, &height) || height == 0 || height > UINT32_MAX
	    || !pixel_count((uint32_t)width, (uint32_t)height, &count))
		return NULL;
	if (!bitmap && (!pnm_read_number(&reader, &maxval) || maxval == 0 || maxval > 255))
		return NULL;
	raw = kind == '4' || kind == '6';
	if (raw) {
		if (reader.position >= reader.length || !pnm_whitespace(reader.data[reader.position]))
			return NULL;
		reader.position++;
	}
	if (bitmap) {
		mask = apc_image_alloc_mask((uint32_t)width, (uint32_t)height);
		if (mask == NULL)
			return NULL;
		if ((raw && !pnm_read_raw_mask(&reader, mask)) || (!raw && !pnm_read_text_mask(&reader, mask, count))) {
			apc_image_free_mask(mask);
			return NULL;
		}
		return mask;
	}
	pixels = apc_image_alloc_pixels((uint32_t)width, (uint32_t)height);
	if (pixels == NULL)
		return NULL;
	if (!pnm_read_pixels(&reader, pixels, count, (uint8_t)maxval, raw)) {
		apc_image_free_pixels(pixels);
		return NULL;
	}
	return pixels;
}

struct ciolib_pixels *
apc_image_decode_ppm(const void *data, size_t length)
{
	return decode_pnm(data, length, false);
}

struct ciolib_mask *
apc_image_decode_pbm(const void *data, size_t length)
{
	return decode_pnm(data, length, true);
}

/* ----- libjxl (runtime-loaded) ----- */

static struct {
	void               (*DecoderCloseInput)(JxlDecoder *);
	JxlDecoder        *(*DecoderCreate)(const JxlMemoryManager *);
	void               (*DecoderDestroy)(JxlDecoder *);
	JxlDecoderStatus   (*DecoderGetBasicInfo)(const JxlDecoder *, JxlBasicInfo *);
	JxlDecoderStatus   (*DecoderImageOutBufferSize)(const JxlDecoder *, const JxlPixelFormat *, size_t *);
	JxlDecoderStatus   (*DecoderProcessInput)(JxlDecoder *);
	size_t             (*DecoderReleaseInput)(JxlDecoder *);
	JxlDecoderStatus   (*DecoderSetImageOutBuffer)(JxlDecoder *, const JxlPixelFormat *, void *, size_t);
	JxlDecoderStatus   (*DecoderSetInput)(JxlDecoder *, const uint8_t *, size_t);
	JxlDecoderStatus   (*DecoderSubscribeEvents)(JxlDecoder *, int);
	JxlDecoderStatus   (*DecoderSetParallelRunner)(JxlDecoder *, JxlParallelRunner, void *);
	JxlParallelRetCode (*ResizableParallelRunner)(void *, void *, JxlParallelRunInit, JxlParallelRunFunction,
	                                              uint32_t, uint32_t);
	void              *(*ResizableParallelRunnerCreate)(const JxlMemoryManager *);
	void               (*ResizableParallelRunnerDestroy)(void *);
	void               (*ResizableParallelRunnerSetThreads)(void *, size_t);
	uint32_t           (*ResizableParallelRunnerSuggestThreads)(uint64_t, uint64_t);
} Jxl;

static pthread_once_t jxl_once = PTHREAD_ONCE_INIT;
static bool           jxl_ok;
static bool           jxl_threads_ok;

/* The bundle's copy first, then the normal dyld search. The fallback rarely helps: library validation refuses a
 * dylib signed by another team (Homebrew's), so in practice the vendored copy is the one that loads. */
static void *
jxl_dlopen(const char *leaf)
{
	char  path[256];
	void *dll;

	snprintf(path, sizeof(path), "@executable_path/../Frameworks/%s", leaf);
	dll = dlopen(path, RTLD_NOW | RTLD_LOCAL);
	if (dll == NULL)
		dll = dlopen(leaf, RTLD_NOW | RTLD_LOCAL);
	return dll;
}

#define JXL_SYM(dll, field, name) ((Jxl.field = dlsym(dll, name)) != NULL)

static void
jxl_load(void)
{
	void *dll;
	void *tdll;

	dll = jxl_dlopen("libjxl.dylib");
	if (dll == NULL)
		return;
	if (!(JXL_SYM(dll, DecoderCloseInput, "JxlDecoderCloseInput")
	      && JXL_SYM(dll, DecoderCreate, "JxlDecoderCreate")
	      && JXL_SYM(dll, DecoderDestroy, "JxlDecoderDestroy")
	      && JXL_SYM(dll, DecoderGetBasicInfo, "JxlDecoderGetBasicInfo")
	      && JXL_SYM(dll, DecoderImageOutBufferSize, "JxlDecoderImageOutBufferSize")
	      && JXL_SYM(dll, DecoderProcessInput, "JxlDecoderProcessInput")
	      && JXL_SYM(dll, DecoderReleaseInput, "JxlDecoderReleaseInput")
	      && JXL_SYM(dll, DecoderSetImageOutBuffer, "JxlDecoderSetImageOutBuffer")
	      && JXL_SYM(dll, DecoderSetInput, "JxlDecoderSetInput")
	      && JXL_SYM(dll, DecoderSubscribeEvents, "JxlDecoderSubscribeEvents"))) {
		dlclose(dll);
		return;
	}
	jxl_ok = true;

	/* Multithreaded decode is optional */
	if (!JXL_SYM(dll, DecoderSetParallelRunner, "JxlDecoderSetParallelRunner"))
		return;
	tdll = jxl_dlopen("libjxl_threads.dylib");
	if (tdll == NULL)
		return;
	if (JXL_SYM(tdll, ResizableParallelRunner, "JxlResizableParallelRunner")
	    && JXL_SYM(tdll, ResizableParallelRunnerCreate, "JxlResizableParallelRunnerCreate")
	    && JXL_SYM(tdll, ResizableParallelRunnerDestroy, "JxlResizableParallelRunnerDestroy")
	    && JXL_SYM(tdll, ResizableParallelRunnerSetThreads, "JxlResizableParallelRunnerSetThreads")
	    && JXL_SYM(tdll, ResizableParallelRunnerSuggestThreads, "JxlResizableParallelRunnerSuggestThreads"))
		jxl_threads_ok = true;
}

bool
apc_image_jxl_supported(void)
{
	pthread_once(&jxl_once, jxl_load);
	return jxl_ok;
}

struct ciolib_pixels *
apc_image_decode_jxl(const void *data, size_t length)
{
	struct ciolib_pixels *pixels = NULL;
	uint8_t              *buffer = NULL;
	uintmax_t             width  = 0;
	uintmax_t             height = 0;
	JxlDecoderStatus      status = JXL_DEC_ERROR;
	JxlBasicInfo          info;
	size_t                size = 0;
	JxlPixelFormat        format;
	JxlDecoder           *decoder;
	void                 *runner = NULL;

	if (data == NULL || !apc_image_jxl_supported())
		return NULL;
	format.num_channels = 3;
	format.data_type    = JXL_TYPE_UINT8;
	format.endianness   = JXL_NATIVE_ENDIAN;
	format.align        = 1;

	decoder = Jxl.DecoderCreate(NULL);
	if (decoder == NULL)
		return NULL;
	if (jxl_threads_ok) {
		runner = Jxl.ResizableParallelRunnerCreate(NULL);
		if (runner != NULL
		    && Jxl.DecoderSetParallelRunner(decoder, Jxl.ResizableParallelRunner, runner) != JXL_DEC_SUCCESS) {
			Jxl.ResizableParallelRunnerDestroy(runner);
			runner = NULL;
		}
	}
	if (Jxl.DecoderSetInput(decoder, data, length) != JXL_DEC_SUCCESS)
		goto done;
	Jxl.DecoderCloseInput(decoder);
	if (Jxl.DecoderSubscribeEvents(decoder, JXL_DEC_BASIC_INFO | JXL_DEC_FULL_IMAGE) != JXL_DEC_SUCCESS)
		goto done;
	for (;;) {
		status = Jxl.DecoderProcessInput(decoder);
		if (status == JXL_DEC_BASIC_INFO) {
			if (Jxl.DecoderGetBasicInfo(decoder, &info) != JXL_DEC_SUCCESS)
				break;
			width  = info.xsize;
			height = info.ysize;
			if (runner != NULL)
				Jxl.ResizableParallelRunnerSetThreads(runner,
				    Jxl.ResizableParallelRunnerSuggestThreads(info.xsize, info.ysize));
			continue;
		}
		if (status == JXL_DEC_NEED_IMAGE_OUT_BUFFER) {
			size_t count;

			if (width == 0 || height == 0 || width > UINT32_MAX || height > UINT32_MAX
			    || !pixel_count((uint32_t)width, (uint32_t)height, &count) || count > SIZE_MAX / 3
			    || Jxl.DecoderImageOutBufferSize(decoder, &format, &size) != JXL_DEC_SUCCESS
			    || size != count * 3)
				break;
			free(buffer);
			buffer = malloc(size);
			apc_image_free_pixels(pixels);
			pixels = apc_image_alloc_pixels((uint32_t)width, (uint32_t)height);
			if (buffer == NULL || pixels == NULL
			    || Jxl.DecoderSetImageOutBuffer(decoder, &format, buffer, size) != JXL_DEC_SUCCESS)
				break;
			continue;
		}
		if (status == JXL_DEC_FULL_IMAGE)
			continue;
		break;
	}
	if (status != JXL_DEC_SUCCESS || pixels == NULL || buffer == NULL) {
		apc_image_free_pixels(pixels);
		pixels = NULL;
	}
	else {
		for (size_t i = 0, pixel = 0; i < size; i += 3, pixel++)
			pixels->pixels[pixel] = CIOLIB_COLOR_RGB | ((uint32_t)buffer[i] << 16)
			                        | ((uint32_t)buffer[i + 1] << 8) | buffer[i + 2];
	}

done:
	free(buffer);
	if (runner != NULL)
		Jxl.ResizableParallelRunnerDestroy(runner);
	Jxl.DecoderReleaseInput(decoder);
	Jxl.DecoderDestroy(decoder);
	return pixels;
}
