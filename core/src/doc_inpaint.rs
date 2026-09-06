//! Content-aware inpainting on the layered document: spot healing (the
//! footprint is the hole) and Content-Aware Fill (the selection is the hole).
//!
//! Both are the same pipeline, and it is short to state: split the hole into
//! connected components; around each, take a window of its bounding box plus
//! the sampling ring; PatchMatch-inpaint the hole from the valid pixels in
//! that ring (`patchmatch`, driven level by level from `inpaint_em`); then
//! hand the result to the ONE healing write-back,
//! [`crate::doc_heal::heal_window_into_pixels`], which Poisson-blends the
//! invented texture to the illumination it lands in. The two
//! algorithms compose exactly: PatchMatch matches TEXTURE and is indifferent
//! to level, the membrane solve fixes LEVEL and cannot touch texture, and
//! because the solve is exact for a zero mismatch a fill that was already
//! correct is left byte-identical.
//!
//! # What each op reads
//!
//! - The HOLE — the set PatchMatch re-estimates — is read from the overlay's
//!   ALPHA for spot healing (its RGB is deliberately ignored: that overlay
//!   carries pure coverage, there is no sampled source) and from the
//!   selection mask for the fill, and the two take it at different
//!   thresholds. A brush dab is cut hard at `>= 128`; a selection is taken
//!   wherever it touches at all (`> 0`), so a feathered edge is filled and
//!   faded rather than stepped. [`Caller::hole_threshold`] holds the reason.
//! - The SOURCE the inpaint samples is `self.flattened()` when `sample_all`
//!   is set and layer `idx`'s own canvas-placed pixels otherwise. Unlike the
//!   healing brush's identically named option — which the app implements by
//!   choosing the snapshot it draws into the overlay — this one has to live
//!   in the core: here the core GENERATES the source, so only it can know
//!   where to sample. `sample_all` therefore costs one full composite, once
//!   per call.
//! - The DESTINATION whose illumination the fill takes is always layer
//!   `idx`'s own pixels, and its alpha is never touched: a hole over
//!   transparent pixels stays transparent (there is nothing to blend to, and
//!   the write-back's contract is that alpha does not move).
//! - The WRITE WEIGHT differs between the two, and follows the same split.
//!   Content-Aware Fill weights the write-back by the selection's own
//!   coverage bytes, so a feathered edge genuinely blends; spot healing takes
//!   `doc_heal`'s full weight inside the α = 128 contour and nothing outside
//!   it, exactly as the healing brush does — hardness shrinks the footprint,
//!   it does not fade the heal. Because the hole runs to the same threshold
//!   the weight starts from, the fill's contribution rises CONTINUOUSLY from
//!   0: measured on a 200 px plasma with a 40 px ramp, the mean distance the
//!   fill moves a pixel is 7 code values at coverage 1-24, 50 at 64-111, 70
//!   at 112-127, 77 at 128-143 and 138 at 215-255. Cutting the hole at 128
//!   and weighting by the byte inside it made that sequence 0, 0, 0, 77, 138
//!   — a hard edge on the 50 % contour of an edge the user asked to be soft,
//!   which is what `a_feathered_selection_blends_across_its_whole_ramp`
//!   guards. [`Caller`] is the two-way distinction and nothing else; the
//!   entry point is also what words every refusal, since a stroke and a
//!   selection cannot be told to do the same thing about a cap.
//!
//! # Per component, and what that costs
//!
//! Each component is filled from its OWN neighbourhood, so a scatter of
//! blemishes costs the sum of their own boxes and not one box around all of
//! them, and two blemishes far apart cannot borrow each other's colour. The
//! source image is read once, before the first component: components are
//! filled from the ORIGINAL surroundings and never from each other's results.
//! Two blemishes closer together than a patch may therefore see each other's
//! unfilled pixels inside a target patch's distance — never as a SOURCE,
//! since every hole is excluded from the valid set.
//!
//! What is emphatically NOT per component is the layer buffer, nor the caps.
//! `inpaint` clones the layer's pixels once and threads that copy through
//! every component, `doc_heal::heal_layer`'s rule and for its reason: a fresh
//! document per component cost a full layer copy each time — ~20 ms per speck
//! on a 100-megapixel canvas, twenty seconds of `memcpy` for a thousand-speck
//! dust selection before any inpainting. The caps are below.
//!
//! # The sampling ring
//!
//! `ring` is the width in pixels of the band around the hole the fill may
//! copy from; 0 means automatic. It is then subject to three rules, in order,
//! and every one of them is visible to the user in prose because the ring is
//! a user-facing number:
//!
//! 1. **Widened from below by the hole itself**, never under `3·PATCH` and
//!    never under half the hole's own radius. An 8-px ring around a
//!    1000 × 1000 hole would offer a few thousand origins for a million
//!    targets, which does not look like texture — it looks like tiling. It
//!    applies to an EXPLICIT ring too (around a megapixel hole a requested
//!    21, 48, 100 and 282 are all the same 282), and it is a QUALITY rule
//!    rather than a cost one — see the cost section for what that does and
//!    does not mean.
//! 2. **Narrowed, uniformly and in advance, to fit the caps.** If the hole
//!    dilated by the ring would take the call past
//!    [`MAX_INPAINT_TARGET_PIXELS`] — or its windows past
//!    [`MAX_INPAINT_PLAN_PIXELS`] — EVERY component's ring is narrowed by
//!    the same number of steps of a fifth until the total fits, down to
//!    `3·PATCH`; only if even that busts a cap is the call refused. A
//!    mildly tiled fill is better than a refusal. `inpaint_plan` does this
//!    before any component is filled, and its module doc holds the three
//!    defects that placement fixes: a budget spent first-come-first-served
//!    refused a scatter of specks that fits comfortably, refused it only
//!    after paying for most of the fill, and sized every window from the
//!    ring the caller ASKED for rather than the one the narrowing chose.
//! 3. **Widened again, per level, if the origins are starved.** Below
//!    `patchmatch::min_origins` the ring doubles and the admissible set is
//!    rebuilt, up to the whole window. That widening never grows the WINDOW,
//!    which was sized from rule 1 — it only relaxes the restriction inside
//!    it, so it can never bust a cap that was already checked.
//!
//! # The caps, and the order they are checked in
//!
//! ```text
//! MAX_INPAINT_HOLE_PIXELS    the CALL's covered pixel count — PatchMatch's targets
//! MAX_INPAINT_TARGET_PIXELS  the CALL's hole DILATED by the ring — the real work
//! MAX_INPAINT_PLAN_PIXELS    the CALL's working WINDOWS — the boxes, summed
//! MAX_SOLVE_WINDOW_PIXELS    one component's window — a MEMORY bound (doc_heal)
//! ```
//!
//! Each caps a quantity that actually drives cost. None of them caps ONE
//! hole's bounding box, which was the obvious thing to cap and the wrong
//! one: a three-pixel scratch, a wire, a stray hair — content-aware fill's
//! single most common use — has a box of nearly the whole photograph and an
//! area of a few thousand pixels, and refusing that would be worse than the
//! transient. What the boxes are capped by is their SUM, and only because
//! the dilated cap cannot see them: twenty such scratches on one canvas are
//! 3.2 M dilated (inside the work cap) and 190 megapixels of window, which
//! measured 16.3 s.
//!
//! **The first two bound the CALL, not one part of it**, and the difference
//! is the whole point of having them: a magic-wand, Colour Range or Select
//! Subject selection is routinely dozens of components, so measured per
//! component the caps bounded nothing — four disjoint 620 × 620 squares, half
//! again the stated megapixel, were accepted and cost the sum. The hole count
//! is summed once, before the component walk; the dilated count is summed by
//! `inpaint_plan`, over every component, before any of them is filled.
//! `MAX_SOLVE_WINDOW_PIXELS` stays per component on purpose — it bounds the
//! working buffers ONE solve allocates, and those are freed before the next.
//!
//! **Every one of them is checked before a pixel moves**, and that is a
//! contract, not an implementation detail: a caller may try a selection and
//! be told no without paying for a fill. What a refusal costs is the
//! component walk plus `inpaint_plan`'s first, arithmetic ladder — 7 ms for
//! a 90 000-part dust selection, 15 ms for 143 canvas-spanning scratches —
//! and only a selection that clears every cheap bound goes on to pay for
//! distance transforms (0.22 s for the one-component comb of
//! `a_refused_fill_costs_far_less_than_a_fill`, where the fill it refused
//! costs 1.6 s). It used to cost the whole fill, 13 s of frozen main thread
//! in the app to be told no, because the budget was spent inside the loop
//! that did the work; and then it cost a full-resolution distance transform
//! per component, which for a dust selection is the same disaster in a
//! different place — 28.7 s to refuse a million one-pixel specks.
//!
//! # Preview
//!
//! `preview` reduces the WHOLE pipeline — the distance transform, the origin
//! list, the field, the EM loop and the Poisson solve — onto a window
//! `box_reduced` by the smallest `k ∈ {1, 2, 4, 8, 16}` that brings the call
//! under BOTH `inpaint_preview::PREVIEW_WINDOW_PIXELS` and
//! `PREVIEW_HOLE_PIXELS`, and bilinearly upsamples the healed window back.
//! The cost is bounded by WORK rather than by a level count, which is what
//! keeps the sheet's re-render from beachballing its own Cancel button. The
//! structure of the result is final; its finest texture is not, and the
//! full-size blend runs on Apply.
//!
//! **The reduction is chosen from the WINDOWS the plan has already measured**,
//! summed over the parts the preview will actually fill — not from the covered
//! count, which this module's own cost model says does not drive cost. Chosen
//! from the covered count it was wrong for the shape called out three
//! paragraphs above as content-aware fill's single most common use: a
//! three-pixel scratch corner to corner on a 5000 × 5000 scan covers 15 000
//! pixels, under `PREVIEW_HOLE_PIXELS`, so `preview_factor` answered 1 and the
//! "preview" ran the identical full-resolution pipeline as the commit —
//! measured 4.27 s against a 4.10 s fill, with Cancel blocking the main thread
//! on it and every edited field arming another render. The same shape at
//! 3000 × 3000 now previews in 0.53 s against a 1.18 s fill.
//!
//! `k` is the CALL's, not one component's. Chosen per component it bounded
//! nothing either, because `preview_factor` is 1 for anything at or under
//! 40 000 pixels: twenty-five disjoint 200 × 200 blobs — the routine shape of
//! a dust or magic-wand selection — previewed every one of them at full
//! resolution, so the preview cost exactly what the fill it was previewing
//! cost (measured 8.7 s for both). The same selection now previews in 0.57 s
//! against an 8.4 s fill.
//!
//! One component may still be previewed FINER than the call's `k`, and
//! `fill_component`'s `preview_plane` is where: a reduction that leaves a
//! window under four patches on a side, or that thins the band of real pixels
//! between two nearby holes below one patch, has nothing to sample from and
//! would refuse a fill that succeeds. The test is the admissible-origin count
//! on the reduced plane itself, so the preview gives ground exactly where it
//! must and nowhere else.
//!
//! That escape hatch is also why `k` alone does not bound the preview, and
//! why [`crate::inpaint_preview::PREVIEW_MAX_PARTS`] exists. A component's
//! window is at least `2·RING_MIN` on a side, so a SMALL component can never
//! be reduced at all — and a small component still costs its window planes,
//! its transform, its pyramid, its integral image and a membrane solve,
//! about 3.4 ms of them. A dust selection is nothing but small components, so
//! the "reduced" preview ran every one of them at full resolution and cost
//! exactly what the fill cost: 900 12-px specks previewed in 2.30 s against a
//! 2.30 s fill, and 2 888 one-pixel specks — the most the work cap admits —
//! would have previewed in the fill's 9.8 s, with the sheet's Cancel blocking
//! the main thread on it. A preview therefore fills the BIGGEST 200 parts and
//! leaves the rest showing the original, which is honest for a preview and
//! bounds it at 0.6-0.7 s on every shape measured: 0.28 s for one megapixel
//! hole, 0.72 s for the 900 specks, 0.80 s for twenty-five 200 × 200 blobs.
//!
//! The reduction that makes the preview's hole is an OR over each block's
//! children — it must never LOSE a thin hole — while the pyramid's own
//! reduction (`patchmatch::reduce`) erodes it instead. The two want
//! opposite things and both are right: the preview's hole defines what gets
//! filled, the pyramid's has to shrink for a coarse level to be solvable.
//!
//! # Measured cost
//!
//! **What costs time is the region DILATED by its ring, plus the WINDOWS the
//! parts are worked in** — the two quantities [`MAX_INPAINT_TARGET_PIXELS`]
//! and [`MAX_INPAINT_PLAN_PIXELS`] bound, and the reason those are the caps
//! they are. It is emphatically not the selected count: the two are within a
//! small factor for a compact blob and nowhere near each other for a long
//! thin one, which is content-aware fill's most common shape. A linear fit
//! over the rows below gives **0.1 s per megapixel of window plus 1.2 s per
//! megapixel of dilated region**, and it is the model the caps are sized
//! from. `content_aware_tests`, `content_aware_cost_tests` and a probe run
//! beside them, this machine, `--release`:
//!
//! | case | selected | dilated | windows | total |
//! |---|---|---|---|---|
//! | 2000 x 1500 photograph, a 300 x 300 hole | 90 k | ~0.4 M | 0.4 M | 0.53 s |
//! | 2000 x 1500, a 3 px diagonal scratch | 6.5 k | ~0.23 M | 3 M | 0.60 s |
//! | 5000 x 5000, ONE 3 px scratch corner to corner | 15 k | ~1.0 M | 25 M | 4.2 s |
//! | 5000 x 5000, FOUR such scratches | 44 k | ~2.9 M | 57 M | 9.1 s |
//! | **the hole cap**: a 1000 x 1000 hole, ring 48 | 1 M | ~3 M | 2.4 M | 5.4 s |
//! | the same at ring 512 | 1 M | ~3 M | 4.1 M | 5.2 s |
//! | 2000 x 1500, 1131 12-px specks, ring 21 | 163 k | ~1.7 M | 17 M | 3.6 s |
//! | the same at ring 512 | 163 k | ~1.7 M | 17 M | 3.8 s |
//! | 3000 x 3000, ten 3 px scratches | 78 k | ~1.6 M | 68 M | 9.8 s |
//! | **the worst permitted call found**: ten 17 px scratches | 395 k | ~3.9 M | 71 M | 12.1 s |
//! | a `preview` of the megapixel hole | 1 M | — | — | 0.28 s |
//! | a `preview` of 900 12-px specks | 130 k | — | — | 0.69 s |
//! | a `preview` of one canvas-spanning 3 px scratch | 9 k | — | — | 0.53 s |
//! | REFUSED: 90 000 one-pixel specks | 90 k | — | — | 0.007 s |
//! | REFUSED: 143 canvas-spanning scratches | 288 k | — | — | 0.015 s |
//! | REFUSED on the work cap, one component | 163 k | — | — | 0.22 s |
//!
//! Read across the first three rows: a scratch selecting a sixth of what the
//! compact hole selects costs eight times as much, because its window is the
//! whole photograph and a 70 px ring around a 7 000 px diagonal is a
//! megapixel of work. So **the worst case for a permitted call is about
//! twelve seconds**, not the five the megapixel hole cap costs — inside the
//! fifteen the phase budgeted for a blocking Apply, and the app IS
//! unresponsive for that whole time, which the sheet's footnote, the catalog
//! description and the README all say in prose.
//!
//! It follows that the advice to a caller with a slow fill is not simply
//! "select less". What to make smaller is the region PLUS its ring, or the
//! number of separate parts: a shorter scratch is cheaper, a thinner one is
//! not, and splitting a long scratch into separate calls buys nothing at all
//! (the parts dilate to the same band and their boxes still overlap).
//!
//! **And it costs the same at the edge of the frame as in the middle of it**,
//! which for a while it did not: `patchmatch::should_coarsen` lost the whole
//! pyramid for any selection touching a border, at 2.3x the time and 2.9x the
//! error. That doc has the measurements;
//! `a_hole_at_the_canvas_edge_costs_like_one_in_the_middle` asserts the ratio
//! so it cannot rot again.
//!
//! **The ring the caller PASSES is not a cost knob**, which is a different
//! claim from the one above and also true — but only because rule 2 makes it
//! so, and for a while it did not. At the megapixel cap every ring costs the
//! same to within noise (5.4 s at a requested 48, widened to 282 by rule 1,
//! and 5.2 s at 512), because rule 1 raises a small ring from below and one
//! big window is one big window either way. On a SCATTERED selection that
//! reasoning does not apply and the claim was simply false: every component's
//! window was sized from the ring the caller asked for, so 1131 specks at
//! `ring: 512` built 1131 windows of a megapixel each and took 78.9 s against
//! 3.0 s at 21 — a 26x cost multiplier on a parameter the schema calls free,
//! paid on the main thread. `inpaint_plan` now sizes each window from the
//! ring the narrowing SETTLES on, so the same selection is 3.6 s at 21 and
//! 3.8 s at 512. `the_ring_does_not_drive_the_cost_at_the_cap` and
//! `the_ring_does_not_drive_the_cost_of_a_scattered_selection` assert both
//! ratios, so neither claim can rot.
//!
//! An earlier draft had the cost model backwards twice over. It said "32 s at
//! the automatic ring against 6.5 s at 48" — measured through an app macOS
//! had already demoted with App Nap, which makes every later op in that
//! process ~5x slower (the app's `AppActivity.swift` holds the measurement
//! and the assertion that prevents it) — and it then generalized a
//! 2000 x 1500 scratch measurement into "it costs like its area", which the
//! 5000 x 5000 rows above falsify by a factor of ten.
//!
//! The preview rows are the point of that parameter: a selection previews in
//! under a second whatever its shape, where the fill it previews takes three
//! to twelve. Part of a preview still runs at FULL resolution and that is
//! honest rather than a mistake — the window planes, the reduction itself and
//! the cheap ladder the caps are measured against — because the caps are
//! statements about the op being previewed, not about the preview. What the
//! reduction and the part cap bound is everything that grows without limit:
//! the search, the vote and the solve.

use image::RgbaImage;

use crate::doc::RzDocument;
use crate::doc_heal::{
    components, heal_window_into_layer, heal_window_into_pixels, Component, MAX_SOLVE_WINDOW_PIXELS,
};
use crate::inpaint_em::{hole_distance, inpaint_plane};
use crate::inpaint_plan::{plan, ComponentPlan, RING_MIN};
use crate::inpaint_preview::{
    dest_window, paste_window_into_pixels, preview_factor, reduce_all, reduce_any, reduce_rgb,
    reduce_rgba, upsample_rgb, MIN_PREVIEW_SIDE, PREVIEW_MAX_PARTS,
};
use crate::patchmatch::{sources, Plane, PATCH};
use crate::poisson::COVERED_THRESHOLD;

/// The largest hole ONE CALL will fill, in covered pixels — about 1000 x 1000.
/// It is the count of PatchMatch targets, hence very nearly the whole cost of
/// the search; the measured worst case at this number is in the module doc.
///
/// Every separate part of the selection counts towards it, and it is checked
/// once, before the component walk. Per component it would bound nothing: see
/// the module doc's cap section.
pub const MAX_INPAINT_HOLE_PIXELS: u64 = 1_000_000;

/// The largest hole-plus-ring ONE CALL will work over. The ring is what the
/// origin list, the integral image and the distance transform are sized from,
/// so this is the bound on everything the hole count does not already bound.
///
/// It is a total over every component rather than a test each of them takes
/// separately, for the same reason: what it bounds is the work the call does.
/// `inpaint_plan` measures it over the whole selection before any of it is
/// filled, and narrows every component's ring by the same steps to fit — so a
/// refusal costs a distance transform and not a fill, and which speck the
/// component walk reached first cannot decide the answer.
pub const MAX_INPAINT_TARGET_PIXELS: u64 = 4_000_000;

/// The largest total of WORKING WINDOWS one call will build. It bounds the
/// quantity [`MAX_INPAINT_TARGET_PIXELS`] deliberately does not: a component's
/// window is its bounding BOX plus the ring, and a long thin scratch's box is
/// nearly the whole photograph while it dilates to a fraction of it. Twenty
/// three-pixel scratches across a 3000 x 3000 picture dilate to 3.8 M — inside
/// the work cap — and come to 180 megapixels of window planes, distance
/// transform and integral image.
///
/// The number comes from the time budget, not from taste. Measured on this
/// machine a call costs about `0.1 s` per megapixel of window plus `1.2 s`
/// per megapixel of dilated region, so 80 megapixels of window with the work
/// cap's 4 megapixels of region is ~13 s — inside the 15 s the phase allows
/// a blocking Apply, and the only quantity that was previously unbounded.
/// Without it, thirty three-pixel scratches across a 3000 x 3000 photograph
/// (3.2 M dilated, comfortably inside the work cap) measured 16.3 s.
///
/// Like the work cap it is a total over the call, and `inpaint_plan` narrows
/// every ring by the same steps to fit it — though narrowing rarely helps
/// here, since a window is mostly its component's bounding BOX. What makes
/// it fit is fewer or shorter parts: three corner-to-corner scratches on a
/// 5000 x 5000 scan are 75 megapixels and fill, four are 100 and are
/// refused, and each of the four on its own is 25 and fills.
pub const MAX_INPAINT_PLAN_PIXELS: u64 = 80_000_000;

/// Which entry point a call came in through. The caps are one set of numbers
/// with one home; the sentences that report them are not, because the two
/// gestures have nothing in common — a menu command over a selection, with a
/// ring field in its sheet, and a brush stroke that has neither. A spot-heal
/// stroke told to "select less, or use a narrower ring" is being sent to a
/// command it did not run and a control it does not have; `doc_heal`'s window
/// limit already words the healing brush's bound for the healing brush's
/// gesture, and this is how the inpainting caps do the same.
///
/// It decides one thing about the pixels as well, and only one:
/// [`Caller::soft_write`].
#[derive(Clone, Copy, PartialEq, Eq)]
pub(crate) enum Caller {
    /// Content-Aware Fill: the region is a selection, the ring is a field in
    /// a sheet, and the work is asked for from a menu.
    Fill,
    /// The Spot Healing Brush: the region is a stroke's footprint, and the
    /// tool exposes neither a selection nor a ring.
    SpotHeal,
}

impl Caller {
    /// Whether the caller's coverage BYTES weight the write-back, or the hard
    /// cut at the α = 128 contour does. True for Content-Aware Fill alone:
    /// there the pixels outside Ω are the original image, so a feathered
    /// selection edge genuinely blends. Spot healing's coverage is a brush
    /// dab, and `doc_heal`'s hard-cut rule applies to it exactly as it does
    /// to the healing brush — Hardness shrinks the footprint, it does not
    /// fade the heal.
    fn soft_write(self) -> bool {
        self == Caller::Fill
    }

    /// The coverage byte at or above which a pixel is part of the HOLE — the
    /// set PatchMatch re-estimates and the membrane solve then corrects.
    ///
    /// It is the same distinction as [`Caller::soft_write`] and it has to
    /// be, or the write-back steps where the coverage ramps. Content-Aware
    /// Fill takes every pixel the selection touches at all (1), because its
    /// coverage is a SELECTION whose feathered edge is a request for a fade:
    /// filling only `≥ 128` and weighting by the byte put the whole ramp
    /// below the contour at weight 0 and the first pixel above it at 0.502,
    /// so a soft-edged selection stepped by half the fill's own effect
    /// across one pixel — measured at 9 code values on a 128 px plasma.
    /// Inpainting the ramp too costs the ramp's own pixels (they count
    /// against [`MAX_INPAINT_HOLE_PIXELS`], which is honest — they are being
    /// re-estimated) and makes the write weight continuous from 0.
    ///
    /// Spot healing's coverage is a brush DAB, and `doc_heal`'s hard cut at
    /// the α = 128 contour applies to it exactly as it does to the healing
    /// brush: hardness shrinks the footprint, it does not fade the heal.
    fn hole_threshold(self) -> u8 {
        match self {
            Caller::Fill => 1,
            Caller::SpotHeal => COVERED_THRESHOLD,
        }
    }
}

/// How well a refusal knows the number it is quoting. The cheap ladder in
/// `inpaint_plan` refuses a scattered selection from bounding boxes alone —
/// deliberately, since measuring it exactly is the cost that pass exists to
/// avoid — so the sentence says "more than" rather than inventing precision
/// it does not have.
pub(crate) enum Measured {
    /// Counted, pixel by pixel, on a distance transform.
    Exactly(u64),
    /// A rigorous floor from the components' bounding boxes.
    AtLeast(u64),
}

impl Measured {
    /// The phrase that goes where a refusal names the size of the call.
    fn phrase(&self) -> String {
        match self {
            Measured::Exactly(total) => format!("covers {total} pixels"),
            Measured::AtLeast(total) => format!("covers more than {total} pixels"),
        }
    }
}

/// The knobs both entry points share.
struct Fill {
    strength: f32,
    ring: u32,
    seed: u64,
    sample_all: bool,
    preview: bool,
    caller: Caller,
}

impl RzDocument {
    /// Spot healing: PatchMatch-inpaints the footprint `overlay`'s ALPHA
    /// marks from a ring of valid pixels around it, then Poisson-blends the
    /// result into layer `idx` exactly as [`RzDocument::heal_layer`] does.
    ///
    /// `overlay` is the canvas-frame premultiplied RGBA8 buffer
    /// `rz_doc_painting_layer` takes (`w`/`h` must equal the canvas size) but
    /// only its alpha is read — there is no sampled source, so its RGB
    /// carries no meaning. The alpha is COVERAGE and nothing else: the
    /// write-back is `doc_heal`'s hard cut at the α = 128 contour, so a soft
    /// tip heals a smaller footprint rather than a fainter one, exactly as
    /// the healing brush does. `strength` is clamped to [0, 1] and scales the
    /// write-back; `ring` is the sampling ring in px (0 = automatic) subject
    /// to the module doc's three rules; `seed` makes the result reproducible;
    /// `sample_all` inpaints from the flattened composite; `preview` runs the
    /// whole pipeline on a reduced copy.
    ///
    /// `Err` (a message for the user) on a cap or a starved sampling region.
    /// `Ok(None)` for an out-of-range `idx`, `w`/`h` not the canvas size, a
    /// short overlay, a non-finite `strength`, an empty footprint, a layer
    /// extent that misses the canvas, or no pixel actually changing.
    // The parameter list deliberately mirrors `rz_doc_spot_heal_layer`'s C
    // signature one-for-one; bundling them into a struct would only move the
    // count somewhere else.
    #[allow(clippy::too_many_arguments)]
    pub fn spot_heal_layer(
        &self,
        idx: usize,
        overlay: &[u8],
        w: u32,
        h: u32,
        strength: f32,
        ring: u32,
        seed: u64,
        sample_all: bool,
        preview: bool,
    ) -> Result<Option<Self>, String> {
        let Some(n) = canvas_len(self, w, h) else {
            return Ok(None);
        };
        if overlay.len() < n * 4 {
            return Ok(None);
        }
        let coverage: Vec<u8> = (0..n).map(|i| overlay[i * 4 + 3]).collect();
        inpaint(
            self,
            idx,
            &coverage,
            Fill {
                strength,
                ring,
                seed,
                sample_all,
                preview,
                caller: Caller::SpotHeal,
            },
        )
    }

    /// Content-Aware Fill: PatchMatch-inpaints the region a canvas-sized u8
    /// coverage mask marks (the selection convention — 0 outside, 255 inside,
    /// intermediate = anti-aliased edge), sampled from a ring around it, then
    /// Poisson-blends the fill to the surrounding illumination.
    ///
    /// The mask's own bytes weight the write-back, so a partially covered
    /// region blends and nothing outside the mask moves. A feathered edge's
    /// ramp lies OUTSIDE the filled region and is left alone — it needs no
    /// blending, because the membrane solve already lands exactly on the
    /// destination at the region's contour.
    ///
    /// `ring`, `seed`, `sample_all` and `preview` are
    /// [`RzDocument::spot_heal_layer`]'s. Same refusals, plus `Ok(None)` for
    /// an empty mask.
    // The parameter list deliberately mirrors `rz_doc_content_aware_fill`'s C
    // signature one-for-one; bundling them into a struct would only move the
    // count somewhere else.
    #[allow(clippy::too_many_arguments)]
    pub fn content_aware_fill(
        &self,
        idx: usize,
        mask: &[u8],
        w: u32,
        h: u32,
        ring: u32,
        seed: u64,
        sample_all: bool,
        preview: bool,
    ) -> Result<Option<Self>, String> {
        let Some(n) = canvas_len(self, w, h) else {
            return Ok(None);
        };
        if mask.len() < n {
            return Ok(None);
        }
        inpaint(
            self,
            idx,
            &mask[..n],
            Fill {
                strength: 1.0,
                ring,
                seed,
                sample_all,
                preview,
                caller: Caller::Fill,
            },
        )
    }
}

/// The canvas pixel count, or `None` when `w`/`h` are not the canvas size or
/// the canvas is empty.
fn canvas_len(doc: &RzDocument, w: u32, h: u32) -> Option<usize> {
    if w != doc.width || h != doc.height {
        return None;
    }
    (w as usize)
        .checked_mul(h as usize)
        .filter(|n| *n > 0 && n.checked_mul(4).is_some())
}

/// What one component's fill needs to read, gathered once for the whole call.
struct Job<'a> {
    /// The caller's coverage bytes, canvas-sized.
    coverage: &'a [u8],
    /// `coverage >= 128` anywhere — every component's hole, so no component
    /// can sample from another's unknown pixels.
    hole_all: &'a [bool],
    /// The image the inpaint samples: the composite, or the layer's own
    /// pixels placed in canvas space.
    source: &'a RgbaImage,
    fill: &'a Fill,
    /// The preview's reduction factor, chosen ONCE for the whole call and
    /// from the WINDOWS `inpaint_plan` measured — 1 when this is not a
    /// preview. Neither "once for the call" nor "from the windows" is
    /// incidental; the module doc's preview section holds the measurement
    /// behind each, and `inpaint_preview::preview_factor` the rule.
    factor: usize,
}

/// The driver: validate, choose the source image, check the caps that bound
/// the whole CALL, then split the coverage into components and fill each into
/// one shared copy of the layer's pixels.
fn inpaint(
    doc: &RzDocument,
    idx: usize,
    coverage: &[u8],
    fill: Fill,
) -> Result<Option<RzDocument>, String> {
    let Some(layer) = doc.layers.get(idx) else {
        return Ok(None);
    };
    if !fill.strength.is_finite() {
        return Ok(None);
    }
    // The canvas-frame coverage must be able to reach a layer pixel at all —
    // the same intersection `RzDocument::painting_layer` (`doc.rs`, the
    // master copy) makes before touching anything.
    let (lw, lh) = layer.pixels.dimensions();
    let (off_x, off_y) = (i64::from(layer.offset.0), i64::from(layer.offset.1));
    let reach_x = (-off_x).max(0) < (i64::from(doc.width) - off_x).min(i64::from(lw));
    let reach_y = (-off_y).max(0) < (i64::from(doc.height) - off_y).min(i64::from(lh));
    if !reach_x || !reach_y {
        return Ok(None);
    }
    // What counts as hole is the caller's, and only the caller's: a brush dab
    // is cut hard at the α = 128 contour, a selection is taken wherever it
    // touches at all so its feathered ramp is filled and faded rather than
    // stepped. See `Caller::hole_threshold`.
    let threshold = fill.caller.hole_threshold();
    let hole_all: Vec<bool> = coverage.iter().map(|c| *c >= threshold).collect();
    let covered = hole_all.iter().filter(|c| **c).count() as u64;
    if covered == 0 {
        return Ok(None);
    }
    // The hole cap bounds the CALL, and it is checked here — before the
    // components — for exactly that reason. It counts PatchMatch's targets,
    // and a selection of ten blobs costs the sum of their targets; testing
    // one component against it would leave the op's worst case unbounded in
    // the component count while every user-facing sentence describing the cap
    // ("at most 1,000,000 selected pixels") promises the opposite.
    if covered > MAX_INPAINT_HOLE_PIXELS {
        return Err(hole_cap_message(fill.caller, covered));
    }
    let source = if fill.sample_all {
        doc.flattened()
    } else {
        let Some(image) = doc.layer_canvas_image(idx) else {
            return Ok(None);
        };
        image
    };
    // A SAMPLE-ABLE pixel is one that carries colour, and alpha's only job
    // here is to answer that — the RGB beside it is straight, so a pixel at
    // alpha 204 is as good a source as one at 255. Testing `== 255` made this
    // whole op unusable on any composite that is nowhere fully opaque: a
    // single layer at 80 % opacity flattens to alpha 204 everywhere, every
    // pixel was disqualified, and the call was refused with a sentence
    // claiming the surroundings were transparent when nothing in the picture
    // was. The threshold is the crate's one 50 % rule, the same contour the
    // hole itself is cut at.
    if !source.pixels().any(|p| p.0[3] >= COVERED_THRESHOLD) {
        return Err(if fill.sample_all {
            // Distinct from NOTHING_TO_SAMPLE, which is about the region's
            // own neighbourhood: this one is about the whole sampled image.
            "there is nothing to sample from: every pixel in the picture is transparent."
                .to_string()
        } else {
            "the layer has no pixels solid enough to sample from — they are transparent, or \
             nearly so; turn on Sample All Layers or fill on the layer that holds the \
             photograph."
                .to_string()
        });
    }
    let (cw, ch) = (doc.width as usize, doc.height as usize);
    // Every component's window and ring, and the work cap, measured BEFORE a
    // single pixel is filled: a refusal must not cost what a fill costs. See
    // `inpaint_plan`'s module doc for the two defects that pass exists for.
    let components = components(&hole_all, cw, ch);
    let plans = plan(&components, (cw, ch), fill.ring, fill.caller)?;
    // A preview is bounded by WORK, and on a scattered selection the
    // reduction alone does not bound it — a small part cannot be reduced and
    // still costs milliseconds, so it is the part COUNT that has to be
    // capped too. See [`PREVIEW_MAX_PARTS`] and the preview section of the
    // module doc. The walk takes the BIGGEST parts first, so what the budget
    // buys is what the eye is looking at; the order is otherwise immaterial,
    // since a component writes only its own pixels and no component's solve
    // reads another's.
    let mut order: Vec<usize> = (0..components.len()).collect();
    if fill.preview {
        order.sort_by_key(|k| std::cmp::Reverse(components[*k].pixels.len()));
        order.truncate(PREVIEW_MAX_PARTS);
    }
    let job = Job {
        coverage,
        hole_all: &hole_all,
        source: &source,
        // The preview's reduction is the CALL's, not one component's — and it
        // is chosen from the WINDOWS the plan just measured, which is what
        // costs, rather than from the covered count, which is not. See
        // [`preview_factor`].
        factor: if fill.preview {
            let windows = order
                .iter()
                .fold(0u64, |sum, k| sum.saturating_add(plans[*k].window_pixels()));
            preview_factor(covered, windows)
        } else {
            1
        },
        fill: &fill,
    };
    // ONE clone of the layer for the whole call, threaded through every
    // component — `doc_heal::heal_layer`'s rule, and the reason it has one.
    // Chaining a fresh document per component instead cost a full layer copy
    // each time, which on a 100-megapixel canvas is 400 MB per speck of a
    // dust-removal selection.
    let mut pixels = (*layer.pixels).clone();
    let mut changed = false;
    for k in order {
        changed |= fill_component(
            (doc.width, doc.height),
            &mut pixels,
            layer.offset,
            &components[k],
            &plans[k],
            &job,
        )?;
    }
    if !changed {
        // Identity result: refuse rather than mint an unchanged copy.
        return Ok(None);
    }
    Ok(doc.with_layer_pixels(idx, pixels))
}

/// Fills one component into `pixels`: the window planes, the inpaint and the
/// healing write-back. `sized` is the window and ring `inpaint_plan` already
/// measured and fitted for this component. Returns whether any byte moved.
fn fill_component(
    canvas: (u32, u32),
    pixels: &mut RgbaImage,
    offset: (i32, i32),
    component: &Component,
    sized: &ComponentPlan,
    job: &Job,
) -> Result<bool, String> {
    let cw = canvas.0 as usize;
    let (x0, y0, ww, wh) = sized.window;
    let ring = sized.ring;

    // --- the window's planes, at full resolution -------------------------
    let n = ww * wh;
    let mut rgb = vec![0u8; n * 3];
    let mut solid = vec![false; n];
    let mut hole_any = vec![false; n];
    for wy in 0..wh {
        for wx in 0..ww {
            let i = wy * ww + wx;
            let p = (y0 + wy) * cw + x0 + wx;
            let px = job.source.get_pixel((x0 + wx) as u32, (y0 + wy) as u32).0;
            rgb[i * 3..i * 3 + 3].copy_from_slice(&px[..3]);
            // Solid enough to carry colour, not necessarily fully opaque:
            // see the guard in `inpaint` for what testing `== 255` cost.
            solid[i] = px[3] >= COVERED_THRESHOLD;
            hole_any[i] = job.hole_all[p];
        }
    }
    let mut hole = vec![false; n];
    let mut write = vec![0u8; n];
    for &p in &component.pixels {
        let (cx, cy) = (p as usize % cw, p as usize / cw);
        let i = (cy - y0) * ww + cx - x0;
        hole[i] = true;
        // Only this component's own coverage: a neighbouring blob inside the
        // same window is another component's business. Whether that coverage
        // WEIGHTS the write-back or is merely the hard cut at α = 128 is
        // `Caller::soft_write`'s question — see its own comment.
        write[i] = if job.fill.caller.soft_write() {
            job.coverage[p as usize]
        } else {
            255
        };
    }

    let data: Vec<bool> = (0..n).map(|i| solid[i] && !hole_any[i]).collect();
    let plane = Plane {
        w: ww,
        h: wh,
        rgb,
        hole,
        data,
    };
    // The call's reduction, and the reduced plane it produces — or factor 1
    // and no plane, when this component cannot be previewed that coarsely.
    let (factor, small) = if job.factor > 1 {
        preview_plane(&plane, job.factor)
    } else {
        (1, None)
    };
    let Some(small) = small else {
        // ONE distance transform over the window, which the finest pyramid
        // level takes as its own. `inpaint_plan` measured this component's
        // dilated area on its own copy and dropped it; the transform is the
        // cheapest stage in the pipeline and holding one f32 plane per
        // component would not be. It is computed HERE rather than above
        // because a reduced preview never uses it — it runs the pyramid on
        // the small plane, whose own contour is measured at that scale — and
        // a full-resolution exact Euclidean transform is one of the biggest
        // fixed costs a preview of a canvas-spanning scratch was paying.
        let sdf = hole_distance(&plane.hole, ww, wh);
        let (source, region) =
            inpaint_plane(plane, ring, job.fill.seed, Some(sdf), job.fill.caller)?;
        for (weight, covered) in write.iter_mut().zip(&region) {
            if *covered < COVERED_THRESHOLD {
                *weight = 0;
            }
        }
        return heal_window_into_pixels(
            canvas,
            pixels,
            offset,
            (x0 as i64, y0 as i64, ww, wh),
            &source,
            &region,
            &write,
            job.fill.strength,
        );
    };

    // --- preview: the same pipeline on the reduced copy -------------------
    let (rw, rh) = (small.w, small.h);
    let destination = dest_window(canvas, pixels, offset, (x0 as i64, y0 as i64, ww, wh));
    let reduced_dest = reduce_rgba(&destination, ww, wh, factor);
    let (source, region) = inpaint_plane(
        small,
        (ring / factor as f32).max(RING_MIN),
        job.fill.seed,
        None,
        job.fill.caller,
    )?;
    // The reduced heal IS the shipped op, run on a one-layer document of the
    // reduced window: same solver, same write-back, same refusals. Its write
    // weight is 255 inside the region because the caller's own coverage is
    // applied once, at full resolution, in the paste below.
    let full = vec![255u8; rw * rh];
    let temp = RzDocument::from_pixels(reduced_dest);
    let healed = heal_window_into_layer(&temp, 0, (0, 0, rw, rh), &source, &region, &full, 1.0)?;
    let healed = healed.as_ref().unwrap_or(&temp);
    let healed_pixels = &healed.layers[0].pixels;
    let mut small_rgb = vec![0u8; rw * rh * 3];
    for (i, px) in healed_pixels.pixels().enumerate() {
        small_rgb[i * 3..i * 3 + 3].copy_from_slice(&px.0[..3]);
    }
    let upsampled = upsample_rgb(&small_rgb, rw, rh, factor, ww, wh);
    Ok(paste_window_into_pixels(
        canvas,
        pixels,
        offset,
        (x0 as i64, y0 as i64, ww, wh),
        &upsampled,
        &write,
        job.fill.strength,
    ))
}

/// The plane a component is previewed on, and the factor it was reduced by:
/// the CALL's factor, halved while the reduction leaves this component
/// nothing to sample from. `None` means preview it at full resolution.
///
/// Two things go wrong at a coarse factor and they have the same answer. A
/// window shorter than [`MIN_PREVIEW_SIDE`] has no room to move a source
/// patch; and a component packed close to its neighbours — twenty-five blobs
/// with forty-pixel gaps, the shape a magic-wand selection makes — keeps its
/// hole under the OR reduction while the thin band of real pixels between the
/// holes falls under a patch wide, so the reduced window has no admissible
/// origin at all and the preview would refuse a fill that succeeds. Both are
/// caught by the same test — count the admissible origins on the reduced
/// plane, which is one integral image and cheap next to what it decides —
/// and the retry costs at most a third again of the factor it settles on,
/// since each rejected factor's planes are a quarter of the next one's.
fn preview_plane(plane: &Plane, factor: usize) -> (usize, Option<Plane>) {
    let mut factor = factor;
    while factor > 1 {
        let (rw, rh) = (plane.w.div_ceil(factor), plane.h.div_ceil(factor));
        if rw >= MIN_PREVIEW_SIDE && rh >= MIN_PREVIEW_SIDE {
            let small = Plane {
                w: rw,
                h: rh,
                rgb: reduce_rgb(&plane.rgb, plane.w, plane.h, factor),
                // OR for the hole (a thin scratch must never be LOST) and AND
                // for the data (no reduced source patch may hold an invented
                // colour) — `inpaint_preview` states why they differ.
                hole: reduce_any(&plane.hole, plane.w, plane.h, factor),
                data: reduce_all(&plane.data, plane.w, plane.h, factor),
            };
            let valid: Vec<bool> = small
                .data
                .iter()
                .zip(&small.hole)
                .map(|(d, h)| *d && !*h)
                .collect();
            // Ignoring the ring, which `inpaint_em::build_sources` widens up
            // to the whole window when the origins are starved: what cannot
            // be recovered is a window with no complete valid patch in it.
            if !sources(&valid, rw, rh).is_empty() {
                return (factor, Some(small));
            }
        }
        factor /= 2;
    }
    (1, None)
}

// ---- the cap refusals, one sentence per cap per caller --------------------
//
// The limits, the numbers and the arithmetic have one home each (above, and
// `doc_heal::MAX_SOLVE_WINDOW_PIXELS`); what branches here is only the
// sentence, because the two callers are asked for in different gestures and a
// refusal has to name something the person holding that gesture can change.
// See [`Caller`].

/// [`MAX_INPAINT_HOLE_PIXELS`] busted by the call's covered count.
fn hole_cap_message(caller: Caller, covered: u64) -> String {
    match caller {
        Caller::Fill => format!(
            "the region to fill is {covered} pixels; content-aware fill works on at most {} \
             pixels in one call (about 1000 x 1000), counting every separate part of the \
             selection together. Select less, or fill it in pieces.",
            MAX_INPAINT_HOLE_PIXELS
        ),
        Caller::SpotHeal => format!(
            "the stroke covers {covered} pixels; spot healing works on at most {} pixels in one \
             call (about 1000 x 1000), counting every part of the stroke together. Heal it in \
             shorter strokes, or with a smaller brush.",
            MAX_INPAINT_HOLE_PIXELS
        ),
    }
}

/// [`MAX_INPAINT_TARGET_PIXELS`] busted by the call's dilated total, with
/// every ring already narrowed to `floor` — the narrowest the rules will use.
/// The advice is the one that works: the ring has been narrowed as far as it
/// goes, so what is left to change is the region.
pub(crate) fn target_cap_message(caller: Caller, total: Measured, floor: f32) -> String {
    let amount = total.phrase();
    match caller {
        Caller::Fill => format!(
            "the region plus the sampling ring around it {amount}, with the ring \
             already narrowed as far as it goes ({floor:.0} px); content-aware fill works on at \
             most {} in one call, counting every separate part of the selection together. Select \
             less, or fill it in pieces.",
            MAX_INPAINT_TARGET_PIXELS
        ),
        Caller::SpotHeal => format!(
            "the stroke plus the band of pixels it heals from {amount}, with that \
             band already as narrow as it goes ({floor:.0} px); spot healing works on at most {} \
             in one call, counting every part of the stroke together. Heal it in shorter \
             strokes, or with a smaller brush.",
            MAX_INPAINT_TARGET_PIXELS
        ),
    }
}

/// The refusal when the neighbourhood holds no pixel to copy from AT ALL —
/// every pixel around the region is transparent, part of the region, or off
/// the canvas.
///
/// Kept distinct from [`narrow_band_message`], which is the far more common
/// case and used to be reported with this sentence: a selection with three
/// solid, opaque, on-canvas pixels of picture around it was told its
/// surroundings were transparent when they plainly were not, and given
/// nothing to act on. The two are told apart by the `valid` plane
/// `inpaint_em::build_sources` already returns: this one is for an empty one.
pub(crate) fn nothing_to_sample_message(caller: Caller) -> String {
    match caller {
        Caller::Fill => "there is nothing to sample from: every pixel around the selection is \
                         transparent, part of the selection, or outside the canvas."
            .to_string(),
        Caller::SpotHeal => "there is nothing to sample from: every pixel around the stroke is \
                             transparent, part of it, or outside the canvas."
            .to_string(),
    }
}

/// The refusal when there ARE pixels to copy from but the band they form is
/// narrower than one source patch, so not one complete patch fits in it.
///
/// `patchmatch::sources` admits an origin only when its whole `PATCH x PATCH`
/// window is valid, so a band under seven pixels yields an empty origin set
/// however opaque and on-canvas it is. Measured on a 200 x 200 fully opaque
/// document with a centred rectangular selection: bands of 3, 5 and 6 px
/// refuse here and a 7 px band fills. It is reachable whenever a selection
/// comes within six pixels of the picture's edge on every side — "remove the
/// subject" where the subject nearly fills the frame, or Select All followed
/// by a small Contract — so the sentence names the width and says what to do.
pub(crate) fn narrow_band_message(caller: Caller) -> String {
    match caller {
        Caller::Fill => format!(
            "the band of picture around the selection is narrower than one source patch \
             ({PATCH} px), so there is no complete patch to copy from — leave at least {PATCH} \
             px of unselected picture around the region, or select less."
        ),
        Caller::SpotHeal => format!(
            "the band of picture around the stroke is narrower than one source patch \
             ({PATCH} px), so there is no complete patch to copy from — use a smaller brush, \
             or heal a spot with more picture around it."
        ),
    }
}

/// [`MAX_INPAINT_PLAN_PIXELS`] busted by the total of the call's working
/// windows, with every ring already at [`RING_MIN`]. Distinct from the work
/// cap because the thing to change is distinct: the windows are bounding
/// BOXES, so what makes them smaller is fewer or shorter parts, and thinning
/// the selection or narrowing the ring does nothing at all.
pub(crate) fn plan_cap_message(caller: Caller, total: u64) -> String {
    let megapixels = |v: u64| v as f64 / 1e6;
    match caller {
        Caller::Fill => format!(
            "the separate parts of the selection span {:.0} megapixels of working area between \
             them, with the sampling ring already as narrow as it goes; content-aware fill \
             works over at most {:.0} megapixels in one call. Each part needs buffers over \
             its whole bounding box, so fill fewer parts at a time, or shorter ones — \
             thinning the selection will not help.",
            megapixels(total),
            megapixels(MAX_INPAINT_PLAN_PIXELS)
        ),
        Caller::SpotHeal => format!(
            "the separate parts of the stroke span {:.0} megapixels of working area between \
             them, with the band they heal from already as narrow as it goes; spot healing \
             works over at most {:.0} megapixels in one call. Heal it in shorter strokes.",
            megapixels(total),
            megapixels(MAX_INPAINT_PLAN_PIXELS)
        ),
    }
}

/// `doc_heal::MAX_SOLVE_WINDOW_PIXELS` busted by one component's window. The
/// number and the memory it stands for are `doc_heal`'s; only the gesture
/// being refused is this file's business.
pub(crate) fn window_cap_message(caller: Caller, ww: usize, wh: usize, pixels: u64) -> String {
    let megapixels = |v: u64| v as f64 / 1e6;
    match caller {
        Caller::Fill => format!(
            "the region plus its sampling ring spans a {ww} x {wh} box ({:.1} megapixels); \
             filling needs working buffers over that box and is limited to {:.0} megapixels — \
             fill it in pieces, or select a smaller region.",
            megapixels(pixels),
            megapixels(MAX_SOLVE_WINDOW_PIXELS)
        ),
        Caller::SpotHeal => format!(
            "the stroke plus the band it heals from spans a {ww} x {wh} box ({:.1} megapixels); \
             healing needs working buffers over that box and is limited to {:.0} megapixels — \
             heal it in shorter strokes.",
            megapixels(pixels),
            megapixels(MAX_SOLVE_WINDOW_PIXELS)
        ),
    }
}
