//! Pure image operations on RGBA8 buffers. Every function returns a new
//! buffer and never mutates its input. No unsafe code here.

use image::imageops::{self, FilterType};
use image::RgbaImage;

use crate::blend::{paint_pixel, LUMA_B, LUMA_G, LUMA_R};
use crate::doc::MAX_PIXELS;

pub(crate) fn rotate90(img: &RgbaImage) -> RgbaImage {
    imageops::rotate90(img)
}

pub(crate) fn rotate180(img: &RgbaImage) -> RgbaImage {
    imageops::rotate180(img)
}

pub(crate) fn rotate270(img: &RgbaImage) -> RgbaImage {
    imageops::rotate270(img)
}

pub(crate) fn flip_horizontal(img: &RgbaImage) -> RgbaImage {
    imageops::flip_horizontal(img)
}

pub(crate) fn flip_vertical(img: &RgbaImage) -> RgbaImage {
    imageops::flip_vertical(img)
}

/// Returns `None` if the rect is empty or not fully inside the image
/// (including on u32 overflow of `x + w` / `y + h`).
pub(crate) fn crop(img: &RgbaImage, x: u32, y: u32, w: u32, h: u32) -> Option<RgbaImage> {
    if w == 0 || h == 0 {
        return None;
    }
    let (iw, ih) = img.dimensions();
    let x_end = x.checked_add(w)?;
    let y_end = y.checked_add(h)?;
    if x_end > iw || y_end > ih {
        return None;
    }
    Some(imageops::crop_imm(img, x, y, w, h).to_image())
}

/// Returns `None` if either dimension is zero or the target exceeds
/// [`MAX_PIXELS`].
pub(crate) fn resize(img: &RgbaImage, w: u32, h: u32, filter: FilterType) -> Option<RgbaImage> {
    if w == 0 || h == 0 || u64::from(w) * u64::from(h) > MAX_PIXELS {
        return None;
    }
    Some(imageops::resize(img, w, h, filter))
}

/// Applies brightness, then contrast, then saturation, per pixel in
/// normalized [0, 1] space. Each control is clamped to [-1, 1]; 0 is the
/// identity. Alpha is untouched.
pub(crate) fn adjust(
    img: &RgbaImage,
    brightness: f32,
    contrast: f32,
    saturation: f32,
) -> RgbaImage {
    let brightness = brightness.clamp(-1.0, 1.0);
    let contrast_slope = (1.0 + contrast.clamp(-1.0, 1.0)).max(0.0);
    let saturation_scale = (1.0 + saturation.clamp(-1.0, 1.0)).max(0.0);
    let mut out = img.clone();
    for px in out.pixels_mut() {
        let mut ch = [
            f32::from(px[0]) / 255.0,
            f32::from(px[1]) / 255.0,
            f32::from(px[2]) / 255.0,
        ];
        for v in &mut ch {
            *v += brightness;
            *v = (*v - 0.5) * contrast_slope + 0.5;
        }
        let luma = LUMA_R * ch[0] + LUMA_G * ch[1] + LUMA_B * ch[2];
        for v in &mut ch {
            *v = luma + (*v - luma) * saturation_scale;
        }
        for (dst, v) in px.0.iter_mut().zip(ch) {
            *dst = (v.clamp(0.0, 1.0) * 255.0).round() as u8;
        }
    }
    out
}

pub(crate) fn grayscale(img: &RgbaImage) -> RgbaImage {
    let mut out = img.clone();
    for px in out.pixels_mut() {
        let luma =
            (LUMA_R * f32::from(px[0]) + LUMA_G * f32::from(px[1]) + LUMA_B * f32::from(px[2]))
                .clamp(0.0, 255.0)
                .round() as u8;
        px[0] = luma;
        px[1] = luma;
        px[2] = luma;
    }
    out
}

pub(crate) fn invert(img: &RgbaImage) -> RgbaImage {
    let mut out = img.clone();
    for px in out.pixels_mut() {
        for c in px.0.iter_mut().take(3) {
            *c = 255 - *c;
        }
    }
    out
}

pub(crate) fn sepia(img: &RgbaImage) -> RgbaImage {
    let mut out = img.clone();
    for px in out.pixels_mut() {
        let r = f32::from(px[0]);
        let g = f32::from(px[1]);
        let b = f32::from(px[2]);
        px[0] = (0.393 * r + 0.769 * g + 0.189 * b).min(255.0).round() as u8;
        px[1] = (0.349 * r + 0.686 * g + 0.168 * b).min(255.0).round() as u8;
        px[2] = (0.272 * r + 0.534 * g + 0.131 * b).min(255.0).round() as u8;
    }
    out
}

/// Composite mode, mirroring `RzCompositeMode` in the C header.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum CompositeMode {
    Over,
    Erase,
}

impl CompositeMode {
    /// Maps a raw `RzCompositeMode` value coming across the FFI.
    pub(crate) fn from_c(value: i32) -> Option<Self> {
        match value {
            0 => Some(CompositeMode::Over),
            1 => Some(CompositeMode::Erase),
            _ => None,
        }
    }
}

/// Composites a full-frame PREMULTIPLIED RGBA8 overlay (`src`, row-major, no
/// row padding) onto the non-premultiplied `dst`, returning a new
/// non-premultiplied image. `alpha` is clamped to [0, 1] and scales the
/// overlay's alpha first. [`CompositeMode::Over`] paints the overlay over the
/// destination; [`CompositeMode::Erase`] uses the overlay's alpha to erase
/// destination alpha and ignores the overlay's color. Where the overlay is
/// fully transparent the destination bytes pass through exactly.
///
/// Returns `None` if `alpha` is NaN or `src` is not exactly
/// `width * height * 4` bytes.
pub(crate) fn composite(
    dst: &RgbaImage,
    src: &[u8],
    mode: CompositeMode,
    alpha: f32,
) -> Option<RgbaImage> {
    if alpha.is_nan() {
        return None;
    }
    let (w, h) = dst.dimensions();
    let expected = (w as usize).checked_mul(h as usize)?.checked_mul(4)?;
    if src.len() != expected {
        return None;
    }
    let a = alpha.clamp(0.0, 1.0);
    let mut out = dst.clone();
    // Same-size frames, so this is exactly the shared per-pixel kernel run
    // over the zipped buffers (the offset-mapped variant is
    // `RzDocument::painting_layer`).
    for (op, sp) in out.pixels_mut().zip(src.chunks_exact(4)) {
        paint_pixel(&mut op.0, [sp[0], sp[1], sp[2], sp[3]], mode, a);
    }
    Some(out)
}

/// Multiplies each pixel's alpha by a full-frame u8 coverage mask (`mask`,
/// row-major, one byte per pixel — the selection convention: 0 hides, 255
/// keeps, intermediate values scale proportionally, so an anti-aliased or
/// feathered edge fades out across the fringe). The keep-side twin of
/// `RzDocument::clear_selection`, and the same integer rounding: only ALPHA
/// scales (pixels are straight alpha, so scaling color would darken the
/// surviving fringe); where the scaled alpha lands on 0 the color drops too.
/// Full-coverage (255) pixels pass through byte-for-byte — an all-255 mask
/// returns an identical copy, like a full-image `crop` — so an already
/// transparent pixel keeps its latent color there, and only there.
///
/// Returns `None` if `mask` is not exactly `width * height` bytes.
pub(crate) fn apply_mask(img: &RgbaImage, mask: &[u8]) -> Option<RgbaImage> {
    let (w, h) = img.dimensions();
    let expected = (w as usize).checked_mul(h as usize)?;
    if mask.len() != expected {
        return None;
    }
    let mut out = img.clone();
    for (px, cov) in out.pixels_mut().zip(mask.iter()) {
        if *cov == 255 {
            continue;
        }
        // round(alpha * coverage / 255) in integers; the +127 is the half
        // step, and no product of two u8s can land exactly on a .5 tie
        // (255 is odd).
        let kept = u32::from(px.0[3]) * u32::from(*cov);
        let alpha = ((kept + 127) / 255) as u8;
        if alpha == 0 {
            // Fully hidden: remove all color too.
            px.0 = [0, 0, 0, 0];
        } else {
            px.0[3] = alpha;
        }
    }
    Some(out)
}

/// Gaussian blur. Returns `None` if `sigma` is not finite or not positive.
pub(crate) fn blur(img: &RgbaImage, sigma: f32) -> Option<RgbaImage> {
    if !sigma.is_finite() || sigma <= 0.0 {
        return None;
    }
    Some(imageops::blur(img, sigma))
}

/// Unsharp-mask sharpen with `amount` clamped to (0, 5] and threshold 0.
/// Returns `None` if `amount` is not finite or not positive.
pub(crate) fn sharpen(img: &RgbaImage, amount: f32) -> Option<RgbaImage> {
    if !amount.is_finite() || amount <= 0.0 {
        return None;
    }
    Some(imageops::unsharpen(img, amount.min(5.0), 0))
}
