//! The canonical writer for [`LayerStyle`] (`to_json`): every key of every
//! present effect, effects in render order, keys sorted (serde_json's `Map`
//! is BTreeMap-backed — do not enable `preserve_order`), colours as
//! lowercase `#rrggbb`, numbers re-quantized to four decimals and printed
//! as decimals (`5.0`, `0.3333`). What `rz_doc_layer_style` returns and
//! what the RZDC writer stores; the parser is `style_json`, the schema
//! table `style`'s module doc.

use serde_json::{Map, Value};

use crate::blend::BlendMode;
use crate::style::{Effect, GradientFill, LayerStyle};
use crate::style_names::{
    blend_mode_name, color_hex, enum_name, BEVEL_DIRECTIONS, BEVEL_STYLES, CHANNELS, GLOW_SOURCES,
    GRADIENT_STYLES, STROKE_FILLS, STROKE_POSITIONS,
};

impl LayerStyle {
    /// The canonical JSON: every key of every present effect, effects in
    /// render order, sorted keys, `#rrggbb` colours, numbers re-quantized
    /// (`5.0`, `0.3333`), `version` 1. What `rz_doc_layer_style` returns and
    /// what the RZDC writer stores.
    pub fn to_json(&self) -> String {
        let mut root = Map::new();
        root.insert("version".into(), Value::from(1));
        root.insert("fill_opacity".into(), number(self.fill_opacity));
        root.insert(
            "blend_if".into(),
            match &self.blend_if {
                None => Value::Null,
                Some(b) => {
                    let mut o = Map::new();
                    o.insert(
                        "channel".into(),
                        Value::from(enum_name(&CHANNELS, b.channel)),
                    );
                    o.insert("this_layer".into(), ramp_value(b.this_layer));
                    o.insert("underlying".into(), ramp_value(b.underlying));
                    Value::Object(o)
                }
            },
        );
        let mut effects: Vec<&Effect> = self.effects.iter().collect();
        effects.sort_by_key(|e| e.kind());
        root.insert(
            "effects".into(),
            Value::Array(effects.into_iter().map(effect_value).collect()),
        );
        Value::Object(root).to_string()
    }
}

/// The stored f32 re-quantized in f64 and printed as a decimal (`5.0`,
/// `0.3333`) — never the f32's own expansion (`0.33329999446868896`).
fn number(v: f32) -> Value {
    Value::from((f64::from(v) * 1e4).round() / 1e4)
}

fn ramp_value(r: [u8; 4]) -> Value {
    Value::Array(r.iter().map(|&v| Value::from(v)).collect())
}

fn gradient_value(g: &GradientFill) -> Value {
    let mut o = Map::new();
    o.insert(
        "stops".into(),
        Value::Array(
            g.stops
                .iter()
                .map(|s| {
                    let mut so = Map::new();
                    so.insert("position".into(), number(s.position));
                    so.insert("color".into(), Value::from(color_hex(s.color)));
                    so.insert("opacity".into(), number(s.opacity));
                    Value::Object(so)
                })
                .collect(),
        ),
    );
    o.insert(
        "style".into(),
        Value::from(enum_name(&GRADIENT_STYLES, g.style)),
    );
    o.insert("angle".into(), number(g.angle));
    o.insert("scale".into(), number(g.scale));
    o.insert("reverse".into(), Value::from(g.reverse));
    o.insert("align_with_layer".into(), Value::from(g.align_with_layer));
    Value::Object(o)
}

fn put_blend(o: &mut Map<String, Value>, key: &str, mode: BlendMode) {
    o.insert(key.into(), Value::from(blend_mode_name(mode)));
}

fn effect_value(e: &Effect) -> Value {
    let mut o = Map::new();
    o.insert("type".into(), Value::from(e.kind().type_name()));
    o.insert("enabled".into(), Value::from(e.enabled()));
    match e {
        Effect::DropShadow(d) => {
            put_blend(&mut o, "blend", d.blend);
            o.insert("color".into(), Value::from(color_hex(d.color)));
            o.insert("opacity".into(), number(d.opacity));
            o.insert("angle".into(), number(d.angle));
            o.insert("use_global_light".into(), Value::from(d.use_global_light));
            o.insert("distance".into(), number(d.distance));
            o.insert("spread".into(), number(d.spread));
            o.insert("size".into(), number(d.size));
            o.insert("layer_knocks_out".into(), Value::from(d.layer_knocks_out));
        }
        Effect::InnerShadow(s) => {
            put_blend(&mut o, "blend", s.blend);
            o.insert("color".into(), Value::from(color_hex(s.color)));
            o.insert("opacity".into(), number(s.opacity));
            o.insert("angle".into(), number(s.angle));
            o.insert("use_global_light".into(), Value::from(s.use_global_light));
            o.insert("distance".into(), number(s.distance));
            o.insert("choke".into(), number(s.choke));
            o.insert("size".into(), number(s.size));
        }
        Effect::OuterGlow(g) => {
            put_blend(&mut o, "blend", g.blend);
            o.insert("color".into(), Value::from(color_hex(g.color)));
            o.insert("opacity".into(), number(g.opacity));
            o.insert("spread".into(), number(g.spread));
            o.insert("size".into(), number(g.size));
        }
        Effect::InnerGlow(g) => {
            put_blend(&mut o, "blend", g.blend);
            o.insert("color".into(), Value::from(color_hex(g.color)));
            o.insert("opacity".into(), number(g.opacity));
            o.insert("choke".into(), number(g.choke));
            o.insert("size".into(), number(g.size));
            o.insert(
                "source".into(),
                Value::from(enum_name(&GLOW_SOURCES, g.source)),
            );
        }
        Effect::Stroke(s) => {
            put_blend(&mut o, "blend", s.blend);
            o.insert("opacity".into(), number(s.opacity));
            o.insert("size".into(), number(s.size));
            o.insert(
                "position".into(),
                Value::from(enum_name(&STROKE_POSITIONS, s.position)),
            );
            o.insert(
                "fill_type".into(),
                Value::from(enum_name(&STROKE_FILLS, s.fill_type)),
            );
            o.insert("color".into(), Value::from(color_hex(s.color)));
            o.insert("gradient".into(), gradient_value(&s.gradient));
        }
        Effect::ColorOverlay(c) => {
            put_blend(&mut o, "blend", c.blend);
            o.insert("color".into(), Value::from(color_hex(c.color)));
            o.insert("opacity".into(), number(c.opacity));
        }
        Effect::GradientOverlay(g) => {
            put_blend(&mut o, "blend", g.blend);
            o.insert("opacity".into(), number(g.opacity));
            o.insert("gradient".into(), gradient_value(&g.gradient));
        }
        Effect::BevelEmboss(b) => {
            o.insert(
                "style".into(),
                Value::from(enum_name(&BEVEL_STYLES, b.style)),
            );
            o.insert("depth".into(), number(b.depth));
            o.insert(
                "direction".into(),
                Value::from(enum_name(&BEVEL_DIRECTIONS, b.direction)),
            );
            o.insert("size".into(), number(b.size));
            o.insert("soften".into(), number(b.soften));
            o.insert("angle".into(), number(b.angle));
            o.insert("use_global_light".into(), Value::from(b.use_global_light));
            o.insert("altitude".into(), number(b.altitude));
            put_blend(&mut o, "highlight_blend", b.highlight_blend);
            o.insert(
                "highlight_color".into(),
                Value::from(color_hex(b.highlight_color)),
            );
            o.insert("highlight_opacity".into(), number(b.highlight_opacity));
            put_blend(&mut o, "shadow_blend", b.shadow_blend);
            o.insert(
                "shadow_color".into(),
                Value::from(color_hex(b.shadow_color)),
            );
            o.insert("shadow_opacity".into(), number(b.shadow_opacity));
        }
        Effect::Satin(s) => {
            put_blend(&mut o, "blend", s.blend);
            o.insert("color".into(), Value::from(color_hex(s.color)));
            o.insert("opacity".into(), number(s.opacity));
            o.insert("angle".into(), number(s.angle));
            o.insert("distance".into(), number(s.distance));
            o.insert("size".into(), number(s.size));
            o.insert("invert".into(), Value::from(s.invert));
        }
    }
    Value::Object(o)
}
