//! What a content-aware call will cost, decided BEFORE any of it runs: every
//! component's window, the sampling ring it may sample from, and whether the
//! call fits [`MAX_INPAINT_TARGET_PIXELS`] at all.
//!
//! `doc_inpaint` owns the caps, their numbers and the sentences that report
//! them; this is the pass that measures the call against them. It is a
//! separate pass, and separate from the fill, for two reasons — both of them
//! defects the old spend-as-you-go form had:
//!
//! 1. **A refusal must be cheap.** The budget used to be spent component by
//!    component inside the fill loop, so a call that was going to be refused
//!    first inpainted and Poisson-solved every component before the one that
//!    busted the cap, and then dropped all of it. Measured in the app on a
//!    5000 x 5000 canvas, eight thin scratches (240 k covered pixels, a
//!    quarter of the hole cap) froze the main thread for 13 s and filled
//!    nothing; four of the same scratches succeeded in 12 s, so essentially
//!    the whole cost of a fill was paid for the privilege of being told no.
//! 2. **The narrowing must be uniform.** First come, first served made the
//!    refusal an allocation artifact rather than a real limit: the first
//!    components took their full automatic ring and the last ones were cut
//!    to [`RING_MIN`] against what was left, so a 900-speck dust
//!    selection of 129 600 covered pixels — 13 % of the hole cap — was
//!    refused at the sheet's default ring while the same selection at a
//!    narrower ring succeeded, and the refusal quoted the LAST component's
//!    post-halving ring rather than the ring the earlier ones had spent. Here
//!    one narrowing is chosen for the whole call and applied to every
//!    component, so the answer does not depend on which speck the component
//!    walk reached first.
//!
//! # Two ladders, and why the cheap one has to come first
//!
//! Measuring the dilated area EXACTLY needs a distance transform over each
//! component's window, and that transform is the thing this pass was caught
//! charging for. One window is at least `(2·RING_MIN + 1)²` = 1 849 px
//! whatever the component's size, and it is `(2·ring + 1)²` when the caller
//! asks for a wide one — so running it per component, up front, made the
//! planner cost `components × ring²` with nothing bounding either factor.
//!
//! A 1200 x 1200 canvas whose selection is one-pixel specks — every covered
//! pixel its own component, the shape a grain, dust or halftone selection
//! makes — every count below well under `MAX_INPAINT_HOLE_PIXELS`, and every
//! one of them refused:
//!
//! | specks | old | now |
//! |---|---|---|
//! | 20 000 | 0.60 s | 0.004 s |
//! | 90 000 | 2.4 s | 0.007 s |
//! | 250 000 | 4.9 s | 0.011 s |
//! | 360 000 | (not measured) | 0.015 s |
//! | 999 698 | 28.7 s | (not measured) |
//!
//! and the same defect on the other axis, a selection that is ACCEPTED:
//! 1131 disjoint 12-px specks on a 2000 x 1500 photograph took 78.9 s at
//! `ring: 512` against 3.0 s at 21, and now takes 3.8 s against 3.6 s.
//!
//! So the ladder is climbed twice. The first pass ([`cheap_start`]) uses only
//! each component's bounding box and pixel count — arithmetic, no allocation,
//! no transform — and answers the two questions that need no exactness:
//! **is there any step this call could possibly fit at**, and **which step is
//! the widest ring worth measuring**. Every bound it uses is a rigorous one:
//!
//! - a 4-connected run occupies every column of its own bounding box and
//!   every row of it, and each of those pixels drags at least `ring + 1` of
//!   its column (or row) into the dilated set, so `bw·(ring+1)` and
//!   `bh·(ring+1)` are both floors;
//! - the dilated set contains a whole disc around any one of the component's
//!   pixels, and the fewest canvas pixels such a disc can cover is a quarter
//!   of it in the tightest corner ([`floor_disc`]);
//! - and the component itself is in there.
//!
//! The largest of those, summed over the components and compared against
//! [`MAX_INPAINT_TARGET_PIXELS`], is what refuses a dust selection in
//! milliseconds: at [`RING_MIN`] a single speck floors at 367 px, so more
//! than ~10 900 separate parts cannot fit however small they are, and no
//! window is ever built for them.
//!
//! The second pass is the exact one, and it runs only from the step the
//! cheap pass cleared. Its windows are sized from THAT step's ring rather
//! than from the ring the caller asked for, which is the other half of the
//! same defect: `ring: 512` on a scattered selection used to multiply every
//! window by 26 and pay for it twice (once here, once in `fill_component`),
//! while the schema promised the ring was free.
//!
//! # Why a total-window budget as well
//!
//! [`MAX_INPAINT_TARGET_PIXELS`] bounds the DILATED area, and a long thin
//! component dilates to far less than its bounding box: twenty three-pixel
//! scratches across a 3000 x 3000 photograph dilate to 2.7 M — inside the
//! cap — while their windows come to 99 megapixels of transform and window
//! planes, and measured 14.1 s. `doc_inpaint::MAX_INPAINT_PLAN_PIXELS`
//! bounds that sum, and the ladder narrows against it exactly as it narrows
//! against the work cap — though narrowing rarely helps there, since a
//! window is mostly its component's bounding box.

use crate::doc_heal::{Component, MAX_SOLVE_WINDOW_PIXELS};
use crate::doc_inpaint::{
    plan_cap_message, target_cap_message, window_cap_message, Caller, Measured,
    MAX_INPAINT_PLAN_PIXELS, MAX_INPAINT_TARGET_PIXELS,
};
use crate::inpaint_em::hole_distance;
use crate::patchmatch::PATCH;

/// The narrowest ring the automatic rules will choose: three patches, so a
/// source patch has somewhere to move even in the narrowest band.
pub(crate) const RING_MIN: f32 = 3.0 * PATCH as f32;
/// The widest. Past this the fill is no longer sampling the blemish's
/// neighbourhood, it is sampling the photograph.
const RING_MAX: f32 = 512.0;

/// One component's plan: where it will be filled, and how wide a band around
/// it the fill may copy from.
pub(crate) struct ComponentPlan {
    /// The working window in canvas pixels, `(x0, y0, w, h)`, sized from the
    /// ring below — the one the call settled on, NOT the one the caller
    /// asked for. Sizing it from the request instead left the ring a cost
    /// multiplier on everything downstream (`fill_component`'s planes, its
    /// transform, its integral image) while the narrowing restricted only
    /// which pixels could be sampled; see the module doc.
    pub(crate) window: (usize, usize, usize, usize),
    /// The sampling ring in px, after the whole call's uniform narrowing.
    pub(crate) ring: f32,
}

impl ComponentPlan {
    /// The window's area — the quantity `MAX_INPAINT_PLAN_PIXELS` is summed
    /// against, and the one a preview's reduction is chosen from.
    pub(crate) fn window_pixels(&self) -> u64 {
        self.window.2 as u64 * self.window.3 as u64
    }
}

/// Sizes every component of the call and narrows their rings, uniformly,
/// until the total dilated area fits [`MAX_INPAINT_TARGET_PIXELS`].
///
/// `ring` is the caller's request (0 = automatic) and `canvas` the document's
/// size. `Err` — a sentence for the user, worded for `caller` — when one
/// component's window busts the memory bound, when the call's windows bust
/// [`MAX_INPAINT_PLAN_PIXELS`], or when even [`RING_MIN`] everywhere leaves
/// the call over the work cap.
pub(crate) fn plan(
    components: &[Component],
    canvas: (usize, usize),
    ring: u32,
    caller: Caller,
) -> Result<Vec<ComponentPlan>, String> {
    if components.is_empty() {
        return Ok(Vec::new());
    }
    let asked: Vec<f32> = components
        .iter()
        .map(|component| requested_ring(ring, component.pixels.len() as u64))
        .collect();
    // Every component takes the same NUMBER of narrowing steps, so the ladder
    // runs until the widest ring asked for has reached the floor.
    let steps = steps_to_floor(asked.iter().copied().fold(RING_MIN, f32::max));

    // --- ladder one: bounding boxes and arithmetic, no window built -------
    let start = cheap_start(components, &asked, steps, canvas, caller)?;

    // --- ladder two: the exact dilated area, one transform per component --
    let windows: Vec<(usize, usize, usize, usize)> = components
        .iter()
        .zip(&asked)
        .map(|(component, asked)| window_of(component, narrowed(*asked, start), canvas))
        .collect();
    let mut dilated = vec![vec![0u64; steps + 1]; components.len()];
    for (k, component) in components.iter().enumerate() {
        let (x0, y0, ww, wh) = windows[k];
        let mut hole = vec![false; ww * wh];
        for &p in &component.pixels {
            let (cx, cy) = (p as usize % canvas.0, p as usize / canvas.0);
            hole[(cy - y0) * ww + cx - x0] = true;
        }
        // The same transform the fill measures its own ring against, and the
        // reason neither needs a second definition of "dilated".
        let sdf = hole_distance(&hole, ww, wh);
        let rings: Vec<f32> = (start..=steps).map(|s| narrowed(asked[k], s)).collect();
        // One pass, then a suffix sum: `rings` descends, so the deepest step
        // whose ring still reaches a pixel decides every shallower step too.
        // The lookup is a binary search rather than a scan because the ladder
        // is fifteen entries and the window can be tens of megapixels.
        let mut deepest = vec![0u64; rings.len()];
        for s in &sdf {
            let reached = rings.partition_point(|r| *r >= -*s);
            if reached > 0 {
                deepest[reached - 1] += 1;
            }
        }
        let mut running = 0u64;
        for (offset, count) in deepest.iter().enumerate().rev() {
            running += count;
            dilated[k][start + offset] = running;
        }
    }
    let total = |step: usize| -> u64 {
        dilated
            .iter()
            .fold(0u64, |sum, counts| sum.saturating_add(counts[step]))
    };
    for step in start..=steps {
        if total(step) <= MAX_INPAINT_TARGET_PIXELS {
            return Ok(components
                .iter()
                .zip(&asked)
                .map(|(component, requested)| {
                    let ring = narrowed(*requested, step);
                    ComponentPlan {
                        window: window_of(component, ring, canvas),
                        ring,
                    }
                })
                .collect());
        }
    }
    Err(target_cap_message(
        caller,
        Measured::Exactly(total(steps)),
        RING_MIN,
    ))
}

/// The shallowest ladder step whose CHEAP bounds all fit, or the refusal the
/// deepest step earned. Bounding boxes and pixel counts only: nothing here
/// allocates a window or runs a transform, which is the whole point.
///
/// The three tests are all monotone in the step (a narrower ring dilates to
/// less and needs a smaller window), so one ascending scan settles it. They
/// are checked in the order their refusals are worth reading — a window over
/// the MEMORY bound is a different problem from a call that is simply too
/// much work.
fn cheap_start(
    components: &[Component],
    asked: &[f32],
    steps: usize,
    canvas: (usize, usize),
    caller: Caller,
) -> Result<usize, String> {
    // `floor_disc` depends only on the radius and the canvas, and a scattered
    // selection asks the same question a million times: answer it once per
    // integer radius up to the widest ring in play, which for a dust
    // selection is [`RING_MIN`] and a few hundred float operations.
    let widest = asked.iter().copied().fold(RING_MIN, f32::max).ceil() as usize;
    let disc: Vec<u64> = (0..=widest).map(|r| floor_disc(r as f32, canvas)).collect();
    let area = (canvas.0 as u64).saturating_mul(canvas.1 as u64);
    let mut last: Option<String> = None;
    for step in 0..=steps {
        let mut windows = 0u64;
        let mut floor = 0u64;
        let mut oversized: Option<(usize, usize, u64)> = None;
        for (component, asked) in components.iter().zip(asked) {
            let ring = narrowed(*asked, step);
            let (_, _, ww, wh) = window_of(component, ring, canvas);
            let pixels = (ww as u64).saturating_mul(wh as u64);
            if pixels > MAX_SOLVE_WINDOW_PIXELS {
                oversized = Some((ww, wh, pixels));
                break;
            }
            windows = windows.saturating_add(pixels);
            floor = floor.saturating_add(floor_dilated(component, ring, canvas, &disc, area));
        }
        if let Some((ww, wh, pixels)) = oversized {
            last = Some(window_cap_message(caller, ww, wh, pixels));
            continue;
        }
        if windows > MAX_INPAINT_PLAN_PIXELS {
            last = Some(plan_cap_message(caller, windows));
            continue;
        }
        if floor > MAX_INPAINT_TARGET_PIXELS {
            last = Some(target_cap_message(
                caller,
                Measured::AtLeast(floor),
                RING_MIN,
            ));
            continue;
        }
        return Ok(step);
    }
    // Every step failed, and `last` holds the narrowest ring's own refusal —
    // the honest one, since it is the most the rules would do for the caller.
    Err(last.unwrap_or_else(|| target_cap_message(caller, Measured::AtLeast(0), RING_MIN)))
}

/// A rigorous LOWER bound on how many canvas pixels lie within `ring` of the
/// component, from its bounding box and pixel count alone. See the module
/// doc for the three floors it takes the largest of.
fn floor_dilated(
    component: &Component,
    ring: f32,
    canvas: (usize, usize),
    disc: &[u64],
    area: u64,
) -> u64 {
    let (x0, y0, x1, y1) = component.bounds;
    let (bw, bh) = (u64::from(x1 - x0 + 1), u64::from(y1 - y0 + 1));
    let reach = ring.max(0.0).floor() as u64 + 1;
    let by_columns = bw.saturating_mul(reach.min(canvas.1 as u64));
    let by_rows = bh.saturating_mul(reach.min(canvas.0 as u64));
    let around = disc
        .get(ring.max(0.0) as usize)
        .copied()
        .unwrap_or_else(|| floor_disc(ring, canvas));
    (component.pixels.len() as u64)
        .max(by_columns)
        .max(by_rows)
        .max(around)
        .min(area)
}

/// The fewest canvas pixels a disc of radius `ring` can cover wherever its
/// centre sits: a quarter of it, in the tightest corner, clipped to the
/// canvas on both axes. Counted column by column rather than taken as
/// `π·r²/4`, because a canvas narrower than the radius clips the estimate
/// and a bound that is only usually true is not a bound.
///
/// A corner really is the worst place for the centre. A centre at `a` has
/// `min(a, r)` columns of the disc to its left and `min(cw−1−a, r)` to its
/// right, and those two counts sum to at least the `min(cw−1, r)` a corner
/// gets on its one side; since a column's own height is non-increasing in
/// its distance from the centre, splitting the same number of columns over
/// two sides can only add.
fn floor_disc(ring: f32, canvas: (usize, usize)) -> u64 {
    let r = ring.max(0.0);
    let columns = (r.floor() as usize + 1).min(canvas.0);
    (0..columns)
        .map(|dx| {
            let rest = (r * r - (dx * dx) as f32).max(0.0).sqrt();
            ((rest.floor() as usize) + 1).min(canvas.1) as u64
        })
        .sum()
}

/// The ring the caller asked for, in pixels, before the narrowing fits it: 0
/// means automatic (the hole's own radius), and any value — explicit ones
/// included — is widened from below by [`RING_MIN`] and by half the hole's
/// radius. See rule 1 of `doc_inpaint`'s module doc, and its cost section for
/// what passing a large ring on a scattered selection actually buys.
fn requested_ring(ring: u32, area: u64) -> f32 {
    let radius = (area as f64 / std::f64::consts::PI).sqrt().ceil() as f32;
    let asked = if ring == 0 { radius } else { ring as f32 };
    asked
        .max(RING_MIN)
        .max(radius * 0.5)
        .clamp(RING_MIN, RING_MAX)
}

/// The component's bounding box grown by `ring` and clamped to the canvas.
fn window_of(
    component: &Component,
    ring: f32,
    canvas: (usize, usize),
) -> (usize, usize, usize, usize) {
    let pad = ring.ceil() as u32;
    let (bx0, by0, bx1, by1) = component.bounds;
    let x0 = bx0.saturating_sub(pad) as usize;
    let y0 = by0.saturating_sub(pad) as usize;
    let ww = (bx1.saturating_add(pad) as usize).min(canvas.0 - 1) - x0 + 1;
    let wh = (by1.saturating_add(pad) as usize).min(canvas.1 - 1) - y0 + 1;
    (x0, y0, ww, wh)
}

/// One narrowing step, in ring width. A fifth off per step rather than a
/// half: the ring is a QUALITY knob (rule 1 widens it from below because a
/// narrow ring tiles), so the fit should give up as little of it as the cap
/// demands. Halving overshot badly — a call 3 % over the budget came back
/// with every ring at half width and the total at a quarter of what was
/// allowed. Fifteen steps take [`RING_MAX`] to [`RING_MIN`].
const NARROW_STEP: f32 = 0.8;

/// `ring` narrowed `steps` times, never below [`RING_MIN`].
fn narrowed(ring: f32, steps: usize) -> f32 {
    (ring * NARROW_STEP.powi(steps as i32)).max(RING_MIN)
}

/// How many steps take the widest ring in the call down to [`RING_MIN`] — at
/// most fifteen, since rule 1 already clamps every ring to [`RING_MAX`].
fn steps_to_floor(widest: f32) -> usize {
    let mut steps = 0;
    while narrowed(widest, steps) > RING_MIN {
        steps += 1;
    }
    steps
}
