//! Layer styles — the per-style rendered-plane cache: the pointer keys and
//! the shape-equality refresh across Duplicate Layer and divergence (one
//! key per layer over shared planes, each keeping its own bounds), the
//! incremental sub-plane re-render on a brush tick (every effect, every blur
//! level, both morphologies) and its capped-pad fallback, the hand-over of
//! planes between style versions (`inherit_planes`: what a replaced version
//! keeps, what its successor starts with, what a version edit costs however
//! many entries undo keeps alive, and adoption through a version that never
//! composited), and the cost budget of the plain styled path. The oracle throughout is a FRESH style — an empty cache,
//! hence a full render — whose projection every cached one must equal byte
//! for byte. Black-box through the public API and the FFI; shared fixtures
//! live in `tests/common`, the model and compositing coverage in `style.rs`.

use std::sync::Arc;
use std::time::{Duration, Instant};

use image::{Rgba, RgbaImage};
use rasterize_core::doc::{MaskKind, RzDocument};
use rasterize_core::ffi_doc::*;

mod common;
use common::*;

// ---------------------------------------------------------------- helpers --

/// Paints a canvas-frame premultiplied overlay onto layer `idx` through the
/// FFI (`rz_doc_painting_layer`), asserting success.
fn painted(doc: &RzDocument, idx: usize, overlay: &[u8], mode: i32, alpha: f32) -> RzDocument {
    let handle = Box::into_raw(Box::new(doc.clone()));
    let out = unsafe {
        rz_doc_painting_layer(
            handle,
            idx,
            overlay.as_ptr(),
            doc.width,
            doc.height,
            mode,
            alpha,
        )
    };
    unsafe { rz_doc_free(handle) };
    assert!(!out.is_null(), "painting_layer refused");
    *unsafe { Box::from_raw(out) }
}

fn px(flat: &RgbaImage, x: u32, y: u32) -> [u8; 4] {
    flat.get_pixel(x, y).0
}

/// The white-canvas / red-rect fixture `style.rs` shares: a 40x32 canvas
/// with a 6x4 rect at (12, 12), far enough from every edge that no blur or
/// growth reaches the border.
const CANVAS: (u32, u32) = (40, 32);

fn rect_doc() -> RzDocument {
    rect_layer_doc(CANVAS, (12, 12, 6, 4), RED)
}

/// A canvas-frame premultiplied overlay with `rect` filled by `px`.
fn overlay_rect(w: u32, h: u32, rect: (u32, u32, u32, u32), px: [u8; 4]) -> Vec<u8> {
    let mut out = vec![0u8; (w * h * 4) as usize];
    for y in rect.1..rect.1 + rect.3 {
        for x in rect.0..rect.0 + rect.2 {
            let i = ((y * w + x) * 4) as usize;
            out[i..i + 4].copy_from_slice(&px);
        }
    }
    out
}

/// The projection of `doc` with layer 1 restyled from a FRESH parse of
/// `json` — an empty cache, hence a full render: the oracle every cache
/// path is held to.
fn fresh_render(doc: &RzDocument, json: &str) -> Vec<u8> {
    let mut fresh = doc.clone();
    fresh.layers[1].style = Some(Arc::new(parse(json)));
    fresh.flattened().into_raw()
}

// -------------------------------------------------------------- the cache --

#[test]
fn cache_survives_duplicate_and_divergence() {
    let json = "{\"effects\":[{\"type\":\"drop_shadow\",\"size\":4}]}";
    let styled_doc = styled(&rect_doc(), 1, json);
    let dup = styled_doc.duplicating_layer(1).unwrap();
    assert!(Arc::ptr_eq(
        dup.layers[1].style.as_ref().unwrap(),
        dup.layers[2].style.as_ref().unwrap()
    ));
    let _ = dup.flattened();
    // An overlay that changes ALPHA: erase the copy's left half.
    let mut erase = vec![0u8; (CANVAS.0 * CANVAS.1 * 4) as usize];
    for y in 0..CANVAS.1 {
        for x in 0..CANVAS.0 {
            if x < 15 {
                erase[((y * CANVAS.0 + x) * 4 + 3) as usize] = 255;
            }
        }
    }
    let diverged = painted(&dup, 2, &erase, COMPOSITE_ERASE, 1.0);
    assert_ne!(
        diverged.layers[2].pixels.as_raw(),
        diverged.layers[1].pixels.as_raw()
    );
    let one = diverged.flattened().into_raw();
    let two = diverged.flattened().into_raw();
    assert_eq!(one, two);
    let mut fresh = diverged.clone();
    fresh.layers[1].style = Some(Arc::new(parse(json)));
    fresh.layers[2].style = Some(Arc::new(parse(json)));
    assert_eq!(
        fresh.flattened().into_raw(),
        one,
        "cached planes equal fresh ones after divergence"
    );
    // An overlay that only changes COLOUR on the opaque copy: the
    // shape-equality fallback must be exact.
    let mut paint = vec![0u8; (CANVAS.0 * CANVAS.1 * 4) as usize];
    for y in 12..16 {
        for x in 12..15 {
            let i = ((y * CANVAS.0 + x) * 4) as usize;
            paint[i..i + 4].copy_from_slice(&[0, 0, 255, 255]);
        }
    }
    let recoloured = painted(&dup, 2, &paint, COMPOSITE_OVER, 1.0);
    assert_eq!(recoloured.layers[2].pixels.get_pixel(0, 0).0, BLUE);
    let one = recoloured.flattened().into_raw();
    assert_eq!(recoloured.flattened().into_raw(), one);
    let mut fresh = recoloured.clone();
    fresh.layers[1].style = Some(Arc::new(parse(json)));
    fresh.layers[2].style = Some(Arc::new(parse(json)));
    assert_eq!(
        fresh.flattened().into_raw(),
        one,
        "the shape-equality hit is exact"
    );
}

#[test]
fn a_brush_tick_on_a_styled_layer_patches_the_cached_planes_exactly() {
    // A canvas-sized layer whose content is a 200x150 rect (the shape's
    // bounds are the rect; the plane is the canvas plus the pad). A first
    // flatten fills each style's cache; the edits then change the shape
    // locally (a hole, a dab beside the rect) or not at all (a recolour),
    // and every projection must equal, byte for byte, what a FRESH style —
    // a fresh cache, hence a full render — produces. Sizes are chosen to
    // cover the direct, 2x, 4x and 8x blur paths, both morphologies, the
    // in-plane shifts, the bevel stencil and both gradient alignments.
    const W: u32 = 480;
    const H: u32 = 360;
    let mut content = RgbaImage::from_pixel(W, H, Rgba([0, 0, 0, 0]));
    for y in 100..250 {
        for x in 140..340 {
            content.put_pixel(x, y, Rgba(RED));
        }
    }
    let base = RzDocument::from_pixels(solid(W, H, WHITE))
        .adding_image_layer(0, content, "Content")
        .unwrap();
    let styles = [
        "{\"effects\":[{\"type\":\"drop_shadow\",\"size\":40,\"distance\":12}]}",
        "{\"effects\":[{\"type\":\"drop_shadow\",\"size\":9,\"spread\":0.3}]}",
        "{\"effects\":[{\"type\":\"outer_glow\",\"size\":14,\"spread\":0.5}]}",
        "{\"effects\":[{\"type\":\"stroke\",\"size\":5,\"position\":\"center\"}]}",
        "{\"effects\":[{\"type\":\"inner_shadow\",\"size\":6,\"distance\":7}]}",
        "{\"effects\":[{\"type\":\"inner_glow\",\"size\":8,\"source\":\"center\"}]}",
        "{\"effects\":[{\"type\":\"bevel_emboss\",\"size\":24,\"soften\":3,\"style\":\"emboss\"}]}",
        "{\"effects\":[{\"type\":\"satin\"}]}",
        "{\"effects\":[{\"type\":\"gradient_overlay\",\"gradient\":{\"style\":\"radial\"}}]}",
        "{\"effects\":[{\"type\":\"stroke\",\"fill_type\":\"gradient\",\
         \"gradient\":{\"align_with_layer\":false}},{\"type\":\"color_overlay\",\"opacity\":0.5}]}",
    ];
    let hole = overlay_rect(W, H, (230, 170, 8, 6), [0, 0, 0, 255]);
    let dab = overlay_rect(W, H, (60, 40, 12, 12), [0, 0, 255, 255]);
    let recolour = overlay_rect(W, H, (150, 110, 20, 20), [0, 255, 0, 255]);
    for json in styles {
        let cached = styled(&base, 1, json);
        let _ = cached.flattened();
        for (name, overlay, mode) in [
            ("hole", &hole, COMPOSITE_ERASE),
            ("dab", &dab, COMPOSITE_OVER),
            ("recolour", &recolour, COMPOSITE_OVER),
        ] {
            let edited = painted(&cached, 1, overlay, mode, 1.0);
            let got = edited.flattened().into_raw();
            let mut fresh = edited.clone();
            fresh.layers[1].style = Some(Arc::new(parse(json)));
            assert_eq!(got, fresh.flattened().into_raw(), "{json}: {name}");
        }
        // Successive ticks patch already-patched planes.
        let mut doc = cached;
        for i in 0..3u32 {
            let tick = overlay_rect(W, H, (200 + 30 * i, 180, 10, 10), [0, 0, 0, 255]);
            doc = painted(&doc, 1, &tick, COMPOSITE_ERASE, 1.0);
            let mut fresh = doc.clone();
            fresh.layers[1].style = Some(Arc::new(parse(json)));
            assert_eq!(
                doc.flattened().into_raw(),
                fresh.flattened().into_raw(),
                "{json}: tick {i}"
            );
        }
        // Layer > Mask > Apply: the hidden part bakes into the alpha, so
        // the coverage is byte-identical to the masked one while the
        // shape's BOUNDS — the alpha box a layer-aligned gradient spans —
        // shrink from the rect to its visible part. The identical-coverage
        // refresh must not hand back planes rendered against the old box.
        let sel = selection(W, H, |x, _| u8::from(x < 260) * 255);
        let masked = styled(
            &base.add_mask(1, MaskKind::FromSelection(&sel)).unwrap(),
            1,
            json,
        );
        let _ = masked.flattened();
        let applied = masked.remove_mask(1, true).unwrap();
        let mut fresh = applied.clone();
        fresh.layers[1].style = Some(Arc::new(parse(json)));
        assert_eq!(
            applied.flattened().into_raw(),
            fresh.flattened().into_raw(),
            "{json}: apply mask"
        );
    }
}

#[test]
fn a_capped_pad_falls_back_to_a_full_render_on_a_brush_tick() {
    // An inner shadow at distance 1500 reaches past MAX_PAD (1024): the
    // pad is the cap, a full render stays exact (the shift fills from
    // beyond the plane with what an infinite plane holds), but a hole
    // erased into the layer casts its shadow 1500 px to the right — farther
    // than the incremental re-render's windows, sized from the pad, span.
    // The plane must be big enough (twice the ~17 MP input window) for that
    // path to be taken at all: a 4000 x 4000 layer, mostly off a small
    // canvas that still shows the hole and where its shadow lands.
    const CW: u32 = 1700;
    const CH: u32 = 200;
    let doc = RzDocument::from_pixels(solid(CW, CH, WHITE))
        .adding_image_layer(0, solid(4000, 4000, RED), "Big")
        .unwrap()
        .with_layer_offset(1, -1000, -1900)
        .unwrap();
    let json = "{\"effects\":[{\"type\":\"inner_shadow\",\"use_global_light\":false,\
         \"angle\":180,\"distance\":1500,\"size\":0,\"opacity\":1,\"blend\":\"normal\"}]}";
    let cached = styled(&doc, 1, json);
    assert_eq!(px(&cached.flattened(), 1565, 115), RED, "no shadow yet");
    let hole = overlay_rect(CW, CH, (50, 100, 30, 30), [0, 0, 0, 255]);
    let edited = painted(&cached, 1, &hole, COMPOSITE_ERASE, 1.0);
    let got = edited.flattened();
    let mut fresh = edited.clone();
    fresh.layers[1].style = Some(Arc::new(parse(json)));
    let want = fresh.flattened();
    assert_eq!(
        px(&want, 1565, 115),
        [0, 0, 0, 255],
        "the hole's shadow, 1500 px right"
    );
    assert_eq!(px(&want, 65, 115), WHITE, "the hole itself");
    assert_eq!(got.into_raw(), want.into_raw());
}

#[test]
fn a_refreshed_entry_carries_the_bounds_a_later_gradient_spans() {
    // The identical-coverage refresh (module doc) re-keys an entry whose
    // coverage did not change while the layer's ALPHA box did — painting
    // under a masked-out region, or Layer > Mask > Apply baking the mask
    // into the alpha. The style at that point reads no bounds, so the
    // refresh is exact for it; but the style set NEXT inherits the entry
    // and renders its new effects over the entry's shape, and a
    // layer-aligned gradient spans that shape's bounds. Oracle: a
    // black-to-white linear gradient at angle 0 across the box [bx0, bx1)
    // is grey round(255 (x + 0.5 - bx0) / (bx1 - bx0)) at column x, and the
    // cached projection must equal a fresh style's byte for byte.
    const W: u32 = 40;
    const H: u32 = 20;
    const SHADOW: &str = "{\"effects\":[{\"type\":\"drop_shadow\"}]}";
    const BOTH: &str = "{\"effects\":[{\"type\":\"drop_shadow\"},\
         {\"type\":\"gradient_overlay\",\"gradient\":{\"angle\":0,\"align_with_layer\":true}}]}";
    let grey = |x: u32, bx0: u32, bx1: u32| -> u8 {
        ((x as f32 + 0.5 - bx0 as f32) / (bx1 - bx0) as f32 * 255.0).round() as u8
    };
    let sel = selection(W, H, |x, _| u8::from(x < 10) * 255);

    // Painting under the mask: opaque at x < 10 under a mask hiding x >= 10;
    // paint at x >= 30 widens the alpha box to the whole layer while the
    // coverage stays put.
    let mut content = RgbaImage::from_pixel(W, H, Rgba([0, 0, 0, 0]));
    for y in 0..H {
        for x in 0..10 {
            content.put_pixel(x, y, Rgba(RED));
        }
    }
    let base = RzDocument::from_pixels(solid(W, H, WHITE))
        .adding_image_layer(0, content, "L")
        .unwrap();
    let masked = base.add_mask(1, MaskKind::FromSelection(&sel)).unwrap();
    let v1 = styled(&masked, 1, SHADOW);
    let _ = v1.flattened();
    let overlay = overlay_rect(W, H, (30, 0, 10, H), BLUE);
    let v2 = painted(&v1, 1, &overlay, COMPOSITE_OVER, 1.0);
    let _ = v2.flattened(); // the refresh: same coverage, box 0..10 -> 0..40
    let v3 = styled(&v2, 1, BOTH);
    let got = v3.flattened().into_raw();
    let want = fresh_render(&v3, BOTH);
    assert_eq!(
        pixel(&want, W, 5, 0)[0],
        grey(5, 0, 40),
        "oracle: the whole layer"
    );
    assert_eq!(got, want, "paint under the mask");

    // Layer > Mask > Apply: an opaque layer under the same mask; applying
    // it bakes the hidden part into the alpha, so the box shrinks to the
    // visible 0..10 while the coverage is byte-identical.
    let base = RzDocument::from_pixels(solid(W, H, WHITE))
        .adding_image_layer(0, solid(W, H, RED), "L")
        .unwrap();
    let masked = base.add_mask(1, MaskKind::FromSelection(&sel)).unwrap();
    let v1 = styled(&masked, 1, SHADOW);
    let _ = v1.flattened();
    let v2 = v1.remove_mask(1, true).unwrap();
    let _ = v2.flattened(); // the refresh: same coverage, box 0..40 -> 0..10
    let v3 = styled(&v2, 1, BOTH);
    let got = v3.flattened().into_raw();
    let want = fresh_render(&v3, BOTH);
    assert_eq!(
        pixel(&want, W, 5, 0)[0],
        grey(5, 0, 10),
        "oracle: the visible part"
    );
    assert_eq!(got, want, "apply mask");
}

#[test]
fn an_inside_stroke_tick_re_renders_from_a_window_that_sees_its_band() {
    // An inside band is coverage − erode(coverage, size): a pixel's band
    // value reads the shape `size` px away, so a tick's re-render window
    // must reach that far past the tick even though nothing of the band
    // lands beyond the shape. A 40x20 opaque layer with a transparent
    // column at x = 8 and a 3 px inside stroke: the band runs x = 5..8 to
    // the column's left. An eraser tick just left of the band (alpha 255 ->
    // 254 at x in [3, 5), y in [8, 10)) changes the coverage without
    // touching the band; a window sized from a reach of 0 re-renders
    // x = 5..7 without seeing the column and patches the band away.
    const W: u32 = 40;
    const H: u32 = 20;
    let json = "{\"effects\":[{\"type\":\"stroke\",\"position\":\"inside\",\"size\":3}]}";
    let mut content = solid(W, H, RED);
    for y in 0..H {
        content.put_pixel(8, y, Rgba([0, 0, 0, 0]));
    }
    let base = RzDocument::from_pixels(solid(W, H, WHITE))
        .adding_image_layer(0, content, "Content")
        .unwrap();
    let cached = styled(&base, 1, json);
    let first = cached.flattened();
    assert_eq!(
        px(&first, 6, 9),
        [0, 0, 0, 255],
        "the band left of the column"
    );
    assert_eq!(px(&first, 20, 9), RED, "the interior, clear of every edge");
    let tick = overlay_rect(W, H, (3, 8, 2, 2), [0, 0, 0, 1]);
    let edited = painted(&cached, 1, &tick, COMPOSITE_ERASE, 1.0);
    assert!(
        edited.layers[1].pixels.get_pixel(3, 8).0[3] < 255,
        "the tick changed the coverage"
    );
    let got = edited.flattened();
    assert_eq!(px(&got, 6, 9), [0, 0, 0, 255], "the band survives the tick");
    assert_eq!(got.into_raw(), fresh_render(&edited, json));
}

#[test]
fn a_replaced_style_hands_its_planes_over_and_keeps_none() {
    // Every cache entry holds one Weak on the layer's pixel Arc, and every
    // document here shares that Arc, so its weak count IS the number of
    // plane sets retained for the layer across every document alive — what
    // an undo stack of style versions would pin. A version replaced by
    // set_layer_style must keep none, and its successor must start with
    // the planes when only colours, blends, opacities or the shadow's
    // composite-time offset changed, or when one effect's geometry did
    // (that effect alone re-rendered) — projecting, byte for byte, what a
    // full render of the new style produces.
    const W: u32 = 160;
    const H: u32 = 120;
    let mut content = RgbaImage::from_pixel(W, H, Rgba([0, 0, 0, 0]));
    for y in 30..90 {
        for x in 40..120 {
            content.put_pixel(x, y, Rgba(RED));
        }
    }
    let base = RzDocument::from_pixels(solid(W, H, WHITE))
        .adding_image_layer(0, content, "Content")
        .unwrap();
    let retained = |doc: &RzDocument| Arc::weak_count(&doc.layers[1].pixels);
    let effects = |list: &str| format!("{{\"effects\":[{list}]}}");
    let gradient = |a: &str, b: &str| {
        format!(
            "\"gradient\":{{\"angle\":30,\"stops\":[{{\"position\":0,\"color\":\"{a}\",\
             \"opacity\":1}},{{\"position\":1,\"color\":\"{b}\",\"opacity\":0.5}}]}}"
        )
    };
    // (before, after): the same planes, different stamps.
    let restamps: Vec<(String, String)> = vec![
        (
            "{\"type\":\"drop_shadow\",\"size\":9,\"spread\":0.3}".into(),
            "{\"type\":\"drop_shadow\",\"size\":9,\"spread\":0.3,\"color\":\"#123456\",\
             \"blend\":\"normal\",\"opacity\":0.4,\"use_global_light\":false,\"angle\":30,\
             \"distance\":9,\"layer_knocks_out\":false}"
                .into(),
        ),
        (
            "{\"type\":\"inner_shadow\",\"size\":6,\"distance\":4}".into(),
            "{\"type\":\"inner_shadow\",\"size\":6,\"distance\":4,\"color\":\"#00ff00\",\
             \"blend\":\"screen\",\"opacity\":1}"
                .into(),
        ),
        (
            "{\"type\":\"outer_glow\",\"size\":10,\"spread\":0.4}".into(),
            "{\"type\":\"outer_glow\",\"size\":10,\"spread\":0.4,\"color\":\"#0000ff\",\
             \"blend\":\"normal\",\"opacity\":0.9}"
                .into(),
        ),
        (
            "{\"type\":\"inner_glow\",\"size\":8,\"source\":\"center\"}".into(),
            "{\"type\":\"inner_glow\",\"size\":8,\"source\":\"center\",\"color\":\"#ff00ff\",\
             \"blend\":\"multiply\",\"opacity\":0.6}"
                .into(),
        ),
        (
            "{\"type\":\"stroke\",\"size\":4,\"position\":\"center\"}".into(),
            "{\"type\":\"stroke\",\"size\":4,\"position\":\"center\",\"color\":\"#00ffff\",\
             \"blend\":\"difference\",\"opacity\":0.7}"
                .into(),
        ),
        (
            format!(
                "{{\"type\":\"stroke\",\"size\":4,\"fill_type\":\"gradient\",{}}}",
                gradient("#ff0000", "#0000ff")
            ),
            format!(
                "{{\"type\":\"stroke\",\"size\":4,\"fill_type\":\"gradient\",{},\"opacity\":0.8}}",
                gradient("#00ff00", "#ffff00")
            ),
        ),
        (
            "{\"type\":\"color_overlay\"}".into(),
            "{\"type\":\"color_overlay\",\"color\":\"#336699\",\"blend\":\"overlay\",\
             \"opacity\":0.5}"
                .into(),
        ),
        (
            format!(
                "{{\"type\":\"gradient_overlay\",{}}}",
                gradient("#ff0000", "#0000ff")
            ),
            format!(
                "{{\"type\":\"gradient_overlay\",{},\"blend\":\"screen\",\"opacity\":0.6}}",
                gradient("#123456", "#abcdef")
            ),
        ),
        (
            "{\"type\":\"bevel_emboss\",\"size\":10,\"style\":\"emboss\"}".into(),
            "{\"type\":\"bevel_emboss\",\"size\":10,\"style\":\"emboss\",\
             \"highlight_color\":\"#ffff00\",\"highlight_blend\":\"normal\",\
             \"highlight_opacity\":1,\"shadow_color\":\"#000080\",\"shadow_blend\":\"normal\",\
             \"shadow_opacity\":0.3}"
                .into(),
        ),
        (
            "{\"type\":\"satin\"}".into(),
            "{\"type\":\"satin\",\"color\":\"#ff8800\",\"blend\":\"normal\",\"opacity\":1}".into(),
        ),
        // The light an effect resolves to is what counts, not how it got
        // there: the document's 120° and an explicit 120° share planes.
        (
            "{\"type\":\"inner_shadow\",\"use_global_light\":true}".into(),
            "{\"type\":\"inner_shadow\",\"use_global_light\":false,\"angle\":120}".into(),
        ),
    ];
    for (before, after) in &restamps {
        let (before, after) = (effects(before), effects(after));
        let v1 = styled(&base, 1, &before);
        assert_eq!(retained(&v1), 0, "{before}: nothing rendered yet");
        let _ = v1.flattened();
        assert_eq!(retained(&v1), 1, "{before}: one plane set");
        let v2 = styled(&v1, 1, &after);
        assert_eq!(
            retained(&v2),
            1,
            "{after}: inherited before any composite, and v1 keeps none"
        );
        assert_eq!(
            v2.flattened().into_raw(),
            fresh_render(&v2, &after),
            "{after}: re-stamped planes equal a full render"
        );
        assert_eq!(retained(&v2), 1);
    }

    // A geometry change on one of two effects: the entry is still handed
    // over (the pad is unchanged) with that effect alone re-rendered.
    let two = effects("{\"type\":\"drop_shadow\",\"size\":12},{\"type\":\"stroke\",\"size\":3}");
    let wider = effects("{\"type\":\"drop_shadow\",\"size\":12},{\"type\":\"stroke\",\"size\":5}");
    let v1 = styled(&base, 1, &two);
    let _ = v1.flattened();
    let v2 = styled(&v1, 1, &wider);
    assert_eq!(retained(&v2), 1, "handed over across a stroke width change");
    assert_eq!(v2.flattened().into_raw(), fresh_render(&v2, &wider));
    assert_eq!(retained(&v2), 1);

    // A pad change is another plane size: nothing to inherit, and still
    // nothing retained by the version replaced.
    let bigger = effects("{\"type\":\"drop_shadow\",\"size\":40},{\"type\":\"stroke\",\"size\":5}");
    let v3 = styled(&v2, 1, &bigger);
    assert_eq!(
        retained(&v3),
        0,
        "a pad change starts empty and v2 keeps none"
    );
    assert_eq!(v3.flattened().into_raw(), fresh_render(&v3, &bigger));
    assert_eq!(retained(&v3), 1);

    // Clearing keeps none either; and every superseded version — still
    // alive here, as on an undo stack — projects exactly when asked,
    // re-rendering once.
    let cleared = v3.set_layer_style(1, None).expect("clears");
    assert_eq!(retained(&cleared), 0);
    assert_eq!(v1.flattened().into_raw(), fresh_render(&v1, &two));
    assert_eq!(v2.flattened().into_raw(), fresh_render(&v2, &wider));
    assert_eq!(v3.flattened().into_raw(), fresh_render(&v3, &bigger));
}

#[test]
fn a_styled_layer_costs_about_the_plain_path() {
    let bg = RzDocument::from_pixels(RgbaImage::from_pixel(4096, 4096, Rgba(WHITE)));
    let plain = bg
        .adding_image_layer(0, solid(16, 16, RED), "Small")
        .unwrap()
        .with_layer_offset(1, 2000, 2000)
        .unwrap();
    let styled_doc = styled(&plain, 1, "{\"effects\":[{\"type\":\"drop_shadow\"}]}");
    let median = |doc: &RzDocument| -> Duration {
        let mut times: Vec<Duration> = (0..3)
            .map(|_| {
                let start = Instant::now();
                std::hint::black_box(doc.flattened());
                start.elapsed()
            })
            .collect();
        times.sort();
        times[1]
    };
    let unstyled = median(&plain);
    let with_style = median(&styled_doc);
    assert!(
        with_style <= unstyled * 2 + Duration::from_millis(20),
        "styled {with_style:?} vs unstyled {unstyled:?}: the plain styled path must allocate nothing canvas-sized"
    );
}

#[test]
fn an_identical_coverage_hit_adds_a_key_and_keeps_the_matched_entry() {
    // Duplicate Layer shares one Arc<LayerStyle> between two layers, and a
    // recolour of the copy gives it pixels of its own with the SAME
    // coverage. Every cache entry holds one Weak on the pixel Arc it is
    // keyed to, so a layer's weak count is its number of entries: after
    // one composite each layer must own an entry, and a second composite
    // must leave both in place — an identical-coverage match adds a key
    // over the shared planes rather than moving the one entry from layer
    // to layer on every flatten (each of which would rebuild both shapes
    // and compare both coverages).
    let json = "{\"effects\":[{\"type\":\"drop_shadow\",\"size\":4}]}";
    let dup = styled(&rect_doc(), 1, json).duplicating_layer(1).unwrap();
    let paint = overlay_rect(CANVAS.0, CANVAS.1, (12, 12, 3, 4), BLUE);
    let recoloured = painted(&dup, 2, &paint, COMPOSITE_OVER, 1.0);
    assert!(!Arc::ptr_eq(
        &recoloured.layers[1].pixels,
        &recoloured.layers[2].pixels
    ));
    let entries = |idx: usize| Arc::weak_count(&recoloured.layers[idx].pixels);
    assert_eq!((entries(1), entries(2)), (0, 0), "nothing rendered yet");
    let first = recoloured.flattened().into_raw();
    assert_eq!((entries(1), entries(2)), (1, 1), "one entry per layer");
    assert_eq!(recoloured.flattened().into_raw(), first);
    assert_eq!(
        (entries(1), entries(2)),
        (1, 1),
        "neither layer takes the other's entry"
    );
    let mut fresh = recoloured.clone();
    fresh.layers[1].style = Some(Arc::new(parse(json)));
    fresh.layers[2].style = Some(Arc::new(parse(json)));
    assert_eq!(
        fresh.flattened().into_raw(),
        first,
        "the shared planes are exact"
    );

    // When the bounds differ under an identical coverage (Layer > Mask >
    // Apply), the NEW entry takes the new bounds and the matched entry
    // keeps its own: a style inheriting both later renders a layer-aligned
    // gradient over each entry's shape, and the document that still holds
    // the old pixels (an undo snapshot) must project it across ITS box.
    // Oracle as in `a_refreshed_entry_carries_the_bounds_a_later_gradient_
    // spans`: grey round(255 (x + 0.5 - bx0) / (bx1 - bx0)) at column x.
    const W: u32 = 40;
    const H: u32 = 20;
    const SHADOW: &str = "{\"effects\":[{\"type\":\"drop_shadow\"}]}";
    const BOTH: &str = "{\"effects\":[{\"type\":\"drop_shadow\"},\
         {\"type\":\"gradient_overlay\",\"gradient\":{\"angle\":0,\"align_with_layer\":true}}]}";
    let grey = |x: u32, bx0: u32, bx1: u32| -> u8 {
        ((x as f32 + 0.5 - bx0 as f32) / (bx1 - bx0) as f32 * 255.0).round() as u8
    };
    let sel = selection(W, H, |x, _| u8::from(x < 10) * 255);
    let base = RzDocument::from_pixels(solid(W, H, WHITE))
        .adding_image_layer(0, solid(W, H, RED), "L")
        .unwrap();
    let v1 = styled(
        &base.add_mask(1, MaskKind::FromSelection(&sel)).unwrap(),
        1,
        SHADOW,
    );
    let _ = v1.flattened();
    let v2 = v1.remove_mask(1, true).unwrap();
    let _ = v2.flattened(); // identical coverage, box 0..40 -> 0..10
    assert_eq!(
        (
            Arc::weak_count(&v1.layers[1].pixels),
            Arc::weak_count(&v2.layers[1].pixels)
        ),
        (1, 1),
        "both keys live"
    );
    let v3 = styled(&v2, 1, BOTH);
    let got = v3.flattened().into_raw();
    let want = fresh_render(&v3, BOTH);
    assert_eq!(
        pixel(&want, W, 5, 0)[0],
        grey(5, 0, 10),
        "oracle: the new box"
    );
    assert_eq!(got, want, "the new entry spans the applied alpha");
    let mut back = v1.clone();
    back.layers[1].style = v3.layers[1].style.clone();
    let got = back.flattened().into_raw();
    let want = fresh_render(&back, BOTH);
    assert_eq!(
        pixel(&want, W, 5, 0)[0],
        grey(5, 0, 40),
        "oracle: the old box"
    );
    assert_eq!(got, want, "the matched entry kept its own bounds");
}

#[test]
fn a_style_edit_renders_nothing_however_many_entries_undo_keeps_alive() {
    // Three brush ticks, each followed by a composite, with every document
    // kept alive as an undo stack keeps them: the style's cache holds one
    // entry per pixel Arc, CACHE_CAPACITY of them. A Layer Style tick that
    // keeps the pad but moves the satin — a plane change, so the effect
    // must re-render — must not re-render it once per entry inside
    // set_layer_style: the entries are carried over as they are, and only
    // the one the next composite reads is adopted, then. Oracle: the
    // setter takes a fraction of ONE full render of the style however many
    // entries it carries (the old way cost one satin render per entry,
    // several renders' worth); every carried entry then projects exactly,
    // adopted on first read, and none is lost on the way.
    const W: u32 = 1000;
    const H: u32 = 700;
    let mut content = RgbaImage::from_pixel(W, H, Rgba([0, 0, 0, 0]));
    for y in 100..600 {
        for x in 150..850 {
            content.put_pixel(x, y, Rgba(RED));
        }
    }
    let base = RzDocument::from_pixels(solid(W, H, WHITE))
        .adding_image_layer(0, content, "Content")
        .unwrap();
    let satin = |angle: u32| format!("{{\"effects\":[{{\"type\":\"satin\",\"angle\":{angle}}}]}}");
    let retained = |doc: &RzDocument| Arc::weak_count(&doc.layers[1].pixels);
    let median = |mut times: Vec<Duration>| -> Duration {
        times.sort();
        times[times.len() / 2]
    };
    // One full render of the style: a fresh style, an empty cache.
    let render = median(
        (0..3)
            .map(|_| {
                let fresh = styled(&base, 1, &satin(19));
                let start = Instant::now();
                std::hint::black_box(fresh.flattened());
                start.elapsed()
            })
            .collect(),
    );
    // The undo stack: v1 rendered, then three ticks each rendered.
    let stack = || -> Vec<RzDocument> {
        let mut docs = vec![styled(&base, 1, &satin(19))];
        let _ = docs[0].flattened();
        for i in 0..3u32 {
            let tick = overlay_rect(W, H, (300 + 40 * i, 300, 20, 20), [0, 0, 0, 255]);
            let next = painted(docs.last().unwrap(), 1, &tick, COMPOSITE_ERASE, 1.0);
            let _ = next.flattened();
            docs.push(next);
        }
        assert!(docs.iter().all(|d| retained(d) == 1), "one entry per tick");
        docs
    };
    // Each stack is dropped before the next is built: the base pixels are
    // shared, and a live stack would be a second entry keyed to them.
    let edit = median(
        (0..3)
            .map(|_| {
                let docs = stack();
                let start = Instant::now();
                std::hint::black_box(styled(docs.last().unwrap(), 1, &satin(60)));
                start.elapsed()
            })
            .collect(),
    );
    assert!(
        edit * 4 <= render,
        "set_layer_style {edit:?} vs one full render {render:?}: the setter must render nothing"
    );
    let docs = stack();
    let edited = styled(docs.last().unwrap(), 1, &satin(60));
    assert!(
        docs.iter().all(|d| retained(d) == 1),
        "every entry carried over, none rendered"
    );
    assert_eq!(
        edited.flattened().into_raw(),
        fresh_render(&edited, &satin(60))
    );
    assert!(docs.iter().all(|d| retained(d) == 1), "adopted in place");
    // A document holding an older pixel Arc under the new style reads a
    // carried entry that was never adopted: adopted on that first read.
    let mut older = docs[1].clone();
    older.layers[1].style = edited.layers[1].style.clone();
    assert_eq!(
        older.flattened().into_raw(),
        fresh_render(&older, &satin(60))
    );
    assert_eq!(retained(&older), 1);
}

#[test]
fn an_entry_carried_through_an_uncomposited_version_is_adopted_from_its_own_stack() {
    // v1 renders; v2 replaces one effect's geometry and is never
    // composited; v3 replaces a colour. v3's entry still holds v1's planes,
    // so its adoption must compare against v1's effects (the stroke
    // re-rendered, the shadow re-stamped) — not v2's, whose planes never
    // existed. And a version whose ENABLED stack equals its predecessor's
    // (a fill-opacity edit) owns the planes outright.
    const W: u32 = 160;
    const H: u32 = 120;
    let mut content = RgbaImage::from_pixel(W, H, Rgba([0, 0, 0, 0]));
    for y in 30..90 {
        for x in 40..120 {
            content.put_pixel(x, y, Rgba(RED));
        }
    }
    let base = RzDocument::from_pixels(solid(W, H, WHITE))
        .adding_image_layer(0, content, "Content")
        .unwrap();
    let retained = |doc: &RzDocument| Arc::weak_count(&doc.layers[1].pixels);
    let one =
        "{\"effects\":[{\"type\":\"drop_shadow\",\"size\":12},{\"type\":\"stroke\",\"size\":3}]}";
    let two =
        "{\"effects\":[{\"type\":\"drop_shadow\",\"size\":12},{\"type\":\"stroke\",\"size\":5}]}";
    let three = "{\"effects\":[{\"type\":\"drop_shadow\",\"size\":12,\"color\":\"#336699\"},\
         {\"type\":\"stroke\",\"size\":5}]}";
    let four = "{\"fill_opacity\":0.5,\"effects\":[{\"type\":\"drop_shadow\",\"size\":12,\
         \"color\":\"#336699\"},{\"type\":\"stroke\",\"size\":5}]}";
    let v1 = styled(&base, 1, one);
    let _ = v1.flattened();
    let v2 = styled(&v1, 1, two);
    let v3 = styled(&v2, 1, three);
    assert_eq!(retained(&v3), 1, "carried twice, rendered by neither");
    assert_eq!(v3.flattened().into_raw(), fresh_render(&v3, three));
    assert_eq!(retained(&v3), 1);
    let v4 = styled(&v3, 1, four);
    assert_eq!(retained(&v4), 1);
    assert_eq!(v4.flattened().into_raw(), fresh_render(&v4, four));
    // The skipped version renders once when asked, from nothing.
    assert_eq!(v2.flattened().into_raw(), fresh_render(&v2, two));
}
