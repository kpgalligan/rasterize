//! What a content-aware call COSTS, and what it refuses: the guards on
//! `inpaint_plan`'s two ladders, the caps they measure against, and the
//! preview's own bound.
//!
//! Separate from `content_aware_tests` — which is about the pixels — because
//! these are timing and refusal assertions with their own fixtures, and
//! neither file should carry the other's. Shared fixtures live in
//! `tests/common`.
//!
//! # How a timing assertion is written here, and why
//!
//! A bare ratio between two wall-clock samples is not a test, it is a
//! coin toss with a bias: `make test` runs the test binaries in parallel, a
//! transient stall inflates the shorter measurement far more than the longer
//! one it is divided into, and `a_scattered_preview_is_bounded_by_the_part_count`
//! duly failed the project's own gate at 2.79x against a 3.0x assertion while
//! measuring 4.2-4.9x on an idle machine. A red suite for a change that did
//! not touch the code costs more than the assertion buys.
//!
//! So every timing test here is written in three layers, and the first one
//! is the point:
//!
//! 1. **The deterministic property.** The parts a preview actually repaired,
//!    the sentence a refusal carries, the pixels a fill changed. This is what
//!    the test is really about and it cannot go flaky.
//! 2. **A generous ABSOLUTE ceiling**, sized from the documented budget
//!    rather than from the measurement — `a_300_square_hole_in_a_2000_by_1500_photograph`'s
//!    own precedent, whose comment says why (0.53 s measured against a 15 s
//!    bound).
//! 3. **A ratio with at least twice the headroom of the measured value**, and
//!    still strictly inside the number the regression it guards produced. The
//!    measured value is printed either way, so the module docs' figures can
//!    be checked by eye.

use std::time::Instant;

use image::{Rgba, RgbaImage};
use rasterize_core::doc::RzDocument;
use rasterize_core::doc_inpaint::{
    MAX_INPAINT_HOLE_PIXELS, MAX_INPAINT_PLAN_PIXELS, MAX_INPAINT_TARGET_PIXELS,
};

mod common;
use common::*;

// ------------------------------------------------------- a cheap refusal --

/// A dust selection is refused from the components' BOUNDING BOXES, before a
/// single working window is built.
///
/// The planner used to allocate a window and run a full exact distance
/// transform for every component before comparing anything against a cap, so
/// the promise its own module doc makes — "a refusal must be cheap" — held
/// only for a selection made of a few big parts. Measured against this same
/// entry point before the fix, on a 1200 x 1200 canvas: 20 000 one-pixel
/// specks refused in 0.60 s, 90 000 in 2.4 s, 250 000 in 4.9 s and 999 698 —
/// still under `MAX_INPAINT_HOLE_PIXELS` — in 28.7 s, all of it on the
/// caller's thread, which in the app is the main one. It is now 6 ms, because
/// the first ladder is arithmetic over the boxes: a component dilates to at
/// least a quarter-disc of the ring, so the part COUNT alone settles a dust
/// selection.
#[test]
fn a_dust_selection_is_refused_before_a_window_is_built() {
    let side = 1200u32;
    let doc = doc_of(side, side, plasma);
    // Every (even, even) pixel of a 600 x 600 corner: 90 000 separate
    // 4-connected components of one pixel each — the shape a grain, dust or
    // halftone selection makes, and a tenth of the hole cap.
    let dust = mask_of(side, side, |x, y| {
        x.is_multiple_of(2) && y.is_multiple_of(2) && x < 600 && y < 600
    });
    let covered = dust.iter().filter(|v| **v >= 128).count() as u64;
    assert_eq!(covered, 90_000, "the fixture must be 90 000 specks");
    assert!(
        covered * 10 <= MAX_INPAINT_HOLE_PIXELS,
        "and far under the hole cap, so only the work caps may refuse it"
    );

    let started = Instant::now();
    let (out, message) = fill(&doc, 0, &dust, (side, side), (0, 3), (false, false));
    let refused = started.elapsed();
    assert!(out.is_none(), "90 000 separate parts cannot fit the caps");
    let message = message.expect("a cap must speak");
    assert!(
        message.contains(&MAX_INPAINT_TARGET_PIXELS.to_string())
            || message.contains("working area"),
        "the refusal must name a work cap: {message}"
    );

    // The scale to measure it against: a plain compact fill of the same
    // picture, which is the cheapest thing this op does at all.
    let compact = mask_of(side, side, |x, y| {
        (450..750).contains(&x) && (450..750).contains(&y)
    });
    let broken = punch(&doc, &compact, [255, 255, 255]);
    let started = Instant::now();
    let (out, message) = fill(&broken, 0, &compact, (side, side), (0, 3), (false, false));
    let filled = started.elapsed();
    assert!(message.is_none(), "unexpected message: {message:?}");
    assert!(out.is_some(), "the compact fill must land");

    println!("dust: refused in {refused:?}, a 300 x 300 fill takes {filled:?}");
    assert!(
        refused.as_secs_f64() * 10.0 < filled.as_secs_f64(),
        "a refusal must cost a fraction of the smallest fill, not a multiple of it: \
         refused {refused:?}, filled {filled:?}"
    );
}

/// A call whose working WINDOWS bust their budget is refused in the words of
/// working area, and refused cheaply.
///
/// `MAX_INPAINT_TARGET_PIXELS` bounds the region DILATED by its ring, and a
/// long thin component dilates to a small fraction of its bounding box — so
/// on its own it left the sum of the windows (the planes, the transform and
/// the integral image every component builds) unbounded. Measured: thirty
/// three-pixel scratches across a 3000 x 3000 photograph are 3.2 M dilated,
/// comfortably inside the work cap, and took 16.3 s.
#[test]
fn a_call_whose_windows_bust_their_budget_says_so() {
    let side = 2000u32;
    let doc = RzDocument::from_pixels(RgbaImage::from_pixel(side, side, Rgba([70, 80, 90, 255])));
    // Two-pixel-thick diagonals 14 px apart — thick because a one-pixel
    // diagonal is not 4-connected and would be one component per pixel.
    // Each spans the canvas, so each window is nearly the whole picture.
    let mut mask = vec![0u8; (side as usize) * (side as usize)];
    let mut parts = 0;
    for k in 0..143u32 {
        let offset = k * 14;
        if offset >= side {
            break;
        }
        parts += 1;
        for x in 0..side - offset {
            let y = x + offset;
            mask[(y * side + x) as usize] = 255;
            if y + 1 < side {
                mask[((y + 1) * side + x) as usize] = 255;
            }
        }
    }
    let covered = mask.iter().filter(|v| **v >= 128).count() as u64;
    assert!(
        parts > 100 && covered < MAX_INPAINT_HOLE_PIXELS,
        "the fixture must be many long thin parts under the hole cap: {parts} parts, {covered} px"
    );

    let started = Instant::now();
    let (out, message) = fill(&doc, 0, &mask, (side, side), (0, 1), (false, false));
    let refused = started.elapsed();
    assert!(out.is_none(), "the windows must not fit their budget");
    let message = message.expect("the budget must speak");
    println!("{parts} spanning scratches ({covered} px): refused in {refused:?} — {message}");
    assert!(
        message.contains("working area")
            && message.contains(&format!("{}", MAX_INPAINT_PLAN_PIXELS / 1_000_000)),
        "the refusal must be worded as working area and name the limit: {message}"
    );
    // And it is the CHEAP ladder that refused it: one small region of the
    // same picture, whose windows do fit, costs the whole pipeline — and far
    // more than this refusal did.
    let one = mask_of(side, side, |x, y| {
        (900..1100).contains(&x) && (900..1100).contains(&y)
    });
    let started = Instant::now();
    let _ = fill(&doc, 0, &one, (side, side), (0, 1), (false, false));
    let filled = started.elapsed();
    println!("one 200 px region of the same picture fills in {filled:?}");
    // Measured 13 ms against 100 ms; the ratio the fix was written against was
    // about 1 (essentially the whole cost of a fill, paid to be told no), so
    // two is a bound a loaded machine cannot cross and a regression cannot
    // hide behind.
    assert!(
        refused.as_secs_f64() < 2.0,
        "a refusal must be cheap in absolute terms: {refused:?}"
    );
    assert!(
        refused.as_secs_f64() * 2.0 < filled.as_secs_f64(),
        "the refusal must not cost like a fill: refused {refused:?}, filled {filled:?}"
    );
}

// ----------------------------------------------- the ring is not a knob --

/// The ring is a QUALITY control on a scattered selection too, which is what
/// the schema and the module doc both promise and what was false for the one
/// shape it mattered on.
///
/// Every component's working window used to be sized from the ring the
/// caller ASKED for rather than the one the narrowing settled on, so the
/// planner and the fill both paid `parts x ring²` with nothing bounding it.
/// Measured in the app on a 2000 x 1500 photograph with 1131 disjoint 12-px
/// specks: `ring: 21` returned in 3.0 s and `ring: 512` — the same selection,
/// neither cap firing — in 78.9 s, with the main thread blocked throughout.
#[test]
fn the_ring_does_not_drive_the_cost_of_a_scattered_selection() {
    let (w, h) = (1200u32, 900u32);
    let doc = doc_of(w, h, plasma);
    let speck = |v: u32| v > 20 && (v % 50) < 12;
    let mask = mask_of(w, h, |x, y| speck(x) && speck(y));
    let covered = mask.iter().filter(|v| **v >= 128).count() as u64;
    assert!(
        covered * 4 < MAX_INPAINT_HOLE_PIXELS,
        "the fixture must be far under the hole cap: {covered} px"
    );
    let broken = punch(&doc, &mask, [255, 255, 255]);
    let run = |ring: u32| {
        let started = Instant::now();
        let (out, message) = fill(&broken, 0, &mask, (w, h), (ring, 4), (false, false));
        let elapsed = started.elapsed();
        assert!(
            message.is_none(),
            "unexpected message at ring {ring}: {message:?}"
        );
        assert!(out.is_some(), "the fill must land at ring {ring}");
        elapsed
    };
    let narrow = run(21);
    let wide = run(512);
    println!("scattered selection: ring 21 {narrow:?}, ring 512 {wide:?}");
    // Measured 1.29 s against 1.81 s, a ratio of 1.4; the defect this guards
    // was 26x, so four leaves the assertion three times the headroom of the
    // measurement and still an order below what it has to catch.
    assert!(
        wide.as_secs_f64() < narrow.as_secs_f64() * 4.0,
        "the ring must not multiply the cost of a scattered selection: \
         ring 21 {narrow:?}, ring 512 {wide:?}"
    );
}

// -------------------------------------------------------------- preview --

/// A preview of a scattered selection is bounded by the PART COUNT, not only
/// by the reduction.
///
/// `preview_factor` reduces the call until its covered count is under 40 000,
/// but `preview_plane` silently drops a component back to full resolution
/// when its window will not survive the reduction — which is every small
/// component, since the window is at least `2·RING_MIN` on a side. So a
/// scattered selection previewed at exactly what the fill cost: measured
/// against this entry point before the fix, 900 12-px specks previewed in
/// 2.30 s against a 2.30 s fill, and the sheet's Cancel button blocks the
/// main thread on the render in flight. The preview now fills the biggest
/// 200 parts and leaves the rest showing the original.
#[test]
fn a_scattered_preview_is_bounded_by_the_part_count() {
    let side = 1200u32;
    let doc = doc_of(side, side, plasma);
    // 900 disjoint 12 x 12 specks — a dust selection, and every one of them
    // too small for the call's reduction to touch.
    let blob = |v: u32| v >= 20 && (v - 20) % 39 < 12 && v < 1190;
    let mask = mask_of(side, side, |x, y| blob(x) && blob(y));
    let parts = 900;
    let broken = punch(&doc, &mask, [255, 255, 255]);

    let started = Instant::now();
    let (out, message) = fill(&broken, 0, &mask, (side, side), (0, 5), (false, true));
    let preview_time = started.elapsed();
    assert!(message.is_none(), "unexpected message: {message:?}");
    let bytes = layer_bytes(&out.expect("a preview must produce something"), 0);

    let started = Instant::now();
    let (out, message) = fill(&broken, 0, &mask, (side, side), (0, 5), (false, false));
    let fill_time = started.elapsed();
    assert!(message.is_none(), "unexpected message: {message:?}");
    assert!(out.is_some(), "the full fill must land");

    // How many of the 900 specks the preview actually repaired: a bounded
    // preview of NOTHING would pass a bare ratio, and one that repaired
    // every speck would not be bounded.
    let mut repaired = 0;
    for by in 0..30u32 {
        for bx in 0..30u32 {
            let (x, y) = (20 + bx * 39 + 6, 20 + by * 39 + 6);
            let i = ((y * side + x) * 4) as usize;
            if bytes[i] < 250 || bytes[i + 1] < 250 || bytes[i + 2] < 250 {
                repaired += 1;
            }
        }
    }
    println!(
        "900-speck selection: preview {preview_time:?} ({repaired} parts repaired), \
         fill {fill_time:?}"
    );
    // THE assertion of this test, and the deterministic one: the part cap
    // fired, so the preview filled 200 of the 900 specks and left the rest
    // showing the original.
    assert!(
        (100..parts).contains(&repaired),
        "the preview must show a bounded majority of the parts, not none and not all: \
         {repaired} of {parts}"
    );
    // Then the cost, in the two layers the module doc describes: an absolute
    // ceiling from the budget (measured 0.69 s), and a ratio with twice the
    // headroom of the measurement (4.3x) that is still far inside the 1.0x
    // this was written against — the preview used to cost exactly the fill.
    assert!(
        preview_time.as_secs_f64() < 5.0,
        "a bounded preview must be under the budget in absolute terms: {preview_time:?}"
    );
    assert!(
        preview_time.as_secs_f64() * 2.0 < fill_time.as_secs_f64(),
        "the preview must not cost what the fill costs: preview {preview_time:?}, \
         fill {fill_time:?}"
    );
}

/// A preview of ONE canvas-spanning scratch is bounded too, and by the
/// quantity that actually costs: the working WINDOW.
///
/// The reduction used to be chosen from the selection's covered count, which
/// `doc_inpaint`'s own module doc says does not drive cost. A three-pixel
/// scratch running corner to corner — the shape that doc calls content-aware
/// fill's single most common use — covers 15 000 pixels on a 5000 x 5000
/// scan, far under `PREVIEW_HOLE_PIXELS`, so it previewed at factor 1 and the
/// "preview" ran the identical full-resolution pipeline as the commit:
/// measured 4.27 s against a 4.10 s fill, with the sheet's Cancel blocking
/// the main thread on it and every edited field arming another. Neither of
/// the other two preview tests uses a one-component shape, which is how it
/// survived them.
#[test]
fn a_spanning_scratch_previews_far_faster_than_it_fills() {
    let side = 3000u32;
    let doc = doc_of(side, side, plasma);
    // One 4-connected three-pixel-wide diagonal, corner to corner: a window
    // of the whole picture around a hole of a few thousand pixels.
    let mask = mask_of(side, side, |x, y| y >= x && y < x + 3);
    let covered = mask.iter().filter(|v| **v >= 128).count() as u64;
    assert!(
        covered < 10_000,
        "the fixture must be a small hole in a huge window: {covered} px"
    );
    let broken = punch(&doc, &mask, [255, 255, 255]);

    let started = Instant::now();
    let (out, message) = fill(&broken, 0, &mask, (side, side), (0, 9), (false, true));
    let preview_time = started.elapsed();
    assert!(message.is_none(), "unexpected message: {message:?}");
    let bytes = layer_bytes(&out.expect("a preview must produce something"), 0);

    let started = Instant::now();
    let (out, message) = fill(&broken, 0, &mask, (side, side), (0, 9), (false, false));
    let fill_time = started.elapsed();
    assert!(message.is_none(), "unexpected message: {message:?}");
    assert!(out.is_some(), "the full fill must land");
    println!("spanning scratch: preview {preview_time:?}, fill {fill_time:?}");

    // The preview still has to show the scratch gone — a fast preview of
    // nothing would pass any timing bound.
    let mut damaged = 0;
    for step in (0..side).step_by(17) {
        let i = ((step * side + step + 1) * 4) as usize;
        if bytes[i] > 250 && bytes[i + 1] > 250 && bytes[i + 2] > 250 {
            damaged += 1;
        }
    }
    assert_eq!(damaged, 0, "the preview must show the scratch repaired");
    // Measured 0.53 s against 1.18 s. The ratio is smaller than the scattered
    // selection's on purpose and the module doc says why: for a thin scratch
    // most of what is left is the full-resolution window work the preview
    // cannot avoid — the planes, the reduction itself and the paste back —
    // and only the search, the vote and the solve reduce. What matters is
    // that it is no longer 1.0x, which is what it was.
    assert!(
        preview_time.as_secs_f64() < 5.0,
        "a bounded preview must be under the budget in absolute terms: {preview_time:?}"
    );
    assert!(
        preview_time.as_secs_f64() * 1.5 < fill_time.as_secs_f64(),
        "the preview must not cost what the fill costs: preview {preview_time:?}, \
         fill {fill_time:?}"
    );
}
