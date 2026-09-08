//! The two ICC profiles this build WRITES: sRGB IEC61966-2.1 and Display P3,
//! emitted as real, conformant ICC v2.1.0 matrix/TRC blobs so an exported
//! file carries a profile any other application can read. `icc` parses; this
//! module builds; `icc_transform` does the numerics.
//!
//! # Why v2.1.0 with a 1024-entry `curv`, and not a `para` curve
//!
//! `parametricCurveType` (`para`) is an ICC **v4** tag type and is not
//! defined in v2, so a v2 header carrying one is a hybrid strict validators
//! (Java's `ICC_Profile`, some Windows ICM paths) may reject. Writing a
//! `curv` table removes the question, and it costs nothing:
//!
//! * **The shape is Apple's own.** `/System/Library/ColorSync/Profiles/sRGB
//!   Profile.icc` is version `02 10 00 00` with a `desc` and a 1024-entry
//!   `curv` — exactly what this module writes.
//! * **The bytes are Apple's own.** The generation rule below,
//!   `tab[i] = round(srgb_transfer(i / 1023) * 65535)`, reproduces that
//!   shipped file's 1024-entry rTRC table byte-for-byte, all 1024 entries
//!   (`color_tests::builtin_trc_is_the_iec_curve` recomputes it here).
//! * **The numbers do not move.** Every conversion anchor is identical
//!   whether the built-in TRC is the analytic sRGB `para` curve or this
//!   table.
//!
//! Cost: one 2060-byte `curv` blob, shared by all three TRC tags, so a
//! built-in is ~2.5 KB rather than ~540 bytes. Irrelevant next to a JPEG.
//!
//! # Determinism
//!
//! The creation date in the header is a CONSTANT, never `now()`: a save must
//! produce the same bytes every run, or the "resaving a document reproduces
//! the file byte-for-byte" property the RZDC tests rely on would break the
//! moment a profile is embedded.
//!
//! Both the blob and the [`MatrixTrc`] model come from the SAME constants
//! below, so `parse(blob(w))` and `model(w)` describe one colour space and
//! `IccProfile::srgb()` never has to unwrap a parse.

use std::sync::OnceLock;

use crate::icc_transform::{Curve, MatrixTrc};

/// Which of the two profiles this build can write.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Builtin {
    Srgb,
    DisplayP3,
}

impl Builtin {
    /// The `desc` text, which is also the name the UI shows.
    pub(crate) fn display_name(self) -> &'static str {
        match self {
            Builtin::Srgb => "sRGB IEC61966-2.1",
            Builtin::DisplayP3 => "Display P3",
        }
    }

    /// Maps a raw `RzBuiltinProfile` value coming across the FFI. Mapped,
    /// never transmuted: an out-of-range discriminant is a caller error, and
    /// materializing an enum from one would be undefined behaviour.
    pub(crate) fn from_c(value: i32) -> Option<Self> {
        match value {
            0 => Some(Builtin::Srgb),
            1 => Some(Builtin::DisplayP3),
            _ => None,
        }
    }

    /// The three D50-adapted matrix columns as raw s15Fixed16 values, in
    /// r, g, b order. Recomputed from the published xy primaries through the
    /// Bradford D65→D50 adaptation by
    /// `color_tests::builtin_matrix_columns_match_the_published_primaries`.
    fn columns(self) -> [[i32; 3]; 3] {
        match self {
            // 0.436035  0.222485  0.013916
            // 0.385117  0.716888  0.097061
            // 0.143036  0.060608  0.713928
            Builtin::Srgb => [
                [0x0000_6FA0, 0x0000_38F5, 0x0000_0390],
                [0x0000_6297, 0x0000_B787, 0x0000_18D9],
                [0x0000_249F, 0x0000_0F84, 0x0000_B6C3],
            ],
            // 0.515121  0.241196 -0.001053
            // 0.291977  0.692245  0.041885
            // 0.157104  0.066574  0.784073
            //
            // Byte-identical to Apple's `Display P3.icc` at offsets 400, 420
            // and 440.
            Builtin::DisplayP3 => [
                [0x0000_83DF, 0x0000_3DBF, 0xFFFF_FFBBu32 as i32],
                [0x0000_4ABF, 0x0000_B137, 0x0000_0AB9],
                [0x0000_2838, 0x0000_110B, 0x0000_C8B9],
            ],
        }
    }
}

/// The D50 PCS white point, fixed by the ICC spec and identical in every
/// profile macOS ships: 0.9642, 1.0, 0.8249 as s15Fixed16.
const D50: [i32; 3] = [0x0000_F6D6, 0x0001_0000, 0x0000_D32D];

/// The Bradford chromatic adaptation from D65 to D50, row-major s15Fixed16 —
///
/// ```text
///  1.047886   0.022919  -0.050216
///  0.029582   0.990484  -0.017079
/// -0.009252   0.015073   0.751678
/// ```
///
/// The `chad` tag is ADVISORY: this crate's reader ignores it (see
/// `MatrixTrc`'s doc for why a matrix/TRC profile's PCS white is always
/// D50), and it is written only because a v2 display profile whose native
/// white is not D50 is expected to record the adaptation it applied. That is
/// also why three of these entries differ from Apple's by one raw unit
/// (Apple has `FFFFF326`, `FFFFFBA2`, `FFFFFDA3`): the Bradford product is
/// rounded here rather than copied, and nothing reads the result.
const CHAD: [i32; 9] = [
    0x0001_0C42,
    0x0000_05DE,
    0xFFFF_F325u32 as i32,
    0x0000_0793,
    0x0000_FD90,
    0xFFFF_FBA1u32 as i32,
    0xFFFF_FDA2u32 as i32,
    0x0000_03DC,
    0x0000_C06E,
];

/// Entries in the `curv` TRC table. 1024 is what Apple's own sRGB profile
/// uses, and the table below reproduces that file exactly.
const TRC_ENTRIES: usize = 1024;

/// The IEC 61966-2.1 electro-optical transfer function — the sRGB curve,
/// which Display P3 shares (P3 differs only in its red and green
/// primaries). Maps an encoded value to a linear one.
fn srgb_transfer(x: f64) -> f64 {
    if x <= 0.04045 {
        x / 12.92
    } else {
        ((x + 0.055) / 1.055).powf(2.4)
    }
}

/// The 1024 16-bit TRC samples both built-ins share.
///
/// Anchors a reviewer can spot-check against Apple's shipped
/// `sRGB Profile.icc`: `[0] = 0x0000`, `[1] = 0x0005`, `[2] = 0x000A`,
/// `[256] = 0x0D0D`, `[512] = 0x36E9`, `[1023] = 0xFFFF`.
fn trc_table() -> Vec<u16> {
    (0..TRC_ENTRIES)
        .map(|i| {
            let x = i as f64 / (TRC_ENTRIES - 1) as f64;
            (srgb_transfer(x) * 65535.0).round() as u16
        })
        .collect()
}

/// The profile's canonical bytes, built once per built-in and byte-identical
/// on every call and every run.
pub(crate) fn blob(which: Builtin) -> &'static [u8] {
    static SRGB: OnceLock<Vec<u8>> = OnceLock::new();
    static P3: OnceLock<Vec<u8>> = OnceLock::new();
    let slot = match which {
        Builtin::Srgb => &SRGB,
        Builtin::DisplayP3 => &P3,
    };
    slot.get_or_init(|| build_v2_matrix_profile(which.display_name(), which.columns()))
}

/// The transformable model, built from the SAME constants as [`blob`], so
/// there is one source of truth for what each built-in means.
pub(crate) fn model(which: Builtin) -> MatrixTrc {
    let cols = which.columns();
    let to_pcs = [fixed_col(cols[0]), fixed_col(cols[1]), fixed_col(cols[2])];
    let curve = Curve::Sampled(trc_table());
    MatrixTrc::new(to_pcs, [curve.clone(), curve.clone(), curve])
        .expect("the built-in primaries are an invertible basis")
}

fn fixed_col(raw: [i32; 3]) -> [f64; 3] {
    [
        f64::from(raw[0]) / 65536.0,
        f64::from(raw[1]) / 65536.0,
        f64::from(raw[2]) / 65536.0,
    ]
}

// ------------------------------------------------------------- assembly --

/// Assembles a complete ICC v2.1.0 RGB matrix/TRC display profile:
/// the 128-byte header, a 10-entry tag table (`desc`, `cprt`, `wtpt`,
/// `rXYZ`, `gXYZ`, `bXYZ`, `rTRC`, `gTRC`, `bTRC`, `chad`), then the tag
/// data, each blob padded to a 4-byte boundary (padding is NOT counted in a
/// tag's size) and IDENTICAL blobs shared — the three TRC tags all point at
/// one 2060-byte `curv`, exactly as both Apple profiles do.
fn build_v2_matrix_profile(desc: &str, cols: [[i32; 3]; 3]) -> Vec<u8> {
    let curv = curv_tag(&trc_table());
    let tags: [(&[u8; 4], Vec<u8>); 10] = [
        (b"desc", desc_tag(desc)),
        (b"cprt", text_tag("Public Domain")),
        (b"wtpt", xyz_tag(D50)),
        (b"rXYZ", xyz_tag(cols[0])),
        (b"gXYZ", xyz_tag(cols[1])),
        (b"bXYZ", xyz_tag(cols[2])),
        (b"rTRC", curv.clone()),
        (b"gTRC", curv.clone()),
        (b"bTRC", curv),
        (b"chad", sf32_tag(&CHAD)),
    ];

    let table_start = 132;
    let payload_start = table_start + 12 * tags.len();
    let mut table = Vec::with_capacity(12 * tags.len());
    let mut payload: Vec<u8> = Vec::new();
    // (blob, offset) pairs, so an identical blob reuses the first offset.
    let mut placed: Vec<(&[u8], u32)> = Vec::new();
    for (sig, data) in &tags {
        let offset = match placed.iter().find(|(seen, _)| *seen == data.as_slice()) {
            Some((_, off)) => *off,
            None => {
                let off = (payload_start + payload.len()) as u32;
                payload.extend_from_slice(data);
                // Pad to the next 4-byte boundary; the padding is not part
                // of the tag's declared size.
                while !payload.len().is_multiple_of(4) {
                    payload.push(0);
                }
                placed.push((data.as_slice(), off));
                off
            }
        };
        table.extend_from_slice(sig.as_slice());
        table.extend_from_slice(&offset.to_be_bytes());
        table.extend_from_slice(&(data.len() as u32).to_be_bytes());
    }

    let total = (payload_start + payload.len()) as u32;
    let mut out = Vec::with_capacity(total as usize);
    // --- the 128-byte header ---
    out.extend_from_slice(&total.to_be_bytes()); //   0 profile size
    out.extend_from_slice(&[0; 4]); //                4 preferred CMM: none
    out.extend_from_slice(&[0x02, 0x10, 0x00, 0x00]); // 8 version 2.1.0
    out.extend_from_slice(b"mntr"); //               12 display device class
    out.extend_from_slice(b"RGB "); //               16 data colour space
    out.extend_from_slice(b"XYZ "); //               20 PCS
                                    //               24 creation date, a CONSTANT: 2026-01-01T00:00:00Z
    for field in [2026u16, 1, 1, 0, 0, 0] {
        out.extend_from_slice(&field.to_be_bytes());
    }
    out.extend_from_slice(b"acsp"); //               36 magic
    out.extend_from_slice(&[0; 4]); //               40 primary platform: none
    out.extend_from_slice(&[0; 4]); //               44 profile flags
    out.extend_from_slice(&[0; 4]); //               48 device manufacturer
    out.extend_from_slice(&[0; 4]); //               52 device model
    out.extend_from_slice(&[0; 8]); //               56 device attributes
    out.extend_from_slice(&[0; 4]); //               64 rendering intent: perceptual
    for v in D50 {
        out.extend_from_slice(&v.to_be_bytes()); //  68 PCS illuminant, fixed by spec
    }
    out.extend_from_slice(&[0; 4]); //               80 profile creator
    out.extend_from_slice(&[0; 16]); //              84 profile ID (zero is accepted in practice)
    out.extend_from_slice(&[0; 28]); //             100 reserved
    debug_assert_eq!(out.len(), 128);
    // --- tag table and data ---
    out.extend_from_slice(&(tags.len() as u32).to_be_bytes());
    out.extend_from_slice(&table);
    out.extend_from_slice(&payload);
    out
}

/// `XYZType`: signature, four reserved zero bytes, three s15Fixed16.
fn xyz_tag(v: [i32; 3]) -> Vec<u8> {
    let mut t = Vec::with_capacity(20);
    t.extend_from_slice(b"XYZ ");
    t.extend_from_slice(&[0; 4]);
    for c in v {
        t.extend_from_slice(&c.to_be_bytes());
    }
    t
}

/// `curveType`: signature, reserved, u32 count, then that many big-endian
/// u16 samples.
fn curv_tag(table: &[u16]) -> Vec<u8> {
    let mut t = Vec::with_capacity(12 + 2 * table.len());
    t.extend_from_slice(b"curv");
    t.extend_from_slice(&[0; 4]);
    t.extend_from_slice(&(table.len() as u32).to_be_bytes());
    for v in table {
        t.extend_from_slice(&v.to_be_bytes());
    }
    t
}

/// `s15Fixed16ArrayType`: the `chad` matrix, row-major.
fn sf32_tag(v: &[i32; 9]) -> Vec<u8> {
    let mut t = Vec::with_capacity(8 + 36);
    t.extend_from_slice(b"sf32");
    t.extend_from_slice(&[0; 4]);
    for c in v {
        t.extend_from_slice(&c.to_be_bytes());
    }
    t
}

/// `textType`: signature, reserved, NUL-terminated 7-bit ASCII.
fn text_tag(s: &str) -> Vec<u8> {
    let mut t = Vec::with_capacity(8 + s.len() + 1);
    t.extend_from_slice(b"text");
    t.extend_from_slice(&[0; 4]);
    t.extend_from_slice(s.as_bytes());
    t.push(0);
    t
}

/// `textDescriptionType`, the v2 name tag: signature, reserved, u32 ASCII
/// count INCLUDING its NUL, the string, then the fixed tail — u32 Unicode
/// language, u32 Unicode count (0), u16 ScriptCode, u8 Macintosh count, and
/// a 67-byte Macintosh buffer that is present even when unused. Total size
/// is `ascii + 90`. This build WRITES the full tail; the reader deliberately
/// does not REQUIRE it (real profiles ship truncated ones).
fn desc_tag(s: &str) -> Vec<u8> {
    let ascii = s.len() + 1;
    let mut t = Vec::with_capacity(ascii + 90);
    t.extend_from_slice(b"desc");
    t.extend_from_slice(&[0; 4]);
    t.extend_from_slice(&(ascii as u32).to_be_bytes());
    t.extend_from_slice(s.as_bytes());
    t.push(0);
    t.extend_from_slice(&[0; 4]); // Unicode language code
    t.extend_from_slice(&[0; 4]); // Unicode count: no Unicode string
    t.extend_from_slice(&[0; 2]); // ScriptCode code
    t.push(0); // Macintosh string count
    t.extend_from_slice(&[0; 67]); // Macintosh string buffer
    t
}
