# High-Leverage Roadmap

**Status: Phases 1–4 have shipped** — selection algebra/feathering/marching
ants, layer masks, re-editable text layers, and the unified transform pipeline
(Free Transform, ⌘T) are all in the app, the core, and the MCP catalog, which
now stands at 38 tools. The deferred items below remain deferred.

Four features chosen from the GIMP architecture study
(`gimp-image-manipulation-capabilities.md`) as the best
capability-per-effort fits for Rasterize's current model: they compound
with what exists (the coverage-mask selection model, f32 compositing,
`Arc`-shared pure ops), and none requires the rewrite-scale commitments
the study warns about (live render graph, float pipeline, tiling).

Ordered by leverage over cost. Each phase ships all three surfaces —
interactive UI, MCP tools, and (where state persists) the `.rz` format —
plus core tests and README updates, with the usual FFI three-file
lockstep (Rust shim / header / Swift wrapper).

---

## Phase 1 — Selection algebra, feathering, real marching ants

*Study §6: "set algebra is a channel-combine module"; "feathering is a
post-process Gaussian blur on the mask". The representation is already
right; this phase is mostly arithmetic on it.*

**Combine modes.** All selections rasterize to canvas-sized u8 coverage,
so algebra is per-byte: union `max(a,b)`, subtract `min(a, 255−b)`,
intersect `min(a,b)`, invert `255−a`. Combining ever-so-slightly demotes
exact-path selections to mask kind — acceptable, because this phase also
adds true mask outlines (below). A result that is all zero becomes
deselect.

**Modifiers and menu.** Photoshop conventions on all four selection
tools (rect, ellipse, lasso, wand): Shift = add, Option = subtract,
Shift+Option = intersect, decided at mouse-down/click. Select menu
gains Invert (⇧⌘I) and Feather… (radius dialog).

**Feather.** Gaussian blur on the mask buffer. Small core function over
a raw mask buffer (reuse the blur kernel machinery in
`ops_filters.rs`); masks already cross the FFI as plain byte buffers,
not handles, so an in-place `rz_selection_feather(mask, w, h, radius)`
fits.

**Marching ants on the mask contour.** Mask-kind selections currently
draw a dashed bounding box. Add marching-squares contour extraction at
coverage ≥128 → cached `NSBezierPath`, invalidated on selection change
(study: "computed once into cached segment arrays"). Geometric shapes
keep their exact paths. Also cache the empty/full bits alongside the
existing bounds.

**MCP.** `mode: replace|add|subtract|intersect` parameter on the four
`select_*` tools; new `modify_selection` tool (invert, feather radius).

Size: **small–medium.** Almost entirely Swift plus one core function.

## Phase 2 — Layer masks

*Study §6: "one representation for selection, mask, and channel." The
selection mask representation becomes a per-layer alpha gate.*

**Core model.** `Layer` gains `mask: Option<Arc<GrayImage>>` (same
dimensions as the layer's pixels, moves with the layer, GIMP-style) and
`mask_enabled: bool`. The f32 composite kernel multiplies layer alpha
by mask coverage before blending — a three-input point op, exactly the
study's shape.

**Operations** (all pure, returning new documents): add mask
(reveal-all / hide-all / from current selection, cropped to the layer
rect), delete, apply (bake into layer alpha), enable/disable. Painting
on a mask reuses the stroke-overlay path with a new target:
`mask' = lerp(mask, luma(overlay), alpha(overlay))` — brush paints
toward white, eraser toward black.

**UI.** Layers panel shows a second thumbnail per masked layer; clicking
selects the paint target (ring highlight), and brush/eraser then edit
the mask in grayscale. Layer ▸ Mask submenu for add/delete/apply/
disable. Selection confinement applies to mask painting like any other
stroke.

**Persistence.** `.rz` format version bump serializing mask bytes +
enabled flag (older files keep loading; see the shared-bump note in
Cross-cutting). Investigate whether the `psd` crate exposes layer
masks for import — stretch goal.

**MCP.** `add_layer_mask`, `remove_layer_mask {apply}`,
`set_layer_mask_enabled`; `target: "mask"` on brush/eraser;
`get_document` reports mask presence per layer.

Size: **large.** Touches the compositor, model, format, panel, paint
path, and a handful of FFI functions.

## Phase 3 — Re-editable text layers (via a layer-metadata mechanism)

*Study §11: "parameter object as source of truth, raster as cache",
persisted alongside pixels so older readers degrade gracefully. Also
§2's parasite advice — implemented minimally.*

**Mechanism first.** `Layer` gains `meta: Option<String>` — an opaque
JSON blob the core stores, copies, and serializes but never interprets
(a one-field parasite). Text layers are ordinary raster layers whose
meta holds `{type: "text", string, font, size, color, alignment}`.
Rendering stays in Swift/CoreText (the study: delegate shaping to a
real layout engine); the core never shapes text.

**Flow.** The text tool commits a *text layer* instead of painting into
the active layer: pixels rendered to a tight raster, offset = layout
origin, meta attached, one atomic FFI call
(`rz_doc_layer_set_content(idx, pixels, offset, meta)`) so re-edits are
one undo step. Clicking a text layer with the text tool reopens the
on-canvas editor pre-filled from meta; commit re-renders and replaces
content. Move tool needs no special casing — position *is* the layer
offset.

**Degradation.** Destructive ops on a text layer (filters, painting,
transforms) prompt "Rasterize text layer?" and drop the meta on
confirm. Old `.rz` readers see a plain raster layer — graceful by
construction. Layers panel badges text layers with a "T".

**MCP.** New `add_text_layer` / `edit_text_layer` tools;
`draw_text` stays as the rasterizing paint variant; `get_document`
reports text params.

Size: **medium.** Rides Phase 2's format bump if landed adjacently.

## Phase 4 — Unified transform pipeline (free transform)

*Study §10: "one matrix pipeline, many front-ends", with bidirectional
parameter↔matrix mapping and cheap preview / quality commit.*

**Core.** One new op: `rz_doc_layer_transform(idx, affine[6], sampler)`
— inverse-mapping resample (nearest / bilinear / bicubic), output
extent from the transformed corner bbox, new layer offset. Resample in
*premultiplied* f32 and unpremultiply at the end, or transparent
neighborhoods bleed dark fringes into edges (study §3's warning applied
to sampling). Existing exact 90°/flip ops remain the fast paths.

**Tool.** Free Transform (⌘T) on the active layer: corner/edge handles
scale (Shift constrains proportions), dragging outside a corner
rotates, Option pivots on center; Return commits, Escape cancels.
Options bar shows editable angle / scale % / size numerics bound both
ways to the matrix. Preview during drag is a cheap CG affine of the
cached layer image; commit runs the core resample once — one undo
step. Text layers prompt to rasterize (Phase 3 rule) until symbolic
transforms are worth adding.

**MCP.** `transform_layer {layer, rotate, scale_x, scale_y, translate,
around, sampler}` (named params compiled to the matrix — friendlier to
agents than raw matrices).

**Deferred within this phase:** perspective (needs a 3×3 pipeline and
better handles), transforming a floated selection rather than a whole
layer.

Size: **medium–large.** One meaty core function plus interactive
geometry.

---

## Cross-cutting

- **One `.rz` bump, not two.** Masks (Phase 2) and layer meta (Phase 3)
  should share a single format revision — add the meta field to the
  format when masks land, even if nothing writes it yet.
- **Verification per phase:** cargo unit tests for every core op
  (combine/feather edge cases, masked compositing, transform corners +
  premultiplied sampling, meta round-trip through `.rz`), then
  end-to-end MCP drives against an isolated instance per the CLAUDE.md
  recipe, with rendered-canvas checks.
- **Order.** 1 → 2 → 3 → 4. Phase 1 is standalone polish that
  immediately compounds; 2 and 3 are adjacent for the format bump;
  4 is independent and can slot anywhere after 1.

## Deliberately deferred (rewrite-scale per the study)

Float/linear-light pipeline and blend/composite-space axes (§3 — "was
the 2.10 release"), live non-destructive filter stacks (§5 — GIMP 3's
headline, wants the graph), tiled/lazy buffers and mipmaps (§13 —
matters past our 100 MP cap), color management (§7), layer groups and
channels-as-objects (§2). Each is worth doing only with a deliberate
model change, not as an increment.
