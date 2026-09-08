//! Healing on the layered document: the Poisson write-back that turns a
//! cloned patch into a seamless one, and the healing brush that drives it.
//!
//! The stroke arrives as the SAME canvas-frame premultiplied RGBA8 overlay
//! `rz_doc_painting_layer` takes — the Clone Stamp's overlay, literally: its
//! ALPHA is the footprint's coverage and its RGB the already-aligned source
//! pixels, premultiplied by that coverage. The healing brush IS the clone
//! stamp with a different op at commit, which is why no offset parameter
//! crosses the FFI: the alignment happened when the overlay was drawn.
//!
//! # What the solve does
//!
//! Covered pixels (alpha ≥ 128) are handed to `poisson::solve_membrane`,
//! which returns the harmonic correction `ũ` matching `destination − source`
//! on the covered set's contour. The healed pixel is `source + ũ`: the
//! source's texture, the destination's illumination. Each of R, G and B is
//! solved independently on STRAIGHT colour, in the document's own numbers —
//! healing samples the document's own pixels, so no colour conversion
//! happens anywhere here. Layer alpha is never touched, and a fully
//! transparent destination pixel is excluded from the solve and never
//! written (its RGB is latent garbage, not colour — `doc_retouch`'s rule).
//!
//! # The write-back weight is a HARD cut, and why
//!
//! `out = dst + w·(f − dst)` with **`w = covered ? strength : 0`** — a hard
//! cut at the α = 128 contour, NOT the overlay's soft alpha. Outside the
//! covered set the solver leaves `ũ = 0`, so weighting by a soft alpha there
//! would blend in `f = g`: the UNCORRECTED clone, carrying exactly the
//! illumination mismatch the op exists to remove, as a bright or dark fringe
//! around every stroke. No feather is needed to hide the join, because
//! `f == dst` exactly on the contour. Content-Aware Fill is the one caller
//! that passes a soft `write` plane, and it can because it also takes its Ω
//! out to the far edge of the selection's ramp: every pixel it fades is one
//! the inpaint actually re-estimated, so the weight rises from 0 INSIDE Ω
//! rather than stepping at its contour. Spot healing is NOT: its coverage is
//! a brush dab exactly like this one's, so it takes the hard cut too, which
//! is all `doc_inpaint::Caller` decides.
//!
//! Two consequences worth stating plainly:
//!
//! - **Hardness shrinks the footprint; it does not fade the heal.** A soft
//!   brush's rim falls below 128 and is simply not healed. The heal itself
//!   is always at full strength inside the contour.
//! - **Flow must be 1 for a healing brush.** Flow multiplies every dab's
//!   alpha, so at flow ≤ 0.5 a click deposits α < 128 everywhere, the
//!   covered set is empty and the op refuses. Strength belongs in Opacity,
//!   which the callers pass as `strength` — the dodge/burn precedent.
//!
//! # Quantization at the rim
//!
//! At a pixel ON the contour the un-premultiply error cancels exactly:
//! `f = g + (f* − g) = f*`. It does NOT cancel in the interior — `b` is read
//! at the contour from the un-premultiplied overlay and, by the maximum
//! principle, an error there propagates inward with weight up to 1. At the
//! α = 128 contour the un-premultiply error is up to 127/128 ≈ 1 code value,
//! so a CG-rasterized (anti-aliased) footprint carries up to ±1 code of DC
//! error across the healed patch. A hand-built, integer-aligned,
//! full-coverage footprint carries none. Relatedly, the overlay conflates
//! the source's own alpha with coverage: cloning from a semi-transparent
//! area heals at reduced strength, exactly as the Clone Stamp paints it at
//! reduced opacity. Both are limits, not bugs.
//!
//! # "Replace" mode is not shipped
//!
//! Photoshop's Replace mode skips the blend at the footprint's edge, which
//! in this build is precisely the Clone Stamp — already its own tool with
//! its own overlay path. Shipping it would be a second name for an existing
//! tool, so `heal_layer` has no mode parameter.
//!
//! # Measured cost of a stroke commit
//!
//! A whole `heal_layer` call on a 2000×1500 document (`heal_tests`, this
//! machine, `--release`) — the canvas-sized coverage scan and the component
//! walk included, which is most of the bill for a small dab:
//!
//! | footprint | covered px | whole op, 3 channels |
//! |---|---|---|
//! | a 40 px brush dab | 1.3 k | 4.4 ms |
//! | a 120 px dab | 11 k | 8.4 ms |
//! | a patch-tool region, 340 px across | 91 k | 54 ms |
//!
//! So the solve runs once at mouse-up, on the whole stroke's footprint, and
//! costs a frame or two — which is why the healing brush previews the raw
//! clone during the drag and heals on release, rather than solving per dab
//! (`k` solves instead of one, each pinning its boundary to a destination
//! the previous dab already moved, which shows as ridges along the stroke).
//!
//! # What is capped, and why there are two caps
//!
//! [`MAX_SOLVE_WINDOW_PIXELS`] bounds ONE component's window and is about
//! MEMORY. It says nothing about a call with many components, and the cost
//! of those is real and was unbounded: every component pays a full pass over
//! its own window — the coverage, usable, `b` and `u` planes, plus
//! `poisson`'s classification — even when it covers three pixels, so the
//! bill is `parts × window area`. Measured on a 5000 × 4000 document whose
//! coverage is N disjoint three-pixel diagonal runs, each with a box
//! spanning nearly the whole canvas (the shape a scratch, a wire or a hair
//! makes): 10 parts 5.2 s, 40 parts 20.2 s, linear in the count and nothing
//! refusing. [`MAX_HEAL_PLAN_PIXELS`] bounds that sum, before any component
//! is healed — the same quantity `doc_inpaint`'s plan cap bounds for the
//! sibling ops, which refused the identical selection in milliseconds while
//! this one accepted it and blocked.

use image::RgbaImage;
use std::collections::VecDeque;

use crate::doc::RzDocument;
use crate::doc_lock::EditKind;
use crate::poisson::{solve_membrane, Region, COVERED_THRESHOLD};

/// Memory bound on ONE component's solve window. The window carries dense
/// f32 `u` and `b` planes, the classification and coverage byte planes, the
/// source RGB and the multigrid hierarchy's own 4/3 of all that — about 38
/// bytes a pixel measured across the buffers this file and `poisson`
/// allocate, so 32 megapixels is a ~1.2 GB peak and, at `poisson`'s measured
/// 137–166 ns an unknown, ~13–16 s for three channels. It is a bound on
/// MEMORY, not on the unknown count: the schedule in `poisson` costs a
/// constant per unknown, so a big region is slow in proportion to its area
/// and nothing worse.
///
/// The window is a bounding BOX, so the cap is deliberately generous: a
/// three-pixel scratch running corner to corner across a 24-megapixel photo
/// has a box of 24 megapixels and a few thousand covered pixels, and
/// refusing that — the single most common content-aware fill — would be
/// worse than the transient.
///
/// This is the one home for the number; `doc_inpaint` reuses it rather than
/// declaring a second copy.
pub const MAX_SOLVE_WINDOW_PIXELS: u64 = 32_000_000;

/// The largest total of working WINDOWS one heal call will build, summed over
/// its components. It bounds the quantity [`MAX_SOLVE_WINDOW_PIXELS`]
/// deliberately does not — the whole CALL — and it is checked before a single
/// component is healed, so a refusal costs a component walk and not a heal.
///
/// The number is the same 80 megapixels as
/// `doc_inpaint::MAX_INPAINT_PLAN_PIXELS`, and for the same measured reason:
/// a megapixel of window costs about 26 ms of plane building here (5.2 s for
/// ten canvas-spanning scratches on a 5000 × 4000 document, 20.2 s for
/// forty), so 80 megapixels is ~2 s of window work, which leaves the rest of
/// the 15 s a blocking commit is allowed for the solve itself. It is a
/// separate constant rather than a shared one because the two ops bound
/// different work and either may move on its own measurement.
pub const MAX_HEAL_PLAN_PIXELS: u64 = 80_000_000;

impl RzDocument {
    /// Poisson-blends the source patch `overlay` carries into layer `idx`:
    /// the source's texture with the layer's own illumination.
    ///
    /// `overlay` is the canvas-frame PREMULTIPLIED RGBA8 buffer
    /// `rz_doc_painting_layer` takes (`w`/`h` must equal the canvas size).
    /// Its alpha is the footprint's coverage; its RGB, un-premultiplied, is
    /// the already-aligned source. `strength` is clamped to [0, 1] and
    /// scales the write-back. The overlay is mapped through the layer's
    /// offset exactly as `painting_layer`: overlay outside the layer's
    /// extent is ignored and the layer never grows.
    ///
    /// The covered set is split into 4-connected COMPONENTS, each solved in
    /// its own bounding box padded by one pixel — so a scatter of dabs costs
    /// the sum of their own boxes rather than one box around all of them,
    /// and each blemish's boundary condition comes from its own
    /// neighbourhood.
    ///
    /// `Err` (a message for the user) when one component's box exceeds
    /// [`MAX_SOLVE_WINDOW_PIXELS`], or when every component's box together
    /// exceeds [`MAX_HEAL_PLAN_PIXELS`] — both are measured before anything
    /// is healed. `Ok(None)` — a plain refusal — for an
    /// out-of-range `idx`, `w`/`h` not the canvas size, an `overlay` shorter
    /// than `w*h*4`, a non-finite `strength`, an empty covered set, a layer
    /// extent that misses the canvas, or no pixel actually changing (a
    /// covered set with no interior is the common case: every covered pixel
    /// is then on the join contour, where the heal IS the destination).
    pub fn heal_layer(
        &self,
        idx: usize,
        overlay: &[u8],
        w: u32,
        h: u32,
        strength: f32,
    ) -> Result<Option<Self>, String> {
        self.under_locks_fallible(idx, EditKind::Pixels, |doc| {
            doc.heal_layer_unlocked(idx, overlay, w, h, strength)
        })
    }

    /// The body of [`Self::heal_layer`], outside the lock gate. Split out
    /// only so the gate is one line; that method is its only caller. It takes
    /// `under_locks_fallible` rather than `under_locks` because it reports
    /// through `Result`, and a lock refusal comes back as `Ok(None)` — a
    /// domain refusal, not an error string.
    fn heal_layer_unlocked(
        &self,
        idx: usize,
        overlay: &[u8],
        w: u32,
        h: u32,
        strength: f32,
    ) -> Result<Option<Self>, String> {
        let Some(layer) = self.raster_layer(idx) else {
            return Ok(None);
        };
        if w != self.width || h != self.height || !strength.is_finite() {
            return Ok(None);
        }
        let canvas = match (w as usize).checked_mul(h as usize) {
            Some(n) if n > 0 && overlay.len() >= n * 4 => n,
            _ => return Ok(None),
        };
        // The canvas-frame overlay must be able to reach a layer pixel at
        // all — the same intersection `RzDocument::painting_layer`
        // (`doc.rs`, the master copy) makes before touching anything.
        let (lw, lh) = layer.pixels.dimensions();
        let (off_x, off_y) = (i64::from(layer.offset.0), i64::from(layer.offset.1));
        let reach_x = (-off_x).max(0) < (i64::from(self.width) - off_x).min(i64::from(lw));
        let reach_y = (-off_y).max(0) < (i64::from(self.height) - off_y).min(i64::from(lh));
        if !reach_x || !reach_y {
            return Ok(None);
        }

        let covered: Vec<bool> = (0..canvas)
            .map(|i| overlay[i * 4 + 3] >= COVERED_THRESHOLD)
            .collect();
        if !covered.iter().any(|c| *c) {
            return Ok(None);
        }
        let parts = components(&covered, w as usize, h as usize);
        // The WHOLE call's working area, measured before any of it is healed:
        // a refusal must cost a component walk and not a heal, and the
        // per-component memory bound below says nothing about how many
        // components there are. See the module doc's cap section.
        if let Some(message) = over_plan_limit(&parts, w, h) {
            return Err(message);
        }
        let mut pixels = (*layer.pixels).clone();
        let mut changed = false;
        for component in parts {
            let (x0, y0, x1, y1) = component.box_padded(w, h);
            let (ww, wh) = ((x1 - x0 + 1) as usize, (y1 - y0 + 1) as usize);
            // Check the memory bound BEFORE building this component's window
            // buffers, since they are most of what the bound is about.
            if let Some(message) = over_window_limit(ww, wh) {
                return Err(message);
            }
            let (region, write, source) =
                component.window_buffers(overlay, w as usize, (x0, y0), (ww, wh));
            changed |= heal_window_into_pixels(
                (self.width, self.height),
                &mut pixels,
                layer.offset,
                (i64::from(x0), i64::from(y0), ww, wh),
                &source,
                &region,
                &write,
                strength,
            )?;
        }
        if !changed {
            // Identity result: refuse rather than mint an unchanged copy.
            return Ok(None);
        }
        Ok(self.with_layer_pixels(idx, pixels))
    }
}

/// THE healing write-back, shared by [`RzDocument::heal_layer`] and by
/// `doc_inpaint`'s spot heal and content-aware fill. Everything but `doc`
/// and `idx` is WINDOW-sized.
///
/// `win` is `(x, y, w, h)` in canvas coordinates. `source` is straight RGB,
/// 3 bytes per window pixel. `region` is the solve domain (≥ 128 = in).
/// `write` is the write-back weight, and it is subordinate to `region` and
/// to the layer: `write[p]` is forced to 0 wherever `region[p] < 128` or the
/// destination pixel is outside the layer or fully transparent, so no pixel
/// can ever receive an unsolved source. `strength` scales it.
///
/// `Err` when the window exceeds [`MAX_SOLVE_WINDOW_PIXELS`]; `Ok(None)`
/// when the index is out of range, `strength` is not finite, a buffer is
/// short, the window is empty, or no byte moved.
///
/// Deliberately NOT gated by `doc_lock` and deliberately reading
/// `layers.get` rather than `raster_layer`, which `doc_lock`'s module doc
/// also records so nobody "fixes" it: this is a module-level free function,
/// not an `impl RzDocument` method, so `under_locks` cannot wrap it, and its
/// only caller (`doc_inpaint`'s reduced-resolution preview) hands it an
/// internal ONE-LAYER TEMP document whose single raster layer carries no
/// locks. The locks and the group guard are applied one level up, at
/// `heal_layer` / `spot_heal_layer` / `content_aware_fill`, which is where a
/// caller's real layer index enters.
pub fn heal_window_into_layer(
    doc: &RzDocument,
    idx: usize,
    win: (i64, i64, usize, usize),
    source: &[u8],
    region: &[u8],
    write: &[u8],
    strength: f32,
) -> Result<Option<RzDocument>, String> {
    let Some(layer) = doc.layers.get(idx) else {
        return Ok(None);
    };
    if !strength.is_finite() {
        return Ok(None);
    }
    let mut pixels = (*layer.pixels).clone();
    let changed = heal_window_into_pixels(
        (doc.width, doc.height),
        &mut pixels,
        layer.offset,
        win,
        source,
        region,
        write,
        strength,
    )?;
    if !changed {
        return Ok(None);
    }
    Ok(doc.with_layer_pixels(idx, pixels))
}

/// One window's solve and write-back, straight into a layer pixel buffer —
/// so a stroke (or a fill) with several components pays one buffer clone, not
/// one per component. [`heal_window_into_layer`] is the same call for the one
/// caller that has no buffer to thread: the preview's one-layer temp
/// document. Returns whether any byte moved.
// The parameter list is the window contract of `heal_window_into_layer`
// with the layer unpacked; bundling them into a struct would only move the
// count somewhere else.
#[allow(clippy::too_many_arguments)]
pub(crate) fn heal_window_into_pixels(
    canvas: (u32, u32),
    pixels: &mut RgbaImage,
    offset: (i32, i32),
    win: (i64, i64, usize, usize),
    source: &[u8],
    region: &[u8],
    write: &[u8],
    strength: f32,
) -> Result<bool, String> {
    let (wx, wy, ww, wh) = win;
    let Some(n) = ww.checked_mul(wh) else {
        return Ok(false);
    };
    if n == 0 || !strength.is_finite() {
        return Ok(false);
    }
    // The memory bound first: it is a statement about the WINDOW, and it
    // also keeps `n * 3` below from having to be a checked multiply.
    if let Some(message) = over_window_limit(ww, wh) {
        return Err(message);
    }
    if source.len() < n * 3 || region.len() < n || write.len() < n {
        return Ok(false);
    }
    let strength = strength.clamp(0.0, 1.0);
    let (lw, lh) = pixels.dimensions();
    let (off_x, off_y) = (i64::from(offset.0), i64::from(offset.1));
    // Window pixel -> byte index of the layer pixel under it, or None when
    // that pixel is off-canvas or off-layer. Same canvas->layer mapping as
    // `RzDocument::painting_layer` (`doc.rs`), in i64 so an extreme offset
    // cannot wrap.
    let layer_byte = |wxi: usize, wyi: usize| -> Option<usize> {
        let cx = wx + wxi as i64;
        let cy = wy + wyi as i64;
        if cx < 0 || cy < 0 || cx >= i64::from(canvas.0) || cy >= i64::from(canvas.1) {
            return None;
        }
        let lx = cx - off_x;
        let ly = cy - off_y;
        if lx < 0 || ly < 0 || lx >= i64::from(lw) || ly >= i64::from(lh) {
            return None;
        }
        Some(((ly as u64 * u64::from(lw) + lx as u64) * 4) as usize)
    };

    let raw: &mut [u8] = pixels;
    let mut covered = vec![false; n];
    let mut usable = vec![false; n];
    for wyi in 0..wh {
        for wxi in 0..ww {
            let i = wyi * ww + wxi;
            covered[i] = region[i] >= COVERED_THRESHOLD;
            // Usable = the solve may read and write this pixel: inside the
            // canvas, inside the layer, and not fully transparent.
            usable[i] = layer_byte(wxi, wyi).is_some_and(|di| raw[di + 3] > 0);
        }
    }
    let solve = Region {
        w: ww,
        h: wh,
        covered: &covered,
        usable: &usable,
    };
    let max_diameter = ww.max(wh);
    let mut b = vec![0f32; n];
    let mut u = vec![0f32; n];
    let mut changed = false;
    for channel in 0..3 {
        for wyi in 0..wh {
            for wxi in 0..ww {
                let i = wyi * ww + wxi;
                b[i] = 0.0;
                if !(covered[i] && usable[i]) {
                    continue;
                }
                if let Some(di) = layer_byte(wxi, wyi) {
                    b[i] = f32::from(raw[di + channel]) - f32::from(source[i * 3 + channel]);
                }
            }
        }
        u.fill(0.0);
        solve_membrane(&solve, &b, max_diameter, &mut u);
        for wyi in 0..wh {
            for wxi in 0..ww {
                let i = wyi * ww + wxi;
                if !(covered[i] && usable[i]) {
                    continue;
                }
                let weight = f32::from(write[i]) / 255.0 * strength;
                if weight <= 0.0 {
                    continue;
                }
                let Some(di) = layer_byte(wxi, wyi) else {
                    continue;
                };
                let old = raw[di + channel];
                let healed = f32::from(source[i * 3 + channel]) + u[i];
                let out = f32::from(old) + weight * (healed - f32::from(old));
                // Round half-up, clamping only here: `source + u` may leave
                // [0, 255] where the data genuinely does.
                let new = (out.clamp(0.0, 255.0) + 0.5).floor() as u8;
                if new != old {
                    raw[di + channel] = new;
                    changed = true;
                }
            }
        }
    }
    Ok(changed)
}

/// The refusal for a window over [`MAX_SOLVE_WINDOW_PIXELS`], or `None` when
/// it fits. Both the healing brush (before it builds a component's buffers)
/// and the shared seam (for every other caller) ask this, so the sentence
/// the user reads has one home.
fn over_window_limit(ww: usize, wh: usize) -> Option<String> {
    let pixels = (ww as u64).checked_mul(wh as u64)?;
    if pixels <= MAX_SOLVE_WINDOW_PIXELS {
        return None;
    }
    let megapixels = |v: u64| v as f64 / 1_000_000.0;
    Some(format!(
        "the healed region spans a {ww} x {wh} box ({:.1} megapixels); healing needs working \
         buffers over that box and is limited to {:.0} megapixels — heal it in shorter \
         strokes, or select a smaller region.",
        megapixels(pixels),
        megapixels(MAX_SOLVE_WINDOW_PIXELS)
    ))
}

/// The refusal for a call whose components' boxes together exceed
/// [`MAX_HEAL_PLAN_PIXELS`], or `None` when they fit. Worded for the two
/// gestures that reach it — a stroke and a dragged region — exactly as
/// [`over_window_limit`] words the per-component bound.
fn over_plan_limit(parts: &[Component], w: u32, h: u32) -> Option<String> {
    let mut total = 0u64;
    for part in parts {
        let (x0, y0, x1, y1) = part.box_padded(w, h);
        let box_pixels = u64::from(x1 - x0 + 1) * u64::from(y1 - y0 + 1);
        total = total.saturating_add(box_pixels);
    }
    if total <= MAX_HEAL_PLAN_PIXELS {
        return None;
    }
    let megapixels = |v: u64| v as f64 / 1_000_000.0;
    Some(format!(
        "the healed region falls in {} separate places whose working boxes come to {:.0} \
         megapixels; healing needs working buffers over every one of them and is limited to \
         {:.0} megapixels in one go — heal it in shorter strokes, or select a smaller region.",
        parts.len(),
        megapixels(total),
        megapixels(MAX_HEAL_PLAN_PIXELS)
    ))
}

/// One 4-connected run of covered canvas pixels. This is the MASTER copy for
/// the whole healing family: `doc_inpaint` splits its hole into the same
/// components with the same walk rather than keeping a second one.
pub(crate) struct Component {
    /// Canvas pixel indices, in discovery order.
    pub(crate) pixels: Vec<u32>,
    /// The run's inclusive bounding box, `(x0, y0, x1, y1)`.
    pub(crate) bounds: (u32, u32, u32, u32),
}

impl Component {
    /// The component's bounding box padded by one pixel and clamped to the
    /// canvas — the ring of destination pixels the solve needs in order to
    /// see an uncovered usable neighbour.
    fn box_padded(&self, w: u32, h: u32) -> (u32, u32, u32, u32) {
        let (x0, y0, x1, y1) = self.bounds;
        (
            x0.saturating_sub(1),
            y0.saturating_sub(1),
            (x1 + 1).min(w - 1),
            (y1 + 1).min(h - 1),
        )
    }

    /// The three window planes the solve takes: the coverage `region` (this
    /// component's overlay alpha only, so a neighbouring blob that happens
    /// to fall inside the same window cannot leak into this solve), the
    /// hard-cut `write` weight, and the un-premultiplied straight-RGB
    /// `source`.
    fn window_buffers(
        &self,
        overlay: &[u8],
        canvas_w: usize,
        origin: (u32, u32),
        size: (usize, usize),
    ) -> (Vec<u8>, Vec<u8>, Vec<u8>) {
        let (ww, wh) = size;
        let mut region = vec![0u8; ww * wh];
        let mut write = vec![0u8; ww * wh];
        for &p in &self.pixels {
            let (cx, cy) = (p as usize % canvas_w, p as usize / canvas_w);
            let i = (cy - origin.1 as usize) * ww + (cx - origin.0 as usize);
            region[i] = overlay[p as usize * 4 + 3];
            // The hard cut of the module doc: full weight inside the α = 128
            // contour, nothing outside it.
            write[i] = 255;
        }
        let mut source = vec![0u8; ww * wh * 3];
        for wyi in 0..wh {
            for wxi in 0..ww {
                let i = wyi * ww + wxi;
                let p = (origin.1 as usize + wyi) * canvas_w + (origin.0 as usize + wxi);
                let alpha = overlay[p * 4 + 3];
                if alpha == 0 {
                    continue;
                }
                // Straight source colour: divide the premultiplied bytes by
                // their own alpha, as `doc_paint::painting_layer_blend`
                // (the master copy of this un-premultiply) does; the min
                // guards a malformed colour byte above its alpha.
                for c in 0..3 {
                    let v = f32::from(overlay[p * 4 + c]) * 255.0 / f32::from(alpha);
                    source[i * 3 + c] = v.min(255.0).round() as u8;
                }
            }
        }
        (region, write, source)
    }
}

/// Splits the covered canvas plane into 4-connected components — the ONE
/// component walk the healing brush, spot healing and content-aware fill all
/// use, so they cannot disagree about what a region is. The BFS mirrors
/// `doc_select::grow_region` (`doc_select.rs`), the master copy of this walk;
/// it differs only in its predicate (a coverage flag instead of colour
/// similarity) and in collecting the run rather than painting a mask.
pub(crate) fn components(covered: &[bool], w: usize, h: usize) -> Vec<Component> {
    let mut seen = vec![false; w * h];
    let mut out = Vec::new();
    let mut queue: VecDeque<u32> = VecDeque::new();
    for start in 0..w * h {
        if seen[start] || !covered[start] {
            continue;
        }
        seen[start] = true;
        queue.push_back(start as u32);
        let mut pixels = Vec::new();
        let (mut x0, mut y0) = (u32::MAX, u32::MAX);
        let (mut x1, mut y1) = (0u32, 0u32);
        while let Some(p) = queue.pop_front() {
            pixels.push(p);
            let (x, y) = (p as usize % w, p as usize / w);
            x0 = x0.min(x as u32);
            y0 = y0.min(y as u32);
            x1 = x1.max(x as u32);
            y1 = y1.max(y as u32);
            let neighbors = [
                (x > 0, p.wrapping_sub(1)),
                (x + 1 < w, p + 1),
                (y > 0, p.wrapping_sub(w as u32)),
                (y + 1 < h, p + w as u32),
            ];
            for (inside, q) in neighbors {
                let q = q as usize;
                if !inside || seen[q] || !covered[q] {
                    continue;
                }
                seen[q] = true;
                queue.push_back(q as u32);
            }
        }
        out.push(Component {
            pixels,
            bounds: (x0, y0, x1, y1),
        });
    }
    out
}
