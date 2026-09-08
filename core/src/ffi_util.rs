//! Shared plumbing for the FFI shims (`ffi`, `ffi_doc`, `ffi_filters`,
//! `ffi_style`, `ffi_agent`, `ffi_assistant`): error reporting through
//! `err_out`, panic-safe wrappers, and the argument mappings every shim
//! needs. Nothing
//! here is exported through the C header — these are the helpers the
//! exported functions are built from, so the conventions (catch_unwind
//! everywhere, NULL tolerance, heap CString errors freed with
//! `rz_string_free`) live in ONE place.

use std::ffi::{c_char, c_int, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr;

use image::imageops::FilterType;

use crate::doc::RzDocument;
use crate::rzdc::MAX_RZDC_LAYERS;
use crate::RzImage;

/// Stores a heap-allocated copy of `msg` through `err_out` (if non-NULL).
/// Interior NUL bytes are replaced so the `CString` conversion cannot fail.
///
/// # Safety
/// `err_out` must be NULL or a valid pointer to writable `*mut c_char`.
pub(crate) unsafe fn set_err(err_out: *mut *mut c_char, msg: &str) {
    if err_out.is_null() {
        return;
    }
    let sanitized = msg.replace('\0', " ");
    let cstring = CString::new(sanitized)
        .unwrap_or_else(|_| CString::new("rasterize-core error").expect("static string"));
    unsafe {
        *err_out = cstring.into_raw();
    }
}

/// Reads a required C-string argument into an owned `String`, naming the
/// argument in the error ("`what` is NULL" / "`what` is not valid UTF-8").
///
/// # Safety
/// `ptr` must be NULL or a valid NUL-terminated C string.
pub(crate) unsafe fn read_cstr(ptr: *const c_char, what: &str) -> Result<String, String> {
    if ptr.is_null() {
        return Err(format!("{what} is NULL"));
    }
    unsafe { CStr::from_ptr(ptr) }
        .to_str()
        .map(str::to_owned)
        .map_err(|_| format!("{what} is not valid UTF-8"))
}

/// Boxes a value and leaks it as the raw handle the C side owns.
pub(crate) fn boxed<T>(value: T) -> *mut T {
    Box::into_raw(Box::new(value))
}

/// Runs a fallible FFI body under [`catch_unwind`], mapping `Ok` through
/// `success` and reporting failures through `err_out`: an `Err` message
/// passes through verbatim, a caught panic becomes the long-form
/// "internal error: `what`". Either failure returns `failure`.
///
/// # Safety
/// `err_out` must be NULL or a valid pointer to writable `*mut c_char`.
pub(crate) unsafe fn fallible_op<T, R>(
    err_out: *mut *mut c_char,
    what: &str,
    failure: R,
    body: impl FnOnce() -> Result<T, String>,
    success: impl FnOnce(T) -> R,
) -> R {
    match catch_unwind(AssertUnwindSafe(body)) {
        Ok(Ok(value)) => success(value),
        Ok(Err(msg)) => {
            unsafe { set_err(err_out, &msg) };
            failure
        }
        Err(_) => {
            unsafe { set_err(err_out, &format!("internal error: {what}")) };
            failure
        }
    }
}

/// Runs a producer that takes no handle, boxing what it makes: `None` or a
/// panic yield NULL. The constructor twin of [`pure_op`] — for exports whose
/// only inputs are plain values (`rz_image_from_rgba`) — and the one place
/// the produce-or-NULL mapping is written.
pub(crate) fn produce_op<T>(op: impl FnOnce() -> Option<T>) -> *mut T {
    match catch_unwind(AssertUnwindSafe(op)) {
        Ok(Some(result)) => boxed(result),
        _ => ptr::null_mut(),
    }
}

/// Runs a pure operation against `img`, boxing the produced image.
/// NULL input, `None`, or a panic all yield NULL.
///
/// # Safety
/// `img` must be NULL or a valid pointer to a live `RzImage`.
pub(crate) unsafe fn pure_op<F>(img: *const RzImage, op: F) -> *mut RzImage
where
    F: FnOnce(&RzImage) -> Option<RzImage>,
{
    if img.is_null() {
        return ptr::null_mut();
    }
    let image = unsafe { &*img };
    produce_op(|| op(image))
}

/// Runs a pure operation against `doc`, boxing the produced document.
/// NULL input, `None`, or a panic all yield NULL.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`.
pub(crate) unsafe fn doc_op<F>(doc: *const RzDocument, op: F) -> *mut RzDocument
where
    F: FnOnce(&RzDocument) -> Option<RzDocument>,
{
    if doc.is_null() {
        return ptr::null_mut();
    }
    let document = unsafe { &*doc };
    match catch_unwind(AssertUnwindSafe(|| op(document))) {
        Ok(Some(result)) => Box::into_raw(Box::new(result)),
        _ => ptr::null_mut(),
    }
}

/// Runs a pure query against `doc`, returning `default` for NULL input,
/// `None`, or a panic.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`.
pub(crate) unsafe fn doc_get<T, F>(doc: *const RzDocument, default: T, get: F) -> T
where
    F: FnOnce(&RzDocument) -> Option<T>,
{
    if doc.is_null() {
        return default;
    }
    let document = unsafe { &*doc };
    match catch_unwind(AssertUnwindSafe(|| get(document))) {
        Ok(Some(value)) => value,
        _ => default,
    }
}

/// The image twin of [`doc_get`]: a pure query against `img`, returning
/// `default` for NULL input, `None`, or a panic.
///
/// # Safety
/// `img` must be NULL or a valid pointer to a live `RzImage`.
pub(crate) unsafe fn img_get<T, F>(img: *const RzImage, default: T, get: F) -> T
where
    F: FnOnce(&RzImage) -> Option<T>,
{
    if img.is_null() {
        return default;
    }
    let image = unsafe { &*img };
    match catch_unwind(AssertUnwindSafe(|| get(image))) {
        Ok(Some(value)) => value,
        _ => default,
    }
}

/// Reads an optional caller buffer pointer (a canvas-sized selection mask, a
/// canvas-sized paint overlay, a canvas-sized plane) into a slice of exactly
/// `len` bytes. `len` is always derived from the core's own dimensions, never
/// from the caller.
///
/// # Safety
/// `buffer` must be NULL or valid for `len` bytes for the duration of the
/// caller.
pub(crate) unsafe fn mask_slice<'a>(buffer: *const u8, len: usize) -> Option<&'a [u8]> {
    if buffer.is_null() {
        None
    } else {
        Some(unsafe { std::slice::from_raw_parts(buffer, len) })
    }
}

/// A caller's list of layer indices, refused WHOLE (`None`) when the pointer
/// is NULL, `len` is 0 or past the format's layer cap, an index is not below
/// `count`, or an index repeats. A repeat is an error rather than a silent
/// dedupe because every set op renumbers: a caller that named an entry twice
/// has miscounted something, and answering it with a quietly different set
/// would hide that. Ascending on the way out, which is the order every
/// structural op wants.
///
/// # Safety
/// `ptr` must be NULL or valid for `len` `size_t` values for the duration of
/// the call.
pub(crate) unsafe fn index_slice(
    ptr: *const usize,
    len: usize,
    count: usize,
) -> Option<Vec<usize>> {
    if ptr.is_null() || len == 0 || len > MAX_RZDC_LAYERS as usize {
        return None;
    }
    let raw = unsafe { std::slice::from_raw_parts(ptr, len) };
    let mut out = raw.to_vec();
    out.sort_unstable();
    if out.windows(2).any(|w| w[0] == w[1]) || out.last().is_some_and(|&i| i >= count) {
        return None;
    }
    Some(out)
}

/// Writes as much of `values` as fits into a caller buffer of `cap` entries
/// and reports the TRUE length through `out_len`, so a caller can tell a
/// truncated answer from a complete one. A NULL buffer means "do not report
/// it" and is not an error.
///
/// # Safety
/// `buffer` must be NULL or valid for `cap` `size_t` writes; `out_len` must be
/// NULL or a valid pointer to a writable `size_t`.
pub(crate) unsafe fn write_indices(
    values: &[usize],
    buffer: *mut usize,
    cap: usize,
    out_len: *mut usize,
) {
    if !out_len.is_null() {
        unsafe { *out_len = values.len() };
    }
    if buffer.is_null() {
        return;
    }
    for (i, &value) in values.iter().take(cap).enumerate() {
        unsafe { *buffer.add(i) = value };
    }
}

/// Aspect-fit thumbnail dimensions with the longest side `max(1, max_side)`,
/// each at least 1 — the ONE sizing rule, shared by `rz_doc_layer_thumbnail`
/// and the plane-image getters. `w` and `h` must be non-zero (every caller
/// checks for an empty source first, since there is nothing to scale).
pub(crate) fn thumb_dims(w: u32, h: u32, max_side: u32) -> (u32, u32) {
    let side = max_side.max(1);
    if w >= h {
        let th = (f64::from(h) * f64::from(side) / f64::from(w)).round() as u32;
        (side, th.max(1))
    } else {
        let tw = (f64::from(w) * f64::from(side) / f64::from(h)).round() as u32;
        (tw.max(1), side)
    }
}

/// Maps a raw `RzResizeFilter` value — the ONE mapping shared by
/// `rz_image_resize`, `rz_doc_resize`, and the layer transform.
pub(crate) fn filter_from_c(value: c_int) -> Option<FilterType> {
    match value {
        0 => Some(FilterType::Nearest),
        1 => Some(FilterType::Triangle),
        2 => Some(FilterType::CatmullRom),
        3 => Some(FilterType::Lanczos3),
        _ => None,
    }
}
