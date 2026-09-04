//! The RZDC version-6 DOCUMENT TAIL — the colour profile, the three
//! metadata packets and the print resolution — as a file format: the round
//! trip, the older versions that still load, the crafted tails the reader
//! must refuse or sanitize, the caps, and the ride-along sweep proving every
//! document op carries all three without copying them.
//!
//! Black-box through the C exports and the safe constructors, on fixtures
//! this file builds byte by byte; `color_tests` covers the colour maths and
//! `metadata_tests` the container splice. No golden files anywhere.

use std::ffi::CString;
use std::sync::Arc;

use image::imageops::FilterType;
use rasterize_core::doc::{MaskKind, RzDocument};
use rasterize_core::ffi_channel::*;
use rasterize_core::ffi_color::*;
use rasterize_core::ffi_doc::*;
use rasterize_core::metadata::{Metadata, Resolution};
use tempfile::TempDir;

mod common;
use common::*;

/// Mirrored from the header.
const PROFILE_DISPLAY_P3: std::ffi::c_int = 1;
const METADATA_EXIF: std::ffi::c_int = 0;
const METADATA_XMP: std::ffi::c_int = 1;
const METADATA_IPTC: std::ffi::c_int = 2;

fn open_bytes(dir: &TempDir, name: &str, bytes: &[u8]) -> Result<RzDocument, String> {
    let path = dir.path().join(name);
    std::fs::write(&path, bytes).unwrap();
    RzDocument::open(path.to_str().unwrap())
}

fn save_and_read(doc: &RzDocument, dir: &TempDir, name: &str) -> Vec<u8> {
    let path = dir.path().join(name);
    doc.save_native(path.to_str().unwrap()).expect("save");
    std::fs::read(&path).unwrap()
}

fn builtin_bytes(which: std::ffi::c_int) -> Vec<u8> {
    let len = rz_builtin_profile_len(which);
    let mut out = vec![0u8; len];
    assert!(unsafe { rz_builtin_profile(which, out.as_mut_ptr(), len) });
    out
}

/// A document carrying all three kinds of new state, built through the FFI
/// so the setters are exercised on the way in.
fn rich_document(dir: &TempDir) -> RzDocument {
    let doc = doc_from(dir, "rich.png", &opaque_pattern(6, 4));
    let p3 = builtin_bytes(PROFILE_DISPLAY_P3);
    let doc = apply(doc, |d| unsafe {
        rz_doc_assign_profile(d, p3.as_ptr(), p3.len())
    });
    // Blobs with a NUL and a high byte in them, so "verbatim" has to mean
    // byte for byte.
    let doc = apply(doc, |d| unsafe {
        rz_doc_set_metadata(d, METADATA_EXIF, EXIF.as_ptr(), EXIF.len())
    });
    let doc = apply(doc, |d| unsafe {
        rz_doc_set_metadata(d, METADATA_XMP, XMP.as_ptr(), XMP.len())
    });
    let doc = apply(doc, |d| unsafe {
        rz_doc_set_metadata(d, METADATA_IPTC, IPTC.as_ptr(), IPTC.len())
    });
    let doc = apply(doc, |d| unsafe { rz_doc_set_resolution(d, 300.0, 150.5) });
    let out = unsafe { &*doc }.clone();
    unsafe { rz_doc_free(doc) };
    out
}

const EXIF: &[u8] = b"II*\x00\x08\x00\x00\x00\x00\xff\x00\xfe";
const XMP: &[u8] = b"<x:xmpmeta\x00\xc3\xa9/>";
const IPTC: &[u8] = b"8BIM\x04\x04\x00\x00\x00\x00\x00\x02\xff\x00";

// ------------------------------------------------------------ round trip --

#[test]
fn rzdc_v6_round_trips_the_profile_packets_and_resolution() {
    let dir = TempDir::new().unwrap();
    let doc = rich_document(&dir);
    let bytes = save_and_read(&doc, &dir, "rich.rzdc");
    assert_eq!(&bytes[..4], b"RZDC");
    assert_eq!(
        u32::from_le_bytes(bytes[4..8].try_into().unwrap()),
        6,
        "the colour profile and the packets bumped the format to 6"
    );
    // The tail is at the very END of the file: the four blobs in order,
    // each preceded by its present byte and length.
    let mut expected_tail = Vec::new();
    expected_tail.extend_from_slice(&300.0f32.to_le_bytes());
    expected_tail.extend_from_slice(&150.5f32.to_le_bytes());
    for blob in [
        builtin_bytes(PROFILE_DISPLAY_P3).as_slice(),
        EXIF,
        XMP,
        IPTC,
    ] {
        expected_tail.push(1);
        expected_tail.extend_from_slice(&(blob.len() as u32).to_le_bytes());
        expected_tail.extend_from_slice(blob);
    }
    assert!(
        bytes.ends_with(&expected_tail),
        "the document tail is the last thing in the file"
    );

    let back = open_bytes(&dir, "rich-back.rzdc", &bytes).expect("reopen");
    assert_eq!(back.resolution, Resolution { x: 300.0, y: 150.5 });
    assert_eq!(
        &**back.profile.bytes(),
        builtin_bytes(PROFILE_DISPLAY_P3).as_slice()
    );
    assert_eq!(back.profile.name(), "Display P3");
    assert_eq!(back.metadata.exif.as_deref(), Some(EXIF));
    assert_eq!(back.metadata.xmp.as_deref(), Some(XMP));
    assert_eq!(back.metadata.iptc.as_deref(), Some(IPTC));

    // Re-encoding the reloaded document reproduces the file exactly.
    assert_eq!(
        save_and_read(&back, &dir, "rich-again.rzdc"),
        bytes,
        "the round trip is byte-identical"
    );
}

#[test]
fn the_builtin_srgb_profile_is_elided_from_the_file() {
    let dir = TempDir::new().unwrap();
    let doc = RzDocument::from_pixels(opaque_pattern(4, 3));
    let bytes = save_and_read(&doc, &dir, "plain.rzdc");
    // 12 bytes: two resolution floats and four absent-blob flags.
    assert_eq!(
        &bytes[bytes.len() - 12..],
        &[0, 0, 144, 66, 0, 0, 144, 66, 0, 0, 0, 0],
        "72 ppi twice, then four absent blobs"
    );
    let back = open_bytes(&dir, "plain-back.rzdc", &bytes).expect("reopen");
    assert!(
        back.profile.is_builtin_srgb(),
        "an absent ICC slot reads back as the built-in sRGB"
    );
    assert_eq!(back.resolution, Resolution::default());
    assert!(back.metadata.is_empty());
}

#[test]
fn a_zero_length_blob_is_distinguishable_from_an_absent_one() {
    let dir = TempDir::new().unwrap();
    let doc = RzDocument::from_pixels(opaque_pattern(3, 3));
    let empty = doc
        .set_metadata(rasterize_core::doc_color::MetadataKind::Xmp, Some(&[]))
        .expect("an empty packet is a change from absent");
    let bytes = save_and_read(&empty, &dir, "empty-blob.rzdc");
    let back = open_bytes(&dir, "empty-blob-back.rzdc", &bytes).expect("reopen");
    assert_eq!(
        back.metadata.xmp.as_deref(),
        Some(&[][..]),
        "present-and-empty is not absent"
    );
    assert!(back.metadata.exif.is_none());
    // And clearing it again is a change back.
    assert!(back
        .set_metadata(rasterize_core::doc_color::MetadataKind::Xmp, None)
        .is_some());
}

// -------------------------------------------------- older and crafted files --

/// The pieces of a hand-built RZDC file, the `style_format.rs` idiom
/// extended with a channel count and the version-6 tail.
struct Craft {
    png: Vec<u8>,
}

impl Craft {
    fn new() -> Self {
        let mut png = Vec::new();
        solid(2, 2, [1, 2, 3, 255])
            .write_to(&mut std::io::Cursor::new(&mut png), image::ImageFormat::Png)
            .unwrap();
        Craft { png }
    }

    /// A complete file at `version`, with every block older versions lack
    /// omitted, so each is a strict prefix of the next.
    fn file(&self, version: u32) -> Vec<u8> {
        let mut b = Vec::new();
        b.extend_from_slice(b"RZDC");
        b.extend_from_slice(&version.to_le_bytes());
        b.extend_from_slice(&2u32.to_le_bytes()); // width
        b.extend_from_slice(&2u32.to_le_bytes()); // height
        b.extend_from_slice(&1u32.to_le_bytes()); // layer count
        if version >= 4 {
            b.extend_from_slice(&120.0f32.to_le_bytes());
            b.extend_from_slice(&30.0f32.to_le_bytes());
        }
        b.extend_from_slice(&3u32.to_le_bytes()); // name length
        b.extend_from_slice(b"Old");
        b.extend_from_slice(&0i32.to_le_bytes());
        b.extend_from_slice(&0i32.to_le_bytes());
        b.extend_from_slice(&1.0f32.to_le_bytes());
        b.extend_from_slice(&0u32.to_le_bytes()); // blend
        b.push(1); // visible
        b.extend_from_slice(&(self.png.len() as u32).to_le_bytes());
        b.extend_from_slice(&self.png);
        if version >= 2 {
            b.push(0); // no mask
            b.push(1); // mask enabled
            b.push(0); // no meta
        }
        if version >= 3 {
            b.push(0); // not clipped
        }
        if version >= 4 {
            b.push(0); // no style
        }
        if version >= 5 {
            b.extend_from_slice(&0u32.to_le_bytes()); // no channels
        }
        if version >= 6 {
            b.extend_from_slice(&72.0f32.to_le_bytes());
            b.extend_from_slice(&72.0f32.to_le_bytes());
            b.extend_from_slice(&[0, 0, 0, 0]);
        }
        b
    }
}

#[test]
fn hand_built_v1_to_v5_records_take_the_tail_defaults() {
    let dir = TempDir::new().unwrap();
    let craft = Craft::new();
    for version in 1..=5u32 {
        let doc = open_bytes(&dir, &format!("v{version}.rzdc"), &craft.file(version))
            .unwrap_or_else(|e| panic!("v{version}: {e}"));
        assert_eq!(
            doc.resolution,
            Resolution::default(),
            "v{version} takes 72 ppi"
        );
        assert!(
            doc.profile.is_builtin_srgb(),
            "v{version} takes the built-in sRGB"
        );
        assert_eq!(
            doc.metadata,
            Metadata::default(),
            "v{version} has no packets"
        );
    }
    // And a version-6 file with the tail loads the same way.
    let doc = open_bytes(&dir, "v6.rzdc", &craft.file(6)).expect("v6");
    assert_eq!(doc.resolution, Resolution::default());
}

#[test]
fn crafted_document_tails_are_refused_or_sanitized() {
    let dir = TempDir::new().unwrap();
    let craft = Craft::new();
    let base = craft.file(5);

    // An over-cap declared blob length is refused BEFORE a byte is read.
    let mut over = base.clone();
    over[4..8].copy_from_slice(&6u32.to_le_bytes());
    over.extend_from_slice(&72.0f32.to_le_bytes());
    over.extend_from_slice(&72.0f32.to_le_bytes());
    over.push(1);
    over.extend_from_slice(&(16 * 1024 * 1024 + 1u32).to_le_bytes());
    let err = open_bytes(&dir, "over.rzdc", &over)
        .err()
        .expect("must be refused");
    assert!(err.contains("ICC profile length"), "{err}");

    // A declared length with no bytes behind it is a truncation.
    let mut short = base.clone();
    short[4..8].copy_from_slice(&6u32.to_le_bytes());
    short.extend_from_slice(&72.0f32.to_le_bytes());
    short.extend_from_slice(&72.0f32.to_le_bytes());
    short.push(1);
    short.extend_from_slice(&64u32.to_le_bytes());
    let err = open_bytes(&dir, "short.rzdc", &short)
        .err()
        .expect("must be refused");
    assert!(err.contains("unexpected end of file"), "{err}");

    // A v6 file truncated after ppiX.
    let mut cut = base.clone();
    cut[4..8].copy_from_slice(&6u32.to_le_bytes());
    cut.extend_from_slice(&72.0f32.to_le_bytes());
    let err = open_bytes(&dir, "cut.rzdc", &cut)
        .err()
        .expect("must be refused");
    assert!(err.contains("unexpected end of file"), "{err}");

    // A v5-shaped file stamped 6 has no tail at all.
    let mut mislabelled = base.clone();
    mislabelled[4..8].copy_from_slice(&6u32.to_le_bytes());
    assert!(
        open_bytes(&dir, "mislabelled.rzdc", &mislabelled).is_err(),
        "a v5-shaped file stamped 6 is refused"
    );

    // Absurd resolutions are SANITIZED, never refused — the global light's
    // rule, applied to the tail.
    for (ppi, expected) in [
        (f32::NAN, 72.0f32),
        (0.0, 72.0),
        (-5.0, 72.0),
        (1e9, 30_000.0),
        (0.001, 1.0),
    ] {
        let mut odd = base.clone();
        odd[4..8].copy_from_slice(&6u32.to_le_bytes());
        odd.extend_from_slice(&ppi.to_le_bytes());
        odd.extend_from_slice(&ppi.to_le_bytes());
        odd.extend_from_slice(&[0, 0, 0, 0]);
        let doc = open_bytes(&dir, "odd.rzdc", &odd)
            .unwrap_or_else(|e| panic!("{ppi} must load, not fail: {e}"));
        assert_eq!(doc.resolution.x, expected, "{ppi} sanitizes to {expected}");
    }

    // A profile blob that no longer parses falls back to the default rather
    // than refusing a file whose pixels are fine.
    let mut junk = base.clone();
    junk[4..8].copy_from_slice(&6u32.to_le_bytes());
    junk.extend_from_slice(&72.0f32.to_le_bytes());
    junk.extend_from_slice(&72.0f32.to_le_bytes());
    junk.push(1);
    junk.extend_from_slice(&4u32.to_le_bytes());
    junk.extend_from_slice(b"junk");
    junk.extend_from_slice(&[0, 0, 0]);
    let doc = open_bytes(&dir, "junk.rzdc", &junk).expect("loads");
    assert!(doc.profile.is_builtin_srgb());
}

#[test]
fn the_blob_cap_is_enforced_by_the_setter_before_the_writer() {
    let dir = TempDir::new().unwrap();
    let doc = doc_from(&dir, "cap.png", &solid(2, 2, [1, 2, 3, 255]));
    let over = vec![0u8; 16 * 1024 * 1024 + 1];
    for kind in [METADATA_EXIF, METADATA_XMP, METADATA_IPTC] {
        assert!(
            unsafe { rz_doc_set_metadata(doc, kind, over.as_ptr(), over.len()) }.is_null(),
            "kind {kind}: a packet the writer would refuse is never stored"
        );
    }
    assert!(
        unsafe { rz_doc_assign_profile(doc, over.as_ptr(), over.len()) }.is_null(),
        "and neither is an over-cap profile"
    );
    unsafe { rz_doc_free(doc) };
}

#[test]
fn resolution_sanitizes_and_refuses_an_echo() {
    let dir = TempDir::new().unwrap();
    let doc = doc_from(&dir, "r.png", &solid(2, 2, [1, 2, 3, 255]));
    assert_eq!(unsafe { rz_doc_resolution_x(doc) }, 72.0);

    for (x, y) in [
        (f32::NAN, 300.0f32),
        (300.0, f32::INFINITY),
        (0.0, 300.0),
        (-1.0, 300.0),
    ] {
        assert!(
            unsafe { rz_doc_set_resolution(doc, x, y) }.is_null(),
            "({x}, {y}) is refused rather than sanitized into an edit"
        );
    }
    assert!(
        unsafe { rz_doc_set_resolution(doc, 72.0, 72.0) }.is_null(),
        "setting what it already holds is a refusal"
    );

    // Out-of-range values clamp; the clamped value echoed back is refused.
    let big = unsafe { rz_doc_set_resolution(doc, 1e9, 1e9) };
    assert!(!big.is_null());
    assert_eq!(unsafe { rz_doc_resolution_x(big) }, 30_000.0);
    assert!(unsafe { rz_doc_set_resolution(big, 30_000.0, 30_000.0) }.is_null());

    // Four decimals, like the global light: a reported value round-trips
    // (the `the_global_light_is_stored_to_four_decimals_and_an_echo_is_refused`
    // idiom, applied to the twin sanitizer).
    let odd = unsafe { rz_doc_set_resolution(doc, 333.33333, 149.98765) };
    assert!(!odd.is_null());
    let (x, y) = unsafe { (rz_doc_resolution_x(odd), rz_doc_resolution_y(odd)) };
    assert_eq!((x, y), (333.3333, 149.9877));
    let echo = |v: f32| ((f64::from(v) * 1e4).round() / 1e4) as f32;
    assert_eq!((echo(x), echo(y)), (x, y));
    assert!(
        unsafe { rz_doc_set_resolution(odd, echo(x), echo(y)) }.is_null(),
        "the reported value echoed back is no change"
    );
    assert!(
        unsafe { rz_doc_set_resolution(odd, 333.33333, 149.98765) }.is_null(),
        "and so is the original input again"
    );
    // And pixels never move.
    assert_eq!(flat_pixels(odd), flat_pixels(doc));

    unsafe {
        rz_doc_free(odd);
        rz_doc_free(big);
        rz_doc_free(doc);
    }
}

// ------------------------------------------------------------ ride-along --

#[test]
fn colour_and_metadata_ride_along_every_document_path() {
    let dir = TempDir::new().unwrap();
    let base = rich_document(&dir);
    let doc = base
        .adding_image_layer(0, solid(6, 4, [9, 9, 9, 200]), "Top")
        .expect("a second layer");
    let profile = Arc::clone(&doc.profile);
    let exif = Arc::clone(doc.metadata.exif.as_ref().unwrap());
    let resolution = doc.resolution;

    let same = |d: &RzDocument, what: &str| {
        assert!(
            Arc::ptr_eq(&d.profile, &profile),
            "{what} keeps the same profile Arc — carried, not copied"
        );
        assert!(
            Arc::ptr_eq(d.metadata.exif.as_ref().expect(what), &exif),
            "{what} keeps the same EXIF Arc"
        );
        assert_eq!(d.resolution, resolution, "{what} keeps the resolution");
    };

    same(&doc.crop(1, 1, 4, 3).unwrap(), "crop");
    same(&doc.canvas_resize(10, 10, (2, 2)).unwrap(), "canvas_resize");
    same(&doc.rotate180(), "rotate180");
    same(&doc.flip_horizontal(), "flip_horizontal");
    same(&doc.flip_vertical(), "flip_vertical");
    same(&doc.resize(12, 8, FilterType::Triangle).unwrap(), "resize");
    same(&doc.flattening(), "flattening");
    same(&doc.merging_down(1).unwrap(), "merging_down");
    same(&doc.duplicating_layer(1).unwrap(), "duplicating_layer");
    same(&doc.removing_layer(1).unwrap(), "removing_layer");
    same(&doc.add_mask(1, MaskKind::RevealAll).unwrap(), "add_mask");
    same(
        &doc.with_layer_opacity(1, 0.5).unwrap(),
        "with_layer_opacity",
    );

    // The rotations carry them too, but with the two resolutions swapped.
    for (turned, what) in [(doc.rotate90(), "rotate90"), (doc.rotate270(), "rotate270")] {
        assert!(Arc::ptr_eq(&turned.profile, &profile), "{what}");
        assert!(Arc::ptr_eq(turned.metadata.exif.as_ref().unwrap(), &exif));
    }

    // Through the FFI: painting, the channel ops and the layer transform.
    let handle = Box::into_raw(Box::new(doc.clone()));
    let overlay = [0u8; 6 * 4 * 4];
    let painted = unsafe { rz_doc_painting_layer(handle, 1, overlay.as_ptr(), 6, 4, 0, 1.0) };
    assert!(!painted.is_null());
    same(unsafe { &*painted }, "painting_layer");

    let name = CString::new("Saved").unwrap();
    let plane = [128u8; 24];
    let channelled =
        unsafe { rz_doc_add_channel(handle, name.as_ptr(), plane.as_ptr(), 6, 4, 255, 0, 0, 0.5) };
    assert!(!channelled.is_null());
    same(unsafe { &*channelled }, "add_channel");

    let matrix = [1.0, 0.0, 0.0, 1.0, 2.0, 1.0];
    let transformed =
        unsafe { rz_doc_transform_layer(handle, 1, matrix.as_ptr(), FILTER_BILINEAR) };
    assert!(!transformed.is_null());
    same(unsafe { &*transformed }, "transform_layer");

    unsafe {
        rz_doc_free(transformed);
        rz_doc_free(channelled);
        rz_doc_free(painted);
        rz_doc_free(handle);
    }
}

#[test]
fn rotating_the_document_swaps_the_two_resolutions() {
    let dir = TempDir::new().unwrap();
    let doc = doc_from(&dir, "rot.png", &opaque_pattern(6, 4));
    let doc = apply(doc, |d| unsafe { rz_doc_set_resolution(d, 300.0, 150.0) });
    let doc = unsafe { &*doc }.clone();

    let turned = doc.rotate90();
    assert_eq!(turned.resolution, Resolution { x: 150.0, y: 300.0 });
    assert_eq!(
        doc.rotate270().resolution,
        Resolution { x: 150.0, y: 300.0 }
    );
    for (kept, what) in [
        (doc.rotate180(), "rotate180"),
        (doc.flip_horizontal(), "flip_horizontal"),
        (doc.flip_vertical(), "flip_vertical"),
    ] {
        assert_eq!(
            kept.resolution,
            Resolution { x: 300.0, y: 150.0 },
            "{what} leaves the axes where they were"
        );
    }
    assert_eq!(
        turned.rotate90().rotate90().rotate90().resolution,
        doc.resolution,
        "four quarter turns are the identity"
    );
    // And a resample changes the pixels but never the ppi (Photoshop's
    // "Resample: on" case).
    assert_eq!(
        doc.resize(12, 8, FilterType::Triangle).unwrap().resolution,
        doc.resolution
    );
}
