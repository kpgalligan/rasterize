//! The three HSL-family colour adjustments — `vibrance`, `hue_saturation`
//! and `color_balance`. Payload structs, their `parse` and their kernels
//! live here; `adjust` keeps only the schema rows and the dispatch.
//!
//! # Vibrance
//!
//! Photoshop's curve is unpublished. The de-facto reference (the shader
//! formula everyone reimplements against) scales each channel's distance
//! from the pixel's luma by a gain that shrinks as the pixel's own chroma
//! grows, so a boost lands on the flat colours and leaves an already
//! saturated sky alone:
//!
//! ```text
//! sat  = max(rgb) - min(rgb)                        # chroma extent, 0..1
//! skin = clamp(1 - hue_distance(h, 25 deg) / 25, 0, 1)
//! prot = v > 0 ? 1 - 0.5*skin : 1                   # BOOSTS only
//! k    = max(0, 1 + v * (1 - sign(v)*sat) * prot)
//! out  = luma + (c - luma) * k
//! ```
//!
//! Two terms are ours and are documented as ours rather than as Photoshop's:
//!
//! * **The skin term.** Photoshop protects skin; the reference formula does
//!   not. Full protection halves the boost at hue 25 deg and fades to none
//!   by 0 deg and 50 deg. It attenuates boosts ONLY — a deliberate
//!   desaturation of a face is still a desaturation.
//! * **The clamp at 0**, which is not defensive tidying. Without it
//!   `v = -0.7` on a saturated pixel gives `k = -0.4`, and a negative gain
//!   REFLECTS the colour through its own luma: pure red comes back teal.
//!   The clamp is what makes -1 converge to grey.
//!
//! Vibrance's dialog also carries a flat Saturation slider. It goes through
//! [`hsl_shift`] — the SAME two-sided HSL curve `hue_saturation`'s master
//! Saturation uses, byte for byte — because two dialogs a menu apart may not
//! spell the same word two ways. (`bcs`'s `saturation` is a third, older
//! spelling, a scale about the luma; its meaning is frozen by the ops that
//! already ship, and `adjust_math::two_sided`'s doc says so.) The gain's
//! output is clamped back into [0, 1] before the HSL stage reads it, so the
//! two sliders always describe the same pixel — see [`Vibrance::apply`].
//!
//! # Hue / Saturation
//!
//! HSL throughout ([`adjust_math::rgb_to_hsl`]). The master hue shift, and
//! each of the six editable bands' shifts, are summed with the band weights
//! and applied once:
//!
//! ```text
//! chroma = max(rgb) - min(rgb)
//! gate   = min(chroma / 0.05, 1) ^ 2                # BAND_CHROMA_FLOOR
//! w_b    = gate * band_weight(hue_distance(h, centre_b), inner_b, falloff_b)
//! H'     = H + hue    + sum_b w_b * hue_b
//! S'     = two_sided(S, saturation + sum_b w_b * saturation_b)
//! L'     = two_sided(L, lightness  + sum_b w_b * lightness_b)
//! ```
//!
//! The band ramp is Photoshop's: the range popup's four handles are an
//! inner half-width of 15 deg and an outer of 45 deg, i.e. `inner` 15 with a
//! 30 deg `falloff`, linear between. The property that matters is that
//! adjacent bands (60 deg apart) sum to exactly 1 at every hue, so the same
//! edit on all six bands IS one master edit and nothing bands at a boundary
//! — `adjust_color_tests` asserts exactly that, through the op.
//!
//! The gate is the other half of "which pixels is this band about", and
//! without it the six bands sum to 1 in the one place hue means nothing.
//! See [`band_chroma_gate`]: a neutral has no hue, so it must take no band
//! edit at all, and a near-neutral must ramp in rather than snap to
//! whichever band 8-bit quantization named.
//!
//! Colorize REPLACES rather than shifts (`H' = colorize_hue`,
//! `S' = colorize_saturation`, `L'` the pixel's own lightness through the
//! two-sided curve) and ignores the master and band controls, which is what
//! the checkbox means in the dialog.
//!
//! # Color Balance
//!
//! GIMP's `gimp_operation_color_balance_map`, which was written to match
//! Photoshop, with the constants that are its whole content: `a = 0.25`,
//! `b = 0.333`, `scale = 0.7`. The masks are evaluated on the CHANNEL's own
//! level, not on the pixel's luma — which is why a strongly coloured pixel
//! can be "shadow" in blue and "highlight" in red — and they sum to exactly
//! 1 at every level, so a full push on all three tones is a uniform `0.7`
//! lift, crossing over at `v = 0.333` and `v = 0.667`.
//!
//! Preserve Luminosity is [`adjust_math::preserve_luminosity`], the Rec. 709
//! ratio shared with `photo_filter` — NOT the HSL-lightness substitution
//! GIMP uses, which loses twelve levels of the luma it exists to hold (see
//! that function's doc).

use serde_json::{Map, Value};

use crate::adjust_math::{
    band_weight, hsl_to_rgb, hue_distance, luma, preserve_luminosity, rgb_to_hsl, two_sided,
    HUE_WHEEL,
};
use crate::adjust_parse::{boolean, nested, num_in, obj};

/// The ONE HSL edit. Both `vibrance`'s flat Saturation slider and
/// `hue_saturation`'s master-plus-band totals land here, which is what makes
/// `vibrance {saturation: s}` and `hue_saturation {saturation: s}`
/// byte-for-byte identical rather than merely similar.
///
/// `hsl` is the pixel already converted (the caller needs the hue for the
/// band weights, so converting twice would be waste).
///
/// A pixel with NO chroma is left neutral: `S = 0` is a fixed point of the
/// saturation curve. That is not a tweak of the curve but the model's own
/// rule — a grey has no hue to saturate — and it is exactly why Photoshop
/// needs a separate Colorize checkbox to tint a neutral at all. Lightness
/// has no such rule: pushing a black pixel to white is what its slider is
/// for.
fn hsl_shift(hsl: [f32; 3], hue: f32, saturation: f32, lightness: f32) -> [f32; 3] {
    let s = if hsl[1] > 0.0 {
        two_sided(hsl[1], saturation)
    } else {
        0.0
    };
    hsl_to_rgb([hsl[0] + hue, s, two_sided(hsl[2], lightness)])
}

// ------------------------------------------------------------ vibrance --

/// A parsed `vibrance` op: the chroma-weighted gain and the flat
/// saturation slider that rides with it in the same dialog.
#[derive(Clone)]
pub(crate) struct Vibrance {
    vibrance: f32,
    saturation: f32,
}

impl Vibrance {
    /// Parses the `vibrance` params per the schema row in `adjust`.
    pub(crate) fn parse(params: &Map<String, Value>) -> Option<Vibrance> {
        Some(Vibrance {
            vibrance: num_in(params, "vibrance", -1.0..=1.0, 0.0)?,
            saturation: num_in(params, "saturation", -1.0..=1.0, 0.0)?,
        })
    }

    /// One straight RGB triple in [0, 1]: the weighted gain, then the flat
    /// saturation. Both steps are skipped when their slider is at rest, so
    /// the defaults are a byte-exact no-op and an already-saturated pixel
    /// (gain exactly 1) comes back untouched rather than round-tripped.
    pub(crate) fn apply(&self, rgb: [f32; 3]) -> [f32; 3] {
        // Back into gamut BEFORE the HSL stage, not after. The gain is free
        // to overshoot — `vibrance` 1 on (1, 0.5, 0.5) gives k = 1.502 and
        // an r of 1.197 — and `rgb_to_hsl` of a triple outside [0, 1]
        // reports a lightness and a saturation no displayable colour has
        // (there, L = 0.82 and S = 2.11). Feeding that to the flat slider
        // would make the two controls describe different pixels: the first
        // step off Saturation 0 would jump the result to what the ROUNDED
        // HSL says, which for this pixel is 51 levels the wrong way. The
        // clamp is the same one `apply_at` puts on the return value, so the
        // saturation-at-rest path is byte-for-byte unchanged by it.
        let boosted = self.boost(rgb).map(|c| c.clamp(0.0, 1.0));
        if self.saturation == 0.0 {
            return boosted;
        }
        hsl_shift(rgb_to_hsl(boosted), 0.0, self.saturation, 0.0)
    }

    /// The chroma-weighted, skin-protected gain about the pixel's luma —
    /// the module doc's kernel.
    fn boost(&self, rgb: [f32; 3]) -> [f32; 3] {
        let v = self.vibrance;
        if v == 0.0 {
            return rgb;
        }
        let sat = rgb[0].max(rgb[1]).max(rgb[2]) - rgb[0].min(rgb[1]).min(rgb[2]);
        let protection = if v > 0.0 {
            // 25 deg is the middle of the skin band and 25 deg its
            // half-width, so the term is 1 at hue 25 and 0 by 0 and 50.
            let skin = (1.0 - hue_distance(rgb_to_hsl(rgb)[0], 25.0) / 25.0).clamp(0.0, 1.0);
            1.0 - 0.5 * skin
        } else {
            1.0
        };
        let k = (1.0 + v * (1.0 - v.signum() * sat) * protection).max(0.0);
        if k == 1.0 {
            return rgb;
        }
        let anchor = luma(rgb);
        rgb.map(|c| anchor + (c - anchor) * k)
    }
}

// ------------------------------------------------------ hue/saturation --

/// One editable hue band: where it sits on the wheel, how wide its flat top
/// and its ramp are, and what it does to a pixel inside it.
#[derive(Clone, Copy)]
struct Band {
    hue: f32,
    saturation: f32,
    lightness: f32,
    center: f32,
    inner: f32,
    falloff: f32,
}

/// A parsed `hue_saturation` op.
#[derive(Clone)]
pub(crate) struct HueSaturation {
    hue: f32,
    saturation: f32,
    lightness: f32,
    bands: [Band; 6],
    /// True when at least one band actually edits something, so the common
    /// master-only case skips six distance computations per pixel.
    banded: bool,
    colorize: bool,
    colorize_hue: f32,
    colorize_saturation: f32,
    colorize_lightness: f32,
}

/// The chroma at which a hue band reaches its full weight, as a straight-RGB
/// extent: 0.05 is 12.75 of 255 levels.
const BAND_CHROMA_FLOOR: f32 = 0.05;

/// How much of a hue band's weight a pixel of this chroma earns, in [0, 1].
///
/// A band asks "is this pixel one of the reds", and a hue alone cannot
/// answer it. [`rgb_to_hsl`] reports hue 0 for an exactly neutral pixel, so
/// every grey in the document sat at the dead centre of the Reds band; and a
/// pixel one 8-bit level off neutral lands on an exact multiple of 60 deg,
/// so a flat grey wall — or one level of sensor noise in a sky — was
/// PARTITIONED among the six bands at full weight. The hue and saturation
/// sliders hid it ([`hsl_shift`] holds `S = 0` fixed and a hue shift of a
/// zero-chroma colour is a no-op), but Lightness applied the whole edit:
/// measured, `bands.reds.lightness 0.5` moved a solid rgb(128,128,128)
/// patch to 192 — byte-identical to the MASTER slider — and turned a
/// rgb(128 +/- 1) noise patch into a 65-level split.
///
/// Chroma is the max-min extent, the same measure [`Vibrance::boost`] uses,
/// and deliberately NOT the HSL saturation: HSL divides the extent by the
/// width of the lightness cone, so one level of noise reads as 0.004 at mid
/// grey but 0.02 near black or white — inflating the gate exactly where
/// blotching shows most.
///
/// The ramp is quadratic rather than linear so that its slope at zero is
/// zero: a one-level chroma difference, where the hue is nothing but
/// quantization, earns 0.6 % of the band instead of 8 %, and a `+/- 1`-level
/// patch under a full Lightness edit spreads by about one more level rather
/// than by 64. It reaches 1 at [`BAND_CHROMA_FLOOR`], about 13 levels, which
/// is also about where the hue of an 8-bit pixel is resolved to better than
/// 5 deg — well inside the ramp the band handles describe. Every fixture
/// with real colour in it is at gate 1, which is why the band invariants
/// (`hue_saturation_bands_sum_to_one_at_every_hue`) are untouched.
fn band_chroma_gate(rgb: [f32; 3]) -> f32 {
    let chroma = rgb[0].max(rgb[1]).max(rgb[2]) - rgb[0].min(rgb[1]).min(rgb[2]);
    let t = (chroma / BAND_CHROMA_FLOOR).clamp(0.0, 1.0);
    t * t
}

/// A hue in DEGREES: the schema's half-open `[0, 360)`, which no inclusive
/// range can express, so 360 is refused explicitly rather than folded (a
/// host that means 0 must say 0).
fn hue_degrees(params: &Map<String, Value>, key: &str, default: f64) -> Option<f32> {
    let value = num_in(params, key, 0.0..=360.0, default)?;
    (value < 360.0).then_some(value)
}

impl HueSaturation {
    /// Parses the `hue_saturation` params per the schema row in `adjust`.
    /// Each band's centre defaults to `60 * index` — the wheel Photoshop's
    /// range popup lists — and its handles to the factory 15 deg inner and
    /// 30 deg falloff.
    pub(crate) fn parse(params: &Map<String, Value>) -> Option<HueSaturation> {
        let mut bands = std::array::from_fn(|i| Band {
            hue: 0.0,
            saturation: 0.0,
            lightness: 0.0,
            center: 60.0 * i as f32,
            inner: 15.0,
            falloff: 30.0,
        });
        if let Some(listed) = obj(params, "bands")? {
            for (band, name) in bands.iter_mut().zip(HUE_WHEEL) {
                let Some(sub) = obj(listed, name)? else {
                    continue;
                };
                *band = Band {
                    hue: num_in(sub, "hue", -180.0..=180.0, 0.0)?,
                    saturation: num_in(sub, "saturation", -1.0..=1.0, 0.0)?,
                    lightness: num_in(sub, "lightness", -1.0..=1.0, 0.0)?,
                    center: hue_degrees(sub, "center", f64::from(band.center))?,
                    inner: num_in(sub, "inner", 0.0..=180.0, 15.0)?,
                    falloff: num_in(sub, "falloff", 0.0..=180.0, 30.0)?,
                };
            }
        }
        let banded = bands
            .iter()
            .any(|b| b.hue != 0.0 || b.saturation != 0.0 || b.lightness != 0.0);
        Some(HueSaturation {
            hue: num_in(params, "hue", -180.0..=180.0, 0.0)?,
            saturation: num_in(params, "saturation", -1.0..=1.0, 0.0)?,
            lightness: num_in(params, "lightness", -1.0..=1.0, 0.0)?,
            bands,
            banded,
            colorize: boolean(params, "colorize", false)?,
            colorize_hue: hue_degrees(params, "colorize_hue", 0.0)?,
            colorize_saturation: num_in(params, "colorize_saturation", 0.0..=1.0, 0.25)?,
            colorize_lightness: num_in(params, "colorize_lightness", -1.0..=1.0, 0.0)?,
        })
    }

    /// One straight RGB triple in [0, 1]. Band weights are read off the
    /// ORIGINAL hue and chroma — a band edit may not move a pixel out of its
    /// own band mid-computation — and the totals go through the one
    /// [`hsl_shift`].
    pub(crate) fn apply(&self, rgb: [f32; 3]) -> [f32; 3] {
        let hsl = rgb_to_hsl(rgb);
        if self.colorize {
            return hsl_to_rgb([
                self.colorize_hue,
                self.colorize_saturation,
                two_sided(hsl[2], self.colorize_lightness),
            ]);
        }
        let (mut hue, mut saturation, mut lightness) = (self.hue, self.saturation, self.lightness);
        if self.banded {
            // A neutral is gated out of every band before the six distances
            // are even measured — see `band_chroma_gate` for why a hue on
            // its own cannot decide this.
            let gate = band_chroma_gate(rgb);
            if gate > 0.0 {
                for band in &self.bands {
                    let w = gate
                        * band_weight(hue_distance(hsl[0], band.center), band.inner, band.falloff);
                    if w > 0.0 {
                        hue += w * band.hue;
                        saturation += w * band.saturation;
                        lightness += w * band.lightness;
                    }
                }
            }
        }
        hsl_shift(hsl, hue, saturation, lightness)
    }
}

// ------------------------------------------------------- color balance --

/// GIMP's tone-mask constants: the ramp half-width, the shadow/midtone
/// crossover, and the ceiling on how far one full slider may move a
/// channel (0.7 = 179 of 255).
const MASK_WIDTH: f32 = 0.25;
const MASK_CROSSOVER: f32 = 0.333;
const MASK_SCALE: f32 = 0.7;

/// A parsed `color_balance` op: three `{cyan_red, magenta_green,
/// yellow_blue}` triples, stored per OUTPUT channel (R, G, B) because that
/// is the order the kernel walks them in.
#[derive(Clone)]
pub(crate) struct ColorBalance {
    shadows: [f32; 3],
    midtones: [f32; 3],
    highlights: [f32; 3],
    preserve_luminosity: bool,
}

/// The shadow, midtone and highlight weights at one channel level — the
/// module doc's masks. They sum to exactly 1 at every level.
fn tone_masks(value: f32) -> [f32; 3] {
    let low = ((value - MASK_CROSSOVER) / -MASK_WIDTH + 0.5).clamp(0.0, 1.0);
    let high = ((value + MASK_CROSSOVER - 1.0) / MASK_WIDTH + 0.5).clamp(0.0, 1.0);
    let mid = ((value - MASK_CROSSOVER) / MASK_WIDTH + 0.5).clamp(0.0, 1.0)
        * ((value + MASK_CROSSOVER - 1.0) / -MASK_WIDTH + 0.5).clamp(0.0, 1.0);
    [low, mid, high]
}

impl ColorBalance {
    /// Parses the `color_balance` params per the schema row in `adjust`.
    pub(crate) fn parse(params: &Map<String, Value>) -> Option<ColorBalance> {
        let keys = ["cyan_red", "magenta_green", "yellow_blue"];
        Some(ColorBalance {
            shadows: nested(params, "shadows", keys, -1.0..=1.0, [0.0; 3])?,
            midtones: nested(params, "midtones", keys, -1.0..=1.0, [0.0; 3])?,
            highlights: nested(params, "highlights", keys, -1.0..=1.0, [0.0; 3])?,
            preserve_luminosity: boolean(params, "preserve_luminosity", true)?,
        })
    }

    /// One straight RGB triple in [0, 1].
    pub(crate) fn apply(&self, rgb: [f32; 3]) -> [f32; 3] {
        let out = std::array::from_fn(|c| {
            let [low, mid, high] = tone_masks(rgb[c]);
            let delta = self.shadows[c] * low + self.midtones[c] * mid + self.highlights[c] * high;
            (rgb[c] + delta * MASK_SCALE).clamp(0.0, 1.0)
        });
        if self.preserve_luminosity {
            preserve_luminosity(rgb, out)
        } else {
            out
        }
    }
}
