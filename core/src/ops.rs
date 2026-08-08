//! Pure image operations on RGBA8 buffers. Every function returns a new
//! buffer and never mutates its input. No unsafe code here.

use image::imageops::{self, FilterType};
use image::RgbaImage;

/// Rec. 709 luma coefficients, used for grayscale and saturation.
const LUMA_R: f32 = 0.2126;
const LUMA_G: f32 = 0.7152;
const LUMA_B: f32 = 0.0722;

/// Largest permitted resize target, in total pixels.
const MAX_RESIZE_PIXELS: u64 = 100_000_000;

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
/// [`MAX_RESIZE_PIXELS`].
pub(crate) fn resize(img: &RgbaImage, w: u32, h: u32, filter: FilterType) -> Option<RgbaImage> {
    if w == 0 || h == 0 || u64::from(w) * u64::from(h) > MAX_RESIZE_PIXELS {
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
    for (op, sp) in out.pixels_mut().zip(src.chunks_exact(4)) {
        // Fast path: a fully transparent overlay pixel passes the destination
        // bytes through exactly (no float round-trip). For OVER the color
        // bytes must also be zero — they always are in well-formed
        // premultiplied data; malformed pixels fall through to the math.
        let src_transparent = sp[3] == 0
            && match mode {
                CompositeMode::Over => sp[0] == 0 && sp[1] == 0 && sp[2] == 0,
                CompositeMode::Erase => true,
            };
        if src_transparent {
            continue;
        }
        let sa = (f32::from(sp[3]) / 255.0) * a;
        let da = f32::from(op[3]) / 255.0;
        match mode {
            CompositeMode::Over => {
                let out_a = sa + da * (1.0 - sa);
                if out_a < 1e-6 {
                    // Keep the destination color bytes so fully transparent
                    // regions do not invent color fringes.
                    op[3] = 0;
                } else {
                    for c in 0..3 {
                        let scp = (f32::from(sp[c]) / 255.0) * a;
                        let dc = f32::from(op[c]) / 255.0;
                        let v = (scp + dc * da * (1.0 - sa)) / out_a;
                        op[c] = (v.clamp(0.0, 1.0) * 255.0).round() as u8;
                    }
                    op[3] = (out_a.clamp(0.0, 1.0) * 255.0).round() as u8;
                }
            }
            CompositeMode::Erase => {
                let out_a = da * (1.0 - sa);
                op[3] = (out_a.clamp(0.0, 1.0) * 255.0).round() as u8;
            }
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
