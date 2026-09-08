//! The layer-style plane renderer: the padded shape plane every effect is a
//! function of, the plane primitives (ONE blur, ONE dilate/erode, shift,
//! multiply) and the per-effect dispatch. The gradient math is
//! `style_gradient`; the rendered-plane cache that lives inside each
//! `Arc<LayerStyle>` is `style_cache`.
//!
//! # The plane model
//!
//! Effects are functions of the layer's SHAPE — its straight alpha times its
//! enabled mask, `coverage = round(alpha * mask / 255)` (the arithmetic of
//! `remove_mask(apply: true)`) — on a plane padded by `pad` on every side.
//! A [`Shape`] carries the plane's size, its coverage bytes and its
//! `origin`: the LAYER coordinate of plane pixel `(0, 0)`, so plane pixel
//! `p` is layer pixel `p + origin` and canvas pixel `offset + p + origin`.
//! A full plane has `origin = (-pad, -pad)` and size `lw + 2 pad` by
//! `lh + 2 pad`, with 0 coverage in the padding. Planes are LAYER-local, so
//! a Move drag, an opacity scrub and Duplicate Layer all reuse them. `pad`
//! is `LayerStyle::pad()`: each enabled effect's reach plus one, so a plane
//! never reads or writes beyond its border and a shape padded by `reach`
//! renders exactly as it would on an infinite plane. A plane over
//! `MAX_PIXELS` is refused (`Shape::of_layer` is `None`) and the style
//! renders no effects — a documented refusal, never a panic.
//!
//! The same locality is what makes a SUB-PLANE exact: [`Shape::sub`] cuts a
//! window out of a full plane (its `origin` moves with it, its `bounds`
//! stay the full shape's), and every effect rendered over the sub-plane
//! equals the full render wherever the window's border is at least the
//! effect's reach away — the cache's incremental re-render for a brush
//! stroke (`style_cache`) relies on it, so no renderer may read anything
//! global about the plane beyond `bounds` and `lw`/`lh`.
//!
//! `bounds` is the bounding box of the layer's non-transparent pixels
//! (alpha > 0), in layer coordinates: what "Align with Layer" spans a
//! gradient across. Photoshop ignores transparent pixels for that box, and
//! a new, shape-tool or brush-painted layer is a canvas-sized buffer whose
//! content is much smaller — the buffer rect would spread the gradient
//! over the whole canvas. The enabled mask, though part of the shape, is
//! left out of the box on purpose: masking away part of a gradient-filled
//! shape must not make the gradient jump to re-span what remains.
//!
//! A [`Contribution`] is what one effect emits: a coverage plane the size of
//! the shape, a colour, a blend mode, an opacity, a placement (Below the
//! pixels or Interior, above them), an integer shift applied at composite
//! time, a knock-out flag, and which [`Part`] of its effect it is (the
//! bevel's highlight or shadow; `Main` for every other effect) — the tag
//! `style_reuse` re-stamps by. The colour is one solid RGB or a
//! [`PlaneColor::Gradient`] evaluated per pixel AT COMPOSITE TIME from the
//! pixel's layer coordinate — a gradient is a closed-form function of
//! position and a few stops, and storing it per pixel would pin 12 bytes
//! per plane pixel in every cache entry (a 20 MP layer, a quarter gigabyte
//! per entry). Every Interior contribution's coverage is bounded by the
//! shape (its renderer multiplies by `shape.coverage`), which is what lets
//! `style_composite` draw it straight onto the accumulator.
//!
//! # Numeric conventions (Photoshop's; one home each)
//!
//! - `sigma_for_size(size) = size / 2`: Photoshop's "size" is the visible
//!   extent of the soft edge; a Gaussian at sigma = size/2 has faded to
//!   ~5 % two sigmas out, i.e. at `size`, which matches the dialog's look
//!   closely enough that no user has a reference to compare against.
//! - `feather_radius(sigma)` inverts `doc_select::feather_mask`'s
//!   `sigma = 0.3 (r - 1) + 0.8`, floored at 0.5 so any positive size still
//!   gets the 3-tap minimum kernel. `size == 0` means no blur (hard edge).
//! - `blur_plane` routes every plane through `feather_mask` (the master
//!   Gaussian; `ops::blur` blurs four channels assuming premultiplied
//!   input and is the wrong tool). `feather_mask` is O(pixels x taps), so a
//!   50 px shadow (sigma 25, ~330 taps per pass) on a 20 MP layer would take
//!   seconds. Above sigma 3 the plane is therefore blurred at a reduced
//!   resolution — `downsample_factor`: 2x above sigma 3, 4x above 6, 8x
//!   above 12 (each step where the reduced-resolution sigma is 1.5, so the
//!   kernel never exceeds ~13 taps and the cost is flat in sigma) — with a
//!   Triangle resample down and back up, which is invisible at those
//!   softnesses. The two resamples blur a little themselves (a triangle of
//!   half-width `f` has variance `f² / 6`; twice that for the round trip),
//!   so `reduced_sigma` subtracts `f² / 3` from the variance before
//!   dividing by `f`: the total softness stays continuous across a step,
//!   and a size slider crossing 6, 12 or 24 px shows no jump. The plane is
//!   zero-extended to a multiple of `f` before the resample so the sampling
//!   lattice is a fixed function of plane coordinates (an exact ratio, the
//!   same weights everywhere) — what keeps a sub-plane whose origin sits on
//!   the [`SUB_PLANE_ALIGN`] lattice bit-identical to the full plane.
//! - `blur_reach(sigma)` is how far the blur reads or writes from any
//!   pixel: the kernel half-width `feather_mask` builds (`taps =
//!   nearest_odd(2r + 1)`, so at most `ceil(r)`) plus 1 for the odd
//!   rounding; at a reduced resolution that half-width plus the two
//!   resamples' support (a Triangle down-sample reads `[-f/2, 3f/2)` around
//!   its cell, the up-sample the neighbouring reduced pixel on each side —
//!   together two reduced pixels), all scaled back by `f`:
//!   `f * (ceil(r_f) + 1 + 2)`. It is the ONE definition `LayerStyle::pad()`
//!   and every effect use — what makes a plane's padding exact.
//! - `dilate_plane` / `erode_plane` are `grow_mask` / `shrink_mask`: they
//!   binarize at >= 128 and re-anti-alias with a ~1 px ramp — right for
//!   spread/choke/stroke, never run for size-only effects.

use image::imageops::{self, FilterType};
use image::GrayImage;

use crate::blend::BlendMode;
use crate::doc::{Layer, MAX_PIXELS};
use crate::doc_select::{feather_mask, grow_mask, shrink_mask};
use crate::icc_transform::Transform;
use crate::style::{Effect, EffectKind, GlobalLight, LayerStyle};
use crate::style_gradient::{gradient_color, GradientSampler};
use crate::{
    style_fx_bevel_emboss, style_fx_color_overlay, style_fx_drop_shadow, style_fx_gradient_overlay,
    style_fx_inner_glow, style_fx_inner_shadow, style_fx_outer_glow, style_fx_satin,
    style_fx_stroke,
};

// ------------------------------------------------------------------ shape --

/// The padded coverage plane an effect stack renders from (module doc).
#[derive(Clone)]
pub(crate) struct Shape {
    pub lw: u32,
    pub lh: u32,
    pub w: u32,
    pub h: u32,
    /// Layer coordinate of plane pixel (0, 0): `(-pad, -pad)` for a full
    /// plane, further in for a sub-plane.
    pub origin: (i64, i64),
    pub coverage: Vec<u8>,
    /// Bounding box `(x0, y0, x1, y1)` (exclusive) of the FULL layer's
    /// non-transparent pixels in layer coordinates, the mask left out
    /// (module doc); `None` when there are none.
    pub bounds: Option<(i64, i64, i64, i64)>,
}

impl Shape {
    /// The shape of `layer` on a plane padded by `pad`; `None` when the
    /// plane would exceed `MAX_PIXELS`.
    pub(crate) fn of_layer(layer: &Layer, pad: u32) -> Option<Shape> {
        let (lw, lh) = layer.pixels.dimensions();
        let w = u64::from(lw) + 2 * u64::from(pad);
        let h = u64::from(lh) + 2 * u64::from(pad);
        if w * h > MAX_PIXELS || w > u64::from(u32::MAX) || h > u64::from(u32::MAX) {
            return None;
        }
        let (w, h) = (w as u32, h as u32);
        let mut coverage = vec![0u8; w as usize * h as usize];
        let raw = layer.pixels.as_raw();
        let mask = layer.active_mask().map(|m| m.as_raw().as_slice());
        let (mut bx0, mut by0, mut bx1, mut by1) = (i64::from(lw), i64::from(lh), 0i64, 0i64);
        for y in 0..lh {
            let row = (y + pad) as usize * w as usize + pad as usize;
            let mut row_min = lw;
            let mut row_max = 0;
            for x in 0..lw {
                let li = (y as usize * lw as usize + x as usize) * 4;
                let alpha = raw[li + 3];
                let c = match mask {
                    None => alpha,
                    Some(m) => (f32::from(alpha) * f32::from(m[li / 4]) / 255.0).round() as u8,
                };
                coverage[row + x as usize] = c;
                if alpha != 0 {
                    row_min = row_min.min(x);
                    row_max = x;
                }
            }
            if row_min < lw {
                bx0 = bx0.min(i64::from(row_min));
                bx1 = bx1.max(i64::from(row_max) + 1);
                by0 = by0.min(i64::from(y));
                by1 = i64::from(y) + 1;
            }
        }
        let bounds = (bx1 > bx0).then_some((bx0, by0, bx1, by1));
        Some(Shape {
            lw,
            lh,
            w,
            h,
            origin: (-i64::from(pad), -i64::from(pad)),
            coverage,
            bounds,
        })
    }

    /// Row-major index of plane pixel (x, y).
    pub(crate) fn idx(&self, x: u32, y: u32) -> usize {
        y as usize * self.w as usize + x as usize
    }

    /// Coverage at plane pixel (x, y); 0 outside the plane.
    pub(crate) fn at(&self, x: i64, y: i64) -> u8 {
        if x < 0 || y < 0 || x >= i64::from(self.w) || y >= i64::from(self.h) {
            return 0;
        }
        self.coverage[self.idx(x as u32, y as u32)]
    }

    /// `255 - coverage`: the layer's transparency. Also the ONE knock-out
    /// of every exterior effect (outer glow, the outside stroke band): a
    /// plane multiplied by it holds at most `1 - alpha` of the effect under
    /// a partial pixel — the same proportion the drop shadow's
    /// composite-time knock-out (`knocked_out_by_shape`) leaves — so a
    /// semi-transparent layer never has its interior filled with glow or
    /// stroke colour, and an anti-aliased edge fades the effect out
    /// smoothly rather than at a hard threshold.
    pub(crate) fn inverted(&self) -> Vec<u8> {
        self.coverage.iter().map(|&v| 255 - v).collect()
    }

    /// The layer rect in plane coordinates, `(x0, y0, x1, y1)` exclusive,
    /// clipped to the plane: the full layer rect on a full plane, the
    /// window's part of it on a sub-plane.
    pub(crate) fn layer_rect(&self) -> (u32, u32, u32, u32) {
        let clamp = |v: i64, hi: u32| v.clamp(0, i64::from(hi)) as u32;
        (
            clamp(-self.origin.0, self.w),
            clamp(-self.origin.1, self.h),
            clamp(i64::from(self.lw) - self.origin.0, self.w),
            clamp(i64::from(self.lh) - self.origin.1, self.h),
        )
    }

    /// The window `(x0, y0, x1, y1)` (plane coordinates, exclusive, inside
    /// the plane) of this shape as a shape of its own: the coverage bytes
    /// of the window, the origin moved by its corner, `bounds` and the
    /// layer size unchanged (module doc).
    pub(crate) fn sub(&self, x0: u32, y0: u32, x1: u32, y1: u32) -> Shape {
        let (w, h) = (x1.saturating_sub(x0), y1.saturating_sub(y0));
        let mut coverage = Vec::with_capacity(w as usize * h as usize);
        for y in y0..y0 + h {
            let row = self.idx(x0, y);
            coverage.extend_from_slice(&self.coverage[row..row + w as usize]);
        }
        Shape {
            lw: self.lw,
            lh: self.lh,
            w,
            h,
            origin: (self.origin.0 + i64::from(x0), self.origin.1 + i64::from(y0)),
            coverage,
            bounds: self.bounds,
        }
    }

    /// The bounding box `(x0, y0, x1, y1)` (plane coordinates, exclusive)
    /// of the pixels whose coverage differs between two planes of the same
    /// size; `None` when they are identical (or differently sized).
    pub(crate) fn diff_bounds(&self, other: &Shape) -> Option<(u32, u32, u32, u32)> {
        if self.w != other.w || self.h != other.h || self.coverage.len() != other.coverage.len() {
            return None;
        }
        let w = self.w as usize;
        let (mut x0, mut y0, mut x1, mut y1) = (w, self.h as usize, 0usize, 0usize);
        for y in 0..self.h as usize {
            let a = &self.coverage[y * w..(y + 1) * w];
            let b = &other.coverage[y * w..(y + 1) * w];
            if a == b {
                continue;
            }
            let first = a.iter().zip(b).position(|(p, q)| p != q).unwrap_or(0);
            let last = a.iter().zip(b).rposition(|(p, q)| p != q).unwrap_or(w - 1);
            x0 = x0.min(first);
            x1 = x1.max(last + 1);
            y0 = y0.min(y);
            y1 = y + 1;
        }
        (x1 > x0).then_some((x0 as u32, y0 as u32, x1 as u32, y1 as u32))
    }
}

// ---------------------------------------------------------- contributions --

/// Straight RGB in 0..1: one colour for the whole plane, or a gradient
/// evaluated per pixel at composite time (module doc), sampled at the
/// pixel's centre in LAYER coordinates.
#[derive(Clone)]
pub(crate) enum PlaneColor {
    Solid([f32; 3]),
    Gradient(GradientSampler),
}

impl PlaneColor {
    /// This colour converted through `t` — the AUTHORED sRGB colour a style
    /// stores turned into the document's own numbers, once, at composite
    /// time (`style_composite::composite_contribution`, the one place a
    /// contribution's colour is read).
    ///
    /// Deliberately NOT applied when the plane is rendered: the cache holds
    /// the colours the user authored, so an Assign or Convert to Profile
    /// leaves every cached plane valid and a style's APPEARANCE survives a
    /// profile change without the style JSON being rewritten.
    ///
    /// A `Solid` came from [`unit_color`], so `* 255` recovers the authored
    /// byte exactly.
    pub(crate) fn converted(&self, t: &Transform) -> PlaneColor {
        match self {
            PlaneColor::Solid(rgb) => {
                let byte = |v: f32| (v * 255.0).round().clamp(0.0, 255.0) as u8;
                PlaneColor::Solid(unit_color(t.color([
                    byte(rgb[0]),
                    byte(rgb[1]),
                    byte(rgb[2]),
                ])))
            }
            PlaneColor::Gradient(sampler) => {
                PlaneColor::Gradient(sampler.mapping_colors(|c| t.color(c)))
            }
        }
    }

    /// The colour at layer pixel `(lx, ly)`.
    pub(crate) fn at(&self, lx: i64, ly: i64) -> [f32; 3] {
        match self {
            PlaneColor::Solid(rgb) => *rgb,
            PlaneColor::Gradient(sampler) => {
                gradient_color(&sampler.fill, sampler.t(lx as f32 + 0.5, ly as f32 + 0.5)).0
            }
        }
    }
}

/// Where a contribution composites relative to the layer's pixels.
#[derive(Clone, Copy, PartialEq, Eq)]
pub(crate) enum Placement {
    Below,
    Interior,
}

/// Which of its effect's parts a contribution is: `Main` for every effect
/// that colours all of its planes alike, `Highlight` / `Shadow` for the
/// bevel's two lit sides, which carry their own colour, blend and opacity.
/// What tells them apart when a cached plane is re-stamped with a new
/// style's colours (`style_reuse`) — the planes alone cannot (a bevel
/// whose highlight faces nowhere emits its shadow only).
#[derive(Clone, Copy, PartialEq, Eq)]
pub(crate) enum Part {
    Main,
    Highlight,
    Shadow,
}

/// What one effect emits (module doc).
#[derive(Clone)]
pub(crate) struct Contribution {
    pub kind: EffectKind,
    pub part: Part,
    pub coverage: Vec<u8>,
    pub color: PlaneColor,
    pub blend: BlendMode,
    pub opacity: f32,
    pub placement: Placement,
    /// Integer canvas shift applied at composite time (Below only).
    pub shift: (i32, i32),
    /// Multiply the coverage by `1 - shape` at the landing position
    /// (Photoshop's "Layer Knocks Out Drop Shadow").
    pub knocked_out_by_shape: bool,
}

impl Contribution {
    /// A solid-colour, unshifted, non-knocked-out `Main` contribution.
    pub(crate) fn solid(
        kind: EffectKind,
        coverage: Vec<u8>,
        color: [u8; 3],
        blend: BlendMode,
        opacity: f32,
        placement: Placement,
    ) -> Self {
        Contribution {
            kind,
            part: Part::Main,
            coverage,
            color: PlaneColor::Solid(unit_color(color)),
            blend,
            opacity,
            placement,
            shift: (0, 0),
            knocked_out_by_shape: false,
        }
    }

    /// Whether two contributions are the same slot of the same style — the
    /// per-pixel planes aside: the same effect, part, placement, shift and
    /// knock-out (blend, opacity and colour follow from the style).
    pub(crate) fn same_slot(&self, other: &Contribution) -> bool {
        self.kind == other.kind
            && self.part == other.part
            && self.placement == other.placement
            && self.shift == other.shift
            && self.knocked_out_by_shape == other.knocked_out_by_shape
    }
}

/// `[u8; 3]` to straight 0..1.
pub(crate) fn unit_color(color: [u8; 3]) -> [f32; 3] {
    [
        f32::from(color[0]) / 255.0,
        f32::from(color[1]) / 255.0,
        f32::from(color[2]) / 255.0,
    ]
}

/// What a render depends on beyond the shape and the style: the global
/// light, and — for canvas-aligned gradients — the DOCUMENT canvas size and
/// the layer's offset on it (never the projection window: Merge Down
/// composites into the union of two layers, and a canvas-aligned gradient
/// must bake exactly as the projection showed it).
#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) struct RenderContext {
    pub light: GlobalLight,
    pub canvas: (u32, u32),
    pub layer_offset: (i32, i32),
}

/// The rendered planes of one style over one shape; both lists sorted by
/// render rank.
pub(crate) struct RenderedEffects {
    pub shape: Shape,
    pub below: Vec<Contribution>,
    pub interior: Vec<Contribution>,
}

/// Render rank within a placement (Photoshop's dialog order read bottom-up;
/// interior effects use their own blend modes — "Blend Interior Effects as
/// Group" is off).
fn rank(kind: EffectKind, placement: Placement) -> u8 {
    match placement {
        Placement::Below => match kind {
            EffectKind::DropShadow => 0,
            EffectKind::OuterGlow => 1,
            EffectKind::Stroke => 2,
            EffectKind::BevelEmboss => 3,
            _ => 4,
        },
        Placement::Interior => match kind {
            EffectKind::GradientOverlay => 0,
            EffectKind::ColorOverlay => 1,
            EffectKind::Satin => 2,
            EffectKind::InnerGlow => 3,
            EffectKind::InnerShadow => 4,
            EffectKind::Stroke => 5,
            EffectKind::BevelEmboss => 6,
            _ => 7,
        },
    }
}

/// Renders every enabled effect of `style` over `shape` and partitions the
/// contributions by placement in render order.
pub(crate) fn render_effects(
    style: &LayerStyle,
    shape: Shape,
    ctx: &RenderContext,
) -> RenderedEffects {
    let mut all = Vec::new();
    for effect in style.enabled_effects() {
        all.extend(render_effect(effect, &shape, ctx));
    }
    let (below, interior) = ranked(all);
    RenderedEffects {
        shape,
        below,
        interior,
    }
}

/// The one dispatch to an effect's renderer: `effect`'s contributions
/// over `shape` (any number, any placement, unsorted).
pub(crate) fn render_effect(
    effect: &Effect,
    shape: &Shape,
    ctx: &RenderContext,
) -> Vec<Contribution> {
    match effect {
        Effect::DropShadow(fx) => style_fx_drop_shadow::render(fx, shape, ctx),
        Effect::InnerShadow(fx) => style_fx_inner_shadow::render(fx, shape, ctx),
        Effect::OuterGlow(fx) => style_fx_outer_glow::render(fx, shape, ctx),
        Effect::InnerGlow(fx) => style_fx_inner_glow::render(fx, shape, ctx),
        Effect::Stroke(fx) => style_fx_stroke::render(fx, shape, ctx),
        Effect::ColorOverlay(fx) => style_fx_color_overlay::render(fx, shape, ctx),
        Effect::GradientOverlay(fx) => style_fx_gradient_overlay::render(fx, shape, ctx),
        Effect::BevelEmboss(fx) => style_fx_bevel_emboss::render(fx, shape, ctx),
        Effect::Satin(fx) => style_fx_satin::render(fx, shape, ctx),
    }
}

/// Partitions contributions by placement, each list in render order
/// (a stable sort, so an effect's own emission order survives within its
/// rank).
pub(crate) fn ranked(all: Vec<Contribution>) -> (Vec<Contribution>, Vec<Contribution>) {
    let (mut below, mut interior): (Vec<Contribution>, Vec<Contribution>) = all
        .into_iter()
        .partition(|c| c.placement == Placement::Below);
    below.sort_by_key(|c| rank(c.kind, Placement::Below));
    interior.sort_by_key(|c| rank(c.kind, Placement::Interior));
    (below, interior)
}

// ------------------------------------------------------------- numerics --

/// Gaussian sigma for a Photoshop "size" in px (module doc).
pub(crate) fn sigma_for_size(size_px: f32) -> f32 {
    if size_px.is_finite() {
        (size_px / 2.0).max(0.0)
    } else {
        0.0
    }
}

/// The `feather_mask` radius that yields `sigma` (inverse of
/// `sigma = 0.3 (r - 1) + 0.8`), floored at 0.5 so any positive sigma still
/// blurs with the 3-tap minimum kernel.
pub(crate) fn feather_radius(sigma: f32) -> f32 {
    ((sigma - 0.8) / 0.3 + 1.0).max(0.5)
}

/// The lattice a sub-plane's origin must sit on for `blur_plane` to be
/// bit-identical between the sub-plane and the full plane (module doc):
/// the largest `downsample_factor`.
pub(crate) const SUB_PLANE_ALIGN: u32 = 8;

/// The resolution reduction `blur_plane` works at for `sigma` (module
/// doc): 1 (direct) up to sigma 3, then 2, 4 and 8 at each doubling.
pub(crate) fn downsample_factor(sigma: f32) -> u32 {
    if sigma.is_nan() || sigma <= 3.0 {
        1
    } else if sigma <= 6.0 {
        2
    } else if sigma <= 12.0 {
        4
    } else {
        8
    }
}

/// The sigma blurred at 1/`f` resolution so that, with the two Triangle
/// resamples' own softening (`f² / 3` of variance), the result matches
/// `sigma` at full resolution (module doc). `pub(crate)` for
/// `adjust_tone::tone_plane`, which reduces a plane itself rather than
/// letting `blur_plane` do it, so that the crate keeps ONE such rule.
pub(crate) fn reduced_sigma(sigma: f32, f: u32) -> f32 {
    let f = f as f32;
    (sigma * sigma - f * f / 3.0).max(0.0).sqrt() / f
}

/// How far, in px, `blur_plane` at `sigma` reads or writes from any pixel
/// (module doc). 0 for no blur.
pub(crate) fn blur_reach(sigma: f32) -> u32 {
    if sigma.is_nan() || sigma <= 0.0 {
        return 0;
    }
    let f = downsample_factor(sigma);
    if f == 1 {
        feather_radius(sigma).ceil() as u32 + 1
    } else {
        f * (feather_radius(reduced_sigma(sigma, f)).ceil() as u32 + 1 + 2)
    }
}

/// Splits a size and its spread/choke fraction into `(dilate_px, sigma)`:
/// dilate by `size * spread`, then blur by `size * (1 - spread)`.
pub(crate) fn spread_split(size: f32, spread: f32) -> (f32, f32) {
    let size = if size.is_finite() { size.max(0.0) } else { 0.0 };
    let spread = if spread.is_finite() {
        spread.clamp(0.0, 1.0)
    } else {
        0.0
    };
    (size * spread, sigma_for_size(size * (1.0 - spread)))
}

/// The integer offset a shadow at `angle_deg` and `distance` lands at:
/// `(round(-d cos a), round(+d sin a))` in y-down pixel space, so 120°
/// (Photoshop's default light, upper-left) casts down-right. Rounded to
/// whole pixels — planes are shifted, never resampled. The products are
/// snapped to a millionth before rounding: the trig identities produce
/// exact halves (`cos 120° = -1/2`, so distance 3 at 120° is 1.5 px) that
/// `f64::cos` returns a few ulps off, and without the snap the same style
/// could land a pixel apart between platforms.
pub(crate) fn light_offset(angle_deg: f32, distance: f32) -> (i32, i32) {
    if !angle_deg.is_finite() || !distance.is_finite() {
        return (0, 0);
    }
    let a = f64::from(angle_deg).to_radians();
    let d = f64::from(distance);
    let snap = |v: f64| {
        let snapped = (v * 1e6).round() / 1e6;
        snapped
            .round()
            .clamp(f64::from(i32::MIN), f64::from(i32::MAX)) as i32
    };
    (snap(-d * a.cos()), snap(d * a.sin()))
}

/// THE plane blur (module doc): `sigma <= 0` is a no-op; up to sigma 3 a
/// direct `feather_mask`; above it the plane is zero-extended to a multiple
/// of the `downsample_factor`, resampled down, blurred at `reduced_sigma`,
/// and resampled back.
pub(crate) fn blur_plane(plane: &mut [u8], w: u32, h: u32, sigma: f32) {
    if sigma.is_nan() || sigma <= 0.0 || w == 0 || h == 0 || plane.len() != w as usize * h as usize
    {
        return;
    }
    let f = downsample_factor(sigma);
    if f == 1 {
        feather_mask(plane, w, h, feather_radius(sigma));
        return;
    }
    let we = w.div_ceil(f) * f;
    let he = h.div_ceil(f) * f;
    let mut extended = vec![0u8; we as usize * he as usize];
    for y in 0..h as usize {
        extended[y * we as usize..y * we as usize + w as usize]
            .copy_from_slice(&plane[y * w as usize..(y + 1) * w as usize]);
    }
    let Some(full) = GrayImage::from_raw(we, he, extended) else {
        return;
    };
    let (rw, rh) = (we / f, he / f);
    let mut reduced = imageops::resize(&full, rw, rh, FilterType::Triangle);
    feather_mask(
        reduced.as_mut(),
        rw,
        rh,
        feather_radius(reduced_sigma(sigma, f)),
    );
    let back = imageops::resize(&reduced, we, he, FilterType::Triangle);
    let raw = back.as_raw();
    for y in 0..h as usize {
        plane[y * w as usize..(y + 1) * w as usize]
            .copy_from_slice(&raw[y * we as usize..y * we as usize + w as usize]);
    }
}

/// Dilates a plane by `px` (`grow_mask`; no-op at `px <= 0`).
pub(crate) fn dilate_plane(plane: &mut [u8], w: u32, h: u32, px: f32) {
    grow_mask(plane, w, h, px);
}

/// Erodes a plane by `px` (`shrink_mask`; no-op at `px <= 0`).
pub(crate) fn erode_plane(plane: &mut [u8], w: u32, h: u32, px: f32) {
    shrink_mask(plane, w, h, px);
}

/// `out(x, y) = plane(x - dx, y - dy)`, `fill` where that falls outside.
pub(crate) fn shift_plane(plane: &[u8], w: u32, h: u32, dx: i32, dy: i32, fill: u8) -> Vec<u8> {
    let (wi, hi) = (i64::from(w), i64::from(h));
    let mut out = vec![fill; plane.len()];
    if plane.len() != w as usize * h as usize {
        return out;
    }
    for y in 0..hi {
        let sy = y - i64::from(dy);
        if sy < 0 || sy >= hi {
            continue;
        }
        for x in 0..wi {
            let sx = x - i64::from(dx);
            if sx < 0 || sx >= wi {
                continue;
            }
            out[(y * wi + x) as usize] = plane[(sy * wi + sx) as usize];
        }
    }
    out
}

/// `a = round(a * b / 255)` per pixel (integer form; 255 is odd, so no
/// product of two bytes lands on a .5 tie).
pub(crate) fn multiply_planes(a: &mut [u8], b: &[u8]) {
    for (x, &y) in a.iter_mut().zip(b) {
        *x = ((u32::from(*x) * u32::from(y) + 127) / 255) as u8;
    }
}

/// `a = a.saturating_sub(b)` per pixel.
pub(crate) fn subtract_planes(a: &mut [u8], b: &[u8]) {
    for (x, &y) in a.iter_mut().zip(b) {
        *x = x.saturating_sub(y);
    }
}

/// `a = 255 - a` per pixel.
pub(crate) fn invert_plane(a: &mut [u8]) {
    for x in a.iter_mut() {
        *x = 255 - *x;
    }
}
