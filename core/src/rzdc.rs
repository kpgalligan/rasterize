//! The RZDC native document format: encoder, atomic writer and
//! bounds-checked reader, plus the hard caps both sides enforce. The doc
//! comment on [`RzDocument::encode_native`] IS the format spec.

use std::sync::Arc;

use image::codecs::png::PngEncoder;
use image::{ExtendedColorType, GrayImage, ImageEncoder};

use crate::blend::BlendMode;
use crate::doc::{sane_opacity, Layer, RzDocument, MAX_PIXELS};
use crate::rz_image::save_atomically;
use crate::style::{GlobalLight, LayerStyle};

/// Hard caps applied while reading RZDC files so corrupt headers cannot ask
/// for absurd allocations. The meta cap is shared by BOTH per-layer string
/// slots (meta and the layer style) and is also what the FFI meta and style
/// setters enforce, so a document can never carry a string the writer would
/// refuse.
const MAX_RZDC_LAYERS: u32 = 1024;
const MAX_RZDC_NAME_LEN: u32 = 64 * 1024;
const MAX_RZDC_PNG_LEN: u32 = 512 * 1024 * 1024;
pub(crate) const MAX_RZDC_META_LEN: u32 = 16 * 1024 * 1024;

/// The RZDC revision this build writes. Version 1 files (no mask, no layer
/// meta), version 2 files (no clipped flag) and version 3 files (no layer
/// style, no global light) still load; anything newer is refused.
const RZDC_VERSION: u32 = 4;

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
    ///
    /// Version 4 adds two document fields right after the layer count — f32
    /// global-light angle, f32 global-light altitude (degrees) — and one more
    /// per-layer field after the version-3 clipped byte (a version-3 record
    /// is a strict prefix of a version-4 one): u8 style present and, when
    /// present, u32 style len + UTF-8 canonical style JSON (see `style`),
    /// encoded and capped exactly like meta.
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
        // Version 4 document fields.
        let light = self.global_light.sane();
        buf.extend_from_slice(&light.angle.to_le_bytes());
        buf.extend_from_slice(&light.altitude.to_le_bytes());
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
            put_opt_string(&mut buf, layer.meta.as_deref(), "meta")?;
            // Version 3 field.
            buf.push(u8::from(layer.clipped));
            // Version 4 field: the canonical style JSON.
            let style = layer.style.as_ref().map(|s| s.to_json());
            put_opt_string(&mut buf, style.as_deref(), "style")?;
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

/// Writes an optional string slot (meta, style): u8 present, then u32 len +
/// UTF-8 bytes when present. The cap error names the slot.
fn put_opt_string(buf: &mut Vec<u8>, value: Option<&str>, what: &str) -> Result<(), String> {
    buf.push(u8::from(value.is_some()));
    if let Some(s) = value {
        let len = u32::try_from(s.len())
            .ok()
            .filter(|&len| len <= MAX_RZDC_META_LEN)
            .ok_or_else(|| format!("layer {what} too large (max {MAX_RZDC_META_LEN})"))?;
        buf.extend_from_slice(&len.to_le_bytes());
        buf.extend_from_slice(s.as_bytes());
    }
    Ok(())
}

/// Reads an optional string slot written by [`put_opt_string`]; the cap
/// error names the slot. Lenient on UTF-8 (lossy), like names and meta.
fn take_opt_string(r: &mut Reader<'_>, what: &str) -> Result<Option<String>, String> {
    if r.u8()? == 0 {
        return Ok(None);
    }
    let len = r.u32()?;
    if len > MAX_RZDC_META_LEN {
        return Err(format!("layer {what} length {len} out of range"));
    }
    Ok(Some(
        String::from_utf8_lossy(r.take(len as usize)?).into_owned(),
    ))
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

/// Parses an RZDC buffer of version 1 to 4 (version 1 predates layer masks
/// and layer meta, which default to absent; versions 1 and 2 predate the
/// clipped flag, which defaults to false; versions 1 to 3 predate the layer
/// style and the global light, which default to absent / (120°, 30°)).
/// Corrupt or truncated input produces `Err`, never a panic; unknown
/// blend-mode values fall back to Normal, opacity is clamped, the light is
/// sanitized, and a style is read LENIENTLY (`LayerStyle::from_json_lenient`:
/// a style from a newer build keeps the effects this build knows; only a
/// structurally malformed style — or an identity — loads as no style).
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
    // after the mask and meta fields; version 3 records after the clipped
    // byte.
    let has_mask_and_meta = version >= 2;
    let has_clipped = version >= 3;
    let has_style = version >= 4;
    let width = r.u32()?;
    let height = r.u32()?;
    if width == 0 || height == 0 || u64::from(width) * u64::from(height) > MAX_PIXELS {
        return Err("invalid canvas size".to_string());
    }
    let count = r.u32()?;
    if count == 0 || count > MAX_RZDC_LAYERS {
        return Err(format!("invalid layer count {count}"));
    }
    // Version 4 document fields; lenient on values, like opacity.
    let global_light = if version >= 4 {
        GlobalLight {
            angle: r.f32()?,
            altitude: r.f32()?,
        }
        .sane()
    } else {
        GlobalLight::default()
    };
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
            meta = take_opt_string(&mut r, "meta")?;
        }
        let clipped = has_clipped && r.u8()? != 0;
        let style = if has_style {
            take_opt_string(&mut r, "style")?
                .and_then(|s| LayerStyle::from_json_lenient(&s).ok())
                .filter(|s| !s.is_identity())
                .map(Arc::new)
        } else {
            None
        };
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
            style,
        });
    }
    Ok(RzDocument {
        width,
        height,
        layers,
        global_light,
    })
}
