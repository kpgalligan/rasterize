//! The four DECOMPOSITION and MATRIX adjustments — `black_and_white`,
//! `photo_filter`, `channel_mixer` and `selective_color`. Payload structs,
//! their `parse` and their kernels live here; `adjust` keeps only the schema
//! rows and the dispatch.
//!
//! # The decomposition two of them share
//!
//! Black & White and Selective Color both ask "which hue is this pixel?",
//! and both answer with [`adjust_math::decompose`] — ONE implementation, per
//! `core/CLAUDE.md`: a neutral part plus at most two adjacent hue
//! components, a primary (R/G/B) and a secondary (C/M/Y), on the six-slot
//! wheel `adjust_math::HUE_WHEEL` names.
//!
//! They read it differently, and the difference is the point:
//!
//! * **Black & White multiplies the AMOUNTS.** `gray = neutral +
//!   primary_amount * W[primary] + secondary_amount * W[secondary]`. A grey
//!   pixel has both amounts 0, so `gray = neutral` and no weight can tint a
//!   neutral, whatever the sliders say — the invariant to check first.
//! * **Selective Color needs a MEMBERSHIP**, so it divides the amounts by
//!   the chroma (`max - min`). A pale pink is then fully in Reds exactly as
//!   a saturated red is, which is what reproduces Adobe's own worked
//!   example — `rgb(255, 128, 128)` with Reds magenta +10 relative gives
//!   green 115.3, a number the un-normalized amount misses by six levels.
//!   A pixel with no chroma has no hue and no chromatic membership at all;
//!   the whites / neutrals / blacks ranges are what act on it.
//!
//! Black & White's defaults are Photoshop's factory mix (reds 40 %,
//! yellows 60 %, greens 40 %, cyans 60 %, blues 20 %, magentas 80 %), which
//! is a very different picture from the `grayscale` op's Rec. 709 luma —
//! pure red reads 102 here and 54 there.
//!
//! But `grayscale` IS this op's degenerate case, and saying otherwise (an
//! earlier draft of this paragraph did) leads a reader away from the one
//! fact worth knowing. Set the six weights to the LUMA OF EACH WHEEL COLOUR
//! — reds 0.2126, yellows 0.9278, greens 0.7152, cyans 0.7874, blues
//! 0.0722, magentas 0.2848 — and the two agree everywhere. The algebra is
//! exact and short: [`adjust_math::decompose`] partitions the pixel as
//! `neutral*(1,1,1) + primary_amount*P + secondary_amount*S`, Rec. 709 luma
//! is linear with `luma((1,1,1)) = 1`, and each secondary's luma is the sum
//! of its two primaries' — so weighting each wheel slot by the luma of its
//! own colour reproduces luma at every pixel.
//! `adjust_mix_tests::black_and_white_at_luma_weights_is_the_grayscale_op`
//! is that identity as a test.
//!
//! `grayscale` nevertheless stays its own op, for two reasons that have
//! nothing to do with the math: its weights are frozen (it is one of the
//! legacy nine, whose numbers existing oracles pin), and it does its
//! arithmetic in 0..255 rather than 0..1, so on a value falling exactly
//! between two codes it can round one step away from this op.
//!
//! # Photo Filter
//!
//! A density-weighted multiply — `out = c * (1 - d + d*f)` — which is what
//! makes a filter SUBTRACTIVE (a warming filter really does remove blue),
//! followed by the shared [`adjust_math::preserve_luminosity`] rescale,
//! which is what stops it darkening the picture. This is the standard
//! reconstruction of Photoshop's dialog, not a published formula.
//!
//! # Channel Mixer
//!
//! One 3x4 matrix over the ENCODED values (Photoshop's Channel Mixer is a
//! gamma-space matrix; do not linearize it): `out_i = sum_j M[i][j] * c_j +
//! K[i]`. The stored numbers are FRACTIONS of the dialog's percentages,
//! constant included, so a constant of 0.5 adds 127.5 in 8-bit. Monochrome
//! is resolved at parse time by copying the gray row into all three outputs,
//! which is precisely what the checkbox means.
//!
//! # Selective Color
//!
//! CMYK ink nudges per hue range, in the naive separation
//! [`adjust_math::rgb_to_cmyk`] defines. Adobe documents the two methods
//! verbatim, and both reproduce their published example (50 % magenta,
//! +10 %: relative 55 %, absolute 60 %):
//!
//! ```text
//! total_ink = sum_ranges weight * slider          # weights below
//! relative:  ink' = ink * (1 + total_ink)         # a share of what is there
//! absolute:  ink' = ink + total_ink               # an amount of ink
//! ```
//!
//! The chromatic weights are the membership above; the achromatic three are
//! `whites = clamp((min - 0.5)*2, 0, 1)`, `blacks = clamp((0.5 - max)*2, 0,
//! 1)` and `neutrals = 1 - whites - blacks` (whites and blacks cannot both
//! be non-zero, so neutrals never goes negative). The two families are
//! independent — a pale red pixel is in Reds AND in Neutrals — which is how
//! the dialog behaves.

use serde_json::{Map, Value};

use crate::adjust_math::{
    cmyk_to_rgb, decompose, hsl_to_rgb, preserve_luminosity, rgb_to_cmyk, rgb_to_hsl, HUE_WHEEL,
};
use crate::adjust_parse::{boolean, color, nested, num_in, string_enum};

// ----------------------------------------------------- black and white --

/// Photoshop's factory mix, in [`HUE_WHEEL`] order.
const BW_DEFAULTS: [f64; 6] = [0.4, 0.6, 0.4, 0.6, 0.2, 0.8];

/// The sRGB spelling of Photoshop's default tint (hue 42 deg, saturation
/// 20 %). A sheet writes the DOCUMENT's own spelling of it; this default
/// only has to be right on an sRGB document (see `adjust`'s colour note).
const BW_TINT: [u8; 3] = [0x99, 0x8a, 0x66];

/// A parsed `black_and_white` op. The tint is stored as the HUE and
/// SATURATION of its colour — the only two components the op uses, since
/// the lightness IS the computed grey.
#[derive(Clone)]
pub(crate) struct BlackAndWhite {
    weights: [f32; 6],
    tint: bool,
    tint_hue: f32,
    tint_saturation: f32,
}

impl BlackAndWhite {
    /// Parses the `black_and_white` params per the schema row in `adjust`.
    pub(crate) fn parse(params: &Map<String, Value>) -> Option<BlackAndWhite> {
        let mut weights = [0.0f32; 6];
        for ((slot, name), default) in weights.iter_mut().zip(HUE_WHEEL).zip(BW_DEFAULTS) {
            *slot = num_in(params, name, -2.0..=3.0, default)?;
        }
        let tint_color = color(params, "tint_color", BW_TINT)?;
        let hsl = rgb_to_hsl(tint_color.map(|c| f32::from(c) / 255.0));
        Some(BlackAndWhite {
            weights,
            tint: boolean(params, "tint", false)?,
            tint_hue: hsl[0],
            tint_saturation: hsl[1],
        })
    }

    /// One straight RGB triple in [0, 1].
    pub(crate) fn apply(&self, rgb: [f32; 3]) -> [f32; 3] {
        let parts = decompose(rgb);
        let gray = (parts.neutral
            + parts.primary_amount * self.weights[parts.primary]
            + parts.secondary_amount * self.weights[parts.secondary])
            .clamp(0.0, 1.0);
        if self.tint {
            hsl_to_rgb([self.tint_hue, self.tint_saturation, gray])
        } else {
            [gray; 3]
        }
    }
}

// --------------------------------------------------------- photo filter --

/// The sRGB spelling of Warming Filter (85), Photoshop's default. Same
/// caveat as the Black & White tint: a sheet writes the document's numbers.
const WARMING_85: [u8; 3] = [0xec, 0x8a, 0x00];

/// A parsed `photo_filter` op, its colour already normalized.
#[derive(Clone)]
pub(crate) struct PhotoFilter {
    color: [f32; 3],
    density: f32,
    preserve_luminosity: bool,
}

impl PhotoFilter {
    /// Parses the `photo_filter` params per the schema row in `adjust`.
    pub(crate) fn parse(params: &Map<String, Value>) -> Option<PhotoFilter> {
        Some(PhotoFilter {
            color: color(params, "color", WARMING_85)?.map(|c| f32::from(c) / 255.0),
            density: num_in(params, "density", 0.0..=1.0, 0.25)?,
            preserve_luminosity: boolean(params, "preserve_luminosity", true)?,
        })
    }

    /// One straight RGB triple in [0, 1].
    pub(crate) fn apply(&self, rgb: [f32; 3]) -> [f32; 3] {
        let d = self.density;
        let out = std::array::from_fn(|c| rgb[c] * (1.0 - d + d * self.color[c]));
        if self.preserve_luminosity {
            preserve_luminosity(rgb, out)
        } else {
            out
        }
    }
}

// -------------------------------------------------------- channel mixer --

/// The four keys of one mixer row, and the identity/gray defaults.
const MIXER_KEYS: [&str; 4] = ["r", "g", "b", "constant"];
const MIXER_ROWS: [(&str, [f64; 4]); 3] = [
    ("red", [1.0, 0.0, 0.0, 0.0]),
    ("green", [0.0, 1.0, 0.0, 0.0]),
    ("blue", [0.0, 0.0, 1.0, 0.0]),
];
const MIXER_GRAY: [f64; 4] = [0.4, 0.4, 0.2, 0.0];

/// A parsed `channel_mixer` op: the 3x4 matrix, with Monochrome already
/// resolved into it.
#[derive(Clone)]
pub(crate) struct ChannelMixer {
    rows: [[f32; 4]; 3],
}

impl ChannelMixer {
    /// Parses the `channel_mixer` params per the schema row in `adjust`.
    /// The `gray` row is read whether or not Monochrome is on, so a host can
    /// keep both settings in the layer and toggle the checkbox without
    /// losing either — exactly what the dialog does.
    pub(crate) fn parse(params: &Map<String, Value>) -> Option<ChannelMixer> {
        let mut rows = [[0.0f32; 4]; 3];
        for (row, (name, defaults)) in rows.iter_mut().zip(MIXER_ROWS) {
            *row = nested(params, name, MIXER_KEYS, -2.0..=2.0, defaults)?;
        }
        let gray = nested(params, "gray", MIXER_KEYS, -2.0..=2.0, MIXER_GRAY)?;
        if boolean(params, "monochrome", false)? {
            rows = [gray; 3];
        }
        Some(ChannelMixer { rows })
    }

    /// One straight RGB triple in [0, 1], on the ENCODED values.
    pub(crate) fn apply(&self, rgb: [f32; 3]) -> [f32; 3] {
        self.rows
            .map(|row| row[0] * rgb[0] + row[1] * rgb[1] + row[2] * rgb[2] + row[3])
    }
}

// ------------------------------------------------------ selective color --

/// The three achromatic ranges. They are read AFTER [`HUE_WHEEL`]'s six, so
/// a chromatic range's index IS the wheel slot [`decompose`] reports — an
/// ordering the parse loop chains rather than restates, since a second copy
/// of those six names could drift out of step with the decomposition.
const ACHROMATIC_NAMES: [&str; 3] = ["whites", "neutrals", "blacks"];
const WHITES: usize = 6;
const NEUTRALS: usize = 7;
const BLACKS: usize = 8;
const INK_KEYS: [&str; 4] = ["c", "m", "y", "k"];

/// A parsed `selective_color` op: nine `{c, m, y, k}` nudges and the method.
#[derive(Clone)]
pub(crate) struct SelectiveColor {
    ranges: [[f32; 4]; 9],
    absolute: bool,
}

impl SelectiveColor {
    /// Parses the `selective_color` params per the schema row in `adjust`.
    pub(crate) fn parse(params: &Map<String, Value>) -> Option<SelectiveColor> {
        let mut ranges = [[0.0f32; 4]; 9];
        for (slot, name) in ranges
            .iter_mut()
            .zip(HUE_WHEEL.iter().chain(&ACHROMATIC_NAMES))
        {
            *slot = nested(params, name, INK_KEYS, -1.0..=1.0, [0.0; 4])?;
        }
        let method = string_enum(params, "method", &["relative", "absolute"], Some(0))?;
        Some(SelectiveColor {
            ranges,
            absolute: method == 1,
        })
    }

    /// One straight RGB triple in [0, 1]. All-zero sliders are an exact
    /// identity: every ink delta is 0 and the CMYK round trip is exact.
    pub(crate) fn apply(&self, rgb: [f32; 3]) -> [f32; 3] {
        let mut weights = [0.0f32; 9];
        let parts = decompose(rgb);
        let mx = rgb[0].max(rgb[1]).max(rgb[2]);
        let mn = rgb[0].min(rgb[1]).min(rgb[2]);
        let chroma = mx - mn;
        if chroma > 0.0 {
            weights[parts.primary] = parts.primary_amount / chroma;
            weights[parts.secondary] = parts.secondary_amount / chroma;
        }
        weights[WHITES] = ((mn - 0.5) * 2.0).clamp(0.0, 1.0);
        weights[BLACKS] = ((0.5 - mx) * 2.0).clamp(0.0, 1.0);
        weights[NEUTRALS] = (1.0 - weights[WHITES] - weights[BLACKS]).clamp(0.0, 1.0);

        let mut delta = [0.0f32; 4];
        for (range, weight) in self.ranges.iter().zip(weights) {
            if weight == 0.0 {
                continue;
            }
            for (slot, nudge) in delta.iter_mut().zip(range) {
                *slot += weight * nudge;
            }
        }
        let mut ink = rgb_to_cmyk(rgb);
        for (value, d) in ink.iter_mut().zip(delta) {
            *value = if self.absolute {
                *value + d
            } else {
                *value * (1.0 + d)
            }
            .clamp(0.0, 1.0);
        }
        cmyk_to_rgb(ink)
    }
}
