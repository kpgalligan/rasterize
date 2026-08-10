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

/* ------------------------------------------------------------------------ */
/* Layered documents                                                         */
/* ------------------------------------------------------------------------ */

/* Opaque layered document: a canvas size plus an ordered stack of layers
 * (index 0 = BOTTOM). Every layer has straight-alpha RGBA8 pixels of its own
 * size, an integer canvas offset, a name, opacity, a blend mode, and a
 * visibility flag. Layer pixel buffers are immutable and shared between
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
 * produces can be read back: more than 1024 layers or a layer PNG over
 * 512 MiB is an error; layer names longer than 64 KiB are truncated on a
 * UTF-8 character boundary. Layout (little-endian): "RZDC", u32 version=1,
 * u32 canvas width, u32 canvas height, u32 layer count; then per layer
 * bottom-to-top: u32 name byte length + UTF-8 name, i32 offset x, i32
 * offset y, f32 opacity, u32 blend mode, u8 visible, u32 PNG byte length +
 * PNG-encoded RGBA8 layer pixels. */
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

/* Aspect-fit thumbnail of a layer, longest side == max_side (min 1). */
RzImage *rz_doc_layer_thumbnail(const RzDocument *doc, size_t idx,
                                uint32_t max_side);

/* Canvas-sized projection: visible layers composited bottom-to-top in f32,
 * straight-alpha result. Compositing follows the W3C model: with backdrop
 * (Cb, ab), source layer (Cs, as' = as * opacity) and blend function B:
 *   ao = as' + ab*(1-as')
 *   Co = ( as'*(1-ab)*Cs + as'*ab*B(Cb,Cs) + (1-as')*ab*Cb ) / ao   (ao > 0)
 * Invisible layers are skipped; areas a layer does not cover use Cb. */
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

/* Replaces a layer's pixels (any size; offset and properties kept). */
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
 * layer's name and visibility and covers the union of both layers' extents.
 * An invisible upper layer is simply removed. NULL if idx == 0 / out of
 * range, or if the LOWER layer is hidden (the merge would discard the upper
 * layer's content). */
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
 * Limits as rz_image_resize. */
RzDocument *rz_doc_resize(const RzDocument *doc, uint32_t w, uint32_t h,
                          RzResizeFilter filter);

/* Changes the canvas size WITHOUT scaling anything: the canvas becomes w*h
 * and every layer's offset shifts by (origin_x, origin_y) — where the old
 * canvas's top-left corner lands in the new canvas. Layer pixels are
 * untouched; content outside the new canvas is retained (as with
 * rz_doc_crop) and can be revealed later. NULL if w == 0, h == 0, or
 * w*h > 100000000. */
RzDocument *rz_doc_canvas_resize(const RzDocument *doc, uint32_t w,
                                 uint32_t h, int32_t origin_x,
                                 int32_t origin_y);

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
