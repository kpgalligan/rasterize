//! The one-way normalization the XMP packet gets on the way out: the
//! `tiff:Orientation` and `tiff:XResolution` / `tiff:YResolution` /
//! `tiff:ResolutionUnit` properties rewritten to what THIS document says,
//! exactly as `metadata_write::exif_normalized` rewrites the EXIF copies of
//! the same four numbers. Capture stays byte-exact; only the export is
//! rewritten, so the stored packet and the RZDC round trip are untouched.
//!
//! # Why the second copy has to be reset too
//!
//! `rz_image::open_bytes` bakes the camera's rotation into the pixels, so a
//! preserved `Orientation: 6` double-rotates the picture in every viewer.
//! That is why the EXIF copy is reset — and a file written by Lightroom or
//! Photoshop carries the SAME property a second time, in its XMP packet, as
//! `tiff:Orientation`. The XMP Specification Part 3 ("Reconciliation") makes
//! the XMP value authoritative for a property present in both places when
//! the file was last written by an XMP-aware application, and Bridge and
//! Camera Raw follow it, so resetting only the EXIF copy left the picture
//! rotated 90 degrees and at the source file's ppi in exactly the toolchain
//! a Photoshop replacement has to interoperate with.
//!
//! # Why a text edit is safe here and an IFD edit is not
//!
//! An XMP packet is UTF-8 XML with **no internal offsets**: nothing in it
//! points at a byte position, so a value may be replaced by a longer or
//! shorter one and everything around it still means what it meant. An EXIF
//! IFD is the opposite — every out-of-line datum is addressed from the
//! block's own header — which is why `metadata_write` never moves a byte and
//! this module may. The packet is edited as BYTES rather than as a `String`:
//! every pattern matched here is ASCII, which cannot occur inside a UTF-8
//! multi-byte sequence, so a packet with invalid UTF-8 in a description
//! field is still edited correctly instead of being dropped.
//!
//! # What it does not do
//!
//! * A property that is ABSENT is never inserted. The packet is a
//!   description of the file, not a place to publish new claims, and the
//!   EXIF block and the container density already state the same numbers.
//! * Only the conventional `tiff:` prefix is recognized. Every writer that
//!   emits these properties (Adobe's included) binds the TIFF namespace to
//!   it; a packet that binds it to some other prefix keeps its stale values,
//!   which is the situation the whole file was in before this module
//!   existed.
//! * `tiff:ImageWidth` / `tiff:ImageLength` and `exif:PixelXDimension` /
//!   `exif:PixelYDimension` are left alone, like their EXIF counterparts:
//!   they are advisory, and no reader rotates or rescales a picture because
//!   of them.

use crate::metadata::Resolution;

/// The XMP packet as it should be written: the document's orientation,
/// resolution and resolution unit, in both spellings XMP uses for a simple
/// property — an `rdf:Description` attribute and a child element.
///
/// Always returns a packet: a property this module does not recognize is
/// left exactly as it was, so the worst case is the packet the source file
/// carried.
pub(crate) fn xmp_normalized(blob: &[u8], dpi: Resolution) -> Vec<u8> {
    let mut out = blob.to_vec();
    // The rationals first is not significant — the four properties have
    // distinct names and no edit can create or destroy another's spelling.
    for (name, value) in [
        // The rotation is already in the pixels.
        ("tiff:Orientation", "1".to_string()),
        ("tiff:XResolution", rational(dpi.x)),
        ("tiff:YResolution", rational(dpi.y)),
        // 2 = inches, which is what the two rationals above are counted in.
        ("tiff:ResolutionUnit", "2".to_string()),
    ] {
        out = set_property(&out, name.as_bytes(), value.as_bytes());
    }
    out
}

/// A ppi as the `n/d` XMP TIFF schema spells a Rational — the same choice
/// `metadata_write::rational_bytes` makes for the EXIF copy, so the two
/// statements in one file read identically: an integral ppi is `300/1`
/// rather than `3000000/10000`, and anything else keeps the four decimals
/// `Resolution::sane` stores.
fn rational(ppi: f32) -> String {
    let v = f64::from(ppi);
    if (v - v.round()).abs() < 1e-4 {
        format!("{}/1", v.round().max(1.0) as u32)
    } else {
        format!("{}/10000", (v * 10_000.0).round().max(1.0) as u32)
    }
}

/// Every occurrence of `name` rewritten to `value`, in both spellings:
/// `name="…"` (or `name='…'`) and `<name …>…</name>`.
fn set_property(blob: &[u8], name: &[u8], value: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(blob.len());
    let mut i = 0usize;
    while i < blob.len() {
        let Some(found) = find(blob, name, i) else {
            break;
        };
        // The name must be whole: `tiff:Orientation` inside a longer name is
        // a different property, and rewriting part of one would corrupt it.
        // What comes BEFORE it decides which spelling this is — `<` for an
        // element, anything else for an attribute — and a name that is a
        // suffix of a longer one (`xmp:tiff:Orientation` is not a thing, but
        // costs nothing to exclude) is skipped.
        let after = found + name.len();
        let before = blob[..found].last().copied();
        let opens = before == Some(b'<');
        let attribute = matches!(before, Some(b) if b.is_ascii_whitespace());
        let boundary = matches!(blob.get(after), Some(b) if
            b.is_ascii_whitespace() || *b == b'=' || *b == b'>' || *b == b'/');
        let end = if boundary && opens {
            element_value(blob, after, name).map(|span| replace(&mut out, blob, i, span, value))
        } else if boundary && attribute {
            attribute_value(blob, after).map(|span| replace(&mut out, blob, i, span, value))
        } else {
            None
        };
        match end {
            Some(end) => i = end,
            None => {
                // Not a spelling we rewrite: copy the name through and carry
                // on past it, so a second occurrence still gets its chance.
                out.extend_from_slice(&blob[i..after]);
                i = after;
            }
        }
    }
    out.extend_from_slice(&blob[i.min(blob.len())..]);
    out
}

/// Copies `blob[at..span.start]`, then `value`, and answers where to carry
/// on from.
fn replace(
    out: &mut Vec<u8>,
    blob: &[u8],
    at: usize,
    span: std::ops::Range<usize>,
    value: &[u8],
) -> usize {
    out.extend_from_slice(&blob[at..span.start]);
    out.extend_from_slice(value);
    span.end
}

/// The value span of `name="…"`, given the offset just past the name.
/// `None` unless what follows is optional whitespace, `=`, optional
/// whitespace and a quote with a closing partner.
fn attribute_value(blob: &[u8], after_name: usize) -> Option<std::ops::Range<usize>> {
    let mut i = skip_space(blob, after_name);
    if *blob.get(i)? != b'=' {
        return None;
    }
    i = skip_space(blob, i + 1);
    let quote = *blob.get(i)?;
    if quote != b'"' && quote != b'\'' {
        return None;
    }
    let start = i + 1;
    let end = start + blob.get(start..)?.iter().position(|&b| b == quote)?;
    Some(start..end)
}

/// The text span of `<name …>text</name>`, given the offset just past the
/// name in the OPENING tag. `None` for a self-closing element (which has no
/// text to rewrite), for an unterminated tag, or when the matching close tag
/// is missing — every one of those is a packet we leave as we found it.
fn element_value(blob: &[u8], after_name: usize, name: &[u8]) -> Option<std::ops::Range<usize>> {
    let close = after_name + blob.get(after_name..)?.iter().position(|&b| b == b'>')?;
    if blob.get(close.checked_sub(1)?) == Some(&b'/') {
        return None;
    }
    let start = close + 1;
    let mut end_tag = Vec::with_capacity(name.len() + 3);
    end_tag.extend_from_slice(b"</");
    end_tag.extend_from_slice(name);
    end_tag.push(b'>');
    let end = find(blob, &end_tag, start)?;
    // An element holding markup rather than plain text is not a simple
    // property; replacing across it would produce nonsense.
    if blob[start..end].contains(&b'<') {
        return None;
    }
    Some(start..end)
}

fn skip_space(blob: &[u8], mut at: usize) -> usize {
    while matches!(blob.get(at), Some(b) if b.is_ascii_whitespace()) {
        at += 1;
    }
    at
}

/// The first offset at or after `from` where `needle` occurs.
fn find(haystack: &[u8], needle: &[u8], from: usize) -> Option<usize> {
    if from > haystack.len() || needle.is_empty() {
        return None;
    }
    haystack[from..]
        .windows(needle.len())
        .position(|w| w == needle)
        .map(|at| at + from)
}
