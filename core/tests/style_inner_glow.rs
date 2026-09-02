//! Inner glow (work item E3): an edge glow at full choke is the complement
//! of the shrink-rect closed form (a hard band inside the contour), soft
//! and partly-choked glows are the header's feather kernel over hand-built
//! grow/shrink planes, a centre glow of size 0 is the whole shape, colours
//! follow the W3C reference blend with the effect's OWN blend mode (also on
//! a Multiply layer), and the common cases: disabled / opacity 0 / edge
//! size 0 render nothing, a masked shape and an offset rect map, fill
//! opacity 0 keeps the glow, a transparent layer renders nothing, purity.
//! Black-box through the FFI setter (`common::styled`) and the public
//! projection; the oracles are analytic — never a golden image.

use std::ffi::c_int;

use image::{Rgba, RgbaImage};
use rasterize_core::doc::{BlendMode, MaskKind, RzDocument};

mod common;
use common::*;

// --------------------------------------------------------------- fixture --

/// A 40x32 white canvas under a 16x12 rect at (10, 8): the rect is at least
/// 8 px from every canvas edge, so a size-4 glow's kernel (radius 5, 11
/// taps) never reads the border, and a full-choke band of 4 px still leaves
/// an 8x4 interior to prove the band stops.
const CANVAS: (u32, u32) = (40, 32);
const RECT: (i32, i32, u32, u32) = (10, 8, 16, 12);
/// A mid-tone rect colour: Screen with the default pale-yellow glow changes
/// every channel, so a wrong blend or opacity shows.
const NAVY: [u8; 4] = [40, 80, 160, 255];
/// The schema's default glow colour, `#ffffbe`.
const GLOW: [u8; 4] = [255, 255, 190, 255];
const DEFAULT_OPACITY: f32 = 0.75;

fn rect_doc() -> RzDocument {
    rect_layer_doc(CANVAS, RECT, NAVY)
}

/// An inner-glow style with `extra` spliced in as further keys (`,"k":v`).
fn glow_json(source: &str, choke: f32, size: f32, extra: &str) -> String {
    format!(
        "{{\"effects\":[{{\"type\":\"inner_glow\",\"source\":\"{source}\",\
         \"choke\":{choke},\"size\":{size}{extra}}}]}}"
    )
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

fn in_rect(rect: (i32, i32, u32, u32), x: i64, y: i64) -> bool {
    let (x0, y0) = (i64::from(rect.0), i64::from(rect.1));
    x >= x0 && y >= y0 && x < x0 + i64::from(rect.2) && y < y0 + i64::from(rect.3)
}

/// For a pixel INSIDE `rect`, the distance to the nearest pixel outside it
/// — axis-aligned, because the complement of a rect is nearest along an
/// axis (tests.md §5.3): `min(x - x0 + 1, x1 - x, y - y0 + 1, y1 - y)`.
fn d_out(rect: (i32, i32, u32, u32), x: i64, y: i64) -> i64 {
    let (x0, y0) = (i64::from(rect.0), i64::from(rect.1));
    let (x1, y1) = (x0 + i64::from(rect.2), y0 + i64::from(rect.3));
    (x - x0 + 1).min(x1 - x).min(y - y0 + 1).min(y1 - y)
}

/// The rect shrunk by `r` at an inside pixel, from the header's contract
/// `coverage' = clamp(s - r + 0.5, 0, 1) * 255` with `s = d_out - 0.5`.
fn shrunk_rect(rect: (i32, i32, u32, u32), r: f32, x: i64, y: i64) -> u8 {
    ((d_out(rect, x, y) as f32 - r).clamp(0.0, 1.0) * 255.0).round() as u8
}

/// The rect's INVERSE grown by `r` at an inside pixel of the rect (the
/// pixel is outside the inverse, whose nearest inside pixel is the rect's
/// nearest outside one): `clamp(s + r + 0.5, 0, 1) * 255` with
/// `s = 0.5 - d_out`.
fn grown_inverse(rect: (i32, i32, u32, u32), r: f32, x: i64, y: i64) -> u8 {
    ((r + 1.0 - d_out(rect, x, y) as f32).clamp(0.0, 1.0) * 255.0).round() as u8
}

/// The documented sigma -> feather radius mapping (style_render module
/// doc): `sigma = size / 2`, `radius = max((sigma - 0.8) / 0.3 + 1, 0.5)`,
/// no blur at all for size 0.
fn feather_radius_for_size(size_px: f32) -> Option<f32> {
    let sigma = size_px / 2.0;
    (sigma > 0.0).then(|| ((sigma - 0.8) / 0.3 + 1.0).max(0.5))
}

/// The independent oracle for the glow's coverage plane over the canvas:
/// the closed-form grow (edge) or shrink (centre) by `size * choke`, the
/// header's feather kernel for the remaining `size * (1 - choke)`, then
/// clipped to the rect. The core renders on a layer-local padded plane;
/// the two agree wherever no kernel reaches a border, which the fixture
/// guarantees, and because the outside of the rect is constant (255 for
/// the inverse, 0 for the shape) out to both borders.
fn oracle_plane(rect: (i32, i32, u32, u32), source: &str, choke: f32, size: f32) -> Vec<u8> {
    let dilate = size * choke;
    let plane = selection(CANVAS.0, CANVAS.1, |x, y| {
        let (xi, yi) = (i64::from(x), i64::from(y));
        match (source, in_rect(rect, xi, yi)) {
            ("edge", true) => grown_inverse(rect, dilate, xi, yi),
            ("edge", false) => 255,
            ("center", true) => shrunk_rect(rect, dilate, xi, yi),
            ("center", false) => 0,
            _ => panic!("unknown source {source}"),
        }
    });
    let mut plane = match feather_radius_for_size(size * (1.0 - choke)) {
        Some(radius) => feathered_plane(&plane, CANVAS.0, CANVAS.1, radius),
        None => plane,
    };
    for (i, v) in plane.iter_mut().enumerate() {
        let (x, y) = (i as u32 % CANVAS.0, i as u32 / CANVAS.0);
        if !in_rect(rect, i64::from(x), i64::from(y)) {
            *v = 0;
        }
    }
    plane
}

/// The glow at coverage `cov` over the (opaque) pixel colour `bg`, through
/// the W3C reference composite with the effect's own blend mode and
/// opacity, quantized once like the projection.
fn glow_over(bg: [u8; 4], glow: [u8; 4], cov: u8, opacity: f32, mode: c_int) -> [u8; 4] {
    quantized(ref_composite(
        to_unit(bg),
        to_unit(glow),
        opacity * f32::from(cov) / 255.0,
        mode,
    ))
}

// -------------------------------------------------------- closed forms --

#[test]
fn edge_glow_at_full_choke_is_the_shrink_rect_band() {
    // choke 1 at size 4: the inverse grown by 4 and no blur, i.e. exactly
    // the 4 px the rect loses when shrunk by 4 — full coverage where
    // d_out <= 4, nothing from d_out = 5 in.
    let flat = styled(&rect_doc(), 1, &glow_json("edge", 1.0, 4.0, "")).flattened();
    let band_colour = glow_over(NAVY, GLOW, 255, DEFAULT_OPACITY, BLEND_SCREEN);
    assert_ne!(band_colour, NAVY, "the fixture's glow is visible");
    let (mut band, mut interior) = (0, 0);
    for y in 0..CANVAS.1 {
        for x in 0..CANVAS.0 {
            let got = px(&flat, x, y);
            let (xi, yi) = (i64::from(x), i64::from(y));
            if !in_rect(RECT, xi, yi) {
                assert_eq!(got, WHITE, "({x},{y}) outside the shape");
                continue;
            }
            let cov = 255 - shrunk_rect(RECT, 4.0, xi, yi);
            if cov == 0 {
                assert!(d_out(RECT, xi, yi) >= 5);
                assert_eq!(got, NAVY, "({x},{y}) interior is untouched");
                interior += 1;
            } else {
                assert_eq!(cov, 255, "a full choke has no soft ramp");
                assert!(d_out(RECT, xi, yi) <= 4);
                assert_px_close(got, band_colour, &format!("({x},{y}) band"));
                band += 1;
            }
        }
    }
    assert_eq!(interior, 8 * 4, "the 16x12 rect keeps an 8x4 interior");
    assert_eq!(band, 16 * 12 - 8 * 4);
}

#[test]
fn center_glow_at_size_zero_is_the_whole_shape() {
    let want = glow_over(NAVY, GLOW, 255, DEFAULT_OPACITY, BLEND_SCREEN);
    for choke in [0.0, 1.0] {
        let flat = styled(&rect_doc(), 1, &glow_json("center", choke, 0.0, "")).flattened();
        for y in 0..CANVAS.1 {
            for x in 0..CANVAS.0 {
                let got = px(&flat, x, y);
                if in_rect(RECT, i64::from(x), i64::from(y)) {
                    assert_px_close(got, want, &format!("choke {choke} ({x},{y})"));
                } else {
                    assert_eq!(got, WHITE, "choke {choke} ({x},{y}) outside");
                }
            }
        }
    }
}

#[test]
fn center_glow_at_full_choke_is_the_shrunk_rect() {
    // choke 1 at size 4: the shape eroded by 4 and no blur — the glow is the
    // 8x4 interior at full coverage and the 4 px band is untouched.
    let flat = styled(&rect_doc(), 1, &glow_json("center", 1.0, 4.0, "")).flattened();
    let want = glow_over(NAVY, GLOW, 255, DEFAULT_OPACITY, BLEND_SCREEN);
    let mut glowing = 0;
    for y in 0..CANVAS.1 {
        for x in 0..CANVAS.0 {
            let got = px(&flat, x, y);
            let (xi, yi) = (i64::from(x), i64::from(y));
            if !in_rect(RECT, xi, yi) {
                assert_eq!(got, WHITE);
            } else if d_out(RECT, xi, yi) >= 5 {
                assert_px_close(got, want, &format!("({x},{y}) plateau"));
                glowing += 1;
            } else {
                assert_eq!(got, NAVY, "({x},{y}) the eroded band is untouched");
            }
        }
    }
    assert_eq!(glowing, 8 * 4);
}

// ------------------------------------------------------- feather oracle --

#[test]
fn soft_and_partly_choked_glows_match_the_feather_oracle() {
    // size 4: choke 0 -> sigma 2 (radius 5), choke 0.5 -> dilate 2 then
    // sigma 1 (radius 5/3); both sources.
    for source in ["edge", "center"] {
        let mut contours = Vec::new();
        for choke in [0.0f32, 0.5] {
            let flat = styled(&rect_doc(), 1, &glow_json(source, choke, 4.0, "")).flattened();
            let plane = oracle_plane(RECT, source, choke, 4.0);
            let mut soft = 0;
            for y in 0..CANVAS.1 {
                for x in 0..CANVAS.0 {
                    let got = px(&flat, x, y);
                    let what = format!("{source} choke {choke} ({x},{y})");
                    if !in_rect(RECT, i64::from(x), i64::from(y)) {
                        assert_eq!(got, WHITE, "{what} outside");
                        continue;
                    }
                    let cov = plane[(y * CANVAS.0 + x) as usize];
                    let want = glow_over(NAVY, GLOW, cov, DEFAULT_OPACITY, BLEND_SCREEN);
                    assert_px_close(got, want, &format!("{what} coverage {cov}"));
                    assert_eq!(got[3], 255, "{what} alpha");
                    if cov != 0 && cov != 255 {
                        soft += 1;
                    }
                }
            }
            assert!(soft > 0, "{source} choke {choke}: the ramp exists");
            let contour = plane[(RECT.1 as u32 * CANVAS.0 + RECT.0 as u32 + 8) as usize];
            match (source, choke == 0.0) {
                // The blur is centred on the contour and the outermost
                // pixel's centre sits half a pixel inside it, so the
                // unchoked edge glow is ~40 % there (0.4 * 255 = 102) and
                // the unchoked centre glow, its complement, ~60 % (153); the
                // two are complements of one step, so they sum to 255.
                ("edge", true) => assert!(
                    (80..=128).contains(&contour),
                    "edge contour {contour} is about 40 %"
                ),
                ("center", true) => assert!(
                    (128..=180).contains(&contour),
                    "centre contour {contour} is about 60 %"
                ),
                _ => {}
            }
            contours.push(contour);
        }
        // Choke hardens the glow at the contour: for an edge glow the 2 px
        // plateau it adds raises the contour pixel (to ~241 — never 255,
        // since the 5-tap kernel still sees the ramp two pixels in); for a
        // centre glow the erosion pulls the plateau inward, so the contour
        // pixel drops (to 0 — nothing of the shrunk shape is within the
        // kernel's reach there).
        let (unchoked, choked) = (contours[0], contours[1]);
        match source {
            "edge" => assert!(choked > unchoked, "edge contour {unchoked} -> {choked}"),
            _ => assert!(choked < unchoked, "centre contour {unchoked} -> {choked}"),
        }
    }
}

#[test]
fn edge_glow_of_size_zero_renders_nothing() {
    // A glow with no extent draws nothing — including along anti-aliased
    // edges, where inverse x coverage would otherwise leave a faint halo.
    let mut soft = solid(RECT.2, RECT.3, NAVY);
    for y in 0..RECT.3 {
        for x in 0..RECT.2 {
            if x == 0 || y == 0 || x == RECT.2 - 1 || y == RECT.3 - 1 {
                soft.put_pixel(x, y, Rgba([NAVY[0], NAVY[1], NAVY[2], 128]));
            }
        }
    }
    let base = rect_doc()
        .with_layer_pixels(1, soft)
        .expect("soft-edged rect");
    let plain = base.flattened().into_raw();
    for choke in [0.0, 1.0] {
        let doc = styled(&base, 1, &glow_json("edge", choke, 0.0, ""));
        assert!(doc.layers[1].style.is_some(), "an enabled effect is stored");
        assert_eq!(doc.flattened().into_raw(), plain, "choke {choke}");
    }
}

// ----------------------------------------------------------- blending --

#[test]
fn glow_blend_mode_and_opacity_follow_the_reference() {
    let grey = [128, 128, 128, 255];
    let mut seen = Vec::new();
    for (name, mode) in [
        ("normal", BLEND_NORMAL),
        ("multiply", BLEND_MULTIPLY),
        ("screen", BLEND_SCREEN),
    ] {
        let extra = format!(",\"blend\":\"{name}\",\"color\":\"#808080\",\"opacity\":0.6");
        let flat = styled(&rect_doc(), 1, &glow_json("center", 0.0, 0.0, &extra)).flattened();
        let want = glow_over(NAVY, grey, 255, 0.6, mode);
        assert_px_close(px(&flat, 17, 13), want, name);
        assert_eq!(px(&flat, 5, 5), WHITE, "{name}: outside untouched");
        seen.push(want);
    }
    assert!(
        seen[0] != seen[1] && seen[1] != seen[2] && seen[0] != seen[2],
        "the three modes are distinguishable on this fixture: {seen:?}"
    );
}

#[test]
fn layer_opacity_mixes_the_packaged_pixels_and_glow() {
    // The layer opacity applies once, to the package of pixels and glow
    // (Photoshop's model): the glow at its own opacity over the opaque
    // pixels, then that result mixed into the backdrop at the layer's 0.5
    // — never the glow thinned by 0.5 over pixels thinned by 0.5.
    let base = rect_doc().with_layer_opacity(1, 0.5).expect("opacity");
    let flat = styled(&base, 1, &glow_json("center", 0.0, 0.0, "")).flattened();
    let pixels = ref_composite(to_unit(WHITE), to_unit(NAVY), 1.0, BLEND_NORMAL);
    let package = ref_composite(pixels, to_unit(GLOW), DEFAULT_OPACITY, BLEND_SCREEN);
    let white = to_unit(WHITE);
    let want = quantized([
        white[0] + (package[0] - white[0]) * 0.5,
        white[1] + (package[1] - white[1]) * 0.5,
        white[2] + (package[2] - white[2]) * 0.5,
        1.0,
    ]);
    assert_px_close(px(&flat, 17, 13), want, "half-opacity layer");
    assert_ne!(
        px(&flat, 17, 13),
        glow_over(NAVY, GLOW, 255, DEFAULT_OPACITY, BLEND_SCREEN),
        "the layer opacity reached the glow"
    );
    let sequential = quantized(ref_composite(
        ref_composite(white, to_unit(NAVY), 0.5, BLEND_NORMAL),
        to_unit(GLOW),
        DEFAULT_OPACITY * 0.5,
        BLEND_SCREEN,
    ));
    assert_ne!(
        px(&flat, 17, 13),
        sequential,
        "the per-contribution model differs on this fixture"
    );
}

#[test]
fn the_glow_keeps_its_own_blend_on_a_multiply_layer() {
    // A Multiply-blend RED layer over grey composites to dark red; a white
    // Normal glow at opacity 1 above it must show white (its OWN blend, not
    // the layer's — "Blend Interior Effects as Group" is off). Through the
    // layer's Multiply it would stay dark red.
    let grey = [128, 128, 128, 255];
    let base = RzDocument::from_pixels(solid(CANVAS.0, CANVAS.1, grey))
        .adding_image_layer(0, solid(RECT.2, RECT.3, RED), "Rect")
        .expect("add layer")
        .with_layer_offset(1, RECT.0, RECT.1)
        .expect("offset")
        .with_layer_blend_mode(1, BlendMode::Multiply)
        .expect("blend");
    let pixels_only = quantized(ref_composite(
        to_unit(grey),
        to_unit(RED),
        1.0,
        BLEND_MULTIPLY,
    ));
    assert_eq!(base.flattened().get_pixel(17, 13).0, pixels_only);
    let flat = styled(
        &base,
        1,
        &glow_json(
            "center",
            0.0,
            0.0,
            ",\"blend\":\"normal\",\"color\":\"#ffffff\",\"opacity\":1",
        ),
    )
    .flattened();
    for y in 0..CANVAS.1 {
        for x in 0..CANVAS.0 {
            let got = px(&flat, x, y);
            if in_rect(RECT, i64::from(x), i64::from(y)) {
                assert_px_close(got, WHITE, &format!("({x},{y}) white through Normal"));
            } else {
                assert_eq!(got, grey, "({x},{y}) outside");
            }
        }
    }
}

// --------------------------------------------------------- common cases --

#[test]
fn disabled_and_opacity_zero_render_nothing() {
    let base = rect_doc();
    let plain = base.flattened().into_raw();
    let off = styled(&base, 1, &glow_json("edge", 0.0, 5.0, ",\"opacity\":0"));
    assert_eq!(off.flattened().into_raw(), plain, "opacity 0");
    let disabled = styled(
        &base,
        1,
        "{\"fill_opacity\":0.5,\"effects\":[{\"type\":\"inner_glow\",\"enabled\":false}]}",
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

#[test]
fn the_glow_follows_the_masked_shape() {
    // A mask hiding the rect's right 4 columns: the shape is 12x12 and the
    // band hugs the MASK's edge; the hidden columns show the canvas.
    let visible = (RECT.0, RECT.1, RECT.2 - 4, RECT.3);
    let sel = selection(CANVAS.0, CANVAS.1, |x, y| {
        u8::from(in_rect(visible, i64::from(x), i64::from(y))) * 255
    });
    let base = rect_doc()
        .add_mask(1, MaskKind::FromSelection(&sel))
        .expect("mask");
    let flat = styled(&base, 1, &glow_json("edge", 1.0, 4.0, "")).flattened();
    let band_colour = glow_over(NAVY, GLOW, 255, DEFAULT_OPACITY, BLEND_SCREEN);
    let mut interior = 0;
    for y in 0..CANVAS.1 {
        for x in 0..CANVAS.0 {
            let got = px(&flat, x, y);
            let (xi, yi) = (i64::from(x), i64::from(y));
            if !in_rect(visible, xi, yi) {
                assert_eq!(got, WHITE, "({x},{y}) hidden or outside");
            } else if d_out(visible, xi, yi) <= 4 {
                assert_px_close(got, band_colour, &format!("({x},{y}) band"));
            } else {
                assert_eq!(got, NAVY, "({x},{y}) interior");
                interior += 1;
            }
        }
    }
    assert_eq!(
        interior,
        4 * 4,
        "the 12x12 visible shape keeps a 4x4 interior"
    );
}

#[test]
fn an_offset_rect_partly_off_canvas_bands_along_its_true_edges() {
    // The band is measured from the rect's real edges, off-canvas ones
    // included: only the corner nearest the canvas corner is interior.
    for (rect, interior_px) in [
        ((-6, -4, RECT.2, RECT.3), 6 * 4),
        ((30, 24, RECT.2, RECT.3), 6 * 4),
    ] {
        let base = rect_layer_doc(CANVAS, rect, NAVY);
        let flat = styled(&base, 1, &glow_json("edge", 1.0, 4.0, "")).flattened();
        let band_colour = glow_over(NAVY, GLOW, 255, DEFAULT_OPACITY, BLEND_SCREEN);
        let mut interior = 0;
        for y in 0..CANVAS.1 {
            for x in 0..CANVAS.0 {
                let got = px(&flat, x, y);
                let (xi, yi) = (i64::from(x), i64::from(y));
                let what = format!("rect at ({},{}) ({x},{y})", rect.0, rect.1);
                if !in_rect(rect, xi, yi) {
                    assert_eq!(got, WHITE, "{what} outside");
                } else if d_out(rect, xi, yi) <= 4 {
                    assert_px_close(got, band_colour, &format!("{what} band"));
                } else {
                    assert_eq!(got, NAVY, "{what} interior");
                    interior += 1;
                }
            }
        }
        assert_eq!(interior, interior_px, "rect at ({},{})", rect.0, rect.1);
    }
}

#[test]
fn fill_opacity_zero_keeps_the_glow() {
    // The pixels vanish, the effect stays: a Normal glow at opacity 1 IS the
    // glow colour on the band, and the canvas shows through the interior.
    let flat = styled(
        &rect_doc(),
        1,
        "{\"fill_opacity\":0,\"effects\":[{\"type\":\"inner_glow\",\"source\":\"edge\",\
         \"choke\":1,\"size\":4,\"blend\":\"normal\",\"opacity\":1}]}",
    )
    .flattened();
    for y in 0..CANVAS.1 {
        for x in 0..CANVAS.0 {
            let got = px(&flat, x, y);
            let (xi, yi) = (i64::from(x), i64::from(y));
            let want = if in_rect(RECT, xi, yi) && d_out(RECT, xi, yi) <= 4 {
                GLOW
            } else {
                WHITE
            };
            assert_eq!(got, want, "({x},{y})");
        }
    }
}

#[test]
fn transparent_and_one_pixel_layers_render_sanely() {
    let white = solid(CANVAS.0, CANVAS.1, WHITE).into_raw();
    let clear = RzDocument::from_pixels(solid(CANVAS.0, CANVAS.1, WHITE))
        .adding_image_layer(0, solid(RECT.2, RECT.3, [0, 0, 0, 0]), "Clear")
        .expect("add layer")
        .with_layer_offset(1, RECT.0, RECT.1)
        .expect("offset");
    for source in ["edge", "center"] {
        let doc = styled(&clear, 1, &glow_json(source, 0.5, 4.0, ""));
        assert_eq!(
            doc.flattened().into_raw(),
            white,
            "{source}: a transparent shape"
        );
    }
    let dot = rect_layer_doc(CANVAS, (5, 5, 1, 1), NAVY);
    let hard = styled(&dot, 1, &glow_json("edge", 1.0, 4.0, "")).flattened();
    assert_px_close(
        px(&hard, 5, 5),
        glow_over(NAVY, GLOW, 255, DEFAULT_OPACITY, BLEND_SCREEN),
        "a lone pixel is all band",
    );
    assert_eq!(px(&hard, 6, 5), WHITE);
    let soft = styled(&dot, 1, &glow_json("center", 0.0, 4.0, "")).flattened();
    assert_eq!(px(&soft, 5, 5)[3], 255);
    assert_eq!(px(&soft, 4, 5), WHITE, "a glow never leaves the shape");
    assert_eq!(px(&soft, 5, 6), WHITE);
}

#[test]
fn styling_is_pure() {
    let base = rect_doc();
    let before = base.flattened().into_raw();
    let doc = styled(&base, 1, &glow_json("edge", 0.5, 6.0, ""));
    assert!(doc.layers[1].style.is_some());
    assert!(
        base.layers[1].style.is_none(),
        "the input document is untouched"
    );
    assert_eq!(base.flattened().into_raw(), before);
    assert_ne!(doc.flattened().into_raw(), before, "the glow rendered");
}
