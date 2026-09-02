//! Inner glow (Photoshop Layer Style > Inner Glow): a glow INSIDE the
//! shape, composited above the pixels with its own blend mode (Screen by
//! default), colour and opacity. Where the glow comes from is the `source`:
//!
//! - `edge` (the default) — the glow hugs the inside of the contour and
//!   fades toward the interior. `plane = shape.inverted()` (the OUTSIDE of
//!   the shape); `(dilate, sigma) = spread_split(size, choke)`;
//!   `dilate_plane(plane, dilate)` grows the outside INTO the shape, so
//!   choke is the hard part of the glow — `size * choke` px of full
//!   coverage along the contour — and `blur_plane(plane, sigma)` softens
//!   the remaining `size * (1 - choke)` px; `multiply_planes(plane,
//!   coverage)` clips it to the shape. At choke 1 the glow is exactly the
//!   band the shape loses when it is shrunk by `size` (the grow of the
//!   inverse is the complement of the shrink — the closed form the tests
//!   pin).
//! - `center` — the glow rises from the interior and fades toward the
//!   contour. `plane = coverage.clone()`; `erode_plane(plane, dilate)` pulls
//!   the glow's plateau `size * choke` px in from the contour, the mirror
//!   of what choke does to an edge glow; `blur_plane(plane, sigma)`;
//!   `multiply_planes(plane, coverage)`. The blur is centred on the
//!   contour, so the glow sits at half strength right at the edge and
//!   reaches full strength `size` px in — the look of Photoshop's Center
//!   source at its default choke. With `size == 0` the plane IS the shape:
//!   the whole interior glows at full coverage.
//!
//! One Interior contribution (kind InnerGlow, solid colour). Nothing at
//! opacity 0, nothing for an `edge` glow of size 0 (a glow with no extent —
//! see [`render`]), and nothing when the plane comes out empty (a fully
//! transparent layer). The inner glow has no light direction, so `ctx` is
//! unused; the pad `LayerStyle::pad()` reserves for it
//! (`ceil(dilate) + 1 + blur_reach(sigma)`) is exactly what the dilate and
//! the blur can reach, so the plane renders as it would on an infinite one.

use crate::style::{EffectKind, GlowSource, InnerGlow};
use crate::style_render::{
    blur_plane, dilate_plane, erode_plane, multiply_planes, spread_split, Contribution, Placement,
    RenderContext, Shape,
};

/// Renders `fx` over `shape`: one Interior contribution whose coverage is
/// bounded by `shape.coverage` (module doc), or none when there is nothing
/// to draw. An `edge` glow of size 0 is nothing rather than
/// `inverted × coverage`: that product is 0 on every hard pixel and only
/// non-zero along anti-aliased edges (`(255 - c) * c / 255`, at most 64),
/// which would draw a faint one-pixel halo where a 0 px glow should draw
/// nothing. A `center` glow of size 0 is the whole shape, which is what
/// Photoshop shows too.
pub(crate) fn render(fx: &InnerGlow, shape: &Shape, ctx: &RenderContext) -> Vec<Contribution> {
    let _ = ctx;
    if fx.opacity.is_nan() || fx.opacity <= 0.0 {
        return Vec::new();
    }
    let (dilate, sigma) = spread_split(fx.size, fx.choke);
    let mut plane = match fx.source {
        GlowSource::Edge => {
            // A NaN size (only reachable by direct construction; the parser
            // clamps) draws nothing too, like a NaN opacity.
            if fx.size.is_nan() || fx.size <= 0.0 {
                return Vec::new();
            }
            let mut plane = shape.inverted();
            dilate_plane(&mut plane, shape.w, shape.h, dilate);
            plane
        }
        GlowSource::Center => {
            let mut plane = shape.coverage.clone();
            erode_plane(&mut plane, shape.w, shape.h, dilate);
            plane
        }
    };
    blur_plane(&mut plane, shape.w, shape.h, sigma);
    multiply_planes(&mut plane, &shape.coverage);
    if plane.iter().all(|&v| v == 0) {
        return Vec::new();
    }
    vec![Contribution::solid(
        EffectKind::InnerGlow,
        plane,
        fx.color,
        fx.blend,
        fx.opacity,
        Placement::Interior,
    )]
}
