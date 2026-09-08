//! Inner shadow — black-box through the FFI (`rz_doc_set_layer_style` via
//! `common::styled`) against analytic oracles written from the documented
//! contracts, never a golden image: a hard shadow is the inverted rect
//! translated and clipped (`rect \ (rect + offset)`), a choked one follows
//! the header's grow contract applied to the inverse, a soft one the
//! header's feather kernel (`common::feathered_plane`), and every colour
//! goes through the W3C reference blend. Also the effect's own blend mode
//! on a Multiply layer, enabled/opacity/offset/fill-0/mask/transparent
//! cases, the global light, and purity.

use image::RgbaImage;
use rasterize_core::doc::{BlendMode, MaskKind, RzDocument};

mod common;
use common::*;

// ---------------------------------------------------------------- helpers --

const CANVAS: (u32, u32) = (40, 32);
/// The small rect of the hard oracle (the drop-shadow fixture's twin): a
/// 6x4 rect at (12, 12), so every band the light offsets carve is a few
/// pixels wide and the rest of the rect stays untouched.
const RECT: (i32, i32, u32, u32) = (12, 12, 6, 4);
/// A rect wide enough that a 4 px choke band and a radius-5 blur both
/// leave untouched interior behind them.
const BIG: (i32, i32, u32, u32) = (10, 8, 16, 12);
const BLACK: [f32; 4] = [0.0, 0.0, 0.0, 1.0];

/// One inner-shadow style with the given extra fields.
fn inner_shadow(fields: &str) -> String {
    format!("{{\"effects\":[{{\"type\":\"inner_shadow\",{fields}}}]}}")
}

/// A hard (size 0, choke 0) black inner shadow at `angle`/`distance` with
/// its own light.
fn hard(angle: f32, distance: f32) -> String {
    inner_shadow(&format!(
        "\"use_global_light\":false,\"angle\":{angle},\"distance\":{distance},\"size\":0,\
         \"choke\":0"
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

/// The rect `(x, y, w, h)` shifted by `(dx, dy)` contains `(px, py)`.
fn in_rect(rect: (i32, i32, u32, u32), shift: (i32, i32), px: i64, py: i64) -> bool {
    let x0 = i64::from(rect.0) + i64::from(shift.0);
    let y0 = i64::from(rect.1) + i64::from(shift.1);
    px >= x0 && py >= y0 && px < x0 + i64::from(rect.2) && py < y0 + i64::from(rect.3)
}

/// The shadow colour `color` at `opacity` in `mode` over an opaque `base`
/// pixel, scaled by a coverage byte — the reference for one band pixel.
fn shaded(base: [u8; 4], color: [f32; 4], opacity: f32, cov: u8, mode: i32) -> [u8; 4] {
    quantized(ref_composite(
        to_unit(base),
        color,
        opacity * f32::from(cov) / 255.0,
        mode,
    ))
}

/// The documented blur conventions (style_render.rs module doc): sigma is
/// half the size left after the choke, and the feather radius inverts
/// `sigma = 0.3 (r - 1) + 0.8`, floored at 0.5.
fn feather_radius_for(size: f32, choke: f32) -> f32 {
    let sigma = size * (1.0 - choke) / 2.0;
    if sigma <= 0.0 {
        0.0
    } else {
        ((sigma - 0.8) / 0.3 + 1.0).max(0.5)
    }
}

/// The inverted rect grown by `k` px at canvas pixel (x, y): 255 outside
/// the rect; inside, `round(255 * clamp(k + 1 - d, 0, 1))` with `d` the
/// Euclidean distance to the nearest pixel outside the rect — the header's
/// grow contract (`rz_selection_grow`) applied to the inverse. For a rect
/// that nearest pixel is always axis-aligned, so `d` is the smallest edge
/// distance. `k == 0` gives the plain inverse (every inside pixel has
/// `d >= 1`).
fn grown_inverse(rect: (i32, i32, u32, u32), k: f32, x: i64, y: i64) -> u8 {
    if !in_rect(rect, (0, 0), x, y) {
        return 255;
    }
    let (x0, y0) = (i64::from(rect.0), i64::from(rect.1));
    let (x1, y1) = (x0 + i64::from(rect.2), y0 + i64::from(rect.3));
    let d = (x - x0 + 1).min(x1 - x).min(y - y0 + 1).min(y1 - y) as f32;
    ((k + 1.0 - d).clamp(0.0, 1.0) * 255.0).round() as u8
}

/// The canvas-space coverage plane the effect should produce for an opaque
/// `rect`: the inverse grown by `k`, feathered by `radius` (0 = none),
/// shifted by `shift` (255 beyond the canvas — outside is shadow), and
/// clipped to the rect. Exact for the grow/shift steps; ±1 where the
/// feather rounds. Building it in canvas space is sound because the
/// inverse is 255 everywhere outside the rect, in the core's padded plane
/// and here alike, and clamp-to-edge sampling extends that 255 the same
/// way on both.
fn expected_plane(rect: (i32, i32, u32, u32), k: f32, radius: f32, shift: (i32, i32)) -> Vec<u8> {
    let (w, h) = CANVAS;
    let grown = selection(w, h, |x, y| {
        grown_inverse(rect, k, i64::from(x), i64::from(y))
    });
    let soft = feathered_plane(&grown, w, h, radius);
    selection(w, h, |x, y| {
        let (xi, yi) = (i64::from(x), i64::from(y));
        if !in_rect(rect, (0, 0), xi, yi) {
            return 0;
        }
        let (sx, sy) = (xi - i64::from(shift.0), yi - i64::from(shift.1));
        if sx < 0 || sy < 0 || sx >= i64::from(w) || sy >= i64::from(h) {
            255
        } else {
            soft[(sy * i64::from(w) + sx) as usize]
        }
    })
}

/// Every canvas pixel against `plane` for the DEFAULT shadow (black,
/// Multiply, opacity 0.75) over a RED rect: outside `rect` untouched
/// white; inside, the shadow at the plane's coverage over red — exact at
/// coverage 0 and 255, ±1 between (the feather oracle rounds once, the
/// core once more at the end). The colour/blend/opacity knobs have their
/// own test below.
fn assert_matches_plane(flat: &RgbaImage, rect: (i32, i32, u32, u32), plane: &[u8], what: &str) {
    for y in 0..CANVAS.1 {
        for x in 0..CANVAS.0 {
            let got = px(flat, x, y);
            if !in_rect(rect, (0, 0), i64::from(x), i64::from(y)) {
                assert_eq!(
                    got, WHITE,
                    "{what}: ({x},{y}) outside the rect is untouched"
                );
                continue;
            }
            let cov = plane[(y * CANVAS.0 + x) as usize];
            let want = shaded(RED, BLACK, 0.75, cov, BLEND_MULTIPLY);
            assert_eq!(got[3], 255, "{what}: ({x},{y}) alpha");
            if cov == 0 || cov == 255 {
                assert_eq!(got, want, "{what}: ({x},{y}) coverage {cov} is exact");
            } else {
                assert_close(&got, &want, &format!("{what}: ({x},{y}) coverage {cov}"));
            }
        }
    }
}

fn plane_at(plane: &[u8], x: u32, y: u32) -> u8 {
    plane[(y * CANVAS.0 + x) as usize]
}

// ------------------------------------------------------------- the oracle --

#[test]
fn hard_inner_shadow_is_the_band_inside_the_lit_edge() {
    let band = shaded(RED, BLACK, 0.75, 255, BLEND_MULTIPLY);
    assert_ne!(band, RED, "the fixture distinguishes shadow from rect");
    // The light offset is the drop shadow's: (round(-d cos a), round(d sin a)).
    // The outside slides by it into the shape, so the shadow is
    // rect \ (rect + offset): at 0° (light from the right) the 3 columns
    // inside the right edge, at 90° (from the top) the 3 rows under the
    // top edge, at 120° an L along the top and left.
    for (angle, shift) in [
        (0.0, (-3, 0)),
        (90.0, (0, 3)),
        (120.0, (2, 3)),
        (180.0, (3, 0)),
        (-90.0, (0, -3)),
    ] {
        let doc = styled(&rect_layer_doc(CANVAS, RECT, RED), 1, &hard(angle, 3.0));
        let flat = doc.flattened();
        let mut shadowed = 0u32;
        for y in 0..CANVAS.1 {
            for x in 0..CANVAS.0 {
                let (xi, yi) = (i64::from(x), i64::from(y));
                let want = if !in_rect(RECT, (0, 0), xi, yi) {
                    WHITE
                } else if in_rect(RECT, shift, xi, yi) {
                    RED
                } else {
                    shadowed += 1;
                    band
                };
                assert_eq!(px(&flat, x, y), want, "angle {angle} ({x},{y})");
            }
        }
        let kept = (RECT.2 - shift.0.unsigned_abs()) * (RECT.3 - shift.1.unsigned_abs());
        assert_eq!(
            shadowed,
            RECT.2 * RECT.3 - kept,
            "angle {angle}: the band is exactly rect minus the shifted rect"
        );
    }
}

#[test]
fn choke_pulls_the_shadow_inward_by_the_grow_closed_form() {
    // Choke 1 at size 4: dilate the inverse by 4, no blur. At distance 0
    // that is a 4 px band at full coverage inside every edge, the interior
    // clear — the grow-rect closed form on the inverse.
    let doc = styled(
        &rect_layer_doc(CANVAS, BIG, RED),
        1,
        &inner_shadow(
            "\"use_global_light\":false,\"angle\":0,\"distance\":0,\"size\":4,\"choke\":1",
        ),
    );
    let plane = expected_plane(BIG, 4.0, 0.0, (0, 0));
    assert_eq!(plane_at(&plane, 13, 14), 255, "4th pixel in is band");
    assert_eq!(plane_at(&plane, 14, 14), 0, "5th pixel in is clear");
    assert_eq!(plane_at(&plane, 18, 11), 255, "4th row down is band");
    assert_eq!(plane_at(&plane, 18, 12), 0, "5th row down is clear");
    assert_matches_plane(&doc.flattened(), BIG, &plane, "choke 1, distance 0");

    // With distance 3 at 0° the grown inverse slides left by 3 before the
    // clip: the right band is 4 + 3 = 7 px, the left band 4 - 3 = 1 px,
    // top and bottom stay 4.
    let doc = styled(
        &rect_layer_doc(CANVAS, BIG, RED),
        1,
        &inner_shadow(
            "\"use_global_light\":false,\"angle\":0,\"distance\":3,\"size\":4,\"choke\":1",
        ),
    );
    let plane = expected_plane(BIG, 4.0, 0.0, (-3, 0));
    assert_eq!(plane_at(&plane, 19, 14), 255, "right band starts 7 px in");
    assert_eq!(plane_at(&plane, 18, 14), 0, "and is clear before that");
    assert_eq!(plane_at(&plane, 10, 14), 255, "left band is 1 px");
    assert_eq!(plane_at(&plane, 11, 14), 0, "and clear after it");
    assert_matches_plane(&doc.flattened(), BIG, &plane, "choke 1, distance 3");

    // Choke 0.5 at size 4: dilate by 2, THEN blur the remaining 2 px
    // (sigma 1) — the order the split defines; the oracle composes the
    // closed forms the same way.
    let doc = styled(
        &rect_layer_doc(CANVAS, BIG, RED),
        1,
        &inner_shadow(
            "\"use_global_light\":false,\"angle\":0,\"distance\":0,\"size\":4,\"choke\":0.5",
        ),
    );
    let plane = expected_plane(BIG, 2.0, feather_radius_for(4.0, 0.5), (0, 0));
    let soft = plane.iter().filter(|&&c| c > 0 && c < 255).count();
    assert!(soft > 0, "the half choke leaves a soft ramp");
    assert_matches_plane(&doc.flattened(), BIG, &plane, "choke 0.5");
}

#[test]
fn soft_inner_shadow_matches_the_feather_oracle() {
    // Size 4 -> sigma 2 -> feather radius (2 - 0.8) / 0.3 + 1 = 5; the
    // inverse is blurred first and shifted by the 120° offset (2, 3) after.
    let doc = styled(
        &rect_layer_doc(CANVAS, BIG, RED),
        1,
        &inner_shadow(
            "\"use_global_light\":false,\"angle\":120,\"distance\":3,\"size\":4,\"choke\":0",
        ),
    );
    let radius = feather_radius_for(4.0, 0.0);
    assert!((radius - 5.0).abs() < 1e-4);
    let plane = expected_plane(BIG, 0.0, radius, (2, 3));
    let mut clear = 0;
    let mut soft = 0;
    for y in BIG.1 as u32..BIG.1 as u32 + BIG.3 {
        for x in BIG.0 as u32..BIG.0 as u32 + BIG.2 {
            match plane_at(&plane, x, y) {
                0 => clear += 1,
                255 => {}
                _ => soft += 1,
            }
        }
    }
    assert!(
        clear > 0,
        "the interior beyond the blur's reach is untouched"
    );
    assert!(soft > 0, "the blur is real");
    // The top-left corner reads the true outside shifted in and is deepest
    // in shadow; (20, 17) reads (18, 14), which is 6+ px from every outside
    // pixel — past the 11-tap kernel's half-width of 5 — so it is clear.
    // (The rect's own far corners are NOT clear: the blur of the inverse
    // reaches in from every edge, lit or not, and only the shift favours
    // the lit ones.)
    assert!(
        plane_at(&plane, 10, 8) > 200,
        "top-left corner is deep shadow"
    );
    assert_eq!(plane_at(&plane, 20, 17), 0, "interior beyond the reach");
    assert!(
        plane_at(&plane, 25, 19) > 0,
        "far corner still catches the blur"
    );
    assert_matches_plane(&doc.flattened(), BIG, &plane, "size 4 at 120°");
}

// ----------------------------------------------------------- blend & knobs --

#[test]
fn shadow_blend_opacity_and_enabled_follow_the_reference() {
    // A grey shadow over a BLUE rect, so Normal, Multiply and Screen all
    // differ; band pixel (16, 13) sits in the 3 columns inside the right
    // edge, (13, 13) outside the band, (30, 13) outside the rect.
    let grey = [128u8, 128, 128, 255];
    let base = rect_layer_doc(CANVAS, RECT, BLUE);
    for (name, mode) in [
        ("normal", BLEND_NORMAL),
        ("multiply", BLEND_MULTIPLY),
        ("screen", BLEND_SCREEN),
    ] {
        let doc = styled(
            &base,
            1,
            &inner_shadow(&format!(
                "\"use_global_light\":false,\"angle\":0,\"distance\":3,\"size\":0,\
                 \"blend\":\"{name}\",\"color\":\"#808080\",\"opacity\":0.6"
            )),
        );
        let flat = doc.flattened();
        let want = shaded(BLUE, to_unit(grey), 0.6, 255, mode);
        assert_close(&px(&flat, 16, 13), &want, name);
        assert_eq!(px(&flat, 13, 13), BLUE, "{name}: the rest of the rect");
        assert_eq!(px(&flat, 30, 13), WHITE, "{name}: outside the rect");
    }
    let plain = base.flattened().into_raw();
    let off = styled(&base, 1, &inner_shadow("\"opacity\":0"));
    assert_eq!(
        off.flattened().into_raw(),
        plain,
        "opacity 0 renders nothing"
    );
    let disabled = styled(
        &base,
        1,
        "{\"fill_opacity\":0.5,\"effects\":[{\"type\":\"inner_shadow\",\"enabled\":false}]}",
    );
    assert_eq!(
        disabled.flattened().into_raw(),
        base.with_layer_opacity(1, 0.5)
            .unwrap()
            .flattened()
            .into_raw(),
        "a disabled effect renders nothing"
    );
}

#[test]
fn interior_effects_keep_their_own_blend_on_a_multiply_layer() {
    // A Multiply-blend BLUE layer over grey: the pixels multiply, but a
    // Normal-blend white inner shadow composites Normal over the result
    // ("Blend Interior Effects as Group" is off) — under Multiply a white
    // shadow would change nothing at all.
    let grey = [128u8, 128, 128, 255];
    let doc = RzDocument::from_pixels(solid(CANVAS.0, CANVAS.1, grey))
        .adding_image_layer(0, solid(RECT.2, RECT.3, BLUE), "Rect")
        .unwrap()
        .with_layer_offset(1, RECT.0, RECT.1)
        .unwrap()
        .with_layer_blend_mode(1, BlendMode::Multiply)
        .unwrap();
    let doc = styled(
        &doc,
        1,
        &inner_shadow(
            "\"use_global_light\":false,\"angle\":0,\"distance\":3,\"size\":0,\
             \"blend\":\"normal\",\"color\":\"#ffffff\",\"opacity\":0.75",
        ),
    );
    let flat = doc.flattened();
    let pixel = ref_composite(to_unit(grey), to_unit(BLUE), 1.0, BLEND_MULTIPLY);
    let want = quantized(ref_composite(pixel, [1.0; 4], 0.75, BLEND_NORMAL));
    let not_want = quantized(ref_composite(pixel, [1.0; 4], 0.75, BLEND_MULTIPLY));
    assert_ne!(want, not_want, "the fixture distinguishes the two modes");
    assert_close(&px(&flat, 16, 13), &want, "the shadow uses its own Normal");
    assert_close(
        &px(&flat, 13, 13),
        &quantized(pixel),
        "the layer's pixels use Multiply",
    );
    assert_eq!(px(&flat, 30, 13), grey, "outside the rect");
}

#[test]
fn fill_opacity_zero_leaves_the_shadow_intact() {
    // The pixels vanish, the shadow stays: over the white that shows
    // through, at the same band.
    let doc = styled(
        &rect_layer_doc(CANVAS, RECT, RED),
        1,
        "{\"fill_opacity\":0,\"effects\":[{\"type\":\"inner_shadow\",\"use_global_light\":false,\
         \"angle\":0,\"distance\":3,\"size\":0,\"choke\":0}]}",
    );
    let flat = doc.flattened();
    let band = shaded(WHITE, BLACK, 0.75, 255, BLEND_MULTIPLY);
    for y in 0..CANVAS.1 {
        for x in 0..CANVAS.0 {
            let (xi, yi) = (i64::from(x), i64::from(y));
            let want = if in_rect(RECT, (0, 0), xi, yi) && !in_rect(RECT, (-3, 0), xi, yi) {
                band
            } else {
                WHITE
            };
            assert_eq!(px(&flat, x, y), want, "({x},{y})");
        }
    }
}

// ------------------------------------------------------------ shape cases --

#[test]
fn layer_offset_maps_the_band_onto_the_canvas() {
    let band = shaded(RED, BLACK, 0.75, 255, BLEND_MULTIPLY);
    let check = |rect: (i32, i32, u32, u32), angle: f32, shift: (i32, i32)| {
        let doc = styled(&rect_layer_doc(CANVAS, rect, RED), 1, &hard(angle, 3.0));
        let flat = doc.flattened();
        let mut shadowed = 0;
        for y in 0..CANVAS.1 {
            for x in 0..CANVAS.0 {
                let (xi, yi) = (i64::from(x), i64::from(y));
                let want = if !in_rect(rect, (0, 0), xi, yi) {
                    WHITE
                } else if in_rect(rect, shift, xi, yi) {
                    RED
                } else {
                    shadowed += 1;
                    band
                };
                assert_eq!(
                    px(&flat, x, y),
                    want,
                    "rect {rect:?} angle {angle} ({x},{y})"
                );
            }
        }
        shadowed
    };
    // Hanging off the top-left: the band inside the right edge is on
    // canvas (columns 2..5 of the 8-wide rect ending at x = 5), 3 x 4 rows.
    assert_eq!(check((-3, -2, 8, 6), 0.0, (-3, 0)), 12);
    // Hanging off the bottom-right: at 0° the band is entirely off-canvas
    // (nothing but red shows); at 180° it is the 3 columns inside the
    // LEFT edge, on canvas.
    assert_eq!(check((36, 28, 8, 6), 0.0, (-3, 0)), 0);
    assert_eq!(check((36, 28, 8, 6), 180.0, (3, 0)), 12);
}

#[test]
fn the_enabled_mask_is_part_of_the_shape() {
    // A mask hiding the right half of the rect makes the SHAPE the left
    // half (columns 12..15): at 0° with distance 2 the band is the 2
    // columns inside the half's right edge, and the hidden half is white.
    let sel = selection(CANVAS.0, CANVAS.1, |x, _| u8::from(x < 15) * 255);
    let masked = rect_layer_doc(CANVAS, RECT, RED)
        .add_mask(1, MaskKind::FromSelection(&sel))
        .unwrap();
    let band = shaded(RED, BLACK, 0.75, 255, BLEND_MULTIPLY);
    let doc = styled(&masked, 1, &hard(0.0, 2.0));
    let flat = doc.flattened();
    for y in 0..CANVAS.1 {
        for x in 0..CANVAS.0 {
            let (xi, yi) = (i64::from(x), i64::from(y));
            let want = if !in_rect(RECT, (0, 0), xi, yi) || x >= 15 {
                WHITE
            } else if x >= 13 {
                band
            } else {
                RED
            };
            assert_eq!(px(&flat, x, y), want, "masked ({x},{y})");
        }
    }
    // Disabling the mask restores the whole rect as the shape: the band
    // moves back to the rect's own right edge.
    let unmasked = doc.set_mask_enabled(1, false).unwrap();
    let flat = unmasked.flattened();
    for y in 0..CANVAS.1 {
        for x in 0..CANVAS.0 {
            let (xi, yi) = (i64::from(x), i64::from(y));
            let want = if !in_rect(RECT, (0, 0), xi, yi) {
                WHITE
            } else if in_rect(RECT, (-2, 0), xi, yi) {
                RED
            } else {
                band
            };
            assert_eq!(px(&flat, x, y), want, "mask disabled ({x},{y})");
        }
    }
}

#[test]
fn a_half_alpha_shape_bounds_the_shadow() {
    // Shape = alpha: a rect at alpha 128 has coverage 128 and inverse 127,
    // so after the shift the band reads 255 (true outside) and the rest of
    // the rect 127 (its own half-clear inverse); both are multiplied by
    // the coverage 128 — the plan's formula, computed here by hand.
    let half = [255u8, 0, 0, 128];
    let doc = styled(&rect_layer_doc(CANVAS, RECT, half), 1, &hard(0.0, 3.0));
    let flat = doc.flattened();
    let pixel = ref_composite(to_unit(WHITE), to_unit(half), 1.0, BLEND_NORMAL);
    let cov_of = |inverse: u32| ((inverse * 128 + 127) / 255) as u8;
    assert_eq!(cov_of(255), 128);
    assert_eq!(cov_of(127), 64);
    for y in 0..CANVAS.1 {
        for x in 0..CANVAS.0 {
            let (xi, yi) = (i64::from(x), i64::from(y));
            let got = px(&flat, x, y);
            if !in_rect(RECT, (0, 0), xi, yi) {
                assert_eq!(got, WHITE, "({x},{y})");
                continue;
            }
            let cov = if in_rect(RECT, (-3, 0), xi, yi) {
                cov_of(127)
            } else {
                cov_of(255)
            };
            let want = quantized(ref_composite(
                pixel,
                BLACK,
                0.75 * f32::from(cov) / 255.0,
                BLEND_MULTIPLY,
            ));
            assert_close(&got, &want, &format!("({x},{y}) coverage {cov}"));
            assert_ne!(
                got,
                quantized(pixel),
                "({x},{y}) every shape pixel is shaded"
            );
        }
    }
}

#[test]
fn a_transparent_layer_renders_nothing() {
    let doc = RzDocument::from_pixels(solid(CANVAS.0, CANVAS.1, WHITE))
        .adding_image_layer(0, solid(RECT.2, RECT.3, [0, 0, 0, 0]), "Clear")
        .unwrap()
        .with_layer_offset(1, RECT.0, RECT.1)
        .unwrap();
    let styled_doc = styled(&doc, 1, &inner_shadow("\"size\":6,\"choke\":0.5"));
    assert_eq!(
        styled_doc.flattened().into_raw(),
        solid(CANVAS.0, CANVAS.1, WHITE).into_raw()
    );
}

#[test]
fn nothing_to_cast_and_everything_to_cast() {
    // A hard shape at distance 0 with no size: the inverse times the
    // coverage is zero everywhere, so the projection is the unstyled one.
    let base = rect_layer_doc(CANVAS, RECT, RED);
    let none = styled(&base, 1, &hard(0.0, 0.0));
    assert_eq!(none.flattened().into_raw(), base.flattened().into_raw());
    // A distance beyond the rect's width slides only "outside" onto it:
    // every rect pixel is shadow (the pad grows with the distance, so the
    // shifted-in region is the plane's border fill).
    let all = styled(&base, 1, &hard(0.0, 40.0));
    let flat = all.flattened();
    let band = shaded(RED, BLACK, 0.75, 255, BLEND_MULTIPLY);
    for y in 0..CANVAS.1 {
        for x in 0..CANVAS.0 {
            let want = if in_rect(RECT, (0, 0), i64::from(x), i64::from(y)) {
                band
            } else {
                WHITE
            };
            assert_eq!(px(&flat, x, y), want, "({x},{y})");
        }
    }
}

// ------------------------------------------------------- light & purity --

#[test]
fn use_global_light_reads_the_document_light() {
    let json = inner_shadow("\"use_global_light\":true,\"distance\":3,\"size\":0,\"choke\":0");
    let band = shaded(RED, BLACK, 0.75, 255, BLEND_MULTIPLY);
    let doc = styled(&rect_layer_doc(CANVAS, RECT, RED), 1, &json);
    // Default light 120°: offset (2, 3), the band is the left 2 columns
    // and top 3 rows; (12, 15) is in it, (17, 15) is not.
    let before = doc.flattened();
    assert_eq!(px(&before, 12, 15), band, "left band at 120°");
    assert_eq!(
        px(&before, 17, 15),
        RED,
        "bottom-right corner clear at 120°"
    );
    // Light from the right on a clone sharing the Arc<LayerStyle>: the
    // band moves to the right edge (the cache key carries the light).
    let lit = with_light(&doc, 0.0, 30.0);
    let after = lit.flattened();
    assert_eq!(px(&after, 17, 15), band, "right band at 0°");
    assert_eq!(px(&after, 12, 15), RED, "left edge clear at 0°");
    assert_eq!(
        doc.flattened().into_raw(),
        before.into_raw(),
        "the original is untouched"
    );
    // A style with its own light ignores the document's.
    let own = styled(&rect_layer_doc(CANVAS, RECT, RED), 1, &hard(120.0, 3.0));
    assert_eq!(
        own.flattened().into_raw(),
        with_light(&own, 0.0, 30.0).flattened().into_raw()
    );
}

#[test]
fn purity_and_tiny_layers() {
    let base = rect_layer_doc(CANVAS, RECT, RED);
    let plain = base.flattened().into_raw();
    let doc = styled(&base, 1, &hard(0.0, 3.0));
    assert!(base.layers[1].style.is_none(), "the source gained no style");
    assert!(doc.layers[1].style.is_some());
    assert_eq!(
        base.flattened().into_raw(),
        plain,
        "the source renders as before"
    );
    assert_ne!(doc.flattened().into_raw(), plain, "the result differs");

    // A 1x1 layer with every knob at its extreme: no panic, and the lone
    // pixel — one pixel from "outside" on every side, well within a 250 px
    // choke — is fully shadowed.
    let tiny = RzDocument::from_pixels(solid(8, 8, WHITE))
        .adding_image_layer(0, solid(1, 1, RED), "Dot")
        .unwrap()
        .with_layer_offset(1, 3, 3)
        .unwrap();
    let dot = styled(
        &tiny,
        1,
        &inner_shadow(
            "\"use_global_light\":false,\"angle\":45,\"distance\":250,\"size\":250,\"choke\":1",
        ),
    );
    let flat = dot.flattened();
    let band = shaded(RED, BLACK, 0.75, 255, BLEND_MULTIPLY);
    for y in 0..8 {
        for x in 0..8 {
            let want = if (x, y) == (3, 3) { band } else { WHITE };
            assert_eq!(px(&flat, x, y), want, "({x},{y})");
        }
    }
    // The same dot with a soft, unchoked shadow: still no panic, alpha
    // intact everywhere.
    let soft = styled(&tiny, 1, &inner_shadow("\"distance\":0,\"size\":40"));
    let flat = soft.flattened();
    assert!(flat.pixels().all(|p| p.0[3] == 255));
}
