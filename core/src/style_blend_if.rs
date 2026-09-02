//! Blend If (Photoshop Layer Style > Blending Options > Blend If): a
//! per-pixel weight in `[0, 1]` that `style_composite` multiplies into a
//! layer pixel's alpha before it blends — the photographer's "this warm
//! adjustment only in the highlights", and the cheapest of the blending
//! options (no plane, no blur: two ramp lookups per pixel).
//!
//! **The ramp.** A split-slider pair `[lo0, lo1, hi0, hi1]` over the 8-bit
//! range, `lo0 <= lo1 <= hi0 <= hi1` (the parser enforces the order), maps
//! a channel value `v` to a weight:
//!
//! | `v`                | weight                    |
//! |--------------------|---------------------------|
//! | `v < lo0`          | 0                         |
//! | `lo0 <= v < lo1`   | `(v - lo0) / (lo1 - lo0)` |
//! | `lo1 <= v <= hi0`  | 1                         |
//! | `hi0 < v <= hi1`   | `(hi1 - v) / (hi1 - hi0)` |
//! | `v > hi1`          | 0                         |
//!
//! A JOINED pair is a hard edge: `lo0 == lo1` weights 1 from `lo0` up
//! (the second row is empty, so no division happens), `hi0 == hi1` weights
//! 0 above `hi0`. Splitting a handle with ⌥-drag in the dialog opens the
//! ramp rows, which is how Photoshop softens the transition. The branch
//! guards make the two divisions safe by construction — each denominator is
//! strictly positive whenever its row is reached — and every row lands in
//! `[0, 1]`, so even a ramp handed in out of order (nothing produces one,
//! but the function must not care) yields a valid weight.
//!
//! **The channel value.** Ramps are defined over 8-bit values, so the
//! straight `0..1` colour is scaled to `0..=255` and ROUNDED to the nearest
//! integer: the source pixel is 8-bit already and the rounding only undoes
//! the `/255 * 255` float error that would otherwise put a pixel of exactly
//! `lo0` on the wrong side of a hard edge; the backdrop is an f32 composite,
//! and rounding evaluates it as the 8-bit pixel it becomes when the
//! projection quantizes, so a hard edge at 100 splits the same pixels
//! Photoshop's does. Gray is the luminosity `LUMA_R r + LUMA_G g + LUMA_B b`
//! (the `blend::LUMA_*` constants — one home for the coefficients); red /
//! green / blue read one channel. The value is clamped to `[0, 255]` after
//! scaling because the three LUMA coefficients sum to 1 only in decimal —
//! in f32 a pure white pixel can come out a hair above 255, which a full
//! ramp `[0, 0, 255, 255]` would otherwise weight 0.
//!
//! **Two ramps, one weight.** `source_weight` = this-layer ramp on the
//! layer pixel's own colour × underlying ramp on the composite BENEATH the
//! layer. "Underlying" is the accumulator pixel as stored at the moment the
//! layer starts drawing — the snapshot `style_composite` takes before the
//! layer's own Below effects, because Photoshop's Underlying Layer is what
//! lies under the layer, and the layer's own drop shadow is not under it.
//! The snapshot's alpha is ignored: the ramps are functions of colour, and
//! the accumulator keeps straight colour, so what a partially covered
//! backdrop pixel looks like IS its stored colour. A never-touched pixel is
//! the accumulator's cleared value, transparent black, and so evaluates as
//! 0 — the deterministic answer where there is no colour to read (a layer
//! floating over nothing is the case Blend If is least meant for).

use crate::blend::{LUMA_B, LUMA_G, LUMA_R};
use crate::style::{BlendIf, BlendIfChannel};

/// Weight in `[0, 1]` multiplied into the layer pixel's alpha: the
/// this-layer ramp evaluated on `source`'s channel × the underlying ramp on
/// `backdrop`'s (module doc). `source` is the layer pixel's straight RGB in
/// `0..1`; `backdrop` the accumulator pixel beneath the layer as stored
/// (straight RGB + alpha; the alpha is ignored — module doc).
pub(crate) fn source_weight(blend_if: &BlendIf, source: [f32; 3], backdrop: [f32; 4]) -> f32 {
    let this = ramp_weight(channel_value(blend_if.channel, source), blend_if.this_layer);
    let under = ramp_weight(
        channel_value(blend_if.channel, [backdrop[0], backdrop[1], backdrop[2]]),
        blend_if.underlying,
    );
    this * under
}

/// One split ramp on a channel value `v` in `0..=255` (the table in the
/// module doc). Total over every finite `v` and every ramp, joined or not,
/// ordered or not: the result is always in `[0, 1]` and no division by zero
/// can be reached. A non-finite `v` fails every comparison and falls to the
/// last row, weight 0.
pub(crate) fn ramp_weight(v: f32, ramp: [u8; 4]) -> f32 {
    let [lo0, lo1, hi0, hi1] = ramp.map(f32::from);
    if v < lo0 {
        0.0
    } else if v < lo1 {
        // Reached only with lo0 <= v < lo1, so lo1 - lo0 > 0.
        (v - lo0) / (lo1 - lo0)
    } else if v <= hi0 {
        1.0
    } else if v <= hi1 {
        // Reached only with hi0 < v <= hi1, so hi1 - hi0 > 0.
        (hi1 - v) / (hi1 - hi0)
    } else {
        0.0
    }
}

/// The 8-bit channel value the ramps read from a straight `0..1` RGB
/// triple: gray is the `LUMA_*` luminosity, the others one channel; scaled
/// to `0..=255`, rounded to the integer the pixel is (or becomes), clamped
/// (module doc).
fn channel_value(channel: BlendIfChannel, rgb: [f32; 3]) -> f32 {
    let unit = match channel {
        BlendIfChannel::Gray => LUMA_R * rgb[0] + LUMA_G * rgb[1] + LUMA_B * rgb[2],
        BlendIfChannel::Red => rgb[0],
        BlendIfChannel::Green => rgb[1],
        BlendIfChannel::Blue => rgb[2],
    };
    (unit * 255.0).round().clamp(0.0, 255.0)
}
