//! Inner shadow (Photoshop Layer Style > Inner Shadow): the shadow a raised
//! edge casts INTO the shape — the layer read as a hole cut in the surface
//! and lit from `angle`, so the rim nearest the light throws a shadow onto
//! the pixels along that edge.
//!
//! # Algorithm
//!
//! The plane starts as the INVERTED shape (`255 - coverage`: opaque outside,
//! clear inside), because the shadow is what the outside casts inward:
//!
//! 1. `(dilate, sigma) = spread_split(size, choke)`, the same split a drop
//!    shadow makes of `size` and `spread`; `dilate_plane` grows the OUTSIDE
//!    by `size * choke` — "choke" is spread's mirror, the hard part of the
//!    shadow pulled inward rather than pushed outward — and `blur_plane`
//!    softens what is left by `size * (1 - choke)`. Both are the shared
//!    primitives of `style_render`, never a second Gaussian or EDT.
//! 2. The plane is shifted by `light_offset(resolved angle, distance)`,
//!    exactly the drop shadow's offset for the same light: at angle 0 the
//!    light comes from the right, the offset is `(-distance, 0)`, the
//!    outside slides LEFT into the shape and the shadow is the band inside
//!    the RIGHT edge; at 90° (light from the top) it sits under the top
//!    edge; at Photoshop's default 120° it hugs the top-left edges. The
//!    shift fills with 255 — everything beyond the plane is "outside" too,
//!    so a region shifted in from the border must stay shadow rather than
//!    open a clear seam. `LayerStyle::pad` adds `ceil(distance)` to this
//!    effect's reach for precisely this step, so the fill is never actually
//!    read inside the layer rect and the plane renders as it would on an
//!    infinite one.
//! 3. The plane is multiplied by the shape coverage. Every Interior
//!    contribution must be bounded by the shape (`style_composite` draws it
//!    straight onto the accumulator on that promise), and for an inner
//!    shadow the clip IS the effect: only what falls on the pixels shows.
//!
//! Why the shift happens inside the plane rather than at composite time as
//! the drop shadow's does: the drop shadow is clipped by nothing (or knocked
//! out at the landing position), but an inner shadow is clipped to the
//! shape AFTER the shift, so the shift has to precede the multiply.
//!
//! With `size == 0 && choke == 0` both primitives are no-ops and the plane
//! is exactly the inverted shape translated: for a hard rect the shadow is
//! `rect \ (rect + offset)` at full coverage — the closed form the tests
//! pin. With `choke == 1` the plane is the grown inverted shape, so the
//! band follows the grow-rect closed form of `doc_select::grow_mask`.
//!
//! One Interior contribution (kind `InnerShadow`, solid colour, the
//! effect's own blend mode and opacity); none at opacity 0 or when the
//! clipped plane is empty (a hard shape at distance 0 with no size casts
//! nothing, and an all-transparent shape has nothing to cast onto).

use crate::style::{EffectKind, InnerShadow};
use crate::style_render::{
    blur_plane, dilate_plane, light_offset, multiply_planes, shift_plane, spread_split,
    Contribution, Placement, RenderContext, Shape,
};

/// Renders `fx` over `shape`: one Interior contribution, or none when the
/// effect is invisible (opacity 0, or a clipped plane that is all zero).
pub(crate) fn render(fx: &InnerShadow, shape: &Shape, ctx: &RenderContext) -> Vec<Contribution> {
    if fx.opacity.is_nan() || fx.opacity <= 0.0 {
        return Vec::new();
    }
    let mut plane = shape.inverted();
    let (dilate, sigma) = spread_split(fx.size, fx.choke);
    dilate_plane(&mut plane, shape.w, shape.h, dilate);
    blur_plane(&mut plane, shape.w, shape.h, sigma);
    let (dx, dy) = light_offset(fx.resolved_angle(ctx.light), fx.distance);
    // `shift_plane` allocates a second plane; at distance 0 (or an angle
    // whose rounded offset is zero) the shifted plane would be a copy.
    if (dx, dy) != (0, 0) {
        // Fill 255: beyond the plane is outside the shape, hence shadow
        // (module doc, step 2).
        plane = shift_plane(&plane, shape.w, shape.h, dx, dy, 255);
    }
    multiply_planes(&mut plane, &shape.coverage);
    // An empty plane would cost the compositor a full pass over the shape
    // for nothing; the scan is one byte per pixel against a blur that was
    // dozens of taps per pixel.
    if plane.iter().all(|&v| v == 0) {
        return Vec::new();
    }
    vec![Contribution::solid(
        EffectKind::InnerShadow,
        plane,
        fx.color,
        fx.blend,
        fx.opacity,
        Placement::Interior,
    )]
}
