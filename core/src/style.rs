//! Layer styles (Photoshop's Layer Style dialog): the per-layer effect stack
//! plus the blending options beyond opacity and mode — `fill_opacity` and
//! Blend If — and the document's shared global light. This module holds the
//! MODEL: the types, their defaults, the identity rule and the semantics
//! helpers the compositor and the transforms need. The JSON codec lives in
//! `style_json`, the plane renderer and its cache in `style_render`, the
//! compositing assembly in `style_composite`, and each effect's algorithm in
//! its own `style_fx_*` module. The header's "Layer styles" section points
//! here for the full key table — this module doc IS the schema, the way
//! `adjust`'s is for adjustment meta.
//!
//! # The style JSON (the contract across the FFI, in `.rz`, and over MCP)
//!
//! One JSON object per layer:
//!
//! ```json
//! {
//!   "version": 1,
//!   "fill_opacity": 1.0,
//!   "blend_if": null,
//!   "effects": [ { "type": "drop_shadow", ... }, ... ]
//! }
//! ```
//!
//! | key            | type / range                                                        | default |
//! |----------------|---------------------------------------------------------------------|---------|
//! | `version`      | integer, ignored on input, written as 1                             | 1       |
//! | `fill_opacity` | number 0..=1 (opacity of the PIXELS only, never of effects)         | 1.0     |
//! | `blend_if`     | `null` or the object below                                          | null    |
//! | `effects`      | array of effect objects, at most one per `type`, any input order    | `[]`    |
//!
//! `blend_if` object: `channel` — `"gray"` | `"red"` | `"green"` | `"blue"`
//! (default `"gray"`); `this_layer` and `underlying` — arrays of exactly 4
//! integers 0..=255 with `lo0 <= lo1 <= hi0 <= hi1` (default
//! `[0, 0, 255, 255]` = full weight everywhere).
//!
//! Every effect object has `type` (required string) and `enabled` (bool,
//! default true; a disabled effect is kept, serialized, and not rendered).
//! `blend` values are the 27 layer blend modes as snake_case Photoshop names:
//! `normal, dissolve, darken, multiply, color_burn, linear_burn, darker_color,
//! lighten, screen, color_dodge, linear_dodge, lighter_color, overlay,
//! soft_light, hard_light, vivid_light, linear_light, pin_light, hard_mix,
//! difference, exclusion, subtract, divide, hue, saturation, color,
//! luminosity` (`linear_dodge` is `BlendMode::Addition`). Colours are
//! `"#rrggbb"` (case-insensitive; `"#rrggbbaa"` accepted, alpha ignored).
//! Angles are degrees in the Photoshop convention (0 = light from the right,
//! 90 = from the top). Pixel sizes are canvas pixels.
//!
//! | `type`             | keys (type, range, default)                                                    |
//! |--------------------|--------------------------------------------------------------------------------|
//! | `drop_shadow`      | `blend` (multiply), `color` (#000000), `opacity` 0..=1 (0.75), `angle` (120),  |
//! |                    | `use_global_light` (true), `distance` px 0..=30000 (5), `spread` 0..=1 fraction |
//! |                    | of size (0), `size` px 0..=250 (5), `layer_knocks_out` bool (true — "Layer     |
//! |                    | Knocks Out Drop Shadow": the shadow is not drawn under the layer's own shape)   |
//! | `inner_shadow`     | `blend` (multiply), `color` (#000000), `opacity` (0.75), `angle` (120),         |
//! |                    | `use_global_light` (true), `distance` (5), `choke` 0..=1 (0), `size` (5)       |
//! | `outer_glow`       | `blend` (screen), `color` (#ffffbe), `opacity` (0.75), `spread` (0), `size` (5) |
//! | `inner_glow`       | `blend` (screen), `color` (#ffffbe), `opacity` (0.75), `choke` (0), `size` (5), |
//! |                    | `source` `"edge"` \| `"center"` (edge)                                          |
//! | `stroke`           | `blend` (normal), `opacity` (1.0), `size` px 0..=250 (3), `position`            |
//! |                    | `"outside"` \| `"inside"` \| `"center"` (outside), `fill_type` `"color"` \|     |
//! |                    | `"gradient"` (color), `color` (#000000), `gradient` (GradientFill)              |
//! | `color_overlay`    | `blend` (normal), `color` (#ff0000), `opacity` (1.0)                            |
//! | `gradient_overlay` | `blend` (normal), `opacity` (1.0), `gradient` (GradientFill)                    |
//! | `bevel_emboss`     | `style` `"outer_bevel"` \| `"inner_bevel"` \| `"emboss"` \| `"pillow_emboss"`  |
//! |                    | (inner_bevel), `depth` 0.01..=10 (1.0 = Photoshop 100 %), `direction` `"up"` \| |
//! |                    | `"down"` (up), `size` px 0..=250 (5), `soften` px 0..=16 (0), `angle` (120),    |
//! |                    | `use_global_light` (true), `altitude` 0..=90 (30), `highlight_blend` (screen),  |
//! |                    | `highlight_color` (#ffffff), `highlight_opacity` (0.75), `shadow_blend`         |
//! |                    | (multiply), `shadow_color` (#000000), `shadow_opacity` (0.75)                   |
//! | `satin`            | `blend` (multiply), `color` (#000000), `opacity` (0.5), `angle` (19),           |
//! |                    | `distance` px (11), `size` px (14), `invert` bool (true)                        |
//!
//! GradientFill object (shared by `stroke` and `gradient_overlay`): `stops` —
//! array of 2..=32 `{ "position": 0..=1, "color": hex, "opacity": 0..=1 }`
//! (stable-sorted by position on parse; default
//! `[{0, "#000000", 1}, {1, "#ffffff", 1}]`); `style` `"linear"` |
//! `"radial"` | `"angle"` | `"reflected"` | `"diamond"` (linear); `angle` deg
//! (90); `scale` 0.1..=1.5 (1.0); `reverse` bool (false); `align_with_layer`
//! bool (true).
//!
//! Parse rules (STRICT mode, the FFI setter): unknown keys anywhere are
//! ignored (host versioning room); a missing key takes its default; a key
//! present with the wrong JSON type, a non-finite number, an unknown enum
//! string, an unparseable colour, an unknown effect `type`, a second effect
//! of the same `type`, or a Blend If ramp out of order makes the whole style
//! malformed (an error naming the path, e.g. `effects[1].size must be a
//! number`). Numeric ranges are CLAMPED, not refused (Photoshop's dialog
//! clamps too); angles are normalized into `[-180, 180)`; every number is
//! quantized to 4 decimals at parse time so the stored value IS its canonical
//! form. LENIENT mode (the RZDC reader only): an unknown effect `type` is
//! skipped, a duplicate `type` keeps the first, an unknown enum string takes
//! the enum's default; every other rule stays strict. One parser, one
//! `Strictness` parameter. The canonical writer (`to_json`) emits EVERY key
//! of every present effect, effects in render order, sorted keys, lowercase
//! colours. Stroke emboss, contours, textures, pattern overlay, glow
//! technique/range/jitter, noise, anti-aliasing toggles,
//! `blend_interior_as_group` and knockout are NOT in this phase.
//!
//! # Photoshop conventions (numerics; one home each, in `style_render`)
//!
//! Light offset `(round(-d cos a), round(+d sin a))` in y-down pixel space
//! (120° casts down-right). `size` is the blur extent in px with Gaussian
//! `sigma = size / 2`; `spread`/`choke` is a fraction of size — dilate (or
//! erode) by `size * spread`, then blur by `size * (1 - spread)`. Effects
//! with `use_global_light` read the document's `GlobalLight` (angle,
//! altitude; defaults 120°, 30°) instead of their own angle.
//!
//! # Identity, lifetime, scaling
//!
//! A style is IDENTITY when `fill_opacity == 1`, `blend_if` is absent or
//! full-weight, and no effect is enabled. THE ONE RULE:
//! [`RzDocument::set_layer_style`] with an identity style behaves exactly
//! like clearing — an identity style is never stored, so
//! `Layer::style.is_some()` means "renders something" on every surface.
//!
//! A style rides along like meta (setters, painting, mask ops, geometry,
//! reordering, crop/canvas-resize), is copied by Duplicate Layer, and is
//! DROPPED where the layer stops being itself: Merge Down and Flatten bake
//! the effects into pixels through the projection and clear it. Adjustment
//! layers ignore styles (they have no shape). Free Transform, perspective
//! and Image Size apply "Scale Effects" in the core ([`LayerStyle::scaled`]
//! by the mean scale factor), so every host path agrees.

use std::sync::Arc;

use crate::adjust::Adjustment;
use crate::doc::{Layer, RzDocument};
use crate::style_cache::RenderCache;
use crate::style_json::{Range, RANGES};
use crate::style_render::light_offset;

pub use crate::style_effects::{
    BevelEmboss, ColorOverlay, DropShadow, Effect, EffectKind, GradientOverlay, InnerGlow,
    InnerShadow, OuterGlow, Satin, Stroke,
};
pub use crate::style_model::{
    BevelDirection, BevelStyle, BlendIf, BlendIfChannel, GlobalLight, GlowSource, GradientFill,
    GradientStop, GradientStyle, Strictness, StrokeFill, StrokePosition, FULL_RAMP,
};
pub use crate::style_names::{blend_mode_from_name, blend_mode_name, color_hex, parse_color};

/// Largest padding a style may ask a shape plane for, in px on each side.
/// The per-effect caps (size 250, soften 16, distance 30000) already bound
/// every reach except the inner shadow's `distance`, which shifts inside the
/// plane; 1024 keeps a hostile distance from turning a 1x1 layer into a
/// multi-megapixel plane while still covering every size the dialog offers.
pub(crate) const MAX_PAD: u32 = 1024;

// ------------------------------------------------------------ the style --

/// A layer's complete style: the blending options and the effect stack.
/// INVARIANT: `effects` is sorted by [`Effect::kind`] with at most one
/// effect per kind — the parser enforces it and [`LayerStyle::normalized`]
/// re-establishes it for directly constructed values.
#[derive(Clone, Debug, PartialEq)]
pub struct LayerStyle {
    pub fill_opacity: f32,
    pub blend_if: Option<BlendIf>,
    pub effects: Vec<Effect>,
    /// The rendered-plane cache (see `style_render`); lives in the style so
    /// every document sharing this `Arc<LayerStyle>` shares the planes.
    pub(crate) cache: RenderCache,
}

impl Default for LayerStyle {
    fn default() -> Self {
        LayerStyle {
            fill_opacity: 1.0,
            blend_if: None,
            effects: Vec::new(),
            cache: RenderCache::default(),
        }
    }
}

impl LayerStyle {
    /// True when the style renders nothing at all: fill opacity 1, no
    /// (effective) Blend If, and no ENABLED effect. Identity styles are never
    /// stored (see [`RzDocument::set_layer_style`]).
    pub fn is_identity(&self) -> bool {
        self.fill_opacity >= 1.0
            && self.blend_if.is_none_or(|b| b.is_identity())
            && !self.has_enabled_effects()
    }

    /// Whether any effect is enabled (the only case that renders planes).
    pub fn has_enabled_effects(&self) -> bool {
        self.effects.iter().any(Effect::enabled)
    }

    /// The effect of `kind`, present or not enabled.
    pub fn effect(&self, kind: EffectKind) -> Option<&Effect> {
        self.effects.iter().find(|e| e.kind() == kind)
    }

    /// Enabled effects only, in render order.
    pub(crate) fn enabled_effects(&self) -> impl Iterator<Item = &Effect> {
        self.effects.iter().filter(|e| e.enabled())
    }

    /// Padding, in px on each side, the shape plane needs so every enabled
    /// effect renders exactly as it would on an infinite plane: the largest
    /// per-effect reach plus one, capped at [`MAX_PAD`]. Zero with no
    /// enabled effect. Because a reach also bounds how far an input change
    /// moves an output, this is the radius of the cache's incremental
    /// re-render windows too (`style_cache`).
    pub fn pad(&self) -> u32 {
        self.wanted_pad().min(MAX_PAD)
    }

    /// The padding the enabled effects ask for before the cap.
    fn wanted_pad(&self) -> u32 {
        self.enabled_effects()
            .map(|e| e.reach().saturating_add(1))
            .max()
            .unwrap_or(0)
    }

    /// True when [`pad`](Self::pad) is the cap rather than the effects'
    /// full reach. A FULL render stays exact then: only an inner shadow's
    /// or a satin's `distance` can exceed the cap, their shifts fill from
    /// beyond the plane with what an infinite plane holds there (255 for
    /// the inverted plane, 0 for the blurred coverage — every blur reach is
    /// far below the cap), and both are clipped to the shape. But an input
    /// change can then move an output by MORE than `pad`, so the cache's
    /// incremental sub-plane re-render — whose windows are sized by `pad` —
    /// must fall back to a full render (`style_cache`).
    pub(crate) fn pad_is_capped(&self) -> bool {
        self.wanted_pad() > MAX_PAD
    }

    /// The composite-time offset of an enabled drop shadow under `light`
    /// (`style_render::light_offset` of its resolved angle and distance) —
    /// the only contribution that lands beyond the padded plane, and what
    /// Merge Down grows its extent by in that direction. `None` without an
    /// enabled drop shadow.
    pub fn shadow_shift(&self, light: GlobalLight) -> Option<(i32, i32)> {
        self.enabled_effects().find_map(|e| match e {
            Effect::DropShadow(d) => Some(light_offset(d.resolved_angle(light), d.distance)),
            _ => None,
        })
    }

    /// The enabled gradients (stroke fill or overlay), if any.
    fn gradients(&self) -> impl Iterator<Item = &GradientFill> {
        self.enabled_effects().filter_map(|e| match e {
            Effect::Stroke(s) if s.fill_type == StrokeFill::Gradient => Some(&s.gradient),
            Effect::GradientOverlay(g) => Some(&g.gradient),
            _ => None,
        })
    }

    /// True when a rendered plane depends on where the layer sits on the
    /// canvas: a gradient with `align_with_layer == false`.
    pub fn needs_canvas_alignment(&self) -> bool {
        self.gradients().any(|g| !g.align_with_layer)
    }

    /// True when a rendered plane depends on the layer's content bounds: a
    /// gradient with `align_with_layer == true` spans them (the cache cannot
    /// patch such planes locally when the bounds change).
    pub fn needs_shape_bounds(&self) -> bool {
        self.gradients().any(|g| g.align_with_layer)
    }

    /// True when any ENABLED effect reads the document's global light.
    pub fn uses_global_light(&self) -> bool {
        self.enabled_effects().any(|e| match e {
            Effect::DropShadow(d) => d.use_global_light,
            Effect::InnerShadow(s) => s.use_global_light,
            Effect::BevelEmboss(b) => b.use_global_light,
            _ => false,
        })
    }

    /// Re-establishes the effects invariant for a directly constructed
    /// style: sorted by kind, the first of any duplicated kind kept. The
    /// cache is fresh.
    pub fn normalized(mut self) -> Self {
        self.effects.sort_by_key(Effect::kind);
        self.effects.dedup_by_key(|e| e.kind());
        self.cache = RenderCache::default();
        self
    }

    /// "Scale Effects": every pixel-valued field multiplied by `factor` —
    /// shadow/glow `size`, shadow `distance`, stroke `size`, bevel `size` and
    /// `soften`, satin `distance` and `size` — re-clamped and re-quantized
    /// exactly as the parser would. `spread`/`choke` are fractions of size,
    /// and depth, opacities, angles, colours and the gradient scale are not
    /// pixel quantities, so they stay. Fresh cache.
    pub fn scaled(&self, factor: f64) -> LayerStyle {
        let px = |v: f32, range: Range| range.apply(f64::from(v) * factor);
        let effects = self
            .effects
            .iter()
            .map(|e| match e {
                Effect::DropShadow(d) => Effect::DropShadow(DropShadow {
                    distance: px(d.distance, RANGES.distance),
                    size: px(d.size, RANGES.size),
                    ..d.clone()
                }),
                Effect::InnerShadow(s) => Effect::InnerShadow(InnerShadow {
                    distance: px(s.distance, RANGES.distance),
                    size: px(s.size, RANGES.size),
                    ..s.clone()
                }),
                Effect::OuterGlow(g) => Effect::OuterGlow(OuterGlow {
                    size: px(g.size, RANGES.size),
                    ..g.clone()
                }),
                Effect::InnerGlow(g) => Effect::InnerGlow(InnerGlow {
                    size: px(g.size, RANGES.size),
                    ..g.clone()
                }),
                Effect::Stroke(s) => Effect::Stroke(Stroke {
                    size: px(s.size, RANGES.size),
                    ..s.clone()
                }),
                Effect::BevelEmboss(b) => Effect::BevelEmboss(BevelEmboss {
                    size: px(b.size, RANGES.size),
                    soften: px(b.soften, RANGES.soften),
                    ..b.clone()
                }),
                Effect::Satin(s) => Effect::Satin(Satin {
                    distance: px(s.distance, RANGES.distance),
                    size: px(s.size, RANGES.size),
                    ..s.clone()
                }),
                Effect::ColorOverlay(_) | Effect::GradientOverlay(_) => e.clone(),
            })
            .collect();
        LayerStyle {
            fill_opacity: self.fill_opacity,
            blend_if: self.blend_if,
            effects,
            cache: RenderCache::default(),
        }
    }
}

/// [`LayerStyle::scaled`] on an optional shared style: the SAME `Arc` comes
/// back when there is no style, `factor` is within 1e-6 of 1 (an exact
/// translation or rotation: `sqrt(|det|)` of a rotation is 1 only up to
/// floating-point residue), `factor` is not a positive finite number, or
/// nothing would change after re-quantization — so a no-op transform keeps
/// the cache warm.
pub(crate) fn scaled_style(
    style: &Option<Arc<LayerStyle>>,
    factor: f64,
) -> Option<Arc<LayerStyle>> {
    let current = style.as_ref()?;
    if !factor.is_finite() || factor <= 0.0 || (factor - 1.0).abs() < 1e-6 {
        return Some(Arc::clone(current));
    }
    let scaled = current.scaled(factor);
    if scaled == **current {
        return Some(Arc::clone(current));
    }
    Some(Arc::new(scaled))
}

/// The mean scale a perspective warp applies to a `lw` x `lh` layer whose
/// corners land on `quad` (x, y pairs in corner order): the square root of
/// the area ratio, with the quad's area from the shoelace formula. The area
/// — never the bounding box — is what stays 1 for a pure rotation, and it
/// equals `sqrt(|det|)` when the quad is a parallelogram, so the affine and
/// perspective commit paths agree.
pub(crate) fn quad_mean_scale(quad: [f64; 8], lw: u32, lh: u32) -> f64 {
    let mut twice_area = 0.0;
    for i in 0..4 {
        let (x0, y0) = (quad[2 * i], quad[2 * i + 1]);
        let j = (i + 1) % 4;
        let (x1, y1) = (quad[2 * j], quad[2 * j + 1]);
        twice_area += x0 * y1 - x1 * y0;
    }
    let source = f64::from(lw) * f64::from(lh);
    if source <= 0.0 {
        return 1.0;
    }
    (twice_area.abs() / 2.0 / source).sqrt()
}

impl Layer {
    /// The style the compositor must render for this layer: `Some` only when
    /// a style is present and the meta does not parse as an adjustment
    /// (adjustment layers have no shape and ignore styles). Identity styles
    /// are never stored, so `Some` means "renders something".
    ///
    /// A GROUP may carry a style; an adjustment layer may not. A group's shape
    /// is its own rendered projection — `doc_group::rendered_group` hands the
    /// style to the SYNTHETIC layer, so `Shape::of_layer` gets real pixels and
    /// nothing here needs a group branch.
    pub(crate) fn renders_style(&self) -> Option<&LayerStyle> {
        let style = self.style.as_deref()?;
        if self
            .meta
            .as_deref()
            .and_then(Adjustment::from_meta)
            .is_some()
        {
            return None;
        }
        Some(style)
    }
}

impl RzDocument {
    /// Pure setter: replaces layer `idx`'s style with `style`, or clears it
    /// when `None`. An identity style CLEARS — it is mapped to `None` before
    /// anything else, so a stored style always renders something. `None`
    /// (a refusal, never an identical copy) on an out-of-range `idx` or when
    /// the new value equals the current one, "no style" included.
    ///
    /// The one side effect, invisible to every projection: the style being
    /// replaced hands its rendered-plane cache to the new one
    /// ([`LayerStyle::inherit_planes`]) and keeps none of it. The planes
    /// are a memo, not state — a document that still holds the old `Arc`
    /// (an undo snapshot, the sheet's preview base) re-renders once if it
    /// is ever projected again — and without the hand-over every style
    /// version an agent or the Layer Style sheet minted would pin a full
    /// plane set for as long as the undo stack held its document (tens of
    /// versions of a photo-sized layer is gigabytes), while the new version
    /// re-blurred planes that only changed colour.
    pub fn set_layer_style(&self, idx: usize, style: Option<Arc<LayerStyle>>) -> Option<Self> {
        let style = style.filter(|s| !s.is_identity());
        let layer = self.layers.get(idx)?;
        if layer.style == style {
            return None;
        }
        if let Some(previous) = layer.style.as_deref() {
            match style.as_deref() {
                Some(next) => next.inherit_planes(previous),
                None => previous.cache.clear(),
            }
        }
        let mut doc = self.clone();
        doc.layers[idx].style = style;
        Some(doc)
    }

    /// Pure setter: replaces the document's global light with `light`
    /// sanitized ([`GlobalLight::sane`]). `None` on a non-finite component
    /// or when nothing changes after sanitizing.
    pub fn set_global_light(&self, light: GlobalLight) -> Option<Self> {
        if !light.angle.is_finite() || !light.altitude.is_finite() {
            return None;
        }
        let light = light.sane();
        if light == self.global_light {
            return None;
        }
        let mut doc = self.clone();
        doc.global_light = light;
        Some(doc)
    }
}
