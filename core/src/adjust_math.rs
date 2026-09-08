//! The pixel-math helpers the adjustment kernels share, and the ONE
//! destructive kernel `rz_image_adjust_op` runs.
//!
//! **This file is shared and append-only, ordered by first caller** — a
//! helper lands here with the op that first needs it, so nothing in it is
//! ever unused and `cargo clippy -D warnings` stays green at every step.
//! Present: the Rec. 709 luma (over `blend`'s `LUMA_*`, the one home for
//! those constants), the sRGB transfer function pair, [`apply_to_image`],
//! and — added with the colour and mapping ops that first needed them — the
//! HSL round trip, [`hue_distance`], [`band_weight`], [`two_sided`],
//! [`preserve_luminosity`], [`decompose`] and the CMYK round trip. There is
//! deliberately NO HSV pair: nothing in the core needs one (the Info
//! panel's HSB readout is display-only and computed host-side), and a
//! conversion with no caller is dead code at `cargo clippy -D warnings`.
//!
//! # Why the sRGB transfer function specifically
//!
//! An adjustment is a pure function of the numbers the document already
//! holds and carries no profile (see `adjust`'s module doc): an `RzImage`
//! has none, so a profile-dependent kernel would make the destructive twin
//! and the adjustment layer disagree on a non-sRGB document — the one thing
//! the parity test exists to prevent. Where an op needs a light-linear
//! domain to do its arithmetic (Exposure, White Balance) it therefore uses
//! the sRGB transfer function and the sRGB (D65) primaries, whatever the
//! document's profile, and each op's schema row says so.

use image::RgbaImage;

use crate::adjust::Adjustment;
use crate::blend::{LUMA_B, LUMA_G, LUMA_R};

/// Rec. 709 luma of a straight RGB triple in [0, 1] — the ONE luma in this
/// crate, over `blend`'s shared coefficients.
pub(crate) fn luma(rgb: [f32; 3]) -> f32 {
    LUMA_R * rgb[0] + LUMA_G * rgb[1] + LUMA_B * rgb[2]
}

/// The sRGB EOTF: one encoded channel in [0, 1] to light-linear.
pub(crate) fn srgb_to_linear(v: f32) -> f32 {
    if v <= 0.04045 {
        v / 12.92
    } else {
        ((v + 0.055) / 1.055).powf(2.4)
    }
}

/// The sRGB OETF: light-linear back to an encoded channel, the input
/// clamped into [0, 1] first so an op that overshoots (Exposure's gain,
/// White Balance's out-of-gamut corner) lands on black or white rather than
/// on a NaN from a negative base.
pub(crate) fn linear_to_srgb(u: f32) -> f32 {
    let u = u.clamp(0.0, 1.0);
    if u <= 0.0031308 {
        12.92 * u
    } else {
        1.055 * u.powf(1.0 / 2.4) - 0.055
    }
}

/// THE destructive kernel: `adjustment` applied to every pixel of `img`,
/// returning a new image with ALPHA COPIED UNTOUCHED. This is the identical
/// code path the compositor runs for an adjustment layer
/// (`doc::composite_adjustment_into`), which is what makes
/// `rz_image_adjust_op` and `add_adjustment_layer` incapable of drifting:
/// the guide plane is built once from THIS image and each pixel is mapped
/// through [`Adjustment::apply_at`] with its own position.
///
/// Two deliberate differences from the layer path, both written up in
/// `adjust`'s module doc as exceptions to invariant 1. A SPATIAL op reads
/// its neighbourhood from this image, while the layer reads it from the
/// backdrop below itself; the two agree on the same input and are different
/// pictures on different inputs — the distinction Photoshop's
/// Shadows/Highlights has. And the position handed to `apply_at` is the
/// position within THIS image, where the layer path hands the CANVAS
/// position, so `gradient_map`'s position-keyed dither lands on different
/// pixels when the layer's offset is not (0, 0) (`dither: false` makes the
/// two exact at any offset).
pub(crate) fn apply_to_image(adjustment: &Adjustment, img: &RgbaImage) -> RgbaImage {
    let (w, h) = img.dimensions();
    let raw = img.as_raw();
    let guide = adjustment.guide(w, h, &|i| {
        [
            f32::from(raw[i * 4]) / 255.0,
            f32::from(raw[i * 4 + 1]) / 255.0,
            f32::from(raw[i * 4 + 2]) / 255.0,
            f32::from(raw[i * 4 + 3]) / 255.0,
        ]
    });
    let mut out = img.clone();
    let width = i64::from(w);
    for (i, px) in out.pixels_mut().enumerate() {
        let rgb = [
            f32::from(px[0]) / 255.0,
            f32::from(px[1]) / 255.0,
            f32::from(px[2]) / 255.0,
        ];
        let xy = (i as i64 % width, i as i64 / width);
        // 0.0 for an op with no plane: `apply_at`'s guide argument is only
        // ever read by an op whose `guide` returned `Some`.
        let g = guide
            .as_ref()
            .map_or(0.0, |plane| plane.at(xy.0 as u32, xy.1 as u32));
        let adjusted = adjustment.apply_at(rgb, g, xy);
        for (dst, v) in px.0.iter_mut().zip(adjusted) {
            *dst = (v * 255.0).round() as u8;
        }
    }
    out
}

// ------------------------------------------------------- the HSL family --

/// The standard hexcone RGB -> HSL: hue in DEGREES in [0, 360), saturation
/// and lightness in [0, 1]. A neutral pixel has no hue and reports 0 by the
/// usual convention; `adjust_color::hsl_shift` is where that convention is
/// kept harmless (a zero saturation is a fixed point, so a grey is never
/// painted red).
pub(crate) fn rgb_to_hsl(rgb: [f32; 3]) -> [f32; 3] {
    let mx = rgb[0].max(rgb[1]).max(rgb[2]);
    let mn = rgb[0].min(rgb[1]).min(rgb[2]);
    let d = mx - mn;
    let l = (mx + mn) / 2.0;
    let s = if d == 0.0 {
        0.0
    } else if l <= 0.5 {
        d / (mx + mn)
    } else {
        d / (2.0 - mx - mn)
    };
    let h = if d == 0.0 {
        0.0
    } else if mx == rgb[0] {
        60.0 * ((rgb[1] - rgb[2]) / d % 6.0)
    } else if mx == rgb[1] {
        60.0 * ((rgb[2] - rgb[0]) / d + 2.0)
    } else {
        60.0 * ((rgb[0] - rgb[1]) / d + 4.0)
    };
    [h.rem_euclid(360.0), s, l]
}

/// The inverse hexcone, HSL -> RGB. The hue is wrapped rather than refused,
/// so a caller may add a signed shift to it and hand the sum straight back.
pub(crate) fn hsl_to_rgb(hsl: [f32; 3]) -> [f32; 3] {
    let s = hsl[1].clamp(0.0, 1.0);
    let l = hsl[2].clamp(0.0, 1.0);
    let c = (1.0 - (2.0 * l - 1.0).abs()) * s;
    let hp = hsl[0].rem_euclid(360.0) / 60.0;
    let x = c * (1.0 - (hp % 2.0 - 1.0).abs());
    let (r, g, b) = match hp as u32 {
        0 => (c, x, 0.0),
        1 => (x, c, 0.0),
        2 => (0.0, c, x),
        3 => (0.0, x, c),
        4 => (x, 0.0, c),
        // 5, and the unreachable 6 a hue of exactly 360 would produce if
        // `rem_euclid` ever rounded up to it.
        _ => (c, 0.0, x),
    };
    let m = l - c / 2.0;
    [r + m, g + m, b + m]
}

/// The absolute angular distance between two hues in degrees, always in
/// [0, 180] — the short way round the wheel, which is what a hue band's
/// ramp is measured along.
pub(crate) fn hue_distance(a: f32, b: f32) -> f32 {
    let d = (a - b).rem_euclid(360.0);
    if d > 180.0 {
        360.0 - d
    } else {
        d
    }
}

/// Photoshop's hue-band ramp as a weight: 1 inside the inner half-width, 0
/// at and beyond `inner + falloff`, linear between. With the factory
/// handles (inner 15 deg, falloff 30 deg) adjacent bands 60 deg apart sum to
/// exactly 1 at EVERY hue, which is the property that makes "the same edit
/// on all six bands" identical to one master edit — the invariant
/// `adjust_color_tests` pins. A zero falloff is a hard edge rather than a
/// division by zero.
///
/// This is the ramp along the HUE axis only, and a hue is not the whole
/// question: its one caller multiplies this by
/// `adjust_color::band_chroma_gate`, so a pixel with no chroma — whose hue
/// this crate reports as 0 deg, i.e. dead centre of Reds — is in no band at
/// all, and the "sums to 1" identity above is a statement about pixels that
/// have a hue to be one of.
pub(crate) fn band_weight(delta: f32, inner: f32, falloff: f32) -> f32 {
    if delta <= inner {
        1.0
    } else if falloff <= 0.0 || delta >= inner + falloff {
        0.0
    } else {
        (inner + falloff - delta) / falloff
    }
}

/// The two-sided slider curve Hue/Saturation's Saturation and Lightness
/// both use, and (by the phase's own rule that one word means one thing)
/// the curve `vibrance`'s flat Saturation slider uses too: `+1` reaches the
/// top of the range, `-1` reaches the bottom, and the two halves meet
/// continuously at 0, where the result is `value` EXACTLY — which is what
/// lets an untouched slider be a byte-exact no-op.
///
/// `bcs`'s saturation is deliberately a DIFFERENT curve (a scale about the
/// luma, `1 + amount`); its meaning is frozen by the ops that already ship.
pub(crate) fn two_sided(value: f32, amount: f32) -> f32 {
    let amount = amount.clamp(-1.0, 1.0);
    let value = value.clamp(0.0, 1.0);
    let out = if amount >= 0.0 {
        value + amount * (1.0 - value)
    } else {
        value * (1.0 + amount)
    };
    out.clamp(0.0, 1.0)
}

/// THE "preserve luminosity" rule, shared by `color_balance` and
/// `photo_filter`: rescale the adjusted triple so its Rec. 709 luma is the
/// original's again.
///
/// Why a ratio and not the other candidate — substituting the ORIGINAL
/// HSL lightness onto the adjusted hue and saturation (what GIMP does): the
/// substitution is not luminosity-preserving at all. Midtones Cyan-Red
/// +0.2 on grey 128 comes back at luma 116 through the HSL route and at
/// luma 128 (exactly) through this one, so a checkbox that exists to hold
/// the brightness would have cost twelve levels of it.
///
/// A channel that leaves the gamut is clamped afterwards, so the luma can
/// still move for a pixel the adjustment pushed past white — unavoidable in
/// 8-bit and stated here rather than hidden.
pub(crate) fn preserve_luminosity(original: [f32; 3], adjusted: [f32; 3]) -> [f32; 3] {
    let out_luma = luma(adjusted);
    if out_luma <= 0.0 {
        return adjusted;
    }
    let k = luma(original) / out_luma;
    adjusted.map(|v| (v * k).clamp(0.0, 1.0))
}

// ------------------------------------------ the hue-wheel decomposition --

/// The six-slot hue wheel's names, in the ONE order the decomposition's
/// slots, `black_and_white`'s weights, `hue_saturation`'s bands and
/// `selective_color`'s first six ranges all use — so the same word never
/// means a different slot in two schema rows.
pub(crate) const HUE_WHEEL: [&str; 6] = ["reds", "yellows", "greens", "cyans", "blues", "magentas"];

/// One pixel split into a neutral part plus AT MOST two adjacent hue
/// components — the model both `black_and_white` and `selective_color`
/// stand on, written once here (`core/CLAUDE.md`'s one-implementation rule).
///
/// `primary` and `secondary` index the six-slot hue wheel in the order both
/// ops name their parameters: 0 reds, 1 yellows, 2 greens, 3 cyans,
/// 4 blues, 5 magentas — so a primary is always even and a secondary always
/// odd. A neutral pixel has both amounts 0 and reports slots 0 and 1, which
/// no caller may read a meaning into.
pub(crate) struct Decomposition {
    /// `min(r, g, b)`: the white part no hue weight may tint.
    pub neutral: f32,
    /// The R/G/B slot holding the maximum (0, 2 or 4).
    pub primary: usize,
    /// `max - mid`: how much of the pixel is that pure primary.
    pub primary_amount: f32,
    /// The C/M/Y slot the two largest channels form (1, 3 or 5).
    pub secondary: usize,
    /// `mid - min`: how much of the pixel is that pure secondary.
    pub secondary_amount: f32,
}

/// Decomposes one straight RGB triple in [0, 1] into [`Decomposition`].
///
/// The secondary is the C/M/Y the two largest channels make — red+green is
/// yellow, green+blue is cyan, red+blue is magenta — and the amounts
/// partition the chroma: `neutral + primary_amount + secondary_amount` is
/// the maximum channel. Ties are broken toward the lower wheel slot so the
/// result is deterministic; where they can occur (`max == mid`) the
/// primary's amount is 0, so the choice cannot change any output.
pub(crate) fn decompose(rgb: [f32; 3]) -> Decomposition {
    // Channel order by value, ties toward the lower index (R, G, B).
    let mut order = [0usize, 1, 2];
    order.sort_by(|&a, &b| rgb[b].total_cmp(&rgb[a]).then(a.cmp(&b)));
    let (hi, mid, lo) = (order[0], order[1], order[2]);
    // R -> 0, G -> 2, B -> 4 on the six-slot wheel.
    let primary = hi * 2;
    // The C/M/Y between the two largest channels: R+G = yellow (1),
    // G+B = cyan (3), R+B = magenta (5).
    let secondary = match (hi.min(mid), hi.max(mid)) {
        (0, 1) => 1,
        (1, 2) => 3,
        _ => 5,
    };
    Decomposition {
        neutral: rgb[lo],
        primary,
        primary_amount: rgb[hi] - rgb[mid],
        secondary,
        secondary_amount: rgb[mid] - rgb[lo],
    }
}

// ----------------------------------------------------- the CMYK round trip --

/// Straight RGB in [0, 1] to the naive CMYK `selective_color` works in
/// (there is no profile in an adjustment — see `adjust`'s colour note — so
/// this is the algebraic separation, not a printer's).
///
/// `k = 1 - max(r, g, b)`; the `k >= 1` guard is the divide-by-zero the
/// formula hides: pure black has no ink ratios, and every C/M/Y is 0.
pub(crate) fn rgb_to_cmyk(rgb: [f32; 3]) -> [f32; 4] {
    let k = 1.0 - rgb[0].max(rgb[1]).max(rgb[2]);
    if k >= 1.0 {
        return [0.0, 0.0, 0.0, 1.0];
    }
    let scale = 1.0 - k;
    [
        (1.0 - rgb[0] - k) / scale,
        (1.0 - rgb[1] - k) / scale,
        (1.0 - rgb[2] - k) / scale,
        k,
    ]
}

/// The exact inverse of [`rgb_to_cmyk`] for every triple it can produce.
pub(crate) fn cmyk_to_rgb(cmyk: [f32; 4]) -> [f32; 3] {
    let scale = 1.0 - cmyk[3];
    [
        (1.0 - cmyk[0]) * scale,
        (1.0 - cmyk[1]) * scale,
        (1.0 - cmyk[2]) * scale,
    ]
}
