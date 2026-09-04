//! The EXIF / XMP / IPTC packets a document preserves, the print
//! resolution, and the ONE container walk that reads them out of a JPEG or a
//! PNG. The write half — the segment and chunk builders, the streaming
//! injector, the in-place EXIF normalizer and the 8BIM filter — is
//! `metadata_write`; the document-level ops that use both are `doc_color`.
//!
//! # The contract on a packet
//!
//! A packet is **stored verbatim and never interpreted** — the same opaque
//! "parasite" contract a layer's `meta` has, one level up. The core does not
//! parse an EXIF block to answer questions about it; the two places it looks
//! inside are narrow and stated: [`resolution_from_exif`] here, for the ppi
//! the file states (the authority Exif/DCF names, with the container's own
//! density as the fallback — see [`resolve_resolution`]), and
//! `metadata_write::exif_normalized` on the way out, to reset the
//! orientation the pixels already absorbed and to bring the resolution, the
//! colour space and the dimensions into line with the document (a packet it
//! cannot correct is dropped rather than written contradicting the file it
//! is in). `metadata_xmp::xmp_normalized` does the same for the XMP packet's
//! own copies of the orientation and the resolution.
//!
//! # Why JPEG and PNG only
//!
//! These are the two containers this crate can also SPLICE on the way out,
//! so the walk captures exactly what the save path can put back. A TIFF or
//! WebP contributes its ICC profile (which comes from the decoder, not from
//! here) and nothing else; BMP and GIF contribute nothing. `rz_format_carries`
//! is the same table as a query, and `rz_doc_save_image` reports what was
//! actually written, so a host can say so once rather than pretending.
//!
//! Blob conventions, fixed here and matched by the writer:
//!
//! * **EXIF** is the raw TIFF stream with **no `Exif\0\0` prefix** — the PNG
//!   `eXIf` convention. The JPEG scanner strips the 6-byte prefix and
//!   `image`'s JPEG encoder adds it back.
//! * **XMP** is the UTF-8 packet with no identifier: in a JPEG the APP1
//!   payload after `http://ns.adobe.com/xap/1.0/\0`, in a PNG the
//!   `iTXt` text under the keyword `XML:com.adobe.xmp`, **uncompressed
//!   only** (Adobe writes flag 0; a compressed one reads as absent).
//!   ExtendedXMP (`http://ns.adobe.com/xmp/extension/`) is not captured.
//! * **IPTC** is the JPEG APP13 payload after `Photoshop 3.0\0` — the whole
//!   8BIM image-resource run, never parsed on the way in. PNG carries none
//!   (ImageMagick's base64-in-`zTXt` convention is not IIM and is not read).

use std::sync::Arc;

use crate::rzdc::MAX_RZDC_BLOB_LEN;
use crate::style_json::q4;

/// The PNG signature.
const PNG_SIGNATURE: [u8; 8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

/// The JPEG APP1 identifier that introduces an XMP packet.
pub(crate) const XMP_ID: &[u8] = b"http://ns.adobe.com/xap/1.0/\0";

/// The JPEG APP13 identifier that introduces the 8BIM image-resource run.
pub(crate) const IPTC_ID: &[u8] = b"Photoshop 3.0\0";

/// The PNG `iTXt` keyword Adobe writes an XMP packet under.
pub(crate) const PNG_XMP_KEYWORD: &[u8] = b"XML:com.adobe.xmp";

/// Inches per metre's reciprocal — the PNG `pHYs` unit is pixels per metre.
const METRES_PER_INCH: f64 = 0.0254;

/// The print resolution a document with no stated one takes: 72 ppi, the
/// PostScript point, which is what every format assumes when it carries no
/// resolution at all.
const DEFAULT_PPI: f32 = 72.0;

/// Resolution clamp. Photoshop's own Image Size ceiling is 30 000 ppi, and
/// below 1 ppi the print size of a 100 MP canvas is measured in miles.
const MIN_PPI: f64 = 1.0;
const MAX_PPI: f64 = 30_000.0;

/// The three metadata packets, preserved verbatim from open and re-spliced
/// on export. `Arc<[u8]>` for the same copy-on-write reason as layer pixels:
/// every pure op clones the document, and a megabyte of XMP must not be
/// copied on a brush tick.
#[derive(Clone, Default, PartialEq, Eq, Debug)]
pub struct Metadata {
    pub exif: Option<Arc<[u8]>>,
    pub xmp: Option<Arc<[u8]>>,
    pub iptc: Option<Arc<[u8]>>,
}

impl Metadata {
    /// True when no packet is present — the state a document built from bare
    /// pixels is in.
    pub fn is_empty(&self) -> bool {
        self.exif.is_none() && self.xmp.is_none() && self.iptc.is_none()
    }
}

/// Print resolution in pixels per inch, per axis (Photoshop stores both).
/// Pixels never change with it — only the print size does.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Resolution {
    pub x: f32,
    pub y: f32,
}

impl Default for Resolution {
    fn default() -> Self {
        Resolution {
            x: DEFAULT_PPI,
            y: DEFAULT_PPI,
        }
    }
}

impl Resolution {
    /// The ONE sanitizer, used by the setter, the RZDC reader, the RZDC
    /// writer and the FFI — `GlobalLight::sane`'s twin. A non-finite or
    /// non-positive component takes the 72 ppi default; finite values clamp
    /// to [1, 30000] and quantize to four decimals through the style
    /// parser's own [`q4`], the crate's ONE four-decimal quantizer, so a
    /// host that echoes a reported value back through the setter is refused
    /// as unchanged instead of registering a phantom edit.
    pub fn sane(self) -> Self {
        Resolution {
            x: sane_ppi(self.x),
            y: sane_ppi(self.y),
        }
    }

    /// The two axes swapped when `swap` — a 300 x 150 ppi document turned
    /// 90 degrees is 150 x 300.
    pub(crate) fn transposed_if(self, swap: bool) -> Self {
        if swap {
            Resolution {
                x: self.y,
                y: self.x,
            }
        } else {
            self
        }
    }
}

fn sane_ppi(v: f32) -> f32 {
    if v.is_finite() && v > 0.0 {
        q4(f64::from(v).clamp(MIN_PPI, MAX_PPI))
    } else {
        DEFAULT_PPI
    }
}

/// Everything a container walk found. Absent fields are absent, never an
/// error: a corrupt APP1 is still an openable file.
#[derive(Default)]
pub(crate) struct Scan {
    pub metadata: Metadata,
    pub resolution: Option<Resolution>,
}

/// The two containers this crate walks, told apart by their magic — the ONE
/// place that test lives, so [`scan`] and [`walks`] can never disagree about
/// which files contribute their capture data.
enum Container {
    Jpeg,
    Png,
}

fn container(bytes: &[u8]) -> Option<Container> {
    if bytes.starts_with(&[0xFF, 0xD8]) {
        Some(Container::Jpeg)
    } else if bytes.starts_with(&PNG_SIGNATURE) {
        Some(Container::Png)
    } else {
        None
    }
}

/// True when [`scan`] would actually WALK these bytes — a JPEG or a PNG.
/// Asked so a host can say "the capture data was never read in" for every
/// container the walk skips, instead of only for the ones a platform decoder
/// produced: a TIFF or a WebP really can carry an EXIF block, and a document
/// opened from one holds no packet for the same reason a HEIC does, not
/// because the file had none.
pub(crate) fn walks(bytes: &[u8]) -> bool {
    container(bytes).is_some()
}

/// Reads the packets and the resolution out of the file's own bytes,
/// sniffing the container. Anything that is not a JPEG or a PNG scans empty.
/// A resolution found in a file is sanitized here, so no other caller has to
/// decide what an absurd one means.
pub(crate) fn scan(bytes: &[u8]) -> Scan {
    let mut found = match container(bytes) {
        Some(Container::Jpeg) => scan_jpeg(bytes),
        Some(Container::Png) => scan_png(bytes),
        None => Scan::default(),
    };
    found.resolution = found.resolution.map(Resolution::sane);
    found
}

/// Whether a packet would be kept if it were offered: the first one wins,
/// and anything larger than the format's own blob cap is refused so a
/// captured packet can always be saved again.
///
/// Separate from [`capture`] so a walk can ask BEFORE doing work that only
/// pays off if the answer is yes — see `scan_png`, where the work is a CRC
/// over the whole chunk.
fn capturable(slot: &Option<Arc<[u8]>>, bytes: &[u8]) -> bool {
    slot.is_none() && bytes.len() <= MAX_RZDC_BLOB_LEN as usize
}

/// Stores a captured packet, first one wins, refusing anything larger than
/// the format's own blob cap so a captured packet can always be saved again.
fn capture(slot: &mut Option<Arc<[u8]>>, bytes: &[u8]) {
    if capturable(slot, bytes) {
        *slot = Some(Arc::from(bytes.to_vec()));
    }
}

// ----------------------------------------------------------------- JPEG --

fn scan_jpeg(bytes: &[u8]) -> Scan {
    let mut out = Scan::default();
    let mut container = None;
    // The 8BIM run, CONCATENATED across every APP13 that carries it (see the
    // APP13 arm below), and whether it outgrew the blob cap on the way.
    let mut iptc: Vec<u8> = Vec::new();
    let mut iptc_over_cap = false;
    let mut i = 2usize;
    while i + 4 <= bytes.len() {
        if bytes[i] != 0xFF {
            break;
        }
        let marker = bytes[i + 1];
        // Fill bytes: any number of 0xFF may precede a marker code.
        if marker == 0xFF {
            i += 1;
            continue;
        }
        // Standalone markers carry no length.
        if marker == 0xD8 || marker == 0x01 || (0xD0..=0xD7).contains(&marker) {
            i += 2;
            continue;
        }
        // Entropy-coded data begins at SOS; nothing after it is a segment we
        // read.
        if marker == 0xDA || marker == 0xD9 {
            break;
        }
        let len = usize::from(u16::from_be_bytes([bytes[i + 2], bytes[i + 3]]));
        if len < 2 {
            break;
        }
        let start = i + 4;
        let Some(payload) = bytes.get(start..start + len - 2) else {
            break;
        };
        match marker {
            0xE0 => {
                if let Some(rest) = payload.strip_prefix(b"JFIF\0".as_slice()) {
                    if container.is_none() {
                        container = jfif_density(rest);
                    }
                }
            }
            0xE1 => {
                if let Some(rest) = payload.strip_prefix(b"Exif\0\0".as_slice()) {
                    capture(&mut out.metadata.exif, rest);
                } else if let Some(rest) = payload.strip_prefix(XMP_ID) {
                    capture(&mut out.metadata.xmp, rest);
                }
            }
            0xED => {
                if let Some(rest) = payload.strip_prefix(IPTC_ID) {
                    // CONCATENATED, not first-one-wins: Photoshop splits an
                    // image-resource run larger than one segment across
                    // several `Photoshop 3.0\0` APP13s, and a reader is
                    // meant to join them back into one run. Taking the first
                    // dropped every resource after it — silently, because
                    // the save then re-spliced the truncated prefix and
                    // reported the packet as written.
                    if iptc.len().saturating_add(rest.len()) <= MAX_RZDC_BLOB_LEN as usize {
                        iptc.extend_from_slice(rest);
                    } else {
                        // A run past the cap is dropped WHOLE. A truncated
                        // 8BIM run is malformed, and the export would have
                        // to claim a packet the file does not contain.
                        iptc_over_cap = true;
                    }
                }
            }
            // APP2 ICC_PROFILE is deliberately ignored: the decoder
            // reassembles multi-chunk profiles for every format, so doing it
            // here would be a second implementation.
            _ => {}
        }
        i = start + len - 2;
    }
    if !iptc.is_empty() && !iptc_over_cap {
        capture(&mut out.metadata.iptc, &iptc);
    }
    out.resolution = resolve_resolution(
        container,
        out.metadata.exif.as_deref().and_then(resolution_from_exif),
    );
    out
}

/// The JFIF APP0 density, after its `JFIF\0` identifier: version (2), units
/// (1), Xdensity (2), Ydensity (2).
fn jfif_density(rest: &[u8]) -> Option<Resolution> {
    let units = *rest.get(2)?;
    let x = f64::from(u16::from_be_bytes([*rest.get(3)?, *rest.get(4)?]));
    let y = f64::from(u16::from_be_bytes([*rest.get(5)?, *rest.get(6)?]));
    if x <= 0.0 || y <= 0.0 || not_stated(x, y) {
        return None;
    }
    match units {
        1 => Some(Resolution {
            x: x as f32,
            y: y as f32,
        }),
        // Units 2 is dots per centimetre.
        2 => Some(Resolution {
            x: (x * 2.54) as f32,
            y: (y * 2.54) as f32,
        }),
        // Units 0 is the pixel-aspect-ratio convention: no resolution.
        _ => None,
    }
}

/// The resolution a file states, when it states it twice: **the EXIF pair
/// wins**, and the container's density is the fallback for a file whose EXIF
/// says nothing (or says it in a unit — "none" — that is a bare aspect
/// ratio).
///
/// Both halves of that rule matter, and they point the same way:
///
/// * When the two AGREE, the EXIF pair is the more precise statement. A
///   container density — the JFIF APP0 pair, a PNG `pHYs` — is an INTEGER
///   count, of dots per inch or of pixels per metre, while
///   XResolution/YResolution are RATIONALs, so only EXIF can spell a
///   fractional ppi: a 150.5 ppi document this crate wrote reopens at 150.5
///   rather than at the 151 its own JFIF header had to round to.
/// * When they DISAGREE, the EXIF pair is the authority the specification
///   names. Exif/DCF makes IFD0's XResolution/YResolution the file's
///   statement of its print resolution — a JFIF APP0 is not even supposed to
///   be present in an Exif file — and it is what ImageIO, ImageMagick and
///   every other reader answers. Believing the container instead opened such
///   a file at the wrong ppi, which now shows up as a wrong print size in
///   Image Size and a wrong layout in Print, and made the app's two
///   "what ppi does this file state" paths (this one and ImageIO's, which
///   the host uses for the formats this crate cannot decode) contradict each
///   other about the same file.
fn resolve_resolution(
    container: Option<Resolution>,
    exif: Option<Resolution>,
) -> Option<Resolution> {
    exif.or(container)
}

/// A container density of exactly 1 x 1 means "not stated", whatever the
/// unit byte says. JFIF units 0 is the pixel-aspect-ratio convention and
/// always carries (1, 1) — it is also `PixelDensity::default()` in the very
/// crate this one encodes with — and that (1, 1) leaks into files written
/// with units 1 as well. Taking it literally makes a 300 ppi scan open
/// claiming a 4000-inch print size, because the sanitizer clamps 1 to 1
/// rather than rejecting it. A `pHYs` of 1 x 1 pixels per metre (0.0254 ppi)
/// is equally meaningless.
fn not_stated(x: f64, y: f64) -> bool {
    x == 1.0 && y == 1.0
}

// ------------------------------------------------------------------ PNG --

fn scan_png(bytes: &[u8]) -> Scan {
    let mut out = Scan::default();
    let mut container = None;
    let mut i = 8usize;
    while i + 12 <= bytes.len() {
        let len = u32::from_be_bytes([bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3]]) as usize;
        // A PNG chunk length is at most 2^31 - 1.
        if len > 0x7FFF_FFFF {
            break;
        }
        let Some(end) = i.checked_add(12).and_then(|e| e.checked_add(len)) else {
            break;
        };
        if end > bytes.len() {
            break;
        }
        let kind = &bytes[i + 4..i + 8];
        let data = &bytes[i + 8..i + 8 + len];
        // The CRC is spent only on a chunk this walk would actually KEEP,
        // and that is decided FIRST — by type, then by what the chunk turns
        // out to hold — because the check costs a table-free pass over the
        // chunk's whole data. The walk's bounds come from the length field,
        // not from the CRC, so verifying bytes that are then discarded buys
        // nothing: `IDAT` is essentially the entire file, and a crafted
        // 200 MB `iTXt` (a PNG chunk may be 2 GiB, and `capture` refuses
        // anything over 16 MiB anyway) would otherwise freeze an open for
        // seconds before dropping the blob. A chunk that fails its CRC is
        // not trusted, but the walk goes on: the rest of the file may be
        // fine.
        match kind {
            b"pHYs" if container.is_none() => {
                if let Some(density) = phys_density(data) {
                    if chunk_crc_ok(bytes, i, len, end) {
                        container = Some(density);
                    }
                }
            }
            b"eXIf" if capturable(&out.metadata.exif, data) => {
                if chunk_crc_ok(bytes, i, len, end) {
                    capture(&mut out.metadata.exif, data);
                }
            }
            b"iTXt" => {
                if let Some(text) = itxt_xmp(data) {
                    if capturable(&out.metadata.xmp, text) && chunk_crc_ok(bytes, i, len, end) {
                        capture(&mut out.metadata.xmp, text);
                    }
                }
            }
            _ => {}
        }
        if kind == b"IEND" {
            break;
        }
        i = end;
    }
    out.resolution = resolve_resolution(
        container,
        out.metadata.exif.as_deref().and_then(resolution_from_exif),
    );
    out
}

/// True when the chunk starting at `i` (type + data spanning `len` bytes,
/// its stored CRC in the four bytes before `end`) matches its CRC.
fn chunk_crc_ok(bytes: &[u8], i: usize, len: usize, end: usize) -> bool {
    let stored = u32::from_be_bytes([
        bytes[end - 4],
        bytes[end - 3],
        bytes[end - 2],
        bytes[end - 1],
    ]);
    crc32(&bytes[i + 4..i + 8 + len]) == stored
}

/// `pHYs`: x pixels per unit (4), y pixels per unit (4), unit specifier (1),
/// where unit 1 is the metre and 0 means "aspect ratio only".
fn phys_density(data: &[u8]) -> Option<Resolution> {
    if data.len() < 9 || data[8] != 1 {
        return None;
    }
    let x = f64::from(u32::from_be_bytes([data[0], data[1], data[2], data[3]]));
    let y = f64::from(u32::from_be_bytes([data[4], data[5], data[6], data[7]]));
    if x <= 0.0 || y <= 0.0 || not_stated(x, y) {
        return None;
    }
    Some(Resolution {
        x: snapped(x * METRES_PER_INCH),
        y: snapped(y * METRES_PER_INCH),
    })
}

/// How far a reconstructed ppi may sit from a whole number and still be read
/// as that number. A `pHYs` chunk counts pixels per METRE as an integer, so
/// no integral ppi can be stored exactly: 300 ppi is written as 11811 px/m
/// and reads back as 299.9994. The reconstruction error is bounded by half a
/// pixel per metre, i.e. 0.0127 ppi, so a 0.02 window recovers exactly the
/// number that was written and cannot reach a neighbouring integer. A
/// genuinely fractional resolution (299.5) is left alone.
const PPI_SNAP: f64 = 0.02;

fn snapped(ppi: f64) -> f32 {
    let whole = ppi.round();
    if (ppi - whole).abs() <= PPI_SNAP {
        whole as f32
    } else {
        ppi as f32
    }
}

/// The text of an `iTXt` chunk whose keyword is `XML:com.adobe.xmp` and
/// whose compression flag is 0. Layout: keyword, NUL, compression flag,
/// compression method, language tag, NUL, translated keyword, NUL, text.
fn itxt_xmp(data: &[u8]) -> Option<&[u8]> {
    // Matched as a prefix rather than by scanning to the first NUL: the
    // keyword we want has a known length, and a chunk keyed something else
    // is rejected without touching the rest of it, which for a crafted
    // 200 MB `iTXt` is the difference between one byte and a full pass.
    let key_end = PNG_XMP_KEYWORD.len();
    if !data.starts_with(PNG_XMP_KEYWORD) || *data.get(key_end)? != 0 {
        return None;
    }
    // A compressed packet reads as absent: inflating it would need a zlib
    // decoder this crate deliberately does not carry, and Adobe writes 0.
    if *data.get(key_end + 1)? != 0 {
        return None;
    }
    let after_method = key_end + 3;
    let rest = data.get(after_method..)?;
    let lang_end = rest.iter().position(|&b| b == 0)?;
    let rest = rest.get(lang_end + 1..)?;
    let translated_end = rest.iter().position(|&b| b == 0)?;
    rest.get(translated_end + 1..)
}

/// CRC-32 (the PNG polynomial), table-free — the ONE implementation, shared
/// by the walk's verification and the chunk builder's stamp.
pub(crate) fn crc32(bytes: &[u8]) -> u32 {
    let mut c: u32 = 0xFFFF_FFFF;
    for &b in bytes {
        c ^= u32::from(b);
        for _ in 0..8 {
            c = if c & 1 != 0 {
                0xEDB8_8320 ^ (c >> 1)
            } else {
                c >> 1
            };
        }
    }
    c ^ 0xFFFF_FFFF
}

// ------------------------------------------------------- the TIFF stream --

/// Tag numbers this crate looks at inside an EXIF block. Everything else is
/// opaque.
pub(crate) const TAG_IMAGE_WIDTH: u16 = 0x0100;
pub(crate) const TAG_IMAGE_LENGTH: u16 = 0x0101;
pub(crate) const TAG_ORIENTATION: u16 = 0x0112;
pub(crate) const TAG_X_RESOLUTION: u16 = 0x011A;
pub(crate) const TAG_Y_RESOLUTION: u16 = 0x011B;
pub(crate) const TAG_RESOLUTION_UNIT: u16 = 0x0128;
pub(crate) const TAG_EXIF_IFD: u16 = 0x8769;
pub(crate) const TAG_COLOR_SPACE: u16 = 0xA001;
pub(crate) const TAG_PIXEL_X_DIMENSION: u16 = 0xA002;
pub(crate) const TAG_PIXEL_Y_DIMENSION: u16 = 0xA003;

/// TIFF field types this crate can size. An unknown code makes an ENTRY
/// unreadable, never the block: the walk skips it rather than guessing a
/// width.
pub(crate) const TYPE_SHORT: u16 = 3;
pub(crate) const TYPE_LONG: u16 = 4;
pub(crate) const TYPE_RATIONAL: u16 = 5;

/// At most this many entries per IFD. A real IFD has tens; a thousand is
/// generous and bounds the work a crafted block can ask for.
pub(crate) const MAX_IFD_ENTRIES: usize = 1000;

/// One IFD entry, located rather than decoded: 2-byte tag, 2-byte type,
/// 4-byte count, then a 4-byte field that holds the value inline when
/// `count * type size <= 4` and an offset otherwise.
#[derive(Clone, Copy)]
pub(crate) struct Entry {
    pub tag: u16,
    pub kind: u16,
    pub count: u32,
    /// Offset OF the 4-byte value field, from the start of the TIFF stream.
    pub field: usize,
}

/// A bounds-checked view over an EXIF TIFF stream — the ONE reader, shared
/// by the resolution probe here and the export-time normalizer in
/// `metadata_write`. Every offset in the structure is measured from byte 0
/// of the 8-byte header, which is exactly why an EXIF block can be copied
/// between files intact.
pub(crate) struct Tiff<'a> {
    pub bytes: &'a [u8],
    pub big_endian: bool,
    /// Offset of IFD0.
    pub ifd0: usize,
}

impl<'a> Tiff<'a> {
    /// `None` unless the 8-byte header is well formed: `II` or `MM`, magic
    /// 42 in that order, and an IFD0 offset that is at least 8 and inside
    /// the block.
    pub(crate) fn new(bytes: &'a [u8]) -> Option<Tiff<'a>> {
        let order = bytes.get(0..2)?;
        let big_endian = match order {
            b"II" => false,
            b"MM" => true,
            _ => return None,
        };
        let t = Tiff {
            bytes,
            big_endian,
            ifd0: 0,
        };
        if t.u16_at(2)? != 42 {
            return None;
        }
        let ifd0 = t.u32_at(4)? as usize;
        if ifd0 < 8 || ifd0 >= bytes.len() {
            return None;
        }
        Some(Tiff { ifd0, ..t })
    }

    pub(crate) fn u16_at(&self, at: usize) -> Option<u16> {
        let s = self.bytes.get(at..at.checked_add(2)?)?;
        let v = [s[0], s[1]];
        Some(if self.big_endian {
            u16::from_be_bytes(v)
        } else {
            u16::from_le_bytes(v)
        })
    }

    pub(crate) fn u32_at(&self, at: usize) -> Option<u32> {
        let s = self.bytes.get(at..at.checked_add(4)?)?;
        let v = [s[0], s[1], s[2], s[3]];
        Some(if self.big_endian {
            u32::from_be_bytes(v)
        } else {
            u32::from_le_bytes(v)
        })
    }

    /// `value` encoded in this stream's byte order.
    pub(crate) fn u16_bytes(&self, value: u16) -> [u8; 2] {
        if self.big_endian {
            value.to_be_bytes()
        } else {
            value.to_le_bytes()
        }
    }

    /// `value` encoded in this stream's byte order.
    pub(crate) fn u32_bytes(&self, value: u32) -> [u8; 4] {
        if self.big_endian {
            value.to_be_bytes()
        } else {
            value.to_le_bytes()
        }
    }

    /// The entries of the IFD at `at`, plus the offset of its next-IFD link.
    /// `None` when the count or the extent runs past the block, or the count
    /// is past [`MAX_IFD_ENTRIES`].
    pub(crate) fn ifd(&self, at: usize) -> Option<(Vec<Entry>, usize)> {
        let count = usize::from(self.u16_at(at)?);
        if count > MAX_IFD_ENTRIES {
            return None;
        }
        let link = at.checked_add(2)?.checked_add(count.checked_mul(12)?)?;
        // The link's own four bytes must be inside the block too.
        if link.checked_add(4)? > self.bytes.len() {
            return None;
        }
        let mut entries = Vec::with_capacity(count);
        for i in 0..count {
            let e = at + 2 + 12 * i;
            let entry = Entry {
                tag: self.u16_at(e)?,
                kind: self.u16_at(e + 2)?,
                count: self.u32_at(e + 4)?,
                field: e + 8,
            };
            // An entry whose out-of-line datum leaves the block is corrupt.
            self.data_range(&entry)?;
            entries.push(entry);
        }
        Some((entries, link))
    }

    /// Where the entry's DATA lives: the 4-byte field itself when it fits,
    /// the offset it holds otherwise. `None` for an unreadable extent —
    /// which includes an unknown type code, whose width we refuse to guess.
    pub(crate) fn data_range(&self, e: &Entry) -> Option<std::ops::Range<usize>> {
        let Some(unit) = type_size(e.kind) else {
            // An unknown type is skipped, not fatal: the entry stays opaque.
            return Some(e.field..e.field + 4);
        };
        let total = usize::try_from(e.count).ok()?.checked_mul(unit)?;
        if total <= 4 {
            return Some(e.field..e.field + 4);
        }
        let at = self.u32_at(e.field)? as usize;
        let end = at.checked_add(total)?;
        if end > self.bytes.len() {
            return None;
        }
        Some(at..end)
    }

    /// The entry's first value as an unsigned integer, for the inline
    /// SHORT/LONG cases this crate reads.
    pub(crate) fn scalar(&self, e: &Entry) -> Option<u32> {
        match e.kind {
            TYPE_SHORT => Some(u32::from(self.u16_at(e.field)?)),
            TYPE_LONG => Some(self.u32_at(e.field)?),
            _ => None,
        }
    }

    /// The entry's first RATIONAL as an f64; `None` for any other shape or a
    /// zero denominator.
    pub(crate) fn rational(&self, e: &Entry) -> Option<f64> {
        if e.kind != TYPE_RATIONAL || e.count == 0 {
            return None;
        }
        let at = self.u32_at(e.field)? as usize;
        let num = f64::from(self.u32_at(at)?);
        let den = f64::from(self.u32_at(at.checked_add(4)?)?);
        if den == 0.0 {
            None
        } else {
            Some(num / den)
        }
    }
}

/// The width of one value of a TIFF field type; `None` for a code this
/// crate does not know.
pub(crate) fn type_size(kind: u16) -> Option<usize> {
    match kind {
        1 | 2 | 6 | 7 => Some(1),
        3 | 8 => Some(2),
        4 | 9 | 11 => Some(4),
        5 | 10 | 12 => Some(8),
        _ => None,
    }
}

/// The ppi an EXIF block states through XResolution / YResolution /
/// ResolutionUnit, when the container itself said nothing. Unit 2 is inches
/// and unit 3 centimetres; unit 1 ("none") is a bare aspect ratio and is
/// skipped, as is a malformed block.
pub(crate) fn resolution_from_exif(blob: &[u8]) -> Option<Resolution> {
    let t = Tiff::new(blob)?;
    let (entries, _) = t.ifd(t.ifd0)?;
    let find = |tag: u16| entries.iter().find(|e| e.tag == tag);
    let x = t.rational(find(TAG_X_RESOLUTION)?)?;
    let y = t.rational(find(TAG_Y_RESOLUTION)?)?;
    let unit = find(TAG_RESOLUTION_UNIT)
        .and_then(|e| t.scalar(e))
        .unwrap_or(2);
    let scale = match unit {
        2 => 1.0,
        3 => 2.54,
        _ => return None,
    };
    if x <= 0.0 || y <= 0.0 {
        return None;
    }
    Some(Resolution {
        x: (x * scale) as f32,
        y: (y * scale) as f32,
    })
}
