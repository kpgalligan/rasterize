//! Layer GROUPS: the nesting marked on each entry, the ONE invariant that
//! keeps it well formed, and the recursive compositor `doc::flattened` wires
//! up. The two ops (`group_layers` / `ungroup_layer`) plus the structural move
//! (`move_layer_to`) that create the shape — those three, and the group
//! projection every raw reader answers with, live next door in
//! `doc_group_ops`, which is where this file's size budget sends them.
//! Per-entry geometry and link queries live in `doc_group_query`, the lock
//! bits in `doc_lock`.
//!
//! # The layout
//!
//! The stack stays a FLAT `Vec<Layer>`, bottom first, with structure marked
//! on the entry: a `kind` (raster or group) and a `depth`. A group's children
//! are the maximal run of entries immediately BELOW it at greater depth, and
//! the group entry itself is the LAST record of its own subtree. That is
//! Photoshop's panel order read bottom-up (`Layer 0`, `Layer A`, `Layer B`,
//! `Group 1` — indices 0, 1, 2, 3 at depths 0, 1, 1, 0), and it is exactly how
//! PSD stores it, so import maps across without reordering and every existing
//! index, export and undo snapshot keeps its meaning.
//!
//! A valid forest, bottom-first:
//!
//! * every depth is <= [`MAX_GROUP_DEPTH`];
//! * the LAST entry of the stack is at depth 0;
//! * scanning any level's range `[lo, hi)` at depth `d`, every entry has
//!   depth >= `d`, and each entry AT depth `d` closes the run of entries since
//!   the previous depth-`d` entry: that run is its children and must be empty
//!   unless the entry's kind is Group; each such run is itself a valid level
//!   at depth `d + 1`;
//! * an empty group (a Group entry closing an empty run) is legal — Photoshop
//!   allows one, and so does PSD.
//!
//! The tree is re-derived positionally on every composite, precisely as
//! `Layer::clipped` and the clip-run walk already re-derive clip groups. This
//! module applies that same mechanism one level up.
//!
//! # The invariant is a HARD RUNTIME check, never an assertion
//!
//! [`units`] has no way to report a malformed input. Given the malformed
//! `[c0(d1), X(d0), c1(d1), G(d0)]` — which is what a `move_layer_to` with a
//! bad `(to, depth)` pair produces — it yields `Unit { start: 0, idx: 1 }` for
//! the raster entry `X`; resolution borrows `X` and never looks at
//! `start..idx`; and `c0` DISAPPEARS from every projection, every export and
//! every save with no error anywhere. Silent data loss, not a crash.
//!
//! So [`validate_structure`] is a real runtime check and every structural op
//! ends in [`validated`], which returns `None` on a violation. `make test`
//! runs `cargo test --release` and `Cargo.toml`'s `[profile.release]` sets
//! only `lto = true`, so `debug-assertions` takes Cargo's release default of
//! false: a `debug_assert!` here would be compiled out of every test the
//! project runs AND out of the shipped staticlib, leaving nothing to catch a
//! host-driven violation. One O(n) scan over at most 1024 entries costs far
//! less than the clone the op already made, and `None` is the core's own
//! purity contract: a malformed structure is a NO-OP, never a panic. (Setting
//! `debug-assertions = true` in `[profile.release]` was considered and
//! rejected: it would ship assertions and turn a violated invariant into a
//! panic that `catch_unwind` converts into a generic FFI error — strictly
//! worse than a clean `None`.)
//!
//! # A group RENDERS TO A LAYER
//!
//! An ISOLATED group is composited into a private f32 buffer over its own
//! extent, quantized to RGBA8 by the document's own [`crate::doc::quantize`],
//! and wrapped in a synthetic `Layer` carrying the group's name, opacity,
//! blend mode, mask (cropped to the extent), style and clipped flag. That
//! synthetic layer is handed to the existing, unchanged `composite_layer_into`
//! / `composite_clip_group_into` / `composite_styled_into`, so a group's
//! style, mask, blend mode, opacity, Blend If and Dissolve dither mean exactly
//! what they mean on a layer, because they ARE what they mean on a layer:
//! there is no second implementation of any of them.
//!
//! The cost is one 8-bit quantization at each isolated group boundary. That is
//! what "render the group and composite it once" means in an 8-bit editor, it
//! is what Photoshop does, and f32 chaining is still preserved in the two
//! places that matter: INSIDE a group, and across the WHOLE document when its
//! groups are Pass Through.
//!
//! A PASS-THROUGH group allocates nothing: its children composite straight
//! onto the enclosing accumulator with the same origin, which is the only way
//! an adjustment layer inside it can reach the layers below the group. Pass
//! Through is therefore the CHEAP case and Isolated the expensive one — the
//! opposite of the naive intuition.
//!
//! # A pass-through group's own MASK and OPACITY gate it; they do not isolate
//!
//! A mask or an opacity below 1 on a Pass Through group is NOT a reason to
//! isolate. Isolating for them destroys what the group is for: an adjustment
//! layer inside would composite against a fresh TRANSPARENT buffer, where
//! `composite_adjustment_into`'s documented `bg[3] <= 0.0` skip makes it a
//! no-op, so the adjustment vanishes entirely instead of being restricted or
//! scaled — an all-white "Reveal All" mask, a semantic no-op, would silently
//! turn the group off. Photoshop keeps such a group in Pass Through and
//! restricts it PER PIXEL, and so does this build ([`composite_gated_pass`]):
//! the children composite onto a COPY of the enclosing accumulator, which is
//! the real backdrop, and the result is lerped back by
//! `mask/255 * sane_opacity(opacity)`. "Group the adjustment layers and mask
//! the group" is the standard workflow this makes work.
//!
//! The gate is exact at both ends: a coverage of 1 takes the composited pixel
//! VERBATIM (so an all-white mask at opacity 1 is byte-identical to no mask at
//! all), and a coverage of 0 leaves the accumulator untouched. Its cost is one
//! accumulator-sized f32 copy, charged against [`MAX_GROUP_BUFFER_PIXELS`]
//! like every other group buffer, and only a group that actually carries a
//! mask or a sub-1 opacity pays it.
//!
//! # Isolation, and the clipping cost it carries
//!
//! [`is_isolated`] is the whole rule. Two notes on it:
//!
//! * a BLEND MODE or a STYLE does isolate, because both need the group's own
//!   rendered pixels: a blend function takes the group's colour as its source,
//!   and a style needs the shape the group's projection makes. Neither can be
//!   expressed as a per-pixel gate on the backdrop, which is why the mask and
//!   opacity terms above are the only two that could move.
//! * `clipped` and a visible clipped MEMBER both force isolation because both
//!   need the group's own alpha footprint: a clipped group is gated by its
//!   sibling's footprint, and a clip base's members are gated by the base's. A
//!   clip group is already an isolation. Only VISIBLE clipped members count,
//!   so an invisible clipped sibling never silently isolates a group — and
//!   `clipped` counts only when the entry actually HAS a base, i.e. is not the
//!   bottom-most entry of its level. A baseless clipped entry composites as if
//!   unclipped, so the flag must not isolate it either; otherwise clipping a
//!   pass-through group to a sibling that does not exist would switch off an
//!   adjustment layer inside it, and simply reordering the group to the bottom
//!   of its level would do the same to a group that was clipped legitimately.
//!
//! The stated cost of the member rule, and why it is accepted. Take
//! `[Photo(d0), G(d0, PassThrough){Curves(d1)}, Texture(d0, clipped)]`. `G` is
//! a clip base, so it isolates; `Curves` then composites into a private
//! transparent buffer, where the documented `bg[3] <= 0.0` skip means it
//! adjusts NOTHING, and `Photo` is left untouched. Removing `clipped` from
//! `Texture` — an unrelated sibling — makes `Curves` adjust `Photo` again. So
//! setting a clipping mask on one layer turns off an adjustment inside a
//! different, pass-through group. That is a decision, not an oversight: it is
//! published in the `set_layer_clipped` and `add_adjustment_layer` catalog
//! entries and in the layers panel, and pinned by
//! `group_tests::clipping_over_a_pass_through_group_isolates_it`. The
//! alternative — keeping pass-through when the group is only a clip BASE —
//! needs an alpha-only pass over the group's visible leaf descendants, a
//! second full-extent buffer seeded from `acc`, and a footprint-weighted mix
//! back: a SECOND implementation of clipping, in a codebase whose rule is one
//! implementation per algorithm. It is the named follow-up, not smuggled in.
//!
//! # Why the depth cap is not a memory bound
//!
//! A depth cap is NOT an allocation bound. Per ISOLATED level the compositor
//! allocates, over the level's extent (at most the canvas):
//!
//! ```text
//!     f32 accumulator                        16 bytes / pixel   (rendered_group)
//!     the quantized RGBA8 it becomes          4 bytes / pixel   (rendered_group)
//!   + when the level is also a CLIP BASE:
//!     composite_clip_group_into's buffer     16 bytes / pixel   (doc.rs)
//!     its base_alpha: Vec<f32>                4 bytes / pixel   (doc.rs)
//!   + when the level carries a STYLE:
//!     composite_styled_into's buffer         16 bytes / pixel   (style_composite.rs)
//! ```
//!
//! A GATED pass-through level (a mask or a sub-1 opacity, no isolation) is
//! cheaper but not free: one f32 copy of the ENCLOSING accumulator, 16 bytes /
//! pixel, plus a 1 byte / pixel cropped mask, and it nests exactly as an
//! isolated level does. It charges the same budget, at the same two points.
//!
//! `MAX_PIXELS` is 100_000_000, so ONE full-canvas isolated level is 2.0 GB,
//! and up to 5.6 GB when it is a styled clip base. Ten nested such levels — a
//! ~10 KB `.rz` holding one 10000x10000 raster layer inside ten groups each at
//! opacity 0.9, which now GATE rather than isolate but allocate a full-canvas
//! f32 buffer per level all the same, and whose extent is the leaf's
//! full-canvas rect at every level because extent-intersect-clip never
//! shrinks — demands roughly 16-56 GB. Rust ABORTS on allocation failure, so
//! `catch_unwind` cannot contain it, and `validate_structure` does not catch
//! it because the structure is perfectly well formed. A group entry's own PNG
//! is a 1x1 transparent buffer (~70 bytes), so a ten-deep chain costs
//! essentially nothing against the RZDC pixel caps.
//! [`MAX_GROUP_BUFFER_PIXELS`] is the bound that closes this: it is charged in
//! [`rendered_group`] and [`composite_gated_pass`] BEFORE every allocation and
//! RELEASED as soon as that buffer is dropped, so it bounds what a nest holds
//! AT ONCE; a group that
//! would pass it contributes nothing — the same outcome as an empty group, in
//! band, with no panic and no partial allocation. Sibling groups composite one
//! after another and never coexist, so they do not spend it: only nesting
//! does, which is exactly the shape that can run the machine out of memory.
//!
//! # The styled-group plane cache
//!
//! `style_cache::CacheKey::of` keys a style's rendered planes on the pointer
//! identity of `layer.pixels`. A group's compositing key is the SYNTHETIC
//! layer's `Arc`, fresh every composite, so the exact-pointer lookup always
//! misses — and then the cache's identical-coverage path finds the previous
//! entry by size + context, shares its planes and stores a second key. A
//! styled group therefore pays one shape build and one coverage compare per
//! composite and re-renders its effects only when its projection actually
//! changed; `store`'s dead-entry prune keeps exactly one entry alive.
//!
//! MEASURED, so the claim is evidence rather than reasoning: a 1200x900 canvas
//! holding a group of two 400x300 layers, the group carrying a drop shadow
//! (distance 12, size 16) plus an outer glow (size 18). The same document's
//! FIRST projection takes 29 ms and each repeat 14 ms (median of five); the
//! identical projection with the style removed takes 9 ms. So the style costs
//! 20 ms once and 5 ms on every repeat — the shape build and the coverage
//! compare, not a re-blur, which is the whole claim. Two styled groups cannot
//! collide because each group entry owns a PRIVATE 1x1 `Arc` (never a shared
//! constant); `style_cache.rs` pins that.

use std::borrow::Cow;
use std::cell::Cell;
use std::ops::Range;
use std::sync::Arc;

use image::{GrayImage, Luma};

use crate::blend::BlendMode;
use crate::doc::{
    composite_clip_group_into, quantize, sane_opacity, Layer, LayerKind, RzDocument, MAX_PIXELS,
};
use crate::style_composite::{merge_extent, style_grown, CompositeEnv};

/// Deepest permitted nesting. Photoshop's own practical ceiling is 10, so no
/// real document or PSD is refused by it. It bounds the compositor's
/// RECURSION (a crafted `.rz` must not overflow the stack). It does NOT bound
/// the compositor's ALLOCATION — see [`MAX_GROUP_BUFFER_PIXELS`], which is the
/// check that does, and the module doc for why a depth cap cannot.
pub const MAX_GROUP_DEPTH: u16 = 10;

/// f32-accumulator pixels an isolated-group nest may hold LIVE AT ONCE.
/// `MAX_PIXELS` (100M) is the canvas ceiling; four canvases is the ceiling for
/// the buffers alive together, mirroring how `doc_channel::channels_fit`
/// bounds a document's channel memory. At the per-level costs in the module
/// doc this caps one projection's group buffers at roughly 8 GB in the worst
/// styled clip-base shape and 6.4 GB in the plain isolated shape — bounded,
/// and far above anything a real document reaches.
///
/// It is a PEAK, not a running total: [`rendered_group`] charges the budget
/// before its `vec!` and RELEASES the charge once that buffer is dropped, so
/// what the cap bounds is the memory a nest holds simultaneously — which is
/// what it exists to bound. Charging cumulatively instead would count sibling
/// groups that never coexist in memory and would silently drop every isolated
/// group past the fourth canvas of total WORK, from the projection and from
/// every export alike, on documents whose memory was never at risk (this
/// app's layers are canvas-sized, so a group's extent is routinely the whole
/// canvas, and a 24 MP composite would lose its seventeenth group).
pub const MAX_GROUP_BUFFER_PIXELS: u64 = 4 * MAX_PIXELS;

// ------------------------------------------------------------- the layout --

/// One entry of a level together with the descendants that belong to it: the
/// entry sits at `idx` and its children occupy `start..idx` (`start == idx`
/// for a leaf and for an empty group).
#[derive(Clone, Copy, Debug)]
pub(crate) struct Unit {
    pub start: usize,
    pub idx: usize,
}

/// The units of the level spanning `range` at `depth`, bottom-first. One
/// forward scan, no allocation per entry.
pub(crate) fn units(layers: &[Layer], range: Range<usize>, depth: u16) -> Vec<Unit> {
    let mut out = Vec::new();
    let mut start = range.start;
    for i in range {
        if layers[i].depth == depth {
            out.push(Unit { start, idx: i });
            start = i + 1;
        }
    }
    out
}

/// The whole document's top level.
pub(crate) fn top_level(layers: &[Layer]) -> Vec<Unit> {
    units(layers, 0..layers.len(), 0)
}

/// `layers[idx]`'s subtree as a half-open range, `start..idx + 1`. `end` is
/// exactly where a new sibling inserted "above" this entry lands. An
/// out-of-range `idx` yields the empty range `idx..idx`, so callers that have
/// already validated the index pay nothing and the rest cannot panic.
pub(crate) fn subtree(layers: &[Layer], idx: usize) -> Range<usize> {
    let Some(entry) = layers.get(idx) else {
        return idx..idx;
    };
    let depth = entry.depth;
    let mut start = idx;
    while start > 0 && layers[start - 1].depth > depth {
        start -= 1;
    }
    start..idx + 1
}

/// The index of `idx`'s enclosing group, or `None` at the top level. In a
/// valid forest the first entry ABOVE `idx` at a shallower depth is that
/// group, because a group's own record closes its children's run.
pub(crate) fn parent(layers: &[Layer], idx: usize) -> Option<usize> {
    let depth = layers.get(idx)?.depth;
    if depth == 0 {
        return None;
    }
    layers[idx + 1..]
        .iter()
        .position(|l| l.depth < depth)
        .map(|offset| idx + 1 + offset)
}

/// The ONE structural check: `false` for any malformed depth sequence (a child
/// with no enclosing group, a leaf closing a non-empty run, a depth past the
/// cap, a last entry not at depth 0). An EMPTY stack is vacuously valid —
/// "at least one entry" is a separate invariant the removal ops enforce.
///
/// This is a HARD RUNTIME CHECK, deliberately not a `debug_assert!`; the
/// module doc says why, and [`validated`] is how every op applies it.
pub(crate) fn validate_structure(layers: &[Layer]) -> bool {
    if layers.iter().any(|l| l.depth > MAX_GROUP_DEPTH) {
        return false;
    }
    valid_level(layers, 0..layers.len(), 0)
}

/// One level of [`validate_structure`]'s scan. Recursion is bounded by
/// `MAX_GROUP_DEPTH`, which the caller has already checked against every
/// entry, so this cannot run away on a crafted file.
fn valid_level(layers: &[Layer], range: Range<usize>, depth: u16) -> bool {
    let end = range.end;
    let mut start = range.start;
    for i in range {
        let entry_depth = layers[i].depth;
        if entry_depth < depth {
            return false; // an entry shallower than the level it sits in
        }
        if entry_depth == depth {
            if start < i {
                // A non-empty run belongs to this entry: only a group may
                // close one, and the run must itself be a valid level.
                if layers[i].kind != LayerKind::Group || !valid_level(layers, start..i, depth + 1) {
                    return false;
                }
            }
            start = i + 1;
        }
    }
    // Anything left after the last entry AT this depth is a child with no
    // enclosing group — the silent-data-loss shape the module doc names.
    start == end
}

/// `doc` when its structure is well formed, `None` when it is not — the three
/// lines every structural op ends with, so a malformed result is a NO-OP
/// rather than a corrupt document or a panic.
pub(crate) fn validated(doc: RzDocument) -> Option<RzDocument> {
    validate_structure(&doc.layers).then_some(doc)
}

/// The half-open range of the LEVEL entry `idx` sits in: its enclosing
/// group's children at any depth, the whole stack at the top level. The one
/// derivation of "which entries are this entry's siblings", shared by
/// `merging_down`, `arrange_layer` and `merge_layers`.
pub(crate) fn level_range(layers: &[Layer], idx: usize) -> Range<usize> {
    match parent(layers, idx) {
        Some(group) => subtree(layers, group).start..group,
        None => 0..layers.len(),
    }
}

/// Moves the subtree `sub` so that it sits at index `at` in the stack with
/// that subtree ALREADY TAKEN OUT, re-basing every moved entry's depth by
/// `shift`. This is the ONE splice every structural move performs: each op
/// brings its own POLICY — `move_layer_to` the depth the caller asked for,
/// `doc_structure::arrange_layer` the rule that a sibling reorder never
/// leaves its level — and none of them owns a second copy of the move.
///
/// `None` when the shift would take a depth outside `0..=MAX_GROUP_DEPTH`
/// (which catches a negative shift as well as too deep a nest) or when the
/// result would be malformed, so a bad `(at, shift)` pair is a no-op rather
/// than a corrupt document.
pub(crate) fn relocated(
    doc: &RzDocument,
    sub: Range<usize>,
    at: usize,
    shift: i32,
) -> Option<RzDocument> {
    let mut out = doc.clone();
    let mut block: Vec<Layer> = out.layers.drain(sub).collect();
    for layer in &mut block {
        let depth = i32::from(layer.depth).checked_add(shift)?;
        if !(0..=i32::from(MAX_GROUP_DEPTH)).contains(&depth) {
            return None;
        }
        layer.depth = depth as u16;
    }
    let at = at.min(out.layers.len());
    out.layers.splice(at..at, block);
    validated(out)
}

// ---------------------------------------------------------- the compositor --

/// A group renders ISOLATED — into a private buffer, composited once — when
/// anything about it needs its own RENDERED PIXELS or its own footprint.
/// Otherwise it is PASS THROUGH and its children composite straight onto the
/// enclosing accumulator, which is the only way an adjustment layer inside it
/// can reach the layers below the group. A group whose blend mode is NORMAL is
/// isolated: Pass Through is a distinct mode, Photoshop's default for a new
/// group and the default this build creates. See the module doc for the
/// clipping cost the last two terms carry.
///
/// A group's own MASK and OPACITY are deliberately NOT here: they are a
/// per-pixel gate on what the children contributed, which
/// [`composite_gated_pass`] applies without leaving the pass-through path. See
/// the module doc for why isolating for them destroys the effect it means to
/// restrict.
///
/// `baseless` says the entry is the bottom-most of its level, so its `clipped`
/// flag has NO base to clip to and [`composite_level_into`] already composites
/// it as if unclipped. A flag the compositor ignores must not force isolation
/// either: otherwise setting a clipping mask that clips to nothing would
/// switch off an adjustment layer inside an otherwise pass-through group,
/// which is the opposite of what "composites as if unclipped" promises.
pub(crate) fn is_isolated(
    layer: &Layer,
    baseless: bool,
    has_visible_clipped_members: bool,
) -> bool {
    layer.blend != BlendMode::PassThrough
        || layer.renders_style().is_some()
        || (layer.clipped && !baseless)
        || has_visible_clipped_members
}

/// The canvas rect `(x0, y0, x1, y1)` (exclusive) a group's children can write
/// into: the union of `style_composite::merge_extent` over its visible LEAF
/// descendants — "pixel rect grown by the style's pad, plus the drop shadow's
/// shifted rect" — with each nested GROUP's own subtree rect grown the SAME
/// way by that group's style (`style_composite::style_grown`), since a styled
/// group's effects are drawn into this level's buffer and would otherwise be
/// clipped off at the leaf rects. `None` when nothing visible is inside — such
/// a group contributes nothing.
///
/// An unmasked ADJUSTMENT descendant needs no extra room: an adjustment never
/// touches a transparent pixel, and inside the group only its siblings'
/// extents are non-transparent.
///
/// Sizing the buffer to the group's own extent rather than the whole
/// accumulator keeps a group's cost proportional to its content, and costs
/// nothing extra — `composite_layer_into` already takes an arbitrary origin
/// and size. It does NOT bound the worst case, because a full-canvas leaf
/// makes every enclosing extent full-canvas; [`MAX_GROUP_BUFFER_PIXELS`] does.
fn group_extent(layers: &[Layer], u: Unit, env: CompositeEnv<'_>) -> Option<(i64, i64, i64, i64)> {
    let depth = layers.get(u.idx)?.depth.saturating_add(1);
    let mut out = None;
    extent_of_level(layers, u.start..u.idx, depth, env, &mut out);
    out
}

fn extent_of_level(
    layers: &[Layer],
    range: Range<usize>,
    depth: u16,
    env: CompositeEnv<'_>,
    out: &mut Option<(i64, i64, i64, i64)>,
) {
    for unit in units(layers, range, depth) {
        let entry = &layers[unit.idx];
        if !entry.visible {
            continue; // an invisible entry hides its whole subtree
        }
        let rect = match entry.kind {
            LayerKind::Raster => merge_extent(entry, env),
            LayerKind::Group => {
                // The child group's own subtree FIRST, into a fresh option,
                // because a styled group's effects reach outside it exactly
                // as a styled layer's reach outside its pixel rect — and
                // `rendered_group` will draw them into THIS level's buffer.
                // Recursing straight into `out` would union the leaf rects
                // alone and clip the inner group's drop shadow, outer glow
                // and outside stroke away the moment this level isolates.
                let mut sub = None;
                extent_of_level(layers, unit.start..unit.idx, depth + 1, env, &mut sub);
                let Some(sub) = sub else { continue };
                match entry.renders_style() {
                    Some(style) => style_grown(sub, style, env),
                    None => sub,
                }
            }
        };
        *out = Some(match *out {
            None => rect,
            Some(o) => (
                o.0.min(rect.0),
                o.1.min(rect.1),
                o.2.max(rect.2),
                o.3.max(rect.3),
            ),
        });
    }
}

/// The ONE group-materialization function: entry `u` rendered into a private
/// buffer over its own extent (clipped to `clip`, the enclosing accumulator's
/// canvas rect `(x, y, w, h)`) and wrapped as a synthetic raster `Layer`
/// carrying the group's name, opacity, blend mode, cropped mask, style and
/// clipped flag.
///
/// `None` when the entry is not a group, when nothing visible is inside it,
/// when the recursion is past [`MAX_GROUP_DEPTH`], or when the buffer would
/// pass [`MAX_GROUP_BUFFER_PIXELS`] — all four mean "contributes nothing",
/// which is exactly what an empty group means.
///
/// The budget charge is RELEASED before returning, once the f32 buffer has
/// been quantized and dropped: the cap bounds the buffers a nest holds at
/// once, so nesting is what spends it and a sequence of sibling groups is
/// not (see [`MAX_GROUP_BUFFER_PIXELS`]).
pub(crate) fn rendered_group(
    layers: &[Layer],
    u: Unit,
    env: CompositeEnv<'_>,
    clip: (i32, i32, u32, u32),
    depth: u16,
    budget: &Cell<u64>,
) -> Option<Layer> {
    let entry = layers.get(u.idx)?;
    if entry.kind != LayerKind::Group || depth >= MAX_GROUP_DEPTH {
        return None;
    }
    let (ex0, ey0, ex1, ey1) = group_extent(layers, u, env)?;
    let cx0 = i64::from(clip.0);
    let cy0 = i64::from(clip.1);
    let x0 = ex0.max(cx0);
    let y0 = ey0.max(cy0);
    let x1 = ex1.min(cx0 + i64::from(clip.2));
    let y1 = ey1.min(cy0 + i64::from(clip.3));
    if x1 <= x0 || y1 <= y0 {
        return None;
    }
    let (w, h) = ((x1 - x0) as u64, (y1 - y0) as u64);
    // Charged BEFORE the allocation: a refused group contributes nothing
    // rather than aborting the process on a failed `vec!`. Released below,
    // once the buffer is gone.
    let pixels = w.checked_mul(h)?;
    let charged = budget.get().checked_add(pixels)?;
    if charged > MAX_GROUP_BUFFER_PIXELS {
        return None;
    }
    budget.set(charged);
    let mut buf = vec![[0.0f32; 4]; pixels as usize];
    // `x0` lies inside `clip`, whose origin is an i32, so this cannot wrap.
    let origin = (x0 as i32, y0 as i32);
    let children = units(layers, u.start..u.idx, entry.depth.saturating_add(1));
    composite_level_into(
        &mut buf,
        w as u32,
        h as u32,
        origin,
        layers,
        &children,
        env,
        depth + 1,
        budget,
    );
    let quantized = quantize(&buf, w as u32, h as u32);
    drop(buf);
    // The charge is a PEAK: this level's accumulator is gone, so the room it
    // took is available to the sibling that composites next. What the cap
    // bounds is a NEST's simultaneous allocations, never a projection's total
    // work.
    budget.set(budget.get().saturating_sub(pixels));
    // The group's mask is CANVAS-sized; the synthetic layer's must be its own
    // size, which is what makes `Layer::active_mask` and every mask site below
    // work on it unchanged.
    let mask = entry
        .mask
        .as_deref()
        .filter(|_| entry.mask_enabled)
        .map(|m| Arc::new(cropped_mask(m, entry.offset, x0, y0, w as u32, h as u32)));
    Some(Layer {
        pixels: Arc::new(quantized),
        offset: origin,
        name: entry.name.clone(),
        opacity: entry.opacity,
        // Reachable only when something else forced isolation, and then the
        // group composites as an ordinary Normal layer.
        blend: if entry.blend.is_group_only() {
            BlendMode::Normal
        } else {
            entry.blend
        },
        visible: true,
        mask,
        mask_enabled: true,
        // A group is never an adjustment layer: the core never interprets a
        // group's meta, so the synthetic layer carries none.
        meta: None,
        clipped: entry.clipped,
        style: entry.style.clone(),
        kind: LayerKind::Raster,
        depth: 0,
        locks: 0,
        link: 0,
        open: true,
    })
}

/// The `w` x `h` window of a CANVAS-sized mask whose top-left sits at
/// `(x0, y0)`. Pixels outside the mask read 0 — hidden, which is the safe
/// answer for a mask and is only reachable defensively (the extent is always
/// inside the canvas).
///
/// `mask_origin` is where the plane itself sits on the canvas: a group's mask
/// TRAVELS WITH THE GROUP as bookkeeping on the group's offset rather than as
/// a resample per move (`doc_align::translate_entry`), so the window is taken
/// relative to that origin. It is (0, 0) for a mask that has never moved.
fn cropped_mask(
    mask: &GrayImage,
    mask_origin: (i32, i32),
    x0: i64,
    y0: i64,
    w: u32,
    h: u32,
) -> GrayImage {
    let (mw, mh) = mask.dimensions();
    let (ox, oy) = (i64::from(mask_origin.0), i64::from(mask_origin.1));
    GrayImage::from_fn(w, h, |x, y| {
        let mx = x0 - ox + i64::from(x);
        let my = y0 - oy + i64::from(y);
        if mx < 0 || my < 0 || mx >= i64::from(mw) || my >= i64::from(mh) {
            return Luma([0]);
        }
        *mask.get_pixel(mx as u32, my as u32)
    })
}

/// Entry `idx` as a `Layer` the pixel ops can use: a raster entry cloned, a
/// group RENDERED over the whole canvas through [`rendered_group`]. `None`
/// for an out-of-range index and for a group with nothing visible in it.
///
/// This is what makes Merge Down work across a group boundary: a pass-through
/// group materialized here is composited as a unit, exactly as Photoshop
/// rasterizes a group it merges.
pub(crate) fn materialized(
    layers: &[Layer],
    idx: usize,
    env: CompositeEnv<'_>,
    budget: &Cell<u64>,
) -> Option<Layer> {
    let entry = layers.get(idx)?;
    if entry.kind == LayerKind::Raster {
        return Some(entry.clone());
    }
    let (cw, ch) = env.canvas;
    let start = subtree(layers, idx).start;
    rendered_group(
        layers,
        Unit { start, idx },
        env,
        (0, 0, cw, ch),
        entry.depth,
        budget,
    )
}

/// Composites one LEVEL of the stack onto `acc`. `level` holds the level's
/// sibling entries bottom-first. The clip run is re-derived positionally
/// WITHIN THIS LEVEL — a clipped entry clips to the first unclipped SIBLING
/// below it, never across a group boundary, and a clipped entry at the bottom
/// of its level is baseless and composites as if unclipped (today's rule, now
/// stated at every level). `depth` bounds the recursion; `budget` bounds the
/// allocation.
///
/// With every entry at depth 0 and kind Raster this performs exactly the
/// statements the pre-groups projection loop performed, in the same order,
/// with the same arguments — which is what makes a document with no groups
/// composite byte-identically.
#[allow(clippy::too_many_arguments)]
pub(crate) fn composite_level_into(
    acc: &mut [[f32; 4]],
    acc_w: u32,
    acc_h: u32,
    origin: (i32, i32),
    layers: &[Layer],
    level: &[Unit],
    env: CompositeEnv<'_>,
    depth: u16,
    budget: &Cell<u64>,
) {
    if depth > MAX_GROUP_DEPTH {
        return;
    }
    let mut i = 0;
    while i < level.len() {
        let unit = level[i];
        let entry = &layers[unit.idx];
        if entry.clipped {
            // Only reachable at the bottom of a level (a clipped entry above a
            // base is consumed by that base's run below): baseless, so it
            // composites as if unclipped — including, via `baseless: true`,
            // for the isolation decision a group entry makes.
            if entry.visible {
                composite_unit_into(
                    acc,
                    acc_w,
                    acc_h,
                    origin,
                    layers,
                    unit,
                    &[],
                    true,
                    env,
                    depth,
                    budget,
                );
            }
            i += 1;
            continue;
        }
        let mut end = i + 1;
        while end < level.len() && layers[level[end].idx].clipped {
            end += 1;
        }
        if entry.visible {
            composite_unit_into(
                acc,
                acc_w,
                acc_h,
                origin,
                layers,
                unit,
                &level[i + 1..end],
                false,
                env,
                depth,
                budget,
            );
        }
        i = end;
    }
}

/// One clip unit of a level: the (visible) base `unit` and the run of clipped
/// entries `members` above it. `baseless` is true only for a CLIPPED entry at
/// the bottom of its level, whose clip flag has no base to act on and is
/// therefore ignored here as well as by [`is_isolated`].
#[allow(clippy::too_many_arguments)]
fn composite_unit_into(
    acc: &mut [[f32; 4]],
    acc_w: u32,
    acc_h: u32,
    origin: (i32, i32),
    layers: &[Layer],
    unit: Unit,
    members: &[Unit],
    baseless: bool,
    env: CompositeEnv<'_>,
    depth: u16,
    budget: &Cell<u64>,
) {
    let entry = &layers[unit.idx];
    let has_visible_clipped_members = members.iter().any(|m| layers[m.idx].visible);
    if entry.kind == LayerKind::Group && !is_isolated(entry, baseless, has_visible_clipped_members)
    {
        // PASS THROUGH: the children composite straight onto this accumulator
        // at this origin, so an adjustment layer inside the group sees the
        // document backdrop. `is_isolated` guarantees no visible clipped
        // member is waiting on this group's footprint, so nothing is lost by
        // never materializing it.
        let children = units(layers, unit.start..unit.idx, entry.depth.saturating_add(1));
        let opacity = sane_opacity(entry.opacity);
        let mask = entry
            .mask
            .as_deref()
            .filter(|_| entry.mask_enabled)
            .map(|m| (m, entry.offset));
        if opacity >= 1.0 && mask.is_none() {
            composite_level_into(
                acc,
                acc_w,
                acc_h,
                origin,
                layers,
                &children,
                env,
                depth + 1,
                budget,
            );
            return;
        }
        // A gate of zero everywhere: the children would be lerped all the way
        // back out, so skip the copy and the recursion entirely.
        if opacity > 0.0 {
            composite_gated_pass(
                acc, acc_w, acc_h, origin, layers, &children, env, depth, budget, mask, opacity,
            );
        }
        return;
    }
    let clip = (origin.0, origin.1, acc_w, acc_h);
    let base = match entry.kind {
        LayerKind::Raster => Cow::Borrowed(entry),
        LayerKind::Group => {
            match rendered_group(layers, unit, env, clip, depth, budget) {
                Some(rendered) => Cow::Owned(rendered),
                // Nothing visible inside, or the budget refused it: the whole
                // unit contributes nothing, since its clipped members are
                // confined to a footprint that does not exist.
                None => return,
            }
        }
    };
    let resolved: Vec<Layer> = members
        .iter()
        .map(|&m| resolved_member(layers, m, env, clip, depth, budget))
        .collect();
    composite_clip_group_into(acc, acc_w, acc_h, origin, &base, &resolved, env);
}

/// A PASS-THROUGH group that also carries a mask or an opacity below 1: its
/// children composite onto a COPY of the enclosing accumulator — the real
/// backdrop, which is what keeps an adjustment layer inside working — and the
/// result is lerped back per pixel by `mask/255 * opacity`.
///
/// The two exact ends matter and are written as branches rather than left to
/// the lerp's arithmetic: at coverage 1 the composited pixel is taken
/// VERBATIM, so an all-white mask at opacity 1 is byte-identical to no mask at
/// all (`a + (b - a) * 1.0` rounds twice and can land one ULP off `b`); at
/// coverage 0 the accumulator is not written at all.
///
/// In between, the mix is PREMULTIPLIED, which is the whole subtlety. The
/// accumulator holds STRAIGHT colour beside its alpha (`crate::doc::quantize`
/// and `composite_adjustment_into` both read it that way), and lerping a
/// straight colour toward a different alpha is wrong: an opaque red child in a
/// half-opacity group over a TRANSPARENT backdrop would come out as half-dark
/// red at alpha 0.5 instead of red at alpha 0.5, because the backdrop's
/// meaningless black would be mixed in as if it were a colour. Weighting each
/// colour by its own alpha first, mixing, and dividing the result back out is
/// the same arithmetic source-over does and gives red. Where the alphas agree
/// — an adjustment layer over an opaque backdrop, the case this fix exists for
/// — the division is by 1 and the two forms are bit-identical.
///
/// Contributes nothing when the copy would pass [`MAX_GROUP_BUFFER_PIXELS`],
/// the same in-band answer [`rendered_group`] gives, and releases the charge
/// as soon as the copy is dropped.
#[allow(clippy::too_many_arguments)]
fn composite_gated_pass(
    acc: &mut [[f32; 4]],
    acc_w: u32,
    acc_h: u32,
    origin: (i32, i32),
    layers: &[Layer],
    children: &[Unit],
    env: CompositeEnv<'_>,
    depth: u16,
    budget: &Cell<u64>,
    mask: Option<(&GrayImage, (i32, i32))>,
    opacity: f32,
) {
    let pixels = acc.len() as u64;
    let Some(charged) = budget.get().checked_add(pixels) else {
        return;
    };
    if charged > MAX_GROUP_BUFFER_PIXELS {
        return;
    }
    budget.set(charged);
    let mut buf = acc.to_vec();
    composite_level_into(
        &mut buf,
        acc_w,
        acc_h,
        origin,
        layers,
        children,
        env,
        depth + 1,
        budget,
    );
    // The group's mask is CANVAS-sized; this window of it lines up with the
    // accumulator index for index, through the one crop `rendered_group` uses.
    let window = mask.map(|(m, mask_origin)| {
        cropped_mask(
            m,
            mask_origin,
            i64::from(origin.0),
            i64::from(origin.1),
            acc_w,
            acc_h,
        )
    });
    for (i, out) in acc.iter_mut().enumerate() {
        let coverage = window
            .as_ref()
            .map_or(1.0, |w| f32::from(w.as_raw()[i]) / 255.0);
        let t = coverage * opacity;
        if t <= 0.0 {
            continue;
        }
        if t >= 1.0 {
            *out = buf[i];
            continue;
        }
        let (a0, a1) = (out[3], buf[i][3]);
        let a = a0 + (a1 - a0) * t;
        if a <= 0.0 {
            *out = [0.0; 4];
            continue;
        }
        for c in 0..3 {
            let (p0, p1) = (out[c] * a0, buf[i][c] * a1);
            out[c] = (p0 + (p1 - p0) * t) / a;
        }
        out[3] = a;
    }
    drop(buf);
    budget.set(budget.get().saturating_sub(pixels));
}

/// One clipped MEMBER of a clip run, resolved to a `Layer`.
///
/// Every member is kept POSITIONALLY, visible or not. This is load-bearing for
/// byte-identity on a document with NO groups at all: the pre-groups walk
/// handed `composite_clip_group_into` the whole run, invisible members
/// included, and that function's `group.is_empty()` early-out is what chooses
/// between the private-buffer path and the direct `composite_layer_into` path.
/// The two are NOT equivalent for an adjustment-meta base — an adjustment base
/// has no pixel footprint in a transparent buffer, so a non-empty group over
/// one contributes nothing. If resolution dropped invisible members (the
/// natural reading, since [`rendered_group`] returns `None` for a group with
/// nothing visible), an adjustment layer that is a clip base with only
/// invisible clipped layers above it would flip from contributing nothing to
/// applying to the whole backdrop — a visible regression on a document with no
/// groups in it. So an invisible LEAF member is cloned unchanged
/// (`composite_clip_group_into` already filters on `visible`), and a group
/// member that is invisible or renders to nothing is kept as an INVISIBLE
/// placeholder without being rendered.
fn resolved_member(
    layers: &[Layer],
    unit: Unit,
    env: CompositeEnv<'_>,
    clip: (i32, i32, u32, u32),
    depth: u16,
    budget: &Cell<u64>,
) -> Layer {
    let entry = &layers[unit.idx];
    if entry.kind == LayerKind::Raster {
        return entry.clone();
    }
    let rendered = entry
        .visible
        .then(|| rendered_group(layers, unit, env, clip, depth, budget))
        .flatten();
    rendered.unwrap_or_else(|| Layer {
        visible: false,
        ..entry.clone()
    })
}
