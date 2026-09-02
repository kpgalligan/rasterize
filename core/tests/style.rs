//! Layer styles — model and compositing: the JSON codec's contract, the
//! identity rule, padding, Scale Effects, the fill-opacity and drop-shadow
//! oracles (the W3C reference blend over hand-built planes: a hard shadow
//! is the rect translated, a soft one the header's feather kernel, a spread
//! one the grow-rect closed form), the global light, clip groups, Merge
//! Down and Flatten, and the downsampled blur path. Everything black-box
//! through the public API and the FFI; shared fixtures live in
//! `tests/common`. Format and FFI-guard coverage is in `style_format.rs`;
//! the rendered-plane cache (Duplicate Layer, brush ticks, the hand-over
//! between style versions, the cost budget) in `style_cache.rs`.

use std::sync::Arc;

use image::RgbaImage;
use rasterize_core::doc::{BlendMode, MaskKind, RzDocument};
use rasterize_core::ffi_doc::*;
use rasterize_core::ffi_style::*;
use rasterize_core::style::*;
use tempfile::TempDir;

mod common;
use common::*;

// ---------------------------------------------------------------- helpers --

/// The canonical drop-shadow JSON for the oracles: a hard (size 0, spread
/// 0) black shadow at `angle`/`distance` with its own light.
fn hard_shadow(angle: f32, distance: f32) -> String {
    format!(
        "{{\"effects\":[{{\"type\":\"drop_shadow\",\"use_global_light\":false,\
         \"angle\":{angle},\"distance\":{distance},\"size\":0,\"spread\":0}}]}}"
    )
}

fn drop_shadow(style: &LayerStyle) -> &DropShadow {
    match style.effect(EffectKind::DropShadow) {
        Some(Effect::DropShadow(d)) => d,
        other => panic!("no drop shadow: {other:?}"),
    }
}

fn px(flat: &RgbaImage, x: u32, y: u32) -> [u8; 4] {
    flat.get_pixel(x, y).0
}

fn quantized(v: [f32; 4]) -> [u8; 4] {
    [
        (v[0] * 255.0).round() as u8,
        (v[1] * 255.0).round() as u8,
        (v[2] * 255.0).round() as u8,
        (v[3] * 255.0).round() as u8,
    ]
}

fn assert_px_close(got: [u8; 4], want: [u8; 4], what: &str) {
    assert_close(&got, &want, what);
}

/// The rect `(x, y, w, h)` shifted by `(dx, dy)` contains `(px, py)`.
fn in_rect(rect: (i32, i32, u32, u32), shift: (i32, i32), px: i64, py: i64) -> bool {
    let x0 = i64::from(rect.0) + i64::from(shift.0);
    let y0 = i64::from(rect.1) + i64::from(shift.1);
    px >= x0 && py >= y0 && px < x0 + i64::from(rect.2) && py < y0 + i64::from(rect.3)
}

/// The white-canvas / red-rect fixture every drop-shadow oracle uses: a
/// 40x32 canvas with a 6x4 rect at (12, 12), far enough from every edge
/// that no blur or growth reaches the border.
const CANVAS: (u32, u32) = (40, 32);
const RECT: (i32, i32, u32, u32) = (12, 12, 6, 4);

fn rect_doc() -> RzDocument {
    rect_layer_doc(CANVAS, RECT, RED)
}

// -------------------------------------------------------------- the model --

#[test]
fn defaults_round_trip_and_every_type_parses_from_its_type_alone() {
    let d = LayerStyle::default();
    assert!(d.is_identity());
    assert_eq!(parse(&d.to_json()), d, "the default round-trips");
    for kind in EffectKind::ALL {
        let json = format!("{{\"effects\":[{{\"type\":\"{}\"}}]}}", kind.type_name());
        let s = parse(&json);
        assert_eq!(s.effects, vec![Effect::default_for(kind)], "{kind:?}");
        assert!(!s.is_identity(), "{kind:?} is enabled by default");
        let echo = s.to_json();
        assert_eq!(
            parse(&echo),
            s,
            "{kind:?}: the canonical echo re-parses equal"
        );
        assert_eq!(
            parse(&echo).to_json(),
            echo,
            "{kind:?}: canonical form is a fixed point"
        );
        assert_eq!(EffectKind::from_type_name(kind.type_name()), Some(kind));
    }
    assert_eq!(EffectKind::from_type_name("glow"), None);
}

#[test]
fn canonical_output_is_sorted_render_ordered_and_lowercase() {
    let s = parse(
        "{\"fill_opacity\":1,\"effects\":[{\"type\":\"satin\"},\
         {\"type\":\"drop_shadow\",\"color\":\"#AABBCC\"}]}",
    );
    let json = s.to_json();
    let satin = json.find("\"type\":\"satin\"").expect("satin present");
    let shadow = json
        .find("\"type\":\"drop_shadow\"")
        .expect("shadow present");
    assert!(shadow < satin, "effects come out in render order: {json}");
    assert!(
        json.contains("\"color\":\"#aabbcc\""),
        "lowercase colour: {json}"
    );
    assert!(
        json.starts_with("{\"blend_if\":null,\"effects\":["),
        "sorted keys: {json}"
    );
    assert!(
        json.ends_with("\"fill_opacity\":1.0,\"version\":1}"),
        "{json}"
    );

    // The exact canonical form of a default drop shadow — the contract the
    // hosts round-trip; every key present, numbers printed as decimals.
    let shadow = parse("{\"effects\":[{\"type\":\"drop_shadow\"}]}").to_json();
    assert_eq!(
        shadow,
        "{\"blend_if\":null,\"effects\":[{\"angle\":120.0,\"blend\":\"multiply\",\
         \"color\":\"#000000\",\"distance\":5.0,\"enabled\":true,\"layer_knocks_out\":true,\
         \"opacity\":0.75,\"size\":5.0,\"spread\":0.0,\"type\":\"drop_shadow\",\
         \"use_global_light\":true}],\"fill_opacity\":1.0,\"version\":1}"
    );
    // The blend-name table covers all 27 modes both ways.
    let mut seen = 0;
    for raw in 0..27 {
        let mode = BlendMode::from_c(raw).unwrap();
        let name = blend_mode_name(mode);
        assert!(!name.is_empty(), "{mode:?} has a name");
        assert_eq!(blend_mode_from_name(name), Some(mode));
        seen += 1;
    }
    assert_eq!(seen, 27);
    assert_eq!(
        blend_mode_from_name("linear_dodge"),
        Some(BlendMode::Addition)
    );
    assert_eq!(parse_color("#FF8800"), Some([255, 136, 0]));
    assert_eq!(parse_color("#ff880080"), Some([255, 136, 0]));
    assert_eq!(parse_color("ff8800"), None);
    assert_eq!(color_hex([255, 136, 0]), "#ff8800");
}

#[test]
fn unknown_keys_are_ignored_and_ranges_clamp() {
    let s = parse(
        "{\"foo\":1,\"fill_opacity\":2,\"effects\":[{\"type\":\"drop_shadow\",\"bar\":\"x\",\
         \"size\":999,\"opacity\":-1,\"angle\":540,\"distance\":-5,\"spread\":7}]}",
    );
    assert_eq!(s.fill_opacity, 1.0);
    let d = drop_shadow(&s);
    assert_eq!(d.size, 250.0, "size clamps to 250");
    assert_eq!(d.opacity, 0.0);
    assert_eq!(d.angle, -180.0, "540 normalizes to -180");
    assert_eq!(d.distance, 0.0);
    assert_eq!(d.spread, 1.0);
    for (input, want) in [
        (180.0, -180.0),
        (-180.0, -180.0),
        (190.0, -170.0),
        (-190.0, 170.0),
    ] {
        let s = parse(&format!(
            "{{\"effects\":[{{\"type\":\"satin\",\"angle\":{input}}}]}}"
        ));
        match s.effect(EffectKind::Satin) {
            Some(Effect::Satin(satin)) => assert_eq!(satin.angle, want, "angle {input}"),
            other => panic!("{other:?}"),
        }
    }
    // A number where an integer is expected is fine when integral.
    let s = parse("{\"blend_if\":{\"this_layer\":[0,10.0,200,255]}}");
    assert_eq!(s.blend_if.unwrap().this_layer, [0, 10, 200, 255]);
    // Blend If ramp values clamp too.
    let s = parse("{\"blend_if\":{\"underlying\":[0,0,300,300]}}");
    assert_eq!(s.blend_if.unwrap().underlying, [0, 0, 255, 255]);
}

#[test]
fn numbers_quantize_to_four_decimals_and_the_echo_round_trips() {
    let s =
        parse("{\"effects\":[{\"type\":\"drop_shadow\",\"opacity\":0.33333,\"size\":2.00004}]}");
    let d = drop_shadow(&s);
    assert_eq!(d.opacity, 0.3333);
    assert_eq!(d.size, 2.0);
    let echo = s.to_json();
    assert!(echo.contains("\"opacity\":0.3333"), "{echo}");
    assert!(echo.contains("\"size\":2.0"), "{echo}");
    assert_eq!(
        parse(&echo),
        s,
        "re-parsing the echo equals the stored style"
    );
    // The stored value IS its canonical form: setting the echo on a layer
    // that already carries the style is a refusal, not a change.
    let doc = styled(&rect_doc(), 1, &echo);
    assert!(matches!(try_styled(&doc, 1, Some(&echo)), Ok(None)));
    assert!(
        matches!(
            try_styled(
                &doc,
                1,
                Some("{\"effects\":[{\"type\":\"drop_shadow\",\"opacity\":0.33333,\"size\":2.00004}]}")
            ),
            Ok(None)
        ),
        "the un-canonical original quantizes to the same style"
    );
}

#[test]
fn malformed_styles_are_refused_naming_the_key() {
    let cases: [(&str, &str); 22] = [
        ("not json at all", "JSON"),
        ("[1,2]", "object"),
        ("{\"fill_opacity\":\"x\"}", "fill_opacity"),
        ("{\"effects\":{}}", "effects"),
        ("{\"effects\":[5]}", "effects[0]"),
        ("{\"effects\":[{\"size\":3}]}", "effects[0].type"),
        ("{\"effects\":[{\"type\":\"glow\"}]}", "effects[0].type"),
        (
            "{\"effects\":[{\"type\":\"satin\"},{\"type\":\"satin\"}]}",
            "effects[1].type",
        ),
        (
            "{\"effects\":[{\"type\":\"satin\",\"blend\":\"plus\"}]}",
            "effects[0].blend",
        ),
        (
            "{\"effects\":[{\"type\":\"satin\",\"color\":\"red\"}]}",
            "effects[0].color",
        ),
        // Multi-byte characters straddling a hex pair (six and eight bytes
        // after the `#`, so they pass the length check) and a sign
        // `from_str_radix` would take: refused, never a panic.
        (
            "{\"effects\":[{\"type\":\"satin\",\"color\":\"#aé123\"}]}",
            "effects[0].color",
        ),
        (
            "{\"effects\":[{\"type\":\"drop_shadow\",\"color\":\"#0é000ff\"}]}",
            "effects[0].color",
        ),
        (
            "{\"effects\":[{\"type\":\"satin\",\"color\":\"#+1+2+3\"}]}",
            "effects[0].color",
        ),
        (
            "{\"effects\":[{\"type\":\"drop_shadow\",\"size\":\"big\"}]}",
            "effects[0].size",
        ),
        (
            "{\"effects\":[{\"type\":\"drop_shadow\",\"enabled\":1}]}",
            "effects[0].enabled",
        ),
        (
            "{\"effects\":[{\"type\":\"stroke\",\"position\":\"middle\"}]}",
            "effects[0].position",
        ),
        (
            "{\"effects\":[{\"type\":\"stroke\",\"gradient\":{\"stops\":[{\"position\":0}]}}]}",
            "effects[0].gradient.stops",
        ),
        ("{\"blend_if\":5}", "blend_if"),
        ("{\"blend_if\":{\"channel\":\"alpha\"}}", "blend_if.channel"),
        (
            "{\"blend_if\":{\"this_layer\":[10,5,255,255]}}",
            "blend_if.this_layer",
        ),
        (
            "{\"blend_if\":{\"this_layer\":[0,0,255]}}",
            "blend_if.this_layer",
        ),
        (
            "{\"blend_if\":{\"underlying\":[0,0.5,255,255]}}",
            "blend_if.underlying",
        ),
    ];
    for (json, key) in cases {
        let err = LayerStyle::from_json(json)
            .err()
            .unwrap_or_else(|| panic!("{json} must be refused"));
        assert!(err.contains(key), "{json}: message {err:?} must name {key}");
    }
}

#[test]
fn lenient_parse_skips_unknown_effects_and_defaults_unknown_enum_values() {
    let s = LayerStyle::from_json_lenient(
        "{\"effects\":[{\"type\":\"pattern_overlay\"},{\"type\":\"drop_shadow\"},\
         {\"type\":\"drop_shadow\",\"size\":9}]}",
    )
    .expect("lenient parse");
    assert_eq!(s.effects, vec![Effect::default_for(EffectKind::DropShadow)]);
    let s = LayerStyle::from_json_lenient(
        "{\"effects\":[{\"type\":\"stroke\",\"position\":\"middle\"}]}",
    )
    .expect("lenient parse");
    match s.effect(EffectKind::Stroke) {
        Some(Effect::Stroke(stroke)) => assert_eq!(stroke.position, StrokePosition::Outside),
        other => panic!("{other:?}"),
    }
    assert!(LayerStyle::from_json_lenient("{\"fill_opacity\":\"x\"}").is_err());
    assert!(
        LayerStyle::from_json_lenient("{\"effects\":[{\"type\":\"satin\",\"color\":\"#aé123\"}]}")
            .is_err(),
        "a colour stays strict in lenient mode, and a multi-byte one is a refusal, not a panic"
    );
    assert!(
        LayerStyle::from_json_lenient("{\"blend_if\":{\"this_layer\":[10,5,255,255]}}").is_err()
    );
    assert!(LayerStyle::from_json("{\"effects\":[{\"type\":\"pattern_overlay\"}]}").is_err());
}

#[test]
fn identity_truth_table() {
    assert!(parse("{}").is_identity());
    assert!(parse("{\"effects\":[]}").is_identity());
    assert!(!parse("{\"fill_opacity\":0.5}").is_identity());
    assert!(
        parse("{\"blend_if\":{\"channel\":\"red\"}}").is_identity(),
        "full-weight ramps"
    );
    assert!(!parse("{\"blend_if\":{\"this_layer\":[0,10,255,255]}}").is_identity());
    assert!(parse("{\"effects\":[{\"type\":\"drop_shadow\",\"enabled\":false}]}").is_identity());
    assert!(!parse("{\"effects\":[{\"type\":\"drop_shadow\"}]}").is_identity());
    let all_off = parse(
        "{\"fill_opacity\":1,\"blend_if\":{\"this_layer\":[0,0,255,255]},\
         \"effects\":[{\"type\":\"satin\",\"enabled\":false},{\"type\":\"stroke\",\"enabled\":false}]}",
    );
    assert!(
        all_off.is_identity(),
        "fill 1 + full ramps + only disabled effects IS identity"
    );
    assert!(BlendIf::default().is_identity());
}

/// The documented reach formulas (style_render's module doc), restated.
fn feather_radius(sigma: f32) -> f32 {
    ((sigma - 0.8) / 0.3 + 1.0).max(0.5)
}

/// 1 (direct) up to sigma 3, then 2, 4 and 8 at each doubling.
fn downsample_factor(sigma: f32) -> u32 {
    if sigma <= 3.0 {
        1
    } else if sigma <= 6.0 {
        2
    } else if sigma <= 12.0 {
        4
    } else {
        8
    }
}

fn blur_reach(sigma: f32) -> u32 {
    if sigma <= 0.0 {
        return 0;
    }
    let f = downsample_factor(sigma);
    if f == 1 {
        return feather_radius(sigma).ceil() as u32 + 1;
    }
    // The reduced-resolution sigma compensates the two resamples' own
    // variance (f^2 / 3); the reach is that kernel's half-width plus one,
    // plus two reduced pixels for the resamples, scaled back by f.
    let ff = f as f32;
    let reduced = (sigma * sigma - ff * ff / 3.0).max(0.0).sqrt() / ff;
    f * (feather_radius(reduced).ceil() as u32 + 1 + 2)
}

#[test]
fn pad_follows_the_documented_reach_and_is_capped() {
    assert_eq!(parse("{}").pad(), 0);
    assert_eq!(
        parse("{\"fill_opacity\":0.5}").pad(),
        0,
        "no enabled effect, no plane"
    );
    let shadow = |size: f32, spread: f32, distance: f32| {
        parse(&format!(
            "{{\"effects\":[{{\"type\":\"drop_shadow\",\"size\":{size},\"spread\":{spread},\
             \"distance\":{distance}}}]}}"
        ))
        .pad()
    };
    assert_eq!(
        shadow(0.0, 0.0, 5.0),
        2,
        "ceil(0) + 1 + blur_reach(0) = 1, +1"
    );
    assert_eq!(
        shadow(4.0, 0.0, 5.0),
        1 + blur_reach(2.0) + 1,
        "sigma 2 -> radius 5"
    );
    assert_eq!(
        shadow(4.0, 1.0, 5.0),
        4 + 1 + 1,
        "spread 1: dilate 4, no blur"
    );
    assert_eq!(shadow(4.0, 0.5, 5.0), 2 + 1 + blur_reach(1.0) + 1);
    assert_eq!(
        shadow(5.0, 0.0, 5.0),
        shadow(5.0, 0.0, 300.0),
        "distance never enters the pad"
    );
    assert_eq!(
        shadow(250.0, 0.0, 5.0),
        1 + blur_reach(125.0) + 1,
        "the downsampled reach"
    );
    let inner = parse("{\"effects\":[{\"type\":\"inner_shadow\",\"size\":0,\"distance\":7}]}");
    assert_eq!(
        inner.pad(),
        1 + 7 + 1,
        "an in-plane shift pads by its distance"
    );
    let bevel = parse("{\"effects\":[{\"type\":\"bevel_emboss\",\"size\":4,\"soften\":0}]}");
    assert_eq!(bevel.pad(), blur_reach(2.0) + 1 + 1);
    assert!(bevel.pad() > blur_reach(2.0), "at least blur_reach + 1");
    let huge = parse("{\"effects\":[{\"type\":\"inner_shadow\",\"distance\":30000}]}");
    assert_eq!(huge.pad(), 1024, "capped");
    let disabled =
        parse("{\"effects\":[{\"type\":\"inner_shadow\",\"distance\":30000,\"enabled\":false}]}");
    assert_eq!(disabled.pad(), 0, "a disabled effect has no reach");
    // shadow_shift is the drop shadow's composite-time offset under the
    // light — what Merge Down grows its extent by, in that direction only.
    let s = parse("{\"effects\":[{\"type\":\"drop_shadow\",\"size\":0,\"distance\":3}]}");
    assert_eq!(
        s.shadow_shift(GlobalLight::default()),
        Some((2, 3)),
        "120 degrees casts down-right"
    );
    assert_eq!(
        s.shadow_shift(GlobalLight {
            angle: 0.0,
            altitude: 30.0
        }),
        Some((-3, 0)),
        "lit from the right, the shadow falls left"
    );
    assert_eq!(
        parse("{\"effects\":[{\"type\":\"satin\"}]}").shadow_shift(GlobalLight::default()),
        None
    );
}

#[test]
fn scaled_multiplies_pixel_fields_only() {
    let s = parse(
        "{\"fill_opacity\":0.5,\"effects\":[\
         {\"type\":\"drop_shadow\",\"distance\":5,\"size\":5,\"spread\":0.5,\"angle\":120,\"opacity\":0.6},\
         {\"type\":\"stroke\",\"size\":3},\
         {\"type\":\"bevel_emboss\",\"size\":5,\"soften\":2,\"depth\":2},\
         {\"type\":\"satin\",\"distance\":11,\"size\":14},\
         {\"type\":\"outer_glow\",\"size\":200},\
         {\"type\":\"color_overlay\"}]}",
    );
    let t = s.scaled(2.0);
    assert_eq!(t.fill_opacity, 0.5);
    let d = drop_shadow(&t);
    assert_eq!(
        (d.distance, d.size, d.spread, d.angle, d.opacity),
        (10.0, 10.0, 0.5, 120.0, 0.6)
    );
    match t.effect(EffectKind::Stroke) {
        Some(Effect::Stroke(st)) => assert_eq!(st.size, 6.0),
        other => panic!("{other:?}"),
    }
    match t.effect(EffectKind::BevelEmboss) {
        Some(Effect::BevelEmboss(b)) => assert_eq!((b.size, b.soften, b.depth), (10.0, 4.0, 2.0)),
        other => panic!("{other:?}"),
    }
    match t.effect(EffectKind::Satin) {
        Some(Effect::Satin(sa)) => assert_eq!((sa.distance, sa.size), (22.0, 28.0)),
        other => panic!("{other:?}"),
    }
    match t.effect(EffectKind::OuterGlow) {
        Some(Effect::OuterGlow(g)) => assert_eq!(g.size, 250.0, "re-clamped"),
        other => panic!("{other:?}"),
    }
    assert_eq!(
        t.effect(EffectKind::ColorOverlay),
        s.effect(EffectKind::ColorOverlay)
    );
    // Quantization: 1/3 scale of 5 is 1.6667.
    assert_eq!(drop_shadow(&s.scaled(1.0 / 3.0)).size, 1.6667);
    assert_eq!(s.scaled(1.0), s, "factor 1 changes nothing");
}

#[test]
fn identity_styles_clear_through_the_ffi() {
    let dir = TempDir::new().unwrap();
    let doc = doc_from(&dir, "bg.png", &solid(6, 4, WHITE));
    let doc = add_layer(&dir, "top.png", doc, 0, &solid(2, 2, RED), "Top");
    // On a plain layer an identity style is a silent refusal.
    assert_eq!(style_error(doc, 1, "{\"effects\":[]}"), None);
    assert_eq!(
        style_error(
            doc,
            1,
            "{\"effects\":[{\"type\":\"drop_shadow\",\"enabled\":false}]}"
        ),
        None
    );
    assert!(!unsafe { rz_doc_layer_has_style(doc, 1) });
    // On a styled layer it clears.
    let doc = set_style(doc, 1, "{\"effects\":[{\"type\":\"drop_shadow\"}]}");
    assert!(unsafe { rz_doc_layer_has_style(doc, 1) });
    let doc = set_style(
        doc,
        1,
        "{\"fill_opacity\":1,\"effects\":[{\"type\":\"drop_shadow\",\"enabled\":false}]}",
    );
    assert!(!unsafe { rz_doc_layer_has_style(doc, 1) });
    assert_eq!(ffi_style(doc, 1), None);
    unsafe { rz_doc_free(doc) };
}

// ------------------------------------------------------------ compositing --

/// A layered fixture exercising opacity, blend mode, offset, a soft mask,
/// an adjustment layer and a clip group — everything the plain walk
/// composites (the byte-identity fixture idea from mask_tests).
fn regression_doc() -> RzDocument {
    let doc = RzDocument::from_pixels(opaque_pattern(8, 6));
    let doc = doc
        .adding_image_layer(0, solid(5, 4, [30, 200, 120, 180]), "Mid")
        .unwrap()
        .with_layer_offset(1, 1, 1)
        .unwrap()
        .with_layer_opacity(1, 0.7)
        .unwrap()
        .with_layer_blend_mode(1, BlendMode::Multiply)
        .unwrap();
    let sel = selection(8, 6, |x, y| if (x + y) % 2 == 0 { 255 } else { 90 });
    let doc = doc.add_mask(1, MaskKind::FromSelection(&sel)).unwrap();
    let doc = doc
        .adding_image_layer(1, solid(8, 6, [200, 40, 40, 255]), "Clipped")
        .unwrap()
        .with_layer_clipped(2, true)
        .unwrap()
        .with_layer_opacity(2, 0.6)
        .unwrap();
    let mut doc = doc
        .adding_image_layer(2, solid(1, 1, MAGENTA), "Adjust")
        .unwrap()
        .with_layer_opacity(3, 0.5)
        .unwrap();
    doc.layers[3].meta = Some(adjust_meta("invert", "{}"));
    doc
}

#[test]
fn unstyled_stacks_composite_byte_identically() {
    let reference = regression_doc().flattened().into_raw();
    // Attaching and clearing a style leaves nothing behind.
    let toggled = styled(
        &regression_doc(),
        1,
        "{\"effects\":[{\"type\":\"drop_shadow\"}]}",
    );
    let toggled = try_styled(&toggled, 1, None).unwrap().expect("clear");
    assert!(toggled.layers.iter().all(|l| l.style.is_none()));
    assert_eq!(toggled.flattened().into_raw(), reference);
    // An adjustment layer given a style composites exactly as without.
    let adjusted = styled(
        &regression_doc(),
        3,
        "{\"fill_opacity\":0.2,\"effects\":[{\"type\":\"drop_shadow\"}]}",
    );
    assert!(adjusted.layers[3].style.is_some());
    assert_eq!(
        adjusted.flattened().into_raw(),
        reference,
        "adjustment layers ignore styles"
    );
    // A hidden styled layer contributes nothing.
    let hidden = styled(
        &regression_doc(),
        1,
        "{\"effects\":[{\"type\":\"drop_shadow\"}]}",
    )
    .with_layer_visible(1, false)
    .unwrap();
    assert_eq!(
        hidden.flattened().into_raw(),
        regression_doc()
            .with_layer_visible(1, false)
            .unwrap()
            .flattened()
            .into_raw()
    );
}

#[test]
fn fill_opacity_matches_layer_opacity_and_the_reference() {
    let color = [30, 200, 120, 255];
    let base = rect_layer_doc((10, 8), (2, 2, 4, 3), color);
    let fill = styled(&base, 1, "{\"fill_opacity\":0.4}");
    let layer = base.with_layer_opacity(1, 0.4).unwrap();
    let fill_flat = fill.flattened();
    assert_eq!(
        fill_flat.clone().into_raw(),
        layer.flattened().into_raw(),
        "same loop, same arithmetic"
    );
    let want = quantized(ref_composite(
        to_unit(WHITE),
        to_unit(color),
        0.4,
        BLEND_NORMAL,
    ));
    for y in 0..8 {
        for x in 0..10 {
            let got = px(&fill_flat, x, y);
            if (2..6).contains(&x) && (2..5).contains(&y) {
                assert_px_close(got, want, &format!("({x},{y})"));
            } else {
                assert_eq!(got, WHITE, "({x},{y}) untouched");
            }
        }
    }
    // Fill and layer opacity multiply.
    let both = styled(
        &base.with_layer_opacity(1, 0.5).unwrap(),
        1,
        "{\"fill_opacity\":0.5}",
    );
    assert_eq!(
        both.flattened().into_raw(),
        base.with_layer_opacity(1, 0.25)
            .unwrap()
            .flattened()
            .into_raw()
    );
    // Half-alpha pixels scale the same way (alpha exact).
    let soft = rect_layer_doc((10, 8), (2, 2, 4, 3), [30, 200, 120, 128]);
    assert_eq!(
        styled(&soft, 1, "{\"fill_opacity\":0.4}")
            .flattened()
            .into_raw(),
        soft.with_layer_opacity(1, 0.4)
            .unwrap()
            .flattened()
            .into_raw()
    );
    // Fill 0 hides the pixels entirely (but is not an identity).
    let none = styled(&base, 1, "{\"fill_opacity\":0}");
    assert_eq!(none.flattened().into_raw(), solid(10, 8, WHITE).into_raw());
}

#[test]
fn styled_clip_base_at_fill_matches_the_source_over_chain() {
    // A blue base at fill 0.4 with a half-opacity red clipped member over
    // its left half; the member covers more than the base and must be
    // confined to it.
    let base = rect_layer_doc((12, 8), (3, 2, 6, 4), BLUE);
    let doc = base
        .adding_image_layer(1, solid(4, 8, RED), "Member")
        .unwrap()
        .with_layer_offset(2, 1, 0)
        .unwrap()
        .with_layer_opacity(2, 0.5)
        .unwrap()
        .with_layer_clipped(2, true)
        .unwrap();
    let doc = styled(&doc, 1, "{\"fill_opacity\":0.4}");
    let flat = doc.flattened();
    let white = to_unit(WHITE);
    for y in 0..8u32 {
        for x in 0..12u32 {
            let got = px(&flat, x, y);
            let in_base = (3..9).contains(&x) && (2..6).contains(&y);
            let in_member = (1..5).contains(&x);
            let want = if in_base {
                // Buffer: base pixels at [blue, 0.4]; the member source-over
                // at 0.5; alpha clamped to the shape (1); then Normal onto
                // white at opacity 1.
                let mut buf = [0.0, 0.0, 1.0, 0.4];
                if in_member {
                    buf = ref_composite(buf, to_unit(RED), 0.5, BLEND_NORMAL);
                    buf[3] = buf[3].min(1.0);
                }
                quantized(ref_composite(white, buf, 1.0, BLEND_NORMAL))
            } else {
                WHITE
            };
            assert_px_close(got, want, &format!("({x},{y})"));
        }
    }
}

#[test]
fn hard_drop_shadow_is_the_rect_translated_by_the_light_offset() {
    let shadow = quantized(ref_composite(
        to_unit(WHITE),
        [0.0, 0.0, 0.0, 1.0],
        0.75,
        BLEND_MULTIPLY,
    ));
    for (angle, shift) in [
        (0.0, (-3, 0)),
        (90.0, (0, 3)),
        (120.0, (2, 3)),
        (180.0, (3, 0)),
        (-90.0, (0, -3)),
    ] {
        let doc = styled(&rect_doc(), 1, &hard_shadow(angle, 3.0));
        let flat = doc.flattened();
        for y in 0..CANVAS.1 {
            for x in 0..CANVAS.0 {
                let got = px(&flat, x, y);
                let (xi, yi) = (i64::from(x), i64::from(y));
                let want = if in_rect(RECT, (0, 0), xi, yi) {
                    RED
                } else if in_rect(RECT, shift, xi, yi) {
                    shadow
                } else {
                    WHITE
                };
                assert_eq!(got, want, "angle {angle} ({x},{y})");
            }
        }
    }
}

#[test]
fn knock_out_keeps_the_shadow_from_under_the_shape() {
    let shadow = quantized(ref_composite(
        to_unit(WHITE),
        [0.0, 0.0, 0.0, 1.0],
        0.75,
        BLEND_MULTIPLY,
    ));
    let json = |knock: bool| {
        format!(
            "{{\"fill_opacity\":0,\"effects\":[{{\"type\":\"drop_shadow\",\"use_global_light\":false,\
             \"angle\":0,\"distance\":3,\"size\":0,\"spread\":0,\"layer_knocks_out\":{knock}}}]}}"
        )
    };
    let knocked = styled(&rect_doc(), 1, &json(true)).flattened();
    let through = styled(&rect_doc(), 1, &json(false)).flattened();
    for y in 0..CANVAS.1 {
        for x in 0..CANVAS.0 {
            let (xi, yi) = (i64::from(x), i64::from(y));
            let under = in_rect(RECT, (0, 0), xi, yi);
            let shadowed = in_rect(RECT, (-3, 0), xi, yi);
            let want_knocked = if shadowed && !under { shadow } else { WHITE };
            let want_through = if shadowed { shadow } else { WHITE };
            assert_eq!(px(&knocked, x, y), want_knocked, "knocked out ({x},{y})");
            assert_eq!(
                px(&through, x, y),
                want_through,
                "showing through ({x},{y})"
            );
        }
    }
}

#[test]
fn soft_drop_shadow_matches_the_feather_oracle() {
    // size 4 -> sigma 2 -> feather radius (2 - 0.8) / 0.3 + 1 = 5.
    let doc = styled(
        &rect_doc(),
        1,
        "{\"effects\":[{\"type\":\"drop_shadow\",\"use_global_light\":false,\"angle\":120,\
         \"distance\":3,\"size\":4,\"spread\":0}]}",
    );
    let flat = doc.flattened();
    let shift = (2, 3);
    let sel = selection(CANVAS.0, CANVAS.1, |x, y| {
        u8::from(in_rect(RECT, shift, i64::from(x), i64::from(y))) * 255
    });
    let plane = feathered_plane(&sel, CANVAS.0, CANVAS.1, 5.0);
    let mut bulk_shadow = 0;
    let mut bulk_white = 0;
    for y in 0..CANVAS.1 {
        for x in 0..CANVAS.0 {
            let got = px(&flat, x, y);
            if in_rect(RECT, (0, 0), i64::from(x), i64::from(y)) {
                assert_eq!(got, RED, "({x},{y}) the rect covers its own shadow");
                continue;
            }
            let cov = plane[(y * CANVAS.0 + x) as usize];
            let want = quantized(ref_composite(
                to_unit(WHITE),
                [0.0, 0.0, 0.0, 1.0],
                0.75 * f32::from(cov) / 255.0,
                BLEND_MULTIPLY,
            ));
            assert_px_close(got, want, &format!("({x},{y}) coverage {cov}"));
            assert_eq!(got[3], 255);
            if cov == 255 {
                bulk_shadow += 1;
                assert_eq!(got, want, "full coverage is exact");
            }
            if cov == 0 {
                bulk_white += 1;
                assert_eq!(got, WHITE, "zero coverage is untouched");
            }
        }
    }
    // A 6x4 rect under a radius-5 kernel never reaches full coverage, so
    // only the untouched bulk is guaranteed to exist here; the full-coverage
    // branch above still pins exactness wherever the oracle says 255.
    assert!(bulk_white > 0, "the untouched bulk exists");
    let _ = bulk_shadow;
}

#[test]
fn spread_drop_shadow_matches_the_grow_oracle() {
    // spread 1 at size 4: the rect grown by 4 with no blur (the grow-rect
    // closed form: outside coverage round(255 * clamp(r + 1 - d, 0, 1)) with
    // d the Euclidean distance to the nearest rect pixel).
    let doc = styled(
        &rect_doc(),
        1,
        "{\"effects\":[{\"type\":\"drop_shadow\",\"use_global_light\":false,\"angle\":0,\
         \"distance\":3,\"size\":4,\"spread\":1}]}",
    );
    let flat = doc.flattened();
    let (sx0, sy0) = (i64::from(RECT.0) - 3, i64::from(RECT.1));
    let (sx1, sy1) = (sx0 + i64::from(RECT.2) - 1, sy0 + i64::from(RECT.3) - 1);
    for y in 0..CANVAS.1 {
        for x in 0..CANVAS.0 {
            let got = px(&flat, x, y);
            let (xi, yi) = (i64::from(x), i64::from(y));
            if in_rect(RECT, (0, 0), xi, yi) {
                assert_eq!(got, RED);
                continue;
            }
            let nx = xi.clamp(sx0, sx1);
            let ny = yi.clamp(sy0, sy1);
            let d = (((xi - nx).pow(2) + (yi - ny).pow(2)) as f32).sqrt();
            let cov = ((4.0 + 1.0 - d).clamp(0.0, 1.0) * 255.0).round() as u8;
            let want = quantized(ref_composite(
                to_unit(WHITE),
                [0.0, 0.0, 0.0, 1.0],
                0.75 * f32::from(cov) / 255.0,
                BLEND_MULTIPLY,
            ));
            if cov == 0 {
                assert_eq!(got, WHITE, "({x},{y}) outside the grown rect");
            } else {
                assert_px_close(got, want, &format!("({x},{y}) coverage {cov}"));
            }
        }
    }
}

#[test]
fn use_global_light_reads_the_document_light_and_the_cache_key_covers_it() {
    let json = "{\"effects\":[{\"type\":\"drop_shadow\",\"use_global_light\":true,\
                \"distance\":3,\"size\":0,\"spread\":0}]}";
    let shadow = quantized(ref_composite(
        to_unit(WHITE),
        [0.0, 0.0, 0.0, 1.0],
        0.75,
        BLEND_MULTIPLY,
    ));
    let doc = styled(&rect_doc(), 1, json);
    // Default light 120 degrees: shift (2, 3). Flatten first so the cache
    // holds this rendering, then change the light on a clone that SHARES
    // the Arc<LayerStyle>.
    let before = doc.flattened();
    assert_eq!(
        px(&before, 19, 16),
        shadow,
        "shadow down-right at 120 degrees"
    );
    assert_eq!(px(&before, 11, 12), WHITE);
    let lit = with_light(&doc, 0.0, 30.0);
    assert!(Arc::ptr_eq(
        doc.layers[1].style.as_ref().unwrap(),
        lit.layers[1].style.as_ref().unwrap()
    ));
    let after = lit.flattened();
    assert_eq!(px(&after, 11, 12), shadow, "shadow left at 0 degrees");
    assert_eq!(px(&after, 19, 16), WHITE);
    assert_eq!(
        doc.flattened().into_raw(),
        before.into_raw(),
        "the original is untouched"
    );
    // A style with its own light renders identically under both lights.
    let own = styled(&rect_doc(), 1, &hard_shadow(120.0, 3.0));
    assert_eq!(
        own.flattened().into_raw(),
        with_light(&own, 0.0, 30.0).flattened().into_raw()
    );
}

#[test]
fn shadow_blend_opacity_and_enabled_follow_the_reference() {
    // Grey canvas so Normal and Multiply differ for a grey shadow.
    let grey = [128, 128, 128, 255];
    let base = {
        let doc = RzDocument::from_pixels(solid(CANVAS.0, CANVAS.1, grey));
        let doc = doc
            .adding_image_layer(0, solid(RECT.2, RECT.3, RED), "Rect")
            .unwrap();
        doc.with_layer_offset(1, RECT.0, RECT.1).unwrap()
    };
    for (name, mode) in [
        ("normal", BLEND_NORMAL),
        ("multiply", BLEND_MULTIPLY),
        ("screen", BLEND_SCREEN),
    ] {
        let doc = styled(
            &base,
            1,
            &format!(
                "{{\"effects\":[{{\"type\":\"drop_shadow\",\"use_global_light\":false,\"angle\":0,\
                 \"distance\":3,\"size\":0,\"blend\":\"{name}\",\"color\":\"#808080\",\"opacity\":0.6}}]}}"
            ),
        );
        let flat = doc.flattened();
        let want = quantized(ref_composite(
            to_unit(grey),
            to_unit([128, 128, 128, 255]),
            0.6,
            mode,
        ));
        assert_px_close(px(&flat, 10, 13), want, name);
        assert_eq!(px(&flat, 30, 13), grey, "{name}: far pixels untouched");
    }
    let plain = base.flattened().into_raw();
    let off = styled(
        &base,
        1,
        "{\"effects\":[{\"type\":\"drop_shadow\",\"opacity\":0}]}",
    );
    assert_eq!(
        off.flattened().into_raw(),
        plain,
        "opacity 0 renders nothing"
    );
    let disabled = styled(
        &base,
        1,
        "{\"fill_opacity\":0.5,\"effects\":[{\"type\":\"drop_shadow\",\"enabled\":false}]}",
    );
    assert_eq!(
        disabled.flattened().into_raw(),
        base.with_layer_opacity(1, 0.5)
            .unwrap()
            .flattened()
            .into_raw(),
        "a disabled effect renders nothing"
    );
}

#[test]
fn identical_documents_render_identical_bytes() {
    let json = "{\"effects\":[{\"type\":\"drop_shadow\",\"size\":6,\"spread\":0.3}]}";
    let a = styled(&rect_doc(), 1, json);
    let first = a.flattened().into_raw();
    let second = a.flattened().into_raw();
    assert_eq!(first, second, "cache hit == fresh render");
    let b = styled(&rect_doc(), 1, json);
    assert_eq!(
        b.flattened().into_raw(),
        first,
        "a fresh document renders the same bytes"
    );
    // Move drag / opacity scrub reuse the planes and stay consistent.
    let moved = a.with_layer_offset(1, 14, 13).unwrap();
    let fresh_moved = styled(&rect_doc().with_layer_offset(1, 14, 13).unwrap(), 1, json);
    assert_eq!(
        moved.flattened().into_raw(),
        fresh_moved.flattened().into_raw()
    );
}

#[test]
fn below_effects_keep_their_own_blend_on_a_multiply_layer() {
    let grey = [128, 128, 128, 255];
    let doc = RzDocument::from_pixels(solid(CANVAS.0, CANVAS.1, grey));
    let doc = doc
        .adding_image_layer(0, solid(RECT.2, RECT.3, BLUE), "Rect")
        .unwrap()
        .with_layer_offset(1, RECT.0, RECT.1)
        .unwrap()
        .with_layer_blend_mode(1, BlendMode::Multiply)
        .unwrap();
    let doc = styled(
        &doc,
        1,
        "{\"effects\":[{\"type\":\"drop_shadow\",\"use_global_light\":false,\"angle\":0,\
         \"distance\":3,\"size\":0,\"blend\":\"normal\",\"color\":\"#ffffff\",\"opacity\":0.75}]}",
    );
    let flat = doc.flattened();
    let want = quantized(ref_composite(
        to_unit(grey),
        [1.0, 1.0, 1.0, 1.0],
        0.75,
        BLEND_NORMAL,
    ));
    let not_want = quantized(ref_composite(
        to_unit(grey),
        [1.0, 1.0, 1.0, 1.0],
        0.75,
        BLEND_MULTIPLY,
    ));
    assert_ne!(want, not_want, "the fixture distinguishes the two modes");
    assert_px_close(
        px(&flat, 10, 13),
        want,
        "the shadow uses its own Normal blend",
    );
    // The pixels still use the layer's Multiply.
    let pixel_want = quantized(ref_composite(
        to_unit(grey),
        to_unit(BLUE),
        1.0,
        BLEND_MULTIPLY,
    ));
    assert_px_close(
        px(&flat, 13, 13),
        pixel_want,
        "the layer's pixels use Multiply",
    );
}

#[test]
fn styled_clip_bases_render_one_shadow_and_confine_their_members() {
    let json = hard_shadow(0.0, 3.0);
    let shadow = quantized(ref_composite(
        to_unit(WHITE),
        [0.0, 0.0, 0.0, 1.0],
        0.75,
        BLEND_MULTIPLY,
    ));
    let grouped = rect_doc()
        .adding_image_layer(1, solid(CANVAS.0, CANVAS.1, GREEN), "Texture")
        .unwrap()
        .with_layer_clipped(2, true)
        .unwrap();
    let with_member = styled(&grouped, 1, &json);
    let without_member = with_member.with_layer_visible(2, false).unwrap();
    let a = with_member.flattened();
    let b = without_member.flattened();
    for y in 0..CANVAS.1 {
        for x in 0..CANVAS.0 {
            let (xi, yi) = (i64::from(x), i64::from(y));
            if in_rect(RECT, (0, 0), xi, yi) {
                assert_eq!(
                    px(&a, x, y),
                    GREEN,
                    "({x},{y}) the member shows inside the base"
                );
                assert_eq!(px(&b, x, y), RED);
            } else {
                assert_eq!(
                    px(&a, x, y),
                    px(&b, x, y),
                    "({x},{y}) one shadow, member confined"
                );
                let want = if in_rect(RECT, (-3, 0), xi, yi) {
                    shadow
                } else {
                    WHITE
                };
                assert_eq!(px(&a, x, y), want);
            }
        }
    }
    // A base at fill 0 with an opaque member: the member shows inside the
    // shape and nothing outside; the knocked-out shadow stays outside too.
    let hollow = styled(&grouped, 1, &format!("{{\"fill_opacity\":0,{}", &json[1..]));
    let flat = hollow.flattened();
    for y in 0..CANVAS.1 {
        for x in 0..CANVAS.0 {
            let (xi, yi) = (i64::from(x), i64::from(y));
            let want = if in_rect(RECT, (0, 0), xi, yi) {
                GREEN
            } else if in_rect(RECT, (-3, 0), xi, yi) {
                shadow
            } else {
                WHITE
            };
            assert_eq!(px(&flat, x, y), want, "fill 0 base ({x},{y})");
        }
    }
    // A styled clipped MEMBER: its shadow is confined to the base shape.
    let member_rect = (14, 13, 3, 2);
    let member_doc = rect_doc()
        .adding_image_layer(1, solid(member_rect.2, member_rect.3, BLUE), "Member")
        .unwrap()
        .with_layer_offset(2, member_rect.0, member_rect.1)
        .unwrap()
        .with_layer_clipped(2, true)
        .unwrap();
    let member_doc = styled(&member_doc, 2, &hard_shadow(0.0, 3.0));
    let flat = member_doc.flattened();
    let member_shadow = quantized(ref_composite(
        to_unit(RED),
        [0.0, 0.0, 0.0, 1.0],
        0.75,
        BLEND_MULTIPLY,
    ));
    for y in 0..CANVAS.1 {
        for x in 0..CANVAS.0 {
            let (xi, yi) = (i64::from(x), i64::from(y));
            let got = px(&flat, x, y);
            if !in_rect(RECT, (0, 0), xi, yi) {
                assert_eq!(
                    got, WHITE,
                    "({x},{y}) nothing of the member escapes the base"
                );
            } else if in_rect(member_rect, (0, 0), xi, yi) {
                assert_eq!(got, BLUE);
            } else if in_rect(member_rect, (-3, 0), xi, yi) {
                assert_px_close(
                    got,
                    member_shadow,
                    &format!("({x},{y}) member shadow over the base"),
                );
            } else {
                assert_eq!(got, RED);
            }
        }
    }
}

#[test]
fn merge_down_and_flatten_bake_the_shadow() {
    // Opaque white layer 0 under the styled rect with the DEFAULT shadow:
    // over an opaque backdrop the merged pixels quantize once, exactly like
    // the projection.
    let doc = styled(&rect_doc(), 1, "{\"effects\":[{\"type\":\"drop_shadow\"}]}");
    let pad = i64::from(doc.layers[1].style.as_ref().unwrap().pad());
    let before = doc.flattened().into_raw();
    let merged = doc.merging_down(1).expect("merge");
    assert_eq!(merged.layers.len(), 1);
    assert!(
        merged.layers[0].style.is_none(),
        "the merged layer carries no style"
    );
    assert_eq!(
        merged.flattened().into_raw(),
        before,
        "the projection survives the merge"
    );
    // The extent grows by the pad on every side and by the shadow's shift
    // (down-right at 120 degrees) on the far sides only, clipped to the
    // canvas — here the union with the canvas-sized layer 0 is the canvas.
    let expected_offset = (
        (i64::from(RECT.0) - pad).min(0) as i32,
        (i64::from(RECT.1) - pad).min(0) as i32,
    );
    assert_eq!(merged.layers[0].offset, expected_offset);
    assert_eq!(
        merged.layers[0].pixels.dimensions(),
        CANVAS,
        "nothing beyond the canvas"
    );
    let flat = merged.flattened();
    assert_ne!(
        px(&flat, 19, 17),
        WHITE,
        "the shadow is in the merged pixels"
    );
    assert_eq!(px(&flat, 13, 13), RED);
    // Flatten bakes it too and keeps the light.
    let lit = with_light(&doc, 45.0, 60.0);
    let flattened = lit.flattening();
    assert_eq!(flattened.layers.len(), 1);
    assert!(flattened.layers[0].style.is_none());
    assert_eq!(
        flattened.global_light,
        GlobalLight {
            angle: 45.0,
            altitude: 60.0
        }
    );
    assert_eq!(flattened.flattened().into_raw(), lit.flattened().into_raw());
}

#[test]
fn merge_down_grows_only_toward_the_shadow_and_clips_it_to_the_canvas() {
    // A 10x10 white layer at (60, 60) under a 20x20 red layer at (30, 30)
    // carrying a hard shadow cast LEFT (angle 0) by 10 px, on a transparent
    // 100x100 canvas. Size 0 -> reach 1 -> pad 2: the merged extent is the
    // red rect grown by 2, then by the 10 px shift on the left only, in
    // union with the white square.
    let base = RzDocument::from_pixels(solid(100, 100, [0, 0, 0, 0]))
        .adding_image_layer(0, solid(10, 10, WHITE), "Lower")
        .unwrap()
        .with_layer_offset(1, 60, 60)
        .unwrap()
        .adding_image_layer(1, solid(20, 20, RED), "Upper")
        .unwrap()
        .with_layer_offset(2, 30, 30)
        .unwrap();
    let doc = styled(&base, 2, &hard_shadow(0.0, 10.0));
    assert_eq!(doc.layers[2].style.as_ref().unwrap().pad(), 2);
    let before = doc.flattened().into_raw();
    let merged = doc.merging_down(2).expect("merge");
    let layer = &merged.layers[1];
    assert_eq!(
        layer.offset,
        (18, 28),
        "grown by the pad and the 10 px shift on the left"
    );
    assert_eq!(
        layer.pixels.dimensions(),
        (52, 42),
        "the pad alone on the right and below"
    );
    assert_eq!(
        merged.flattened().into_raw(),
        before,
        "the projection survives the merge"
    );
    // A legal but absurd distance: the shifted rect lies entirely off the
    // canvas (where it is never visible), so it adds nothing — the merge
    // neither balloons to tens of megapixels nor refuses.
    let far = styled(&base, 2, &hard_shadow(0.0, 30000.0));
    let before = far.flattened().into_raw();
    let merged = far.merging_down(2).expect("a far shadow still merges");
    assert_eq!(merged.layers[1].offset, (28, 28));
    assert_eq!(merged.layers[1].pixels.dimensions(), (42, 42));
    assert_eq!(merged.flattened().into_raw(), before);
}

#[test]
fn multibyte_colours_are_refused_through_the_ffi_naming_the_key() {
    // The setter's contract: a bad colour is a key-naming error the host
    // can act on, never the catch_unwind's "internal error".
    for json in [
        "{\"effects\":[{\"type\":\"drop_shadow\",\"color\":\"#aé123\"}]}",
        "{\"effects\":[{\"type\":\"drop_shadow\",\"color\":\"#0é000ff\"}]}",
    ] {
        let err = try_styled(&rect_doc(), 1, Some(json))
            .err()
            .unwrap_or_else(|| panic!("{json} must be refused"));
        assert!(err.contains("effects[0].color"), "{json}: {err}");
        assert!(!err.contains("internal error"), "{json}: {err}");
    }
}

#[test]
fn large_blur_sizes_take_the_downsampled_path_sanely() {
    // size 60 -> sigma 30 > 8: quarter-resolution blur. No oracle at this
    // softness; pin the properties any Gaussian keeps.
    let doc = styled(
        &rect_layer_doc((240, 120), (90, 30, 60, 60), RED),
        1,
        "{\"effects\":[{\"type\":\"drop_shadow\",\"use_global_light\":false,\"angle\":0,\
         \"distance\":0,\"size\":40,\"layer_knocks_out\":false}],\"fill_opacity\":0}",
    );
    let flat = doc.flattened();
    let row = 60;
    let darkness = |x: u32| 255 - u32::from(px(&flat, x, row)[0]);
    assert!(darkness(120) > 100, "the shadow is dark at the rect centre");
    assert_eq!(px(&flat, 2, row), WHITE, "far pixels are untouched");
    let mut previous = darkness(120);
    for x in 121..240 {
        let d = darkness(x);
        assert!(
            d <= previous + 1,
            "monotone fade at x={x}: {d} after {previous}"
        );
        previous = d;
    }
    for k in 1..80 {
        let l = darkness(120 - k);
        let r = darkness(120 + k);
        assert!(
            (i64::from(l) - i64::from(r)).abs() <= 4,
            "roughly symmetric at ±{k}: {l} vs {r}"
        );
    }
}
