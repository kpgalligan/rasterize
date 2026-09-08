//! Color Overlay (work item E5): the shape filled with one colour above the
//! pixels at the effect's own blend mode and opacity. Every oracle here is
//! closed-form — the W3C reference composite (`common::ref_composite`) over
//! the rect geometry of the fixture, chained in f32 and quantized once the
//! way the accumulator is — never a golden image. The key case is
//! Photoshop's default "Blend Interior Effects as Group: off": a
//! Multiply-blend LAYER with a white Normal overlay renders WHITE, because
//! the overlay blends with its own mode against the backdrop while the
//! layer's mode applies to its pixels only. Everything is black-box through
//! the FFI: `styled` sets the style through `rz_doc_set_layer_style`, and
//! the projection is read through `rz_doc_flattened`.

use std::ffi::c_int;

use image::RgbaImage;
use rasterize_core::doc::{BlendMode, MaskKind, RzDocument};
use rasterize_core::ffi_doc::*;
use rasterize_core::ffi_style::*;

mod common;
use common::*;

// ---------------------------------------------------------------- helpers --

/// A 20x16 white canvas under an 8x6 rect at (5, 4) — every side clear of
/// the border, so the offset tests below are the only ones that clip.
const CANVAS: (u32, u32) = (20, 16);
const RECT: (i32, i32, u32, u32) = (5, 4, 8, 6);
/// The rect colour: mid-range in every channel so every blend mode in the
/// loop below differs from Normal.
const C: [u8; 4] = [30, 200, 120, 255];
/// The overlay colour, as the JSON writes it and as bytes.
const O_HEX: &str = "#c850a0";
const O: [u8; 4] = [200, 80, 160, 255];
const GREY: [u8; 4] = [128, 128, 128, 255];
const CLEAR: [u8; 4] = [0, 0, 0, 0];

fn rect_doc() -> RzDocument {
    rect_layer_doc(CANVAS, RECT, C)
}

/// One colour-overlay style: `extra` is spliced into the top level (e.g.
/// `"fill_opacity":0,`) for the blending-option tests.
fn overlay(blend: &str, color: &str, opacity: f32, extra: &str) -> String {
    format!(
        "{{{extra}\"effects\":[{{\"type\":\"color_overlay\",\"blend\":\"{blend}\",\
         \"color\":\"{color}\",\"opacity\":{opacity}}}]}}"
    )
}

/// The projection through `rz_doc_flattened` on a boxed copy of `doc`.
fn flat(doc: &RzDocument) -> RgbaImage {
    let handle = Box::into_raw(Box::new(doc.clone()));
    let bytes = flat_pixels(handle);
    unsafe { rz_doc_free(handle) };
    RgbaImage::from_raw(doc.width, doc.height, bytes).expect("flattened pixels fit the canvas")
}

/// `rz_doc_layer_has_style` on a boxed copy of `doc`.
fn has_style(doc: &RzDocument, idx: usize) -> bool {
    let handle = Box::into_raw(Box::new(doc.clone()));
    let has = unsafe { rz_doc_layer_has_style(handle, idx) };
    unsafe { rz_doc_free(handle) };
    has
}

/// `rz_doc_layer_style` on a boxed copy of `doc`.
fn style_json(doc: &RzDocument, idx: usize) -> Option<String> {
    let handle = Box::into_raw(Box::new(doc.clone()));
    let json = ffi_style(handle, idx);
    unsafe { rz_doc_free(handle) };
    json
}

fn px(flat: &RgbaImage, x: u32, y: u32) -> [u8; 4] {
    flat.get_pixel(x, y).0
}

fn quantized(v: [f32; 4]) -> [u8; 4] {
    [
        (v[0] * 255.0).round() as u8,
        (v[1] * 255.0).round() as u8,
        (v[2] * 255.0).round() as u8,
        (v[3] * 255.0).round() as u8,
    ]
}

/// The W3C source-over chain: `bg`, then each `(source, opacity, mode)` in
/// order — the source's own alpha times `opacity` is the coverage — kept in
/// f32 and quantized once at the end, exactly the accumulator's rule.
fn chain(bg: [u8; 4], steps: &[([u8; 4], f32, c_int)]) -> [u8; 4] {
    let mut acc = to_unit(bg);
    for &(src, opacity, mode) in steps {
        acc = ref_composite(acc, to_unit(src), opacity, mode);
    }
    quantized(acc)
}

fn in_rect(rect: (i32, i32, u32, u32), x: u32, y: u32) -> bool {
    let (x, y) = (i64::from(x), i64::from(y));
    x >= i64::from(rect.0)
        && y >= i64::from(rect.1)
        && x < i64::from(rect.0) + i64::from(rect.2)
        && y < i64::from(rect.1) + i64::from(rect.3)
}

/// Every pixel inside `rect` is `inside` (exactly, or ±1 per colour channel
/// with alpha exact when `exact` is false) and every other pixel is exactly
/// `outside`.
fn assert_partition(
    flat: &RgbaImage,
    rect: (i32, i32, u32, u32),
    inside: [u8; 4],
    exact: bool,
    outside: [u8; 4],
    what: &str,
) {
    for y in 0..flat.height() {
        for x in 0..flat.width() {
            let got = px(flat, x, y);
            let at = format!("{what} at ({x},{y})");
            if in_rect(rect, x, y) {
                if exact {
                    assert_eq!(got, inside, "{at}: inside the rect");
                } else {
                    assert_close(&got, &inside, &at);
                }
            } else {
                assert_eq!(got, outside, "{at}: outside the rect must be untouched");
            }
        }
    }
}

// ------------------------------------------------------------- the schema --

#[test]
fn defaults_echo_canonically_and_the_echo_is_unchanged() {
    let base = rect_doc();
    let doc = styled(&base, 1, "{\"effects\":[{\"type\":\"color_overlay\"}]}");
    assert!(
        has_style(&doc, 1),
        "an enabled overlay is never an identity"
    );
    let echo = style_json(&doc, 1).expect("styled layer reports its style");
    for key in [
        "\"type\":\"color_overlay\"",
        "\"enabled\":true",
        "\"blend\":\"normal\"",
        "\"color\":\"#ff0000\"",
        "\"opacity\":1.0",
    ] {
        assert!(echo.contains(key), "canonical echo {echo} lacks {key}");
    }
    assert!(
        matches!(try_styled(&doc, 1, Some(&echo)), Ok(None)),
        "setting the echo again is a silent no-op"
    );
    // The default red renders: the rect is exactly the default colour.
    assert_partition(
        &flat(&doc),
        RECT,
        [255, 0, 0, 255],
        true,
        WHITE,
        "default overlay",
    );
    // Colours canonicalize to lowercase and opacity to four decimals.
    let doc = styled(&base, 1, &overlay("multiply", "#C850A0", 0.33333, ""));
    let echo = style_json(&doc, 1).expect("style");
    assert!(echo.contains("\"color\":\"#c850a0\""), "{echo}");
    assert!(echo.contains("\"opacity\":0.3333"), "{echo}");
    assert!(echo.contains("\"blend\":\"multiply\""), "{echo}");
}

// ------------------------------------------------------------ the oracles --

#[test]
fn a_normal_overlay_matches_the_reference_inside_the_rect_and_nothing_outside() {
    let doc = styled(&rect_doc(), 1, &overlay("normal", O_HEX, 0.6, ""));
    let want = chain(WHITE, &[(C, 1.0, BLEND_NORMAL), (O, 0.6, BLEND_NORMAL)]);
    assert_ne!(want, C, "the fixture shows the overlay");
    assert_ne!(want, O, "0.6 is not a replacement");
    assert_partition(&flat(&doc), RECT, want, false, WHITE, "normal 0.6");
}

#[test]
fn every_blend_mode_follows_the_reference_blend() {
    let base = rect_doc();
    let modes: [(&str, c_int); 14] = [
        ("normal", BLEND_NORMAL),
        ("multiply", BLEND_MULTIPLY),
        ("screen", BLEND_SCREEN),
        ("overlay", BLEND_OVERLAY),
        ("soft_light", BLEND_SOFT_LIGHT),
        ("hard_light", BLEND_HARD_LIGHT),
        ("darken", BLEND_DARKEN),
        ("lighten", BLEND_LIGHTEN),
        ("difference", BLEND_DIFFERENCE),
        ("exclusion", BLEND_EXCLUSION),
        ("color_dodge", BLEND_COLOR_DODGE),
        ("color_burn", BLEND_COLOR_BURN),
        ("linear_dodge", BLEND_ADDITION),
        ("subtract", BLEND_SUBTRACT),
    ];
    let mut seen = Vec::new();
    for (name, mode) in modes {
        let doc = styled(&base, 1, &overlay(name, O_HEX, 0.6, ""));
        let want = chain(WHITE, &[(C, 1.0, BLEND_NORMAL), (O, 0.6, mode)]);
        assert_partition(&flat(&doc), RECT, want, false, WHITE, name);
        seen.push(want);
    }
    // The fixture distinguishes the modes: Normal and Multiply, at least,
    // land on different bytes, so the loop cannot pass on a mode-blind
    // renderer.
    assert_ne!(
        seen[0], seen[1],
        "normal and multiply differ on the fixture"
    );
}

#[test]
fn full_opacity_normal_overlay_is_the_overlay_colour_exactly() {
    let doc = styled(&rect_doc(), 1, &overlay("normal", O_HEX, 1.0, ""));
    assert_partition(&flat(&doc), RECT, O, true, WHITE, "opacity 1");
}

#[test]
fn opacity_zero_and_disabled_render_nothing() {
    let base = rect_doc();
    let plain = flat(&base).into_raw();
    let off = styled(&base, 1, &overlay("normal", O_HEX, 0.0, ""));
    assert!(
        has_style(&off, 1),
        "an enabled effect at opacity 0 is stored"
    );
    assert_eq!(flat(&off).into_raw(), plain, "opacity 0 renders nothing");
    // A lone disabled effect would be an identity (cleared by the core), so
    // the disabled case rides on a fill opacity, which composites exactly
    // like the same layer opacity.
    let disabled = styled(
        &base,
        1,
        "{\"fill_opacity\":0.5,\"effects\":[{\"type\":\"color_overlay\",\"enabled\":false}]}",
    );
    assert_eq!(
        flat(&disabled).into_raw(),
        flat(&base.with_layer_opacity(1, 0.5).expect("opacity")).into_raw(),
        "a disabled overlay renders nothing"
    );
}

#[test]
fn fill_opacity_never_touches_the_overlay() {
    let base = rect_doc();
    // Fill 0: the pixels vanish, the overlay stays — the rect IS the
    // overlay colour.
    let none = styled(
        &base,
        1,
        &overlay("normal", O_HEX, 1.0, "\"fill_opacity\":0,"),
    );
    assert_partition(&flat(&none), RECT, O, true, WHITE, "fill 0");
    // Fill 0.5 under a 0.5 overlay: the pixels at half, then the overlay at
    // half over the result.
    let half = styled(
        &base,
        1,
        &overlay("normal", O_HEX, 0.5, "\"fill_opacity\":0.5,"),
    );
    let want = chain(WHITE, &[(C, 0.5, BLEND_NORMAL), (O, 0.5, BLEND_NORMAL)]);
    assert_partition(&flat(&half), RECT, want, false, WHITE, "fill 0.5");
}

/// The package model of layer opacity: `steps` chained over `bg` in f32
/// (the layer's package at opacity 1), then mixed back into `bg` at
/// `opacity` in premultiplied space, quantized once.
fn packaged(bg: [u8; 4], steps: &[([u8; 4], f32, c_int)], opacity: f32) -> [u8; 4] {
    let b = to_unit(bg);
    let mut p = b;
    for &(src, o, mode) in steps {
        p = ref_composite(p, to_unit(src), o, mode);
    }
    let alpha = b[3] + (p[3] - b[3]) * opacity;
    let mut out = [0.0f32; 4];
    for c in 0..3 {
        let (bp, pp) = (b[c] * b[3], p[c] * p[3]);
        out[c] = (bp + (pp - bp) * opacity) / alpha;
    }
    out[3] = alpha;
    quantized(out)
}

#[test]
fn layer_opacity_applies_once_to_the_packaged_pixels_and_overlay() {
    // Photoshop composites the pixels and their effects as ONE package and
    // applies the layer opacity to that: an overlay at opacity 1 on a layer
    // at 50 % is the overlay colour at 50 % over the backdrop, never a tint
    // of the pixels beneath it.
    let base = rect_doc().with_layer_opacity(1, 0.5).expect("opacity");
    let doc = styled(&base, 1, &overlay("normal", O_HEX, 1.0, ""));
    let want = packaged(
        WHITE,
        &[(C, 1.0, BLEND_NORMAL), (O, 1.0, BLEND_NORMAL)],
        0.5,
    );
    assert_partition(&flat(&doc), RECT, want, false, WHITE, "layer opacity 0.5");
    assert_ne!(
        want,
        chain(WHITE, &[(C, 0.5, BLEND_NORMAL), (O, 0.5, BLEND_NORMAL)]),
        "the per-contribution model would tint the overlay with the pixels"
    );
    // The effect's own opacity stays inside the package: the overlay at
    // 0.6 over the pixels, then the package at 0.5.
    let doc = styled(&base, 1, &overlay("normal", O_HEX, 0.6, ""));
    let want = packaged(
        WHITE,
        &[(C, 1.0, BLEND_NORMAL), (O, 0.6, BLEND_NORMAL)],
        0.5,
    );
    assert_partition(&flat(&doc), RECT, want, false, WHITE, "0.5 x 0.6");
    // The brief's figure: a red rect with a blue overlay on a layer at 50 %
    // is pure blue at 50 % — [128, 128, 255] — not [128, 64, 191].
    let red = rect_layer_doc(CANVAS, RECT, RED)
        .with_layer_opacity(1, 0.5)
        .expect("opacity");
    let doc = styled(&red, 1, &overlay("normal", "#0000ff", 1.0, ""));
    assert_partition(
        &flat(&doc),
        RECT,
        [128, 128, 255, 255],
        true,
        WHITE,
        "blue at 50 %",
    );
    // Over a transparent canvas the mix is in premultiplied space: the
    // package's colour survives at the halved alpha.
    let clear = RzDocument::from_pixels(solid(CANVAS.0, CANVAS.1, CLEAR))
        .adding_image_layer(0, solid(RECT.2, RECT.3, RED), "Rect")
        .expect("add")
        .with_layer_offset(1, RECT.0, RECT.1)
        .expect("offset")
        .with_layer_opacity(1, 0.5)
        .expect("opacity");
    let doc = styled(&clear, 1, &overlay("normal", "#0000ff", 1.0, ""));
    assert_partition(
        &flat(&doc),
        RECT,
        [0, 0, 255, 128],
        true,
        CLEAR,
        "blue at alpha 128 over nothing",
    );
}

#[test]
fn a_half_alpha_rect_carries_its_alpha_into_the_overlay() {
    let half = [C[0], C[1], C[2], 128];
    let a = 128.0 / 255.0;
    // Over white: the overlay's coverage is the rect's alpha, not the rect's
    // box — at opacity 1 it is still a 50 % mix, never the flat colour —
    // and the composite stays opaque (alpha exact).
    let doc = styled(
        &rect_layer_doc(CANVAS, RECT, half),
        1,
        &overlay("normal", O_HEX, 1.0, ""),
    );
    let want = chain(WHITE, &[(half, 1.0, BLEND_NORMAL), (O, a, BLEND_NORMAL)]);
    assert_ne!(want, O, "half coverage is not a replacement");
    assert_eq!(want[3], 255);
    assert_partition(
        &flat(&doc),
        RECT,
        want,
        false,
        WHITE,
        "half alpha over white",
    );
    // Over a transparent canvas the overlay never creates coverage outside
    // the shape (alpha stays 0 there), and inside it the alpha is the
    // source-over union of the pixels' and the overlay's coverage, exact by
    // the W3C formula — the compositor draws interior contributions
    // source-over with `sa = shape coverage x opacity` (style_composite).
    let clear = RzDocument::from_pixels(solid(CANVAS.0, CANVAS.1, CLEAR))
        .adding_image_layer(0, solid(RECT.2, RECT.3, half), "Rect")
        .expect("add")
        .with_layer_offset(1, RECT.0, RECT.1)
        .expect("offset");
    let doc = styled(&clear, 1, &overlay("normal", O_HEX, 1.0, ""));
    let want = chain(CLEAR, &[(half, 1.0, BLEND_NORMAL), (O, a, BLEND_NORMAL)]);
    assert_eq!(want[3], ((a + a * (1.0 - a)) * 255.0).round() as u8);
    assert_partition(
        &flat(&doc),
        RECT,
        want,
        false,
        CLEAR,
        "half alpha over clear",
    );
}

#[test]
fn the_layer_mask_is_part_of_the_shape() {
    // Mask: hidden left of canvas x 9, half at x 9, revealed from x 10 —
    // all inside the rect's 5..13 span.
    let sel = selection(CANVAS.0, CANVAS.1, |x, _| match x {
        0..=8 => 0,
        9 => 128,
        _ => 255,
    });
    let masked = rect_doc()
        .add_mask(1, MaskKind::FromSelection(&sel))
        .expect("mask");
    let doc = styled(&masked, 1, &overlay("normal", O_HEX, 1.0, ""));
    let image = flat(&doc);
    let a = 128.0 / 255.0;
    let half = chain(WHITE, &[(C, a, BLEND_NORMAL), (O, a, BLEND_NORMAL)]);
    for y in 0..CANVAS.1 {
        for x in 0..CANVAS.0 {
            let got = px(&image, x, y);
            let at = format!("({x},{y})");
            if !in_rect(RECT, x, y) || x <= 8 {
                // Outside the rect, or masked out: the pixels and the
                // overlay both vanish.
                assert_eq!(got, WHITE, "{at}");
            } else if x == 9 {
                assert_close(&got, &half, &at);
            } else {
                assert_eq!(got, O, "{at}: revealed");
            }
        }
    }
    // A disabled mask drops out of the shape: the whole rect is overlaid.
    let unmasked = styled(
        &masked.set_mask_enabled(1, false).expect("disable"),
        1,
        &overlay("normal", O_HEX, 1.0, ""),
    );
    assert_partition(&flat(&unmasked), RECT, O, true, WHITE, "mask disabled");
}

#[test]
fn a_multiply_layer_with_a_white_normal_overlay_renders_white() {
    // The §1.3 case: "Blend Interior Effects as Group" is off, so the
    // overlay uses ITS blend (Normal) against the backdrop and the layer's
    // Multiply applies to the pixels only. This is how everyone recolours
    // text.
    let base = RzDocument::from_pixels(solid(CANVAS.0, CANVAS.1, GREY))
        .adding_image_layer(0, solid(RECT.2, RECT.3, BLUE), "Rect")
        .expect("add")
        .with_layer_offset(1, RECT.0, RECT.1)
        .expect("offset")
        .with_layer_blend_mode(1, BlendMode::Multiply)
        .expect("blend");
    // Without the overlay the pixels multiply into the grey.
    let multiplied = chain(GREY, &[(BLUE, 1.0, BLEND_MULTIPLY)]);
    assert_ne!(multiplied, WHITE);
    assert_partition(
        &flat(&base),
        RECT,
        multiplied,
        false,
        GREY,
        "unstyled multiply layer",
    );
    // With a white Normal overlay at opacity 1 the rect is WHITE — a
    // Multiply overlay would be invisible on grey.
    let white = styled(&base, 1, &overlay("normal", "#ffffff", 1.0, ""));
    assert_partition(
        &flat(&white),
        RECT,
        WHITE,
        true,
        GREY,
        "white normal overlay",
    );
    // At 0.5 the overlay is half white over the MULTIPLIED pixels through
    // Normal, not through the layer's Multiply (which would leave them).
    let half = styled(&base, 1, &overlay("normal", "#ffffff", 0.5, ""));
    let want = chain(
        GREY,
        &[(BLUE, 1.0, BLEND_MULTIPLY), (WHITE, 0.5, BLEND_NORMAL)],
    );
    let not_want = chain(
        GREY,
        &[(BLUE, 1.0, BLEND_MULTIPLY), (WHITE, 0.5, BLEND_MULTIPLY)],
    );
    assert_ne!(want, not_want, "the fixture distinguishes the two modes");
    assert_partition(
        &flat(&half),
        RECT,
        want,
        false,
        GREY,
        "half white normal overlay",
    );
    // And the overlay's own Multiply IS honoured when asked for: white
    // multiplied in changes nothing.
    let mult = styled(&base, 1, &overlay("multiply", "#ffffff", 1.0, ""));
    assert_partition(
        &flat(&mult),
        RECT,
        multiplied,
        false,
        GREY,
        "white multiply overlay",
    );
}

#[test]
fn offsets_map_the_overlay_onto_the_canvas() {
    let style = overlay("normal", O_HEX, 1.0, "");
    // Partly off the top-left, partly off the bottom-right, and a 1x1
    // layer: only the on-canvas part of each rect is overlaid.
    let cases: [(i32, i32, u32, u32); 3] = [
        (-3, -2, 6, 5),
        (CANVAS.0 as i32 - 3, CANVAS.1 as i32 - 2, 6, 5),
        (4, 4, 1, 1),
    ];
    for rect in cases {
        let doc = styled(&rect_layer_doc(CANVAS, rect, C), 1, &style);
        assert_partition(&flat(&doc), rect, O, true, WHITE, &format!("rect {rect:?}"));
    }
}

#[test]
fn the_overlay_stays_inside_the_shape_on_a_padded_plane() {
    // A drop shadow pads the plane; the overlay's coverage is the shape,
    // 0 across the padding, so outside the rect the projection is the
    // shadow-only one byte for byte and inside it is the overlay colour.
    let shadow = "{\"type\":\"drop_shadow\",\"use_global_light\":false,\"angle\":0,\
                  \"distance\":3,\"size\":4,\"spread\":0}";
    let both = format!(
        "{{\"effects\":[{shadow},{{\"type\":\"color_overlay\",\"color\":\"{O_HEX}\",\
         \"opacity\":1}}]}}"
    );
    let base = rect_doc();
    let shadow_only = flat(&styled(&base, 1, &format!("{{\"effects\":[{shadow}]}}")));
    let image = flat(&styled(&base, 1, &both));
    let mut shadowed = 0;
    for y in 0..CANVAS.1 {
        for x in 0..CANVAS.0 {
            let got = px(&image, x, y);
            if in_rect(RECT, x, y) {
                assert_eq!(got, O, "({x},{y}) inside");
            } else {
                assert_eq!(
                    got,
                    px(&shadow_only, x, y),
                    "({x},{y}) outside is the shadow alone"
                );
                if got != WHITE {
                    shadowed += 1;
                }
            }
        }
    }
    assert!(
        shadowed > 0,
        "the fixture has a visible shadow outside the rect"
    );
}

#[test]
fn a_fully_transparent_layer_renders_nothing_but_keeps_its_style() {
    let clear_rect = rect_layer_doc(CANVAS, RECT, [C[0], C[1], C[2], 0]);
    let doc = styled(&clear_rect, 1, &overlay("normal", O_HEX, 1.0, ""));
    assert!(
        has_style(&doc, 1),
        "the style is stored (it is not an identity)"
    );
    assert_eq!(
        flat(&doc).into_raw(),
        solid(CANVAS.0, CANVAS.1, WHITE).into_raw(),
        "no shape, no overlay"
    );
}

#[test]
fn the_setter_is_pure_and_the_render_deterministic() {
    let base = rect_doc();
    let before = flat(&base).into_raw();
    let doc = styled(&base, 1, &overlay("screen", O_HEX, 0.7, ""));
    assert!(
        base.layers[1].style.is_none(),
        "the input document is unchanged"
    );
    assert!(!has_style(&base, 1));
    assert_eq!(
        flat(&base).into_raw(),
        before,
        "the input still projects the same"
    );
    // Cached and fresh renders agree: the same document twice, and an
    // independently built twin.
    let first = flat(&doc).into_raw();
    assert_eq!(flat(&doc).into_raw(), first, "second flatten (cache hit)");
    let twin = styled(&rect_doc(), 1, &overlay("screen", O_HEX, 0.7, ""));
    assert_eq!(
        flat(&twin).into_raw(),
        first,
        "an identical document renders identically"
    );
}
