//! Alpha channels on the layered document: named, canvas-sized u8 coverage
//! planes that are a SAVED SELECTION in exactly the representation selections
//! (`doc_select`) and layer masks (`doc`) already use — 0 out, 255 in,
//! intermediate = anti-aliased edge. A channel never composites:
//! `flattened` and `layer_canvas_image` ignore them entirely, and the overlay
//! colour, opacity and polarity exist only so a host can draw one as a
//! rubylith. Every canvas-geometry op keeps them canvas-sized (the four
//! helpers at the foot of this module are what `doc.rs` wires in, and
//! [`RzDocument::transform_channels`] is the fifth — the one a HOST composes,
//! for a straighten). The plane arithmetic they are made of lives in
//! `doc_plane`.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use image::imageops::{self, FilterType};
use image::GrayImage;

use crate::doc::{sane_opacity, Geometry, RzDocument, MAX_PIXELS};
use crate::doc_plane::Plane;
use crate::doc_transform::{resample_canvas_plane, Affine};
use crate::rzdc::MAX_RZDC_TOTAL_CHANNEL_PIXELS;

/// One alpha channel: a named canvas-sized coverage plane plus the rubylith a
/// host draws it with.
#[derive(Clone)]
pub struct Channel {
    /// Stable identity, unique among every channel this process has minted.
    ///
    /// It exists because a host's per-channel VIEW state (which channel's eye
    /// is on, say) has to stay attached to a channel rather than to its name
    /// or its position: names are not unique and a rename changes them, and
    /// every insert, delete and undo renumbers the list under a positional
    /// key. Everything that carries a channel through keeps the id — a
    /// rename, an edit to its plane, the geometry helpers, undo/redo (which
    /// restores the whole handle) — and [`RzDocument::duplicate_channel`]
    /// mints a fresh one, because the copy IS a different channel.
    ///
    /// It is deliberately NOT persisted: identity only has to hold for as
    /// long as a host is looking at one open document, so `parse_native`
    /// mints new ids on load and the `.rz` bytes stay unchanged.
    pub id: u64,
    /// Display name. Not unique — the host disambiguates.
    pub name: String,
    /// ALWAYS canvas-sized (the module invariant). Shared (`Arc`) for the
    /// same copy-on-write reason as layer pixels and masks.
    pub data: Arc<GrayImage>,
    /// Rubylith colour a host draws the channel in. Display only.
    pub overlay_color: [u8; 3],
    /// Rubylith opacity, 0..=1 (`sane_opacity`). Display only.
    pub overlay_opacity: f32,
    /// Which side of the channel the rubylith covers. FALSE (the default)
    /// means "Color Indicates: Masked Areas" — the wash covers where the
    /// channel is BLACK, which is Photoshop's default and the polarity the
    /// app's Quick Mask overlay already draws. Display only: it never changes
    /// a byte of `data`.
    pub color_indicates_selected: bool,
}

/// The largest channel list a document may carry — the ONE home for the count
/// cap (`rzdc` enforces the same number, so every document that can be built
/// can also be written and read back).
///
/// 256 is Photoshop's own alpha-channel ceiling, and it keeps the list small
/// enough that a host can put every channel in one panel.
pub(crate) const MAX_CHANNELS: usize = 256;

/// The rubylith a new channel gets: Photoshop's 50% red — the same wash Quick
/// Mask draws, so a channel and Quick Mask read alike on screen.
pub(crate) const DEFAULT_OVERLAY_COLOR: [u8; 3] = [255, 0, 0];
pub(crate) const DEFAULT_OVERLAY_OPACITY: f32 = 0.5;

/// How many channels [`RzDocument::add_luminosity_masks`] appends.
const LUMINOSITY_MASK_COUNT: usize = 9;

/// The id counter behind [`Channel::id`]. Starts at 1, so 0 is free to mean
/// "no channel" across the FFI. `Relaxed` is enough: nothing is published
/// through this counter, only made distinct, and a `fetch_add` is atomic
/// whatever the ordering.
static NEXT_CHANNEL_ID: AtomicU64 = AtomicU64::new(1);

impl Channel {
    /// A channel with a FRESH identity, the default rubylith (see the two
    /// constants above) and the default masked-areas polarity. Every channel
    /// this crate creates — a new one, a duplicate, a luminosity mask, one
    /// read back out of a `.rz` file — is minted here, so the id is unique by
    /// construction.
    pub(crate) fn new(name: &str, data: Arc<GrayImage>) -> Self {
        Channel {
            id: NEXT_CHANNEL_ID.fetch_add(1, Ordering::Relaxed),
            name: name.to_string(),
            data,
            overlay_color: DEFAULT_OVERLAY_COLOR,
            overlay_opacity: DEFAULT_OVERLAY_OPACITY,
            color_indicates_selected: false,
        }
    }
}

/// True when `count` channels on a `w` x `h` canvas stay inside BOTH caps:
/// the count ([`MAX_CHANNELS`]) and the total pixel budget the RZDC reader
/// enforces ([`MAX_RZDC_TOTAL_CHANNEL_PIXELS`]).
///
/// The predicate takes EXPLICIT dimensions because two kinds of op can break
/// the budget: one that adds channels to the canvas it has
/// ([`RzDocument::channels_fit`], which delegates here), and one that GROWS
/// the canvas under the channels it has — `RzDocument::resize` and
/// `RzDocument::canvas_resize`, which refuse rather than build a document
/// `rz_doc_save_native` would then refuse to write. Forty saved selections on
/// a 20 MP canvas fit; the same forty after an Image Size to 30 MP do not, and
/// discovering that at Save time would cost the user the work.
pub(crate) fn channels_fit_at(w: u32, h: u32, count: usize) -> bool {
    count <= max_channels_at(w, h)
}

/// The largest channel count a `w` x `h` canvas can carry — the inverse of
/// [`channels_fit_at`], and the one number that lets a host EXPLAIN a refusal
/// ("this canvas holds at most N channels; delete some") instead of beeping
/// at it. `RzDocument::resize`, `RzDocument::canvas_resize` and
/// `add_luminosity_masks` all refuse on this budget, and a beep leaves the
/// user with no way to learn why.
///
/// A zero dimension answers [`MAX_CHANNELS`]: nothing multiplied by no pixels
/// can break the pixel budget, and a canvas with no pixels is refused a step
/// earlier anyway.
pub(crate) fn max_channels_at(w: u32, h: u32) -> usize {
    let per_channel = u64::from(w) * u64::from(h);
    if per_channel == 0 {
        return MAX_CHANNELS;
    }
    // usize is 64-bit on every target this ships to, and the quotient is at
    // most MAX_RZDC_TOTAL_CHANNEL_PIXELS anyway, so the cast cannot truncate.
    ((MAX_RZDC_TOTAL_CHANNEL_PIXELS / per_channel) as usize).min(MAX_CHANNELS)
}

impl RzDocument {
    /// True when `adding` more canvas-sized channels stays inside BOTH caps:
    /// the count ([`MAX_CHANNELS`]) and the total pixel budget the RZDC
    /// reader enforces ([`MAX_RZDC_TOTAL_CHANNEL_PIXELS`]).
    ///
    /// Every op that CREATES channels calls this, so a document can never be
    /// built that `rz_doc_save_native` would write and `parse_native` would
    /// then refuse — fifty channels on a 24 MP canvas, or two hundred on a
    /// 6 MP one, would otherwise save happily and never reopen. The budget is
    /// nine full canvases precisely so that the one op which appends a fixed
    /// NINE ([`RzDocument::add_luminosity_masks`]) is never refused on a
    /// canvas the app itself allows.
    pub(crate) fn channels_fit(&self, adding: usize) -> bool {
        let count = match self.channels.len().checked_add(adding) {
            Some(count) => count,
            None => return false,
        };
        channels_fit_at(self.width, self.height, count)
    }

    /// Appends a channel built from `plane`, exactly `w * h` coverage bytes
    /// (row 0 top), with the default masked-areas polarity.
    ///
    /// When `(w, h)` differs from the canvas the plane is resampled to the
    /// canvas bilinearly — the ONE resampling entry, for the iPhone
    /// auxiliary-matte path, and literally the line `RzDocument::resize`
    /// already runs on a layer mask.
    ///
    /// `None` on a length mismatch, a zero dimension, `w * h` past
    /// [`MAX_PIXELS`], or a list that would break either cap
    /// ([`Self::channels_fit`]).
    pub fn add_channel(
        &self,
        name: &str,
        plane: &[u8],
        w: u32,
        h: u32,
        color: [u8; 3],
        opacity: f32,
    ) -> Option<Self> {
        if w == 0 || h == 0 || self.width == 0 || self.height == 0 {
            return None;
        }
        if u64::from(w) * u64::from(h) > MAX_PIXELS {
            return None;
        }
        let expected = (w as usize).checked_mul(h as usize)?;
        if plane.len() != expected {
            return None;
        }
        if !self.channels_fit(1) {
            return None;
        }
        let source = GrayImage::from_raw(w, h, plane.to_vec())?;
        let data = if (w, h) == (self.width, self.height) {
            source
        } else {
            imageops::resize(&source, self.width, self.height, FilterType::Triangle)
        };
        let mut doc = self.clone();
        doc.channels.push(Channel {
            overlay_color: color,
            overlay_opacity: sane_opacity(opacity),
            ..Channel::new(name, Arc::new(data))
        });
        Some(doc)
    }

    /// Drops channel `i`. `None` for an out-of-range index.
    pub fn remove_channel(&self, i: usize) -> Option<Self> {
        self.channels.get(i)?;
        let mut doc = self.clone();
        doc.channels.remove(i);
        Some(doc)
    }

    /// Renames channel `i`. `None` for an out-of-range index or a name that
    /// is already what it would be set to.
    pub fn rename_channel(&self, i: usize, name: &str) -> Option<Self> {
        if self.channels.get(i)?.name == name {
            return None;
        }
        let mut doc = self.clone();
        doc.channels[i].name = name.to_string();
        Some(doc)
    }

    /// Replaces all three display options of channel `i` at once (so the
    /// host's options sheet is one undo step). `opacity` goes through
    /// `sane_opacity`. `None` for an out-of-range index or when none of the
    /// three would change.
    pub fn set_channel_overlay(
        &self,
        i: usize,
        color: [u8; 3],
        opacity: f32,
        indicates_selected: bool,
    ) -> Option<Self> {
        let channel = self.channels.get(i)?;
        let opacity = sane_opacity(opacity);
        if channel.overlay_color == color
            && channel.overlay_opacity == opacity
            && channel.color_indicates_selected == indicates_selected
        {
            return None;
        }
        let mut doc = self.clone();
        let channel = &mut doc.channels[i];
        channel.overlay_color = color;
        channel.overlay_opacity = opacity;
        channel.color_indicates_selected = indicates_selected;
        Some(doc)
    }

    /// Replaces channel `i`'s coverage with `plane`, which must be exactly
    /// canvas-sized. `None` for an out-of-range index, a wrong length, or
    /// bytes identical to the current plane.
    pub fn set_channel_data(&self, i: usize, plane: &[u8]) -> Option<Self> {
        let channel = self.channels.get(i)?;
        let expected = (self.width as usize).checked_mul(self.height as usize)?;
        if plane.len() != expected || channel.data.as_raw().as_slice() == plane {
            return None;
        }
        let data = GrayImage::from_raw(self.width, self.height, plane.to_vec())?;
        let mut doc = self.clone();
        doc.channels[i].data = Arc::new(data);
        Some(doc)
    }

    /// Inserts a copy of channel `i` right after it, named "<name> copy"
    /// (the `duplicating_layer` convention). The copy gets its OWN identity —
    /// it is a second channel, not the same one in two places, and a host
    /// keying view state on [`Channel::id`] must not see the original's eye
    /// on both rows. `None` for an out-of-range index or a list that would
    /// break either cap.
    pub fn duplicate_channel(&self, i: usize) -> Option<Self> {
        let source = self.channels.get(i)?;
        if !self.channels_fit(1) {
            return None;
        }
        let dup = Channel {
            overlay_color: source.overlay_color,
            overlay_opacity: source.overlay_opacity,
            color_indicates_selected: source.color_indicates_selected,
            ..Channel::new(&format!("{} copy", source.name), Arc::clone(&source.data))
        };
        let mut doc = self.clone();
        doc.channels.insert(i + 1, dup);
        Some(doc)
    }

    /// Inverts channel `i` (`255 - v`). `None` only for an out-of-range
    /// index: on a non-empty canvas inverting always changes something, since
    /// `v == 255 - v` has no integer solution (255 is odd).
    pub fn invert_channel(&self, i: usize) -> Option<Self> {
        let channel = self.channels.get(i)?;
        let mut inverted = (*channel.data).clone();
        let raw: &mut [u8] = &mut inverted;
        for v in raw.iter_mut() {
            *v = 255 - *v;
        }
        let mut doc = self.clone();
        doc.channels[i].data = Arc::new(inverted);
        Some(doc)
    }

    /// Channel `i`'s coverage bytes (canvas-sized, row 0 top); `None` for an
    /// out-of-range index.
    pub fn channel_plane(&self, i: usize) -> Option<&[u8]> {
        Some(self.channels.get(i)?.data.as_raw().as_slice())
    }

    /// Appends the nine luminosity masks — "Lights 1".."Lights 3",
    /// "Darks 1".."Darks 3", "Midtones 1".."Midtones 3" — built from the
    /// composite's Rec. 709 luma `L` (all math in f32 on `v / 255`, rounded
    /// once at the end):
    ///
    /// ```text
    /// Lights n = L^n        Darks n = (1 - L)^n
    /// Midtones n = clamp(1 - L^(n+1) - (1 - L)^(n+1))
    /// ```
    ///
    /// The multiply chain (L, L*L, L*L*L) is the photographer's convention:
    /// each step narrows the mask toward the brightest tones.
    ///
    /// The midtone exponent is deliberately offset by one. The LINEAR pair
    /// sums to 1 at every pixel, so `1 - (Lights 1 + Darks 1)` would be 0
    /// everywhere — an all-black, useless channel. The SQUARED pair gives
    /// `2L(1 - L)`, the standard midtone mask, peaking at L = 0.5. Because
    /// each step narrows BOTH tails, the midtone masks correspondingly
    /// broaden: at mid grey they read 0.5, 0.75 and 0.875, so Midtones 1 is
    /// the tightest band around mid grey and Midtones 3 the most inclusive —
    /// three genuinely distinct masks.
    ///
    /// `None` when the nine would break either cap ([`Self::channels_fit`]) —
    /// checked BEFORE the composite is built, so a refusal costs nothing. In
    /// practice only the COUNT cap can refuse them: the pixel budget is nine
    /// full canvases, so the set fits every canvas the app can build (see
    /// [`MAX_RZDC_TOTAL_CHANNEL_PIXELS`]), and a document already carrying
    /// close to 256 channels is the one case left.
    pub fn add_luminosity_masks(&self) -> Option<Self> {
        if !self.channels_fit(LUMINOSITY_MASK_COUNT) {
            return None;
        }
        let luma = self.composite_plane(Plane::Luma)?;
        let (w, h) = (self.width, self.height);
        let mut doc = self.clone();
        for n in 1..=3i32 {
            doc.channels
                .push(luminosity_mask(&format!("Lights {n}"), &luma, w, h, |t| {
                    t.powi(n)
                })?);
        }
        for n in 1..=3i32 {
            doc.channels
                .push(luminosity_mask(&format!("Darks {n}"), &luma, w, h, |t| {
                    (1.0 - t).powi(n)
                })?);
        }
        for n in 1..=3i32 {
            doc.channels.push(luminosity_mask(
                &format!("Midtones {n}"),
                &luma,
                w,
                h,
                |t| 1.0 - t.powi(n + 1) - (1.0 - t).powi(n + 1),
            )?);
        }
        Some(doc)
    }

    /// Resamples EVERY channel through `m`, an affine matrix in canvas
    /// coordinates — the whole-document half of `transform_layer`, for the
    /// one edit that rotates the picture without changing the canvas: the
    /// Crop tool's straighten, which turns every layer by the same matrix
    /// before cropping. A channel is a saved SELECTION of the picture, so it
    /// has to ride that rotation or it silently stops lining up with what it
    /// was saved from.
    ///
    /// The destination is the canvas itself (a channel is canvas space and
    /// stays canvas-sized — there is no bounding box to grow into), so
    /// coverage that rotates off the canvas is dropped. Nothing is lost by
    /// that: the straighten's crop rect is inside the canvas, so a sample
    /// that leaves the canvas leaves the crop too. Samples with no source
    /// read 0, exactly as a layer's mask does under the same rotation.
    ///
    /// Resampling goes through `doc_transform`'s own mask resampler with the
    /// same kernel the layer pixels take, so a channel and an identical layer
    /// mask come out identical. `None` when there are no channels, when the
    /// matrix is not finite or is singular, when the filter is not one of the
    /// four `RzResizeFilter` values, or when no byte would change.
    pub fn transform_channels(&self, m: Affine, filter: FilterType) -> Option<Self> {
        if self.channels.is_empty() || self.width == 0 || self.height == 0 {
            return None;
        }
        let channels: Vec<Channel> = self
            .channels
            .iter()
            .map(|c| {
                Some(Channel {
                    data: Arc::new(resample_canvas_plane(&c.data, &m, filter)?),
                    ..c.clone()
                })
            })
            .collect::<Option<Vec<_>>>()?;
        // An identity matrix (or one whose resample lands on the same bytes)
        // is not an edit — the purity rule, and a phantom undo step in the
        // host otherwise.
        if channels
            .iter()
            .zip(self.channels.iter())
            .all(|(new, old)| new.data.as_raw() == old.data.as_raw())
        {
            return None;
        }
        let mut doc = self.clone();
        doc.channels = channels;
        Some(doc)
    }
}

/// One luminosity mask: `f` applied to every luma value as a unit float, then
/// clamped and rounded back to a byte.
fn luminosity_mask(
    name: &str,
    luma: &[u8],
    w: u32,
    h: u32,
    f: impl Fn(f32) -> f32,
) -> Option<Channel> {
    let data: Vec<u8> = luma
        .iter()
        .map(|&v| (f(f32::from(v) / 255.0).clamp(0.0, 1.0) * 255.0).round() as u8)
        .collect();
    Some(Channel::new(
        name,
        Arc::new(GrayImage::from_raw(w, h, data)?),
    ))
}

// ------------------------------------------------------ canvas geometry --
//
// The four helpers `doc.rs`'s geometry ops wire in, each keeping every
// channel exactly canvas-sized and carrying its name, colour, opacity and
// polarity through with `..c.clone()`.

/// Applies one exact whole-document transform (the rotations and flips) to
/// ONE canvas-sized plane — the same generic `Geometry::apply` layer pixels
/// and masks go through, so a plane permutes identically.
pub(crate) fn geometry_plane(plane: &GrayImage, geom: Geometry) -> GrayImage {
    geom.apply(plane)
}

/// Cuts ONE canvas-sized plane down to the new canvas window. A canvas plane
/// (unlike a layer, which merely shifts its offset) is genuinely cut down to
/// the rect.
pub(crate) fn cropped_plane(plane: &GrayImage, x: u32, y: u32, w: u32, h: u32) -> GrayImage {
    imageops::crop_imm(plane, x, y, w, h).to_image()
}

/// Pads ONE canvas-sized plane into the new canvas, with the old canvas's
/// top-left corner landing at `origin`. New area is 0 — unselected for a
/// channel, hidden for a group mask, which is the same thing an absent plane
/// means in both. `imageops::replace` clips, so a negative origin (the canvas
/// shrinking around the content) is handled by construction.
pub(crate) fn padded_plane(plane: &GrayImage, w: u32, h: u32, origin: (i32, i32)) -> GrayImage {
    let mut out = GrayImage::new(w, h);
    imageops::replace(&mut out, plane, i64::from(origin.0), i64::from(origin.1));
    out
}

/// Resamples ONE canvas-sized plane to the NEW CANVAS size (never a
/// per-layer size — a canvas plane has no layer), with the same filter the
/// layer pixels take.
pub(crate) fn resized_plane(plane: &GrayImage, w: u32, h: u32, filter: FilterType) -> GrayImage {
    imageops::resize(plane, w, h, filter)
}

/// [`geometry_plane`] over every channel.
pub(crate) fn geometry_channels(channels: &[Channel], geom: Geometry) -> Vec<Channel> {
    channels
        .iter()
        .map(|c| Channel {
            data: Arc::new(geometry_plane(&c.data, geom)),
            ..c.clone()
        })
        .collect()
}

/// [`cropped_plane`] over every channel.
pub(crate) fn cropped_channels(
    channels: &[Channel],
    x: u32,
    y: u32,
    w: u32,
    h: u32,
) -> Vec<Channel> {
    channels
        .iter()
        .map(|c| Channel {
            data: Arc::new(cropped_plane(&c.data, x, y, w, h)),
            ..c.clone()
        })
        .collect()
}

/// [`padded_plane`] over every channel.
pub(crate) fn padded_channels(
    channels: &[Channel],
    w: u32,
    h: u32,
    origin: (i32, i32),
) -> Vec<Channel> {
    channels
        .iter()
        .map(|c| Channel {
            data: Arc::new(padded_plane(&c.data, w, h, origin)),
            ..c.clone()
        })
        .collect()
}

/// [`resized_plane`] over every channel.
pub(crate) fn resized_channels(
    channels: &[Channel],
    w: u32,
    h: u32,
    filter: FilterType,
) -> Vec<Channel> {
    channels
        .iter()
        .map(|c| Channel {
            data: Arc::new(resized_plane(&c.data, w, h, filter)),
            ..c.clone()
        })
        .collect()
}
