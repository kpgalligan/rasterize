//! What a new style inherits from the style it replaces: the rendered
//! planes of every effect whose PLANE parameters are unchanged, re-stamped
//! with the new colour, blend mode and opacity (and, for the drop shadow,
//! its composite-time shift and knock-out). `RzDocument::set_layer_style`
//! hands the old `Arc<LayerStyle>`'s cache to the new one through
//! `LayerStyle::inherit_planes` (`style_cache`), and on the first read of
//! each carried entry the new style re-renders only the effects
//! [`same_planes`] rejects — so a colour, opacity or blend-mode edit in
//! the Layer Style sheet, or an MCP `set_layer_style` that changes one
//! such knob, costs no blur at all; a geometry edit costs one render of
//! that effect, for the one entry a composite reads; and the undo
//! snapshot that keeps the old style keeps no planes.
//!
//! The two functions here are mirror images: [`plane_params`] neutralizes
//! exactly the fields [`restamp`] copies, so every field of an effect
//! belongs to one list or the other — and a field ADDED to an effect is a
//! plane parameter by default, where a mismatch costs a re-render, never a
//! plane rendered for the wrong style. Two effect-level facts are plane
//! parameters too: whether an opacity is above zero (an effect at opacity
//! 0 emits nothing, so its contributions do not exist to re-stamp), and
//! the light an effect actually resolves to (`use_global_light` is folded
//! into `angle`/`altitude` under the entry's own light, so switching a
//! shadow from its own angle to an equal global one keeps its planes).

use crate::blend::BlendMode;
use crate::style::{
    BevelEmboss, ColorOverlay, DropShadow, Effect, GlobalLight, GradientFill, GradientOverlay,
    InnerGlow, InnerShadow, OuterGlow, Satin, Stroke, StrokeFill,
};
use crate::style_render::{light_offset, unit_color, Contribution, Part, PlaneColor};

/// True when `next` renders the same coverage planes as `previous` did
/// under `light` (module doc): the two are equal once every stamp field is
/// neutralized. `previous` must be the effect whose contributions are
/// cached; the caller checks it was enabled.
pub(crate) fn same_planes(previous: &Effect, next: &Effect, light: GlobalLight) -> bool {
    plane_params(previous, light) == plane_params(next, light)
}

/// `effect` with every stamp field replaced by a fixed value: colours
/// black, blends Normal, opacities 1 (or 0 when they were 0), the light
/// resolved and `use_global_light` cleared, the drop shadow's shift inputs
/// and knock-out zeroed, gradient stop colours black. What remains is
/// exactly what the effect's planes are a function of.
fn plane_params(effect: &Effect, light: GlobalLight) -> Effect {
    const COLOR: [u8; 3] = [0, 0, 0];
    const BLEND: BlendMode = BlendMode::Normal;
    match effect {
        Effect::DropShadow(d) => Effect::DropShadow(DropShadow {
            enabled: true,
            blend: BLEND,
            color: COLOR,
            opacity: lit(d.opacity),
            angle: 0.0,
            use_global_light: false,
            distance: 0.0,
            layer_knocks_out: false,
            ..d.clone()
        }),
        Effect::InnerShadow(s) => Effect::InnerShadow(InnerShadow {
            enabled: true,
            blend: BLEND,
            color: COLOR,
            opacity: lit(s.opacity),
            angle: s.resolved_angle(light),
            use_global_light: false,
            ..s.clone()
        }),
        Effect::OuterGlow(g) => Effect::OuterGlow(OuterGlow {
            enabled: true,
            blend: BLEND,
            color: COLOR,
            opacity: lit(g.opacity),
            ..g.clone()
        }),
        Effect::InnerGlow(g) => Effect::InnerGlow(InnerGlow {
            enabled: true,
            blend: BLEND,
            color: COLOR,
            opacity: lit(g.opacity),
            ..g.clone()
        }),
        Effect::Stroke(s) => Effect::Stroke(Stroke {
            enabled: true,
            blend: BLEND,
            opacity: lit(s.opacity),
            color: COLOR,
            gradient: geometry_of(&s.gradient),
            ..s.clone()
        }),
        Effect::ColorOverlay(c) => Effect::ColorOverlay(ColorOverlay {
            enabled: true,
            blend: BLEND,
            color: COLOR,
            opacity: lit(c.opacity),
        }),
        Effect::GradientOverlay(g) => Effect::GradientOverlay(GradientOverlay {
            enabled: true,
            blend: BLEND,
            opacity: lit(g.opacity),
            gradient: geometry_of(&g.gradient),
        }),
        Effect::BevelEmboss(b) => Effect::BevelEmboss(BevelEmboss {
            enabled: true,
            angle: b.resolved_angle(light),
            use_global_light: false,
            altitude: b.resolved_altitude(light),
            highlight_blend: BLEND,
            highlight_color: COLOR,
            highlight_opacity: lit(b.highlight_opacity),
            shadow_blend: BLEND,
            shadow_color: COLOR,
            shadow_opacity: lit(b.shadow_opacity),
            ..b.clone()
        }),
        Effect::Satin(s) => Effect::Satin(Satin {
            enabled: true,
            blend: BLEND,
            color: COLOR,
            opacity: lit(s.opacity),
            ..s.clone()
        }),
    }
}

/// 1 for an opacity that renders, 0 for one that emits nothing — the only
/// plane-relevant fact about an opacity (NaN counts as nothing, as every
/// renderer treats it).
fn lit(opacity: f32) -> f32 {
    if opacity.is_finite() && opacity > 0.0 {
        1.0
    } else {
        0.0
    }
}

/// `fill` with its stop colours black: the stop positions and opacities,
/// the style, angle, scale, reverse and alignment all shape the plane (a
/// stop's opacity multiplies the coverage; the geometry places it), only
/// the colours are sampled at composite time.
fn geometry_of(fill: &GradientFill) -> GradientFill {
    let mut geometry = fill.clone();
    for stop in &mut geometry.stops {
        stop.color = [0, 0, 0];
    }
    geometry
}

/// `cached` — a contribution rendered for an effect [`same_planes`] as
/// `effect` — with `effect`'s stamps: colour (a gradient keeps its sampler
/// and takes the new stops), blend, opacity, and for the drop shadow the
/// shift under `light` and the knock-out flag. The plane bytes are shared
/// by clone; nothing is rendered.
pub(crate) fn restamp(cached: &Contribution, effect: &Effect, light: GlobalLight) -> Contribution {
    let mut c = cached.clone();
    match effect {
        Effect::DropShadow(d) => {
            c.color = PlaneColor::Solid(unit_color(d.color));
            c.blend = d.blend;
            c.opacity = d.opacity;
            c.shift = light_offset(d.resolved_angle(light), d.distance);
            c.knocked_out_by_shape = d.layer_knocks_out;
        }
        Effect::InnerShadow(s) => solid(&mut c, s.color, s.blend, s.opacity),
        Effect::OuterGlow(g) => solid(&mut c, g.color, g.blend, g.opacity),
        Effect::InnerGlow(g) => solid(&mut c, g.color, g.blend, g.opacity),
        Effect::Stroke(s) => {
            c.blend = s.blend;
            c.opacity = s.opacity;
            c.color = match s.fill_type {
                StrokeFill::Color => PlaneColor::Solid(unit_color(s.color)),
                StrokeFill::Gradient => regraded(&c.color, &s.gradient),
            };
        }
        Effect::ColorOverlay(o) => solid(&mut c, o.color, o.blend, o.opacity),
        Effect::GradientOverlay(g) => {
            c.blend = g.blend;
            c.opacity = g.opacity;
            c.color = regraded(&c.color, &g.gradient);
        }
        Effect::BevelEmboss(b) => match c.part {
            Part::Highlight => solid(
                &mut c,
                b.highlight_color,
                b.highlight_blend,
                b.highlight_opacity,
            ),
            Part::Shadow => solid(&mut c, b.shadow_color, b.shadow_blend, b.shadow_opacity),
            Part::Main => {}
        },
        Effect::Satin(s) => solid(&mut c, s.color, s.blend, s.opacity),
    }
    c
}

fn solid(c: &mut Contribution, color: [u8; 3], blend: BlendMode, opacity: f32) {
    c.color = PlaneColor::Solid(unit_color(color));
    c.blend = blend;
    c.opacity = opacity;
}

/// A gradient colour with `fill`'s stops (same geometry, so the sampler's
/// precomputed box trigonometry stays valid); a solid colour unchanged.
fn regraded(color: &PlaneColor, fill: &GradientFill) -> PlaneColor {
    match color {
        PlaneColor::Gradient(sampler) => {
            let mut sampler = sampler.clone();
            sampler.fill = fill.clone();
            PlaneColor::Gradient(sampler)
        }
        PlaneColor::Solid(rgb) => PlaneColor::Solid(*rgb),
    }
}
