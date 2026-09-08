//! The nine layer-style effects (Photoshop's Layer Style dialog, one struct
//! each with the schema defaults of `style`'s module doc), the
//! [`EffectKind`] enumeration whose declaration order is the canonical JSON
//! order and the render order, and the [`Effect`] sum type with each
//! effect's plane REACH — the input to `LayerStyle::pad`. `style` re-exports
//! everything here.

use crate::blend::BlendMode;
use crate::style_fx_bevel_emboss::stencil_half_width;
use crate::style_model::{
    BevelDirection, BevelStyle, GlobalLight, GlowSource, GradientFill, StrokeFill, StrokePosition,
};
use crate::style_render::{blur_reach, sigma_for_size, spread_split};

#[derive(Clone, Debug, PartialEq)]
pub struct DropShadow {
    pub enabled: bool,
    pub blend: BlendMode,
    pub color: [u8; 3],
    pub opacity: f32,
    pub angle: f32,
    pub use_global_light: bool,
    pub distance: f32,
    pub spread: f32,
    pub size: f32,
    pub layer_knocks_out: bool,
}

impl Default for DropShadow {
    fn default() -> Self {
        DropShadow {
            enabled: true,
            blend: BlendMode::Multiply,
            color: [0, 0, 0],
            opacity: 0.75,
            angle: 120.0,
            use_global_light: true,
            distance: 5.0,
            spread: 0.0,
            size: 5.0,
            layer_knocks_out: true,
        }
    }
}

impl DropShadow {
    /// The angle this effect is lit from: the document's when
    /// `use_global_light`, else its own.
    pub fn resolved_angle(&self, light: GlobalLight) -> f32 {
        if self.use_global_light {
            light.angle
        } else {
            self.angle
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct InnerShadow {
    pub enabled: bool,
    pub blend: BlendMode,
    pub color: [u8; 3],
    pub opacity: f32,
    pub angle: f32,
    pub use_global_light: bool,
    pub distance: f32,
    pub choke: f32,
    pub size: f32,
}

impl Default for InnerShadow {
    fn default() -> Self {
        InnerShadow {
            enabled: true,
            blend: BlendMode::Multiply,
            color: [0, 0, 0],
            opacity: 0.75,
            angle: 120.0,
            use_global_light: true,
            distance: 5.0,
            choke: 0.0,
            size: 5.0,
        }
    }
}

impl InnerShadow {
    /// See [`DropShadow::resolved_angle`].
    pub fn resolved_angle(&self, light: GlobalLight) -> f32 {
        if self.use_global_light {
            light.angle
        } else {
            self.angle
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct OuterGlow {
    pub enabled: bool,
    pub blend: BlendMode,
    pub color: [u8; 3],
    pub opacity: f32,
    pub spread: f32,
    pub size: f32,
}

impl Default for OuterGlow {
    fn default() -> Self {
        OuterGlow {
            enabled: true,
            blend: BlendMode::Screen,
            color: [0xff, 0xff, 0xbe],
            opacity: 0.75,
            spread: 0.0,
            size: 5.0,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct InnerGlow {
    pub enabled: bool,
    pub blend: BlendMode,
    pub color: [u8; 3],
    pub opacity: f32,
    pub choke: f32,
    pub size: f32,
    pub source: GlowSource,
}

impl Default for InnerGlow {
    fn default() -> Self {
        InnerGlow {
            enabled: true,
            blend: BlendMode::Screen,
            color: [0xff, 0xff, 0xbe],
            opacity: 0.75,
            choke: 0.0,
            size: 5.0,
            source: GlowSource::Edge,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Stroke {
    pub enabled: bool,
    pub blend: BlendMode,
    pub opacity: f32,
    pub size: f32,
    pub position: StrokePosition,
    pub fill_type: StrokeFill,
    pub color: [u8; 3],
    pub gradient: GradientFill,
}

impl Default for Stroke {
    fn default() -> Self {
        Stroke {
            enabled: true,
            blend: BlendMode::Normal,
            opacity: 1.0,
            size: 3.0,
            position: StrokePosition::Outside,
            fill_type: StrokeFill::Color,
            color: [0, 0, 0],
            gradient: GradientFill::default(),
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct ColorOverlay {
    pub enabled: bool,
    pub blend: BlendMode,
    pub color: [u8; 3],
    pub opacity: f32,
}

impl Default for ColorOverlay {
    fn default() -> Self {
        ColorOverlay {
            enabled: true,
            blend: BlendMode::Normal,
            color: [0xff, 0, 0],
            opacity: 1.0,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct GradientOverlay {
    pub enabled: bool,
    pub blend: BlendMode,
    pub opacity: f32,
    pub gradient: GradientFill,
}

impl Default for GradientOverlay {
    fn default() -> Self {
        GradientOverlay {
            enabled: true,
            blend: BlendMode::Normal,
            opacity: 1.0,
            gradient: GradientFill::default(),
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct BevelEmboss {
    pub enabled: bool,
    pub style: BevelStyle,
    pub depth: f32,
    pub direction: BevelDirection,
    pub size: f32,
    pub soften: f32,
    pub angle: f32,
    pub use_global_light: bool,
    pub altitude: f32,
    pub highlight_blend: BlendMode,
    pub highlight_color: [u8; 3],
    pub highlight_opacity: f32,
    pub shadow_blend: BlendMode,
    pub shadow_color: [u8; 3],
    pub shadow_opacity: f32,
}

impl Default for BevelEmboss {
    fn default() -> Self {
        BevelEmboss {
            enabled: true,
            style: BevelStyle::InnerBevel,
            depth: 1.0,
            direction: BevelDirection::Up,
            size: 5.0,
            soften: 0.0,
            angle: 120.0,
            use_global_light: true,
            altitude: 30.0,
            highlight_blend: BlendMode::Screen,
            highlight_color: [0xff, 0xff, 0xff],
            highlight_opacity: 0.75,
            shadow_blend: BlendMode::Multiply,
            shadow_color: [0, 0, 0],
            shadow_opacity: 0.75,
        }
    }
}

impl BevelEmboss {
    /// See [`DropShadow::resolved_angle`].
    pub fn resolved_angle(&self, light: GlobalLight) -> f32 {
        if self.use_global_light {
            light.angle
        } else {
            self.angle
        }
    }

    /// The light's altitude: the document's when `use_global_light`, else
    /// the effect's own.
    pub fn resolved_altitude(&self, light: GlobalLight) -> f32 {
        if self.use_global_light {
            light.altitude
        } else {
            self.altitude
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Satin {
    pub enabled: bool,
    pub blend: BlendMode,
    pub color: [u8; 3],
    pub opacity: f32,
    pub angle: f32,
    pub distance: f32,
    pub size: f32,
    pub invert: bool,
}

impl Default for Satin {
    fn default() -> Self {
        Satin {
            enabled: true,
            blend: BlendMode::Multiply,
            color: [0, 0, 0],
            opacity: 0.5,
            angle: 19.0,
            distance: 11.0,
            size: 14.0,
            invert: true,
        }
    }
}

/// The nine effect kinds. Declaration order == canonical JSON order ==
/// render order (Stroke and BevelEmboss decide Below/Interior per
/// contribution; see `style_render`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum EffectKind {
    DropShadow,
    OuterGlow,
    Stroke,
    GradientOverlay,
    ColorOverlay,
    Satin,
    InnerGlow,
    InnerShadow,
    BevelEmboss,
}

impl EffectKind {
    /// Every kind, in render order.
    pub const ALL: [EffectKind; 9] = [
        EffectKind::DropShadow,
        EffectKind::OuterGlow,
        EffectKind::Stroke,
        EffectKind::GradientOverlay,
        EffectKind::ColorOverlay,
        EffectKind::Satin,
        EffectKind::InnerGlow,
        EffectKind::InnerShadow,
        EffectKind::BevelEmboss,
    ];

    /// The JSON `type` string.
    pub fn type_name(self) -> &'static str {
        match self {
            EffectKind::DropShadow => "drop_shadow",
            EffectKind::OuterGlow => "outer_glow",
            EffectKind::Stroke => "stroke",
            EffectKind::GradientOverlay => "gradient_overlay",
            EffectKind::ColorOverlay => "color_overlay",
            EffectKind::Satin => "satin",
            EffectKind::InnerGlow => "inner_glow",
            EffectKind::InnerShadow => "inner_shadow",
            EffectKind::BevelEmboss => "bevel_emboss",
        }
    }

    /// The kind for a JSON `type` string; `None` for anything unknown.
    pub fn from_type_name(name: &str) -> Option<Self> {
        EffectKind::ALL.into_iter().find(|k| k.type_name() == name)
    }
}

/// One effect of the stack.
#[derive(Clone, Debug, PartialEq)]
pub enum Effect {
    DropShadow(DropShadow),
    InnerShadow(InnerShadow),
    OuterGlow(OuterGlow),
    InnerGlow(InnerGlow),
    Stroke(Stroke),
    ColorOverlay(ColorOverlay),
    GradientOverlay(GradientOverlay),
    BevelEmboss(BevelEmboss),
    Satin(Satin),
}

impl Effect {
    pub fn kind(&self) -> EffectKind {
        match self {
            Effect::DropShadow(_) => EffectKind::DropShadow,
            Effect::InnerShadow(_) => EffectKind::InnerShadow,
            Effect::OuterGlow(_) => EffectKind::OuterGlow,
            Effect::InnerGlow(_) => EffectKind::InnerGlow,
            Effect::Stroke(_) => EffectKind::Stroke,
            Effect::ColorOverlay(_) => EffectKind::ColorOverlay,
            Effect::GradientOverlay(_) => EffectKind::GradientOverlay,
            Effect::BevelEmboss(_) => EffectKind::BevelEmboss,
            Effect::Satin(_) => EffectKind::Satin,
        }
    }

    pub fn enabled(&self) -> bool {
        match self {
            Effect::DropShadow(e) => e.enabled,
            Effect::InnerShadow(e) => e.enabled,
            Effect::OuterGlow(e) => e.enabled,
            Effect::InnerGlow(e) => e.enabled,
            Effect::Stroke(e) => e.enabled,
            Effect::ColorOverlay(e) => e.enabled,
            Effect::GradientOverlay(e) => e.enabled,
            Effect::BevelEmboss(e) => e.enabled,
            Effect::Satin(e) => e.enabled,
        }
    }

    /// The effect of `kind` with every key at its default.
    pub fn default_for(kind: EffectKind) -> Effect {
        match kind {
            EffectKind::DropShadow => Effect::DropShadow(DropShadow::default()),
            EffectKind::InnerShadow => Effect::InnerShadow(InnerShadow::default()),
            EffectKind::OuterGlow => Effect::OuterGlow(OuterGlow::default()),
            EffectKind::InnerGlow => Effect::InnerGlow(InnerGlow::default()),
            EffectKind::Stroke => Effect::Stroke(Stroke::default()),
            EffectKind::ColorOverlay => Effect::ColorOverlay(ColorOverlay::default()),
            EffectKind::GradientOverlay => Effect::GradientOverlay(GradientOverlay::default()),
            EffectKind::BevelEmboss => Effect::BevelEmboss(BevelEmboss::default()),
            EffectKind::Satin => Effect::Satin(Satin::default()),
        }
    }

    /// This effect's reach in px: the farthest its plane lands beyond the
    /// shape, or the farthest an input change moves one of its outputs —
    /// whichever is larger. It is the input to [`LayerStyle::pad`], which
    /// sizes both the shape plane's padding and the cache's incremental
    /// re-render windows (`style_cache`), so an interior effect that reads
    /// inward still reports how far it reads. Distance enters only where
    /// the shift happens INSIDE the plane (inner shadow, satin); the drop
    /// shadow's shift is applied at composite time and needs no padding.
    pub(crate) fn reach(&self) -> u32 {
        let ceil = |v: f32| v.max(0.0).ceil() as u32;
        match self {
            Effect::DropShadow(e) => {
                let (dilate, sigma) = spread_split(e.size, e.spread);
                ceil(dilate) + 1 + blur_reach(sigma)
            }
            Effect::OuterGlow(e) => {
                let (dilate, sigma) = spread_split(e.size, e.spread);
                ceil(dilate) + 1 + blur_reach(sigma)
            }
            Effect::InnerShadow(e) => {
                let (dilate, sigma) = spread_split(e.size, e.choke);
                ceil(dilate) + 1 + blur_reach(sigma) + ceil(e.distance)
            }
            Effect::InnerGlow(e) => {
                let (dilate, sigma) = spread_split(e.size, e.choke);
                ceil(dilate) + 1 + blur_reach(sigma)
            }
            // An inside band is `coverage − erode(coverage, size)`: nothing
            // lands beyond the shape, but the erosion reads `size` px
            // inward, so an input change (an erased hole) moves outputs
            // that far — the same radius as the outside band's dilation.
            Effect::Stroke(e) => match e.position {
                StrokePosition::Outside | StrokePosition::Inside => ceil(e.size) + 1,
                StrokePosition::Center => ceil(e.size / 2.0) + 1,
            },
            // The height field is a blur of the coverage, so its outer half
            // reaches a full blur_reach (not `size`); plus the central
            // difference's stencil half-width, which reads that many
            // neighbours further out.
            Effect::BevelEmboss(e) => {
                blur_reach(sigma_for_size(e.size))
                    + blur_reach(sigma_for_size(e.soften))
                    + stencil_half_width(e.size)
            }
            Effect::Satin(e) => blur_reach(sigma_for_size(e.size)) + ceil(e.distance),
            Effect::ColorOverlay(_) | Effect::GradientOverlay(_) => 0,
        }
    }
}
