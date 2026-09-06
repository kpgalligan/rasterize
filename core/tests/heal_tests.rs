//! Healing tests: `rz_doc_heal_layer` — the healing brush's Poisson
//! write-back — and the membrane solver behind it.
//!
//! Every document op runs through the FFI entry point on documents built
//! from the safe constructors, on the `doc_retouch.rs` model. The solver's
//! oracles are the closed-form answers of the published worked examples
//! (Pérez et al.'s guided interpolation, solved in exact rationals) plus an
//! independently written f64 red-black SOR reference for the measured
//! accuracy table — never a golden image. Shared fixtures live in
//! `tests/common`.

use std::ffi::c_char;
use std::ptr;
use std::time::Instant;

use image::{Rgba, RgbaImage};
use rasterize_core::doc::RzDocument;
use rasterize_core::doc_heal::{heal_window_into_layer, MAX_SOLVE_WINDOW_PIXELS};
use rasterize_core::ffi_doc::rz_doc_free;
use rasterize_core::ffi_heal::rz_doc_heal_layer;
use rasterize_core::poisson::{solve_membrane, sweep_budget, Region};

mod common;
use common::*;

// ------------------------------------------------------------- plumbing --

/// Runs the op through its FFI entry point on a copy of `doc`: the new
/// document (NULL = a refusal) and the error message, if any.
fn heal(
    doc: &RzDocument,
    idx: usize,
    overlay: &[u8],
    (w, h): (u32, u32),
    strength: f32,
) -> (Option<RzDocument>, Option<String>) {
    let handle = Box::into_raw(Box::new(doc.clone()));
    let mut err: *mut c_char = ptr::null_mut();
    let out = unsafe { rz_doc_heal_layer(handle, idx, overlay.as_ptr(), w, h, strength, &mut err) };
    unsafe { rz_doc_free(handle) };
    let message = if err.is_null() {
        None
    } else {
        Some(take_err_string(err))
    };
    let healed = if out.is_null() {
        None
    } else {
        Some(*unsafe { Box::from_raw(out) })
    };
    (healed, message)
}

/// [`heal`], asserting success and no message.
fn healed(doc: &RzDocument, overlay: &[u8], dims: (u32, u32), strength: f32) -> RzDocument {
    let (out, message) = heal(doc, 0, overlay, dims, strength);
    assert!(message.is_none(), "unexpected message: {message:?}");
    out.expect("heal_layer must succeed")
}

/// The layer's own pixel bytes, read back through the FFI.
fn layer_bytes(doc: &RzDocument, idx: usize) -> Vec<u8> {
    let handle = Box::into_raw(Box::new(doc.clone()));
    let out = layer_pixels(handle, idx);
    unsafe { rz_doc_free(handle) };
    out
}

/// A single-layer document whose pixels come from `f`.
fn doc_of(w: u32, h: u32, f: impl Fn(u32, u32) -> [u8; 4]) -> RzDocument {
    RzDocument::from_pixels(RgbaImage::from_fn(w, h, |x, y| Rgba(f(x, y))))
}

/// Canvas-sized PREMULTIPLIED overlay: `f` yields the STRAIGHT source RGB
/// and the coverage alpha at each canvas pixel, and this premultiplies —
/// exactly what a CoreGraphics-drawn clone footprint hands the core.
fn overlay(w: u32, h: u32, f: impl Fn(u32, u32) -> ([u8; 3], u8)) -> Vec<u8> {
    let mut out = vec![0u8; (w as usize) * (h as usize) * 4];
    for y in 0..h {
        for x in 0..w {
            let (rgb, a) = f(x, y);
            let i = ((y as usize) * (w as usize) + x as usize) * 4;
            for (c, v) in rgb.iter().enumerate() {
                out[i + c] = (f32::from(*v) * f32::from(a) / 255.0 + 0.5).floor() as u8;
            }
            out[i + 3] = a;
        }
    }
    out
}

/// A grey opaque pixel.
fn grey(v: u8) -> [u8; 4] {
    [v, v, v, 255]
}

/// A textured source: healing a FLAT destination from a FLAT source changes
/// nothing (the correction is the constant mismatch and `f` lands back on
/// the destination), so every fixture that must actually move a pixel gives
/// its source a texture for the heal to carry over.
fn textured(base: u8, x: u32, y: u32) -> [u8; 3] {
    let v = base + 24 * ((x + y) % 2) as u8;
    [v, v, v]
}

fn at(buf: &[u8], w: u32, x: u32, y: u32) -> [u8; 4] {
    pixel(buf, w, x, y)
}

// --------------------------------------------------- the worked examples --

/// The end-to-end worked example (Pérez §2's correction form, solved in
/// exact rationals): a 5x5 footprint whose destination is a pure
/// illumination ramp `f* = 60 + 20x` and whose source is a flat 100 with a
/// +-8 checker. The footprint's outline is the Dirichlet boundary, so it
/// keeps the destination; the inner 3x3 must come out byte-exact.
///
/// The checker amplitude is 8 and not 10 deliberately: at 10 the exact
/// answers land on .5 ties and the byte assertions would be hostage to the
/// solver's last ulp.
#[test]
fn worked_example_lands_byte_exact() {
    // Canvas 7x7 so the 5x5 footprint at (1, 1) has a ring of uncovered
    // destination around it; local coordinates are canvas - 1.
    let doc = doc_of(7, 7, |x, _| grey((40 + 20 * x) as u8));
    let src = overlay(7, 7, |x, y| {
        if (1..=5).contains(&x) && (1..=5).contains(&y) {
            let v = 100 + 8 * ((x + y) % 2) as u8;
            ([v, v, v], 255)
        } else {
            ([0, 0, 0], 0)
        }
    });
    let out = healed(&doc, &src, (7, 7), 1.0);
    let bytes = layer_bytes(&out, 0);
    let expected = [[74u8, 104, 114], [84, 96, 124], [74, 104, 114]];
    for y in 0..7u32 {
        for x in 0..7u32 {
            let want = if (2..=4).contains(&x) && (2..=4).contains(&y) {
                expected[(y - 2) as usize][(x - 2) as usize]
            } else {
                // Everything else — the footprint's outline included — is
                // the destination: on the boundary f = g + (f* - g) = f*.
                (40 + 20 * x) as u8
            };
            assert_eq!(
                at(&bytes, 7, x, y),
                [want, want, want, 255],
                "pixel ({x}, {y})"
            );
        }
    }
}

/// The mean-value example, straight against the solver: a 5x5 covered block
/// whose boundary carries 100 on its top edge and 0 on the other three. The
/// centre unknown is exactly 100/4 = 25 by the four-fold symmetry, and the
/// whole 3x3 is published in exact rationals. This pins the stencil, the
/// per-pixel divisor and the corner rule (the four ring corners are
/// 4-adjacent to no unknown and must contribute nothing) in one test.
#[test]
fn mean_value_matches_the_exact_rationals() {
    let (w, h) = (7usize, 7usize);
    let covered: Vec<bool> = (0..w * h)
        .map(|i| {
            let (x, y) = (i % w, i / w);
            (1..=5).contains(&x) && (1..=5).contains(&y)
        })
        .collect();
    let usable = vec![true; w * h];
    let b: Vec<f32> = (0..w * h)
        .map(|i| if i / w == 1 { 100.0 } else { 0.0 })
        .collect();
    let mut u = vec![0f32; w * h];
    let solved = solve_membrane(
        &Region {
            w,
            h,
            covered: &covered,
            usable: &usable,
        },
        &b,
        5,
        &mut u,
    );
    assert_eq!(solved, 9, "the inner 3x3 are the unknowns");
    let expected = [
        [300.0 / 7.0, 1475.0 / 28.0, 300.0 / 7.0],
        [75.0 / 4.0, 25.0, 75.0 / 4.0],
        [50.0 / 7.0, 275.0 / 28.0, 50.0 / 7.0],
    ];
    for y in 0..3 {
        for x in 0..3 {
            let got = u[(y + 2) * w + (x + 2)];
            assert!(
                (f64::from(got) - expected[y][x]).abs() < 1e-3,
                "u({x}, {y}) = {got}, want {}",
                expected[y][x]
            );
        }
    }
}

/// A linear gradient healed from a DIFFERENT linear ramp comes back
/// byte-exact: `b = f* - g` is then affine, the discrete Laplacian
/// annihilates affine functions exactly, so the correction reproduces the
/// destination to the last code value.
///
/// This only holds for a footprint that is full coverage (alpha 255) with an
/// integer-aligned outline: `b` is read on the contour from the
/// un-premultiplied overlay, and at the alpha = 128 contour of a
/// CoreGraphics-antialiased footprint that un-premultiply is worth up to
/// +-1 code, which the maximum principle then carries across the patch.
#[test]
fn linear_gradient_heals_byte_exact() {
    let ramp = |x: u32| (4 * x + 20) as u8;
    // The destination is the ramp with a black square gouged out of it,
    // strictly inside the footprint so the contour reads clean data.
    let doc = doc_of(40, 40, |x, y| {
        if (14..26).contains(&x) && (14..26).contains(&y) {
            [0, 0, 0, 255]
        } else {
            grey(ramp(x))
        }
    });
    let src = overlay(40, 40, |x, y| {
        if (12..28).contains(&x) && (12..28).contains(&y) {
            let v = (2 * x + 60) as u8;
            ([v, v, v], 255)
        } else {
            ([0, 0, 0], 0)
        }
    });
    let out = healed(&doc, &src, (40, 40), 1.0);
    let bytes = layer_bytes(&out, 0);
    for y in 0..40u32 {
        for x in 0..40u32 {
            assert_eq!(
                at(&bytes, 40, x, y),
                [ramp(x), ramp(x), ramp(x), 255],
                "pixel ({x}, {y})"
            );
        }
    }
}

/// A source identical to the destination is a no-op: the correction is
/// identically zero, every byte lands where it was, and the export refuses
/// rather than minting a copy that would register a phantom undo step.
#[test]
fn identical_source_is_a_no_op() {
    let doc = doc_of(24, 24, |x, y| [(x * 9) as u8, (y * 7) as u8, 90, 255]);
    let bytes = layer_bytes(&doc, 0);
    let src = overlay(24, 24, |x, y| {
        let p = at(&bytes, 24, x, y);
        let inside = (6..18).contains(&x) && (6..18).contains(&y);
        ([p[0], p[1], p[2]], if inside { 255 } else { 0 })
    });
    let (out, message) = heal(&doc, 0, &src, (24, 24), 1.0);
    assert!(out.is_none(), "an identical source must refuse");
    assert!(message.is_none(), "a refusal carries no message");
}

/// Every solved correction lies within the range of its component's
/// boundary data — the discrete maximum principle. Catches sign errors,
/// wrong divisors and mask leaks in one assertion.
#[test]
fn corrections_obey_the_maximum_principle() {
    let (w, h) = (41usize, 41usize);
    let disc = |x: usize, y: usize| {
        let (dx, dy) = (x as f32 - 20.0, y as f32 - 20.0);
        dx * dx + dy * dy <= 17.0 * 17.0
    };
    let covered: Vec<bool> = (0..w * h).map(|i| disc(i % w, i / w)).collect();
    let usable = vec![true; w * h];
    // Deliberately jagged boundary data, in [-70, 110].
    let b: Vec<f32> = (0..w * h)
        .map(|i| {
            let (x, y) = (i % w, i / w);
            if (x / 5 + y / 3) % 2 == 0 {
                110.0
            } else {
                -70.0
            }
        })
        .collect();
    let mut u = vec![0f32; w * h];
    let solved = solve_membrane(
        &Region {
            w,
            h,
            covered: &covered,
            usable: &usable,
        },
        &b,
        41,
        &mut u,
    );
    assert!(
        solved > 500,
        "the disc's interior must be unknown: {solved}"
    );
    for (i, value) in u.iter().enumerate() {
        assert!(value.is_finite(), "u[{i}] is not finite");
        assert!(
            (-70.0..=110.0).contains(value),
            "u[{i}] = {value} escapes the boundary range"
        );
    }
}

// -------------------------------------------------- the write-back rules --

/// A soft-edged dab leaves its rim byte-identical to the destination. The
/// write weight is a hard cut at the alpha = 128 contour, so a rim at
/// alpha 60 is not written at all — weighting it by the overlay's own alpha
/// would blend in the UNCORRECTED clone (the solver leaves u = 0 outside the
/// covered set), which is exactly the illumination mismatch the op exists to
/// remove, as a fringe around every stroke.
#[test]
fn a_soft_rim_is_never_written() {
    let doc = doc_of(21, 21, |_, _| grey(60));
    // A large mismatch: an uncorrected clone would be obvious.
    let src = overlay(21, 21, |x, y| {
        let (dx, dy) = (x as i32 - 10, y as i32 - 10);
        let r2 = dx * dx + dy * dy;
        let alpha = if r2 <= 36 {
            255
        } else if r2 <= 64 {
            60
        } else {
            0
        };
        (textured(180, x, y), alpha)
    });
    let out = healed(&doc, &src, (21, 21), 1.0);
    let bytes = layer_bytes(&out, 0);
    for y in 0..21u32 {
        for x in 0..21u32 {
            let (dx, dy) = (x as i32 - 10, y as i32 - 10);
            let r2 = dx * dx + dy * dy;
            if r2 > 36 {
                assert_eq!(
                    at(&bytes, 21, x, y),
                    grey(60),
                    "rim pixel ({x}, {y}) must be untouched"
                );
            }
        }
    }
}

/// An overlay whose maximum alpha is 127 covers nothing and refuses. This is
/// why the canvas forces Flow to 1 for the healing brushes: flow multiplies
/// every dab's alpha, so at flow <= 0.5 a click would deposit alpha < 128
/// everywhere and the tool would look broken. Strength lives in Opacity,
/// which is this op's `strength`.
#[test]
fn coverage_below_the_threshold_refuses() {
    let doc = doc_of(16, 16, |_, _| grey(60));
    let faint = overlay(16, 16, |x, y| {
        let inside = (4..12).contains(&x) && (4..12).contains(&y);
        (textured(180, x, y), if inside { 127 } else { 0 })
    });
    let (out, message) = heal(&doc, 0, &faint, (16, 16), 1.0);
    assert!(out.is_none(), "alpha 127 is not covered");
    assert!(message.is_none());

    let full = overlay(16, 16, |x, y| {
        let inside = (4..12).contains(&x) && (4..12).contains(&y);
        (textured(180, x, y), if inside { 255 } else { 0 })
    });
    let (out, _) = heal(&doc, 0, &full, (16, 16), 1.0);
    assert!(out.is_some(), "the same footprint at full alpha must heal");
}

/// `strength` scales the write-back: at 0.5 a pixel moves half way from the
/// destination to the healed value, and at 0 nothing moves at all.
#[test]
fn strength_scales_the_write_back() {
    let doc = doc_of(21, 21, |x, _| grey((60 + 2 * x) as u8));
    let src = overlay(21, 21, |x, y| {
        let inside = (5..16).contains(&x) && (5..16).contains(&y);
        // The source carries a checker the destination lacks, so the heal
        // has something to deposit.
        (textured(150, x, y), if inside { 255 } else { 0 })
    });
    let bytes = layer_bytes(&doc, 0);
    let full = layer_bytes(&healed(&doc, &src, (21, 21), 1.0), 0);
    let half = layer_bytes(&healed(&doc, &src, (21, 21), 0.5), 0);
    for y in 6..15u32 {
        for x in 6..15u32 {
            let base = f32::from(at(&bytes, 21, x, y)[0]);
            let want = base + 0.5 * (f32::from(at(&full, 21, x, y)[0]) - base);
            let got = f32::from(at(&half, 21, x, y)[0]);
            assert!((got - want).abs() <= 1.0, "({x}, {y}): {got} vs {want}");
        }
    }
    let (none, _) = heal(&doc, 0, &src, (21, 21), 0.0);
    assert!(none.is_none(), "strength 0 changes nothing");
}

/// The seam's write weight is subordinate to its region: a `write` plane
/// that covers the whole window still writes nothing where the region is
/// uncovered, so no pixel can receive an unsolved source.
#[test]
fn the_seam_never_writes_outside_its_region() {
    let ramp = |x: usize| (60 + 4 * x) as u8;
    let doc = doc_of(11, 11, |x, y| {
        if (4..7).contains(&x) && (4..7).contains(&y) {
            [0, 0, 0, 255]
        } else {
            grey(ramp(x as usize))
        }
    });
    let n = 11 * 11;
    let source = vec![160u8; n * 3];
    let region: Vec<u8> = (0..n)
        .map(|i| {
            let (x, y) = (i % 11, i / 11);
            if (2..9).contains(&x) && (2..9).contains(&y) {
                255
            } else {
                0
            }
        })
        .collect();
    let write = vec![255u8; n];
    let out = heal_window_into_layer(&doc, 0, (0, 0, 11, 11), &source, &region, &write, 1.0)
        .expect("no cap")
        .expect("the gouged square must change");
    let bytes = layer_bytes(&out, 0);
    for y in 0..11u32 {
        for x in 0..11u32 {
            // Everywhere — inside the region the affine correction restores
            // the ramp exactly, outside it the write weight is zero.
            assert_eq!(
                at(&bytes, 11, x, y),
                grey(ramp(x as usize)),
                "pixel ({x}, {y})"
            );
        }
    }
}

// ------------------------------------------------- geometry and topology --

/// A footprint touching the canvas edge floats there instead of being
/// pinned. An off-canvas neighbour is SKIPPED — it reduces the divisor, a
/// zero-flux edge — so the edge row relaxes toward the interior solution.
/// Under the rejected rule (treat the missing neighbour as Dirichlet data)
/// the edge row would be pinned to its own b of 0 and the heal would grow a
/// dark rim exactly along the canvas edge.
#[test]
fn the_canvas_edge_is_zero_flux_not_dirichlet() {
    // Destination 100 everywhere but the footprint's bottom contour row,
    // which is 120: b is 0 on the left/right contour columns and on the
    // covered top row, 20 along the bottom.
    let doc = doc_of(20, 20, |_, y| if y == 7 { grey(120) } else { grey(100) });
    let src = overlay(20, 20, |x, y| {
        let inside = (4..16).contains(&x) && y < 8;
        ([100, 100, 100], if inside { 255 } else { 0 })
    });
    let out = healed(&doc, &src, (20, 20), 1.0);
    let bytes = layer_bytes(&out, 0);
    let top = f32::from(at(&bytes, 20, 10, 0)[0]);
    let next = f32::from(at(&bytes, 20, 10, 1)[0]);
    assert!(
        top > 101.0,
        "the canvas-edge row must float toward the interior, got {top}"
    );
    assert!(
        (top - next).abs() <= 1.0,
        "zero flux means no step at the edge: {top} vs {next}"
    );
    for x in 5..15u32 {
        assert!(
            f32::from(at(&bytes, 20, x, 0)[0]) >= 100.0,
            "no dark rim at x = {x}"
        );
    }
}

/// Layer alpha is never touched, and a fully transparent destination pixel
/// inside the footprint is left exactly as it was — its RGB is latent
/// garbage, not colour, so it is neither solved nor written.
#[test]
fn alpha_and_transparent_pixels_survive() {
    let doc = doc_of(17, 17, |x, y| {
        if x == 8 && y == 8 {
            [7, 9, 11, 0]
        } else {
            [60, 70, 80, if y % 3 == 0 { 200 } else { 255 }]
        }
    });
    let before = layer_bytes(&doc, 0);
    let src = overlay(17, 17, |x, y| {
        let inside = (4..13).contains(&x) && (4..13).contains(&y);
        (
            [
                textured(150, x, y)[0],
                textured(120, x, y)[0],
                textured(90, x, y)[0],
            ],
            if inside { 255 } else { 0 },
        )
    });
    let out = healed(&doc, &src, (17, 17), 1.0);
    let after = layer_bytes(&out, 0);
    assert_eq!(
        at(&after, 17, 8, 8),
        [7, 9, 11, 0],
        "a transparent pixel is untouched, colour bytes included"
    );
    for i in 0..17 * 17 {
        assert_eq!(
            before[i * 4 + 3],
            after[i * 4 + 3],
            "alpha moved at index {i}"
        );
    }
}

/// The same heal on a layer at a non-zero offset lands on the same LAYER
/// pixels: the overlay is canvas-framed and mapped through the offset, and
/// overlay outside the layer's extent is ignored.
#[test]
fn a_layer_offset_maps_the_overlay() {
    let pixels = |x: u32, y: u32| [(20 + 6 * x) as u8, (30 + 5 * y) as u8, 90, 255];
    let flat = doc_of(12, 12, pixels);
    let src = overlay(12, 12, |x, y| {
        let inside = (3..9).contains(&x) && (3..9).contains(&y);
        (
            [
                textured(150, x, y)[0],
                textured(40, x, y)[0],
                textured(120, x, y)[0],
            ],
            if inside { 255 } else { 0 },
        )
    });
    let flat_out = layer_bytes(&healed(&flat, &src, (12, 12), 1.0), 0);

    let base = RzDocument::from_pixels(RgbaImage::from_pixel(20, 20, Rgba([0, 0, 0, 0])));
    let shifted = base
        .adding_image_layer(
            0,
            RgbaImage::from_fn(12, 12, |x, y| Rgba(pixels(x, y))),
            "L",
        )
        .and_then(|d| d.with_layer_offset(1, 3, 2))
        .expect("layer at an offset");
    let shifted_src = overlay(20, 20, |x, y| {
        let inside = (6..12).contains(&x) && (5..11).contains(&y);
        (
            [
                textured(150, x - 3, y - 2)[0],
                textured(40, x - 3, y - 2)[0],
                textured(120, x - 3, y - 2)[0],
            ],
            if inside { 255 } else { 0 },
        )
    });
    let (out, message) = heal(&shifted, 1, &shifted_src, (20, 20), 1.0);
    assert!(message.is_none());
    let shifted_out = layer_bytes(&out.expect("offset heal"), 1);
    assert_eq!(
        flat_out, shifted_out,
        "the offset heal must match the flat one"
    );
}

/// An isolated opaque island in a transparent sea is INERT: every candidate
/// has divisor 0, there is no neighbourhood to match, and the documented
/// answer is the plain clone. No NaN, no black pixel.
#[test]
fn an_isolated_opaque_pixel_heals_as_a_plain_clone() {
    let doc = doc_of(9, 9, |x, y| {
        if x == 4 && y == 4 {
            [30, 40, 50, 255]
        } else {
            [0, 0, 0, 0]
        }
    });
    let src = overlay(9, 9, |x, y| {
        let inside = (2..7).contains(&x) && (2..7).contains(&y);
        ([170, 120, 200], if inside { 255 } else { 0 })
    });
    let out = healed(&doc, &src, (9, 9), 1.0);
    let bytes = layer_bytes(&out, 0);
    assert_eq!(at(&bytes, 9, 4, 4), [170, 120, 200, 255]);
    for i in 0..9 * 9 {
        if i != 4 * 9 + 4 {
            assert_eq!(&bytes[i * 4..i * 4 + 4], &[0, 0, 0, 0], "pixel {i}");
        }
    }
}

/// A covered set that fills the layer has no Dirichlet boundary anywhere: a
/// pure-Neumann system, whose only harmonic solutions are constants. The
/// documented gauge is `mean(dest - source)` over the component, so the
/// result is the source shifted by that mean — never the raw source (which
/// zero, the iteration's other fixed point, would have committed).
#[test]
fn a_boundary_free_component_takes_the_constant_gauge() {
    // b is 40 on half the pixels and 48 on the other half: mean 44 exactly.
    let doc = doc_of(8, 8, |x, y| grey(100 + 8 * ((x + y) % 2) as u8));
    let src = overlay(8, 8, |_, _| ([60, 60, 60], 255));
    let out = healed(&doc, &src, (8, 8), 1.0);
    let bytes = layer_bytes(&out, 0);
    for y in 0..8u32 {
        for x in 0..8u32 {
            assert_eq!(at(&bytes, 8, x, y), grey(104), "pixel ({x}, {y})");
        }
    }
}

/// Disjoint blobs are separate components, each solved in its own window
/// from its own neighbourhood — a blob does not inherit the illumination of
/// a distant one.
#[test]
fn components_are_solved_independently() {
    // Two flat fields far apart, each with its own gouged centre.
    let doc = doc_of(60, 20, |x, y| {
        let base = if x < 30 { 80 } else { 200 };
        if ((10..14).contains(&x) || (46..50).contains(&x)) && (8..12).contains(&y) {
            grey(0)
        } else {
            grey(base)
        }
    });
    let src = overlay(60, 20, |x, y| {
        let inside = ((8..16).contains(&x) || (44..52).contains(&x)) && (6..14).contains(&y);
        ([130, 130, 130], if inside { 255 } else { 0 })
    });
    let out = healed(&doc, &src, (60, 20), 1.0);
    let bytes = layer_bytes(&out, 0);
    assert_eq!(at(&bytes, 60, 12, 10), grey(80), "left blob takes 80");
    assert_eq!(at(&bytes, 60, 48, 10), grey(200), "right blob takes 200");
}

// ------------------------------------------------------------- refusals --

#[test]
fn refusals_are_null_without_a_message() {
    let doc = doc_of(12, 12, |_, _| grey(120));
    let src = overlay(12, 12, |x, y| {
        let inside = (3..9).contains(&x) && (3..9).contains(&y);
        ([200, 60, 60], if inside { 255 } else { 0 })
    });
    for (what, (out, message)) in [
        ("bad index", heal(&doc, 9, &src, (12, 12), 1.0)),
        ("wrong dimensions", heal(&doc, 0, &src, (11, 12), 1.0)),
        (
            "non-finite strength",
            heal(&doc, 0, &src, (12, 12), f32::NAN),
        ),
        (
            "empty coverage",
            heal(
                &doc,
                0,
                &overlay(12, 12, |_, _| ([9, 9, 9], 0)),
                (12, 12),
                1.0,
            ),
        ),
        (
            // A one-pixel-wide covered line has no interior: every covered
            // pixel is on the join contour, where the heal IS the
            // destination, so no byte moves.
            "a covered line with no interior",
            heal(
                &doc,
                0,
                &overlay(12, 12, |x, y| {
                    (
                        [200, 60, 60],
                        if y == 6 && (2..10).contains(&x) {
                            255
                        } else {
                            0
                        },
                    )
                }),
                (12, 12),
                1.0,
            ),
        ),
    ] {
        assert!(out.is_none(), "{what} must refuse");
        assert!(message.is_none(), "{what} must carry no message");
    }

    // A layer whose extent misses the canvas entirely.
    let base = RzDocument::from_pixels(RgbaImage::from_pixel(12, 12, Rgba([0, 0, 0, 0])));
    let away = base
        .adding_image_layer(0, RgbaImage::from_pixel(4, 4, Rgba([9, 9, 9, 255])), "L")
        .and_then(|d| d.with_layer_offset(1, 100, 100))
        .expect("layer off-canvas");
    let (out, message) = heal(&away, 1, &src, (12, 12), 1.0);
    assert!(out.is_none(), "an off-canvas layer must refuse");
    assert!(message.is_none());

    // A NULL overlay is refused before anything is read.
    let handle = Box::into_raw(Box::new(doc.clone()));
    let mut err: *mut c_char = ptr::null_mut();
    let out = unsafe { rz_doc_heal_layer(handle, 0, ptr::null(), 12, 12, 1.0, &mut err) };
    unsafe { rz_doc_free(handle) };
    assert!(out.is_null() && err.is_null());
}

/// One component's box over the memory limit refuses WITH a message that
/// names the limit and says what to do about it.
#[test]
fn an_oversized_component_refuses_with_a_message() {
    // The window is the component's box padded by 1 and clamped to the
    // canvas, so exceeding a 32-megapixel bound needs a canvas larger than
    // that: an L-shaped footprint whose box is the whole canvas.
    let (w, h) = (33_000u32, 1_000u32);
    let doc = RzDocument::from_pixels(RgbaImage::from_pixel(w, h, Rgba([120, 120, 120, 255])));
    let src = overlay(w, h, |x, y| {
        let inside = y == 0 || x == 0;
        ([200, 60, 60], if inside { 255 } else { 0 })
    });
    let (out, message) = heal(&doc, 0, &src, (w, h), 1.0);
    assert!(out.is_none(), "over the memory limit must refuse");
    let message = message.expect("a memory refusal carries a message");
    assert!(
        message.contains("33000 x 1000") && message.contains("32 megapixels"),
        "the message must name the box and the limit: {message}"
    );
    assert!(
        u64::from(w) * u64::from(h) > MAX_SOLVE_WINDOW_PIXELS,
        "the fixture must actually exceed the documented cap"
    );
}

#[test]
fn null_safety() {
    let doc = doc_of(4, 4, |_, _| grey(10));
    let src = overlay(4, 4, |_, _| ([1, 2, 3], 255));
    unsafe {
        let mut err: *mut c_char = ptr::null_mut();
        assert!(rz_doc_heal_layer(ptr::null(), 0, src.as_ptr(), 4, 4, 1.0, &mut err).is_null());
        assert!(err.is_null(), "a NULL document is a refusal, not an error");
        assert!(
            rz_doc_heal_layer(ptr::null(), 0, src.as_ptr(), 4, 4, 1.0, ptr::null_mut()).is_null()
        );
        let handle = Box::into_raw(Box::new(doc.clone()));
        assert!(rz_doc_heal_layer(handle, 0, ptr::null(), 4, 4, 1.0, ptr::null_mut()).is_null());
        rz_doc_free(handle);
    }
}

// ------------------------------------------------- the cost of the solve --

/// The schedule's work budget is a constant times the UNKNOWN count and
/// never a function of the region's diameter. A square, a long thin strip, a
/// disc and an L with comparable unknown counts must all be budgeted the
/// same way — this is the regression guard against reintroducing a sweep
/// count that grows with the geometry (which is what made the solve cubic
/// before the schedule was fixed).
///
/// The budget quotes the CEILING the residual-driven loop may spend, which is
/// what a cost bound has to say; the scheduled cycles are a quarter of it and
/// every geometry measured lands between the two.
#[test]
fn the_work_budget_is_linear_in_the_unknowns() {
    let solve = |w: usize, h: usize, inside: &dyn Fn(usize, usize) -> bool| -> usize {
        let covered: Vec<bool> = (0..w * h).map(|i| inside(i % w, i / w)).collect();
        let usable = vec![true; w * h];
        let b = vec![25.0f32; w * h];
        let mut u = vec![0f32; w * h];
        solve_membrane(
            &Region {
                w,
                h,
                covered: &covered,
                usable: &usable,
            },
            &b,
            w.max(h),
            &mut u,
        )
    };
    let cases: [(&str, usize); 4] = [
        (
            "square",
            solve(60, 60, &|x, y| (2..58).contains(&x) && (2..58).contains(&y)),
        ),
        (
            "strip",
            solve(900, 12, &|x, y| {
                (2..898).contains(&x) && (2..10).contains(&y)
            }),
        ),
        (
            "disc",
            solve(120, 120, &|x, y| {
                let (dx, dy) = (x as f32 - 60.0, y as f32 - 60.0);
                dx * dx + dy * dy <= 50.0 * 50.0
            }),
        ),
        (
            "L",
            solve(200, 200, &|x, y| {
                ((2..40).contains(&x) && (2..198).contains(&y))
                    || ((2..198).contains(&x) && (160..198).contains(&y))
            }),
        ),
    ];
    for (name, unknowns) in cases {
        assert!(unknowns > 100, "{name} must have unknowns: {unknowns}");
        let budget = sweep_budget(unknowns);
        assert!(
            budget <= 112 * unknowns as u64 + 40_960,
            "{name}: {budget} updates for {unknowns} unknowns"
        );
    }
    // The budget is a function of the count alone: a 900x12 strip and a
    // 60x60 square with the same unknown count cost the same.
    assert!(sweep_budget(1_000_000) < 120_000_000);
}

/// Measures the shipped schedule against an independently written f64
/// red-black SOR reference on a square region whose boundary data carries
/// step discontinuities — the honest shape of `b = dest - source` where
/// texture edges cross the contour. The numbers this prints are the ones
/// recorded in `poisson.rs`'s module doc; the assertions are deliberately
/// loose so they cannot go flaky under `cargo test --release`'s parallelism.
#[test]
fn measured_accuracy_against_an_f64_reference() {
    let n = 300usize;
    let (elapsed, ours, reference) = solve_square(n);
    let mut worst = [0f64; 3];
    for y in 0..n {
        for x in 0..n {
            let edge = (x + 1).min(y + 1).min(n - x).min(n - y);
            let bucket = match edge {
                0..=2 => 0,
                3..=10 => 1,
                _ => 2,
            };
            let error = (ours[y * n + x] - reference[y * n + x]).abs();
            worst[bucket] = worst[bucket].max(error);
        }
    }
    println!(
        "poisson n={n}: {} unknowns, {:?} per channel, seam {:.4}, 3-10px {:.4}, interior {:.4}",
        n * n,
        elapsed,
        worst[0],
        worst[1],
        worst[2]
    );
    // Two orders below the byte quantization step, with room for a slower
    // machine or a future smoother: the numbers measured here are 0.0009 /
    // 0.0038 / 0.0052.
    assert!(worst[0] < 0.05, "seam error {:.4} code values", worst[0]);
    assert!(worst[1] < 0.10, "near error {:.4} code values", worst[1]);
    assert!(
        worst[2] < 0.20,
        "interior error {:.4} code values",
        worst[2]
    );
}

/// The realistic large case: a 1000x1000 region (a million unknowns, the
/// size a patch-tool drag over a face reaches). Times one channel and
/// asserts only a generous bound — the printed number is what the module
/// doc records.
#[test]
fn measured_cost_of_a_million_unknowns() {
    let n = 1000usize;
    let start = Instant::now();
    let (elapsed, _, _) = solve_square_timed_only(n);
    println!(
        "poisson n={n}: {} unknowns, {:?} per channel ({:?} including setup)",
        n * n,
        elapsed,
        start.elapsed()
    );
    assert!(
        elapsed.as_secs_f64() < 3.0,
        "a million unknowns took {elapsed:?} for one channel"
    );
}

/// The shipped solve and the reference solve of an `n x n` unknown block,
/// plus the time the shipped one took. The covered set is the block grown
/// by one pixel, whose outline is the Dirichlet contour.
fn solve_square(n: usize) -> (std::time::Duration, Vec<f64>, Vec<f64>) {
    let (elapsed, ours) = shipped_square(n);
    let reference = reference_square(n, &boundary_value);
    (elapsed, ours, reference)
}

fn solve_square_timed_only(n: usize) -> (std::time::Duration, Vec<f64>, Vec<f64>) {
    let (elapsed, ours) = shipped_square(n);
    (elapsed, ours, Vec::new())
}

/// Boundary data on the contour of the square case: steps every ~15 px, so
/// the harmonic extension has a genuine boundary layer.
fn boundary_value(x: i64, y: i64) -> f64 {
    if (x.div_euclid(17) + y.div_euclid(13)).rem_euclid(2) == 0 {
        100.0
    } else {
        -60.0
    }
}

/// Runs the shipped solver on the square case, returning the interior
/// `n x n` correction as f64 and the wall time of the solve alone.
fn shipped_square(n: usize) -> (std::time::Duration, Vec<f64>) {
    let m = n + 4;
    let covered: Vec<bool> = (0..m * m)
        .map(|i| {
            let (x, y) = (i % m, i / m);
            (1..m - 1).contains(&x) && (1..m - 1).contains(&y)
        })
        .collect();
    let usable = vec![true; m * m];
    let b: Vec<f32> = (0..m * m)
        .map(|i| {
            let (x, y) = ((i % m) as i64, (i / m) as i64);
            boundary_value(x - 2, y - 2) as f32
        })
        .collect();
    let mut u = vec![0f32; m * m];
    let start = Instant::now();
    let solved = solve_membrane(
        &Region {
            w: m,
            h: m,
            covered: &covered,
            usable: &usable,
        },
        &b,
        m,
        &mut u,
    );
    let elapsed = start.elapsed();
    assert_eq!(solved, n * n, "the interior block must be the unknowns");
    let mut out = vec![0f64; n * n];
    for y in 0..n {
        for x in 0..n {
            out[y * n + x] = f64::from(u[(y + 2) * m + (x + 2)]);
        }
    }
    (elapsed, out)
}

/// The oracle: a flat f64 red-black SOR over the same discrete system,
/// written straight from Young's formulas (`rho_J = cos(pi/(n+1))`,
/// `omega = 2/(1 + sqrt(1 - rho_J^2))`) and run until the per-sweep delta
/// stops moving. It shares no code with `poisson`.
fn reference_square(n: usize, boundary: &dyn Fn(i64, i64) -> f64) -> Vec<f64> {
    let m = n + 2;
    let mut u = vec![0f64; m * m];
    for y in 0..m {
        for x in 0..m {
            if x == 0 || y == 0 || x == m - 1 || y == m - 1 {
                u[y * m + x] = boundary(x as i64 - 1, y as i64 - 1);
            }
        }
    }
    let rho = (std::f64::consts::PI / (n as f64 + 1.0)).cos();
    let omega = 2.0 / (1.0 + (1.0 - rho * rho).sqrt());
    for _ in 0..20 * n.max(8) {
        let mut delta = 0f64;
        for color in 0..2 {
            for y in 1..m - 1 {
                for x in 1..m - 1 {
                    if (x + y) % 2 != color {
                        continue;
                    }
                    let i = y * m + x;
                    let average = (u[i - 1] + u[i + 1] + u[i - m] + u[i + m]) * 0.25;
                    let next = u[i] + omega * (average - u[i]);
                    delta = delta.max((next - u[i]).abs());
                    u[i] = next;
                }
            }
        }
        if delta < 1e-9 {
            break;
        }
    }
    let mut out = vec![0f64; n * n];
    for y in 0..n {
        for x in 0..n {
            out[y * n + x] = u[(y + 1) * m + (x + 1)];
        }
    }
    out
}
/// The module doc's second table row, on demand. Ignored by default because
/// the f64 reference for a million unknowns takes ~6 s to converge — too
/// long to pay on every `make test` for a number that only changes when the
/// schedule does. Run it with `cargo test --release --test heal_tests --
/// --ignored` after touching `poisson.rs`, and update the table.
#[test]
#[ignore]
fn measured_accuracy_at_a_million_unknowns() {
    let n = 1000usize;
    let (elapsed, ours, reference) = solve_square(n);
    let mut worst = [0f64; 3];
    for y in 0..n {
        for x in 0..n {
            let edge = (x + 1).min(y + 1).min(n - x).min(n - y);
            let bucket = match edge {
                0..=2 => 0,
                3..=10 => 1,
                _ => 2,
            };
            let error = (ours[y * n + x] - reference[y * n + x]).abs();
            worst[bucket] = worst[bucket].max(error);
        }
    }
    println!(
        "poisson n={n}: {:?} per channel, seam {:.4}, 3-10px {:.4}, interior {:.4}",
        elapsed, worst[0], worst[1], worst[2]
    );
}

/// What a stroke commit actually costs on a realistic photo: a
/// 2000x1500 document, a brush dab, a bigger dab, and a patch-tool-sized
/// region. The whole op is timed — the canvas-sized coverage scan and the
/// component walk included, which is most of the bill for a small dab — and
/// the printed numbers are the ones `doc_heal`'s module doc records. The
/// assertion is deliberately loose so it cannot go flaky under
/// `cargo test --release`'s parallelism.
#[test]
fn measured_cost_of_a_stroke_commit() {
    let doc = doc_of(2000, 1500, |x, y| {
        [
            ((x * 7 + y * 3) % 256) as u8,
            ((x * 3 + y * 11) % 256) as u8,
            ((x + y) % 256) as u8,
            255,
        ]
    });
    for (label, radius) in [("dab r=20", 20i32), ("dab r=60", 60), ("patch r=170", 170)] {
        let (cx, cy) = (1000i32, 750i32);
        let src = overlay(2000, 1500, |x, y| {
            let (dx, dy) = (x as i32 - cx, y as i32 - cy);
            let inside = dx * dx + dy * dy <= radius * radius;
            (textured(150, x + 37, y + 11), if inside { 255 } else { 0 })
        });
        let covered = (std::f64::consts::PI * f64::from(radius * radius)) as u64;
        let start = Instant::now();
        let (out, message) = heal(&doc, 0, &src, (2000, 1500), 1.0);
        let elapsed = start.elapsed();
        assert!(message.is_none(), "{label}: {message:?}");
        assert!(out.is_some(), "{label} must heal");
        println!("{label}: ~{covered} covered px, whole op {elapsed:?}");
        assert!(
            elapsed.as_secs_f64() < 3.0,
            "{label} took {elapsed:?} on a 3 MP document"
        );
    }
}

// ------------------------------------- accuracy on every kind of geometry --

/// The accuracy claim held on ONE shape — a Dirichlet-dominated square — and
/// was false on the shapes whose contour is mostly the window's edge.
///
/// A region flush with the canvas edge is a nearly pure Neumann problem: the
/// only Dirichlet data is one inner contour, the operator's smallest
/// eigenvalue is tiny, and the fixed-scale coarse-grid correction the
/// V-cycle used to apply at step 1 DIVERGED there — measured, a 40 px frame
/// flush with all four edges of a 161 px window came out 53 code values from
/// the exact discrete solution, with 12 329 of its samples off by more than
/// 4. Every healing tool reaches this shape from an ordinary gesture:
/// magic-wand the black border of a scan and run Content-Aware Fill, or drag
/// the Patch tool around the border of the picture.
///
/// The oracle is a Jacobi-preconditioned conjugate gradient in f64, written
/// from the same classification rule and sharing no code with `poisson`,
/// converged until its own residual is below 1e-9 (asserted, so a failure to
/// converge cannot pass as agreement). The bound is a quarter of the byte
/// quantization step — the worst geometry measures 0.117 — and the numbers
/// printed are the ones recorded in `poisson.rs`'s table.
#[test]
fn the_accuracy_holds_on_every_geometry() {
    let side = 161usize;
    let t = 40usize;
    /// One geometry: its name and whether a window pixel is covered.
    type Case<'a> = (&'a str, &'a dyn Fn(usize, usize) -> bool);
    let cases: [Case; 6] = [
        // The control: a block well inside the window, all Dirichlet.
        ("block", &|x, y| {
            (40..120).contains(&x) && (40..120).contains(&y)
        }),
        ("disc", &|x, y| {
            let (dx, dy) = (x as f32 - 80.0, y as f32 - 80.0);
            dx * dx + dy * dy <= 55.0 * 55.0
        }),
        ("L", &|x, y| {
            ((20..60).contains(&x) && (20..140).contains(&y))
                || ((20..140).contains(&x) && (100..140).contains(&y))
        }),
        // Flush with one window edge: one zero-flux side.
        ("strip flush", &|x, _| x < t),
        // Flush with three: a U.
        ("U flush", &|x, y| x < t || y >= side - t || x >= side - t),
        // Flush with all four: the shape that diverged.
        ("frame flush", &|x, y| {
            x < t || y < t || x >= side - t || y >= side - t
        }),
    ];
    for (name, inside) in cases {
        let covered: Vec<bool> = (0..side * side)
            .map(|i| inside(i % side, i / side))
            .collect();
        let usable = vec![true; side * side];
        let b: Vec<f32> = (0..side * side)
            .map(|i| boundary_value((i % side) as i64, (i / side) as i64) as f32)
            .collect();
        let mut u = vec![0f32; side * side];
        let start = Instant::now();
        let solved = solve_membrane(
            &Region {
                w: side,
                h: side,
                covered: &covered,
                usable: &usable,
            },
            &b,
            side,
            &mut u,
        );
        let elapsed = start.elapsed();
        assert!(solved > 1000, "{name} must have unknowns: {solved}");
        let (reference, residual) = reference_region(&covered, &usable, &b, side, side);
        assert!(
            residual < 1e-9,
            "{name}: the oracle did not converge (residual {residual:.1e})"
        );
        let mut worst = 0f64;
        let mut off = 0u64;
        for i in 0..side * side {
            let Some(exact) = reference[i] else { continue };
            let error = (f64::from(u[i]) - exact).abs();
            worst = worst.max(error);
            if error > 1.0 {
                off += 1;
            }
        }
        println!("{name}: {solved} unknowns, {elapsed:?}, max error {worst:.4} code values");
        assert!(
            worst < 0.25 && off == 0,
            "{name}: {worst:.4} code values of error ({off} samples past a whole code value)"
        );
    }
}

/// The oracle for [`the_accuracy_holds_on_every_geometry`]: the same discrete
/// system solved in f64 by Jacobi-preconditioned conjugate gradient, written
/// straight from the classification rule stated on `poisson::Region` and
/// sharing no code with the solver under test. `None` at every pixel that is
/// not an unknown; the second return is the oracle's own max residual, so the
/// caller can prove it converged.
fn reference_region(
    covered: &[bool],
    usable: &[bool],
    b: &[f32],
    w: usize,
    h: usize,
) -> (Vec<Option<f64>>, f64) {
    // 0 = outside the system, 1 = Dirichlet boundary, 2 = unknown.
    let neighbors = |i: usize, x: usize, y: usize| -> [(bool, usize); 4] {
        [
            (x > 0, i.wrapping_sub(1)),
            (x + 1 < w, i + 1),
            (y > 0, i.wrapping_sub(w)),
            (y + 1 < h, i + w),
        ]
    };
    let mut kind = vec![0u8; w * h];
    for y in 0..h {
        for x in 0..w {
            let i = y * w + x;
            if !(covered[i] && usable[i]) {
                continue;
            }
            let (mut divisor, mut dirichlet) = (0u32, false);
            for (inside, q) in neighbors(i, x, y) {
                if !inside || !usable[q] {
                    continue;
                }
                divisor += 1;
                dirichlet |= !covered[q];
            }
            kind[i] = if divisor == 0 {
                0
            } else if dirichlet {
                1
            } else {
                2
            };
        }
    }
    // The divisor is the count of neighbours that are in the system at all —
    // an off-window or unusable neighbour reduces it (a zero-flux edge).
    let mut divisor = vec![0f64; w * h];
    for y in 0..h {
        for x in 0..w {
            let i = y * w + x;
            if kind[i] == 0 {
                continue;
            }
            divisor[i] = neighbors(i, x, y)
                .into_iter()
                .filter(|(inside, q)| *inside && kind[*q] != 0)
                .count() as f64;
        }
    }
    let unknowns: Vec<usize> = (0..w * h).filter(|i| kind[*i] == 2).collect();
    // A u over the unknown block; the boundary's own values are the RHS.
    let apply = |v: &[f64], out: &mut [f64]| {
        for &i in &unknowns {
            let (x, y) = (i % w, i / w);
            let sum: f64 = neighbors(i, x, y)
                .into_iter()
                .filter(|(inside, q)| *inside && kind[*q] == 2)
                .map(|(_, q)| v[q])
                .sum();
            out[i] = divisor[i] * v[i] - sum;
        }
    };
    let mut f = vec![0f64; w * h];
    for &i in &unknowns {
        let (x, y) = (i % w, i / w);
        f[i] = neighbors(i, x, y)
            .into_iter()
            .filter(|(inside, q)| *inside && kind[*q] == 1)
            .map(|(_, q)| f64::from(b[q]))
            .sum();
    }
    let mut u = vec![0f64; w * h];
    let mut r = f.clone();
    let mut z: Vec<f64> = (0..w * h)
        .map(|i| if kind[i] == 2 { r[i] / divisor[i] } else { 0.0 })
        .collect();
    let mut p = z.clone();
    let mut rz: f64 = unknowns.iter().map(|&i| r[i] * z[i]).sum();
    let mut ap = vec![0f64; w * h];
    for _ in 0..100_000 {
        apply(&p, &mut ap);
        let pap: f64 = unknowns.iter().map(|&i| p[i] * ap[i]).sum();
        if pap <= 0.0 {
            break;
        }
        let alpha = rz / pap;
        for &i in &unknowns {
            u[i] += alpha * p[i];
            r[i] -= alpha * ap[i];
        }
        if unknowns.iter().fold(0f64, |m, &i| m.max(r[i].abs())) < 1e-11 {
            break;
        }
        for &i in &unknowns {
            z[i] = r[i] / divisor[i];
        }
        let next: f64 = unknowns.iter().map(|&i| r[i] * z[i]).sum();
        let beta = next / rz;
        rz = next;
        for &i in &unknowns {
            p[i] = z[i] + beta * p[i];
        }
    }
    apply(&u, &mut ap);
    let residual = unknowns
        .iter()
        .fold(0f64, |m, &i| m.max((f[i] - ap[i]).abs()));
    let out = (0..w * h)
        .map(|i| if kind[i] == 2 { Some(u[i]) } else { None })
        .collect();
    (out, residual)
}

/// A call whose components' working boxes come to more than one call's worth
/// is refused with a sentence that names the limit — and refused before any
/// of it is healed.
///
/// `MAX_SOLVE_WINDOW_PIXELS` bounds ONE component's window, which is a
/// statement about memory and says nothing about how many components a call
/// has. Every component pays a full pass over its own window whatever it
/// covers, so a stroke that lands in many places with big boxes — the shape a
/// magic-wand selection of scratches or hairs makes, handed to the Patch tool
/// — cost `parts x window area` with nothing refusing: measured on a
/// 5000 x 4000 document, ten canvas-spanning three-pixel runs took 5.2 s and
/// forty took 20.2 s, on the caller's thread, which in the app is the main
/// one. The identical selection handed to `content_aware_fill` was refused in
/// milliseconds by its own plan cap.
#[test]
fn a_call_whose_windows_bust_their_budget_is_refused() {
    let (w, h) = (4000u32, 3000u32);
    let doc = doc_of(w, h, |x, y| grey(((x * 3 + y * 5) % 200) as u8 + 20));
    // Twenty disjoint diagonal bands, each five pixels thick and spanning the
    // canvas, so each is one 4-connected component with a box of most of the
    // picture: ~90 megapixels of window against the 80 MP limit, on a
    // selection whose covered count is a fraction of a megapixel.
    let band = |x: u32, y: u32, count: u32| -> bool {
        (0..count).any(|k| {
            let top = x + k * 100;
            y >= top && y < top + 5
        })
    };
    let src = overlay(w, h, |x, y| {
        (
            textured(150, x + 7, y + 3),
            if band(x, y, 20) { 255 } else { 0 },
        )
    });
    let start = Instant::now();
    let (out, message) = heal(&doc, 0, &src, (w, h), 1.0);
    let elapsed = start.elapsed();
    assert!(out.is_none(), "the windows must not fit one call's budget");
    let message = message.expect("the budget must speak");
    println!("twenty spanning bands: refused in {elapsed:?} — {message}");
    assert!(
        message.contains("80 megapixels") && message.contains("separate places"),
        "the refusal must name the limit and what busted it: {message}"
    );
    // A refusal costs the component walk and nothing else. The bound is
    // absolute and generous on purpose — a ratio against a real heal would go
    // flaky under `cargo test`'s parallelism, and this measures ~0.1 s.
    assert!(
        elapsed.as_secs_f64() < 5.0,
        "a refusal must not cost what a heal costs: {elapsed:?}"
    );
    // And one run on its own — an eighth of the budget — still heals.
    let one = overlay(w, h, |x, y| {
        (
            textured(150, x + 7, y + 3),
            if band(x, y, 1) { 255 } else { 0 },
        )
    });
    let (out, message) = heal(&doc, 0, &one, (w, h), 1.0);
    assert!(message.is_none(), "unexpected message: {message:?}");
    assert!(out.is_some(), "one band must heal");
}
