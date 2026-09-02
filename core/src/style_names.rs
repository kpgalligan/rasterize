//! The name tables of the style JSON — the 27 blend modes, the Blend If
//! channels, the gradient styles, the glow sources, the stroke positions
//! and fills, the bevel styles and directions — one table each, read in
//! both directions by the parser (`style_json`) and the canonical writer
//! (`style_json_write`), plus the public colour and blend-mode name helpers
//! `style` re-exports. The schema table is `style`'s module doc.

use crate::blend::BlendMode;
use crate::style_model::{
    BevelDirection, BevelStyle, BlendIfChannel, GlowSource, GradientStyle, StrokeFill,
    StrokePosition,
};

/// The 27 blend modes by their snake_case Photoshop names (`linear_dodge`
/// is `Addition`); one table serves both directions.
pub(crate) const BLEND_NAMES: [(&str, BlendMode); 27] = [
    ("normal", BlendMode::Normal),
    ("dissolve", BlendMode::Dissolve),
    ("darken", BlendMode::Darken),
    ("multiply", BlendMode::Multiply),
    ("color_burn", BlendMode::ColorBurn),
    ("linear_burn", BlendMode::LinearBurn),
    ("darker_color", BlendMode::DarkerColor),
    ("lighten", BlendMode::Lighten),
    ("screen", BlendMode::Screen),
    ("color_dodge", BlendMode::ColorDodge),
    ("linear_dodge", BlendMode::Addition),
    ("lighter_color", BlendMode::LighterColor),
    ("overlay", BlendMode::Overlay),
    ("soft_light", BlendMode::SoftLight),
    ("hard_light", BlendMode::HardLight),
    ("vivid_light", BlendMode::VividLight),
    ("linear_light", BlendMode::LinearLight),
    ("pin_light", BlendMode::PinLight),
    ("hard_mix", BlendMode::HardMix),
    ("difference", BlendMode::Difference),
    ("exclusion", BlendMode::Exclusion),
    ("subtract", BlendMode::Subtract),
    ("divide", BlendMode::Divide),
    ("hue", BlendMode::Hue),
    ("saturation", BlendMode::Saturation),
    ("color", BlendMode::Color),
    ("luminosity", BlendMode::Luminosity),
];

pub(crate) const CHANNELS: [(&str, BlendIfChannel); 4] = [
    ("gray", BlendIfChannel::Gray),
    ("red", BlendIfChannel::Red),
    ("green", BlendIfChannel::Green),
    ("blue", BlendIfChannel::Blue),
];

pub(crate) const GRADIENT_STYLES: [(&str, GradientStyle); 5] = [
    ("linear", GradientStyle::Linear),
    ("radial", GradientStyle::Radial),
    ("angle", GradientStyle::Angle),
    ("reflected", GradientStyle::Reflected),
    ("diamond", GradientStyle::Diamond),
];

pub(crate) const GLOW_SOURCES: [(&str, GlowSource); 2] =
    [("edge", GlowSource::Edge), ("center", GlowSource::Center)];

pub(crate) const STROKE_POSITIONS: [(&str, StrokePosition); 3] = [
    ("outside", StrokePosition::Outside),
    ("inside", StrokePosition::Inside),
    ("center", StrokePosition::Center),
];

pub(crate) const STROKE_FILLS: [(&str, StrokeFill); 2] = [
    ("color", StrokeFill::Color),
    ("gradient", StrokeFill::Gradient),
];

pub(crate) const BEVEL_STYLES: [(&str, BevelStyle); 4] = [
    ("outer_bevel", BevelStyle::OuterBevel),
    ("inner_bevel", BevelStyle::InnerBevel),
    ("emboss", BevelStyle::Emboss),
    ("pillow_emboss", BevelStyle::PillowEmboss),
];

pub(crate) const BEVEL_DIRECTIONS: [(&str, BevelDirection); 2] =
    [("up", BevelDirection::Up), ("down", BevelDirection::Down)];

/// The JSON name of a blend mode.
pub fn blend_mode_name(mode: BlendMode) -> &'static str {
    enum_name(&BLEND_NAMES, mode)
}

/// The blend mode for a JSON name; `None` for anything unknown.
pub fn blend_mode_from_name(name: &str) -> Option<BlendMode> {
    BLEND_NAMES
        .iter()
        .find(|(n, _)| *n == name)
        .map(|(_, m)| *m)
}

/// Parses `#rrggbb` or `#rrggbbaa` (case-insensitive; alpha ignored);
/// `None` for anything else. Works on the BYTES, one hex digit at a time:
/// slicing the `&str` by byte index would panic on a multi-byte character
/// straddling the slice (`"#aé123"` is six bytes after the `#`), and
/// `u8::from_str_radix` would accept a sign (`"#+1+2+3"`), which no colour
/// syntax allows — a non-hex byte anywhere is simply not a colour.
pub fn parse_color(text: &str) -> Option<[u8; 3]> {
    let hex = text.strip_prefix('#')?.as_bytes();
    if hex.len() != 6 && hex.len() != 8 {
        return None;
    }
    let nibble = |b: u8| char::from(b).to_digit(16).map(|d| d as u8);
    let byte = |i: usize| Some((nibble(hex[i])? << 4) | nibble(hex[i + 1])?);
    Some([byte(0)?, byte(2)?, byte(4)?])
}

/// Lowercase `#rrggbb`.
pub fn color_hex(color: [u8; 3]) -> String {
    format!("#{:02x}{:02x}{:02x}", color[0], color[1], color[2])
}

pub(crate) fn enum_name<T: Copy + PartialEq>(
    table: &[(&'static str, T)],
    value: T,
) -> &'static str {
    table
        .iter()
        .find(|(_, v)| *v == value)
        .map(|(n, _)| *n)
        .unwrap_or("")
}
