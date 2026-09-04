//! EXIF / XMP / IPTC preservation, the print resolution, and the
//! document-level save that splices them back — exercised through the public
//! C FFI (`rz_doc_metadata*`, `rz_doc_*resolution*`, `rz_format_carries`,
//! `rz_doc_save_image`).
//!
//! Oracles are written HERE and are byte-stream parsers, not the core's:
//! this file assembles its own EXIF TIFF blocks, its own 8BIM runs and its
//! own JPEG segments, and it walks every exported file with its own marker
//! and chunk walkers (including an independently written CRC-32 for PNG).
//! No repo sample carries a profile, XMP, IPTC or a `pHYs` chunk — every
//! fixture below is built from bytes this file writes. No golden images
//! anywhere.

use std::ffi::{c_char, c_int};
use std::path::Path;
use std::ptr;

use image::{ExtendedColorType, ImageEncoder, RgbaImage};
use rasterize_core::doc::RzDocument;
use rasterize_core::ffi::*;
use rasterize_core::ffi_color::*;
use rasterize_core::ffi_doc::*;
use tempfile::TempDir;

mod common;
use common::*;

/// Mirrored from the header, like the BLEND_* constants in `tests/common`.
const FORMAT_PNG: c_int = 0;
const FORMAT_JPEG: c_int = 1;
const FORMAT_TIFF: c_int = 2;
const FORMAT_BMP: c_int = 3;
const FORMAT_GIF: c_int = 4;
const FORMAT_WEBP: c_int = 5;
const METADATA_EXIF: c_int = 0;
const METADATA_XMP: c_int = 1;
const METADATA_IPTC: c_int = 2;
const CARRIES_PROFILE: u32 = 1;
const CARRIES_EXIF: u32 = 2;
const CARRIES_XMP: u32 = 4;
const CARRIES_IPTC: u32 = 8;
const CARRIES_RESOLUTION: u32 = 16;

// ------------------------------------------------- byte-stream oracles --

/// Every JPEG marker segment as (marker, payload), stopping at SOS — an
/// independent walker, deliberately not the core's.
fn jpeg_segments(bytes: &[u8]) -> Vec<(u8, Vec<u8>)> {
    assert_eq!(&bytes[..2], &[0xFF, 0xD8], "SOI");
    let mut out = Vec::new();
    let mut i = 2usize;
    while i + 4 <= bytes.len() {
        assert_eq!(bytes[i], 0xFF, "a marker at {i}");
        let marker = bytes[i + 1];
        if marker == 0xDA || marker == 0xD9 {
            out.push((marker, Vec::new()));
            break;
        }
        let len = usize::from(u16::from_be_bytes([bytes[i + 2], bytes[i + 3]]));
        out.push((marker, bytes[i + 4..i + 2 + len].to_vec()));
        i += 2 + len;
    }
    out
}

/// The payload of the first segment with `marker` whose payload starts with
/// `id`, minus that identifier.
fn jpeg_payload(bytes: &[u8], marker: u8, id: &[u8]) -> Option<Vec<u8>> {
    jpeg_segments(bytes)
        .into_iter()
        .find(|(m, p)| *m == marker && p.starts_with(id))
        .map(|(_, p)| p[id.len()..].to_vec())
}

/// CRC-32 with the PNG polynomial, written out here so the walk below
/// verifies chunks against an oracle rather than against the core's copy.
fn crc32(bytes: &[u8]) -> u32 {
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

/// Every PNG chunk as (type, data), with every CRC verified.
fn png_chunks(bytes: &[u8]) -> Vec<([u8; 4], Vec<u8>)> {
    assert_eq!(
        &bytes[..8],
        &[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    );
    let mut out = Vec::new();
    let mut i = 8usize;
    while i + 12 <= bytes.len() {
        let len = u32::from_be_bytes(bytes[i..i + 4].try_into().unwrap()) as usize;
        let kind: [u8; 4] = bytes[i + 4..i + 8].try_into().unwrap();
        let data = bytes[i + 8..i + 8 + len].to_vec();
        let stored = u32::from_be_bytes(bytes[i + 8 + len..i + 12 + len].try_into().unwrap());
        assert_eq!(
            crc32(&bytes[i + 4..i + 8 + len]),
            stored,
            "CRC of {:?}",
            std::str::from_utf8(&kind)
        );
        out.push((kind, data));
        i += 12 + len;
        if &kind == b"IEND" {
            break;
        }
    }
    out
}

fn png_chunk(bytes: &[u8], kind: &[u8; 4]) -> Option<Vec<u8>> {
    png_chunks(bytes)
        .into_iter()
        .find(|(k, _)| k == kind)
        .map(|(_, d)| d)
}

// -------------------------------------------------- fixture assemblers --

/// What an assembled EXIF block contains and where its patchable fields
/// live, so a test can assert that NOTHING ELSE moved.
struct Exif {
    bytes: Vec<u8>,
    /// Offset of the Orientation entry's 4-byte value field.
    orientation_field: usize,
    /// Offset of IFD0's next-IFD link.
    link: usize,
    /// Offset of the two resolution RATIONALs (16 bytes).
    rationals: usize,
    /// Offset of the Exif sub-IFD's ColorSpace value field, when the block
    /// has a sub-IFD at all.
    color_space_field: Option<usize>,
}

/// Assembles an EXIF TIFF stream by hand — the layout the ICC/metadata map
/// verified against `samples/portrait-exif6.jpg`, generalized.
fn build_exif(
    big_endian: bool,
    orientation: u16,
    resolution: (u32, u32),
    dimensions: Option<(u32, u32)>,
    thumbnail: bool,
) -> Exif {
    let u16b = |v: u16| {
        if big_endian {
            v.to_be_bytes()
        } else {
            v.to_le_bytes()
        }
    };
    let u32b = |v: u32| {
        if big_endian {
            v.to_be_bytes()
        } else {
            v.to_le_bytes()
        }
    };
    // Entry count and the layout that follows IFD0.
    let mut count = 4u16; // orientation, x res, y res, unit
    if dimensions.is_some() {
        count += 3; // width, length, Exif sub-IFD pointer
    }
    let ifd0 = 8usize;
    let link = ifd0 + 2 + 12 * usize::from(count);
    let mut cursor = link + 4;
    let rationals = cursor;
    cursor += 16;
    let sub_ifd = cursor;
    if dimensions.is_some() {
        // ColorSpace, PixelXDimension, PixelYDimension.
        cursor += 2 + 36 + 4;
    }
    let ifd1 = cursor;
    let thumb = ifd1 + 2 + 24 + 4;
    let end = if thumbnail { thumb + 8 } else { cursor };

    let mut b = vec![0u8; end];
    b[0..2].copy_from_slice(if big_endian { b"MM" } else { b"II" });
    b[2..4].copy_from_slice(&u16b(42));
    b[4..8].copy_from_slice(&u32b(ifd0 as u32));
    b[ifd0..ifd0 + 2].copy_from_slice(&u16b(count));

    let mut at = ifd0 + 2;
    let put = |b: &mut Vec<u8>, at: &mut usize, tag: u16, kind: u16, value: [u8; 4]| {
        b[*at..*at + 2].copy_from_slice(&u16b(tag));
        b[*at + 2..*at + 4].copy_from_slice(&u16b(kind));
        b[*at + 4..*at + 8].copy_from_slice(&u32b(1));
        b[*at + 8..*at + 12].copy_from_slice(&value);
        let field = *at + 8;
        *at += 12;
        field
    };
    // Entries must be sorted ascending by tag.
    if let Some((w, _)) = dimensions {
        put(&mut b, &mut at, 0x0100, 4, u32b(w));
    }
    if let Some((_, h)) = dimensions {
        put(&mut b, &mut at, 0x0101, 4, u32b(h));
    }
    // A SHORT's value is left-justified in the 4-byte field.
    let orientation_field = {
        let mut v = [0u8; 4];
        v[0..2].copy_from_slice(&u16b(orientation));
        put(&mut b, &mut at, 0x0112, 3, v)
    };
    put(&mut b, &mut at, 0x011A, 5, u32b(rationals as u32));
    put(&mut b, &mut at, 0x011B, 5, u32b((rationals + 8) as u32));
    {
        let mut v = [0u8; 4];
        v[0..2].copy_from_slice(&u16b(2)); // inch
        put(&mut b, &mut at, 0x0128, 3, v);
    }
    if dimensions.is_some() {
        put(&mut b, &mut at, 0x8769, 4, u32b(sub_ifd as u32));
    }
    b[link..link + 4].copy_from_slice(&u32b(if thumbnail { ifd1 as u32 } else { 0 }));

    b[rationals..rationals + 4].copy_from_slice(&u32b(resolution.0));
    b[rationals + 4..rationals + 8].copy_from_slice(&u32b(1));
    b[rationals + 8..rationals + 12].copy_from_slice(&u32b(resolution.1));
    b[rationals + 12..rationals + 16].copy_from_slice(&u32b(1));

    let mut color_space_field = None;
    if let Some((w, h)) = dimensions {
        b[sub_ifd..sub_ifd + 2].copy_from_slice(&u16b(3));
        let mut at = sub_ifd + 2;
        // ColorSpace 1 = sRGB, an inline SHORT of count 1 — what every
        // camera and phone writes.
        color_space_field = Some({
            let mut v = [0u8; 4];
            v[0..2].copy_from_slice(&u16b(1));
            put(&mut b, &mut at, 0xA001, 3, v)
        });
        put(&mut b, &mut at, 0xA002, 4, u32b(w));
        put(&mut b, &mut at, 0xA003, 4, u32b(h));
        b[at..at + 4].copy_from_slice(&u32b(0));
    }
    if thumbnail {
        b[ifd1..ifd1 + 2].copy_from_slice(&u16b(2));
        let mut at = ifd1 + 2;
        put(&mut b, &mut at, 0x0201, 4, u32b(thumb as u32));
        put(&mut b, &mut at, 0x0202, 4, u32b(8));
        b[at..at + 4].copy_from_slice(&u32b(0));
        b[thumb..thumb + 8].copy_from_slice(b"THUMBJPG");
    }
    Exif {
        bytes: b,
        orientation_field,
        link,
        rationals,
        color_space_field,
    }
}

/// The offset of IFD0's 12-byte entry for `tag`, in a little-endian block
/// this file assembled. The tests below use it to give a tag a SHAPE
/// [`build_exif`] does not produce — a LONG resolution unit, two axes
/// pointing at one rational — which is exactly where the writer's
/// all-or-nothing rule has to hold.
fn ifd0_entry(bytes: &[u8], tag: u16) -> usize {
    let u16_at = |a: usize| u16::from_le_bytes([bytes[a], bytes[a + 1]]);
    let ifd = u32::from_le_bytes(bytes[4..8].try_into().unwrap()) as usize;
    (0..usize::from(u16_at(ifd)))
        .map(|i| ifd + 2 + 12 * i)
        .find(|&e| u16_at(e) == tag)
        .expect("the tag is in the block this file built")
}

/// The inline scalar value of IFD0's `tag` — the shape a SHORT or LONG of
/// count 1 has, where the value sits IN the entry rather than at an offset
/// (which is what [`tiff_tag`] would read).
fn ifd0_inline(bytes: &[u8], tag: u16) -> u32 {
    let e = ifd0_entry(bytes, tag);
    match u16::from_le_bytes([bytes[e + 2], bytes[e + 3]]) {
        3 => u32::from(u16::from_le_bytes([bytes[e + 8], bytes[e + 9]])),
        _ => u32::from_le_bytes(bytes[e + 8..e + 12].try_into().unwrap()),
    }
}

/// The two LONGs of the RATIONAL at `at`, little-endian.
fn rational_at(bytes: &[u8], at: usize) -> (u32, u32) {
    let u32_at = |a: usize| u32::from_le_bytes(bytes[a..a + 4].try_into().unwrap());
    (u32_at(at), u32_at(at + 4))
}

/// One 8BIM image-resource block, with the padding rules the format's own
/// layout demands.
fn bim(id: u16, name: &[u8], data: &[u8]) -> Vec<u8> {
    let mut b = b"8BIM".to_vec();
    b.extend_from_slice(&id.to_be_bytes());
    b.push(name.len() as u8);
    b.extend_from_slice(name);
    // The WHOLE name field, length byte included, is padded to even.
    if !(1 + name.len()).is_multiple_of(2) {
        b.push(0);
    }
    b.extend_from_slice(&(data.len() as u32).to_be_bytes());
    b.extend_from_slice(data);
    if !data.len().is_multiple_of(2) {
        b.push(0);
    }
    b
}

fn jpeg_segment(marker: u8, id: &[u8], payload: &[u8]) -> Vec<u8> {
    let mut s = vec![0xFF, marker];
    s.extend_from_slice(&((id.len() + payload.len() + 2) as u16).to_be_bytes());
    s.extend_from_slice(id);
    s.extend_from_slice(payload);
    s
}

/// A real encoded JPEG with `segments` inserted after the leading APPn run,
/// which is where a writer would put them.
fn jpeg_with(pixels: &RgbaImage, quality: u8, segments: &[Vec<u8>]) -> Vec<u8> {
    let mut base = Vec::new();
    let rgb = image::DynamicImage::ImageRgba8(pixels.clone()).to_rgb8();
    image::codecs::jpeg::JpegEncoder::new_with_quality(&mut base, quality)
        .write_image(
            rgb.as_raw(),
            pixels.width(),
            pixels.height(),
            ExtendedColorType::Rgb8,
        )
        .unwrap();
    let mut i = 2usize;
    loop {
        let marker = base[i + 1];
        if !((0xE0..=0xEF).contains(&marker) || marker == 0xFE) {
            break;
        }
        i += 2 + usize::from(u16::from_be_bytes([base[i + 2], base[i + 3]]));
    }
    let mut out = base[..i].to_vec();
    for s in segments {
        out.extend_from_slice(s);
    }
    out.extend_from_slice(&base[i..]);
    out
}

/// A real encoded PNG with `chunks` inserted straight after `IHDR`.
fn png_with(pixels: &RgbaImage, chunks: &[Vec<u8>]) -> Vec<u8> {
    let mut base = Vec::new();
    image::codecs::png::PngEncoder::new(&mut base)
        .write_image(
            pixels.as_raw(),
            pixels.width(),
            pixels.height(),
            ExtendedColorType::Rgba8,
        )
        .unwrap();
    let ihdr_end = 8 + 8 + 13 + 4;
    let mut out = base[..ihdr_end].to_vec();
    for c in chunks {
        out.extend_from_slice(c);
    }
    out.extend_from_slice(&base[ihdr_end..]);
    out
}

fn png_chunk_bytes(kind: &[u8; 4], data: &[u8]) -> Vec<u8> {
    let mut c = (data.len() as u32).to_be_bytes().to_vec();
    c.extend_from_slice(kind);
    c.extend_from_slice(data);
    let crc = crc32(&c[4..]);
    c.extend_from_slice(&crc.to_be_bytes());
    c
}

// ---------------------------------------------------------- FFI helpers --

fn open_file(dir: &TempDir, name: &str, bytes: &[u8]) -> *mut RzDocument {
    let path = dir.path().join(name);
    std::fs::write(&path, bytes).unwrap();
    let c = cpath(&path);
    let mut err: *mut c_char = ptr::null_mut();
    let doc = unsafe { rz_doc_open(c.as_ptr(), &mut err) };
    assert!(!doc.is_null(), "open {name}: {}", take_err_string(err));
    doc
}

fn packet(doc: *const RzDocument, kind: c_int) -> Option<Vec<u8>> {
    let len = unsafe { rz_doc_metadata_len(doc, kind) };
    if len == 0 {
        return None;
    }
    let mut out = vec![0u8; len];
    assert!(unsafe { rz_doc_metadata(doc, kind, out.as_mut_ptr(), len) });
    Some(out)
}

/// One packet as text, for the XMP tests.
fn packet_str(doc: *const RzDocument, kind: c_int) -> String {
    String::from_utf8(packet(doc, kind).expect("a packet")).expect("UTF-8")
}

/// The XMP packet a saved file carries: the JPEG APP1 payload after the XMP
/// identifier, or the PNG `iTXt` text after its keyword, compression flag,
/// method, language and translated keyword (all empty, as the writer emits
/// them).
fn written_xmp(bytes: &[u8], format: c_int) -> Vec<u8> {
    if format == FORMAT_JPEG {
        return jpeg_payload(bytes, 0xE1, XMP_ID).expect("an XMP APP1");
    }
    let chunk = png_chunk(bytes, b"iTXt").expect("an iTXt chunk");
    let keyword = b"XML:com.adobe.xmp";
    assert!(chunk.starts_with(keyword));
    chunk[keyword.len() + 5..].to_vec()
}

/// Sets a packet, FREEING the input — for linear chains.
fn set_packet(doc: *mut RzDocument, kind: c_int, bytes: &[u8]) -> *mut RzDocument {
    apply(doc, |d| unsafe {
        rz_doc_set_metadata(d, kind, bytes.as_ptr(), bytes.len())
    })
}

/// Sets a packet, KEEPING the input alive — for branching off one document.
fn with_packet(doc: *const RzDocument, kind: c_int, bytes: &[u8]) -> *mut RzDocument {
    let out = unsafe { rz_doc_set_metadata(doc, kind, bytes.as_ptr(), bytes.len()) };
    assert!(!out.is_null());
    out
}

/// Saves and returns (the file's bytes, the carried bits).
fn save(
    doc: *const RzDocument,
    path: &Path,
    format: c_int,
    embed_profile: bool,
    strip_metadata: bool,
) -> (Vec<u8>, u32) {
    let c = cpath(path);
    let mut err: *mut c_char = ptr::null_mut();
    let mut carried: u32 = 0;
    assert!(
        unsafe {
            rz_doc_save_image(
                doc,
                ptr::null(),
                c.as_ptr(),
                format,
                92,
                embed_profile,
                strip_metadata,
                &mut carried,
                &mut err,
            )
        },
        "save: {}",
        take_err_string(err)
    );
    (std::fs::read(path).unwrap(), carried)
}

fn builtin_bytes(which: c_int) -> Vec<u8> {
    let len = rz_builtin_profile_len(which);
    let mut out = vec![0u8; len];
    assert!(unsafe { rz_builtin_profile(which, out.as_mut_ptr(), len) });
    out
}

const XMP_ID: &[u8] = b"http://ns.adobe.com/xap/1.0/\0";
const IPTC_ID: &[u8] = b"Photoshop 3.0\0";
const SAMPLE_XMP: &[u8] =
    b"<?xpacket begin=''?><x:xmpmeta xmlns:x='adobe:ns:meta/'/><?xpacket end='w'?>";

// ------------------------------------------------------------- the tests --

#[test]
fn a_jpeg_app1_we_build_ourselves_reads_back() {
    let dir = TempDir::new().unwrap();
    let exif = build_exif(false, 1, (300, 300), Some((8, 6)), false);
    let iptc = bim(0x0404, b"", b"\x1c\x02\x00\x00\x02\x00\x04");
    let file = jpeg_with(
        &opaque_pattern(8, 6),
        92,
        &[
            jpeg_segment(0xE1, b"Exif\0\0", &exif.bytes),
            jpeg_segment(0xE1, XMP_ID, SAMPLE_XMP),
            jpeg_segment(0xED, IPTC_ID, &iptc),
        ],
    );
    let doc = open_file(&dir, "meta.jpg", &file);

    assert_eq!(
        packet(doc, METADATA_EXIF).as_deref(),
        Some(exif.bytes.as_slice()),
        "the EXIF packet is the raw TIFF stream, with no Exif\\0\\0 prefix"
    );
    assert_eq!(packet(doc, METADATA_XMP).as_deref(), Some(SAMPLE_XMP));
    assert_eq!(packet(doc, METADATA_IPTC).as_deref(), Some(iptc.as_slice()));
    assert_eq!(unsafe { rz_doc_resolution_x(doc) }, 300.0);
    assert_eq!(unsafe { rz_doc_resolution_y(doc) }, 300.0);
    unsafe { rz_doc_free(doc) };
}

#[test]
fn the_8bim_run_is_filtered_on_export() {
    let dir = TempDir::new().unwrap();
    // Two harmless resources — one with an odd-length Pascal name and an
    // odd-length payload, so both padding rules are exercised — and the four
    // that must go.
    let keep_a = bim(0x0404, b"cap", b"\x1c\x02\x78\x00\x03abc");
    let keep_b = bim(0x0425, b"", b"\x01\x02\x03");
    let run: Vec<u8> = [
        bim(0x03ED, b"", &[0u8; 16]),
        keep_a.clone(),
        bim(0x040F, b"", &[1u8; 8]),
        keep_b.clone(),
        bim(0x0422, b"", &[2u8; 4]),
        bim(0x0424, b"", &[3u8; 4]),
    ]
    .concat();

    let doc = doc_from(&dir, "b.png", &opaque_pattern(4, 4));
    let doc = set_packet(doc, METADATA_IPTC, &run);
    let (bytes, carried) = save(
        doc,
        &dir.path().join("filtered.jpg"),
        FORMAT_JPEG,
        true,
        false,
    );
    assert!(carried & CARRIES_IPTC != 0);
    let out = jpeg_payload(&bytes, 0xED, IPTC_ID).expect("an APP13");
    assert_eq!(
        out,
        [keep_a, keep_b].concat(),
        "the four contradicting resources are gone and the rest is byte-exact"
    );

    // A run of only droppable resources produces no APP13 at all.
    let only_dropped = [bim(0x03ED, b"", &[0u8; 16]), bim(0x0424, b"", &[3u8; 4])].concat();
    let doc2 = with_packet(doc, METADATA_IPTC, &only_dropped);
    let (bytes2, carried2) = save(
        doc2,
        &dir.path().join("empty.jpg"),
        FORMAT_JPEG,
        true,
        false,
    );
    assert_eq!(carried2 & CARRIES_IPTC, 0, "the IPTC bit is clear");
    assert!(jpeg_payload(&bytes2, 0xED, IPTC_ID).is_none());

    // A malformed run is dropped, not written.
    let doc3 = with_packet(doc, METADATA_IPTC, b"8BIM\x04\x04\x00\x00\xff\xff\xff\xff");
    let (bytes3, carried3) = save(doc3, &dir.path().join("bad.jpg"), FORMAT_JPEG, true, false);
    assert_eq!(carried3 & CARRIES_IPTC, 0);
    assert!(jpeg_payload(&bytes3, 0xED, IPTC_ID).is_none());

    unsafe {
        rz_doc_free(doc3);
        rz_doc_free(doc2);
        rz_doc_free(doc);
    }
}

#[test]
fn png_phys_round_trips() {
    let dir = TempDir::new().unwrap();
    let doc = doc_from(&dir, "p.png", &opaque_pattern(5, 4));
    for (ppi, expected) in [(300.0f32, 11811u32), (72.0, 2835)] {
        let doc = if ppi == 72.0 {
            unsafe { rz_doc_clone(doc) }
        } else {
            let out = unsafe { rz_doc_set_resolution(doc, ppi, ppi) };
            assert!(!out.is_null());
            out
        };
        let path = dir.path().join(format!("{ppi}.png"));
        let (bytes, carried) = save(doc, &path, FORMAT_PNG, true, false);
        assert!(carried & CARRIES_RESOLUTION != 0);
        let phys = png_chunk(&bytes, b"pHYs").expect("a pHYs chunk");
        assert_eq!(
            phys,
            [
                expected.to_be_bytes().as_slice(),
                expected.to_be_bytes().as_slice(),
                &[1]
            ]
            .concat(),
            "{ppi} ppi is {expected} pixels per metre, unit 1"
        );
        let back = open_file(&dir, &format!("back-{ppi}.png"), &bytes);
        assert_eq!(unsafe { rz_doc_resolution_x(back) }, ppi);
        assert_eq!(unsafe { rz_doc_resolution_y(back) }, ppi);
        unsafe {
            rz_doc_free(back);
            rz_doc_free(doc);
        }
    }
    unsafe { rz_doc_free(doc) };
}

#[test]
fn an_orientation_6_file_exports_as_orientation_1() {
    for big_endian in [false, true] {
        let dir = TempDir::new().unwrap();
        // No dimension tags here, so the ONLY bytes allowed to move are the
        // orientation value, the IFD0 link and the two resolution rationals.
        let exif = build_exif(big_endian, 6, (72, 72), None, true);
        let file = jpeg_with(
            &opaque_pattern(8, 6),
            95,
            &[jpeg_segment(0xE1, b"Exif\0\0", &exif.bytes)],
        );
        let doc = open_file(&dir, "rotated.jpg", &file);
        // The camera rotation is baked into the pixels at open time.
        assert_eq!(
            unsafe { (rz_doc_width(doc), rz_doc_height(doc)) },
            (6, 8),
            "orientation 6 is a quarter turn"
        );
        let (bytes, carried) = save(doc, &dir.path().join("out.jpg"), FORMAT_JPEG, true, false);
        assert!(carried & CARRIES_EXIF != 0);
        let out = jpeg_payload(&bytes, 0xE1, b"Exif\0\0").expect("an Exif APP1");
        assert_eq!(out.len(), exif.bytes.len(), "the block did not grow");

        let u16_at = |b: &[u8], at: usize| {
            let v = [b[at], b[at + 1]];
            if big_endian {
                u16::from_be_bytes(v)
            } else {
                u16::from_le_bytes(v)
            }
        };
        let u32_at = |b: &[u8], at: usize| {
            let v: [u8; 4] = b[at..at + 4].try_into().unwrap();
            if big_endian {
                u32::from_be_bytes(v)
            } else {
                u32::from_le_bytes(v)
            }
        };
        assert_eq!(
            u16_at(&out, exif.orientation_field),
            1,
            "the orientation is neutralized"
        );
        assert_eq!(u32_at(&out, exif.link), 0, "IFD1 is unlinked");
        assert_eq!(
            (
                u32_at(&out, exif.rationals),
                u32_at(&out, exif.rationals + 4)
            ),
            (72, 1),
            "the resolution follows the document"
        );
        // Nothing else moved — the thumbnail's own bytes are still there.
        for (i, byte) in out.iter().enumerate() {
            let patched = (i >= exif.orientation_field && i < exif.orientation_field + 2)
                || (i >= exif.link && i < exif.link + 4)
                || (i >= exif.rationals && i < exif.rationals + 16);
            if !patched {
                assert_eq!(*byte, exif.bytes[i], "byte {i} moved");
            }
        }
        unsafe { rz_doc_free(doc) };
    }
}

#[test]
fn exported_resolution_tags_follow_the_document() {
    let dir = TempDir::new().unwrap();
    let exif = build_exif(false, 1, (72, 72), Some((8, 6)), false);
    let file = jpeg_with(
        &opaque_pattern(8, 6),
        92,
        &[jpeg_segment(0xE1, b"Exif\0\0", &exif.bytes)],
    );
    let doc = open_file(&dir, "res.jpg", &file);
    let doc = apply(doc, |d| unsafe { rz_doc_set_resolution(d, 300.0, 150.0) });
    let (bytes, _) = save(
        doc,
        &dir.path().join("res-out.jpg"),
        FORMAT_JPEG,
        true,
        false,
    );

    // JFIF: units 1 (inches), per axis.
    let jfif = jpeg_payload(&bytes, 0xE0, b"JFIF\0").expect("an APP0");
    assert_eq!(jfif[2], 1, "units 1 = dots per inch");
    assert_eq!(u16::from_be_bytes([jfif[3], jfif[4]]), 300, "Xdensity");
    assert_eq!(u16::from_be_bytes([jfif[5], jfif[6]]), 150, "Ydensity");

    // And the EXIF tags say the same thing.
    let out = jpeg_payload(&bytes, 0xE1, b"Exif\0\0").expect("an Exif APP1");
    let u32_at = |at: usize| u32::from_le_bytes(out[at..at + 4].try_into().unwrap());
    assert_eq!(
        (u32_at(exif.rationals), u32_at(exif.rationals + 4)),
        (300, 1)
    );
    assert_eq!(
        (u32_at(exif.rationals + 8), u32_at(exif.rationals + 12)),
        (150, 1)
    );
    // Reopening the export agrees.
    let back = open_file(&dir, "back.jpg", &bytes);
    assert_eq!(
        unsafe { (rz_doc_resolution_x(back), rz_doc_resolution_y(back)) },
        (300.0, 150.0)
    );
    unsafe {
        rz_doc_free(back);
        rz_doc_free(doc);
    }
}

#[test]
fn container_density_of_one_by_one_is_ignored() {
    let dir = TempDir::new().unwrap();
    let exif = build_exif(false, 1, (300, 300), None, false);
    // A JPEG whose JFIF claims units 1 at 1 x 1 while its EXIF says 300.
    let mut file = jpeg_with(
        &opaque_pattern(6, 4),
        92,
        &[jpeg_segment(0xE1, b"Exif\0\0", &exif.bytes)],
    );
    let app0 = file
        .windows(5)
        .position(|w| w == b"JFIF\0")
        .expect("a JFIF APP0");
    file[app0 + 7] = 1; // units -> dots per inch, density still 1 x 1
    let doc = open_file(&dir, "one.jpg", &file);
    assert_eq!(
        unsafe { rz_doc_resolution_x(doc) },
        300.0,
        "a 1 x 1 container density means \"not stated\""
    );

    // A PNG whose pHYs says 1 x 1 per metre while its eXIf says 300.
    let phys = png_chunk_bytes(b"pHYs", &[0, 0, 0, 1, 0, 0, 0, 1, 1]);
    let exif_chunk = png_chunk_bytes(b"eXIf", &exif.bytes);
    let png = png_with(&opaque_pattern(6, 4), &[phys, exif_chunk]);
    let doc2 = open_file(&dir, "one.png", &png);
    assert_eq!(unsafe { rz_doc_resolution_x(doc2) }, 300.0);

    // Units 2 is dots per CENTIMETRE: 118 dots/cm is about 300 ppi.
    let mut file3 = jpeg_with(&opaque_pattern(6, 4), 92, &[]);
    let app0 = file3
        .windows(5)
        .position(|w| w == b"JFIF\0")
        .expect("a JFIF APP0");
    file3[app0 + 7] = 2;
    file3[app0 + 8..app0 + 10].copy_from_slice(&118u16.to_be_bytes());
    file3[app0 + 10..app0 + 12].copy_from_slice(&118u16.to_be_bytes());
    let doc3 = open_file(&dir, "cm.jpg", &file3);
    let ppi = unsafe { rz_doc_resolution_x(doc3) };
    assert!(
        (ppi - 299.72).abs() < 0.01,
        "118 dots/cm is {ppi} ppi, expected about 299.72"
    );

    unsafe {
        rz_doc_free(doc3);
        rz_doc_free(doc2);
        rz_doc_free(doc);
    }
}

#[test]
fn a_malformed_exif_packet_is_dropped_not_written() {
    let dir = TempDir::new().unwrap();
    let doc = doc_from(&dir, "m.png", &opaque_pattern(4, 4));
    let good = build_exif(false, 1, (72, 72), None, true);

    let mut cases: Vec<(&str, Vec<u8>)> = Vec::new();
    let mut order = good.bytes.clone();
    order[0..2].copy_from_slice(b"XX");
    cases.push(("bad order bytes", order));
    let mut magic = good.bytes.clone();
    magic[2..4].copy_from_slice(&43u16.to_le_bytes());
    cases.push(("magic is not 42", magic));
    let mut far = good.bytes.clone();
    far[4..8].copy_from_slice(&9999u32.to_le_bytes());
    cases.push(("IFD0 past the block", far));
    let mut many = good.bytes.clone();
    many[8..10].copy_from_slice(&999u16.to_le_bytes());
    cases.push(("entry count past the block", many));
    let mut inside = good.bytes.clone();
    // Point XResolution's out-of-line datum into the TIFF header.
    let x_res_field = good.orientation_field + 12;
    inside[x_res_field..x_res_field + 4].copy_from_slice(&99999u32.to_le_bytes());
    cases.push(("an out-of-line offset past the block", inside));
    // An orientation entry this crate cannot patch IN PLACE refuses the
    // whole packet: writing a stale rotation back out is the one failure
    // the normalizer exists to prevent.
    let mut wide = good.bytes.clone();
    let kind_at = good.orientation_field - 6;
    wide[kind_at..kind_at + 2].copy_from_slice(&5u16.to_le_bytes()); // RATIONAL
    cases.push(("an orientation that is not an inline scalar", wide));

    for (label, blob) in cases {
        let doc = with_packet(doc, METADATA_EXIF, &blob);
        let (bytes, carried) = save(
            doc,
            &dir.path().join("bad-exif.jpg"),
            FORMAT_JPEG,
            true,
            false,
        );
        assert_eq!(carried & CARRIES_EXIF, 0, "{label}: the bit must be clear");
        assert!(
            jpeg_payload(&bytes, 0xE1, b"Exif\0\0").is_none(),
            "{label}: nothing is written"
        );
        unsafe { rz_doc_free(doc) };
    }
    unsafe { rz_doc_free(doc) };
}

#[test]
fn jpeg_segments_are_written_in_the_documented_order() {
    let dir = TempDir::new().unwrap();
    let doc = doc_from(&dir, "o.png", &opaque_pattern(6, 4));
    let exif = build_exif(false, 1, (72, 72), None, false);
    let doc = set_packet(doc, METADATA_EXIF, &exif.bytes);
    let doc = set_packet(doc, METADATA_XMP, SAMPLE_XMP);
    let doc = set_packet(
        doc,
        METADATA_IPTC,
        &bim(0x0404, b"", b"\x1c\x02\x00\x00\x02\x00\x04"),
    );
    let p3 = builtin_bytes(1);
    let doc = apply(doc, |d| unsafe {
        rz_doc_assign_profile(d, p3.as_ptr(), p3.len())
    });

    let (bytes, carried) = save(doc, &dir.path().join("order.jpg"), FORMAT_JPEG, true, false);
    assert_eq!(
        carried,
        CARRIES_PROFILE | CARRIES_EXIF | CARRIES_XMP | CARRIES_IPTC | CARRIES_RESOLUTION
    );
    let segments = jpeg_segments(&bytes);
    let labels: Vec<String> = segments
        .iter()
        .map(|(m, p)| match (*m, p.as_slice()) {
            (0xE0, p) if p.starts_with(b"JFIF\0") => "APP0(JFIF)".to_string(),
            (0xE1, p) if p.starts_with(b"Exif\0\0") => "APP1(Exif)".to_string(),
            (0xE1, p) if p.starts_with(XMP_ID) => "APP1(XMP)".to_string(),
            (0xE2, p) if p.starts_with(b"ICC_PROFILE\0") => "APP2(ICC)".to_string(),
            (0xED, p) if p.starts_with(IPTC_ID) => "APP13".to_string(),
            (0xC0, _) => "SOF0".to_string(),
            (m, _) => format!("{m:02X}"),
        })
        .collect();
    let head: Vec<&str> = labels.iter().map(String::as_str).collect();
    let icc_count = head.iter().filter(|l| **l == "APP2(ICC)").count();
    assert!(icc_count >= 1, "at least one ICC chunk");
    let mut expected = vec!["APP0(JFIF)", "APP1(Exif)"];
    expected.extend(std::iter::repeat_n("APP2(ICC)", icc_count));
    expected.extend(["APP1(XMP)", "APP13", "SOF0"]);
    assert_eq!(
        &head[..expected.len()],
        &expected[..],
        "the documented order: JFIF first, Exif the first APP1, our segments last, all before SOF0"
    );
    unsafe { rz_doc_free(doc) };
}

#[test]
fn per_format_capability_matches_what_is_written() {
    let dir = TempDir::new().unwrap();
    let doc = doc_from(&dir, "cap.png", &opaque_pattern(6, 4));
    let exif = build_exif(false, 1, (72, 72), None, false);
    let doc = set_packet(doc, METADATA_EXIF, &exif.bytes);
    let doc = set_packet(doc, METADATA_XMP, SAMPLE_XMP);
    let doc = set_packet(
        doc,
        METADATA_IPTC,
        &bim(0x0404, b"", b"\x1c\x02\x00\x00\x02\x00\x04"),
    );
    let p3 = builtin_bytes(1);
    let doc = apply(doc, |d| unsafe {
        rz_doc_assign_profile(d, p3.as_ptr(), p3.len())
    });

    for (format, name) in [
        (FORMAT_PNG, "png"),
        (FORMAT_JPEG, "jpg"),
        (FORMAT_TIFF, "tif"),
        (FORMAT_BMP, "bmp"),
        (FORMAT_GIF, "gif"),
        (FORMAT_WEBP, "webp"),
    ] {
        let caps = rz_format_carries(format);
        let path = dir.path().join(format!("cap.{name}"));
        let (bytes, carried) = save(doc, &path, format, true, false);
        // WebP is the one format whose report exceeds its own row: it has no
        // density slot, but the EXIF packet it writes states the ppi, and
        // the report is about the FILE (a_webp_reports_the_resolution_its_
        // exif_states pins that).
        let expected = if format == FORMAT_WEBP {
            caps | CARRIES_RESOLUTION
        } else {
            caps
        };
        assert_eq!(
            carried, expected,
            "{name}: this document holds all five, so everything the format \
             carries must be written"
        );
        // And a byte-stream walk confirms exactly those and no others.
        match format {
            FORMAT_PNG => {
                let kinds: Vec<[u8; 4]> = png_chunks(&bytes).into_iter().map(|(k, _)| k).collect();
                assert!(kinds.contains(b"iCCP"));
                assert!(kinds.contains(b"eXIf"));
                assert!(kinds.contains(b"iTXt"));
                assert!(kinds.contains(b"pHYs"));
            }
            FORMAT_JPEG => {
                assert!(jpeg_payload(&bytes, 0xE1, b"Exif\0\0").is_some());
                assert!(jpeg_payload(&bytes, 0xE1, XMP_ID).is_some());
                assert!(jpeg_payload(&bytes, 0xED, IPTC_ID).is_some());
                assert!(jpeg_payload(&bytes, 0xE2, b"ICC_PROFILE\0").is_some());
            }
            FORMAT_TIFF => {
                assert_eq!(tiff_tag(&bytes, 0x8773).as_deref(), Some(p3.as_slice()));
            }
            FORMAT_WEBP => {
                assert!(
                    bytes.windows(4).any(|w| w == b"ICCP"),
                    "a WebP carries the profile in an ICCP chunk"
                );
            }
            _ => assert!(
                !bytes.windows(4).any(|w| w == b"acsp"),
                "a format that carries nothing writes no profile"
            ),
        }
        // Every format's output reopens with the same pixels.
        if format != FORMAT_GIF && format != FORMAT_JPEG {
            let back = open_file(&dir, &format!("back.{name}"), &bytes);
            assert_eq!(
                unsafe { (rz_doc_width(back), rz_doc_height(back)) },
                (6, 4),
                "{name} reopens"
            );
            unsafe { rz_doc_free(back) };
        }
    }
    unsafe { rz_doc_free(doc) };
}

#[test]
fn an_embedded_profile_and_packets_survive_a_round_trip() {
    // The phase's central promise, end to end: a tagged file written here
    // reopens here in the same space, with the same packets and the same
    // ppi. (TIFF is the documented exception —
    // `jpeg_and_png_are_the_only_walked_containers` pins it.)
    let dir = TempDir::new().unwrap();
    let doc = doc_from(&dir, "rt.png", &opaque_pattern(8, 6));
    let p3 = builtin_bytes(1);
    let doc = apply(doc, |d| unsafe {
        rz_doc_assign_profile(d, p3.as_ptr(), p3.len())
    });
    let doc = apply(doc, |d| unsafe { rz_doc_set_resolution(d, 240.0, 240.0) });
    let exif = build_exif(false, 1, (240, 240), None, false);
    let doc = set_packet(doc, METADATA_EXIF, &exif.bytes);
    let doc = set_packet(doc, METADATA_XMP, SAMPLE_XMP);

    for (format, name) in [(FORMAT_PNG, "rt-out.png"), (FORMAT_JPEG, "rt-out.jpg")] {
        let (bytes, carried) = save(doc, &dir.path().join(name), format, true, false);
        assert!(carried & CARRIES_PROFILE != 0, "{name}");
        let back = open_file(&dir, &format!("back-{name}"), &bytes);
        let len = unsafe { rz_doc_icc_profile_len(back) };
        let mut profile = vec![0u8; len];
        assert!(unsafe { rz_doc_icc_profile(back, profile.as_mut_ptr(), len) });
        assert_eq!(profile, p3, "{name}: the profile comes back byte for byte");
        assert_eq!(
            unsafe { rz_doc_resolution_x(back) },
            240.0,
            "{name}: and so does the ppi"
        );
        assert_eq!(
            packet(back, METADATA_XMP).as_deref(),
            Some(SAMPLE_XMP),
            "{name}: and the XMP packet"
        );
        // The EXIF comes back NORMALIZED, not verbatim — its next-IFD link
        // was cut and its resolution rewritten on the way out.
        let recovered = packet(back, METADATA_EXIF).expect("an EXIF packet");
        assert_eq!(recovered.len(), exif.bytes.len(), "{name}");
        unsafe { rz_doc_free(back) };
    }
    unsafe { rz_doc_free(doc) };
}

#[test]
fn an_oversize_blob_is_dropped_rather_than_failing_the_save() {
    let dir = TempDir::new().unwrap();
    let doc = doc_from(&dir, "big.png", &opaque_pattern(4, 4));
    let fat = vec![b'x'; 70 * 1024];
    let doc = set_packet(doc, METADATA_XMP, &fat);

    let (jpg, jpeg_carried) = save(doc, &dir.path().join("fat.jpg"), FORMAT_JPEG, true, false);
    assert_eq!(
        jpeg_carried & CARRIES_XMP,
        0,
        "70 KB does not fit one APP1, so it is dropped"
    );
    assert!(jpeg_payload(&jpg, 0xE1, XMP_ID).is_none());

    let (png, png_carried) = save(doc, &dir.path().join("fat.png"), FORMAT_PNG, true, false);
    assert!(
        png_carried & CARRIES_XMP != 0,
        "a PNG iTXt chunk has no such limit"
    );
    assert!(png_chunk(&png, b"iTXt").is_some());
    unsafe { rz_doc_free(doc) };
}

#[test]
fn strip_metadata_and_embed_profile_are_honoured() {
    let dir = TempDir::new().unwrap();
    let doc = doc_from(&dir, "s.png", &opaque_pattern(5, 4));
    let exif = build_exif(false, 1, (72, 72), None, false);
    let doc = set_packet(doc, METADATA_EXIF, &exif.bytes);
    let doc = set_packet(doc, METADATA_XMP, SAMPLE_XMP);
    let p3 = builtin_bytes(1);
    let doc = apply(doc, |d| unsafe {
        rz_doc_assign_profile(d, p3.as_ptr(), p3.len())
    });

    for embed in [true, false] {
        for strip in [true, false] {
            let path = dir.path().join(format!("s-{embed}-{strip}.png"));
            let (bytes, carried) = save(doc, &path, FORMAT_PNG, embed, strip);
            let kinds: Vec<[u8; 4]> = png_chunks(&bytes).into_iter().map(|(k, _)| k).collect();
            assert_eq!(
                carried & CARRIES_PROFILE != 0,
                embed,
                "embed={embed} strip={strip}"
            );
            assert_eq!(kinds.contains(b"iCCP"), embed);
            assert_eq!(carried & CARRIES_EXIF != 0, !strip);
            assert_eq!(kinds.contains(b"eXIf"), !strip);
            assert_eq!(kinds.contains(b"iTXt"), !strip);
            assert!(
                carried & CARRIES_RESOLUTION != 0,
                "the document's own resolution is not inherited metadata"
            );
        }
    }
    unsafe { rz_doc_free(doc) };
}

#[test]
fn the_injector_produces_a_readable_file() {
    let dir = TempDir::new().unwrap();
    let pixels = opaque_pattern(9, 7);
    let doc = doc_from(&dir, "r.png", &pixels);
    let doc = set_packet(doc, METADATA_XMP, SAMPLE_XMP);
    let doc = apply(doc, |d| unsafe { rz_doc_set_resolution(d, 300.0, 300.0) });
    let before = flat_pixels(doc);

    let (png, _) = save(doc, &dir.path().join("inj.png"), FORMAT_PNG, true, false);
    let back = open_file(&dir, "inj-back.png", &png);
    assert_eq!(flat_pixels(back), before, "a spliced PNG reopens unchanged");

    // TIFF is the format whose encoder SEEKS: it must take the
    // pass-through injector and still reopen.
    let (tiff, carried) = save(doc, &dir.path().join("inj.tif"), FORMAT_TIFF, true, false);
    assert_eq!(carried, CARRIES_PROFILE, "TIFF carries the profile only");
    let back_tiff = open_file(&dir, "inj-back.tif", &tiff);
    assert_eq!(flat_pixels(back_tiff), before, "the TIFF reopens unchanged");

    unsafe {
        rz_doc_free(back_tiff);
        rz_doc_free(back);
        rz_doc_free(doc);
    }
}

#[test]
fn a_caller_supplied_flat_image_is_what_gets_encoded() {
    let dir = TempDir::new().unwrap();
    let doc = doc_from(&dir, "f.png", &opaque_pattern(6, 4));
    let doc = apply(doc, |d| unsafe { rz_doc_set_resolution(d, 200.0, 200.0) });
    let doc = set_packet(doc, METADATA_XMP, SAMPLE_XMP);
    // A composite that deliberately differs from this document's own.
    let supplied = open_image(&dir, "supplied.png", &solid(6, 4, [9, 8, 7, 255]));

    let path = dir.path().join("supplied-out.png");
    let c = cpath(&path);
    let mut err: *mut c_char = ptr::null_mut();
    let mut carried: u32 = 0;
    assert!(unsafe {
        rz_doc_save_image(
            doc,
            supplied,
            c.as_ptr(),
            FORMAT_PNG,
            90,
            true,
            false,
            &mut carried,
            &mut err,
        )
    });
    assert!(carried & CARRIES_XMP != 0 && carried & CARRIES_RESOLUTION != 0);
    let back = open_file(&dir, "supplied-back.png", &std::fs::read(&path).unwrap());
    assert_eq!(
        flat_pixels(back),
        img_pixels(supplied),
        "the supplied pixels are what got encoded"
    );
    assert_eq!(unsafe { rz_doc_resolution_x(back) }, 200.0);
    assert!(png_chunk(&std::fs::read(&path).unwrap(), b"iTXt").is_some());

    // And a NULL flat flattens the document itself.
    let (bytes, _) = save(doc, &dir.path().join("own.png"), FORMAT_PNG, true, false);
    let own = open_file(&dir, "own-back.png", &bytes);
    assert_eq!(flat_pixels(own), flat_pixels(doc));

    unsafe {
        rz_doc_free(own);
        rz_doc_free(back);
        rz_image_free(supplied);
        rz_doc_free(doc);
    }
}

/// The value bytes of a TIFF IFD0 tag, walked by hand.
fn tiff_tag(bytes: &[u8], tag: u16) -> Option<Vec<u8>> {
    let le = &bytes[..2] == b"II";
    let u16_at = |a: usize| {
        let v = [bytes[a], bytes[a + 1]];
        if le {
            u16::from_le_bytes(v)
        } else {
            u16::from_be_bytes(v)
        }
    };
    let u32_at = |a: usize| {
        let v: [u8; 4] = bytes[a..a + 4].try_into().unwrap();
        if le {
            u32::from_le_bytes(v)
        } else {
            u32::from_be_bytes(v)
        }
    };
    assert_eq!(u16_at(2), 42, "the TIFF magic");
    let ifd = u32_at(4) as usize;
    let count = usize::from(u16_at(ifd));
    (0..count).find_map(|i| {
        let e = ifd + 2 + 12 * i;
        (u16_at(e) == tag).then(|| {
            let n = u32_at(e + 4) as usize;
            let at = u32_at(e + 8) as usize;
            bytes[at..at + n].to_vec()
        })
    })
}

#[test]
fn jpeg_and_png_are_the_only_walked_containers() {
    let dir = TempDir::new().unwrap();
    // A TIFF carries the profile and nothing else: no EXIF, no XMP, no ppi.
    let doc = doc_from(&dir, "t.png", &opaque_pattern(5, 3));
    let p3 = builtin_bytes(1);
    let doc = apply(doc, |d| unsafe {
        rz_doc_assign_profile(d, p3.as_ptr(), p3.len())
    });
    let doc = set_packet(doc, METADATA_XMP, SAMPLE_XMP);
    let doc = apply(doc, |d| unsafe { rz_doc_set_resolution(d, 300.0, 300.0) });
    let (bytes, carried) = save(doc, &dir.path().join("only.tif"), FORMAT_TIFF, true, false);
    assert_eq!(carried, CARRIES_PROFILE);
    // Tag 0x8773 InterColorProfile, read out of the IFD by hand: what the
    // file actually holds is the document's own profile, byte for byte.
    assert_eq!(
        tiff_tag(&bytes, 0x8773).as_deref(),
        Some(p3.as_slice()),
        "the TIFF carries the profile as tag 34675"
    );

    let back = open_file(&dir, "only-back.tif", &bytes);
    // Reopening does NOT recover it: `image` 0.25.10's TIFF decoder never
    // surfaces the tag it writes (its `get_tag_u8_vec` refuses the array),
    // so the document takes the sRGB default. What we WRITE is right —
    // ColorSync and littleCMS both read "Display P3" out of this file — and
    // this assertion pins the limit so it is noticed if the crate fixes it.
    assert_ne!(
        unsafe { rz_doc_icc_profile_len(back) },
        p3.len(),
        "a TIFF's own profile is not read back by this build"
    );
    assert_eq!(packet(back, METADATA_XMP), None, "no walk, no packets");
    assert_eq!(
        unsafe { rz_doc_resolution_x(back) },
        72.0,
        "and no resolution: the default stands"
    );
    // The OTHER TIFF limit, pinned because a host has to word a message
    // around it: the encoder crate exposes no resolution hook, so the file
    // does not merely omit the ppi — it states the `tiff` crate's own
    // 1/1 with ResolutionUnit 1 ("none"), which some readers show as 1 dpi.
    // If a future crate version writes something real, this fails and the
    // export notice's sentence needs revisiting.
    assert_eq!(&bytes[..2], b"II", "the encoder writes little-endian here");
    let resolution_tag = |tag: u16| {
        let e = ifd0_entry(&bytes, tag);
        let at = u32::from_le_bytes(bytes[e + 8..e + 12].try_into().unwrap()) as usize;
        rational_at(&bytes, at)
    };
    assert_eq!(
        resolution_tag(0x011A),
        (1, 1),
        "XResolution is the crate's default"
    );
    assert_eq!(resolution_tag(0x011B), (1, 1), "and so is YResolution");
    unsafe {
        rz_doc_free(back);
        rz_doc_free(doc);
    }
}

/// A broken link to the thumbnail IFD costs the thumbnail, not the packet.
/// A tool that strips a thumbnail without rewriting IFD0's next-IFD offset
/// leaves a link pointing past the end of the block — common in the wild —
/// and every IFD0 tag (the camera make, the date, the copyright) used to go
/// out of the export with it. IFD1 is unlinked on the way out anyway, so
/// nothing downstream of IFD0 is ever written.
#[test]
fn a_broken_thumbnail_link_still_exports_the_exif() {
    let dir = TempDir::new().unwrap();
    let doc = doc_from(&dir, "link.png", &opaque_pattern(4, 4));
    let good = build_exif(false, 1, (72, 72), None, true);
    for (label, link) in [("past the block", 100_000u32), ("back at IFD0", 8)] {
        let mut blob = good.bytes.clone();
        blob[good.link..good.link + 4].copy_from_slice(&link.to_le_bytes());
        let doc = with_packet(doc, METADATA_EXIF, &blob);
        let (bytes, carried) = save(
            doc,
            &dir.path().join("linked.jpg"),
            FORMAT_JPEG,
            true,
            false,
        );
        assert_ne!(carried & CARRIES_EXIF, 0, "{label}: the packet is written");
        let out = jpeg_payload(&bytes, 0xE1, b"Exif\0\0").expect("an Exif APP1");
        assert_eq!(out.len(), blob.len(), "{label}: the block did not grow");
        assert_eq!(
            u32::from_le_bytes(out[good.link..good.link + 4].try_into().unwrap()),
            0,
            "{label}: and the broken link is the one thing cut"
        );
        assert_eq!(
            u32::from_le_bytes(out[good.rationals..good.rationals + 4].try_into().unwrap()),
            72,
            "{label}: IFD0's own tags survive"
        );
        unsafe { rz_doc_free(doc) };
    }
    unsafe { rz_doc_free(doc) };
}

/// A fractional ppi survives a round trip through our own writer. Both
/// containers state the resolution as an integer count — the JFIF density in
/// whole dots per inch, `pHYs` in whole pixels per metre — while the EXIF
/// tags are RATIONALs, so when the two agree to the container's precision
/// the EXIF pair is the one to believe. Without that, every save/reopen
/// cycle shifted a 150.5 ppi document by a third of a percent.
#[test]
fn a_fractional_resolution_survives_a_round_trip() {
    let dir = TempDir::new().unwrap();
    let exif = build_exif(false, 1, (72, 72), None, false);
    let file = jpeg_with(
        &opaque_pattern(8, 6),
        95,
        &[jpeg_segment(0xE1, b"Exif\0\0", &exif.bytes)],
    );
    let doc = open_file(&dir, "frac.jpg", &file);
    let doc = apply(doc, |d| unsafe { rz_doc_set_resolution(d, 150.5, 300.25) });
    for (format, name) in [(FORMAT_JPEG, "frac-out.jpg"), (FORMAT_PNG, "frac-out.png")] {
        let path = dir.path().join(name);
        let (bytes, _) = save(doc, &path, format, true, false);
        let back = open_file(&dir, &format!("re-{name}"), &bytes);
        assert_eq!(
            unsafe { (rz_doc_resolution_x(back), rz_doc_resolution_y(back)) },
            (150.5, 300.25),
            "{name}: the exact resolution comes back"
        );
        unsafe { rz_doc_free(back) };
    }
    unsafe { rz_doc_free(doc) };
}

/// The open-time rotation swaps the resolution's axes with the pixels'. A
/// 300 x 150 ppi frame stored sideways is a 150 x 300 ppi picture once it is
/// upright, and `rz_doc_rotate90` on the same document says exactly that —
/// the two paths must not disagree about one operation.
#[test]
fn a_quarter_turned_file_swaps_its_resolution() {
    let dir = TempDir::new().unwrap();
    for (orientation, swapped) in [(1u16, false), (3, false), (6, true), (8, true)] {
        let exif = build_exif(false, orientation, (300, 150), None, false);
        let file = jpeg_with(
            &opaque_pattern(8, 6),
            95,
            &[jpeg_segment(0xE1, b"Exif\0\0", &exif.bytes)],
        );
        let doc = open_file(&dir, &format!("turn{orientation}.jpg"), &file);
        let want = if swapped {
            (150.0, 300.0)
        } else {
            (300.0, 150.0)
        };
        assert_eq!(
            unsafe { (rz_doc_resolution_x(doc), rz_doc_resolution_y(doc)) },
            want,
            "orientation {orientation}"
        );
        // The physical picture is the same size either way: the print
        // dimensions turn with the pixels instead of being reshaped.
        let (w, h) = unsafe { (rz_doc_width(doc), rz_doc_height(doc)) };
        let print = (w as f32 / want.0, h as f32 / want.1);
        let expected = if swapped {
            (6.0 / 150.0, 8.0 / 300.0)
        } else {
            (8.0 / 300.0, 6.0 / 150.0)
        };
        assert_eq!(print, expected, "orientation {orientation}: print size");
        unsafe { rz_doc_free(doc) };
    }
}

/// The three chunks the PNG walk actually reads are still CRC-verified —
/// their contents are trusted, so a corrupt one must be ignored rather than
/// half-believed. (Every other chunk, `IDAT` above all, is skipped by TYPE
/// before its CRC is computed: verifying bytes the walk then discards cost a
/// pass over the whole file on every open and bought nothing.)
#[test]
fn a_chunk_the_walk_reads_is_still_crc_checked() {
    let dir = TempDir::new().unwrap();
    let pixels = opaque_pattern(4, 4);
    // 11811 px/m = 300 ppi, unit 1.
    let mut phys = 11811u32.to_be_bytes().to_vec();
    phys.extend_from_slice(&11811u32.to_be_bytes());
    phys.push(1);
    let good = png_with(&pixels, &[png_chunk_bytes(b"pHYs", &phys)]);
    let doc = open_file(&dir, "good-crc.png", &good);
    assert_eq!(
        unsafe { rz_doc_resolution_x(doc) },
        300.0,
        "a good CRC is read"
    );
    unsafe { rz_doc_free(doc) };

    let mut broken = good.clone();
    let at = broken
        .windows(4)
        .position(|w| w == b"pHYs")
        .expect("the chunk is there")
        + 4
        + phys.len();
    broken[at] ^= 0xFF;
    let doc = open_file(&dir, "bad-crc.png", &broken);
    assert_eq!(
        unsafe { rz_doc_resolution_x(doc) },
        72.0,
        "a chunk that fails its CRC is not trusted"
    );
    unsafe { rz_doc_free(doc) };
}

/// The three resolution tags are ONE statement, so the writer brings all
/// three to the document or writes no packet at all. Both halves were live
/// defects: a unit the writer skipped left the new numbers counted in the
/// OLD unit (300 ppi written under "centimetres" reads as 762 ppi
/// everywhere but here), and the mirror — flipping the unit to inches while
/// the centimetre numbers stayed — understated the resolution by 2.54x.
///
/// "Leave all three alone" was the third wrong answer, and the subtlest:
/// Exif makes IFD0 the authority OVER the JFIF density beside it, so a
/// packet left saying 118/1 under "centimetres" did not sit quietly next to
/// a 300 ppi JFIF header — it beat it, and the file read back at 299.72 ppi
/// in Rasterize, `sips` and ImageMagick alike while the save reported the
/// resolution as written. A trio that cannot be corrected is silenced, and
/// when even that is impossible the packet is dropped and REPORTED dropped.
#[test]
fn the_resolution_trio_is_written_whole_or_not_at_all() {
    let dir = TempDir::new().unwrap();

    // (a) A ResolutionUnit stored as a LONG. The reader has always accepted
    // that shape, so the writer must patch it too.
    let mut exif = build_exif(false, 1, (118, 118), None, false);
    let unit = ifd0_entry(&exif.bytes, 0x0128);
    exif.bytes[unit + 2..unit + 4].copy_from_slice(&4u16.to_le_bytes()); // LONG
    exif.bytes[unit + 8..unit + 12].copy_from_slice(&3u32.to_le_bytes()); // centimetres
    let doc = doc_from(&dir, "trio.png", &opaque_pattern(8, 6));
    let doc = apply(doc, |d| unsafe { rz_doc_set_resolution(d, 300.0, 300.0) });
    let doc = set_packet(doc, METADATA_EXIF, &exif.bytes);
    let (bytes, carried) = save(
        doc,
        &dir.path().join("long-unit.jpg"),
        FORMAT_JPEG,
        true,
        false,
    );
    assert!(carried & CARRIES_EXIF != 0);
    let out = jpeg_payload(&bytes, 0xE1, b"Exif\0\0").expect("an Exif APP1");
    assert_eq!(rational_at(&out, exif.rationals), (300, 1), "XResolution");
    assert_eq!(
        rational_at(&out, exif.rationals + 8),
        (300, 1),
        "YResolution"
    );
    assert_eq!(
        ifd0_inline(&out, 0x0128),
        2,
        "and the unit that counts them is inches"
    );
    unsafe { rz_doc_free(doc) };

    // (b) A ResolutionUnit shape nothing can patch in place (a SHORT of
    // count 2). The rationals must NOT move either — 300 ppi under
    // "centimetres" is a file claiming 762 ppi — and because the unit is the
    // very entry that cannot be silenced, the packet cannot be brought to
    // say anything true about the resolution and is dropped WHOLE.
    let mut exif = build_exif(false, 1, (118, 118), None, false);
    let unit = ifd0_entry(&exif.bytes, 0x0128);
    exif.bytes[unit + 4..unit + 8].copy_from_slice(&2u32.to_le_bytes()); // count 2
    exif.bytes[unit + 8..unit + 10].copy_from_slice(&3u16.to_le_bytes()); // centimetres
    let doc = doc_from(&dir, "trio2.png", &opaque_pattern(8, 6));
    let doc = apply(doc, |d| unsafe { rz_doc_set_resolution(d, 300.0, 300.0) });
    let doc = set_packet(doc, METADATA_EXIF, &exif.bytes);
    let (bytes, carried) = save(
        doc,
        &dir.path().join("odd-unit.jpg"),
        FORMAT_JPEG,
        true,
        false,
    );
    assert_eq!(
        carried & CARRIES_EXIF,
        0,
        "a packet that would contradict the density is dropped, and reported dropped"
    );
    assert!(
        jpeg_payload(&bytes, 0xE1, b"Exif\0\0").is_none(),
        "no Exif APP1 at all"
    );
    assert!(
        carried & CARRIES_RESOLUTION != 0,
        "the resolution still travels — in the container's own density"
    );
    // And the JFIF density is then the export's only statement about ppi.
    let jfif = jpeg_payload(&bytes, 0xE0, b"JFIF\0").expect("an APP0");
    assert_eq!(
        (jfif[2], u16::from_be_bytes([jfif[3], jfif[4]])),
        (1, 300),
        "which the container still carries"
    );
    // Which is what the file reads back at — the point of the whole rule.
    let back = open_file(&dir, "re-odd-unit.jpg", &bytes);
    assert_eq!(
        unsafe { (rz_doc_resolution_x(back), rz_doc_resolution_y(back)) },
        (300.0, 300.0)
    );
    unsafe {
        rz_doc_free(back);
        rz_doc_free(doc);
    }
}

/// Both resolution entries may point at ONE eight-byte rational — legal
/// EXIF, and what a writer that de-duplicates identical values produces for
/// a file whose axes started equal. Patching them separately wrote the
/// vertical ppi over the horizontal one and left the file stating one wrong
/// number for both axes.
///
/// One datum cannot state two numbers, so an ANISOTROPIC document cannot be
/// spelled through it at all — and leaving the source's number there was the
/// second half of the same defect, because the EXIF pair outranks the JFIF
/// density this save writes. The packet is therefore dropped WHOLE, and
/// reported dropped, so the file has exactly one resolution statement and it
/// is the document's.
#[test]
fn resolution_entries_sharing_one_rational_are_not_half_written() {
    let dir = TempDir::new().unwrap();
    let mut exif = build_exif(false, 1, (72, 72), None, false);
    let y = ifd0_entry(&exif.bytes, 0x011B);
    exif.bytes[y + 8..y + 12].copy_from_slice(&(exif.rationals as u32).to_le_bytes());

    // Axes that agree: one datum, one number, and it is the document's.
    let doc = doc_from(&dir, "shared.png", &opaque_pattern(8, 6));
    let doc = apply(doc, |d| unsafe { rz_doc_set_resolution(d, 300.0, 300.0) });
    let doc = set_packet(doc, METADATA_EXIF, &exif.bytes);
    let (bytes, _) = save(
        doc,
        &dir.path().join("shared.jpg"),
        FORMAT_JPEG,
        true,
        false,
    );
    let out = jpeg_payload(&bytes, 0xE1, b"Exif\0\0").expect("an Exif APP1");
    assert_eq!(rational_at(&out, exif.rationals), (300, 1));
    unsafe { rz_doc_free(doc) };

    // Axes that differ: one datum cannot state two numbers, so neither is
    // written and the container's density carries the pair alone.
    let doc = doc_from(&dir, "shared2.png", &opaque_pattern(8, 6));
    let doc = apply(doc, |d| unsafe { rz_doc_set_resolution(d, 300.0, 150.0) });
    let doc = set_packet(doc, METADATA_EXIF, &exif.bytes);
    let (bytes, carried) = save(
        doc,
        &dir.path().join("shared3.jpg"),
        FORMAT_JPEG,
        true,
        false,
    );
    assert_eq!(
        carried & CARRIES_EXIF,
        0,
        "the packet cannot state 300 x 150 through one datum, so it is dropped"
    );
    assert!(jpeg_payload(&bytes, 0xE1, b"Exif\0\0").is_none());
    let jfif = jpeg_payload(&bytes, 0xE0, b"JFIF\0").expect("an APP0");
    assert_eq!(u16::from_be_bytes([jfif[3], jfif[4]]), 300, "Xdensity");
    assert_eq!(u16::from_be_bytes([jfif[5], jfif[6]]), 150, "Ydensity");
    // The whole point: the density is the file's only resolution statement,
    // so the exported file reads back at the document's own anisotropic ppi
    // rather than at the source file's 72.
    let back = open_file(&dir, "re-shared3.jpg", &bytes);
    assert_eq!(
        unsafe { (rz_doc_resolution_x(back), rz_doc_resolution_y(back)) },
        (300.0, 150.0)
    );
    assert!(
        carried & CARRIES_RESOLUTION != 0,
        "which is what the save reports"
    );
    unsafe {
        rz_doc_free(back);
        rz_doc_free(doc);
    }
}

/// One RIFF chunk's payload, walked by hand.
fn riff_chunk(bytes: &[u8], fourcc: &[u8; 4]) -> Option<Vec<u8>> {
    let mut i = 12usize;
    while i + 8 <= bytes.len() {
        let size = u32::from_le_bytes(bytes[i + 4..i + 8].try_into().unwrap()) as usize;
        let end = i + 8 + size;
        if end > bytes.len() {
            return None;
        }
        if &bytes[i..i + 4] == fourcc {
            return Some(bytes[i + 8..end].to_vec());
        }
        i = end + (size % 2);
    }
    None
}

/// A WebP has no density slot of its own, but the EXIF chunk it does carry
/// states the document's ppi — so the save must report the resolution as
/// CARRIED. Reporting it dropped, from the format table alone, told the user
/// the opposite of what the file contains.
#[test]
fn a_webp_reports_the_resolution_its_exif_states() {
    let dir = TempDir::new().unwrap();
    let exif = build_exif(false, 1, (72, 72), None, false);
    let doc = doc_from(&dir, "w.png", &opaque_pattern(8, 6));
    let doc = apply(doc, |d| unsafe { rz_doc_set_resolution(d, 300.0, 300.0) });
    let doc = set_packet(doc, METADATA_EXIF, &exif.bytes);

    let (bytes, carried) = save(doc, &dir.path().join("w.webp"), FORMAT_WEBP, true, false);
    assert!(carried & CARRIES_EXIF != 0);
    assert!(
        carried & CARRIES_RESOLUTION != 0,
        "the file states the ppi, so the report must say so"
    );
    let out = riff_chunk(&bytes, b"EXIF").expect("an EXIF chunk");
    assert_eq!(rational_at(&out, exif.rationals), (300, 1), "XResolution");
    assert_eq!(ifd0_inline(&out, 0x0128), 2, "in inches");

    // With the packet stripped there is nothing left to say it, and the
    // report says that instead.
    let (bytes, carried) = save(doc, &dir.path().join("bare.webp"), FORMAT_WEBP, true, true);
    assert_eq!(carried & (CARRIES_EXIF | CARRIES_RESOLUTION), 0);
    assert!(riff_chunk(&bytes, b"EXIF").is_none());
    unsafe { rz_doc_free(doc) };

    // A packet with no resolution tags to patch says nothing either, even
    // though it is carried.
    let bare = build_exif_without_resolution();
    let doc = doc_from(&dir, "w2.png", &opaque_pattern(8, 6));
    let doc = apply(doc, |d| unsafe { rz_doc_set_resolution(d, 300.0, 300.0) });
    let doc = set_packet(doc, METADATA_EXIF, &bare);
    let (_, carried) = save(doc, &dir.path().join("w2.webp"), FORMAT_WEBP, true, false);
    assert!(carried & CARRIES_EXIF != 0, "carried");
    assert_eq!(
        carried & CARRIES_RESOLUTION,
        0,
        "but nothing in the file states this document's ppi"
    );
    unsafe { rz_doc_free(doc) };
}

/// An IFD0 holding one Orientation entry and nothing else: a packet the
/// writer can normalize but whose resolution it cannot state, because an
/// absent tag is never inserted.
fn build_exif_without_resolution() -> Vec<u8> {
    let ifd0 = 8usize;
    let mut b = vec![0u8; ifd0 + 2 + 12 + 4];
    b[0..2].copy_from_slice(b"II");
    b[2..4].copy_from_slice(&42u16.to_le_bytes());
    b[4..8].copy_from_slice(&(ifd0 as u32).to_le_bytes());
    b[ifd0..ifd0 + 2].copy_from_slice(&1u16.to_le_bytes());
    let e = ifd0 + 2;
    b[e..e + 2].copy_from_slice(&0x0112u16.to_le_bytes());
    b[e + 2..e + 4].copy_from_slice(&3u16.to_le_bytes());
    b[e + 4..e + 8].copy_from_slice(&1u32.to_le_bytes());
    b[e + 8..e + 10].copy_from_slice(&1u16.to_le_bytes());
    b
}

/// A chunk that could never be stored is skipped BEFORE its CRC is computed.
///
/// The check is table-free — eight iterations per byte — so paying it for a
/// chunk the walk then throws away is pure loss, and a PNG chunk may be
/// 2 GiB. This measures the walk's own cost rather than a wall-clock
/// threshold: the same file appears twice, once with the big chunk typed
/// `eXIf` (which the walk reads) and once typed `zzZz` (which it skips by
/// type), so the ONLY difference between the two opens is the verification.
/// Before the fix the `eXIf` open cost seconds more.
#[test]
fn an_oversize_chunk_is_skipped_before_its_crc_is_computed() {
    let dir = TempDir::new().unwrap();
    let pixels = opaque_pattern(4, 4);
    // Comfortably over MAX_RZDC_BLOB_LEN (16 MiB), so `capture` could never
    // keep it however the CRC turns out.
    let payload = vec![b'x'; 24 * 1024 * 1024];
    let elapsed = |kind: &[u8; 4], name: &str| {
        let file = png_with(&pixels, &[png_chunk_bytes(kind, &payload)]);
        std::fs::write(dir.path().join(name), &file).unwrap();
        let c = cpath(&dir.path().join(name));
        let mut best = std::time::Duration::MAX;
        for _ in 0..3 {
            let start = std::time::Instant::now();
            let mut err: *mut c_char = ptr::null_mut();
            let doc = unsafe { rz_doc_open(c.as_ptr(), &mut err) };
            best = best.min(start.elapsed());
            assert!(!doc.is_null());
            assert_eq!(packet(doc, METADATA_EXIF), None, "far past the blob cap");
            unsafe { rz_doc_free(doc) };
        }
        best
    };
    let ignored = elapsed(b"zzZz", "ignored.png");
    let walked = elapsed(b"eXIf", "walked.png");
    println!("ignored {ignored:?} walked {walked:?}");
    // Best of three each, and a 4x bound rather than a tight one: the ratio
    // measured here is 1.3x with the cap checked first and about 30x without
    // it (7.5 ms against 250 ms), so the margin is for a loaded machine, not
    // for the defect.
    assert!(
        walked < ignored * 4,
        "a chunk the walk cannot keep must cost what an ignored one costs \
         (ignored {ignored:?}, walked {walked:?})"
    );
}

/// Photoshop splits an 8BIM run larger than one segment across several
/// `Photoshop 3.0\0` APP13s, and a reader is meant to CONCATENATE them.
/// Taking the first dropped every resource after it — silently, because the
/// export then re-spliced the truncated prefix and reported the packet as
/// written.
#[test]
fn a_split_8bim_run_is_concatenated_across_app13_segments() {
    let dir = TempDir::new().unwrap();
    let first = bim(0x0404, b"cap", b"\x1c\x02\x78\x00\x03abc");
    let second = bim(0x040C, b"", &[7u8; 6]);
    let third = bim(0x0425, b"", &[9u8; 5]);
    let file = jpeg_with(
        &opaque_pattern(6, 4),
        92,
        &[
            jpeg_segment(0xED, IPTC_ID, &first),
            jpeg_segment(0xED, IPTC_ID, &[second.clone(), third.clone()].concat()),
        ],
    );
    let doc = open_file(&dir, "split.jpg", &file);
    assert_eq!(
        packet(doc, METADATA_IPTC).expect("an 8BIM run"),
        [first.clone(), second.clone(), third.clone()].concat(),
        "every segment's payload, joined in order"
    );

    // And the whole run travels: an export re-splices all three resources.
    let (bytes, carried) = save(
        doc,
        &dir.path().join("split-out.jpg"),
        FORMAT_JPEG,
        true,
        false,
    );
    assert!(carried & CARRIES_IPTC != 0);
    assert_eq!(
        jpeg_payload(&bytes, 0xED, IPTC_ID).expect("an APP13"),
        [first, second, third].concat(),
        "nothing is lost between the first segment and the last"
    );
    unsafe { rz_doc_free(doc) };
}

/// When a JPEG states its resolution twice and the two disagree, the EXIF
/// pair wins: Exif/DCF makes IFD0's XResolution/YResolution the file's
/// statement (a JFIF APP0 is not even supposed to be in an Exif file), and
/// it is what ImageIO and ImageMagick answer for the same file. Believing
/// the container instead opened such a file at the wrong ppi, which is a
/// wrong print size in Image Size and a wrong layout on paper.
#[test]
fn a_disagreeing_exif_resolution_beats_the_container_density() {
    let dir = TempDir::new().unwrap();
    let exif = build_exif(false, 1, (300, 300), None, false);
    let mut file = jpeg_with(
        &opaque_pattern(6, 4),
        92,
        &[jpeg_segment(0xE1, b"Exif\0\0", &exif.bytes)],
    );
    // The encoder's own APP0: units 1 (dots per inch) at 72 x 72, which
    // contradicts the EXIF pair by more than any rounding.
    let app0 = file
        .windows(5)
        .position(|w| w == b"JFIF\0")
        .expect("a JFIF APP0");
    file[app0 + 7] = 1;
    file[app0 + 8..app0 + 10].copy_from_slice(&72u16.to_be_bytes());
    file[app0 + 10..app0 + 12].copy_from_slice(&72u16.to_be_bytes());
    let doc = open_file(&dir, "both.jpg", &file);
    assert_eq!(
        unsafe { (rz_doc_resolution_x(doc), rz_doc_resolution_y(doc)) },
        (300.0, 300.0),
        "the EXIF pair is the authority"
    );

    // The container is still the fallback when the EXIF says nothing: unit 1
    // ("none") is a bare aspect ratio, not a resolution.
    let mut none_unit = build_exif(false, 1, (300, 300), None, false);
    let unit = ifd0_entry(&none_unit.bytes, 0x0128);
    none_unit.bytes[unit + 8..unit + 10].copy_from_slice(&1u16.to_le_bytes());
    let mut file2 = jpeg_with(
        &opaque_pattern(6, 4),
        92,
        &[jpeg_segment(0xE1, b"Exif\0\0", &none_unit.bytes)],
    );
    let app0 = file2
        .windows(5)
        .position(|w| w == b"JFIF\0")
        .expect("a JFIF APP0");
    file2[app0 + 7] = 1;
    file2[app0 + 8..app0 + 10].copy_from_slice(&200u16.to_be_bytes());
    file2[app0 + 10..app0 + 12].copy_from_slice(&200u16.to_be_bytes());
    let doc2 = open_file(&dir, "fallback.jpg", &file2);
    assert_eq!(
        unsafe { rz_doc_resolution_x(doc2) },
        200.0,
        "with no usable EXIF pair the container's density carries it"
    );

    unsafe {
        rz_doc_free(doc2);
        rz_doc_free(doc);
    }
}

/// The orientation reset is mandatory, so a packet whose queued edits would
/// overwrite each other is refused WHOLE rather than written half-applied.
///
/// A crafted XResolution value offset can point at the Orientation entry's
/// own four-byte field: the eight-byte rational then lands on top of the
/// reset (and on the tag and type of the entry after it), and the export
/// would carry a stale rotation while reporting the EXIF as written.
#[test]
fn an_exif_packet_whose_patches_collide_is_refused_whole() {
    let dir = TempDir::new().unwrap();
    let doc = doc_from(&dir, "collide.png", &opaque_pattern(4, 4));

    // The orientation entry's value field, aimed at by XResolution.
    let mut hostile = build_exif(false, 6, (72, 72), None, false);
    let x_entry = ifd0_entry(&hostile.bytes, 0x011A);
    let orientation_field = hostile.orientation_field as u32;
    hostile.bytes[x_entry + 8..x_entry + 12].copy_from_slice(&orientation_field.to_le_bytes());
    let doc1 = with_packet(doc, METADATA_EXIF, &hostile.bytes);
    let (bytes, carried) = save(
        doc1,
        &dir.path().join("collide.jpg"),
        FORMAT_JPEG,
        true,
        false,
    );
    assert_eq!(
        carried & CARRIES_EXIF,
        0,
        "the packet is refused, not half-written"
    );
    assert!(
        jpeg_payload(&bytes, 0xE1, b"Exif\0\0").is_none(),
        "and nothing claims to be an EXIF block"
    );

    // Two rationals that overlap by four bytes — the partial-overlap the
    // "same offset" check alone never caught.
    let mut shifted = build_exif(false, 1, (72, 72), None, false);
    let y_entry = ifd0_entry(&shifted.bytes, 0x011B);
    let overlapping = (shifted.rationals + 4) as u32;
    shifted.bytes[y_entry + 8..y_entry + 12].copy_from_slice(&overlapping.to_le_bytes());
    let doc2 = with_packet(doc, METADATA_EXIF, &shifted.bytes);
    let (bytes2, carried2) = save(
        doc2,
        &dir.path().join("overlap.jpg"),
        FORMAT_JPEG,
        true,
        false,
    );
    assert_eq!(carried2 & CARRIES_EXIF, 0);
    assert!(jpeg_payload(&bytes2, 0xE1, b"Exif\0\0").is_none());

    // A sub-IFD pointer landing INSIDE IFD0 is the same class: its
    // "entries" are IFD0's own bytes read at a shifted offset.
    let mut inside = build_exif(false, 1, (72, 72), Some((4, 4)), false);
    let sub_entry = ifd0_entry(&inside.bytes, 0x8769);
    let ifd0 = u32::from_le_bytes(inside.bytes[4..8].try_into().unwrap());
    inside.bytes[sub_entry + 8..sub_entry + 12].copy_from_slice(&(ifd0 + 2).to_le_bytes());
    let doc3 = with_packet(doc, METADATA_EXIF, &inside.bytes);
    let (bytes3, carried3) = save(doc3, &dir.path().join("sub.jpg"), FORMAT_JPEG, true, false);
    assert_eq!(carried3 & CARRIES_EXIF, 0);
    assert!(jpeg_payload(&bytes3, 0xE1, b"Exif\0\0").is_none());

    // The same packets with honest offsets still travel, so the guard is
    // not simply refusing everything.
    let good = build_exif(false, 6, (72, 72), Some((4, 4)), false);
    let doc4 = with_packet(doc, METADATA_EXIF, &good.bytes);
    let (bytes4, carried4) = save(doc4, &dir.path().join("good.jpg"), FORMAT_JPEG, true, false);
    assert!(carried4 & CARRIES_EXIF != 0);
    let written = jpeg_payload(&bytes4, 0xE1, b"Exif\0\0").expect("an APP1");
    assert_eq!(ifd0_inline(&written, 0x0112), 1, "orientation reset");

    unsafe {
        rz_doc_free(doc4);
        rz_doc_free(doc3);
        rz_doc_free(doc2);
        rz_doc_free(doc1);
        rz_doc_free(doc);
    }
}

/// A resolution datum is written where the ENTRY says its data lives, and
/// nowhere else. Two crafted offsets pass every bounds check and still
/// destroy the packet, so both refuse it whole rather than writing a block
/// no reader can parse while reporting the EXIF as carried.
#[test]
fn a_resolution_datum_outside_its_own_storage_refuses_the_packet() {
    let dir = TempDir::new().unwrap();
    let doc = doc_from(&dir, "aim.png", &opaque_pattern(8, 6));

    // (a) A value offset of 0: eight bytes over the packet's own TIFF
    // header, which costs it the byte-order mark and the magic 42.
    let mut at_header = build_exif(false, 1, (72, 72), None, false);
    let x_entry = ifd0_entry(&at_header.bytes, 0x011A);
    at_header.bytes[x_entry + 8..x_entry + 12].copy_from_slice(&0u32.to_le_bytes());
    let doc1 = with_packet(doc, METADATA_EXIF, &at_header.bytes);
    let (bytes, carried) = save(
        doc1,
        &dir.path().join("header.jpg"),
        FORMAT_JPEG,
        true,
        false,
    );
    assert_eq!(carried & CARRIES_EXIF, 0, "the packet is refused");
    assert!(jpeg_payload(&bytes, 0xE1, b"Exif\0\0").is_none());
    // The save itself is unaffected: the picture and its density travel.
    let back = open_file(&dir, "re-header.jpg", &bytes);
    assert_eq!(unsafe { rz_doc_resolution_x(back) }, 72.0);
    unsafe { rz_doc_free(back) };

    // (b) A value offset inside ANOTHER tag's out-of-line datum — here an
    // ASCII string covering the rationals, standing in for the MakerNote
    // this silently corrupted.
    let mut inside_datum = build_exif(false, 1, (72, 72), Some((8, 6)), false);
    let length_entry = ifd0_entry(&inside_datum.bytes, 0x0101);
    inside_datum.bytes[length_entry + 2..length_entry + 4].copy_from_slice(&2u16.to_le_bytes());
    inside_datum.bytes[length_entry + 4..length_entry + 8].copy_from_slice(&24u32.to_le_bytes());
    inside_datum.bytes[length_entry + 8..length_entry + 12]
        .copy_from_slice(&(inside_datum.rationals as u32).to_le_bytes());
    let doc2 = with_packet(doc, METADATA_EXIF, &inside_datum.bytes);
    let (bytes2, carried2) = save(
        doc2,
        &dir.path().join("datum.jpg"),
        FORMAT_JPEG,
        true,
        false,
    );
    assert_eq!(carried2 & CARRIES_EXIF, 0);
    assert!(jpeg_payload(&bytes2, 0xE1, b"Exif\0\0").is_none());

    unsafe {
        rz_doc_free(doc2);
        rz_doc_free(doc1);
        rz_doc_free(doc);
    }
}

/// A JPEG or PNG carries the orientation and the resolution TWICE — once in
/// the EXIF block and once as `tiff:` properties in its XMP packet — and
/// XMP's own reconciliation rules make the XMP copy the authority for a
/// property present in both. Resetting only the EXIF one left Bridge, Camera
/// Raw and every other XMP-first reader rotating the picture 90 degrees and
/// showing it at the source file's ppi, which is exactly the double rotation
/// the reset exists to prevent.
///
/// Both spellings XMP uses for a simple property are rewritten: an
/// `rdf:Description` attribute and a child element.
#[test]
fn the_xmp_packet_is_normalized_like_the_exif_one() {
    let dir = TempDir::new().unwrap();
    // Attributes for two properties and elements for the other two, which is
    // how writers actually mix them.
    let packet = b"<?xpacket begin=\"\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>\
<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF \
xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">\
<rdf:Description rdf:about=\"\" xmlns:tiff=\"http://ns.adobe.com/tiff/1.0/\" \
tiff:Orientation=\"6\" tiff:XResolution=\"72/1\">\
<tiff:YResolution>72/1</tiff:YResolution>\
<tiff:ResolutionUnit>3</tiff:ResolutionUnit>\
<tiff:Model>A Camera</tiff:Model>\
</rdf:Description></rdf:RDF></x:xmpmeta><?xpacket end=\"w\"?>"
        .to_vec();
    let exif = build_exif(false, 6, (72, 72), None, false);
    let file = jpeg_with(
        &opaque_pattern(8, 6),
        95,
        &[
            jpeg_segment(0xE1, b"Exif\0\0", &exif.bytes),
            jpeg_segment(0xE1, XMP_ID, &packet),
        ],
    );
    let doc = open_file(&dir, "xmp.jpg", &file);
    // The rotation is already in the pixels, and the document's own ppi is
    // what the export has to state.
    assert_eq!(unsafe { (rz_doc_width(doc), rz_doc_height(doc)) }, (6, 8));
    let doc = apply(doc, |d| unsafe { rz_doc_set_resolution(d, 300.0, 300.0) });
    assert_eq!(
        packet_str(doc, METADATA_XMP),
        String::from_utf8(packet.clone()).unwrap(),
        "the STORED packet is byte-exact — only the export is rewritten"
    );

    for (format, name) in [(FORMAT_JPEG, "xmp-out.jpg"), (FORMAT_PNG, "xmp-out.png")] {
        let (bytes, carried) = save(doc, &dir.path().join(name), format, true, false);
        assert!(carried & CARRIES_XMP != 0, "{name}");
        let written = String::from_utf8(written_xmp(&bytes, format)).expect("UTF-8");
        assert!(
            written.contains("tiff:Orientation=\"1\""),
            "{name}: the attribute spelling is reset: {written}"
        );
        assert!(
            written.contains("tiff:XResolution=\"300/1\""),
            "{name}: {written}"
        );
        assert!(
            written.contains("<tiff:YResolution>300/1</tiff:YResolution>"),
            "{name}: the element spelling too: {written}"
        );
        assert!(
            written.contains("<tiff:ResolutionUnit>2</tiff:ResolutionUnit>"),
            "{name}: counted in inches: {written}"
        );
        assert!(
            written.contains("<tiff:Model>A Camera</tiff:Model>"),
            "{name}: every other property is untouched: {written}"
        );
        assert!(
            written.starts_with("<?xpacket begin") && written.ends_with("<?xpacket end=\"w\"?>"),
            "{name}: the packet's own wrapper survives"
        );
    }
    unsafe { rz_doc_free(doc) };
}

/// The normalizer rewrites what it finds and invents nothing: a property the
/// packet does not carry is never inserted (the EXIF block and the container
/// density already state the same numbers), and a spelling it does not
/// recognize is left exactly as it was rather than half-edited.
#[test]
fn the_xmp_normalizer_inserts_nothing_and_half_edits_nothing() {
    let dir = TempDir::new().unwrap();
    let packet = b"<x:xmpmeta xmlns:x=\"adobe:ns:meta/\">\
<rdf:Description dc:title=\"tiff:Orientation is not a property here\" \
tiff:OrientationHint=\"6\"><tiff:Orientation/></rdf:Description></x:xmpmeta>"
        .to_vec();
    let doc = doc_from(&dir, "plain.png", &opaque_pattern(4, 4));
    let doc = set_packet(doc, METADATA_XMP, &packet);
    let (bytes, carried) = save(
        doc,
        &dir.path().join("plain-out.png"),
        FORMAT_PNG,
        true,
        false,
    );
    assert!(carried & CARRIES_XMP != 0);
    assert_eq!(
        written_xmp(&bytes, FORMAT_PNG),
        packet,
        "no resolution property is invented, and neither a name that merely \
         contains one nor a self-closing element is rewritten"
    );
    unsafe { rz_doc_free(doc) };
}

/// Exif 2.32 §4.6.5: ColorSpace 1 means sRGB and 0xFFFF ("Uncalibrated")
/// means the space is the one the embedded profile names. A camera's 1 left
/// beside a Display P3 profile tells every reader that honours the tag — and
/// every pipeline that keeps EXIF while stripping ICC — to read P3 numbers
/// as sRGB, which shows up as a visibly oversaturated picture.
#[test]
fn the_exif_colour_space_tag_follows_the_document() {
    let dir = TempDir::new().unwrap();
    let exif = build_exif(false, 1, (72, 72), Some((8, 6)), false);
    let field = exif.color_space_field.expect("a sub-IFD with ColorSpace");
    let doc = doc_from(&dir, "space.png", &opaque_pattern(8, 6));
    let doc = set_packet(doc, METADATA_EXIF, &exif.bytes);

    // An sRGB document keeps the camera's 1.
    let (bytes, _) = save(doc, &dir.path().join("srgb.jpg"), FORMAT_JPEG, true, false);
    let out = jpeg_payload(&bytes, 0xE1, b"Exif\0\0").expect("an Exif APP1");
    assert_eq!(u16::from_le_bytes([out[field], out[field + 1]]), 1);

    // Converting the document to Display P3 makes it "Uncalibrated" — the
    // value Photoshop and Lightroom write for a non-sRGB export.
    let p3 = builtin_bytes(1);
    let converted = apply(doc, |d| unsafe {
        rz_doc_convert_to_profile(d, p3.as_ptr(), p3.len())
    });
    let (bytes, carried) = save(
        converted,
        &dir.path().join("p3.jpg"),
        FORMAT_JPEG,
        true,
        false,
    );
    assert!(carried & (CARRIES_PROFILE | CARRIES_EXIF) != 0);
    let out = jpeg_payload(&bytes, 0xE1, b"Exif\0\0").expect("an Exif APP1");
    assert_eq!(u16::from_le_bytes([out[field], out[field + 1]]), 0xFFFF);
    // The dimensions beside it are still patched, and the block never grew.
    assert_eq!(out.len(), exif.bytes.len());
    unsafe { rz_doc_free(converted) };
}

/// `rz_path_metadata_walked` answers what an open of that file would do with
/// its capture data, so a host can say "the capture data was never read in"
/// for every container the walk skips — not only for the ones a platform
/// decoder produced. A TIFF or a WebP really can carry an EXIF block; this
/// build's open drops it.
#[test]
fn metadata_walked_names_the_containers_the_walk_reads() {
    let dir = TempDir::new().unwrap();
    let pixels = opaque_pattern(6, 4);
    let doc = doc_from(&dir, "walk.png", &pixels);

    let walked = |name: &str| {
        let c = cpath(&dir.path().join(name));
        unsafe { rz_path_metadata_walked(c.as_ptr()) }
    };
    for (format, name, expected) in [
        (FORMAT_PNG, "w.png", true),
        (FORMAT_JPEG, "w.jpg", true),
        (FORMAT_TIFF, "w.tif", false),
        (FORMAT_WEBP, "w.webp", false),
        (FORMAT_BMP, "w.bmp", false),
        (FORMAT_GIF, "w.gif", false),
    ] {
        save(doc, &dir.path().join(name), format, true, false);
        assert_eq!(walked(name), expected, "{name}");
    }
    // The native format carries its packets itself.
    let native = dir.path().join("w.rz");
    let c = cpath(&native);
    let mut err: *mut c_char = ptr::null_mut();
    assert!(unsafe { rz_doc_save_native(doc, c.as_ptr(), &mut err) });
    assert!(
        walked("w.rz"),
        "a .rz stores the packets rather than being walked"
    );

    assert!(
        !walked("nothing-here.jpg"),
        "an unreadable file is not walked"
    );
    assert!(
        !unsafe { rz_path_metadata_walked(ptr::null()) },
        "and a NULL path is not"
    );
    unsafe { rz_doc_free(doc) };
}
