//! `curves`: the per-channel point lists of an adjustment, resolved into
//! 256-entry lookup tables at parse time. The payload, its `parse` and its
//! kernel live here; `adjust` keeps only the schema row and the dispatch.
//!
//! Each supplied point list is sorted by `in` (a stable sort, so of two
//! points sharing an `in` value the first listed wins and later duplicates
//! are dropped; fewer than 2 distinct `in` values is malformed) and turned
//! into a 256-entry lookup table via monotone cubic (Fritsch–Carlson)
//! interpolation, which passes through every control point exactly and
//! never overshoots — monotone input points produce a monotone table.
//! Inputs outside the listed `in` range take the nearest endpoint's `out`
//! value. The identity point list `[[0, 0], [255, 255]]` produces the
//! identity table. Application order per channel: the per-channel table
//! first, then the master `rgb` table — `out = rgb_lut[channel_lut[v]]`.

use serde_json::{Map, Value};

/// The 256-entry per-channel lookup tables of a parsed `curves` op, built
/// once at parse time (missing channels are the identity table).
#[derive(Clone)]
pub(crate) struct CurveLuts {
    r: [u8; 256],
    g: [u8; 256],
    b: [u8; 256],
    rgb: [u8; 256],
}

impl CurveLuts {
    /// Parses the `curves` params per the schema row in `adjust`.
    pub(crate) fn parse(params: &Map<String, Value>) -> Option<CurveLuts> {
        let mut luts = CurveLuts {
            r: identity_lut(),
            g: identity_lut(),
            b: identity_lut(),
            rgb: identity_lut(),
        };
        for (key, lut) in [
            ("r", &mut luts.r),
            ("g", &mut luts.g),
            ("b", &mut luts.b),
            ("rgb", &mut luts.rgb),
        ] {
            if let Some(value) = params.get(key) {
                *lut = monotone_lut(&parse_points(value)?);
            }
        }
        Some(luts)
    }

    /// One straight RGB triple in [0, 1]: quantize to a table index, the
    /// per-channel table first, then the master `rgb` table.
    pub(crate) fn apply(&self, rgb: [f32; 3]) -> [f32; 3] {
        let idx = rgb.map(|v| (v * 255.0).round() as usize);
        [
            f32::from(self.rgb[usize::from(self.r[idx[0]])]) / 255.0,
            f32::from(self.rgb[usize::from(self.g[idx[1]])]) / 255.0,
            f32::from(self.rgb[usize::from(self.b[idx[2]])]) / 255.0,
        ]
    }
}

/// Parses one curves point list: 2..=16 `[in, out]` pairs, values clamped to
/// [0, 255], sorted by `in` with duplicate `in`s dropped (first listed wins).
/// `None` on any structural violation or fewer than 2 distinct `in` values.
fn parse_points(value: &Value) -> Option<Vec<(f64, f64)>> {
    let list = value.as_array()?;
    if !(2..=16).contains(&list.len()) {
        return None;
    }
    let mut points = Vec::with_capacity(list.len());
    for entry in list {
        let pair = entry.as_array()?;
        if pair.len() != 2 {
            return None;
        }
        let x = pair[0].as_f64()?.clamp(0.0, 255.0);
        let y = pair[1].as_f64()?.clamp(0.0, 255.0);
        points.push((x, y));
    }
    points.sort_by(|a, b| a.0.total_cmp(&b.0));
    points.dedup_by(|next, kept| next.0 == kept.0);
    if points.len() < 2 {
        return None;
    }
    Some(points)
}

/// Builds a 256-entry LUT through `points` (sorted, distinct `x`, len >= 2,
/// values in [0, 255]) by monotone cubic (Fritsch–Carlson) interpolation:
/// secant slopes, averaged tangents zeroed across sign changes and at flat
/// segments, then the circle limit (alpha^2 + beta^2 <= 9) that guarantees
/// monotonicity on monotone data. Inputs outside the point range clamp to
/// the nearest endpoint's value.
fn monotone_lut(points: &[(f64, f64)]) -> [u8; 256] {
    let n = points.len();
    let mut d = vec![0.0f64; n - 1];
    for k in 0..n - 1 {
        d[k] = (points[k + 1].1 - points[k].1) / (points[k + 1].0 - points[k].0);
    }
    let mut m = vec![0.0f64; n];
    m[0] = d[0];
    m[n - 1] = d[n - 2];
    for k in 1..n - 1 {
        m[k] = if d[k - 1] * d[k] <= 0.0 {
            0.0
        } else {
            (d[k - 1] + d[k]) / 2.0
        };
    }
    for k in 0..n - 1 {
        if d[k] == 0.0 {
            m[k] = 0.0;
            m[k + 1] = 0.0;
            continue;
        }
        let alpha = m[k] / d[k];
        let beta = m[k + 1] / d[k];
        let s = alpha * alpha + beta * beta;
        if s > 9.0 {
            let tau = 3.0 / s.sqrt();
            m[k] = tau * alpha * d[k];
            m[k + 1] = tau * beta * d[k];
        }
    }
    std::array::from_fn(|i| {
        let x = i as f64;
        if x <= points[0].0 {
            return points[0].1.round() as u8;
        }
        if x >= points[n - 1].0 {
            return points[n - 1].1.round() as u8;
        }
        let k = points.partition_point(|p| p.0 <= x) - 1;
        let h = points[k + 1].0 - points[k].0;
        let t = (x - points[k].0) / h;
        let t2 = t * t;
        let t3 = t2 * t;
        let y = points[k].1 * (2.0 * t3 - 3.0 * t2 + 1.0)
            + h * m[k] * (t3 - 2.0 * t2 + t)
            + points[k + 1].1 * (-2.0 * t3 + 3.0 * t2)
            + h * m[k + 1] * (t3 - t2);
        y.clamp(0.0, 255.0).round() as u8
    })
}

/// The identity lookup table (a missing curves channel).
fn identity_lut() -> [u8; 256] {
    std::array::from_fn(|i| i as u8)
}
