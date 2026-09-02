//! Satin (Photoshop Layer Style > Satin): the sheen of folded fabric. Two
//! copies of the shape, blurred by `size`, are pushed apart along `angle`
//! by `distance` — one copy each way — and combined where exactly ONE of
//! them covers a pixel; `invert` takes the complement. The result is
//! clipped to the shape and composited above the pixels with the effect's
//! own blend mode (Multiply by default) and opacity (0.5), as one Interior
//! contribution.
//!
//! # The algorithm
//!
//! `p = blur_plane(coverage, sigma_for_size(size))`;
//! `(dx, dy) = light_offset(angle, distance)`;
//! `a = shift_plane(p, dx, dy, 0)`, `b = shift_plane(p, -dx, -dy, 0)`;
//! per pixel `s = a + b - 2ab` with `a`, `b` in 0..1; `invert` → `1 - s`;
//! then `s * coverage`. Every plane primitive is `style_render`'s — the
//! ONE blur and the ONE shift — so this module holds no pixel math of its
//! own beyond the soft XOR.
//!
//! # Why these numbers
//!
//! - **Soft XOR `a + b - 2ab`.** Photoshop combines the two offset copies
//!   with an exclusive-or-like difference: where both copies cover, or
//!   neither does, there is no sheen. `a + b - 2ab` is the continuous
//!   extension of XOR (it equals XOR at every corner of the unit square,
//!   is symmetric in `a` and `b`, and is smooth everywhere). The other
//!   candidate, `|a - b|`, also agrees with XOR at the corners but has a
//!   crease at `a == b` — on a blurred satin that crease runs right down
//!   the middle of the pattern as a visible seam, so the product form is
//!   what ships.
//! - **Integer form.** With `a`, `b` in 0..=255 the soft XOR is
//!   `((a + b) * 255 - 2ab + 127) / 255`, one rounding, exact otherwise.
//!   The numerator is never negative (`a (255 - b) + b (255 - a) >= 0`)
//!   and never exceeds `255 * 255` (`255² - 255 (a + b) + 2ab =
//!   (255 - a)(255 - b) + ab >= 0`), so the quotient is a byte.
//! - **Symmetric shift.** The copies sit at `+(dx, dy)` and `-(dx, dy)`, so
//!   the pattern stays centred on the shape and an angle flipped by 180°
//!   renders identically — which copy gets which sign is immaterial since
//!   the symmetric difference is symmetric. The shifted-in region is
//!   filled with 0 (outside the layer is transparent); `LayerStyle::pad`
//!   reserves `blur_reach(sigma) + ceil(distance)` around the shape, so a
//!   shift by at most `distance` only ever reads real zeros and the plane
//!   renders exactly as it would on an infinite canvas.
//! - **Distance 0.** `a == b`, so `s = 2a (1 - a)`: nothing on a hard
//!   shape, a faint ridge along a blurred edge — Photoshop shows the same
//!   at distance 0; with `invert` the whole shape is painted.
//! - **No global light.** Photoshop's Satin pane has no "Use Global Light"
//!   checkbox; `angle` is always the effect's own, so the render context
//!   is not read.
//!
//! Contour and anti-aliasing toggles are not in this phase.

use crate::style::{EffectKind, Satin};
use crate::style_render::{
    blur_plane, invert_plane, light_offset, multiply_planes, shift_plane, sigma_for_size,
    Contribution, Placement, RenderContext, Shape,
};

/// Renders `fx` over `shape`: one Interior contribution whose coverage is
/// the (optionally inverted) soft XOR of the two offset copies of the
/// blurred shape, bounded by `shape.coverage` (the Interior rule). Nothing
/// at opacity 0. The context is unused — Satin has no global-light option.
pub(crate) fn render(fx: &Satin, shape: &Shape, _ctx: &RenderContext) -> Vec<Contribution> {
    if fx.opacity.is_nan() || fx.opacity <= 0.0 {
        return Vec::new();
    }
    let mut soft = shape.coverage.clone();
    blur_plane(&mut soft, shape.w, shape.h, sigma_for_size(fx.size));
    let (dx, dy) = light_offset(fx.angle, fx.distance);
    let a = shift_plane(&soft, shape.w, shape.h, dx, dy, 0);
    // `saturating_neg`: `light_offset` clamps to the i32 range, and
    // `-i32::MIN` would overflow for a directly constructed absurd distance.
    let b = shift_plane(
        &soft,
        shape.w,
        shape.h,
        dx.saturating_neg(),
        dy.saturating_neg(),
        0,
    );
    let mut plane: Vec<u8> = a.iter().zip(&b).map(|(&a, &b)| soft_xor(a, b)).collect();
    if fx.invert {
        invert_plane(&mut plane);
    }
    multiply_planes(&mut plane, &shape.coverage);
    vec![Contribution::solid(
        EffectKind::Satin,
        plane,
        fx.color,
        fx.blend,
        fx.opacity,
        Placement::Interior,
    )]
}

/// `round(255 (a + b - 2ab))` for coverage bytes `a`, `b` — the soft XOR
/// of the module doc in its exact integer form.
fn soft_xor(a: u8, b: u8) -> u8 {
    let (a, b) = (u32::from(a), u32::from(b));
    (((a + b) * 255 - 2 * a * b + 127) / 255) as u8
}
