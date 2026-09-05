//! Auto Tone, Auto Contrast and Auto Color: the three menu commands that
//! derive LEVELS parameters from an image's own histogram and then run the
//! existing levels math (`ops_filters::levels_channels`). They are commands,
//! not adjustment layers — there is nothing to re-edit once the numbers are
//! derived, and Photoshop treats them the same way.
//!
//! Everything here reads [`ops_stats::histogram`] and its ONE counting rule,
//! so "the image's own histogram" has a single definition in this build and
//! a transparent surround cannot pin the black point at 0.
//!
//! # The three modes
//!
//! * **Auto Tone** — per channel, a black point at the level below which
//!   `clip` of the counted pixels fall and a white point mirrored at the
//!   top; gamma 1. Stretches each channel independently, so it also removes
//!   a colour cast.
//! * **Auto Contrast** — one black/white pair taken from the LUMA histogram
//!   and applied to all three channels, so the colour balance is untouched;
//!   gamma 1.
//! * **Auto Color** — Auto Tone's per-channel endpoints plus a per-channel
//!   gamma that snaps the MIDTONES neutral.
//!
//! # Why Auto Color is a neutral-candidate snap and not gray-world
//!
//! Gray-world — force the three channel means to agree — neutralises a
//! sunset, a forest or a brick wall, whose channel means are legitimately
//! unequal. Instead only pixels that ALREADY look neutral vote: counted
//! pixels whose post-stretch `max - min` is under 0.1 and whose Rec. 709
//! luma is in 0.25..=0.75. If fewer than 0.5 % of the counted pixels
//! qualify, the picture has no neutral to snap to and every gamma stays 1.
//!
//! The gamma itself is `ln(m_c) / ln(m)`, which is the correct inversion for
//! this codebase's `out = t^(1/gamma)` (`ops_filters::levels`), and it is
//! CLAMPED into [0.5, 2.0] — deliberately tight, because it bounds how far
//! an automatic command may rewrite the colour of a scene. The logarithms
//! are guarded BEFORE they are taken rather than by clamping afterwards:
//! `f32::clamp` propagates NaN, and a NaN gamma would fail
//! `levels_channels`' range check and silently refuse the whole op.

use image::RgbaImage;

use crate::blend::{LUMA_B, LUMA_G, LUMA_R};
use crate::ops_stats::{counted, histogram};

/// Which of the three commands. Mirrors `RzAutoMode` in the C header.
#[derive(Clone, Copy, PartialEq, Eq)]
pub(crate) enum AutoMode {
    Tone,
    Contrast,
    Color,
}

impl AutoMode {
    /// Maps a raw `RzAutoMode` value coming across the FFI.
    pub(crate) fn from_c(value: i32) -> Option<AutoMode> {
        match value {
            0 => Some(AutoMode::Tone),
            1 => Some(AutoMode::Contrast),
            2 => Some(AutoMode::Color),
            _ => None,
        }
    }
}

/// Share of the counted pixels a candidate set must reach before Auto
/// Color's midtone snap is trusted at all.
const MIN_CANDIDATE_SHARE: f64 = 0.005;

/// How near-neutral a pixel must be to vote, as post-stretch `max - min`.
const NEUTRAL_SPREAD: f32 = 0.1;

/// How far an automatic command may bend a channel's midtones.
const GAMMA_LIMIT: f32 = 2.0;

/// Levels parameters — `(black, white, gamma)`, three floats each — derived
/// from `img`'s own histogram, clipping `clip` of the counted pixels at each
/// end. `mask` is optional (`None` = the whole image).
///
/// `None` when `clip` is outside [0, 0.1] or not finite, when nothing is
/// counted (an empty or wholly transparent image, or a mask that covers
/// nothing), or when the result would be the IDENTITY — a command that
/// changes nothing must register no undo step.
pub(crate) fn auto_levels(
    img: &RgbaImage,
    mask: Option<&[u8]>,
    mode: AutoMode,
    clip: f32,
) -> Option<([f32; 3], [f32; 3], [f32; 3])> {
    if !clip.is_finite() || !(0.0..=0.1).contains(&clip) {
        return None;
    }
    let (bins, total) = histogram(img, mask, 1);
    if total == 0 {
        return None;
    }
    let cut = f64::from(clip) * total as f64;

    let mut black = [0.0f32; 3];
    let mut white = [1.0f32; 3];
    let mut gamma = [1.0f32; 3];
    for c in 0..3 {
        // Auto Contrast takes one pair from the luma histogram (plane 3) and
        // gives it to all three channels; the other two are per channel.
        let plane = if mode == AutoMode::Contrast { 3 } else { c };
        if let Some((lo, hi)) = endpoints(&bins[plane * 256..plane * 256 + 256], cut) {
            black[c] = f32::from(lo) / 255.0;
            white[c] = f32::from(hi) / 255.0;
        }
    }
    if mode == AutoMode::Color {
        gamma = neutral_gamma(img, mask, black, white, total);
    }

    let identity = black == [0.0; 3] && white == [1.0; 3] && gamma == [1.0; 3];
    (!identity).then_some((black, white, gamma))
}

/// The black and white codes of one 256-bin plane at a clipping COUNT:
/// black is the lowest code whose running total exceeds `cut`, white the
/// highest code whose running total from the top exceeds it. With `cut` 0
/// that is exactly the darkest and brightest occupied codes. `None` for a
/// flat plane (black >= white), which leaves that channel alone rather than
/// dividing by a zero range.
fn endpoints(plane: &[u32], cut: f64) -> Option<(u8, u8)> {
    let mut run = 0f64;
    let mut low = 255usize;
    for (v, count) in plane.iter().enumerate() {
        run += f64::from(*count);
        if run > cut {
            low = v;
            break;
        }
    }
    let mut run = 0f64;
    let mut high = 0usize;
    for (v, count) in plane.iter().enumerate().rev() {
        run += f64::from(*count);
        if run > cut {
            high = v;
            break;
        }
    }
    (low < high).then_some((low as u8, high as u8))
}

/// Auto Color's per-channel midtone gamma (module doc). Returns all ones
/// when too few pixels look neutral or a mean sits against an end.
fn neutral_gamma(
    img: &RgbaImage,
    mask: Option<&[u8]>,
    black: [f32; 3],
    white: [f32; 3],
    total: u64,
) -> [f32; 3] {
    let mut sums = [0f64; 3];
    let mut candidates = 0u64;
    for (i, px) in img.pixels().enumerate() {
        if !counted(px, mask, i) {
            continue;
        }
        let mut stretched = [0f32; 3];
        for (c, slot) in stretched.iter_mut().enumerate() {
            *slot = ((f32::from(px[c]) / 255.0 - black[c]) / (white[c] - black[c])).clamp(0.0, 1.0);
        }
        let spread = stretched[0].max(stretched[1]).max(stretched[2])
            - stretched[0].min(stretched[1]).min(stretched[2]);
        if spread >= NEUTRAL_SPREAD {
            continue;
        }
        let luma = LUMA_R * stretched[0] + LUMA_G * stretched[1] + LUMA_B * stretched[2];
        if !(0.25..=0.75).contains(&luma) {
            continue;
        }
        for (slot, v) in sums.iter_mut().zip(stretched) {
            *slot += f64::from(v);
        }
        candidates += 1;
    }
    if (candidates as f64) < MIN_CANDIDATE_SHARE * total as f64 || candidates == 0 {
        return [1.0; 3];
    }
    let means = sums.map(|s| s / candidates as f64);
    let mean = (means[0] + means[1] + means[2]) / 3.0;
    if !(0.001..=0.999).contains(&mean) {
        return [1.0; 3];
    }
    let mut gamma = [1.0f32; 3];
    for (slot, m) in gamma.iter_mut().zip(means) {
        if !(0.001..=0.999).contains(&m) {
            continue;
        }
        *slot = ((m.ln() / mean.ln()) as f32).clamp(1.0 / GAMMA_LIMIT, GAMMA_LIMIT);
    }
    gamma
}
