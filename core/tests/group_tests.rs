//! Layer GROUPS: the byte-identity proofs a document with no groups must keep
//! passing, the isolation rule and the two behaviours it deliberately
//! degrades, the group's own opacity / blend mode / canvas-sized mask / style
//! / clipping, nesting and its cap, the content-bounds and hit-test queries,
//! the whole-document geometry ops carrying a group mask against a
//! hand-computed oracle, and the group/ungroup round trips. Black-box through
//! the FFI; shared fixtures live in `tests/common`, the structural ops' own
//! coverage in `structure_tests.rs`.

use std::ffi::{c_char, CString};
use std::ptr;

use image::{Rgba, RgbaImage};
use rasterize_core::doc::RzDocument;
use rasterize_core::doc_group::MAX_GROUP_DEPTH;
use rasterize_core::ffi::rz_image_free;
use rasterize_core::ffi_channel::rz_doc_layer_plane;
use rasterize_core::ffi_doc::*;
use rasterize_core::ffi_group::*;
use rasterize_core::ffi_style::*;
use tempfile::TempDir;

mod common;
use common::*;

const PASS_THROUGH: i32 = 27;

// ---------------------------------------------------------------- helpers --

/// `rz_doc_group_layers` through the FFI, asserting success and freeing the
/// old handle: the new document, the group's index, and the two reports.
fn group_with_reports(
    doc: *mut RzDocument,
    idx: &[usize],
    name: &str,
) -> (*mut RzDocument, usize, Vec<usize>, Vec<usize>) {
    let cname = CString::new(name).expect("no interior NUL");
    let cap = unsafe { rz_doc_layer_count(doc) } + 1;
    let mut group = usize::MAX;
    let mut cleared = vec![0usize; cap];
    let mut cleared_len = 0usize;
    let mut reordered = vec![0usize; cap];
    let mut reordered_len = 0usize;
    let out = unsafe {
        rz_doc_group_layers(
            doc,
            idx.as_ptr(),
            idx.len(),
            cname.as_ptr(),
            &mut group,
            cleared.as_mut_ptr(),
            &mut cleared_len,
            reordered.as_mut_ptr(),
            &mut reordered_len,
            cap,
        )
    };
    assert!(!out.is_null(), "group_layers({idx:?}) refused");
    unsafe { rz_doc_free(doc) };
    cleared.truncate(cleared_len);
    reordered.truncate(reordered_len);
    (out, group, cleared, reordered)
}

/// [`group_with_reports`] when only the group's index matters.
fn group(doc: *mut RzDocument, idx: &[usize], name: &str) -> (*mut RzDocument, usize) {
    let (out, group, _, _) = group_with_reports(doc, idx, name);
    (out, group)
}

fn set_blend(doc: *mut RzDocument, idx: usize, mode: i32) -> *mut RzDocument {
    apply(doc, |d| unsafe {
        rz_doc_with_layer_blend_mode(d, idx, mode)
    })
}

fn set_visible(doc: *mut RzDocument, idx: usize, visible: bool) -> *mut RzDocument {
    apply(doc, |d| unsafe {
        rz_doc_with_layer_visible(d, idx, visible)
    })
}

fn set_clipped(doc: *mut RzDocument, idx: usize, clipped: bool) -> *mut RzDocument {
    apply(doc, |d| unsafe {
        rz_doc_with_layer_clipped(d, idx, clipped)
    })
}

fn set_opacity(doc: *mut RzDocument, idx: usize, opacity: f32) -> *mut RzDocument {
    apply(doc, |d| unsafe {
        rz_doc_with_layer_opacity(d, idx, opacity)
    })
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

fn names(doc: *const RzDocument) -> Vec<String> {
    (0..unsafe { rz_doc_layer_count(doc) })
        .map(|i| layer_name(doc, i))
        .collect()
}

fn bounds(doc: *const RzDocument, idx: usize) -> Option<(i32, i32, i32, i32)> {
    let mut out = [0i32; 4];
    unsafe { rz_doc_layer_bounds(doc, idx, out.as_mut_ptr()) }
        .then_some((out[0], out[1], out[2], out[3]))
}

fn hit(doc: *const RzDocument, x: i32, y: i32, top_level: bool) -> Option<usize> {
    let mut idx = usize::MAX;
    unsafe { rz_doc_layer_at(doc, x, y, top_level, &mut idx) }.then_some(idx)
}

/// A canvas-sized coverage buffer used as a GROUP mask, through
/// `rz_doc_adding_layer_mask`'s FromSelection kind.
fn add_canvas_mask(
    doc: *mut RzDocument,
    idx: usize,
    sel: &[u8],
    w: u32,
    h: u32,
) -> *mut RzDocument {
    apply(doc, |d| unsafe {
        rz_doc_adding_layer_mask(d, idx, MASK_FROM_SELECTION, sel.as_ptr(), w, h)
    })
}

/// The fixture both byte-identity proofs run on: seven entries carrying a
/// clip run, a masked layer, a styled layer, an adjustment layer and five
/// different blend modes, so "identical" means the whole compositing path
/// agrees and not merely the plain kernel.
fn mixed_fixture(dir: &TempDir) -> *mut RzDocument {
    let canvas = (40u32, 32u32);
    let mut doc = doc_from(dir, "bg.png", &opaque_pattern(canvas.0, canvas.1));
    doc = add_layer(
        dir,
        "base1.png",
        doc,
        0,
        &solid(20, 16, [200, 60, 40, 255]),
        "Base1",
    );
    doc = apply(doc, |d| unsafe { rz_doc_with_layer_offset(d, 1, 4, 4) });
    doc = set_blend(doc, 1, BLEND_MULTIPLY);
    doc = add_layer(
        dir,
        "clipa.png",
        doc,
        1,
        &solid(30, 20, [30, 220, 90, 200]),
        "Clip1a",
    );
    doc = apply(doc, |d| unsafe { rz_doc_with_layer_offset(d, 2, 2, 8) });
    doc = set_blend(doc, 2, BLEND_SCREEN);
    doc = set_clipped(doc, 2, true);
    doc = add_layer(
        dir,
        "clipb.png",
        doc,
        2,
        &solid(12, 12, [40, 40, 240, 255]),
        "Clip1b",
    );
    doc = apply(doc, |d| unsafe { rz_doc_with_layer_offset(d, 3, 10, 6) });
    doc = set_blend(doc, 3, BLEND_OVERLAY);
    doc = set_clipped(doc, 3, true);
    doc = add_layer(
        dir,
        "masked.png",
        doc,
        3,
        &solid(24, 24, [250, 240, 60, 255]),
        "Masked",
    );
    doc = apply(doc, |d| unsafe { rz_doc_with_layer_offset(d, 4, 6, 2) });
    doc = set_blend(doc, 4, BLEND_DARKEN);
    let checker = selection(
        canvas.0,
        canvas.1,
        |x, y| if (x + y) % 3 == 0 { 255 } else { 60 },
    );
    doc = add_canvas_mask(doc, 4, &checker, canvas.0, canvas.1);
    doc = add_layer(
        dir,
        "styled.png",
        doc,
        4,
        &solid(10, 10, [90, 90, 220, 255]),
        "Styled",
    );
    doc = apply(doc, |d| unsafe { rz_doc_with_layer_offset(d, 5, 20, 14) });
    doc = with_style(doc, 5, STYLE_JSON);
    doc = add_layer(
        dir,
        "adjust.png",
        doc,
        5,
        &solid(4, 4, [0, 0, 0, 0]),
        "Adjust",
    );
    doc = set_meta(
        doc,
        6,
        &adjust_meta("levels", "{\"black\":0.05,\"white\":0.92,\"gamma\":1.4}"),
    );
    doc = set_blend(doc, 6, BLEND_LIGHTEN);
    doc
}

const PLANE_MASK: i32 = 5;

fn with_style(doc: *mut RzDocument, idx: usize, json: &str) -> *mut RzDocument {
    let c = CString::new(json).expect("no interior NUL");
    let mut err: *mut c_char = ptr::null_mut();
    let out = unsafe { rz_doc_set_layer_style(doc, idx, c.as_ptr(), &mut err) };
    assert!(!out.is_null(), "set_layer_style: {}", take_err_string(err));
    unsafe { rz_doc_free(doc) };
    out
}

// ------------------------------------------- the byte-identity proofs (2.4) --

#[test]
fn wrapping_the_whole_stack_in_a_pass_through_group_changes_nothing() {
    let dir = TempDir::new().unwrap();
    let doc = mixed_fixture(&dir);
    let before = flat_pixels(doc);
    let (doc, group_idx) = group(doc, &[0, 1, 2, 3, 4, 5, 6], "All");
    assert_eq!(unsafe { rz_doc_layer_count(doc) }, 8);
    assert_eq!(group_idx, 7);
    assert!(unsafe { rz_doc_layer_is_group(doc, 7) });
    assert_eq!(
        unsafe { rz_doc_layer_blend_mode(doc, 7) },
        PASS_THROUGH,
        "a new group is Pass Through"
    );
    assert_eq!(depths(doc), vec![1, 1, 1, 1, 1, 1, 1, 0]);
    let after = flat_pixels(doc);
    assert_eq!(
        before, after,
        "wrapping the WHOLE stack in one pass-through group must change nothing"
    );
    unsafe { rz_doc_free(doc) };
}

#[test]
fn wrapping_each_clip_run_in_a_pass_through_group_changes_nothing() {
    // A whole CLIP RUN is the atom, not one entry: clipping is re-derived
    // WITHIN a level, so wrapping a clipped entry away from its base would
    // make it the bottom of its new level, which composites as if UNCLIPPED —
    // a different picture. Wrapping the base away from its members breaks the
    // same run from the other side. Splitting the assertion this way is what
    // keeps clipping in the fixture, which is exactly the case byte-identity
    // most needs to cover.
    let dir = TempDir::new().unwrap();
    let mut doc = mixed_fixture(&dir);
    let before = flat_pixels(doc);
    // Top-down, so the indices below each wrap stay where they are.
    for (run, name) in [
        (vec![6usize], "R6"),
        (vec![5], "R5"),
        (vec![4], "R4"),
        (vec![1, 2, 3], "R123"),
        (vec![0], "R0"),
    ] {
        let (next, _) = group(doc, &run, name);
        doc = next;
    }
    assert_eq!(unsafe { rz_doc_layer_count(doc) }, 12);
    let after = flat_pixels(doc);
    assert_eq!(
        before, after,
        "wrapping every clip run in its own pass-through group must change nothing"
    );
    unsafe { rz_doc_free(doc) };
}

#[test]
fn an_isolated_group_of_one_opaque_layer_is_that_layer() {
    // The straight-alpha round trip through the quantizer is exact at opacity
    // 1 over a transparent backdrop, so an isolated Normal group of one opaque
    // layer must land the same bytes the layer lands.
    let dir = TempDir::new().unwrap();
    let mut doc = doc_from(&dir, "bg.png", &opaque_pattern(30, 24));
    doc = add_layer(
        &dir,
        "rect.png",
        doc,
        0,
        &solid(10, 8, [220, 30, 90, 255]),
        "Rect",
    );
    doc = apply(doc, |d| unsafe { rz_doc_with_layer_offset(d, 1, 7, 6) });
    let before = flat_pixels(doc);
    let (doc, group_idx) = group(doc, &[1], "G");
    let doc = set_blend(doc, group_idx, BLEND_NORMAL);
    let after = flat_pixels(doc);
    assert_eq!(
        before, after,
        "an isolated group of one opaque layer IS that layer"
    );
    unsafe { rz_doc_free(doc) };
}

#[test]
fn an_adjustment_in_a_pass_through_group_still_reaches_the_backdrop() {
    let dir = TempDir::new().unwrap();
    let mut doc = doc_from(&dir, "bg.png", &solid(8, 8, [100, 100, 100, 255]));
    doc = add_layer(
        &dir,
        "adj.png",
        doc,
        0,
        &solid(2, 2, [0, 0, 0, 0]),
        "Adjust",
    );
    doc = set_meta(doc, 1, &adjust_meta("invert", "{}"));
    let flat = flat_pixels(doc);
    assert_eq!(pixel(&flat, 8, 3, 3), [155, 155, 155, 255]);
    let (doc, _) = group(doc, &[1], "G");
    let grouped = flat_pixels(doc);
    assert_eq!(
        grouped, flat,
        "a pass-through group lets its adjustment layer reach the backdrop below the group"
    );
    unsafe { rz_doc_free(doc) };
}

#[test]
fn an_adjustment_in_an_isolated_group_does_not_reach_the_backdrop() {
    // The other half of the rule, and the already-documented consequence of
    // the transparent-buffer skip: inside an ISOLATED group the adjustment's
    // backdrop is the group's own private buffer, which starts empty.
    let dir = TempDir::new().unwrap();
    let mut doc = doc_from(&dir, "bg.png", &solid(8, 8, [100, 100, 100, 255]));
    doc = add_layer(
        &dir,
        "adj.png",
        doc,
        0,
        &solid(2, 2, [0, 0, 0, 0]),
        "Adjust",
    );
    doc = set_meta(doc, 1, &adjust_meta("invert", "{}"));
    let (doc, group_idx) = group(doc, &[1], "G");
    let doc = set_blend(doc, group_idx, BLEND_NORMAL);
    let flat = flat_pixels(doc);
    assert_eq!(
        pixel(&flat, 8, 3, 3),
        [100, 100, 100, 255],
        "an isolated group's adjustment sees only the group's own buffer"
    );
    unsafe { rz_doc_free(doc) };
}

/// A Pass Through group holding one Invert adjustment over an opaque grey
/// backdrop: the fixture all three gate tests below share.
fn adjustment_in_a_pass_through_group(dir: &TempDir) -> (*mut RzDocument, usize) {
    let mut doc = doc_from(dir, "bg.png", &solid(8, 8, [100, 100, 100, 255]));
    doc = add_layer(dir, "adj.png", doc, 0, &solid(2, 2, [0, 0, 0, 0]), "Adjust");
    doc = set_meta(doc, 1, &adjust_meta("invert", "{}"));
    group(doc, &[1], "G")
}

#[test]
fn a_reveal_all_mask_on_a_pass_through_group_changes_nothing() {
    // The workflow this exists for: "group the adjustment layers and mask the
    // group". An all-white mask is a semantic no-op, so it must be a
    // BYTE-IDENTICAL one — isolating for the mask instead would composite the
    // adjustment against a fresh transparent buffer, where the documented
    // `bg[3] <= 0.0` skip makes it contribute nothing at all.
    let dir = TempDir::new().unwrap();
    let (doc, group_idx) = adjustment_in_a_pass_through_group(&dir);
    let before = flat_pixels(doc);
    assert_eq!(pixel(&before, 8, 3, 3), [155, 155, 155, 255], "inverted");
    let doc = apply(doc, |d| unsafe {
        rz_doc_adding_layer_mask(d, group_idx, MASK_REVEAL_ALL, ptr::null(), 0, 0)
    });
    assert!(unsafe { rz_doc_layer_has_mask(doc, group_idx) });
    assert_eq!(
        flat_pixels(doc),
        before,
        "an all-white mask on a Pass Through group is a no-op, not an off switch"
    );
    unsafe { rz_doc_free(doc) };
}

#[test]
fn a_pass_through_group_mask_restricts_its_adjustment_per_pixel() {
    // The other half: the mask CONFINES the adjustment to where it is white,
    // and leaves the backdrop exactly as it was everywhere else.
    let dir = TempDir::new().unwrap();
    let (doc, group_idx) = adjustment_in_a_pass_through_group(&dir);
    let sel = selection(8, 8, |x, _| if x < 4 { 255 } else { 0 });
    let doc = add_canvas_mask(doc, group_idx, &sel, 8, 8);
    let flat = flat_pixels(doc);
    assert_eq!(
        pixel(&flat, 8, 1, 3),
        [155, 155, 155, 255],
        "the revealed half is adjusted"
    );
    assert_eq!(
        pixel(&flat, 8, 5, 3),
        [100, 100, 100, 255],
        "the hidden half keeps the untouched backdrop"
    );
    unsafe { rz_doc_free(doc) };
}

#[test]
fn a_pass_through_group_opacity_scales_its_adjustment() {
    // Oracle, computed independently of the compositor: the backdrop is
    // 100/255, Invert answers 1 - that, and the group's opacity lerps between
    // them, so a quarter-strength group lands at
    // round(255 * (100/255 + (155/255 - 100/255) * 0.25)) = round(113.75) = 114.
    let dir = TempDir::new().unwrap();
    let (doc, group_idx) = adjustment_in_a_pass_through_group(&dir);
    let doc = set_opacity(doc, group_idx, 0.25);
    let flat = flat_pixels(doc);
    assert_eq!(
        pixel(&flat, 8, 3, 3),
        [114, 114, 114, 255],
        "a quarter-opacity Pass Through group applies a quarter of its adjustment"
    );
    unsafe { rz_doc_free(doc) };
}

#[test]
fn a_gated_pass_through_group_fades_colour_the_way_an_isolated_one_does() {
    // The gate mixes in PREMULTIPLIED colour. Over a TRANSPARENT backdrop an
    // opaque red child in a half-opacity group must come out RED at alpha 128,
    // never half-dark red: a straight-alpha mix would fold the backdrop's
    // meaningless black in as if it were a colour. The oracle is the same
    // group ISOLATED at the same opacity, which composites through the
    // untouched `composite_layer_into` and is what a group's opacity has
    // always meant.
    let dir = TempDir::new().unwrap();
    let mut doc = doc_from(&dir, "bg.png", &solid(8, 8, [0, 0, 0, 0]));
    doc = add_layer(&dir, "a.png", doc, 0, &solid(8, 8, [255, 0, 0, 255]), "A");
    let (doc, group_idx) = group(doc, &[1], "G");
    let doc = set_opacity(doc, group_idx, 0.5);
    let gated = flat_pixels(doc);
    assert_eq!(
        pixel(&gated, 8, 4, 4),
        [255, 0, 0, 128],
        "red at half coverage, not half-dark red"
    );
    let isolated = flat_pixels(set_blend(doc, group_idx, BLEND_NORMAL));
    assert_eq!(
        gated, isolated,
        "over a transparent backdrop a gated pass-through group and the same \
         group isolated give the same picture"
    );
}

#[test]
fn a_blend_mode_still_isolates_a_group_that_also_carries_a_mask() {
    // Mask and opacity moved out of `is_isolated`; the other four terms did
    // not. A masked group whose blend mode is Normal is still ISOLATED, so its
    // adjustment sees the group's own transparent buffer and reaches nothing.
    let dir = TempDir::new().unwrap();
    let (doc, group_idx) = adjustment_in_a_pass_through_group(&dir);
    let sel = selection(8, 8, |_, _| 255u8);
    let doc = add_canvas_mask(doc, group_idx, &sel, 8, 8);
    let doc = set_blend(doc, group_idx, BLEND_NORMAL);
    let flat = flat_pixels(doc);
    assert_eq!(
        pixel(&flat, 8, 3, 3),
        [100, 100, 100, 255],
        "a blend mode isolates, and an isolated group's adjustment sees only its own buffer"
    );
    unsafe { rz_doc_free(doc) };
}

#[test]
fn an_adjustment_clip_base_under_invisible_clipped_layers_is_unchanged() {
    // On a document with NO groups: resolution keeps every clip-run member
    // positionally, visible or not, so `group.is_empty()` keeps exactly its
    // old meaning — a non-empty clip group over an adjustment base contributes
    // nothing. Dropping invisible members would flip this to "the adjustment
    // applies to the whole backdrop".
    let dir = TempDir::new().unwrap();
    let mut doc = doc_from(&dir, "bg.png", &solid(8, 8, [100, 100, 100, 255]));
    doc = add_layer(
        &dir,
        "adj.png",
        doc,
        0,
        &solid(8, 8, [0, 0, 0, 0]),
        "Adjust",
    );
    doc = set_meta(doc, 1, &adjust_meta("invert", "{}"));
    doc = add_layer(
        &dir,
        "clip.png",
        doc,
        1,
        &solid(8, 8, [10, 20, 30, 255]),
        "Clipped",
    );
    doc = set_clipped(doc, 2, true);
    doc = set_visible(doc, 2, false);
    let flat = flat_pixels(doc);
    assert_eq!(
        pixel(&flat, 8, 3, 3),
        [100, 100, 100, 255],
        "an adjustment clip base with a non-empty clip group contributes nothing"
    );
    // Removing the invisible member makes the group empty and the adjustment
    // applies again — which is what proves the first assertion is about the
    // member being KEPT and not about visibility.
    let bare = apply(doc, |d| unsafe { rz_doc_removing_layer(d, 2) });
    let flat = flat_pixels(bare);
    assert_eq!(pixel(&flat, 8, 3, 3), [155, 155, 155, 255]);
    unsafe { rz_doc_free(bare) };
}

#[test]
fn clipping_over_a_pass_through_group_isolates_it() {
    // The published cost of counting a VISIBLE clipped member as isolation:
    // clipping an unrelated sibling to a pass-through group turns off an
    // adjustment layer inside it. Pinned so it cannot regress into an
    // accident.
    let dir = TempDir::new().unwrap();
    let mut doc = doc_from(&dir, "photo.png", &solid(8, 8, [100, 100, 100, 255]));
    doc = add_layer(
        &dir,
        "adj.png",
        doc,
        0,
        &solid(2, 2, [0, 0, 0, 0]),
        "Curves",
    );
    doc = set_meta(doc, 1, &adjust_meta("invert", "{}"));
    let (doc, group_idx) = group(doc, &[1], "G");
    assert_eq!(group_idx, 2);
    let mut doc = add_layer(
        &dir,
        "tex.png",
        doc,
        group_idx,
        &solid(4, 4, [0, 0, 0, 0]),
        "Texture",
    );
    // Unclipped: the group stays pass-through and the adjustment reaches the
    // photo below it.
    let open = flat_pixels(doc);
    assert_eq!(pixel(&open, 8, 6, 6), [155, 155, 155, 255]);
    doc = set_clipped(doc, 3, true);
    let clipped = flat_pixels(doc);
    assert_eq!(
        pixel(&clipped, 8, 6, 6),
        [100, 100, 100, 255],
        "clipping a layer to a pass-through group makes it composite as a unit, \
         so the adjustment inside stops reaching the layers below"
    );
    // An INVISIBLE clipped member does not isolate it.
    doc = set_visible(doc, 3, false);
    let hidden = flat_pixels(doc);
    assert_eq!(
        hidden, open,
        "an invisible clipped sibling never isolates a group"
    );
    unsafe { rz_doc_free(doc) };
}

// ---------------------------------------------- the group's own properties --

#[test]
fn group_opacity_and_blend_mode_apply_to_the_whole_group() {
    let dir = TempDir::new().unwrap();
    let mut doc = doc_from(&dir, "bg.png", &solid(8, 8, [0, 0, 0, 255]));
    doc = add_layer(
        &dir,
        "a.png",
        doc,
        0,
        &solid(8, 8, [200, 200, 200, 255]),
        "A",
    );
    doc = add_layer(&dir, "b.png", doc, 1, &solid(4, 4, [40, 40, 40, 255]), "B");
    let (doc, group_idx) = group(doc, &[1, 2], "G");
    // Isolated at half opacity: the group's own projection (B over A) fades
    // uniformly toward the black backdrop, so the two halves of the group
    // fade by the SAME rule rather than each layer fading on its own.
    let doc = set_blend(doc, group_idx, BLEND_NORMAL);
    let doc = set_opacity(doc, group_idx, 0.5);
    let flat = flat_pixels(doc);
    assert_eq!(
        pixel(&flat, 8, 6, 6),
        [100, 100, 100, 255],
        "A at 50% over black"
    );
    assert_eq!(
        pixel(&flat, 8, 1, 1),
        [20, 20, 20, 255],
        "B at 50% over black"
    );
    unsafe { rz_doc_free(doc) };
}

#[test]
fn a_group_mask_is_canvas_sized_and_gates_the_group() {
    let dir = TempDir::new().unwrap();
    let canvas = (8u32, 8u32);
    let mut doc = doc_from(&dir, "bg.png", &solid(canvas.0, canvas.1, [0, 0, 0, 255]));
    doc = add_layer(
        &dir,
        "a.png",
        doc,
        0,
        &solid(4, 4, [255, 255, 255, 255]),
        "A",
    );
    doc = apply(doc, |d| unsafe { rz_doc_with_layer_offset(d, 1, 2, 2) });
    let (doc, group_idx) = group(doc, &[1], "G");
    let sel = selection(canvas.0, canvas.1, |x, _| if x < 4 { 255 } else { 0 });
    let doc = add_canvas_mask(doc, group_idx, &sel, canvas.0, canvas.1);
    assert!(unsafe { rz_doc_layer_has_mask(doc, group_idx) });
    let mut plane = vec![0u8; (canvas.0 * canvas.1) as usize];
    assert!(
        unsafe {
            rz_doc_layer_plane(
                doc,
                group_idx,
                PLANE_MASK,
                plane.as_mut_ptr(),
                canvas.0,
                canvas.1,
            )
        },
        "a group's mask plane is canvas-sized"
    );
    assert_eq!(
        plane, sel,
        "the group mask is stored at the CANVAS size, verbatim"
    );
    // The mask also makes the group isolated, and it gates its projection.
    let flat = flat_pixels(doc);
    assert_eq!(pixel(&flat, 8, 3, 3), [255, 255, 255, 255], "revealed half");
    assert_eq!(pixel(&flat, 8, 4, 3), [0, 0, 0, 255], "hidden half");
    // Applying a group mask has nothing to bake into and is refused.
    assert!(unsafe { rz_doc_removing_layer_mask(doc, group_idx, true) }.is_null());
    let dropped = apply(doc, |d| unsafe {
        rz_doc_removing_layer_mask(d, group_idx, false)
    });
    assert!(!unsafe { rz_doc_layer_has_mask(dropped, group_idx) });
    unsafe { rz_doc_free(dropped) };
}

#[test]
fn a_group_carries_a_layer_style() {
    // The style's shape is the group's own rendered projection, so a stroke
    // around a group of two disjoint rects hugs BOTH of them.
    let dir = TempDir::new().unwrap();
    let mut doc = doc_from(&dir, "bg.png", &solid(30, 20, [255, 255, 255, 255]));
    doc = add_layer(&dir, "a.png", doc, 0, &solid(4, 4, [0, 0, 0, 255]), "A");
    doc = apply(doc, |d| unsafe { rz_doc_with_layer_offset(d, 1, 5, 8) });
    doc = add_layer(&dir, "b.png", doc, 1, &solid(4, 4, [0, 0, 0, 255]), "B");
    doc = apply(doc, |d| unsafe { rz_doc_with_layer_offset(d, 2, 20, 8) });
    let (doc, group_idx) = group(doc, &[1, 2], "G");
    let plain = flat_pixels(doc);
    let doc = with_style(
        doc,
        group_idx,
        "{\"effects\":[{\"type\":\"stroke\",\"size\":2,\"color\":\"#FF0000\",\"position\":\"outside\"}]}",
    );
    assert!(unsafe { rz_doc_layer_has_style(doc, group_idx) });
    let styled = flat_pixels(doc);
    assert_ne!(styled, plain, "a group's style renders");
    for (x, y) in [(4u32, 9u32), (19, 9)] {
        assert_eq!(
            pixel(&styled, 30, x, y),
            [255, 0, 0, 255],
            "the stroke hugs BOTH rects, so the shape is the group's projection"
        );
    }
    unsafe { rz_doc_free(doc) };
}

#[test]
fn a_group_can_be_a_clip_base_and_a_clipped_member() {
    let dir = TempDir::new().unwrap();
    let mut doc = doc_from(&dir, "bg.png", &solid(10, 10, [0, 0, 0, 255]));
    doc = add_layer(
        &dir,
        "base.png",
        doc,
        0,
        &solid(4, 4, [255, 255, 255, 255]),
        "Base",
    );
    doc = apply(doc, |d| unsafe { rz_doc_with_layer_offset(d, 1, 1, 1) });
    doc = add_layer(
        &dir,
        "paint.png",
        doc,
        1,
        &solid(10, 10, [255, 0, 0, 255]),
        "Paint",
    );
    // Group the painted layer and clip the GROUP to the base below it.
    let (doc, group_idx) = group(doc, &[2], "G");
    let doc = set_clipped(doc, group_idx, true);
    let flat = flat_pixels(doc);
    assert_eq!(
        pixel(&flat, 10, 2, 2),
        [255, 0, 0, 255],
        "inside the base's footprint"
    );
    assert_eq!(
        pixel(&flat, 10, 8, 8),
        [0, 0, 0, 255],
        "outside it the clip holds"
    );
    unsafe { rz_doc_free(doc) };
}

#[test]
fn a_clipped_entry_at_the_bottom_of_a_level_composites_unclipped() {
    let dir = TempDir::new().unwrap();
    let mut doc = doc_from(&dir, "bg.png", &solid(8, 8, [0, 0, 0, 255]));
    doc = add_layer(&dir, "a.png", doc, 0, &solid(8, 8, [255, 0, 0, 255]), "A");
    doc = set_clipped(doc, 1, true);
    // Inside a group A is the bottom of its level: no unclipped sibling below
    // it there, so it is baseless and composites as if unclipped.
    let (doc, _) = group(doc, &[1], "G");
    let flat = flat_pixels(doc);
    assert_eq!(pixel(&flat, 8, 4, 4), [255, 0, 0, 255]);
    unsafe { rz_doc_free(doc) };
}

#[test]
fn a_clipped_group_at_the_bottom_of_a_level_still_passes_through() {
    // The group twin of the case above, and the boundary of
    // `clipping_over_a_pass_through_group_isolates_it`: a clip flag the
    // compositor has already decided to IGNORE — because the entry is the
    // bottom-most of its level and so has no base — must not force isolation
    // either, or setting a no-op clipping mask would silently switch off an
    // adjustment layer inside a pass-through group.
    let dir = TempDir::new().unwrap();
    let mut doc = doc_from(&dir, "bg.png", &opaque_pattern(8, 8));
    doc = add_layer(
        &dir,
        "adj.png",
        doc,
        0,
        &solid(2, 2, [0, 0, 0, 0]),
        "Invert",
    );
    doc = set_meta(doc, 1, &adjust_meta("invert", "{}"));
    let (doc, inner) = group(doc, &[1], "Ginner");
    let doc = add_layer(
        &dir,
        "sib.png",
        doc,
        inner,
        &solid(8, 8, [0, 0, 0, 0]),
        "Sib",
    );
    // [bg(d0), Invert(d2), Ginner(d1), Sib(d1), Gouter(d0)] — Ginner is the
    // bottom-most child of Gouter, so it is baseless.
    let (doc, outer) = group(doc, &[inner, inner + 1], "Gouter");
    assert_eq!((depths(doc), outer), (vec![0, 2, 1, 1, 0], 4));
    let backdrop = {
        let plain = doc_from(&dir, "plain.png", &opaque_pattern(8, 8));
        let px = flat_pixels(plain);
        unsafe { rz_doc_free(plain) };
        px
    };
    let before = flat_pixels(doc);
    assert_ne!(
        before, backdrop,
        "the invert reaches the backdrop through both pass-through groups"
    );
    let doc = set_clipped(doc, inner, true);
    assert_eq!(
        flat_pixels(doc),
        before,
        "a clipped group with no base composites as if unclipped, isolation included"
    );
    unsafe { rz_doc_free(doc) };

    // The contrast, so the rule stays a rule and not an accident: give the
    // same group a base BELOW it in its level and the clip really does
    // isolate it, which is what turns the adjustment off.
    let mut doc = doc_from(&dir, "bg2.png", &opaque_pattern(8, 8));
    doc = add_layer(
        &dir,
        "sib2.png",
        doc,
        0,
        &solid(8, 8, [90, 90, 90, 255]),
        "Sib",
    );
    doc = add_layer(
        &dir,
        "adj2.png",
        doc,
        1,
        &solid(2, 2, [0, 0, 0, 0]),
        "Invert",
    );
    doc = set_meta(doc, 2, &adjust_meta("invert", "{}"));
    let (doc, inner) = group(doc, &[2], "Ginner");
    let (doc, _) = group(doc, &[1, inner], "Gouter");
    // [bg(d0), Sib(d1), Invert(d2), Ginner(d1), Gouter(d0)] — Ginner now sits
    // above an unclipped sibling of its own level.
    assert_eq!(depths(doc), vec![0, 1, 2, 1, 0]);
    assert_eq!(pixel(&flat_pixels(doc), 8, 4, 4), [165, 165, 165, 255]);
    let doc = set_clipped(doc, 3, true);
    assert_eq!(
        pixel(&flat_pixels(doc), 8, 4, 4),
        [90, 90, 90, 255],
        "a clipped group that HAS a base isolates, so the adjustment inside it \
         composites over nothing"
    );
    unsafe { rz_doc_free(doc) };
}

#[test]
fn nested_groups_composite_and_the_depth_cap_refuses() {
    let dir = TempDir::new().unwrap();
    let mut doc = doc_from(&dir, "bg.png", &solid(8, 8, [0, 0, 0, 255]));
    doc = add_layer(
        &dir,
        "a.png",
        doc,
        0,
        &solid(8, 8, [10, 120, 240, 255]),
        "A",
    );
    let expected = flat_pixels(doc);
    // MAX_GROUP_DEPTH nested pass-through groups, each wrapping the previous:
    // the leaf ends at the cap and the picture is unchanged.
    for level in 0..MAX_GROUP_DEPTH {
        let (next, _) = group(doc, &[1], &format!("G{level}"));
        doc = next;
    }
    assert_eq!(
        unsafe { rz_doc_layer_depth(doc, 1) },
        u32::from(MAX_GROUP_DEPTH)
    );
    assert_eq!(
        flat_pixels(doc),
        expected,
        "pass-through nesting changes nothing"
    );
    // One more level would push the leaf past the cap.
    let idx = [1usize];
    let cname = CString::new("too deep").unwrap();
    let mut group_out = 0usize;
    assert!(
        unsafe {
            rz_doc_group_layers(
                doc,
                idx.as_ptr(),
                1,
                cname.as_ptr(),
                &mut group_out,
                ptr::null_mut(),
                ptr::null_mut(),
                ptr::null_mut(),
                ptr::null_mut(),
                0,
            )
        }
        .is_null(),
        "nesting past the depth cap is refused"
    );
    unsafe { rz_doc_free(doc) };
}

#[test]
fn an_empty_group_composites_to_nothing_and_is_legal() {
    let dir = TempDir::new().unwrap();
    let mut doc = doc_from(&dir, "bg.png", &solid(8, 8, [20, 30, 40, 255]));
    doc = add_layer(&dir, "a.png", doc, 0, &solid(8, 8, [0, 0, 0, 0]), "A");
    let (doc, group_idx) = group(doc, &[1], "G");
    // Removing the group's only child leaves an empty group, which is legal
    // and contributes nothing at any blend mode or opacity.
    let doc = apply(doc, |d| unsafe { rz_doc_removing_layer(d, group_idx - 1) });
    assert_eq!(unsafe { rz_doc_layer_count(doc) }, 2);
    assert!(unsafe { rz_doc_layer_is_group(doc, 1) });
    let doc = set_blend(doc, 1, BLEND_MULTIPLY);
    let flat = flat_pixels(doc);
    assert_eq!(pixel(&flat, 8, 4, 4), [20, 30, 40, 255]);
    assert_eq!(bounds(doc, 1), None, "an empty group has no content bounds");
    unsafe { rz_doc_free(doc) };
}

#[test]
fn pass_through_is_refused_on_a_raster_layer() {
    let dir = TempDir::new().unwrap();
    let doc = doc_from(&dir, "bg.png", &solid(4, 4, RED));
    assert!(
        unsafe { rz_doc_with_layer_blend_mode(doc, 0, PASS_THROUGH) }.is_null(),
        "Pass Through is a group's declaration, not a layer blend mode"
    );
    let (doc, group_idx) = group(doc, &[0], "G");
    // A new group is created in Pass Through, so asking for it again is the
    // purity rule's no-op; asking for it back after a real mode is not.
    assert!(
        unsafe { rz_doc_with_layer_blend_mode(doc, group_idx, PASS_THROUGH) }.is_null(),
        "the group already composites as Pass Through"
    );
    let doc = set_blend(doc, group_idx, BLEND_MULTIPLY);
    assert!(!unsafe { rz_doc_with_layer_blend_mode(doc, group_idx, PASS_THROUGH) }.is_null());
    unsafe { rz_doc_free(doc) };
}

// ------------------------------------------------- readers on a group entry --

#[test]
fn group_readers_answer_the_projection_and_the_content_box() {
    let dir = TempDir::new().unwrap();
    let mut doc = doc_from(&dir, "bg.png", &solid(20, 16, [0, 0, 0, 255]));
    doc = add_layer(
        &dir,
        "a.png",
        doc,
        0,
        &solid(4, 4, [255, 255, 255, 255]),
        "A",
    );
    doc = apply(doc, |d| unsafe { rz_doc_with_layer_offset(d, 1, 3, 5) });
    let (doc, group_idx) = group(doc, &[1], "G");
    // No pixels of its own.
    assert!(unsafe { rz_doc_layer_image(doc, group_idx) }.is_null());
    // The raw projection, canvas-sized.
    let canvas = unsafe { rz_doc_layer_canvas_image(doc, group_idx) };
    assert!(!canvas.is_null());
    assert_eq!(img_dims(canvas), (20, 16));
    let px = img_pixels(canvas);
    assert_eq!(pixel(&px, 20, 4, 6), [255, 255, 255, 255]);
    assert_eq!(
        pixel(&px, 20, 0, 0),
        [0, 0, 0, 0],
        "raw: nothing outside the children"
    );
    unsafe { rz_image_free(canvas) };
    // A thumbnail of that projection.
    let thumb = unsafe { rz_doc_layer_thumbnail(doc, group_idx, 10) };
    assert!(!thumb.is_null());
    assert_eq!(img_dims(thumb), (10, 8));
    unsafe { rz_image_free(thumb) };
    // The geometry getters answer the CONTENT box, since a group has no
    // pixel rect.
    assert_eq!(bounds(doc, group_idx), Some((3, 5, 4, 4)));
    assert_eq!(layer_offset(doc, group_idx), (3, 5));
    assert_eq!(layer_dims(doc, group_idx), (4, 4));
    // ...while a raster entry's four values stay its pixel rect.
    assert_eq!(layer_offset(doc, 0), (0, 0));
    assert_eq!(layer_dims(doc, 0), (20, 16));
    // And a group is never an adjustment layer, whatever its meta says.
    let doc = set_meta(doc, group_idx, &adjust_meta("invert", "{}"));
    assert!(!unsafe { rz_doc_layer_is_adjustment(doc, group_idx) });
    let flat = flat_pixels(doc);
    assert_eq!(
        pixel(&flat, 20, 0, 0),
        [0, 0, 0, 255],
        "a group's meta is never interpreted as an adjustment"
    );
    unsafe { rz_doc_free(doc) };
}

#[test]
fn layer_bounds_is_the_content_box_not_the_pixel_rect() {
    let dir = TempDir::new().unwrap();
    let mut doc = doc_from(&dir, "bg.png", &solid(20, 20, [0, 0, 0, 0]));
    // A canvas-sized buffer with content only in the middle — the shape every
    // paste, text layer and shape layer produces.
    let mut sparse = RgbaImage::new(20, 20);
    for y in 6..10 {
        for x in 4..12 {
            sparse.put_pixel(x, y, Rgba([255, 0, 0, 255]));
        }
    }
    doc = add_layer(&dir, "sparse.png", doc, 0, &sparse, "Sparse");
    assert_eq!(
        layer_dims(doc, 1),
        (20, 20),
        "the PIXEL rect is the whole canvas"
    );
    assert_eq!(
        bounds(doc, 1),
        Some((4, 6, 8, 4)),
        "the CONTENT box is the opaque part"
    );
    // A fully transparent entry has no content box at all.
    assert_eq!(bounds(doc, 0), None);
    // A group's box is the union over its descendants.
    doc = add_layer(
        &dir,
        "far.png",
        doc,
        1,
        &solid(2, 2, [0, 255, 0, 255]),
        "Far",
    );
    doc = apply(doc, |d| unsafe { rz_doc_with_layer_offset(d, 2, 15, 15) });
    let (doc, group_idx) = group(doc, &[1, 2], "G");
    assert_eq!(bounds(doc, group_idx), Some((4, 6, 13, 11)));
    unsafe { rz_doc_free(doc) };
}

#[test]
fn layer_at_finds_the_topmost_covered_entry() {
    let dir = TempDir::new().unwrap();
    let mut doc = doc_from(&dir, "bg.png", &solid(16, 16, [0, 0, 0, 255]));
    doc = add_layer(
        &dir,
        "half.png",
        doc,
        0,
        &solid(4, 4, [255, 0, 0, 127]),
        "Half",
    );
    doc = apply(doc, |d| unsafe { rz_doc_with_layer_offset(d, 1, 2, 2) });
    doc = add_layer(
        &dir,
        "over.png",
        doc,
        1,
        &solid(4, 4, [255, 0, 0, 128]),
        "Over",
    );
    doc = apply(doc, |d| unsafe { rz_doc_with_layer_offset(d, 2, 8, 8) });
    // The contour is >= 128: alpha 127 misses, alpha 128 hits.
    assert_eq!(
        hit(doc, 3, 3, false),
        Some(0),
        "alpha 127 is below the contour"
    );
    assert_eq!(hit(doc, 9, 9, false), Some(2));
    // An invisible entry is skipped...
    let hidden = set_visible(doc, 2, false);
    assert_eq!(hit(hidden, 9, 9, false), Some(0));
    // ...and so is an adjustment layer.
    let adj = set_meta(hidden, 2, &adjust_meta("invert", "{}"));
    let adj = set_visible(adj, 2, true);
    assert_eq!(hit(adj, 9, 9, false), Some(0));
    // Nothing at all when no entry covers the point.
    let empty = apply(adj, |d| unsafe { rz_doc_with_layer_visible(d, 0, false) });
    assert_eq!(hit(empty, 1, 1, false), None);
    // With top_level the answer is the hit entry's top-level ancestor.
    let shown = apply(empty, |d| unsafe { rz_doc_with_layer_visible(d, 0, true) });
    let (grouped, group_idx) = group(shown, &[1], "G");
    assert_eq!(hit(grouped, 3, 3, false), Some(0));
    let (grouped, outer) = group(grouped, &[group_idx], "Outer");
    let mut doc = add_layer(
        &dir,
        "solid.png",
        grouped,
        0,
        &solid(4, 4, [0, 0, 255, 255]),
        "Solid",
    );
    doc = apply(doc, |d| unsafe { rz_doc_with_layer_offset(d, 1, 12, 12) });
    assert_eq!(hit(doc, 13, 13, false), Some(1), "the leaf itself");
    assert_eq!(hit(doc, 13, 13, true), Some(1), "already top level");
    let _ = outer;
    unsafe { rz_doc_free(doc) };
}

// ------------------------------------------ the group mask under geometry --

/// The group-mask ride-along, against a hand-computed oracle: a group mask is
/// CANVAS space, so it must be carried the way a channel is (cut down, padded,
/// resampled to the new canvas) and never the way a layer mask is (resampled
/// to the layer's own new size — which for a group's 1x1 dummy would destroy
/// it).
#[test]
fn the_geometry_ops_carry_a_group_mask() {
    let dir = TempDir::new().unwrap();
    let canvas = (8u32, 6u32);
    let mut doc = doc_from(&dir, "bg.png", &solid(canvas.0, canvas.1, [0, 0, 0, 255]));
    doc = add_layer(
        &dir,
        "a.png",
        doc,
        0,
        &solid(4, 4, [255, 255, 255, 255]),
        "A",
    );
    let (doc, group_idx) = group(doc, &[1], "G");
    // A mask whose value encodes its canvas position, so any misplacement
    // shows up as a wrong byte rather than a plausible one.
    let sel = selection(canvas.0, canvas.1, |x, y| (x * 16 + y * 2) as u8);
    let doc = add_canvas_mask(doc, group_idx, &sel, canvas.0, canvas.1);

    let read = |d: *const RzDocument, w: u32, h: u32| -> Vec<u8> {
        let mut plane = vec![0u8; (w * h) as usize];
        assert!(
            unsafe { rz_doc_layer_plane(d, 2, PLANE_MASK, plane.as_mut_ptr(), w, h) },
            "the group mask must survive as a canvas plane"
        );
        plane
    };

    // Rotate 180: the canvas mask permutes with the canvas.
    let rotated = apply(unsafe { rz_doc_clone(doc) }, |d| unsafe {
        rz_doc_rotate180(d)
    });
    let expected: Vec<u8> = (0..canvas.1)
        .flat_map(|y| {
            (0..canvas.0).map(move |x| {
                let (sx, sy) = (canvas.0 - 1 - x, canvas.1 - 1 - y);
                (sx * 16 + sy * 2) as u8
            })
        })
        .collect();
    assert_eq!(read(rotated, canvas.0, canvas.1), expected, "rotate180");
    unsafe { rz_doc_free(rotated) };

    // Flip horizontally.
    let flipped = apply(unsafe { rz_doc_clone(doc) }, |d| unsafe {
        rz_doc_flip_horizontal(d)
    });
    let expected: Vec<u8> = (0..canvas.1)
        .flat_map(|y| (0..canvas.0).map(move |x| ((canvas.0 - 1 - x) * 16 + y * 2) as u8))
        .collect();
    assert_eq!(
        read(flipped, canvas.0, canvas.1),
        expected,
        "flip_horizontal"
    );
    unsafe { rz_doc_free(flipped) };

    // Crop: genuinely cut down to the window, like a channel.
    let cropped = apply(unsafe { rz_doc_clone(doc) }, |d| unsafe {
        rz_doc_crop(d, 2, 1, 4, 4)
    });
    let expected: Vec<u8> = (0..4)
        .flat_map(|y| (0..4).map(move |x| ((x + 2) * 16 + (y + 1) * 2) as u8))
        .collect();
    assert_eq!(read(cropped, 4, 4), expected, "crop");
    unsafe { rz_doc_free(cropped) };

    // Canvas resize: padded into the new canvas at the origin, 0 outside.
    let padded = apply(unsafe { rz_doc_clone(doc) }, |d| unsafe {
        rz_doc_canvas_resize(d, 10, 8, 1, 1)
    });
    let expected: Vec<u8> = (0..8u32)
        .flat_map(|y| {
            (0..10u32).map(move |x| {
                if (1..1 + canvas.0).contains(&x) && (1..1 + canvas.1).contains(&y) {
                    ((x - 1) * 16 + (y - 1) * 2) as u8
                } else {
                    0
                }
            })
        })
        .collect();
    assert_eq!(read(padded, 10, 8), expected, "canvas_resize");
    unsafe { rz_doc_free(padded) };

    // Resize: resampled to the NEW CANVAS, not to the 1x1 dummy's new size.
    let resized = apply(unsafe { rz_doc_clone(doc) }, |d| unsafe {
        rz_doc_resize(d, 16, 12, FILTER_NEAREST)
    });
    let expected: Vec<u8> = (0..12u32)
        .flat_map(|y| {
            (0..16u32).map(move |x| {
                // image's nearest-neighbour maps a destination centre back
                // through the scale factor.
                let sx = ((f32::from(x as u16) + 0.5) * 0.5).floor().min(7.0) as u32;
                let sy = ((f32::from(y as u16) + 0.5) * 0.5).floor().min(5.0) as u32;
                (sx * 16 + sy * 2) as u8
            })
        })
        .collect();
    assert_eq!(read(resized, 16, 12), expected, "resize");
    unsafe { rz_doc_free(resized) };

    unsafe { rz_doc_free(doc) };
}

// ------------------------------------------------- structure and round trips --

#[test]
fn group_and_ungroup_round_trip() {
    let dir = TempDir::new().unwrap();
    let mut doc = doc_from(&dir, "bg.png", &solid(6, 6, RED));
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
    assert_eq!(names(doc), vec!["Background", "A", "B", "C"]);
    let before = flat_pixels(doc);
    let (doc, group_idx) = group(doc, &[1, 2], "G");
    assert_eq!(
        group_idx, 3,
        "the group's subtree occupies the topmost given entry's slot"
    );
    assert_eq!(names(doc), vec!["Background", "A", "B", "G", "C"]);
    assert_eq!(depths(doc), vec![0, 1, 1, 0, 0]);
    assert_eq!(kinds(doc), vec![false, false, false, true, false]);
    assert_eq!(
        flat_pixels(doc),
        before,
        "a pass-through wrap changes no pixel"
    );
    let ungrouped = apply(doc, |d| unsafe {
        rz_doc_ungroup_layer(d, 3, ptr::null_mut(), ptr::null_mut(), 0)
    });
    assert_eq!(names(ungrouped), vec!["Background", "A", "B", "C"]);
    assert_eq!(depths(ungrouped), vec![0, 0, 0, 0]);
    assert_eq!(flat_pixels(ungrouped), before);
    // Ungrouping a raster entry is a refusal, not a no-op copy.
    assert!(
        unsafe { rz_doc_ungroup_layer(ungrouped, 0, ptr::null_mut(), ptr::null_mut(), 0) }
            .is_null()
    );
    unsafe { rz_doc_free(ungrouped) };
}

#[test]
fn group_layers_reports_the_clip_flag_it_cleared() {
    let dir = TempDir::new().unwrap();
    let mut doc = doc_from(&dir, "bg.png", &solid(6, 6, RED));
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
    // A is clipped to Background. Grouping A alone leaves its base outside, so
    // the flag is CLEARED and reported — without which A would silently
    // composite as if unclipped and the clip would be gone with no warning.
    doc = set_clipped(doc, 1, true);
    let (doc, group_idx, cleared, reordered) = group_with_reports(doc, &[1], "G");
    assert_eq!(names(doc), vec!["Background", "A", "G", "B"]);
    assert_eq!(group_idx, 2);
    assert_eq!(
        cleared,
        vec![1],
        "the bottom-most grouped entry lost its base"
    );
    assert!(reordered.is_empty(), "a contiguous set reorders nothing");
    assert!(!unsafe { rz_doc_layer_clipped(doc, 1) });
    // Grouping a clip run WITH its base keeps every flag: the base is inside.
    let regrouped = apply(doc, |d| unsafe {
        rz_doc_ungroup_layer(d, 2, ptr::null_mut(), ptr::null_mut(), 0)
    });
    let regrouped = set_clipped(regrouped, 1, true);
    let (regrouped, _, cleared, _) = group_with_reports(regrouped, &[0, 1], "H");
    assert!(
        cleared.is_empty(),
        "the bottom-most entry of the run is its base"
    );
    assert!(unsafe { rz_doc_layer_clipped(regrouped, 1) });
    unsafe { rz_doc_free(regrouped) };
}

/// `rz_doc_ungroup_layer` with its report: the new document and the entries
/// whose clipped flag was released.
fn ungroup_with_report(doc: *mut RzDocument, idx: usize) -> (*mut RzDocument, Vec<usize>) {
    let cap = unsafe { rz_doc_layer_count(doc) };
    let mut cleared = vec![0usize; cap];
    let mut cleared_len = 0usize;
    let out =
        unsafe { rz_doc_ungroup_layer(doc, idx, cleared.as_mut_ptr(), &mut cleared_len, cap) };
    assert!(!out.is_null(), "ungroup_layer({idx}) refused");
    unsafe { rz_doc_free(doc) };
    cleared.truncate(cleared_len);
    (out, cleared)
}

#[test]
fn ungroup_releases_a_clip_the_group_was_hiding_and_reports_it() {
    // The mirror of `group_layers`' cleared_clip. Inside the group C0 is the
    // BOTTOM of its level, so its clipped flag is baseless and it composites
    // as if unclipped. Ungrouping used to drop it back next to BASE, where it
    // suddenly clipped to BASE's much smaller footprint and most of C0
    // vanished — with nothing anywhere saying so.
    let dir = TempDir::new().unwrap();
    let mut doc = doc_from(&dir, "bg.png", &solid(20, 20, [0, 0, 0, 255]));
    // BASE: a 4x4 opaque square at (2, 2), so a clip to it is unmistakable.
    doc = add_layer(
        &dir,
        "base.png",
        doc,
        0,
        &solid(4, 4, [0, 255, 0, 255]),
        "BASE",
    );
    doc = apply(doc, |d| unsafe { rz_doc_with_layer_offset(d, 1, 2, 2) });
    doc = add_layer(&dir, "c0.png", doc, 1, &solid(20, 20, RED), "C0");
    let (doc, group_idx) = group(doc, &[2], "G");
    let doc = set_clipped(doc, 2, true);
    let before = flat_pixels(doc);
    assert_eq!(
        pixel(&before, 20, 10, 10),
        [255, 0, 0, 255],
        "inside the group C0 is baseless, so it covers everything"
    );
    let (doc, cleared) = ungroup_with_report(doc, group_idx);
    assert_eq!(
        cleared,
        vec![2],
        "C0 would have gained BASE as a clip base, so its flag was released"
    );
    assert!(!unsafe { rz_doc_layer_clipped(doc, 2) });
    assert_eq!(
        flat_pixels(doc),
        before,
        "ungrouping a plain Pass Through group changes no pixel"
    );

    // With NO unclipped sibling below the group the entry is baseless either
    // way, so the flag is left exactly as the user set it.
    let (doc, group_idx) = group(doc, &[2], "G");
    let doc = set_clipped(doc, 2, true);
    let bottom = apply(doc, |d| unsafe {
        rz_doc_remove_layers(d, [0usize, 1].as_ptr(), 2)
    });
    let (bottom, cleared) = ungroup_with_report(bottom, group_idx - 2);
    assert!(
        cleared.is_empty(),
        "nothing unclipped below: still baseless"
    );
    assert!(unsafe { rz_doc_layer_clipped(bottom, 0) });
    unsafe { rz_doc_free(bottom) };
}

/// One entry's mask read back as a canvas-sized plane.
fn mask_plane(doc: *const RzDocument, idx: usize, canvas: (u32, u32)) -> Vec<u8> {
    let mut plane = vec![0u8; (canvas.0 * canvas.1) as usize];
    assert!(
        unsafe { rz_doc_layer_plane(doc, idx, PLANE_MASK, plane.as_mut_ptr(), canvas.0, canvas.1) },
        "layer_plane(mask) refused"
    );
    plane
}

#[test]
fn ungroup_reads_the_bottom_most_child_not_the_deepest_descendant() {
    // The bottom-most child of a dissolved group is not the first entry of its
    // subtree whenever that child is ITSELF a group: the subtree starts at the
    // deepest GRANDCHILD. Reading the subtree's start instead let a clipped
    // child GROUP out at the parent level with its flag intact, where it
    // suddenly clipped to a sibling and the picture collapsed with nothing
    // reported — and, in the mirror case, threw away a deep descendant's flag
    // and reported a release that never happened.
    let dir = TempDir::new().unwrap();
    let canvas = (8u32, 4u32);
    // [Backdrop, B (2 wide), GC (full width, inside G1), G1 (clipped), G]
    let mut doc = doc_from(&dir, "bg.png", &solid(canvas.0, canvas.1, [0, 0, 0, 0]));
    doc = add_layer(&dir, "b.png", doc, 0, &solid(2, canvas.1, BLUE), "B");
    doc = add_layer(
        &dir,
        "gc.png",
        doc,
        1,
        &solid(canvas.0, canvas.1, GREEN),
        "GC",
    );
    let (doc, g1) = group(doc, &[2], "G1");
    let (doc, outer) = group(doc, &[g1], "G");
    // After the wrap, not before: `group_layers` clears the bottom-most
    // grouped entry's flag itself, which is the rule this mirrors.
    let doc = set_clipped(doc, 3, true);
    assert_eq!(depths(doc), vec![0, 0, 2, 1, 0]);
    let before = flat_pixels(doc);
    assert_eq!(
        pixel(&before, canvas.0, 5, 1),
        GREEN,
        "G1 is the bottom of its level inside G, so its clip is baseless"
    );
    let (doc, cleared) = ungroup_with_report(doc, outer);
    assert_eq!(
        cleared,
        vec![3],
        "the bottom-most CHILD is G1 at 3, not the grandchild at 2"
    );
    assert!(!unsafe { rz_doc_layer_clipped(doc, 3) });
    assert_eq!(
        flat_pixels(doc),
        before,
        "dissolving a Pass Through group changes no pixel"
    );
    unsafe { rz_doc_free(doc) };

    // The mirror: the deepest descendant IS clipped but stays at the bottom of
    // its own inner level, so its flag must be left exactly where it was.
    let mut doc = doc_from(&dir, "bg2.png", &solid(canvas.0, canvas.1, [0, 0, 0, 0]));
    doc = add_layer(&dir, "b2.png", doc, 0, &solid(2, canvas.1, BLUE), "B");
    doc = add_layer(
        &dir,
        "gc2.png",
        doc,
        1,
        &solid(canvas.0, canvas.1, GREEN),
        "GC",
    );
    doc = add_layer(
        &dir,
        "gc3.png",
        doc,
        2,
        &solid(canvas.0, canvas.1, RED),
        "GC2",
    );
    let (doc, g1) = group(doc, &[2, 3], "G1");
    let doc = set_clipped(doc, 2, true);
    let (doc, outer) = group(doc, &[g1], "G");
    assert_eq!(depths(doc), vec![0, 0, 2, 2, 1, 0]);
    let before = flat_pixels(doc);
    let (doc, cleared) = ungroup_with_report(doc, outer);
    assert!(
        cleared.is_empty(),
        "the grandchild was and stays at the bottom of its own level"
    );
    assert!(
        unsafe { rz_doc_layer_clipped(doc, 2) },
        "its stored flag survives"
    );
    assert_eq!(flat_pixels(doc), before);
    unsafe { rz_doc_free(doc) };
}

#[test]
fn moving_a_masked_group_out_and_back_restores_its_mask() {
    // A group's mask TRAVELS WITH THE GROUP as bookkeeping on the group's own
    // offset, never as a resample per step: composing translations of a canvas
    // plane ate a band of the mask on every tick, so one Move drag that went
    // out and came back — or two opposite arrow nudges — permanently changed
    // the picture inside a single undo step.
    let dir = TempDir::new().unwrap();
    let canvas = (16u32, 8u32);
    let mut doc = doc_from(&dir, "bg.png", &solid(canvas.0, canvas.1, [0, 0, 0, 0]));
    doc = add_layer(
        &dir,
        "a.png",
        doc,
        0,
        &solid(canvas.0, canvas.1, [255, 255, 255, 255]),
        "A",
    );
    let (doc, group_idx) = group(doc, &[1], "G");
    let reveal = selection(canvas.0, canvas.1, |_, _| 255);
    let doc = add_canvas_mask(doc, group_idx, &reveal, canvas.0, canvas.1);
    let before_mask = mask_plane(doc, group_idx, canvas);
    let before = flat_pixels(doc);
    assert!(
        before.chunks_exact(4).all(|p| p[3] == 255),
        "a reveal-all mask hides nothing"
    );
    let set = [group_idx];
    let out = apply(doc, |d| unsafe {
        rz_doc_move_layers(d, set.as_ptr(), set.len(), 5, 0)
    });
    let shifted = mask_plane(out, group_idx, canvas);
    assert!(
        (0..canvas.1).all(|y| (0..5).all(|x| shifted[(y * canvas.0 + x) as usize] == 0)),
        "the mask travelled with the group"
    );
    let back = apply(out, |d| unsafe {
        rz_doc_move_layers(d, set.as_ptr(), set.len(), -5, 0)
    });
    assert_eq!(
        mask_plane(back, group_idx, canvas),
        before_mask,
        "the mask bytes come back exactly"
    );
    assert_eq!(flat_pixels(back), before, "and so does the picture");
    unsafe { rz_doc_free(back) };
}

#[test]
fn grouping_a_non_contiguous_set_reports_what_it_reordered() {
    let dir = TempDir::new().unwrap();
    let mut doc = doc_from(&dir, "bg.png", &solid(6, 6, RED));
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
    // Grouping {A, C} out of [A, B, C] gathers both subtrees into C's slot, so
    // B is left BELOW A rather than between them — a real reorder, reported by
    // new index so the caller can say which entries moved.
    let (doc, group_idx, cleared, reordered) = group_with_reports(doc, &[1, 3], "G");
    assert_eq!(names(doc), vec!["Background", "B", "A", "C", "G"]);
    assert_eq!(group_idx, 4);
    assert!(cleared.is_empty());
    assert_eq!(reordered, vec![1], "B changed its relative position");
    assert_eq!(depths(doc), vec![0, 0, 1, 1, 0]);
    unsafe { rz_doc_free(doc) };
}

#[test]
fn grouping_across_parents_or_levels_is_refused() {
    let dir = TempDir::new().unwrap();
    let mut doc = doc_from(&dir, "bg.png", &solid(6, 6, RED));
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
    let (doc, _) = group(doc, &[1], "G");
    // Entry 1 is now inside G; entry 0 is at the top level.
    let idx = [0usize, 1];
    let cname = CString::new("bad").unwrap();
    let mut group_out = 0usize;
    assert!(
        unsafe {
            rz_doc_group_layers(
                doc,
                idx.as_ptr(),
                2,
                cname.as_ptr(),
                &mut group_out,
                ptr::null_mut(),
                ptr::null_mut(),
                ptr::null_mut(),
                ptr::null_mut(),
                0,
            )
        }
        .is_null(),
        "entries at different levels cannot be grouped together"
    );
    unsafe { rz_doc_free(doc) };
}

#[test]
fn adding_duplicating_and_removing_take_the_whole_subtree() {
    let dir = TempDir::new().unwrap();
    let mut doc = doc_from(&dir, "bg.png", &solid(6, 6, RED));
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
    let (doc, group_idx) = group(doc, &[1, 2], "G");
    assert_eq!(group_idx, 3);
    // The subtree is the answer every "where does a new entry land" site asks
    // for, and it is what `adding_layer` uses.
    let mut start = 0usize;
    let mut end = 0usize;
    assert!(unsafe { rz_doc_layer_subtree(doc, 3, &mut start, &mut end) });
    assert_eq!((start, end), (1, 4));
    let cname = CString::new("New").unwrap();
    let added = apply(doc, |d| unsafe {
        rz_doc_adding_layer(d, 3, cname.as_ptr())
    });
    assert_eq!(names(added), vec!["Background", "A", "B", "G", "New"]);
    assert_eq!(
        depths(added),
        vec![0, 1, 1, 0, 0],
        "the new entry takes G's depth"
    );
    // Duplicating a group copies its whole subtree, " copy" on the group only.
    let duped = apply(added, |d| unsafe { rz_doc_duplicating_layer(d, 3) });
    assert_eq!(
        names(duped),
        vec!["Background", "A", "B", "G", "A", "B", "G copy", "New"]
    );
    assert_eq!(depths(duped), vec![0, 1, 1, 0, 1, 1, 0, 0]);
    // Removing a group removes its whole subtree.
    let removed = apply(duped, |d| unsafe { rz_doc_removing_layer(d, 6) });
    assert_eq!(names(removed), vec!["Background", "A", "B", "G", "New"]);
    unsafe { rz_doc_free(removed) };
}

#[test]
fn merging_down_targets_the_previous_sibling() {
    let dir = TempDir::new().unwrap();
    let mut doc = doc_from(&dir, "bg.png", &solid(8, 8, [0, 0, 0, 255]));
    doc = add_layer(&dir, "a.png", doc, 0, &solid(8, 8, [255, 0, 0, 255]), "A");
    doc = add_layer(&dir, "b.png", doc, 1, &solid(8, 8, [0, 255, 0, 255]), "B");
    let (doc, group_idx) = group(doc, &[1, 2], "G");
    assert_eq!(group_idx, 3);
    assert_eq!(names(doc), vec!["Background", "A", "B", "G"]);
    // Inside the group, B merges into A — its previous SIBLING — and the
    // result stays inside the group at the level's depth.
    let merged = apply(unsafe { rz_doc_clone(doc) }, |d| unsafe {
        rz_doc_merging_down(d, 2)
    });
    assert_eq!(names(merged), vec!["Background", "A", "G"]);
    assert_eq!(depths(merged), vec![0, 1, 0]);
    let px = flat_pixels(merged);
    assert_eq!(pixel(&px, 8, 4, 4), [0, 255, 0, 255], "B baked into A");
    unsafe { rz_doc_free(merged) };
    // A is at the BOTTOM of its level: nothing below it INSIDE the group, so
    // the merge is refused rather than reaching across the boundary into the
    // Background.
    assert!(unsafe { rz_doc_merging_down(doc, 1) }.is_null());
    // The group itself merges down into the Background, rasterized first.
    let flat = apply(unsafe { rz_doc_clone(doc) }, |d| unsafe {
        rz_doc_merging_down(d, 3)
    });
    assert_eq!(names(flat), vec!["Background"]);
    assert_eq!(depths(flat), vec![0]);
    let px = flat_pixels(flat);
    assert_eq!(
        pixel(&px, 8, 4, 4),
        [0, 255, 0, 255],
        "B over A, baked into the Background"
    );
    unsafe { rz_doc_free(flat) };
    unsafe { rz_doc_free(doc) };
}

#[test]
fn moving_an_entry_into_and_out_of_a_group_keeps_the_structure_valid() {
    let dir = TempDir::new().unwrap();
    let mut doc = doc_from(&dir, "bg.png", &solid(6, 6, RED));
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
    let (doc, group_idx) = group(doc, &[2], "G");
    assert_eq!(names(doc), vec!["Background", "A", "B", "G"]);
    assert_eq!(group_idx, 3);
    // Move A (index 1) INTO the group, at depth 1, just below B.
    let moved = apply(doc, |d| unsafe { rz_doc_move_layer_to(d, 1, 1, 1) });
    assert_eq!(names(moved), vec!["Background", "A", "B", "G"]);
    assert_eq!(depths(moved), vec![0, 1, 1, 0]);
    // And back out to the top level.
    let out = apply(moved, |d| unsafe { rz_doc_move_layer_to(d, 1, 3, 0) });
    assert_eq!(depths(out), vec![0, 1, 0, 0]);
    assert_eq!(names(out), vec!["Background", "B", "G", "A"]);
    // A malformed (to, depth) pair is a refusal, never a corrupt document:
    // depth 1 at the very top would leave a child with no enclosing group.
    assert!(unsafe { rz_doc_move_layer_to(out, 0, 3, 1) }.is_null());
    // A group cannot move into its own subtree.
    assert!(unsafe { rz_doc_move_layer_to(out, 2, 1, 1) }.is_null());
    unsafe { rz_doc_free(out) };
}

#[test]
fn grouping_is_meta_and_style_free() {
    // Grouping is a pure re-parent: a described layer keeps its description
    // and a styled layer keeps its style, so the host's re-render contract
    // survives the move.
    let dir = TempDir::new().unwrap();
    let mut doc = doc_from(&dir, "bg.png", &solid(8, 8, RED));
    doc = add_layer(&dir, "text.png", doc, 0, &solid(4, 4, BLUE), "Text");
    doc = set_meta(doc, 1, TEXT_META);
    doc = with_style(doc, 1, STYLE_JSON);
    let style_before = unsafe { rz_doc_layer_style(doc, 1) };
    assert!(!style_before.is_null());
    let style_before = take_err_string(style_before);
    let (doc, _) = group(doc, &[1], "G");
    assert_eq!(ffi_meta(doc, 1).as_deref(), Some(TEXT_META));
    let style_after = take_err_string(unsafe { rz_doc_layer_style(doc, 1) });
    assert_eq!(style_after, style_before);
    unsafe { rz_doc_free(doc) };
}

#[test]
fn locks_links_and_the_open_flag_round_trip_through_the_getters() {
    let dir = TempDir::new().unwrap();
    let mut doc = doc_from(&dir, "bg.png", &solid(4, 4, RED));
    doc = add_layer(&dir, "a.png", doc, 0, &solid(4, 4, BLUE), "A");
    // Defaults.
    assert_eq!(unsafe { rz_doc_layer_locks(doc, 0) }, 0);
    assert_eq!(unsafe { rz_doc_layer_link(doc, 0) }, 0);
    assert_eq!(unsafe { rz_doc_layer_depth(doc, 0) }, 0);
    assert!(!unsafe { rz_doc_layer_is_group(doc, 0) });
    // Reserved bits are masked off rather than stored.
    let locked = apply(doc, |d| unsafe {
        rz_doc_with_layer_locks(d, 1, 0xFFFF_FFFF)
    });
    assert_eq!(unsafe { rz_doc_layer_locks(locked, 1) }, 7);
    // lock_block names the lock that would stop each kind of edit.
    assert_eq!(unsafe { rz_doc_lock_block(locked, 1, 0) }, 2, "pixels");
    assert_eq!(unsafe { rz_doc_lock_block(locked, 1, 1) }, 4, "position");
    assert_eq!(
        unsafe { rz_doc_lock_block(locked, 1, 2) },
        7,
        "Lock All freezes the mask"
    );
    let position = apply(locked, |d| unsafe { rz_doc_with_layer_locks(d, 1, 4) });
    assert_eq!(
        unsafe { rz_doc_lock_block(position, 1, 0) },
        0,
        "position never blocks pixels"
    );
    assert_eq!(
        unsafe { rz_doc_lock_block(position, 1, 2) },
        0,
        "nor the mask"
    );
    // A group's position block also answers for its descendants.
    let (grouped, group_idx) = group(position, &[1], "G");
    assert_eq!(unsafe { rz_doc_lock_block(grouped, group_idx, 1) }, 4);
    // The disclosure flag is a group's alone.
    assert!(unsafe { rz_doc_layer_open(grouped, group_idx) });
    let closed = apply(grouped, |d| unsafe {
        rz_doc_with_layer_open(d, group_idx, false)
    });
    assert!(!unsafe { rz_doc_layer_open(closed, group_idx) });
    assert!(
        unsafe { rz_doc_with_layer_open(closed, 0, false) }.is_null(),
        "a raster entry has nothing to expand"
    );
    unsafe { rz_doc_free(closed) };
}

#[test]
fn a_group_offset_shifts_its_whole_subtree() {
    let dir = TempDir::new().unwrap();
    let mut doc = doc_from(&dir, "bg.png", &solid(20, 20, [0, 0, 0, 0]));
    doc = add_layer(&dir, "a.png", doc, 0, &solid(2, 2, [255, 0, 0, 255]), "A");
    doc = apply(doc, |d| unsafe { rz_doc_with_layer_offset(d, 1, 4, 4) });
    doc = add_layer(&dir, "b.png", doc, 1, &solid(2, 2, [0, 255, 0, 255]), "B");
    doc = apply(doc, |d| unsafe { rz_doc_with_layer_offset(d, 2, 10, 8) });
    let (doc, group_idx) = group(doc, &[1, 2], "G");
    assert_eq!(bounds(doc, group_idx), Some((4, 4, 8, 6)));
    let moved = apply(doc, |d| unsafe {
        rz_doc_with_layer_offset(d, group_idx, 0, 1)
    });
    assert_eq!(bounds(moved, group_idx), Some((0, 1, 8, 6)));
    assert_eq!(
        layer_offset(moved, 1),
        (0, 1),
        "every descendant moved by the delta"
    );
    assert_eq!(layer_offset(moved, 2), (6, 5));
    unsafe { rz_doc_free(moved) };
}

#[test]
fn a_nested_group_s_own_style_survives_an_isolated_parent() {
    // A styled GROUP's effects reach outside its children, exactly as a
    // styled layer's reach outside its pixels. The enclosing group's private
    // buffer therefore has to be sized to hold them: an extent unioned over
    // the LEAF rects alone clipped the inner group's drop shadow away
    // entirely the moment the outer group isolated.
    let dir = TempDir::new().unwrap();
    let canvas = 200u32;
    let white = [255u8, 255, 255, 255];
    let mut doc = doc_from(&dir, "bg.png", &solid(canvas, canvas, white));
    doc = add_layer(
        &dir,
        "red.png",
        doc,
        0,
        &solid(50, 50, [220, 40, 40, 255]),
        "Red",
    );
    doc = apply(doc, |d| unsafe { rz_doc_with_layer_offset(d, 1, 75, 75) });
    let (doc, inner) = group(doc, &[1], "Ginner");
    // Distance 0 so the shadow is a symmetric halo the leaf rect cannot
    // contain: every shadow pixel is outside 75..125 in both axes.
    let doc = with_style(
        doc,
        inner,
        "{\"effects\":[{\"type\":\"drop_shadow\",\"distance\":0,\"size\":40,\
          \"spread\":0.2,\"opacity\":1}]}",
    );
    let (doc, outer) = group(doc, &[inner], "Gouter");

    // Counts pixels outside the leaf rect that are no longer the background.
    let halo = |doc: *const RzDocument| {
        let flat = flat_pixels(doc);
        (0..canvas)
            .flat_map(|y| (0..canvas).map(move |x| (x, y)))
            .filter(|&(x, y)| !(75..125).contains(&x) && !(75..125).contains(&y))
            .filter(|&(x, y)| pixel(&flat, canvas, x, y) != white)
            .count()
    };
    let through = halo(doc);
    assert!(through > 1000, "the pass-through case draws the shadow");

    // A fully revealing canvas-sized mask on the OUTER group changes no
    // colour at all — it only forces `is_isolated`, which is the whole
    // difference under test.
    let doc = add_canvas_mask(
        doc,
        outer,
        &vec![255u8; (canvas * canvas) as usize],
        canvas,
        canvas,
    );
    let isolated = halo(doc);
    assert!(
        isolated * 10 >= through * 9,
        "an isolated parent must not clip the inner group's shadow: \
         {isolated} shadow pixels against {through} through the pass-through parent"
    );
    unsafe { rz_doc_free(doc) };
}

#[test]
fn align_moves_a_group_and_its_own_child_exactly_once() {
    // A selection may name a group AND one of its children; the core reduces
    // to independent roots, so the child moves once — with its group — and
    // not once more on its own. Applying each delta through a nested move
    // instead ADDED them and pushed the child clean off the canvas.
    let dir = TempDir::new().unwrap();
    let mut doc = doc_from(&dir, "bg.png", &solid(40, 20, [0, 0, 0, 0]));
    doc = add_layer(&dir, "a.png", doc, 0, &solid(4, 4, [255, 0, 0, 255]), "A");
    doc = apply(doc, |d| unsafe { rz_doc_with_layer_offset(d, 1, 8, 2) });
    doc = add_layer(&dir, "b.png", doc, 1, &solid(4, 4, [0, 255, 0, 255]), "B");
    doc = apply(doc, |d| unsafe { rz_doc_with_layer_offset(d, 2, 30, 10) });
    let (doc, g) = group(doc, &[1, 2], "G");
    assert_eq!(bounds(doc, g), Some((8, 2, 26, 12)));

    // The group plus its own child B: the reference is the canvas, so the
    // group's left edge (8) lands on 0 and B travels with it to 22.
    let set = [2usize, g];
    let aligned = apply(doc, |d| unsafe {
        rz_doc_align_layers(d, set.as_ptr(), set.len(), ALIGN_LEFT, true)
    });
    assert_eq!(layer_offset(aligned, 1), (0, 2), "A moved with the group");
    assert_eq!(
        layer_offset(aligned, 2),
        (22, 10),
        "B moved with the group ONCE, not once more for naming it directly"
    );
    assert_eq!(bounds(aligned, g), Some((0, 2, 26, 12)));
    unsafe { rz_doc_free(aligned) };
}

#[test]
fn a_group_s_geometry_getters_are_the_buffer_union_not_the_content_box() {
    // The four geometry getters are read once per row on every panel reload
    // and once per row by the agent, so a group's answer has to be cheap:
    // the union of its raster descendants' BUFFER rects, which is the same
    // meaning a raster row's four values already carry. The content box —
    // which has to look at the pixels — stays behind `rz_doc_layer_bounds`.
    let dir = TempDir::new().unwrap();
    let mut sparse = RgbaImage::from_pixel(20, 20, Rgba([0, 0, 0, 0]));
    for y in 5..7 {
        for x in 4..7 {
            sparse.put_pixel(x, y, Rgba([255, 0, 0, 255]));
        }
    }
    let mut doc = doc_from(&dir, "bg.png", &solid(20, 20, [0, 0, 0, 0]));
    doc = add_layer(&dir, "sparse.png", doc, 0, &sparse, "Sparse");
    let (doc, g) = group(doc, &[1], "G");
    assert_eq!(bounds(doc, g), Some((4, 5, 3, 2)), "the CONTENT box");
    let getters = unsafe {
        (
            rz_doc_layer_offset_x(doc, g),
            rz_doc_layer_offset_y(doc, g),
            rz_doc_layer_width(doc, g),
            rz_doc_layer_height(doc, g),
        )
    };
    assert_eq!(
        getters,
        (0, 0, 20, 20),
        "the geometry getters are the descendants' buffer union"
    );
    // Getter and setter speak the SAME rectangle, so reading an entry's
    // offset and writing it back is the identity — on a group exactly as on
    // a raster layer.
    // …and the identity is spelled the way the purity rule spells it: an op
    // that would change nothing answers NULL rather than an identical copy,
    // so a host echoing a row back adds no undo step.
    assert!(
        unsafe { rz_doc_with_layer_offset(doc, g, 0, 0) }.is_null(),
        "writing back the offset just read moves nothing"
    );
    let shifted = apply(doc, |d| unsafe { rz_doc_with_layer_offset(d, g, 6, 1) });
    assert_eq!(layer_offset(shifted, 1), (6, 1));
    assert_eq!(
        bounds(shifted, g),
        Some((10, 6, 3, 2)),
        "the CONTENT box moved too"
    );
    let doc = apply(shifted, |d| unsafe { rz_doc_with_layer_offset(d, g, 0, 0) });

    // An EMPTY group has no descendant buffer at all and answers zero, the
    // same as an out-of-range index.
    let (doc, outer) = group(doc, &[g], "Outer");
    let emptied = apply(doc, |d| unsafe {
        rz_doc_remove_layers(d, [1usize].as_ptr(), 1)
    });
    let empty_group = outer - 2;
    assert!(unsafe { rz_doc_layer_is_group(emptied, empty_group) });
    assert_eq!(unsafe { rz_doc_layer_width(emptied, empty_group) }, 0);
    assert_eq!(bounds(emptied, empty_group), None);
    unsafe { rz_doc_free(emptied) };
}
