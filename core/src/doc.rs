//! Layered document model: `RzDocument` (canvas + bottom-to-top layer
//! stack), the f32 compositing projection, document ops, and per-layer
//! masks. See include/rasterize_core.h for the contract. The blend-mode
//! table and blend math live in `blend`, the RZDC native format in `rzdc`,
//! and layered PSD import in `psd`. Layer pixel and mask buffers are
//! `Arc`-shared so document copies are copy-on-write.

use std::sync::Arc;

use image::imageops::{self, FilterType};
use image::{GenericImageView, GrayImage, ImageBuffer, Luma, Pixel, RgbaImage};

use crate::adjust::Adjustment;
use crate::blend::{
    blend_kind, composite_source_into, dissolve_threshold, paint_pixel, BlendKind, LUMA_B, LUMA_G,
    LUMA_R,
};
use crate::ops::CompositeMode;
use crate::RzImage;

pub use crate::blend::BlendMode;

/// Largest permitted canvas or merged-extent size, in total pixels (matches
/// the `rz_image_resize` guard). The FFI applies it to caller-declared layer
/// buffer dimensions too, so absurd dimensions are refused rather than read.
pub(crate) const MAX_PIXELS: u64 = 100_000_000;

// ------------------------------------------------------------------ model --

/// One layer: straight-alpha RGBA8 pixels of the layer's own size, an integer
/// canvas offset, and display properties. The pixel buffer is immutable and
/// shared (`Arc`), so cloning a layer is cheap.
#[derive(Clone)]
pub struct Layer {
    /// Straight-alpha RGBA8 pixels, the layer's own size.
    pub pixels: Arc<RgbaImage>,
    /// Canvas position of the layer's top-left pixel.
    pub offset: (i32, i32),
    /// Display name.
    pub name: String,
    /// Opacity in [0, 1].
    pub opacity: f32,
    /// Blend mode used when compositing this layer onto the stack below.
    pub blend: BlendMode,
    /// Invisible layers are skipped by the projection.
    pub visible: bool,
    /// Optional coverage mask gating the layer's alpha (0 hides, 255 shows,
    /// intermediate values scale). INVARIANT: its dimensions always equal
    /// `pixels`' dimensions — the mask moves, rotates and scales with the
    /// layer (GIMP-style), so canvas geometry never enters mask indexing.
    /// Shared (`Arc`) for the same copy-on-write reason as the pixels.
    pub mask: Option<Arc<GrayImage>>,
    /// When false the mask is retained but ignored while compositing.
    pub mask_enabled: bool,
    /// Opaque per-layer metadata (a minimal "parasite"): the core stores,
    /// copies and serializes this JSON blob but never interprets it — with
    /// ONE exception: meta that parses as an [`Adjustment`] description
    /// (`{"type":"adjust", ...}`, see `adjust`) makes the compositor treat
    /// the layer as an adjustment layer.
    pub meta: Option<String>,
    /// Clipping-mask flag (Photoshop semantics): a clipped layer is confined
    /// to the alpha footprint of the first UNCLIPPED layer beneath it, its
    /// base. Group structure is purely positional — [`RzDocument::flattened`]
    /// re-derives base + consecutive-clipped-run groups on every composite,
    /// so reordering or deleting layers needs no bookkeeping. A clipped layer
    /// at the bottom of the stack (no unclipped layer below) composites as if
    /// unclipped. Copied on duplicate like every other property.
    pub clipped: bool,
}

impl Layer {
    /// A plain layer at offset (0, 0): fully opaque, Normal, visible,
    /// unclipped, with no mask and no meta.
    fn new(pixels: RgbaImage, name: &str) -> Self {
        Layer {
            pixels: Arc::new(pixels),
            offset: (0, 0),
            name: name.to_string(),
            opacity: 1.0,
            blend: BlendMode::Normal,
            visible: true,
            mask: None,
            mask_enabled: true,
            meta: None,
            clipped: false,
        }
    }

    /// The mask that actually gates compositing: `None` when the layer has no
    /// mask, the mask is disabled, or (defensively — the invariant should
    /// prevent it) its dimensions disagree with the layer's pixels.
    fn active_mask(&self) -> Option<&GrayImage> {
        let mask = self.mask.as_deref()?;
        if !self.mask_enabled || mask.dimensions() != self.pixels.dimensions() {
            return None;
        }
        Some(mask)
    }
}

/// A layered document: canvas size plus an ordered layer stack
/// (index 0 = bottom). Always contains at least one layer.
#[derive(Clone)]
pub struct RzDocument {
    /// Canvas width in pixels.
    pub width: u32,
    /// Canvas height in pixels.
    pub height: u32,
    /// Layer stack, bottom first.
    pub layers: Vec<Layer>,
}

/// Clamps opacity to [0, 1], mapping non-finite values to 1.
pub(crate) fn sane_opacity(opacity: f32) -> f32 {
    if opacity.is_finite() {
        opacity.clamp(0.0, 1.0)
    } else {
        1.0
    }
}

// ------------------------------------------------------------- projection --

/// Composites `layer` onto the straight-alpha f32 accumulator `acc` (size
/// `acc_w` x `acc_h`, whose top-left pixel sits at canvas coordinate
/// `origin`), using the W3C compositing formula with the layer's blend mode
/// and opacity. An enabled layer mask scales the source alpha per pixel
/// (`mask / 255`) on top of the layer opacity. Pixels outside the layer's
/// extent are untouched. The caller is responsible for visibility filtering.
///
/// A layer whose meta parses as an [`Adjustment`] is routed to
/// [`composite_adjustment_into`] instead — every projection (flatten, render,
/// export, merge-down) goes through this function, so adjustment layers
/// behave identically everywhere.
fn composite_layer_into(
    acc: &mut [[f32; 4]],
    acc_w: u32,
    acc_h: u32,
    origin: (i32, i32),
    layer: &Layer,
) {
    let opacity = sane_opacity(layer.opacity);
    if opacity <= 0.0 {
        return;
    }
    if let Some(adjustment) = layer.meta.as_deref().and_then(Adjustment::from_meta) {
        composite_adjustment_into(acc, acc_w, acc_h, origin, layer, &adjustment, opacity);
        return;
    }
    let mask = layer.active_mask().map(|m| m.as_raw().as_slice());
    let kind = blend_kind(layer.blend);
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
            let sa = f32::from(raw[li + 3]) / 255.0 * coverage * opacity;
            if sa <= 0.0 {
                continue;
            }
            let cs = [
                f32::from(raw[li]) / 255.0,
                f32::from(raw[li + 1]) / 255.0,
                f32::from(raw[li + 2]) / 255.0,
            ];
            let ai = (ay as u64 * u64::from(acc_w) + ax as u64) as usize;
            let canvas_xy = (ax + i64::from(origin.0), ay + i64::from(origin.1));
            composite_source_into(acc, ai, cs, sa, kind, canvas_xy);
        }
    }
}

/// Composites an ADJUSTMENT layer onto the accumulator: the layer's own
/// pixels are ignored; instead the adjustment is applied to the accumulated
/// backdrop color (`adjusted = adjustment(backdrop)`, straight [0, 1] RGB),
/// pushed through the layer's blend mode as the SOURCE against the backdrop
/// (Normal therefore leaves `adjusted` as-is), and lerped back in by
/// `k = opacity * mask coverage`:
///
///   out_rgb = backdrop_rgb + (effective_rgb - backdrop_rgb) * k
///
/// Alpha is NEVER changed, and a fully transparent backdrop pixel is left
/// entirely untouched. Coverage honors the layer's offset exactly as for
/// raster layers, but gates differently: with no mask (or a disabled one)
/// the adjustment reaches the WHOLE accumulator — an unmasked adjustment
/// layer is canvas-wide regardless of its own pixel extent — while an
/// enabled mask confines it (0 outside the mask's extent). Dissolve, which
/// has no blend function, keeps its all-or-nothing dither: each pixel is
/// fully adjusted with probability `k`, otherwise untouched.
fn composite_adjustment_into(
    acc: &mut [[f32; 4]],
    acc_w: u32,
    acc_h: u32,
    origin: (i32, i32),
    layer: &Layer,
    adjustment: &Adjustment,
    opacity: f32,
) {
    let mask = layer.active_mask().map(|m| m.as_raw().as_slice());
    let kind = blend_kind(layer.blend);
    let (lw, lh) = layer.pixels.dimensions();
    let rel_x = i64::from(layer.offset.0) - i64::from(origin.0);
    let rel_y = i64::from(layer.offset.1) - i64::from(origin.1);
    for ay in 0..i64::from(acc_h) {
        for ax in 0..i64::from(acc_w) {
            let coverage = match mask {
                None => 1.0,
                Some(m) => {
                    let lx = ax - rel_x;
                    let ly = ay - rel_y;
                    if lx < 0 || ly < 0 || lx >= i64::from(lw) || ly >= i64::from(lh) {
                        continue; // outside the mask's extent: coverage 0
                    }
                    f32::from(m[(ly as u64 * u64::from(lw) + lx as u64) as usize]) / 255.0
                }
            };
            let k = coverage * opacity;
            if k <= 0.0 {
                continue;
            }
            let ai = (ay as u64 * u64::from(acc_w) + ax as u64) as usize;
            let bg = acc[ai];
            if bg[3] <= 0.0 {
                continue; // nothing to adjust; alpha (and color) stay exact
            }
            let cb = [bg[0], bg[1], bg[2]];
            let adjusted = adjustment.apply(cb);
            if let BlendKind::Dissolve = kind {
                let (cx, cy) = (ax + i64::from(origin.0), ay + i64::from(origin.1));
                if dissolve_threshold(cx, cy) < k {
                    acc[ai] = [adjusted[0], adjusted[1], adjusted[2], bg[3]];
                }
                continue;
            }
            let effective = match kind {
                BlendKind::Separable(f) => [
                    f(cb[0], adjusted[0]),
                    f(cb[1], adjusted[1]),
                    f(cb[2], adjusted[2]),
                ],
                BlendKind::NonSeparable(f) => f(cb, adjusted),
                BlendKind::Dissolve => unreachable!("dissolve handled above"),
            };
            for c in 0..3 {
                acc[ai][c] = cb[c] + (effective[c] - cb[c]) * k;
            }
        }
    }
}

/// Composites a CLIP GROUP — `base` plus `group`, the consecutive run of
/// clipped layers stacked immediately above it — onto the accumulator. The
/// caller has already filtered the base's visibility (an invisible base hides
/// its whole group). With an EMPTY group this is exactly
/// [`composite_layer_into`] on the base: the group machinery never engages,
/// keeping the plain path byte-identical.
///
/// A non-empty group blends as one unit (Photoshop's "blend clipped layers
/// as group"): the base renders into a private transparent buffer at FULL
/// opacity in Normal mode, its layer mask applied as usual, and the buffer's
/// alpha after that render — the base's footprint — is recorded. Each
/// visible clipped layer then composites into the buffer through the normal
/// kernel (its own opacity, blend mode, mask and offset; adjustment meta
/// routes through [`composite_adjustment_into`] with the buffer as
/// backdrop), and after each one the buffer's alpha is forced back to the
/// recorded footprint — clipped layers never extend or shrink it. The
/// finished buffer finally composites onto `acc` with the BASE layer's blend
/// mode and opacity (Dissolve keeps its canvas-absolute dither). Invisible
/// clipped layers are skipped.
///
/// One consequence of the base rendering into a TRANSPARENT buffer: an
/// adjustment-meta base has no pixel footprint there (adjustments never touch
/// alpha, and a transparent backdrop is left untouched), so a non-empty group
/// over an adjustment base contributes nothing.
fn composite_clip_group_into(
    acc: &mut [[f32; 4]],
    acc_w: u32,
    acc_h: u32,
    origin: (i32, i32),
    base: &Layer,
    group: &[Layer],
) {
    if group.is_empty() {
        composite_layer_into(acc, acc_w, acc_h, origin, base);
        return;
    }
    let opacity = sane_opacity(base.opacity);
    if opacity <= 0.0 {
        return;
    }
    let mut buf = vec![[0.0f32; 4]; acc.len()];
    let full = Layer {
        opacity: 1.0,
        blend: BlendMode::Normal,
        ..base.clone()
    };
    composite_layer_into(&mut buf, acc_w, acc_h, origin, &full);
    let base_alpha: Vec<f32> = buf.iter().map(|px| px[3]).collect();
    for layer in group.iter().filter(|l| l.visible) {
        composite_layer_into(&mut buf, acc_w, acc_h, origin, layer);
        for (px, &a) in buf.iter_mut().zip(&base_alpha) {
            px[3] = a;
        }
    }
    // The group buffer is accumulator-aligned (same size, same origin), so
    // this is composite_layer_into's kernel with an f32 source and the
    // base's mode and opacity. Pixels a clipped layer touched outside the
    // footprint carry color at forced alpha 0 and are skipped here.
    let kind = blend_kind(base.blend);
    for ay in 0..i64::from(acc_h) {
        for ax in 0..i64::from(acc_w) {
            let ai = (ay as u64 * u64::from(acc_w) + ax as u64) as usize;
            let src = buf[ai];
            let sa = src[3] * opacity;
            if sa <= 0.0 {
                continue;
            }
            let cs = [src[0], src[1], src[2]];
            let canvas_xy = (ax + i64::from(origin.0), ay + i64::from(origin.1));
            composite_source_into(acc, ai, cs, sa, kind, canvas_xy);
        }
    }
}

/// The five exact (lossless, axis-aligned) whole-document transforms. Naming
/// one lets `geometry` apply the SAME transform to a layer's pixels and to its
/// mask, which is what keeps the two the same size. `doc_transform` reuses
/// them as the exact fast paths of the arbitrary-affine layer transform.
#[derive(Clone, Copy)]
pub(crate) enum Geometry {
    Rotate90,
    Rotate180,
    Rotate270,
    FlipH,
    FlipV,
}

impl Geometry {
    pub(crate) fn apply<I>(
        self,
        img: &I,
    ) -> ImageBuffer<I::Pixel, Vec<<I::Pixel as Pixel>::Subpixel>>
    where
        I: GenericImageView,
        I::Pixel: 'static,
    {
        match self {
            Geometry::Rotate90 => imageops::rotate90(img),
            Geometry::Rotate180 => imageops::rotate180(img),
            Geometry::Rotate270 => imageops::rotate270(img),
            Geometry::FlipH => imageops::flip_horizontal(img),
            Geometry::FlipV => imageops::flip_vertical(img),
        }
    }
}

/// Quantizes a straight-alpha f32 accumulator to RGBA8.
fn quantize(acc: &[[f32; 4]], w: u32, h: u32) -> RgbaImage {
    let mut out = RgbaImage::new(w, h);
    for (dst, src) in out.pixels_mut().zip(acc.iter()) {
        for (d, &v) in dst.0.iter_mut().zip(src.iter()) {
            *d = (v.clamp(0.0, 1.0) * 255.0).round() as u8;
        }
    }
    out
}

// ------------------------------------------------------------- operations --

impl RzDocument {
    /// Wraps straight-alpha RGBA8 pixels as a single-layer document.
    pub fn from_pixels(pixels: RgbaImage) -> Self {
        let (width, height) = pixels.dimensions();
        RzDocument {
            width,
            height,
            layers: vec![Layer::new(pixels, "Background")],
        }
    }

    fn layer(&self, idx: usize) -> Option<&Layer> {
        self.layers.get(idx)
    }

    /// Canvas-sized straight-alpha projection of all visible layers,
    /// composited bottom-to-top in f32 and quantized once at the end.
    ///
    /// The walk re-derives CLIP GROUPS positionally on every call: each
    /// unclipped layer is a BASE and the consecutive run of clipped layers
    /// immediately above it composites with it as one unit through
    /// [`composite_clip_group_into`], confined to the base's alpha footprint.
    /// An invisible base hides its whole group; clipped layers at the BOTTOM
    /// of the stack (no unclipped layer below) have no base and composite as
    /// if unclipped. A base with no clipped layers above composites exactly
    /// as it always did.
    pub fn flattened(&self) -> RgbaImage {
        let px = self.width as usize * self.height as usize;
        let mut acc = vec![[0.0f32; 4]; px];
        let mut i = 0;
        while i < self.layers.len() {
            let layer = &self.layers[i];
            if layer.clipped {
                // Only reachable at the bottom of the stack (a clipped layer
                // above a base is consumed by that base's group below):
                // baseless, so it composites as if unclipped.
                if layer.visible {
                    composite_layer_into(&mut acc, self.width, self.height, (0, 0), layer);
                }
                i += 1;
                continue;
            }
            let mut end = i + 1;
            while end < self.layers.len() && self.layers[end].clipped {
                end += 1;
            }
            if layer.visible {
                composite_clip_group_into(
                    &mut acc,
                    self.width,
                    self.height,
                    (0, 0),
                    layer,
                    &self.layers[i + 1..end],
                );
            }
            i = end;
        }
        quantize(&acc, self.width, self.height)
    }

    /// Layer `idx`'s OWN pixels on a transparent canvas-sized buffer, placed
    /// at its offset and clipped to the canvas — the single-layer counterpart
    /// of [`Self::flattened`], and what a layer-scoped copy puts on the
    /// clipboard.
    ///
    /// Deliberately raw: opacity, blend mode, visibility and the layer mask
    /// are COMPOSITING properties — they describe how the layer meets the
    /// stack, not what its pixels are — so they play no part here and a
    /// hidden layer still yields its pixels. Straight alpha throughout, so
    /// nothing is un/premultiplied and the bytes copy across verbatim.
    ///
    /// None for an out-of-range `idx`; an empty canvas or a layer entirely
    /// off-canvas simply yields a fully transparent buffer.
    pub fn layer_canvas_image(&self, idx: usize) -> Option<RgbaImage> {
        let layer = self.layers.get(idx)?;
        let mut out = RgbaImage::new(self.width, self.height);
        let (off_x, off_y) = layer.offset;
        for (lx, ly, px) in layer.pixels.enumerate_pixels() {
            // Layer space -> canvas space in i64: an offset near i32::MIN/MAX
            // must not wrap into the canvas.
            let cx = i64::from(off_x) + i64::from(lx);
            let cy = i64::from(off_y) + i64::from(ly);
            if cx < 0 || cy < 0 || cx >= i64::from(self.width) || cy >= i64::from(self.height) {
                continue;
            }
            out.put_pixel(cx as u32, cy as u32, *px);
        }
        Some(out)
    }

    /// Pure setter: replaces layer `idx`'s name.
    pub fn with_layer_name(&self, idx: usize, name: &str) -> Option<Self> {
        self.with_layer(idx, |l| l.name = name.to_string())
    }

    /// Pure setter: replaces layer `idx`'s opacity (clamped to [0, 1]).
    pub fn with_layer_opacity(&self, idx: usize, opacity: f32) -> Option<Self> {
        self.with_layer(idx, |l| l.opacity = sane_opacity(opacity))
    }

    /// Pure setter: replaces layer `idx`'s blend mode.
    pub fn with_layer_blend_mode(&self, idx: usize, mode: BlendMode) -> Option<Self> {
        self.with_layer(idx, |l| l.blend = mode)
    }

    /// Pure setter: replaces layer `idx`'s visibility flag.
    pub fn with_layer_visible(&self, idx: usize, visible: bool) -> Option<Self> {
        self.with_layer(idx, |l| l.visible = visible)
    }

    /// Pure setter: replaces layer `idx`'s clipped flag (see [`Layer::clipped`]).
    pub fn with_layer_clipped(&self, idx: usize, clipped: bool) -> Option<Self> {
        self.with_layer(idx, |l| l.clipped = clipped)
    }

    /// Pure setter: replaces layer `idx`'s canvas offset.
    pub fn with_layer_offset(&self, idx: usize, x: i32, y: i32) -> Option<Self> {
        self.with_layer(idx, |l| l.offset = (x, y))
    }

    /// Pure setter: replaces layer `idx`'s pixels (any size; offset and
    /// properties kept). A mask survives a same-size replacement (the paint
    /// and fill ops rely on that) but is dropped when the new pixels have
    /// different dimensions, which would otherwise break the mask's
    /// same-size-as-the-layer invariant.
    pub fn with_layer_pixels(&self, idx: usize, pixels: RgbaImage) -> Option<Self> {
        self.with_layer(idx, |l| {
            if l.mask
                .as_ref()
                .is_some_and(|m| m.dimensions() != pixels.dimensions())
            {
                l.mask = None;
                l.mask_enabled = true;
            }
            l.pixels = Arc::new(pixels);
        })
    }

    fn with_layer(&self, idx: usize, edit: impl FnOnce(&mut Layer)) -> Option<Self> {
        self.layer(idx)?;
        let mut doc = self.clone();
        edit(&mut doc.layers[idx]);
        Some(doc)
    }

    /// Inserts a transparent canvas-sized layer above `idx`.
    pub fn adding_layer(&self, idx: usize, name: &str) -> Option<Self> {
        self.adding_image_layer(idx, RgbaImage::new(self.width, self.height), name)
    }

    /// Inserts a layer with the given pixels (offset 0) above `idx`.
    pub fn adding_image_layer(&self, idx: usize, pixels: RgbaImage, name: &str) -> Option<Self> {
        self.layer(idx)?;
        let mut doc = self.clone();
        doc.layers.insert(idx + 1, Layer::new(pixels, name));
        Some(doc)
    }

    /// Duplicates layer `idx` (pixels shared, " copy" appended to the name),
    /// inserting the duplicate above it.
    pub fn duplicating_layer(&self, idx: usize) -> Option<Self> {
        let src = self.layer(idx)?;
        let mut dup = src.clone();
        dup.name.push_str(" copy");
        let mut doc = self.clone();
        doc.layers.insert(idx + 1, dup);
        Some(doc)
    }

    /// Removes layer `idx`; `None` if it is the only layer.
    pub fn removing_layer(&self, idx: usize) -> Option<Self> {
        self.layer(idx)?;
        if self.layers.len() == 1 {
            return None;
        }
        let mut doc = self.clone();
        doc.layers.remove(idx);
        Some(doc)
    }

    /// Removes the layer at `from` and reinserts it at `to`.
    pub fn moving_layer(&self, from: usize, to: usize) -> Option<Self> {
        self.layer(from)?;
        self.layer(to)?;
        let mut doc = self.clone();
        let layer = doc.layers.remove(from);
        doc.layers.insert(to, layer);
        Some(doc)
    }

    /// Merges layer `idx` (must be >= 1) into the layer below it. The merged
    /// layer covers the union of both extents; BOTH layers' modes and
    /// opacities are baked into its pixels via the same kernel as
    /// [`RzDocument::flattened`] (the lower composites onto a transparent
    /// backdrop, where every blend function degenerates to Normal and
    /// Dissolve keeps exactly its dithered pixels), so the result is
    /// Normal at opacity 1 and keeps only the lower layer's name and
    /// visibility. An invisible upper layer contributes nothing (it is simply
    /// removed); a hidden LOWER layer refuses the merge (`None`) so the upper
    /// layer's content cannot silently vanish.
    ///
    /// The merge is destructive, so the merged layer carries neither layer's
    /// mask or meta: an ENABLED mask is baked into the pixels by the kernel
    /// (like opacity and blend), a disabled one is simply dropped, and meta no
    /// longer describes the pixels it is attached to. Because the kernel is
    /// shared, merging an ADJUSTMENT layer down bakes the adjustment into the
    /// layer below, gated by its blend mode, opacity and mask.
    ///
    /// A CLIPPED upper layer is baked through its clipping: the pair runs the
    /// same group kernel as the projection ([`composite_clip_group_into`]
    /// with the lower layer as base), so the upper layer's contribution is
    /// alpha-limited to the lower layer's footprint. The merged layer keeps
    /// the LOWER layer's clipped flag (like its name and visibility), so a
    /// merge inside a clip group stays in the group.
    pub fn merging_down(&self, idx: usize) -> Option<Self> {
        if idx == 0 {
            return None;
        }
        let upper = self.layer(idx)?.clone();
        let lower = self.layer(idx - 1)?.clone();
        if !lower.visible {
            return None;
        }
        let mut doc = self.clone();
        doc.layers.remove(idx);
        if !upper.visible {
            return Some(doc);
        }
        let (lo_w, lo_h) = lower.pixels.dimensions();
        let (up_w, up_h) = upper.pixels.dimensions();
        let x0 = i64::from(lower.offset.0).min(i64::from(upper.offset.0));
        let y0 = i64::from(lower.offset.1).min(i64::from(upper.offset.1));
        let x1 = (i64::from(lower.offset.0) + i64::from(lo_w))
            .max(i64::from(upper.offset.0) + i64::from(up_w));
        let y1 = (i64::from(lower.offset.1) + i64::from(lo_h))
            .max(i64::from(upper.offset.1) + i64::from(up_h));
        let (uw, uh) = ((x1 - x0) as u64, (y1 - y0) as u64);
        if uw == 0 || uh == 0 || uw * uh > MAX_PIXELS {
            return None;
        }
        let origin = (x0 as i32, y0 as i32);
        let mut acc = vec![[0.0f32; 4]; (uw * uh) as usize];
        if upper.clipped {
            composite_clip_group_into(
                &mut acc,
                uw as u32,
                uh as u32,
                origin,
                &lower,
                std::slice::from_ref(&upper),
            );
        } else {
            composite_layer_into(&mut acc, uw as u32, uh as u32, origin, &lower);
            composite_layer_into(&mut acc, uw as u32, uh as u32, origin, &upper);
        }
        let merged = doc.layers.get_mut(idx - 1).expect("lower layer exists");
        merged.pixels = Arc::new(quantize(&acc, uw as u32, uh as u32));
        merged.offset = origin;
        merged.opacity = 1.0;
        merged.blend = BlendMode::Normal;
        merged.mask = None;
        merged.mask_enabled = true;
        merged.meta = None;
        Some(doc)
    }

    /// Single-layer document containing the projection, named "Background".
    ///
    /// Like [`RzDocument::merging_down`], this is destructive: the projection
    /// bakes every ENABLED mask into the composited pixels (a disabled one is
    /// simply dropped with its layer), so the resulting layer carries neither
    /// a mask nor meta — nothing is left that could describe those pixels.
    pub fn flattening(&self) -> Self {
        RzDocument::from_pixels(self.flattened())
    }

    /// Paints a canvas-frame PREMULTIPLIED RGBA8 overlay (`src`, exactly
    /// canvas w*h*4 bytes, semantics of `rz_image_composite`) onto layer
    /// `idx`, mapped through the layer's offset. Overlay areas outside the
    /// layer's extent are ignored; if the layer's extent does not intersect
    /// the canvas at all (no pixel could change) the paint is refused
    /// (`None`) rather than returning an unchanged copy. (`pub(crate)`
    /// because `CompositeMode` is a crate-private type; the public surface is
    /// `rz_doc_painting_layer`.)
    pub(crate) fn painting_layer(
        &self,
        idx: usize,
        src: &[u8],
        mode: CompositeMode,
        alpha: f32,
    ) -> Option<Self> {
        let layer = self.layer(idx)?;
        if alpha.is_nan() {
            return None;
        }
        let expected = (self.width as usize)
            .checked_mul(self.height as usize)?
            .checked_mul(4)?;
        if src.len() != expected {
            return None;
        }
        let a = alpha.clamp(0.0, 1.0);
        let (lw, lh) = layer.pixels.dimensions();
        let (off_x, off_y) = (i64::from(layer.offset.0), i64::from(layer.offset.1));
        let lx0 = (-off_x).max(0);
        let ly0 = (-off_y).max(0);
        let lx1 = (i64::from(self.width) - off_x).min(i64::from(lw));
        let ly1 = (i64::from(self.height) - off_y).min(i64::from(lh));
        if lx0 >= lx1 || ly0 >= ly1 {
            // The canvas-frame overlay cannot reach any layer pixel; fail
            // instead of minting an unchanged copy (which would register a
            // phantom undo step in the app).
            return None;
        }
        let mut pixels = (*layer.pixels).clone();
        let raw: &mut [u8] = &mut pixels;
        for ly in ly0..ly1 {
            for lx in lx0..lx1 {
                let cx = (lx + off_x) as u64;
                let cy = (ly + off_y) as u64;
                let si = ((cy * u64::from(self.width) + cx) * 4) as usize;
                let di = ((ly as u64 * u64::from(lw) + lx as u64) * 4) as usize;
                let sp = [src[si], src[si + 1], src[si + 2], src[si + 3]];
                let dp: &mut [u8] = &mut raw[di..di + 4];
                paint_pixel(dp, sp, mode, a);
            }
        }
        self.with_layer_pixels(idx, pixels)
    }

    /// Rotates the whole document 90 degrees clockwise.
    pub fn rotate90(&self) -> Self {
        let ch = i64::from(self.height);
        self.geometry(self.height, self.width, Geometry::Rotate90, |l, _lw, lh| {
            (saturating_i32(ch - i64::from(l.offset.1) - lh), l.offset.0)
        })
    }

    /// Rotates the whole document 180 degrees.
    pub fn rotate180(&self) -> Self {
        let (cw, ch) = (i64::from(self.width), i64::from(self.height));
        self.geometry(self.width, self.height, Geometry::Rotate180, |l, lw, lh| {
            (
                saturating_i32(cw - i64::from(l.offset.0) - lw),
                saturating_i32(ch - i64::from(l.offset.1) - lh),
            )
        })
    }

    /// Rotates the whole document 90 degrees counter-clockwise.
    pub fn rotate270(&self) -> Self {
        let cw = i64::from(self.width);
        self.geometry(
            self.height,
            self.width,
            Geometry::Rotate270,
            |l, lw, _lh| (l.offset.1, saturating_i32(cw - i64::from(l.offset.0) - lw)),
        )
    }

    /// Mirrors the whole document left-right.
    pub fn flip_horizontal(&self) -> Self {
        let cw = i64::from(self.width);
        self.geometry(self.width, self.height, Geometry::FlipH, |l, lw, _lh| {
            (saturating_i32(cw - i64::from(l.offset.0) - lw), l.offset.1)
        })
    }

    /// Mirrors the whole document top-bottom.
    pub fn flip_vertical(&self) -> Self {
        let ch = i64::from(self.height);
        self.geometry(self.width, self.height, Geometry::FlipV, |l, _lw, lh| {
            (l.offset.0, saturating_i32(ch - i64::from(l.offset.1) - lh))
        })
    }

    /// Applies one exact geometric transform to every layer's pixels AND its
    /// mask (which must stay the same size as the pixels), with `f` supplying
    /// each layer's new offset from its old one and its pixel dimensions.
    fn geometry(
        &self,
        new_w: u32,
        new_h: u32,
        geom: Geometry,
        f: impl Fn(&Layer, i64, i64) -> (i32, i32),
    ) -> Self {
        let layers = self
            .layers
            .iter()
            .map(|l| {
                let (lw, lh) = l.pixels.dimensions();
                Layer {
                    pixels: Arc::new(geom.apply(&*l.pixels)),
                    mask: l.mask.as_ref().map(|m| Arc::new(geom.apply(&**m))),
                    offset: f(l, i64::from(lw), i64::from(lh)),
                    ..l.clone()
                }
            })
            .collect();
        RzDocument {
            width: new_w,
            height: new_h,
            layers,
        }
    }

    /// Moves the canvas window: canvas becomes `w` x `h`, offsets shift by
    /// (-x, -y), layer pixels untouched. Bounds-checked against the canvas
    /// like `rz_image_crop`.
    ///
    /// Nothing changes in layer space — pixels outside the new canvas are
    /// retained rather than trimmed — so masks and meta ride along untouched:
    /// a mask is layer-space, and moving the window past it keeps it hiding
    /// exactly the same pixels.
    ///
    /// `None` for an empty or out-of-bounds rect, and for the whole canvas
    /// (0, 0, width, height) — that window IS the current one, and returning
    /// an identical copy would register a phantom undo step in the host.
    pub fn crop(&self, x: u32, y: u32, w: u32, h: u32) -> Option<Self> {
        if w == 0 || h == 0 {
            return None;
        }
        let x_end = x.checked_add(w)?;
        let y_end = y.checked_add(h)?;
        if x_end > self.width || y_end > self.height {
            return None;
        }
        if x == 0 && y == 0 && w == self.width && h == self.height {
            return None;
        }
        let layers = self
            .layers
            .iter()
            .map(|l| Layer {
                offset: (
                    saturating_i32(i64::from(l.offset.0) - i64::from(x)),
                    saturating_i32(i64::from(l.offset.1) - i64::from(y)),
                ),
                ..l.clone()
            })
            .collect();
        Some(RzDocument {
            width: w,
            height: h,
            layers,
        })
    }

    /// Changes the canvas size without scaling anything: the canvas becomes
    /// `w` x `h` and every layer's offset shifts by `origin` — where the old
    /// canvas's top-left corner lands in the new canvas. Layer pixels are
    /// untouched; content outside the new canvas is retained, as with crop.
    ///
    /// Growing or shrinking the canvas is a pure offset change, so — exactly
    /// as in [`RzDocument::crop`] — masks and meta ride along untouched.
    pub fn canvas_resize(&self, w: u32, h: u32, origin: (i32, i32)) -> Option<Self> {
        if w == 0 || h == 0 || u64::from(w) * u64::from(h) > MAX_PIXELS {
            return None;
        }
        let layers = self
            .layers
            .iter()
            .map(|l| Layer {
                offset: (
                    saturating_i32(i64::from(l.offset.0) + i64::from(origin.0)),
                    saturating_i32(i64::from(l.offset.1) + i64::from(origin.1)),
                ),
                ..l.clone()
            })
            .collect();
        Some(RzDocument {
            width: w,
            height: h,
            layers,
        })
    }

    /// Scales the canvas and every layer (sizes and offsets) proportionally.
    /// The total-pixel guard applies to the canvas, as in `rz_image_resize`.
    pub fn resize(&self, w: u32, h: u32, filter: FilterType) -> Option<Self> {
        if w == 0 || h == 0 || u64::from(w) * u64::from(h) > MAX_PIXELS {
            return None;
        }
        let fx = f64::from(w) / f64::from(self.width);
        let fy = f64::from(h) / f64::from(self.height);
        let layers = self
            .layers
            .iter()
            .map(|l| {
                let (lw, lh) = l.pixels.dimensions();
                let nw = ((f64::from(lw) * fx).round() as u32).max(1);
                let nh = ((f64::from(lh) * fy).round() as u32).max(1);
                Layer {
                    pixels: Arc::new(imageops::resize(&*l.pixels, nw, nh, filter)),
                    // The mask scales with the layer, staying the same size.
                    mask: l
                        .mask
                        .as_ref()
                        .map(|m| Arc::new(imageops::resize(&**m, nw, nh, filter))),
                    offset: (
                        saturating_i32((f64::from(l.offset.0) * fx).round() as i64),
                        saturating_i32((f64::from(l.offset.1) * fy).round() as i64),
                    ),
                    ..l.clone()
                }
            })
            .collect();
        Some(RzDocument {
            width: w,
            height: h,
            layers,
        })
    }
}

fn saturating_i32(v: i64) -> i32 {
    v.clamp(i64::from(i32::MIN), i64::from(i32::MAX)) as i32
}

// ------------------------------------------------------------ layer masks --

/// What a freshly added layer mask is filled with.
pub enum MaskKind<'a> {
    /// Fully visible everywhere (255).
    RevealAll,
    /// Fully hidden everywhere (0).
    HideAll,
    /// A CANVAS-sized coverage buffer (`width * height` bytes, row 0 top —
    /// the selection convention shared with `bucket_fill` and `gradient`),
    /// cropped to the layer's rect. Layer pixels lying outside the canvas get
    /// 0, since a selection never extends past the canvas.
    FromSelection(&'a [u8]),
}

impl RzDocument {
    /// Gives layer `idx` a mask (replacing any existing one) and enables it.
    /// The mask is created at exactly the layer's pixel dimensions. `None` on
    /// an out-of-range index or a `FromSelection` buffer that is not
    /// canvas-sized.
    pub fn add_mask(&self, idx: usize, kind: MaskKind) -> Option<Self> {
        let layer = self.layer(idx)?;
        let (lw, lh) = layer.pixels.dimensions();
        let (off_x, off_y) = (i64::from(layer.offset.0), i64::from(layer.offset.1));
        let mask = match kind {
            MaskKind::RevealAll => GrayImage::from_pixel(lw, lh, Luma([255])),
            MaskKind::HideAll => GrayImage::new(lw, lh),
            MaskKind::FromSelection(sel) => {
                let canvas_px = (self.width as usize).checked_mul(self.height as usize)?;
                if sel.len() != canvas_px {
                    return None;
                }
                GrayImage::from_fn(lw, lh, |x, y| {
                    let cx = i64::from(x) + off_x;
                    let cy = i64::from(y) + off_y;
                    if cx < 0
                        || cy < 0
                        || cx >= i64::from(self.width)
                        || cy >= i64::from(self.height)
                    {
                        return Luma([0]);
                    }
                    Luma([sel[cy as usize * self.width as usize + cx as usize]])
                })
            }
        };
        self.with_layer(idx, |l| {
            l.mask = Some(Arc::new(mask));
            l.mask_enabled = true;
        })
    }

    /// Drops layer `idx`'s mask. With `apply`, the mask is first baked into
    /// the layer's alpha (`alpha' = alpha * mask / 255`, straight alpha)
    /// REGARDLESS of `mask_enabled` — "apply" always means what it says — so
    /// the projection is unchanged for an enabled mask. `None` if the layer
    /// has no mask.
    pub fn remove_mask(&self, idx: usize, apply: bool) -> Option<Self> {
        let layer = self.layer(idx)?;
        let mask = layer.mask.as_deref()?;
        let baked = (apply && mask.dimensions() == layer.pixels.dimensions()).then(|| {
            let mut pixels = (*layer.pixels).clone();
            for (px, cov) in pixels.pixels_mut().zip(mask.pixels()) {
                px[3] = (f32::from(px[3]) * f32::from(cov[0]) / 255.0).round() as u8;
            }
            pixels
        });
        self.with_layer(idx, |l| {
            if let Some(pixels) = baked {
                l.pixels = Arc::new(pixels);
            }
            l.mask = None;
            l.mask_enabled = true;
        })
    }

    /// Enables or disables layer `idx`'s mask (a disabled mask is retained but
    /// ignored while compositing). `None` if the layer has no mask.
    pub fn set_mask_enabled(&self, idx: usize, enabled: bool) -> Option<Self> {
        self.layer(idx)?.mask.as_ref()?;
        self.with_layer(idx, |l| l.mask_enabled = enabled)
    }

    /// Paints layer `idx`'s mask with a canvas-frame PREMULTIPLIED RGBA8
    /// overlay (`overlay`, exactly canvas w*h*4 bytes — the same buffer
    /// `painting_layer` takes), mapped through the layer's offset: each mask
    /// pixel samples the overlay at its canvas position, and
    /// `mask' = round(lerp(mask, luma(straight colour), overlay alpha))`.
    /// Painting white therefore reveals and black hides, with the stroke's
    /// own anti-aliasing (and any selection clipping the caller already
    /// applied to the overlay) carried by the alpha. Overlay pixels outside
    /// the layer are ignored; `None` if the layer has no mask, the buffer is
    /// the wrong size, or the layer's extent misses the canvas entirely (no
    /// mask pixel could change), matching `painting_layer`.
    pub fn paint_mask(&self, idx: usize, overlay: &[u8]) -> Option<Self> {
        let layer = self.layer(idx)?;
        let mask = layer.mask.as_deref()?;
        let expected = (self.width as usize)
            .checked_mul(self.height as usize)?
            .checked_mul(4)?;
        if overlay.len() != expected {
            return None;
        }
        let (lw, lh) = layer.pixels.dimensions();
        if mask.dimensions() != (lw, lh) {
            return None;
        }
        let (off_x, off_y) = (i64::from(layer.offset.0), i64::from(layer.offset.1));
        let lx0 = (-off_x).max(0);
        let ly0 = (-off_y).max(0);
        let lx1 = (i64::from(self.width) - off_x).min(i64::from(lw));
        let ly1 = (i64::from(self.height) - off_y).min(i64::from(lh));
        if lx0 >= lx1 || ly0 >= ly1 {
            return None;
        }
        let mut painted = mask.clone();
        let raw: &mut [u8] = &mut painted;
        for ly in ly0..ly1 {
            for lx in lx0..lx1 {
                let cx = (lx + off_x) as u64;
                let cy = (ly + off_y) as u64;
                let si = ((cy * u64::from(self.width) + cx) * 4) as usize;
                let a = f32::from(overlay[si + 3]) / 255.0;
                if a <= 0.0 {
                    continue;
                }
                // Unpremultiplying and taking the luma is one division: luma
                // is linear, so luma(c / a) == luma(c) / a.
                let luma = (LUMA_R * f32::from(overlay[si])
                    + LUMA_G * f32::from(overlay[si + 1])
                    + LUMA_B * f32::from(overlay[si + 2]))
                    / a;
                let luma = luma.clamp(0.0, 255.0);
                let di = (ly as u64 * u64::from(lw) + lx as u64) as usize;
                let m = f32::from(raw[di]);
                raw[di] = (m + (luma - m) * a).clamp(0.0, 255.0).round() as u8;
            }
        }
        self.with_layer(idx, |l| l.mask = Some(Arc::new(painted)))
    }

    /// Layer `idx`'s mask expanded to an opaque grayscale RGBA image (for the
    /// layers-panel thumbnail); `None` if the layer has no mask.
    pub fn mask_image(&self, idx: usize) -> Option<RgbaImage> {
        let mask = self.layer(idx)?.mask.as_deref()?;
        let (mw, mh) = mask.dimensions();
        Some(RgbaImage::from_fn(mw, mh, |x, y| {
            let v = mask.get_pixel(x, y)[0];
            image::Rgba([v, v, v, 255])
        }))
    }
}

// ------------------------------------------------------------------- open --

impl RzDocument {
    /// Opens a document, sniffing the container: "RZDC" is the native format,
    /// "8BPS" a Photoshop document (layered import), anything else decodes
    /// via the `RzImage::open` rules to a single "Background" layer.
    pub fn open(path: &str) -> Result<Self, String> {
        let bytes = std::fs::read(path).map_err(|e| format!("failed to read {path}: {e}"))?;
        if bytes.len() >= 4 && &bytes[..4] == b"RZDC" {
            crate::rzdc::parse_native(&bytes)
                .map_err(|e| format!("failed to read document {path}: {e}"))
        } else if bytes.len() >= 4 && &bytes[..4] == b"8BPS" {
            crate::psd::open_psd(&bytes, path)
        } else {
            drop(bytes);
            Ok(RzDocument::from_pixels(RzImage::open(path)?.pixels))
        }
    }
}
