//! Layered document model: `RzDocument` (canvas + bottom-to-top layer
//! stack), the f32 compositing projection, document ops, and per-layer
//! masks. See include/rasterize_core.h for the contract. The blend-mode
//! table and blend math live in `blend`, the RZDC native format in `rzdc`,
//! and layered PSD import in `psd`. Layer styles (the effect stack, fill
//! opacity, Blend If, the global light) live in `style`, are rendered by
//! `style_render` and composited by `style_composite`; this module only
//! routes styled layers there. LAYER GROUPS — the nesting marked on each
//! entry, the invariant that keeps it well formed, and the recursive
//! compositor this module's projection wires up — live in `doc_group`, with
//! the per-entry geometry and link queries in `doc_group_query` and the lock
//! bits in `doc_lock`. Layer pixel and mask buffers are `Arc`-shared so
//! document copies are copy-on-write.

use std::cell::Cell;
use std::sync::Arc;

use image::imageops::{self, FilterType};
use image::{GenericImageView, GrayImage, ImageBuffer, Luma, Pixel, RgbaImage};

use crate::adjust::Adjustment;
use crate::blend::{
    blend_kind, composite_buffer_into, composite_source_into, dissolve_threshold, paint_pixel,
    BlendKind,
};
use crate::doc_align;
use crate::doc_channel::{self, Channel};
use crate::doc_group;
use crate::doc_lock::EditKind;
use crate::doc_plane::channel_lerp;
use crate::icc::IccProfile;
use crate::metadata::{Metadata, Resolution};
use crate::ops::CompositeMode;
use crate::style::{scaled_style, GlobalLight, LayerStyle};
use crate::style_composite::{composite_styled_into, merge_extent, CompositeEnv};
use crate::RzImage;

pub use crate::blend::BlendMode;

/// Largest permitted canvas or merged-extent size, in total pixels (matches
/// the `rz_image_resize` guard). The FFI applies it to caller-declared layer
/// buffer dimensions too, so absurd dimensions are refused rather than read.
pub(crate) const MAX_PIXELS: u64 = 100_000_000;

// ------------------------------------------------------------------ model --

/// What an entry in the stack IS. A GROUP is a container with no pixels of
/// its own; its children are the entries immediately BELOW it at greater
/// depth (see `doc_group`, whose module doc is the layout's specification).
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
#[repr(i32)]
pub enum LayerKind {
    Raster = 0,
    Group = 1,
}

impl LayerKind {
    /// Maps a raw `RzLayerKind` value coming across the FFI or out of a `.rz`
    /// record; `None` for anything else, which the reader refuses rather
    /// than repairs (a kind it cannot name is a structural claim, not a
    /// cosmetic one).
    pub fn from_c(value: i32) -> Option<Self> {
        match value {
            0 => Some(LayerKind::Raster),
            1 => Some(LayerKind::Group),
            _ => None,
        }
    }

    /// The `RzLayerKind` value for the FFI.
    pub fn to_c(self) -> i32 {
        self as i32
    }
}

/// One entry in the stack: either a raster layer — straight-alpha RGBA8
/// pixels of the layer's own size, an integer canvas offset, and display
/// properties — or a GROUP, which carries the same display properties over
/// the children below it and no pixels of its own. The pixel buffer is
/// immutable and shared (`Arc`), so cloning a layer is cheap.
#[derive(Clone)]
pub struct Layer {
    /// Straight-alpha RGBA8 pixels, the layer's own size.
    pub pixels: Arc<RgbaImage>,
    /// Canvas position of the layer's top-left pixel. On a GROUP, which has
    /// no pixels of its own, it is instead where its CANVAS-sized mask sits:
    /// a group's mask travels with the group as bookkeeping on this offset
    /// rather than as a resample per move, so a drag out and back restores it
    /// exactly (`doc_align::translate_entry`). It stays (0, 0) on a group
    /// with no mask.
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
    /// Clipping-mask flag (Photoshop semantics): a clipped entry is confined
    /// to the alpha footprint of the first UNCLIPPED SIBLING beneath it —
    /// WITHIN ITS LEVEL — which is its base. Structure is purely positional:
    /// [`RzDocument::flattened`] re-derives both the nesting and the base +
    /// consecutive-clipped-run groups on every composite, so reordering or
    /// deleting entries needs no bookkeeping. A clipped entry at the bottom
    /// of its level (no unclipped sibling below) has no base and composites
    /// as if unclipped. Copied on duplicate like every other property.
    pub clipped: bool,
    /// Layer style (effects + blending options); see `style`. Rides along
    /// like meta, dropped by merge/flatten (which bake it), copied by
    /// duplicate, scaled by the transforms. Never an identity style (the
    /// setter clears those), so `Some` means "renders something".
    pub style: Option<Arc<LayerStyle>>,
    /// Raster or group. A GROUP's `pixels` is a private 1x1 fully
    /// transparent buffer that nothing ever reads: it exists so a group is
    /// a `Layer` (every FFI export addresses entries by index) and so its
    /// `Arc` address is unique — the layer-style plane cache keys on that
    /// address (`style_cache::CacheKey::of`), and a shared dummy would make
    /// two styled groups render each other's effects.
    pub kind: LayerKind,
    /// Nesting depth: 0 at the top level, one more inside each enclosing
    /// group. See `doc_group` for the ONE invariant this participates in and
    /// for why that invariant is checked at runtime.
    pub depth: u16,
    /// Lock flags: bit 0 transparency, bit 1 pixels, bit 2 position (PSD's
    /// `lspf` order). All three set is "Lock All". Bits 3..31 are reserved
    /// and are masked off wherever a value enters. See `doc_lock`.
    pub locks: u32,
    /// Link group: 0 unlinked, otherwise every entry carrying the same value
    /// moves and transforms with this one. Ids are the smallest unused
    /// non-zero value, so a `.rz` round trip is byte-identical. See
    /// `doc_group_query`.
    pub link: u32,
    /// Whether the panel shows a GROUP expanded. Meaningless on a raster
    /// entry (kept `true` there). Document state so it survives a save, like
    /// Photoshop's.
    pub open: bool,
}

impl Layer {
    /// A plain RASTER layer at offset (0, 0), at the top level: fully
    /// opaque, Normal, visible, unclipped, unlocked, unlinked, with no mask
    /// and no meta. `pub(crate)` because `doc_structure`'s merge, stamp and
    /// Via Copy each end with exactly this layer — one constructor, so a new
    /// `Layer` field can never be forgotten at one of them.
    pub(crate) fn new(pixels: RgbaImage, name: &str) -> Self {
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
            style: None,
            kind: LayerKind::Raster,
            depth: 0,
            locks: 0,
            link: 0,
            open: true,
        }
    }

    /// The mask that actually gates compositing: `None` when the layer has no
    /// mask, the mask is disabled, or (defensively — the invariant should
    /// prevent it) its dimensions disagree with the layer's pixels.
    ///
    /// A GROUP's mask is CANVAS-sized by design (`doc_group`), so this
    /// deliberately answers `None` for one, and the compositor never asks:
    /// `doc_group::rendered_group` crops the canvas mask to the group's
    /// extent and hands the SYNTHETIC layer a mask that satisfies the
    /// invariant, which is what makes every mask site below work unchanged.
    pub(crate) fn active_mask(&self) -> Option<&GrayImage> {
        let mask = self.mask.as_deref()?;
        if !self.mask_enabled || mask.dimensions() != self.pixels.dimensions() {
            return None;
        }
        Some(mask)
    }
}

/// A layered document: canvas size plus an ordered layer stack
/// (index 0 = bottom). Always contains at least one ENTRY; an entry may be a
/// group, so a document may hold no pixels at all (an empty group composites
/// to a transparent canvas).
#[derive(Clone)]
pub struct RzDocument {
    /// Canvas width in pixels.
    pub width: u32,
    /// Canvas height in pixels.
    pub height: u32,
    /// Layer stack, bottom first. A FOREST, flattened: a group's children
    /// are the entries immediately below it at greater depth, and the group
    /// entry is the last record of its own subtree. `doc_group` owns the
    /// layout, its invariant and the walk.
    pub layers: Vec<Layer>,
    /// Shared light direction every "use global light" effect reads.
    pub global_light: GlobalLight,
    /// Named canvas-sized coverage planes — saved selections. See
    /// `doc_channel`; they never composite.
    pub channels: Vec<Channel>,
    /// The document's working colour space: the ICC profile its pixel
    /// numbers belong to, embedded on export. Defaults to the built-in
    /// sRGB and is never absent — an untagged file is assumed sRGB at open,
    /// which is what every reader does anyway and what gives the display,
    /// the export and the transform exactly one rule. See `doc_color`.
    pub profile: Arc<IccProfile>,
    /// EXIF / XMP / IPTC packets, verbatim and uninterpreted. See
    /// `metadata`.
    pub metadata: Metadata,
    /// Print resolution in ppi; 72 x 72 by default. Pixels never change with
    /// it — only the print size does. See `metadata::Resolution`.
    pub resolution: Resolution,
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
/// A GROUP entry never reaches this function as itself: `doc_group` renders
/// an isolated group into a private buffer and hands the result over as a
/// synthetic raster layer, so everything below is written for pixels and
/// needs no group branch.
///
/// A layer whose meta parses as an [`Adjustment`] is routed to
/// [`composite_adjustment_into`] instead — every projection (flatten, render,
/// export, merge-down) goes through this function, so adjustment layers
/// behave identically everywhere. A layer carrying a style is routed to
/// `style_composite` (its effects rendered under `env`: the global light
/// and the document canvas) — after the adjustment check, so adjustment
/// layers ignore styles by construction. (`env` also carries the conversion
/// an authored style colour takes into the document's colour space — see
/// `style_composite`, which applies it where a contribution's colour is
/// read.)
pub(crate) fn composite_layer_into(
    acc: &mut [[f32; 4]],
    acc_w: u32,
    acc_h: u32,
    origin: (i32, i32),
    layer: &Layer,
    env: CompositeEnv<'_>,
) {
    let opacity = sane_opacity(layer.opacity);
    if opacity <= 0.0 {
        return;
    }
    // A GROUP's meta is the host's alone: the core never interprets it, so
    // a group whose blob happened to parse as an adjustment cannot silently
    // become an adjustment layer. (Reached only defensively — the compositor
    // hands this function a group's SYNTHETIC layer, which carries no meta.)
    if layer.kind != LayerKind::Group {
        if let Some(adjustment) = layer.meta.as_deref().and_then(Adjustment::from_meta) {
            composite_adjustment_into(acc, acc_w, acc_h, origin, layer, &adjustment, opacity);
            return;
        }
    }
    if let Some(style) = layer.renders_style() {
        composite_styled_into(acc, acc_w, acc_h, origin, layer, &[], style, opacity, env);
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
    // A SPATIAL adjustment (Shadows/Highlights) weights its lift by a
    // large-radius ALPHA-WEIGHTED blur of the backdrop's luma. The plane is
    // built ONCE here, from the accumulator, and read per pixel below; every
    // other op returns None and pays nothing (`adjust::Adjustment::guide`).
    let guide = adjustment.guide(acc_w, acc_h, &|i| acc[i]);
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
            let canvas_xy = (ax + i64::from(origin.0), ay + i64::from(origin.1));
            // 0.0 for a guide-less op: `apply_at`'s guide argument is only
            // ever read by an op whose `guide` returned a plane.
            let g = guide
                .as_ref()
                .map_or(0.0, |plane| plane.at(ax as u32, ay as u32));
            let adjusted = adjustment.apply_at(cb, g, canvas_xy);
            if let BlendKind::Dissolve = kind {
                let (cx, cy) = canvas_xy;
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
            // k == 1 — a full-opacity, unmasked adjustment, the common case
            // — takes the blended value VERBATIM rather than lerping to it.
            // `cb + (e - cb) * 1.0` is not the floating-point identity: the
            // subtraction and the add each round, so the result can land one
            // ULP below `e` and quantize to a different byte wherever `e`
            // sits on an exact half-code (30.5/255, say). Verbatim is what
            // makes an adjustment LAYER byte-identical to its destructive
            // twin instead of merely within one step of it.
            if k >= 1.0 {
                acc[ai][..3].copy_from_slice(&effective);
            } else {
                for c in 0..3 {
                    acc[ai][c] = cb[c] + (effective[c] - cb[c]) * k;
                }
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
/// over an adjustment base contributes nothing. A STYLED base with a
/// non-empty group is routed to `style_composite`, which renders its below
/// effects once, the group as the interior unit, then its interior effects.
pub(crate) fn composite_clip_group_into(
    acc: &mut [[f32; 4]],
    acc_w: u32,
    acc_h: u32,
    origin: (i32, i32),
    base: &Layer,
    group: &[Layer],
    env: CompositeEnv<'_>,
) {
    if group.is_empty() {
        composite_layer_into(acc, acc_w, acc_h, origin, base, env);
        return;
    }
    let opacity = sane_opacity(base.opacity);
    if opacity <= 0.0 {
        return;
    }
    if let Some(style) = base.renders_style() {
        composite_styled_into(acc, acc_w, acc_h, origin, base, group, style, opacity, env);
        return;
    }
    let mut buf = vec![[0.0f32; 4]; acc.len()];
    let full = Layer {
        opacity: 1.0,
        blend: BlendMode::Normal,
        style: None,
        ..base.clone()
    };
    composite_layer_into(&mut buf, acc_w, acc_h, origin, &full, env);
    let base_alpha: Vec<f32> = buf.iter().map(|px| px[3]).collect();
    for layer in group.iter().filter(|l| l.visible) {
        composite_layer_into(&mut buf, acc_w, acc_h, origin, layer, env);
        for (px, &a) in buf.iter_mut().zip(&base_alpha) {
            px[3] = a;
        }
    }
    // The group buffer is accumulator-aligned (same size, same origin), so
    // this is composite_layer_into's kernel with an f32 source and the
    // base's mode and opacity (blend::composite_buffer_into). Pixels a
    // clipped layer touched outside the footprint carry color at forced
    // alpha 0 and are skipped there.
    composite_buffer_into(
        acc,
        &buf,
        acc_w,
        acc_h,
        origin,
        blend_kind(base.blend),
        opacity,
    );
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

    /// True for the two quarter turns, which exchange the canvas's width and
    /// height — and with them the document's two print resolutions.
    pub(crate) fn swaps_axes(self) -> bool {
        matches!(self, Geometry::Rotate90 | Geometry::Rotate270)
    }
}

/// Quantizes a straight-alpha f32 accumulator to RGBA8. The ONE quantizer:
/// the document's projection and every isolated group's private projection
/// (`doc_group::rendered_group`) both end here, so a group boundary rounds
/// exactly the way the canvas does.
pub(crate) fn quantize(acc: &[[f32; 4]], w: u32, h: u32) -> RgbaImage {
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
            global_light: GlobalLight::default(),
            channels: Vec::new(),
            // Bare pixels are assumed sRGB with no metadata and a 72 ppi
            // print size; `RzDocument::open` overwrites all three from
            // whatever the file said.
            profile: IccProfile::srgb(),
            metadata: Metadata::default(),
            resolution: Resolution::default(),
        }
    }

    fn layer(&self, idx: usize) -> Option<&Layer> {
        self.layers.get(idx)
    }

    /// Entry `idx` when it is a RASTER layer — the accessor every
    /// pixel-writing op uses in place of [`Self::layer`], so "a group has no
    /// pixels of its own, refuse" is written once instead of at each of the
    /// nineteen sites that need it. `None` for an out-of-range index and for
    /// a group.
    pub(crate) fn raster_layer(&self, idx: usize) -> Option<&Layer> {
        let layer = self.layers.get(idx)?;
        (layer.kind == LayerKind::Raster).then_some(layer)
    }

    /// Canvas-sized straight-alpha projection of all visible layers,
    /// composited bottom-to-top in f32 and quantized once at the end.
    ///
    /// The walk re-derives the whole structure positionally on every call —
    /// the NESTING and, within each level, the CLIP GROUPS — and lives in
    /// [`doc_group::composite_level_into`], which this function only wires
    /// up: build the accumulator, the style-colour transform, the group
    /// allocation budget and the top level, composite, quantize once. Within
    /// a level each unclipped entry is a BASE and the consecutive run of
    /// clipped entries immediately above it composites with it as one unit
    /// through [`composite_clip_group_into`], confined to the base's alpha
    /// footprint. An invisible base hides its whole group; clipped entries at
    /// the BOTTOM of their level have no base and composite as if unclipped.
    /// A base with no clipped entries above composites exactly as it always
    /// did — a document with no groups in it takes byte-for-byte the path it
    /// took before groups existed.
    pub fn flattened(&self) -> RgbaImage {
        let px = self.width as usize * self.height as usize;
        let mut acc = vec![[0.0f32; 4]; px];
        // Built once for the whole projection and borrowed by every styled
        // layer (`style_composite`): the conversion an authored layer-style
        // colour takes into this document's space.
        let colors = self.style_colors();
        let env = self.composite_env(colors.as_ref());
        // The allocation budget every isolated group charges before it makes
        // a buffer (`doc_group::MAX_GROUP_BUFFER_PIXELS`): one projection,
        // one budget, so a nest of groups cannot ask for tens of gigabytes.
        let budget = Cell::new(0u64);
        let level = doc_group::top_level(&self.layers);
        doc_group::composite_level_into(
            &mut acc,
            self.width,
            self.height,
            (0, 0),
            &self.layers,
            &level,
            env,
            0,
            &budget,
        );
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
    /// For a GROUP the answer is its RAW projection on that same buffer —
    /// its children composited among themselves, WITHOUT the group's own
    /// opacity, blend mode, mask or style, which keeps this export's
    /// "deliberately raw" contract exactly.
    ///
    /// None for an out-of-range `idx`; an empty canvas or a layer entirely
    /// off-canvas simply yields a fully transparent buffer.
    pub fn layer_canvas_image(&self, idx: usize) -> Option<RgbaImage> {
        let layer = self.layers.get(idx)?;
        if layer.kind == LayerKind::Group {
            return self.group_projection(idx);
        }
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

    /// Pure setter: replaces layer `idx`'s name. `None` when it already
    /// carries that name — see [`Self::with_layer`]'s note on the latch.
    pub fn with_layer_name(&self, idx: usize, name: &str) -> Option<Self> {
        if self.layer(idx)?.name == name {
            return None;
        }
        self.with_layer(idx, |l| l.name = name.to_string())
    }

    /// Pure setter: replaces layer `idx`'s opacity (clamped to [0, 1]).
    /// `None` when the clamped value is the one already stored.
    pub fn with_layer_opacity(&self, idx: usize, opacity: f32) -> Option<Self> {
        let opacity = sane_opacity(opacity);
        if self.layer(idx)?.opacity == opacity {
            return None;
        }
        self.with_layer(idx, |l| l.opacity = opacity)
    }

    /// Pure setter: replaces entry `idx`'s blend mode. `None` — a domain
    /// refusal — for `BlendMode::PassThrough` on a RASTER layer: pass-through
    /// is a group's declaration that it has no footprint of its own, and a
    /// leaf carrying it would have no defined meaning. `None` too when the
    /// entry is already in that mode.
    pub fn with_layer_blend_mode(&self, idx: usize, mode: BlendMode) -> Option<Self> {
        let layer = self.layer(idx)?;
        if (mode.is_group_only() && layer.kind != LayerKind::Group) || layer.blend == mode {
            return None;
        }
        self.with_layer(idx, |l| l.blend = mode)
    }

    /// Pure setter: replaces layer `idx`'s visibility flag. `None` when the
    /// flag already has that value.
    pub fn with_layer_visible(&self, idx: usize, visible: bool) -> Option<Self> {
        if self.layer(idx)?.visible == visible {
            return None;
        }
        self.with_layer(idx, |l| l.visible = visible)
    }

    /// Pure setter: replaces layer `idx`'s clipped flag (see [`Layer::clipped`]).
    pub fn with_layer_clipped(&self, idx: usize, clipped: bool) -> Option<Self> {
        self.with_layer(idx, |l| l.clipped = clipped)
    }

    /// Pure setter: replaces layer `idx`'s canvas offset.
    ///
    /// A GROUP has no pixel BUFFER of its own, so this SHIFTS its whole
    /// subtree instead: every raster descendant moves by the delta that puts
    /// the group's rect origin at `(x, y)`. That rect is
    /// [`Self::layer_pixel_rect`] — the union of its descendants' buffer
    /// rects, which is exactly what `rz_doc_layer_offset_x/y/width/height`
    /// report for a group, so reading an entry's offset and writing it back
    /// is the identity on both kinds of entry. (`layer_bounds`, the CONTENT
    /// box, is a different rectangle and belongs to align and distribute; it
    /// also costs a per-pixel scan, which a property setter has no business
    /// paying.) `None` for a group holding no raster descendant — there is no
    /// origin to move.
    ///
    /// A POSITION edit under `doc_lock`, so a position-locked entry (or a
    /// group holding one) refuses it. It deliberately does NOT follow LINKS:
    /// it is a property write, not a move — [`Self::move_layers`] is the op
    /// that means "move this".
    ///
    /// `None` for a move of zero — writing back the offset just read — on
    /// either kind of entry, like every other property setter here.
    pub fn with_layer_offset(&self, idx: usize, x: i32, y: i32) -> Option<Self> {
        self.under_locks(idx, EditKind::Position, |doc| {
            let entry = doc.layer(idx)?;
            if entry.kind == LayerKind::Group {
                let (bx, by, _, _) = doc.layer_pixel_rect(idx)?;
                let dx = i64::from(x) - i64::from(bx);
                let dy = i64::from(y) - i64::from(by);
                if dx == 0 && dy == 0 {
                    return None;
                }
                let mut out = doc.clone();
                let (mdx, mdy) = (saturating_i32(dx), saturating_i32(dy));
                // Every entry of the subtree through the ONE translate the
                // Move tool's drag also uses, so a nested group's canvas-sized
                // MASK travels with it exactly as a layer's buffer does — as
                // bookkeeping on its offset, never as a resample.
                for i in doc_group::subtree(&doc.layers, idx) {
                    doc_align::translate_entry(&mut out.layers, i, mdx, mdy);
                }
                return Some(out);
            }
            if entry.offset == (x, y) {
                return None;
            }
            doc.with_layer(idx, |l| l.offset = (x, y))
        })
    }

    /// Pure setter: replaces layer `idx`'s pixels (any size; offset and
    /// properties kept). A mask survives a same-size replacement (the paint
    /// and fill ops rely on that) but is dropped when the new pixels have
    /// different dimensions, which would otherwise break the mask's
    /// same-size-as-the-layer invariant.
    /// `None` on a GROUP index: a group has no pixels of its own.
    ///
    /// A PIXELS edit under `doc_lock`. It is the funnel almost every pixel op
    /// ends in, so those ops pay the lock gate twice — once at their own entry
    /// point and once here. That is deliberate: the gate is idempotent (a
    /// second alpha restore changes nothing), it costs one extra buffer clone
    /// only on a transparency-locked layer, and it means this export honours
    /// locks on its own, which it must — the host calls it directly.
    pub fn with_layer_pixels(&self, idx: usize, pixels: RgbaImage) -> Option<Self> {
        self.raster_layer(idx)?;
        self.under_locks(idx, EditKind::Pixels, move |doc| {
            doc.with_layer(idx, |l| {
                if l.mask
                    .as_ref()
                    .is_some_and(|m| m.dimensions() != pixels.dimensions())
                {
                    l.mask = None;
                    l.mask_enabled = true;
                }
                l.pixels = Arc::new(pixels);
            })
        })
    }

    /// Clone-then-mutate for one entry. It cannot tell whether `edit` changed
    /// anything, so the LATCH — the purity rule's "an op that would change
    /// nothing returns None, never an identical copy", without which a host's
    /// read-modify-write registers a phantom undo step and dirties the
    /// document — lives in each property setter above, which compares the one
    /// field it writes before it gets here.
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

    /// Inserts a layer with the given pixels (offset 0) above `idx`: at
    /// `idx`'s own depth, immediately above its whole SUBTREE, so "above a
    /// group" means above the group and not inside it. Identical to
    /// `insert(idx + 1)` on a document with no groups.
    pub fn adding_image_layer(&self, idx: usize, pixels: RgbaImage, name: &str) -> Option<Self> {
        let depth = self.layer(idx)?.depth;
        let at = doc_group::subtree(&self.layers, idx).end;
        let mut doc = self.clone();
        let mut layer = Layer::new(pixels, name);
        layer.depth = depth;
        doc.layers.insert(at, layer);
        doc_group::validated(doc)
    }

    /// Duplicates entry `idx` (pixels shared, " copy" appended to the name),
    /// inserting the duplicate immediately above it. A GROUP duplicates its
    /// whole SUBTREE, depths preserved and " copy" appended to the group's
    /// name only. Meta and style are copied like every other property; LINKS
    /// are not — a copy is a new object, not a second member of the
    /// original's link group.
    pub fn duplicating_layer(&self, idx: usize) -> Option<Self> {
        self.layer(idx)?;
        let sub = doc_group::subtree(&self.layers, idx);
        let at = sub.end;
        let mut copies: Vec<Layer> = self.layers[sub]
            .iter()
            .map(|l| Layer {
                link: 0,
                ..l.clone()
            })
            .collect();
        copies
            .last_mut()
            .expect("a subtree always contains its own entry")
            .name
            .push_str(" copy");
        let mut doc = self.clone();
        doc.layers.splice(at..at, copies);
        doc_group::validated(doc)
    }

    /// Removes entry `idx` and, for a GROUP, its whole subtree; `None` when
    /// that would leave the document with no entries at all.
    pub fn removing_layer(&self, idx: usize) -> Option<Self> {
        self.layer(idx)?;
        let sub = doc_group::subtree(&self.layers, idx);
        if sub.len() == self.layers.len() {
            return None;
        }
        let mut doc = self.clone();
        doc.layers.drain(sub);
        doc_group::validated(doc)
    }

    /// Removes the entry at `from` (with its subtree) and reinserts it at
    /// `to`, taking the depth of whatever entry sits at `to` — the natural
    /// reading of a panel drag onto a row, and byte-for-byte the old
    /// remove-then-insert on a document with no groups. See
    /// [`RzDocument::move_layer_to`] for the form that names a depth.
    pub fn moving_layer(&self, from: usize, to: usize) -> Option<Self> {
        let depth = self.layer(to)?.depth;
        self.move_layer_to(from, to, depth)
    }

    /// Merges entry `idx` into the previous SIBLING — the entry immediately
    /// below it within its own level, which on a document with no groups is
    /// simply `idx - 1`. The merged layer covers the union of both extents;
    /// BOTH entries' modes and opacities are baked into its pixels via the
    /// same kernel as [`RzDocument::flattened`] (the lower composites onto a
    /// transparent backdrop, where every blend function degenerates to Normal
    /// and Dissolve keeps exactly its dithered pixels), so the result is
    /// Normal at opacity 1 and keeps only the lower entry's name,
    /// visibility, clipped flag, depth, locks and link. An invisible upper
    /// entry contributes nothing (it is simply removed); a hidden LOWER entry
    /// refuses the merge (`None`) so the upper entry's content cannot
    /// silently vanish. `None` too when `idx` is at the BOTTOM of its level
    /// (generalising the old `idx == 0` rule) or out of range, and when the
    /// LOWER entry's locks refuse a merge (`doc_lock::EditKind::Merge`) —
    /// merging replaces that entry's whole picture, which is exactly what
    /// Lock Pixels forbids.
    ///
    /// Either operand may be a GROUP: it is materialized through
    /// [`doc_group::rendered_group`] first — the ONE definition of what a
    /// group's pixels are — so a group merged down (or merged into) becomes
    /// a plain raster entry at the level's depth and its subtree is removed.
    /// A group with nothing visible in it materializes to nothing and simply
    /// contributes nothing, exactly like an invisible layer.
    ///
    /// The merge is destructive, so the merged layer carries neither entry's
    /// mask, meta or layer style: an ENABLED mask is baked into the pixels by
    /// the kernel (like opacity and blend), a disabled one is simply dropped,
    /// meta no longer describes the pixels it is attached to, and both
    /// entries' style effects are baked by the same kernel (the union extent
    /// grows by each one's `style_composite::merge_extent`: the style's
    /// pad, plus the drop shadow's shifted rect clipped to the canvas).
    /// Because the kernel
    /// is shared, merging an ADJUSTMENT layer down bakes the adjustment into
    /// the layer below, gated by its blend mode, opacity and mask.
    ///
    /// A CLIPPED upper entry is baked through its clipping: the pair runs the
    /// same group kernel as the projection ([`composite_clip_group_into`]
    /// with the lower entry as base), so the upper entry's contribution is
    /// alpha-limited to the lower entry's footprint. The merged layer keeps
    /// the LOWER entry's clipped flag (like its name and visibility), so a
    /// merge inside a clip group stays in the group.
    pub fn merging_down(&self, idx: usize) -> Option<Self> {
        let upper_entry = self.layer(idx)?;
        let upper_visible = upper_entry.visible;
        let upper_clipped = upper_entry.clipped;
        let upper_sub = doc_group::subtree(&self.layers, idx);
        let level_start = doc_group::level_range(&self.layers, idx).start;
        if upper_sub.start == level_start {
            return None; // nothing below it inside its own level
        }
        // A sibling's subtree ENDS with its own record, so the entry
        // immediately below this subtree is exactly the previous sibling.
        let lower_idx = upper_sub.start - 1;
        let lower_entry = &self.layers[lower_idx];
        if !lower_entry.visible {
            return None;
        }
        // The DESTINATION's locks, asked before anything is built: the merge
        // drains both subtrees, so this is the last point at which the index
        // still names the entry the lock belongs to (see `doc_lock`).
        if self.lock_block(lower_idx, EditKind::Merge) != 0 {
            return None;
        }
        let lower_sub = doc_group::subtree(&self.layers, lower_idx);
        let merged_name = lower_entry.name.clone();
        let merged_depth = lower_entry.depth;
        let merged_clipped = lower_entry.clipped;
        let merged_locks = lower_entry.locks;
        let merged_link = lower_entry.link;

        let colors = self.style_colors();
        let env = self.composite_env(colors.as_ref());
        let budget = Cell::new(0u64);
        let upper = upper_visible
            .then(|| doc_group::materialized(&self.layers, idx, env, &budget))
            .flatten();
        let lower = doc_group::materialized(&self.layers, lower_idx, env, &budget);

        let mut doc = self.clone();
        doc.layers.drain(upper_sub);
        let Some(upper) = upper else {
            // Nothing to merge in: the upper entry (or the whole group) was
            // invisible or empty, so it is simply removed.
            return doc_group::validated(doc);
        };
        let (mut x0, mut y0, mut x1, mut y1) = merge_extent(&upper, env);
        if let Some(lower) = lower.as_ref() {
            let (lx0, ly0, lx1, ly1) = merge_extent(lower, env);
            x0 = x0.min(lx0);
            y0 = y0.min(ly0);
            x1 = x1.max(lx1);
            y1 = y1.max(ly1);
        }
        let (uw, uh) = ((x1 - x0) as u64, (y1 - y0) as u64);
        if uw == 0 || uh == 0 || uw * uh > MAX_PIXELS {
            return None;
        }
        if x0 < i64::from(i32::MIN) || y0 < i64::from(i32::MIN) {
            return None;
        }
        let origin = (x0 as i32, y0 as i32);
        let mut acc = vec![[0.0f32; 4]; (uw * uh) as usize];
        match lower.as_ref() {
            Some(lower) if upper_clipped => composite_clip_group_into(
                &mut acc,
                uw as u32,
                uh as u32,
                origin,
                lower,
                std::slice::from_ref(&upper),
                env,
            ),
            Some(lower) => {
                composite_layer_into(&mut acc, uw as u32, uh as u32, origin, lower, env);
                composite_layer_into(&mut acc, uw as u32, uh as u32, origin, &upper, env);
            }
            // A clipped upper entry whose base materialized to nothing is
            // baseless, which composites as if unclipped — the same rule the
            // projection applies at the bottom of a level.
            None => composite_layer_into(&mut acc, uw as u32, uh as u32, origin, &upper, env),
        }
        let mut merged = Layer::new(quantize(&acc, uw as u32, uh as u32), &merged_name);
        merged.offset = origin;
        merged.visible = true;
        merged.clipped = merged_clipped;
        merged.depth = merged_depth;
        merged.locks = merged_locks;
        merged.link = merged_link;
        doc.layers.splice(lower_sub, std::iter::once(merged));
        doc_group::validated(doc)
    }

    /// Single-layer document containing the projection, named "Background".
    ///
    /// Like [`RzDocument::merging_down`], this is destructive: the projection
    /// bakes every ENABLED mask and every layer style into the composited
    /// pixels (a disabled mask is simply dropped with its layer), so the
    /// resulting layer carries neither a mask, meta nor style — nothing is
    /// left that could describe those pixels. The document's global light
    /// is a preference, not layer state, and is kept; so are the alpha
    /// channels, which are canvas-sized document state and have nothing to
    /// do with the layer stack being collapsed; and so, for the same reason,
    /// are the colour profile (the flattened pixels are still in that
    /// space), the metadata packets and the print resolution.
    ///
    /// Every one of those five is listed EXPLICITLY: this builds on
    /// `..from_pixels`, so anything not named here is silently replaced by a
    /// default. That applies to the LAYER-level state too, deliberately: the
    /// one surviving entry is a raster layer at depth 0 with no locks, no
    /// link and `open` true, because the whole tree — groups included — has
    /// been collapsed into it.
    pub fn flattening(&self) -> Self {
        RzDocument {
            global_light: self.global_light,
            channels: self.channels.clone(),
            profile: Arc::clone(&self.profile),
            metadata: self.metadata.clone(),
            resolution: self.resolution,
            ..RzDocument::from_pixels(self.flattened())
        }
    }

    /// Paints a canvas-frame PREMULTIPLIED RGBA8 overlay (`src`, exactly
    /// canvas w*h*4 bytes, semantics of `rz_image_composite`) onto layer
    /// `idx`, mapped through the layer's offset. Overlay areas outside the
    /// layer's extent are ignored; if the layer's extent does not intersect
    /// the canvas at all (no pixel could change) the paint is refused
    /// (`None`) rather than returning an unchanged copy, and so is a GROUP
    /// index (a group has no pixels of its own). A PIXELS edit under
    /// `doc_lock`: a pixel-locked layer refuses it, and on a
    /// transparency-locked one the stroke changes colour but never coverage.
    /// (`pub(crate)` because `CompositeMode` is a crate-private type; the
    /// public surface is `rz_doc_painting_layer`.)
    pub(crate) fn painting_layer(
        &self,
        idx: usize,
        src: &[u8],
        mode: CompositeMode,
        alpha: f32,
    ) -> Option<Self> {
        self.under_locks(idx, EditKind::Pixels, |doc| {
            let layer = doc.raster_layer(idx)?;
            if alpha.is_nan() {
                return None;
            }
            let expected = (doc.width as usize)
                .checked_mul(doc.height as usize)?
                .checked_mul(4)?;
            if src.len() != expected {
                return None;
            }
            let a = alpha.clamp(0.0, 1.0);
            let (lw, lh) = layer.pixels.dimensions();
            let (off_x, off_y) = (i64::from(layer.offset.0), i64::from(layer.offset.1));
            let lx0 = (-off_x).max(0);
            let ly0 = (-off_y).max(0);
            let lx1 = (i64::from(doc.width) - off_x).min(i64::from(lw));
            let ly1 = (i64::from(doc.height) - off_y).min(i64::from(lh));
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
                    let si = ((cy * u64::from(doc.width) + cx) * 4) as usize;
                    let di = ((ly as u64 * u64::from(lw) + lx as u64) * 4) as usize;
                    let sp = [src[si], src[si + 1], src[si + 2], src[si + 3]];
                    let dp: &mut [u8] = &mut raw[di..di + 4];
                    paint_pixel(dp, sp, mode, a);
                }
            }
            doc.with_layer_pixels(idx, pixels)
        })
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
        // A GROUP mask that has TRAVELLED rides its group's offset; every op
        // below consumes it as a CANVAS plane, so the offset is flattened into
        // the plane first — the one place that shift is ever resampled
        // (`doc_align::baked_group_masks`).
        if let Some(baked) = doc_align::baked_group_masks(self) {
            return baked.geometry(new_w, new_h, geom, f);
        }
        let layers = self
            .layers
            .iter()
            .map(|l| {
                let (lw, lh) = l.pixels.dimensions();
                Layer {
                    pixels: Arc::new(geom.apply(&*l.pixels)),
                    // One `Geometry::apply` serves both mask conventions: a
                    // layer mask is the layer's size and comes back the
                    // layer's new size, a GROUP's is the canvas's and comes
                    // back the new canvas's — which is exactly what
                    // `doc_channel::geometry_plane` does for a channel.
                    mask: l.mask.as_ref().map(|m| Arc::new(geom.apply(&**m))),
                    offset: group_offset(l).unwrap_or_else(|| f(l, i64::from(lw), i64::from(lh))),
                    ..l.clone()
                }
            })
            .collect();
        RzDocument {
            width: new_w,
            height: new_h,
            layers,
            global_light: self.global_light,
            channels: doc_channel::geometry_channels(&self.channels, geom),
            profile: Arc::clone(&self.profile),
            metadata: self.metadata.clone(),
            // A 300 x 150 ppi document turned 90 degrees is 150 x 300; the
            // other three geometries leave the axes where they were.
            resolution: self.resolution.transposed_if(geom.swaps_axes()),
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
        // See `geometry`: a travelled group mask is baked to canvas origin
        // before anything reads it as a canvas plane.
        if let Some(baked) = doc_align::baked_group_masks(self) {
            return baked.crop(x, y, w, h);
        }
        let layers = self
            .layers
            .iter()
            .map(|l| Layer {
                offset: group_offset(l).unwrap_or_else(|| {
                    (
                        saturating_i32(i64::from(l.offset.0) - i64::from(x)),
                        saturating_i32(i64::from(l.offset.1) - i64::from(y)),
                    )
                }),
                // A GROUP's mask is CANVAS space, so it rides the CHANNEL
                // path and is genuinely cut down to the window; a layer mask
                // is layer space and rides along untouched.
                mask: canvas_mask(l)
                    .map(|m| Some(Arc::new(doc_channel::cropped_plane(m, x, y, w, h))))
                    .unwrap_or_else(|| l.mask.clone()),
                ..l.clone()
            })
            .collect();
        Some(RzDocument {
            width: w,
            height: h,
            layers,
            global_light: self.global_light,
            channels: doc_channel::cropped_channels(&self.channels, x, y, w, h),
            profile: Arc::clone(&self.profile),
            metadata: self.metadata.clone(),
            resolution: self.resolution,
        })
    }

    /// Changes the canvas size without scaling anything: the canvas becomes
    /// `w` x `h` and every layer's offset shifts by `origin` — where the old
    /// canvas's top-left corner lands in the new canvas. Layer pixels are
    /// untouched; content outside the new canvas is retained, as with crop.
    ///
    /// Growing or shrinking the canvas is a pure offset change, so — exactly
    /// as in [`RzDocument::crop`] — masks and meta ride along untouched.
    ///
    /// Channels are canvas-sized, so growing the canvas grows every one of
    /// them: `None` when that would push the list past the RZDC total-pixel
    /// budget (`doc_channel::channels_fit_at`), rather than building a
    /// document `rz_doc_save_native` could not write.
    pub fn canvas_resize(&self, w: u32, h: u32, origin: (i32, i32)) -> Option<Self> {
        if w == 0 || h == 0 || u64::from(w) * u64::from(h) > MAX_PIXELS {
            return None;
        }
        if !doc_channel::channels_fit_at(w, h, self.channels.len()) {
            return None;
        }
        // See `geometry`: a travelled group mask is baked to canvas origin
        // before anything reads it as a canvas plane.
        if let Some(baked) = doc_align::baked_group_masks(self) {
            return baked.canvas_resize(w, h, origin);
        }
        let layers = self
            .layers
            .iter()
            .map(|l| Layer {
                offset: group_offset(l).unwrap_or_else(|| {
                    (
                        saturating_i32(i64::from(l.offset.0) + i64::from(origin.0)),
                        saturating_i32(i64::from(l.offset.1) + i64::from(origin.1)),
                    )
                }),
                // A GROUP's canvas-sized mask is padded into the new canvas
                // the way a channel is (`doc_channel::padded_plane`).
                mask: canvas_mask(l)
                    .map(|m| Some(Arc::new(doc_channel::padded_plane(m, w, h, origin))))
                    .unwrap_or_else(|| l.mask.clone()),
                ..l.clone()
            })
            .collect();
        Some(RzDocument {
            width: w,
            height: h,
            layers,
            global_light: self.global_light,
            channels: doc_channel::padded_channels(&self.channels, w, h, origin),
            profile: Arc::clone(&self.profile),
            metadata: self.metadata.clone(),
            resolution: self.resolution,
        })
    }

    /// Scales the canvas and every layer (sizes and offsets) proportionally.
    /// The total-pixel guard applies to the canvas, as in `rz_image_resize`.
    /// Layer styles are scaled with the layer ("Scale Effects", by the mean
    /// factor `sqrt(fx * fy)`).
    ///
    /// Channels resample to the new canvas, so — as in
    /// [`RzDocument::canvas_resize`] — `None` when the enlarged list would
    /// break the RZDC total-pixel budget.
    pub fn resize(&self, w: u32, h: u32, filter: FilterType) -> Option<Self> {
        if w == 0 || h == 0 || u64::from(w) * u64::from(h) > MAX_PIXELS {
            return None;
        }
        if !doc_channel::channels_fit_at(w, h, self.channels.len()) {
            return None;
        }
        // See `geometry`: a travelled group mask is baked to canvas origin
        // before anything reads it as a canvas plane.
        if let Some(baked) = doc_align::baked_group_masks(self) {
            return baked.resize(w, h, filter);
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
                    // The mask scales with the layer, staying the same size —
                    // except a GROUP's, which is canvas space and resamples
                    // to the NEW CANVAS like a channel does. Sending it down
                    // the layer path would resample it to the 1x1 dummy's new
                    // size and destroy it.
                    mask: match canvas_mask(l) {
                        Some(m) => Some(Arc::new(doc_channel::resized_plane(m, w, h, filter))),
                        None => l
                            .mask
                            .as_ref()
                            .map(|m| Arc::new(imageops::resize(&**m, nw, nh, filter))),
                    },
                    offset: group_offset(l).unwrap_or_else(|| {
                        (
                            saturating_i32((f64::from(l.offset.0) * fx).round() as i64),
                            saturating_i32((f64::from(l.offset.1) * fy).round() as i64),
                        )
                    }),
                    style: scaled_style(&l.style, (fx * fy).sqrt()),
                    ..l.clone()
                }
            })
            .collect();
        Some(RzDocument {
            width: w,
            height: h,
            layers,
            global_light: self.global_light,
            channels: doc_channel::resized_channels(&self.channels, w, h, filter),
            profile: Arc::clone(&self.profile),
            metadata: self.metadata.clone(),
            // Photoshop's "Resample: on" case — the pixels change and so
            // does the print size, but the ppi holds. `set_resolution` is
            // the op that moves ppi, and it never touches a pixel.
            resolution: self.resolution,
        })
    }
}

pub(crate) fn saturating_i32(v: i64) -> i32 {
    v.clamp(i64::from(i32::MIN), i64::from(i32::MAX)) as i32
}

/// `Some((0, 0))` for a GROUP entry, `None` for a raster one — the offset the
/// whole-document maps must give a group. A group has no pixel rect, so its
/// `offset` is a phantom: letting the maps derive one from the 1x1 dummy
/// would drift it away from (0, 0) on every rotate and crop, and every reader
/// that is later taught about groups would inherit the drift.
fn group_offset(layer: &Layer) -> Option<(i32, i32)> {
    (layer.kind == LayerKind::Group).then_some((0, 0))
}

/// A GROUP's CANVAS-sized mask, `None` for a raster entry's layer-sized one —
/// the branch that sends the two down their different geometry paths.
fn canvas_mask(layer: &Layer) -> Option<&GrayImage> {
    (layer.kind == LayerKind::Group)
        .then_some(layer.mask.as_deref())
        .flatten()
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
    /// Gives entry `idx` a mask (replacing any existing one) and enables it.
    /// The mask is created at exactly the layer's pixel dimensions — or, for
    /// a GROUP, at the CANVAS's, which is the size a group mask always has
    /// (`doc_group`): a group has no pixel buffer to be the size of, and
    /// Photoshop's group masks are canvas space too. All three
    /// [`MaskKind`]s honour that; `FromSelection` is canvas-sized already, so
    /// on a group it is taken verbatim rather than cropped to anything.
    /// `None` on an out-of-range index or a `FromSelection` buffer that is
    /// not canvas-sized. A MASK edit under `doc_lock`: only "Lock All"
    /// refuses it, since Photoshop lets a pixel-locked layer's mask be
    /// edited.
    pub fn add_mask(&self, idx: usize, kind: MaskKind) -> Option<Self> {
        self.under_locks(idx, EditKind::Mask, |doc| {
            let layer = doc.layer(idx)?;
            let (lw, lh) = if layer.kind == LayerKind::Group {
                (doc.width, doc.height)
            } else {
                layer.pixels.dimensions()
            };
            let (off_x, off_y) = match group_offset(layer) {
                Some((x, y)) => (i64::from(x), i64::from(y)),
                None => (i64::from(layer.offset.0), i64::from(layer.offset.1)),
            };
            let mask = match kind {
                MaskKind::RevealAll => GrayImage::from_pixel(lw, lh, Luma([255])),
                MaskKind::HideAll => GrayImage::new(lw, lh),
                MaskKind::FromSelection(sel) => {
                    let canvas_px = (doc.width as usize).checked_mul(doc.height as usize)?;
                    if sel.len() != canvas_px {
                        return None;
                    }
                    GrayImage::from_fn(lw, lh, |x, y| {
                        let cx = i64::from(x) + off_x;
                        let cy = i64::from(y) + off_y;
                        if cx < 0
                            || cy < 0
                            || cx >= i64::from(doc.width)
                            || cy >= i64::from(doc.height)
                        {
                            return Luma([0]);
                        }
                        Luma([sel[cy as usize * doc.width as usize + cx as usize]])
                    })
                }
            };
            doc.with_layer(idx, |l| {
                l.mask = Some(Arc::new(mask));
                l.mask_enabled = true;
                // A fresh group mask is canvas-ALIGNED, so the offset the old
                // one had travelled to goes with it (`doc_align`).
                if l.kind == LayerKind::Group {
                    l.offset = (0, 0);
                }
            })
        })
    }

    /// Drops layer `idx`'s mask. With `apply`, the mask is first baked into
    /// the layer's alpha (`alpha' = alpha * mask / 255`, straight alpha)
    /// REGARDLESS of `mask_enabled` — "apply" always means what it says — so
    /// the projection is unchanged for an enabled mask. `None` if the layer
    /// has no mask, and `None` for `apply` on a GROUP — a group has no pixels
    /// to bake a mask into, so "apply" has nothing to mean there. A MASK edit
    /// under `doc_lock`: applying a mask is a mask operation in Photoshop's
    /// own menus, and treating it as a pixel edit would make "Lock Pixels"
    /// mean something different here than everywhere else. With `apply` it is
    /// the STRONGER `EditKind::MaskApply`, because that variant multiplies the
    /// coverage into the layer's alpha and Lock Transparency exists precisely
    /// to make that impossible.
    pub fn remove_mask(&self, idx: usize, apply: bool) -> Option<Self> {
        let kind = if apply {
            EditKind::MaskApply
        } else {
            EditKind::Mask
        };
        self.under_locks(idx, kind, |doc| {
            let layer = doc.layer(idx)?;
            let mask = layer.mask.as_deref()?;
            if apply && layer.kind == LayerKind::Group {
                return None;
            }
            let baked = (apply && mask.dimensions() == layer.pixels.dimensions()).then(|| {
                let mut pixels = (*layer.pixels).clone();
                for (px, cov) in pixels.pixels_mut().zip(mask.pixels()) {
                    px[3] = (f32::from(px[3]) * f32::from(cov[0]) / 255.0).round() as u8;
                }
                pixels
            });
            doc.with_layer(idx, |l| {
                if let Some(pixels) = baked {
                    l.pixels = Arc::new(pixels);
                }
                l.mask = None;
                l.mask_enabled = true;
                // A group's offset positions its mask and means nothing
                // without one (`doc_align`).
                if l.kind == LayerKind::Group {
                    l.offset = (0, 0);
                }
            })
        })
    }

    /// Enables or disables layer `idx`'s mask (a disabled mask is retained but
    /// ignored while compositing). `None` if the layer has no mask. A MASK
    /// edit under `doc_lock`.
    pub fn set_mask_enabled(&self, idx: usize, enabled: bool) -> Option<Self> {
        self.under_locks(idx, EditKind::Mask, |doc| {
            doc.layer(idx)?.mask.as_ref()?;
            doc.with_layer(idx, |l| l.mask_enabled = enabled)
        })
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
    /// mask pixel could change), matching `painting_layer`. A GROUP's mask is
    /// CANVAS-sized and sits at the group's own offset — which is exactly what
    /// that offset positions (`doc_align`) — so the same walk covers it with
    /// the canvas as its frame. A MASK edit under `doc_lock`.
    pub fn paint_mask(&self, idx: usize, overlay: &[u8]) -> Option<Self> {
        self.under_locks(idx, EditKind::Mask, |doc| {
            let layer = doc.layer(idx)?;
            let mask = layer.mask.as_deref()?;
            let expected = (doc.width as usize)
                .checked_mul(doc.height as usize)?
                .checked_mul(4)?;
            if overlay.len() != expected {
                return None;
            }
            let (lw, lh) = if layer.kind == LayerKind::Group {
                (doc.width, doc.height)
            } else {
                layer.pixels.dimensions()
            };
            if mask.dimensions() != (lw, lh) {
                return None;
            }
            // One rule for both kinds: a raster entry's offset positions its
            // pixels and its layer-sized mask, a group's positions its
            // canvas-sized mask (`doc_align`).
            let (off_x, off_y) = (i64::from(layer.offset.0), i64::from(layer.offset.1));
            let lx0 = (-off_x).max(0);
            let ly0 = (-off_y).max(0);
            let lx1 = (i64::from(doc.width) - off_x).min(i64::from(lw));
            let ly1 = (i64::from(doc.height) - off_y).min(i64::from(lh));
            if lx0 >= lx1 || ly0 >= ly1 {
                return None;
            }
            let mut painted = mask.clone();
            let raw: &mut [u8] = &mut painted;
            for ly in ly0..ly1 {
                for lx in lx0..lx1 {
                    let cx = (lx + off_x) as u64;
                    let cy = (ly + off_y) as u64;
                    let si = ((cy * u64::from(doc.width) + cx) * 4) as usize;
                    let sp = [
                        overlay[si],
                        overlay[si + 1],
                        overlay[si + 2],
                        overlay[si + 3],
                    ];
                    let di = (ly as u64 * u64::from(lw) + lx as u64) as usize;
                    // `doc_plane::channel_lerp` IS this rule (it was lifted
                    // from here), now shared with channel and colour-plane
                    // painting; None means the overlay pixel is transparent
                    // and the mask byte is left alone. This loop deliberately
                    // keeps `paint_mask`'s historic lack of a "nothing
                    // changed" latch — the channel paints have one — so the
                    // refactor changes no behaviour here.
                    if let Some(v) = channel_lerp(raw[di], sp) {
                        raw[di] = v;
                    }
                }
            }
            doc.with_layer(idx, |l| l.mask = Some(Arc::new(painted)))
        })
    }

    /// Layer `idx`'s mask expanded to an opaque grayscale RGBA image (for the
    /// layers-panel thumbnail); `None` if the layer has no mask.
    pub fn mask_image(&self, idx: usize) -> Option<RgbaImage> {
        // A GROUP's mask rides its offset, so the thumbnail is of the mask
        // where it actually sits on the canvas (`doc_align`).
        let baked = doc_align::baked_group_masks(self);
        let this = baked.as_ref().unwrap_or(self);
        let mask = this.layer(idx)?.mask.as_deref()?;
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
    /// via the `RzImage::open_bytes` rules to a single "Background" layer.
    ///
    /// A FLAT open also lifts the file's sidecar onto the document: its
    /// embedded ICC profile (from the decoder, which reassembles JPEG APP2
    /// chunks and inflates PNG `iCCP` for every format it reads), its EXIF,
    /// XMP and IPTC packets and its print resolution (from `metadata`'s
    /// JPEG/PNG container walk). A `.rz` carries all of that itself; a PSD
    /// captures none of it — `psd` 0.3.5 exposes only the Slices image
    /// resource, so the resolution (id 1005) and the ICC profile (id 1039)
    /// are unreachable.
    ///
    /// This REPORTS what the file said and adopts no working space: an
    /// embedded profile that differs from the host's preference is converted
    /// by `adopt_working_space`, once, by the caller.
    pub fn open(path: &str) -> Result<Self, String> {
        let bytes = std::fs::read(path).map_err(|e| format!("failed to read {path}: {e}"))?;
        if bytes.len() >= 4 && &bytes[..4] == b"RZDC" {
            crate::rzdc::parse_native(&bytes)
                .map_err(|e| format!("failed to read document {path}: {e}"))
        } else if bytes.len() >= 4 && &bytes[..4] == b"8BPS" {
            crate::psd::open_psd(&bytes, path)
        } else {
            let (image, sidecar) = RzImage::open_bytes(&bytes, path)?;
            let mut doc = RzDocument::from_pixels(image.pixels);
            // A profile that is not an RGB ICC profile — or one whose
            // declared size is past the blob cap, which a zlib-compressed
            // PNG `iCCP` can inflate to — is dropped, not an error: the
            // pixels are still fine, and the document keeps the sRGB
            // assumption every reader makes. `IccProfile::parse` is where
            // both refusals live, so this path can never build a document
            // the native writer would refuse to save.
            if let Some(profile) = sidecar.icc.as_deref().and_then(IccProfile::parse) {
                doc.profile = Arc::new(profile);
            }
            doc.metadata = sidecar.metadata;
            if let Some(resolution) = sidecar.resolution {
                doc.resolution = resolution;
            }
            Ok(doc)
        }
    }
}
