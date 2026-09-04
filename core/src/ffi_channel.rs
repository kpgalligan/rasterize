//! C FFI for alpha channels and colour planes (`rz_doc_channel_*`,
//! `rz_doc_*_plane*`, `rz_image_plane*`, `rz_blend_planes`) — the "Channels"
//! section of `include/rasterize_core.h`. Same conventions as the sibling
//! shims: catch_unwind through the `ffi_util` helpers, NULL tolerance first,
//! slice lengths recomputed from the core's own dimensions.
//!
//! Every `RzPlane` parameter is declared `c_int` and mapped through
//! [`Plane::from_c`]: the header documents that several exports refuse
//! `RZ_PLANE_LUMA` / `RZ_PLANE_MASK`, so callers do pass values a given
//! export has no use for, and materializing an enum from an out-of-range
//! discriminant would be undefined behaviour.

use std::ffi::{c_char, c_double, c_int, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr;

use image::imageops::{self, FilterType};
use image::GrayImage;

use crate::doc::{BlendMode, RzDocument, MAX_PIXELS};
use crate::doc_channel::max_channels_at;
use crate::doc_plane::{
    blend_planes, blend_planes_rgb, box_reduced, gray_image, image_plane, Plane,
};
use crate::doc_transform::Affine;
use crate::ffi_util::{
    doc_get, doc_op, filter_from_c, img_get, mask_slice, pure_op, read_cstr, thumb_dims,
};
use crate::RzImage;

// ------------------------------------------------------- channel getters --

/// The largest channel count a `w` x `h` canvas may carry under both caps —
/// `doc_channel::MAX_CHANNELS` and `rzdc::MAX_RZDC_TOTAL_CHANNEL_PIXELS`,
/// today 256 channels and 900000000 channel pixels in total (nine full
/// canvases). The two constants are the budget's one home; this comment names
/// them rather than becoming a third copy to keep in step.
///
/// Document-independent and pointer-free, so it takes and refuses nothing; a
/// zero dimension answers the count cap.
///
/// It exists so a host can EXPLAIN the refusals `rz_doc_resize`,
/// `rz_doc_canvas_resize` and `rz_doc_add_luminosity_masks` return NULL for —
/// naming the budget and the channels to delete — rather than reporting them
/// as a bare failure.
#[no_mangle]
pub extern "C" fn rz_max_channels_at(w: u32, h: u32) -> usize {
    // Pure arithmetic that cannot panic; the guard is the family's uniform
    // shape, not a defence against a known unwind.
    catch_unwind(|| max_channels_at(w, h)).unwrap_or(0)
}

/// Number of alpha channels on the document; 0 on a NULL doc.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_channel_count(doc: *const RzDocument) -> usize {
    unsafe { doc_get(doc, 0, |d| Some(d.channels.len())) }
}

/// Channel `i`'s stable identity — unique among every channel this process
/// has minted, kept by every op that carries the channel through (a rename, a
/// plane edit, the geometry ops, undo/redo) and re-minted for a duplicate and
/// on load. 0 on a NULL doc or an out-of-range index, which no live channel
/// ever answers.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_channel_id(doc: *const RzDocument, i: usize) -> u64 {
    unsafe { doc_get(doc, 0, |d| Some(d.channels.get(i)?.id)) }
}

/// Heap copy of channel `i`'s name (free with `rz_string_free`); NULL on a
/// NULL doc or an out-of-range index.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_channel_name(doc: *const RzDocument, i: usize) -> *mut c_char {
    unsafe {
        doc_get(doc, ptr::null_mut(), |d| {
            let name = &d.channels.get(i)?.name;
            let sanitized = name.replace('\0', " ");
            let cstring = CString::new(sanitized)
                .unwrap_or_else(|_| CString::new("Channel").expect("static string"));
            Some(cstring.into_raw())
        })
    }
}

/// Writes channel `i`'s rubylith colour as 3 bytes (r, g, b) into `rgb_out`;
/// false on a NULL doc, a NULL buffer or an out-of-range index.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`; `rgb_out`
/// must be NULL or writable for 3 bytes.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_channel_overlay_color(
    doc: *const RzDocument,
    i: usize,
    rgb_out: *mut u8,
) -> bool {
    if rgb_out.is_null() {
        return false;
    }
    unsafe {
        doc_get(doc, false, |d| {
            let color = d.channels.get(i)?.overlay_color;
            ptr::copy_nonoverlapping(color.as_ptr(), rgb_out, color.len());
            Some(true)
        })
    }
}

/// Channel `i`'s rubylith opacity in [0, 1]; 0.0 on a NULL doc or an
/// out-of-range index.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_channel_overlay_opacity(doc: *const RzDocument, i: usize) -> f32 {
    unsafe { doc_get(doc, 0.0, |d| Some(d.channels.get(i)?.overlay_opacity)) }
}

/// Channel `i`'s rubylith polarity: true = "Color Indicates: Selected Areas",
/// false (the default) = the wash covers the MASKED areas, matching Quick
/// Mask. false on a NULL doc or an out-of-range index.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_channel_color_indicates_selected(
    doc: *const RzDocument,
    i: usize,
) -> bool {
    unsafe {
        doc_get(doc, false, |d| {
            Some(d.channels.get(i)?.color_indicates_selected)
        })
    }
}

// ----------------------------------------------------- channel mutators --

/// Appends a channel from `plane` (`w * h` coverage bytes, row 0 top) with
/// the default masked-areas polarity. When `w`/`h` differ from the canvas the
/// plane is resampled to it bilinearly — the iPhone auxiliary-matte path, and
/// the one place a caller-sized buffer crosses this boundary. NULL on NULL
/// args, a zero dimension, `w * h` past `MAX_PIXELS`, a full channel list, or
/// a list that would exceed the RZDC total pixel budget.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`; `name` must
/// be NULL or a valid NUL-terminated C string; `plane` must be NULL or a
/// valid pointer to at least `w * h` readable bytes.
// The parameter list mirrors the C declaration one-for-one; bundling the
// arguments into a struct would only move the count somewhere else.
#[allow(clippy::too_many_arguments)]
#[no_mangle]
pub unsafe extern "C" fn rz_doc_add_channel(
    doc: *const RzDocument,
    name: *const c_char,
    plane: *const u8,
    w: u32,
    h: u32,
    red: u8,
    green: u8,
    blue: u8,
    overlay_opacity: f32,
) -> *mut RzDocument {
    // The dimensions ARE the buffer's length here (the plane need not be
    // canvas-sized), so bound them before a slice is built from them, exactly
    // as `rz_doc_with_layer_pixels_rgba` bounds its own.
    if name.is_null() || plane.is_null() || w == 0 || h == 0 {
        return ptr::null_mut();
    }
    if u64::from(w) * u64::from(h) > MAX_PIXELS {
        return ptr::null_mut();
    }
    let name = match unsafe { read_cstr(name, "name") } {
        Ok(name) => name,
        Err(_) => return ptr::null_mut(),
    };
    unsafe {
        doc_op(doc, |d| {
            let len = (w as usize).checked_mul(h as usize)?;
            let plane = mask_slice(plane, len)?;
            d.add_channel(&name, plane, w, h, [red, green, blue], overlay_opacity)
        })
    }
}

/// Drops channel `i`. NULL on a NULL doc or an out-of-range index.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_remove_channel(
    doc: *const RzDocument,
    i: usize,
) -> *mut RzDocument {
    unsafe { doc_op(doc, |d| d.remove_channel(i)) }
}

/// Renames channel `i`. NULL on NULL args, an out-of-range index, or a name
/// that is already what it would be set to.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`; `name` must
/// be NULL or a valid NUL-terminated C string.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_rename_channel(
    doc: *const RzDocument,
    i: usize,
    name: *const c_char,
) -> *mut RzDocument {
    let name = match unsafe { read_cstr(name, "name") } {
        Ok(name) => name,
        Err(_) => return ptr::null_mut(),
    };
    unsafe { doc_op(doc, |d| d.rename_channel(i, &name)) }
}

/// Replaces all three of channel `i`'s display options at once (one undo step
/// for a host's options sheet). NULL on a NULL doc, an out-of-range index, or
/// when none of the three would change.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`.
#[allow(clippy::too_many_arguments)]
#[no_mangle]
pub unsafe extern "C" fn rz_doc_set_channel_overlay(
    doc: *const RzDocument,
    i: usize,
    red: u8,
    green: u8,
    blue: u8,
    overlay_opacity: f32,
    color_indicates_selected: bool,
) -> *mut RzDocument {
    unsafe {
        doc_op(doc, |d| {
            d.set_channel_overlay(
                i,
                [red, green, blue],
                overlay_opacity,
                color_indicates_selected,
            )
        })
    }
}

/// Replaces channel `i`'s coverage from a CANVAS-sized `plane` (`w`/`h` must
/// equal the canvas). NULL on NULL args, a dimension mismatch, an
/// out-of-range index, or bytes identical to the current plane.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`; `plane` must
/// be NULL or a valid pointer to at least `w * h` readable bytes.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_set_channel_data(
    doc: *const RzDocument,
    i: usize,
    plane: *const u8,
    w: u32,
    h: u32,
) -> *mut RzDocument {
    unsafe {
        doc_op(doc, |d| {
            // Validate against the canvas dimensions before touching `plane`,
            // so the raw read below is bounded by the canvas buffer size.
            if w != d.width || h != d.height {
                return None;
            }
            let len = (w as usize).checked_mul(h as usize)?;
            d.set_channel_data(i, mask_slice(plane, len)?)
        })
    }
}

/// Inserts a copy of channel `i` right after it, named "<name> copy". NULL on
/// a NULL doc, an out-of-range index, or a list that would break either cap.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_duplicate_channel(
    doc: *const RzDocument,
    i: usize,
) -> *mut RzDocument {
    unsafe { doc_op(doc, |d| d.duplicate_channel(i)) }
}

/// Inverts channel `i` (255 - v). NULL on a NULL doc or an out-of-range
/// index.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_invert_channel(
    doc: *const RzDocument,
    i: usize,
) -> *mut RzDocument {
    unsafe { doc_op(doc, |d| d.invert_channel(i)) }
}

/// Appends the nine luminosity masks ("Lights 1".."Midtones 3") built from
/// the composite's Rec. 709 luma. NULL on a NULL doc or when the nine would
/// not fit under either cap.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_add_luminosity_masks(doc: *const RzDocument) -> *mut RzDocument {
    unsafe { doc_op(doc, |d| d.add_luminosity_masks()) }
}

/// Resamples EVERY channel through an affine matrix in CANVAS coordinates —
/// the same six doubles, in the same `CGAffineTransform` order, that
/// `rz_doc_transform_layer` takes, and the same `RzResizeFilter` kernel. For
/// the one edit that turns the whole picture in place: a straighten rotates
/// every layer (mask included) about a point, so the channels — saved
/// selections OF that picture — must turn with it or stop lining up.
///
/// Channels stay canvas-sized: the destination is the canvas, so coverage
/// rotated off it is dropped (a straighten's crop rect is inside the canvas,
/// so nothing that could survive the crop is lost) and destinations with no
/// source read 0.
///
/// NULL on a NULL doc or matrix, a document with no channels, a non-finite or
/// singular matrix, an unknown filter value, or when no byte would change.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`; `affine`
/// must be NULL or a valid pointer to six readable `double`s.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_transform_channels(
    doc: *const RzDocument,
    affine: *const c_double,
    filter: c_int,
) -> *mut RzDocument {
    if affine.is_null() {
        return ptr::null_mut();
    }
    // Six elements by contract, never a caller-supplied length — the same
    // bounded read rz_doc_transform_layer makes.
    let m = unsafe { std::slice::from_raw_parts(affine, 6) };
    let m = Affine::from_array([m[0], m[1], m[2], m[3], m[4], m[5]]);
    unsafe { doc_op(doc, |d| d.transform_channels(m, filter_from_c(filter)?)) }
}

// ------------------------------------------------- planes into a buffer --

/// Copies `plane` into `out`, which the caller declared to be `w * h` bytes;
/// the length is recomputed here from the same dimensions the caller's claim
/// was already validated against.
///
/// # Safety
/// `out` must be writable for `w * h` bytes.
unsafe fn write_plane(plane: &[u8], out: *mut u8, w: u32, h: u32) -> Option<bool> {
    let len = (w as usize).checked_mul(h as usize)?;
    if plane.len() != len {
        return None;
    }
    unsafe { ptr::copy_nonoverlapping(plane.as_ptr(), out, len) };
    Some(true)
}

/// One plane of the FLATTENED composite into `out` (canvas-sized, row 0 top).
/// A ONE-SHOT op: it runs the whole projection, so a host drawing a plane
/// repeatedly should read its own cached projection with `rz_image_plane`
/// instead. false on NULL args, a dimension mismatch, or `RZ_PLANE_MASK`
/// (the composite has no mask).
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`; `out` must
/// be NULL or writable for canvas width*height bytes.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_composite_plane(
    doc: *const RzDocument,
    plane: c_int,
    out: *mut u8,
    w: u32,
    h: u32,
) -> bool {
    if out.is_null() {
        return false;
    }
    unsafe {
        doc_get(doc, false, |d| {
            if w != d.width || h != d.height {
                return None;
            }
            let plane = d.composite_plane(Plane::from_c(plane)?)?;
            write_plane(&plane, out, w, h)
        })
    }
}

/// One plane of layer `idx` into `out`, CANVAS-sized: pixels outside the
/// layer's rect read 0. `RZ_PLANE_MASK` needs the layer to have a mask.
/// false on NULL args, a dimension mismatch, an out-of-range index, or a
/// plane this layer cannot supply.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`; `out` must
/// be NULL or writable for canvas width*height bytes.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_layer_plane(
    doc: *const RzDocument,
    idx: usize,
    plane: c_int,
    out: *mut u8,
    w: u32,
    h: u32,
) -> bool {
    if out.is_null() {
        return false;
    }
    unsafe {
        doc_get(doc, false, |d| {
            if w != d.width || h != d.height {
                return None;
            }
            let plane = d.layer_plane(idx, Plane::from_c(plane)?)?;
            write_plane(&plane, out, w, h)
        })
    }
}

/// Channel `i`'s coverage into `out` (canvas-sized, row 0 top). false on NULL
/// args, a dimension mismatch, or an out-of-range index.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`; `out` must
/// be NULL or writable for canvas width*height bytes.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_channel_plane(
    doc: *const RzDocument,
    i: usize,
    out: *mut u8,
    w: u32,
    h: u32,
) -> bool {
    if out.is_null() {
        return false;
    }
    unsafe {
        doc_get(doc, false, |d| {
            if w != d.width || h != d.height {
                return None;
            }
            write_plane(d.channel_plane(i)?, out, w, h)
        })
    }
}

/// One plane of a bare image into `out` — `w` and `h` are the IMAGE's own
/// dimensions, the second exception to the canvas-sized rule. For an opaque
/// grayscale image `RZ_PLANE_LUMA` is the identity, which makes this the
/// lossless reader for the plane images below. false on NULL args, a
/// dimension mismatch, or `RZ_PLANE_MASK` (an image has no mask).
///
/// # Safety
/// `img` must be NULL or a valid pointer to a live `RzImage`; `out` must be
/// NULL or writable for the image's width*height bytes.
#[no_mangle]
pub unsafe extern "C" fn rz_image_plane(
    img: *const RzImage,
    plane: c_int,
    out: *mut u8,
    w: u32,
    h: u32,
) -> bool {
    if out.is_null() {
        return false;
    }
    unsafe {
        img_get(img, false, |image| {
            let (iw, ih) = image.pixels.dimensions();
            if w != iw || h != ih {
                return None;
            }
            let plane = image_plane(&image.pixels, Plane::from_c(plane)?)?;
            write_plane(&plane, out, w, h)
        })
    }
}

// ------------------------------------- planes as opaque grayscale images --

/// How many box samples per OUTPUT pixel per axis the box reduction leaves
/// for the Triangle pass to weight (so the box may only take a factor of
/// `side / target / 4`).
///
/// The box is an area mean, which is what a Triangle kernel this wide
/// approximates anyway, but it is a HARD mean: reducing all the way to the
/// target size would make the box the resampler and drop the kernel's
/// sub-pixel weighting at the edges. Four samples per axis keeps a 4 x 4
/// neighbourhood under every output pixel, which measures as no visible
/// difference at all — over a 6000 x 4000 smooth, noisy and hard-edged plane
/// the two-step thumbnail is within 2/255 of the single Triangle pass, and
/// byte-identical on most of them — while still cutting the work by 20x.
/// Reducing to the target directly is ~4x faster again and drifts to 5/255,
/// which is not a trade a thumbnail needs to make.
const THUMB_BOX_GUARD: u32 = 4;

/// `plane` as an opaque grayscale image, aspect-fit to `max_side` (0 = full
/// size). `None` for an empty source, a buffer that is not `w * h` bytes, or
/// a target size past [`MAX_PIXELS`].
///
/// A thumbnail downsamples the PLANE and expands afterwards, never the other
/// way round: [`gray_image`] writes four bytes per pixel, so expanding first
/// would allocate a canvas-sized RGBA buffer (168 MB on a 42 MP canvas) and
/// resample all of it, only to throw everything but a 44-pixel thumbnail
/// away — several seconds of main thread per document change, once a panel
/// asks for one thumbnail per channel. The arithmetic is the same either way:
/// every tap has r == g == b and alpha is the constant 255, so the kernel over
/// the plane and the kernel over its grayscale image give the same bytes.
///
/// A BIG reduction takes two steps: [`box_reduced`] means whole `k` x `k`
/// boxes straight out of the borrowed plane, and the Triangle kernel then
/// does the fractional remainder over the small intermediate. The kernel
/// alone costs ~2 weighted taps per SOURCE pixel whatever the target size, so
/// its cost is the CANVAS's: 44 ms for one 6000 x 4000 plane and 185 ms at
/// 100 MP, once per channel row per document change, against 3.5 ms end to
/// end for the pair. `THUMB_BOX_GUARD` is what keeps the picture the same one
/// — it is the box, not the order above, that puts a thumbnail within 2/255
/// of the plain full-kernel resample instead of exactly on it.
fn plane_image(plane: &[u8], w: u32, h: u32, max_side: u32) -> Option<RzImage> {
    if max_side == 0 {
        return Some(RzImage {
            pixels: gray_image(plane, w, h)?,
        });
    }
    if w == 0 || h == 0 || plane.len() != (w as usize).checked_mul(h as usize)? {
        return None;
    }
    let (tw, th) = thumb_dims(w, h, max_side);
    // The ceiling `ops::resize` enforces for the RGBA path, restated for the
    // gray one: `max_side` is a caller's number and nothing else bounds it.
    if u64::from(tw) * u64::from(th) > MAX_PIXELS {
        return None;
    }
    // Whole boxes first (nothing to reduce answers `None` and the plane is
    // copied as it was), the kernel over what is left.
    let k = (w / tw / THUMB_BOX_GUARD).min(h / th / THUMB_BOX_GUARD);
    let (buffer, sw, sh) = box_reduced(plane, w, h, k).unwrap_or_else(|| (plane.to_vec(), w, h));
    let source = GrayImage::from_raw(sw, sh, buffer)?;
    let small = imageops::resize(&source, tw, th, FilterType::Triangle);
    Some(RzImage {
        pixels: gray_image(small.as_raw(), tw, th)?,
    })
}

/// One plane of an image the host ALREADY HAS — its cached projection, say —
/// as an opaque grayscale image (r == g == b, alpha 255). `max_side` 0 gives
/// full size, otherwise the image is aspect-fit with its longest side ==
/// `max_side`. NULL on a NULL image, `RZ_PLANE_MASK`, or an empty image.
///
/// # Safety
/// `img` must be NULL or a valid pointer to a live `RzImage`.
#[no_mangle]
pub unsafe extern "C" fn rz_image_plane_image(
    img: *const RzImage,
    plane: c_int,
    max_side: u32,
) -> *mut RzImage {
    unsafe {
        pure_op(img, |image| {
            let (w, h) = image.pixels.dimensions();
            let plane = image_plane(&image.pixels, Plane::from_c(plane)?)?;
            plane_image(&plane, w, h, max_side)
        })
    }
}

/// One plane of the FLATTENED composite as an opaque grayscale image. This
/// form re-flattens, so it is for one-shot work only — a display path reads
/// its cached projection through `rz_image_plane_image`. NULL on a NULL doc,
/// `RZ_PLANE_MASK`, or an empty canvas.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_composite_plane_image(
    doc: *const RzDocument,
    plane: c_int,
    max_side: u32,
) -> *mut RzImage {
    unsafe {
        doc_get(doc, ptr::null_mut(), |d| {
            let plane = d.composite_plane(Plane::from_c(plane)?)?;
            Some(Box::into_raw(Box::new(plane_image(
                &plane, d.width, d.height, max_side,
            )?)))
        })
    }
}

/// One CANVAS-sized plane of layer `idx` as an opaque grayscale image (0
/// outside the layer's rect). NULL on a NULL doc, an out-of-range index, a
/// plane the layer cannot supply, or an empty canvas.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_layer_plane_image(
    doc: *const RzDocument,
    idx: usize,
    plane: c_int,
    max_side: u32,
) -> *mut RzImage {
    unsafe {
        doc_get(doc, ptr::null_mut(), |d| {
            let plane = d.layer_plane(idx, Plane::from_c(plane)?)?;
            Some(Box::into_raw(Box::new(plane_image(
                &plane, d.width, d.height, max_side,
            )?)))
        })
    }
}

/// Channel `i` as an opaque grayscale image (the panel's thumbnail source).
/// NULL on a NULL doc, an out-of-range index, or an empty canvas.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_channel_image(
    doc: *const RzDocument,
    i: usize,
    max_side: u32,
) -> *mut RzImage {
    unsafe {
        doc_get(doc, ptr::null_mut(), |d| {
            let plane = d.channel_plane(i)?;
            Some(Box::into_raw(Box::new(plane_image(
                plane, d.width, d.height, max_side,
            )?)))
        })
    }
}

// ---------------------------------------------------------- plane writer --

/// Replaces ONLY `plane` of layer `idx`'s pixels from a CANVAS-sized `src`,
/// inside the layer's rect. `RZ_PLANE_ALPHA` writes STRAIGHT alpha and clears
/// the colour bytes of any pixel whose new alpha is 0. NULL for
/// `RZ_PLANE_LUMA` or `RZ_PLANE_MASK`, NULL args, a dimension mismatch, an
/// out-of-range index, a layer extent that misses the canvas, or when no byte
/// would change — so a caller writing several planes must tolerate NULL per
/// plane.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`; `src` must
/// be NULL or a valid pointer to at least `w * h` readable bytes.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_with_layer_plane(
    doc: *const RzDocument,
    idx: usize,
    plane: c_int,
    src: *const u8,
    w: u32,
    h: u32,
) -> *mut RzDocument {
    unsafe {
        doc_op(doc, |d| {
            // Validate against the canvas dimensions before touching `src`,
            // so the raw read below is bounded by the canvas buffer size.
            if w != d.width || h != d.height {
                return None;
            }
            let len = (w as usize).checked_mul(h as usize)?;
            d.with_layer_plane(idx, Plane::from_c(plane)?, mask_slice(src, len)?)
        })
    }
}

/// Replaces ONLY `plane` of layer `idx`'s pixels from a LAYER-SIZED `src`:
/// `w` and `h` must equal the LAYER's own dimensions, and every sample is
/// written — the part of the layer that hangs off the canvas included. The
/// writer for the filter/adjustment round trip, whose source is
/// `rz_doc_layer_image` + `rz_image_plane`; `rz_doc_with_layer_plane` is the
/// canvas-sized sibling. Same alpha rule, same refusals, and NULL when no
/// byte would change.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`; `src` must
/// be NULL or a valid pointer to at least `w * h` readable bytes.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_with_layer_space_plane(
    doc: *const RzDocument,
    idx: usize,
    plane: c_int,
    src: *const u8,
    w: u32,
    h: u32,
) -> *mut RzDocument {
    unsafe {
        doc_op(doc, |d| {
            // Validate against the LAYER's own dimensions before touching
            // `src`, so the raw read below is bounded by the layer buffer's
            // size (the canvas says nothing about it here).
            let (lw, lh) = d.layers.get(idx)?.pixels.dimensions();
            if w != lw || h != lh {
                return None;
            }
            let len = (w as usize).checked_mul(h as usize)?;
            d.with_layer_space_plane(idx, Plane::from_c(plane)?, mask_slice(src, len)?)
        })
    }
}

// ------------------------------------------------------ coverage painting --

/// Paints channel `i` with a canvas-frame PREMULTIPLIED RGBA8 overlay (`src`,
/// `w`/`h` must equal the canvas — the same buffer `rz_doc_painting_layer`
/// takes) through the mask-painting lerp: white paints toward 255, black
/// toward 0. NULL on NULL args, a dimension mismatch, an out-of-range index,
/// or when no byte would change (white over white is not an edit).
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`; `src` must
/// be NULL or a valid pointer to at least `w * h * 4` readable bytes.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_painting_channel(
    doc: *const RzDocument,
    i: usize,
    src: *const u8,
    w: u32,
    h: u32,
) -> *mut RzDocument {
    unsafe {
        doc_op(doc, |d| {
            // Validate against the canvas dimensions before touching `src`,
            // so the raw read below is bounded by the canvas buffer size.
            if w != d.width || h != d.height {
                return None;
            }
            let len = (w as usize).checked_mul(h as usize)?.checked_mul(4)?;
            d.painting_channel(i, mask_slice(src, len)?)
        })
    }
}

/// The same coverage paint into ONE colour plane of layer `idx`, mapped
/// through the layer's offset. Painting `RZ_PLANE_ALPHA` never clears the
/// colour bytes (a stroke is incremental), unlike `rz_doc_with_layer_plane`.
/// NULL for `RZ_PLANE_LUMA` or `RZ_PLANE_MASK`, NULL args, a dimension
/// mismatch, an out-of-range index, a layer extent that misses the canvas, or
/// when no byte would change.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`; `src` must
/// be NULL or a valid pointer to at least `w * h * 4` readable bytes.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_painting_layer_plane(
    doc: *const RzDocument,
    idx: usize,
    plane: c_int,
    src: *const u8,
    w: u32,
    h: u32,
) -> *mut RzDocument {
    unsafe {
        doc_op(doc, |d| {
            // Validate against the canvas dimensions before touching `src`,
            // so the raw read below is bounded by the canvas buffer size.
            if w != d.width || h != d.height {
                return None;
            }
            let len = (w as usize).checked_mul(h as usize)?.checked_mul(4)?;
            d.painting_layer_plane(idx, Plane::from_c(plane)?, mask_slice(src, len)?)
        })
    }
}

// --------------------------------------------------------- plane arithmetic --

/// `base = lerp(base, blend(base, source), opacity)` per pixel, IN PLACE on
/// caller-owned buffers (the `rz_selection_*` convention), through the same
/// blend table the projection uses. `invert_*` invert an operand FIRST, so
/// the complement is both blended and lerped from. The ONE function behind
/// Apply Image and Calculations. false on NULL args, a zero dimension,
/// dimensions past the 100 MP cap, an unknown mode, or a non-finite opacity.
///
/// # Safety
/// `base` must be NULL or writable for `w * h` bytes; `source` must be NULL
/// or readable for `w * h` bytes.
// The parameter list mirrors the C declaration one-for-one; bundling the
// arguments into a struct would only move the count somewhere else.
#[allow(clippy::too_many_arguments)]
#[no_mangle]
pub unsafe extern "C" fn rz_blend_planes(
    base: *mut u8,
    source: *const u8,
    w: u32,
    h: u32,
    mode: c_int,
    opacity: f32,
    invert_base: bool,
    invert_source: bool,
) -> bool {
    // The in-place caller-owned-buffer shape, guard for guard: the master
    // copy is the `rz_selection_*` family in `ffi_doc` (there is no handle
    // whose dimensions the length could come from instead, so the dimensions
    // are validated and the slice built from them here). The MAX_PIXELS bound
    // is this family's own: a plane is always canvas-sized, and a canvas can
    // never exceed it.
    if base.is_null() || source.is_null() || w == 0 || h == 0 {
        return false;
    }
    if u64::from(w) * u64::from(h) > MAX_PIXELS {
        return false;
    }
    let mode = match BlendMode::from_c(mode) {
        Some(mode) => mode,
        None => return false,
    };
    let len = w as usize * h as usize;
    let base = unsafe { std::slice::from_raw_parts_mut(base, len) };
    let source = unsafe { std::slice::from_raw_parts(source, len) };
    catch_unwind(AssertUnwindSafe(|| {
        blend_planes(
            base,
            source,
            w,
            h,
            mode,
            opacity,
            invert_base,
            invert_source,
        )
    }))
    .unwrap_or(false)
}

/// The RGB-TRIPLE twin of `rz_blend_planes`: three base planes blended
/// against three source planes AS ONE COLOUR and written back into the three
/// caller-owned base buffers. This is Apply Image with an RGB source onto an
/// RGB target, and the only form in which the four non-separable modes (Hue,
/// Saturation, Color, Luminosity) mean anything — which is exactly why
/// `rz_blend_planes` refuses them and this one accepts them. false on a NULL
/// argument, a zero dimension, dimensions past the 100 MP cap, an unknown
/// mode, or a non-finite opacity; on false every buffer is left untouched.
///
/// # Safety
/// The three `base_*` pointers must be writable for `w * h` bytes and the
/// three `source_*` pointers readable for `w * h` bytes. Every buffer is read
/// through a SHARED slice and the results are written back only once those
/// slices are gone, so out-parameters a caller happens to alias stay defined
/// (the answer is then whichever write lands last, which is the caller's
/// problem, not undefined behaviour).
// The parameter list mirrors the C declaration one-for-one; bundling the
// arguments into a struct would only move the count somewhere else.
#[allow(clippy::too_many_arguments)]
#[no_mangle]
pub unsafe extern "C" fn rz_blend_planes_rgb(
    base_r: *mut u8,
    base_g: *mut u8,
    base_b: *mut u8,
    source_r: *const u8,
    source_g: *const u8,
    source_b: *const u8,
    w: u32,
    h: u32,
    mode: c_int,
    opacity: f32,
    invert_base: bool,
    invert_source: bool,
) -> bool {
    if base_r.is_null() || base_g.is_null() || base_b.is_null() {
        return false;
    }
    if source_r.is_null() || source_g.is_null() || source_b.is_null() {
        return false;
    }
    if w == 0 || h == 0 || u64::from(w) * u64::from(h) > MAX_PIXELS {
        return false;
    }
    let mode = match BlendMode::from_c(mode) {
        Some(mode) => mode,
        None => return false,
    };
    let len = w as usize * h as usize;
    let blended = catch_unwind(AssertUnwindSafe(|| {
        let base = unsafe {
            [
                std::slice::from_raw_parts(base_r.cast_const(), len),
                std::slice::from_raw_parts(base_g.cast_const(), len),
                std::slice::from_raw_parts(base_b.cast_const(), len),
            ]
        };
        let source = unsafe {
            [
                std::slice::from_raw_parts(source_r, len),
                std::slice::from_raw_parts(source_g, len),
                std::slice::from_raw_parts(source_b, len),
            ]
        };
        blend_planes_rgb(
            base,
            source,
            w,
            h,
            mode,
            opacity,
            invert_base,
            invert_source,
        )
    }))
    .unwrap_or(None);
    let out = match blended {
        Some(out) => out,
        None => return false,
    };
    unsafe {
        ptr::copy_nonoverlapping(out[0].as_ptr(), base_r, len);
        ptr::copy_nonoverlapping(out[1].as_ptr(), base_g, len);
        ptr::copy_nonoverlapping(out[2].as_ptr(), base_b, len);
    }
    true
}
