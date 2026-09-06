//! C FFI for retouching: healing (`rz_doc_heal_layer`), the two
//! content-aware inpainting entry points (`rz_doc_spot_heal_layer`,
//! `rz_doc_content_aware_fill`) and red-eye (`rz_doc_red_eye_layer`).
//!
//! Same conventions as `ffi_doc`: the shared helpers in `ffi_util` supply
//! catch_unwind and NULL tolerance, slice lengths are recomputed from the
//! core's own dimensions rather than trusted from the caller, and the three
//! ops that can refuse WITH a message go through `fallible_op` — `Ok(None)`
//! is NULL with no message (a domain refusal), `Err` is NULL with one.

use std::ffi::c_char;
use std::ptr;

use crate::doc::RzDocument;
use crate::ffi_util::{boxed, doc_op, fallible_op};

/// Poisson-blends the source patch `src` carries into layer `idx`: the
/// source's texture with the destination's illumination. `src` is the same
/// canvas-frame premultiplied overlay `rz_doc_painting_layer` takes (`w`/`h`
/// must equal the canvas size); its alpha is the footprint's coverage and
/// its RGB the already-aligned source. `strength` is clamped to [0, 1].
/// NULL with a message when one region's box exceeds the documented memory
/// limit, or when every region's box together exceeds the documented
/// working-area limit for one call — both measured before anything is
/// healed; NULL with no message on NULL args, dimension mismatch, non-finite
/// strength, out-of-range idx, an empty covered set, a layer extent that
/// misses the canvas, or when no pixel would change.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`; `src` must
/// be NULL or valid for `w * h * 4` bytes; `err_out` must be NULL or a valid
/// pointer to writable `*mut c_char`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_heal_layer(
    doc: *const RzDocument,
    idx: usize,
    src: *const u8,
    w: u32,
    h: u32,
    strength: f32,
    err_out: *mut *mut c_char,
) -> *mut RzDocument {
    let body = || -> Result<Option<RzDocument>, String> {
        if doc.is_null() || src.is_null() {
            return Ok(None);
        }
        let document = unsafe { &*doc };
        // Validate against the canvas dimensions before touching `src`, so
        // the raw read below is bounded by the canvas buffer size.
        if w != document.width || h != document.height {
            return Ok(None);
        }
        let Some(len) = (w as usize)
            .checked_mul(h as usize)
            .and_then(|n| n.checked_mul(4))
        else {
            return Ok(None);
        };
        let overlay = unsafe { std::slice::from_raw_parts(src, len) };
        document.heal_layer(idx, overlay, w, h, strength)
    };
    unsafe {
        fallible_op(
            err_out,
            "panic while healing",
            ptr::null_mut(),
            body,
            |out| out.map_or(ptr::null_mut(), boxed),
        )
    }
}

/// Spot healing: inpaints the overlay's footprint from a ring of valid
/// pixels around it, then Poisson-blends the result in exactly as
/// `rz_doc_heal_layer` does. Only the overlay's ALPHA is read. `ring` is the
/// sampling-ring width in px (0 = automatic), `seed` makes the result
/// reproducible, `sample_all` inpaints from the flattened composite, and
/// `preview` computes the whole pipeline on a reduced copy. NULL with a
/// message on a cap or a starved sample region; NULL with no message when
/// nothing would change.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`; `src` must
/// be NULL or valid for `w * h * 4` bytes; `err_out` must be NULL or a valid
/// pointer to writable `*mut c_char`.
// The parameter list mirrors the C declaration in `rasterize_core.h`
// one-for-one; bundling them into a struct would only move the count
// somewhere else.
#[allow(clippy::too_many_arguments)]
#[no_mangle]
pub unsafe extern "C" fn rz_doc_spot_heal_layer(
    doc: *const RzDocument,
    idx: usize,
    src: *const u8,
    w: u32,
    h: u32,
    strength: f32,
    ring: u32,
    seed: u64,
    sample_all: bool,
    preview: bool,
    err_out: *mut *mut c_char,
) -> *mut RzDocument {
    let body = || -> Result<Option<RzDocument>, String> {
        if doc.is_null() || src.is_null() {
            return Ok(None);
        }
        let document = unsafe { &*doc };
        if w != document.width || h != document.height {
            return Ok(None);
        }
        let Some(len) = (w as usize)
            .checked_mul(h as usize)
            .and_then(|n| n.checked_mul(4))
        else {
            return Ok(None);
        };
        let overlay = unsafe { std::slice::from_raw_parts(src, len) };
        document.spot_heal_layer(
            idx, overlay, w, h, strength, ring, seed, sample_all, preview,
        )
    };
    unsafe {
        fallible_op(
            err_out,
            "panic while spot healing",
            ptr::null_mut(),
            body,
            |out| out.map_or(ptr::null_mut(), boxed),
        )
    }
}

/// Content-Aware Fill: inpaints the region a canvas-sized u8 coverage mask
/// marks (the selection convention: 0 outside, 255 inside, intermediate =
/// anti-aliased edge), sampled from a ring around it, then Poisson-blends
/// the fill to the surrounding illumination. The mask's SOFT bytes weight
/// the write-back. `ring`/`seed`/`sample_all`/`preview` as
/// `rz_doc_spot_heal_layer`. NULL with a message on a cap or a starved
/// sample region; NULL with no message when nothing would change.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`; `mask` must
/// be NULL or valid for `w * h` bytes; `err_out` must be NULL or a valid
/// pointer to writable `*mut c_char`.
// The parameter list mirrors the C declaration in `rasterize_core.h`
// one-for-one; bundling them into a struct would only move the count
// somewhere else.
#[allow(clippy::too_many_arguments)]
#[no_mangle]
pub unsafe extern "C" fn rz_doc_content_aware_fill(
    doc: *const RzDocument,
    idx: usize,
    mask: *const u8,
    w: u32,
    h: u32,
    ring: u32,
    seed: u64,
    sample_all: bool,
    preview: bool,
    err_out: *mut *mut c_char,
) -> *mut RzDocument {
    let body = || -> Result<Option<RzDocument>, String> {
        if doc.is_null() || mask.is_null() {
            return Ok(None);
        }
        let document = unsafe { &*doc };
        if w != document.width || h != document.height {
            return Ok(None);
        }
        let Some(len) = (w as usize).checked_mul(h as usize) else {
            return Ok(None);
        };
        let coverage = unsafe { std::slice::from_raw_parts(mask, len) };
        document.content_aware_fill(idx, coverage, w, h, ring, seed, sample_all, preview)
    };
    unsafe {
        fallible_op(
            err_out,
            "panic while filling",
            ptr::null_mut(),
            body,
            |out| out.map_or(ptr::null_mut(), boxed),
        )
    }
}

/// Removes flash red inside a canvas rect on layer `idx`: red DOMINANCE
/// gated by saturation and hue, corrected only where a scoring component
/// fits within `pupil_size` times the rect's SHORTER side. `pupil_size` is a
/// fraction in (0, 1] (1.0 is the intended default) and `darken` is in
/// [0, 1] (0.5 = Photoshop's default). NULL on an empty or off-canvas rect,
/// out-of-range idx, non-finite parameters, no component within the
/// pupil-size limit, or when no pixel would change.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`.
// The parameter list mirrors the C declaration in `rasterize_core.h`
// one-for-one; bundling them into a struct would only move the count
// somewhere else.
#[allow(clippy::too_many_arguments)]
#[no_mangle]
pub unsafe extern "C" fn rz_doc_red_eye_layer(
    doc: *const RzDocument,
    idx: usize,
    x: i32,
    y: i32,
    w: u32,
    h: u32,
    pupil_size: f32,
    darken: f32,
) -> *mut RzDocument {
    unsafe {
        doc_op(doc, |d| {
            d.red_eye_layer(idx, x, y, w, h, pupil_size, darken)
        })
    }
}
