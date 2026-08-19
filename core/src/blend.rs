//! The blend-mode table and all blend math: the W3C separable and
//! non-separable blend functions, the Dissolve dither, the shared f32 W3C
//! compositing kernel the projection loops run, and the shared straight-alpha
//! source-over/erase pixel primitives. `doc` drives these from its
//! projection; `ops` and `doc_select` route their per-pixel paint math
//! through the primitives here so every paint path shares one
//! implementation. Also home to the Rec. 709 luma coefficients.

use crate::ops::CompositeMode;

/// Rec. 709 luma coefficients — the ONE copy, shared by `ops`,
/// `ops_filters`, `adjust` and `doc`.
pub(crate) const LUMA_R: f32 = 0.2126;
pub(crate) const LUMA_G: f32 = 0.7152;
pub(crate) const LUMA_B: f32 = 0.0722;

/// The blend-mode set, mirroring `RzBlendMode` in the C header: 0-13 and
/// 15-22 are separable (per-channel W3C formulas), 23-26 non-separable
/// (whole-RGB-triple SetLum/SetSat math), and Dissolve (14) replaces alpha
/// compositing with a deterministic per-canvas-position dither.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(i32)]
pub enum BlendMode {
    Normal = 0,
    Multiply = 1,
    Screen = 2,
    Overlay = 3,
    SoftLight = 4,
    HardLight = 5,
    Darken = 6,
    Lighten = 7,
    Difference = 8,
    Exclusion = 9,
    ColorDodge = 10,
    ColorBurn = 11,
    Addition = 12,
    Subtract = 13,
    Dissolve = 14,
    LinearBurn = 15,
    DarkerColor = 16,
    LighterColor = 17,
    VividLight = 18,
    LinearLight = 19,
    PinLight = 20,
    HardMix = 21,
    Divide = 22,
    Hue = 23,
    Saturation = 24,
    Color = 25,
    Luminosity = 26,
}

impl BlendMode {
    /// Maps a raw `RzBlendMode` value coming across the FFI.
    pub fn from_c(value: i32) -> Option<Self> {
        match value {
            0 => Some(BlendMode::Normal),
            1 => Some(BlendMode::Multiply),
            2 => Some(BlendMode::Screen),
            3 => Some(BlendMode::Overlay),
            4 => Some(BlendMode::SoftLight),
            5 => Some(BlendMode::HardLight),
            6 => Some(BlendMode::Darken),
            7 => Some(BlendMode::Lighten),
            8 => Some(BlendMode::Difference),
            9 => Some(BlendMode::Exclusion),
            10 => Some(BlendMode::ColorDodge),
            11 => Some(BlendMode::ColorBurn),
            12 => Some(BlendMode::Addition),
            13 => Some(BlendMode::Subtract),
            14 => Some(BlendMode::Dissolve),
            15 => Some(BlendMode::LinearBurn),
            16 => Some(BlendMode::DarkerColor),
            17 => Some(BlendMode::LighterColor),
            18 => Some(BlendMode::VividLight),
            19 => Some(BlendMode::LinearLight),
            20 => Some(BlendMode::PinLight),
            21 => Some(BlendMode::HardMix),
            22 => Some(BlendMode::Divide),
            23 => Some(BlendMode::Hue),
            24 => Some(BlendMode::Saturation),
            25 => Some(BlendMode::Color),
            26 => Some(BlendMode::Luminosity),
            _ => None,
        }
    }

    /// The `RzBlendMode` value for the FFI.
    pub fn to_c(self) -> i32 {
        self as i32
    }
}

// --------------------------------------------------------- blend functions --
// W3C separable blend functions B(cb, cs); all inputs and outputs in [0, 1].

fn b_normal(_cb: f32, cs: f32) -> f32 {
    cs
}

fn b_multiply(cb: f32, cs: f32) -> f32 {
    cb * cs
}

fn b_screen(cb: f32, cs: f32) -> f32 {
    cb + cs - cb * cs
}

fn b_hard_light(cb: f32, cs: f32) -> f32 {
    if cs <= 0.5 {
        2.0 * cb * cs
    } else {
        1.0 - 2.0 * (1.0 - cb) * (1.0 - cs)
    }
}

fn b_overlay(cb: f32, cs: f32) -> f32 {
    b_hard_light(cs, cb)
}

fn b_darken(cb: f32, cs: f32) -> f32 {
    cb.min(cs)
}

fn b_lighten(cb: f32, cs: f32) -> f32 {
    cb.max(cs)
}

fn b_difference(cb: f32, cs: f32) -> f32 {
    (cb - cs).abs()
}

fn b_exclusion(cb: f32, cs: f32) -> f32 {
    cb + cs - 2.0 * cb * cs
}

fn b_color_dodge(cb: f32, cs: f32) -> f32 {
    if cb == 0.0 {
        0.0
    } else if cs == 1.0 {
        1.0
    } else {
        (cb / (1.0 - cs)).min(1.0)
    }
}

fn b_color_burn(cb: f32, cs: f32) -> f32 {
    if cb == 1.0 {
        1.0
    } else if cs == 0.0 {
        0.0
    } else {
        1.0 - ((1.0 - cb) / cs).min(1.0)
    }
}

fn soft_light_d(cb: f32) -> f32 {
    if cb <= 0.25 {
        ((16.0 * cb - 12.0) * cb + 4.0) * cb
    } else {
        cb.sqrt()
    }
}

fn b_soft_light(cb: f32, cs: f32) -> f32 {
    if cs <= 0.5 {
        cb - (1.0 - 2.0 * cs) * cb * (1.0 - cb)
    } else {
        cb + (2.0 * cs - 1.0) * (soft_light_d(cb) - cb)
    }
}

fn b_addition(cb: f32, cs: f32) -> f32 {
    (cb + cs).min(1.0)
}

fn b_subtract(cb: f32, cs: f32) -> f32 {
    (cb - cs).max(0.0)
}

fn b_linear_burn(cb: f32, cs: f32) -> f32 {
    (cb + cs - 1.0).max(0.0)
}

fn b_vivid_light(cb: f32, cs: f32) -> f32 {
    // At cs == 0.5 exactly, burn(cb, 1.0) == cb, matching the dodge branch's
    // limit, so the seam is continuous.
    if cs <= 0.5 {
        b_color_burn(cb, 2.0 * cs)
    } else {
        b_color_dodge(cb, 2.0 * cs - 1.0)
    }
}

fn b_linear_light(cb: f32, cs: f32) -> f32 {
    (cb + 2.0 * cs - 1.0).clamp(0.0, 1.0)
}

fn b_pin_light(cb: f32, cs: f32) -> f32 {
    if cs <= 0.5 {
        cb.min(2.0 * cs)
    } else {
        cb.max(2.0 * cs - 1.0)
    }
}

fn b_hard_mix(cb: f32, cs: f32) -> f32 {
    if cb + cs >= 1.0 {
        1.0
    } else {
        0.0
    }
}

fn b_divide(cb: f32, cs: f32) -> f32 {
    if cs == 0.0 {
        1.0
    } else {
        (cb / cs).min(1.0)
    }
}

// W3C non-separable blend machinery (compositing-1 spec pseudocode) operating
// on RGB triples in [0, 1]. Lum uses the spec's 0.3/0.59/0.11 weights.

fn lum(c: [f32; 3]) -> f32 {
    0.3 * c[0] + 0.59 * c[1] + 0.11 * c[2]
}

/// ClipColor: pulls out-of-gamut channels back toward the triple's
/// luminosity, preserving it. The divisors are safe: `l` is always a real
/// color's luminosity (in [0, 1]), so `n < 0` implies `l - n > 0` and `x > 1`
/// implies `x - l > 0`.
fn clip_color(mut c: [f32; 3]) -> [f32; 3] {
    let l = lum(c);
    let n = c[0].min(c[1]).min(c[2]);
    let x = c[0].max(c[1]).max(c[2]);
    if n < 0.0 {
        for ch in &mut c {
            *ch = l + (*ch - l) * l / (l - n);
        }
    }
    if x > 1.0 {
        for ch in &mut c {
            *ch = l + (*ch - l) * (1.0 - l) / (x - l);
        }
    }
    c
}

/// SetLum: shifts the triple to luminosity `l`, then clips into gamut.
fn set_lum(c: [f32; 3], l: f32) -> [f32; 3] {
    let d = l - lum(c);
    clip_color([c[0] + d, c[1] + d, c[2] + d])
}

fn sat(c: [f32; 3]) -> f32 {
    c[0].max(c[1]).max(c[2]) - c[0].min(c[1]).min(c[2])
}

/// SetSat: rescales the triple to saturation `s` — min channel to 0, max to
/// `s`, mid proportionally between them (spec pseudocode).
fn set_sat(c: [f32; 3], s: f32) -> [f32; 3] {
    let mut idx = [0usize, 1, 2];
    idx.sort_by(|&a, &b| c[a].total_cmp(&c[b]));
    let [lo, mid, hi] = idx;
    let mut out = [0.0f32; 3];
    if c[hi] > c[lo] {
        out[mid] = (c[mid] - c[lo]) * s / (c[hi] - c[lo]);
        out[hi] = s;
    }
    out
}

fn b_hue(cb: [f32; 3], cs: [f32; 3]) -> [f32; 3] {
    set_lum(set_sat(cs, sat(cb)), lum(cb))
}

fn b_saturation(cb: [f32; 3], cs: [f32; 3]) -> [f32; 3] {
    set_lum(set_sat(cb, sat(cs)), lum(cb))
}

fn b_color(cb: [f32; 3], cs: [f32; 3]) -> [f32; 3] {
    set_lum(cs, lum(cb))
}

fn b_luminosity(cb: [f32; 3], cs: [f32; 3]) -> [f32; 3] {
    set_lum(cb, lum(cs))
}

/// Whole-pixel pick: the lower-luma triple wins (backdrop on a tie).
fn b_darker_color(cb: [f32; 3], cs: [f32; 3]) -> [f32; 3] {
    if lum(cs) < lum(cb) {
        cs
    } else {
        cb
    }
}

/// Whole-pixel pick: the higher-luma triple wins (backdrop on a tie).
fn b_lighter_color(cb: [f32; 3], cs: [f32; 3]) -> [f32; 3] {
    if lum(cs) > lum(cb) {
        cs
    } else {
        cb
    }
}

/// How a blend mode participates in compositing: per-channel `B(cb, cs)`,
/// whole-RGB-triple `B(Cb, Cs)`, or the Dissolve dither (which replaces the
/// compositing formula entirely).
#[derive(Clone, Copy)]
pub(crate) enum BlendKind {
    Separable(fn(f32, f32) -> f32),
    NonSeparable(fn([f32; 3], [f32; 3]) -> [f32; 3]),
    Dissolve,
}

/// The blend behavior for a mode (data table, resolved once per layer rather
/// than per pixel).
pub(crate) fn blend_kind(mode: BlendMode) -> BlendKind {
    match mode {
        BlendMode::Normal => BlendKind::Separable(b_normal),
        BlendMode::Multiply => BlendKind::Separable(b_multiply),
        BlendMode::Screen => BlendKind::Separable(b_screen),
        BlendMode::Overlay => BlendKind::Separable(b_overlay),
        BlendMode::SoftLight => BlendKind::Separable(b_soft_light),
        BlendMode::HardLight => BlendKind::Separable(b_hard_light),
        BlendMode::Darken => BlendKind::Separable(b_darken),
        BlendMode::Lighten => BlendKind::Separable(b_lighten),
        BlendMode::Difference => BlendKind::Separable(b_difference),
        BlendMode::Exclusion => BlendKind::Separable(b_exclusion),
        BlendMode::ColorDodge => BlendKind::Separable(b_color_dodge),
        BlendMode::ColorBurn => BlendKind::Separable(b_color_burn),
        BlendMode::Addition => BlendKind::Separable(b_addition),
        BlendMode::Subtract => BlendKind::Separable(b_subtract),
        BlendMode::Dissolve => BlendKind::Dissolve,
        BlendMode::LinearBurn => BlendKind::Separable(b_linear_burn),
        BlendMode::DarkerColor => BlendKind::NonSeparable(b_darker_color),
        BlendMode::LighterColor => BlendKind::NonSeparable(b_lighter_color),
        BlendMode::VividLight => BlendKind::Separable(b_vivid_light),
        BlendMode::LinearLight => BlendKind::Separable(b_linear_light),
        BlendMode::PinLight => BlendKind::Separable(b_pin_light),
        BlendMode::HardMix => BlendKind::Separable(b_hard_mix),
        BlendMode::Divide => BlendKind::Separable(b_divide),
        BlendMode::Hue => BlendKind::NonSeparable(b_hue),
        BlendMode::Saturation => BlendKind::NonSeparable(b_saturation),
        BlendMode::Color => BlendKind::NonSeparable(b_color),
        BlendMode::Luminosity => BlendKind::NonSeparable(b_luminosity),
    }
}

/// Deterministic Dissolve threshold for a canvas position, in [0, 1).
/// Murmur3-style integer mix of the coordinates; canvas-absolute so the
/// dither pattern is stable for a given position regardless of layer offset
/// or projection window. Only the low 24 hash bits are used so the result is
/// exact in f32 and strictly below 1 (a fully opaque pixel always shows).
pub(crate) fn dissolve_threshold(x: i64, y: i64) -> f32 {
    let mut h = (x as u32)
        .wrapping_mul(0x9E37_79B9)
        .wrapping_add((y as u32).wrapping_mul(0x85EB_CA6B));
    h ^= h >> 16;
    h = h.wrapping_mul(0x85EB_CA6B);
    h ^= h >> 13;
    h = h.wrapping_mul(0xC2B2_AE35);
    h ^= h >> 16;
    ((h >> 8) as f32) * (1.0 / 16_777_216.0)
}

// ------------------------------------------------- shared pixel kernels --

/// One W3C compositing step of a straight-color source (`cs`, effective
/// alpha `sa` > 0, both in [0, 1]) onto accumulator pixel `acc[ai]` — THE
/// inner loop shared by `doc`'s layer and clip-group compositors.
///
/// Dissolve skips the compositing formula: the source shows fully opaque
/// with probability `sa` (its effective alpha), decided by the deterministic
/// canvas-absolute threshold at `canvas_xy`; otherwise the backdrop pixel
/// stays untouched.
pub(crate) fn composite_source_into(
    acc: &mut [[f32; 4]],
    ai: usize,
    cs: [f32; 3],
    sa: f32,
    kind: BlendKind,
    canvas_xy: (i64, i64),
) {
    if let BlendKind::Dissolve = kind {
        if dissolve_threshold(canvas_xy.0, canvas_xy.1) < sa {
            acc[ai] = [cs[0], cs[1], cs[2], 1.0];
        }
        return;
    }
    let bg = acc[ai];
    let ab = bg[3];
    let ao = sa + ab * (1.0 - sa);
    let blended = match kind {
        BlendKind::Separable(f) => [f(bg[0], cs[0]), f(bg[1], cs[1]), f(bg[2], cs[2])],
        BlendKind::NonSeparable(f) => f([bg[0], bg[1], bg[2]], cs),
        BlendKind::Dissolve => unreachable!("dissolve handled above"),
    };
    let mut out = [0.0f32; 4];
    for c in 0..3 {
        out[c] = (sa * (1.0 - ab) * cs[c] + sa * ab * blended[c] + (1.0 - sa) * ab * bg[c]) / ao;
    }
    out[3] = ao;
    acc[ai] = out;
}

/// The shared straight-alpha source-over write: composites a source with
/// effective alpha `sa` and PREMULTIPLIED f32 color `scp` (straight color
/// times `sa`, all in [0, 1]) onto the straight RGBA8 pixel `dp`. Callers
/// have already handled `sa <= 0` and a vanishing output alpha, so the
/// division is safe.
pub(crate) fn source_over_rgba8(dp: &mut [u8], scp: [f32; 3], sa: f32) {
    let da = f32::from(dp[3]) / 255.0;
    let out_a = sa + da * (1.0 - sa);
    for c in 0..3 {
        let dc = f32::from(dp[c]) / 255.0;
        let v = (scp[c] + dc * da * (1.0 - sa)) / out_a;
        dp[c] = (v.clamp(0.0, 1.0) * 255.0).round() as u8;
    }
    dp[3] = (out_a.clamp(0.0, 1.0) * 255.0).round() as u8;
}

/// Per-pixel core of `rz_image_composite` and the layer paint path — the ONE
/// implementation of premultiplied-overlay compositing: `ops::composite`
/// composites two same-size frames through it and `RzDocument::painting_layer`
/// maps a canvas-frame overlay through a layer offset onto it.
/// (`doc_select`'s straight-source painter shares [`source_over_rgba8`].)
/// `dp` is a straight-alpha RGBA8 pixel, `sp` a premultiplied overlay pixel,
/// `a` the pre-clamped global alpha.
pub(crate) fn paint_pixel(dp: &mut [u8], sp: [u8; 4], mode: CompositeMode, a: f32) {
    // Fast path: a fully transparent overlay pixel passes the destination
    // bytes through exactly (no float round-trip). For OVER the color bytes
    // must also be zero — they always are in well-formed premultiplied data;
    // malformed pixels fall through to the math.
    let src_transparent = sp[3] == 0
        && match mode {
            CompositeMode::Over => sp[0] == 0 && sp[1] == 0 && sp[2] == 0,
            CompositeMode::Erase => true,
        };
    if src_transparent {
        return;
    }
    let sa = (f32::from(sp[3]) / 255.0) * a;
    let da = f32::from(dp[3]) / 255.0;
    match mode {
        CompositeMode::Over => {
            let out_a = sa + da * (1.0 - sa);
            if out_a < 1e-6 {
                // Keep the destination color bytes so fully transparent
                // regions do not invent color fringes.
                dp[3] = 0;
            } else {
                let scp = [
                    (f32::from(sp[0]) / 255.0) * a,
                    (f32::from(sp[1]) / 255.0) * a,
                    (f32::from(sp[2]) / 255.0) * a,
                ];
                source_over_rgba8(dp, scp, sa);
            }
        }
        CompositeMode::Erase => {
            let out_a = da * (1.0 - sa);
            dp[3] = (out_a.clamp(0.0, 1.0) * 255.0).round() as u8;
        }
    }
}
