//! Drop shadow (Photoshop Layer Style > Drop Shadow): the layer's shape,
//! dilated by `size * spread`, blurred by `size * (1 - spread)`, offset by
//! (`distance`, `angle`) and colourized, composited BELOW the pixels with
//! the effect's own blend mode and opacity. With "Layer Knocks Out Drop
//! Shadow" (`layer_knocks_out`, the default) the shadow is not drawn under
//! the layer's own shape, so a layer at 0 % fill shows no shadow through
//! itself.

use crate::style::{DropShadow, EffectKind};
use crate::style_render::{
    blur_plane, dilate_plane, light_offset, spread_split, unit_color, Contribution, Part,
    Placement, PlaneColor, RenderContext, Shape,
};

/// Renders `fx` over `shape`: one Below contribution, shifted at composite
/// time by [`light_offset`] of the resolved angle and `distance`. Nothing
/// at opacity 0. With `size == 0 && spread == 0` the plane IS the shape
/// (both primitives are no-ops at 0), so a hard shadow is the shape
/// translated — the oracle the tests pin.
pub(crate) fn render(fx: &DropShadow, shape: &Shape, ctx: &RenderContext) -> Vec<Contribution> {
    if fx.opacity.is_nan() || fx.opacity <= 0.0 {
        return Vec::new();
    }
    let mut plane = shape.coverage.clone();
    let (dilate, sigma) = spread_split(fx.size, fx.spread);
    dilate_plane(&mut plane, shape.w, shape.h, dilate);
    blur_plane(&mut plane, shape.w, shape.h, sigma);
    vec![Contribution {
        kind: EffectKind::DropShadow,
        part: Part::Main,
        coverage: plane,
        color: PlaneColor::Solid(unit_color(fx.color)),
        blend: fx.blend,
        opacity: fx.opacity,
        placement: Placement::Below,
        shift: light_offset(fx.resolved_angle(ctx.light), fx.distance),
        knocked_out_by_shape: fx.layer_knocks_out,
    }]
}
