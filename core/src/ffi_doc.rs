//! C FFI for the layered document model (`rz_doc_*`). Follows the same
//! conventions as `ffi`: catch_unwind everywhere, NULL-tolerant, errors via
//! heap CStrings released with rz_string_free.

use std::ffi::{c_char, c_int, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr;

use image::imageops::FilterType;

use crate::doc::{BlendMode, RzDocument};
use crate::ops::CompositeMode;
use crate::RzImage;

/// Stores a heap-allocated copy of `msg` through `err_out` (if non-NULL).
/// Interior NUL bytes are replaced so the `CString` conversion cannot fail.
/// (Local copy of the private helper in `ffi`.)
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

/// Runs a pure operation against `doc`, boxing the produced document.
/// NULL input, `None`, or a panic all yield NULL.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`.
unsafe fn doc_op<F>(doc: *const RzDocument, op: F) -> *mut RzDocument
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
unsafe fn doc_get<T, F>(doc: *const RzDocument, default: T, get: F) -> T
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

/// Maps a raw `RzResizeFilter` value (same mapping as `rz_image_resize`).
fn filter_from_c(value: c_int) -> Option<FilterType> {
    match value {
        0 => Some(FilterType::Nearest),
        1 => Some(FilterType::Triangle),
        2 => Some(FilterType::CatmullRom),
        3 => Some(FilterType::Lanczos3),
        _ => None,
    }
}

/// Opens a document: "RZDC" files load the native layered format, "8BPS"
/// files import Photoshop layers (falling back to the flattened composite on
/// per-layer failures), anything else decodes as a single-layer image.
/// Returns NULL on failure and writes a message through `err_out` (caller
/// frees with `rz_string_free`).
///
/// # Safety
/// `path` must be NULL or a valid NUL-terminated C string; `err_out` must be
/// NULL or a valid pointer to writable `*mut c_char`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_open(
    path: *const c_char,
    err_out: *mut *mut c_char,
) -> *mut RzDocument {
    let outcome = catch_unwind(AssertUnwindSafe(|| {
        if path.is_null() {
            return Err("path is NULL".to_string());
        }
        let path = unsafe { CStr::from_ptr(path) }
            .to_str()
            .map_err(|_| "path is not valid UTF-8".to_string())?;
        RzDocument::open(path)
    }));
    match outcome {
        Ok(Ok(doc)) => Box::into_raw(Box::new(doc)),
        Ok(Err(msg)) => {
            unsafe { set_err(err_out, &msg) };
            ptr::null_mut()
        }
        Err(_) => {
            unsafe { set_err(err_out, "internal error: panic while opening document") };
            ptr::null_mut()
        }
    }
}

/// Wraps an image as a single-"Background"-layer document. NULL if `img` is
/// NULL.
///
/// # Safety
/// `img` must be NULL or a valid pointer to a live `RzImage`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_from_image(img: *const RzImage) -> *mut RzDocument {
    if img.is_null() {
        return ptr::null_mut();
    }
    let image = unsafe { &*img };
    match catch_unwind(AssertUnwindSafe(|| {
        RzDocument::from_pixels(image.pixels.clone())
    })) {
        Ok(doc) => Box::into_raw(Box::new(doc)),
        Err(_) => ptr::null_mut(),
    }
}

/// Cheap copy (shares layer pixel buffers). NULL only if `doc` is NULL.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_clone(doc: *const RzDocument) -> *mut RzDocument {
    unsafe { doc_op(doc, |d| Some(d.clone())) }
}

/// Frees a document. NULL is a safe no-op.
///
/// # Safety
/// `doc` must be NULL or a pointer previously returned by this library that
/// has not yet been freed.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_free(doc: *mut RzDocument) {
    if doc.is_null() {
        return;
    }
    let _ = catch_unwind(AssertUnwindSafe(|| drop(unsafe { Box::from_raw(doc) })));
}

/// Writes the native RZDC format (all layers preserved), atomically like
/// `rz_image_save`. Returns false on failure and writes a message through
/// `err_out`.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`; `path` must
/// be NULL or a valid NUL-terminated C string; `err_out` must be NULL or a
/// valid pointer to writable `*mut c_char`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_save_native(
    doc: *const RzDocument,
    path: *const c_char,
    err_out: *mut *mut c_char,
) -> bool {
    let outcome = catch_unwind(AssertUnwindSafe(|| {
        if doc.is_null() {
            return Err("document is NULL".to_string());
        }
        if path.is_null() {
            return Err("path is NULL".to_string());
        }
        let document = unsafe { &*doc };
        let path = unsafe { CStr::from_ptr(path) }
            .to_str()
            .map_err(|_| "path is not valid UTF-8".to_string())?;
        document.save_native(path)
    }));
    match outcome {
        Ok(Ok(())) => true,
        Ok(Err(msg)) => {
            unsafe { set_err(err_out, &msg) };
            false
        }
        Err(_) => {
            unsafe { set_err(err_out, "internal error: panic while saving document") };
            false
        }
    }
}

/// Canvas width in pixels; 0 if `doc` is NULL.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_width(doc: *const RzDocument) -> u32 {
    unsafe { doc_get(doc, 0, |d| Some(d.width)) }
}

/// Canvas height in pixels; 0 if `doc` is NULL.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_height(doc: *const RzDocument) -> u32 {
    unsafe { doc_get(doc, 0, |d| Some(d.height)) }
}

/// Number of layers (index 0 = bottom); 0 if `doc` is NULL.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_layer_count(doc: *const RzDocument) -> usize {
    unsafe { doc_get(doc, 0, |d| Some(d.layers.len())) }
}

/// Heap copy of the layer's name (free with `rz_string_free`); NULL on NULL
/// doc or out-of-range idx.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_layer_name(doc: *const RzDocument, idx: usize) -> *mut c_char {
    unsafe {
        doc_get(doc, ptr::null_mut(), |d| {
            let name = &d.layers.get(idx)?.name;
            let sanitized = name.replace('\0', " ");
            let cstring = CString::new(sanitized)
                .unwrap_or_else(|_| CString::new("Layer").expect("static string"));
            Some(cstring.into_raw())
        })
    }
}

/// The layer's opacity in [0, 1]; 0.0 on NULL doc or out-of-range idx.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_layer_opacity(doc: *const RzDocument, idx: usize) -> f32 {
    unsafe { doc_get(doc, 0.0, |d| Some(d.layers.get(idx)?.opacity)) }
}

/// The layer's blend mode; RZ_BLEND_NORMAL on NULL doc or out-of-range idx.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_layer_blend_mode(doc: *const RzDocument, idx: usize) -> c_int {
    unsafe { doc_get(doc, 0, |d| Some(d.layers.get(idx)?.blend.to_c())) }
}

/// The layer's visibility flag; false on NULL doc or out-of-range idx.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_layer_visible(doc: *const RzDocument, idx: usize) -> bool {
    unsafe { doc_get(doc, false, |d| Some(d.layers.get(idx)?.visible)) }
}

/// The layer's canvas x offset; 0 on NULL doc or out-of-range idx.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_layer_offset_x(doc: *const RzDocument, idx: usize) -> i32 {
    unsafe { doc_get(doc, 0, |d| Some(d.layers.get(idx)?.offset.0)) }
}

/// The layer's canvas y offset; 0 on NULL doc or out-of-range idx.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_layer_offset_y(doc: *const RzDocument, idx: usize) -> i32 {
    unsafe { doc_get(doc, 0, |d| Some(d.layers.get(idx)?.offset.1)) }
}

/// The layer's pixel width; 0 on NULL doc or out-of-range idx.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_layer_width(doc: *const RzDocument, idx: usize) -> u32 {
    unsafe { doc_get(doc, 0, |d| Some(d.layers.get(idx)?.pixels.width())) }
}

/// The layer's pixel height; 0 on NULL doc or out-of-range idx.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_layer_height(doc: *const RzDocument, idx: usize) -> u32 {
    unsafe { doc_get(doc, 0, |d| Some(d.layers.get(idx)?.pixels.height())) }
}

/// Copy of a layer's pixels at the layer's own size; NULL on NULL doc or
/// out-of-range idx.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_layer_image(doc: *const RzDocument, idx: usize) -> *mut RzImage {
    unsafe {
        doc_get(doc, ptr::null_mut(), |d| {
            let pixels = (*d.layers.get(idx)?.pixels).clone();
            Some(Box::into_raw(Box::new(RzImage { pixels })))
        })
    }
}

/// Aspect-fit thumbnail of a layer with longest side `max(1, max_side)`
/// (Triangle filter; tiny layers are upscaled). NULL on NULL doc,
/// out-of-range idx, an empty-sized layer, or an absurd target size.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_layer_thumbnail(
    doc: *const RzDocument,
    idx: usize,
    max_side: u32,
) -> *mut RzImage {
    unsafe {
        doc_get(doc, ptr::null_mut(), |d| {
            let layer = d.layers.get(idx)?;
            let (lw, lh) = layer.pixels.dimensions();
            if lw == 0 || lh == 0 {
                return None;
            }
            let side = max_side.max(1);
            let (tw, th) = if lw >= lh {
                let th = (f64::from(lh) * f64::from(side) / f64::from(lw)).round() as u32;
                (side, th.max(1))
            } else {
                let tw = (f64::from(lw) * f64::from(side) / f64::from(lh)).round() as u32;
                (tw.max(1), side)
            };
            let pixels = crate::ops::resize(&layer.pixels, tw, th, FilterType::Triangle)?;
            Some(Box::into_raw(Box::new(RzImage { pixels })))
        })
    }
}

/// Canvas-sized straight-alpha projection of the visible layers; NULL only if
/// `doc` is NULL.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_flattened(doc: *const RzDocument) -> *mut RzImage {
    unsafe {
        doc_get(doc, ptr::null_mut(), |d| {
            let pixels = d.flattened();
            Some(Box::into_raw(Box::new(RzImage { pixels })))
        })
    }
}

/// Pure setter: returns a new document with layer `idx` renamed. NULL on NULL
/// args or out-of-range idx.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`; `name` must
/// be NULL or a valid NUL-terminated C string.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_with_layer_name(
    doc: *const RzDocument,
    idx: usize,
    name: *const c_char,
) -> *mut RzDocument {
    if name.is_null() {
        return ptr::null_mut();
    }
    let name = unsafe { CStr::from_ptr(name) }
        .to_string_lossy()
        .into_owned();
    unsafe { doc_op(doc, |d| d.with_layer_name(idx, &name)) }
}

/// Pure setter: returns a new document with layer `idx`'s opacity replaced
/// (clamped to [0, 1]). NULL on NULL doc or out-of-range idx.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_with_layer_opacity(
    doc: *const RzDocument,
    idx: usize,
    opacity: f32,
) -> *mut RzDocument {
    unsafe { doc_op(doc, |d| d.with_layer_opacity(idx, opacity)) }
}

/// Pure setter: returns a new document with layer `idx`'s blend mode
/// replaced. NULL on NULL doc, out-of-range idx, or an unknown mode value.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_with_layer_blend_mode(
    doc: *const RzDocument,
    idx: usize,
    mode: c_int,
) -> *mut RzDocument {
    unsafe {
        doc_op(doc, |d| {
            d.with_layer_blend_mode(idx, BlendMode::from_c(mode)?)
        })
    }
}

/// Pure setter: returns a new document with layer `idx`'s visibility
/// replaced. NULL on NULL doc or out-of-range idx.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_with_layer_visible(
    doc: *const RzDocument,
    idx: usize,
    visible: bool,
) -> *mut RzDocument {
    unsafe { doc_op(doc, |d| d.with_layer_visible(idx, visible)) }
}

/// Pure setter: returns a new document with layer `idx`'s canvas offset
/// replaced. NULL on NULL doc or out-of-range idx.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_with_layer_offset(
    doc: *const RzDocument,
    idx: usize,
    x: i32,
    y: i32,
) -> *mut RzDocument {
    unsafe { doc_op(doc, |d| d.with_layer_offset(idx, x, y)) }
}

/// Pure setter: returns a new document with layer `idx`'s pixels replaced by
/// a copy of `img` (any size; offset and properties kept). NULL on NULL args
/// or out-of-range idx.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`; `img` must
/// be NULL or a valid pointer to a live `RzImage`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_with_layer_pixels(
    doc: *const RzDocument,
    idx: usize,
    img: *const RzImage,
) -> *mut RzDocument {
    if img.is_null() {
        return ptr::null_mut();
    }
    let image = unsafe { &*img };
    unsafe { doc_op(doc, |d| d.with_layer_pixels(idx, image.pixels.clone())) }
}

/// Inserts a transparent canvas-sized layer (offset 0) above `idx`. NULL on
/// NULL args or out-of-range idx.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`; `name` must
/// be NULL or a valid NUL-terminated C string.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_adding_layer(
    doc: *const RzDocument,
    idx: usize,
    name: *const c_char,
) -> *mut RzDocument {
    if name.is_null() {
        return ptr::null_mut();
    }
    let name = unsafe { CStr::from_ptr(name) }
        .to_string_lossy()
        .into_owned();
    unsafe { doc_op(doc, |d| d.adding_layer(idx, &name)) }
}

/// Inserts a layer with a copy of `img`'s pixels (offset 0) above `idx`. NULL
/// on NULL args or out-of-range idx.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`; `img` must
/// be NULL or a valid pointer to a live `RzImage`; `name` must be NULL or a
/// valid NUL-terminated C string.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_adding_image_layer(
    doc: *const RzDocument,
    idx: usize,
    img: *const RzImage,
    name: *const c_char,
) -> *mut RzDocument {
    if img.is_null() || name.is_null() {
        return ptr::null_mut();
    }
    let image = unsafe { &*img };
    let name = unsafe { CStr::from_ptr(name) }
        .to_string_lossy()
        .into_owned();
    unsafe {
        doc_op(doc, |d| {
            d.adding_image_layer(idx, image.pixels.clone(), &name)
        })
    }
}

/// Duplicates layer `idx` (" copy" appended to the name), inserting the
/// duplicate above it. NULL on NULL doc or out-of-range idx.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_duplicating_layer(
    doc: *const RzDocument,
    idx: usize,
) -> *mut RzDocument {
    unsafe { doc_op(doc, |d| d.duplicating_layer(idx)) }
}

/// Removes layer `idx`. NULL on NULL doc, out-of-range idx, or if it is the
/// last remaining layer.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_removing_layer(
    doc: *const RzDocument,
    idx: usize,
) -> *mut RzDocument {
    unsafe { doc_op(doc, |d| d.removing_layer(idx)) }
}

/// Removes the layer at `from` and reinserts it at `to`. NULL on NULL doc or
/// either index out of range.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_moving_layer(
    doc: *const RzDocument,
    from: usize,
    to: usize,
) -> *mut RzDocument {
    unsafe { doc_op(doc, |d| d.moving_layer(from, to)) }
}

/// Merges layer `idx` (idx >= 1) into the layer below it: both layers' modes
/// and opacities are baked into the merged pixels (same kernel as the
/// projection), so the merged layer is Normal at opacity 1, keeping only the
/// lower layer's name and visibility, and covers the union of both extents.
/// NULL on NULL doc, idx == 0 / out of range, or a hidden LOWER layer.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_merging_down(
    doc: *const RzDocument,
    idx: usize,
) -> *mut RzDocument {
    unsafe { doc_op(doc, |d| d.merging_down(idx)) }
}

/// Single-layer document containing the projection, named "Background". NULL
/// only if `doc` is NULL.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_flattening(doc: *const RzDocument) -> *mut RzDocument {
    unsafe { doc_op(doc, |d| Some(d.flattening())) }
}

/// Paints a canvas-frame PREMULTIPLIED RGBA8 overlay (`src`, `w`/`h` must
/// equal the canvas size) onto layer `idx`, mapped through the layer's
/// offset; modes and `alpha` as `rz_image_composite`. NULL on NULL args,
/// dimension mismatch, unknown mode, NaN alpha, out-of-range idx, or when
/// the layer's extent does not intersect the canvas (no pixel could change).
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`; `src` must
/// be NULL or a valid pointer to at least `w * h * 4` readable bytes.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_painting_layer(
    doc: *const RzDocument,
    idx: usize,
    src: *const u8,
    w: u32,
    h: u32,
    mode: c_int,
    alpha: f32,
) -> *mut RzDocument {
    if doc.is_null() || src.is_null() {
        return ptr::null_mut();
    }
    let document = unsafe { &*doc };
    let outcome = catch_unwind(AssertUnwindSafe(|| {
        let mode = CompositeMode::from_c(mode)?;
        // Validate against the canvas dimensions before touching `src`, so
        // the raw read below is bounded by the canvas buffer size.
        if w != document.width || h != document.height {
            return None;
        }
        let len = (w as usize).checked_mul(h as usize)?.checked_mul(4)?;
        let src = unsafe { std::slice::from_raw_parts(src, len) };
        document.painting_layer(idx, src, mode, alpha)
    }));
    match outcome {
        Ok(Some(result)) => Box::into_raw(Box::new(result)),
        _ => ptr::null_mut(),
    }
}

/// Rotates the whole document 90 degrees clockwise.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_rotate90(doc: *const RzDocument) -> *mut RzDocument {
    unsafe { doc_op(doc, |d| Some(d.rotate90())) }
}

/// Rotates the whole document 180 degrees.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_rotate180(doc: *const RzDocument) -> *mut RzDocument {
    unsafe { doc_op(doc, |d| Some(d.rotate180())) }
}

/// Rotates the whole document 90 degrees counter-clockwise.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_rotate270(doc: *const RzDocument) -> *mut RzDocument {
    unsafe { doc_op(doc, |d| Some(d.rotate270())) }
}

/// Mirrors the whole document left-right.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_flip_horizontal(doc: *const RzDocument) -> *mut RzDocument {
    unsafe { doc_op(doc, |d| Some(d.flip_horizontal())) }
}

/// Mirrors the whole document top-bottom.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_flip_vertical(doc: *const RzDocument) -> *mut RzDocument {
    unsafe { doc_op(doc, |d| Some(d.flip_vertical())) }
}

/// Moves the canvas window (offsets shift, layer pixels untouched);
/// bounds-checked against the canvas like `rz_image_crop`. NULL on NULL doc
/// or an invalid rect.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_crop(
    doc: *const RzDocument,
    x: u32,
    y: u32,
    w: u32,
    h: u32,
) -> *mut RzDocument {
    unsafe { doc_op(doc, |d| d.crop(x, y, w, h)) }
}

/// Changes the canvas size without scaling: every layer's offset shifts by
/// (`origin_x`, `origin_y`), layer pixels untouched. NULL on NULL doc, zero
/// dimension, or a canvas over the total-pixel limit.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_canvas_resize(
    doc: *const RzDocument,
    w: u32,
    h: u32,
    origin_x: i32,
    origin_y: i32,
) -> *mut RzDocument {
    unsafe { doc_op(doc, |d| d.canvas_resize(w, h, (origin_x, origin_y))) }
}

/// Scales the canvas and every layer proportionally; limits and filter
/// mapping as `rz_image_resize`. NULL on NULL doc, invalid target, or an
/// unknown filter value.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_resize(
    doc: *const RzDocument,
    w: u32,
    h: u32,
    filter: c_int,
) -> *mut RzDocument {
    unsafe { doc_op(doc, |d| d.resize(w, h, filter_from_c(filter)?)) }
}

// ------------------------------------------------------- selection & fill --

/// Similar-color selection from the flattened composite: writes a
/// canvas-sized 0/255 mask (w*h bytes, row 0 top) into `mask_out`.
/// `tolerance` is the maximum per-channel RGBA difference; `contiguous`
/// restricts the selection to the connected region around the seed.
/// Returns false on NULL/out-of-canvas input.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`;
/// `mask_out` must be NULL or writable for canvas width*height bytes.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_magic_wand(
    doc: *const RzDocument,
    x: u32,
    y: u32,
    tolerance: u8,
    contiguous: bool,
    mask_out: *mut u8,
) -> bool {
    if doc.is_null() || mask_out.is_null() {
        return false;
    }
    let document = unsafe { &*doc };
    let mask = catch_unwind(AssertUnwindSafe(|| {
        document.magic_wand(x, y, tolerance, contiguous)
    }));
    match mask {
        Ok(Some(mask)) => {
            unsafe { ptr::copy_nonoverlapping(mask.as_ptr(), mask_out, mask.len()) };
            true
        }
        _ => false,
    }
}

/// Reads an optional canvas-sized mask pointer into a slice.
///
/// # Safety
/// `mask` must be NULL or valid for `len` bytes for the duration of the
/// caller.
unsafe fn mask_slice<'a>(mask: *const u8, len: usize) -> Option<&'a [u8]> {
    if mask.is_null() {
        None
    } else {
        Some(unsafe { std::slice::from_raw_parts(mask, len) })
    }
}

/// Bucket fill on layer `idx`: grows a similar-color region over the
/// layer's own pixels from canvas point (x, y) and paints `rgba`
/// source-over it. `mask` is a canvas-sized selection coverage buffer or
/// NULL; a seed outside the canvas, the layer, or the mask yields NULL.
///
/// # Safety
/// `doc` must be NULL or a valid live `RzDocument`; `rgba` must point to
/// 4 bytes; `mask` must be NULL or valid for canvas width*height bytes.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_bucket_fill(
    doc: *const RzDocument,
    idx: usize,
    x: i32,
    y: i32,
    tolerance: u8,
    rgba: *const u8,
    contiguous: bool,
    mask: *const u8,
) -> *mut RzDocument {
    if rgba.is_null() {
        return ptr::null_mut();
    }
    let color = unsafe { [*rgba, *rgba.add(1), *rgba.add(2), *rgba.add(3)] };
    unsafe {
        doc_op(doc, |d| {
            let mask = mask_slice(mask, d.width as usize * d.height as usize);
            d.bucket_fill(idx, x, y, tolerance, color, contiguous, mask)
        })
    }
}

/// Paints a two-color gradient source-over layer `idx` (the whole layer,
/// scaled by `mask` where given): kind 0 = linear along p0->p1 (clamped
/// past the ends), kind 1 = radial from p0 with radius |p1-p0|. Colors
/// interpolate straight RGBA. NULL if p0 == p1, coordinates are not
/// finite, or the kind is unknown.
///
/// # Safety
/// `doc` must be NULL or a valid live `RzDocument`; `start_rgba` and
/// `end_rgba` must point to 4 bytes; `mask` must be NULL or valid for
/// canvas width*height bytes.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_gradient(
    doc: *const RzDocument,
    idx: usize,
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
    start_rgba: *const u8,
    end_rgba: *const u8,
    kind: c_int,
    mask: *const u8,
) -> *mut RzDocument {
    if start_rgba.is_null() || end_rgba.is_null() {
        return ptr::null_mut();
    }
    let radial = match kind {
        0 => false,
        1 => true,
        _ => return ptr::null_mut(),
    };
    let start = unsafe {
        [
            *start_rgba,
            *start_rgba.add(1),
            *start_rgba.add(2),
            *start_rgba.add(3),
        ]
    };
    let end = unsafe {
        [
            *end_rgba,
            *end_rgba.add(1),
            *end_rgba.add(2),
            *end_rgba.add(3),
        ]
    };
    unsafe {
        doc_op(doc, |d| {
            let mask = mask_slice(mask, d.width as usize * d.height as usize);
            d.gradient(idx, (x0, y0), (x1, y1), start, end, radial, mask)
        })
    }
}

/// Gaussian-feathers a selection mask in place (width*height coverage
/// bytes, row 0 top). Sampling clamps to the canvas edges, so a
/// selection touching the border keeps full coverage there. Returns
/// false on NULL mask, zero dimensions, or a non-finite radius;
/// `radius <= 0` returns true and leaves the mask untouched.
///
/// # Safety
/// `mask` must be NULL or valid and writable for width*height bytes.
#[no_mangle]
pub unsafe extern "C" fn rz_selection_feather(
    mask: *mut u8,
    width: u32,
    height: u32,
    radius: f32,
) -> bool {
    if mask.is_null() || width == 0 || height == 0 || !radius.is_finite() {
        return false;
    }
    let len = width as usize * height as usize;
    let slice = unsafe { std::slice::from_raw_parts_mut(mask, len) };
    catch_unwind(AssertUnwindSafe(|| {
        crate::doc_select::feather_mask(slice, width, height, radius);
    }))
    .is_ok()
}
