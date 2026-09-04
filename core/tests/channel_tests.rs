//! Alpha channels and colour planes, exercised through the public C FFI
//! (the header's "Channels" section): the channel list and its two caps, the
//! plane readers and the plane writer, coverage painting, plane arithmetic,
//! the luminosity masks, RZDC version 5 and the geometry ops.
//!
//! Oracles are analytic and written here, independently of the
//! implementation: the W3C reference blend from `tests/common` for the
//! arithmetic, the Rec. 709 definition for luma, index permutations written
//! out by hand for the geometry, and the "white paints toward 255 by the
//! coverage fraction" identity for painting (a WHITE premultiplied overlay
//! has luma exactly 255 whatever its alpha, so the lerp reduces to a formula
//! with no rounding of its own). No golden images anywhere.

use std::ffi::{c_char, c_int, CStr, CString};
use std::ptr;
use std::sync::Arc;

use image::{GrayImage, Rgba, RgbaImage};
use rasterize_core::doc::RzDocument;
use rasterize_core::doc_channel::Channel;
use rasterize_core::ffi::*;
use rasterize_core::ffi_channel::*;
use rasterize_core::ffi_doc::*;
use rasterize_core::RzImage;
use tempfile::TempDir;

mod common;
use common::*;

// The RzPlane values, mirrored from the header the way `common` mirrors
// RzBlendMode.
const PLANE_RED: c_int = 0;
const PLANE_GREEN: c_int = 1;
const PLANE_BLUE: c_int = 2;
const PLANE_ALPHA: c_int = 3;
const PLANE_LUMA: c_int = 4;
const PLANE_MASK: c_int = 5;

/// Rec. 709, restated here rather than imported, so the tests do not agree
/// with the core by construction.
const REF_LUMA: [f32; 3] = [0.2126, 0.7152, 0.0722];

// ------------------------------------------------------------- FFI shims --

fn doc_dims(doc: *const RzDocument) -> (u32, u32) {
    unsafe { (rz_doc_width(doc), rz_doc_height(doc)) }
}

fn channel_count(doc: *const RzDocument) -> usize {
    unsafe { rz_doc_channel_count(doc) }
}

fn channel_name(doc: *const RzDocument, i: usize) -> String {
    let p = unsafe { rz_doc_channel_name(doc, i) };
    assert!(!p.is_null(), "channel_name({i}) NULL");
    let s = unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned();
    unsafe { rz_string_free(p) };
    s
}

/// (colour, opacity, polarity) for one channel.
fn channel_overlay(doc: *const RzDocument, i: usize) -> ([u8; 3], f32, bool) {
    let mut rgb = [0u8; 3];
    assert!(
        unsafe { rz_doc_channel_overlay_color(doc, i, rgb.as_mut_ptr()) },
        "overlay_color({i}) failed"
    );
    unsafe {
        (
            rgb,
            rz_doc_channel_overlay_opacity(doc, i),
            rz_doc_channel_color_indicates_selected(doc, i),
        )
    }
}

fn channel_plane(doc: *const RzDocument, i: usize) -> Vec<u8> {
    let (w, h) = doc_dims(doc);
    let mut out = vec![0u8; (w as usize) * (h as usize)];
    assert!(
        unsafe { rz_doc_channel_plane(doc, i, out.as_mut_ptr(), w, h) },
        "channel_plane({i}) failed"
    );
    out
}

fn composite_plane(doc: *const RzDocument, plane: c_int) -> Option<Vec<u8>> {
    let (w, h) = doc_dims(doc);
    let mut out = vec![0u8; (w as usize) * (h as usize)];
    let ok = unsafe { rz_doc_composite_plane(doc, plane, out.as_mut_ptr(), w, h) };
    ok.then_some(out)
}

fn layer_plane(doc: *const RzDocument, idx: usize, plane: c_int) -> Option<Vec<u8>> {
    let (w, h) = doc_dims(doc);
    let mut out = vec![0u8; (w as usize) * (h as usize)];
    let ok = unsafe { rz_doc_layer_plane(doc, idx, plane, out.as_mut_ptr(), w, h) };
    ok.then_some(out)
}

fn image_plane(img: *const RzImage, plane: c_int) -> Option<Vec<u8>> {
    let (w, h) = img_dims(img);
    let mut out = vec![0u8; (w as usize) * (h as usize)];
    let ok = unsafe { rz_image_plane(img, plane, out.as_mut_ptr(), w, h) };
    ok.then_some(out)
}

/// Appends a channel, asserting success and freeing the old handle.
fn add_channel(doc: *mut RzDocument, name: &str, plane: &[u8], w: u32, h: u32) -> *mut RzDocument {
    let c = CString::new(name).expect("no interior NUL");
    apply(doc, |d| unsafe {
        rz_doc_add_channel(d, c.as_ptr(), plane.as_ptr(), w, h, 255, 0, 0, 0.5)
    })
}

/// The same, returning `None` on a refusal instead of asserting.
fn try_add_channel(
    doc: *const RzDocument,
    name: &str,
    plane: &[u8],
    w: u32,
    h: u32,
) -> Option<*mut RzDocument> {
    let c = CString::new(name).expect("no interior NUL");
    let out = unsafe { rz_doc_add_channel(doc, c.as_ptr(), plane.as_ptr(), w, h, 0, 0, 0, 1.0) };
    (!out.is_null()).then_some(out)
}

/// A varied canvas-sized coverage plane: no symmetry in either axis, so a
/// transposed or mirrored result cannot pass by accident.
fn asymmetric_plane(w: u32, h: u32) -> Vec<u8> {
    (0..h)
        .flat_map(|y| (0..w).map(move |x| ((x * 37 + y * 11 + x * y * 3) % 251) as u8))
        .collect()
}

/// A canvas-frame PREMULTIPLIED RGBA8 overlay of one colour at a per-pixel
/// alpha — what the app's stroke pipeline hands the paint FFI.
fn overlay(w: u32, h: u32, color: [u8; 3], alpha: impl Fn(u32, u32) -> u8) -> Vec<u8> {
    let mut out = Vec::with_capacity((w * h * 4) as usize);
    for y in 0..h {
        for x in 0..w {
            let a = alpha(x, y);
            for c in color {
                out.push(((u32::from(c) * u32::from(a)) / 255) as u8);
            }
            out.push(a);
        }
    }
    out
}

// -------------------------------------------------------- plane arithmetic --

/// The independent oracle for `rz_blend_planes`: invert first, blend with the
/// W3C reference from `tests/common`, then fade by opacity.
fn ref_blend_plane(b: u8, s: u8, mode: c_int, opacity: f32, invert_b: bool, invert_s: bool) -> u8 {
    let bv = if invert_b { 255 - b } else { b };
    let sv = if invert_s { 255 - s } else { s };
    let bf = f32::from(bv) / 255.0;
    let sf = f32::from(sv) / 255.0;
    let blended = ref_blend(mode, bf, sf);
    let out = opacity * blended + (1.0 - opacity) * bf;
    (out.clamp(0.0, 1.0) * 255.0).round() as u8
}

fn blended(base: &[u8], source: &[u8], w: u32, h: u32, mode: c_int, opacity: f32) -> Vec<u8> {
    let mut out = base.to_vec();
    assert!(
        unsafe {
            rz_blend_planes(
                out.as_mut_ptr(),
                source.as_ptr(),
                w,
                h,
                mode,
                opacity,
                false,
                false,
            )
        },
        "rz_blend_planes refused a well-formed call"
    );
    out
}

#[test]
fn blend_planes_matches_the_reference_for_multiply_and_screen() {
    let (w, h) = (64u32, 32u32);
    // Left half black, right half white — the two ends of every formula.
    let base: Vec<u8> = (0..h)
        .flat_map(|_| (0..w).map(|x| if x < w / 2 { 0u8 } else { 255 }))
        .collect();
    let source = vec![128u8; (w * h) as usize];

    for &mode in &[BLEND_MULTIPLY, BLEND_SCREEN, BLEND_NORMAL, BLEND_OVERLAY] {
        for &opacity in &[1.0f32, 0.5, 0.0] {
            let got = blended(&base, &source, w, h, mode, opacity);
            for (i, &v) in got.iter().enumerate() {
                let want = ref_blend_plane(base[i], source[i], mode, opacity, false, false);
                assert_eq!(v, want, "mode {mode} opacity {opacity} at {i}");
            }
        }
    }

    // The named landmarks, spelled out so a change to the reference cannot
    // quietly move the answer with the implementation.
    let multiply = blended(&base, &source, w, h, BLEND_MULTIPLY, 1.0);
    assert_eq!(multiply[0], 0, "multiply against black is black");
    assert_eq!(
        multiply[(w - 1) as usize],
        128,
        "multiply against white is the source"
    );
    let screen = blended(&base, &source, w, h, BLEND_SCREEN, 1.0);
    assert_eq!(screen[0], 128, "screen against black is the source");
    assert_eq!(
        screen[(w - 1) as usize],
        255,
        "screen against white is white"
    );
    // Opacity 0 is the identity, which also proves the lerp direction.
    assert_eq!(
        blended(&base, &source, w, h, BLEND_MULTIPLY, 0.0),
        base,
        "opacity 0 leaves the base alone"
    );
}

#[test]
fn blend_planes_inverts_an_operand_before_blending_and_lerping() {
    let (w, h) = (16u32, 8u32);
    let base = asymmetric_plane(w, h);
    let source: Vec<u8> = base.iter().map(|&v| v.wrapping_mul(3)).collect();

    for &(invert_b, invert_s) in &[(true, false), (false, true), (true, true)] {
        for &mode in &[BLEND_NORMAL, BLEND_MULTIPLY, BLEND_DIFFERENCE] {
            let mut got = base.clone();
            assert!(unsafe {
                rz_blend_planes(
                    got.as_mut_ptr(),
                    source.as_ptr(),
                    w,
                    h,
                    mode,
                    0.5,
                    invert_b,
                    invert_s,
                )
            });
            for (i, &v) in got.iter().enumerate() {
                let want = ref_blend_plane(base[i], source[i], mode, 0.5, invert_b, invert_s);
                assert_eq!(v, want, "invert {invert_b}/{invert_s} mode {mode} at {i}");
            }
        }
    }

    // Normal with an inverted base is the sharpest statement of the rule:
    // the COMPLEMENT is both the blend input and the value lerped from.
    let mut got = base.clone();
    assert!(unsafe {
        rz_blend_planes(
            got.as_mut_ptr(),
            source.as_ptr(),
            w,
            h,
            BLEND_NORMAL,
            0.5,
            true,
            false,
        )
    });
    for (i, &v) in got.iter().enumerate() {
        let complement = f32::from(255 - base[i]) / 255.0;
        let s = f32::from(source[i]) / 255.0;
        let want = ((0.5 * s + 0.5 * complement).clamp(0.0, 1.0) * 255.0).round() as u8;
        assert_eq!(v, want, "lerp(255 - b, s, 0.5) at {i}");
    }
}

// ------------------------------------------------------------- plane reads --

#[test]
fn composite_and_image_planes_read_the_expected_values() {
    let dir = TempDir::new().unwrap();
    let color = [64u8, 128, 192, 255];
    let doc = doc_from(&dir, "solid.png", &solid(9, 5, color));

    for (plane, want) in [
        (PLANE_RED, color[0]),
        (PLANE_GREEN, color[1]),
        (PLANE_BLUE, color[2]),
        (PLANE_ALPHA, color[3]),
    ] {
        let got = composite_plane(doc, plane).expect("plane");
        assert!(
            got.iter().all(|&v| v == want),
            "plane {plane} must be {want} everywhere"
        );
    }

    let luma = (REF_LUMA[0] * f32::from(color[0])
        + REF_LUMA[1] * f32::from(color[1])
        + REF_LUMA[2] * f32::from(color[2]))
    .round() as u8;
    assert_eq!(luma, 119, "the Rec. 709 luma of #4080C0");
    let got = composite_plane(doc, PLANE_LUMA).expect("luma plane");
    assert!(got.iter().all(|&v| v == luma), "luma plane");

    // The composite has no mask.
    assert!(
        composite_plane(doc, PLANE_MASK).is_none(),
        "RZ_PLANE_MASK is not a composite plane"
    );

    // Reading the same planes back off the flattened IMAGE must agree byte
    // for byte — that equality is what lets a host read a cached projection
    // instead of re-flattening.
    let flat = unsafe { rz_doc_flattened(doc) };
    assert!(!flat.is_null());
    for plane in [PLANE_RED, PLANE_GREEN, PLANE_BLUE, PLANE_ALPHA, PLANE_LUMA] {
        assert_eq!(
            image_plane(flat, plane).expect("image plane"),
            composite_plane(doc, plane).expect("composite plane"),
            "image plane {plane} must equal the composite plane"
        );
    }
    assert!(
        image_plane(flat, PLANE_MASK).is_none(),
        "an image has no mask"
    );

    // A plane image is opaque grayscale, and its LUMA reads the plane back
    // losslessly — the round trip every filter-on-a-plane depends on.
    let gray = unsafe { rz_image_plane_image(flat, PLANE_GREEN, 0) };
    assert!(!gray.is_null());
    assert_eq!(img_dims(gray), (9, 5));
    for px in img_pixels(gray).chunks_exact(4) {
        assert_eq!([px[1], px[2], px[3]], [px[0], px[0], 255]);
        assert_eq!(px[0], color[1]);
    }
    assert_eq!(
        image_plane(gray, PLANE_LUMA).expect("luma of a gray image"),
        vec![color[1]; 45],
        "luma is the identity on an opaque grayscale image"
    );
    // And it is the identity for EVERY byte value, which is the whole basis
    // of the plane round trip (plane -> gray image -> op -> luma -> plane).
    let ramp = RgbaImage::from_fn(256, 1, |x, _| {
        let v = x as u8;
        Rgba([v, v, v, 255])
    });
    let ramp_img = open_image(&dir, "ramp.png", &ramp);
    assert_eq!(
        image_plane(ramp_img, PLANE_LUMA).expect("luma of the ramp"),
        (0..=255u8).collect::<Vec<_>>(),
        "luma round-trips every grey value"
    );
    unsafe { rz_image_free(ramp_img) };
    // max_side aspect-fits, like a layer thumbnail.
    let thumb = unsafe { rz_image_plane_image(flat, PLANE_GREEN, 3) };
    assert!(!thumb.is_null());
    assert_eq!(img_dims(thumb), (3, 2));

    unsafe {
        rz_image_free(thumb);
        rz_image_free(gray);
        rz_image_free(flat);
        rz_doc_free(doc);
    }
}

/// A plane THUMBNAIL downsamples the plane and expands it to grayscale
/// afterwards, which is what keeps a panel's per-row thumbnail off a
/// canvas-sized RGBA buffer. The claim that makes that safe is that the two
/// orders are the same arithmetic — every tap has r == g == b and alpha is a
/// constant 255 — so this pins it: the thumbnail must be byte-identical to
/// the full-size plane image put through the same Triangle resize.
#[test]
fn a_plane_thumbnail_equals_the_full_plane_image_resampled() {
    let dir = TempDir::new().unwrap();
    let img = open_image(&dir, "thumb.png", &opaque_pattern(40, 24));
    let full = unsafe { rz_image_plane_image(img, PLANE_RED, 0) };
    assert!(!full.is_null());
    let thumb = unsafe { rz_image_plane_image(img, PLANE_RED, 11) };
    assert!(!thumb.is_null());
    // The shared aspect-fit rule: the longest side is max_side.
    assert_eq!(img_dims(thumb), (11, 7));
    let resized = unsafe { rz_image_resize(full, 11, 7, FILTER_BILINEAR) };
    assert!(!resized.is_null());
    assert_eq!(
        img_pixels(thumb),
        img_pixels(resized),
        "downsampling the plane and downsampling its grayscale image agree"
    );
    for px in img_pixels(thumb).chunks_exact(4) {
        assert_eq!(
            [px[1], px[2], px[3]],
            [px[0], px[0], 255],
            "opaque grayscale"
        );
    }

    // The channel row's own thumbnail source takes the same path.
    let doc = doc_from(&dir, "thumb-doc.png", &opaque_pattern(40, 24));
    let plane = asymmetric_plane(40, 24);
    let doc = add_channel(doc, "Sky", &plane, 40, 24);
    let channel_full = unsafe { rz_doc_channel_image(doc, 0, 0) };
    let channel_thumb = unsafe { rz_doc_channel_image(doc, 0, 11) };
    assert!(!channel_full.is_null() && !channel_thumb.is_null());
    assert_eq!(img_dims(channel_thumb), (11, 7));
    let channel_resized = unsafe { rz_image_resize(channel_full, 11, 7, FILTER_BILINEAR) };
    assert_eq!(img_pixels(channel_thumb), img_pixels(channel_resized));

    unsafe {
        rz_image_free(channel_resized);
        rz_image_free(channel_thumb);
        rz_image_free(channel_full);
        rz_doc_free(doc);
        rz_image_free(resized);
        rz_image_free(thumb);
        rz_image_free(full);
        rz_image_free(img);
    }
}

/// A BIG reduction (a panel thumbnail of a real canvas) takes the two-step
/// path — whole boxes averaged straight out of the plane, then the resampling
/// kernel over the small intermediate — because one kernel pass over a
/// canvas-sized plane costs ~2 weighted taps per SOURCE pixel however small
/// the thumbnail is, per channel row, per document change. Three claims make
/// the shortcut safe, and each is pinned here:
///
/// * the picture is the one a single full-kernel pass gives (2/255 at worst);
/// * a box divides by the samples it actually covered, so a constant plane
///   thumbnails to that constant even where the boxes overhang the canvas
///   (203 x 121 is chosen so they do, in both axes);
/// * the box AVERAGES rather than sampling every k-th byte — a plane whose
///   only marks sit away from the box origins must still show them.
#[test]
fn a_big_plane_thumbnail_agrees_with_the_full_kernel() {
    let dir = TempDir::new().unwrap();
    let (w, h) = (203u32, 121u32);
    let doc = doc_from(&dir, "big-thumb.png", &opaque_pattern(w, h));
    let doc = add_channel(doc, "Sky", &asymmetric_plane(w, h), w, h);
    let doc = add_channel(doc, "Flat", &vec![200u8; (w * h) as usize], w, h);
    let full = unsafe { rz_doc_channel_image(doc, 0, 0) };
    let thumb = unsafe { rz_doc_channel_image(doc, 0, 11) };
    assert!(!full.is_null() && !thumb.is_null());
    assert_eq!(img_dims(thumb), (11, 7), "the shared aspect-fit rule");
    let kernel = unsafe { rz_image_resize(full, 11, 7, FILTER_BILINEAR) };
    assert!(!kernel.is_null());
    let worst = img_pixels(thumb)
        .iter()
        .zip(img_pixels(kernel).iter())
        .map(|(a, b)| i32::from(*a).abs_diff(i32::from(*b)))
        .max()
        .expect("a non-empty thumbnail");
    assert!(
        worst <= 2,
        "the two-step thumbnail drifts {worst}/255 from the single kernel pass"
    );
    for px in img_pixels(thumb).chunks_exact(4) {
        assert_eq!(
            [px[1], px[2], px[3]],
            [px[0], px[0], 255],
            "still opaque grayscale"
        );
    }
    // The overhanging boxes: 203 = 50 * 4 + 3 and 121 = 30 * 4 + 1, so the
    // last column and row of boxes are partial. Dividing those by the full
    // box area instead of their own count would darken the two edges.
    let flat = unsafe { rz_doc_channel_image(doc, 1, 11) };
    assert!(!flat.is_null());
    for px in img_pixels(flat).chunks_exact(4) {
        assert_eq!(px[0], 200, "a constant plane thumbnails to that constant");
    }

    // Marks at (x % 4 == 3, y % 4 == 3) only: never at a box origin, so
    // sampling every 4th byte would answer an all-black thumbnail. The mean
    // of each 4 x 4 box is exactly 255 / 16 = 15.9375 -> 16, and a resize of
    // a constant image is that constant, so the whole thumbnail must be 16.
    // 200 x 120 divides by 4 exactly, which is what makes every box full.
    let (gw, gh) = (200u32, 120u32);
    let grid: Vec<u8> = (0..gh)
        .flat_map(|y| (0..gw).map(move |x| if x % 4 == 3 && y % 4 == 3 { 255 } else { 0 }))
        .collect();
    let grid_doc = doc_from(&dir, "grid-thumb.png", &opaque_pattern(gw, gh));
    let grid_doc = add_channel(grid_doc, "Grid", &grid, gw, gh);
    let grid_thumb = unsafe { rz_doc_channel_image(grid_doc, 0, 11) };
    assert!(!grid_thumb.is_null());
    assert_eq!(img_dims(grid_thumb), (11, 7));
    for px in img_pixels(grid_thumb).chunks_exact(4) {
        assert_eq!(px[0], 16, "every box averages what it covers");
    }

    unsafe {
        rz_image_free(grid_thumb);
        rz_doc_free(grid_doc);
        rz_image_free(flat);
        rz_image_free(kernel);
        rz_image_free(thumb);
        rz_image_free(full);
        rz_doc_free(doc);
    }
}

#[test]
fn layer_planes_are_canvas_sized_and_zero_outside_the_layer() {
    let dir = TempDir::new().unwrap();
    // Opaque red canvas under a 3x2 blue layer at (4, 1) on an 8x5 canvas.
    let doc = ffi_mask_fixture(&dir, "lp", (8, 5), (3, 2), (4, 1));

    let red = layer_plane(doc, 1, PLANE_RED).expect("red plane");
    let blue = layer_plane(doc, 1, PLANE_BLUE).expect("blue plane");
    let alpha = layer_plane(doc, 1, PLANE_ALPHA).expect("alpha plane");
    for y in 0..5u32 {
        for x in 0..8u32 {
            let i = (y * 8 + x) as usize;
            let inside = (4..7).contains(&x) && (1..3).contains(&y);
            assert_eq!(red[i], 0, "the blue layer has no red at ({x}, {y})");
            assert_eq!(blue[i], if inside { 255 } else { 0 }, "blue at ({x}, {y})");
            assert_eq!(
                alpha[i],
                if inside { 255 } else { 0 },
                "alpha at ({x}, {y})"
            );
        }
    }

    // No mask yet.
    assert!(
        layer_plane(doc, 1, PLANE_MASK).is_none(),
        "a layer with no mask has no mask plane"
    );
    let sel = selection(8, 5, |x, y| ((x * 31 + y * 7) % 256) as u8);
    let masked = apply(doc, |d| unsafe {
        rz_doc_adding_layer_mask(d, 1, MASK_FROM_SELECTION, sel.as_ptr(), 8, 5)
    });
    let mask = layer_plane(masked, 1, PLANE_MASK).expect("mask plane");
    for y in 0..5u32 {
        for x in 0..8u32 {
            let i = (y * 8 + x) as usize;
            let inside = (4..7).contains(&x) && (1..3).contains(&y);
            assert_eq!(
                mask[i],
                if inside { sel[i] } else { 0 },
                "the mask plane is canvas-sized with 0 outside the layer at ({x}, {y})"
            );
        }
    }
    assert!(
        layer_plane(masked, 9, PLANE_RED).is_none(),
        "an out-of-range layer has no plane"
    );
    unsafe { rz_doc_free(masked) };
}

// ------------------------------------------------------------ plane writes --

#[test]
fn with_layer_plane_replaces_one_plane_and_refuses_a_no_op() {
    let dir = TempDir::new().unwrap();
    let img = test_pattern(6, 4);
    let doc = doc_from(&dir, "wl.png", &img);
    let before = layer_pixels(doc, 0);

    let mut red = layer_plane(doc, 0, PLANE_RED).expect("red");
    for v in red.iter_mut() {
        *v = 255 - *v;
    }
    let out = unsafe { rz_doc_with_layer_plane(doc, 0, PLANE_RED, red.as_ptr(), 6, 4) };
    assert!(!out.is_null(), "writing a changed red plane must succeed");
    let after = layer_pixels(out, 0);
    for i in 0..(6 * 4) {
        assert_eq!(after[i * 4], 255 - before[i * 4], "red inverted at {i}");
        assert_eq!(
            &after[i * 4 + 1..i * 4 + 4],
            &before[i * 4 + 1..i * 4 + 4],
            "green, blue and alpha untouched at {i}"
        );
    }

    // Writing a plane back unchanged is not an edit (the purity rule the
    // multi-plane callers depend on).
    let same = layer_plane(doc, 0, PLANE_RED).expect("red");
    assert!(
        unsafe { rz_doc_with_layer_plane(doc, 0, PLANE_RED, same.as_ptr(), 6, 4) }.is_null(),
        "an unchanged plane write must refuse"
    );

    // Alpha writes STRAIGHT alpha and zeroes the colour of pixels it clears.
    let zero = [0u8; 24];
    let cleared = unsafe { rz_doc_with_layer_plane(doc, 0, PLANE_ALPHA, zero.as_ptr(), 6, 4) };
    assert!(!cleared.is_null());
    assert!(
        layer_pixels(cleared, 0).iter().all(|&v| v == 0),
        "alpha 0 drops the colour bytes too"
    );

    // The derived planes are not writable.
    for plane in [PLANE_LUMA, PLANE_MASK] {
        assert!(
            unsafe { rz_doc_with_layer_plane(doc, 0, plane, zero.as_ptr(), 6, 4) }.is_null(),
            "plane {plane} is read-only"
        );
    }
    // Dimensions must be the canvas's.
    assert!(
        unsafe { rz_doc_with_layer_plane(doc, 0, PLANE_RED, zero.as_ptr(), 4, 6) }.is_null(),
        "a non-canvas size is refused"
    );

    unsafe {
        rz_doc_free(cleared);
        rz_doc_free(out);
        rz_doc_free(doc);
    }
}

/// The layer-space writer covers the WHOLE layer, including the ring that
/// hangs off the canvas — which is the difference from its canvas-sized
/// sibling, and the reason a filter on one colour plane uses it. Both writers
/// are driven with the same inversion here, so the ring is the only thing
/// that can tell them apart.
#[test]
fn with_layer_space_plane_rewrites_the_whole_layer_including_its_off_canvas_ring() {
    let dir = TempDir::new().unwrap();
    // A 6x4 canvas under an 8x6 layer at (-1, -1): the layer hangs over every
    // edge, so 8x6 - 6x4 = 24 of its pixels are off-canvas.
    let doc = doc_from(&dir, "ls-bg.png", &solid(6, 4, RED));
    let doc = add_layer(&dir, "ls-top.png", doc, 0, &test_pattern(8, 6), "Top");
    let doc = apply(doc, |d| unsafe { rz_doc_with_layer_offset(d, 1, -1, -1) });
    assert_eq!(layer_dims(doc, 1), (8, 6));

    let img = unsafe { rz_doc_layer_image(doc, 1) };
    assert!(!img.is_null());
    let before = img_pixels(img);
    let red = image_plane(img, PLANE_RED).expect("layer-space red");
    unsafe { rz_image_free(img) };
    assert_eq!(red.len(), 8 * 6);
    let inverted: Vec<u8> = red.iter().map(|&v| 255 - v).collect();

    let out = unsafe { rz_doc_with_layer_space_plane(doc, 1, PLANE_RED, inverted.as_ptr(), 8, 6) };
    assert!(!out.is_null(), "a layer-sized write must succeed");
    let after = layer_pixels(out, 1);
    for i in 0..(8 * 6) {
        assert_eq!(after[i * 4], 255 - before[i * 4], "red inverted at {i}");
        assert_eq!(
            &after[i * 4 + 1..i * 4 + 4],
            &before[i * 4 + 1..i * 4 + 4],
            "green, blue and alpha untouched at {i}"
        );
    }

    // The canvas-sized sibling, handed the same inversion canvas-sized, gets
    // the on-canvas window right and leaves the ring alone. That is correct
    // for Apply Image and wrong for a filter, which is why both exist.
    let canvas_red = layer_plane(doc, 1, PLANE_RED).expect("canvas-sized red");
    let canvas_inverted: Vec<u8> = canvas_red.iter().map(|&v| 255 - v).collect();
    let clipped =
        unsafe { rz_doc_with_layer_plane(doc, 1, PLANE_RED, canvas_inverted.as_ptr(), 6, 4) };
    assert!(!clipped.is_null());
    let clipped_pixels = layer_pixels(clipped, 1);
    // Layer pixel (0, 0) sits at canvas (-1, -1): off-canvas, so only the
    // layer-space writer reaches it.
    assert_eq!(
        clipped_pixels[0], before[0],
        "the canvas-sized writer leaves the off-canvas ring alone"
    );
    assert_eq!(
        after[0],
        255 - before[0],
        "the layer-space writer rewrites it"
    );
    // Layer pixel (1, 1) sits at canvas (0, 0): both writers reach it.
    let inside = (8 + 1) * 4;
    assert_eq!(clipped_pixels[inside], 255 - before[inside]);
    assert_eq!(after[inside], 255 - before[inside]);

    // Refusals: the CANVAS size is not the layer's, the derived planes are
    // read-only, an unchanged buffer is not an edit, and the index is checked.
    assert!(
        unsafe { rz_doc_with_layer_space_plane(doc, 1, PLANE_RED, inverted.as_ptr(), 6, 4) }
            .is_null(),
        "a canvas-sized buffer is refused by the layer-space writer"
    );
    for plane in [PLANE_LUMA, PLANE_MASK] {
        assert!(
            unsafe { rz_doc_with_layer_space_plane(doc, 1, plane, inverted.as_ptr(), 8, 6) }
                .is_null(),
            "plane {plane} is read-only"
        );
    }
    assert!(
        unsafe { rz_doc_with_layer_space_plane(doc, 1, PLANE_RED, red.as_ptr(), 8, 6) }.is_null(),
        "writing the plane back unchanged is not an edit"
    );
    assert!(
        unsafe { rz_doc_with_layer_space_plane(doc, 9, PLANE_RED, inverted.as_ptr(), 8, 6) }
            .is_null(),
        "an out-of-range layer is refused"
    );

    // Alpha keeps the straight-alpha rule its sibling states: a pixel written
    // to alpha 0 loses its colour bytes too.
    let zero = [0u8; 8 * 6];
    let cleared =
        unsafe { rz_doc_with_layer_space_plane(doc, 1, PLANE_ALPHA, zero.as_ptr(), 8, 6) };
    assert!(!cleared.is_null());
    assert!(
        layer_pixels(cleared, 1).iter().all(|&v| v == 0),
        "alpha 0 drops the colour bytes over the whole layer"
    );

    unsafe {
        rz_doc_free(cleared);
        rz_doc_free(clipped);
        rz_doc_free(out);
        rz_doc_free(doc);
    }
}

// ------------------------------------------------------- coverage painting --

#[test]
fn painting_a_channel_lerps_toward_white_by_the_coverage() {
    let dir = TempDir::new().unwrap();
    let (w, h) = (8u32, 5u32);
    let doc = doc_from(&dir, "pc.png", &solid(w, h, RED));
    let start = vec![40u8; (w * h) as usize];
    let doc = add_channel(doc, "Alpha 1", &start, w, h);

    // White at a per-pixel alpha: a white premultiplied pixel has luma
    // exactly 255 at ANY alpha, so v' = round(v + (255 - v) * a / 255)
    // with no rounding of the luma itself.
    let alpha = |x: u32, y: u32| if y == 0 { 0 } else { ((x * 32) % 256) as u8 };
    let ov = overlay(w, h, [255, 255, 255], alpha);
    let painted = unsafe { rz_doc_painting_channel(doc, 0, ov.as_ptr(), w, h) };
    assert!(!painted.is_null(), "a covering stroke must paint");
    let got = channel_plane(painted, 0);
    for y in 0..h {
        for x in 0..w {
            let i = (y * w + x) as usize;
            let a = f32::from(alpha(x, y)) / 255.0;
            let want = (40.0 + (255.0 - 40.0) * a).round() as u8;
            assert_eq!(got[i], want, "white at ({x}, {y})");
            if alpha(x, y) == 0 {
                assert_eq!(got[i], 40, "an uncovered pixel is byte-identical");
            }
        }
    }

    // Black paints the other way: v' = round(v * (1 - a)).
    let ov = overlay(w, h, [0, 0, 0], |_, _| 128);
    let dark = unsafe { rz_doc_painting_channel(painted, 0, ov.as_ptr(), w, h) };
    assert!(!dark.is_null());
    let before = got;
    let after = channel_plane(dark, 0);
    for i in 0..before.len() {
        let want = (f32::from(before[i]) * (1.0 - 128.0 / 255.0)).round() as u8;
        assert_eq!(after[i], want, "black at {i}");
    }

    unsafe {
        rz_doc_free(dark);
        rz_doc_free(painted);
        rz_doc_free(doc);
    }
}

#[test]
fn painting_a_layer_plane_maps_through_the_layer_offset() {
    let dir = TempDir::new().unwrap();
    // A 4x4 layer at (-1, -1) on a 6x5 canvas: its first row and column hang
    // off the canvas and can never be reached by a canvas-frame overlay.
    let doc = ffi_mask_fixture(&dir, "plp", (6, 5), (4, 4), (-1, -1));
    let before = layer_pixels(doc, 1);

    let ov = overlay(6, 5, [255, 255, 255], |_, _| 255);
    let painted = unsafe { rz_doc_painting_layer_plane(doc, 1, PLANE_RED, ov.as_ptr(), 6, 5) };
    assert!(!painted.is_null());
    let after = layer_pixels(painted, 1);
    for ly in 0..4u32 {
        for lx in 0..4u32 {
            let i = ((ly * 4 + lx) * 4) as usize;
            let on_canvas = lx >= 1 && ly >= 1;
            assert_eq!(
                after[i],
                if on_canvas { 255 } else { before[i] },
                "red at layer ({lx}, {ly})"
            );
            assert_eq!(
                &after[i + 1..i + 4],
                &before[i + 1..i + 4],
                "only the red byte moves at layer ({lx}, {ly})"
            );
        }
    }
    for plane in [PLANE_LUMA, PLANE_MASK] {
        assert!(
            unsafe { rz_doc_painting_layer_plane(doc, 1, plane, ov.as_ptr(), 6, 5) }.is_null(),
            "plane {plane} cannot be painted"
        );
    }

    unsafe {
        rz_doc_free(painted);
        rz_doc_free(doc);
    }
}

#[test]
fn coverage_paints_that_change_nothing_are_refused() {
    let dir = TempDir::new().unwrap();
    let (w, h) = (6u32, 4u32);
    let doc = doc_from(&dir, "noop.png", &solid(w, h, RED));
    let white_channel = vec![255u8; (w * h) as usize];
    let black_channel = vec![0u8; (w * h) as usize];
    let doc = add_channel(doc, "White", &white_channel, w, h);
    let doc = add_channel(doc, "Black", &black_channel, w, h);

    let white = overlay(w, h, [255, 255, 255], |_, _| 255);
    let black = overlay(w, h, [0, 0, 0], |_, _| 255);
    let empty = overlay(w, h, [255, 255, 255], |_, _| 0);

    assert!(
        unsafe { rz_doc_painting_channel(doc, 0, white.as_ptr(), w, h) }.is_null(),
        "white over an all-255 channel is not an edit"
    );
    assert!(
        unsafe { rz_doc_painting_channel(doc, 1, black.as_ptr(), w, h) }.is_null(),
        "black over an all-0 channel is not an edit"
    );
    for i in 0..2 {
        assert!(
            unsafe { rz_doc_painting_channel(doc, i, empty.as_ptr(), w, h) }.is_null(),
            "a transparent overlay is not an edit"
        );
    }
    assert!(
        unsafe { rz_doc_painting_layer_plane(doc, 0, PLANE_RED, empty.as_ptr(), w, h) }.is_null(),
        "a transparent overlay is not an edit on a layer plane either"
    );
    // ... but the same stroke on the OTHER channel is a real edit, so the
    // latch is not simply refusing everything.
    let real = unsafe { rz_doc_painting_channel(doc, 0, black.as_ptr(), w, h) };
    assert!(!real.is_null(), "black over white IS an edit");
    unsafe {
        rz_doc_free(real);
        rz_doc_free(doc);
    }
}

// ------------------------------------------------------------ channel list --

#[test]
fn channel_list_edits_and_their_refusals() {
    let dir = TempDir::new().unwrap();
    let (w, h) = (7u32, 4u32);
    let doc = doc_from(&dir, "cl.png", &solid(w, h, RED));
    let plane = asymmetric_plane(w, h);
    let doc = add_channel(doc, "Sky", &plane, w, h);
    assert_eq!(channel_count(doc), 1);
    assert_eq!(channel_name(doc, 0), "Sky");
    assert_eq!(channel_plane(doc, 0), plane);
    assert_eq!(channel_overlay(doc, 0), ([255, 0, 0], 0.5, false));

    // Rename, but not to the name it already has.
    let same = CString::new("Sky").unwrap();
    assert!(
        unsafe { rz_doc_rename_channel(doc, 0, same.as_ptr()) }.is_null(),
        "renaming to the current name is not an edit"
    );
    let new = CString::new("Sky mask").unwrap();
    let doc = apply(doc, |d| unsafe {
        rz_doc_rename_channel(d, 0, new.as_ptr())
    });
    assert_eq!(channel_name(doc, 0), "Sky mask");

    // Overlay options, all at once, and refused when nothing changes.
    let doc = apply(doc, |d| unsafe {
        rz_doc_set_channel_overlay(d, 0, 0, 128, 255, 0.25, true)
    });
    assert_eq!(channel_overlay(doc, 0), ([0, 128, 255], 0.25, true));
    assert!(
        unsafe { rz_doc_set_channel_overlay(doc, 0, 0, 128, 255, 0.25, true) }.is_null(),
        "an echo of the current options is not an edit"
    );
    // Opacity is sanitized like every other opacity in the core.
    let doc = apply(doc, |d| unsafe {
        rz_doc_set_channel_overlay(d, 0, 0, 128, 255, f32::NAN, true)
    });
    assert_eq!(channel_overlay(doc, 0).1, 1.0, "NaN opacity becomes 1");

    // Replacing the data, and refusing an echo or a wrong size.
    let other = asymmetric_plane(w, h)
        .iter()
        .map(|&v| 255 - v)
        .collect::<Vec<_>>();
    assert!(
        unsafe { rz_doc_set_channel_data(doc, 0, plane.as_ptr(), w, h) }.is_null(),
        "setting the plane it already holds is not an edit"
    );
    assert!(
        unsafe { rz_doc_set_channel_data(doc, 0, other.as_ptr(), w, h + 1) }.is_null(),
        "a non-canvas size is refused"
    );
    let doc = apply(doc, |d| unsafe {
        rz_doc_set_channel_data(d, 0, other.as_ptr(), w, h)
    });
    assert_eq!(channel_plane(doc, 0), other);

    // Duplicate lands right after the original with " copy" appended.
    let doc = apply(doc, |d| unsafe { rz_doc_duplicate_channel(d, 0) });
    assert_eq!(channel_count(doc), 2);
    assert_eq!(channel_name(doc, 1), "Sky mask copy");
    assert_eq!(channel_plane(doc, 1), other);
    assert_eq!(
        channel_overlay(doc, 1),
        channel_overlay(doc, 0),
        "a duplicate keeps the rubylith"
    );

    // Remove.
    let doc = apply(doc, |d| unsafe { rz_doc_remove_channel(d, 0) });
    assert_eq!(channel_count(doc), 1);
    assert_eq!(channel_name(doc, 0), "Sky mask copy");

    // Out-of-range everywhere.
    unsafe {
        assert!(rz_doc_remove_channel(doc, 9).is_null());
        assert!(rz_doc_duplicate_channel(doc, 9).is_null());
        assert!(rz_doc_invert_channel(doc, 9).is_null());
        assert!(rz_doc_rename_channel(doc, 9, new.as_ptr()).is_null());
        assert!(rz_doc_set_channel_overlay(doc, 9, 1, 2, 3, 0.5, false).is_null());
        assert!(rz_doc_set_channel_data(doc, 9, other.as_ptr(), w, h).is_null());
        assert!(rz_doc_channel_name(doc, 9).is_null());
        assert_eq!(rz_doc_channel_overlay_opacity(doc, 9), 0.0);
        assert!(!rz_doc_channel_color_indicates_selected(doc, 9));
        let mut rgb = [0u8; 3];
        assert!(!rz_doc_channel_overlay_color(doc, 9, rgb.as_mut_ptr()));
        assert!(rz_doc_channel_image(doc, 9, 0).is_null());
    }

    // Sizes the export can refuse without reading anything: a zero
    // dimension, and dimensions past the 100 MP ceiling. (The FFI derives
    // the buffer length FROM w and h, so a caller cannot hand it a length
    // that disagrees; the Rust-level length guard is exercised below, where
    // a short slice can be passed safely.)
    let tiny = [0u8; 4];
    let short_name = CString::new("Short").unwrap();
    unsafe {
        assert!(
            rz_doc_add_channel(doc, short_name.as_ptr(), tiny.as_ptr(), 0, 2, 0, 0, 0, 1.0)
                .is_null()
        );
        assert!(
            rz_doc_add_channel(doc, short_name.as_ptr(), tiny.as_ptr(), 2, 0, 0, 0, 0, 1.0)
                .is_null()
        );
        assert!(rz_doc_add_channel(
            doc,
            short_name.as_ptr(),
            tiny.as_ptr(),
            100_000,
            100_000,
            0,
            0,
            0,
            1.0
        )
        .is_null());
        assert!(rz_doc_add_channel(doc, ptr::null(), tiny.as_ptr(), 2, 2, 0, 0, 0, 1.0).is_null());
        assert!(
            rz_doc_add_channel(doc, short_name.as_ptr(), ptr::null(), 2, 2, 0, 0, 0, 1.0).is_null()
        );
    }
    // The Rust-level guard: a slice that is not w*h bytes long.
    let model = RzDocument::from_pixels(solid(w, h, RED));
    assert!(
        model
            .add_channel("Short", &[0u8; 3], w, h, [255, 0, 0], 0.5)
            .is_none(),
        "a plane shorter than w*h is refused"
    );

    unsafe { rz_doc_free(doc) };
}

#[test]
fn invert_channel_is_its_own_inverse() {
    let dir = TempDir::new().unwrap();
    let (w, h) = (5u32, 3u32);
    let doc = doc_from(&dir, "inv.png", &solid(w, h, RED));
    let plane = asymmetric_plane(w, h);
    let doc = add_channel(doc, "A", &plane, w, h);

    let once = apply(doc, |d| unsafe { rz_doc_invert_channel(d, 0) });
    let got = channel_plane(once, 0);
    for (i, &v) in got.iter().enumerate() {
        assert_eq!(v, 255 - plane[i], "255 - v at {i}");
    }
    let twice = apply(once, |d| unsafe { rz_doc_invert_channel(d, 0) });
    assert_eq!(
        channel_plane(twice, 0),
        plane,
        "inverting twice is identity"
    );
    unsafe { rz_doc_free(twice) };
}

/// `rz_doc_channel_id` is what a host hangs per-channel view state on, so
/// what it must guarantee is exactly this: the id follows the CHANNEL, not
/// its name and not its position. Two channels may share a name and still be
/// told apart; a rename, an edit and a delete of a neighbour leave an id
/// alone; a duplicate is a new channel and gets a new id; a deleted channel's
/// id is never handed to a survivor.
#[test]
fn channel_ids_follow_the_channel_through_renames_deletes_and_duplicates() {
    let dir = TempDir::new().unwrap();
    let (w, h) = (6u32, 4u32);
    let doc = doc_from(&dir, "ids.png", &solid(w, h, RED));
    // Deliberately the SAME name twice — the core does not enforce
    // uniqueness, which is why a name cannot be an identity.
    let doc = add_channel(doc, "Alpha 1", &vec![10u8; (w * h) as usize], w, h);
    let doc = add_channel(doc, "Alpha 1", &vec![20u8; (w * h) as usize], w, h);
    let id = |d: *const RzDocument, i: usize| unsafe { rz_doc_channel_id(d, i) };
    let (first, second) = (id(doc, 0), id(doc, 1));
    assert!(first != 0 && second != 0, "a live channel has an id");
    assert_ne!(first, second, "same name, different channels");
    assert_eq!(id(doc, 2), 0, "out of range answers 0");
    assert_eq!(id(ptr::null(), 0), 0, "a NULL doc answers 0");

    // A rename, an overlay change and a plane edit are all the same channel.
    let renamed = apply(doc, |d| unsafe {
        let c = CString::new("Sky").unwrap();
        rz_doc_rename_channel(d, 0, c.as_ptr())
    });
    let edited = apply(renamed, |d| unsafe { rz_doc_invert_channel(d, 0) });
    assert_eq!(id(edited, 0), first, "a rename and an edit keep the id");
    assert_eq!(id(edited, 1), second, "and leave the neighbour alone");

    // A duplicate is a SECOND channel: same pixels, its own identity.
    let duplicated = apply(edited, |d| unsafe { rz_doc_duplicate_channel(d, 0) });
    assert_eq!(id(duplicated, 0), first, "the original keeps its id");
    let copy = id(duplicated, 1);
    assert!(
        copy != first && copy != second,
        "the copy gets an id of its own"
    );
    assert_eq!(id(duplicated, 2), second, "the list below just shifts down");

    // Deleting the FIRST of two same-named channels must not hand its
    // identity to the survivor, which is what a positional key would do.
    let deleted = apply(duplicated, |d| unsafe { rz_doc_remove_channel(d, 0) });
    assert_eq!(channel_count(deleted), 2);
    assert_eq!(id(deleted, 0), copy, "the copy is now first, with its id");
    assert_eq!(id(deleted, 1), second);
    assert!(
        (0..channel_count(deleted)).all(|i| id(deleted, i) != first),
        "the deleted channel's id is gone with it"
    );

    // Ids are per-process handles, not file content: a saved and reopened
    // document has the same planes and fresh, still-distinct ids.
    let path = dir.path().join("ids.rzdc");
    let c = cpath(&path);
    let mut err: *mut c_char = ptr::null_mut();
    assert!(
        unsafe { rz_doc_save_native(deleted, c.as_ptr(), &mut err) },
        "{}",
        take_err_string(err)
    );
    let mut err: *mut c_char = ptr::null_mut();
    let back = unsafe { rz_doc_open(c.as_ptr(), &mut err) };
    assert!(!back.is_null(), "reopen: {}", take_err_string(err));
    assert_eq!(channel_plane(back, 0), channel_plane(deleted, 0));
    assert_ne!(id(back, 0), id(back, 1), "reloaded ids are still distinct");
    assert!(id(back, 0) != 0 && id(back, 1) != 0);

    unsafe {
        rz_doc_free(back);
        rz_doc_free(deleted);
    }
}

#[test]
fn add_channel_resamples_a_matte_to_the_canvas() {
    let dir = TempDir::new().unwrap();
    // The iPhone-matte shape: a small auxiliary plane on a bigger canvas.
    let doc = doc_from(&dir, "matte.png", &solid(30, 20, RED));
    let matte = asymmetric_plane(7, 5);
    let doc = add_channel(doc, "Depth", &matte, 7, 5);

    let plane = channel_plane(doc, 0);
    assert_eq!(plane.len(), 30 * 20, "the channel is canvas-sized");
    let lo = *matte.iter().min().unwrap();
    let hi = *matte.iter().max().unwrap();
    assert!(
        plane.iter().all(|&v| v >= lo && v <= hi),
        "a bilinear resample stays within the source's range [{lo}, {hi}]"
    );
    assert!(
        plane.iter().any(|&v| v != plane[0]),
        "the resampled plane still varies"
    );
    unsafe { rz_doc_free(doc) };
}

// ------------------------------------------------------- luminosity masks --

#[test]
fn luminosity_masks_follow_the_documented_formulas() {
    let dir = TempDir::new().unwrap();
    // Mid grey: L = 128/255, the value where the midtone masks peak.
    let doc = doc_from(&dir, "lum.png", &solid(6, 4, [128, 128, 128, 255]));
    let doc = apply(doc, |d| unsafe { rz_doc_add_luminosity_masks(d) });
    assert_eq!(channel_count(doc), 9);

    let names: Vec<String> = (0..9).map(|i| channel_name(doc, i)).collect();
    assert_eq!(
        names,
        [
            "Lights 1",
            "Lights 2",
            "Lights 3",
            "Darks 1",
            "Darks 2",
            "Darks 3",
            "Midtones 1",
            "Midtones 2",
            "Midtones 3",
        ]
    );

    let l = 128.0f32 / 255.0;
    let want = |t: f32| (t.clamp(0.0, 1.0) * 255.0).round() as u8;
    let expected = [
        want(l),
        want(l * l),
        want(l * l * l),
        want(1.0 - l),
        want((1.0 - l) * (1.0 - l)),
        want((1.0 - l) * (1.0 - l) * (1.0 - l)),
        want(1.0 - l * l - (1.0 - l) * (1.0 - l)),
        want(1.0 - l * l * l - (1.0 - l) * (1.0 - l) * (1.0 - l)),
        want(1.0 - l * l * l * l - (1.0 - l) * (1.0 - l) * (1.0 - l) * (1.0 - l)),
    ];
    for (i, &v) in expected.iter().enumerate() {
        let plane = channel_plane(doc, i);
        assert!(
            plane.iter().all(|&p| p == v),
            "{} must be {v} everywhere, got {}",
            names[i],
            plane[0]
        );
    }

    // The regression the offset exponent exists to prevent: with the LINEAR
    // pair the midtone masks would be identically zero.
    assert!(
        expected[6] > 120,
        "Midtones 1 at mid grey is 2L(1-L) ~ 128, not 0 (it was {})",
        expected[6]
    );
    // At mid grey the three sit at 2L(1-L) = 0.5, then 0.75 and 0.875 —
    // distinct, and rising, because each narrows BOTH tails and so widens
    // the band left between them. L is 128/255, a hair above 0.5, so the
    // first lands a hair below 127.5 and rounds down to 127.
    assert_eq!(
        [expected[6], expected[7], expected[8]],
        [127, 191, 223],
        "the midtone values at mid grey are 0.5, 0.75 and 0.875"
    );
    assert_eq!(
        channel_overlay(doc, 0),
        ([255, 0, 0], 0.5, false),
        "luminosity masks take the default rubylith"
    );

    // What can refuse the nine is the COUNT cap and a canvas already carrying
    // many channels — never the canvas SIZE alone; see
    // nine_luminosity_masks_fit_every_canvas_the_library_will_build.
    unsafe { rz_doc_free(doc) };
}

/// The nine fit EVERY canvas this library will build. The total channel-pixel
/// budget is nine full canvases precisely so that the one op which appends a
/// fixed nine can never be refused for a reason the user has no way to act on.
///
/// At four canvases it was: a 45 MP camera file (8192 x 5464 — the size
/// luminosity masks exist for) allowed only eight channels, so Add Luminosity
/// Masks was refused on a freshly opened, channel-FREE document, under an
/// alert telling the user to delete channels that did not exist.
///
/// `rz_max_channels_at` is the predicate `channels_fit` itself asks, so this
/// exercises the refusal path rather than restating the constant.
#[test]
fn nine_luminosity_masks_fit_every_canvas_the_library_will_build() {
    // The extremes of a 100 MP canvas (MAX_PIXELS, the largest any op will
    // build): square, and each degenerate strip.
    for (w, h) in [(10_000u32, 10_000u32), (100_000_000, 1), (1, 100_000_000)] {
        assert!(
            rz_max_channels_at(w, h) >= 9,
            "{w}x{h} must hold a whole luminosity-mask set"
        );
    }
    // The camera files the feature exists for: 45 MP, 24 MP, 12 MP.
    for (w, h) in [(8192u32, 5464u32), (6000, 4000), (4032, 3024)] {
        assert!(rz_max_channels_at(w, h) >= 9, "{w}x{h} must hold the nine");
    }
    // And a channel-free document really does get them: the refusal is
    // checked before the composite is built, so passing the predicate is the
    // whole of it.
    let dir = TempDir::new().unwrap();
    let doc = doc_from(&dir, "fresh.png", &opaque_pattern(8, 6));
    assert_eq!(channel_count(doc), 0);
    let masked = unsafe { rz_doc_add_luminosity_masks(doc) };
    assert!(
        !masked.is_null(),
        "a document with no channels is never full"
    );
    assert_eq!(channel_count(masked), 9);
    unsafe {
        rz_doc_free(masked);
        rz_doc_free(doc);
    }
}

// ---------------------------------------------------------------- the caps --

#[test]
fn the_channel_count_cap_holds_at_both_ends() {
    let dir = TempDir::new().unwrap();
    let (w, h) = (4u32, 4u32);
    let mut doc = doc_from(&dir, "cap.png", &solid(w, h, RED));
    let plane = asymmetric_plane(w, h);
    for i in 0..256 {
        doc = add_channel(doc, &format!("Alpha {i}"), &plane, w, h);
    }
    assert_eq!(channel_count(doc), 256);
    assert!(
        try_add_channel(doc, "One too many", &plane, w, h).is_none(),
        "the 257th channel is refused"
    );
    assert!(
        unsafe { rz_doc_duplicate_channel(doc, 0) }.is_null(),
        "duplicating past the cap is refused"
    );

    // The document that DID fit writes and reads back intact — the invariant
    // the creation-side check exists to protect.
    let path = dir.path().join("full.rzdc");
    let c = cpath(&path);
    let mut err: *mut c_char = ptr::null_mut();
    assert!(
        unsafe { rz_doc_save_native(doc, c.as_ptr(), &mut err) },
        "{}",
        take_err_string(err)
    );
    let mut err: *mut c_char = ptr::null_mut();
    let back = unsafe { rz_doc_open(c.as_ptr(), &mut err) };
    assert!(!back.is_null(), "reopen: {}", take_err_string(err));
    assert_eq!(channel_count(back), 256);
    assert_eq!(channel_name(back, 255), "Alpha 255");
    assert_eq!(channel_plane(back, 255), plane);

    unsafe {
        rz_doc_free(back);
        rz_doc_free(doc);
    }
}

#[test]
fn the_total_channel_pixel_budget_holds_at_both_ends() {
    let dir = TempDir::new().unwrap();
    // 2000x2000 = 4 MP: 225 channels are exactly the 900 MP budget, so the
    // 226th is refused. The planes are Arc-SHARED here (the model's field is
    // public), which is what keeps a boundary test of a 900 MP budget down to
    // one 4 MB buffer.
    let base = RzDocument::from_pixels(solid(2, 2, RED))
        .canvas_resize(2000, 2000, (0, 0))
        .expect("canvas resize");
    let plane = Arc::new(GrayImage::from_pixel(2000, 2000, image::Luma([200])));
    let mut doc = base.clone();
    for i in 0..225 {
        doc.channels.push(Channel {
            // The model's fields are public, so a test that builds a channel
            // by hand mints its own identity; every core path goes through
            // Channel::new instead.
            id: i as u64 + 1,
            name: format!("Alpha {i}"),
            data: Arc::clone(&plane),
            overlay_color: [255, 0, 0],
            overlay_opacity: 0.5,
            color_indicates_selected: false,
        });
    }
    let handle: *const RzDocument = &doc;
    let tiny = [0u8; 4];
    let name = CString::new("One too many").unwrap();
    assert!(
        unsafe { rz_doc_add_channel(handle, name.as_ptr(), tiny.as_ptr(), 2, 2, 0, 0, 0, 1.0) }
            .is_null(),
        "the 226th channel would exceed the total pixel budget"
    );
    assert!(
        unsafe { rz_doc_duplicate_channel(handle, 0) }.is_null(),
        "duplicating past the pixel budget is refused"
    );
    assert!(
        unsafe { rz_doc_add_luminosity_masks(handle) }.is_null(),
        "nine more would exceed the budget too"
    );
    // One fewer channel and the same calls go through, so the refusals above
    // are the cap and not something incidental.
    let mut room = doc.clone();
    room.channels.truncate(224);
    let room_handle: *const RzDocument = &room;
    let out = unsafe {
        rz_doc_add_channel(
            room_handle,
            name.as_ptr(),
            tiny.as_ptr(),
            2,
            2,
            0,
            0,
            0,
            1.0,
        )
    };
    assert!(!out.is_null(), "the 225th channel fits exactly");
    unsafe { rz_doc_free(out) };

    // The WRITER enforces the same budget, so nothing this build can hold can
    // be written and then refused on reopen. 256 channels on a 1876x1876
    // canvas is 901.0 MP — past the budget while inside the count cap.
    let mut over = RzDocument::from_pixels(solid(2, 2, RED))
        .canvas_resize(1876, 1876, (0, 0))
        .expect("canvas resize");
    let small = Arc::new(GrayImage::new(1876, 1876));
    for i in 0..256 {
        over.channels.push(Channel {
            id: i as u64 + 1,
            name: format!("Alpha {i}"),
            data: Arc::clone(&small),
            overlay_color: [255, 0, 0],
            overlay_opacity: 0.5,
            color_indicates_selected: false,
        });
    }
    let err = over
        .save_native(dir.path().join("over.rzdc").to_str().unwrap())
        .expect_err("the writer must refuse a document past the budget");
    assert!(err.contains("total channel pixels"), "got: {err}");

    // And past the COUNT cap.
    let mut many = RzDocument::from_pixels(solid(2, 2, RED));
    let dot = Arc::new(GrayImage::new(2, 2));
    for i in 0..257 {
        many.channels.push(Channel {
            id: i as u64 + 1,
            name: format!("Alpha {i}"),
            data: Arc::clone(&dot),
            overlay_color: [255, 0, 0],
            overlay_opacity: 0.5,
            color_indicates_selected: false,
        });
    }
    let err = many
        .save_native(dir.path().join("many.rzdc").to_str().unwrap())
        .expect_err("the writer must refuse more than 256 channels");
    assert!(err.contains("too many channels"), "got: {err}");
}

// -------------------------------------------------------------- RZDC v5 --

/// A document with three channels covering both polarities, non-ASCII names,
/// distinct rubyliths and non-trivial planes.
fn channel_fixture(dir: &TempDir) -> *mut RzDocument {
    let (w, h) = (11u32, 7u32);
    let doc = doc_from(dir, "rzdc.png", &opaque_pattern(w, h));
    let doc = add_layer(dir, "rzdc-top.png", doc, 0, &solid(4, 3, BLUE), "Top");
    let mut doc = add_channel(doc, "Sky", &asymmetric_plane(w, h), w, h);
    doc = add_channel(doc, "層 — matte", &vec![0u8; (w * h) as usize], w, h);
    doc = add_channel(doc, "Skin", &vec![255u8; (w * h) as usize], w, h);
    doc = apply(doc, |d| unsafe {
        rz_doc_set_channel_overlay(d, 1, 0, 200, 30, 0.25, true)
    });
    apply(doc, |d| unsafe {
        rz_doc_set_channel_overlay(d, 2, 10, 20, 30, 0.75, false)
    })
}

#[test]
fn rzdc_v5_round_trips_channels_byte_for_byte() {
    let dir = TempDir::new().unwrap();
    let doc = channel_fixture(&dir);

    let path = dir.path().join("channels.rzdc");
    let c = cpath(&path);
    let mut err: *mut c_char = ptr::null_mut();
    assert!(
        unsafe { rz_doc_save_native(doc, c.as_ptr(), &mut err) },
        "{}",
        take_err_string(err)
    );
    let bytes = std::fs::read(&path).unwrap();
    assert_eq!(&bytes[..4], b"RZDC");
    assert_eq!(
        u32::from_le_bytes(bytes[4..8].try_into().unwrap()),
        5,
        "channels bumped the format to 5"
    );

    let mut err: *mut c_char = ptr::null_mut();
    let back = unsafe { rz_doc_open(c.as_ptr(), &mut err) };
    assert!(!back.is_null(), "reopen: {}", take_err_string(err));
    assert_eq!(channel_count(back), 3);
    for i in 0..3 {
        assert_eq!(channel_name(back, i), channel_name(doc, i), "name {i}");
        assert_eq!(
            channel_overlay(back, i),
            channel_overlay(doc, i),
            "overlay {i}"
        );
        assert_eq!(channel_plane(back, i), channel_plane(doc, i), "plane {i}");
    }
    assert!(
        channel_overlay(back, 1).2 && !channel_overlay(back, 2).2,
        "both polarities survive"
    );

    // Re-encoding the reloaded document reproduces the file exactly.
    let again = dir.path().join("again.rzdc");
    let c2 = cpath(&again);
    let mut err: *mut c_char = ptr::null_mut();
    assert!(
        unsafe { rz_doc_save_native(back, c2.as_ptr(), &mut err) },
        "{}",
        take_err_string(err)
    );
    assert_eq!(
        std::fs::read(&again).unwrap(),
        bytes,
        "the round trip is byte-identical"
    );

    unsafe {
        rz_doc_free(back);
        rz_doc_free(doc);
    }
}

#[test]
fn version_4_files_load_with_no_channels_and_version_6_is_refused() {
    let dir = TempDir::new().unwrap();
    // A channel-less document written today is a v4 file plus the four bytes
    // of a zero channel count, so a v4 fixture is that file minus its tail.
    let doc = doc_from(&dir, "v4.png", &opaque_pattern(5, 3));
    let path = dir.path().join("v5-empty.rzdc");
    let c = cpath(&path);
    let mut err: *mut c_char = ptr::null_mut();
    assert!(unsafe { rz_doc_save_native(doc, c.as_ptr(), &mut err) });
    let v5 = std::fs::read(&path).unwrap();
    assert_eq!(
        &v5[v5.len() - 4..],
        &0u32.to_le_bytes(),
        "an empty channel list is a u32 zero at the very end"
    );

    let mut v4 = v5[..v5.len() - 4].to_vec();
    v4[4..8].copy_from_slice(&4u32.to_le_bytes());
    let v4_path = dir.path().join("v4.rzdc");
    std::fs::write(&v4_path, &v4).unwrap();
    let c4 = cpath(&v4_path);
    let mut err: *mut c_char = ptr::null_mut();
    let back = unsafe { rz_doc_open(c4.as_ptr(), &mut err) };
    assert!(
        !back.is_null(),
        "a v4 file must load: {}",
        take_err_string(err)
    );
    assert_eq!(channel_count(back), 0, "a v4 file carries no channels");
    assert_eq!(unsafe { rz_doc_layer_count(back) }, 1);
    assert_eq!(
        composite_plane(back, PLANE_RED),
        composite_plane(doc, PLANE_RED),
        "and everything else is intact"
    );

    // A future version is refused by number.
    let mut v6 = v5.clone();
    v6[4..8].copy_from_slice(&6u32.to_le_bytes());
    let v6_path = dir.path().join("v6.rzdc");
    std::fs::write(&v6_path, &v6).unwrap();
    let c6 = cpath(&v6_path);
    let mut err: *mut c_char = ptr::null_mut();
    assert!(unsafe { rz_doc_open(c6.as_ptr(), &mut err) }.is_null());
    let msg = take_err_string(err);
    assert!(msg.contains("unsupported RZDC version 6"), "got: {msg}");

    unsafe {
        rz_doc_free(back);
        rz_doc_free(doc);
    }
}

#[test]
fn crafted_channel_headers_are_refused_before_anything_is_decoded() {
    let dir = TempDir::new().unwrap();
    let mut png = Vec::new();
    solid(1, 1, [1, 2, 3, 255])
        .write_to(&mut std::io::Cursor::new(&mut png), image::ImageFormat::Png)
        .unwrap();

    // A minimal v5 file whose canvas and channel count are whatever we say.
    let craft = |width: u32, height: u32, channels: u32| {
        let mut b = Vec::new();
        b.extend_from_slice(b"RZDC");
        b.extend_from_slice(&5u32.to_le_bytes());
        b.extend_from_slice(&width.to_le_bytes());
        b.extend_from_slice(&height.to_le_bytes());
        b.extend_from_slice(&1u32.to_le_bytes()); // layer count
        b.extend_from_slice(&120.0f32.to_le_bytes());
        b.extend_from_slice(&30.0f32.to_le_bytes());
        b.extend_from_slice(&1u32.to_le_bytes()); // name len
        b.push(b'X');
        b.extend_from_slice(&0i32.to_le_bytes());
        b.extend_from_slice(&0i32.to_le_bytes());
        b.extend_from_slice(&1.0f32.to_le_bytes());
        b.extend_from_slice(&0u32.to_le_bytes()); // blend
        b.push(1); // visible
        b.extend_from_slice(&(png.len() as u32).to_le_bytes());
        b.extend_from_slice(&png);
        b.push(0); // no mask
        b.push(1); // mask enabled
        b.push(0); // no meta
        b.push(0); // not clipped
        b.push(0); // no style
        b.extend_from_slice(&channels.to_le_bytes());
        b
    };

    let open = |name: &str, bytes: &[u8]| {
        let path = dir.path().join(name);
        std::fs::write(&path, bytes).unwrap();
        let c = cpath(&path);
        let mut err: *mut c_char = ptr::null_mut();
        let doc = unsafe { rz_doc_open(c.as_ptr(), &mut err) };
        if doc.is_null() {
            Err(take_err_string(err))
        } else {
            Ok(doc)
        }
    };

    let err = open("count.rzdc", &craft(2, 2, 300)).expect_err("300 channels is past the cap");
    assert!(err.contains("invalid channel count"), "got: {err}");

    // 226 channels on a 2000x2000 canvas is 904 MP: refused UP FRONT, from
    // the header alone, before a single plane is decoded (the file carries
    // no channel records at all).
    let err =
        open("budget.rzdc", &craft(2000, 2000, 226)).expect_err("past the total pixel budget");
    assert!(err.contains("total channel pixels"), "got: {err}");

    // A declared channel with no bytes behind it is a truncation, not a
    // panic.
    let err = open("truncated.rzdc", &craft(2, 2, 1)).expect_err("truncated");
    assert!(err.contains("unexpected end of file"), "got: {err}");

    // Zero channels parses fine, which proves the fixture itself is sound.
    let doc = open("empty.rzdc", &craft(2, 2, 0)).expect("a well-formed v5 file");
    assert_eq!(channel_count(doc), 0);
    unsafe { rz_doc_free(doc) };
}

// -------------------------------------------------------------- geometry --

/// The five exact transforms, written out as index permutations rather than
/// taken from the core. Returns the new plane and its dimensions.
fn permute(plane: &[u8], w: u32, h: u32, kind: &str) -> (Vec<u8>, u32, u32) {
    let at = |x: u32, y: u32| plane[(y * w + x) as usize];
    match kind {
        // Clockwise: the top-left pixel lands top-right.
        "rot90" => (
            (0..w)
                .flat_map(|y| (0..h).map(move |x| (x, y)))
                .map(|(x, y)| at(y, h - 1 - x))
                .collect(),
            h,
            w,
        ),
        "rot180" => (
            (0..h)
                .flat_map(|y| (0..w).map(move |x| (x, y)))
                .map(|(x, y)| at(w - 1 - x, h - 1 - y))
                .collect(),
            w,
            h,
        ),
        // Counter-clockwise: the top-left pixel lands bottom-left.
        "rot270" => (
            (0..w)
                .flat_map(|y| (0..h).map(move |x| (x, y)))
                .map(|(x, y)| at(w - 1 - y, x))
                .collect(),
            h,
            w,
        ),
        "fliph" => (
            (0..h)
                .flat_map(|y| (0..w).map(move |x| (x, y)))
                .map(|(x, y)| at(w - 1 - x, y))
                .collect(),
            w,
            h,
        ),
        "flipv" => (
            (0..h)
                .flat_map(|y| (0..w).map(move |x| (x, y)))
                .map(|(x, y)| at(x, h - 1 - y))
                .collect(),
            w,
            h,
        ),
        other => panic!("unknown transform {other}"),
    }
}

#[test]
fn canvas_geometry_keeps_channels_canvas_sized_and_aligned() {
    let dir = TempDir::new().unwrap();
    let (w, h) = (9u32, 6u32);
    let plane = asymmetric_plane(w, h);
    let base = doc_from(&dir, "geo.png", &opaque_pattern(w, h));
    let base = add_channel(base, "Sky", &plane, w, h);

    for (kind, op) in [
        ("rot90", rz_doc_rotate90 as unsafe extern "C" fn(_) -> _),
        ("rot180", rz_doc_rotate180),
        ("rot270", rz_doc_rotate270),
        ("fliph", rz_doc_flip_horizontal),
        ("flipv", rz_doc_flip_vertical),
    ] {
        let out = unsafe { op(base) };
        assert!(!out.is_null(), "{kind} failed");
        let (want, nw, nh) = permute(&plane, w, h, kind);
        assert_eq!(doc_dims(out), (nw, nh), "{kind} canvas");
        assert_eq!(channel_count(out), 1, "{kind} keeps the channel");
        assert_eq!(channel_plane(out, 0), want, "{kind} plane");
        assert_eq!(channel_name(out, 0), "Sky", "{kind} keeps the name");
        unsafe { rz_doc_free(out) };
    }

    // Crop cuts the plane down to the rect (a channel is CANVAS space).
    let cropped = unsafe { rz_doc_crop(base, 2, 1, 5, 4) };
    assert!(!cropped.is_null());
    assert_eq!(doc_dims(cropped), (5, 4));
    let got = channel_plane(cropped, 0);
    for y in 0..4u32 {
        for x in 0..5u32 {
            assert_eq!(
                got[(y * 5 + x) as usize],
                plane[((y + 1) * w + x + 2) as usize],
                "crop at ({x}, {y})"
            );
        }
    }
    unsafe { rz_doc_free(cropped) };

    // Growing the canvas pads with 0 (unselected).
    let grown = unsafe { rz_doc_canvas_resize(base, 12, 9, 2, 3) };
    assert!(!grown.is_null());
    assert_eq!(doc_dims(grown), (12, 9));
    let got = channel_plane(grown, 0);
    for y in 0..9u32 {
        for x in 0..12u32 {
            let inside = (2..2 + w).contains(&x) && (3..3 + h).contains(&y);
            let want = if inside {
                plane[((y - 3) * w + x - 2) as usize]
            } else {
                0
            };
            assert_eq!(got[(y * 12 + x) as usize], want, "pad at ({x}, {y})");
        }
    }
    unsafe { rz_doc_free(grown) };

    // A NEGATIVE origin shrinks the window around the content; the plane is
    // clipped, never wrapped.
    let shrunk = unsafe { rz_doc_canvas_resize(base, 5, 4, -3, -2) };
    assert!(!shrunk.is_null());
    assert_eq!(doc_dims(shrunk), (5, 4));
    let got = channel_plane(shrunk, 0);
    for y in 0..4u32 {
        for x in 0..5u32 {
            assert_eq!(
                got[(y * 5 + x) as usize],
                plane[((y + 2) * w + x + 3) as usize],
                "negative origin at ({x}, {y})"
            );
        }
    }
    unsafe { rz_doc_free(shrunk) };

    // Resize takes the channel to the NEW canvas size.
    let scaled = unsafe { rz_doc_resize(base, 18, 12, FILTER_BILINEAR) };
    assert!(!scaled.is_null());
    assert_eq!(doc_dims(scaled), (18, 12));
    assert_eq!(channel_plane(scaled, 0).len(), 18 * 12);
    let lo = *plane.iter().min().unwrap();
    let hi = *plane.iter().max().unwrap();
    assert!(
        channel_plane(scaled, 0).iter().all(|&v| v >= lo && v <= hi),
        "a resampled plane stays inside the source's range"
    );
    unsafe { rz_doc_free(scaled) };

    unsafe { rz_doc_free(base) };
}

/// The Crop tool's straighten, composed exactly as the app and the `crop`
/// MCP tool compose it: every layer through `rz_doc_transform_layer`, the
/// channels through `rz_doc_transform_channels`, then `rz_doc_crop` — one
/// edit. A channel that starts out as the picture's own luma must still BE
/// the picture's luma afterwards; that is what "the saved selection still
/// lines up with what it was saved from" means.
///
/// The oracle is the composite's luma read back through the FFI, compared
/// only where the rotated picture is fully opaque with fully opaque
/// neighbours — at the rotated edge the RGBA resample fades to transparent
/// while a coverage resample fades to 0, so the two are legitimately
/// different there. The final assertion is the regression itself: skipping
/// the channel transform leaves the channel far out of register.
#[test]
fn straighten_carries_the_channels_with_the_picture() {
    let dir = TempDir::new().unwrap();
    let (w, h) = (64u32, 48u32);
    let base = doc_from(&dir, "straighten.png", &opaque_pattern(w, h));
    let luma = composite_plane(base, PLANE_LUMA).expect("composite luma");
    let base = add_channel(base, "Luma", &luma, w, h);
    assert_eq!(
        channel_plane(base, 0),
        luma,
        "the channel starts as the luma"
    );

    // Rotate by -20 degrees about the crop rect's centre — the matrix both
    // straighten call sites build, in CGAffineTransform element order.
    let (rx, ry, rw, rh) = (8u32, 6u32, 32u32, 28u32);
    let (cx, cy) = (
        f64::from(rx) + f64::from(rw) / 2.0,
        f64::from(ry) + f64::from(rh) / 2.0,
    );
    let theta = (-20.0f64).to_radians();
    let (cos, sin) = (theta.cos(), theta.sin());
    let m = [
        cos,
        sin,
        -sin,
        cos,
        cx - cx * cos + cy * sin,
        cy - cx * sin - cy * cos,
    ];

    let turned = unsafe { rz_doc_transform_layer(base, 0, m.as_ptr(), FILTER_BILINEAR) };
    assert!(!turned.is_null(), "transform_layer refused the straighten");
    let carried = unsafe { rz_doc_transform_channels(turned, m.as_ptr(), FILTER_BILINEAR) };
    assert!(!carried.is_null(), "transform_channels refused a rotation");
    assert_eq!(doc_dims(carried), (w, h), "a channel transform is in place");
    assert_eq!(channel_name(carried, 0), "Luma", "the name rides along");

    let fixed = unsafe { rz_doc_crop(carried, rx, ry, rw, rh) };
    let dropped = unsafe { rz_doc_crop(turned, rx, ry, rw, rh) };
    assert!(!fixed.is_null() && !dropped.is_null(), "crop refused");
    assert_eq!(doc_dims(fixed), (rw, rh));

    let want = composite_plane(fixed, PLANE_LUMA).expect("straightened luma");
    let alpha = composite_plane(fixed, PLANE_ALPHA).expect("straightened alpha");
    let got = channel_plane(fixed, 0);
    let skipped = channel_plane(dropped, 0);
    assert_eq!(got.len(), want.len());

    // Interior: opaque, with every neighbour opaque, so a bilinear tap can
    // only have come from opaque source pixels.
    let opaque_neighbourhood = |x: u32, y: u32| {
        (y.saturating_sub(1)..=(y + 1).min(rh - 1)).all(|ny| {
            (x.saturating_sub(1)..=(x + 1).min(rw - 1))
                .all(|nx| alpha[(ny * rw + nx) as usize] == 255)
        })
    };
    let (mut interior, mut worst, mut worst_skipped) = (0usize, 0i32, 0i32);
    for y in 1..rh - 1 {
        for x in 1..rw - 1 {
            if !opaque_neighbourhood(x, y) {
                continue;
            }
            let i = (y * rw + x) as usize;
            interior += 1;
            worst = worst.max((i32::from(got[i]) - i32::from(want[i])).abs());
            worst_skipped = worst_skipped.max((i32::from(skipped[i]) - i32::from(want[i])).abs());
        }
    }
    assert!(
        interior > 200,
        "only {interior} interior samples to compare"
    );
    // 4 covers the two roundings the two paths do not share: luma-then-
    // resample against resample-then-luma, and the RGBA path's unpremultiply.
    assert!(
        worst <= 4,
        "the carried channel drifted from the picture by {worst}"
    );
    // The defect this test exists for: without the channel transform the
    // very same channel is out of register with the picture it describes.
    assert!(
        worst_skipped >= 16,
        "an un-rotated channel should be visibly wrong, was off by {worst_skipped}"
    );

    // An identity matrix is not an edit (nothing would move).
    let identity = [1.0f64, 0.0, 0.0, 1.0, 0.0, 0.0];
    assert!(
        unsafe { rz_doc_transform_channels(base, identity.as_ptr(), FILTER_BILINEAR) }.is_null(),
        "an identity transform must refuse rather than mint an undo step"
    );

    unsafe {
        rz_doc_free(fixed);
        rz_doc_free(dropped);
        rz_doc_free(carried);
        rz_doc_free(turned);
        rz_doc_free(base);
    }
}

#[test]
fn stack_operations_carry_the_channel_list() {
    let dir = TempDir::new().unwrap();
    let (w, h) = (6u32, 4u32);
    let plane = asymmetric_plane(w, h);
    let doc = doc_from(&dir, "stack.png", &opaque_pattern(w, h));
    let doc = add_layer(&dir, "stack-top.png", doc, 0, &solid(3, 2, BLUE), "Top");
    let doc = add_channel(doc, "Sky", &plane, w, h);

    for (what, out) in [
        ("clone", unsafe { rz_doc_clone(doc) }),
        ("flattening", unsafe { rz_doc_flattening(doc) }),
        ("merging_down", unsafe { rz_doc_merging_down(doc, 1) }),
        ("duplicating_layer", unsafe {
            rz_doc_duplicating_layer(doc, 0)
        }),
        ("removing_layer", unsafe { rz_doc_removing_layer(doc, 1) }),
    ] {
        assert!(!out.is_null(), "{what} failed");
        assert_eq!(channel_count(out), 1, "{what} keeps the channel");
        assert_eq!(channel_plane(out, 0), plane, "{what} keeps the plane");
        assert_eq!(channel_name(out, 0), "Sky", "{what} keeps the name");
        unsafe { rz_doc_free(out) };
    }
    unsafe { rz_doc_free(doc) };
}

// ------------------------------------------------- bogus and NULL arguments --

#[test]
fn bogus_plane_values_are_refused_rather_than_materialized() {
    let dir = TempDir::new().unwrap();
    let (w, h) = (4u32, 3u32);
    let doc = doc_from(&dir, "bogus.png", &opaque_pattern(w, h));
    let img = open_image(&dir, "bogus-img.png", &opaque_pattern(w, h));
    let mut out = vec![0u8; (w * h) as usize];
    let src = vec![0u8; (w * h) as usize];
    let ov = overlay(w, h, [255, 255, 255], |_, _| 255);

    for plane in [-1, 6, 99, i32::MIN, i32::MAX] {
        unsafe {
            assert!(!rz_doc_composite_plane(doc, plane, out.as_mut_ptr(), w, h));
            assert!(!rz_doc_layer_plane(doc, 0, plane, out.as_mut_ptr(), w, h));
            assert!(!rz_image_plane(img, plane, out.as_mut_ptr(), w, h));
            assert!(rz_doc_composite_plane_image(doc, plane, 0).is_null());
            assert!(rz_doc_layer_plane_image(doc, 0, plane, 0).is_null());
            assert!(rz_image_plane_image(img, plane, 0).is_null());
            assert!(rz_doc_with_layer_plane(doc, 0, plane, src.as_ptr(), w, h).is_null());
            assert!(rz_doc_painting_layer_plane(doc, 0, plane, ov.as_ptr(), w, h).is_null());
        }
    }
    // An unknown blend mode is refused the same way.
    let mut base = vec![0u8; (w * h) as usize];
    for mode in [-1, BLEND_MODE_COUNT, 999] {
        assert!(
            !unsafe {
                rz_blend_planes(
                    base.as_mut_ptr(),
                    src.as_ptr(),
                    w,
                    h,
                    mode,
                    1.0,
                    false,
                    false,
                )
            },
            "mode {mode} must be refused"
        );
    }
    unsafe {
        rz_image_free(img);
        rz_doc_free(doc);
    }
}

#[test]
fn non_document_exports_reject_null_zero_size_and_non_finite() {
    let dir = TempDir::new().unwrap();
    let img = open_image(&dir, "null.png", &opaque_pattern(4, 3));
    let null_img: *const RzImage = ptr::null();
    let mut base = vec![0u8; 12];
    let source = [0u8; 12];
    let mut out = vec![0u8; 12];

    unsafe {
        // rz_blend_planes.
        assert!(!rz_blend_planes(
            ptr::null_mut(),
            source.as_ptr(),
            4,
            3,
            BLEND_NORMAL,
            1.0,
            false,
            false
        ));
        assert!(!rz_blend_planes(
            base.as_mut_ptr(),
            ptr::null(),
            4,
            3,
            BLEND_NORMAL,
            1.0,
            false,
            false
        ));
        for (w, h) in [(0u32, 3u32), (4, 0), (0, 0)] {
            assert!(!rz_blend_planes(
                base.as_mut_ptr(),
                source.as_ptr(),
                w,
                h,
                BLEND_NORMAL,
                1.0,
                false,
                false
            ));
        }
        assert!(
            !rz_blend_planes(
                base.as_mut_ptr(),
                source.as_ptr(),
                100_000,
                100_000,
                BLEND_NORMAL,
                1.0,
                false,
                false
            ),
            "absurd dimensions are refused before any slice is built"
        );
        for opacity in [f32::NAN, f32::INFINITY, f32::NEG_INFINITY] {
            assert!(!rz_blend_planes(
                base.as_mut_ptr(),
                source.as_ptr(),
                4,
                3,
                BLEND_NORMAL,
                opacity,
                false,
                false
            ));
        }
        assert!(
            base.iter().all(|&v| v == 0),
            "a refused blend leaves the buffer untouched"
        );

        // rz_image_plane / rz_image_plane_image.
        assert!(!rz_image_plane(null_img, PLANE_RED, out.as_mut_ptr(), 4, 3));
        assert!(!rz_image_plane(img, PLANE_RED, ptr::null_mut(), 4, 3));
        assert!(
            !rz_image_plane(img, PLANE_RED, out.as_mut_ptr(), 3, 4),
            "the dimensions must be the image's own"
        );
        assert!(rz_image_plane_image(null_img, PLANE_RED, 0).is_null());
        rz_image_free(img);
    }
}

// ------------------------------------ non-separable modes on one plane vs. RGB --

// The W3C non-separable machinery, written out here from the compositing-1
// pseudocode so the oracle agrees with the SPEC rather than with the core's
// copy of it. `lum` uses the spec's 0.3/0.59/0.11 weights (not Rec. 709,
// which is the luma of a PLANE — a different quantity in a different place).
fn ref_lum(c: [f32; 3]) -> f32 {
    0.3 * c[0] + 0.59 * c[1] + 0.11 * c[2]
}

fn ref_clip_color(mut c: [f32; 3]) -> [f32; 3] {
    let l = ref_lum(c);
    let n = c[0].min(c[1]).min(c[2]);
    let x = c[0].max(c[1]).max(c[2]);
    if n < 0.0 {
        for ch in &mut c {
            *ch = l + (*ch - l) * l / (l - n);
        }
    }
    if x > 1.0 {
        for ch in &mut c {
            *ch = l + (*ch - l) * (1.0 - l) / (x - l);
        }
    }
    c
}

fn ref_set_lum(c: [f32; 3], l: f32) -> [f32; 3] {
    let d = l - ref_lum(c);
    ref_clip_color([c[0] + d, c[1] + d, c[2] + d])
}

fn ref_sat(c: [f32; 3]) -> f32 {
    c[0].max(c[1]).max(c[2]) - c[0].min(c[1]).min(c[2])
}

fn ref_set_sat(c: [f32; 3], s: f32) -> [f32; 3] {
    let (mut lo, mut mid, mut hi) = (0usize, 1usize, 2usize);
    // A hand-written three-element sort by value: no shared helper, so the
    // oracle cannot inherit the implementation's ordering rule.
    if c[lo] > c[mid] {
        std::mem::swap(&mut lo, &mut mid);
    }
    if c[mid] > c[hi] {
        std::mem::swap(&mut mid, &mut hi);
    }
    if c[lo] > c[mid] {
        std::mem::swap(&mut lo, &mut mid);
    }
    let mut out = [0.0f32; 3];
    if c[hi] > c[lo] {
        out[mid] = (c[mid] - c[lo]) * s / (c[hi] - c[lo]);
        out[hi] = s;
    }
    out
}

/// The four HSL blends over unit triples, straight from the spec.
fn ref_blend_triple(mode: c_int, cb: [f32; 3], cs: [f32; 3]) -> [f32; 3] {
    match mode {
        BLEND_HUE => ref_set_lum(ref_set_sat(cs, ref_sat(cb)), ref_lum(cb)),
        BLEND_SATURATION => ref_set_lum(ref_set_sat(cb, ref_sat(cs)), ref_lum(cb)),
        BLEND_COLOR => ref_set_lum(cs, ref_lum(cb)),
        BLEND_LUMINOSITY => ref_set_lum(cb, ref_lum(cs)),
        // Every separable mode reduces to the per-channel reference.
        _ => [
            ref_blend(mode, cb[0], cs[0]),
            ref_blend(mode, cb[1], cs[1]),
            ref_blend(mode, cb[2], cs[2]),
        ],
    }
}

/// `rz_blend_planes_rgb`'s oracle: blend the triples, then fade by opacity
/// against the (opaque) base.
fn ref_blend_rgb(cb: [u8; 3], cs: [u8; 3], mode: c_int, opacity: f32) -> [u8; 3] {
    let b = [
        f32::from(cb[0]) / 255.0,
        f32::from(cb[1]) / 255.0,
        f32::from(cb[2]) / 255.0,
    ];
    let s = [
        f32::from(cs[0]) / 255.0,
        f32::from(cs[1]) / 255.0,
        f32::from(cs[2]) / 255.0,
    ];
    let blended = ref_blend_triple(mode, b, s);
    let mut out = [0u8; 3];
    for c in 0..3 {
        let v = opacity * blended[c] + (1.0 - opacity) * b[c];
        out[c] = (v.clamp(0.0, 1.0) * 255.0).round() as u8;
    }
    out
}

/// Three planes through `rz_blend_planes_rgb`, asserting success.
fn blended_rgb(
    base: &[Vec<u8>; 3],
    source: &[Vec<u8>; 3],
    w: u32,
    h: u32,
    mode: c_int,
    opacity: f32,
) -> [Vec<u8>; 3] {
    let mut out = [base[0].clone(), base[1].clone(), base[2].clone()];
    let ok = unsafe {
        rz_blend_planes_rgb(
            out[0].as_mut_ptr(),
            out[1].as_mut_ptr(),
            out[2].as_mut_ptr(),
            source[0].as_ptr(),
            source[1].as_ptr(),
            source[2].as_ptr(),
            w,
            h,
            mode,
            opacity,
            false,
            false,
        )
    };
    assert!(ok, "rz_blend_planes_rgb refused a well-formed call");
    out
}

#[test]
fn blend_planes_refuses_the_modes_that_carry_nothing_on_one_gray_plane() {
    let (w, h) = (8u32, 4u32);
    let base = asymmetric_plane(w, h);
    let source: Vec<u8> = base.iter().map(|&v| 255 - v).collect();

    // Hue, Saturation and Color would answer the BASE verbatim on a gray
    // triple and Luminosity would answer plain Normal, so a single-plane
    // blend refuses them outright rather than pretending to compute.
    for &mode in &[BLEND_HUE, BLEND_SATURATION, BLEND_COLOR, BLEND_LUMINOSITY] {
        let mut got = base.clone();
        assert!(
            !unsafe {
                rz_blend_planes(
                    got.as_mut_ptr(),
                    source.as_ptr(),
                    w,
                    h,
                    mode,
                    1.0,
                    false,
                    false,
                )
            },
            "mode {mode} must be refused on a single plane"
        );
        assert_eq!(got, base, "a refused blend leaves the buffer untouched");
    }

    // Darker Color and Lighter Color are non-separable too, but their
    // whole-pixel luma pick reduces to Darken/Lighten on gray triples, which
    // is meaningful — they are deliberately still accepted.
    for &(mode, separable) in &[
        (BLEND_DARKER_COLOR, BLEND_DARKEN),
        (BLEND_LIGHTER_COLOR, BLEND_LIGHTEN),
    ] {
        let got = blended(&base, &source, w, h, mode, 1.0);
        for (i, &v) in got.iter().enumerate() {
            let want = ref_blend_plane(base[i], source[i], separable, 1.0, false, false);
            assert_eq!(v, want, "mode {mode} at {i} should reduce to {separable}");
        }
    }
}

#[test]
fn blend_planes_rgb_blends_the_triple_so_the_hsl_modes_mean_something() {
    let (w, h) = (16u32, 8u32);
    // Three planes that are independent of one another: a triple whose
    // channels differ is the only input the HSL modes say anything about.
    let base: [Vec<u8>; 3] = [
        asymmetric_plane(w, h),
        asymmetric_plane(w, h).iter().map(|&v| 255 - v).collect(),
        (0..w * h).map(|i| (i * 5 % 256) as u8).collect(),
    ];
    let source: [Vec<u8>; 3] = [
        (0..w * h).map(|i| (i * 3 % 256) as u8).collect(),
        vec![200u8; (w * h) as usize],
        (0..w * h).map(|i| (255 - (i * 7 % 256)) as u8).collect(),
    ];

    for &mode in &[
        BLEND_HUE,
        BLEND_SATURATION,
        BLEND_COLOR,
        BLEND_LUMINOSITY,
        BLEND_NORMAL,
        BLEND_MULTIPLY,
    ] {
        for &opacity in &[1.0f32, 0.5] {
            let got = blended_rgb(&base, &source, w, h, mode, opacity);
            for i in 0..(w * h) as usize {
                let want = ref_blend_rgb(
                    [base[0][i], base[1][i], base[2][i]],
                    [source[0][i], source[1][i], source[2][i]],
                    mode,
                    opacity,
                );
                for c in 0..3 {
                    // One byte of slack: the oracle and the core reach the
                    // same formula through different f32 orderings.
                    let diff = i32::from(got[c][i]) - i32::from(want[c]);
                    assert!(
                        diff.abs() <= 1,
                        "mode {mode} opacity {opacity} plane {c} at {i}: {} vs {}",
                        got[c][i],
                        want[c]
                    );
                }
            }
        }
    }

    // The point of the whole function: Color really does recolour, where
    // three independent gray blends would have changed nothing at all.
    let colored = blended_rgb(&base, &source, w, h, BLEND_COLOR, 1.0);
    assert!(
        (0..3).any(|c| colored[c] != base[c]),
        "Color left every plane untouched — the triple was not blended as one"
    );
    // Luminosity keeps the base's hue while taking the source's brightness,
    // so it is NOT the source and NOT plain Normal.
    let luminous = blended_rgb(&base, &source, w, h, BLEND_LUMINOSITY, 1.0);
    assert!(
        (0..3).any(|c| luminous[c] != source[c]),
        "Luminosity degenerated to Normal"
    );
}

#[test]
fn blend_planes_rgb_refuses_a_bad_call_and_leaves_the_buffers_alone() {
    let (w, h) = (4u32, 3u32);
    let plane = asymmetric_plane(w, h);
    let mut base = [plane.clone(), plane.clone(), plane.clone()];
    let source = [plane.clone(), plane.clone(), plane.clone()];
    let cases: [(u32, u32, f32); 3] = [(0, h, 1.0), (w, 0, 1.0), (w, h, f32::NAN)];
    for (cw, ch, opacity) in cases {
        assert!(
            !unsafe {
                rz_blend_planes_rgb(
                    base[0].as_mut_ptr(),
                    base[1].as_mut_ptr(),
                    base[2].as_mut_ptr(),
                    source[0].as_ptr(),
                    source[1].as_ptr(),
                    source[2].as_ptr(),
                    cw,
                    ch,
                    BLEND_NORMAL,
                    opacity,
                    false,
                    false,
                )
            },
            "({cw}, {ch}, {opacity}) should be refused"
        );
    }
    // An unknown mode is refused the same way rz_blend_planes refuses one.
    assert!(!unsafe {
        rz_blend_planes_rgb(
            base[0].as_mut_ptr(),
            base[1].as_mut_ptr(),
            base[2].as_mut_ptr(),
            source[0].as_ptr(),
            source[1].as_ptr(),
            source[2].as_ptr(),
            w,
            h,
            99,
            1.0,
            false,
            false,
        )
    });
    assert!(
        base.iter().all(|p| *p == plane),
        "a refused blend leaves every buffer untouched"
    );
}

// ------------------------------------------ the channel budget under geometry --

#[test]
fn growing_the_canvas_refuses_to_break_the_channel_pixel_budget() {
    let dir = TempDir::new().unwrap();
    // 256 channels (the count cap) on a small canvas: cheap to build, and
    // 1900 x 1900 x 256 = 924,160,000 > the 900,000,000-pixel budget while
    // the canvas itself stays far inside the 100 MP cap. A document that
    // reached that size could not be written by rz_doc_save_native, so both
    // growing ops refuse it up front instead.
    let (w, h) = (40u32, 40u32);
    let plane = asymmetric_plane(w, h);
    let mut doc = doc_from(&dir, "budget.png", &opaque_pattern(w, h));
    for i in 0..256 {
        doc = add_channel(doc, &format!("Alpha {i}"), &plane, w, h);
    }
    assert_eq!(channel_count(doc), 256);

    assert!(
        unsafe { rz_doc_resize(doc, 1900, 1900, FILTER_BILINEAR) }.is_null(),
        "resize past the channel budget must refuse"
    );
    assert!(
        unsafe { rz_doc_canvas_resize(doc, 1900, 1900, 0, 0) }.is_null(),
        "canvas_resize past the channel budget must refuse"
    );
    assert_eq!(
        channel_count(doc),
        256,
        "a refused geometry op leaves the document alone"
    );

    // The same document grows happily to a size the budget allows, so the
    // refusal is the BUDGET and not "any resize with channels".
    let small = unsafe { rz_doc_resize(doc, 60, 60, FILTER_BILINEAR) };
    assert!(!small.is_null(), "a resize inside the budget must succeed");
    assert_eq!(doc_dims(small), (60, 60));
    assert_eq!(channel_count(small), 256);
    assert_eq!(channel_plane(small, 0).len(), 60 * 60);
    unsafe { rz_doc_free(small) };
    let padded = unsafe { rz_doc_canvas_resize(doc, 60, 60, 0, 0) };
    assert!(!padded.is_null());
    assert_eq!(channel_plane(padded, 0).len(), 60 * 60);
    unsafe { rz_doc_free(padded) };
    unsafe { rz_doc_free(doc) };

    // And with NO channels the very same 1900 x 1900 growth is fine: the
    // budget is the only thing the refusal above was about.
    let plain = doc_from(&dir, "plain.png", &opaque_pattern(w, h));
    let grown = unsafe { rz_doc_resize(plain, 1900, 1900, FILTER_BILINEAR) };
    assert!(!grown.is_null(), "a channel-less document resizes freely");
    assert_eq!(doc_dims(grown), (1900, 1900));
    unsafe { rz_doc_free(grown) };
    let padded = unsafe { rz_doc_canvas_resize(plain, 1900, 1900, 0, 0) };
    assert!(!padded.is_null());
    unsafe { rz_doc_free(padded) };
    unsafe { rz_doc_free(plain) };
}

/// `rz_max_channels_at` answers that same budget as a NUMBER — what a host
/// needs to say "this canvas holds at most N channels; delete some" instead
/// of refusing silently. Checked against an independently written formula and
/// against the refusals of the test above.
#[test]
fn max_channels_at_answers_the_budget_the_geometry_ops_refuse_on() {
    // The two caps, restated here rather than imported, so the test cannot
    // agree with the core by construction.
    let expected = |w: u64, h: u64| (900_000_000u64 / (w * h)).min(256) as usize;
    assert_eq!(rz_max_channels_at(1900, 1900), expected(1900, 1900));
    assert_eq!(rz_max_channels_at(2000, 2000), 225);
    assert_eq!(
        rz_max_channels_at(2001, 2000),
        224,
        "one pixel wider is one channel fewer"
    );
    assert_eq!(
        rz_max_channels_at(60, 60),
        256,
        "the count cap wins on a small canvas"
    );
    assert_eq!(
        rz_max_channels_at(0, 0),
        256,
        "no pixels, so only the count cap"
    );
    assert_eq!(
        rz_max_channels_at(u32::MAX, u32::MAX),
        0,
        "nothing fits a canvas that could not exist"
    );

    // The same fixture the geometry test refuses on: 256 channels on a 40x40
    // canvas. The number predicts both its refusal and its success, which is
    // the whole point of exposing it.
    let dir = TempDir::new().unwrap();
    let (w, h) = (40u32, 40u32);
    let plane = asymmetric_plane(w, h);
    let mut doc = doc_from(&dir, "explain.png", &opaque_pattern(w, h));
    for i in 0..256 {
        doc = add_channel(doc, &format!("Alpha {i}"), &plane, w, h);
    }
    assert!(
        channel_count(doc) > rz_max_channels_at(1900, 1900),
        "the number says 1900x1900 will refuse"
    );
    assert!(unsafe { rz_doc_resize(doc, 1900, 1900, FILTER_BILINEAR) }.is_null());
    assert!(unsafe { rz_doc_canvas_resize(doc, 1900, 1900, 0, 0) }.is_null());
    assert!(
        channel_count(doc) <= rz_max_channels_at(60, 60),
        "and that 60x60 will not"
    );
    let small = unsafe { rz_doc_resize(doc, 60, 60, FILTER_BILINEAR) };
    assert!(!small.is_null());
    // Nine luminosity masks on top of 256 channels break the COUNT cap, and
    // the same number says so before the call.
    assert!(channel_count(small) + 9 > rz_max_channels_at(60, 60));
    assert!(unsafe { rz_doc_add_luminosity_masks(small) }.is_null());
    unsafe {
        rz_doc_free(small);
        rz_doc_free(doc);
    }
}
