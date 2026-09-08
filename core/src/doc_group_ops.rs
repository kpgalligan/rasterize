//! The layer-group OPERATIONS: the two that create and dissolve the shape
//! (`group_layers` / `ungroup_layer`), the structural move every reparenting
//! drag goes through (`move_layer_to`), the panel disclosure setter, and the
//! raw group projection `layer_canvas_image` and the plane readers answer
//! with. The layout, its invariant and the compositor these build on are in
//! `doc_group`; this file exists because that one is the specification and
//! carrying the ops as well would put it well past the size budget.
//!
//! Every op here ends in `doc_group::validated`, so a malformed result is a
//! NO-OP rather than a corrupt document — see `doc_group`'s module doc for why
//! that gate is a runtime check and not an assertion.

use std::cell::Cell;
use std::ops::Range;
use std::sync::Arc;

use image::RgbaImage;

use crate::blend::BlendMode;
use crate::doc::{quantize, Layer, LayerKind, RzDocument};
use crate::doc_group::{
    composite_level_into, level_range, parent, relocated, subtree, units, validated,
    MAX_GROUP_DEPTH,
};

impl RzDocument {
    /// Group `idx`'s RAW projection on a transparent canvas-sized buffer: its
    /// children composited among themselves, WITHOUT the group's own opacity,
    /// blend mode, mask or style — the group twin of
    /// [`RzDocument::layer_canvas_image`], whose "deliberately raw" contract
    /// this keeps. `None` when `idx` is not a group.
    pub(crate) fn group_projection(&self, idx: usize) -> Option<RgbaImage> {
        let entry = self.layers.get(idx)?;
        if entry.kind != LayerKind::Group {
            return None;
        }
        let px = self.width as usize * self.height as usize;
        let mut acc = vec![[0.0f32; 4]; px];
        let colors = self.style_colors();
        let env = self.composite_env(colors.as_ref());
        let budget = Cell::new(0u64);
        let depth = entry.depth.saturating_add(1);
        let children = units(&self.layers, subtree(&self.layers, idx).start..idx, depth);
        composite_level_into(
            &mut acc,
            self.width,
            self.height,
            (0, 0),
            &self.layers,
            &children,
            env,
            depth,
            &budget,
        );
        Some(quantize(&acc, self.width, self.height))
    }

    /// THE structural move: the entry at `from` and its whole subtree land at
    /// index `to` — an index into the stack with that subtree already taken
    /// out, exactly as `remove`-then-`insert` has always meant — at `depth`.
    ///
    /// `None` for an out-of-range index, for a `depth` past
    /// [`MAX_GROUP_DEPTH`] once the subtree's own nesting is added, for any
    /// `(to, depth)` pair whose RESULT fails [`validate_structure`] — the
    /// malformed depth sequence the module doc opens with is exactly this op's
    /// failure mode — and for a `(to, depth)` pair that would leave the stack
    /// exactly as it is. That last one is the core's no-op rule, and it is
    /// decidable without building the result: `to` numbers the stack with the
    /// subtree already drained, so the block lands back where it came from
    /// precisely when `to` (clamped to the end, as `relocated` clamps it)
    /// equals the subtree's own start. Without it a panel drag that ended
    /// where it began, or a `reorder_layer` naming a `to` inside the entry's
    /// own subtree, answered a document identical to its input and the host
    /// minted an undo step for a move that moved nothing.
    ///
    /// There is deliberately NO "not into your own subtree" guard. `to` is an
    /// index into the stack with the subtree ALREADY removed, so every value
    /// in `0..=len - subtree.len()` is a legal insertion point and landing
    /// inside the moved block is impossible by construction. A guard written
    /// in the PRE-drain numbering refuses real drags instead: for a group at
    /// `g` whose subtree is `s..g + 1`, dropping it one place up over a
    /// smaller sibling maps to `to = s + m`, which falls inside that range
    /// whenever the sibling is smaller than the group — i.e. the commonest
    /// group reorder the layers panel performs.
    pub fn move_layer_to(&self, from: usize, to: usize, depth: u16) -> Option<Self> {
        let entry = self.layers.get(from)?;
        self.layers.get(to)?;
        let from_depth = entry.depth;
        let sub = subtree(&self.layers, from);
        if to.min(self.layers.len() - sub.len()) == sub.start && depth == from_depth {
            return None;
        }
        // The subtree keeps its shape and is re-based on the new depth; its
        // shallowest entry IS the moved entry itself, so `relocated`'s
        // per-entry range check is exactly the cap check this needs.
        relocated(self, sub, to, i32::from(depth) - i32::from(from_depth))
    }

    /// Wraps the given entries in a NEW group. Every entry must share ONE
    /// parent (else `None`); the subtrees are gathered in their existing
    /// relative order and the group is inserted so its subtree occupies the
    /// TOPMOST given entry's slot, with the gathered depths shifted by +1.
    /// `None` for an empty or out-of-range set, for entries at different
    /// levels, and when the deepest resulting depth would pass
    /// [`MAX_GROUP_DEPTH`].
    ///
    /// The new group is Pass Through, opacity 1, visible, open, unclipped,
    /// with no mask, no style, no locks and no link.
    ///
    /// Returns `(document, new group index, entries whose clipped flag was
    /// CLEARED, entries whose relative order CHANGED)`, the last two as NEW
    /// indices, because both are things the caller must be able to report:
    ///
    /// * the bottom-most grouped entry has its `clipped` flag cleared when it
    ///   is set, since nothing is below it inside the group for it to clip to
    ///   — Photoshop's behaviour, and without it the entry would silently
    ///   composite as if unclipped and the clip would be gone with no warning;
    /// * a NON-CONTIGUOUS set gathers the subtrees into the topmost given
    ///   entry's slot, so entries left between them change their relative
    ///   position (grouping `{A, C}` out of `[A, B, C]` leaves `B` below `A`,
    ///   not between them).
    pub fn group_layers(
        &self,
        idx: &[usize],
        name: &str,
    ) -> Option<(Self, usize, Vec<usize>, Vec<usize>)> {
        let mut sorted = idx.to_vec();
        sorted.sort_unstable();
        sorted.dedup();
        let (&first, &last) = (sorted.first()?, sorted.last()?);
        if last >= self.layers.len() {
            return None;
        }
        let depth = self.layers[first].depth;
        let parent_of_set = parent(&self.layers, first);
        if sorted
            .iter()
            .any(|&i| self.layers[i].depth != depth || parent(&self.layers, i) != parent_of_set)
        {
            return None;
        }
        let subs: Vec<Range<usize>> = sorted.iter().map(|&i| subtree(&self.layers, i)).collect();
        let deepest = subs
            .iter()
            .flat_map(|r| self.layers[r.clone()].iter())
            .map(|l| l.depth)
            .max()?;
        if deepest.saturating_add(1) > MAX_GROUP_DEPTH {
            return None;
        }
        let mut gathered_flag = vec![false; self.layers.len()];
        for range in &subs {
            for i in range.clone() {
                gathered_flag[i] = true;
            }
        }
        let mut gathered: Vec<Layer> = Vec::new();
        let mut gathered_from: Vec<usize> = Vec::new();
        let mut kept: Vec<Layer> = Vec::new();
        let mut kept_from: Vec<usize> = Vec::new();
        for (i, layer) in self.layers.iter().enumerate() {
            if gathered_flag[i] {
                gathered.push(Layer {
                    depth: layer.depth + 1,
                    ..layer.clone()
                });
                gathered_from.push(i);
            } else {
                kept.push(layer.clone());
                kept_from.push(i);
            }
        }
        let mut cleared_clip = Vec::new();
        if self.layers[first].clipped {
            let position = gathered_from
                .iter()
                .position(|&o| o == first)
                .expect("the bottom-most given entry is gathered");
            gathered[position].clipped = false;
            cleared_clip.push(first);
        }
        let at = kept_from
            .iter()
            .position(|&o| o > last)
            .unwrap_or(kept.len());
        let group_index = at + gathered.len();
        let mut layers = Vec::with_capacity(self.layers.len() + 1);
        layers.extend_from_slice(&kept[..at]);
        layers.extend(gathered);
        layers.push(Layer {
            pixels: Arc::new(RgbaImage::new(1, 1)),
            offset: (0, 0),
            name: name.to_string(),
            opacity: 1.0,
            blend: BlendMode::PassThrough,
            visible: true,
            mask: None,
            mask_enabled: true,
            meta: None,
            clipped: false,
            style: None,
            kind: LayerKind::Group,
            depth,
            locks: 0,
            link: 0,
            open: true,
        });
        layers.extend_from_slice(&kept[at..]);
        // Original index -> new index, so both reports name entries the caller
        // can actually address afterwards.
        let new_index = |original: usize| -> usize {
            match gathered_from.iter().position(|&o| o == original) {
                Some(g) => at + g,
                None => {
                    let k = kept_from
                        .iter()
                        .position(|&o| o == original)
                        .expect("every entry is either gathered or kept");
                    if k < at {
                        k
                    } else {
                        k + gathered_from.len() + 1
                    }
                }
            }
        };
        let cleared_clip: Vec<usize> = cleared_clip.into_iter().map(new_index).collect();
        let reordered: Vec<usize> = kept_from
            .iter()
            .copied()
            .filter(|&o| o > subs[0].start && o < last)
            .map(new_index)
            .collect();
        let mut doc = self.clone();
        doc.layers = layers;
        let doc = validated(doc)?;
        Some((doc, group_index, cleared_clip, reordered))
    }

    /// Pure setter: replaces GROUP `idx`'s panel disclosure state — document
    /// state, so it survives a save, like Photoshop's. `None` on an
    /// out-of-range index, on a raster entry (which has nothing to expand),
    /// and when the group is already in that state — the core's purity rule,
    /// which matters here because the host counts a change for every non-nil
    /// answer, so an identical copy would dirty a document nobody edited.
    pub fn with_layer_open(&self, idx: usize, open: bool) -> Option<Self> {
        let entry = self.layers.get(idx)?;
        if entry.kind != LayerKind::Group {
            return None;
        }
        if entry.open == open {
            return None;
        }
        let mut doc = self.clone();
        doc.layers[idx].open = open;
        Some(doc)
    }

    /// Dissolves group `idx`: its children take its depth and its slot, in
    /// order, and the group entry is removed. The group's own mask, style,
    /// opacity, blend mode and clipped flag are DISCARDED — they cannot be
    /// expressed on the children — so a caller that wants to report the loss
    /// must read them before the call. `None` on a non-group and when the
    /// document would be left with no entries at all.
    ///
    /// Returns `(document, entries whose clipped flag was CLEARED)`, the
    /// second as NEW indices — the exact mirror of [`Self::group_layers`]'s
    /// `cleared_clip`, and for the same reason. Inside the group the
    /// bottom-most child was at the BOTTOM of its level, so a `clipped` flag
    /// on it was BASELESS and composited as if unclipped. Out at the parent
    /// level that same entry can land above an unclipped sibling and suddenly
    /// clip to it — confining it to that sibling's footprint and changing the
    /// picture with nothing anywhere saying so. So an entry that was baseless
    /// STAYS baseless: the flag is cleared, exactly as grouping clears it, and
    /// the caller is told which entry it happened to. When there is no
    /// unclipped sibling below the group the entry is baseless either way and
    /// its flag is left alone.
    pub fn ungroup_layer(&self, idx: usize) -> Option<(Self, Vec<usize>)> {
        let entry = self.layers.get(idx)?;
        if entry.kind != LayerKind::Group {
            return None;
        }
        let start = subtree(&self.layers, idx).start;
        if self.layers.len() == 1 {
            return None;
        }
        let mut doc = self.clone();
        for layer in &mut doc.layers[start..idx] {
            layer.depth = layer.depth.saturating_sub(1);
        }
        let mut cleared_clip = Vec::new();
        // The bottom-most CHILD, which is not `start` whenever that child is
        // itself a group: `start` is then the deepest GRANDCHILD at the bottom
        // of the subtree, whose clipping never changes here. Reading `start`
        // instead both missed a clipped child group (it silently gained a clip
        // base at the parent level) and cleared — and reported — the flag of a
        // deep descendant that stayed baseless either way.
        let bottom = units(&self.layers, start..idx, entry.depth.saturating_add(1))
            .first()
            .map(|u| u.idx);
        if let Some(bottom) = bottom.filter(|&b| doc.layers[b].clipped) {
            let level = level_range(&self.layers, idx);
            let gains_base = units(&self.layers, level.start..start, entry.depth)
                .iter()
                .any(|u| !self.layers[u.idx].clipped);
            if gains_base {
                doc.layers[bottom].clipped = false;
                cleared_clip.push(bottom);
            }
        }
        doc.layers.remove(idx);
        // Removing the group shifts nothing below `idx`, so the index recorded
        // above is already the entry's new address.
        validated(doc).map(|doc| (doc, cleared_clip))
    }
}
