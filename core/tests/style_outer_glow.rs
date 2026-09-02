//! Outer glow tests: the `outer_glow` effect of a layer style — Layer >
//! Layer Style > Outer Glow. The oracles are closed-form geometry on a hard
//! rect (the grow-rect formula of the header's `rz_selection_grow` contract
//! for spread, the header's feather kernel rebuilt in `tests/common` for
//! size) and the W3C reference blend; every style is applied through the
//! FFI (`rz_doc_set_layer_style`) on documents built from the safe
//! constructors. Shared fixtures live in `tests/common`.

use std::sync::Arc;

use image::{Rgba, RgbaImage};
use rasterize_core::doc::{BlendMode, MaskKind, RzDocument};

mod common;
use common::*;

// ---------------------------------------------------------------- helpers --

/// A 40x32 canvas with a 6x4 rect at (12, 12): a size-4 halo (reach 5 at
/// spread 1, kernel half-width 5 at spread 0) never touches the border, so
/// canvas-space oracles equal the core's plane-space render exactly.
const CANVAS: (u32, u32) = (40, 32);
const RECT: (i32, i32, u32, u32) = (12, 12, 6, 4);
/// Dark enough that Screen (the default blend) is visible: over white,
/// Screen is the identity.
const DARK: [u8; 4] = [40, 40, 40, 255];
const GREY: [u8; 4] = [128, 128, 128, 255];
/// The schema's default glow colour.
const GLOW: [f32; 3] = [1.0, 1.0, 190.0 / 255.0];

/// `{"effects":[{"type":"outer_glow", <fields>}]}`.
fn glow_json(fields: &str) -> String {
    format!("{{\"effects\":[{{\"type\":\"outer_glow\",{fields}}}]}}")
}

/// The brief's main case: spread 1, size 4 — the rect grown by 4 with no
/// blur — with `extra` fields appended.
fn spread_glow(extra: &str) -> String {
    glow_json(&format!("\"spread\":1,\"size\":4{extra}"))
}

/// White canvas under the red rect (the shared fixture).
fn rect_doc() -> RzDocument {
    rect_layer_doc(CANVAS, RECT, RED)
}

/// A `bg`-coloured canvas under the red rect.
fn rect_on(bg: [u8; 4]) -> RzDocument {
    let doc = RzDocument::from_pixels(solid(CANVAS.0, CANVAS.1, bg));
    doc.adding_image_layer(0, solid(RECT.2, RECT.3, RED), "Rect")
        .expect("add rect layer")
        .with_layer_offset(1, RECT.0, RECT.1)
        .expect("offset")
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

fn assert_px_close(got: [u8; 4], want: [u8; 4], what: &str) {
    assert_close(&got, &want, what);
}

/// Whether `(px, py)` lies in `rect` = (x, y, w, h).
fn in_rect(rect: (i32, i32, u32, u32), px: i64, py: i64) -> bool {
    let (x0, y0) = (i64::from(rect.0), i64::from(rect.1));
    px >= x0 && py >= y0 && px < x0 + i64::from(rect.2) && py < y0 + i64::from(rect.3)
}

/// The grow-rect closed form (rasterize_core.h, rz_selection_grow, for a
/// rect): inside 255; outside `round(255 * clamp(r + 1 - d, 0, 1))` with
/// `d` the Euclidean distance to the nearest rect pixel
/// `(clamp(x, x0, x1 - 1), clamp(y, y0, y1 - 1))`.
fn grown_rect(rect: (i32, i32, u32, u32), r: f32, px: i64, py: i64) -> u8 {
    if in_rect(rect, px, py) {
        return 255;
    }
    let (x0, y0) = (i64::from(rect.0), i64::from(rect.1));
    let (x1, y1) = (x0 + i64::from(rect.2) - 1, y0 + i64::from(rect.3) - 1);
    let nx = px.clamp(x0, x1);
    let ny = py.clamp(y0, y1);
    let d = (((px - nx).pow(2) + (py - ny).pow(2)) as f32).sqrt();
    ((r + 1.0 - d).clamp(0.0, 1.0) * 255.0).round() as u8
}

/// The canvas-sized hard selection of `rect`.
fn rect_selection(rect: (i32, i32, u32, u32)) -> Vec<u8> {
    selection(CANVAS.0, CANVAS.1, |x, y| {
        u8::from(in_rect(rect, i64::from(x), i64::from(y))) * 255
    })
}

/// A glow pixel: `color` at `opacity * cov / 255` over `bg` with `mode`,
/// per the W3C reference, quantized once.
fn glow_pixel(bg: [u8; 4], color: [f32; 3], opacity: f32, cov: u8, mode: i32) -> [u8; 4] {
    quantized(ref_composite(
        to_unit(bg),
        [color[0], color[1], color[2], 1.0],
        opacity * f32::from(cov) / 255.0,
        mode,
    ))
}

/// Checks every canvas pixel of `flat` against `oracle(x, y) -> coverage`
/// for a glow of `color` at `opacity` with `mode` over `bg`; the rect's
/// own pixels are skipped when `rect_color` is None, else asserted exactly.
/// Zero coverage must leave `bg` untouched, everything else is ±1.
fn assert_glow(
    flat: &RgbaImage,
    bg: [u8; 4],
    rect_color: Option<[u8; 4]>,
    color: [f32; 3],
    opacity: f32,
    mode: i32,
    oracle: impl Fn(i64, i64) -> u8,
) -> (usize, usize) {
    let (mut bulk_glow, mut bulk_bg) = (0, 0);
    for y in 0..CANVAS.1 {
        for x in 0..CANVAS.0 {
            let got = px(flat, x, y);
            let (xi, yi) = (i64::from(x), i64::from(y));
            if in_rect(RECT, xi, yi) {
                if let Some(rc) = rect_color {
                    assert_eq!(got, rc, "({x},{y}) the rect's own pixels");
                }
                continue;
            }
            let cov = oracle(xi, yi);
            assert_eq!(got[3], 255, "({x},{y}) alpha is exact");
            if cov == 0 {
                bulk_bg += 1;
                assert_eq!(got, bg, "({x},{y}) zero coverage is untouched");
                continue;
            }
            if cov == 255 {
                bulk_glow += 1;
            }
            let want = glow_pixel(bg, color, opacity, cov, mode);
            assert_px_close(got, want, &format!("({x},{y}) coverage {cov}"));
        }
    }
    (bulk_glow, bulk_bg)
}

// ----------------------------------------------------------- the oracles --

#[test]
fn spread_glow_is_the_rect_grown_by_size_minus_the_rect() {
    // The brief's main oracle: spread 1 at size 4 dilates by 4 and blurs by
    // 0, so the halo is the grow-rect closed form outside the rect and
    // nothing under it. Defaults otherwise (#ffffbe, 0.75, Screen), over a
    // dark canvas where Screen shows.
    let doc = styled(&rect_on(DARK), 1, &spread_glow(""));
    let flat = doc.flattened();
    let (bulk_glow, bulk_bg) =
        assert_glow(&flat, DARK, Some(RED), GLOW, 0.75, BLEND_SCREEN, |x, y| {
            grown_rect(RECT, 4.0, x, y)
        });
    assert!(bulk_glow > 0, "the full-coverage band exists");
    assert!(bulk_bg > 0, "the untouched bulk exists");
    // Sanity pins independent of the formula: the halo's straight edges
    // are 4 px wide (the size), the diagonal corner is rounded.
    assert_eq!(grown_rect(RECT, 4.0, 8, 13), 255, "4 px out is full");
    assert_eq!(grown_rect(RECT, 4.0, 7, 13), 0, "5 px out is empty");
    assert_eq!(
        grown_rect(RECT, 4.0, 8, 8),
        0,
        "the corner at sqrt(32) is gone"
    );
    let ring = grown_rect(RECT, 4.0, 9, 9);
    assert!(
        ring > 0 && ring < 255,
        "sqrt(18) = 4.24 is on the ramp: {ring}"
    );
}

#[test]
fn a_normal_glow_over_white_shows_the_geometry_and_screen_is_invisible() {
    // Normal blue at opacity 1: a full-coverage halo pixel IS the glow
    // colour, so the geometry is pinned exactly, not just ±1.
    let doc = styled(
        &rect_doc(),
        1,
        &spread_glow(",\"blend\":\"normal\",\"color\":\"#0000ff\",\"opacity\":1"),
    );
    let flat = doc.flattened();
    assert_glow(
        &flat,
        WHITE,
        Some(RED),
        [0.0, 0.0, 1.0],
        1.0,
        BLEND_NORMAL,
        |x, y| grown_rect(RECT, 4.0, x, y),
    );
    assert_eq!(px(&flat, 8, 13), BLUE, "full coverage is the glow colour");
    assert_eq!(px(&flat, 15, 8), BLUE);
    assert_eq!(px(&flat, 7, 13), WHITE);
    // The brief's literal case — the default Screen over white — composites
    // to white everywhere (screen(1, c) = 1 for every c): the halo is
    // there, just invisible, so the projection is the unstyled one.
    let screened = styled(&rect_doc(), 1, &spread_glow("")).flattened();
    assert_eq!(
        screened.into_raw(),
        rect_doc().flattened().into_raw(),
        "Screen over white is the identity"
    );
}

#[test]
fn soft_glow_matches_the_feather_oracle() {
    // spread 0, size 4 -> sigma 2 -> feather radius (2 - 0.8) / 0.3 + 1 = 5.
    // The plane is the rect blurred by that kernel, then zeroed under the
    // rect (the inverted-shape multiply); in canvas space the same blur of
    // the rect's selection, since neither reaches a border.
    let doc = styled(
        &rect_doc(),
        1,
        &glow_json(
            "\"spread\":0,\"size\":4,\"blend\":\"normal\",\"color\":\"#0000ff\",\"opacity\":1",
        ),
    );
    let flat = doc.flattened();
    let plane = feathered_plane(&rect_selection(RECT), CANVAS.0, CANVAS.1, 5.0);
    let (_, bulk_bg) = assert_glow(
        &flat,
        WHITE,
        Some(RED),
        [0.0, 0.0, 1.0],
        1.0,
        BLEND_NORMAL,
        |x, y| {
            if in_rect(RECT, x, y) {
                0
            } else {
                plane[(y * i64::from(CANVAS.0) + x) as usize]
            }
        },
    );
    assert!(bulk_bg > 0, "the untouched bulk exists");
    // Monotone fade away from the rect along the middle row, and the
    // kernel's half-width (5) is where it ends.
    // (Columns 2..=11: column 12 is the rect itself.)
    let row: Vec<u8> = (2..=11).map(|x| px(&flat, x, 13)[0]).collect();
    assert!(
        row.windows(2).all(|w| w[0] >= w[1]),
        "red fades in toward the rect: {row:?}"
    );
    assert_eq!(px(&flat, 6, 13), WHITE, "beyond the kernel half-width");
    assert_ne!(px(&flat, 7, 13), WHITE, "inside the kernel half-width");
}

#[test]
fn partial_spread_dilates_then_blurs() {
    // spread 0.5 at size 4: dilate by 2, then blur by size 2 (sigma 1,
    // feather radius (1 - 0.8) / 0.3 + 1 = 1.667). The oracle is the
    // grow-rect closed form at r = 2 fed through the feather kernel, then
    // zeroed under the rect. Tolerance ±2 on colour: the grown ring may sit
    // ±1 from the closed form (f32 sqrt on the diagonal), the blur carries
    // that through, and the composite quantizes once more.
    let doc = styled(
        &rect_doc(),
        1,
        &glow_json(
            "\"spread\":0.5,\"size\":4,\"blend\":\"normal\",\"color\":\"#0000ff\",\"opacity\":1",
        ),
    );
    let flat = doc.flattened();
    let grown = selection(CANVAS.0, CANVAS.1, |x, y| {
        grown_rect(RECT, 2.0, i64::from(x), i64::from(y))
    });
    let radius = (1.0 - 0.8) / 0.3 + 1.0;
    let plane = feathered_plane(&grown, CANVAS.0, CANVAS.1, radius);
    let mut touched = 0;
    for y in 0..CANVAS.1 {
        for x in 0..CANVAS.0 {
            let got = px(&flat, x, y);
            let (xi, yi) = (i64::from(x), i64::from(y));
            if in_rect(RECT, xi, yi) {
                assert_eq!(got, RED);
                continue;
            }
            let cov = plane[(y * CANVAS.0 + x) as usize];
            let want = glow_pixel(WHITE, [0.0, 0.0, 1.0], 1.0, cov, BLEND_NORMAL);
            assert_eq!(got[3], 255);
            for c in 0..3 {
                assert!(
                    (i32::from(got[c]) - i32::from(want[c])).abs() <= 2,
                    "({x},{y}) channel {c}: {} vs {} (coverage {cov})",
                    got[c],
                    want[c]
                );
            }
            if cov > 0 {
                touched += 1;
            }
        }
    }
    assert!(touched > 0);
    // Reach pins independent of the kernel's weights: the halo ends at the
    // dilation (2) plus the kernel half-width (taps = nearest_odd(4.33) = 5,
    // half 2), i.e. 4 px out — column 8 is touched, column 7 is not — and
    // fades monotonically toward the rect.
    assert_ne!(px(&flat, 8, 13), WHITE, "4 px out: dilation + half-width");
    assert_eq!(px(&flat, 7, 13), WHITE, "5 px out: past the reach");
    let row: Vec<u8> = (4..=11).map(|x| px(&flat, x, 13)[0]).collect();
    assert!(
        row.windows(2).all(|w| w[0] >= w[1]),
        "red fades in toward the rect: {row:?}"
    );
}

#[test]
fn size_zero_opacity_zero_and_disabled_render_nothing() {
    let plain = rect_on(DARK).flattened().into_raw();
    for fields in [
        "\"size\":0,\"spread\":0",
        "\"size\":0,\"spread\":1",
        "\"opacity\":0",
    ] {
        let doc = styled(&rect_on(DARK), 1, &glow_json(fields));
        assert!(
            doc.layers[1].style.is_some(),
            "{fields}: the style is stored"
        );
        assert_eq!(
            doc.flattened().into_raw(),
            plain,
            "{fields}: renders nothing"
        );
    }
    // A disabled effect alone is an identity (never stored), so pair it
    // with a fill opacity and compare against the same layer opacity.
    let disabled = styled(
        &rect_on(DARK),
        1,
        "{\"fill_opacity\":0.5,\"effects\":[{\"type\":\"outer_glow\",\"enabled\":false,\
         \"size\":4,\"spread\":1}]}",
    );
    assert_eq!(
        disabled.flattened().into_raw(),
        rect_on(DARK)
            .with_layer_opacity(1, 0.5)
            .unwrap()
            .flattened()
            .into_raw(),
        "a disabled glow renders nothing"
    );
}

#[test]
fn own_blend_and_opacity_follow_the_reference() {
    // (10, 13) is 2 px left of the rect: full coverage at spread 1, size 4.
    for (name, mode) in [
        ("normal", BLEND_NORMAL),
        ("multiply", BLEND_MULTIPLY),
        ("screen", BLEND_SCREEN),
        ("overlay", BLEND_OVERLAY),
        ("difference", BLEND_DIFFERENCE),
    ] {
        let doc = styled(
            &rect_on(GREY),
            1,
            &spread_glow(&format!(
                ",\"blend\":\"{name}\",\"color\":\"#40c0ff\",\"opacity\":0.6"
            )),
        );
        let flat = doc.flattened();
        let color = [64.0 / 255.0, 192.0 / 255.0, 1.0];
        let want = glow_pixel(GREY, color, 0.6, 255, mode);
        assert_px_close(px(&flat, 10, 13), want, name);
        assert_px_close(px(&flat, 15, 17), want, &format!("{name} below the rect"));
        assert_eq!(px(&flat, 30, 13), GREY, "{name}: far pixels untouched");
        assert_eq!(px(&flat, 13, 13), RED, "{name}: the rect is untouched");
    }
    // Opacity scales the coverage: 0.3 at full coverage equals 0.6 at half.
    let a = styled(
        &rect_on(GREY),
        1,
        &spread_glow(",\"blend\":\"normal\",\"opacity\":0.3"),
    );
    let want = glow_pixel(GREY, GLOW, 0.6, 128, BLEND_NORMAL);
    assert_px_close(
        px(&a.flattened(), 10, 13),
        want,
        "opacity 0.3 at full coverage",
    );
}

#[test]
fn glow_keeps_its_own_blend_on_a_multiply_layer() {
    // A Multiply-blend LAYER with a Normal-blend white glow: the halo
    // follows Normal (Below effects never inherit the layer's mode) while
    // the pixels still multiply.
    let doc = RzDocument::from_pixels(solid(CANVAS.0, CANVAS.1, GREY));
    let doc = doc
        .adding_image_layer(0, solid(RECT.2, RECT.3, BLUE), "Rect")
        .unwrap()
        .with_layer_offset(1, RECT.0, RECT.1)
        .unwrap()
        .with_layer_blend_mode(1, BlendMode::Multiply)
        .unwrap();
    let doc = styled(
        &doc,
        1,
        &spread_glow(",\"blend\":\"normal\",\"color\":\"#ffffff\",\"opacity\":0.75"),
    );
    let flat = doc.flattened();
    let want = glow_pixel(GREY, [1.0; 3], 0.75, 255, BLEND_NORMAL);
    let not_want = glow_pixel(GREY, [1.0; 3], 0.75, 255, BLEND_MULTIPLY);
    assert_ne!(want, not_want, "the fixture distinguishes the two modes");
    assert_px_close(
        px(&flat, 10, 13),
        want,
        "the glow uses its own Normal blend",
    );
    let pixel_want = quantized(ref_composite(
        to_unit(GREY),
        to_unit(BLUE),
        1.0,
        BLEND_MULTIPLY,
    ));
    assert_px_close(
        px(&flat, 13, 13),
        pixel_want,
        "the layer's pixels use Multiply",
    );
}

#[test]
fn the_shape_is_alpha_times_mask() {
    // (a) A half-transparent rect: the glow is knocked out by the coverage,
    // so `255 - 128 = 127` of it lies under the rect (a quarter of glow
    // tint at most once the rect composites over it at alpha 128/255) —
    // one chain of two reference composites in f32, quantized once.
    let half = [255, 0, 0, 128];
    let doc = RzDocument::from_pixels(solid(CANVAS.0, CANVAS.1, WHITE))
        .adding_image_layer(0, solid(RECT.2, RECT.3, half), "Half")
        .unwrap()
        .with_layer_offset(1, RECT.0, RECT.1)
        .unwrap();
    let doc = styled(
        &doc,
        1,
        &spread_glow(",\"blend\":\"normal\",\"color\":\"#0000ff\",\"opacity\":1"),
    );
    let flat = doc.flattened();
    let under = ref_composite(
        to_unit(WHITE),
        [0.0, 0.0, 1.0, 1.0],
        127.0 / 255.0,
        BLEND_NORMAL,
    );
    // `ref_composite` multiplies the source alpha by `opacity`, so the
    // rect's 128/255 enters exactly once (as an opaque red at that opacity).
    let want = quantized(ref_composite(
        under,
        [1.0, 0.0, 0.0, 1.0],
        128.0 / 255.0,
        BLEND_NORMAL,
    ));
    assert_glow(
        &flat,
        WHITE,
        Some(want),
        [0.0, 0.0, 1.0],
        1.0,
        BLEND_NORMAL,
        |x, y| grown_rect(RECT, 4.0, x, y),
    );

    // (b) A mask hiding the rect's right half: the shape is the visible 3x4
    // left part, the halo forms around THAT, and the hidden pixels (masked
    // to alpha 0) are outside the shape — the glow shows there over white.
    let visible = (RECT.0, RECT.1, 3, RECT.3);
    let sel = selection(CANVAS.0, CANVAS.1, |x, _| u8::from(x < 15) * 255);
    let masked = rect_doc()
        .add_mask(1, MaskKind::FromSelection(&sel))
        .unwrap();
    let doc = styled(
        &masked,
        1,
        &spread_glow(",\"blend\":\"normal\",\"color\":\"#0000ff\",\"opacity\":1"),
    );
    let flat = doc.flattened();
    for y in 0..CANVAS.1 {
        for x in 0..CANVAS.0 {
            let got = px(&flat, x, y);
            let (xi, yi) = (i64::from(x), i64::from(y));
            if in_rect(visible, xi, yi) {
                assert_eq!(got, RED, "({x},{y}) the visible part");
                continue;
            }
            let cov = grown_rect(visible, 4.0, xi, yi);
            let want = glow_pixel(WHITE, [0.0, 0.0, 1.0], 1.0, cov, BLEND_NORMAL);
            if cov == 0 {
                assert_eq!(got, WHITE, "({x},{y})");
            } else {
                assert_px_close(got, want, &format!("({x},{y}) coverage {cov}"));
            }
        }
    }
    assert_eq!(px(&flat, 16, 13), BLUE, "the hidden half is halo, not rect");
}

#[test]
fn glow_maps_through_the_layer_offset_and_clips_to_the_canvas() {
    // The rect at (-3, -2): only its 3x2 corner is on the canvas, and the
    // closed form measures distance to the FULL rect (planes are
    // layer-local, so nothing is lost off-canvas).
    let off = (-3, -2, RECT.2, RECT.3);
    let doc = rect_doc().with_layer_offset(1, off.0, off.1).unwrap();
    let doc = styled(
        &doc,
        1,
        &spread_glow(",\"blend\":\"normal\",\"color\":\"#0000ff\",\"opacity\":1"),
    );
    let flat = doc.flattened();
    for y in 0..CANVAS.1 {
        for x in 0..CANVAS.0 {
            let got = px(&flat, x, y);
            let (xi, yi) = (i64::from(x), i64::from(y));
            if in_rect(off, xi, yi) {
                assert_eq!(got, RED, "({x},{y})");
                continue;
            }
            let cov = grown_rect(off, 4.0, xi, yi);
            let want = glow_pixel(WHITE, [0.0, 0.0, 1.0], 1.0, cov, BLEND_NORMAL);
            if cov == 0 {
                assert_eq!(got, WHITE, "({x},{y})");
            } else {
                assert_px_close(got, want, &format!("({x},{y}) coverage {cov}"));
            }
        }
    }
    assert_eq!(px(&flat, 0, 0), RED);
    assert_eq!(px(&flat, 5, 0), BLUE, "3 px right of the last rect column");
    assert_eq!(px(&flat, 0, 5), BLUE, "4 px below the last rect row");
    assert_eq!(px(&flat, 0, 6), WHITE, "5 px below: past the halo");

    // A rect entirely off-canvas whose halo still reaches in: the last
    // rect column is x = -3, so x = 0 and 1 are halo and x = 2 is not.
    let doc = rect_doc().with_layer_offset(1, -8, 12).unwrap();
    let doc = styled(
        &doc,
        1,
        &spread_glow(",\"blend\":\"normal\",\"color\":\"#0000ff\",\"opacity\":1"),
    );
    let flat = doc.flattened();
    assert_eq!(px(&flat, 0, 13), BLUE);
    assert_eq!(px(&flat, 1, 13), BLUE);
    assert_eq!(px(&flat, 2, 13), WHITE);
    assert_eq!(
        px(&flat, 0, 17),
        BLUE,
        "one row below the rect, still in reach"
    );
    // And one whose halo cannot reach: the projection is the bare canvas.
    let far = styled(
        &rect_doc().with_layer_offset(1, 100, 100).unwrap(),
        1,
        &spread_glow(""),
    );
    assert_eq!(
        far.flattened().into_raw(),
        solid(CANVAS.0, CANVAS.1, WHITE).into_raw()
    );
}

#[test]
fn fill_opacity_zero_keeps_a_hollow_halo() {
    // Fill opacity scales the pixels, never the effects — and the glow is
    // outside-only, so under the (now invisible) rect there is nothing.
    let doc = styled(
        &rect_doc(),
        1,
        "{\"fill_opacity\":0,\"effects\":[{\"type\":\"outer_glow\",\"spread\":1,\"size\":4,\
         \"blend\":\"normal\",\"color\":\"#0000ff\",\"opacity\":1}]}",
    );
    let flat = doc.flattened();
    assert_glow(
        &flat,
        WHITE,
        Some(WHITE),
        [0.0, 0.0, 1.0],
        1.0,
        BLEND_NORMAL,
        |x, y| grown_rect(RECT, 4.0, x, y),
    );
    assert_eq!(px(&flat, 13, 13), WHITE, "hollow");
    assert_eq!(px(&flat, 10, 13), BLUE, "the halo stays");
}

#[test]
fn the_glow_is_knocked_out_in_proportion_under_an_anti_aliased_edge() {
    // A black rect whose left column is at alpha 200 (an anti-aliased edge)
    // with a Normal yellow glow at opacity 1 on the dark backdrop: the glow
    // is knocked out by the pixel's own coverage — 55 of it remains under
    // the partial pixel, the drop shadow's `1 - alpha` proportion — and the
    // pixel composites over that: R = 19, a smooth fade from glow to text
    // that never fills a semi-transparent layer's interior with glow.
    let mut pixels = RgbaImage::from_pixel(RECT.2, RECT.3, Rgba([0, 0, 0, 255]));
    for y in 0..RECT.3 {
        pixels.put_pixel(0, y, Rgba([0, 0, 0, 200]));
    }
    let doc = RzDocument::from_pixels(solid(CANVAS.0, CANVAS.1, DARK))
        .adding_image_layer(0, pixels, "Text")
        .unwrap()
        .with_layer_offset(1, RECT.0, RECT.1)
        .unwrap();
    let doc = styled(
        &doc,
        1,
        &spread_glow(",\"blend\":\"normal\",\"color\":\"#ffff00\",\"opacity\":1"),
    );
    let flat = doc.flattened();
    let glow = ref_composite(to_unit(DARK), [1.0, 1.0, 0.0, 1.0], 1.0, BLEND_NORMAL);
    let under_edge = ref_composite(
        to_unit(DARK),
        [1.0, 1.0, 0.0, 1.0],
        55.0 / 255.0,
        BLEND_NORMAL,
    );
    let want = quantized(ref_composite(
        under_edge,
        [0.0, 0.0, 0.0, 1.0],
        200.0 / 255.0,
        BLEND_NORMAL,
    ));
    assert_eq!(want[0], 19);
    assert_px_close(px(&flat, RECT.0 as u32, 13), want, "the edge pixel");
    assert_eq!(px(&flat, RECT.0 as u32 + 1, 13), [0, 0, 0, 255], "the fill");
    assert_eq!(
        px(&flat, RECT.0 as u32 - 1, 13),
        quantized(glow),
        "the halo beside it"
    );
}

#[test]
fn a_fully_transparent_layer_renders_nothing() {
    let doc = RzDocument::from_pixels(solid(CANVAS.0, CANVAS.1, DARK))
        .adding_image_layer(0, solid(RECT.2, RECT.3, [255, 0, 0, 0]), "Clear")
        .unwrap()
        .with_layer_offset(1, RECT.0, RECT.1)
        .unwrap();
    let plain = doc.flattened().into_raw();
    for fields in [
        "\"spread\":1,\"size\":4",
        "\"spread\":0,\"size\":12",
        "\"size\":40",
    ] {
        let styled_doc = styled(&doc, 1, &glow_json(fields));
        assert_eq!(styled_doc.flattened().into_raw(), plain, "{fields}");
    }
    // Likewise a 1x1 layer: the smallest shape still renders (a dot's halo
    // is the disc of the grow oracle).
    let dot = RzDocument::from_pixels(solid(CANVAS.0, CANVAS.1, WHITE))
        .adding_image_layer(0, solid(1, 1, RED), "Dot")
        .unwrap()
        .with_layer_offset(1, 20, 16)
        .unwrap();
    let dot = styled(
        &dot,
        1,
        &spread_glow(",\"blend\":\"normal\",\"color\":\"#0000ff\",\"opacity\":1"),
    );
    let flat = dot.flattened();
    assert_eq!(px(&flat, 20, 16), RED);
    assert_eq!(px(&flat, 24, 16), BLUE, "4 px out");
    assert_eq!(px(&flat, 25, 16), WHITE, "5 px out");
    let diag = px(&flat, 23, 19);
    assert_ne!(diag, WHITE, "sqrt(18) is on the ramp");
    assert_ne!(diag, BLUE);
}

#[test]
fn the_setter_is_pure_and_the_cache_is_consistent() {
    let base = rect_on(DARK);
    let base_pixels = Arc::clone(&base.layers[1].pixels);
    let plain = base.flattened().into_raw();
    let json = glow_json("\"spread\":0.25,\"size\":9");
    let doc = styled(&base, 1, &json);
    assert!(
        base.layers[1].style.is_none(),
        "the input document is unchanged"
    );
    assert_eq!(base.flattened().into_raw(), plain);
    assert!(
        Arc::ptr_eq(&doc.layers[1].pixels, &base_pixels),
        "pixels are shared, not copied"
    );
    let echo = doc.layers[1].style.as_ref().unwrap().to_json();
    assert!(echo.contains("\"type\":\"outer_glow\""), "{echo}");
    assert!(echo.contains("\"spread\":0.25"), "{echo}");
    // Cache hit == fresh render, and a moved layer reuses its planes.
    let first = doc.flattened().into_raw();
    assert_eq!(doc.flattened().into_raw(), first);
    assert_ne!(first, plain, "size 9 at spread 0.25 renders a halo");
    let moved = doc.with_layer_offset(1, 14, 13).unwrap();
    let fresh = styled(&base.with_layer_offset(1, 14, 13).unwrap(), 1, &json);
    assert_eq!(moved.flattened().into_raw(), fresh.flattened().into_raw());
}
