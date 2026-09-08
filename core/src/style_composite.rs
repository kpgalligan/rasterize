//! The styled-layer compositing path: how a layer with a style meets the
//! accumulator. The plain path in `doc::composite_layer_into` is never
//! touched for unstyled layers; a styled layer (or a styled clip BASE) is
//! routed here and assembled in Photoshop's order:
//!
//! 1. If the style has a Blend If, the accumulator is snapshotted BEFORE
//!    anything of this layer is drawn — Photoshop's "Underlying Layer" is
//!    the composite beneath the layer, and the layer's own shadow is not
//!    underlying. Only where a Below contribution can land inside the
//!    layer rect, though: everywhere else the accumulator still holds the
//!    underlying composite when the pixel pass reads it, so a Blend If
//!    with no Below effect — the common case, a plain styled layer — takes
//!    no snapshot at all rather than copying 16 bytes per layer pixel on
//!    every composite (320 MB per frame for a canvas-sized 20 MP layer).
//!    A styled clip BASE draws its pixels into a private buffer, not the
//!    accumulator, so it snapshots its whole layer rect (the buffer is
//!    already an accumulator-sized allocation; the snapshot is not the
//!    cost there).
//! 2. The Below group (drop shadow, outer glow, outside stroke, outer bevel
//!    halves) composites straight onto the accumulator, each contribution
//!    with its OWN blend mode and `sa = coverage x effect opacity` — never
//!    the layer's blend mode.
//! 3. The interior unit. A plain styled layer draws its pixels through the
//!    ordinary per-pixel loop with `sa = alpha x mask x fill_opacity x
//!    blend-if weight` and the LAYER's blend mode — no accumulator-sized
//!    buffer is allocated, so a fill-only or blend-if-only style costs the
//!    plain path plus two multiplies per pixel. A styled clip BASE (clipped
//!    members present) instead renders its pixels at Normal / opacity 1
//!    into a private accumulator-aligned buffer — the SAME full-window
//!    allocation the unstyled clip group makes today, a pre-existing cost —
//!    then each visible member through `composite_layer_into`, clamping the
//!    buffer's alpha to the SHAPE after each one (the footprint is the shape
//!    at fill 1, so a base at 0 % fill still confines its members), and
//!    finally composites the buffer with the layer's blend mode through
//!    `blend::composite_buffer_into`.
//! 4. The Interior group (gradient overlay, colour overlay, satin, inner
//!    glow, inner shadow, inside/centre stroke, inner bevel) composites
//!    straight onto the accumulator, each with its own blend mode — "Blend
//!    Interior Effects as Group" is OFF, Photoshop's default, so a Multiply
//!    text layer with a white colour overlay shows white. (The follow-up key
//!    `blend_interior_as_group` would route them through the clip-base
//!    buffer instead.) Every interior contribution is already bounded by the
//!    shape, which is what makes this correct without a buffer.
//!
//! Fill opacity therefore never touches effects: a text layer at 0 % fill
//! with a stroke and a drop shadow is outlined text.
//!
//! # Layer opacity: the package
//!
//! Photoshop applies the LAYER opacity once, to the finished package of
//! pixels and effects, not to each piece: a colour overlay at opacity 1 on
//! a layer at 50 % shows pure overlay colour at 50 %, never a tint of the
//! pixels under it. So at opacity < 1 the four steps above run at opacity 1
//! against a COPY of the accumulator's affected window, and the result is
//! mixed back in premultiplied space, `acc = acc + (packaged - acc) x
//! opacity` for colour x alpha and for alpha — which is exactly the W3C
//! formula for one source at `sa = alpha x opacity` (so a layer with no
//! effects composites the same bytes either way), and for several sources
//! the package model. The window is processed in strips of
//! `PACKAGE_STRIP_ROWS` rows so the copy stays small on a photo-sized
//! layer; every kernel here clips to its accumulator, so a strip is just a
//! smaller accumulator with a shifted origin (the Dissolve dither and the
//! Blend If snapshot both key on canvas coordinates, unaffected). Three
//! cases keep the direct per-contribution path: opacity 1 (nothing to mix),
//! a style that renders no planes (one source — identical result, no copy),
//! and a layer in Dissolve mode (its per-pixel coin toss on `sa` has no
//! package form).
//!
//! # The render context
//!
//! Effects are rendered against the DOCUMENT canvas (`CompositeEnv`: the
//! global light and the canvas size), never against the accumulator: Merge
//! Down composites into the union of two layer rects, and a canvas-aligned
//! gradient must bake exactly the pixels the projection showed.
//!
//! # A style's colours are AUTHORED, and convert here
//!
//! Every colour inside a style — an effect's `color`, a bevel's two lit
//! sides, a gradient's stops — is stored as the sRGB `#rrggbb` the user or
//! the agent authored, the same convention every colour argument this crate
//! is handed follows. It is converted into the DOCUMENT's colour space
//! exactly once, in [`composite_contribution`], which is the one place a
//! contribution's colour is read; `CompositeEnv::colors` carries the
//! conversion (absent when the document is already in that space, so an
//! sRGB document is byte-for-byte what it was before colour management).
//!
//! Converting HERE rather than when the plane is rendered is what keeps the
//! two properties that matter. The plane cache holds the AUTHORED colour, so
//! a document that changes profile — Assign, Convert to Profile, or an undo
//! of either — invalidates nothing and re-renders nothing; and the style
//! JSON is never rewritten, so `set_layer_style` stays idempotent, a `.rz`
//! round trip stays byte-identical, and Convert to Profile preserves a
//! style's APPEARANCE (its authored colour re-converts into the new space)
//! without touching a single stored value. A document whose profile this
//! crate cannot model keeps its authored numbers verbatim, which is exactly
//! what the host does when it paints into such a document.
//!
//! # Merge Down's extent
//!
//! `merge_extent` is the rect a baked layer needs: its pixel rect grown by
//! the style's pad on every side (where the in-plane effects can reach),
//! and, for an enabled drop shadow, that rect shifted by the shadow's
//! composite-time offset — in the shadow's direction only, never `distance`
//! on all four sides — and clipped to the canvas, because the shadow beyond
//! the canvas is never visible and a legal 30000 px distance would
//! otherwise grow a merge to tens of megapixels or refuse it outright.

use crate::blend::{blend_kind, composite_buffer_into, composite_source_into, BlendMode};
use crate::doc::{composite_layer_into, sane_opacity, Layer, RzDocument};
use crate::icc_transform::Transform;
use crate::style::{BlendIf, GlobalLight, LayerStyle};
use crate::style_blend_if::source_weight;
use crate::style_render::{Contribution, RenderContext, RenderedEffects, Shape};

/// What every composite reads beyond the layers: the global light every
/// "use global light" effect resolves against, the document canvas size
/// canvas-aligned gradients span, and the conversion an authored style
/// colour takes into the document's space (module doc).
///
/// `colors` is a BORROW so this stays `Copy` — a `Transform` is twelve
/// kilobytes of lookup tables, built once per projection by
/// `RzDocument::style_colors` and handed down.
#[derive(Clone, Copy)]
pub(crate) struct CompositeEnv<'a> {
    pub light: GlobalLight,
    pub canvas: (u32, u32),
    pub colors: Option<&'a Transform>,
}

impl RzDocument {
    /// The conversion every AUTHORED style colour takes into this document's
    /// space (module doc), or `None` when there is nothing to do: the
    /// document is already in sRGB — the overwhelmingly common case, and the
    /// one that must stay byte-for-byte what it was — or its profile is one
    /// this crate cannot model, where the honest answer is the numbers as
    /// authored, exactly as the host paints them.
    ///
    /// Owned by the caller and borrowed into [`CompositeEnv`], so one
    /// projection builds one transform however many styled layers it has.
    pub(crate) fn style_colors(&self) -> Option<Transform> {
        let srgb = crate::icc::IccProfile::srgb();
        Transform::between(srgb.model()?, self.profile.model()?)
    }

    /// The document's compositing environment.
    pub(crate) fn composite_env<'a>(&self, colors: Option<&'a Transform>) -> CompositeEnv<'a> {
        CompositeEnv {
            light: self.global_light,
            canvas: (self.width, self.height),
            colors,
        }
    }
}

/// Rows per strip of the package path (module doc): 256 rows of a
/// 5000 px wide window are 20 MB of f32 pixels, small enough to stay in
/// cache-friendly memory and large enough that the per-strip pass over the
/// planes is a small fraction of the work.
const PACKAGE_STRIP_ROWS: i64 = 256;

fn saturating_i32(v: i64) -> i32 {
    v.clamp(i64::from(i32::MIN), i64::from(i32::MAX)) as i32
}

/// The styled-layer path (module doc). `opacity` is the layer's, already
/// sanitized and > 0; `group` is the clipped run above a clip BASE (empty
/// for a plain styled layer).
#[allow(clippy::too_many_arguments)]
pub(crate) fn composite_styled_into(
    acc: &mut [[f32; 4]],
    acc_w: u32,
    acc_h: u32,
    origin: (i32, i32),
    layer: &Layer,
    group: &[Layer],
    style: &LayerStyle,
    opacity: f32,
    env: CompositeEnv<'_>,
) {
    let ctx = RenderContext {
        light: env.light,
        canvas: env.canvas,
        layer_offset: layer.offset,
    };
    let planes = if style.has_enabled_effects() {
        style.rendered(layer, &ctx)
    } else {
        None
    };
    match planes.as_deref() {
        Some(planes) if opacity < 1.0 && layer.blend != BlendMode::Dissolve => {
            composite_package_into(
                acc, acc_w, acc_h, origin, layer, group, style, opacity, env, planes,
            );
        }
        planes => composite_direct_into(
            acc, acc_w, acc_h, origin, layer, group, style, opacity, env, planes,
        ),
    }
}

/// The four steps of the module doc straight onto `acc`, every
/// contribution and the pixels scaled by `opacity`.
#[allow(clippy::too_many_arguments)]
fn composite_direct_into(
    acc: &mut [[f32; 4]],
    acc_w: u32,
    acc_h: u32,
    origin: (i32, i32),
    layer: &Layer,
    group: &[Layer],
    style: &LayerStyle,
    opacity: f32,
    env: CompositeEnv<'_>,
    planes: Option<&RenderedEffects>,
) {
    let rel = (
        saturating_i32(i64::from(layer.offset.0) - i64::from(origin.0)),
        saturating_i32(i64::from(layer.offset.1) - i64::from(origin.1)),
    );
    // Module doc, step 1: the snapshot covers only what the Below group
    // can overwrite inside the layer rect; a plain layer with nothing
    // Below reads the accumulator itself.
    let snapshot_rect = match (group.is_empty(), planes) {
        (true, None) => None,
        (true, Some(p)) => below_landing(rel, &p.shape, &p.below),
        (false, _) => Some((i64::MIN, i64::MIN, i64::MAX, i64::MAX)),
    };
    let backdrop = style.blend_if.filter(|b| !b.is_identity()).map(|b| {
        let snapshot =
            snapshot_rect.map(|r| BackdropSnapshot::of(acc, acc_w, acc_h, rel, layer, r));
        (b, snapshot)
    });
    let blend_if = backdrop.as_ref().map(|(b, s)| (b, s.as_ref()));

    if let Some(planes) = planes {
        for c in &planes.below {
            composite_contribution(
                acc,
                acc_w,
                acc_h,
                origin,
                rel,
                &planes.shape,
                c,
                opacity,
                env.colors,
            );
        }
    }

    if group.is_empty() {
        composite_pixels_into(
            acc,
            acc_w,
            acc_h,
            origin,
            layer,
            style.fill_opacity,
            blend_if,
            layer.blend,
            opacity,
        );
    } else {
        let mut buf = vec![[0.0f32; 4]; acc.len()];
        composite_pixels_into(
            &mut buf,
            acc_w,
            acc_h,
            origin,
            layer,
            style.fill_opacity,
            blend_if,
            BlendMode::Normal,
            1.0,
        );
        // The footprint is the SHAPE: the effects' plane when there is
        // one, else a pad-0 shape built for the purpose. Only a layer too
        // large for even that (over MAX_PIXELS) falls back to the pixel
        // pass's own alpha, the unstyled group's rule.
        let local;
        let footprint: Option<&Shape> = match planes {
            Some(p) => Some(&p.shape),
            None => {
                local = Shape::of_layer(layer, 0);
                local.as_ref()
            }
        };
        let base_alpha: Vec<f32> = if footprint.is_none() {
            buf.iter().map(|px| px[3]).collect()
        } else {
            Vec::new()
        };
        for member in group.iter().filter(|l| l.visible) {
            composite_layer_into(&mut buf, acc_w, acc_h, origin, member, env);
            match footprint {
                Some(shape) => clamp_alpha_to_shape(&mut buf, acc_w, acc_h, rel, shape),
                None => {
                    for (px, &a) in buf.iter_mut().zip(&base_alpha) {
                        px[3] = a;
                    }
                }
            }
        }
        composite_buffer_into(
            acc,
            &buf,
            acc_w,
            acc_h,
            origin,
            blend_kind(layer.blend),
            opacity,
        );
    }

    if let Some(planes) = planes {
        for c in &planes.interior {
            composite_contribution(
                acc,
                acc_w,
                acc_h,
                origin,
                rel,
                &planes.shape,
                c,
                opacity,
                env.colors,
            );
        }
    }
}

/// The package path of the module doc: the direct path at opacity 1 over
/// strips of a copy of the affected window, mixed back at `opacity`.
#[allow(clippy::too_many_arguments)]
fn composite_package_into(
    acc: &mut [[f32; 4]],
    acc_w: u32,
    acc_h: u32,
    origin: (i32, i32),
    layer: &Layer,
    group: &[Layer],
    style: &LayerStyle,
    opacity: f32,
    env: CompositeEnv<'_>,
    planes: &RenderedEffects,
) {
    let Some((x0, y0, x1, y1)) = affected_window(acc_w, acc_h, origin, layer, planes) else {
        return;
    };
    let width = (x1 - x0) as usize;
    let mut top = y0;
    while top < y1 {
        let rows = (y1 - top).min(PACKAGE_STRIP_ROWS);
        let mut strip: Vec<[f32; 4]> = Vec::with_capacity(width * rows as usize);
        for y in top..top + rows {
            let row = y as usize * acc_w as usize;
            strip.extend_from_slice(&acc[row + x0 as usize..row + x1 as usize]);
        }
        let strip_origin = (
            saturating_i32(i64::from(origin.0) + x0),
            saturating_i32(i64::from(origin.1) + top),
        );
        composite_direct_into(
            &mut strip,
            width as u32,
            rows as u32,
            strip_origin,
            layer,
            group,
            style,
            1.0,
            env,
            Some(planes),
        );
        for (i, y) in (top..top + rows).enumerate() {
            let row = y as usize * acc_w as usize + x0 as usize;
            for x in 0..width {
                let dst = &mut acc[row + x];
                *dst = mix_premultiplied(*dst, strip[i * width + x], opacity);
            }
        }
        top += rows;
    }
}

/// The window of `acc` (`(x0, y0, x1, y1)`, exclusive) a styled layer can
/// touch: its plane — which covers the layer rect and every unshifted
/// contribution — extended by the Below contributions' shifts, clipped to
/// the accumulator. `None` when nothing of it is inside.
fn affected_window(
    acc_w: u32,
    acc_h: u32,
    origin: (i32, i32),
    layer: &Layer,
    planes: &RenderedEffects,
) -> Option<(i64, i64, i64, i64)> {
    let shape = &planes.shape;
    let base_x = i64::from(layer.offset.0) - i64::from(origin.0) + shape.origin.0;
    let base_y = i64::from(layer.offset.1) - i64::from(origin.1) + shape.origin.1;
    let (mut min_sx, mut min_sy, mut max_sx, mut max_sy) = (0i64, 0i64, 0i64, 0i64);
    for c in &planes.below {
        min_sx = min_sx.min(i64::from(c.shift.0));
        min_sy = min_sy.min(i64::from(c.shift.1));
        max_sx = max_sx.max(i64::from(c.shift.0));
        max_sy = max_sy.max(i64::from(c.shift.1));
    }
    let x0 = (base_x + min_sx).max(0);
    let y0 = (base_y + min_sy).max(0);
    let x1 = (base_x + i64::from(shape.w) + max_sx).min(i64::from(acc_w));
    let y1 = (base_y + i64::from(shape.h) + max_sy).min(i64::from(acc_h));
    (x1 > x0 && y1 > y0).then_some((x0, y0, x1, y1))
}

/// The union `(x0, y0, x1, y1)` (window coordinates, exclusive, unclipped)
/// of where `below` can land: each contribution's plane rect shifted by its
/// shift. `None` with no Below contribution.
fn below_landing(
    rel: (i32, i32),
    shape: &Shape,
    below: &[Contribution],
) -> Option<(i64, i64, i64, i64)> {
    let base_x = i64::from(rel.0) + shape.origin.0;
    let base_y = i64::from(rel.1) + shape.origin.1;
    below
        .iter()
        .map(|c| {
            let (x, y) = (base_x + i64::from(c.shift.0), base_y + i64::from(c.shift.1));
            (x, y, x + i64::from(shape.w), y + i64::from(shape.h))
        })
        .reduce(|a, b| (a.0.min(b.0), a.1.min(b.1), a.2.max(b.2), a.3.max(b.3)))
}

/// `backdrop + (packaged - backdrop) x t` in premultiplied space (module
/// doc), returned straight; transparent black when the mixed alpha is 0.
fn mix_premultiplied(backdrop: [f32; 4], packaged: [f32; 4], t: f32) -> [f32; 4] {
    let (ba, pa) = (backdrop[3], packaged[3]);
    let alpha = ba + (pa - ba) * t;
    if alpha <= 0.0 {
        return [0.0; 4];
    }
    let mut out = [0.0f32; 4];
    for c in 0..3 {
        let b = backdrop[c] * ba;
        let p = packaged[c] * pa;
        out[c] = ((b + (p - b) * t) / alpha).clamp(0.0, 1.0);
    }
    out[3] = alpha.min(1.0);
    out
}

/// `acc` inside (layer rect ∩ window ∩ `rect`), copied before the layer
/// draws anything (module doc, step 1). `x0`/`y0` are window coordinates.
struct BackdropSnapshot {
    x0: i64,
    y0: i64,
    w: usize,
    h: usize,
    px: Vec<[f32; 4]>,
}

impl BackdropSnapshot {
    fn of(
        acc: &[[f32; 4]],
        acc_w: u32,
        acc_h: u32,
        rel: (i32, i32),
        layer: &Layer,
        rect: (i64, i64, i64, i64),
    ) -> Self {
        let (lw, lh) = layer.pixels.dimensions();
        let x0 = i64::from(rel.0).max(0).max(rect.0);
        let y0 = i64::from(rel.1).max(0).max(rect.1);
        let x1 = (i64::from(rel.0) + i64::from(lw))
            .min(i64::from(acc_w))
            .min(rect.2);
        let y1 = (i64::from(rel.1) + i64::from(lh))
            .min(i64::from(acc_h))
            .min(rect.3);
        if x1 <= x0 || y1 <= y0 {
            return BackdropSnapshot {
                x0,
                y0,
                w: 0,
                h: 0,
                px: Vec::new(),
            };
        }
        let (w, h) = ((x1 - x0) as usize, (y1 - y0) as usize);
        let mut px = Vec::with_capacity(w * h);
        for ay in y0..y1 {
            let row = ay as usize * acc_w as usize;
            px.extend_from_slice(&acc[row + x0 as usize..row + x1 as usize]);
        }
        BackdropSnapshot { x0, y0, w, h, px }
    }

    /// The snapshotted pixel at window position `(ax, ay)`; `None` outside
    /// the snapshot, where the accumulator is still the backdrop.
    fn at(&self, ax: i64, ay: i64) -> Option<[f32; 4]> {
        let x = ax - self.x0;
        let y = ay - self.y0;
        if x < 0 || y < 0 || x >= self.w as i64 || y >= self.h as i64 {
            return None;
        }
        Some(self.px[y as usize * self.w + x as usize])
    }
}

/// The layer's pixels into `target` with
/// `sa = alpha x mask x fill_opacity x blend-if weight x opacity` and blend
/// `mode`; the Blend If weight reads the backdrop snapshot where there is
/// one and `target` itself (still the underlying composite there, read
/// before the pixel is written) everywhere else; `None` = weight 1.
/// Master copy of the iteration: `doc::composite_layer_into` —
/// this is its variant with two extra multiplies; the arithmetic is kept
/// identical so a fill-opacity edit and a layer-opacity edit of the same
/// value composite byte-identically. A fresh transparent target pixel is
/// written directly as `[cs, sa]` under Normal (the kernel's `sa*cs/sa`
/// would only add rounding), so the clip-base buffer holds the base pixels
/// exactly.
#[allow(clippy::too_many_arguments)]
fn composite_pixels_into(
    target: &mut [[f32; 4]],
    acc_w: u32,
    acc_h: u32,
    origin: (i32, i32),
    layer: &Layer,
    fill_opacity: f32,
    blend_if: Option<(&BlendIf, Option<&BackdropSnapshot>)>,
    mode: BlendMode,
    opacity: f32,
) {
    let fill = sane_opacity(fill_opacity);
    if fill <= 0.0 || opacity <= 0.0 {
        return;
    }
    let kind = blend_kind(mode);
    let direct = mode == BlendMode::Normal;
    let mask = layer.active_mask().map(|m| m.as_raw().as_slice());
    let (lw, lh) = layer.pixels.dimensions();
    let rel_x = i64::from(layer.offset.0) - i64::from(origin.0);
    let rel_y = i64::from(layer.offset.1) - i64::from(origin.1);
    let x0 = rel_x.max(0);
    let y0 = rel_y.max(0);
    let x1 = (rel_x + i64::from(lw)).min(i64::from(acc_w));
    let y1 = (rel_y + i64::from(lh)).min(i64::from(acc_h));
    let raw = layer.pixels.as_raw();
    for ay in y0..y1 {
        let ly = (ay - rel_y) as u64;
        for ax in x0..x1 {
            let lx = (ax - rel_x) as u64;
            let mi = (ly * u64::from(lw) + lx) as usize;
            let li = mi * 4;
            let coverage = mask.map_or(1.0, |m| f32::from(m[mi]) / 255.0);
            let cs = [
                f32::from(raw[li]) / 255.0,
                f32::from(raw[li + 1]) / 255.0,
                f32::from(raw[li + 2]) / 255.0,
            ];
            let ai = (ay as u64 * u64::from(acc_w) + ax as u64) as usize;
            let weight = match blend_if {
                None => 1.0,
                Some((b, snapshot)) => {
                    let under = snapshot.and_then(|s| s.at(ax, ay)).unwrap_or(target[ai]);
                    source_weight(b, cs, under)
                }
            };
            let sa = f32::from(raw[li + 3]) / 255.0 * coverage * fill * weight * opacity;
            if sa <= 0.0 {
                continue;
            }
            if direct && target[ai][3] <= 0.0 {
                target[ai] = [cs[0], cs[1], cs[2], sa];
                continue;
            }
            let canvas_xy = (ax + i64::from(origin.0), ay + i64::from(origin.1));
            composite_source_into(target, ai, cs, sa, kind, canvas_xy);
        }
    }
}

/// One contribution onto `target` with `sa = coverage x c.opacity x
/// opacity_scale`, honouring the shift and the knock-out: plane pixel
/// `(px, py)` lands at window pixel `(rel + shape.origin + (px, py) +
/// shift)`, and a knocked-out contribution is multiplied by
/// `1 - shape(px + shift)` — the shape at the landing position. A gradient
/// colour is evaluated at the pixel's layer coordinate.
#[allow(clippy::too_many_arguments)]
fn composite_contribution(
    target: &mut [[f32; 4]],
    acc_w: u32,
    acc_h: u32,
    origin: (i32, i32),
    rel: (i32, i32),
    shape: &Shape,
    c: &Contribution,
    opacity_scale: f32,
    colors: Option<&Transform>,
) {
    let scale = c.opacity * opacity_scale;
    if scale.is_nan() || scale <= 0.0 || c.coverage.len() != shape.coverage.len() {
        return;
    }
    let kind = blend_kind(c.blend);
    // The style's AUTHORED sRGB colour into the document's space, once for
    // the whole contribution (module doc). A gradient converts its stops, so
    // this is a stop list either way, never per-pixel work.
    let converted = colors.map(|t| c.color.converted(t));
    let color = converted.as_ref().unwrap_or(&c.color);
    let (sx, sy) = (i64::from(c.shift.0), i64::from(c.shift.1));
    // Window position of plane pixel (0, 0).
    let base_x = i64::from(rel.0) + shape.origin.0 + sx;
    let base_y = i64::from(rel.1) + shape.origin.1 + sy;
    let px0 = (-base_x).max(0);
    let py0 = (-base_y).max(0);
    let px1 = (i64::from(acc_w) - base_x).min(i64::from(shape.w));
    let py1 = (i64::from(acc_h) - base_y).min(i64::from(shape.h));
    if px0 >= px1 || py0 >= py1 {
        return;
    }
    for py in py0..py1 {
        let ay = base_y + py;
        for px in px0..px1 {
            let i = shape.idx(px as u32, py as u32);
            let mut cov = u32::from(c.coverage[i]);
            if cov == 0 {
                continue;
            }
            if c.knocked_out_by_shape {
                let under = u32::from(shape.at(px + sx, py + sy));
                cov = (cov * (255 - under) + 127) / 255;
                if cov == 0 {
                    continue;
                }
            }
            let sa = cov as f32 / 255.0 * scale;
            if sa <= 0.0 {
                continue;
            }
            let ax = base_x + px;
            let ai = (ay as u64 * u64::from(acc_w) + ax as u64) as usize;
            let cs = color.at(px + shape.origin.0, py + shape.origin.1);
            let canvas_xy = (ax + i64::from(origin.0), ay + i64::from(origin.1));
            composite_source_into(target, ai, cs, sa, kind, canvas_xy);
        }
    }
}

/// `buf alpha = min(alpha, shape coverage / 255)` over the whole buffer
/// (0 outside the plane) — the clip-base footprint rule of the module doc.
fn clamp_alpha_to_shape(
    buf: &mut [[f32; 4]],
    acc_w: u32,
    acc_h: u32,
    rel: (i32, i32),
    shape: &Shape,
) {
    let base_x = i64::from(rel.0) + shape.origin.0;
    let base_y = i64::from(rel.1) + shape.origin.1;
    for ay in 0..i64::from(acc_h) {
        let row = ay as usize * acc_w as usize;
        for ax in 0..i64::from(acc_w) {
            let limit = f32::from(shape.at(ax - base_x, ay - base_y)) / 255.0;
            let px = &mut buf[row + ax as usize];
            if px[3] > limit {
                px[3] = limit;
            }
        }
    }
}

/// The canvas rect `(x0, y0, x1, y1)` (exclusive) Merge Down must give a
/// baked `layer` (module doc): its pixel rect grown by the style's pad, and
/// the drop shadow's shifted copy of that rect clipped to the canvas. The
/// pixel rect alone without a renderable style.
pub(crate) fn merge_extent(layer: &Layer, env: CompositeEnv<'_>) -> (i64, i64, i64, i64) {
    let (lw, lh) = layer.pixels.dimensions();
    let (x, y) = (i64::from(layer.offset.0), i64::from(layer.offset.1));
    let rect = (x, y, x + i64::from(lw), y + i64::from(lh));
    match layer.renders_style() {
        Some(style) => style_grown(rect, style, env),
        None => rect,
    }
}

/// `rect` grown by everything a rendered `style` draws OUTSIDE the thing it
/// decorates: the pad on all four sides, plus the drop shadow's shifted rect
/// clipped to the canvas.
///
/// Split out of [`merge_extent`] because a GROUP needs exactly the same
/// arithmetic and has no `Layer` to hand it: `doc_group::extent_of_level`
/// grows a nested group's subtree rect with this, so an enclosing isolated
/// group sizes its buffer to hold the inner group's effects instead of
/// clipping them away. One implementation, two callers.
pub(crate) fn style_grown(
    rect: (i64, i64, i64, i64),
    style: &LayerStyle,
    env: CompositeEnv<'_>,
) -> (i64, i64, i64, i64) {
    let pad = i64::from(style.pad());
    let (x0, y0, x1, y1) = (rect.0 - pad, rect.1 - pad, rect.2 + pad, rect.3 + pad);
    let Some((dx, dy)) = style.shadow_shift(env.light) else {
        return (x0, y0, x1, y1);
    };
    let (dx, dy) = (i64::from(dx), i64::from(dy));
    let sx0 = (x0 + dx).max(0);
    let sy0 = (y0 + dy).max(0);
    let sx1 = (x1 + dx).min(i64::from(env.canvas.0));
    let sy1 = (y1 + dy).min(i64::from(env.canvas.1));
    if sx1 <= sx0 || sy1 <= sy0 {
        return (x0, y0, x1, y1);
    }
    (x0.min(sx0), y0.min(sy0), x1.max(sx1), y1.max(sy1))
}
