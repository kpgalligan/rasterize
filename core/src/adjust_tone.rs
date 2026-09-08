//! The two TONE adjustments: `exposure` (a light-linear gain, pedestal and
//! gamma) and `shadows_highlights` (the one SPATIAL op, whose lift is
//! weighted by a large-radius alpha-weighted blur of the luma). Payload
//! structs, their `parse`, their kernels, and [`tone_plane`] — the guide
//! plane — live here; `adjust` keeps only the schema rows and the dispatch.
//!
//! # Exposure
//!
//! Adobe's own statement of the op: *"Exposure works by performing
//! calculations in a linear colour space (gamma 1.0) rather than the image's
//! current colour space."* So:
//!
//! ```text
//! u   = srgb_to_linear(v)
//! u   = u * 2^exposure          # a pure linear gain, in stops
//! u   = u + offset              # a linear pedestal
//! u   = max(u, 0) ^ gamma       # still in linear light
//! out = linear_to_srgb(u)
//! ```
//!
//! Order matters and is not commutative: gain, THEN offset, THEN gamma —
//! offset after gain is what makes Offset "darken the shadows and midtones
//! with minimal effect on the highlights", and the reverse order would scale
//! the pedestal. The `max(u, 0)` is because a negative offset can push a
//! dark pixel below zero, and a negative base under a fractional exponent is
//! a NaN.
//!
//! **The gamma is the POWER, not its reciprocal, so `gamma > 1` DARKENS.**
//! That is Photoshop's Exposure convention and the exact INVERSE of the
//! `levels` op's midtone gamma in this same crate (`ops_filters::levels`
//! applies `t^(1/gamma)`, so there `gamma > 1` brightens). The two are the
//! one place in this module where the same word means opposite things, which
//! is why both schema rows, both catalog entries and both sheets say which.
//!
//! # Shadows / Highlights
//!
//! The weight comes from a large-radius blur of the LUMINANCE, not from the
//! pixel's own value — that is the whole mechanism, and what preserves local
//! contrast: a dark pixel inside a bright region is not lifted, because its
//! neighbourhood says "highlight".
//!
//! ```text
//! L   = luma(rgb);  B = the guide (the blurred luma at this pixel)
//! w_s = clamp(1 - B/t_s, 0, 1)^2 ;  w_h = clamp(1 - (1 - B)/t_h, 0, 1)^2
//! e   = (1 + a_h*w_h) / (1 + a_s*w_s)
//! L'  = L^e
//! L'  = L' + m*(3L'^2 - 2L'^3 - L')        # midtone_contrast
//! k   = L > 0 ? L'/L : 1
//! rgb'= rgb * k                            # NOT clamped yet
//! w   = clamp(a_s*w_s + a_h*w_h, 0, 1)     # "how much this pixel moved"
//! rgb'= L' + (rgb' - L') * (1 + color*w)
//! rgb'= clamp(rgb', 0, 1)                  # ONE clamp, at the end
//! ```
//!
//! The SQUARED weight is what gives the smooth shoulder; a linear ramp
//! visibly bands at the tone boundary.
//!
//! Two details are load-bearing and easy to "tidy" into bugs:
//!
//! * **The single trailing clamp.** Clamping `rgb * k` before the Color step
//!   would anchor the saturation to a grey that is not the pixel's own luma —
//!   precisely where the op works hardest (a deep shadow lifted several
//!   stops), so a channel that overshot would come back desaturated toward
//!   the wrong centre.
//! * **The `w` gate on Color.** `color` defaults to 0.2, so without a gate
//!   an all-zero-amount Shadows/Highlights would still resaturate the whole
//!   image. `w` is zero exactly where the tone did not move, which makes
//!   `amount 0` an exact identity.
//!
//! The midtone-contrast term is monotone for every `m` in [-1, 1]: its
//! derivative is `(1 - m) + 6m*x*(1 - x)`, whose minimum over x in [0, 1] is
//! `1 - m` for positive m and `1 + m/2` for negative m — both non-negative
//! on that interval, so the op can never invert an ordering.

use serde_json::{Map, Value};

use crate::adjust_math::{linear_to_srgb, luma, srgb_to_linear};
use crate::adjust_parse::{num_in, obj};
use crate::style_render::{blur_plane, downsample_factor, reduced_sigma, sigma_for_size};

/// A parsed `exposure` op: the gain (already `2^stops`), the linear
/// pedestal, and the linear-light gamma EXPONENT.
#[derive(Clone)]
pub(crate) struct Exposure {
    gain: f32,
    offset: f32,
    gamma: f32,
}

impl Exposure {
    /// Parses the `exposure` params per the schema row in `adjust`.
    pub(crate) fn parse(params: &Map<String, Value>) -> Option<Exposure> {
        let stops = num_in(params, "exposure", -20.0..=20.0, 0.0)?;
        let offset = num_in(params, "offset", -0.5..=0.5, 0.0)?;
        let gamma = num_in(params, "gamma", 0.01..=9.99, 1.0)?;
        Some(Exposure {
            gain: stops.exp2(),
            offset,
            gamma,
        })
    }

    /// One straight RGB triple in [0, 1]. The defaults (0 stops, 0 offset,
    /// gamma 1) are a byte-for-byte no-op: the gain is exactly 1, the
    /// pedestal exactly 0, `powf(1.0)` is the identity, and the sRGB
    /// transfer pair round-trips every 8-bit code exactly.
    pub(crate) fn apply(&self, rgb: [f32; 3]) -> [f32; 3] {
        rgb.map(|v| {
            let u = (srgb_to_linear(v) * self.gain + self.offset).max(0.0);
            linear_to_srgb(u.powf(self.gamma))
        })
    }
}

/// A parsed `shadows_highlights` op. ONE radius serves both bands (two
/// radii would mean two blurred guide planes per composite for the same
/// picture), and the amounts/tones are stored as fractions.
#[derive(Clone)]
pub(crate) struct ShadowsHighlights {
    shadow_amount: f32,
    shadow_tone: f32,
    highlight_amount: f32,
    highlight_tone: f32,
    radius: f32,
    color: f32,
    midtone_contrast: f32,
}

/// Reads one `{amount, tone}` band object, which may be absent entirely.
fn band(
    params: &Map<String, Value>,
    key: &str,
    amount_default: f64,
    tone_default: f64,
) -> Option<(f32, f32)> {
    match obj(params, key)? {
        None => Some((amount_default as f32, tone_default as f32)),
        Some(sub) => Some((
            num_in(sub, "amount", 0.0..=1.0, amount_default)?,
            num_in(sub, "tone", 0.01..=1.0, tone_default)?,
        )),
    }
}

impl ShadowsHighlights {
    /// Parses the `shadows_highlights` params per the schema row in
    /// `adjust`. Photoshop's own defaults: shadows 35 % at tone 50 %,
    /// highlights off, radius 30 px, Color +20 %.
    pub(crate) fn parse(params: &Map<String, Value>) -> Option<ShadowsHighlights> {
        let (shadow_amount, shadow_tone) = band(params, "shadows", 0.35, 0.5)?;
        let (highlight_amount, highlight_tone) = band(params, "highlights", 0.0, 0.5)?;
        Some(ShadowsHighlights {
            shadow_amount,
            shadow_tone,
            highlight_amount,
            highlight_tone,
            radius: num_in(params, "radius", 0.0..=1000.0, 30.0)?,
            color: num_in(params, "color", -1.0..=1.0, 0.2)?,
            midtone_contrast: num_in(params, "midtone_contrast", -1.0..=1.0, 0.0)?,
        })
    }

    /// Whether this op's output depends on the guide at all.
    ///
    /// `b` reaches [`ShadowsHighlights::apply`] only through `w_s` and
    /// `w_h`, and both are multiplied by their band's amount everywhere they
    /// are used — in the exponent and in `moved`. With both amounts zero the
    /// guide is therefore UNREAD: the exponent is 1, `moved` is 0, and the
    /// op is either the identity or the midtone-contrast curve alone. So the
    /// plane is not built, which matters because building it is the most
    /// expensive thing any adjustment does and the compositor rebuilds it on
    /// every render, export, thumbnail and live stroke tick.
    fn reads_guide(&self) -> bool {
        self.shadow_amount != 0.0 || self.highlight_amount != 0.0
    }

    /// This op's guide plane at its own radius — [`tone_plane`], which is
    /// the only reason `Adjustment::guide` exists. `None` when the guide
    /// cannot change a single output pixel ([`Self::reads_guide`]).
    pub(crate) fn guide_plane(
        &self,
        w: u32,
        h: u32,
        rgba_at: &dyn Fn(usize) -> [f32; 4],
    ) -> Option<GuidePlane> {
        if !self.reads_guide() {
            return None;
        }
        Some(tone_plane(w, h, self.radius, rgba_at))
    }

    /// One straight RGB triple with `guide` = the blurred luma of its
    /// neighbourhood (the module doc's `B`). See the module doc for why the
    /// clamp is at the end and why `w` gates the Color step.
    pub(crate) fn apply(&self, rgb: [f32; 3], guide: f32) -> [f32; 3] {
        let l = luma(rgb);
        let b = guide.clamp(0.0, 1.0);
        let w_s = (1.0 - b / self.shadow_tone).clamp(0.0, 1.0);
        let w_s = w_s * w_s;
        let w_h = (1.0 - (1.0 - b) / self.highlight_tone).clamp(0.0, 1.0);
        let w_h = w_h * w_h;
        let exponent = (1.0 + self.highlight_amount * w_h) / (1.0 + self.shadow_amount * w_s);
        // `powf(1.0)` is exactly `l`, so the shortcut is bit-identical — and
        // it is taken for every pixel of an amount-free pass and for every
        // midtone pixel of a normal one, where `powf` is otherwise the most
        // expensive instruction in the whole adjustment.
        let mut lifted = if l <= 0.0 {
            0.0
        } else if exponent == 1.0 {
            l
        } else {
            l.powf(exponent)
        };
        let m = self.midtone_contrast;
        lifted += m * (3.0 * lifted * lifted - 2.0 * lifted * lifted * lifted - lifted);
        let k = if l > 0.0 { lifted / l } else { 1.0 };
        let moved = (self.shadow_amount * w_s + self.highlight_amount * w_h).clamp(0.0, 1.0);
        let boost = 1.0 + self.color * moved;
        rgb.map(|c| (lifted + (c * k - lifted) * boost).clamp(0.0, 1.0))
    }
}

/// The Shadows/Highlights guide, held at the resolution the signal actually
/// carries rather than at the canvas's — a `w` x `h` grid of `factor`-sized
/// cells, read back by bilinear interpolation ([`GuidePlane::at`]).
///
/// The guide is by construction a blur at `sigma = radius / 2`, so above
/// `factor` 1 it has no detail a full-canvas buffer could hold: sampling it
/// at 1/factor and interpolating is the same picture. Holding it small is
/// what keeps the op affordable at the sizes the app supports — the plane is
/// rebuilt on EVERY composite (`doc::composite_adjustment_into` has no
/// cache, deliberately: the plane is a function of the backdrop, which a
/// live stroke changes on every tick, so a cache keyed on anything cheaper
/// than the backdrop's contents would hand back a stale guide). At 10000 x
/// 10000 the reduced grid is 1250 x 1250: three intermediate buffers of
/// 1.5 MB instead of 100 MB each, and two blurs over 1.5 M cells instead of
/// 100 M pixels.
pub(crate) struct GuidePlane {
    plane: Vec<u8>,
    w: u32,
    h: u32,
    factor: u32,
}

impl GuidePlane {
    /// The guide at full-resolution pixel `(x, y)`, as a fraction in
    /// [0, 1]. Cell centres sit at `(i + 0.5) * factor` in full-resolution
    /// coordinates, so the sample point is `(x + 0.5) / factor - 0.5`,
    /// clamped to the grid at the borders (which is what a blur's own edge
    /// handling does anyway). At `factor` 1 this is a plain lookup, so a
    /// small radius keeps exactly the pixel-for-pixel guide it always had.
    ///
    /// `(x, y)` must be inside the `w` x `h` the plane was built for — both
    /// callers walk exactly that buffer — and is read per pixel of a
    /// composite, so it is written for that and not defended twice.
    pub(crate) fn at(&self, x: u32, y: u32) -> f32 {
        let row = self.w as usize;
        if self.factor == 1 {
            let i = (y as usize) * row + (x as usize);
            return f32::from(self.plane[i]) / 255.0;
        }
        let f = self.factor as f32;
        let (x0, x1, fx) = cell((x as f32 + 0.5) / f - 0.5, self.w);
        let (y0, y1, fy) = cell((y as f32 + 0.5) / f - 0.5, self.h);
        let at = |cx: usize, cy: usize| f32::from(self.plane[cy * row + cx]);
        let top = at(x0, y0) + (at(x1, y0) - at(x0, y0)) * fx;
        let bottom = at(x0, y1) + (at(x1, y1) - at(x0, y1)) * fx;
        (top + (bottom - top) * fy) / 255.0
    }
}

/// The two neighbouring cell indices and the fraction between them for a
/// grid coordinate, clamped into `0..n`.
fn cell(t: f32, n: u32) -> (usize, usize, f32) {
    let last = n.saturating_sub(1) as usize;
    if !t.is_finite() || t <= 0.0 {
        return (0, 0, 0.0);
    }
    let floor = t.floor();
    let i = floor as usize;
    if i >= last {
        return (last, last, 0.0);
    }
    (i, i + 1, t - floor)
}

/// The Shadows/Highlights guide: an ALPHA-WEIGHTED, large-radius blur of the
/// luma.
///
/// Two planes go through the ONE plane blur (`style_render::blur_plane`) at
/// `sigma = radius / 2` — `style_render::sigma_for_size`, the one sizing
/// rule in this crate, so a Shadows/Highlights radius and a layer-style size
/// of the same number soften by the same amount. The plane is then the RATIO
/// `blur(luma * alpha) / blur(alpha)`, which is what makes the estimate
/// honest at an edge:
///
/// * a transparent pixel contributes NOTHING, so a cut-out subject is not
///   dragged toward black by the empty space around it and gets no halo;
/// * the ratio also normalizes away the blur's own edge handling, so the
///   estimate at the image border is the mean of the pixels that are
///   actually there;
/// * where the blurred alpha is zero the ratio is undefined and the cell's
///   OWN mean luma stands in. At a small non-zero coverage the ratio is
///   coarsely quantized, but the op's response to the guide is quadratic in
///   a clamped ramp, so a whole 8-bit code of guide error moves the output
///   by well under one code.
///
/// **The grid.** `blur_plane` above sigma 3 already blurs a downsampled copy
/// and resamples back, so the guide never had detail below
/// `style_render::downsample_factor(sigma)` pixels. This builds it at that
/// resolution directly — box-averaging each cell in the ONE pass over the
/// image that reading it requires, blurring the small grid, and letting
/// [`GuidePlane::at`] interpolate — instead of materializing three
/// canvas-sized buffers and putting each through a resample-blur-resample
/// round trip. `style_render::reduced_sigma` is the compensation for that
/// round trip's own softening; a box average down plus a bilinear read back
/// carries variance `f²/4` against the `f²/3` it assumes, which at the
/// factors it selects is under 2 % of the effective sigma — far less than
/// the 8-bit quantization the plane already carries, and worth not having a
/// second sizing rule in the crate.
///
/// At `radius` 0 the blur is a no-op, the factor is 1, and the plane is
/// exactly the per-pixel luma — the honest reading of "no neighbourhood".
pub(crate) fn tone_plane(
    w: u32,
    h: u32,
    radius: f32,
    rgba_at: &dyn Fn(usize) -> [f32; 4],
) -> GuidePlane {
    let sigma = sigma_for_size(radius);
    let factor = downsample_factor(sigma);
    let (gw, gh) = (w.div_ceil(factor).max(1), h.div_ceil(factor).max(1));
    let cells = (gw as usize) * (gh as usize);
    let mut weighted_plane = vec![0u8; cells];
    let mut coverage_plane = vec![0u8; cells];
    // Reused as the output plane: it starts as each cell's own mean luma,
    // which is the fallback where the blurred coverage is zero.
    let mut plane = vec![0u8; cells];
    let byte = |v: f32| (v.clamp(0.0, 1.0) * 255.0).round() as u8;
    if factor == 1 {
        // The grid IS the image: no cell arithmetic, one pass, straight to
        // the bytes. This is the path every small radius takes, and it is
        // pixel-for-pixel what the guide has always been.
        for i in 0..cells {
            let px = rgba_at(i);
            let l = luma([px[0], px[1], px[2]]).clamp(0.0, 1.0);
            let a = px[3].clamp(0.0, 1.0);
            plane[i] = byte(l);
            coverage_plane[i] = byte(a);
            weighted_plane[i] = byte(l * a);
        }
    } else {
        let mut weighted = vec![0f32; cells];
        let mut coverage = vec![0f32; cells];
        let mut lumas = vec![0f32; cells];
        // One RUN of a cell's pixels at a time — a cell is `factor`
        // consecutive pixels of a row — so the three sums live in registers
        // across the run and the grid is touched once per run, not once per
        // pixel.
        for y in 0..h {
            let row = (y / factor) as usize * gw as usize;
            let base = (y as usize) * (w as usize);
            for cx in 0..gw {
                let (x0, x1) = (cx * factor, ((cx + 1) * factor).min(w));
                let (mut sum_w, mut sum_c, mut sum_l) = (0.0f32, 0.0f32, 0.0f32);
                for x in x0..x1 {
                    let px = rgba_at(base + x as usize);
                    let l = luma([px[0], px[1], px[2]]).clamp(0.0, 1.0);
                    let a = px[3].clamp(0.0, 1.0);
                    sum_w += l * a;
                    sum_c += a;
                    sum_l += l;
                }
                let c = row + cx as usize;
                weighted[c] += sum_w;
                coverage[c] += sum_c;
                lumas[c] += sum_l;
            }
        }
        // The cell's pixel count, arithmetically: the last row and column
        // are ragged when the dimensions are not a multiple of the factor.
        let span = |i: u32, limit: u32| (((i + 1) * factor).min(limit) - i * factor) as f32;
        for c in 0..cells {
            let (cx, cy) = ((c % gw as usize) as u32, (c / gw as usize) as u32);
            let n = (span(cx, w) * span(cy, h)).max(1.0);
            weighted_plane[c] = byte(weighted[c] / n);
            coverage_plane[c] = byte(coverage[c] / n);
            plane[c] = byte(lumas[c] / n);
        }
    }
    let grid_sigma = if factor == 1 {
        sigma
    } else {
        reduced_sigma(sigma, factor)
    };
    blur_plane(&mut weighted_plane, gw, gh, grid_sigma);
    blur_plane(&mut coverage_plane, gw, gh, grid_sigma);
    for c in 0..cells {
        if coverage_plane[c] > 0 {
            plane[c] = byte(f32::from(weighted_plane[c]) / f32::from(coverage_plane[c]));
        }
    }
    GuidePlane {
        plane,
        w: gw,
        h: gh,
        factor,
    }
}
