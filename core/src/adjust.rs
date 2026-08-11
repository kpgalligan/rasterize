//! Adjustment layers: the ONE meta shape the core interprets. A layer whose
//! `meta` parses as an [`Adjustment`] is composited by `doc` as a
//! non-destructive color adjustment of the accumulated backdrop instead of as
//! pixels (the layer's own pixels are ignored). Anything that does not parse
//! composites as an ordinary raster layer — the same graceful degradation as
//! text meta. The per-pixel math mirrors the destructive filters in `ops` /
//! `ops_filters` exactly, so applying an adjustment layer and running the
//! matching destructive filter produce the same image.
//!
//! # Meta schema (the contract the host codes against)
//!
//! ```json
//! {"type": "adjust", "op": "<op>", "params": { ... }}
//! ```
//!
//! `type` must be exactly the string `"adjust"` and `op` one of the nine
//! operation names below; `params` is an object and may be omitted entirely
//! when every parameter has a default. Unknown keys — top-level or inside
//! `params` — are ignored (room for host-side versioning). A missing optional
//! parameter takes its default; a parameter that is present but has the wrong
//! JSON type, or a value outside a REQUIRED range, makes the whole meta
//! malformed (`from_meta` returns `None` and the layer composites as a plain
//! raster layer). All numbers are JSON numbers (integers accepted wherever a
//! float is expected, and vice versa where noted).
//!
//! | op            | params (key: type, range, default)                       |
//! |---------------|----------------------------------------------------------|
//! | `"bcs"`       | `brightness`, `contrast`, `saturation`: floats, each     |
//! |               | CLAMPED to [-1, 1] (out-of-range values are not an       |
//! |               | error), default 0 = identity. Applied in that order,     |
//! |               | mirroring `rz_image_adjust`.                             |
//! | `"levels"`    | `black`: float, default 0; `white`: float, default 1;    |
//! |               | requires 0 <= black < white <= 1. `gamma`: float in      |
//! |               | [0.1, 10], default 1. Mirrors `rz_image_levels`.         |
//! | `"hue_rotate"`| `degrees`: float, any finite angle, default 0. Mirrors   |
//! |               | `rz_image_hue_rotate` (SVG feColorMatrix hueRotate).     |
//! | `"threshold"` | `level`: float in [0, 1], default 0.5. Mirrors           |
//! |               | `rz_image_threshold` (Rec. 709 luma >= level).           |
//! | `"posterize"` | `levels`: integer in [2, 64], REQUIRED (a float with a   |
//! |               | zero fraction, e.g. `5.0`, is accepted). Mirrors         |
//! |               | `rz_image_posterize`.                                    |
//! | `"curves"`    | `rgb`, `r`, `g`, `b`: each OPTIONAL, an array of 2..=16  |
//! |               | `[in, out]` pairs, both numbers in [0, 255] (values are  |
//! |               | defensively clamped into that range). A missing channel  |
//! |               | is the identity. See below.                              |
//! | `"invert"`    | none                                                     |
//! | `"grayscale"` | none                                                     |
//! | `"sepia"`     | none                                                     |
//!
//! ## Curves
//!
//! Each supplied point list is sorted by `in` (a stable sort, so of two
//! points sharing an `in` value the first listed wins and later duplicates
//! are dropped; fewer than 2 distinct `in` values is malformed) and turned
//! into a 256-entry lookup table at parse time via monotone cubic
//! (Fritsch–Carlson) interpolation, which passes through every control point
//! exactly and never overshoots — monotone input points produce a monotone
//! table. Inputs outside the listed `in` range take the nearest endpoint's
//! `out` value. The identity point list `[[0, 0], [255, 255]]` produces the
//! identity table. Application order per channel: the per-channel table
//! first, then the master `rgb` table — `out = rgb_lut[channel_lut[v]]`.
//!
//! # Application
//!
//! [`Adjustment::apply`] maps one straight (non-premultiplied) RGB triple in
//! [0, 1] to another; alpha never enters and is NEVER modified by any
//! adjustment. The compositor's accumulator already holds straight color, so
//! no unpremultiply round-trip is needed there.

use serde_json::{Map, Value};

use crate::ops_filters::hue_rotate_matrix;

/// Rec. 709 luma coefficients (private copy; `ops`, `ops_filters` and `doc`
/// keep their own).
const LUMA_R: f32 = 0.2126;
const LUMA_G: f32 = 0.7152;
const LUMA_B: f32 = 0.0722;

/// The 256-entry per-channel lookup tables of a parsed `curves` op, built
/// once at parse time (missing channels are the identity table).
pub(crate) struct CurveLuts {
    r: [u8; 256],
    g: [u8; 256],
    b: [u8; 256],
    rgb: [u8; 256],
}

/// One parsed color adjustment. Derived values (the contrast slope, the hue
/// matrix, curve LUTs) are computed at parse time so [`Adjustment::apply`]
/// is cheap per pixel.
pub(crate) enum Adjustment {
    /// Brightness/contrast/saturation, mirroring `ops::adjust`: the stored
    /// values are the pre-clamped brightness and the derived slope/scale.
    Bcs {
        brightness: f32,
        contrast_slope: f32,
        saturation_scale: f32,
    },
    /// Levels, mirroring `ops_filters::levels` (range = white - black).
    Levels {
        black: f32,
        range: f32,
        inv_gamma: f32,
    },
    /// Hue rotation, mirroring `ops_filters::hue_rotate`.
    HueRotate { matrix: [[f32; 3]; 3] },
    /// Luma threshold, mirroring `ops_filters::threshold`.
    Threshold { level: f32 },
    /// Posterize, mirroring `ops_filters::posterize` (steps = levels - 1).
    Posterize { steps: f32 },
    /// Per-channel curves through cached LUTs.
    Curves(Box<CurveLuts>),
    /// Channel inversion, mirroring `ops::invert`.
    Invert,
    /// Rec. 709 grayscale, mirroring `ops::grayscale`.
    Grayscale,
    /// Sepia matrix, mirroring `ops::sepia`.
    Sepia,
}

/// Reads `params[key]` as a number, with `default` when the key is absent.
/// A present non-number value is malformed (`None`). JSON cannot encode NaN
/// or infinities, so the result is always finite.
fn num(params: &Map<String, Value>, key: &str, default: f64) -> Option<f64> {
    match params.get(key) {
        None => Some(default),
        Some(v) => v.as_f64(),
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

impl Adjustment {
    /// Parses a layer's meta as an adjustment description per the module-level
    /// schema. `None` for anything else — non-JSON, a different `type`, an
    /// unknown `op`, or invalid params — in which case the layer composites
    /// as an ordinary raster layer.
    pub(crate) fn from_meta(meta: &str) -> Option<Adjustment> {
        let root: Value = serde_json::from_str(meta).ok()?;
        let obj = root.as_object()?;
        if obj.get("type")?.as_str()? != "adjust" {
            return None;
        }
        let op = obj.get("op")?.as_str()?;
        let empty = Map::new();
        let params = match obj.get("params") {
            None => &empty,
            Some(v) => v.as_object()?,
        };
        match op {
            "bcs" => {
                // Mirrors `ops::adjust`: each control clamps to [-1, 1]
                // rather than refusing, and the slope/scale floors at 0.
                let brightness = num(params, "brightness", 0.0)? as f32;
                let contrast = num(params, "contrast", 0.0)? as f32;
                let saturation = num(params, "saturation", 0.0)? as f32;
                Some(Adjustment::Bcs {
                    brightness: brightness.clamp(-1.0, 1.0),
                    contrast_slope: (1.0 + contrast.clamp(-1.0, 1.0)).max(0.0),
                    saturation_scale: (1.0 + saturation.clamp(-1.0, 1.0)).max(0.0),
                })
            }
            "levels" => {
                let black = num(params, "black", 0.0)? as f32;
                let white = num(params, "white", 1.0)? as f32;
                let gamma = num(params, "gamma", 1.0)? as f32;
                // The exact validity condition of `ops_filters::levels`.
                if !(black >= 0.0 && black < white && white <= 1.0 && (0.1..=10.0).contains(&gamma))
                {
                    return None;
                }
                Some(Adjustment::Levels {
                    black,
                    range: white - black,
                    inv_gamma: 1.0 / gamma,
                })
            }
            "hue_rotate" => {
                let degrees = num(params, "degrees", 0.0)? as f32;
                // JSON numbers are finite, but the f64 -> f32 narrowing can
                // overflow to infinity; refuse like `ops_filters::hue_rotate`.
                if !degrees.is_finite() {
                    return None;
                }
                Some(Adjustment::HueRotate {
                    matrix: hue_rotate_matrix(degrees),
                })
            }
            "threshold" => {
                let level = num(params, "level", 0.5)? as f32;
                if !(0.0..=1.0).contains(&level) {
                    return None;
                }
                Some(Adjustment::Threshold { level })
            }
            "posterize" => {
                // Required; integral floats (e.g. 5.0) are accepted, the
                // range is `ops_filters::posterize`'s 2..=64.
                let levels = params.get("levels")?.as_f64()?;
                if levels.fract() != 0.0 || !(2.0..=64.0).contains(&levels) {
                    return None;
                }
                Some(Adjustment::Posterize {
                    steps: (levels - 1.0) as f32,
                })
            }
            "curves" => {
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
                Some(Adjustment::Curves(Box::new(luts)))
            }
            "invert" => Some(Adjustment::Invert),
            "grayscale" => Some(Adjustment::Grayscale),
            "sepia" => Some(Adjustment::Sepia),
            _ => None,
        }
    }

    /// Applies the adjustment to one straight (non-premultiplied) RGB triple
    /// in [0, 1], returning a triple clamped back into [0, 1]. Alpha never
    /// enters: no adjustment reads or modifies it. The math mirrors the
    /// matching destructive filter per component (worked in normalized [0, 1]
    /// space, so the two can differ by at most one 8-bit rounding step).
    pub(crate) fn apply(&self, rgb: [f32; 3]) -> [f32; 3] {
        let rgb = [
            rgb[0].clamp(0.0, 1.0),
            rgb[1].clamp(0.0, 1.0),
            rgb[2].clamp(0.0, 1.0),
        ];
        let out = match self {
            // `ops::adjust`: brightness, then contrast about 0.5, then
            // luma-anchored saturation.
            Adjustment::Bcs {
                brightness,
                contrast_slope,
                saturation_scale,
            } => {
                let mut ch = rgb;
                for v in &mut ch {
                    *v += brightness;
                    *v = (*v - 0.5) * contrast_slope + 0.5;
                }
                let luma = LUMA_R * ch[0] + LUMA_G * ch[1] + LUMA_B * ch[2];
                for v in &mut ch {
                    *v = luma + (*v - luma) * saturation_scale;
                }
                ch
            }
            // `ops_filters::levels`: map [black, white] to [0, 1], then gamma.
            Adjustment::Levels {
                black,
                range,
                inv_gamma,
            } => rgb.map(|v| ((v - black) / range).clamp(0.0, 1.0).powf(*inv_gamma)),
            // `ops_filters::hue_rotate`: one matrix multiply.
            Adjustment::HueRotate { matrix } => {
                matrix.map(|row| row[0] * rgb[0] + row[1] * rgb[1] + row[2] * rgb[2])
            }
            // `ops_filters::threshold`: Rec. 709 luma against the level.
            Adjustment::Threshold { level } => {
                let luma = LUMA_R * rgb[0] + LUMA_G * rgb[1] + LUMA_B * rgb[2];
                let v = if luma >= *level { 1.0 } else { 0.0 };
                [v, v, v]
            }
            // `ops_filters::posterize`: snap to `levels` evenly spaced values.
            Adjustment::Posterize { steps } => rgb.map(|v| (v * steps).round() / steps),
            // Curves: quantize to a table index, per-channel LUT first, then
            // the master rgb LUT.
            Adjustment::Curves(luts) => {
                let idx = rgb.map(|v| (v * 255.0).round() as usize);
                [
                    f32::from(luts.rgb[usize::from(luts.r[idx[0]])]) / 255.0,
                    f32::from(luts.rgb[usize::from(luts.g[idx[1]])]) / 255.0,
                    f32::from(luts.rgb[usize::from(luts.b[idx[2]])]) / 255.0,
                ]
            }
            // `ops::invert`.
            Adjustment::Invert => rgb.map(|v| 1.0 - v),
            // `ops::grayscale`: Rec. 709 luma on every channel.
            Adjustment::Grayscale => {
                let luma = LUMA_R * rgb[0] + LUMA_G * rgb[1] + LUMA_B * rgb[2];
                [luma, luma, luma]
            }
            // `ops::sepia`: the classic sepia matrix, clamped high side only
            // (the coefficients are all non-negative).
            Adjustment::Sepia => [
                (0.393 * rgb[0] + 0.769 * rgb[1] + 0.189 * rgb[2]).min(1.0),
                (0.349 * rgb[0] + 0.686 * rgb[1] + 0.168 * rgb[2]).min(1.0),
                (0.272 * rgb[0] + 0.534 * rgb[1] + 0.131 * rgb[2]).min(1.0),
            ],
        };
        out.map(|v| v.clamp(0.0, 1.0))
    }
}
