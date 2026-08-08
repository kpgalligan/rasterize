//! rasterize-core: the image-processing core behind the C FFI declared in
//! `include/rasterize_core.h`.
//!
//! The safe internal API lives here and in [`ops`]; all unsafe code is
//! confined to [`ffi`].

pub mod ffi;
mod ops;

use std::fs::File;
use std::io::{BufWriter, Write};

use image::codecs::bmp::BmpEncoder;
use image::codecs::gif::GifEncoder;
use image::codecs::jpeg::JpegEncoder;
use image::codecs::png::PngEncoder;
use image::codecs::tiff::TiffEncoder;
use image::codecs::webp::WebPEncoder;
use image::{ExtendedColorType, ImageDecoder, ImageEncoder, RgbaImage};

/// Opaque image handle exposed through the FFI. Holds a non-premultiplied
/// RGBA8 buffer (row-major, no row padding).
pub struct RzImage {
    pub(crate) pixels: RgbaImage,
}

/// Output format, mirroring `RzFormat` in the C header.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Format {
    Png,
    Jpeg,
    Tiff,
    Bmp,
    Gif,
    Webp,
}

impl Format {
    /// Maps a raw `RzFormat` value coming across the FFI.
    pub(crate) fn from_c(value: i32) -> Option<Self> {
        match value {
            0 => Some(Format::Png),
            1 => Some(Format::Jpeg),
            2 => Some(Format::Tiff),
            3 => Some(Format::Bmp),
            4 => Some(Format::Gif),
            5 => Some(Format::Webp),
            _ => None,
        }
    }
}

impl RzImage {
    /// Reads and decodes the file at `path`. Files starting with the `8BPS`
    /// magic are decoded as Photoshop documents and flattened to their
    /// composite image; everything else goes through content sniffing in the
    /// `image` crate.
    pub(crate) fn open(path: &str) -> Result<Self, String> {
        let bytes = std::fs::read(path).map_err(|e| format!("failed to read {path}: {e}"))?;
        let pixels = if bytes.len() >= 4 && &bytes[..4] == b"8BPS" {
            let psd = psd::Psd::from_bytes(&bytes)
                .map_err(|e| format!("failed to decode PSD {path}: {e}"))?;
            // The psd crate silently mis-decodes anything but 8-bit RGB or
            // grayscale (CMYK channels land in RGB slots, 16-bit data is read
            // byte-interleaved), so reject those up front.
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
            RgbaImage::from_raw(psd.width(), psd.height(), psd.rgba())
                .ok_or_else(|| format!("PSD {path}: composite buffer size mismatch"))?
        } else {
            let decode_err = |e: image::ImageError| format!("failed to decode {path}: {e}");
            let mut decoder = image::ImageReader::new(std::io::Cursor::new(&bytes))
                .with_guessed_format()
                .map_err(|e| format!("failed to read {path}: {e}"))?
                .into_decoder()
                .map_err(decode_err)?;
            // Normalize camera-tagged rotation (EXIF) into the pixels at open
            // time; the save path never writes orientation metadata.
            let orientation = decoder
                .orientation()
                .unwrap_or(image::metadata::Orientation::NoTransforms);
            let mut img = image::DynamicImage::from_decoder(decoder).map_err(decode_err)?;
            img.apply_orientation(orientation);
            img.to_rgba8()
        };
        Ok(RzImage { pixels })
    }

    /// Encodes the image to `path` in `format`. The encode goes to a
    /// temporary file in the same directory which is renamed over `path` only
    /// on success, so a failed save never truncates or deletes an existing
    /// destination file.
    pub(crate) fn save(&self, path: &str, format: Format, jpeg_quality: u8) -> Result<(), String> {
        static SAVE_SEQ: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let seq = SAVE_SEQ.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let tmp_path = format!("{path}.rz-tmp-{}-{seq}", std::process::id());
        let file = File::create(&tmp_path).map_err(|e| format!("failed to create {path}: {e}"))?;
        let mut writer = BufWriter::new(file);
        let result = self
            .encode_into(&mut writer, format, jpeg_quality)
            .and_then(|()| {
                writer
                    .flush()
                    .map_err(|e| format!("failed to write {path}: {e}"))
            });
        drop(writer);
        let result = result.and_then(|()| {
            std::fs::rename(&tmp_path, path).map_err(|e| format!("failed to write {path}: {e}"))
        });
        if result.is_err() {
            let _ = std::fs::remove_file(&tmp_path);
        }
        result
    }

    fn encode_into(
        &self,
        writer: &mut BufWriter<File>,
        format: Format,
        jpeg_quality: u8,
    ) -> Result<(), String> {
        let (w, h) = self.pixels.dimensions();
        let raw = self.pixels.as_raw();
        let err = |e: image::ImageError| format!("encoding failed: {e}");
        match format {
            Format::Png => PngEncoder::new(writer)
                .write_image(raw, w, h, ExtendedColorType::Rgba8)
                .map_err(err),
            Format::Jpeg => {
                let rgb = composite_over_white(&self.pixels);
                JpegEncoder::new_with_quality(writer, jpeg_quality.clamp(1, 100))
                    .write_image(rgb.as_raw(), w, h, ExtendedColorType::Rgb8)
                    .map_err(err)
            }
            Format::Tiff => TiffEncoder::new(writer)
                .write_image(raw, w, h, ExtendedColorType::Rgba8)
                .map_err(err),
            Format::Bmp => BmpEncoder::new(writer)
                .write_image(raw, w, h, ExtendedColorType::Rgba8)
                .map_err(err),
            Format::Gif => {
                let mut encoder = GifEncoder::new_with_speed(writer, 10);
                encoder
                    .encode(raw, w, h, ExtendedColorType::Rgba8)
                    .map_err(err)
            }
            Format::Webp => WebPEncoder::new_lossless(writer)
                .write_image(raw, w, h, ExtendedColorType::Rgba8)
                .map_err(err),
        }
    }
}

/// Alpha-composites the image over an opaque white background, producing RGB8
/// (used for JPEG output, which has no alpha channel).
fn composite_over_white(img: &RgbaImage) -> image::RgbImage {
    let (w, h) = img.dimensions();
    let mut out = image::RgbImage::new(w, h);
    for (src, dst) in img.pixels().zip(out.pixels_mut()) {
        let alpha = f32::from(src[3]) / 255.0;
        for (d, &s) in dst.0.iter_mut().zip(src.0.iter()) {
            *d = (f32::from(s) * alpha + 255.0 * (1.0 - alpha)).round() as u8;
        }
    }
    out
}
