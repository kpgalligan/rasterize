//! The RZDC native document format: encoder, atomic writer and
//! bounds-checked reader, plus the hard caps both sides enforce. The doc
//! comment on [`RzDocument::encode_native`] IS the format spec.

use std::sync::Arc;

use image::codecs::png::PngEncoder;
use image::{ExtendedColorType, GrayImage, ImageEncoder};

use crate::blend::BlendMode;
use crate::doc::{sane_opacity, Layer, RzDocument, MAX_PIXELS};
use crate::rz_image::save_atomically;

/// Hard caps applied while reading RZDC files so corrupt headers cannot ask
/// for absurd allocations. The meta cap is also what the FFI meta setter
/// enforces, so a document can never carry meta the writer would refuse.
const MAX_RZDC_LAYERS: u32 = 1024;
const MAX_RZDC_NAME_LEN: u32 = 64 * 1024;
const MAX_RZDC_PNG_LEN: u32 = 512 * 1024 * 1024;
pub(crate) const MAX_RZDC_META_LEN: u32 = 16 * 1024 * 1024;

/// The RZDC revision this build writes. Version 1 files (no mask, no layer
/// meta) and version 2 files (no clipped flag) still load; anything newer is
/// refused.
const RZDC_VERSION: u32 = 3;

/// Ceiling on the SUM of decoded layer pixels across one RZDC file: even when
/// every individual layer looks reasonable, a crafted file must not be able
/// to stack layers until memory is exhausted.
const MAX_RZDC_TOTAL_LAYER_PIXELS: u64 = 4 * MAX_PIXELS;

impl RzDocument {
    /// Serializes to the RZDC layout (see the header comment): "RZDC",
    /// u32 version, u32 width, u32 height, u32 layer count; per layer
    /// bottom-to-top: u32 name len + UTF-8 name, i32 off x, i32 off y,
    /// f32 opacity, u32 blend, u8 visible, u32 PNG len + PNG pixels.
    /// All integers little-endian.
    ///
    /// Version 2 appends three fields to each layer record, after the pixel
    /// PNG (so a version-1 record is a strict prefix of a version-2 one):
    /// u8 mask present, u8 mask enabled, u32 mask len + that many RAW
    /// coverage bytes when present (the mask's dimensions are the layer's
    /// pixel dimensions and are not stored twice), then u8 meta present and,
    /// when present, u32 meta len + UTF-8 meta bytes.
    ///
    /// Version 3 appends one more field after all the version-2 fields (so a
    /// version-2 record is in turn a strict prefix of a version-3 one):
    /// u8 clipped.
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
        buf.extend_from_slice(&RZDC_VERSION.to_le_bytes());
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
            // Version 2 fields. The mask is stored raw: its length is always
            // the layer's pixel count, which the reader re-derives and checks
            // — so a mask that somehow broke that invariant is written as
            // absent rather than as a file that cannot be read back.
            let mask = layer.mask.as_deref().filter(|m| m.dimensions() == (lw, lh));
            buf.push(u8::from(mask.is_some()));
            buf.push(u8::from(layer.mask_enabled));
            if let Some(mask) = mask {
                let bytes = mask.as_raw();
                let mask_len =
                    u32::try_from(bytes.len()).map_err(|_| "layer mask too large".to_string())?;
                buf.extend_from_slice(&mask_len.to_le_bytes());
                buf.extend_from_slice(bytes);
            }
            buf.push(u8::from(layer.meta.is_some()));
            if let Some(meta) = layer.meta.as_deref() {
                let meta_len = u32::try_from(meta.len())
                    .ok()
                    .filter(|&len| len <= MAX_RZDC_META_LEN)
                    .ok_or_else(|| format!("layer meta too large (max {MAX_RZDC_META_LEN})"))?;
                buf.extend_from_slice(&meta_len.to_le_bytes());
                buf.extend_from_slice(meta.as_bytes());
            }
            // Version 3 field.
            buf.push(u8::from(layer.clipped));
        }
        Ok(buf)
    }

    /// Writes the native RZDC format. Atomic exactly like `RzImage::save`
    /// (the shared [`save_atomically`] helper): the bytes go to a temporary
    /// file in the same directory which is renamed over `path` only on
    /// success, so a failed save never truncates or deletes an existing
    /// destination file.
    pub fn save_native(&self, path: &str) -> Result<(), String> {
        let bytes = self.encode_native()?;
        save_atomically(path, |tmp_path| {
            std::fs::write(tmp_path, &bytes).map_err(|e| format!("failed to create {path}: {e}"))
        })
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

/// Parses an RZDC buffer of version 1, 2 or 3 (version 1 predates layer
/// masks and layer meta, which default to absent; versions 1 and 2 predate
/// the clipped flag, which defaults to false). Corrupt or truncated input
/// produces `Err`, never a panic; unknown blend-mode values fall back to
/// Normal and opacity is clamped.
pub(crate) fn parse_native(bytes: &[u8]) -> Result<RzDocument, String> {
    let mut r = Reader { bytes, pos: 0 };
    if r.take(4)? != b"RZDC" {
        return Err("not an RZDC document".to_string());
    }
    let version = r.u32()?;
    if version == 0 || version > RZDC_VERSION {
        return Err(format!("unsupported RZDC version {version}"));
    }
    // Version 1 layer records stop after the pixel PNG; version 2 records
    // after the mask and meta fields.
    let has_mask_and_meta = version >= 2;
    let has_clipped = version >= 3;
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
        let mut mask = None;
        let mut mask_enabled = true;
        let mut meta = None;
        if has_mask_and_meta {
            let present = r.u8()? != 0;
            mask_enabled = r.u8()? != 0;
            if present {
                let mask_len = r.u32()?;
                let expected = u64::from(lw) * u64::from(lh);
                if u64::from(mask_len) != expected {
                    return Err(format!(
                        "layer mask length {mask_len} does not match the layer's {expected} pixels"
                    ));
                }
                let raw = r.take(mask_len as usize)?.to_vec();
                mask = Some(Arc::new(
                    GrayImage::from_raw(lw, lh, raw)
                        .ok_or_else(|| "invalid layer mask".to_string())?,
                ));
            }
            if r.u8()? != 0 {
                let meta_len = r.u32()?;
                if meta_len > MAX_RZDC_META_LEN {
                    return Err(format!("layer meta length {meta_len} out of range"));
                }
                meta = Some(String::from_utf8_lossy(r.take(meta_len as usize)?).into_owned());
            }
        }
        let clipped = has_clipped && r.u8()? != 0;
        layers.push(Layer {
            pixels: Arc::new(pixels),
            offset: (off_x, off_y),
            name,
            opacity,
            blend,
            visible,
            mask,
            mask_enabled,
            meta,
            clipped,
        });
    }
    Ok(RzDocument {
        width,
        height,
        layers,
    })
}
