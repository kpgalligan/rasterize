//! Dodge/burn tests: `rz_doc_dodge_burn_layer` — the destructive retouch
//! brush. The oracle is an independently written scalar reference of the
//! documented curves; every application runs through the FFI on documents
//! built from the safe constructors. Shared fixtures live in `tests/common`.

use std::ptr;

use image::{Rgba, RgbaImage};
use rasterize_core::doc::RzDocument;
use rasterize_core::ffi_doc::*;

mod common;
use common::*;

/// Runs the op through its FFI entry point on a copy of `doc`, returning
/// the new document, or `None` when the call refuses.
fn dodge_burn(
    doc: &RzDocument,
    idx: usize,
    overlay: &[u8],
    (w, h): (u32, u32),
    exposure: f32,
    range: u8,
    burn: bool,
) -> Option<RzDocument> {
    let handle = Box::into_raw(Box::new(doc.clone()));
    let out = unsafe {
        rz_doc_dodge_burn_layer(handle, idx, overlay.as_ptr(), w, h, exposure, range, burn)
    };
    unsafe { rz_doc_free(handle) };
    if out.is_null() {
        None
    } else {
        Some(*unsafe { Box::from_raw(out) })
    }
}

/// [`dodge_burn`], asserting success.
fn applied(
    doc: &RzDocument,
    idx: usize,
    overlay: &[u8],
    dims: (u32, u32),
    exposure: f32,
    range: u8,
    burn: bool,
) -> RzDocument {
    dodge_burn(doc, idx, overlay, dims, exposure, range, burn)
        .expect("dodge_burn_layer must succeed")
}

/// Canvas-sized premultiplied overlay whose ALPHA is `f(x, y)`. The color
/// bytes are deliberate junk (varying, nonzero even where alpha is 0) so a
/// result that matches the alpha-only oracle proves the color channels are
/// never read.
fn overlay(w: u32, h: u32, f: impl Fn(u32, u32) -> u8) -> Vec<u8> {
    let mut out = Vec::with_capacity((w * h * 4) as usize);
    for y in 0..h {
        for x in 0..w {
            out.extend_from_slice(&[(x * 31 + 7) as u8, (y * 17 + 3) as u8, 99, f(x, y)]);
        }
    }
    out
}

/// Independent scalar reference for ONE channel, written straight from the
/// documented formulas: `v` and `coverage` are bytes, `exposure` clamps to
/// [0, 1] with `k = e/3`, `range` is 0 shadows / 1 midtones / 2 highlights.
fn reference(v: u8, coverage: u8, exposure: f32, range: u8, burn: bool) -> u8 {
    let e = exposure.clamp(0.0, 1.0);
    let k = e / 3.0;
    let vf = f32::from(v) / 255.0;
    let target = match (range, burn) {
        (0, false) => k + vf * (1.0 - k), // lift the black point
        (0, true) => ((vf - k) / (1.0 - k)).max(0.0), // crush the black point
        (1, false) => vf.powf(1.0 / (1.0 + e)), // gamma up
        (1, true) => vf.powf(1.0 + e),    // gamma down
        (2, false) => (vf / (1.0 - k)).min(1.0), // pull the white point in
        (2, true) => vf * (1.0 - k),      // push the white point down
        _ => panic!("bad range {range}"),
    };
    let c = f32::from(coverage) / 255.0;
    ((vf + c * (target - vf)) * 255.0 + 0.5).floor() as u8
}

/// 16x16 opaque gradient: R walks every byte value once, G the reverse
/// ramp, B a decorrelated pattern.
fn gradient_img() -> RgbaImage {
    RgbaImage::from_fn(16, 16, |x, y| {
        let i = y * 16 + x;
        Rgba([i as u8, (255 - i) as u8, ((i * 7 + 13) % 256) as u8, 255])
    })
}

// ---------------------------------------------------------------- tests --

#[test]
fn full_coverage_matches_the_scalar_reference_exactly() {
    let img = gradient_img();
    let doc = RzDocument::from_pixels(img.clone());
    let full = overlay(16, 16, |_, _| 255);
    for range in 0..=2u8 {
        for burn in [false, true] {
            let out = applied(&doc, 0, &full, (16, 16), 0.6, range, burn);
            let after = out.layers[0].pixels.as_raw();
            for (i, before) in img.as_raw().iter().enumerate() {
                let expect = if i % 4 == 3 {
                    *before // alpha is never touched
                } else {
                    reference(*before, 255, 0.6, range, burn)
                };
                assert_eq!(after[i], expect, "byte {i} (range {range}, burn {burn})");
            }
        }
    }
}

#[test]
fn half_coverage_matches_the_reference_and_lands_halfway() {
    let img = gradient_img();
    let doc = RzDocument::from_pixels(img.clone());
    let full = applied(
        &doc,
        0,
        &overlay(16, 16, |_, _| 255),
        (16, 16),
        1.0,
        1,
        false,
    );
    let half = applied(
        &doc,
        0,
        &overlay(16, 16, |_, _| 128),
        (16, 16),
        1.0,
        1,
        false,
    );
    let (full, half) = (
        full.layers[0].pixels.as_raw(),
        half.layers[0].pixels.as_raw(),
    );
    for (i, before) in img.as_raw().iter().enumerate() {
        if i % 4 == 3 {
            assert_eq!(half[i], 255, "alpha untouched at byte {i}");
            continue;
        }
        assert_eq!(
            half[i],
            reference(*before, 128, 1.0, 1, false),
            "byte {i} must match the coverage-128 reference"
        );
        // Coverage 128/255 is (near) half strength: within rounding of the
        // midpoint between the original and the full-coverage result.
        let midpoint = (i32::from(*before) + i32::from(full[i]) + 1) / 2;
        assert!(
            (i32::from(half[i]) - midpoint).abs() <= 1,
            "byte {i}: {} not halfway between {} and {}",
            half[i],
            before,
            full[i]
        );
    }
}

#[test]
fn range_banding_targets_the_bands() {
    // One gray strip: dark 32, mid 128, bright 224.
    let img = RgbaImage::from_fn(3, 1, |x, _| {
        let v = [32u8, 128, 224][x as usize];
        Rgba([v, v, v, 255])
    });
    let doc = RzDocument::from_pixels(img);
    let full = overlay(3, 1, |_, _| 255);
    let deltas = |exposure: f32, range: u8, burn: bool| -> [i32; 3] {
        let out = applied(&doc, 0, &full, (3, 1), exposure, range, burn);
        let px = out.layers[0].pixels.as_raw();
        [
            i32::from(px[0]) - 32,
            i32::from(px[4]) - 128,
            i32::from(px[8]) - 224,
        ]
    };

    // Shadows-dodge lifts by k(1 - v): strictly decreasing in v, dark
    // pixels moving far more than bright ones.
    let s = deltas(1.0, 0, false);
    assert!(
        s[0] > s[1] && s[1] > s[2] && s[0] > 50 && s[0] >= 4 * s[2],
        "shadows must brighten dark pixels much more than bright ones: {s:?}"
    );

    // Highlights: the unclamped directions are linear in v, so the effect
    // grows strictly with brightness — burn at full exposure; dodge at an
    // exposure low enough that the white-point clamp plateau stays clear
    // of the probes (at e = 1 the bright probe's gain is capped by its
    // headroom, not by the band).
    let hb = deltas(1.0, 2, true);
    assert!(
        -hb[2] > -hb[1] && -hb[1] > -hb[0] && -hb[2] > 50 && -hb[2] >= 4 * -hb[0],
        "highlights-burn must darken bright pixels much more than dark ones: {hb:?}"
    );
    let hd = deltas(0.3, 2, false);
    assert!(
        hd[2] > hd[1] && hd[1] > hd[0],
        "highlights-dodge must brighten bright pixels most: {hd:?}"
    );

    // Midtones: burn's gamma (v^(1+e)) has its largest absolute effect at
    // exactly mid grey when e = 1. Dodge's peak sits somewhat below mid
    // (sqrt(v) - v peaks at v = 1/4), so it is probed at a gentle exposure
    // where mid grey still beats both end probes.
    let mb = deltas(1.0, 1, true);
    assert!(
        -mb[1] > -mb[0] && -mb[1] > -mb[2],
        "midtones-burn must peak at mid grey: {mb:?}"
    );
    let md = deltas(0.2, 1, false);
    assert!(
        md[1] > md[0] && md[1] > md[2],
        "midtones-dodge must peak at mid grey: {md:?}"
    );
}

#[test]
fn every_band_and_direction_is_monotone_at_full_exposure() {
    // The reason this curve family replaced the polynomial band weights:
    // a retouch brush must never reorder tones. Map the full 0..=255 gray
    // ramp through every band/direction at exposure 1 (the worst case —
    // the old shadows-dodge inverted for any e > 1/3) and assert the
    // output is non-decreasing.
    let img = RgbaImage::from_fn(16, 16, |x, y| {
        let v = (y * 16 + x) as u8;
        Rgba([v, v, v, 255])
    });
    let doc = RzDocument::from_pixels(img);
    let full = overlay(16, 16, |_, _| 255);
    for range in 0..=2u8 {
        for burn in [false, true] {
            let out = applied(&doc, 0, &full, (16, 16), 1.0, range, burn);
            let px = out.layers[0].pixels.as_raw();
            for v in 1..256 {
                assert!(
                    px[v * 4] >= px[(v - 1) * 4],
                    "range {range} burn {burn}: {} -> {} but {} -> {} — tonal inversion",
                    v - 1,
                    px[(v - 1) * 4],
                    v,
                    px[v * 4]
                );
            }
        }
    }
}

#[test]
fn burn_is_the_mirror_of_dodge() {
    // For the linear end bands, burn_r(v) == 1 - dodge_r'(1 - v) exactly
    // in the reals with the band mirrored (shadows <-> highlights): the
    // black-point crush is the reflected white-point pull and vice versa.
    // So the byte results may differ only by half-up rounding: within 1.
    // (Midtones is deliberately NOT in this sweep: gamma is not
    // point-symmetric — 1 - (1-v)^(1/(1+e)) is a different curve than
    // v^(1+e) — dodge and burn there are function inverses instead.)
    let img = gradient_img();
    let inverted = RgbaImage::from_fn(16, 16, |x, y| {
        let p = img.get_pixel(x, y).0;
        Rgba([255 - p[0], 255 - p[1], 255 - p[2], 255])
    });
    let full = overlay(16, 16, |_, _| 255);
    for (burn_range, dodge_range) in [(0u8, 2u8), (2, 0)] {
        let burned = applied(
            &RzDocument::from_pixels(img.clone()),
            0,
            &full,
            (16, 16),
            1.0,
            burn_range,
            true,
        );
        let dodged = applied(
            &RzDocument::from_pixels(inverted.clone()),
            0,
            &full,
            (16, 16),
            1.0,
            dodge_range,
            false,
        );
        let (b, d) = (
            burned.layers[0].pixels.as_raw(),
            dodged.layers[0].pixels.as_raw(),
        );
        for i in (0..b.len()).filter(|i| i % 4 != 3) {
            assert!(
                (i32::from(b[i]) - (255 - i32::from(d[i]))).abs() <= 1,
                "byte {i}: burn range {burn_range} must mirror dodge range {dodge_range}"
            );
        }
    }
}

#[test]
fn dodging_white_refuses_burning_it_darkens() {
    let doc = RzDocument::from_pixels(solid(4, 4, WHITE));
    let full = overlay(4, 4, |_, _| 255);
    for range in 0..=2u8 {
        assert!(
            dodge_burn(&doc, 0, &full, (4, 4), 1.0, range, false).is_none(),
            "dodge leaves white at exactly 1 (range {range}) — identity must refuse"
        );
    }
    let burned = applied(&doc, 0, &full, (4, 4), 0.8, 2, true);
    let px = pixel(burned.layers[0].pixels.as_raw(), 4, 1, 1);
    assert!(
        px[0] < 255 && px[1] < 255 && px[2] < 255,
        "burn darkens white"
    );
    assert_eq!(px[3], 255, "alpha untouched");
    assert_eq!(px[0], reference(255, 255, 0.8, 2, true));
}

#[test]
fn overlay_maps_through_the_layer_offset() {
    // 12x10 red canvas under a 4x4 mid-gray layer at (5, 3); coverage over
    // canvas rect x 6..8, y 4..6 (the layer's inner 2x2), plus a splash
    // entirely outside the layer's extent that must be ignored.
    let doc = RzDocument::from_pixels(solid(12, 10, RED))
        .adding_image_layer(0, solid(4, 4, [128, 128, 128, 255]), "Top")
        .expect("add layer")
        .with_layer_offset(1, 5, 3)
        .expect("set offset");
    let ov = overlay(12, 10, |x, y| {
        let inside = (6..8).contains(&x) && (4..6).contains(&y);
        let splash = x < 2 && y < 2;
        if inside || splash {
            255
        } else {
            0
        }
    });
    let out = applied(&doc, 1, &ov, (12, 10), 1.0, 1, false);
    assert_eq!(out.layers[1].offset, (5, 3), "offset survives");
    assert_eq!(
        out.layers[1].pixels.dimensions(),
        (4, 4),
        "the layer does not grow"
    );
    let before = doc.layers[1].pixels.as_raw();
    let after = out.layers[1].pixels.as_raw();
    let expect = reference(128, 255, 1.0, 1, false);
    for ly in 0..4u32 {
        for lx in 0..4u32 {
            let i = ((ly * 4 + lx) * 4) as usize;
            // Canvas rect (6..8, 4..6) minus the (5, 3) offset.
            if (1..3).contains(&lx) && (1..3).contains(&ly) {
                assert_eq!(
                    &after[i..i + 4],
                    &[expect, expect, expect, 255],
                    "covered layer pixel ({lx},{ly})"
                );
            } else {
                assert_eq!(
                    &after[i..i + 4],
                    &before[i..i + 4],
                    "uncovered layer pixel ({lx},{ly}) must be byte-identical"
                );
            }
        }
    }
    assert_eq!(
        out.layers[0].pixels.as_raw(),
        doc.layers[0].pixels.as_raw(),
        "other layers untouched"
    );
}

#[test]
fn alpha_is_never_touched_and_transparent_garbage_survives() {
    // Fully transparent pixels carry RGB values that WOULD move under
    // dodge-midtones if they were processed; the rest is an alpha ramp.
    let img = RgbaImage::from_fn(8, 8, |x, y| {
        if (x + y) % 3 == 0 {
            Rgba([10, 200, 90, 0])
        } else {
            Rgba([
                (x * 30) as u8,
                (y * 30) as u8,
                77,
                (40 + x * 20 + y * 5) as u8,
            ])
        }
    });
    let doc = RzDocument::from_pixels(img.clone());
    let full = overlay(8, 8, |_, _| 255);
    let out = applied(&doc, 0, &full, (8, 8), 1.0, 1, false);
    let after = out.layers[0].pixels.as_raw();
    for (i, px) in img.as_raw().chunks_exact(4).enumerate() {
        let j = i * 4;
        assert_eq!(after[j + 3], px[3], "pixel {i}: alpha byte untouched");
        if px[3] == 0 {
            assert_eq!(
                &after[j..j + 4],
                px,
                "pixel {i}: alpha-0 RGB garbage must survive byte-identical"
            );
        } else {
            for ch in 0..3 {
                assert_eq!(
                    after[j + ch],
                    reference(px[ch], 255, 1.0, 1, false),
                    "pixel {i} channel {ch}"
                );
            }
        }
    }
}

#[test]
fn refusals() {
    let doc = RzDocument::from_pixels(solid(6, 4, [40, 90, 200, 255]));
    let full = overlay(6, 4, |_, _| 255);
    assert!(
        dodge_burn(&doc, 0, &full, (6, 4), 0.5, 1, false).is_some(),
        "the baseline call must succeed or this sweep proves nothing"
    );

    assert!(
        dodge_burn(&doc, 5, &full, (6, 4), 0.5, 1, false).is_none(),
        "idx out of range"
    );
    // Wrong dimensions (each buffer sized to its own claim, so only the
    // canvas mismatch can be what refuses).
    let wide = overlay(7, 4, |_, _| 255);
    assert!(
        dodge_burn(&doc, 0, &wide, (7, 4), 0.5, 1, false).is_none(),
        "w mismatch"
    );
    let tall = overlay(6, 5, |_, _| 255);
    assert!(
        dodge_burn(&doc, 0, &tall, (6, 5), 0.5, 1, false).is_none(),
        "h mismatch"
    );
    for bad in [f32::NAN, f32::INFINITY, f32::NEG_INFINITY] {
        assert!(
            dodge_burn(&doc, 0, &full, (6, 4), bad, 1, false).is_none(),
            "non-finite exposure {bad}"
        );
    }
    assert!(
        dodge_burn(&doc, 0, &full, (6, 4), 0.5, 3, false).is_none(),
        "range 3"
    );

    // Identity results refuse rather than mint a phantom undo step.
    assert!(
        dodge_burn(&doc, 0, &full, (6, 4), 0.0, 1, false).is_none(),
        "exposure 0 is the identity"
    );
    assert!(
        dodge_burn(&doc, 0, &full, (6, 4), -2.0, 1, false).is_none(),
        "negative exposure clamps to the identity"
    );
    let uncovered = overlay(6, 4, |_, _| 0);
    assert!(
        dodge_burn(&doc, 0, &uncovered, (6, 4), 1.0, 1, false).is_none(),
        "zero coverage is the identity"
    );

    // A layer whose extent misses the canvas entirely.
    let off = doc
        .adding_image_layer(0, solid(2, 2, RED), "Off")
        .expect("add layer")
        .with_layer_offset(1, 100, 100)
        .expect("set offset");
    assert!(
        dodge_burn(&off, 1, &full, (6, 4), 1.0, 1, false).is_none(),
        "a layer extent that misses the canvas"
    );
}

#[test]
fn null_safety() {
    // The per-export NULL sweep: NULL doc, NULL src. (A too-short buffer is
    // not representable through safe test code — the FFI recomputes the
    // length from the document's own canvas dimensions.)
    let full = overlay(2, 2, |_, _| 255);
    assert!(
        unsafe { rz_doc_dodge_burn_layer(ptr::null(), 0, full.as_ptr(), 2, 2, 0.5, 1, false) }
            .is_null()
    );
    let handle = Box::into_raw(Box::new(RzDocument::from_pixels(solid(2, 2, RED))));
    assert!(
        unsafe { rz_doc_dodge_burn_layer(handle, 0, ptr::null(), 2, 2, 0.5, 1, false) }.is_null()
    );
    unsafe { rz_doc_free(handle) };
}
