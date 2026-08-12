//! Shared plumbing for the FFI shims (`ffi`, `ffi_doc`, `ffi_filters`,
//! `ffi_agent`, `ffi_assistant`): error reporting through `err_out`,
//! panic-safe wrappers, and the argument mappings every shim needs. Nothing
//! here is exported through the C header — these are the helpers the
//! exported functions are built from, so the conventions (catch_unwind
//! everywhere, NULL tolerance, heap CString errors freed with
//! `rz_string_free`) live in ONE place.

use std::ffi::{c_char, c_int, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr;

use image::imageops::FilterType;

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
