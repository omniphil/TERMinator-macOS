/*
 * apc_image.h -- PPM / PBM / JPEG XL decoding for SyncTERM's image APCs, ported from upstream SyncTERM's
 * src/syncterm/pixel_image.c. Pixels come back as CIOLIB_COLOR_RGB values. See apc_image.c.
 */
#ifndef APC_IMAGE_H
#define APC_IMAGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

struct ciolib_pixels;
struct ciolib_mask;

struct ciolib_pixels *apc_image_alloc_pixels(uint32_t width, uint32_t height);
struct ciolib_mask   *apc_image_alloc_mask(uint32_t width, uint32_t height);
void                  apc_image_free_pixels(struct ciolib_pixels *pixels);
void                  apc_image_free_mask(struct ciolib_mask *mask);

struct ciolib_pixels *apc_image_decode_ppm(const void *data, size_t length);
struct ciolib_mask   *apc_image_decode_pbm(const void *data, size_t length);

/* True once libjxl.dylib (Contents/Frameworks) and its dependencies load. */
bool                  apc_image_jxl_supported(void);
struct ciolib_pixels *apc_image_decode_jxl(const void *data, size_t length);

#endif /* APC_IMAGE_H */
