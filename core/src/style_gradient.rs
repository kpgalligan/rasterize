//! The ONE gradient implementation the stroke's gradient fill and the
//! gradient overlay share: the box a fill spans (`gradient_box`), the
//! per-pixel parameter `t` with the box's trigonometry done once
//! (`GradientSampler`), and the colour and opacity at `t`
//! (`gradient_color`). Boxes and samples are in LAYER coordinates; the
//! plane model that maps them is `style_render`'s.

use crate::style::{GradientFill, GradientStop, GradientStyle};
use crate::style_render::{unit_color, RenderContext, Shape};

/// The box a `GradientFill` spans, in LAYER coordinates `(x, y, w, h)`:
/// with `align_with_layer` the bounding box of the layer's non-transparent
/// pixels (`Shape::bounds` — module doc; the buffer rect when there are
/// none), so a Move drag keeps the cached plane; else the canvas rect,
/// `(-offset.x, -offset.y, canvas.w, canvas.h)`, so the gradient stays put
/// on the canvas while the layer moves. The ONE mapping the stroke's
/// gradient fill and the gradient overlay share.
pub(crate) fn gradient_box(
    fill: &GradientFill,
    shape: &Shape,
    ctx: &RenderContext,
) -> (f32, f32, f32, f32) {
    if fill.align_with_layer {
        match shape.bounds {
            Some((x0, y0, x1, y1)) => (x0 as f32, y0 as f32, (x1 - x0) as f32, (y1 - y0) as f32),
            None => (0.0, 0.0, shape.lw as f32, shape.lh as f32),
        }
    } else {
        (
            -(ctx.layer_offset.0 as f32),
            -(ctx.layer_offset.1 as f32),
            ctx.canvas.0 as f32,
            ctx.canvas.1 as f32,
        )
    }
}

/// A gradient fill over one box, with the per-box trigonometry done once:
/// `PlaneColor::Gradient` samples it per pixel on every composite, and a
/// sine and cosine per pixel would be most of that cost on a large layer.
#[derive(Clone)]
pub(crate) struct GradientSampler {
    pub fill: GradientFill,
    angle: f32,
    sin_a: f32,
    cos_a: f32,
    cx: f32,
    cy: f32,
    extent: f32,
    major: f32,
}

impl GradientSampler {
    /// `fill` over the box `(bx, by, bw, bh)`.
    pub(crate) fn new(fill: &GradientFill, bx: f32, by: f32, bw: f32, bh: f32) -> Self {
        let angle = fill.angle.to_radians();
        let (sin_a, cos_a) = angle.sin_cos();
        let scale = if fill.scale.is_finite() {
            fill.scale.max(1e-6)
        } else {
            1.0
        };
        GradientSampler {
            fill: fill.clone(),
            angle,
            sin_a,
            cos_a,
            cx: bx + bw / 2.0,
            cy: by + bh / 2.0,
            extent: ((bw * cos_a).abs() + (bh * sin_a).abs()) * scale,
            major: bw.max(bh) * scale,
        }
    }

    /// This sampler with every stop colour mapped through `f` — how an
    /// AUTHORED gradient reaches the document's colour space at composite
    /// time (`style_composite`). Only the stops change: the box, the angle
    /// and the trigonometry are geometry, so the clone is a stop list.
    ///
    /// Mapping the STOPS rather than each sampled colour means the ramp is
    /// interpolated in the document's space, which is the space everything
    /// else about the effect is composited in, and costs one conversion per
    /// stop instead of one per pixel.
    pub(crate) fn mapping_colors(&self, f: impl Fn([u8; 3]) -> [u8; 3]) -> Self {
        let mut out = self.clone();
        for stop in &mut out.fill.stops {
            stop.color = f(stop.color);
        }
        out
    }

    /// The gradient parameter `t` in [0, 1] at `(x, y)` (a pixel centre in
    /// the box's coordinates). With centre `c`, angle `a` and `u`/`v` the
    /// coordinates rotated by `a`, the box's projection onto the gradient
    /// direction is `extent = (|bw cos a| + |bh sin a|) * scale` (Photoshop
    /// spans the gradient across the layer box at any angle): linear
    /// `0.5 + u / extent`; reflected `|2u / extent|`; radial
    /// `2 |p - c| / (max(bw, bh) scale)`; diamond
    /// `2 (|u| + |v|) / (max(bw, bh) scale)`; angle
    /// `((atan2(-(y - cy), x - cx) - a) mod 2pi) / 2pi`. So at angle 0 a
    /// linear gradient runs left to right, at 90 bottom to top (y-down).
    /// Clamped, then `1 - t` when `reverse`.
    pub(crate) fn t(&self, x: f32, y: f32) -> f32 {
        let dx = x - self.cx;
        let dy = y - self.cy;
        let u = dx * self.cos_a - dy * self.sin_a;
        let v = dx * self.sin_a + dy * self.cos_a;
        let t = match self.fill.style {
            GradientStyle::Linear => 0.5 + u / self.extent,
            GradientStyle::Reflected => (2.0 * u / self.extent).abs(),
            GradientStyle::Radial => 2.0 * (dx * dx + dy * dy).sqrt() / self.major,
            GradientStyle::Diamond => 2.0 * (u.abs() + v.abs()) / self.major,
            GradientStyle::Angle => {
                let tau = std::f32::consts::TAU;
                ((-dy).atan2(dx) - self.angle).rem_euclid(tau) / tau
            }
        };
        let t = if t.is_finite() {
            t.clamp(0.0, 1.0)
        } else {
            0.0
        };
        if self.fill.reverse {
            1.0 - t
        } else {
            t
        }
    }
}

/// The straight RGB and opacity of `fill` at `t`: linear between the two
/// bracketing stops (stops are sorted by position; of two at the same
/// position the later one wins past it), clamped to the end stops.
pub(crate) fn gradient_color(fill: &GradientFill, t: f32) -> ([f32; 3], f32) {
    let stops = &fill.stops;
    let Some(first) = stops.first() else {
        return ([0.0; 3], 0.0);
    };
    let last = stops.last().unwrap_or(first);
    let at = |s: &GradientStop| (unit_color(s.color), s.opacity);
    if t.is_nan() || t <= first.position {
        return at(first);
    }
    if t >= last.position {
        return at(last);
    }
    for pair in stops.windows(2) {
        let (a, b) = (&pair[0], &pair[1]);
        if t >= a.position && t < b.position {
            let span = b.position - a.position;
            let f = if span > 0.0 {
                (t - a.position) / span
            } else {
                1.0
            };
            let (ca, oa) = at(a);
            let (cb, ob) = at(b);
            return (
                [
                    ca[0] + (cb[0] - ca[0]) * f,
                    ca[1] + (cb[1] - ca[1]) * f,
                    ca[2] + (cb[2] - ca[2]) * f,
                ],
                oa + (ob - oa) * f,
            );
        }
    }
    at(last)
}
