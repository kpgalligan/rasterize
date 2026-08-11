//! Layered PSD import, plus the shared "8-bit RGB and grayscale only" gate
//! that the flat open path (`RzImage::open`) applies too. Import quirks and
//! fallbacks are documented on [`open_psd`].

use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::Arc;

use image::RgbaImage;

use crate::blend::BlendMode;
use crate::doc::{Layer, RzDocument};

/// The psd crate silently mis-decodes anything but 8-bit RGB or grayscale
/// (CMYK channels land in RGB slots, 16-bit data is read byte-interleaved),
/// so both open paths — the flat `RzImage::open` composite and the layered
/// import — reject those up front with the same message.
pub(crate) fn check_supported(psd: &psd::Psd, path: &str) -> Result<(), String> {
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
    Ok(())
}

/// PSD -> RzDocument blend-mode mapping; PassThrough (group-only semantics)
/// and unknown values become Normal. The argument is the discriminant of
/// psd 0.3.5's `BlendMode` (the enum itself lives in a private module and is
/// not re-exported, so it cannot be named here — but its values are C-like
/// and cast losslessly): 0 PassThrough, 1 Normal, 2 Dissolve, 3 Darken,
/// 4 Multiply, 5 ColorBurn, 6 LinearBurn, 7 DarkerColor, 8 Lighten,
/// 9 Screen, 10 ColorDodge, 11 LinearDodge, 12 LighterColor, 13 Overlay,
/// 14 SoftLight, 15 HardLight, 16 VividLight, 17 LinearLight, 18 PinLight,
/// 19 HardMix, 20 Difference, 21 Exclusion, 22 Subtract, 23 Divide, 24 Hue,
/// 25 Saturation, 26 Color, 27 Luminosity.
fn map_psd_blend(mode: i32) -> BlendMode {
    match mode {
        2 => BlendMode::Dissolve,
        3 => BlendMode::Darken,
        4 => BlendMode::Multiply,
        5 => BlendMode::ColorBurn,
        6 => BlendMode::LinearBurn,
        7 => BlendMode::DarkerColor,
        8 => BlendMode::Lighten,
        9 => BlendMode::Screen,
        10 => BlendMode::ColorDodge,
        11 => BlendMode::Addition, // LinearDodge
        12 => BlendMode::LighterColor,
        13 => BlendMode::Overlay,
        14 => BlendMode::SoftLight,
        15 => BlendMode::HardLight,
        16 => BlendMode::VividLight,
        17 => BlendMode::LinearLight,
        18 => BlendMode::PinLight,
        19 => BlendMode::HardMix,
        20 => BlendMode::Difference,
        21 => BlendMode::Exclusion,
        22 => BlendMode::Subtract,
        23 => BlendMode::Divide,
        24 => BlendMode::Hue,
        25 => BlendMode::Saturation,
        26 => BlendMode::Color,
        27 => BlendMode::Luminosity,
        _ => BlendMode::Normal,
    }
}

/// Flattened-composite fallback: the whole PSD as one "Background" layer.
fn psd_composite_fallback(psd: &psd::Psd, path: &str) -> Result<RzDocument, String> {
    let pixels = RgbaImage::from_raw(psd.width(), psd.height(), psd.rgba())
        .ok_or_else(|| format!("PSD {path}: composite buffer size mismatch"))?;
    Ok(RzDocument::from_pixels(pixels))
}

/// Layered PSD import. One document layer per PSD raster layer; if the file
/// has no raster layers or any layer fails to decode, falls back to the
/// flattened composite.
///
/// psd 0.3.5 quirks this code compensates for (verified against the crate
/// sources and real files):
/// - `Psd::layers()` is ordered TOP-to-bottom (its `layer_by_idx` doc comment
///   claims the opposite, but the crate's own renderer consumes it top-down),
///   so the iteration is reversed for our bottom-first stack.
/// - `PsdLayer::visible()` actually returns the record's HIDDEN flag (bit 1
///   of the flags byte set means hidden in real files), so it is negated.
/// - `PsdLayer::rgba()` returns a CANVAS-sized buffer with the layer placed
///   at its rectangle — but for layers with no alpha channel it floods
///   alpha=255 across the whole canvas (opaque black outside the layer), and
///   for layers whose rectangle leaves the canvas it can panic. The buffer is
///   therefore cropped to the layer's rectangle intersected with the canvas
///   (which also yields real per-layer offsets), and each decode runs under
///   `catch_unwind`.
pub(crate) fn open_psd(bytes: &[u8], path: &str) -> Result<RzDocument, String> {
    let psd =
        psd::Psd::from_bytes(bytes).map_err(|e| format!("failed to decode PSD {path}: {e}"))?;
    check_supported(&psd, path)?;
    let (cw, ch) = (psd.width(), psd.height());
    if cw == 0 || ch == 0 {
        return Err(format!("PSD {path}: empty canvas"));
    }
    if psd.layers().is_empty() {
        return psd_composite_fallback(&psd, path);
    }
    let canvas_len = cw as usize * ch as usize * 4;
    let mut layers = Vec::with_capacity(psd.layers().len());
    for l in psd.layers().iter().rev() {
        let rgba = match catch_unwind(AssertUnwindSafe(|| l.rgba())) {
            Ok(rgba) if rgba.len() == canvas_len => rgba,
            _ => return psd_composite_fallback(&psd, path),
        };
        // Intersect the layer rectangle (crate bounds are inclusive) with the
        // canvas.
        let x0 = l.layer_left().max(0) as i64;
        let y0 = l.layer_top().max(0) as i64;
        let x1 = (i64::from(l.layer_right()) + 1).min(i64::from(cw));
        let y1 = (i64::from(l.layer_bottom()) + 1).min(i64::from(ch));
        let (pixels, offset) = if x0 < x1 && y0 < y1 {
            let (w, h) = ((x1 - x0) as u32, (y1 - y0) as u32);
            let img = RgbaImage::from_fn(w, h, |x, y| {
                let cx = x0 as u32 + x;
                let cy = y0 as u32 + y;
                let i = (cy as usize * cw as usize + cx as usize) * 4;
                image::Rgba([rgba[i], rgba[i + 1], rgba[i + 2], rgba[i + 3]])
            });
            (img, (x0 as i32, y0 as i32))
        } else {
            // The layer is entirely outside the canvas; keep a minimal
            // transparent placeholder so the layer (and its properties)
            // survive the import.
            (RgbaImage::new(1, 1), (0, 0))
        };
        layers.push(Layer {
            pixels: Arc::new(pixels),
            offset,
            name: l.name().to_string(),
            opacity: f32::from(l.opacity()) / 255.0,
            blend: map_psd_blend(l.blend_mode() as i32),
            visible: !l.visible(),
            // PSD layer masks are not imported (the crate exposes them only
            // as raw channel data); imported layers arrive unmasked. The PSD
            // clipping bit is not exposed by the crate either, so imported
            // layers arrive unclipped.
            mask: None,
            mask_enabled: true,
            meta: None,
            clipped: false,
        });
    }
    Ok(RzDocument {
        width: cw,
        height: ch,
        layers,
    })
}
