//! Selection-region and region-paint operations on the layered document:
//! magic-wand masks, mask feathering, bucket fill, two-color gradients,
//! and clearing a selected region to transparency.
//!
//! Conventions shared by all of them: coordinates are canvas pixels (row
//! 0 top); similarity means every RGBA channel differs by at most
//! `tolerance`; selection masks are canvas-sized u8 coverage buffers
//! (0 = outside, 255 = fully inside, intermediate values scale paint
//! coverage at anti-aliased edges).

use image::RgbaImage;
use std::collections::VecDeque;

use crate::blend::source_over_rgba8;
use crate::doc::RzDocument;

/// Per-channel similarity: every RGBA channel within `tolerance`.
fn similar(a: [u8; 4], b: [u8; 4], tolerance: u8) -> bool {
    a.iter()
        .zip(b.iter())
        .all(|(x, y)| x.abs_diff(*y) <= tolerance)
}

/// Grows a 0/255 region over `pixels` from `seed`: the connected flood
/// when `contiguous`, else every similar pixel in the image.
fn grow_region(pixels: &RgbaImage, seed: (u32, u32), tolerance: u8, contiguous: bool) -> Vec<u8> {
    let (w, h) = pixels.dimensions();
    let idx = |x: u32, y: u32| y as usize * w as usize + x as usize;
    let seed_color = pixels.get_pixel(seed.0, seed.1).0;
    let mut region = vec![0u8; w as usize * h as usize];
    if !contiguous {
        for (x, y, px) in pixels.enumerate_pixels() {
            if similar(px.0, seed_color, tolerance) {
                region[idx(x, y)] = 255;
            }
        }
        return region;
    }
    let mut queue = VecDeque::new();
    region[idx(seed.0, seed.1)] = 255;
    queue.push_back(seed);
    while let Some((x, y)) = queue.pop_front() {
        let neighbors = [
            (x.wrapping_sub(1), y),
            (x + 1, y),
            (x, y.wrapping_sub(1)),
            (x, y + 1),
        ];
        for (nx, ny) in neighbors {
            if nx >= w || ny >= h || region[idx(nx, ny)] != 0 {
                continue;
            }
            if similar(pixels.get_pixel(nx, ny).0, seed_color, tolerance) {
                region[idx(nx, ny)] = 255;
                queue.push_back((nx, ny));
            }
        }
    }
    region
}

/// Straight-alpha source-over of `src` (normalized RGBA) onto a straight
/// RGBA8 pixel, through the shared [`source_over_rgba8`] kernel. The master
/// premultiplied variant is `blend::paint_pixel`; this wrapper differs from
/// it in its degenerate-alpha handling (a genuine behavioral difference,
/// kept as-is): `paint_pixel` zeroes only the alpha byte below its 1e-6
/// output-alpha threshold, while this clears the whole pixel at exactly
/// zero — unreachable here, since `sa > 0` forces `out_a > 0`.
fn over_straight(src: [f32; 4], dst: &mut image::Rgba<u8>) {
    let sa = src[3];
    if sa <= 0.0 {
        return;
    }
    let da = f32::from(dst.0[3]) / 255.0;
    let out_a = sa + da * (1.0 - sa);
    if out_a <= 0.0 {
        dst.0 = [0, 0, 0, 0];
        return;
    }
    source_over_rgba8(&mut dst.0, [src[0] * sa, src[1] * sa, src[2] * sa], sa);
}

impl RzDocument {
    /// Similar-color selection mask sampled from the flattened composite
    /// ("select what you see"): canvas-sized 0/255 bytes. None when the
    /// seed lies outside the canvas.
    pub fn magic_wand(&self, x: u32, y: u32, tolerance: u8, contiguous: bool) -> Option<Vec<u8>> {
        if x >= self.width || y >= self.height {
            return None;
        }
        let composite = self.flattened();
        Some(grow_region(&composite, (x, y), tolerance, contiguous))
    }

    /// Bucket fill: grows a similar-color region over layer `idx`'s own
    /// pixels from canvas point (x, y) and paints `color` source-over it.
    /// `mask` (canvas-sized coverage, None for no selection) gates and
    /// scales the paint; a seed outside the canvas, the layer, or the
    /// mask yields None.
    // The parameter list deliberately mirrors `rz_doc_bucket_fill`'s C
    // signature one-for-one; bundling them into a struct would only move
    // the count somewhere else.
    #[allow(clippy::too_many_arguments)]
    pub fn bucket_fill(
        &self,
        idx: usize,
        x: i32,
        y: i32,
        tolerance: u8,
        color: [u8; 4],
        contiguous: bool,
        mask: Option<&[u8]>,
    ) -> Option<Self> {
        let canvas_px = self.width as usize * self.height as usize;
        if let Some(mask) = mask {
            if mask.len() != canvas_px {
                return None;
            }
        }
        if x < 0 || y < 0 || x as u32 >= self.width || y as u32 >= self.height {
            return None;
        }
        if let Some(mask) = mask {
            if mask[y as usize * self.width as usize + x as usize] == 0 {
                return None;
            }
        }
        let layer = self.layers.get(idx)?;
        let (off_x, off_y) = layer.offset;
        let (lw, lh) = layer.pixels.dimensions();
        let lx = x.checked_sub(off_x)?;
        let ly = y.checked_sub(off_y)?;
        if lx < 0 || ly < 0 || lx as u32 >= lw || ly as u32 >= lh {
            return None;
        }
        let region = grow_region(&layer.pixels, (lx as u32, ly as u32), tolerance, contiguous);
        let src = [
            f32::from(color[0]) / 255.0,
            f32::from(color[1]) / 255.0,
            f32::from(color[2]) / 255.0,
            f32::from(color[3]) / 255.0,
        ];
        let mut pixels = (*layer.pixels).clone();
        for (px_x, px_y, px) in pixels.enumerate_pixels_mut() {
            let covered = region[px_y as usize * lw as usize + px_x as usize];
            if covered == 0 {
                continue;
            }
            let coverage = mask_coverage(mask, self.width, self.height, off_x, off_y, px_x, px_y);
            if coverage == 0 {
                continue;
            }
            let mut paint = src;
            paint[3] *= f32::from(coverage) / 255.0;
            over_straight(paint, px);
        }
        self.with_layer_pixels(idx, pixels)
    }

    /// Paints a two-color gradient source-over layer `idx` (the whole
    /// layer, scaled by `mask` where given). Linear: along p0->p1,
    /// clamped past the ends. Radial: from p0 with radius |p1 - p0|.
    /// Colors interpolate straight RGBA. None if p0 == p1 or any
    /// coordinate is not finite.
    #[allow(clippy::too_many_arguments)]
    pub fn gradient(
        &self,
        idx: usize,
        p0: (f32, f32),
        p1: (f32, f32),
        start: [u8; 4],
        end: [u8; 4],
        radial: bool,
        mask: Option<&[u8]>,
    ) -> Option<Self> {
        if let Some(mask) = mask {
            if mask.len() != self.width as usize * self.height as usize {
                return None;
            }
        }
        if ![p0.0, p0.1, p1.0, p1.1].iter().all(|v| v.is_finite()) {
            return None;
        }
        let d = (p1.0 - p0.0, p1.1 - p0.1);
        let len2 = d.0 * d.0 + d.1 * d.1;
        if len2 <= 0.0 {
            return None;
        }
        let layer = self.layers.get(idx)?;
        let (off_x, off_y) = layer.offset;
        let c0 = start.map(|v| f32::from(v) / 255.0);
        let c1 = end.map(|v| f32::from(v) / 255.0);
        let mut pixels = (*layer.pixels).clone();
        for (px_x, px_y, px) in pixels.enumerate_pixels_mut() {
            let coverage = mask_coverage(mask, self.width, self.height, off_x, off_y, px_x, px_y);
            if coverage == 0 {
                continue;
            }
            // Pixel center in canvas coordinates.
            let cx = px_x as f32 + off_x as f32 + 0.5;
            let cy = px_y as f32 + off_y as f32 + 0.5;
            let t = if radial {
                (((cx - p0.0).powi(2) + (cy - p0.1).powi(2)) / len2).sqrt()
            } else {
                ((cx - p0.0) * d.0 + (cy - p0.1) * d.1) / len2
            }
            .clamp(0.0, 1.0);
            let mut paint = [
                c0[0] + (c1[0] - c0[0]) * t,
                c0[1] + (c1[1] - c0[1]) * t,
                c0[2] + (c1[2] - c0[2]) * t,
                c0[3] + (c1[3] - c0[3]) * t,
            ];
            paint[3] *= f32::from(coverage) / 255.0;
            over_straight(paint, px);
        }
        self.with_layer_pixels(idx, pixels)
    }

    /// Clears the selected region of layer `idx` to transparency, in
    /// PROPORTION to the selection's coverage. `mask` is the canvas-sized
    /// coverage buffer `bucket_fill` and `gradient` take, mapped onto the
    /// layer through its offset: a layer pixel takes the coverage `c` at
    /// its own canvas position and its straight alpha becomes
    /// `round(alpha * (255 - c) / 255)`, so full coverage erases it, half
    /// coverage halves its alpha and zero coverage leaves it exactly as it
    /// was — a feathered selection therefore cuts a soft-edged hole rather
    /// than a hard one. A pixel whose alpha reaches 0 also has its RGB
    /// zeroed; one that stays partly visible keeps its color untouched
    /// (pixels are STRAIGHT alpha, so scaling color would darken the
    /// surviving fringe). Layer pixels whose canvas position falls outside
    /// the canvas are untouched (a selection never reaches there), and only
    /// pixels change: the layer's mask, offset, name, opacity, blend mode,
    /// visibility and `meta` all survive.
    ///
    /// None on a mask that is not canvas-sized or an out-of-range `idx`. A
    /// mask that selects nothing is not an error: like `gradient` (which
    /// has no seed to validate either) it succeeds, returning a document
    /// whose pixels are unchanged.
    pub fn clear_selection(&self, idx: usize, mask: &[u8]) -> Option<Self> {
        if mask.len() != self.width as usize * self.height as usize {
            return None;
        }
        let layer = self.layers.get(idx)?;
        let (off_x, off_y) = layer.offset;
        let mut pixels = (*layer.pixels).clone();
        for (px_x, px_y, px) in pixels.enumerate_pixels_mut() {
            let coverage = mask_coverage(
                Some(mask),
                self.width,
                self.height,
                off_x,
                off_y,
                px_x,
                px_y,
            );
            // Unselected (and off-canvas) pixels keep every byte: the
            // formula is the identity there anyway.
            if coverage == 0 {
                continue;
            }
            // round(alpha * (255 - coverage) / 255) in integers; the +127
            // is the half step, and no product of two u8s can land exactly
            // on a .5 tie (255 is odd).
            let kept = u32::from(px.0[3]) * u32::from(255 - coverage);
            let alpha = ((kept + 127) / 255) as u8;
            if alpha == 0 {
                // Fully cleared: remove all color too.
                px.0 = [0, 0, 0, 0];
            } else {
                px.0[3] = alpha;
            }
        }
        self.with_layer_pixels(idx, pixels)
    }
}

/// Gaussian-feathers a selection mask in place (`width * height`
/// coverage bytes, row 0 top).
///
/// The kernel derives from `radius` the same way the machinery behind
/// the image blur does (the image crate's
/// `GaussianBlurParameters::new_from_radius`): the separable kernel
/// spans the nearest odd count of `2 * radius + 1` taps (floored at 3
/// so any positive radius softens) with
/// `sigma = 0.3 * (radius - 1) + 0.8`. Sampling clamps to the edges,
/// so a selection touching the canvas border keeps full coverage there
/// instead of fading toward zero from outside.
///
/// `radius <= 0` (or NaN/inf), a zero dimension, or a mask length that
/// does not match `width * height` is a no-op.
pub fn feather_mask(mask: &mut [u8], width: u32, height: u32, radius: f32) {
    let (w, h) = (width as usize, height as usize);
    if !radius.is_finite() || radius <= 0.0 || w == 0 || h == 0 || mask.len() != w * h {
        return;
    }
    let taps = nearest_odd(radius * 2.0 + 1.0).max(3);
    let half = (taps / 2) as i64;
    let sigma = 0.3 * (radius - 1.0) + 0.8;
    // Normalized 1-D Gaussian; the 1/(sqrt(2*pi)*sigma) scale cancels.
    let mut kernel: Vec<f32> = (0..taps)
        .map(|i| (-0.5 * ((i as i64 - half) as f32 / sigma).powi(2)).exp())
        .collect();
    let sum: f32 = kernel.iter().sum();
    for k in &mut kernel {
        *k /= sum;
    }

    // Horizontal pass into a float plane, then vertical back into the mask,
    // both clamping sample coordinates to the edges.
    let mut tmp = vec![0f32; w * h];
    for y in 0..h {
        let row = &mask[y * w..(y + 1) * w];
        for x in 0..w {
            let mut acc = 0.0;
            for (i, k) in kernel.iter().enumerate() {
                let sx = (x as i64 + i as i64 - half).clamp(0, w as i64 - 1) as usize;
                acc += k * f32::from(row[sx]);
            }
            tmp[y * w + x] = acc;
        }
    }
    for y in 0..h {
        for x in 0..w {
            let mut acc = 0.0;
            for (i, k) in kernel.iter().enumerate() {
                let sy = (y as i64 + i as i64 - half).clamp(0, h as i64 - 1) as usize;
                acc += k * tmp[sy * w + x];
            }
            mask[y * w + x] = acc.clamp(0.0, 255.0).round() as u8;
        }
    }
}

// -------------------------------------------------- selection morphology --
//
// Grow, shrink and border are defined on the signed Euclidean distance to
// the mask's 50% contour: coverage is binarized at >= 128 (deliberately
// resolving any feathered softness to its 50% contour), the exact squared
// Euclidean distance transform is taken both ways with the two-pass O(n)
// Felzenszwalb–Huttenlocher algorithm, and each pixel gets
//
//     s = (distance to nearest OUTSIDE pixel) - 0.5   if it is inside,
//     s = -((distance to nearest INSIDE pixel) - 0.5) if it is outside,
//
// so the contour sits at s = 0, halfway between an inside pixel and its
// outside neighbor. The canvas boundary is NOT a contour: the transform
// only sees the inside/outside pixels actually present in the buffer, so a
// full mask (no outside pixels, s = +inf everywhere) stays full under both
// grow and shrink, and an empty mask (no inside pixels, s = -inf) stays
// empty; border maps both to empty. New edges come back with a fresh ~1px
// anti-aliased ramp.

/// Grows (dilates) a selection mask in place by `radius` pixels of true
/// Euclidean distance: `coverage' = clamp(s + radius + 0.5, 0, 1) * 255`,
/// so edges move outward by `radius` and corners round into circular arcs.
///
/// `radius <= 0` (or NaN/inf), a zero dimension, or a mask length that
/// does not match `width * height` is a no-op, as in [`feather_mask`].
pub fn grow_mask(mask: &mut [u8], width: u32, height: u32, radius: f32) {
    let (w, h) = (width as usize, height as usize);
    if !radius.is_finite() || radius <= 0.0 || w == 0 || h == 0 || mask.len() != w * h {
        return;
    }
    offset_contour(mask, w, h, radius);
}

/// Shrinks (erodes) a selection mask in place by `radius` pixels:
/// [`grow_mask`] with `-radius`, so edges move inward and outside corners
/// round the same way. Same no-op conditions as [`grow_mask`].
pub fn shrink_mask(mask: &mut [u8], width: u32, height: u32, radius: f32) {
    let (w, h) = (width as usize, height as usize);
    if !radius.is_finite() || radius <= 0.0 || w == 0 || h == 0 || mask.len() != w * h {
        return;
    }
    offset_contour(mask, w, h, -radius);
}

/// Replaces a selection mask in place with an anti-aliased band `width_px`
/// wide straddling its 50% contour:
/// `coverage' = clamp(width_px/2 - |s| + 0.5, 0, 1) * 255`. A full or
/// empty mask has no contour and comes back empty.
///
/// `width_px <= 0` (or NaN/inf), a zero dimension, or a mask length that
/// does not match `width * height` is a no-op, as in [`feather_mask`].
pub fn border_mask(mask: &mut [u8], width: u32, height: u32, width_px: f32) {
    let (w, h) = (width as usize, height as usize);
    if !width_px.is_finite() || width_px <= 0.0 || w == 0 || h == 0 || mask.len() != w * h {
        return;
    }
    let sdf = signed_distance_field(mask, w, h);
    for (v, s) in mask.iter_mut().zip(sdf) {
        *v = coverage_byte(width_px * 0.5 - s.abs());
    }
}

/// Smooths a selection mask in place: a Gaussian blur with exactly
/// [`feather_mask`]'s sigma mapping, then a smoothstep contrast remap
/// (`t = v/255`, `v' = round(255 * t^2 * (3 - 2t))`). Corners round and
/// jagged edges reconcile, while a long straight edge stays put — the
/// blur is symmetric across it and smoothstep fixes 1/2. Unlike
/// grow/shrink/border this never binarizes: soft coverage stays soft.
/// Same no-op conditions as [`feather_mask`].
pub fn smooth_mask(mask: &mut [u8], width: u32, height: u32, radius: f32) {
    let (w, h) = (width as usize, height as usize);
    if !radius.is_finite() || radius <= 0.0 || w == 0 || h == 0 || mask.len() != w * h {
        return;
    }
    feather_mask(mask, width, height, radius);
    for v in mask.iter_mut() {
        let t = f32::from(*v) / 255.0;
        *v = (255.0 * t * t * (3.0 - 2.0 * t)).round() as u8;
    }
}

/// Rewrites `mask` as its 50% contour offset outward by `offset` pixels
/// (inward when negative): `coverage' = clamp(s + offset + 0.5, 0, 1) * 255`.
fn offset_contour(mask: &mut [u8], w: usize, h: usize, offset: f32) {
    let sdf = signed_distance_field(mask, w, h);
    for (v, s) in mask.iter_mut().zip(sdf) {
        *v = coverage_byte(s + offset);
    }
}

/// `clamp(x + 0.5, 0, 1) * 255`: a signed pixel distance inside the target
/// region mapped onto a coverage byte with a ~1px anti-aliased ramp.
/// Infinities clamp like any other out-of-range value.
fn coverage_byte(x: f32) -> u8 {
    ((x + 0.5).clamp(0.0, 1.0) * 255.0).round() as u8
}

/// The signed Euclidean distance from every pixel center to the mask's 50%
/// contour (see the section comment above): positive inside (coverage
/// `>= 128`), negative outside, `+inf`/`-inf` when the binarized mask has
/// no outside (resp. inside) pixels at all.
fn signed_distance_field(mask: &[u8], w: usize, h: usize) -> Vec<f32> {
    let len = w * h;
    let mut to_outside = vec![0f32; len];
    let mut to_inside = vec![0f32; len];
    for i in 0..len {
        if mask[i] >= 128 {
            to_outside[i] = f32::INFINITY;
        } else {
            to_inside[i] = f32::INFINITY;
        }
    }
    edt_squared(&mut to_outside, w, h);
    edt_squared(&mut to_inside, w, h);
    for i in 0..len {
        to_outside[i] = if mask[i] >= 128 {
            to_outside[i].sqrt() - 0.5
        } else {
            0.5 - to_inside[i].sqrt()
        };
    }
    to_outside
}

/// Exact squared Euclidean distance transform, columns then rows through
/// the 1-D lower-envelope pass (Felzenszwalb–Huttenlocher). On input,
/// `grid` holds 0 at site pixels and `+inf` elsewhere; on output, each
/// cell is the squared distance to its nearest site (`+inf` when the grid
/// has no sites at all).
fn edt_squared(grid: &mut [f32], w: usize, h: usize) {
    let n = w.max(h);
    let mut f = vec![0f32; n];
    let mut d = vec![0f32; n];
    let mut v = vec![0usize; n];
    let mut z = vec![0f32; n + 1];
    for x in 0..w {
        for y in 0..h {
            f[y] = grid[y * w + x];
        }
        edt_1d(&f[..h], &mut d[..h], &mut v, &mut z);
        for y in 0..h {
            grid[y * w + x] = d[y];
        }
    }
    for y in 0..h {
        f[..w].copy_from_slice(&grid[y * w..(y + 1) * w]);
        edt_1d(&f[..w], &mut d[..w], &mut v, &mut z);
        grid[y * w..(y + 1) * w].copy_from_slice(&d[..w]);
    }
}

/// One 1-D pass of the Felzenszwalb–Huttenlocher transform:
/// `d[q] = min_p (q - p)^2 + f[p]`. `+inf` entries in `f` never seed a
/// parabola (a line with no finite entry comes back all `+inf`), which is
/// what makes a site-free grid legal. `v` and `z` are scratch for the
/// lower envelope: parabola vertices and the boundaries between them.
fn edt_1d(f: &[f32], d: &mut [f32], v: &mut [usize], z: &mut [f32]) {
    let n = f.len();
    let mut k = 0usize;
    let mut seeded = false;
    for q in 0..n {
        if f[q] == f32::INFINITY {
            continue;
        }
        if !seeded {
            seeded = true;
            v[0] = q;
            z[0] = f32::NEG_INFINITY;
            z[1] = f32::INFINITY;
            continue;
        }
        // Intersection of q's parabola with the rightmost one kept; pop
        // envelopes it fully covers. `s` is finite (finite f, q > p), so
        // the loop stops at z[0] = -inf at the latest and k never wraps.
        let mut s;
        loop {
            let p = v[k];
            s = ((f[q] + (q * q) as f32) - (f[p] + (p * p) as f32))
                / ((2 * q) as f32 - (2 * p) as f32);
            if s > z[k] {
                break;
            }
            k -= 1;
        }
        k += 1;
        v[k] = q;
        z[k] = s;
        z[k + 1] = f32::INFINITY;
    }
    if !seeded {
        d[..n].fill(f32::INFINITY);
        return;
    }
    let mut k = 0usize;
    for (q, dq) in d.iter_mut().enumerate().take(n) {
        while z[k + 1] < q as f32 {
            k += 1;
        }
        let p = v[k];
        *dq = (q as f32 - p as f32).powi(2) + f[p];
    }
}

/// Nearest odd integer to `x` (ties resolve to the lower odd value),
/// mirroring the image crate's kernel-size rounding. `x` must be >= 1.
fn nearest_odd(x: f32) -> u32 {
    let n = x.round().max(1.0) as u32;
    if n % 2 == 1 {
        n
    } else if x - (n - 1) as f32 <= (n + 1) as f32 - x {
        n - 1
    } else {
        n + 1
    }
}

/// Coverage of the layer pixel (px_x, px_y) under the optional canvas
/// mask: 255 without a mask; the mask byte at the pixel's canvas
/// position with one, and 0 off-canvas (a selection never extends
/// beyond the canvas).
fn mask_coverage(
    mask: Option<&[u8]>,
    canvas_w: u32,
    canvas_h: u32,
    off_x: i32,
    off_y: i32,
    px_x: u32,
    px_y: u32,
) -> u8 {
    let Some(mask) = mask else { return 255 };
    let cx = px_x as i64 + i64::from(off_x);
    let cy = px_y as i64 + i64::from(off_y);
    if cx < 0 || cy < 0 || cx >= i64::from(canvas_w) || cy >= i64::from(canvas_h) {
        return 0;
    }
    mask[cy as usize * canvas_w as usize + cx as usize]
}
