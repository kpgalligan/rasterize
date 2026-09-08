//! Blend-mode painting tests: `rz_doc_painting_layer_blend` — the paint
//! tools' Blend option. Two independent oracles: the W3C reference in
//! `tests/common` (`ref_composite`, for the separable modes it covers), and
//! the op's own contract that painting through mode M lands exactly what a
//! mode-M layer holding the stroke would flatten to (checked through the
//! separately-tested projection path, which covers every mode including the
//! non-separable four and Dissolve).

use std::ffi::c_int;
use std::ptr;

use image::{Rgba, RgbaImage};
use rasterize_core::doc::RzDocument;
use rasterize_core::ffi_doc::*;
use tempfile::TempDir;

mod common;
use common::*;

/// Runs the op through its FFI entry point, returning the new document or
/// `None` when the call refuses.
fn painted_blend(
    doc: *const RzDocument,
    idx: usize,
    overlay: &[u8],
    (w, h): (u32, u32),
    mode: c_int,
    alpha: f32,
) -> Option<*mut RzDocument> {
    let out = unsafe { rz_doc_painting_layer_blend(doc, idx, overlay.as_ptr(), w, h, mode, alpha) };
    if out.is_null() {
        None
    } else {
        Some(out)
    }
}

/// A varied straight-alpha stroke image: color ramps with an alpha ramp
/// that includes fully transparent, fully opaque and everything between.
fn stroke_image(w: u32, h: u32) -> RgbaImage {
    RgbaImage::from_fn(w, h, |x, y| {
        let i = y * w + x;
        Rgba([
            (i * 13 % 256) as u8,
            (255 - (i * 7 % 256)) as u8,
            (i * 29 % 256) as u8,
            (i * 17 % 256) as u8,
        ])
    })
}

/// A varied straight-alpha base: different ramps, partial alpha included.
fn base_image(w: u32, h: u32) -> RgbaImage {
    RgbaImage::from_fn(w, h, |x, y| {
        let i = y * w + x;
        Rgba([
            (i * 5 % 256) as u8,
            (i * 11 % 256) as u8,
            (200 + i * 3 % 56) as u8,
            (64 + i * 23 % 192) as u8,
        ])
    })
}

/// The same stroke as a canvas-frame PREMULTIPLIED overlay — what the app's
/// stroke pipeline hands the paint FFI.
fn premultiplied(img: &RgbaImage) -> Vec<u8> {
    img.pixels()
        .flat_map(|p| {
            let a = u32::from(p[3]);
            [
                ((u32::from(p[0]) * a + 127) / 255) as u8,
                ((u32::from(p[1]) * a + 127) / 255) as u8,
                ((u32::from(p[2]) * a + 127) / 255) as u8,
                p[3],
            ]
        })
        .collect()
}

// ------------------------------------------------------------------ tests --

#[test]
fn normal_is_byte_identical_to_the_classic_paint_path() {
    let dir = TempDir::new().unwrap();
    let doc = doc_from(&dir, "base.png", &base_image(16, 12));
    let overlay = premultiplied(&stroke_image(16, 12));
    for alpha in [1.0f32, 0.5, 0.125] {
        let classic = unsafe {
            rz_doc_painting_layer(doc, 0, overlay.as_ptr(), 16, 12, COMPOSITE_OVER, alpha)
        };
        assert!(!classic.is_null());
        let blend = painted_blend(doc, 0, &overlay, (16, 12), BLEND_NORMAL, alpha)
            .expect("normal blend paint must succeed");
        assert_eq!(
            layer_pixels(classic, 0),
            layer_pixels(blend, 0),
            "alpha {alpha}"
        );
        unsafe { rz_doc_free(classic) };
        unsafe { rz_doc_free(blend) };
    }
    unsafe { rz_doc_free(doc) };
}

#[test]
fn separable_modes_match_the_w3c_reference() {
    // Per-pixel oracle: unpremultiplied stroke color composited by the
    // independent reference in tests/common. ±1 byte absorbs the f32
    // rounding difference between one rounding step and the reference's.
    let dir = TempDir::new().unwrap();
    let base = base_image(16, 12);
    let stroke = stroke_image(16, 12);
    let overlay = premultiplied(&stroke);
    let doc = doc_from(&dir, "base.png", &base);
    for &(mode, alpha) in &[
        (BLEND_MULTIPLY, 1.0f32),
        (BLEND_MULTIPLY, 0.6),
        (BLEND_SCREEN, 1.0),
        (BLEND_OVERLAY, 0.8),
        (BLEND_DARKEN, 1.0),
        (BLEND_LIGHTEN, 0.4),
        (BLEND_DIFFERENCE, 1.0),
        (BLEND_EXCLUSION, 0.7),
        (BLEND_COLOR_DODGE, 0.9),
        (BLEND_COLOR_BURN, 1.0),
        (BLEND_SOFT_LIGHT, 1.0),
        (BLEND_HARD_LIGHT, 0.5),
        (BLEND_ADDITION, 1.0),
        (BLEND_SUBTRACT, 0.8),
    ] {
        let out = painted_blend(doc, 0, &overlay, (16, 12), mode, alpha)
            .unwrap_or_else(|| panic!("mode {mode} must paint"));
        let got = layer_pixels(out, 0);
        for y in 0..12u32 {
            for x in 0..16u32 {
                // The oracle gets the color the op actually receives: the
                // overlay's premultiplied bytes divided back out. (The
                // pristine stroke color is NOT recoverable — premultiplying
                // quantizes, and at low alpha that loss is many byte steps.)
                let sp = pixel(&overlay, 16, x, y);
                let expect = if sp[3] == 0 {
                    pixel(base.as_raw(), 16, x, y)
                } else {
                    let src = [
                        (f32::from(sp[0]) / f32::from(sp[3])).min(1.0),
                        (f32::from(sp[1]) / f32::from(sp[3])).min(1.0),
                        (f32::from(sp[2]) / f32::from(sp[3])).min(1.0),
                        f32::from(sp[3]) / 255.0,
                    ];
                    let want =
                        ref_composite(to_unit(pixel(base.as_raw(), 16, x, y)), src, alpha, mode);
                    [
                        (want[0].clamp(0.0, 1.0) * 255.0).round() as u8,
                        (want[1].clamp(0.0, 1.0) * 255.0).round() as u8,
                        (want[2].clamp(0.0, 1.0) * 255.0).round() as u8,
                        (want[3].clamp(0.0, 1.0) * 255.0).round() as u8,
                    ]
                };
                let actual = pixel(&got, 16, x, y);
                for c in 0..4 {
                    assert!(
                        (i32::from(actual[c]) - i32::from(expect[c])).abs() <= 1,
                        "mode {mode} alpha {alpha} at ({x},{y})[{c}]: {} vs {}",
                        actual[c],
                        expect[c]
                    );
                }
            }
        }
        unsafe { rz_doc_free(out) };
    }
    unsafe { rz_doc_free(doc) };
}

#[test]
fn every_mode_matches_flattening_an_equivalent_layer() {
    // The op's contract, verbatim: painting through mode M onto the only
    // layer equals adding a mode-M layer holding the stroke and flattening.
    // Exercises every non-Normal mode, non-separable and Dissolve included,
    // and must agree byte-for-byte (both paths run the same kernel once per
    // pixel on identical f32 inputs). Two framing choices make exactness
    // possible: stroke alphas are only 0 or 255 (premultiplying is lossless
    // there; partial coverage is exercised via the global alpha instead),
    // and Normal is excluded — it deliberately delegates to the classic
    // paint path, whose different f32 grouping can differ from the
    // projection by one rounding step (its own byte-identity test above is
    // the stronger check).
    let dir = TempDir::new().unwrap();
    let base = base_image(16, 12);
    let stroke = RgbaImage::from_fn(16, 12, |x, y| {
        let i = y * 16 + x;
        let a = if (x + y) % 3 == 0 { 0 } else { 255 };
        Rgba([
            (i * 13 % 256) as u8,
            (255 - i * 7 % 256) as u8,
            (i * 29 % 256) as u8,
            a,
        ])
    });
    let overlay = premultiplied(&stroke);
    for mode in 1..BLEND_MODE_COUNT {
        for &alpha in &[1.0f32, 0.6] {
            let doc = doc_from(&dir, &format!("b-{mode}-{alpha}.png"), &base);
            let painted = painted_blend(doc, 0, &overlay, (16, 12), mode, alpha)
                .unwrap_or_else(|| panic!("mode {mode} alpha {alpha} must paint"));

            let layered = add_layer(
                &dir,
                &format!("s-{mode}-{alpha}.png"),
                doc,
                0,
                &stroke,
                "Stroke",
            );
            let layered = apply(layered, |d| unsafe {
                rz_doc_with_layer_blend_mode(d, 1, mode)
            });
            // alpha 1.0 is the opacity the fresh layer already carries, and
            // a setter handed the stored value answers NULL (the core's
            // purity rule).
            let layered = apply_or_keep(layered, |d| unsafe {
                rz_doc_with_layer_opacity(d, 1, alpha)
            });

            assert_eq!(
                layer_pixels(painted, 0),
                flat_pixels(layered),
                "mode {mode} alpha {alpha}"
            );
            unsafe { rz_doc_free(painted) };
            unsafe { rz_doc_free(layered) };
        }
    }
}

#[test]
fn dissolve_is_deterministic_and_respects_coverage() {
    let dir = TempDir::new().unwrap();
    let base = solid(32, 32, [10, 20, 30, 255]);
    let doc = doc_from(&dir, "base.png", &base);
    // Uniform half-coverage stroke of solid green.
    let overlay: Vec<u8> = (0..32 * 32).flat_map(|_| [0u8, 128, 0, 128]).collect();
    let a = painted_blend(doc, 0, &overlay, (32, 32), BLEND_DISSOLVE, 1.0)
        .expect("dissolve must paint");
    let b = painted_blend(doc, 0, &overlay, (32, 32), BLEND_DISSOLVE, 1.0)
        .expect("dissolve must paint again");
    let (pa, pb) = (layer_pixels(a, 0), layer_pixels(b, 0));
    assert_eq!(pa, pb, "dissolve dither must be deterministic");
    let mut painted_px = 0;
    for i in 0..32 * 32 {
        let px = pixel(&pa, 32, (i % 32) as u32, (i / 32) as u32);
        if px == [0, 255, 0, 255] {
            painted_px += 1;
        } else {
            assert_eq!(
                px,
                [10, 20, 30, 255],
                "pixel {i} must be source or untouched"
            );
        }
    }
    let fraction = f64::from(painted_px) / 1024.0;
    assert!(
        (0.35..=0.65).contains(&fraction),
        "≈half the pixels should paint, got {fraction}"
    );
    unsafe { rz_doc_free(a) };
    unsafe { rz_doc_free(b) };
    unsafe { rz_doc_free(doc) };
}

#[test]
fn refusals() {
    let dir = TempDir::new().unwrap();
    let base = solid(8, 6, [100, 100, 100, 255]);
    let doc = doc_from(&dir, "base.png", &base);
    let overlay: Vec<u8> = (0..8 * 6).flat_map(|_| [255u8, 255, 255, 255]).collect();

    // Unknown mode, NaN alpha, wrong dimensions, bad index, NULL inputs.
    assert!(painted_blend(doc, 0, &overlay, (8, 6), 99, 1.0).is_none());
    assert!(painted_blend(doc, 0, &overlay, (8, 6), -1, 1.0).is_none());
    assert!(painted_blend(doc, 0, &overlay, (8, 6), BLEND_MULTIPLY, f32::NAN).is_none());
    assert!(painted_blend(doc, 0, &overlay, (7, 6), BLEND_MULTIPLY, 1.0).is_none());
    assert!(painted_blend(doc, 0, &overlay, (8, 5), BLEND_MULTIPLY, 1.0).is_none());
    assert!(painted_blend(doc, 9, &overlay, (8, 6), BLEND_MULTIPLY, 1.0).is_none());
    assert!(unsafe {
        rz_doc_painting_layer_blend(ptr::null(), 0, overlay.as_ptr(), 8, 6, BLEND_MULTIPLY, 1.0)
            .is_null()
    });
    assert!(unsafe {
        rz_doc_painting_layer_blend(doc, 0, ptr::null(), 8, 6, BLEND_MULTIPLY, 1.0).is_null()
    });

    // No pixel changes: multiplying an opaque layer by pure white.
    assert!(
        painted_blend(doc, 0, &overlay, (8, 6), BLEND_MULTIPLY, 1.0).is_none(),
        "multiply by white must refuse as a no-change edit"
    );
    // …and a fully transparent overlay through any mode.
    let clear: Vec<u8> = vec![0; 8 * 6 * 4];
    assert!(painted_blend(doc, 0, &clear, (8, 6), BLEND_SCREEN, 1.0).is_none());
    // Alpha 0 scales every contribution away.
    let green: Vec<u8> = (0..8 * 6).flat_map(|_| [0u8, 200, 0, 200]).collect();
    assert!(painted_blend(doc, 0, &green, (8, 6), BLEND_SCREEN, 0.0).is_none());
    unsafe { rz_doc_free(doc) };
}

#[test]
fn overlay_is_mapped_through_the_layer_offset() {
    // A 4x4 layer at offset (2, 1) inside an 8x6 canvas: only the covered
    // canvas region reaches the layer, and the layer never grows.
    let doc_owned = mask_fixture((8, 6), (4, 4), (2, 1));
    let handle = Box::into_raw(Box::new(doc_owned));
    // Screen a solid gray onto the blue layer: blue (0,0,255) screened with
    // gray 128 -> (128, 128, 255).
    let overlay: Vec<u8> = (0..8 * 6).flat_map(|_| [128u8, 128, 128, 255]).collect();
    let out = painted_blend(handle, 1, &overlay, (8, 6), BLEND_SCREEN, 1.0)
        .expect("offset blend paint must succeed");
    assert_eq!(layer_dims(out, 1), (4, 4), "the layer must not grow");
    let px = layer_pixels(out, 1);
    for i in 0..16 {
        assert_eq!(
            pixel(&px, 4, (i % 4) as u32, (i / 4) as u32),
            [128, 128, 255, 255],
            "layer pixel {i}"
        );
    }
    unsafe { rz_doc_free(out) };
    unsafe { rz_doc_free(handle) };
}

#[test]
fn dissolve_dither_is_canvas_absolute_under_a_layer_offset() {
    // The dither threshold is a function of CANVAS position, so the same
    // half-coverage overlay must speckle a pixel identically whether the
    // layer under it sits at (0, 0) or somewhere else: painting an offset
    // layer and reading through the canvas mapping must reproduce the
    // origin layer's speckle for the shared canvas region. A broken kernel
    // that passed LAYER-local coordinates would agree at (0, 0) and
    // diverge at any nonzero offset.
    let dir = TempDir::new().unwrap();
    let overlay: Vec<u8> = (0..16 * 12).flat_map(|_| [0u8, 128, 0, 128]).collect();

    let origin = doc_from(&dir, "origin.png", &solid(16, 12, [10, 20, 30, 255]));
    let painted_origin = painted_blend(origin, 0, &overlay, (16, 12), BLEND_DISSOLVE, 1.0)
        .expect("origin dissolve must paint");
    let origin_px = layer_pixels(painted_origin, 0);

    // 8x8 layer at offset (5, 3) inside the same canvas.
    let offset_doc = mask_fixture((16, 12), (8, 8), (5, 3));
    let handle = Box::into_raw(Box::new(offset_doc));
    let painted_offset = painted_blend(handle, 1, &overlay, (16, 12), BLEND_DISSOLVE, 1.0)
        .expect("offset dissolve must paint");
    let offset_px = layer_pixels(painted_offset, 1);
    for ly in 0..8u32 {
        for lx in 0..8u32 {
            let (cx, cy) = (lx + 5, ly + 3);
            let spoke = pixel(&offset_px, 8, lx, ly) == [0, 255, 0, 255];
            let origin_spoke = pixel(&origin_px, 16, cx, cy) == [0, 255, 0, 255];
            assert_eq!(
                spoke, origin_spoke,
                "canvas ({cx},{cy}) must speckle identically at both offsets"
            );
        }
    }
    unsafe { rz_doc_free(painted_origin) };
    unsafe { rz_doc_free(origin) };
    unsafe { rz_doc_free(painted_offset) };
    unsafe { rz_doc_free(handle) };
}
