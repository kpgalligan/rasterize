//! Layered PSD import, plus the shared "8-bit RGB and grayscale only" gate
//! that the flat open path (`RzImage::open_bytes`) applies too. Import
//! quirks and fallbacks are documented on [`open_psd`].

use std::collections::HashMap;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::Arc;

use image::RgbaImage;

use crate::blend::BlendMode;
use crate::doc::{Layer, LayerKind, RzDocument};
use crate::doc_group::{validate_structure, MAX_GROUP_DEPTH};
use crate::icc::IccProfile;
use crate::metadata::{Metadata, Resolution};
use crate::style::GlobalLight;

/// The psd crate silently mis-decodes anything but 8-bit RGB or grayscale
/// (CMYK channels land in RGB slots, 16-bit data is read byte-interleaved),
/// so both open paths — the flat `RzImage::open_bytes` composite and the layered
/// import — reject those up front with the same message.
pub(crate) fn check_supported(psd: &psd::Psd, path: &str) -> Result<(), String> {
    if psd.depth() != psd::PsdDepth::Eight
        || !matches!(
            psd.color_mode(),
            psd::ColorMode::Rgb | psd::ColorMode::Grayscale
        )
    {
        return Err(format!(
            "PSD {path}: unsupported {:?} color at depth {:?}; only 8-bit RGB and grayscale PSDs are supported",
            psd.color_mode(),
            psd.depth()
        ));
    }
    Ok(())
}

/// PSD -> RzDocument blend-mode mapping for a LAYER; PassThrough (mode 0,
/// which is a group's declaration and meaningless on a layer) and unknown
/// values become Normal. A GROUP never comes through here: its real blend key
/// lives in the `lsct` sub-key this decoder discards, so every imported group
/// arrives Pass Through by construction (see [`open_psd`]). The argument is the discriminant of
/// psd 0.3.5's `BlendMode` (the enum itself lives in a private module and is
/// not re-exported, so it cannot be named here — but its values are C-like
/// and cast losslessly): 0 PassThrough, 1 Normal, 2 Dissolve, 3 Darken,
/// 4 Multiply, 5 ColorBurn, 6 LinearBurn, 7 DarkerColor, 8 Lighten,
/// 9 Screen, 10 ColorDodge, 11 LinearDodge, 12 LighterColor, 13 Overlay,
/// 14 SoftLight, 15 HardLight, 16 VividLight, 17 LinearLight, 18 PinLight,
/// 19 HardMix, 20 Difference, 21 Exclusion, 22 Subtract, 23 Divide, 24 Hue,
/// 25 Saturation, 26 Color, 27 Luminosity.
fn map_psd_blend(mode: i32) -> BlendMode {
    match mode {
        2 => BlendMode::Dissolve,
        3 => BlendMode::Darken,
        4 => BlendMode::Multiply,
        5 => BlendMode::ColorBurn,
        6 => BlendMode::LinearBurn,
        7 => BlendMode::DarkerColor,
        8 => BlendMode::Lighten,
        9 => BlendMode::Screen,
        10 => BlendMode::ColorDodge,
        11 => BlendMode::Addition, // LinearDodge
        12 => BlendMode::LighterColor,
        13 => BlendMode::Overlay,
        14 => BlendMode::SoftLight,
        15 => BlendMode::HardLight,
        16 => BlendMode::VividLight,
        17 => BlendMode::LinearLight,
        18 => BlendMode::PinLight,
        19 => BlendMode::HardMix,
        20 => BlendMode::Difference,
        21 => BlendMode::Exclusion,
        22 => BlendMode::Subtract,
        23 => BlendMode::Divide,
        24 => BlendMode::Hue,
        25 => BlendMode::Saturation,
        26 => BlendMode::Color,
        27 => BlendMode::Luminosity,
        _ => BlendMode::Normal,
    }
}

/// Flattened-composite fallback: the whole PSD as one "Background" layer.
fn psd_composite_fallback(psd: &psd::Psd, path: &str) -> Result<RzDocument, String> {
    let pixels = RgbaImage::from_raw(psd.width(), psd.height(), psd.rgba())
        .ok_or_else(|| format!("PSD {path}: composite buffer size mismatch"))?;
    Ok(RzDocument::from_pixels(pixels))
}

/// Layered PSD import. One document layer per PSD raster layer; if the file
/// has no raster layers or any layer fails to decode, falls back to the
/// flattened composite.
///
/// LAYER GROUPS import with their structure and names, reconstructed from the
/// crate's `groups()` / `parent_id()` API: a group becomes a `LayerKind::Group`
/// entry holding the entries below it at greater depth, exactly as `doc_group`
/// lays a nested stack out and exactly as the PSD itself stores it. What does
/// NOT arrive, and cannot without a record walk of our own:
///
/// > Photoshop layer groups import with their structure and names; a group's
/// > own opacity, blend mode and visibility are not read by the PSD decoder
/// > this build uses, so every imported group arrives at 100 %, Pass Through
/// > and visible. Layer locks do not import for the same reason.
///
/// The cause is precise: `psd` 0.3.5 builds a `PsdGroup` from the hidden
/// BOUNDING-SECTION divider record it meets when it CLOSES the folder, not
/// from the folder record that carries those three properties, and the real
/// blend mode lives in the `lsct` sub-key it reads into a discarded binding.
/// `lspf` (locks), `lclr` (colour labels) and `knko` (knockout) go the same
/// way, through the block walk's catch-all arm.
///
/// psd 0.3.5 quirks this code compensates for (verified against the crate
/// sources and real files):
/// - `Psd::layers()` is ordered TOP-to-bottom (its `layer_by_idx` doc comment
///   claims the opposite, but the crate's own renderer consumes it top-down),
///   so the iteration is reversed for our bottom-first stack.
/// - `PsdLayer::visible()` actually returns the record's HIDDEN flag (bit 1
///   of the flags byte set means hidden in real files), so it is negated.
/// - `PsdLayer::is_clipping_mask()` is INVERTED: the crate stores the PSD
///   spec's "Clipping: 0 = base, 1 = non-base" byte as `byte == 0`, so a true
///   there means the layer is a clipping BASE. Our flag is its negation.
/// - `Psd::group_ids_in_order()` is CLOSE (post) order despite its doc
///   comment, and `get_group_sub_layers` returns DESCENDANTS rather than
///   direct children, so neither is used for ordering; the tree is rebuilt
///   from `parent_id()` and the flat layer indices, which are exact.
/// - `PsdLayer::rgba()` returns a CANVAS-sized buffer with the layer placed
///   at its rectangle — but for layers with no alpha channel it floods
///   alpha=255 across the whole canvas (opaque black outside the layer), and
///   for layers whose rectangle leaves the canvas it can panic. The buffer is
///   therefore cropped to the layer's rectangle intersected with the canvas
///   (which also yields real per-layer offsets), and each decode runs under
///   `catch_unwind`.
///
/// A PSD nested deeper than [`MAX_GROUP_DEPTH`] has its over-deep GROUPS
/// dissolved: their layers arrive at the tenth level as siblings, keeping
/// their pixels, names and properties, and only the extra folder rows are
/// dropped. Photoshop's own practical ceiling is ten, so no real file reaches
/// it. The finished stack goes through `validate_structure` — this is a trust
/// boundary, and a decoder whose ordering surprised us must refuse rather
/// than hand back a stack whose entries would silently vanish.
pub(crate) fn open_psd(bytes: &[u8], path: &str) -> Result<RzDocument, String> {
    let psd =
        psd::Psd::from_bytes(bytes).map_err(|e| format!("failed to decode PSD {path}: {e}"))?;
    check_supported(&psd, path)?;
    let (cw, ch) = (psd.width(), psd.height());
    if cw == 0 || ch == 0 {
        return Err(format!("PSD {path}: empty canvas"));
    }
    // A PSD of nothing but empty groups has no layers and is still a layered
    // document; only a file with neither takes the composite fallback.
    if psd.layers().is_empty() && psd.groups().is_empty() {
        return psd_composite_fallback(&psd, path);
    }
    let tree = PsdTree::build(&psd);
    let canvas_len = cw as usize * ch as usize * 4;
    let mut layers = Vec::with_capacity(psd.layers().len() + psd.groups().len());
    let mut failed = false;
    tree.emit(None, 0, &mut |node, depth| {
        if failed {
            return;
        }
        match node {
            Node::Group(id) => layers.push(Layer {
                // A group has no pixels of its own; the 1x1 transparent buffer
                // is the placeholder `doc_group` documents, and it is private
                // per entry so the style plane cache cannot confuse two of
                // them.
                pixels: Arc::new(RgbaImage::new(1, 1)),
                offset: (0, 0),
                name: psd.groups()[&id].name().to_string(),
                opacity: 1.0,
                blend: BlendMode::PassThrough,
                visible: true,
                mask: None,
                mask_enabled: true,
                meta: None,
                clipped: false,
                style: None,
                kind: LayerKind::Group,
                depth,
                locks: 0,
                link: 0,
                open: true,
            }),
            Node::Layer(i) => {
                let l = &psd.layers()[i];
                let rgba = match catch_unwind(AssertUnwindSafe(|| l.rgba())) {
                    Ok(rgba) if rgba.len() == canvas_len => rgba,
                    _ => {
                        failed = true;
                        return;
                    }
                };
                // Intersect the layer rectangle (crate bounds are inclusive)
                // with the canvas.
                let x0 = l.layer_left().max(0) as i64;
                let y0 = l.layer_top().max(0) as i64;
                let x1 = (i64::from(l.layer_right()) + 1).min(i64::from(cw));
                let y1 = (i64::from(l.layer_bottom()) + 1).min(i64::from(ch));
                let (pixels, offset) = if x0 < x1 && y0 < y1 {
                    let (w, h) = ((x1 - x0) as u32, (y1 - y0) as u32);
                    let img = RgbaImage::from_fn(w, h, |x, y| {
                        let cx = x0 as u32 + x;
                        let cy = y0 as u32 + y;
                        let i = (cy as usize * cw as usize + cx as usize) * 4;
                        image::Rgba([rgba[i], rgba[i + 1], rgba[i + 2], rgba[i + 3]])
                    });
                    (img, (x0 as i32, y0 as i32))
                } else {
                    // The layer is entirely outside the canvas; keep a minimal
                    // transparent placeholder so the layer (and its
                    // properties) survive the import.
                    (RgbaImage::new(1, 1), (0, 0))
                };
                layers.push(Layer {
                    pixels: Arc::new(pixels),
                    offset,
                    name: l.name().to_string(),
                    opacity: f32::from(l.opacity()) / 255.0,
                    blend: map_psd_blend(l.blend_mode() as i32),
                    visible: !l.visible(),
                    // PSD layer masks are not imported (the crate exposes them
                    // only as raw channel data); imported layers arrive
                    // unmasked. PSD `lfx2` layer effects are not imported
                    // either (the crate discards the block), so no layer
                    // style. The clipping bit IS imported, inverted — see the
                    // quirk list on `open_psd`.
                    mask: None,
                    mask_enabled: true,
                    meta: None,
                    clipped: !l.is_clipping_mask(),
                    style: None,
                    kind: LayerKind::Raster,
                    depth,
                    // `lspf` is discarded by the crate's block walk, so
                    // imported layers arrive unlocked; nothing in a PSD
                    // corresponds to our link groups.
                    locks: 0,
                    link: 0,
                    open: true,
                });
            }
        }
    });
    // A decode failure, or a tree the crate described in a way this walk could
    // not place anything from, both fall back to the flattened composite: a
    // document must always hold at least one entry, and half a stack is worse
    // than a picture.
    if failed || layers.is_empty() {
        return psd_composite_fallback(&psd, path);
    }
    if !validate_structure(&layers) {
        return Err(format!("PSD {path}: malformed layer group structure"));
    }
    Ok(RzDocument {
        width: cw,
        height: ch,
        layers,
        global_light: GlobalLight::default(),
        // PSD alpha channels are not imported (the crate exposes only the
        // composite and per-layer raster data), so an imported document
        // arrives with no channels. Nor is the image-resources section, of
        // which `psd` 0.3.5 exposes only Slices: the resolution (id 1005)
        // and the ICC profile (id 1039) are unreachable, so an imported
        // document takes the sRGB / no-metadata / 72 ppi defaults.
        channels: Vec::new(),
        // PSD guides and the ruler origin live in image resource 1032, which
        // `psd` 0.3.5 does not expose either, so an imported document arrives
        // with no guides and its ruler zero at the canvas's top-left.
        guides: Vec::new(),
        ruler_origin: (0.0, 0.0),
        profile: IccProfile::srgb(),
        metadata: Metadata::default(),
        resolution: Resolution::default(),
    })
}

/// One node of a PSD's layer tree: a raster layer at its flat `layers()`
/// index, or a group by its crate id.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Node {
    Layer(usize),
    Group(u32),
}

/// The PSD's tree, rebuilt from `parent_id()` alone: each parent's children in
/// BOTTOM-FIRST order, which is the order our stack wants.
///
/// The ordering key is each node's position in the crate's TOP-DOWN
/// `layers()` list — a layer is at its own flat index, and a group's folder
/// row sits immediately above its contents, so a group takes the flat index
/// its descendants begin at, with groups before the layer at the same index
/// and nested groups outermost first (ids are assigned in top-down OPEN
/// order, so the outer folder gets the smaller id). Reversing that key gives
/// bottom-first.
struct PsdTree {
    children: HashMap<Option<u32>, Vec<Node>>,
}

/// One node with its TOP-DOWN sort key: `(position, groups-first, group id)`.
type Keyed = (usize, u8, u32, Node);

impl PsdTree {
    fn build(psd: &psd::Psd) -> Self {
        let mut keyed: HashMap<Option<u32>, Vec<Keyed>> = HashMap::new();
        for (i, layer) in psd.layers().iter().enumerate() {
            keyed
                .entry(layer.parent_id())
                .or_default()
                // 1 = "after a group at the same index": the folder row comes
                // first in top-down order.
                .push((i, 1, 0, Node::Layer(i)));
        }
        for (&id, group) in psd.groups() {
            let start = group_start(psd, id);
            keyed
                .entry(group.parent_id())
                .or_default()
                .push((start, 0, id, Node::Group(id)));
        }
        let children = keyed
            .into_iter()
            .map(|(parent, mut nodes)| {
                nodes.sort_by_key(|&(start, group_last, id, _)| (start, group_last, id));
                // Top-down -> bottom-first.
                nodes.reverse();
                (parent, nodes.into_iter().map(|(_, _, _, n)| n).collect())
            })
            .collect();
        PsdTree { children }
    }

    /// Walks `parent`'s children bottom-first, emitting each node — a group's
    /// descendants first, then the group's own record, which is exactly
    /// `doc_group`'s layout. A group that would push its children past
    /// [`MAX_GROUP_DEPTH`] is DISSOLVED: its children take the cap's depth as
    /// siblings and its folder row is dropped, so the invariant holds and only
    /// the container is lost.
    fn emit(&self, parent: Option<u32>, depth: u16, out: &mut impl FnMut(Node, u16)) {
        let Some(nodes) = self.children.get(&parent) else {
            return;
        };
        for &node in nodes {
            match node {
                Node::Layer(_) => out(node, depth.min(MAX_GROUP_DEPTH)),
                Node::Group(id) if depth >= MAX_GROUP_DEPTH => {
                    self.emit(Some(id), MAX_GROUP_DEPTH, out)
                }
                Node::Group(id) => {
                    self.emit(Some(id), depth + 1, out);
                    out(node, depth);
                }
            }
        }
    }
}

/// The flat `layers()` index group `id`'s contents begin at — the position its
/// folder row occupies in the crate's TOP-DOWN ordering, since a folder row
/// sits immediately above its contents.
///
/// `get_group_sub_layers` returns `&layers[range]`, so even for an EMPTY group
/// (length 0) the slice's ADDRESS is `layers.as_ptr() + range.start`, which is
/// the only way this crate exposes an empty group's position at all — it has
/// no descendants to be anchored by. The offset is computed in `usize` (so a
/// slice from anywhere else wraps instead of misbehaving) and clamped to the
/// layer count, which parks an unplaceable group at the bottom of its parent;
/// it has no pixels, so nothing about the picture depends on it.
fn group_start(psd: &psd::Psd, id: u32) -> usize {
    let layers = psd.layers();
    let Some(first) = layers.first() else {
        return 0;
    };
    let Some(sub) = psd.get_group_sub_layers(&id) else {
        return layers.len();
    };
    let stride = std::mem::size_of_val(first);
    let base = layers.as_ptr() as usize;
    ((sub.as_ptr() as usize).wrapping_sub(base) / stride.max(1)).min(layers.len())
}
