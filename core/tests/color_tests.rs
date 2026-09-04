//! Colour management: the ICC parser, the two profiles this build writes,
//! the 8-bit transform, and the document ops (assign, convert, adopt) as
//! seen through the public C FFI.
//!
//! Oracles are analytic and written HERE, independently of the
//! implementation: the ICC byte layout is assembled by this file's own
//! builder rather than the core's; the D50-adapted matrix columns are
//! recomputed from the published xy primaries through the Bradford
//! adaptation in f64; the sRGB transfer function is written out from the IEC
//! definition; and the reference conversion is a from-first-principles
//! decode / matrix / encode with no shared code at all. The one external
//! number is the Display P3 -> sRGB anchor, obtained from littleCMS through
//! Apple's own `Display P3.icc`. No golden images anywhere, and no profile
//! is read off this machine — every fixture is built from bytes this file
//! writes.

use std::ffi::{c_char, c_int};
use std::ptr;

use image::RgbaImage;
use rasterize_core::doc::RzDocument;
use rasterize_core::ffi::*;
use rasterize_core::ffi_channel::*;
use rasterize_core::ffi_color::*;
use rasterize_core::ffi_doc::*;
use rasterize_core::icc::{inspect, IccProfile, Inspect};
use rasterize_core::icc_transform::{MatrixTrc, Transform};
use tempfile::TempDir;

mod common;
use common::*;

/// Mirrored from the header, like the BLEND_* constants in `tests/common`.
const PROFILE_SRGB: c_int = 0;
const PROFILE_DISPLAY_P3: c_int = 1;
const ICC_NOT_ICC: c_int = 0;
const ICC_NOT_RGB: c_int = 1;
const ICC_RGB_UNCONVERTIBLE: c_int = 2;
const ICC_RGB_MATRIX: c_int = 3;
const ICC_NOT_IMAGE_PROFILE: c_int = 4;
const ADOPT_UNCHANGED: c_int = 0;
const ADOPT_CONVERTED: c_int = 1;
const ADOPT_KEPT_UNCONVERTIBLE: c_int = 2;

// ------------------------------------------------- an ICC builder of ours --

/// Assembles an ICC v2.1.0 profile from a data colour space and a tag list:
/// 128-byte header, u32 tag count, the 12-byte entries, then the tag data,
/// each blob padded to a 4-byte boundary with identical blobs shared. This
/// is deliberately a SECOND implementation of the layout — if it and the
/// core's builder ever disagree, one of them is wrong.
fn build_profile(space: &[u8; 4], tags: &[(&[u8; 4], Vec<u8>)]) -> Vec<u8> {
    build_profile_class(b"mntr", space, tags)
}

/// [`build_profile`] with the profile CLASS spelled out (header bytes
/// 12..16), for the classes that carry RGB numbers without describing a
/// space a picture's pixels live in.
fn build_profile_class(class: &[u8; 4], space: &[u8; 4], tags: &[(&[u8; 4], Vec<u8>)]) -> Vec<u8> {
    let payload_start = 132 + 12 * tags.len();
    let mut table = Vec::new();
    let mut payload: Vec<u8> = Vec::new();
    let mut placed: Vec<(Vec<u8>, u32)> = Vec::new();
    for (sig, data) in tags {
        let offset = match placed.iter().find(|(seen, _)| seen == data) {
            Some((_, off)) => *off,
            None => {
                let off = (payload_start + payload.len()) as u32;
                payload.extend_from_slice(data);
                while !payload.len().is_multiple_of(4) {
                    payload.push(0);
                }
                placed.push((data.clone(), off));
                off
            }
        };
        table.extend_from_slice(sig.as_slice());
        table.extend_from_slice(&offset.to_be_bytes());
        table.extend_from_slice(&(data.len() as u32).to_be_bytes());
    }
    let total = (payload_start + payload.len()) as u32;
    let mut out = vec![0u8; 128];
    out[0..4].copy_from_slice(&total.to_be_bytes());
    out[8..12].copy_from_slice(&[0x02, 0x10, 0x00, 0x00]);
    out[12..16].copy_from_slice(class);
    out[16..20].copy_from_slice(space);
    out[20..24].copy_from_slice(b"XYZ ");
    out[36..40].copy_from_slice(b"acsp");
    for (i, v) in D50_RAW.iter().enumerate() {
        out[68 + 4 * i..72 + 4 * i].copy_from_slice(&v.to_be_bytes());
    }
    out.extend_from_slice(&(tags.len() as u32).to_be_bytes());
    out.extend_from_slice(&table);
    out.extend_from_slice(&payload);
    out
}

/// The D50 PCS illuminant as s15Fixed16, from the ICC spec's 0.9642 / 1.0 /
/// 0.8249.
const D50_RAW: [i32; 3] = [0x0000_F6D6, 0x0001_0000, 0x0000_D32D];

fn fixed(v: f64) -> i32 {
    (v * 65536.0).round() as i32
}

fn tag_xyz(v: [f64; 3]) -> Vec<u8> {
    let mut t = b"XYZ \0\0\0\0".to_vec();
    for c in v {
        t.extend_from_slice(&fixed(c).to_be_bytes());
    }
    t
}

fn tag_curv_identity() -> Vec<u8> {
    let mut t = b"curv\0\0\0\0".to_vec();
    t.extend_from_slice(&0u32.to_be_bytes());
    t
}

/// `curv` with a single u8Fixed8 entry: the gamma a real profile can
/// actually store (2.2 becomes 0x0233 = 2.19921875, not 2.2).
fn tag_curv_gamma(raw: u16) -> Vec<u8> {
    let mut t = b"curv\0\0\0\0".to_vec();
    t.extend_from_slice(&1u32.to_be_bytes());
    t.extend_from_slice(&raw.to_be_bytes());
    t
}

fn tag_curv_table(table: &[u16]) -> Vec<u8> {
    let mut t = b"curv\0\0\0\0".to_vec();
    t.extend_from_slice(&(table.len() as u32).to_be_bytes());
    for v in table {
        t.extend_from_slice(&v.to_be_bytes());
    }
    t
}

fn tag_para(kind: u16, params: &[f64]) -> Vec<u8> {
    let mut t = b"para\0\0\0\0".to_vec();
    t.extend_from_slice(&kind.to_be_bytes());
    t.extend_from_slice(&[0, 0]);
    for p in params {
        t.extend_from_slice(&fixed(*p).to_be_bytes());
    }
    t
}

/// `textDescriptionType`. With `tail` false the tag stops right after the
/// ASCII string — the truncated shape real profiles ship and a reader must
/// still name.
fn tag_desc(name: &str, tail: bool) -> Vec<u8> {
    let mut t = b"desc\0\0\0\0".to_vec();
    t.extend_from_slice(&((name.len() + 1) as u32).to_be_bytes());
    t.extend_from_slice(name.as_bytes());
    t.push(0);
    if tail {
        t.extend_from_slice(&[0; 4]);
        t.extend_from_slice(&[0; 4]);
        t.extend_from_slice(&[0; 2]);
        t.push(0);
        t.extend_from_slice(&[0; 67]);
    }
    t
}

/// `multiLocalizedUnicodeType`, one 'enUS' record of UTF-16BE.
fn tag_mluc(name: &str) -> Vec<u8> {
    let utf16: Vec<u16> = name.encode_utf16().collect();
    let mut t = b"mluc\0\0\0\0".to_vec();
    t.extend_from_slice(&1u32.to_be_bytes());
    t.extend_from_slice(&12u32.to_be_bytes());
    t.extend_from_slice(b"enUS");
    t.extend_from_slice(&((utf16.len() * 2) as u32).to_be_bytes());
    t.extend_from_slice(&28u32.to_be_bytes());
    for u in utf16 {
        t.extend_from_slice(&u.to_be_bytes());
    }
    t
}

/// Locates a tag's data in a profile, walking the table by hand.
fn find_tag<'a>(profile: &'a [u8], sig: &[u8; 4]) -> Option<&'a [u8]> {
    let count = be32(profile, 128) as usize;
    (0..count).find_map(|i| {
        let e = 132 + 12 * i;
        (&profile[e..e + 4] == sig.as_slice()).then(|| {
            let off = be32(profile, e + 4) as usize;
            let size = be32(profile, e + 8) as usize;
            &profile[off..off + size]
        })
    })
}

fn be32(b: &[u8], at: usize) -> u32 {
    u32::from_be_bytes(b[at..at + 4].try_into().unwrap())
}

// ------------------------------------------ the colour oracle, in f64 here --

type Mat = [[f64; 3]; 3];

fn mat_mul(a: Mat, b: Mat) -> Mat {
    let mut out = [[0.0; 3]; 3];
    for (i, row) in out.iter_mut().enumerate() {
        for (j, v) in row.iter_mut().enumerate() {
            *v = (0..3).map(|k| a[i][k] * b[k][j]).sum();
        }
    }
    out
}

fn mat_vec(a: Mat, v: [f64; 3]) -> [f64; 3] {
    let mut out = [0.0; 3];
    for (i, o) in out.iter_mut().enumerate() {
        *o = (0..3).map(|k| a[i][k] * v[k]).sum();
    }
    out
}

fn inv3(m: Mat) -> Mat {
    let det = m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1])
        - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
        + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0]);
    let mut out = [[0.0; 3]; 3];
    for (r, row) in out.iter_mut().enumerate() {
        for (c, v) in row.iter_mut().enumerate() {
            let (r0, r1) = ((c + 1) % 3, (c + 2) % 3);
            let (c0, c1) = ((r + 1) % 3, (r + 2) % 3);
            *v = (m[r0][c0] * m[r1][c1] - m[r0][c1] * m[r1][c0]) / det;
        }
    }
    out
}

/// The Bradford cone response matrix, from the CIE literature.
const BRADFORD: Mat = [
    [0.8951, 0.2664, -0.1614],
    [-0.7502, 1.7135, 0.0367],
    [0.0389, -0.0685, 1.0296],
];

fn xy_to_xyz(x: f64, y: f64) -> [f64; 3] {
    [x / y, 1.0, (1.0 - x - y) / y]
}

/// `A = M^-1 · diag(M·Wd / M·Ws) · M` — the standard von Kries adaptation.
fn adaptation(ws: [f64; 3], wd: [f64; 3]) -> Mat {
    let s = mat_vec(BRADFORD, ws);
    let d = mat_vec(BRADFORD, wd);
    let scale = [
        [d[0] / s[0], 0.0, 0.0],
        [0.0, d[1] / s[1], 0.0],
        [0.0, 0.0, d[2] / s[2]],
    ];
    mat_mul(inv3(BRADFORD), mat_mul(scale, BRADFORD))
}

/// The D50-adapted RGB -> XYZ matrix for a set of xy primaries under D65.
fn d50_matrix(primaries: [(f64, f64); 3]) -> Mat {
    let d50 = [0.9642, 1.0, 0.8249];
    let d65 = xy_to_xyz(0.3127, 0.3290);
    let cols: Vec<[f64; 3]> = primaries.iter().map(|&(x, y)| xy_to_xyz(x, y)).collect();
    let basis = [
        [cols[0][0], cols[1][0], cols[2][0]],
        [cols[0][1], cols[1][1], cols[2][1]],
        [cols[0][2], cols[1][2], cols[2][2]],
    ];
    let scale = mat_vec(inv3(basis), d65);
    let mut native = [[0.0; 3]; 3];
    for (i, row) in native.iter_mut().enumerate() {
        for (j, v) in row.iter_mut().enumerate() {
            *v = basis[i][j] * scale[j];
        }
    }
    mat_mul(adaptation(d65, d50), native)
}

const SRGB_PRIMARIES: [(f64, f64); 3] = [(0.6400, 0.3300), (0.3000, 0.6000), (0.1500, 0.0600)];
const P3_PRIMARIES: [(f64, f64); 3] = [(0.6800, 0.3200), (0.2650, 0.6900), (0.1500, 0.0600)];

/// The IEC 61966-2.1 transfer function, encoded -> linear, written out from
/// the definition.
fn srgb_decode(x: f64) -> f64 {
    if x <= 0.04045 {
        x / 12.92
    } else {
        ((x + 0.055) / 1.055).powf(2.4)
    }
}

/// Its inverse, linear -> encoded.
fn srgb_encode(y: f64) -> f64 {
    let y = y.clamp(0.0, 1.0);
    if y <= 0.003_130_8 {
        12.92 * y
    } else {
        1.055 * y.powf(1.0 / 2.4) - 0.055
    }
}

/// The 1024-entry `curv` table both built-ins carry, recomputed here.
fn iec_trc_table() -> Vec<u16> {
    (0..1024)
        .map(|i| (srgb_decode(f64::from(i) / 1023.0) * 65535.0).round() as u16)
        .collect()
}

/// The reference conversion: decode, matrix, encode, all in f64 from first
/// principles.
fn reference_convert(px: [u8; 3], src: Mat, dst: Mat) -> [u8; 3] {
    let lin = [
        srgb_decode(f64::from(px[0]) / 255.0),
        srgb_decode(f64::from(px[1]) / 255.0),
        srgb_decode(f64::from(px[2]) / 255.0),
    ];
    let out = mat_vec(mat_mul(inv3(dst), src), lin);
    let mut result = [0u8; 3];
    for (o, v) in result.iter_mut().zip(out) {
        *o = (srgb_encode(v) * 255.0).round() as u8;
    }
    result
}

// ------------------------------------------------------ fixture profiles --

/// A complete RGB matrix/TRC profile with the given columns and one TRC tag
/// body shared by all three channels.
fn matrix_profile(name: &str, cols: Mat, trc: Vec<u8>) -> Vec<u8> {
    build_profile(
        b"RGB ",
        &[
            (b"desc", tag_desc(name, true)),
            (b"wtpt", tag_xyz([0.9642, 1.0, 0.8249])),
            (b"rXYZ", tag_xyz([cols[0][0], cols[1][0], cols[2][0]])),
            (b"gXYZ", tag_xyz([cols[0][1], cols[1][1], cols[2][1]])),
            (b"bXYZ", tag_xyz([cols[0][2], cols[1][2], cols[2][2]])),
            (b"rTRC", trc.clone()),
            (b"gTRC", trc.clone()),
            (b"bTRC", trc),
        ],
    )
}

fn parsed(bytes: &[u8]) -> IccProfile {
    IccProfile::parse(bytes).expect("a well-formed RGB profile")
}

fn model_of(bytes: &[u8]) -> MatrixTrc {
    parsed(bytes).model().expect("a matrix/TRC profile").clone()
}

/// Runs the FULL pipeline (no equivalence fast path) over one pixel.
fn convert_pixel(src: &MatrixTrc, dst: &MatrixTrc, px: [u8; 3]) -> [u8; 3] {
    let mut image = RgbaImage::from_pixel(1, 1, image::Rgba([px[0], px[1], px[2], 200]));
    Transform::new(src, dst).apply(&mut image);
    let out = image.get_pixel(0, 0).0;
    assert_eq!(out[3], 200, "alpha is copied untouched");
    [out[0], out[1], out[2]]
}

fn builtin_bytes(which: c_int) -> Vec<u8> {
    let len = rz_builtin_profile_len(which);
    let mut out = vec![0u8; len];
    assert!(unsafe { rz_builtin_profile(which, out.as_mut_ptr(), len) });
    out
}

// ----------------------------------------------- the profiles we can write --

#[test]
fn builtin_profiles_are_well_formed_icc() {
    for which in [PROFILE_SRGB, PROFILE_DISPLAY_P3] {
        let p = builtin_bytes(which);
        assert_eq!(
            be32(&p, 0) as usize,
            p.len(),
            "the size field is the byte count"
        );
        assert_eq!(p.len() % 4, 0, "the profile is 4-aligned");
        assert_eq!(&p[8..12], &[0x02, 0x10, 0x00, 0x00], "ICC v2.1.0");
        assert_eq!(&p[12..16], b"mntr");
        assert_eq!(&p[16..20], b"RGB ");
        assert_eq!(&p[20..24], b"XYZ ");
        assert_eq!(&p[36..40], b"acsp", "the magic");
        for (i, v) in D50_RAW.iter().enumerate() {
            assert_eq!(
                be32(&p, 68 + 4 * i) as i32,
                *v,
                "the PCS illuminant is D50, fixed by spec"
            );
        }
        assert_eq!(be32(&p, 128), 10, "ten tags");
        let mut trc_offsets = Vec::new();
        for i in 0..10 {
            let e = 132 + 12 * i;
            let off = be32(&p, e + 4) as usize;
            let size = be32(&p, e + 8) as usize;
            assert_eq!(off % 4, 0, "tag {i} is 4-aligned");
            assert!(off + size <= p.len(), "tag {i} is inside the profile");
            if p[e..e + 4].ends_with(b"TRC") {
                trc_offsets.push(off);
            }
        }
        assert_eq!(trc_offsets.len(), 3);
        assert!(
            trc_offsets.iter().all(|o| *o == trc_offsets[0]),
            "the three TRC tags share one blob, as both Apple profiles do"
        );
        for sig in [
            b"desc", b"cprt", b"wtpt", b"rXYZ", b"gXYZ", b"bXYZ", b"chad",
        ] {
            assert!(find_tag(&p, sig).is_some(), "tag {:?} present", sig);
        }
    }
}

#[test]
fn builtin_profile_bytes_are_stable() {
    for which in [PROFILE_SRGB, PROFILE_DISPLAY_P3] {
        assert_eq!(
            builtin_bytes(which),
            builtin_bytes(which),
            "two calls produce the same bytes"
        );
    }
    // The creation date is a constant, never `now()`: without it a save
    // would not reproduce its own file.
    let p = builtin_bytes(PROFILE_SRGB);
    assert_eq!(
        &p[24..36],
        &[0x07, 0xEA, 0, 1, 0, 1, 0, 0, 0, 0, 0, 0],
        "2026-01-01T00:00:00Z, a constant"
    );
}

#[test]
fn builtin_matrix_columns_match_the_published_primaries() {
    for (which, primaries) in [
        (PROFILE_SRGB, SRGB_PRIMARIES),
        (PROFILE_DISPLAY_P3, P3_PRIMARIES),
    ] {
        let p = builtin_bytes(which);
        let expected = d50_matrix(primaries);
        for (col, sig) in [b"rXYZ", b"gXYZ", b"bXYZ"].iter().enumerate() {
            let data = find_tag(&p, sig).expect("column tag");
            for (row, want_row) in expected.iter().enumerate() {
                let raw = be32(data, 8 + 4 * row) as i32;
                let want = fixed(want_row[col]);
                assert!(
                    (raw - want).abs() <= 2,
                    "{sig:?}[{row}]: {raw} vs {want} (recomputed from the primaries)"
                );
            }
        }
        // `chad` is advisory — this library's reader ignores it — which is
        // why a couple of raw units either way is fine: Apple's own file
        // differs from this one by exactly that much in three entries.
        let chad = find_tag(&p, b"chad").expect("chad");
        let expected = adaptation(xy_to_xyz(0.3127, 0.3290), [0.9642, 1.0, 0.8249]);
        for (row, want_row) in expected.iter().enumerate() {
            for (col, want) in want_row.iter().enumerate() {
                let raw = be32(chad, 8 + 4 * (3 * row + col)) as i32;
                assert!((raw - fixed(*want)).abs() <= 2, "chad[{row}][{col}]");
            }
        }
    }
}

#[test]
fn builtin_trc_is_the_iec_curve() {
    let table = iec_trc_table();
    for which in [PROFILE_SRGB, PROFILE_DISPLAY_P3] {
        let p = builtin_bytes(which);
        let trc = find_tag(&p, b"rTRC").expect("rTRC");
        assert_eq!(&trc[0..4], b"curv");
        assert_eq!(be32(trc, 8), 1024, "1024 entries, as Apple's own sRGB has");
        for (i, want) in table.iter().enumerate() {
            let got = u16::from_be_bytes([trc[12 + 2 * i], trc[13 + 2 * i]]);
            assert_eq!(got, *want, "entry {i}");
        }
        // Anchors a reviewer can check by hand.
        for (i, want) in [
            (0, 0u16),
            (1, 5),
            (2, 10),
            (256, 3341),
            (512, 14057),
            (1023, 65535),
        ] {
            assert_eq!(table[i], want, "anchor {i}");
        }
    }
}

#[test]
fn parsing_our_own_profiles_round_trips() {
    for (bytes, direct) in [
        (builtin_bytes(PROFILE_SRGB), IccProfile::srgb()),
        (builtin_bytes(PROFILE_DISPLAY_P3), IccProfile::display_p3()),
    ] {
        let reparsed = parsed(&bytes);
        assert!(
            reparsed
                .model()
                .expect("matrix/TRC")
                .approx_eq(direct.model().expect("matrix/TRC")),
            "the blob and the model come from the same constants"
        );
        assert_eq!(reparsed.name(), direct.name());
    }
    assert_eq!(
        parsed(&builtin_bytes(PROFILE_SRGB)).name(),
        "sRGB IEC61966-2.1"
    );
    assert_eq!(
        parsed(&builtin_bytes(PROFILE_DISPLAY_P3)).name(),
        "Display P3"
    );
}

// -------------------------------------------------------- the transform --

#[test]
fn identity_is_exact_for_every_curve_kind() {
    let cols = d50_matrix(SRGB_PRIMARIES);
    // The sRGB `para` curve, the two pure gammas a real profile stores, the
    // exact gammas a `para` type 0 can state, a sampled table and the linear
    // curve. The gamma cases are the regression for the inverse table this
    // encoder replaced: it turned code 3 into code 1 at gamma 2.2 and 2.4.
    let curves: [(&str, Vec<u8>); 7] = [
        ("curv 1024", tag_curv_table(&iec_trc_table())),
        (
            "para sRGB",
            tag_para(3, &[2.4, 1.0 / 1.055, 0.055 / 1.055, 1.0 / 12.92, 0.04045]),
        ),
        ("curv gamma 2.19921875", tag_curv_gamma(0x0233)),
        ("curv gamma 1.80078125", tag_curv_gamma(0x01CD)),
        ("para gamma 2.2", tag_para(0, &[2.2])),
        ("para gamma 1.8", tag_para(0, &[1.8])),
        ("curv identity", tag_curv_identity()),
    ];
    for (name, trc) in curves {
        let model = model_of(&matrix_profile(name, cols, trc));
        for v in 0..=255u8 {
            for channel in 0..3 {
                let mut px = [0u8; 3];
                px[channel] = v;
                let out = convert_pixel(&model, &model, px);
                assert_eq!(
                    out, px,
                    "{name}: channel {channel} value {v} must survive exactly"
                );
            }
        }
        // The codes the deleted inverse table got wrong, called out.
        for v in [0u8, 1, 2, 3, 255] {
            assert_eq!(
                convert_pixel(&model, &model, [v, v, v]),
                [v, v, v],
                "{name}"
            );
        }
    }
}

#[test]
fn srgb_to_display_p3_matches_an_analytic_reference() {
    let src = model_of(&builtin_bytes(PROFILE_SRGB));
    let dst = model_of(&builtin_bytes(PROFILE_DISPLAY_P3));
    let ref_src = d50_matrix(SRGB_PRIMARIES);
    let ref_dst = d50_matrix(P3_PRIMARIES);

    let mut worst = 0i32;
    let mut total = 0i64;
    let mut count = 0i64;
    let grid: Vec<u8> = (0..17).map(|i| (i * 255 / 16) as u8).collect();
    for &r in &grid {
        for &g in &grid {
            for &b in &grid {
                let got = convert_pixel(&src, &dst, [r, g, b]);
                let want = reference_convert([r, g, b], ref_src, ref_dst);
                for i in 0..3 {
                    let d = i32::from(got[i]) - i32::from(want[i]);
                    worst = worst.max(d.abs());
                    total += i64::from(d.abs());
                    count += 1;
                }
            }
        }
    }
    assert!(worst <= 1, "max |delta| was {worst} code values");
    let mean = total as f64 / count as f64;
    assert!(mean <= 0.25, "mean |delta| was {mean} code values");

    // Anchors, computed in f64 and reproducible by hand.
    for (input, expected) in [
        ([128u8, 64, 32], [120u8, 67, 39]),
        ([255, 0, 0], [234, 51, 35]),
        ([0, 255, 0], [117, 251, 76]),
        ([0, 0, 255], [0, 0, 245]),
        ([255, 128, 0], [239, 135, 51]),
        ([200, 150, 100], [192, 152, 107]),
        ([0, 0, 0], [0, 0, 0]),
        ([255, 255, 255], [255, 255, 255]),
    ] {
        assert_eq!(convert_pixel(&src, &dst, input), expected, "{input:?}");
    }
}

#[test]
fn display_p3_to_srgb_matches_the_littlecms_anchor() {
    let src = model_of(&builtin_bytes(PROFILE_DISPLAY_P3));
    let dst = model_of(&builtin_bytes(PROFILE_SRGB));
    // Obtained INDEPENDENTLY, from littleCMS through Apple's own
    // Display P3.icc: this pins the direction of the matrix, not merely the
    // pipeline's self-consistency.
    assert_eq!(convert_pixel(&src, &dst, [128, 64, 32]), [138, 59, 21]);
}

#[test]
fn an_hp_shaped_srgb_is_equivalent_to_ours() {
    // The columns macOS's shipped sRGB Profile.icc carries — the HP/IEC 1998
    // rounding, 1.83e-4 away from this build's ENTRYWISE, which is why the
    // equivalence test compares the COMBINED matrix (2.585e-4 from the
    // identity) instead. It also has NO chad tag and a wtpt holding the
    // unadapted D65, which is what pins the "PCS white is always D50" rule.
    let hp = build_profile(
        b"RGB ",
        &[
            (b"desc", tag_desc("sRGB IEC61966-2.1", true)),
            (b"wtpt", tag_xyz([0.950455, 1.0, 1.089050])),
            (b"rXYZ", tag_xyz([0.436066, 0.222488, 0.013916])),
            (b"gXYZ", tag_xyz([0.385147, 0.716873, 0.097076])),
            (b"bXYZ", tag_xyz([0.143066, 0.060608, 0.714096])),
            (b"rTRC", tag_curv_table(&iec_trc_table())),
            (b"gTRC", tag_curv_table(&iec_trc_table())),
            (b"bTRC", tag_curv_table(&iec_trc_table())),
        ],
    );
    let theirs = model_of(&hp);
    let ours = model_of(&builtin_bytes(PROFILE_SRGB));
    assert!(
        theirs.approx_eq(&ours) && ours.approx_eq(&theirs),
        "the world's most common tagged file must take the Unchanged branch"
    );
    // And converting anyway (the fast path bypassed) moves nothing.
    for v in [0u8, 1, 7, 64, 128, 200, 255] {
        let out = convert_pixel(&theirs, &ours, [v, v / 2, 255 - v]);
        let want = [v, v / 2, 255 - v];
        for i in 0..3 {
            assert!(
                (i32::from(out[i]) - i32::from(want[i])).abs() <= 1,
                "{out:?} vs {want:?}"
            );
        }
    }
}

// ------------------------------------------------ classification and names --

#[test]
fn a_gray_or_cmyk_profile_is_refused_and_a_lut_profile_is_kept() {
    let dir = TempDir::new().unwrap();
    let doc = doc_from(&dir, "c.png", &opaque_pattern(4, 3));

    let gray = build_profile(b"GRAY", &[(b"desc", tag_desc("Some Gray", true))]);
    let cmyk = build_profile(b"CMYK", &[(b"desc", tag_desc("Some CMYK", true))]);
    for (bytes, label) in [(&gray, "gray"), (&cmyk, "cmyk")] {
        let mut name: *mut c_char = ptr::null_mut();
        let kind = unsafe { rz_icc_inspect(bytes.as_ptr(), bytes.len(), &mut name) };
        assert_eq!(kind, ICC_NOT_RGB, "{label}");
        assert!(!name.is_null(), "a non-RGB profile still has a name");
        unsafe { rz_string_free(name) };
        assert!(
            unsafe { rz_doc_assign_profile(doc, bytes.as_ptr(), bytes.len()) }.is_null(),
            "{label} must never be stored"
        );
    }

    // An RGB profile with a LUT and no matrix tags: kept, but not
    // convertible.
    let lut = build_profile(
        b"RGB ",
        &[
            (b"desc", tag_desc("LUT RGB", true)),
            (
                b"A2B0",
                vec![b'm', b'f', b't', b'2', 0, 0, 0, 0, 3, 3, 0, 0],
            ),
        ],
    );
    let mut name: *mut c_char = ptr::null_mut();
    assert_eq!(
        unsafe { rz_icc_inspect(lut.as_ptr(), lut.len(), &mut name) },
        ICC_RGB_UNCONVERTIBLE
    );
    unsafe { rz_string_free(name) };
    let kept = unsafe { rz_doc_assign_profile(doc, lut.as_ptr(), lut.len()) };
    assert!(!kept.is_null(), "a LUT RGB profile IS stored");
    assert!(
        !unsafe { rz_doc_profile_is_convertible(kept) },
        "but it cannot be converted from"
    );
    let srgb = builtin_bytes(PROFILE_SRGB);
    assert!(
        unsafe { rz_doc_convert_to_profile(kept, srgb.as_ptr(), srgb.len()) }.is_null(),
        "convert refuses, with no error string anywhere"
    );
    // And it round-trips out byte-for-byte, which is what re-embedding needs.
    let len = unsafe { rz_doc_icc_profile_len(kept) };
    assert_eq!(len, lut.len());
    let mut back = vec![0u8; len];
    assert!(unsafe { rz_doc_icc_profile(kept, back.as_mut_ptr(), len) });
    assert_eq!(back, lut);

    let matrix = builtin_bytes(PROFILE_DISPLAY_P3);
    let mut name: *mut c_char = ptr::null_mut();
    assert_eq!(
        unsafe { rz_icc_inspect(matrix.as_ptr(), matrix.len(), &mut name) },
        ICC_RGB_MATRIX
    );
    unsafe { rz_string_free(name) };
    assert_eq!(
        unsafe { rz_icc_inspect(b"not a profile".as_ptr(), 13, ptr::null_mut()) },
        ICC_NOT_ICC
    );

    unsafe {
        rz_doc_free(kept);
        rz_doc_free(doc);
    }
}

#[test]
fn a_truncated_desc_tail_still_names_the_profile() {
    let cols = d50_matrix(SRGB_PRIMARIES);
    // A `desc` sized exactly 12 + count, with no Macintosh tail at all.
    let bytes = build_profile(
        b"RGB ",
        &[
            (b"desc", tag_desc("Truncated Tail", false)),
            (b"rXYZ", tag_xyz([cols[0][0], cols[1][0], cols[2][0]])),
            (b"gXYZ", tag_xyz([cols[0][1], cols[1][1], cols[2][1]])),
            (b"bXYZ", tag_xyz([cols[0][2], cols[1][2], cols[2][2]])),
            (b"rTRC", tag_curv_identity()),
            (b"gTRC", tag_curv_identity()),
            (b"bTRC", tag_curv_identity()),
        ],
    );
    assert_eq!(parsed(&bytes).name(), "Truncated Tail");

    // The v4 shape, and a plain textType, are named too.
    let mluc = build_profile(b"RGB ", &[(b"desc", tag_mluc("Wide Gamut"))]);
    assert_eq!(parsed(&mluc).name(), "Wide Gamut");
    let text = build_profile(b"RGB ", &[(b"desc", b"text\0\0\0\0Plain Name\0".to_vec())]);
    assert_eq!(parsed(&text).name(), "Plain Name");
    let none = build_profile(b"RGB ", &[(b"cprt", b"text\0\0\0\0x\0".to_vec())]);
    assert_eq!(parsed(&none).name(), "Untitled profile");
}

#[test]
fn crafted_profiles_never_panic() {
    let good = builtin_bytes(PROFILE_DISPLAY_P3);
    let mut cases: Vec<Vec<u8>> = vec![Vec::new(), vec![0, 0, 0, 0], b"acsp".to_vec()];
    // A size field of u32::MAX, and a tag count of u32::MAX.
    let mut huge = good.clone();
    huge[0..4].copy_from_slice(&u32::MAX.to_be_bytes());
    cases.push(huge);
    let mut tags = good.clone();
    tags[128..132].copy_from_slice(&u32::MAX.to_be_bytes());
    cases.push(tags);
    // A tag offset past the buffer, and an unaligned one.
    let mut past = good.clone();
    past[136..140].copy_from_slice(&(good.len() as u32 + 4096).to_be_bytes());
    cases.push(past);
    let mut odd = good.clone();
    odd[136..140].copy_from_slice(&253u32.to_be_bytes());
    cases.push(odd);
    // A `curv` count that overflows its tag, a `para` type 9, and a `desc`
    // whose ASCII count runs past the tag.
    let cols = d50_matrix(SRGB_PRIMARIES);
    let mut fat_curv = b"curv\0\0\0\0".to_vec();
    fat_curv.extend_from_slice(&u32::MAX.to_be_bytes());
    cases.push(matrix_profile("fat", cols, fat_curv));
    cases.push(matrix_profile("para9", cols, tag_para(9, &[1.0])));
    let mut bad_desc = b"desc\0\0\0\0".to_vec();
    bad_desc.extend_from_slice(&u32::MAX.to_be_bytes());
    cases.push(build_profile(b"RGB ", &[(b"desc", bad_desc)]));
    let mut bad_mluc = tag_mluc("x");
    bad_mluc[24..28].copy_from_slice(&u32::MAX.to_be_bytes());
    cases.push(build_profile(b"RGB ", &[(b"desc", bad_mluc)]));
    // Two tags pointing at the same blob, which is LEGAL and must parse.
    cases.push(good.clone());
    // 200 pseudo-random truncations and byte flips of a real profile.
    let mut seed = 0x2026_0904u64;
    let mut next = move || {
        seed = seed.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(1);
        (seed >> 33) as usize
    };
    for _ in 0..200 {
        let cut = next() % good.len();
        cases.push(good[..cut].to_vec());
        let mut flipped = good.clone();
        let at = next() % good.len();
        flipped[at] ^= 0xFF;
        cases.push(flipped);
    }
    for bytes in &cases {
        let mut name = String::new();
        let kind = inspect(bytes, &mut name);
        let parsed = IccProfile::parse(bytes);
        match kind {
            Inspect::NotIcc | Inspect::NotRgb | Inspect::NotImageProfile => {
                assert!(parsed.is_none())
            }
            Inspect::RgbUnconvertible => {
                assert!(parsed.expect("kept").model().is_none());
            }
            Inspect::RgbMatrix => {
                assert!(parsed.expect("kept").model().is_some());
            }
        }
        // And through the FFI, where a panic would become a NULL rather than
        // an abort.
        let mut name_out: *mut c_char = ptr::null_mut();
        unsafe {
            rz_icc_inspect(bytes.as_ptr(), bytes.len(), &mut name_out);
            rz_string_free(name_out);
        }
    }
}

// -------------------------------------------------------- document ops --

/// A two-layer document with a mask, a channel and layer meta, so a convert
/// can be checked for what it must NOT touch.
fn color_fixture(dir: &TempDir) -> *mut RzDocument {
    let doc = doc_from(dir, "base.png", &opaque_pattern(6, 4));
    let doc = add_layer(
        dir,
        "top.png",
        doc,
        0,
        &solid(6, 4, [200, 90, 30, 180]),
        "Top",
    );
    let doc = apply(doc, |d| unsafe {
        rz_doc_adding_layer_mask(d, 1, MASK_HIDE_ALL, ptr::null(), 0, 0)
    });
    let name = std::ffi::CString::new("Saved").unwrap();
    let plane = [128u8; 24];
    let doc = apply(doc, |d| unsafe {
        rz_doc_add_channel(d, name.as_ptr(), plane.as_ptr(), 6, 4, 255, 0, 0, 0.5)
    });
    let meta = std::ffi::CString::new("{\"note\":\"keep me\"}").unwrap();
    apply(doc, |d| unsafe {
        rz_doc_with_layer_meta(d, 1, meta.as_ptr())
    })
}

fn plane_of(doc: *const RzDocument, i: usize) -> Vec<u8> {
    let mut out = vec![0u8; 24];
    assert!(unsafe { rz_doc_channel_plane(doc, i, out.as_mut_ptr(), 6, 4) });
    out
}

fn mask_of(doc: *const RzDocument, idx: usize) -> Vec<u8> {
    let img = unsafe { rz_doc_layer_mask_image(doc, idx) };
    assert!(!img.is_null());
    let v = img_pixels(img);
    unsafe { rz_image_free(img) };
    v
}

#[test]
fn assign_changes_no_pixel_and_convert_changes_them() {
    let dir = TempDir::new().unwrap();
    let doc = color_fixture(&dir);
    let before = flat_pixels(doc);
    let p3 = builtin_bytes(PROFILE_DISPLAY_P3);

    let assigned = unsafe { rz_doc_assign_profile(doc, p3.as_ptr(), p3.len()) };
    assert!(!assigned.is_null());
    assert_eq!(flat_pixels(assigned), before, "assign touches no pixel");
    let name = unsafe { rz_doc_profile_name(assigned) };
    assert_eq!(
        unsafe { std::ffi::CStr::from_ptr(name) }.to_str().unwrap(),
        "Display P3"
    );
    unsafe { rz_string_free(name) };

    let converted = unsafe { rz_doc_convert_to_profile(doc, p3.as_ptr(), p3.len()) };
    assert!(!converted.is_null());
    assert_ne!(flat_pixels(converted), before, "convert moves the numbers");
    assert_eq!(
        mask_of(converted, 1),
        mask_of(doc, 1),
        "a layer mask is coverage, not colour"
    );
    assert_eq!(
        plane_of(converted, 0),
        plane_of(doc, 0),
        "an alpha channel is coverage, not colour"
    );
    let meta = unsafe { rz_doc_layer_meta(converted, 1) };
    assert!(!meta.is_null());
    assert_eq!(
        unsafe { std::ffi::CStr::from_ptr(meta) }.to_str().unwrap(),
        "{\"note\":\"keep me\"}"
    );
    unsafe { rz_string_free(meta) };

    // The layer pixels moved exactly as the transform says.
    let src = model_of(&builtin_bytes(PROFILE_SRGB));
    let dst = model_of(&p3);
    let raw = layer_pixels(doc, 0);
    let out = layer_pixels(converted, 0);
    for i in (0..raw.len()).step_by(4) {
        let want = convert_pixel(&src, &dst, [raw[i], raw[i + 1], raw[i + 2]]);
        assert_eq!(&out[i..i + 3], &want[..], "pixel {}", i / 4);
        assert_eq!(out[i + 3], raw[i + 3], "alpha untouched");
    }

    unsafe {
        rz_doc_free(converted);
        rz_doc_free(assigned);
        rz_doc_free(doc);
    }
}

#[test]
fn assigning_or_converting_to_an_equivalent_profile_is_refused() {
    let dir = TempDir::new().unwrap();
    let doc = doc_from(&dir, "e.png", &opaque_pattern(4, 3));
    let srgb = builtin_bytes(PROFILE_SRGB);
    assert!(
        unsafe { rz_doc_assign_profile(doc, srgb.as_ptr(), srgb.len()) }.is_null(),
        "assigning the profile the document already has is a refusal"
    );
    assert!(
        unsafe { rz_doc_convert_to_profile(doc, srgb.as_ptr(), srgb.len()) }.is_null(),
        "converting to an equivalent space is a refusal, not a phantom edit"
    );
    // A DIFFERENT blob describing the same space is refused by convert (the
    // spaces agree) but accepted by assign (the bytes differ).
    let hp = build_profile(
        b"RGB ",
        &[
            (b"desc", tag_desc("sRGB IEC61966-2.1", true)),
            (b"rXYZ", tag_xyz([0.436066, 0.222488, 0.013916])),
            (b"gXYZ", tag_xyz([0.385147, 0.716873, 0.097076])),
            (b"bXYZ", tag_xyz([0.143066, 0.060608, 0.714096])),
            (b"rTRC", tag_curv_table(&iec_trc_table())),
            (b"gTRC", tag_curv_table(&iec_trc_table())),
            (b"bTRC", tag_curv_table(&iec_trc_table())),
        ],
    );
    assert!(unsafe { rz_doc_convert_to_profile(doc, hp.as_ptr(), hp.len()) }.is_null());
    let relabelled = unsafe { rz_doc_assign_profile(doc, hp.as_ptr(), hp.len()) };
    assert!(!relabelled.is_null());
    unsafe {
        rz_doc_free(relabelled);
        rz_doc_free(doc);
    }
}

/// `rz_icc_describes_same_space` exists so a host can DISABLE a Convert
/// command instead of offering one the core will refuse. It is therefore
/// tested against `rz_doc_convert_to_profile` itself on the same pairs: a
/// host that gates on the bytes (the two sRGB spellings below differ by 576
/// of them) enables an Apply that can only beep.
#[test]
fn describes_same_space_agrees_with_convert() {
    let dir = TempDir::new().unwrap();
    let srgb = builtin_bytes(PROFILE_SRGB);
    let p3 = builtin_bytes(PROFILE_DISPLAY_P3);
    let hp = build_profile(
        b"RGB ",
        &[
            (b"desc", tag_desc("sRGB IEC61966-2.1", true)),
            (b"rXYZ", tag_xyz([0.436066, 0.222488, 0.013916])),
            (b"gXYZ", tag_xyz([0.385147, 0.716873, 0.097076])),
            (b"bXYZ", tag_xyz([0.143066, 0.060608, 0.714096])),
            (b"rTRC", tag_curv_table(&iec_trc_table())),
            (b"gTRC", tag_curv_table(&iec_trc_table())),
            (b"bTRC", tag_curv_table(&iec_trc_table())),
        ],
    );
    let same = |a: &[u8], b: &[u8]| unsafe {
        rz_icc_describes_same_space(a.as_ptr(), a.len(), b.as_ptr(), b.len())
    };
    assert_ne!(
        srgb, hp,
        "the two sRGB spellings really are different bytes"
    );
    for (a, b, want, label) in [
        (&srgb, &srgb, true, "a profile against itself"),
        (&srgb, &hp, true, "two spellings of sRGB"),
        (&hp, &srgb, true, "and the other way round"),
        (&srgb, &p3, false, "sRGB against Display P3"),
        (&p3, &hp, false, "Display P3 against sRGB"),
    ] {
        assert_eq!(same(a, b), want, "{label}");
        // The document op is the authority: a document tagged `a` refuses a
        // conversion to `b` exactly when the two describe one space.
        let mut doc = doc_from(&dir, "s.png", &opaque_pattern(4, 3));
        // A fresh document is already in the built-in sRGB, and assigning
        // that is itself a refusal.
        if a.as_slice() != srgb.as_slice() {
            doc = apply(doc, |d| unsafe {
                rz_doc_assign_profile(d, a.as_ptr(), a.len())
            });
        }
        let converted = unsafe { rz_doc_convert_to_profile(doc, b.as_ptr(), b.len()) };
        assert_eq!(converted.is_null(), want, "{label}: convert must agree");
        unsafe {
            if !converted.is_null() {
                rz_doc_free(converted);
            }
            rz_doc_free(doc);
        }
    }
    // The OTHER refusals are not this question, and each has its own
    // sentence in the host: a profile that is not RGB, one this crate cannot
    // model, and bytes that are not a profile at all all answer false.
    let lut = build_profile(
        b"RGB ",
        &[
            (b"desc", tag_desc("LUT RGB", true)),
            (
                b"A2B0",
                vec![b'm', b'f', b't', b'2', 0, 0, 0, 0, 3, 3, 0, 0],
            ),
        ],
    );
    let gray = build_profile(b"GRAY", &[(b"desc", tag_desc("Some Gray", true))]);
    assert!(!same(&lut, &lut), "a LUT profile is not comparable at all");
    assert!(!same(&lut, &srgb));
    assert!(!same(&gray, &srgb));
    assert!(!same(b"not a profile", &srgb));
    assert!(!same(&srgb, b""));
}

#[test]
fn adopt_working_space_outcomes() {
    let dir = TempDir::new().unwrap();
    let doc = doc_from(&dir, "a.png", &opaque_pattern(4, 3));
    let srgb = builtin_bytes(PROFILE_SRGB);
    let p3 = builtin_bytes(PROFILE_DISPLAY_P3);

    // 1. Already the working space.
    let mut outcome: c_int = 99;
    let same = unsafe { rz_doc_adopt_working_space(doc, srgb.as_ptr(), srgb.len(), &mut outcome) };
    assert!(same.is_null());
    assert_eq!(outcome, ADOPT_UNCHANGED);

    // 2. A different space: converted.
    let mut outcome: c_int = 99;
    let converted = unsafe { rz_doc_adopt_working_space(doc, p3.as_ptr(), p3.len(), &mut outcome) };
    assert!(!converted.is_null());
    assert_eq!(outcome, ADOPT_CONVERTED);
    assert_ne!(flat_pixels(converted), flat_pixels(doc));

    // 3. A profile we cannot convert from: kept, nothing touched.
    let lut = build_profile(
        b"RGB ",
        &[
            (b"desc", tag_desc("LUT RGB", true)),
            (
                b"A2B0",
                vec![b'm', b'f', b't', b'2', 0, 0, 0, 0, 3, 3, 0, 0],
            ),
        ],
    );
    let unconvertible = unsafe { rz_doc_assign_profile(doc, lut.as_ptr(), lut.len()) };
    assert!(!unconvertible.is_null());
    let mut outcome: c_int = 99;
    let kept =
        unsafe { rz_doc_adopt_working_space(unconvertible, p3.as_ptr(), p3.len(), &mut outcome) };
    assert!(kept.is_null());
    assert_eq!(outcome, ADOPT_KEPT_UNCONVERTIBLE);
    assert_eq!(
        flat_pixels(unconvertible),
        flat_pixels(doc),
        "nothing was touched"
    );

    unsafe {
        rz_doc_free(unconvertible);
        rz_doc_free(converted);
        rz_doc_free(doc);
    }
}

#[test]
fn colour_setters_are_pure() {
    let dir = TempDir::new().unwrap();
    let doc = color_fixture(&dir);
    let before = flat_pixels(doc);
    let before_profile = unsafe { rz_doc_icc_profile_len(doc) };
    let before_res = unsafe { (rz_doc_resolution_x(doc), rz_doc_resolution_y(doc)) };
    let p3 = builtin_bytes(PROFILE_DISPLAY_P3);
    let packet = b"II*\0\x08\0\0\0\0\0\0\0\0\0".to_vec();

    let outs = unsafe {
        [
            rz_doc_assign_profile(doc, p3.as_ptr(), p3.len()),
            rz_doc_convert_to_profile(doc, p3.as_ptr(), p3.len()),
            rz_doc_set_resolution(doc, 300.0, 150.0),
            rz_doc_set_metadata(doc, 0, packet.as_ptr(), packet.len()),
        ]
    };
    for out in outs {
        assert!(!out.is_null());
        unsafe { rz_doc_free(out) };
    }
    assert_eq!(flat_pixels(doc), before, "the original is untouched");
    assert_eq!(unsafe { rz_doc_icc_profile_len(doc) }, before_profile);
    assert_eq!(
        unsafe { (rz_doc_resolution_x(doc), rz_doc_resolution_y(doc)) },
        before_res
    );
    assert_eq!(unsafe { rz_doc_metadata_len(doc, 0) }, 0);
    unsafe { rz_doc_free(doc) };
}

#[test]
fn each_curve_kind_is_evaluated_by_its_spec_formula() {
    // A behavioural guard on the parser's classification: converting FROM a
    // profile whose only difference is its TRC, INTO one with the linear
    // `curv` count-0 curve and the same primaries, makes the output the
    // curve itself. Count 0 is linear, count 1 is a u8Fixed8 gamma, count
    // above 1 is a sampled table, and a `para` keeps its function type.
    let cols = d50_matrix(SRGB_PRIMARIES);
    let linear = model_of(&matrix_profile("linear", cols, tag_curv_identity()));

    let table: Vec<u16> = (0..=64u32)
        .map(|i| ((f64::from(i) / 64.0).powf(1.5) * 65535.0).round() as u16)
        .collect();
    /// A curve fixture: what to call it, its TRC tag bytes, and the curve
    /// itself written out from the spec formula.
    type CurveCase = (&'static str, Vec<u8>, Box<dyn Fn(f64) -> f64>);
    let cases: [CurveCase; 5] = [
        ("identity", tag_curv_identity(), Box::new(|x| x)),
        (
            "gamma 2.19921875",
            tag_curv_gamma(0x0233),
            Box::new(|x: f64| x.powf(2.19921875)),
        ),
        (
            "sampled",
            tag_curv_table(&table),
            Box::new(move |x: f64| {
                let pos = x * 64.0;
                let i = pos.floor() as usize;
                if i >= 64 {
                    1.0
                } else {
                    let f = pos - i as f64;
                    (f64::from(table[i]) * (1.0 - f) + f64::from(table[i + 1]) * f) / 65535.0
                }
            }),
        ),
        (
            "para type 0",
            tag_para(0, &[2.2]),
            Box::new(|x: f64| x.powf(f64::from(fixed(2.2)) / 65536.0)),
        ),
        (
            "para type 3 (sRGB)",
            tag_para(3, &[2.4, 1.0 / 1.055, 0.055 / 1.055, 1.0 / 12.92, 0.04045]),
            Box::new(srgb_decode),
        ),
    ];
    for (name, trc, curve) in cases {
        let model = model_of(&matrix_profile(name, cols, trc));
        for v in [0u8, 1, 3, 17, 64, 128, 200, 254, 255] {
            let got = convert_pixel(&model, &linear, [v, v, v]);
            let want = encode_linear(curve(f64::from(v) / 255.0));
            for channel in got {
                assert!(
                    i32::from(channel).abs_diff(i32::from(want)) <= 1,
                    "{name} at {v}: got {channel}, want {want}"
                );
            }
        }
    }
}

/// The encoder's rule restated from first principles for the LINEAR
/// destination: the output code is the number of thresholds
/// `(k + 0.5) / 255` strictly below the linear value.
fn encode_linear(lin: f64) -> u8 {
    let lin = lin.clamp(0.0, 1.0);
    let mut k = 0u8;
    while k < 255 && (f64::from(k) + 0.5) / 255.0 < lin {
        k += 1;
    }
    k
}

// ------------------------------------------ the size a profile may reach --

/// A PNG carrying `icc` in its `iCCP` chunk, written by the `image` crate's
/// own encoder (which deflates the profile for us, exactly as the files this
/// case is about are written).
fn png_with_profile(dir: &TempDir, name: &str, icc: Vec<u8>) -> std::path::PathBuf {
    let path = dir.path().join(name);
    let file = std::fs::File::create(&path).unwrap();
    let pixels = opaque_pattern(4, 3);
    let mut enc = image::codecs::png::PngEncoder::new(std::io::BufWriter::new(file));
    enc.set_icc_profile(icc).unwrap();
    use image::ImageEncoder;
    enc.write_image(pixels.as_raw(), 4, 3, image::ExtendedColorType::Rgba8)
        .unwrap();
    path
}

fn open_path(path: &std::path::Path) -> *mut RzDocument {
    let c = cpath(path);
    let mut err: *mut c_char = ptr::null_mut();
    let doc = unsafe { rz_doc_open(c.as_ptr(), &mut err) };
    assert!(!doc.is_null(), "open: {}", take_err_string(err));
    doc
}

fn profile_bytes(doc: *const RzDocument) -> Vec<u8> {
    let len = unsafe { rz_doc_icc_profile_len(doc) };
    let mut out = vec![0u8; len];
    assert!(unsafe { rz_doc_icc_profile(doc, out.as_mut_ptr(), len) });
    out
}

fn saves_natively(doc: *const RzDocument, path: &std::path::Path) -> Result<(), String> {
    let c = cpath(path);
    let mut err: *mut c_char = ptr::null_mut();
    if unsafe { rz_doc_save_native(doc, c.as_ptr(), &mut err) } {
        Ok(())
    } else {
        Err(take_err_string(err))
    }
}

/// A profile IS its declared size. A PNG `iCCP` stream that inflates to
/// megabytes of padding behind a small profile must not put those megabytes
/// on the document — they would be re-embedded on every export and, past the
/// RZDC blob cap, would make the document unsavable in the native format for
/// the rest of its life.
#[test]
fn a_padded_profile_is_stored_at_its_declared_size() {
    let dir = TempDir::new().unwrap();
    let profile = matrix_profile("Padded", d50_matrix(SRGB_PRIMARIES), tag_curv_gamma(0x0233));
    let mut padded = profile.clone();
    // Comfortably past MAX_RZDC_BLOB_LEN, so a document that kept the
    // padding could not be saved at all.
    padded.resize(20 * 1024 * 1024, 0);
    let doc = open_path(&png_with_profile(&dir, "padded.png", padded));

    assert_eq!(
        profile_bytes(doc),
        profile,
        "the padding is not part of the profile"
    );
    assert_eq!(
        saves_natively(doc, &dir.path().join("padded.rz")),
        Ok(()),
        "an opened document must always be savable in the native format"
    );
    unsafe { rz_doc_free(doc) };
}

/// A profile whose DECLARED size is past the blob cap is refused outright —
/// in the parser, so that every entry point inherits the refusal — and the
/// document keeps the sRGB it would have had with no profile at all.
#[test]
fn an_oversize_profile_is_refused_everywhere_it_could_enter() {
    let dir = TempDir::new().unwrap();
    let cap = 16 * 1024 * 1024;
    let mut huge = matrix_profile("Huge", d50_matrix(SRGB_PRIMARIES), tag_curv_gamma(0x0233));
    huge.resize(cap + 4096, 0);
    // Restate the size in the header: this profile CLAIMS to be all of it.
    let size = (huge.len() as u32).to_be_bytes();
    huge[0..4].copy_from_slice(&size);

    assert!(
        IccProfile::parse(&huge).is_none(),
        "the parser is where the cap lives"
    );
    let doc = doc_from(&dir, "cap.png", &opaque_pattern(4, 3));
    assert!(
        unsafe { rz_doc_assign_profile(doc, huge.as_ptr(), huge.len()) }.is_null(),
        "and the setter refuses it"
    );
    unsafe { rz_doc_free(doc) };

    let opened = open_path(&png_with_profile(&dir, "huge.png", huge));
    assert_eq!(
        profile_bytes(opened),
        builtin_bytes(PROFILE_SRGB),
        "an unusable profile leaves the document on the sRGB assumption"
    );
    assert_eq!(
        saves_natively(opened, &dir.path().join("huge.rz")),
        Ok(()),
        "and the document is still savable"
    );
    unsafe { rz_doc_free(opened) };
}

/// A profile whose CLASS is a device link, an abstract transform or a
/// named-colour list carries RGB numbers without describing the space a
/// picture's pixels live in, and is refused with Gray, CMYK and Lab rather
/// than kept as "RGB, just not convertible".
///
/// macOS ships one: `WebSafeColors.icc` is `nmcl` with an RGB data space, a
/// Lab PCS and no matrix, no TRC and no A2B. Reading the data space alone
/// made it storable, and CoreGraphics then took it as a tag it could not
/// convert OUT of — every pixel a host drew through it came out empty, and
/// the export re-embedded it so the file stayed that way.
#[test]
fn a_device_link_abstract_or_named_colour_profile_is_refused() {
    let dir = TempDir::new().unwrap();
    let doc = doc_from(&dir, "class.png", &opaque_pattern(4, 3));
    let cols = d50_matrix(SRGB_PRIMARIES);
    let trc = tag_curv_gamma(0x0233);
    let tags: Vec<(&[u8; 4], Vec<u8>)> = vec![
        (b"desc", tag_desc("Some Profile", true)),
        (b"rXYZ", tag_xyz([cols[0][0], cols[1][0], cols[2][0]])),
        (b"gXYZ", tag_xyz([cols[0][1], cols[1][1], cols[2][1]])),
        (b"bXYZ", tag_xyz([cols[0][2], cols[1][2], cols[2][2]])),
        (b"rTRC", trc.clone()),
        (b"gTRC", trc.clone()),
        (b"bTRC", trc),
    ];
    // Refused, whatever else the profile carries — these three have all six
    // matrix/TRC tags and are still not a space to interpret pixels in.
    for class in [b"nmcl", b"link", b"abst"] {
        let bytes = build_profile_class(class, b"RGB ", &tags);
        let mut name: *mut c_char = ptr::null_mut();
        let kind = unsafe { rz_icc_inspect(bytes.as_ptr(), bytes.len(), &mut name) };
        let label = String::from_utf8_lossy(class).into_owned();
        assert_eq!(kind, ICC_NOT_IMAGE_PROFILE, "{label}");
        assert!(
            !name.is_null(),
            "{label}: a refused profile still has a name"
        );
        unsafe { rz_string_free(name) };
        assert!(
            unsafe { rz_doc_assign_profile(doc, bytes.as_ptr(), bytes.len()) }.is_null(),
            "{label} must never be stored"
        );
    }
    // The four classes that DO describe pixels stay accepted.
    for class in [b"mntr", b"scnr", b"prtr", b"spac"] {
        let bytes = build_profile_class(class, b"RGB ", &tags);
        let label = String::from_utf8_lossy(class).into_owned();
        assert_eq!(
            unsafe { rz_icc_inspect(bytes.as_ptr(), bytes.len(), ptr::null_mut()) },
            ICC_RGB_MATRIX,
            "{label}"
        );
        let stored = unsafe { rz_doc_assign_profile(doc, bytes.as_ptr(), bytes.len()) };
        assert!(!stored.is_null(), "{label} is a profile pixels can wear");
        unsafe { rz_doc_free(stored) };
    }
    unsafe { rz_doc_free(doc) };
}

/// A layer style's colours are AUTHORED sRGB — the convention every
/// `#rrggbb` this crate is handed follows — and reach the document's space
/// at COMPOSITE time rather than in the stored JSON. Three consequences,
/// all checked here for a solid colour and for a gradient's stops:
///
/// * the same `#00ff00` is the same green on any document; on a Display P3
///   one it lands on the P3 numbers a converted sRGB green has, which is
///   exactly where a fill of the same hex lands, so an effect and a fill can
///   no longer disagree;
/// * Assign to Profile relabels the pixels and the style follows, with no
///   rendered plane invalidated;
/// * Convert to Profile preserves a style's APPEARANCE without rewriting a
///   byte of its JSON.
#[test]
fn style_colours_are_authored_in_srgb_and_convert_at_composite_time() {
    let dir = TempDir::new().unwrap();
    // The anchor from `srgb_to_display_p3_matches_an_analytic_reference`.
    const GREEN_IN_P3: [u8; 4] = [117, 251, 76, 255];
    let stops = "{\"stops\":[{\"position\":0,\"color\":\"#00ff00\"},\
                 {\"position\":1,\"color\":\"#00ff00\"}]}";
    for effect in [
        "{\"type\":\"color_overlay\",\"blend\":\"normal\",\"color\":\"#00ff00\",\"opacity\":1}"
            .to_string(),
        format!("{{\"type\":\"gradient_overlay\",\"blend\":\"normal\",\"opacity\":1,\"gradient\":{stops}}}"),
    ] {
        let doc = doc_from(&dir, "style.png", &solid(4, 4, [10, 20, 30, 255]));
        let styled = set_style(doc, 0, &format!("{{\"effects\":[{effect}]}}"));
        assert_eq!(
            pixel(&flat_pixels(styled), 4, 2, 2),
            [0, 255, 0, 255],
            "an sRGB document paints the authored numbers: {effect}"
        );
        let p3 = builtin_bytes(PROFILE_DISPLAY_P3);
        let converted = unsafe { rz_doc_convert_to_profile(styled, p3.as_ptr(), p3.len()) };
        assert!(!converted.is_null());
        assert_eq!(
            pixel(&flat_pixels(converted), 4, 2, 2),
            GREEN_IN_P3,
            "the authored green as Display P3 numbers: {effect}"
        );
        assert!(
            ffi_style(converted, 0).expect("a style").contains("#00ff00"),
            "the stored style is not rewritten: {effect}"
        );
        let assigned = unsafe { rz_doc_assign_profile(styled, p3.as_ptr(), p3.len()) };
        assert!(!assigned.is_null());
        assert_eq!(
            pixel(&flat_pixels(assigned), 4, 2, 2),
            GREEN_IN_P3,
            "assign relabels the document and the style follows: {effect}"
        );
        unsafe {
            rz_doc_free(assigned);
            rz_doc_free(converted);
            rz_doc_free(styled);
        }
    }
}

/// The other half of that rule, and the one the host has to match: on a
/// document whose profile this crate cannot MODEL, an authored colour is
/// the number it says — in a layer style exactly as in the pixels a paint
/// tool lays down.
///
/// The two sides answer the same question separately, which is how they came
/// to disagree. `RzDocument::style_colors` returns `None` the moment
/// `profile.model()` is absent, so a style's `#00ff00` composites as
/// (0, 255, 0); the host converts an authored colour into
/// `ColorProfile.drawingSpace`, which falls back to sRGB for exactly this
/// class of profile — a space ColorSync cannot render INTO — so a fill of
/// `#00ff00` writes (0, 255, 0) too. Gate either side on a different
/// question and one hex produces two grossly different colours in one
/// document: pure green from the brush and a muted one from the effect,
/// baked in by Merge Down, Flatten and every export.
///
/// Contrast with a Display P3 document above, where BOTH sides convert and
/// land on the same P3 numbers. The invariant is the agreement, not the
/// conversion.
#[test]
fn an_authored_colour_agrees_with_a_style_colour_on_an_unmodellable_profile() {
    let dir = TempDir::new().unwrap();
    // What a fill of #00ff00 lays down on such a document, host-side.
    const AUTHORED: [u8; 4] = [0, 255, 0, 255];
    // An RGB profile with a LUT and no matrix tags: stored, displayed and
    // re-embedded, but not one this crate can transform with.
    let lut = build_profile(
        b"RGB ",
        &[
            (b"desc", tag_desc("LUT RGB", true)),
            (
                b"A2B0",
                vec![b'm', b'f', b't', b'2', 0, 0, 0, 0, 3, 3, 0, 0],
            ),
        ],
    );
    let doc = doc_from(&dir, "lut.png", &solid(4, 4, AUTHORED));
    let doc = apply(doc, |d| unsafe {
        rz_doc_assign_profile(d, lut.as_ptr(), lut.len())
    });
    assert!(
        !unsafe { rz_doc_profile_is_convertible(doc) },
        "the profile is the RgbUnconvertible class this test is about"
    );
    assert_eq!(
        pixel(&flat_pixels(doc), 4, 2, 2),
        AUTHORED,
        "assign touches no pixel, so the painted numbers stand"
    );
    let styled = set_style(
        doc,
        0,
        "{\"effects\":[{\"type\":\"color_overlay\",\"blend\":\"normal\",\
         \"color\":\"#00ff00\",\"opacity\":1}]}",
    );
    assert_eq!(
        pixel(&flat_pixels(styled), 4, 2, 2),
        AUTHORED,
        "and the same hex in a style is the same colour"
    );
    unsafe { rz_doc_free(styled) };
}
