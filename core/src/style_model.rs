//! The layer-style MODEL's shared value types: the document's global
//! light, Blend If, the gradient fill, the small enums every effect pane
//! offers, and the parser's strictness switch. The nine effect structs live
//! in `style_effects`, the `LayerStyle` itself (with the identity rule, the
//! padding arithmetic and Scale Effects) in `style`, which re-exports
//! everything here so `style::GlobalLight` stays the public path. The JSON
//! schema table is `style`'s module doc.

use crate::style_json::{canonical_angle, RANGES};

/// Direction of the document's shared light source, in degrees: `angle` in
/// the Photoshop convention (0 = from the right, 90 = from the top) and
/// `altitude` above the canvas plane (90 = straight down).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct GlobalLight {
    pub angle: f32,
    pub altitude: f32,
}

impl Default for GlobalLight {
    fn default() -> Self {
        GlobalLight {
            angle: 120.0,
            altitude: 30.0,
        }
    }
}

impl GlobalLight {
    /// The ONE sanitizer, used by the setter, the RZDC reader and the FFI: a
    /// non-finite component takes its default, altitude clamps to [0, 90],
    /// angle normalizes to [-180, 180), and both are quantized to four
    /// decimals through the style parser's own canonicalizers
    /// (`style_json::canonical_angle`, the `RANGES` clamp table) — so the
    /// stored light IS its canonical form exactly like every style number,
    /// and a host that echoes the reported four-decimal value back through
    /// the setter is refused as unchanged instead of registering a phantom
    /// edit. Sanitized values compare with plain `==` (the cache key relies
    /// on it).
    pub fn sane(self) -> Self {
        let default = GlobalLight::default();
        let angle = if self.angle.is_finite() {
            canonical_angle(f64::from(self.angle))
        } else {
            default.angle
        };
        let altitude = if self.altitude.is_finite() {
            RANGES.altitude.apply(f64::from(self.altitude))
        } else {
            default.altitude
        };
        GlobalLight { angle, altitude }
    }
}

// ------------------------------------------------------------- blend if --

/// Which channel Blend If evaluates its ramps on.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum BlendIfChannel {
    #[default]
    Gray,
    Red,
    Green,
    Blue,
}

/// Blending Options > Blend If: two split-slider pairs `[lo0, lo1, hi0, hi1]`
/// over 0..=255 — one evaluated on this layer's pixels, one on the composite
/// beneath — whose product weights the layer's alpha.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct BlendIf {
    pub channel: BlendIfChannel,
    pub this_layer: [u8; 4],
    pub underlying: [u8; 4],
}

/// The ramp that weights every value 1.
pub const FULL_RAMP: [u8; 4] = [0, 0, 255, 255];

impl Default for BlendIf {
    fn default() -> Self {
        BlendIf {
            channel: BlendIfChannel::Gray,
            this_layer: FULL_RAMP,
            underlying: FULL_RAMP,
        }
    }
}

impl BlendIf {
    /// True when both ramps weight every value 1 (the channel is then moot).
    pub fn is_identity(&self) -> bool {
        self.this_layer == FULL_RAMP && self.underlying == FULL_RAMP
    }
}

// -------------------------------------------------------------- gradients --

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct GradientStop {
    pub position: f32,
    pub color: [u8; 3],
    pub opacity: f32,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum GradientStyle {
    #[default]
    Linear,
    Radial,
    Angle,
    Reflected,
    Diamond,
}

/// A gradient fill shared by Stroke (gradient fill type) and Gradient
/// Overlay; see the module doc for the key table.
#[derive(Clone, Debug, PartialEq)]
pub struct GradientFill {
    pub stops: Vec<GradientStop>,
    pub style: GradientStyle,
    pub angle: f32,
    pub scale: f32,
    pub reverse: bool,
    pub align_with_layer: bool,
}

impl Default for GradientFill {
    fn default() -> Self {
        GradientFill {
            stops: vec![
                GradientStop {
                    position: 0.0,
                    color: [0, 0, 0],
                    opacity: 1.0,
                },
                GradientStop {
                    position: 1.0,
                    color: [255, 255, 255],
                    opacity: 1.0,
                },
            ],
            style: GradientStyle::Linear,
            angle: 90.0,
            scale: 1.0,
            reverse: false,
            align_with_layer: true,
        }
    }
}

// ---------------------------------------------------------- effect enums --

#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum GlowSource {
    #[default]
    Edge,
    Center,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum StrokePosition {
    #[default]
    Outside,
    Inside,
    Center,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum StrokeFill {
    #[default]
    Color,
    Gradient,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum BevelStyle {
    OuterBevel,
    #[default]
    InnerBevel,
    Emboss,
    PillowEmboss,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum BevelDirection {
    #[default]
    Up,
    Down,
}

/// Strict = the FFI setter (an unknown `type`/enum value is malformed);
/// Lenient = the RZDC reader (unknown types skipped, unknown enum values
/// defaulted — a file from a newer build keeps the effects this build knows).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Strictness {
    Strict,
    Lenient,
}
