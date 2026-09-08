//! `gradient_map` through the C ABI: the luma read as a position along a
//! multi-stop gradient, its stop opacities, `reverse`, and the dither that
//! keeps an 8-bit map from banding.
//!
//! The oracle is the gradient's own definition (linear between the two
//! bracketing stops), written here; the black-to-white default is checked
//! against a genuinely independent implementation — the `grayscale` op,
//! which computes the same Rec. 709 luma by a different route.

use std::ffi::{c_char, CString};
use std::ptr;

use image::{Rgba, RgbaImage};
use rasterize_core::ffi::*;
use rasterize_core::ffi_adjust::*;
use rasterize_core::ffi_doc::*;
use rasterize_core::RzImage;
use tempfile::TempDir;

mod common;
use common::*;

// ------------------------------------------------------------- plumbing --

fn adjust(img: *const RzImage, op: &str, params: &str) -> *mut RzImage {
    let c_op = CString::new(op).unwrap();
    let c_params = CString::new(params).unwrap();
    let mut err: *mut c_char = ptr::null_mut();
    let out = unsafe { rz_image_adjust_op(img, c_op.as_ptr(), c_params.as_ptr(), &mut err) };
    assert!(
        !out.is_null(),
        "rz_image_adjust_op({op}, {params}) failed: {}",
        take_err_string(err)
    );
    assert!(err.is_null(), "err_out set on success");
    out
}

fn run(dir: &TempDir, tag: &str, src: &RgbaImage, params: &str) -> Vec<[u8; 3]> {
    let img = open_pattern(dir, &format!("{tag}.png"), src);
    let out = adjust(img, "gradient_map", params);
    let bytes = pixels(out);
    let alpha: Vec<u8> = bytes.iter().skip(3).step_by(4).copied().collect();
    let expected: Vec<u8> = src.pixels().map(|p| p[3]).collect();
    assert_eq!(alpha, expected, "{tag}: alpha must never be touched");
    unsafe { rz_image_free(out) };
    free(img);
    bytes.chunks_exact(4).map(|p| [p[0], p[1], p[2]]).collect()
}

fn refuses(dir: &TempDir, tag: &str, params: &str) {
    let img = open_pattern(dir, &format!("{tag}.png"), &opaque_pattern(4, 4));
    let c_op = CString::new("gradient_map").unwrap();
    let c_params = CString::new(params).unwrap();
    let mut err: *mut c_char = ptr::null_mut();
    let out = unsafe { rz_image_adjust_op(img, c_op.as_ptr(), c_params.as_ptr(), &mut err) };
    assert!(out.is_null(), "gradient_map {params} must be refused");
    assert!(
        take_err_string(err).contains("gradient_map"),
        "gradient_map {params}: the message must name the op"
    );
    free(img);
}

fn norm(c: [u8; 3]) -> [f64; 3] {
    c.map(|v| f64::from(v) / 255.0)
}

fn luma(rgb: [f64; 3]) -> f64 {
    0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2]
}

/// The gradient's colour and opacity at `t`: linear between the bracketing
/// stops, clamped to the ends.
fn sample(stops: &[(f64, [f64; 3], f64)], t: f64) -> ([f64; 3], f64) {
    let first = stops[0];
    let last = stops[stops.len() - 1];
    if t <= first.0 {
        return (first.1, first.2);
    }
    if t >= last.0 {
        return (last.1, last.2);
    }
    for pair in stops.windows(2) {
        let (a, b) = (pair[0], pair[1]);
        if t >= a.0 && t < b.0 {
            let f = if b.0 > a.0 {
                (t - a.0) / (b.0 - a.0)
            } else {
                1.0
            };
            return (
                std::array::from_fn(|c| a.1[c] + (b.1[c] - a.1[c]) * f),
                a.2 + (b.2 - a.2) * f,
            );
        }
    }
    (last.1, last.2)
}

fn map_oracle(rgb: [f64; 3], stops: &[(f64, [f64; 3], f64)], reverse: bool) -> [f64; 3] {
    let mut t = luma(rgb).clamp(0.0, 1.0);
    if reverse {
        t = 1.0 - t;
    }
    let (mapped, opacity) = sample(stops, t);
    std::array::from_fn(|c| rgb[c] + (mapped[c] - rgb[c]) * opacity)
}

fn assert_bytes(got: [u8; 3], want: [f64; 3], what: &str) {
    for (c, (g, w)) in got.iter().zip(want).enumerate() {
        let want_byte = (w.clamp(0.0, 1.0) * 255.0).round();
        assert!(
            (f64::from(*g) - want_byte).abs() <= 1.0,
            "{what} channel {c}: {g} vs {want_byte}"
        );
    }
}

// ----------------------------------------------------------------- tests --

/// The default gradient is black to white, so the map IS the pixel's luma
/// as a grey — which the `grayscale` op computes independently. Two
/// implementations of the same number agreeing is worth more than either
/// agreeing with a table.
#[test]
fn the_default_gradient_maps_luma_to_grey() {
    let dir = TempDir::new().unwrap();
    let src = opaque_pattern(16, 16);
    let out = run(&dir, "gm-default", &src, "{\"dither\":false}");
    let img = open_pattern(&dir, "gm-grey.png", &src);
    let grey = unsafe { rz_image_grayscale(img) };
    let bytes = pixels(grey);
    for (i, got) in out.iter().enumerate() {
        assert_eq!(
            *got,
            [bytes[i * 4], bytes[i * 4 + 1], bytes[i * 4 + 2]],
            "pixel {i}: a black-to-white map is the grayscale op"
        );
    }
    unsafe { rz_image_free(grey) };
    free(img);
    // Spelling the default gradient out explicitly changes nothing.
    let explicit = run(
        &dir,
        "gm-explicit",
        &src,
        "{\"dither\":false,\"gradient\":{\"stops\":[\
            {\"position\":0,\"color\":\"#000000\"},\
            {\"position\":1,\"color\":\"#ffffff\"}]}}",
    );
    assert_eq!(explicit, out);
}

#[test]
fn a_two_stop_ramp_lands_on_the_midpoint_and_reverses() {
    let dir = TempDir::new().unwrap();
    // Rec. 709 luma 0.5 exactly, so the map lands on the ramp's midpoint.
    let half = [128u8, 128, 128];
    let src = RgbaImage::from_fn(3, 1, |x, _| match x {
        0 => Rgba([0, 0, 0, 255]),
        1 => Rgba([half[0], half[1], half[2], 255]),
        _ => Rgba([255, 255, 255, 255]),
    });
    let ramp = "{\"dither\":false,\"gradient\":{\"stops\":[\
        {\"position\":0,\"color\":\"#ff0000\"},\
        {\"position\":1,\"color\":\"#0000ff\"}]}}";
    let stops = [(0.0, [1.0, 0.0, 0.0], 1.0), (1.0, [0.0, 0.0, 1.0], 1.0)];

    let out = run(&dir, "gm-ramp", &src, ramp);
    assert_eq!(out[0], [255, 0, 0], "black takes the first stop");
    assert_eq!(out[2], [0, 0, 255], "white takes the last");
    let mid_t = luma(norm(half));
    assert!(
        (mid_t - 0.501961).abs() < 1e-6,
        "mid grey's luma is {mid_t}"
    );
    assert_bytes(out[1], map_oracle(norm(half), &stops, false), "midpoint");
    assert!(
        out[1][0] > 120 && out[1][0] < 135 && out[1][2] > 120 && out[1][2] < 135,
        "the middle is halfway along the ramp: {:?}",
        out[1]
    );

    // `reverse` lives on the gradient object and the map applies it itself.
    let reversed = run(
        &dir,
        "gm-rev",
        &src,
        &ramp.replace("\"stops\"", "\"reverse\":true,\"stops\""),
    );
    assert_eq!(
        reversed[0],
        [0, 0, 255],
        "reversed, black takes the last stop"
    );
    assert_eq!(reversed[2], [255, 0, 0]);
    for (px, got) in src.pixels().zip(&reversed) {
        assert_bytes(
            *got,
            map_oracle(norm([px[0], px[1], px[2]]), &stops, true),
            "reverse",
        );
    }
}

/// A stop's opacity blends between the ORIGINAL pixel and the mapped
/// colour — the only meaning available to an op that may not touch alpha.
#[test]
fn a_stop_opacity_blends_with_the_original_pixel() {
    let dir = TempDir::new().unwrap();
    let src = opaque_pattern(16, 16);
    let params = "{\"dither\":false,\"gradient\":{\"stops\":[\
        {\"position\":0,\"color\":\"#00ff00\",\"opacity\":0.5},\
        {\"position\":1,\"color\":\"#00ff00\",\"opacity\":0.5}]}}";
    let stops = [(0.0, [0.0, 1.0, 0.0], 0.5), (1.0, [0.0, 1.0, 0.0], 0.5)];
    let out = run(&dir, "gm-opacity", &src, params);
    for (px, got) in src.pixels().zip(&out) {
        let rgb = norm([px[0], px[1], px[2]]);
        assert_bytes(*got, map_oracle(rgb, &stops, false), "half-opacity stops");
        // Halfway between the pixel and pure green, by construction.
        for c in 0..3 {
            let midpoint = (rgb[c] + [0.0, 1.0, 0.0][c]) / 2.0 * 255.0;
            assert!((f64::from(got[c]) - midpoint).abs() <= 1.0);
        }
    }
    // Opacity 0 anywhere on the gradient is a no-op there.
    let transparent = run(
        &dir,
        "gm-none",
        &src,
        "{\"dither\":false,\"gradient\":{\"stops\":[\
            {\"position\":0,\"color\":\"#ff00ff\",\"opacity\":0},\
            {\"position\":1,\"color\":\"#ff00ff\",\"opacity\":0}]}}",
    );
    for (px, got) in src.pixels().zip(&transparent) {
        assert_eq!(
            *got,
            [px[0], px[1], px[2]],
            "a fully transparent map is a no-op"
        );
    }
}

/// A multi-stop gradient is read stop by stop, and the whole 8-bit ramp
/// must follow the oracle.
#[test]
fn a_multi_stop_gradient_follows_the_oracle_over_the_whole_ramp() {
    let dir = TempDir::new().unwrap();
    let ramp = RgbaImage::from_fn(256, 1, |x, _| {
        let v = x as u8;
        Rgba([v, v, v, 255])
    });
    let params = "{\"dither\":false,\"gradient\":{\"stops\":[\
        {\"position\":0,\"color\":\"#101040\"},\
        {\"position\":0.25,\"color\":\"#c04020\",\"opacity\":0.8},\
        {\"position\":0.6,\"color\":\"#f0d060\"},\
        {\"position\":1,\"color\":\"#ffffff\"}]}}";
    let stops = [
        (0.0, [0x10, 0x10, 0x40], 1.0),
        (0.25, [0xc0, 0x40, 0x20], 0.8),
        (0.6, [0xf0, 0xd0, 0x60], 1.0),
        (1.0, [0xff, 0xff, 0xff], 1.0),
    ]
    .map(|(p, c, o)| {
        (
            p,
            [
                c[0] as f64 / 255.0,
                c[1] as f64 / 255.0,
                c[2] as f64 / 255.0,
            ],
            o,
        )
    });
    let out = run(&dir, "gm-multi", &ramp, params);
    for (v, got) in out.iter().enumerate() {
        let rgb = norm([v as u8; 3]);
        assert_bytes(*got, map_oracle(rgb, &stops, false), &format!("level {v}"));
    }
}

/// Dither is what stops an 8-bit map banding over a smooth sky: it must be
/// a jitter of at most one code, keyed on position, that averages to the
/// undithered answer — never a visible change to the picture.
#[test]
fn dither_moves_no_channel_by_more_than_one_and_averages_out() {
    let dir = TempDir::new().unwrap();
    // A flat patch: every pixel has the same luma, so the undithered map
    // gives one colour and the dithered one spreads about it.
    let flat = RgbaImage::from_pixel(64, 64, Rgba([90, 110, 130, 255]));
    let params = "{\"gradient\":{\"stops\":[\
        {\"position\":0,\"color\":\"#000000\"},\
        {\"position\":1,\"color\":\"#ffffff\"}]}}";
    let plain = run(
        &dir,
        "gm-plain",
        &flat,
        &format!("{{\"dither\":false,{}", &params[1..]),
    );
    let dithered = run(&dir, "gm-dither", &flat, params);

    let reference = plain[0];
    assert!(
        plain.iter().all(|p| *p == reference),
        "the undithered map of a flat patch is one colour"
    );
    let mut moved = 0usize;
    let mut sum = 0.0f64;
    for got in &dithered {
        for c in 0..3 {
            let delta = i32::from(got[c]) - i32::from(reference[c]);
            assert!(delta.abs() <= 1, "dither moved a channel by {delta}");
        }
        if got[0] != reference[0] {
            moved += 1;
        }
        sum += f64::from(got[0]);
    }
    assert!(moved > 0, "dither must actually do something");
    let mean = sum / dithered.len() as f64;
    assert!(
        (mean - f64::from(reference[0])).abs() < 0.2,
        "the dithered mean {mean} must sit on the undithered value {}",
        reference[0]
    );
    // Deterministic: the same pixels, the same offsets, every time.
    let again = run(&dir, "gm-dither2", &flat, params);
    assert_eq!(dithered, again, "the dither is a pure function of position");
    // And on by default: an empty params object is the default gradient
    // (black to white, the one spelled out above) WITH dither.
    assert_eq!(
        run(&dir, "gm-dither3", &flat, "{}"),
        dithered,
        "dither defaults to true"
    );
}

/// The third stated exception to "the filter and the layer land on the
/// identical bytes" (`adjust`'s module doc, the README, the catalog): the
/// dither is keyed on the position `apply_at` is handed, and the two paths
/// count that position in different frames — the layer from the CANVAS, the
/// filter from the image it was given. On a layer at offset (0, 0) those are
/// the same frame; on a layer at any other offset the jitter falls on
/// different pixels. `dither: false` removes the difference at any offset.
///
/// Both halves are asserted here so the documented exception is a tested
/// fact rather than a claim, and so a future change that makes the two
/// converge fails loudly instead of silently invalidating three doc blocks.
#[test]
fn gradient_map_dither_is_keyed_on_the_position_it_is_given() {
    let dir = TempDir::new().unwrap();
    // A canvas roomy enough to hold the content layer at a NON-ZERO offset.
    let canvas = solid(48, 40, [0, 0, 0, 255]);
    // Smoothly varying content, so the map is not flat and the dither has
    // somewhere to bite.
    let content = RgbaImage::from_fn(32, 24, |x, y| {
        Rgba([(x * 7) as u8, (y * 9) as u8, ((x + y) * 5) as u8, 255])
    });
    const OFFSET: (i32, i32) = (7, 3);

    for (dither, must_match) in [(false, true), (true, false)] {
        let params = format!("{{\"dither\":{dither}}}");
        // The layer path: content at OFFSET, an adjustment layer above it.
        let mut doc = doc_from(&dir, &format!("gm-off-bg-{dither}.png"), &canvas);
        doc = add_layer(
            &dir,
            &format!("gm-off-content-{dither}.png"),
            doc,
            0,
            &content,
            "content",
        );
        doc = apply(doc, |d| unsafe {
            rz_doc_with_layer_offset(d, 1, OFFSET.0, OFFSET.1)
        });
        assert_eq!(layer_offset(doc, 1), OFFSET);
        doc = add_layer(
            &dir,
            &format!("gm-off-adj-{dither}.png"),
            doc,
            1,
            &solid(2, 2, MAGENTA),
            "map",
        );
        doc = set_meta(doc, 2, &adjust_meta("gradient_map", &params));
        let flat = flat_pixels(doc);
        unsafe { rz_doc_free(doc) };

        // The filter path: the same op on the layer's own image.
        let filtered = run(&dir, &format!("gm-off-filter-{dither}"), &content, &params);

        let mut differing = 0usize;
        for (i, want) in filtered.iter().enumerate() {
            let (lx, ly) = (i as u32 % 32, i as u32 / 32);
            let got = pixel(&flat, 48, lx + OFFSET.0 as u32, ly + OFFSET.1 as u32);
            for c in 0..3 {
                let delta = i32::from(got[c]) - i32::from(want[c]);
                assert!(
                    delta.abs() <= 1,
                    "dither {dither}: the two paths may never differ by more than the \
                     one code the dither itself is worth (pixel {lx},{ly} channel {c}: \
                     {} vs {})",
                    got[c],
                    want[c]
                );
            }
            if got[..3] != want[..] {
                differing += 1;
            }
        }
        if must_match {
            assert_eq!(
                differing, 0,
                "dither false: the filter and the layer must be byte-identical at any offset"
            );
        } else {
            // The finding measured "roughly half"; assert only that the
            // divergence is real and substantial, so the number is not a
            // second implementation of the dither.
            assert!(
                differing > filtered.len() / 8,
                "dither true at offset {OFFSET:?}: the documented divergence must be real \
                 ({differing} of {} pixels differ)",
                filtered.len()
            );
        }
    }
}

#[test]
fn gradient_map_refuses_a_malformed_gradient() {
    let dir = TempDir::new().unwrap();
    let many = (0..33)
        .map(|i| {
            format!(
                "{{\"position\":{},\"color\":\"#000000\"}}",
                f64::from(i) / 32.0
            )
        })
        .collect::<Vec<_>>()
        .join(",");
    for params in [
        "{\"gradient\":7}".to_string(),
        "{\"gradient\":{\"stops\":[]}}".to_string(),
        "{\"gradient\":{\"stops\":[{\"position\":0,\"color\":\"#000000\"}]}}".to_string(),
        format!("{{\"gradient\":{{\"stops\":[{many}]}}}}"),
        "{\"gradient\":{\"stops\":[{\"position\":0,\"color\":\"black\"},\
          {\"position\":1,\"color\":\"#ffffff\"}]}}"
            .to_string(),
        "{\"gradient\":{\"stops\":\"rainbow\"}}".to_string(),
        "{\"dither\":\"on\"}".to_string(),
    ] {
        refuses(&dir, "gm-bad", &params);
    }
    // The keys a map does not use are still ACCEPTED, so one editor and one
    // JSON shape serve both a layer style and an adjustment.
    let src = opaque_pattern(4, 4);
    let ignored = run(
        &dir,
        "gm-ignored",
        &src,
        "{\"dither\":false,\"gradient\":{\"style\":\"radial\",\"angle\":33,\
          \"scale\":1.4,\"align_with_layer\":false}}",
    );
    assert_eq!(
        ignored,
        run(&dir, "gm-ignored-ref", &src, "{\"dither\":false}"),
        "style, angle, scale and align_with_layer are accepted and ignored"
    );
}
