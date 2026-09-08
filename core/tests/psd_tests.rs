//! PSD import of LAYER GROUPS: the nesting, the names, the order, the
//! clipping bit — and the three properties this decoder provably cannot
//! recover, asserted as losses so the README's promise stays true.
//!
//! The fixture is built BYTE BY BYTE here rather than checked in or made with
//! ImageMagick: ImageMagick cannot write PSD groups at all, and a binary
//! fixture in the tree would hide exactly the record shapes these assertions
//! are about. Every field below is the PSD spec's, big-endian throughout.

use rasterize_core::doc::RzDocument;
use tempfile::TempDir;

mod common;

// ------------------------------------------------------- the PSD builder --

fn u16be(v: u16) -> [u8; 2] {
    v.to_be_bytes()
}
fn u32be(v: u32) -> [u8; 4] {
    v.to_be_bytes()
}
fn i32be(v: i32) -> [u8; 4] {
    v.to_be_bytes()
}

/// A Pascal string padded to a multiple of four, the layer-record name slot.
fn pascal4(name: &str) -> Vec<u8> {
    let mut out = vec![name.len() as u8];
    out.extend_from_slice(name.as_bytes());
    while !out.len().is_multiple_of(4) {
        out.push(0);
    }
    out
}

/// An "additional layer information" block: "8BIM" + key + u32 length + body.
fn additional(key: &[u8; 4], body: &[u8]) -> Vec<u8> {
    let mut out = b"8BIM".to_vec();
    out.extend_from_slice(key);
    out.extend_from_slice(&u32be(body.len() as u32));
    out.extend_from_slice(body);
    out
}

/// What a layer record says about itself. `lsct` is the section-divider
/// setting that makes a record a folder (1 = open folder, 3 = the hidden
/// bounding-section divider that CLOSES one); `clipping` is the spec's
/// "0 = base, 1 = non-base" byte.
struct Rec<'a> {
    name: &'a str,
    blend: &'a [u8; 4],
    opacity: u8,
    clipping: u8,
    /// Bit 1 set means HIDDEN in a real file, which is why the crate's
    /// `visible()` has to be negated.
    flags: u8,
    lsct: Option<(u32, Option<&'a [u8; 4]>)>,
    lspf: Option<u32>,
}

impl<'a> Rec<'a> {
    fn new(name: &'a str) -> Self {
        Rec {
            name,
            blend: b"norm",
            opacity: 255,
            clipping: 0,
            flags: 0b0000_1000,
            lsct: None,
            lspf: None,
        }
    }

    /// The record itself and its channel data, which the file carries in two
    /// separate runs in the same record order.
    fn build(&self) -> (Vec<u8>, Vec<u8>) {
        let mut r = Vec::new();
        r.extend_from_slice(&i32be(0)); // top
        r.extend_from_slice(&i32be(0)); // left
        r.extend_from_slice(&i32be(1)); // bottom
        r.extend_from_slice(&i32be(1)); // right
        let ids: [i16; 4] = [0, 1, 2, -1];
        r.extend_from_slice(&u16be(ids.len() as u16));
        for id in ids {
            r.extend_from_slice(&id.to_be_bytes());
            // The declared length INCLUDES the two compression bytes; the
            // crate computes `length - 2`, so anything below 2 underflows.
            r.extend_from_slice(&u32be(3));
        }
        r.extend_from_slice(b"8BIM");
        // MSB order: the crate reads the key as written, so "mron" would not
        // be recognised — the same reason the ImageMagick fixture is built
        // with -endian MSB.
        r.extend_from_slice(self.blend);
        r.extend_from_slice(&[self.opacity, self.clipping, self.flags, 0]);
        let mut extra = Vec::new();
        extra.extend_from_slice(&u32be(0)); // no mask data
        extra.extend_from_slice(&u32be(0)); // no blending ranges
        extra.extend_from_slice(&pascal4(self.name));
        if let Some((kind, subkey)) = self.lsct {
            let mut body = u32be(kind).to_vec();
            if let Some(key) = subkey {
                body.extend_from_slice(b"8BIM");
                body.extend_from_slice(key);
            }
            extra.extend_from_slice(&additional(b"lsct", &body));
        }
        if let Some(flags) = self.lspf {
            extra.extend_from_slice(&additional(b"lspf", &u32be(flags)));
        }
        r.extend_from_slice(&u32be(extra.len() as u32));
        r.extend_from_slice(&extra);

        let mut channels = Vec::new();
        for id in ids {
            channels.extend_from_slice(&u16be(0)); // raw
            channels.push(if id == -1 { 255 } else { 200 });
        }
        (r, channels)
    }
}

/// A whole 1x1 RGB PSD holding `records`, bottom-to-top in file order.
fn build_psd(records: &[Rec<'_>]) -> Vec<u8> {
    let (mut recs, mut chans) = (Vec::new(), Vec::new());
    for rec in records {
        let (r, c) = rec.build();
        recs.extend_from_slice(&r);
        chans.extend_from_slice(&c);
    }
    let mut layer_info = (records.len() as i16).to_be_bytes().to_vec();
    layer_info.extend_from_slice(&recs);
    layer_info.extend_from_slice(&chans);
    if !layer_info.len().is_multiple_of(2) {
        layer_info.push(0);
    }
    let mut layer_and_mask = u32be(layer_info.len() as u32).to_vec();
    layer_and_mask.extend_from_slice(&layer_info);
    layer_and_mask.extend_from_slice(&u32be(0)); // no global layer mask info

    let mut out = b"8BPS".to_vec();
    out.extend_from_slice(&u16be(1)); // version
    out.extend_from_slice(&[0; 6]); // reserved
    out.extend_from_slice(&u16be(3)); // channels
    out.extend_from_slice(&u32be(1)); // height
    out.extend_from_slice(&u32be(1)); // width
    out.extend_from_slice(&u16be(8)); // depth
    out.extend_from_slice(&u16be(3)); // RGB
    out.extend_from_slice(&u32be(0)); // no colour-mode data
    out.extend_from_slice(&u32be(0)); // no image resources
    out.extend_from_slice(&u32be(layer_and_mask.len() as u32));
    out.extend_from_slice(&layer_and_mask);
    out.extend_from_slice(&u16be(0)); // image data: raw
    out.extend_from_slice(&[10, 20, 30]); // three 1-pixel planes
    out
}

fn open_psd_bytes(dir: &TempDir, name: &str, bytes: &[u8]) -> Result<RzDocument, String> {
    let path = dir.path().join(name);
    std::fs::write(&path, bytes).unwrap();
    RzDocument::open(path.to_str().unwrap())
}

fn shape(doc: &RzDocument) -> Vec<(String, u16, bool)> {
    doc.layers
        .iter()
        .map(|l| {
            (
                l.name.clone(),
                l.depth,
                l.kind == rasterize_core::doc::LayerKind::Group,
            )
        })
        .collect()
}

// -------------------------------------------------------------- the tests --

#[test]
fn psd_groups_import_with_their_nesting_names_and_order() {
    let dir = TempDir::new().unwrap();
    // File order is bottom-to-top, and a folder is stored as a divider record
    // BELOW its contents and a folder record ABOVE them:
    //
    //   </Layer group>   the divider closing "Grp"
    //   Inner            inside "Grp"
    //   Grp              the folder row
    //   Loose            a top-level layer above it
    let psd = build_psd(&[
        Rec {
            lsct: Some((3, None)),
            flags: 0b0001_1000,
            ..Rec::new("</Layer group>")
        },
        Rec {
            opacity: 200,
            ..Rec::new("Inner")
        },
        Rec {
            opacity: 128,
            flags: 0b0001_1010, // hidden, in the file
            lsct: Some((1, Some(b"mul "))),
            ..Rec::new("Grp")
        },
        Rec {
            lspf: Some(0b101),
            ..Rec::new("Loose")
        },
    ]);
    let doc = open_psd_bytes(&dir, "grouped.psd", &psd).expect("a grouped PSD must import");

    // Our stack is bottom-first with a group's children BEFORE it, so the
    // panel reads (top to bottom) Loose, Grp, Inner — which is the PSD's own
    // order read the other way.
    assert_eq!(
        shape(&doc),
        vec![
            ("Inner".to_string(), 1, false),
            ("Grp".to_string(), 0, true),
            ("Loose".to_string(), 0, false),
        ],
        "the folder's contents come first, then the folder, then the layer \
         above it"
    );
    assert_eq!(doc.width, 1);
    assert_eq!(doc.height, 1);

    // The LAYER properties that do import.
    assert!((doc.layers[0].opacity - 200.0 / 255.0).abs() < 1e-6);
    assert!(doc.layers[0].visible, "the flags byte's bit 1 is HIDDEN");

    // The three losses, asserted so the README's sentence stays true: a
    // group's opacity, blend mode and visibility live in the folder record,
    // and this decoder builds its group from the hidden divider instead.
    let grp = &doc.layers[1];
    assert_eq!(grp.opacity, 1.0, "a group's own opacity does not import");
    assert!(grp.visible, "nor does a hidden group's visibility");
    assert_eq!(
        grp.blend,
        rasterize_core::doc::BlendMode::PassThrough,
        "and its blend mode arrives as Pass Through, PSD's own default for a \
         group and the mode that leaves the stack transparent"
    );
    assert_eq!(
        grp.locks, 0,
        "PSD `lspf` locks are discarded by the decoder"
    );
    assert_eq!(doc.layers[2].locks, 0, "on a layer too");
}

#[test]
fn the_psd_clipping_bit_imports_inverted() {
    let dir = TempDir::new().unwrap();
    // The spec byte is "0 = base, 1 = non-base", and the crate stores it as
    // `byte == 0` behind the misnamed `is_clipping_mask()`. So OUR clipped
    // flag is its negation, and getting that backwards would silently clip
    // every unclipped layer in every imported file.
    let psd = build_psd(&[
        Rec {
            clipping: 0,
            ..Rec::new("Base")
        },
        Rec {
            clipping: 1,
            ..Rec::new("Clipped")
        },
    ]);
    let doc = open_psd_bytes(&dir, "clip.psd", &psd).expect("import");
    // PSD records run bottom-to-top and so does our stack, so the base is
    // index 0 and the layer clipped to it sits above at index 1.
    assert_eq!(doc.layers[0].name, "Base");
    assert!(!doc.layers[0].clipped, "the base record is not clipped");
    assert_eq!(doc.layers[1].name, "Clipped");
    assert!(doc.layers[1].clipped, "and the non-base record above it is");
}

#[test]
fn a_psd_of_nothing_but_empty_groups_keeps_them() {
    let dir = TempDir::new().unwrap();
    // No raster layers at all: the composite fallback would throw the groups
    // away, so the guard has to be "no layers AND no groups".
    let psd = build_psd(&[
        Rec {
            lsct: Some((3, None)),
            ..Rec::new("</Layer group>")
        },
        Rec {
            lsct: Some((1, Some(b"pass"))),
            ..Rec::new("Empty")
        },
    ]);
    let doc = open_psd_bytes(&dir, "empty.psd", &psd).expect("import");
    assert_eq!(
        shape(&doc),
        vec![("Empty".to_string(), 0, true)],
        "an empty group is a legal stack all by itself"
    );
}

#[test]
fn a_flat_psd_still_imports_exactly_as_it_did() {
    let dir = TempDir::new().unwrap();
    let psd = build_psd(&[Rec::new("Bottom"), Rec::new("Top")]);
    let doc = open_psd_bytes(&dir, "flat.psd", &psd).expect("import");
    assert_eq!(
        shape(&doc),
        vec![
            ("Bottom".to_string(), 0, false),
            ("Top".to_string(), 0, false),
        ],
        "no groups: a flat stack at depth 0, bottom-first like the file's own \
         record order"
    );
    assert!(doc.layers.iter().all(|l| l.locks == 0 && l.link == 0));
}

#[test]
fn the_sample_psds_still_import() {
    // The checked-in fixtures are flat, so this is the regression guard for
    // everything the group walk now sits in front of.
    for name in ["layered.psd", "gradient.psd"] {
        let path = format!("{}/../samples/{name}", env!("CARGO_MANIFEST_DIR"));
        if !std::path::Path::new(&path).exists() {
            continue;
        }
        let doc = RzDocument::open(&path).unwrap_or_else(|e| panic!("{name}: {e}"));
        assert!(!doc.layers.is_empty(), "{name} has entries");
        assert!(
            doc.layers.iter().all(|l| l.depth == 0),
            "{name} is a flat PSD and must import flat"
        );
        assert!(
            doc.layers.last().is_some_and(|l| l.depth == 0),
            "{name} ends at the top level"
        );
    }
}
