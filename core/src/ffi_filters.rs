//! C FFI for the additional filters (`rz_image_hue_rotate` etc.), following
//! the conventions of `ffi`.
//!
//! Every function is panic-safe: bodies run under [`catch_unwind`] so no
//! unwinding ever crosses the FFI boundary. NULL images and invalid
//! arguments yield NULL results.

use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr;

use crate::{ops_filters, RzImage};

/// Runs a pure operation against `img`, boxing the produced image.
/// NULL input, `None`, or a panic all yield NULL. (Private copy of the
/// equivalent helper in `ffi`.)
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

/// Rotates hue by `degrees` via the standard hue-rotation matrix. Any finite
/// value is accepted; NULL on NaN (or infinities). Alpha untouched.
///
/// # Safety
/// `img` must be NULL or a valid pointer to a live `RzImage`.
#[no_mangle]
pub unsafe extern "C" fn rz_image_hue_rotate(img: *const RzImage, degrees: f32) -> *mut RzImage {
    unsafe {
        pure_op(img, |i| {
            ops_filters::hue_rotate(&i.pixels, degrees).map(|pixels| RzImage { pixels })
        })
    }
}

/// Levels: maps [black, white] to [0, 1] then applies gamma
/// (`out = t^(1/gamma)`). NULL unless `0 <= black < white <= 1` and gamma is
/// in [0.1, 10]. Alpha untouched.
///
/// # Safety
/// `img` must be NULL or a valid pointer to a live `RzImage`.
#[no_mangle]
pub unsafe extern "C" fn rz_image_levels(
    img: *const RzImage,
    black: f32,
    white: f32,
    gamma: f32,
) -> *mut RzImage {
    unsafe {
        pure_op(img, |i| {
            ops_filters::levels(&i.pixels, black, white, gamma).map(|pixels| RzImage { pixels })
        })
    }
}

/// Luma threshold at `level` in [0, 1]: color channels become black or white
/// by Rec. 709 luma; NULL if `level` is NaN or out of range. Alpha untouched.
///
/// # Safety
/// `img` must be NULL or a valid pointer to a live `RzImage`.
#[no_mangle]
pub unsafe extern "C" fn rz_image_threshold(img: *const RzImage, level: f32) -> *mut RzImage {
    unsafe {
        pure_op(img, |i| {
            ops_filters::threshold(&i.pixels, level).map(|pixels| RzImage { pixels })
        })
    }
}

/// Reduces each color channel to `levels` evenly spaced values; NULL unless
/// `levels` is in 2..=64. Alpha untouched.
///
/// # Safety
/// `img` must be NULL or a valid pointer to a live `RzImage`.
#[no_mangle]
pub unsafe extern "C" fn rz_image_posterize(img: *const RzImage, levels: u32) -> *mut RzImage {
    unsafe {
        pure_op(img, |i| {
            ops_filters::posterize(&i.pixels, levels).map(|pixels| RzImage { pixels })
        })
    }
}

/// Mosaic of `block` x `block` cells (alpha-weighted mean color, plain mean
/// alpha); NULL unless `block` is in 1..=1024.
///
/// # Safety
/// `img` must be NULL or a valid pointer to a live `RzImage`.
#[no_mangle]
pub unsafe extern "C" fn rz_image_pixelate(img: *const RzImage, block: u32) -> *mut RzImage {
    unsafe {
        pure_op(img, |i| {
            ops_filters::pixelate(&i.pixels, block).map(|pixels| RzImage { pixels })
        })
    }
}

/// Additive uniform noise in [-amount, +amount] per color channel,
/// deterministic for a given `seed`; NULL unless `amount` is in (0, 1].
/// Alpha untouched.
///
/// # Safety
/// `img` must be NULL or a valid pointer to a live `RzImage`.
#[no_mangle]
pub unsafe extern "C" fn rz_image_noise(
    img: *const RzImage,
    amount: f32,
    seed: u64,
) -> *mut RzImage {
    unsafe {
        pure_op(img, |i| {
            ops_filters::noise(&i.pixels, amount, seed).map(|pixels| RzImage { pixels })
        })
    }
}

/// Sobel edge magnitude on luma, rendered as an opaque grayscale image.
///
/// # Safety
/// `img` must be NULL or a valid pointer to a live `RzImage`.
#[no_mangle]
pub unsafe extern "C" fn rz_image_edge_detect(img: *const RzImage) -> *mut RzImage {
    unsafe {
        pure_op(img, |i| {
            Some(RzImage {
                pixels: ops_filters::edge_detect(&i.pixels),
            })
        })
    }
}

/// Emboss: 3x3 directional relief kernel on luma around mid-gray, opaque.
///
/// # Safety
/// `img` must be NULL or a valid pointer to a live `RzImage`.
#[no_mangle]
pub unsafe extern "C" fn rz_image_emboss(img: *const RzImage) -> *mut RzImage {
    unsafe {
        pure_op(img, |i| {
            Some(RzImage {
                pixels: ops_filters::emboss(&i.pixels),
            })
        })
    }
}
