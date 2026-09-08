//! C FFI for layer styles and the global light (`rz_doc_*style*`,
//! `rz_doc_*global_light*`). Same conventions as `ffi_doc`: the shared
//! helpers in `ffi_util` supply catch_unwind and NULL tolerance; the style
//! JSON is the contract documented in `style` and the header's "Layer
//! styles" section.

use std::ffi::{c_char, CString};
use std::ptr;
use std::sync::Arc;

use crate::doc::RzDocument;
use crate::ffi_util::{boxed, doc_get, doc_op, fallible_op, read_cstr};
use crate::rzdc::MAX_RZDC_META_LEN;
use crate::style::{GlobalLight, LayerStyle, Strictness};

/// Pure setter: returns a new document with layer `idx`'s style replaced by
/// a copy of `style_json` (parsed and canonicalized), or CLEARED when it is
/// NULL — and also cleared when the parsed style is an identity (no enabled
/// effect, fill opacity 1, no Blend If), so a stored style always renders
/// something. NULL with a message through `err_out` when `doc` is NULL
/// ("document is NULL", the err_out convention of `rz_doc_save_native`),
/// when the string is not UTF-8, not valid JSON, not a valid style (the
/// message names the offending key), or over the 16 MiB cap; NULL with NO
/// message (a refusal, not an error) on an out-of-range `idx` or a value
/// equal to the current one, "no style" included.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`;
/// `style_json` must be NULL or a valid NUL-terminated C string; `err_out`
/// must be NULL or a valid pointer to writable `*mut c_char`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_set_layer_style(
    doc: *const RzDocument,
    idx: usize,
    style_json: *const c_char,
    err_out: *mut *mut c_char,
) -> *mut RzDocument {
    let body = || -> Result<Option<RzDocument>, String> {
        if doc.is_null() {
            return Err("document is NULL".to_string());
        }
        let document = unsafe { &*doc };
        let value = if style_json.is_null() {
            None
        } else {
            let s = unsafe { read_cstr(style_json, "style") }?;
            if s.len() > MAX_RZDC_META_LEN as usize {
                return Err(format!("style too large (max {MAX_RZDC_META_LEN} bytes)"));
            }
            let json: serde_json::Value =
                serde_json::from_str(&s).map_err(|e| format!("style is not valid JSON: {e}"))?;
            let style = LayerStyle::from_value(&json, Strictness::Strict)
                .map_err(|reason| format!("style: {reason}"))?;
            Some(Arc::new(style))
        };
        Ok(document.set_layer_style(idx, value))
    };
    unsafe {
        fallible_op(
            err_out,
            "panic while setting layer style",
            ptr::null_mut(),
            body,
            |out| out.map_or(ptr::null_mut(), boxed),
        )
    }
}

/// Canonical JSON of layer `idx`'s style (heap, free with `rz_string_free`);
/// NULL on NULL doc, out-of-range idx, or a layer with no style.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_layer_style(doc: *const RzDocument, idx: usize) -> *mut c_char {
    unsafe {
        doc_get(doc, ptr::null_mut(), |d| {
            let style = d.layers.get(idx)?.style.as_deref()?;
            Some(CString::new(style.to_json()).ok()?.into_raw())
        })
    }
}

/// Whether layer `idx` carries a style (a cheap badge query; false on NULL
/// doc or out-of-range idx). Because identity styles are never stored,
/// true means "renders something".
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_layer_has_style(doc: *const RzDocument, idx: usize) -> bool {
    unsafe { doc_get(doc, false, |d| Some(d.layers.get(idx)?.style.is_some())) }
}

/// Pure setter for the document's global light (degrees); NULL on NULL doc,
/// a non-finite component, or no change after sanitizing (altitude clamped
/// to [0, 90], angle normalized to [-180, 180), both quantized to four
/// decimals like every style number — so echoing a reported value back is
/// "no change").
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_set_global_light(
    doc: *const RzDocument,
    angle: f32,
    altitude: f32,
) -> *mut RzDocument {
    unsafe { doc_op(doc, |d| d.set_global_light(GlobalLight { angle, altitude })) }
}

/// The global light's angle in degrees; 0.0 on NULL doc.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_global_light_angle(doc: *const RzDocument) -> f32 {
    unsafe { doc_get(doc, 0.0, |d| Some(d.global_light.angle)) }
}

/// The global light's altitude in degrees; 0.0 on NULL doc.
///
/// # Safety
/// `doc` must be NULL or a valid pointer to a live `RzDocument`.
#[no_mangle]
pub unsafe extern "C" fn rz_doc_global_light_altitude(doc: *const RzDocument) -> f32 {
    unsafe { doc_get(doc, 0.0, |d| Some(d.global_light.altitude)) }
}
