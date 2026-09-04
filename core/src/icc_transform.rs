//! The ICC matrix/TRC NUMERICS: the tone-curve model, the profile→PCS
//! matrix, the equivalence test two profiles are compared with, and the
//! 8-bit-in/8-bit-out [`Transform`] between two of them. The parser that
//! builds these values from profile bytes is `icc`; the two profiles this
//! build writes are `icc_builtin`.
//!
//! # The pipeline, and why it is shaped this way
//!
//! Straight (non-premultiplied) RGBA8 in, straight RGBA8 out, with the
//! **alpha byte copied untouched** — alpha is coverage, not colour.
//!
//! **Decode is a 256-entry table per channel and it is exact.** The input is
//! 8-bit, so every byte's linear contribution is known up front; the columns
//! of the combined matrix are folded into that table, which makes the
//! per-pixel path nine adds with no multiplies and no interpolation error on
//! the source side.
//!
//! **Encode is a binary search over 255 forward-evaluated thresholds, and
//! there is no curve inverter in this crate.** `thresh[c][k]` is the linear
//! value at which the destination's 8-bit code rounds up from `k` to `k + 1`,
//! obtained by evaluating the destination curve FORWARD at `(k + 0.5) / 255`;
//! `partition_point` then counts the thresholds strictly below the pixel's
//! linear value, which is exactly `round(inverse(lin) * 255)` for a strictly
//! increasing curve and picks the lowest pre-image on a plateau. Adding an
//! inverter back is a regression, for two independent reasons measured
//! before this module was written:
//!
//! * a table indexed uniformly in LINEAR value loses two 8-bit codes in the
//!   shadows of any gamma-2.2 destination (code 3 came back as 1 at
//!   γ = 2.2 and γ = 2.4 — Adobe RGB (1998) and ProPhoto are exactly the
//!   profiles a photographer's files carry after sRGB and Display P3), and
//! * indexing a 4096-entry table by `floor(lin * 4095) + 1` reads one past
//!   the end at `lin == 1.0`. The search below indexes no table with a
//!   computed float at all: its result is a count in `0..=255`, so that
//!   class of bug is structurally impossible rather than merely guarded.
//!
//! Round-tripping all 256 byte values through `eval` and back through the
//! search is byte-exact (max |Δ| = 0) for the sRGB `para` curve, for
//! `Gamma(1.0 / 1.8 / 2.19921875 / 2.2 / 2.4)` and for a 1024-entry
//! `Sampled` sRGB curve; `color_tests::identity_is_exact_for_every_curve_kind`
//! is that measurement as a committed test.
//!
//! **Out of gamut** is the destination's own black and white: the linear
//! value is clamped to [0, 1] before the search, never reported as an error.
//!
//! Cost is three 8-step binary searches per pixel. A conversion is a one-shot
//! user command, so this is not a hot path and there is deliberately no
//! transform cache.

use image::RgbaImage;

/// How far the COMBINED matrix `inv(b) · a` may sit from the identity, in
/// any entry, for two profiles to count as the same colour space.
///
/// 5e-4, and the number is measured rather than chosen. macOS's shipped
/// `sRGB Profile.icc` — the HP/IEC profile Photoshop, GIMP and most cameras
/// embed — has `bXYZ.Z = 0.714096` against this build's `0.713928`, an
/// ENTRYWISE gap of 1.83e-4; an entrywise 1e-4 tolerance would therefore
/// reject the world's most common tagged file, making every open of one a
/// full-image transform with an extra ±1 requantization and making
/// `convert_to_profile` to the built-in sRGB always report a change. The
/// COMBINED matrix for that same pair deviates from the identity by only
/// 2.585e-4, so comparing the combination — which is what a conversion would
/// actually apply — takes the "nothing would change" branch, which is the
/// right answer.
///
/// 5e-4 is far below one 8-bit code: the induced encoded error is bounded by
/// `d(encode)/d(lin) · lin · tol ≤ 0.44 · 5e-4 ≈ 0.06 code` above the toe,
/// and smaller still inside it where `lin` itself is tiny.
const MATRIX_TOL: f64 = 5e-4;

/// How far two tone curves may differ, at any of 256 evenly spaced inputs,
/// for two profiles to count as the same colour space. One part in 10 000 is
/// a quarter of an 8-bit code at the steepest point of the sRGB curve.
const TRC_TOL: f64 = 1e-4;

/// A determinant this small means the three primaries are collinear (or the
/// tags are zero): the profile describes no invertible colour space, so it
/// is refused as unmodellable rather than producing infinities.
const MIN_DET: f64 = 1e-9;

/// One tone reproduction curve, in the four shapes ICC `curv` and `para`
/// tags express. Every variant maps [0, 1] → [0, 1] through
/// [`Curve::eval`], which is the ONE evaluator: nothing in this crate
/// inverts a curve (see the module doc).
#[derive(Clone, Debug, PartialEq)]
pub enum Curve {
    /// `curv` with a count of 0 — the linear curve.
    Identity,
    /// `curv` with a count of 1: the single u8Fixed8 entry is a gamma
    /// exponent (`raw / 256`). A non-positive exponent is degraded to
    /// [`Curve::Identity`] at parse time.
    Gamma(f64),
    /// `curv` with a count above 1: a table sampled uniformly over [0, 1]
    /// with 16-bit outputs, linearly interpolated over `n - 1` intervals.
    /// Monotonized by a running maximum at parse time, so the threshold
    /// search's precondition holds for any input file.
    Sampled(Vec<u16>),
    /// `para`, function types 0 to 4, with the unused parameters zero.
    Para {
        kind: u8,
        g: f64,
        a: f64,
        b: f64,
        c: f64,
        d: f64,
        e: f64,
        f: f64,
    },
}

impl Curve {
    /// The curve at `x`, clamped into [0, 1] on both sides. A parameter set
    /// that produces a non-finite result (a negative base under a fractional
    /// exponent, a zero base under a negative one) yields 0 rather than a
    /// NaN that would poison the matrix.
    pub(crate) fn eval(&self, x: f64) -> f64 {
        let x = if x.is_finite() {
            x.clamp(0.0, 1.0)
        } else {
            0.0
        };
        let y = match self {
            Curve::Identity => x,
            Curve::Gamma(g) => {
                if *g > 0.0 {
                    x.powf(*g)
                } else {
                    x
                }
            }
            Curve::Sampled(table) => {
                let n = table.len();
                if n < 2 {
                    // Guarded at parse time; defensive, and linear is the
                    // only honest reading of a table with no interval.
                    return x;
                }
                let pos = x * (n - 1) as f64;
                let i = pos.floor() as usize;
                if i >= n - 1 {
                    f64::from(table[n - 1]) / 65535.0
                } else {
                    let f = pos - i as f64;
                    (f64::from(table[i]) * (1.0 - f) + f64::from(table[i + 1]) * f) / 65535.0
                }
            }
            // The ICC parametricCurveType formulas, one per function type.
            Curve::Para {
                kind,
                g,
                a,
                b,
                c,
                d,
                e,
                f,
            } => match kind {
                0 => pow(x, *g),
                1 => {
                    if *a != 0.0 && x >= -b / a {
                        pow(a * x + b, *g)
                    } else {
                        0.0
                    }
                }
                2 => {
                    if *a != 0.0 && x >= -b / a {
                        pow(a * x + b, *g) + c
                    } else {
                        *c
                    }
                }
                3 => {
                    if x >= *d {
                        pow(a * x + b, *g)
                    } else {
                        c * x
                    }
                }
                _ => {
                    if x >= *d {
                        pow(a * x + b, *g) + e
                    } else {
                        c * x + f
                    }
                }
            },
        };
        if y.is_finite() {
            y.clamp(0.0, 1.0)
        } else {
            0.0
        }
    }
}

/// `base^exp` with a negative base read as 0 — the ICC formulas are only
/// defined for a non-negative base, and `f64::powf` would answer NaN.
fn pow(base: f64, exp: f64) -> f64 {
    if base <= 0.0 {
        0.0
    } else {
        base.powf(exp)
    }
}

/// A profile we can actually transform with: the three D50-adapted matrix
/// columns and the three tone curves.
///
/// **The PCS white is always D50 and `wtpt`/`chad` are advisory.** For a
/// matrix/TRC profile the ICC spec requires `rXYZ`/`gXYZ`/`bXYZ` to be
/// already D50-adapted; `chad` merely RECORDS the adaptation that was
/// applied so a CMM can recover the native white. Adapting again with
/// either tag double-adapts. The proof ships with macOS: `sRGB Profile.icc`
/// has D50-adapted columns, no `chad` tag at all, and a `wtpt` holding the
/// unadapted D65 (0.950455, 1.0, 1.089050) — a reader that trusts `wtpt` as
/// the PCS white gets sRGB visibly wrong.
#[derive(Clone, Debug)]
pub struct MatrixTrc {
    /// COLUMNS of the profile→PCS matrix: `to_pcs[c]` is the D50-adapted
    /// XYZ of channel `c` at full intensity (r, g, b in that order), so
    /// `XYZ = Σ_c to_pcs[c] · linear[c]`.
    to_pcs: [[f64; 3]; 3],
    /// ROWS of its inverse, the PCS→profile matrix:
    /// `linear[i] = Σ_k from_pcs[i][k] · XYZ[k]`. Computed once at
    /// construction, which is also where a singular matrix is refused.
    from_pcs: [[f64; 3]; 3],
    /// rTRC, gTRC, bTRC.
    trc: [Curve; 3],
}

impl MatrixTrc {
    /// Builds the model from the three matrix columns and the three curves.
    /// `None` when the columns are not an invertible basis (collinear
    /// primaries, or all-zero tags) — that profile describes no colour space
    /// this crate can convert through, and is reported as unmodellable
    /// rather than as an error.
    pub fn new(to_pcs: [[f64; 3]; 3], trc: [Curve; 3]) -> Option<MatrixTrc> {
        if !to_pcs.iter().all(|col| col.iter().all(|v| v.is_finite())) {
            return None;
        }
        let from_pcs = invert(to_pcs)?;
        Some(MatrixTrc {
            to_pcs,
            from_pcs,
            trc,
        })
    }

    /// True when converting between the two would change nothing: the
    /// COMBINED matrix `inv(other.to_pcs) · self.to_pcs` is within
    /// [`MATRIX_TOL`] of the identity in every entry AND the three curve
    /// pairs agree within [`TRC_TOL`] at 256 evenly spaced inputs. See
    /// [`MATRIX_TOL`] for why the combination is compared and not the
    /// entries.
    pub fn approx_eq(&self, other: &MatrixTrc) -> bool {
        let combined = self.combined_with(other);
        for (i, row) in combined.iter().enumerate() {
            for (c, &v) in row.iter().enumerate() {
                let target = if i == c { 1.0 } else { 0.0 };
                if (v - target).abs() > MATRIX_TOL {
                    return false;
                }
            }
        }
        for (mine, theirs) in self.trc.iter().zip(other.trc.iter()) {
            for s in 0..256 {
                let x = f64::from(s) / 255.0;
                if (mine.eval(x) - theirs.eval(x)).abs() > TRC_TOL {
                    return false;
                }
            }
        }
        true
    }

    /// `inv(dst.to_pcs) · self.to_pcs`, row-major: the matrix a conversion
    /// from `self` to `dst` applies to linear RGB.
    fn combined_with(&self, dst: &MatrixTrc) -> [[f64; 3]; 3] {
        let mut out = [[0.0f64; 3]; 3];
        for (i, row) in out.iter_mut().enumerate() {
            for (c, entry) in row.iter_mut().enumerate() {
                *entry = (0..3).map(|k| dst.from_pcs[i][k] * self.to_pcs[c][k]).sum();
            }
        }
        out
    }
}

/// Inverts a matrix given by its COLUMNS, returning ROWS of the inverse.
/// `None` for a determinant too small to trust (see [`MIN_DET`]).
fn invert(cols: [[f64; 3]; 3]) -> Option<[[f64; 3]; 3]> {
    // m[row][col]; cols[c] is column c.
    let m = |r: usize, c: usize| cols[c][r];
    let det = m(0, 0) * (m(1, 1) * m(2, 2) - m(1, 2) * m(2, 1))
        - m(0, 1) * (m(1, 0) * m(2, 2) - m(1, 2) * m(2, 0))
        + m(0, 2) * (m(1, 0) * m(2, 1) - m(1, 1) * m(2, 0));
    if !det.is_finite() || det.abs() < MIN_DET {
        return None;
    }
    let cof = |r: usize, c: usize| {
        let (r0, r1) = ((r + 1) % 3, (r + 2) % 3);
        let (c0, c1) = ((c + 1) % 3, (c + 2) % 3);
        m(r0, c0) * m(r1, c1) - m(r0, c1) * m(r1, c0)
    };
    let mut inv = [[0.0f64; 3]; 3];
    for (r, row) in inv.iter_mut().enumerate() {
        for (c, entry) in row.iter_mut().enumerate() {
            // inv[r][c] = cofactor(c, r) / det (adjugate = transposed
            // cofactor matrix).
            *entry = cof(c, r) / det;
        }
    }
    Some(inv)
}

/// A prepared source→destination conversion. See the module doc for the
/// decode table and the threshold encode.
pub struct Transform {
    /// `col[c][v]` is source channel `c`'s contribution, for input byte `v`,
    /// to the three DESTINATION linear channels — the combined matrix's
    /// column `c` scaled by the source curve at `v / 255`.
    col: [[[f32; 3]; 256]; 3],
    /// `thresh[c][k]` is the destination linear value at which output code
    /// `k` rounds up to `k + 1`: the destination curve evaluated FORWARD at
    /// `(k + 0.5) / 255`, made monotone by a running maximum.
    thresh: [[f32; 255]; 3],
}

impl Transform {
    /// Prepares the conversion from `src` to `dst`.
    pub fn new(src: &MatrixTrc, dst: &MatrixTrc) -> Transform {
        let combined = src.combined_with(dst);
        let mut col = [[[0.0f32; 3]; 256]; 3];
        for (c, channel) in col.iter_mut().enumerate() {
            for (v, entry) in channel.iter_mut().enumerate() {
                let lin = src.trc[c].eval(v as f64 / 255.0);
                for (i, slot) in entry.iter_mut().enumerate() {
                    *slot = (combined[i][c] * lin) as f32;
                }
            }
        }
        let mut thresh = [[0.0f32; 255]; 3];
        for (c, channel) in thresh.iter_mut().enumerate() {
            let mut run = f64::NEG_INFINITY;
            for (k, slot) in channel.iter_mut().enumerate() {
                // The running maximum is defensive: a pathological `para`
                // can be non-monotone, and the binary search below requires
                // a sorted array. A monotone curve is unaffected.
                run = run.max(dst.trc[c].eval((k as f64 + 0.5) / 255.0));
                *slot = run as f32;
            }
        }
        Transform { col, thresh }
    }

    /// The transform from `src` to `dst`, or `None` when the two describe
    /// the SAME space — the [`MatrixTrc::approx_eq`] rule, asked once here
    /// so "there is nothing to convert" has one spelling: a document op
    /// refuses (no phantom undo step) and a compositing caller leaves its
    /// colours exactly as authored (no requantization of an sRGB colour on
    /// an sRGB document).
    pub(crate) fn between(src: &MatrixTrc, dst: &MatrixTrc) -> Option<Transform> {
        (!src.approx_eq(dst)).then(|| Transform::new(src, dst))
    }

    /// One straight RGB triple converted — the ONE per-colour step, run by
    /// [`Transform::apply`] over a buffer and by `style_composite` over an
    /// authored layer-style colour.
    pub(crate) fn color(&self, rgb: [u8; 3]) -> [u8; 3] {
        let (cr, cg, cb) = (
            &self.col[0][rgb[0] as usize],
            &self.col[1][rgb[1] as usize],
            &self.col[2][rgb[2] as usize],
        );
        let mut out = [0u8; 3];
        for (i, o) in out.iter_mut().enumerate() {
            let lin = (cr[i] + cg[i] + cb[i]).clamp(0.0, 1.0);
            // `partition_point` counts the thresholds strictly below `lin`,
            // which is the output code — always in 0..=255, so the cast is
            // total.
            *o = self.thresh[i].partition_point(|&t| t < lin) as u8;
        }
        out
    }

    /// Converts straight (non-premultiplied) RGBA8 pixels in place. Alpha is
    /// copied untouched.
    pub fn apply(&self, pixels: &mut RgbaImage) {
        for px in pixels.chunks_exact_mut(4) {
            let out = self.color([px[0], px[1], px[2]]);
            px[..3].copy_from_slice(&out);
        }
    }
}
