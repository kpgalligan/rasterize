//! Selection-region tests through the C FFI: the magic wand, bucket fill
//! and gradients, clearing a selection, mask feathering, and the grow /
//! shrink / border / smooth morphology family. Shared fixtures live in
//! `tests/common`.

use std::ptr;

use image::{Rgba, RgbaImage};
use rasterize_core::doc::RzDocument;
use rasterize_core::doc_select::{feather_mask, grow_mask, smooth_mask};
use rasterize_core::ffi_doc::*;
use tempfile::TempDir;

mod common;
use common::*;

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
    let mut mask = [0u8; 24];
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
    assert!(px[0] <= 13, "left end near black, got {}", px[0]);
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

// ------------------------------------------------ clearing a selection --

/// `rz_doc_clear_selection` with the canvas-sized `mask`, asserting success
/// and freeing the old handle.
fn clear_sel(doc: *mut RzDocument, idx: usize, mask: &[u8]) -> *mut RzDocument {
    let (w, h) = unsafe { (rz_doc_width(doc), rz_doc_height(doc)) };
    assert_eq!(mask.len(), (w * h) as usize, "the mask is canvas-sized");
    apply(doc, |d| unsafe {
        rz_doc_clear_selection(d, idx, mask.as_ptr(), w, h)
    })
}

/// The pinned formula: straight alpha scaled by the UNselected fraction.
fn cleared_alpha(alpha: u8, coverage: u8) -> u8 {
    (f32::from(alpha) * f32::from(255 - coverage) / 255.0).round() as u8
}

#[test]
fn clear_selection_erases_covered_pixels_and_leaves_the_rest() {
    let dir = TempDir::new().unwrap();
    let doc = doc_from(&dir, "clear-full.png", &opaque_pattern(6, 4));
    let before = layer_pixels(doc, 0);

    // Fully selected rect [1, 4) x [1, 3).
    let mask = rect_mask(6, 4, 1, 1, 4, 3);
    let cleared = clear_sel(unsafe { rz_doc_clone(doc) }, 0, &mask);
    let after = layer_pixels(cleared, 0);
    for y in 0..4 {
        for x in 0..6 {
            let inside = (1..4).contains(&x) && (1..3).contains(&y);
            let got = pixel(&after, 6, x, y);
            if inside {
                assert_eq!(got, [0, 0, 0, 0], "({x},{y}) cleared: alpha AND color");
            } else {
                assert_eq!(
                    got,
                    pixel(&before, 6, x, y),
                    "({x},{y}) is outside the selection: byte-identical"
                );
            }
        }
    }
    assert_eq!(layer_pixels(doc, 0), before, "the operation is pure");

    // A mask that selects nothing is not an error: it succeeds unchanged.
    let empty = vec![0u8; 24];
    let untouched = clear_sel(unsafe { rz_doc_clone(doc) }, 0, &empty);
    assert_eq!(layer_pixels(untouched, 0), before);

    for d in [doc, cleared, untouched] {
        unsafe { rz_doc_free(d) };
    }
}

#[test]
fn clear_selection_is_proportional_and_never_scales_color() {
    let dir = TempDir::new().unwrap();
    // One opaque-ish (alpha 200) row of distinct colors under a coverage ramp.
    const RAMP: [u8; 5] = [0, 64, 128, 192, 255];
    let img = RgbaImage::from_fn(5, 1, |x, _| {
        Rgba([(x * 40 + 11) as u8, 90, (250 - x * 30) as u8, 200])
    });
    let doc = doc_from(&dir, "clear-ramp.png", &img);
    let before = layer_pixels(doc, 0);
    let cleared = clear_sel(doc, 0, &RAMP);
    let after = layer_pixels(cleared, 0);

    for (x, &c) in RAMP.iter().enumerate() {
        let src = pixel(&before, 5, x as u32, 0);
        let got = pixel(&after, 5, x as u32, 0);
        let want = cleared_alpha(src[3], c);
        assert_eq!(got[3], want, "coverage {c}: alpha {} -> {want}", src[3]);
        if want == 0 {
            assert_eq!(got, [0, 0, 0, 0], "coverage {c}: nothing of it remains");
        } else {
            assert_eq!(
                [got[0], got[1], got[2]],
                [src[0], src[1], src[2]],
                "coverage {c}: STRAIGHT alpha, so the color must not be scaled"
            );
        }
    }

    // The pinned numbers, so a plausible-but-wrong formula cannot pass.
    let alphas: Vec<u8> = (0..5).map(|x| pixel(&after, 5, x, 0)[3]).collect();
    assert_eq!(
        alphas,
        vec![200, 150, 100, 49, 0],
        "alpha * (255 - c) / 255"
    );

    unsafe { rz_doc_free(cleared) };
}

#[test]
fn clear_selection_scales_a_semi_transparent_pixel() {
    let dir = TempDir::new().unwrap();
    let doc = doc_from(&dir, "clear-semi.png", &solid(2, 1, [10, 20, 30, 128]));
    let cleared = clear_sel(doc, 0, &[128, 255]);
    let px = layer_pixels(cleared, 0);
    assert_eq!(
        pixel(&px, 2, 0, 0),
        [10, 20, 30, 64],
        "alpha 128 under half coverage -> 64, color kept"
    );
    assert_eq!(pixel(&px, 2, 1, 0), [0, 0, 0, 0]);
    unsafe { rz_doc_free(cleared) };
}

#[test]
fn clear_selection_maps_canvas_coordinates_on_an_offset_layer() {
    let dir = TempDir::new().unwrap();
    // 5x3 canvas; an opaque 4x2 layer at (-1, 1) hangs off the left edge.
    let doc = ffi_mask_fixture(&dir, "clear-offset", (5, 3), (4, 2), (-1, 1));
    let before = layer_pixels(doc, 1);
    // Distinctive per-canvas-pixel coverage so a mis-mapping cannot pass.
    let sel = selection(5, 3, |x, y| (x * 50 + y * 17) as u8);
    let cleared = clear_sel(unsafe { rz_doc_clone(doc) }, 1, &sel);
    let after = layer_pixels(cleared, 1);

    let mut changed = 0;
    for ly in 0..2u32 {
        for lx in 0..4u32 {
            let cx = lx as i64 - 1;
            let cy = ly as i64 + 1;
            let src = pixel(&before, 4, lx, ly);
            let got = pixel(&after, 4, lx, ly);
            if cx < 0 {
                assert_eq!(got, src, "layer ({lx},{ly}) is off-canvas: untouched");
                continue;
            }
            let c = sel[cy as usize * 5 + cx as usize];
            assert_eq!(
                got[3],
                cleared_alpha(src[3], c),
                "layer ({lx},{ly}) -> canvas ({cx},{cy}), coverage {c}"
            );
            assert_eq!(
                [got[0], got[1], got[2]],
                [src[0], src[1], src[2]],
                "partly surviving pixel keeps its color"
            );
            changed += usize::from(got[3] != src[3]);
        }
    }
    assert!(changed >= 5, "the selection did reach the layer");
    assert_eq!(
        pixel(&after, 4, 0, 0),
        BLUE,
        "the off-canvas column stays fully opaque blue"
    );

    unsafe { rz_doc_free(cleared) };
    unsafe { rz_doc_free(doc) };
}

#[test]
fn clear_selection_keeps_the_layer_mask_meta_and_properties() {
    let dir = TempDir::new().unwrap();
    // A 4x2 layer at (1, 0) on a 4x2 canvas: its last column is off-canvas.
    let doc = ffi_mask_fixture(&dir, "clear-props", (4, 2), (4, 2), (1, 0));
    let doc = apply(doc, |d| unsafe { rz_doc_with_layer_opacity(d, 1, 0.5) });
    let doc = apply(doc, |d| unsafe {
        rz_doc_with_layer_blend_mode(d, 1, BLEND_MULTIPLY)
    });
    let doc = apply(doc, |d| unsafe { rz_doc_with_layer_visible(d, 1, false) });
    let sel = selection(4, 2, |x, _| if x < 2 { 255 } else { 0 });
    let doc = apply(doc, |d| unsafe {
        rz_doc_adding_layer_mask(d, 1, MASK_FROM_SELECTION, sel.as_ptr(), 4, 2)
    });
    let doc = set_meta(doc, 1, TEXT_META);
    let mask_before = ffi_mask_bytes(doc, 1);

    let cleared = clear_sel(doc, 1, &[255u8; 8]);

    assert_eq!(layer_name(cleared, 1), "Top");
    assert_eq!(unsafe { rz_doc_layer_opacity(cleared, 1) }, 0.5);
    assert_eq!(
        unsafe { rz_doc_layer_blend_mode(cleared, 1) },
        BLEND_MULTIPLY
    );
    assert!(!unsafe { rz_doc_layer_visible(cleared, 1) });
    assert_eq!(layer_offset(cleared, 1), (1, 0));
    assert_eq!(layer_dims(cleared, 1), (4, 2));
    assert_eq!(ffi_mask_flags(cleared, 1), (true, true));
    assert_eq!(
        ffi_mask_bytes(cleared, 1),
        mask_before,
        "the layer's own mask is untouched"
    );
    assert_eq!(
        ffi_meta(cleared, 1).as_deref(),
        Some(TEXT_META),
        "meta survives: the host decides text-layer policy, not the core"
    );

    // The pixels the selection reached are gone; the column past the canvas
    // edge (layer x 3 -> canvas x 4) is not.
    let px = layer_pixels(cleared, 1);
    for y in 0..2 {
        for x in 0..3 {
            assert_eq!(pixel(&px, 4, x, y), [0, 0, 0, 0], "({x},{y}) cleared");
        }
        assert_eq!(pixel(&px, 4, 3, y), BLUE, "off-canvas column untouched");
    }

    unsafe { rz_doc_free(cleared) };
}

#[test]
fn clear_selection_rejects_bad_index_size_and_null() {
    let dir = TempDir::new().unwrap();
    let doc = doc_from(&dir, "clear-errors.png", &opaque_pattern(4, 3));
    let mask = [255u8; 12];
    unsafe {
        assert!(
            rz_doc_clear_selection(ptr::null(), 0, mask.as_ptr(), 4, 3).is_null(),
            "NULL document"
        );
        assert!(
            rz_doc_clear_selection(doc, 0, ptr::null(), 4, 3).is_null(),
            "NULL mask"
        );
        assert!(
            rz_doc_clear_selection(doc, 1, mask.as_ptr(), 4, 3).is_null(),
            "index past the top of the stack"
        );
        assert!(rz_doc_clear_selection(doc, usize::MAX, mask.as_ptr(), 4, 3).is_null());
        // The dimensions are checked against the CANVAS before the buffer is
        // read, so a wrong pair can only reject it, never widen the read.
        assert!(
            rz_doc_clear_selection(doc, 0, mask.as_ptr(), 3, 4).is_null(),
            "transposed dimensions"
        );
        assert!(
            rz_doc_clear_selection(doc, 0, mask.as_ptr(), 4, 2).is_null(),
            "short mask"
        );
        assert!(rz_doc_clear_selection(doc, 0, mask.as_ptr(), 0, 0).is_null());
    }
    assert_eq!(
        layer_pixels(doc, 0),
        opaque_pattern(4, 3).into_raw(),
        "a refused call leaves the input document untouched"
    );

    // The safe API refuses the same inputs.
    let model = RzDocument::from_pixels(opaque_pattern(4, 3));
    assert!(
        model.clear_selection(0, &[255u8; 11]).is_none(),
        "a mask that is not canvas-sized"
    );
    assert!(model.clear_selection(9, &[255u8; 12]).is_none());
    assert!(model.clear_selection(0, &[255u8; 12]).is_some());

    unsafe { rz_doc_free(doc) };
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

// ------------------------------------------------- selection morphology --

#[test]
fn grow_extends_edges_by_radius_and_rounds_corners() {
    let (w, h) = (40u32, 40u32);
    let mut mask = rect_mask(w, h, 10, 10, 30, 30);
    assert!(unsafe { rz_selection_grow(mask.as_mut_ptr(), w, h, 5.0) });
    let at = |x: u32, y: u32| mask[(y * w + x) as usize];

    // Mid-edge: the contour (between pixels 9 and 10) moves outward by
    // exactly 5px on all four sides, to between pixels 4 and 5.
    assert_eq!(at(5, 20), 255, "left edge midpoint at distance r is in");
    assert_eq!(at(4, 20), 0, "one past the grown left edge is out");
    assert_eq!(at(34, 20), 255);
    assert_eq!(at(35, 20), 0);
    assert_eq!(at(20, 5), 255);
    assert_eq!(at(20, 4), 0);
    assert_eq!(at(20, 34), 255);
    assert_eq!(at(20, 35), 0);
    assert_eq!(at(20, 20), 255, "interior untouched");

    // Corners are circular, not square: the diagonal pixel at Euclidean
    // distance sqrt(50) > 5 from the nearest original pixel stays out even
    // though a Chebyshev (square) dilation would take it, while the
    // axis-aligned pixel at exactly 5 is in.
    assert_eq!(at(5, 5), 0, "diagonal corner pixel beyond r stays out");
    assert_eq!(at(5, 10), 255, "axis-aligned pixel at distance r is in");
    // Partway around the arc the fresh edge is anti-aliased.
    let arc = at(6, 6);
    assert!(arc > 0 && arc < 255, "corner arc pixel anti-aliases: {arc}");
}

#[test]
fn shrink_then_grow_restores_edges_away_from_corners() {
    let (w, h) = (40u32, 40u32);
    let original = rect_mask(w, h, 8, 8, 32, 32);
    let mut mask = original.clone();
    let at = |m: &[u8], x: u32, y: u32| m[(y * w + x) as usize];

    assert!(unsafe { rz_selection_shrink(mask.as_mut_ptr(), w, h, 4.0) });
    // The mid-edge contour (between pixels 7 and 8) moved inward by
    // exactly 4px, to between pixels 11 and 12.
    assert_eq!(at(&mask, 12, 20), 255);
    assert_eq!(at(&mask, 11, 20), 0);

    assert!(unsafe { rz_selection_grow(mask.as_mut_ptr(), w, h, 4.0) });
    // Growing back by the same radius restores the edges: identity along
    // the mid row and column (only the corners, now filleted at radius 4,
    // may differ).
    for i in 0..w {
        assert_eq!(at(&mask, i, 20), at(&original, i, 20), "row 20, x={i}");
        assert_eq!(at(&mask, 20, i), at(&original, 20, i), "col 20, y={i}");
    }
}

#[test]
fn border_bands_straddle_the_contour() {
    let (w, h) = (40u32, 40u32);
    let mut mask = rect_mask(w, h, 10, 10, 30, 30);
    assert!(unsafe { rz_selection_border(mask.as_mut_ptr(), w, h, 3.0) });
    let at = |x: u32, y: u32| mask[(y * w + x) as usize];

    // Left edge, mid row: the contour runs between pixels 9 and 10, so
    // |s| = 0.5 for the pixel on each side (fully in the 3px band),
    // 1.5 one step further (the band's half-covered AA edge), and 2.5
    // beyond it (out).
    assert_eq!(at(9, 20), 255);
    assert_eq!(at(10, 20), 255);
    assert_eq!(at(8, 20), 128, "AA edge outside the contour");
    assert_eq!(at(11, 20), 128, "AA edge inside the contour");
    assert_eq!(at(7, 20), 0);
    assert_eq!(at(12, 20), 0);

    // The band REPLACES the selection: deep inside is no longer selected.
    assert_eq!(at(20, 20), 0);
    assert_eq!(at(0, 0), 0);
}

#[test]
fn morphology_full_and_empty_masks() {
    let (w, h) = (12u32, 9u32);
    let len = (w * h) as usize;

    // The canvas boundary is not a contour: a full mask has no outside
    // pixels, so there is nothing to grow into or shrink from...
    let mut full = vec![255u8; len];
    assert!(unsafe { rz_selection_grow(full.as_mut_ptr(), w, h, 3.0) });
    assert!(full.iter().all(|&v| v == 255), "grow of full stays full");
    assert!(unsafe { rz_selection_shrink(full.as_mut_ptr(), w, h, 3.0) });
    assert!(full.iter().all(|&v| v == 255), "shrink of full stays full");

    // ...and an empty mask has no inside pixels, hence no contour either.
    let mut empty = vec![0u8; len];
    assert!(unsafe { rz_selection_grow(empty.as_mut_ptr(), w, h, 3.0) });
    assert!(empty.iter().all(|&v| v == 0), "grow of empty stays empty");
    assert!(unsafe { rz_selection_shrink(empty.as_mut_ptr(), w, h, 3.0) });
    assert!(empty.iter().all(|&v| v == 0), "shrink of empty stays empty");

    // Border of either is empty: no contour, no band.
    let mut full = vec![255u8; len];
    assert!(unsafe { rz_selection_border(full.as_mut_ptr(), w, h, 4.0) });
    assert!(full.iter().all(|&v| v == 0), "border of full is empty");
    let mut empty = vec![0u8; len];
    assert!(unsafe { rz_selection_border(empty.as_mut_ptr(), w, h, 4.0) });
    assert!(empty.iter().all(|&v| v == 0), "border of empty is empty");
}

#[test]
fn smooth_keeps_straight_edges_and_rounds_corners() {
    // A vertical edge whose 50% contour runs through pixel centers:
    // columns left of 15 fully selected, column 15 at exactly 128, the
    // rest empty.
    let (w, h) = (30u32, 30u32);
    let mut mask = vec![0u8; (w * h) as usize];
    for y in 0..h {
        for x in 0..15 {
            mask[(y * w + x) as usize] = 255;
        }
        mask[(y * w + 15) as usize] = 128;
    }
    assert!(unsafe { rz_selection_smooth(mask.as_mut_ptr(), w, h, 3.0) });
    let at = |x: u32, y: u32| mask[(y * w + x) as usize];
    // The blur is symmetric across a straight edge and smoothstep fixes
    // 1/2, so the midline does not move.
    let mid = at(15, 15);
    assert!((127..=129).contains(&mid), "midline moved: {mid}");
    assert_eq!(at(5, 15), 255, "deep inside untouched");
    assert_eq!(at(28, 15), 0, "deep outside untouched");
    assert!(at(13, 15) > 128, "inside of the edge keeps its side");
    assert!(at(17, 15) < 128, "outside of the edge keeps its side");

    // A right-angle corner is rounded: the corner pixel of a square drops
    // below 50% while the mid-edge pixels keep their sides.
    let mut sq = rect_mask(w, h, 10, 10, 26, 26);
    smooth_mask(&mut sq, w, h, 3.0);
    let at = |x: u32, y: u32| sq[(y * w + x) as usize];
    assert!(at(10, 10) < 128, "corner pixel rounded off: {}", at(10, 10));
    assert!(at(10, 18) >= 128, "mid-edge pixel keeps its side");
    assert!(at(9, 18) < 128, "outside mid-edge pixel keeps its side");
    assert_eq!(at(18, 18), 255, "interior saturates back to full");
}

#[test]
fn grow_binarizes_soft_input_at_the_50_percent_contour() {
    // Feathering first must not change what grow produces away from the
    // corners: the soft ramp resolves back to the original 50% contour,
    // which for a hard-edged rect sits exactly at the old edge.
    let (w, h) = (40u32, 40u32);
    let mut hard = rect_mask(w, h, 10, 10, 30, 30);
    let mut soft = hard.clone();
    feather_mask(&mut soft, w, h, 2.0);
    let edge = soft[(20 * w + 9) as usize];
    assert!(edge > 0 && edge < 128, "feather softened pixel 9: {edge}");
    grow_mask(&mut hard, w, h, 4.0);
    grow_mask(&mut soft, w, h, 4.0);
    for x in 0..w {
        assert_eq!(
            soft[(20 * w + x) as usize],
            hard[(20 * w + x) as usize],
            "row 20, x={x}"
        );
    }

    // The threshold is coverage >= 128: a 128 pixel seeds the distance
    // field, 127 does not.
    let mut seed = vec![0u8; 81];
    seed[4 * 9 + 4] = 128;
    grow_mask(&mut seed, 9, 9, 2.0);
    assert_eq!(seed[4 * 9 + 4], 255, "the seed resolves to full");
    assert_eq!(seed[4 * 9 + 6], 255, "axis pixel at distance 2 is in");
    assert_eq!(seed[4 * 9 + 7], 0, "axis pixel at distance 3 is out");
    let diag = seed[6 * 9 + 6];
    assert!(
        diag > 0 && diag < 255,
        "diagonal at sqrt(8) anti-aliases: {diag}"
    );

    let mut faint = vec![127u8; 81];
    grow_mask(&mut faint, 9, 9, 2.0);
    assert!(faint.iter().all(|&v| v == 0), "sub-50% coverage is no seed");
}

#[test]
fn morphology_rejects_null_zero_size_and_non_finite() {
    type MaskFn = unsafe extern "C" fn(*mut u8, u32, u32, f32) -> bool;
    let fns: [MaskFn; 4] = [
        rz_selection_grow,
        rz_selection_shrink,
        rz_selection_border,
        rz_selection_smooth,
    ];
    let original = rect_mask(4, 4, 1, 1, 3, 3);
    for f in fns {
        let mut mask = original.clone();
        assert!(!unsafe { f(ptr::null_mut(), 2, 2, 1.0) });
        assert!(!unsafe { f(mask.as_mut_ptr(), 0, 4, 1.0) });
        assert!(!unsafe { f(mask.as_mut_ptr(), 4, 0, 1.0) });
        assert!(!unsafe { f(mask.as_mut_ptr(), 4, 4, f32::NAN) });
        assert!(!unsafe { f(mask.as_mut_ptr(), 4, 4, f32::INFINITY) });
        assert_eq!(mask, original, "a refused call leaves the mask alone");
        // Zero and negative parameters succeed as no-ops, exactly like
        // rz_selection_feather's radius.
        assert!(unsafe { f(mask.as_mut_ptr(), 4, 4, 0.0) });
        assert!(unsafe { f(mask.as_mut_ptr(), 4, 4, -2.0) });
        assert_eq!(mask, original, "non-positive parameters are no-ops");
    }
}
