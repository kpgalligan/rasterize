//! Gradient overlay tests (Layer Style > Gradient Overlay, work item E6):
//! the shape filled with a gradient above the pixels. The oracle is the
//! gradient parameter of `style_render`'s module doc restated here in f64
//! from the layer box — closed forms for the linear cases (`t = (i + 0.5) /
//! n` at column `i` of an `n`-wide box at 0°, `1 - (j + 0.5) / m` at 90°,
//! reverse and scale as arithmetic on those), the general formula for the
//! radial / reflected / diamond / angle styles — fed through the W3C
//! reference composite from `tests/common`. Every style is applied through
//! `rz_doc_set_layer_style`; documents are built from the safe constructors.
//! Never a golden image.

use std::ffi::CString;
use std::os::raw::c_char;
use std::ptr;

use image::{Rgba, RgbaImage};
use rasterize_core::doc::{BlendMode, MaskKind, RzDocument};
use rasterize_core::ffi_doc::*;
use rasterize_core::ffi_style::*;

mod common;
use common::*;

// ---------------------------------------------------------------- helpers --

/// A 40x32 white canvas under a 10x8 red rect at (12, 12): even dimensions
/// so no pixel centre lies on the box's centre lines (the angle style's
/// seam), far from every edge.
const CANVAS: (u32, u32) = (40, 32);
const RECT: (i32, i32, u32, u32) = (12, 12, 10, 8);

fn rect_doc() -> RzDocument {
    rect_layer_doc(CANVAS, RECT, RED)
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

/// An opaque grey `t` in 0..1 — the default black-to-white gradient's colour.
fn grey(t: f64) -> [u8; 4] {
    let v = (t * 255.0).round() as u8;
    [v, v, v, 255]
}

fn in_rect(rect: (i32, i32, u32, u32), x: u32, y: u32) -> bool {
    let (x, y) = (i64::from(x), i64::from(y));
    x >= i64::from(rect.0)
        && y >= i64::from(rect.1)
        && x < i64::from(rect.0) + i64::from(rect.2)
        && y < i64::from(rect.1) + i64::from(rect.3)
}

/// A gradient-overlay style with the default black-to-white stops and
/// `extra` spliced into the gradient object (`"angle":0,"reverse":true`).
fn overlay(gradient_extra: &str) -> String {
    overlay_with(gradient_extra, "")
}

/// As [`overlay`], with `effect_extra` spliced into the effect object
/// (`"blend":"multiply","opacity":0.6`) and `gradient_extra` into the
/// gradient object.
fn overlay_with(gradient_extra: &str, effect_extra: &str) -> String {
    let gradient = if gradient_extra.is_empty() {
        "{}".to_string()
    } else {
        format!("{{{gradient_extra}}}")
    };
    let effect = if effect_extra.is_empty() {
        String::new()
    } else {
        format!(",{effect_extra}")
    };
    format!("{{\"effects\":[{{\"type\":\"gradient_overlay\",\"gradient\":{gradient}{effect}}}]}}")
}

/// The gradient parameter restated from the module doc, in f64, for the
/// pixel centre `(x, y)` and the box `(bx, by, bw, bh)` in the SAME
/// coordinate space (layer or canvas — the plane's padding cancels out of
/// every difference, so the test never needs to know it).
struct Grad<'a> {
    style: &'a str,
    angle: f64,
    scale: f64,
    reverse: bool,
}

#[allow(clippy::too_many_arguments)]
fn oracle_t(g: &Grad, x: f64, y: f64, bx: f64, by: f64, bw: f64, bh: f64) -> f64 {
    let (cx, cy) = (bx + bw / 2.0, by + bh / 2.0);
    let a = g.angle.to_radians();
    let (dx, dy) = (x - cx, y - cy);
    let u = dx * a.cos() - dy * a.sin();
    let v = dx * a.sin() + dy * a.cos();
    let extent = ((bw * a.cos()).abs() + (bh * a.sin()).abs()) * g.scale;
    let major = bw.max(bh) * g.scale;
    let t = match g.style {
        "linear" => 0.5 + u / extent,
        "reflected" => (2.0 * u / extent).abs(),
        "radial" => 2.0 * (dx * dx + dy * dy).sqrt() / major,
        "diamond" => 2.0 * (u.abs() + v.abs()) / major,
        "angle" => {
            let tau = std::f64::consts::TAU;
            ((-dy).atan2(dx) - a).rem_euclid(tau) / tau
        }
        other => panic!("unknown gradient style {other}"),
    };
    let t = t.clamp(0.0, 1.0);
    if g.reverse {
        1.0 - t
    } else {
        t
    }
}

/// Asserts every pixel of the flattened `doc`: `want(lx, ly)` inside the
/// rect (layer coordinates), white outside.
fn assert_rect(
    doc: &RzDocument,
    rect: (i32, i32, u32, u32),
    what: &str,
    want: impl Fn(u32, u32) -> [u8; 4],
) {
    let flat = doc.flattened();
    for y in 0..doc.height {
        for x in 0..doc.width {
            let got = px(&flat, x, y);
            if in_rect(rect, x, y) {
                let lx = (i64::from(x) - i64::from(rect.0)) as u32;
                let ly = (i64::from(y) - i64::from(rect.1)) as u32;
                assert_close(&got, &want(lx, ly), &format!("{what} ({x},{y})"));
            } else {
                assert_eq!(
                    got, WHITE,
                    "{what}: ({x},{y}) outside the rect is untouched"
                );
            }
        }
    }
}

// ------------------------------------------------------------ linear ramps --

#[test]
fn linear_at_zero_degrees_ramps_left_to_right_across_the_layer_box() {
    // Column i of a 10-wide box samples its centre at i + 0.5, so
    // t = (i + 0.5) / 10 — symmetric about the centre, never 0 or 1.
    let doc = styled(&rect_doc(), 1, &overlay("\"angle\":0"));
    assert_rect(&doc, RECT, "linear 0°", |lx, _| {
        grey((f64::from(lx) + 0.5) / f64::from(RECT.2))
    });
}

#[test]
fn linear_at_ninety_degrees_ramps_bottom_to_top_and_is_the_default() {
    // At 90° (the schema default) the ramp runs bottom to top in y-down
    // space: row j of an 8-high box has t = 1 - (j + 0.5) / 8, so the top
    // row is nearly white and the bottom row nearly black.
    let want = |_: u32, ly: u32| grey(1.0 - (f64::from(ly) + 0.5) / f64::from(RECT.3));
    let explicit = styled(&rect_doc(), 1, &overlay("\"angle\":90"));
    assert_rect(&explicit, RECT, "linear 90°", want);
    let default = styled(
        &rect_doc(),
        1,
        "{\"effects\":[{\"type\":\"gradient_overlay\"}]}",
    );
    assert_rect(&default, RECT, "default gradient", want);
    assert_eq!(
        default.flattened().into_raw(),
        explicit.flattened().into_raw(),
        "the default angle is 90°"
    );
}

#[test]
fn reverse_flips_the_ramp() {
    let doc = styled(&rect_doc(), 1, &overlay("\"angle\":0,\"reverse\":true"));
    assert_rect(&doc, RECT, "reversed", |lx, _| {
        grey(1.0 - (f64::from(lx) + 0.5) / f64::from(RECT.2))
    });
}

#[test]
fn scale_shortens_the_ramp_about_the_centre() {
    // Scale halves the extent, so the ramp climbs twice as fast through the
    // centre and clamps to the end colours in the outer columns:
    // t = clamp(0.5 + 2 (i + 0.5 - w/2) / w).
    let doc = styled(&rect_doc(), 1, &overlay("\"angle\":0,\"scale\":0.5"));
    let w = f64::from(RECT.2);
    let t = |lx: u32| (0.5 + 2.0 * (f64::from(lx) + 0.5 - w / 2.0) / w).clamp(0.0, 1.0);
    assert_rect(&doc, RECT, "scale 0.5", |lx, _| grey(t(lx)));
    // The closed form itself: the outer columns are clamped, the two centre
    // columns straddle 0.5 by one doubled step each.
    assert_eq!(t(0), 0.0, "left columns clamp to the start colour");
    assert_eq!(t(9), 1.0, "right columns clamp to the end colour");
    assert!((t(5) - t(4) - 2.0 / w).abs() < 1e-9, "the slope is doubled");
    assert!(
        (t(4) + t(5) - 1.0).abs() < 1e-9,
        "symmetric about the centre"
    );
}

// ------------------------------------------------------------ other styles --

#[test]
fn radial_reflected_diamond_and_angle_follow_the_restated_formulas() {
    let (bw, bh) = (f64::from(RECT.2), f64::from(RECT.3));
    for (style, angle) in [
        ("radial", 90.0),
        ("reflected", 0.0),
        ("reflected", 90.0),
        ("diamond", 90.0),
        ("angle", 0.0),
        ("linear", 30.0),
        ("reflected", 45.0),
    ] {
        let g = Grad {
            style,
            angle,
            scale: 1.0,
            reverse: false,
        };
        let doc = styled(
            &rect_doc(),
            1,
            &overlay(&format!("\"style\":\"{style}\",\"angle\":{angle}")),
        );
        assert_rect(&doc, RECT, &format!("{style} at {angle}°"), |lx, ly| {
            let t = oracle_t(
                &g,
                f64::from(lx) + 0.5,
                f64::from(ly) + 0.5,
                0.0,
                0.0,
                bw,
                bh,
            );
            grey(t)
        });
    }
}

#[test]
fn radial_is_a_distance_from_the_centre_and_reflected_is_symmetric() {
    // Properties independent of the formula: a radial gradient's grey is
    // monotone in the distance from the box centre and equal for pixels at
    // equal distances; a reflected one mirrors about the centre line.
    let radial = styled(&rect_doc(), 1, &overlay("\"style\":\"radial\"")).flattened();
    let reflected = styled(
        &rect_doc(),
        1,
        &overlay("\"style\":\"reflected\",\"angle\":0"),
    )
    .flattened();
    let (x0, y0) = (RECT.0 as u32, RECT.1 as u32);
    let (w, h) = (RECT.2, RECT.3);
    let dist = |lx: u32, ly: u32| {
        let dx = f64::from(lx) + 0.5 - f64::from(w) / 2.0;
        let dy = f64::from(ly) + 0.5 - f64::from(h) / 2.0;
        (dx * dx + dy * dy).sqrt()
    };
    let centre = px(&radial, x0 + w / 2, y0 + h / 2)[0];
    let corner = px(&radial, x0, y0)[0];
    assert!(
        centre < 60,
        "radial: the centre is near the start colour ({centre})"
    );
    assert_eq!(
        corner, 255,
        "radial: the corner (beyond the radius) clamps to white"
    );
    for ly in 0..h {
        for lx in 0..w {
            // Mirror images share a distance, hence a grey.
            let (mx, my) = (w - 1 - lx, h - 1 - ly);
            assert!((dist(lx, ly) - dist(mx, my)).abs() < 1e-9);
            assert_eq!(
                px(&radial, x0 + lx, y0 + ly),
                px(&radial, x0 + mx, y0 + my),
                "radial: ({lx},{ly}) and its mirror differ"
            );
            assert_eq!(
                px(&reflected, x0 + lx, y0 + ly),
                px(&reflected, x0 + mx, y0 + ly),
                "reflected: ({lx},{ly}) and its mirror differ"
            );
            if lx + 1 < w / 2 {
                assert!(
                    px(&reflected, x0 + lx, y0 + ly)[0] > px(&reflected, x0 + lx + 1, y0 + ly)[0],
                    "reflected: darkens toward the centre line at ({lx},{ly})"
                );
            }
        }
    }
}

#[test]
fn angle_style_is_monotone_around_the_centre() {
    // Walking the ring at Chebyshev distance 1.5 from the centre in order of
    // increasing polar angle (counter-clockwise on screen), the grey level
    // rises strictly — one full turn from black back to white with the seam
    // on the +x axis, which no pixel centre touches (even dimensions).
    let flat = styled(&rect_doc(), 1, &overlay("\"style\":\"angle\",\"angle\":0")).flattened();
    let (w, h) = (f64::from(RECT.2), f64::from(RECT.3));
    let mut ring: Vec<(f64, u8)> = Vec::new();
    for ly in 0..RECT.3 {
        for lx in 0..RECT.2 {
            let dx = f64::from(lx) + 0.5 - w / 2.0;
            let dy = f64::from(ly) + 0.5 - h / 2.0;
            if dx.abs().max(dy.abs()) == 1.5 {
                let polar = (-dy).atan2(dx).rem_euclid(std::f64::consts::TAU);
                ring.push((polar, px(&flat, RECT.0 as u32 + lx, RECT.1 as u32 + ly)[0]));
            }
        }
    }
    assert_eq!(ring.len(), 12, "the 4x4 ring minus its 2x2 centre");
    ring.sort_by(|a, b| a.0.partial_cmp(&b.0).expect("finite angles"));
    for pair in ring.windows(2) {
        assert!(
            pair[0].1 < pair[1].1,
            "grey must rise counter-clockwise: {:?} then {:?}",
            pair[0],
            pair[1]
        );
    }
    assert!(ring[0].1 < 40, "just above the +x axis is near black");
    assert!(ring[11].1 > 215, "just below the +x axis is near white");
}

// --------------------------------------------------------------- stops --

#[test]
fn a_transparent_middle_stop_lets_the_pixels_show_through() {
    // An 11-wide rect puts column 5's centre exactly at t = 0.5, where the
    // middle stop's opacity 0 zeroes the coverage: that column IS the rect
    // colour. Elsewhere colour and opacity interpolate linearly to the
    // neighbouring stops — black to red with opacity 1 - 2t below the
    // middle, red to white with opacity 2t - 1 above it.
    let rect = (12, 12, 11, 8);
    let doc = styled(
        &rect_layer_doc(CANVAS, rect, RED),
        1,
        &overlay(
            "\"angle\":0,\"stops\":[{\"position\":0,\"color\":\"#000000\",\"opacity\":1},\
             {\"position\":0.5,\"color\":\"#ff0000\",\"opacity\":0},\
             {\"position\":1,\"color\":\"#ffffff\",\"opacity\":1}]",
        ),
    );
    assert_rect(&doc, rect, "transparent middle stop", |lx, _| {
        let t = (f64::from(lx) + 0.5) / f64::from(rect.2);
        let (colour, a) = if t < 0.5 {
            let f = t / 0.5;
            ([f as f32, 0.0, 0.0, 1.0], 1.0 - f as f32)
        } else {
            let f = (t - 0.5) / 0.5;
            ([1.0, f as f32, f as f32, 1.0], f as f32)
        };
        quantized(ref_composite(to_unit(RED), colour, a, BLEND_NORMAL))
    });
    let flat = doc.flattened();
    assert_eq!(px(&flat, 12 + 5, 14), RED, "the middle column is untouched");
}

// -------------------------------------------------------- blend and opacity --

#[test]
fn blend_mode_and_opacity_follow_the_reference() {
    for (name, mode) in [
        ("normal", BLEND_NORMAL),
        ("multiply", BLEND_MULTIPLY),
        ("screen", BLEND_SCREEN),
    ] {
        let doc = styled(
            &rect_doc(),
            1,
            &overlay_with(
                "\"angle\":0",
                &format!("\"blend\":\"{name}\",\"opacity\":0.6"),
            ),
        );
        assert_rect(&doc, RECT, name, |lx, _| {
            let t = ((f64::from(lx) + 0.5) / f64::from(RECT.2)) as f32;
            quantized(ref_composite(to_unit(RED), [t, t, t, 1.0], 0.6, mode))
        });
    }
}

#[test]
fn the_overlay_keeps_its_own_blend_on_a_multiply_layer() {
    // A Multiply-blend LAYER over grey: the pixels multiply, but a Normal
    // overlay is drawn with ITS blend against the backdrop, so the rect
    // shows the plain ramp — not the ramp multiplied by grey.
    let grey_bg = [128, 128, 128, 255];
    let base = RzDocument::from_pixels(solid(CANVAS.0, CANVAS.1, grey_bg))
        .adding_image_layer(0, solid(RECT.2, RECT.3, RED), "Rect")
        .expect("add rect layer")
        .with_layer_offset(1, RECT.0, RECT.1)
        .expect("offset")
        .with_layer_blend_mode(1, BlendMode::Multiply)
        .expect("blend");
    let plain = base.flattened();
    assert_eq!(
        px(&plain, 14, 14),
        [128, 0, 0, 255],
        "baseline: the Multiply layer darkens to red x grey, or this test proves nothing"
    );
    let styled_doc = styled(&base, 1, &overlay("\"angle\":0"));
    let flat = styled_doc.flattened();
    for y in 0..CANVAS.1 {
        for x in 0..CANVAS.0 {
            let got = px(&flat, x, y);
            if in_rect(RECT, x, y) {
                let lx = x - RECT.0 as u32;
                let want = grey((f64::from(lx) + 0.5) / f64::from(RECT.2));
                assert_close(
                    &got,
                    &want,
                    &format!("Normal overlay on a Multiply layer ({x},{y})"),
                );
            } else {
                assert_eq!(got, grey_bg, "({x},{y}) outside the rect is untouched");
            }
        }
    }
}

#[test]
fn disabled_and_zero_opacity_render_nothing() {
    let base = rect_doc();
    let plain = base.flattened().into_raw();
    let off = styled(
        &base,
        1,
        "{\"effects\":[{\"type\":\"gradient_overlay\",\"opacity\":0}]}",
    );
    assert_eq!(
        off.flattened().into_raw(),
        plain,
        "opacity 0 renders nothing"
    );
    // A disabled effect alone is an identity style (the core clears it), so
    // fill opacity keeps the style stored; the projection equals the same
    // layer at that LAYER opacity.
    let disabled = styled(
        &base,
        1,
        "{\"fill_opacity\":0.5,\"effects\":[{\"type\":\"gradient_overlay\",\"enabled\":false}]}",
    );
    assert_eq!(
        disabled.flattened().into_raw(),
        base.with_layer_opacity(1, 0.5)
            .expect("opacity")
            .flattened()
            .into_raw(),
        "a disabled effect renders nothing"
    );
}

// -------------------------------------------------------- shape and box --

#[test]
fn align_with_layer_spans_the_content_bounds_not_the_buffer() {
    // A canvas-sized layer whose only opaque pixels are the 10x8 rect —
    // what the Shape tool or a brush stroke on a new layer produces —
    // renders every gradient style exactly like the tight 10x8 layer:
    // Photoshop spans the box across the content, ignoring transparent
    // pixels, never across the pixel buffer.
    let mut pixels = RgbaImage::from_pixel(CANVAS.0, CANVAS.1, Rgba([0, 0, 0, 0]));
    for y in 0..RECT.3 {
        for x in 0..RECT.2 {
            pixels.put_pixel(RECT.0 as u32 + x, RECT.1 as u32 + y, Rgba(RED));
        }
    }
    let painted = RzDocument::from_pixels(solid(CANVAS.0, CANVAS.1, WHITE))
        .adding_image_layer(0, pixels, "Painted")
        .expect("add layer");
    for gradient in [
        "",
        "\"angle\":0",
        "\"style\":\"radial\"",
        "\"style\":\"reflected\",\"angle\":45",
        "\"style\":\"diamond\",\"scale\":0.7",
        "\"style\":\"angle\",\"angle\":30",
    ] {
        let json = overlay(gradient);
        assert_eq!(
            styled(&painted, 1, &json).flattened().into_raw(),
            styled(&rect_doc(), 1, &json).flattened().into_raw(),
            "{gradient}: the buffer's transparent margin is not the box"
        );
    }
    // The default ramp runs the rect's full height (`t = 1 - (j + 0.5) /
    // 8`), not the almost flat slice a canvas-sized box would give.
    let flat = styled(&painted, 1, &overlay("")).flattened();
    assert_eq!(px(&flat, 16, 12), grey(1.0 - 0.5 / 8.0));
    assert_eq!(px(&flat, 16, 19), grey(0.5 / 8.0));
    // (A mask, unlike transparency, leaves the box alone —
    // `a_mask_shrinks_the_shape_but_not_the_box`.)
    // A gradient stroke uses the same box.
    let stroke = "{\"effects\":[{\"type\":\"stroke\",\"size\":2,\"fill_type\":\"gradient\",\
                  \"gradient\":{\"angle\":0}}]}";
    assert_eq!(
        styled(&painted, 1, stroke).flattened().into_raw(),
        styled(&rect_doc(), 1, stroke).flattened().into_raw(),
        "gradient stroke"
    );
}

#[test]
fn merge_down_bakes_a_canvas_aligned_gradient_as_the_projection_showed_it() {
    // Layer 1 a 10x10 green square at (0, 0), layer 2 a 20x20 red square
    // at (40, 40) with a CANVAS-aligned ramp at angle 0, on a 100x100 white
    // canvas. Merge Down composites the two into a window the size of their
    // union plus the padding — much smaller than the canvas — but the
    // gradient must span the canvas exactly as the projection rendered it,
    // for the overlay (exact) and a gradient stroke (its anti-aliased band
    // is quantized once more on the way) alike.
    let base = RzDocument::from_pixels(solid(100, 100, WHITE))
        .adding_image_layer(0, solid(10, 10, GREEN), "Small")
        .expect("add")
        .adding_image_layer(1, solid(20, 20, RED), "Styled")
        .expect("add")
        .with_layer_offset(2, 40, 40)
        .expect("offset");
    let overlay_json = overlay("\"angle\":0,\"align_with_layer\":false");
    let doc = styled(&base, 2, &overlay_json);
    let before = doc.flattened();
    // The square shows the middle slice of a canvas-wide ramp.
    assert_close(&px(&before, 50, 50), &grey(50.5 / 100.0), "projection");
    let merged = doc.merging_down(2).expect("merge");
    assert_eq!(merged.layers.len(), 2);
    assert!(
        merged.layers[1].pixels.dimensions().0 < 100,
        "the merge window is smaller than the canvas"
    );
    assert_eq!(
        merged.flattened().into_raw(),
        before.into_raw(),
        "overlay: the projection survives the merge byte for byte"
    );
    let stroke = "{\"effects\":[{\"type\":\"stroke\",\"size\":4,\"fill_type\":\"gradient\",\
                  \"gradient\":{\"angle\":0,\"align_with_layer\":false}}]}";
    let doc = styled(&base, 2, stroke);
    let before = doc.flattened();
    let merged = doc.merging_down(2).expect("merge");
    assert_close(
        &merged.flattened().into_raw(),
        &before.into_raw(),
        "gradient stroke: the projection survives the merge",
    );
}

#[test]
fn the_layer_offset_maps_the_ramp_and_off_canvas_parts_are_clipped() {
    // The box is the LAYER rect even when most of it lies off-canvas: the
    // visible columns show the ramp's tail end, in layer coordinates.
    for rect in [(-4, -3, 10, 8), (34, 27, 10, 8)] {
        let doc = styled(
            &rect_layer_doc(CANVAS, rect, RED),
            1,
            &overlay("\"angle\":0"),
        );
        let flat = doc.flattened();
        let mut visible = 0;
        for y in 0..CANVAS.1 {
            for x in 0..CANVAS.0 {
                let got = px(&flat, x, y);
                if in_rect(rect, x, y) {
                    visible += 1;
                    let lx = i64::from(x) - i64::from(rect.0);
                    let want = grey((lx as f64 + 0.5) / f64::from(rect.2));
                    assert_close(
                        &got,
                        &want,
                        &format!("rect at {:?} ({x},{y})", (rect.0, rect.1)),
                    );
                } else {
                    assert_eq!(got, WHITE, "({x},{y}) outside the rect is untouched");
                }
            }
        }
        assert_eq!(visible, 6 * 5, "a 6x5 corner of the rect is on canvas");
    }
}

#[test]
fn canvas_alignment_uses_the_canvas_box_and_follows_canvas_resize() {
    // Not aligned with the layer: the box is the canvas, so canvas column x
    // has t = (x + 0.5) / canvas width regardless of where the rect sits.
    let json = overlay("\"angle\":0,\"align_with_layer\":false");
    let doc = styled(&rect_doc(), 1, &json);
    let before = doc.flattened();
    for y in RECT.1 as u32..RECT.1 as u32 + RECT.3 {
        for x in RECT.0 as u32..RECT.0 as u32 + RECT.2 {
            let want = grey((f64::from(x) + 0.5) / f64::from(CANVAS.0));
            assert_close(&px(&before, x, y), &want, &format!("canvas box ({x},{y})"));
        }
    }
    // Canvas Size: 60 wide, the old canvas landing 10 px in. The style's
    // Arc (and its cache, now holding the 40-wide render) is shared with the
    // resized document; the gradient must re-render against the new box.
    let resized = doc.canvas_resize(60, 32, (10, 0)).expect("canvas resize");
    let after = resized.flattened();
    let rect = (RECT.0 + 10, RECT.1, RECT.2, RECT.3);
    for y in rect.1 as u32..rect.1 as u32 + rect.3 {
        for x in rect.0 as u32..rect.0 as u32 + rect.2 {
            let want = grey((f64::from(x) + 0.5) / 60.0);
            assert_close(
                &px(&after, x, y),
                &want,
                &format!("resized canvas box ({x},{y})"),
            );
        }
    }
    // Byte-identical to the same document rendered without a warm cache.
    let fresh = styled(&rect_doc(), 1, &json)
        .canvas_resize(60, 32, (10, 0))
        .expect("canvas resize")
        .flattened();
    assert_eq!(
        after.into_raw(),
        fresh.into_raw(),
        "the cache key carries the canvas"
    );
    // Aligned with the layer, the same resize changes nothing inside the rect.
    let aligned = styled(&rect_doc(), 1, &overlay("\"angle\":0"));
    let a0 = aligned.flattened();
    let a1 = aligned
        .canvas_resize(60, 32, (10, 0))
        .expect("resize")
        .flattened();
    for y in RECT.1 as u32..RECT.1 as u32 + RECT.3 {
        for x in RECT.0 as u32..RECT.0 as u32 + RECT.2 {
            assert_eq!(
                px(&a0, x, y),
                px(&a1, x + 10, y),
                "layer-aligned ({x},{y}) moves with the layer"
            );
        }
    }
}

#[test]
fn a_mask_shrinks_the_shape_but_not_the_box() {
    // A mask hiding the right half of the rect: no overlay there (the shape
    // is alpha x mask), while the visible columns keep the FULL box's ramp
    // — the box is the layer rect, not the visible shape.
    let split = RECT.0 as u32 + RECT.2 / 2;
    let mask = selection(CANVAS.0, CANVAS.1, |x, _| if x < split { 255 } else { 0 });
    let base = rect_doc()
        .add_mask(1, MaskKind::FromSelection(&mask))
        .expect("mask");
    let doc = styled(&base, 1, &overlay("\"angle\":0"));
    let flat = doc.flattened();
    for y in 0..CANVAS.1 {
        for x in 0..CANVAS.0 {
            let got = px(&flat, x, y);
            let want = if in_rect(RECT, x, y) && x < split {
                grey((f64::from(x - RECT.0 as u32) + 0.5) / f64::from(RECT.2))
            } else {
                WHITE
            };
            assert_close(&got, &want, &format!("masked ({x},{y})"));
        }
    }
}

#[test]
fn fill_opacity_zero_leaves_the_overlay_intact() {
    // At 0 % fill the pixels vanish but the shape stays: the rect area is
    // the ramp drawn straight over the white canvas.
    let doc = styled(
        &rect_doc(),
        1,
        "{\"fill_opacity\":0,\"effects\":[{\"type\":\"gradient_overlay\",\"gradient\":{\"angle\":0}}]}",
    );
    assert_rect(&doc, RECT, "fill 0", |lx, _| {
        grey((f64::from(lx) + 0.5) / f64::from(RECT.2))
    });
}

#[test]
fn a_half_alpha_rect_scales_the_overlay_by_its_coverage() {
    // Coverage 128 both for the pixels and the overlay: the ramp lands over
    // the half-red pixels at the same 128/255, alpha stays 255 exactly.
    let half = [255, 0, 0, 128];
    let doc = styled(
        &rect_layer_doc(CANVAS, RECT, half),
        1,
        &overlay("\"angle\":0"),
    );
    let a = 128.0 / 255.0;
    assert_rect(&doc, RECT, "half alpha", |lx, _| {
        let t = ((f64::from(lx) + 0.5) / f64::from(RECT.2)) as f32;
        let under = ref_composite(to_unit(WHITE), [1.0, 0.0, 0.0, 1.0], a, BLEND_NORMAL);
        quantized(ref_composite(under, [t, t, t, 1.0], a, BLEND_NORMAL))
    });
}

#[test]
fn a_transparent_layer_renders_nothing() {
    let base = RzDocument::from_pixels(solid(CANVAS.0, CANVAS.1, WHITE))
        .adding_image_layer(0, solid(RECT.2, RECT.3, [0, 0, 0, 0]), "Empty")
        .expect("add layer")
        .with_layer_offset(1, RECT.0, RECT.1)
        .expect("offset");
    let doc = styled(&base, 1, &overlay("\"angle\":0"));
    assert_eq!(
        doc.flattened().into_raw(),
        base.flattened().into_raw(),
        "an empty shape draws no gradient"
    );
    // The same through a hide-all mask on an opaque layer.
    let hidden = rect_doc().add_mask(1, MaskKind::HideAll).expect("mask");
    let doc = styled(&hidden, 1, &overlay("\"angle\":0"));
    assert_eq!(
        doc.flattened().into_raw(),
        hidden.flattened().into_raw(),
        "a hidden shape draws no gradient"
    );
}

// ---------------------------------------------------------------- purity --

#[test]
fn setting_the_style_leaves_the_source_document_unchanged() {
    let base = rect_doc();
    let handle = Box::into_raw(Box::new(base.clone()));
    let plain = flat_pixels(handle);
    let json = CString::new(overlay("\"angle\":0")).expect("no interior NUL");
    let mut err: *mut c_char = ptr::null_mut();
    let out = unsafe { rz_doc_set_layer_style(handle, 1, json.as_ptr(), &mut err) };
    assert!(
        !out.is_null(),
        "set_layer_style failed: {}",
        take_err_string(err)
    );
    assert!(err.is_null(), "err_out set on success");
    assert!(ffi_style(handle, 1).is_none(), "the source has no style");
    assert_eq!(
        flat_pixels(handle),
        plain,
        "the source projection is unchanged"
    );
    assert!(
        ffi_style(out, 1).is_some_and(|s| s.contains("gradient_overlay")),
        "the result carries the style"
    );
    assert_ne!(flat_pixels(out), plain, "the result renders the overlay");
    unsafe {
        rz_doc_free(out);
        rz_doc_free(handle);
    }
}
