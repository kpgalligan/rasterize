//! C FFI for the adjustment ops, the image statistics and the Lab readout.
//! Same conventions as `ffi_doc` and `ffi_filters`: the shared helpers in
//! `ffi_util` supply `catch_unwind` and NULL tolerance, and the params JSON
//! is the contract documented in `adjust`'s schema table.
//!
//! There is exactly ONE destructive adjustment export,
//! [`rz_image_adjust_op`], covering every op. Twelve exports with up to
//! thirty-odd float parameters each is not a C surface anyone can maintain,
//! and — the structural win — the destructive path IS the adjustment-layer
//! path, so the two can never drift.

use std::ffi::{c_char, c_int, CString};
use std::ptr;

use serde_json::{Map, Value};

use crate::adjust::Adjustment;
use crate::adjust_lut;
use crate::adjust_math::apply_to_image;
use crate::doc::RzDocument;
use crate::ffi_util::{doc_get, fallible_op, img_get, mask_slice, pure_op, read_cstr};
use crate::ops_auto::{self, AutoMode};
use crate::ops_filters;
use crate::ops_stats;
use crate::RzImage;

/// Applies the adjustment `op` with `params_json` — the SAME object an
/// adjustment layer's meta carries — to `img`'s pixels, destructively.
/// `params_json` may be NULL for "every default". NULL with a message
/// through `err_out` when the op is unknown, the params are not valid
/// UTF-8/JSON/an object, or the parameters are not valid for the op; NULL
/// with NO message on a NULL image. Alpha untouched.
///
/// # Safety
/// `img` must be NULL or a valid pointer to a live `RzImage`; `op` and
/// `params_json` must be NULL or valid NUL-terminated C strings; `err_out`
/// must be NULL or a valid pointer to writable `*mut c_char`.
#[no_mangle]
pub unsafe extern "C" fn rz_image_adjust_op(
    img: *const RzImage,
    op: *const c_char,
    params_json: *const c_char,
    err_out: *mut *mut c_char,
) -> *mut RzImage {
    if img.is_null() {
        return ptr::null_mut();
    }
    let body = || -> Result<RzImage, String> {
        let name = unsafe { read_cstr(op, "op") }?;
        let parsed: Option<Value> = if params_json.is_null() {
            None
        } else {
            let text = unsafe { read_cstr(params_json, "params") }?;
            Some(
                serde_json::from_str(&text)
                    .map_err(|e| format!("params is not valid JSON: {e}"))?,
            )
        };
        let empty = Map::new();
        let params = match &parsed {
            None => &empty,
            Some(value) => value
                .as_object()
                .ok_or_else(|| "params is not a JSON object".to_string())?,
        };
        let adjustment = Adjustment::from_op(&name, params).ok_or_else(|| {
            format!("`{name}` is not a known adjustment op, or its parameters are not valid for it")
        })?;
        let image = unsafe { &*img };
        Ok(RzImage {
            pixels: apply_to_image(&adjustment, &image.pixels),
        })
    };
    unsafe {
        fallible_op(
            err_out,
            "panic while applying an adjustment",
            ptr::null_mut(),
            body,
            crate::ffi_util::boxed,
        )
    }
}

/// Parses an Adobe Cube LUT (.cube) at `path` into the params object a
/// `"color_lookup"` adjustment stores, as a heap JSON string freed with
/// `rz_string_free`. A table larger than this build stores is resampled down
/// to the cap, and `"source_size"` — always emitted — is the size the FILE
/// declared. NULL with a message through `err_out` for a
/// missing/oversized/malformed file; never panics.
///
/// # Safety
/// `path` must be NULL or a valid NUL-terminated C string; `err_out` must be
/// NULL or a valid pointer to writable `*mut c_char`.
#[no_mangle]
pub unsafe extern "C" fn rz_lut_parse_cube(
    path: *const c_char,
    err_out: *mut *mut c_char,
) -> *mut c_char {
    let body = || -> Result<String, String> {
        let p = unsafe { read_cstr(path, "path") }?;
        adjust_lut::parse_cube_file(&p)
    };
    unsafe {
        fallible_op(
            err_out,
            "panic while parsing a cube LUT",
            ptr::null_mut(),
            body,
            |json| CString::new(json).map_or(ptr::null_mut(), CString::into_raw),
        )
    }
}

/// Fills `bins_out` with 1024 counts — 256 red, then green, then blue, then
/// Rec. 709 luma — and `total_out` with the number of pixels counted. A
/// pixel counts when its alpha is non-zero and, when `mask` is given, its
/// coverage is >= 128. `stride` counts every stride-th pixel in row-major
/// order (0 and 1 both mean every pixel). A NULL `total_out` is tolerated —
/// the bins still come back — but a NULL `bins_out` is not: false on that,
/// or on a NULL image.
///
/// # Safety
/// `img` must be NULL or a valid pointer to a live `RzImage`; `mask` must be
/// NULL or readable for the image's width*height bytes; `bins_out` must be
/// writable for 1024 `uint32_t` and `total_out` NULL or writable for one
/// `uint64_t`.
#[no_mangle]
pub unsafe extern "C" fn rz_image_histogram(
    img: *const RzImage,
    mask: *const u8,
    stride: u32,
    bins_out: *mut u32,
    total_out: *mut u64,
) -> bool {
    if bins_out.is_null() {
        return false;
    }
    unsafe {
        img_get(img, false, |i| {
            let (w, h) = i.pixels.dimensions();
            let len = (w as usize) * (h as usize);
            let coverage = mask_slice(mask, len);
            let (bins, total) = ops_stats::histogram(&i.pixels, coverage, stride);
            ptr::copy_nonoverlapping(bins.as_ptr(), bins_out, bins.len());
            if !total_out.is_null() {
                *total_out = total;
            }
            Some(true)
        })
    }
}

/// The straight RGBA at (x, y): the plain mean of the (2*reach + 1) square
/// about it with out-of-bounds pixels dropped (reach 0, 1 or 2 = point, 3x3,
/// 5x5), truncating like the eyedropper it serves. Writes 4 bytes to
/// `rgba_out`. false only when NO pixel of the block is inside the image,
/// `reach` is above 2, or `img`/`rgba_out` is NULL — the CENTRE itself may
/// be outside, which is what the eyedropper does today.
///
/// # Safety
/// `img` must be NULL or a valid pointer to a live `RzImage`; `rgba_out`
/// must be NULL or writable for 4 bytes.
#[no_mangle]
pub unsafe extern "C" fn rz_image_sample(
    img: *const RzImage,
    x: i32,
    y: i32,
    reach: u32,
    rgba_out: *mut u8,
) -> bool {
    if rgba_out.is_null() {
        return false;
    }
    unsafe {
        img_get(img, false, |i| {
            let px = ops_stats::sample_mean(&i.pixels, x, y, reach)?;
            ptr::copy_nonoverlapping(px.as_ptr(), rgba_out, px.len());
            Some(true)
        })
    }
}

/// Derives Levels parameters from `img`'s own histogram — the same counting
/// rule `rz_image_histogram` uses — clipping `clip` of the counted pixels at
/// each end, and writes nine floats to `params_out`: black[3], white[3],
/// gamma[3]. `mask` is optional. false on a NULL image, an unknown mode, an
/// out-of-range clip, an empty image, or when the result would be the
/// identity.
///
/// # Safety
/// `img` must be NULL or a valid pointer to a live `RzImage`; `mask` must be
/// NULL or readable for the image's width*height bytes; `params_out` must be
/// NULL or writable for 9 `float`.
#[no_mangle]
pub unsafe extern "C" fn rz_image_auto_levels(
    img: *const RzImage,
    mask: *const u8,
    mode: c_int,
    clip: f32,
    params_out: *mut f32,
) -> bool {
    if params_out.is_null() {
        return false;
    }
    unsafe {
        img_get(img, false, |i| {
            let mode = AutoMode::from_c(mode)?;
            let (w, h) = i.pixels.dimensions();
            let coverage = mask_slice(mask, (w as usize) * (h as usize));
            let (black, white, gamma) = ops_auto::auto_levels(&i.pixels, coverage, mode, clip)?;
            let mut out = [0.0f32; 9];
            out[..3].copy_from_slice(&black);
            out[3..6].copy_from_slice(&white);
            out[6..].copy_from_slice(&gamma);
            ptr::copy_nonoverlapping(out.as_ptr(), params_out, out.len());
            Some(true)
        })
    }
}

/// Levels with a black point, white point and gamma PER channel (three
/// floats each, R, G, B). Same math and the same validity condition as
/// `rz_image_levels` applied per channel. Alpha untouched.
///
/// # Safety
/// `img` must be NULL or a valid pointer to a live `RzImage`; `black`,
/// `white` and `gamma` must each be NULL or readable for 3 `float`.
#[no_mangle]
pub unsafe extern "C" fn rz_image_levels_channels(
    img: *const RzImage,
    black: *const f32,
    white: *const f32,
    gamma: *const f32,
) -> *mut RzImage {
    if black.is_null() || white.is_null() || gamma.is_null() {
        return ptr::null_mut();
    }
    unsafe {
        pure_op(img, |i| {
            let read = |p: *const f32| -> [f32; 3] {
                let slice = std::slice::from_raw_parts(p, 3);
                [slice[0], slice[1], slice[2]]
            };
            ops_filters::levels_channels(&i.pixels, read(black), read(white), read(gamma))
                .map(|pixels| RzImage { pixels })
        })
    }
}

/// CIE L*a*b* of one straight RGB triple of THIS document's pixels, through
/// the document's own profile, against the D50 PCS white — so the same bytes
/// read differently in an sRGB and a Display P3 document. Writes L, a, b to
/// `lab_out`. false on a NULL doc/out pointer or a profile this build cannot
/// model (a LUT profile), where the host must say so rather than assume
/// sRGB.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`; `lab_out`
/// must be NULL or writable for 3 `float`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_lab(
    doc: *const RzDocument,
    r: u8,
    g: u8,
    b: u8,
    lab_out: *mut f32,
) -> bool {
    if lab_out.is_null() {
        return false;
    }
    unsafe {
        doc_get(doc, false, |d| {
            let lab = d.lab([r, g, b])?;
            ptr::copy_nonoverlapping(lab.as_ptr(), lab_out, lab.len());
            Some(true)
        })
    }
}
