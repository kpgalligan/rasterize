//! Blend If (Blending Options) — the split-ramp weight through the
//! projection: the this-layer ramp on a gray ramp over white, the underlying
//! ramp on a solid layer over a ramp backdrop, channel selection on pure
//! colours (which isolates each luma coefficient), joined pairs as hard
//! edges, the two ramps multiplying, full-weight ramps being no style at
//! all, the layer's own drop shadow NOT counting as underlying, offset /
//! fill / opacity / transparency handling, and the canonical JSON echo.
//! Every expectation is the ramp table from the spec restated here in f64
//! and fed through the W3C reference composite — no core code, no golden
//! image. Black-box through the FFI setter (`common::styled`) and the safe
//! projection.

use image::{Rgba, RgbaImage};
use rasterize_core::doc::{BlendMode, RzDocument};
use rasterize_core::ffi_doc::rz_doc_free;
use rasterize_core::ffi_style::rz_doc_layer_has_style;
use std::ffi::c_int;

mod common;
use common::*;

// ---------------------------------------------------------------- oracle --

/// The spec's ramp table, written from the prose in f64: 0 below `lo0`, a
/// linear rise to `lo1`, 1 through `hi0`, a linear fall to `hi1`, 0 above.
/// A joined pair (`lo0 == lo1` / `hi0 == hi1`) is a step.
fn ramp(v: i64, r: [i64; 4]) -> f64 {
    let [lo0, lo1, hi0, hi1] = r;
    if v < lo0 {
        0.0
    } else if v < lo1 {
        (v - lo0) as f64 / (lo1 - lo0) as f64
    } else if v <= hi0 {
        1.0
    } else if v <= hi1 {
        (hi1 - v) as f64 / (hi1 - hi0) as f64
    } else {
        0.0
    }
}

/// The 8-bit value a channel reads from a pixel: gray is the Rec. 709
/// luminosity rounded to an integer, the others the channel itself.
fn channel_value(channel: &str, px: [u8; 4]) -> i64 {
    let (r, g, b) = (f64::from(px[0]), f64::from(px[1]), f64::from(px[2]));
    match channel {
        "gray" => (0.2126 * r + 0.7152 * g + 0.0722 * b).round() as i64,
        "red" => px[0].into(),
        "green" => px[1].into(),
        "blue" => px[2].into(),
        other => panic!("unknown channel {other}"),
    }
}

fn quantized(v: [f32; 4]) -> [u8; 4] {
    [
        (v[0] * 255.0).round() as u8,
        (v[1] * 255.0).round() as u8,
        (v[2] * 255.0).round() as u8,
        (v[3] * 255.0).round() as u8,
    ]
}

/// `src` over `bg` at weight `w` with `mode`, quantized like the projection.
fn expect(bg: [u8; 4], src: [u8; 4], w: f64, mode: c_int) -> [u8; 4] {
    quantized(ref_composite(to_unit(bg), to_unit(src), w as f32, mode))
}

fn px(flat: &RgbaImage, x: u32, y: u32) -> [u8; 4] {
    flat.get_pixel(x, y).0
}

fn assert_px_close(got: [u8; 4], want: [u8; 4], what: &str) {
    assert_close(&got, &want, what);
}

// -------------------------------------------------------------- fixtures --

/// One column per 8-bit value, so a ramp is checked at every input.
const W: u32 = 256;
const H: u32 = 4;

/// Opaque gray ramp: column `x` is the value `x` (R = G = B, so gray and
/// every channel agree and the luma of a column is exactly `x`).
fn gray_ramp(w: u32, h: u32) -> RgbaImage {
    RgbaImage::from_fn(w, h, |x, _| {
        let v = (x * 255 / (w - 1).max(1)) as u8;
        Rgba([v, v, v, 255])
    })
}

/// Canvas of `bg` under layer 1 = `layer` at offset 0.
fn over(bg: RgbaImage, layer: RgbaImage) -> RzDocument {
    RzDocument::from_pixels(bg)
        .adding_image_layer(0, layer, "Top")
        .expect("add layer")
}

fn blend_if(channel: &str, this: [i64; 4], under: [i64; 4]) -> String {
    format!(
        "{{\"blend_if\":{{\"channel\":\"{channel}\",\"this_layer\":{this:?},\
         \"underlying\":{under:?}}}}}"
    )
}

const FULL: [i64; 4] = [0, 0, 255, 255];
const SRC: [u8; 4] = [40, 200, 90, 255];

// ----------------------------------------------------------------- tests --

#[test]
fn this_layer_ramp_weights_the_layer_by_its_own_value() {
    let this = [0, 0, 100, 200];
    let doc = over(solid(W, H, WHITE), gray_ramp(W, H));
    let flat = styled(&doc, 1, &blend_if("gray", this, FULL)).flattened();
    let mut saw_partial = false;
    for x in 0..W {
        let src = px(&gray_ramp(W, H), x, 0);
        let w = ramp(i64::from(x), this);
        saw_partial |= w > 0.0 && w < 1.0;
        for y in 0..H {
            assert_px_close(
                px(&flat, x, y),
                expect(WHITE, src, w, BLEND_NORMAL),
                &format!("gray ramp over white, column {x}"),
            );
        }
    }
    assert!(saw_partial, "the ramp must cover its sloped row");

    // The weight scales the alpha the LAYER's blend mode sees: a Multiply
    // layer over a coloured backdrop multiplies at weight w(x).
    let bg = [200, 150, 100, 255];
    let doc = over(solid(W, H, bg), gray_ramp(W, H))
        .with_layer_blend_mode(1, BlendMode::Multiply)
        .expect("blend");
    let flat = styled(&doc, 1, &blend_if("gray", this, FULL)).flattened();
    for x in 0..W {
        let src = px(&gray_ramp(W, H), x, 0);
        let w = ramp(i64::from(x), this);
        let want = expect(bg, src, w, BLEND_MULTIPLY);
        assert_px_close(px(&flat, x, 1), want, &format!("multiply column {x}"));
        // At value 100 (weight 1) the two modes are 20+ levels apart; at
        // black they coincide, which is why the check is not per column.
        if x == 100 {
            assert_ne!(
                want,
                expect(bg, src, w, BLEND_NORMAL),
                "the fixture distinguishes Multiply from Normal"
            );
        }
    }
}

#[test]
fn underlying_ramp_reads_the_composite_beneath() {
    let under = [50, 100, 255, 255];
    let doc = over(gray_ramp(W, H), solid(W, H, SRC));
    let flat = styled(&doc, 1, &blend_if("gray", FULL, under)).flattened();
    for x in 0..W {
        let bg = px(&gray_ramp(W, H), x, 0);
        let w = ramp(i64::from(x), under);
        for y in 0..H {
            assert_px_close(
                px(&flat, x, y),
                expect(bg, SRC, w, BLEND_NORMAL),
                &format!("solid over ramp backdrop, column {x}"),
            );
        }
    }
    // Sanity on the shape: hidden below 50, fully shown from 100 up.
    assert_eq!(px(&flat, 20, 0), px(&gray_ramp(W, H), 20, 0));
    assert_eq!(px(&flat, 200, 0), SRC);
}

#[test]
fn channels_select_red_green_blue_or_the_luminosity() {
    // Pure colours isolate one luma coefficient each; white, black and a
    // mid gray pin the ends and the middle. Every luma lands far from a
    // rounding boundary (54.2, 182.4, 18.4), so the f64 oracle and the
    // core's f32 agree on the integer.
    let columns: [[u8; 4]; 6] = [
        [255, 0, 0, 255],
        [0, 255, 0, 255],
        [0, 0, 255, 255],
        WHITE,
        [0, 0, 0, 255],
        [128, 128, 128, 255],
    ];
    let layer = RgbaImage::from_fn(6, H, |x, _| Rgba(columns[x as usize]));
    let this = [0, 0, 100, 200];
    for channel in ["gray", "red", "green", "blue"] {
        let doc = over(solid(6, H, WHITE), layer.clone());
        let flat = styled(&doc, 1, &blend_if(channel, this, FULL)).flattened();
        for (x, &src) in columns.iter().enumerate() {
            let w = ramp(channel_value(channel, src), this);
            assert_px_close(
                px(&flat, x as u32, 0),
                expect(WHITE, src, w, BLEND_NORMAL),
                &format!("channel {channel}, column {x}"),
            );
        }
    }
    // The fixture tells the channels apart: pure green is nearly hidden on
    // gray (luma 182 → 0.18) yet fully shown on red (R = 0 → 1).
    let gray = styled(
        &over(solid(6, H, WHITE), layer.clone()),
        1,
        &blend_if("gray", this, FULL),
    )
    .flattened();
    let red = styled(
        &over(solid(6, H, WHITE), layer),
        1,
        &blend_if("red", this, FULL),
    )
    .flattened();
    assert_ne!(px(&gray, 1, 0), px(&red, 1, 0));
    assert_eq!(px(&red, 1, 0), columns[1]);
}

#[test]
fn joined_pairs_are_hard_edges() {
    let ramp_img = gray_ramp(W, H);
    // High pair joined at 100: every column up to 100 is the source, byte
    // for byte; every column above is untouched white.
    let doc = over(solid(W, H, WHITE), ramp_img.clone());
    let flat = styled(&doc, 1, &blend_if("gray", [0, 0, 100, 100], FULL)).flattened();
    for x in 0..W {
        let want = if x <= 100 { px(&ramp_img, x, 0) } else { WHITE };
        assert_eq!(px(&flat, x, 2), want, "high step, column {x}");
    }
    // Low pair joined at 100: hidden below, shown from 100 up.
    let doc = over(solid(W, H, WHITE), ramp_img.clone());
    let flat = styled(&doc, 1, &blend_if("gray", [100, 100, 255, 255], FULL)).flattened();
    for x in 0..W {
        let want = if x >= 100 { px(&ramp_img, x, 0) } else { WHITE };
        assert_eq!(px(&flat, x, 2), want, "low step, column {x}");
    }
    // The same steps on the underlying ramp, read from the backdrop.
    let doc = over(ramp_img.clone(), solid(W, H, SRC));
    let flat = styled(&doc, 1, &blend_if("gray", FULL, [0, 0, 100, 100])).flattened();
    for x in 0..W {
        let want = if x <= 100 { SRC } else { px(&ramp_img, x, 0) };
        assert_eq!(px(&flat, x, 2), want, "underlying high step, column {x}");
    }
}

#[test]
fn the_two_ramps_multiply() {
    // Column x carries the layer value x; row y carries a backdrop value
    // chosen to land on every row of the underlying ramp's table.
    let rows: [u8; 8] = [0, 40, 80, 120, 160, 200, 240, 255];
    let this = [20, 60, 150, 230];
    let under = [30, 90, 180, 250];
    let bg = RgbaImage::from_fn(W, 8, |_, y| {
        let v = rows[y as usize];
        Rgba([v, v, v, 255])
    });
    let layer = gray_ramp(W, 8);
    let doc = over(bg.clone(), layer.clone());
    let flat = styled(&doc, 1, &blend_if("gray", this, under)).flattened();
    let mut both_partial = 0;
    for y in 0..8 {
        let u = ramp(i64::from(rows[y as usize]), under);
        for x in 0..W {
            let t = ramp(i64::from(x), this);
            if t > 0.0 && t < 1.0 && u > 0.0 && u < 1.0 {
                both_partial += 1;
            }
            assert_px_close(
                px(&flat, x, y),
                expect(px(&bg, x, y), px(&layer, x, y), t * u, BLEND_NORMAL),
                &format!("product weight at ({x},{y})"),
            );
        }
    }
    assert!(both_partial > 0, "some pixels sit on both slopes");
}

#[test]
fn full_weight_ramps_are_no_style_at_all() {
    let doc = over(solid(W, H, WHITE), gray_ramp(W, H));
    // Identity: the core refuses to store it (no message) and reports no
    // style — the channel is moot when both ramps weight everything 1.
    for channel in ["gray", "red"] {
        let outcome = match try_styled(&doc, 1, Some(&blend_if(channel, FULL, FULL))) {
            Ok(None) => "refused",
            Ok(Some(_)) => "stored",
            Err(_) => "error",
        };
        assert_eq!(
            outcome, "refused",
            "a full-weight blend-if on {channel} is an identity"
        );
    }
    let handle = Box::into_raw(Box::new(doc.clone()));
    assert!(!unsafe { rz_doc_layer_has_style(handle, 1) });
    unsafe { rz_doc_free(handle) };

    // Beside a real knob it is stored but changes nothing: fill 0.5 with a
    // full blend-if renders byte-identically to fill 0.5 alone.
    let plain = styled(&doc, 1, "{\"fill_opacity\":0.5}").flattened();
    let with = styled(
        &doc,
        1,
        &format!(
            "{{\"fill_opacity\":0.5,\"blend_if\":{{\"channel\":\"blue\",\"this_layer\":{FULL:?},\
             \"underlying\":{FULL:?}}}}}"
        ),
    )
    .flattened();
    assert_eq!(plain.as_raw(), with.as_raw(), "full ramps beside fill 0.5");

    // A ramp that is not full but weights every pixel of THIS fixture 1
    // (the white backdrop reads 255, above the low pair) still goes
    // through the styled loop and comes out byte-identical to no style.
    let unstyled = doc.flattened();
    let weighted = styled(&doc, 1, &blend_if("gray", FULL, [0, 10, 255, 255])).flattened();
    assert_eq!(
        unstyled.as_raw(),
        weighted.as_raw(),
        "weight 1 everywhere is the plain path's bytes"
    );
}

#[test]
fn the_layers_own_shadow_is_not_underlying() {
    // A hard black Multiply shadow at distance 0 with knock-out OFF paints
    // the whole rect black beneath the pixels. Underlying must still be the
    // gray ramp the snapshot saw before the shadow: if the shadow counted,
    // every column would read 0 and be fully shown.
    let under = [0, 0, 100, 200];
    let json = format!(
        "{{\"blend_if\":{{\"channel\":\"gray\",\"this_layer\":{FULL:?},\"underlying\":{under:?}}},\
         \"effects\":[{{\"type\":\"drop_shadow\",\"use_global_light\":false,\"distance\":0,\
         \"size\":0,\"spread\":0,\"opacity\":1,\"blend\":\"multiply\",\"color\":\"#000000\",\
         \"layer_knocks_out\":false}}]}}"
    );
    let ramp_img = gray_ramp(W, H);
    let doc = over(ramp_img.clone(), solid(W, H, SRC));
    let flat = styled(&doc, 1, &json).flattened();
    let black = [0, 0, 0, 255];
    let mut distinguished = false;
    for x in 0..W {
        let bg = px(&ramp_img, x, 0);
        let shadowed = expect(bg, black, 1.0, BLEND_MULTIPLY);
        assert_eq!(shadowed, black, "black multiplied over anything is black");
        let w = ramp(i64::from(x), under);
        let want = expect(shadowed, SRC, w, BLEND_NORMAL);
        let wrong = expect(shadowed, SRC, ramp(0, under), BLEND_NORMAL);
        distinguished |= want != wrong;
        for y in 0..H {
            assert_px_close(px(&flat, x, y), want, &format!("shadowed column {x}"));
        }
    }
    assert!(distinguished, "the fixture tells the two backdrops apart");
    // Where the weight is 0 the shadow shows through — black, not the ramp.
    assert_eq!(px(&flat, 250, 0), black);
}

#[test]
fn underlying_is_the_pre_shadow_composite_wherever_the_shadow_lands_or_not() {
    // The backdrop snapshot covers only where a Below contribution can land
    // inside the layer rect; everywhere else the accumulator itself is
    // still the underlying composite when the pixels read it. A hard black
    // Normal shadow shifted 128 px right (knock-out off) lands under the
    // right half of the 256-wide layer only: both halves must weight by
    // the pre-shadow ramp — the snapshotted half and the live half alike —
    // while the shadow itself shows through where the weight is 0 (a ramp
    // with a zero foot on both sides, so each half has such a column).
    let under = [40, 80, 160, 220];
    let json = format!(
        "{{\"blend_if\":{{\"channel\":\"gray\",\"this_layer\":{FULL:?},\"underlying\":{under:?}}},\
         \"effects\":[{{\"type\":\"drop_shadow\",\"use_global_light\":false,\"angle\":180,\
         \"distance\":128,\"size\":0,\"spread\":0,\"opacity\":1,\"blend\":\"normal\",\
         \"color\":\"#000000\",\"layer_knocks_out\":false}}]}}"
    );
    let ramp_img = gray_ramp(W, H);
    let doc = over(ramp_img.clone(), solid(W, H, SRC));
    let flat = styled(&doc, 1, &json).flattened();
    let black = [0, 0, 0, 255];
    let mut distinguished = false;
    for x in 0..W {
        let bg = px(&ramp_img, x, 0);
        let w = ramp(i64::from(x), under);
        let shadowed = x >= 128;
        let beneath = if shadowed { black } else { bg };
        let want = expect(beneath, SRC, w, BLEND_NORMAL);
        let wrong = expect(
            beneath,
            SRC,
            ramp(channel_value("gray", beneath), under),
            BLEND_NORMAL,
        );
        distinguished |= shadowed && want != wrong;
        for y in 0..H {
            assert_px_close(px(&flat, x, y), want, &format!("column {x}"));
        }
    }
    assert!(distinguished, "the fixture tells the two backdrops apart");
    assert_eq!(px(&flat, 250, 0), black, "weight 0 over the shadow");
    assert_eq!(
        px(&flat, 20, 0),
        px(&ramp_img, 20, 0),
        "weight 0 over the bare ramp"
    );
}

#[test]
fn offset_fill_opacity_and_transparency_follow_the_plain_rules() {
    // Layer 256x4 at (-100, 2) on a 200x8 canvas: canvas column cx shows
    // layer column cx + 100 for cx < 156; the backdrop ramp is read at cx.
    let (cw, ch) = (200u32, 8u32);
    let this = [0, 0, 100, 200];
    let under = [50, 100, 255, 255];
    let bg = gray_ramp(cw, ch);
    let layer = gray_ramp(W, H);
    let doc = RzDocument::from_pixels(bg.clone())
        .adding_image_layer(0, layer.clone(), "Top")
        .expect("add layer")
        .with_layer_offset(1, -100, 2)
        .expect("offset")
        .with_layer_opacity(1, 0.8)
        .expect("opacity");
    let json = format!(
        "{{\"fill_opacity\":0.5,\"blend_if\":{{\"channel\":\"gray\",\"this_layer\":{this:?},\
         \"underlying\":{under:?}}}}}"
    );
    let flat = styled(&doc, 1, &json).flattened();
    for cy in 0..ch {
        for cx in 0..cw {
            let inside = (2..6).contains(&cy) && cx < 156;
            let want = if inside {
                let src = px(&layer, cx + 100, cy - 2);
                let beneath = channel_value("gray", px(&bg, cx, cy));
                let w = ramp(i64::from(cx + 100), this) * ramp(beneath, under);
                // fill 0.5 and layer opacity 0.8 multiply into the weight.
                expect(px(&bg, cx, cy), src, w * 0.5 * 0.8, BLEND_NORMAL)
            } else {
                px(&bg, cx, cy)
            };
            assert_px_close(
                px(&flat, cx, cy),
                want,
                &format!("offset layer at ({cx},{cy})"),
            );
        }
    }

    // A fully transparent layer renders nothing, ramps or not.
    let clear = over(bg.clone(), solid(cw, ch, [255, 0, 0, 0]));
    let flat = styled(
        &clear,
        1,
        &blend_if("red", [0, 0, 255, 255], [0, 0, 254, 255]),
    )
    .flattened();
    assert_eq!(flat.as_raw(), bg.as_raw());

    // Purity: the input document never changed.
    assert!(doc.layers[1].style.is_none());
    assert_eq!(doc.flattened().as_raw(), doc.clone().flattened().as_raw());
}

#[test]
fn underlying_reads_the_stored_colour_and_transparent_black() {
    // Nothing beneath: the accumulator's cleared value is transparent black,
    // which the underlying ramp reads as 0.
    let none = over(solid(W, H, [0, 0, 0, 0]), solid(W, H, SRC));
    let hidden = styled(&none, 1, &blend_if("gray", FULL, [50, 100, 255, 255])).flattened();
    assert!(
        hidden.as_raw().iter().all(|&b| b == 0),
        "weight 0 over nothing"
    );
    let shown = styled(&none, 1, &blend_if("gray", FULL, [0, 0, 100, 200])).flattened();
    assert!(shown.pixels().all(|p| p.0 == SRC), "weight 1 over nothing");

    // Half-covered: the straight colour is what the ramp sees, alpha aside.
    let half = [200, 100, 50, 128];
    let doc = over(solid(W, H, half), solid(W, H, SRC));
    let shown = styled(&doc, 1, &blend_if("red", FULL, [150, 150, 255, 255])).flattened();
    assert!(
        shown.pixels().all(|p| p.0 == SRC),
        "R = 200 clears a 150 step"
    );
    let hidden = styled(&doc, 1, &blend_if("red", FULL, [0, 0, 100, 100])).flattened();
    assert_eq!(
        hidden.as_raw(),
        solid(W, H, half).as_raw(),
        "R = 200 fails a 100 cap: only the half-covered backdrop remains"
    );
}

#[test]
fn the_canonical_json_echoes_the_ramps() {
    let doc = over(solid(W, H, WHITE), gray_ramp(W, H));
    let styled_doc = styled(&doc, 1, &blend_if("red", [0, 0, 100, 200], FULL));
    let handle = Box::into_raw(Box::new(styled_doc));
    let json = ffi_style(handle, 1).expect("a stored style");
    assert!(unsafe { rz_doc_layer_has_style(handle, 1) });
    unsafe { rz_doc_free(handle) };
    assert!(
        json.contains(
            "\"blend_if\":{\"channel\":\"red\",\"this_layer\":[0,0,100,200],\
             \"underlying\":[0,0,255,255]}"
        ),
        "canonical form: {json}"
    );
}
