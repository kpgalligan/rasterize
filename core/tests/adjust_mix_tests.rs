//! The four decomposition/matrix ops of `rz_image_adjust_op`:
//! `black_and_white`, `photo_filter`, `channel_mixer` and
//! `selective_color`, exercised through the C ABI.
//!
//! The oracles here are written from the published descriptions — the hue
//! decomposition, the density-weighted multiply, the percentage matrix,
//! Adobe's own definition of Relative and Absolute — and the worked
//! examples those sources publish are asserted as literals on top of them.

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

fn row_of(colors: &[[u8; 3]]) -> RgbaImage {
    RgbaImage::from_fn(colors.len() as u32, 1, |x, _| {
        let c = colors[x as usize];
        Rgba([c[0], c[1], c[2], 255])
    })
}

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

fn run_bytes(dir: &TempDir, tag: &str, src: &RgbaImage, op: &str, params: &str) -> Vec<u8> {
    let img = open_pattern(dir, &format!("{tag}.png"), src);
    let out = adjust(img, op, params);
    let bytes = pixels(out);
    unsafe { rz_image_free(out) };
    free(img);
    bytes
}

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

// -------------------------------------------------------------- oracles --

fn luma(rgb: [f64; 3]) -> f64 {
    0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2]
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

/// The neutral part, the primary slot and its amount, the secondary slot
/// and its amount, on the six-slot wheel (0 reds, 1 yellows, 2 greens,
/// 3 cyans, 4 blues, 5 magentas).
fn decompose(rgb: [f64; 3]) -> (f64, usize, f64, usize, f64) {
    let mut order = [0usize, 1, 2];
    order.sort_by(|&a, &b| rgb[b].total_cmp(&rgb[a]).then(a.cmp(&b)));
    let (hi, mid, lo) = (order[0], order[1], order[2]);
    let secondary = match (hi.min(mid), hi.max(mid)) {
        (0, 1) => 1, // red + green = yellow
        (1, 2) => 3, // green + blue = cyan
        _ => 5,      // red + blue = magenta
    };
    (
        rgb[lo],
        hi * 2,
        rgb[hi] - rgb[mid],
        secondary,
        rgb[mid] - rgb[lo],
    )
}

const BW_DEFAULTS: [f64; 6] = [0.4, 0.6, 0.4, 0.6, 0.2, 0.8];

fn black_and_white_oracle(rgb: [f64; 3], weights: [f64; 6]) -> f64 {
    let (neutral, primary, primary_amount, secondary, secondary_amount) = decompose(rgb);
    (neutral + primary_amount * weights[primary] + secondary_amount * weights[secondary])
        .clamp(0.0, 1.0)
}

fn preserve(original: [f64; 3], adjusted: [f64; 3]) -> [f64; 3] {
    let out_luma = luma(adjusted);
    if out_luma <= 0.0 {
        return adjusted;
    }
    let k = luma(original) / out_luma;
    adjusted.map(|v| (v * k).clamp(0.0, 1.0))
}

fn photo_filter_oracle(rgb: [f64; 3], filter: [f64; 3], density: f64, keep: bool) -> [f64; 3] {
    let out: [f64; 3] = std::array::from_fn(|c| rgb[c] * (1.0 - density + density * filter[c]));
    if keep {
        preserve(rgb, out)
    } else {
        out.map(|v| v.clamp(0.0, 1.0))
    }
}

fn rgb_to_cmyk(rgb: [f64; 3]) -> [f64; 4] {
    let k = 1.0 - rgb[0].max(rgb[1]).max(rgb[2]);
    if k >= 1.0 {
        return [0.0, 0.0, 0.0, 1.0];
    }
    [
        (1.0 - rgb[0] - k) / (1.0 - k),
        (1.0 - rgb[1] - k) / (1.0 - k),
        (1.0 - rgb[2] - k) / (1.0 - k),
        k,
    ]
}

fn cmyk_to_rgb(ink: [f64; 4]) -> [f64; 3] {
    [
        (1.0 - ink[0]) * (1.0 - ink[3]),
        (1.0 - ink[1]) * (1.0 - ink[3]),
        (1.0 - ink[2]) * (1.0 - ink[3]),
    ]
}

/// The nine range weights: the chromatic six are the hue MEMBERSHIP (the
/// decomposition's amounts over the chroma), the achromatic three the
/// position on the light-dark axis.
fn selective_weights(rgb: [f64; 3]) -> [f64; 9] {
    let (_, primary, primary_amount, secondary, secondary_amount) = decompose(rgb);
    let mx = rgb[0].max(rgb[1]).max(rgb[2]);
    let mn = rgb[0].min(rgb[1]).min(rgb[2]);
    let chroma = mx - mn;
    let mut w = [0.0f64; 9];
    if chroma > 0.0 {
        w[primary] = primary_amount / chroma;
        w[secondary] = secondary_amount / chroma;
    }
    w[6] = ((mn - 0.5) * 2.0).clamp(0.0, 1.0);
    w[8] = ((0.5 - mx) * 2.0).clamp(0.0, 1.0);
    w[7] = (1.0 - w[6] - w[8]).clamp(0.0, 1.0);
    w
}

fn selective_oracle(rgb: [f64; 3], ranges: [[f64; 4]; 9], absolute: bool) -> [f64; 3] {
    let weights = selective_weights(rgb);
    let mut delta = [0.0f64; 4];
    for (range, weight) in ranges.iter().zip(weights) {
        for (slot, nudge) in delta.iter_mut().zip(range) {
            *slot += weight * nudge;
        }
    }
    let mut ink = rgb_to_cmyk(rgb);
    for (value, d) in ink.iter_mut().zip(delta) {
        *value = if absolute {
            *value + d
        } else {
            *value * (1.0 + d)
        }
        .clamp(0.0, 1.0);
    }
    cmyk_to_rgb(ink)
}

// -------------------------------------------------------- black & white --

/// Photoshop's factory table, which IS the acceptance test.
#[test]
fn black_and_white_reproduces_the_factory_table() {
    let dir = TempDir::new().unwrap();
    let table: [([u8; 3], u8); 9] = [
        ([255, 0, 0], 102),
        ([255, 255, 0], 153),
        ([0, 255, 0], 102),
        ([0, 255, 255], 153),
        ([0, 0, 255], 51),
        ([255, 0, 255], 204),
        ([255, 255, 255], 255),
        ([128, 128, 128], 128),
        ([200, 150, 120], 158),
    ];
    let src = row_of(&table.map(|(c, _)| c));
    let out = run(&dir, "bw-table", &src, "black_and_white", "{}");
    for ((color, want), got) in table.iter().zip(&out) {
        let oracle = black_and_white_oracle(norm(*color), BW_DEFAULTS);
        assert!(
            ((oracle * 255.0).round() - f64::from(*want)).abs() < 0.5,
            "the oracle itself gives {} for {color:?}, expected {want}",
            oracle * 255.0
        );
        assert_eq!(*got, [*want; 3], "black_and_white{color:?}");
    }
}

/// A grey pixel has no hue components at all, so no weight can tint it —
/// the first invariant of the decomposition, checked with a deliberately
/// wild mix.
#[test]
fn black_and_white_never_tints_a_neutral() {
    let dir = TempDir::new().unwrap();
    let src = row_of(&[[0, 0, 0], [17, 17, 17], [128, 128, 128], [255, 255, 255]]);
    let wild = "{\"reds\":3,\"yellows\":-2,\"greens\":2.5,\"cyans\":-1.5,\
        \"blues\":3,\"magentas\":-2}";
    let out = run(&dir, "bw-grey", &src, "black_and_white", wild);
    for (px, got) in src.pixels().zip(&out) {
        assert_eq!(
            *got, [px[0]; 3],
            "a neutral is its own grey, whatever the weights"
        );
    }
}

/// The tint uses ONLY the colour's hue and saturation; the lightness is the
/// computed grey, which is what keeps the tonal mapping intact.
#[test]
fn black_and_white_tint_colorizes_the_computed_grey() {
    let dir = TempDir::new().unwrap();
    let src = row_of(&[[255, 0, 0], [200, 150, 120], [128, 128, 128]]);
    let plain = run(&dir, "bw-plain", &src, "black_and_white", "{}");

    // The default tint is the sRGB spelling of hue 42 deg, saturation 20 %.
    let tinted = run(&dir, "bw-tint", &src, "black_and_white", "{\"tint\":true}");
    for (grey, got) in plain.iter().zip(&tinted) {
        let level = f64::from(grey[0]) / 255.0;
        assert_bytes(*got, hsl_to_rgb([42.353, 0.2, level]), "default tint");
    }
    // An explicit tint colour, in the DOCUMENT's numbers: pure blue is
    // hue 240 at full saturation, so the tint is unmistakable.
    let blue = run(
        &dir,
        "bw-tint-blue",
        &src,
        "black_and_white",
        "{\"tint\":true,\"tint_color\":\"#0000ff\"}",
    );
    for (grey, got) in plain.iter().zip(&blue) {
        let level = f64::from(grey[0]) / 255.0;
        assert_bytes(*got, hsl_to_rgb([240.0, 1.0, level]), "blue tint");
    }
    // Only the hue and saturation are read: a tint colour of a different
    // lightness but the same hue/saturation gives the same picture.
    let same = run(
        &dir,
        "bw-tint-same",
        &src,
        "black_and_white",
        "{\"tint\":true,\"tint_color\":\"#000080\"}",
    );
    assert_eq!(blue, same, "the tint colour's own lightness is not used");
}

/// At the FACTORY weights, Black & White is a very different picture from
/// the `grayscale` op — which is why both are offered, and the only claim
/// this half makes.
#[test]
fn black_and_white_at_the_factory_weights_is_not_the_grayscale_op() {
    let dir = TempDir::new().unwrap();
    let src = row_of(&[[255, 0, 0], [0, 0, 255], [200, 100, 50]]);
    let bw = run(&dir, "bw-vs", &src, "black_and_white", "{}");
    let img = open_pattern(&dir, "gray-vs.png", &src);
    let grey = unsafe { rz_image_grayscale(img) };
    let bytes = pixels(grey);
    for (i, got) in bw.iter().enumerate() {
        assert_ne!(
            got[0],
            bytes[i * 4],
            "pixel {i}: the factory mix is not Rec. 709 luma"
        );
    }
    // Rec. 709 luma reads pure red at 54; the factory hue weights read it
    // at 102, which is the whole reason both ops are offered.
    assert_eq!(bytes[0], 54);
    assert_eq!(bw[0][0], 102);
    unsafe { rz_image_free(grey) };
    free(img);
}

/// And at the LUMA weights the two coincide — `grayscale` is this op's
/// degenerate case, exactly as the spec says.
///
/// `decompose` writes a pixel as `neutral*(1,1,1) + p*P + s*S`, Rec. 709
/// luma is linear with `luma((1,1,1)) = 1`, and each secondary's luma is
/// the sum of its two primaries', so weighting each wheel slot by the luma
/// of its own colour reproduces luma everywhere. Asserted over a pattern
/// that hits every ordering of the three channels, ties included.
///
/// The tolerance is one code, and it is not slack: `grayscale` is one of
/// the legacy nine and does its arithmetic in 0..255, so a value falling
/// exactly between two codes can round one step away — which is the whole
/// of what still separates the two ops.
#[test]
fn black_and_white_at_luma_weights_is_the_grayscale_op() {
    let dir = TempDir::new().unwrap();
    let src = opaque_pattern(64, 64);
    let luma_weights = "{\"reds\":0.2126,\"yellows\":0.9278,\"greens\":0.7152,\
        \"cyans\":0.7874,\"blues\":0.0722,\"magentas\":0.2848}";
    let bw = run(&dir, "bw-luma", &src, "black_and_white", luma_weights);
    let img = open_pattern(&dir, "gray-luma.png", &src);
    let grey = unsafe { rz_image_grayscale(img) };
    let bytes = pixels(grey);
    let mut off_by_one = 0usize;
    for (i, got) in bw.iter().enumerate() {
        let want = bytes[i * 4];
        assert_eq!(got[0], got[1], "pixel {i}: the result must be neutral");
        assert_eq!(got[1], got[2], "pixel {i}: the result must be neutral");
        let delta = i32::from(got[0]) - i32::from(want);
        assert!(
            delta.abs() <= 1,
            "pixel {i}: {} vs grayscale's {want} — the luma weights ARE grayscale",
            got[0]
        );
        if delta != 0 {
            off_by_one += 1;
        }
    }
    // The 0..1 and 0..255 paths agree on the overwhelming majority; only a
    // half-code can split them.
    assert!(
        off_by_one * 20 < bw.len(),
        "{off_by_one} of {} pixels differ, which is more than rounding",
        bw.len()
    );
    unsafe { rz_image_free(grey) };
    free(img);
}

#[test]
fn black_and_white_refuses_malformed_parameters() {
    let dir = TempDir::new().unwrap();
    for params in [
        "{\"reds\":3.1}",
        "{\"blues\":-2.1}",
        "{\"magentas\":\"lots\"}",
        "{\"tint\":\"yes\"}",
        "{\"tint_color\":\"blue\"}",
        "{\"tint_color\":\"#12345\"}",
    ] {
        refuses(&dir, "bw-bad", "black_and_white", params);
    }
}

// --------------------------------------------------------- photo filter --

/// The published worked rows: Warming 85 and Cooling 80 on a neutral at the
/// default 25 % density. Preserve OFF darkens (blue falls to 96); preserve
/// ON lifts the whole triple back to the original luma.
#[test]
fn photo_filter_reproduces_the_worked_rows() {
    let dir = TempDir::new().unwrap();
    let grey = row_of(&[[128, 128, 128]]);
    let cases = [
        (
            "#ec8a00",
            [236.0, 138.0, 0.0],
            [125.616, 113.318, 96.0],
            [140.204, 126.477, 107.149],
        ),
        (
            "#006dff",
            [0.0, 109.0, 255.0],
            [96.0, 109.678, 128.0],
            [113.680, 129.877, 151.573],
        ),
    ];
    for (hex, filter, want_off, want_on) in cases {
        let filter = filter.map(|v: f64| v / 255.0);
        let off = photo_filter_oracle(norm([128, 128, 128]), filter, 0.25, false);
        let on = photo_filter_oracle(norm([128, 128, 128]), filter, 0.25, true);
        for c in 0..3 {
            assert!(
                (off[c] * 255.0 - want_off[c]).abs() < 0.01
                    && (on[c] * 255.0 - want_on[c]).abs() < 0.01,
                "the oracle is wrong for {hex} at channel {c}: {} / {}",
                off[c] * 255.0,
                on[c] * 255.0
            );
        }
        let got_off = run(
            &dir,
            "pf-off",
            &grey,
            "photo_filter",
            &format!("{{\"color\":\"{hex}\",\"preserve_luminosity\":false}}"),
        );
        assert_bytes(got_off[0], off, hex);
        let got_on = run(
            &dir,
            "pf-on",
            &grey,
            "photo_filter",
            &format!("{{\"color\":\"{hex}\"}}"),
        );
        assert_bytes(got_on[0], on, hex);
        assert!(
            (luma(norm(got_on[0])) * 255.0 - 128.0).abs() <= 1.0,
            "preserve on holds the luma: {:?}",
            got_on[0]
        );
    }
}

#[test]
fn photo_filter_density_scales_between_identity_and_the_filter() {
    let dir = TempDir::new().unwrap();
    let src = opaque_pattern(16, 16);
    // Density 0 is an exact identity WHATEVER the colour is, and whether or
    // not luminosity is preserved (the rescale factor is 1).
    for keep in ["true", "false"] {
        assert_eq!(
            run_bytes(
                &dir,
                "pf-zero",
                &src,
                "photo_filter",
                &format!("{{\"color\":\"#00ff00\",\"density\":0,\"preserve_luminosity\":{keep}}}"),
            ),
            *src.as_raw(),
            "density 0 must be an exact identity"
        );
    }
    // Full density with preserve off is a plain multiply by the colour.
    let out = run(
        &dir,
        "pf-full",
        &src,
        "photo_filter",
        "{\"color\":\"#8040c0\",\"density\":1,\"preserve_luminosity\":false}",
    );
    let filter = norm([0x80, 0x40, 0xc0]);
    for (px, got) in src.pixels().zip(&out) {
        let rgb = norm([px[0], px[1], px[2]]);
        assert_bytes(
            *got,
            std::array::from_fn(|c| rgb[c] * filter[c]),
            "density 1",
        );
    }
    // The default is Warming 85 at 25 %: naming it explicitly changes
    // nothing.
    assert_eq!(
        run_bytes(&dir, "pf-default", &src, "photo_filter", "{}"),
        run_bytes(
            &dir,
            "pf-named",
            &src,
            "photo_filter",
            "{\"color\":\"#ec8a00\",\"density\":0.25,\"preserve_luminosity\":true}"
        ),
        "the defaults are Warming 85 at 25 % with luminosity preserved"
    );
}

#[test]
fn photo_filter_refuses_malformed_parameters() {
    let dir = TempDir::new().unwrap();
    for params in [
        "{\"density\":1.5}",
        "{\"density\":-0.1}",
        "{\"color\":\"warming\"}",
        "{\"color\":42}",
        "{\"preserve_luminosity\":\"on\"}",
    ] {
        refuses(&dir, "pf-bad", "photo_filter", params);
    }
}

// -------------------------------------------------------- channel mixer --

#[test]
fn channel_mixer_identity_is_exact_and_the_worked_rows_hold() {
    let dir = TempDir::new().unwrap();
    let pattern = opaque_pattern(16, 16);
    for params in [
        "{}",
        "{\"red\":{\"r\":1},\"green\":{\"g\":1},\"blue\":{\"b\":1}}",
        // The gray row is read but unused while Monochrome is off.
        "{\"gray\":{\"r\":0.9,\"g\":0.05,\"b\":0.05}}",
    ] {
        assert_eq!(
            run_bytes(&dir, "cm-id", &pattern, "channel_mixer", params),
            *pattern.as_raw(),
            "{params} must be an exact identity"
        );
    }

    let src = row_of(&[[200, 100, 50]]);
    // The classic B&W-via-mixer recipe.
    let mono = run(
        &dir,
        "cm-mono",
        &src,
        "channel_mixer",
        "{\"monochrome\":true,\"gray\":{\"r\":0.4,\"g\":0.4,\"b\":0.2}}",
    );
    assert_eq!(mono[0], [130, 130, 130], "0.4*200 + 0.4*100 + 0.2*50");
    // Which is NOT what Black & White's factory weights give for the same
    // pixel — genuinely different algorithms, never conflated. (The map's
    // "158" belongs to (200,150,120); this pixel's Black & White value is
    // 120, recomputed here from the decomposition.)
    let bw = run(&dir, "cm-bw", &src, "black_and_white", "{}");
    assert_eq!(bw[0], [120, 120, 120]);
    assert_ne!(mono[0], bw[0]);

    // A row that mixes and adds a constant: 0.5*200 + 0.5*100 + 0.1*255.
    let mixed = run(
        &dir,
        "cm-const",
        &src,
        "channel_mixer",
        "{\"red\":{\"r\":0.5,\"g\":0.5,\"b\":0,\"constant\":0.1}}",
    );
    assert_eq!(mixed[0], [176, 100, 50], "175.5 rounds to 176");

    // Monochrome sends the gray row to all three outputs, so the result is
    // neutral whatever the other rows say.
    let neutral = run(
        &dir,
        "cm-neutral",
        &opaque_pattern(8, 8),
        "channel_mixer",
        "{\"monochrome\":true,\"red\":{\"r\":0,\"g\":0,\"b\":1}}",
    );
    for px in &neutral {
        assert!(
            px[0] == px[1] && px[1] == px[2],
            "monochrome is neutral: {px:?}"
        );
    }
}

#[test]
fn channel_mixer_is_a_matrix_over_the_encoded_values() {
    let dir = TempDir::new().unwrap();
    let src = opaque_pattern(16, 16);
    let rows = [
        [0.6, 0.3, 0.1, -0.05],
        [-0.2, 1.1, 0.1, 0.0],
        [0.0, 0.2, 0.8, 0.25],
    ];
    let params = format!(
        "{{\"red\":{{\"r\":{},\"g\":{},\"b\":{},\"constant\":{}}},\
           \"green\":{{\"r\":{},\"g\":{},\"b\":{},\"constant\":{}}},\
           \"blue\":{{\"r\":{},\"g\":{},\"b\":{},\"constant\":{}}}}}",
        rows[0][0],
        rows[0][1],
        rows[0][2],
        rows[0][3],
        rows[1][0],
        rows[1][1],
        rows[1][2],
        rows[1][3],
        rows[2][0],
        rows[2][1],
        rows[2][2],
        rows[2][3],
    );
    let out = run(&dir, "cm-matrix", &src, "channel_mixer", &params);
    for (px, got) in src.pixels().zip(&out) {
        let rgb = norm([px[0], px[1], px[2]]);
        let want = rows.map(|r| r[0] * rgb[0] + r[1] * rgb[1] + r[2] * rgb[2] + r[3]);
        assert_bytes(*got, want, "channel_mixer");
    }
}

#[test]
fn channel_mixer_refuses_malformed_parameters() {
    let dir = TempDir::new().unwrap();
    for params in [
        "{\"red\":{\"r\":2.5}}",
        "{\"gray\":{\"constant\":-3}}",
        "{\"green\":[1,0,0]}",
        "{\"monochrome\":\"yes\"}",
        "{\"blue\":{\"b\":\"one\"}}",
    ] {
        refuses(&dir, "cm-bad", "channel_mixer", params);
    }
}

// ------------------------------------------------------ selective color --

/// Adobe's published example, both methods: 50 % magenta plus 10 % is 55 %
/// relative and 60 % absolute.
#[test]
fn selective_color_reproduces_adobes_example() {
    let dir = TempDir::new().unwrap();
    let src = row_of(&[[255, 128, 128]]);
    let mut ranges = [[0.0f64; 4]; 9];
    ranges[0][1] = 0.1; // Reds, magenta +10 %

    let ink = rgb_to_cmyk(norm([255, 128, 128]));
    assert!(
        (ink[1] - 0.498039).abs() < 1e-6 && ink[0] == 0.0 && ink[3] == 0.0,
        "the separation of rgb(255,128,128) is {ink:?}"
    );
    // A pale pink is FULLY in the Reds range: the chromatic weights are a
    // hue membership, the amounts over the chroma. An un-normalized amount
    // would put this pixel at 0.498 and miss Adobe's number by six levels.
    let weights = selective_weights(norm([255, 128, 128]));
    assert!(
        (weights[0] - 1.0).abs() < 1e-6,
        "Reds weight is {}",
        weights[0]
    );

    for (method, want_ink, want_rgb) in [
        ("relative", 0.5478, [255.0, 115.3, 128.0]),
        ("absolute", 0.5980, [255.0, 102.5, 128.0]),
    ] {
        let absolute = method == "absolute";
        let oracle = selective_oracle(norm([255, 128, 128]), ranges, absolute);
        let moved_ink = if absolute { ink[1] + 0.1 } else { ink[1] * 1.1 };
        assert!(
            (moved_ink - want_ink).abs() < 1e-4,
            "{method}: the ink lands at {moved_ink}, expected {want_ink}"
        );
        for c in 0..3 {
            assert!(
                (oracle[c] * 255.0 - want_rgb[c]).abs() < 0.05,
                "{method}: the oracle gives {} at channel {c}, expected {}",
                oracle[c] * 255.0,
                want_rgb[c]
            );
        }
        let out = run(
            &dir,
            "sc-adobe",
            &src,
            "selective_color",
            &format!("{{\"method\":\"{method}\",\"reds\":{{\"m\":0.1}}}}"),
        );
        assert_bytes(out[0], oracle, method);
    }
}

#[test]
fn selective_color_matches_the_cmyk_oracle_over_a_pattern() {
    let dir = TempDir::new().unwrap();
    let src = opaque_pattern(16, 16);
    let mut ranges = [[0.0f64; 4]; 9];
    ranges[0] = [0.2, -0.1, 0.0, 0.05]; // reds
    ranges[3] = [-0.3, 0.0, 0.4, 0.0]; // cyans
    ranges[7] = [0.0, 0.15, -0.15, 0.1]; // neutrals
    ranges[8] = [0.0, 0.0, 0.0, -0.5]; // blacks
    let params = "{\"reds\":{\"c\":0.2,\"m\":-0.1,\"k\":0.05},\
        \"cyans\":{\"c\":-0.3,\"y\":0.4},\
        \"neutrals\":{\"m\":0.15,\"y\":-0.15,\"k\":0.1},\
        \"blacks\":{\"k\":-0.5}}";
    for (method, absolute) in [("relative", false), ("absolute", true)] {
        let out = run(
            &dir,
            "sc-oracle",
            &src,
            "selective_color",
            &format!("{{\"method\":\"{method}\",{}", &params[1..]),
        );
        for (px, got) in src.pixels().zip(&out) {
            let want = selective_oracle(norm([px[0], px[1], px[2]]), ranges, absolute);
            assert_bytes(*got, want, method);
        }
    }
}

/// The `k >= 1` guard is the divide-by-zero the separation hides, and the
/// achromatic ranges are what reach a pixel with no hue at all.
#[test]
fn selective_color_handles_black_white_and_neutrals() {
    let dir = TempDir::new().unwrap();
    let src = row_of(&[[0, 0, 0], [255, 255, 255], [128, 128, 128]]);

    // Pure black has no C/M/Y ratios: relative nudges cannot bring any
    // back, and the op must not divide by zero doing it.
    let out = run(
        &dir,
        "sc-black",
        &src,
        "selective_color",
        "{\"blacks\":{\"c\":0.5,\"m\":0.5,\"y\":0.5}}",
    );
    assert_eq!(out[0], [0, 0, 0], "relative on pure black adds no ink");
    // Absolute does, and the weights say which range reaches which pixel.
    let out = run(
        &dir,
        "sc-abs",
        &src,
        "selective_color",
        "{\"method\":\"absolute\",\"whites\":{\"k\":0.2}}",
    );
    assert_eq!(out[0], [0, 0, 0], "the Whites range does not reach black");
    assert_eq!(out[2], [128, 128, 128], "nor mid grey");
    assert_bytes(
        out[1],
        selective_oracle(
            norm([255, 255, 255]),
            {
                let mut r = [[0.0f64; 4]; 9];
                r[6][3] = 0.2;
                r
            },
            true,
        ),
        "whites +20 % black ink",
    );
    assert!(out[1][0] < 255, "white takes the ink");
}

#[test]
fn selective_color_defaults_are_a_byte_exact_no_op() {
    let dir = TempDir::new().unwrap();
    let src = opaque_pattern(16, 16);
    for params in [
        "{}",
        "{\"method\":\"absolute\"}",
        "{\"reds\":{},\"whites\":{},\"blacks\":{}}",
    ] {
        assert_eq!(
            run_bytes(&dir, "sc-id", &src, "selective_color", params),
            *src.as_raw(),
            "{params}: an all-zero nudge is an exact CMYK round trip"
        );
    }
}

#[test]
fn selective_color_refuses_malformed_parameters() {
    let dir = TempDir::new().unwrap();
    for params in [
        "{\"method\":\"perceptual\"}",
        "{\"method\":7}",
        "{\"reds\":{\"c\":1.5}}",
        "{\"neutrals\":{\"k\":-1.5}}",
        "{\"blacks\":\"none\"}",
    ] {
        refuses(&dir, "sc-bad", "selective_color", params);
    }
}
