//! Adjustment-layer tests: `{"type":"adjust", ...}` meta interpreted by
//! the compositor — parity with the destructive filters, opacity / mask /
//! blend gating, curves, stacking and invisibility, merge-down baking, and
//! RZDC round-trips. Shared fixtures live in `tests/common`.

use std::ffi::c_char;
use std::ptr;

use image::{Rgba, RgbaImage};
use rasterize_core::doc::RzDocument;
use rasterize_core::ffi::*;
use rasterize_core::ffi_doc::*;
use rasterize_core::ffi_filters::*;
use rasterize_core::RzImage;
use tempfile::TempDir;

mod common;
use common::*;

// --------------------------------------------------- adjustment layers --
//
// A layer whose meta parses as `{"type":"adjust", ...}` (core/src/adjust.rs)
// is composited as a color adjustment of the accumulated backdrop: its own
// pixels are ignored, alpha is never touched, and opacity/mask/blend gate the
// strength. Anything that does not parse falls back to a plain raster layer.

/// A 6x4 opaque-pattern background under a garish 2x2 MAGENTA layer at
/// (1, 1) named "Adjust" (index 1) carrying `meta`. The magenta pixels are
/// the canary: an adjustment layer must ignore them, so any leak into the
/// projection fails the comparisons below.
fn adjustment_fixture(dir: &TempDir, tag: &str, meta: &str) -> *mut RzDocument {
    let doc = doc_from(dir, &format!("{tag}-bg.png"), &opaque_pattern(6, 4));
    let doc = add_layer(
        dir,
        &format!("{tag}-top.png"),
        doc,
        0,
        &solid(2, 2, MAGENTA),
        "Adjust",
    );
    let doc = apply(doc, |d| unsafe { rz_doc_with_layer_offset(d, 1, 1, 1) });
    set_meta(doc, 1, meta)
}

/// Asserts two RGBA buffers match within one 8-bit step per color channel
/// (the compositor quantizes once at the end, the destructive filters per
/// pixel), with alpha byte-exact — no adjustment may touch it.
fn assert_close(actual: &[u8], expected: &[u8], what: &str) {
    assert_eq!(actual.len(), expected.len(), "{what}: buffer sizes differ");
    for (i, (&a, &e)) in actual.iter().zip(expected).enumerate() {
        let tol = if i % 4 == 3 { 0 } else { 1 };
        assert!(
            (i32::from(a) - i32::from(e)).abs() <= tol,
            "{what}: byte {i} is {a}, expected {e} (±{tol})"
        );
    }
}

#[test]
fn adjustment_layer_matches_destructive_filter_for_every_op() {
    let dir = TempDir::new().unwrap();
    type Filter = Box<dyn Fn(*const RzImage) -> *mut RzImage>;
    let cases: Vec<(&str, String, Filter)> = vec![
        (
            "bcs",
            adjust_meta(
                "bcs",
                "{\"brightness\":0.15,\"contrast\":-0.3,\"saturation\":0.4}",
            ),
            Box::new(|i| unsafe { rz_image_adjust(i, 0.15, -0.3, 0.4) }),
        ),
        (
            "levels",
            adjust_meta("levels", "{\"black\":0.1,\"white\":0.9,\"gamma\":1.8}"),
            Box::new(|i| unsafe { rz_image_levels(i, 0.1, 0.9, 1.8) }),
        ),
        (
            "hue_rotate",
            adjust_meta("hue_rotate", "{\"degrees\":135.0}"),
            Box::new(|i| unsafe { rz_image_hue_rotate(i, 135.0) }),
        ),
        (
            "threshold",
            adjust_meta("threshold", "{\"level\":0.45}"),
            Box::new(|i| unsafe { rz_image_threshold(i, 0.45) }),
        ),
        (
            "posterize",
            adjust_meta("posterize", "{\"levels\":5}"),
            Box::new(|i| unsafe { rz_image_posterize(i, 5) }),
        ),
        (
            "invert",
            adjust_meta("invert", "{}"),
            Box::new(|i| unsafe { rz_image_invert(i) }),
        ),
        (
            // `params` may be omitted entirely when every param has a default.
            "invert-no-params",
            "{\"type\":\"adjust\",\"op\":\"invert\"}".to_string(),
            Box::new(|i| unsafe { rz_image_invert(i) }),
        ),
        (
            "grayscale",
            adjust_meta("grayscale", "{}"),
            Box::new(|i| unsafe { rz_image_grayscale(i) }),
        ),
        (
            "sepia",
            adjust_meta("sepia", "{}"),
            Box::new(|i| unsafe { rz_image_sepia(i) }),
        ),
    ];
    for (tag, meta, destructive) in cases {
        let doc = adjustment_fixture(&dir, tag, &meta);
        assert!(
            unsafe { rz_doc_layer_is_adjustment(doc, 1) },
            "{tag}: valid adjustment meta must be recognized"
        );
        assert!(
            !unsafe { rz_doc_layer_is_adjustment(doc, 0) },
            "{tag}: a layer without meta is not an adjustment"
        );

        // The reference: the destructive filter applied to the backdrop
        // (which IS the flattened background layer — it is opaque).
        let backdrop = open_image(&dir, &format!("{tag}-ref.png"), &opaque_pattern(6, 4));
        let filtered = destructive(backdrop);
        assert!(!filtered.is_null(), "{tag}: destructive filter failed");
        let expected = img_pixels(filtered);

        // The 2x2 magenta pixels must NOT appear: the whole canvas gets the
        // adjustment, nothing gets the layer's pixels.
        assert_close(&flat_pixels(doc), &expected, tag);

        unsafe { rz_image_free(filtered) };
        unsafe { rz_image_free(backdrop) };
        unsafe { rz_doc_free(doc) };
    }
}

#[test]
fn adjustment_layer_opacity_lerps_toward_the_adjusted_color() {
    let dir = TempDir::new().unwrap();
    let doc = adjustment_fixture(&dir, "lerp", &adjust_meta("invert", "{}"));
    let doc = apply(doc, |d| unsafe { rz_doc_with_layer_opacity(d, 1, 0.5) });
    let flat = flat_pixels(doc);
    let backdrop = opaque_pattern(6, 4);
    for (i, px) in backdrop.pixels().enumerate() {
        for c in 0..3 {
            let bg = f32::from(px[c]) / 255.0;
            let half = bg + ((1.0 - bg) - bg) * 0.5;
            let expected = (half.clamp(0.0, 1.0) * 255.0).round();
            let got = f32::from(flat[i * 4 + c]);
            assert!(
                (got - expected).abs() <= 1.0,
                "pixel {i} channel {c}: {got} vs half-strength {expected}"
            );
        }
        assert_eq!(flat[i * 4 + 3], 255, "alpha untouched at half opacity");
    }
    unsafe { rz_doc_free(doc) };
}

#[test]
fn adjustment_layer_mask_gates_interpolates_and_honors_offset() {
    let dir = TempDir::new().unwrap();
    let backdrop = opaque_pattern(6, 4);
    let backdrop_bytes = backdrop.as_raw().clone();

    // Canvas-sized invert adjustment; mask columns 0-1 hidden, 2-3 mid-gray,
    // 4-5 revealed.
    let doc = doc_from(&dir, "gate-bg.png", &backdrop);
    let doc = add_layer(
        &dir,
        "gate-top.png",
        doc,
        0,
        &solid(6, 4, MAGENTA),
        "Adjust",
    );
    let doc = set_meta(doc, 1, &adjust_meta("invert", "{}"));
    let sel = selection(6, 4, |x, _| match x {
        0 | 1 => 0,
        2 | 3 => 128,
        _ => 255,
    });
    let masked = apply(doc, |d| unsafe {
        rz_doc_adding_layer_mask(d, 1, MASK_FROM_SELECTION, sel.as_ptr(), 6, 4)
    });
    let flat = flat_pixels(masked);
    for (x, y, px) in backdrop.enumerate_pixels() {
        let i = ((y * 6 + x) * 4) as usize;
        if x < 2 {
            assert_eq!(
                &flat[i..i + 4],
                &px.0,
                "({x},{y}): outside the mask the backdrop is untouched"
            );
            continue;
        }
        let k = if x < 4 { 128.0 / 255.0 } else { 1.0 };
        for c in 0..3 {
            let bg = f32::from(px[c]) / 255.0;
            let expected = ((bg + ((1.0 - bg) - bg) * k) * 255.0).round();
            let got = f32::from(flat[i + c]);
            assert!(
                (got - expected).abs() <= 1.0,
                "({x},{y}) channel {c}: {got} vs {expected} at coverage {k}"
            );
        }
        assert_eq!(flat[i + 3], 255);
    }

    // Disabling the mask makes the adjustment canvas-wide again.
    let unmasked = apply(unsafe { rz_doc_clone(masked) }, |d| unsafe {
        rz_doc_with_layer_mask_enabled(d, 1, false)
    });
    let flat = flat_pixels(unmasked);
    for (i, &b) in backdrop_bytes.iter().enumerate() {
        let expected = if i % 4 == 3 { b } else { 255 - b };
        assert!(
            (i32::from(flat[i]) - i32::from(expected)).abs() <= 1,
            "byte {i}: a disabled mask must mean full coverage"
        );
    }
    unsafe { rz_doc_free(unmasked) };
    unsafe { rz_doc_free(masked) };

    // A 2x2 adjustment layer at (1, 1) with a reveal-all mask: the mask's
    // extent (which rides the layer's offset) confines the adjustment to
    // that window; everywhere else is untouched.
    let doc = adjustment_fixture(&dir, "window", &adjust_meta("invert", "{}"));
    let windowed = apply(doc, |d| unsafe {
        rz_doc_adding_layer_mask(d, 1, MASK_REVEAL_ALL, ptr::null(), 0, 0)
    });
    let flat = flat_pixels(windowed);
    for (x, y, px) in backdrop.enumerate_pixels() {
        let i = ((y * 6 + x) * 4) as usize;
        if (1..3).contains(&x) && (1..3).contains(&y) {
            for c in 0..3 {
                let expected = 255 - px[c];
                assert!(
                    (i32::from(flat[i + c]) - i32::from(expected)).abs() <= 1,
                    "({x},{y}): inside the masked window the backdrop inverts"
                );
            }
        } else {
            assert_eq!(
                &flat[i..i + 4],
                &px.0,
                "({x},{y}): outside the mask's extent nothing changes"
            );
        }
    }
    unsafe { rz_doc_free(windowed) };
}

#[test]
fn adjustment_layer_never_touches_alpha() {
    let dir = TempDir::new().unwrap();
    // Columns: fully transparent, semi-transparent, opaque.
    let backdrop = RgbaImage::from_fn(6, 2, |x, _| match x {
        0 | 1 => Rgba([0, 0, 0, 0]),
        2 | 3 => Rgba([200, 40, 90, 100]),
        _ => Rgba([10, 220, 130, 255]),
    });
    let doc = doc_from(&dir, "alpha-bg.png", &backdrop);
    let doc = add_layer(
        &dir,
        "alpha-top.png",
        doc,
        0,
        &solid(2, 2, MAGENTA),
        "Adjust",
    );
    let doc = set_meta(doc, 1, &adjust_meta("invert", "{}"));
    let flat = flat_pixels(doc);
    for x in 0..6u32 {
        for y in 0..2u32 {
            let px = pixel(&flat, 6, x, y);
            match x {
                0 | 1 => assert_eq!(
                    px,
                    [0, 0, 0, 0],
                    "({x},{y}): a fully transparent pixel is entirely untouched"
                ),
                2 | 3 => assert_eq!(
                    px,
                    [55, 215, 165, 100],
                    "({x},{y}): straight color inverts, alpha kept exactly"
                ),
                _ => assert_eq!(px, [245, 35, 125, 255], "({x},{y}): opaque inverts"),
            }
        }
    }
    unsafe { rz_doc_free(doc) };
}

#[test]
fn malformed_or_foreign_meta_composites_as_plain_raster() {
    let dir = TempDir::new().unwrap();
    // The projection of the SAME stack with no meta at all: magenta showing.
    let plain = adjustment_fixture(&dir, "plain", "");
    let plain = apply(plain, |d| unsafe {
        rz_doc_with_layer_meta(d, 1, ptr::null())
    });
    let plain_flat = flat_pixels(plain);
    assert_eq!(pixel(&plain_flat, 6, 1, 1), MAGENTA, "raster pixels show");

    let seventeen = (0..17)
        .map(|i| format!("[{},{}]", i, i))
        .collect::<Vec<_>>()
        .join(",");
    let rejects: Vec<String> = vec![
        "not json at all".into(),
        "[1,2,3]".into(),
        "{\"op\":\"invert\"}".into(),
        "{\"type\":\"text\",\"string\":\"hi\"}".into(),
        adjust_meta("unknown_op", "{}"),
        "{\"type\":\"adjust\",\"op\":\"invert\",\"params\":7}".into(),
        adjust_meta("posterize", "{}"),
        adjust_meta("posterize", "{\"levels\":1}"),
        adjust_meta("posterize", "{\"levels\":65}"),
        adjust_meta("posterize", "{\"levels\":5.5}"),
        adjust_meta("levels", "{\"black\":0.9,\"white\":0.1}"),
        adjust_meta("levels", "{\"gamma\":11.0}"),
        adjust_meta("threshold", "{\"level\":1.5}"),
        adjust_meta("bcs", "{\"brightness\":\"dark\"}"),
        adjust_meta("curves", "{\"rgb\":[[0,0]]}"),
        adjust_meta("curves", &format!("{{\"rgb\":[{seventeen}]}}")),
        adjust_meta("curves", "{\"rgb\":[[0,0],[0,255]]}"),
        adjust_meta("curves", "{\"rgb\":[[0,0],[255]]}"),
        adjust_meta("curves", "{\"rgb\":\"steep\"}"),
    ];
    for (n, meta) in rejects.iter().enumerate() {
        let doc = adjustment_fixture(&dir, &format!("reject{n}"), meta);
        assert!(
            !unsafe { rz_doc_layer_is_adjustment(doc, 1) },
            "case {n} ({meta}) must not parse as an adjustment"
        );
        assert_eq!(
            flat_pixels(doc),
            plain_flat,
            "case {n} ({meta}) must composite as a plain raster layer"
        );
        assert_eq!(
            ffi_meta(doc, 1).as_deref(),
            Some(meta.as_str()),
            "case {n}: the blob itself still round-trips verbatim"
        );
        unsafe { rz_doc_free(doc) };
    }

    // Every valid op IS an adjustment (the compositing math has its own
    // tests; this pins the recognizer the host's layers panel keys off).
    let accepts: Vec<String> = vec![
        adjust_meta("bcs", "{}"),
        adjust_meta("levels", "{}"),
        adjust_meta("hue_rotate", "{}"),
        adjust_meta("threshold", "{}"),
        adjust_meta("posterize", "{\"levels\":2}"),
        adjust_meta("curves", "{}"),
        adjust_meta(
            "curves",
            "{\"rgb\":[[0,0],[255,255]],\"r\":[[0,10],[255,240]]}",
        ),
        adjust_meta("invert", "{}"),
        adjust_meta("grayscale", "{}"),
        adjust_meta("sepia", "{}"),
    ];
    for (n, meta) in accepts.iter().enumerate() {
        let doc = adjustment_fixture(&dir, &format!("accept{n}"), meta);
        assert!(
            unsafe { rz_doc_layer_is_adjustment(doc, 1) },
            "case {n} ({meta}) must parse as an adjustment"
        );
        unsafe { rz_doc_free(doc) };
    }

    // Guards, like every other layer query.
    unsafe {
        assert!(!rz_doc_layer_is_adjustment(ptr::null(), 0));
        assert!(!rz_doc_layer_is_adjustment(plain, 0), "no meta at all");
        assert!(!rz_doc_layer_is_adjustment(plain, 9), "out of range");
    }
    unsafe { rz_doc_free(plain) };
}

#[test]
fn curves_identity_monotonicity_endpoints_and_order() {
    let dir = TempDir::new().unwrap();
    let ramp = RgbaImage::from_fn(256, 1, |x, _| {
        let v = x as u8;
        Rgba([v, v, v, 255])
    });
    let fixture = |tag: &str, meta: &str| {
        let doc = doc_from(&dir, &format!("{tag}-bg.png"), &ramp);
        let doc = add_layer(
            &dir,
            &format!("{tag}-top.png"),
            doc,
            0,
            &solid(1, 1, MAGENTA),
            "Adjust",
        );
        set_meta(doc, 1, meta)
    };

    // The identity point list is the identity LUT: byte-for-byte no-op.
    let id = fixture(
        "curves-id",
        &adjust_meta("curves", "{\"rgb\":[[0,0],[255,255]]}"),
    );
    assert_eq!(
        flat_pixels(id),
        ramp.as_raw().clone(),
        "identity curves must be exactly the identity"
    );
    unsafe { rz_doc_free(id) };

    // A monotone S-curve: monotone output, endpoints and every control point
    // map exactly (the interpolant passes through its knots).
    let s = fixture(
        "curves-s",
        &adjust_meta("curves", "{\"rgb\":[[0,0],[64,32],[192,224],[255,255]]}"),
    );
    let flat = flat_pixels(s);
    let lut: Vec<u8> = (0..256).map(|x| flat[x * 4]).collect();
    for x in 0..256 {
        let i = x * 4;
        assert_eq!(
            (flat[i + 1], flat[i + 2], flat[i + 3]),
            (lut[x], lut[x], 255),
            "gray in, gray out, alpha kept"
        );
        if x > 0 {
            assert!(
                lut[x] >= lut[x - 1],
                "monotone points must give a monotone LUT ({} < {} at {x})",
                lut[x],
                lut[x - 1]
            );
        }
    }
    for (input, output) in [(0usize, 0u8), (64, 32), (192, 224), (255, 255)] {
        assert_eq!(lut[input], output, "control point ({input}, {output})");
    }
    unsafe { rz_doc_free(s) };

    // Per-channel before master: red halved then everything inverted, so
    // red = 255 - x/2 while green/blue = 255 - x (identity per-channel LUT).
    let composed = fixture(
        "curves-order",
        &adjust_meta(
            "curves",
            "{\"r\":[[0,0],[255,128]],\"rgb\":[[0,255],[255,0]]}",
        ),
    );
    let flat = flat_pixels(composed);
    for x in 0..256usize {
        let i = x * 4;
        let halved = (x as f64 * 128.0 / 255.0).round();
        assert!(
            (f64::from(flat[i]) - (255.0 - halved)).abs() <= 1.0,
            "red at {x}: {} vs rgb_lut[r_lut[v]] = {}",
            flat[i],
            255.0 - halved
        );
        assert_eq!(
            (flat[i + 1], flat[i + 2]),
            (255 - x as u8, 255 - x as u8),
            "green/blue at {x} see only the master curve"
        );
    }
    unsafe { rz_doc_free(composed) };
}

#[test]
fn adjustment_layers_stack_and_skip_invisible() {
    let dir = TempDir::new().unwrap();
    let backdrop = opaque_pattern(6, 4);

    // invert over invert cancels exactly; hiding one leaves one inversion.
    let doc = adjustment_fixture(&dir, "stack", &adjust_meta("invert", "{}"));
    let doc = add_layer(
        &dir,
        "stack-top2.png",
        doc,
        1,
        &solid(1, 1, MAGENTA),
        "Adjust2",
    );
    let doc = set_meta(doc, 2, &adjust_meta("invert", "{}"));
    assert_eq!(
        flat_pixels(doc),
        backdrop.as_raw().clone(),
        "two stacked inversions must cancel"
    );
    let one = apply(unsafe { rz_doc_clone(doc) }, |d| unsafe {
        rz_doc_with_layer_visible(d, 2, false)
    });
    let flat = flat_pixels(one);
    for (i, &b) in backdrop.as_raw().iter().enumerate() {
        let expected = if i % 4 == 3 { b } else { 255 - b };
        assert_eq!(
            flat[i], expected,
            "an invisible adjustment layer is skipped"
        );
    }
    unsafe { rz_doc_free(one) };
    unsafe { rz_doc_free(doc) };

    // A raster layer ABOVE an adjustment layer composites over the adjusted
    // backdrop: its own pixels are untouched by the adjustment below.
    let doc = adjustment_fixture(&dir, "above", &adjust_meta("invert", "{}"));
    let doc = add_layer(&dir, "above-top.png", doc, 1, &solid(2, 2, GREEN), "Top");
    let doc = apply(doc, |d| unsafe { rz_doc_with_layer_offset(d, 2, 3, 1) });
    let flat = flat_pixels(doc);
    for (x, y, px) in backdrop.enumerate_pixels() {
        let got = pixel(&flat, 6, x, y);
        if (3..5).contains(&x) && (1..3).contains(&y) {
            assert_eq!(got, GREEN, "({x},{y}): the raster layer wins on top");
        } else {
            for c in 0..3 {
                assert_eq!(got[c], 255 - px[c], "({x},{y}): inverted below");
            }
        }
    }
    unsafe { rz_doc_free(doc) };
}

#[test]
fn merge_down_bakes_adjustment_masked_and_unmasked() {
    let dir = TempDir::new().unwrap();
    let backdrop = opaque_pattern(6, 4);

    // Masked case: canvas-sized invert revealed on the left half only.
    let doc = doc_from(&dir, "bake-bg.png", &backdrop);
    let doc = add_layer(
        &dir,
        "bake-top.png",
        doc,
        0,
        &solid(6, 4, MAGENTA),
        "Adjust",
    );
    let doc = set_meta(doc, 1, &adjust_meta("invert", "{}"));
    let sel = selection(6, 4, |x, _| if x < 3 { 255 } else { 0 });
    let doc = apply(doc, |d| unsafe {
        rz_doc_adding_layer_mask(d, 1, MASK_FROM_SELECTION, sel.as_ptr(), 6, 4)
    });
    let before = flat_pixels(doc);
    let merged = apply(doc, |d| unsafe { rz_doc_merging_down(d, 1) });
    assert_eq!(unsafe { rz_doc_layer_count(merged) }, 1);
    assert!(
        !unsafe { rz_doc_layer_is_adjustment(merged, 0) },
        "the baked layer is plain raster (meta cleared)"
    );
    assert_eq!(ffi_meta(merged, 0), None);
    assert_eq!(
        flat_pixels(merged),
        before,
        "merging an adjustment down must not change the projection"
    );
    // ... and the bake is real: left half inverted, right half untouched.
    for (x, y, px) in backdrop.enumerate_pixels() {
        let got = pixel(&before, 6, x, y);
        if x < 3 {
            for c in 0..3 {
                assert_eq!(got[c], 255 - px[c], "({x},{y}): inside the mask");
            }
        } else {
            assert_eq!(got, px.0, "({x},{y}): outside the mask");
        }
    }
    unsafe { rz_doc_free(merged) };

    // Unmasked, half opacity: the bake keeps the half-strength lerp.
    let doc = adjustment_fixture(&dir, "bake-op", &adjust_meta("invert", "{}"));
    let doc = apply(doc, |d| unsafe { rz_doc_with_layer_opacity(d, 1, 0.5) });
    let before = flat_pixels(doc);
    let merged = apply(doc, |d| unsafe { rz_doc_merging_down(d, 1) });
    assert_eq!(unsafe { rz_doc_layer_count(merged) }, 1);
    assert_eq!(flat_pixels(merged), before, "opacity-gated bake");
    assert_ne!(
        before,
        backdrop.as_raw().clone(),
        "the half-strength adjustment did change the projection"
    );
    unsafe { rz_doc_free(merged) };
}

#[test]
fn rzdc_round_trip_preserves_a_masked_adjustment_layer() {
    let dir = TempDir::new().unwrap();
    let meta = adjust_meta("hue_rotate", "{\"degrees\":120.0}");
    let doc = doc_from(&dir, "rt-bg.png", &opaque_pattern(6, 4));
    let doc = add_layer(&dir, "rt-top.png", doc, 0, &solid(6, 4, MAGENTA), "Adjust");
    let doc = set_meta(doc, 1, &meta);
    let sel = selection(6, 4, |x, y| if (x + y) % 2 == 0 { 255 } else { 64 });
    let doc = apply(doc, |d| unsafe {
        rz_doc_adding_layer_mask(d, 1, MASK_FROM_SELECTION, sel.as_ptr(), 6, 4)
    });
    let before = flat_pixels(doc);

    let path = dir.path().join("adjust.rzdc");
    let c = cpath(&path);
    let mut err: *mut c_char = ptr::null_mut();
    assert!(
        unsafe { rz_doc_save_native(doc, c.as_ptr(), &mut err) },
        "save failed: {}",
        take_err_string(err)
    );
    let mut err: *mut c_char = ptr::null_mut();
    let back = unsafe { rz_doc_open(c.as_ptr(), &mut err) };
    assert!(!back.is_null(), "reopen failed: {}", take_err_string(err));

    assert!(
        unsafe { rz_doc_layer_is_adjustment(back, 1) },
        "the reopened layer is still an adjustment layer"
    );
    assert_eq!(ffi_meta(back, 1).as_deref(), Some(meta.as_str()));
    assert_eq!(
        flat_pixels(back),
        before,
        "the reopened document composites byte-identically"
    );

    unsafe { rz_doc_free(back) };
    unsafe { rz_doc_free(doc) };
}
