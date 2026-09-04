//! The flat image handle behind the `rz_image_*` FFI: [`RzImage`], the
//! `RzFormat` mapping, file open (container sniffing, EXIF normalization,
//! the [`Sidecar`] a document lifts), atomic save, and the per-format
//! encoders. (Named `rz_image`, not `image`, to avoid ambiguity with the
//! `image` crate.)

use std::fs::File;
use std::io::{BufWriter, Seek, Write};

use image::codecs::bmp::BmpEncoder;
use image::codecs::gif::GifEncoder;
use image::codecs::jpeg::{JpegEncoder, PixelDensity, PixelDensityUnit};
use image::codecs::png::PngEncoder;
use image::codecs::tiff::TiffEncoder;
use image::codecs::webp::WebPEncoder;
use image::{ExtendedColorType, ImageDecoder, ImageEncoder, RgbaImage};

use crate::doc::MAX_PIXELS;
use crate::metadata::{self, Metadata, Resolution};
use crate::metadata_write::{EncodeSidecar, MetadataInjector};

/// Opaque image handle exposed through the FFI. Holds a non-premultiplied
/// RGBA8 buffer (row-major, no row padding).
pub struct RzImage {
    pub(crate) pixels: RgbaImage,
}

/// Everything a decode found BESIDE the pixels: the embedded ICC profile,
/// the metadata packets and the print resolution. `RzDocument::open` lifts
/// it onto the document; `rz_image_open` discards it, because a bare image
/// handle has nowhere to put it and ~40 pure ops would have to state a
/// per-field carry policy on a type with no place to state one.
///
/// The resolution describes the pixels AS RETURNED — upright, with any
/// camera rotation already baked in — so it is transposed for the four
/// quarter-turn orientations rather than echoing the file's stored pair.
#[derive(Default)]
pub(crate) struct Sidecar {
    pub icc: Option<Vec<u8>>,
    pub metadata: Metadata,
    pub resolution: Option<Resolution>,
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
    /// Wraps a caller-supplied STRAIGHT (non-premultiplied) RGBA8 buffer —
    /// row-major, row 0 = top, exactly `w * h * 4` bytes — as an image: the
    /// in-memory twin of [`RzImage::open`], for pixels this crate cannot
    /// decode itself (a macOS HEIC still, a Live Photo video frame). None for
    /// a zero dimension, a size past [`MAX_PIXELS`], or a buffer whose length
    /// disagrees with the dimensions.
    pub(crate) fn from_rgba(w: u32, h: u32, data: Vec<u8>) -> Option<Self> {
        if w == 0 || h == 0 || u64::from(w) * u64::from(h) > MAX_PIXELS {
            return None;
        }
        RgbaImage::from_raw(w, h, data).map(|pixels| RzImage { pixels })
    }

    /// Reads and decodes the file at `path`, discarding its [`Sidecar`].
    /// The thin wrapper over [`RzImage::open_bytes`], which is the ONE
    /// decoder.
    pub(crate) fn open(path: &str) -> Result<Self, String> {
        let bytes = std::fs::read(path).map_err(|e| format!("failed to read {path}: {e}"))?;
        Ok(RzImage::open_bytes(&bytes, path)?.0)
    }

    /// Decodes `bytes` (already read from `path`, which is used only in
    /// error messages) and returns the image plus everything else the file
    /// carried. Buffers starting with the `8BPS` magic are decoded as
    /// Photoshop documents and flattened to their composite image;
    /// everything else goes through content sniffing in the `image` crate.
    ///
    /// The PSD branch contributes an EMPTY sidecar: `psd` 0.3.5 exposes only
    /// the Slices image resource, so the resolution (id 1005) and the ICC
    /// profile (id 1039) are unreachable, exactly as PSD alpha channels and
    /// layer masks are.
    pub(crate) fn open_bytes(bytes: &[u8], path: &str) -> Result<(Self, Sidecar), String> {
        if bytes.len() >= 4 && &bytes[..4] == b"8BPS" {
            let psd = psd::Psd::from_bytes(bytes)
                .map_err(|e| format!("failed to decode PSD {path}: {e}"))?;
            crate::psd::check_supported(&psd, path)?;
            let pixels = RgbaImage::from_raw(psd.width(), psd.height(), psd.rgba())
                .ok_or_else(|| format!("PSD {path}: composite buffer size mismatch"))?;
            return Ok((RzImage { pixels }, Sidecar::default()));
        }
        let decode_err = |e: image::ImageError| format!("failed to decode {path}: {e}");
        let mut decoder = image::ImageReader::new(std::io::Cursor::new(bytes))
            .with_guessed_format()
            .map_err(|e| format!("failed to read {path}: {e}"))?
            .into_decoder()
            .map_err(decode_err)?;
        // Normalize camera-tagged rotation (EXIF) into the pixels at open
        // time. A preserved EXIF packet therefore CANNOT be written back
        // unchanged — `metadata_write::exif_normalized` resets its
        // Orientation to 1 on every save, which is what keeps this safe.
        let orientation = decoder
            .orientation()
            .unwrap_or(image::metadata::Orientation::NoTransforms);
        // The last question the live decoder answers: it is consumed on the
        // next line. `.ok().flatten()`, never `?` — a corrupt profile is
        // absence, not a failure to open the file.
        let icc = decoder.icc_profile().ok().flatten();
        let mut img = image::DynamicImage::from_decoder(decoder).map_err(decode_err)?;
        img.apply_orientation(orientation);
        let scan = metadata::scan(bytes);
        // The file states its resolution for the picture as STORED; the
        // pixels above are the picture as DISPLAYED, so a quarter turn
        // swaps the two axes — a 300 x 150 ppi frame stored sideways is
        // 150 x 300 once it is upright. This is the same rule
        // `RzDocument::geometry` applies to `rotate90`, through the same
        // `Resolution::transposed_if`; the two would otherwise disagree
        // about one operation.
        let resolution = scan
            .resolution
            .map(|r| r.transposed_if(quarter_turned(orientation)));
        Ok((
            RzImage {
                pixels: img.to_rgba8(),
            },
            Sidecar {
                icc,
                metadata: scan.metadata,
                resolution,
            },
        ))
    }

    /// Encodes the image to `path` in `format`, atomically via
    /// [`save_atomically`], so a failed save never truncates or deletes an
    /// existing destination file. Attaches nothing: a bare image has no
    /// profile and no packets, so this produces exactly the bytes it always
    /// did. The document-level twin is `RzDocument::save_image`.
    pub(crate) fn save(&self, path: &str, format: Format, jpeg_quality: u8) -> Result<(), String> {
        save_flat(
            &self.pixels,
            path,
            format,
            jpeg_quality,
            &EncodeSidecar::NONE,
        )
    }
}

/// True for the four EXIF orientations (5-8) that turn the picture a
/// quarter of a turn, so the stored width becomes the displayed height.
fn quarter_turned(orientation: image::metadata::Orientation) -> bool {
    use image::metadata::Orientation::*;
    matches!(
        orientation,
        Rotate90 | Rotate270 | Rotate90FlipH | Rotate270FlipH
    )
}

/// Encodes `pixels` to `path`, splicing in whatever `side` carries. The ONE
/// flat writer: [`RzImage::save`] passes [`EncodeSidecar::NONE`] and
/// `RzDocument::save_image` passes the document's profile, packets and
/// resolution.
///
/// The splice lives INSIDE the [`save_atomically`] closure, so atomicity is
/// preserved and there is no second helper; and there is exactly one
/// `match format` in the crate that dispatches an encoder.
pub(crate) fn save_flat(
    pixels: &RgbaImage,
    path: &str,
    format: Format,
    jpeg_quality: u8,
    side: &EncodeSidecar<'_>,
) -> Result<(), String> {
    save_atomically(path, |tmp_path| {
        let file = File::create(tmp_path).map_err(|e| format!("failed to create {path}: {e}"))?;
        let writer = BufWriter::new(file);
        // Only JPEG and PNG are ever spliced, and only when there is
        // something to splice: with nothing extra to write the injector is a
        // pass-through, which is also the ONLY mode a seeking encoder (TIFF)
        // may be given.
        let extra = match format {
            Format::Jpeg => side.jpeg_segments(),
            Format::Png => side.png_chunks(),
            _ => Vec::new(),
        };
        let mut injector = match format {
            _ if extra.is_empty() => MetadataInjector::passthrough(writer),
            Format::Jpeg => MetadataInjector::jpeg(writer, extra),
            Format::Png => MetadataInjector::png(writer, extra),
            _ => MetadataInjector::passthrough(writer),
        };
        encode_into(pixels, &mut injector, format, jpeg_quality, side)?;
        let mut writer = injector.finish()?;
        writer
            .flush()
            .map_err(|e| format!("failed to write {path}: {e}"))
    })
}

/// The per-format encoders — the ONE dispatch.
///
/// `W: Write + Seek` rather than `Write` because `TiffEncoder` is
/// `impl<W: Write + Seek>` (the `tiff` crate seeks to backpatch IFD
/// offsets), while PNG, JPEG, BMP, GIF and WebP need only `Write`.
/// `BufWriter<File>` satisfies both, and `MetadataInjector`'s `Seek` impl
/// refuses a seek on a spliced stream rather than corrupting the file.
fn encode_into<W: Write + Seek>(
    pixels: &RgbaImage,
    writer: &mut W,
    format: Format,
    jpeg_quality: u8,
    side: &EncodeSidecar<'_>,
) -> Result<(), String> {
    let (w, h) = pixels.dimensions();
    let raw = pixels.as_raw();
    let err = |e: image::ImageError| format!("encoding failed: {e}");
    let unsupported = |e: image::error::UnsupportedError| format!("encoding failed: {e}");
    match format {
        Format::Png => {
            let mut enc = PngEncoder::new(writer);
            if let Some(icc) = side.icc {
                enc.set_icc_profile(icc.to_vec()).map_err(unsupported)?;
            }
            if let Some(exif) = &side.exif {
                enc.set_exif_metadata(exif.clone()).map_err(unsupported)?;
            }
            enc.write_image(raw, w, h, ExtendedColorType::Rgba8)
                .map_err(err)
        }
        Format::Jpeg => {
            // Alpha is flattened over white BEFORE encoding, on the
            // document's own pixels, and the profile is embedded unchanged:
            // white is white in every RGB space this crate supports, so no
            // conversion belongs around this and adding one would be wrong.
            let rgb = composite_over_white(pixels);
            let mut enc = JpegEncoder::new_with_quality(writer, jpeg_quality.clamp(1, 100));
            if let Some(icc) = side.icc {
                enc.set_icc_profile(icc.to_vec()).map_err(unsupported)?;
            }
            if let Some(exif) = &side.exif {
                enc.set_exif_metadata(exif.clone()).map_err(unsupported)?;
            }
            if let Some(dpi) = side.dpi {
                // Per axis: `PixelDensity::dpi` takes ONE u16 and could not
                // express a 300 x 150 ppi document.
                enc.set_pixel_density(PixelDensity {
                    density: (clamp_jfif_density(dpi.x), clamp_jfif_density(dpi.y)),
                    unit: PixelDensityUnit::Inches,
                });
            }
            enc.write_image(rgb.as_raw(), w, h, ExtendedColorType::Rgb8)
                .map_err(err)
        }
        Format::Tiff => {
            let mut enc = TiffEncoder::new(writer);
            if let Some(icc) = side.icc {
                enc.set_icc_profile(icc.to_vec()).map_err(unsupported)?;
            }
            enc.write_image(raw, w, h, ExtendedColorType::Rgba8)
                .map_err(err)
        }
        Format::Bmp => BmpEncoder::new(writer)
            .write_image(raw, w, h, ExtendedColorType::Rgba8)
            .map_err(err),
        Format::Gif => {
            let mut encoder = GifEncoder::new_with_speed(writer, 10);
            encoder
                .encode(raw, w, h, ExtendedColorType::Rgba8)
                .map_err(err)
        }
        Format::Webp => {
            let mut enc = WebPEncoder::new_lossless(writer);
            if let Some(icc) = side.icc {
                enc.set_icc_profile(icc.to_vec()).map_err(unsupported)?;
            }
            if let Some(exif) = &side.exif {
                enc.set_exif_metadata(exif.clone()).map_err(unsupported)?;
            }
            enc.write_image(raw, w, h, ExtendedColorType::Rgba8)
                .map_err(err)
        }
    }
}

/// The JFIF density field is a u16 per axis. The document's own resolution
/// is already sanitized to [1, 30000], so this rounds and bounds rather than
/// corrects.
fn clamp_jfif_density(ppi: f32) -> u16 {
    f64::from(ppi).round().clamp(1.0, f64::from(u16::MAX)) as u16
}

/// Writes a file atomically — the ONE helper behind every save path
/// (`save_flat` here, `RzDocument::save_native` in `rzdc`). `write`
/// produces the content at a temporary path in the same directory (pid plus
/// a process-wide sequence number keep concurrent saves distinct), which is
/// renamed over `path` only on success, so a failed save never truncates or
/// deletes an existing destination file; the temporary file is removed on
/// failure.
pub(crate) fn save_atomically(
    path: &str,
    write: impl FnOnce(&str) -> Result<(), String>,
) -> Result<(), String> {
    static SAVE_SEQ: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let seq = SAVE_SEQ.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let tmp_path = format!("{path}.rz-tmp-{}-{seq}", std::process::id());
    let result = write(&tmp_path).and_then(|()| {
        std::fs::rename(&tmp_path, path).map_err(|e| format!("failed to write {path}: {e}"))
    });
    if result.is_err() {
        let _ = std::fs::remove_file(&tmp_path);
    }
    result
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
