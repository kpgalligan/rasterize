//! Selection-region and region-paint operations on the layered document:
//! magic-wand masks, bucket fill, and two-color gradients.
//!
//! Conventions shared by all three: coordinates are canvas pixels (row 0
//! top); similarity means every RGBA channel differs by at most
//! `tolerance`; selection masks are canvas-sized u8 coverage buffers
//! (0 = outside, 255 = fully inside, intermediate values scale paint
//! coverage at anti-aliased edges).

use image::RgbaImage;
use std::collections::VecDeque;

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
/// RGBA8 pixel.
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
    for c in 0..3 {
        let dc = f32::from(dst.0[c]) / 255.0;
        let out = (src[c] * sa + dc * da * (1.0 - sa)) / out_a;
        dst.0[c] = (out.clamp(0.0, 1.0) * 255.0).round() as u8;
    }
    dst.0[3] = (out_a.clamp(0.0, 1.0) * 255.0).round() as u8;
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
