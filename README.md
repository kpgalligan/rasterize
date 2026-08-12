# Rasterize

A native macOS raster image editor. Swift/AppKit UI with a Rust core for image
decoding, encoding, and manipulation.

## Features

- **Layers**: full layer stack with per-layer opacity, visibility, offsets,
  and the full 27-mode Photoshop blend set — the separable W3C modes plus
  Dissolve, Vivid/Linear/Pin Light, Hard Mix, Divide, Darker/Lighter Color,
  and the non-separable Hue/Saturation/Color/Luminosity — grouped in the
  panel exactly like Photoshop's menu;
  layers panel with thumbnails, inline rename, drag-reorder, a right-click
  row menu (Rename, Delete Layer), and
  new/delete/duplicate/merge-down/flatten; Move tool (V) with arrow-key
  nudges; Paste as New Layer; PSD files import with their real layers; the
  native `.rz` format saves the full layer stack — masks, clipping flags,
  and text and adjustment descriptions included — losslessly, and older
  `.rz` files still load
- **Layer masks**: a grayscale coverage mask per layer that hides pixels
  without erasing them — Layer > Mask adds one revealing all, hiding all, or
  built from the current selection, then enables/disables it (a disabled mask
  is kept but ignored, to compare with and without), applies it (bakes the
  coverage into the layer's alpha) or deletes it (the layer comes back
  whole); a masked layer grows a second thumbnail beside its own in the
  layers panel — click either to aim the brush and eraser, which paint the
  mask white to reveal and black to hide. A mask is the layer's size and
  moves, rotates, crops and scales with it
- **Adjustment layers**: non-destructive color adjustments that live in the
  layer stack and recolor everything below them at composite time, their
  parameters editable forever. Layer > New Adjustment Layer offers nine ops
  — Brightness/Contrast/Saturation, Levels, Curves (an interactive spline
  editor: click the curve to add up to 16 control points per channel, drag
  to move them, with a channel popup switching between the master RGB curve
  and Red/Green/Blue individually), Hue Rotate, Posterize, Threshold,
  Invert, Grayscale, and Sepia. The parameterized ops open live-preview
  dialogs and re-open any time via Layer > Adjustment Options… or a
  double-click on the layer's row in the panel (which badges adjustment
  layers "◐"). Every adjustment layer is created with a layer mask gating where
  the adjustment applies — built from the selection when one exists, else
  revealing all — and brush and eraser strokes on the layer paint that mask
  automatically. Because it is just a layer, opacity, blend mode and
  clipping all apply; where an op has a destructive Filters-menu twin the
  math mirrors it, so the only difference is reversibility
- **Clipping masks** (Layer > Create Clipping Mask, ⌥⌘G): confine a layer
  to the alpha footprint of the first unclipped layer beneath it —
  Photoshop group semantics, so the base's blend mode and opacity apply to
  the group as one unit, consecutive clipped layers all ride the same base,
  hiding the base hides its group, and reordering simply re-derives the
  groups. The layers panel indents a clipped layer behind a "↳" arrow;
  releasing (the same menu item, retitled) undoes it, pixels untouched
  either way
- Open PNG, JPEG, Photoshop (PSD, layered), TIFF, BMP, GIF, WebP
  — EXIF orientation is applied on open, so camera photos display upright
- Export a copy to PNG, JPEG (with quality control), TIFF, BMP, GIF, WebP;
  failed saves never truncate or delete an existing destination file
- Smooth zoom (pinch, ⌘+/⌘-, fit, actual size) and pan
- Rotate 90°/180°, flip horizontal/vertical
- **Free Transform** (Layer > Free Transform, ⌘T): rotate, scale and move the
  active layer in one session — drag the eight handles to scale (Shift keeps
  the proportions, Option grows about the pivot), drag just outside a corner to
  rotate (Shift snaps to 15°), drag inside to move, arrow keys nudge; Return or
  a double-click commits, Escape cancels. The options bar shows editable
  Angle / Scale X / Scale Y and W / H — the layer's own scaled pixel size,
  bound to the matrix both ways, so typing a width sets the scale (keeping
  a mirrored layer mirrored) — plus the resampling filter
  (nearest, bilinear, bicubic by default, or Lanczos). The drag is a live
  preview and the whole session commits as **one undo step** — the layer is
  resampled exactly once, in premultiplied alpha so rotated edges stay clean
  instead of fringing dark. A layer mask transforms with its layer, and whole-
  pixel moves and mirrors copy pixels losslessly. Text layers ask to rasterize
  first (as any destructive edit does). Selections are not transformable yet —
  a session always transforms the whole layer and hides the marquee while it
  runs
- **Crop** (Image > Crop, ⌘K): the canvas shrinks to the selection's
  bounds and layers keep their pixels outside it, ready to be revealed
  again. Available only while the selection covers less than the whole
  image — anything else would be a no-op
- Image Size (scale with filter choice, up to 100 MP),
  and Canvas Size with the Photoshop-style 3×3 anchor selector — grow or
  trim the canvas without scaling; layers keep their pixels and can be
  revealed again later
- Brightness / contrast / saturation, Levels, Hue Rotate, Threshold, and
  Posterize adjustments with live in-context preview on the active layer —
  the destructive Filters-menu twins of the adjustment layers above
- Grayscale, invert, sepia, Gaussian blur, sharpen, Pixelate, Add Noise,
  Edge Detect, Emboss
- Selections beyond the rectangle: ellipse marquee (O), polygonal lasso
  (L — click vertices, double-click/Return/click-the-start closes, Escape
  cancels), and a magic wand (W) with tolerance + contiguous options that
  samples the flattened composite; combine selections with Shift (add),
  Option (subtract), or Shift+Option (intersect), invert (⇧⌘I), soften
  them with Select > Feather Selection…, reshape them with Grow, Shrink,
  Border, and Smooth Selection… — true Euclidean-distance morphology at
  the selection's 50% contour, so a moved edge comes back freshly
  anti-aliased instead of jagged — or paint them directly in Quick Mask
  mode (Q — the selection becomes a red rubylith overlay the brush adds
  to and the eraser removes from; toggling back out converts the buffer
  into the selection, and an empty one deselects), and the marching ants
  trace the true selection contour — disjoint pieces and holes each get their own
  dashed loop; selections confine brush, eraser, fill, and gradient, dim
  the outside, and define Crop. Delete (Edit > Clear, ⌫) clears the
  selected region of the active layer to transparency in one undo step,
  and does it proportionally where coverage is partial — a feathered
  selection leaves a soft-edged hole, not a hard one (text layers ask to
  rasterize first, as any destructive edit does)
- Fill tool (K): bucket flood fill on the active layer with tolerance,
  and a Gradient tool (G): drag to paint linear or radial two-color
  gradients (default fades the paint color to transparent), both
  selection-aware
- Eyedropper (I): picks the color under the cursor into the shared paint
  color, sampled from the flattened composite — what you actually see, not
  one layer — with a swatch and monospaced hex + RGBA readout in the
  options bar; a drag keeps sampling, and Option-click borrows the
  eyedropper mid-tool from brush, fill, and gradient
- Brush and eraser (size, opacity, color; `[`/`]` resize; 1 px pixel-snapped
  mode; strokes confine to an active selection) and on-canvas text
  (font/size/color and left/center/right alignment, ⌘Return commits,
  Escape cancels) — tools switch via toolbar, Tools menu, or
  M/O/L/W/V/B/E/K/G/T/I. Related tools share one toolbar button: the four
  selection tools sit on one, brush and eraser on another, each showing
  whichever member is current with a chevron on its right that drops a menu
  of the rest (with their keys). A group remembers the member last used
- **Re-editable text layers**: committing text adds its own layer that
  remembers the string, font, size, color and alignment it was rendered
  from — click it again with the text tool to reopen the editor pre-filled,
  with its font/size/color/alignment restored into the options bar, and the
  layers panel badges it with a "T". Double-clicking the layer's row in the
  panel reopens it the same way from anywhere: it switches to the text tool
  and selects the whole string, so typing replaces it. A destructive edit (filter, adjustment, fill, gradient,
  brush, eraser) asks "Rasterize text layer?" first and drops the
  description on confirm, keeping the pixels. The native `.rz` format stores
  the description alongside the pixels, so text stays editable across
  save and open
- Full undo/redo, copy to clipboard, recent files
- Drag image files onto a window to open them; File > New from Clipboard (⌘N)
- Checkerboard backdrop for transparency

Known limits: PSD support is 8-bit RGB/grayscale (16-bit and CMYK files are
rejected with a clear error), and PSD layer masks and clipping flags do not
import; animated GIFs and multi-page TIFFs
load their first frame/page only, so ⌘S on a GIF deliberately routes through
Save As instead of overwriting the animation in place. Document-level rotate,
flip and resize move a text layer's pixels but keep its description, so
re-editing the text after one re-renders it upright at the layer's corner.

## Built-in assistant

The Assistant tab of the right panel (View > Assistant, ⌃⌘A) is a chat
agent built into the app: it edits the window's document by calling the
same tools the MCP server exposes, sees the canvas by rendering it, and
verifies its own work. The agent loop lives in the Rust core
(`core/src/assistant.rs`): a tool-use loop over the Anthropic Messages
API (non-streaming v1; `api_base` is the provider seam), with per-turn
events driving the panel UI, cancellation at tool/API boundaries, and
automatic pruning of older canvas renders from the conversation so
history stays small. Every assistant edit is a normal undo step.

Bring your own API key: the panel asks once and stores it in the
keychain (launching with `ANTHROPIC_API_KEY` set also works). The model
defaults to `claude-sonnet-5`; override with
`defaults write com.kgalligan.Rasterize AssistantModel <model-id>`.

## AI agent access (MCP)

Tools > Allow Agent Connections hosts an MCP server (streamable HTTP) inside
the app at `http://127.0.0.1:4816/mcp` (`RZ_AGENT_PORT` overrides; falls back
to an ephemeral port). Any MCP client can drive the editor — 43 tools cover
opening documents, inspecting and rendering the canvas (the agent *sees* the
image as PNG, and `sample_color` reads single pixels off the flattened
composite — the eyedropper), layer operations, blend modes, layer masks (add
revealing, hiding or from the selection; enable, apply, or delete), clipping
masks (`set_layer_clipped` confines a layer to the alpha of the first
unclipped layer below it; `get_document` reports the flag), non-destructive
adjustment layers (`add_adjustment_layer` / `edit_adjustment_layer` over all
nine ops with the same mask-on-creation rule as the UI's; `get_document`
reports each one's op and params), filters, geometry —
including `transform_layer`, the Free Transform pipeline with named parameters
(rotate in degrees, positive is clockwise; scale, translate, pivot, sampler),
reporting the layer's new bounds — brush and eraser strokes (polyline points
with size/color/opacity, and a
`target` choosing the layer's pixels or its mask), text — `add_text_layer`
and `edit_text_layer` for re-editable text layers with an `alignment`
parameter (`get_document` reports each layer's text parameters) and
`add_text` for the rasterizing variant —
selections (rect/ellipse/polygon/magic wand with add/subtract/intersect
modes, plus `modify_selection`'s invert, feather, grow, shrink, border, and
smooth — shared with the UI and
honored by every paint tool), `clear_selection` to clear the window's
current selection on a layer (partial coverage clears proportionally),
bucket fill, gradients,
undo/redo, and exporting. Agent edits run on the main thread through the same edit path
as the UI: each tool call is one undo step, marks the document edited, and
updates the open window live. With [goose](https://github.com/aaif-goose/goose):

```sh
goose session --with-streamable-http-extension "http://127.0.0.1:4816/mcp"
```

The protocol layer lives in the Rust core (`core/src/agent.rs`, tools-only,
stateless, single JSON responses); the Swift side registers the tool catalog
and executes calls against the live documents (`app/Sources/AgentServer.swift`).
The endpoint is unauthenticated and off by default — any local process can
connect while it is enabled.

## Design

The UI takes its structure from the Balopy design handoff in
`designs/design_handoff_rasterize_desktop` — sticker-shadow pill controls,
an IBM Plex Mono voice for machine numbers, the welcome window and overlap
motif — but the chrome uses the standard semantic system colors
(`windowBackgroundColor`, `labelColor`, the user's accent color, …) so it
stays neutral around the image and follows light/dark automatically. The
brand palette survives only in the app icon, the welcome motif, and the
coral selection marquee. Fonts (Source Sans 3, IBM Plex Mono, Darker
Grotesque — all OFL) are vendored in `app/Resources/Fonts` and registered
via `ATSApplicationFontsPath`. Launching with nothing open shows the
welcome window instead of a bare open panel.

## Layout

```
core/           Rust crate (staticlib) — all pixel work happens here
  include/      Hand-maintained C header: the FFI contract
app/
  Sources/      Swift AppKit application (programmatic UI, no storyboards)
  Bridging/     Bridging header importing the Rust FFI header
project.yml     xcodegen definition — source of truth for the Xcode project
Makefile        Build orchestration
```

## Building

Requires Xcode, Rust (cargo), and [xcodegen](https://github.com/yonaskolb/XcodeGen).

```sh
make app        # cargo build + xcodegen + xcodebuild → build/Build/Products/Release/Rasterize.app
make run        # build and launch
make test       # Rust core tests
make typecheck  # fast swiftc -typecheck of the app sources
```

`Rasterize.xcodeproj` is generated — run `xcodegen generate` (or `make project`)
after editing `project.yml`, and don't commit the project file.

## Architecture notes

- The FFI surface (`core/include/rasterize_core.h`) is an opaque `RzImage`
  handle holding non-premultiplied RGBA8. All operations are pure — they
  return a new image and never mutate the input — which makes undo/redo a
  simple stack of handles (bounded by `NSUndoManager.levelsOfUndo`).
- Swift wraps the handle in a `RasterImage` class whose `deinit` frees the
  Rust allocation; error strings cross the boundary as malloc'd C strings
  released with `rz_string_free`.
- PSD files are detected by their `8BPS` signature and decoded with the `psd`
  crate (layered import, falling back to the flattened composite when a
  file's layers cannot be decoded); everything else goes through the `image`
  crate.
