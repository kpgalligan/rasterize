//! Bevel & Emboss — black-box through the style FFI and the projection.
//! The oracle restates the module doc's formula on top of the header's
//! feather contract (`common::feathered_plane`) and the W3C reference
//! blend: height = blur(coverage) shaped per style (and softened), the
//! normal from a 1-px central difference with `k = size`, the light
//! `L = (cos alt cos ang, −cos alt sin ang, sin alt)`, the lateral shading
//! `d = n.x L.x + n.y L.y`, highlight `clamp(d)`, shadow `clamp(−d)`, each
//! restricted to its band and composited below or inside the pixels with
//! its own blend. Nothing here reads a core plane; the tolerances are ±2
//! per colour channel (a ±1 height byte moves a slope by one coverage
//! level, and the two code paths round `d` independently), alpha exact.

use std::ffi::c_int;

use image::{Rgba, RgbaImage};
use rasterize_core::doc::{BlendMode, MaskKind, RzDocument};

mod common;
use common::*;

// --------------------------------------------------------------- fixture --

/// A mid-gray backdrop: an outer highlight is screen-white, invisible over
/// the shared white fixture, so every oracle here starts from gray.
const GRAY: [u8; 4] = [128, 128, 128, 255];
const RECT_COLOR: [u8; 4] = [120, 160, 200, 255];
const CANVAS: (u32, u32) = (60, 50);
/// 24×20 at (18, 15): at least 15 px of margin on every side, more than
/// the 12 px a size-4 + soften-4 bevel reaches, so the oracle's
/// clamp-to-edge feather equals the core's zero-padded plane.
const RECT: (i32, i32, u32, u32) = (18, 15, 24, 20);
/// The feather kernel for size 4 (sigma 2) has half-width 5: the bevel
/// band is 6 px (the plateau starts where the window is fully inside, and
/// the central difference reaches one further), and a row or column is
/// "pure" — its height depends on one axis only — 6 px in from an edge.
const BAND: i64 = 6;

/// `rect_layer_doc` over a chosen backdrop instead of white.
fn rect_over(
    bg: [u8; 4],
    canvas: (u32, u32),
    rect: (i32, i32, u32, u32),
    color: [u8; 4],
) -> RzDocument {
    let doc = RzDocument::from_pixels(solid(canvas.0, canvas.1, bg));
    let doc = doc
        .adding_image_layer(0, solid(rect.2, rect.3, color), "Rect")
        .expect("add rect layer");
    doc.with_layer_offset(1, rect.0, rect.1).expect("offset")
}

fn gray_doc() -> RzDocument {
    rect_over(GRAY, CANVAS, RECT, RECT_COLOR)
}

fn in_rect(rect: (i32, i32, u32, u32), x: i64, y: i64) -> bool {
    x >= i64::from(rect.0)
        && y >= i64::from(rect.1)
        && x < i64::from(rect.0) + i64::from(rect.2)
        && y < i64::from(rect.1) + i64::from(rect.3)
}

fn rect_selection(w: u32, h: u32, rect: (i32, i32, u32, u32)) -> Vec<u8> {
    selection(w, h, |x, y| {
        if in_rect(rect, i64::from(x), i64::from(y)) {
            255
        } else {
            0
        }
    })
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

/// Per-channel comparison with a stated tolerance, alpha exact.
fn assert_px(got: [u8; 4], want: [u8; 4], tol: i32, what: &str) {
    for c in 0..4 {
        let t = if c == 3 { 0 } else { tol };
        assert!(
            (i32::from(got[c]) - i32::from(want[c])).abs() <= t,
            "{what}: channel {c} is {} expected {} (±{t}); got {got:?} want {want:?}",
            got[c],
            want[c]
        );
    }
}

fn assert_image(got: &RgbaImage, want: &RgbaImage, tol: i32, what: &str) {
    assert_eq!(got.dimensions(), want.dimensions(), "{what}: dimensions");
    for y in 0..got.height() {
        for x in 0..got.width() {
            assert_px(
                px(got, x, y),
                px(want, x, y),
                tol,
                &format!("{what} ({x},{y})"),
            );
        }
    }
}

/// "Only lighter": every channel ≥ the reference (a screen-white
/// highlight never darkens) — and strictly lighter when `strict`.
fn assert_lighter(got: [u8; 4], base: [u8; 4], strict: bool, what: &str) {
    assert_eq!(got[3], base[3], "{what}: alpha");
    for c in 0..3 {
        assert!(
            got[c] >= base[c],
            "{what}: channel {c} darkened: {got:?} vs {base:?}"
        );
    }
    if strict {
        assert!(got[..3] != base[..3], "{what}: not lit: {got:?}");
    }
}

/// "Only darker": every channel ≤ the reference (a multiply-black shadow
/// never lightens) — and strictly darker when `strict`.
fn assert_darker(got: [u8; 4], base: [u8; 4], strict: bool, what: &str) {
    assert_eq!(got[3], base[3], "{what}: alpha");
    for c in 0..3 {
        assert!(
            got[c] <= base[c],
            "{what}: channel {c} lightened: {got:?} vs {base:?}"
        );
    }
    if strict {
        assert!(got[..3] != base[..3], "{what}: not shaded: {got:?}");
    }
}

// ---------------------------------------------------------------- style --

/// One bevel effect's knobs: the JSON the FFI takes and the numbers the
/// oracle uses come from the same value.
#[derive(Clone)]
struct Bevel {
    style: &'static str,
    depth: f32,
    down: bool,
    size: f32,
    soften: f32,
    angle: f32,
    altitude: f32,
    use_global_light: bool,
    highlight: (c_int, &'static str, [u8; 3], f32),
    shadow: (c_int, &'static str, [u8; 3], f32),
    fill_opacity: f32,
    enabled: bool,
}

impl Default for Bevel {
    /// The core's defaults with the light made explicit (angle 0 = from the
    /// right) and its own, so the document light plays no part unless a
    /// test asks for it.
    fn default() -> Self {
        Bevel {
            style: "inner_bevel",
            depth: 1.0,
            down: false,
            size: 4.0,
            soften: 0.0,
            angle: 0.0,
            altitude: 30.0,
            use_global_light: false,
            highlight: (BLEND_SCREEN, "screen", [255, 255, 255], 0.75),
            shadow: (BLEND_MULTIPLY, "multiply", [0, 0, 0], 0.75),
            fill_opacity: 1.0,
            enabled: true,
        }
    }
}

impl Bevel {
    fn json(&self) -> String {
        let hex = |c: [u8; 3]| format!("#{:02x}{:02x}{:02x}", c[0], c[1], c[2]);
        format!(
            "{{\"fill_opacity\":{},\"effects\":[{{\"type\":\"bevel_emboss\",\"enabled\":{},\
             \"style\":\"{}\",\"depth\":{},\"direction\":\"{}\",\"size\":{},\"soften\":{},\
             \"angle\":{},\"use_global_light\":{},\"altitude\":{},\
             \"highlight_blend\":\"{}\",\"highlight_color\":\"{}\",\"highlight_opacity\":{},\
             \"shadow_blend\":\"{}\",\"shadow_color\":\"{}\",\"shadow_opacity\":{}}}]}}",
            self.fill_opacity,
            self.enabled,
            self.style,
            self.depth,
            if self.down { "down" } else { "up" },
            self.size,
            self.soften,
            self.angle,
            self.use_global_light,
            self.altitude,
            self.highlight.1,
            hex(self.highlight.2),
            self.highlight.3,
            self.shadow.1,
            hex(self.shadow.2),
            self.shadow.3,
        )
    }
}

// --------------------------------------------------------------- oracle --

/// The feather radius for a Photoshop size: sigma = size / 2 (the
/// documented approximation) and the header's `sigma = 0.3 (r − 1) + 0.8`
/// inverted, floored at 0.5 so any positive size still blurs.
fn radius_for(size: f32) -> f32 {
    let sigma = size / 2.0;
    if sigma <= 0.0 {
        0.0
    } else {
        ((sigma - 0.8) / 0.3 + 1.0).max(0.5)
    }
}

/// `round(a · b / 255)` per pixel.
fn mul(a: &[u8], b: &[u8]) -> Vec<u8> {
    a.iter()
        .zip(b)
        .map(|(&x, &y)| ((u32::from(x) * u32::from(y) + 127) / 255) as u8)
        .collect()
}

fn inv(a: &[u8]) -> Vec<u8> {
    a.iter().map(|&v| 255 - v).collect()
}

/// The unit-scaled height field (as coverage bytes) of the module doc.
fn height(sel: &[u8], w: u32, h: u32, b: &Bevel) -> Vec<u8> {
    let blur = feathered_plane(sel, w, h, radius_for(b.size));
    let shaped = match b.style {
        "inner_bevel" => mul(&blur, sel),
        "outer_bevel" => mul(&blur, &inv(sel))
            .iter()
            .zip(sel)
            .map(|(&o, &c)| o.saturating_add(c))
            .collect(),
        "emboss" => blur,
        "pillow_emboss" => {
            let outside = mul(&blur, &inv(sel));
            let inside = mul(&inv(&blur), sel);
            outside
                .iter()
                .zip(&inside)
                .map(|(&o, &i)| o.saturating_add(i))
                .collect()
        }
        other => panic!("unknown style {other}"),
    };
    feathered_plane(&shaped, w, h, radius_for(b.soften))
}

/// The shading `d` per pixel: 1-px central differences (clamped at the
/// plane edge), `n = normalize(−depth·size·hx, −depth·size·hy, 1)`,
/// `d = n.x L.x + n.y L.y`, negated for direction down.
fn shading(height: &[u8], w: u32, h: u32, b: &Bevel, light: (f32, f32)) -> Vec<f32> {
    let (wi, hi) = (i64::from(w), i64::from(h));
    let at =
        |x: i64, y: i64| f32::from(height[(y.clamp(0, hi - 1) * wi + x.clamp(0, wi - 1)) as usize]);
    let k = b.depth * b.size;
    let (ang, alt) = (light.0.to_radians(), light.1.to_radians());
    let l = (alt.cos() * ang.cos(), -alt.cos() * ang.sin());
    let mut out = Vec::with_capacity(height.len());
    for y in 0..hi {
        for x in 0..wi {
            let hx = (at(x + 1, y) - at(x - 1, y)) / (2.0 * 255.0);
            let hy = (at(x, y + 1) - at(x, y - 1)) / (2.0 * 255.0);
            let (nx, ny, nz) = (-k * hx, -k * hy, 1.0f32);
            let len = (nx * nx + ny * ny + nz * nz).sqrt();
            let d = (nx / len) * l.0 + (ny / len) * l.1;
            out.push(if b.down { -d } else { d });
        }
    }
    out
}

fn coverage(d: f32) -> u8 {
    (255.0 * d.clamp(0.0, 1.0)).round() as u8
}

/// The four coverage planes an effect emits — (outer highlight, outer
/// shadow, inner highlight, inner shadow), each already restricted to its
/// band; a style without that half leaves its planes zero.
struct Planes {
    outer_hl: Vec<u8>,
    outer_sh: Vec<u8>,
    inner_hl: Vec<u8>,
    inner_sh: Vec<u8>,
}

fn planes(sel: &[u8], w: u32, h: u32, b: &Bevel, light: (f32, f32)) -> Planes {
    let d = shading(&height(sel, w, h, b), w, h, b, light);
    let hl: Vec<u8> = d.iter().map(|&v| coverage(v)).collect();
    let sh: Vec<u8> = d.iter().map(|&v| coverage(-v)).collect();
    let zero = vec![0u8; sel.len()];
    let (has_inner, has_outer) = match b.style {
        "inner_bevel" => (true, false),
        "outer_bevel" => (false, true),
        _ => (true, true),
    };
    let pick =
        |on: bool, plane: &[u8], band: &[u8]| if on { mul(plane, band) } else { zero.clone() };
    let outside = inv(sel);
    Planes {
        outer_hl: pick(has_outer, &hl, &outside),
        outer_sh: pick(has_outer, &sh, &outside),
        inner_hl: pick(has_inner, &hl, sel),
        inner_sh: pick(has_inner, &sh, sel),
    }
}

/// The expected projection over a solid `bg`: below halves, then the layer
/// pixel (if any) at `fill_opacity` with `layer_mode`, then the inner
/// halves — every step the W3C reference composite, quantized once.
fn expected(
    bg: [u8; 4],
    w: u32,
    h: u32,
    layer_px: impl Fn(u32, u32) -> Option<[u8; 4]>,
    p: &Planes,
    b: &Bevel,
    layer_mode: c_int,
) -> RgbaImage {
    let (hl_mode, _, hl_rgb, hl_op) = b.highlight;
    let (sh_mode, _, sh_rgb, sh_op) = b.shadow;
    let unit = |c: [u8; 3]| {
        [
            f32::from(c[0]) / 255.0,
            f32::from(c[1]) / 255.0,
            f32::from(c[2]) / 255.0,
            1.0,
        ]
    };
    RgbaImage::from_fn(w, h, |x, y| {
        let i = (y * w + x) as usize;
        let mut acc = to_unit(bg);
        acc = ref_composite(
            acc,
            unit(hl_rgb),
            hl_op * f32::from(p.outer_hl[i]) / 255.0,
            hl_mode,
        );
        acc = ref_composite(
            acc,
            unit(sh_rgb),
            sh_op * f32::from(p.outer_sh[i]) / 255.0,
            sh_mode,
        );
        if let Some(l) = layer_px(x, y) {
            acc = ref_composite(acc, to_unit(l), b.fill_opacity, layer_mode);
        }
        acc = ref_composite(
            acc,
            unit(hl_rgb),
            hl_op * f32::from(p.inner_hl[i]) / 255.0,
            hl_mode,
        );
        acc = ref_composite(
            acc,
            unit(sh_rgb),
            sh_op * f32::from(p.inner_sh[i]) / 255.0,
            sh_mode,
        );
        Rgba(quantized(acc))
    })
}

/// The oracle projection of `RECT` on `CANVAS` over `bg` with its own light.
fn expected_rect(bg: [u8; 4], b: &Bevel, layer_mode: c_int) -> RgbaImage {
    let sel = rect_selection(CANVAS.0, CANVAS.1, RECT);
    let p = planes(&sel, CANVAS.0, CANVAS.1, b, (b.angle, b.altitude));
    expected(
        bg,
        CANVAS.0,
        CANVAS.1,
        |x, y| in_rect(RECT, i64::from(x), i64::from(y)).then_some(RECT_COLOR),
        &p,
        b,
        layer_mode,
    )
}

// ---------------------------------------------------------------- tests --

/// Rows whose height depends on x only (BAND px clear of the top and
/// bottom edges, so the vertical kernel and the central difference never
/// see them) and the same for columns.
fn pure_rows() -> std::ops::Range<u32> {
    (RECT.1 as u32 + BAND as u32)..(RECT.1 as u32 + RECT.3 - BAND as u32)
}

fn pure_cols() -> std::ops::Range<u32> {
    (RECT.0 as u32 + BAND as u32)..(RECT.0 as u32 + RECT.2 - BAND as u32)
}

/// Distance of column `x` inward from the rect's right edge (0 = the edge
/// pixel), and from the left edge.
fn from_right(x: u32) -> i64 {
    i64::from(RECT.0) + i64::from(RECT.2) - 1 - i64::from(x)
}

fn from_left(x: u32) -> i64 {
    i64::from(x) - i64::from(RECT.0)
}

#[test]
fn inner_bevel_lights_the_edge_facing_the_light_and_shades_the_far_one() {
    // Light from the right (angle 0): on the right band h falls toward the
    // edge, so n.x > 0 and d > 0 — highlight only; on the left band the
    // slope faces away — shadow only; on the top and bottom bands the
    // height varies in y only, so d = n.x·L.x = 0: nothing at all.
    let flat = styled(&gray_doc(), 1, &Bevel::default().json()).flattened();
    for y in pure_rows() {
        for x in RECT.0 as u32..RECT.0 as u32 + RECT.2 {
            let got = px(&flat, x, y);
            let (r, l) = (from_right(x), from_left(x));
            let what = format!("({x},{y})");
            if r < BAND {
                assert_lighter(got, RECT_COLOR, r == 0, &what);
            } else if l < BAND {
                assert_darker(got, RECT_COLOR, l == 0, &what);
            } else {
                assert_eq!(got, RECT_COLOR, "{what}: the plateau is untouched");
            }
        }
    }
    for x in pure_cols() {
        for y in RECT.1 as u32..RECT.1 as u32 + RECT.3 {
            assert_eq!(
                px(&flat, x, y),
                RECT_COLOR,
                "top/bottom band ({x},{y}) must be empty"
            );
        }
    }
    // The inner bevel is Interior only: nothing lands outside the shape.
    for y in 0..CANVAS.1 {
        for x in 0..CANVAS.0 {
            if !in_rect(RECT, i64::from(x), i64::from(y)) {
                assert_eq!(px(&flat, x, y), GRAY, "outside ({x},{y})");
            }
        }
    }
}

#[test]
fn angle_180_and_direction_down_both_swap_the_bands() {
    let from_left_light = Bevel {
        angle: 180.0,
        ..Bevel::default()
    };
    let down = Bevel {
        down: true,
        ..Bevel::default()
    };
    let a = styled(&gray_doc(), 1, &from_left_light.json()).flattened();
    let b = styled(&gray_doc(), 1, &down.json()).flattened();
    for y in pure_rows() {
        for x in RECT.0 as u32..RECT.0 as u32 + RECT.2 {
            let (r, l) = (from_right(x), from_left(x));
            for (flat, name) in [(&a, "angle 180"), (&b, "direction down")] {
                let got = px(flat, x, y);
                let what = format!("{name} ({x},{y})");
                if l < BAND {
                    assert_lighter(got, RECT_COLOR, l == 0, &what);
                } else if r < BAND {
                    assert_darker(got, RECT_COLOR, r == 0, &what);
                } else {
                    assert_eq!(got, RECT_COLOR, "{what}");
                }
            }
        }
    }
    // Negating d and reversing the light are the same operation on the
    // pure bands; at the corners `sin 180°` is a few ulps from 0, hence ±1.
    assert_image(&a, &b, 1, "angle 180 vs direction down");
}

#[test]
fn nothing_at_altitude_90_size_0_zero_opacity_or_disabled() {
    let plain = gray_doc().flattened();
    let cases = [
        (
            "altitude 90",
            Bevel {
                altitude: 90.0,
                ..Bevel::default()
            },
        ),
        (
            "size 0",
            Bevel {
                size: 0.0,
                ..Bevel::default()
            },
        ),
        (
            "both opacities 0",
            Bevel {
                highlight: (BLEND_SCREEN, "screen", [255, 255, 255], 0.0),
                shadow: (BLEND_MULTIPLY, "multiply", [0, 0, 0], 0.0),
                ..Bevel::default()
            },
        ),
    ];
    for (name, bevel) in cases {
        let flat = styled(&gray_doc(), 1, &bevel.json()).flattened();
        assert_eq!(
            flat, plain,
            "{name} must render exactly the unstyled projection"
        );
    }
    // A disabled bevel alone is an identity style, which the core refuses
    // to store (the setter's one rule); beside a fill opacity it is stored
    // and renders exactly as the fill opacity alone.
    let disabled = Bevel {
        enabled: false,
        ..Bevel::default()
    };
    assert!(
        try_styled(&gray_doc(), 1, Some(&disabled.json()))
            .expect("valid")
            .is_none(),
        "a disabled effect alone is an identity style"
    );
    let disabled_with_fill = Bevel {
        fill_opacity: 0.5,
        ..disabled
    };
    let fill_only = styled(&gray_doc(), 1, "{\"fill_opacity\":0.5}").flattened();
    assert_eq!(
        styled(&gray_doc(), 1, &disabled_with_fill.json()).flattened(),
        fill_only,
        "a disabled bevel renders nothing"
    );
    // One opacity at 0 drops only that half.
    let no_shadow = Bevel {
        shadow: (BLEND_MULTIPLY, "multiply", [0, 0, 0], 0.0),
        ..Bevel::default()
    };
    let flat = styled(&gray_doc(), 1, &no_shadow.json()).flattened();
    let y = pure_rows().start;
    assert_lighter(
        px(&flat, RECT.0 as u32 + RECT.2 - 1, y),
        RECT_COLOR,
        true,
        "highlight kept",
    );
    assert_eq!(px(&flat, RECT.0 as u32, y), RECT_COLOR, "shadow dropped");
}

#[test]
fn a_full_layer_bevels_only_along_the_canvas_border() {
    // A canvas-sized opaque layer is constant height everywhere but at
    // the layer's boundary, which the zero-padded plane makes an edge —
    // Photoshop's frame bevel on a full layer. Flat ground shades to 0:
    // every pixel further than the band from the border is untouched.
    let doc = RzDocument::from_pixels(solid(CANVAS.0, CANVAS.1, GRAY))
        .adding_image_layer(0, solid(CANVAS.0, CANVAS.1, RECT_COLOR), "Full")
        .expect("add layer");
    let flat = styled(&doc, 1, &Bevel::default().json()).flattened();
    let band = BAND as u32;
    for y in 0..CANVAS.1 {
        for x in 0..CANVAS.0 {
            let got = px(&flat, x, y);
            let inside = x >= band && y >= band && x < CANVAS.0 - band && y < CANVAS.1 - band;
            if inside {
                assert_eq!(got, RECT_COLOR, "flat ground ({x},{y})");
            }
        }
    }
    let y = CANVAS.1 / 2;
    assert_lighter(
        px(&flat, CANVAS.0 - 1, y),
        RECT_COLOR,
        true,
        "right border lit",
    );
    assert_darker(px(&flat, 0, y), RECT_COLOR, true, "left border shaded");
}

#[test]
fn inner_bevel_matches_the_normal_from_the_feather_oracle() {
    let bevel = Bevel::default();
    let flat = styled(&gray_doc(), 1, &bevel.json()).flattened();
    assert_image(
        &flat,
        &expected_rect(GRAY, &bevel, BLEND_NORMAL),
        2,
        "inner bevel, size 4",
    );

    // The plan's spot check, spelled out: along one pure row, h is the
    // feathered rect times the rect, hx its central difference,
    // n.x = −4 hx / sqrt(1 + 16 hx²), d = n.x · cos 30°, and the right
    // band's pixels are screen-white at 0.75 · d over the rect colour.
    let sel = rect_selection(CANVAS.0, CANVAS.1, RECT);
    let h = mul(
        &feathered_plane(&sel, CANVAS.0, CANVAS.1, radius_for(4.0)),
        &sel,
    );
    let y = pure_rows().start;
    let at = |x: u32| f32::from(h[(y * CANVAS.0 + x) as usize]) / 255.0;
    let mut lit_columns = 0;
    for x in RECT.0 as u32 + RECT.2 - BAND as u32..RECT.0 as u32 + RECT.2 {
        let hx = (at(x + 1) - at(x - 1)) / 2.0;
        assert!(
            hx <= 0.0,
            "the right band falls toward the edge at {x}: hx = {hx}"
        );
        let nx = -4.0 * hx / (1.0 + 16.0 * hx * hx).sqrt();
        let d = nx * 30f32.to_radians().cos();
        let cov = coverage(d);
        let want = quantized(ref_composite(
            to_unit(RECT_COLOR),
            [1.0, 1.0, 1.0, 1.0],
            0.75 * f32::from(cov) / 255.0,
            BLEND_SCREEN,
        ));
        assert_px(
            px(&flat, x, y),
            want,
            2,
            &format!("column {x} (d = {d:.3})"),
        );
        if cov > 0 {
            lit_columns += 1;
        }
    }
    assert!(
        lit_columns >= 4,
        "the band should be lit across most of its width, got {lit_columns}"
    );
}

#[test]
fn outer_bevel_emboss_and_pillow_place_their_halves_below_and_inside() {
    for style in ["outer_bevel", "emboss", "pillow_emboss"] {
        let bevel = Bevel {
            style,
            ..Bevel::default()
        };
        let flat = styled(&gray_doc(), 1, &bevel.json()).flattened();
        assert_image(&flat, &expected_rect(GRAY, &bevel, BLEND_NORMAL), 2, style);
    }
    // The shape of each style, directly: light from the right.
    let y = pure_rows().start;
    let (right_edge, left_edge) = (RECT.0 as u32 + RECT.2 - 1, RECT.0 as u32);
    let (right_out, left_out) = (right_edge + 1, left_edge - 1);
    let outer = styled(
        &gray_doc(),
        1,
        &Bevel {
            style: "outer_bevel",
            ..Bevel::default()
        }
        .json(),
    )
    .flattened();
    assert_lighter(
        px(&outer, right_out, y),
        GRAY,
        true,
        "outer bevel: outside right lit",
    );
    assert_darker(
        px(&outer, left_out, y),
        GRAY,
        true,
        "outer bevel: outside left shaded",
    );
    assert_eq!(
        px(&outer, right_edge, y),
        RECT_COLOR,
        "outer bevel: inside untouched"
    );
    let emboss = styled(
        &gray_doc(),
        1,
        &Bevel {
            style: "emboss",
            ..Bevel::default()
        }
        .json(),
    )
    .flattened();
    assert_lighter(
        px(&emboss, right_out, y),
        GRAY,
        true,
        "emboss: outside right lit",
    );
    assert_lighter(
        px(&emboss, right_edge, y),
        RECT_COLOR,
        true,
        "emboss: inside right lit",
    );
    assert_darker(
        px(&emboss, left_out, y),
        GRAY,
        true,
        "emboss: outside left shaded",
    );
    assert_darker(
        px(&emboss, left_edge, y),
        RECT_COLOR,
        true,
        "emboss: inside left shaded",
    );
    let pillow = styled(
        &gray_doc(),
        1,
        &Bevel {
            style: "pillow_emboss",
            ..Bevel::default()
        }
        .json(),
    )
    .flattened();
    assert_lighter(
        px(&pillow, right_out, y),
        GRAY,
        true,
        "pillow: outside right lit",
    );
    assert_darker(
        px(&pillow, right_edge, y),
        RECT_COLOR,
        true,
        "pillow: inside right is a dent",
    );
    assert_darker(
        px(&pillow, left_out, y),
        GRAY,
        true,
        "pillow: outside left shaded",
    );
    assert_lighter(
        px(&pillow, left_edge, y),
        RECT_COLOR,
        true,
        "pillow: inside left lit",
    );
}

#[test]
fn highlight_and_shadow_keep_their_own_blend_and_opacity_on_a_multiply_layer() {
    // A Multiply-blend LAYER with Normal-blend halves in their own colours:
    // the halves follow ref_composite(..., NORMAL) over the multiplied
    // pixels, never the layer's Multiply.
    let bevel = Bevel {
        style: "emboss",
        highlight: (BLEND_NORMAL, "normal", [255, 200, 40], 0.4),
        shadow: (BLEND_NORMAL, "normal", [30, 60, 220], 0.6),
        ..Bevel::default()
    };
    let doc = gray_doc()
        .with_layer_blend_mode(1, BlendMode::Multiply)
        .expect("multiply");
    let flat = styled(&doc, 1, &bevel.json()).flattened();
    assert_image(
        &flat,
        &expected_rect(GRAY, &bevel, BLEND_MULTIPLY),
        2,
        "emboss on a multiply layer",
    );
    // Sanity, without the oracle: the multiplied rect is dark, and the
    // Normal orange highlight on its right edge is brighter than that in
    // red — Multiply could only have darkened it.
    let multiplied = quantized(ref_composite(
        to_unit(GRAY),
        to_unit(RECT_COLOR),
        1.0,
        BLEND_MULTIPLY,
    ));
    let y = pure_rows().start;
    let lit = px(&flat, RECT.0 as u32 + RECT.2 - 1, y);
    assert!(
        lit[0] > multiplied[0],
        "highlight {lit:?} must lighten red over {multiplied:?}"
    );
    let shaded = px(&flat, RECT.0 as u32, y);
    assert!(
        shaded[2] > multiplied[2],
        "a blue Normal shadow {shaded:?} adds blue over {multiplied:?}"
    );
}

#[test]
fn fill_opacity_zero_keeps_the_bevel() {
    let bevel = Bevel {
        style: "emboss",
        fill_opacity: 0.0,
        ..Bevel::default()
    };
    let flat = styled(&gray_doc(), 1, &bevel.json()).flattened();
    assert_image(
        &flat,
        &expected_rect(GRAY, &bevel, BLEND_NORMAL),
        2,
        "emboss at fill 0",
    );
    let y = pure_rows().start;
    let mid = RECT.0 as u32 + RECT.2 / 2;
    assert_eq!(px(&flat, mid, y), GRAY, "the pixels are gone");
    assert_lighter(
        px(&flat, RECT.0 as u32 + RECT.2 - 1, y),
        GRAY,
        true,
        "the inner highlight stays",
    );
}

#[test]
fn soften_and_depth_follow_the_oracle() {
    let soft = Bevel {
        soften: 4.0,
        ..Bevel::default()
    };
    let flat = styled(&gray_doc(), 1, &soft.json()).flattened();
    assert_image(
        &flat,
        &expected_rect(GRAY, &soft, BLEND_NORMAL),
        2,
        "soften 4",
    );
    // Softening the step at the edge lowers the rim's slope: the edge
    // pixel is less lit than without soften — and still nothing outside.
    let hard = styled(&gray_doc(), 1, &Bevel::default().json()).flattened();
    let y = pure_rows().start;
    let edge = RECT.0 as u32 + RECT.2 - 1;
    assert!(
        px(&flat, edge, y)[0] < px(&hard, edge, y)[0],
        "soften lowers the rim"
    );
    assert_eq!(
        px(&flat, edge + 1, y),
        GRAY,
        "an inner bevel stays inside even softened"
    );

    let deep = Bevel {
        depth: 5.0,
        ..Bevel::default()
    };
    let flat = styled(&gray_doc(), 1, &deep.json()).flattened();
    assert_image(
        &flat,
        &expected_rect(GRAY, &deep, BLEND_NORMAL),
        2,
        "depth 5",
    );
    assert!(
        px(&flat, edge, y)[0] > px(&hard, edge, y)[0],
        "depth raises the contrast"
    );
}

#[test]
fn use_global_light_reads_the_document_light_and_altitude() {
    let global = Bevel {
        use_global_light: true,
        angle: 120.0, // ignored while the global light is on
        altitude: 60.0,
        ..Bevel::default()
    };
    let own = Bevel::default(); // angle 0, altitude 30, its own light
    let lit_from_right = styled(&with_light(&gray_doc(), 0.0, 30.0), 1, &global.json()).flattened();
    assert_eq!(
        lit_from_right,
        styled(&gray_doc(), 1, &own.json()).flattened(),
        "global (0°, 30°) resolves to exactly the effect's own (0°, 30°)"
    );
    let plain = gray_doc().flattened();
    let overhead = styled(&with_light(&gray_doc(), 0.0, 90.0), 1, &global.json()).flattened();
    assert_eq!(overhead, plain, "a global altitude of 90 shades nothing");
    // And an effect with its own light ignores the document's.
    let own_left = Bevel {
        angle: 180.0,
        ..Bevel::default()
    };
    let flat = styled(&with_light(&gray_doc(), 0.0, 30.0), 1, &own_left.json()).flattened();
    let y = pure_rows().start;
    assert_lighter(
        px(&flat, RECT.0 as u32, y),
        RECT_COLOR,
        true,
        "own angle 180 lights the left",
    );
}

#[test]
fn offset_layers_and_masks_follow_the_shape() {
    // The rect hangs off the top-left corner: (-8, -6). The oracle runs on
    // a virtual plane extended by 20 px on those sides, where the rect
    // sits fully inside, and is cropped back to the canvas.
    let bevel = Bevel {
        style: "emboss",
        ..Bevel::default()
    };
    let rect = (-8, -6, RECT.2, RECT.3);
    let doc = rect_over(GRAY, CANVAS, rect, RECT_COLOR);
    let flat = styled(&doc, 1, &bevel.json()).flattened();
    let (ext, vw, vh) = (20u32, CANVAS.0 + 20, CANVAS.1 + 20);
    let vrect = (rect.0 + ext as i32, rect.1 + ext as i32, rect.2, rect.3);
    let sel = rect_selection(vw, vh, vrect);
    let p = planes(&sel, vw, vh, &bevel, (bevel.angle, bevel.altitude));
    let virtual_expected = expected(
        GRAY,
        vw,
        vh,
        |x, y| in_rect(vrect, i64::from(x), i64::from(y)).then_some(RECT_COLOR),
        &p,
        &bevel,
        BLEND_NORMAL,
    );
    let want = RgbaImage::from_fn(CANVAS.0, CANVAS.1, |x, y| {
        *virtual_expected.get_pixel(x + ext, y + ext)
    });
    assert_image(&flat, &want, 2, "emboss partly off-canvas");
    // The rect's right edge is at canvas x = 15 and row 4 is 10 px below
    // its (off-canvas) top: a pure row.
    let right_edge = (rect.0 + rect.2 as i32 - 1) as u32;
    assert_lighter(
        px(&flat, right_edge, 4),
        RECT_COLOR,
        true,
        "the visible right edge is lit",
    );

    // A mask hiding the right half moves the shape's right edge — and the
    // bevel with it: the effect is a function of alpha × mask.
    let half = i64::from(RECT.0) + i64::from(RECT.2) / 2;
    let mask = selection(CANVAS.0, CANVAS.1, |x, _| {
        if i64::from(x) < half {
            255
        } else {
            0
        }
    });
    let masked = gray_doc()
        .add_mask(1, MaskKind::FromSelection(&mask))
        .expect("mask");
    let flat = styled(&masked, 1, &Bevel::default().json()).flattened();
    let sel: Vec<u8> = rect_selection(CANVAS.0, CANVAS.1, RECT)
        .iter()
        .zip(&mask)
        .map(|(&s, &m)| ((u32::from(s) * u32::from(m) + 127) / 255) as u8)
        .collect();
    let p = planes(&sel, CANVAS.0, CANVAS.1, &Bevel::default(), (0.0, 30.0));
    let want = expected(
        GRAY,
        CANVAS.0,
        CANVAS.1,
        |x, y| {
            (in_rect(RECT, i64::from(x), i64::from(y)) && i64::from(x) < half).then_some(RECT_COLOR)
        },
        &p,
        &Bevel::default(),
        BLEND_NORMAL,
    );
    assert_image(&flat, &want, 2, "inner bevel on a masked rect");
    let y = pure_rows().start;
    assert_lighter(
        px(&flat, half as u32 - 1, y),
        RECT_COLOR,
        true,
        "the mask's edge is the lit edge",
    );
    assert_eq!(
        px(&flat, RECT.0 as u32 + RECT.2 - 1, y),
        GRAY,
        "the masked half shows the backdrop"
    );
}

#[test]
fn transparent_layers_render_nothing_and_the_source_is_unchanged() {
    let base = RzDocument::from_pixels(solid(CANVAS.0, CANVAS.1, GRAY))
        .adding_image_layer(0, solid(RECT.2, RECT.3, [0, 0, 0, 0]), "Clear")
        .expect("add layer");
    let plain = base.flattened();
    let flat = styled(&base, 1, &Bevel::default().json()).flattened();
    assert_eq!(flat, plain, "a fully transparent shape has no edges");

    let source = gray_doc();
    let before = source.flattened();
    let styled_doc = styled(&source, 1, &Bevel::default().json());
    assert_eq!(
        source.flattened(),
        before,
        "the input document is untouched"
    );
    assert!(
        source.layers[1].style.is_none(),
        "the input layer carries no style"
    );
    assert!(styled_doc.layers[1].style.is_some());
    assert_ne!(
        styled_doc.flattened(),
        before,
        "the styled copy renders the bevel"
    );
}

#[test]
fn the_canonical_style_sets_again_as_unchanged() {
    let doc = styled(&gray_doc(), 1, &Bevel::default().json());
    let canonical = doc.layers[1]
        .style
        .as_ref()
        .expect("style stored")
        .to_json();
    assert!(
        canonical.contains("\"type\":\"bevel_emboss\""),
        "{canonical}"
    );
    assert!(
        canonical.contains("\"style\":\"inner_bevel\""),
        "{canonical}"
    );
    assert!(
        try_styled(&doc, 1, Some(&canonical))
            .expect("valid")
            .is_none(),
        "the echo is refused as unchanged"
    );
    assert!(
        try_styled(&doc, 1, Some(&Bevel::default().json()))
            .expect("valid")
            .is_none(),
        "and so is the original text"
    );
}
