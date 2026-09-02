//! Layer styles — the Stroke effect, black-box through the FFI
//! (`rz_doc_set_layer_style` + `rz_doc_flattened`) against closed-form
//! oracles: the grow/shrink-rect band geometry from the header's
//! `rz_selection_grow` / `rz_selection_shrink` contracts (an outside pixel's
//! coverage is `round(255 * clamp(r + 1 - d, 0, 1))` with `d` the Euclidean
//! distance to the nearest rect pixel; an inside pixel's shrunk coverage is
//! `round(255 * clamp(d_out - r, 0, 1))` with `d_out` the axis distance to
//! the rect's complement), the W3C reference blend for every colour, and the
//! `gradient_t` formula restated for the gradient fill. Shared fixtures live
//! in `tests/common`; the model/JSON contract is covered by `style.rs`.

use std::ffi::c_int;

use image::{Rgba, RgbaImage};
use rasterize_core::doc::{BlendMode, RzDocument};
use rasterize_core::ffi_doc::*;

mod common;
use common::*;

// ---------------------------------------------------------------- helpers --

/// A 40x32 white canvas under a 14x12 red rect at (10, 8): at least 8 px
/// from every canvas edge, so a 4 px band never touches the border, and
/// tall/wide enough that a 2 px inside band leaves an untouched interior.
const CANVAS: (u32, u32) = (40, 32);
const RECT: (i32, i32, u32, u32) = (10, 8, 14, 12);
const STROKE_BLUE: [u8; 3] = [0, 0, 255];

fn rect_doc() -> RzDocument {
    rect_layer_doc(CANVAS, RECT, RED)
}

/// `{"effects":[{"type":"stroke", <extra>}]}` — `extra` is a comma-led list
/// of extra keys (or empty).
fn stroke_json(extra: &str) -> String {
    format!("{{\"effects\":[{{\"type\":\"stroke\"{extra}}}]}}")
}

/// The projection through `rz_doc_flattened`.
fn flat(doc: &RzDocument) -> Vec<u8> {
    let handle = Box::into_raw(Box::new(doc.clone()));
    let out = flat_pixels(handle);
    unsafe { rz_doc_free(handle) };
    out
}

fn at(flat: &[u8], x: u32, y: u32) -> [u8; 4] {
    pixel(flat, CANVAS.0, x, y)
}

fn quantized(v: [f32; 4]) -> [u8; 4] {
    [
        (v[0] * 255.0).round() as u8,
        (v[1] * 255.0).round() as u8,
        (v[2] * 255.0).round() as u8,
        (v[3] * 255.0).round() as u8,
    ]
}

/// The reference composite of an opaque `color` at `coverage * opacity`
/// over `bg`, quantized once like the projection.
fn over(bg: [u8; 4], color: [u8; 3], coverage: u8, opacity: f32, mode: c_int) -> [u8; 4] {
    let src = [
        f32::from(color[0]) / 255.0,
        f32::from(color[1]) / 255.0,
        f32::from(color[2]) / 255.0,
        1.0,
    ];
    quantized(ref_composite(
        to_unit(bg),
        src,
        opacity * f32::from(coverage) / 255.0,
        mode,
    ))
}

fn in_rect(rect: (i32, i32, u32, u32), x: i64, y: i64) -> bool {
    let (x0, y0) = (i64::from(rect.0), i64::from(rect.1));
    x >= x0 && y >= y0 && x < x0 + i64::from(rect.2) && y < y0 + i64::from(rect.3)
}

/// Grow-rect closed form: the outside band `dilate(rect, r) - rect` at
/// pixel `(x, y)` — `round(255 * clamp(r + 1 - d, 0, 1))` with `d` the
/// Euclidean distance to the nearest rect pixel; 0 inside the rect.
fn outside_cov(rect: (i32, i32, u32, u32), r: f32, x: i64, y: i64) -> u8 {
    if in_rect(rect, x, y) {
        return 0;
    }
    let (x0, y0) = (i64::from(rect.0), i64::from(rect.1));
    let nx = x.clamp(x0, x0 + i64::from(rect.2) - 1);
    let ny = y.clamp(y0, y0 + i64::from(rect.3) - 1);
    let d = (((x - nx).pow(2) + (y - ny).pow(2)) as f32).sqrt();
    ((r + 1.0 - d).clamp(0.0, 1.0) * 255.0).round() as u8
}

/// Shrink-rect closed form: the inside band `rect - erode(rect, r)` at
/// pixel `(x, y)` — `255 - round(255 * clamp(d_out - r, 0, 1))` with
/// `d_out = min(x - x0 + 1, x1 - x, y - y0 + 1, y1 - y)` (the complement of
/// a rect is nearest along an axis); 0 outside the rect.
fn inside_cov(rect: (i32, i32, u32, u32), r: f32, x: i64, y: i64) -> u8 {
    if !in_rect(rect, x, y) {
        return 0;
    }
    let (x0, y0) = (i64::from(rect.0), i64::from(rect.1));
    let (x1, y1) = (x0 + i64::from(rect.2), y0 + i64::from(rect.3));
    let d_out = (x - x0 + 1).min(x1 - x).min(y - y0 + 1).min(y1 - y) as f32;
    255 - ((d_out - r).clamp(0.0, 1.0) * 255.0).round() as u8
}

/// Every pixel of the projection of `doc` against the outside band
/// `outside_cov(rect, r_out)` (Below the pixels) and the inside band
/// `inside_cov(rect, r_in)` (over them), both in `color` at opacity 1
/// Normal: a band pixel is the reference composite, a rect pixel off the
/// inside band is `rect_color`, everything else white.
fn assert_bands(
    doc: &RzDocument,
    rect: (i32, i32, u32, u32),
    rect_color: [u8; 4],
    color: [u8; 3],
    r_out: f32,
    r_in: f32,
    what: &str,
) {
    let img = flat(doc);
    let mut band_pixels = 0;
    for y in 0..CANVAS.1 {
        for x in 0..CANVAS.0 {
            let got = at(&img, x, y);
            let (xi, yi) = (i64::from(x), i64::from(y));
            let label = format!("{what} ({x},{y})");
            if in_rect(rect, xi, yi) {
                let cov = if r_in > 0.0 {
                    inside_cov(rect, r_in, xi, yi)
                } else {
                    0
                };
                if cov == 0 {
                    assert_eq!(got, rect_color, "{label}: rect pixel");
                } else {
                    band_pixels += 1;
                    assert_close(
                        &got,
                        &over(rect_color, color, cov, 1.0, BLEND_NORMAL),
                        &format!("{label}: inside band {cov}"),
                    );
                }
                continue;
            }
            let cov = if r_out > 0.0 {
                outside_cov(rect, r_out, xi, yi)
            } else {
                0
            };
            if cov == 0 {
                assert_eq!(got, WHITE, "{label}: outside the band");
            } else {
                band_pixels += 1;
                assert_close(
                    &got,
                    &over(WHITE, color, cov, 1.0, BLEND_NORMAL),
                    &format!("{label}: outside band {cov}"),
                );
            }
        }
    }
    assert!(band_pixels > 0, "{what}: the band covers no pixel");
}

// ----------------------------------------------------------- the oracles --

#[test]
fn outside_stroke_is_the_grown_rect_minus_the_rect() {
    let doc = styled(
        &rect_doc(),
        1,
        &stroke_json(",\"size\":3,\"position\":\"outside\",\"color\":\"#0000ff\""),
    );
    assert_bands(&doc, RECT, RED, STROKE_BLUE, 3.0, 0.0, "outside 3");
    // Pins independent of the loop: 3 px out is band, 4 px out is not, and
    // the diagonal corner rounds (d = sqrt(18) = 4.24 > 4 at (7, 5)).
    let img = flat(&doc);
    assert_eq!(at(&img, 7, 12), [0, 0, 255, 255], "3 px left of the rect");
    assert_eq!(at(&img, 6, 12), WHITE, "4 px left of the rect");
    assert_eq!(at(&img, 7, 5), WHITE, "the rounded corner");
    assert_eq!(at(&img, 10, 8), RED, "the rect's corner pixel is the rect");
}

#[test]
fn inside_stroke_is_the_rect_minus_the_shrunk_rect() {
    let doc = styled(
        &rect_doc(),
        1,
        &stroke_json(",\"size\":2,\"position\":\"inside\",\"color\":\"#0000ff\""),
    );
    assert_bands(&doc, RECT, RED, STROKE_BLUE, 0.0, 2.0, "inside 2");
    let img = flat(&doc);
    assert_eq!(
        at(&img, 11, 13),
        [0, 0, 255, 255],
        "2 px in from the left edge"
    );
    assert_eq!(at(&img, 12, 13), RED, "3 px in is the rect");
    assert_eq!(at(&img, 9, 13), WHITE, "nothing outside the rect");
}

#[test]
fn center_stroke_splits_the_width_across_the_contour() {
    let center = styled(
        &rect_doc(),
        1,
        &stroke_json(",\"size\":4,\"position\":\"center\",\"color\":\"#0000ff\""),
    );
    assert_bands(&center, RECT, RED, STROKE_BLUE, 2.0, 2.0, "center 4");
    // outside 2 + inside 2 == center 4, pixel for pixel: the two halves are
    // exactly the two single-sided strokes at half the width.
    let outside = styled(
        &rect_doc(),
        1,
        &stroke_json(",\"size\":2,\"position\":\"outside\",\"color\":\"#0000ff\""),
    );
    let inside = styled(
        &rect_doc(),
        1,
        &stroke_json(",\"size\":2,\"position\":\"inside\",\"color\":\"#0000ff\""),
    );
    let (c, o, i) = (flat(&center), flat(&outside), flat(&inside));
    for y in 0..CANVAS.1 {
        for x in 0..CANVAS.0 {
            let (xi, yi) = (i64::from(x), i64::from(y));
            let want = if in_rect(RECT, xi, yi) {
                at(&i, x, y)
            } else {
                at(&o, x, y)
            };
            assert_eq!(at(&c, x, y), want, "({x},{y})");
        }
    }
}

#[test]
fn gradient_fill_follows_the_layer_box() {
    // Linear at angle 0 across the layer box: column x of the layer has
    // t = (x - x0 + 0.5) / lw, clamped beyond the rect's ends (the band
    // outside the box holds the end stops' colours).
    let gradient = |extra: &str| {
        stroke_json(&format!(
            ",\"size\":3,\"position\":\"outside\",\"fill_type\":\"gradient\",\
             \"gradient\":{{\"style\":\"linear\",\"angle\":0{extra}}}"
        ))
    };
    let t_of = |x: u32| (x as f32 - RECT.0 as f32 + 0.5) / RECT.2 as f32;
    let grey = |t: f32| {
        let t = t.clamp(0.0, 1.0);
        quantized(ref_composite(
            to_unit(WHITE),
            [t, t, t, 1.0],
            1.0,
            BLEND_NORMAL,
        ))
    };
    let img = flat(&styled(&rect_doc(), 1, &gradient("")));
    let row = RECT.1 as u32 - 1; // 1 px above the rect: band coverage 255
    for x in [10u32, 16, 23] {
        assert_close(
            &at(&img, x, row),
            &grey(t_of(x)),
            &format!("column {x} at t {}", t_of(x)),
        );
    }
    assert_eq!(
        at(&img, 8, row),
        [0, 0, 0, 255],
        "past the left end: the first stop"
    );
    assert_eq!(at(&img, 10, 8), RED, "the rect is untouched");

    // `reverse` flips t.
    let reversed = flat(&styled(&rect_doc(), 1, &gradient(",\"reverse\":true")));
    for x in [10u32, 16, 23] {
        assert_close(
            &at(&reversed, x, row),
            &grey(1.0 - t_of(x)),
            &format!("reversed column {x}"),
        );
    }

    // Angle 90 runs bottom to top: row y of the layer has
    // t = (lh - (y - y0) - 0.5) / lh, checked down the band left of the rect.
    let up = flat(&styled(
        &rect_doc(),
        1,
        &stroke_json(
            ",\"size\":3,\"position\":\"outside\",\"fill_type\":\"gradient\",\
             \"gradient\":{\"style\":\"linear\",\"angle\":90}",
        ),
    ));
    let col = RECT.0 as u32 - 1;
    for y in [8u32, 13, 19] {
        let t = (RECT.3 as f32 - (y as f32 - RECT.1 as f32) - 0.5) / RECT.3 as f32;
        assert_close(&at(&up, col, y), &grey(t), &format!("row {y} at t {t}"));
    }
    assert!(
        at(&up, col, 8)[0] > at(&up, col, 19)[0],
        "brighter at the top"
    );
}

#[test]
fn gradient_stop_opacity_scales_the_band() {
    // Black to transparent black across the layer box: the band's coverage
    // at column x is round(255 * (1 - t)), so the pixel is white lifted by
    // exactly that coverage of black.
    let doc = styled(
        &rect_doc(),
        1,
        &stroke_json(
            ",\"size\":3,\"position\":\"outside\",\"fill_type\":\"gradient\",\
             \"gradient\":{\"style\":\"linear\",\"angle\":0,\"stops\":[\
             {\"position\":0,\"color\":\"#000000\",\"opacity\":1},\
             {\"position\":1,\"color\":\"#000000\",\"opacity\":0}]}",
        ),
    );
    let img = flat(&doc);
    let row = RECT.1 as u32 - 1;
    for x in RECT.0 as u32..RECT.0 as u32 + RECT.2 {
        let t = (x as f32 - RECT.0 as f32 + 0.5) / RECT.2 as f32;
        let cov = (255.0 * (1.0 - t)).round() as u8;
        assert_close(
            &at(&img, x, row),
            &over(WHITE, [0, 0, 0], cov, 1.0, BLEND_NORMAL),
            &format!("column {x} coverage {cov}"),
        );
    }
    assert_eq!(at(&img, 8, row), [0, 0, 0, 255], "the opaque end");
    assert_eq!(
        at(&img, 25, row),
        WHITE,
        "the transparent end draws nothing"
    );
}

#[test]
fn gradient_aligned_with_the_canvas_uses_the_canvas_box() {
    // Without align_with_layer the box is the canvas: at angle 0 column x of
    // the CANVAS has t = (x + 0.5) / canvas width, wherever the layer sits.
    let json = stroke_json(
        ",\"size\":3,\"position\":\"outside\",\"fill_type\":\"gradient\",\
         \"gradient\":{\"style\":\"linear\",\"angle\":0,\"align_with_layer\":false}",
    );
    let grey = |x: u32| {
        let t = (x as f32 + 0.5) / CANVAS.0 as f32;
        quantized(ref_composite(
            to_unit(WHITE),
            [t, t, t, 1.0],
            1.0,
            BLEND_NORMAL,
        ))
    };
    let doc = styled(&rect_doc(), 1, &json);
    let img = flat(&doc);
    let row = RECT.1 as u32 - 1;
    for x in [10u32, 16, 23] {
        assert_close(&at(&img, x, row), &grey(x), &format!("column {x}"));
    }
    // Moving the layer keeps the gradient on the canvas (the render cache
    // keys on the offset for canvas-aligned styles): the band 4 px further
    // right now shows the canvas column's value, not the layer column's.
    let moved = doc.with_layer_offset(1, RECT.0 + 4, RECT.1).expect("move");
    let moved_img = flat(&moved);
    assert_close(&at(&moved_img, 14, row), &grey(14), "moved column 14");
    assert_ne!(
        at(&moved_img, 14, row),
        at(&img, 10, row),
        "the layer's first column changed colour with the move"
    );
}

#[test]
fn blend_mode_and_opacity_follow_the_reference() {
    // An inside band over the red rect distinguishes Screen from Normal
    // (screen(red, blue) is magenta); an outside band over white checks
    // the opacity path.
    let inside = |blend: &str| {
        stroke_json(&format!(
            ",\"size\":2,\"position\":\"inside\",\"color\":\"#0000ff\",\
             \"opacity\":0.6,\"blend\":\"{blend}\""
        ))
    };
    let screen = flat(&styled(&rect_doc(), 1, &inside("screen")));
    let normal = flat(&styled(&rect_doc(), 1, &inside("normal")));
    let want_screen = over(RED, STROKE_BLUE, 255, 0.6, BLEND_SCREEN);
    let want_normal = over(RED, STROKE_BLUE, 255, 0.6, BLEND_NORMAL);
    assert_ne!(
        want_screen, want_normal,
        "the fixture distinguishes the modes"
    );
    assert_close(&at(&screen, 10, 13), &want_screen, "screen band");
    assert_close(&at(&normal, 10, 13), &want_normal, "normal band");
    assert_eq!(at(&screen, 13, 13), RED, "the interior is untouched");

    let outside = flat(&styled(
        &rect_doc(),
        1,
        &stroke_json(",\"size\":3,\"position\":\"outside\",\"color\":\"#0000ff\",\"opacity\":0.4"),
    ));
    assert_close(
        &at(&outside, 8, 13),
        &over(WHITE, STROKE_BLUE, 255, 0.4, BLEND_NORMAL),
        "outside band at 40 %",
    );
    // The anti-aliased rim scales by coverage AND opacity.
    let cov = outside_cov(RECT, 3.0, 7, 6);
    assert!(
        cov > 0 && cov < 255,
        "the corner pixel is on the rim ({cov})"
    );
    assert_close(
        &at(&outside, 7, 6),
        &over(WHITE, STROKE_BLUE, cov, 0.4, BLEND_NORMAL),
        "rim pixel at 40 %",
    );
}

#[test]
fn stroke_keeps_its_own_blend_on_a_multiply_layer() {
    let grey = [128, 128, 128, 255];
    let base = RzDocument::from_pixels(solid(CANVAS.0, CANVAS.1, grey))
        .adding_image_layer(0, solid(RECT.2, RECT.3, BLUE), "Rect")
        .expect("add")
        .with_layer_offset(1, RECT.0, RECT.1)
        .expect("offset")
        .with_layer_blend_mode(1, BlendMode::Multiply)
        .expect("blend");
    let white = [255, 255, 255];
    let want_normal = over(grey, white, 255, 0.75, BLEND_NORMAL);
    let not_want = over(grey, white, 255, 0.75, BLEND_MULTIPLY);
    assert_ne!(want_normal, not_want, "the fixture distinguishes the modes");

    // Below placement: the outside band ignores the layer's Multiply.
    let outside = flat(&styled(
        &base,
        1,
        &stroke_json(
            ",\"size\":3,\"position\":\"outside\",\"color\":\"#ffffff\",\
             \"opacity\":0.75,\"blend\":\"normal\"",
        ),
    ));
    assert_close(&at(&outside, 8, 13), &want_normal, "outside band");
    let pixel_want = quantized(ref_composite(
        to_unit(grey),
        to_unit(BLUE),
        1.0,
        BLEND_MULTIPLY,
    ));
    assert_close(
        &at(&outside, 16, 13),
        &pixel_want,
        "the pixels still multiply",
    );

    // Interior placement: the inside band composites with Normal over the
    // multiplied pixels.
    let inside = flat(&styled(
        &base,
        1,
        &stroke_json(
            ",\"size\":2,\"position\":\"inside\",\"color\":\"#ffffff\",\
             \"opacity\":0.75,\"blend\":\"normal\"",
        ),
    ));
    let want_inside = quantized(ref_composite(
        to_unit(pixel_want),
        [1.0, 1.0, 1.0, 1.0],
        0.75,
        BLEND_NORMAL,
    ));
    assert_close(&at(&inside, 10, 13), &want_inside, "inside band");
    assert_close(
        &at(&inside, 16, 13),
        &pixel_want,
        "the interior still multiplies",
    );
}

#[test]
fn disabled_zero_opacity_and_zero_size_render_nothing() {
    let plain = flat(&rect_doc());
    // A disabled stroke alone is an identity style: the core clears it
    // rather than storing it (a silent refusal on an unstyled layer).
    assert!(
        matches!(
            try_styled(&rect_doc(), 1, Some(&stroke_json(",\"enabled\":false"))),
            Ok(None)
        ),
        "a lone disabled stroke is identity"
    );
    // Beside an effect that renders nothing the style is stored and the
    // disabled stroke still draws nothing.
    let disabled = styled(
        &rect_doc(),
        1,
        "{\"effects\":[{\"type\":\"stroke\",\"enabled\":false},\
         {\"type\":\"drop_shadow\",\"opacity\":0}]}",
    );
    assert!(disabled.layers[1].style.is_some(), "stored");
    assert_eq!(flat(&disabled), plain, "disabled");
    for extra in [
        ",\"opacity\":0",
        ",\"size\":0",
        ",\"size\":0,\"position\":\"inside\"",
    ] {
        let doc = styled(&rect_doc(), 1, &stroke_json(extra));
        assert!(doc.layers[1].style.is_some(), "{extra}: stored");
        assert_eq!(flat(&doc), plain, "{extra}");
    }
}

#[test]
fn fill_opacity_zero_leaves_the_stroke_intact() {
    // Outlined text at 0 % fill: the band draws, the pixels do not.
    let inside = flat(&styled(
        &rect_doc(),
        1,
        "{\"fill_opacity\":0,\"effects\":[{\"type\":\"stroke\",\"size\":2,\
         \"position\":\"inside\",\"color\":\"#0000ff\"}]}",
    ));
    assert_eq!(at(&inside, 10, 13), [0, 0, 255, 255], "the inside band");
    assert_eq!(
        at(&inside, 16, 13),
        WHITE,
        "the interior shows the backdrop"
    );
    assert_eq!(at(&inside, 9, 13), WHITE, "nothing outside");

    let outside = flat(&styled(
        &rect_doc(),
        1,
        "{\"fill_opacity\":0,\"effects\":[{\"type\":\"stroke\",\"size\":3,\
         \"position\":\"outside\",\"color\":\"#0000ff\"}]}",
    ));
    assert_eq!(at(&outside, 8, 13), [0, 0, 255, 255], "the outside band");
    assert_eq!(
        at(&outside, 16, 13),
        WHITE,
        "the rect's pixels are invisible"
    );
    assert_eq!(
        at(&outside, 10, 8),
        WHITE,
        "the band stays outside the shape"
    );
}

#[test]
fn offset_layers_map_the_band_onto_the_canvas() {
    // Partly off the top-left corner and partly off the bottom-right: the
    // closed form uses the rect's true (off-canvas) coordinates and the band
    // is simply clipped.
    for rect in [(-3, -2, 14, 12), (30, 24, 14, 12)] {
        let doc = styled(
            &rect_layer_doc(CANVAS, rect, RED),
            1,
            &stroke_json(",\"size\":4,\"position\":\"center\",\"color\":\"#0000ff\""),
        );
        assert_bands(
            &doc,
            rect,
            RED,
            STROKE_BLUE,
            2.0,
            2.0,
            &format!("rect {rect:?}"),
        );
    }
}

#[test]
fn transparent_layers_render_nothing() {
    let empty = RzDocument::from_pixels(solid(CANVAS.0, CANVAS.1, WHITE))
        .adding_image_layer(0, solid(RECT.2, RECT.3, [0, 0, 0, 0]), "Empty")
        .expect("add")
        .with_layer_offset(1, RECT.0, RECT.1)
        .expect("offset");
    let white = flat(&empty);
    assert!(white.chunks(4).all(|p| p == WHITE), "the fixture is white");
    for position in ["outside", "inside", "center"] {
        let doc = styled(
            &empty,
            1,
            &stroke_json(&format!(
                ",\"size\":4,\"position\":\"{position}\",\"color\":\"#0000ff\""
            )),
        );
        assert_eq!(flat(&doc), white, "{position}: no shape, no band");
    }
}

#[test]
fn a_single_pixel_layer_strokes_into_a_disc() {
    // The dilated-point closed form: every non-seed pixel's nearest inside
    // pixel is the seed, so the outside band is round(255 * clamp(r + 1 - d)).
    let (cx, cy) = (20i64, 16i64);
    let seed = rect_layer_doc(CANVAS, (cx as i32, cy as i32, 1, 1), RED);
    let outside = flat(&styled(
        &seed,
        1,
        &stroke_json(",\"size\":3,\"position\":\"outside\",\"color\":\"#0000ff\""),
    ));
    for y in 0..CANVAS.1 {
        for x in 0..CANVAS.0 {
            let (dx, dy) = (i64::from(x) - cx, i64::from(y) - cy);
            let got = at(&outside, x, y);
            if dx == 0 && dy == 0 {
                assert_eq!(got, RED, "the seed");
                continue;
            }
            let d = ((dx * dx + dy * dy) as f32).sqrt();
            let cov = ((3.0 + 1.0 - d).clamp(0.0, 1.0) * 255.0).round() as u8;
            if cov == 0 {
                assert_eq!(got, WHITE, "({x},{y}) outside the disc");
            } else {
                assert_close(
                    &got,
                    &over(WHITE, STROKE_BLUE, cov, 1.0, BLEND_NORMAL),
                    &format!("({x},{y}) disc coverage {cov}"),
                );
            }
        }
    }
    // Inside: the lone pixel is 1 px from the outside, so a 2 px band
    // covers it entirely — and nothing else.
    let inside = flat(&styled(
        &seed,
        1,
        &stroke_json(",\"size\":2,\"position\":\"inside\",\"color\":\"#0000ff\""),
    ));
    assert_eq!(at(&inside, cx as u32, cy as u32), [0, 0, 255, 255]);
    assert_eq!(at(&inside, cx as u32 + 1, cy as u32), WHITE);
}

#[test]
fn a_half_alpha_shape_is_knocked_out_of_the_band_in_proportion() {
    // The outside band is knocked out by the layer's own coverage, the
    // drop shadow's proportion: a rect at alpha 128 keeps `255 - 128 = 127`
    // of the band under its own pixels, which then composite over it at
    // 128/255 — at most a quarter of stroke tint over the backdrop, never
    // a solid fill of stroke colour under a half-transparent layer. The
    // inside band keeps 128 over them. Both composite in f32 and quantize
    // once, like the oracle chain.
    let half = [255, 0, 0, 128];
    let doc = rect_layer_doc(CANVAS, RECT, half);
    let outside = flat(&styled(
        &doc,
        1,
        &stroke_json(",\"size\":3,\"position\":\"outside\",\"color\":\"#0000ff\""),
    ));
    let under = ref_composite(
        to_unit(WHITE),
        [0.0, 0.0, 1.0, 1.0],
        127.0 / 255.0,
        BLEND_NORMAL,
    );
    let want_under = quantized(ref_composite(under, to_unit(half), 1.0, BLEND_NORMAL));
    assert_close(
        &at(&outside, 16, 13),
        &want_under,
        "band under a half-alpha pixel",
    );
    // The white backdrop still shows through the thinned band: R = 192,
    // where a band at 255 under the pixels would leave the solid purple
    // [128, 0, 128].
    let interior = at(&outside, 16, 13);
    assert!(
        interior[0] > 160,
        "a quarter of stroke tint, not a solid fill: {interior:?}"
    );
    assert_close(
        &at(&outside, 8, 13),
        &over(WHITE, STROKE_BLUE, 255, 1.0, BLEND_NORMAL),
        "full band beside it",
    );

    let inside = flat(&styled(
        &doc,
        1,
        &stroke_json(",\"size\":2,\"position\":\"inside\",\"color\":\"#0000ff\""),
    ));
    let pixels = ref_composite(to_unit(WHITE), to_unit(half), 1.0, BLEND_NORMAL);
    let want_band = quantized(ref_composite(
        pixels,
        [0.0, 0.0, 1.0, 1.0],
        128.0 / 255.0,
        BLEND_NORMAL,
    ));
    assert_close(
        &at(&inside, 10, 13),
        &want_band,
        "half band over the pixels",
    );
    assert_close(
        &at(&inside, 16, 13),
        &quantized(pixels),
        "the interior is the pixels",
    );
}

/// The white canvas under a black 10x6 rect at (14, 12) whose LEFT column
/// is at `edge_alpha` — an anti-aliased edge.
fn aa_edge_doc(edge_alpha: u8) -> RzDocument {
    let mut px = RgbaImage::from_pixel(10, 6, Rgba([0, 0, 0, 255]));
    for y in 0..6 {
        px.put_pixel(0, y, Rgba([0, 0, 0, edge_alpha]));
    }
    RzDocument::from_pixels(solid(CANVAS.0, CANVAS.1, WHITE))
        .adding_image_layer(0, px, "Text")
        .expect("add layer")
        .with_layer_offset(1, 14, 12)
        .expect("offset")
}

#[test]
fn an_outside_band_fades_under_the_anti_aliased_edge_in_proportion() {
    // A black outside stroke of size 3 around the black rect: under the
    // partial edge pixel (alpha 200) the band is knocked out to 55 — the
    // pixel's own transparency, the drop shadow's proportion — and the
    // pixel composites over that, so the edge column reads
    // `white x (1 - 55/255) x (1 - 200/255)`: grey 43, a smooth step from
    // band to fill rather than a hard threshold at full opacity. Every
    // other column of row 15 is solid black from the band's outer edge
    // through the fill.
    let edge = |band: u8, alpha: u8| -> [u8; 4] {
        let under = over(WHITE, [0, 0, 0], band, 1.0, BLEND_NORMAL);
        over(under, [0, 0, 0], alpha, 1.0, BLEND_NORMAL)
    };
    let json = stroke_json(",\"size\":3,\"position\":\"outside\"");
    let img = flat(&styled(&aa_edge_doc(200), 1, &json));
    for x in (11..=13).chain(15..=26) {
        assert_eq!(
            at(&img, x, 15),
            [0, 0, 0, 255],
            "x={x}: solid band and fill"
        );
    }
    assert_close(&at(&img, 14, 15), &edge(55, 200), "the edge column");
    assert_eq!(edge(55, 200)[0], 43);
    assert_eq!(at(&img, 10, 15), WHITE, "3 px band, 4 px out is white");
    assert_eq!(at(&img, 27, 15), WHITE);
    // At alpha 100 the column lies outside the 50 % contour: the band
    // starts one pixel later, and under the edge column keeps 155 of it.
    let img = flat(&styled(&aa_edge_doc(100), 1, &json));
    for x in (12..=13).chain(15..=26) {
        assert_eq!(at(&img, x, 15), [0, 0, 0, 255], "x={x}: alpha 100");
    }
    assert_close(&at(&img, 14, 15), &edge(155, 100), "alpha 100 edge");
    assert_eq!(at(&img, 11, 15), WHITE);
    // At 0 % fill the band is an outline — knocked out under the opaque
    // interior — whose partial edge column carries the band's 55.
    let hollow = styled(
        &aa_edge_doc(200),
        1,
        &format!("{{\"fill_opacity\":0,{}", &json[1..]),
    );
    let img = flat(&hollow);
    for x in 11..=13 {
        assert_eq!(at(&img, x, 15), [0, 0, 0, 255], "x={x}: outline");
    }
    assert_close(
        &at(&img, 14, 15),
        &over(WHITE, [0, 0, 0], 55, 1.0, BLEND_NORMAL),
        "the outline's partial column",
    );
    for x in 15..=23 {
        assert_eq!(at(&img, x, 15), WHITE, "x={x}: hollow interior");
    }
}

#[test]
fn layer_opacity_applies_once_to_the_pixels_and_the_band_together() {
    // A blue stroke on the red rect at layer opacity 0.5: Photoshop
    // composites the pixels and their effects as one package and applies
    // the layer opacity to that — the band is 50 % blue over white,
    // [128, 128, 255], never a purple tint of the red beneath it, and the
    // interior is 50 % red.
    let base = rect_doc().with_layer_opacity(1, 0.5).expect("opacity");
    for position in ["inside", "outside", "center"] {
        let img = flat(&styled(
            &base,
            1,
            &stroke_json(&format!(
                ",\"size\":2,\"position\":\"{position}\",\"color\":\"#0000ff\""
            )),
        ));
        let band_x = if position == "outside" { 9 } else { 10 };
        assert_eq!(
            at(&img, band_x, 13),
            [128, 128, 255, 255],
            "{position}: the band is the package at 50 %"
        );
        assert_eq!(
            at(&img, 16, 13),
            [255, 128, 128, 255],
            "{position}: the interior is the pixels at 50 %"
        );
    }
}

#[test]
fn the_source_document_is_unchanged() {
    let source = rect_doc();
    let before = flat(&source);
    let styled_doc = styled(
        &source,
        1,
        &stroke_json(",\"size\":3,\"position\":\"outside\",\"color\":\"#0000ff\""),
    );
    assert!(
        source.layers[1].style.is_none(),
        "purity: no style on the source"
    );
    assert_eq!(flat(&source), before, "purity: the source projection");
    assert_ne!(flat(&styled_doc), before, "the styled copy differs");
}
