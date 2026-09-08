//! RZDC VERSION 8 — the guide list and the ruler origin — as a file format:
//! the round trip and the byte-identical resave, the twenty-byte tail
//! property, every older version still loading with the guide defaults, the
//! crafted blocks the reader must refuse or sanitize, and the ride-along
//! sweep proving every document op leaves the guides where the geometry table
//! says.
//!
//! Black-box through the C exports and the safe constructors, on fixtures
//! this file builds byte by byte (the `group_format` skeleton); `guide_tests`
//! covers the model and the ops. No golden files anywhere.

use std::ffi::{c_char, c_int};
use std::ptr;

use rasterize_core::doc::RzDocument;
use rasterize_core::doc_guide::GuideOrientation;
use rasterize_core::ffi_doc::*;
use rasterize_core::ffi_guide::*;
use tempfile::TempDir;

mod common;
use common::*;

/// `RzGuideOrientation`, mirrored from the header like the tables in
/// `tests/common`.
const HORIZONTAL: u8 = 0;
const VERTICAL: u8 = 1;

/// The guide cap, mirrored so the crafted files below do not depend on the
/// crate's constant (`guide_tests` is where the two are checked to agree).
const MAX_GUIDES: u32 = 1024;

/// The size of a guide-less version-8 tail: two f64 origin components plus
/// the u32 count. The property the whole format decision rests on.
const GUIDE_TAIL_BYTES: usize = 20;

// ---------------------------------------------------------------- helpers --

fn open_bytes(dir: &TempDir, name: &str, bytes: &[u8]) -> Result<RzDocument, String> {
    let path = dir.path().join(name);
    std::fs::write(&path, bytes).unwrap();
    RzDocument::open(path.to_str().unwrap())
}

fn save_and_read(doc: *const RzDocument, dir: &TempDir, name: &str) -> Vec<u8> {
    let path = dir.path().join(name);
    let c = cpath(&path);
    let mut err: *mut c_char = ptr::null_mut();
    assert!(
        unsafe { rz_doc_save_native(doc, c.as_ptr(), &mut err) },
        "{}",
        take_err_string(err)
    );
    std::fs::read(&path).unwrap()
}

fn reopen(dir: &TempDir, name: &str) -> *mut RzDocument {
    let c = cpath(&dir.path().join(name));
    let mut err: *mut c_char = ptr::null_mut();
    let doc = unsafe { rz_doc_open(c.as_ptr(), &mut err) };
    assert!(!doc.is_null(), "reopen {name}: {}", take_err_string(err));
    doc
}

/// The whole guide list as (orientation, position) pairs, through the FFI.
fn guides(doc: *const RzDocument) -> Vec<(c_int, f64)> {
    (0..unsafe { rz_doc_guide_count(doc) })
        .map(|i| unsafe {
            (
                rz_doc_guide_orientation(doc, i),
                rz_doc_guide_position(doc, i),
            )
        })
        .collect()
}

/// The same, off a safely-owned document (the crafted-file path).
fn model_guides(doc: &RzDocument) -> Vec<(u8, f64)> {
    doc.guides
        .iter()
        .map(|g| {
            let o = match g.orientation {
                GuideOrientation::Horizontal => HORIZONTAL,
                GuideOrientation::Vertical => VERTICAL,
            };
            (o, g.position)
        })
        .collect()
}

fn origin(doc: *const RzDocument) -> (f64, f64) {
    let mut out = [0.0f64; 2];
    assert!(unsafe { rz_doc_ruler_origin(doc, out.as_mut_ptr()) });
    (out[0], out[1])
}

fn add(doc: *mut RzDocument, orientation: u8, position: f64) -> *mut RzDocument {
    apply(doc, |d| unsafe {
        rz_doc_add_guide(d, c_int::from(orientation), position)
    })
}

/// A document -> document FFI op, for the ride-along sweep below.
type DocOp = Box<dyn Fn(*const RzDocument) -> *mut RzDocument>;

/// One row of the ride-along sweep: what the op is called, the op, the guide
/// list it must produce, and the ruler origin it must produce.
type Row = (&'static str, DocOp, Vec<(c_int, f64)>, (f64, f64));

// ------------------------------------------------------------- round trip --

/// A 200 x 120 canvas carrying guides on both axes — including one on each
/// canvas edge, since those are the boundary the format's clamp acts on — and
/// a ruler origin off the corner.
fn fixture(dir: &TempDir) -> *mut RzDocument {
    let mut doc = doc_from(dir, "bg.png", &solid(200, 120, RED));
    doc = add_layer(dir, "top.png", doc, 0, &solid(16, 16, BLUE), "Top");
    for (orientation, position) in [
        (VERTICAL, 0.0),
        (VERTICAL, 37.25),
        (VERTICAL, 200.0),
        (HORIZONTAL, 12.5),
        (HORIZONTAL, 120.0),
    ] {
        doc = add(doc, orientation, position);
    }
    apply(doc, |d| unsafe { rz_doc_set_ruler_origin(d, 37.25, 12.5) })
}

#[test]
fn version_8_round_trips_the_guides_and_the_ruler_origin() {
    let dir = TempDir::new().unwrap();
    let doc = fixture(&dir);
    let before = guides(doc);
    let before_origin = origin(doc);

    let bytes = save_and_read(doc, &dir, "guides.rzdc");
    assert_eq!(&bytes[..4], b"RZDC");
    assert_eq!(
        u32::from_le_bytes(bytes[4..8].try_into().unwrap()),
        8,
        "guides and the ruler origin bumped the format to 8"
    );

    let back = reopen(&dir, "guides.rzdc");
    assert_eq!(guides(back), before, "every line comes back, in order");
    assert_eq!(origin(back), before_origin, "and so does the origin");

    // Resaving the reopened document must produce the SAME bytes: anything
    // the reader dropped, reordered or re-quantized would show up here.
    let again = save_and_read(back, &dir, "guides-again.rzdc");
    assert_eq!(again, bytes, "the resave is byte-identical");
    unsafe {
        rz_doc_free(back);
        rz_doc_free(doc);
    }
}

// -------------------------------------------------------- the crafted files --

/// Builds RZDC files record by record, so an older version is a real file of
/// that version rather than a truncation of a newer one, and so the version-8
/// tail can be crafted independently of the writer.
struct Craft {
    png: Vec<u8>,
    canvas: (u32, u32),
}

/// One layer record's worth of state this file cares about — everything else
/// takes the format's own defaults.
#[derive(Clone, Copy, Default)]
struct Record;

/// The version-8 tail, hand-assembled.
#[derive(Clone, Copy)]
struct Tail {
    origin: (f64, f64),
    /// Writes this count instead of the guide list's real length, for the
    /// crafted "declares more guides than it holds" file.
    count_override: Option<u32>,
}

impl Default for Tail {
    fn default() -> Self {
        Tail {
            origin: (0.0, 0.0),
            count_override: None,
        }
    }
}

impl Craft {
    fn new(canvas: (u32, u32)) -> Self {
        let mut png = Vec::new();
        solid(1, 1, [0, 0, 0, 0])
            .write_to(&mut std::io::Cursor::new(&mut png), image::ImageFormat::Png)
            .unwrap();
        Craft { png, canvas }
    }

    /// A complete file at `version` holding `records`, with every block older
    /// versions lack omitted. The guide tail is written only at version 8.
    fn file(&self, version: u32, records: &[Record], guides: &[(u8, f64)], tail: Tail) -> Vec<u8> {
        let mut b = Vec::new();
        b.extend_from_slice(b"RZDC");
        b.extend_from_slice(&version.to_le_bytes());
        b.extend_from_slice(&self.canvas.0.to_le_bytes());
        b.extend_from_slice(&self.canvas.1.to_le_bytes());
        b.extend_from_slice(&(records.len() as u32).to_le_bytes());
        if version >= 4 {
            b.extend_from_slice(&120.0f32.to_le_bytes());
            b.extend_from_slice(&30.0f32.to_le_bytes());
        }
        for _ in records {
            b.extend_from_slice(&3u32.to_le_bytes());
            b.extend_from_slice(b"Old");
            b.extend_from_slice(&0i32.to_le_bytes());
            b.extend_from_slice(&0i32.to_le_bytes());
            b.extend_from_slice(&1.0f32.to_le_bytes());
            b.extend_from_slice(&0u32.to_le_bytes());
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
            if version >= 7 {
                b.extend_from_slice(&0u32.to_le_bytes()); // locks
                b.extend_from_slice(&0u32.to_le_bytes()); // link
                b.extend_from_slice(&0u16.to_le_bytes()); // depth
                b.push(0); // raster
                b.push(1); // open
            }
        }
        if version >= 5 {
            b.extend_from_slice(&0u32.to_le_bytes()); // no channels
        }
        if version >= 6 {
            b.extend_from_slice(&72.0f32.to_le_bytes());
            b.extend_from_slice(&72.0f32.to_le_bytes());
            b.extend_from_slice(&[0, 0, 0, 0]); // no ICC / EXIF / XMP / IPTC
        }
        if version >= 8 {
            b.extend_from_slice(&tail.origin.0.to_le_bytes());
            b.extend_from_slice(&tail.origin.1.to_le_bytes());
            let count = tail.count_override.unwrap_or(guides.len() as u32);
            b.extend_from_slice(&count.to_le_bytes());
            for (orientation, position) in guides {
                b.push(*orientation);
                b.extend_from_slice(&position.to_le_bytes());
            }
        }
        b
    }
}

#[test]
fn hand_built_v1_to_v7_files_take_the_guide_defaults() {
    let dir = TempDir::new().unwrap();
    let craft = Craft::new((16, 16));
    let records = [Record, Record];
    for version in 1..=7u32 {
        let doc = open_bytes(
            &dir,
            &format!("v{version}.rzdc"),
            &craft.file(version, &records, &[], Tail::default()),
        )
        .unwrap_or_else(|e| panic!("v{version}: {e}"));
        assert_eq!(doc.layers.len(), 2);
        assert!(doc.guides.is_empty(), "v{version}: no guides");
        assert_eq!(
            doc.ruler_origin,
            (0.0, 0.0),
            "v{version}: the ruler zero is the canvas's top-left"
        );
    }
    // And a version-8 file carries what it was given.
    let doc = open_bytes(
        &dir,
        "v8.rzdc",
        &craft.file(
            8,
            &records,
            &[(VERTICAL, 4.0), (HORIZONTAL, 9.0)],
            Tail {
                origin: (2.0, 3.0),
                count_override: None,
            },
        ),
    )
    .expect("v8 loads");
    assert_eq!(model_guides(&doc), vec![(HORIZONTAL, 9.0), (VERTICAL, 4.0)]);
    assert_eq!(doc.ruler_origin, (2.0, 3.0));
}

#[test]
fn a_guide_less_v8_file_is_a_v7_file_plus_twenty_bytes() {
    // A SIZE property, not a literal byte prefix: the version word is a u32
    // at byte offset 4, so the two files necessarily differ there. The
    // tail-append is what makes even this much hold — versions 4 and 7 both
    // broke it, because their bytes go inside each layer record.
    let dir = TempDir::new().unwrap();
    let craft = Craft::new((16, 16));
    let records = [Record, Record];
    let v7 = craft.file(7, &records, &[], Tail::default());
    let v8 = craft.file(8, &records, &[], Tail::default());

    assert_eq!(v8.len(), v7.len() + GUIDE_TAIL_BYTES);
    assert_eq!(&v8[..4], &v7[..4], "the magic is unchanged");
    assert_ne!(&v8[4..8], &v7[4..8], "the version word is the only edit");
    assert_eq!(
        &v8[8..v7.len()],
        &v7[8..],
        "everything after the version word is byte-for-byte the older file"
    );
    assert_eq!(
        &v8[v7.len()..],
        &[0u8; GUIDE_TAIL_BYTES],
        "and the tail is a zero origin and a zero count"
    );

    // Both open, and to the same document.
    let a = open_bytes(&dir, "p7.rzdc", &v7).expect("v7 loads");
    let b = open_bytes(&dir, "p8.rzdc", &v8).expect("v8 loads");
    assert_eq!(a.layers.len(), b.layers.len());
    assert!(a.guides.is_empty() && b.guides.is_empty());
    assert_eq!(a.ruler_origin, b.ruler_origin);

    // The same property against the REAL writer: strip the twenty bytes the
    // version-8 tail added and wind the version word back, and what is left
    // is a version-7 file this build still reads.
    let doc = doc_from(&dir, "plain.png", &solid(16, 16, RED));
    let written = save_and_read(doc, &dir, "plain.rzdc");
    unsafe { rz_doc_free(doc) };
    let mut derived = written[..written.len() - GUIDE_TAIL_BYTES].to_vec();
    derived[4..8].copy_from_slice(&7u32.to_le_bytes());
    let back = open_bytes(&dir, "derived.rzdc", &derived).expect("the derived v7 file loads");
    assert!(back.guides.is_empty());
    assert_eq!(back.ruler_origin, (0.0, 0.0));
    assert_eq!(back.layers.len(), 1);
}

#[test]
fn crafted_version_8_blocks_are_refused_or_sanitized() {
    let dir = TempDir::new().unwrap();
    let craft = Craft::new((100, 60));
    let records = [Record];
    let file = |guides: &[(u8, f64)], tail: Tail| craft.file(8, &records, guides, tail);

    // REFUSED — the two structural claims. An orientation is a claim like the
    // layer-kind byte, not a cosmetic value, and a count is a claim about how
    // much the file holds.
    let err = open_bytes(&dir, "orient.rzdc", &file(&[(2, 10.0)], Tail::default()))
        .err()
        .expect("an unknown orientation must be refused");
    assert!(err.contains("orientation"), "{err}");
    let err = open_bytes(
        &dir,
        "count.rzdc",
        &file(
            &[],
            Tail {
                origin: (0.0, 0.0),
                count_override: Some(MAX_GUIDES + 1),
            },
        ),
    )
    .err()
    .expect("a count over the cap must be refused");
    assert!(err.contains("guide count"), "{err}");
    // ...and the cap itself is checked BEFORE a byte of the list is read, so
    // a file that merely CLAIMS a million guides is refused instantly rather
    // than allocating for them.
    assert!(open_bytes(
        &dir,
        "huge.rzdc",
        &file(
            &[],
            Tail {
                origin: (0.0, 0.0),
                count_override: Some(1_000_000),
            }
        )
    )
    .is_err());

    // SANITIZED — a broken VALUE is repaired at the nearest legal one.
    let doc = open_bytes(
        &dir,
        "values.rzdc",
        &file(
            &[
                (VERTICAL, f64::NAN),
                (VERTICAL, 500.0),
                (VERTICAL, -25.0),
                (HORIZONTAL, 1e300),
                (VERTICAL, 12.345_678),
            ],
            Tail {
                origin: (f64::INFINITY, -4.0),
                count_override: None,
            },
        ),
    )
    .expect("broken values load");
    assert_eq!(
        model_guides(&doc),
        vec![
            (HORIZONTAL, 60.0),
            (VERTICAL, 0.0),
            (VERTICAL, 12.3457),
            (VERTICAL, 100.0),
        ],
        "a non-finite position DROPS that guide; an out-of-canvas one is \
         CLAMPED to the nearest edge — deliberately the opposite of `crop`'s \
         drop, because a value in a crafted file is broken rather than cut \
         out of the picture by a user; and every position is quantized"
    );
    assert_eq!(
        doc.ruler_origin,
        (0.0, 0.0),
        "a non-finite origin component becomes 0, a negative one clamps to it"
    );

    // ...and the list comes back in the model's canonical order, with
    // coincident entries collapsed, whatever order the file listed them in.
    let doc = open_bytes(
        &dir,
        "order.rzdc",
        &file(
            &[
                (VERTICAL, 80.0),
                (HORIZONTAL, 5.0),
                (VERTICAL, 20.0),
                (VERTICAL, 80.0),
                (VERTICAL, 80.000_001),
            ],
            Tail::default(),
        ),
    )
    .expect("out-of-order duplicates load");
    assert_eq!(
        model_guides(&doc),
        vec![(HORIZONTAL, 5.0), (VERTICAL, 20.0), (VERTICAL, 80.0)],
        "sorted, and the three coincident verticals are one line"
    );

    // A truncated tail is an ordinary short read, not a panic.
    let mut short = file(&[(VERTICAL, 10.0)], Tail::default());
    short.truncate(short.len() - 4);
    assert!(open_bytes(&dir, "short.rzdc", &short).is_err());
}

#[test]
fn a_full_guide_list_writes_nine_bytes_each_and_reads_back() {
    // The cap is enforced at BOTH ends, like the layer and channel counts, so
    // a document this build can build is always one it can write and read.
    // The creating op refuses the 1025th guide (`guide_tests`), so the
    // writer's own check can never fire for a document this build made —
    // which is exactly the invariant, and what this test pins.
    let dir = TempDir::new().unwrap();
    let mut doc = doc_from(&dir, "full.png", &solid(2048, 8, RED));
    for i in 0..rz_max_guides() {
        doc = add(doc, VERTICAL, i as f64);
    }
    let bytes = save_and_read(doc, &dir, "full.rzdc");
    let per_guide = 9; // u8 orientation + f64 position
    let list_start = bytes.len() - per_guide * rz_max_guides();
    assert_eq!(
        u32::from_le_bytes(bytes[list_start - 4..list_start].try_into().unwrap()),
        MAX_GUIDES,
        "the count word sits exactly nine bytes per guide from the end"
    );
    // The same document with the list cleared is nine bytes per guide
    // shorter — the whole cost of 1024 guides is 9 KB.
    let empty = apply(unsafe { rz_doc_clone(doc) }, |d| unsafe {
        rz_doc_clear_guides(d)
    });
    let plain = save_and_read(empty, &dir, "empty.rzdc");
    unsafe { rz_doc_free(empty) };
    assert_eq!(bytes.len(), plain.len() + per_guide * rz_max_guides());

    let back = reopen(&dir, "full.rzdc");
    assert_eq!(unsafe { rz_doc_guide_count(back) }, rz_max_guides());
    assert_eq!(guides(back), guides(doc), "every one of them comes back");
    unsafe {
        rz_doc_free(back);
        rz_doc_free(doc);
    }
}

// -------------------------------------------------------------- ride-along --

/// Every document op run once on the fixture, each asserting the guides and
/// the ruler origin land where the geometry table says AND survive a save and
/// reopen at the new canvas size. This sweep is where the bugs are: the crop
/// family DROPS what left the window while the scale and the permutations
/// CLAMP, and each of those is a separate code path.
#[test]
fn every_document_op_carries_the_guides_and_the_origin() {
    let dir = TempDir::new().unwrap();
    let doc = fixture(&dir);
    // The fixture, restated as the oracle every row below is measured
    // against: verticals at 0, 37.25 and 200 on a 200-wide canvas, and
    // horizontals at 12.5 and 120 on a 120-tall one.
    assert_eq!(
        guides(doc),
        vec![(0, 12.5), (0, 120.0), (1, 0.0), (1, 37.25), (1, 200.0),]
    );

    let rows: Vec<Row> = vec![
        (
            // A quarter turn exchanges every orientation: x = a becomes
            // y = a, y = b becomes x = H - b.
            "rotate90",
            Box::new(|d| unsafe { rz_doc_rotate90(d) }),
            vec![(0, 0.0), (0, 37.25), (0, 200.0), (1, 0.0), (1, 107.5)],
            (120.0 - 12.5, 37.25),
        ),
        (
            "rotate180",
            Box::new(|d| unsafe { rz_doc_rotate180(d) }),
            vec![(0, 0.0), (0, 107.5), (1, 0.0), (1, 162.75), (1, 200.0)],
            (200.0 - 37.25, 120.0 - 12.5),
        ),
        (
            "rotate270",
            Box::new(|d| unsafe { rz_doc_rotate270(d) }),
            vec![(0, 0.0), (0, 162.75), (0, 200.0), (1, 12.5), (1, 120.0)],
            (12.5, 200.0 - 37.25),
        ),
        (
            "flip_horizontal",
            Box::new(|d| unsafe { rz_doc_flip_horizontal(d) }),
            vec![(0, 12.5), (0, 120.0), (1, 0.0), (1, 162.75), (1, 200.0)],
            (200.0 - 37.25, 12.5),
        ),
        (
            "flip_vertical",
            Box::new(|d| unsafe { rz_doc_flip_vertical(d) }),
            vec![(0, 0.0), (0, 107.5), (1, 0.0), (1, 37.25), (1, 200.0)],
            (37.25, 120.0 - 12.5),
        ),
        (
            // DROP: the window is x in [20, 120), y in [0, 100). The
            // verticals at 0 and 200 leave; the horizontal at 120 leaves;
            // 37.25 shifts to 17.25 and 12.5 stays.
            "crop",
            Box::new(|d| unsafe { rz_doc_crop(d, 20, 0, 100, 100) }),
            vec![(0, 12.5), (1, 17.25)],
            (17.25, 12.5),
        ),
        (
            // DROP again, the other direction: growing by 10 on each axis
            // keeps everything, because nothing can leave a canvas that only
            // grew.
            "canvas_resize (grow)",
            Box::new(|d| unsafe { rz_doc_canvas_resize(d, 220, 140, 10, 10) }),
            vec![(0, 22.5), (0, 130.0), (1, 10.0), (1, 47.25), (1, 210.0)],
            (47.25, 22.5),
        ),
        (
            // ...and shrinking around the content drops what falls off both
            // ends: with the old canvas placed at (-30, -30) in a 100 x 60
            // one, the vertical at 0 lands at -30 and the one at 200 at 170.
            "canvas_resize (shrink)",
            Box::new(|d| unsafe { rz_doc_canvas_resize(d, 100, 60, -30, -30) }),
            vec![(1, 7.25)],
            (7.25, 0.0),
        ),
        (
            // CLAMP, not drop: halving the canvas halves every position, and
            // the guides on the far edges land on the new far edges.
            "resize",
            Box::new(|d| unsafe { rz_doc_resize(d, 100, 60, FILTER_BILINEAR) }),
            vec![(0, 6.25), (0, 60.0), (1, 0.0), (1, 18.625), (1, 100.0)],
            (18.625, 6.25),
        ),
        (
            // Carried verbatim — the canvas does not move.
            "flattening",
            Box::new(|d| unsafe { rz_doc_flattening(d) }),
            vec![(0, 12.5), (0, 120.0), (1, 0.0), (1, 37.25), (1, 200.0)],
            (37.25, 12.5),
        ),
    ];

    for (what, op, expected, expected_origin) in rows {
        let out = op(doc);
        assert!(!out.is_null(), "{what} refused");
        assert_eq!(guides(out), expected, "{what}: the guides");
        assert_eq!(origin(out), expected_origin, "{what}: the ruler origin");
        // ...and the same after a save and a reopen at the NEW canvas size,
        // which is where a clamp against the wrong extent would show.
        let name = format!("{what}.rzdc");
        let bytes = save_and_read(out, &dir, &name);
        assert!(!bytes.is_empty());
        let back = reopen(&dir, &name);
        assert_eq!(guides(back), expected, "{what}: after a reopen");
        assert_eq!(
            origin(back),
            expected_origin,
            "{what}: origin after a reopen"
        );
        unsafe {
            rz_doc_free(back);
            rz_doc_free(out);
        }
    }
    unsafe { rz_doc_free(doc) };
}
