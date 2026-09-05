//! The `color_lookup` adjustment and `rz_lut_parse_cube`: the Adobe Cube
//! LUT parser, trilinear and linear evaluation, the domain, the strength
//! lerp, the resample to this build's storage cap, the parse-time refusals,
//! and the memo that keeps a big table from being re-parsed per composite.
//!
//! The reference lookup and the base64 codec below are written HERE from the
//! Cube LUT 1.0 specification and from RFC 4648, deliberately in a different
//! shape from the core's, and the reference is checked against the
//! specification's own worked examples before it is used to judge anything.

use std::ffi::{c_char, CString};
use std::ptr;

use image::{Rgba, RgbaImage};
use rasterize_core::doc::RzDocument;
use rasterize_core::ffi::*;
use rasterize_core::ffi_adjust::*;
use rasterize_core::ffi_doc::*;
use serde_json::{json, Map, Value};
use tempfile::TempDir;

mod common;
use common::*;

// ------------------------------------------------- base64, written here --

const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

fn b64_encode(bytes: &[u8]) -> String {
    let mut out = String::new();
    let mut i = 0;
    while i < bytes.len() {
        let remaining = bytes.len() - i;
        let b0 = u32::from(bytes[i]);
        let b1 = if remaining > 1 {
            u32::from(bytes[i + 1])
        } else {
            0
        };
        let b2 = if remaining > 2 {
            u32::from(bytes[i + 2])
        } else {
            0
        };
        let word = (b0 << 16) | (b1 << 8) | b2;
        out.push(ALPHABET[(word >> 18) as usize & 63] as char);
        out.push(ALPHABET[(word >> 12) as usize & 63] as char);
        out.push(if remaining > 1 {
            ALPHABET[(word >> 6) as usize & 63] as char
        } else {
            '='
        });
        out.push(if remaining > 2 {
            ALPHABET[word as usize & 63] as char
        } else {
            '='
        });
        i += 3;
    }
    out
}

fn b64_decode(text: &str) -> Vec<u8> {
    let mut bits: Vec<u8> = Vec::new();
    for byte in text.bytes() {
        if byte == b'=' {
            break;
        }
        let index = ALPHABET
            .iter()
            .position(|c| *c == byte)
            .unwrap_or_else(|| panic!("`{}` is not a base64 digit", byte as char));
        bits.push(index as u8);
    }
    let mut out = Vec::new();
    for chunk in bits.chunks(4) {
        let mut word: u32 = 0;
        for (i, v) in chunk.iter().enumerate() {
            word |= u32::from(*v) << (18 - 6 * i);
        }
        let produced = chunk.len() * 6 / 8;
        for i in 0..produced {
            out.push((word >> (16 - 8 * i)) as u8);
        }
    }
    out
}

fn table_bytes(table: &[f32]) -> Vec<u8> {
    table.iter().flat_map(|v| v.to_le_bytes()).collect()
}

fn table_floats(encoded: &str) -> Vec<f32> {
    b64_decode(encoded)
        .chunks_exact(4)
        .map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]]))
        .collect()
}

// --------------------------------------- the reference lookup, from spec --

/// `t_c = clamp((v - min) / (max - min), 0, 1) * (n - 1)`, split into the
/// lower node and the fraction with `i = min(floor(t), n - 2)`.
fn split(t: f64, n: usize) -> (usize, f64) {
    let i = (t.floor().max(0.0) as usize).min(n - 2);
    (i, t - i as f64)
}

/// Trilinear over the eight corners, `i = r + g*n + b*n^2` (red fastest).
fn ref_3d(table: &[f32], n: usize, t: [f64; 3]) -> [f64; 3] {
    let (ir, fr) = split(t[0], n);
    let (ig, fg) = split(t[1], n);
    let (ib, fb) = split(t[2], n);
    let mut out = [0.0f64; 3];
    for db in 0..2usize {
        for dg in 0..2usize {
            for dr in 0..2usize {
                let w = (if dr == 1 { fr } else { 1.0 - fr })
                    * (if dg == 1 { fg } else { 1.0 - fg })
                    * (if db == 1 { fb } else { 1.0 - fb });
                let base = ((ir + dr) + (ig + dg) * n + (ib + db) * n * n) * 3;
                for (slot, v) in out.iter_mut().enumerate() {
                    *v += w * f64::from(table[base + slot]);
                }
            }
        }
    }
    out
}

fn ref_1d(table: &[f32], n: usize, t: f64, c: usize) -> f64 {
    let (i, f) = split(t, n);
    f64::from(table[i * 3 + c]) * (1.0 - f) + f64::from(table[(i + 1) * 3 + c]) * f
}

/// The full lookup: domain, interpolation, then the strength lerp.
fn ref_lookup(
    table: &[f32],
    n: usize,
    three_d: bool,
    domain: ([f64; 3], [f64; 3]),
    strength: f64,
    rgb: [f64; 3],
) -> [f64; 3] {
    let node: [f64; 3] = std::array::from_fn(|c| {
        ((rgb[c] - domain.0[c]) / (domain.1[c] - domain.0[c])).clamp(0.0, 1.0) * (n - 1) as f64
    });
    let mapped = if three_d {
        ref_3d(table, n, node)
    } else {
        std::array::from_fn(|c| ref_1d(table, n, node[c], c))
    };
    std::array::from_fn(|c| rgb[c] + (mapped[c] - rgb[c]) * strength)
}

/// The tables below are f32, so a node value like 0.1 is not exactly 0.1 —
/// the specification's worked decimals are reproduced to within one part in
/// a million, which is four orders of magnitude below one 8-bit code.
const TOL: f64 = 1e-6;

#[test]
fn the_reference_reproduces_the_specifications_worked_examples() {
    // The identity 2x2x2, red fastest — the shortest disambiguating fixture.
    let identity = identity_3d(2);
    let unit = ([0.0; 3], [1.0; 3]);
    for input in [[0.3, 0.6, 0.9], [0.5, 0.25, 0.75]] {
        let got = ref_lookup(&identity, 2, true, unit, 1.0, input);
        for c in 0..3 {
            assert!(
                (got[c] - input[c]).abs() < TOL,
                "identity {input:?} -> {got:?}"
            );
        }
    }
    // The same table with red and blue swapped at every node.
    let swapped = swap_rb_3d();
    let got = ref_lookup(&swapped, 2, true, unit, 1.0, [0.3, 0.6, 0.9]);
    for (c, want) in [0.9, 0.6, 0.3].into_iter().enumerate() {
        assert!((got[c] - want).abs() < TOL, "swap -> {got:?}");
    }
    // A 3x3x3 holding v^2 at its nodes shows the interpolation error a
    // coarse LUT carries; (0.5, 0.5, 0.5) is a node and is exact.
    let gamma = gamma_two_3d(3);
    let got = ref_lookup(&gamma, 3, true, unit, 1.0, [0.25, 0.5, 0.75]);
    for (c, want) in [0.125, 0.25, 0.625].into_iter().enumerate() {
        assert!((got[c] - want).abs() < TOL, "gamma table -> {got:?} at {c}");
    }
    let got = ref_lookup(&gamma, 3, true, unit, 1.0, [0.125, 0.0, 1.0]);
    for (c, want) in [0.0625, 0.0, 1.0].into_iter().enumerate() {
        assert!((got[c] - want).abs() < TOL, "gamma table -> {got:?} at {c}");
    }
    // The 1D example from the specification.
    let table = one_d_table(&[0.0, 0.1, 0.25, 0.55, 1.0]);
    for (v, want) in [
        (0.0, 0.0),
        (0.3, 0.13),
        (0.5, 0.25),
        (0.625, 0.4),
        (1.0, 1.0),
    ] {
        let got = ref_lookup(&table, 5, false, unit, 1.0, [v; 3]);
        assert!((got[0] - want).abs() < TOL, "1D at {v} -> {}", got[0]);
    }
    // Domain rescale: DOMAIN_MAX 2 puts 0.3 at t = 0.15 of the range.
    let wide = ([0.0; 3], [2.0; 3]);
    let got = ref_lookup(&identity, 2, true, wide, 1.0, [0.3; 3]);
    assert!((got[0] - 0.15).abs() < TOL, "domain 0..2 -> {got:?}");
    let shifted = ([-0.1; 3], [1.1; 3]);
    let got = ref_lookup(&identity, 2, true, shifted, 1.0, [0.3; 3]);
    assert!(
        (got[0] - 1.0 / 3.0).abs() < TOL,
        "domain -0.1..1.1 -> {got:?}"
    );
}

// ------------------------------------------------------------- fixtures --

/// The identity 3D table at `n` nodes per axis, red fastest.
fn identity_3d(n: usize) -> Vec<f32> {
    let mut out = Vec::with_capacity(n * n * n * 3);
    for b in 0..n {
        for g in 0..n {
            for r in 0..n {
                let s = (n - 1) as f32;
                out.extend_from_slice(&[r as f32 / s, g as f32 / s, b as f32 / s]);
            }
        }
    }
    out
}

/// 2x2x2 with red and blue exchanged.
fn swap_rb_3d() -> Vec<f32> {
    let mut out = Vec::with_capacity(24);
    for b in 0..2 {
        for g in 0..2 {
            for r in 0..2 {
                out.extend_from_slice(&[b as f32, g as f32, r as f32]);
            }
        }
    }
    out
}

/// A 3D table holding `v^2` at every node.
fn gamma_two_3d(n: usize) -> Vec<f32> {
    let mut out = Vec::with_capacity(n * n * n * 3);
    let s = (n - 1) as f32;
    for b in 0..n {
        for g in 0..n {
            for r in 0..n {
                out.extend_from_slice(&[
                    (r as f32 / s).powi(2),
                    (g as f32 / s).powi(2),
                    (b as f32 / s).powi(2),
                ]);
            }
        }
    }
    out
}

/// A 1D table with the same curve on all three channels.
fn one_d_table(values: &[f32]) -> Vec<f32> {
    values.iter().flat_map(|v| [*v, *v, *v]).collect()
}

/// The params object for a table, with whatever extra keys a test needs.
fn lut_params(kind: &str, size: usize, table: &[f32], extra: &[(&str, Value)]) -> Value {
    let mut params = Map::new();
    params.insert("kind".into(), json!(kind));
    params.insert("size".into(), json!(size));
    params.insert("table".into(), json!(b64_encode(&table_bytes(table))));
    for (key, value) in extra {
        params.insert((*key).into(), value.clone());
    }
    Value::Object(params)
}

/// A row of every 8-bit code triple worth probing.
fn probe_row() -> RgbaImage {
    let inputs: Vec<[u8; 3]> = vec![
        [0, 0, 0],
        [255, 255, 255],
        [128, 128, 128],
        [77, 153, 230],
        [64, 32, 192],
        [200, 150, 120],
        [1, 254, 3],
        [250, 10, 60],
    ];
    RgbaImage::from_fn(inputs.len() as u32, 1, |x, _| {
        let p = inputs[x as usize];
        Rgba([p[0], p[1], p[2], 255])
    })
}

/// Applies `color_lookup` with `params` through the ONE destructive export.
fn apply_lut(dir: &TempDir, tag: &str, src: &RgbaImage, params: &Value) -> Vec<[u8; 3]> {
    let img = open_pattern(dir, &format!("{tag}.png"), src);
    let op = CString::new("color_lookup").unwrap();
    let text = CString::new(params.to_string()).unwrap();
    let mut err: *mut c_char = ptr::null_mut();
    let out = unsafe { rz_image_adjust_op(img, op.as_ptr(), text.as_ptr(), &mut err) };
    assert!(!out.is_null(), "{tag} failed: {}", take_err_string(err));
    let bytes = pixels(out);
    unsafe { rz_image_free(out) };
    free(img);
    bytes.chunks_exact(4).map(|p| [p[0], p[1], p[2]]).collect()
}

/// Asserts every probe pixel matches the reference lookup within one byte.
#[allow(clippy::too_many_arguments)]
fn assert_matches_reference(
    dir: &TempDir,
    tag: &str,
    table: &[f32],
    n: usize,
    three_d: bool,
    domain: ([f64; 3], [f64; 3]),
    strength: f64,
    params: &Value,
) {
    let src = probe_row();
    let got = apply_lut(dir, tag, &src, params);
    for (i, px) in src.pixels().enumerate() {
        let rgb = [
            f64::from(px[0]) / 255.0,
            f64::from(px[1]) / 255.0,
            f64::from(px[2]) / 255.0,
        ];
        let want = ref_lookup(table, n, three_d, domain, strength, rgb);
        for c in 0..3 {
            let want_byte = (want[c].clamp(0.0, 1.0) * 255.0).round();
            assert!(
                (f64::from(got[i][c]) - want_byte).abs() <= 1.0,
                "{tag}: pixel {i} channel {c}: {} vs {want_byte}",
                got[i][c]
            );
        }
    }
}

// ------------------------------------------------------------ evaluation --

#[test]
fn identity_lut_is_a_byte_exact_no_op() {
    let dir = TempDir::new().unwrap();
    for size in [2usize, 3, 5, 33] {
        let table = identity_3d(size);
        let params = lut_params("3d", size, &table, &[]);
        let src = probe_row();
        let got = apply_lut(&dir, &format!("id-{size}"), &src, &params);
        for (i, px) in src.pixels().enumerate() {
            assert_eq!(
                got[i],
                [px[0], px[1], px[2]],
                "the identity {size}^3 table must not move pixel {i}"
            );
        }
    }
}

#[test]
fn three_d_lookup_matches_the_reference() {
    let dir = TempDir::new().unwrap();
    let unit = ([0.0f64; 3], [1.0f64; 3]);
    let swapped = swap_rb_3d();
    assert_matches_reference(
        &dir,
        "swap",
        &swapped,
        2,
        true,
        unit,
        1.0,
        &lut_params("3d", 2, &swapped, &[]),
    );
    // A swap is exactly linear, so it is exact, not merely close.
    let src = probe_row();
    let got = apply_lut(
        &dir,
        "swap-exact",
        &src,
        &lut_params("3d", 2, &swapped, &[]),
    );
    for (i, px) in src.pixels().enumerate() {
        assert_eq!(got[i], [px[2], px[1], px[0]], "pixel {i}");
    }
    for size in [3usize, 5, 17] {
        let gamma = gamma_two_3d(size);
        assert_matches_reference(
            &dir,
            &format!("gamma-{size}"),
            &gamma,
            size,
            true,
            unit,
            1.0,
            &lut_params("3d", size, &gamma, &[]),
        );
    }
}

#[test]
fn one_d_lookup_is_per_channel() {
    let dir = TempDir::new().unwrap();
    let unit = ([0.0f64; 3], [1.0f64; 3]);
    // A different curve per channel proves each axis reads its own column.
    let table: Vec<f32> = (0..5)
        .flat_map(|i| {
            let t = i as f32 / 4.0;
            [t.powi(2), t, t.sqrt()]
        })
        .collect();
    assert_matches_reference(
        &dir,
        "one-d",
        &table,
        5,
        false,
        unit,
        1.0,
        &lut_params("1d", 5, &table, &[]),
    );
}

#[test]
fn domain_rescales_the_input_and_strength_lerps_from_the_original() {
    let dir = TempDir::new().unwrap();
    let table = identity_3d(2);
    let wide = ([0.0f64; 3], [2.0f64; 3]);
    assert_matches_reference(
        &dir,
        "domain-wide",
        &table,
        2,
        true,
        wide,
        1.0,
        &lut_params("3d", 2, &table, &[("domain_max", json!([2.0, 2.0, 2.0]))]),
    );
    let shifted = ([-0.1f64; 3], [1.1f64; 3]);
    assert_matches_reference(
        &dir,
        "domain-shift",
        &table,
        2,
        true,
        shifted,
        1.0,
        &lut_params(
            "3d",
            2,
            &table,
            &[
                ("domain_min", json!([-0.1, -0.1, -0.1])),
                ("domain_max", json!([1.1, 1.1, 1.1])),
            ],
        ),
    );
    // Strength: 0 is the original, 1 the LUT, 0.5 halfway.
    let swapped = swap_rb_3d();
    for strength in [0.0f64, 0.25, 0.5, 1.0] {
        assert_matches_reference(
            &dir,
            &format!("strength-{strength}"),
            &swapped,
            2,
            true,
            ([0.0; 3], [1.0; 3]),
            strength,
            &lut_params("3d", 2, &swapped, &[("strength", json!(strength))]),
        );
    }
    let src = probe_row();
    let none = apply_lut(
        &dir,
        "strength-zero",
        &src,
        &lut_params("3d", 2, &swapped, &[("strength", json!(0.0))]),
    );
    for (i, px) in src.pixels().enumerate() {
        assert_eq!(none[i], [px[0], px[1], px[2]], "strength 0 changes nothing");
    }
}

#[test]
fn color_lookup_refuses_malformed_params() {
    let dir = TempDir::new().unwrap();
    let img = open_pattern(&dir, "lut-bad.png", &probe_row());
    let table = identity_3d(2);
    let good = b64_encode(&table_bytes(&table));
    // A table that decodes to the right LENGTH but holds a NaN or an
    // infinity: the numbers are unusable (every lookup that touches the
    // node returns NaN, and a NaN write quantizes to 0), so the params are
    // refused rather than stored. The host mirrors this check before it
    // ever gets here (`AdjustmentSchema.firstNonFiniteEntry`) so an agent
    // is told WHY instead of being handed a layer whose meta silently
    // failed to parse.
    let mut nan_table = table.clone();
    nan_table[0] = f32::NAN;
    let mut inf_table = table.clone();
    inf_table[5] = f32::INFINITY;
    let cases: Vec<Value> = vec![
        json!({}),
        json!({"size": 2, "table": good}),
        json!({"kind": "2d", "size": 2, "table": good}),
        json!({"kind": "3d", "table": good}),
        json!({"kind": "3d", "size": 1, "table": good}),
        json!({"kind": "3d", "size": 34, "table": good}),
        json!({"kind": "1d", "size": 1025, "table": good}),
        json!({"kind": "3d", "size": 3, "table": good}),
        json!({"kind": "3d", "size": 2, "table": "not base64!"}),
        json!({"kind": "3d", "size": 2}),
        json!({"kind": "3d", "size": 2, "table": good, "strength": 1.5}),
        json!({"kind": "3d", "size": 2, "table": good, "domain_min": [0.0, 0.0]}),
        json!({"kind": "3d", "size": 2, "table": good,
               "domain_min": [1.0, 0.0, 0.0], "domain_max": [1.0, 1.0, 1.0]}),
        json!({"kind": "3d", "size": 2, "table": good, "source_size": 1}),
        json!({"kind": "3d", "size": 2, "table": good, "title": "x".repeat(129)}),
        json!({"kind": "3d", "size": 2.5, "table": good}),
        json!({"kind": "3d", "size": 2, "table": b64_encode(&table_bytes(&nan_table))}),
        json!({"kind": "3d", "size": 2, "table": b64_encode(&table_bytes(&inf_table))}),
    ];
    for (n, params) in cases.iter().enumerate() {
        let op = CString::new("color_lookup").unwrap();
        let text = CString::new(params.to_string()).unwrap();
        let mut err: *mut c_char = ptr::null_mut();
        let out = unsafe { rz_image_adjust_op(img, op.as_ptr(), text.as_ptr(), &mut err) };
        assert!(out.is_null(), "case {n} ({params}) must be refused");
        assert!(!take_err_string(err).is_empty(), "case {n} must say why");
    }
    // A 128-character title and a `source_size` that differs from `size` are
    // both ACCEPTED: the second is what a resampled LUT round-trips with.
    for params in [
        json!({"kind": "3d", "size": 2, "table": good, "title": "x".repeat(128)}),
        json!({"kind": "3d", "size": 2, "table": good, "source_size": 64}),
        json!({"kind": "3d", "size": 2, "table": good, "unknown_key": 7}),
    ] {
        let op = CString::new("color_lookup").unwrap();
        let text = CString::new(params.to_string()).unwrap();
        let mut err: *mut c_char = ptr::null_mut();
        let out = unsafe { rz_image_adjust_op(img, op.as_ptr(), text.as_ptr(), &mut err) };
        assert!(!out.is_null(), "{params} must be accepted");
        unsafe { rz_image_free(out) };
    }
    free(img);
}

// ------------------------------------------------------------ .cube file --

/// Writes `text` as a `.cube` file and parses it, returning the params
/// object or the core's message.
fn parse_cube(dir: &TempDir, name: &str, text: &str) -> Result<Value, String> {
    let path = dir.path().join(name);
    std::fs::write(&path, text).expect("write cube");
    parse_cube_path(&path)
}

fn parse_cube_path(path: &std::path::Path) -> Result<Value, String> {
    let c = cpath(path);
    let mut err: *mut c_char = ptr::null_mut();
    let json = unsafe { rz_lut_parse_cube(c.as_ptr(), &mut err) };
    if json.is_null() {
        return Err(take_err_string(err));
    }
    assert!(err.is_null(), "err_out set on success");
    let text = unsafe { std::ffi::CStr::from_ptr(json) }
        .to_string_lossy()
        .into_owned();
    unsafe { rz_string_free(json) };
    Ok(serde_json::from_str(&text).expect("the core emits valid JSON"))
}

#[test]
fn cube_file_reads_the_spec_directives() {
    let dir = TempDir::new().unwrap();
    let text = "\
# a comment, and a blank line follow

TITLE \"Warm Look\"
LUT_3D_SIZE 2
DOMAIN_MIN 0 0 0
DOMAIN_MAX 1 1 1
0.0 0.0 0.0
1.0 0.0 0.0
0.0 1.0 0.0
1.0 1.0 0.0
0.0 0.0 1.0
1.0 0.0 1.0
0.0 1.0 1.0
1.0 1.0 1.0
";
    let params = parse_cube(&dir, "identity.cube", text).expect("parse");
    assert_eq!(params["kind"], json!("3d"));
    assert_eq!(params["size"], json!(2));
    assert_eq!(params["source_size"], json!(2), "always emitted");
    assert_eq!(params["title"], json!("Warm Look"));
    assert_eq!(params["domain_min"], json!([0.0, 0.0, 0.0]));
    assert_eq!(params["domain_max"], json!([1.0, 1.0, 1.0]));
    let table = table_floats(params["table"].as_str().expect("table string"));
    assert_eq!(table, identity_3d(2), "red changes fastest");

    // No TITLE: the key is simply absent.
    let bare = parse_cube(&dir, "bare.cube", "LUT_1D_SIZE 2\n0 0 0\n1 1 1\n").expect("parse 1d");
    assert_eq!(bare["kind"], json!("1d"));
    assert!(bare.get("title").is_none(), "no TITLE, no key");

    // The Resolve-era spelling of the domain, and a non-unit domain.
    let ranged = parse_cube(
        &dir,
        "ranged.cube",
        "LUT_1D_INPUT_RANGE -0.1 1.1\nLUT_1D_SIZE 2\n0 0 0\n1 1 1\n",
    )
    .expect("parse input range");
    assert_eq!(ranged["domain_min"], json!([-0.1, -0.1, -0.1]));
    assert_eq!(ranged["domain_max"], json!([1.1, 1.1, 1.1]));

    // A leading UTF-8 BOM is the same file. Notepad, PowerShell's `Out-File`
    // and several Windows LUT exporters write one; it survives the UTF-8
    // decode as U+FEFF glued to the first token, so the file was refused
    // with "`\u{feff}LUT_3D_SIZE` is not a number" — a message blaming the
    // one directive it got right.
    let bom = parse_cube(&dir, "bom.cube", &format!("\u{feff}{text}")).expect("parse with a BOM");
    assert_eq!(bom, params, "a BOM changes nothing about the file");
}

#[test]
fn cube_file_over_the_storage_cap_resamples_and_reports_its_source_size() {
    let dir = TempDir::new().unwrap();
    // A 64^3 gamma-2 table: over this build's 33^3 storage cap, so it comes
    // back at 33 with `source_size` 64. The resample goes through the same
    // trilinear interpolation the lookup uses, and the table is smooth, so
    // the resampled nodes still sit on v^2 to well within an 8-bit code.
    let n = 64usize;
    let mut text = String::with_capacity(n * n * n * 26 + 32);
    text.push_str("LUT_3D_SIZE 64\n");
    for b in 0..n {
        for g in 0..n {
            for r in 0..n {
                let s = (n - 1) as f64;
                text.push_str(&format!(
                    "{:.6} {:.6} {:.6}\n",
                    (r as f64 / s).powi(2),
                    (g as f64 / s).powi(2),
                    (b as f64 / s).powi(2)
                ));
            }
        }
    }
    let params = parse_cube(&dir, "big.cube", &text).expect("parse 64^3");
    assert_eq!(params["size"], json!(33), "resampled to the storage cap");
    assert_eq!(params["source_size"], json!(64), "the FILE's own size");
    let table = table_floats(params["table"].as_str().unwrap());
    assert_eq!(table.len(), 33 * 33 * 33 * 3);
    for i in 0..33usize {
        let node = table[(i + i * 33 + i * 33 * 33) * 3];
        let want = (i as f32 / 32.0).powi(2);
        assert!(
            (node - want).abs() < 2.0 / 255.0,
            "resampled node {i} is {node}, v^2 is {want}"
        );
    }
    // And the stored params are themselves valid input to the adjustment.
    let src = probe_row();
    let got = apply_lut(&dir, "big-apply", &src, &params);
    for (i, px) in src.pixels().enumerate() {
        let want = (f64::from(px[0]) / 255.0).powi(2) * 255.0;
        assert!(
            (f64::from(got[i][0]) - want).abs() <= 3.0,
            "pixel {i}: {} vs v^2 = {want}",
            got[i][0]
        );
    }

    // The 1D cap, which is 1024.
    let mut wide = String::from("LUT_1D_SIZE 2048\n");
    for i in 0..2048 {
        let t = i as f64 / 2047.0;
        wide.push_str(&format!("{t:.6} {t:.6} {t:.6}\n"));
    }
    let params = parse_cube(&dir, "wide.cube", &wide).expect("parse 1d 2048");
    assert_eq!(params["size"], json!(1024));
    assert_eq!(params["source_size"], json!(2048));
}

#[test]
fn cube_file_refusals_name_the_path_and_never_panic() {
    let dir = TempDir::new().unwrap();
    let cases: Vec<(&str, &str)> = vec![
        ("no-size.cube", "0 0 0\n1 1 1\n"),
        ("both.cube", "LUT_1D_SIZE 2\nLUT_3D_SIZE 2\n0 0 0\n1 1 1\n"),
        ("small.cube", "LUT_3D_SIZE 1\n0 0 0\n"),
        ("huge3d.cube", "LUT_3D_SIZE 65\n0 0 0\n"),
        ("huge1d.cube", "LUT_1D_SIZE 65537\n0 0 0\n"),
        ("short.cube", "LUT_3D_SIZE 2\n0 0 0\n1 1 1\n"),
        ("long.cube", "LUT_1D_SIZE 2\n0 0 0\n1 1 1\n0.5 0.5 0.5\n"),
        ("two-fields.cube", "LUT_1D_SIZE 2\n0 0\n1 1 1\n"),
        ("four-fields.cube", "LUT_1D_SIZE 2\n0 0 0 0\n1 1 1\n"),
        ("nan.cube", "LUT_1D_SIZE 2\nnan 0 0\n1 1 1\n"),
        ("inf.cube", "LUT_1D_SIZE 2\ninf 0 0\n1 1 1\n"),
        ("words.cube", "LUT_1D_SIZE 2\nblack white grey\n1 1 1\n"),
        ("data-first.cube", "0 0 0\nLUT_1D_SIZE 2\n1 1 1\n"),
        (
            "zero-domain.cube",
            "LUT_1D_SIZE 2\nDOMAIN_MIN 0.5 0 0\nDOMAIN_MAX 0.5 1 1\n0 0 0\n1 1 1\n",
        ),
        (
            "backwards-domain.cube",
            "LUT_1D_SIZE 2\nDOMAIN_MIN 1 1 1\nDOMAIN_MAX 0 0 0\n0 0 0\n1 1 1\n",
        ),
        // Past f32: the stored domain narrows to f32 on the way back in, so
        // this has no stored form and must be refused rather than written
        // as an infinity (see the invariant test below).
        (
            "f32-domain.cube",
            "LUT_1D_SIZE 2\nDOMAIN_MAX 3.5e38 3.5e38 3.5e38\n0 0 0\n1 1 1\n",
        ),
        // Past the six-decimal quantizer's own f64 headroom (~1.8e302),
        // where the multiply overflowed and a 0 the file never declared was
        // substituted for the whole domain.
        (
            "quantizer-overflow-domain.cube",
            "LUT_1D_SIZE 2\nDOMAIN_MIN 0 0 0\nDOMAIN_MAX 1e303 1e303 1e303\n0 0 0\n1 1 1\n",
        ),
        (
            "negative-overflow-domain.cube",
            "LUT_1D_SIZE 2\nDOMAIN_MIN -1e303 -1e303 -1e303\n0 0 0\n1 1 1\n",
        ),
        ("fractional-size.cube", "LUT_1D_SIZE 2.5\n0 0 0\n1 1 1\n"),
        ("missing-value.cube", "LUT_1D_SIZE\n0 0 0\n1 1 1\n"),
    ];
    for (name, text) in cases {
        let error = parse_cube(&dir, name, text).expect_err(&format!("{name} must be refused"));
        assert!(
            error.contains(name),
            "{name}: the message must name the path (`{error}`)"
        );
        assert!(
            error.chars().next().is_some_and(char::is_lowercase),
            "{name}: messages are lowercase (`{error}`)"
        );
    }

    // Invalid UTF-8, a missing file, and a file over the read cap.
    let bad = dir.path().join("utf8.cube");
    std::fs::write(&bad, [b'L', b'U', b'T', 0xff, 0xfe]).unwrap();
    let error = parse_cube_path(&bad).expect_err("invalid UTF-8 must be refused");
    assert!(error.contains("UTF-8"), "{error}");
    let error = parse_cube_path(&dir.path().join("never-written.cube"))
        .expect_err("a missing file must be refused");
    assert!(error.contains("never-written.cube"), "{error}");
}

/// THE parser invariant: whatever `rz_lut_parse_cube` accepts, the
/// `color_lookup` adjustment must accept back, with the domain the file
/// declared. The domain is the one thing about a file a caller cannot
/// re-derive from the params, so a corner outside the stored form's reach is
/// refused at parse rather than quantized into something else — a success
/// carrying an invented domain gave the host params the compositor then
/// refused, and the layer built from them composited as nothing at all.
#[test]
fn cube_file_never_emits_a_domain_the_adjustment_will_refuse() {
    let dir = TempDir::new().unwrap();
    let src = probe_row();

    // Inside the stored form's reach: accepted, reported EXACTLY as
    // declared (not zeroed, not rounded to an infinity), and usable.
    for (name, max, want) in [
        ("wide-domain.cube", "3.0e38", 3.0e38f64),
        ("small-domain.cube", "0.000001", 0.000001f64),
        ("plain-domain.cube", "2", 2.0f64),
    ] {
        let params = parse_cube(
            &dir,
            name,
            &format!("LUT_1D_SIZE 2\nDOMAIN_MAX {max} {max} {max}\n0 0 0\n1 1 1\n"),
        )
        .unwrap_or_else(|e| panic!("{name} must parse: {e}"));
        let got = params["domain_max"].as_array().expect("a domain triple");
        for v in got {
            let v = v.as_f64().expect("a finite number");
            assert!(
                (v - want).abs() <= want.abs() * 1e-9,
                "{name}: domain_max came back {v}, the file said {want}"
            );
        }
        // Accepted back by the adjustment, which is the whole point. At
        // 3e38 the whole 8-bit range collapses onto the bottom node, so the
        // identity ramp's first row (black) comes out for white.
        let out = apply_lut(&dir, "wide-apply", &src, &params);
        if want > 1e6 {
            assert_eq!(out[1], [0, 0, 0], "{name}: 255 sits at the bottom node");
        }
    }

    // And nothing the parser accepts may be refused downstream. Every
    // domain the parser takes, run through the adjustment.
    for (name, line) in [
        ("d-default.cube", String::new()),
        ("d-unit.cube", "DOMAIN_MIN 0 0 0\nDOMAIN_MAX 1 1 1\n".into()),
        ("d-shift.cube", "DOMAIN_MIN -0.1 -0.1 -0.1\n".into()),
        ("d-mixed.cube", "DOMAIN_MAX 0.5 1 2\n".into()),
        ("d-range.cube", "LUT_1D_INPUT_RANGE -2 2\n".into()),
    ] {
        let params = parse_cube(&dir, name, &format!("LUT_1D_SIZE 2\n{line}0 0 0\n1 1 1\n"))
            .unwrap_or_else(|e| panic!("{name} must parse: {e}"));
        apply_lut(&dir, "domain-apply", &src, &params);
    }
}

// ----------------------------------------------------------------- memo --

/// The adjustment meta for a params object.
fn lut_meta(params: &Value) -> String {
    json!({"type": "adjust", "op": "color_lookup", "params": params}).to_string()
}

#[test]
fn the_memo_is_transparent_and_is_not_fooled_by_a_same_length_meta() {
    let dir = TempDir::new().unwrap();
    // A 33^3 table makes the meta about 575 KB, well over the 64 KiB
    // threshold at which `from_meta` consults the memo.
    let a_table = gamma_two_3d(33);
    let b_table = {
        // The same LENGTH — every base64 string of a 33^3 table is the same
        // size — but a completely different picture, so a memo that matched
        // on length or on a partial hash alone would be caught here.
        let mut t = Vec::with_capacity(33 * 33 * 33 * 3);
        for b in 0..33 {
            for g in 0..33 {
                for r in 0..33 {
                    let s = 32.0f32;
                    t.extend_from_slice(&[b as f32 / s, g as f32 / s, r as f32 / s]);
                }
            }
        }
        t
    };
    let a_meta = lut_meta(&lut_params("3d", 33, &a_table, &[]));
    let b_meta = lut_meta(&lut_params("3d", 33, &b_table, &[]));
    assert_eq!(
        a_meta.len(),
        b_meta.len(),
        "the two metas are the same size"
    );
    assert!(a_meta.len() > 64 * 1024, "and both take the memo path");
    assert_ne!(a_meta, b_meta);

    let backdrop = probe_row();
    let render = |tag: &str, meta: &str| -> Vec<u8> {
        let doc = doc_from(&dir, &format!("{tag}-bg.png"), &backdrop);
        let doc = add_layer(
            &dir,
            &format!("{tag}-top.png"),
            doc,
            0,
            &solid(1, 1, MAGENTA),
            "LUT",
        );
        let doc = set_meta(doc, 1, meta);
        assert!(unsafe { rz_doc_layer_is_adjustment(doc, 1) });
        let flat = flat_pixels(doc);
        unsafe { rz_doc_free(doc) };
        flat
    };

    // A: computed, then served from the memo, then served again after B has
    // evicted nothing (the memo holds two).
    let first = render("memo-a1", &a_meta);
    let second = render("memo-a2", &a_meta);
    assert_eq!(first, second, "the memo must be transparent");
    let other = render("memo-b", &b_meta);
    assert_ne!(
        first, other,
        "a DIFFERENT meta of the same length must not be confused for it"
    );
    let third = render("memo-a3", &a_meta);
    assert_eq!(first, third, "and A still parses to A afterwards");

    // The memoized result is the reference lookup, not merely self-consistent.
    for (i, px) in backdrop.pixels().enumerate() {
        let rgb = [
            f64::from(px[0]) / 255.0,
            f64::from(px[1]) / 255.0,
            f64::from(px[2]) / 255.0,
        ];
        let want = ref_lookup(&a_table, 33, true, ([0.0; 3], [1.0; 3]), 1.0, rgb);
        for c in 0..3 {
            let want_byte = (want[c].clamp(0.0, 1.0) * 255.0).round();
            assert!(
                (f64::from(first[i * 4 + c]) - want_byte).abs() <= 1.0,
                "pixel {i} channel {c}: {} vs {want_byte}",
                first[i * 4 + c]
            );
        }
        assert_eq!(first[i * 4 + 3], 255, "alpha untouched");
    }
}

/// A 3D table that scales every channel by `gain` — linear, so trilinear
/// interpolation reproduces it exactly and a stack of them composes to the
/// product of the gains.
fn gain_3d(n: usize, gain: f32) -> Vec<f32> {
    let s = (n - 1) as f32;
    let mut table = Vec::with_capacity(n * n * n * 3);
    for b in 0..n {
        for g in 0..n {
            for r in 0..n {
                table.extend_from_slice(&[
                    r as f32 / s * gain,
                    g as f32 / s * gain,
                    b as f32 / s * gain,
                ]);
            }
        }
    }
    table
}

/// The gains of the stack both memo tests build, chosen distinct so every
/// layer's meta is a different 575 KB string. More than the memo used to
/// hold, which is the whole point.
const STACK_GAINS: [f32; 5] = [0.9, 0.8, 0.7, 0.6, 0.5];

/// A document whose layer 0 is `backdrop` and whose layers 1..=n are Color
/// Lookup adjustment layers carrying `metas` bottom-first.
fn lut_stack(dir: &TempDir, tag: &str, backdrop: &RgbaImage, metas: &[String]) -> *mut RzDocument {
    let mut doc = doc_from(dir, &format!("{tag}-bg.png"), backdrop);
    for (i, meta) in metas.iter().enumerate() {
        doc = add_layer(
            dir,
            &format!("{tag}-lut{i}.png"),
            doc,
            i,
            &solid(1, 1, MAGENTA),
            "LUT",
        );
        doc = set_meta(doc, i + 1, meta);
        assert!(unsafe { rz_doc_layer_is_adjustment(doc, i + 1) });
    }
    doc
}

#[test]
fn a_stack_of_lut_layers_each_applies_its_own_table() {
    // Five DISTINCT 33^3 tables — more than the memo held when it was
    // introduced. Each one is a pure gain, so the stack composites to the
    // product of the gains and any confusion between two entries (a memo
    // that returned the wrong table, or an LRU reorder that lost one) shows
    // up as a wrong colour rather than merely as lost time.
    let dir = TempDir::new().unwrap();
    let metas: Vec<String> = STACK_GAINS
        .iter()
        .map(|g| lut_meta(&lut_params("3d", 33, &gain_3d(33, *g), &[])))
        .collect();
    for meta in &metas {
        assert!(meta.len() > 64 * 1024, "every meta takes the memo path");
    }
    let backdrop = probe_row();
    let doc = lut_stack(&dir, "stack", &backdrop, &metas);
    let first = flat_pixels(doc);
    // Composited AGAIN, which is what a render, an export, a thumbnail and
    // every live stroke tick each do: the second pass must agree with the
    // first exactly.
    let second = flat_pixels(doc);
    unsafe { rz_doc_free(doc) };
    assert_eq!(first, second, "the memo must be transparent across renders");

    let product: f64 = STACK_GAINS.iter().map(|g| f64::from(*g)).product();
    for (i, px) in backdrop.pixels().enumerate() {
        for c in 0..3 {
            let want = (f64::from(px[c]) / 255.0 * product).clamp(0.0, 1.0) * 255.0;
            assert!(
                (f64::from(first[i * 4 + c]) - want).abs() <= 1.0,
                "pixel {i} channel {c}: {} vs {want}",
                first[i * 4 + c]
            );
        }
        assert_eq!(first[i * 4 + 3], px[3], "alpha untouched");
    }
}

#[test]
fn the_memo_holds_a_whole_stack_of_lut_layers() {
    // The one property of the memo that is a NUMBER rather than a rule: it
    // must hold at least as many entries as one composite walks. Below
    // that, the entry evicted is always the one the next lookup wants —
    // the layers are visited in the same order every time — so every layer
    // re-parses its ~575 KB meta on every render and the memo is worse than
    // no memo at all.
    //
    // Timed RELATIVELY, against the same stack built from one meta repeated,
    // which any memo of one entry or more serves perfectly. Both stacks do
    // identical pixel work and make the same number of `from_meta` calls, so
    // the only difference measured is the parsing, and the bound needs no
    // idea of how fast the machine is. On a 4x1 canvas the pixel work is
    // negligible; at the capacity this test defends the ratio is ~1, and at
    // a capacity below the stack's depth it was ~20.
    let dir = TempDir::new().unwrap();
    let distinct: Vec<String> = STACK_GAINS
        .iter()
        .map(|g| lut_meta(&lut_params("3d", 33, &gain_3d(33, *g), &[])))
        .collect();
    let repeated = vec![distinct[0].clone(); distinct.len()];
    let backdrop = RgbaImage::from_pixel(4, 1, Rgba([200, 150, 120, 255]));
    let one = lut_stack(&dir, "memo-repeat", &backdrop, &repeated);
    let many = lut_stack(&dir, "memo-distinct", &backdrop, &distinct);
    // Warm both, so neither pays a first parse inside a timed loop.
    let _ = flat_pixels(one);
    let _ = flat_pixels(many);
    let time = |doc: *const RzDocument| {
        let start = std::time::Instant::now();
        for _ in 0..20 {
            let _ = flat_pixels(doc);
        }
        start.elapsed().as_secs_f64()
    };
    let repeated_secs = time(one);
    let distinct_secs = time(many);
    unsafe { rz_doc_free(one) };
    unsafe { rz_doc_free(many) };
    assert!(
        distinct_secs < repeated_secs * 8.0 + 0.05,
        "five DISTINCT LUT layers cost {distinct_secs:.4}s against {repeated_secs:.4}s for \
         five copies of one — the memo is evicting entries this composite still needs"
    );
}
