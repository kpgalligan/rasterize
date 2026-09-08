//! Outer glow (Photoshop Layer Style > Outer Glow): a glow around the
//! shape, OUTSIDE only. The shape's coverage is dilated by `size * spread`
//! and blurred by `size * (1 - spread)` — the drop shadow's recipe without
//! the offset, since a glow radiates evenly in every direction — then
//! knocked out by the shape's own coverage (`Shape::inverted`) so it lies
//! only where the layer is transparent, and emitted as ONE Below
//! contribution with the effect's own blend mode (Screen by default) and
//! opacity. Every primitive is `style_render`'s: `spread_split`,
//! `dilate_plane`, `blur_plane`, `multiply_planes`.
//!
//! # Why the knock-out happens in-plane, and in proportion to the coverage
//!
//! Photoshop never draws an outer glow under the layer's solid pixels: a
//! layer at 0 % fill with an outer glow is a hollow halo, and the dialog
//! has no "layer knocks out" switch for it (that toggle is the drop
//! shadow's opt-out). Multiplying here rather than setting the compositor's
//! `knocked_out_by_shape` flag keeps the cached plane self-contained (no
//! shift, nothing left for composite time). The proportion is the drop
//! shadow's: the plane is multiplied by `255 - coverage`, so under a pixel
//! at alpha `a` at most `1 - a` of the glow remains. A layer painted at
//! 50 % opacity therefore carries a quarter of the glow's tint under its
//! interior at most, never a full fill of glow colour, and an anti-aliased
//! edge pixel fades the glow out smoothly — the same machinery Photoshop's
//! "layer knocks out" uses for the drop shadow, applied to every exterior
//! effect alike (the outside stroke band does the same).
//!
//! # Why size 0 emits nothing
//!
//! At size 0 both primitives are no-ops (spread is a fraction OF size, so
//! the dilation is 0 too) and the plane IS the shape; knocking it out by
//! the shape leaves only `coverage × (255 − coverage)` along anti-aliased
//! edges — a stray ring on soft edges that Photoshop does not draw (its
//! size 0 is an empty glow). So a size-0 glow contributes nothing at all,
//! and the projection equals the unstyled layer's byte for byte, which the
//! tests pin.
//!
//! # Extent
//!
//! `LayerStyle::pad()` gives the plane `ceil(size * spread) + 1 +
//! blur_reach(sigma)` plus one px on each side — the reach of dilate then
//! blur — so the halo is never clipped by the plane's border; the outer
//! edge of the halo therefore sits at `size` px from the shape at spread 1
//! and fades over roughly `size` px at spread 0 (sigma = size / 2).

use crate::style::{EffectKind, OuterGlow};
use crate::style_render::{
    blur_plane, dilate_plane, multiply_planes, spread_split, Contribution, Placement,
    RenderContext, Shape,
};

/// Renders `fx` over `shape`: one Below contribution (kind OuterGlow, solid
/// colour, the effect's blend and opacity, no shift, not knocked out at
/// composite time — the plane is already knocked out by the shape). Nothing
/// at opacity 0 or size 0 (module doc). The context goes unread: a glow has
/// no light direction and no canvas alignment.
pub(crate) fn render(fx: &OuterGlow, shape: &Shape, _ctx: &RenderContext) -> Vec<Contribution> {
    if fx.opacity.is_nan() || fx.opacity <= 0.0 || fx.size.is_nan() || fx.size <= 0.0 {
        return Vec::new();
    }
    let mut plane = shape.coverage.clone();
    let (dilate, sigma) = spread_split(fx.size, fx.spread);
    dilate_plane(&mut plane, shape.w, shape.h, dilate);
    blur_plane(&mut plane, shape.w, shape.h, sigma);
    multiply_planes(&mut plane, &shape.inverted());
    vec![Contribution::solid(
        EffectKind::OuterGlow,
        plane,
        fx.color,
        fx.blend,
        fx.opacity,
        Placement::Below,
    )]
}
