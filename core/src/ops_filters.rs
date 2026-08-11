//! Additional pure filters: hue rotate, levels, threshold, posterize,
//! pixelate, noise, edge detect, emboss. See include/rasterize_core.h.
//!
//! Every function returns a new image and never mutates its input; invalid
//! arguments yield `None` (surfaced as NULL through the FFI). Color math is
//! f32 per channel, rounded and clamped back to u8; alpha passes through
//! untouched unless a filter's contract says otherwise.

use image::{Rgba, RgbaImage};

/// Rec. 709 luma coefficients (private copy; `ops` keeps its own).
const LUMA_R: f32 = 0.2126;
const LUMA_G: f32 = 0.7152;
const LUMA_B: f32 = 0.0722;

/// The hueRotate matrix from the SVG filter effects specification, built
/// from cos/sin of `degrees` (no HSL round-trip). Shared with the
/// `hue_rotate` adjustment layer (`adjust`) so both produce the same colors.
pub(crate) fn hue_rotate_matrix(degrees: f32) -> [[f32; 3]; 3] {
    let (s, c) = degrees.to_radians().sin_cos();
    [
        [
            0.213 + c * 0.787 - s * 0.213,
            0.715 - c * 0.715 - s * 0.715,
            0.072 - c * 0.072 + s * 0.928,
        ],
        [
            0.213 - c * 0.213 + s * 0.143,
            0.715 + c * 0.285 + s * 0.140,
            0.072 - c * 0.072 - s * 0.283,
        ],
        [
            0.213 - c * 0.213 - s * 0.787,
            0.715 - c * 0.715 + s * 0.715,
            0.072 + c * 0.928 + s * 0.072,
        ],
    ]
}

/// Rotates hue by `degrees` using [`hue_rotate_matrix`]. Any finite angle
/// is accepted; returns `None` for NaN or infinite values. Alpha untouched.
pub(crate) fn hue_rotate(img: &RgbaImage, degrees: f32) -> Option<RgbaImage> {
    if !degrees.is_finite() {
        return None;
    }
    let m = hue_rotate_matrix(degrees);
    let mut out = img.clone();
    for px in out.pixels_mut() {
        let r = f32::from(px[0]) / 255.0;
        let g = f32::from(px[1]) / 255.0;
        let b = f32::from(px[2]) / 255.0;
        for (dst, row) in px.0.iter_mut().zip(&m) {
            let v = row[0] * r + row[1] * g + row[2] * b;
            *dst = (v.clamp(0.0, 1.0) * 255.0).round() as u8;
        }
    }
    Some(out)
}

/// Levels: maps [black, white] to [0, 1], then applies gamma
/// (`out = t^(1/gamma)`). Requires `0 <= black < white <= 1` and gamma in
/// [0.1, 10]; returns `None` otherwise (NaN fails every comparison).
pub(crate) fn levels(img: &RgbaImage, black: f32, white: f32, gamma: f32) -> Option<RgbaImage> {
    if !(black >= 0.0 && black < white && white <= 1.0 && (0.1..=10.0).contains(&gamma)) {
        return None;
    }
    let range = white - black;
    let inv_gamma = 1.0 / gamma;
    let mut out = img.clone();
    for px in out.pixels_mut() {
        for ch in px.0.iter_mut().take(3) {
            let t = ((f32::from(*ch) / 255.0 - black) / range).clamp(0.0, 1.0);
            *ch = (t.powf(inv_gamma) * 255.0).round() as u8;
        }
    }
    Some(out)
}

/// Luma threshold: every color channel becomes 0 or 255 depending on whether
/// the pixel's Rec. 709 luma (on normalized channels) is >= `level`. Requires
/// `level` in [0, 1]; alpha untouched.
pub(crate) fn threshold(img: &RgbaImage, level: f32) -> Option<RgbaImage> {
    if !(0.0..=1.0).contains(&level) {
        return None;
    }
    let mut out = img.clone();
    for px in out.pixels_mut() {
        let luma =
            (LUMA_R * f32::from(px[0]) + LUMA_G * f32::from(px[1]) + LUMA_B * f32::from(px[2]))
                / 255.0;
        let v = if luma >= level { 255 } else { 0 };
        px[0] = v;
        px[1] = v;
        px[2] = v;
    }
    Some(out)
}

/// Reduces each color channel to `levels` evenly spaced values:
/// `round(c * (n - 1)) / (n - 1)` in normalized space. Requires
/// `levels` in 2..=64; alpha untouched.
pub(crate) fn posterize(img: &RgbaImage, levels: u32) -> Option<RgbaImage> {
    if !(2..=64).contains(&levels) {
        return None;
    }
    let steps = (levels - 1) as f32;
    let mut out = img.clone();
    for px in out.pixels_mut() {
        for ch in px.0.iter_mut().take(3) {
            let t = (f32::from(*ch) / 255.0 * steps).round() / steps;
            *ch = (t * 255.0).round() as u8;
        }
    }
    Some(out)
}

/// Mosaic of `block` x `block` cells anchored at (0, 0); partial edge cells
/// use their actual extent. Each cell becomes its ALPHA-WEIGHTED mean color
/// (`sum c*a / sum a`; a cell whose alpha sums to zero becomes fully
/// transparent black) with the plain mean alpha. Requires `block` in
/// 1..=1024; `block == 1` is the identity (still a fresh image).
pub(crate) fn pixelate(img: &RgbaImage, block: u32) -> Option<RgbaImage> {
    if !(1..=1024).contains(&block) {
        return None;
    }
    let mut out = img.clone();
    if block == 1 {
        return Some(out);
    }
    let (w, h) = img.dimensions();
    for cy in (0..h).step_by(block as usize) {
        let cell_h = block.min(h - cy);
        for cx in (0..w).step_by(block as usize) {
            let cell_w = block.min(w - cx);
            // Integer accumulation is exact: c*a <= 65025 summed over at most
            // 1024*1024 pixels fits comfortably in u64.
            let mut sum_ca = [0u64; 3];
            let mut sum_a = 0u64;
            for y in cy..cy + cell_h {
                for x in cx..cx + cell_w {
                    let p = img.get_pixel(x, y);
                    let a = u64::from(p[3]);
                    sum_a += a;
                    for (s, ch) in sum_ca.iter_mut().zip(p.0) {
                        *s += u64::from(ch) * a;
                    }
                }
            }
            let mean = if sum_a == 0 {
                Rgba([0, 0, 0, 0])
            } else {
                let count = u64::from(cell_w) * u64::from(cell_h);
                let mut px = [0u8; 4];
                for (dst, s) in px.iter_mut().zip(sum_ca) {
                    *dst = (s as f64 / sum_a as f64).round() as u8;
                }
                px[3] = (sum_a as f64 / count as f64).round() as u8;
                Rgba(px)
            };
            for y in cy..cy + cell_h {
                for x in cx..cx + cell_w {
                    out.put_pixel(x, y, mean);
                }
            }
        }
    }
    Some(out)
}

/// SplitMix64 PRNG; a few lines, no dependency, deterministic per seed.
struct SplitMix64(u64);

impl SplitMix64 {
    fn next_u64(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    /// Uniform in [0, 1), built from the top 24 bits.
    fn next_unit_f32(&mut self) -> f32 {
        (self.next_u64() >> 40) as f32 / (1u64 << 24) as f32
    }
}

/// Additive uniform noise in [-amount, +amount] (normalized scale) per COLOR
/// channel, independent per channel, deterministic from `seed` (SplitMix64,
/// pixels visited in row-major order, channels r, g, b). Requires `amount`
/// in (0, 1]; alpha untouched.
pub(crate) fn noise(img: &RgbaImage, amount: f32, seed: u64) -> Option<RgbaImage> {
    if !(amount > 0.0 && amount <= 1.0) {
        return None;
    }
    let mut rng = SplitMix64(seed);
    let mut out = img.clone();
    for px in out.pixels_mut() {
        for ch in px.0.iter_mut().take(3) {
            let delta = (2.0 * rng.next_unit_f32() - 1.0) * amount;
            let v = f32::from(*ch) / 255.0 + delta;
            *ch = (v.clamp(0.0, 1.0) * 255.0).round() as u8;
        }
    }
    Some(out)
}

/// Normalized ([0, 1]) Rec. 709 luma plane with border-replicating sampling,
/// shared by the convolution filters.
struct LumaPlane {
    w: usize,
    h: usize,
    data: Vec<f32>,
}

impl LumaPlane {
    fn new(img: &RgbaImage) -> Self {
        let (w, h) = img.dimensions();
        let data = img
            .pixels()
            .map(|p| {
                (LUMA_R * f32::from(p[0]) + LUMA_G * f32::from(p[1]) + LUMA_B * f32::from(p[2]))
                    / 255.0
            })
            .collect();
        LumaPlane {
            w: w as usize,
            h: h as usize,
            data,
        }
    }

    /// Samples with replicated borders (coordinates clamp to the edges).
    fn at(&self, x: i64, y: i64) -> f32 {
        let x = x.clamp(0, self.w as i64 - 1) as usize;
        let y = y.clamp(0, self.h as i64 - 1) as usize;
        self.data[y * self.w + x]
    }

    /// 3x3 convolution centered on (x, y), borders replicated.
    fn convolve3(&self, x: u32, y: u32, kernel: &[[f32; 3]; 3]) -> f32 {
        let (cx, cy) = (i64::from(x), i64::from(y));
        let mut acc = 0.0;
        for (ky, row) in kernel.iter().enumerate() {
            for (kx, k) in row.iter().enumerate() {
                acc += k * self.at(cx + kx as i64 - 1, cy + ky as i64 - 1);
            }
        }
        acc
    }
}

const SOBEL_X: [[f32; 3]; 3] = [[-1.0, 0.0, 1.0], [-2.0, 0.0, 2.0], [-1.0, 0.0, 1.0]];
const SOBEL_Y: [[f32; 3]; 3] = [[-1.0, -2.0, -1.0], [0.0, 0.0, 0.0], [1.0, 2.0, 1.0]];
const EMBOSS: [[f32; 3]; 3] = [[-2.0, -1.0, 0.0], [-1.0, 1.0, 1.0], [0.0, 1.0, 2.0]];

/// Sobel edge magnitude on the Rec. 709 luma plane, `sqrt(gx^2 + gy^2)`
/// clamped to [0, 1], rendered as opaque grayscale (r = g = b, alpha 255).
pub(crate) fn edge_detect(img: &RgbaImage) -> RgbaImage {
    let (w, h) = img.dimensions();
    let luma = LumaPlane::new(img);
    let mut out = RgbaImage::new(w, h);
    for y in 0..h {
        for x in 0..w {
            let gx = luma.convolve3(x, y, &SOBEL_X);
            let gy = luma.convolve3(x, y, &SOBEL_Y);
            let mag = (gx * gx + gy * gy).sqrt().clamp(0.0, 1.0);
            let v = (mag * 255.0).round() as u8;
            out.put_pixel(x, y, Rgba([v, v, v, 255]));
        }
    }
    out
}

/// Emboss: the 3x3 relief kernel `[[-2,-1,0],[-1,1,1],[0,1,2]]` applied to
/// the Rec. 709 luma plane plus a 0.5 bias, clamped to [0, 1], rendered as
/// opaque grayscale (r = g = b, alpha 255). Borders replicate.
pub(crate) fn emboss(img: &RgbaImage) -> RgbaImage {
    let (w, h) = img.dimensions();
    let luma = LumaPlane::new(img);
    let mut out = RgbaImage::new(w, h);
    for y in 0..h {
        for x in 0..w {
            let v = ((luma.convolve3(x, y, &EMBOSS) + 0.5).clamp(0.0, 1.0) * 255.0).round() as u8;
            out.put_pixel(x, y, Rgba([v, v, v, 255]));
        }
    }
    out
}
