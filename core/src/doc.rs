//! Layered document model: `RzDocument` (canvas + bottom-to-top layer
//! stack), the blend-mode table and f32 compositing, the RZDC native
//! format, and layered PSD import. See include/rasterize_core.h for the
//! contract. Layer pixel buffers are `Arc`-shared so document copies are
//! copy-on-write.

use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::Arc;

use image::codecs::png::PngEncoder;
use image::imageops::{self, FilterType};
use image::{ExtendedColorType, ImageEncoder, RgbaImage};

use crate::ops::CompositeMode;
use crate::RzImage;

/// Largest permitted canvas or merged-extent size, in total pixels (matches
/// the `rz_image_resize` guard).
const MAX_PIXELS: u64 = 100_000_000;

/// Hard caps applied while reading RZDC files so corrupt headers cannot ask
/// for absurd allocations.
const MAX_RZDC_LAYERS: u32 = 1024;
const MAX_RZDC_NAME_LEN: u32 = 64 * 1024;
const MAX_RZDC_PNG_LEN: u32 = 512 * 1024 * 1024;

/// Ceiling on the SUM of decoded layer pixels across one RZDC file: even when
/// every individual layer looks reasonable, a crafted file must not be able
/// to stack layers until memory is exhausted.
const MAX_RZDC_TOTAL_LAYER_PIXELS: u64 = 4 * MAX_PIXELS;

/// The blend-mode set, mirroring `RzBlendMode` in the C header: 0-13 and
/// 15-22 are separable (per-channel W3C formulas), 23-26 non-separable
/// (whole-RGB-triple SetLum/SetSat math), and Dissolve (14) replaces alpha
/// compositing with a deterministic per-canvas-position dither.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(i32)]
pub enum BlendMode {
    Normal = 0,
    Multiply = 1,
    Screen = 2,
    Overlay = 3,
    SoftLight = 4,
    HardLight = 5,
    Darken = 6,
    Lighten = 7,
    Difference = 8,
    Exclusion = 9,
    ColorDodge = 10,
    ColorBurn = 11,
    Addition = 12,
    Subtract = 13,
    Dissolve = 14,
    LinearBurn = 15,
    DarkerColor = 16,
    LighterColor = 17,
    VividLight = 18,
    LinearLight = 19,
    PinLight = 20,
    HardMix = 21,
    Divide = 22,
    Hue = 23,
    Saturation = 24,
    Color = 25,
    Luminosity = 26,
}

impl BlendMode {
    /// Maps a raw `RzBlendMode` value coming across the FFI.
    pub fn from_c(value: i32) -> Option<Self> {
        match value {
            0 => Some(BlendMode::Normal),
            1 => Some(BlendMode::Multiply),
            2 => Some(BlendMode::Screen),
            3 => Some(BlendMode::Overlay),
            4 => Some(BlendMode::SoftLight),
            5 => Some(BlendMode::HardLight),
            6 => Some(BlendMode::Darken),
            7 => Some(BlendMode::Lighten),
            8 => Some(BlendMode::Difference),
            9 => Some(BlendMode::Exclusion),
            10 => Some(BlendMode::ColorDodge),
            11 => Some(BlendMode::ColorBurn),
            12 => Some(BlendMode::Addition),
            13 => Some(BlendMode::Subtract),
            14 => Some(BlendMode::Dissolve),
            15 => Some(BlendMode::LinearBurn),
            16 => Some(BlendMode::DarkerColor),
            17 => Some(BlendMode::LighterColor),
            18 => Some(BlendMode::VividLight),
            19 => Some(BlendMode::LinearLight),
            20 => Some(BlendMode::PinLight),
            21 => Some(BlendMode::HardMix),
            22 => Some(BlendMode::Divide),
            23 => Some(BlendMode::Hue),
            24 => Some(BlendMode::Saturation),
            25 => Some(BlendMode::Color),
            26 => Some(BlendMode::Luminosity),
            _ => None,
        }
    }

    /// The `RzBlendMode` value for the FFI.
    pub fn to_c(self) -> i32 {
        self as i32
    }
}

// --------------------------------------------------------- blend functions --
// W3C separable blend functions B(cb, cs); all inputs and outputs in [0, 1].

fn b_normal(_cb: f32, cs: f32) -> f32 {
    cs
}

fn b_multiply(cb: f32, cs: f32) -> f32 {
    cb * cs
}

fn b_screen(cb: f32, cs: f32) -> f32 {
    cb + cs - cb * cs
}

fn b_hard_light(cb: f32, cs: f32) -> f32 {
    if cs <= 0.5 {
        2.0 * cb * cs
    } else {
        1.0 - 2.0 * (1.0 - cb) * (1.0 - cs)
    }
}

fn b_overlay(cb: f32, cs: f32) -> f32 {
    b_hard_light(cs, cb)
}

fn b_darken(cb: f32, cs: f32) -> f32 {
    cb.min(cs)
}

fn b_lighten(cb: f32, cs: f32) -> f32 {
    cb.max(cs)
}

fn b_difference(cb: f32, cs: f32) -> f32 {
    (cb - cs).abs()
}

fn b_exclusion(cb: f32, cs: f32) -> f32 {
    cb + cs - 2.0 * cb * cs
}

fn b_color_dodge(cb: f32, cs: f32) -> f32 {
    if cb == 0.0 {
        0.0
    } else if cs == 1.0 {
        1.0
    } else {
        (cb / (1.0 - cs)).min(1.0)
    }
}

fn b_color_burn(cb: f32, cs: f32) -> f32 {
    if cb == 1.0 {
        1.0
    } else if cs == 0.0 {
        0.0
    } else {
        1.0 - ((1.0 - cb) / cs).min(1.0)
    }
}

fn soft_light_d(cb: f32) -> f32 {
    if cb <= 0.25 {
        ((16.0 * cb - 12.0) * cb + 4.0) * cb
    } else {
        cb.sqrt()
    }
}

fn b_soft_light(cb: f32, cs: f32) -> f32 {
    if cs <= 0.5 {
        cb - (1.0 - 2.0 * cs) * cb * (1.0 - cb)
    } else {
        cb + (2.0 * cs - 1.0) * (soft_light_d(cb) - cb)
    }
}

fn b_addition(cb: f32, cs: f32) -> f32 {
    (cb + cs).min(1.0)
}

fn b_subtract(cb: f32, cs: f32) -> f32 {
    (cb - cs).max(0.0)
}

fn b_linear_burn(cb: f32, cs: f32) -> f32 {
    (cb + cs - 1.0).max(0.0)
}

fn b_vivid_light(cb: f32, cs: f32) -> f32 {
    // At cs == 0.5 exactly, burn(cb, 1.0) == cb, matching the dodge branch's
    // limit, so the seam is continuous.
    if cs <= 0.5 {
        b_color_burn(cb, 2.0 * cs)
    } else {
        b_color_dodge(cb, 2.0 * cs - 1.0)
    }
}

fn b_linear_light(cb: f32, cs: f32) -> f32 {
    (cb + 2.0 * cs - 1.0).clamp(0.0, 1.0)
}

fn b_pin_light(cb: f32, cs: f32) -> f32 {
    if cs <= 0.5 {
        cb.min(2.0 * cs)
    } else {
        cb.max(2.0 * cs - 1.0)
    }
}

fn b_hard_mix(cb: f32, cs: f32) -> f32 {
    if cb + cs >= 1.0 {
        1.0
    } else {
        0.0
    }
}

fn b_divide(cb: f32, cs: f32) -> f32 {
    if cs == 0.0 {
        1.0
    } else {
        (cb / cs).min(1.0)
    }
}

// W3C non-separable blend machinery (compositing-1 spec pseudocode) operating
// on RGB triples in [0, 1]. Lum uses the spec's 0.3/0.59/0.11 weights.

fn lum(c: [f32; 3]) -> f32 {
    0.3 * c[0] + 0.59 * c[1] + 0.11 * c[2]
}

/// ClipColor: pulls out-of-gamut channels back toward the triple's
/// luminosity, preserving it. The divisors are safe: `l` is always a real
/// color's luminosity (in [0, 1]), so `n < 0` implies `l - n > 0` and `x > 1`
/// implies `x - l > 0`.
fn clip_color(mut c: [f32; 3]) -> [f32; 3] {
    let l = lum(c);
    let n = c[0].min(c[1]).min(c[2]);
    let x = c[0].max(c[1]).max(c[2]);
    if n < 0.0 {
        for ch in &mut c {
            *ch = l + (*ch - l) * l / (l - n);
        }
    }
    if x > 1.0 {
        for ch in &mut c {
            *ch = l + (*ch - l) * (1.0 - l) / (x - l);
        }
    }
    c
}

/// SetLum: shifts the triple to luminosity `l`, then clips into gamut.
fn set_lum(c: [f32; 3], l: f32) -> [f32; 3] {
    let d = l - lum(c);
    clip_color([c[0] + d, c[1] + d, c[2] + d])
}

fn sat(c: [f32; 3]) -> f32 {
    c[0].max(c[1]).max(c[2]) - c[0].min(c[1]).min(c[2])
}

/// SetSat: rescales the triple to saturation `s` — min channel to 0, max to
/// `s`, mid proportionally between them (spec pseudocode).
fn set_sat(c: [f32; 3], s: f32) -> [f32; 3] {
    let mut idx = [0usize, 1, 2];
    idx.sort_by(|&a, &b| c[a].total_cmp(&c[b]));
    let [lo, mid, hi] = idx;
    let mut out = [0.0f32; 3];
    if c[hi] > c[lo] {
        out[mid] = (c[mid] - c[lo]) * s / (c[hi] - c[lo]);
        out[hi] = s;
    }
    out
}

fn b_hue(cb: [f32; 3], cs: [f32; 3]) -> [f32; 3] {
    set_lum(set_sat(cs, sat(cb)), lum(cb))
}

fn b_saturation(cb: [f32; 3], cs: [f32; 3]) -> [f32; 3] {
    set_lum(set_sat(cb, sat(cs)), lum(cb))
}

fn b_color(cb: [f32; 3], cs: [f32; 3]) -> [f32; 3] {
    set_lum(cs, lum(cb))
}

fn b_luminosity(cb: [f32; 3], cs: [f32; 3]) -> [f32; 3] {
    set_lum(cb, lum(cs))
}

/// Whole-pixel pick: the lower-luma triple wins (backdrop on a tie).
fn b_darker_color(cb: [f32; 3], cs: [f32; 3]) -> [f32; 3] {
    if lum(cs) < lum(cb) {
        cs
    } else {
        cb
    }
}

/// Whole-pixel pick: the higher-luma triple wins (backdrop on a tie).
fn b_lighter_color(cb: [f32; 3], cs: [f32; 3]) -> [f32; 3] {
    if lum(cs) > lum(cb) {
        cs
    } else {
        cb
    }
}

/// How a blend mode participates in compositing: per-channel `B(cb, cs)`,
/// whole-RGB-triple `B(Cb, Cs)`, or the Dissolve dither (which replaces the
/// compositing formula entirely).
#[derive(Clone, Copy)]
enum BlendKind {
    Separable(fn(f32, f32) -> f32),
    NonSeparable(fn([f32; 3], [f32; 3]) -> [f32; 3]),
    Dissolve,
}

/// The blend behavior for a mode (data table, resolved once per layer rather
/// than per pixel).
fn blend_kind(mode: BlendMode) -> BlendKind {
    match mode {
        BlendMode::Normal => BlendKind::Separable(b_normal),
        BlendMode::Multiply => BlendKind::Separable(b_multiply),
        BlendMode::Screen => BlendKind::Separable(b_screen),
        BlendMode::Overlay => BlendKind::Separable(b_overlay),
        BlendMode::SoftLight => BlendKind::Separable(b_soft_light),
        BlendMode::HardLight => BlendKind::Separable(b_hard_light),
        BlendMode::Darken => BlendKind::Separable(b_darken),
        BlendMode::Lighten => BlendKind::Separable(b_lighten),
        BlendMode::Difference => BlendKind::Separable(b_difference),
        BlendMode::Exclusion => BlendKind::Separable(b_exclusion),
        BlendMode::ColorDodge => BlendKind::Separable(b_color_dodge),
        BlendMode::ColorBurn => BlendKind::Separable(b_color_burn),
        BlendMode::Addition => BlendKind::Separable(b_addition),
        BlendMode::Subtract => BlendKind::Separable(b_subtract),
        BlendMode::Dissolve => BlendKind::Dissolve,
        BlendMode::LinearBurn => BlendKind::Separable(b_linear_burn),
        BlendMode::DarkerColor => BlendKind::NonSeparable(b_darker_color),
        BlendMode::LighterColor => BlendKind::NonSeparable(b_lighter_color),
        BlendMode::VividLight => BlendKind::Separable(b_vivid_light),
        BlendMode::LinearLight => BlendKind::Separable(b_linear_light),
        BlendMode::PinLight => BlendKind::Separable(b_pin_light),
        BlendMode::HardMix => BlendKind::Separable(b_hard_mix),
        BlendMode::Divide => BlendKind::Separable(b_divide),
        BlendMode::Hue => BlendKind::NonSeparable(b_hue),
        BlendMode::Saturation => BlendKind::NonSeparable(b_saturation),
        BlendMode::Color => BlendKind::NonSeparable(b_color),
        BlendMode::Luminosity => BlendKind::NonSeparable(b_luminosity),
    }
}

/// Deterministic Dissolve threshold for a canvas position, in [0, 1).
/// Murmur3-style integer mix of the coordinates; canvas-absolute so the
/// dither pattern is stable for a given position regardless of layer offset
/// or projection window. Only the low 24 hash bits are used so the result is
/// exact in f32 and strictly below 1 (a fully opaque pixel always shows).
fn dissolve_threshold(x: i64, y: i64) -> f32 {
    let mut h = (x as u32)
        .wrapping_mul(0x9E37_79B9)
        .wrapping_add((y as u32).wrapping_mul(0x85EB_CA6B));
    h ^= h >> 16;
    h = h.wrapping_mul(0x85EB_CA6B);
    h ^= h >> 13;
    h = h.wrapping_mul(0xC2B2_AE35);
    h ^= h >> 16;
    ((h >> 8) as f32) * (1.0 / 16_777_216.0)
}

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
}

impl Layer {
    fn new(pixels: RgbaImage, name: &str) -> Self {
        Layer {
            pixels: Arc::new(pixels),
            offset: (0, 0),
            name: name.to_string(),
            opacity: 1.0,
            blend: BlendMode::Normal,
            visible: true,
        }
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
fn sane_opacity(opacity: f32) -> f32 {
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
/// and opacity. Pixels outside the layer's extent are untouched. The caller
/// is responsible for visibility filtering.
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
            let li = ((ly * u64::from(lw) + lx) * 4) as usize;
            let sa = f32::from(raw[li + 3]) / 255.0 * opacity;
            if sa <= 0.0 {
                continue;
            }
            let cs = [
                f32::from(raw[li]) / 255.0,
                f32::from(raw[li + 1]) / 255.0,
                f32::from(raw[li + 2]) / 255.0,
            ];
            let ai = (ay as u64 * u64::from(acc_w) + ax as u64) as usize;
            if let BlendKind::Dissolve = kind {
                // Dissolve skips the compositing formula: the source shows
                // fully opaque with probability sa (its effective alpha),
                // otherwise the backdrop pixel stays untouched.
                let (cx, cy) = (ax + i64::from(origin.0), ay + i64::from(origin.1));
                if dissolve_threshold(cx, cy) < sa {
                    acc[ai] = [cs[0], cs[1], cs[2], 1.0];
                }
                continue;
            }
            let bg = acc[ai];
            let ab = bg[3];
            let ao = sa + ab * (1.0 - sa);
            let blended = match kind {
                BlendKind::Separable(f) => [f(bg[0], cs[0]), f(bg[1], cs[1]), f(bg[2], cs[2])],
                BlendKind::NonSeparable(f) => f([bg[0], bg[1], bg[2]], cs),
                BlendKind::Dissolve => unreachable!("dissolve handled above"),
            };
            let mut out = [0.0f32; 4];
            for c in 0..3 {
                out[c] =
                    (sa * (1.0 - ab) * cs[c] + sa * ab * blended[c] + (1.0 - sa) * ab * bg[c]) / ao;
            }
            out[3] = ao;
            acc[ai] = out;
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
    pub fn flattened(&self) -> RgbaImage {
        let px = self.width as usize * self.height as usize;
        let mut acc = vec![[0.0f32; 4]; px];
        for layer in self.layers.iter().filter(|l| l.visible) {
            composite_layer_into(&mut acc, self.width, self.height, (0, 0), layer);
        }
        quantize(&acc, self.width, self.height)
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

    /// Pure setter: replaces layer `idx`'s canvas offset.
    pub fn with_layer_offset(&self, idx: usize, x: i32, y: i32) -> Option<Self> {
        self.with_layer(idx, |l| l.offset = (x, y))
    }

    /// Pure setter: replaces layer `idx`'s pixels (any size; offset and
    /// properties kept).
    pub fn with_layer_pixels(&self, idx: usize, pixels: RgbaImage) -> Option<Self> {
        self.with_layer(idx, |l| l.pixels = Arc::new(pixels))
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
        composite_layer_into(&mut acc, uw as u32, uh as u32, origin, &lower);
        composite_layer_into(&mut acc, uw as u32, uh as u32, origin, &upper);
        let merged = doc.layers.get_mut(idx - 1).expect("lower layer exists");
        merged.pixels = Arc::new(quantize(&acc, uw as u32, uh as u32));
        merged.offset = origin;
        merged.opacity = 1.0;
        merged.blend = BlendMode::Normal;
        Some(doc)
    }

    /// Single-layer document containing the projection, named "Background".
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
        self.geometry(self.height, self.width, |l, _lw, lh| {
            (
                imageops::rotate90(&*l.pixels),
                (saturating_i32(ch - i64::from(l.offset.1) - lh), l.offset.0),
            )
        })
    }

    /// Rotates the whole document 180 degrees.
    pub fn rotate180(&self) -> Self {
        let (cw, ch) = (i64::from(self.width), i64::from(self.height));
        self.geometry(self.width, self.height, |l, lw, lh| {
            (
                imageops::rotate180(&*l.pixels),
                (
                    saturating_i32(cw - i64::from(l.offset.0) - lw),
                    saturating_i32(ch - i64::from(l.offset.1) - lh),
                ),
            )
        })
    }

    /// Rotates the whole document 90 degrees counter-clockwise.
    pub fn rotate270(&self) -> Self {
        let cw = i64::from(self.width);
        self.geometry(self.height, self.width, |l, lw, _lh| {
            (
                imageops::rotate270(&*l.pixels),
                (l.offset.1, saturating_i32(cw - i64::from(l.offset.0) - lw)),
            )
        })
    }

    /// Mirrors the whole document left-right.
    pub fn flip_horizontal(&self) -> Self {
        let cw = i64::from(self.width);
        self.geometry(self.width, self.height, |l, lw, _lh| {
            (
                imageops::flip_horizontal(&*l.pixels),
                (saturating_i32(cw - i64::from(l.offset.0) - lw), l.offset.1),
            )
        })
    }

    /// Mirrors the whole document top-bottom.
    pub fn flip_vertical(&self) -> Self {
        let ch = i64::from(self.height);
        self.geometry(self.width, self.height, |l, _lw, lh| {
            (
                imageops::flip_vertical(&*l.pixels),
                (l.offset.0, saturating_i32(ch - i64::from(l.offset.1) - lh)),
            )
        })
    }

    fn geometry(
        &self,
        new_w: u32,
        new_h: u32,
        f: impl Fn(&Layer, i64, i64) -> (RgbaImage, (i32, i32)),
    ) -> Self {
        let layers = self
            .layers
            .iter()
            .map(|l| {
                let (lw, lh) = l.pixels.dimensions();
                let (pixels, offset) = f(l, i64::from(lw), i64::from(lh));
                Layer {
                    pixels: Arc::new(pixels),
                    offset,
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
    pub fn crop(&self, x: u32, y: u32, w: u32, h: u32) -> Option<Self> {
        if w == 0 || h == 0 {
            return None;
        }
        let x_end = x.checked_add(w)?;
        let y_end = y.checked_add(h)?;
        if x_end > self.width || y_end > self.height {
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

/// Per-pixel core of `rz_image_composite` (same math as `ops::composite`,
/// duplicated here because painting maps a canvas-frame overlay through a
/// layer offset rather than compositing two same-size frames). `dp` is a
/// straight-alpha RGBA8 pixel, `sp` a premultiplied overlay pixel, `a` the
/// pre-clamped global alpha.
fn paint_pixel(dp: &mut [u8], sp: [u8; 4], mode: CompositeMode, a: f32) {
    // Fast path: a fully transparent overlay pixel passes the destination
    // bytes through exactly (no float round-trip). For OVER the color bytes
    // must also be zero — they always are in well-formed premultiplied data;
    // malformed pixels fall through to the math.
    let src_transparent = sp[3] == 0
        && match mode {
            CompositeMode::Over => sp[0] == 0 && sp[1] == 0 && sp[2] == 0,
            CompositeMode::Erase => true,
        };
    if src_transparent {
        return;
    }
    let sa = (f32::from(sp[3]) / 255.0) * a;
    let da = f32::from(dp[3]) / 255.0;
    match mode {
        CompositeMode::Over => {
            let out_a = sa + da * (1.0 - sa);
            if out_a < 1e-6 {
                // Keep the destination color bytes so fully transparent
                // regions do not invent color fringes.
                dp[3] = 0;
            } else {
                for c in 0..3 {
                    let scp = (f32::from(sp[c]) / 255.0) * a;
                    let dc = f32::from(dp[c]) / 255.0;
                    let v = (scp + dc * da * (1.0 - sa)) / out_a;
                    dp[c] = (v.clamp(0.0, 1.0) * 255.0).round() as u8;
                }
                dp[3] = (out_a.clamp(0.0, 1.0) * 255.0).round() as u8;
            }
        }
        CompositeMode::Erase => {
            let out_a = da * (1.0 - sa);
            dp[3] = (out_a.clamp(0.0, 1.0) * 255.0).round() as u8;
        }
    }
}

// ---------------------------------------------------- native format (RZDC) --

impl RzDocument {
    /// Serializes to the RZDC layout (see the header comment): "RZDC",
    /// u32 version=1, u32 width, u32 height, u32 layer count; per layer
    /// bottom-to-top: u32 name len + UTF-8 name, i32 off x, i32 off y,
    /// f32 opacity, u32 blend, u8 visible, u32 PNG len + PNG pixels.
    /// All integers little-endian.
    fn encode_native(&self) -> Result<Vec<u8>, String> {
        // The writer enforces the reader's caps, so every file it produces
        // can be read back: layer count and per-layer PNG size are hard
        // errors, over-long names are truncated on a char boundary.
        let count = u32::try_from(self.layers.len())
            .ok()
            .filter(|&c| c <= MAX_RZDC_LAYERS)
            .ok_or_else(|| format!("too many layers (max {MAX_RZDC_LAYERS})"))?;
        let mut buf = Vec::new();
        buf.extend_from_slice(b"RZDC");
        buf.extend_from_slice(&1u32.to_le_bytes());
        buf.extend_from_slice(&self.width.to_le_bytes());
        buf.extend_from_slice(&self.height.to_le_bytes());
        buf.extend_from_slice(&count.to_le_bytes());
        for layer in &self.layers {
            let mut name = layer.name.as_str();
            if name.len() > MAX_RZDC_NAME_LEN as usize {
                let mut end = MAX_RZDC_NAME_LEN as usize;
                while !name.is_char_boundary(end) {
                    end -= 1;
                }
                name = &name[..end];
            }
            let name = name.as_bytes();
            buf.extend_from_slice(&(name.len() as u32).to_le_bytes());
            buf.extend_from_slice(name);
            buf.extend_from_slice(&layer.offset.0.to_le_bytes());
            buf.extend_from_slice(&layer.offset.1.to_le_bytes());
            buf.extend_from_slice(&layer.opacity.to_le_bytes());
            buf.extend_from_slice(&(layer.blend.to_c() as u32).to_le_bytes());
            buf.push(u8::from(layer.visible));
            let mut png = Vec::new();
            let (lw, lh) = layer.pixels.dimensions();
            PngEncoder::new(&mut png)
                .write_image(layer.pixels.as_raw(), lw, lh, ExtendedColorType::Rgba8)
                .map_err(|e| format!("PNG encoding failed: {e}"))?;
            let png_len = u32::try_from(png.len())
                .ok()
                .filter(|&len| len <= MAX_RZDC_PNG_LEN)
                .ok_or_else(|| "layer PNG too large".to_string())?;
            buf.extend_from_slice(&png_len.to_le_bytes());
            buf.extend_from_slice(&png);
        }
        Ok(buf)
    }

    /// Writes the native RZDC format. Atomic like `RzImage::save`: the bytes
    /// go to a temporary file in the same directory which is renamed over
    /// `path` only on success, so a failed save never truncates or deletes an
    /// existing destination file.
    pub fn save_native(&self, path: &str) -> Result<(), String> {
        let bytes = self.encode_native()?;
        static SAVE_SEQ: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let seq = SAVE_SEQ.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let tmp_path = format!("{path}.rz-tmp-{}-{seq}", std::process::id());
        let result = std::fs::write(&tmp_path, &bytes)
            .map_err(|e| format!("failed to create {path}: {e}"))
            .and_then(|()| {
                std::fs::rename(&tmp_path, path).map_err(|e| format!("failed to write {path}: {e}"))
            });
        if result.is_err() {
            let _ = std::fs::remove_file(&tmp_path);
        }
        result
    }
}

/// Bounds-checked little-endian reader over an RZDC byte buffer.
struct Reader<'a> {
    bytes: &'a [u8],
    pos: usize,
}

impl<'a> Reader<'a> {
    fn take(&mut self, n: usize) -> Result<&'a [u8], String> {
        let end = self
            .pos
            .checked_add(n)
            .filter(|&e| e <= self.bytes.len())
            .ok_or_else(|| "unexpected end of file".to_string())?;
        let slice = &self.bytes[self.pos..end];
        self.pos = end;
        Ok(slice)
    }

    fn u8(&mut self) -> Result<u8, String> {
        Ok(self.take(1)?[0])
    }

    fn u32(&mut self) -> Result<u32, String> {
        Ok(u32::from_le_bytes(
            self.take(4)?.try_into().expect("4 bytes"),
        ))
    }

    fn i32(&mut self) -> Result<i32, String> {
        Ok(i32::from_le_bytes(
            self.take(4)?.try_into().expect("4 bytes"),
        ))
    }

    fn f32(&mut self) -> Result<f32, String> {
        Ok(f32::from_le_bytes(
            self.take(4)?.try_into().expect("4 bytes"),
        ))
    }
}

/// Parses an RZDC buffer. Corrupt or truncated input produces `Err`, never a
/// panic; unknown blend-mode values fall back to Normal and opacity is
/// clamped.
fn parse_native(bytes: &[u8]) -> Result<RzDocument, String> {
    let mut r = Reader { bytes, pos: 0 };
    if r.take(4)? != b"RZDC" {
        return Err("not an RZDC document".to_string());
    }
    let version = r.u32()?;
    if version != 1 {
        return Err(format!("unsupported RZDC version {version}"));
    }
    let width = r.u32()?;
    let height = r.u32()?;
    if width == 0 || height == 0 || u64::from(width) * u64::from(height) > MAX_PIXELS {
        return Err("invalid canvas size".to_string());
    }
    let count = r.u32()?;
    if count == 0 || count > MAX_RZDC_LAYERS {
        return Err(format!("invalid layer count {count}"));
    }
    let mut layers = Vec::with_capacity(count as usize);
    let mut total_pixels: u64 = 0;
    for _ in 0..count {
        let name_len = r.u32()?;
        if name_len > MAX_RZDC_NAME_LEN {
            return Err(format!("layer name length {name_len} out of range"));
        }
        let name = String::from_utf8_lossy(r.take(name_len as usize)?).into_owned();
        let off_x = r.i32()?;
        let off_y = r.i32()?;
        let opacity = sane_opacity(r.f32()?);
        let blend_raw = r.u32()?;
        let blend = i32::try_from(blend_raw)
            .ok()
            .and_then(BlendMode::from_c)
            .unwrap_or(BlendMode::Normal);
        let visible = r.u8()? != 0;
        let png_len = r.u32()?;
        if png_len > MAX_RZDC_PNG_LEN {
            return Err(format!("layer PNG length {png_len} out of range"));
        }
        let png = r.take(png_len as usize)?;
        let pixels = image::load_from_memory_with_format(png, image::ImageFormat::Png)
            .map_err(|e| format!("failed to decode layer pixels: {e}"))?
            .to_rgba8();
        let (lw, lh) = pixels.dimensions();
        total_pixels = total_pixels.saturating_add(u64::from(lw) * u64::from(lh));
        if total_pixels > MAX_RZDC_TOTAL_LAYER_PIXELS {
            return Err(format!(
                "total layer pixels exceed {MAX_RZDC_TOTAL_LAYER_PIXELS}"
            ));
        }
        layers.push(Layer {
            pixels: Arc::new(pixels),
            offset: (off_x, off_y),
            name,
            opacity,
            blend,
            visible,
        });
    }
    Ok(RzDocument {
        width,
        height,
        layers,
    })
}

// -------------------------------------------------------------- psd import --

/// PSD -> RzDocument blend-mode mapping; PassThrough (group-only semantics)
/// and unknown values become Normal. The argument is the discriminant of
/// psd 0.3.5's `BlendMode` (the enum itself lives in a private module and is
/// not re-exported, so it cannot be named here — but its values are C-like
/// and cast losslessly): 0 PassThrough, 1 Normal, 2 Dissolve, 3 Darken,
/// 4 Multiply, 5 ColorBurn, 6 LinearBurn, 7 DarkerColor, 8 Lighten,
/// 9 Screen, 10 ColorDodge, 11 LinearDodge, 12 LighterColor, 13 Overlay,
/// 14 SoftLight, 15 HardLight, 16 VividLight, 17 LinearLight, 18 PinLight,
/// 19 HardMix, 20 Difference, 21 Exclusion, 22 Subtract, 23 Divide, 24 Hue,
/// 25 Saturation, 26 Color, 27 Luminosity.
fn map_psd_blend(mode: i32) -> BlendMode {
    match mode {
        2 => BlendMode::Dissolve,
        3 => BlendMode::Darken,
        4 => BlendMode::Multiply,
        5 => BlendMode::ColorBurn,
        6 => BlendMode::LinearBurn,
        7 => BlendMode::DarkerColor,
        8 => BlendMode::Lighten,
        9 => BlendMode::Screen,
        10 => BlendMode::ColorDodge,
        11 => BlendMode::Addition, // LinearDodge
        12 => BlendMode::LighterColor,
        13 => BlendMode::Overlay,
        14 => BlendMode::SoftLight,
        15 => BlendMode::HardLight,
        16 => BlendMode::VividLight,
        17 => BlendMode::LinearLight,
        18 => BlendMode::PinLight,
        19 => BlendMode::HardMix,
        20 => BlendMode::Difference,
        21 => BlendMode::Exclusion,
        22 => BlendMode::Subtract,
        23 => BlendMode::Divide,
        24 => BlendMode::Hue,
        25 => BlendMode::Saturation,
        26 => BlendMode::Color,
        27 => BlendMode::Luminosity,
        _ => BlendMode::Normal,
    }
}

/// Flattened-composite fallback: the whole PSD as one "Background" layer.
fn psd_composite_fallback(psd: &psd::Psd, path: &str) -> Result<RzDocument, String> {
    let pixels = RgbaImage::from_raw(psd.width(), psd.height(), psd.rgba())
        .ok_or_else(|| format!("PSD {path}: composite buffer size mismatch"))?;
    Ok(RzDocument::from_pixels(pixels))
}

/// Layered PSD import. One document layer per PSD raster layer; if the file
/// has no raster layers or any layer fails to decode, falls back to the
/// flattened composite.
///
/// psd 0.3.5 quirks this code compensates for (verified against the crate
/// sources and real files):
/// - `Psd::layers()` is ordered TOP-to-bottom (its `layer_by_idx` doc comment
///   claims the opposite, but the crate's own renderer consumes it top-down),
///   so the iteration is reversed for our bottom-first stack.
/// - `PsdLayer::visible()` actually returns the record's HIDDEN flag (bit 1
///   of the flags byte set means hidden in real files), so it is negated.
/// - `PsdLayer::rgba()` returns a CANVAS-sized buffer with the layer placed
///   at its rectangle — but for layers with no alpha channel it floods
///   alpha=255 across the whole canvas (opaque black outside the layer), and
///   for layers whose rectangle leaves the canvas it can panic. The buffer is
///   therefore cropped to the layer's rectangle intersected with the canvas
///   (which also yields real per-layer offsets), and each decode runs under
///   `catch_unwind`.
fn open_psd(bytes: &[u8], path: &str) -> Result<RzDocument, String> {
    let psd =
        psd::Psd::from_bytes(bytes).map_err(|e| format!("failed to decode PSD {path}: {e}"))?;
    // The psd crate silently mis-decodes anything but 8-bit RGB or grayscale
    // (CMYK channels land in RGB slots, 16-bit data is read byte-interleaved),
    // so reject those up front — same gate as the flat open path.
    if psd.depth() != psd::PsdDepth::Eight
        || !matches!(
            psd.color_mode(),
            psd::ColorMode::Rgb | psd::ColorMode::Grayscale
        )
    {
        return Err(format!(
            "PSD {path}: unsupported {:?} color at depth {:?}; only 8-bit RGB and grayscale PSDs are supported",
            psd.color_mode(),
            psd.depth()
        ));
    }
    let (cw, ch) = (psd.width(), psd.height());
    if cw == 0 || ch == 0 {
        return Err(format!("PSD {path}: empty canvas"));
    }
    if psd.layers().is_empty() {
        return psd_composite_fallback(&psd, path);
    }
    let canvas_len = cw as usize * ch as usize * 4;
    let mut layers = Vec::with_capacity(psd.layers().len());
    for l in psd.layers().iter().rev() {
        let rgba = match catch_unwind(AssertUnwindSafe(|| l.rgba())) {
            Ok(rgba) if rgba.len() == canvas_len => rgba,
            _ => return psd_composite_fallback(&psd, path),
        };
        // Intersect the layer rectangle (crate bounds are inclusive) with the
        // canvas.
        let x0 = l.layer_left().max(0) as i64;
        let y0 = l.layer_top().max(0) as i64;
        let x1 = (i64::from(l.layer_right()) + 1).min(i64::from(cw));
        let y1 = (i64::from(l.layer_bottom()) + 1).min(i64::from(ch));
        let (pixels, offset) = if x0 < x1 && y0 < y1 {
            let (w, h) = ((x1 - x0) as u32, (y1 - y0) as u32);
            let img = RgbaImage::from_fn(w, h, |x, y| {
                let cx = x0 as u32 + x;
                let cy = y0 as u32 + y;
                let i = (cy as usize * cw as usize + cx as usize) * 4;
                image::Rgba([rgba[i], rgba[i + 1], rgba[i + 2], rgba[i + 3]])
            });
            (img, (x0 as i32, y0 as i32))
        } else {
            // The layer is entirely outside the canvas; keep a minimal
            // transparent placeholder so the layer (and its properties)
            // survive the import.
            (RgbaImage::new(1, 1), (0, 0))
        };
        layers.push(Layer {
            pixels: Arc::new(pixels),
            offset,
            name: l.name().to_string(),
            opacity: f32::from(l.opacity()) / 255.0,
            blend: map_psd_blend(l.blend_mode() as i32),
            visible: !l.visible(),
        });
    }
    Ok(RzDocument {
        width: cw,
        height: ch,
        layers,
    })
}

// ------------------------------------------------------------------- open --

impl RzDocument {
    /// Opens a document, sniffing the container: "RZDC" is the native format,
    /// "8BPS" a Photoshop document (layered import), anything else decodes
    /// via the `RzImage::open` rules to a single "Background" layer.
    pub fn open(path: &str) -> Result<Self, String> {
        let bytes = std::fs::read(path).map_err(|e| format!("failed to read {path}: {e}"))?;
        if bytes.len() >= 4 && &bytes[..4] == b"RZDC" {
            parse_native(&bytes).map_err(|e| format!("failed to read document {path}: {e}"))
        } else if bytes.len() >= 4 && &bytes[..4] == b"8BPS" {
            open_psd(&bytes, path)
        } else {
            drop(bytes);
            Ok(RzDocument::from_pixels(RzImage::open(path)?.pixels))
        }
    }
}
