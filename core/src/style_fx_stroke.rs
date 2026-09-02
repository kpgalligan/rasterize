//! Stroke (Photoshop Layer Style > Stroke): a band of constant width along
//! the shape's contour, filled with a colour or a gradient, composited with
//! the effect's own blend mode and opacity.
//!
//! # The band
//!
//! The contour is the shape's 50 % coverage line, and the band is built from
//! the morphology primitives in `style_render` (the ONE distance transform,
//! `doc_select`'s `grow_mask` / `shrink_mask`), so a stroke and a
//! grown/shrunk selection of the same width agree pixel for pixel:
//!
//! - Outside: `dilate(coverage, size)` knocked out by the shape's own
//!   coverage (`× (255 − coverage)`, `Shape::inverted`) — every pixel
//!   within `size` px of the shape's contour, with `grow_mask`'s ~1 px
//!   anti-aliased rim and rounded outer corners, where the layer is
//!   transparent. A Below contribution: the pixels draw over it, so an
//!   opaque layer hides the band's inner edge exactly as Photoshop's
//!   outside stroke sits under the fill, a layer at 0 % fill shows the
//!   band as an outline, never a filled shape, and a layer painted at 50 %
//!   opacity carries at most a quarter of the band's tint under its
//!   interior rather than a solid fill of stroke colour. The proportion is
//!   the drop shadow's knock-out (`knocked_out_by_shape`), so every
//!   exterior effect knocks out alike; an anti-aliased edge pixel at
//!   alpha `a` sits over `1 − a` of the band and fades the stroke out
//!   smoothly instead of at a hard threshold.
//! - Inside: `coverage − erode(coverage, size)` — the `size` px of the shape
//!   nearest its edge. An Interior contribution, bounded by the shape per
//!   pixel because `a.saturating_sub(b) <= a`; an anti-aliased edge pixel
//!   keeps its own alpha here, since the band IS the shape's edge.
//! - Center: the two halves at `size / 2` each, emitted as SEPARATE
//!   contributions so each lands in its own group (the outer half Below, the
//!   inner half Interior). Photoshop centres the band on the contour, half
//!   outside and half inside; splitting at exactly half keeps `outside 2 +
//!   inside 2 == center 4` for a hard edge, which is the oracle the tests
//!   pin.
//!
//! `size == 0` draws nothing (a stroke of no width has no band), and a band
//! that ends up all zero — an empty or fully transparent shape — is dropped
//! rather than composited.
//!
//! # The fill
//!
//! `Color` is one solid colour. `Gradient` evaluates
//! `style_gradient::GradientSampler` / `gradient_color` (the ONE gradient
//! implementation, shared with the gradient overlay) at every band pixel's
//! CENTRE, `(x + 0.5, y + 0.5)` in layer coordinates — the same convention
//! as the selection gradient tool, which makes a linear gradient across an
//! `n`-pixel box hit `t = (i + 0.5) / n` at column `i`. The box is
//! `style_gradient::gradient_box`: with `align_with_layer` (the default) the
//! bounding box of the layer's non-transparent pixels — deliberately the same box
//! Gradient Overlay uses, so a gradient stroke and a gradient overlay with
//! the same settings line up and the stroke reads as a continuation of the
//! fill (the classic Photoshop bevelled-text trick); an outside band beyond
//! the box's ends therefore holds the end stops' colours, which is what
//! the sampler's clamp gives. Without `align_with_layer` the box is the
//! CANVAS rect, and the render cache keys on the canvas and the offset for
//! such styles (`LayerStyle::needs_canvas_alignment`). The stop opacity
//! multiplies the band coverage, `round(coverage × a)`, so a transparent
//! stop lets the backdrop (or the pixels, for an inside band) show through;
//! the colour itself is a [`PlaneColor::Gradient`] evaluated per pixel at
//! composite time rather than a stored colour plane.

use crate::style::{EffectKind, GradientFill, Stroke, StrokeFill, StrokePosition};
use crate::style_gradient::{gradient_box, gradient_color, GradientSampler};
use crate::style_render::{
    dilate_plane, erode_plane, multiply_planes, subtract_planes, unit_color, Contribution, Part,
    Placement, PlaneColor, RenderContext, Shape,
};

/// Renders `fx` over `shape`: one Below (outside), one Interior (inside) or
/// both (center — the outer half Below, the inner half Interior)
/// contributions, each with the effect's own blend and opacity, no shift
/// and no composite-time knock-out (an outside band is already knocked
/// out by the shape in-plane).
/// Nothing at opacity 0, at size 0, or when the band covers no pixel.
pub(crate) fn render(fx: &Stroke, shape: &Shape, ctx: &RenderContext) -> Vec<Contribution> {
    if fx.opacity.is_nan() || fx.opacity <= 0.0 || !fx.size.is_finite() || fx.size <= 0.0 {
        return Vec::new();
    }
    let mut out = Vec::with_capacity(2);
    match fx.position {
        StrokePosition::Outside => {
            out.extend(contribution(
                fx,
                shape,
                ctx,
                outside_band(shape, fx.size),
                Placement::Below,
            ));
        }
        StrokePosition::Inside => {
            out.extend(contribution(
                fx,
                shape,
                ctx,
                inside_band(shape, fx.size),
                Placement::Interior,
            ));
        }
        StrokePosition::Center => {
            // Half the width on each side of the contour (module doc).
            let half = fx.size / 2.0;
            out.extend(contribution(
                fx,
                shape,
                ctx,
                outside_band(shape, half),
                Placement::Below,
            ));
            out.extend(contribution(
                fx,
                shape,
                ctx,
                inside_band(shape, half),
                Placement::Interior,
            ));
        }
    }
    out
}

/// `dilate(coverage, px)` knocked out by the coverage: the band outside
/// the contour (module doc).
fn outside_band(shape: &Shape, px: f32) -> Vec<u8> {
    let mut grown = shape.coverage.clone();
    dilate_plane(&mut grown, shape.w, shape.h, px);
    multiply_planes(&mut grown, &shape.inverted());
    grown
}

/// `coverage − erode(coverage, px)`: the band inside the contour.
fn inside_band(shape: &Shape, px: f32) -> Vec<u8> {
    let mut shrunk = shape.coverage.clone();
    erode_plane(&mut shrunk, shape.w, shape.h, px);
    let mut band = shape.coverage.clone();
    subtract_planes(&mut band, &shrunk);
    band
}

/// One contribution of `band` at `placement` with the stroke's fill, or
/// `None` when the band covers nothing.
fn contribution(
    fx: &Stroke,
    shape: &Shape,
    ctx: &RenderContext,
    mut band: Vec<u8>,
    placement: Placement,
) -> Option<Contribution> {
    if band.iter().all(|&v| v == 0) {
        return None;
    }
    let color = match fx.fill_type {
        StrokeFill::Color => PlaneColor::Solid(unit_color(fx.color)),
        StrokeFill::Gradient => {
            if fx.gradient.stops.is_empty() {
                // The parser requires two stops; a direct construction with
                // none has no colour to draw.
                return None;
            }
            gradient_fill(&fx.gradient, shape, ctx, &mut band)
        }
    };
    Some(Contribution {
        kind: EffectKind::Stroke,
        part: Part::Main,
        coverage: band,
        color,
        blend: fx.blend,
        opacity: fx.opacity,
        placement,
        shift: (0, 0),
        knocked_out_by_shape: false,
    })
}

/// Multiplies every covered pixel of `band` by the stop opacity of `fill`
/// at its centre (layer coordinates) and returns the gradient as the
/// band's per-pixel colour. Only covered pixels are visited — with a large
/// shadow beside the stroke the padding can be most of the plane.
fn gradient_fill(
    fill: &GradientFill,
    shape: &Shape,
    ctx: &RenderContext,
    band: &mut [u8],
) -> PlaneColor {
    let (bx, by, bw, bh) = gradient_box(fill, shape, ctx);
    let sampler = GradientSampler::new(fill, bx, by, bw, bh);
    for y in 0..shape.h {
        for x in 0..shape.w {
            let i = shape.idx(x, y);
            let cov = band[i];
            if cov == 0 {
                continue;
            }
            let lx = (i64::from(x) + shape.origin.0) as f32 + 0.5;
            let ly = (i64::from(y) + shape.origin.1) as f32 + 0.5;
            let (_, a) = gradient_color(fill, sampler.t(lx, ly));
            let a = if a.is_finite() {
                a.clamp(0.0, 1.0)
            } else {
                0.0
            };
            band[i] = (f32::from(cov) * a).round() as u8;
        }
    }
    PlaneColor::Gradient(sampler)
}
