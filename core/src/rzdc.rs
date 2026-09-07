//! The RZDC native document format: encoder, atomic writer and
//! bounds-checked reader, plus the hard caps both sides enforce. The doc
//! comment on [`RzDocument::encode_native`] IS the format spec.

use std::sync::Arc;

use image::codecs::png::PngEncoder;
use image::{ExtendedColorType, GrayImage, ImageEncoder};

use crate::blend::BlendMode;
use crate::doc::{sane_opacity, Layer, LayerKind, RzDocument, MAX_PIXELS};
use crate::doc_channel::{Channel, MAX_CHANNELS};
use crate::doc_group::{validate_structure, MAX_GROUP_DEPTH};
use crate::doc_lock::LOCK_ALL;
use crate::icc::IccProfile;
use crate::metadata::{Metadata, Resolution};
use crate::rz_image::save_atomically;
use crate::style::{GlobalLight, LayerStyle};

/// Hard caps applied while reading RZDC files so corrupt headers cannot ask
/// for absurd allocations. The meta cap is shared by BOTH per-layer string
/// slots (meta and the layer style) and is also what the FFI meta and style
/// setters enforce, so a document can never carry a string the writer would
/// refuse. Channel names share the layer-name slot rule (same cap, same
/// truncation, same `put_name` writer).
pub(crate) const MAX_RZDC_LAYERS: u32 = 1024;
const MAX_RZDC_NAME_LEN: u32 = 64 * 1024;
const MAX_RZDC_PNG_LEN: u32 = 512 * 1024 * 1024;
pub(crate) const MAX_RZDC_META_LEN: u32 = 16 * 1024 * 1024;

/// Cap on EACH of the four document blobs the version-6 tail carries — the
/// ICC profile and the EXIF, XMP and IPTC packets — applied independently,
/// so a crafted file tops out at 64 MiB of blob next to the 1.6 GB of layer
/// pixels [`MAX_RZDC_TOTAL_LAYER_PIXELS`] already admits. There is no total
/// budget and none is needed: unlike channels, blobs are not multiplied by
/// the canvas size.
///
/// 16 MiB is deliberately just ABOVE what any JPEG can carry: an ICC profile
/// travels in at most 255 APP2 chunks of 65533 - 14 payload bytes
/// (16 707 345 bytes = 15.93 MiB, the same arithmetic `image`'s JPEG encoder
/// does). So no blob that arrived in a JPEG can ever be refused on the way
/// out, while a hand-built profile (a CMYK device link is the large real
/// case, a few MB) is far inside it. The FFI setters enforce it too, so a
/// document can never hold a blob the writer would refuse.
///
/// Separate from [`MAX_RZDC_META_LEN`] on purpose: that one is a *string*
/// cap the FFI meta and style setters also enforce, and raising one must not
/// silently raise the other.
pub(crate) const MAX_RZDC_BLOB_LEN: u32 = 16 * 1024 * 1024;

/// The RZDC revision this build writes. Version 1 files (no mask, no layer
/// meta), version 2 files (no clipped flag), version 3 files (no layer style,
/// no global light), version 4 files (no channels), version 5 files (no
/// colour profile, no metadata packets, no resolution) and version 6 files
/// (no group structure, no locks, no links) still load; anything newer is
/// refused.
const RZDC_VERSION: u32 = 7;

/// Parse-time ceiling on the canvas area a file's ISOLATED groups could ask
/// the compositor for: the canvas pixel count summed over every Group record
/// whose STORED properties already force isolation. It is a cheap, friendly
/// refusal for an absurd file — checked before a single layer PNG is decoded —
/// and deliberately NOT the guarantee, which is `doc_group`'s runtime
/// `MAX_GROUP_BUFFER_PIXELS`: that one is charged before every allocation and
/// released when the buffer is dropped, so it bounds what a NEST holds at
/// once whatever the file says, and it is the only check that can be right,
/// because a group's real extent and the `has_visible_clipped_members`
/// isolation are not knowable from stored properties alone.
///
/// SIXTY-FOUR canvases, not the runtime budget's four, and the two numbers do
/// not compare because they do not measure the same thing. This one is a SUM
/// over every isolated group in the file — the only quantity a parse can
/// compute, since a group's real extent is not knowable from stored
/// properties — while the runtime budget is a PEAK over the buffers alive at
/// once, which sibling groups never add to (each is dropped before the next
/// is built). Sixty-four sibling groups therefore cost the compositor ONE
/// canvas, not sixty-four, and this check refuses only the shape whose
/// sheer count says the file is not a document. It over-counts a real one
/// badly if made tight: at four canvases a perfectly ordinary 24 MP composite
/// would be refused at SIXTEEN isolated groups, and refusing to open (or
/// save) a real document is far worse than rendering a crafted one slowly.
/// Sixty-four puts the line at 266 isolated groups on that canvas and 64 on
/// the largest canvas this build allows, which no hand-made document reaches
/// and which still catches the "one tiny file, tens of gigabytes" shape
/// early.
const MAX_RZDC_GROUP_CANVAS_PIXELS: u64 = 64 * MAX_PIXELS;

/// Ceiling on the SUM of decoded layer pixels across one RZDC file: even when
/// every individual layer looks reasonable, a crafted file must not be able
/// to stack layers until memory is exhausted.
const MAX_RZDC_TOTAL_LAYER_PIXELS: u64 = 4 * MAX_PIXELS;

/// The same ceiling for the channel list. The COUNT cap
/// (`doc_channel::MAX_CHANNELS`) alone is not enough: 256 channels on a
/// 24 MP canvas is 6.4 GB of coverage, so the reader also checks the total —
/// and, unlike layers, it can do so UP FRONT, because a channel's size is
/// always the canvas's and the count is in the header.
///
/// NINE full canvases, deliberately: `add_luminosity_masks` appends exactly
/// nine canvas-sized planes, so any smaller multiple makes the feature refuse
/// itself on a large canvas. At four it did — a 45 MP camera file (8192 x
/// 5464, the size the feature exists for) allowed only eight channels, so the
/// nine masks were refused on a document with no channels to delete. At nine
/// the whole set fits the largest canvas any op will build (`MAX_PIXELS`),
/// which is the invariant worth having: an op that creates channels is never
/// refused for a reason the user cannot act on. A crafted file is still
/// bounded — 900 MB of coverage, well under the 1.6 GB of layer pixels
/// `MAX_RZDC_TOTAL_LAYER_PIXELS` already admits.
///
/// `doc_channel::channels_fit` enforces the same number at CREATION time, so
/// for a document this build made the writer's check can never fire; it is
/// there so the writer provably enforces every cap the reader does.
pub(crate) const MAX_RZDC_TOTAL_CHANNEL_PIXELS: u64 = 9 * MAX_PIXELS;

impl RzDocument {
    /// Serializes to the RZDC layout (see the header comment): "RZDC",
    /// u32 version, u32 width, u32 height, u32 layer count; per layer
    /// bottom-to-top: u32 name len + UTF-8 name, i32 off x, i32 off y,
    /// f32 opacity, u32 blend, u8 visible, u32 PNG len + PNG pixels.
    /// All integers little-endian.
    ///
    /// Version 2 appends three fields to each layer record, after the pixel
    /// PNG (so a version-1 record is a strict prefix of a version-2 one):
    /// u8 mask present, u8 mask enabled, u32 mask len + that many RAW
    /// coverage bytes when present (the mask's dimensions are the layer's
    /// pixel dimensions and are not stored twice), then u8 meta present and,
    /// when present, u32 meta len + UTF-8 meta bytes.
    ///
    /// Version 3 appends one more field after all the version-2 fields (so a
    /// version-2 record is in turn a strict prefix of a version-3 one):
    /// u8 clipped.
    ///
    /// Version 4 adds two document fields right after the layer count — f32
    /// global-light angle, f32 global-light altitude (degrees) — and one more
    /// per-layer field after the version-3 clipped byte (a version-3 record
    /// is a strict prefix of a version-4 one): u8 style present and, when
    /// present, u32 style len + UTF-8 canonical style JSON (see `style`),
    /// encoded and capped exactly like meta.
    ///
    /// Version 5 appends the ALPHA CHANNEL list after the LAST LAYER RECORD,
    /// so a version-4 file is a strict prefix of a version-5 one: u32 channel
    /// count (at most `doc_channel::MAX_CHANNELS`), then per channel u32 name
    /// byte length + UTF-8 name (truncated exactly like a layer name), u8
    /// overlay red, u8 green, u8 blue, f32 overlay opacity, u8 "color
    /// indicates selected" (0 — the default — means the wash covers the
    /// MASKED areas, matching Quick Mask; any non-zero value reads as 1), and
    /// u32 PNG byte length + a PNG-encoded 8-bit GRAYSCALE (L8) plane of
    /// exactly the canvas size (a channel is always canvas-sized, so its
    /// dimensions are not stored twice). The plane is PNG-compressed rather
    /// than raw like a layer mask because a channel is always the WHOLE
    /// canvas: nine luminosity masks on a 24 MP canvas would be 216 MB raw,
    /// and coverage planes are exactly the flat, large-run data PNG's filters
    /// collapse. `Channel::id` is NOT written: it is a per-process handle a
    /// host hangs view state on, minted fresh whenever a channel is created,
    /// this reader included.
    ///
    /// Version 6 appends the DOCUMENT TAIL after the channel list, so a
    /// version-5 file is a strict prefix of a version-6 one: f32 horizontal
    /// resolution and f32 vertical resolution in pixels per inch (sanitized
    /// by [`Resolution::sane`] on both sides — non-finite or non-positive
    /// takes the 72 ppi default, finite values clamp to [1, 30000] and
    /// quantize to four decimals, exactly like the global light), then FOUR
    /// optional blobs in this order — the ICC colour profile, the EXIF
    /// packet, the XMP packet and the IPTC packet — each written as u8
    /// present and, when present, u32 byte length + that many RAW bytes,
    /// capped at [`MAX_RZDC_BLOB_LEN`] each. The blobs are stored VERBATIM
    /// and never interpreted here: they are what the file they came from
    /// carried, and the export path splices them back. Unlike meta and the
    /// style they are NOT UTF-8 (an ICC profile and an EXIF packet are
    /// binary; XMP merely happens to be XML), so they take the byte helpers
    /// rather than the string ones.
    ///
    /// The ICC slot is written ABSENT when the document's profile is the
    /// built-in sRGB, and an absent slot reads back as that same profile —
    /// so a plain document does not grow by 2.5 KB, and a blob-less
    /// version-6 file is a version-5 file plus exactly 12 bytes.
    ///
    /// Version 7 appends TWELVE bytes to each layer record, immediately after
    /// the version-4 style slot, so a version-6 RECORD is a strict prefix of a
    /// version-7 one: u32 lock flags (bits 0..2 meaningful — transparency,
    /// pixels, position; the reader masks 3..31 off), u32 link-group id (0 =
    /// unlinked), u16 nesting depth (0 = top level), u8 kind (0 = raster,
    /// 1 = group; any other value is REFUSED) and u8 group-open, the panel
    /// disclosure flag, which is meaningless on a raster entry. WHOLE-FILE
    /// prefixing does NOT hold for version 7: the bytes go inside each record,
    /// so a version-6 file is not a byte-prefix of the version-7 file of the
    /// same document — exactly as version 4 already broke it, and for the same
    /// reason.
    ///
    /// A GROUP entry's pixel PNG is a 1x1 fully transparent PNG (~70 bytes),
    /// so the record layout stays uniform and the writer needs no conditional
    /// shape; a group has no pixels of its own and nothing ever reads them.
    /// Its `off x` / `off y` are not a pixel position either but where that
    /// canvas-sized mask SITS: a group's mask travels with the group as
    /// bookkeeping on this offset rather than as a resample per move
    /// (`doc_align::translate_entry`), and persisting it is what makes a save
    /// round trip lossless for a group that has been dragged. It is (0, 0) for
    /// a group with no mask and for every version-1 to -6 file, which has no
    /// groups at all. Its MASK is CANVAS-sized rather than layer-sized
    /// (`doc_group`), which is the one place the record's shape depends on a
    /// field written LATER than the mask:
    ///
    /// * the writer takes the expected dimensions from
    ///   [`expected_mask_dims`] — the layer's for a raster entry, the
    ///   canvas's for a group — so a group mask is never silently written as
    ///   ABSENT by a filter that only knows the layer's size;
    /// * the reader DEFERS building the mask image until the kind byte has
    ///   been read. It accepts a stored `mask_len` equal to EITHER the decoded
    ///   pixel count OR the canvas's, keeps the bytes, and only after the
    ///   version-7 fields builds the `GrayImage` at the size the kind
    ///   requires, refusing a wrong pairing (a raster mask sized to the
    ///   canvas, or a group mask sized to the layer). For every version-1 to
    ///   -6 file the kind is always Raster, so the widened acceptance can only
    ///   defer a refusal that the later check then makes identically — no
    ///   older file changes outcome.
    ///
    /// The whole depth sequence is checked for well-formedness at both ends
    /// (`doc_group::validate_structure`): the writer refuses to produce a file
    /// it could not read back, and the reader refuses a crafted one rather
    /// than loading a stack whose entries would silently vanish from every
    /// projection.
    fn encode_native(&self) -> Result<Vec<u8>, String> {
        // The writer enforces the reader's caps, so every file it produces
        // can be read back: layer count and per-layer PNG size are hard
        // errors, over-long names are truncated on a char boundary.
        let count = u32::try_from(self.layers.len())
            .ok()
            .filter(|&c| c <= MAX_RZDC_LAYERS)
            .ok_or_else(|| format!("too many layers (max {MAX_RZDC_LAYERS})"))?;
        // The writer enforces the reader's structural rules too, so a document
        // this build holds is always one it can read back.
        if !validate_structure(&self.layers) {
            return Err("malformed layer group structure".to_string());
        }
        if let Some(deep) = self.layers.iter().find(|l| l.depth > MAX_GROUP_DEPTH) {
            return Err(format!(
                "layer nesting deeper than {MAX_GROUP_DEPTH} levels ({})",
                deep.depth
            ));
        }
        if isolated_group_pixels(&self.layers, self.width, self.height)
            > MAX_RZDC_GROUP_CANVAS_PIXELS
        {
            return Err("layer groups would need more memory than this build allows".to_string());
        }
        let mut buf = Vec::new();
        buf.extend_from_slice(b"RZDC");
        buf.extend_from_slice(&RZDC_VERSION.to_le_bytes());
        buf.extend_from_slice(&self.width.to_le_bytes());
        buf.extend_from_slice(&self.height.to_le_bytes());
        buf.extend_from_slice(&count.to_le_bytes());
        // Version 4 document fields.
        let light = self.global_light.sane();
        buf.extend_from_slice(&light.angle.to_le_bytes());
        buf.extend_from_slice(&light.altitude.to_le_bytes());
        for layer in &self.layers {
            put_name(&mut buf, &layer.name);
            buf.extend_from_slice(&layer.offset.0.to_le_bytes());
            buf.extend_from_slice(&layer.offset.1.to_le_bytes());
            buf.extend_from_slice(&layer.opacity.to_le_bytes());
            buf.extend_from_slice(&(layer.blend.to_c() as u32).to_le_bytes());
            buf.push(u8::from(layer.visible));
            let mut png = Vec::new();
            let (lw, lh) = layer.pixels.dimensions();
            PngEncoder::new(&mut png)
                .write_image(layer.pixels.as_raw(), lw, lh, ExtendedColorType::Rgba8)
                .map_err(|e| format!("PNG encoding failed: {e}"))?;
            let png_len = u32::try_from(png.len())
                .ok()
                .filter(|&len| len <= MAX_RZDC_PNG_LEN)
                .ok_or_else(|| "layer PNG too large".to_string())?;
            buf.extend_from_slice(&png_len.to_le_bytes());
            buf.extend_from_slice(&png);
            // Version 2 fields. The mask is stored raw: its length is always
            // the pixel count the entry's KIND requires — the layer's for a
            // raster entry, the CANVAS's for a group (`expected_mask_dims`) —
            // which the reader re-derives and checks, so a mask that somehow
            // broke that invariant is written as absent rather than as a file
            // that cannot be read back. Taking the dimensions from the layer
            // alone would write every group mask as ABSENT.
            let dims = expected_mask_dims(layer, self.width, self.height);
            let mask = layer.mask.as_deref().filter(|m| m.dimensions() == dims);
            buf.push(u8::from(mask.is_some()));
            buf.push(u8::from(layer.mask_enabled));
            if let Some(mask) = mask {
                let bytes = mask.as_raw();
                let mask_len =
                    u32::try_from(bytes.len()).map_err(|_| "layer mask too large".to_string())?;
                buf.extend_from_slice(&mask_len.to_le_bytes());
                buf.extend_from_slice(bytes);
            }
            put_opt_string(&mut buf, layer.meta.as_deref(), "meta")?;
            // Version 3 field.
            buf.push(u8::from(layer.clipped));
            // Version 4 field: the canonical style JSON.
            let style = layer.style.as_ref().map(|s| s.to_json());
            put_opt_string(&mut buf, style.as_deref(), "style")?;
            // Version 7 fields, twelve bytes: the structure, the locks and the
            // link. Reserved lock bits are masked off on the way out as well
            // as on the way in, so a file never carries a bit this build does
            // not understand.
            buf.extend_from_slice(&(layer.locks & LOCK_ALL).to_le_bytes());
            buf.extend_from_slice(&layer.link.to_le_bytes());
            buf.extend_from_slice(&layer.depth.to_le_bytes());
            buf.push(match layer.kind {
                LayerKind::Raster => 0,
                LayerKind::Group => 1,
            });
            buf.push(u8::from(layer.open));
        }
        // Version 5: the alpha channel list, after the last layer record.
        // Every cap the reader enforces is enforced here too — the count, the
        // total pixel budget (which the reader checks up front from this very
        // count) and the per-channel PNG size — so no document this build can
        // build is one it cannot read back.
        let channel_count = u32::try_from(self.channels.len())
            .ok()
            .filter(|&c| c as usize <= MAX_CHANNELS)
            .ok_or_else(|| format!("too many channels (max {MAX_CHANNELS})"))?;
        let total_channel_pixels =
            u64::from(channel_count) * u64::from(self.width) * u64::from(self.height);
        if total_channel_pixels > MAX_RZDC_TOTAL_CHANNEL_PIXELS {
            return Err(format!(
                "total channel pixels exceed {MAX_RZDC_TOTAL_CHANNEL_PIXELS}"
            ));
        }
        buf.extend_from_slice(&channel_count.to_le_bytes());
        for channel in &self.channels {
            let (cw, ch) = channel.data.dimensions();
            if (cw, ch) != (self.width, self.height) {
                // The model's invariant; a broken one would write a file the
                // reader must reject, so refuse to write it at all.
                return Err(format!(
                    "channel plane {cw}x{ch} does not match the {}x{} canvas",
                    self.width, self.height
                ));
            }
            put_name(&mut buf, &channel.name);
            buf.extend_from_slice(&channel.overlay_color);
            buf.extend_from_slice(&sane_opacity(channel.overlay_opacity).to_le_bytes());
            buf.push(u8::from(channel.color_indicates_selected));
            let mut png = Vec::new();
            PngEncoder::new(&mut png)
                .write_image(channel.data.as_raw(), cw, ch, ExtendedColorType::L8)
                .map_err(|e| format!("PNG encoding failed: {e}"))?;
            let png_len = u32::try_from(png.len())
                .ok()
                .filter(|&len| len <= MAX_RZDC_PNG_LEN)
                .ok_or_else(|| "channel PNG too large".to_string())?;
            buf.extend_from_slice(&png_len.to_le_bytes());
            buf.extend_from_slice(&png);
        }
        // Version 6: the document tail, after the channel list. Every cap the
        // reader enforces is enforced here too, and the resolution is
        // re-sanitized on the way out exactly as the global light is, so no
        // document this build can build is one it cannot read back.
        let res = self.resolution.sane();
        buf.extend_from_slice(&res.x.to_le_bytes());
        buf.extend_from_slice(&res.y.to_le_bytes());
        // The built-in sRGB is the document default and is elided: an absent
        // slot reads back as exactly that profile.
        let icc = if self.profile.is_builtin_srgb() {
            None
        } else {
            Some(&**self.profile.bytes())
        };
        put_opt_bytes(&mut buf, icc, "ICC profile", MAX_RZDC_BLOB_LEN)?;
        let meta = &self.metadata;
        put_opt_bytes(
            &mut buf,
            meta.exif.as_deref(),
            "EXIF packet",
            MAX_RZDC_BLOB_LEN,
        )?;
        put_opt_bytes(
            &mut buf,
            meta.xmp.as_deref(),
            "XMP packet",
            MAX_RZDC_BLOB_LEN,
        )?;
        put_opt_bytes(
            &mut buf,
            meta.iptc.as_deref(),
            "IPTC packet",
            MAX_RZDC_BLOB_LEN,
        )?;
        Ok(buf)
    }

    /// Writes the native RZDC format. Atomic exactly like `RzImage::save`
    /// (the shared [`save_atomically`] helper): the bytes go to a temporary
    /// file in the same directory which is renamed over `path` only on
    /// success, so a failed save never truncates or deletes an existing
    /// destination file.
    pub fn save_native(&self, path: &str) -> Result<(), String> {
        let bytes = self.encode_native()?;
        save_atomically(path, |tmp_path| {
            std::fs::write(tmp_path, &bytes).map_err(|e| format!("failed to create {path}: {e}"))
        })
    }
}

/// Writes a NAME slot — u32 byte length + UTF-8 bytes — truncating an
/// over-long name on a UTF-8 character boundary rather than failing the save.
/// The ONE implementation, shared by the layer loop and the channel loop.
fn put_name(buf: &mut Vec<u8>, name: &str) {
    let mut name = name;
    if name.len() > MAX_RZDC_NAME_LEN as usize {
        let mut end = MAX_RZDC_NAME_LEN as usize;
        while !name.is_char_boundary(end) {
            end -= 1;
        }
        name = &name[..end];
    }
    let bytes = name.as_bytes();
    buf.extend_from_slice(&(bytes.len() as u32).to_le_bytes());
    buf.extend_from_slice(bytes);
}

/// Writes an optional LENGTH-PREFIXED slot — u8 present, then u32 len + that
/// many bytes when present — under `cap`. The ONE implementation: the layer
/// string slots (meta, style) and the version-6 document blobs both go
/// through it. `what` is the whole noun ("layer meta", "ICC profile").
fn put_opt_bytes(
    buf: &mut Vec<u8>,
    value: Option<&[u8]>,
    what: &str,
    cap: u32,
) -> Result<(), String> {
    buf.push(u8::from(value.is_some()));
    if let Some(b) = value {
        let len = u32::try_from(b.len())
            .ok()
            .filter(|&len| len <= cap)
            .ok_or_else(|| format!("{what} too large (max {cap})"))?;
        buf.extend_from_slice(&len.to_le_bytes());
        buf.extend_from_slice(b);
    }
    Ok(())
}

/// Reads a slot written by [`put_opt_bytes`]; the cap error names the slot,
/// and the cap is checked BEFORE a byte is taken.
fn take_opt_bytes(r: &mut Reader<'_>, what: &str, cap: u32) -> Result<Option<Vec<u8>>, String> {
    if r.u8()? == 0 {
        return Ok(None);
    }
    let len = r.u32()?;
    if len > cap {
        return Err(format!("{what} length {len} out of range"));
    }
    Ok(Some(r.take(len as usize)?.to_vec()))
}

/// Writes an optional string slot (meta, style) — the UTF-8 twin of
/// [`put_opt_bytes`], under the shared string cap.
fn put_opt_string(buf: &mut Vec<u8>, value: Option<&str>, what: &str) -> Result<(), String> {
    put_opt_bytes(
        buf,
        value.map(str::as_bytes),
        &format!("layer {what}"),
        MAX_RZDC_META_LEN,
    )
}

/// Reads an optional string slot written by [`put_opt_string`]; the cap
/// error names the slot. Lenient on UTF-8 (lossy), like names and meta.
fn take_opt_string(r: &mut Reader<'_>, what: &str) -> Result<Option<String>, String> {
    Ok(
        take_opt_bytes(r, &format!("layer {what}"), MAX_RZDC_META_LEN)?
            .map(|b| String::from_utf8_lossy(&b).into_owned()),
    )
}

/// The dimensions a layer record's MASK must have: the layer's own pixel
/// size for a raster entry, the CANVAS's for a group, which has no pixel
/// buffer to be the size of (`doc_group`). The ONE definition, shared by the
/// writer's "write it or write it as absent" filter and the reader's
/// deferred construction — the two would otherwise be a matched pair that can
/// drift, and the drift silently DROPS every group mask.
fn expected_mask_dims(layer: &Layer, width: u32, height: u32) -> (u32, u32) {
    match layer.kind {
        LayerKind::Raster => layer.pixels.dimensions(),
        LayerKind::Group => (width, height),
    }
}

/// The canvas area a stack's groups could ask the compositor for: the canvas
/// pixel count summed over every Group entry whose STORED properties already
/// make it allocate a full accumulator — any blend but Pass Through, a style,
/// or its own clipped flag, which ISOLATE it (`doc_group::is_isolated`), plus
/// an opacity below 1 or an enabled mask, which GATE it
/// (`doc_group::composite_gated_pass`) and cost the same one f32 buffer.
///
/// Deliberately conservative in the SAFE direction: a plain pass-through group
/// allocates nothing and is not counted, and the last isolation trigger — a
/// visible CLIPPED member above the group — is not knowable from stored
/// properties alone, which is precisely why this is a friendly early refusal
/// and `doc_group::MAX_GROUP_BUFFER_PIXELS` is the guarantee.
fn isolated_group_pixels(layers: &[Layer], width: u32, height: u32) -> u64 {
    let canvas = u64::from(width) * u64::from(height);
    layers
        .iter()
        .filter(|l| {
            // A mask or a sub-1 opacity no longer ISOLATES a pass-through
            // group (`doc_group::is_isolated`), but it still makes it allocate
            // a full accumulator-sized f32 buffer — `composite_gated_pass`'s
            // copy — so it is still counted here: what this estimates is the
            // canvas area a file's groups can ask the compositor for, not
            // which of them take the isolated path.
            l.kind == LayerKind::Group
                && (l.blend != BlendMode::PassThrough
                    || sane_opacity(l.opacity) < 1.0
                    || (l.mask.is_some() && l.mask_enabled)
                    || l.style.is_some()
                    || l.clipped)
        })
        .fold(0u64, |acc, _| acc.saturating_add(canvas))
}

/// Bounds-checked little-endian reader over an RZDC byte buffer.
struct Reader<'a> {
    bytes: &'a [u8],
    pos: usize,
}

impl<'a> Reader<'a> {
    fn take(&mut self, n: usize) -> Result<&'a [u8], String> {
        let end = self
            .pos
            .checked_add(n)
            .filter(|&e| e <= self.bytes.len())
            .ok_or_else(|| "unexpected end of file".to_string())?;
        let slice = &self.bytes[self.pos..end];
        self.pos = end;
        Ok(slice)
    }

    fn u8(&mut self) -> Result<u8, String> {
        Ok(self.take(1)?[0])
    }

    fn u16(&mut self) -> Result<u16, String> {
        Ok(u16::from_le_bytes(
            self.take(2)?.try_into().expect("2 bytes"),
        ))
    }

    fn u32(&mut self) -> Result<u32, String> {
        Ok(u32::from_le_bytes(
            self.take(4)?.try_into().expect("4 bytes"),
        ))
    }

    fn i32(&mut self) -> Result<i32, String> {
        Ok(i32::from_le_bytes(
            self.take(4)?.try_into().expect("4 bytes"),
        ))
    }

    fn f32(&mut self) -> Result<f32, String> {
        Ok(f32::from_le_bytes(
            self.take(4)?.try_into().expect("4 bytes"),
        ))
    }
}

/// Parses an RZDC buffer of version 1 to 7 (version 1 predates layer masks
/// and layer meta, which default to absent; versions 1 and 2 predate the
/// clipped flag, which defaults to false; versions 1 to 3 predate the layer
/// style and the global light, which default to absent / (120°, 30°);
/// versions 1 to 4 predate the channel list, which defaults to empty;
/// versions 1 to 5 predate the document tail, so the resolution defaults to
/// 72 x 72 ppi, the colour profile to the built-in sRGB and the three
/// metadata packets to absent; versions 1 to 6 predate group structure,
/// locks and links, so every record loads as an unlocked, unlinked, open
/// RASTER entry at depth 0 — a flat stack, exactly what those files hold).
/// Corrupt or truncated input produces `Err`, never a panic; unknown
/// blend-mode values fall back to Normal, unknown LOCK bits are masked off,
/// opacity is clamped, the light and the resolution are sanitized, the four
/// document blobs are length-capped but otherwise uninterpreted, and a style
/// is read LENIENTLY (`LayerStyle::from_json_lenient`: a style from a newer
/// build keeps the effects this build knows; only a structurally malformed
/// style — or an identity — loads as no style).
///
/// What is REFUSED rather than repaired, because each is a RELATION between
/// stored quantities and a guess would be silent data loss: a mask length
/// that matches neither the layer nor the canvas, or that matches the wrong
/// one for the entry's kind (see [`RzDocument::encode_native`]'s deferred
/// mask construction); a kind byte other than 0 or 1; a depth past
/// `doc_group::MAX_GROUP_DEPTH`; a malformed depth SEQUENCE, caught by one
/// `doc_group::validate_structure` walk after the records are read; and a
/// file whose isolated groups declare more canvas area than
/// [`MAX_RZDC_GROUP_CANVAS_PIXELS`], checked as soon as the records are read,
/// which is as early as the information exists — the decoding ahead of it is
/// already bounded by [`MAX_RZDC_TOTAL_LAYER_PIXELS`].
pub(crate) fn parse_native(bytes: &[u8]) -> Result<RzDocument, String> {
    let mut r = Reader { bytes, pos: 0 };
    if r.take(4)? != b"RZDC" {
        return Err("not an RZDC document".to_string());
    }
    let version = r.u32()?;
    if version == 0 || version > RZDC_VERSION {
        return Err(format!("unsupported RZDC version {version}"));
    }
    // Version 1 layer records stop after the pixel PNG; version 2 records
    // after the mask and meta fields; version 3 records after the clipped
    // byte.
    let has_mask_and_meta = version >= 2;
    let has_clipped = version >= 3;
    let has_style = version >= 4;
    let has_channels = version >= 5;
    let has_document_tail = version >= 6;
    // Version 7 records end with the structure, the locks and the link.
    let has_groups = version >= 7;
    let width = r.u32()?;
    let height = r.u32()?;
    if width == 0 || height == 0 || u64::from(width) * u64::from(height) > MAX_PIXELS {
        return Err("invalid canvas size".to_string());
    }
    let count = r.u32()?;
    if count == 0 || count > MAX_RZDC_LAYERS {
        return Err(format!("invalid layer count {count}"));
    }
    // Version 4 document fields; lenient on values, like opacity.
    let global_light = if version >= 4 {
        GlobalLight {
            angle: r.f32()?,
            altitude: r.f32()?,
        }
        .sane()
    } else {
        GlobalLight::default()
    };
    let mut layers = Vec::with_capacity(count as usize);
    let mut total_pixels: u64 = 0;
    for _ in 0..count {
        let name_len = r.u32()?;
        if name_len > MAX_RZDC_NAME_LEN {
            return Err(format!("layer name length {name_len} out of range"));
        }
        let name = String::from_utf8_lossy(r.take(name_len as usize)?).into_owned();
        let off_x = r.i32()?;
        let off_y = r.i32()?;
        let opacity = sane_opacity(r.f32()?);
        let blend_raw = r.u32()?;
        let blend = i32::try_from(blend_raw)
            .ok()
            .and_then(BlendMode::from_c)
            .unwrap_or(BlendMode::Normal);
        let visible = r.u8()? != 0;
        let png_len = r.u32()?;
        if png_len > MAX_RZDC_PNG_LEN {
            return Err(format!("layer PNG length {png_len} out of range"));
        }
        let png = r.take(png_len as usize)?;
        let pixels = image::load_from_memory_with_format(png, image::ImageFormat::Png)
            .map_err(|e| format!("failed to decode layer pixels: {e}"))?
            .to_rgba8();
        let (lw, lh) = pixels.dimensions();
        total_pixels = total_pixels.saturating_add(u64::from(lw) * u64::from(lh));
        if total_pixels > MAX_RZDC_TOTAL_LAYER_PIXELS {
            return Err(format!(
                "total layer pixels exceed {MAX_RZDC_TOTAL_LAYER_PIXELS}"
            ));
        }
        // The mask BYTES are taken here but the image is NOT built yet: a
        // group's mask is canvas-sized and a raster layer's is layer-sized,
        // and the kind byte that tells them apart comes later in the record.
        // Both lengths are accepted now and the pairing is checked once the
        // kind is known, which for every version-1 to -6 file (always Raster)
        // can only defer a refusal that is then made identically.
        let mut mask_raw: Option<Vec<u8>> = None;
        let mut mask_enabled = true;
        let mut meta = None;
        let layer_px = u64::from(lw) * u64::from(lh);
        let canvas_px = u64::from(width) * u64::from(height);
        if has_mask_and_meta {
            let present = r.u8()? != 0;
            mask_enabled = r.u8()? != 0;
            if present {
                let mask_len = r.u32()?;
                if u64::from(mask_len) != layer_px && u64::from(mask_len) != canvas_px {
                    return Err(format!(
                        "layer mask length {mask_len} does not match the layer's {layer_px} pixels"
                    ));
                }
                mask_raw = Some(r.take(mask_len as usize)?.to_vec());
            }
            meta = take_opt_string(&mut r, "meta")?;
        }
        let clipped = has_clipped && r.u8()? != 0;
        let style = if has_style {
            take_opt_string(&mut r, "style")?
                .and_then(|s| LayerStyle::from_json_lenient(&s).ok())
                .filter(|s| !s.is_identity())
                .map(Arc::new)
        } else {
            None
        };
        // Version 7 fields. Versions 1-6 have no structure, no locks and no
        // links: every record is a top-level raster layer, which is exactly
        // what those files hold.
        let (locks, link, depth, kind, open) = if has_groups {
            let locks = r.u32()? & LOCK_ALL;
            let link = r.u32()?;
            let depth = r.u16()?;
            if depth > MAX_GROUP_DEPTH {
                return Err(format!(
                    "layer nesting deeper than {MAX_GROUP_DEPTH} levels ({depth})"
                ));
            }
            let kind = match r.u8()? {
                0 => LayerKind::Raster,
                1 => LayerKind::Group,
                other => return Err(format!("unsupported layer kind {other}")),
            };
            (locks, link, depth, kind, r.u8()? != 0)
        } else {
            (0, 0, 0, LayerKind::Raster, true)
        };
        // Now the kind is known, so the mask can be built at the size it
        // requires — and a mask sized to the other one is refused, because the
        // pairing must be RIGHT and not merely plausible.
        let (mw, mh) = match kind {
            LayerKind::Raster => (lw, lh),
            LayerKind::Group => (width, height),
        };
        let mask = match mask_raw {
            None => None,
            Some(raw) => {
                let expected = u64::from(mw) * u64::from(mh);
                if raw.len() as u64 != expected {
                    let n = raw.len();
                    return Err(match kind {
                        LayerKind::Raster => format!(
                            "layer mask length {n} does not match the layer's {expected} pixels"
                        ),
                        LayerKind::Group => format!(
                            "layer mask length {n} does not match the canvas's {expected} pixels"
                        ),
                    });
                }
                Some(Arc::new(
                    GrayImage::from_raw(mw, mh, raw)
                        .ok_or_else(|| "invalid layer mask".to_string())?,
                ))
            }
        };
        layers.push(Layer {
            pixels: Arc::new(pixels),
            offset: (off_x, off_y),
            name,
            opacity,
            blend,
            visible,
            mask,
            mask_enabled,
            meta,
            clipped,
            style,
            kind,
            depth,
            locks,
            link,
            open,
        });
    }
    // ONE walk over the finished records: a malformed depth sequence is a
    // relation between stored values, so it is refused like a mask length and
    // never repaired. Without it a child with no enclosing group would simply
    // DISAPPEAR from every projection, export and save with no error anywhere.
    if !validate_structure(&layers) {
        return Err("malformed layer group structure".to_string());
    }
    if isolated_group_pixels(&layers, width, height) > MAX_RZDC_GROUP_CANVAS_PIXELS {
        return Err("layer groups would need more memory than this build allows".to_string());
    }
    let mut channels = Vec::new();
    if has_channels {
        let count = r.u32()?;
        if count as usize > MAX_CHANNELS {
            return Err(format!("invalid channel count {count}"));
        }
        // Unlike layers, a channel's size is knowable from the header (it is
        // always the canvas's), so the total is checked BEFORE a single plane
        // is decoded.
        if u64::from(count) * u64::from(width) * u64::from(height) > MAX_RZDC_TOTAL_CHANNEL_PIXELS {
            return Err(format!(
                "total channel pixels exceed {MAX_RZDC_TOTAL_CHANNEL_PIXELS}"
            ));
        }
        channels = Vec::with_capacity(count as usize);
        for _ in 0..count {
            let name_len = r.u32()?;
            if name_len > MAX_RZDC_NAME_LEN {
                return Err(format!("channel name length {name_len} out of range"));
            }
            let name = String::from_utf8_lossy(r.take(name_len as usize)?).into_owned();
            let overlay_color = [r.u8()?, r.u8()?, r.u8()?];
            let overlay_opacity = sane_opacity(r.f32()?);
            let color_indicates_selected = r.u8()? != 0;
            let png_len = r.u32()?;
            if png_len > MAX_RZDC_PNG_LEN {
                return Err(format!("channel PNG length {png_len} out of range"));
            }
            let png = r.take(png_len as usize)?;
            let plane = image::load_from_memory_with_format(png, image::ImageFormat::Png)
                .map_err(|e| format!("failed to decode channel plane: {e}"))?
                .to_luma8();
            if plane.dimensions() != (width, height) {
                let (cw, ch) = plane.dimensions();
                return Err(format!(
                    "channel plane {cw}x{ch} does not match the {width}x{height} canvas"
                ));
            }
            // Through `Channel::new`, so the loaded channel gets a fresh
            // identity: `Channel::id` is a host-facing handle for as long as a
            // document is open, never a persisted property (see its doc).
            channels.push(Channel {
                overlay_color,
                overlay_opacity,
                color_indicates_selected,
                ..Channel::new(&name, Arc::new(plane))
            });
        }
    }
    // Version 6: the document tail. Sanitized rather than refused, like the
    // global light; the blobs are capped before a byte is taken and are
    // otherwise passed through untouched.
    let (resolution, profile, metadata) = if has_document_tail {
        let resolution = Resolution {
            x: r.f32()?,
            y: r.f32()?,
        }
        .sane();
        let icc = take_opt_bytes(&mut r, "ICC profile", MAX_RZDC_BLOB_LEN)?;
        let exif = take_opt_bytes(&mut r, "EXIF packet", MAX_RZDC_BLOB_LEN)?;
        let xmp = take_opt_bytes(&mut r, "XMP packet", MAX_RZDC_BLOB_LEN)?;
        let iptc = take_opt_bytes(&mut r, "IPTC packet", MAX_RZDC_BLOB_LEN)?;
        // An absent slot is the built-in sRGB (the writer elides it); a
        // present blob that no longer parses as an RGB profile falls back to
        // it too, rather than refusing a file whose pixels are fine.
        let profile = icc
            .and_then(|b| IccProfile::parse(&b))
            .map(Arc::new)
            .unwrap_or_else(IccProfile::srgb);
        (
            resolution,
            profile,
            Metadata {
                exif: exif.map(Arc::from),
                xmp: xmp.map(Arc::from),
                iptc: iptc.map(Arc::from),
            },
        )
    } else {
        (
            Resolution::default(),
            IccProfile::srgb(),
            Metadata::default(),
        )
    };
    Ok(RzDocument {
        width,
        height,
        layers,
        global_light,
        channels,
        profile,
        metadata,
        resolution,
    })
}
