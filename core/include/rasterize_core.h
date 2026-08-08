#ifndef RASTERIZE_CORE_H
#define RASTERIZE_CORE_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque image handle. Holds width, height, and a non-premultiplied RGBA8
 * pixel buffer (row-major, no row padding). Not thread-safe; callers must
 * serialize access to a given handle. */
typedef struct RzImage RzImage;

typedef enum {
  RZ_FORMAT_PNG = 0,
  RZ_FORMAT_JPEG = 1,
  RZ_FORMAT_TIFF = 2,
  RZ_FORMAT_BMP = 3,
  RZ_FORMAT_GIF = 4,
  RZ_FORMAT_WEBP = 5, /* lossless */
} RzFormat;

typedef enum {
  RZ_FILTER_NEAREST = 0,
  RZ_FILTER_BILINEAR = 1,
  RZ_FILTER_CATMULL_ROM = 2,
  RZ_FILTER_LANCZOS3 = 3,
} RzResizeFilter;

/* Open the image file at `path` (UTF-8). PNG/JPEG/TIFF/BMP/GIF/WebP are
 * detected by content sniffing; a file whose first four bytes are "8BPS" is
 * decoded as a Photoshop document and flattened to its composite image.
 * On success returns a new image (free with rz_image_free) and leaves
 * *err_out untouched. On failure returns NULL and, if err_out is non-NULL,
 * sets *err_out to a heap-allocated UTF-8 message the caller must release
 * with rz_string_free. */
RzImage *rz_image_open(const char *path, char **err_out);

/* Deep copy. Returns NULL only if img is NULL. */
RzImage *rz_image_clone(const RzImage *img);

/* Frees an image. NULL is a safe no-op. */
void rz_image_free(RzImage *img);

uint32_t rz_image_width(const RzImage *img);
uint32_t rz_image_height(const RzImage *img);

/* Borrowed pointer to width*height*4 bytes of non-premultiplied RGBA8.
 * Valid until the image is freed. Never NULL for a valid image. */
const uint8_t *rz_image_pixels_rgba(const RzImage *img);

/* All operations below are pure: they return a NEW image (caller frees) and
 * never mutate their input. They return NULL only for the invalid-argument
 * cases called out per function (or if img is NULL). Alpha is preserved
 * unchanged by color operations. */

RzImage *rz_image_rotate90(const RzImage *img);  /* 90 degrees clockwise */
RzImage *rz_image_rotate180(const RzImage *img);
RzImage *rz_image_rotate270(const RzImage *img); /* 90 degrees counter-clockwise */
RzImage *rz_image_flip_horizontal(const RzImage *img);
RzImage *rz_image_flip_vertical(const RzImage *img);

/* NULL if w == 0, h == 0, or the rect is not fully inside the image. */
RzImage *rz_image_crop(const RzImage *img, uint32_t x, uint32_t y,
                       uint32_t w, uint32_t h);

/* NULL if w == 0, h == 0, or w*h > 100000000 (guard against absurd sizes). */
RzImage *rz_image_resize(const RzImage *img, uint32_t w, uint32_t h,
                         RzResizeFilter filter);

/* brightness, contrast, saturation each in [-1.0, 1.0]; 0.0 is identity for
 * all three. Out-of-range values are clamped. Applied in the order
 * brightness, then contrast, then saturation, per pixel, alpha untouched. */
RzImage *rz_image_adjust(const RzImage *img, float brightness, float contrast,
                         float saturation);

RzImage *rz_image_grayscale(const RzImage *img);
RzImage *rz_image_invert(const RzImage *img);
RzImage *rz_image_sepia(const RzImage *img);

typedef enum {
  RZ_COMPOSITE_OVER = 0,  /* source-over painting (brush, text) */
  RZ_COMPOSITE_ERASE = 1, /* source alpha removes destination alpha */
} RzCompositeMode;

/* Composites a full-frame overlay onto the image, returning a NEW image.
 * `src` points to w*h*4 bytes of PREMULTIPLIED RGBA8 (the CoreGraphics
 * bitmap-context layout), row-major, top row first, no row padding; w and h
 * must equal the image's dimensions exactly. `alpha` is clamped to [0, 1] and
 * scales the overlay's alpha before compositing; the result remains
 * non-premultiplied. RZ_COMPOSITE_OVER paints the overlay over the image;
 * RZ_COMPOSITE_ERASE uses the overlay's alpha to erase destination alpha and
 * ignores the overlay's color. Where the overlay is fully transparent the
 * destination bytes pass through exactly. Returns NULL if img or src is
 * NULL, on dimension mismatch, on an unknown mode, or if alpha is NaN. */
RzImage *rz_image_composite(const RzImage *img, const uint8_t *src,
                            uint32_t w, uint32_t h, RzCompositeMode mode,
                            float alpha);

/* Gaussian blur. NULL if sigma <= 0 or not finite. */
RzImage *rz_image_blur(const RzImage *img, float sigma);

/* Unsharp-mask sharpen. amount clamped to (0, 5]; NULL if amount <= 0 or
 * not finite. */
RzImage *rz_image_sharpen(const RzImage *img, float amount);

/* Encode to `path` (UTF-8). jpeg_quality (1-100) applies to RZ_FORMAT_JPEG
 * only; for JPEG the image is composited over white to drop alpha. Returns
 * true on success; on failure returns false and, if err_out is non-NULL,
 * sets *err_out as in rz_image_open. */
bool rz_image_save(const RzImage *img, const char *path, RzFormat format,
                   uint8_t jpeg_quality, char **err_out);

/* Frees strings returned via err_out parameters. NULL is a safe no-op. */
void rz_string_free(char *s);

/* Static version string, e.g. "0.1.0". Do not free. */
const char *rz_core_version(void);

#ifdef __cplusplus
}
#endif

#endif /* RASTERIZE_CORE_H */
