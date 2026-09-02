# From Compositor to Photo Editor: a Gap Review

**Status: proposal (September 2026), nothing here has shipped.** A
fresh-eyes review of the shipped feature set against what a working
photographer actually reaches for in Photoshop, followed by a large, sized
catalog of what to build. Companion to `next-features.md` (whose open
follow-ons — layer groups, layer styles, the healing brush — reappear here
with concrete designs) and `high-leverage-roadmap.md`. The GIMP study
(`gimp-image-manipulation-capabilities.md`) is cited by section where its
mechanism notes apply.

Sizing used throughout: **S** a day or less · **M** a few days · **L** a
week or more · **XL** a model change that touches every op.

---

## 1. Where the app stands

What has shipped is a *compositing and painting* editor with unusually
good bones for its age:

- The layer model is right: `Arc`-shared pure ops, an f32 compositor, the
  complete 27-mode Photoshop blend set, masks, clipping groups, and an
  opaque `meta` slot that already carries three parametric layer types
  (text, shape, Live Photo) plus adjustment layers.
- Non-destructive adjustments chain in f32 on the accumulator, so five
  stacked adjustment layers do not quantize between steps. Only the
  destructive Filters-menu twins round to 8 bits.
- Selections are canvas-sized coverage masks with real algebra,
  feathering, Euclidean morphology, Quick Mask, and Vision subject
  segmentation. That representation is what makes channels (§4) cheap.
- Free Transform is a true homography pipeline resampling in premultiplied
  alpha; the brush engine has the full Photoshop tip set.
- The MCP catalog and the built-in assistant are a scripting API nobody
  else has.

Three findings that the README's feature list hides, in order of how much
they matter to a photographer:

1. **Color is not managed at all.** The core reads pixel bytes and drops
   the ICC profile; the save path writes none. An iPhone photo (Display
   P3) opens with its numbers reinterpreted as sRGB, so saturated reds and
   greens are wrong on screen and wrong in the export. EXIF and XMP are
   stripped on export; there is no DPI, so a print shop gets a 72-ppi file.
   This is invisible in the feature list and the first thing a photographer
   would notice as "the colours look off in Rasterize". §3A.
2. **Parametric layers cannot be transformed.** Free Transform on a text
   or shape layer asks to rasterize. Worse, the README's own known limit —
   document rotate/flip leave a text layer's description upright, so the
   next re-edit re-renders it at the wrong angle — is the same bug seen
   from the other side. One `transform` field on the payload fixes both.
   §2.2.
3. **The stack is a list, not a tree, and a layer has no styles.** No
   groups, no layer effects, no alpha channels, no lock. These are the
   features that make a 20-layer retouch manageable, and 20 layers is
   where adjustment layers and shape layers push every document.

Everything else is breadth — adjustments, brushes, filters, selection
tools — and breadth is cheap here because each new adjustment or filter
is one Rust variant that lands simultaneously as an adjustment layer, a
destructive twin, and an MCP tool.

---

## 2. The three requested features

### 2.1 Layer styles and blending options (drop shadow first)

Blend *modes* are done. What is missing is Photoshop's **Layer Style**
dialog, whose first pane is titled "Blending Options": the effect stack
(fx) and the per-layer compositing knobs beyond opacity and mode.

**Model.** A new core field, not more `meta`: the compositor must
interpret styles, and a text layer's `meta` is already spoken for.

```
Layer.style: Option<Arc<LayerStyle>>
LayerStyle {
  fill_opacity: f32,             // opacity of the pixels, not of the effects
  knockout: None|Shallow|Deep,   // punch through to the group base / bottom
  blend_if: Option<BlendIf>,     // channel, this-layer and underlying ranges,
                                 //   each a split-slider pair (lo0,lo1,hi0,hi1)
  effects: Vec<Effect>,          // in Photoshop's fixed render order
}
Effect = DropShadow{color, opacity, blend, angle, use_global_light, distance, spread, size}
       | InnerShadow{…same…}
       | OuterGlow{color|gradient, opacity, blend, spread, size}
       | InnerGlow{…, source: Edge|Center}
       | Stroke{size, position: Outside|Inside|Center, color|gradient, opacity, blend}
       | ColorOverlay{color, opacity, blend}
       | GradientOverlay{gradient, angle, scale, style, opacity, blend}
       | BevelEmboss{style, depth, direction, size, soften, angle, altitude, highlight, shadow}
       | Satin{color, blend, opacity, angle, distance, size}
RzDocument.global_light: (angle, altitude)
```

**Rendering.** Every effect is a function of the layer's *shape* — its
alpha times its enabled mask — and reuses primitives the core already has:

- Drop shadow / outer glow: dilate the shape by `spread` (the Euclidean
  distance transform behind Grow Selection), Gaussian-blur by `size` (the
  existing blur kernel), offset by `(distance, angle)`, colorize, and
  composite *below* the layer with the effect's own blend mode and
  opacity.
- Inner shadow / inner glow: the same on the inverted shape, clipped to
  the shape, composited *above* the pixels.
- Stroke: a band of the signed distance field, filled with a color or
  gradient. Outside strokes composite below the layer like a shadow,
  inside strokes above it.
- Color / gradient overlay: a fill clipped to the shape, above the
  pixels, at its own blend mode (this is how everyone recolors text).
- Bevel & Emboss: a normal from the gradient of the blurred shape, lit
  from `(angle, altitude)`, split into a highlight pass and a shadow pass.
- Blend If: a per-pixel weight from the source (or backdrop) channel value
  through the two split ramps, multiplied into source alpha before
  blending. Lands in `composite_layer_into` as a few lines. It is the
  photographer's tool for "this warm adjustment only in the highlights".
- Fill opacity: scales the pixels' alpha but not the effects'. A text
  layer at 0% fill with a stroke and drop shadow is outlined text — a
  five-minute test case that exercises the whole design.

Render order, as Photoshop fixes it: drop shadow, outer glow (below);
the pixels at fill opacity; then above them overlays, satin, inner glow,
inner shadow, bevel; strokes at their position. Effects render into the
clipping group's projection when the layer is a clip base, so a shadow
under a clipped texture falls once.

**Performance.** The blur and distance transform run at composite time,
so cache the rendered effect planes per layer keyed on
`(Arc::as_ptr(pixels), Arc::as_ptr(mask), style hash)` — the pure model
makes that key exact. During a live brush stroke on a styled layer,
composite the stroke overlay without re-running the effects; the commit
re-renders once. Effects scale with Free Transform (Photoshop's "Scale
Effects"): multiply distance/size/spread by the mean scale on commit.

**Surfaces.** Layer > Layer Style… opens one sheet with an effect checklist
down the left and a pane per effect, live-previewed through the normal
projection; Copy / Paste / Clear Layer Style; an "fx" badge with a
disclosure that lists effect rows (each with its own eye) under the layer
in the panel; `.rz` bump (shared with §2.3 — one bump); `set_layer_style`
(whole style, idempotent) and `get_document` reporting it over MCP; PSD
import of the `lfx2` block is a stretch goal, PSD export rasterizes the
effects into the layer with a note in the layer name. Size: **L** — the
largest single item in this document, and the one with the most visible
payoff.

### 2.2 Symbolic transforms on parametric layers

Give every `meta` payload a `transform: [a, b, c, d, tx, ty]` (an affine
in layer space; a homography can come later). Free Transform on a text,
shape, or Live Photo layer stops prompting to rasterize: the session's
final matrix composes into the payload and the layer **re-renders through
the transform** — CoreText glyph outlines and shape paths drawn under the
CTM, so a rotated headline has crisp vector edges and can be rotated back
losslessly. Move stays an offset change. Document-level rotate and flip
compose into the same field, which closes the README's "re-edits land
upright" limit for text and for Live Photo re-frames alike. The on-canvas
text editor can stay axis-aligned in a first cut (edit in an unrotated
overlay, commit re-renders rotated); a rotated editor is polish.

Size: **M**. Payload version 2 (older builds read those layers as plain
rasters, per the graceful-degradation rule), no `.rz` bump. Same-day
follow-ons on the text payload, each **S**: weight and italic traits,
tracking, leading, underline, fixed-width paragraph boxes vs point text.
Outline and shadow come from layer styles rather than from the text
payload, exactly as in Photoshop.

### 2.3 Channels: alpha channels and per-channel colour

The selection mask is already a canvas-sized u8 plane, and the GIMP study
(§6) is explicit that selection, mask, and channel should be one
representation. So:

**Model.** `RzDocument.channels: Vec<Channel { name, data: Arc<GrayImage>
(canvas-sized), overlay_color, overlay_opacity }>`. Save Selection writes
one; Load Selection reads one (with the add / subtract / intersect algebra
that exists); delete, duplicate, invert, rename. Quick Mask becomes a
temporary channel rather than its own buffer. `.rz` bump shared with §2.1.

**Panel.** A Channels tab beside Layers: RGB, Red, Green, Blue (extracted
from the composite), then the active layer's Transparency and Mask, then
the alpha channels. Viewing a single channel shows it in grayscale;
viewing an alpha channel over RGB draws it as a rubylith — the Quick Mask
overlay code, unchanged. ⌘-click any channel row **or any layer
thumbnail** loads it as a selection (Shift/Option/Shift+Option combine),
which is how Photoshop users have selected "this layer's pixels" for
thirty years and which the app cannot do today.

**Editing a single channel.** The paint `target` grows from `layer|mask`
to `layer|mask|red|green|blue|alpha|channel:<name>`: the stroke overlay's
luminance replaces that plane within its coverage. Filters and
adjustments on a single channel (blur the blue channel to kill chroma
noise, Curves already has per-channel) extract the plane, run the op,
re-insert.

**Channel arithmetic.** Apply Image and Calculations are one function —
`plane = blend(a, b, mode, opacity)` over two gray planes with the
existing blend table — and yield the photographer's luminosity masks
(Lights / Darks / Midtones and their intersections) for free.

**The distinctive part.** iPhone HEICs carry auxiliary images that ImageIO
exposes in one call each: the depth map, the portrait effects matte, and
the semantic mattes for skin, hair, teeth, glasses and sky. Open a portrait
and those arrive as named alpha channels. "Blur the background using the
depth map", "select the hair" and "warm the skin" become a ⌘-click plus an
adjustment layer. No desktop editor does this for iPhone photos without a
plugin; the Swift-side ImageIO decode path for HEIC is where it plugs in.

Size: **M** for the model, panel, and load/save; **S** each for
single-channel painting, Apply Image, and auxiliary mattes. MCP:
`save_selection`, `load_selection {from: channel|layer_alpha|layer_mask,
mode}`, `list_channels`, `target` on the paint tools, `render {channel}`.

---

## 3. The catalog

### 3A. Photo correctness — colour management, metadata, RAW

| Feature | Size | Notes |
|---|---|---|
| Read the embedded ICC profile and convert to the document space on open | M | `image` exposes decoder ICC bytes; convert with a pure-Rust CMS (`qcms` or `moxcms`). Document space is sRGB by default with an option to keep Display P3. GIMP §7: keep *assign* and *convert* as separate commands. |
| Tag the canvas with the document profile | S | Hand the display a CGImage in the document's `CGColorSpace` and the window server does the monitor transform. Correct on-screen colour on a P3 MacBook display for one line of Swift. |
| Embed the profile on export | S | PNG, JPEG, TIFF, WebP encoders take profile bytes. |
| Preserve EXIF / XMP / IPTC on export, orientation reset to 1 | M | Keep the raw metadata blobs from open and re-splice after encoding (the `img-parts` crate does this for JPEG/PNG/WebP). Export panel gets a "strip metadata" toggle. |
| Image resolution (ppi) and print size in Image Size; File > Print | S/M | `RzDocument` gains a ppi pair; the `.rz` bump carries it. |
| Camera RAW (CR3, NEF, ARW, DNG, ProRAW) via Core Image's `CIRAWFilter` | M | Swift-side decode, like HEIC today. A small "Develop" sheet before the pixels land — exposure, temperature/tint, noise reduction, lens correction — is the whole reason to own a RAW workflow. Highest photo value per day in this table. |
| HEIC export; AVIF and JPEG XL open/export | S/M | `image` has AVIF behind a feature flag; JXL via `jxl-oxide`. HEIC export through ImageIO on the Swift side. |
| Histogram panel with per-channel view and clipping warning | S | Levels and Curves want it too. A parallel scan with merged bins (GIMP §8). |
| Info panel: cursor position, RGB/HSB/Lab readout, selection bounds | S | Table over values the eyedropper already samples. |
| A per-document **linear-light compositing** toggle | M | Photoshop's "Blend RGB colors using gamma 1.0". Decode 8-bit sRGB to linear f32 on ingest (a 256-entry LUT), encode on output; storage stays 8-bit sRGB. Soft brushes and gradients stop turning muddy in the middle. Not the GIMP §3 three-axis system — one flag — and honestly optional. |
| 16-bit / half-float pixels | XL | Every op assumes `RgbaImage<u8>`. Defer; the f32 adjustment chain covers the banding case that matters most. |

### 3B. Adjustments — every row is one `Adjustment` variant

Each lands at once as an adjustment layer, a destructive Filters twin,
and an MCP op; each is **S** unless marked.

- **Exposure** (exposure, offset, gamma) — the RAW-style trio.
- **Vibrance** — saturation weighted toward unsaturated pixels, skin-safe.
- **Hue / Saturation** with per-range targeting — six hue bands each with
  hue, saturation, lightness, plus Colorize. The workhorse; **M**.
- **Color Balance** — shadows / midtones / highlights, preserve luminosity.
- **Black & White** — per-hue weights and a tint; the Grayscale op is the
  degenerate case.
- **Photo Filter** — warming/cooling, density, preserve luminosity.
- **Channel Mixer** — a 3×4 matrix with a monochrome mode.
- **Selective Color** — per-primary CMYK nudges; **M**.
- **Shadows / Highlights** — a local-contrast op (large-radius blur as
  the tone estimate); **M**.
- **White balance / Temperature-Tint** — Bradford-adapted, on any layer.
- **Gradient Map** — luma through a gradient; needs the multi-stop
  gradient editor from §3E.
- **Color Lookup (LUT)** — `.cube` parser plus trilinear interpolation.
  Film emulation packs become drag-and-drop presets.
- **Auto Tone / Auto Contrast / Auto Color** — the Levels op with
  histogram-derived parameters; menu items, not layers.
- **Match Color / Equalize** — later.

### 3C. Retouching

| Feature | Size | Mechanism |
|---|---|---|
| Healing brush and Spot Healing | L | Clone the source's *texture* while keeping the destination's illumination: Poisson-blend the difference field over the dab footprint (GIMP §9). Spot Healing picks the source automatically from a ring around the dab. The clone stamp's overlay path supplies everything but the solve. |
| Patch tool | M | Healing brush over a lasso'd region moved by a drag. |
| Content-Aware Fill | L | PatchMatch inpainting over the selection, sampled from a ring around it. The follow-on `next-features.md` already named; "remove the person" becomes one assistant call after `select_subject`. |
| Red-eye | S | Vision face landmarks locate the eyes; desaturate red within the pupil radius. |
| Smudge, Blur, Sharpen, Sponge brushes | M | Per-dab ops through the dodge/burn core-op path; smudge keeps a running accumulation buffer (GIMP §9). |
| Frequency separation helper | S | A menu command that builds the two-layer setup (blurred low, High Pass linear-light high) most retouchers set up by hand. |
| Liquify | L | Brush strokes accumulate into a displacement field; the layer is looked up through it at commit (GIMP §10's warp note). Forward warp, pucker, bloat, push, reconstruct. |

### 3D. Selection

- **Freehand lasso** (drag) and **magnetic lasso** (Dijkstra over an
  edge-cost map, GIMP §6) — the polygon lasso is the only lasso today. S / M.
- **Quick Selection brush** — region growing under a dab with edge
  awareness. M.
- **Color Range** — fuzziness around a sampled colour, or the
  highlights / midtones / shadows presets; produces a soft mask. S.
- **Refine Edge** — a guided filter on the coverage mask against the
  composite, with radius, smooth, feather, shift-edge and decontaminate.
  Turns Select Subject's mask into hair. M.
- **Transform Selection** — the Free Transform session on the mask alone
  (already deferred in Phase 4). M.
- **Select Subject: people instances** — `VNGeneratePersonInstanceMaskRequest`
  for up to four separated people. S.
- **Stroke Selection… / Fill Selection…** with the multi-stop gradient and
  pattern fills. S.
- **Reselect (⇧⌘D)**, **Load/Save Selection** (§2.3), **Select > Grow by
  colour** (the wand's global mode over the current selection). S.

### 3E. Paint and fill

- **Multi-stop gradient editor** with colour and opacity stops, plus the
  angle, reflected and diamond styles the options-bar comment already
  plans; **gradient presets**. M.
- **Pattern fill** (bucket, fill dialog, Pattern Overlay effect) from a
  pattern library and Define Pattern from Selection. M.
- **Custom brush tips** from a selection, scattering, dual brush,
  texture, colour dynamics; **Pencil** (aliased) and **Background Eraser**
  / **Magic Eraser** (the wand as an eraser). S each.
- **Colour swatches panel**, recent colours, HSB and Lab in the picker,
  `X` to swap and `D` to reset foreground/background, ⌥⌫ / ⌘⌫ fill with
  foreground/background. S.

### 3F. Layer structure and workflow

| Feature | Size | Notes |
|---|---|---|
| **Layer groups** with opacity, blend mode, mask, and pass-through | L | The compositor recurses: a group renders its children into a private projection and composites once (GIMP §4). The stack becomes a tree; `.rz`, the panel, MCP `get_document`, and PSD import all follow. Photoshop's Knockout and clipping to a group ride on it. |
| Lock: transparency, pixels, position, all | S | A flags field on `Layer`; the paint path honours transparency lock by multiplying stroke coverage by existing alpha. |
| Multi-select layers; transform, move, delete, group, merge them together | M | Free Transform over a set of layers is the same matrix applied per layer. |
| Link layers; Align and Distribute | S | |
| Layer Via Copy (⌘J) / Via Cut (⇧⌘J); Merge Visible; Stamp Visible (⇧⌥⌘E); Bring/Send arrange shortcuts | S | |
| Auto-Select with the Move tool (click a layer's pixels to activate it) | S | Hit-test alpha from the top down. |
| Layer colour labels, filter-by-kind, search | S | |
| Linked image layers | M | `{type:"image", path}` in `meta` — the Live Photo layer's mechanism generalized: place a file, keep it re-renderable at any transform, Replace Contents. Most of what people use Smart Objects for, without the subsystem. |
| Layer comps / snapshots | S | Named document handles; the pure model makes a snapshot one pointer. |
| History panel | S | A table over the undo stack that exists; raise `levelsOfUndo` from 24 with a byte budget and a step floor (GIMP §12). |

### 3G. Filters (and non-destructive filters)

New ops, **S** each unless marked: Unsharp Mask and Smart Sharpen (the
sharpen everyone actually uses; the current Sharpen has no radius),
High Pass, Motion Blur, Radial / Zoom Blur, Box and Lens Blur (M),
Surface / Bilateral Blur, Median and Reduce Noise (M), Vignette, Lens
Correction and Chromatic Aberration (M), Film Grain, Clouds / Render,
Offset, Dust & Scratches.

**Filter layers.** The adjustment-layer mechanism already applies an op
to the accumulated backdrop, so a *blur* or *sharpen* adjustment layer is
the same code path with an area op instead of a point op. With a mask it
is non-destructive selective blur — background blur under a subject
selection — without the live filter graph the earlier roadmaps rightly
deferred (GIMP §5). Cost is that the adjustment renders per composite;
cache it as §2.1 caches effects. **M** for the mechanism, then each
filter opts in.

### 3H. Geometry

- **Arbitrary canvas rotation** (Image > Rotate… by angle), and
  **auto-straighten** from `VNDetectHorizonRequest`. S.
- **Perspective Crop** — the crop box's corners become a quad; commit
  runs the existing homography. S.
- **Skew / Distort / Perspective / Warp** as named Free Transform
  submodes; the first three are the current ⌘-corner drag with
  constraints, warp is a 4×4 Bézier mesh resampled through the
  displacement-field machinery Liquify needs. S / L.
- **Content-Aware Scale** — seam carving with a protect mask. M.
- **Trim** (to transparent or to a corner colour) and **Reveal All**
  (canvas to the union of layer bounds). S.
- **Guides, rulers, grid, and snapping** — every tool's drag snaps to
  guides, canvas edges, layer bounds and selection bounds; Smart Guides
  when moving. M, and the single most-missed piece of chrome.

### 3I. Files, export and sharing

- **PSD export** with layers, masks, blend modes (a 1:1 table), opacity,
  clipping, groups; text and shapes rasterized with their payload kept in
  a private XMP block so a re-import restores them. L, and the feature
  that lets a Rasterize document go to a collaborator on Photoshop.
- **Export for Web** — resize, format, quality, and *file size* preview
  side by side, with a metadata toggle; **Quick Export as PNG**. M.
- **Export Layers to Files**, contact sheet, **batch export** of a folder
  through an action (§3J). S once actions exist.
- **PDF and SVG import** (rasterize at a chosen size), PDF export. S.
- **Drag a layer out** of the canvas as a PNG; the macOS Share menu. S.
- **Multi-frame GIF and multi-page TIFF** as layers rather than first
  frame only; animated export from layers as frames. M.
- **Autosave and version browsing** on `.rz` via `NSDocument`'s standard
  machinery, which the app already sits on. S.

### 3J. Automation — the distinctive one

The MCP catalog is already a complete scripting surface, and the
assistant already drives it. **Actions** are recorded tool-call sequences:
turn on Record, work normally, and every UI edit that has an MCP twin
(all of them, by the parity rule in `app/CLAUDE.md`) is appended as a
call; stop, name it, replay it on the current document or on a folder
(File > Batch…). Parameters that reference the current document —
selection, active layer, canvas size — are captured symbolically. The
assistant can author an action from a sentence and the user can edit it
as JSON. **M**, and unlike every other item here it compounds with each
new tool that ships.

Two smaller ones in the same spirit: **Filters > Repeat Last (⌃F)** and
a **command palette** (⌘K-style fuzzy search over the whole menu).

---

## 4. Suggested order

1. **Layer styles and blending options** (§2.1) — the request, the most
   visible payoff, and it forces the effect cache that §3G reuses.
2. **Symbolic transforms** on text, shape and Live Photo layers (§2.2),
   with the text typography follow-ons — small, and it deletes a known
   limit.
3. **Channels** (§2.3) with ⌘-click-to-select, luminosity masks, and the
   iPhone auxiliary mattes — one `.rz` bump shared with step 1.
4. **Colour management and metadata** (§3A, first five rows) — silent
   correctness. Do it before more people export photos from the app.
5. **The adjustment batch** (§3B) plus the histogram and info panels —
   two weeks of S items that make the Adjustments menu look like a photo
   editor's.
6. **Healing brush and Content-Aware Fill** (§3C) — the retouching gap.
7. **Groups, lock, multi-select** (§3F) and **guides / rulers / snapping**
   (§3H) — the workflow layer that 20-layer documents demand.
8. **RAW develop** (§3A) and **Actions** (§3J) — the two features that
   would make this app a reason to leave Photoshop rather than a
   replacement for it.

Everything after that is breadth, and breadth here is one variant at a
time.

## 5. Cross-cutting

- **One `.rz` bump** carries layer styles, channels, ppi, groups when they
  land, and the linear-light flag — reserve the fields now even where
  nothing writes them, exactly as the earlier roadmap did for `meta`.
- **Per-layer render caches** (effects, filter layers) are keyed on `Arc`
  pointer identity plus a parameter hash; the pure model makes that
  exact, and it is the only reason composite-time effects stay fast on a
  100 MP canvas.
- **Every item ships three surfaces** — UI, MCP tool with a catalog entry
  naming the UI path it mirrors, and `.rz` where state persists — plus
  core tests and README, per the standard recipe in `CLAUDE.md`.
- **Still deferred, and still rightly:** 16-bit storage, a tiled render
  graph, a Bézier path subsystem, CMYK, and full three-axis blend and
  composite spaces. The linear-light toggle in §3A is the one deliberate,
  bounded step toward the last of those.
