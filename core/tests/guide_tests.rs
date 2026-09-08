//! Guides and the ruler origin, exercised through the public C FFI (the
//! header's "Guides, rulers and snapping" section): the five mutators and
//! every refusal each of them owes, the identity model, the 1024-guide cap,
//! and the whole canvas-geometry table — with the DROP for crop and canvas
//! resize and the CLAMP for the rotations, the flips and Image Size asserted
//! per branch rather than lumped together.
//!
//! The oracles are written out here by hand, independently of the
//! implementation: the five permutation formulas come from the geometry a
//! quarter turn performs on a line, not from the core's own table. The format
//! itself — version 8, the older versions, the crafted files — is
//! `guide_format`.

use std::ffi::c_int;
use std::ptr;

use rasterize_core::doc::RzDocument;
use rasterize_core::ffi_doc::*;
use rasterize_core::ffi_guide::*;
use tempfile::TempDir;

mod common;
use common::*;

/// `RzGuideOrientation`, mirrored from the header the way `common` mirrors
/// `RzBlendMode`, so the tests do not agree with the core by construction.
const HORIZONTAL: c_int = 0;
const VERTICAL: c_int = 1;

// ---------------------------------------------------------------- helpers --

fn canvas(dir: &TempDir, name: &str, w: u32, h: u32) -> *mut RzDocument {
    doc_from(dir, name, &solid(w, h, RED))
}

/// The whole guide list as (orientation, position) pairs, in the core's own
/// order.
fn guides(doc: *const RzDocument) -> Vec<(c_int, f64)> {
    (0..unsafe { rz_doc_guide_count(doc) })
        .map(|i| unsafe {
            (
                rz_doc_guide_orientation(doc, i),
                rz_doc_guide_position(doc, i),
            )
        })
        .collect()
}

fn ids(doc: *const RzDocument) -> Vec<u64> {
    (0..unsafe { rz_doc_guide_count(doc) })
        .map(|i| unsafe { rz_doc_guide_id(doc, i) })
        .collect()
}

fn origin(doc: *const RzDocument) -> (f64, f64) {
    let mut out = [0.0f64; 2];
    assert!(
        unsafe { rz_doc_ruler_origin(doc, out.as_mut_ptr()) },
        "a live document always has an origin"
    );
    (out[0], out[1])
}

/// Adds a guide, asserting it was accepted and freeing the old handle.
fn add(doc: *mut RzDocument, orientation: c_int, position: f64) -> *mut RzDocument {
    apply(doc, |d| unsafe {
        rz_doc_add_guide(d, orientation, position)
    })
}

fn assert_close(actual: f64, expected: f64, what: &str) {
    assert!(
        (actual - expected).abs() < 1e-6,
        "{what}: {actual} vs {expected}"
    );
}

// ------------------------------------------------------------ the mutators --

#[test]
fn add_move_remove_and_clear_round_trip() {
    let dir = TempDir::new().unwrap();
    let mut doc = canvas(&dir, "a.png", 100, 60);
    assert_eq!(unsafe { rz_doc_guide_count(doc) }, 0, "a new document");
    assert_eq!(guides(doc), vec![]);

    doc = add(doc, VERTICAL, 25.0);
    doc = add(doc, HORIZONTAL, 40.0);
    doc = add(doc, VERTICAL, 10.5);
    // Sorted by orientation (horizontal first), then position — the model
    // invariant, and what gives a host a stable draw order across undo.
    assert_eq!(
        guides(doc),
        vec![(HORIZONTAL, 40.0), (VERTICAL, 10.5), (VERTICAL, 25.0)]
    );

    // Moving re-sorts, and the moved guide keeps its identity.
    let moved_id = ids(doc)[2];
    doc = apply(doc, |d| unsafe { rz_doc_move_guide(d, 2, 5.0) });
    assert_eq!(
        guides(doc),
        vec![(HORIZONTAL, 40.0), (VERTICAL, 5.0), (VERTICAL, 10.5)]
    );
    assert_eq!(ids(doc)[1], moved_id, "a move keeps the guide's identity");

    doc = apply(doc, |d| unsafe { rz_doc_remove_guide(d, 0) });
    assert_eq!(guides(doc), vec![(VERTICAL, 5.0), (VERTICAL, 10.5)]);

    doc = apply(doc, |d| unsafe { rz_doc_clear_guides(d) });
    assert_eq!(unsafe { rz_doc_guide_count(doc) }, 0);
    unsafe { rz_doc_free(doc) };
}

#[test]
fn a_guide_may_sit_on_either_canvas_edge() {
    // The grid-line convention: the range is [0, extent] INCLUSIVE, so both
    // canvas edges are lines a user can align to.
    let dir = TempDir::new().unwrap();
    let mut doc = canvas(&dir, "edges.png", 100, 60);
    doc = add(doc, VERTICAL, 0.0);
    doc = add(doc, VERTICAL, 100.0);
    doc = add(doc, HORIZONTAL, 0.0);
    doc = add(doc, HORIZONTAL, 60.0);
    assert_eq!(
        guides(doc),
        vec![
            (HORIZONTAL, 0.0),
            (HORIZONTAL, 60.0),
            (VERTICAL, 0.0),
            (VERTICAL, 100.0)
        ]
    );
    // ...and one step past either edge is refused, on the axis that owns it:
    // a vertical guide is measured against the WIDTH.
    assert!(unsafe { rz_doc_add_guide(doc, VERTICAL, 100.001) }.is_null());
    assert!(unsafe { rz_doc_add_guide(doc, HORIZONTAL, 60.001) }.is_null());
    assert!(
        unsafe { rz_doc_add_guide(doc, HORIZONTAL, 100.0) }.is_null(),
        "60 is the height, so a horizontal guide stops there even though the \
         canvas is 100 wide"
    );
    unsafe { rz_doc_free(doc) };
}

#[test]
fn positions_quantize_to_four_decimals() {
    let dir = TempDir::new().unwrap();
    let mut doc = canvas(&dir, "q.png", 100, 60);
    doc = add(doc, VERTICAL, 12.345_678);
    assert_close(guides(doc)[0].1, 12.3457, "quantized on the way in");
    // And the reported value echoed straight back is refused as unchanged,
    // which is the whole reason for quantizing.
    assert!(
        unsafe { rz_doc_add_guide(doc, VERTICAL, 12.3457) }.is_null(),
        "the same guide again is not an edit"
    );
    assert!(
        unsafe { rz_doc_add_guide(doc, VERTICAL, 12.345_678) }.is_null(),
        "nor is the unquantized value it came from"
    );
    unsafe { rz_doc_free(doc) };
}

#[test]
fn every_refusal_the_mutators_owe() {
    let dir = TempDir::new().unwrap();
    let mut doc = canvas(&dir, "r.png", 100, 60);

    // clear_guides on an empty list: nothing to clear is not an edit.
    assert!(unsafe { rz_doc_clear_guides(doc) }.is_null());
    // remove_guide with no guides at all, and with an out-of-range index.
    assert!(unsafe { rz_doc_remove_guide(doc, 0) }.is_null());
    // move_guide with an out-of-range index.
    assert!(unsafe { rz_doc_move_guide(doc, 0, 10.0) }.is_null());

    // add_guide: an unknown orientation, a non-finite position, and both ends
    // of the range.
    assert!(unsafe { rz_doc_add_guide(doc, 2, 10.0) }.is_null());
    assert!(unsafe { rz_doc_add_guide(doc, -1, 10.0) }.is_null());
    assert!(unsafe { rz_doc_add_guide(doc, VERTICAL, f64::NAN) }.is_null());
    assert!(unsafe { rz_doc_add_guide(doc, VERTICAL, f64::INFINITY) }.is_null());
    assert!(unsafe { rz_doc_add_guide(doc, VERTICAL, -0.001) }.is_null());
    assert!(unsafe { rz_doc_add_guide(doc, VERTICAL, 1e300) }.is_null());

    doc = add(doc, VERTICAL, 25.0);
    doc = add(doc, VERTICAL, 50.0);
    // A duplicate of the same orientation, but NOT of the other one: a
    // horizontal guide at x = 25 is a different line entirely.
    assert!(unsafe { rz_doc_add_guide(doc, VERTICAL, 25.0) }.is_null());
    doc = add(doc, HORIZONTAL, 25.0);

    // move_guide: to where it already is, onto another guide, out of range,
    // and non-finite.
    assert!(unsafe { rz_doc_move_guide(doc, 1, 25.0) }.is_null());
    assert!(unsafe { rz_doc_move_guide(doc, 1, 50.0) }.is_null());
    assert!(unsafe { rz_doc_move_guide(doc, 1, 200.0) }.is_null());
    assert!(unsafe { rz_doc_move_guide(doc, 1, f64::NAN) }.is_null());
    assert!(unsafe { rz_doc_move_guide(doc, 9, 30.0) }.is_null());

    // set_ruler_origin: unchanged, non-finite, outside the canvas on either
    // axis.
    assert!(unsafe { rz_doc_set_ruler_origin(doc, 0.0, 0.0) }.is_null());
    assert!(unsafe { rz_doc_set_ruler_origin(doc, f64::NAN, 0.0) }.is_null());
    assert!(unsafe { rz_doc_set_ruler_origin(doc, 0.0, f64::INFINITY) }.is_null());
    assert!(unsafe { rz_doc_set_ruler_origin(doc, 100.001, 0.0) }.is_null());
    assert!(unsafe { rz_doc_set_ruler_origin(doc, 0.0, -1.0) }.is_null());

    // Nothing above changed the document.
    assert_eq!(
        guides(doc),
        vec![(HORIZONTAL, 25.0), (VERTICAL, 25.0), (VERTICAL, 50.0)]
    );
    assert_eq!(origin(doc), (0.0, 0.0));
    unsafe { rz_doc_free(doc) };
}

#[test]
fn the_ruler_origin_moves_and_quantizes() {
    let dir = TempDir::new().unwrap();
    let mut doc = canvas(&dir, "o.png", 100, 60);
    assert_eq!(origin(doc), (0.0, 0.0), "the canvas's top-left by default");
    doc = apply(doc, |d| unsafe {
        rz_doc_set_ruler_origin(d, 12.345_678, 60.0)
    });
    let (x, y) = origin(doc);
    assert_close(x, 12.3457, "quantized");
    assert_close(y, 60.0, "the far edge is legal");
    assert!(
        unsafe { rz_doc_set_ruler_origin(doc, 12.3457, 60.0) }.is_null(),
        "the reported origin echoed back is not an edit"
    );
    unsafe { rz_doc_free(doc) };
}

#[test]
fn ids_are_stable_through_unrelated_ops_and_fresh_after_a_reload() {
    let dir = TempDir::new().unwrap();
    let mut doc = canvas(&dir, "id.png", 40, 30);
    doc = add(doc, VERTICAL, 10.0);
    doc = add(doc, HORIZONTAL, 20.0);
    let before = ids(doc);
    assert!(before.iter().all(|&id| id != 0), "0 means 'no guide'");
    assert_ne!(before[0], before[1], "identities are distinct");

    // An unrelated document op carries the identities through.
    let flat = apply(unsafe { rz_doc_clone(doc) }, |d| unsafe {
        rz_doc_flattening(d)
    });
    assert_eq!(
        ids(flat),
        before,
        "flattening keeps the guides and their ids"
    );
    unsafe { rz_doc_free(flat) };

    // A save/reopen mints fresh ones: identity holds while a document is
    // open, never across sessions.
    let path = dir.path().join("id.rzdc");
    let c = cpath(&path);
    let mut err: *mut std::ffi::c_char = ptr::null_mut();
    assert!(
        unsafe { rz_doc_save_native(doc, c.as_ptr(), &mut err) },
        "{}",
        take_err_string(err)
    );
    let mut err: *mut std::ffi::c_char = ptr::null_mut();
    let back = unsafe { rz_doc_open(c.as_ptr(), &mut err) };
    assert!(!back.is_null(), "{}", take_err_string(err));
    assert_eq!(guides(back), guides(doc), "the same lines come back");
    assert!(
        ids(back).iter().all(|id| !before.contains(id)),
        "with fresh ids"
    );
    unsafe {
        rz_doc_free(back);
        rz_doc_free(doc);
    }
}

// ------------------------------------------------------------------- the cap --

#[test]
fn the_guide_cap_is_1024_and_the_1025th_is_refused() {
    assert_eq!(rz_max_guides(), 1024, "the exported cap");
    let dir = TempDir::new().unwrap();
    // A canvas wide enough for 1024 distinct integer positions.
    let mut doc = canvas(&dir, "cap.png", 2048, 8);
    for i in 0..rz_max_guides() {
        doc = add(doc, VERTICAL, i as f64);
    }
    assert_eq!(unsafe { rz_doc_guide_count(doc) }, rz_max_guides());
    assert!(
        unsafe { rz_doc_add_guide(doc, VERTICAL, 2000.0) }.is_null(),
        "the list is full"
    );
    assert!(
        unsafe { rz_doc_add_guide(doc, HORIZONTAL, 4.0) }.is_null(),
        "the cap is the whole list, not one orientation's share of it"
    );
    // A full list still MOVES and still empties.
    doc = apply(doc, |d| unsafe { rz_doc_move_guide(d, 0, 2000.0) });
    doc = apply(doc, |d| unsafe { rz_doc_remove_guide(d, 0) });
    assert_eq!(unsafe { rz_doc_guide_count(doc) }, rz_max_guides() - 1);
    doc = add(doc, HORIZONTAL, 4.0);
    assert_eq!(unsafe { rz_doc_guide_count(doc) }, rz_max_guides());
    unsafe { rz_doc_free(doc) };
}

// -------------------------------------------------------- the geometry table --

/// The fixture every geometry row runs on: a 100 x 60 canvas with one guide
/// on each axis and a ruler origin off the corner, so a map that dropped an
/// axis or swapped two would show.
fn geometry_fixture(dir: &TempDir, name: &str) -> *mut RzDocument {
    let mut doc = canvas(dir, name, 100, 60);
    doc = add(doc, VERTICAL, 25.0);
    doc = add(doc, HORIZONTAL, 10.0);
    apply(doc, |d| unsafe { rz_doc_set_ruler_origin(d, 30.0, 20.0) })
}

#[test]
fn the_quarter_turns_and_the_flips_permute_guides_and_the_origin() {
    let dir = TempDir::new().unwrap();
    let doc = geometry_fixture(&dir, "g.png");
    let (w, h) = (100.0, 60.0);

    // rotate90 clockwise: (x, y) -> (H - y, x). A vertical line x = a becomes
    // a horizontal line y = a; a horizontal line y = b becomes a vertical
    // line x = H - b.
    let out = apply(unsafe { rz_doc_clone(doc) }, |d| unsafe {
        rz_doc_rotate90(d)
    });
    assert_eq!(
        guides(out),
        vec![(HORIZONTAL, 25.0), (VERTICAL, h - 10.0)],
        "rotate90"
    );
    assert_eq!(origin(out), (h - 20.0, 30.0), "rotate90 origin");
    unsafe { rz_doc_free(out) };

    // rotate180: (x, y) -> (W - x, H - y). Orientations hold.
    let out = apply(unsafe { rz_doc_clone(doc) }, |d| unsafe {
        rz_doc_rotate180(d)
    });
    assert_eq!(
        guides(out),
        vec![(HORIZONTAL, h - 10.0), (VERTICAL, w - 25.0)],
        "rotate180"
    );
    assert_eq!(origin(out), (w - 30.0, h - 20.0), "rotate180 origin");
    unsafe { rz_doc_free(out) };

    // rotate270 counter-clockwise: (x, y) -> (y, W - x).
    let out = apply(unsafe { rz_doc_clone(doc) }, |d| unsafe {
        rz_doc_rotate270(d)
    });
    assert_eq!(
        guides(out),
        vec![(HORIZONTAL, w - 25.0), (VERTICAL, 10.0)],
        "rotate270"
    );
    assert_eq!(origin(out), (20.0, w - 30.0), "rotate270 origin");
    unsafe { rz_doc_free(out) };

    // flip_horizontal: only the vertical guide moves.
    let out = apply(unsafe { rz_doc_clone(doc) }, |d| unsafe {
        rz_doc_flip_horizontal(d)
    });
    assert_eq!(
        guides(out),
        vec![(HORIZONTAL, 10.0), (VERTICAL, w - 25.0)],
        "flip_horizontal"
    );
    assert_eq!(origin(out), (w - 30.0, 20.0), "flip_horizontal origin");
    unsafe { rz_doc_free(out) };

    // flip_vertical: only the horizontal one.
    let out = apply(unsafe { rz_doc_clone(doc) }, |d| unsafe {
        rz_doc_flip_vertical(d)
    });
    assert_eq!(
        guides(out),
        vec![(HORIZONTAL, h - 10.0), (VERTICAL, 25.0)],
        "flip_vertical"
    );
    assert_eq!(origin(out), (30.0, h - 20.0), "flip_vertical origin");
    unsafe { rz_doc_free(out) };

    unsafe { rz_doc_free(doc) };
}

#[test]
fn four_quarter_turns_are_the_identity() {
    let dir = TempDir::new().unwrap();
    let doc = geometry_fixture(&dir, "spin.png");
    let before = guides(doc);
    let before_origin = origin(doc);
    let mut turned = unsafe { rz_doc_clone(doc) };
    for _ in 0..4 {
        turned = apply(turned, |d| unsafe { rz_doc_rotate90(d) });
    }
    assert_eq!(guides(turned), before, "four quarter turns come home");
    assert_eq!(origin(turned), before_origin);
    unsafe {
        rz_doc_free(turned);
        rz_doc_free(doc);
    }
}

#[test]
fn crop_shifts_and_drops_rather_than_piling_guides_on_the_edge() {
    let dir = TempDir::new().unwrap();
    let mut doc = canvas(&dir, "crop.png", 100, 60);
    for x in [5.0, 25.0, 50.0, 95.0] {
        doc = add(doc, VERTICAL, x);
    }
    doc = add(doc, HORIZONTAL, 55.0);
    doc = apply(doc, |d| unsafe { rz_doc_set_ruler_origin(d, 5.0, 55.0) });

    // Window x in [20, 60), y in [0, 30): the guides at 5 and 95 leave, the
    // horizontal one at 55 leaves, and the two survivors shift by -20.
    let out = apply(unsafe { rz_doc_clone(doc) }, |d| unsafe {
        rz_doc_crop(d, 20, 0, 40, 30)
    });
    assert_eq!(guides(out), vec![(VERTICAL, 5.0), (VERTICAL, 30.0)]);
    assert_eq!(
        unsafe { rz_doc_guide_count(out) },
        2,
        "the count FELL — an out-of-window guide is dropped, not clamped"
    );
    assert!(
        !guides(out).iter().any(|&(_, p)| p == 40.0),
        "and nothing piled up on the new right edge"
    );
    assert_eq!(
        origin(out),
        (0.0, 30.0),
        "the origin is CLAMPED where a guide is dropped: a document is never \
         without one"
    );
    unsafe { rz_doc_free(out) };

    // The window boundary is INCLUSIVE at both ends: a guide landing exactly
    // on 0 or on the new width survives.
    let out = apply(unsafe { rz_doc_clone(doc) }, |d| unsafe {
        rz_doc_crop(d, 5, 0, 90, 60)
    });
    assert_eq!(
        guides(out),
        vec![
            (HORIZONTAL, 55.0),
            (VERTICAL, 0.0),
            (VERTICAL, 20.0),
            (VERTICAL, 45.0),
            (VERTICAL, 90.0)
        ],
        "5 -> 0 and 95 -> 90 both land on an edge and both are kept"
    );
    unsafe {
        rz_doc_free(out);
        rz_doc_free(doc);
    }
}

#[test]
fn canvas_resize_shifts_and_drops_and_a_grow_then_shrink_comes_home() {
    let dir = TempDir::new().unwrap();
    let mut doc = canvas(&dir, "cr.png", 100, 60);
    doc = add(doc, VERTICAL, 10.0);
    doc = add(doc, VERTICAL, 90.0);
    doc = add(doc, HORIZONTAL, 30.0);

    // Shrinking the canvas around the middle: the origin goes negative, so
    // the guide at x = 10 leaves and the one at 90 stays (90 - 20 = 70 > 60).
    let out = apply(unsafe { rz_doc_clone(doc) }, |d| unsafe {
        rz_doc_canvas_resize(d, 60, 60, -20, 0)
    });
    assert_eq!(
        guides(out),
        vec![(HORIZONTAL, 30.0)],
        "both verticals left the window: 10 - 20 is negative and 90 - 20 is \
         past the new 60-wide canvas"
    );
    unsafe { rz_doc_free(out) };

    // Growing then shrinking by the same offset returns a surviving guide to
    // exactly where it started.
    let grown = apply(unsafe { rz_doc_clone(doc) }, |d| unsafe {
        rz_doc_canvas_resize(d, 200, 160, 50, 50)
    });
    assert_eq!(
        guides(grown),
        vec![(HORIZONTAL, 80.0), (VERTICAL, 60.0), (VERTICAL, 140.0)]
    );
    let back = apply(grown, |d| unsafe {
        rz_doc_canvas_resize(d, 100, 60, -50, -50)
    });
    assert_eq!(guides(back), guides(doc), "grow then shrink comes home");
    unsafe {
        rz_doc_free(back);
        rz_doc_free(doc);
    }
}

#[test]
fn resize_scales_without_rounding_and_survives_a_round_trip() {
    let dir = TempDir::new().unwrap();
    let mut doc = canvas(&dir, "rs.png", 1000, 1000);
    doc = add(doc, VERTICAL, 137.0);
    doc = add(doc, HORIZONTAL, 1000.0);
    doc = apply(doc, |d| unsafe { rz_doc_set_ruler_origin(d, 137.0, 500.0) });

    let down = apply(unsafe { rz_doc_clone(doc) }, |d| unsafe {
        rz_doc_resize(d, 333, 333, FILTER_BILINEAR)
    });
    assert_close(guides(down)[1].1, 137.0 * 0.333, "scaled, not rounded");
    assert_close(
        guides(down)[0].1,
        333.0,
        "a guide on the far edge lands on the new far edge — the CLAMP is \
         float safety, not a drop",
    );
    assert_eq!(
        unsafe { rz_doc_guide_count(down) },
        2,
        "nothing can leave the canvas under a scale"
    );

    let up = apply(down, |d| unsafe {
        rz_doc_resize(d, 1000, 1000, FILTER_BILINEAR)
    });
    // 1000 -> 333 -> 1000 must come back within q4's granularity. Rounding
    // the intermediate to a whole pixel would land 1.5 px away.
    assert_close(
        guides(up)[1].1,
        137.0,
        "the down-and-back trip is exact to the quantizer",
    );
    assert_close(guides(up)[0].1, 1000.0, "and the edge guide is still on it");
    assert_close(origin(up).0, 137.0, "so is the ruler origin");
    unsafe {
        rz_doc_free(up);
        rz_doc_free(doc);
    }
}

#[test]
fn flattening_carries_the_guides_and_the_origin() {
    // The spread trap: `flattening` builds on `..from_pixels`, so anything it
    // does not name explicitly is silently replaced by a default. This is the
    // pin.
    let dir = TempDir::new().unwrap();
    let mut doc = canvas(&dir, "flat.png", 80, 40);
    doc = add_layer(&dir, "top.png", doc, 0, &solid(20, 20, BLUE), "Top");
    doc = add(doc, VERTICAL, 33.0);
    doc = add(doc, HORIZONTAL, 7.5);
    doc = apply(doc, |d| unsafe { rz_doc_set_ruler_origin(d, 8.0, 9.0) });

    let flat = apply(unsafe { rz_doc_clone(doc) }, |d| unsafe {
        rz_doc_flattening(d)
    });
    assert_eq!(unsafe { rz_doc_layer_count(flat) }, 1, "one layer left");
    assert_eq!(guides(flat), guides(doc), "and every guide survived");
    assert_eq!(origin(flat), (8.0, 9.0), "and so did the ruler origin");
    unsafe {
        rz_doc_free(flat);
        rz_doc_free(doc);
    }
}

#[test]
fn a_layer_op_leaves_the_guides_alone() {
    // Guides are CANVAS state: only the canvas ops move them.
    let dir = TempDir::new().unwrap();
    let mut doc = canvas(&dir, "layer.png", 60, 60);
    doc = add_layer(&dir, "l.png", doc, 0, &solid(10, 10, BLUE), "L");
    doc = add(doc, VERTICAL, 30.0);
    let before = guides(doc);
    let moved = apply(unsafe { rz_doc_clone(doc) }, |d| unsafe {
        rz_doc_with_layer_offset(d, 1, 20, 20)
    });
    assert_eq!(guides(moved), before, "moving a layer moves no guide");
    unsafe {
        rz_doc_free(moved);
        rz_doc_free(doc);
    }
}
