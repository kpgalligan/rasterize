//! The JSON parser for [`LayerStyle`]: ONE parser (`Strict` for the FFI
//! setter, `Lenient` for the RZDC reader — see `style`'s module doc, which
//! is the schema table), the clamp table it shares with `LayerStyle::scaled`,
//! and the four-decimal quantization applied at parse time so the stored
//! value IS its canonical form and a `to_json` echo (`style_json_write`)
//! re-parses to an equal style. The name tables are `style_names`.

use serde_json::{Map, Value};

use crate::blend::BlendMode;
use crate::style::{
    BevelEmboss, BlendIf, BlendIfChannel, ColorOverlay, DropShadow, Effect, EffectKind,
    GradientFill, GradientOverlay, GradientStop, InnerGlow, InnerShadow, LayerStyle, OuterGlow,
    Satin, Strictness, Stroke,
};
use crate::style_names::{
    parse_color, BEVEL_DIRECTIONS, BEVEL_STYLES, BLEND_NAMES, CHANNELS, GLOW_SOURCES,
    GRADIENT_STYLES, STROKE_FILLS, STROKE_POSITIONS,
};

/// Quantizes to four decimals (in f64, so the rounding is exact for every
/// value the schema allows) and narrows to the f32 the model stores. Four
/// decimals is finer than any dialog shows and coarse enough that the
/// decimal string serde_json prints re-parses to the same f32.
pub(crate) fn q4(v: f64) -> f32 {
    ((v * 1e4).round() / 1e4) as f32
}

/// An inclusive clamp range for one numeric key; [`Range::apply`] is the
/// parser's and `LayerStyle::scaled`'s shared "clamp then quantize".
#[derive(Clone, Copy, Debug)]
pub(crate) struct Range {
    pub lo: f32,
    pub hi: f32,
}

impl Range {
    pub(crate) fn apply(self, v: f64) -> f32 {
        let v = if v.is_finite() { v } else { f64::from(self.lo) };
        q4(v.clamp(f64::from(self.lo), f64::from(self.hi)))
    }
}

/// The one clamp table, keyed by what a number means. Bounds are
/// Photoshop's dialog limits: size 250 px (also what bounds every blur
/// kernel), distance 30000 px, soften 16 px, depth 1..1000 %, altitude
/// 0..90°, gradient scale 10..150 %.
pub(crate) struct Ranges {
    /// Opacities, spread/choke fractions, gradient stop positions.
    pub unit: Range,
    pub distance: Range,
    pub size: Range,
    pub soften: Range,
    pub depth: Range,
    pub altitude: Range,
    pub gradient_scale: Range,
}

pub(crate) const RANGES: Ranges = Ranges {
    unit: Range { lo: 0.0, hi: 1.0 },
    distance: Range {
        lo: 0.0,
        hi: 30000.0,
    },
    size: Range { lo: 0.0, hi: 250.0 },
    soften: Range { lo: 0.0, hi: 16.0 },
    depth: Range { lo: 0.01, hi: 10.0 },
    altitude: Range { lo: 0.0, hi: 90.0 },
    gradient_scale: Range { lo: 0.1, hi: 1.5 },
};

// ------------------------------------------------------------- parsing --

/// `key` as reported in errors: `fill_opacity` at the root,
/// `effects[1].size` inside an effect.
fn at(path: &str, key: &str) -> String {
    if path.is_empty() {
        key.to_string()
    } else {
        format!("{path}.{key}")
    }
}

/// `obj[key]` as a finite number clamped into `range` and quantized;
/// `default` when absent. Present but not a number (JSON cannot encode NaN
/// or infinities, so "number" means finite) is malformed.
fn num(
    obj: &Map<String, Value>,
    path: &str,
    key: &str,
    default: f32,
    range: Range,
) -> Result<f32, String> {
    match obj.get(key) {
        None => Ok(range.apply(f64::from(default))),
        Some(v) => v
            .as_f64()
            .filter(|f| f.is_finite())
            .map(|f| range.apply(f))
            .ok_or_else(|| format!("{} must be a number", at(path, key))),
    }
}

/// `obj[key]` as an angle in degrees: any finite number, normalized into
/// [-180, 180) and quantized.
fn angle(obj: &Map<String, Value>, path: &str, key: &str, default: f32) -> Result<f32, String> {
    let raw = match obj.get(key) {
        None => f64::from(default),
        Some(v) => v
            .as_f64()
            .filter(|f| f.is_finite())
            .ok_or_else(|| format!("{} must be a number", at(path, key)))?,
    };
    Ok(canonical_angle(raw))
}

/// Normalize into [-180, 180), quantize, and keep the quantized value in
/// range (179.99996 would round up to 180). The normalization runs in f64
/// BEFORE the narrowing to f32: JSON allows any finite double, and an
/// angle beyond the f32 range (1e39) narrowed first would become infinite,
/// its remainder NaN — a value the writer prints as `null`, the reader then
/// refuses, and `PartialEq` never matches (phantom undo steps). Every
/// finite double has a finite remainder, so the stored angle is always a
/// finite f32 in range.
pub(crate) fn canonical_angle(deg: f64) -> f32 {
    let normalized = (deg + 180.0).rem_euclid(360.0) - 180.0;
    let normalized = if normalized.is_finite() && normalized < 180.0 {
        normalized
    } else {
        -180.0
    };
    let q = q4(normalized);
    if q >= 180.0 {
        -180.0
    } else {
        q
    }
}

fn boolean(obj: &Map<String, Value>, path: &str, key: &str, default: bool) -> Result<bool, String> {
    match obj.get(key) {
        None => Ok(default),
        Some(v) => v
            .as_bool()
            .ok_or_else(|| format!("{} must be a boolean", at(path, key))),
    }
}

/// `obj[key]` as one of `table`'s names. Unknown: malformed in strict mode,
/// `default` in lenient mode. A non-string is malformed in both.
fn string_enum<T: Copy>(
    obj: &Map<String, Value>,
    path: &str,
    key: &str,
    default: T,
    table: &[(&str, T)],
    strictness: Strictness,
) -> Result<T, String> {
    let Some(v) = obj.get(key) else {
        return Ok(default);
    };
    let name = v
        .as_str()
        .ok_or_else(|| format!("{} must be a string", at(path, key)))?;
    match table.iter().find(|(n, _)| *n == name) {
        Some((_, value)) => Ok(*value),
        None => match strictness {
            Strictness::Strict => {
                let names: Vec<&str> = table.iter().map(|(n, _)| *n).collect();
                Err(format!(
                    "{} must be one of {}",
                    at(path, key),
                    names.join(", ")
                ))
            }
            Strictness::Lenient => Ok(default),
        },
    }
}

fn color(
    obj: &Map<String, Value>,
    path: &str,
    key: &str,
    default: [u8; 3],
) -> Result<[u8; 3], String> {
    match obj.get(key) {
        None => Ok(default),
        Some(v) => v
            .as_str()
            .and_then(parse_color)
            .ok_or_else(|| format!("{} must be a #rrggbb color", at(path, key))),
    }
}

fn blend(
    obj: &Map<String, Value>,
    path: &str,
    key: &str,
    default: BlendMode,
    strictness: Strictness,
) -> Result<BlendMode, String> {
    string_enum(obj, path, key, default, &BLEND_NAMES, strictness)
}

fn object<'a>(value: &'a Value, path: &str) -> Result<&'a Map<String, Value>, String> {
    value
        .as_object()
        .ok_or_else(|| format!("{path} must be an object"))
}

fn gradient(
    obj: &Map<String, Value>,
    path: &str,
    key: &str,
    strictness: Strictness,
) -> Result<GradientFill, String> {
    let default = GradientFill::default();
    let Some(v) = obj.get(key) else {
        return Ok(default);
    };
    let gpath = at(path, key);
    let g = object(v, &gpath)?;
    let stops = match g.get("stops") {
        None => default.stops.clone(),
        Some(list) => {
            let spath = at(&gpath, "stops");
            let list = list
                .as_array()
                .ok_or_else(|| format!("{spath} must be an array"))?;
            if !(2..=32).contains(&list.len()) {
                return Err(format!("{spath} must have 2 to 32 entries"));
            }
            let mut stops = Vec::with_capacity(list.len());
            for (i, entry) in list.iter().enumerate() {
                let epath = format!("{spath}[{i}]");
                let e = object(entry, &epath)?;
                stops.push(GradientStop {
                    position: num(e, &epath, "position", 0.0, RANGES.unit)?,
                    color: color(e, &epath, "color", [0, 0, 0])?,
                    opacity: num(e, &epath, "opacity", 1.0, RANGES.unit)?,
                });
            }
            stops.sort_by(|a, b| a.position.total_cmp(&b.position));
            stops
        }
    };
    Ok(GradientFill {
        stops,
        style: string_enum(
            g,
            &gpath,
            "style",
            default.style,
            &GRADIENT_STYLES,
            strictness,
        )?,
        angle: angle(g, &gpath, "angle", default.angle)?,
        scale: num(g, &gpath, "scale", default.scale, RANGES.gradient_scale)?,
        reverse: boolean(g, &gpath, "reverse", default.reverse)?,
        align_with_layer: boolean(g, &gpath, "align_with_layer", default.align_with_layer)?,
    })
}

/// One Blend If ramp: exactly four integers in 0..=255 (a float with a zero
/// fraction is accepted; out-of-range values clamp) in non-decreasing order.
fn ramp(obj: &Map<String, Value>, path: &str, key: &str) -> Result<[u8; 4], String> {
    let Some(v) = obj.get(key) else {
        return Ok(crate::style::FULL_RAMP);
    };
    let rpath = at(path, key);
    let list = v
        .as_array()
        .filter(|l| l.len() == 4)
        .ok_or_else(|| format!("{rpath} must be an array of 4 integers"))?;
    let mut out = [0u8; 4];
    for (slot, entry) in out.iter_mut().zip(list) {
        let f = entry
            .as_f64()
            .filter(|f| f.is_finite() && f.fract() == 0.0)
            .ok_or_else(|| format!("{rpath} must be an array of 4 integers"))?;
        *slot = f.clamp(0.0, 255.0) as u8;
    }
    if !(out[0] <= out[1] && out[1] <= out[2] && out[2] <= out[3]) {
        return Err(format!("{rpath} must be in non-decreasing order"));
    }
    Ok(out)
}

fn parse_blend_if(value: &Value, strictness: Strictness) -> Result<Option<BlendIf>, String> {
    if value.is_null() {
        return Ok(None);
    }
    let b = value
        .as_object()
        .ok_or_else(|| "blend_if must be an object or null".to_string())?;
    Ok(Some(BlendIf {
        channel: string_enum(
            b,
            "blend_if",
            "channel",
            BlendIfChannel::Gray,
            &CHANNELS,
            strictness,
        )?,
        this_layer: ramp(b, "blend_if", "this_layer")?,
        underlying: ramp(b, "blend_if", "underlying")?,
    }))
}

/// One effect object. `Ok(None)` means "skipped" (an unknown `type` in
/// lenient mode); a structural problem is `Err` in both modes.
fn effect(value: &Value, path: &str, strictness: Strictness) -> Result<Option<Effect>, String> {
    let o = object(value, path)?;
    let type_key = at(path, "type");
    let type_name = o
        .get("type")
        .and_then(Value::as_str)
        .ok_or_else(|| format!("{type_key} must be a string"))?;
    let Some(kind) = EffectKind::from_type_name(type_name) else {
        return match strictness {
            Strictness::Strict => Err(format!(
                "{type_key} must be one of {}",
                EffectKind::ALL
                    .iter()
                    .map(|k| k.type_name())
                    .collect::<Vec<_>>()
                    .join(", ")
            )),
            Strictness::Lenient => Ok(None),
        };
    };
    let enabled = boolean(o, path, "enabled", true)?;
    let unit = RANGES.unit;
    let parsed = match kind {
        EffectKind::DropShadow => {
            let d = DropShadow::default();
            Effect::DropShadow(DropShadow {
                enabled,
                blend: blend(o, path, "blend", d.blend, strictness)?,
                color: color(o, path, "color", d.color)?,
                opacity: num(o, path, "opacity", d.opacity, unit)?,
                angle: angle(o, path, "angle", d.angle)?,
                use_global_light: boolean(o, path, "use_global_light", d.use_global_light)?,
                distance: num(o, path, "distance", d.distance, RANGES.distance)?,
                spread: num(o, path, "spread", d.spread, unit)?,
                size: num(o, path, "size", d.size, RANGES.size)?,
                layer_knocks_out: boolean(o, path, "layer_knocks_out", d.layer_knocks_out)?,
            })
        }
        EffectKind::InnerShadow => {
            let d = InnerShadow::default();
            Effect::InnerShadow(InnerShadow {
                enabled,
                blend: blend(o, path, "blend", d.blend, strictness)?,
                color: color(o, path, "color", d.color)?,
                opacity: num(o, path, "opacity", d.opacity, unit)?,
                angle: angle(o, path, "angle", d.angle)?,
                use_global_light: boolean(o, path, "use_global_light", d.use_global_light)?,
                distance: num(o, path, "distance", d.distance, RANGES.distance)?,
                choke: num(o, path, "choke", d.choke, unit)?,
                size: num(o, path, "size", d.size, RANGES.size)?,
            })
        }
        EffectKind::OuterGlow => {
            let d = OuterGlow::default();
            Effect::OuterGlow(OuterGlow {
                enabled,
                blend: blend(o, path, "blend", d.blend, strictness)?,
                color: color(o, path, "color", d.color)?,
                opacity: num(o, path, "opacity", d.opacity, unit)?,
                spread: num(o, path, "spread", d.spread, unit)?,
                size: num(o, path, "size", d.size, RANGES.size)?,
            })
        }
        EffectKind::InnerGlow => {
            let d = InnerGlow::default();
            Effect::InnerGlow(InnerGlow {
                enabled,
                blend: blend(o, path, "blend", d.blend, strictness)?,
                color: color(o, path, "color", d.color)?,
                opacity: num(o, path, "opacity", d.opacity, unit)?,
                choke: num(o, path, "choke", d.choke, unit)?,
                size: num(o, path, "size", d.size, RANGES.size)?,
                source: string_enum(o, path, "source", d.source, &GLOW_SOURCES, strictness)?,
            })
        }
        EffectKind::Stroke => {
            let d = Stroke::default();
            Effect::Stroke(Stroke {
                enabled,
                blend: blend(o, path, "blend", d.blend, strictness)?,
                opacity: num(o, path, "opacity", d.opacity, unit)?,
                size: num(o, path, "size", d.size, RANGES.size)?,
                position: string_enum(
                    o,
                    path,
                    "position",
                    d.position,
                    &STROKE_POSITIONS,
                    strictness,
                )?,
                fill_type: string_enum(
                    o,
                    path,
                    "fill_type",
                    d.fill_type,
                    &STROKE_FILLS,
                    strictness,
                )?,
                color: color(o, path, "color", d.color)?,
                gradient: gradient(o, path, "gradient", strictness)?,
            })
        }
        EffectKind::ColorOverlay => {
            let d = ColorOverlay::default();
            Effect::ColorOverlay(ColorOverlay {
                enabled,
                blend: blend(o, path, "blend", d.blend, strictness)?,
                color: color(o, path, "color", d.color)?,
                opacity: num(o, path, "opacity", d.opacity, unit)?,
            })
        }
        EffectKind::GradientOverlay => {
            let d = GradientOverlay::default();
            Effect::GradientOverlay(GradientOverlay {
                enabled,
                blend: blend(o, path, "blend", d.blend, strictness)?,
                opacity: num(o, path, "opacity", d.opacity, unit)?,
                gradient: gradient(o, path, "gradient", strictness)?,
            })
        }
        EffectKind::BevelEmboss => {
            let d = BevelEmboss::default();
            Effect::BevelEmboss(BevelEmboss {
                enabled,
                style: string_enum(o, path, "style", d.style, &BEVEL_STYLES, strictness)?,
                depth: num(o, path, "depth", d.depth, RANGES.depth)?,
                direction: string_enum(
                    o,
                    path,
                    "direction",
                    d.direction,
                    &BEVEL_DIRECTIONS,
                    strictness,
                )?,
                size: num(o, path, "size", d.size, RANGES.size)?,
                soften: num(o, path, "soften", d.soften, RANGES.soften)?,
                angle: angle(o, path, "angle", d.angle)?,
                use_global_light: boolean(o, path, "use_global_light", d.use_global_light)?,
                altitude: num(o, path, "altitude", d.altitude, RANGES.altitude)?,
                highlight_blend: blend(o, path, "highlight_blend", d.highlight_blend, strictness)?,
                highlight_color: color(o, path, "highlight_color", d.highlight_color)?,
                highlight_opacity: num(o, path, "highlight_opacity", d.highlight_opacity, unit)?,
                shadow_blend: blend(o, path, "shadow_blend", d.shadow_blend, strictness)?,
                shadow_color: color(o, path, "shadow_color", d.shadow_color)?,
                shadow_opacity: num(o, path, "shadow_opacity", d.shadow_opacity, unit)?,
            })
        }
        EffectKind::Satin => {
            let d = Satin::default();
            Effect::Satin(Satin {
                enabled,
                blend: blend(o, path, "blend", d.blend, strictness)?,
                color: color(o, path, "color", d.color)?,
                opacity: num(o, path, "opacity", d.opacity, unit)?,
                angle: angle(o, path, "angle", d.angle)?,
                distance: num(o, path, "distance", d.distance, RANGES.distance)?,
                size: num(o, path, "size", d.size, RANGES.size)?,
                invert: boolean(o, path, "invert", d.invert)?,
            })
        }
    };
    Ok(Some(parsed))
}

impl LayerStyle {
    /// Parses the style JSON in STRICT mode (the FFI setter's rules — see
    /// `style`'s module doc). The message of an `Err` names the offending
    /// key (`effects[1].size must be a number`) or says `not valid JSON`.
    pub fn from_json(json: &str) -> Result<LayerStyle, String> {
        let value: Value =
            serde_json::from_str(json).map_err(|e| format!("not valid JSON: {e}"))?;
        LayerStyle::from_value(&value, Strictness::Strict)
    }

    /// Parses in LENIENT mode (the RZDC reader's rules): an unknown effect
    /// `type` is skipped, a duplicate keeps the first, an unknown enum
    /// string takes the default; structure, types, finiteness and ramp
    /// order stay strict.
    pub fn from_json_lenient(json: &str) -> Result<LayerStyle, String> {
        let value: Value =
            serde_json::from_str(json).map_err(|e| format!("not valid JSON: {e}"))?;
        LayerStyle::from_value(&value, Strictness::Lenient)
    }

    /// The one parser behind both `from_json` variants, over an
    /// already-decoded value (so the FFI can word a syntax error and a
    /// schema error differently).
    pub(crate) fn from_value(value: &Value, strictness: Strictness) -> Result<LayerStyle, String> {
        let root = value
            .as_object()
            .ok_or_else(|| "style must be a JSON object".to_string())?;
        let fill_opacity = num(root, "", "fill_opacity", 1.0, RANGES.unit)?;
        let blend_if = match root.get("blend_if") {
            None => None,
            Some(v) => parse_blend_if(v, strictness)?,
        };
        let mut effects: Vec<Effect> = Vec::new();
        if let Some(list) = root.get("effects") {
            let list = list
                .as_array()
                .ok_or_else(|| "effects must be an array".to_string())?;
            for (i, entry) in list.iter().enumerate() {
                let path = format!("effects[{i}]");
                let Some(parsed) = effect(entry, &path, strictness)? else {
                    continue;
                };
                if effects.iter().any(|e| e.kind() == parsed.kind()) {
                    match strictness {
                        Strictness::Strict => {
                            return Err(format!(
                                "{} duplicates an earlier effect",
                                at(&path, "type")
                            ))
                        }
                        Strictness::Lenient => continue,
                    }
                }
                effects.push(parsed);
            }
        }
        effects.sort_by_key(Effect::kind);
        Ok(LayerStyle {
            fill_opacity,
            blend_if,
            effects,
            cache: Default::default(),
        })
    }
}
