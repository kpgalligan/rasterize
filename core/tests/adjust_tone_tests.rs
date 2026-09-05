//! The three tone ops of `rz_image_adjust_op`: `exposure`,
//! `shadows_highlights` and `white_balance`, exercised through the C ABI.
//!
//! Every expected value comes from an ORACLE WRITTEN HERE from the published
//! formula — Adobe's linear-light Exposure, the blurred-luminance
//! Shadows/Highlights shape, Bradford adaptation with the CIE daylight and
//! Planckian locus fits — never from the core's own output. Where a
//! published constant exists (Lindbloom's Bradford D65 -> D50 matrix, the
//! D50/D65 chromaticities) the oracle is checked against it first, so a
//! wrong oracle fails before it can bless a wrong implementation.

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

/// A 256x1 grey ramp: every 8-bit code exactly once.
fn grey_ramp() -> RgbaImage {
    RgbaImage::from_fn(256, 1, |x, _| {
        let v = x as u8;
        Rgba([v, v, v, 255])
    })
}

/// The output bytes of `op` on a one-row image, as RGB triples.
fn run_row(dir: &TempDir, tag: &str, src: &RgbaImage, op: &str, params: &str) -> Vec<[u8; 3]> {
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

// ------------------------------------------------------- the oracle ------
//
// Written from the published formulas, in f64, deliberately the long way.

fn s2l(v: f64) -> f64 {
    if v <= 0.04045 {
        v / 12.92
    } else {
        ((v + 0.055) / 1.055).powf(2.4)
    }
}

fn l2s(u: f64) -> f64 {
    let u = u.clamp(0.0, 1.0);
    if u <= 0.0031308 {
        12.92 * u
    } else {
        1.055 * u.powf(1.0 / 2.4) - 0.055
    }
}

fn luma(rgb: [f64; 3]) -> f64 {
    0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2]
}

/// Adobe's Exposure: linearize, gain in stops, linear pedestal, then the
/// POWER gamma (so gamma > 1 darkens), then re-encode.
fn exposure_oracle(v: f64, stops: f64, offset: f64, gamma: f64) -> f64 {
    let u = (s2l(v) * 2f64.powf(stops) + offset).max(0.0);
    l2s(u.powf(gamma))
}

/// Shadows/Highlights on one pixel with a KNOWN neighbourhood estimate `b`.
#[allow(clippy::too_many_arguments)]
fn shadows_oracle(
    rgb: [f64; 3],
    b: f64,
    a_s: f64,
    t_s: f64,
    a_h: f64,
    t_h: f64,
    color: f64,
    midtone: f64,
) -> [f64; 3] {
    let l = luma(rgb);
    let w_s = (1.0 - b / t_s).clamp(0.0, 1.0).powi(2);
    let w_h = (1.0 - (1.0 - b) / t_h).clamp(0.0, 1.0).powi(2);
    let e = (1.0 + a_h * w_h) / (1.0 + a_s * w_s);
    let mut lifted = if l > 0.0 { l.powf(e) } else { 0.0 };
    lifted += midtone * (3.0 * lifted * lifted - 2.0 * lifted.powi(3) - lifted);
    let k = if l > 0.0 { lifted / l } else { 1.0 };
    let moved = (a_s * w_s + a_h * w_h).clamp(0.0, 1.0);
    let boost = 1.0 + color * moved;
    let mut out = [0.0f64; 3];
    for (slot, c) in out.iter_mut().zip(rgb) {
        *slot = (lifted + (c * k - lifted) * boost).clamp(0.0, 1.0);
    }
    out
}

const M_A: [[f64; 3]; 3] = [
    [0.8951, 0.2664, -0.1614],
    [-0.7502, 1.7135, 0.0367],
    [0.0389, -0.0685, 1.0296],
];
const M_A_INV: [[f64; 3]; 3] = [
    [0.9869929, -0.1470543, 0.1599627],
    [0.4323053, 0.5183603, 0.0492912],
    [-0.0085287, 0.0400428, 0.9684867],
];
const D50_XYZ: [f64; 3] = [0.96422, 1.0, 0.82521];
const D65_XYZ: [f64; 3] = [0.95047, 1.0, 1.08883];
const SRGB_TO_XYZ: [[f64; 3]; 3] = [
    [0.4124564, 0.3575761, 0.1804375],
    [0.2126729, 0.7151522, 0.0721750],
    [0.0193339, 0.1191920, 0.9503041],
];
const XYZ_TO_SRGB: [[f64; 3]; 3] = [
    [3.2404542, -1.5371385, -0.4985314],
    [-0.9692660, 1.8760108, 0.0415560],
    [0.0556434, -0.2040259, 1.0572252],
];

fn mat_vec(m: [[f64; 3]; 3], v: [f64; 3]) -> [f64; 3] {
    m.map(|row| row[0] * v[0] + row[1] * v[1] + row[2] * v[2])
}

fn mat_mul(a: [[f64; 3]; 3], b: [[f64; 3]; 3]) -> [[f64; 3]; 3] {
    let mut out = [[0.0f64; 3]; 3];
    for (i, row) in out.iter_mut().enumerate() {
        for (j, entry) in row.iter_mut().enumerate() {
            *entry = (0..3).map(|k| a[i][k] * b[k][j]).sum();
        }
    }
    out
}

/// Bradford adaptation from one white to another, both XYZ.
fn bradford(source: [f64; 3], dest: [f64; 3]) -> [[f64; 3]; 3] {
    let cs = mat_vec(M_A, source);
    let cd = mat_vec(M_A, dest);
    let mut diag = [[0.0f64; 3]; 3];
    for i in 0..3 {
        diag[i][i] = cd[i] / cs[i];
    }
    mat_mul(M_A_INV, mat_mul(diag, M_A))
}

/// CCT to chromaticity: the CIE D-series daylight cubics at and above
/// 4000 K, Kim et al.'s Planckian cubics below it.
fn locus_xy(t: f64) -> (f64, f64) {
    if t >= 4000.0 {
        let x = if t <= 7000.0 {
            -4.6070e9 / t.powi(3) + 2.9678e6 / (t * t) + 0.09911e3 / t + 0.244063
        } else {
            -2.0064e9 / t.powi(3) + 1.9018e6 / (t * t) + 0.24748e3 / t + 0.237040
        };
        (x, -3.0 * x * x + 2.87 * x - 0.275)
    } else {
        let x = -0.2661239e9 / t.powi(3) - 0.2343589e6 / (t * t) + 0.8776956e3 / t + 0.179910;
        let y = if t >= 2222.0 {
            -0.9549476 * x.powi(3) - 1.37418593 * x * x + 2.09137015 * x - 0.16748867
        } else {
            -1.1063814 * x.powi(3) - 1.34811020 * x * x + 2.18555832 * x - 0.20219683
        };
        (x, y)
    }
}

/// CIE xy to the CIE 1960 UCS uv.
fn xy_to_uv(x: f64, y: f64) -> (f64, f64) {
    let den = -2.0 * x + 12.0 * y + 3.0;
    (4.0 * x / den, 6.0 * y / den)
}

/// The unit locus tangent at `t` in uv, toward rising temperature. Taken by
/// a one-sided difference held inside `locus_xy`'s own branch, because the
/// Planckian and daylight fits do not meet at their 4000 K seam.
fn locus_tangent_uv(t: f64) -> (f64, f64) {
    let step = (t * 1e-3).max(0.5);
    let hi_bound = if t < 2222.0 {
        2222.0
    } else if t < 4000.0 {
        4000.0
    } else if t <= 7000.0 {
        7000.0
    } else {
        f64::MAX
    };
    let (lo, hi) = if hi_bound - t >= step {
        (t, t + step)
    } else {
        (t - step, t)
    };
    let (u0, v0) = xy_to_uv(locus_xy(lo).0, locus_xy(lo).1);
    let (u1, v1) = xy_to_uv(locus_xy(hi).0, locus_xy(hi).1);
    let (du, dv) = (u1 - u0, v1 - v0);
    let len = du.hypot(dv);
    (du / len, dv / len)
}

/// The illuminant a (temperature, tint) pair describes, as XYZ. A POSITIVE
/// tint is a GREENER source white, stepped `tint/3000` along the ISOTHERM —
/// the locus normal, whose green side is `(dv, -du)` for a tangent pointing
/// at rising temperature — which is why removing it pushes the picture
/// toward magenta without moving the white's CCT.
fn source_white(temperature: f64, tint: f64) -> [f64; 3] {
    let (u0, v0) = xy_to_uv(locus_xy(temperature).0, locus_xy(temperature).1);
    let (du, dv) = locus_tangent_uv(temperature);
    let k = tint / 3000.0;
    let u = u0 + k * dv;
    let v = v0 - k * du;
    let den2 = 2.0 * u - 8.0 * v + 4.0;
    let (x2, y2) = (3.0 * u / den2, 2.0 * v / den2);
    [x2 / y2, 1.0, (1.0 - x2 - y2) / y2]
}

/// White balance on one encoded triple: adapt the stated illuminant to D65.
fn white_balance_oracle(rgb: [f64; 3], temperature: f64, tint: f64) -> [f64; 3] {
    if temperature == 6504.0 && tint == 0.0 {
        return rgb;
    }
    let m = mat_mul(
        XYZ_TO_SRGB,
        mat_mul(
            bradford(source_white(temperature, tint), D65_XYZ),
            SRGB_TO_XYZ,
        ),
    );
    let lin = rgb.map(s2l);
    mat_vec(m, lin).map(l2s)
}

// ------------------------------------------------- the oracle's own check --

#[test]
fn the_oracle_reproduces_the_published_constants() {
    // Bradford D65 -> D50 is Lindbloom's published matrix to 7 decimals.
    let published = [
        [1.0478112, 0.0228866, -0.0501270],
        [0.0295424, 0.9904844, -0.0170491],
        [-0.0092345, 0.0150436, 0.7521316],
    ];
    // The published table carries seven decimals and its last digit is
    // truncated rather than rounded (1.04781127... is printed 1.0478112),
    // so agreement is asserted at 5e-7 — two orders of magnitude below one
    // part in 10 000, and far below a visible 8-bit step.
    let computed = bradford(D65_XYZ, D50_XYZ);
    for (r, (got, want)) in computed.iter().zip(published).enumerate() {
        for (c, (a, b)) in got.iter().zip(want).enumerate() {
            assert!(
                (a - b).abs() < 5e-7,
                "bradford[{r}][{c}] = {a}, published {b}"
            );
        }
    }
    // The locus fit lands on the published D50 and D65 chromaticities to
    // within its own 1e-4 accuracy.
    for (t, want) in [(5000.0, (0.34574, 0.35867)), (6504.0, (0.31271, 0.32912))] {
        let (x, y) = locus_xy(t);
        assert!(
            (x - want.0).abs() < 1e-4 && (y - want.1).abs() < 1e-4,
            "{t} K -> ({x}, {y}), expected {want:?}"
        );
    }
    // A magenta-pushing tint is a GREENER source white: larger v.
    let plus = source_white(6504.0, 50.0);
    let minus = source_white(6504.0, -50.0);
    assert!(
        plus[2] < minus[2],
        "a greener source white has less Z than a magenta one"
    );
    // And the step is along the ISOTHERM, so the white it lands on keeps the
    // CCT it started from: the nearest locus point to the tinted white is
    // still 6504 K, to within the 5 K resolution of this scan. (Before the
    // isotherm fix, a pure +v step of the same size landed on a white whose
    // nearest locus point was about 5360 K.)
    for tint in [-150.0, -50.0, 50.0, 150.0] {
        let white = source_white(6504.0, tint);
        let sum = white[0] + white[1] + white[2];
        let (u, v) = xy_to_uv(white[0] / sum, white[1] / sum);
        let mut best = (f64::MAX, 0.0f64);
        let mut t = 1700.0;
        while t <= 25000.0 {
            let (lu, lv) = xy_to_uv(locus_xy(t).0, locus_xy(t).1);
            let d = (lu - u).powi(2) + (lv - v).powi(2);
            if d < best.0 {
                best = (d, t);
            }
            t += 5.0;
        }
        assert!(
            (best.1 - 6504.0).abs() <= 10.0,
            "tint {tint} moved the implied CCT to {} K",
            best.1
        );
    }
}

// ------------------------------------------------------------- exposure --

#[test]
fn exposure_defaults_are_a_byte_exact_no_op() {
    let dir = TempDir::new().unwrap();
    let ramp = grey_ramp();
    for params in ["{}", "{\"exposure\":0,\"offset\":0,\"gamma\":1}"] {
        let out = run_row(&dir, "exp-id", &ramp, "exposure", params);
        for (v, px) in out.iter().enumerate() {
            assert_eq!(
                *px, [v as u8; 3],
                "identity exposure must round-trip code {v} exactly ({params})"
            );
        }
    }
}

#[test]
fn exposure_matches_the_linear_light_oracle() {
    let dir = TempDir::new().unwrap();
    let ramp = grey_ramp();
    // The gamma convention is Photoshop's Exposure one — `out = u^gamma`,
    // so gamma > 1 DARKENS. This is the exact INVERSE of `levels`' midtone
    // gamma; the two ops in this crate deliberately disagree on the word.
    let cases = [
        (1.0f64, 0.0f64, 1.0f64),
        (0.0, 0.05, 1.0),
        (0.0, 0.0, 2.0),
        (1.0, 0.05, 1.2),
        (-1.5, -0.1, 0.6),
        (-20.0, 0.0, 1.0),
        (20.0, 0.0, 9.99),
    ];
    for (stops, offset, gamma) in cases {
        let params = format!("{{\"exposure\":{stops},\"offset\":{offset},\"gamma\":{gamma}}}");
        let out = run_row(&dir, "exp", &ramp, "exposure", &params);
        for (v, px) in out.iter().enumerate() {
            let want = exposure_oracle(v as f64 / 255.0, stops, offset, gamma);
            let want_byte = (want.clamp(0.0, 1.0) * 255.0).round();
            for channel in px {
                assert!(
                    (f64::from(*channel) - want_byte).abs() <= 1.0,
                    "exposure({stops}, {offset}, {gamma}) at {v}: {channel} vs {want_byte}"
                );
            }
        }
    }

    // The two acceptance numbers the phase plan pins, recomputed here from
    // the same oracle so a reader can see where they come from.
    let at_gamma_two = exposure_oracle(128.0 / 255.0, 0.0, 0.0, 2.0) * 255.0;
    assert!(
        (at_gamma_two - 60.95).abs() < 0.05,
        "128 at gamma 2 is {at_gamma_two}, expected ~60.95 (byte 61)"
    );
    let trio = exposure_oracle(128.0 / 255.0, 1.0, 0.05, 1.2) * 255.0;
    assert!(
        (trio - 172.69).abs() < 0.05,
        "the worked trio is {trio}, expected ~172.69 (byte 173)"
    );
}

#[test]
fn exposure_refuses_out_of_range_parameters() {
    let dir = TempDir::new().unwrap();
    let img = open_pattern(&dir, "exp-bad.png", &grey_ramp());
    for params in [
        "{\"exposure\":21}",
        "{\"exposure\":-21}",
        "{\"offset\":0.51}",
        "{\"gamma\":0}",
        "{\"gamma\":10}",
        "{\"gamma\":\"steep\"}",
    ] {
        let c_op = CString::new("exposure").unwrap();
        let c_params = CString::new(params).unwrap();
        let mut err: *mut c_char = ptr::null_mut();
        let out = unsafe { rz_image_adjust_op(img, c_op.as_ptr(), c_params.as_ptr(), &mut err) };
        assert!(out.is_null(), "{params} must be refused");
        assert!(
            take_err_string(err).contains("exposure"),
            "{params}: the message must name the op"
        );
    }
    free(img);
}

// -------------------------------------------------- shadows / highlights --

/// A flat opaque grey field, so the guide equals the pixel's own luma
/// everywhere except within a blur radius of the border — where the
/// alpha-weighted ratio normalizes the blur's edge handling away, so it is
/// exact there too.
fn flat(v: u8, w: u32, h: u32) -> RgbaImage {
    RgbaImage::from_pixel(w, h, Rgba([v, v, v, 255]))
}

#[test]
fn shadows_highlights_defaults_lift_a_flat_field_like_the_oracle() {
    let dir = TempDir::new().unwrap();
    for level in [16u8, 32, 64, 96, 128, 160, 192, 224] {
        let img = open_pattern(&dir, &format!("sh-{level}.png"), &flat(level, 48, 48));
        let out = adjust(img, "shadows_highlights", "{}");
        let got = pixel_at(out, 24, 24);
        let v = f64::from(level) / 255.0;
        let want = shadows_oracle([v; 3], v, 0.35, 0.5, 0.0, 0.5, 0.2, 0.0);
        for c in 0..3 {
            let want_byte = want[c] * 255.0;
            assert!(
                (f64::from(got[c]) - want_byte).abs() <= 1.0,
                "level {level} channel {c}: {} vs {want_byte}",
                got[c]
            );
        }
        assert_eq!(got[3], 255, "alpha untouched");
        unsafe { rz_image_free(out) };
        free(img);
    }
}

#[test]
fn shadows_highlights_reads_the_neighbourhood_not_the_pixel() {
    // A dark square inside a bright field. Its own luma says "shadow"; its
    // NEIGHBOURHOOD says "highlight", and a correct implementation leaves it
    // alone. A plain curve would lift it.
    let dir = TempDir::new().unwrap();
    let dark = (0.20f64 * 255.0).round() as u8;
    let bright = (0.85f64 * 255.0).round() as u8;
    let mut field = flat(bright, 128, 128);
    for y in 60..68 {
        for x in 60..68 {
            field.put_pixel(x, y, Rgba([dark, dark, dark, 255]));
        }
    }
    let img = open_pattern(&dir, "sh-local.png", &field);
    let in_context = adjust(img, "shadows_highlights", "{}");
    let context_px = pixel_at(in_context, 64, 64);

    // The same pixel in a field of its own colour: now the neighbourhood
    // agrees with it and the lift applies in full.
    let alone = open_pattern(&dir, "sh-alone.png", &flat(dark, 128, 128));
    let lifted = adjust(alone, "shadows_highlights", "{}");
    let alone_px = pixel_at(lifted, 64, 64);

    let v = f64::from(dark) / 255.0;
    let unlifted = shadows_oracle([v; 3], 0.85, 0.35, 0.5, 0.0, 0.5, 0.2, 0.0);
    let fully = shadows_oracle([v; 3], v, 0.35, 0.5, 0.0, 0.5, 0.2, 0.0);
    assert!(
        (f64::from(context_px[0]) - unlifted[0] * 255.0).abs() <= 2.0,
        "a dark pixel in a bright field must stay dark: {} vs {}",
        context_px[0],
        unlifted[0] * 255.0
    );
    assert!(
        (f64::from(alone_px[0]) - fully[0] * 255.0).abs() <= 1.0,
        "the same pixel in its own field lifts: {} vs {}",
        alone_px[0],
        fully[0] * 255.0
    );
    assert!(
        alone_px[0] > context_px[0] + 5,
        "the two readings must differ visibly ({} vs {})",
        alone_px[0],
        context_px[0]
    );
    unsafe { rz_image_free(in_context) };
    unsafe { rz_image_free(lifted) };
    free(img);
    free(alone);
}

#[test]
fn shadows_highlights_guide_ignores_transparent_neighbours() {
    // Left half fully transparent, right half a uniform opaque grey. Because
    // the guide is the ratio blur(luma*alpha) / blur(alpha), the transparent
    // half contributes NOTHING and every opaque pixel — including the ones
    // right against the boundary — sees exactly the flat-field estimate. A
    // plain blur of the luma would drag the estimate toward black there and
    // halo the cut-out.
    let dir = TempDir::new().unwrap();
    let level = (0.45f64 * 255.0).round() as u8;
    let field = RgbaImage::from_fn(64, 64, |x, _| {
        if x < 32 {
            Rgba([0, 0, 0, 0])
        } else {
            Rgba([level, level, level, 255])
        }
    });
    let img = open_pattern(&dir, "sh-alpha.png", &field);
    let out = adjust(img, "shadows_highlights", "{}");
    let v = f64::from(level) / 255.0;
    let want = shadows_oracle([v; 3], v, 0.35, 0.5, 0.0, 0.5, 0.2, 0.0)[0] * 255.0;
    for x in 32..64u32 {
        for y in [0u32, 31, 63] {
            let px = pixel_at(out, x, y);
            assert!(
                (f64::from(px[0]) - want).abs() <= 1.0,
                "({x},{y}): {} vs the flat-neighbourhood answer {want}",
                px[0]
            );
            assert_eq!(px[3], 255);
        }
    }
    for x in 0..32u32 {
        assert_eq!(
            pixel_at(out, x, 32),
            [0, 0, 0, 0],
            "a transparent pixel is left entirely alone"
        );
    }
    unsafe { rz_image_free(out) };
    free(img);
}

#[test]
fn shadows_highlights_saturation_anchors_on_the_new_luma() {
    // The Color step happens AFTER the lift and BEFORE the only clamp, so
    // the saturation is anchored on the pixel's NEW luma. Pushing a deep,
    // saturated shadow all the way up must therefore come back with the
    // luma the tone step asked for, not with a grey the clamp invented.
    let dir = TempDir::new().unwrap();
    let field = RgbaImage::from_pixel(48, 48, Rgba([40, 8, 4, 255]));
    let img = open_pattern(&dir, "sh-sat.png", &field);
    let params = "{\"shadows\":{\"amount\":1.0,\"tone\":1.0},\"color\":0.5}";
    let out = adjust(img, "shadows_highlights", params);
    let got = pixel_at(out, 24, 24);
    let rgb = [40.0 / 255.0, 8.0 / 255.0, 4.0 / 255.0];
    let want = shadows_oracle(rgb, luma(rgb), 1.0, 1.0, 0.0, 0.5, 0.5, 0.0);
    for c in 0..3 {
        assert!(
            (f64::from(got[c]) - want[c] * 255.0).abs() <= 1.0,
            "channel {c}: {} vs {}",
            got[c],
            want[c] * 255.0
        );
    }
    unsafe { rz_image_free(out) };
    free(img);
}

#[test]
fn shadows_highlights_zero_amounts_are_an_exact_identity() {
    // `color` defaults to 0.2, so without the "how much did this pixel
    // move" gate on the Color step an all-zero-amount pass would still
    // resaturate the whole image.
    let dir = TempDir::new().unwrap();
    let pattern = opaque_pattern(32, 24);
    let out = run_row(
        &dir,
        "sh-zero",
        &pattern,
        "shadows_highlights",
        "{\"shadows\":{\"amount\":0},\"highlights\":{\"amount\":0}}",
    );
    for (i, px) in pattern.pixels().enumerate() {
        assert_eq!(
            out[i],
            [px[0], px[1], px[2]],
            "pixel {i} must be untouched at zero amounts"
        );
    }
}

#[test]
fn shadows_highlights_without_amounts_never_reads_the_guide() {
    // With both amounts zero the guide cannot reach the output: `b` enters
    // only through `w_s` and `w_h`, and both are multiplied by their band's
    // amount in the exponent and in `moved`. So the radius — the one
    // parameter that decides what the guide SAYS — must make no difference
    // whatsoever, which is what lets the op skip building the plane. Three
    // canvas-sized buffers and two blurs per composite ride on this.
    let dir = TempDir::new().unwrap();
    let pattern = opaque_pattern(48, 32);
    let mut previous: Option<Vec<[u8; 3]>> = None;
    for radius in [0.0f64, 4.0, 30.0, 500.0, 1000.0] {
        let params = format!(
            "{{\"shadows\":{{\"amount\":0}},\"highlights\":{{\"amount\":0}},\
              \"midtone_contrast\":0.4,\"color\":0.7,\"radius\":{radius}}}"
        );
        let out = run_row(&dir, "sh-noguide", &pattern, "shadows_highlights", &params);
        if let Some(previous) = &previous {
            assert_eq!(
                &out, previous,
                "radius {radius} changed an amount-free Shadows/Highlights"
            );
        }
        previous = Some(out);
    }
}

#[test]
fn shadows_highlights_guide_survives_being_held_at_a_reduced_resolution() {
    // The guide is a blur at sigma = radius/2, so it is held on a grid of
    // `style_render::downsample_factor(sigma)`-sized cells and read back by
    // interpolation. Two properties have to survive that, and both are
    // checked at a radius well past the factor's last step (8 above sigma
    // 12): a flat opaque field still reads as its own luma everywhere,
    // border included, and the alpha-weighted RATIO still ignores a
    // transparent surround exactly rather than approximately.
    let dir = TempDir::new().unwrap();
    let level = (0.30f64 * 255.0).round() as u8;
    for radius in [30.0f64, 120.0, 600.0] {
        let params = format!("{{\"radius\":{radius}}}");
        let img = open_pattern(&dir, "sh-grid.png", &flat(level, 100, 70));
        let out = adjust(img, "shadows_highlights", &params);
        let v = f64::from(level) / 255.0;
        let want = shadows_oracle([v; 3], v, 0.35, 0.5, 0.0, 0.5, 0.2, 0.0)[0] * 255.0;
        for (x, y) in [(0u32, 0u32), (50, 35), (99, 69), (99, 0), (0, 69)] {
            let px = pixel_at(out, x, y);
            assert!(
                (f64::from(px[0]) - want).abs() <= 1.0,
                "radius {radius} at ({x},{y}): {} vs {want}",
                px[0]
            );
        }
        unsafe { rz_image_free(out) };
        free(img);

        // A cut-out: the left half is transparent. Every opaque pixel must
        // still see the flat-field estimate, because the ratio
        // blur(luma*alpha)/blur(alpha) is scale-free in the coverage —
        // including inside a cell that straddles the boundary.
        let field = RgbaImage::from_fn(100, 70, |x, _| {
            if x < 50 {
                Rgba([0, 0, 0, 0])
            } else {
                Rgba([level, level, level, 255])
            }
        });
        let img = open_pattern(&dir, "sh-grid-alpha.png", &field);
        let out = adjust(img, "shadows_highlights", &params);
        for x in [50u32, 51, 60, 99] {
            let px = pixel_at(out, x, 35);
            assert!(
                (f64::from(px[0]) - want).abs() <= 1.0,
                "radius {radius} at ({x},35) beside a cut-out: {} vs {want}",
                px[0]
            );
        }
        unsafe { rz_image_free(out) };
        free(img);
    }
}

#[test]
fn shadows_highlights_midtone_contrast_is_monotone_and_pins_the_ends() {
    let dir = TempDir::new().unwrap();
    let ramp = grey_ramp();
    for m in [-1.0f64, -0.5, 0.5, 1.0] {
        let params = format!(
            "{{\"shadows\":{{\"amount\":0}},\"highlights\":{{\"amount\":0}},\
              \"midtone_contrast\":{m}}}"
        );
        let out = run_row(&dir, "sh-mid", &ramp, "shadows_highlights", &params);
        assert_eq!(out[0], [0, 0, 0], "black stays black at m = {m}");
        assert_eq!(out[255], [255, 255, 255], "white stays white at m = {m}");
        for v in 1..256 {
            assert!(
                out[v][0] >= out[v - 1][0],
                "m = {m}: the curve inverted at {v} ({} < {})",
                out[v][0],
                out[v - 1][0]
            );
        }
        for v in [64usize, 128, 192] {
            let l = v as f64 / 255.0;
            let want = shadows_oracle([l; 3], l, 0.0, 0.5, 0.0, 0.5, 0.2, m)[0] * 255.0;
            assert!(
                (f64::from(out[v][0]) - want).abs() <= 1.0,
                "m = {m} at {v}: {} vs {want}",
                out[v][0]
            );
        }
    }
}

#[test]
fn shadows_highlights_refuses_out_of_range_parameters() {
    let dir = TempDir::new().unwrap();
    let img = open_pattern(&dir, "sh-bad.png", &flat(128, 8, 8));
    for params in [
        "{\"shadows\":{\"amount\":1.5}}",
        "{\"shadows\":{\"tone\":0}}",
        "{\"highlights\":7}",
        "{\"radius\":-1}",
        "{\"radius\":1001}",
        "{\"color\":2}",
        "{\"midtone_contrast\":-1.5}",
    ] {
        let c_op = CString::new("shadows_highlights").unwrap();
        let c_params = CString::new(params).unwrap();
        let mut err: *mut c_char = ptr::null_mut();
        let out = unsafe { rz_image_adjust_op(img, c_op.as_ptr(), c_params.as_ptr(), &mut err) };
        assert!(out.is_null(), "{params} must be refused");
        assert!(!take_err_string(err).is_empty());
    }
    free(img);
}

// -------------------------------------------------------- white balance --

#[test]
fn white_balance_default_is_the_exact_identity() {
    // The CCT fit is only 1e-4 accurate, so the default is SNAPPED to the
    // identity rather than left as whatever the fit produces.
    let dir = TempDir::new().unwrap();
    let pattern = opaque_pattern(32, 24);
    for params in ["{}", "{\"temperature\":6504,\"tint\":0}"] {
        let out = run_row(&dir, "wb-id", &pattern, "white_balance", params);
        for (i, px) in pattern.pixels().enumerate() {
            assert_eq!(
                out[i],
                [px[0], px[1], px[2]],
                "pixel {i} must be byte-identical at the default ({params})"
            );
        }
    }
}

#[test]
fn white_balance_matches_the_bradford_oracle() {
    let dir = TempDir::new().unwrap();
    let src = RgbaImage::from_fn(6, 1, |x, _| {
        [
            Rgba([128, 128, 128, 255]),
            Rgba([200, 150, 120, 255]),
            Rgba([20, 40, 90, 255]),
            Rgba([255, 255, 255, 255]),
            Rgba([0, 0, 0, 255]),
            Rgba([250, 10, 60, 255]),
        ][x as usize]
    });
    for (temperature, tint) in [
        (9000.0f64, 0.0f64),
        (5000.0, 0.0),
        (2856.0, 0.0),
        (25000.0, 0.0),
        (1667.0, 0.0),
        (6504.0, 50.0),
        (6504.0, -50.0),
        (4500.0, 120.0),
    ] {
        let params = format!("{{\"temperature\":{temperature},\"tint\":{tint}}}");
        let out = run_row(&dir, "wb", &src, "white_balance", &params);
        for (i, px) in src.pixels().enumerate() {
            let rgb = [
                f64::from(px[0]) / 255.0,
                f64::from(px[1]) / 255.0,
                f64::from(px[2]) / 255.0,
            ];
            let want = white_balance_oracle(rgb, temperature, tint);
            for c in 0..3 {
                let want_byte = (want[c].clamp(0.0, 1.0) * 255.0).round();
                assert!(
                    (f64::from(out[i][c]) - want_byte).abs() <= 1.0,
                    "({temperature} K, tint {tint}) pixel {i} channel {c}: {} vs {want_byte}",
                    out[i][c]
                );
            }
        }
    }
}

/// CIE Lab of an 8-bit sRGB triple under D65 — the readout a photographer
/// judges a cast by. Written here from the published formula so the axis
/// assertions below are independent of the core's own `lab` module.
fn srgb_lab(rgb: [u8; 3]) -> [f64; 3] {
    let lin = rgb.map(|c| s2l(f64::from(c) / 255.0));
    let xyz = mat_vec(SRGB_TO_XYZ, lin);
    let f = |t: f64| {
        if t > 216.0 / 24389.0 {
            t.cbrt()
        } else {
            (24389.0 / 27.0 * t + 16.0) / 116.0
        }
    };
    let (fx, fy, fz) = (
        f(xyz[0] / D65_XYZ[0]),
        f(xyz[1] / D65_XYZ[1]),
        f(xyz[2] / D65_XYZ[2]),
    );
    [116.0 * fy - 16.0, 500.0 * (fx - fy), 200.0 * (fy - fz)]
}

#[test]
fn white_balance_directions_are_the_camera_raw_ones() {
    // Outcomes, not formulas: a HIGHER kelvin says "the light was bluer", so
    // removing it WARMS; a POSITIVE tint says "the light was greener", so
    // removing it pushes toward MAGENTA (R and B up relative to G).
    let dir = TempDir::new().unwrap();
    let grey = flat(128, 4, 4);
    let read = |tag: &str, params: &str| -> [u8; 3] {
        let out = run_row(&dir, tag, &grey, "white_balance", params);
        out[0]
    };
    let warm = read("wb-warm", "{\"temperature\":9000}");
    assert!(
        warm[0] > 128 && warm[2] < 128,
        "9000 K must raise red and lower blue on grey: {warm:?}"
    );
    let cool = read("wb-cool", "{\"temperature\":5000}");
    assert!(
        cool[0] < 128 && cool[2] > 128,
        "5000 K must cool a grey: {cool:?}"
    );
    let magenta = read("wb-mag", "{\"tint\":50}");
    assert!(
        magenta[0] > magenta[1] && magenta[2] > magenta[1],
        "tint +50 must raise R and B relative to G: {magenta:?}"
    );
    let green = read("wb-green", "{\"tint\":-50}");
    assert!(
        green[1] > green[0] && green[1] > green[2],
        "tint -50 must do the reverse: {green:?}"
    );

    // R and B above G is satisfied by a BLUE cast too, which is what a tint
    // offset taken along `+v` instead of along the isotherm produces: at
    // 6504 K a pure +v step is 81 % a temperature change. So assert the axis
    // itself — the tint slider is green-magenta, so on a neutral grey the
    // Lab a* excursion must DOMINATE the b* one, both ways and at both the
    // small and the extreme setting. (The old v-only code failed this: tint
    // +50 gave a* +6.5 against b* -14.2.)
    for (tag, tint, magenta_ward) in [
        ("wb-a50", 50.0, true),
        ("wb-a150", 150.0, true),
        ("wb-a-50", -50.0, false),
        ("wb-a-150", -150.0, false),
    ] {
        let out = read(tag, &format!("{{\"tint\":{tint}}}"));
        let lab = srgb_lab(out);
        assert_eq!(magenta_ward, lab[1] > 0.0, "tint {tint}: a* {}", lab[1]);
        assert!(
            lab[1].abs() > lab[2].abs(),
            "tint {tint} must move a* more than b*: {out:?} -> a* {}, b* {}",
            lab[1],
            lab[2]
        );
    }
}

#[test]
fn white_balance_refuses_out_of_range_parameters() {
    let dir = TempDir::new().unwrap();
    let img = open_pattern(&dir, "wb-bad.png", &flat(128, 8, 8));
    for params in [
        "{\"temperature\":1666}",
        "{\"temperature\":25001}",
        "{\"tint\":151}",
        "{\"tint\":-151}",
        "{\"temperature\":true}",
    ] {
        let c_op = CString::new("white_balance").unwrap();
        let c_params = CString::new(params).unwrap();
        let mut err: *mut c_char = ptr::null_mut();
        let out = unsafe { rz_image_adjust_op(img, c_op.as_ptr(), c_params.as_ptr(), &mut err) };
        assert!(out.is_null(), "{params} must be refused");
        assert!(!take_err_string(err).is_empty());
    }
    free(img);
}

// ------------------------------------------------- the generic export ----

#[test]
fn adjust_op_reports_its_refusals_and_accepts_null_params() {
    let dir = TempDir::new().unwrap();
    let img = open_pattern(&dir, "op.png", &flat(128, 4, 4));

    // NULL params means "every default", which for `invert` is the whole op.
    let op = CString::new("invert").unwrap();
    let mut err: *mut c_char = ptr::null_mut();
    let out = unsafe { rz_image_adjust_op(img, op.as_ptr(), ptr::null(), &mut err) };
    assert!(!out.is_null(), "NULL params must mean every default");
    assert_eq!(pixel_at(out, 0, 0), [127, 127, 127, 255]);
    unsafe { rz_image_free(out) };

    for (op, params, needle) in [
        ("no_such_op", "{}", "no_such_op"),
        ("exposure", "not json", "valid JSON"),
        ("exposure", "[1,2]", "object"),
    ] {
        let c_op = CString::new(op).unwrap();
        let c_params = CString::new(params).unwrap();
        let mut err: *mut c_char = ptr::null_mut();
        let out = unsafe { rz_image_adjust_op(img, c_op.as_ptr(), c_params.as_ptr(), &mut err) };
        assert!(out.is_null(), "{op} / {params} must be refused");
        let message = take_err_string(err);
        assert!(
            message.contains(needle),
            "{op} / {params}: `{message}` should mention `{needle}`"
        );
    }

    // A NULL op string is named in the message; a NULL image is a silent
    // refusal with no message at all, like every other pure op.
    let mut err: *mut c_char = ptr::null_mut();
    assert!(unsafe { rz_image_adjust_op(img, ptr::null(), ptr::null(), &mut err) }.is_null());
    assert!(take_err_string(err).contains("op"));
    let mut err: *mut c_char = ptr::null_mut();
    let op = CString::new("invert").unwrap();
    assert!(
        unsafe { rz_image_adjust_op(ptr::null(), op.as_ptr(), ptr::null(), &mut err) }.is_null()
    );
    assert!(err.is_null(), "a NULL image is a refusal, not an error");
    free(img);
}
