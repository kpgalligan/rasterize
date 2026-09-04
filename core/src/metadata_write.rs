//! The WRITE half of metadata preservation: what an encoder is asked to
//! attach ([`EncodeSidecar`]), the packets that are rewritten on the way out
//! ([`exif_normalized`] and [`iptc_filtered`] here, the XMP packet in
//! `metadata_xmp`), the JPEG segments and PNG chunks the `image` crate's
//! encoders cannot write, and the streaming [`MetadataInjector`] that
//! splices them into the encoded byte stream. The container walk that
//! captured the packets in the first place is `metadata`.
//!
//! # The orientation reset is mandatory
//!
//! `rz_image::open_bytes` bakes the camera's rotation into the pixels, so a
//! preserved `Orientation: 6` written back out would double-rotate the image
//! in every viewer. [`exif_normalized`] therefore rewrites IFD0's
//! Orientation to 1, and while it is there it also brings the resolution,
//! colour-space and dimension tags into line with the document and **cuts
//! the link to IFD1**.
//!
//! The argument applies to every OTHER copy of the same property the file
//! carries, which is why `metadata_xmp::xmp_normalized` gives the XMP
//! packet's `tiff:Orientation` and `tiff:*Resolution` the same treatment:
//! XMP's own reconciliation rules make the XMP copy the authority for a
//! property present twice, so resetting only the EXIF one leaves an
//! XMP-aware reader rotating the picture exactly as before.
//!
//! Every one of those edits is made **in place, moving no offset**: an EXIF
//! block is full of offsets measured from its own header, and inserting an
//! entry would grow an IFD by 12 bytes and shift every out-of-line datum
//! after it — silently corrupting MakerNotes, many of which store absolute
//! offsets into the same block and cannot be relocated. So an ABSENT tag is
//! never inserted; the container's own density (JFIF, `pHYs`) carries the
//! ppi in that case. Any malformation in IFD0 or the Exif sub-IFD makes the
//! whole packet absent — including a value offset that reaches into an
//! entry table, which would have one edit overwrite another: a blob we
//! could not verify is never written. A
//! malformation PAST them costs nothing, because the normalizer stops at
//! IFD0 — see [`exif_normalized`].
//!
//! IFD1's thumbnail is the pre-rotation, pre-edit picture, so a camera JPEG
//! exported after the open-time rotation — or after any crop or resize —
//! would carry a thumbnail of the wrong image, which is the same defect the
//! orientation reset exists to prevent. Zeroing the link is a pure in-place
//! patch; the thumbnail's bytes stay in the packet as legal unreferenced
//! data, which costs a few kilobytes and keeps the "never move an offset"
//! discipline absolute.
//!
//! # Why the 8BIM run may be filtered but a TIFF IFD may not
//!
//! An 8BIM image-resource block is fully self-describing — `'8BIM'`, a u16
//! id, a Pascal name whose WHOLE field (length byte included) is padded to
//! an even length, a u32 size, and data padded to an even length — and the
//! blocks carry **no cross-block offsets**, so dropping one cannot
//! invalidate another. That is what makes [`iptc_filtered`] safe in a way
//! that editing an IFD is not. It drops exactly the four resources that
//! would contradict what this save just wrote (`0x03ED` ResolutionInfo,
//! `0x040F` ICC profile, `0x0422` Exif, `0x0424` XMP) — Photoshop reads
//! `0x03ED` in PREFERENCE to JFIF and EXIF, so leaving it would reopen a
//! 300 ppi export at the source file's old ppi. Filtering happens on WRITE,
//! never on capture, so the stored packet stays byte-exact and the RZDC
//! round trip stays byte-identical.

use std::io::{self, Seek, SeekFrom, Write};
use std::ops::Range;

use crate::metadata::{
    crc32, resolution_from_exif, Entry, Resolution, Tiff, IPTC_ID, PNG_XMP_KEYWORD,
    TAG_COLOR_SPACE, TAG_EXIF_IFD, TAG_IMAGE_LENGTH, TAG_IMAGE_WIDTH, TAG_ORIENTATION,
    TAG_PIXEL_X_DIMENSION, TAG_PIXEL_Y_DIMENSION, TAG_RESOLUTION_UNIT, TAG_X_RESOLUTION,
    TAG_Y_RESOLUTION, TYPE_LONG, TYPE_RATIONAL, TYPE_SHORT, XMP_ID,
};

/// Largest payload a JPEG marker segment can carry: the 16-bit length field
/// includes its own two bytes.
pub(crate) const JPEG_MAX_PAYLOAD: usize = 65533;

/// The 8BIM image resources dropped on export because they would contradict
/// the density, the profile, the normalized EXIF and the XMP this save
/// writes for itself.
const DROPPED_8BIM: [u16; 4] = [0x03ED, 0x040F, 0x0422, 0x0424];

/// Metres per inch, for the PNG `pHYs` unit.
const METRES_PER_INCH: f64 = 0.0254;

/// What the encoder is asked to attach to one file. Everything here has
/// already been filtered by the format's capability row and the per-format
/// size limits — `doc_color::save_image` decides, this module writes.
pub(crate) struct EncodeSidecar<'a> {
    /// The ICC profile, embedded through the encoder's own writer.
    pub icc: Option<&'a [u8]>,
    /// The EXIF packet, already normalized by [`exif_normalized`].
    pub exif: Option<Vec<u8>>,
    /// The XMP packet, already normalized by
    /// `metadata_xmp::xmp_normalized`.
    pub xmp: Option<Vec<u8>>,
    /// The 8BIM run, already filtered by [`iptc_filtered`].
    pub iptc: Option<Vec<u8>>,
    /// The document's print resolution.
    pub dpi: Option<Resolution>,
}

impl EncodeSidecar<'_> {
    /// Attach nothing — what a bare `rz_image_save` passes, so a plain image
    /// save produces exactly the bytes it always did.
    pub(crate) const NONE: EncodeSidecar<'static> = EncodeSidecar {
        icc: None,
        exif: None,
        xmp: None,
        iptc: None,
        dpi: None,
    };

    /// The segments or chunks the `image` encoders cannot write themselves,
    /// ready for [`MetadataInjector`]. Empty for every format but JPEG and
    /// PNG, and empty for those two when there is nothing extra to say.
    pub(crate) fn jpeg_segments(&self) -> Vec<Vec<u8>> {
        let mut out = Vec::new();
        if let Some(xmp) = &self.xmp {
            if let Some(seg) = jpeg_app1_xmp(xmp) {
                out.push(seg);
            }
        }
        if let Some(iptc) = &self.iptc {
            if let Some(seg) = jpeg_app13_iptc(iptc) {
                out.push(seg);
            }
        }
        out
    }

    /// The PNG chunks, in the order they are injected after `IHDR`.
    pub(crate) fn png_chunks(&self) -> Vec<Vec<u8>> {
        let mut out = Vec::new();
        if let Some(dpi) = self.dpi {
            out.push(png_phys(dpi));
        }
        if let Some(xmp) = &self.xmp {
            out.push(png_itxt_xmp(xmp));
        }
        out
    }
}

// ------------------------------------------------------- EXIF normalizer --

/// A packet ready to be written, and whether it STATES the document's print
/// resolution — which the resolution trio is only sometimes able to say
/// (see [`patch_resolution`]).
///
/// The flag exists because a format with no density slot of its own can
/// still carry the ppi inside this packet: WebP writes an EXIF chunk and
/// nothing else, so what the file says about resolution is exactly what
/// this packet says. The save reports `RZ_CARRIES_RESOLUTION` from the two
/// together rather than from the format table alone, so the report and the
/// file cannot disagree.
///
/// It is never true of a packet that states a DIFFERENT resolution: such a
/// packet is refused whole ([`patch_resolution`]), because Exif/DCF makes
/// IFD0 the authority over a JFIF or `pHYs` density, so a stale pair here
/// would outrank the correct number beside it.
pub(crate) struct NormalizedExif {
    pub bytes: Vec<u8>,
    pub states_resolution: bool,
}

/// The EXIF packet as it should be written: IFD0's Orientation set to 1, its
/// resolution and dimension tags brought into line with the document, and
/// its next-IFD link zeroed so the stale thumbnail is unreferenced. `None`
/// when the packet is malformed in any way — the caller then drops it and
/// reports the EXIF as not carried.
///
/// Every patch is in place. Tags that are absent are never inserted, and a
/// tag whose shape is not one this crate can patch (a non-inline dimension,
/// a colour-space tag that is not an inline scalar) is left exactly as it
/// was — those are advisory. The ORIENTATION is not advisory: a packet whose
/// orientation entry cannot be patched in place is refused whole, because
/// writing a stale rotation back out is the one failure this function exists
/// to prevent. Neither is the RESOLUTION, which outranks the container's own
/// density: a trio that states something this document does not and cannot
/// be corrected refuses the packet too ([`patch_resolution`]). So does one whose queued edits would
/// collide with each other, with an IFD's entry table or with another tag's
/// out-of-line datum, which is a crafted block rather than a shape to
/// decline — [`patches_are_safe`] is the check, run before a byte is
/// written.
///
/// **The walk stops at IFD0**, and that is the point rather than a
/// shortcut. IFD1 and anything after it is UNLINKED two lines below, so
/// nothing further down the chain is ever written; reading it could only
/// cost the packet, never save it. Walking on used to mean that a
/// thumbnail-stripping tool's leftover next-IFD offset — a link into
/// nowhere, which is common in the wild — dropped every IFD0 tag the file
/// had: the camera make, the date, the copyright. Now a broken link costs
/// the thumbnail it points at, which was being discarded anyway.
pub(crate) fn exif_normalized(
    blob: &[u8],
    w: u32,
    h: u32,
    dpi: Resolution,
    srgb: bool,
) -> Option<NormalizedExif> {
    let t = Tiff::new(blob)?;
    let (entries, link) = t.ifd(t.ifd0)?;
    // The IFD STRUCTURES, gathered before anything is queued: the 8-byte
    // TIFF header every offset in the packet is measured from, and the entry
    // count, the `count * 12` entries and the four-byte next-IFD link of
    // IFD0 and, when there is one, of the Exif sub-IFD. An out-of-line datum
    // that reaches into one of these is a crafted packet rather than a file
    // to patch — see [`patches_are_safe`].
    let mut structures: Vec<Range<usize>> = Vec::with_capacity(3);
    structures.push(0..8);
    structures.push(t.ifd0..link + 4);
    let sub_entries = match entries
        .iter()
        .find(|e| e.tag == TAG_EXIF_IFD)
        .and_then(|e| t.scalar(e))
    {
        Some(sub) => {
            let sub = sub as usize;
            let (sub_entries, sub_link) = t.ifd(sub)?;
            // A sub-IFD that lands ANYWHERE inside the header or IFD0 is a
            // malformed packet, not a second helping of the same entries:
            // its "entries" would be those bytes read at a shifted offset,
            // and patching one of them would corrupt a tag outright.
            let extent = sub..sub_link + 4;
            if structures.iter().any(|s| overlaps(s, &extent)) {
                return None;
            }
            structures.push(extent);
            sub_entries
        }
        None => Vec::new(),
    };
    let mut patches: Vec<Patch> = Vec::new();
    let states_resolution = patch_ifd0(&t, &entries, w, h, dpi, &mut patches)?;
    // Drop IFD1: its thumbnail is the pre-edit picture. Its four bytes sit
    // right after IFD0's entries, so this is an in-structure edit like the
    // inline ones.
    patches.push(Patch::inline(link, t.u32_bytes(0).to_vec()));
    for e in &sub_entries {
        match e.tag {
            // Exif 2.32 §4.6.5: 1 is sRGB and 0xFFFF ("Uncalibrated") means
            // the space is the one the embedded ICC profile names, which is
            // what Photoshop and Lightroom write for a non-sRGB export.
            // Leaving a camera's 1 beside a Display P3 profile tells every
            // reader that honours the tag to read P3 numbers as sRGB, and
            // the picture comes out visibly oversaturated.
            TAG_COLOR_SPACE => {
                push_inline(&t, e, if srgb { 1 } else { 0xFFFF }, &mut patches);
            }
            TAG_PIXEL_X_DIMENSION => {
                push_inline(&t, e, w, &mut patches);
            }
            TAG_PIXEL_Y_DIMENSION => {
                push_inline(&t, e, h, &mut patches);
            }
            _ => {}
        }
    }
    if !patches_are_safe(
        &patches,
        &structures,
        &foreign_datums(&t, &entries, &sub_entries),
    ) {
        return None;
    }
    let mut out = blob.to_vec();
    for p in patches {
        let slot = out.get_mut(p.at..p.at.checked_add(p.bytes.len())?)?;
        slot.copy_from_slice(&p.bytes);
    }
    Some(NormalizedExif {
        bytes: out,
        states_resolution,
    })
}

/// One queued in-place edit.
struct Patch {
    at: usize,
    bytes: Vec<u8>,
    /// True when the target is an entry's own four-byte value field (or the
    /// next-IFD link beside it), which lives INSIDE an IFD's structure;
    /// false for an out-of-line datum, which must lie clear of every one.
    inline: bool,
}

impl Patch {
    fn inline(at: usize, bytes: Vec<u8>) -> Patch {
        Patch {
            at,
            bytes,
            inline: true,
        }
    }

    fn datum(at: usize, bytes: Vec<u8>) -> Patch {
        Patch {
            at,
            bytes,
            inline: false,
        }
    }

    fn range(&self) -> Range<usize> {
        self.at..self.at.saturating_add(self.bytes.len())
    }
}

/// True when two byte ranges share a byte.
fn overlaps(a: &Range<usize>, b: &Range<usize>) -> bool {
    a.start < b.end && b.start < a.end
}

/// True when the queued edits can all be applied and each still says what it
/// was queued to say. Three rules, and a packet that breaks any of them is
/// refused WHOLE, exactly as an unpatchable orientation is:
///
/// * **an out-of-line datum lies clear of every IFD structure.** A value
///   offset is not obliged to point at data. A crafted XResolution can aim
///   its eight bytes at the Orientation entry's own value field — passing
///   [`rational_slot`]'s bounds check — and overwrite the reset this whole
///   function exists to make, along with the tag and type of the entry after
///   it, while the save still reports the EXIF as carried. The packet's own
///   8-byte TIFF header is one of those structures: a value offset of 0 is
///   inside the block and passes every bounds check, and writing eight bytes
///   there destroys the byte order mark and the magic 42, so no reader can
///   parse the block at all.
/// * **an out-of-line datum lies clear of every OTHER tag's datum**
///   ([`foreign_datums`]). An offset that lands inside a MakerNote's or a
///   date string's storage corrupts that tag just as silently.
/// * **no two edits touch the same byte.** They are applied in order, so an
///   overlap means a later one silently undoes an earlier one. Two
///   RATIONALs four bytes apart do exactly that, which the equal-offset
///   check in [`patch_resolution`] never sees.
///
/// Pairwise because the lists have a handful of entries each; the ranges are
/// not sorted anywhere else, and sorting them here would only hide which
/// edit collided with which.
fn patches_are_safe(
    patches: &[Patch],
    structures: &[Range<usize>],
    foreign: &[Range<usize>],
) -> bool {
    patches.iter().enumerate().all(|(i, p)| {
        let range = p.range();
        let clear = |others: &[Range<usize>]| !others.iter().any(|o| overlaps(o, &range));
        (p.inline || (clear(structures) && clear(foreign)))
            && patches[i + 1..]
                .iter()
                .all(|other| !overlaps(&range, &other.range()))
    })
}

/// Where every tag this function does NOT patch out of line keeps its data —
/// the ranges an edit of ours must not reach into.
///
/// The two resolution tags are excluded because they are the only out-of-line
/// patches this module makes, and because they may legally SHARE one eight-
/// byte datum: a writer that de-duplicates equal values points both entries
/// at it, and treating each as the other's foreign datum would refuse a
/// perfectly ordinary packet. Their own extents are validated by
/// [`rational_slot`], which takes them from `Tiff::data_range` rather than
/// from the raw offset.
///
/// An INLINE entry's "data" is its own four-byte field, which lives inside an
/// IFD structure and is therefore already covered; listing it again is free
/// and keeps the rule one line.
fn foreign_datums(t: &Tiff<'_>, ifd0: &[Entry], sub: &[Entry]) -> Vec<Range<usize>> {
    ifd0.iter()
        .chain(sub)
        .filter(|e| e.tag != TAG_X_RESOLUTION && e.tag != TAG_Y_RESOLUTION)
        .filter_map(|e| t.data_range(e))
        .collect()
}

/// `None` when the orientation entry is present but cannot be patched in
/// place, or when the resolution trio states something this document does
/// not and cannot be corrected — either makes the whole packet unwritable;
/// otherwise whether the packet now STATES the document's resolution.
fn patch_ifd0(
    t: &Tiff<'_>,
    entries: &[Entry],
    w: u32,
    h: u32,
    dpi: Resolution,
    patches: &mut Vec<Patch>,
) -> Option<bool> {
    for e in entries {
        match e.tag {
            // The reset is MANDATORY — the rotation is already in the
            // pixels — so a shape that cannot be patched refuses the packet
            // rather than letting a stale rotation through.
            TAG_ORIENTATION => {
                if !push_inline(t, e, 1, patches) {
                    return None;
                }
            }
            TAG_IMAGE_WIDTH => {
                push_inline(t, e, w, patches);
            }
            TAG_IMAGE_LENGTH => {
                push_inline(t, e, h, patches);
            }
            _ => {}
        }
    }
    match patch_resolution(t, entries, dpi, patches) {
        ResolutionSay::States => Some(true),
        ResolutionSay::Silent => Some(false),
        ResolutionSay::Contradicts => None,
    }
}

/// What the exported packet ends up saying about the print resolution.
enum ResolutionSay {
    /// It states THIS document's ppi — because the trio was brought to it,
    /// or because it already said exactly that.
    States,
    /// It carries no resolution tag at all, so the container's own density
    /// is the file's only statement about one.
    Silent,
    /// It states a resolution that is not this document's and cannot be
    /// corrected. The packet is refused whole.
    Contradicts,
}

/// Brings XResolution, YResolution and ResolutionUnit to the document's ppi
/// in inches — ALL THREE OR NONE — and answers what the packet ends up
/// saying.
///
/// The trio is one statement, so it is patched as one. Two shapes make that
/// matter, and both were live defects:
///
/// * The rationals are meaningless without the unit they are counted in. A
///   ResolutionUnit this crate cannot overwrite in place (anything but an
///   inline SHORT or LONG of count 1) left at 3 while the rationals become
///   300/1 states 300 pixels per CENTIMETRE — 762 ppi — in a file we meant
///   to say 300 ppi. The mirror is as bad: flipping the unit to 2 while the
///   old centimetre numbers stay understates the resolution by 2.54x.
/// * A count-1 RATIONAL is always out of line, and a writer that
///   de-duplicates equal values points BOTH entries at the same eight
///   bytes. Patching them separately would write the vertical ppi over the
///   horizontal one and state one wrong number for both axes. Giving them
///   their own storage would grow the packet and move every offset after
///   it, which this module never does — so an anisotropic document cannot
///   be spelled through one shared datum at all.
///
/// **Leaving the trio alone is NOT the fallback**, and believing it was is
/// what made this the file's worst statement rather than its most cautious
/// one: Exif/DCF makes IFD0's XResolution/YResolution the authority over a
/// JFIF APP0 or a PNG `pHYs`, so a stale pair does not sit quietly beside
/// the density this save wrote — it outranks it, in ImageIO, ImageMagick
/// and Photoshop alike, and the file then reads back at the SOURCE's ppi.
///
/// So a trio that cannot be corrected costs the PACKET: it is refused
/// whole, the same treatment a malformed one gets, and the save reports the
/// EXIF as dropped while the container's density carries the ppi.
///
/// Setting ResolutionUnit to 1 ("none") instead — making the rationals a
/// bare aspect ratio, which is what this crate's own reader then sees — was
/// tried first and does not work, and that is a measurement rather than a
/// judgement: with a unit of 1 and a stale `999/1`, `sips -g dpiWidth` and
/// `magick identify -format %x` both still answer **999** and ignore the
/// JFIF density beside it. A packet is in authority for as long as it
/// exists, so the only way to hand the density back its authority is to not
/// write the packet.
///
/// A packet that already states exactly the document's ppi (a centimetre
/// trio whose numbers happen to be right, say) is left untouched and
/// reported as stating it. An ABSENT unit needs no patch when the rationals
/// ARE patchable — TIFF's default is already 2 — but an absent rational
/// cannot be inserted, so a packet carrying only one of them cannot be
/// corrected either, and a packet carrying neither says nothing to correct.
fn patch_resolution(
    t: &Tiff<'_>,
    entries: &[Entry],
    dpi: Resolution,
    patches: &mut Vec<Patch>,
) -> ResolutionSay {
    let find = |tag: u16| entries.iter().find(|e| e.tag == tag);
    let (x, y) = (find(TAG_X_RESOLUTION), find(TAG_Y_RESOLUTION));
    let mut queued = Vec::new();
    if trio_in_place(t, x, y, find(TAG_RESOLUTION_UNIT), dpi, &mut queued) {
        patches.append(&mut queued);
        return ResolutionSay::States;
    }
    // The trio could not be corrected, so the only question left is whether
    // the packet makes a resolution claim at all. What it CLAIMS is asked
    // through the crate's ONE reader, so "which ppi does this state" has the
    // same answer here as on the next open; whether it claims anything is
    // asked of the ENTRIES, because a claim this reader cannot make sense of
    // is still one another reader may act on.
    match resolution_from_exif(t.bytes).map(Resolution::sane) {
        Some(stated) if stated == dpi => ResolutionSay::States,
        _ if x.is_some() || y.is_some() => ResolutionSay::Contradicts,
        _ => ResolutionSay::Silent,
    }
}

/// Queues the three edits that bring the trio to `dpi` in inches, or answers
/// false having queued nothing (see [`patch_resolution`] for each shape).
fn trio_in_place(
    t: &Tiff<'_>,
    x: Option<&Entry>,
    y: Option<&Entry>,
    unit: Option<&Entry>,
    dpi: Resolution,
    queued: &mut Vec<Patch>,
) -> bool {
    let (Some(x), Some(y)) = (x, y) else {
        return false;
    };
    let (Some(at_x), Some(at_y)) = (rational_slot(t, x), rational_slot(t, y)) else {
        return false;
    };
    let bytes_x = rational_bytes(t, dpi.x);
    let bytes_y = rational_bytes(t, dpi.y);
    if at_x == at_y && bytes_x != bytes_y {
        return false;
    }
    // 2 = inch, which is what the rationals below state.
    if let Some(unit) = unit {
        if !push_inline(t, unit, 2, queued) {
            return false;
        }
    }
    queued.push(Patch::datum(at_x, bytes_x));
    if at_y != at_x {
        queued.push(Patch::datum(at_y, bytes_y));
    }
    true
}

/// Where a RATIONAL count-1 tag's two LONGs live. Count 1 is 8 bytes, so the
/// field is ALWAYS an offset and overwriting what it points at moves
/// nothing. `None` for any other shape — those are shapes to leave alone.
///
/// The extent comes from `Tiff::data_range`, the same reader that validated
/// every entry when the IFD was walked, rather than from the raw offset: one
/// bounds check, in one place. An offset that is inside the packet but
/// points somewhere it should not is NOT filtered here — it is queued and
/// caught by [`patches_are_safe`], which refuses the packet, because a
/// resolution datum aimed at the TIFF header or into another tag's storage
/// is a malformed block rather than a shape this module declines to patch.
fn rational_slot(t: &Tiff<'_>, e: &Entry) -> Option<usize> {
    if e.kind != TYPE_RATIONAL || e.count != 1 {
        return None;
    }
    let range = t.data_range(e)?;
    (range.len() == 8).then_some(range.start)
}

/// A ppi as the eight bytes of a RATIONAL, in the packet's byte order.
fn rational_bytes(t: &Tiff<'_>, ppi: f32) -> Vec<u8> {
    let v = f64::from(ppi);
    // An integral ppi is written as n/1 so a reader shows "300", not
    // "3000000/10000"; anything else keeps four decimals, which is the
    // precision `Resolution::sane` stores.
    let (num, den) = if (v - v.round()).abs() < 1e-4 {
        (v.round().max(1.0) as u32, 1u32)
    } else {
        ((v * 10_000.0).round().max(1.0) as u32, 10_000u32)
    };
    let mut bytes = Vec::with_capacity(8);
    bytes.extend_from_slice(&t.u32_bytes(num));
    bytes.extend_from_slice(&t.u32_bytes(den));
    bytes
}

/// Overwrites an INLINE scalar tag (SHORT or LONG, count 1) — the shape the
/// orientation, the dimension and the resolution-unit tags all have. False
/// when the entry is some other shape, or a SHORT that cannot hold the
/// value: the caller decides whether that is fatal (orientation, and the
/// resolution trio it would leave self-contradictory) or something to leave
/// alone (dimensions, which are advisory, and where a wrong small number
/// would be worse than a stale one).
fn push_inline(t: &Tiff<'_>, e: &Entry, value: u32, patches: &mut Vec<Patch>) -> bool {
    if e.count != 1 {
        return false;
    }
    match e.kind {
        TYPE_SHORT => match u16::try_from(value) {
            Ok(v) => {
                // The two value bytes are the whole edit; the remaining two
                // bytes of the field are already zero padding.
                patches.push(Patch::inline(e.field, t.u16_bytes(v).to_vec()));
                true
            }
            Err(_) => false,
        },
        TYPE_LONG => {
            patches.push(Patch::inline(e.field, t.u32_bytes(value).to_vec()));
            true
        }
        _ => false,
    }
}

// ---------------------------------------------------------- 8BIM filter --

/// The 8BIM run minus the resources that would contradict what this save
/// wrote. `None` when the run is malformed; an EMPTY result means "write no
/// APP13", which the caller reports by leaving the IPTC bit clear.
pub(crate) fn iptc_filtered(blob: &[u8]) -> Option<Vec<u8>> {
    let mut out = Vec::with_capacity(blob.len());
    let mut i = 0usize;
    while i < blob.len() {
        // Signature (4) + id (2) + an empty Pascal name (2) + size (4).
        if blob.len() - i < 12 || &blob[i..i + 4] != b"8BIM" {
            return None;
        }
        let id = u16::from_be_bytes([blob[i + 4], blob[i + 5]]);
        let name_len = usize::from(blob[i + 6]);
        // The WHOLE name field — its length byte included — is padded to an
        // even size.
        let name_field = (1 + name_len).next_multiple_of(2);
        let size_at = i.checked_add(6)?.checked_add(name_field)?;
        if size_at.checked_add(4)? > blob.len() {
            return None;
        }
        let size = u32::from_be_bytes([
            blob[size_at],
            blob[size_at + 1],
            blob[size_at + 2],
            blob[size_at + 3],
        ]) as usize;
        // The data is padded to an even length; the pad byte is not counted.
        let padded = size.checked_add(size % 2)?;
        let end = size_at.checked_add(4)?.checked_add(padded)?;
        if end > blob.len() {
            return None;
        }
        if !DROPPED_8BIM.contains(&id) {
            out.extend_from_slice(&blob[i..end]);
        }
        i = end;
    }
    Some(out)
}

// ------------------------------------------------------------- builders --

/// A JPEG APP1 segment carrying the XMP packet. `None` when it would not fit
/// one segment — ExtendedXMP is neither read nor written, so an oversize
/// packet is dropped and reported rather than split.
pub(crate) fn jpeg_app1_xmp(xmp: &[u8]) -> Option<Vec<u8>> {
    jpeg_segment(0xE1, XMP_ID, xmp)
}

/// A JPEG APP13 segment carrying the (already filtered) 8BIM run. `None`
/// for an empty run — there is nothing to say — or one too large for a
/// segment.
pub(crate) fn jpeg_app13_iptc(run: &[u8]) -> Option<Vec<u8>> {
    if run.is_empty() {
        return None;
    }
    jpeg_segment(0xED, IPTC_ID, run)
}

fn jpeg_segment(marker: u8, id: &[u8], payload: &[u8]) -> Option<Vec<u8>> {
    let total = id.len().checked_add(payload.len())?;
    if total > JPEG_MAX_PAYLOAD {
        return None;
    }
    let mut seg = Vec::with_capacity(total + 4);
    seg.push(0xFF);
    seg.push(marker);
    seg.extend_from_slice(&((total + 2) as u16).to_be_bytes());
    seg.extend_from_slice(id);
    seg.extend_from_slice(payload);
    Some(seg)
}

/// The PNG `pHYs` chunk for a resolution: pixels per metre on both axes,
/// unit 1 (the metre).
pub(crate) fn png_phys(dpi: Resolution) -> Vec<u8> {
    let ppm = |ppi: f32| {
        (f64::from(ppi) / METRES_PER_INCH)
            .round()
            .clamp(1.0, f64::from(u32::MAX)) as u32
    };
    let mut data = Vec::with_capacity(9);
    data.extend_from_slice(&ppm(dpi.x).to_be_bytes());
    data.extend_from_slice(&ppm(dpi.y).to_be_bytes());
    data.push(1);
    png_chunk(b"pHYs", &data)
}

/// The PNG `iTXt` chunk Adobe's XMP convention uses: keyword
/// `XML:com.adobe.xmp`, uncompressed, no language and no translated
/// keyword.
pub(crate) fn png_itxt_xmp(xmp: &[u8]) -> Vec<u8> {
    let mut data = Vec::with_capacity(PNG_XMP_KEYWORD.len() + 5 + xmp.len());
    data.extend_from_slice(PNG_XMP_KEYWORD);
    data.push(0); // keyword terminator
    data.push(0); // compression flag: uncompressed
    data.push(0); // compression method
    data.push(0); // empty language tag
    data.push(0); // empty translated keyword
    data.extend_from_slice(xmp);
    png_chunk(b"iTXt", &data)
}

/// One complete PNG chunk: length, type, data, CRC-32 over type + data.
fn png_chunk(kind: &[u8; 4], data: &[u8]) -> Vec<u8> {
    let mut chunk = Vec::with_capacity(data.len() + 12);
    chunk.extend_from_slice(&(data.len() as u32).to_be_bytes());
    chunk.extend_from_slice(kind);
    chunk.extend_from_slice(data);
    let crc = crc32(&chunk[4..]);
    chunk.extend_from_slice(&crc.to_be_bytes());
    chunk
}

// ------------------------------------------------------------- injector --

/// How much of one `write` call is taken into the prefix buffer before it is
/// drained again. Together with the largest single JPEG segment this bounds
/// the buffer at about 128 KB however the encoder chooses to write, so a
/// 100 MP save never doubles its peak memory.
const MAX_PREFIX_CHUNK: usize = 1 << 16;

enum Mode {
    /// Inject nothing — the only mode a SEEKING encoder may receive.
    Passthrough,
    /// Pass the whole leading APPn/COM run through, then inject.
    Jpeg,
    /// Pass the signature and `IHDR` through, then inject.
    Png,
}

/// Wraps the file writer and splices the segments or chunks the `image`
/// encoders cannot write, streaming — the encoded bytes are never buffered
/// whole.
///
/// `W: Write + Seek` because `TiffEncoder` is `impl<W: Write + Seek>` (the
/// `tiff` crate seeks to backpatch IFD offsets) while PNG, JPEG, BMP, GIF
/// and WebP are `Write` only. That is honest only because the sole mode a
/// seeking encoder is ever given is [`Mode::Passthrough`], which injects
/// nothing, so the inner writer's offsets are the encoder's offsets — and
/// the [`Seek`] impl below asserts it rather than trusting it.
pub(crate) struct MetadataInjector<W: Write + Seek> {
    inner: W,
    mode: Mode,
    extra: Vec<Vec<u8>>,
    pending: Vec<u8>,
    saw_signature: bool,
    /// True once the injection point is behind us and writes go straight
    /// through.
    done: bool,
}

impl<W: Write + Seek> MetadataInjector<W> {
    /// The JPEG encoder never seeks: it streams SOI, APP0, APP1, APP2xN,
    /// SOF0, and so on.
    pub(crate) fn jpeg(inner: W, segments: Vec<Vec<u8>>) -> Self {
        MetadataInjector {
            inner,
            mode: Mode::Jpeg,
            extra: segments,
            pending: Vec::new(),
            saw_signature: false,
            done: false,
        }
    }

    /// The PNG encoder never seeks.
    pub(crate) fn png(inner: W, chunks: Vec<Vec<u8>>) -> Self {
        MetadataInjector {
            inner,
            mode: Mode::Png,
            extra: chunks,
            pending: Vec::new(),
            saw_signature: false,
            done: false,
        }
    }

    /// Injects nothing and forwards everything, seeks included.
    pub(crate) fn passthrough(inner: W) -> Self {
        MetadataInjector {
            inner,
            mode: Mode::Passthrough,
            extra: Vec::new(),
            pending: Vec::new(),
            saw_signature: true,
            done: true,
        }
    }

    /// Finishes the splice and hands the inner writer back so the caller can
    /// flush it. An error means the encoder never produced the marker the
    /// injection point is defined by, which would be a defect in this crate
    /// rather than anything the file could cause; the bytes written so far
    /// are in a temporary file the atomic save discards.
    pub(crate) fn finish(mut self) -> Result<W, String> {
        if !self.done {
            let pending = std::mem::take(&mut self.pending);
            self.inner
                .write_all(&pending)
                .map_err(|e| format!("encoding failed: {e}"))?;
            return Err(match self.mode {
                Mode::Jpeg => {
                    "encoding failed: the JPEG stream carried no frame header".to_string()
                }
                _ => "encoding failed: the PNG stream carried no IHDR chunk".to_string(),
            });
        }
        Ok(self.inner)
    }

    /// Writes everything decidable out of `pending`, injecting once the
    /// point is reached.
    fn drain(&mut self) -> io::Result<()> {
        match self.mode {
            Mode::Passthrough => Ok(()),
            Mode::Jpeg => self.drain_jpeg(),
            Mode::Png => self.drain_png(),
        }
    }

    fn drain_jpeg(&mut self) -> io::Result<()> {
        loop {
            if !self.saw_signature {
                if self.pending.len() < 2 {
                    return Ok(());
                }
                if self.pending[0] != 0xFF || self.pending[1] != 0xD8 {
                    return Err(io::Error::other(
                        "MetadataInjector: the encoded stream does not start with a JPEG SOI",
                    ));
                }
                self.emit(2)?;
                self.saw_signature = true;
            }
            if self.pending.len() < 4 {
                return Ok(());
            }
            let (m0, m1) = (self.pending[0], self.pending[1]);
            // APPn (0xE0..=0xEF) and COM (0xFE) are the leading run. The
            // injection goes AFTER all of them, so our XMP APP1 and IPTC
            // APP13 land behind the encoder's Exif APP1 and ICC APP2 — Exif
            // stays the first APP1, which is what strict readers look for.
            let leading = m0 == 0xFF && ((0xE0..=0xEF).contains(&m1) || m1 == 0xFE);
            if !leading {
                return self.inject();
            }
            let len = usize::from(u16::from_be_bytes([self.pending[2], self.pending[3]]));
            if len < 2 {
                return self.inject();
            }
            let total = 2 + len;
            if self.pending.len() < total {
                return Ok(());
            }
            self.emit(total)?;
        }
    }

    fn drain_png(&mut self) -> io::Result<()> {
        // Signature (8) + chunk length (4) + type (4).
        if self.pending.len() < 16 {
            return Ok(());
        }
        if &self.pending[12..16] != b"IHDR" {
            return Err(io::Error::other(
                "MetadataInjector: the encoded stream does not start with a PNG IHDR",
            ));
        }
        let len = u32::from_be_bytes([
            self.pending[8],
            self.pending[9],
            self.pending[10],
            self.pending[11],
        ]) as usize;
        let total = 8 + 8 + len + 4;
        if self.pending.len() < total {
            return Ok(());
        }
        self.emit(total)?;
        self.inject()
    }

    /// Moves the first `n` pending bytes to the inner writer.
    fn emit(&mut self, n: usize) -> io::Result<()> {
        self.inner.write_all(&self.pending[..n])?;
        self.pending.drain(..n);
        Ok(())
    }

    /// Writes the extra segments/chunks, then everything still pending, and
    /// switches to straight pass-through.
    fn inject(&mut self) -> io::Result<()> {
        for block in &self.extra {
            self.inner.write_all(block)?;
        }
        let pending = std::mem::take(&mut self.pending);
        self.inner.write_all(&pending)?;
        self.done = true;
        Ok(())
    }
}

impl<W: Write + Seek> Write for MetadataInjector<W> {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        if self.done {
            return self.inner.write(buf);
        }
        // The whole buffer is always consumed — a short return would be
        // legal `Write` but silently loses bytes for any caller that uses
        // `write` rather than `write_all`. Memory stays bounded because only
        // [`MAX_PREFIX_CHUNK`] is added to the prefix buffer before draining
        // it again, so `pending` never exceeds one segment plus that.
        let mut rest = buf;
        while !rest.is_empty() && !self.done {
            let take = rest.len().min(MAX_PREFIX_CHUNK);
            self.pending.extend_from_slice(&rest[..take]);
            rest = &rest[take..];
            self.drain()?;
        }
        // The injection point was reached part-way through this buffer; the
        // remainder is ordinary payload.
        if !rest.is_empty() {
            self.inner.write_all(rest)?;
        }
        Ok(buf.len())
    }

    /// Flushes the inner writer. Bytes still held for the splice stay held:
    /// where they belong is not known until the injection point is found,
    /// and no encoder here depends on a mid-header flush reaching the file.
    fn flush(&mut self) -> io::Result<()> {
        self.inner.flush()
    }
}

impl<W: Write + Seek> Seek for MetadataInjector<W> {
    /// Only a pass-through injector may seek. A spliced stream's offsets are
    /// not the encoder's — that is the whole point of the splice — so an
    /// encoder that seeks must not be given one, and saying so loudly beats
    /// corrupting the file.
    fn seek(&mut self, pos: SeekFrom) -> io::Result<u64> {
        match self.mode {
            Mode::Passthrough => self.inner.seek(pos),
            _ => Err(io::Error::other(
                "MetadataInjector: the encoder for this format seeks, so it must not be spliced",
            )),
        }
    }
}
