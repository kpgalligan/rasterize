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

/* Build an image from `src`: w*h*4 bytes of STRAIGHT (non-premultiplied)
 * RGBA8, row-major, top row first, no row padding — the in-memory twin of
 * rz_image_open, for pixels this library cannot decode itself (a HEIC still
 * decoded by the host, a Live Photo video frame). The buffer is copied and
 * stays the caller's. Returns NULL if src is NULL, if w or h is 0, or if
 * w*h > 100000000. */
RzImage *rz_image_from_rgba(const uint8_t *src, uint32_t w, uint32_t h);

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

/* Multiplies each pixel's alpha by a full-frame u8 coverage mask, returning
 * a NEW image. `mask` points to w*h bytes, row-major, top row first, one
 * byte per pixel — the selection convention: 0 hides, 255 keeps,
 * intermediate values scale alpha proportionally; w and h must equal the
 * image's dimensions exactly. Color bytes pass through, except where the
 * scaled alpha lands on 0, which clears the pixel to transparent black;
 * full-coverage (255) pixels pass through byte-for-byte, an already
 * transparent pixel's latent color included. Returns NULL if img or mask is
 * NULL or on dimension mismatch. */
RzImage *rz_image_apply_mask(const RzImage *img, const uint8_t *mask,
                             uint32_t w, uint32_t h);

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

/* ------------------------------------------------------------------------ */
/* Layered documents                                                         */
/* ------------------------------------------------------------------------ */

/* Opaque layered document: a canvas size plus an ordered stack of layers
 * (index 0 = BOTTOM). Every layer has straight-alpha RGBA8 pixels of its own
 * size, an integer canvas offset, a name, opacity, a blend mode, a
 * visibility flag, an optional layer mask (see "Layer masks" below) and an
 * optional layer style (see "Layer styles" below); the document carries a
 * global light (angle, altitude) the styles share.
 * Layer pixel buffers are immutable and shared between
 * document handles (copy-on-write), so rz_doc_clone and the pure "with_"/
 * stack operations are cheap: they copy only what they change. Documents
 * always contain at least one layer. Like RzImage, a given handle is not
 * thread-safe; callers must serialize access to it. */
typedef struct RzDocument RzDocument;

/* The Photoshop blend-mode set, sRGB-encoded f32 math. Modes 0-13 and 15-22
 * are separable (per-channel, W3C compositing formulas); 23-26 are the W3C
 * non-separable modes operating on the RGB triple via the spec's
 * SetLum/SetSat helpers (Lum = 0.3R + 0.59G + 0.11B); DISSOLVE replaces
 * alpha compositing with a deterministic per-canvas-position dither: each
 * pixel shows the source fully opaque with probability equal to its
 * effective alpha, otherwise the backdrop. Values are stable across
 * releases; RZDC files store them as u32, and readers map unknown values to
 * RZ_BLEND_NORMAL. */
typedef enum {
  RZ_BLEND_NORMAL = 0,
  RZ_BLEND_MULTIPLY = 1,
  RZ_BLEND_SCREEN = 2,
  RZ_BLEND_OVERLAY = 3,
  RZ_BLEND_SOFT_LIGHT = 4,
  RZ_BLEND_HARD_LIGHT = 5,
  RZ_BLEND_DARKEN = 6,
  RZ_BLEND_LIGHTEN = 7,
  RZ_BLEND_DIFFERENCE = 8,
  RZ_BLEND_EXCLUSION = 9,
  RZ_BLEND_COLOR_DODGE = 10,
  RZ_BLEND_COLOR_BURN = 11,
  RZ_BLEND_ADDITION = 12, /* a.k.a. Linear Dodge */
  RZ_BLEND_SUBTRACT = 13,
  RZ_BLEND_DISSOLVE = 14,
  RZ_BLEND_LINEAR_BURN = 15,
  RZ_BLEND_DARKER_COLOR = 16,  /* whole-pixel: keeps the lower-luma color */
  RZ_BLEND_LIGHTER_COLOR = 17, /* whole-pixel: keeps the higher-luma color */
  RZ_BLEND_VIVID_LIGHT = 18,
  RZ_BLEND_LINEAR_LIGHT = 19,
  RZ_BLEND_PIN_LIGHT = 20,
  RZ_BLEND_HARD_MIX = 21,
  RZ_BLEND_DIVIDE = 22,
  RZ_BLEND_HUE = 23,
  RZ_BLEND_SATURATION = 24,
  RZ_BLEND_COLOR = 25,
  RZ_BLEND_LUMINOSITY = 26,
} RzBlendMode;

/* Opens a document. Sniffing order: files starting "RZDC" are native
 * Rasterize documents (layers preserved); "8BPS" are Photoshop documents,
 * imported as one layer per PSD raster layer (name, visibility, opacity,
 * best-effort blend-mode mapping; on any per-layer failure falls back to a
 * single flattened layer); anything else decodes via rz_image_open rules to
 * a single "Background" layer. Errors as in rz_image_open. */
RzDocument *rz_doc_open(const char *path, char **err_out);

/* Wraps an image as a single-"Background"-layer document. NULL if img NULL. */
RzDocument *rz_doc_from_image(const RzImage *img);

/* Cheap copy (shares layer pixels). NULL only if doc is NULL. */
RzDocument *rz_doc_clone(const RzDocument *doc);
void rz_doc_free(RzDocument *doc);

/* Writes the native RZDC format (all layers preserved). Atomic like
 * rz_image_save. The writer enforces the reader's limits so every file it
 * produces can be read back: more than 1024 layers, more than 256 channels,
 * more than 900000000 channel pixels in total (the budget the "Channels"
 * section below states, and the one rz_max_channels_at answers), or a layer
 * or channel PNG over 512 MiB is an error; layer and channel names longer
 * than 64 KiB are truncated on a UTF-8 character boundary. Layout
 * (little-endian): "RZDC", u32 version=5,
 * u32 canvas width, u32 canvas height, u32 layer count, then (version 4)
 * f32 global-light angle and f32 altitude in degrees; then per layer
 * bottom-to-top: u32 name byte length + UTF-8 name, i32 offset x, i32
 * offset y, f32 opacity, u32 blend mode, u8 visible, u32 PNG byte length +
 * PNG-encoded RGBA8 layer pixels; then the version-2 fields, which a
 * version-1 record simply lacks: u8 mask present, u8 mask enabled, u32 mask
 * byte length + that many RAW coverage bytes when present (a mask is always
 * the layer's pixel count, so its dimensions are not stored twice), then u8
 * layer-metadata present and, when present, u32 byte length + UTF-8 bytes (see
 * "Layer metadata" below); then the version-3 field, appended after all the
 * version-2 fields (each older record is a strict prefix of the next): u8
 * clipped (see "Clipping masks" below); then the version-4 field: u8
 * layer-style present and, when present, u32 byte length + UTF-8 canonical
 * style JSON (see "Layer styles" below). After the LAST layer record comes
 * the version-5 block, the alpha channel list (see "Channels" below): u32
 * channel count, then per channel u32 name byte length + UTF-8 name, u8
 * overlay red, u8 green, u8 blue, f32 overlay opacity, u8 color-indicates-
 * selected, and u32 PNG byte length + a PNG-encoded 8-bit GRAYSCALE (L8)
 * plane of exactly the canvas size (a channel is always canvas-sized, so its
 * dimensions are not stored twice). Version-1, -2, -3 and -4 files still
 * load, missing fields taking their defaults: no mask and no metadata on any
 * layer (v1), clipped false (v1 and v2), no style on any layer and a
 * (120°, 30°) global light (v1–v3), and no channels (v1–v4). A style is read
 * leniently: a style from a newer build keeps the effects this build
 * knows. */
bool rz_doc_save_native(const RzDocument *doc, const char *path,
                        char **err_out);

uint32_t rz_doc_width(const RzDocument *doc);
uint32_t rz_doc_height(const RzDocument *doc);
size_t rz_doc_layer_count(const RzDocument *doc);

/* Layer getters. Out-of-range idx: NULL / 0 / RZ_BLEND_NORMAL / false.
 * rz_doc_layer_name returns a heap string freed with rz_string_free. */
char *rz_doc_layer_name(const RzDocument *doc, size_t idx);
float rz_doc_layer_opacity(const RzDocument *doc, size_t idx);
RzBlendMode rz_doc_layer_blend_mode(const RzDocument *doc, size_t idx);
bool rz_doc_layer_visible(const RzDocument *doc, size_t idx);
int32_t rz_doc_layer_offset_x(const RzDocument *doc, size_t idx);
int32_t rz_doc_layer_offset_y(const RzDocument *doc, size_t idx);
uint32_t rz_doc_layer_width(const RzDocument *doc, size_t idx);
uint32_t rz_doc_layer_height(const RzDocument *doc, size_t idx);

/* Copy of a layer's pixels at the layer's own size. */
RzImage *rz_doc_layer_image(const RzDocument *doc, size_t idx);

/* A layer's own pixels on a transparent CANVAS-sized image, placed at its
 * offset — the single-layer counterpart of rz_doc_flattened. Opacity, blend
 * mode, visibility and the layer mask are ignored: they say how the layer
 * composites, not what its pixels are. */
RzImage *rz_doc_layer_canvas_image(const RzDocument *doc, size_t idx);

/* Aspect-fit thumbnail of a layer, longest side == max_side (min 1). */
RzImage *rz_doc_layer_thumbnail(const RzDocument *doc, size_t idx,
                                uint32_t max_side);

/* Canvas-sized projection: visible layers composited bottom-to-top in f32,
 * straight-alpha result. Compositing follows the W3C model: with backdrop
 * (Cb, ab), source layer (Cs, as' = as * opacity) and blend function B:
 *   ao = as' + ab*(1-as')
 *   Co = ( as'*(1-ab)*Cs + as'*ab*B(Cb,Cs) + (1-as')*ab*Cb ) / ao   (ao > 0)
 * Invisible layers are skipped; areas a layer does not cover use Cb. Layers
 * flagged clipped composite in groups with the unclipped layer beneath them
 * (see "Clipping masks" below). Layers carrying a style composite with their
 * effects (see "Layer styles" below). */
RzImage *rz_doc_flattened(const RzDocument *doc);

/* Pure per-layer setters: return a NEW document (input untouched), NULL on
 * out-of-range idx or NULL args. Opacity is clamped to [0,1]. */
RzDocument *rz_doc_with_layer_name(const RzDocument *doc, size_t idx,
                                   const char *name);
RzDocument *rz_doc_with_layer_opacity(const RzDocument *doc, size_t idx,
                                      float opacity);
RzDocument *rz_doc_with_layer_blend_mode(const RzDocument *doc, size_t idx,
                                         RzBlendMode mode);
RzDocument *rz_doc_with_layer_visible(const RzDocument *doc, size_t idx,
                                      bool visible);
RzDocument *rz_doc_with_layer_offset(const RzDocument *doc, size_t idx,
                                     int32_t x, int32_t y);

/* Replaces a layer's pixels (any size; offset and properties kept). See
 * rz_doc_with_layer_pixels_rgba under "Layer metadata" for the variant that
 * takes a rendered buffer instead of an image handle. */
RzDocument *rz_doc_with_layer_pixels(const RzDocument *doc, size_t idx,
                                     const RzImage *img);

/* Stack operations (all pure). Insertion index semantics: the new layer is
 * inserted ABOVE idx (i.e. at position idx+1); idx must be in range. */
RzDocument *rz_doc_adding_layer(const RzDocument *doc, size_t idx,
                                const char *name); /* transparent, canvas-sized, offset 0 */
RzDocument *rz_doc_adding_image_layer(const RzDocument *doc, size_t idx,
                                      const RzImage *img, const char *name);
RzDocument *rz_doc_duplicating_layer(const RzDocument *doc, size_t idx);
RzDocument *rz_doc_removing_layer(const RzDocument *doc, size_t idx); /* NULL if last layer */
RzDocument *rz_doc_moving_layer(const RzDocument *doc, size_t from, size_t to);

/* Merges layer idx (idx >= 1) into the layer below it. BOTH layers' blend
 * modes and opacities are baked into the merged pixels (same math as the
 * projection, the lower compositing onto a transparent backdrop), so the
 * merged layer is RZ_BLEND_NORMAL at opacity 1.0; it keeps only the LOWER
 * layer's name, visibility and clipped flag and covers the union of both
 * layers' extents. A CLIPPED upper layer is baked through its clipping: its
 * contribution is alpha-limited to the lower layer's footprint (the same
 * group kernel as the projection — see "Clipping masks" below). An invisible
 * upper layer is simply removed. NULL if idx == 0 / out of range, or if the
 * LOWER layer is hidden (the merge would discard the upper layer's
 * content). */
RzDocument *rz_doc_merging_down(const RzDocument *doc, size_t idx);

/* Single-layer document containing the projection, named "Background". */
RzDocument *rz_doc_flattening(const RzDocument *doc);

/* Paints a CANVAS-frame premultiplied overlay (as in rz_image_composite;
 * w/h must equal the canvas size) onto layer idx, mapped through the
 * layer's offset. Overlay areas outside the layer's extent are ignored
 * (the layer does NOT grow). Modes/alpha as rz_image_composite. NULL when
 * the layer's extent does not intersect the canvas at all (no pixel could
 * change, so there is nothing to paint). */
RzDocument *rz_doc_painting_layer(const RzDocument *doc, size_t idx,
                                  const uint8_t *src, uint32_t w, uint32_t h,
                                  RzCompositeMode mode, float alpha);

/* Paints the same canvas-frame premultiplied overlay onto layer idx
 * through a layer blend mode (the paint tools' Blend option): each covered
 * pixel runs the W3C compositing formula the layer projection uses, so the
 * stroke lands exactly what a `mode` layer holding it would flatten to
 * against the layer's current pixels. RZ_BLEND_NORMAL delegates to
 * rz_doc_painting_layer with RZ_COMPOSITE_OVER (byte-identical, refusal
 * rules included). alpha clamps to [0, 1]. NULL on NULL args, dimension
 * mismatch, unknown mode, NaN alpha, bad idx, a layer extent that misses
 * the canvas, or — non-Normal modes only — when no pixel would change. */
RzDocument *rz_doc_painting_layer_blend(const RzDocument *doc, size_t idx,
                                        const uint8_t *src, uint32_t w,
                                        uint32_t h, RzBlendMode mode,
                                        float alpha);

/* Dodges (brightens, burn false) or burns (darkens, burn true) layer idx
 * where a stroke overlay covers it. src is the SAME canvas-frame
 * premultiplied overlay rz_doc_painting_layer takes (w/h must equal the
 * canvas size); ONLY its alpha channel is read, as per-pixel stroke
 * coverage. Each color channel moves toward white (dodge) or black (burn),
 * banded by its own value — range 0 shadows, 1 midtones, 2 highlights —
 * and scaled by exposure (clamped to [0, 1]). Layer alpha is never
 * touched; overlay outside the layer's extent is ignored (the layer does
 * NOT grow). NULL on dimension mismatch, non-finite exposure, range > 2,
 * out-of-range idx, a layer extent that misses the canvas, or when no
 * pixel would change. */
RzDocument *rz_doc_dodge_burn_layer(const RzDocument *doc, size_t idx,
                                    const uint8_t *src, uint32_t w, uint32_t h,
                                    float exposure, uint8_t range, bool burn);

/* Whole-document geometry: every layer's pixels and offset transform
 * together with the canvas. */
RzDocument *rz_doc_rotate90(const RzDocument *doc);
RzDocument *rz_doc_rotate180(const RzDocument *doc);
RzDocument *rz_doc_rotate270(const RzDocument *doc);
RzDocument *rz_doc_flip_horizontal(const RzDocument *doc);
RzDocument *rz_doc_flip_vertical(const RzDocument *doc);

/* Crop moves the canvas window: canvas becomes w*h, layer offsets shift by
 * (-x, -y), layer pixels are untouched (content outside the canvas is
 * retained and can be revealed by moving layers). Bounds-checked like
 * rz_image_crop against the CANVAS rect. */
RzDocument *rz_doc_crop(const RzDocument *doc, uint32_t x, uint32_t y,
                        uint32_t w, uint32_t h);

/* Scales the canvas and every layer (sizes and offsets) proportionally.
 * Limits as rz_image_resize. Layer styles scale with their layers ("Scale
 * Effects", by the mean factor sqrt(fx * fy); see "Layer styles" below).
 * Alpha channels resample to the new canvas with it, so this is also NULL
 * when the enlarged channel list would break the .rz total-channel-pixel
 * budget (see "Channels") — the refusal lands here, where the user can
 * delete channels, rather than at save time. */
RzDocument *rz_doc_resize(const RzDocument *doc, uint32_t w, uint32_t h,
                          RzResizeFilter filter);

/* Changes the canvas size WITHOUT scaling anything: the canvas becomes w*h
 * and every layer's offset shifts by (origin_x, origin_y) — where the old
 * canvas's top-left corner lands in the new canvas. Layer pixels are
 * untouched; content outside the new canvas is retained (as with
 * rz_doc_crop) and can be revealed later. Alpha channels are canvas-sized,
 * so they are padded with 0 to the new canvas; growing past the .rz
 * total-channel-pixel budget is refused here for the same reason
 * rz_doc_resize refuses it. NULL if w == 0, h == 0, w*h > 100000000, or that
 * budget would break. */
RzDocument *rz_doc_canvas_resize(const RzDocument *doc, uint32_t w,
                                 uint32_t h, int32_t origin_x,
                                 int32_t origin_y);

/* Free transform of ONE layer by an arbitrary affine matrix.
 *
 * `affine` points to exactly six doubles in CGAffineTransform element order,
 * [a, b, c, d, tx, ty], mapping
 *     (x, y) -> (a*x + c*y + tx, b*x + d*y + ty)
 * so a CGAffineTransform's fields can be handed over unchanged.
 *
 * The matrix works in CANVAS coordinates: the layer occupies the canvas rect
 * (offset_x, offset_y, layer_width, layer_height), the matrix says where that
 * rect lands, and the layer's NEW offset and size are the axis-aligned
 * bounding box of the four transformed corners, rounded OUTWARD (floor of the
 * minima, ceil of the maxima) so nothing is clipped — after each corner within
 * 1e-9 of an integer is snapped onto it, so the floating-point residue of a
 * composed matrix (cos(PI/2) is 6e-17, not 0) cannot add a phantom transparent
 * row or column. Corners that are fractional by any user-meaningful amount are
 * untouched and still round outward. The canvas itself is not touched, and
 * neither is any other layer; a transformed layer may extend past the canvas,
 * exactly like any other offset layer.
 *
 * Pixels are inverse-mapped: every DESTINATION pixel centre is mapped back
 * through the inverse matrix and sampled in the source with `sampler` (the
 * shared RzResizeFilter values: NEAREST point-samples, BILINEAR is a 2x2
 * triangle filter, CATMULL_ROM a 4x4 bicubic, LANCZOS3 a 6x6 windowed sinc).
 * Samples landing outside the source pixels are fully transparent, so edges
 * fade out rather than smear the border. Interpolation runs in PREMULTIPLIED
 * f32 and is unpremultiplied on the way out, so anti-aliased edges keep their
 * color instead of fringing toward the (meaningless) color of transparent
 * neighbours.
 *
 * A layer MASK is carried through identically: it is resampled with the same
 * matrix, the same destination extent and the same sampler, so it lands
 * pixel-for-pixel on the transformed pixels and stays exactly the layer's
 * size. Layer `meta` is PRESERVED — the core never interprets it, so deciding
 * whether a transform invalidates a text description is the host's policy.
 * Name, opacity, blend mode, visibility and the mask-enabled flag survive too.
 *
 * Exact matrices (an integer translation, optionally composed with an
 * axis-aligned flip or a 90-degree multiple) skip resampling and copy pixels
 * losslessly, matching rz_doc_rotate90 / rz_doc_flip_* byte for byte. Exact
 * means "within 1e-9": a caller that composes its quarter turn from an angle
 * (rotated(by: M_PI_2), whose cosine is 6e-17 rather than 0) gets the same
 * lossless copy and the same extent as one passing an integer matrix. A
 * transform that misses by more than that — 89.999 degrees is 1.7e-5 off —
 * resamples normally. The dedicated whole-document ops above remain the right
 * call for menu items.
 *
 * A layer style is scaled with the layer ("Scale Effects": its pixel-valued
 * fields — distance, size, soften — follow the mean scale sqrt(|a*d - b*c|);
 * see "Layer styles" below).
 *
 * NULL if doc or affine is NULL, idx is out of range, any matrix element is
 * not finite, the matrix is singular (|a*d - b*c| < 1e-9), the sampler value
 * is unknown, or the destination extent is empty, falls outside the int32
 * offset range, or exceeds 100000000 pixels. */
RzDocument *rz_doc_transform_layer(const RzDocument *doc, size_t idx,
                                   const double *affine,
                                   RzResizeFilter sampler);

/* Perspective (projective) transform of one layer: maps the layer's rect
 * corner-for-corner onto a destination QUAD. `quad` points to eight doubles
 * — the canvas coordinates the source rect's corners land on, in the
 * source rect's own corner order top-left, top-right, bottom-right,
 * bottom-left (x then y for each, clockwise on the y-down canvas). The
 * homography realizing the mapping is solved inside the core, so no 3x3
 * element-order convention crosses this boundary.
 *
 * Everything rz_doc_transform_layer documents carries over: the new
 * offset/size are the quad corners' outward-rounded bounding box (with the
 * same 1e-9 integer snapping), pixels are inverse-mapped and interpolated in
 * premultiplied f32 with the same samplers, samples outside the source are
 * transparent, a layer mask rides along with the same map/extent/kernel, and
 * meta plus every other layer property survive. Extent pixels outside the
 * quad itself come out fully transparent. Perspective compresses sampling
 * density toward the quad's narrow side, so some aliasing there under
 * NEAREST/BILINEAR is inherent, not a defect.
 *
 * A quad that is a PARALLELOGRAM within 1e-9 canvas px (opposite sides
 * equal; the fourth corner implied by the other three) is an affine
 * transform and is delegated to rz_doc_transform_layer — an integer
 * translation handed over as corners is still a lossless pixel copy.
 *
 * NULL if doc or quad is NULL, idx is out of range, any coordinate is not
 * finite, the quad is concave or self-intersecting (the mapping would fold
 * through the horizon inside the layer; a corner's homogeneous w must stay
 * >= 1e-6 with w = 1 pinned at the rect's top-left), the quad collapses
 * toward zero area, the sampler value is unknown, or the destination extent
 * is empty, falls outside the int32 offset range, or exceeds 100000000
 * pixels. */
RzDocument *rz_doc_perspective_layer(const RzDocument *doc, size_t idx,
                                     const double *quad,
                                     RzResizeFilter sampler);

/* ------------------------------------------------------------------------ */
/* Additional filters (pure RzImage operations, NULL on invalid args)       */
/* ------------------------------------------------------------------------ */

/* Rotates hue by degrees (any finite value; NULL on NaN). Alpha untouched. */
RzImage *rz_image_hue_rotate(const RzImage *img, float degrees);

/* Levels: maps [black, white] to [0,1] then applies gamma (out = t^(1/g)).
 * Requires 0 <= black < white <= 1 and gamma in [0.1, 10]; NULL otherwise. */
RzImage *rz_image_levels(const RzImage *img, float black, float white,
                         float gamma);

/* Luma threshold at level in [0,1]: output pixels become opaque-preserving
 * black or white by Rec.709 luma; alpha untouched. */
RzImage *rz_image_threshold(const RzImage *img, float level);

/* Reduces each color channel to `levels` evenly spaced values (2..=64). */
RzImage *rz_image_posterize(const RzImage *img, uint32_t levels);

/* Mosaic: block*block cells (1..=1024) averaged (alpha-weighted). */
RzImage *rz_image_pixelate(const RzImage *img, uint32_t block);

/* Additive uniform noise, amount in (0,1]; deterministic for a given seed.
 * Alpha untouched. */
RzImage *rz_image_noise(const RzImage *img, float amount, uint64_t seed);

/* Sobel edge magnitude on luma, rendered as an opaque grayscale image. */
RzImage *rz_image_edge_detect(const RzImage *img);

/* Emboss: 3x3 directional relief kernel on luma around mid-gray, opaque. */
RzImage *rz_image_emboss(const RzImage *img);

/* ---- Selection regions and region painting ------------------------------
 *
 * Selection masks are canvas-sized u8 coverage buffers (width*height
 * bytes, row 0 top): 0 = outside, 255 = fully inside, intermediate
 * values scale paint coverage at anti-aliased edges. */

/* Similar-color selection from the flattened composite ("select what you
 * see"): writes a canvas-sized 0/255 mask into mask_out. `tolerance` is
 * the maximum per-channel RGBA difference; `contiguous` restricts the
 * selection to the connected region around the seed. false on NULL or
 * out-of-canvas input. */
bool rz_doc_magic_wand(const RzDocument *doc, uint32_t x, uint32_t y,
                       uint8_t tolerance, bool contiguous, uint8_t *mask_out);

/* Bucket fill on layer idx: grows a similar-color region over the
 * layer's OWN pixels from canvas point (x, y) and paints rgba (straight,
 * 4 bytes) source-over it. `mask` is a selection coverage buffer or NULL
 * for none; a seed outside the canvas, the layer, or the mask is NULL. */
RzDocument *rz_doc_bucket_fill(const RzDocument *doc, size_t idx, int32_t x,
                               int32_t y, uint8_t tolerance,
                               const uint8_t *rgba, bool contiguous,
                               const uint8_t *mask);

typedef enum {
  RZ_GRADIENT_LINEAR = 0, /* along p0->p1, clamped past the ends */
  RZ_GRADIENT_RADIAL = 1, /* from p0, radius |p1-p0| */
} RzGradientKind;

/* Paints a two-color gradient source-over layer idx (the whole layer,
 * scaled by `mask` where given). Colors are straight RGBA (4 bytes
 * each), interpolated component-wise. NULL if p0 == p1 or coordinates
 * are not finite. */
RzDocument *rz_doc_gradient(const RzDocument *doc, size_t idx, float x0,
                            float y0, float x1, float y1,
                            const uint8_t *start_rgba,
                            const uint8_t *end_rgba, RzGradientKind kind,
                            const uint8_t *mask);

/* Clears the selected region of layer idx to transparency, in PROPORTION to
 * the selection's coverage. `mask` is a CANVAS-sized coverage buffer as
 * described above (w and h must equal the canvas size), mapped onto the layer
 * through its offset: each layer pixel takes the coverage c at its own canvas
 * position and its straight alpha becomes
 *
 *     alpha' = round(alpha * (255 - c) / 255)
 *
 * so full coverage erases the pixel, half coverage halves its alpha, and zero
 * coverage leaves it byte-identical — a feathered or anti-aliased selection
 * cuts a SOFT-edged hole, which is the point of the operation. A pixel whose
 * alpha reaches 0 also has its COLOR zeroed (nothing of it remains); one that
 * stays partly visible keeps its RGB exactly, since pixels are straight alpha
 * and scaling color would darken the surviving fringe. Layer pixels lying
 * outside the canvas are untouched (a selection never reaches past the
 * canvas), and only pixels change: the layer's mask, offset, name, opacity,
 * blend mode, visibility and metadata all survive.
 *
 * A mask that selects nothing is NOT an error — as with rz_doc_gradient there
 * is no seed to validate, so the call succeeds and the pixels come back
 * unchanged. NULL on a NULL doc or mask, w/h that are not the canvas size, or
 * an out-of-range idx. */
RzDocument *rz_doc_clear_selection(const RzDocument *doc, size_t idx,
                                   const uint8_t *mask, uint32_t w,
                                   uint32_t h);

/* Gaussian-feathers a selection mask in place (width*height coverage
 * bytes, row 0 top). Sampling clamps to the canvas edges, so a
 * selection touching the border keeps full coverage there. false on
 * NULL mask, zero dimensions, or a non-finite radius; radius <= 0
 * returns true and leaves the mask untouched. */
bool rz_selection_feather(uint8_t *mask, uint32_t width, uint32_t height,
                          float radius);

/* Selection morphology: in-place companions to rz_selection_feather on the
 * same width*height coverage buffers (row 0 top). Grow, shrink and border
 * are defined on the signed Euclidean distance to the mask's 50% contour:
 * coverage is first binarized at >= 128 — any feathered softness is
 * DELIBERATELY resolved to its 50% contour — and an exact Euclidean
 * distance transform both ways yields s = distance to the contour,
 * positive inside. The canvas boundary is NOT a contour: only the
 * inside/outside pixels actually present in the buffer count, so a full
 * mask stays full under grow and shrink, an empty mask stays empty, and
 * border maps both to empty (no contour, no band). New edges come back
 * with a fresh ~1px anti-aliased ramp.
 *
 * All four return false on a NULL mask, zero dimensions, or a non-finite
 * parameter; a parameter <= 0 returns true and leaves the mask untouched,
 * exactly as rz_selection_feather treats its radius. */

/* Grows (dilates) the selection by radius pixels of true Euclidean
 * distance: coverage' = clamp(s + radius + 0.5, 0, 1) * 255, so edges move
 * outward by radius and corners round into circular arcs. */
bool rz_selection_grow(uint8_t *mask, uint32_t width, uint32_t height,
                       float radius);

/* Shrinks (erodes) the selection by radius pixels: grow with -radius, so
 * edges move inward and outside corners round the same way. */
bool rz_selection_shrink(uint8_t *mask, uint32_t width, uint32_t height,
                         float radius);

/* Replaces the selection with an anti-aliased band width_px wide straddling
 * its 50% contour: coverage' = clamp(width_px/2 - |s| + 0.5, 0, 1) * 255. */
bool rz_selection_border(uint8_t *mask, uint32_t width, uint32_t height,
                         float width_px);

/* Smooths the selection: a Gaussian blur with exactly the sigma mapping of
 * rz_selection_feather, then a smoothstep contrast remap (t = v/255,
 * v' = round(255 * t^2 * (3 - 2t))). Corners round and jagged edges
 * reconcile while a long straight edge stays put — the blur is symmetric
 * across it and smoothstep fixes 1/2. Unlike grow/shrink/border this never
 * binarizes: soft coverage stays soft. */
bool rz_selection_smooth(uint8_t *mask, uint32_t width, uint32_t height,
                         float radius);

/* ---- Layer masks --------------------------------------------------------
 *
 * A layer mask is a per-layer grayscale coverage channel gating the layer's
 * alpha while compositing: 0 hides, 255 shows, intermediate values are
 * partial coverage, multiplied on top of the layer's opacity. A mask is
 * always exactly the LAYER's pixel size (never the canvas size) and it moves,
 * rotates, crops and scales WITH the layer (GIMP-style), so it keeps hiding
 * the same layer content wherever the layer sits on the canvas; replacing a
 * layer's pixels with a differently sized image drops it. Masks ride along
 * through the stack operations and are written by rz_doc_save_native (they
 * are what bumped the RZDC format to version 2).
 *
 * The layer getters above stay deliberately mask-free: rz_doc_layer_image and
 * rz_doc_layer_thumbnail return the layer's UNMASKED pixels, and the mask has
 * an image of its own (rz_doc_layer_mask_image) for a second thumbnail beside
 * them. Only the projection (rz_doc_flattened) applies masks. */

typedef enum {
  RZ_MASK_REVEAL_ALL = 0,     /* filled 255: the layer shows in full */
  RZ_MASK_HIDE_ALL = 1,       /* filled 0: the layer is hidden entirely */
  RZ_MASK_FROM_SELECTION = 2, /* the selection buffer, cropped to the layer */
} RzMaskKind;

/* Gives layer idx a mask (replacing any existing one) and enables it, at
 * exactly the layer's pixel size. For RZ_MASK_FROM_SELECTION, `selection` is
 * a CANVAS-sized coverage buffer as described under "Selection regions"
 * above — w and h must equal the canvas size — and is CROPPED to the layer's
 * rect: each mask pixel takes the selection value at its own canvas position,
 * and layer pixels lying outside the canvas get 0 (a selection never reaches
 * past the canvas). For the other kinds `selection` is unused: pass NULL,
 * 0, 0. NULL on out-of-range idx, an unknown kind, or a NULL / not
 * canvas-sized selection buffer. */
RzDocument *rz_doc_adding_layer_mask(const RzDocument *doc, size_t idx,
                                     RzMaskKind kind, const uint8_t *selection,
                                     uint32_t w, uint32_t h);

/* Drops layer idx's mask. With apply, the coverage is first baked into the
 * layer's alpha (alpha' = alpha * mask / 255, straight alpha) REGARDLESS of
 * the enabled flag — "apply" always means what it says — so applying an
 * ENABLED mask leaves the projection unchanged. Without apply the pixels are
 * untouched and the layer is revealed in full again. NULL on out-of-range idx
 * or a layer with no mask. */
RzDocument *rz_doc_removing_layer_mask(const RzDocument *doc, size_t idx,
                                       bool apply);

/* Enables or disables layer idx's mask: a disabled mask is RETAINED (and
 * saved) but ignored while compositing, so the layer composites exactly as if
 * it had none. NULL on out-of-range idx or a layer with no mask. */
RzDocument *rz_doc_with_layer_mask_enabled(const RzDocument *doc, size_t idx,
                                           bool enabled);

/* Paints layer idx's MASK with a CANVAS-frame PREMULTIPLIED RGBA8 overlay —
 * the very buffer rz_doc_painting_layer takes, w/h equal to the canvas size —
 * mapped through the layer's offset. Each mask pixel samples the overlay at
 * its canvas position and becomes
 *   mask' = round(lerp(mask, luma(straight color), overlay alpha))
 * so painting white reveals and black hides, with the stroke's own
 * anti-aliasing (and any selection the caller already clipped the overlay
 * with) carried by the alpha. Overlay pixels outside the layer are ignored
 * (the layer does NOT grow). NULL on a layer with no mask, on dimension
 * mismatch, or when the layer's extent does not intersect the canvas at all
 * (no mask pixel could change), matching rz_doc_painting_layer. */
RzDocument *rz_doc_painting_layer_mask(const RzDocument *doc, size_t idx,
                                       const uint8_t *src, uint32_t w,
                                       uint32_t h);

/* Layer idx's mask as an opaque grayscale image at the LAYER's size (for the
 * mask thumbnail beside the layer's own). NULL on out-of-range idx or a layer
 * with no mask. */
RzImage *rz_doc_layer_mask_image(const RzDocument *doc, size_t idx);

/* Mask queries. Both are false on NULL doc or out-of-range idx;
 * rz_doc_layer_mask_enabled is also false for a layer with no mask (there is
 * nothing to enable), so it can drive a checkbox or menu item directly. */
bool rz_doc_layer_has_mask(const RzDocument *doc, size_t idx);
bool rz_doc_layer_mask_enabled(const RzDocument *doc, size_t idx);

/* ---- Channels -----------------------------------------------------------
 *
 * A channel is a NAMED, CANVAS-SIZED u8 coverage plane stored on the
 * document — a saved selection, in exactly the representation selections and
 * layer masks already use (0 outside, 255 inside, intermediate =
 * anti-aliased edge). Channels never composite: they carry an overlay
 * colour, opacity and polarity only so a host can draw one as a rubylith.
 * Every canvas-geometry op keeps them canvas-sized — rz_doc_crop crops them,
 * rz_doc_canvas_resize pads with 0, the rotations and flips permute them,
 * rz_doc_resize resamples them; the per-layer ops leave them untouched, and
 * rz_doc_flattening keeps them. A host-composed whole-document rotation (the
 * Crop tool's straighten, which is rz_doc_transform_layer over every layer
 * followed by rz_doc_crop) is the one geometry the core cannot recognize as
 * such, so it has an op of its own: rz_doc_transform_channels turns the
 * channels by the same matrix inside the same edit. They are written by rz_doc_save_native (they
 * are what bumped the RZDC format to version 5).
 *
 * A PLANE crossing this boundary is always canvas width*height bytes, row 0
 * top — the selection convention — with THREE exceptions: rz_doc_add_channel,
 * which resamples a caller-sized plane, rz_image_plane, whose buffer is the
 * IMAGE's size, and rz_doc_with_layer_space_plane, whose buffer is the
 * LAYER's. Each is called out at its declaration.
 *
 * At most 256 channels, and at most 900000000 channel pixels in total (nine
 * full canvases, so that rz_doc_add_luminosity_masks' fixed nine always fit
 * a canvas this library will build); every op that creates channels — and
 * every op that GROWS the canvas under them, rz_doc_resize and
 * rz_doc_canvas_resize — refuses
 * rather than build a document rz_doc_save_native could write and
 * rz_doc_open could not read. rz_max_channels_at answers the same budget as
 * a number, so a host can name it in the refusal instead of just failing. */

typedef enum {
  RZ_PLANE_RED = 0,
  RZ_PLANE_GREEN = 1,
  RZ_PLANE_BLUE = 2,
  RZ_PLANE_ALPHA = 3,
  RZ_PLANE_LUMA = 4, /* Rec. 709 luma; read-only */
  RZ_PLANE_MASK = 5, /* a layer's mask; read-only, layers only */
} RzPlane;

/* --- channel list (getters) --- */

/* The largest channel count a w*h canvas may carry under both caps. No
 * document and no pointers: a zero dimension answers the count cap. Ask it
 * before Image Size, Canvas Size or rz_doc_add_luminosity_masks to tell the
 * user WHY those refuse, and how many channels would have to go. */
size_t rz_max_channels_at(uint32_t w, uint32_t h);

size_t rz_doc_channel_count(const RzDocument *doc);

/* Channel i's STABLE IDENTITY: unique among every channel this process has
 * minted, and the handle a host hangs per-channel view state on (which
 * channel's eye is on, say). Names are not unique and every insert, delete or
 * undo renumbers the list, so neither can identify a channel across an edit;
 * the id survives a rename, a plane edit, the geometry ops and undo/redo,
 * rz_doc_duplicate_channel mints a fresh one for the copy, and a channel that
 * is gone takes its id with it. NOT persisted — rz_doc_open mints new ids, so
 * the identity holds for as long as a document is open, not across sessions.
 * 0 on NULL doc / bad index, which no live channel ever answers. */
uint64_t rz_doc_channel_id(const RzDocument *doc, size_t i);

/* Heap UTF-8 name, free with rz_string_free; NULL on NULL doc / bad index. */
char *rz_doc_channel_name(const RzDocument *doc, size_t i);

/* Writes 3 bytes (r, g, b) into rgb_out. false on NULL / bad index. */
bool rz_doc_channel_overlay_color(const RzDocument *doc, size_t i,
                                  uint8_t *rgb_out);

/* 0.0 on NULL doc or bad index. */
float rz_doc_channel_overlay_opacity(const RzDocument *doc, size_t i);

/* "Color Indicates: Selected Areas" when true; false (the default) means the
 * wash covers the MASKED areas, matching Quick Mask. false on NULL. */
bool rz_doc_channel_color_indicates_selected(const RzDocument *doc, size_t i);

/* --- channel list (pure mutators; NULL = refusal, per the doc comments) --- */

/* Appends a channel from `plane` (w*h coverage bytes, row 0 top), with the
 * default masked-areas polarity (rz_doc_set_channel_overlay changes it).
 * THE FIRST EXCEPTION to the canvas-sized rule: when w/h differ from the
 * canvas the plane is resampled bilinearly to it (the iPhone
 * auxiliary-matte path), and the length therefore comes from the CALLER's
 * w*h with checked arithmetic, exactly as rz_doc_with_layer_pixels_rgba
 * already does. NULL on NULL args, w or h == 0, w*h > 100000000, a full
 * channel list (256), or a channel list that would exceed the total pixel
 * budget (so every document this builds can be saved and reopened). */
RzDocument *rz_doc_add_channel(const RzDocument *doc, const char *name,
                               const uint8_t *plane, uint32_t w, uint32_t h,
                               uint8_t red, uint8_t green, uint8_t blue,
                               float overlay_opacity);

RzDocument *rz_doc_remove_channel(const RzDocument *doc, size_t i);

/* NULL on a bad index or a name the channel already has. */
RzDocument *rz_doc_rename_channel(const RzDocument *doc, size_t i,
                                  const char *name);

/* All three display options at once — colour, opacity and polarity (one undo
 * step for the options sheet).
 * NULL when none of them would change. */
RzDocument *rz_doc_set_channel_overlay(const RzDocument *doc, size_t i,
                                       uint8_t red, uint8_t green,
                                       uint8_t blue, float overlay_opacity,
                                       bool color_indicates_selected);

/* `plane` is canvas-sized (w and h must equal the canvas exactly). NULL when
 * the bytes are identical to the channel's current plane. */
RzDocument *rz_doc_set_channel_data(const RzDocument *doc, size_t i,
                                    const uint8_t *plane, uint32_t w,
                                    uint32_t h);

/* Inserts a copy right after i, named "<name> copy". */
RzDocument *rz_doc_duplicate_channel(const RzDocument *doc, size_t i);

/* 255 - v. NULL only on a bad index. */
RzDocument *rz_doc_invert_channel(const RzDocument *doc, size_t i);

/* Appends nine channels built from the composite's Rec. 709 luma L:
 * "Lights n" = L^n, "Darks n" = (1-L)^n and "Midtones n" =
 * clamp(1 - L^(n+1) - (1-L)^(n+1)) for n = 1, 2, 3, in that order. The
 * midtone exponent is offset by one deliberately: the linear pair sums to 1
 * at every pixel, so the un-offset formula would be black everywhere.
 * NULL when the nine would not fit under either cap. */
RzDocument *rz_doc_add_luminosity_masks(const RzDocument *doc);

/* Resamples EVERY channel through an affine matrix in CANVAS coordinates —
 * the same six doubles in the same order, and the same RzResizeFilter kernel,
 * as rz_doc_transform_layer. For the one edit that turns the whole picture in
 * place: a straighten (rz_doc_transform_layer over every layer, then
 * rz_doc_crop) must carry the channels too, or every saved selection silently
 * stops lining up with the picture it was saved from. The channels stay
 * canvas-sized — the destination IS the canvas, so coverage rotated off it is
 * dropped (a straighten's crop rect lies inside the canvas, so nothing that
 * could survive the crop is lost) and destinations with no source read 0,
 * exactly as a layer mask does under the same matrix.
 *
 * NULL on NULL args, a document with no channels, a non-finite or singular
 * matrix, an unknown filter, or when no byte would change. */
RzDocument *rz_doc_transform_channels(const RzDocument *doc,
                                      const double *affine,
                                      RzResizeFilter sampler);

/* --- planes out, straight into a caller buffer (no image round trip) ---
 * All write exactly w*h bytes and return false on NULL, a dimension
 * mismatch, a bad index, or a plane this source cannot supply
 * (RZ_PLANE_MASK from a composite or an image, a layer with no mask). */

/* One plane of the FLATTENED composite. A ONE-SHOT op — it runs the whole
 * projection, so a host drawing a plane repeatedly reads its own cached
 * projection with rz_image_plane instead. */
bool rz_doc_composite_plane(const RzDocument *doc, RzPlane plane,
                            uint8_t *out, uint32_t w, uint32_t h);

/* One plane of layer idx, CANVAS-sized: pixels outside the layer's rect read
 * 0 for every plane, RZ_PLANE_MASK included (outside the layer there is
 * nothing for a mask to reveal). */
bool rz_doc_layer_plane(const RzDocument *doc, size_t idx, RzPlane plane,
                        uint8_t *out, uint32_t w, uint32_t h);

bool rz_doc_channel_plane(const RzDocument *doc, size_t i, uint8_t *out,
                          uint32_t w, uint32_t h);

/* THE SECOND EXCEPTION to the canvas-sized rule: w and h are the IMAGE's own
 * dimensions. For an opaque grayscale image RZ_PLANE_LUMA is the identity,
 * which makes this the lossless reader for the plane images below — and the
 * definition of "take the result's gray" for an op that un-grays one. */
bool rz_image_plane(const RzImage *img, RzPlane plane, uint8_t *out,
                    uint32_t w, uint32_t h);

/* --- planes out as opaque GRAYSCALE RGBA images (r == g == b, alpha 255) ---
 * max_side == 0 gives the plane at full size; otherwise the image is
 * aspect-fit with its longest side == max_side (the rz_doc_layer_thumbnail
 * rule). rz_image_plane_image reads a plane out of an image the host ALREADY
 * HAS — the cached projection — and is what a Channels panel's composite
 * rows and a plane canvas view use; the rz_doc_composite_* form re-flattens
 * and is for one-shot work only. */
RzImage *rz_image_plane_image(const RzImage *img, RzPlane plane,
                              uint32_t max_side);
RzImage *rz_doc_composite_plane_image(const RzDocument *doc, RzPlane plane,
                                      uint32_t max_side);
RzImage *rz_doc_layer_plane_image(const RzDocument *doc, size_t idx,
                                  RzPlane plane, uint32_t max_side);
RzImage *rz_doc_channel_image(const RzDocument *doc, size_t i,
                              uint32_t max_side);

/* --- plane writers --- */

/* Replaces ONLY `plane` of layer idx's pixels from a CANVAS-sized `src`,
 * inside the layer's rect (mapped through the layer's offset exactly as
 * rz_doc_painting_layer maps a stroke). RZ_PLANE_ALPHA writes STRAIGHT alpha
 * and clears the colour bytes of any pixel whose new alpha is 0. NULL for
 * RZ_PLANE_LUMA or RZ_PLANE_MASK, NULL args, dimension mismatch,
 * out-of-range idx, a layer extent that misses the canvas, or when no byte
 * would change — so a caller writing several planes must tolerate NULL per
 * plane. */
RzDocument *rz_doc_with_layer_plane(const RzDocument *doc, size_t idx,
                                    RzPlane plane, const uint8_t *src,
                                    uint32_t w, uint32_t h);

/* THE THIRD EXCEPTION to the canvas-sized rule: `src` is LAYER-sized — w and
 * h must equal layer idx's own pixel dimensions — and every sample is
 * written, including the part of the layer that hangs off the canvas. The
 * writer for the filter/adjustment round trip (rz_doc_layer_image +
 * rz_image_plane read the plane at that same size, so a neighbourhood filter
 * sees the layer's own border pixels rather than the zeros a canvas-sized
 * read leaves outside its rect); its canvas-sized sibling above would leave
 * the off-canvas ring of that ONE plane unfiltered, which the next Canvas
 * Size or Move turns into a colour seam. Same alpha rule and same refusals as
 * the sibling, plus NULL for a `src` that is not the layer's size. */
RzDocument *rz_doc_with_layer_space_plane(const RzDocument *doc, size_t idx,
                                          RzPlane plane, const uint8_t *src,
                                          uint32_t w, uint32_t h);

/* --- coverage painting (the mask-painting lerp; see
 *     rz_doc_painting_layer_mask for the formula) ---
 * `src` is a canvas-sized PREMULTIPLIED RGBA8 overlay, the very buffer
 * rz_doc_painting_layer takes: white paints toward 255, black toward 0, the
 * overlay's alpha carries the stroke's coverage. Both return NULL when no
 * byte would change (white over white is not an edit).
 *
 * rz_doc_painting_layer_plane refuses RZ_PLANE_LUMA and RZ_PLANE_MASK
 * (RZ_PLANE_MASK is rz_doc_painting_layer_mask's job) and, unlike
 * rz_doc_with_layer_plane, never clears the colour bytes when it paints
 * alpha to 0: a stroke is incremental, and the colour must survive an alpha
 * that dips and is painted back up. */
RzDocument *rz_doc_painting_channel(const RzDocument *doc, size_t i,
                                    const uint8_t *src, uint32_t w,
                                    uint32_t h);
RzDocument *rz_doc_painting_layer_plane(const RzDocument *doc, size_t idx,
                                        RzPlane plane, const uint8_t *src,
                                        uint32_t w, uint32_t h);

/* --- plane arithmetic (in place on CALLER-owned buffers, like the
 *     rz_selection_* family) ---
 * base = lerp(base, blend(base, source), opacity) per pixel, through the
 * same blend table the projection uses; a gray value is the triple (v, v, v)
 * and the result's gray is taken, so every SEPARABLE mode works, Dissolve's
 * canvas-absolute dither included. The four NON-SEPARABLE modes (Hue,
 * Saturation, Color, Luminosity) are REFUSED on a single plane: they are
 * defined over an RGB triple, and a gray triple has zero saturation, which
 * collapses three of them to the base and the fourth to Normal. Blend three
 * planes as one colour with rz_blend_planes_rgb instead — that is where they
 * mean something. invert_base and invert_source invert an operand FIRST, so
 * the complement is both blended and lerped from. These two are the ONE
 * arithmetic behind Apply Image and Calculations; Apply Image passes the
 * target plane as `base`, Calculations passes Source 2 as `base` and Source 1
 * as `source` (Photoshop's convention). false on NULL, a zero dimension,
 * w*h > 100000000, an unknown mode, or a non-finite opacity; on false every
 * buffer is left untouched.
 *
 * rz_blend_planes_rgb takes red, green and blue as three separate planes
 * (base and source alike), blends them AS ONE COLOUR and writes the three
 * results back into the base buffers — Apply Image with an RGB source onto an
 * RGB target. It accepts every mode, the non-separable four included. The
 * three base buffers should be distinct; aliasing them is defined but
 * answers whichever write lands last. */
bool rz_blend_planes(uint8_t *base, const uint8_t *source, uint32_t w,
                     uint32_t h, RzBlendMode mode, float opacity,
                     bool invert_base, bool invert_source);
bool rz_blend_planes_rgb(uint8_t *base_r, uint8_t *base_g, uint8_t *base_b,
                         const uint8_t *source_r, const uint8_t *source_g,
                         const uint8_t *source_b, uint32_t w, uint32_t h,
                         RzBlendMode mode, float opacity, bool invert_base,
                         bool invert_source);

/* ---- Clipping masks -----------------------------------------------------
 *
 * Every layer carries a CLIPPED flag (default false): a clipped layer is
 * confined to the alpha footprint of the first unclipped layer beneath it —
 * Photoshop clipping-mask semantics, "blend clipped layers as group". Group
 * structure is purely POSITIONAL and re-derived at every composite: any
 * unclipped layer is a BASE, and its clip group is the consecutive run of
 * clipped layers immediately above it, so reordering or deleting layers
 * needs no bookkeeping. A clipped layer at the BOTTOM of the stack (nothing
 * unclipped below) has no base and composites as if unclipped.
 *
 * A base with no clipped layers above composites exactly as it always did.
 * A non-empty group blends as one unit: the base renders into a private
 * transparent buffer at FULL opacity in Normal mode, its layer mask applied
 * as usual, and the buffer's alpha after that render is the group's
 * footprint. Each visible clipped layer then composites into the buffer
 * through the normal kernel — its own opacity, blend mode (blending against
 * the base's content), mask and offset; an adjustment layer adjusts the
 * buffer — and after each one the buffer's alpha is forced back to the
 * footprint, so clipped layers never extend or shrink it. The finished
 * buffer composites into the real backdrop with the BASE layer's blend mode
 * and opacity. Hiding the base hides its whole group; invisible clipped
 * layers are skipped.
 *
 * The flag rides along wherever the layer survives as itself (setters,
 * painting, geometry, reordering), is copied by rz_doc_duplicating_layer,
 * is baked through by rz_doc_merging_down (which keeps the LOWER layer's
 * flag — see above), and round-trips through rz_doc_save_native: it is what
 * bumped the RZDC format to version 3. */

/* Pure setter: replaces layer idx's clipped flag. NULL on NULL doc or
 * out-of-range idx. */
RzDocument *rz_doc_with_layer_clipped(const RzDocument *doc, size_t idx,
                                      bool clipped);

/* The layer's clipped flag; false on NULL doc or out-of-range idx. */
bool rz_doc_layer_clipped(const RzDocument *doc, size_t idx);

/* ---- Layer metadata -----------------------------------------------------
 *
 * Every layer carries an optional metadata string: an OPAQUE, host-owned blob
 * that the core stores, copies and serializes but never parses — with ONE
 * exception: the compositor recognizes the {"type":"adjust", ...} shape
 * (schema in core/src/adjust.rs; query with rz_doc_layer_is_adjustment below)
 * and composites such a layer as a color adjustment of the backdrop instead
 * of as pixels. For every other blob its meaning, its schema and its
 * versioning belong entirely to the host — the core only guarantees the bytes
 * come back exactly as they went in. Rasterize uses it to keep the parameters
 * a layer's pixels were rendered from (a text layer's string, font, size,
 * color, alignment), making the raster a cache of a description the host can
 * re-render.
 *
 * Lifetime rules, all of them consequences of ONE principle — metadata is
 * attached to a layer's identity, not to its pixel values:
 *   - It rides along wherever the layer survives as itself: the pure per-layer
 *     setters, pixel replacement, painting/fill/gradient/clear, mask
 *     operations, duplicating (the copy gets it too), reordering, adding and
 *     removing layers, whole-document rotate/flip/crop/canvas-resize/resize.
 *   - It is DROPPED exactly where a layer stops being itself, alongside the
 *     mask: rz_doc_merging_down clears it — and the layer style — on the
 *     merged layer (the pixels are now two layers' worth, so nothing
 *     describes them) and rz_doc_flattening produces one plain "Background"
 *     layer with none.
 *   - It round-trips through rz_doc_save_native / rz_doc_open in the
 *     version-2 RZDC format, per layer. Older readers see a plain raster
 *     layer, which is the intended graceful degradation.
 * The host stays responsible for dropping metadata that its own rules say a
 * destructive edit invalidates — the core has no opinion, because it cannot
 * read the blob.
 *
 * Re-rendering a layer in place needs no special entry point: every operation
 * is pure, so chain rz_doc_with_layer_pixels_rgba, rz_doc_with_layer_offset
 * and rz_doc_with_layer_meta — or, when a mask must land with the new
 * pixels, rz_doc_set_layer_content (after rz_doc_transform_layer when the
 * re-render follows a transform: that moves the mask and scales the style,
 * and the host's own rendering replaces the resampled pixels) — and commit
 * only the final handle: one edit, one undo step. */

/* Layer idx's metadata as a heap string freed with rz_string_free; NULL on
 * out-of-range idx or a layer with no metadata (so NULL means "none", not an
 * error). Interior NUL bytes, which only a hand-crafted RZDC file could carry,
 * come back as spaces — the price of a C string. */
char *rz_doc_layer_meta(const RzDocument *doc, size_t idx);

/* Replaces layer idx's metadata with a copy of `meta`, or CLEARS it when
 * `meta` is NULL. `meta` must be valid UTF-8 of at most 16 MiB (16777216
 * bytes) — the RZDC writer's own cap, enforced here so a document can never
 * hold metadata the format would later refuse to store. NULL on out-of-range
 * idx, invalid UTF-8 (refused, never lossily converted), or an over-long
 * payload. */
RzDocument *rz_doc_with_layer_meta(const RzDocument *doc, size_t idx,
                                   const char *meta);

/* Whether layer idx's metadata parses as a color-adjustment description
 * ({"type":"adjust", ...} — schema in core/src/adjust.rs), i.e. whether the
 * compositor treats the layer as an ADJUSTMENT LAYER: its own pixels are
 * ignored and its contribution is the adjustment applied to the accumulated
 * backdrop, pushed through its blend mode and scaled by opacity * mask
 * coverage (an unmasked adjustment layer reaches the whole canvas; alpha is
 * never changed). False on out-of-range idx, absent meta, or meta that does
 * not parse as an adjustment (such a layer composites as plain raster). */
bool rz_doc_layer_is_adjustment(const RzDocument *doc, size_t idx);

/* Replaces layer idx's pixels with a copy of a straight-alpha RGBA8 buffer
 * (`src`, exactly w*h*4 bytes, row 0 top) — the same op as
 * rz_doc_with_layer_pixels, for a host that renders into memory rather than
 * into a file. The layer takes the buffer's size and keeps its offset, name,
 * opacity, blend mode, visibility and metadata. NOTE the size rule it shares
 * with rz_doc_with_layer_pixels: a layer MASK survives a same-size
 * replacement, but a replacement at different dimensions drops it (a mask is
 * always exactly the layer's pixel size), so a re-render that changes size
 * loses the mask. NULL on out-of-range idx, NULL src, w == 0, h == 0, or
 * w*h > 100000000 — the dimensions are the buffer's only declared length, so
 * they are bounded like rz_doc_resize's before anything is read. */
RzDocument *rz_doc_with_layer_pixels_rgba(const RzDocument *doc, size_t idx,
                                          const uint8_t *src, uint32_t w,
                                          uint32_t h);

/* Replaces layer idx's pixels, offset and mask in ONE pure step — the
 * re-render primitive for a described layer whose raster, position and mask
 * change together (a text layer rotated by its own description; a Live Photo
 * re-framed under a transform). `src` is straight RGBA8, w*h*4 bytes, row 0
 * top; `mask` is NULL (the layer ends with no mask; mask_enabled resets to
 * true) or exactly w*h coverage bytes at the pixels' size (mask_enabled is
 * kept, so a disabled mask stays disabled). Name, opacity, blend mode,
 * visibility, metadata, style and clipped flag survive. NULL on out-of-range
 * idx, NULL src, w == 0, h == 0, or w*h > 100000000 — dimensions bounded
 * before anything is read, as for rz_doc_with_layer_pixels_rgba. */
RzDocument *rz_doc_set_layer_content(const RzDocument *doc, size_t idx,
                                     const uint8_t *src, uint32_t w,
                                     uint32_t h, int32_t x, int32_t y,
                                     const uint8_t *mask);

/* ---- Layer styles -------------------------------------------------------
 *
 * Every layer carries an optional LAYER STYLE: Photoshop's effect stack plus
 * the blending options beyond opacity and mode — fill opacity (the opacity
 * of the pixels only, never of the effects) and Blend If (two split-slider
 * ramps, on this layer and on the composite beneath, weighting the layer's
 * alpha). The effects are functions of the layer's SHAPE (its alpha times
 * its enabled mask) and are rendered by the projection only:
 * rz_doc_layer_image, rz_doc_layer_canvas_image and the thumbnails stay
 * effect-free, exactly as they stay mask-free.
 *
 * The style crosses this boundary as ONE JSON object — the contract:
 *   {"version": 1, "fill_opacity": 1.0, "blend_if": null,
 *    "effects": [{"type": "drop_shadow", ...}, ...]}
 * The nine effect types are drop_shadow, inner_shadow, outer_glow,
 * inner_glow, stroke, color_overlay, gradient_overlay, bevel_emboss and
 * satin — at most one of each; every effect has "enabled" (default true; a
 * disabled effect is kept but not rendered), its own blend mode ("blend",
 * the 27 layer blend modes as snake_case names: normal, multiply, screen,
 * linear_dodge, ...) and opacity. Colours are "#rrggbb"; angles are degrees
 * in the Photoshop convention (0 = light from the right, 90 = from the top;
 * the default 120° casts down-right); sizes are canvas pixels; "spread" /
 * "choke" are fractions of "size". The full key table with every default
 * lives in core/src/style.rs. On input unknown keys are ignored, missing
 * keys take their defaults, numeric ranges are clamped, and a wrong JSON
 * type, unknown enum value, unknown effect type, duplicate type or
 * out-of-order Blend If ramp is an error naming the key. Numbers are
 * canonicalized to 4 decimals; rz_doc_layer_style returns the canonical
 * form (every key of every present effect, effects in render order, sorted
 * keys), which is also what the RZDC file stores.
 *
 * Identity rule: a style that renders nothing (fill opacity 1, no Blend If,
 * no enabled effect) CLEARS — it is never stored — so rz_doc_layer_has_style
 * true means the layer renders something.
 *
 * Lifetime: the style rides along wherever the layer survives as itself
 * (exactly like metadata above); rz_doc_duplicating_layer copies it;
 * rz_doc_merging_down and rz_doc_flattening BAKE the effects into the pixels
 * and drop it; rz_doc_transform_layer, rz_doc_perspective_layer and
 * rz_doc_resize apply "Scale Effects" (the pixel-valued fields follow the
 * mean scale factor). Adjustment layers ignore styles (they have no shape).
 *
 * Render order, Photoshop's: the drop shadow, outer glow and an outside
 * stroke composite BELOW the pixels, each with its own blend mode and
 * opacity; the pixels composite at fill opacity (times the Blend If weight)
 * with the LAYER's blend mode; then gradient overlay, colour overlay, satin,
 * inner glow, inner shadow, an inside/centre stroke and the bevel composite
 * above them, each with its own blend mode ("Blend Interior Effects as
 * Group" is off, so a Multiply layer with a white colour overlay shows
 * white). Blend If reads the composite BENEATH the layer, not the layer's
 * own shadow. A styled clip base renders its shadow once under the whole
 * group, and clipped members are confined to the base's shape.
 *
 * Effects with "use_global_light" read the document's GLOBAL LIGHT (angle,
 * altitude in degrees; defaults 120°, 30°) instead of their own angle. The
 * style and the light round-trip through rz_doc_save_native / rz_doc_open:
 * they are what bumped the RZDC format to version 4. */

/* Replaces layer idx's style with a copy of `style_json` (parsed and
 * canonicalized as described above), or CLEARS it when `style_json` is
 * NULL — and also clears it when the parsed style is an identity. Two
 * failure tiers: NULL with a message through err_out (free with
 * rz_string_free) when doc is NULL ("document is NULL"), the string is not
 * valid UTF-8, not valid JSON, not a valid style (the message names the
 * offending key), or over 16 MiB (the RZDC writer's cap, shared with
 * metadata); NULL with NO message — a refusal, not an error — on an
 * out-of-range idx or a value equal to the current one ("no style"
 * included), so the host never registers a phantom undo step. */
RzDocument *rz_doc_set_layer_style(const RzDocument *doc, size_t idx,
                                   const char *style_json, char **err_out);

/* Layer idx's style as its canonical JSON, a heap string freed with
 * rz_string_free; NULL on NULL doc, out-of-range idx, or a layer with no
 * style (so NULL means "none", not an error). */
char *rz_doc_layer_style(const RzDocument *doc, size_t idx);

/* Whether layer idx carries a style — the cheap badge query; false on NULL
 * doc or out-of-range idx. Because identity styles are never stored, true
 * means the layer renders something. */
bool rz_doc_layer_has_style(const RzDocument *doc, size_t idx);

/* Pure setter for the document's global light, in degrees. NULL on NULL doc,
 * a non-finite component, or no change after sanitizing (altitude clamped to
 * [0, 90], angle normalized to [-180, 180), both quantized to four decimals
 * like every style number, so a reported value echoed back is "no change"). */
RzDocument *rz_doc_set_global_light(const RzDocument *doc, float angle,
                                    float altitude);

/* The global light's components in degrees; 0.0 on NULL doc. */
float rz_doc_global_light_angle(const RzDocument *doc);
float rz_doc_global_light_altitude(const RzDocument *doc);

/* ---- Embedded agent (MCP) server ----------------------------------------
 *
 * A minimal MCP server (streamable-HTTP transport, tools only) hosted in
 * this library so an external AI agent (goose, or any MCP client) can
 * drive the application. The library owns the protocol; the application
 * supplies the tool catalog and executes tool calls via the handler.
 * One server per process. */

/* Executes one tool call. Called from the server thread for every
 * `tools/call`; `arguments_json` is the call's arguments object. Must
 * return a CallToolResult JSON object (`{"content": [...], "isError":
 * bool}`) allocated with rz_agent_string_create, or NULL to report a
 * handler failure. */
typedef char *(*RzAgentToolHandler)(void *context, const char *tool_name,
                                    const char *arguments_json);

/* Allocates a library-owned copy of `s` for handler return values.
 * Ownership passes back to the library on return; never free it. */
char *rz_agent_string_create(const char *s);

/* Starts the MCP server on 127.0.0.1:port (0 picks an ephemeral port);
 * the endpoint answers JSON-RPC POSTs on any path (/mcp canonical).
 * `tools_json` is the tools/list catalog as a JSON array. `handler` and
 * `context` must stay valid and callable from any thread until
 * rz_agent_server_stop returns. Returns the bound port, or 0 on failure
 * with a message through err_out (free with rz_string_free). */
uint16_t rz_agent_server_start(uint16_t port, const char *server_name,
                               const char *server_version,
                               const char *tools_json,
                               RzAgentToolHandler handler, void *context,
                               char **err_out);

/* Stops the server and joins its thread. Safe with no server running. */
void rz_agent_server_stop(void);

/* ---- Built-in assistant (agent loop) ------------------------------------
 *
 * A tool-use agent loop over the Anthropic Messages API, hosted in this
 * library. One RzAssistant is one conversation. Turns run on a worker
 * thread: the model is called, requested tools execute through the same
 * RzAgentToolHandler contract the MCP server uses, results feed back,
 * and the loop repeats until the model stops. Progress arrives through
 * the event handler as JSON objects: turn_started, assistant_text,
 * tool_call, tool_result, error, turn_finished. */

typedef struct RzAssistant RzAssistant;

/* Receives each event as a JSON string on the worker thread. The string
 * is only valid for the duration of the call — copy it. */
typedef void (*RzAssistantEventHandler)(void *context, const char *event_json);

/* Creates a conversation. config_json: {"api_key", "model", "system"
 * (required strings), "api_base" (default https://api.anthropic.com),
 * "max_tokens" (default 4096)}. tools_json: the same MCP-format catalog
 * array rz_agent_server_start takes. Both handler/context pairs must
 * stay valid and callable from any thread until rz_assistant_free
 * returns. NULL on failure with a message through err_out. */
RzAssistant *rz_assistant_new(const char *config_json, const char *tools_json,
                              RzAgentToolHandler tool_handler,
                              void *tool_context,
                              RzAssistantEventHandler event_handler,
                              void *event_context, char **err_out);

/* Starts one turn with the user's message. false while a turn is
 * already running (nothing is queued). */
bool rz_assistant_send(const RzAssistant *assistant, const char *user_text);

/* True while a turn is running. */
bool rz_assistant_is_busy(const RzAssistant *assistant);

/* Asks the running turn to stop at the next tool/API boundary; the turn
 * still emits turn_finished as it winds down. */
void rz_assistant_cancel(const RzAssistant *assistant);

/* Cancels, joins the worker, frees. NULL is a safe no-op. */
void rz_assistant_free(RzAssistant *assistant);

/* Frees strings returned via err_out parameters. NULL is a safe no-op. */
void rz_string_free(char *s);

/* Static version string, e.g. "0.1.0". Do not free. */
const char *rz_core_version(void);

#ifdef __cplusplus
}
#endif

#endif /* RASTERIZE_CORE_H */
