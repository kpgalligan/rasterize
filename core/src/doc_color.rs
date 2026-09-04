//! Colour management and metadata as DOCUMENT operations: assign versus
//! convert, the one-shot working-space adoption every non-native open runs,
//! the print resolution, the metadata packets, and the document-level image
//! save that embeds all of it. The profile model is `icc`, the numerics
//! `icc_transform`, the packets and the container walk `metadata` /
//! `metadata_write`; `doc.rs` only carries the three fields through its ops.
//!
//! # Assign is not Convert
//!
//! **Assign** reinterprets: the pixels are untouched and the profile is
//! replaced, so the image's NUMBERS stay and its appearance changes.
//! **Convert** transforms: every layer's pixels move through the transform
//! so the appearance stays and the numbers change. Photoshop keeps these two
//! separate and the GIMP study's §7 insists on it; collapsing them is the
//! classic way to destroy a photograph quietly.
//!
//! Convert touches **layer pixels only**. Layer masks and alpha channels are
//! coverage rather than colour and are left byte-identical; an adjustment
//! layer's `meta` is left alone for a different reason, worth stating because
//! it is the one place "the picture looks the same" stops being true — a
//! curve point or a saturation amount is a PARAMETER, not a colour, so there
//! is nothing to convert it into, and it is then applied to numbers that have
//! moved. Blend modes are the same story one level up. Each LAYER keeps its
//! appearance; a stack whose result is computed from the numbers does not,
//! and the host says so rather than promising otherwise
//! (`ColorProfileControls.appearanceDependsOnNumbers`).
//!
//! So are the colours inside a layer STYLE and a text layer's `meta`, and
//! that is correct rather than a limit: those are AUTHORED sRGB values, and
//! they reach the document's space at the point they are used — a style's at
//! composite time (`style_composite`, whose module doc says why there rather
//! than in the cache), a text layer's when the host re-renders it through a
//! document-space context. Converting them here as well would convert them
//! twice.
//!
//! # What a save actually writes
//!
//! Not every format can carry everything, so [`format_carries`] is the
//! capability table as a query — the host asks the same question the core
//! answers, and [`RzDocument::save_image`] reports what was ACTUALLY
//! written. A packet the format cannot carry, one too large for its segment,
//! or an 8BIM run that filters down to nothing is **dropped and reported,
//! never an error**: a save must not fail because a source file had a fat
//! profile.
//!
//! One asymmetry is worth naming, because it looks like a bug and is not: a
//! TIFF written here carries its profile correctly (the tag is present and
//! ColorSync and littleCMS both read it), but reopening one does not recover
//! it — `image` 0.25.10's TIFF decoder never surfaces the tag its own
//! encoder writes, so such a document comes back assuming sRGB.
//! `metadata_tests::jpeg_and_png_are_the_only_walked_containers` pins both
//! halves of that.
//!
//! The other TIFF limit is the resolution, and it is worth stating because
//! the file is not merely silent about it: `image` 0.25.10's `TiffEncoder`
//! exposes no resolution hook (only `set_icc_profile`), so every TIFF it
//! writes carries the `tiff` crate's own default of XResolution 1/1,
//! YResolution 1/1 and ResolutionUnit 1 ("none"). Applications that read
//! that pair literally show a 1 dpi image. `format_carries` says TIFF
//! carries no resolution, which is true — nothing there states THIS
//! document's ppi — and the host's export notice names what the file says
//! instead, rather than implying the tags are absent.

use std::ffi::c_int;
use std::io::Read;
use std::sync::Arc;

use crate::doc::RzDocument;
use crate::icc::IccProfile;
use crate::icc_transform::Transform;
use crate::metadata::{self, Metadata, Resolution, IPTC_ID, XMP_ID};
use crate::metadata_write::{exif_normalized, iptc_filtered, EncodeSidecar, JPEG_MAX_PAYLOAD};
use crate::metadata_xmp::xmp_normalized;
use crate::rz_image::{save_flat, Format};
use crate::rzdc::MAX_RZDC_BLOB_LEN;
use crate::RzImage;

/// The capability bits, mirroring `RZ_CARRIES_*` in the C header.
pub const CARRIES_PROFILE: u32 = 1;
pub const CARRIES_EXIF: u32 = 2;
pub const CARRIES_XMP: u32 = 4;
pub const CARRIES_IPTC: u32 = 8;
pub const CARRIES_RESOLUTION: u32 = 16;

/// The `Exif\0\0` prefix `image`'s JPEG encoder adds back around the packet
/// this crate stores without it, which is why an EXIF block has six fewer
/// bytes than a segment to live in.
const JPEG_EXIF_PREFIX: usize = 6;

/// The largest ICC profile a JPEG can carry: 255 APP2 chunks of
/// `65533 - 14` payload bytes each. Checked here so an oversize profile is
/// DROPPED rather than turned into a failed export by the encoder's own
/// "ICC profile too large" error.
const JPEG_MAX_ICC: usize = (JPEG_MAX_PAYLOAD - 14) * 255;

/// What an open did to the document's colour, so a host can say so once.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AdoptOutcome {
    /// The file's profile already IS the working space (within the
    /// equivalence tolerance), so nothing was touched.
    Unchanged,
    /// The pixels were transformed into the working space.
    Converted,
    /// The file's profile is one this crate cannot convert FROM, so it was
    /// kept as the document's profile and no pixel was touched. Display,
    /// painting and re-embedding are all still correct; only Convert to
    /// Profile refuses.
    KeptUnconvertible,
}

/// Which metadata packet an FFI call means.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MetadataKind {
    Exif,
    Xmp,
    Iptc,
}

impl MetadataKind {
    /// Maps a raw `RzMetadataKind` value coming across the FFI. Mapped,
    /// never transmuted: callers do pass values outside the enum, and
    /// materializing an enum from an out-of-range discriminant would be
    /// undefined behaviour.
    pub(crate) fn from_c(value: c_int) -> Option<Self> {
        match value {
            0 => Some(MetadataKind::Exif),
            1 => Some(MetadataKind::Xmp),
            2 => Some(MetadataKind::Iptc),
            _ => None,
        }
    }

    fn get(self, meta: &Metadata) -> Option<&Arc<[u8]>> {
        match self {
            MetadataKind::Exif => meta.exif.as_ref(),
            MetadataKind::Xmp => meta.xmp.as_ref(),
            MetadataKind::Iptc => meta.iptc.as_ref(),
        }
    }

    fn slot(self, meta: &mut Metadata) -> &mut Option<Arc<[u8]>> {
        match self {
            MetadataKind::Exif => &mut meta.exif,
            MetadataKind::Xmp => &mut meta.xmp,
            MetadataKind::Iptc => &mut meta.iptc,
        }
    }
}

/// Whether opening `path` would PRESERVE whatever EXIF, XMP and IPTC the
/// file holds — the question a host has to answer to say "the capture data
/// was never read in" honestly.
///
/// True for a JPEG or a PNG (the two containers `metadata::scan` walks) and
/// for a native `.rz`, which stores its packets itself. False for every
/// other container — a TIFF, WebP, GIF, BMP or PSD opens with its pixels and
/// none of its capture data, and a TIFF's IFD0 or a PSD's 8BIM run really
/// can hold some — and false for a file that cannot be read at all, which is
/// a file the open is about to refuse anyway.
///
/// Asked of the PATH rather than of the document because it describes the
/// OPEN, not the document: a document carries no memory of which container
/// it came out of, and inventing one would mean a field every pure op had to
/// carry and the native format had to persist. Reading the magic costs eight
/// bytes.
pub fn metadata_walked(path: &str) -> bool {
    // `read_to_end` over a `take`, not one `read`: a single read is allowed
    // to return fewer bytes than asked for, and answering "not walked"
    // because of a short read would be a wrong answer about a real JPEG.
    let mut head = Vec::with_capacity(8);
    let read = std::fs::File::open(path).and_then(|f| f.take(8).read_to_end(&mut head));
    if read.is_err() {
        return false;
    }
    head.starts_with(b"RZDC") || metadata::walks(&head)
}

/// Which of the profile, packets and resolution `format` is able to carry —
/// the ONE capability table, asked as a number so the host and the core can
/// never drift:
///
/// | Format | profile | exif | xmp | iptc | resolution |
/// |---|---|---|---|---|---|
/// | PNG | `iCCP` | `eXIf` | our `iTXt` | — | our `pHYs` |
/// | JPEG | APP2 x n | APP1 | our APP1 | our APP13 | JFIF density |
/// | TIFF | tag | — | — | — | — |
/// | WebP | chunk | chunk | — | — | — |
/// | BMP, GIF | — | — | — | — | — |
///
/// The resolution column is the format's OWN density slot, which is why
/// WebP's is empty even though a WebP export can still state the ppi: it
/// does so inside the EXIF chunk, and only when there is a packet to write.
/// [`RzDocument::save_image`] therefore reports `CARRIES_RESOLUTION` from
/// this table **or** from the normalized packet, never from the table
/// alone — a report that said "dropped" about a number the file plainly
/// contains would be worse than saying nothing.
pub(crate) fn format_carries(format: Format) -> u32 {
    match format {
        Format::Png => CARRIES_PROFILE | CARRIES_EXIF | CARRIES_XMP | CARRIES_RESOLUTION,
        Format::Jpeg => {
            CARRIES_PROFILE | CARRIES_EXIF | CARRIES_XMP | CARRIES_IPTC | CARRIES_RESOLUTION
        }
        Format::Tiff => CARRIES_PROFILE,
        Format::Webp => CARRIES_PROFILE | CARRIES_EXIF,
        Format::Bmp | Format::Gif => 0,
    }
}

impl RzDocument {
    /// Reinterprets the document in `p`: pixels unchanged, profile replaced.
    /// `None` when the document already carries exactly those bytes — a
    /// refusal, so an assign that changes nothing registers no undo step.
    pub fn assign_profile(&self, p: &Arc<IccProfile>) -> Option<Self> {
        if Arc::ptr_eq(&self.profile, p) || self.profile.bytes() == p.bytes() {
            return None;
        }
        let mut out = self.clone();
        out.profile = Arc::clone(p);
        Some(out)
    }

    /// Transforms every LAYER's pixels into `p` and replaces the profile, so
    /// the picture looks the same and its numbers change. Masks, channels
    /// and layer `meta` are untouched (see the module doc).
    ///
    /// `None` when either profile is not a matrix/TRC one this crate can
    /// model, or when the two describe the same colour space — again a
    /// refusal, not an error, so no phantom undo step is registered.
    pub fn convert_to_profile(&self, p: &Arc<IccProfile>) -> Option<Self> {
        let transform = Transform::between(self.profile.model()?, p.model()?)?;
        let mut out = self.clone();
        for layer in &mut out.layers {
            let mut pixels = (*layer.pixels).clone();
            transform.apply(&mut pixels);
            layer.pixels = Arc::new(pixels);
        }
        out.profile = Arc::clone(p);
        Some(out)
    }

    /// The ONE open-time colour rule, run exactly once per non-native open
    /// by the host: whatever produced the pixels, the document is first
    /// assigned the profile those pixel NUMBERS actually belong to, and then
    /// this converts them into the working space if the two differ.
    ///
    /// The outcome is reported even when no document comes back, so a host
    /// can tell "already in the working space" from "kept, could not be
    /// converted from".
    ///
    /// A `.rz` document skips this entirely: it carries its own profile, and
    /// converting it to a preference on every open would silently rewrite
    /// the user's document.
    pub fn adopt_working_space(&self, working: &Arc<IccProfile>) -> (Option<Self>, AdoptOutcome) {
        if self.profile.model().is_none() {
            return (None, AdoptOutcome::KeptUnconvertible);
        }
        match self.convert_to_profile(working) {
            Some(doc) => (Some(doc), AdoptOutcome::Converted),
            // Either the working space is not modellable (impossible for a
            // built-in) or the two spaces already agree.
            None => (None, AdoptOutcome::Unchanged),
        }
    }

    /// Sets the print resolution in ppi. Pixels are never touched — only the
    /// print size changes. `None` on a non-finite or non-positive component,
    /// or when nothing changes after sanitizing (clamped to [1, 30000] and
    /// quantized to four decimals like the global light, so a host echoing a
    /// reported value back is refused instead of registering a phantom
    /// edit).
    pub fn set_resolution(&self, x: f32, y: f32) -> Option<Self> {
        if !x.is_finite() || !y.is_finite() || x <= 0.0 || y <= 0.0 {
            return None;
        }
        let next = Resolution { x, y }.sane();
        if next == self.resolution {
            return None;
        }
        let mut out = self.clone();
        out.resolution = next;
        Some(out)
    }

    /// Stores one metadata packet verbatim, or clears it with `None`.
    /// `None` for a payload past the RZDC blob cap — enforced here so a
    /// document can never hold a packet the writer would refuse — or for a
    /// value the document already carries.
    pub fn set_metadata(&self, kind: MetadataKind, bytes: Option<&[u8]>) -> Option<Self> {
        if bytes.is_some_and(|b| b.len() > MAX_RZDC_BLOB_LEN as usize) {
            return None;
        }
        let current = kind.get(&self.metadata).map(|b| &**b);
        if current == bytes {
            return None;
        }
        let mut out = self.clone();
        *kind.slot(&mut out.metadata) = bytes.map(|b| Arc::from(b.to_vec()));
        Some(out)
    }

    /// Encodes the document to `path` as a flat image, embedding its colour
    /// profile and — unless `strip_metadata` — its EXIF, XMP and IPTC
    /// packets, format permitting, and always its print resolution where the
    /// format has somewhere to put one. Returns the `CARRIES_*` bits that
    /// were ACTUALLY written.
    ///
    /// `flat` is a caller-supplied composite of THIS document (the host's
    /// always-warm projection); passing an unrelated image is a caller bug,
    /// and the canvas dimensions are not re-checked. `None` flattens here.
    /// The parameter exists because re-compositing the whole layer stack —
    /// styles, masks, clipping — on every save would be a visible stall on
    /// the app's most frequent command, and because the export path captures
    /// its composite deliberately BEFORE the save panel opens.
    ///
    /// `strip_metadata` governs the three inherited packets only. The
    /// document's own resolution and colour profile are its state, not
    /// something it inherited from a file, so they follow the format's
    /// capability and `embed_profile`.
    ///
    /// Atomic exactly like `rz_image_save`.
    pub(crate) fn save_image(
        &self,
        flat: Option<&RzImage>,
        path: &str,
        format: Format,
        jpeg_quality: u8,
        embed_profile: bool,
        strip_metadata: bool,
    ) -> Result<u32, String> {
        let flattened;
        let pixels = match flat {
            Some(image) => &image.pixels,
            None => {
                flattened = self.flattened();
                &flattened
            }
        };
        let (w, h) = pixels.dimensions();
        let caps = format_carries(format);
        let is_jpeg = format == Format::Jpeg;
        let mut carried = 0u32;

        let icc = self.profile.bytes();
        let icc = if embed_profile
            && caps & CARRIES_PROFILE != 0
            && (!is_jpeg || icc.len() <= JPEG_MAX_ICC)
        {
            carried |= CARRIES_PROFILE;
            Some(&**icc)
        } else {
            None
        };

        let keep = |bit: u32| !strip_metadata && caps & bit != 0;
        // The EXIF packet is rewritten before it is written: orientation to
        // 1, the resolution, colour-space and dimension tags to this
        // document's, IFD1 unlinked. A packet that does not verify — or one
        // whose resolution states something this document does not and
        // cannot be corrected, which would outrank the density this save
        // writes — is dropped whole.
        let exif = keep(CARRIES_EXIF)
            .then_some(self.metadata.exif.as_deref())
            .flatten()
            .and_then(|blob| {
                exif_normalized(
                    blob,
                    w,
                    h,
                    self.resolution.sane(),
                    self.profile.describes_srgb(),
                )
            })
            .filter(|e| !is_jpeg || e.bytes.len() + JPEG_EXIF_PREFIX <= JPEG_MAX_PAYLOAD);
        if exif.is_some() {
            carried |= CARRIES_EXIF;
        }

        // The XMP packet carries its own copies of the orientation and the
        // resolution, and XMP's reconciliation rules make THEM the authority
        // — so it gets the same one-way normalization the EXIF block does,
        // and the size check runs on what will actually be written.
        let xmp = keep(CARRIES_XMP)
            .then_some(self.metadata.xmp.as_deref())
            .flatten()
            .map(|blob| xmp_normalized(blob, self.resolution.sane()))
            .filter(|blob| !is_jpeg || blob.len() + XMP_ID.len() <= JPEG_MAX_PAYLOAD);
        if xmp.is_some() {
            carried |= CARRIES_XMP;
        }

        // The 8BIM run loses the resources that would contradict what this
        // save writes; a run that filters down to nothing means no APP13.
        let iptc = keep(CARRIES_IPTC)
            .then_some(self.metadata.iptc.as_deref())
            .flatten()
            .and_then(iptc_filtered)
            .filter(|run| !run.is_empty())
            .filter(|run| !is_jpeg || run.len() + IPTC_ID.len() <= JPEG_MAX_PAYLOAD);
        if iptc.is_some() {
            carried |= CARRIES_IPTC;
        }

        // The format's own density slot (the JFIF APP0, the PNG `pHYs`).
        let dpi = (caps & CARRIES_RESOLUTION != 0).then(|| self.resolution.sane());
        // The file states this document's ppi if that slot was written OR
        // the EXIF packet came out saying it — which is how a WebP export
        // states a resolution at all.
        //
        // The density slot alone is enough BECAUSE `exif_normalized` never
        // writes a packet that states a different resolution: Exif/DCF makes
        // IFD0 the authority over a JFIF or `pHYs` density, so a packet that
        // could not be corrected is dropped there rather than left to
        // outrank the number written here.
        if dpi.is_some() || exif.as_ref().is_some_and(|e| e.states_resolution) {
            carried |= CARRIES_RESOLUTION;
        }

        save_flat(
            pixels,
            path,
            format,
            jpeg_quality,
            &EncodeSidecar {
                icc,
                exif: exif.map(|e| e.bytes),
                xmp,
                iptc,
                dpi,
            },
        )?;
        Ok(carried)
    }
}
