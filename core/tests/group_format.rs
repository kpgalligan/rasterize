//! RZDC VERSION 7 — layer groups, locks, links and the panel disclosure flag —
//! as a file format: the round trip and the byte-identical resave, the older
//! versions that still load, the crafted records the reader must refuse or
//! sanitize, the two mask pairings the deferred construction exists for, the
//! memory pre-check, and the ride-along sweep proving every document op leaves
//! the depth sequence well formed and the group masks intact.
//!
//! Black-box through the C exports and the safe constructors, on fixtures this
//! file builds byte by byte (the `color_format` skeleton); `group_tests`
//! covers the model and the compositor, `structure_tests` the ops. No golden
//! files anywhere.

use std::ffi::{c_char, c_int, CString};
use std::ptr;

use rasterize_core::doc::RzDocument;
use rasterize_core::ffi_channel::rz_doc_layer_plane;
use rasterize_core::ffi_doc::*;
use rasterize_core::ffi_group::*;
use tempfile::TempDir;

mod common;
use common::*;

/// RZ_PLANE_MASK, mirrored from the header like the tables in `tests/common`.
const PLANE_MASK: c_int = 5;
/// The deepest nesting this build accepts (`doc_group::MAX_GROUP_DEPTH`),
/// mirrored so the crafted files below do not depend on the crate's constant.
const MAX_DEPTH: u16 = 10;

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

fn group(doc: *mut RzDocument, idx: &[usize], name: &str) -> (*mut RzDocument, usize) {
    let cname = CString::new(name).unwrap();
    let mut out_group = usize::MAX;
    let out = unsafe {
        rz_doc_group_layers(
            doc,
            idx.as_ptr(),
            idx.len(),
            cname.as_ptr(),
            &mut out_group,
            ptr::null_mut(),
            ptr::null_mut(),
            ptr::null_mut(),
            ptr::null_mut(),
            0,
        )
    };
    assert!(!out.is_null(), "group_layers({idx:?}) refused");
    unsafe { rz_doc_free(doc) };
    (out, out_group)
}

fn depths(doc: *const RzDocument) -> Vec<u32> {
    (0..unsafe { rz_doc_layer_count(doc) })
        .map(|i| unsafe { rz_doc_layer_depth(doc, i) })
        .collect()
}

fn kinds(doc: *const RzDocument) -> Vec<bool> {
    (0..unsafe { rz_doc_layer_count(doc) })
        .map(|i| unsafe { rz_doc_layer_is_group(doc, i) })
        .collect()
}

fn locks(doc: *const RzDocument) -> Vec<u32> {
    (0..unsafe { rz_doc_layer_count(doc) })
        .map(|i| unsafe { rz_doc_layer_locks(doc, i) })
        .collect()
}

fn links(doc: *const RzDocument) -> Vec<u32> {
    (0..unsafe { rz_doc_layer_count(doc) })
        .map(|i| unsafe { rz_doc_layer_link(doc, i) })
        .collect()
}

fn opens(doc: *const RzDocument) -> Vec<bool> {
    (0..unsafe { rz_doc_layer_count(doc) })
        .map(|i| unsafe { rz_doc_layer_open(doc, i) })
        .collect()
}

/// A group's CANVAS-sized mask, read through the plane getter — the only
/// reader that answers with one, since `rz_doc_layer_mask_image` is layer
/// sized by contract.
fn group_mask(doc: *const RzDocument, idx: usize, w: u32, h: u32) -> Vec<u8> {
    let mut plane = vec![0u8; (w * h) as usize];
    assert!(
        unsafe { rz_doc_layer_plane(doc, idx, PLANE_MASK, plane.as_mut_ptr(), w, h) },
        "the group mask must read back as a canvas plane"
    );
    plane
}

/// A document -> document FFI op, for the ride-along sweeps below.
type DocOp = Box<dyn Fn(*const RzDocument) -> *mut RzDocument>;

/// The depth sequence, checked the way `structure_tests` checks it: from each
/// child UP to the group that must enclose it.
fn assert_well_formed(doc: *const RzDocument, what: &str) {
    let n = unsafe { rz_doc_layer_count(doc) };
    let d = depths(doc);
    let g = kinds(doc);
    assert!(n > 0 && d[n - 1] == 0, "{what}: {d:?}");
    for i in 0..n {
        if d[i] == 0 {
            continue;
        }
        let parent = (i + 1..n)
            .find(|&j| d[j] < d[i])
            .unwrap_or_else(|| panic!("{what}: entry {i} has no enclosing group — {d:?}"));
        assert_eq!(d[parent], d[i] - 1, "{what}: {d:?}");
        assert!(g[parent], "{what}: entry {i}'s enclosing entry is a layer");
    }
}

/// The fixture the round trip runs on: a nested document carrying every piece
/// of version-7 state — two levels of group, a canvas-sized group mask, a
/// collapsed group, locks on two entries and a link group of two.
fn nested_fixture(dir: &TempDir, canvas: (u32, u32)) -> *mut RzDocument {
    let (w, h) = canvas;
    let mut doc = doc_from(dir, "bg.png", &solid(w, h, RED));
    for (i, name) in ["A", "B", "C"].iter().enumerate() {
        doc = add_layer(
            dir,
            &format!("{name}.png"),
            doc,
            i,
            &solid(4, 4, BLUE),
            name,
        );
    }
    // [Background, A, B, C] -> Inner{A, B} -> Outer{Inner}
    let (doc, inner) = group(doc, &[1, 2], "Inner");
    let (doc, outer) = group(doc, &[inner], "Outer");
    assert_eq!(depths(doc), vec![0, 2, 2, 1, 0, 0]);
    // A canvas-sized mask on the OUTER group, whose byte encodes its canvas
    // position so a misplacement shows up as a wrong value.
    let sel = selection(w, h, |x, y| (x * 7 + y * 3) as u8);
    let doc = apply(doc, |d| unsafe {
        rz_doc_adding_layer_mask(d, outer, MASK_FROM_SELECTION, sel.as_ptr(), w, h)
    });
    let doc = apply(doc, |d| unsafe { rz_doc_with_layer_open(d, outer, false) });
    let doc = apply(doc, |d| unsafe {
        rz_doc_with_layer_locks(d, 1, LOCK_TRANSPARENCY | LOCK_POSITION)
    });
    let doc = apply(doc, |d| unsafe { rz_doc_with_layer_locks(d, 5, LOCK_ALL) });
    let pair = [1usize, 5];
    apply(doc, |d| unsafe { rz_doc_link_layers(d, pair.as_ptr(), 2) })
}

// ------------------------------------------------------------- round trip --

#[test]
fn version_7_round_trips_the_structure_locks_links_and_the_open_flag() {
    let dir = TempDir::new().unwrap();
    let canvas = (12u32, 9u32);
    let doc = nested_fixture(&dir, canvas);
    let before = flat_pixels(doc);
    let mask_before = group_mask(doc, 4, canvas.0, canvas.1);

    let bytes = save_and_read(doc, &dir, "nested.rzdc");
    assert_eq!(&bytes[..4], b"RZDC");
    assert_eq!(
        u32::from_le_bytes(bytes[4..8].try_into().unwrap()),
        8,
        "the writer always writes the current version (groups and locks \
         bumped it to 7, guides and the ruler origin to 8)"
    );

    let back = reopen(&dir, "nested.rzdc");
    assert_eq!(depths(back), depths(doc));
    assert_eq!(kinds(back), kinds(doc));
    assert_eq!(locks(back), locks(doc));
    assert_eq!(links(back), links(doc));
    assert_eq!(opens(back), opens(doc));
    assert_eq!(
        group_mask(back, 4, canvas.0, canvas.1),
        mask_before,
        "the group's CANVAS-sized mask survives — the reader had to defer \
         building it until the kind byte said which size it is"
    );
    assert_eq!(flat_pixels(back), before, "and the picture is unchanged");
    assert_well_formed(back, "after a reopen");

    // Resaving the reopened document must produce the SAME bytes: anything
    // the reader dropped or reordered would show up here.
    let again = save_and_read(back, &dir, "nested-again.rzdc");
    assert_eq!(again, bytes, "the resave is byte-identical");
    unsafe {
        rz_doc_free(back);
        rz_doc_free(doc);
    }
}

// -------------------------------------------------------- the crafted files --

/// Builds RZDC files record by record, so an older version is a real file of
/// that version rather than a truncation of a newer one — version 7 puts its
/// bytes INSIDE each layer record, so truncating a tail no longer produces a
/// well-formed older file.
struct Craft {
    png: Vec<u8>,
    canvas: (u32, u32),
}

/// One layer record's worth of version-7 state.
#[derive(Clone, Copy)]
struct Record {
    locks: u32,
    link: u32,
    depth: u16,
    kind: u8,
    open: bool,
    opacity: f32,
    blend: u32,
    /// `Some(len)` writes a mask slot of that many bytes.
    mask_len: Option<u32>,
}

impl Default for Record {
    fn default() -> Self {
        Record {
            locks: 0,
            link: 0,
            depth: 0,
            kind: 0,
            open: true,
            opacity: 1.0,
            blend: 0,
            mask_len: None,
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
    /// versions lack omitted.
    fn file(&self, version: u32, records: &[Record]) -> Vec<u8> {
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
        for r in records {
            b.extend_from_slice(&3u32.to_le_bytes());
            b.extend_from_slice(b"Old");
            b.extend_from_slice(&0i32.to_le_bytes());
            b.extend_from_slice(&0i32.to_le_bytes());
            b.extend_from_slice(&r.opacity.to_le_bytes());
            b.extend_from_slice(&r.blend.to_le_bytes());
            b.push(1); // visible
            b.extend_from_slice(&(self.png.len() as u32).to_le_bytes());
            b.extend_from_slice(&self.png);
            if version >= 2 {
                match r.mask_len {
                    None => {
                        b.push(0); // no mask
                        b.push(1); // mask enabled
                    }
                    Some(len) => {
                        b.push(1);
                        b.push(1);
                        b.extend_from_slice(&len.to_le_bytes());
                        b.extend(std::iter::repeat_n(200u8, len as usize));
                    }
                }
                b.push(0); // no meta
            }
            if version >= 3 {
                b.push(0); // not clipped
            }
            if version >= 4 {
                b.push(0); // no style
            }
            if version >= 7 {
                b.extend_from_slice(&r.locks.to_le_bytes());
                b.extend_from_slice(&r.link.to_le_bytes());
                b.extend_from_slice(&r.depth.to_le_bytes());
                b.push(r.kind);
                b.push(u8::from(r.open));
            }
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
fn hand_built_v1_to_v6_records_take_the_group_defaults() {
    let dir = TempDir::new().unwrap();
    let craft = Craft::new((1, 1));
    let records = [Record::default(), Record::default()];
    for version in 1..=6u32 {
        let doc = open_bytes(
            &dir,
            &format!("v{version}.rzdc"),
            &craft.file(version, &records),
        )
        .unwrap_or_else(|e| panic!("v{version}: {e}"));
        assert_eq!(doc.layers.len(), 2);
        for layer in &doc.layers {
            assert_eq!(layer.depth, 0, "v{version}: a flat stack");
            assert_eq!(layer.locks, 0, "v{version}: unlocked");
            assert_eq!(layer.link, 0, "v{version}: unlinked");
            assert!(layer.open, "v{version}: open");
        }
    }
    // And a version-7 file carries what it was given.
    let mixed = [
        Record {
            locks: LOCK_PIXELS,
            link: 3,
            depth: 1,
            ..Record::default()
        },
        Record {
            kind: 1,
            depth: 0,
            open: false,
            ..Record::default()
        },
    ];
    let doc = open_bytes(&dir, "v7.rzdc", &craft.file(7, &mixed)).expect("v7");
    assert_eq!(doc.layers[0].locks, LOCK_PIXELS);
    assert_eq!(doc.layers[0].link, 3);
    assert_eq!(doc.layers[0].depth, 1);
    assert!(!doc.layers[1].open, "a collapsed group survives");
}

#[test]
fn crafted_version_7_records_are_refused_or_sanitized() {
    let dir = TempDir::new().unwrap();
    let craft = Craft::new((2, 2));

    // Unknown lock bits are MASKED OFF and the file loads — the same leniency
    // an unknown blend mode gets.
    let loose = [Record {
        locks: 0xFFFF_FFFF,
        ..Record::default()
    }];
    let doc = open_bytes(&dir, "loose.rzdc", &craft.file(7, &loose)).expect("loads");
    assert_eq!(doc.layers[0].locks, LOCK_ALL, "reserved bits masked off");

    // A kind byte that is neither raster nor group is a REFUSAL: it is not a
    // value to be guessed at.
    let odd = [Record {
        kind: 9,
        ..Record::default()
    }];
    let err = open_bytes(&dir, "kind.rzdc", &craft.file(7, &odd))
        .err()
        .expect("an unknown kind must be refused");
    assert!(err.contains("unsupported layer kind 9"), "{err}");

    // A depth past the cap is refused before the record is trusted.
    let deep = [
        Record {
            depth: MAX_DEPTH + 1,
            ..Record::default()
        },
        Record {
            kind: 1,
            ..Record::default()
        },
    ];
    let err = open_bytes(&dir, "deep.rzdc", &craft.file(7, &deep))
        .err()
        .expect("too deep must be refused");
    assert!(err.contains("layer nesting deeper than"), "{err}");

    // A malformed depth SEQUENCE — a child closed by a raster entry — is
    // refused rather than repaired, because the child would otherwise vanish
    // from every projection, export and save with no error anywhere.
    let orphan = [
        Record {
            depth: 1,
            ..Record::default()
        },
        Record::default(), // a RASTER entry closing a child run
    ];
    let err = open_bytes(&dir, "orphan.rzdc", &craft.file(7, &orphan))
        .err()
        .expect("a malformed sequence must be refused");
    assert!(err.contains("malformed layer group structure"), "{err}");

    // ...and so is a child with no enclosing group at all.
    let dangling = [Record {
        depth: 1,
        ..Record::default()
    }];
    let err = open_bytes(&dir, "dangling.rzdc", &craft.file(7, &dangling))
        .err()
        .expect("a dangling child must be refused");
    assert!(err.contains("malformed layer group structure"), "{err}");

    // The legal shape loads: a child closed by a GROUP.
    let good = [
        Record {
            depth: 1,
            ..Record::default()
        },
        Record {
            kind: 1,
            ..Record::default()
        },
    ];
    let doc = open_bytes(&dir, "good.rzdc", &craft.file(7, &good)).expect("loads");
    assert_eq!(doc.layers.len(), 2);
}

#[test]
fn both_mismatched_mask_pairings_are_refused_with_their_own_message() {
    let dir = TempDir::new().unwrap();
    // A 3x3 canvas and 1x1 layer PNGs: the layer count (1) and the canvas
    // count (9) are different numbers, so a pairing can actually be wrong.
    let craft = Craft::new((3, 3));

    // A RASTER record whose mask is canvas-sized: accepted at the length
    // check (it matches one of the two) and refused once the kind is known.
    let raster_canvas_mask = [Record {
        mask_len: Some(9),
        ..Record::default()
    }];
    let err = open_bytes(&dir, "rc.rzdc", &craft.file(7, &raster_canvas_mask))
        .err()
        .expect("a raster mask sized to the canvas must be refused");
    assert!(
        err.contains("does not match the layer's 1 pixels"),
        "the message names the LAYER: {err}"
    );

    // A GROUP record whose mask is layer-sized, the mirror error.
    let group_layer_mask = [Record {
        kind: 1,
        mask_len: Some(1),
        ..Record::default()
    }];
    let err = open_bytes(&dir, "gl.rzdc", &craft.file(7, &group_layer_mask))
        .err()
        .expect("a group mask sized to the layer must be refused");
    assert!(
        err.contains("does not match the canvas's 9 pixels"),
        "the message names the CANVAS: {err}"
    );

    // A length that matches NEITHER is refused at the length check, before a
    // byte is taken — the version-2 behaviour, unchanged.
    let neither = [Record {
        mask_len: Some(4),
        ..Record::default()
    }];
    let err = open_bytes(&dir, "nn.rzdc", &craft.file(7, &neither))
        .err()
        .expect("a length matching neither must be refused");
    assert!(err.contains("layer mask length 4"), "{err}");

    // Both RIGHT pairings load.
    let ok = [
        Record {
            mask_len: Some(1),
            ..Record::default()
        },
        Record {
            kind: 1,
            mask_len: Some(9),
            ..Record::default()
        },
    ];
    let doc = open_bytes(&dir, "ok.rzdc", &craft.file(7, &ok)).expect("loads");
    assert_eq!(doc.layers[0].mask.as_ref().unwrap().dimensions(), (1, 1));
    assert_eq!(doc.layers[1].mask.as_ref().unwrap().dimensions(), (3, 3));
}

#[test]
fn the_setter_enforces_the_depth_cap_before_the_writer_ever_sees_it() {
    let dir = TempDir::new().unwrap();
    let mut doc = doc_from(&dir, "bg.png", &solid(4, 4, RED));
    doc = add_layer(&dir, "a.png", doc, 0, &solid(4, 4, BLUE), "A");
    // Wrap the layer ten times: the tenth group puts it at depth 10, the cap.
    let mut inner = 1usize;
    for level in 0..MAX_DEPTH {
        let (out, g) = group(doc, &[inner], &format!("G{level}"));
        doc = out;
        inner = g;
    }
    assert_eq!(
        depths(doc)[1],
        u32::from(MAX_DEPTH),
        "the layer sits at the cap"
    );
    unsafe {
        let set = [inner];
        let cname = CString::new("too deep").unwrap();
        let mut out_group = 0usize;
        assert!(
            rz_doc_group_layers(
                doc,
                set.as_ptr(),
                1,
                cname.as_ptr(),
                &mut out_group,
                ptr::null_mut(),
                ptr::null_mut(),
                ptr::null_mut(),
                ptr::null_mut(),
                0,
            )
            .is_null(),
            "one more level is refused by the SETTER, so the writer never has \
             to refuse a document the host already holds"
        );
    }
    // ...and the document at the cap saves and reopens.
    let bytes = save_and_read(doc, &dir, "deep.rzdc");
    assert!(!bytes.is_empty());
    let back = reopen(&dir, "deep.rzdc");
    assert_eq!(depths(back), depths(doc));
    assert_well_formed(back, "a document nested to the cap");
    unsafe {
        rz_doc_free(back);
        rz_doc_free(doc);
    }
}

// ------------------------------------------------------------- the memory --

#[test]
fn a_deeply_nested_isolated_document_opens_and_renders() {
    let dir = TempDir::new().unwrap();
    // One full-canvas layer inside TEN nested ISOLATED groups (each at 90 %
    // opacity, which `is_isolated` treats as isolated), crafted as a file so
    // the reader's own recursion is what is exercised.
    let canvas = (48u32, 48u32);
    let craft = Craft::new(canvas);
    let mut records = vec![Record {
        depth: MAX_DEPTH,
        ..Record::default()
    }];
    for level in (0..MAX_DEPTH).rev() {
        records.push(Record {
            kind: 1,
            depth: level,
            opacity: 0.9,
            ..Record::default()
        });
    }
    let doc = open_bytes(&dir, "nest.rzdc", &craft.file(7, &records)).expect("a legal file");
    assert_eq!(doc.layers.len(), 11);
    // The projection terminates and yields a canvas-sized image; a runaway
    // recursion or an unbounded allocation would never get here.
    let flat = doc.flattened();
    assert_eq!(flat.dimensions(), canvas);
}

#[test]
fn a_file_whose_isolated_groups_ask_for_too_much_memory_is_refused_at_parse() {
    let dir = TempDir::new().unwrap();
    // The parse-time pre-check sums the CANVAS pixel count over every group
    // record whose stored properties already force isolation. On the largest
    // canvas this build allows, sixty-four of them is the line — so this file
    // is sixty-five empty, isolated, top-level groups, each a 1x1 PNG. The
    // whole thing is a few kilobytes and nothing canvas-sized is ever built.
    //
    // The RUNTIME budget (`doc_group::MAX_GROUP_BUFFER_PIXELS`) is the actual
    // guarantee and is deliberately NOT exercised here: reaching its ceiling
    // needs four hundred million accumulator pixels ALIVE AT ONCE, which is
    // gigabytes of real compositing rather than a unit test. The two caps
    // measure different quantities — this one sums over every isolated group
    // in the file, that one peaks over the buffers a nest holds together, and
    // sixty-four SIBLING groups cost the compositor one canvas, not
    // sixty-four — so the sixteenfold difference between them is a difference
    // of kind, not a disagreement. This pre-check is the early, friendly
    // refusal for exactly the file shape that would reach the other.
    let craft = Craft::new((10_000, 10_000));
    let records: Vec<Record> = (0..65)
        .map(|_| Record {
            kind: 1,
            opacity: 0.9,
            ..Record::default()
        })
        .collect();
    let err = open_bytes(&dir, "greedy.rzdc", &craft.file(7, &records))
        .err()
        .expect("must be refused");
    assert!(
        err.contains("layer groups would need more memory than this build allows"),
        "{err}"
    );

    // Sixty-four of them is inside the line and loads, so the refusal is a
    // real boundary and not a blanket ban on groups at a large canvas.
    let inside: Vec<Record> = records[..64].to_vec();
    let doc = open_bytes(&dir, "ok.rzdc", &craft.file(7, &inside)).expect("loads");
    assert_eq!(doc.layers.len(), 64);

    // PASS-THROUGH groups are not counted at all — they allocate nothing —
    // so a hundred of them on the same canvas is fine.
    let pass: Vec<Record> = (0..100)
        .map(|_| Record {
            kind: 1,
            blend: 27, // RZ_BLEND_PASS_THROUGH
            ..Record::default()
        })
        .collect();
    let doc = open_bytes(&dir, "pass.rzdc", &craft.file(7, &pass)).expect("loads");
    assert_eq!(doc.layers.len(), 100);
}

// ------------------------------------------------------- the ride-along --

/// Every document op run once on the nested fixture, each asserting the depth
/// sequence stays well formed and the group's canvas-sized mask comes through
/// at the new canvas size. This sweep is where the bugs are: a group mask that
/// took the LAYER-mask path would be resampled to the 1x1 dummy's size and
/// destroyed, and every one of these ops has a separate code path for it.
#[test]
fn every_document_op_carries_the_structure_and_the_group_mask() {
    let dir = TempDir::new().unwrap();
    let canvas = (16u32, 12u32);
    let doc = nested_fixture(&dir, canvas);
    let outer = 4usize;

    // The whole-canvas geometry ops, each with the canvas size it produces.
    let geometry: Vec<(&str, DocOp, (u32, u32))> = vec![
        (
            "rotate180",
            Box::new(|d| unsafe { rz_doc_rotate180(d) }),
            canvas,
        ),
        (
            "rotate90",
            Box::new(|d| unsafe { rz_doc_rotate90(d) }),
            (canvas.1, canvas.0),
        ),
        (
            "flip_horizontal",
            Box::new(|d| unsafe { rz_doc_flip_horizontal(d) }),
            canvas,
        ),
        (
            "crop",
            Box::new(|d| unsafe { rz_doc_crop(d, 2, 1, 8, 6) }),
            (8, 6),
        ),
        (
            "canvas_resize",
            Box::new(|d| unsafe { rz_doc_canvas_resize(d, 20, 16, 2, 2) }),
            (20, 16),
        ),
        (
            "resize",
            Box::new(|d| unsafe { rz_doc_resize(d, 8, 6, FILTER_BILINEAR) }),
            (8, 6),
        ),
    ];
    for (what, op, (w, h)) in geometry {
        let out = op(doc);
        assert!(!out.is_null(), "{what} refused");
        assert_well_formed(out, what);
        assert_eq!(depths(out), depths(doc), "{what}: the structure is kept");
        let mask = group_mask(out, outer, w, h);
        assert_eq!(mask.len(), (w * h) as usize, "{what}: mask is canvas-sized");
        assert!(
            mask.iter().any(|&v| v != 0) && mask.iter().any(|&v| v != 255),
            "{what}: the mask still carries its gradient rather than a flat \
             fill, which is what a destroyed one would look like"
        );
        // ...and it survives a save and reopen at the NEW canvas size.
        let name = format!("{what}.rzdc");
        let bytes = save_and_read(out, &dir, &name);
        assert!(!bytes.is_empty());
        let back = reopen(&dir, &name);
        assert_eq!(
            group_mask(back, outer, w, h),
            mask,
            "{what}: after a reopen"
        );
        assert_well_formed(back, what);
        unsafe {
            rz_doc_free(back);
            rz_doc_free(out);
        }
    }

    // The stack ops, which keep the canvas and must keep the mask verbatim.
    let mask_before = group_mask(doc, outer, canvas.0, canvas.1);
    let stack: Vec<(&str, DocOp, usize)> = vec![
        (
            "duplicating_layer",
            Box::new(|d| unsafe { rz_doc_duplicating_layer(d, 3) }),
            outer + 3,
        ),
        (
            "removing_layer",
            Box::new(|d| unsafe { rz_doc_removing_layer(d, 5) }),
            outer,
        ),
        (
            "moving_layer",
            Box::new(|d| unsafe { rz_doc_moving_layer(d, 0, 5) }),
            outer - 1,
        ),
    ];
    for (what, op, group_at) in stack {
        let out = op(doc);
        assert!(!out.is_null(), "{what} refused");
        assert_well_formed(out, what);
        assert!(
            unsafe { rz_doc_layer_is_group(out, group_at) },
            "{what}: the masked group is at {group_at}"
        );
        assert_eq!(
            group_mask(out, group_at, canvas.0, canvas.1),
            mask_before,
            "{what}: the group mask is untouched"
        );
        unsafe { rz_doc_free(out) };
    }

    // Merging a GROUP down is the one op that deliberately ends the group:
    // both operands are rendered to pixels, so the masked group becomes a
    // plain raster entry and its mask is BAKED into them, exactly as
    // `merging_down` documents. What must survive is the invariant.
    let merged = apply(unsafe { rz_doc_clone(doc) }, |d| unsafe {
        rz_doc_merging_down(d, 5)
    });
    assert_well_formed(merged, "merging_down onto a group");
    assert_eq!(unsafe { rz_doc_layer_count(merged) }, 2);
    assert!(
        !unsafe { rz_doc_layer_is_group(merged, 1) },
        "the group was rasterized by the merge"
    );
    assert_eq!(depths(merged), vec![0, 0]);
    unsafe { rz_doc_free(merged) };

    // Grouping and ungrouping around the masked group.
    let (regrouped, g) = group(unsafe { rz_doc_clone(doc) }, &[outer], "Wrapper");
    assert_well_formed(regrouped, "group_layers");
    assert_eq!(
        group_mask(regrouped, outer, canvas.0, canvas.1),
        mask_before,
        "group_layers: the inner group keeps its mask"
    );
    let dissolved = apply(regrouped, |d| unsafe {
        rz_doc_ungroup_layer(d, g, ptr::null_mut(), ptr::null_mut(), 0)
    });
    assert_well_formed(dissolved, "ungroup_layer");
    assert_eq!(
        group_mask(dissolved, outer, canvas.0, canvas.1),
        mask_before,
        "ungroup_layer: and so does it after the wrapper is dissolved"
    );
    unsafe {
        rz_doc_free(dissolved);
        rz_doc_free(doc);
    }
}
