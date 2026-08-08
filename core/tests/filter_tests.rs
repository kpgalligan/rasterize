//! FFI-level tests for the "Additional filters" section of
//! `include/rasterize_core.h`, exercised through the C ABI like
//! `tests/integration.rs`.

use std::ffi::{c_char, CStr, CString};
use std::path::Path;
use std::ptr;

use image::{Rgba, RgbaImage};
use rasterize_core::ffi::*;
use rasterize_core::ffi_filters::*;
use rasterize_core::RzImage;
use tempfile::TempDir;

// ---------------------------------------------------------------- helpers --

fn cpath(p: &Path) -> CString {
    CString::new(p.to_str().expect("utf-8 path")).expect("no interior NUL")
}

/// Gradient with an alpha ramp (fully opaque top row, transparent bottom).
fn test_pattern(w: u32, h: u32) -> RgbaImage {
    RgbaImage::from_fn(w, h, |x, y| {
        let r = (x * 255 / (w - 1).max(1)) as u8;
        let g = (y * 255 / (h - 1).max(1)) as u8;
        let b = ((x + y) % 256) as u8;
        let a = 255 - (y * 255 / (h - 1).max(1)) as u8;
        Rgba([r, g, b, a])
    })
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

fn open_ok(path: &Path) -> *mut RzImage {
    let c = cpath(path);
    let mut err: *mut c_char = ptr::null_mut();
    let img = unsafe { rz_image_open(c.as_ptr(), &mut err) };
    assert!(
        !img.is_null(),
        "open of {path:?} failed: {}",
        take_err_string(err)
    );
    img
}

/// Writes `img` as a PNG (via the image crate) and opens it back through the
/// FFI; the only way to materialize an RzImage from synthesized pixels.
fn open_pattern(dir: &TempDir, name: &str, img: &RgbaImage) -> *mut RzImage {
    let path = dir.path().join(name);
    img.save(&path).expect("save pattern png");
    open_ok(&path)
}

fn dims(img: *const RzImage) -> (u32, u32) {
    unsafe { (rz_image_width(img), rz_image_height(img)) }
}

fn pixels(img: *const RzImage) -> Vec<u8> {
    let (w, h) = dims(img);
    let p = unsafe { rz_image_pixels_rgba(img) };
    assert!(!p.is_null(), "pixels pointer NULL for valid image");
    unsafe { std::slice::from_raw_parts(p, (w * h * 4) as usize) }.to_vec()
}

fn pixel_at(img: *const RzImage, x: u32, y: u32) -> [u8; 4] {
    let (w, h) = dims(img);
    assert!(x < w && y < h);
    let v = pixels(img);
    let i = ((y * w + x) * 4) as usize;
    [v[i], v[i + 1], v[i + 2], v[i + 3]]
}

fn free(img: *mut RzImage) {
    unsafe { rz_image_free(img) }
}

// ------------------------------------------------------------------ tests --

#[test]
fn hue_rotate_identity_rotation_alpha_and_nan() {
    let dir = tempfile::tempdir().unwrap();
    let pattern = test_pattern(32, 24);
    let img = open_pattern(&dir, "pattern.png", &pattern);
    let src = pattern.as_raw();

    // The matrix at 0 degrees IS the identity (tolerance 1); at 360 degrees
    // it is near-exact (tolerance 2). Alpha must be byte-identical.
    for (degrees, tol) in [(0.0f32, 1i32), (360.0, 2)] {
        let out = unsafe { rz_image_hue_rotate(img, degrees) };
        assert!(!out.is_null(), "hue_rotate({degrees}) failed");
        assert_eq!(dims(out), (32, 24));
        for (i, (&got, &want)) in pixels(out).iter().zip(src.iter()).enumerate() {
            if i % 4 == 3 {
                assert_eq!(got, want, "alpha changed at byte {i} ({degrees} deg)");
            } else {
                assert!(
                    (i32::from(got) - i32::from(want)).abs() <= tol,
                    "byte {i}: {got} vs {want} at {degrees} deg"
                );
            }
        }
        free(out);
    }

    // Pure red rotated 120 degrees is approximately green (dominant channel).
    let red = RgbaImage::from_pixel(8, 8, Rgba([255, 0, 0, 200]));
    let rimg = open_pattern(&dir, "red.png", &red);
    let rot = unsafe { rz_image_hue_rotate(rimg, 120.0) };
    assert!(!rot.is_null());
    let [r, g, b, a] = pixel_at(rot, 4, 4);
    assert!(g > r && g > b, "not green-dominant: {:?}", [r, g, b]);
    assert!(g >= 90, "green channel too weak: {g}");
    assert_eq!(a, 200, "alpha changed by hue rotation");
    free(rot);
    free(rimg);

    // Any finite angle is accepted; NaN (and infinities) -> NULL.
    let big = unsafe { rz_image_hue_rotate(img, -1234.5) };
    assert!(!big.is_null());
    free(big);
    assert!(unsafe { rz_image_hue_rotate(img, f32::NAN) }.is_null());
    assert!(unsafe { rz_image_hue_rotate(img, f32::INFINITY) }.is_null());
    assert!(unsafe { rz_image_hue_rotate(img, f32::NEG_INFINITY) }.is_null());
    free(img);
}

#[test]
fn levels_identity_black_point_gamma_and_guards() {
    let dir = tempfile::tempdir().unwrap();
    let pattern = test_pattern(64, 48);
    let img = open_pattern(&dir, "pattern.png", &pattern);
    let src = pattern.as_raw();

    // (0, 1, 1) is the exact identity.
    let same = unsafe { rz_image_levels(img, 0.0, 1.0, 1.0) };
    assert!(!same.is_null());
    assert_eq!(pixels(same), *src, "levels(0,1,1) must be exact identity");
    free(same);

    // black = 0.5 crushes every channel value <= 127 (c/255 <= 0.5) to 0.
    let dark = unsafe { rz_image_levels(img, 0.5, 1.0, 1.0) };
    assert!(!dark.is_null());
    for (i, (&got, &want)) in pixels(dark).iter().zip(src.iter()).enumerate() {
        if i % 4 == 3 {
            assert_eq!(got, want, "alpha changed at byte {i}");
        } else if want <= 127 {
            assert_eq!(got, 0, "byte {i}: input {want} not crushed to 0");
        }
    }
    free(dark);

    // gamma branch: input 0.25 with gamma 2 -> sqrt(0.25) = 0.5 (+-1).
    let gray = RgbaImage::from_pixel(4, 4, Rgba([64, 64, 64, 255]));
    let gimg = open_pattern(&dir, "gray.png", &gray);
    let out = unsafe { rz_image_levels(gimg, 0.0, 1.0, 2.0) };
    assert!(!out.is_null());
    let [r, g, b, a] = pixel_at(out, 2, 2);
    for v in [r, g, b] {
        assert!(
            (127..=129).contains(&v),
            "gamma 2 on 64 gave {v}, want ~128"
        );
    }
    assert_eq!(a, 255);
    free(out);
    free(gimg);

    // Invalid arguments -> NULL.
    for (black, white, gamma) in [
        (0.5f32, 0.5f32, 1.0f32), // black == white
        (0.7, 0.5, 1.0),          // black > white
        (-0.1, 1.0, 1.0),         // black below range
        (0.0, 1.1, 1.0),          // white above range
        (0.0, 1.0, 0.0),          // gamma zero
        (0.0, 1.0, 0.05),         // gamma below range
        (0.0, 1.0, 10.5),         // gamma above range
        (f32::NAN, 1.0, 1.0),
        (0.0, f32::NAN, 1.0),
        (0.0, 1.0, f32::NAN),
    ] {
        assert!(
            unsafe { rz_image_levels(img, black, white, gamma) }.is_null(),
            "levels({black},{white},{gamma}) should be NULL"
        );
    }
    free(img);
}

#[test]
fn threshold_splits_gradient_at_level() {
    let dir = tempfile::tempdir().unwrap();
    // 256 columns of r = g = b = x with an alpha ramp.
    let grad = RgbaImage::from_fn(256, 4, |x, _| {
        Rgba([x as u8, x as u8, x as u8, 255 - (x / 2) as u8])
    });
    let img = open_pattern(&dir, "grad.png", &grad);
    let out = unsafe { rz_image_threshold(img, 0.5) };
    assert!(!out.is_null());
    let src = grad.as_raw();
    for (i, (chunk, sc)) in pixels(out)
        .chunks_exact(4)
        .zip(src.chunks_exact(4))
        .enumerate()
    {
        let x = i % 256;
        // Gray value x has luma x/255, so the split lands between 127 and 128.
        let want = if x >= 128 { 255 } else { 0 };
        assert_eq!(
            &chunk[..3],
            &[want, want, want],
            "column {x} on the wrong side of the threshold"
        );
        assert_eq!(chunk[3], sc[3], "alpha changed at pixel {i}");
    }
    free(out);

    // level 0 sends everything to white (luma >= 0 always).
    let all_white = unsafe { rz_image_threshold(img, 0.0) };
    assert!(!all_white.is_null());
    for (i, chunk) in pixels(all_white).chunks_exact(4).enumerate() {
        assert_eq!(&chunk[..3], &[255, 255, 255], "pixel {i} not white");
    }
    free(all_white);

    // Out-of-range or NaN level -> NULL.
    for level in [-0.1f32, 1.1, f32::NAN] {
        assert!(
            unsafe { rz_image_threshold(img, level) }.is_null(),
            "threshold({level}) should be NULL"
        );
    }
    free(img);
}

#[test]
fn posterize_two_and_sixtyfour_levels() {
    let dir = tempfile::tempdir().unwrap();
    let pattern = test_pattern(64, 48);
    let img = open_pattern(&dir, "pattern.png", &pattern);
    let src = pattern.as_raw();

    // levels = 2 yields only {0, 255} in the color channels.
    let two = unsafe { rz_image_posterize(img, 2) };
    assert!(!two.is_null());
    for (i, (chunk, sc)) in pixels(two)
        .chunks_exact(4)
        .zip(src.chunks_exact(4))
        .enumerate()
    {
        for &c in &chunk[..3] {
            assert!(c == 0 || c == 255, "pixel {i}: {c} not in {{0, 255}}");
        }
        assert_eq!(chunk[3], sc[3], "alpha changed at pixel {i}");
    }
    free(two);

    // levels = 64 is close to the identity (max color delta <= 3).
    let many = unsafe { rz_image_posterize(img, 64) };
    assert!(!many.is_null());
    let mut max_delta = 0i32;
    for (i, (&got, &want)) in pixels(many).iter().zip(src.iter()).enumerate() {
        if i % 4 == 3 {
            assert_eq!(got, want, "alpha changed at byte {i}");
        } else {
            max_delta = max_delta.max((i32::from(got) - i32::from(want)).abs());
        }
    }
    assert!(max_delta <= 3, "64 levels drifted by {max_delta}");
    free(many);

    // Out-of-range level counts -> NULL.
    for levels in [0u32, 1, 65, 1000] {
        assert!(
            unsafe { rz_image_posterize(img, levels) }.is_null(),
            "posterize({levels}) should be NULL"
        );
    }
    free(img);
}

#[test]
fn pixelate_quadrants_identity_and_guards() {
    let dir = tempfile::tempdir().unwrap();
    // 4x4 with four distinct 2x2 quadrants; the bottom-right one is fully
    // transparent with junk color bytes that must not leak into the output.
    let quad = RgbaImage::from_fn(4, 4, |x, y| match (x < 2, y < 2) {
        (true, true) => Rgba([255, 0, 0, 255]),
        (false, true) => Rgba([0, 255, 0, 255]),
        (true, false) => Rgba([0, 0, 255, 255]),
        (false, false) => Rgba([9, 8, 7, 0]),
    });
    let img = open_pattern(&dir, "quad.png", &quad);
    assert_eq!(pixels(img), *quad.as_raw(), "png round trip must be exact");

    let out = unsafe { rz_image_pixelate(img, 2) };
    assert!(!out.is_null());
    assert_eq!(dims(out), (4, 4));
    for y in 0..4 {
        for x in 0..4 {
            let want = match (x < 2, y < 2) {
                (true, true) => [255, 0, 0, 255],
                (false, true) => [0, 255, 0, 255],
                (true, false) => [0, 0, 255, 255],
                // Zero total alpha -> fully transparent black, junk gone.
                (false, false) => [0, 0, 0, 0],
            };
            assert_eq!(pixel_at(out, x, y), want, "cell pixel ({x},{y})");
        }
    }
    free(out);

    // block == 1 is the identity, as a fresh image.
    let one = unsafe { rz_image_pixelate(img, 1) };
    assert!(!one.is_null());
    assert_ne!(
        one as usize, img as usize,
        "block 1 must allocate a new image"
    );
    assert_eq!(pixels(one), pixels(img));
    free(one);

    // Out-of-range block sizes -> NULL.
    for block in [0u32, 1025, 4096] {
        assert!(
            unsafe { rz_image_pixelate(img, block) }.is_null(),
            "pixelate({block}) should be NULL"
        );
    }
    free(img);
}

#[test]
fn pixelate_mean_is_alpha_weighted_and_edges_partial() {
    let dir = tempfile::tempdir().unwrap();
    // One 2x2 cell mixing opaque red, fully transparent junk green,
    // low-alpha blue, and transparent black.
    let mut cell = RgbaImage::new(2, 2);
    cell.put_pixel(0, 0, Rgba([255, 0, 0, 255]));
    cell.put_pixel(1, 0, Rgba([0, 255, 0, 0]));
    cell.put_pixel(0, 1, Rgba([0, 0, 255, 50]));
    cell.put_pixel(1, 1, Rgba([0, 0, 0, 0]));
    let img = open_pattern(&dir, "cell.png", &cell);
    let out = unsafe { rz_image_pixelate(img, 2) };
    assert!(!out.is_null());
    // sum a = 305; r = 255*255/305 = 213.2 -> 213; b = 255*50/305 = 41.8 -> 42;
    // the transparent green contributes nothing; mean alpha = 305/4 -> 76.
    for y in 0..2 {
        for x in 0..2 {
            assert_eq!(pixel_at(out, x, y), [213, 0, 42, 76], "pixel ({x},{y})");
        }
    }
    free(out);
    free(img);

    // Partial edge cells use their actual extent: 3x1 with block 2 averages
    // the first two pixels and leaves the third alone.
    let mut strip = RgbaImage::new(3, 1);
    strip.put_pixel(0, 0, Rgba([100, 0, 0, 255]));
    strip.put_pixel(1, 0, Rgba([200, 0, 0, 255]));
    strip.put_pixel(2, 0, Rgba([50, 60, 70, 255]));
    let simg = open_pattern(&dir, "strip.png", &strip);
    let sout = unsafe { rz_image_pixelate(simg, 2) };
    assert!(!sout.is_null());
    assert_eq!(pixel_at(sout, 0, 0), [150, 0, 0, 255]);
    assert_eq!(pixel_at(sout, 1, 0), [150, 0, 0, 255]);
    assert_eq!(pixel_at(sout, 2, 0), [50, 60, 70, 255]);
    free(sout);
    free(simg);
}

#[test]
fn noise_is_deterministic_bounded_and_validated() {
    let dir = tempfile::tempdir().unwrap();
    let pattern = test_pattern(64, 48);
    let img = open_pattern(&dir, "pattern.png", &pattern);
    let src = pattern.as_raw();

    let a = unsafe { rz_image_noise(img, 0.2, 42) };
    let b = unsafe { rz_image_noise(img, 0.2, 42) };
    let c = unsafe { rz_image_noise(img, 0.2, 43) };
    assert!(!a.is_null() && !b.is_null() && !c.is_null());
    assert_eq!(pixels(a), pixels(b), "same seed must reproduce exactly");
    assert_ne!(pixels(a), pixels(c), "different seeds must differ");
    assert_ne!(pixels(a), *src, "noise at amount 0.2 changed nothing");

    // Bounds: per color channel, |delta| <= round(amount * 255) + 1.
    let bound = (0.2f32 * 255.0).round() as i32 + 1;
    for (i, (&got, &want)) in pixels(a).iter().zip(src.iter()).enumerate() {
        if i % 4 == 3 {
            assert_eq!(got, want, "alpha changed at byte {i}");
        } else {
            assert!(
                (i32::from(got) - i32::from(want)).abs() <= bound,
                "byte {i}: {got} deviates from {want} beyond {bound}"
            );
        }
    }
    free(a);
    free(b);
    free(c);

    // Full-strength noise is still valid.
    let full = unsafe { rz_image_noise(img, 1.0, 7) };
    assert!(!full.is_null());
    free(full);

    // amount outside (0, 1] or NaN -> NULL.
    for amount in [0.0f32, -0.2, 1.5, f32::NAN] {
        assert!(
            unsafe { rz_image_noise(img, amount, 42) }.is_null(),
            "noise({amount}) should be NULL"
        );
    }
    free(img);
}

#[test]
fn edge_detect_flat_and_step() {
    let dir = tempfile::tempdir().unwrap();

    // A flat image (even a translucent one) has no edges: opaque black out.
    let flat = RgbaImage::from_pixel(16, 12, Rgba([80, 160, 240, 128]));
    let img = open_pattern(&dir, "flat.png", &flat);
    let out = unsafe { rz_image_edge_detect(img) };
    assert!(!out.is_null());
    assert_eq!(dims(out), (16, 12));
    for (i, chunk) in pixels(out).chunks_exact(4).enumerate() {
        assert_eq!(chunk, &[0, 0, 0, 255], "pixel {i} of flat image");
    }
    free(out);
    free(img);

    // A vertical black->white step at x == 8 lights exactly the two columns
    // adjacent to the step (Sobel gx saturates); output is opaque gray.
    let step = RgbaImage::from_fn(16, 12, |x, _| {
        if x < 8 {
            Rgba([0, 0, 0, 255])
        } else {
            Rgba([255, 255, 255, 255])
        }
    });
    let simg = open_pattern(&dir, "step.png", &step);
    let sout = unsafe { rz_image_edge_detect(simg) };
    assert!(!sout.is_null());
    for (i, chunk) in pixels(sout).chunks_exact(4).enumerate() {
        let x = i % 16;
        assert!(
            chunk[0] == chunk[1] && chunk[1] == chunk[2],
            "pixel {i} not gray: {chunk:?}"
        );
        assert_eq!(chunk[3], 255, "pixel {i} not opaque");
        let want = if x == 7 || x == 8 { 255 } else { 0 };
        assert_eq!(chunk[0], want, "column {x} magnitude");
    }
    free(sout);
    free(simg);
}

#[test]
fn emboss_flat_black_is_mid_gray() {
    let dir = tempfile::tempdir().unwrap();
    let flat = RgbaImage::from_pixel(8, 8, Rgba([0, 0, 0, 255]));
    let img = open_pattern(&dir, "black.png", &flat);
    let out = unsafe { rz_image_emboss(img) };
    assert!(!out.is_null());
    assert_eq!(dims(out), (8, 8));
    for (i, chunk) in pixels(out).chunks_exact(4).enumerate() {
        assert!(
            chunk[0] == chunk[1] && chunk[1] == chunk[2],
            "pixel {i} not gray: {chunk:?}"
        );
        assert!(
            (127..=128).contains(&chunk[0]),
            "pixel {i}: {} not mid-gray",
            chunk[0]
        );
        assert_eq!(chunk[3], 255, "pixel {i} not opaque");
    }
    free(out);
    free(img);
}

#[test]
fn null_safety_all_filters() {
    let null: *const RzImage = ptr::null();
    assert!(unsafe { rz_image_hue_rotate(null, 30.0) }.is_null());
    assert!(unsafe { rz_image_levels(null, 0.0, 1.0, 1.0) }.is_null());
    assert!(unsafe { rz_image_threshold(null, 0.5) }.is_null());
    assert!(unsafe { rz_image_posterize(null, 4) }.is_null());
    assert!(unsafe { rz_image_pixelate(null, 4) }.is_null());
    assert!(unsafe { rz_image_noise(null, 0.5, 1) }.is_null());
    assert!(unsafe { rz_image_edge_detect(null) }.is_null());
    assert!(unsafe { rz_image_emboss(null) }.is_null());
}
