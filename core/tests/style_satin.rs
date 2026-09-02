//! Satin tests: the Interior effect behind Layer > Layer Style > Satin. The
//! oracle is closed-form geometry restated from Photoshop's conventions —
//! a hard rect's satin is the symmetric difference of the rect translated
//! by `+(dx, dy)` and `-(dx, dy)`, clipped to the rect, with the light
//! offset `(round(-d cos a), round(d sin a))` — and the W3C reference blend
//! (`common::ref_composite`) for the colours; a soft satin is checked
//! against the header's feather kernel (`common::feathered_plane`) fed
//! through the same soft XOR. Every document goes through
//! `rz_doc_set_layer_style` (`common::styled`); shared fixtures live in
//! `tests/common`.

use image::RgbaImage;
use rasterize_core::doc::{BlendMode, MaskKind, RzDocument};
use rasterize_core::style::*;

mod common;
use common::*;

// ---------------------------------------------------------------- helpers --

const CANVAS: (u32, u32) = (40, 32);
/// A 16x10 rect at (12, 11): 12 px of margin left and right, 11 top and
/// bottom — more than the soft test's kernel half-width (5) plus its 3 px
/// shift, so no oracle ever touches the canvas edge.
const RECT: (i32, i32, u32, u32) = (12, 11, 16, 10);
/// The rect colour. Every channel is even, so the hard oracle's x0.5 (black
/// Multiply at opacity 0.5 halves the backdrop) quantizes with no .5 tie
/// and the hard tests can assert exact bytes.
const TAN: [u8; 4] = [200, 120, 60, 255];
const BLACK: [f32; 3] = [0.0, 0.0, 0.0];

fn rect_doc() -> RzDocument {
    rect_layer_doc(CANVAS, RECT, TAN)
}

/// `{"effects":[{"type":"satin",<fields>}]}`.
fn satin_json(fields: &str) -> String {
    format!("{{\"effects\":[{{\"type\":\"satin\",{fields}}}]}}")
}

/// A hard (size 0) satin at `angle`/`distance`, otherwise Photoshop's
/// defaults: black, Multiply, opacity 0.5.
fn hard_satin(angle: f32, distance: f32, invert: bool) -> String {
    satin_json(&format!(
        "\"angle\":{angle},\"distance\":{distance},\"size\":0,\"invert\":{invert}"
    ))
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

/// `(x, y)` lies in `rect` = (x, y, w, h) translated by `shift`.
fn in_rect(rect: (i32, i32, u32, u32), shift: (i32, i32), x: i64, y: i64) -> bool {
    let x0 = i64::from(rect.0) + i64::from(shift.0);
    let y0 = i64::from(rect.1) + i64::from(shift.1);
    x >= x0 && y >= y0 && x < x0 + i64::from(rect.2) && y < y0 + i64::from(rect.3)
}

/// The closed-form hard satin: inside `rect`, 255 where exactly ONE of the
/// rect's two copies — translated by `+shift` and by `-shift` — covers
/// `(x, y)`, else 0; `invert` flips that inside the rect; always 0 outside
/// it (the effect is clipped to the shape).
fn hard_satin_coverage(
    rect: (i32, i32, u32, u32),
    shift: (i32, i32),
    invert: bool,
    x: i64,
    y: i64,
) -> u8 {
    if !in_rect(rect, (0, 0), x, y) {
        return 0;
    }
    let a = in_rect(rect, shift, x, y);
    let b = in_rect(rect, (-shift.0, -shift.1), x, y);
    if (a != b) != invert {
        255
    } else {
        0
    }
}

/// The satin colour over an opaque backdrop pixel at coverage `cov`,
/// through the W3C reference.
fn satin_over(bg: [u8; 4], color: [f32; 3], cov: u8, opacity: f32, mode: i32) -> [u8; 4] {
    quantized(ref_composite(
        to_unit(bg),
        [color[0], color[1], color[2], 1.0],
        opacity * f32::from(cov) / 255.0,
        mode,
    ))
}

/// `±tol` per colour channel, alpha exact.
fn assert_within(got: [u8; 4], want: [u8; 4], tol: i32, what: &str) {
    for c in 0..3 {
        assert!(
            (i32::from(got[c]) - i32::from(want[c])).abs() <= tol,
            "{what}: channel {c} is {} , expected {} (±{tol})",
            got[c],
            want[c]
        );
    }
    assert_eq!(got[3], want[3], "{what}: alpha");
}

/// `out(x, y) = plane(x - dx, y - dy)`, 0 where that is off the plane —
/// the test's own translation, so the soft oracle shares no code with the
/// core's `shift_plane`.
fn translated(plane: &[u8], w: u32, h: u32, (dx, dy): (i32, i32)) -> Vec<u8> {
    let (wi, hi) = (i64::from(w), i64::from(h));
    let mut out = vec![0u8; plane.len()];
    for y in 0..hi {
        for x in 0..wi {
            let (sx, sy) = (x - i64::from(dx), y - i64::from(dy));
            if sx >= 0 && sy >= 0 && sx < wi && sy < hi {
                out[(y * wi + x) as usize] = plane[(sy * wi + sx) as usize];
            }
        }
    }
    out
}

/// The soft XOR `round(255 (a + b - 2ab))` in floating point, from the
/// formula the style module documents.
fn soft_xor(a: u8, b: u8) -> u8 {
    let (a, b) = (f32::from(a) / 255.0, f32::from(b) / 255.0);
    ((a + b - 2.0 * a * b) * 255.0).round() as u8
}

/// The white canvas with a `layer`-sized rect at `RECT`'s position.
fn doc_with_rect(layer: image::RgbaImage) -> RzDocument {
    RzDocument::from_pixels(solid(CANVAS.0, CANVAS.1, WHITE))
        .adding_image_layer(0, layer, "Rect")
        .expect("add layer")
        .with_layer_offset(1, RECT.0, RECT.1)
        .expect("offset")
}

// ------------------------------------------------------------------ tests --

#[test]
fn hard_satin_is_the_symmetric_difference_of_the_two_offset_copies() {
    // Each shift is (round(-3 cos a), round(3 sin a)), y down.
    let cases = [
        (0.0, (-3, 0)),
        (90.0, (0, 3)),
        (45.0, (-2, 2)),
        (120.0, (2, 3)),
        (180.0, (3, 0)),
        (-90.0, (0, -3)),
    ];
    let area = RECT.2 * RECT.3;
    for invert in [false, true] {
        for (angle, shift) in cases {
            let doc = styled(&rect_doc(), 1, &hard_satin(angle, 3.0, invert));
            let flat = doc.flattened();
            let mut sheen = 0;
            for y in 0..CANVAS.1 {
                for x in 0..CANVAS.0 {
                    let (xi, yi) = (i64::from(x), i64::from(y));
                    let got = px(&flat, x, y);
                    let what = format!("angle {angle} invert {invert} ({x},{y})");
                    if !in_rect(RECT, (0, 0), xi, yi) {
                        assert_eq!(got, WHITE, "{what}: outside the shape");
                        continue;
                    }
                    let cov = hard_satin_coverage(RECT, shift, invert, xi, yi);
                    let want = satin_over(TAN, BLACK, cov, 0.5, BLEND_MULTIPLY);
                    assert_eq!(got, want, "{what}: coverage {cov}");
                    if cov == 255 {
                        sheen += 1;
                    }
                }
            }
            assert!(
                sheen > 0 && sheen < area,
                "angle {angle} invert {invert}: the sheen covers {sheen} of {area} px"
            );
        }
    }
}

#[test]
fn at_angle_zero_the_sheen_is_two_bands_and_invert_is_their_complement() {
    // dx = -3: the copies sit 3 px left and 3 px right of the rect, so
    // exactly one of them covers the outer 3 columns on each side.
    let plain = styled(&rect_doc(), 1, &hard_satin(0.0, 3.0, false)).flattened();
    let inverted = styled(&rect_doc(), 1, &hard_satin(0.0, 3.0, true)).flattened();
    let sheen = satin_over(TAN, BLACK, 255, 0.5, BLEND_MULTIPLY);
    assert_ne!(sheen, TAN, "the fixture shows the sheen");
    assert_eq!(
        sheen,
        [100, 60, 30, 255],
        "black Multiply at 0.5 halves the backdrop"
    );
    let (x0, x1) = (RECT.0, RECT.0 + RECT.2 as i32);
    for y in RECT.1..RECT.1 + RECT.3 as i32 {
        for x in x0..x1 {
            let in_band = x < x0 + 3 || x >= x1 - 3;
            let (got_plain, got_inverted) = (
                px(&plain, x as u32, y as u32),
                px(&inverted, x as u32, y as u32),
            );
            assert_eq!(
                got_plain,
                if in_band { sheen } else { TAN },
                "plain ({x},{y})"
            );
            assert_eq!(
                got_inverted,
                if in_band { TAN } else { sheen },
                "inverted ({x},{y})"
            );
        }
    }
}

#[test]
fn satin_blend_opacity_and_enabled_follow_the_reference() {
    // Angle 0, hard: the rect's first column is in the left band, its
    // centre is sheen-free.
    let band = (RECT.0 as u32, RECT.1 as u32 + 1);
    let centre = (RECT.0 as u32 + 8, RECT.1 as u32 + 5);
    let grey = [128, 128, 128, 255];
    for (name, mode) in [
        ("normal", BLEND_NORMAL),
        ("multiply", BLEND_MULTIPLY),
        ("screen", BLEND_SCREEN),
    ] {
        let doc = styled(
            &rect_doc(),
            1,
            &satin_json(&format!(
                "\"angle\":0,\"distance\":3,\"size\":0,\"invert\":false,\
                 \"blend\":\"{name}\",\"color\":\"#808080\",\"opacity\":0.6"
            )),
        );
        let flat = doc.flattened();
        let want = quantized(ref_composite(to_unit(TAN), to_unit(grey), 0.6, mode));
        assert_ne!(want, TAN, "{name}: the fixture shows the effect");
        assert_close(&px(&flat, band.0, band.1), &want, name);
        assert_eq!(
            px(&flat, centre.0, centre.1),
            TAN,
            "{name}: the sheen-free interior is untouched"
        );
    }
    let plain = rect_doc().flattened().into_raw();
    let off = styled(&rect_doc(), 1, &satin_json("\"opacity\":0"));
    assert_eq!(
        off.flattened().into_raw(),
        plain,
        "opacity 0 renders nothing"
    );
    let disabled = styled(
        &rect_doc(),
        1,
        "{\"fill_opacity\":0.5,\"effects\":[{\"type\":\"satin\",\"enabled\":false}]}",
    );
    assert_eq!(
        disabled.flattened().into_raw(),
        rect_doc()
            .with_layer_opacity(1, 0.5)
            .expect("opacity")
            .flattened()
            .into_raw(),
        "a disabled effect renders nothing"
    );
}

#[test]
fn satin_keeps_its_own_blend_on_a_multiply_layer() {
    let grey = [128, 128, 128, 255];
    let doc = RzDocument::from_pixels(solid(CANVAS.0, CANVAS.1, grey))
        .adding_image_layer(0, solid(RECT.2, RECT.3, BLUE), "Rect")
        .expect("add layer")
        .with_layer_offset(1, RECT.0, RECT.1)
        .expect("offset")
        .with_layer_blend_mode(1, BlendMode::Multiply)
        .expect("blend");
    let doc = styled(
        &doc,
        1,
        &satin_json(
            "\"angle\":0,\"distance\":3,\"size\":0,\"invert\":false,\
             \"blend\":\"normal\",\"color\":\"#ffffff\",\"opacity\":0.75",
        ),
    );
    let flat = doc.flattened();
    // The pixels land first with the LAYER's Multiply; the satin then
    // composites over them with its OWN Normal — never the layer's mode.
    let pixels = ref_composite(to_unit(grey), to_unit(BLUE), 1.0, BLEND_MULTIPLY);
    let want = quantized(ref_composite(pixels, [1.0; 4], 0.75, BLEND_NORMAL));
    let not_want = quantized(ref_composite(pixels, [1.0; 4], 0.75, BLEND_MULTIPLY));
    assert_ne!(want, not_want, "the fixture distinguishes the two modes");
    assert_close(
        &px(&flat, RECT.0 as u32, RECT.1 as u32 + 1),
        &want,
        "the satin uses its own Normal blend",
    );
    assert_close(
        &px(&flat, RECT.0 as u32 + 8, RECT.1 as u32 + 5),
        &quantized(pixels),
        "the layer's pixels use Multiply",
    );
}

#[test]
fn soft_satin_matches_the_feather_oracle_through_the_soft_xor() {
    // size 4 -> sigma 2 -> feather radius (2 - 0.8) / 0.3 + 1 = 5.
    let doc = styled(
        &rect_doc(),
        1,
        &satin_json("\"angle\":0,\"distance\":3,\"size\":4,\"invert\":false"),
    );
    let flat = doc.flattened();
    let (w, h) = CANVAS;
    let rect_sel = selection(w, h, |x, y| {
        u8::from(in_rect(RECT, (0, 0), i64::from(x), i64::from(y))) * 255
    });
    let blurred = feathered_plane(&rect_sel, w, h, 5.0);
    let a = translated(&blurred, w, h, (-3, 0));
    let b = translated(&blurred, w, h, (3, 0));
    // Tolerance: the feather oracle is ±1 per plane; the soft XOR's slope
    // in each input is at most 1, plus its own rounding, so the coverage
    // may differ by 3; at opacity 0.5 over TAN that moves a channel by at
    // most 0.5 * 200/255 * 3 = 1.2 before the final rounding — hence ±2.
    let mut intermediate = 0;
    for y in 0..h {
        for x in 0..w {
            let i = (y * w + x) as usize;
            let got = px(&flat, x, y);
            if rect_sel[i] == 0 {
                assert_eq!(got, WHITE, "({x},{y}) outside the shape");
                continue;
            }
            let cov = soft_xor(a[i], b[i]);
            let want = satin_over(TAN, BLACK, cov, 0.5, BLEND_MULTIPLY);
            assert_within(got, want, 2, &format!("({x},{y}) coverage {cov}"));
            if cov > 0 && cov < 255 {
                intermediate += 1;
            }
        }
    }
    assert!(intermediate > 0, "the oracle exercises the blur");
}

#[test]
fn satin_follows_the_layer_offset_even_partly_off_canvas() {
    // The rect hangs off the top-left corner: its left band is entirely
    // off-canvas; the right band sits at the LAYER's right edge (x 8..11),
    // not at a canvas-relative position.
    let rect = (-5, -4, 16, 10);
    let doc = styled(
        &rect_layer_doc(CANVAS, rect, TAN),
        1,
        &hard_satin(0.0, 3.0, false),
    );
    let flat = doc.flattened();
    let sheen = satin_over(TAN, BLACK, 255, 0.5, BLEND_MULTIPLY);
    for y in 0..CANVAS.1 {
        for x in 0..CANVAS.0 {
            let (xi, yi) = (i64::from(x), i64::from(y));
            let want = if !in_rect(rect, (0, 0), xi, yi) {
                WHITE
            } else if hard_satin_coverage(rect, (-3, 0), false, xi, yi) == 255 {
                sheen
            } else {
                TAN
            };
            assert_eq!(px(&flat, x, y), want, "({x},{y})");
        }
    }
    assert_eq!(px(&flat, 7, 2), TAN, "interior up to the band");
    assert_eq!(px(&flat, 8, 2), sheen, "the band starts 3 px from the edge");
    assert_eq!(px(&flat, 10, 2), sheen, "and runs to it");
    assert_eq!(px(&flat, 11, 2), WHITE, "outside the layer");
}

#[test]
fn fill_opacity_zero_keeps_the_sheen_and_a_transparent_layer_renders_nothing() {
    let doc = styled(
        &rect_doc(),
        1,
        "{\"fill_opacity\":0,\"effects\":[{\"type\":\"satin\",\"angle\":0,\"distance\":3,\
         \"size\":0,\"invert\":false}]}",
    );
    let flat = doc.flattened();
    // With the pixels gone the sheen falls straight onto the white canvas.
    let sheen = satin_over(WHITE, BLACK, 255, 0.5, BLEND_MULTIPLY);
    assert_eq!(sheen, [128, 128, 128, 255]);
    for y in 0..CANVAS.1 {
        for x in 0..CANVAS.0 {
            let (xi, yi) = (i64::from(x), i64::from(y));
            let want = if hard_satin_coverage(RECT, (-3, 0), false, xi, yi) == 255 {
                sheen
            } else {
                WHITE
            };
            assert_eq!(px(&flat, x, y), want, "({x},{y})");
        }
    }
    // No alpha, no shape, no sheen — even inverted, which paints the whole
    // shape when there is one.
    let clear = doc_with_rect(solid(RECT.2, RECT.3, [0, 0, 0, 0]));
    let styled_clear = styled(&clear, 1, &hard_satin(0.0, 3.0, true));
    assert_eq!(
        styled_clear.flattened().into_raw(),
        solid(CANVAS.0, CANVAS.1, WHITE).into_raw(),
        "a fully transparent layer renders nothing"
    );
}

#[test]
fn the_shape_is_alpha_times_mask() {
    // Reveal only the rect's left 8 columns: the effective shape is an 8x10
    // rect, so the right band moves to the MASK's edge.
    let visible = (RECT.0, RECT.1, 8, RECT.3);
    let sel = selection(CANVAS.0, CANVAS.1, |x, y| {
        u8::from(in_rect(visible, (0, 0), i64::from(x), i64::from(y))) * 255
    });
    let doc = rect_doc()
        .add_mask(1, MaskKind::FromSelection(&sel))
        .expect("mask");
    let doc = styled(&doc, 1, &hard_satin(0.0, 3.0, false));
    let flat = doc.flattened();
    let sheen = satin_over(TAN, BLACK, 255, 0.5, BLEND_MULTIPLY);
    for y in 0..CANVAS.1 {
        for x in 0..CANVAS.0 {
            let (xi, yi) = (i64::from(x), i64::from(y));
            let want = if !in_rect(visible, (0, 0), xi, yi) {
                WHITE
            } else if hard_satin_coverage(visible, (-3, 0), false, xi, yi) == 255 {
                sheen
            } else {
                TAN
            };
            assert_eq!(px(&flat, x, y), want, "({x},{y})");
        }
    }
    // The band hugs the mask edge (x 17..20), where the unmasked rect
    // would have shown plain TAN.
    assert_eq!(px(&flat, 17, 15), sheen);
    assert_eq!(px(&flat, 16, 15), TAN);
    assert_eq!(px(&flat, 20, 15), WHITE, "the masked-out half is invisible");
}

#[test]
fn distance_zero_on_a_hard_shape_is_nothing_or_with_invert_the_whole_shape() {
    // Both copies coincide, so s = 2a(1 - a): 0 wherever the shape is hard.
    let plain = rect_doc().flattened().into_raw();
    let none = styled(
        &rect_doc(),
        1,
        &satin_json("\"distance\":0,\"size\":0,\"invert\":false"),
    );
    assert_eq!(
        none.flattened().into_raw(),
        plain,
        "coincident copies cancel"
    );
    let whole = styled(
        &rect_doc(),
        1,
        &satin_json("\"distance\":0,\"size\":0,\"invert\":true"),
    )
    .flattened();
    let sheen = satin_over(TAN, BLACK, 255, 0.5, BLEND_MULTIPLY);
    for y in 0..CANVAS.1 {
        for x in 0..CANVAS.0 {
            let inside = in_rect(RECT, (0, 0), i64::from(x), i64::from(y));
            assert_eq!(
                px(&whole, x, y),
                if inside { sheen } else { WHITE },
                "({x},{y})"
            );
        }
    }
}

#[test]
fn large_sizes_take_the_downsampled_blur_and_stay_inside_the_shape() {
    // size 40 -> sigma 20, above the quarter-resolution threshold (8): the
    // plane still renders, stays clipped to the shape, and keeps every
    // pixel opaque.
    let doc = styled(
        &rect_doc(),
        1,
        &satin_json("\"angle\":19,\"distance\":6,\"size\":40,\"invert\":true"),
    );
    let flat = doc.flattened();
    let mut changed = 0;
    for y in 0..CANVAS.1 {
        for x in 0..CANVAS.0 {
            let got = px(&flat, x, y);
            let inside = in_rect(RECT, (0, 0), i64::from(x), i64::from(y));
            assert_eq!(got[3], 255, "({x},{y}) alpha");
            if !inside {
                assert_eq!(got, WHITE, "({x},{y}) outside the shape");
            } else if got != TAN {
                changed += 1;
                for c in 0..3 {
                    assert!(got[c] <= TAN[c], "({x},{y}) a black Multiply only darkens");
                }
            }
        }
    }
    assert!(changed > 0, "the sheen renders at large sizes");
}

#[test]
fn defaults_are_photoshops_and_the_setter_is_pure() {
    let style = LayerStyle::from_json("{\"effects\":[{\"type\":\"satin\"}]}").expect("parses");
    match style.effect(EffectKind::Satin) {
        Some(Effect::Satin(satin)) => assert_eq!(
            *satin,
            Satin {
                enabled: true,
                blend: BlendMode::Multiply,
                color: [0, 0, 0],
                opacity: 0.5,
                angle: 19.0,
                distance: 11.0,
                size: 14.0,
                invert: true,
            }
        ),
        other => panic!("no satin: {other:?}"),
    }
    let base = rect_doc();
    let before = base.flattened().into_raw();
    let out = styled(&base, 1, &hard_satin(0.0, 3.0, false));
    assert!(
        base.layers[1].style.is_none(),
        "the source document is untouched"
    );
    assert_eq!(base.flattened().into_raw(), before, "the setter is pure");
    assert!(out.layers[1].style.is_some(), "the copy carries the style");
    assert_ne!(out.flattened().into_raw(), before, "and renders it");
    // Rendering twice (cache hit) and from a fresh document agree byte for byte.
    assert_eq!(out.flattened().into_raw(), out.flattened().into_raw());
    assert_eq!(
        styled(&rect_doc(), 1, &hard_satin(0.0, 3.0, false))
            .flattened()
            .into_raw(),
        out.flattened().into_raw()
    );
}
