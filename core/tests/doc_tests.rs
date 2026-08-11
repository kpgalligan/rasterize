//! Integration tests for the layered document model, exercised through the
//! public C FFI (`rz_doc_*`) declared in `include/rasterize_core.h`.

use std::ffi::{c_char, c_int, CStr, CString};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::ptr;
use std::sync::Arc;

use image::{GrayImage, Luma, Rgba, RgbaImage};
use rasterize_core::doc::{BlendMode, MaskKind, RzDocument};
use rasterize_core::doc_select::feather_mask;
use rasterize_core::ffi::*;
use rasterize_core::ffi_doc::*;
use rasterize_core::RzImage;
use tempfile::TempDir;

const BLEND_NORMAL: c_int = 0;
const BLEND_MULTIPLY: c_int = 1;
const BLEND_SCREEN: c_int = 2;
const BLEND_OVERLAY: c_int = 3;
const BLEND_SOFT_LIGHT: c_int = 4;
const BLEND_HARD_LIGHT: c_int = 5;
const BLEND_DARKEN: c_int = 6;
const BLEND_LIGHTEN: c_int = 7;
const BLEND_DIFFERENCE: c_int = 8;
const BLEND_EXCLUSION: c_int = 9;
const BLEND_COLOR_DODGE: c_int = 10;
const BLEND_COLOR_BURN: c_int = 11;
const BLEND_ADDITION: c_int = 12;
const BLEND_SUBTRACT: c_int = 13;
const BLEND_DISSOLVE: c_int = 14;
const BLEND_LINEAR_BURN: c_int = 15;
const BLEND_DARKER_COLOR: c_int = 16;
const BLEND_LIGHTER_COLOR: c_int = 17;
const BLEND_VIVID_LIGHT: c_int = 18;
const BLEND_LINEAR_LIGHT: c_int = 19;
const BLEND_PIN_LIGHT: c_int = 20;
const BLEND_HARD_MIX: c_int = 21;
const BLEND_DIVIDE: c_int = 22;
const BLEND_HUE: c_int = 23;
const BLEND_SATURATION: c_int = 24;
const BLEND_COLOR: c_int = 25;
const BLEND_LUMINOSITY: c_int = 26;
const BLEND_MODE_COUNT: c_int = 27;

const COMPOSITE_OVER: c_int = 0;
const COMPOSITE_ERASE: c_int = 1;

const MASK_REVEAL_ALL: c_int = 0;
const MASK_HIDE_ALL: c_int = 1;
const MASK_FROM_SELECTION: c_int = 2;

const FILTER_NEAREST: c_int = 0;
const FILTER_BILINEAR: c_int = 1;
const FILTER_CATMULL_ROM: c_int = 2;
const FILTER_LANCZOS3: c_int = 3;

// ---------------------------------------------------------------- helpers --

fn cpath(p: &Path) -> CString {
    CString::new(p.to_str().expect("utf-8 path")).expect("no interior NUL")
}

fn take_err_string(err: *mut c_char) -> String {
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
fn open_image(dir: &TempDir, name: &str, img: &RgbaImage) -> *mut RzImage {
    let path = dir.path().join(name);
    img.save(&path).expect("save pattern png");
    let c = cpath(&path);
    let mut err: *mut c_char = ptr::null_mut();
    let p = unsafe { rz_image_open(c.as_ptr(), &mut err) };
    assert!(!p.is_null(), "open failed: {}", take_err_string(err));
    p
}

fn img_dims(img: *const RzImage) -> (u32, u32) {
    unsafe { (rz_image_width(img), rz_image_height(img)) }
}

fn img_pixels(img: *const RzImage) -> Vec<u8> {
    let (w, h) = img_dims(img);
    let p = unsafe { rz_image_pixels_rgba(img) };
    assert!(!p.is_null(), "pixels pointer NULL for valid image");
    unsafe { std::slice::from_raw_parts(p, (w * h * 4) as usize) }.to_vec()
}

/// A single-layer document built from synthesized pixels.
fn doc_from(dir: &TempDir, name: &str, img: &RgbaImage) -> *mut RzDocument {
    let image = open_image(dir, name, img);
    let doc = unsafe { rz_doc_from_image(image) };
    unsafe { rz_image_free(image) };
    assert!(!doc.is_null());
    doc
}

/// Inserts `img` as a new layer above `idx` (asserting success), returning
/// the NEW document and freeing the old one.
fn add_layer(
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
fn apply(
    doc: *mut RzDocument,
    op: impl FnOnce(*const RzDocument) -> *mut RzDocument,
) -> *mut RzDocument {
    let out = op(doc);
    assert!(!out.is_null(), "document operation failed");
    unsafe { rz_doc_free(doc) };
    out
}

fn layer_pixels(doc: *const RzDocument, idx: usize) -> Vec<u8> {
    let img = unsafe { rz_doc_layer_image(doc, idx) };
    assert!(!img.is_null(), "layer_image({idx}) NULL");
    let v = img_pixels(img);
    unsafe { rz_image_free(img) };
    v
}

fn layer_dims(doc: *const RzDocument, idx: usize) -> (u32, u32) {
    unsafe { (rz_doc_layer_width(doc, idx), rz_doc_layer_height(doc, idx)) }
}

fn layer_offset(doc: *const RzDocument, idx: usize) -> (i32, i32) {
    unsafe {
        (
            rz_doc_layer_offset_x(doc, idx),
            rz_doc_layer_offset_y(doc, idx),
        )
    }
}

fn layer_name(doc: *const RzDocument, idx: usize) -> String {
    let p = unsafe { rz_doc_layer_name(doc, idx) };
    assert!(!p.is_null(), "layer_name({idx}) NULL");
    let s = unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned();
    unsafe { rz_string_free(p) };
    s
}

fn flat_pixels(doc: *const RzDocument) -> Vec<u8> {
    let img = unsafe { rz_doc_flattened(doc) };
    assert!(!img.is_null(), "flattened NULL");
    let v = img_pixels(img);
    unsafe { rz_image_free(img) };
    v
}

fn pixel(buf: &[u8], w: u32, x: u32, y: u32) -> [u8; 4] {
    let i = ((y * w + x) * 4) as usize;
    [buf[i], buf[i + 1], buf[i + 2], buf[i + 3]]
}

fn opaque_pattern(w: u32, h: u32) -> RgbaImage {
    RgbaImage::from_fn(w, h, |x, y| {
        Rgba([
            (x * 255 / w.max(1)) as u8,
            (y * 255 / h.max(1)) as u8,
            ((x * 7 + y * 13) % 256) as u8,
            255,
        ])
    })
}

fn solid(w: u32, h: u32, px: [u8; 4]) -> RgbaImage {
    RgbaImage::from_pixel(w, h, Rgba(px))
}

// --------------------------------------------- reference blend math (W3C) --

fn ref_blend(mode: c_int, cb: f32, cs: f32) -> f32 {
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
fn ref_composite(bg: [f32; 4], src: [f32; 4], opacity: f32, mode: c_int) -> [f32; 4] {
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

fn to_unit(px: [u8; 4]) -> [f32; 4] {
    [
        f32::from(px[0]) / 255.0,
        f32::from(px[1]) / 255.0,
        f32::from(px[2]) / 255.0,
        f32::from(px[3]) / 255.0,
    ]
}

/// Builds a two-layer doc (solid bottom, solid top with mode/opacity) and
/// returns the flattened top-left pixel.
fn blended_pixel(
    dir: &TempDir,
    tag: &str,
    bottom: [u8; 4],
    top: [u8; 4],
    mode: c_int,
    opacity: f32,
) -> [u8; 4] {
    let doc = doc_from(dir, &format!("b-{tag}.png"), &solid(2, 2, bottom));
    let doc = add_layer(
        dir,
        &format!("t-{tag}.png"),
        doc,
        0,
        &solid(2, 2, top),
        "Top",
    );
    let doc = apply(doc, |d| unsafe { rz_doc_with_layer_blend_mode(d, 1, mode) });
    let doc = apply(doc, |d| unsafe { rz_doc_with_layer_opacity(d, 1, opacity) });
    let flat = flat_pixels(doc);
    unsafe { rz_doc_free(doc) };
    pixel(&flat, 2, 0, 0)
}

// ------------------------------------------------------------------ tests --

#[test]
fn open_single_layer_and_from_image() {
    let dir = TempDir::new().unwrap();
    let pattern = opaque_pattern(16, 12);

    // rz_doc_open on a plain PNG: single "Background" layer.
    let path = dir.path().join("plain.png");
    pattern.save(&path).unwrap();
    let c = cpath(&path);
    let mut err: *mut c_char = ptr::null_mut();
    let doc = unsafe { rz_doc_open(c.as_ptr(), &mut err) };
    assert!(!doc.is_null(), "doc open failed: {}", take_err_string(err));
    assert!(err.is_null());
    assert_eq!(unsafe { rz_doc_width(doc) }, 16);
    assert_eq!(unsafe { rz_doc_height(doc) }, 12);
    assert_eq!(unsafe { rz_doc_layer_count(doc) }, 1);
    assert_eq!(layer_name(doc, 0), "Background");
    assert_eq!(layer_dims(doc, 0), (16, 12));
    assert_eq!(layer_offset(doc, 0), (0, 0));
    assert_eq!(unsafe { rz_doc_layer_opacity(doc, 0) }, 1.0);
    assert_eq!(unsafe { rz_doc_layer_blend_mode(doc, 0) }, BLEND_NORMAL);
    assert!(unsafe { rz_doc_layer_visible(doc, 0) });
    assert_eq!(flat_pixels(doc), *pattern.as_raw());
    assert_eq!(layer_pixels(doc, 0), *pattern.as_raw());

    // rz_doc_from_image produces the same document; clone is independent.
    let img = open_image(&dir, "same.png", &pattern);
    let doc2 = unsafe { rz_doc_from_image(img) };
    unsafe { rz_image_free(img) };
    assert!(!doc2.is_null());
    assert_eq!(flat_pixels(doc2), *pattern.as_raw());
    let clone = unsafe { rz_doc_clone(doc2) };
    assert!(!clone.is_null());
    unsafe { rz_doc_free(doc2) };
    assert_eq!(unsafe { rz_doc_layer_count(clone) }, 1);
    assert_eq!(flat_pixels(clone), *pattern.as_raw());
    unsafe { rz_doc_free(clone) };
    unsafe { rz_doc_free(doc) };
}

#[test]
fn blend_mode_math_opaque_layers() {
    let dir = TempDir::new().unwrap();
    // (tag, mode, bottom RGB, top RGB) — values chosen to hit both branches
    // of the piecewise modes and the divide-by-zero edges of dodge/burn.
    let cases: &[(&str, c_int, [u8; 3], [u8; 3])] = &[
        ("mul", BLEND_MULTIPLY, [51, 102, 204], [102, 153, 255]),
        ("scr", BLEND_SCREEN, [51, 102, 204], [102, 153, 255]),
        ("ovr", BLEND_OVERLAY, [51, 204, 128], [100, 100, 200]),
        ("hard", BLEND_HARD_LIGHT, [51, 204, 128], [100, 200, 128]),
        ("dark", BLEND_DARKEN, [51, 204, 100], [102, 153, 100]),
        ("light", BLEND_LIGHTEN, [51, 204, 100], [102, 153, 100]),
        ("diff", BLEND_DIFFERENCE, [200, 30, 128], [100, 80, 128]),
        ("excl", BLEND_EXCLUSION, [200, 30, 128], [100, 80, 128]),
        // color-dodge edges: cb==0 -> 0 (even with cs==1), cs==255 -> 1,
        // plus a normal channel.
        ("dodge", BLEND_COLOR_DODGE, [0, 100, 100], [255, 255, 100]),
        // color-burn edges: cb==255 -> 1, cs==0 -> 0, normal channel.
        ("burn", BLEND_COLOR_BURN, [255, 100, 100], [10, 0, 200]),
        // soft-light: cs <= 0.5 branch, then cs > 0.5 with cb <= 0.25
        // (polynomial d) and cb > 0.25 (sqrt d).
        ("soft1", BLEND_SOFT_LIGHT, [40, 150, 220], [64, 64, 64]),
        ("soft2", BLEND_SOFT_LIGHT, [40, 150, 220], [200, 200, 200]),
        ("add", BLEND_ADDITION, [200, 100, 10], [100, 100, 10]),
        ("sub", BLEND_SUBTRACT, [30, 200, 100], [100, 50, 100]),
    ];
    for &(tag, mode, cb, cs) in cases {
        let got = blended_pixel(
            &dir,
            tag,
            [cb[0], cb[1], cb[2], 255],
            [cs[0], cs[1], cs[2], 255],
            mode,
            1.0,
        );
        for c in 0..3 {
            let b = ref_blend(mode, f32::from(cb[c]) / 255.0, f32::from(cs[c]) / 255.0);
            let want = (b.clamp(0.0, 1.0) * 255.0).round();
            assert!(
                (f32::from(got[c]) - want).abs() <= 1.0,
                "{tag} channel {c}: got {}, want ~{want}",
                got[c]
            );
        }
        assert_eq!(got[3], 255, "{tag}: opaque stack must stay opaque");
    }
}

#[test]
fn blend_full_formula_with_opacity_and_transparency() {
    let dir = TempDir::new().unwrap();

    // Normal at opacity 0.5 over an opaque backdrop: Co = 0.5 Cs + 0.5 Cb.
    let got = blended_pixel(
        &dir,
        "op50",
        [40, 80, 120, 255],
        [240, 20, 60, 255],
        BLEND_NORMAL,
        0.5,
    );
    for c in 0..3 {
        let want =
            (0.5 * f32::from([240u8, 20, 60][c]) + 0.5 * f32::from([40u8, 80, 120][c])).round();
        assert!(
            (f32::from(got[c]) - want).abs() <= 1.0,
            "opacity 0.5 channel {c}: got {}, want ~{want}",
            got[c]
        );
    }
    assert_eq!(got[3], 255);

    // Semi-transparent backdrop AND semi-transparent scaled source exercise
    // every term of the W3C formula (not the simplified opaque form).
    let bottom = [40, 200, 120, 128];
    let top = [220, 60, 30, 200];
    let (mode, opacity) = (BLEND_MULTIPLY, 0.7);
    let got = blended_pixel(&dir, "w3c", bottom, top, mode, opacity);
    let want = ref_composite(to_unit(bottom), to_unit(top), opacity, mode);
    for c in 0..4 {
        let want_b = (want[c].clamp(0.0, 1.0) * 255.0).round();
        assert!(
            (f32::from(got[c]) - want_b).abs() <= 1.0,
            "full-formula channel {c}: got {}, want ~{want_b}",
            got[c]
        );
    }

    // Zero-opacity layer contributes nothing.
    let got = blended_pixel(
        &dir,
        "op0",
        [10, 20, 30, 255],
        [200, 200, 200, 255],
        BLEND_NORMAL,
        0.0,
    );
    assert_eq!(got, [10, 20, 30, 255]);
}

#[test]
fn blend_mode_math_new_separable_modes() {
    let dir = TempDir::new().unwrap();
    // (tag, mode, bottom RGB, top RGB, expected RGB on the 255 scale) —
    // hand-computed from the header's formulas, covering both branches of the
    // piecewise modes and the cs==0 / cs==1 edges. All values here are exact
    // (byte arithmetic), so a wrong branch or formula misses by far more than
    // the 1-count quantization tolerance.
    #[allow(clippy::type_complexity)]
    let cases: &[(&str, c_int, [u8; 3], [u8; 3], [f32; 3])] = &[
        // (cb + cs - 1).max(0): 200+100-255=45; 50+100-255<0 -> 0; 255+200-255.
        (
            "lburn",
            BLEND_LINEAR_BURN,
            [200, 50, 255],
            [100, 100, 200],
            [45.0, 0.0, 200.0],
        ),
        // cs<=0.5 -> burn(cb, 2cs) = 1 - (127/255)/(128/255) = 1/128 -> 1.99;
        // cs>0.5 -> dodge(cb, 2cs-1) = (64/255)/(1 - 127/255) = 0.5 -> 127.5;
        // cs==1 -> dodge edge -> 1.
        (
            "vivid",
            BLEND_VIVID_LIGHT,
            [128, 64, 100],
            [64, 191, 255],
            [1.99, 127.5, 255.0],
        ),
        // cb + 2cs - 1 clamped: 100+200-255=45; 30+100-255<0 -> 0;
        // 200+400-255=345 -> 255.
        (
            "llight",
            BLEND_LINEAR_LIGHT,
            [100, 30, 200],
            [100, 50, 200],
            [45.0, 0.0, 255.0],
        ),
        // cs<=0.5 -> min(cb, 2cs): min(200,120), min(50,120);
        // cs>0.5 -> max(cb, 2cs-1): max(100, 145).
        (
            "pin",
            BLEND_PIN_LIGHT,
            [200, 50, 100],
            [60, 60, 200],
            [120.0, 50.0, 145.0],
        ),
        // cb+cs >= 1 -> 1 else 0: 256/255 -> 1; 200/255 -> 0; exactly 1 -> 1.
        (
            "hmix",
            BLEND_HARD_MIX,
            [128, 100, 255],
            [128, 100, 0],
            [255.0, 0.0, 255.0],
        ),
        // cb/cs clamped: 100/200 -> 127.5; 200/100 -> clamp 255; 60/180 -> 85.
        (
            "div",
            BLEND_DIVIDE,
            [100, 200, 60],
            [200, 100, 180],
            [127.5, 255.0, 85.0],
        ),
        // cs == 0 -> 1 regardless of cb (including cb == 0).
        (
            "div0",
            BLEND_DIVIDE,
            [50, 0, 128],
            [0, 0, 0],
            [255.0, 255.0, 255.0],
        ),
    ];
    for &(tag, mode, cb, cs, want) in cases {
        let got = blended_pixel(
            &dir,
            tag,
            [cb[0], cb[1], cb[2], 255],
            [cs[0], cs[1], cs[2], 255],
            mode,
            1.0,
        );
        for c in 0..3 {
            assert!(
                (f32::from(got[c]) - want[c]).abs() <= 1.0,
                "{tag} channel {c}: got {}, want ~{}",
                got[c],
                want[c]
            );
        }
        assert_eq!(got[3], 255, "{tag}: opaque stack must stay opaque");
    }
}

#[test]
fn blend_mode_math_non_separable() {
    let dir = TempDir::new().unwrap();
    // cb = (128, 64, 192)/255, cs = (51, 204, 102)/255 = (0.2, 0.8, 0.4).
    // Expectations hand-executed from the W3C SetLum/SetSat pseudocode with
    // Lum = 0.3R + 0.59G + 0.11B, all on the 255 scale:
    //   lum(cb) = 0.3*128 + 0.59*64 + 0.11*192 = 97.28
    //   lum(cs) = 0.3*51 + 0.59*204 + 0.11*102 = 146.88
    //   sat(cb) = 192-64 = 128, sat(cs) = 204-51 = 153
    // hue = set_lum(set_sat(cs, 128), 97.28):
    //   set_sat(cs, 128): min r->0, max g->128, mid b->(102-51)*128/153=42.667
    //   lum(0, 128, 42.667) = 80.213; d = 17.067 -> (17.07, 145.07, 59.73),
    //   in gamut so ClipColor is the identity.
    // saturation = set_lum(set_sat(cb, 153), 97.28):
    //   set_sat(cb, 153): min g->0, max b->153, mid r->(128-64)*153/128=76.5
    //   lum(76.5, 0, 153) = 39.78; d = 57.5 -> (134, 57.5, 210.5).
    // color = set_lum(cs, 97.28): d = 97.28-146.88 = -49.6
    //   -> (1.4, 154.4, 52.4).
    // luminosity = set_lum(cb, 146.88): d = 49.6 -> (177.6, 113.6, 241.6).
    let cb = [128u8, 64, 192];
    let cs = [51u8, 204, 102];
    let cases: &[(&str, c_int, [f32; 3])] = &[
        ("hue", BLEND_HUE, [17.07, 145.07, 59.73]),
        ("nsat", BLEND_SATURATION, [134.0, 57.5, 210.5]),
        ("ncol", BLEND_COLOR, [1.4, 154.4, 52.4]),
        ("nlum", BLEND_LUMINOSITY, [177.6, 113.6, 241.6]),
    ];
    for &(tag, mode, want) in cases {
        let got = blended_pixel(
            &dir,
            tag,
            [cb[0], cb[1], cb[2], 255],
            [cs[0], cs[1], cs[2], 255],
            mode,
            1.0,
        );
        for c in 0..3 {
            assert!(
                (f32::from(got[c]) - want[c]).abs() <= 1.0,
                "{tag} channel {c}: got {}, want ~{}",
                got[c],
                want[c]
            );
        }
        assert_eq!(got[3], 255, "{tag}: opaque stack must stay opaque");
    }
}

#[test]
fn darker_and_lighter_color_pick_whole_pixels() {
    let dir = TempDir::new().unwrap();
    // Red has lum 0.3, blue lum 0.11.
    let red = [255, 0, 0, 255];
    let blue = [0, 0, 255, 255];
    // Darker color keeps the whole lower-luma pixel (blue); a per-channel
    // darken of the same pair would produce black.
    let got = blended_pixel(&dir, "dkcl", red, blue, BLEND_DARKER_COLOR, 1.0);
    assert_eq!(got, blue, "darker color must keep the whole blue pixel");
    // Lighter color keeps the whole higher-luma pixel (red, the backdrop); a
    // per-channel lighten would produce magenta (255, 0, 255).
    let got = blended_pixel(&dir, "ltcl", red, blue, BLEND_LIGHTER_COLOR, 1.0);
    assert_eq!(got, red, "lighter color must keep the whole red pixel");
}

#[test]
fn dissolve_is_deterministic_and_dithers_by_alpha() {
    let dir = TempDir::new().unwrap();
    let backdrop = [10, 20, 30, 255];
    let source = [200, 150, 100, 255];
    let doc = doc_from(&dir, "dis-bg.png", &solid(100, 100, backdrop));
    let doc = add_layer(
        &dir,
        "dis-top.png",
        doc,
        0,
        &solid(100, 100, source),
        "Dissolve",
    );
    let doc = apply(doc, |d| unsafe {
        rz_doc_with_layer_blend_mode(d, 1, BLEND_DISSOLVE)
    });
    let doc = apply(doc, |d| unsafe { rz_doc_with_layer_opacity(d, 1, 0.5) });

    // Deterministic: flattening twice yields byte-identical output.
    let flat = flat_pixels(doc);
    assert_eq!(flat, flat_pixels(doc), "dissolve must be deterministic");

    // Every output pixel is either the untouched backdrop or the fully
    // opaque source; at 50% effective alpha the dissolved fraction over
    // 10000 pixels must land close to one half.
    let mut dissolved = 0usize;
    for (i, px) in flat.chunks_exact(4).enumerate() {
        let px = [px[0], px[1], px[2], px[3]];
        assert!(
            px == source || px == backdrop,
            "pixel {i}: dissolve output {px:?} is neither opaque source nor backdrop"
        );
        if px == source {
            dissolved += 1;
        }
    }
    let fraction = dissolved as f64 / 10_000.0;
    assert!(
        (0.45..=0.55).contains(&fraction),
        "dissolved fraction {fraction} outside 45-55%"
    );
    unsafe { rz_doc_free(doc) };
}

#[test]
fn rzdc_round_trip_preserves_all_blend_modes() {
    let dir = TempDir::new().unwrap();
    let mut doc = doc_from(&dir, "modes.png", &solid(2, 2, [9, 9, 9, 255]));
    let lname = CString::new("L").unwrap();
    for _ in 1..BLEND_MODE_COUNT {
        doc = apply(doc, |d| unsafe {
            rz_doc_adding_layer(d, 0, lname.as_ptr())
        });
    }
    for mode in 0..BLEND_MODE_COUNT {
        doc = apply(doc, |d| unsafe {
            rz_doc_with_layer_blend_mode(d, mode as usize, mode)
        });
    }
    // The first value past the end of the enum is rejected.
    assert!(unsafe { rz_doc_with_layer_blend_mode(doc, 0, BLEND_MODE_COUNT) }.is_null());

    let path = dir.path().join("modes.rzdc");
    let c = cpath(&path);
    let mut err: *mut c_char = ptr::null_mut();
    assert!(
        unsafe { rz_doc_save_native(doc, c.as_ptr(), &mut err) },
        "save failed: {}",
        take_err_string(err)
    );
    let mut err: *mut c_char = ptr::null_mut();
    let reopened = unsafe { rz_doc_open(c.as_ptr(), &mut err) };
    assert!(
        !reopened.is_null(),
        "reopen failed: {}",
        take_err_string(err)
    );
    assert_eq!(
        unsafe { rz_doc_layer_count(reopened) },
        BLEND_MODE_COUNT as usize
    );
    for mode in 0..BLEND_MODE_COUNT {
        assert_eq!(
            unsafe { rz_doc_layer_blend_mode(reopened, mode as usize) },
            mode,
            "layer {mode} blend mode after round trip"
        );
    }
    unsafe { rz_doc_free(reopened) };
    unsafe { rz_doc_free(doc) };
}

#[test]
fn layer_offsets_clip_and_show_backdrop() {
    let dir = TempDir::new().unwrap();
    let red = [255, 0, 0, 255];
    let doc = doc_from(&dir, "bg.png", &solid(6, 5, red));
    // 2x2 layer with four distinct pixels so the mapping is unambiguous.
    let mut quad = RgbaImage::new(2, 2);
    quad.put_pixel(0, 0, Rgba([0, 0, 255, 255]));
    quad.put_pixel(1, 0, Rgba([0, 255, 0, 255]));
    quad.put_pixel(0, 1, Rgba([255, 255, 0, 255]));
    quad.put_pixel(1, 1, Rgba([0, 255, 255, 255]));
    let doc = add_layer(&dir, "quad.png", doc, 0, &quad, "Quad");
    let doc = apply(doc, |d| unsafe { rz_doc_with_layer_offset(d, 1, 3, 2) });
    let flat = flat_pixels(doc);
    assert_eq!(pixel(&flat, 6, 3, 2), [0, 0, 255, 255]);
    assert_eq!(pixel(&flat, 6, 4, 2), [0, 255, 0, 255]);
    assert_eq!(pixel(&flat, 6, 3, 3), [255, 255, 0, 255]);
    assert_eq!(pixel(&flat, 6, 4, 3), [0, 255, 255, 255]);
    // Everything else is backdrop.
    for y in 0..5u32 {
        for x in 0..6u32 {
            if (3..5).contains(&x) && (2..4).contains(&y) {
                continue;
            }
            assert_eq!(pixel(&flat, 6, x, y), red, "backdrop leak at ({x},{y})");
        }
    }

    // Negative offset: only the layer's bottom-right pixel remains visible.
    let doc = apply(doc, |d| unsafe { rz_doc_with_layer_offset(d, 1, -1, -1) });
    let flat = flat_pixels(doc);
    assert_eq!(
        pixel(&flat, 6, 0, 0),
        [0, 255, 255, 255],
        "quad(1,1) at canvas origin"
    );
    assert_eq!(pixel(&flat, 6, 1, 0), red);
    assert_eq!(pixel(&flat, 6, 0, 1), red);
    unsafe { rz_doc_free(doc) };
}

#[test]
fn setters_are_pure_and_validate() {
    let dir = TempDir::new().unwrap();
    let doc = doc_from(&dir, "bg.png", &opaque_pattern(4, 4));

    let changed = unsafe { rz_doc_with_layer_opacity(doc, 0, 0.25) };
    assert!(!changed.is_null());
    assert_ne!(doc as usize, changed as usize);
    assert_eq!(unsafe { rz_doc_layer_opacity(changed, 0) }, 0.25);
    assert_eq!(
        unsafe { rz_doc_layer_opacity(doc, 0) },
        1.0,
        "original document mutated"
    );
    unsafe { rz_doc_free(changed) };

    // Clamping.
    let hi = unsafe { rz_doc_with_layer_opacity(doc, 0, 3.0) };
    assert_eq!(unsafe { rz_doc_layer_opacity(hi, 0) }, 1.0);
    unsafe { rz_doc_free(hi) };
    let lo = unsafe { rz_doc_with_layer_opacity(doc, 0, -0.5) };
    assert_eq!(unsafe { rz_doc_layer_opacity(lo, 0) }, 0.0);
    unsafe { rz_doc_free(lo) };

    // Name, blend, visible, offset round-trips leave the original untouched.
    let name = CString::new("Étage 层").unwrap();
    let named = unsafe { rz_doc_with_layer_name(doc, 0, name.as_ptr()) };
    assert_eq!(layer_name(named, 0), "Étage 层");
    assert_eq!(layer_name(doc, 0), "Background");
    unsafe { rz_doc_free(named) };

    let blended = unsafe { rz_doc_with_layer_blend_mode(doc, 0, BLEND_SCREEN) };
    assert_eq!(unsafe { rz_doc_layer_blend_mode(blended, 0) }, BLEND_SCREEN);
    assert_eq!(unsafe { rz_doc_layer_blend_mode(doc, 0) }, BLEND_NORMAL);
    unsafe { rz_doc_free(blended) };

    let hidden = unsafe { rz_doc_with_layer_visible(doc, 0, false) };
    assert!(!unsafe { rz_doc_layer_visible(hidden, 0) });
    assert!(unsafe { rz_doc_layer_visible(doc, 0) });
    unsafe { rz_doc_free(hidden) };

    let moved = unsafe { rz_doc_with_layer_offset(doc, 0, -7, 9) };
    assert_eq!(layer_offset(moved, 0), (-7, 9));
    assert_eq!(layer_offset(doc, 0), (0, 0));
    unsafe { rz_doc_free(moved) };

    // with_layer_pixels replaces pixels (any size), keeps properties.
    let tiny = open_image(&dir, "tiny.png", &solid(2, 3, [9, 8, 7, 255]));
    let offset_doc = unsafe { rz_doc_with_layer_offset(doc, 0, 5, 5) };
    let repl = unsafe { rz_doc_with_layer_pixels(offset_doc, 0, tiny) };
    unsafe { rz_image_free(tiny) };
    assert!(!repl.is_null());
    assert_eq!(layer_dims(repl, 0), (2, 3));
    assert_eq!(layer_offset(repl, 0), (5, 5), "offset must be kept");
    assert_eq!(layer_name(repl, 0), "Background");
    unsafe { rz_doc_free(repl) };
    unsafe { rz_doc_free(offset_doc) };

    // Out-of-range idx -> NULL for every setter.
    let name = CString::new("x").unwrap();
    unsafe {
        assert!(rz_doc_with_layer_name(doc, 1, name.as_ptr()).is_null());
        assert!(rz_doc_with_layer_opacity(doc, 1, 0.5).is_null());
        assert!(rz_doc_with_layer_blend_mode(doc, 1, BLEND_NORMAL).is_null());
        assert!(rz_doc_with_layer_visible(doc, 1, false).is_null());
        assert!(rz_doc_with_layer_offset(doc, 1, 0, 0).is_null());
        // Unknown blend mode value -> NULL.
        assert!(rz_doc_with_layer_blend_mode(doc, 0, 99).is_null());
    }

    // Out-of-range getters return defaults.
    unsafe {
        assert!(rz_doc_layer_name(doc, 5).is_null());
        assert_eq!(rz_doc_layer_opacity(doc, 5), 0.0);
        assert_eq!(rz_doc_layer_blend_mode(doc, 5), BLEND_NORMAL);
        assert!(!rz_doc_layer_visible(doc, 5));
        assert_eq!(rz_doc_layer_offset_x(doc, 5), 0);
        assert_eq!(rz_doc_layer_offset_y(doc, 5), 0);
        assert_eq!(rz_doc_layer_width(doc, 5), 0);
        assert_eq!(rz_doc_layer_height(doc, 5), 0);
        assert!(rz_doc_layer_image(doc, 5).is_null());
        assert!(rz_doc_layer_thumbnail(doc, 5, 10).is_null());
    }
    unsafe { rz_doc_free(doc) };
}

#[test]
fn stack_operations() {
    let dir = TempDir::new().unwrap();
    let red = solid(4, 4, [255, 0, 0, 255]);
    let green = solid(4, 4, [0, 255, 0, 255]);
    let blue = solid(4, 4, [0, 0, 255, 255]);

    let doc = doc_from(&dir, "red.png", &red);

    // adding_layer: transparent canvas-sized layer above idx 0.
    let cname = CString::new("Empty").unwrap();
    let with_empty = unsafe { rz_doc_adding_layer(doc, 0, cname.as_ptr()) };
    assert!(!with_empty.is_null());
    assert_eq!(unsafe { rz_doc_layer_count(with_empty) }, 2);
    assert_eq!(layer_name(with_empty, 1), "Empty");
    assert_eq!(layer_dims(with_empty, 1), (4, 4));
    assert_eq!(layer_offset(with_empty, 1), (0, 0));
    assert!(layer_pixels(with_empty, 1).iter().all(|&b| b == 0));
    // A transparent layer does not change the projection.
    assert_eq!(flat_pixels(with_empty), *red.as_raw());
    unsafe { rz_doc_free(with_empty) };
    assert_eq!(unsafe { rz_doc_layer_count(doc) }, 1, "original mutated");

    // adding_image_layer above the bottom, then another above that.
    let doc = add_layer(&dir, "green.png", doc, 0, &green, "Green");
    let doc = add_layer(&dir, "blue.png", doc, 1, &blue, "Blue");
    assert_eq!(unsafe { rz_doc_layer_count(doc) }, 3);
    assert_eq!(layer_name(doc, 0), "Background");
    assert_eq!(layer_name(doc, 1), "Green");
    assert_eq!(layer_name(doc, 2), "Blue");
    assert_eq!(pixel(&layer_pixels(doc, 1), 4, 0, 0), [0, 255, 0, 255]);
    assert_eq!(pixel(&layer_pixels(doc, 2), 4, 0, 0), [0, 0, 255, 255]);

    // duplicating_layer: " copy" suffix, same pixels, inserted above.
    let doc = apply(doc, |d| unsafe { rz_doc_duplicating_layer(d, 1) });
    assert_eq!(unsafe { rz_doc_layer_count(doc) }, 4);
    assert_eq!(layer_name(doc, 2), "Green copy");
    assert_eq!(layer_pixels(doc, 2), *green.as_raw());
    assert_eq!(layer_name(doc, 3), "Blue");

    // moving_layer: remove at `from`, insert at `to`.
    let doc = apply(doc, |d| unsafe { rz_doc_moving_layer(d, 0, 3) });
    assert_eq!(layer_name(doc, 0), "Green");
    assert_eq!(layer_name(doc, 1), "Green copy");
    assert_eq!(layer_name(doc, 2), "Blue");
    assert_eq!(layer_name(doc, 3), "Background");
    let doc = apply(doc, |d| unsafe { rz_doc_moving_layer(d, 3, 0) });
    assert_eq!(layer_name(doc, 0), "Background");
    assert_eq!(layer_name(doc, 1), "Green");

    // removing_layer.
    let doc = apply(doc, |d| unsafe { rz_doc_removing_layer(d, 2) });
    assert_eq!(unsafe { rz_doc_layer_count(doc) }, 3);
    assert_eq!(layer_name(doc, 2), "Blue");

    // Index validation.
    let cname = CString::new("nope").unwrap();
    unsafe {
        assert!(rz_doc_adding_layer(doc, 3, cname.as_ptr()).is_null());
        assert!(rz_doc_duplicating_layer(doc, 3).is_null());
        assert!(rz_doc_removing_layer(doc, 3).is_null());
        assert!(rz_doc_moving_layer(doc, 0, 3).is_null());
        assert!(rz_doc_moving_layer(doc, 3, 0).is_null());
    }
    unsafe { rz_doc_free(doc) };

    // The last remaining layer cannot be removed.
    let last = doc_from(&dir, "last.png", &red);
    assert!(unsafe { rz_doc_removing_layer(last, 0) }.is_null());
    unsafe { rz_doc_free(last) };
}

#[test]
fn merge_down_matches_flatten_and_handles_extents() {
    let dir = TempDir::new().unwrap();

    // Same-extent merge must equal the projection of the pair exactly (same
    // kernel, single quantization).
    let doc = doc_from(&dir, "bg.png", &opaque_pattern(6, 4));
    let doc = add_layer(
        &dir,
        "top.png",
        doc,
        0,
        &solid(6, 4, [180, 40, 220, 200]),
        "Top",
    );
    let doc = apply(doc, |d| unsafe {
        rz_doc_with_layer_blend_mode(d, 1, BLEND_MULTIPLY)
    });
    let doc = apply(doc, |d| unsafe { rz_doc_with_layer_opacity(d, 1, 0.6) });
    let flat_before = flat_pixels(doc);
    let merged = unsafe { rz_doc_merging_down(doc, 1) };
    assert!(!merged.is_null());
    assert_eq!(unsafe { rz_doc_layer_count(merged) }, 1);
    assert_eq!(layer_name(merged, 0), "Background");
    assert_eq!(unsafe { rz_doc_layer_opacity(merged, 0) }, 1.0);
    assert_eq!(unsafe { rz_doc_layer_blend_mode(merged, 0) }, BLEND_NORMAL);
    assert_eq!(layer_offset(merged, 0), (0, 0));
    assert_eq!(
        flat_pixels(merged),
        flat_before,
        "merge_down must equal flatten of the pair"
    );
    unsafe { rz_doc_free(merged) };
    assert_eq!(unsafe { rz_doc_layer_count(doc) }, 2, "original mutated");
    unsafe { rz_doc_free(doc) };

    // Offset layers: merged layer covers the union of both extents.
    let green = [0, 200, 0, 255];
    let magenta = [255, 0, 255, 255];
    let doc = doc_from(&dir, "base10.png", &opaque_pattern(10, 8));
    let doc = add_layer(&dir, "a.png", doc, 0, &solid(3, 2, green), "A");
    let doc = apply(doc, |d| unsafe { rz_doc_with_layer_offset(d, 1, 1, 1) });
    let doc = add_layer(&dir, "b.png", doc, 1, &solid(2, 2, magenta), "B");
    let doc = apply(doc, |d| unsafe { rz_doc_with_layer_offset(d, 2, 3, 2) });
    let flat_before = flat_pixels(doc);
    let merged = unsafe { rz_doc_merging_down(doc, 2) };
    assert!(!merged.is_null());
    assert_eq!(unsafe { rz_doc_layer_count(merged) }, 2);
    assert_eq!(layer_name(merged, 1), "A");
    assert_eq!(layer_offset(merged, 1), (1, 1), "union origin");
    assert_eq!(layer_dims(merged, 1), (4, 3), "union extent");
    let mp = layer_pixels(merged, 1);
    assert_eq!(pixel(&mp, 4, 0, 0), green, "A-only region");
    assert_eq!(pixel(&mp, 4, 1, 1), green, "A under nothing");
    assert_eq!(pixel(&mp, 4, 2, 1), magenta, "B over A overlap");
    assert_eq!(pixel(&mp, 4, 3, 2), magenta, "B-only region");
    assert_eq!(pixel(&mp, 4, 3, 0), [0, 0, 0, 0], "uncovered union corner");
    assert_eq!(pixel(&mp, 4, 0, 2), [0, 0, 0, 0], "uncovered union corner");
    // The projection is unchanged by merging.
    assert_eq!(flat_pixels(merged), flat_before);
    unsafe { rz_doc_free(merged) };

    // Invisible upper layer: merge_down simply removes it.
    let hidden = apply(unsafe { rz_doc_clone(doc) }, |d| unsafe {
        rz_doc_with_layer_visible(d, 2, false)
    });
    let a_before = layer_pixels(hidden, 1);
    let merged = unsafe { rz_doc_merging_down(hidden, 2) };
    assert!(!merged.is_null());
    assert_eq!(unsafe { rz_doc_layer_count(merged) }, 2);
    assert_eq!(layer_pixels(merged, 1), a_before, "lower must be unchanged");
    assert_eq!(layer_offset(merged, 1), (1, 1));
    assert_eq!(layer_dims(merged, 1), (3, 2));
    unsafe { rz_doc_free(merged) };
    unsafe { rz_doc_free(hidden) };

    // merging_down(0) and OOB -> NULL.
    unsafe {
        assert!(rz_doc_merging_down(doc, 0).is_null());
        assert!(rz_doc_merging_down(doc, 3).is_null());
    }

    // flattening: one "Background" layer, projection preserved.
    let flattened = unsafe { rz_doc_flattening(doc) };
    assert!(!flattened.is_null());
    assert_eq!(unsafe { rz_doc_layer_count(flattened) }, 1);
    assert_eq!(layer_name(flattened, 0), "Background");
    assert_eq!(layer_offset(flattened, 0), (0, 0));
    assert_eq!(layer_dims(flattened, 0), (10, 8));
    assert_eq!(flat_pixels(flattened), flat_before);
    unsafe { rz_doc_free(flattened) };
    unsafe { rz_doc_free(doc) };
}

#[test]
fn merge_down_bakes_lower_opacity_and_blend() {
    let dir = TempDir::new().unwrap();

    // Lower layer at opacity 0.5 with Multiply under a semi-transparent
    // upper: merging must bake BOTH layers' modes/opacities into the pixels
    // (lower over a transparent backdrop, where Multiply degenerates to
    // Normal), so the projection is unchanged by the merge.
    let doc = doc_from(&dir, "mb-lo.png", &solid(5, 4, [40, 200, 120, 255]));
    let doc = apply(doc, |d| unsafe { rz_doc_with_layer_opacity(d, 0, 0.5) });
    let doc = apply(doc, |d| unsafe {
        rz_doc_with_layer_blend_mode(d, 0, BLEND_MULTIPLY)
    });
    let doc = add_layer(
        &dir,
        "mb-hi.png",
        doc,
        0,
        &solid(5, 4, [220, 60, 30, 160]),
        "Upper",
    );
    let flat_before = flat_pixels(doc);
    let merged = unsafe { rz_doc_merging_down(doc, 1) };
    assert!(!merged.is_null());
    assert_eq!(unsafe { rz_doc_layer_count(merged) }, 1);
    assert_eq!(layer_name(merged, 0), "Background");
    assert_eq!(
        unsafe { rz_doc_layer_opacity(merged, 0) },
        1.0,
        "lower opacity must be baked, not kept"
    );
    assert_eq!(
        unsafe { rz_doc_layer_blend_mode(merged, 0) },
        BLEND_NORMAL,
        "lower blend must be baked, not kept"
    );
    let flat_after = flat_pixels(merged);
    for (i, (&a, &b)) in flat_after.iter().zip(flat_before.iter()).enumerate() {
        assert!(
            (i32::from(a) - i32::from(b)).abs() <= 1,
            "byte {i}: merged {a} vs pre-merge {b}"
        );
    }
    unsafe { rz_doc_free(merged) };
    unsafe { rz_doc_free(doc) };
}

#[test]
fn merge_down_onto_hidden_lower_is_refused() {
    let dir = TempDir::new().unwrap();
    let doc = doc_from(&dir, "mh-lo.png", &solid(4, 4, [10, 20, 30, 255]));
    let doc = add_layer(
        &dir,
        "mh-hi.png",
        doc,
        0,
        &solid(4, 4, [200, 100, 50, 255]),
        "Upper",
    );
    // Merging a visible layer into a hidden lower layer would make the upper
    // content vanish from the projection; it must fail instead.
    let hidden = apply(unsafe { rz_doc_clone(doc) }, |d| unsafe {
        rz_doc_with_layer_visible(d, 0, false)
    });
    assert!(
        unsafe { rz_doc_merging_down(hidden, 1) }.is_null(),
        "merge into a hidden lower layer must fail"
    );
    unsafe { rz_doc_free(hidden) };
    // With the lower visible the same merge succeeds.
    let merged = unsafe { rz_doc_merging_down(doc, 1) };
    assert!(!merged.is_null());
    unsafe { rz_doc_free(merged) };
    unsafe { rz_doc_free(doc) };
}

#[test]
fn painting_layer_over_and_erase() {
    let dir = TempDir::new().unwrap();
    let bottom = opaque_pattern(8, 6);
    let top = solid(4, 3, [10, 20, 30, 255]);
    let doc = doc_from(&dir, "bg.png", &bottom);
    let doc = add_layer(&dir, "top.png", doc, 0, &top, "Paint");
    let doc = apply(doc, |d| unsafe { rz_doc_with_layer_offset(d, 1, 2, 1) });

    // Opaque premultiplied red square covering canvas x 3..6, y 2..4.
    let mut overlay = [0u8; 8 * 6 * 4];
    for y in 2..4u32 {
        for x in 3..6u32 {
            let i = ((y * 8 + x) * 4) as usize;
            overlay[i..i + 4].copy_from_slice(&[255, 0, 0, 255]);
        }
    }
    let painted =
        unsafe { rz_doc_painting_layer(doc, 1, overlay.as_ptr(), 8, 6, COMPOSITE_OVER, 1.0) };
    assert!(!painted.is_null());
    let lp = layer_pixels(painted, 1);
    for ly in 0..3u32 {
        for lx in 0..4u32 {
            let (cx, cy) = (lx + 2, ly + 1);
            let inside = (3..6).contains(&cx) && (2..4).contains(&cy);
            let got = pixel(&lp, 4, lx, ly);
            if inside {
                assert_eq!(got, [255, 0, 0, 255], "paint missing at layer ({lx},{ly})");
            } else {
                assert_eq!(got, [10, 20, 30, 255], "paint leaked to layer ({lx},{ly})");
            }
        }
    }
    // Other layers and the source document are untouched.
    assert_eq!(layer_pixels(painted, 0), *bottom.as_raw());
    assert_eq!(layer_pixels(doc, 1), *top.as_raw(), "original mutated");
    assert_eq!(layer_offset(painted, 1), (2, 1));
    unsafe { rz_doc_free(painted) };

    // ERASE halves alpha through a 128-alpha overlay.
    let erase_overlay = [128u8; 8 * 6 * 4];
    let erased = unsafe {
        rz_doc_painting_layer(doc, 1, erase_overlay.as_ptr(), 8, 6, COMPOSITE_ERASE, 1.0)
    };
    assert!(!erased.is_null());
    let ep = layer_pixels(erased, 1);
    for (i, chunk) in ep.chunks_exact(4).enumerate() {
        assert_eq!(&chunk[..3], &[10, 20, 30], "erase changed color at {i}");
        assert!(
            (f32::from(chunk[3]) - 127.0).abs() <= 1.0,
            "erase alpha at {i}: got {}",
            chunk[3]
        );
    }
    unsafe { rz_doc_free(erased) };

    // Guards: dimension mismatch, unknown mode, NaN alpha, OOB idx, NULL src.
    unsafe {
        assert!(
            rz_doc_painting_layer(doc, 1, overlay.as_ptr(), 7, 6, COMPOSITE_OVER, 1.0).is_null()
        );
        assert!(
            rz_doc_painting_layer(doc, 1, overlay.as_ptr(), 8, 5, COMPOSITE_OVER, 1.0).is_null()
        );
        assert!(rz_doc_painting_layer(doc, 1, overlay.as_ptr(), 8, 6, 99, 1.0).is_null());
        assert!(
            rz_doc_painting_layer(doc, 1, overlay.as_ptr(), 8, 6, COMPOSITE_OVER, f32::NAN)
                .is_null()
        );
        assert!(
            rz_doc_painting_layer(doc, 9, overlay.as_ptr(), 8, 6, COMPOSITE_OVER, 1.0).is_null()
        );
        assert!(rz_doc_painting_layer(doc, 1, ptr::null(), 8, 6, COMPOSITE_OVER, 1.0).is_null());
    }
    unsafe { rz_doc_free(doc) };
}

#[test]
fn painting_layer_outside_extent_returns_null() {
    let dir = TempDir::new().unwrap();
    let doc = doc_from(&dir, "po-bg.png", &opaque_pattern(8, 6));
    let doc = add_layer(
        &dir,
        "po-small.png",
        doc,
        0,
        &solid(2, 2, [10, 20, 30, 255]),
        "Small",
    );
    let overlay = [255u8; 8 * 6 * 4]; // opaque premultiplied white, full frame

    // Layer entirely outside the canvas: no overlay pixel can reach it, so
    // the paint must fail (NULL) instead of returning an unchanged copy.
    let doc = apply(doc, |d| unsafe { rz_doc_with_layer_offset(d, 1, 100, 100) });
    unsafe {
        assert!(
            rz_doc_painting_layer(doc, 1, overlay.as_ptr(), 8, 6, COMPOSITE_OVER, 1.0).is_null(),
            "painting a layer fully outside the canvas must fail"
        );
    }

    // Partial intersection still paints the covered pixel and leaves the
    // off-canvas ones untouched.
    let doc = apply(doc, |d| unsafe { rz_doc_with_layer_offset(d, 1, -1, -1) });
    let painted =
        unsafe { rz_doc_painting_layer(doc, 1, overlay.as_ptr(), 8, 6, COMPOSITE_OVER, 1.0) };
    assert!(!painted.is_null(), "partial intersection must still paint");
    let lp = layer_pixels(painted, 1);
    assert_eq!(pixel(&lp, 2, 1, 1), [255, 255, 255, 255], "on-canvas pixel");
    assert_eq!(pixel(&lp, 2, 0, 0), [10, 20, 30, 255], "off-canvas pixel");
    assert_eq!(pixel(&lp, 2, 1, 0), [10, 20, 30, 255], "off-canvas pixel");
    assert_eq!(pixel(&lp, 2, 0, 1), [10, 20, 30, 255], "off-canvas pixel");
    unsafe { rz_doc_free(painted) };
    unsafe { rz_doc_free(doc) };
}

/// Builds the asymmetric geometry fixture: 7x5 canvas, semi-transparent 3x2
/// layer at (1, 1) blended with multiply.
fn geometry_fixture(dir: &TempDir, tag: &str, offset: (i32, i32)) -> *mut RzDocument {
    let doc = doc_from(dir, &format!("geo-bg-{tag}.png"), &opaque_pattern(7, 5));
    let layer = RgbaImage::from_fn(3, 2, |x, y| {
        Rgba([
            (x * 90 + 20) as u8,
            (y * 100 + 40) as u8,
            ((x + y) * 60 + 10) as u8,
            if (x + y) % 2 == 0 { 255 } else { 128 },
        ])
    });
    let doc = add_layer(dir, &format!("geo-l-{tag}.png"), doc, 0, &layer, "Geo");
    let doc = apply(doc, |d| unsafe {
        rz_doc_with_layer_blend_mode(d, 1, BLEND_MULTIPLY)
    });
    apply(doc, |d| unsafe {
        rz_doc_with_layer_offset(d, 1, offset.0, offset.1)
    })
}

#[test]
fn geometry_ops_commute_with_flatten() {
    let dir = TempDir::new().unwrap();

    type DocOp = unsafe extern "C" fn(*const RzDocument) -> *mut RzDocument;
    type ImgOp = unsafe extern "C" fn(*const RzImage) -> *mut RzImage;
    let ops: &[(&str, DocOp, ImgOp)] = &[
        ("rotate90", rz_doc_rotate90, rz_image_rotate90),
        ("rotate180", rz_doc_rotate180, rz_image_rotate180),
        ("rotate270", rz_doc_rotate270, rz_image_rotate270),
        ("flip_h", rz_doc_flip_horizontal, rz_image_flip_horizontal),
        ("flip_v", rz_doc_flip_vertical, rz_image_flip_vertical),
    ];

    // Both an interior offset and a negative (clipping) offset.
    for (tag, offset) in [("in", (1, 1)), ("neg", (-1, -1))] {
        let doc = geometry_fixture(&dir, tag, offset);
        let flat = unsafe { rz_doc_flattened(doc) };
        assert!(!flat.is_null());
        for (name, doc_op, img_op) in ops {
            let rotated_doc = unsafe { doc_op(doc) };
            assert!(!rotated_doc.is_null(), "{name} failed");
            let a = flat_pixels(rotated_doc);
            let rotated_flat = unsafe { img_op(flat) };
            let b = img_pixels(rotated_flat);
            let (aw, ah) = {
                let d = rotated_doc;
                unsafe { (rz_doc_width(d), rz_doc_height(d)) }
            };
            assert_eq!((aw, ah), img_dims(rotated_flat), "{name}/{tag}: dims");
            assert_eq!(a, b, "{name}/{tag}: flatten must commute with geometry");
            unsafe { rz_image_free(rotated_flat) };
            unsafe { rz_doc_free(rotated_doc) };
        }
        unsafe { rz_image_free(flat) };
        unsafe { rz_doc_free(doc) };
    }

    // Explicit dimension/offset formulas on the interior fixture:
    // (name, op, canvas dims, layer dims, layer offset).
    type GeoCheck = (
        &'static str,
        unsafe extern "C" fn(*const RzDocument) -> *mut RzDocument,
        (u32, u32),
        (u32, u32),
        (i32, i32),
    );
    let doc = geometry_fixture(&dir, "fx", (1, 1));
    let checks: &[GeoCheck] = &[
        ("rotate90", rz_doc_rotate90, (5, 7), (2, 3), (2, 1)),
        ("rotate180", rz_doc_rotate180, (7, 5), (3, 2), (3, 2)),
        ("rotate270", rz_doc_rotate270, (5, 7), (2, 3), (1, 3)),
        ("flip_h", rz_doc_flip_horizontal, (7, 5), (3, 2), (3, 1)),
        ("flip_v", rz_doc_flip_vertical, (7, 5), (3, 2), (1, 2)),
    ];
    for &(name, op, canvas, ldims, loff) in checks {
        let out = unsafe { op(doc) };
        assert!(!out.is_null());
        assert_eq!(
            unsafe { (rz_doc_width(out), rz_doc_height(out)) },
            canvas,
            "{name}: canvas dims"
        );
        assert_eq!(layer_dims(out, 1), ldims, "{name}: layer dims");
        assert_eq!(layer_offset(out, 1), loff, "{name}: layer offset");
        unsafe { rz_doc_free(out) };
    }

    // rotate270(rotate90(doc)) is the identity.
    let there = unsafe { rz_doc_rotate90(doc) };
    let back = unsafe { rz_doc_rotate270(there) };
    assert_eq!(flat_pixels(back), flat_pixels(doc));
    assert_eq!(layer_offset(back, 1), (1, 1));
    unsafe { rz_doc_free(there) };
    unsafe { rz_doc_free(back) };
    unsafe { rz_doc_free(doc) };
}

#[test]
fn crop_shifts_offsets_and_resize_scales() {
    let dir = TempDir::new().unwrap();
    let doc = geometry_fixture(&dir, "crop", (1, 1));
    let layer_before = layer_pixels(doc, 1);
    let flat = unsafe { rz_doc_flattened(doc) };

    // Crop: canvas window moves; layer pixels untouched, offsets shift.
    let cropped = unsafe { rz_doc_crop(doc, 2, 1, 4, 3) };
    assert!(!cropped.is_null());
    assert_eq!(
        unsafe { (rz_doc_width(cropped), rz_doc_height(cropped)) },
        (4, 3)
    );
    assert_eq!(layer_offset(cropped, 1), (-1, 0));
    assert_eq!(layer_offset(cropped, 0), (-2, -1));
    assert_eq!(
        layer_pixels(cropped, 1),
        layer_before,
        "crop must not touch pixels"
    );
    // Projection of the cropped doc == crop of the projection.
    let flat_crop = unsafe { rz_image_crop(flat, 2, 1, 4, 3) };
    assert!(!flat_crop.is_null());
    assert_eq!(flat_pixels(cropped), img_pixels(flat_crop));
    unsafe { rz_image_free(flat_crop) };
    unsafe { rz_doc_free(cropped) };

    // Crop validation mirrors rz_image_crop.
    unsafe {
        assert!(rz_doc_crop(doc, 0, 0, 0, 3).is_null());
        assert!(rz_doc_crop(doc, 0, 0, 3, 0).is_null());
        assert!(rz_doc_crop(doc, 5, 0, 3, 3).is_null());
        assert!(rz_doc_crop(doc, 0, 4, 2, 2).is_null());
        assert!(rz_doc_crop(doc, u32::MAX, 0, 2, 2).is_null());
    }

    // Resize by exactly 2x: canvas, layer dims, and offsets all double.
    let resized = unsafe { rz_doc_resize(doc, 14, 10, FILTER_NEAREST) };
    assert!(!resized.is_null());
    assert_eq!(
        unsafe { (rz_doc_width(resized), rz_doc_height(resized)) },
        (14, 10)
    );
    assert_eq!(layer_dims(resized, 0), (14, 10));
    assert_eq!(layer_dims(resized, 1), (6, 4));
    assert_eq!(layer_offset(resized, 1), (2, 2));
    unsafe { rz_doc_free(resized) };

    // Resize guards: zero dims, absurd target, unknown filter.
    unsafe {
        assert!(rz_doc_resize(doc, 0, 5, FILTER_BILINEAR).is_null());
        assert!(rz_doc_resize(doc, 5, 0, FILTER_BILINEAR).is_null());
        assert!(rz_doc_resize(doc, 10_000, 10_001, FILTER_BILINEAR).is_null());
        assert!(rz_doc_resize(doc, 5, 5, 99).is_null());
    }

    // Thumbnails: aspect-fit with the longest side == max_side, upscaling
    // small layers.
    let thumb = unsafe { rz_doc_layer_thumbnail(doc, 0, 4) };
    assert!(!thumb.is_null());
    assert_eq!(img_dims(thumb), (4, 3)); // 7x5 -> longest side 4
    unsafe { rz_image_free(thumb) };
    let thumb = unsafe { rz_doc_layer_thumbnail(doc, 1, 9) };
    assert!(!thumb.is_null());
    assert_eq!(img_dims(thumb), (9, 6)); // 3x2 upscaled
    unsafe { rz_image_free(thumb) };
    let thumb = unsafe { rz_doc_layer_thumbnail(doc, 1, 0) };
    assert!(!thumb.is_null());
    assert_eq!(img_dims(thumb), (1, 1)); // max_side clamps up to 1
    unsafe { rz_image_free(thumb) };

    unsafe { rz_image_free(flat) };
    unsafe { rz_doc_free(doc) };
}

/// Builds the 3-layer document used by the RZDC round-trip tests.
fn rzdc_fixture(dir: &TempDir) -> *mut RzDocument {
    let doc = doc_from(dir, "rz-bg.png", &opaque_pattern(9, 7));
    let mid = RgbaImage::from_fn(4, 3, |x, y| {
        Rgba([
            (x * 60) as u8,
            (y * 80) as u8,
            200,
            ((x + y) * 40 + 50) as u8,
        ])
    });
    let doc = add_layer(dir, "rz-mid.png", doc, 0, &mid, "Ébauche 层");
    let doc = apply(doc, |d| unsafe { rz_doc_with_layer_offset(d, 1, -3, 2) });
    let doc = apply(doc, |d| unsafe { rz_doc_with_layer_opacity(d, 1, 0.6) });
    let doc = apply(doc, |d| unsafe {
        rz_doc_with_layer_blend_mode(d, 1, BLEND_MULTIPLY)
    });
    let top = solid(2, 5, [250, 128, 3, 200]);
    let doc = add_layer(dir, "rz-top.png", doc, 1, &top, "guide/mask");
    let doc = apply(doc, |d| unsafe { rz_doc_with_layer_offset(d, 2, 5, -4) });
    let doc = apply(doc, |d| unsafe { rz_doc_with_layer_opacity(d, 2, 0.25) });
    let doc = apply(doc, |d| unsafe {
        rz_doc_with_layer_blend_mode(d, 2, BLEND_SCREEN)
    });
    apply(doc, |d| unsafe { rz_doc_with_layer_visible(d, 2, false) })
}

#[test]
fn rzdc_round_trip_preserves_everything() {
    let dir = TempDir::new().unwrap();
    let doc = rzdc_fixture(&dir);

    let path = dir.path().join("doc.rzdc");
    let c = cpath(&path);
    let mut err: *mut c_char = ptr::null_mut();
    let ok = unsafe { rz_doc_save_native(doc, c.as_ptr(), &mut err) };
    assert!(ok, "save_native failed: {}", take_err_string(err));
    assert!(err.is_null());
    let header = std::fs::read(&path).unwrap();
    assert_eq!(&header[..4], b"RZDC", "file must start with the magic");

    let mut err: *mut c_char = ptr::null_mut();
    let reopened = unsafe { rz_doc_open(c.as_ptr(), &mut err) };
    assert!(
        !reopened.is_null(),
        "reopen failed: {}",
        take_err_string(err)
    );

    assert_eq!(unsafe { rz_doc_width(reopened) }, unsafe {
        rz_doc_width(doc)
    });
    assert_eq!(unsafe { rz_doc_height(reopened) }, unsafe {
        rz_doc_height(doc)
    });
    assert_eq!(unsafe { rz_doc_layer_count(reopened) }, 3);
    for idx in 0..3usize {
        assert_eq!(
            layer_name(reopened, idx),
            layer_name(doc, idx),
            "layer {idx} name"
        );
        assert_eq!(
            unsafe { rz_doc_layer_opacity(reopened, idx) },
            unsafe { rz_doc_layer_opacity(doc, idx) },
            "layer {idx} opacity"
        );
        assert_eq!(
            unsafe { rz_doc_layer_blend_mode(reopened, idx) },
            unsafe { rz_doc_layer_blend_mode(doc, idx) },
            "layer {idx} blend"
        );
        assert_eq!(
            unsafe { rz_doc_layer_visible(reopened, idx) },
            unsafe { rz_doc_layer_visible(doc, idx) },
            "layer {idx} visibility"
        );
        assert_eq!(
            layer_offset(reopened, idx),
            layer_offset(doc, idx),
            "layer {idx} offset"
        );
        assert_eq!(
            layer_dims(reopened, idx),
            layer_dims(doc, idx),
            "layer {idx} dims"
        );
        assert_eq!(
            layer_pixels(reopened, idx),
            layer_pixels(doc, idx),
            "layer {idx} pixels must be byte-identical"
        );
    }
    assert_eq!(flat_pixels(reopened), flat_pixels(doc));
    unsafe { rz_doc_free(reopened) };
    unsafe { rz_doc_free(doc) };
}

#[test]
fn rzdc_corrupt_truncated_and_lenient_fields() {
    let dir = TempDir::new().unwrap();
    let doc = rzdc_fixture(&dir);
    let path = dir.path().join("doc.rzdc");
    let c = cpath(&path);
    let mut err: *mut c_char = ptr::null_mut();
    assert!(unsafe { rz_doc_save_native(doc, c.as_ptr(), &mut err) });
    unsafe { rz_doc_free(doc) };
    let bytes = std::fs::read(&path).unwrap();

    // Truncations at various depths: header, layer table, PNG payload.
    for cut in [
        0usize,
        3,
        4,
        10,
        17,
        20,
        bytes.len() / 3,
        bytes.len() / 2,
        bytes.len() - 1,
    ] {
        let tpath = dir.path().join(format!("cut-{cut}.rzdc"));
        std::fs::write(&tpath, &bytes[..cut]).unwrap();
        let tc = cpath(&tpath);
        let mut err: *mut c_char = ptr::null_mut();
        let p = unsafe { rz_doc_open(tc.as_ptr(), &mut err) };
        assert!(p.is_null(), "truncated file (cut {cut}) must not open");
        assert!(!err.is_null(), "truncation (cut {cut}) must set an error");
        assert!(!take_err_string(err).is_empty());
    }

    // Bad magic.
    let mut bad = bytes.clone();
    bad[3] = b'X';
    let bpath = dir.path().join("bad-magic.rzdc");
    std::fs::write(&bpath, &bad).unwrap();
    let bc = cpath(&bpath);
    let mut err: *mut c_char = ptr::null_mut();
    let p = unsafe { rz_doc_open(bc.as_ptr(), &mut err) };
    assert!(p.is_null(), "bad magic must not open");
    assert!(!take_err_string(err).is_empty());

    // Zero layer count is rejected.
    let mut zero = bytes[..16].to_vec();
    zero.extend_from_slice(&0u32.to_le_bytes());
    let zpath = dir.path().join("zero.rzdc");
    std::fs::write(&zpath, &zero).unwrap();
    let zc = cpath(&zpath);
    let mut err: *mut c_char = ptr::null_mut();
    assert!(unsafe { rz_doc_open(zc.as_ptr(), &mut err) }.is_null());
    assert!(!take_err_string(err).is_empty());

    // Hand-crafted file with an unknown blend value and out-of-range opacity:
    // opens leniently (Normal, clamped).
    let mut png = Vec::new();
    solid(2, 2, [1, 2, 3, 255])
        .write_to(&mut std::io::Cursor::new(&mut png), image::ImageFormat::Png)
        .unwrap();
    let mut crafted = Vec::new();
    crafted.extend_from_slice(b"RZDC");
    crafted.extend_from_slice(&1u32.to_le_bytes());
    crafted.extend_from_slice(&2u32.to_le_bytes());
    crafted.extend_from_slice(&2u32.to_le_bytes());
    crafted.extend_from_slice(&1u32.to_le_bytes());
    crafted.extend_from_slice(&1u32.to_le_bytes()); // name len
    crafted.push(b'X');
    crafted.extend_from_slice(&0i32.to_le_bytes());
    crafted.extend_from_slice(&0i32.to_le_bytes());
    crafted.extend_from_slice(&2.5f32.to_le_bytes()); // opacity out of range
    crafted.extend_from_slice(&999u32.to_le_bytes()); // unknown blend
    crafted.push(1);
    crafted.extend_from_slice(&(png.len() as u32).to_le_bytes());
    crafted.extend_from_slice(&png);
    let hpath = dir.path().join("crafted.rzdc");
    std::fs::write(&hpath, &crafted).unwrap();
    let hc = cpath(&hpath);
    let mut err: *mut c_char = ptr::null_mut();
    let lenient = unsafe { rz_doc_open(hc.as_ptr(), &mut err) };
    assert!(
        !lenient.is_null(),
        "lenient open failed: {}",
        take_err_string(err)
    );
    assert_eq!(unsafe { rz_doc_layer_count(lenient) }, 1);
    assert_eq!(layer_name(lenient, 0), "X");
    assert_eq!(unsafe { rz_doc_layer_opacity(lenient, 0) }, 1.0);
    assert_eq!(unsafe { rz_doc_layer_blend_mode(lenient, 0) }, BLEND_NORMAL);
    unsafe { rz_doc_free(lenient) };
}

#[test]
fn rzdc_rejects_absurd_canvas_dims() {
    let dir = TempDir::new().unwrap();
    let mut png = Vec::new();
    solid(1, 1, [1, 2, 3, 255])
        .write_to(&mut std::io::Cursor::new(&mut png), image::ImageFormat::Png)
        .unwrap();
    // Well-formed file whose header declares a 100000x100000 canvas (1e10
    // pixels) holding one 1x1 layer: the reader must reject the canvas size
    // instead of trusting it.
    let mut crafted = Vec::new();
    crafted.extend_from_slice(b"RZDC");
    crafted.extend_from_slice(&1u32.to_le_bytes()); // version
    crafted.extend_from_slice(&100_000u32.to_le_bytes()); // width
    crafted.extend_from_slice(&100_000u32.to_le_bytes()); // height
    crafted.extend_from_slice(&1u32.to_le_bytes()); // layer count
    crafted.extend_from_slice(&1u32.to_le_bytes()); // name len
    crafted.push(b'X');
    crafted.extend_from_slice(&0i32.to_le_bytes());
    crafted.extend_from_slice(&0i32.to_le_bytes());
    crafted.extend_from_slice(&1.0f32.to_le_bytes());
    crafted.extend_from_slice(&0u32.to_le_bytes()); // blend
    crafted.push(1); // visible
    crafted.extend_from_slice(&(png.len() as u32).to_le_bytes());
    crafted.extend_from_slice(&png);
    let path = dir.path().join("huge-canvas.rzdc");
    std::fs::write(&path, &crafted).unwrap();
    let c = cpath(&path);
    let mut err: *mut c_char = ptr::null_mut();
    let p = unsafe { rz_doc_open(c.as_ptr(), &mut err) };
    assert!(p.is_null(), "absurd canvas dims must not open");
    let msg = take_err_string(err);
    assert!(
        msg.contains("invalid canvas size"),
        "unexpected error: {msg}"
    );
}

#[test]
fn rzdc_save_enforces_reader_caps() {
    let dir = TempDir::new().unwrap();

    // A layer name longer than the 64 KiB reader cap still saves; the name is
    // truncated on a char boundary and round-trips. 64 KiB is not a multiple
    // of 3, so a name of 3-byte chars forces the boundary adjustment.
    const NAME_CAP: usize = 64 * 1024;
    let long_name = "层".repeat(NAME_CAP / 3 + 10);
    assert!(long_name.len() > NAME_CAP);
    let doc = doc_from(&dir, "caps.png", &solid(3, 3, [7, 8, 9, 255]));
    let cname = CString::new(long_name.clone()).unwrap();
    let doc = apply(doc, |d| unsafe {
        rz_doc_with_layer_name(d, 0, cname.as_ptr())
    });
    let path = dir.path().join("longname.rzdc");
    let c = cpath(&path);
    let mut err: *mut c_char = ptr::null_mut();
    assert!(
        unsafe { rz_doc_save_native(doc, c.as_ptr(), &mut err) },
        "save with over-long name failed: {}",
        take_err_string(err)
    );
    unsafe { rz_doc_free(doc) };
    let mut err: *mut c_char = ptr::null_mut();
    let reopened = unsafe { rz_doc_open(c.as_ptr(), &mut err) };
    assert!(
        !reopened.is_null(),
        "reopen failed: {}",
        take_err_string(err)
    );
    let got = layer_name(reopened, 0);
    assert_eq!(got, "层".repeat(NAME_CAP / 3), "truncated at char boundary");
    assert!(long_name.starts_with(&got));
    unsafe { rz_doc_free(reopened) };

    // Layer count: exactly 1024 layers saves, 1025 is refused with an error.
    let mut big = doc_from(&dir, "many.png", &solid(2, 2, [1, 1, 1, 255]));
    let lname = CString::new("L").unwrap();
    for _ in 0..1023 {
        big = apply(big, |d| unsafe {
            rz_doc_adding_layer(d, 0, lname.as_ptr())
        });
    }
    assert_eq!(unsafe { rz_doc_layer_count(big) }, 1024);
    let at_cap = dir.path().join("at-cap.rzdc");
    let ac = cpath(&at_cap);
    let mut err: *mut c_char = ptr::null_mut();
    assert!(
        unsafe { rz_doc_save_native(big, ac.as_ptr(), &mut err) },
        "1024 layers must save: {}",
        take_err_string(err)
    );
    big = apply(big, |d| unsafe {
        rz_doc_adding_layer(d, 0, lname.as_ptr())
    });
    let over_cap = dir.path().join("over-cap.rzdc");
    let oc = cpath(&over_cap);
    let mut err: *mut c_char = ptr::null_mut();
    assert!(
        !unsafe { rz_doc_save_native(big, oc.as_ptr(), &mut err) },
        "1025 layers must not save"
    );
    assert!(!take_err_string(err).is_empty());
    assert!(!over_cap.exists(), "failed save must not create the file");
    unsafe { rz_doc_free(big) };
}

#[test]
fn rzdc_failed_save_leaves_no_temp_files() {
    use std::os::unix::fs::PermissionsExt;
    let dir = TempDir::new().unwrap();
    let doc = rzdc_fixture(&dir);

    // Nonexistent directory.
    let bad = CString::new("/nonexistent-dir-xyz-rasterize/doc.rzdc").unwrap();
    let mut err: *mut c_char = ptr::null_mut();
    let ok = unsafe { rz_doc_save_native(doc, bad.as_ptr(), &mut err) };
    assert!(!ok);
    assert!(!take_err_string(err).is_empty());

    // Read-only directory: creation of the temp file fails and nothing is
    // left behind.
    let ro = dir.path().join("ro");
    std::fs::create_dir(&ro).unwrap();
    std::fs::set_permissions(&ro, std::fs::Permissions::from_mode(0o555)).unwrap();
    let target = cpath(&ro.join("doc.rzdc"));
    let mut err: *mut c_char = ptr::null_mut();
    let ok = unsafe { rz_doc_save_native(doc, target.as_ptr(), &mut err) };
    std::fs::set_permissions(&ro, std::fs::Permissions::from_mode(0o755)).unwrap();
    if !ok {
        assert!(!take_err_string(err).is_empty());
    }
    let leftovers: Vec<_> = std::fs::read_dir(&ro)
        .unwrap()
        .filter_map(|e| e.ok())
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .filter(|n| n.contains("rz-tmp"))
        .collect();
    assert!(
        leftovers.is_empty(),
        "temp files left behind: {leftovers:?}"
    );
    unsafe { rz_doc_free(doc) };
}

// --------------------------------------------------------------------- psd --

/// Generates a real two-layer PSD with ImageMagick, or None (with a log line)
/// if that is impossible, so the suite skips gracefully.
///
/// Recipe notes (verified against ImageMagick 7.1.2):
/// - When writing a multi-image PSD, image 0 becomes the merged composite and
///   the remaining images become the layers, so a composite is prepended with
///   `-clone 0,1 -flatten -insert 0` to get TWO real layers.
/// - `-endian MSB` is required: without it this ImageMagick writes the layer
///   blend-mode keys byte-reversed ("mron" instead of "norm"), which the psd
///   crate rejects.
fn layered_psd_fixture(dir: &TempDir) -> Option<PathBuf> {
    let magick = Path::new("/opt/homebrew/bin/magick");
    if !magick.exists() {
        eprintln!("skipping PSD assertions: {} not found", magick.display());
        return None;
    }
    let path = dir.path().join("layered.psd");
    let status = Command::new(magick)
        .args([
            "-size",
            "40x30",
            "xc:#3060c0",
            "(",
            "-size",
            "20x10",
            "xc:#e04040",
            "-repage",
            "+8+6",
            ")",
            "(",
            "-clone",
            "0,1",
            "-flatten",
            ")",
            "-insert",
            "0",
            "-depth",
            "8",
            "-endian",
            "MSB",
        ])
        .arg(&path)
        .status();
    match status {
        Ok(s) if s.success() && path.exists() => Some(path),
        other => {
            eprintln!("skipping PSD assertions: magick failed: {other:?}");
            None
        }
    }
}

#[test]
fn psd_layered_import() {
    let dir = TempDir::new().unwrap();
    let Some(path) = layered_psd_fixture(&dir) else {
        return;
    };
    let c = cpath(&path);
    let mut err: *mut c_char = ptr::null_mut();
    let doc = unsafe { rz_doc_open(c.as_ptr(), &mut err) };
    assert!(!doc.is_null(), "PSD open failed: {}", take_err_string(err));
    assert_eq!(unsafe { (rz_doc_width(doc), rz_doc_height(doc)) }, (40, 30));
    assert_eq!(unsafe { rz_doc_layer_count(doc) }, 2, "expected two layers");

    // Bottom layer: canvas-sized blue; top layer: 20x10 red at (8, 6).
    assert_eq!(layer_dims(doc, 0), (40, 30));
    assert_eq!(layer_offset(doc, 0), (0, 0));
    let bottom = layer_pixels(doc, 0);
    let blue = pixel(&bottom, 40, 5, 5);
    assert!(
        blue[2] >= 150 && blue[0] <= 100 && blue[3] == 255,
        "bottom layer not blue: {blue:?}"
    );
    assert!(!layer_name(doc, 0).is_empty());

    assert_eq!(
        layer_dims(doc, 1),
        (20, 10),
        "top layer must keep its own size"
    );
    assert_eq!(
        layer_offset(doc, 1),
        (8, 6),
        "top layer offset from PSD rect"
    );
    let top = layer_pixels(doc, 1);
    let red = pixel(&top, 20, 0, 0);
    assert!(
        red[0] >= 180 && red[2] <= 100 && red[3] == 255,
        "top layer not red: {red:?}"
    );
    assert!(!layer_name(doc, 1).is_empty());
    // ImageMagick marks both layers shown; opacity 255 -> 1.0; blend normal.
    for idx in 0..2usize {
        assert!(
            unsafe { rz_doc_layer_visible(doc, idx) },
            "layer {idx} hidden"
        );
        assert_eq!(unsafe { rz_doc_layer_opacity(doc, idx) }, 1.0);
        assert_eq!(unsafe { rz_doc_layer_blend_mode(doc, idx) }, BLEND_NORMAL);
    }

    // The projection matches the file: red rectangle at (8,6)-(28,16) over
    // blue.
    let flat = flat_pixels(doc);
    for (x, y, want_red) in [
        (0u32, 0u32, false),
        (7, 6, false),
        (8, 6, true),
        (20, 10, true),
        (27, 15, true),
        (28, 16, false),
        (39, 29, false),
    ] {
        let px = pixel(&flat, 40, x, y);
        if want_red {
            assert!(
                px[0] >= 180 && px[2] <= 100,
                "({x},{y}) should be red: {px:?}"
            );
        } else {
            assert!(
                px[2] >= 150 && px[0] <= 100,
                "({x},{y}) should be blue: {px:?}"
            );
        }
    }

    // ... and stays close to ImageMagick's own composite of the same file.
    let composite_png = dir.path().join("composite.png");
    let status = Command::new("/opt/homebrew/bin/magick")
        .arg(format!("{}[0]", path.display()))
        .arg(&composite_png)
        .status();
    if matches!(status, Ok(s) if s.success()) {
        let magick_flat = image::open(&composite_png).unwrap().to_rgba8();
        assert_eq!(magick_flat.dimensions(), (40, 30));
        for (i, (&a, &b)) in flat.iter().zip(magick_flat.as_raw().iter()).enumerate() {
            assert!(
                (i32::from(a) - i32::from(b)).abs() <= 2,
                "byte {i}: flattened {a} vs magick composite {b}"
            );
        }
    }

    // The flat open path on the same layered file keeps working.
    let mut err: *mut c_char = ptr::null_mut();
    let img = unsafe { rz_image_open(c.as_ptr(), &mut err) };
    assert!(
        !img.is_null(),
        "rz_image_open on PSD failed: {}",
        take_err_string(err)
    );
    assert_eq!(img_dims(img), (40, 30));
    unsafe { rz_image_free(img) };
    unsafe { rz_doc_free(doc) };

    // A single-image PSD still opens as a one-layer document whose
    // projection matches the rz_image_open decode. (This ImageMagick writes
    // one real layer record even for a single image — named "L1", not our
    // "Background" fallback — so only the count and pixels are asserted.)
    let flat_psd = dir.path().join("flat.psd");
    let status = Command::new("/opt/homebrew/bin/magick")
        .args(["-size", "32x24", "gradient:red-blue", "-depth", "8"])
        .arg(&flat_psd)
        .status();
    if matches!(status, Ok(s) if s.success()) {
        let fc = cpath(&flat_psd);
        let mut err: *mut c_char = ptr::null_mut();
        let fdoc = unsafe { rz_doc_open(fc.as_ptr(), &mut err) };
        assert!(
            !fdoc.is_null(),
            "flat PSD open failed: {}",
            take_err_string(err)
        );
        assert_eq!(unsafe { rz_doc_layer_count(fdoc) }, 1);
        assert!(!layer_name(fdoc, 0).is_empty());
        let mut err: *mut c_char = ptr::null_mut();
        let fimg = unsafe { rz_image_open(fc.as_ptr(), &mut err) };
        assert!(!fimg.is_null());
        assert_eq!(flat_pixels(fdoc), img_pixels(fimg));
        unsafe { rz_image_free(fimg) };
        unsafe { rz_doc_free(fdoc) };
    }
}

// ------------------------------------------------------------- null safety --

#[test]
fn null_safety_sweep() {
    let null_doc: *const RzDocument = ptr::null();
    let null_img: *const RzImage = ptr::null();
    let name = CString::new("x").unwrap();
    let overlay = [0u8; 16];

    unsafe {
        // Open/save.
        let mut err: *mut c_char = ptr::null_mut();
        assert!(rz_doc_open(ptr::null(), &mut err).is_null());
        assert!(!take_err_string(err).is_empty());
        assert!(rz_doc_open(ptr::null(), ptr::null_mut()).is_null());
        let path = CString::new("/tmp/never-created.rzdc").unwrap();
        let mut err: *mut c_char = ptr::null_mut();
        assert!(!rz_doc_save_native(null_doc, path.as_ptr(), &mut err));
        assert!(!take_err_string(err).is_empty());
        assert!(!rz_doc_save_native(
            null_doc,
            path.as_ptr(),
            ptr::null_mut()
        ));

        // Lifetime and getters.
        assert!(rz_doc_from_image(null_img).is_null());
        assert!(rz_doc_clone(null_doc).is_null());
        rz_doc_free(ptr::null_mut());
        assert_eq!(rz_doc_width(null_doc), 0);
        assert_eq!(rz_doc_height(null_doc), 0);
        assert_eq!(rz_doc_layer_count(null_doc), 0);
        assert!(rz_doc_layer_name(null_doc, 0).is_null());
        assert_eq!(rz_doc_layer_opacity(null_doc, 0), 0.0);
        assert_eq!(rz_doc_layer_blend_mode(null_doc, 0), BLEND_NORMAL);
        assert!(!rz_doc_layer_visible(null_doc, 0));
        assert_eq!(rz_doc_layer_offset_x(null_doc, 0), 0);
        assert_eq!(rz_doc_layer_offset_y(null_doc, 0), 0);
        assert_eq!(rz_doc_layer_width(null_doc, 0), 0);
        assert_eq!(rz_doc_layer_height(null_doc, 0), 0);
        assert!(rz_doc_layer_image(null_doc, 0).is_null());
        assert!(rz_doc_layer_thumbnail(null_doc, 0, 16).is_null());
        assert!(rz_doc_flattened(null_doc).is_null());

        // Setters and stack operations.
        assert!(rz_doc_with_layer_name(null_doc, 0, name.as_ptr()).is_null());
        assert!(rz_doc_with_layer_opacity(null_doc, 0, 1.0).is_null());
        assert!(rz_doc_with_layer_blend_mode(null_doc, 0, BLEND_NORMAL).is_null());
        assert!(rz_doc_with_layer_visible(null_doc, 0, true).is_null());
        assert!(rz_doc_with_layer_offset(null_doc, 0, 0, 0).is_null());
        assert!(rz_doc_with_layer_pixels(null_doc, 0, null_img).is_null());
        assert!(rz_doc_adding_layer(null_doc, 0, name.as_ptr()).is_null());
        assert!(rz_doc_adding_image_layer(null_doc, 0, null_img, name.as_ptr()).is_null());
        assert!(rz_doc_duplicating_layer(null_doc, 0).is_null());
        assert!(rz_doc_removing_layer(null_doc, 0).is_null());
        assert!(rz_doc_moving_layer(null_doc, 0, 0).is_null());
        assert!(rz_doc_merging_down(null_doc, 1).is_null());
        assert!(rz_doc_flattening(null_doc).is_null());
        assert!(
            rz_doc_painting_layer(null_doc, 0, overlay.as_ptr(), 2, 2, COMPOSITE_OVER, 1.0)
                .is_null()
        );

        // Geometry.
        assert!(rz_doc_rotate90(null_doc).is_null());
        assert!(rz_doc_rotate180(null_doc).is_null());
        assert!(rz_doc_rotate270(null_doc).is_null());
        assert!(rz_doc_flip_horizontal(null_doc).is_null());
        assert!(rz_doc_flip_vertical(null_doc).is_null());
        assert!(rz_doc_crop(null_doc, 0, 0, 1, 1).is_null());
        assert!(rz_doc_resize(null_doc, 1, 1, FILTER_NEAREST).is_null());
        let identity = [1.0f64, 0.0, 0.0, 1.0, 0.0, 0.0];
        assert!(rz_doc_transform_layer(null_doc, 0, identity.as_ptr(), FILTER_NEAREST).is_null());
        assert!(rz_doc_transform_layer(null_doc, 0, ptr::null(), FILTER_NEAREST).is_null());
    }

    // NULL name / NULL image arguments on a valid doc.
    let dir = TempDir::new().unwrap();
    let doc = doc_from(&dir, "n.png", &solid(2, 2, [1, 2, 3, 255]));
    unsafe {
        assert!(rz_doc_with_layer_name(doc, 0, ptr::null()).is_null());
        assert!(rz_doc_adding_layer(doc, 0, ptr::null()).is_null());
        assert!(rz_doc_adding_image_layer(doc, 0, null_img, name.as_ptr()).is_null());
        assert!(rz_doc_adding_image_layer(doc, 0, ptr::null(), ptr::null()).is_null());
        assert!(rz_doc_with_layer_pixels(doc, 0, null_img).is_null());
        assert!(rz_doc_transform_layer(doc, 0, ptr::null(), FILTER_NEAREST).is_null());
        let mut err: *mut c_char = ptr::null_mut();
        assert!(!rz_doc_save_native(doc, ptr::null(), &mut err));
        assert!(!take_err_string(err).is_empty());
    }
    unsafe { rz_doc_free(doc) };
}

#[test]
fn canvas_resize_shifts_offsets_without_scaling() {
    let dir = TempDir::new().unwrap();
    let doc = geometry_fixture(&dir, "canvas", (1, 1));
    let layer_before = layer_pixels(doc, 1);
    let flat = unsafe { rz_doc_flattened(doc) };

    // Grow from 7x5 to 11x9 anchored at the center: old origin lands at
    // (2, 2); layer dims and pixels unchanged.
    let grown = unsafe { rz_doc_canvas_resize(doc, 11, 9, 2, 2) };
    assert!(!grown.is_null());
    assert_eq!(
        unsafe { (rz_doc_width(grown), rz_doc_height(grown)) },
        (11, 9)
    );
    assert_eq!(layer_offset(grown, 0), (2, 2));
    assert_eq!(layer_offset(grown, 1), (3, 3));
    assert_eq!(layer_dims(grown, 1), (3, 2));
    assert_eq!(
        layer_pixels(grown, 1),
        layer_before,
        "canvas resize must not touch pixels"
    );
    // The old projection appears verbatim inside the grown projection.
    let grown_flat = unsafe { rz_doc_flattened(grown) };
    let window = unsafe { rz_image_crop(grown_flat, 2, 2, 7, 5) };
    assert!(!window.is_null());
    assert_eq!(img_pixels(window), img_pixels(flat));
    unsafe { rz_image_free(window) };
    unsafe { rz_image_free(grown_flat) };
    unsafe { rz_doc_free(grown) };

    // Shrinking with a negative origin is exactly a crop of the same window.
    let shrunk = unsafe { rz_doc_canvas_resize(doc, 4, 3, -2, -1) };
    let cropped = unsafe { rz_doc_crop(doc, 2, 1, 4, 3) };
    assert!(!shrunk.is_null() && !cropped.is_null());
    assert_eq!(layer_offset(shrunk, 0), layer_offset(cropped, 0));
    assert_eq!(layer_offset(shrunk, 1), layer_offset(cropped, 1));
    assert_eq!(flat_pixels(shrunk), flat_pixels(cropped));
    unsafe { rz_doc_free(cropped) };
    unsafe { rz_doc_free(shrunk) };

    // Guards: zero dims, over-limit canvas, NULL doc.
    unsafe {
        assert!(rz_doc_canvas_resize(doc, 0, 5, 0, 0).is_null());
        assert!(rz_doc_canvas_resize(doc, 5, 0, 0, 0).is_null());
        assert!(rz_doc_canvas_resize(doc, 10_001, 10_000, 0, 0).is_null());
        assert!(rz_doc_canvas_resize(std::ptr::null(), 5, 5, 0, 0).is_null());
    }

    unsafe { rz_image_free(flat) };
    unsafe { rz_doc_free(doc) };
}

// -------------------------------------------------- selection & fill ops --

/// Builds a 6x4 doc: left half solid red, right half solid blue.
fn two_tone_doc(dir: &TempDir) -> *mut RzDocument {
    let mut img = RgbaImage::new(6, 4);
    for (x, _, px) in img.enumerate_pixels_mut() {
        *px = if x < 3 {
            Rgba([200, 0, 0, 255])
        } else {
            Rgba([0, 0, 200, 255])
        };
    }
    doc_from(dir, "twotone.png", &img)
}

fn wand(doc: *const RzDocument, x: u32, y: u32, tol: u8, contiguous: bool) -> Vec<u8> {
    let (w, h) = unsafe { (rz_doc_width(doc), rz_doc_height(doc)) };
    let mut mask = vec![0u8; (w * h) as usize];
    let ok = unsafe { rz_doc_magic_wand(doc, x, y, tol, contiguous, mask.as_mut_ptr()) };
    assert!(ok, "magic_wand({x},{y}) failed");
    mask
}

#[test]
fn magic_wand_contiguous_and_global() {
    let dir = TempDir::new().unwrap();
    let doc = two_tone_doc(&dir);

    // Seed in the red half selects exactly the 3x4 red block.
    let mask = wand(doc, 0, 0, 0, true);
    assert_eq!(mask.iter().filter(|&&m| m == 255).count(), 12);
    assert_eq!(mask[0], 255); // top-left red
    assert_eq!(mask[5], 0); // top-right blue

    // Two disconnected red pixels at the far corner: contiguous excludes,
    // global includes.
    let mut img = RgbaImage::new(6, 4);
    for (x, _, px) in img.enumerate_pixels_mut() {
        *px = if x < 3 {
            Rgba([200, 0, 0, 255])
        } else {
            Rgba([0, 0, 200, 255])
        };
    }
    img.put_pixel(5, 3, Rgba([200, 0, 0, 255]));
    let doc2 = doc_from(&dir, "twotone2.png", &img);
    let contiguous = wand(doc2, 0, 0, 0, true);
    assert_eq!(contiguous[3 * 6 + 5], 0);
    let global = wand(doc2, 0, 0, 0, false);
    assert_eq!(global[3 * 6 + 5], 255);

    // Tolerance: 200-diff needs tolerance >= 200 to swallow both halves.
    let loose = wand(doc, 0, 0, 200, true);
    assert_eq!(loose.iter().filter(|&&m| m == 255).count(), 24);

    // Out-of-canvas seed fails.
    let mut mask = vec![0u8; 24];
    assert!(!unsafe { rz_doc_magic_wand(doc, 99, 0, 0, true, mask.as_mut_ptr()) });

    unsafe { rz_doc_free(doc) };
    unsafe { rz_doc_free(doc2) };
}

#[test]
fn bucket_fill_region_mask_and_blend() {
    let dir = TempDir::new().unwrap();
    let doc = two_tone_doc(&dir);

    // Opaque green fill clicked in the blue half replaces exactly it.
    let green = [0u8, 255, 0, 255];
    let filled = apply(doc, |d| unsafe {
        rz_doc_bucket_fill(d, 0, 5, 0, 0, green.as_ptr(), true, ptr::null())
    });
    let px = layer_pixels(filled, 0);
    assert_eq!(&px[0..4], &[200, 0, 0, 255]); // red untouched
    assert_eq!(&px[5 * 4..5 * 4 + 4], &[0, 255, 0, 255]); // blue -> green

    // A mask covering only the top row halves the fill's reach; 50%
    // coverage scales the paint.
    let mut mask = vec![0u8; 24];
    for m in mask.iter_mut().take(6) {
        *m = 128;
    }
    let masked = apply(filled, |d| unsafe {
        rz_doc_bucket_fill(d, 0, 0, 0, 0, green.as_ptr(), true, mask.as_ptr())
    });
    let px = layer_pixels(masked, 0);
    // Top-left red got ~50% green blended over it.
    assert!(
        px[1] > 100 && px[1] < 160,
        "half-coverage green, got {}",
        px[1]
    );
    // Second row red untouched (mask 0).
    assert_eq!(&px[6 * 4..6 * 4 + 4], &[200, 0, 0, 255]);

    // Click outside the mask fails.
    let out =
        unsafe { rz_doc_bucket_fill(masked, 0, 0, 2, 0, green.as_ptr(), true, mask.as_ptr()) };
    assert!(out.is_null());

    unsafe { rz_doc_free(masked) };
}

#[test]
fn gradient_linear_radial_and_offsets() {
    let dir = TempDir::new().unwrap();
    // Transparent 10x1 canvas: gradient endpoints land exactly.
    let img = RgbaImage::new(10, 1);
    let doc = doc_from(&dir, "empty.png", &img);
    let black = [0u8, 0, 0, 255];
    let white = [255u8, 255, 255, 255];

    let out = apply(doc, |d| unsafe {
        rz_doc_gradient(
            d,
            0,
            0.0,
            0.5,
            10.0,
            0.5,
            black.as_ptr(),
            white.as_ptr(),
            0,
            ptr::null(),
        )
    });
    let px = layer_pixels(out, 0);
    assert!(px[0 * 4] <= 13, "left end near black, got {}", px[0]);
    assert!(px[9 * 4] >= 242, "right end near white, got {}", px[9 * 4]);
    let mid = px[5 * 4];
    assert!((110..=160).contains(&mid), "midpoint mid-gray, got {mid}");

    // Radial: center black, edge white.
    let img2 = RgbaImage::new(9, 9);
    let doc2 = doc_from(&dir, "empty2.png", &img2);
    let out2 = apply(doc2, |d| unsafe {
        rz_doc_gradient(
            d,
            0,
            4.5,
            4.5,
            8.5,
            4.5,
            black.as_ptr(),
            white.as_ptr(),
            1,
            ptr::null(),
        )
    });
    let px2 = layer_pixels(out2, 0);
    let center = px2[(4 * 9 + 4) * 4];
    let corner_right = px2[(4 * 9 + 8) * 4];
    assert!(center <= 13, "radial center black, got {center}");
    assert!(corner_right >= 242, "radial edge white, got {corner_right}");

    // Degenerate p0 == p1 fails.
    let bad = unsafe {
        rz_doc_gradient(
            out2,
            0,
            1.0,
            1.0,
            1.0,
            1.0,
            black.as_ptr(),
            white.as_ptr(),
            0,
            ptr::null(),
        )
    };
    assert!(bad.is_null());

    // Offset layer: gradient coordinates are canvas coordinates.
    let stripe = RgbaImage::new(4, 1);
    let mut doc3 = doc_from(&dir, "empty3.png", &RgbaImage::new(10, 1));
    doc3 = add_layer(&dir, "stripe.png", doc3, 0, &stripe, "S");
    doc3 = apply(doc3, |d| unsafe { rz_doc_with_layer_offset(d, 1, 6, 0) });
    let out3 = apply(doc3, |d| unsafe {
        rz_doc_gradient(
            d,
            1,
            0.0,
            0.5,
            10.0,
            0.5,
            black.as_ptr(),
            white.as_ptr(),
            0,
            ptr::null(),
        )
    });
    // The stripe sits at canvas x 6..10, so its own first pixel is ~65%.
    let px3 = layer_pixels(out3, 1);
    assert!(
        px3[0] > 140,
        "offset layer samples canvas-space t, got {}",
        px3[0]
    );

    unsafe { rz_doc_free(out) };
    unsafe { rz_doc_free(out2) };
    unsafe { rz_doc_free(out3) };
}

// ---------------------------------------------------- selection feather --

/// w*h mask, 255 inside the half-open rect [x0, x1) x [y0, y1), 0 outside.
fn rect_mask(w: u32, h: u32, x0: u32, y0: u32, x1: u32, y1: u32) -> Vec<u8> {
    let mut mask = vec![0u8; (w * h) as usize];
    for y in y0..y1 {
        for x in x0..x1 {
            mask[(y * w + x) as usize] = 255;
        }
    }
    mask
}

#[test]
fn feather_softens_rect_boundary_only() {
    let (w, h) = (24u32, 24u32);
    let mut mask = rect_mask(w, h, 6, 6, 18, 18);
    assert!(unsafe { rz_selection_feather(mask.as_mut_ptr(), w, h, 2.0) });
    let at = |x: u32, y: u32| mask[(y * w + x) as usize];

    // Deep inside stays fully selected; far outside stays empty.
    assert_eq!(at(12, 12), 255);
    assert_eq!(at(0, 0), 0);
    assert_eq!(at(23, 23), 0);

    // The formerly hard edge is now a ramp: intermediate coverage on both
    // sides of the boundary, decreasing outward.
    let inside_edge = at(6, 12);
    let outside_edge = at(5, 12);
    assert!(
        inside_edge > 0 && inside_edge < 255,
        "inside boundary pixel intermediate, got {inside_edge}"
    );
    assert!(
        outside_edge > 0 && outside_edge < 255,
        "outside boundary pixel intermediate, got {outside_edge}"
    );
    assert!(inside_edge > outside_edge);
}

#[test]
fn feather_symmetric_input_stays_symmetric() {
    let (w, h) = (20u32, 20u32);
    let mut mask = rect_mask(w, h, 5, 5, 15, 15);
    feather_mask(&mut mask, w, h, 3.0);
    let at = |x: u32, y: u32| mask[(y * w + x) as usize];
    for y in 0..h {
        for x in 0..w {
            assert_eq!(at(x, y), at(w - 1 - x, y), "mirror x at ({x},{y})");
            assert_eq!(at(x, y), at(x, h - 1 - y), "mirror y at ({x},{y})");
            assert_eq!(at(x, y), at(y, x), "transpose at ({x},{y})");
        }
    }
}

#[test]
fn feather_clamps_at_canvas_edges() {
    // A fully selected canvas must stay fully selected: clamp-to-edge
    // sampling means nothing bleeds in from outside the canvas.
    let (w, h) = (9u32, 7u32);
    let mut mask = vec![255u8; (w * h) as usize];
    feather_mask(&mut mask, w, h, 4.0);
    assert!(mask.iter().all(|&v| v == 255), "edges faded: {mask:?}");
}

#[test]
fn feather_zero_radius_is_identity() {
    let (w, h) = (16u32, 12u32);
    let original = rect_mask(w, h, 3, 2, 9, 11);
    let mut mask = original.clone();
    feather_mask(&mut mask, w, h, 0.0);
    assert_eq!(mask, original);

    // Negative radius is also a no-op, and still succeeds over the FFI.
    assert!(unsafe { rz_selection_feather(mask.as_mut_ptr(), w, h, -3.0) });
    assert_eq!(mask, original);
}

#[test]
fn feather_rejects_null_zero_size_and_non_finite() {
    let mut mask = vec![0u8; 4];
    assert!(!unsafe { rz_selection_feather(ptr::null_mut(), 2, 2, 1.0) });
    assert!(!unsafe { rz_selection_feather(mask.as_mut_ptr(), 0, 2, 1.0) });
    assert!(!unsafe { rz_selection_feather(mask.as_mut_ptr(), 2, 0, 1.0) });
    assert!(!unsafe { rz_selection_feather(mask.as_mut_ptr(), 2, 2, f32::NAN) });
    assert!(!unsafe { rz_selection_feather(mask.as_mut_ptr(), 2, 2, f32::INFINITY) });
    assert_eq!(mask, vec![0u8; 4]);
}

// -------------------------------------------------------------- layer masks --
//
// The model's own semantics, driven through the safe Rust API on
// `RzDocument`; the `rz_doc_*_mask` entry points that wrap it get their own
// section at the end of this file.

const RED: [u8; 4] = [255, 0, 0, 255];
const BLUE: [u8; 4] = [0, 0, 255, 255];

/// Opaque red canvas-sized background under an opaque blue layer of size
/// `layer` placed at `offset` (layer index 1).
fn mask_fixture(canvas: (u32, u32), layer: (u32, u32), offset: (i32, i32)) -> RzDocument {
    let doc = RzDocument::from_pixels(solid(canvas.0, canvas.1, RED));
    let doc = doc
        .adding_image_layer(0, solid(layer.0, layer.1, BLUE), "Top")
        .expect("add layer");
    doc.with_layer_offset(1, offset.0, offset.1)
        .expect("set offset")
}

/// Canvas-sized selection buffer from a per-pixel function.
fn selection(w: u32, h: u32, f: impl Fn(u32, u32) -> u8) -> Vec<u8> {
    let mut out = Vec::with_capacity((w * h) as usize);
    for y in 0..h {
        for x in 0..w {
            out.push(f(x, y));
        }
    }
    out
}

/// Normal-mode source-over of an opaque source onto an opaque backdrop at
/// effective alpha `sa`, quantized exactly like the compositor.
fn over_opaque(bg: [u8; 4], src: [u8; 4], sa: f32) -> [u8; 4] {
    let mut out = [0u8; 4];
    for c in 0..3 {
        let v = sa * f32::from(src[c]) / 255.0 + (1.0 - sa) * f32::from(bg[c]) / 255.0;
        out[c] = (v.clamp(0.0, 1.0) * 255.0).round() as u8;
    }
    out[3] = 255;
    out
}

/// The mask bytes of layer `idx`, row-major.
fn mask_bytes(doc: &RzDocument, idx: usize) -> Vec<u8> {
    doc.layers[idx]
        .mask
        .as_ref()
        .expect("layer has a mask")
        .as_raw()
        .clone()
}

fn flat(doc: &RzDocument, x: u32, y: u32) -> [u8; 4] {
    doc.flattened().get_pixel(x, y).0
}

#[test]
fn mask_gates_layer_coverage() {
    // 4x2 canvas, full-canvas blue layer, mask columns 0/0/128/255.
    let doc = mask_fixture((4, 2), (4, 2), (0, 0));
    let sel = selection(4, 2, |x, _| match x {
        2 => 128,
        3 => 255,
        _ => 0,
    });
    let masked = doc
        .add_mask(1, MaskKind::FromSelection(&sel))
        .expect("mask");
    assert_eq!(mask_bytes(&masked, 1), sel, "mask copies the selection 1:1");

    for y in 0..2 {
        assert_eq!(flat(&masked, 0, y), RED, "hidden half shows the backdrop");
        assert_eq!(flat(&masked, 1, y), RED, "hidden half shows the backdrop");
        assert_eq!(
            flat(&masked, 2, y),
            over_opaque(RED, BLUE, 128.0 / 255.0),
            "intermediate mask value is partial coverage"
        );
        assert_eq!(flat(&masked, 3, y), BLUE, "revealed half shows the layer");
    }
    // Adding a mask replaces any earlier one.
    let hidden = masked.add_mask(1, MaskKind::HideAll).expect("hide all");
    assert_eq!(mask_bytes(&hidden, 1), vec![0u8; 8]);
    assert!(hidden.layers[1].mask_enabled);
    for x in 0..4 {
        assert_eq!(flat(&hidden, x, 0), RED, "hide-all mask hides everything");
    }
    let shown = hidden.add_mask(1, MaskKind::RevealAll).expect("reveal all");
    assert_eq!(mask_bytes(&shown, 1), vec![255u8; 8]);
    assert_eq!(flat(&shown, 0, 0), BLUE, "reveal-all mask changes nothing");

    // A canvas-sized selection is required.
    assert!(doc
        .add_mask(1, MaskKind::FromSelection(&sel[..7]))
        .is_none());
    assert!(doc.add_mask(9, MaskKind::RevealAll).is_none());
}

#[test]
fn disabled_mask_composites_like_no_mask() {
    // Non-trivial layer properties so the comparison covers the whole kernel.
    let plain = mask_fixture((4, 2), (4, 2), (0, 0));
    let plain = plain.with_layer_opacity(1, 0.6).unwrap();
    let plain = plain
        .with_layer_blend_mode(1, rasterize_core::doc::BlendMode::Multiply)
        .unwrap();
    let sel = selection(4, 2, |x, _| if x < 2 { 0 } else { 200 });
    let masked = plain.add_mask(1, MaskKind::FromSelection(&sel)).unwrap();
    assert_ne!(
        masked.flattened().into_raw(),
        plain.flattened().into_raw(),
        "the enabled mask must change the projection"
    );

    let disabled = masked.set_mask_enabled(1, false).expect("disable");
    assert!(!disabled.layers[1].mask_enabled);
    assert!(disabled.layers[1].mask.is_some(), "mask is retained");
    assert_eq!(
        disabled.flattened().into_raw(),
        plain.flattened().into_raw(),
        "a disabled mask composites exactly like no mask at all"
    );
    // Re-enabling restores the masked projection.
    let reenabled = disabled.set_mask_enabled(1, true).unwrap();
    assert_eq!(
        reenabled.flattened().into_raw(),
        masked.flattened().into_raw()
    );
    // No mask: nothing to enable.
    assert!(plain.set_mask_enabled(1, false).is_none());
    assert!(plain.set_mask_enabled(9, true).is_none());
}

#[test]
fn mask_and_layer_opacity_multiply() {
    let doc = mask_fixture((3, 1), (3, 1), (0, 0));
    let doc = doc.with_layer_opacity(1, 0.5).unwrap();
    let sel = selection(3, 1, |x, _| [0, 128, 255][x as usize]);
    let masked = doc.add_mask(1, MaskKind::FromSelection(&sel)).unwrap();
    for (x, cov) in [0u8, 128, 255].into_iter().enumerate() {
        let sa = f32::from(cov) / 255.0 * 0.5;
        assert_eq!(
            flat(&masked, x as u32, 0),
            over_opaque(RED, BLUE, sa),
            "coverage {cov} times opacity 0.5"
        );
    }
}

#[test]
fn add_mask_from_selection_crops_to_the_layer_rect() {
    // 5x3 canvas; a 4x2 layer at (-1, 1) hangs off the left edge and its
    // bottom row sits on the canvas' last row.
    let doc = mask_fixture((5, 3), (4, 2), (-1, 1));
    // Distinctive per-canvas-pixel values so a mis-mapping cannot pass.
    let sel = selection(5, 3, |x, y| (x * 10 + y + 1) as u8);
    let masked = doc.add_mask(1, MaskKind::FromSelection(&sel)).unwrap();
    let mask = mask_bytes(&masked, 1);
    assert_eq!(mask.len(), 4 * 2, "mask is exactly the layer's size");
    for ly in 0..2u32 {
        for lx in 0..4u32 {
            let cx = lx as i64 - 1;
            let cy = ly as i64 + 1;
            let expected = if cx < 0 || cx >= 5 || cy >= 3 {
                0
            } else {
                sel[cy as usize * 5 + cx as usize]
            };
            assert_eq!(
                mask[(ly * 4 + lx) as usize],
                expected,
                "layer pixel ({lx},{ly}) -> canvas ({cx},{cy})"
            );
        }
    }
    // Column 0 is off-canvas, so it is hidden; the rest follows the selection.
    assert_eq!(mask[0], 0);
    assert_eq!(mask[1], sel[5], "layer (1,0) -> canvas (0,1)");
}

#[test]
fn remove_mask_applies_or_discards() {
    let doc = mask_fixture((4, 2), (4, 2), (0, 0));
    let sel = selection(4, 2, |x, _| (x * 85) as u8);
    let masked = doc.add_mask(1, MaskKind::FromSelection(&sel)).unwrap();
    let masked_flat = masked.flattened().into_raw();

    // apply: the coverage is baked into the layer's alpha and the projection
    // is byte-identical to the masked one.
    let applied = masked.remove_mask(1, true).expect("apply");
    assert!(applied.layers[1].mask.is_none());
    assert!(applied.layers[1].mask_enabled);
    for (i, &cov) in sel.iter().enumerate() {
        assert_eq!(
            applied.layers[1].pixels.as_raw()[i * 4 + 3],
            cov,
            "alpha {i} baked from coverage"
        );
    }
    assert_eq!(
        applied.flattened().into_raw(),
        masked_flat,
        "applying a mask must not change the projection"
    );

    // apply also bakes a DISABLED mask (the flag only affects compositing).
    let disabled = masked.set_mask_enabled(1, false).unwrap();
    let applied_disabled = disabled.remove_mask(1, true).expect("apply disabled");
    assert_eq!(
        applied_disabled.layers[1].pixels.as_raw(),
        applied.layers[1].pixels.as_raw()
    );

    // no apply: the layer is revealed in full again.
    let dropped = masked.remove_mask(1, false).expect("drop");
    assert!(dropped.layers[1].mask.is_none());
    assert_eq!(
        dropped.flattened().into_raw(),
        doc.flattened().into_raw(),
        "dropping a mask reveals the layer"
    );
    assert_eq!(
        dropped.layers[1].pixels.as_raw(),
        doc.layers[1].pixels.as_raw(),
        "dropping must not touch pixels"
    );

    // No mask, nothing to remove.
    assert!(doc.remove_mask(1, true).is_none());
    assert!(doc.remove_mask(9, false).is_none());
}

#[test]
fn paint_mask_lerps_overlay_luma_by_alpha() {
    // 5x2 canvas, 4x2 layer at (1, 0): mask row 0 starts hidden, row 1 shown.
    let doc = mask_fixture((5, 2), (4, 2), (1, 0));
    let sel = selection(5, 2, |_, y| if y == 0 { 0 } else { 255 });
    let masked = doc.add_mask(1, MaskKind::FromSelection(&sel)).unwrap();
    assert_eq!(mask_bytes(&masked, 1), vec![0, 0, 0, 0, 255, 255, 255, 255]);

    // Canvas-frame PREMULTIPLIED overlay, one behavior per canvas column:
    // 0 opaque white (outside the layer), 1 opaque white, 2 half black,
    // 3 transparent, 4 half white.
    let mut overlay = vec![0u8; 5 * 2 * 4];
    for y in 0..2usize {
        for (x, px) in [
            [255u8, 255, 255, 255],
            [255, 255, 255, 255],
            [0, 0, 0, 128],
            [0, 0, 0, 0],
            [128, 128, 128, 128],
        ]
        .into_iter()
        .enumerate()
        {
            let i = (y * 5 + x) * 4;
            overlay[i..i + 4].copy_from_slice(&px);
        }
    }
    let painted = masked.paint_mask(1, &overlay).expect("paint");
    assert_eq!(
        mask_bytes(&painted, 1),
        vec![
            // row 0, from 0: white reveals, half black stays, transparent
            // keeps, half white lands mid-way.
            255, 0, 0, 128, // row 1, from 255: white keeps, half black lands
            // mid-way, transparent keeps, half white keeps.
            255, 127, 255, 255,
        ]
    );

    // The revealed footprint is exactly what the flattened image shows.
    assert_eq!(flat(&painted, 1, 0), BLUE, "painted white reveals");
    assert_eq!(flat(&painted, 2, 0), RED, "unpainted stays hidden");
    assert_eq!(
        flat(&painted, 3, 0),
        RED,
        "transparent overlay changes nothing"
    );
    assert_eq!(
        flat(&painted, 4, 0),
        over_opaque(RED, BLUE, 128.0 / 255.0),
        "half-alpha white is half coverage"
    );
    assert_eq!(
        flat(&painted, 2, 1),
        over_opaque(RED, BLUE, 127.0 / 255.0),
        "half-alpha black halves an already-revealed pixel"
    );

    // Painting an opaque white overlay over a hide-all mask reveals exactly
    // the painted footprint and nothing else.
    let hidden = doc.add_mask(1, MaskKind::HideAll).unwrap();
    let mut stroke = vec![0u8; 5 * 2 * 4];
    let i = 2 * 4; // canvas (2, 0) -> layer (1, 0)
    stroke[i..i + 4].copy_from_slice(&[255, 255, 255, 255]);
    let stroked = hidden.paint_mask(1, &stroke).expect("stroke");
    assert_eq!(mask_bytes(&stroked, 1), vec![0, 255, 0, 0, 0, 0, 0, 0]);
    assert_eq!(flat(&stroked, 2, 0), BLUE);
    assert_eq!(flat(&stroked, 1, 0), RED);

    // Guards: no mask, wrong buffer size, layer entirely off-canvas.
    assert!(doc.paint_mask(1, &overlay).is_none());
    assert!(masked.paint_mask(1, &overlay[..39]).is_none());
    assert!(masked.paint_mask(9, &overlay).is_none());
    let off = masked.with_layer_offset(1, 50, 50).unwrap();
    assert!(off.paint_mask(1, &overlay).is_none());
}

#[test]
fn mask_image_is_opaque_grayscale() {
    let doc = mask_fixture((3, 1), (3, 1), (0, 0));
    let sel = selection(3, 1, |x, _| [0, 128, 255][x as usize]);
    let masked = doc.add_mask(1, MaskKind::FromSelection(&sel)).unwrap();
    let img = masked.mask_image(1).expect("mask image");
    assert_eq!(img.dimensions(), (3, 1));
    assert_eq!(img.get_pixel(0, 0).0, [0, 0, 0, 255]);
    assert_eq!(img.get_pixel(1, 0).0, [128, 128, 128, 255]);
    assert_eq!(img.get_pixel(2, 0).0, [255, 255, 255, 255]);
    assert!(doc.mask_image(1).is_none(), "no mask, no image");
    assert!(masked.mask_image(9).is_none());
}

#[test]
fn duplicating_layer_copies_mask_enabled_and_meta() {
    let doc = mask_fixture((4, 2), (4, 2), (1, 0));
    let sel = selection(4, 2, |x, y| (x + y * 4) as u8);
    let mut masked = doc.add_mask(1, MaskKind::FromSelection(&sel)).unwrap();
    masked = masked.set_mask_enabled(1, false).unwrap();
    masked.layers[1].meta = Some("{\"type\":\"text\",\"string\":\"hi\"}".to_string());

    let dup = masked.duplicating_layer(1).expect("duplicate");
    assert_eq!(dup.layers.len(), 3);
    assert_eq!(dup.layers[2].name, "Top copy");
    assert_eq!(mask_bytes(&dup, 2), mask_bytes(&masked, 1));
    assert!(!dup.layers[2].mask_enabled, "enabled flag copies");
    assert_eq!(dup.layers[2].meta, masked.layers[1].meta, "meta copies");
}

#[test]
fn masks_follow_layer_geometry_and_scaling() {
    let doc = mask_fixture((4, 2), (4, 2), (0, 0));
    let sel = selection(4, 2, |x, y| if x == 0 && y == 0 { 255 } else { 0 });
    let masked = doc.add_mask(1, MaskKind::FromSelection(&sel)).unwrap();

    // Rotating the document rotates the mask with the pixels, so the mask
    // keeps the layer's dimensions and the projection commutes.
    let rotated = masked.rotate90();
    assert_eq!(
        rotated.layers[1].mask.as_ref().unwrap().dimensions(),
        (2, 4)
    );
    assert_eq!(
        rotated.flattened().into_raw(),
        image::imageops::rotate90(&masked.flattened()).into_raw(),
        "rotate90 must commute with the masked projection"
    );
    let flipped = masked.flip_horizontal();
    assert_eq!(mask_bytes(&flipped, 1), vec![0, 0, 0, 255, 0, 0, 0, 0]);

    // Scaling scales the mask alongside the pixels.
    let resized = masked
        .resize(8, 4, image::imageops::FilterType::Nearest)
        .unwrap();
    let mask = resized.layers[1].mask.as_ref().unwrap();
    assert_eq!(mask.dimensions(), (8, 4));
    assert_eq!(mask.get_pixel(0, 0).0[0], 255);
    assert_eq!(mask.get_pixel(7, 3).0[0], 0);

    // Replacing the pixels with a differently sized buffer drops the mask
    // rather than leaving a mismatched one behind.
    let same = masked.with_layer_pixels(1, solid(4, 2, BLUE)).unwrap();
    assert!(same.layers[1].mask.is_some(), "same size keeps the mask");
    let smaller = masked.with_layer_pixels(1, solid(2, 1, BLUE)).unwrap();
    assert!(smaller.layers[1].mask.is_none(), "resize drops the mask");

    // Merging down bakes an enabled mask into the pixels and drops it.
    let merged = masked.merging_down(1).expect("merge");
    assert_eq!(merged.layers.len(), 1);
    assert!(merged.layers[0].mask.is_none());
    assert_eq!(
        merged.flattened().into_raw(),
        masked.flattened().into_raw(),
        "merging a masked layer preserves the projection"
    );
}

#[test]
fn rzdc_round_trips_masks_and_meta() {
    let dir = TempDir::new().unwrap();
    let doc = mask_fixture((5, 3), (4, 2), (-1, 1));
    // Layer 1: a disabled mask plus meta. Layer 2: an enabled mask.
    let sel = selection(5, 3, |x, y| (x * 17 + y * 3) as u8);
    let mut doc = doc.add_mask(1, MaskKind::FromSelection(&sel)).unwrap();
    doc = doc.set_mask_enabled(1, false).unwrap();
    doc.layers[1].meta = Some("{\"type\":\"text\",\"string\":\"héllo 层\"}".to_string());
    let doc = doc
        .adding_image_layer(1, solid(3, 3, [10, 200, 30, 128]), "Top2")
        .unwrap();
    let doc = doc.add_mask(2, MaskKind::HideAll).unwrap();
    let doc = doc.add_mask(2, MaskKind::FromSelection(&sel)).unwrap();

    let path = dir.path().join("masked.rzdc");
    let spath = path.to_str().unwrap().to_string();
    doc.save_native(&spath).expect("save");
    let bytes = std::fs::read(&path).unwrap();
    assert_eq!(&bytes[..4], b"RZDC");
    assert_eq!(
        u32::from_le_bytes(bytes[4..8].try_into().unwrap()),
        2,
        "masks and layer meta bump the format to version 2"
    );

    let back = RzDocument::open(&spath).expect("reopen");
    assert_eq!(back.layers.len(), 3);
    assert!(
        back.layers[0].mask.is_none(),
        "unmasked layer stays unmasked"
    );
    assert!(back.layers[0].mask_enabled);
    assert_eq!(back.layers[0].meta, None);
    for idx in [1usize, 2] {
        assert_eq!(
            mask_bytes(&back, idx),
            mask_bytes(&doc, idx),
            "layer {idx} mask"
        );
        assert_eq!(
            back.layers[idx].mask_enabled, doc.layers[idx].mask_enabled,
            "layer {idx} mask_enabled"
        );
        assert_eq!(
            back.layers[idx].meta, doc.layers[idx].meta,
            "layer {idx} meta"
        );
    }
    assert!(!back.layers[1].mask_enabled);
    assert!(back.layers[2].mask_enabled);
    assert_eq!(
        back.flattened().into_raw(),
        doc.flattened().into_raw(),
        "projection survives the round trip"
    );

    // Saving the reopened document reproduces the file byte for byte.
    let again = dir.path().join("again.rzdc");
    back.save_native(again.to_str().unwrap()).expect("resave");
    assert_eq!(std::fs::read(&again).unwrap(), bytes);
}

#[test]
fn rzdc_version_1_files_still_load_without_masks() {
    let dir = TempDir::new().unwrap();
    let mut png = Vec::new();
    solid(2, 2, [1, 2, 3, 255])
        .write_to(&mut std::io::Cursor::new(&mut png), image::ImageFormat::Png)
        .unwrap();
    // A hand-built version-1 file: the layer record ends after the PNG.
    let mut v1 = Vec::new();
    v1.extend_from_slice(b"RZDC");
    v1.extend_from_slice(&1u32.to_le_bytes()); // version
    v1.extend_from_slice(&2u32.to_le_bytes()); // width
    v1.extend_from_slice(&2u32.to_le_bytes()); // height
    v1.extend_from_slice(&1u32.to_le_bytes()); // layer count
    v1.extend_from_slice(&3u32.to_le_bytes()); // name len
    v1.extend_from_slice(b"Old");
    v1.extend_from_slice(&0i32.to_le_bytes());
    v1.extend_from_slice(&0i32.to_le_bytes());
    v1.extend_from_slice(&1.0f32.to_le_bytes());
    v1.extend_from_slice(&0u32.to_le_bytes()); // blend
    v1.push(1); // visible
    v1.extend_from_slice(&(png.len() as u32).to_le_bytes());
    v1.extend_from_slice(&png);
    let path = dir.path().join("v1.rzdc");
    std::fs::write(&path, &v1).unwrap();

    let doc = RzDocument::open(path.to_str().unwrap()).expect("version 1 must still load");
    assert_eq!(doc.layers.len(), 1);
    assert_eq!(doc.layers[0].name, "Old");
    assert!(doc.layers[0].mask.is_none(), "version 1 has no masks");
    assert!(doc.layers[0].mask_enabled, "enabled defaults to true");
    assert_eq!(doc.layers[0].meta, None, "version 1 has no meta");

    // A future version is refused by number.
    let mut v3 = v1.clone();
    v3[4..8].copy_from_slice(&3u32.to_le_bytes());
    let future = dir.path().join("v3.rzdc");
    std::fs::write(&future, &v3).unwrap();
    let err = RzDocument::open(future.to_str().unwrap())
        .err()
        .expect("a future version must be refused");
    assert!(err.contains("unsupported RZDC version 3"), "got: {err}");

    // A version-2 file whose mask length disagrees with the layer's pixel
    // count is rejected instead of trusted.
    let mut bad = v1.clone();
    bad[4..8].copy_from_slice(&2u32.to_le_bytes());
    bad.push(1); // mask present
    bad.push(1); // mask enabled
    bad.extend_from_slice(&3u32.to_le_bytes()); // 3 bytes for a 2x2 layer
    bad.extend_from_slice(&[255, 255, 255]);
    bad.push(0); // no meta
    let bad_path = dir.path().join("bad-mask.rzdc");
    std::fs::write(&bad_path, &bad).unwrap();
    let err = RzDocument::open(bad_path.to_str().unwrap())
        .err()
        .expect("a mismatched mask length must be refused");
    assert!(err.contains("mask length"), "got: {err}");
}

// ------------------------------ masks & meta across every remaining path --
//
// Completeness pass over the paths that move a layer, change the canvas, or
// rebuild the stack. Two things are checked everywhere: the hard invariant
// (a mask is always exactly its layer's pixel size) and ALIGNMENT — the mask
// must go on hiding the same visible pixels, which only a comparison against
// the projection can show.

const GREEN: [u8; 4] = [0, 200, 0, 255];
const WHITE: [u8; 4] = [255, 255, 255, 255];
const META: &str = "{\"type\":\"text\",\"string\":\"keep me\"}";

/// Asserts the hard invariant on every layer of `doc`.
fn assert_mask_invariant(doc: &RzDocument, what: &str) {
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
fn checkerboard_masked(canvas: (u32, u32), layer: (u32, u32), offset: (i32, i32)) -> RzDocument {
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

/// Runs the canvas-frame paint path over a safe document. `painting_layer`
/// is crate-private, so the FFI entry point is the only way in from here.
fn paint_over(doc: &RzDocument, idx: usize, overlay: &[u8]) -> RzDocument {
    let handle = Box::into_raw(Box::new(doc.clone()));
    let out = unsafe {
        rz_doc_painting_layer(
            handle,
            idx,
            overlay.as_ptr(),
            doc.width,
            doc.height,
            COMPOSITE_OVER,
            1.0,
        )
    };
    unsafe { rz_doc_free(handle) };
    assert!(!out.is_null(), "painting_layer must succeed");
    *unsafe { Box::from_raw(out) }
}

#[test]
fn crop_keeps_the_mask_aligned_with_its_layer() {
    // 6x4 canvas, 4x3 blue layer at (1, 1) over a red background.
    let doc = checkerboard_masked((6, 4), (4, 3), (1, 1));
    let before = doc.flattened();
    let mask_before = mask_bytes(&doc, 1);

    // Crop only moves the canvas window: pixels, mask and meta ride along
    // with the layer, so every surviving canvas pixel looks identical.
    let cropped = doc.crop(1, 1, 4, 3).expect("crop");
    assert_mask_invariant(&cropped, "crop");
    assert_eq!((cropped.width, cropped.height), (4, 3));
    assert_eq!(cropped.layers[1].offset, (0, 0));
    assert_eq!(cropped.layers[0].offset, (-1, -1));
    assert_eq!(
        mask_bytes(&cropped, 1),
        mask_before,
        "the mask is layer-space, so a window move must not touch it"
    );
    assert!(cropped.layers[1].mask_enabled);
    assert_eq!(cropped.layers[1].meta.as_deref(), Some(META));
    let after = cropped.flattened();
    for y in 0..3 {
        for x in 0..4 {
            assert_eq!(
                after.get_pixel(x, y).0,
                before.get_pixel(x + 1, y + 1).0,
                "cropped ({x},{y}) must hide/show exactly what it did before"
            );
        }
    }

    // A crop that leaves the masked layer entirely outside the window still
    // keeps a consistent mask (the layer is merely off-canvas now).
    let away = doc.crop(0, 0, 1, 1).expect("corner crop");
    assert_mask_invariant(&away, "crop to a corner");
    assert_eq!(mask_bytes(&away, 1), mask_before);
}

#[test]
fn canvas_resize_grow_and_shrink_keep_the_mask_aligned() {
    let doc = checkerboard_masked((6, 4), (4, 3), (1, 1));
    let before = doc.flattened();
    let mask_before = mask_bytes(&doc, 1);

    // Grow with the old canvas anchored at (2, 3) in the new one.
    let grown = doc.canvas_resize(10, 8, (2, 3)).expect("grow");
    assert_mask_invariant(&grown, "canvas grow");
    assert_eq!((grown.width, grown.height), (10, 8));
    assert_eq!(grown.layers[1].offset, (3, 4));
    assert_eq!(mask_bytes(&grown, 1), mask_before, "growing moves nothing");
    assert_eq!(grown.layers[1].meta.as_deref(), Some(META));
    let after = grown.flattened();
    for y in 0..8 {
        for x in 0..10 {
            let inside = (2..8).contains(&x) && (3..7).contains(&y);
            let expected = if inside {
                before.get_pixel(x - 2, y - 3).0
            } else {
                [0, 0, 0, 0]
            };
            assert_eq!(
                after.get_pixel(x, y).0,
                expected,
                "grown ({x},{y}) must match the anchored old canvas"
            );
        }
    }

    // Shrink around the same content: a negative origin, i.e. exactly a crop.
    let shrunk = doc.canvas_resize(3, 2, (-2, -1)).expect("shrink");
    assert_mask_invariant(&shrunk, "canvas shrink");
    assert_eq!((shrunk.width, shrunk.height), (3, 2));
    assert_eq!(shrunk.layers[1].offset, (-1, 0));
    assert_eq!(
        mask_bytes(&shrunk, 1),
        mask_before,
        "shrinking moves nothing"
    );
    let after = shrunk.flattened();
    for y in 0..2 {
        for x in 0..3 {
            assert_eq!(
                after.get_pixel(x, y).0,
                before.get_pixel(x + 2, y + 1).0,
                "shrunk ({x},{y}) must hide/show exactly what it did before"
            );
        }
    }
    assert_eq!(
        after.into_raw(),
        doc.crop(2, 1, 3, 2).unwrap().flattened().into_raw(),
        "a shrink with a negative origin is the matching crop, masks included"
    );
}

#[test]
fn whole_document_transforms_preserve_meta_and_the_invariant() {
    let doc = checkerboard_masked((6, 4), (4, 3), (1, 1));
    let variants = [
        ("rotate90", doc.rotate90()),
        ("rotate180", doc.rotate180()),
        ("rotate270", doc.rotate270()),
        ("flip_horizontal", doc.flip_horizontal()),
        ("flip_vertical", doc.flip_vertical()),
        ("crop", doc.crop(1, 1, 4, 3).expect("crop")),
        (
            "canvas_resize",
            doc.canvas_resize(9, 7, (2, 2)).expect("canvas resize"),
        ),
        (
            "resize",
            doc.resize(12, 8, image::imageops::FilterType::Nearest)
                .expect("resize"),
        ),
        (
            // A scale whose per-layer rounding is not exact: pixels and mask
            // must round to the SAME dimensions, not merely to close ones.
            "resize (fractional)",
            doc.resize(7, 5, image::imageops::FilterType::Triangle)
                .expect("fractional resize"),
        ),
    ];
    for (name, out) in variants {
        assert_mask_invariant(&out, name);
        assert!(out.layers[1].mask.is_some(), "{name} must keep the mask");
        assert!(
            out.layers[1].mask_enabled,
            "{name} must keep the enabled flag"
        );
        assert_eq!(
            out.layers[1].meta.as_deref(),
            Some(META),
            "{name} must keep the layer's meta"
        );
    }

    // Chaining them cannot drift either.
    let chained = doc
        .rotate90()
        .crop(0, 1, 4, 4)
        .expect("crop the rotated canvas")
        .resize(3, 3, image::imageops::FilterType::Nearest)
        .expect("resize the cropped canvas");
    assert_mask_invariant(&chained, "rotate90 -> crop -> resize");

    // A downscale that collapses the layer to a single pixel clamps pixels
    // and mask to the same 1x1, not to different sizes.
    let tiny = doc
        .resize(1, 1, image::imageops::FilterType::Nearest)
        .expect("collapse");
    assert_mask_invariant(&tiny, "collapse to 1x1");
    assert_eq!(tiny.layers[1].pixels.dimensions(), (1, 1));
}

#[test]
fn flattening_bakes_enabled_masks_and_drops_them() {
    // Background red; a masked blue layer; a half-opaque green layer whose
    // mask is DISABLED (so it must not be baked); a hidden masked layer.
    let doc = checkerboard_masked((4, 2), (3, 2), (1, 0));
    let doc = doc
        .adding_image_layer(1, solid(4, 2, GREEN), "Green")
        .unwrap();
    let doc = doc.with_layer_opacity(2, 0.5).unwrap();
    let doc = doc.add_mask(2, MaskKind::HideAll).unwrap();
    let doc = doc.set_mask_enabled(2, false).unwrap();
    let doc = doc
        .adding_image_layer(2, solid(4, 2, WHITE), "Hidden")
        .unwrap();
    let doc = doc.with_layer_visible(3, false).unwrap();
    let mut doc = doc.add_mask(3, MaskKind::RevealAll).unwrap();
    doc.layers[3].meta = Some(META.to_string());
    let projection = doc.flattened();

    let flat = doc.flattening();
    assert_mask_invariant(&flat, "flattening");
    assert_eq!(flat.layers.len(), 1);
    assert_eq!((flat.width, flat.height), (4, 2));
    assert_eq!(flat.layers[0].name, "Background");
    assert_eq!(flat.layers[0].offset, (0, 0));
    assert_eq!(flat.layers[0].pixels.dimensions(), (4, 2));
    assert!(
        flat.layers[0].mask.is_none(),
        "the composite has no mask left to apply"
    );
    assert!(
        flat.layers[0].mask_enabled,
        "the flag resets to the default"
    );
    assert_eq!(
        flat.layers[0].meta, None,
        "meta cannot describe a composite"
    );
    assert_eq!(
        flat.layers[0].pixels.as_raw(),
        projection.as_raw(),
        "the single layer IS the projection, enabled masks baked in"
    );
    assert_eq!(
        flat.flattened().into_raw(),
        projection.into_raw(),
        "flattening must not change what the document looks like"
    );

    // The enabled mask really participated: dropping it first changes the
    // result, so the equality above is not vacuous.
    let unmasked = doc.remove_mask(1, false).unwrap();
    assert_ne!(
        unmasked.flattening().layers[0].pixels.as_raw(),
        flat.layers[0].pixels.as_raw(),
        "the blue layer's enabled mask must affect the flattened pixels"
    );
}

#[test]
fn fill_gradient_and_paint_keep_the_layer_mask() {
    // 4x2 canvas and layer: columns 0-1 hidden by the mask, 2-3 revealed.
    let doc = mask_fixture((4, 2), (4, 2), (0, 0));
    let sel = selection(4, 2, |x, _| if x < 2 { 0 } else { 255 });
    let masked = doc.add_mask(1, MaskKind::FromSelection(&sel)).unwrap();
    let mask_before = mask_bytes(&masked, 1);

    // Bucket fill replaces the layer's pixels at the same size: the mask
    // survives and still gates exactly the same columns.
    let filled = masked
        .bucket_fill(1, 3, 0, 0, GREEN, true, None)
        .expect("bucket fill");
    assert_mask_invariant(&filled, "bucket_fill");
    assert_eq!(mask_bytes(&filled, 1), mask_before, "fill keeps the mask");
    assert!(filled.layers[1].mask_enabled);
    assert_eq!(
        filled.layers[1].pixels.get_pixel(0, 0).0,
        GREEN,
        "the fill itself is not gated by the mask, only the projection is"
    );
    for y in 0..2 {
        assert_eq!(flat(&filled, 0, y), RED, "hidden column shows the backdrop");
        assert_eq!(flat(&filled, 1, y), RED, "hidden column shows the backdrop");
        assert_eq!(flat(&filled, 2, y), GREEN, "revealed column shows the fill");
        assert_eq!(flat(&filled, 3, y), GREEN, "revealed column shows the fill");
    }

    // Gradients take the same same-size replacement path.
    let graded = masked
        .gradient(1, (0.0, 0.0), (4.0, 0.0), GREEN, WHITE, false, None)
        .expect("gradient");
    assert_mask_invariant(&graded, "gradient");
    assert_eq!(
        mask_bytes(&graded, 1),
        mask_before,
        "gradient keeps the mask"
    );
    for y in 0..2 {
        assert_eq!(flat(&graded, 0, y), RED, "hidden column shows the backdrop");
        assert_ne!(flat(&graded, 3, y), RED, "revealed column shows the ramp");
    }

    // So does the canvas-frame paint overlay (opaque white everywhere).
    let overlay = vec![255u8; 4 * 2 * 4];
    let painted = paint_over(&masked, 1, &overlay);
    assert_mask_invariant(&painted, "painting_layer");
    assert_eq!(mask_bytes(&painted, 1), mask_before, "paint keeps the mask");
    for y in 0..2 {
        assert_eq!(flat(&painted, 0, y), RED, "hidden column stays hidden");
        assert_eq!(flat(&painted, 3, y), WHITE, "revealed column takes paint");
    }

    // A DISABLED mask is retained across the same paths, flag included.
    let disabled = masked.set_mask_enabled(1, false).unwrap();
    let filled = disabled
        .bucket_fill(1, 3, 0, 0, GREEN, true, None)
        .expect("bucket fill");
    assert_eq!(mask_bytes(&filled, 1), mask_before);
    assert!(!filled.layers[1].mask_enabled, "the disabled flag survives");
}

#[test]
fn stack_ops_carry_masks_and_meta_with_their_layer() {
    let doc = checkerboard_masked((4, 2), (4, 2), (0, 0));
    let doc = doc.set_mask_enabled(1, false).expect("disable");
    let mask = mask_bytes(&doc, 1);

    // Inserting a fresh transparent layer below the masked one: the new layer
    // arrives unmasked, the masked one just shifts index.
    let added = doc.adding_layer(0, "New").expect("add layer");
    assert_mask_invariant(&added, "adding_layer");
    assert_eq!(added.layers.len(), 3);
    assert!(added.layers[1].mask.is_none(), "a new layer has no mask");
    assert_eq!(added.layers[1].meta, None, "a new layer has no meta");
    assert_eq!(mask_bytes(&added, 2), mask);
    assert!(!added.layers[2].mask_enabled);
    assert_eq!(added.layers[2].meta.as_deref(), Some(META));

    // Pasting pixels as a new layer above the masked one: same story.
    let pasted = doc
        .adding_image_layer(1, solid(2, 2, GREEN), "Pasted")
        .expect("paste layer");
    assert_mask_invariant(&pasted, "adding_image_layer");
    assert!(
        pasted.layers[2].mask.is_none(),
        "pasted layers are unmasked"
    );
    assert_eq!(pasted.layers[2].meta, None);
    assert_eq!(
        mask_bytes(&pasted, 1),
        mask,
        "the masked layer is untouched"
    );

    // Reordering and removal move the whole layer, mask and meta included.
    let moved = doc.moving_layer(1, 0).expect("reorder");
    assert_mask_invariant(&moved, "moving_layer");
    assert_eq!(mask_bytes(&moved, 0), mask);
    assert!(!moved.layers[0].mask_enabled);
    assert_eq!(moved.layers[0].meta.as_deref(), Some(META));

    let removed = doc.removing_layer(0).expect("remove the background");
    assert_mask_invariant(&removed, "removing_layer");
    assert_eq!(removed.layers.len(), 1);
    assert_eq!(mask_bytes(&removed, 0), mask);
    assert_eq!(removed.layers[0].meta.as_deref(), Some(META));
}

#[test]
fn merge_down_with_a_hidden_upper_keeps_the_lower_mask() {
    // An invisible upper layer contributes nothing, so the lower layer is not
    // rewritten and keeps its mask, its enabled flag and its meta.
    let doc = checkerboard_masked((4, 2), (4, 2), (0, 0));
    let doc = doc
        .adding_image_layer(1, solid(4, 2, GREEN), "Hidden")
        .unwrap();
    let doc = doc.with_layer_visible(2, false).unwrap();

    let merged = doc.merging_down(2).expect("merge a hidden upper");
    assert_mask_invariant(&merged, "merging_down with a hidden upper");
    assert_eq!(merged.layers.len(), 2);
    assert_eq!(mask_bytes(&merged, 1), mask_bytes(&doc, 1));
    assert!(merged.layers[1].mask_enabled);
    assert_eq!(merged.layers[1].meta.as_deref(), Some(META));
    assert_eq!(
        merged.flattened().into_raw(),
        doc.flattened().into_raw(),
        "dropping an invisible layer cannot change the projection"
    );
}

// -------------------------------------------------------- layer masks (FFI) --
//
// The same operations through the C entry points: handle lifetimes, the
// mask-kind mapping, buffer validation and the two queries.

/// The FFI twin of `mask_fixture`: an opaque red canvas-sized background under
/// an opaque blue layer of size `layer` placed at `offset` (layer index 1).
fn ffi_mask_fixture(
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
fn ffi_mask_bytes(doc: *const RzDocument, idx: usize) -> Vec<u8> {
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
fn ffi_mask_flags(doc: *const RzDocument, idx: usize) -> (bool, bool) {
    unsafe {
        (
            rz_doc_layer_has_mask(doc, idx),
            rz_doc_layer_mask_enabled(doc, idx),
        )
    }
}

#[test]
fn ffi_adding_layer_mask_kinds_queries_and_projection() {
    let dir = TempDir::new().unwrap();
    let doc = ffi_mask_fixture(&dir, "kinds", (4, 2), (4, 2), (0, 0));
    let unmasked_flat = flat_pixels(doc);
    assert_eq!(ffi_mask_flags(doc, 1), (false, false), "no mask to start");
    assert!(
        unsafe { rz_doc_layer_mask_image(doc, 1) }.is_null(),
        "no mask, no mask image"
    );

    // Reveal-all: present and enabled, projection unchanged.
    let reveal = unsafe { rz_doc_adding_layer_mask(doc, 1, MASK_REVEAL_ALL, ptr::null(), 0, 0) };
    assert!(!reveal.is_null());
    assert_eq!(ffi_mask_flags(reveal, 1), (true, true));
    assert_eq!(ffi_mask_bytes(reveal, 1), vec![255u8; 8]);
    assert_eq!(
        flat_pixels(reveal),
        unmasked_flat,
        "a reveal-all mask changes nothing"
    );
    assert_eq!(
        ffi_mask_flags(doc, 1),
        (false, false),
        "the operation is pure: the input document is untouched"
    );

    // Hide-all: the backdrop shows everywhere.
    let hide = unsafe { rz_doc_adding_layer_mask(doc, 1, MASK_HIDE_ALL, ptr::null(), 0, 0) };
    assert!(!hide.is_null());
    assert_eq!(ffi_mask_bytes(hide, 1), vec![0u8; 8]);
    let flat = flat_pixels(hide);
    for x in 0..4 {
        assert_eq!(pixel(&flat, 4, x, 0), RED, "hide-all shows the backdrop");
    }

    // From-selection: columns 0/0/128/255 gate the layer's coverage.
    let sel = selection(4, 2, |x, _| match x {
        2 => 128,
        3 => 255,
        _ => 0,
    });
    let from_sel =
        unsafe { rz_doc_adding_layer_mask(doc, 1, MASK_FROM_SELECTION, sel.as_ptr(), 4, 2) };
    assert!(!from_sel.is_null());
    assert_eq!(
        ffi_mask_bytes(from_sel, 1),
        sel,
        "a canvas-sized layer copies the selection 1:1"
    );
    assert_eq!(ffi_mask_flags(from_sel, 1), (true, true));
    let flat = flat_pixels(from_sel);
    for y in 0..2 {
        assert_eq!(pixel(&flat, 4, 0, y), RED, "hidden column");
        assert_eq!(
            pixel(&flat, 4, 2, y),
            over_opaque(RED, BLUE, 128.0 / 255.0),
            "an intermediate coverage value is partial coverage"
        );
        assert_eq!(pixel(&flat, 4, 3, y), BLUE, "revealed column");
    }

    // Adding a mask replaces any earlier one.
    let replaced = apply(unsafe { rz_doc_clone(from_sel) }, |d| unsafe {
        rz_doc_adding_layer_mask(d, 1, MASK_REVEAL_ALL, ptr::null(), 0, 0)
    });
    assert_eq!(ffi_mask_bytes(replaced, 1), vec![255u8; 8]);

    for d in [reveal, hide, from_sel, replaced, doc] {
        unsafe { rz_doc_free(d) };
    }
}

#[test]
fn ffi_adding_layer_mask_from_selection_crops_to_the_layer() {
    let dir = TempDir::new().unwrap();
    // 5x3 canvas; a 4x2 layer at (-1, 1) hangs off the left edge.
    let doc = ffi_mask_fixture(&dir, "crop", (5, 3), (4, 2), (-1, 1));
    // Distinctive per-canvas-pixel values so a mis-mapping cannot pass.
    let sel = selection(5, 3, |x, y| (x * 10 + y + 1) as u8);
    let masked =
        unsafe { rz_doc_adding_layer_mask(doc, 1, MASK_FROM_SELECTION, sel.as_ptr(), 5, 3) };
    assert!(!masked.is_null());
    let mask = ffi_mask_bytes(masked, 1);
    assert_eq!(mask.len(), 4 * 2, "the mask is exactly the layer's size");
    for ly in 0..2u32 {
        for lx in 0..4u32 {
            let cx = lx as i64 - 1;
            let cy = ly as i64 + 1;
            let expected = if cx < 0 {
                0
            } else {
                sel[cy as usize * 5 + cx as usize]
            };
            assert_eq!(
                mask[(ly * 4 + lx) as usize],
                expected,
                "layer pixel ({lx},{ly}) -> canvas ({cx},{cy})"
            );
        }
    }
    assert_eq!(mask[0], 0, "the off-canvas column is hidden");
    assert_eq!(mask[1], sel[5], "layer (1,0) -> canvas (0,1)");

    unsafe { rz_doc_free(masked) };
    unsafe { rz_doc_free(doc) };
}

#[test]
fn ffi_removing_layer_mask_applies_or_discards() {
    let dir = TempDir::new().unwrap();
    let doc = ffi_mask_fixture(&dir, "remove", (4, 2), (4, 2), (0, 0));
    let unmasked_flat = flat_pixels(doc);
    let unmasked_pixels = layer_pixels(doc, 1);
    let sel = selection(4, 2, |x, _| (x * 85) as u8);
    let masked =
        unsafe { rz_doc_adding_layer_mask(doc, 1, MASK_FROM_SELECTION, sel.as_ptr(), 4, 2) };
    assert!(!masked.is_null());
    let masked_flat = flat_pixels(masked);

    // apply: the coverage is baked into the layer's alpha and the projection
    // is byte-identical to the masked one.
    let applied = unsafe { rz_doc_removing_layer_mask(masked, 1, true) };
    assert!(!applied.is_null());
    assert_eq!(ffi_mask_flags(applied, 1), (false, false));
    assert!(unsafe { rz_doc_layer_mask_image(applied, 1) }.is_null());
    let baked = layer_pixels(applied, 1);
    for (i, &cov) in sel.iter().enumerate() {
        assert_eq!(baked[i * 4 + 3], cov, "alpha {i} baked from coverage");
    }
    assert_eq!(
        flat_pixels(applied),
        masked_flat,
        "applying a mask must not change the projection"
    );

    // A disabled mask composites like none at all, but apply still bakes it.
    let disabled = unsafe { rz_doc_with_layer_mask_enabled(masked, 1, false) };
    assert!(!disabled.is_null());
    assert_eq!(
        ffi_mask_flags(disabled, 1),
        (true, false),
        "the mask is retained, merely ignored"
    );
    assert_eq!(flat_pixels(disabled), unmasked_flat);
    let applied_disabled = unsafe { rz_doc_removing_layer_mask(disabled, 1, true) };
    assert!(!applied_disabled.is_null());
    assert_eq!(
        layer_pixels(applied_disabled, 1),
        baked,
        "apply bakes regardless of the enabled flag"
    );

    // No apply: pixels untouched, the layer is revealed in full again.
    let dropped = unsafe { rz_doc_removing_layer_mask(masked, 1, false) };
    assert!(!dropped.is_null());
    assert_eq!(ffi_mask_flags(dropped, 1), (false, false));
    assert_eq!(layer_pixels(dropped, 1), unmasked_pixels);
    assert_eq!(flat_pixels(dropped), unmasked_flat);

    // Re-enabling restores the masked projection.
    let reenabled = unsafe { rz_doc_with_layer_mask_enabled(disabled, 1, true) };
    assert!(!reenabled.is_null());
    assert_eq!(ffi_mask_flags(reenabled, 1), (true, true));
    assert_eq!(flat_pixels(reenabled), masked_flat);

    // Nothing to remove or toggle on a layer without a mask.
    unsafe {
        assert!(rz_doc_removing_layer_mask(dropped, 1, true).is_null());
        assert!(rz_doc_removing_layer_mask(dropped, 1, false).is_null());
        assert!(rz_doc_with_layer_mask_enabled(dropped, 1, false).is_null());
    }

    for d in [
        masked,
        applied,
        disabled,
        applied_disabled,
        dropped,
        reenabled,
        doc,
    ] {
        unsafe { rz_doc_free(d) };
    }
}

#[test]
fn ffi_painting_layer_mask_reveals_the_stroke() {
    let dir = TempDir::new().unwrap();
    // 5x2 canvas, 4x2 layer at (1, 0), starting fully hidden.
    let doc = ffi_mask_fixture(&dir, "paint", (5, 2), (4, 2), (1, 0));
    let hidden = unsafe { rz_doc_adding_layer_mask(doc, 1, MASK_HIDE_ALL, ptr::null(), 0, 0) };
    assert!(!hidden.is_null());

    // Canvas-frame PREMULTIPLIED overlay: opaque white at canvas (2, 0),
    // half-alpha white at (3, 1), transparent everywhere else.
    let mut overlay = vec![0u8; 5 * 2 * 4];
    let put = |buf: &mut Vec<u8>, x: usize, y: usize, px: [u8; 4]| {
        let i = (y * 5 + x) * 4;
        buf[i..i + 4].copy_from_slice(&px);
    };
    put(&mut overlay, 2, 0, [255, 255, 255, 255]);
    put(&mut overlay, 3, 1, [128, 128, 128, 128]);

    let painted = unsafe { rz_doc_painting_layer_mask(hidden, 1, overlay.as_ptr(), 5, 2) };
    assert!(!painted.is_null());
    assert_eq!(
        ffi_mask_bytes(painted, 1),
        // canvas (2,0) -> layer (1,0); canvas (3,1) -> layer (2,1).
        vec![0, 255, 0, 0, 0, 0, 128, 0],
        "white reveals in full, half alpha lands mid-way"
    );
    let flat = flat_pixels(painted);
    assert_eq!(pixel(&flat, 5, 2, 0), BLUE, "the painted pixel is revealed");
    assert_eq!(pixel(&flat, 5, 1, 0), RED, "the rest stays hidden");
    assert_eq!(
        pixel(&flat, 5, 3, 1),
        over_opaque(RED, BLUE, 128.0 / 255.0),
        "half alpha is half coverage"
    );
    assert_eq!(
        layer_pixels(painted, 1),
        layer_pixels(hidden, 1),
        "painting a mask never touches the layer's pixels"
    );

    // A wrongly sized overlay is REJECTED against the canvas, not read.
    unsafe {
        assert!(rz_doc_painting_layer_mask(hidden, 1, overlay.as_ptr(), 4, 2).is_null());
        assert!(rz_doc_painting_layer_mask(hidden, 1, overlay.as_ptr(), 5, 1).is_null());
        assert!(rz_doc_painting_layer_mask(hidden, 1, overlay.as_ptr(), 5, 3).is_null());
        assert!(rz_doc_painting_layer_mask(hidden, 1, overlay.as_ptr(), 0, 0).is_null());
        assert!(rz_doc_painting_layer_mask(hidden, 1, ptr::null(), 5, 2).is_null());
        assert!(
            rz_doc_painting_layer_mask(doc, 1, overlay.as_ptr(), 5, 2).is_null(),
            "no mask, nothing to paint"
        );
    }

    // A layer whose extent misses the canvas has no mask pixel to change.
    let away = apply(unsafe { rz_doc_clone(hidden) }, |d| unsafe {
        rz_doc_with_layer_offset(d, 1, 50, 50)
    });
    assert!(unsafe { rz_doc_painting_layer_mask(away, 1, overlay.as_ptr(), 5, 2) }.is_null());

    for d in [hidden, painted, away, doc] {
        unsafe { rz_doc_free(d) };
    }
}

#[test]
fn ffi_layer_image_and_thumbnail_ignore_the_mask() {
    let dir = TempDir::new().unwrap();
    let doc = ffi_mask_fixture(&dir, "unmasked", (4, 2), (4, 2), (0, 0));
    let hidden = unsafe { rz_doc_adding_layer_mask(doc, 1, MASK_HIDE_ALL, ptr::null(), 0, 0) };
    assert!(!hidden.is_null());

    // Photoshop/GIMP behavior: the layer thumbnail shows CONTENT and the mask
    // has its own thumbnail beside it, so neither getter applies the mask.
    assert_eq!(
        layer_pixels(hidden, 1),
        layer_pixels(doc, 1),
        "rz_doc_layer_image stays unmasked"
    );
    let masked_thumb = unsafe { rz_doc_layer_thumbnail(hidden, 1, 4) };
    let plain_thumb = unsafe { rz_doc_layer_thumbnail(doc, 1, 4) };
    assert!(!masked_thumb.is_null() && !plain_thumb.is_null());
    assert_eq!(
        img_pixels(masked_thumb),
        img_pixels(plain_thumb),
        "rz_doc_layer_thumbnail stays unmasked"
    );

    // Only the projection applies it — so the equalities above are not vacuous.
    let flat = flat_pixels(hidden);
    for x in 0..4 {
        for y in 0..2 {
            assert_eq!(
                pixel(&flat, 4, x, y),
                RED,
                "the projection applies the mask"
            );
        }
    }

    unsafe { rz_image_free(masked_thumb) };
    unsafe { rz_image_free(plain_thumb) };
    unsafe { rz_doc_free(hidden) };
    unsafe { rz_doc_free(doc) };
}

#[test]
fn ffi_layer_mask_null_and_range_guards() {
    let null_doc: *const RzDocument = ptr::null();
    let buffer = [0u8; 16]; // a 2x2 canvas' worth of either buffer
    unsafe {
        assert!(
            rz_doc_adding_layer_mask(null_doc, 0, MASK_REVEAL_ALL, ptr::null(), 0, 0).is_null()
        );
        assert!(
            rz_doc_adding_layer_mask(null_doc, 0, MASK_FROM_SELECTION, buffer.as_ptr(), 2, 2)
                .is_null()
        );
        assert!(rz_doc_removing_layer_mask(null_doc, 0, true).is_null());
        assert!(rz_doc_with_layer_mask_enabled(null_doc, 0, true).is_null());
        assert!(rz_doc_painting_layer_mask(null_doc, 0, buffer.as_ptr(), 2, 2).is_null());
        assert!(rz_doc_layer_mask_image(null_doc, 0).is_null());
        assert!(!rz_doc_layer_has_mask(null_doc, 0));
        assert!(!rz_doc_layer_mask_enabled(null_doc, 0));
    }

    let dir = TempDir::new().unwrap();
    let doc = ffi_mask_fixture(&dir, "guards", (2, 2), (2, 2), (0, 0));
    let sel = selection(2, 2, |_, _| 255);
    let hidden = unsafe {
        // Out-of-range indices.
        assert!(rz_doc_adding_layer_mask(doc, 9, MASK_REVEAL_ALL, ptr::null(), 0, 0).is_null());
        assert!(
            rz_doc_adding_layer_mask(doc, 9, MASK_FROM_SELECTION, sel.as_ptr(), 2, 2).is_null()
        );
        assert!(rz_doc_removing_layer_mask(doc, 9, true).is_null());
        assert!(rz_doc_with_layer_mask_enabled(doc, 9, true).is_null());
        assert!(rz_doc_painting_layer_mask(doc, 9, buffer.as_ptr(), 2, 2).is_null());
        assert!(rz_doc_layer_mask_image(doc, 9).is_null());
        assert!(!rz_doc_layer_has_mask(doc, 9));
        assert!(!rz_doc_layer_mask_enabled(doc, 9));

        // Unknown kinds, and a selection buffer that is not canvas-sized:
        // rejected against the canvas rather than read at the caller's word.
        assert!(rz_doc_adding_layer_mask(doc, 1, 3, ptr::null(), 0, 0).is_null());
        assert!(rz_doc_adding_layer_mask(doc, 1, -1, ptr::null(), 0, 0).is_null());
        assert!(
            rz_doc_adding_layer_mask(doc, 1, MASK_FROM_SELECTION, sel.as_ptr(), 1, 2).is_null()
        );
        assert!(
            rz_doc_adding_layer_mask(doc, 1, MASK_FROM_SELECTION, sel.as_ptr(), 2, 3).is_null()
        );
        assert!(
            rz_doc_adding_layer_mask(doc, 1, MASK_FROM_SELECTION, sel.as_ptr(), 0, 0).is_null()
        );
        assert!(rz_doc_adding_layer_mask(doc, 1, MASK_FROM_SELECTION, ptr::null(), 2, 2).is_null());

        // The kinds that never read the buffer accept a NULL one.
        rz_doc_adding_layer_mask(doc, 1, MASK_HIDE_ALL, ptr::null(), 0, 0)
    };
    assert!(!hidden.is_null());
    assert_eq!(ffi_mask_flags(hidden, 1), (true, true));

    unsafe { rz_doc_free(hidden) };
    unsafe { rz_doc_free(doc) };
}

// ---------------------------------------------------- layer metadata (FFI) --
//
// `meta` is an opaque host blob: the core stores, copies and serializes it but
// never looks inside. These drive the two entry points that surface it, plus
// the raw-buffer pixel replacement a re-render chains with them.

/// A realistic text-layer payload with non-ASCII content, so "came back
/// unchanged" means byte-for-byte rather than merely non-empty.
const TEXT_META: &str = concat!(
    "{\"type\":\"text\",\"string\":\"héllo 层 — ✎\",",
    "\"font\":\"Helvetica Neue\",\"size\":24.5,",
    "\"color\":\"#ff8800\",\"alignment\":\"center\"}"
);

/// Layer `idx`'s metadata through `rz_doc_layer_meta`; None when the call
/// returns NULL (no metadata, or an out-of-range index).
fn ffi_meta(doc: *const RzDocument, idx: usize) -> Option<String> {
    let p = unsafe { rz_doc_layer_meta(doc, idx) };
    if p.is_null() {
        return None;
    }
    let s = unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned();
    unsafe { rz_string_free(p) };
    Some(s)
}

/// Sets layer `idx`'s metadata, asserting success and freeing the old handle.
fn set_meta(doc: *mut RzDocument, idx: usize, meta: &str) -> *mut RzDocument {
    let c = CString::new(meta).expect("no interior NUL");
    apply(doc, |d| unsafe {
        rz_doc_with_layer_meta(d, idx, c.as_ptr())
    })
}

/// A 4x3 red background under a 2x2 blue "Top" layer (index 1).
fn meta_fixture(dir: &TempDir, tag: &str) -> *mut RzDocument {
    let doc = doc_from(dir, &format!("{tag}-bg.png"), &solid(4, 3, RED));
    add_layer(
        dir,
        &format!("{tag}-top.png"),
        doc,
        0,
        &solid(2, 2, BLUE),
        "Top",
    )
}

#[test]
fn ffi_layer_meta_round_trips_sets_and_clears() {
    let dir = TempDir::new().unwrap();
    let doc = meta_fixture(&dir, "roundtrip");
    assert_eq!(ffi_meta(doc, 0), None, "a fresh layer has no metadata");
    assert_eq!(ffi_meta(doc, 1), None);

    let c = CString::new(TEXT_META).unwrap();
    let tagged = unsafe { rz_doc_with_layer_meta(doc, 1, c.as_ptr()) };
    assert!(!tagged.is_null());
    assert_eq!(
        ffi_meta(tagged, 1).as_deref(),
        Some(TEXT_META),
        "the blob comes back verbatim, non-ASCII and all"
    );
    assert_eq!(ffi_meta(tagged, 0), None, "only the named layer is touched");
    assert_eq!(ffi_meta(doc, 1), None, "the setter is pure");

    // Setting again replaces; NULL clears.
    const SECOND: &str = "{\"type\":\"text\",\"string\":\"second\"}";
    let replaced = set_meta(tagged, 1, SECOND);
    assert_eq!(ffi_meta(replaced, 1).as_deref(), Some(SECOND));
    let cleared = unsafe { rz_doc_with_layer_meta(replaced, 1, ptr::null()) };
    assert!(!cleared.is_null(), "NULL clears rather than failing");
    assert_eq!(ffi_meta(cleared, 1), None);
    assert!(ffi_meta(replaced, 1).is_some(), "clearing is pure too");

    // Getting past the end of the stack is NULL, like every other getter.
    assert_eq!(ffi_meta(cleared, 2), None);
    assert_eq!(ffi_meta(cleared, usize::MAX), None);

    unsafe { rz_doc_free(cleared) };
    unsafe { rz_doc_free(replaced) };
    unsafe { rz_doc_free(doc) };
}

#[test]
fn ffi_layer_meta_rejects_invalid_utf8_and_over_long_payloads() {
    // The cap the RZDC writer enforces: accepting more here would let a
    // document hold metadata that rz_doc_save_native would then refuse.
    const META_CAP: usize = 16 * 1024 * 1024;

    let dir = TempDir::new().unwrap();
    let doc = meta_fixture(&dir, "reject");

    // A lone 0xFF is not valid UTF-8: refused outright, never lossily
    // converted into replacement characters behind the host's back.
    let invalid = CString::new(vec![0x7bu8, 0xff, 0xfe, 0x7d]).unwrap();
    assert!(unsafe { rz_doc_with_layer_meta(doc, 1, invalid.as_ptr()) }.is_null());

    let at_cap = CString::new("a".repeat(META_CAP)).unwrap();
    let big = unsafe { rz_doc_with_layer_meta(doc, 1, at_cap.as_ptr()) };
    assert!(!big.is_null(), "a payload exactly at the cap is accepted");
    assert_eq!(ffi_meta(big, 1).map(|s| s.len()), Some(META_CAP));
    unsafe { rz_doc_free(big) };

    let over_cap = CString::new("a".repeat(META_CAP + 1)).unwrap();
    assert!(unsafe { rz_doc_with_layer_meta(doc, 1, over_cap.as_ptr()) }.is_null());
    assert_eq!(ffi_meta(doc, 1), None, "a refused set changes nothing");

    unsafe { rz_doc_free(doc) };
}

#[test]
fn ffi_layer_meta_survives_a_native_save_and_reopen() {
    let dir = TempDir::new().unwrap();
    let doc = meta_fixture(&dir, "save");
    let doc = set_meta(doc, 1, TEXT_META);

    let path = dir.path().join("meta.rzdc");
    let c = cpath(&path);
    let mut err: *mut c_char = ptr::null_mut();
    assert!(
        unsafe { rz_doc_save_native(doc, c.as_ptr(), &mut err) },
        "save failed: {}",
        take_err_string(err)
    );

    let mut err: *mut c_char = ptr::null_mut();
    let back = unsafe { rz_doc_open(c.as_ptr(), &mut err) };
    assert!(!back.is_null(), "reopen failed: {}", take_err_string(err));
    assert_eq!(unsafe { rz_doc_layer_count(back) }, 2);
    assert_eq!(
        ffi_meta(back, 1).as_deref(),
        Some(TEXT_META),
        "metadata round-trips through the version-2 format"
    );
    assert_eq!(ffi_meta(back, 0), None, "a layer without stays without");

    unsafe { rz_doc_free(back) };
    unsafe { rz_doc_free(doc) };
}

#[test]
fn ffi_re_render_replaces_content_and_keeps_metadata() {
    let dir = TempDir::new().unwrap();
    let doc = meta_fixture(&dir, "rerender");
    let doc = set_meta(doc, 1, TEXT_META);
    assert_eq!(layer_dims(doc, 1), (2, 2));

    // The chain a text re-render uses: new pixels, then a new offset. Both
    // are pure, so the host commits only the final handle — one undo step.
    let green = solid(2, 2, GREEN).into_raw();
    let repainted = unsafe { rz_doc_with_layer_pixels_rgba(doc, 1, green.as_ptr(), 2, 2) };
    assert!(!repainted.is_null());
    let moved = apply(repainted, |d| unsafe {
        rz_doc_with_layer_offset(d, 1, 2, 1)
    });
    assert_eq!(layer_dims(moved, 1), (2, 2));
    assert_eq!(layer_pixels(moved, 1), green, "the buffer landed verbatim");
    assert_eq!(layer_offset(moved, 1), (2, 1));
    assert_eq!(
        ffi_meta(moved, 1).as_deref(),
        Some(TEXT_META),
        "metadata survives a pixel replacement and an offset change"
    );
    assert_eq!(
        layer_pixels(doc, 1),
        solid(2, 2, BLUE).into_raw(),
        "the input document is untouched"
    );
    assert_eq!(layer_offset(doc, 1), (0, 0));

    // The re-rendered content shows at its new position in the projection.
    let flat = flat_pixels(moved);
    assert_eq!(pixel(&flat, 4, 2, 1), GREEN);
    assert_eq!(pixel(&flat, 4, 3, 2), GREEN);
    assert_eq!(pixel(&flat, 4, 0, 0), RED);
    assert_eq!(pixel(&flat, 4, 1, 1), RED, "the old position is exposed");

    // A re-render at a different size resizes the layer and keeps the blob.
    let wide = solid(3, 1, WHITE).into_raw();
    let resized = apply(moved, |d| unsafe {
        rz_doc_with_layer_pixels_rgba(d, 1, wide.as_ptr(), 3, 1)
    });
    assert_eq!(layer_dims(resized, 1), (3, 1));
    assert_eq!(layer_pixels(resized, 1), wide);
    assert_eq!(ffi_meta(resized, 1).as_deref(), Some(TEXT_META));

    unsafe { rz_doc_free(resized) };
    unsafe { rz_doc_free(doc) };
}

#[test]
fn ffi_with_layer_pixels_rgba_keeps_a_mask_only_at_the_same_size() {
    let dir = TempDir::new().unwrap();
    let doc = ffi_mask_fixture(&dir, "rgba-mask", (4, 2), (4, 2), (0, 0));
    let sel = selection(4, 2, |x, _| if x < 2 { 255 } else { 0 });
    let masked = apply(doc, |d| unsafe {
        rz_doc_adding_layer_mask(d, 1, MASK_FROM_SELECTION, sel.as_ptr(), 4, 2)
    });
    assert_eq!(ffi_mask_flags(masked, 1), (true, true));

    let same = solid(4, 2, GREEN).into_raw();
    let kept = unsafe { rz_doc_with_layer_pixels_rgba(masked, 1, same.as_ptr(), 4, 2) };
    assert!(!kept.is_null());
    assert_eq!(
        ffi_mask_flags(kept, 1),
        (true, true),
        "a same-size re-render keeps the mask"
    );
    assert_eq!(ffi_mask_bytes(kept, 1), ffi_mask_bytes(masked, 1));

    let smaller = solid(2, 2, GREEN).into_raw();
    let dropped = unsafe { rz_doc_with_layer_pixels_rgba(masked, 1, smaller.as_ptr(), 2, 2) };
    assert!(!dropped.is_null());
    assert_eq!(layer_dims(dropped, 1), (2, 2));
    assert_eq!(
        ffi_mask_flags(dropped, 1),
        (false, false),
        "a differently sized re-render drops it (the mask is layer-sized)"
    );

    unsafe { rz_doc_free(dropped) };
    unsafe { rz_doc_free(kept) };
    unsafe { rz_doc_free(masked) };
}

#[test]
fn ffi_layer_meta_and_pixels_rgba_null_and_range_guards() {
    let null_doc: *const RzDocument = ptr::null();
    let meta = CString::new("{}").unwrap();
    let px = [0u8; 16]; // a 2x2 RGBA8 buffer

    unsafe {
        assert!(rz_doc_layer_meta(null_doc, 0).is_null());
        assert!(rz_doc_with_layer_meta(null_doc, 0, meta.as_ptr()).is_null());
        assert!(rz_doc_with_layer_meta(null_doc, 0, ptr::null()).is_null());
        assert!(rz_doc_with_layer_pixels_rgba(null_doc, 0, px.as_ptr(), 2, 2).is_null());
    }

    let dir = TempDir::new().unwrap();
    let doc = meta_fixture(&dir, "guards");
    unsafe {
        // Out-of-range indices on every entry point.
        assert!(rz_doc_layer_meta(doc, 2).is_null());
        assert!(rz_doc_with_layer_meta(doc, 2, meta.as_ptr()).is_null());
        assert!(rz_doc_with_layer_meta(doc, 2, ptr::null()).is_null());
        assert!(rz_doc_with_layer_pixels_rgba(doc, 2, px.as_ptr(), 2, 2).is_null());

        // A NULL buffer, a zero dimension, or dimensions past the pixel
        // ceiling are refused before any slice is built from them.
        assert!(rz_doc_with_layer_pixels_rgba(doc, 1, ptr::null(), 2, 2).is_null());
        assert!(rz_doc_with_layer_pixels_rgba(doc, 1, px.as_ptr(), 0, 2).is_null());
        assert!(rz_doc_with_layer_pixels_rgba(doc, 1, px.as_ptr(), 2, 0).is_null());
        assert!(rz_doc_with_layer_pixels_rgba(doc, 1, px.as_ptr(), 100_001, 1_000).is_null());
        assert!(rz_doc_with_layer_pixels_rgba(doc, 1, px.as_ptr(), u32::MAX, u32::MAX).is_null());
        assert_eq!(ffi_meta(doc, 1), None, "no refused call changed anything");
        assert_eq!(layer_dims(doc, 1), (2, 2));
    }
    unsafe { rz_doc_free(doc) };
}

// ------------------------------------------- free transform of one layer --
//
// `rz_doc_transform_layer` maps a layer's canvas rect through an arbitrary
// affine matrix and resamples it by inverse mapping. The properties worth
// pinning are geometric (canvas-space matrix, outward-rounded extent),
// numeric (premultiplied interpolation, exact fast paths) and structural
// (the mask stays layer-sized and aligned, `meta` survives).

/// Runs the transform through its FFI entry point on a copy of `doc`,
/// returning the new document, or `None` when the call refuses.
fn transform(doc: &RzDocument, idx: usize, m: [f64; 6], filter: c_int) -> Option<RzDocument> {
    let handle = Box::into_raw(Box::new(doc.clone()));
    let out = unsafe { rz_doc_transform_layer(handle, idx, m.as_ptr(), filter) };
    unsafe { rz_doc_free(handle) };
    if out.is_null() {
        None
    } else {
        Some(*unsafe { Box::from_raw(out) })
    }
}

/// [`transform`], asserting success.
fn transformed(doc: &RzDocument, idx: usize, m: [f64; 6], filter: c_int) -> RzDocument {
    transform(doc, idx, m, filter).expect("transform_layer must succeed")
}

const IDENTITY: [f64; 6] = [1.0, 0.0, 0.0, 1.0, 0.0, 0.0];
const SAMPLERS: [c_int; 4] = [
    FILTER_NEAREST,
    FILTER_BILINEAR,
    FILTER_CATMULL_ROM,
    FILTER_LANCZOS3,
];

/// The canvas-space matrix a `CGAffineTransform`-style host COMPOSES for a
/// rotate-and-scale about a pivot,
///
///     translate(pivot + move) . rotate(degrees) . scale(sx, sy)
///         . translate(-pivot)
///
/// built from `cos`/`sin` exactly the way `CGAffineTransform.rotated(by:)`
/// builds it. Quarter turns therefore arrive carrying 6.123e-17 where a
/// hand-written matrix would carry an exact 0 — which is precisely what the
/// exact-form tests below need to see.
fn compose_about(degrees: f64, scale: (f64, f64), pivot: (f64, f64), mv: (f64, f64)) -> [f64; 6] {
    let (s, c) = degrees.to_radians().sin_cos();
    let (cx, cy) = pivot;
    // Linear part: rotation times scale.
    let (a, b) = (c * scale.0, s * scale.0);
    let (cc, d) = (-s * scale.1, c * scale.1);
    [
        a,
        b,
        cc,
        d,
        cx + mv.0 - a * cx - cc * cy,
        cy + mv.1 - b * cx - d * cy,
    ]
}

/// Canvas-space matrix rotating `degrees` clockwise about the canvas point
/// (cx, cy) — the composition a free-transform tool builds from its handles.
fn rotate_about(degrees: f64, cx: f64, cy: f64) -> [f64; 6] {
    compose_about(degrees, (1.0, 1.0), (cx, cy), (0.0, 0.0))
}

/// Asserts that `m` really is a COMPOSED matrix — carrying at least one
/// element that a hand-written version would have written as an exact 0 —
/// so a test built on it cannot pass by accidentally being exact.
fn assert_composed(name: &str, m: &[f64; 6]) {
    assert!(
        m.iter().any(|v| *v != 0.0 && v.abs() < 1e-12),
        "{name}: {m:?} has no floating-point residue, so it proves nothing \
         about recognizing composed matrices"
    );
}

/// A 4x3 layer whose fully transparent pixels carry deliberately WHITE color
/// bytes: any path that round-trips them through premultiplied alpha zeroes
/// those bytes, so "byte-identical" below really means byte-identical.
fn quirky_layer() -> RgbaImage {
    RgbaImage::from_fn(4, 3, |x, y| {
        if (x + 2 * y) % 3 == 0 {
            Rgba([255, 255, 255, 0])
        } else {
            Rgba([
                (20 + x * 50) as u8,
                (30 + y * 60) as u8,
                ((x * 7 + y * 11) * 9 % 256) as u8,
                (255 - y * 40) as u8,
            ])
        }
    })
}

/// Red canvas under the 4x3 [`quirky_layer`] placed at `offset` (index 1).
fn transform_fixture(canvas: (u32, u32), offset: (i32, i32)) -> RzDocument {
    RzDocument::from_pixels(solid(canvas.0, canvas.1, RED))
        .adding_image_layer(0, quirky_layer(), "Top")
        .expect("add layer")
        .with_layer_offset(1, offset.0, offset.1)
        .expect("set offset")
}

#[test]
fn transform_layer_identity_and_integer_translation_are_lossless() {
    let doc = transform_fixture((8, 6), (2, 1));
    let before = doc.layers[1].pixels.as_raw().clone();
    let flat_before = doc.flattened();

    for filter in SAMPLERS {
        let out = transformed(&doc, 1, IDENTITY, filter);
        assert_eq!(out.layers[1].offset, (2, 1), "identity keeps the offset");
        assert_eq!(out.layers[1].pixels.dimensions(), (4, 3));
        assert_eq!(
            out.layers[1].pixels.as_raw(),
            &before,
            "identity must not resample (filter {filter})"
        );
        assert_eq!(out.flattened(), flat_before);
        assert_eq!((out.width, out.height), (8, 6), "the canvas is untouched");
        assert_eq!(out.layers[0].pixels.as_raw(), doc.layers[0].pixels.as_raw());
    }

    // A whole-pixel translation moves the offset and copies the pixels: no
    // resampling blur, and the transparent pixels keep their color bytes.
    for filter in SAMPLERS {
        let moved = transformed(&doc, 1, [1.0, 0.0, 0.0, 1.0, 3.0, -4.0], filter);
        assert_eq!(moved.layers[1].offset, (5, -3));
        assert_eq!(moved.layers[1].pixels.dimensions(), (4, 3));
        assert_eq!(
            moved.layers[1].pixels.as_raw(),
            &before,
            "an integer translation must be a pixel copy (filter {filter})"
        );
    }

    // A SUB-pixel translation is a real resample: same extent grown by the
    // outward rounding, and the pixels genuinely change.
    let half = transformed(&doc, 1, [1.0, 0.0, 0.0, 1.0, 0.5, 0.0], FILTER_BILINEAR);
    assert_eq!(half.layers[1].offset, (2, 1));
    assert_eq!(half.layers[1].pixels.dimensions(), (5, 3));
    assert_ne!(half.layers[1].pixels.as_raw(), &before);
}

#[test]
fn transform_layer_matches_the_dedicated_exact_ops() {
    let doc = transform_fixture((8, 6), (2, 1));
    let (cw, ch) = (f64::from(doc.width), f64::from(doc.height));
    // The canvas-space matrices of the whole-document ops: the transformed
    // layer must land exactly where the document op puts it, byte for byte.
    let cases: [(&str, [f64; 6], RzDocument); 5] = [
        ("rotate90", [0.0, 1.0, -1.0, 0.0, ch, 0.0], doc.rotate90()),
        ("rotate180", [-1.0, 0.0, 0.0, -1.0, cw, ch], doc.rotate180()),
        ("rotate270", [0.0, -1.0, 1.0, 0.0, 0.0, cw], doc.rotate270()),
        (
            "flip_h",
            [-1.0, 0.0, 0.0, 1.0, cw, 0.0],
            doc.flip_horizontal(),
        ),
        (
            "flip_v",
            [1.0, 0.0, 0.0, -1.0, 0.0, ch],
            doc.flip_vertical(),
        ),
    ];
    for (name, m, reference) in cases {
        for filter in SAMPLERS {
            let out = transformed(&doc, 1, m, filter);
            assert_eq!(
                out.layers[1].pixels.dimensions(),
                reference.layers[1].pixels.dimensions(),
                "{name}: dimensions (filter {filter})"
            );
            assert_eq!(
                out.layers[1].pixels.as_raw(),
                reference.layers[1].pixels.as_raw(),
                "{name}: must be byte-identical to the dedicated op (filter {filter})"
            );
            assert_eq!(
                out.layers[1].offset, reference.layers[1].offset,
                "{name}: offset (filter {filter})"
            );
            // Only the layer moves: the canvas and its neighbours do not.
            assert_eq!((out.width, out.height), (doc.width, doc.height));
            assert_eq!(out.layers[0].pixels.as_raw(), doc.layers[0].pixels.as_raw());
        }
    }
}

#[test]
fn transform_layer_scale_extent_and_interpolation() {
    // A 2x2 opaque checker at the canvas origin, scaled 2x about it.
    let layer = RgbaImage::from_fn(2, 2, |x, y| {
        if (x + y) % 2 == 0 {
            Rgba([0, 0, 0, 255])
        } else {
            Rgba([255, 255, 255, 255])
        }
    });
    let doc = RzDocument::from_pixels(solid(8, 8, RED))
        .adding_image_layer(0, layer.clone(), "Top")
        .expect("add layer");
    let scale2x = [2.0, 0.0, 0.0, 2.0, 0.0, 0.0];

    let near = transformed(&doc, 1, scale2x, FILTER_NEAREST);
    assert_eq!(near.layers[1].offset, (0, 0));
    assert_eq!(near.layers[1].pixels.dimensions(), (4, 4));
    for y in 0..4 {
        for x in 0..4 {
            assert_eq!(
                near.layers[1].pixels.get_pixel(x, y).0,
                layer.get_pixel(x / 2, y / 2).0,
                "nearest 2x must replicate blocks at ({x}, {y})"
            );
        }
    }

    let lin = transformed(&doc, 1, scale2x, FILTER_BILINEAR);
    assert_eq!(lin.layers[1].pixels.dimensions(), (4, 4));
    // The interior samples sit 1/4 and 3/4 of the way between the source
    // pixel centres, so the four taps weigh 9:3:3:1 over the checker.
    let interior = |x, y| lin.layers[1].pixels.get_pixel(x, y).0;
    assert_eq!(interior(1, 1), [96, 96, 96, 255]); // 0.375 * 255 white
    assert_eq!(interior(2, 2), [96, 96, 96, 255]);
    assert_eq!(interior(1, 2), [159, 159, 159, 255]); // 0.625 * 255 white
    assert_eq!(interior(2, 1), [159, 159, 159, 255]);
    // The outer ring only half-covers the source, so it fades toward
    // transparency instead of stopping abruptly — and the white corner stays
    // pure white, because the interpolation ran premultiplied.
    assert_eq!(lin.layers[1].pixels.get_pixel(0, 0).0, [0, 0, 0, 143]);
    assert_eq!(
        lin.layers[1].pixels.get_pixel(3, 0).0,
        [255, 255, 255, 143],
        "a partially covered white edge pixel must stay white"
    );
}

#[test]
fn transform_layer_interpolates_premultiplied_so_edges_do_not_fringe() {
    // An opaque block on a TRANSPARENT background, rotated a few degrees.
    // Interpolating straight RGBA drags the transparent pixels' (meaningless)
    // color into the anti-aliased edge; premultiplied interpolation cannot,
    // because a zero-alpha pixel contributes nothing to either accumulator.
    // Since every contributing pixel shares one color, the edge color is that
    // color EXACTLY, at any coverage.
    //
    // Two failure modes, one case each: white on transparent BLACK catches
    // interpolating straight and emitting it (the edge darkens toward the
    // background), and a colored block on transparent MAGENTA catches
    // interpolating straight and then unpremultiplying (the edge is pulled
    // toward the background hue, which a black background would hide).
    for (block, background) in [
        ([255, 255, 255, 255], [0, 0, 0, 0]),
        ([60, 180, 240, 255], [255, 0, 255, 0]),
    ] {
        let mut pixels = RgbaImage::from_pixel(14, 14, Rgba(background));
        for y in 4..10 {
            for x in 4..10 {
                pixels.put_pixel(x, y, Rgba(block));
            }
        }
        let doc = RzDocument::from_pixels(pixels);
        let m = rotate_about(7.0, 7.0, 7.0);

        for filter in [FILTER_BILINEAR, FILTER_CATMULL_ROM, FILTER_LANCZOS3] {
            let out = transformed(&doc, 0, m, filter);
            let mut soft_edges = 0;
            for px in out.layers[0].pixels.pixels() {
                let [r, g, b, a] = px.0;
                if a == 0 {
                    continue;
                }
                assert_eq!(
                    [r, g, b],
                    [block[0], block[1], block[2]],
                    "filter {filter}: a partly covered edge pixel (alpha {a}) drifted \
                     off the block color — the interpolation was not premultiplied"
                );
                if a < 255 {
                    soft_edges += 1;
                }
            }
            assert!(
                soft_edges > 8,
                "filter {filter}: the rotation must actually produce anti-aliased \
                 edge pixels ({soft_edges} found), else the test proves nothing"
            );
        }
    }
}

/// A layer whose ALPHA channel is exactly its MASK: the two must then come
/// out of any transform as identical bytes, which is precisely what "the mask
/// lands pixel-for-pixel on the transformed pixels" means. The pattern is
/// asymmetric, so a one-pixel misalignment shows up immediately.
fn alpha_equals_mask_doc() -> RzDocument {
    let pattern = |x: u32, y: u32| ((x * 37 + y * 91 + 13) % 256) as u8;
    let pixels = RgbaImage::from_fn(7, 5, |x, y| Rgba([200, 40, 90, pattern(x, y)]));
    let mut doc = RzDocument::from_pixels(solid(14, 11, RED))
        .adding_image_layer(0, pixels, "Top")
        .expect("add layer")
        .with_layer_offset(1, 3, 2)
        .expect("set offset");
    doc.layers[1].mask = Some(Arc::new(GrayImage::from_fn(7, 5, |x, y| {
        Luma([pattern(x, y)])
    })));
    doc
}

#[test]
fn transform_layer_carries_the_mask_pixel_for_pixel() {
    let doc = alpha_equals_mask_doc();
    let m = rotate_about(23.0, 6.5, 4.5);

    for filter in SAMPLERS {
        let out = transformed(&doc, 1, m, filter);
        assert_mask_invariant(&out, "transform_layer");
        let layer = &out.layers[1];
        let mask = layer.mask.as_ref().expect("the mask must survive");
        assert!(layer.mask_enabled);
        let alpha: Vec<u8> = layer
            .pixels
            .as_raw()
            .chunks_exact(4)
            .map(|p| p[3])
            .collect();
        assert_eq!(
            &alpha,
            mask.as_raw(),
            "filter {filter}: the mask must be resampled exactly like the alpha \
             channel it was built to match"
        );
    }

    // A layer with no mask stays maskless.
    let plain = transform_fixture((8, 6), (1, 1));
    let out = transformed(&plain, 1, m, FILTER_BILINEAR);
    assert!(out.layers[1].mask.is_none());
}

#[test]
fn transform_layer_mask_composites_like_a_pre_applied_mask() {
    // With a 0/255 mask and point sampling, gating the layer before or after
    // the transform must give literally the same projection — only an
    // aligned mask can manage that.
    let doc = checkerboard_masked((12, 10), (4, 4), (2, 2));
    let baked = doc.remove_mask(1, true).expect("apply the mask");
    for m in [
        [2.0, 0.0, 0.0, 2.0, -2.0, -2.0], // 2x about canvas (2, 2)
        [1.0, 0.0, 0.0, 1.0, 3.0, 1.0],   // whole-pixel move
        [0.0, 1.0, -1.0, 0.0, 10.0, 0.0], // 90 degrees
        [3.0, 0.0, 0.0, 1.0, 0.0, 0.0],   // anisotropic stretch
    ] {
        let masked = transformed(&doc, 1, m, FILTER_NEAREST);
        let applied = transformed(&baked, 1, m, FILTER_NEAREST);
        assert_mask_invariant(&masked, "masked transform");
        assert_eq!(masked.layers[1].offset, applied.layers[1].offset);
        assert_eq!(
            masked.flattened(),
            applied.flattened(),
            "the transformed mask must hide exactly the transformed pixels"
        );
    }
}

#[test]
fn transform_layer_operates_in_canvas_coordinates() {
    // A 4x3 layer at (4, 3) on a 16x12 canvas.
    let doc = transform_fixture((16, 12), (4, 3));

    // Scaling 2x about the CANVAS origin doubles the offset too: the layer's
    // placement is part of what the matrix transforms.
    let out = transformed(&doc, 1, [2.0, 0.0, 0.0, 2.0, 0.0, 0.0], FILTER_NEAREST);
    assert_eq!(out.layers[1].offset, (8, 6));
    assert_eq!(out.layers[1].pixels.dimensions(), (8, 6));

    // The same scale about the layer's own top-left corner leaves the corner
    // exactly where it was.
    let out = transformed(&doc, 1, [2.0, 0.0, 0.0, 2.0, -4.0, -3.0], FILTER_NEAREST);
    assert_eq!(out.layers[1].offset, (4, 3));
    assert_eq!(out.layers[1].pixels.dimensions(), (8, 6));

    // Rotating 90 degrees about the canvas origin swings the layer to
    // NEGATIVE x — only a canvas-space matrix does that.
    let out = transformed(&doc, 1, [0.0, 1.0, -1.0, 0.0, 0.0, 0.0], FILTER_NEAREST);
    assert_eq!(out.layers[1].offset, (-6, 4));
    assert_eq!(out.layers[1].pixels.dimensions(), (3, 4));
    assert_eq!((out.width, out.height), (16, 12), "the canvas never moves");

    // A fractional extent rounds OUTWARD so no source pixel is clipped:
    // x spans [6, 12] exactly, y spans [4.5, 9] and grows to [4, 9].
    let out = transformed(&doc, 1, [1.5, 0.0, 0.0, 1.5, 0.0, 0.0], FILTER_BILINEAR);
    assert_eq!(out.layers[1].offset, (6, 4));
    assert_eq!(out.layers[1].pixels.dimensions(), (6, 5));

    // A negative offset survives the round trip through the bounding box.
    let doc = transform_fixture((16, 12), (-3, -2));
    let out = transformed(&doc, 1, IDENTITY, FILTER_BILINEAR);
    assert_eq!(out.layers[1].offset, (-3, -2));
    let out = transformed(&doc, 1, [1.0, 0.0, 0.0, 1.0, -1.0, -1.0], FILTER_NEAREST);
    assert_eq!(out.layers[1].offset, (-4, -3));
}

#[test]
fn transform_layer_preserves_properties_meta_and_neighbours() {
    let mut doc = transform_fixture((10, 8), (1, 1))
        .with_layer_name(1, "Kept")
        .expect("name")
        .with_layer_opacity(1, 0.5)
        .expect("opacity")
        .with_layer_blend_mode(1, BlendMode::Multiply)
        .expect("blend")
        .with_layer_visible(1, false)
        .expect("visible");
    doc.layers[1].meta = Some(META.to_string());
    doc.layers[1].mask = Some(Arc::new(GrayImage::from_pixel(4, 3, Luma([200]))));
    doc.layers[1].mask_enabled = false;

    let out = transformed(&doc, 1, rotate_about(31.0, 5.0, 4.0), FILTER_BILINEAR);
    let layer = &out.layers[1];
    assert_eq!(layer.name, "Kept");
    assert_eq!(layer.opacity, 0.5);
    assert_eq!(layer.blend, BlendMode::Multiply);
    assert!(!layer.visible);
    assert_eq!(
        layer.meta.as_deref(),
        Some(META),
        "meta is opaque to the core: only the host may clear it"
    );
    assert!(
        !layer.mask_enabled && layer.mask.is_some(),
        "a DISABLED mask still travels with its layer"
    );
    assert_mask_invariant(&out, "transform with a disabled mask");

    // Nothing else in the document moved.
    assert_eq!((out.width, out.height), (10, 8));
    assert_eq!(out.layers.len(), 2);
    assert_eq!(out.layers[0].pixels.as_raw(), doc.layers[0].pixels.as_raw());
    assert_eq!(out.layers[0].offset, doc.layers[0].offset);

    // The source document is untouched — the op is pure.
    assert_eq!(doc.layers[1].pixels.dimensions(), (4, 3));
    assert_eq!(doc.layers[1].offset, (1, 1));
}

#[test]
fn transform_layer_rejects_bad_matrices_and_arguments() {
    let doc = transform_fixture((8, 6), (1, 1));

    // Out-of-range layer index.
    assert!(transform(&doc, 2, IDENTITY, FILTER_BILINEAR).is_none());
    assert!(transform(&doc, usize::MAX, IDENTITY, FILTER_BILINEAR).is_none());

    // Unknown sampler values.
    assert!(transform(&doc, 1, IDENTITY, 4).is_none());
    assert!(transform(&doc, 1, IDENTITY, -1).is_none());

    // Singular (and near-singular) matrices have no inverse to map through.
    for m in [
        [0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        [1.0, 0.0, 1.0, 0.0, 0.0, 0.0], // collapses onto a horizontal line
        [0.0, 1.0, 0.0, 1.0, 0.0, 0.0], // collapses onto a vertical line
        [2.0, 1.0, 4.0, 2.0, 0.0, 0.0], // parallel axes
        [1e-6, 0.0, 0.0, 1e-6, 0.0, 0.0], // determinant 1e-12
    ] {
        assert!(
            transform(&doc, 1, m, FILTER_BILINEAR).is_none(),
            "singular matrix {m:?} must be refused"
        );
    }

    // Any non-finite component, in any slot.
    for bad in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY] {
        for slot in 0..6 {
            let mut m = IDENTITY;
            m[slot] = bad;
            assert!(
                transform(&doc, 1, m, FILTER_BILINEAR).is_none(),
                "non-finite element {bad} in slot {slot} must be refused"
            );
        }
    }

    // An extent past the 100-megapixel ceiling, and one past the int32
    // offset range.
    assert!(transform(&doc, 1, [1e5, 0.0, 0.0, 1e5, 0.0, 0.0], FILTER_NEAREST).is_none());
    assert!(transform(&doc, 1, [1.0, 0.0, 0.0, 1.0, 3e9, 0.0], FILTER_NEAREST).is_none());
    assert!(transform(&doc, 1, [1.0, 0.0, 0.0, 1.0, 0.0, -3e9], FILTER_NEAREST).is_none());

    // A NULL matrix pointer on a valid document, and a NULL document.
    let handle = Box::into_raw(Box::new(doc.clone()));
    unsafe {
        assert!(rz_doc_transform_layer(handle, 1, ptr::null(), FILTER_NEAREST).is_null());
        assert!(
            rz_doc_transform_layer(ptr::null(), 1, IDENTITY.as_ptr(), FILTER_NEAREST).is_null()
        );
        rz_doc_free(handle);
    }

    // Nothing above changed the document.
    assert_eq!(doc.layers[1].offset, (1, 1));
    assert_eq!(doc.layers[1].pixels.dimensions(), (4, 3));
}

// ------------------------------- composed quarter turns are still exact --
//
// No host hands over a hand-written matrix; every one of them COMPOSES it,
// and `cos(PI/2)` is 6.123e-17 rather than 0. A quarter turn built that way
// must land on exactly the same pixels and exactly the same extent as one
// written out with integer elements — otherwise it silently resamples (lossy
// and slow) and gains a phantom transparent row or column from the outward
// rounding of a corner that overshot an integer by 1e-15.

#[test]
fn transform_layer_quarter_turns_composed_from_an_angle_are_exact() {
    let doc = transform_fixture((8, 6), (2, 1));
    // The same five canvas-space maps as the dedicated whole-document ops on
    // an 8x6 canvas, but composed from an ANGLE (and, for the flip, from a
    // rotation and a negative scale) instead of written out.
    let cases: [(&str, [f64; 6], RzDocument); 4] = [
        (
            "rotate90",
            compose_about(90.0, (1.0, 1.0), (3.0, 3.0), (0.0, 0.0)),
            doc.rotate90(),
        ),
        (
            "rotate180",
            compose_about(180.0, (1.0, 1.0), (4.0, 3.0), (0.0, 0.0)),
            doc.rotate180(),
        ),
        (
            "rotate270",
            compose_about(270.0, (1.0, 1.0), (4.0, 4.0), (0.0, 0.0)),
            doc.rotate270(),
        ),
        // A composed FLIP: a half turn with a negated y scale is a horizontal
        // mirror, and both factors contribute their own residue.
        (
            "flip_h (180 + scale_y -1)",
            compose_about(180.0, (1.0, -1.0), (4.0, 3.0), (0.0, 0.0)),
            doc.flip_horizontal(),
        ),
    ];
    for (name, m, reference) in cases {
        assert_composed(name, &m);
        for filter in SAMPLERS {
            let out = transformed(&doc, 1, m, filter);
            assert_eq!(
                out.layers[1].pixels.dimensions(),
                reference.layers[1].pixels.dimensions(),
                "{name}: a composed quarter turn must not change the extent \
                 (filter {filter})"
            );
            assert_eq!(
                out.layers[1].offset, reference.layers[1].offset,
                "{name}: offset (filter {filter})"
            );
            assert_eq!(
                out.layers[1].pixels.as_raw(),
                reference.layers[1].pixels.as_raw(),
                "{name}: a composed quarter turn must be byte-identical to the \
                 dedicated op, not resampled (filter {filter})"
            );
        }
    }

    // A quarter turn about a HALF-pixel pivot: the pivot is fractional but the
    // composition's translation, and so the extent, still lands on integers,
    // so this is a pixel copy too. The 4x3 layer at (2, 1) swings to (3, 0).
    let m = compose_about(90.0, (1.0, 1.0), (4.5, 2.5), (0.0, 0.0));
    assert_composed("rotate90 about (4.5, 2.5)", &m);
    let reference = doc.rotate90();
    for filter in SAMPLERS {
        let out = transformed(&doc, 1, m, filter);
        assert_eq!(out.layers[1].offset, (3, 0));
        assert_eq!(out.layers[1].pixels.dimensions(), (3, 4));
        assert_eq!(
            out.layers[1].pixels.as_raw(),
            reference.layers[1].pixels.as_raw(),
            "a non-integer pivot that still lands on integer bounds is exact \
             (filter {filter})"
        );
    }
}

#[test]
fn transform_layer_quarter_turn_extent_has_no_phantom_margin() {
    // Both shapes regressed in a live app before the corners were snapped: a
    // 100x60 layer turned about its own top-left corner came back 61 wide
    // (column 60 fully transparent), and an 80x80 turned about its centre came
    // back at y = -1 and 81 tall.
    for (w, h, pivot, offset, dims) in [
        (
            100_u32,
            60_u32,
            (0.0, 0.0),
            (-60_i32, 0_i32),
            (60_u32, 100_u32),
        ),
        (80, 80, (40.0, 40.0), (0, 0), (80, 80)),
    ] {
        let doc = RzDocument::from_pixels(opaque_pattern(w, h));
        let reference = doc.rotate90();
        let m = compose_about(90.0, (1.0, 1.0), pivot, (0.0, 0.0));
        assert_composed("rotate90", &m);
        for filter in SAMPLERS {
            let out = transformed(&doc, 0, m, filter);
            let layer = &out.layers[0];
            assert_eq!(
                layer.pixels.dimensions(),
                dims,
                "{w}x{h} about {pivot:?}: no phantom row or column (filter {filter})"
            );
            assert_eq!(layer.offset, offset, "{w}x{h} about {pivot:?}: offset");
            assert!(
                layer.pixels.pixels().all(|p| p.0[3] == 255),
                "{w}x{h} about {pivot:?}: an opaque layer must stay fully opaque \
                 — a transparent margin means the extent grew (filter {filter})"
            );
            assert_eq!(
                layer.pixels.as_raw(),
                reference.layers[0].pixels.as_raw(),
                "{w}x{h} about {pivot:?}: must be the dedicated rotate90's bytes \
                 (filter {filter})"
            );
        }
    }
}

#[test]
fn transform_layer_composed_integer_translation_is_lossless() {
    // A full turn plus a whole-pixel move: the linear part is the identity
    // only to within 2.4e-16, and the translation is 3 / -4 only to within
    // the same. It must still be a pixel copy, not a resample.
    let doc = transform_fixture((8, 6), (2, 1));
    let before = doc.layers[1].pixels.as_raw().clone();
    let m = compose_about(360.0, (1.0, 1.0), (2.5, 1.5), (3.0, -4.0));
    assert_composed("360 + move", &m);
    for filter in SAMPLERS {
        let out = transformed(&doc, 1, m, filter);
        assert_eq!(out.layers[1].offset, (5, -3));
        assert_eq!(out.layers[1].pixels.dimensions(), (4, 3));
        assert_eq!(
            out.layers[1].pixels.as_raw(),
            &before,
            "a composed integer translation must be a pixel copy (filter {filter})"
        );
    }
}

#[test]
fn transform_layer_near_right_angle_still_resamples() {
    // The tolerance is 1e-9, four orders of magnitude tighter than the
    // smallest angle a user can name off a right angle: 89.99 degrees must
    // resample, with its own (larger, outward-rounded) extent.
    let doc = RzDocument::from_pixels(opaque_pattern(100, 60));
    let exact = transformed(
        &doc,
        0,
        compose_about(90.0, (1.0, 1.0), (0.0, 0.0), (0.0, 0.0)),
        FILTER_BILINEAR,
    );
    let near = transformed(
        &doc,
        0,
        compose_about(89.99, (1.0, 1.0), (0.0, 0.0), (0.0, 0.0)),
        FILTER_BILINEAR,
    );
    assert_eq!(
        near.layers[0].pixels.dimensions(),
        (61, 101),
        "89.99 degrees genuinely overhangs both axes, so the extent rounds out"
    );
    assert_eq!(near.layers[0].offset, (-60, 0));
    assert_ne!(
        near.layers[0].pixels.as_raw(),
        exact.layers[0].pixels.as_raw(),
        "a near-right angle must not be snapped onto the exact quarter turn"
    );
    // It resampled: an opaque source turned by a fraction of a degree gains
    // anti-aliased, partly transparent edge pixels, which no pixel copy has.
    let soft = near.layers[0]
        .pixels
        .pixels()
        .filter(|p| p.0[3] > 0 && p.0[3] < 255)
        .count();
    assert!(soft > 8, "89.99 degrees must resample ({soft} soft pixels)");
    // ... and the interior is still the source, resampled sanely: the pixel
    // one in from the middle of the layer is opaque.
    assert_eq!(near.layers[0].pixels.get_pixel(30, 50).0[3], 255);
}

#[test]
fn transform_layer_extent_snapping_leaves_fractional_transforms_alone() {
    // Regression: the corner snapping must be invisible to any transform that
    // is fractional by a user-meaningful amount — these extents are the ones
    // the outward rounding produced before it existed.
    let doc = transform_fixture((16, 12), (4, 3));

    // 1.5x about the canvas origin: x spans [6, 12], y spans [4.5, 9] -> [4, 9].
    let out = transformed(&doc, 1, [1.5, 0.0, 0.0, 1.5, 0.0, 0.0], FILTER_BILINEAR);
    assert_eq!(out.layers[1].offset, (6, 4));
    assert_eq!(out.layers[1].pixels.dimensions(), (6, 5));

    // A half-pixel move still grows the extent by one in x and resamples.
    let before = doc.layers[1].pixels.as_raw().clone();
    let out = transformed(&doc, 1, [1.0, 0.0, 0.0, 1.0, 0.5, 0.0], FILTER_BILINEAR);
    assert_eq!(out.layers[1].offset, (4, 3));
    assert_eq!(out.layers[1].pixels.dimensions(), (5, 3));
    assert_ne!(out.layers[1].pixels.as_raw(), &before);

    // A few degrees off axis: the corners are nowhere near integers, so the
    // bounding box is the same one the outward rounding always gave.
    let out = transformed(&doc, 1, rotate_about(7.0, 6.0, 4.5), FILTER_BILINEAR);
    assert_eq!(out.layers[1].pixels.dimensions(), (6, 5));

    // Even 1e-6 of a degree off a right angle — far below anything visible,
    // far above the 1e-9 tolerance — is left to resample.
    let m = compose_about(90.000001, (1.0, 1.0), (0.0, 0.0), (0.0, 0.0));
    let out = transformed(&doc, 1, m, FILTER_BILINEAR);
    assert_ne!(
        out.layers[1].pixels.as_raw(),
        transformed(&doc, 1, [0.0, 1.0, -1.0, 0.0, 0.0, 0.0], FILTER_BILINEAR).layers[1]
            .pixels
            .as_raw(),
        "the tolerance must not swallow a genuinely different transform"
    );
}
