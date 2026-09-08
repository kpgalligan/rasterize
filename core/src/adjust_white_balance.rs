//! The `white_balance` adjustment: a temperature and a tint describing the
//! ILLUMINANT the pixels were shot under, Bradford-adapted to D65.
//!
//! # The direction, stated once
//!
//! **The two parameters describe the light the picture was taken in; the op
//! adapts THAT white to D65.** Everything follows from that sentence:
//!
//! * a HIGHER kelvin means "the light was bluer than I assumed", so removing
//!   it WARMS the image;
//! * a POSITIVE tint means "the light was greener", so removing it pushes
//!   the image toward MAGENTA.
//!
//! Both are Adobe Camera Raw's directions, which is what a photographer's
//! hand expects from the two sliders.
//!
//! # Tint runs along the ISOTHERM, not along `+v`
//!
//! The two sliders must be independent: moving Tint may not change the
//! correlated colour temperature of the white it describes, or a
//! photographer killing a fluorescent green cast would silently re-warm the
//! picture and could not undo it with Temperature.
//!
//! In the CIE 1960 UCS the line of constant CCT through a locus point is the
//! locus NORMAL (that is what "correlated" means — Robertson's isotherms are
//! perpendicular to the locus in exactly this diagram, which is why the UCS
//! is the space CCT is defined in). So the tint offset is taken along that
//! normal. Offsetting `v` alone — the obvious spelling, and the one this
//! module used to carry — is wrong wherever the locus is not horizontal, and
//! it is nearly vertical over the whole daylight range: at 6504 K the unit
//! tangent is `(-0.580, -0.815)`, so a pure `+v` step spends 81 % of itself
//! running ALONG the locus (a CCT change: +50 tint dropped the implied white
//! from 6504 K to about 5360 K, a blue cast 2.2x the magenta correction) and
//! only 58 % on the green-magenta axis it advertises.
//!
//! With the tangent `(du, dv)` pointing toward rising temperature — `u` and
//! `v` both fall over the whole 1667..25000 K range, so this direction is
//! toward blue — the GREEN half of the normal is `(dv, -du)`, whose `v`
//! component `-du` is positive everywhere. A positive tint (a greener source
//! white) therefore steps `k * (dv, -du)` with `k = tint/3000`.
//!
//! The `/3000` divisor is ours and is unchanged by the correction: it used
//! to scale a pure `+v` step and now scales a UNIT step along the normal, so
//! the offset keeps its old LENGTH and only turns. Measured on a mid-grey,
//! tint +150 moves Lab a* by about +29 and tint -150 by about -35, against
//! the temperature slider's own b* span of -62 (1667 K) to +22 (25000 K) —
//! the "roughly the same visual range" the two sliders are meant to have,
//! now without the cross-talk. It is published in the schema row.
//!
//! # The pipeline, and why it collapses to one matrix
//!
//! ```text
//! encoded RGB -> sRGB EOTF -> linear RGB -> sRGB(D65) primaries -> XYZ
//!             -> Bradford(W_source -> D65) -> XYZ
//!             -> sRGB(D65) primaries inverse -> linear RGB -> sRGB OETF
//! ```
//!
//! Every stage but the middle one is a constant matrix, so the whole thing
//! is precomputed at parse time as ONE 3x3 on linear RGB. The primaries are
//! sRGB's whatever the document's profile, for the reason `adjust_math`'s
//! module doc gives: an adjustment carries no profile, and a
//! profile-dependent kernel would make the destructive twin and the layer
//! disagree.
//!
//! # The identity is snapped, not merely close
//!
//! The CCT -> chromaticity fits below are accurate to about 1e-4, so the
//! white they return for 6504 K is `(0.95015, 1, 1.08826)` against D65's
//! published `(0.95047, 1, 1.08883)` — a matrix a hair off the identity that
//! would move a few 8-bit codes and make "the default does nothing" false.
//! The default is therefore snapped to the exact identity, and so is any
//! (temperature, tint) whose computed white lands within 1e-6 of D65.
//!
//! # Provenance of the numbers
//!
//! Bradford `M_A` and its published inverse; the CIE D-series daylight locus
//! cubics for 4000 K and above (two branches, split at 7000 K) with
//! `y = -3x^2 + 2.87x - 0.275`; Kim et al.'s Planckian cubics below 4000 K
//! (two `y` branches, split at 2222 K); the CIE 1960 UCS `uv` round trip and
//! Robertson's normal-to-the-locus isotherms for the tint; and Lindbloom's
//! sRGB/XYZ matrix pair. Sanity values the tests
//! reproduce independently: 5000 K -> xy (0.34574, 0.35867) against the
//! published D50 (0.34567, 0.35850), and 6504 K -> (0.31271, 0.32912)
//! against D65's (0.31270, 0.32900) — both within the fits' own 1e-4.

use serde_json::{Map, Value};

use crate::adjust_math::{linear_to_srgb, srgb_to_linear};
use crate::adjust_parse::num_in;

/// The Bradford cone-response matrix.
const BRADFORD: [[f64; 3]; 3] = [
    [0.8951, 0.2664, -0.1614],
    [-0.7502, 1.7135, 0.0367],
    [0.0389, -0.0685, 1.0296],
];

/// Its published inverse (agrees with the computed inverse to 7 decimals).
const BRADFORD_INV: [[f64; 3]; 3] = [
    [0.9869929, -0.1470543, 0.1599627],
    [0.4323053, 0.5183603, 0.0492912],
    [-0.0085287, 0.0400428, 0.9684867],
];

/// The standard D65 white as XYZ. Deliberately the PUBLISHED triple rather
/// than one derived from `xy = (0.3127, 0.3290)`, which gives
/// `(0.950456, 1, 1.089058)` — close, but different in the 4th decimal, and
/// the gap shows up in the 7th decimal of every adapted matrix.
const D65: [f64; 3] = [0.95047, 1.00000, 1.08883];

/// sRGB linear RGB -> XYZ (D65), Lindbloom.
const SRGB_TO_XYZ: [[f64; 3]; 3] = [
    [0.4124564, 0.3575761, 0.1804375],
    [0.2126729, 0.7151522, 0.0721750],
    [0.0193339, 0.1191920, 0.9503041],
];

/// XYZ (D65) -> sRGB linear RGB, Lindbloom.
const XYZ_TO_SRGB: [[f64; 3]; 3] = [
    [3.2404542, -1.5371385, -0.4985314],
    [-0.9692660, 1.8760108, 0.0415560],
    [0.0556434, -0.2040259, 1.0572252],
];

const IDENTITY: [[f32; 3]; 3] = [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]];

/// A parsed `white_balance` op: the derived 3x3 on LINEAR sRGB.
#[derive(Clone)]
pub(crate) struct WhiteBalance {
    matrix: [[f32; 3]; 3],
}

impl WhiteBalance {
    /// Parses the `white_balance` params per the schema row in `adjust`.
    pub(crate) fn parse(params: &Map<String, Value>) -> Option<WhiteBalance> {
        let temperature = num_in(params, "temperature", 1667.0..=25000.0, 6504.0)?;
        let tint = num_in(params, "tint", -150.0..=150.0, 0.0)?;
        Some(WhiteBalance {
            matrix: matrix_for(temperature, tint),
        })
    }

    /// One straight RGB triple in [0, 1], through the linear round trip.
    pub(crate) fn apply(&self, rgb: [f32; 3]) -> [f32; 3] {
        let lin = rgb.map(srgb_to_linear);
        self.matrix
            .map(|row| linear_to_srgb(row[0] * lin[0] + row[1] * lin[1] + row[2] * lin[2]))
    }
}

/// The linear-RGB matrix for one (temperature, tint) pair, with the exact
/// identity at the default and at any pair whose white IS D65.
fn matrix_for(temperature: f32, tint: f32) -> [[f32; 3]; 3] {
    if temperature == 6504.0 && tint == 0.0 {
        return IDENTITY;
    }
    let source = source_white(f64::from(temperature), f64::from(tint));
    if source.iter().zip(D65).all(|(a, b)| (a - b).abs() < 1e-6) {
        return IDENTITY;
    }
    let adapt = bradford(source, D65);
    let combined = mat_mul(XYZ_TO_SRGB, mat_mul(adapt, SRGB_TO_XYZ));
    combined.map(|row| row.map(|v| v as f32))
}

/// The XYZ of the illuminant a (temperature, tint) pair describes: the CCT
/// locus for the chromaticity, then the tint as a shift off it ALONG THE
/// ISOTHERM — the locus normal — in the CIE 1960 UCS. See the module doc for
/// why the offset is not simply `+v`.
fn source_white(temperature: f64, tint: f64) -> [f64; 3] {
    // xy -> uv (CIE 1960), step off the locus, and back.
    let (u0, v0) = xy_to_uv(locus_xy(temperature));
    // The unit tangent points toward rising temperature (toward blue), so
    // its green-side normal is `(dv, -du)`.
    let (du, dv) = locus_tangent_uv(temperature);
    let k = tint / 3000.0;
    let u = u0 + k * dv;
    let v = v0 - k * du;
    let den2 = 2.0 * u - 8.0 * v + 4.0;
    let x2 = 3.0 * u / den2;
    let y2 = 2.0 * v / den2;
    // A degenerate y (only reachable if the fits themselves went wrong)
    // would divide by zero; D65 is the honest fallback.
    if !(y2.is_finite() && y2.abs() > 1e-9) {
        return D65;
    }
    [x2 / y2, 1.0, (1.0 - x2 - y2) / y2]
}

/// CIE xy to the CIE 1960 UCS `uv`.
fn xy_to_uv((x, y): (f64, f64)) -> (f64, f64) {
    let den = -2.0 * x + 12.0 * y + 3.0;
    (4.0 * x / den, 6.0 * y / den)
}

/// The UNIT tangent to the CCT locus at `t`, in the CIE 1960 UCS, pointing
/// toward rising temperature. Taken by finite difference because
/// [`locus_xy`] is a table of empirical cubics, not something worth
/// differentiating by hand.
///
/// The difference is one-sided and kept INSIDE the branch that contains `t`:
/// the Planckian and daylight fits do not meet exactly at their 4000 K seam
/// (x jumps 0.38053 to 0.38234 there), so a centred difference straddling it
/// would measure the seam rather than the curve — it reports the tangent's
/// `v` component as +0.77 at 4000 K where the true value is about -0.53.
/// Every branch is at least 1778 K wide against a step of at most 25 K, so
/// there is always room on one side.
fn locus_tangent_uv(t: f64) -> (f64, f64) {
    // A 0.1 % step: small enough that the cubics are locally straight,
    // large enough that the difference is not eaten by f64 rounding.
    let step = (t * 1e-3).max(0.5);
    let (branch_lo, branch_hi) = branch_bounds(t);
    let (lo, hi) = if branch_hi - t >= step {
        (t, t + step)
    } else {
        (t - step, t)
    };
    let (u0, v0) = xy_to_uv(locus_xy(lo.max(branch_lo)));
    let (u1, v1) = xy_to_uv(locus_xy(hi));
    let (du, dv) = (u1 - u0, v1 - v0);
    let len = du.hypot(dv);
    // Unreachable for the real fits (the locus never stalls), but a zero
    // length would divide by zero; the near-vertical direction the daylight
    // range has is the harmless fallback.
    if !(len.is_finite() && len > 1e-15) {
        return (0.0, -1.0);
    }
    (du / len, dv / len)
}

/// The half-open temperature interval over which [`locus_xy`] is one smooth
/// fit. Mirrors that function's branches exactly.
fn branch_bounds(t: f64) -> (f64, f64) {
    if t < 2222.0 {
        (f64::MIN, 2222.0)
    } else if t < 4000.0 {
        (2222.0, 4000.0)
    } else if t <= 7000.0 {
        (4000.0, 7000.0)
    } else {
        (7000.0, f64::MAX)
    }
}

/// Correlated colour temperature to chromaticity: the CIE D-series daylight
/// cubics at and above 4000 K, Kim et al.'s Planckian cubics below it.
fn locus_xy(t: f64) -> (f64, f64) {
    if t >= 4000.0 {
        let x = if t <= 7000.0 {
            -4.6070e9 / t.powi(3) + 2.9678e6 / (t * t) + 0.09911e3 / t + 0.244063
        } else {
            -2.0064e9 / t.powi(3) + 1.9018e6 / (t * t) + 0.24748e3 / t + 0.237040
        };
        (x, -3.000 * x * x + 2.870 * x - 0.275)
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

/// The Bradford chromatic-adaptation matrix from source white to
/// destination white, both XYZ: `M_A^-1 . diag(cone_d / cone_s) . M_A`.
fn bradford(source: [f64; 3], dest: [f64; 3]) -> [[f64; 3]; 3] {
    let cone_s = mat_vec(BRADFORD, source);
    let cone_d = mat_vec(BRADFORD, dest);
    let mut scaled = BRADFORD;
    for (row, (d, s)) in scaled.iter_mut().zip(cone_d.iter().zip(cone_s.iter())) {
        // A zero source cone response is impossible for a real white, but a
        // guard costs nothing and keeps an infinity out of the matrix.
        let k = if s.abs() > 1e-12 { d / s } else { 1.0 };
        for entry in row.iter_mut() {
            *entry *= k;
        }
    }
    mat_mul(BRADFORD_INV, scaled)
}

/// Row-major 3x3 times 3x3.
fn mat_mul(a: [[f64; 3]; 3], b: [[f64; 3]; 3]) -> [[f64; 3]; 3] {
    let mut out = [[0.0f64; 3]; 3];
    for (i, row) in out.iter_mut().enumerate() {
        for (j, entry) in row.iter_mut().enumerate() {
            *entry = (0..3).map(|k| a[i][k] * b[k][j]).sum();
        }
    }
    out
}

/// Row-major 3x3 times a column vector.
fn mat_vec(m: [[f64; 3]; 3], v: [f64; 3]) -> [f64; 3] {
    m.map(|row| row[0] * v[0] + row[1] * v[1] + row[2] * v[2])
}
