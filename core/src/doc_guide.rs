//! Guides and the ruler origin — the two pieces of canvas chrome that are
//! genuinely DOCUMENT state, on the same shelf as the alpha channels
//! (`doc_channel`): they are per-document geometry, they must survive save,
//! reopen and undo, and every canvas-geometry op has to move them the way it
//! moves the pixels. Everything else the host draws around them — whether
//! the rulers are shown, which UNIT they read in, whether guides are visible
//! or LOCKED, the guide colour, the grid's spacing and subdivisions, the
//! pixel grid, and every snapping toggle — is an app-wide PREFERENCE and is
//! deliberately absent from this module and from the `.rz` file: those
//! describe how a user works, not what the picture contains, and a document
//! that arrived carrying them would silently reconfigure the app.
//!
//! **Coordinate convention.** A guide's position is a GRID-LINE coordinate in
//! the continuous canvas space `[0, width]` / `[0, height]`, not a pixel
//! index: a vertical guide at x = 0 lies on the left canvas edge and one at
//! x = width on the right, so both extremes are legal and the range is
//! inclusive at both ends. A `Horizontal` guide is a line of constant y, a
//! `Vertical` one a line of constant x — the orientation names the LINE, not
//! the axis its position is measured on.
//!
//! That convention is why the geometry maps below are exactly `doc.rs`'s
//! layer maps (`rotate90` and friends, `doc.rs:1099-1142`) **with
//! `lw = lh = 0`**: a layer is a rect anchored at its top-left, so its map
//! subtracts its own width and height; a guide is a line with no extent, so
//! those terms vanish. The two stay derivable from one another, which is what
//! stops a future edit from drifting them apart.
//!
//! **Lock Guides is ONE app-wide boolean, not a per-guide byte.** Photoshop's
//! own Lock Guides is a single toggle, and a lock exists to stop an
//! accidental mouse drag rather than to freeze the document — so [`Guide`]
//! carries no `locked` field, the `.rz` version-8 block carries no lock byte,
//! and nothing here needs to be taught about it. Do not add one.
//!
//! **The model invariant**, maintained by every mutator, every geometry
//! helper and the `.rz` reader: the list is sorted by
//! `(orientation, position)`, holds no two entries with the same
//! `(orientation, position)` after four-decimal quantization, and every
//! position lies inside `[0, extent]` for its orientation. That is what makes
//! "the same guides" a comparison, what makes the no-op check trivial, and
//! what gives the host a stable draw order across undo.
//!
//! **[`normalized`] knows nothing about the canvas.** It has exactly ONE job
//! — quantize, drop non-finite positions, sort, de-duplicate — and takes no
//! dimensions at all, so it can neither clamp nor drop by extent and no
//! caller can pick up the wrong policy by accident. Each caller states its
//! own canvas policy in its own doc comment, and the two policies are
//! genuinely different: [`cropped_guides`] and [`padded_guides`] **DROP** what
//! left the window (a deliberate user op cut it out of the picture), while
//! [`resized_guides`], [`geometry_guides`] and `rzdc::parse_native` **CLAMP**
//! (a scale cannot move a guide out, and a nonsense value in a crafted file
//! is a broken value the format repairs rather than a structural claim it
//! refuses).

use std::sync::atomic::{AtomicU64, Ordering};

use crate::doc::{Geometry, RzDocument};
use crate::style_json::q4_f64;

/// Which way a guide runs. The name is the LINE's direction, so a
/// `Horizontal` guide has a constant y and a `Vertical` one a constant x.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Debug)]
#[repr(i32)]
pub enum GuideOrientation {
    /// A line of constant y; its position is measured on the height axis.
    Horizontal = 0,
    /// A line of constant x; its position is measured on the width axis.
    Vertical = 1,
}

impl GuideOrientation {
    /// Maps a raw `RzGuideOrientation` value coming across the FFI or out of
    /// a `.rz` record; `None` for anything else, which both the reader and
    /// the FFI refuse rather than repair. An orientation is a structural
    /// claim like a layer kind, not a cosmetic one — and materializing an
    /// enum from an out-of-range discriminant would be undefined behaviour.
    pub(crate) fn from_c(value: i32) -> Option<Self> {
        match value {
            0 => Some(GuideOrientation::Horizontal),
            1 => Some(GuideOrientation::Vertical),
            _ => None,
        }
    }

    /// The `RzGuideOrientation` value for the FFI.
    pub(crate) fn to_c(self) -> i32 {
        self as i32
    }
}

/// One guide: a line across the whole canvas at `position`, in the canvas's
/// continuous coordinate space (see the module doc's convention).
#[derive(Clone, Copy, Debug)]
pub struct Guide {
    /// Stable identity, unique among every guide this process has minted.
    ///
    /// It exists for `Channel::id`'s reason, and the argument is STRONGER
    /// here: a host's per-guide state (which guide a drag is moving, which is
    /// selected) has to stay attached to a guide rather than to its position
    /// in the list, and the list is re-SORTED by position on many edits — so
    /// a positional key changes under an edit that changed nothing else.
    /// Everything that carries a guide through keeps the id: a move, the
    /// geometry helpers, undo/redo (which restores the whole handle).
    ///
    /// It is deliberately NOT persisted: identity only has to hold for as
    /// long as a host is looking at one open document, so `parse_native`
    /// mints new ids on load and the `.rz` bytes stay unchanged.
    pub id: u64,
    pub orientation: GuideOrientation,
    /// Canvas coordinate of the line, always inside `[0, extent]` for its
    /// orientation and quantized to four decimals (the model invariant).
    pub position: f64,
}

/// The largest guide list a document may carry — the ONE home for the count
/// cap (`rzdc` enforces the same number, so every document that can be built
/// can also be written and read back, and `rz_max_guides` reports it so the
/// host never hand-copies the literal).
///
/// A guide is NOT multiplied by the canvas, so — exactly as with
/// `rzdc::MAX_RZDC_BLOB_LEN` — there is no pixel budget and none is needed:
/// 1024 guides is 9 KB in the file, beside the 1.6 GB of layer pixels the
/// format already admits. What the cap actually bounds is DRAWING: one
/// stroked line per canvas redraw and one hit test per mouse move, per guide.
/// 1024 is far past what any real document uses (Photoshop's own New Guide
/// Layout tops out in the dozens) while still refusing the "one tiny file, a
/// million lines to draw" shape.
pub(crate) const MAX_GUIDES: usize = 1024;

/// The id counter behind [`Guide::id`]. Starts at 1, so 0 is free to mean
/// "no guide" across the FFI. `Relaxed` is enough: nothing is published
/// through this counter, only made distinct, and a `fetch_add` is atomic
/// whatever the ordering.
static NEXT_GUIDE_ID: AtomicU64 = AtomicU64::new(1);

impl Guide {
    /// A guide with a FRESH identity. Every guide this crate creates — a new
    /// one, a moved one, one carried through a geometry op, one read back out
    /// of a `.rz` file — is minted here, so the id is unique by construction.
    pub(crate) fn new(orientation: GuideOrientation, position: f64) -> Self {
        Guide {
            id: NEXT_GUIDE_ID.fetch_add(1, Ordering::Relaxed),
            orientation,
            position,
        }
    }

    /// The same guide at a new position, keeping its identity — the one
    /// place a guide moves without becoming a different guide.
    fn moved_to(self, position: f64) -> Self {
        Guide { position, ..self }
    }
}

impl RzDocument {
    /// The canvas extent a guide of this orientation is measured against: the
    /// WIDTH for a vertical guide (a line of constant x) and the HEIGHT for a
    /// horizontal one. A position is legal in `[0, extent]` INCLUSIVE — both
    /// canvas edges are grid lines a user can align to.
    pub(crate) fn guide_extent(&self, orientation: GuideOrientation) -> f64 {
        match orientation {
            GuideOrientation::Horizontal => f64::from(self.height),
            GuideOrientation::Vertical => f64::from(self.width),
        }
    }

    /// Adds a guide. The position is quantized to four decimals FIRST, so
    /// what is stored is exactly what was range-checked.
    ///
    /// `None` — never a silent repair, because the caller asked for a
    /// specific line and deserves to be told no — for a non-finite position,
    /// a position outside `[0, extent]`, a position a guide of the same
    /// orientation already occupies (adding a duplicate is not an edit), or a
    /// list already holding [`MAX_GUIDES`]. A host that needs to tell those
    /// four apart checks them itself before calling.
    pub fn add_guide(&self, orientation: GuideOrientation, position: f64) -> Option<Self> {
        let position = self.checked_position(orientation, position)?;
        if self.guide_at(orientation, position).is_some() {
            return None;
        }
        if self.guides.len() >= MAX_GUIDES {
            return None;
        }
        let mut doc = self.clone();
        doc.guides.push(Guide::new(orientation, position));
        doc.guides = normalized(doc.guides);
        Some(doc)
    }

    /// Moves guide `i` along its own axis, keeping its identity and its
    /// orientation.
    ///
    /// `None` for an out-of-range index, a non-finite or out-of-canvas
    /// position, the position the guide already has, or a position another
    /// guide of the same orientation already occupies.
    pub fn move_guide(&self, i: usize, position: f64) -> Option<Self> {
        let guide = *self.guides.get(i)?;
        let position = self.checked_position(guide.orientation, position)?;
        if position == guide.position {
            return None;
        }
        if self.guide_at(guide.orientation, position).is_some() {
            return None;
        }
        let mut doc = self.clone();
        doc.guides[i] = guide.moved_to(position);
        doc.guides = normalized(doc.guides);
        Some(doc)
    }

    /// Drops guide `i`. `None` for an out-of-range index.
    pub fn remove_guide(&self, i: usize) -> Option<Self> {
        self.guides.get(i)?;
        let mut doc = self.clone();
        doc.guides.remove(i);
        Some(doc)
    }

    /// Drops every guide. `None` on an already empty list — clearing nothing
    /// is not an edit, and an identical copy would register a phantom undo
    /// step in the host.
    pub fn clear_guides(&self) -> Option<Self> {
        if self.guides.is_empty() {
            return None;
        }
        let mut doc = self.clone();
        doc.guides.clear();
        Some(doc)
    }

    /// Moves the ruler zero point to canvas `(x, y)`. Both components are
    /// quantized to four decimals first, so a value the host read back and
    /// echoed in is refused as unchanged rather than registering a phantom
    /// edit.
    ///
    /// `None` for a non-finite component, a point outside the canvas, or the
    /// origin the document already has.
    pub fn set_ruler_origin(&self, x: f64, y: f64) -> Option<Self> {
        if !x.is_finite() || !y.is_finite() {
            return None;
        }
        let (x, y) = (q4_f64(x), q4_f64(y));
        if !(0.0..=f64::from(self.width)).contains(&x)
            || !(0.0..=f64::from(self.height)).contains(&y)
        {
            return None;
        }
        if (x, y) == self.ruler_origin {
            return None;
        }
        let mut doc = self.clone();
        doc.ruler_origin = (x, y);
        Some(doc)
    }

    /// A position accepted for `orientation`: finite, quantized, and inside
    /// `[0, extent]` inclusive. `None` is the mutators' refusal.
    fn checked_position(&self, orientation: GuideOrientation, position: f64) -> Option<f64> {
        if !position.is_finite() {
            return None;
        }
        let position = q4_f64(position);
        (0.0..=self.guide_extent(orientation))
            .contains(&position)
            .then_some(position)
    }

    /// The index of the guide of `orientation` sitting exactly on `position`
    /// (both already quantized), if any — the duplicate test the two
    /// creating mutators share.
    fn guide_at(&self, orientation: GuideOrientation, position: f64) -> Option<usize> {
        self.guides
            .iter()
            .position(|g| g.orientation == orientation && g.position == position)
    }
}

// ------------------------------------------------------ canvas geometry --
//
// The four guide helpers and the four origin helpers `doc.rs`'s geometry ops
// wire in — the `doc_channel` foot's twins, one per op. EACH ONE'S DOC
// COMMENT NAMES ITS CANVAS POLICY, because the policies genuinely differ and
// [`normalized`] deliberately cannot supply one.
//
// Three "why"s, stated once here and referred to below:
//
// 1. **A guide that left the window is DROPPED, not kept.** `crop`'s own
//    comment is the precedent — "A GROUP's mask is CANVAS space, so it rides
//    the CHANNEL path and is genuinely cut down to the window; a layer mask
//    is layer space and rides along untouched" — and a guide is canvas
//    space. Keeping one would leave a line that is invisible, unclickable and
//    undeletable and that reappears from nowhere on a later Canvas Size. Undo
//    restores the whole handle, so nothing is lost.
// 2. **The ORIGIN is CLAMPED where a guide is DROPPED.** There is exactly one
//    origin and a document is never without one — the `profile` field's
//    precedent, "non-optional … a live document has no 'untagged' state" — so
//    clamping keeps it meaningful while dropping would need an "absent
//    origin" state the model does not want.
// 3. **`resize` must NOT round.** The layer map rounds because an offset is
//    an integer pixel address; a guide position is not. Rounding at every
//    Image Size accumulates — 1000 -> 333 -> 1000 would walk a guide off its
//    feature — so the f64 product is kept and only quantized.

/// Permutes every guide through one exact whole-document transform, then
/// **CLAMPS** into the new canvas.
///
/// `w` and `h` are the OLD canvas (the quarter turns exchange them on the way
/// out). The five maps are `doc.rs`'s layer maps with `lw = lh = 0`: a
/// quarter turn exchanges a guide's ORIENTATION as well as its position,
/// because the line it names has turned with the picture.
///
/// The clamp is float safety only — every mapped position is a difference of
/// two in-range values and cannot leave the new canvas — so nothing is ever
/// dropped here, and a reader looking for a drop should stop looking.
pub(crate) fn geometry_guides(g: &[Guide], geom: Geometry, w: u32, h: u32) -> Vec<Guide> {
    let (fw, fh) = (f64::from(w), f64::from(h));
    let (new_w, new_h) = if geom.swaps_axes() { (h, w) } else { (w, h) };
    let mapped = g
        .iter()
        .map(|guide| {
            let p = guide.position;
            let (orientation, position) = match (geom, guide.orientation) {
                (Geometry::Rotate90, GuideOrientation::Vertical) => {
                    (GuideOrientation::Horizontal, p)
                }
                (Geometry::Rotate90, GuideOrientation::Horizontal) => {
                    (GuideOrientation::Vertical, fh - p)
                }
                (Geometry::Rotate180, GuideOrientation::Vertical) => {
                    (GuideOrientation::Vertical, fw - p)
                }
                (Geometry::Rotate180, GuideOrientation::Horizontal) => {
                    (GuideOrientation::Horizontal, fh - p)
                }
                (Geometry::Rotate270, GuideOrientation::Vertical) => {
                    (GuideOrientation::Horizontal, fw - p)
                }
                (Geometry::Rotate270, GuideOrientation::Horizontal) => {
                    (GuideOrientation::Vertical, p)
                }
                (Geometry::FlipH, GuideOrientation::Vertical) => {
                    (GuideOrientation::Vertical, fw - p)
                }
                (Geometry::FlipH, GuideOrientation::Horizontal) => {
                    (GuideOrientation::Horizontal, p)
                }
                (Geometry::FlipV, GuideOrientation::Vertical) => (GuideOrientation::Vertical, p),
                (Geometry::FlipV, GuideOrientation::Horizontal) => {
                    (GuideOrientation::Horizontal, fh - p)
                }
            };
            Guide {
                orientation,
                position: clamp_to(position, extent_of(orientation, new_w, new_h)),
                ..*guide
            }
        })
        .collect();
    normalized(mapped)
}

/// Shifts every guide by `(-x, -y)` and **DROPS** what now lies outside the
/// window (see "why" 1 above). The boundary is INCLUSIVE: a guide landing
/// exactly on 0 or on the new extent is kept, because both are grid lines of
/// the new canvas.
pub(crate) fn cropped_guides(g: &[Guide], x: u32, y: u32, w: u32, h: u32) -> Vec<Guide> {
    shifted_dropping(g, (-f64::from(x), -f64::from(y)), w, h)
}

/// Shifts every guide by `origin` — where the old canvas's top-left corner
/// lands in the new one — and **DROPS** what left it, exactly as
/// [`cropped_guides`] does and for the same reason. `doc_channel::padded_plane`
/// already clips a canvas plane's coverage the same way, so the two behave
/// alike.
pub(crate) fn padded_guides(g: &[Guide], w: u32, h: u32, origin: (i32, i32)) -> Vec<Guide> {
    shifted_dropping(g, (f64::from(origin.0), f64::from(origin.1)), w, h)
}

/// Scales every guide by the canvas's own factors — `fx` for a vertical
/// guide, `fy` for a horizontal one — **without rounding** (see "why" 3
/// above), then **CLAMPS** into the new canvas.
///
/// Nothing can leave the canvas under a scale, so no drop happens here; the
/// clamp is float safety only.
pub(crate) fn resized_guides(g: &[Guide], fx: f64, fy: f64, w: u32, h: u32) -> Vec<Guide> {
    let scaled = g
        .iter()
        .map(|guide| {
            let factor = match guide.orientation {
                GuideOrientation::Horizontal => fy,
                GuideOrientation::Vertical => fx,
            };
            let extent = extent_of(guide.orientation, w, h);
            Guide {
                position: clamp_to(guide.position * factor, extent),
                ..*guide
            }
        })
        .collect();
    normalized(scaled)
}

/// The ruler origin through one exact whole-document transform, **CLAMPED**
/// into the new canvas (see "why" 2 above). `w` and `h` are the OLD canvas.
pub(crate) fn geometry_origin(o: (f64, f64), geom: Geometry, w: u32, h: u32) -> (f64, f64) {
    let (fw, fh) = (f64::from(w), f64::from(h));
    let (ox, oy) = o;
    let moved = match geom {
        Geometry::Rotate90 => (fh - oy, ox),
        Geometry::Rotate180 => (fw - ox, fh - oy),
        Geometry::Rotate270 => (oy, fw - ox),
        Geometry::FlipH => (fw - ox, oy),
        Geometry::FlipV => (ox, fh - oy),
    };
    let (new_w, new_h) = if geom.swaps_axes() { (h, w) } else { (w, h) };
    sane_origin(moved, new_w, new_h)
}

/// The ruler origin shifted by `(-x, -y)` and **CLAMPED** into the crop
/// window.
pub(crate) fn cropped_origin(o: (f64, f64), x: u32, y: u32, w: u32, h: u32) -> (f64, f64) {
    sane_origin((o.0 - f64::from(x), o.1 - f64::from(y)), w, h)
}

/// The ruler origin shifted by `origin` and **CLAMPED** into the new canvas.
pub(crate) fn padded_origin(o: (f64, f64), w: u32, h: u32, origin: (i32, i32)) -> (f64, f64) {
    sane_origin((o.0 + f64::from(origin.0), o.1 + f64::from(origin.1)), w, h)
}

/// The ruler origin scaled by the canvas's own factors and **CLAMPED** into
/// the new canvas. Unrounded, for [`resized_guides`]'s reason.
pub(crate) fn resized_origin(o: (f64, f64), fx: f64, fy: f64, w: u32, h: u32) -> (f64, f64) {
    sane_origin((o.0 * fx, o.1 * fy), w, h)
}

/// The ONE normalizer, and it has ONE job: quantize each position to four
/// decimals, drop non-finite ones, sort by `(orientation, position)` and
/// de-duplicate, keeping the FIRST of any run (so the older guide keeps its
/// identity).
///
/// It takes NO canvas: it can neither clamp nor drop by extent, so no caller
/// can pick up the wrong policy by accident. It is called last by every
/// mutator, every geometry helper and `rzdc::parse_native`, each of which has
/// already applied its own policy.
///
/// Four decimals is `style_json::q4`'s granularity, chosen for
/// `metadata`'s reason: so a host that echoes a reported value back through
/// the setter is refused as unchanged instead of registering a phantom edit.
pub(crate) fn normalized(mut g: Vec<Guide>) -> Vec<Guide> {
    g.retain(|guide| guide.position.is_finite());
    for guide in g.iter_mut() {
        guide.position = q4_f64(guide.position);
    }
    // Stable, so the de-duplication below keeps the earliest-inserted guide
    // of a coincident pair. Positions are finite by the retain above, which
    // is what makes `total_cmp` a total order here.
    g.sort_by(|a, b| {
        a.orientation
            .cmp(&b.orientation)
            .then(a.position.total_cmp(&b.position))
    });
    g.dedup_by(|a, b| a.orientation == b.orientation && a.position == b.position);
    g
}

/// One stored guide position as the `.rz` reader and writer both take it:
/// `None` for a non-finite value (that guide is DROPPED), otherwise clamped
/// into `[0, extent]` and quantized.
///
/// Shared by both ends so a file this build writes reads back to the same
/// model — the writer's twin of `Resolution::sane`.
pub(crate) fn sane_position(position: f64, extent: f64) -> Option<f64> {
    position.is_finite().then(|| clamp_to(position, extent))
}

/// The ruler origin as every canvas policy and the `.rz` reader take it: a
/// non-finite component becomes 0.0 (a document is never without an origin),
/// and both are clamped into the canvas and quantized.
pub(crate) fn sane_origin(o: (f64, f64), w: u32, h: u32) -> (f64, f64) {
    (
        sane_origin_component(o.0, f64::from(w)),
        sane_origin_component(o.1, f64::from(h)),
    )
}

fn sane_origin_component(v: f64, extent: f64) -> f64 {
    if v.is_finite() {
        clamp_to(v, extent)
    } else {
        0.0
    }
}

/// Quantize, then clamp into `[0, extent]`. Quantizing first is what keeps a
/// value that lands exactly on the extent ON it rather than a rounding step
/// outside.
fn clamp_to(v: f64, extent: f64) -> f64 {
    q4_f64(v).clamp(0.0, extent)
}

/// The canvas extent an orientation is measured against, for the free
/// functions (the method twin is [`RzDocument::guide_extent`]).
fn extent_of(orientation: GuideOrientation, w: u32, h: u32) -> f64 {
    match orientation {
        GuideOrientation::Horizontal => f64::from(h),
        GuideOrientation::Vertical => f64::from(w),
    }
}

/// The shared body of [`cropped_guides`] and [`padded_guides`]: shift along
/// each guide's own axis, then FILTER OUT — never clamp — the guides that
/// no longer lie inside `[0, extent]`.
fn shifted_dropping(g: &[Guide], by: (f64, f64), w: u32, h: u32) -> Vec<Guide> {
    let kept = g
        .iter()
        .filter_map(|guide| {
            let shift = match guide.orientation {
                GuideOrientation::Horizontal => by.1,
                GuideOrientation::Vertical => by.0,
            };
            let position = q4_f64(guide.position + shift);
            let extent = extent_of(guide.orientation, w, h);
            (0.0..=extent)
                .contains(&position)
                .then_some(Guide { position, ..*guide })
        })
        .collect();
    normalized(kept)
}
