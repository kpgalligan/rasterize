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
  /* A GROUP whose children composite straight onto the backdrop below the
     group instead of into a private buffer. Not a blend function: legal only
     on a group entry (see "Layer groups" below), refused by
     rz_doc_with_layer_blend_mode on a raster layer and by every plane and
     paint blend. */
  RZ_BLEND_PASS_THROUGH = 27,
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
 * than 64 KiB are truncated on a UTF-8 character boundary, and each of the
 * four version-6 document blobs is capped at 16 MiB. A malformed depth
 * sequence, a nesting deeper than ten levels, and a document whose isolated
 * groups declare more canvas area than this build will composite are errors
 * too, at BOTH ends: the writer refuses to produce a file it could not read
 * back, and so is more than 1024 guides. Layout (little-endian): "RZDC",
 * u32 version=8,
 * u32 canvas width, u32 canvas height, u32 layer count, then (version 4)
 * f32 global-light angle and f32 altitude in degrees; then per layer
 * bottom-to-top: u32 name byte length + UTF-8 name, i32 offset x, i32
 * offset y, f32 opacity, u32 blend mode, u8 visible, u32 PNG byte length +
 * PNG-encoded RGBA8 layer pixels; then the version-2 fields, which a
 * version-1 record simply lacks: u8 mask present, u8 mask enabled, u32 mask
 * byte length + that many RAW coverage bytes when present (a mask is always
 * the layer's pixel count — or, for a GROUP, the canvas's; see the
 * version-7 fields below — so its dimensions are not stored twice), then u8
 * layer-metadata present and, when present, u32 byte length + UTF-8 bytes (see
 * "Layer metadata" below); then the version-3 field, appended after all the
 * version-2 fields (each older record is a strict prefix of the next): u8
 * clipped (see "Clipping masks" below); then the version-4 field: u8
 * layer-style present and, when present, u32 byte length + UTF-8 canonical
 * style JSON (see "Layer styles" below); then the version-7 fields, twelve
 * bytes closing the record (see "Layer groups, locks, links and structure"
 * below): u32 lock flags (an RzLockFlags bitmask, bits 3..31 reserved and
 * masked off by the reader), u32 link-group id (0 = unlinked), u16 nesting
 * depth (0 = top level), u8 kind (0 = raster, 1 = group; any other value is
 * an error) and u8 group-open, the panel disclosure flag, which is
 * meaningless on a raster entry. A GROUP entry's pixel PNG is a 1x1 fully
 * transparent PNG, so the record shape stays uniform; its MASK, however, is
 * CANVAS-sized rather than layer-sized, so the reader accepts a stored mask
 * length equal to either and only builds the mask once the kind byte says
 * which it must be, refusing the wrong pairing. Note that whole-FILE
 * prefixing does not hold for version 7 — its bytes go inside each record,
 * not at the tail, exactly as version 4's did. After the LAST layer record
 * comes the version-5 block, the alpha channel list (see "Channels" below):
 * u32 channel count, then per channel u32 name byte length + UTF-8 name, u8
 * overlay red, u8 green, u8 blue, f32 overlay opacity, u8 color-indicates-
 * selected, and u32 PNG byte length + a PNG-encoded 8-bit GRAYSCALE (L8)
 * plane of exactly the canvas size (a channel is always canvas-sized, so its
 * dimensions are not stored twice). After the channel list comes the
 * version-6 DOCUMENT TAIL (see "Colour management and metadata" below):
 * f32 horizontal and f32 vertical print resolution in pixels per inch, then
 * four optional blobs in this order — the ICC colour profile, the EXIF
 * packet, the XMP packet and the IPTC packet — each written as u8 present
 * and, when present, u32 byte length + that many RAW bytes. The blobs are
 * stored verbatim and never interpreted; the ICC slot is written ABSENT
 * when the document's profile is the built-in sRGB, and an absent slot
 * reads back as that profile, so a blob-less version-6 file is a version-5
 * file plus exactly 12 bytes. Last comes the version-8 GUIDE BLOCK, closing
 * the file (see "Guides, rulers and snapping" below): f64 ruler-origin x, f64
 * ruler-origin y, u32 guide count (more than 1024 is an error), then per
 * guide u8 orientation (0 = horizontal, 1 = vertical; any other value is an
 * error) and f64 position. Because it is a TAIL, a guide-less version-8 file
 * is a version-7 file with the version word bumped plus exactly 20 bytes —
 * a SIZE property, not a literal byte prefix, since the version word itself
 * sits at byte 4. Version-1, -2, -3, -4, -5, -6 and -7 files still
 * load, missing fields taking their defaults: no mask and no metadata on any
 * layer (v1), clipped false (v1 and v2), no style on any layer and a
 * (120°, 30°) global light (v1–v3), no channels (v1–v4), a 72 × 72 ppi
 * resolution, the built-in sRGB profile and no metadata packets (v1–v5),
 * an unlocked, unlinked, open RASTER entry at depth 0 — a flat stack — for
 * every layer (v1–v6), and no guides with the ruler origin at the canvas's
 * top-left (v1–v7). A
 * style is read leniently: a style from a newer build keeps the effects this
 * build knows; the resolution is sanitized rather than refused, exactly like
 * the global light, and so are the ruler origin and each guide position (a
 * non-finite origin component becomes 0, a non-finite position drops that
 * guide, an out-of-canvas value is clamped to the nearest edge). */
bool rz_doc_save_native(const RzDocument *doc, const char *path,
                        char **err_out);

uint32_t rz_doc_width(const RzDocument *doc);
uint32_t rz_doc_height(const RzDocument *doc);
size_t rz_doc_layer_count(const RzDocument *doc);

/* Layer getters. Out-of-range idx: NULL / 0 / RZ_BLEND_NORMAL / false.
 * rz_doc_layer_name returns a heap string freed with rz_string_free.
 * The four geometry getters report the entry's PIXEL BUFFER rect: for a
 * RASTER entry its offset and dimensions, unchanged, and for a GROUP (see
 * "Layer groups" below) — which has no buffer of its own — the union of its
 * raster descendants' buffer rects, 0 for a group holding none. One meaning
 * for both kinds, and cheap on both: rz_doc_layer_bounds is the CONTENT box
 * (the opaque pixels), and callers that mean that ask for it by name. */
char *rz_doc_layer_name(const RzDocument *doc, size_t idx);
float rz_doc_layer_opacity(const RzDocument *doc, size_t idx);
RzBlendMode rz_doc_layer_blend_mode(const RzDocument *doc, size_t idx);
bool rz_doc_layer_visible(const RzDocument *doc, size_t idx);
int32_t rz_doc_layer_offset_x(const RzDocument *doc, size_t idx);
int32_t rz_doc_layer_offset_y(const RzDocument *doc, size_t idx);
uint32_t rz_doc_layer_width(const RzDocument *doc, size_t idx);
uint32_t rz_doc_layer_height(const RzDocument *doc, size_t idx);

/* Copy of a layer's pixels at the layer's own size. NULL on a GROUP, which
 * has no pixels of its own. */
RzImage *rz_doc_layer_image(const RzDocument *doc, size_t idx);

/* A layer's own pixels on a transparent CANVAS-sized image, placed at its
 * offset — the single-layer counterpart of rz_doc_flattened. Opacity, blend
 * mode, visibility and the layer mask are ignored: they say how the layer
 * composites, not what its pixels are. On a GROUP this is its RAW projection
 * — its children only, without the group's own opacity, blend mode, mask or
 * style — which keeps exactly the same contract. */
RzImage *rz_doc_layer_canvas_image(const RzDocument *doc, size_t idx);

/* Aspect-fit thumbnail of a layer, longest side == max_side (min 1). On a
 * GROUP it is that projection, aspect-fit; a layers panel wanting a cheap
 * group row should draw a folder glyph rather than ask for one per reload. */
RzImage *rz_doc_layer_thumbnail(const RzDocument *doc, size_t idx,
                                uint32_t max_side);

/* Canvas-sized projection: visible layers composited bottom-to-top in f32,
 * straight-alpha result. Compositing follows the W3C model: with backdrop
 * (Cb, ab), source layer (Cs, as' = as * opacity) and blend function B:
 *   ao = as' + ab*(1-as')
 *   Co = ( as'*(1-ab)*Cs + as'*ab*B(Cb,Cs) + (1-as')*ab*Cb ) / ao   (ao > 0)
 * Invisible layers are skipped; areas a layer does not cover use Cb. Layers
 * flagged clipped composite in groups with the unclipped SIBLING beneath them
 * (see "Clipping masks" below), and LAYER GROUPS composite as described under
 * "Layer groups" below — pass-through groups transparently, isolated ones
 * rendered once into a private buffer. Layers carrying a style composite with their
 * effects (see "Layer styles" below). */
RzImage *rz_doc_flattened(const RzDocument *doc);

/* Pure per-layer setters: return a NEW document (input untouched), NULL on
 * out-of-range idx or NULL args. Opacity is clamped to [0,1]. Each also
 * answers NULL when the entry ALREADY holds the value passed (the offset
 * pair included, on a group as on a layer): an op that changes nothing
 * returns nothing, so a host reading a row and writing it straight back adds
 * no undo step and does not dirty the document. */
RzDocument *rz_doc_with_layer_name(const RzDocument *doc, size_t idx,
                                   const char *name);
RzDocument *rz_doc_with_layer_opacity(const RzDocument *doc, size_t idx,
                                      float opacity);
/* RZ_BLEND_PASS_THROUGH is legal only on a GROUP; naming it for a raster
 * layer is a refusal (NULL). */
RzDocument *rz_doc_with_layer_blend_mode(const RzDocument *doc, size_t idx,
                                         RzBlendMode mode);
RzDocument *rz_doc_with_layer_visible(const RzDocument *doc, size_t idx,
                                      bool visible);
/* On a GROUP this SHIFTS the whole subtree, so the origin of the rect the four
 * geometry getters report — the union of its layers' buffer rects — lands at
 * (x, y); NULL for a group holding no layer. Every canvas-sized GROUP MASK in
 * that subtree slides by the same delta: a mask travels with the thing it
 * masks, on a group exactly as on a layer, and the area it vacates reads 0.
 * Reading an entry's offset and writing it back is therefore the identity on
 * both kinds of entry. It is a property write and deliberately does NOT follow
 * links. */
RzDocument *rz_doc_with_layer_offset(const RzDocument *doc, size_t idx,
                                     int32_t x, int32_t y);

/* Replaces a layer's pixels (any size; offset and properties kept). See
 * rz_doc_with_layer_pixels_rgba under "Layer metadata" for the variant that
 * takes a rendered buffer instead of an image handle. */
RzDocument *rz_doc_with_layer_pixels(const RzDocument *doc, size_t idx,
                                     const RzImage *img);

/* Stack operations (all pure). Insertion index semantics: the new layer is
 * inserted ABOVE idx — above its whole SUBTREE, at idx's own depth, which is
 * position idx+1 on a document with no groups and rz_doc_layer_subtree's
 * *out_end in general. idx must be in range. */
RzDocument *rz_doc_adding_layer(const RzDocument *doc, size_t idx,
                                const char *name); /* transparent, canvas-sized, offset 0 */
RzDocument *rz_doc_adding_image_layer(const RzDocument *doc, size_t idx,
                                      const RzImage *img, const char *name);
/* Duplicates the entry and, for a group, its whole subtree — depths kept,
 * " copy" appended to the top entry's name only. Metadata and style are
 * copied like every other property; LINKS are not. */
RzDocument *rz_doc_duplicating_layer(const RzDocument *doc, size_t idx);
/* Removes the entry and, for a group, its whole subtree. NULL when that would
 * leave the document with no entries at all. */
RzDocument *rz_doc_removing_layer(const RzDocument *doc, size_t idx);
/* Removes the entry (with its subtree) and reinserts it at `to`, taking the
 * DEPTH of whatever entry sits at `to` — the natural reading of a panel drag
 * onto a row, and byte-for-byte the old remove-then-insert on a document with
 * no groups. rz_doc_move_layer_to names a depth explicitly. */
RzDocument *rz_doc_moving_layer(const RzDocument *doc, size_t from, size_t to);

/* Merges layer idx (idx >= 1) into the layer below it. BOTH layers' blend
 * modes and opacities are baked into the merged pixels (same math as the
 * projection, the lower compositing onto a transparent backdrop), so the
 * merged layer is RZ_BLEND_NORMAL at opacity 1.0; it keeps only the LOWER
 * layer's name, visibility and clipped flag and covers the union of both
 * layers' extents. A CLIPPED upper layer is baked through its clipping: its
 * contribution is alpha-limited to the lower layer's footprint (the same
 * group kernel as the projection — see "Clipping masks" below). An invisible
 * upper layer is simply removed. "The layer below" is the previous SIBLING —
 * the entry immediately below within the entry's own level, which is idx - 1
 * on a document with no groups — and either operand may be a GROUP, which is
 * rendered to pixels first, so a group merged down (or merged into) becomes a
 * plain raster entry and its subtree is removed. NULL if idx is at the BOTTOM
 * of its level / out of range, or if the LOWER entry is hidden (the merge
 * would discard the upper entry's content). */
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

/* Retouching: healing, inpainting and red-eye. */

/* Poisson-blends the source patch an overlay carries into layer idx: the
 * source's TEXTURE with the destination's ILLUMINATION. src is the SAME
 * canvas-frame premultiplied overlay rz_doc_painting_layer takes (w/h must
 * equal the canvas size): its ALPHA is the footprint's coverage and its RGB
 * the already-aligned source pixels, so the Clone Stamp's overlay is
 * literally the healing brush's input. Covered pixels (alpha >= 128) that
 * have a covered-and-usable neighbourhood are solved; a covered pixel next
 * to an uncovered one keeps the destination, which is what makes the join
 * seamless — so a hard-edged footprint needs no feather, and coverage below
 * 128 is not written at all (hardness shrinks the footprint, it does not
 * fade the heal). The covered set is split into connected components, each
 * solved over its own bounding box. Straight colour, per channel, in the
 * document's own numbers; layer alpha is never touched and fully transparent
 * destination pixels are skipped. strength scales the write-back and is
 * clamped to [0, 1]. Overlay outside the layer's extent is ignored (the layer
 * does NOT grow). NULL with *err_out set when one region's bounding box
 * exceeds the documented memory limit, or when every region's box together
 * exceeds the documented working-area limit for one call — both are measured
 * BEFORE anything is healed, so a refusal costs a component walk and not a
 * heal; NULL with *err_out NULL on NULL args,
 * dimension mismatch, non-finite strength, out-of-range idx, an empty covered
 * set, a covered set with no interior to solve (every covered pixel is on the
 * join contour, where the heal IS the destination), a layer extent that
 * misses the canvas, or when no pixel would change. Free *err_out with
 * rz_string_free. */
RzDocument *rz_doc_heal_layer(const RzDocument *doc, size_t idx,
                              const uint8_t *src, uint32_t w, uint32_t h,
                              float strength, char **err_out);

/* Spot healing: PatchMatch-inpaints the overlay's footprint from a ring of
 * valid pixels around it, then Poisson-blends the result in exactly as
 * rz_doc_heal_layer does, hard cut at the alpha = 128 contour and all — so a
 * soft tip heals a SMALLER footprint, never a fainter one. Only the overlay's
 * ALPHA is read (its RGB is ignored — there is no sampled source). ring is
 * the sampling-ring width in
 * px, 0 = automatic, clamped to [21, 512] (the floor is three patch widths,
 * the narrowest band a source patch can move in) and then widened from below
 * by the footprint's own size; seed makes the result reproducible; sample_all
 * inpaints from the flattened composite instead of layer idx's own pixels;
 * preview computes the WHOLE pipeline on a reduced copy (same structure,
 * softer texture) and is for a live preview only; its reduction is chosen
 * from the whole call, so a scattered footprint previews as cheaply as a
 * compact one. A pixel is a valid SOURCE when it is outside every part of
 * the footprint and its alpha is at least 128: alpha here answers only
 * whether there is colour, and the RGB beside it is straight, so a
 * semi-transparent layer or an 80 %-opaque composite samples fine. NULL with
 * *err_out set when the footprint, its sampling window or one region's box
 * exceeds a documented cap (the first two bound the whole CALL: every
 * separate part of the footprint counts towards them together), or when
 * there is nothing to sample from — every cap is measured BEFORE any pixel
 * is filled, so a refusal costs a fraction of a fill, and every message is
 * worded for the gesture that asked (a stroke is not told to select less).
 * NULL with *err_out NULL when nothing would change. Free with
 * rz_string_free. */
RzDocument *rz_doc_spot_heal_layer(const RzDocument *doc, size_t idx,
                                   const uint8_t *src, uint32_t w, uint32_t h,
                                   float strength, uint32_t ring,
                                   uint64_t seed, bool sample_all,
                                   bool preview, char **err_out);

/* Content-Aware Fill: PatchMatch-inpaints the region a canvas-sized u8
 * coverage mask marks (the same convention every selection uses), sampled
 * from a ring around it, then Poisson-blends the fill to the surrounding
 * illumination. The region is every pixel the mask touches at all (> 0, not
 * >= 128 — this is a selection, not a brush dab), and the mask's SOFT bytes
 * weight the write-back, so a feathered selection is filled and faded across
 * the whole of its ramp and nothing outside it moves. Disjoint parts of the mask
 * are filled independently, each from its own neighbourhood, so a scatter of
 * blemishes costs the sum of their own boxes and not one box around all of
 * them. ring/seed/sample_all/preview as rz_doc_spot_heal_layer, so ring is
 * likewise clamped to [21, 512]. The caps bound the WHOLE CALL: every
 * separate part of the mask counts towards them together. NULL with
 * *err_out set on a cap or a starved sample region; NULL with *err_out NULL
 * when nothing would change. Free *err_out with rz_string_free. */
RzDocument *rz_doc_content_aware_fill(const RzDocument *doc, size_t idx,
                                      const uint8_t *mask, uint32_t w,
                                      uint32_t h, uint32_t ring,
                                      uint64_t seed, bool sample_all,
                                      bool preview, char **err_out);

/* Removes flash red inside a canvas rect on layer idx. Inside the rect,
 * pixels are scored by red DOMINANCE — the ratio R/((G+B)/2) gated by HSV
 * saturation and hue, not a naive R > G, which every skin tone passes —
 * and a scoring component is corrected only when its larger side fits within
 * pupil_size times the rect's SHORTER side AND it does not reach all four
 * sides of the rect, so a red object caught by a sloppy rectangle is left
 * alone and a rect dropped wholly inside one red region is refused rather
 * than desaturated into a hard-edged square. pupil_size is a fraction in
 * (0, 1] and 1.0 is the intended default: it exists to reject something
 * bigger than the eye, not to require a small one — the four-sides rule is
 * what gives it teeth on a square rect, where a clipped component can never
 * be larger than the rect. Red drops to (G+B)/2 and the pixel darkens
 * by darken (0.5 = Photoshop's default); a specular catchlight scores zero
 * and comes out bit-identical. Layer alpha is never touched. NULL on an
 * empty or off-canvas rect, out-of-range idx, non-finite parameters, nothing
 * red at all, no component within the pupil-size limit, or when no pixel
 * would change. */
RzDocument *rz_doc_red_eye_layer(const RzDocument *doc, size_t idx,
                                 int32_t x, int32_t y, uint32_t w, uint32_t h,
                                 float pupil_size, float darken);

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

/* ------------------------------------------------------------------------ */
/* Adjustments (the ONE destructive twin), statistics and readout           */
/* ------------------------------------------------------------------------ */

/* Applies the adjustment `op` with `params_json` — the SAME object an
 * adjustment layer's meta carries (schema table in core/src/adjust.rs) — to
 * img's pixels, destructively. This is the identical code path the
 * compositor runs for an adjustment layer, so the filter and the layer can
 * never drift. The one deliberate difference: a SPATIAL op
 * (shadows_highlights) reads its neighbourhood from THIS image, while the
 * layer reads it from the backdrop below itself, so the two agree on the
 * same input and are different pictures on different inputs.
 *
 * An adjustment is a pure function of the numbers the document already
 * holds: its parameters live in the same space as those pixels, so a colour
 * in an adjustment's params is the DOCUMENT's numbers (like an eyedropper
 * sample), not an authored sRGB colour like a layer style's. Where an op
 * needs a colour space for its arithmetic it uses the sRGB transfer function
 * and sRGB primaries, and its schema row says so.
 *
 * params_json may be NULL for "every default". NULL with a message through
 * err_out (free with rz_string_free) when op is unknown, params_json is not
 * valid UTF-8/JSON/an object, or the parameters are not valid for op; NULL
 * with no message on a NULL image. Alpha untouched. */
RzImage *rz_image_adjust_op(const RzImage *img, const char *op,
                            const char *params_json, char **err_out);

/* Parses an Adobe Cube LUT (.cube) at `path` into the params object a
 * "color_lookup" adjustment stores: {"kind","size","source_size",
 * "domain_min","domain_max","table","title"} as a heap JSON string freed
 * with rz_string_free. 1D sizes 2..=65536 and 3D sizes 2..=64 are accepted;
 * a table larger than this build STORES (1D 1024, 3D 33) is resampled down
 * to that size. "source_size" is ALWAYS emitted and is the size the FILE
 * declared, so a caller can report "resampled from 64" — "size" is what is
 * stored. "title" is present only when the file carried a TITLE directive.
 * NULL with a message through err_out for a missing/oversized/malformed file
 * (the message names the path and what was wrong); never panics. */
char *rz_lut_parse_cube(const char *path, char **err_out);

/* Fills bins_out with 1024 counts — 256 red, then green, then blue, then
 * Rec. 709 luma — and total_out with the number of pixels counted. A pixel
 * counts when its alpha is non-zero and, when `mask` is given (a coverage
 * buffer of exactly width*height bytes), its coverage is >= 128. `stride`
 * counts every stride-th pixel in row-major order (0 and 1 both mean every
 * pixel) and total_out reports how many were actually counted, so the
 * proportions and the clipping counts stay comparable at any stride. A NULL
 * total_out is tolerated — the bins still come back — but a NULL bins_out is
 * not: false on that, or on a NULL image. */
bool rz_image_histogram(const RzImage *img, const uint8_t *mask,
                        uint32_t stride, uint32_t *bins_out,
                        uint64_t *total_out);

/* The straight RGBA at (x, y): the plain mean of the (2*reach+1) square
 * about it with out-of-bounds pixels dropped (reach 0, 1 or 2 = point, 3x3,
 * 5x5), truncating like the eyedropper it serves. Writes 4 bytes to
 * rgba_out. false only when NO pixel of the block is inside the image, reach
 * is above 2, or img/rgba_out is NULL — the CENTRE itself may be outside,
 * which is what the eyedropper does today. */
bool rz_image_sample(const RzImage *img, int32_t x, int32_t y, uint32_t reach,
                     uint8_t *rgba_out);

typedef enum {
  RZ_AUTO_TONE = 0,     /* per-channel stretch */
  RZ_AUTO_CONTRAST = 1, /* one stretch from the luma histogram */
  RZ_AUTO_COLOR = 2,    /* per-channel stretch + neutral-candidate midtones */
} RzAutoMode;

/* Derives Levels parameters from img's own histogram — the same counting
 * rule rz_image_histogram uses, so transparent pixels never move the black
 * point — clipping `clip` of the counted pixels at each end (0..=0.1;
 * 0.001 = Photoshop's 0.1%), and writes nine floats to params_out:
 * black[3], white[3], gamma[3]. `mask` is optional (NULL = the whole
 * image). false on a NULL image, an unknown mode, an out-of-range clip, an
 * empty image, or when the result would be the identity (nothing to do). */
bool rz_image_auto_levels(const RzImage *img, const uint8_t *mask,
                          RzAutoMode mode, float clip, float *params_out);

/* Levels with a black point, white point and gamma PER CHANNEL (three
 * floats each, R, G, B). Same math and the same validity condition as
 * rz_image_levels applied per channel: NULL unless every channel has
 * 0 <= black < white <= 1 and gamma in [0.1, 10]. Alpha untouched. */
RzImage *rz_image_levels_channels(const RzImage *img, const float *black,
                                  const float *white, const float *gamma);

/* CIE L*a*b* of one straight RGB triple of THIS document's pixels, through
 * the document's own profile, against the D50 PCS white — so the same bytes
 * read differently in an sRGB and a Display P3 document. Writes L, a, b to
 * lab_out. false on a NULL doc/out pointer or a profile this build cannot
 * model (a LUT profile), where the host must say so rather than assume
 * sRGB. */
bool rz_doc_lab(const RzDocument *doc, uint8_t r, uint8_t g, uint8_t b,
                float *lab_out);

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
 * A GROUP's mask is CANVAS-sized rather than layer-sized; see "Layer groups"
 * below for the whole rule, which every export in this section follows.
 *
 * A layer mask is a per-layer grayscale coverage channel gating the layer's
 * alpha while compositing: 0 hides, 255 shows, intermediate values are
 * partial coverage, multiplied on top of the layer's opacity. A mask is
 * always exactly the LAYER's pixel size (a GROUP's, which has no pixel
 * buffer, is the canvas's — the one exception) and it moves,
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
 * confined to the alpha footprint of the first unclipped SIBLING beneath it
 * — Photoshop clipping-mask semantics, "blend clipped layers as group". Clip
 * structure is purely POSITIONAL and re-derived at every composite, WITHIN
 * EACH LEVEL: any unclipped entry is a BASE, and its clip group is the
 * consecutive run of clipped siblings immediately above it, so reordering or
 * deleting entries needs no bookkeeping. A clipped entry at the BOTTOM of its
 * level (nothing unclipped below it there) has no base and composites as if
 * unclipped. A clip run never crosses a group boundary; a GROUP may be
 * clipped and may be a clip base, and either makes it composite as a unit
 * (see "Layer groups" below).
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
 * not parse as an adjustment (such a layer composites as plain raster), and
 * ALWAYS false on a GROUP: the core never interprets a group's metadata, so a
 * blob that happened to parse cannot turn a group into an adjustment. */
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
 * its enabled mask) — a GROUP may carry a style, whose shape is then its own
 * rendered projection, and an adjustment layer may not — and are rendered by
 * the projection only:
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

/* ---- Layer groups, locks, links and structure ---------------------------
 *
 * The layer stack is a FOREST, flattened. Every entry carries a KIND (raster
 * or group), a nesting DEPTH (0 at the top level) and — new with them — lock
 * flags, a link-group id and, for a group, a panel disclosure flag. A GROUP's
 * children are the entries immediately BELOW it at greater depth, and the
 * group's own record is the LAST record of its own subtree, so the array
 * stays bottom-first and children come before the group that holds them:
 *
 *     index 0  Layer 0   depth 0
 *     index 1  Layer A   depth 1   |
 *     index 2  Layer B   depth 1   |  children of Group 1
 *     index 3  Group 1   depth 0
 *
 * That is Photoshop's panel order read bottom-up and exactly how PSD stores
 * it. Every existing export still addresses an entry by its flat index, and
 * rz_doc_layer_count still counts ENTRIES, groups included. A group has no
 * pixels of its own: rz_doc_layer_image is NULL for one, every pixel writer
 * refuses one, and rz_doc_layer_offset_x/y/width/height answer the union of
 * its raster descendants' buffer rects instead of a pixel rect of its own.
 *
 * COMPOSITING. A group renders ISOLATED — its children into a private buffer
 * over their own extent, quantized once and composited as a single layer with
 * the group's opacity, blend mode, mask, style and clipped flag — when
 * anything about it needs its own RENDERED PIXELS or its own footprint: any
 * blend mode other than RZ_BLEND_PASS_THROUGH, a style, its own clipped flag,
 * or a VISIBLE clipped layer above it. A plain PASS-THROUGH group (the
 * default for a new group) allocates nothing: its children composite straight
 * onto the backdrop below the group, which is what lets an adjustment layer
 * inside a group reach the layers beneath it. Note the consequence, which is
 * Photoshop's too: CLIPPING any layer to a pass-through group makes that
 * group composite as a unit, and an adjustment layer inside it then stops
 * reaching the layers below the group.
 *
 * A pass-through group's own MASK and OPACITY do NOT isolate it: they GATE it
 * per pixel instead. Its children composite onto a copy of the real backdrop
 * and the result is mixed back by mask/255 * opacity, so an adjustment layer
 * inside a masked group is RESTRICTED to where the mask is white (and scaled
 * by the opacity) rather than switched off — "group the adjustment layers and
 * mask the group" works, and a reveal-all mask at opacity 1 is byte-identical
 * to no mask at all. Isolating for them would composite the adjustment
 * against a fresh transparent buffer, where an adjustment never touches a
 * pixel, and the effect would disappear entirely.
 *
 * Nesting is arbitrary up to ten levels; deeper is refused, and a projection's
 * group buffers are additionally capped so a crafted file cannot exhaust
 * memory (a group whose buffer would pass the cap simply contributes
 * nothing).
 *
 * CLIPPING is re-derived WITHIN a level: a clipped entry clips to the first
 * unclipped SIBLING below it, never across a group boundary, and a clipped
 * entry at the bottom of its level has no base and composites as if
 * unclipped — a GROUP there keeps passing through, since a flag the
 * compositor ignores never forces isolation either. So clipping a group to a
 * sibling that does not exist, or sending an already-clipped group to the
 * back of its level, changes no picture.
 *
 * A GROUP's MASK is CANVAS-sized, unlike a layer's, which is always its
 * layer's own size — a group has no pixel buffer to be the size of, and
 * Photoshop's group masks are canvas space too. rz_doc_adding_layer_mask
 * creates one at the canvas size for all three kinds,
 * rz_doc_painting_layer_mask validates against the canvas, and
 * rz_doc_removing_layer_mask with apply == true is REFUSED on a group (there
 * are no pixels to bake into). The whole-document geometry ops carry a group
 * mask the way they carry a channel: cut down by crop, padded by canvas
 * resize, resampled to the new canvas by resize. A group mask also TRAVELS
 * WITH ITS GROUP: rz_doc_move_layers and rz_doc_with_layer_offset slide it by
 * the move's delta and rz_doc_transform_layers warps it through the same
 * affine, so a masked group behaves identically whichever gesture moved it.
 * A TRANSLATE moves it as BOOKKEEPING — the group entry's own offset, which
 * has no other meaning on a group — and never as a resample, so a Move drag
 * that goes out and comes back, or two opposite arrow nudges, restore the
 * mask exactly rather than eating a band of it per step. The plane is
 * resampled once, by the next op that needs the mask as a canvas plane.
 *
 * LOCKS are a bitmask (RzLockFlags). Transparency freezes the layer's alpha
 * channel — a stroke changes colour but never coverage, and an eraser cannot
 * punch a hole. Pixels refuses every pixel edit but leaves the MASK editable,
 * as Photoshop does — except APPLYING one (RZ_EDIT_MASK_APPLY), which bakes
 * the coverage into the layer's alpha and so answers to Transparency too.
 * Position refuses offset changes, moves, transforms and
 * perspective; on a group it also consults every descendant's bit, because
 * moving a group moves them. All three set is "Lock All", which additionally
 * freezes the mask. A MERGE (RZ_EDIT_MERGE) answers to the DESTINATION
 * entry's Pixels and Transparency bits: it replaces that entry's whole
 * picture at a new extent. A TRANSFORM is a POSITION edit and never a Pixels one: it
 * resamples the whole buffer including its alpha, so a frozen alpha channel
 * has no meaning there, and a transparency-locked layer stays transformable
 * exactly as in Photoshop. Locks never block delete, duplicate, reorder,
 * group/ungroup, rename, opacity, blend mode, visibility or style.
 *
 * LINKS are a group id on each entry (0 = unlinked): every entry sharing a
 * non-zero id moves and transforms with the others. rz_doc_with_layer_offset
 * deliberately does NOT follow links — it is a property write, not a move;
 * rz_doc_move_layers and rz_doc_transform_layers do.
 *
 * Groups, locks, links and the disclosure flag round-trip through
 * rz_doc_save_native: they are what bumped the RZDC format to version 7. */

typedef enum {
  RZ_LAYER_RASTER = 0,
  RZ_LAYER_GROUP = 1,
} RzLayerKind;

/* A uint32_t bitmask. Bits 3..31 are reserved and are masked off wherever a
   value enters. */
typedef enum {
  RZ_LOCK_TRANSPARENCY = 1,
  RZ_LOCK_PIXELS = 2,
  RZ_LOCK_POSITION = 4,
  RZ_LOCK_ALL = 7,
} RzLockFlags;

typedef enum {
  RZ_EDIT_PIXELS = 0,
  RZ_EDIT_POSITION = 1,
  RZ_EDIT_MASK = 2,
  /* Applying a layer mask: a mask op that also bakes the coverage into the
     layer's ALPHA, so Lock Transparency refuses it as well as Lock All. */
  RZ_EDIT_MASK_APPLY = 3,
  /* A merge writing this entry: its whole picture is replaced, at a new
     extent. Lock Pixels and Lock Transparency both refuse it. */
  RZ_EDIT_MERGE = 4,
} RzEditKind;

typedef enum {
  RZ_ARRANGE_FRONT = 0,
  RZ_ARRANGE_FORWARD = 1,
  RZ_ARRANGE_BACKWARD = 2,
  RZ_ARRANGE_BACK = 3,
} RzArrange;

typedef enum {
  RZ_ALIGN_LEFT = 0,
  RZ_ALIGN_CENTER_X = 1,
  RZ_ALIGN_RIGHT = 2,
  RZ_ALIGN_TOP = 3,
  RZ_ALIGN_CENTER_Y = 4,
  RZ_ALIGN_BOTTOM = 5,
} RzAlign;

/* --- the entry model (getters and pure setters) --- */

/* True when entry idx is a GROUP; false on NULL doc, out-of-range idx or a
 * raster layer. */
bool rz_doc_layer_is_group(const RzDocument *doc, size_t idx);

/* The entry's nesting depth (0 at the top level); 0 on NULL doc or
 * out-of-range idx. */
uint32_t rz_doc_layer_depth(const RzDocument *doc, size_t idx);

/* The entry's subtree as the half-open range [*out_start, *out_end): the
 * entry itself for a raster layer, the whole group for a group. *out_end is
 * exactly where a new sibling inserted "above" this entry lands, which is
 * what rz_doc_adding_layer, rz_doc_adding_image_layer and
 * rz_doc_duplicating_layer do — so a host that must select what it just
 * created asks this rather than assuming idx + 1. Either out pointer may be
 * NULL. False (nothing written) on NULL doc or out-of-range idx. */
bool rz_doc_layer_subtree(const RzDocument *doc, size_t idx,
                          size_t *out_start, size_t *out_end);

/* The entry's lock flags (an RzLockFlags bitmask); 0 on NULL doc or
 * out-of-range idx. */
uint32_t rz_doc_layer_locks(const RzDocument *doc, size_t idx);

/* Pure setter: replaces the entry's lock flags, reserved bits masked off.
 * NULL on NULL doc or out-of-range idx. */
RzDocument *rz_doc_with_layer_locks(const RzDocument *doc, size_t idx,
                                    uint32_t locks);

/* Which of the entry's lock bits would block an edit of `kind` (0 = allowed)
 * — the query a host asks to phrase a refusal that NAMES the lock. The ops
 * refuse regardless, so a host that never asks cannot get through. 0 on NULL
 * doc, out-of-range idx or an unknown kind. */
uint32_t rz_doc_lock_block(const RzDocument *doc, size_t idx, RzEditKind kind);

/* The entry's link-group id (0 = unlinked); 0 on NULL doc or out-of-range
 * idx. */
uint32_t rz_doc_layer_link(const RzDocument *doc, size_t idx);

/* Whether GROUP idx is shown expanded in the layers panel; false on NULL doc
 * or out-of-range idx. Meaningless on a raster entry, which answers true. */
bool rz_doc_layer_open(const RzDocument *doc, size_t idx);

/* Pure setter: expands or collapses GROUP idx. NULL on NULL doc,
 * out-of-range idx or a raster entry. */
RzDocument *rz_doc_with_layer_open(const RzDocument *doc, size_t idx,
                                   bool open);

/* The entry's CONTENT bounds — the canvas box of its OPAQUE pixels with its
 * enabled mask applied, and for a group the union over its raster
 * descendants — written to out_xywh as x, y, width, height. This is the rect
 * rz_doc_align_layers and rz_doc_distribute_layers act on, and it is NOT the
 * pixel rect rz_doc_layer_offset_x/width report for a raster layer: a
 * photo-shaped layer on a canvas-sized buffer has two different rectangles.
 * Not clipped to the canvas, and blind to the visible flag (this says what
 * the entry HOLDS). False (nothing written) on NULL doc, out-of-range idx, or
 * an entry with nothing opaque in it. */
bool rz_doc_layer_bounds(const RzDocument *doc, size_t idx, int32_t *out_xywh);

/* --- structure --- */

/* Wraps the given entries — which must all share ONE parent — in a new group
 * named `name`, whose index comes back through out_group. The subtrees are
 * gathered in their existing relative order and the group is inserted so its
 * subtree occupies the TOPMOST given entry's slot; the gathered depths shift
 * by +1. The new group is Pass Through, opacity 1, visible, open, unclipped,
 * with no mask, style, locks or link.
 *
 * Two things the caller must be able to report come back alongside it, as NEW
 * indices, in the optional buffers out_cleared_clip and out_reordered (each
 * out_cap size_t entries; their true lengths always come back through
 * out_cleared_len / out_reordered_len, so a short buffer is detectable and a
 * buffer of rz_doc_layer_count entries can never truncate):
 *   - the BOTTOM-MOST grouped entry has its clipped flag CLEARED when it was
 *     set, since nothing inside the group is below it to clip to (Photoshop's
 *     behaviour; without it the entry would silently composite as if
 *     unclipped);
 *   - a NON-CONTIGUOUS set gathers the subtrees into the topmost given
 *     entry's slot, so entries left between them change their relative
 *     position (grouping {A, C} out of [A, B, C] leaves B below A).
 *
 * NULL on NULL doc or name, an empty / out-of-range / repeating index list,
 * entries that do not share one parent, and a nesting past ten levels. */
RzDocument *rz_doc_group_layers(const RzDocument *doc, const size_t *idx,
                                size_t len, const char *name,
                                size_t *out_group, size_t *out_cleared_clip,
                                size_t *out_cleared_len, size_t *out_reordered,
                                size_t *out_reordered_len, size_t out_cap);

/* Dissolves group idx: its children take its depth and its slot, in order,
 * and the group entry is removed. The group's own mask, style, opacity, blend
 * mode and clipped flag are DISCARDED — they cannot be expressed on the
 * children — so a caller that wants to report the loss must read them first.
 *
 * out_cleared_clip / out_cleared_len / out_cap are the same optional report
 * rz_doc_group_layers takes, and the mirror image of it: inside the group the
 * bottom-most child was at the BOTTOM of its level, so a clipped flag on it
 * was baseless and composited as unclipped; out at the parent level it could
 * land above an unclipped sibling and suddenly clip to it. An entry that was
 * baseless therefore STAYS baseless — the flag is cleared — and the entry's
 * NEW index comes back here so the caller can say so. At most one entry.
 *
 * NULL on NULL doc, out-of-range idx, a raster entry, or when the document
 * would be left with no entries at all. */
RzDocument *rz_doc_ungroup_layer(const RzDocument *doc, size_t idx,
                                 size_t *out_cleared_clip,
                                 size_t *out_cleared_len, size_t out_cap);

/* THE structural move: the entry at `from` and its whole subtree land at
 * index `to` — an index into the stack with that subtree already taken out,
 * exactly as rz_doc_moving_layer has always meant — at `depth`. This is how a
 * layer moves INTO or OUT OF a group.
 *
 * There is deliberately no "not into your own subtree" refusal: because `to`
 * numbers the stack with the subtree ALREADY removed, every value in range is
 * a legal insertion point and landing inside the moved block is impossible by
 * construction. A guard written in the PRE-drain numbering would refuse the
 * commonest panel drag — a group dropped one place up over a smaller sibling.
 * `to` past the end is clamped to the end.
 *
 * NULL on NULL doc, an out-of-range index, a depth past ten levels, any
 * (to, depth) pair whose result would be a malformed structure, and a move
 * that would leave the stack exactly as it is (the core's no-op rule, so a
 * drag that put an entry back where it started mints no undo step). */
RzDocument *rz_doc_move_layer_to(const RzDocument *doc, size_t from, size_t to,
                                 uint32_t depth);

/* Moves entry idx among its SIBLINGS only — never into or out of a group. To
 * change an entry's level use rz_doc_move_layer_to. NULL on NULL doc,
 * out-of-range idx, or when the entry is already there. */
RzDocument *rz_doc_arrange_layer(const RzDocument *doc, size_t idx,
                                 RzArrange how);

/* Links the given entries: they take the smallest unused non-zero link id, so
 * a save round trip is byte-identical. Unlink clears theirs, and an id left
 * with a single member is cleared too (a link group of one is not a link).
 * NULL on NULL doc or an empty / out-of-range / repeating index list, and
 * when nothing would change. */
RzDocument *rz_doc_link_layers(const RzDocument *doc, const size_t *idx,
                               size_t len);
RzDocument *rz_doc_unlink_layers(const RzDocument *doc, const size_t *idx,
                                 size_t len);

/* --- set operations ---
 *
 * Each takes an explicit index list and makes ONE document, never a sequence
 * of single-entry calls: every structural op renumbers, so a host loop would
 * address the wrong entries after the first step. The set is expanded by
 * SUBTREE and then by LINK GROUP, deduplicated; each call is all-or-nothing.
 * NULL on NULL doc, an empty / out-of-range / repeating list, a lock that
 * forbids the edit, and — the core's own rule — when nothing would change. */

/* Translates every given entry by (dx, dy). The ONE move-a-set op: the Move
 * tool, the arrow-key nudge and align/distribute all go through it. A GROUP
 * has no offset of its own — its raster descendants are in the expanded set
 * and move on their own — but its canvas-sized MASK slides by the same delta,
 * so a masked group drags exactly as it transforms. */
RzDocument *rz_doc_move_layers(const RzDocument *doc, const size_t *idx,
                               size_t len, int32_t dx, int32_t dy);

/* The same affine applied to every given entry, each deriving its own
 * destination extent. `affine` is six doubles, as in rz_doc_transform_layer. */
RzDocument *rz_doc_transform_layers(const RzDocument *doc, const size_t *idx,
                                    size_t len, const double *affine,
                                    RzResizeFilter sampler);

/* The same affine applied to the WHOLE stack — the Crop tool's straighten.
 * Per-entry POSITION locks do NOT gate it: straightening re-frames the
 * picture rather than moving a layer within it, which is why rz_doc_crop,
 * rz_doc_geometry, rz_doc_canvas_resize and rz_doc_resize do not consult a
 * layer lock either. NULL on NULL doc or affine, an unknown sampler, any
 * entry the transform itself refuses, and when nothing would change. */
RzDocument *rz_doc_straighten_layers(const RzDocument *doc,
                                     const double *affine,
                                     RzResizeFilter sampler);

/* Duplicates / removes every given entry (subtrees included). Removal runs
 * top-down internally and refuses only when it would empty the document. */
RzDocument *rz_doc_duplicate_layers(const RzDocument *doc, const size_t *idx,
                                    size_t len);
RzDocument *rz_doc_remove_layers(const RzDocument *doc, const size_t *idx,
                                 size_t len);

/* Merges the given entries — which must all share one parent — into ONE
 * raster entry at the lowest member's slot and depth, through the same kernel
 * as the projection, keeping the lowest member's name, visibility and clipped
 * flag. Masks, meta and styles are baked and dropped exactly as
 * rz_doc_merging_down documents. */
RzDocument *rz_doc_merge_layers(const RzDocument *doc, const size_t *idx,
                                size_t len);

/* Aligns every given entry's CONTENT bounds (rz_doc_layer_bounds) to `edge`
 * of the reference rect: the union of the given entries' bounds, or the
 * canvas with to_canvas. An entry with nothing opaque is skipped. NULL when
 * fewer than two entries have content and to_canvas is false. */
RzDocument *rz_doc_align_layers(const RzDocument *doc, const size_t *idx,
                                size_t len, RzAlign edge, bool to_canvas);

/* Spaces the given entries evenly along one axis: the two outermost keep
 * their positions and the gaps between adjacent CONTENT bounds are made equal
 * (Photoshop's "distribute spacing", not "distribute centers"). Needs at
 * least three entries with content; a negative gap is arithmetic, not an
 * error. */
RzDocument *rz_doc_distribute_layers(const RzDocument *doc, const size_t *idx,
                                     size_t len, bool vertical);

/* --- commands --- */

/* Replaces every entry that CONTRIBUTES to the projection — visible, with
 * every ancestor visible — with ONE canvas-sized raster entry holding the
 * visible projection, inserted at the slot of the bottom-most contributing
 * entry's top-level ancestor and named after that entry. Every entry that
 * does not contribute SURVIVES untouched, a visible layer inside a hidden
 * group included; a group survives if any descendant does. NULL on NULL doc
 * and when fewer than two LEAF entries contribute. */
RzDocument *rz_doc_merge_visible(const RzDocument *doc);

/* Adds the visible projection as a NEW canvas-sized raster entry immediately
 * above above_idx's subtree, at above_idx's depth. Nothing else changes. NULL
 * on NULL doc, out-of-range above_idx or NULL name. */
RzDocument *rz_doc_stamp_visible(const RzDocument *doc, size_t above_idx,
                                 const char *name);

/* Layer Via Copy / Via Cut: the source's pixels inside the canvas-sized
 * coverage mask (or the whole layer when mask is NULL) become a new raster
 * entry immediately above the source, same depth and same canvas position.
 * This op RASTERIZES: it keeps neither the layer's metadata nor its style, so
 * a host whose layer is a described one (text, shape) or an adjustment layer
 * wants rz_doc_duplicating_layer instead. With cut, the same coverage is
 * cleared from the source, under the source's locks. NULL on NULL doc or
 * name, out-of-range idx, a group, an adjustment layer, a mask that is not
 * canvas-sized, or a coverage that selects nothing inside the layer. */
RzDocument *rz_doc_layer_via(const RzDocument *doc, size_t idx,
                             const uint8_t *mask, uint32_t w, uint32_t h,
                             bool cut, const char *name);

/* The entry a click at canvas (x, y) activates — the TOPMOST one whose own
 * coverage there is at least half (the same contour a selection is cut at),
 * skipping invisible entries with their subtrees and skipping adjustment
 * layers. A group hits when any descendant hits. With top_level the answer is
 * the hit entry's top-level ancestor (Auto-Select: Group). False (nothing
 * written) on NULL doc or when nothing is hit — the caller then leaves its
 * selection alone rather than emptying it. */
bool rz_doc_layer_at(const RzDocument *doc, int32_t x, int32_t y,
                     bool top_level, size_t *out_idx);

/* ---- Guides, rulers and snapping ----------------------------------------
 *
 * A document carries a list of GUIDES and a RULER ORIGIN. A guide is one
 * line across the whole canvas: an orientation (horizontal = a line of
 * constant y, vertical = a line of constant x) and a position. The ruler
 * origin is the canvas coordinate of the ruler's zero point, (0, 0) — the
 * canvas's top-left — by default.
 *
 * POSITIONS ARE GRID-LINE COORDINATES in the continuous canvas space
 * [0, width] / [0, height], not pixel indices: a vertical guide at x = 0 lies
 * on the left canvas edge and one at x = width on the right, so BOTH extremes
 * are legal and the range is inclusive at both ends. The orientation names
 * the LINE, not the axis its position is measured on, so a vertical guide's
 * position is measured against the WIDTH. Positions are quantized to four
 * decimals, exactly like the resolution and the global light, so a value read
 * back and echoed in is refused as unchanged rather than registering an edit.
 * They are absolute canvas coordinates and are NOT measured from the ruler
 * origin — the origin moves the ruler's LABELS and nothing else.
 *
 * Every canvas-geometry op moves them the way it moves the pixels, and where
 * an op could either DROP a guide or CLAMP it the choice is deliberate:
 *   - the rotations and the flips PERMUTE (a quarter turn also exchanges each
 *     guide's orientation, because the line has turned with the picture);
 *   - rz_doc_crop and rz_doc_canvas_resize shift and then DROP whatever now
 *     lies outside the new canvas — a guide cut out of the picture would
 *     otherwise be invisible, unclickable and undeletable, and reappear from
 *     nowhere on a later Canvas Size (undo restores the whole document, so
 *     nothing is lost);
 *   - rz_doc_resize scales without rounding — a guide position is a
 *     continuous coordinate, and rounding it at every Image Size would
 *     accumulate — and nothing can leave the canvas under a scale;
 *   - rz_doc_flattening carries both verbatim; the per-layer ops leave them
 *     alone. A host-composed straighten (rz_doc_transform_layer over every
 *     layer plus rz_doc_crop) has NO guide op and needs none: a rotated guide
 *     is not a guide, so the trailing crop simply shifts and drops.
 * The RULER ORIGIN is CLAMPED where a guide is dropped: there is exactly one
 * origin and a document is never without one.
 *
 * At most rz_max_guides() guides (1024). They are written by
 * rz_doc_save_native — they are what bumped the RZDC format to version 8.
 *
 * WHAT THE CORE DOES NOT KNOW ABOUT. The ruler's UNIT, whether rulers, guides
 * or the grid are shown, the guide COLOUR, the guide LOCK, the grid's spacing
 * and subdivisions, the pixel grid, and every snapping toggle are all HOST
 * preferences: they describe how a user works rather than what the picture
 * contains, they are app-wide rather than per-document, and none of them is
 * in the file. In particular there is no per-guide lock byte and no
 * rz_doc_lock_guides — Lock Guides is one host-side boolean governing the
 * mouse. Snapping itself is entirely the host's: the core stores the lines
 * and answers where they are. */

typedef enum {
  RZ_GUIDE_HORIZONTAL = 0, /* a line of constant y */
  RZ_GUIDE_VERTICAL = 1,   /* a line of constant x */
} RzGuideOrientation;

/* The guide-count cap, 1024. No document and no pointers — and, unlike
 * rz_max_channels_at, no dimensions either: a guide is a line, not a plane,
 * so no canvas size makes fewer of them fit. It is exported rather than
 * hand-copied into a host because rz_doc_add_guide answers a single NULL for
 * four different refusals, and a host must be able to tell "the list is full"
 * apart from "that guide already exists". */
size_t rz_max_guides(void);

/* --- guide list (getters) ---
 * Per-index, with no bulk getter on purpose: a host caches the list once per
 * document change, so a canvas redraw makes no calls at all. */

size_t rz_doc_guide_count(const RzDocument *doc);

/* Guide i's STABLE IDENTITY: unique among every guide this process has
 * minted, and the handle a host hangs per-guide state on (which guide a drag
 * is moving). The list is re-SORTED by position on every edit, so an index
 * cannot identify a guide across one; the id survives a move, the geometry
 * ops and undo/redo, and a guide that is gone takes its id with it. NOT
 * persisted — rz_doc_open mints new ids, so the identity holds for as long as
 * a document is open, not across sessions. 0 on NULL doc / bad index, which
 * no live guide ever answers. */
uint64_t rz_doc_guide_id(const RzDocument *doc, size_t i);

/* An RzGuideOrientation; -1 on NULL doc / bad index (outside the enum). */
int rz_doc_guide_orientation(const RzDocument *doc, size_t i);

/* The canvas coordinate of the line. -1.0 on NULL doc / bad index: a legal
 * position is never negative, so the sentinel cannot collide with an answer. */
double rz_doc_guide_position(const RzDocument *doc, size_t i);

/* Writes the ruler origin as two doubles (x, y) into out_xy. false on a NULL
 * doc or a NULL buffer. */
bool rz_doc_ruler_origin(const RzDocument *doc, double *out_xy);

/* --- guide list (pure mutators; NULL = refusal, per the doc comments) --- */

/* Adds a guide. The list is kept sorted by (orientation, position), so the
 * new guide's INDEX is wherever it sorts, not the end. NULL on NULL doc, an
 * orientation outside RzGuideOrientation, a non-finite position, a position
 * outside [0, canvas extent], a position a guide of the same orientation
 * already occupies (adding a duplicate is not an edit), or a list already
 * holding rz_max_guides(). The four are deliberately one answer: a host that
 * needs to tell them apart checks the position and the count before calling,
 * which is also how it phrases the refusal in its own words. */
RzDocument *rz_doc_add_guide(const RzDocument *doc, int orientation,
                             double position);

/* Moves guide i along its own axis, keeping its identity and its orientation
 * (and re-sorting, so its index may change). NULL on NULL doc, a bad index, a
 * non-finite or out-of-canvas position, the position the guide already has,
 * or a position another guide of the same orientation already occupies. */
RzDocument *rz_doc_move_guide(const RzDocument *doc, size_t i, double position);

/* NULL on NULL doc or a bad index. */
RzDocument *rz_doc_remove_guide(const RzDocument *doc, size_t i);

/* NULL on NULL doc or an already empty list — clearing nothing is not an
 * edit, and an identical copy would register a phantom undo step. */
RzDocument *rz_doc_clear_guides(const RzDocument *doc);

/* Moves the ruler zero point to canvas (x, y). NULL on NULL doc, a non-finite
 * component, a point outside the canvas, or the origin the document already
 * has (after the four-decimal quantization). */
RzDocument *rz_doc_set_ruler_origin(const RzDocument *doc, double x, double y);

/* ---- Colour management and metadata -------------------------------------
 *
 * A document carries three more pieces of state: an ICC COLOUR PROFILE (the
 * space its pixel numbers belong to), the EXIF / XMP / IPTC PACKETS the file
 * it came from carried, and a print RESOLUTION in pixels per inch. Every
 * document op keeps all three; the profile, the packets and the resolution
 * are what bumped the RZDC format to version 6. The one op that does not
 * keep the resolution VERBATIM keeps it correct instead: a quarter turn
 * swaps the two ppi axes, because a 300 x 150 ppi picture turned 90 degrees
 * is a 150 x 300 ppi one. That holds for rz_doc_rotate90 and
 * rz_doc_rotate270, and for the camera rotation rz_doc_open bakes into the
 * pixels — the same turn, so the same swap.
 *
 * THE PROFILE IS NEVER ABSENT. A document with no embedded profile is
 * assumed sRGB — which is what every reader does anyway, and what lets the
 * display, the export and the transform share exactly one rule. So is a
 * document whose file carried a profile that is not RGB, or one larger than
 * the 16 MiB a document can carry (a PNG iCCP is zlib-compressed, so an
 * inflated profile is bounded by nothing else): the profile is dropped
 * rather than producing a document rz_doc_save_native would refuse to
 * write. A profile is also stored at its own DECLARED size, so trailing
 * padding is neither kept nor re-embedded. The library
 * writes its own conformant ICC v2.1.0 blobs for sRGB IEC61966-2.1 and
 * Display P3 (rz_builtin_profile), so an exported file always carries a
 * profile another application can read.
 *
 * WHAT THE LIBRARY CAN CONVERT WITH. ICC v2 and v4 RGB matrix/TRC profiles —
 * sRGB, Display P3, Adobe RGB (1998), ProPhoto, Rec. 2020 and the RGB
 * profiles a camera embeds. For such a profile the PCS white is ALWAYS D50
 * and the rXYZ/gXYZ/bXYZ tags are already D50-adapted; wtpt and chad are
 * advisory and are used for nothing (macOS's own sRGB Profile.icc has
 * D50-adapted columns, no chad at all and a wtpt holding the unadapted D65,
 * so a reader that trusts wtpt gets sRGB wrong). rz_icc_inspect classifies
 * raw bytes five ways, and each way means something different:
 *
 *   RZ_ICC_NOT_ICC            not a profile          — refused, never stored
 *   RZ_ICC_NOT_RGB            Gray / CMYK / Lab      — refused, never stored
 *   RZ_ICC_NOT_IMAGE_PROFILE  RGB numbers, but a     — refused, never stored:
 *                             device-link, abstract    it describes a
 *                             or named-colour class    transform or a colour
 *                                                      list, not the space a
 *                                                      picture's numbers live
 *                                                      in (macOS's own
 *                                                      WebSafeColors.icc),
 *                                                      and CoreGraphics
 *                                                      cannot convert out of
 *                                                      one
 *   RZ_ICC_RGB_UNCONVERTIBLE  RGB, but LUT-based     — KEPT as the document's
 *                                                      profile: pixels are
 *                                                      untouched, display is
 *                                                      correct and an export
 *                                                      re-embeds the original
 *                                                      bytes; only convert
 *                                                      refuses
 *   RZ_ICC_RGB_MATRIX         RGB matrix/TRC         — full function
 *
 * ASSIGN IS NOT CONVERT. rz_doc_assign_profile REINTERPRETS — the pixels are
 * untouched and the profile is replaced, so the numbers stay and the
 * appearance changes. rz_doc_convert_to_profile TRANSFORMS every layer's
 * pixels, so the appearance stays and the numbers change. Convert touches
 * layer pixels only: layer masks, alpha channels and layer metadata are
 * coverage and descriptions, not colour. Nor does it touch the colours
 * inside a LAYER STYLE or a text layer's metadata, and that is not a limit:
 * those are AUTHORED sRGB values — the same convention every #rrggbb this
 * library is handed follows — and they reach the document's space where they
 * are USED. A style's colours convert at composite time, so a style keeps
 * its appearance across a convert, the stored JSON is never rewritten and
 * the rendered-plane cache never has to be thrown away; a text layer's
 * convert when the host re-renders it. rz_doc_open never adopts a working
 * space — it reports what the file said, and the host calls
 * rz_doc_adopt_working_space exactly once.
 *
 * THE PACKETS ARE OPAQUE. EXIF, XMP and IPTC are stored verbatim and never
 * interpreted, exactly like a layer's metadata one level up, and are read
 * and re-spliced for JPEG AND PNG ONLY — the two containers this library can
 * also write into. (TIFF carries the profile alone; WebP carries the profile
 * and the EXIF packet; BMP and GIF carry nothing.) EXIF is the raw TIFF
 * stream with NO "Exif\0\0" prefix; XMP is
 * the UTF-8 packet with no identifier; IPTC is the whole 8BIM image-resource
 * run that follows "Photoshop 3.0\0", CONCATENATED across every APP13 that
 * carries one (Photoshop splits a run larger than one segment, and a reader
 * is meant to join them). A file whose ppi is stated twice is read from its
 * EXIF pair, which Exif/DCF makes the authority, with the container's own
 * density (the JFIF APP0, a PNG pHYs) as the fallback. A HEIC opened by the host contributes
 * its profile and dpi but no packets, and a PSD contributes none of the
 * three.
 *
 * TWO REWRITES HAPPEN ON EXPORT, both mandatory. (1) The EXIF block's IFD0
 * Orientation is set to 1, because the camera rotation was already baked
 * into the pixels at open time and a preserved 6 would double-rotate in
 * every viewer; its resolution and dimension tags are brought into line with
 * the document, and its next-IFD link is zeroed so the stale pre-edit
 * thumbnail is unreferenced. Every edit is in place — an ABSENT tag is never
 * inserted, because growing an IFD shifts every out-of-line datum and
 * silently corrupts MakerNotes — and a packet whose IFD0 or Exif sub-IFD
 * does not verify is dropped whole, as is one whose value offsets reach into
 * an entry table, where one rewrite would overwrite another. Nothing PAST them is read: the link to
 * IFD1 is cut anyway, so a dangling one (what a tool that strips a thumbnail
 * without rewriting the link leaves behind) costs the thumbnail rather than
 * every tag in the packet. (2) The 8BIM run loses resources 0x03ED (ResolutionInfo),
 * 0x040F (ICC), 0x0422 (Exif) and 0x0424 (XMP), which would contradict what
 * the save just wrote; every other resource survives byte-exactly. Both
 * happen on WRITE, so the stored packets stay byte-exact.
 *
 * A blob the format cannot carry, one too large for its segment, or an 8BIM
 * run that filters down to nothing is DROPPED AND REPORTED, never an error:
 * a save must not fail because a source file had a fat profile.
 * rz_format_carries answers what a format is able to carry;
 * rz_doc_save_image reports what was actually written. */

typedef enum {
  RZ_PROFILE_SRGB = 0,
  RZ_PROFILE_DISPLAY_P3 = 1,
} RzBuiltinProfile;

typedef enum {
  RZ_METADATA_EXIF = 0,
  RZ_METADATA_XMP = 1,
  RZ_METADATA_IPTC = 2,
} RzMetadataKind;

/* rz_icc_inspect classifications. */
#define RZ_ICC_NOT_ICC           0
#define RZ_ICC_NOT_RGB           1
#define RZ_ICC_RGB_UNCONVERTIBLE 2
#define RZ_ICC_RGB_MATRIX        3
#define RZ_ICC_NOT_IMAGE_PROFILE 4

/* rz_doc_adopt_working_space outcomes. */
#define RZ_ADOPT_UNCHANGED          0
#define RZ_ADOPT_CONVERTED          1
#define RZ_ADOPT_KEPT_UNCONVERTIBLE 2

/* rz_format_carries / rz_doc_save_image bits. */
#define RZ_CARRIES_PROFILE     1u
#define RZ_CARRIES_EXIF        2u
#define RZ_CARRIES_XMP         4u
#define RZ_CARRIES_IPTC        8u
#define RZ_CARRIES_RESOLUTION 16u

/* --- the built-in profiles this build writes --- */

/* Byte length of a built-in profile; 0 for a value outside
 * RzBuiltinProfile. The bytes are identical on every call and every run. */
size_t rz_builtin_profile_len(RzBuiltinProfile which);

/* Copies a built-in profile into `out`, which the caller declares to be
 * `len` bytes. The length is recomputed from the library's own and must
 * match exactly; false on a NULL buffer, a length that disagrees, or a value
 * outside RzBuiltinProfile. */
bool rz_builtin_profile(RzBuiltinProfile which, uint8_t *out, size_t len);

/* --- inspecting raw bytes, without a document --- */

/* Classifies `bytes` as one of the RZ_ICC_* values and, when `name_out` is
 * non-NULL, writes the profile's display name there as a heap string freed
 * with rz_string_free (NULL for RZ_ICC_NOT_ICC). Ask this before assigning
 * to learn WHY a profile would be refused. */
int rz_icc_inspect(const uint8_t *bytes, size_t len, char **name_out);

/* True when opening `path` would preserve whatever EXIF, XMP and IPTC the
 * file holds: a JPEG, a PNG or a native .rz. False for every other container
 * — a TIFF, WebP, GIF, BMP or PSD arrives as pixels and drops its capture
 * data, which such a file really can carry — for a file that cannot be read,
 * and for a NULL path. Ask it beside rz_doc_open, so a host can say the
 * capture data was never read in rather than implying the file had none. */
bool rz_path_metadata_walked(const char *path);

/* True when both buffers are matrix/TRC RGB profiles describing the SAME
 * colour space — the question rz_doc_convert_to_profile refuses on, asked
 * without a document so a host can disable a Convert command instead of
 * discovering the refusal as a bare NULL. Byte equality is NOT the same
 * question: the "sRGB IEC61966-2.1" blob most cameras and Photoshop embed is
 * 3144 bytes against this library's 2568, and the two describe one space.
 * False on a NULL pointer, on bytes that are not an RGB ICC profile, and on
 * a profile this library cannot model — those are other refusals, which
 * rz_icc_inspect names. */
bool rz_icc_describes_same_space(const uint8_t *a, size_t a_len,
                                 const uint8_t *b, size_t b_len);

/* --- the document's profile --- */

/* Byte length of the document's ICC profile; 0 on a NULL doc. Never 0 for a
 * live document — a document always has a profile. */
size_t rz_doc_icc_profile_len(const RzDocument *doc);

/* Copies the document's profile into `out`, which the caller declares to be
 * `len` bytes; false on a NULL doc, a NULL buffer, or a `len` that
 * disagrees with the library's own length. */
bool rz_doc_icc_profile(const RzDocument *doc, uint8_t *out, size_t len);

/* Heap copy of the profile's display name (free with rz_string_free); NULL
 * on a NULL doc. */
char *rz_doc_profile_name(const RzDocument *doc);

/* True when the document's profile is an RGB matrix/TRC one, i.e. when
 * rz_doc_convert_to_profile can convert FROM it. False on a NULL doc and for
 * a LUT-based profile, which is kept and re-embedded all the same. */
bool rz_doc_profile_is_convertible(const RzDocument *doc);

/* --- pure ops --- */

/* Reinterprets the document in the profile `bytes` describe: pixels
 * unchanged, profile replaced. NULL — a REFUSAL, not an error — on a NULL
 * doc, bytes that are not an RGB ICC profile, a payload over 16 MiB (the
 * RZDC writer's blob cap, enforced here so a document can never hold a
 * profile the format would refuse), or bytes identical to the current
 * profile. `bytes` NULL is NOT a clear: pass the sRGB built-in to reset. */
RzDocument *rz_doc_assign_profile(const RzDocument *doc, const uint8_t *bytes,
                                  size_t len);

/* Transforms every layer's pixels into the profile `bytes` describe and
 * replaces the profile. Refuses (NULL) everything rz_doc_assign_profile
 * refuses, plus a profile on either side that is not matrix/TRC and a target
 * equivalent to the document's current space. */
RzDocument *rz_doc_convert_to_profile(const RzDocument *doc,
                                      const uint8_t *bytes, size_t len);

/* Brings a freshly opened document into the host's working space, ONCE:
 * converts when the two differ, does nothing when they agree, and keeps the
 * document's own profile when it is one this library cannot convert from.
 * `outcome_out` (may be NULL) receives one of the RZ_ADOPT_* values and is
 * written EVEN WHEN the return is NULL, so a "nothing changed" adoption
 * still says which case it was. Skip this for a .rz document: it carries its
 * own profile. */
RzDocument *rz_doc_adopt_working_space(const RzDocument *doc,
                                       const uint8_t *bytes, size_t len,
                                       int *outcome_out);

/* --- metadata packets --- */

/* Byte length of one packet; 0 on a NULL doc, an absent packet, or a value
 * outside RzMetadataKind. */
size_t rz_doc_metadata_len(const RzDocument *doc, RzMetadataKind kind);

/* Copies one packet into `out`, which the caller declares to be `len`
 * bytes; false on a NULL doc, a NULL buffer, an absent packet, a value
 * outside RzMetadataKind, or a `len` that disagrees with the library's own
 * length. */
bool rz_doc_metadata(const RzDocument *doc, RzMetadataKind kind, uint8_t *out,
                     size_t len);

/* Stores one packet verbatim, or CLEARS it when `bytes` is NULL — a zero
 * `len` with a non-NULL pointer stores an EMPTY packet, which the format
 * distinguishes from an absent one. NULL on a NULL doc, a value outside
 * RzMetadataKind, a payload over 16 MiB, or a value the document already
 * carries. */
RzDocument *rz_doc_set_metadata(const RzDocument *doc, RzMetadataKind kind,
                                const uint8_t *bytes, size_t len);

/* --- resolution --- */

/* The document's print resolution in ppi; 0.0 on a NULL doc. */
float rz_doc_resolution_x(const RzDocument *doc);
float rz_doc_resolution_y(const RzDocument *doc);

/* Pure setter for the print resolution. NULL on a NULL doc, a non-finite or
 * non-positive component, or no change after sanitizing (clamped to
 * [1, 30000] and quantized to four decimals like the global light, so a
 * reported value echoed back is "no change"). PIXELS NEVER CHANGE: only the
 * print size does. */
RzDocument *rz_doc_set_resolution(const RzDocument *doc, float ppi_x,
                                  float ppi_y);

/* --- saving a flat file WITH the profile and the packets --- */

/* Which of the profile, the three packets and the resolution `format` is
 * able to carry, as RZ_CARRIES_* bits; 0 for a value outside RzFormat.
 *
 *   PNG   profile (iCCP), exif (eXIf), xmp (iTXt), resolution (pHYs)
 *   JPEG  profile (APP2 x n), exif (APP1), xmp (APP1), iptc (APP13),
 *         resolution (JFIF density, per axis)
 *   TIFF  profile
 *   WebP  profile, exif
 *   BMP, GIF   nothing
 *
 * The resolution column is the format's OWN density slot, and a save may
 * report RZ_CARRIES_RESOLUTION beyond it: a WebP has no such slot but states
 * the ppi inside the EXIF chunk it does write, so rz_doc_save_image reports
 * what the file ends up saying rather than what this table alone allows.
 *
 * Two known TIFF limits. (1) A TIFF written here carries its profile
 * correctly — the tag is there and ColorSync and littleCMS both read it —
 * but rz_doc_open does not recover it, because the decoder this library uses
 * never surfaces that tag, so a TIFF round-tripped through this application
 * comes back assuming sRGB. (2) The encoder exposes no resolution hook, so
 * every TIFF carries its crate's default of XResolution 1/1, YResolution 1/1
 * and ResolutionUnit 1 ("none"); applications that read that pair literally
 * show a 1 dpi image. The bit is clear because nothing in the file states
 * THIS document's ppi — but the file is not silent about resolution, and a
 * host's export notice should say so rather than imply the tags are
 * absent. */
uint32_t rz_format_carries(RzFormat format);

/* Encodes the document to `path` as a flat image, embedding its colour
 * profile (unless `embed_profile` is false) and its EXIF, XMP and IPTC
 * packets (unless `strip_metadata` is true), format permitting, plus its
 * print resolution wherever the format has somewhere to put one.
 * `strip_metadata` governs the three INHERITED packets only — the
 * document's own resolution and profile are its state, not something it
 * inherited from a file.
 *
 * `flat` MAY BE NULL, in which case the document is flattened here; when it
 * is non-NULL its pixels are what gets encoded and the document supplies
 * only the profile, the packets and the resolution. `flat` is a
 * caller-supplied composite of THIS document; passing an unrelated image is
 * a caller bug, and the canvas dimensions are not re-checked.
 *
 * `carried_out` (may be NULL) receives the RZ_CARRIES_* bits actually
 * written. Atomic like rz_image_save; errors as in rz_image_save. */
bool rz_doc_save_image(const RzDocument *doc, const RzImage *flat,
                       const char *path, RzFormat format, uint8_t jpeg_quality,
                       bool embed_profile, bool strip_metadata,
                       uint32_t *carried_out, char **err_out);

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
