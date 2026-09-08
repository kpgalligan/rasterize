//! The STRUCTURAL ops and the LOCKS: arrange, the set duplicate / delete /
//! merge, Merge Visible, Stamp Visible, Layer Via Copy and Via Cut, move,
//! transform, align, distribute and the link groups — plus what each lock
//! forbids and the two sweeps that prove the guards are wired everywhere.
//!
//! Two of those sweeps are the point of this file and are not formalities:
//!
//! * the LOCK sweep drives every wrapped export against a layer carrying each
//!   lock, so an op that forgot `under_locks` fails a test instead of shipping
//!   (the two ops that cannot BE wrapped — the merges, which drain the entry
//!   the lock belongs to — are driven by `lock_tests`, with the edit kinds
//!   that are not a plain pixel write);
//! * the GROUP sweep drives every pixel export against a group index, so an op
//!   that reads `layers.get` instead of `raster_layer` does too.
//!
//! And every op that changes the shape of the stack is checked for the ONE
//! invariant afterwards (`assert_well_formed`), including the hostile cases,
//! because `doc_group::validate_structure` runs at RUNTIME — no assertion in
//! this crate runs under `cargo test --release`, so a NULL from a
//! deliberately malformed argument is the only proof the gate is wired.
//!
//! Black-box through the FFI; the group model itself is `group_tests`, the
//! `.rz` round trip `group_format`.

use std::ffi::{c_char, c_int, CString};
use std::ptr;

use image::{Rgba, RgbaImage};
use rasterize_core::doc::RzDocument;
use rasterize_core::ffi::rz_image_free;
use rasterize_core::ffi_channel::{
    rz_doc_painting_layer_plane, rz_doc_with_layer_plane, rz_doc_with_layer_space_plane,
};
use rasterize_core::ffi_doc::*;
use rasterize_core::ffi_group::*;
use rasterize_core::ffi_heal::*;
use tempfile::TempDir;

mod common;
use common::*;

/// RZ_PLANE_RED and RZ_GRADIENT_LINEAR, mirrored from the header like the
/// blend and lock tables in `tests/common`.
const PLANE_RED: c_int = 0;
const GRADIENT_LINEAR: c_int = 0;

// ---------------------------------------------------------------- helpers --

fn group(doc: *mut RzDocument, idx: &[usize], name: &str) -> (*mut RzDocument, usize) {
    let cname = CString::new(name).unwrap();
    let mut out_group = usize::MAX;
    let out = unsafe {
        rz_doc_group_layers(
            doc,
            idx.as_ptr(),
            idx.len(),
            cname.as_ptr(),
            &mut out_group,
            ptr::null_mut(),
            ptr::null_mut(),
            ptr::null_mut(),
            ptr::null_mut(),
            0,
        )
    };
    assert!(!out.is_null(), "group_layers({idx:?}) refused");
    unsafe { rz_doc_free(doc) };
    (out, out_group)
}

fn names(doc: *const RzDocument) -> Vec<String> {
    (0..unsafe { rz_doc_layer_count(doc) })
        .map(|i| layer_name(doc, i))
        .collect()
}

fn depths(doc: *const RzDocument) -> Vec<u32> {
    (0..unsafe { rz_doc_layer_count(doc) })
        .map(|i| unsafe { rz_doc_layer_depth(doc, i) })
        .collect()
}

fn kinds(doc: *const RzDocument) -> Vec<bool> {
    (0..unsafe { rz_doc_layer_count(doc) })
        .map(|i| unsafe { rz_doc_layer_is_group(doc, i) })
        .collect()
}

fn links(doc: *const RzDocument) -> Vec<u32> {
    (0..unsafe { rz_doc_layer_count(doc) })
        .map(|i| unsafe { rz_doc_layer_link(doc, i) })
        .collect()
}

fn bounds(doc: *const RzDocument, idx: usize) -> Option<(i32, i32, i32, i32)> {
    let mut out = [0i32; 4];
    unsafe { rz_doc_layer_bounds(doc, idx, out.as_mut_ptr()) }
        .then_some((out[0], out[1], out[2], out[3]))
}

/// A document -> document FFI op, for the sweeps below.
type DocOp = Box<dyn Fn(*const RzDocument) -> *mut RzDocument>;

/// The ONE invariant, re-derived independently of the core — and deliberately
/// in a DIFFERENT shape, so these tests do not certify the implementation
/// against itself. The core scans each level and checks that every entry at
/// that depth closes the run since the last one; this walks the other way,
/// from each CHILD up to the group that must enclose it:
///
/// * every depth is within the cap and the LAST entry is at depth 0;
/// * for every entry at depth `d > 0`, the first entry ABOVE it that is
///   shallower must be at exactly `d - 1` and must be a GROUP — that entry is
///   its parent, since a group's own record closes its children's run.
///
/// A child with no enclosing group, a leaf closing a child run and a depth
/// that skips a level all fail one of those two, which is every way the
/// sequence can be malformed.
fn assert_well_formed(doc: *const RzDocument, what: &str) {
    let n = unsafe { rz_doc_layer_count(doc) };
    assert!(n > 0, "{what}: a document always holds at least one entry");
    let d = depths(doc);
    let g = kinds(doc);
    assert!(
        d.iter().all(|&v| v <= 10),
        "{what}: depth past the cap {d:?}"
    );
    assert_eq!(
        d[n - 1],
        0,
        "{what}: the last entry must be top level {d:?}"
    );
    for i in 0..n {
        if d[i] == 0 {
            continue;
        }
        let parent = (i + 1..n).find(|&j| d[j] < d[i]);
        let Some(parent) = parent else {
            panic!("{what}: entry {i} has no enclosing group — {d:?}");
        };
        assert_eq!(
            d[parent],
            d[i] - 1,
            "{what}: entry {i}'s enclosing entry is at the wrong depth — {d:?}"
        );
        assert!(
            g[parent],
            "{what}: entry {i}'s enclosing entry {parent} is a layer, not a group"
        );
    }
}

fn solid_doc(dir: &TempDir, w: u32, h: u32) -> *mut RzDocument {
    doc_from(dir, "bg.png", &solid(w, h, RED))
}

/// A box of `color` at `(x, y)` on a transparent canvas — content bounds that
/// are NOT the pixel rect, which is what align and distribute act on.
fn box_layer(w: u32, h: u32, x: u32, y: u32, bw: u32, bh: u32, color: [u8; 4]) -> RgbaImage {
    RgbaImage::from_fn(w, h, |px, py| {
        if px >= x && px < x + bw && py >= y && py < y + bh {
            Rgba(color)
        } else {
            Rgba([0, 0, 0, 0])
        }
    })
}

fn set_locks(doc: *mut RzDocument, idx: usize, locks: u32) -> *mut RzDocument {
    apply(doc, |d| unsafe { rz_doc_with_layer_locks(d, idx, locks) })
}

fn set_visible(doc: *mut RzDocument, idx: usize, visible: bool) -> *mut RzDocument {
    apply(doc, |d| unsafe {
        rz_doc_with_layer_visible(d, idx, visible)
    })
}

// -------------------------------------------------------------- arranging --

#[test]
fn arrange_moves_an_entry_within_its_own_level_only() {
    let dir = TempDir::new().unwrap();
    let mut doc = solid_doc(&dir, 6, 6);
    for (i, name) in ["A", "B", "C"].iter().enumerate() {
        doc = add_layer(
            &dir,
            &format!("{name}.png"),
            doc,
            i,
            &solid(6, 6, BLUE),
            name,
        );
    }
    // [Background, A, B, C] -> group {A, B} -> [Background, A, B, G, C]
    let (doc, group_idx) = group(doc, &[1, 2], "G");
    assert_eq!(names(doc), vec!["Background", "A", "B", "G", "C"]);
    assert_eq!(group_idx, 3);

    // A is at the BOTTOM of the group's level: Backward and Back refuse.
    unsafe {
        assert!(rz_doc_arrange_layer(doc, 1, ARRANGE_BACKWARD).is_null());
        assert!(rz_doc_arrange_layer(doc, 1, ARRANGE_BACK).is_null());
    }
    // Forward swaps A and B and never leaves the group.
    let swapped = apply(doc, |d| unsafe {
        rz_doc_arrange_layer(d, 1, ARRANGE_FORWARD)
    });
    assert_eq!(names(swapped), vec!["Background", "B", "A", "G", "C"]);
    assert_eq!(depths(swapped), vec![0, 1, 1, 0, 0]);
    assert_well_formed(swapped, "arrange forward inside a group");

    // The GROUP itself moves at the top level, carrying its subtree.
    let front = apply(swapped, |d| unsafe {
        rz_doc_arrange_layer(d, 3, ARRANGE_FRONT)
    });
    assert_eq!(names(front), vec!["Background", "C", "B", "A", "G"]);
    assert_eq!(depths(front), vec![0, 0, 1, 1, 0]);
    assert_well_formed(front, "a group brought to the front");
    unsafe {
        assert!(
            rz_doc_arrange_layer(front, 4, ARRANGE_FRONT).is_null(),
            "already at the front"
        );
        assert!(rz_doc_arrange_layer(front, 4, ARRANGE_FORWARD).is_null());
    }
    // ...and back down to the bottom of the top level.
    let back = apply(front, |d| unsafe {
        rz_doc_arrange_layer(d, 4, ARRANGE_BACK)
    });
    assert_eq!(names(back), vec!["B", "A", "G", "Background", "C"]);
    assert_eq!(depths(back), vec![1, 1, 0, 0, 0]);
    assert_well_formed(back, "a group sent to the back");
    unsafe { rz_doc_free(back) };
}

// ------------------------------------------------------- duplicate/remove --

#[test]
fn duplicate_and_remove_take_whole_subtrees_and_drop_subsumed_entries() {
    let dir = TempDir::new().unwrap();
    let mut doc = solid_doc(&dir, 6, 6);
    for (i, name) in ["A", "B"].iter().enumerate() {
        doc = add_layer(
            &dir,
            &format!("{name}.png"),
            doc,
            i,
            &solid(6, 6, BLUE),
            name,
        );
    }
    let (doc, _) = group(doc, &[1, 2], "G"); // [Background, A, B, G]

    // Naming the group AND one of its children means the group: the child is
    // subsumed, so exactly one copy of the subtree appears.
    let set = [1usize, 3];
    let duped = apply(doc, |d| unsafe {
        rz_doc_duplicate_layers(d, set.as_ptr(), set.len())
    });
    assert_eq!(
        names(duped),
        vec!["Background", "A", "B", "G", "A", "B", "G copy"]
    );
    assert_eq!(depths(duped), vec![0, 1, 1, 0, 1, 1, 0]);
    assert_well_formed(duped, "duplicate a group and its child");

    unsafe { rz_doc_free(duped) };

    // Two independent roots duplicate independently, and the lower one keeps
    // its index because every insertion happened above it.
    let mut doc = solid_doc(&dir, 6, 6);
    for (i, name) in ["A", "B"].iter().enumerate() {
        doc = add_layer(
            &dir,
            &format!("{name}2.png"),
            doc,
            i,
            &solid(6, 6, BLUE),
            name,
        );
    }
    let (doc, _) = group(doc, &[1, 2], "G"); // [Background, A, B, G]
    let both = [0usize, 3];
    let twice = apply(doc, |d| unsafe {
        rz_doc_duplicate_layers(d, both.as_ptr(), both.len())
    });
    assert_eq!(
        names(twice),
        vec![
            "Background",
            "Background copy",
            "A",
            "B",
            "G",
            "A",
            "B",
            "G copy"
        ]
    );
    assert_eq!(depths(twice), vec![0, 0, 1, 1, 0, 1, 1, 0]);
    assert_well_formed(twice, "duplicate two independent roots");

    // Removal takes the subtree and refuses only when it would empty the doc.
    let low_and_high = [0usize, 4];
    let removed = apply(twice, |d| unsafe {
        rz_doc_remove_layers(d, low_and_high.as_ptr(), 2)
    });
    assert_eq!(names(removed), vec!["Background copy", "A", "B", "G copy"]);
    assert_well_formed(removed, "remove two independent roots");
    let everything = [0usize, 1, 2, 3];
    unsafe {
        assert!(
            rz_doc_remove_layers(removed, everything.as_ptr(), 4).is_null(),
            "emptying the document is refused"
        );
    }
    unsafe { rz_doc_free(removed) };
}

// -------------------------------------------------------------- merge/set --

#[test]
fn merge_layers_folds_a_sibling_set_into_the_lowest_slot() {
    let dir = TempDir::new().unwrap();
    // Three opaque quarters of a 4x4 canvas, each in its own layer, so the
    // merged pixels are predictable without a golden image.
    let mut doc = doc_from(&dir, "bg.png", &solid(4, 4, [0, 0, 0, 0]));
    doc = add_layer(
        &dir,
        "a.png",
        doc,
        0,
        &box_layer(4, 4, 0, 0, 2, 2, [255, 0, 0, 255]),
        "A",
    );
    doc = add_layer(
        &dir,
        "b.png",
        doc,
        1,
        &box_layer(4, 4, 2, 0, 2, 2, [0, 255, 0, 255]),
        "B",
    );
    doc = add_layer(
        &dir,
        "c.png",
        doc,
        2,
        &box_layer(4, 4, 0, 2, 2, 2, [0, 0, 255, 255]),
        "C",
    );
    let before = flat_pixels(doc);
    let set = [1usize, 2, 3];
    let merged = apply(doc, |d| unsafe {
        rz_doc_merge_layers(d, set.as_ptr(), set.len())
    });
    assert_eq!(
        names(merged),
        vec!["Background", "A"],
        "one entry at the lowest member's slot, keeping its name"
    );
    assert_eq!(
        flat_pixels(merged),
        before,
        "the projection is unchanged by folding three Normal layers into one"
    );
    assert_well_formed(merged, "merge three siblings");

    // An INVISIBLE member contributes nothing — the same rule the projection
    // applies — and a group is no exception, since a hidden group bakes in
    // nothing at all.
    let dir2 = TempDir::new().unwrap();
    let mut doc = doc_from(&dir2, "bg.png", &solid(4, 4, [0, 0, 0, 0]));
    doc = add_layer(
        &dir2,
        "a.png",
        doc,
        0,
        &box_layer(4, 4, 0, 0, 2, 2, [255, 0, 0, 255]),
        "A",
    );
    doc = add_layer(
        &dir2,
        "b.png",
        doc,
        1,
        &box_layer(4, 4, 2, 0, 2, 2, [0, 255, 0, 255]),
        "B",
    );
    let (doc, g) = group(doc, &[2], "G"); // [Background, A, B, G]
    let doc = set_visible(doc, g, false);
    let visible_only = flat_pixels(doc);
    let set = [1usize, g];
    let with_hidden = apply(doc, |d| unsafe { rz_doc_merge_layers(d, set.as_ptr(), 2) });
    assert_eq!(
        flat_pixels(with_hidden),
        visible_only,
        "the hidden group baked in nothing"
    );
    unsafe { rz_doc_free(with_hidden) };

    // Members at different levels have no defined slot for the result.
    let (grouped, _) = group(merged, &[1], "G");
    let across = [0usize, 1];
    unsafe {
        assert!(
            rz_doc_merge_layers(grouped, across.as_ptr(), 2).is_null(),
            "members at different levels are refused"
        );
        let one = [0usize];
        assert!(
            rz_doc_merge_layers(grouped, one.as_ptr(), 1).is_null(),
            "fewer than two members is refused"
        );
    }
    unsafe { rz_doc_free(grouped) };
}

#[test]
fn merging_a_visible_empty_group_with_a_hidden_sibling_is_refused() {
    // `merge_layers` guarantees only that the LOWEST member is visible, not
    // that it materializes: a visible EMPTY group renders to nothing. With
    // every member contributing nothing the union extent does not exist, and
    // the old MAX/MIN sentinels underflowed into a 1x1 layer at (-1, -1) that
    // replaced — and destroyed — the members. It is a refusal.
    let dir = TempDir::new().unwrap();
    let (grouped, _) = group(solid_doc(&dir, 4, 4), &[0], "G");
    // Delete the group's only child, leaving [G(empty, visible)].
    let mut doc = apply(grouped, |d| unsafe {
        rz_doc_remove_layers(d, [0usize].as_ptr(), 1)
    });
    assert_eq!(names(doc), vec!["G"], "an empty group is the whole stack");
    doc = add_layer(&dir, "top.png", doc, 0, &solid(4, 4, BLUE), "Top");
    let doc = set_visible(doc, 1, false);
    let before = flat_pixels(doc);
    let set = [0usize, 1];
    unsafe {
        assert!(
            rz_doc_merge_layers(doc, set.as_ptr(), 2).is_null(),
            "nothing visible materialized, so there is no merged picture to make"
        );
    }
    assert_eq!(flat_pixels(doc), before, "and the members are untouched");
    assert_eq!(names(doc), vec!["G", "Top"]);
    unsafe { rz_doc_free(doc) };
}

#[test]
fn merge_visible_never_destroys_a_visible_layer_inside_a_hidden_group() {
    let dir = TempDir::new().unwrap();
    let mut doc = solid_doc(&dir, 4, 4);
    for (i, name) in ["Keep", "Top"].iter().enumerate() {
        doc = add_layer(
            &dir,
            &format!("{name}.png"),
            doc,
            i,
            &solid(4, 4, BLUE),
            name,
        );
    }
    // [Background, Keep, Top] -> hide the group holding "Keep".
    let (doc, group_idx) = group(doc, &[1], "Hidden");
    assert_eq!(names(doc), vec!["Background", "Keep", "Hidden", "Top"]);
    let doc = set_visible(doc, group_idx, false);
    let keep_pixels = layer_pixels(doc, 1);

    let merged = apply(doc, |d| unsafe { rz_doc_merge_visible(d) });
    assert_eq!(
        names(merged),
        vec!["Background", "Keep", "Hidden"],
        "the hidden group and the visible layer inside it both survive; only \
         the two CONTRIBUTING entries were merged, at the bottom one's slot"
    );
    assert_eq!(
        layer_pixels(merged, 1),
        keep_pixels,
        "the layer inside the hidden group keeps its pixels"
    );
    assert!(
        unsafe { rz_doc_layer_is_group(merged, 2) },
        "the hidden group survives to hold it"
    );
    assert_well_formed(merged, "merge visible around a hidden group");
    unsafe { rz_doc_free(merged) };
}

#[test]
fn merge_visible_counts_contributing_leaves_not_entries() {
    let dir = TempDir::new().unwrap();
    let mut doc = solid_doc(&dir, 4, 4);
    doc = add_layer(&dir, "top.png", doc, 0, &solid(4, 4, BLUE), "Top");
    // One layer inside one visible group, everything else hidden: TWO
    // contributing entries (the layer and its group) but only ONE leaf, so
    // the floor must refuse rather than merge a layer into a copy of itself.
    let (doc, _) = group(doc, &[1], "G");
    let doc = set_visible(doc, 0, false);
    assert_eq!(names(doc), vec!["Background", "Top", "G"]);
    unsafe {
        assert!(
            rz_doc_merge_visible(doc).is_null(),
            "one contributing leaf is not a merge"
        );
    }
    // A hidden layer inside a VISIBLE group does not contribute either, so
    // the count is still one and the op refuses again — the layer survives
    // because nothing happened to it.
    let doc = set_visible(doc, 0, true);
    let doc = set_visible(doc, 1, false);
    unsafe {
        assert!(
            rz_doc_merge_visible(doc).is_null(),
            "a hidden layer inside a visible group contributes no leaf either"
        );
    }
    assert_eq!(names(doc), vec!["Background", "Top", "G"]);
    unsafe { rz_doc_free(doc) };
}

#[test]
fn stamp_visible_adds_the_projection_and_leaves_the_stack_alone() {
    let dir = TempDir::new().unwrap();
    let mut doc = solid_doc(&dir, 5, 4);
    doc = add_layer(&dir, "top.png", doc, 0, &solid(5, 4, BLUE), "Top");
    let (doc, group_idx) = group(doc, &[1], "G");
    assert_eq!(group_idx, 2);
    let projection = flat_pixels(doc);

    let cname = CString::new("Stamp").unwrap();
    let stamped = apply(doc, |d| unsafe {
        rz_doc_stamp_visible(d, group_idx, cname.as_ptr())
    });
    assert_eq!(
        names(stamped),
        vec!["Background", "Top", "G", "Stamp"],
        "the new entry lands above the group's whole subtree, at its depth"
    );
    assert_eq!(depths(stamped), vec![0, 1, 0, 0]);
    assert_eq!(layer_dims(stamped, 3), (5, 4));
    assert_eq!(layer_offset(stamped, 3), (0, 0));
    assert_eq!(
        layer_pixels(stamped, 3),
        projection,
        "the stamped pixels ARE the projection"
    );
    assert_well_formed(stamped, "stamp visible above a group");
    unsafe { rz_doc_free(stamped) };
}

#[test]
fn stamp_visible_refuses_a_stack_with_nothing_visible() {
    // A stamp of nothing is a fully transparent layer, an undo step and a
    // dirty document in exchange for nothing; the host's own no-op reply
    // ("there is nothing visible to stamp") depends on the refusal.
    let dir = TempDir::new().unwrap();
    let mut doc = solid_doc(&dir, 4, 4);
    doc = add_layer(&dir, "top.png", doc, 0, &solid(4, 4, BLUE), "Top");
    let (doc, group_idx) = group(doc, &[1], "G");
    let cname = CString::new("Stamp").unwrap();
    // One visible leaf is enough — stamping a single layer is a copy of it.
    let hidden_group = set_visible(doc, group_idx, false);
    assert!(
        !unsafe { rz_doc_stamp_visible(hidden_group, 0, cname.as_ptr()) }.is_null(),
        "the Background still contributes"
    );
    let none = set_visible(hidden_group, 0, false);
    assert!(
        unsafe { rz_doc_stamp_visible(none, 0, cname.as_ptr()) }.is_null(),
        "nothing contributes, so there is nothing to stamp"
    );
    unsafe { rz_doc_free(none) };
}

// --------------------------------------------------------------- via copy --

#[test]
fn layer_via_copies_and_cuts_the_selected_coverage() {
    let dir = TempDir::new().unwrap();
    // A 4x4 opaque layer; select its left half.
    let doc = doc_from(&dir, "bg.png", &solid(4, 4, [10, 20, 30, 255]));
    let mask: Vec<u8> = (0..16).map(|i| if i % 4 < 2 { 255 } else { 0 }).collect();
    let cname = CString::new("Via").unwrap();

    let copied = apply(doc, |d| unsafe {
        rz_doc_layer_via(d, 0, mask.as_ptr(), 4, 4, false, cname.as_ptr())
    });
    assert_eq!(names(copied), vec!["Background", "Via"]);
    let via = layer_pixels(copied, 1);
    assert_eq!(
        pixel(&via, 4, 0, 0),
        [10, 20, 30, 255],
        "inside the selection the pixel is copied whole"
    );
    assert_eq!(
        pixel(&via, 4, 3, 0)[3],
        0,
        "outside it the copy is transparent"
    );
    assert_eq!(
        pixel(&layer_pixels(copied, 0), 4, 0, 0),
        [10, 20, 30, 255],
        "a COPY leaves the source untouched"
    );
    unsafe { rz_doc_free(copied) };

    // Via CUT clears the same coverage from the source.
    let doc = doc_from(&dir, "bg2.png", &solid(4, 4, [10, 20, 30, 255]));
    let cut = apply(doc, |d| unsafe {
        rz_doc_layer_via(d, 0, mask.as_ptr(), 4, 4, true, cname.as_ptr())
    });
    let source = layer_pixels(cut, 0);
    assert_eq!(
        pixel(&source, 4, 0, 0)[3],
        0,
        "the cut clears the selection"
    );
    assert_eq!(
        pixel(&source, 4, 3, 0),
        [10, 20, 30, 255],
        "and leaves the rest"
    );
    assert_well_formed(cut, "layer via cut");
    unsafe { rz_doc_free(cut) };

    // No mask means the whole layer; an empty coverage selects nothing.
    let doc = doc_from(&dir, "bg3.png", &solid(4, 4, [10, 20, 30, 255]));
    let whole = apply(doc, |d| unsafe {
        rz_doc_layer_via(d, 0, ptr::null(), 4, 4, false, cname.as_ptr())
    });
    assert_eq!(layer_pixels(whole, 1), layer_pixels(whole, 0));
    let empty = [0u8; 16];
    unsafe {
        assert!(
            rz_doc_layer_via(whole, 0, empty.as_ptr(), 4, 4, false, cname.as_ptr()).is_null(),
            "a coverage that selects nothing is refused"
        );
        assert!(
            rz_doc_layer_via(whole, 0, mask.as_ptr(), 3, 3, false, cname.as_ptr()).is_null(),
            "a mask that is not canvas-sized is refused"
        );
    }
    // An ADJUSTMENT layer has no pixels of its own either.
    let adjusted = set_meta(
        whole,
        1,
        &adjust_meta(
            "bcs",
            "{\"brightness\":0.15,\"contrast\":0.0,\"saturation\":0.0}",
        ),
    );
    unsafe {
        assert!(
            rz_doc_layer_is_adjustment(adjusted, 1),
            "the fixture really is an adjustment layer"
        );
        assert!(
            rz_doc_layer_via(adjusted, 1, ptr::null(), 4, 4, false, cname.as_ptr()).is_null(),
            "an adjustment layer is refused"
        );
    }
    // ...and so does a GROUP.
    let (grouped, group_idx) = group(adjusted, &[1], "G");
    unsafe {
        assert!(
            rz_doc_layer_via(grouped, group_idx, ptr::null(), 4, 4, false, cname.as_ptr())
                .is_null(),
            "a group is refused"
        );
        rz_doc_free(grouped);
    }
}

// -------------------------------------------------- move, align, distribute --

/// Three boxes whose CONTENT bounds differ from their pixel rects, so an
/// alignment computed by hand is checkable.
fn three_boxes(dir: &TempDir) -> *mut RzDocument {
    let mut doc = doc_from(dir, "bg.png", &solid(40, 40, [0, 0, 0, 0]));
    doc = add_layer(
        dir,
        "a.png",
        doc,
        0,
        &box_layer(40, 40, 2, 2, 4, 4, [255, 0, 0, 255]),
        "A",
    );
    doc = add_layer(
        dir,
        "b.png",
        doc,
        1,
        &box_layer(40, 40, 10, 20, 6, 4, [0, 255, 0, 255]),
        "B",
    );
    doc = add_layer(
        dir,
        "c.png",
        doc,
        2,
        &box_layer(40, 40, 30, 8, 2, 8, [0, 0, 255, 255]),
        "C",
    );
    doc
}

#[test]
fn align_uses_content_bounds_against_the_selection_or_the_canvas() {
    let dir = TempDir::new().unwrap();
    let doc = three_boxes(&dir);
    assert_eq!(bounds(doc, 1), Some((2, 2, 4, 4)));
    assert_eq!(bounds(doc, 2), Some((10, 20, 6, 4)));
    assert_eq!(bounds(doc, 3), Some((30, 8, 2, 8)));

    // Left-align to the SELECTION: the union's left edge is A's x = 2.
    let set = [1usize, 2, 3];
    let left = apply(doc, |d| unsafe {
        rz_doc_align_layers(d, set.as_ptr(), 3, ALIGN_LEFT, false)
    });
    assert_eq!(bounds(left, 1), Some((2, 2, 4, 4)), "A does not move");
    assert_eq!(bounds(left, 2), Some((2, 20, 6, 4)));
    assert_eq!(bounds(left, 3), Some((2, 8, 2, 8)));

    // Bottom-align to the CANVAS: every box's bottom edge lands on y = 40.
    let bottom = apply(left, |d| unsafe {
        rz_doc_align_layers(d, set.as_ptr(), 3, ALIGN_BOTTOM, true)
    });
    for i in [1usize, 2, 3] {
        let b = bounds(bottom, i).unwrap();
        assert_eq!(b.1 + b.3, 40, "entry {i} sits on the canvas bottom");
    }
    // Centring on the canvas puts each box's centre on the canvas centre.
    let centred = apply(bottom, |d| unsafe {
        rz_doc_align_layers(d, set.as_ptr(), 3, ALIGN_CENTER_X, true)
    });
    for i in [1usize, 2, 3] {
        let b = bounds(centred, i).unwrap();
        assert_eq!(2 * b.0 + b.2, 40, "entry {i} is centred horizontally");
    }
    // Aligning one entry to the selection is a no-op by definition.
    let one = [1usize];
    unsafe {
        assert!(rz_doc_align_layers(centred, one.as_ptr(), 1, ALIGN_LEFT, false).is_null());
        assert!(
            rz_doc_align_layers(centred, set.as_ptr(), 3, ALIGN_CENTER_X, true).is_null(),
            "nothing left to move"
        );
        rz_doc_free(centred);
    }
}

#[test]
fn distribute_equalizes_the_gaps_and_needs_three_entries() {
    let dir = TempDir::new().unwrap();
    let doc = three_boxes(&dir);
    // Widths 4, 6, 2 with lefts 2, 10, 30: span = 32 - 2 = 30, content = 12,
    // so each of the two gaps must become 9.
    let set = [1usize, 2, 3];
    let spread = apply(doc, |d| unsafe {
        rz_doc_distribute_layers(d, set.as_ptr(), 3, false)
    });
    let a = bounds(spread, 1).unwrap();
    let b = bounds(spread, 2).unwrap();
    let c = bounds(spread, 3).unwrap();
    assert_eq!((a.0, a.2), (2, 4), "the outermost keep their positions");
    assert_eq!((c.0, c.2), (30, 2));
    assert_eq!(b.0 - (a.0 + a.2), 9, "the first gap");
    assert_eq!(c.0 - (b.0 + b.2), 9, "and the second, equal to it");
    unsafe {
        let two = [1usize, 2];
        assert!(
            rz_doc_distribute_layers(spread, two.as_ptr(), 2, false).is_null(),
            "two entries have only one gap to equalize"
        );
        assert!(
            rz_doc_distribute_layers(spread, set.as_ptr(), 3, false).is_null(),
            "already even"
        );
        rz_doc_free(spread);
    }
}

/// A POSITION lock refuses the WHOLE align or distribute call, including when
/// the locked entry is one the arithmetic would never have moved.
///
/// Both ops walk their entries and call `move_layers` per entry, so leaving
/// the lock check to those calls would make the refusal depend on invisible
/// geometry: the entry that DEFINES the reference edge has a zero delta and is
/// skipped, and an entry with nothing opaque in it is skipped before that. The
/// check therefore runs up front, over the whole expanded set, which is what
/// makes the host's "a position lock refuses the whole call" refusal true.
#[test]
fn a_position_lock_refuses_the_whole_align_or_distribute_call() {
    let dir = TempDir::new().unwrap();
    let set = [1usize, 2, 3];
    // A (entry 1) sits at x = 2, the leftmost of the three, so a left-align
    // moves B and C and leaves A exactly where it is.
    let a_locked = set_locks(three_boxes(&dir), 1, LOCK_POSITION);
    unsafe {
        assert!(
            rz_doc_align_layers(a_locked, set.as_ptr(), 3, ALIGN_LEFT, false).is_null(),
            "the entry that defines the reference edge would not have moved, and still \
             refuses the call"
        );
        assert!(
            rz_doc_distribute_layers(a_locked, set.as_ptr(), 3, false).is_null(),
            "an outermost entry never moves either, and still refuses the call"
        );
        rz_doc_free(a_locked);
    }
    // Entry 0 is the fully transparent background: no content at all, so both
    // ops skip it outright — and its lock still refuses.
    let empty_locked = set_locks(three_boxes(&dir), 0, LOCK_POSITION);
    let with_empty = [0usize, 1, 2, 3];
    unsafe {
        assert!(
            rz_doc_align_layers(empty_locked, with_empty.as_ptr(), 4, ALIGN_LEFT, false).is_null(),
            "an entry with nothing opaque is skipped by the arithmetic, not by the lock"
        );
        assert!(rz_doc_distribute_layers(empty_locked, with_empty.as_ptr(), 4, false).is_null());
        rz_doc_free(empty_locked);
    }
    // The same two calls go through once the lock is cleared, so it is the
    // lock that refused and not the geometry.
    let unlocked = set_locks(set_locks(three_boxes(&dir), 1, LOCK_POSITION), 1, 0);
    let aligned = apply(unlocked, |d| unsafe {
        rz_doc_align_layers(d, set.as_ptr(), 3, ALIGN_LEFT, false)
    });
    assert_eq!(bounds(aligned, 2), Some((2, 20, 6, 4)));
    unsafe { rz_doc_free(aligned) };
}

#[test]
fn links_make_move_and_transform_carry_every_member() {
    let dir = TempDir::new().unwrap();
    let doc = three_boxes(&dir);
    let pair = [1usize, 3];
    let linked = apply(doc, |d| unsafe { rz_doc_link_layers(d, pair.as_ptr(), 2) });
    let ids = links(linked);
    assert_eq!(ids[1], 1, "the smallest unused non-zero id");
    assert_eq!(ids[3], 1);
    assert_eq!(ids[2], 0, "an unlinked entry keeps 0");
    unsafe {
        assert!(
            rz_doc_link_layers(linked, pair.as_ptr(), 2).is_null(),
            "re-linking the same set changes nothing"
        );
        let one = [1usize];
        assert!(
            rz_doc_link_layers(linked, one.as_ptr(), 1).is_null(),
            "a link group of one is not a link"
        );
    }

    // Moving ONE member moves the other; the unlinked entry stays put.
    let only_a = [1usize];
    let moved = apply(linked, |d| unsafe {
        rz_doc_move_layers(d, only_a.as_ptr(), 1, 3, -1)
    });
    assert_eq!(bounds(moved, 1), Some((5, 1, 4, 4)));
    assert_eq!(bounds(moved, 3), Some((33, 7, 2, 8)), "the link followed");
    assert_eq!(bounds(moved, 2), Some((10, 20, 6, 4)), "and nothing else");

    // A transform fans out the same way: a half-scale about the origin.
    let affine = [0.5f64, 0.0, 0.0, 0.5, 0.0, 0.0];
    let scaled = apply(moved, |d| unsafe {
        rz_doc_transform_layers(d, only_a.as_ptr(), 1, affine.as_ptr(), FILTER_NEAREST)
    });
    let a = bounds(scaled, 1).unwrap();
    let c = bounds(scaled, 3).unwrap();
    assert_eq!((a.0, a.1), (2, 0), "A halves toward the origin");
    assert_eq!((c.0, c.1), (16, 3), "and so does its link partner");
    assert_eq!(
        bounds(scaled, 2),
        Some((10, 20, 6, 4)),
        "the unlinked entry is untouched"
    );

    // Unlinking clears both, since a group of one is not a link.
    let unlinked = apply(scaled, |d| unsafe {
        rz_doc_unlink_layers(d, only_a.as_ptr(), 1)
    });
    assert_eq!(links(unlinked), vec![0, 0, 0, 0]);
    unsafe {
        assert!(
            rz_doc_unlink_layers(unlinked, only_a.as_ptr(), 1).is_null(),
            "nothing to unlink"
        );
        rz_doc_free(unlinked);
    }
}

#[test]
fn moving_a_group_moves_its_whole_subtree() {
    let dir = TempDir::new().unwrap();
    let doc = three_boxes(&dir);
    let (doc, group_idx) = group(doc, &[1, 2], "G");
    assert_eq!(group_idx, 3);
    let set = [group_idx];
    let moved = apply(doc, |d| unsafe {
        rz_doc_move_layers(d, set.as_ptr(), 1, 5, 5)
    });
    assert_eq!(bounds(moved, 1), Some((7, 7, 4, 4)));
    assert_eq!(bounds(moved, 2), Some((15, 25, 6, 4)));
    assert_eq!(
        bounds(moved, 4),
        Some((30, 8, 2, 8)),
        "the entry outside the group stays"
    );
    unsafe {
        assert!(
            rz_doc_move_layers(moved, set.as_ptr(), 1, 0, 0).is_null(),
            "a zero delta is a no-op"
        );
        rz_doc_free(moved);
    }
}

#[test]
fn moving_a_masked_group_carries_its_mask_with_it() {
    // The two gestures that translate a group — the Move tool's drag (which is
    // `move_layers`, and so `translate_entry`) and Free Transform with a pure
    // translation (`transform_layers`) — must give the same picture. They did
    // not: the transform warped the group's canvas-sized mask and the move
    // left it behind, so dragging a masked group silently re-clipped it
    // against a window that no longer matched its content.
    let dir = TempDir::new().unwrap();
    // A left-half mask: the red box at (2, 2) shows, and anything the group
    // carries past x = 20 does not.
    let sel: Vec<u8> = (0..40 * 40)
        .map(|i| if (i % 40) < 20 { 255u8 } else { 0 })
        .collect();
    let masked_group = |dir: &TempDir| -> (*mut RzDocument, usize) {
        let (doc, g) = group(three_boxes(dir), &[1], "G");
        let doc = apply(doc, |d| unsafe {
            rz_doc_adding_layer_mask(d, g, MASK_FROM_SELECTION, sel.as_ptr(), 40, 40)
        });
        (doc, g)
    };
    let (doc, group_idx) = masked_group(&dir);
    let set = [group_idx];
    let moved = apply(doc, |d| unsafe {
        rz_doc_move_layers(d, set.as_ptr(), 1, 22, 0)
    });
    // The oracle: the identical translation through the OTHER path, which has
    // always carried the mask.
    let (doc, _) = masked_group(&dir);
    let translate = [1.0f64, 0.0, 0.0, 1.0, 22.0, 0.0];
    let transformed = apply(doc, |d| unsafe {
        rz_doc_transform_layers(d, set.as_ptr(), 1, translate.as_ptr(), FILTER_NEAREST)
    });
    assert_eq!(
        flat_pixels(moved),
        flat_pixels(transformed),
        "a masked group dragged 22 px right must look like the same group translated 22 px right"
    );
    // ...and the mask really did travel: the box lands at x = 24, past the
    // mask's original x < 20 window, and is still visible.
    assert_eq!(
        pixel(&flat_pixels(moved), 40, 25, 3),
        [255, 0, 0, 255],
        "the moved box is still revealed, because its mask moved with it"
    );
    unsafe {
        rz_doc_free(moved);
        rz_doc_free(transformed);
    }
}

// ------------------------------------------------------------------ locks --

#[test]
fn a_transparency_locked_layer_still_transforms_and_a_position_locked_one_does_not() {
    let dir = TempDir::new().unwrap();
    let affine = [2.0f64, 0.0, 0.0, 2.0, 0.0, 0.0];
    let doc = solid_doc(&dir, 4, 4);
    let doc = set_locks(doc, 0, LOCK_TRANSPARENCY);
    let scaled = apply(doc, |d| unsafe {
        rz_doc_transform_layer(d, 0, affine.as_ptr(), FILTER_NEAREST)
    });
    assert_eq!(
        layer_dims(scaled, 0),
        (8, 8),
        "Lock Transparency does not block Free Transform — a transform \
         resamples the alpha with everything else, so a frozen alpha channel \
         has no meaning there"
    );
    let locked = set_locks(scaled, 0, LOCK_POSITION);
    unsafe {
        assert!(
            rz_doc_transform_layer(locked, 0, affine.as_ptr(), FILTER_NEAREST).is_null(),
            "Lock Position does block it"
        );
        let quad = [0.0f64, 0.0, 4.0, 0.0, 5.0, 4.0, 0.0, 4.0];
        assert!(
            rz_doc_perspective_layer(locked, 0, quad.as_ptr(), FILTER_NEAREST).is_null(),
            "and a perspective distort with it"
        );
        assert!(rz_doc_with_layer_offset(locked, 0, 3, 3).is_null());
        rz_doc_free(locked);
    }
}

#[test]
fn a_transparency_locked_layer_keeps_its_alpha_and_mints_no_phantom_edit() {
    let dir = TempDir::new().unwrap();
    // Left half opaque, right half transparent.
    let img = box_layer(4, 4, 0, 0, 2, 4, [10, 20, 30, 255]);
    let doc = doc_from(&dir, "half.png", &img);
    let doc = set_locks(doc, 0, LOCK_TRANSPARENCY);

    // A full-canvas opaque green stroke: colour lands, coverage does not.
    let overlay: Vec<u8> = (0..16).flat_map(|_| [0u8, 255, 0, 255]).collect();
    let painted = apply(doc, |d| unsafe {
        rz_doc_painting_layer(d, 0, overlay.as_ptr(), 4, 4, COMPOSITE_OVER, 1.0)
    });
    let px = layer_pixels(painted, 0);
    assert_eq!(
        pixel(&px, 4, 0, 0),
        [0, 255, 0, 255],
        "colour is written where the layer was opaque"
    );
    assert_eq!(
        pixel(&px, 4, 3, 0)[3],
        0,
        "and the transparent half stays transparent"
    );

    // A stroke landing ONLY where alpha is 0 changes nothing after the alpha
    // restore, so it must refuse rather than mint an undo step.
    let right: Vec<u8> = (0..16)
        .flat_map(|i| {
            if i % 4 >= 2 {
                [0u8, 0, 255, 255]
            } else {
                [0, 0, 0, 0]
            }
        })
        .collect();
    let full = [255u8; 16];
    unsafe {
        assert!(
            rz_doc_painting_layer(painted, 0, right.as_ptr(), 4, 4, COMPOSITE_OVER, 1.0).is_null(),
            "a stroke entirely outside the opaque area is a no-op"
        );
        assert!(
            rz_doc_clear_selection(painted, 0, full.as_ptr(), 4, 4).is_null(),
            "clearing cannot punch a hole, so it changes nothing"
        );
        let erase: Vec<u8> = (0..16).flat_map(|_| [0u8, 0, 0, 255]).collect();
        assert!(
            rz_doc_painting_layer(painted, 0, erase.as_ptr(), 4, 4, COMPOSITE_ERASE, 1.0).is_null(),
            "and neither can an eraser"
        );
        rz_doc_free(painted);
    }
}

/// Every export the lock gate wraps, driven against a layer carrying each
/// lock. A missing `under_locks` fails here rather than shipping.
#[test]
fn the_lock_sweep_covers_every_wrapped_export() {
    let dir = TempDir::new().unwrap();
    let overlay = [255u8; 4 * 4 * 4];
    let coverage = [255u8; 4 * 4];
    let plane = [128u8; 4 * 4];
    let rgba = [0u8, 255, 0, 255];
    let affine = [2.0f64, 0.0, 0.0, 2.0, 0.0, 0.0];
    let quad = [0.0f64, 0.0, 4.0, 0.0, 5.0, 4.0, 0.0, 4.0];
    let cname = CString::new("Via").unwrap();

    for &lock in &[LOCK_PIXELS, LOCK_ALL] {
        let doc = doc_from(&dir, "lock.png", &solid(4, 4, [10, 20, 30, 255]));
        let doc = set_locks(doc, 0, lock);
        let mut err: *mut c_char = ptr::null_mut();
        unsafe {
            let img = open_image(&dir, "src.png", &solid(4, 4, BLUE));
            assert!(rz_doc_with_layer_pixels(doc, 0, img).is_null(), "{lock}");
            rz_image_free(img);
            assert!(
                rz_doc_with_layer_pixels_rgba(doc, 0, overlay.as_ptr(), 4, 4).is_null(),
                "{lock}"
            );
            assert!(
                rz_doc_set_layer_content(doc, 0, overlay.as_ptr(), 4, 4, 0, 0, ptr::null())
                    .is_null(),
                "{lock}"
            );
            assert!(
                rz_doc_painting_layer(doc, 0, overlay.as_ptr(), 4, 4, COMPOSITE_OVER, 1.0)
                    .is_null(),
                "{lock}"
            );
            assert!(
                rz_doc_painting_layer_blend(doc, 0, overlay.as_ptr(), 4, 4, BLEND_MULTIPLY, 1.0)
                    .is_null(),
                "{lock}"
            );
            assert!(
                rz_doc_dodge_burn_layer(doc, 0, overlay.as_ptr(), 4, 4, 0.5, 1, false).is_null(),
                "{lock}"
            );
            assert!(
                rz_doc_heal_layer(doc, 0, overlay.as_ptr(), 4, 4, 1.0, &mut err).is_null(),
                "{lock}"
            );
            assert!(err.is_null(), "a lock refusal is a domain refusal, not Err");
            assert!(
                rz_doc_spot_heal_layer(
                    doc,
                    0,
                    overlay.as_ptr(),
                    4,
                    4,
                    1.0,
                    4,
                    1,
                    false,
                    false,
                    &mut err
                )
                .is_null(),
                "{lock}"
            );
            assert!(err.is_null());
            assert!(
                rz_doc_content_aware_fill(
                    doc,
                    0,
                    coverage.as_ptr(),
                    4,
                    4,
                    4,
                    1,
                    false,
                    false,
                    &mut err
                )
                .is_null(),
                "{lock}"
            );
            assert!(err.is_null());
            assert!(
                rz_doc_red_eye_layer(doc, 0, 0, 0, 4, 4, 0.5, 0.5).is_null(),
                "{lock}"
            );
            assert!(
                rz_doc_bucket_fill(doc, 0, 0, 0, 10, rgba.as_ptr(), true, ptr::null()).is_null(),
                "{lock}"
            );
            assert!(
                rz_doc_gradient(
                    doc,
                    0,
                    0.0,
                    0.0,
                    4.0,
                    4.0,
                    rgba.as_ptr(),
                    rgba.as_ptr(),
                    GRADIENT_LINEAR,
                    ptr::null()
                )
                .is_null(),
                "{lock}"
            );
            assert!(
                rz_doc_clear_selection(doc, 0, coverage.as_ptr(), 4, 4).is_null(),
                "{lock}"
            );
            assert!(
                rz_doc_with_layer_plane(doc, 0, PLANE_RED, plane.as_ptr(), 4, 4).is_null(),
                "{lock}"
            );
            assert!(
                rz_doc_with_layer_space_plane(doc, 0, PLANE_RED, plane.as_ptr(), 4, 4).is_null(),
                "{lock}"
            );
            assert!(
                rz_doc_painting_layer_plane(doc, 0, PLANE_RED, overlay.as_ptr(), 4, 4).is_null(),
                "{lock}"
            );
            assert!(
                rz_doc_layer_via(doc, 0, coverage.as_ptr(), 4, 4, true, cname.as_ptr()).is_null(),
                "via CUT runs the clear under the source's locks"
            );
            rz_doc_free(doc);
        }
    }

    // POSITION blocks the two resamplers and the offset setter, and nothing
    // else; MASK edits are blocked only by Lock All.
    let doc = doc_from(&dir, "pos.png", &solid(4, 4, [10, 20, 30, 255]));
    let doc = set_locks(doc, 0, LOCK_POSITION);
    unsafe {
        assert!(rz_doc_with_layer_offset(doc, 0, 1, 1).is_null());
        assert!(rz_doc_transform_layer(doc, 0, affine.as_ptr(), FILTER_NEAREST).is_null());
        assert!(rz_doc_perspective_layer(doc, 0, quad.as_ptr(), FILTER_NEAREST).is_null());
        let set = [0usize];
        assert!(rz_doc_move_layers(doc, set.as_ptr(), 1, 1, 1).is_null());
        assert!(
            rz_doc_transform_layers(doc, set.as_ptr(), 1, affine.as_ptr(), FILTER_NEAREST)
                .is_null()
        );
    }
    // A pixel edit is still allowed under a POSITION lock.
    let painted = apply(doc, |d| unsafe {
        rz_doc_painting_layer(d, 0, overlay.as_ptr(), 4, 4, COMPOSITE_OVER, 1.0)
    });
    // Mask edits: allowed under Pixels, refused under Lock All.
    let masked = apply(painted, |d| unsafe {
        rz_doc_adding_layer_mask(d, 0, MASK_REVEAL_ALL, ptr::null(), 0, 0)
    });
    let pixels_locked = set_locks(masked, 0, LOCK_PIXELS);
    let toggled = apply(pixels_locked, |d| unsafe {
        rz_doc_with_layer_mask_enabled(d, 0, false)
    });
    let all_locked = set_locks(toggled, 0, LOCK_ALL);
    unsafe {
        assert!(rz_doc_with_layer_mask_enabled(all_locked, 0, true).is_null());
        assert!(
            rz_doc_adding_layer_mask(all_locked, 0, MASK_HIDE_ALL, ptr::null(), 0, 0).is_null()
        );
        assert!(rz_doc_removing_layer_mask(all_locked, 0, false).is_null());
        assert!(rz_doc_painting_layer_mask(all_locked, 0, overlay.as_ptr(), 4, 4).is_null());
        // ...and the query says WHICH lock, so a host can name it.
        assert_eq!(rz_doc_lock_block(all_locked, 0, EDIT_PIXELS), LOCK_PIXELS);
        assert_eq!(
            rz_doc_lock_block(all_locked, 0, EDIT_POSITION),
            LOCK_POSITION
        );
        assert_eq!(rz_doc_lock_block(all_locked, 0, EDIT_MASK), LOCK_ALL);
        // The two kinds that are not a plain pixel write; `lock_tests` drives
        // the ops behind them (applying a mask, and merging into an entry).
        assert_eq!(rz_doc_lock_block(all_locked, 0, EDIT_MASK_APPLY), LOCK_ALL);
        assert_eq!(
            rz_doc_lock_block(all_locked, 0, EDIT_MERGE),
            LOCK_PIXELS | LOCK_TRANSPARENCY
        );
        assert_eq!(rz_doc_lock_block(all_locked, 0, 99), 0, "unknown kind");
        rz_doc_free(all_locked);
    }
}

#[test]
fn a_position_locked_descendant_refuses_its_group_s_move() {
    let dir = TempDir::new().unwrap();
    let doc = three_boxes(&dir);
    let (doc, group_idx) = group(doc, &[1, 2], "G");
    let doc = set_locks(doc, 1, LOCK_POSITION);
    let set = [group_idx];
    unsafe {
        assert_eq!(
            rz_doc_lock_block(doc, group_idx, EDIT_POSITION),
            LOCK_POSITION,
            "moving a group moves its children, so their bits count"
        );
        assert!(rz_doc_move_layers(doc, set.as_ptr(), 1, 1, 1).is_null());
        assert!(rz_doc_with_layer_offset(doc, group_idx, 0, 0).is_null());
        rz_doc_free(doc);
    }
}

/// Every pixel export driven against a GROUP index. A guard that reads
/// `layers.get` instead of `raster_layer` fails here.
#[test]
fn the_group_sweep_covers_every_pixel_export() {
    let dir = TempDir::new().unwrap();
    let doc = doc_from(&dir, "bg.png", &solid(4, 4, [10, 20, 30, 255]));
    let doc = add_layer(&dir, "top.png", doc, 0, &solid(4, 4, BLUE), "Top");
    let (doc, g) = group(doc, &[1], "G");
    let overlay = [255u8; 4 * 4 * 4];
    let coverage = [255u8; 4 * 4];
    let plane = [128u8; 4 * 4];
    let rgba = [0u8, 255, 0, 255];
    let mut err: *mut c_char = ptr::null_mut();
    unsafe {
        let img = open_image(&dir, "src.png", &solid(4, 4, BLUE));
        assert!(rz_doc_with_layer_pixels(doc, g, img).is_null());
        rz_image_free(img);
        assert!(rz_doc_with_layer_pixels_rgba(doc, g, overlay.as_ptr(), 4, 4).is_null());
        assert!(
            rz_doc_set_layer_content(doc, g, overlay.as_ptr(), 4, 4, 0, 0, ptr::null()).is_null()
        );
        assert!(
            rz_doc_painting_layer(doc, g, overlay.as_ptr(), 4, 4, COMPOSITE_OVER, 1.0).is_null()
        );
        assert!(
            rz_doc_painting_layer_blend(doc, g, overlay.as_ptr(), 4, 4, BLEND_MULTIPLY, 1.0)
                .is_null()
        );
        assert!(rz_doc_dodge_burn_layer(doc, g, overlay.as_ptr(), 4, 4, 0.5, 1, false).is_null());
        assert!(rz_doc_heal_layer(doc, g, overlay.as_ptr(), 4, 4, 1.0, &mut err).is_null());
        assert!(err.is_null(), "a group index is a domain refusal, not Err");
        assert!(rz_doc_spot_heal_layer(
            doc,
            g,
            overlay.as_ptr(),
            4,
            4,
            1.0,
            4,
            1,
            false,
            false,
            &mut err
        )
        .is_null());
        assert!(err.is_null());
        assert!(rz_doc_content_aware_fill(
            doc,
            g,
            coverage.as_ptr(),
            4,
            4,
            4,
            1,
            false,
            false,
            &mut err
        )
        .is_null());
        assert!(err.is_null());
        assert!(rz_doc_red_eye_layer(doc, g, 0, 0, 4, 4, 0.5, 0.5).is_null());
        assert!(rz_doc_bucket_fill(doc, g, 0, 0, 10, rgba.as_ptr(), true, ptr::null()).is_null());
        assert!(rz_doc_gradient(
            doc,
            g,
            0.0,
            0.0,
            4.0,
            4.0,
            rgba.as_ptr(),
            rgba.as_ptr(),
            GRADIENT_LINEAR,
            ptr::null()
        )
        .is_null());
        assert!(rz_doc_clear_selection(doc, g, coverage.as_ptr(), 4, 4).is_null());
        assert!(rz_doc_with_layer_plane(doc, g, PLANE_RED, plane.as_ptr(), 4, 4).is_null());
        assert!(rz_doc_with_layer_space_plane(doc, g, PLANE_RED, plane.as_ptr(), 4, 4).is_null());
        assert!(rz_doc_painting_layer_plane(doc, g, PLANE_RED, overlay.as_ptr(), 4, 4).is_null());
        assert!(
            rz_doc_layer_image(doc, g).is_null(),
            "a group has no pixels"
        );
        rz_doc_free(doc);
    }
}

#[test]
fn a_group_moves_to_every_legal_destination_above_a_smaller_sibling() {
    // `to` indexes the stack with the moved subtree ALREADY removed, so every
    // value in 0..=len - subtree.len() is a legal insertion point. Testing it
    // against the PRE-drain subtree range refused the commonest group drag
    // there is: a group with children moved one place up over a plain layer.
    let dir = TempDir::new().unwrap();
    let mut doc = solid_doc(&dir, 4, 4);
    for (i, name) in ["A", "B", "C"].iter().enumerate() {
        doc = add_layer(
            &dir,
            &format!("{name}.png"),
            doc,
            i,
            &solid(4, 4, BLUE),
            name,
        );
    }
    let (doc, g) = group(doc, &[1, 2, 3], "G");
    assert_eq!(g, 4);
    let doc = add_layer(&dir, "t.png", doc, g, &solid(4, 4, BLUE), "T");
    assert_eq!(names(doc), vec!["Background", "A", "B", "C", "G", "T"]);
    assert_eq!(depths(doc), vec![0, 1, 1, 1, 0, 0]);

    // The subtree is 1..5, so after the drain the stack is ["Background",
    // "T"] and 0, 1 and 2 are all legal. `to = 2` — G above T, the drag the
    // panel computes for "move the group one place up" — falls squarely
    // inside 1..5 and was refused.
    // The block is spliced in whole, and the group entry is the LAST record
    // of its own subtree.
    let expected = [
        Some((
            vec!["A", "B", "C", "G", "Background", "T"],
            vec![1, 1, 1, 0, 0, 0],
        )),
        // `to` numbers the stack with the subtree ALREADY drained, so 1 is
        // exactly where the block came from: the move moves nothing, and the
        // core's no-op rule refuses it rather than answering an identical
        // document the host would mint an undo step for.
        None,
        Some((
            vec!["Background", "T", "A", "B", "C", "G"],
            vec![0, 0, 1, 1, 1, 0],
        )),
    ];
    for (to, want) in expected.iter().enumerate() {
        let moved = unsafe { rz_doc_move_layer_to(doc, g, to, 0) };
        let Some((want, want_depths)) = want else {
            assert!(
                moved.is_null(),
                "to = {to} puts the block back where it was"
            );
            continue;
        };
        assert!(!moved.is_null(), "to = {to} is a legal destination");
        assert_eq!(&names(moved), want, "to = {to}");
        assert_eq!(&depths(moved), want_depths, "to = {to}");
        assert_well_formed(moved, "move a group among its siblings");
        unsafe { rz_doc_free(moved) };
    }
    // The same refusal for the entry's OWN slot at its own depth, which is
    // what a panel drag that ends where it began computes.
    assert!(
        unsafe { rz_doc_move_layer_to(doc, 1, 1, 1) }.is_null(),
        "a raster entry put back at its own index and depth is a no-op"
    );
    unsafe { rz_doc_free(doc) };
}

#[test]
fn transforming_an_empty_group_alone_changes_nothing_and_is_refused() {
    // An empty group is reachable (PSD import keeps one, and deleting a
    // group's last child leaves one), it has no pixels to resample and no
    // mask to warp, and an identical copy would mint a phantom undo step.
    let dir = TempDir::new().unwrap();
    let mut doc = solid_doc(&dir, 4, 4);
    doc = add_layer(&dir, "top.png", doc, 0, &solid(4, 4, BLUE), "Top");
    let (doc, g) = group(doc, &[1], "G");
    let empty = apply(doc, |d| unsafe {
        rz_doc_remove_layers(d, [1usize].as_ptr(), 1)
    });
    assert_eq!(names(empty), vec!["Background", "G"]);
    let affine = [2.0f64, 0.0, 0.0, 2.0, 0.0, 0.0];
    let set = [g - 1];
    assert!(
        unsafe { rz_doc_transform_layers(empty, set.as_ptr(), 1, affine.as_ptr(), FILTER_NEAREST) }
            .is_null(),
        "nothing was resampled, so the op is a no-op"
    );
    // With a mask on it there IS something to resample, and it goes through.
    let sel = [255u8; 16];
    let masked = apply(empty, |d| unsafe {
        rz_doc_adding_layer_mask(d, g - 1, MASK_FROM_SELECTION, sel.as_ptr(), 4, 4)
    });
    assert!(!unsafe {
        rz_doc_transform_layers(masked, set.as_ptr(), 1, affine.as_ptr(), FILTER_NEAREST)
    }
    .is_null());
    unsafe { rz_doc_free(masked) };
}

// ---------------------------------------------------- the invariant, hostile --

/// One case per structural op, each fed an argument that would leave the
/// stack malformed, each asserting NULL. This is the ONLY proof the runtime
/// gate is wired: `cargo test --release` compiles every `debug_assert!` out,
/// so nothing else in this crate would notice a missing check.
#[test]
fn every_structural_op_refuses_a_malformed_result() {
    let dir = TempDir::new().unwrap();
    let mut doc = solid_doc(&dir, 4, 4);
    for (i, name) in ["A", "B"].iter().enumerate() {
        doc = add_layer(
            &dir,
            &format!("{name}.png"),
            doc,
            i,
            &solid(4, 4, BLUE),
            name,
        );
    }
    let (doc, g) = group(doc, &[1, 2], "G"); // [Background, A, B, G]
    let cname = CString::new("x").unwrap();
    let affine = [1.0f64, 0.0, 0.0, 1.0, 5.0, 0.0];
    unsafe {
        // move_layer_to: a depth with no enclosing group, a (to, depth) pair
        // whose result is malformed, and a depth past the cap.
        assert!(
            rz_doc_move_layer_to(doc, 0, 3, 1).is_null(),
            "a child at the very top has no enclosing group"
        );
        assert!(
            rz_doc_move_layer_to(doc, g, 1, 1).is_null(),
            "the group would end up deeper than the entry closing the stack"
        );
        assert!(
            rz_doc_move_layer_to(doc, 0, 0, 11).is_null(),
            "past the cap"
        );
        // arrange: out of range and an unknown direction.
        assert!(rz_doc_arrange_layer(doc, 9, ARRANGE_FRONT).is_null());
        assert!(rz_doc_arrange_layer(doc, 0, 7).is_null());
        // The set ops all refuse a list naming an entry that is not there.
        let bad = [9usize];
        assert!(rz_doc_duplicate_layers(doc, bad.as_ptr(), 1).is_null());
        assert!(rz_doc_remove_layers(doc, bad.as_ptr(), 1).is_null());
        assert!(rz_doc_merge_layers(doc, bad.as_ptr(), 1).is_null());
        assert!(rz_doc_move_layers(doc, bad.as_ptr(), 1, 1, 1).is_null());
        assert!(
            rz_doc_transform_layers(doc, bad.as_ptr(), 1, affine.as_ptr(), FILTER_NEAREST)
                .is_null()
        );
        assert!(rz_doc_align_layers(doc, bad.as_ptr(), 1, ALIGN_LEFT, true).is_null());
        assert!(rz_doc_distribute_layers(doc, bad.as_ptr(), 1, false).is_null());
        assert!(rz_doc_link_layers(doc, bad.as_ptr(), 1).is_null());
        assert!(rz_doc_unlink_layers(doc, bad.as_ptr(), 1).is_null());
        assert!(rz_doc_ungroup_layer(doc, 9, ptr::null_mut(), ptr::null_mut(), 0).is_null());
        assert!(rz_doc_stamp_visible(doc, 9, cname.as_ptr()).is_null());
        assert!(rz_doc_layer_via(doc, 9, ptr::null(), 4, 4, false, cname.as_ptr()).is_null());
    }
    assert_well_formed(doc, "nothing was changed by any refusal");
    unsafe { rz_doc_free(doc) };
}

/// Every op that changes the shape of the stack, run once each on a nested
/// document, asserting the invariant holds afterwards — the sweep the
/// hostile cases above cannot cover, because these all SUCCEED.
#[test]
fn every_structural_op_leaves_the_stack_well_formed() {
    let dir = TempDir::new().unwrap();
    let mut doc = solid_doc(&dir, 6, 6);
    for (i, name) in ["A", "B", "C"].iter().enumerate() {
        doc = add_layer(
            &dir,
            &format!("{name}.png"),
            doc,
            i,
            &solid(6, 6, BLUE),
            name,
        );
    }
    let (doc, inner) = group(doc, &[1, 2], "Inner");
    let (doc, _outer) = group(doc, &[inner], "Outer");
    assert_eq!(
        names(doc),
        vec!["Background", "A", "B", "Inner", "Outer", "C"]
    );
    assert_eq!(depths(doc), vec![0, 2, 2, 1, 0, 0]);
    assert_well_formed(doc, "a nested document");

    let cname = CString::new("x").unwrap();
    let one = [1usize];
    let pair = [1usize, 2];
    let ops: Vec<(&str, DocOp)> = vec![
        (
            "arrange",
            Box::new(|d| unsafe { rz_doc_arrange_layer(d, 1, ARRANGE_FORWARD) }),
        ),
        (
            "duplicate_layers",
            Box::new(move |d| unsafe { rz_doc_duplicate_layers(d, pair.as_ptr(), 2) }),
        ),
        (
            "remove_layers",
            Box::new(move |d| unsafe { rz_doc_remove_layers(d, one.as_ptr(), 1) }),
        ),
        (
            "merge_layers",
            Box::new(move |d| unsafe { rz_doc_merge_layers(d, pair.as_ptr(), 2) }),
        ),
        (
            "merge_visible",
            Box::new(|d| unsafe { rz_doc_merge_visible(d) }),
        ),
        (
            "stamp_visible",
            Box::new(move |d| unsafe { rz_doc_stamp_visible(d, 3, cname.as_ptr()) }),
        ),
        (
            "layer_via",
            Box::new(move |d| unsafe {
                let n = CString::new("via").unwrap();
                rz_doc_layer_via(d, 1, ptr::null(), 6, 6, true, n.as_ptr())
            }),
        ),
        (
            "duplicating_layer on a group",
            Box::new(|d| unsafe { rz_doc_duplicating_layer(d, 3) }),
        ),
        (
            "removing_layer on a group",
            Box::new(|d| unsafe { rz_doc_removing_layer(d, 3) }),
        ),
        (
            "merging_down across a boundary",
            Box::new(|d| unsafe { rz_doc_merging_down(d, 4) }),
        ),
        (
            "moving_layer",
            Box::new(|d| unsafe { rz_doc_moving_layer(d, 5, 0) }),
        ),
        (
            "ungroup_layer",
            Box::new(|d| unsafe {
                rz_doc_ungroup_layer(d, 3, ptr::null_mut(), ptr::null_mut(), 0)
            }),
        ),
    ];
    for (what, op) in ops {
        let out = op(doc);
        assert!(!out.is_null(), "{what} refused");
        assert_well_formed(out, what);
        unsafe { rz_doc_free(out) };
    }
    // ...and each of them survives a round trip through the format.
    let path = dir.path().join("nested.rzdc");
    let c = cpath(&path);
    let mut err: *mut c_char = ptr::null_mut();
    assert!(unsafe { rz_doc_save_native(doc, c.as_ptr(), &mut err) });
    let back = unsafe { rz_doc_open(c.as_ptr(), &mut err) };
    assert!(!back.is_null(), "{}", take_err_string(err));
    assert_eq!(depths(back), depths(doc));
    assert_eq!(kinds(back), kinds(doc));
    assert_well_formed(back, "after a save and reopen");
    unsafe {
        rz_doc_free(back);
        rz_doc_free(doc);
    }
}

#[test]
fn ungroup_discards_the_group_s_own_compositing_properties() {
    let dir = TempDir::new().unwrap();
    let mut doc = solid_doc(&dir, 5, 5);
    doc = add_layer(&dir, "a.png", doc, 0, &solid(5, 5, BLUE), "A");
    let (doc, g) = group(doc, &[1], "G");
    let doc = apply(doc, |d| unsafe { rz_doc_with_layer_opacity(d, g, 0.5) });
    let doc = apply(doc, |d| unsafe {
        rz_doc_adding_layer_mask(d, g, MASK_HIDE_ALL, ptr::null(), 0, 0)
    });
    let dissolved = apply(doc, |d| unsafe {
        rz_doc_ungroup_layer(d, g, ptr::null_mut(), ptr::null_mut(), 0)
    });
    assert_eq!(names(dissolved), vec!["Background", "A"]);
    assert_eq!(depths(dissolved), vec![0, 0]);
    assert_eq!(
        unsafe { rz_doc_layer_opacity(dissolved, 1) },
        1.0,
        "the group's opacity cannot be expressed on the child and is dropped"
    );
    assert!(
        !unsafe { rz_doc_layer_has_mask(dissolved, 1) },
        "and so is its mask"
    );
    assert_well_formed(dissolved, "ungroup");
    unsafe { rz_doc_free(dissolved) };
}
