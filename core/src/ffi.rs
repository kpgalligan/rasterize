//! C FFI layer implementing `include/rasterize_core.h` exactly.
//!
//! Every function is panic-safe: bodies run under [`catch_unwind`] so no
//! unwinding ever crosses the FFI boundary. Panics become NULL/0/false
//! returns (with an error message where the contract provides `err_out`).
//! NULL handles are always tolerated.

use std::ffi::{c_char, c_int, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr;

use image::imageops::FilterType;

use crate::{ops, Format, RzImage};

/// Stores a heap-allocated copy of `msg` through `err_out` (if non-NULL).
/// Interior NUL bytes are replaced so the `CString` conversion cannot fail.
///
/// # Safety
/// `err_out` must be NULL or a valid pointer to writable `*mut c_char`.
unsafe fn set_err(err_out: *mut *mut c_char, msg: &str) {
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

/// Runs a pure operation against `img`, boxing the produced image.
/// NULL input, `None`, or a panic all yield NULL.
///
/// # Safety
/// `img` must be NULL or a valid pointer to a live `RzImage`.
unsafe fn pure_op<F>(img: *const RzImage, op: F) -> *mut RzImage
where
    F: FnOnce(&RzImage) -> Option<RzImage>,
{
    if img.is_null() {
        return ptr::null_mut();
    }
    let image = unsafe { &*img };
    match catch_unwind(AssertUnwindSafe(|| op(image))) {
        Ok(Some(result)) => Box::into_raw(Box::new(result)),
        _ => ptr::null_mut(),
    }
}

/// Opens the image file at `path` (UTF-8), sniffing the container format;
/// `8BPS` files decode as flattened Photoshop composites. Returns NULL on
/// failure and writes a message through `err_out` (caller frees with
/// [`rz_string_free`]).
///
/// # Safety
/// `path` must be NULL or a valid NUL-terminated C string; `err_out` must be
/// NULL or a valid pointer to writable `*mut c_char`.
#[no_mangle]
pub unsafe extern "C" fn rz_image_open(
    path: *const c_char,
    err_out: *mut *mut c_char,
) -> *mut RzImage {
    let outcome = catch_unwind(AssertUnwindSafe(|| {
        if path.is_null() {
            return Err("path is NULL".to_string());
        }
        let path = unsafe { CStr::from_ptr(path) }
            .to_str()
            .map_err(|_| "path is not valid UTF-8".to_string())?;
        RzImage::open(path)
    }));
    match outcome {
        Ok(Ok(img)) => Box::into_raw(Box::new(img)),
        Ok(Err(msg)) => {
            unsafe { set_err(err_out, &msg) };
            ptr::null_mut()
        }
        Err(_) => {
            unsafe { set_err(err_out, "internal error: panic while opening image") };
            ptr::null_mut()
        }
    }
}

/// Deep copy. Returns NULL only if `img` is NULL.
///
/// # Safety
/// `img` must be NULL or a valid pointer to a live `RzImage`.
#[no_mangle]
pub unsafe extern "C" fn rz_image_clone(img: *const RzImage) -> *mut RzImage {
    unsafe {
        pure_op(img, |i| {
            Some(RzImage {
                pixels: i.pixels.clone(),
            })
        })
    }
}

/// Frees an image. NULL is a safe no-op.
///
/// # Safety
/// `img` must be NULL or a pointer previously returned by this library that
/// has not yet been freed.
#[no_mangle]
pub unsafe extern "C" fn rz_image_free(img: *mut RzImage) {
    if img.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| drop(unsafe { Box::from_raw(img) })));
}

/// Image width in pixels; 0 if `img` is NULL.
///
/// # Safety
/// `img` must be NULL or a valid pointer to a live `RzImage`.
#[no_mangle]
pub unsafe extern "C" fn rz_image_width(img: *const RzImage) -> u32 {
    if img.is_null() {
        return 0;
    }
    let image = unsafe { &*img };
    catch_unwind(AssertUnwindSafe(|| image.pixels.width())).unwrap_or(0)
}

/// Image height in pixels; 0 if `img` is NULL.
///
/// # Safety
/// `img` must be NULL or a valid pointer to a live `RzImage`.
#[no_mangle]
pub unsafe extern "C" fn rz_image_height(img: *const RzImage) -> u32 {
    if img.is_null() {
        return 0;
    }
    let image = unsafe { &*img };
    catch_unwind(AssertUnwindSafe(|| image.pixels.height())).unwrap_or(0)
}

/// Borrowed pointer to `width * height * 4` bytes of non-premultiplied RGBA8,
/// valid until the image is freed. NULL if `img` is NULL.
///
/// # Safety
/// `img` must be NULL or a valid pointer to a live `RzImage`.
#[no_mangle]
pub unsafe extern "C" fn rz_image_pixels_rgba(img: *const RzImage) -> *const u8 {
    if img.is_null() {
        return ptr::null();
    }
    let image = unsafe { &*img };
    catch_unwind(AssertUnwindSafe(|| image.pixels.as_raw().as_ptr())).unwrap_or(ptr::null())
}

/// Rotates 90 degrees clockwise.
///
/// # Safety
/// `img` must be NULL or a valid pointer to a live `RzImage`.
#[no_mangle]
pub unsafe extern "C" fn rz_image_rotate90(img: *const RzImage) -> *mut RzImage {
    unsafe {
        pure_op(img, |i| {
            Some(RzImage {
                pixels: ops::rotate90(&i.pixels),
            })
        })
    }
}

/// Rotates 180 degrees.
///
/// # Safety
/// `img` must be NULL or a valid pointer to a live `RzImage`.
#[no_mangle]
pub unsafe extern "C" fn rz_image_rotate180(img: *const RzImage) -> *mut RzImage {
    unsafe {
        pure_op(img, |i| {
            Some(RzImage {
                pixels: ops::rotate180(&i.pixels),
            })
        })
    }
}

/// Rotates 90 degrees counter-clockwise.
///
/// # Safety
/// `img` must be NULL or a valid pointer to a live `RzImage`.
#[no_mangle]
pub unsafe extern "C" fn rz_image_rotate270(img: *const RzImage) -> *mut RzImage {
    unsafe {
        pure_op(img, |i| {
            Some(RzImage {
                pixels: ops::rotate270(&i.pixels),
            })
        })
    }
}

/// Mirrors left-right.
///
/// # Safety
/// `img` must be NULL or a valid pointer to a live `RzImage`.
#[no_mangle]
pub unsafe extern "C" fn rz_image_flip_horizontal(img: *const RzImage) -> *mut RzImage {
    unsafe {
        pure_op(img, |i| {
            Some(RzImage {
                pixels: ops::flip_horizontal(&i.pixels),
            })
        })
    }
}

/// Mirrors top-bottom.
///
/// # Safety
/// `img` must be NULL or a valid pointer to a live `RzImage`.
#[no_mangle]
pub unsafe extern "C" fn rz_image_flip_vertical(img: *const RzImage) -> *mut RzImage {
    unsafe {
        pure_op(img, |i| {
            Some(RzImage {
                pixels: ops::flip_vertical(&i.pixels),
            })
        })
    }
}

/// Crops to the given rect; NULL if the rect is empty or out of bounds.
///
/// # Safety
/// `img` must be NULL or a valid pointer to a live `RzImage`.
#[no_mangle]
pub unsafe extern "C" fn rz_image_crop(
    img: *const RzImage,
    x: u32,
    y: u32,
    w: u32,
    h: u32,
) -> *mut RzImage {
    unsafe {
        pure_op(img, |i| {
            ops::crop(&i.pixels, x, y, w, h).map(|pixels| RzImage { pixels })
        })
    }
}

/// Resizes to `w` x `h`; NULL if a dimension is zero, the target is over
/// 100000000 pixels, or the filter value is unknown.
///
/// # Safety
/// `img` must be NULL or a valid pointer to a live `RzImage`.
#[no_mangle]
pub unsafe extern "C" fn rz_image_resize(
    img: *const RzImage,
    w: u32,
    h: u32,
    filter: c_int,
) -> *mut RzImage {
    unsafe {
        pure_op(img, |i| {
            let filter = match filter {
                0 => FilterType::Nearest,
                1 => FilterType::Triangle,
                2 => FilterType::CatmullRom,
                3 => FilterType::Lanczos3,
                _ => return None,
            };
            ops::resize(&i.pixels, w, h, filter).map(|pixels| RzImage { pixels })
        })
    }
}

/// Applies brightness, contrast, then saturation (each clamped to [-1, 1],
/// 0 = identity). Alpha untouched.
///
/// # Safety
/// `img` must be NULL or a valid pointer to a live `RzImage`.
#[no_mangle]
pub unsafe extern "C" fn rz_image_adjust(
    img: *const RzImage,
    brightness: f32,
    contrast: f32,
    saturation: f32,
) -> *mut RzImage {
    unsafe {
        pure_op(img, |i| {
            Some(RzImage {
                pixels: ops::adjust(&i.pixels, brightness, contrast, saturation),
            })
        })
    }
}

/// Converts to grayscale (r = g = b = luma), alpha untouched.
///
/// # Safety
/// `img` must be NULL or a valid pointer to a live `RzImage`.
#[no_mangle]
pub unsafe extern "C" fn rz_image_grayscale(img: *const RzImage) -> *mut RzImage {
    unsafe {
        pure_op(img, |i| {
            Some(RzImage {
                pixels: ops::grayscale(&i.pixels),
            })
        })
    }
}

/// Inverts the color channels, alpha untouched.
///
/// # Safety
/// `img` must be NULL or a valid pointer to a live `RzImage`.
#[no_mangle]
pub unsafe extern "C" fn rz_image_invert(img: *const RzImage) -> *mut RzImage {
    unsafe {
        pure_op(img, |i| {
            Some(RzImage {
                pixels: ops::invert(&i.pixels),
            })
        })
    }
}

/// Applies the standard sepia matrix, alpha untouched.
///
/// # Safety
/// `img` must be NULL or a valid pointer to a live `RzImage`.
#[no_mangle]
pub unsafe extern "C" fn rz_image_sepia(img: *const RzImage) -> *mut RzImage {
    unsafe {
        pure_op(img, |i| {
            Some(RzImage {
                pixels: ops::sepia(&i.pixels),
            })
        })
    }
}

/// Gaussian blur; NULL if `sigma` is not finite or not positive.
///
/// # Safety
/// `img` must be NULL or a valid pointer to a live `RzImage`.
#[no_mangle]
pub unsafe extern "C" fn rz_image_blur(img: *const RzImage, sigma: f32) -> *mut RzImage {
    unsafe {
        pure_op(img, |i| {
            ops::blur(&i.pixels, sigma).map(|pixels| RzImage { pixels })
        })
    }
}

/// Unsharp-mask sharpen with `amount` clamped to (0, 5]; NULL if `amount` is
/// not finite or not positive.
///
/// # Safety
/// `img` must be NULL or a valid pointer to a live `RzImage`.
#[no_mangle]
pub unsafe extern "C" fn rz_image_sharpen(img: *const RzImage, amount: f32) -> *mut RzImage {
    unsafe {
        pure_op(img, |i| {
            ops::sharpen(&i.pixels, amount).map(|pixels| RzImage { pixels })
        })
    }
}

/// Encodes the image to `path`. `jpeg_quality` (clamped to 1-100) applies to
/// JPEG only; JPEG output is composited over white. Returns false on failure
/// and writes a message through `err_out`.
///
/// # Safety
/// `img` must be NULL or a valid pointer to a live `RzImage`; `path` must be
/// NULL or a valid NUL-terminated C string; `err_out` must be NULL or a valid
/// pointer to writable `*mut c_char`.
#[no_mangle]
pub unsafe extern "C" fn rz_image_save(
    img: *const RzImage,
    path: *const c_char,
    format: c_int,
    jpeg_quality: u8,
    err_out: *mut *mut c_char,
) -> bool {
    let outcome = catch_unwind(AssertUnwindSafe(|| {
        if img.is_null() {
            return Err("image is NULL".to_string());
        }
        if path.is_null() {
            return Err("path is NULL".to_string());
        }
        let image = unsafe { &*img };
        let path = unsafe { CStr::from_ptr(path) }
            .to_str()
            .map_err(|_| "path is not valid UTF-8".to_string())?;
        let format =
            Format::from_c(format).ok_or_else(|| format!("unknown format value {format}"))?;
        image.save(path, format, jpeg_quality)
    }));
    match outcome {
        Ok(Ok(())) => true,
        Ok(Err(msg)) => {
            unsafe { set_err(err_out, &msg) };
            false
        }
        Err(_) => {
            unsafe { set_err(err_out, "internal error: panic while saving image") };
            false
        }
    }
}

/// Frees strings returned via `err_out` parameters. NULL is a safe no-op.
///
/// # Safety
/// `s` must be NULL or a string pointer previously produced by this library
/// that has not yet been freed.
#[no_mangle]
pub unsafe extern "C" fn rz_string_free(s: *mut c_char) {
    if s.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| drop(unsafe { CString::from_raw(s) })));
}

/// Static version string; the caller must not free it.
#[no_mangle]
pub extern "C" fn rz_core_version() -> *const c_char {
    c"0.1.0".as_ptr()
}
