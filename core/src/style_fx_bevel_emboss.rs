//! Bevel & Emboss (Photoshop Layer Style > Bevel & Emboss), smooth
//! technique: the shape is treated as a relief whose height field is a blur
//! of the coverage, lit from (`angle`, `altitude`), and the lit and unlit
//! slopes become a highlight and a shadow contribution.
//!
//! # The height field
//!
//! `blur = blur_plane(coverage, sigma_for_size(size))` (THE blur, via
//! `style_render`; sigma = size/2 like every other effect, so a bevel of
//! `size` rises over about `size` px). Unit-scaled per style, as u8 planes
//! through the shared `multiply_planes`:
//!
//! - inner bevel: `h = blur × coverage/255` — rises from the edge inward,
//!   flat inside; the outside is flat 0.
//! - outer bevel: `h = blur × inverted/255 + coverage/255` — the shape is a
//!   plateau at full height and the slope falls from its edge outward. The
//!   plateau matters: `blur × inverted` alone would drop to 0 inside and
//!   turn the first outside pixel into a ridge whose inner flank faces away
//!   from the light — a dark hairline along the lit edge.
//! - emboss: `h = blur` — one slope centred on the contour, half outside,
//!   half inside (the shape is a raised plateau).
//! - pillow emboss: `h = blur` outside and `1 − blur` inside (combined as
//!   `blur × inverted + (255 − blur) × coverage`, continuous through
//!   anti-aliased edges): a ridge along the contour, so the outside reads
//!   like an emboss and the inside like a dent — the edges look pressed
//!   into the layers below.
//!
//! `soften` blurs `h` once more with `sigma_for_size(soften)`.
//!
//! # Shading
//!
//! The surface normal comes from central differences of `h`:
//! `n = normalize(−depth·k·∂h/∂x, −depth·k·∂h/∂y, 1)` with `k = size`. The
//! height is unit-scaled (0..1 regardless of `size`), so its slope shrinks
//! as the bevel widens; multiplying by `size` restores the slope of a bevel
//! whose height grows with its width, which is what makes a 20 px bevel
//! shade like a 5 px one instead of fading out. `depth` (1 = Photoshop's
//! 100 %) scales the slope, i.e. the contrast.
//!
//! The light vector is `L = (cos alt · cos ang, −cos alt · sin ang, sin alt)`
//! from `resolved_angle` / `resolved_altitude` (y-down: 0° lights from the
//! right, 90° from the top). Shading is `d = n.x·L.x + n.y·L.y` — the
//! LATERAL part of `n·L` only. Dropping `n.z·L.z` makes three things shade
//! to exactly 0: flat ground (`n = (0, 0, 1)`), slopes perpendicular to the
//! light's azimuth, and altitude 90 (`L = (0, 0, 1)`), whereas the full
//! `n·L − L.z` would darken every slope. Direction `down` negates `d`.
//! Highlight coverage is `round(255·clamp(d, 0, 1))`, shadow
//! `round(255·clamp(−d, 0, 1))`, each restricted to the bevel band by a
//! multiply with the shape (inner half → `coverage`, outer half →
//! `inverted`); the inner halves are Interior contributions, the outer
//! halves Below, all of kind `BevelEmboss` with the highlight's and the
//! shadow's own blend, colour and opacity.
//!
//! # Numeric choices
//!
//! - `size == 0` renders nothing: `k = 0` flattens every normal, and a bevel
//!   of no width has nothing to light (Photoshop's dialog floors size at 1).
//! - The height field is a u8 plane (the one-blur rule), so a central
//!   difference over ±`s` px resolves `k·∂h/∂x` in steps of
//!   `size / (255 · 2s)`. With `s = 1` a 4 px bevel has ~100 steps across
//!   its ramp's ~0.8 peak, but a 60 px one only ~17 and a 250 px one four —
//!   and the staircase shows as mottling wherever the ramp is nearly flat.
//!   The stencil therefore grows with the size, `s = round(size / 8)`
//!   (at least 1, so sizes below 12 keep the plain central difference the
//!   tests restate): the step stays about 1/50 of the peak slope at every
//!   size. The lip this makes at an inner bevel's cliff (`s` px of steeper
//!   slope where the stencil straddles the edge) reads as a rounded edge.
//! - Exactness at the plane border comes from the pad alone:
//!   `Effect::reach` for a bevel is the two blurs' reach plus the stencil
//!   half-width `s` (`stencil_half_width`, the same function `shade`
//!   uses), so the height field is zero for at least `s + 1` px inside
//!   every border — every read lands on the plane (reads are clamped
//!   anyway, but a clamped read of a non-zero border would be wrong) and
//!   no pixel outside the plane would have had a non-zero derivative. The
//!   stencil is therefore a function of `size` alone, never of where the
//!   shape sits on the plane, which is what lets the cache re-render a
//!   sub-plane of a brush stroke and get the full plane's bytes.
//! - Non-finite inputs (impossible from the parser, which clamps; only a
//!   directly constructed effect can carry them) shade to nothing: NaN
//!   falls through `clamp` and `as u8` to coverage 0, never a panic.
//! - A contribution whose plane is all zero (altitude 90, a slope facing
//!   nowhere) is dropped rather than composited for nothing.

use crate::blend::BlendMode;
use crate::style::{BevelDirection, BevelEmboss, BevelStyle, EffectKind};
use crate::style_render::{
    blur_plane, invert_plane, multiply_planes, sigma_for_size, Contribution, Part, Placement,
    RenderContext, Shape,
};

/// Pixels of bevel per pixel of derivative stencil (module doc): the
/// stencil half-width is `round(size / STENCIL_DIVISOR)`, at least 1.
const STENCIL_DIVISOR: f32 = 8.0;

/// The central-difference stencil half-width for a bevel of `size` px
/// (module doc): `round(size / 8)` clamped to 1..=64. Shared with
/// `Effect::reach`, which pads the plane by it.
pub(crate) fn stencil_half_width(size: f32) -> u32 {
    if size.is_finite() {
        (size / STENCIL_DIVISOR).round().clamp(1.0, 64.0) as u32
    } else {
        1
    }
}

/// Renders `fx` over `shape`: up to four contributions — the inner
/// highlight and shadow (Interior) and the outer highlight and shadow
/// (Below), whichever the style has. Nothing at size 0, with both
/// opacities 0, or on an empty plane.
pub(crate) fn render(fx: &BevelEmboss, shape: &Shape, ctx: &RenderContext) -> Vec<Contribution> {
    let lit = |opacity: f32| opacity.is_finite() && opacity > 0.0;
    let (highlight_on, shadow_on) = (lit(fx.highlight_opacity), lit(fx.shadow_opacity));
    let (w, h) = (shape.w, shape.h);
    if !(highlight_on || shadow_on)
        || fx.size.is_nan()
        || fx.size <= 0.0
        || w == 0
        || h == 0
        || shape.coverage.len() != w as usize * h as usize
    {
        return Vec::new();
    }

    let inverted = shape.inverted();
    let height = height_field(fx, shape, &inverted);
    let shading = shade(&height, w, h, fx, ctx);
    let highlight: Vec<u8> = shading.iter().map(|&d| coverage_byte(d)).collect();
    let shadow: Vec<u8> = shading.iter().map(|&d| coverage_byte(-d)).collect();

    // Which halves the style has: the inner band is the shape, the outer
    // band its inverse.
    let (interior, below): (Option<&[u8]>, Option<&[u8]>) = match fx.style {
        BevelStyle::InnerBevel => (Some(&shape.coverage), None),
        BevelStyle::OuterBevel => (None, Some(&inverted)),
        BevelStyle::Emboss | BevelStyle::PillowEmboss => (Some(&shape.coverage), Some(&inverted)),
    };
    let mut out = Vec::with_capacity(4);
    for (band, placement) in [(below, Placement::Below), (interior, Placement::Interior)] {
        let Some(band) = band else {
            continue;
        };
        if highlight_on {
            push_banded(
                &mut out,
                &highlight,
                band,
                Part::Highlight,
                fx.highlight_color,
                fx.highlight_blend,
                fx.highlight_opacity,
                placement,
            );
        }
        if shadow_on {
            push_banded(
                &mut out,
                &shadow,
                band,
                Part::Shadow,
                fx.shadow_color,
                fx.shadow_blend,
                fx.shadow_opacity,
                placement,
            );
        }
    }
    out
}

/// The unit-scaled height field of the module doc as a u8 plane: the
/// blurred coverage shaped per style, then softened.
fn height_field(fx: &BevelEmboss, shape: &Shape, inverted: &[u8]) -> Vec<u8> {
    let (w, h) = (shape.w, shape.h);
    let mut blur = shape.coverage.clone();
    blur_plane(&mut blur, w, h, sigma_for_size(fx.size));
    let mut height = match fx.style {
        BevelStyle::InnerBevel => {
            multiply_planes(&mut blur, &shape.coverage);
            blur
        }
        BevelStyle::OuterBevel => {
            // The slope outside plus the shape at full height: with
            // `blur × inverted` alone the inside would sit at 0, making a
            // ridge just outside the edge whose inner flank faces the
            // wrong way — a dark hairline along the lit side.
            multiply_planes(&mut blur, inverted);
            for (b, &c) in blur.iter_mut().zip(&shape.coverage) {
                *b = b.saturating_add(c);
            }
            blur
        }
        BevelStyle::Emboss => blur,
        BevelStyle::PillowEmboss => {
            // Outside: the blur; inside: its inverse. The two halves sum to
            // at most max(blur, 255 - blur) because coverage + inverted =
            // 255, so the saturating add only guards rounding.
            let mut outside = blur.clone();
            multiply_planes(&mut outside, inverted);
            invert_plane(&mut blur);
            multiply_planes(&mut blur, &shape.coverage);
            for (o, &i) in outside.iter_mut().zip(&blur) {
                *o = o.saturating_add(i);
            }
            outside
        }
    };
    blur_plane(&mut height, w, h, sigma_for_size(fx.soften));
    height
}

/// The shading `d` of the module doc for every plane pixel: the lateral
/// dot product of the surface normal with the light, negated for
/// direction `down`.
fn shade(height: &[u8], w: u32, h: u32, fx: &BevelEmboss, ctx: &RenderContext) -> Vec<f32> {
    let (wi, hi) = (i64::from(w), i64::from(h));
    if height.iter().all(|&v| v == 0) {
        return vec![0.0; height.len()];
    }
    let s = i64::from(stencil_half_width(fx.size));
    // depth·k·∂h/∂x with ∂h/∂x = (h[x+s] − h[x−s]) / (255 · 2s) — the u8
    // height's unit scale and the stencil width folded into one gain.
    let gain = fx.depth * fx.size / (255.0 * 2.0 * s as f32);
    let angle = fx.resolved_angle(ctx.light).to_radians();
    let altitude = fx.resolved_altitude(ctx.light).to_radians();
    let lx = altitude.cos() * angle.cos();
    let ly = -altitude.cos() * angle.sin();
    let sign = match fx.direction {
        BevelDirection::Up => 1.0,
        BevelDirection::Down => -1.0,
    };
    let at = |x: i64, y: i64| -> f32 {
        let (x, y) = (x.clamp(0, wi - 1), y.clamp(0, hi - 1));
        f32::from(height[(y * wi + x) as usize])
    };
    let mut out = Vec::with_capacity(height.len());
    for y in 0..hi {
        for x in 0..wi {
            let hx = (at(x + s, y) - at(x - s, y)) * gain;
            let hy = (at(x, y + s) - at(x, y - s)) * gain;
            // n = (−hx, −hy, 1) / |(−hx, −hy, 1)|; d = n.x·L.x + n.y·L.y.
            let inv_len = 1.0 / (1.0 + hx * hx + hy * hy).sqrt();
            out.push(-(hx * lx + hy * ly) * inv_len * sign);
        }
    }
    out
}

/// `round(255 · clamp(d, 0, 1))`; NaN clamps to NaN and casts to 0.
fn coverage_byte(d: f32) -> u8 {
    (255.0 * d.clamp(0.0, 1.0)).round() as u8
}

/// `plane × band / 255` as one solid contribution tagged `part` (the
/// highlight or the shadow, so a re-stamp can tell them apart), unless it
/// is all zero.
#[allow(clippy::too_many_arguments)]
fn push_banded(
    out: &mut Vec<Contribution>,
    plane: &[u8],
    band: &[u8],
    part: Part,
    color: [u8; 3],
    blend: BlendMode,
    opacity: f32,
    placement: Placement,
) {
    let mut coverage = plane.to_vec();
    multiply_planes(&mut coverage, band);
    if coverage.iter().all(|&v| v == 0) {
        return;
    }
    let mut c = Contribution::solid(
        EffectKind::BevelEmboss,
        coverage,
        color,
        blend,
        opacity,
        placement,
    );
    c.part = part;
    out.push(c);
}
