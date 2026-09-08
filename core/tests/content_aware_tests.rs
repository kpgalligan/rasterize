//! Content-aware inpainting tests: `rz_doc_content_aware_fill` and
//! `rz_doc_spot_heal_layer` — the PatchMatch fill and the membrane blend it
//! composes with.
//!
//! Every op runs through its FFI entry point on documents built from the safe
//! constructors, on the `doc_retouch.rs` / `heal_tests.rs` model. The primary
//! correctness oracle is independent of this implementation: a hole in an
//! exactly periodic texture has a zero-distance source patch for every target
//! patch, so it must come back byte-exact — the same case, the same
//! parameters and the same seed as the 60-line reference inpainter written in
//! Python before any of this existed. Shared fixtures live in `tests/common`.

use std::ffi::c_char;
use std::ptr;
use std::time::Instant;

use image::{Rgba, RgbaImage};
use rasterize_core::doc::RzDocument;
use rasterize_core::doc_heal::MAX_SOLVE_WINDOW_PIXELS;
use rasterize_core::doc_inpaint::{MAX_INPAINT_HOLE_PIXELS, MAX_INPAINT_TARGET_PIXELS};
use rasterize_core::ffi_doc::rz_doc_free;
use rasterize_core::ffi_heal::{rz_doc_content_aware_fill, rz_doc_spot_heal_layer};

mod common;
use common::*;

// ------------------------------------------------------------- plumbing --

/// Runs spot healing through its FFI entry point on a copy of `doc`.
fn spot(
    doc: &RzDocument,
    overlay: &[u8],
    (w, h): (u32, u32),
    strength: f32,
    (ring, seed): (u32, u64),
) -> (Option<RzDocument>, Option<String>) {
    let handle = Box::into_raw(Box::new(doc.clone()));
    let mut err: *mut c_char = ptr::null_mut();
    let out = unsafe {
        rz_doc_spot_heal_layer(
            handle,
            0,
            overlay.as_ptr(),
            w,
            h,
            strength,
            ring,
            seed,
            false,
            false,
            &mut err,
        )
    };
    unsafe { rz_doc_free(handle) };
    take_doc(out, err)
}

/// [`fill`] with the defaults, asserting success and no message.
fn filled(doc: &RzDocument, mask: &[u8], dims: (u32, u32), seed: u64) -> RzDocument {
    let (out, message) = fill(doc, 0, mask, dims, (0, seed), (false, false));
    assert!(message.is_none(), "unexpected message: {message:?}");
    out.expect("content_aware_fill must succeed")
}

/// The canvas-sized premultiplied overlay a spot-heal stroke hands the core:
/// coverage only, its RGB deliberately meaningless (white, as the canvas and
/// the agent both stamp it).
fn coverage_overlay(w: u32, h: u32, f: impl Fn(u32, u32) -> u8) -> Vec<u8> {
    let mut out = vec![0u8; (w as usize) * (h as usize) * 4];
    for y in 0..h {
        for x in 0..w {
            let a = f(x, y);
            let i = ((y as usize) * (w as usize) + x as usize) * 4;
            out[i] = a;
            out[i + 1] = a;
            out[i + 2] = a;
            out[i + 3] = a;
        }
    }
    out
}

/// The reference texture of the primary oracle: period-4 vertical stripes,
/// 40 and 200, constant down the columns. Every 7x7 patch depends only on
/// `x mod 4`, so a zero-distance source exists for every target.
fn stripes(x: u32, _y: u32) -> [u8; 3] {
    let v = if (x / 2).is_multiple_of(2) { 40 } else { 200 };
    [v, v, v]
}

fn at(buf: &[u8], w: u32, x: u32, y: u32) -> [u8; 4] {
    pixel(buf, w, x, y)
}

// ------------------------------------------------------- the oracle case --

/// The primary oracle, ported from the Python reference: a 32x32 image of
/// period-4 vertical stripes with an 8x8 hole at `x, y in [12, 20)`, seed
/// 12345. The hole is 8 px across, under `2 * PATCH`, so the pyramid rule
/// leaves this a single level — and with a zero-distance source patch
/// available for every target patch the recovery must be BYTE-EXACT, not
/// merely close. The Poisson step cannot spoil it: a source that already
/// equals the destination on the region's contour gives a zero correction.
#[test]
fn periodic_texture_comes_back_byte_exact() {
    let doc = doc_of(32, 32, stripes);
    let hole = |x: u32, y: u32| (12..20).contains(&x) && (12..20).contains(&y);
    let mask = mask_of(32, 32, hole);
    let mut broken = doc.clone();
    // Punch the hole first, so the fill has to invent the stripes rather than
    // find them already in place.
    broken = punch(&broken, &mask, [128, 128, 128]);
    let out = filled(&broken, &mask, (32, 32), 12345);
    let bytes = layer_bytes(&out, 0);
    for y in 0..32u32 {
        for x in 0..32u32 {
            let want = stripes(x, y);
            let got = at(&bytes, 32, x, y);
            assert_eq!(
                [got[0], got[1], got[2]],
                want,
                "pixel ({x}, {y}) in {}",
                if hole(x, y) {
                    "the hole"
                } else {
                    "the surround"
                }
            );
        }
    }
}

/// A hole in a solid field comes back that exact colour: every patch distance
/// is zero and the vote averages identical bytes.
#[test]
fn uniform_field_fills_with_its_own_colour() {
    let doc = doc_of(40, 40, |_, _| [90, 140, 210]);
    let mask = mask_of(40, 40, |x, y| {
        (16..24).contains(&x) && (16..24).contains(&y)
    });
    let broken = punch(&doc, &mask, [10, 10, 10]);
    let out = filled(&broken, &mask, (40, 40), 7);
    let bytes = layer_bytes(&out, 0);
    for y in 0..40u32 {
        for x in 0..40u32 {
            let got = at(&bytes, 40, x, y);
            assert_eq!([got[0], got[1], got[2]], [90, 140, 210], "({x}, {y})");
        }
    }
}

// ------------------------------------------------------------ invariants --

/// The same seed twice gives byte-identical documents — the property that
/// makes a fill reproducible, and the reason `seed` is in the signature at
/// all.
#[test]
fn the_same_seed_gives_the_same_pixels() {
    let doc = doc_of(64, 64, plasma);
    let mask = mask_of(64, 64, |x, y| {
        (24..40).contains(&x) && (24..40).contains(&y)
    });
    let broken = punch(&doc, &mask, [200, 30, 30]);
    let a = layer_bytes(&filled(&broken, &mask, (64, 64), 99), 0);
    let b = layer_bytes(&filled(&broken, &mask, (64, 64), 99), 0);
    assert_eq!(a, b, "the same seed must give byte-identical output");
}

/// Different seeds explore different neighbourhoods, so on a field with more
/// than one plausible answer they must differ (asserting this on a uniform
/// field would be asserting a coincidence, since there they cannot).
#[test]
fn different_seeds_give_different_pixels() {
    let doc = doc_of(64, 64, plasma);
    let mask = mask_of(64, 64, |x, y| {
        (24..40).contains(&x) && (24..40).contains(&y)
    });
    let broken = punch(&doc, &mask, [200, 30, 30]);
    let a = layer_bytes(&filled(&broken, &mask, (64, 64), 1), 0);
    let b = layer_bytes(&filled(&broken, &mask, (64, 64), 2), 0);
    assert_ne!(a, b, "two seeds must not agree pixel for pixel");
}

/// Nothing outside the mask moves, and the layer's alpha never does.
#[test]
fn everything_outside_the_mask_is_untouched() {
    let doc = doc_of(64, 64, plasma);
    let mask = mask_of(64, 64, |x, y| {
        (20..30).contains(&x) && (30..44).contains(&y)
    });
    let broken = punch(&doc, &mask, [0, 0, 0]);
    let before = layer_bytes(&broken, 0);
    let after = layer_bytes(&filled(&broken, &mask, (64, 64), 5), 0);
    for y in 0..64u32 {
        for x in 0..64u32 {
            let i = ((y * 64 + x) * 4) as usize;
            assert_eq!(before[i + 3], after[i + 3], "alpha at ({x}, {y})");
            if mask[(y * 64 + x) as usize] >= 128 {
                continue;
            }
            assert_eq!(
                &before[i..i + 3],
                &after[i..i + 3],
                "pixel ({x}, {y}) is outside the mask"
            );
        }
    }
}

/// The mask's own bytes weight the write-back: at coverage 128 a pixel moves
/// half as far as the same pixel at 255, and at coverage 0 it does not move
/// at all. Same seed, so the fill underneath is identical and the only
/// difference is the weight.
#[test]
fn partial_coverage_blends_the_fill() {
    let doc = doc_of(64, 64, plasma);
    let inside = |x: u32, y: u32| (24..40).contains(&x) && (24..40).contains(&y);
    let full = mask_of(64, 64, inside);
    let half: Vec<u8> = full
        .iter()
        .map(|v| if *v >= 128 { 128 } else { 0 })
        .collect();
    let broken = punch(&doc, &full, [0, 0, 0]);
    let base = layer_bytes(&broken, 0);
    let strong = layer_bytes(&filled(&broken, &full, (64, 64), 3), 0);
    let (weak_doc, message) = fill(&broken, 0, &half, (64, 64), (0, 3), (false, false));
    assert!(message.is_none(), "unexpected message: {message:?}");
    let weak = layer_bytes(&weak_doc.expect("a half-covered fill still fills"), 0);
    let mut moved = 0;
    for y in 24..40u32 {
        for x in 24..40u32 {
            let i = ((y * 64 + x) * 4) as usize;
            for c in 0..3 {
                let (b, s, w) = (
                    f32::from(base[i + c]),
                    f32::from(strong[i + c]),
                    f32::from(weak[i + c]),
                );
                if (s - b).abs() < 4.0 {
                    continue;
                }
                moved += 1;
                let expected = b + (s - b) * 128.0 / 255.0;
                assert!(
                    (w - expected).abs() <= 1.5,
                    "({x}, {y}) channel {c}: 255 moved to {s} from {b}, so 128 should be near \
                     {expected}, not {w}"
                );
            }
        }
    }
    assert!(moved > 100, "the fixture must actually move pixels");
}

/// A feathered selection blends across its WHOLE ramp, and the fill's own
/// contribution grows continuously with the coverage byte.
///
/// The hole used to be `coverage >= 128` for both callers, with the write
/// weight taken from the coverage byte inside it and forced to zero outside.
/// For a selection that is a step, not a blend: nothing at all happened at
/// coverage 127 and 50.2 % of the fill's own effect happened at 128, so a
/// soft-edged selection came back with a hard edge exactly on its 50 %
/// contour — measured at 9 code values on a 128 px plasma, against a README,
/// a catalog entry and an FFI header that all promised a blend. The hole is
/// now every pixel the selection touches at all, so the ramp is inpainted
/// too and the weight rises from 0 with the byte.
///
/// The assertion is on the RESIDUE: the whole disc is painted white, so how
/// far a pixel has come back from white measures how much of the fill it
/// received. That has to rise with the coverage and — the point — must not
/// step across the 128 contour.
#[test]
fn a_feathered_selection_blends_across_its_whole_ramp() {
    let side = 200u32;
    let doc = doc_of(side, side, plasma);
    let centre = 100.0f32;
    // A disc whose coverage ramps 0 -> 255 over radius 60 -> 20, so every
    // 16-wide band of coverage is a 2.5 px annulus of several hundred pixels.
    let coverage = |x: u32, y: u32| -> u8 {
        let dx = x as f32 - centre;
        let dy = y as f32 - centre;
        let r = (dx * dx + dy * dy).sqrt();
        (((60.0 - r) / 40.0).clamp(0.0, 1.0) * 255.0).round() as u8
    };
    let mask: Vec<u8> = (0..side * side)
        .map(|i| coverage(i % side, i / side))
        .collect();
    // Damage the WHOLE disc, ramp included — the fill's job is to repair all
    // of it, in proportion to the coverage.
    let mut pixels = doc.layer_canvas_image(0).expect("layer 0");
    for y in 0..side {
        for x in 0..side {
            if coverage(x, y) > 0 {
                pixels.get_pixel_mut(x, y).0[..3].copy_from_slice(&[255, 255, 255]);
            }
        }
    }
    let broken = doc.with_layer_pixels(0, pixels).expect("layer 0");
    let before = layer_bytes(&broken, 0);
    let (out, message) = fill(&broken, 0, &mask, (side, side), (0, 7), (false, false));
    assert!(message.is_none(), "unexpected message: {message:?}");
    let after = layer_bytes(&out.expect("a feathered fill must land"), 0);

    // Nothing the selection does not touch may move at all.
    for y in 0..side {
        for x in 0..side {
            if coverage(x, y) > 0 {
                continue;
            }
            let i = ((y * side + x) * 4) as usize;
            assert_eq!(
                &before[i..i + 4],
                &after[i..i + 4],
                "pixel ({x}, {y}) is outside the selection"
            );
        }
    }

    // Mean distance from white, per band of coverage.
    let band = |low: u8, high: u8| -> f64 {
        let (mut sum, mut count) = (0f64, 0u64);
        for y in 0..side {
            for x in 0..side {
                let c = coverage(x, y);
                if c < low || c > high {
                    continue;
                }
                let i = ((y * side + x) * 4) as usize;
                for v in &after[i..i + 3] {
                    sum += f64::from(255 - *v);
                    count += 1;
                }
            }
        }
        assert!(count > 300, "band {low}..{high} must have pixels: {count}");
        sum / count as f64
    };
    let full = band(215, 255);
    let (below, above) = (band(112, 127), band(128, 143));
    let mid = band(64, 111);
    let faint = band(1, 24);
    println!(
        "feathered ramp, mean distance from white: 1-24 {faint:.1}, 64-111 {mid:.1}, \
         112-127 {below:.1}, 128-143 {above:.1}, 215-255 {full:.1}"
    );
    assert!(
        full > 20.0,
        "the fixture must actually repair the disc: {full:.1}"
    );
    // The ramp rises: nothing is repaired at the outside, everything at the
    // inside, and the middle is in the middle.
    assert!(
        faint < full * 0.2 && mid > full * 0.15 && mid < full * 0.75,
        "the fill must ramp with the coverage: 1-24 {faint:.1}, 64-111 {mid:.1}, \
         215-255 {full:.1}"
    );
    // And it does not STEP at the 50 % contour, which is the defect: with the
    // hole cut at 128 the band below it was 0.0 and the band above it half of
    // `full`.
    assert!(
        (above - below).abs() < full * 0.2,
        "the write-back steps across the 50 % contour: 112-127 {below:.1}, \
         128-143 {above:.1}, full {full:.1}"
    );
}

/// An interior discontinuity is what winner-take-all voting produces and what
/// the Poisson step — a SMOOTH harmonic field — provably cannot remove, so
/// this is the regression guard for ever reintroducing it: the filled region
/// must be no rougher, horizontally, than an equal patch of the real texture.
#[test]
fn the_fill_is_no_rougher_than_the_texture_it_replaces() {
    let doc = doc_of(96, 96, plasma);
    let inside = |x: u32, y: u32| (40..60).contains(&x) && (40..60).contains(&y);
    let mask = mask_of(96, 96, inside);
    let broken = punch(&doc, &mask, [0, 0, 0]);
    let out = layer_bytes(&filled(&broken, &mask, (96, 96), 11), 0);
    let source = layer_bytes(&doc, 0);
    let roughness = |bytes: &[u8], x0: u32, y0: u32| {
        let mut worst = 0i32;
        for y in y0..y0 + 20 {
            for x in x0..x0 + 19 {
                let i = ((y * 96 + x) * 4) as usize;
                for c in 0..3 {
                    let step = i32::from(bytes[i + c + 4]) - i32::from(bytes[i + c]);
                    worst = worst.max(step.abs());
                }
            }
        }
        worst
    };
    let filled_roughness = roughness(&out, 40, 40);
    let native = roughness(&source, 10, 10).max(roughness(&source, 60, 60));
    assert!(
        filled_roughness <= native * 2,
        "the fill jumps by {filled_roughness} between neighbours where the texture itself jumps \
         by at most {native}"
    );
}

/// Two blemishes far apart are filled independently, each from its own
/// neighbourhood: the fill in the red field must come back red and the one in
/// the blue field blue, never a blend of the two.
#[test]
fn disjoint_components_take_their_own_neighbourhoods() {
    let doc = doc_of(
        160,
        40,
        |x, _| {
            if x < 80 {
                [200, 40, 40]
            } else {
                [40, 40, 200]
            }
        },
    );
    let mask = mask_of(160, 40, |x, y| {
        (16..26).contains(&y) && ((30..40).contains(&x) || (120..130).contains(&x))
    });
    let broken = punch(&doc, &mask, [0, 200, 0]);
    let out = layer_bytes(&filled(&broken, &mask, (160, 40), 4), 0);
    for y in 16..26u32 {
        for x in 30..40u32 {
            let got = at(&out, 160, x, y);
            assert_eq!([got[0], got[1], got[2]], [200, 40, 40], "left ({x}, {y})");
        }
        for x in 120..130u32 {
            let got = at(&out, 160, x, y);
            assert_eq!([got[0], got[1], got[2]], [40, 40, 200], "right ({x}, {y})");
        }
    }
}

// ----------------------------------------------------------- spot healing --

/// Spot healing over a periodic texture heals to that texture: the same
/// inpaint, driven by an overlay's coverage instead of a selection mask.
#[test]
fn spot_healing_rebuilds_the_texture_under_the_footprint() {
    let doc = doc_of(48, 48, stripes);
    let footprint = |x: u32, y: u32| {
        let (dx, dy) = (x as f32 - 24.0, y as f32 - 24.0);
        dx * dx + dy * dy <= 25.0
    };
    let mask = mask_of(48, 48, footprint);
    let broken = punch(&doc, &mask, [255, 0, 0]);
    let overlay = coverage_overlay(48, 48, |x, y| if footprint(x, y) { 255 } else { 0 });
    let (out, message) = spot(&broken, &overlay, (48, 48), 1.0, (0, 21));
    assert!(message.is_none(), "unexpected message: {message:?}");
    let bytes = layer_bytes(&out.expect("spot heal must succeed"), 0);
    for y in 0..48u32 {
        for x in 0..48u32 {
            let got = at(&bytes, 48, x, y);
            assert_eq!([got[0], got[1], got[2]], stripes(x, y), "({x}, {y})");
        }
    }
}

/// A footprint over a uniform field comes back that colour; and one whose
/// content ALREADY equals its surroundings changes nothing at all and must
/// therefore refuse — the purity rule, since an identical copy would register
/// as an undo step in the app.
#[test]
fn spot_healing_on_flat_colour_fills_flat_and_then_refuses() {
    let doc = doc_of(48, 48, |_, _| [77, 88, 99]);
    let footprint = |x: u32, y: u32| (20..28).contains(&x) && (20..28).contains(&y);
    let overlay = coverage_overlay(48, 48, |x, y| if footprint(x, y) { 255 } else { 0 });
    let broken = punch(&doc, &mask_of(48, 48, footprint), [255, 0, 0]);
    let (out, message) = spot(&broken, &overlay, (48, 48), 1.0, (0, 1));
    assert!(message.is_none(), "unexpected message: {message:?}");
    let bytes = layer_bytes(&out.expect("a blemish on a flat field heals"), 0);
    for y in 0..48u32 {
        for x in 0..48u32 {
            let got = at(&bytes, 48, x, y);
            assert_eq!([got[0], got[1], got[2]], [77, 88, 99], "({x}, {y})");
        }
    }
    let (out, message) = spot(&doc, &overlay, (48, 48), 1.0, (0, 1));
    assert!(message.is_none(), "unexpected message: {message:?}");
    assert!(out.is_none(), "nothing would change, so the op must refuse");
}

// ----------------------------------------------------------- the refusals --

/// A hole over the cap is refused with a message naming the limit, and the
/// check is free: it happens before any window buffer is allocated.
#[test]
fn a_hole_over_the_cap_names_the_limit() {
    let side = 1100u32;
    let doc = doc_of(side, side, |_, _| [128, 128, 128]);
    let mask = mask_of(side, side, |_, _| true);
    let (out, message) = fill(&doc, 0, &mask, (side, side), (0, 0), (false, false));
    assert!(out.is_none());
    let message = message.expect("a cap must speak");
    assert!(
        message.contains(&MAX_INPAINT_HOLE_PIXELS.to_string()),
        "the message must name the limit: {message}"
    );
    assert!(
        message.contains("in pieces"),
        "and say what to do: {message}"
    );
}

/// The hole cap bounds the CALL, not one part of it. It used to be tested
/// against `component.pixels.len()` inside the per-component loop, so four
/// disjoint blobs of 384 400 pixels each — 1 537 600 covered, 54 % over the
/// stated limit — were all accepted and cost the sum, with no ceiling on the
/// component count at all. A magic-wand, Select Subject or additive-marquee
/// selection is routinely many components, so that was the normal shape of a
/// selection and not a corner case; and the sheet, the catalog entry and the
/// README all describe the number as a bound on the SELECTION.
#[test]
fn the_hole_cap_counts_every_part_of_the_selection() {
    let side = 2400u32;
    let doc = RzDocument::from_pixels(RgbaImage::from_pixel(side, side, Rgba([70, 80, 90, 255])));
    // Four disjoint squares, each comfortably UNDER the cap on its own.
    let blob = |v: u32| (100..720).contains(&v) || (1500..2120).contains(&v);
    let mask = mask_of(side, side, |x, y| blob(x) && blob(y));
    let covered = mask.iter().filter(|v| **v >= 128).count() as u64;
    assert!(
        covered > MAX_INPAINT_HOLE_PIXELS && covered / 4 < MAX_INPAINT_HOLE_PIXELS,
        "the fixture must bust the cap only in total: {covered} px in four parts"
    );
    let (out, message) = fill(&doc, 0, &mask, (side, side), (0, 0), (false, false));
    assert!(out.is_none(), "a selection over the cap must be refused");
    let message = message.expect("a cap must speak");
    assert!(
        message.contains(&covered.to_string())
            && message.contains(&MAX_INPAINT_HOLE_PIXELS.to_string()),
        "the message must name what was asked and what is allowed: {message}"
    );
}

/// The work cap is a budget for the whole call too, spent component by
/// component: the comb below busts it on its own, and preceding it with one
/// tiny blob makes the refusal name a LARGER total, which it could not do if
/// each component were measured against the full constant. (The blob is
/// three pixels of a uniform field, so its own fill is free and changes
/// nothing; all it does is spend a corner of the budget.)
#[test]
fn the_work_cap_is_a_budget_for_the_whole_call() {
    let side = 2600u32;
    let doc = RzDocument::from_pixels(RgbaImage::from_pixel(side, side, Rgba([80, 90, 100, 255])));
    // The comb of `a_dilated_region_over_the_work_cap_names_the_ring`, moved
    // down ten rows and joined along the BOTTOM, so a blob on row 0 is the
    // component the walk reaches first.
    let comb = move |x: u32, y: u32| (y >= 10 && x.is_multiple_of(43)) || y >= side - 3;
    let dilated_of = |mask: &[u8]| -> u64 {
        let (out, message) = fill(&doc, 0, mask, (side, side), (0, 0), (false, false));
        assert!(out.is_none(), "the work cap must refuse");
        let message = message.expect("the work cap must speak");
        assert!(
            message.contains("sampling ring")
                && message.contains(&MAX_INPAINT_TARGET_PIXELS.to_string()),
            "the message must name the ring and the limit: {message}"
        );
        // "... covers {total} pixels; ..." — the running total the call spent.
        let tail = message
            .split("covers ")
            .nth(1)
            .expect("the message states a total");
        tail.split(' ')
            .next()
            .expect("a number")
            .parse()
            .expect("a number")
    };
    let alone = dilated_of(&mask_of(side, side, comb));
    let with_blob = dilated_of(&mask_of(side, side, |x, y| {
        comb(x, y) || ((100..103).contains(&x) && y < 3)
    }));
    assert!(
        with_blob > alone,
        "the blob's own dilated area must count against the same budget: \
         {alone} alone, {with_blob} with the blob"
    );
}

/// An all-transparent surround has nothing to sample from, and says so.
///
/// The selection takes the whole of the layer's only opaque island, so there
/// is genuinely no pixel to copy from — which is what this sentence claims,
/// and the reason the fixture covers the island exactly rather than leaving a
/// rim of it. A rim would be the DIFFERENT refusal
/// `a_band_narrower_than_a_patch_says_so` pins.
#[test]
fn a_transparent_surround_is_refused() {
    let mut pixels = RgbaImage::new(64, 64);
    for y in 24..40u32 {
        for x in 24..40u32 {
            pixels.put_pixel(x, y, Rgba([10, 10, 10, 255]));
        }
    }
    let doc = RzDocument::from_pixels(pixels);
    let mask = mask_of(64, 64, |x, y| {
        (24..40).contains(&x) && (24..40).contains(&y)
    });
    let (out, message) = fill(&doc, 0, &mask, (64, 64), (0, 0), (false, false));
    assert!(out.is_none());
    let message = message.expect("a starved sample region must speak");
    assert!(
        message.contains("nothing to sample from") && message.contains("transparent"),
        "unexpected message: {message}"
    );
}

/// A selection with real picture around it that is merely NARROW is a
/// different refusal, and says the thing the caller can act on.
///
/// `patchmatch::sources` admits an origin only when its whole 7x7 window is
/// valid, so a band under seven pixels yields no origin at all however
/// opaque, unselected and on-canvas it is — and the op used to answer that
/// with "every pixel around the region is transparent, part of the region, or
/// outside the canvas", which on this fixture is false three times over and
/// leaves nothing to do about it. Bands of 3, 5 and 6 px refuse; 7 px fills.
#[test]
fn a_band_narrower_than_a_patch_says_so() {
    let side = 200u32;
    let doc = doc_of(side, side, plasma);
    for band in [3u32, 5, 6] {
        let mask = mask_of(side, side, |x, y| {
            (band..side - band).contains(&x) && (band..side - band).contains(&y)
        });
        let (out, message) = fill(&doc, 0, &mask, (side, side), (0, 4), (false, false));
        assert!(out.is_none(), "a {band} px band cannot seat a source patch");
        let message = message.expect("the narrow band must speak");
        assert!(
            message.contains("7 px") && message.contains("narrower than one source patch"),
            "the refusal must name the patch width: {message}"
        );
        assert!(
            !message.contains("transparent"),
            "and must not claim the surroundings are transparent: {message}"
        );
    }
    let mask = mask_of(side, side, |x, y| {
        (7..side - 7).contains(&x) && (7..side - 7).contains(&y)
    });
    let (out, message) = fill(&doc, 0, &mask, (side, side), (0, 4), (false, false));
    assert!(message.is_none(), "unexpected message: {message:?}");
    assert!(out.is_some(), "a 7 px band is exactly enough to fill from");
}

/// A layer with no opaque pixels at all names Sample All Layers, which is the
/// thing that would fix it.
#[test]
fn an_empty_layer_names_sample_all_layers() {
    let doc = RzDocument::from_pixels(RgbaImage::new(64, 64));
    let mask = mask_of(64, 64, |x, y| {
        (26..38).contains(&x) && (26..38).contains(&y)
    });
    let (out, message) = fill(&doc, 0, &mask, (64, 64), (0, 0), (false, false));
    assert!(out.is_none());
    let message = message.expect("an empty layer must speak");
    assert!(
        message.contains("Sample All Layers"),
        "unexpected message: {message}"
    );
}

/// The plain refusals: NULL buffer, wrong dimensions, a bad index, an empty
/// mask — every one NULL with NO message, because none of them is an error
/// the user should read a sentence about.
#[test]
fn plain_refusals_carry_no_message() {
    let doc = doc_of(32, 32, stripes);
    let mask = mask_of(32, 32, |x, y| {
        (12..20).contains(&x) && (12..20).contains(&y)
    });
    let empty = vec![0u8; 32 * 32];
    for (label, out, message) in [
        {
            let (o, m) = fill(&doc, 9, &mask, (32, 32), (0, 0), (false, false));
            ("a layer index past the stack", o, m)
        },
        {
            let (o, m) = fill(&doc, 0, &mask, (16, 16), (0, 0), (false, false));
            ("dimensions that are not the canvas", o, m)
        },
        {
            let (o, m) = fill(&doc, 0, &empty, (32, 32), (0, 0), (false, false));
            ("an empty mask", o, m)
        },
    ] {
        assert!(out.is_none(), "{label} must refuse");
        assert!(
            message.is_none(),
            "{label} must not set a message: {message:?}"
        );
    }
    // A non-finite strength on the spot-heal path, and a NULL buffer on both.
    let overlay = coverage_overlay(32, 32, |_, _| 255);
    let (out, message) = spot(&doc, &overlay, (32, 32), f32::NAN, (0, 0));
    assert!(
        out.is_none() && message.is_none(),
        "NaN strength: {message:?}"
    );
    let handle = Box::into_raw(Box::new(doc.clone()));
    unsafe {
        assert!(rz_doc_content_aware_fill(
            handle,
            0,
            ptr::null(),
            32,
            32,
            0,
            0,
            false,
            false,
            ptr::null_mut()
        )
        .is_null());
        rz_doc_free(handle);
    }
}

/// A canvas smaller than one patch cannot seat a source at all. It must
/// refuse with the sentence, not panic: "no input may panic" is the rule, and
/// a four-pixel document is the smallest input there is.
#[test]
fn a_canvas_smaller_than_a_patch_refuses() {
    let doc = doc_of(4, 4, |x, y| [x as u8 * 60, y as u8 * 60, 128]);
    let mask = mask_of(4, 4, |_, _| true);
    let (out, message) = fill(&doc, 0, &mask, (4, 4), (0, 0), (false, false));
    assert!(out.is_none());
    assert!(
        message.is_some_and(|m| m.contains("nothing to sample from")),
        "a canvas with no room for a patch must say so"
    );
}

/// A hole whose DILATED region busts the work cap is refused, and the ring
/// has already been narrowed as far as it goes before that happens: a comb of
/// one-pixel teeth 43 px apart, joined at the top so it is one component,
/// covers the whole canvas once every tooth is grown by the narrowest ring
/// the automatic rules will use.
#[test]
fn a_dilated_region_over_the_work_cap_names_the_ring() {
    let side = 2600u32;
    let doc = RzDocument::from_pixels(RgbaImage::from_pixel(side, side, Rgba([80, 90, 100, 255])));
    let mask = mask_of(side, side, |x, y| x.is_multiple_of(43) || y < 3);
    let covered = mask.iter().filter(|v| **v >= 128).count() as u64;
    assert!(
        covered < MAX_INPAINT_HOLE_PIXELS,
        "the comb must pass the hole cap to reach the work cap: {covered} px"
    );
    let (out, message) = fill(&doc, 0, &mask, (side, side), (0, 0), (false, false));
    assert!(out.is_none());
    let message = message.expect("the work cap must speak");
    assert!(
        message.contains(&MAX_INPAINT_TARGET_PIXELS.to_string())
            && message.contains("sampling ring"),
        "the message must name the ring and the limit: {message}"
    );
}

/// A component whose window is over the MEMORY bound is refused in the words
/// of memory, before a single window buffer is allocated.
#[test]
fn a_window_over_the_memory_bound_says_so() {
    // 32.5 megapixels, just over `MAX_SOLVE_WINDOW_PIXELS`.
    let (w, h) = (6500u32, 5000u32);
    const _: () = assert!(6500 * 5000 > MAX_SOLVE_WINDOW_PIXELS as usize);
    let doc = RzDocument::from_pixels(RgbaImage::from_pixel(w, h, Rgba([40, 50, 60, 255])));
    // A three-pixel diagonal: a few thousand covered pixels in ONE
    // 4-connected run, and a box of 32.5 megapixels. Only the MEMORY bound
    // may refuse this.
    let mask = mask_of(w, h, |x, y| {
        (x as f32 * (h as f32 / w as f32) - y as f32).abs() <= 1.5
    });
    let (out, message) = fill(&doc, 0, &mask, (w, h), (0, 0), (false, false));
    assert!(out.is_none());
    let message = message.expect("the memory bound must speak");
    assert!(
        message.contains("working buffers") && message.contains("megapixels"),
        "the message must be worded as memory: {message}"
    );
}

// ------------------------------------------------------------- the shapes --

/// The case the old bounding-box cap refused, and content-aware fill's most
/// common use: a three-pixel diagonal scratch corner to corner. Its box is
/// nearly the whole photograph and its area is a few thousand pixels, so it
/// must fill — and fill quickly.
#[test]
fn a_thin_diagonal_scratch_fills_quickly() {
    let (w, h) = (2000u32, 1500u32);
    let doc = doc_of(w, h, plasma);
    let on_scratch = |x: u32, y: u32| {
        let expected = x as f32 * (h as f32 / w as f32);
        (expected - y as f32).abs() <= 1.5
    };
    let mask = mask_of(w, h, on_scratch);
    let covered = mask.iter().filter(|v| **v >= 128).count();
    assert!(
        (3000..40_000).contains(&covered),
        "the fixture must be thin: {covered} px"
    );
    let broken = punch(&doc, &mask, [255, 255, 255]);
    let started = Instant::now();
    let out = filled(&broken, &mask, (w, h), 8);
    let elapsed = started.elapsed();
    println!("thin diagonal scratch ({covered} px): {elapsed:?}");
    let bytes = layer_bytes(&out, 0);
    let original = layer_bytes(&doc, 0);
    let mut worst = 0i32;
    for y in 0..h {
        for x in 0..w {
            if !on_scratch(x, y) {
                continue;
            }
            let i = ((y * w + x) * 4) as usize;
            for c in 0..3 {
                worst = worst.max((i32::from(bytes[i + c]) - i32::from(original[i + c])).abs());
            }
        }
    }
    assert!(
        worst < 96,
        "the scratch is still visible: {worst} code values"
    );
    assert!(
        elapsed.as_secs_f64() < 5.0,
        "a scratch must not cost like its bounding box: {elapsed:?}"
    );
}

// ---------------------------------------------------------------- preview --

/// The preview runs the WHOLE pipeline on a reduced window — the distance
/// transform, the origin list, the field, the EM loop, the membrane solve —
/// and upsamples the healed window back, so on a uniform field it must still
/// come back byte-exact: every one of those stages has to be right for a
/// constant to survive the round trip.
#[test]
fn a_preview_of_a_uniform_field_is_exact() {
    let doc = doc_of(1200, 1200, |_, _| [64, 96, 160]);
    let mask = mask_of(1200, 1200, |x, y| {
        (100..1100).contains(&x) && (100..1100).contains(&y)
    });
    let broken = punch(&doc, &mask, [255, 0, 0]);
    let (out, message) = fill(&broken, 0, &mask, (1200, 1200), (0, 2), (false, true));
    assert!(message.is_none(), "unexpected message: {message:?}");
    let bytes = layer_bytes(&out.expect("a preview must produce something"), 0);
    for y in (0..1200u32).step_by(7) {
        for x in (0..1200u32).step_by(7) {
            let got = at(&bytes, 1200, x, y);
            assert_eq!([got[0], got[1], got[2]], [64, 96, 160], "({x}, {y})");
        }
    }
}

/// The point of the parameter: the preview's cost is bounded by WORK, so a
/// hole a hundred times bigger must not take a hundred times longer. Without
/// the reduction the second call below is a full one-megapixel fill — seconds
/// — and the sheet's debounced re-render would beachball its own Cancel
/// button waiting for it.
#[test]
fn a_preview_is_bounded_by_work() {
    let doc = doc_of(1200, 1200, plasma);
    let small = mask_of(1200, 1200, |x, y| {
        (550..650).contains(&x) && (550..650).contains(&y)
    });
    let big = mask_of(1200, 1200, |x, y| {
        (100..1100).contains(&x) && (100..1100).contains(&y)
    });
    let broken_small = punch(&doc, &small, [255, 255, 255]);
    let broken_big = punch(&doc, &big, [255, 255, 255]);

    let started = Instant::now();
    let (out, message) = fill(
        &broken_small,
        0,
        &small,
        (1200, 1200),
        (0, 6),
        (false, true),
    );
    let small_time = started.elapsed();
    assert!(message.is_none(), "unexpected message: {message:?}");
    assert!(out.is_some(), "a preview must produce something");

    let started = Instant::now();
    let (out, message) = fill(&broken_big, 0, &big, (1200, 1200), (0, 6), (false, true));
    let big_time = started.elapsed();
    assert!(message.is_none(), "unexpected message: {message:?}");
    let bytes = layer_bytes(&out.expect("a preview must produce something"), 0);
    println!("preview: 10 k hole {small_time:?}, 1 M hole {big_time:?}");
    let mut damaged = 0;
    for y in (400..800u32).step_by(3) {
        for x in (400..800u32).step_by(3) {
            let got = at(&bytes, 1200, x, y);
            if got[0] > 250 && got[1] > 250 && got[2] > 250 {
                damaged += 1;
            }
        }
    }
    assert_eq!(damaged, 0, "the preview must show the damage repaired");
    assert!(
        big_time.as_secs_f64() < small_time.as_secs_f64() + 3.0,
        "a hundredfold hole must not cost a hundredfold: {small_time:?} vs {big_time:?}"
    );
}

// ----------------------------------------------------------- sample layers --

/// `sample_all` decides where the SOURCE comes from, and only the core can
/// know — it is the core that generates the fill. The fixture is a small
/// opaque patch layer over a striped background: filling the patch's middle
/// from the PATCH has a five-pixel rim to sample and cannot even seat one
/// source patch, while filling it from the COMPOSITE has the whole
/// photograph. With the composite's stripes as the source and the patch's own
/// rim as the destination the answer is exactly the stripes, so this is a
/// byte-exact assertion, not an approximate one.
#[test]
fn sample_all_layers_chooses_the_composite() {
    let base = doc_of(200, 200, stripes);
    let mut patch = RgbaImage::new(200, 200);
    for y in 80..120u32 {
        for x in 80..120u32 {
            let inside = (85..115).contains(&x) && (85..115).contains(&y);
            let c = if inside { [255, 0, 255] } else { stripes(x, y) };
            patch.put_pixel(x, y, Rgba([c[0], c[1], c[2], 255]));
        }
    }
    let doc = base
        .adding_image_layer(0, patch, "patch")
        .expect("two layers");
    let mask = mask_of(200, 200, |x, y| {
        (85..115).contains(&x) && (85..115).contains(&y)
    });

    let (out, message) = fill(&doc, 1, &mask, (200, 200), (0, 3), (false, false));
    assert!(
        out.is_none(),
        "the patch layer's own five-pixel rim cannot seat a source patch"
    );
    assert!(
        message.is_some_and(|m| m.contains("narrower than one source patch")),
        "and it must say so in the words of the band, not of transparency"
    );

    let (out, message) = fill(&doc, 1, &mask, (200, 200), (0, 3), (true, false));
    assert!(message.is_none(), "unexpected message: {message:?}");
    let bytes = layer_bytes(&out.expect("the composite has plenty to sample"), 1);
    for y in 80..120u32 {
        for x in 80..120u32 {
            let got = at(&bytes, 200, x, y);
            assert_eq!(
                [got[0], got[1], got[2]],
                stripes(x, y),
                "({x}, {y}) must come back as the stripes the composite shows"
            );
        }
    }
    // And the patch layer is still transparent everywhere it was.
    assert_eq!(at(&bytes, 200, 20, 20)[3], 0, "alpha outside the patch");
}

// ---------------------------------------------------------------- timings --

/// The brief's case, measured: a 300 x 300 hole in a 2000 x 1500 photograph.
/// The assertion is deliberately generous — this test exists to PRINT the
/// number that `doc_inpaint`'s module doc records, and a tight bound would go
/// flaky under `cargo test`'s parallelism.
#[test]
fn a_300_square_hole_in_a_2000_by_1500_photograph() {
    let (w, h) = (2000u32, 1500u32);
    let doc = doc_of(w, h, plasma);
    let mask = mask_of(w, h, |x, y| {
        (850..1150).contains(&x) && (600..900).contains(&y)
    });
    let broken = punch(&doc, &mask, [255, 255, 255]);
    let started = Instant::now();
    let out = filled(&broken, &mask, (w, h), 12345);
    let elapsed = started.elapsed();
    println!("2000x1500 document, 300x300 hole: {elapsed:?}");
    let bytes = layer_bytes(&out, 0);
    // The white damage must be gone: nothing inside the hole may still be the
    // flat colour it was punched with.
    let mut white = 0;
    for y in 860..890u32 {
        for x in 900..1100u32 {
            let got = at(&bytes, w, x, y);
            if got[0] > 250 && got[1] > 250 && got[2] > 250 {
                white += 1;
            }
        }
    }
    assert_eq!(white, 0, "the damage is still there");
    assert!(
        elapsed.as_secs_f64() < 15.0,
        "the brief's case must stay interactive: {elapsed:?}"
    );
}

/// The cost claim `doc_inpaint`'s module doc makes and the catalog entry, the
/// sheet footnote and the README all repeat: **at the megapixel cap the fill
/// costs about the same at every ring**, because a ring widens the WINDOW
/// while the search and the vote are paid per TARGET, and the targets are the
/// hole. The claim used to be the opposite — a five-fold ring effect, which
/// was an App Nap artifact measured through a demoted app — and the advice
/// that came with it ("pass a narrow ring for a big fill") sent callers down
/// a path that does not exist. The assertion is a RATIO, which survives
/// `cargo test`'s parallelism where an absolute bound would not; the loose
/// absolute bound beside it is the phase's 15 s budget for a blocking Apply.
#[test]
fn the_ring_does_not_drive_the_cost_at_the_cap() {
    let (w, h) = (2000u32, 1500u32);
    let doc = doc_of(w, h, plasma);
    // Exactly MAX_INPAINT_HOLE_PIXELS, so this is the cap itself.
    let mask = mask_of(w, h, |x, y| {
        (500..1500).contains(&x) && (250..1250).contains(&y)
    });
    let broken = punch(&doc, &mask, [255, 255, 255]);

    // 48 is the sheet's own default, widened from below to 282 by rule 1;
    // 512 is the ceiling, and the automatic ring for a hole this size.
    let started = Instant::now();
    let (narrow, message) = fill(&broken, 0, &mask, (w, h), (48, 5), (false, false));
    let narrow_time = started.elapsed();
    assert!(message.is_none(), "unexpected message: {message:?}");
    assert!(narrow.is_some(), "the cap itself must be allowed");

    let started = Instant::now();
    let (wide, message) = fill(&broken, 0, &mask, (w, h), (512, 5), (false, false));
    let wide_time = started.elapsed();
    assert!(message.is_none(), "unexpected message: {message:?}");
    assert!(wide.is_some(), "the widest ring must be allowed too");

    println!("1 M hole: ring 48 {narrow_time:?}, ring 512 {wide_time:?}");
    let (narrow_s, wide_s) = (narrow_time.as_secs_f64(), wide_time.as_secs_f64());
    assert!(
        wide_s < narrow_s * 2.0 && narrow_s < wide_s * 2.0,
        "the ring must not drive the cost: ring 48 {narrow_time:?}, ring 512 {wide_time:?}"
    );
    assert!(
        narrow_s < 15.0 && wide_s < 15.0,
        "the cap must stay inside the blocking budget: {narrow_time:?}, {wide_time:?}"
    );
}

/// Rule 1 widens a ring from below by half the hole's own radius, and it does
/// that to an EXPLICIT ring exactly as it does to the automatic one — which
/// is why a narrow ring is not an escape hatch from anything. A 100 x 100
/// hole has a radius of 57, so every requested ring under 28.5 becomes 28.5:
/// 21 and 28 must give byte-identical pixels. A ring ABOVE the floor is
/// honoured, and 300 gives a different (equally plausible) fill, so this is
/// not the trivial "the parameter is ignored" reading.
#[test]
fn a_ring_under_the_widening_floor_is_raised_to_it() {
    let doc = doc_of(400, 400, plasma);
    let mask = mask_of(400, 400, |x, y| {
        (150..250).contains(&x) && (150..250).contains(&y)
    });
    let broken = punch(&doc, &mask, [255, 255, 255]);
    let at_floor = |ring: u32| {
        let (out, message) = fill(&broken, 0, &mask, (400, 400), (ring, 9), (false, false));
        assert!(message.is_none(), "unexpected message: {message:?}");
        layer_bytes(&out.expect("the fill must land"), 0)
    };
    assert_eq!(
        at_floor(21),
        at_floor(28),
        "both are under the 28.5 px floor, so both must run at it"
    );
    assert_ne!(
        at_floor(21),
        at_floor(300),
        "a ring above the floor is honoured and samples a different neighbourhood"
    );
}

// ------------------------------------------------------- the pyramid edge --

/// A hole AT the canvas edge must cost — and reconstruct — like the same hole
/// in the middle of the same picture.
///
/// The window is the hole's box padded by the ring and clamped to the canvas,
/// so a hole touching a border has a margin of zero on that side however wide
/// the band on the other three. `should_coarsen` took the NARROWEST of the
/// four margins, so any hole within `2·PATCH` of an image border built no
/// pyramid at all; and since a single-level run is the coarsest level
/// (`em_iterations`), the finest and most expensive level then ran the
/// 10-iteration coarsest schedule. Measured here before the fix: 0.642 s and
/// a mean error of 29.1 at the edge against 0.295 s and 9.2 in the middle —
/// 2.2x the time and 3.2x the error for moving the same selection to the side
/// of the frame, which is where a person removes someone from a photograph.
/// Both halves are asserted as RATIOS, which survive `cargo test`'s
/// parallelism where an absolute bound would not.
#[test]
fn a_hole_at_the_canvas_edge_costs_like_one_in_the_middle() {
    let side = 800u32;
    let hole = 200u32;
    let doc = doc_of(side, side, plasma);
    let run = |x0: u32| {
        let y0 = (side - hole) / 2;
        let mask = mask_of(side, side, |x, y| {
            (x0..x0 + hole).contains(&x) && (y0..y0 + hole).contains(&y)
        });
        let broken = punch(&doc, &mask, [255, 255, 255]);
        let started = Instant::now();
        let out = filled(&broken, &mask, (side, side), 7);
        let elapsed = started.elapsed();
        let (bytes, original) = (layer_bytes(&out, 0), layer_bytes(&doc, 0));
        let mut sum = 0f64;
        let mut count = 0u64;
        for (i, v) in mask.iter().enumerate() {
            if *v < 128 {
                continue;
            }
            for c in 0..3 {
                sum += (f64::from(bytes[i * 4 + c]) - f64::from(original[i * 4 + c])).abs();
                count += 1;
            }
        }
        (elapsed.as_secs_f64(), sum / count as f64)
    };
    let (middle_time, middle_error) = run((side - hole) / 2);
    let (edge_time, edge_error) = run(0);
    println!(
        "{hole} px hole: middle {middle_time:.3} s / err {middle_error:.2}, \
         edge {edge_time:.3} s / err {edge_error:.2}"
    );
    // The DETERMINISTIC guard is the error below — losing the pyramid showed
    // as 2.9x the reconstruction error as well as 2.3x the time, and the
    // error is a function of the fixed seed alone. The time bound is kept
    // because it is what a reader wants to see, and set at 2.0: the
    // measurement is 1.03 (0.24 s against 0.24 s), so a loaded machine has
    // twice the headroom while the 2.3x regression is still caught.
    assert!(
        edge_time < middle_time * 2.0,
        "a hole at the edge must not lose its pyramid: {edge_time:.3} s against \
         {middle_time:.3} s in the middle"
    );
    assert!(
        edge_error < middle_error * 1.8,
        "nor its reconstruction: {edge_error:.2} against {middle_error:.2} in the middle"
    );
}

// --------------------------------------------- the spot heal write weight --

/// Hardness shrinks a spot-healing footprint; it does not FADE the heal.
///
/// `doc_heal`'s write-back is a hard cut at the alpha = 128 contour, and spot
/// healing is one of the callers that rule is FOR: its coverage is a brush
/// dab, exactly like the healing brush's. It used to hand that dab's raw
/// alpha through as the write weight, so a soft tip wrote
/// `dst + (alpha/255)·(fill − dst)` and left a visible ghost of the blemish
/// inside its own footprint — and a step in the weight exactly at the
/// contour, which is the seam the hard cut exists to avoid. Content-Aware
/// Fill is the one caller whose soft bytes really do weight the write, which
/// `partial_coverage_blends_the_fill` pins; this is the other half of that
/// pair.
#[test]
fn a_soft_tipped_spot_heal_removes_the_blemish_completely() {
    let (w, h) = (300u32, 300u32);
    // A horizontal ramp: smooth, so the membrane solve reproduces it exactly
    // and any residue is a colour that cannot be there.
    let doc = doc_of(w, h, |x, _| {
        let v = (60 + x * 120 / w) as u8;
        [v, v, v]
    });
    let radius = |x: u32, y: u32| {
        let (dx, dy) = (f64::from(x) - 150.0, f64::from(y) - 150.0);
        (dx * dx + dy * dy).sqrt()
    };
    let blemish = mask_of(w, h, |x, y| radius(x, y) <= 25.0);
    let broken = punch(&doc, &blemish, [255, 0, 0]);
    // Hardness 0: a linear falloff to zero at r = 100, so the alpha = 128
    // contour is at r = 50 — the blemish is well inside it and most of the
    // footprint's area is below the threshold.
    let overlay = coverage_overlay(w, h, |x, y| {
        (255.0 * (1.0 - radius(x, y) / 100.0)).clamp(0.0, 255.0) as u8
    });
    let (out, message) = spot(&broken, &overlay, (w, h), 1.0, (0, 4));
    assert!(message.is_none(), "unexpected message: {message:?}");
    let healed = layer_bytes(&out.expect("a soft-tipped spot heal must land"), 0);
    let original = layer_bytes(&doc, 0);
    let damaged = layer_bytes(&broken, 0);
    let mut worst_residue = 0i32;
    let mut worst_cast = 0i32;
    for y in 0..h {
        for x in 0..w {
            let i = ((y * w + x) * 4) as usize;
            let r = radius(x, y);
            if r <= 25.0 {
                for c in 0..3 {
                    let delta = i32::from(healed[i + c]) - i32::from(original[i + c]);
                    worst_residue = worst_residue.max(delta.abs());
                }
                // The blemish is pure red, so any survivor shows as R above G.
                worst_cast = worst_cast.max(i32::from(healed[i]) - i32::from(healed[i + 1]));
            } else if r >= 53.0 {
                assert_eq!(
                    &healed[i..i + 4],
                    &damaged[i..i + 4],
                    "nothing outside the alpha = 128 contour may move ({x}, {y})"
                );
            }
        }
    }
    println!("soft spot heal: worst residue {worst_residue}, worst red cast {worst_cast}");
    assert!(
        worst_residue < 12,
        "a soft tip must heal at full strength inside the contour: {worst_residue} code values"
    );
    assert!(
        worst_cast < 8,
        "no part of the blemish may survive the heal: {worst_cast} code values of red"
    );
}

// ------------------------------------------------ what counts as a source --

/// Alpha on the sampled image answers ONE question — is there colour here —
/// and the RGB beside it is straight, so a pixel at alpha 204 is as good a
/// source as one at 255. Testing `== 255` made the whole op unusable on any
/// composite that is nowhere fully opaque: one layer at 80 % opacity flattens
/// to alpha 204 everywhere, every pixel was disqualified, and both entry
/// points refused with a sentence claiming the surroundings were transparent
/// when nothing in the picture was. Confirmed end to end through the app
/// before it was fixed; this is the same call.
#[test]
fn a_semi_transparent_composite_is_a_usable_source() {
    let doc = doc_of(200, 200, stripes)
        .with_layer_opacity(0, 0.8)
        .expect("an 80 % layer");
    let mask = mask_of(200, 200, |x, y| {
        (90..110).contains(&x) && (90..110).contains(&y)
    });
    // Punched, so the fill has something to repair: reproducing the stripes
    // byte for byte would be a legitimate "nothing changed" refusal.
    let doc = punch(&doc, &mask, [255, 0, 255]);
    let (out, message) = fill(&doc, 0, &mask, (200, 200), (0, 4), (true, false));
    assert!(
        message.is_none(),
        "an 80 % opaque composite is a source, not a refusal: {message:?}"
    );
    assert!(out.is_some(), "the fill must land");

    // And the same for spot healing, whose sample-all path is the same guard.
    let overlay = coverage_overlay(200, 200, |x, y| {
        if (90..110).contains(&x) && (90..110).contains(&y) {
            255
        } else {
            0
        }
    });
    let handle = Box::into_raw(Box::new(doc.clone()));
    let mut err: *mut c_char = ptr::null_mut();
    let out = unsafe {
        rz_doc_spot_heal_layer(
            handle,
            0,
            overlay.as_ptr(),
            200,
            200,
            1.0,
            0,
            4,
            true,
            false,
            &mut err,
        )
    };
    unsafe { rz_doc_free(handle) };
    let (healed, message) = take_doc(out, err);
    assert!(
        message.is_none(),
        "spot healing must not refuse it either: {message:?}"
    );
    assert!(healed.is_some(), "the spot heal must land");
}

/// A picture that really IS transparent everywhere still refuses, and says
/// what is true of it — the whole image, not "every pixel around the region",
/// which is the sentence for a starved neighbourhood.
#[test]
fn a_wholly_transparent_composite_says_so() {
    let doc = RzDocument::from_pixels(RgbaImage::new(64, 64));
    let mask = mask_of(64, 64, |x, y| {
        (26..38).contains(&x) && (26..38).contains(&y)
    });
    let (out, message) = fill(&doc, 0, &mask, (64, 64), (0, 0), (true, false));
    assert!(out.is_none());
    let message = message.expect("a transparent picture must speak");
    assert!(
        message.contains("every pixel in the picture is transparent"),
        "unexpected message: {message}"
    );
}

// --------------------------------------------- who the refusal is talking to --

/// The caps are one set of numbers; the sentences reporting them are not. A
/// spot-heal stroke used to be told "content-aware fill works on at most
/// 1,000,000 pixels … Select less, or fill it in pieces" and to "use a
/// narrower ring" — a command the user did not run and a control the Spot
/// Healing Brush does not have (it always passes ring 0). The wording is the
/// only thing that branches, and `doc_heal::over_window_limit` is the
/// standard it now meets.
#[test]
fn spot_healing_is_refused_in_the_words_of_a_stroke() {
    let (w, h) = (1200u32, 1000u32);
    let doc = doc_of(w, h, plasma);
    // Over MAX_INPAINT_HOLE_PIXELS in one footprint.
    let overlay = coverage_overlay(w, h, |_, _| 255);
    let (out, message) = spot(&doc, &overlay, (w, h), 1.0, (0, 1));
    assert!(out.is_none(), "a footprint over the cap must be refused");
    let message = message.expect("a cap must speak");
    assert!(
        message.contains(&MAX_INPAINT_HOLE_PIXELS.to_string()) && message.contains("stroke"),
        "the message must name the limit and the gesture: {message}"
    );
    for wrong in ["content-aware fill", "election", "ring"] {
        assert!(
            !message.contains(wrong),
            "a stroke must not be told about {wrong:?}: {message}"
        );
    }
    // And the fill's own wording is unchanged: same cap, same numbers, the
    // words of a selection.
    let mask = mask_of(w, h, |_, _| true);
    let (_, fill_message) = fill(&doc, 0, &mask, (w, h), (0, 1), (false, false));
    let fill_message = fill_message.expect("the same cap must speak to the fill");
    assert!(
        fill_message.contains("content-aware fill") && fill_message.contains("Select less"),
        "the fill keeps its own sentence: {fill_message}"
    );
}

// ------------------------------------------------- the caps cost nothing --

/// A refusal must be cheap. The dilated-area budget used to be spent
/// component by component inside the fill loop, so a call that was going to
/// be refused first inpainted and Poisson-solved every component before the
/// one that busted the cap — measured in the app, 13 s of frozen main thread
/// to be told no, against 12 s to actually fill the same shape with fewer
/// parts. Everything the caps are stated in is measurable from the coverage
/// plane and one distance transform per component, so the refusal now happens
/// before a pixel is touched. The assertion is a RATIO, which survives
/// `cargo test`'s parallelism where an absolute bound would not.
#[test]
fn a_refused_fill_costs_far_less_than_a_fill() {
    let side = 2600u32;
    let doc = doc_of(side, side, plasma);
    // The comb of `a_dilated_region_over_the_work_cap_names_the_ring`: teeth
    // 43 px apart joined along the top, one component, refused on the work
    // cap however narrow the ring.
    let refused = mask_of(side, side, |x, y| x.is_multiple_of(43) || y < 3);
    let started = Instant::now();
    let (out, message) = fill(&doc, 0, &refused, (side, side), (0, 3), (false, false));
    let refused_time = started.elapsed();
    assert!(out.is_none(), "the comb must be refused");
    assert!(message.is_some(), "and say why");

    // A selection that IS filled, of the same kind and comfortably smaller:
    // the same comb with a twentieth of the teeth.
    let filled_mask = mask_of(side, side, |x, y| {
        (x.is_multiple_of(43) && (x / 43).is_multiple_of(20)) || y < 3
    });
    let started = Instant::now();
    let (out, message) = fill(&doc, 0, &filled_mask, (side, side), (0, 3), (false, false));
    let fill_time = started.elapsed();
    assert!(message.is_none(), "unexpected message: {message:?}");
    assert!(out.is_some(), "the smaller comb must fill");
    println!("work cap: refused in {refused_time:?}, filled in {fill_time:?}");
    // Measured 0.16 s against 1.48 s, a ratio of 9; the defect was a ratio of
    // about 1, so two is a bound a loaded machine cannot cross.
    assert!(
        refused_time.as_secs_f64() * 2.0 < fill_time.as_secs_f64(),
        "a refusal must not cost like a fill: refused {refused_time:?}, filled {fill_time:?}"
    );
}

/// The narrowing is UNIFORM across the call, not first come first served.
/// Spent greedily, the early components took their full ring and the late
/// ones were starved down to the floor until one of them would not fit at
/// all — so a scatter of specks far under every stated cap was refused as an
/// allocation artifact, at the sheet's own default ring, while the identical
/// selection at a narrower ring succeeded. Four hundred specks dilated by 48
/// come to 4.7 M against a 4 M budget; one halving for all of them is 1.4 M,
/// and that is what the planner picks.
#[test]
fn a_scatter_of_specks_narrows_uniformly_instead_of_being_refused() {
    let side = 2100u32;
    let doc = doc_of(side, side, plasma);
    let speck = |v: u32| v >= 50 && (v - 50) % 100 < 12 && v < 2050;
    let mask = mask_of(side, side, |x, y| speck(x) && speck(y));
    let covered = mask.iter().filter(|v| **v >= 128).count() as u64;
    assert!(
        covered * 10 < MAX_INPAINT_HOLE_PIXELS,
        "the fixture must be far under the hole cap: {covered} px"
    );
    // 48 px is the sheet's default ring, and the value the app was refused at.
    let (out, message) = fill(&doc, 0, &mask, (side, side), (48, 2), (false, false));
    assert!(
        message.is_none(),
        "a dust selection must narrow, not refuse: {message:?}"
    );
    assert!(out.is_some(), "and it must fill");
}

/// The preview's reduction is chosen from the CALL, not from one component.
/// Per component it bounded nothing — `preview_factor` returns 1 for anything
/// at or under 40 000 pixels, so every part of a scattered selection previewed
/// at FULL resolution and the sheet's "live preview" cost exactly what the
/// fill it was previewing cost, with Cancel blocking the main thread on it.
/// Twenty-five disjoint 200 x 200 parts are 1 000 000 covered pixels in parts
/// of 40 000 — the boundary case, and the routine shape of a magic-wand or
/// dust selection.
#[test]
fn a_scattered_selection_previews_far_faster_than_it_fills() {
    let (w, h) = (1200u32, 1200u32);
    let doc = doc_of(w, h, plasma);
    let part = |v: u32| (v % 240) < 200 && v < 1200;
    let mask = mask_of(w, h, |x, y| part(x) && part(y));
    let covered = mask.iter().filter(|v| **v >= 128).count() as u64;
    assert!(
        covered == 25 * 200 * 200,
        "the fixture must be 25 parts of 40 000 px: {covered}"
    );
    let broken = punch(&doc, &mask, [255, 255, 255]);

    let started = Instant::now();
    let (out, message) = fill(&broken, 0, &mask, (w, h), (0, 6), (false, true));
    let preview_time = started.elapsed();
    assert!(message.is_none(), "unexpected message: {message:?}");
    let bytes = layer_bytes(&out.expect("a preview must produce something"), 0);

    let started = Instant::now();
    let (out, message) = fill(&broken, 0, &mask, (w, h), (0, 6), (false, false));
    let fill_time = started.elapsed();
    assert!(message.is_none(), "unexpected message: {message:?}");
    assert!(out.is_some(), "the full fill must land");
    println!("25-part selection: preview {preview_time:?}, fill {fill_time:?}");

    // The preview still has to show the damage repaired — a fast preview of
    // nothing would pass a bare ratio.
    let mut damaged = 0;
    for y in (0..h).step_by(3) {
        for x in (0..w).step_by(3) {
            if mask[(y * w + x) as usize] < 128 {
                continue;
            }
            let got = at(&bytes, w, x, y);
            if got[0] > 250 && got[1] > 250 && got[2] > 250 {
                damaged += 1;
            }
        }
    }
    assert_eq!(damaged, 0, "the preview must show the damage repaired");
    // Measured 0.57 s against 8.4 s, a ratio of 15; the defect was a ratio of
    // 1 (the preview cost the fill), so two has seven times the headroom of
    // the measurement and still catches it.
    assert!(
        preview_time.as_secs_f64() * 2.0 < fill_time.as_secs_f64(),
        "the preview must be bounded by the CALL's work: preview {preview_time:?}, \
         fill {fill_time:?}"
    );
}

// -------------------------------------------- the random search must search --

/// Every EM iteration's random search has to draw its OWN candidates.
///
/// The draws are addressed positionally — `(seed, level, sweep, target)`, so
/// nothing depends on how many came before — and the SWEEP has to count
/// across the level rather than restart inside each `search()` call, or every
/// EM iteration after the first re-tests byte-identical offsets and
/// contributes nothing but propagation. It did: nine of the coarsest level's
/// ten iterations were dead, and the coarsest level is the one `patchmatch`'s
/// doc calls the decider of the whole fill's structure.
///
/// Nothing about that is visible in the API, so the guard is the quality it
/// buys, over enough seeds that one lucky draw cannot carry it: mean absolute
/// reconstruction error against the untouched original, four seeds, a 200 px
/// hole in a structured non-periodic field. Measured 6.85 with the dead
/// iterations and 4.99 with them alive, so the bound below sits between the
/// two with a fifth of the distance in hand on either side — and it is
/// deterministic, since the seeds are fixed.
#[test]
fn every_em_iteration_searches_afresh() {
    let side = 800u32;
    let hole = 200u32;
    let doc = doc_of(side, side, plasma);
    let original = layer_bytes(&doc, 0);
    let x0 = (side - hole) / 2;
    let mask = mask_of(side, side, |x, y| {
        (x0..x0 + hole).contains(&x) && (x0..x0 + hole).contains(&y)
    });
    let broken = punch(&doc, &mask, [255, 255, 255]);
    let mut total = 0f64;
    for seed in 1..=4u64 {
        let bytes = layer_bytes(&filled(&broken, &mask, (side, side), seed), 0);
        let mut sum = 0f64;
        let mut count = 0u64;
        for (i, v) in mask.iter().enumerate() {
            if *v < 128 {
                continue;
            }
            for c in 0..3 {
                sum += (f64::from(bytes[i * 4 + c]) - f64::from(original[i * 4 + c])).abs();
                count += 1;
            }
        }
        total += sum / count as f64;
    }
    let mean = total / 4.0;
    println!("mean reconstruction error over four seeds: {mean:.2} code values");
    assert!(
        mean < 6.0,
        "the random search is not exploring: {mean:.2} code values of mean error"
    );
}
