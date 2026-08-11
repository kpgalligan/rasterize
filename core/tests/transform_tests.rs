//! Free-transform tests: the arbitrary-affine layer transform through
//! `rz_doc_transform_layer` — exact fast paths, resampling, mask carriage,
//! and the composed-quarter-turn exactness guarantees. Shared fixtures live
//! in `tests/common`.

use std::ffi::c_int;
use std::ptr;
use std::sync::Arc;

use image::{GrayImage, Luma, Rgba, RgbaImage};
use rasterize_core::doc::{BlendMode, RzDocument};
use rasterize_core::ffi_doc::*;

mod common;
use common::*;

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
