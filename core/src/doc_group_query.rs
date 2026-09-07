//! Per-entry queries over the layer forest: the CONTENT bounds align,
//! distribute, `get_document` and the layer-boundary overlay all speak; the
//! Move tool's auto-select hit test; and the link-group helpers the set ops
//! expand a selection with. `doc_group` owns the layout, the invariant and the
//! compositor these read; this module only asks questions of them and is where
//! that file's ~600-line budget sends its second half.

use crate::adjust::Adjustment;
use crate::doc::{Layer, LayerKind, RzDocument};
use crate::doc_group::{parent, subtree, top_level, units, Unit};

/// The coverage a pixel needs before the hit test counts it as HIT: the
/// half-code contour the rest of the core already cuts a selection at, so
/// "what auto-select picks" and "what a selection would enclose" agree.
const HIT_COVERAGE: u8 = 128;

impl RzDocument {
    /// The canvas box `(x, y, width, height)` of entry `idx`'s visible
    /// CONTENT: for a raster entry the box of its non-transparent pixels with
    /// its enabled mask applied, for a group the union over its raster
    /// descendants. `None` when nothing is opaque — align and distribute skip
    /// such an entry rather than treating its pixel rect as content.
    ///
    /// This is the rect `align_layers`, `distribute_layers`,
    /// `get_document`'s `content_*` keys and the layer-boundary overlay all
    /// speak, which is why every one of them gets the SAME answer: a raster
    /// layer's `offset`/`width`/`height` are its PIXEL BUFFER rect, and for a
    /// photo-shaped layer on a canvas-sized buffer — what every paste, text
    /// layer and shape layer produces — that is a different rectangle.
    ///
    /// Deliberately NOT clipped to the canvas, so content hanging off the edge
    /// still aligns by where it really is; and deliberately blind to the
    /// `visible` flag, exactly like [`RzDocument::layer_canvas_image`], since
    /// this says what an entry HOLDS and not what it currently shows.
    pub fn layer_bounds(&self, idx: usize) -> Option<(i32, i32, u32, u32)> {
        let entry = self.layers.get(idx)?;
        let mut box_ = None;
        match entry.kind {
            LayerKind::Raster => union(&mut box_, content_box(entry)),
            LayerKind::Group => {
                for i in subtree(&self.layers, idx) {
                    let descendant = &self.layers[i];
                    if descendant.kind == LayerKind::Raster {
                        union(&mut box_, content_box(descendant));
                    }
                }
            }
        }
        let (x0, y0, x1, y1) = box_?;
        Some((
            clamp_i32(x0),
            clamp_i32(y0),
            (x1 - x0).clamp(0, i64::from(u32::MAX)) as u32,
            (y1 - y0).clamp(0, i64::from(u32::MAX)) as u32,
        ))
    }

    /// The canvas box `(x, y, width, height)` of entry `idx`'s PIXEL BUFFER:
    /// a raster entry's `offset` plus its dimensions, and for a group the
    /// UNION of its raster descendants' same rects. `None` for an
    /// out-of-range index and for a group with no raster descendant.
    ///
    /// The cheap positional twin of [`RzDocument::layer_bounds`]: O(number of
    /// descendants), never a per-pixel read. It is what the four geometry
    /// getters answer with, so a layers-panel reload and a `get_document` row
    /// cost the same on a group as on a raster entry, and it keeps ONE
    /// meaning across both kinds — "the rectangle this entry's pixels live
    /// in". The CONTENT box, which has to look at the pixels, stays behind
    /// `layer_bounds`, which every caller that needs it asks for by name.
    pub fn layer_pixel_rect(&self, idx: usize) -> Option<(i32, i32, u32, u32)> {
        let entry = self.layers.get(idx)?;
        let mut box_ = None;
        match entry.kind {
            LayerKind::Raster => union(&mut box_, Some(pixel_rect(entry))),
            LayerKind::Group => {
                for i in subtree(&self.layers, idx) {
                    let descendant = &self.layers[i];
                    if descendant.kind == LayerKind::Raster {
                        union(&mut box_, Some(pixel_rect(descendant)));
                    }
                }
            }
        }
        let (x0, y0, x1, y1) = box_?;
        Some((
            clamp_i32(x0),
            clamp_i32(y0),
            (x1 - x0).clamp(0, i64::from(u32::MAX)) as u32,
            (y1 - y0).clamp(0, i64::from(u32::MAX)) as u32,
        ))
    }

    /// The entry a click at canvas position `(x, y)` activates: the TOPMOST
    /// one whose own coverage there — alpha scaled by an enabled mask — is at
    /// least [`HIT_COVERAGE`]. Invisible entries and their whole subtrees are
    /// skipped, as are adjustment layers (they have no footprint of their own
    /// and clicking one would never be what the user meant). A group HITS when
    /// any descendant hits.
    ///
    /// With `top_level` the answer is the hit entry's top-level ancestor —
    /// Photoshop's "Auto-Select: Group" — otherwise the leaf itself. `None`
    /// when nothing is hit; the caller leaves the selection alone rather than
    /// emptying it.
    pub fn layer_at(&self, x: i32, y: i32, top_level_ancestor: bool) -> Option<usize> {
        let level = top_level(&self.layers);
        let hit = hit_in_level(&self.layers, &level, i64::from(x), i64::from(y))?;
        if !top_level_ancestor {
            return Some(hit);
        }
        let mut current = hit;
        while let Some(above) = parent(&self.layers, current) {
            current = above;
        }
        Some(current)
    }
}

/// The smallest unused non-zero link id in `layers`. Deterministic — unlike an
/// atomic counter, which is right for `Channel::id` precisely because that one
/// is never persisted — so a `.rz` round trip is byte-identical.
pub fn next_link_id(layers: &[Layer]) -> u32 {
    let mut used: Vec<u32> = layers.iter().map(|l| l.link).filter(|&v| v != 0).collect();
    used.sort_unstable();
    used.dedup();
    let mut candidate = 1u32;
    for value in used {
        if value == candidate {
            candidate = candidate.saturating_add(1);
        } else if value > candidate {
            break;
        }
    }
    candidate
}

/// The given entries expanded the way every "move this" op expands them: by
/// SUBTREE (moving a group moves its children) and then by LINK GROUP (every
/// entry carrying a member's non-zero `link`, with its own subtree), to a
/// fixed point, deduplicated and ascending. Out-of-range indices are dropped.
///
/// A fixed point rather than one pass, because a linked entry's subtree can
/// contain an entry that is itself linked into a further group; the loop is
/// bounded by the entry count, which no growth step can exceed.
pub fn expanded_set(layers: &[Layer], idx: &[usize]) -> Vec<usize> {
    let mut included = vec![false; layers.len()];
    for &i in idx {
        if i >= layers.len() {
            continue;
        }
        for member in subtree(layers, i) {
            included[member] = true;
        }
    }
    for _ in 0..layers.len() {
        let links: Vec<u32> = layers
            .iter()
            .enumerate()
            .filter(|(i, l)| included[*i] && l.link != 0)
            .map(|(_, l)| l.link)
            .collect();
        let mut grew = false;
        for (i, layer) in layers.iter().enumerate() {
            if layer.link == 0 || included[i] || !links.contains(&layer.link) {
                continue;
            }
            for member in subtree(layers, i) {
                grew |= !included[member];
                included[member] = true;
            }
        }
        if !grew {
            break;
        }
    }
    included
        .iter()
        .enumerate()
        .filter_map(|(i, &keep)| keep.then_some(i))
        .collect()
}

/// The box `(x0, y0, x1, y1)` (exclusive, canvas coordinates) a raster
/// entry's pixel BUFFER occupies, whatever is in it.
fn pixel_rect(layer: &Layer) -> (i64, i64, i64, i64) {
    let (lw, lh) = layer.pixels.dimensions();
    let (ox, oy) = (i64::from(layer.offset.0), i64::from(layer.offset.1));
    (ox, oy, ox + i64::from(lw), oy + i64::from(lh))
}

/// The box `(x0, y0, x1, y1)` (exclusive, canvas coordinates) of a raster
/// entry's non-transparent pixels, its enabled mask applied; `None` when none
/// are.
///
/// Four EDGE searches with early exits, not one full sweep, because this is
/// on the hot path: [`RzDocument::layer_bounds`] answers the layers panel, the
/// layer-boundary overlay and `get_document`'s `content_*` keys, i.e. once per
/// row on every panel reload and every agent read. The layers this app makes
/// are canvas-sized and mostly opaque — `adding_layer` allocates width x
/// height — and for a fully covered buffer each search stops on its first
/// probe, so the whole box costs four reads instead of `w * h`. A sparse layer
/// degrades gracefully towards the old cost and an entirely empty one still
/// pays it once, which is the honest price of the answer.
fn content_box(layer: &Layer) -> Option<(i64, i64, i64, i64)> {
    let (lw, lh) = layer.pixels.dimensions();
    let raw = layer.pixels.as_raw();
    let mask = layer.active_mask().map(|m| m.as_raw().as_slice());
    let covered = |x: u32, y: u32| {
        let i = y as usize * lw as usize + x as usize;
        raw[i * 4 + 3] != 0 && mask.is_none_or(|m| m[i] != 0)
    };
    let row_has = |y: u32| (0..lw).any(|x| covered(x, y));
    // The first covered row proves the layer is not empty; every later search
    // is then guaranteed to find its edge.
    let y0 = (0..lh).find(|&y| row_has(y))?;
    let y1 = (y0..lh).rev().find(|&y| row_has(y))? + 1;
    let col_has = |x: u32| (y0..y1).any(|y| covered(x, y));
    let x0 = (0..lw).find(|&x| col_has(x))?;
    let x1 = (x0..lw).rev().find(|&x| col_has(x))? + 1;
    let (ox, oy) = (i64::from(layer.offset.0), i64::from(layer.offset.1));
    Some((
        i64::from(x0) + ox,
        i64::from(y0) + oy,
        i64::from(x1) + ox,
        i64::from(y1) + oy,
    ))
}

fn union(box_: &mut Option<(i64, i64, i64, i64)>, rect: Option<(i64, i64, i64, i64)>) {
    let Some(rect) = rect else { return };
    *box_ = Some(match *box_ {
        None => rect,
        Some(o) => (
            o.0.min(rect.0),
            o.1.min(rect.1),
            o.2.max(rect.2),
            o.3.max(rect.3),
        ),
    });
}

fn clamp_i32(v: i64) -> i32 {
    v.clamp(i64::from(i32::MIN), i64::from(i32::MAX)) as i32
}

/// Top-down over one level's composite order, recursing into groups.
fn hit_in_level(layers: &[Layer], level: &[Unit], x: i64, y: i64) -> Option<usize> {
    for unit in level.iter().rev() {
        let entry = &layers[unit.idx];
        if !entry.visible {
            continue;
        }
        match entry.kind {
            LayerKind::Group => {
                let children = units(layers, unit.start..unit.idx, entry.depth.saturating_add(1));
                if let Some(hit) = hit_in_level(layers, &children, x, y) {
                    return Some(hit);
                }
            }
            LayerKind::Raster => {
                if entry
                    .meta
                    .as_deref()
                    .and_then(Adjustment::from_meta)
                    .is_some()
                {
                    continue;
                }
                if covers(entry, x, y) {
                    return Some(unit.idx);
                }
            }
        }
    }
    None
}

/// Whether a raster entry's own coverage at canvas position `(x, y)` reaches
/// [`HIT_COVERAGE`].
fn covers(layer: &Layer, x: i64, y: i64) -> bool {
    let (lw, lh) = layer.pixels.dimensions();
    let lx = x - i64::from(layer.offset.0);
    let ly = y - i64::from(layer.offset.1);
    if lx < 0 || ly < 0 || lx >= i64::from(lw) || ly >= i64::from(lh) {
        return false;
    }
    let i = ly as usize * lw as usize + lx as usize;
    let alpha = f32::from(layer.pixels.as_raw()[i * 4 + 3]);
    let coverage = layer
        .active_mask()
        .map_or(255.0, |m| f32::from(m.as_raw()[i]));
    (alpha * coverage / 255.0).round() as u32 >= u32::from(HIT_COVERAGE)
}
