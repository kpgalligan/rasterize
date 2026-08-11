//! Free transform: one layer resampled through an arbitrary affine matrix.
//!
//! Conventions, all fixed by [`RzDocument::transform_layer`] and restated in
//! the C header:
//!
//! - The matrix works in CANVAS coordinates. A layer occupies the canvas rect
//!   `offset .. offset + pixel dimensions`; the matrix says where that rect
//!   lands, and the new offset/size fall out of the transformed corners'
//!   bounding box (rounded outward, so nothing is clipped).
//! - Resampling is inverse-mapped: every DESTINATION pixel centre is mapped
//!   back through the inverse matrix and sampled in the source. Samples that
//!   fall outside the source pixels are fully transparent, which is also what
//!   makes the edges fade out instead of stopping abruptly.
//! - Interpolation happens in PREMULTIPLIED f32 and is unpremultiplied on the
//!   way out. Interpolating straight RGBA would drag the (meaningless) color
//!   of fully transparent neighbours into edge pixels and fringe them.
//! - A layer mask rides along: it is layer-sized by construction (the Phase 2
//!   invariant), so it is resampled with the SAME matrix, the SAME destination
//!   extent and the SAME kernel, landing pixel-for-pixel on the transformed
//!   pixels. Coverage is a single straight channel, so it needs no
//!   premultiplication dance.

use std::sync::Arc;

use image::imageops::FilterType;
use image::{GrayImage, RgbaImage};

use crate::doc::{Geometry, Layer, RzDocument, MAX_PIXELS};

/// Smallest determinant magnitude that still counts as invertible. Anything
/// smaller collapses the layer onto a line or a point, which cannot be
/// inverse-mapped (and whose bounding box would be empty anyway).
const MIN_DETERMINANT: f64 = 1e-9;

/// How far a value may sit from an exact 0, +/-1 or integer and still be
/// treated as that exact value — used both to recognize the resampling-free
/// matrices and to keep a hair's-breadth overshoot from widening the
/// destination extent by a whole pixel.
///
/// Hosts do not hand over hand-written matrices; they COMPOSE them, and
/// `cos(PI/2)` is 6.123e-17 rather than 0. Comparing against exact zeros
/// would therefore never recognize a quarter turn built from an angle, and
/// the same 1e-17-scale residue turns a corner at 60 into 60.000000000000006,
/// whose ceil is 61 — a phantom, fully transparent column.
///
/// 1e-9 sits in the wide gap between the two error scales that matter:
///
/// - Above the noise: composing a rotation and a scale accumulates a few ULPs,
///   i.e. ~1e-16 RELATIVE error, so any coordinate up to ~1e7 — far larger
///   than any realistic canvas — still lands within 1e-9 of its true value.
///   A relative epsilon would buy nothing at these magnitudes and would make
///   the fast path depend on how far from the origin the layer sits; and past
///   1e7 an absolute epsilon simply stops matching, which costs a resample
///   (the behaviour before this tolerance existed) rather than correctness.
/// - Below anything a user can mean: the nearest angle to a right angle a UI
///   can express, 89.999 degrees, is 1.7e-5 radians off, which throws the
///   linear elements ~1.7e-5 off exact and the corners of even a 1-pixel layer
///   ~1e-5 off an integer — four orders of magnitude outside this epsilon, so
///   it still resamples. Nothing user-visible is snapped: a sub-nanopixel
///   difference cannot survive quantization to a u8 pixel grid.
///
/// It is also the tolerance the app's own identity check uses on a composed
/// matrix's linear part (`LayerTransform.isIdentity`), so the two agree on
/// what counts as "the same transform".
const EXACT_EPSILON: f64 = 1e-9;

/// True when `v` is within [`EXACT_EPSILON`] of `target`.
fn near(v: f64, target: f64) -> bool {
    (v - target).abs() <= EXACT_EPSILON
}

/// Snaps a coordinate sitting within [`EXACT_EPSILON`] of an integer onto that
/// integer. Applied to the transformed corners BEFORE the outward rounding, so
/// a composition's floating-point residue cannot inflate the extent.
fn snap_to_integer(v: f64) -> f64 {
    let rounded = v.round();
    if near(v, rounded) {
        rounded
    } else {
        v
    }
}

/// Widest separable kernel support: Lanczos3 takes six taps per axis.
const MAX_TAPS: usize = 6;

// ------------------------------------------------------------------ matrix --

/// A 2x3 affine matrix in CANVAS space, in `CGAffineTransform` element order:
/// `[a, b, c, d, tx, ty]` maps `(x, y)` to
/// `(a*x + c*y + tx, b*x + d*y + ty)`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Affine {
    /// x scale (row 0, column 0).
    pub a: f64,
    /// y shear (row 0, column 1).
    pub b: f64,
    /// x shear (row 1, column 0).
    pub c: f64,
    /// y scale (row 1, column 1).
    pub d: f64,
    /// x translation.
    pub tx: f64,
    /// y translation.
    pub ty: f64,
}

impl Affine {
    /// Reads the six elements in the order the FFI receives them
    /// (`[a, b, c, d, tx, ty]`).
    pub fn from_array(m: [f64; 6]) -> Self {
        Affine {
            a: m[0],
            b: m[1],
            c: m[2],
            d: m[3],
            tx: m[4],
            ty: m[5],
        }
    }

    fn is_finite(&self) -> bool {
        [self.a, self.b, self.c, self.d, self.tx, self.ty]
            .iter()
            .all(|v| v.is_finite())
    }

    fn determinant(&self) -> f64 {
        self.a * self.d - self.b * self.c
    }

    fn apply(&self, x: f64, y: f64) -> (f64, f64) {
        (
            self.a * x + self.c * y + self.tx,
            self.b * x + self.d * y + self.ty,
        )
    }

    /// The inverse map, or `None` when the matrix is singular (or so close to
    /// it that the inverse is meaningless).
    fn inverse(&self) -> Option<Affine> {
        let det = self.determinant();
        if !det.is_finite() || det.abs() < MIN_DETERMINANT {
            return None;
        }
        let inv = Affine {
            a: self.d / det,
            b: -self.b / det,
            c: -self.c / det,
            d: self.a / det,
            tx: (self.c * self.ty - self.d * self.tx) / det,
            ty: (self.b * self.tx - self.a * self.ty) / det,
        };
        if inv.is_finite() {
            Some(inv)
        } else {
            None
        }
    }
}

/// A matrix that needs no resampling at all.
enum Exact {
    /// Integer translation only: the pixels are reused as they are.
    Translate,
    /// An integer translation composed with one of the five exact
    /// axis-aligned transforms, which the shared [`Geometry`] path applies to
    /// the pixels and the mask alike.
    Geom(Geometry),
}

/// Recognizes the matrices whose sampling would be a plain pixel copy: an
/// INTEGER translation (so destination pixel centres land exactly on source
/// pixel centres) combined with an axis-aligned linear part of 0s and +/-1s.
/// Both are matched within [`EXACT_EPSILON`], because a host composes these
/// matrices from an angle rather than writing them out, and the caller then
/// takes the destination extent from [`transformed_bounds`], which snaps the
/// same residue away. Anything else returns `None` and is resampled.
fn exact_form(m: &Affine) -> Option<Exact> {
    if !near(m.tx, m.tx.round()) || !near(m.ty, m.ty.round()) {
        return None;
    }
    // Linear parts as [a, b, c, d]. Rotate90 is the canvas-space map
    // (x, y) -> (-y, x), matching `imageops::rotate90` on a y-down canvas.
    let forms: [([f64; 4], Option<Geometry>); 6] = [
        ([1.0, 0.0, 0.0, 1.0], None),
        ([-1.0, 0.0, 0.0, 1.0], Some(Geometry::FlipH)),
        ([1.0, 0.0, 0.0, -1.0], Some(Geometry::FlipV)),
        ([-1.0, 0.0, 0.0, -1.0], Some(Geometry::Rotate180)),
        ([0.0, 1.0, -1.0, 0.0], Some(Geometry::Rotate90)),
        ([0.0, -1.0, 1.0, 0.0], Some(Geometry::Rotate270)),
    ];
    let linear = [m.a, m.b, m.c, m.d];
    forms
        .iter()
        .find(|(f, _)| f.iter().zip(linear).all(|(&want, got)| near(got, want)))
        .map(|(_, geom)| geom.map_or(Exact::Translate, Exact::Geom))
}

// ----------------------------------------------------------------- samplers --

/// The separable interpolation kernels. Each is normalized over its full
/// support (including taps that fall outside the source, which contribute
/// nothing) so edges fade toward transparency instead of smearing the border.
#[derive(Clone, Copy)]
enum Kernel {
    /// Triangle filter, 2x2 taps.
    Bilinear,
    /// Catmull-Rom bicubic, 4x4 taps.
    Bicubic,
    /// Lanczos, 6x6 taps.
    Lanczos3,
}

impl Kernel {
    /// Half-width of the support, in source pixels.
    fn radius(self) -> i64 {
        match self {
            Kernel::Bilinear => 1,
            Kernel::Bicubic => 2,
            Kernel::Lanczos3 => 3,
        }
    }

    fn taps(self) -> usize {
        2 * self.radius() as usize
    }

    fn weight(self, t: f32) -> f32 {
        let x = t.abs();
        match self {
            Kernel::Bilinear => (1.0 - x).max(0.0),
            Kernel::Bicubic => {
                // Catmull-Rom (Mitchell with B = 0, C = 0.5): interpolating,
                // so an exact hit reproduces the source sample.
                if x < 1.0 {
                    ((1.5 * x - 2.5) * x) * x + 1.0
                } else if x < 2.0 {
                    ((-0.5 * x + 2.5) * x - 4.0) * x + 2.0
                } else {
                    0.0
                }
            }
            Kernel::Lanczos3 => {
                // sinc(x) * sinc(x/3), written to avoid 0/0 at the centre.
                if x < 1e-6 {
                    1.0
                } else if x < 3.0 {
                    let px = std::f32::consts::PI * x;
                    3.0 * px.sin() * (px / 3.0).sin() / (px * px)
                } else {
                    0.0
                }
            }
        }
    }

    /// Fills `out[..taps]` with the normalized tap weights for the continuous
    /// source coordinate `s` (pixel `k` covers `[k, k+1)`), returning the
    /// index of the first tap.
    fn weights(self, s: f64, out: &mut [f32; MAX_TAPS]) -> i64 {
        // Index space: integers are pixel CENTRES.
        let p = s - 0.5;
        let base = p.floor();
        let lead = self.radius() - 1;
        let mut sum = 0.0f32;
        for (t, w) in out.iter_mut().enumerate().take(self.taps()) {
            *w = self.weight((p - (base + t as f64 - lead as f64)) as f32);
            sum += *w;
        }
        if sum != 0.0 && sum != 1.0 {
            for w in out.iter_mut().take(self.taps()) {
                *w /= sum;
            }
        }
        // `as` saturates, so an absurd coordinate simply lands out of bounds.
        (base as i64).saturating_sub(lead)
    }
}

/// Point sampling or one of the interpolating kernels, chosen by the caller's
/// `RzResizeFilter`.
#[derive(Clone, Copy)]
enum Sampler {
    /// Copies the covering source pixel's BYTES, straight alpha included.
    Nearest,
    Kernel(Kernel),
}

impl Sampler {
    /// Maps the shared resize-filter enum onto a transform sampler. The
    /// `image` crate's Gaussian filter has no `RzResizeFilter` value, so the
    /// FFI never asks for it; it is refused rather than quietly substituted.
    fn from_filter(filter: FilterType) -> Option<Self> {
        match filter {
            FilterType::Nearest => Some(Sampler::Nearest),
            FilterType::Triangle => Some(Sampler::Kernel(Kernel::Bilinear)),
            FilterType::CatmullRom => Some(Sampler::Kernel(Kernel::Bicubic)),
            FilterType::Lanczos3 => Some(Sampler::Kernel(Kernel::Lanczos3)),
            _ => None,
        }
    }
}

/// Maps destination pixel indices to source-LAYER coordinates: the inverse
/// matrix pre-composed with "destination pixel centre" on one side and the
/// layer's offset on the other, so `(u, v)` is a continuous coordinate in the
/// source layer's own pixel space.
struct SourceMap {
    /// Per-destination-column step.
    step: (f64, f64),
    /// Per-destination-row step.
    row: (f64, f64),
    /// The source coordinate of destination pixel (0, 0).
    origin: (f64, f64),
}

impl SourceMap {
    fn new(inv: &Affine, offset: (i32, i32), dest_origin: (i32, i32)) -> Self {
        let (u0, v0) = inv.apply(
            f64::from(dest_origin.0) + 0.5,
            f64::from(dest_origin.1) + 0.5,
        );
        SourceMap {
            step: (inv.a, inv.b),
            row: (inv.c, inv.d),
            origin: (u0 - f64::from(offset.0), v0 - f64::from(offset.1)),
        }
    }

    fn row_start(&self, j: u32) -> (f64, f64) {
        (
            self.origin.0 + self.row.0 * f64::from(j),
            self.origin.1 + self.row.1 * f64::from(j),
        )
    }
}

/// Index of the source pixel covering `(u, v)`, or `None` outside the source.
fn covering_pixel(u: f64, v: f64, w: u32, h: u32) -> Option<usize> {
    let (x, y) = (u.floor(), v.floor());
    if x < 0.0 || y < 0.0 || x >= f64::from(w) || y >= f64::from(h) {
        return None;
    }
    Some(y as usize * w as usize + x as usize)
}

/// Quantizes an accumulated coverage/alpha value exactly the way both
/// resamplers must, so a mask and an identical alpha channel stay equal.
/// Kernels with negative lobes can under- and overshoot, hence the clamp.
fn quantize_coverage(acc: f32) -> u8 {
    acc.clamp(0.0, 255.0).round() as u8
}

/// Inverse-maps `src` onto the destination extent, interpolating in
/// PREMULTIPLIED f32 and unpremultiplying on the way out. Destination pixels
/// whose source neighbourhood is entirely outside `src` come out fully
/// transparent (all four bytes zero).
fn resample_rgba(
    src: &RgbaImage,
    offset: (i32, i32),
    dest: (i32, i32, u32, u32),
    inv: &Affine,
    sampler: Sampler,
) -> RgbaImage {
    let (dx, dy, dw, dh) = dest;
    let (sw, sh) = src.dimensions();
    let raw = src.as_raw();
    let map = SourceMap::new(inv, offset, (dx, dy));
    let mut out = RgbaImage::new(dw, dh);
    let dst: &mut [u8] = &mut out;
    let mut wx = [0.0f32; MAX_TAPS];
    let mut wy = [0.0f32; MAX_TAPS];
    for j in 0..dh {
        let (mut u, mut v) = map.row_start(j);
        for i in 0..dw {
            let di = (j as usize * dw as usize + i as usize) * 4;
            match sampler {
                Sampler::Nearest => {
                    if let Some(si) = covering_pixel(u, v, sw, sh) {
                        dst[di..di + 4].copy_from_slice(&raw[si * 4..si * 4 + 4]);
                    }
                }
                Sampler::Kernel(kernel) => {
                    let taps = kernel.taps();
                    let x0 = kernel.weights(u, &mut wx);
                    let y0 = kernel.weights(v, &mut wy);
                    let mut acc = [0.0f32; 4];
                    for (ty, &wyt) in wy.iter().enumerate().take(taps) {
                        let sy = y0 + ty as i64;
                        if wyt == 0.0 || sy < 0 || sy >= i64::from(sh) {
                            continue;
                        }
                        let row = sy as usize * sw as usize;
                        for (tx, &wxt) in wx.iter().enumerate().take(taps) {
                            let sx = x0 + tx as i64;
                            if wxt == 0.0 || sx < 0 || sx >= i64::from(sw) {
                                continue;
                            }
                            let w = wyt * wxt;
                            let si = (row + sx as usize) * 4;
                            // Premultiplied: the color of a transparent pixel
                            // contributes nothing, so edges cannot fringe.
                            let a = f32::from(raw[si + 3]);
                            let pm = w * a * (1.0 / 255.0);
                            acc[0] += pm * f32::from(raw[si]);
                            acc[1] += pm * f32::from(raw[si + 1]);
                            acc[2] += pm * f32::from(raw[si + 2]);
                            acc[3] += w * a;
                        }
                    }
                    // A destination pixel whose neighbourhood is entirely
                    // outside the source keeps all four bytes zero.
                    let alpha = quantize_coverage(acc[3]);
                    if alpha != 0 {
                        // Unpremultiply by the RAW accumulated alpha (> 0
                        // here), not by the clamped byte: a kernel with
                        // negative lobes can overshoot past 255, and dividing
                        // by the clamp would drag the color along with it.
                        let scale = 255.0 / acc[3];
                        for c in 0..3 {
                            dst[di + c] = (acc[c] * scale).clamp(0.0, 255.0).round() as u8;
                        }
                        dst[di + 3] = alpha;
                    }
                }
            }
            u += map.step.0;
            v += map.step.1;
        }
    }
    out
}

/// The single-channel twin of [`resample_rgba`], run over the same
/// destination extent with the same map and kernel so the mask lands
/// pixel-for-pixel on the transformed pixels. Coverage is straight, so there
/// is nothing to premultiply; outside the source the mask is 0 (hidden), and
/// the pixels there are transparent anyway.
fn resample_mask(
    src: &GrayImage,
    offset: (i32, i32),
    dest: (i32, i32, u32, u32),
    inv: &Affine,
    sampler: Sampler,
) -> GrayImage {
    let (dx, dy, dw, dh) = dest;
    let (sw, sh) = src.dimensions();
    let raw = src.as_raw();
    let map = SourceMap::new(inv, offset, (dx, dy));
    let mut out = GrayImage::new(dw, dh);
    let dst: &mut [u8] = &mut out;
    let mut wx = [0.0f32; MAX_TAPS];
    let mut wy = [0.0f32; MAX_TAPS];
    for j in 0..dh {
        let (mut u, mut v) = map.row_start(j);
        for i in 0..dw {
            let di = j as usize * dw as usize + i as usize;
            match sampler {
                Sampler::Nearest => {
                    if let Some(si) = covering_pixel(u, v, sw, sh) {
                        dst[di] = raw[si];
                    }
                }
                Sampler::Kernel(kernel) => {
                    let taps = kernel.taps();
                    let x0 = kernel.weights(u, &mut wx);
                    let y0 = kernel.weights(v, &mut wy);
                    let mut acc = 0.0f32;
                    for (ty, &wyt) in wy.iter().enumerate().take(taps) {
                        let sy = y0 + ty as i64;
                        if wyt == 0.0 || sy < 0 || sy >= i64::from(sh) {
                            continue;
                        }
                        let row = sy as usize * sw as usize;
                        for (tx, &wxt) in wx.iter().enumerate().take(taps) {
                            let sx = x0 + tx as i64;
                            if wxt == 0.0 || sx < 0 || sx >= i64::from(sw) {
                                continue;
                            }
                            let w = wyt * wxt;
                            acc += w * f32::from(raw[row + sx as usize]);
                        }
                    }
                    dst[di] = quantize_coverage(acc);
                }
            }
            u += map.step.0;
            v += map.step.1;
        }
    }
    out
}

/// The destination placement: the axis-aligned bounding box of the layer
/// rect's four transformed corners, rounded OUTWARD (floor of the minima,
/// ceil of the maxima) so no source pixel is clipped. A corner within
/// [`EXACT_EPSILON`] of an integer is snapped onto it FIRST: without that, a
/// composed quarter turn whose corner lands on 60.000000000000006 would ceil
/// to 61 and grow a fully transparent column. Genuinely fractional corners are
/// untouched and still round outward. `None` when the box is not finite, does
/// not fit the i32 offset range, collapses to zero pixels, or exceeds
/// [`MAX_PIXELS`].
fn transformed_bounds(layer: &Layer, m: &Affine) -> Option<(i32, i32, u32, u32)> {
    let (lw, lh) = layer.pixels.dimensions();
    let (x0, y0) = (f64::from(layer.offset.0), f64::from(layer.offset.1));
    let (x1, y1) = (x0 + f64::from(lw), y0 + f64::from(lh));
    let corners = [
        m.apply(x0, y0),
        m.apply(x1, y0),
        m.apply(x0, y1),
        m.apply(x1, y1),
    ];
    let mut min = (f64::INFINITY, f64::INFINITY);
    let mut max = (f64::NEG_INFINITY, f64::NEG_INFINITY);
    for (x, y) in corners {
        if !x.is_finite() || !y.is_finite() {
            return None;
        }
        let (x, y) = (snap_to_integer(x), snap_to_integer(y));
        min = (min.0.min(x), min.1.min(y));
        max = (max.0.max(x), max.1.max(y));
    }
    let (left, top) = (min.0.floor(), min.1.floor());
    let (right, bottom) = (max.0.ceil(), max.1.ceil());
    if left < f64::from(i32::MIN)
        || top < f64::from(i32::MIN)
        || right > f64::from(i32::MAX)
        || bottom > f64::from(i32::MAX)
    {
        return None;
    }
    let (w, h) = ((right - left) as u64, (bottom - top) as u64);
    if w == 0 || h == 0 || w.checked_mul(h)? > MAX_PIXELS {
        return None;
    }
    Some((left as i32, top as i32, w as u32, h as u32))
}

impl RzDocument {
    /// Transforms layer `idx` by `m`, an affine matrix in CANVAS coordinates:
    /// the layer's rect (its offset plus its pixel dimensions) is mapped
    /// through `m`, and the layer's new offset and size come from the
    /// axis-aligned bounding box of the four transformed corners, rounded
    /// outward. Pixels are resampled by inverse mapping every destination
    /// pixel centre; samples outside the source are fully transparent.
    ///
    /// Only the named layer changes: the canvas is untouched (a transformed
    /// layer may extend past it, exactly like any other offset layer), as are
    /// every other layer and all of this layer's properties — name, opacity,
    /// blend mode, visibility, mask-enabled flag and `meta` (the core never
    /// interprets `meta`; deciding whether a transform invalidates it is the
    /// host's policy). An existing layer MASK is resampled with the same
    /// matrix, extent and kernel, so it stays exactly the layer's size.
    ///
    /// Exact matrices — an integer translation optionally composed with a
    /// flip or a 90-degree multiple — skip resampling entirely and reuse the
    /// lossless pixel-copy paths, so they are byte-identical to the dedicated
    /// `rotate90`/`flip_*` ops. "Exact" is judged within [`EXACT_EPSILON`], so
    /// a quarter turn COMPOSED from an angle (where `cos` returns 6e-17
    /// instead of 0) qualifies too, and its extent is not inflated by that
    /// residue. A transform that is fractional by any user-meaningful amount
    /// resamples as usual.
    ///
    /// Returns `None` when `idx` is out of range, any matrix element is not
    /// finite, the matrix is singular (`|determinant| < 1e-9`), the filter is
    /// not one of the four `RzResizeFilter` values, or the destination extent
    /// is empty, outside the i32 offset range, or over [`MAX_PIXELS`].
    pub fn transform_layer(&self, idx: usize, m: Affine, filter: FilterType) -> Option<Self> {
        let layer = self.layers.get(idx)?;
        if !m.is_finite() {
            return None;
        }
        let sampler = Sampler::from_filter(filter)?;
        let inverse = m.inverse()?;
        let dest = transformed_bounds(layer, &m)?;
        let (dx, dy, dw, dh) = dest;

        let (pixels, mask) = match exact_form(&m) {
            // The exact forms produce the destination extent by construction;
            // the dimension check is belt-and-braces before trusting them.
            Some(Exact::Translate) if layer.pixels.dimensions() == (dw, dh) => {
                (Arc::clone(&layer.pixels), layer.mask.clone())
            }
            Some(Exact::Geom(geom)) if rotated_dims(&layer.pixels, geom) == (dw, dh) => (
                Arc::new(geom.apply(&*layer.pixels)),
                layer.mask.as_ref().map(|m| Arc::new(geom.apply(&**m))),
            ),
            _ => (
                Arc::new(resample_rgba(
                    &layer.pixels,
                    layer.offset,
                    dest,
                    &inverse,
                    sampler,
                )),
                layer.mask.as_ref().map(|mask| {
                    Arc::new(resample_mask(mask, layer.offset, dest, &inverse, sampler))
                }),
            ),
        };

        let mut doc = self.clone();
        let target = doc.layers.get_mut(idx)?;
        target.pixels = pixels;
        target.mask = mask;
        target.offset = (dx, dy);
        Some(doc)
    }
}

/// The dimensions `geom` would produce from `img`.
fn rotated_dims(img: &RgbaImage, geom: Geometry) -> (u32, u32) {
    let (w, h) = img.dimensions();
    match geom {
        Geometry::Rotate90 | Geometry::Rotate270 => (h, w),
        _ => (w, h),
    }
}
