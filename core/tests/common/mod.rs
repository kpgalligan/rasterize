//! Helpers shared by the FFI test files: C-string plumbing, synthesized
//! fixtures, layer/document accessors, the mirrored `Rz*` constants, the W3C
//! reference blend math, and the mask/meta fixtures several files drive.
//! Every test binary pulls this in with `mod common;`, so helpers only some
//! binaries use are expected — hence the file-wide `allow(dead_code)`.
#![allow(dead_code)]

use std::ffi::{c_char, c_int, CStr, CString};
use std::path::Path;
use std::ptr;

use image::{Rgba, RgbaImage};
use rasterize_core::doc::{MaskKind, RzDocument};
use rasterize_core::ffi::*;
use rasterize_core::ffi_doc::*;
use rasterize_core::RzImage;
use tempfile::TempDir;

pub const BLEND_NORMAL: c_int = 0;
pub const BLEND_MULTIPLY: c_int = 1;
pub const BLEND_SCREEN: c_int = 2;
pub const BLEND_OVERLAY: c_int = 3;
pub const BLEND_SOFT_LIGHT: c_int = 4;
pub const BLEND_HARD_LIGHT: c_int = 5;
pub const BLEND_DARKEN: c_int = 6;
pub const BLEND_LIGHTEN: c_int = 7;
pub const BLEND_DIFFERENCE: c_int = 8;
pub const BLEND_EXCLUSION: c_int = 9;
pub const BLEND_COLOR_DODGE: c_int = 10;
pub const BLEND_COLOR_BURN: c_int = 11;
pub const BLEND_ADDITION: c_int = 12;
pub const BLEND_SUBTRACT: c_int = 13;
pub const BLEND_DISSOLVE: c_int = 14;
pub const BLEND_LINEAR_BURN: c_int = 15;
pub const BLEND_DARKER_COLOR: c_int = 16;
pub const BLEND_LIGHTER_COLOR: c_int = 17;
pub const BLEND_VIVID_LIGHT: c_int = 18;
pub const BLEND_LINEAR_LIGHT: c_int = 19;
pub const BLEND_PIN_LIGHT: c_int = 20;
pub const BLEND_HARD_MIX: c_int = 21;
pub const BLEND_DIVIDE: c_int = 22;
pub const BLEND_HUE: c_int = 23;
pub const BLEND_SATURATION: c_int = 24;
pub const BLEND_COLOR: c_int = 25;
pub const BLEND_LUMINOSITY: c_int = 26;
pub const BLEND_MODE_COUNT: c_int = 27;

pub const COMPOSITE_OVER: c_int = 0;
pub const COMPOSITE_ERASE: c_int = 1;

pub const MASK_REVEAL_ALL: c_int = 0;
pub const MASK_HIDE_ALL: c_int = 1;
pub const MASK_FROM_SELECTION: c_int = 2;

pub const FILTER_NEAREST: c_int = 0;
pub const FILTER_BILINEAR: c_int = 1;
pub const FILTER_CATMULL_ROM: c_int = 2;
pub const FILTER_LANCZOS3: c_int = 3;

// ---------------------------------------------------------------- helpers --

pub fn cpath(p: &Path) -> CString {
    CString::new(p.to_str().expect("utf-8 path")).expect("no interior NUL")
}

pub fn take_err_string(err: *mut c_char) -> String {
    if err.is_null() {
        return "<no error message>".into();
    }
    let s = unsafe { CStr::from_ptr(err) }
        .to_string_lossy()
        .into_owned();
    unsafe { rz_string_free(err) };
    s
}

/// Materializes an `RzImage` from synthesized pixels by round-tripping a PNG
/// through the FFI (the same trick the existing integration tests use).
pub fn open_image(dir: &TempDir, name: &str, img: &RgbaImage) -> *mut RzImage {
    let path = dir.path().join(name);
    img.save(&path).expect("save pattern png");
    let c = cpath(&path);
    let mut err: *mut c_char = ptr::null_mut();
    let p = unsafe { rz_image_open(c.as_ptr(), &mut err) };
    assert!(!p.is_null(), "open failed: {}", take_err_string(err));
    p
}

pub fn img_dims(img: *const RzImage) -> (u32, u32) {
    unsafe { (rz_image_width(img), rz_image_height(img)) }
}

pub fn img_pixels(img: *const RzImage) -> Vec<u8> {
    let (w, h) = img_dims(img);
    let p = unsafe { rz_image_pixels_rgba(img) };
    assert!(!p.is_null(), "pixels pointer NULL for valid image");
    unsafe { std::slice::from_raw_parts(p, (w * h * 4) as usize) }.to_vec()
}

/// A single-layer document built from synthesized pixels.
pub fn doc_from(dir: &TempDir, name: &str, img: &RgbaImage) -> *mut RzDocument {
    let image = open_image(dir, name, img);
    let doc = unsafe { rz_doc_from_image(image) };
    unsafe { rz_image_free(image) };
    assert!(!doc.is_null());
    doc
}

/// Inserts `img` as a new layer above `idx` (asserting success), returning
/// the NEW document and freeing the old one.
pub fn add_layer(
    dir: &TempDir,
    file: &str,
    doc: *mut RzDocument,
    idx: usize,
    img: &RgbaImage,
    name: &str,
) -> *mut RzDocument {
    let image = open_image(dir, file, img);
    let cname = CString::new(name).unwrap();
    let out = unsafe { rz_doc_adding_image_layer(doc, idx, image, cname.as_ptr()) };
    unsafe { rz_image_free(image) };
    assert!(!out.is_null(), "adding_image_layer({idx}, {name}) failed");
    unsafe { rz_doc_free(doc) };
    out
}

/// Applies a doc -> doc FFI operation, asserting success and freeing the old
/// document.
pub fn apply(
    doc: *mut RzDocument,
    op: impl FnOnce(*const RzDocument) -> *mut RzDocument,
) -> *mut RzDocument {
    let out = op(doc);
    assert!(!out.is_null(), "document operation failed");
    unsafe { rz_doc_free(doc) };
    out
}

pub fn layer_pixels(doc: *const RzDocument, idx: usize) -> Vec<u8> {
    let img = unsafe { rz_doc_layer_image(doc, idx) };
    assert!(!img.is_null(), "layer_image({idx}) NULL");
    let v = img_pixels(img);
    unsafe { rz_image_free(img) };
    v
}

pub fn layer_dims(doc: *const RzDocument, idx: usize) -> (u32, u32) {
    unsafe { (rz_doc_layer_width(doc, idx), rz_doc_layer_height(doc, idx)) }
}

pub fn layer_offset(doc: *const RzDocument, idx: usize) -> (i32, i32) {
    unsafe {
        (
            rz_doc_layer_offset_x(doc, idx),
            rz_doc_layer_offset_y(doc, idx),
        )
    }
}

pub fn layer_name(doc: *const RzDocument, idx: usize) -> String {
    let p = unsafe { rz_doc_layer_name(doc, idx) };
    assert!(!p.is_null(), "layer_name({idx}) NULL");
    let s = unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned();
    unsafe { rz_string_free(p) };
    s
}

pub fn flat_pixels(doc: *const RzDocument) -> Vec<u8> {
    let img = unsafe { rz_doc_flattened(doc) };
    assert!(!img.is_null(), "flattened NULL");
    let v = img_pixels(img);
    unsafe { rz_image_free(img) };
    v
}

pub fn pixel(buf: &[u8], w: u32, x: u32, y: u32) -> [u8; 4] {
    let i = ((y * w + x) * 4) as usize;
    [buf[i], buf[i + 1], buf[i + 2], buf[i + 3]]
}

pub fn opaque_pattern(w: u32, h: u32) -> RgbaImage {
    RgbaImage::from_fn(w, h, |x, y| {
        Rgba([
            (x * 255 / w.max(1)) as u8,
            (y * 255 / h.max(1)) as u8,
            ((x * 7 + y * 13) % 256) as u8,
            255,
        ])
    })
}

pub fn solid(w: u32, h: u32, px: [u8; 4]) -> RgbaImage {
    RgbaImage::from_pixel(w, h, Rgba(px))
}

/// 64x48-style gradient with an alpha ramp (fully opaque top row, fully
/// transparent bottom row).
pub fn test_pattern(w: u32, h: u32) -> RgbaImage {
    RgbaImage::from_fn(w, h, |x, y| {
        let r = (x * 255 / (w - 1).max(1)) as u8;
        let g = (y * 255 / (h - 1).max(1)) as u8;
        let b = ((x + y) % 256) as u8;
        let a = 255 - (y * 255 / (h - 1).max(1)) as u8;
        Rgba([r, g, b, a])
    })
}

pub fn open_ok(path: &Path) -> *mut RzImage {
    let c = cpath(path);
    let mut err: *mut c_char = ptr::null_mut();
    let img = unsafe { rz_image_open(c.as_ptr(), &mut err) };
    assert!(
        !img.is_null(),
        "open of {path:?} failed: {}",
        take_err_string(err)
    );
    assert!(err.is_null(), "err_out set on success");
    img
}

/// Writes `img` as a PNG (via the image crate) and opens it back through the
/// FFI; the only way to materialize an RzImage from synthesized pixels.
pub fn open_pattern(dir: &TempDir, name: &str, img: &RgbaImage) -> *mut RzImage {
    let path = dir.path().join(name);
    img.save(&path).expect("save pattern png");
    open_ok(&path)
}

pub fn dims(img: *const RzImage) -> (u32, u32) {
    unsafe { (rz_image_width(img), rz_image_height(img)) }
}

pub fn pixels(img: *const RzImage) -> Vec<u8> {
    let (w, h) = dims(img);
    let p = unsafe { rz_image_pixels_rgba(img) };
    assert!(!p.is_null(), "pixels pointer NULL for valid image");
    unsafe { std::slice::from_raw_parts(p, (w * h * 4) as usize) }.to_vec()
}

pub fn pixel_at(img: *const RzImage, x: u32, y: u32) -> [u8; 4] {
    let (w, h) = dims(img);
    assert!(x < w && y < h);
    let v = pixels(img);
    let i = ((y * w + x) * 4) as usize;
    [v[i], v[i + 1], v[i + 2], v[i + 3]]
}

pub fn free(img: *mut RzImage) {
    unsafe { rz_image_free(img) }
}

// --------------------------------------------- reference blend math (W3C) --

pub fn ref_blend(mode: c_int, cb: f32, cs: f32) -> f32 {
    match mode {
        BLEND_NORMAL => cs,
        BLEND_MULTIPLY => cb * cs,
        BLEND_SCREEN => cb + cs - cb * cs,
        BLEND_OVERLAY => ref_blend(BLEND_HARD_LIGHT, cs, cb),
        BLEND_SOFT_LIGHT => {
            let d = if cb <= 0.25 {
                ((16.0 * cb - 12.0) * cb + 4.0) * cb
            } else {
                cb.sqrt()
            };
            if cs <= 0.5 {
                cb - (1.0 - 2.0 * cs) * cb * (1.0 - cb)
            } else {
                cb + (2.0 * cs - 1.0) * (d - cb)
            }
        }
        BLEND_HARD_LIGHT => {
            if cs <= 0.5 {
                2.0 * cb * cs
            } else {
                1.0 - 2.0 * (1.0 - cb) * (1.0 - cs)
            }
        }
        BLEND_DARKEN => cb.min(cs),
        BLEND_LIGHTEN => cb.max(cs),
        BLEND_DIFFERENCE => (cb - cs).abs(),
        BLEND_EXCLUSION => cb + cs - 2.0 * cb * cs,
        BLEND_COLOR_DODGE => {
            if cb == 0.0 {
                0.0
            } else if cs == 1.0 {
                1.0
            } else {
                (cb / (1.0 - cs)).min(1.0)
            }
        }
        BLEND_COLOR_BURN => {
            if cb == 1.0 {
                1.0
            } else if cs == 0.0 {
                0.0
            } else {
                1.0 - ((1.0 - cb) / cs).min(1.0)
            }
        }
        BLEND_ADDITION => (cb + cs).min(1.0),
        BLEND_SUBTRACT => (cb - cs).max(0.0),
        _ => panic!("unknown mode {mode}"),
    }
}

/// Full W3C compositing of one straight-alpha source pixel over a
/// straight-alpha backdrop pixel; all values in [0, 1].
pub fn ref_composite(bg: [f32; 4], src: [f32; 4], opacity: f32, mode: c_int) -> [f32; 4] {
    let sa = src[3] * opacity;
    let ab = bg[3];
    if sa <= 0.0 {
        return bg;
    }
    let ao = sa + ab * (1.0 - sa);
    let mut out = [0.0f32; 4];
    for c in 0..3 {
        out[c] = (sa * (1.0 - ab) * src[c]
            + sa * ab * ref_blend(mode, bg[c], src[c])
            + (1.0 - sa) * ab * bg[c])
            / ao;
    }
    out[3] = ao;
    out
}

pub fn to_unit(px: [u8; 4]) -> [f32; 4] {
    [
        f32::from(px[0]) / 255.0,
        f32::from(px[1]) / 255.0,
        f32::from(px[2]) / 255.0,
        f32::from(px[3]) / 255.0,
    ]
}

// ----------------------------------------------- mask & meta fixtures --

pub const RED: [u8; 4] = [255, 0, 0, 255];
pub const BLUE: [u8; 4] = [0, 0, 255, 255];

/// Opaque red canvas-sized background under an opaque blue layer of size
/// `layer` placed at `offset` (layer index 1).
pub fn mask_fixture(canvas: (u32, u32), layer: (u32, u32), offset: (i32, i32)) -> RzDocument {
    let doc = RzDocument::from_pixels(solid(canvas.0, canvas.1, RED));
    let doc = doc
        .adding_image_layer(0, solid(layer.0, layer.1, BLUE), "Top")
        .expect("add layer");
    doc.with_layer_offset(1, offset.0, offset.1)
        .expect("set offset")
}

/// Canvas-sized selection buffer from a per-pixel function.
pub fn selection(w: u32, h: u32, f: impl Fn(u32, u32) -> u8) -> Vec<u8> {
    let mut out = Vec::with_capacity((w * h) as usize);
    for y in 0..h {
        for x in 0..w {
            out.push(f(x, y));
        }
    }
    out
}

/// The mask bytes of layer `idx`, row-major.
pub fn mask_bytes(doc: &RzDocument, idx: usize) -> Vec<u8> {
    doc.layers[idx]
        .mask
        .as_ref()
        .expect("layer has a mask")
        .as_raw()
        .clone()
}

pub const GREEN: [u8; 4] = [0, 200, 0, 255];
pub const WHITE: [u8; 4] = [255, 255, 255, 255];
pub const META: &str = "{\"type\":\"text\",\"string\":\"keep me\"}";

/// Asserts the hard invariant on every layer of `doc`.
pub fn assert_mask_invariant(doc: &RzDocument, what: &str) {
    for (i, layer) in doc.layers.iter().enumerate() {
        if let Some(mask) = layer.mask.as_ref() {
            assert_eq!(
                mask.dimensions(),
                layer.pixels.dimensions(),
                "{what}: layer {i}'s mask must be exactly its pixels' size"
            );
        }
    }
}

/// `mask_fixture` with a checkerboard mask and meta on layer 1: revealed
/// where the CANVAS coordinate sum is even. A one-pixel misalignment inverts
/// the pattern, so a stale mask cannot survive the projection comparisons.
pub fn checkerboard_masked(
    canvas: (u32, u32),
    layer: (u32, u32),
    offset: (i32, i32),
) -> RzDocument {
    let doc = mask_fixture(canvas, layer, offset);
    let sel = selection(
        canvas.0,
        canvas.1,
        |x, y| if (x + y) % 2 == 0 { 255 } else { 0 },
    );
    let mut doc = doc
        .add_mask(1, MaskKind::FromSelection(&sel))
        .expect("mask from selection");
    doc.layers[1].meta = Some(META.to_string());
    doc
}

/// The FFI twin of `mask_fixture`: an opaque red canvas-sized background under
/// an opaque blue layer of size `layer` placed at `offset` (layer index 1).
pub fn ffi_mask_fixture(
    dir: &TempDir,
    tag: &str,
    canvas: (u32, u32),
    layer: (u32, u32),
    offset: (i32, i32),
) -> *mut RzDocument {
    let doc = doc_from(
        dir,
        &format!("{tag}-bg.png"),
        &solid(canvas.0, canvas.1, RED),
    );
    let doc = add_layer(
        dir,
        &format!("{tag}-top.png"),
        doc,
        0,
        &solid(layer.0, layer.1, BLUE),
        "Top",
    );
    apply(doc, |d| unsafe {
        rz_doc_with_layer_offset(d, 1, offset.0, offset.1)
    })
}

/// Layer `idx`'s coverage read back through `rz_doc_layer_mask_image`, which
/// must be an opaque grayscale image at the LAYER's size.
pub fn ffi_mask_bytes(doc: *const RzDocument, idx: usize) -> Vec<u8> {
    let img = unsafe { rz_doc_layer_mask_image(doc, idx) };
    assert!(!img.is_null(), "layer_mask_image({idx}) NULL");
    assert_eq!(
        img_dims(img),
        layer_dims(doc, idx),
        "the mask image is the layer's size, not the canvas'"
    );
    let px = img_pixels(img);
    unsafe { rz_image_free(img) };
    let mut coverage = Vec::with_capacity(px.len() / 4);
    for c in px.chunks_exact(4) {
        assert_eq!(
            [c[1], c[2], c[3]],
            [c[0], c[0], 255],
            "the mask image must be opaque grayscale"
        );
        coverage.push(c[0]);
    }
    coverage
}

/// The two mask queries as a pair, for terse before/after assertions.
pub fn ffi_mask_flags(doc: *const RzDocument, idx: usize) -> (bool, bool) {
    unsafe {
        (
            rz_doc_layer_has_mask(doc, idx),
            rz_doc_layer_mask_enabled(doc, idx),
        )
    }
}

/// A realistic text-layer payload with non-ASCII content, so "came back
/// unchanged" means byte-for-byte rather than merely non-empty.
pub const TEXT_META: &str = concat!(
    "{\"type\":\"text\",\"string\":\"héllo 层 — ✎\",",
    "\"font\":\"Helvetica Neue\",\"size\":24.5,",
    "\"color\":\"#ff8800\",\"alignment\":\"center\"}"
);

/// Layer `idx`'s metadata through `rz_doc_layer_meta`; None when the call
/// returns NULL (no metadata, or an out-of-range index).
pub fn ffi_meta(doc: *const RzDocument, idx: usize) -> Option<String> {
    let p = unsafe { rz_doc_layer_meta(doc, idx) };
    if p.is_null() {
        return None;
    }
    let s = unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned();
    unsafe { rz_string_free(p) };
    Some(s)
}

/// Sets layer `idx`'s metadata, asserting success and freeing the old handle.
pub fn set_meta(doc: *mut RzDocument, idx: usize, meta: &str) -> *mut RzDocument {
    let c = CString::new(meta).expect("no interior NUL");
    apply(doc, |d| unsafe {
        rz_doc_with_layer_meta(d, idx, c.as_ptr())
    })
}

pub const MAGENTA: [u8; 4] = [255, 0, 255, 255];

/// Meta blob for adjustment op `op` with a `params` JSON object literal.
pub fn adjust_meta(op: &str, params: &str) -> String {
    format!("{{\"type\":\"adjust\",\"op\":\"{op}\",\"params\":{params}}}")
}
