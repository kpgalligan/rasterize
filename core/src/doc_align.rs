//! Moving a SET of entries: the link groups that decide who comes along, the
//! translate and the affine every Move-tool drag and Free Transform commit
//! folds into one call, and align / distribute over a selection.
//!
//! `doc_structure` holds the ops that change the SHAPE of the stack; this file
//! is its sibling for the ops that change where entries SIT, which is where
//! that module's size budget sent them. `doc_group_query` owns the two queries
//! both rest on — `layer_bounds` (the CONTENT box) and `expanded_set`.
//!
//! # One call, one document
//!
//! Every op here takes the whole set and is ALL-OR-NOTHING: a host that
//! looped would pay a document clone per entry and, worse, would leave the
//! document half-moved when one member refused. The set is expanded by
//! SUBTREE (moving a group moves its children) and then by LINK GROUP, and a
//! POSITION lock anywhere in the expanded set refuses the whole call, because
//! a partial move of a linked set is exactly what linking exists to prevent.
//!
//! # Links
//!
//! `Layer::link` is a group id, 0 for unlinked. Ids are the SMALLEST unused
//! non-zero value rather than a counter, so a save round trip is
//! byte-identical; `Channel::id`'s atomic counter is right there for the
//! opposite reason — it is never persisted.
//!
//! # A group's mask travels as bookkeeping
//!
//! A group has no pixel buffer, so its `offset` positions its CANVAS-sized
//! MASK instead: a translate adds to that offset and never touches the plane.
//! Composing resamples of a canvas plane is lossy in both directions, so the
//! plane is shifted exactly once, by [`baked_group_masks`], when an op finally
//! needs the mask as a canvas plane. See [`translate_entry`].
//!
//! Link fan-out is a property of the two ops that MEAN "move this"
//! ([`RzDocument::move_layers`] and [`RzDocument::transform_layers`]), never a
//! hidden behaviour of a setter: `with_layer_offset` writes one entry's
//! offset and is what paste and `set_layer_properties` use.
//!
//! Align and distribute expand each entry's delta the same way, so links
//! follow there too — through [`RzDocument::moved_once`], which applies ONE
//! delta per entry rather than looping `move_layers`. The consequence, which
//! is Photoshop's: aligning entries that are LINKED TO EACH OTHER moves each
//! one's whole link group, so the members travel as a rigid body and the last
//! delta applied is the one that sticks. Link a set or align it, not both.
//! ("Sticks" is now literally true: chaining `move_layers` calls ADDED the
//! deltas instead, so an entry two members reached travelled twice as far.)
//!
//! # The gate
//!
//! Every op here ends in `doc_group::validated`, exactly as the ops that DO
//! change the shape of the stack do. None of these can break the depth
//! sequence today — they write offsets, pixels and link ids — and that is
//! precisely why the gate is uniform rather than reasoned about per op: one
//! O(n) scan on a call that already cloned the document is far cheaper than
//! the day someone teaches one of them to move an entry and the check is not
//! there. See `doc_group`'s module doc for why it is a runtime check.

use std::sync::Arc;

use image::imageops::FilterType;

use crate::doc::{saturating_i32, Layer, LayerKind, RzDocument};
use crate::doc_channel::padded_plane;
use crate::doc_group::validated;
use crate::doc_group_query::{expanded_set, next_link_id};
use crate::doc_lock::EditKind;
use crate::doc_structure::independent_roots;
use crate::doc_transform::{resample_canvas_plane, Affine};

/// Which edge of the reference rect an alignment lines entries up on. Mirrors
/// `RzAlign` in the C header.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
#[repr(i32)]
pub enum AlignEdge {
    /// Left edges together.
    Left = 0,
    /// Horizontal centres together.
    CenterX = 1,
    /// Right edges together.
    Right = 2,
    /// Top edges together.
    Top = 3,
    /// Vertical centres together.
    CenterY = 4,
    /// Bottom edges together.
    Bottom = 5,
}

impl AlignEdge {
    /// Maps a raw `RzAlign` value coming across the FFI.
    pub fn from_c(value: i32) -> Option<Self> {
        match value {
            0 => Some(AlignEdge::Left),
            1 => Some(AlignEdge::CenterX),
            2 => Some(AlignEdge::Right),
            3 => Some(AlignEdge::Top),
            4 => Some(AlignEdge::CenterY),
            5 => Some(AlignEdge::Bottom),
            _ => None,
        }
    }

    /// Whether this edge moves an entry along the Y axis.
    fn vertical(self) -> bool {
        matches!(
            self,
            AlignEdge::Top | AlignEdge::CenterY | AlignEdge::Bottom
        )
    }
}

impl RzDocument {
    /// Translates every given entry by `(dx, dy)` — the ONE move-a-set op, so
    /// the Move tool, the arrow-key nudge and align / distribute all go
    /// through it and all follow subtrees and link groups the same way.
    ///
    /// `None` for an empty or out-of-range set, a zero delta (the core's no-op
    /// rule), a POSITION lock anywhere in the expanded set, and a set that
    /// resolves to groups alone — a group has no pixel rect of its own, so
    /// moving one means moving its raster descendants, and a group with none
    /// has nothing to move.
    pub fn move_layers(&self, idx: &[usize], dx: i32, dy: i32) -> Option<Self> {
        if dx == 0 && dy == 0 {
            return None;
        }
        let set = self.movable_set(idx)?;
        let mut doc = self.clone();
        let mut moved = false;
        for &i in &set {
            moved |= translate_entry(&mut doc.layers, i, dx, dy);
        }
        moved.then_some(doc).and_then(validated)
    }

    /// One delta per ROOT, applied so that every entry moves EXACTLY ONCE —
    /// what align and distribute need and what a chain of
    /// [`Self::move_layers`] calls does not give them.
    ///
    /// Each root is expanded the way `move_layers` expands a set (by subtree,
    /// then by link group) and stakes a claim on every entry it reaches; the
    /// LAST root to claim an entry is the delta that entry takes, which is
    /// what this module's doc has always promised. Looping `move_layers`
    /// instead ADDS the deltas: a selection holding a group and one of its own
    /// children moved that child by its own delta and again by the group's, so
    /// a left-align pushed it off the canvas rather than onto the edge.
    ///
    /// The offsets are written directly, through the same `translate_entry`
    /// the plain move uses, so there is still one definition of what moving an
    /// entry does. `None` when nothing moved.
    fn moved_once(&self, deltas: &[(usize, i32, i32)]) -> Option<Self> {
        let mut claimed: Vec<Option<(i32, i32)>> = vec![None; self.layers.len()];
        for &(root, dx, dy) in deltas {
            if dx == 0 && dy == 0 {
                continue;
            }
            for i in expanded_set(&self.layers, &[root]) {
                claimed[i] = Some((dx, dy));
            }
        }
        let mut doc = self.clone();
        let mut moved = false;
        for (i, delta) in claimed.iter().enumerate() {
            let Some((dx, dy)) = *delta else { continue };
            moved |= translate_entry(&mut doc.layers, i, dx, dy);
        }
        moved.then_some(doc).and_then(validated)
    }

    /// The same affine applied to every given entry, each deriving its own
    /// destination extent through [`RzDocument::transform_layer`] — one
    /// matrix, N layers, and all-or-nothing: the first entry that refuses (an
    /// empty destination extent, an offset outside the i32 range, a
    /// destination past the pixel cap) refuses the whole call, so a Free
    /// Transform over a selection never lands on half of it.
    ///
    /// A GROUP has no pixels to resample; what follows the matrix is its
    /// CANVAS-sized mask, which rides `resample_canvas_plane` — the channel
    /// path — and not the layer-mask path, which would resample it to the 1x1
    /// dummy's new size and destroy it. Its raster descendants are in the
    /// expanded set and transform on their own.
    ///
    /// Same refusals as [`RzDocument::move_layers`] for the set itself.
    pub fn transform_layers(&self, idx: &[usize], m: Affine, filter: FilterType) -> Option<Self> {
        let set = self.movable_set(idx)?;
        self.transformed_entries(&set, m, filter)
    }

    /// The WHOLE stack resampled by one matrix: the Crop tool's straighten,
    /// and the agent `crop` tool's.
    ///
    /// Deliberately NOT gated by per-entry POSITION locks. Straightening is a
    /// document GEOMETRY op, in the same family as [`RzDocument::crop`],
    /// `geometry`, `canvas_resize` and `resize`, not one of which consults a
    /// layer lock: a position lock says "do not move this layer WITHIN the
    /// picture", and re-framing the picture moves nothing within it. Routing
    /// the straighten through [`Self::transform_layers`] instead made ONE
    /// locked layer — the background, which is the layer a Photoshop user
    /// locks by habit — refuse an entire document-wide crop, with no way for
    /// the host to explain it and no matching refusal from the four ops beside
    /// it.
    ///
    /// `None` on the same per-entry refusals [`Self::transform_layers`] has
    /// (an empty destination extent, an offset outside the i32 range, a
    /// destination past the pixel cap) and when nothing would change at all.
    pub fn straighten_layers(&self, m: Affine, filter: FilterType) -> Option<Self> {
        let set: Vec<usize> = (0..self.layers.len()).collect();
        self.transformed_entries(&set, m, filter)
    }

    /// The body both transforms share: `set` is already the entries to write,
    /// and the lock policy has already been decided by whoever built it.
    ///
    /// A raster entry goes through `transform_layer_unlocked` rather than
    /// `transform_layer` because the gate belongs to the SET, not to the
    /// entry: `transform_layers` asked `movable_set` all-or-nothing before the
    /// first pixel moved, and `straighten_layers` is exempt by design. Asking
    /// again per entry would be a second lock policy in a file whose whole
    /// point is that there is one.
    ///
    /// `None` when nothing was written — an empty group (which PSD import and
    /// a crafted `.rz` both produce) has no pixels to resample and no mask to
    /// warp, and returning an identical copy for it would mint an undo step
    /// and dirty the document for an edit that moved nothing.
    fn transformed_entries(&self, set: &[usize], m: Affine, filter: FilterType) -> Option<Self> {
        // A group mask that has TRAVELLED rides an offset; the warp below
        // consumes it as a canvas plane, so flatten that offset in first.
        if let Some(baked) = baked_group_masks(self) {
            return baked.transformed_entries(set, m, filter);
        }
        let kinds: Vec<LayerKind> = set.iter().map(|&i| self.layers[i].kind).collect();
        let mut doc = self.clone();
        let mut changed = false;
        for (&i, &kind) in set.iter().zip(kinds.iter()) {
            match kind {
                LayerKind::Raster => {
                    doc = doc.transform_layer_unlocked(i, m, filter)?;
                    changed = true;
                }
                LayerKind::Group => {
                    if let Some(mask) = doc.layers[i].mask.as_deref() {
                        let warped = resample_canvas_plane(mask, &m, filter)?;
                        doc.layers[i].mask = Some(Arc::new(warped));
                        changed = true;
                    }
                }
            }
        }
        changed.then_some(doc).and_then(validated)
    }

    /// Aligns every given entry's CONTENT bounds ([`RzDocument::layer_bounds`])
    /// to `edge` of the reference rect: the UNION of the given entries' bounds
    /// (`to_canvas` false — Photoshop's behaviour with several layers
    /// selected) or the canvas.
    ///
    /// Content bounds, not the pixel rect: a photo-shaped layer on a
    /// canvas-sized buffer — what every paste, text layer and shape layer
    /// produces — has two different rectangles, and the one a person means is
    /// the opaque one. An entry with nothing opaque is skipped rather than
    /// aligned by a rect it does not really occupy.
    ///
    /// Moves through [`RzDocument::move_layers`], so subtrees and link groups
    /// follow and a POSITION lock refuses the whole call — asked UP FRONT
    /// here, not left to the per-entry moves below (see [`Self::movable_set`]).
    /// `None` when nothing would move, and when fewer than two entries have
    /// content while `to_canvas` is false — aligning one layer to itself is a
    /// no-op by definition.
    pub fn align_layers(&self, idx: &[usize], edge: AlignEdge, to_canvas: bool) -> Option<Self> {
        self.movable_set(idx)?;
        let boxes = self.content_boxes(idx)?;
        if !to_canvas && boxes.len() < 2 {
            return None;
        }
        let reference = if to_canvas {
            (0, 0, i64::from(self.width), i64::from(self.height))
        } else {
            boxes.iter().skip(1).fold(boxes[0].1, |acc, b| {
                (
                    acc.0.min(b.1 .0),
                    acc.1.min(b.1 .1),
                    acc.2.max(b.1 .2),
                    acc.3.max(b.1 .3),
                )
            })
        };
        let deltas: Vec<(usize, i32, i32)> = boxes
            .iter()
            .map(|&(i, rect)| {
                let delta = align_delta(edge, rect, reference);
                if edge.vertical() {
                    (i, 0, saturating_i32(delta))
                } else {
                    (i, saturating_i32(delta), 0)
                }
            })
            .collect();
        self.moved_once(&deltas)
    }

    /// Spaces the given entries evenly along one axis: the two OUTERMOST keep
    /// their positions and the gaps between adjacent CONTENT bounds are made
    /// equal — Photoshop's "distribute spacing", not "distribute centers".
    ///
    /// Needs at least three entries with content. The gap comes out negative
    /// when the content is wider than the span it has to fit into; that is
    /// arithmetic, not an error, and the entries simply overlap evenly.
    ///
    /// `None` for fewer than three entries with content, for the same set
    /// refusals as [`RzDocument::move_layers`] — the POSITION lock among them,
    /// asked UP FRONT (see [`Self::movable_set`]) — and when nothing would
    /// move (already evenly spaced).
    pub fn distribute_layers(&self, idx: &[usize], vertical: bool) -> Option<Self> {
        self.movable_set(idx)?;
        let boxes = self.content_boxes(idx)?;
        if boxes.len() < 3 {
            return None;
        }
        // (entry, start along the axis, size along the axis), ordered by
        // start; the index breaks a tie so the walk is deterministic.
        let mut spans: Vec<(usize, i64, i64)> = boxes
            .iter()
            .map(|&(i, (x0, y0, x1, y1))| {
                if vertical {
                    (i, y0, y1 - y0)
                } else {
                    (i, x0, x1 - x0)
                }
            })
            .collect();
        spans.sort_by_key(|&(i, start, _)| (start, i));
        let first = spans[0].1;
        let last = spans[spans.len() - 1];
        let span = last.1 + last.2 - first;
        let content: i64 = spans.iter().map(|&(_, _, size)| size).sum();
        let total_gap = span - content;
        let steps = (spans.len() - 1) as f64;
        let mut deltas: Vec<(usize, i32, i32)> = Vec::with_capacity(spans.len());
        let mut consumed = 0i64;
        for (k, &(i, start, size)) in spans.iter().enumerate() {
            // The k-th entry sits after every earlier entry's content plus its
            // exact share of the gap. Rounding the SHARE rather than the gap
            // keeps the last entry's target exactly where it already is, so
            // the two outermost never move by a rounding residue.
            let share = ((k as f64) * (total_gap as f64) / steps).round() as i64;
            let target = first + consumed + share;
            consumed += size;
            let delta = target - start;
            deltas.push(if vertical {
                (i, 0, saturating_i32(delta))
            } else {
                (i, saturating_i32(delta), 0)
            });
        }
        self.moved_once(&deltas)
    }

    /// Links the given entries: they take the SMALLEST unused non-zero link
    /// id, computed after their own old ids are cleared, so re-linking the
    /// same set is a no-op rather than a document that differs only in a
    /// number. An id left with a single member afterwards is cleared, since a
    /// link group of one is not a link.
    ///
    /// `None` for fewer than two entries, an out-of-range index, and when
    /// nothing would change.
    pub fn link_layers(&self, idx: &[usize]) -> Option<Self> {
        let set = self.index_set(idx)?;
        if set.len() < 2 {
            return None;
        }
        let mut doc = self.clone();
        for &i in &set {
            doc.layers[i].link = 0;
        }
        let id = next_link_id(&doc.layers);
        for &i in &set {
            doc.layers[i].link = id;
        }
        prune_lone_links(&mut doc.layers);
        changed_links(self, doc).and_then(validated)
    }

    /// Unlinks the given entries. An id left with a single member is cleared
    /// too, for the same reason [`RzDocument::link_layers`] clears one.
    /// `None` for an empty or out-of-range set and when nothing would change.
    pub fn unlink_layers(&self, idx: &[usize]) -> Option<Self> {
        let set = self.index_set(idx)?;
        let mut doc = self.clone();
        for &i in &set {
            doc.layers[i].link = 0;
        }
        prune_lone_links(&mut doc.layers);
        changed_links(self, doc).and_then(validated)
    }

    /// The given indices, deduplicated and ascending. `None` for an empty set
    /// and for any index past the end — a caller that named an entry that is
    /// not there has miscounted, and quietly doing less than it asked is worse
    /// than refusing.
    fn index_set(&self, idx: &[usize]) -> Option<Vec<usize>> {
        let mut set = idx.to_vec();
        set.sort_unstable();
        set.dedup();
        if set.is_empty() || *set.last()? >= self.layers.len() {
            return None;
        }
        Some(set)
    }

    /// [`Self::index_set`] expanded by subtree and link group, with the
    /// all-or-nothing POSITION lock check every move-a-set op makes.
    ///
    /// `align_layers` and `distribute_layers` call it for the CHECK alone,
    /// before computing a single delta, and discard the set they get back.
    /// They could not leave the check to the [`Self::move_layers`] calls they
    /// make per entry: an entry whose delta is zero — and a left-align always
    /// has at least one, the entry that DEFINES the reference edge — never
    /// reaches `move_layers` at all, and an entry with nothing opaque in it is
    /// skipped before that. Whether a position lock was honoured would then
    /// depend on invisible geometry rather than on the lock, and the promise
    /// both ops' doc comments make (and that the host repeats when it names
    /// the lock in a refusal) would be false exactly when a locked entry
    /// happened to already sit where the alignment wanted it.
    fn movable_set(&self, idx: &[usize]) -> Option<Vec<usize>> {
        let set = expanded_set(&self.layers, &self.index_set(idx)?);
        if set.is_empty() {
            return None;
        }
        if set
            .iter()
            .any(|&i| self.lock_block(i, EditKind::Position) != 0)
        {
            return None;
        }
        Some(set)
    }

    /// The given entries paired with their CONTENT boxes as
    /// `(x0, y0, x1, y1)` (exclusive), skipping every entry with nothing
    /// opaque in it. `None` when the set is empty or out of range, or when no
    /// entry in it has content at all.
    ///
    /// Reduced to `doc_structure::independent_roots` first — the same rule
    /// `duplicate_layers` and `remove_layers` apply — so an entry that sits
    /// inside another given entry's subtree is DROPPED rather than being given
    /// a delta of its own. Aligning a group already aligns its children, and
    /// giving a child a second delta on top of that is not a refinement, it is
    /// a double move.
    #[allow(clippy::type_complexity)]
    fn content_boxes(&self, idx: &[usize]) -> Option<Vec<(usize, (i64, i64, i64, i64))>> {
        let boxes: Vec<(usize, (i64, i64, i64, i64))> = independent_roots(&self.layers, idx)?
            .into_iter()
            .filter_map(|i| {
                let (x, y, w, h) = self.layer_bounds(i)?;
                Some((
                    i,
                    (
                        i64::from(x),
                        i64::from(y),
                        i64::from(x) + i64::from(w),
                        i64::from(y) + i64::from(h),
                    ),
                ))
            })
            .collect();
        (!boxes.is_empty()).then_some(boxes)
    }
}

/// Adds `(dx, dy)` to entry `i`'s offset; whether anything was written. The
/// ONE place a translate touches an offset, shared by
/// [`RzDocument::move_layers`], [`RzDocument::moved_once`] and
/// [`RzDocument::with_layer_offset`]'s group branch.
///
/// A GROUP has no pixel rect of its own — its raster descendants are in the
/// set and move on their own — so what its offset positions is its
/// CANVAS-sized MASK, which TRAVELS WITH THE GROUP exactly as a layer's mask
/// travels with the layer. That is bookkeeping, never a resample: composing
/// resamples of a canvas plane destroys a band of it per step, so a Move drag
/// that went out and came back — or two opposite arrow nudges — permanently
/// ate the mask's edge. The plane itself is only ever shifted ONCE, by
/// [`baked_group_masks`], at the moment an op needs it as a canvas plane.
/// A group with NO mask has nothing to move, so its offset stays (0, 0) and
/// this answers false — which is what makes a move of groups alone refuse.
pub(crate) fn translate_entry(layers: &mut [Layer], i: usize, dx: i32, dy: i32) -> bool {
    let Some(layer) = layers.get_mut(i) else {
        return false;
    };
    if dx == 0 && dy == 0 {
        return false;
    }
    if layer.kind == LayerKind::Group && layer.mask.is_none() {
        return false;
    }
    layer.offset = (
        saturating_i32(i64::from(layer.offset.0) + i64::from(dx)),
        saturating_i32(i64::from(layer.offset.1) + i64::from(dy)),
    );
    true
}

/// `doc` with every GROUP mask baked back to the canvas origin — the stored
/// plane padded by the group's own offset, and that offset reset to (0, 0) —
/// or `None` when no group mask has travelled, so the common case pays no
/// clone.
///
/// A group's mask rides an offset rather than being resampled on every move
/// ([`translate_entry`]), so this is the ONE place the plane is ever shifted,
/// and it runs at most once per op: the whole-document geometry ops, the
/// transform and the mask-plane readers all consume a group mask as a CANVAS
/// plane and bake first. The pad reads 0 where the mask vacates, which is
/// "hidden" — the same thing an absent plane means — and that loss is now
/// paid once by the op that flattens the offset away instead of once per drag
/// tick.
pub(crate) fn baked_group_masks(doc: &RzDocument) -> Option<RzDocument> {
    if !doc
        .layers
        .iter()
        .any(|l| l.kind == LayerKind::Group && l.offset != (0, 0))
    {
        return None;
    }
    let (w, h) = (doc.width, doc.height);
    let mut out = doc.clone();
    for layer in &mut out.layers {
        if layer.kind != LayerKind::Group || layer.offset == (0, 0) {
            continue;
        }
        if let Some(mask) = layer.mask.as_deref() {
            layer.mask = Some(Arc::new(padded_plane(mask, w, h, layer.offset)));
        }
        layer.offset = (0, 0);
    }
    Some(out)
}

/// How far entry `rect` must travel along `edge`'s axis to line up with
/// `reference`. Both rects are `(x0, y0, x1, y1)`, exclusive.
fn align_delta(
    edge: AlignEdge,
    rect: (i64, i64, i64, i64),
    reference: (i64, i64, i64, i64),
) -> i64 {
    match edge {
        AlignEdge::Left => reference.0 - rect.0,
        AlignEdge::Right => reference.2 - rect.2,
        AlignEdge::Top => reference.1 - rect.1,
        AlignEdge::Bottom => reference.3 - rect.3,
        // Centres in doubled coordinates, so an odd width does not lose half
        // a pixel before the subtraction; the halving rounds toward zero,
        // which is what an integer offset can express.
        AlignEdge::CenterX => ((reference.0 + reference.2) - (rect.0 + rect.2)) / 2,
        AlignEdge::CenterY => ((reference.1 + reference.3) - (rect.1 + rect.3)) / 2,
    }
}

/// Clears every link id carried by exactly one entry: a link group of one is
/// not a link, and leaving it would make the next `next_link_id` skip a value
/// for no reason.
fn prune_lone_links(layers: &mut [Layer]) {
    let ids: Vec<u32> = layers.iter().map(|l| l.link).collect();
    for layer in layers.iter_mut() {
        if layer.link != 0 && ids.iter().filter(|&&id| id == layer.link).count() < 2 {
            layer.link = 0;
        }
    }
}

/// `doc` when its link ids differ from `before`'s, `None` when they do not —
/// the core's no-op rule applied to the one field these two ops write.
fn changed_links(before: &RzDocument, doc: RzDocument) -> Option<RzDocument> {
    let same = before
        .layers
        .iter()
        .zip(doc.layers.iter())
        .all(|(a, b)| a.link == b.link);
    (!same).then_some(doc)
}
