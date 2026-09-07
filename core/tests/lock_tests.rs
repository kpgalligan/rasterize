//! The lock EDIT KINDS that are not a plain pixel write — applying a mask
//! (`RZ_EDIT_MASK_APPLY`) and merging into an entry (`RZ_EDIT_MERGE`) — the
//! whole-document geometry op that is deliberately EXEMPT from the position
//! lock, and the purity latch on the two lock-adjacent setters.
//!
//! `structure_tests` owns the per-lock behaviour and the two sweeps that
//! prove every wrapped export is wired; it is at its size budget, so
//! `doc_lock`'s coverage continues here. Black-box through the FFI.

use std::ffi::CString;

use rasterize_core::doc::RzDocument;
use rasterize_core::ffi_doc::*;
use rasterize_core::ffi_group::*;
use tempfile::TempDir;

mod common;
use common::*;

fn set_locks(doc: *mut RzDocument, idx: usize, locks: u32) -> *mut RzDocument {
    apply(doc, |d| unsafe { rz_doc_with_layer_locks(d, idx, locks) })
}

/// `set_locks` that KEEPS the input handle, for the loops that lock the same
/// fixture several ways (`apply` frees what it is given).
fn locked_copy(doc: *const RzDocument, idx: usize, locks: u32) -> *mut RzDocument {
    let out = unsafe { rz_doc_with_layer_locks(doc, idx, locks) };
    assert!(!out.is_null(), "locking {idx} with {locks}");
    out
}

fn group(doc: *mut RzDocument, idx: &[usize], name: &str) -> (*mut RzDocument, usize) {
    let cname = CString::new(name).expect("no interior NUL");
    let mut group = usize::MAX;
    let mut len = 0usize;
    let out = unsafe {
        rz_doc_group_layers(
            doc,
            idx.as_ptr(),
            idx.len(),
            cname.as_ptr(),
            &mut group,
            std::ptr::null_mut(),
            &mut len,
            std::ptr::null_mut(),
            &mut len,
            0,
        )
    };
    assert!(!out.is_null(), "group_layers({idx:?}) refused");
    unsafe { rz_doc_free(doc) };
    (out, group)
}

/// The alpha of layer `idx`'s first pixel.
fn first_alpha(doc: *const RzDocument, idx: usize) -> u8 {
    layer_pixels(doc, idx)[3]
}

#[test]
fn applying_a_mask_is_refused_on_a_transparency_locked_layer() {
    // Adding, painting, enabling and DELETING a mask leave the layer's alpha
    // alone, which is why only Lock All gates them. APPLYING one multiplies
    // the coverage straight into that alpha — a hide-all mask applied to a
    // transparency-locked layer erased the entire layer, which is exactly
    // the hole an eraser is not allowed to punch.
    let dir = TempDir::new().unwrap();
    let doc = doc_from(&dir, "one.png", &solid(4, 4, [10, 20, 30, 255]));
    let locked = set_locks(doc, 0, LOCK_TRANSPARENCY);
    let masked = apply(locked, |d| unsafe {
        rz_doc_adding_layer_mask(d, 0, MASK_HIDE_ALL, std::ptr::null(), 0, 0)
    });
    assert_eq!(
        first_alpha(masked, 0),
        255,
        "a mask does not touch the alpha"
    );

    assert_eq!(
        unsafe { rz_doc_lock_block(masked, 0, EDIT_MASK) },
        0,
        "a plain mask edit is not gated by Transparency"
    );
    assert_eq!(
        unsafe { rz_doc_lock_block(masked, 0, EDIT_MASK_APPLY) },
        LOCK_TRANSPARENCY,
        "…and an APPLY is, so the host can name the lock"
    );
    assert!(
        unsafe { rz_doc_removing_layer_mask(masked, 0, true) }.is_null(),
        "apply is refused"
    );
    // Deleting the mask WITHOUT applying it is untouched.
    let deleted = apply(masked, |d| unsafe {
        rz_doc_removing_layer_mask(d, 0, false)
    });
    assert_eq!(first_alpha(deleted, 0), 255);

    // Unlocked, the same apply goes through and takes the alpha to zero —
    // which is the behaviour the lock exists to prevent.
    let remasked = apply(deleted, |d| unsafe {
        rz_doc_adding_layer_mask(d, 0, MASK_HIDE_ALL, std::ptr::null(), 0, 0)
    });
    let unlocked = set_locks(remasked, 0, 0);
    let applied = apply(unlocked, |d| unsafe {
        rz_doc_removing_layer_mask(d, 0, true)
    });
    assert_eq!(first_alpha(applied, 0), 0);
    unsafe { rz_doc_free(applied) };
}

#[test]
fn a_merge_answers_to_the_destination_entry_s_locks() {
    // Merging is the one op that destroys a layer's contents outright, and
    // it was the one pixel writer with no lock gate at all: Lock Pixels —
    // and even Lock All — let it replace the lower layer's picture, while
    // the agent's refusal text promised the opposite.
    let dir = TempDir::new().unwrap();
    let mut doc = doc_from(&dir, "low.png", &solid(4, 4, [10, 10, 10, 255]));
    doc = add_layer(
        &dir,
        "up.png",
        doc,
        0,
        &solid(4, 4, [200, 200, 200, 255]),
        "Up",
    );
    let pair = [0usize, 1];

    for lock in [LOCK_PIXELS, LOCK_TRANSPARENCY, LOCK_ALL] {
        let locked = locked_copy(doc, 0, lock);
        assert_eq!(
            unsafe { rz_doc_lock_block(locked, 0, EDIT_MERGE) } & lock,
            lock & (LOCK_PIXELS | LOCK_TRANSPARENCY),
            "the query names the bits that stopped it ({lock})"
        );
        assert!(
            unsafe { rz_doc_merging_down(locked, 1) }.is_null(),
            "merge down onto a locked layer ({lock})"
        );
        assert!(
            unsafe { rz_doc_merge_layers(locked, pair.as_ptr(), 2) }.is_null(),
            "merge layers into a locked lowest member ({lock})"
        );
        unsafe { rz_doc_free(locked) };
    }

    // A POSITION lock is not a merge lock — Photoshop merges those too — and
    // the UPPER operand is only removed, which no lock blocks.
    let positioned = locked_copy(doc, 0, LOCK_POSITION);
    let merged = apply(positioned, |d| unsafe { rz_doc_merging_down(d, 1) });
    assert_eq!(layer_pixels(merged, 0)[0], 200, "the merge went through");
    unsafe { rz_doc_free(merged) };

    let upper_locked = locked_copy(doc, 1, LOCK_ALL);
    let merged = apply(upper_locked, |d| unsafe { rz_doc_merging_down(d, 1) });
    assert_eq!(unsafe { rz_doc_layer_count(merged) }, 1);
    unsafe { rz_doc_free(merged) };
    unsafe { rz_doc_free(doc) };
}

#[test]
fn setting_the_locks_or_the_open_flag_a_layer_already_has_is_a_no_op() {
    // The core's purity rule, and it is load-bearing rather than tidy: the
    // host registers an undo step and dirties the document for every non-nil
    // answer, so an idempotent `set_layer_lock` used to put a phantom step
    // between the user and their last real edit.
    let dir = TempDir::new().unwrap();
    let mut doc = doc_from(&dir, "one.png", &solid(4, 4, [10, 20, 30, 255]));
    assert!(
        unsafe { rz_doc_with_layer_locks(doc, 0, 0) }.is_null(),
        "an unlocked layer is already unlocked"
    );
    doc = set_locks(doc, 0, LOCK_PIXELS);
    assert!(unsafe { rz_doc_with_layer_locks(doc, 0, LOCK_PIXELS) }.is_null());
    assert!(
        unsafe { rz_doc_with_layer_locks(doc, 0, LOCK_PIXELS | 0xF000) }.is_null(),
        "the reserved bits are masked off BEFORE the comparison"
    );
    assert!(!unsafe { rz_doc_with_layer_locks(doc, 0, LOCK_ALL) }.is_null());

    doc = add_layer(
        &dir,
        "top.png",
        doc,
        0,
        &solid(4, 4, [0, 0, 255, 255]),
        "Top",
    );
    let (doc, g) = group(doc, &[1], "G");
    assert!(unsafe { rz_doc_layer_open(doc, g) }, "a new group is open");
    assert!(
        unsafe { rz_doc_with_layer_open(doc, g, true) }.is_null(),
        "it is open already"
    );
    let closed = apply(doc, |d| unsafe { rz_doc_with_layer_open(d, g, false) });
    assert!(unsafe { rz_doc_with_layer_open(closed, g, false) }.is_null());
    assert!(!unsafe { rz_doc_with_layer_open(closed, g, true) }.is_null());
    unsafe { rz_doc_free(closed) };
}

#[test]
fn a_straighten_ignores_the_position_locks_a_set_transform_refuses() {
    // Straightening re-frames the whole picture, which is why rz_doc_crop,
    // rz_doc_geometry and rz_doc_resize beside it consult no layer lock
    // either. Routing it through the SET transform made one locked layer —
    // the Background, the layer a Photoshop user locks by habit — refuse an
    // entire document-wide crop, with nothing but a beep to show for it.
    let dir = TempDir::new().unwrap();
    let mut doc = doc_from(&dir, "bg.png", &solid(8, 8, [10, 20, 30, 255]));
    doc = add_layer(
        &dir,
        "top.png",
        doc,
        0,
        &solid(4, 4, [0, 0, 255, 255]),
        "Top",
    );
    let locked = set_locks(doc, 0, LOCK_POSITION);
    // A quarter turn about the canvas centre: exact, so no resampling loss.
    let affine = [0.0f64, 1.0, -1.0, 0.0, 8.0, 0.0];
    let all = [0usize, 1];
    assert!(
        unsafe {
            rz_doc_transform_layers(locked, all.as_ptr(), 2, affine.as_ptr(), FILTER_NEAREST)
        }
        .is_null(),
        "the SET transform is all-or-nothing under a position lock"
    );
    let straightened = apply(locked, |d| unsafe {
        rz_doc_straighten_layers(d, affine.as_ptr(), FILTER_NEAREST)
    });
    assert_eq!(
        layer_offset(straightened, 1),
        (4, 0),
        "every entry followed the matrix, the locked one included"
    );
    // The plain crop beside it is unlocked in exactly the same way.
    assert!(!unsafe { rz_doc_crop(straightened, 1, 1, 4, 4) }.is_null());
    unsafe { rz_doc_free(straightened) };
}
