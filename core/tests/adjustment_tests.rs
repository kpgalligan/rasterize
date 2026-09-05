//! Adjustment-layer tests: `{"type":"adjust", ...}` meta interpreted by
//! the compositor — parity with the destructive filters, opacity / mask /
//! blend gating, curves, stacking and invisibility, merge-down baking, and
//! RZDC round-trips. Shared fixtures live in `tests/common`.

use std::ffi::{c_char, CString};
use std::ptr;

use image::{Rgba, RgbaImage};
use rasterize_core::doc::RzDocument;
use rasterize_core::ffi::*;
use rasterize_core::ffi_adjust::*;
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

/// `background` under a garish 2x2 MAGENTA layer at (1, 1) named "Adjust"
/// (index 1) carrying `meta`. The magenta pixels are the canary: an
/// adjustment layer must ignore them, so any leak into the projection fails
/// the comparisons below. The adjustment sits DIRECTLY above the single
/// pattern layer, so the backdrop it composites over is exactly the image
/// the destructive twin is handed — which is what makes the parity
/// comparison meaningful for the one SPATIAL op.
fn adjustment_fixture_on(
    dir: &TempDir,
    tag: &str,
    meta: &str,
    background: &RgbaImage,
) -> *mut RzDocument {
    let doc = doc_from(dir, &format!("{tag}-bg.png"), background);
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

/// The house fixture: a 6x4 opaque pattern under the adjustment.
fn adjustment_fixture(dir: &TempDir, tag: &str, meta: &str) -> *mut RzDocument {
    adjustment_fixture_on(dir, tag, meta, &opaque_pattern(6, 4))
}

/// A 64x64 opaque two-tone fixture — a dark half and a light half — for the
/// one SPATIAL op, which needs a neighbourhood big enough to have an
/// opinion. On the 6x4 house pattern a 30 px blur reaches every pixel, so
/// the two paths could agree by accident rather than by construction.
fn two_tone(w: u32, h: u32) -> RgbaImage {
    RgbaImage::from_fn(w, h, |x, y| {
        // A little per-row texture so the two halves are not two flat
        // colours a bug could reproduce by accident.
        let jitter = ((y % 3) * 2) as u8;
        if x < w / 2 {
            Rgba([40 + jitter, 44 + jitter, 52 + jitter, 255])
        } else {
            Rgba([210 + jitter, 200 + jitter, 190 + jitter, 255])
        }
    })
}

/// The ONE destructive twin, as a filter closure for the parity table.
fn destructive_op(op: &'static str, params: &'static str) -> Filter {
    Box::new(move |img| {
        let c_op = CString::new(op).unwrap();
        let c_params = CString::new(params).unwrap();
        let mut err: *mut c_char = ptr::null_mut();
        let out = unsafe { rz_image_adjust_op(img, c_op.as_ptr(), c_params.as_ptr(), &mut err) };
        assert!(
            !out.is_null(),
            "rz_image_adjust_op({op}, {params}) failed: {}",
            take_err_string(err)
        );
        out
    })
}

/// The destructive reference for one parity row.
type Filter = Box<dyn Fn(*const RzImage) -> *mut RzImage>;

/// A 2x2x2 `color_lookup` table that exchanges red and blue: the shortest
/// table whose effect is unmistakable, base64 of 24 little-endian f32 in
/// red-fastest order (see core/src/adjust_lut.rs).
const SWAP_RB_LUT: &str = concat!(
    "{\"kind\":\"3d\",\"size\":2,\"table\":\"",
    "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAIA/AAAAAAAAgD8AAAAAAAAAAAAAgD8AAIA/AACAPwAAAAAAAAAAAACAPwAAAAAAAIA/AACAPwAAgD8AAAAAAACAPwAAgD8AAIA/",
    "\"}"
);

/// The same table at half strength — the lerp from the original, which the
/// parity row exercises because it is the one part of the op that reads the
/// INPUT pixel as well as the table.
const HALF_STRENGTH_LUT: &str = concat!(
    "{\"kind\":\"3d\",\"size\":2,\"strength\":0.5,\"table\":\"",
    "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAIA/AAAAAAAAgD8AAAAAAAAAAAAAgD8AAIA/AACAPwAAAAAAAAAAAACAPwAAAAAAAIA/AACAPwAAgD8AAAAAAACAPwAAgD8AAIA/",
    "\"}"
);

/// A three-stop `gradient_map`, dither OFF: the parity comparison must be
/// exact, and the dither is position-keyed (see the row's comment).
const GRADIENT_MAP: &str = concat!(
    "{\"dither\":false,\"gradient\":{\"stops\":[",
    "{\"position\":0,\"color\":\"#201060\"},",
    "{\"position\":0.45,\"color\":\"#d05020\",\"opacity\":0.75},",
    "{\"position\":1,\"color\":\"#fff0c0\"}]}}"
);

/// Asserts two RGBA buffers match within one 8-bit step per color channel,
/// with alpha byte-exact — no adjustment may touch it.
///
/// The tolerance is there for the LEGACY nine only, and for one reason:
/// their destructive exports (`ops::grayscale`, `ops::sepia`, ...) predate
/// the ONE twin and do their arithmetic in 0..255 rather than 0..1, so on a
/// value that lands on an exact half-code the two round apart. Every op
/// reached through `rz_image_adjust_op` — which is every op the sheets and
/// MCP use — is BYTE-identical to its layer instead; that stronger claim is
/// `full_strength_adjustment_layer_is_byte_identical_over_every_level`.
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

/// Asserts two RGBA buffers are BYTE-IDENTICAL. Reports how many bytes
/// differ, because "one pixel" and "half the canvas" are very different
/// bugs.
fn assert_identical(actual: &[u8], expected: &[u8], what: &str) {
    assert_eq!(actual.len(), expected.len(), "{what}: buffer sizes differ");
    let mut differing = 0usize;
    let mut first = None;
    for (i, (&a, &e)) in actual.iter().zip(expected).enumerate() {
        if a != e {
            differing += 1;
            first.get_or_insert((i, a, e));
        }
    }
    if let Some((i, a, e)) = first {
        panic!(
            "{what}: byte {i} (pixel {}, channel {}) is {a}, expected {e} \
             — {differing} of {} bytes differ",
            i / 4,
            i % 4,
            actual.len()
        );
    }
}

#[test]
fn adjustment_layer_matches_destructive_filter_for_every_op() {
    let dir = TempDir::new().unwrap();
    let house = opaque_pattern(6, 4);
    // The one SPATIAL op brings its own, bigger fixture (see `two_tone`).
    let spatial = two_tone(64, 64);
    // The fifth field is EXACT: true where the reference is the ONE twin
    // (`rz_image_adjust_op`), which is byte-identical to the layer, and
    // false for the nine legacy exports, which round in 0..255 (see
    // `assert_close`).
    let cases: Vec<(&str, String, Filter, &RgbaImage, bool)> = vec![
        (
            "bcs",
            adjust_meta(
                "bcs",
                "{\"brightness\":0.15,\"contrast\":-0.3,\"saturation\":0.4}",
            ),
            Box::new(|i| unsafe { rz_image_adjust(i, 0.15, -0.3, 0.4) }),
            &house,
            false,
        ),
        (
            "levels",
            adjust_meta("levels", "{\"black\":0.1,\"white\":0.9,\"gamma\":1.8}"),
            Box::new(|i| unsafe { rz_image_levels(i, 0.1, 0.9, 1.8) }),
            &house,
            false,
        ),
        (
            "hue_rotate",
            adjust_meta("hue_rotate", "{\"degrees\":135.0}"),
            Box::new(|i| unsafe { rz_image_hue_rotate(i, 135.0) }),
            &house,
            false,
        ),
        (
            "threshold",
            adjust_meta("threshold", "{\"level\":0.45}"),
            Box::new(|i| unsafe { rz_image_threshold(i, 0.45) }),
            &house,
            false,
        ),
        (
            "posterize",
            adjust_meta("posterize", "{\"levels\":5}"),
            Box::new(|i| unsafe { rz_image_posterize(i, 5) }),
            &house,
            false,
        ),
        (
            "invert",
            adjust_meta("invert", "{}"),
            Box::new(|i| unsafe { rz_image_invert(i) }),
            &house,
            false,
        ),
        (
            // `params` may be omitted entirely when every param has a default.
            "invert-no-params",
            "{\"type\":\"adjust\",\"op\":\"invert\"}".to_string(),
            Box::new(|i| unsafe { rz_image_invert(i) }),
            &house,
            false,
        ),
        (
            "grayscale",
            adjust_meta("grayscale", "{}"),
            Box::new(|i| unsafe { rz_image_grayscale(i) }),
            &house,
            false,
        ),
        (
            "sepia",
            adjust_meta("sepia", "{}"),
            Box::new(|i| unsafe { rz_image_sepia(i) }),
            &house,
            false,
        ),
        // The phase-5 ops, all through the ONE destructive twin: the filter
        // and the layer literally run the same code, so a row here is a
        // check that nothing in the compositing path (the guide plane, the
        // position argument, the accumulator's f32 round trip) perturbs it.
        (
            "exposure",
            adjust_meta(
                "exposure",
                "{\"exposure\":0.8,\"offset\":-0.05,\"gamma\":1.3}",
            ),
            destructive_op(
                "exposure",
                "{\"exposure\":0.8,\"offset\":-0.05,\"gamma\":1.3}",
            ),
            &house,
            true,
        ),
        (
            "vibrance",
            adjust_meta("vibrance", "{\"vibrance\":0.6,\"saturation\":-0.25}"),
            destructive_op("vibrance", "{\"vibrance\":0.6,\"saturation\":-0.25}"),
            &house,
            true,
        ),
        (
            "hue_saturation",
            adjust_meta(
                "hue_saturation",
                "{\"hue\":25,\"saturation\":0.3,\"lightness\":-0.1,                  \"bands\":{\"reds\":{\"hue\":-40,\"saturation\":0.5},                  \"cyans\":{\"lightness\":0.4,\"inner\":20,\"falloff\":45}}}",
            ),
            destructive_op(
                "hue_saturation",
                "{\"hue\":25,\"saturation\":0.3,\"lightness\":-0.1,                  \"bands\":{\"reds\":{\"hue\":-40,\"saturation\":0.5},                  \"cyans\":{\"lightness\":0.4,\"inner\":20,\"falloff\":45}}}",
            ),
            &house,
            true,
        ),
        (
            "color_balance",
            adjust_meta(
                "color_balance",
                "{\"shadows\":{\"cyan_red\":0.3},                  \"midtones\":{\"magenta_green\":-0.4,\"yellow_blue\":0.2},                  \"highlights\":{\"cyan_red\":-0.15}}",
            ),
            destructive_op(
                "color_balance",
                "{\"shadows\":{\"cyan_red\":0.3},                  \"midtones\":{\"magenta_green\":-0.4,\"yellow_blue\":0.2},                  \"highlights\":{\"cyan_red\":-0.15}}",
            ),
            &house,
            true,
        ),
        (
            "black_and_white",
            adjust_meta(
                "black_and_white",
                "{\"reds\":1.2,\"blues\":-0.4,\"tint\":true,                  \"tint_color\":\"#3366aa\"}",
            ),
            destructive_op(
                "black_and_white",
                "{\"reds\":1.2,\"blues\":-0.4,\"tint\":true,                  \"tint_color\":\"#3366aa\"}",
            ),
            &house,
            true,
        ),
        (
            "photo_filter",
            adjust_meta("photo_filter", "{\"color\":\"#006dff\",\"density\":0.6}"),
            destructive_op("photo_filter", "{\"color\":\"#006dff\",\"density\":0.6}"),
            &house,
            true,
        ),
        (
            "channel_mixer",
            adjust_meta(
                "channel_mixer",
                "{\"red\":{\"r\":0.8,\"g\":0.3,\"constant\":-0.05},                  \"blue\":{\"b\":1.2,\"r\":-0.2}}",
            ),
            destructive_op(
                "channel_mixer",
                "{\"red\":{\"r\":0.8,\"g\":0.3,\"constant\":-0.05},                  \"blue\":{\"b\":1.2,\"r\":-0.2}}",
            ),
            &house,
            true,
        ),
        (
            "selective_color",
            adjust_meta(
                "selective_color",
                "{\"method\":\"absolute\",\"reds\":{\"c\":0.2,\"k\":0.1},                  \"neutrals\":{\"m\":-0.15},\"blacks\":{\"k\":0.25}}",
            ),
            destructive_op(
                "selective_color",
                "{\"method\":\"absolute\",\"reds\":{\"c\":0.2,\"k\":0.1},                  \"neutrals\":{\"m\":-0.15},\"blacks\":{\"k\":0.25}}",
            ),
            &house,
            true,
        ),
        (
            // The one SPATIAL op, on a fixture big enough to have a
            // neighbourhood. Invariant 1's stated exception is that the
            // filter reads its neighbourhood from the image it is given
            // while the layer reads it from the backdrop below; here those
            // are the SAME pixels by construction, so the two must agree.
            "shadows_highlights",
            adjust_meta(
                "shadows_highlights",
                "{\"shadows\":{\"amount\":0.6,\"tone\":0.4},                  \"highlights\":{\"amount\":0.3},\"radius\":12,                  \"color\":0.3,\"midtone_contrast\":0.2}",
            ),
            destructive_op(
                "shadows_highlights",
                "{\"shadows\":{\"amount\":0.6,\"tone\":0.4},                  \"highlights\":{\"amount\":0.3},\"radius\":12,                  \"color\":0.3,\"midtone_contrast\":0.2}",
            ),
            &spatial,
            true,
        ),
        (
            "white_balance",
            adjust_meta("white_balance", "{\"temperature\":4200,\"tint\":35}"),
            destructive_op("white_balance", "{\"temperature\":4200,\"tint\":35}"),
            &house,
            true,
        ),
        (
            // `dither: false` so the comparison stays exact. The dither
            // itself is keyed on position, and the two paths use different
            // origins by design (canvas vs image), so a dithered row would
            // be comparing two deliberately different pictures; its own
            // behaviour is pinned in `adjust_map_tests`.
            "gradient_map",
            adjust_meta("gradient_map", GRADIENT_MAP),
            destructive_op("gradient_map", GRADIENT_MAP),
            &house,
            true,
        ),
        (
            "color_lookup",
            adjust_meta("color_lookup", SWAP_RB_LUT),
            destructive_op("color_lookup", SWAP_RB_LUT),
            &house,
            true,
        ),
        (
            "color_lookup-strength",
            adjust_meta("color_lookup", HALF_STRENGTH_LUT),
            destructive_op("color_lookup", HALF_STRENGTH_LUT),
            &house,
            true,
        ),
    ];
    for (tag, meta, destructive, background, exact) in cases {
        let doc = adjustment_fixture_on(&dir, tag, &meta, background);
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
        let backdrop = open_image(&dir, &format!("{tag}-ref.png"), background);
        let filtered = destructive(backdrop);
        assert!(!filtered.is_null(), "{tag}: destructive filter failed");
        let expected = img_pixels(filtered);
        assert_ne!(
            expected,
            *background.as_raw(),
            "{tag}: a row whose parameters change nothing would pass vacuously"
        );

        // The 2x2 magenta pixels must NOT appear: the whole canvas gets the
        // adjustment, nothing gets the layer's pixels.
        let flat = flat_pixels(doc);
        if exact {
            assert_identical(&flat, &expected, tag);
        } else {
            assert_close(&flat, &expected, tag);
        }

        unsafe { rz_image_free(filtered) };
        unsafe { rz_image_free(backdrop) };
        unsafe { rz_doc_free(doc) };
    }
}

/// The parity table above runs on 24 pixels, which is enough to catch a
/// wrong formula and nowhere near enough to catch a wrong ROUNDING: a
/// one-ULP slip only shows where the exact result lands on a half-code
/// (30.5/255), and 24 pixels rarely land on one. This row set is the same
/// invariant over 65 536 pixels — every red and every green level, a third
/// channel that walks — with parameters chosen to produce halves often
/// (a 0.5/0.5 channel mix is a half-code whenever r + g is odd).
///
/// It covers the LEGACY ops as well as the new ones: the drift this pins
/// was in the compositor's opacity lerp, not in any one op's math, so
/// `grayscale` and `sepia` were subject to it too.
#[test]
fn full_strength_adjustment_layer_is_byte_identical_over_every_level() {
    let dir = TempDir::new().unwrap();
    // 256x256: red = x, green = y, blue walks, so every 8-bit level of the
    // two channels the mixes below read appears in every combination.
    let wide = opaque_pattern(256, 256);
    let cases: Vec<(&str, String, Filter)> = vec![
        // The two legacy ops the end-to-end sweep caught drifting. Their
        // reference here is the ONE twin, not `rz_image_grayscale` /
        // `rz_image_sepia`, which are separate 0..255-space implementations
        // predating it (see `assert_close`).
        (
            "grayscale",
            adjust_meta("grayscale", "{}"),
            destructive_op("grayscale", "{}"),
        ),
        (
            "sepia",
            adjust_meta("sepia", "{}"),
            destructive_op("sepia", "{}"),
        ),
        (
            "channel_mixer",
            adjust_meta(
                "channel_mixer",
                "{\"green\":{\"r\":0.5,\"g\":0.5,\"b\":0},\"red\":{\"r\":0.5,\"b\":0.5}}",
            ),
            destructive_op(
                "channel_mixer",
                "{\"green\":{\"r\":0.5,\"g\":0.5,\"b\":0},\"red\":{\"r\":0.5,\"b\":0.5}}",
            ),
        ),
        (
            "black_and_white",
            adjust_meta(
                "black_and_white",
                "{\"reds\":0.5,\"greens\":0.5,\"blues\":0.5}",
            ),
            destructive_op(
                "black_and_white",
                "{\"reds\":0.5,\"greens\":0.5,\"blues\":0.5}",
            ),
        ),
        (
            "hue_saturation",
            adjust_meta("hue_saturation", "{\"hue\":30,\"saturation\":0.25}"),
            destructive_op("hue_saturation", "{\"hue\":30,\"saturation\":0.25}"),
        ),
        (
            "vibrance",
            adjust_meta("vibrance", "{\"vibrance\":0.5,\"saturation\":0.25}"),
            destructive_op("vibrance", "{\"vibrance\":0.5,\"saturation\":0.25}"),
        ),
        (
            "selective_color",
            adjust_meta(
                "selective_color",
                "{\"reds\":{\"c\":0.25},\"neutrals\":{\"k\":0.125}}",
            ),
            destructive_op(
                "selective_color",
                "{\"reds\":{\"c\":0.25},\"neutrals\":{\"k\":0.125}}",
            ),
        ),
    ];
    for (tag, meta, destructive) in cases {
        let doc = adjustment_fixture_on(&dir, tag, &meta, &wide);
        let backdrop = open_image(&dir, &format!("{tag}-wide-ref.png"), &wide);
        let filtered = destructive(backdrop);
        assert!(!filtered.is_null(), "{tag}: destructive filter failed");
        let expected = img_pixels(filtered);
        assert_ne!(
            expected,
            *wide.as_raw(),
            "{tag}: a row whose parameters change nothing would pass vacuously"
        );
        assert_identical(&flat_pixels(doc), &expected, tag);
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

    // A 33-stop gradient: one past what the ONE gradient parser accepts.
    let thirty_three_stops = format!(
        "{{\"gradient\":{{\"stops\":[{}]}}}}",
        (0..33)
            .map(|i| format!(
                "{{\"position\":{},\"color\":\"#000000\"}}",
                f64::from(i) / 32.0
            ))
            .collect::<Vec<_>>()
            .join(",")
    );
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
        // The phase-5 ops. Each refusal is a DIFFERENT shape of mistake:
        // a value past a range end, a nested object of the wrong type, a
        // required key missing, and a table whose length disagrees with the
        // declared size.
        adjust_meta("exposure", "{\"exposure\":25}"),
        adjust_meta("exposure", "{\"gamma\":0}"),
        adjust_meta("shadows_highlights", "{\"shadows\":\"lift\"}"),
        adjust_meta("shadows_highlights", "{\"shadows\":{\"tone\":0}}"),
        adjust_meta("shadows_highlights", "{\"radius\":2000}"),
        adjust_meta("white_balance", "{\"temperature\":1000}"),
        adjust_meta("white_balance", "{\"tint\":200}"),
        adjust_meta("vibrance", "{\"vibrance\":1.5}"),
        adjust_meta("hue_saturation", "{\"bands\":{\"reds\":7}}"),
        adjust_meta("hue_saturation", "{\"colorize_hue\":360}"),
        adjust_meta("color_balance", "{\"midtones\":{\"cyan_red\":2}}"),
        adjust_meta("color_balance", "{\"preserve_luminosity\":\"yes\"}"),
        adjust_meta("black_and_white", "{\"tint_color\":\"navy\"}"),
        adjust_meta("photo_filter", "{\"density\":1.2}"),
        adjust_meta("channel_mixer", "{\"gray\":{\"r\":3}}"),
        adjust_meta("selective_color", "{\"method\":\"perceptual\"}"),
        adjust_meta("selective_color", "{\"whites\":{\"k\":-2}}"),
        adjust_meta("gradient_map", "{\"gradient\":{\"stops\":[]}}"),
        adjust_meta("gradient_map", &thirty_three_stops),
        adjust_meta("color_lookup", "{}"),
        adjust_meta("color_lookup", "{\"kind\":\"3d\",\"size\":2}"),
        adjust_meta(
            "color_lookup",
            "{\"kind\":\"3d\",\"size\":3,\"table\":\"AAAA\"}",
        ),
        adjust_meta(
            "color_lookup",
            "{\"kind\":\"4d\",\"size\":2,\"table\":\"AAAA\"}",
        ),
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
        // Every phase-5 op is valid with no params at all except
        // `color_lookup`, whose table has no meaningful default.
        adjust_meta("exposure", "{}"),
        adjust_meta("shadows_highlights", "{}"),
        adjust_meta("white_balance", "{}"),
        adjust_meta("vibrance", "{}"),
        adjust_meta("hue_saturation", "{}"),
        adjust_meta("color_balance", "{}"),
        adjust_meta("black_and_white", "{}"),
        adjust_meta("photo_filter", "{}"),
        adjust_meta("channel_mixer", "{}"),
        adjust_meta("selective_color", "{}"),
        adjust_meta("gradient_map", "{}"),
        "{\"type\":\"adjust\",\"op\":\"exposure\"}".to_string(),
        adjust_meta("color_lookup", SWAP_RB_LUT),
        adjust_meta("color_lookup", HALF_STRENGTH_LUT),
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
