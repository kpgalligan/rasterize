//! Layer styles — the FFI surface, its guards, the global light, the RZDC
//! version-4 fields (round trip, hand-built older and crafted records, the
//! lenient style read) and the ride-along sweep through every layer path.
//! Black-box through the C exports on documents built from the safe
//! constructors; shared fixtures live in `tests/common`.

use std::ffi::{c_char, CString};
use std::ptr;
use std::sync::Arc;

use image::imageops::FilterType;
use rasterize_core::doc::RzDocument;
use rasterize_core::ffi_doc::*;
use rasterize_core::ffi_style::*;
use rasterize_core::style::*;
use tempfile::TempDir;

mod common;
use common::*;

// ---------------------------------------------------------------- helpers --

fn light(doc: *const RzDocument) -> (f32, f32) {
    unsafe {
        (
            rz_doc_global_light_angle(doc),
            rz_doc_global_light_altitude(doc),
        )
    }
}

fn open_bytes(dir: &TempDir, name: &str, bytes: &[u8]) -> Result<RzDocument, String> {
    let path = dir.path().join(name);
    std::fs::write(&path, bytes).unwrap();
    RzDocument::open(path.to_str().unwrap())
}

/// `rz_doc_transform_layer` on a copy of `doc`.
fn transformed(doc: &RzDocument, idx: usize, m: [f64; 6]) -> RzDocument {
    let handle = Box::into_raw(Box::new(doc.clone()));
    let out = unsafe { rz_doc_transform_layer(handle, idx, m.as_ptr(), FILTER_BILINEAR) };
    unsafe { rz_doc_free(handle) };
    assert!(!out.is_null(), "transform refused");
    *unsafe { Box::from_raw(out) }
}

/// `rz_doc_perspective_layer` on a copy of `doc`.
fn warped(doc: &RzDocument, idx: usize, quad: [f64; 8]) -> RzDocument {
    let handle = Box::into_raw(Box::new(doc.clone()));
    let out = unsafe { rz_doc_perspective_layer(handle, idx, quad.as_ptr(), FILTER_BILINEAR) };
    unsafe { rz_doc_free(handle) };
    assert!(!out.is_null(), "perspective refused");
    *unsafe { Box::from_raw(out) }
}

fn shadow_of(doc: &RzDocument, idx: usize) -> DropShadow {
    match doc.layers[idx]
        .style
        .as_ref()
        .expect("styled")
        .effect(EffectKind::DropShadow)
    {
        Some(Effect::DropShadow(d)) => d.clone(),
        other => panic!("{other:?}"),
    }
}

// -------------------------------------------------------------------- ffi --

#[test]
fn ffi_layer_style_round_trips_sets_and_clears() {
    let dir = TempDir::new().unwrap();
    let doc = doc_from(&dir, "bg.png", &solid(6, 4, WHITE));
    let doc = add_layer(&dir, "top.png", doc, 0, &solid(2, 2, RED), "Top");
    assert_eq!(ffi_style(doc, 1), None, "a fresh layer has no style");
    assert!(!unsafe { rz_doc_layer_has_style(doc, 1) });

    let original = unsafe { rz_doc_clone(doc) };
    let doc = set_style(doc, 1, STYLE_JSON);
    let canonical = ffi_style(doc, 1).expect("style set");
    assert!(canonical.contains("\"fill_opacity\":0.5"), "{canonical}");
    assert!(
        canonical.contains("\"type\":\"drop_shadow\""),
        "{canonical}"
    );
    assert!(canonical.contains("\"type\":\"stroke\""), "{canonical}");
    assert!(
        canonical.contains("\"color\":\"#ff0000\""),
        "lowercase: {canonical}"
    );
    assert!(
        !canonical.contains("note"),
        "unknown keys are dropped: {canonical}"
    );
    assert_eq!(
        canonical,
        LayerStyle::from_json(STYLE_JSON).unwrap().to_json(),
        "the getter returns the canonical form"
    );
    assert!(unsafe { rz_doc_layer_has_style(doc, 1) });
    assert_eq!(ffi_style(doc, 0), None, "the other layer is untouched");
    assert_eq!(ffi_style(original, 1), None, "the setter is pure");
    unsafe { rz_doc_free(original) };

    // Replace, then clear with NULL.
    let doc = set_style(doc, 1, "{\"effects\":[{\"type\":\"satin\"}]}");
    assert!(ffi_style(doc, 1).unwrap().contains("satin"));
    let doc = apply(doc, |d| unsafe {
        rz_doc_set_layer_style(d, 1, ptr::null(), ptr::null_mut())
    });
    assert_eq!(ffi_style(doc, 1), None);
    assert!(!unsafe { rz_doc_layer_has_style(doc, 1) });
    unsafe { rz_doc_free(doc) };
}

#[test]
fn ffi_layer_style_refusals_and_errors() {
    let dir = TempDir::new().unwrap();
    let doc = doc_from(&dir, "bg.png", &solid(6, 4, WHITE));
    let doc = add_layer(&dir, "top.png", doc, 0, &solid(2, 2, RED), "Top");
    let doc = set_style(doc, 1, STYLE_JSON);
    let before = ffi_style(doc, 1).unwrap();

    // An identical value is a silent refusal (canonical or not).
    assert_eq!(style_error(doc, 1, STYLE_JSON), None);
    assert_eq!(style_error(doc, 1, &before), None);
    // Out of range: silent.
    assert_eq!(style_error(doc, 2, STYLE_JSON), None, "idx == count");
    assert_eq!(style_error(doc, usize::MAX, STYLE_JSON), None);
    // Errors carry a message.
    let msg = style_error(doc, 1, "{not json").expect("a message");
    assert!(msg.contains("JSON"), "{msg}");
    let msg = style_error(doc, 1, "{\"effects\":[{\"type\":\"glow\"}]}").expect("a message");
    assert!(msg.contains("effects[0].type"), "{msg}");
    let msg = style_error(doc, 1, "{\"fill_opacity\":\"x\"}").expect("a message");
    assert!(msg.contains("fill_opacity"), "{msg}");
    let huge = format!(
        "{{\"note\":\"{}\",\"effects\":[]}}",
        "a".repeat(16 * 1024 * 1024)
    );
    let msg = style_error(doc, 1, &huge).expect("a message");
    assert!(msg.contains("too large"), "{msg}");
    // Bad UTF-8 is refused with a message.
    let bad = [b'{', 0xff, b'}', 0];
    let mut err: *mut c_char = ptr::null_mut();
    assert!(unsafe { rz_doc_set_layer_style(doc, 1, bad.as_ptr().cast(), &mut err) }.is_null());
    assert!(take_err_string(err).contains("UTF-8"));
    // err_out NULL is tolerated.
    let broken = CString::new("{not json").unwrap();
    assert!(unsafe { rz_doc_set_layer_style(doc, 1, broken.as_ptr(), ptr::null_mut()) }.is_null());
    // NULL doc: NULL and a message, with or without a payload.
    let payload = CString::new(STYLE_JSON).unwrap();
    let mut err: *mut c_char = ptr::null_mut();
    assert!(
        unsafe { rz_doc_set_layer_style(ptr::null(), 0, payload.as_ptr(), &mut err) }.is_null()
    );
    assert_eq!(take_err_string(err), "document is NULL");
    let mut err: *mut c_char = ptr::null_mut();
    assert!(unsafe { rz_doc_set_layer_style(ptr::null(), 0, ptr::null(), &mut err) }.is_null());
    assert!(!take_err_string(err).is_empty());
    assert!(
        unsafe { rz_doc_layer_style(doc, 2) }.is_null(),
        "getter out of range"
    );
    assert!(!unsafe { rz_doc_layer_has_style(doc, 2) });

    assert_eq!(
        ffi_style(doc, 1).as_deref(),
        Some(before.as_str()),
        "no refused call changed anything"
    );
    unsafe { rz_doc_free(doc) };
}

#[test]
fn ffi_global_light_round_trips_sanitizes_and_refuses() {
    let dir = TempDir::new().unwrap();
    let doc = doc_from(&dir, "bg.png", &solid(4, 4, WHITE));
    assert_eq!(light(doc), (120.0, 30.0), "Photoshop's defaults");
    let original = unsafe { rz_doc_clone(doc) };
    let doc = apply(doc, |d| unsafe { rz_doc_set_global_light(d, 45.0, 60.0) });
    assert_eq!(light(doc), (45.0, 60.0));
    assert_eq!(light(original), (120.0, 30.0), "the setter is pure");
    unsafe { rz_doc_free(original) };
    for (a, b) in [
        (f32::NAN, 30.0),
        (45.0, f32::INFINITY),
        (f32::NEG_INFINITY, 30.0),
    ] {
        assert!(
            unsafe { rz_doc_set_global_light(doc, a, b) }.is_null(),
            "({a}, {b})"
        );
    }
    assert!(
        unsafe { rz_doc_set_global_light(doc, 45.0, 60.0) }.is_null(),
        "the current value again"
    );
    let doc = apply(doc, |d| unsafe { rz_doc_set_global_light(d, 540.0, 120.0) });
    assert_eq!(light(doc), (-180.0, 90.0), "540 normalizes, 120 clamps");
    assert!(unsafe { rz_doc_set_global_light(doc, -180.0, 90.0) }.is_null());
    assert!(
        unsafe { rz_doc_set_global_light(doc, 180.0, 95.0) }.is_null(),
        "sanitizes to the same value"
    );
    unsafe { rz_doc_free(doc) };
}

#[test]
fn the_global_light_is_stored_to_four_decimals_and_an_echo_is_refused() {
    // The light is canonical like every style number: quantized to four
    // decimals on the way in, so the value a host reports (rounded to four
    // decimals from the f32 -> f64 widening, as get_document does) and
    // sends back is refused as unchanged — no phantom undo step, no
    // re-render of every lit layer.
    let dir = TempDir::new().unwrap();
    let doc = doc_from(&dir, "bg.png", &solid(4, 4, WHITE));
    let doc = apply(doc, |d| unsafe {
        rz_doc_set_global_light(d, 33.33333, 12.34567)
    });
    let (angle, altitude) = light(doc);
    assert_eq!((angle, altitude), (33.3333, 12.3457));
    let echo = |v: f32| ((f64::from(v) * 1e4).round() / 1e4) as f32;
    assert_eq!((echo(angle), echo(altitude)), (angle, altitude));
    assert!(
        unsafe { rz_doc_set_global_light(doc, echo(angle), echo(altitude)) }.is_null(),
        "the reported value echoed back is no change"
    );
    assert!(
        unsafe { rz_doc_set_global_light(doc, 33.33333, 12.34567) }.is_null(),
        "the original input again is no change"
    );
    assert!(
        unsafe { rz_doc_set_global_light(doc, 33.33334, 12.34567) }.is_null(),
        "a value within the quantum is no change either"
    );
    assert!(
        !unsafe { rz_doc_set_global_light(doc, 33.3334, 12.3457) }.is_null(),
        "a whole quantum away is a change"
    );
    unsafe { rz_doc_free(doc) };
}

// ------------------------------------------------------------------- rzdc --

#[test]
fn rzdc_v4_round_trips_the_style_and_the_light() {
    let dir = TempDir::new().unwrap();
    let doc = doc_from(&dir, "bg.png", &solid(24, 20, WHITE));
    let doc = add_layer(&dir, "top.png", doc, 0, &solid(6, 4, RED), "Rect");
    let doc = apply(doc, |d| unsafe { rz_doc_with_layer_offset(d, 1, 6, 6) });
    let doc = set_style(doc, 1, STYLE_JSON);
    let doc = apply(doc, |d| unsafe { rz_doc_set_global_light(d, 45.0, 60.0) });
    let canonical = ffi_style(doc, 1).unwrap();
    let before = flat_pixels(doc);

    let path = dir.path().join("styled.rzdc");
    let c = cpath(&path);
    let mut err: *mut c_char = ptr::null_mut();
    assert!(
        unsafe { rz_doc_save_native(doc, c.as_ptr(), &mut err) },
        "{}",
        take_err_string(err)
    );
    let bytes = std::fs::read(&path).unwrap();
    assert_eq!(&bytes[..4], b"RZDC");
    assert_eq!(
        u32::from_le_bytes(bytes[4..8].try_into().unwrap()),
        7,
        "layer styles bumped the format to 4, channels to 5, colour and \
         metadata to 6, groups and locks to 7"
    );
    assert_eq!(
        f32::from_le_bytes(bytes[20..24].try_into().unwrap()),
        45.0,
        "light angle after the count"
    );
    assert_eq!(
        f32::from_le_bytes(bytes[24..28].try_into().unwrap()),
        60.0,
        "then the altitude"
    );

    let mut err: *mut c_char = ptr::null_mut();
    let back = unsafe { rz_doc_open(c.as_ptr(), &mut err) };
    assert!(!back.is_null(), "reopen failed: {}", take_err_string(err));
    assert_eq!(
        ffi_style(back, 1).as_deref(),
        Some(canonical.as_str()),
        "the style survives verbatim"
    );
    assert_eq!(ffi_style(back, 0), None);
    assert!(!unsafe { rz_doc_layer_has_style(back, 0) });
    assert_eq!(light(back), (45.0, 60.0));
    assert_eq!(
        flat_pixels(back),
        before,
        "the projection survives the round trip"
    );

    let again = dir.path().join("again.rzdc");
    let c2 = cpath(&again);
    let mut err: *mut c_char = ptr::null_mut();
    assert!(
        unsafe { rz_doc_save_native(back, c2.as_ptr(), &mut err) },
        "{}",
        take_err_string(err)
    );
    assert_eq!(
        std::fs::read(&again).unwrap(),
        bytes,
        "resave is byte-identical"
    );
    unsafe { rz_doc_free(back) };
    unsafe { rz_doc_free(doc) };
}

#[test]
fn angles_beyond_the_f32_range_canonicalize_finite_and_round_trip() {
    // JSON allows any finite double; an angle past the f32 range must be
    // normalized in f64 BEFORE narrowing — narrowed first it is infinite,
    // its remainder NaN, and the NaN would be written as `null` (which the
    // reader refuses: the style vanishes on reopen), never compare equal
    // (phantom undo steps) and never re-parse.
    let dir = TempDir::new().unwrap();
    let base = rect_layer_doc((8, 8), (2, 2, 2, 2), RED);
    for (i, angle) in ["1e39", "-1e300", "1e308", "-3.5e38"]
        .into_iter()
        .enumerate()
    {
        let json = format!(
            "{{\"effects\":[{{\"type\":\"drop_shadow\",\"angle\":{angle},\
             \"use_global_light\":false}},{{\"type\":\"gradient_overlay\",\
             \"gradient\":{{\"angle\":{angle}}}}}]}}"
        );
        let doc = styled(&base, 1, &json);
        let style = Arc::clone(doc.layers[1].style.as_ref().expect("stored"));
        let got = shadow_of(&doc, 1).angle;
        let raw: f64 = angle.parse().unwrap();
        let want = ((raw + 180.0).rem_euclid(360.0) - 180.0) as f32;
        assert!(
            got.is_finite() && (-180.0..180.0).contains(&got),
            "{angle}: stored {got}"
        );
        assert!((got - want).abs() < 1e-3, "{angle}: {got} vs {want}");
        let echo = style.to_json();
        assert!(!echo.contains("\"angle\":null"), "{angle}: {echo}");
        assert_eq!(
            LayerStyle::from_json(&echo).unwrap(),
            *style,
            "{angle}: strict"
        );
        assert_eq!(
            LayerStyle::from_json_lenient(&echo).unwrap(),
            *style,
            "{angle}: lenient"
        );
        assert!(
            try_styled(&doc, 1, Some(&json)).unwrap().is_none(),
            "{angle}: the same JSON again is unchanged"
        );
        // The RZDC round trip keeps the style.
        let path = dir.path().join(format!("angle-{i}.rzdc"));
        let c = cpath(&path);
        let handle = Box::into_raw(Box::new(doc.clone()));
        let mut err: *mut c_char = ptr::null_mut();
        assert!(
            unsafe { rz_doc_save_native(handle, c.as_ptr(), &mut err) },
            "{}",
            take_err_string(err)
        );
        unsafe { rz_doc_free(handle) };
        let mut err: *mut c_char = ptr::null_mut();
        let back = unsafe { rz_doc_open(c.as_ptr(), &mut err) };
        assert!(!back.is_null(), "reopen failed: {}", take_err_string(err));
        assert_eq!(
            ffi_style(back, 1).as_deref(),
            Some(echo.as_str()),
            "{angle}: the style survives the file"
        );
        unsafe { rz_doc_free(back) };
    }
}

#[test]
fn rzdc_hand_built_records_load_or_refuse_deterministically() {
    let dir = TempDir::new().unwrap();
    let mut png = Vec::new();
    solid(2, 2, [1, 2, 3, 255])
        .write_to(&mut std::io::Cursor::new(&mut png), image::ImageFormat::Png)
        .unwrap();
    let header = |version: u32, light: Option<(f32, f32)>| {
        let mut buf = Vec::new();
        buf.extend_from_slice(b"RZDC");
        buf.extend_from_slice(&version.to_le_bytes());
        buf.extend_from_slice(&2u32.to_le_bytes()); // width
        buf.extend_from_slice(&2u32.to_le_bytes()); // height
        buf.extend_from_slice(&1u32.to_le_bytes()); // layer count
        if let Some((angle, altitude)) = light {
            buf.extend_from_slice(&angle.to_le_bytes());
            buf.extend_from_slice(&altitude.to_le_bytes());
        }
        buf
    };
    let record = |buf: &mut Vec<u8>| {
        buf.extend_from_slice(&3u32.to_le_bytes()); // name len
        buf.extend_from_slice(b"Old");
        buf.extend_from_slice(&0i32.to_le_bytes()); // offset x
        buf.extend_from_slice(&0i32.to_le_bytes()); // offset y
        buf.extend_from_slice(&1.0f32.to_le_bytes()); // opacity
        buf.extend_from_slice(&0u32.to_le_bytes()); // blend
        buf.push(1); // visible
        buf.extend_from_slice(&(png.len() as u32).to_le_bytes());
        buf.extend_from_slice(&png);
    };
    let v2_tail = |buf: &mut Vec<u8>| {
        buf.push(0); // mask present
        buf.push(1); // mask enabled
        buf.push(0); // meta present
    };
    let style_slot = |buf: &mut Vec<u8>, json: &str| {
        buf.push(1);
        buf.extend_from_slice(&(json.len() as u32).to_le_bytes());
        buf.extend_from_slice(json.as_bytes());
    };
    let default_light = GlobalLight::default();

    // v1, v2, v3: no style, default light.
    let mut v1 = header(1, None);
    record(&mut v1);
    let mut v2 = header(2, None);
    record(&mut v2);
    v2_tail(&mut v2);
    let mut v3 = header(3, None);
    record(&mut v3);
    v2_tail(&mut v3);
    v3.push(1); // clipped
    for (name, bytes) in [("v1", &v1), ("v2", &v2), ("v3", &v3)] {
        let doc = open_bytes(&dir, &format!("{name}.rzdc"), bytes)
            .unwrap_or_else(|e| panic!("{name}: {e}"));
        assert!(doc.layers[0].style.is_none(), "{name} has no style");
        assert_eq!(
            doc.global_light, default_light,
            "{name} takes the default light"
        );
    }

    // v4 with a style.
    let mut v4 = header(4, Some((45.0, 60.0)));
    record(&mut v4);
    v2_tail(&mut v4);
    v4.push(0); // clipped
    style_slot(
        &mut v4,
        "{\"effects\":[{\"type\":\"drop_shadow\",\"size\":9}]}",
    );
    let doc = open_bytes(&dir, "v4.rzdc", &v4).expect("v4 loads");
    assert_eq!(
        doc.global_light,
        GlobalLight {
            angle: 45.0,
            altitude: 60.0
        }
    );
    assert_eq!(shadow_of(&doc, 0).size, 9.0);

    // v4 without a style.
    let mut v4_none = header(4, Some((45.0, 60.0)));
    record(&mut v4_none);
    v2_tail(&mut v4_none);
    v4_none.push(0);
    v4_none.push(0); // style absent
    assert!(
        open_bytes(&dir, "v4-none.rzdc", &v4_none).unwrap().layers[0]
            .style
            .is_none()
    );

    // Deterministic refusals.
    let err = open_bytes(&dir, "no-record.rzdc", &header(4, Some((120.0, 30.0))))
        .err()
        .expect("must be refused");
    assert!(err.contains("unexpected end of file"), "{err}");
    let mut short = header(4, Some((120.0, 30.0)));
    record(&mut short);
    v2_tail(&mut short);
    short.push(0); // clipped — but no style byte
    let err = open_bytes(&dir, "short.rzdc", &short)
        .err()
        .expect("must be refused");
    assert!(
        err.contains("unexpected end of file"),
        "a v4 record without the style byte: {err}"
    );
    let mut v3_shaped = header(4, None);
    record(&mut v3_shaped);
    v2_tail(&mut v3_shaped);
    v3_shaped.push(0);
    assert!(
        open_bytes(&dir, "v3-shaped.rzdc", &v3_shaped).is_err(),
        "a v3-shaped file stamped 4"
    );
    let mut v8 = header(8, Some((120.0, 30.0)));
    record(&mut v8);
    let err = open_bytes(&dir, "v8.rzdc", &v8)
        .err()
        .expect("must be refused");
    assert!(err.contains("unsupported RZDC version 8"), "{err}");

    // Lenient style read.
    let malformed = {
        let mut b = header(4, Some((120.0, 30.0)));
        record(&mut b);
        v2_tail(&mut b);
        b.push(0);
        style_slot(&mut b, "{\"fill_opacity\":\"x\"}");
        b
    };
    let doc = open_bytes(&dir, "malformed.rzdc", &malformed).expect("loads");
    assert!(
        doc.layers[0].style.is_none(),
        "a structurally malformed style loads as none"
    );
    // A colour with a multi-byte character straddling a hex pair (the
    // parser once byte-sliced it and panicked, refusing the whole file):
    // malformed like any bad colour, so the layer loads with no style.
    let multibyte = {
        let mut b = header(4, Some((120.0, 30.0)));
        record(&mut b);
        v2_tail(&mut b);
        b.push(0);
        style_slot(
            &mut b,
            "{\"effects\":[{\"type\":\"drop_shadow\",\"color\":\"#aé123\"}]}",
        );
        b
    };
    let doc = open_bytes(&dir, "multibyte.rzdc", &multibyte).expect("loads");
    assert!(
        doc.layers[0].style.is_none(),
        "a multi-byte colour loads as no style, never a refused file"
    );
    let newer = {
        let mut b = header(4, Some((120.0, 30.0)));
        record(&mut b);
        v2_tail(&mut b);
        b.push(0);
        style_slot(
            &mut b,
            "{\"effects\":[{\"type\":\"pattern_overlay\"},{\"type\":\"drop_shadow\",\"size\":7}]}",
        );
        b
    };
    let doc = open_bytes(&dir, "newer.rzdc", &newer).expect("loads");
    assert_eq!(
        shadow_of(&doc, 0).size,
        7.0,
        "the known effect survives an unknown one"
    );
    assert_eq!(doc.layers[0].style.as_ref().unwrap().effects.len(), 1);
    let identity = {
        let mut b = header(4, Some((120.0, 30.0)));
        record(&mut b);
        v2_tail(&mut b);
        b.push(0);
        style_slot(
            &mut b,
            "{\"effects\":[{\"type\":\"drop_shadow\",\"enabled\":false}]}",
        );
        b
    };
    assert!(
        open_bytes(&dir, "identity.rzdc", &identity).unwrap().layers[0]
            .style
            .is_none()
    );

    // The light is sanitized, never refused.
    let mut odd_light = header(4, Some((f32::NAN, 1e9)));
    record(&mut odd_light);
    v2_tail(&mut odd_light);
    odd_light.push(0);
    odd_light.push(0);
    let doc = open_bytes(&dir, "odd-light.rzdc", &odd_light).expect("loads");
    assert_eq!(
        doc.global_light,
        GlobalLight {
            angle: 120.0,
            altitude: 90.0
        }
    );

    // The style cap is enforced by length before any read.
    let mut capped = header(4, Some((120.0, 30.0)));
    record(&mut capped);
    v2_tail(&mut capped);
    capped.push(0);
    capped.push(1);
    capped.extend_from_slice(&(16 * 1024 * 1024 + 1u32).to_le_bytes());
    let err = open_bytes(&dir, "capped.rzdc", &capped)
        .err()
        .expect("must be refused");
    assert!(err.contains("style length"), "{err}");
}

// ------------------------------------------------------------ ride-along --

#[test]
fn style_rides_along_every_layer_path() {
    let base = rect_layer_doc((24, 20), (6, 6, 6, 4), RED);
    let doc = styled(&base, 1, STYLE_JSON);
    let arc = Arc::clone(doc.layers[1].style.as_ref().unwrap());
    let same = |d: &RzDocument, what: &str| {
        assert!(
            Arc::ptr_eq(d.layers[1].style.as_ref().expect(what), &arc),
            "{what} keeps the same Arc"
        );
    };
    same(&doc.crop(2, 2, 20, 16).unwrap(), "crop");
    same(&doc.canvas_resize(30, 30, (3, 3)).unwrap(), "canvas_resize");
    same(&doc.rotate90(), "rotate90");
    same(&doc.flip_horizontal(), "flip");
    same(
        &doc.with_layer_offset(1, 1, 1).unwrap(),
        "with_layer_offset",
    );
    same(
        &doc.with_layer_opacity(1, 0.5).unwrap(),
        "with_layer_opacity",
    );
    same(
        &doc.with_layer_blend_mode(1, rasterize_core::doc::BlendMode::Screen)
            .unwrap(),
        "blend mode",
    );
    same(
        &doc.with_layer_pixels(1, solid(6, 4, BLUE)).unwrap(),
        "with_layer_pixels",
    );
    same(
        &doc.add_mask(1, rasterize_core::doc::MaskKind::RevealAll)
            .unwrap(),
        "add_mask",
    );
    // Painting through the FFI.
    let overlay = vec![0u8; 24 * 20 * 4];
    let handle = Box::into_raw(Box::new(doc.clone()));
    let painted =
        unsafe { rz_doc_painting_layer(handle, 1, overlay.as_ptr(), 24, 20, COMPOSITE_OVER, 1.0) };
    unsafe { rz_doc_free(handle) };
    assert!(!painted.is_null());
    let painted = *unsafe { Box::from_raw(painted) };
    same(&painted, "painting_layer");
    // Duplicate copies (shares the Arc); merge drops; flatten drops and
    // keeps the light.
    let dup = doc.duplicating_layer(1).unwrap();
    assert!(Arc::ptr_eq(dup.layers[2].style.as_ref().unwrap(), &arc));
    let merged = doc.merging_down(1).unwrap();
    assert!(merged.layers[0].style.is_none(), "merge drops the style");
    let lit = with_light(&doc, 10.0, 20.0);
    let flat = lit.flattening();
    assert!(flat.layers[0].style.is_none());
    assert_eq!(
        flat.global_light,
        GlobalLight {
            angle: 10.0,
            altitude: 20.0
        }
    );
    // Scale Effects: a 2x transform doubles distance and size, leaves the
    // spread; an exact translation keeps the very same Arc; a 2x
    // perspective and Image Size agree.
    let before = shadow_of(&doc, 1);
    let doubled = transformed(&doc, 1, [2.0, 0.0, 0.0, 2.0, 0.0, 0.0]);
    let after = shadow_of(&doubled, 1);
    assert_eq!(
        (after.distance, after.size, after.spread),
        (before.distance * 2.0, before.size * 2.0, before.spread)
    );
    assert!(!Arc::ptr_eq(
        doubled.layers[1].style.as_ref().unwrap(),
        &arc
    ));
    let moved = transformed(&doc, 1, [1.0, 0.0, 0.0, 1.0, 3.0, -2.0]);
    same(&moved, "exact translate");
    let rotated = transformed(&doc, 1, [0.0, 1.0, -1.0, 0.0, 0.0, 0.0]);
    same(&rotated, "exact rotation (factor 1)");
    let quad = [6.0, 6.0, 18.0, 6.0, 18.0, 14.0, 6.0, 14.0];
    let perspective = warped(&doc, 1, quad);
    let after = shadow_of(&perspective, 1);
    assert_eq!(
        (after.distance, after.size),
        (before.distance * 2.0, before.size * 2.0)
    );
    let resized = doc.resize(48, 40, FilterType::Triangle).unwrap();
    let after = shadow_of(&resized, 1);
    assert_eq!(
        (after.distance, after.size),
        (before.distance * 2.0, before.size * 2.0)
    );
    let unit = doc.resize(24, 20, FilterType::Triangle).unwrap();
    same(&unit, "a no-op resize");
    // The FFI getters see the scaled style too.
    let handle = Box::into_raw(Box::new(doubled));
    assert!(
        ffi_style(handle, 1).unwrap().contains("\"distance\":6.0"),
        "{}",
        ffi_style(handle, 1).unwrap()
    );
    unsafe { rz_doc_free(handle) };
}
