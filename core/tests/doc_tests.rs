//! Integration tests for the layered document model, exercised through the
//! public C FFI (`rz_doc_*`) declared in `include/rasterize_core.h`.

use std::ffi::{c_char, c_int, CStr, CString};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::ptr;

use image::{Rgba, RgbaImage};
use rasterize_core::doc::RzDocument;
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

const FILTER_NEAREST: c_int = 0;
const FILTER_BILINEAR: c_int = 1;

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
