//! C FFI for layer GROUPS, LOCKS and the structural ops (`rz_doc_*`): the
//! per-entry model getters and setters the layers panel and `get_document`
//! read, the content-bounds and hit-test queries align/distribute and the Move
//! tool's auto-select speak, and the two ops that create the shape
//! (`rz_doc_group_layers` / `rz_doc_ungroup_layer`) plus the structural move,
//! and the SET operations every multi-selection folds into one call — arrange,
//! link, move, transform, duplicate, remove, merge, align, distribute — with
//! Merge Visible, Stamp Visible and Layer Via Copy / Via Cut.
//! Same conventions as `ffi_doc`: everything routes through `ffi_util`, so
//! catch_unwind, NULL tolerance and the produce-or-NULL mapping are written
//! once, and a caller's index list goes through `ffi_util::index_slice`, which
//! refuses a NULL pointer, an empty or over-long list, an out-of-range index
//! and a repeat.

use std::ffi::{c_char, c_double, c_int};
use std::ptr;

use crate::doc::{LayerKind, RzDocument};
use crate::doc_align::AlignEdge;
use crate::doc_group::subtree;
use crate::doc_lock::EditKind;
use crate::doc_structure::Arrange;
use crate::doc_transform::Affine;
use crate::ffi_util::{
    doc_get, doc_op, filter_from_c, index_slice, mask_slice, read_cstr, write_indices,
};

/// True when entry `idx` is a GROUP; false on NULL doc, an out-of-range idx or
/// a raster layer.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_layer_is_group(doc: *const RzDocument, idx: usize) -> bool {
    unsafe {
        doc_get(doc, false, |d| {
            Some(d.layers.get(idx)?.kind == LayerKind::Group)
        })
    }
}

/// Entry `idx`'s nesting depth (0 at the top level); 0 on NULL doc or an
/// out-of-range idx.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_layer_depth(doc: *const RzDocument, idx: usize) -> u32 {
    unsafe { doc_get(doc, 0, |d| Some(u32::from(d.layers.get(idx)?.depth))) }
}

/// Entry `idx`'s subtree as the half-open range `[*out_start, *out_end)`;
/// `*out_end` is exactly where a new sibling inserted "above" this entry
/// lands. False (and nothing written) on NULL doc or an out-of-range idx.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`; `out_start`
/// and `out_end` must be NULL or valid pointers to writable `size_t`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_layer_subtree(
    doc: *const RzDocument,
    idx: usize,
    out_start: *mut usize,
    out_end: *mut usize,
) -> bool {
    let range = unsafe {
        doc_get(doc, None, |d| {
            d.layers.get(idx)?;
            Some(Some(subtree(&d.layers, idx)))
        })
    };
    let Some(range) = range else {
        return false;
    };
    unsafe {
        if !out_start.is_null() {
            *out_start = range.start;
        }
        if !out_end.is_null() {
            *out_end = range.end;
        }
    }
    true
}

/// Entry `idx`'s lock flags (an RzLockFlags bitmask); 0 on NULL doc or an
/// out-of-range idx.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_layer_locks(doc: *const RzDocument, idx: usize) -> u32 {
    unsafe { doc_get(doc, 0, |d| Some(d.layers.get(idx)?.locks)) }
}

/// Pure setter: returns a new document with entry `idx`'s lock flags replaced
/// (reserved bits masked off). NULL on NULL doc or an out-of-range idx.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_with_layer_locks(
    doc: *const RzDocument,
    idx: usize,
    locks: u32,
) -> *mut RzDocument {
    unsafe { doc_op(doc, |d| d.with_layer_locks(idx, locks)) }
}

/// Which of entry `idx`'s lock bits would block an edit of `kind`
/// (0 = allowed). 0 on NULL doc, an out-of-range idx or an unknown `kind`.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_lock_block(doc: *const RzDocument, idx: usize, kind: c_int) -> u32 {
    unsafe { doc_get(doc, 0, |d| Some(d.lock_block(idx, EditKind::from_c(kind)?))) }
}

/// Entry `idx`'s link-group id (0 = unlinked); 0 on NULL doc or an
/// out-of-range idx.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_layer_link(doc: *const RzDocument, idx: usize) -> u32 {
    unsafe { doc_get(doc, 0, |d| Some(d.layers.get(idx)?.link)) }
}

/// Whether GROUP `idx` is shown expanded in the panel; false on NULL doc or an
/// out-of-range idx. Meaningless on a raster entry, which always answers true.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_layer_open(doc: *const RzDocument, idx: usize) -> bool {
    unsafe { doc_get(doc, false, |d| Some(d.layers.get(idx)?.open)) }
}

/// Pure setter: returns a new document with GROUP `idx` expanded or
/// collapsed. NULL on NULL doc, an out-of-range idx or a raster entry.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_with_layer_open(
    doc: *const RzDocument,
    idx: usize,
    open: bool,
) -> *mut RzDocument {
    unsafe { doc_op(doc, |d| d.with_layer_open(idx, open)) }
}

/// Entry `idx`'s CONTENT bounds — the canvas box of its opaque pixels, its
/// enabled mask applied, and for a group the union over its raster
/// descendants — written to `out_xywh` as x, y, width, height. False (and
/// nothing written) on NULL doc, an out-of-range idx, or an entry with nothing
/// opaque in it. Width and height are clamped into the i32 range, which no
/// document within the canvas cap can reach.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`; `out_xywh`
/// must be NULL or valid for four `int32_t` writes.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_layer_bounds(
    doc: *const RzDocument,
    idx: usize,
    out_xywh: *mut i32,
) -> bool {
    let bounds = unsafe { doc_get(doc, None, |d| Some(d.layer_bounds(idx))) };
    let Some((x, y, w, h)) = bounds else {
        return false;
    };
    if !out_xywh.is_null() {
        let values = [
            x,
            y,
            i32::try_from(w).unwrap_or(i32::MAX),
            i32::try_from(h).unwrap_or(i32::MAX),
        ];
        for (i, &value) in values.iter().enumerate() {
            unsafe { *out_xywh.add(i) = value };
        }
    }
    true
}

/// The entry a click at canvas position `(x, y)` activates — the topmost one
/// whose own coverage there is at least half — written to `out_idx`. With
/// `top_level` the answer is that entry's top-level ancestor (Auto-Select:
/// Group). False (and nothing written) on NULL doc or when nothing is hit; the
/// caller then leaves its selection alone rather than emptying it.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`; `out_idx`
/// must be NULL or a valid pointer to a writable `size_t`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_layer_at(
    doc: *const RzDocument,
    x: i32,
    y: i32,
    top_level: bool,
    out_idx: *mut usize,
) -> bool {
    let hit = unsafe { doc_get(doc, None, |d| Some(d.layer_at(x, y, top_level))) };
    let Some(hit) = hit else {
        return false;
    };
    if !out_idx.is_null() {
        unsafe { *out_idx = hit };
    }
    true
}

/// Wraps the given entries — which must all share one parent — in a new group
/// named `name`, whose index comes back through `out_group`.
///
/// `out_cleared_clip` and `out_reordered` are optional caller buffers of
/// `out_cap` `size_t` each, receiving the NEW indices of the entries whose
/// clipped flag was cleared and of the entries whose relative order changed
/// (see `rz_doc_group_layers` in the header). Their true lengths come back
/// through `out_cleared_len` / `out_reordered_len` whether or not the buffers
/// are given, so a caller can tell a truncated answer from a complete one; a
/// buffer of `rz_doc_layer_count` entries can never truncate.
///
/// NULL on NULL doc or name, an empty, out-of-range or repeating index list,
/// entries that do not share one parent, and a nesting that would pass the
/// depth cap.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`; `idx` must be
/// NULL or valid for `len` `size_t` values; `name` must be NULL or a valid
/// NUL-terminated C string; each out pointer must be NULL or valid for the
/// writes described above.
#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn rz_doc_group_layers(
    doc: *const RzDocument,
    idx: *const usize,
    len: usize,
    name: *const c_char,
    out_group: *mut usize,
    out_cleared_clip: *mut usize,
    out_cleared_len: *mut usize,
    out_reordered: *mut usize,
    out_reordered_len: *mut usize,
    out_cap: usize,
) -> *mut RzDocument {
    let Ok(name) = (unsafe { read_cstr(name, "name") }) else {
        return ptr::null_mut();
    };
    let mut group = 0usize;
    let mut cleared = Vec::new();
    let mut reordered = Vec::new();
    let out = unsafe {
        doc_op(doc, |d| {
            let indices = index_slice(idx, len, d.layers.len())?;
            let (out, new_group, new_cleared, new_reordered) = d.group_layers(&indices, &name)?;
            group = new_group;
            cleared = new_cleared;
            reordered = new_reordered;
            Some(out)
        })
    };
    if out.is_null() {
        return out;
    }
    unsafe {
        if !out_group.is_null() {
            *out_group = group;
        }
        write_indices(&cleared, out_cleared_clip, out_cap, out_cleared_len);
        write_indices(&reordered, out_reordered, out_cap, out_reordered_len);
    }
    out
}

/// Dissolves group `idx`, its children taking its depth and its slot. NULL on
/// NULL doc, an out-of-range idx, a raster entry, or when the document would
/// be left with no entries at all.
///
/// `out_cleared_clip` is an optional caller buffer of `out_cap` `size_t`
/// receiving the NEW indices of the entries whose clipped flag was cleared —
/// at most one, the bottom-most child (see `rz_doc_ungroup_layer` in the
/// header). Its true length comes back through `out_cleared_len` whether or
/// not the buffer is given, exactly as `rz_doc_group_layers` reports its own.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`; each out
/// pointer must be NULL or valid for the writes described above.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_ungroup_layer(
    doc: *const RzDocument,
    idx: usize,
    out_cleared_clip: *mut usize,
    out_cleared_len: *mut usize,
    out_cap: usize,
) -> *mut RzDocument {
    let mut cleared = Vec::new();
    let out = unsafe {
        doc_op(doc, |d| {
            let (out, new_cleared) = d.ungroup_layer(idx)?;
            cleared = new_cleared;
            Some(out)
        })
    };
    if out.is_null() {
        return out;
    }
    unsafe { write_indices(&cleared, out_cleared_clip, out_cap, out_cleared_len) };
    out
}

/// The structural move: the entry at `from` and its whole subtree land at
/// index `to` — an index into the stack with that subtree already taken out —
/// at `depth`. NULL on NULL doc, an out-of-range index, a move into the
/// entry's own subtree, a depth past the cap, or any `(to, depth)` pair whose
/// result would be a malformed structure.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_move_layer_to(
    doc: *const RzDocument,
    from: usize,
    to: usize,
    depth: u32,
) -> *mut RzDocument {
    unsafe {
        doc_op(doc, |d| {
            // `move_layer_to`'s own cap check covers every legal value, so an
            // absurd depth only has to fail the narrowing.
            d.move_layer_to(from, to, u16::try_from(depth).ok()?)
        })
    }
}

/// Moves entry `idx` among its SIBLINGS only. NULL on NULL doc, an
/// out-of-range idx, an unknown `how`, or when the entry is already there.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_arrange_layer(
    doc: *const RzDocument,
    idx: usize,
    how: c_int,
) -> *mut RzDocument {
    unsafe { doc_op(doc, |d| d.arrange_layer(idx, Arrange::from_c(how)?)) }
}

/// Links the given entries under the smallest unused non-zero id. NULL on
/// NULL doc, a list shorter than two, an out-of-range or repeating index, or
/// when nothing would change.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`; `idx` must be
/// NULL or valid for `len` `size_t` values.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_link_layers(
    doc: *const RzDocument,
    idx: *const usize,
    len: usize,
) -> *mut RzDocument {
    unsafe {
        doc_op(doc, |d| {
            d.link_layers(&index_slice(idx, len, d.layers.len())?)
        })
    }
}

/// Clears the given entries' link ids. NULL on NULL doc, an empty,
/// out-of-range or repeating list, or when nothing would change.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`; `idx` must be
/// NULL or valid for `len` `size_t` values.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_unlink_layers(
    doc: *const RzDocument,
    idx: *const usize,
    len: usize,
) -> *mut RzDocument {
    unsafe {
        doc_op(doc, |d| {
            d.unlink_layers(&index_slice(idx, len, d.layers.len())?)
        })
    }
}

/// Translates every given entry (subtrees and link groups expanded) by
/// `(dx, dy)`. NULL on NULL doc, an empty, out-of-range or repeating list, a
/// zero delta, a position lock anywhere in the expanded set, or a set with no
/// raster entry in it.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`; `idx` must be
/// NULL or valid for `len` `size_t` values.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_move_layers(
    doc: *const RzDocument,
    idx: *const usize,
    len: usize,
    dx: i32,
    dy: i32,
) -> *mut RzDocument {
    unsafe {
        doc_op(doc, |d| {
            d.move_layers(&index_slice(idx, len, d.layers.len())?, dx, dy)
        })
    }
}

/// The same affine — six doubles, as in `rz_doc_transform_layer` — applied to
/// every given entry, each deriving its own destination extent;
/// all-or-nothing. NULL on NULL doc or affine, an empty, out-of-range or
/// repeating list, an unknown sampler, a position lock, or any entry the
/// transform itself refuses.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`; `idx` must be
/// NULL or valid for `len` `size_t` values; `affine` must be NULL or a valid
/// pointer to at least six readable doubles.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_transform_layers(
    doc: *const RzDocument,
    idx: *const usize,
    len: usize,
    affine: *const c_double,
    filter: c_int,
) -> *mut RzDocument {
    if affine.is_null() {
        return ptr::null_mut();
    }
    // The element count is fixed by the contract (six), never a caller-
    // supplied length, so the slice is bounded before anything reads it.
    let m = unsafe { std::slice::from_raw_parts(affine, 6) };
    let m = Affine::from_array([m[0], m[1], m[2], m[3], m[4], m[5]]);
    unsafe {
        doc_op(doc, |d| {
            let indices = index_slice(idx, len, d.layers.len())?;
            d.transform_layers(&indices, m, filter_from_c(filter)?)
        })
    }
}

/// The same affine applied to the WHOLE stack — the Crop tool's straighten.
/// Per-entry POSITION locks do NOT gate it: straightening is a document
/// geometry op, in the same family as `rz_doc_crop` / `rz_doc_geometry` /
/// `rz_doc_resize`, none of which consults a layer lock either. NULL on NULL
/// doc or affine, an unknown sampler, any entry the transform itself refuses,
/// and a stack where nothing would change.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`; `affine`
/// must be NULL or a valid pointer to at least six readable doubles.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_straighten_layers(
    doc: *const RzDocument,
    affine: *const c_double,
    filter: c_int,
) -> *mut RzDocument {
    if affine.is_null() {
        return ptr::null_mut();
    }
    // The element count is fixed by the contract (six), never a caller-
    // supplied length, so the slice is bounded before anything reads it.
    let m = unsafe { std::slice::from_raw_parts(affine, 6) };
    let m = Affine::from_array([m[0], m[1], m[2], m[3], m[4], m[5]]);
    unsafe { doc_op(doc, |d| d.straighten_layers(m, filter_from_c(filter)?)) }
}

/// Duplicates every given entry (subtrees included), each copy immediately
/// above its original. NULL on NULL doc or an empty, out-of-range or
/// repeating list.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`; `idx` must be
/// NULL or valid for `len` `size_t` values.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_duplicate_layers(
    doc: *const RzDocument,
    idx: *const usize,
    len: usize,
) -> *mut RzDocument {
    unsafe {
        doc_op(doc, |d| {
            d.duplicate_layers(&index_slice(idx, len, d.layers.len())?)
        })
    }
}

/// Removes every given entry (subtrees included). NULL on NULL doc, an empty,
/// out-of-range or repeating list, or when the call would leave the document
/// with no entries at all.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`; `idx` must be
/// NULL or valid for `len` `size_t` values.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_remove_layers(
    doc: *const RzDocument,
    idx: *const usize,
    len: usize,
) -> *mut RzDocument {
    unsafe {
        doc_op(doc, |d| {
            d.remove_layers(&index_slice(idx, len, d.layers.len())?)
        })
    }
}

/// Merges the given entries — which must share one parent — into ONE raster
/// entry at the lowest member's slot. NULL on NULL doc, a list shorter than
/// two, an out-of-range or repeating index, entries at different levels, a
/// hidden lowest member, or a union extent that is empty or over the pixel
/// cap.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`; `idx` must be
/// NULL or valid for `len` `size_t` values.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_merge_layers(
    doc: *const RzDocument,
    idx: *const usize,
    len: usize,
) -> *mut RzDocument {
    unsafe {
        doc_op(doc, |d| {
            d.merge_layers(&index_slice(idx, len, d.layers.len())?)
        })
    }
}

/// Aligns the given entries' CONTENT bounds to `edge` of the selection's union
/// (or of the canvas with `to_canvas`). NULL on NULL doc, an empty,
/// out-of-range or repeating list, an unknown `edge`, fewer than two entries
/// with content when `to_canvas` is false, a position lock, or when nothing
/// would move.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`; `idx` must be
/// NULL or valid for `len` `size_t` values.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_align_layers(
    doc: *const RzDocument,
    idx: *const usize,
    len: usize,
    edge: c_int,
    to_canvas: bool,
) -> *mut RzDocument {
    unsafe {
        doc_op(doc, |d| {
            let indices = index_slice(idx, len, d.layers.len())?;
            d.align_layers(&indices, AlignEdge::from_c(edge)?, to_canvas)
        })
    }
}

/// Spaces the given entries evenly along one axis. NULL on NULL doc, an empty,
/// out-of-range or repeating list, fewer than three entries with content, a
/// position lock, or when nothing would move.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`; `idx` must be
/// NULL or valid for `len` `size_t` values.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_distribute_layers(
    doc: *const RzDocument,
    idx: *const usize,
    len: usize,
    vertical: bool,
) -> *mut RzDocument {
    unsafe {
        doc_op(doc, |d| {
            d.distribute_layers(&index_slice(idx, len, d.layers.len())?, vertical)
        })
    }
}

/// Replaces every entry that CONTRIBUTES to the projection with ONE
/// canvas-sized raster entry holding it; every entry that does not contribute
/// survives. NULL on NULL doc and when fewer than two LEAF entries contribute.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_merge_visible(doc: *const RzDocument) -> *mut RzDocument {
    unsafe { doc_op(doc, |d| d.merge_visible()) }
}

/// Adds the visible projection as a new canvas-sized raster entry immediately
/// above `above_idx`'s subtree, at that entry's depth. NULL on NULL doc or
/// name, or an out-of-range index.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`; `name` must
/// be NULL or a valid NUL-terminated C string.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_stamp_visible(
    doc: *const RzDocument,
    above_idx: usize,
    name: *const c_char,
) -> *mut RzDocument {
    let Ok(name) = (unsafe { read_cstr(name, "name") }) else {
        return ptr::null_mut();
    };
    unsafe { doc_op(doc, |d| d.stamp_visible(above_idx, &name)) }
}

/// Layer Via Copy / Via Cut: the source's pixels weighted by a canvas-sized
/// coverage mask (or the whole layer when `mask` is NULL) as a new raster
/// entry above the source. This op RASTERIZES — no meta, no style. NULL on
/// NULL doc or name, an out-of-range idx, a group, an adjustment layer, `w`/`h`
/// that are not the canvas size, or a coverage that selects nothing inside the
/// layer.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`; `mask` must
/// be NULL or valid for `w * h` bytes; `name` must be NULL or a valid
/// NUL-terminated C string.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_layer_via(
    doc: *const RzDocument,
    idx: usize,
    mask: *const u8,
    w: u32,
    h: u32,
    cut: bool,
    name: *const c_char,
) -> *mut RzDocument {
    let Ok(name) = (unsafe { read_cstr(name, "name") }) else {
        return ptr::null_mut();
    };
    unsafe {
        doc_op(doc, |d| {
            // The declared dimensions must BE the canvas's before a byte is
            // read, so the slice length comes from the core's own numbers.
            if w != d.width || h != d.height {
                return None;
            }
            let coverage = if mask.is_null() {
                None
            } else {
                let n = (w as usize).checked_mul(h as usize)?;
                Some(mask_slice(mask, n)?)
            };
            d.layer_via(idx, coverage, cut, &name)
        })
    }
}
