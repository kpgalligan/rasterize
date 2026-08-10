# How GIMP Manipulates Images

*An architecture study of GIMP's image-manipulation capabilities and the mechanisms behind them, with implementation notes for anyone building similar features. Grounded in the GIMP 3.3 development source tree (August 2026); all mechanisms are described in prose — no code is reproduced.*

**At a glance:** 65 layer modes · 49 interactive tools · ~130 filters in menus · 18 precision configurations · 803 scriptable procedures · 60+ file formats

## Contents

1. [The architecture in one idea](#1-the-architecture-in-one-idea)
2. [The image data model](#2-the-image-data-model)
3. [Layer compositing](#3-layer-compositing)
4. [Rendering: the projection](#4-rendering-the-projection)
5. [Non-destructive editing](#5-non-destructive-editing)
6. [Selections, channels, and masks](#6-selections-channels-and-masks)
7. [Color management](#7-color-management)
8. [Filters and adjustments](#8-filters-and-adjustments)
9. [The paint engine](#9-the-paint-engine)
10. [Transforms and deformation](#10-transforms-and-deformation)
11. [Text and vector paths](#11-text-and-vector-paths)
12. [Undo and history](#12-undo-and-history)
13. [Performance machinery](#13-performance-machinery)
14. [Extensibility and file formats](#14-extensibility-and-file-formats)

---

## 1. The architecture in one idea

GIMP delegates all pixel work to two libraries: **GEGL**, a graph-based image-processing engine whose buffers are sparse, tiled, copy-on-write, and disk-swappable; and **babl**, a pixel-format conversion engine in which a format is a first-class runtime object carrying component types, transfer curves, and colorimetry. GIMP itself contains almost no pixel loops. What it contains is a *document model* — and the central design decision is that the document model and the render graph are the same thing.

Every layer, channel, mask, and non-destructive filter in an open image *is* a node in a live GEGL graph. In the class hierarchy, the drawable item types literally inherit from a "filter" base class that owns a graph node. There is no "render the document" pass that walks a scene description and produces pixels: the document is permanently wired into a graph, and rendering means asking that graph for tiles. Adding a layer splices a node in; toggling visibility splices it out; reordering filters is link surgery on the graph. Everything else in this document — compositing, non-destructive editing, previews, even how plug-ins see the image — follows from that one commitment.

> **Implementation notes**
>
> - Decide early whether your document model *is* the render graph or merely compiles into one. GIMP's fused approach means zero synchronization bugs between model and renderer, at the cost of coupling the model to the engine's node API. A compile-to-graph design decouples them but must diff and patch the graph on every edit.
> - Build on an existing tiled-buffer engine rather than writing one. The hard parts — copy-on-write tiles, a shared cache with disk swap, mipmap levels — take years to get right, and every subsystem (undo, previews, plug-in access) benefits from them transparently.
> - Make pixel formats self-describing runtime values (babl-style), not enum pairs scattered through the code. When a buffer's format carries its own colorimetry and transfer curve, conversion becomes a planning problem the format library solves once, instead of a matrix of special cases in application code.

## 2. The image data model

The object hierarchy separates concerns in layers, each level adding exactly one responsibility:

- **Filter** — owns a graph node and an active flag. The smallest thing that can participate in rendering.
- **Item** — identity and geometry, not pixels: a stable ID, a persistent "tattoo" that survives save/load, position and size on the canvas, visibility, independent locks for content, position and visibility, and a list of arbitrary named data blobs ("parasites") that plug-ins can attach. All geometric editing (translate, scale, rotate, flip, arbitrary transform, fill, stroke) is declared here as virtual methods, so every item type — raster or vector — answers the same editing verbs.
- **Drawable** — the first level with pixels: one tiled buffer, plus a "shadow" scratch buffer for plug-in writes, plus the stack of non-destructive filters attached to it.
- **Layer** — compositing parameters: opacity, mode, blend/composite spaces, an optional mask with three independent toggles (apply, edit, show), and alpha lock.
- **Channel** — a single-component grayscale drawable plus a display color, used for saved selections, masks, and overlays.

An image owns three parallel item *trees* — layers, channels, paths — so grouping, naming, reordering, and multi-selection are implemented once and shared. Specialized layer types are subclasses that re-render themselves from higher-level state: text layers from a text description, vector layers from a path plus fill/stroke style, group layers from their children.

### Pixel storage and precision

Precision is a *two-dimensional* property: a component type (8/16/32-bit integer, half, float, double) crossed with a transfer-curve choice (linear light, the image profile's own nonlinear curve, or a fixed perceptual curve) — eighteen combinations. The image decides the storage format once, in exactly three functions (layer format, channel format, mask format), and every drawable derives from those. Two details are worth stealing: masks are deliberately *not* color-managed — a mask is coverage, not color — and indexed images are confined to a single legacy format rather than multiplying the format matrix.

> **Implementation notes**
>
> - Split identity/geometry, pixel ownership, and compositing parameters into separate levels. It lets selections, masks, and layers share 90% of their code, and it gives non-raster items (paths, text) full citizenship in naming, grouping, undo, and transforms.
> - Give items two identifiers: a session-unique integer for APIs, and a persistent tattoo for scripts and file round-trips.
> - Centralize format policy at the document level. Ad-hoc per-buffer format choices are where color bugs breed.
> - An extensible "attach arbitrary named data to anything" mechanism (parasites) is disproportionately valuable: GIMP uses it for text descriptions, ICC profiles, symmetry settings, and plug-in state, all without schema changes.

## 3. Layer compositing

GIMP ships 65 layer modes: 43 modern ones and 22 "legacy" modes that reproduce GIMP 2.8 arithmetic bit-for-bit — including its known bugs — so old files render identically. The whole set is described by a single data table: each mode names its graph operation, an optional blend function (there are 33), a flags bitfield, the UI contexts it may appear in (layers, groups, paint tools, filter blending — one enum, four dropdowns), and its default spaces.

The conceptual heart of the modern engine is that three things older editors conflate are **orthogonal axes**:

- **Blend space** — where the color formula (multiply, screen, overlay…) does its arithmetic: linear light, the profile's nonlinear curve, a perceptual curve, or CIE Lab.
- **Composite space** — where the alpha compositing that mixes blended result with backdrop happens. Linear-light compositing avoids dark fringes at soft edges; nonlinear matches legacy expectations.
- **Composite mode** — which *regions* survive: union of layer and backdrop, clipped to either, or their intersection. This is also how the engine computes tight bounding boxes and skips provably-unchanged areas.

All compositing runs in floating point regardless of storage precision. The per-pixel kernel is a three-input point operation (backdrop, layer, mask) with several hard-won optimizations: cached format-conversion plans, skip-run detection over transparent spans, stack-bounded chunking, and hand-written SSE2/SSE4.1 paths for the dominant Normal mode, selected by runtime CPU detection.

> **Implementation notes**
>
> - Make layer modes a data table, not a switch statement. Flags for "spaces are immutable", "subtractive", "alpha-only" let the UI and the optimizer reason about modes generically.
> - Separate blend space from composite space from composite region. Retrofitting this later is a rewrite; GIMP's was the 2.10 release.
> - Keep backward compatibility by freezing old math in clearly-quarantined legacy implementations rather than threading version flags through new code. GIMP's legacy Overlay is literally an operation whose comment admits it was always soft-light.
> - Composite in float internally even if storage is 8-bit; convert at the boundaries.

## 4. Rendering: the projection

The flattened view of an image (the "projection") is not a renderer — it is a **lazily validated cache**. A tile handler installed on the projection's buffer tracks a dirty region; when any reader asks for a tile intersecting that region, the handler renders *just that tile* from the graph and marks it clean. To every consumer, the projection looks like an ordinary buffer that happens to always be correct.

```
Per layer:
  stored pixels (tiled buffer) → non-destructive filter stack → offset
      → mode node (blend + composite) ← backdrop = everything below

Image:
  layer stack graph → channel-visibility mask → overlay channels
      → projection buffer (lazy tile cache) → display / pickers / histogram
```

*The document as a live graph. Layer masks feed the mode node as a third input; group layers recurse, owning a private projection of their children.*

Ahead-of-demand rendering runs on an idle callback in time-boxed chunks, honoring a **priority rectangle** — the visible viewport — so the part of the image you are looking at becomes correct first, and the UI never blocks on a full-canvas render. Group layers use the identical machinery recursively: each group renders its children into its own private projection, which then acts as the group's pixel source. Pass-through groups skip the private buffer and splice their children directly into the parent graph so they can blend with the backdrop beneath the group. During a paint stroke, per-dab invalidations are coalesced into regions rather than emitting thousands of signals.

> **Implementation notes**
>
> - Model the composite as a demand-driven cache keyed by dirty regions, not as a render loop. Correctness stops depending on "did we remember to re-render" and becomes a property of the tile handler.
> - Time-boxed, interruptible chunk iteration with a viewport-priority rectangle is the difference between "feels instant" and "feels like a batch process" on large images.
> - Coalesce invalidation. High-frequency producers (brushes) should accumulate dirty regions and flush at a bounded rate.
> - Give composite subtrees (groups) their own cache; recursion falls out naturally, and a deep edit only re-renders its own subtree's cache plus ancestors.

## 5. Non-destructive editing

GIMP 3's headline capability is that filters can stay live. A drawable filter is an object wrapping one graph operation, spliced into the drawable's filter stack between the stored pixels and the layer's compositing node. The stored pixels are never touched. Crucially, the filter carries the *full layer compositing parameter set* — opacity, any of the 65 modes, blend/composite spaces — plus its own editable per-pixel mask, a region setting (whole drawable vs. current selection), clipping controls, and an on-canvas split-view for before/after comparison.

The elegant consequence: **previews and persistent effects are the same code path**. Opening a filter dialog attaches the filter (that's the live preview); "commit destructively" renders it into the buffer, pushes one undo, and removes the node; "commit non-destructively" simply… leaves it there. Filter stacks serialize into the native file format by walking each operation's introspected properties, and are baked automatically when an operation requires real pixels (export to flat formats, flatten).

> **Implementation notes**
>
> - Unify preview and persistence: an attached-but-uncommitted effect should be the same object as a saved one, with commit being a policy choice, not a different mechanism.
> - Give effects the complete compositing parameter set from day one. "Blurred at 40% opacity in multiply mode, masked to a gradient" costs nothing extra if effects reuse the layer compositor.
> - Reading "pixels as seen after effects" and "raw stored pixels" are different operations; make both explicit in the API. Color pickers want the former, paint tools the latter.
> - Serialize effects via property introspection so new operations persist without touching the file-format code.

## 6. Selections, channels, and masks

A selection is **literally a grayscale image** the size of the canvas: zero means unselected, maximum means fully selected, and everything between is partial coverage. There is no separate selection concept anywhere in the pipeline — operations just multiply by the mask. Feathering, antialiased edges, painting a selection with any brush, and select-by-color thresholds all fall out of this single representation. Quick Mask is assembled entirely from existing pieces: copy the selection into an ordinary channel, display it as a translucent red overlay (channels composite above layers), let the user paint on it, convert back.

Two mechanisms that look similar are deliberately different: **antialiasing** happens at rasterization time — vector-ish sources are scan-converted with fractional coverage, and ellipses get an analytic antialiased path — while **feathering** is a post-process Gaussian blur on the mask (with a tuned radius conversion chosen to visually match the pre-GEGL era). Set algebra (add, subtract, replace, intersect) is a channel-combine module with analytic fast paths for rectangles and ellipses. The channel caches its bounding box and whether it is empty or full, so nearly every editing operation can short-circuit. The marching-ants outline is computed once into cached segment arrays and invalidated on content change.

Smarter selection builds on the same base: contiguous ("fuzzy") selection is a templated flood fill that runs against any pixel source — a layer, a group, or the composited image; Intelligent Scissors is a Dijkstra shortest-path over an edge-cost map computed lazily per tile; Foreground Select has the user paint a trimap and hands the unknown region to alpha-matting solvers.

> **Implementation notes**
>
> - One representation for selection, mask, and channel — a grayscale coverage buffer — collapses three subsystems into one and makes "edit the selection with any tool" free.
> - Cache emptiness, fullness, and bounds on masks; check them at the top of every operation.
> - Keep antialiasing (a rasterization property) and feathering (a signal-processing operation) as distinct concepts with distinct controls.
> - Compose headline features from primitives. Quick Mask is ~zero new machinery; that is a sign the primitives are right.

## 7. Color management

GIMP runs a **two-engine strategy**. babl handles encoding conversions and — for well-behaved matrix-shaper ICC profiles — full space conversions, planned once and executed as tight conversion paths. LittleCMS is the fallback for what babl cannot express: LUT-based profiles, CMYK, and soft-proofing transforms. A profile object wraps the raw ICC bytes and exposes both worlds; a transform object embodies the choice, trying babl first and falling back to lcms. A cheap predicate — "can this conversion be a plain buffer copy?" — is consulted throughout the app to avoid building transforms at all when formats already agree.

The image's ICC profile is converted to a babl space and embedded in the pixel format itself, so "what color do these numbers mean" travels with every buffer, and every filter is space-aware by construction. Assigning a profile (reinterpret the numbers) and converting to a profile (transform the pixels) are separate operations. Each image also carries its own soft-proof profile, rendering intent, and black-point compensation flag. On the display side, per-monitor profiles feed a cached transform keyed on the full configuration tuple, and a stack of pluggable display filters — color-deficiency simulation, clip warning, an ACES film-look preview — sits between the projection and the screen.

> **Implementation notes**
>
> - Fast path + full CMS fallback is the right shape: most real conversions are matrix-shaper and can run an order of magnitude faster than a generic CMS pipeline.
> - Attach colorimetry to the pixel format, not to side-channel metadata that code can forget to consult.
> - Cache display transforms aggressively and invalidate on configuration change; they are rebuilt-per-widget otherwise.
> - Distinguish assign from convert in both API and UI — conflating them is the classic color-management bug.
> - Make soft-proof state per-document. Proofing is an editing decision, not a monitor setting.

## 8. Filters and adjustments

GIMP defines ~57 operations of its own (color adjustments with rich settings objects, selection morphology, compositing infrastructure, the cage-deformation pair) and exposes roughly 108 stock GEGL operations through its menus — about 91 entries in the Filters menu across Blur, Enhance, Distorts, Light & Shadow, Noise, Edge-Detect, Artistic, Map, and Render categories, plus ~38 in the Colors menu, including true HDR tone-mapping operators, viable because the whole pipeline is float. The menu is not a hand-maintained list: at startup GIMP walks the operation registry and creates an action for *every* installed operation, subtracting a blocklist of categories and named exceptions. Third-party operations appear in the UI without recompiling GIMP.

The UI comes from introspection. Every operation declares typed, ranged properties; a generic builder turns them into widgets, guided by metadata keys on the properties — a "degree" unit becomes a rotation dial, paired x/y properties merge into one coordinate control, range-start/range-end pairs become a dual-handle slider, and visibility/sensitivity can be declarative expressions over sibling properties. Operations that need more get one of ~18 hand-written dialog builders, or on-canvas controller widgets (lines, transform grids, focus rings) bidirectionally bound to properties. Settings objects are synthesized at runtime from the same introspection, which buys serialization, presets, last-used values, and undo integration for every operation — including ones GIMP has never seen.

Histograms are computed by a parallel scan with per-thread bin arrays merged lock-free, asynchronously behind a future, in a caller-chosen transfer-curve space, with derived statistics including Otsu's automatic threshold. When a drawable has live filters, the histogram renders the filtered result on demand through the same lazy tile-validation trick as the projection.

> **Implementation notes**
>
> - Make "operation with introspectable typed properties" the unit of extension, then derive UI, serialization, presets, and scripting bindings from that single declaration. This is the highest-leverage decision in the whole architecture.
> - Expose an operation registry via blocklist, not allowlist, so ecosystem operations surface automatically; keep a separate, stricter predicate for which operations may persist non-destructively in files.
> - Property metadata (units, axis pairing, roles, conditional visibility) is cheap for operation authors and transforms generated dialogs from "form" to "designed".
> - Compute statistics asynchronously with cancellation; a histogram that blocks the UI on a 500-megapixel image poisons every dialog built on it.

## 9. The paint engine

A stroke is a state machine (init → motion → finish) over a small set of buffers whose interplay defines brush behavior. Each dab renders into a scratch buffer the size of the dab, so per-dab cost scales with brush size, not layer size. A full-drawable **coverage mask** accumulates where the stroke has painted; in "constant" mode the source pixels are read from a snapshot taken at stroke start and the coverage mask acts as the stroke's alpha, so overlapping dabs never darken beyond the stroke opacity — the stroke behaves as one flat overlay. In "incremental" mode dabs read the live drawable and build up like a real airbrush (which additionally re-stamps on a timer while the pointer is stationary, with probabilistic coverage accumulation).

Dab spacing is measured in *brush space* — the motion vector is projected onto the brush's scaled, rotated axes, so elongated brushes space correctly along their own geometry — and an event with no motion but changing pressure still paints. Sub-pixel placement uses a 5×5 cache of pre-shifted brush masks. Dynamics map eight inputs (pressure, velocity, direction, tilt, wheel, rotation, random, fade) through per-input editable curves to eleven outputs (size, opacity, angle, color from gradient, hardness, force, aspect, spacing, rate, flow, jitter), mixed by simple averaging. Painting runs on a dedicated worker thread with the canvas refreshing at a bounded rate; every core paints N symmetric dabs when mirror/mandala/tiling symmetry is active, and GIMP 3 paints onto multiple selected layers simultaneously.

Individual engines are variations on the theme. Smudge keeps a running accumulation buffer blended toward the pixels under the brush (pickup rate) and deposited back (flow). Ink models a calligraphic nib as a convex blob and scan-converts the convex union of successive blobs, giving continuous pen-like edges instead of stamped dabs. Heal is the standout: rather than copying source pixels, it solves a Poisson equation on the source/destination difference over the brush footprint, transplanting the source's *texture* while preserving the destination's illumination. MyPaint brushes are integrated by implementing a surface interface over the native buffer, letting an external brush engine drive dab generation.

> **Implementation notes**
>
> - The three-buffer scheme — dab scratch, stroke coverage mask, stroke-start snapshot — is the canonical answer to "why does my brush get darker where dabs overlap". Constant-mode strokes need all three.
> - Space dabs in brush coordinates and interpolate every input axis between events, not just position.
> - Cache sub-pixel-shifted and transformed brush masks; brush rendering is the inner loop of the whole feature.
> - Keep dynamics simple and composable: per-input curves plus averaging covers nearly everything artists ask for, and stays debuggable.
> - Move stroke processing off the UI thread early; retrofitting threading into a paint core is painful.
> - For a heal/repair brush, Poisson-blending the difference field is the mechanism that separates "clone stamp" from "magic".

## 10. Transforms and deformation

All affine and perspective tools — move, scale, rotate, shear, perspective, unified, handle, 3D — funnel into one pipeline: build a 3×3 matrix, hand it to the engine's transform operation with a pluggable resampler (nearest, linear, cubic, plus halo-suppressing resamplers for large downscales), and compute the output extent per the chosen clipping policy. Flips and 90° rotations are detected and take exact fast paths. The same matrix is applied consistently to every item type — raster buffers are resampled, but **paths are transformed analytically** at their control points, and text layers fold transforms into a stored matrix so the text re-renders crisp instead of resampling.

Interactive tools maintain a *bidirectional* mapping between human-editable parameters (angles, scales, handle positions) and the matrix, which is what lets on-canvas handle dragging and numeric dialog entry stay consistent. The exotic deformers each pick a classic algorithm: Warp accumulates brush strokes into a displacement field that pixels are looked up through, making strokes incremental and individually undoable; Cage transform implements Green-coordinates deformation in two passes — an expensive per-cage coefficient precomputation, then a cheap per-drag evaluation, with recursive triangle subdivision to fill the forward map without holes; N-point deformation runs an as-rigid-as-possible solver continuously on a background thread while you drag.

> **Implementation notes**
>
> - One matrix pipeline, many front-ends. Tools should differ only in how they produce parameters and how parameters map to a matrix — in both directions.
> - Transform vector data exactly; only rasterize at the last responsible moment.
> - For brush-driven warps, accumulate a displacement field rather than resampling per stroke: edits compose, preview is a cheap lookup, and final render can use a better sampler.
> - Split deformation algorithms into precompute (per shape) and evaluate (per drag); interactivity lives or dies on that split.

## 11. Text and vector paths

A text layer is a raster layer whose pixels are a *cache*: the source of truth is a serializable description object holding content (with markup), font, size, hinting, kerning, language, direction, justification, spacing, box mode, color, a full outline/stroke specification, and a transform matrix. Change any property and the layer re-renders through Pango and Cairo — including right-to-left and vertical layouts, and on-canvas input-method editing for CJK. The description rides in the file as an attached parasite, so older readers degrade gracefully to a plain raster layer. Text converts to editable outline paths through the same path machinery.

Paths are first-class items: ordered Bézier strokes over anchor lists, with a rich geometric API — nearest point, tangents, arc-length parameterization (the enabler for "along path" features), flattening at a chosen precision. Rasterization goes through one shared scan-converter (Cairo-backed) that both fills and strokes with full stroke style, and the same converter serves "stroke selection", "stroke path", and path-to-selection. SVG path data imports and exports for interchange. Vector layers — live, re-editable shape layers with fill and stroke properties — reuse the identical pattern as text: parameters as truth, pixels as cache.

> **Implementation notes**
>
> - "Parameter object as source of truth, raster as cache" is the general recipe for any re-editable layer type: text, shapes, gradients, linked images.
> - Store transforms on parametric layers symbolically and re-render, never resample.
> - Delegate text shaping to a real layout engine; the hard problems (bidirectional text, scripts, IME) are ecosystems, not features.
> - Persist parametric layers alongside their rendered pixels so older readers still open the file.

## 12. Undo and history

Undo is command objects, roughly 25 typed classes — one per kind of state (pixel region, whole-buffer replacement, item properties, layer add/remove, mask operations, filter stack changes, image-level properties…) — pushed through a façade of ~60 typed functions. The elegant core is that **undo and redo are one symmetric operation**: popping an undo object *swaps* its stored state with the live state, leaving the object holding what redo needs. For pixel edits, the dirty rectangle is expanded to tile boundaries and only that region's old tiles are saved; on undo, the region is exchanged in place. Because snapshots are themselves tiled buffers, large undo states spill to disk automatically.

Compound operations (scale image, quick-mask toggle) wrap their steps in named groups that collapse into a single history entry, with nesting counted so inner groups are free. Tools that make thousands of micro-edits (painting) accumulate into a stroke-scoped buffer and push one undo at stroke end. The memory budget is *measured, not estimated* — every object reports its actual size — with a byte budget (default: an eighth of RAM), a guaranteed floor of steps kept regardless of size, and eviction from the oldest end. History is linear: a new edit clears the redo stack.

> **Implementation notes**
>
> - Swap-based symmetric undo halves the code and eliminates redo-drift bugs by construction.
> - Snapshot regions, aligned to your tile grid, not documents. Let the buffer layer's disk swap handle size.
> - Named, nested undo groups are essential from day one; users think in operations, not in mutations.
> - Budget undo memory by measuring real sizes, and keep a step-count floor so the budget can never strand a user with one undo level.

## 13. Performance machinery

The performance story is layered. At the bottom, the tile engine provides a shared cache (default: half of RAM) with compressed disk swap, so layers, undo snapshots, and previews all degrade gracefully past RAM. Buffers keep mipmap pyramids (~33% overhead), and the display reads coarser pyramid levels when zoomed out rather than downsampling full-resolution tiles. Above that: the engine's own thread pool parallelizes point operations; hand-written loops distribute areas across threads with per-thread accumulators merged lock-free; whole background jobs (histograms, thumbnails) run as cancellable futures, deliberately serialized on one worker so background work can't starve interaction; and the projection's idle-driven chunk iterator cooperatively time-slices the main thread.

SIMD is applied surgically: only the kernels that dominate (Normal mode, the clip-to-backdrop compositor, one smudge blend) have SSE2/SSE4.1 variants, each compiled with its own flags and selected at class-initialization by runtime CPU detection. Equally important are the optimizations that avoid work entirely: conversion-plan caching, skipping runs of transparent pixels, bounding-box derivation from composite regions, cached "is this mask empty" bits, and the stable-topology trick of parking no-op nodes in graph slots so capabilities can toggle without rebuilding graphs.

> **Implementation notes**
>
> - Order of leverage: don't do the work (bounding boxes, empty-mask checks, cached plans) → do it lazily (demand-driven tiles, priority viewport) → do it in parallel → then, last, vectorize the two or three kernels profiling actually indicts.
> - Read from mipmap levels for zoomed-out display; it converts pan/zoom from O(image) to O(screen).
> - Serialize background jobs on a dedicated low-priority worker; ten concurrent histogram threads is how interaction dies.
> - Dispatch SIMD at runtime per-CPU, compile per-file with target flags, and always keep the scalar path as the reference implementation.

## 14. Extensibility and file formats

There is exactly one public API: the **procedural database** (PDB), a runtime registry of 803 named procedures with typed, ranged, documented signatures. Plug-ins, Script-Fu, Python, batch mode, and the network scripting server all reach the same registry. The internal procedures are defined once each in a code generator that emits three artifacts from a single definition: the core-side marshaller with validation, the client-library wrapper that C plug-ins call as ordinary functions, and the introspection metadata that powers the procedure browser. Adding a scriptable operation means writing one definition block; everything else follows.

Plug-ins run **out of process**. The core spawns the plug-in executable with pipe file descriptors passed on the command line and speaks a versioned wire protocol over them; objects cross the boundary as integer IDs, never pointers; bulk pixel data moves through shared memory or, in GIMP 3, through a custom tile backend that gives the plug-in a real buffer object whose tiles are fetched from the core on demand — no bulk copy. A crashed plug-in cannot take the core down, and a cleanup layer recovers leaked undo groups when one misbehaves. Interpreter mapping makes a script file with a shebang a full plug-in; procedure metadata is cached so startup doesn't respawn every plug-in. The GIMP 3 API is GObject-based and fully introspected, so Python, JavaScript, Lua, and Vala bindings exist without per-language binding code — the repository ships the same demo plug-in in five languages. Script-Fu embeds a Scheme interpreter, offers a console, and runs a TCP server for driving GIMP from other processes; batch mode makes it CI-scriptable.

File formats follow the same split: the native XCF format lives in the core (it must understand every core concept — item trees, precision, profiles, parasites, live filter stacks), while some 60+ formats are plug-ins registered by extension, MIME type, and magic bytes with priorities — from PNG/JPEG/TIFF/WebP through EXR, AVIF, JPEG XL and PSD (which imports adjustment layers as live filters), to camera raw handled by delegating to darktable or RawTherapee. A "compressor" plug-in wraps any other handler to read/write compressed variants transparently. Format parsers handling untrusted input living in separate processes is a security posture, not just an architecture nicety.

> **Implementation notes**
>
> - One typed procedure registry as the single public surface keeps scripting, plug-ins, batch, and remote control consistent by construction.
> - Generate marshalling, wrappers, validation, and docs from one definition; hand-written binding layers drift.
> - Isolate extensions in processes; pass objects by ID; move pixels via shared memory or demand-paged tiles. You get crash isolation, security sandboxing of format parsers, and language independence from one decision.
> - Build on an introspectable object system (or provide an IDL) so language bindings are free rather than N ongoing projects.
> - Register file handlers with magic-byte detection and priorities so multiple handlers for one format can coexist.

---

*Compiled from a survey of the GIMP source tree (3.3 development branch, August 2026): the core document model in `app/core`, operations and layer modes in `app/operations`, GEGL glue in `app/gegl`, tools in `app/tools` and `app/paint`, text and paths in `app/text` and `app/path`, color libraries in `libgimpcolor`, the plug-in system in `app/plug-in`, `libgimp`, and `pdb`, and file handling in `app/xcf` and `plug-ins`. Mechanisms are paraphrased; no source code is reproduced.*
