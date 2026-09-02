//! Gradient overlay (Photoshop Layer Style > Gradient Overlay): the shape
//! filled with a gradient ABOVE the pixels, composited with the effect's OWN
//! blend mode and opacity — never the layer's ("Blend Interior Effects as
//! Group" is off, Photoshop's default), so a Multiply text layer with a
//! Normal gradient overlay shows the gradient itself.
//!
//! # The gradient box
//!
//! The gradient is evaluated by `style_gradient::GradientSampler` / `gradient_color`
//! (the ONE gradient implementation, shared with the stroke's gradient fill)
//! over the box `style_gradient::gradient_box` gives in LAYER coordinates.
//! With `align_with_layer` (the default) the box is the bounding box of the
//! layer's non-transparent pixels (`Shape::bounds` — the mask left out, so
//! masking part of the shape away never makes the gradient jump), never the
//! pixel buffer's rect: a new, shape-tool or brush-painted layer is a
//! canvas-sized buffer whose content is a small region, and Photoshop spans
//! the gradient across the content, ignoring transparent pixels. A Move
//! drag keeps the gradient
//! attached to the layer, which is also why the rendered plane can be
//! cached per layer. Without it the box is the CANVAS rect,
//! `(-offset.x, -offset.y, canvas.w, canvas.h)` — the document's canvas,
//! not the projection window, so Merge Down bakes what the projection
//! showed. A canvas-aligned gradient therefore changes with the layer's
//! position and the canvas size, which is exactly what the render cache
//! keys on for such styles (`LayerStyle::needs_canvas_alignment`) — a Move
//! drag or a Canvas Size edit re-renders it, and nothing else does.
//!
//! # Sampling
//!
//! Every pixel is sampled at its CENTRE, `(x + 0.5, y + 0.5)`: the same
//! convention as the selection gradient tool and the one that makes a
//! linear gradient across an `n`-pixel box hit `t = (i + 0.5) / n` at column
//! `i` — symmetric about the box centre, never exactly 0 or 1 at the edge
//! pixels (the oracle the tests pin). The stop opacity multiplies the shape
//! coverage, `round(coverage × a)`, so a transparent stop lets the pixels
//! show through and an anti-aliased edge keeps its own alpha; the colour is
//! a [`PlaneColor::Gradient`] the compositor evaluates per pixel (storing
//! it per pixel would cost 12 bytes per plane pixel in every cache entry).
//! The Interior invariant `coverage <= shape.coverage` holds per pixel
//! because `a <= 1`.
//!
//! Only the layer rect of the plane (`Shape::layer_rect`) is visited: the
//! padding is 0 coverage by construction (`Shape::of_layer`), and with a
//! large drop shadow beside the overlay the padding can be most of the
//! plane. Nothing is rendered at opacity 0 (the parser clamps, but the check
//! is cheap and keeps the module total on every input), over a shape with
//! no coverage (an empty layer carrying a pasted style would otherwise pay
//! a per-pixel gradient evaluation every frame), or with no stops (the
//! parser requires at least two; a direct construction with none has
//! nothing to draw).

use crate::style::{EffectKind, GradientOverlay};
use crate::style_gradient::{gradient_box, gradient_color, GradientSampler};
use crate::style_render::{Contribution, Part, Placement, PlaneColor, RenderContext, Shape};

/// Renders `fx` over `shape`: one Interior contribution (kind
/// GradientOverlay, gradient colour, coverage = shape coverage × stop
/// opacity, the effect's blend and opacity, no shift, no knock-out). Empty
/// at opacity 0, over a shape with no coverage, or with no stops.
pub(crate) fn render(
    fx: &GradientOverlay,
    shape: &Shape,
    ctx: &RenderContext,
) -> Vec<Contribution> {
    if fx.opacity.is_nan() || fx.opacity <= 0.0 || fx.gradient.stops.is_empty() {
        return Vec::new();
    }
    if shape.coverage.iter().all(|&c| c == 0) {
        return Vec::new();
    }
    let (bx, by, bw, bh) = gradient_box(&fx.gradient, shape, ctx);
    let sampler = GradientSampler::new(&fx.gradient, bx, by, bw, bh);
    let mut coverage = vec![0u8; shape.coverage.len()];
    let (x0, y0, x1, y1) = shape.layer_rect();
    for y in y0..y1 {
        for x in x0..x1 {
            let i = shape.idx(x, y);
            let cov = shape.coverage[i];
            if cov == 0 {
                continue;
            }
            let lx = (i64::from(x) + shape.origin.0) as f32 + 0.5;
            let ly = (i64::from(y) + shape.origin.1) as f32 + 0.5;
            let (_, a) = gradient_color(&fx.gradient, sampler.t(lx, ly));
            let a = if a.is_finite() {
                a.clamp(0.0, 1.0)
            } else {
                0.0
            };
            coverage[i] = (f32::from(cov) * a).round() as u8;
        }
    }
    vec![Contribution {
        kind: EffectKind::GradientOverlay,
        part: Part::Main,
        coverage,
        color: PlaneColor::Gradient(sampler),
        blend: fx.blend,
        opacity: fx.opacity,
        placement: Placement::Interior,
        shift: (0, 0),
        knocked_out_by_shape: false,
    }]
}
