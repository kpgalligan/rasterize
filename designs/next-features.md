# What Popular Editors Have That We Don't

**Status: the suggested next phase (bottom of this file) has shipped** —
adjustment layers (all nine ops, Curves included), clipping masks, the
eyedropper and crop tools, and selection morphology + Quick Mask are in the
app, the core, and the MCP catalog, which now stands at 43 tools. The
follow-ons — layer groups, shape layers, layer styles, retouch brushes —
remain open.

A survey against Photoshop / Photopea / GIMP / Affinity, ranked by value
per unit of effort **given this codebase's architecture** — pure ops over
`Arc`-shared layers, canvas-sized coverage masks, an f32 compositor, and
the opaque per-layer `meta` slot that text layers already ride.

Companion to `high-leverage-roadmap.md` (Phases 1–4, all shipped) and the
GIMP study in `gimp-image-manipulation-capabilities.md`.

---

## The headline: `meta` is a parametric-layer mechanism, not a text mechanism

Phase 3 built "parameter object as source of truth, raster as cache" for
text. The same mechanism, unchanged, delivers three of the most-missed
features in the app. This is the single highest-leverage direction
available and needs no new architecture.

**Adjustment layers.** A layer whose `meta` says
`{type:"adjust", op:"curves", …}` and whose contribution at composite
time is *the adjustment applied to the accumulated backdrop* rather than
stored pixels. It is the honest way to get non-destructive editing
without the live filter graph the GIMP study warns is rewrite-scale (§5).
It composes with the layer masks from Phase 2 for free, and
"adjustment + mask" is the single most-used professional workflow there
is: dodge this region, warm that one, all re-editable forever. Opacity
and blend mode already apply to it because it is a layer.

**Shape layers.** `{type:"shape", kind:"rect|ellipse|line|polygon",
geometry, fill, stroke, radius}` re-rendered exactly the way text layers
re-render — the study's §11 note that vector layers reuse the identical
pattern. There is currently *no way to draw a rectangle* in this app,
which is a conspicuous hole, and doing it parametrically costs barely
more than doing it destructively.

**Layer styles** (drop shadow, stroke, outer/inner glow, colour
overlay). `meta` describes the effects; the compositor renders them
around the layer's pixels at composite time. Enormous perceived value
per unit of work, and it lands especially well now that text is a real
layer type — "drop shadow on text" is what people reach for first.

Cost: medium each, sharing one mechanism and one `.rz` field. No format
bump needed — the slot already exists and already round-trips.

## Structure: groups and clipping masks

**Clipping masks** — clip a layer to the alpha of the layer beneath it.
Cheap (a compositing rule, no model change) and constantly used: it is
how everyone confines a texture, gradient, or adjustment to one shape.

**Layer groups** — folders with their own opacity, blend mode, and mask.
This one is genuinely large: the compositor must recurse, each group
rendering its children into a private projection that then composites as
a single layer (study §4). Pass-through groups can come later. Worth it
once the layer stack routinely exceeds ~8 layers, which adjustment
layers and shape layers will cause immediately.

## The hand tools that are simply missing

Small, individually obvious, collectively the difference between "demo"
and "tool you'd actually reach for":

- **Eyedropper** — there is no way to pick a colour off the canvas. This
  is the most embarrassing gap in the app; it is an afternoon's work.
- **Crop tool** — interactive handles with aspect presets and
  straighten. Crop today is selection-based via a menu; the Free
  Transform session already has the handle, hit-testing, and
  commit-on-Return machinery to borrow.
- **Shape tools** — the UI half of shape layers above.
- **Guides, rulers, grid, and snapping** — workflow plumbing everyone
  expects and nobody notices until it is absent.

## Cheap wins riding machinery that already exists

The coverage-mask selection model makes a whole class of features nearly
free — the GIMP study's point that composing headline features from
primitives is the sign the primitives are right:

- **Select ▸ Grow / Shrink / Border / Smooth** — morphology on the mask,
  structurally identical to the feather already shipped.
- **Quick Mask** — display the selection as a red overlay and let any
  paint tool edit it, then convert back. The study calls this "~zero new
  machinery" once selections are coverage buffers, which ours are.
- **Save/Load Selection** as a named channel, and a Channels panel.
- **Curves** — Levels already exists; Curves is the same pipeline with a
  spline LUT, and it is the adjustment people ask for by name.
- **Histogram** — needed by Levels and Curves anyway; §8 has the
  parallel-scan-with-merged-bins design.
- **Multi-stop gradient editor** and **gradient map**. Gradients are
  two-colour today.
- **History panel** — undo is already a stack of handles; this is
  mostly a table view over state that exists.
- **Copy Merged, Paste Into, Trim, Reveal All**, auto-levels/contrast.

## Retouching brushes — the biggest category gap for photo work

The paint path (canvas-sized premultiplied overlay, one undo step per
stroke) extends naturally:

- **Clone stamp** — sample at a fixed offset from a source point. Small.
- **Dodge / burn / sponge / smudge / blur brush** — per-dab pixel ops.
  Smudge needs the running accumulation buffer described in §9.
- **Healing brush** — solves a Poisson equation on the source/destination
  difference so the source's *texture* transplants while the
  destination's illumination survives. Real work, but §9 documents the
  mechanism and it is what separates "clone stamp" from "magic".

## The distinctive one: subject selection via Vision

Our selection *is* a coverage mask, so a segmentation result drops
straight into the existing model with no glue. macOS ships this:
`VNGeneratePersonSegmentationRequest` works on the current deployment
target; full subject lifting
(`VNGenerateForegroundInstanceMaskRequest`) needs macOS 14, so it is a
raise-the-floor-or-gate-it decision.

Exposed as an MCP tool as well, it makes the built-in agent
qualitatively more capable — "remove the background", "brighten just the
person" become one-shot requests. No other editor pairs a segmentation
primitive with an agent that can act on it. **Content-aware fill**
(PatchMatch inpainting) is the natural follow-on and the bigger lift.

## Keep deferring

Unchanged from the previous roadmap, all rewrite-scale per the study:
float/linear-light pipeline with separate blend and composite spaces
(§3 — "was the 2.10 release"), a live tiled render graph (§1, §4, §13),
colour management (§7), smart objects, and a full pen/Bézier path model.
Paths are the most tempting of these — they would unlock text-on-path,
better shapes, and path-based selections — but they are a subsystem, not
a feature, and shape layers deliver most of the value without them.

## Suggested next phase

1. Adjustment layers (with Curves as the first adjustment worth having).
2. Clipping masks.
3. Eyedropper + crop tool.
4. Selection morphology and Quick Mask.

That sequence puts non-destructive editing, the most-used pro workflow
(masked adjustment layers), and the most-missed small tools in the app
while touching one mechanism that already exists and one compositing
rule. Layer groups, shape layers, layer styles, and the retouch brushes
follow naturally after.
