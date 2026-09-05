//! The three HSL-family ops of `rz_image_adjust_op`: `vibrance`,
//! `hue_saturation` and `color_balance`, exercised through the C ABI.
//!
//! Every expected value comes from an ORACLE WRITTEN HERE from the published
//! formula — the hexcone conversions, GIMP's colour-balance masks, the
//! shader-community vibrance kernel with this build's two documented
//! additions — never from the core's own output. The handful of numbers the
//! phase plan pins are asserted as literals ON TOP of the oracle, so a wrong
//! oracle fails before it can bless a wrong implementation.

use std::ffi::{c_char, CString};
use std::ptr;

use image::{Rgba, RgbaImage};
use rasterize_core::ffi::*;
use rasterize_core::ffi_adjust::*;
use rasterize_core::RzImage;
use tempfile::TempDir;

mod common;
use common::*;

// ------------------------------------------------------------- plumbing --

/// Runs `op` with `params` over `img` through the ONE destructive export.
fn adjust(img: *const RzImage, op: &str, params: &str) -> *mut RzImage {
    let c_op = CString::new(op).unwrap();
    let c_params = CString::new(params).unwrap();
    let mut err: *mut c_char = ptr::null_mut();
    let out = unsafe { rz_image_adjust_op(img, c_op.as_ptr(), c_params.as_ptr(), &mut err) };
    assert!(
        !out.is_null(),
        "rz_image_adjust_op({op}, {params}) failed: {}",
        take_err_string(err)
    );
    assert!(err.is_null(), "err_out set on success");
    out
}

/// A one-row image of the given colours.
fn row_of(colors: &[[u8; 3]]) -> RgbaImage {
    RgbaImage::from_fn(colors.len() as u32, 1, |x, _| {
        let c = colors[x as usize];
        Rgba([c[0], c[1], c[2], 255])
    })
}

/// The RGB triples `op` produces for `src`, alpha asserted untouched.
fn run(dir: &TempDir, tag: &str, src: &RgbaImage, op: &str, params: &str) -> Vec<[u8; 3]> {
    let img = open_pattern(dir, &format!("{tag}.png"), src);
    let out = adjust(img, op, params);
    let bytes = pixels(out);
    let alpha: Vec<u8> = bytes.iter().skip(3).step_by(4).copied().collect();
    let expected: Vec<u8> = src.pixels().map(|p| p[3]).collect();
    assert_eq!(alpha, expected, "{tag}: alpha must never be touched");
    unsafe { rz_image_free(out) };
    free(img);
    bytes.chunks_exact(4).map(|p| [p[0], p[1], p[2]]).collect()
}

/// The raw RGBA bytes `op` produces for `src` — for the comparisons that
/// must be byte-for-byte rather than within a rounding step.
fn run_bytes(dir: &TempDir, tag: &str, src: &RgbaImage, op: &str, params: &str) -> Vec<u8> {
    let img = open_pattern(dir, &format!("{tag}.png"), src);
    let out = adjust(img, op, params);
    let bytes = pixels(out);
    unsafe { rz_image_free(out) };
    free(img);
    bytes
}

/// The op must refuse `params` with a message naming it.
fn refuses(dir: &TempDir, tag: &str, op: &str, params: &str) {
    let img = open_pattern(dir, &format!("{tag}.png"), &row_of(&[[128, 128, 128]]));
    let c_op = CString::new(op).unwrap();
    let c_params = CString::new(params).unwrap();
    let mut err: *mut c_char = ptr::null_mut();
    let out = unsafe { rz_image_adjust_op(img, c_op.as_ptr(), c_params.as_ptr(), &mut err) };
    assert!(out.is_null(), "{op} {params} must be refused");
    assert!(
        take_err_string(err).contains(op),
        "{op} {params}: the message must name the op"
    );
    free(img);
}

fn norm(c: [u8; 3]) -> [f64; 3] {
    c.map(|v| f64::from(v) / 255.0)
}

fn assert_bytes(got: [u8; 3], want: [f64; 3], what: &str) {
    for (c, (g, w)) in got.iter().zip(want).enumerate() {
        let want_byte = (w.clamp(0.0, 1.0) * 255.0).round();
        assert!(
            (f64::from(*g) - want_byte).abs() <= 1.0,
            "{what} channel {c}: {g} vs {want_byte}"
        );
    }
}

// ------------------------------------------------------------- the oracle --
//
// Written from the published formulas, in f64, deliberately the long way.

fn luma(rgb: [f64; 3]) -> f64 {
    0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2]
}

fn rgb_to_hsl(rgb: [f64; 3]) -> [f64; 3] {
    let mx = rgb[0].max(rgb[1]).max(rgb[2]);
    let mn = rgb[0].min(rgb[1]).min(rgb[2]);
    let d = mx - mn;
    let l = (mx + mn) / 2.0;
    if d == 0.0 {
        return [0.0, 0.0, l];
    }
    let s = if l <= 0.5 {
        d / (mx + mn)
    } else {
        d / (2.0 - mx - mn)
    };
    let h = if mx == rgb[0] {
        60.0 * (((rgb[1] - rgb[2]) / d).rem_euclid(6.0))
    } else if mx == rgb[1] {
        60.0 * ((rgb[2] - rgb[0]) / d + 2.0)
    } else {
        60.0 * ((rgb[0] - rgb[1]) / d + 4.0)
    };
    [h.rem_euclid(360.0), s, l]
}

fn hsl_to_rgb(hsl: [f64; 3]) -> [f64; 3] {
    let (h, s, l) = (hsl[0].rem_euclid(360.0), hsl[1], hsl[2]);
    let c = (1.0 - (2.0 * l - 1.0).abs()) * s;
    let hp = h / 60.0;
    let x = c * (1.0 - (hp % 2.0 - 1.0).abs());
    let (r, g, b) = match hp as u32 {
        0 => (c, x, 0.0),
        1 => (x, c, 0.0),
        2 => (0.0, c, x),
        3 => (0.0, x, c),
        4 => (x, 0.0, c),
        _ => (c, 0.0, x),
    };
    let m = l - c / 2.0;
    [r + m, g + m, b + m]
}

fn hue_distance(a: f64, b: f64) -> f64 {
    let d = (a - b).rem_euclid(360.0);
    if d > 180.0 {
        360.0 - d
    } else {
        d
    }
}

/// Hue/Saturation's two-sided slider curve: `+1` reaches the top of the
/// range, `-1` the bottom, continuous at 0.
fn two_sided(v: f64, a: f64) -> f64 {
    if a >= 0.0 {
        v + a * (1.0 - v)
    } else {
        v * (1.0 + a)
    }
    .clamp(0.0, 1.0)
}

/// The HSL edit both ops share. A pixel with no chroma stays neutral —
/// the model's own rule, and why Colorize exists as a separate checkbox.
fn hsl_shift(rgb: [f64; 3], hue: f64, sat: f64, light: f64) -> [f64; 3] {
    let hsl = rgb_to_hsl(rgb);
    let s = if hsl[1] > 0.0 {
        two_sided(hsl[1], sat)
    } else {
        0.0
    };
    hsl_to_rgb([hsl[0] + hue, s, two_sided(hsl[2], light)])
}

/// The vibrance gain, with `skin` switchable so the test can show which
/// term moved a number (the phase plan pins both values for one pixel).
fn vibrance_gain(rgb: [f64; 3], v: f64, skin_protection: bool) -> f64 {
    let sat = rgb[0].max(rgb[1]).max(rgb[2]) - rgb[0].min(rgb[1]).min(rgb[2]);
    let protection = if skin_protection && v > 0.0 {
        let skin = (1.0 - hue_distance(rgb_to_hsl(rgb)[0], 25.0) / 25.0).clamp(0.0, 1.0);
        1.0 - 0.5 * skin
    } else {
        1.0
    };
    (1.0 + v * (1.0 - v.signum() * sat) * protection).max(0.0)
}

fn vibrance_oracle(rgb: [f64; 3], v: f64, saturation: f64, skin: bool) -> [f64; 3] {
    let k = vibrance_gain(rgb, v, skin);
    let anchor = luma(rgb);
    // The gain is free to overshoot — the flat slider that follows it reads
    // a COLOUR, and a triple outside [0, 1] has no hue-cone lightness or
    // saturation, so it is clamped back into gamut first. The properties
    // this costs nothing and buys everything are asserted independently by
    // `vibrance_saturation_is_continuous_where_the_gain_leaves_the_gamut`.
    let boosted = rgb.map(|c| (anchor + (c - anchor) * k).clamp(0.0, 1.0));
    if saturation == 0.0 {
        boosted
    } else {
        hsl_shift(boosted, 0.0, saturation, 0.0)
    }
}

/// GIMP's shadow / midtone / highlight masks at one channel level.
fn tone_masks(v: f64) -> [f64; 3] {
    let (a, b) = (0.25, 0.333);
    let low = ((v - b) / -a + 0.5).clamp(0.0, 1.0);
    let high = ((v + b - 1.0) / a + 0.5).clamp(0.0, 1.0);
    let mid = ((v - b) / a + 0.5).clamp(0.0, 1.0) * ((v + b - 1.0) / -a + 0.5).clamp(0.0, 1.0);
    [low, mid, high]
}

fn color_balance_oracle(
    rgb: [f64; 3],
    shadows: [f64; 3],
    midtones: [f64; 3],
    highlights: [f64; 3],
    preserve: bool,
) -> [f64; 3] {
    let out: [f64; 3] = std::array::from_fn(|c| {
        let [low, mid, high] = tone_masks(rgb[c]);
        (rgb[c] + (shadows[c] * low + midtones[c] * mid + highlights[c] * high) * 0.7)
            .clamp(0.0, 1.0)
    });
    if !preserve {
        return out;
    }
    let out_luma = luma(out);
    if out_luma <= 0.0 {
        return out;
    }
    let k = luma(rgb) / out_luma;
    out.map(|v| (v * k).clamp(0.0, 1.0))
}

// ------------------------------------------------------------- vibrance --

/// The rows the phase plan pins, as literals, next to the oracle that
/// produces them. `(200, 150, 120)` carries BOTH numbers so a reader can
/// see which term moved it: hue 22.5 deg is inside the skin band, so the
/// protection halves a 0.343 boost to 0.189.
#[test]
fn vibrance_reproduces_the_pinned_rows() {
    let dir = TempDir::new().unwrap();
    let src = row_of(&[
        [200, 150, 120],
        [100, 200, 100],
        [255, 0, 0],
        [140, 130, 125],
    ]);
    let out = run(&dir, "vib-rows", &src, "vibrance", "{\"vibrance\":0.5}");

    let skin_row = vibrance_oracle(norm([200, 150, 120]), 0.5, 0.0, true);
    let bare_row = vibrance_oracle(norm([200, 150, 120]), 0.5, 0.0, false);
    for (got, want) in [
        (skin_row, [207.839, 148.403, 112.741]),
        (bare_row, [214.253, 147.096, 106.802]),
    ] {
        for (c, (g, w)) in got.iter().zip(want).enumerate() {
            assert!(
                (g * 255.0 - w).abs() < 0.01,
                "the oracle itself is wrong at channel {c}: {} vs {w}",
                g * 255.0
            );
        }
    }
    assert_bytes(out[0], skin_row, "vibrance (200,150,120) +0.5");
    assert!(
        (skin_row[0] - bare_row[0]).abs() > 0.02,
        "the skin term must actually move this pixel"
    );

    // Hue 120 deg is nowhere near the skin band, so the two kernels must
    // agree EXACTLY — which is what proves the gate is bounded and not a
    // blanket attenuation.
    let green_skin = vibrance_oracle(norm([100, 200, 100]), 0.5, 0.0, true);
    let green_bare = vibrance_oracle(norm([100, 200, 100]), 0.5, 0.0, false);
    assert_eq!(green_skin, green_bare, "hue 120 deg has no skin weight");
    assert_bytes(out[1], green_skin, "vibrance (100,200,100) +0.5");
    assert!(
        (green_skin[0] * 255.0 - 78.27).abs() < 0.01
            && (green_skin[1] * 255.0 - 208.66).abs() < 0.01,
        "the pinned green row is {:?}",
        green_skin.map(|v| v * 255.0)
    );

    // An already-saturated pixel has gain exactly 1 and comes back
    // untouched — the whole reason vibrance is not saturation.
    assert_eq!(out[2], [255, 0, 0], "a saturated red is left alone");
    assert_eq!(vibrance_gain(norm([255, 0, 0]), 0.5, true), 1.0);

    assert_bytes(
        out[3],
        vibrance_oracle(norm([140, 130, 125]), 0.5, 0.0, true),
        "vibrance (140,130,125) +0.5",
    );
}

/// The clamp at 0 is the whole point of the negative half: without it a
/// gain below zero REFLECTS the colour through its own luma and pure red
/// comes back teal.
#[test]
fn vibrance_converges_to_grey_and_never_crosses_the_luma() {
    let dir = TempDir::new().unwrap();
    let src = row_of(&[[255, 0, 0], [255, 64, 64], [200, 150, 120]]);

    let out = run(&dir, "vib-neg1", &src, "vibrance", "{\"vibrance\":-1}");
    let grey = (luma(norm([255, 0, 0])) * 255.0).round();
    assert!((grey - 54.0).abs() < 1.0, "the luma of pure red is {grey}");
    for c in 0..3 {
        assert!(
            (f64::from(out[0][c]) - grey).abs() <= 1.0,
            "-1 vibrance must land pure red on its own luma, got {:?}",
            out[0]
        );
    }

    let out = run(&dir, "vib-neg07", &src, "vibrance", "{\"vibrance\":-0.7}");
    for (i, color) in [[255u8, 0, 0], [255, 64, 64], [200, 150, 120]]
        .iter()
        .enumerate()
    {
        let src_rgb = norm(*color);
        let anchor = luma(src_rgb) * 255.0;
        for c in 0..3 {
            let from = f64::from(color[c]);
            let to = f64::from(out[i][c]);
            // No channel may cross its own luma from the other side.
            assert!(
                (to - anchor).abs() <= (from - anchor).abs() + 1.0,
                "pixel {i} channel {c}: {from} -> {to} crossed the luma {anchor}"
            );
        }
        assert_bytes(
            out[i],
            vibrance_oracle(src_rgb, -0.7, 0.0, true),
            "vibrance -0.7",
        );
    }
    // (255, 64, 64) at -0.7 has gain exactly 0: all three channels land ON
    // the luma, 104.6.
    assert_eq!(vibrance_gain(norm([255, 64, 64]), -0.7, true), 0.0);
    for c in 0..3 {
        assert!((f64::from(out[1][c]) - 104.6).abs() <= 1.0, "{:?}", out[1]);
    }
}

/// Two dialogs a menu apart may not spell "saturation" two ways: vibrance's
/// flat slider IS `hue_saturation`'s master saturation, byte for byte.
/// (`bcs`'s third spelling is deliberately different and frozen.)
#[test]
fn vibrance_saturation_is_the_hue_saturation_curve_byte_for_byte() {
    let dir = TempDir::new().unwrap();
    let src = opaque_pattern(16, 16);
    for s in ["0.5", "-0.5", "1", "-1"] {
        let through_vibrance = run_bytes(
            &dir,
            "vib-sat",
            &src,
            "vibrance",
            &format!("{{\"vibrance\":0,\"saturation\":{s}}}"),
        );
        let through_hue_saturation = run_bytes(
            &dir,
            "hs-sat",
            &src,
            "hue_saturation",
            &format!("{{\"saturation\":{s}}}"),
        );
        assert_eq!(
            through_vibrance, through_hue_saturation,
            "saturation {s} must be the same curve in both ops"
        );
    }
}

/// The two sliders in the one dialog must describe the SAME pixel. The gain
/// may push a channel past 1 — `vibrance` 1 on (255, 128, 128) wants
/// r = 1.197 — and the flat Saturation slider that follows reads a colour,
/// so the boost is clamped back into gamut before the HSL stage sees it.
/// Both properties asserted here follow from what the controls MEAN, not
/// from how they are written:
///
/// * Saturation at rest is the limit of approaching it, so a 0.1 % nudge
///   may not move a pixel more than one code.
/// * A positive Saturation may never REDUCE a pixel's chroma extent.
///
/// Without the clamp, `rgb_to_hsl` of the overshooting triple reports
/// L = 0.82 and S = 2.11; `two_sided` pins S at 1 and the reconstruction
/// lands (255, 165, 165) — 51 levels LESS saturated than the at-rest
/// (255, 114, 114), from a 1 % change, in the direction the label denies.
#[test]
fn vibrance_saturation_is_continuous_where_the_gain_leaves_the_gamut() {
    let dir = TempDir::new().unwrap();
    let probes = [
        [255u8, 128, 128],
        [128, 255, 128],
        [128, 128, 255],
        [250, 210, 120],
    ];
    let src = row_of(&probes);

    // The row is only a regression test if it actually overshoots: every
    // probe must have at least one channel above 1 before the clamp.
    for color in &probes {
        let rgb = norm(*color);
        let k = vibrance_gain(rgb, 1.0, true);
        let anchor = luma(rgb);
        let top = rgb
            .iter()
            .map(|c| anchor + (c - anchor) * k)
            .fold(f64::MIN, f64::max);
        assert!(top > 1.0, "probe {color:?} does not leave the gamut: {top}");
    }

    let extent = |p: [u8; 3]| {
        i32::from(p.iter().copied().max().unwrap_or(0))
            - i32::from(p.iter().copied().min().unwrap_or(0))
    };
    let at_rest = run(&dir, "vib-gamut-0", &src, "vibrance", "{\"vibrance\":1}");

    let nudged = run(
        &dir,
        "vib-gamut-eps",
        &src,
        "vibrance",
        "{\"vibrance\":1,\"saturation\":0.001}",
    );
    for (i, (rest, near)) in at_rest.iter().zip(&nudged).enumerate() {
        for c in 0..3 {
            assert!(
                (i32::from(near[c]) - i32::from(rest[c])).abs() <= 1,
                "probe {i} channel {c}: saturation 0.001 jumped {} -> {}",
                rest[c],
                near[c]
            );
        }
    }

    for s in ["0.01", "0.1", "0.5", "1"] {
        let out = run(
            &dir,
            "vib-gamut-s",
            &src,
            "vibrance",
            &format!("{{\"vibrance\":1,\"saturation\":{s}}}"),
        );
        for (i, (rest, more)) in at_rest.iter().zip(&out).enumerate() {
            assert!(
                extent(*more) >= extent(*rest) - 1,
                "probe {i}: saturation {s} DESATURATED {rest:?} -> {more:?}"
            );
        }
    }
}

#[test]
fn vibrance_defaults_are_a_byte_exact_no_op() {
    let dir = TempDir::new().unwrap();
    let src = opaque_pattern(16, 16);
    for params in ["{}", "{\"vibrance\":0,\"saturation\":0}"] {
        assert_eq!(
            run_bytes(&dir, "vib-id", &src, "vibrance", params),
            *src.as_raw(),
            "{params} must be an exact identity"
        );
    }
}

#[test]
fn vibrance_refuses_out_of_range_parameters() {
    let dir = TempDir::new().unwrap();
    for params in [
        "{\"vibrance\":1.5}",
        "{\"vibrance\":-1.01}",
        "{\"saturation\":2}",
        "{\"vibrance\":\"lots\"}",
    ] {
        refuses(&dir, "vib-bad", "vibrance", params);
    }
}

// -------------------------------------------------------- hue/saturation --

/// A 360-pixel hue sweep at half saturation, so both directions of every
/// slider have somewhere to go.
fn hue_sweep() -> RgbaImage {
    RgbaImage::from_fn(360, 1, |x, _| {
        let rgb = hsl_to_rgb([f64::from(x), 0.5, 0.5]);
        Rgba([
            (rgb[0] * 255.0).round() as u8,
            (rgb[1] * 255.0).round() as u8,
            (rgb[2] * 255.0).round() as u8,
            255,
        ])
    })
}

/// THE band invariant: the factory handles make adjacent bands sum to
/// exactly 1 at every hue, so the same edit on all six bands is the same
/// picture as one master edit. Asserted through the op at every hue, which
/// is the only way to see the weights at all.
#[test]
fn hue_saturation_bands_sum_to_one_at_every_hue() {
    let dir = TempDir::new().unwrap();
    let src = hue_sweep();
    let all_six = |key: &str, value: &str| {
        let bands = ["reds", "yellows", "greens", "cyans", "blues", "magentas"]
            .map(|name| format!("\"{name}\":{{\"{key}\":{value}}}"))
            .join(",");
        format!("{{\"bands\":{{{bands}}}}}")
    };
    for (key, value) in [("saturation", "0.4"), ("lightness", "-0.3"), ("hue", "30")] {
        let banded = run_bytes(
            &dir,
            "hs-bands",
            &src,
            "hue_saturation",
            &all_six(key, value),
        );
        let master = run_bytes(
            &dir,
            "hs-master",
            &src,
            "hue_saturation",
            &format!("{{\"{key}\":{value}}}"),
        );
        for (i, (a, b)) in banded.iter().zip(&master).enumerate() {
            assert!(
                (i32::from(*a) - i32::from(*b)).abs() <= 1,
                "{key}: hue {} byte {} is {a} through the bands and {b} through the master",
                i / 4,
                i % 4
            );
        }
    }
}

/// One band edits its own hues and nothing else, with the ramp between.
#[test]
fn hue_saturation_band_reaches_only_its_own_hues() {
    let dir = TempDir::new().unwrap();
    let src = hue_sweep();
    let out = run(
        &dir,
        "hs-reds",
        &src,
        "hue_saturation",
        "{\"bands\":{\"reds\":{\"lightness\":-0.5}}}",
    );
    let flat = src.pixels().map(|p| [p[0], p[1], p[2]]).collect::<Vec<_>>();
    for hue in [0usize, 10, 15, 350, 359] {
        assert_ne!(out[hue], flat[hue], "hue {hue} is inside the Reds band");
    }
    for hue in [45usize, 90, 180, 270, 315] {
        assert_eq!(out[hue], flat[hue], "hue {hue} is outside the Reds band");
    }
    // The ramp: at 30 deg the weight is 0.5, so the edit is half of a full
    // one — bracketed by the untouched and the fully edited pixel.
    let full = run(
        &dir,
        "hs-full",
        &src,
        "hue_saturation",
        "{\"lightness\":-0.5}",
    );
    for c in 0..3 {
        let (plain, half, whole) = (
            i32::from(flat[30][c]),
            i32::from(out[30][c]),
            i32::from(full[30][c]),
        );
        assert!(
            half < plain && half > whole,
            "channel {c} at hue 30: {plain} -> {half}, full edit {whole}"
        );
    }
    // A band may be moved and narrowed: centred on 180 with no falloff it
    // is a hard-edged window.
    let out = run(
        &dir,
        "hs-window",
        &src,
        "hue_saturation",
        "{\"bands\":{\"reds\":{\"lightness\":-0.5,\"center\":180,\"inner\":10,\"falloff\":0}}}",
    );
    assert_ne!(out[175], flat[175], "inside the moved window");
    assert_eq!(out[195], flat[195], "outside it, with no ramp at all");
}

#[test]
fn hue_saturation_matches_the_hsl_oracle() {
    let dir = TempDir::new().unwrap();
    let src = opaque_pattern(16, 16);
    for (hue, sat, light) in [
        (0.0, 0.5, 0.0),
        (0.0, -0.5, 0.0),
        (45.0, 0.0, 0.0),
        (-120.0, 0.3, -0.2),
        (180.0, -1.0, 0.4),
    ] {
        let params = format!("{{\"hue\":{hue},\"saturation\":{sat},\"lightness\":{light}}}");
        let out = run(&dir, "hs-oracle", &src, "hue_saturation", &params);
        for (px, got) in src.pixels().zip(&out) {
            let want = hsl_shift(norm([px[0], px[1], px[2]]), hue, sat, light);
            assert_bytes(*got, want, &format!("hue_saturation {params}"));
        }
    }
    // The two curve values the phase plan pins.
    assert!((two_sided(0.4, 0.5) - 0.7).abs() < 1e-12);
    assert!((two_sided(0.4, -0.5) - 0.2).abs() < 1e-12);
}

/// Colorize REPLACES hue and saturation and keeps only the lightness, which
/// is why it is a checkbox and not another slider.
#[test]
fn hue_saturation_colorize_replaces_hue_and_saturation() {
    let dir = TempDir::new().unwrap();
    let src = row_of(&[[200, 40, 40], [40, 200, 40], [128, 128, 128]]);
    let out = run(
        &dir,
        "hs-colorize",
        &src,
        "hue_saturation",
        "{\"colorize\":true,\"colorize_hue\":210,\"colorize_saturation\":0.5}",
    );
    for (px, got) in src.pixels().zip(&out) {
        let hsl = rgb_to_hsl(norm([px[0], px[1], px[2]]));
        assert_bytes(*got, hsl_to_rgb([210.0, 0.5, hsl[2]]), "colorize");
        let out_hsl = rgb_to_hsl(norm(*got));
        assert!(
            (out_hsl[0] - 210.0).abs() < 1.0 && (out_hsl[1] - 0.5).abs() < 0.02,
            "every pixel comes back at the colorize hue and saturation: {out_hsl:?}"
        );
    }
    // Colorize is what tints a NEUTRAL — the plain sliders cannot.
    assert_ne!(out[2], [128, 128, 128], "the grey is tinted by Colorize");
}

/// A pixel with no chroma has no hue to saturate, so the saturation curve
/// leaves it alone however far the slider goes. That fixed point is the
/// model's own rule and the reason Colorize exists.
#[test]
fn hue_saturation_leaves_neutrals_neutral() {
    let dir = TempDir::new().unwrap();
    let src = row_of(&[[0, 0, 0], [64, 64, 64], [128, 128, 128], [255, 255, 255]]);
    let out = run(
        &dir,
        "hs-grey",
        &src,
        "hue_saturation",
        "{\"saturation\":1,\"hue\":90}",
    );
    for (px, got) in src.pixels().zip(&out) {
        assert_eq!(
            *got,
            [px[0], px[1], px[2]],
            "a neutral pixel is not colorized by the saturation slider"
        );
    }
    // Lightness has no such rule: pushing black to white is its whole job.
    let out = run(
        &dir,
        "hs-light",
        &src,
        "hue_saturation",
        "{\"lightness\":1}",
    );
    assert_eq!(out[0], [255, 255, 255], "black to white at lightness +1");

    // A BAND makes the same promise, and it is the one a hue alone cannot
    // keep: `rgb_to_hsl` answers 0 deg for a neutral, so every grey in the
    // document used to sit at the dead centre of Reds and took its edits in
    // full. Hue and Saturation hid it (a zero-chroma pixel is a fixed point
    // of both); LIGHTNESS did not, which made one slider of one range
    // behave unlike all the others. Each band in turn, with all three of
    // its sliders pushed, must be a byte-exact identity on every neutral.
    for band in ["reds", "yellows", "greens", "cyans", "blues", "magentas"] {
        let params = format!(
            "{{\"bands\":{{\"{band}\":{{\"hue\":60,\"saturation\":0.5,\"lightness\":0.5}}}}}}"
        );
        let out = run(&dir, "hs-band-grey", &src, "hue_saturation", &params);
        for (px, got) in src.pixels().zip(&out) {
            assert_eq!(
                *got,
                [px[0], px[1], px[2]],
                "the {band} band must not edit a neutral, which has no hue to be one of"
            );
        }
    }
}

/// One 8-bit level of chroma is not a hue, it is quantization: a pixel with
/// `max - min == 1` lands on an exact multiple of 60 deg, so an ungated band
/// weight PARTITIONED a flat grey — sensor noise in a sky, a grey wall
/// behind a red jacket — among the six ranges at full weight and blotched
/// it. The gate is a ramp in chroma, so this test pins both of its ends
/// through the op: nothing at zero chroma, everything by the floor, and
/// monotone between.
#[test]
fn hue_saturation_bands_ramp_in_with_chroma_instead_of_snapping() {
    let dir = TempDir::new().unwrap();
    let reds = "{\"bands\":{\"reds\":{\"lightness\":0.5}}}";

    // A 64x64 patch of rgb(128 +/- 1): every channel independent, so all six
    // quantized hues occur. FNV-1a over the coordinate keeps it deterministic
    // — a failure reproduces exactly.
    let noise = RgbaImage::from_fn(64, 64, |x, y| {
        let level = |c: u32| {
            let mut h: u64 = 0xcbf2_9ce4_8422_2325;
            for b in [x as u8, (x >> 8) as u8, y as u8, (y >> 8) as u8, c as u8] {
                h = (h ^ u64::from(b)).wrapping_mul(0x100_0000_01b3);
            }
            127 + (h % 3) as u8
        };
        Rgba([level(0), level(1), level(2), 255])
    });
    let flat: Vec<[u8; 3]> = noise.pixels().map(|p| [p[0], p[1], p[2]]).collect();
    let spread = |v: &[[u8; 3]]| {
        let lo = v.iter().flatten().min().copied().unwrap_or(0);
        let hi = v.iter().flatten().max().copied().unwrap_or(0);
        i32::from(hi) - i32::from(lo)
    };
    assert_eq!(spread(&flat), 2, "the fixture is one level of noise");
    let out = run(&dir, "hs-noise", &noise, "hue_saturation", reds);
    // Ungated, the pixels split between "in the band, +64 levels" and
    // "untouched" and the spread went to 65. The gate is continuous, so a
    // residual proportional to the chroma is by design and cannot be zero;
    // what must not happen is that it exceeds the noise it is reading.
    assert!(
        spread(&out) <= spread(&flat) + 2,
        "a Reds Lightness edit spread a near-neutral patch over {} levels",
        spread(&out)
    );
    for (i, (before, after)) in flat.iter().zip(&out).enumerate() {
        for c in 0..3 {
            assert!(
                (i32::from(after[c]) - i32::from(before[c])).abs() <= 2,
                "pixel {i} channel {c} moved from {} to {}",
                before[c],
                after[c]
            );
        }
    }

    // The ramp itself: r = 128 + d, g = b = 128 is hue 0 deg exactly (the
    // Reds centre, band weight 1) at chroma d/255, so the only thing moving
    // across the row is the gate. Green rises with the edit — it is
    // `l - (1 - l)*s`, and both terms push it up — so the row must be
    // non-decreasing, pinned at each end.
    let ramp: Vec<[u8; 3]> = [0u8, 1, 2, 3, 5, 8, 13, 26, 64]
        .iter()
        .map(|d| [128 + d, 128, 128])
        .collect();
    let src = row_of(&ramp);
    let out = run(&dir, "hs-ramp", &src, "hue_saturation", reds);
    let master = run(
        &dir,
        "hs-ramp-m",
        &src,
        "hue_saturation",
        "{\"lightness\":0.5}",
    );
    assert_eq!(out[0], ramp[0], "zero chroma takes none of the band");
    for i in 1..out.len() {
        assert!(
            out[i][1] >= out[i - 1][1],
            "the gate must be monotone in chroma: {:?} then {:?}",
            out[i - 1],
            out[i]
        );
    }
    // 13 levels is past BAND_CHROMA_FLOOR (0.05 = 12.75 levels), so from
    // there on the band edit IS the master edit — the ramp reaches 1 and
    // stays there, and a saturated colour is untouched by the gate.
    for i in 6..out.len() {
        assert_eq!(
            out[i],
            master[i],
            "at chroma {} the Reds band must be the whole edit",
            ramp[i][0] - 128
        );
    }
}

#[test]
fn hue_saturation_defaults_are_a_byte_exact_no_op() {
    let dir = TempDir::new().unwrap();
    let src = opaque_pattern(16, 16);
    for params in [
        "{}",
        "{\"hue\":0,\"saturation\":0,\"lightness\":0}",
        // A band listed but left at rest changes nothing either.
        "{\"bands\":{\"reds\":{}}}",
    ] {
        assert_eq!(
            run_bytes(&dir, "hs-id", &src, "hue_saturation", params),
            *src.as_raw(),
            "{params} must be an exact identity"
        );
    }
}

#[test]
fn hue_saturation_refuses_malformed_parameters() {
    let dir = TempDir::new().unwrap();
    for params in [
        "{\"hue\":181}",
        "{\"hue\":-181}",
        "{\"saturation\":1.5}",
        "{\"bands\":7}",
        "{\"bands\":{\"reds\":\"hot\"}}",
        "{\"bands\":{\"reds\":{\"center\":360}}}",
        "{\"bands\":{\"reds\":{\"inner\":181}}}",
        "{\"bands\":{\"reds\":{\"falloff\":-1}}}",
        "{\"colorize\":\"yes\"}",
        "{\"colorize_hue\":360}",
        "{\"colorize_saturation\":-0.1}",
    ] {
        refuses(&dir, "hs-bad", "hue_saturation", params);
    }
}

// --------------------------------------------------------- color balance --

/// The masks sum to exactly 1 at every level, so a full push on all three
/// tones is a uniform 0.7 lift — asserted through the op, at every 8-bit
/// code, which is the only way the masks are observable.
#[test]
fn color_balance_masks_sum_to_one_at_every_level() {
    let dir = TempDir::new().unwrap();
    let ramp = RgbaImage::from_fn(256, 1, |x, _| {
        let v = x as u8;
        Rgba([v, v, v, 255])
    });
    let all_three = "{\"shadows\":{\"cyan_red\":1},\"midtones\":{\"cyan_red\":1},\
        \"highlights\":{\"cyan_red\":1},\"preserve_luminosity\":false}";
    let out = run(&dir, "cb-sum", &ramp, "color_balance", all_three);
    for (v, got) in out.iter().enumerate() {
        let want = ((f64::from(v as u8) / 255.0) + 0.7).clamp(0.0, 1.0) * 255.0;
        assert!(
            (f64::from(got[0]) - want).abs() <= 1.0,
            "level {v}: a full push on all three tones lifted red to {} not {want}",
            got[0]
        );
        assert_eq!(got[1], v as u8, "green untouched");
        assert_eq!(got[2], v as u8, "blue untouched");
    }
    // The crossovers: at v = 0.333 the shadow and midtone masks are both
    // 0.5, at v = 0.667 the midtone and highlight masks are.
    for (level, low, high) in [
        (85u8, "shadows", "midtones"),
        (170, "midtones", "highlights"),
    ] {
        let one = run(
            &dir,
            "cb-cross-a",
            &row_of(&[[level, level, level]]),
            "color_balance",
            &format!("{{\"{low}\":{{\"cyan_red\":1}},\"preserve_luminosity\":false}}"),
        );
        let other = run(
            &dir,
            "cb-cross-b",
            &row_of(&[[level, level, level]]),
            "color_balance",
            &format!("{{\"{high}\":{{\"cyan_red\":1}},\"preserve_luminosity\":false}}"),
        );
        assert!(
            (i32::from(one[0][0]) - i32::from(other[0][0])).abs() <= 1,
            "at level {level} the {low} and {high} masks must cross: {:?} vs {:?}",
            one[0],
            other[0]
        );
    }
}

/// The worked example, both ways round the Preserve Luminosity checkbox.
/// The point of the assertion is the LUMA: the checkbox exists to hold it,
/// and the Rec. 709 rescale holds it exactly where the HSL substitution
/// this build rejected lost twelve levels of it.
#[test]
fn color_balance_preserve_luminosity_holds_the_luma_exactly() {
    let dir = TempDir::new().unwrap();
    let grey = row_of(&[[128, 128, 128]]);
    let midtones = "{\"midtones\":{\"cyan_red\":0.2}";

    let off = run(
        &dir,
        "cb-off",
        &grey,
        "color_balance",
        &format!("{midtones},\"preserve_luminosity\":false}}"),
    );
    let want_off = color_balance_oracle(
        norm([128, 128, 128]),
        [0.0; 3],
        [0.2, 0.0, 0.0],
        [0.0; 3],
        false,
    );
    assert!(
        (want_off[0] * 255.0 - 163.7).abs() < 0.05,
        "the oracle's preserve-off red is {}",
        want_off[0] * 255.0
    );
    assert_bytes(off[0], want_off, "color_balance preserve off");

    let on = run(
        &dir,
        "cb-on",
        &grey,
        "color_balance",
        &format!("{midtones}}}"),
    );
    let want_on = color_balance_oracle(
        norm([128, 128, 128]),
        [0.0; 3],
        [0.2, 0.0, 0.0],
        [0.0; 3],
        true,
    );
    for (got, want) in want_on.iter().zip([154.5, 120.8, 120.8]) {
        assert!(
            (got * 255.0 - want).abs() < 0.1,
            "the oracle's preserve-on triple is {:?}",
            want_on.map(|v| v * 255.0)
        );
    }
    assert_bytes(on[0], want_on, "color_balance preserve on");
    assert!(
        (luma(want_on) * 255.0 - 128.0).abs() < 0.01,
        "the rescaled luma is {}",
        luma(want_on) * 255.0
    );
    assert!(
        (luma(norm(on[0])) * 255.0 - 128.0).abs() <= 1.0,
        "and it survives the 8-bit round trip: {:?}",
        on[0]
    );
    // Preserve ON is DARKER in red and lighter overall than preserve OFF is
    // in green and blue — the rescale moves every channel, not just one.
    assert!(on[0][0] < off[0][0] && on[0][1] < off[0][1]);
}

#[test]
fn color_balance_matches_the_gimp_oracle_over_a_pattern() {
    let dir = TempDir::new().unwrap();
    let src = opaque_pattern(16, 16);
    let cases = [
        ([0.5, 0.0, -0.3], [0.0; 3], [0.0; 3], false),
        ([0.0; 3], [0.2, -0.4, 0.1], [0.0; 3], false),
        ([0.0; 3], [0.0; 3], [-0.6, 0.3, 0.9], true),
        ([0.3, -0.2, 0.1], [-0.1, 0.4, -0.5], [0.2, 0.2, 0.2], true),
    ];
    for (shadows, midtones, highlights, preserve) in cases {
        let params = format!(
            "{{\"shadows\":{{\"cyan_red\":{},\"magenta_green\":{},\"yellow_blue\":{}}},\
              \"midtones\":{{\"cyan_red\":{},\"magenta_green\":{},\"yellow_blue\":{}}},\
              \"highlights\":{{\"cyan_red\":{},\"magenta_green\":{},\"yellow_blue\":{}}},\
              \"preserve_luminosity\":{preserve}}}",
            shadows[0],
            shadows[1],
            shadows[2],
            midtones[0],
            midtones[1],
            midtones[2],
            highlights[0],
            highlights[1],
            highlights[2],
        );
        let out = run(&dir, "cb-oracle", &src, "color_balance", &params);
        for (px, got) in src.pixels().zip(&out) {
            let want = color_balance_oracle(
                norm([px[0], px[1], px[2]]),
                shadows,
                midtones,
                highlights,
                preserve,
            );
            assert_bytes(*got, want, "color_balance");
        }
    }
}

#[test]
fn color_balance_defaults_are_a_byte_exact_no_op() {
    let dir = TempDir::new().unwrap();
    let src = opaque_pattern(16, 16);
    // Preserve Luminosity defaults ON, and must still be an exact identity
    // when nothing moved: the rescale factor is 1.
    for params in ["{}", "{\"midtones\":{}}", "{\"preserve_luminosity\":true}"] {
        assert_eq!(
            run_bytes(&dir, "cb-id", &src, "color_balance", params),
            *src.as_raw(),
            "{params} must be an exact identity"
        );
    }
}

#[test]
fn color_balance_refuses_malformed_parameters() {
    let dir = TempDir::new().unwrap();
    for params in [
        "{\"shadows\":{\"cyan_red\":1.5}}",
        "{\"midtones\":{\"magenta_green\":-2}}",
        "{\"highlights\":[1,2,3]}",
        "{\"shadows\":{\"cyan_red\":\"warm\"}}",
        "{\"preserve_luminosity\":1}",
    ] {
        refuses(&dir, "cb-bad", "color_balance", params);
    }
}
