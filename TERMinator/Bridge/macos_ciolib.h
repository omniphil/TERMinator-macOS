/**
 * iOS-specific ciolib interface
 *
 * Provides the screen buffer and terminal I/O abstraction for iOS.
 * This replaces the Android-specific android_ciolib.h
 */

#ifndef IOS_CIOLIB_H
#define IOS_CIOLIB_H

#include <stdint.h>
#include <stdbool.h>

// Forward declaration from ciolib
struct vmem_cell;

// Initialization and cleanup
int  macos_ciolib_init(void);
void macos_ciolib_cleanup(void);

// Screen buffer access
void macos_ciolib_lock(void);
void macos_ciolib_unlock(void);
struct vmem_cell* macos_ciolib_get_screen_buffer(void);
uint32_t* macos_ciolib_get_palette(void);

// Screen dimensions
int macos_ciolib_get_screen_width(void);
int macos_ciolib_get_screen_height(void);
void macos_ciolib_resize(int width, int height);

// Cursor
int macos_ciolib_get_cursor_x(void);
int macos_ciolib_get_cursor_y(void);
bool macos_ciolib_is_cursor_visible(void);
bool macos_ciolib_cursor_type_changed(void);
int macos_ciolib_get_cursor_type(void);
int macos_ciolib_get_cursor_start(void);
int macos_ciolib_get_cursor_end(void);
int macos_ciolib_get_cursor_blinks(void);
uint32_t macos_ciolib_get_fg_color(void);
int macos_ciolib_get_char_pixel_height(void);
void macos_ciolib_set_custom_cursor(int s, int e, int r, int b, int v);

// Dirty tracking
bool macos_ciolib_is_dirty(void);
void macos_ciolib_clear_dirty(void);
bool macos_ciolib_get_dirty_region(int32_t *minX, int32_t *minY,
                                  int32_t *maxX, int32_t *maxY);

// Input
void macos_ciolib_push_input_buffer(const unsigned char *data, int len);

// Sixel pixel framebuffer
struct ciolib_pixels;
struct ciolib_mask;
int macos_ciolib_setpixels(uint32_t sx, uint32_t sy, uint32_t ex, uint32_t ey,
                          uint32_t x_off, uint32_t y_off, uint32_t mx_off, uint32_t my_off,
                          struct ciolib_pixels *pixels, struct ciolib_mask *mask);
void macos_ciolib_clear_pixels(void);
void macos_ciolib_blit_sixel(const uint32_t *src, int dst_x, int dst_y, int w, int h);
void macos_ciolib_set_char_pixel_height(int h);
// Re-derive the cursor scanlines (curs_start/curs_end) from the active mode's
// vparams entry. Must be called whenever the mode, the geometry or the font
// height changes — the scanlines are relative to the CELL, so a value carried
// over from a taller cell draws the cursor a row low.
void macos_ciolib_apply_mode_cursor(void);
int macos_ciolib_has_sixel_data(void);
int macos_ciolib_is_pixel_dirty(void);
void macos_ciolib_clear_pixel_dirty(void);
int macos_ciolib_copy_dirty_pixels(uint32_t *dest, int dest_w, int dest_h, int dest_stride, int full,
                                   int *x, int *y, int *w, int *h, int *bw, int *bh);
uint32_t* macos_ciolib_get_pixel_buffer(void);
int macos_ciolib_get_pixel_width(void);
int macos_ciolib_get_pixel_height(void);

/* --- macOS PETSCII 2026-09-04: Commodore video-mode support ---------------
 * set_video_mode installs an explicit ciolib mode (C64_40X25 / C128_40X25 /
 * C128_80X25) that overrides geometry inference, loads the mode's palette and
 * re-derives the cursor scanlines. mode_no_blink reports whether attribute
 * bit 7 means background-brightness rather than ANSI blink — the renderer MUST
 * gate its blink handling on it or every reverse-video PETSCII cell flickers.
 * ⚠️ mode_no_blink takes no lock: it is called from inside macos_ciolib_lock(). */
void macos_ciolib_apply_mode_palette(void);
void macos_ciolib_set_video_mode(int mode);
int  macos_ciolib_get_video_mode(void);
int  macos_ciolib_mode_no_blink(void);
int  macos_ciolib_get_mode_char_height(void);

/* Current ciolib video flags (CIOLIB_VIDEO_BGBRIGHT etc., as set by cterm). No lock, like
 * mode_no_blink: the screen packer calls it from inside macos_ciolib_lock(). */
int  macos_ciolib_get_video_flags(void);

#endif /* IOS_CIOLIB_H */
