//! Perspective-transform tests: `rz_doc_perspective_layer` — the corner-quad
//! projective transform. The oracles are independent of the solve: incidence
//! geometry (diagonals map to diagonals), point-in-quad tests written from
//! cross products, the affine pipeline for parallelogram quads, and the
//! alpha==mask twin invariant. Shared fixtures live in `tests/common`.

use std::ffi::c_int;
use std::ptr;

use image::{Rgba, RgbaImage};
use rasterize_core::doc::{MaskKind, RzDocument};
use rasterize_core::ffi_doc::*;

mod common;
use common::*;

/// Runs the transform through its FFI entry point on a copy of `doc`,
/// returning the new document, or `None` when the call refuses.
fn warp(doc: &RzDocument, idx: usize, q: [f64; 8], filter: c_int) -> Option<RzDocument> {
    let handle = Box::into_raw(Box::new(doc.clone()));
    let out = unsafe { rz_doc_perspective_layer(handle, idx, q.as_ptr(), filter) };
    unsafe { rz_doc_free(handle) };
    if out.is_null() {
        None
    } else {
        Some(*unsafe { Box::from_raw(out) })
    }
}

/// [`warp`], asserting success.
fn warped(doc: &RzDocument, idx: usize, q: [f64; 8], filter: c_int) -> RzDocument {
    warp(doc, idx, q, filter).expect("perspective_layer must succeed")
}

const SAMPLERS: [c_int; 4] = [
    FILTER_NEAREST,
    FILTER_BILINEAR,
    FILTER_CATMULL_ROM,
    FILTER_LANCZOS3,
];

/// A 4x3 layer whose fully transparent pixels carry deliberately WHITE color
/// bytes, so "byte-identical" on the lossless paths really means it (any
/// resample would zero them through premultiplication).
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

/// Red canvas under the quirky layer at `offset` (index 1).
fn fixture(canvas: (u32, u32), offset: (i32, i32)) -> RzDocument {
    RzDocument::from_pixels(solid(canvas.0, canvas.1, RED))
        .adding_image_layer(0, quirky_layer(), "Top")
        .expect("add layer")
        .with_layer_offset(1, offset.0, offset.1)
        .expect("set offset")
}

/// The quad the identity maps `rect` to: its own corners, TL TR BR BL.
fn rect_quad(x: f64, y: f64, w: f64, h: f64) -> [f64; 8] {
    [x, y, x + w, y, x + w, y + h, x, y + h]
}

// ------------------------------------------------------------- geometry --

/// Intersection of segments a-b and c-d, solved from the parametric forms —
/// plain 2x2 linear algebra, no homography anywhere near it.
fn line_intersection(a: (f64, f64), b: (f64, f64), c: (f64, f64), d: (f64, f64)) -> (f64, f64) {
    let (r, s) = ((b.0 - a.0, b.1 - a.1), (d.0 - c.0, d.1 - c.1));
    let den = r.0 * s.1 - r.1 * s.0;
    assert!(den.abs() > 1e-9, "diagonals must not be parallel");
    let t = ((c.0 - a.0) * s.1 - (c.1 - a.1) * s.0) / den;
    (a.0 + t * r.0, a.1 + t * r.1)
}

/// True when `p` is inside the convex quad (TL TR BR BL, either winding):
/// every edge cross product carries the same sign.
fn point_in_quad(p: (f64, f64), q: &[f64; 8]) -> bool {
    let corners = [(q[0], q[1]), (q[2], q[3]), (q[4], q[5]), (q[6], q[7])];
    let mut sign = 0.0f64;
    for i in 0..4 {
        let (ax, ay) = corners[i];
        let (bx, by) = corners[(i + 1) % 4];
        let cross = (bx - ax) * (p.1 - ay) - (by - ay) * (p.0 - ax);
        if sign == 0.0 {
            sign = cross.signum();
        } else if cross.signum() != sign {
            return false;
        }
    }
    true
}

/// The smallest distance from `p` to the quad's BOUNDARY (edge segments,
/// not their infinite lines) — the probes below assert a margin so sampling
/// half-pixels cannot flip a verdict.
fn edge_margin(p: (f64, f64), q: &[f64; 8]) -> f64 {
    let corners = [(q[0], q[1]), (q[2], q[3]), (q[4], q[5]), (q[6], q[7])];
    let mut min = f64::INFINITY;
    for i in 0..4 {
        let (ax, ay) = corners[i];
        let (bx, by) = corners[(i + 1) % 4];
        let (ex, ey) = (bx - ax, by - ay);
        let t = (((p.0 - ax) * ex + (p.1 - ay) * ey) / (ex * ex + ey * ey)).clamp(0.0, 1.0);
        let (nx, ny) = (ax + t * ex, ay + t * ey);
        min = min.min(((p.0 - nx).powi(2) + (p.1 - ny).powi(2)).sqrt());
    }
    min
}

// ---------------------------------------------------------------- tests --

#[test]
fn parallelogram_quads_delegate_to_the_lossless_affine_paths() {
    let doc = fixture((8, 6), (2, 1));
    let before = doc.layers[1].pixels.as_raw().clone();

    for filter in SAMPLERS {
        // The rect's own corners: identity, byte for byte.
        let out = warped(&doc, 1, rect_quad(2.0, 1.0, 4.0, 3.0), filter);
        assert_eq!(out.layers[1].offset, (2, 1), "identity keeps the offset");
        assert_eq!(
            out.layers[1].pixels.as_raw(),
            &before,
            "an identity quad must not resample (filter {filter})"
        );

        // The same corners moved by a whole-pixel translation: still a
        // plain pixel copy, transparent pixels' color bytes included.
        let moved = warped(&doc, 1, rect_quad(5.0, -3.0, 4.0, 3.0), filter);
        assert_eq!(moved.layers[1].offset, (5, -3));
        assert_eq!(
            moved.layers[1].pixels.as_raw(),
            &before,
            "an integer-translation quad must be a pixel copy (filter {filter})"
        );
    }
}

#[test]
fn a_sheared_parallelogram_quad_matches_transform_layer() {
    let doc = fixture((8, 6), (2, 1));
    // A non-axis-aligned parallelogram: shear the bottom edge sideways. The
    // reference affine is derived from the same three corners the
    // delegation uses, so the two paths must agree byte for byte.
    let quad = [2.0, 1.0, 6.0, 1.0, 8.5, 4.0, 4.5, 4.0];
    let (rx, ry, rw, rh) = (2.0, 1.0, 4.0, 3.0);
    let a = (quad[2] - quad[0]) / rw;
    let b = (quad[3] - quad[1]) / rw;
    let c = (quad[6] - quad[0]) / rh;
    let d = (quad[7] - quad[1]) / rh;
    let m = [
        a,
        b,
        c,
        d,
        quad[0] - a * rx - c * ry,
        quad[1] - b * rx - d * ry,
    ];

    for filter in SAMPLERS {
        let via_quad = warped(&doc, 1, quad, filter);
        let handle = Box::into_raw(Box::new(doc.clone()));
        let reference = unsafe { rz_doc_transform_layer(handle, 1, m.as_ptr(), filter) };
        unsafe { rz_doc_free(handle) };
        assert!(!reference.is_null());
        let reference = *unsafe { Box::from_raw(reference) };
        assert_eq!(via_quad.layers[1].offset, reference.layers[1].offset);
        assert_eq!(
            via_quad.layers[1].pixels.as_raw(),
            reference.layers[1].pixels.as_raw(),
            "parallelogram quad and affine matrix must agree (filter {filter})"
        );
    }
}

/// The 41x41 red layer with a 5x5 black dot at its centre that the
/// geometric tests warp, on a white 60x60 canvas at `offset` (index 1).
fn dot_fixture_at(offset: (i32, i32)) -> RzDocument {
    let dot = RgbaImage::from_fn(41, 41, |x, y| {
        if (18..=22).contains(&x) && (18..=22).contains(&y) {
            Rgba([0, 0, 0, 255])
        } else {
            Rgba(RED)
        }
    });
    RzDocument::from_pixels(solid(60, 60, WHITE))
        .adding_image_layer(0, dot, "Dot")
        .expect("add layer")
        .with_layer_offset(1, offset.0, offset.1)
        .expect("set offset")
}

fn dot_fixture() -> RzDocument {
    dot_fixture_at((0, 0))
}

/// The shared body of the incidence tests: warps [`dot_fixture`]'s layer
/// onto `quad` with Nearest, then asserts the centre dot lands on the
/// quad's diagonal crossing, quarter-way corner probes are red, and the
/// given extent-corner pixels (outside the quad but inside its bounding
/// box) are fully transparent. Every probe's precondition (inside/outside
/// with margin, clear of the dot) is asserted too, so a bad quad choice
/// fails loudly instead of proving nothing.
fn assert_dot_lands_on_diagonal_crossing(
    doc: &RzDocument,
    quad: [f64; 8],
    expect_offset: (i32, i32),
    transparent_extent_corners: &[(u32, u32)],
) -> (f64, f64) {
    let out = warped(doc, 1, quad, FILTER_NEAREST);
    let layer = &out.layers[1];
    let (ox, oy) = layer.offset;
    assert_eq!(
        (ox, oy),
        expect_offset,
        "offset is the quad bbox's top-left"
    );

    let sample = |p: (f64, f64)| -> [u8; 4] {
        let (x, y) = (
            (p.0.floor() as i32 - ox) as u32,
            (p.1.floor() as i32 - oy) as u32,
        );
        layer.pixels.get_pixel(x, y).0
    };

    // A projective map takes lines to lines, so the rect's diagonals land
    // on the quad's diagonals and the dot — at their crossing — must land
    // on the QUAD's diagonal crossing, a point plain 2D geometry finds
    // with no homography.
    let crossing = line_intersection(
        (quad[0], quad[1]),
        (quad[4], quad[5]),
        (quad[2], quad[3]),
        (quad[6], quad[7]),
    );
    assert_eq!(
        sample(crossing),
        [0, 0, 0, 255],
        "the centre dot must sit on the quad's diagonal crossing"
    );

    // Probes a quarter of the way from each corner toward the centroid:
    // inside the quad with margin, far from the dot's image — red.
    let centroid = (
        (quad[0] + quad[2] + quad[4] + quad[6]) / 4.0,
        (quad[1] + quad[3] + quad[5] + quad[7]) / 4.0,
    );
    for i in 0..4 {
        let corner = (quad[2 * i], quad[2 * i + 1]);
        let p = (
            corner.0 + 0.25 * (centroid.0 - corner.0),
            corner.1 + 0.25 * (centroid.1 - corner.1),
        );
        let centre = (p.0.floor() + 0.5, p.1.floor() + 0.5);
        assert!(point_in_quad(centre, &quad) && edge_margin(centre, &quad) > 1.5);
        let dist = ((centre.0 - crossing.0).powi(2) + (centre.1 - crossing.1).powi(2)).sqrt();
        assert!(dist > 6.0, "probe {i} must stay clear of the dot's image");
        assert_eq!(sample(p), RED, "probe {i} inside the quad must be red");
    }

    // Extent pixels outside the quad — fully transparent. (Only the
    // corners the caller names: a quad side lying ON the bounding box puts
    // that side's bbox corners inside the quad.)
    for &(cx, cy) in transparent_extent_corners {
        let centre = (
            f64::from(ox) + f64::from(cx) + 0.5,
            f64::from(oy) + f64::from(cy) + 0.5,
        );
        assert!(
            !point_in_quad(centre, &quad) && edge_margin(centre, &quad) > 0.9,
            "extent corner ({cx},{cy}) must probe outside the quad with margin"
        );
        assert_eq!(
            layer.pixels.get_pixel(cx, cy).0,
            [0, 0, 0, 0],
            "extent pixels outside the quad must be fully transparent"
        );
    }
    crossing
}

#[test]
fn perspective_maps_the_rect_centre_onto_the_quads_diagonal_intersection() {
    // A strong-perspective trapezoid: top side 50 wide, bottom 20. The
    // pinch pulls the centre's image toward the narrow side, so the
    // diagonal crossing (~(26.4, 33.6)) sits 8.5 px from the corner
    // CENTROID (27.5, 25) — where a tensor-product bilinear corner warp
    // (the classic wrong implementation, whose centre image is the
    // centroid) would put the dot. The dot's image is only ~4 px across,
    // so the two assertions below cannot both hold for anything but a true
    // homography: the crossing pixel is black AND the centroid pixel is
    // red.
    let quad = [5.0, 5.0, 55.0, 5.0, 35.0, 45.0, 15.0, 45.0];
    // The top side lies on the bbox, so only the bottom bbox corners are
    // outside the quad.
    let crossing =
        assert_dot_lands_on_diagonal_crossing(&dot_fixture(), quad, (5, 5), &[(0, 39), (49, 39)]);

    let out = warped(&dot_fixture(), 1, quad, FILTER_NEAREST);
    let layer = &out.layers[1];
    let centroid = (27.5, 25.0);
    let dist = ((centroid.0 - crossing.0).powi(2) + (centroid.1 - crossing.1).powi(2)).sqrt();
    assert!(dist > 6.0, "the quad must separate crossing and centroid");
    let (cx, cy) = (
        (centroid.0.floor() as i32 - layer.offset.0) as u32,
        (centroid.1.floor() as i32 - layer.offset.1) as u32,
    );
    assert_eq!(
        layer.pixels.get_pixel(cx, cy).0,
        RED,
        "the centroid pixel must NOT carry the dot — a bilinear corner warp \
         would put it exactly there"
    );
}

#[test]
fn mirrored_quads_render_through_the_oriented_inverse() {
    // The trapezoid above reflected about x = 30, KEEPING the source
    // corner labels: the source's left edge now lands on the destination's
    // right — a mirror, so the homography's determinant is negative and
    // the adjugate comes out globally sign-flipped. Without the det-sign
    // orientation in perspective_layer the denominator would be negative
    // across the whole quad and the horizon guard would blank every pixel;
    // this asserts the mirrored warp actually renders, dot on the mirrored
    // crossing, bbox corners outside the quad still transparent.
    let quad = [55.0, 5.0, 5.0, 5.0, 25.0, 45.0, 45.0, 45.0];
    assert_dot_lands_on_diagonal_crossing(&dot_fixture(), quad, (5, 5), &[(0, 39), (49, 39)]);
}

#[test]
fn layer_offset_only_relabels_the_source_frame() {
    // Mapping "rect at offset O onto quad Q" and "the same pixels at
    // offset (0, 0) onto Q" are the SAME source-to-destination
    // correspondence — the rect's corners land on Q's corners either way —
    // so the results must be byte-identical, which pins every offset term
    // in the projective source map at full strength: a swapped or dropped
    // term shifts the offset copy's sampling by up to several pixels
    // across the extent. The two solves take different arithmetic paths to
    // the same map, so their ~1e-12 residues could floor a sample
    // differently exactly ON a pixel boundary; the quad's corners are
    // deliberately fractional so no sample lands there, and IEEE
    // arithmetic is deterministic, so green once is green forever. The
    // quad is fully generic — both perspective coefficients alive, slanted
    // horizon — because a symmetric trapezoid zeroes one inverse
    // coefficient and would mask a mutation in that offset slot.
    let pattern = RgbaImage::from_fn(41, 41, |x, y| {
        Rgba([
            (x * 5) as u8,
            (y * 5) as u8,
            ((x * 7 + y * 11) % 256) as u8,
            255,
        ])
    });
    let at_origin = RzDocument::from_pixels(solid(60, 60, WHITE))
        .adding_image_layer(0, pattern, "P")
        .expect("add layer");
    let offset = at_origin.with_layer_offset(1, 9, 2).expect("set offset");
    let quad = [5.3, 5.7, 45.3, 8.7, 38.3, 47.7, 2.3, 40.7];
    for filter in SAMPLERS {
        let a = warped(&at_origin, 1, quad, filter);
        let b = warped(&offset, 1, quad, filter);
        assert_eq!(
            a.layers[1].offset, b.layers[1].offset,
            "same quad, same destination (filter {filter})"
        );
        assert_eq!(
            a.layers[1].pixels.as_raw(),
            b.layers[1].pixels.as_raw(),
            "the layer offset must only relabel the source frame (filter {filter})"
        );
    }
}

#[test]
fn masks_alpha_meta_and_properties_ride_along() {
    // A layer whose ALPHA equals its MASK, pixel for pixel: both channels
    // run the same map, extent and kernel through the same quantization, so
    // they must come out byte-equal — a self-referential oracle that fails
    // on any drift between the RGBA and mask resamplers.
    let (off_x, off_y) = (4i32, 3i32);
    let coverage = |x: u32, y: u32| ((x * 37 + y * 29) % 256) as u8;
    let layer = RgbaImage::from_fn(8, 6, |x, y| Rgba([200, 80, 40, coverage(x, y)]));
    let sel = selection(16, 12, |x, y| {
        let (lx, ly) = (x as i32 - off_x, y as i32 - off_y);
        if (0..8).contains(&lx) && (0..6).contains(&ly) {
            coverage(lx as u32, ly as u32)
        } else {
            0
        }
    });
    let mut doc = RzDocument::from_pixels(solid(16, 12, RED))
        .adding_image_layer(0, layer, "Top")
        .expect("add layer")
        .with_layer_offset(1, off_x, off_y)
        .expect("set offset")
        .add_mask(1, MaskKind::FromSelection(&sel))
        .expect("mask");
    doc.layers[1].meta = Some(META.to_string());

    // A genuine trapezoid over the layer's rect.
    let quad = [3.0, 2.0, 13.0, 4.0, 11.0, 10.0, 4.0, 9.0];
    for filter in SAMPLERS {
        let out = warped(&doc, 1, quad, filter);
        assert_mask_invariant(&out, "perspective");
        let alpha: Vec<u8> = out.layers[1].pixels.pixels().map(|p| p.0[3]).collect();
        assert_eq!(
            alpha,
            mask_bytes(&out, 1),
            "alpha and mask must stay byte-equal (filter {filter})"
        );
        assert_eq!(out.layers[1].meta.as_deref(), Some(META), "meta survives");
        assert_eq!(out.layers[1].name, "Top", "name survives");
        assert_eq!((out.width, out.height), (16, 12), "canvas untouched");
        assert_eq!(
            out.layers[0].pixels.as_raw(),
            doc.layers[0].pixels.as_raw(),
            "other layers untouched"
        );
    }
}

#[test]
fn degenerate_and_invalid_quads_are_refused() {
    let doc = fixture((8, 6), (2, 1));
    let good = [1.0, 0.0, 7.0, 1.0, 6.0, 5.0, 2.0, 4.0];
    assert!(
        warp(&doc, 1, good, FILTER_BILINEAR).is_some(),
        "the baseline quad must be accepted or this sweep proves nothing"
    );

    // One non-finite coordinate in each slot.
    for i in 0..8 {
        for bad in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY] {
            let mut q = good;
            q[i] = bad;
            assert!(
                warp(&doc, 1, q, FILTER_BILINEAR).is_none(),
                "slot {i}: {bad}"
            );
        }
    }

    let cases: [(&str, [f64; 8]); 5] = [
        // BR pulled inside the triangle of the other three corners.
        ("concave", [0.0, 0.0, 40.0, 0.0, 15.0, 15.0, 0.0, 40.0]),
        // Bottom corners swapped: the sides cross.
        ("bowtie", [0.0, 0.0, 40.0, 0.0, 0.0, 40.0, 40.0, 40.0]),
        // All four corners on one line.
        ("collinear", [0.0, 0.0, 10.0, 10.0, 20.0, 20.0, 30.0, 30.0]),
        // The quad collapses to a point.
        ("point", [7.0, 7.0, 7.0, 7.0, 7.0, 7.0, 7.0, 7.0]),
        // Non-parallelogram quad past the pixel budget (1e8).
        (
            "budget",
            [0.0, 0.0, 20000.0, 0.0, 20000.0, 10000.0, 0.0, 10001.0],
        ),
    ];
    for (name, q) in cases {
        assert!(warp(&doc, 1, q, FILTER_BILINEAR).is_none(), "{name}");
    }

    // Out-of-range layer, unknown filter, NULL doc, NULL quad.
    assert!(warp(&doc, 9, good, FILTER_BILINEAR).is_none());
    assert!(warp(&doc, 1, good, 99).is_none());
    assert!(unsafe { rz_doc_perspective_layer(ptr::null(), 1, good.as_ptr(), 1) }.is_null());
    let handle = Box::into_raw(Box::new(doc.clone()));
    assert!(unsafe { rz_doc_perspective_layer(handle, 1, ptr::null(), 1) }.is_null());
    unsafe { rz_doc_free(handle) };
}
