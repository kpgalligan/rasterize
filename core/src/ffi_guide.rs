//! C FFI for guides and the ruler origin (`rz_max_guides`, `rz_doc_guide_*`,
//! `rz_doc_ruler_origin`, `rz_doc_set_ruler_origin`) — the "Guides, rulers
//! and snapping" section of `include/rasterize_core.h`. Same conventions as
//! the sibling shims: `catch_unwind` through the `ffi_util` helpers, NULL
//! tolerance first, narrow `unsafe` blocks.
//!
//! Like the channel family there is no `err_out` anywhere: every refusal is
//! NULL / 0 / -1 and the reasons are in the doc comments. A host that needs
//! to tell one refusal from another (out of canvas, already occupied, list
//! full) checks before it calls — which is why [`rz_max_guides`] exists.
//!
//! `orientation` is declared `c_int` and mapped through
//! [`GuideOrientation::from_c`], for the reason `ffi_channel` gives of
//! `RzPlane`: materializing an enum from an out-of-range discriminant would
//! be undefined behaviour.
//!
//! **No bulk getter, deliberately.** The host caches the list in its own
//! array, refreshed once per document change, so a canvas redraw makes zero
//! FFI calls; three calls per guide per change, on a list that is under ten
//! entries in any real document, is far under the five-calls-per-channel
//! `rz_doc_channel_*` reload this crate already accepts.

use std::ffi::{c_double, c_int};
use std::panic::catch_unwind;
use std::ptr;

use crate::doc::RzDocument;
use crate::doc_guide::{GuideOrientation, MAX_GUIDES};
use crate::ffi_util::{doc_get, doc_op};

/// The largest guide list any document may carry — `doc_guide::MAX_GUIDES`,
/// today 1024.
///
/// It takes no arguments because, unlike the channel budget
/// (`rz_max_channels_at`), the cap does NOT vary with the canvas: a guide is
/// a line, not a plane, so no canvas size makes fewer of them fit. It is
/// exported rather than left as a Swift literal because a host must be able
/// to tell "the list is full" apart from "that guide already exists" when
/// `rz_doc_add_guide` answers a single NULL, and one exported constant cannot
/// drift from the core's.
#[no_mangle]
pub extern "C" fn rz_max_guides() -> usize {
    // Pure arithmetic that cannot panic; the guard is the family's uniform
    // shape, not a defence against a known unwind.
    catch_unwind(|| MAX_GUIDES).unwrap_or(0)
}

/// Number of guides on the document; 0 on a NULL doc.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_guide_count(doc: *const RzDocument) -> usize {
    unsafe { doc_get(doc, 0, |d| Some(d.guides.len())) }
}

/// Guide `i`'s stable identity — unique among every guide this process has
/// minted, kept by a move, the geometry ops and undo/redo, and re-minted on
/// load. 0 on a NULL doc or an out-of-range index, which no live guide ever
/// answers.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_guide_id(doc: *const RzDocument, i: usize) -> u64 {
    unsafe { doc_get(doc, 0, |d| Some(d.guides.get(i)?.id)) }
}

/// Guide `i`'s orientation as an `RzGuideOrientation`; -1 on a NULL doc or an
/// out-of-range index, which is outside the enum on purpose.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_guide_orientation(doc: *const RzDocument, i: usize) -> c_int {
    unsafe { doc_get(doc, -1, |d| Some(d.guides.get(i)?.orientation.to_c())) }
}

/// Guide `i`'s canvas position — the x of a vertical guide, the y of a
/// horizontal one. -1.0 on a NULL doc or an out-of-range index: a legal
/// position is never negative, so the sentinel cannot collide with an answer.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_guide_position(doc: *const RzDocument, i: usize) -> c_double {
    unsafe { doc_get(doc, -1.0, |d| Some(d.guides.get(i)?.position)) }
}

/// Adds a guide at `position` and returns a NEW document. NULL on a NULL doc,
/// an orientation outside `RzGuideOrientation`, a non-finite position, a
/// position outside [0, canvas extent], a position a guide of the same
/// orientation already occupies, or a list already holding `rz_max_guides()`.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_add_guide(
    doc: *const RzDocument,
    orientation: c_int,
    position: c_double,
) -> *mut RzDocument {
    unsafe {
        doc_op(doc, |d| {
            d.add_guide(GuideOrientation::from_c(orientation)?, position)
        })
    }
}

/// Moves guide `i` along its own axis, keeping its identity and orientation.
/// NULL on a NULL doc, an out-of-range index, a non-finite or out-of-canvas
/// position, the position the guide already has, or a position another guide
/// of the same orientation already occupies.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_move_guide(
    doc: *const RzDocument,
    i: usize,
    position: c_double,
) -> *mut RzDocument {
    unsafe { doc_op(doc, |d| d.move_guide(i, position)) }
}

/// Drops guide `i`. NULL on a NULL doc or an out-of-range index.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_remove_guide(doc: *const RzDocument, i: usize) -> *mut RzDocument {
    unsafe { doc_op(doc, |d| d.remove_guide(i)) }
}

/// Drops every guide. NULL on a NULL doc or an already empty list — clearing
/// nothing is not an edit.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_clear_guides(doc: *const RzDocument) -> *mut RzDocument {
    unsafe { doc_op(doc, |d| d.clear_guides()) }
}

/// Writes the ruler origin as two doubles (x, y) into `out_xy`; false on a
/// NULL doc or a NULL buffer.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`; `out_xy`
/// must be NULL or writable for 2 doubles.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_ruler_origin(
    doc: *const RzDocument,
    out_xy: *mut c_double,
) -> bool {
    if out_xy.is_null() {
        return false;
    }
    unsafe {
        doc_get(doc, false, |d| {
            let origin = [d.ruler_origin.0, d.ruler_origin.1];
            ptr::copy_nonoverlapping(origin.as_ptr(), out_xy, origin.len());
            Some(true)
        })
    }
}

/// Moves the ruler zero point to canvas (x, y). NULL on a NULL doc, a
/// non-finite component, a point outside the canvas, or the origin the
/// document already has.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_set_ruler_origin(
    doc: *const RzDocument,
    x: c_double,
    y: c_double,
) -> *mut RzDocument {
    unsafe { doc_op(doc, |d| d.set_ruler_origin(x, y)) }
}
