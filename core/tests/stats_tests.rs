//! Image statistics and the readout: `rz_image_histogram`,
//! `rz_image_sample`, `rz_image_auto_levels`, `rz_image_levels_channels` and
//! `rz_doc_lab`, exercised through the C ABI.
//!
//! The expected values are counted or computed HERE — a synthetic ramp whose
//! counts are known by construction, and a Lab pipeline written from the CIE
//! formulas against the published sRGB and Display P3 matrices — never read
//! back from the core.

use std::ffi::c_char;
use std::ptr;

use image::{Rgba, RgbaImage};
use rasterize_core::ffi::*;
use rasterize_core::ffi_adjust::*;
use rasterize_core::ffi_color::*;
use rasterize_core::ffi_doc::*;
use rasterize_core::ffi_filters::*;
use rasterize_core::RzImage;
use tempfile::TempDir;

mod common;
use common::*;

const AUTO_TONE: i32 = 0;
const AUTO_CONTRAST: i32 = 1;
const AUTO_COLOR: i32 = 2;

// ------------------------------------------------------------- histogram --

/// The four planes of `rz_image_histogram` plus the counted total.
fn histogram(img: *const RzImage, mask: Option<&[u8]>, stride: u32) -> ([u32; 1024], u64) {
    let mut bins = [0u32; 1024];
    let mut total = 0u64;
    let mask_ptr = mask.map_or(ptr::null(), <[u8]>::as_ptr);
    let ok = unsafe { rz_image_histogram(img, mask_ptr, stride, bins.as_mut_ptr(), &mut total) };
    assert!(ok, "histogram failed");
    (bins, total)
}

#[test]
fn histogram_counts_every_plane_and_honours_alpha_and_mask() {
    let dir = TempDir::new().unwrap();
    // 256x4: every code once per row in red, a fixed green and blue, and the
    // bottom two rows fully transparent.
    let src = RgbaImage::from_fn(256, 4, |x, y| {
        let a = if y < 2 { 255 } else { 0 };
        Rgba([x as u8, 40, 200, a])
    });
    let img = open_pattern(&dir, "hist.png", &src);

    let (bins, total) = histogram(img, None, 1);
    assert_eq!(total, 512, "only the opaque rows count");
    for (v, count) in bins[..256].iter().enumerate() {
        assert_eq!(*count, 2, "red code {v} appears once per opaque row");
    }
    assert_eq!(bins[256 + 40], 512, "green is constant");
    assert_eq!(bins[512 + 200], 512, "blue is constant");
    let luma_total: u32 = bins[768..].iter().sum();
    assert_eq!(
        u64::from(luma_total),
        total,
        "the luma plane counts once each"
    );
    // The luma plane spans exactly the range Rec. 709 gives this ramp:
    // 0.2126*x + 0.7152*40 + 0.0722*200 for x in 0..=255.
    let luma_at = |x: f64| (0.2126 * x + 0.7152 * 40.0 + 0.0722 * 200.0).round() as usize;
    let (lo, hi) = (luma_at(0.0), luma_at(255.0));
    assert!(
        bins[768..768 + lo].iter().all(|&b| b == 0),
        "nothing below {lo}"
    );
    assert!(
        bins[768 + hi + 1..].iter().all(|&b| b == 0),
        "nothing above {hi}"
    );

    // A mask that keeps the left half, binarized at 128: the 127 column is
    // out, the 128 column is in.
    let mask = selection(256, 4, |x, _| if x < 128 { 200 } else { 100 });
    let (masked, masked_total) = histogram(img, Some(&mask), 1);
    assert_eq!(masked_total, 256, "half the opaque pixels");
    for (v, count) in masked[..128].iter().enumerate() {
        assert_eq!(*count, 2, "code {v} survives the mask");
    }
    for (v, count) in masked[128..256].iter().enumerate() {
        assert_eq!(*count, 0, "code {} is masked out", v + 128);
    }

    // Stride: every 4th pixel of a 256-wide row is one in four, and the
    // total reports what was actually counted so proportions still work.
    let (strided, strided_total) = histogram(img, None, 4);
    assert_eq!(strided_total, 128, "one pixel in four, opaque rows only");
    assert_eq!(strided[768..].iter().sum::<u32>(), 128);
    // Stride 0 means "every pixel", exactly like stride 1.
    let (every, every_total) = histogram(img, None, 0);
    assert_eq!(every_total, total);
    assert_eq!(every, bins);

    free(img);
}

#[test]
fn histogram_luma_plane_of_a_grey_ramp_is_one_per_code() {
    // On a neutral pixel the three Rec. 709 weights sum to one, so the luma
    // plane of a full grey ramp must be exactly one count per code — the
    // unambiguous check that `bin = round(luma * 255)`.
    let dir = TempDir::new().unwrap();
    let src = RgbaImage::from_fn(256, 1, |x, _| {
        let v = x as u8;
        Rgba([v, v, v, 255])
    });
    let img = open_pattern(&dir, "hist-luma.png", &src);
    let (bins, total) = histogram(img, None, 1);
    assert_eq!(total, 256);
    for (v, count) in bins[768..].iter().enumerate() {
        assert_eq!(*count, 1, "luma code {v}");
    }
    free(img);
}

#[test]
fn histogram_of_a_wholly_transparent_image_counts_nothing() {
    let dir = TempDir::new().unwrap();
    let src = RgbaImage::from_pixel(8, 8, Rgba([0, 0, 0, 0]));
    let img = open_pattern(&dir, "hist-empty.png", &src);
    let (bins, total) = histogram(img, None, 1);
    assert_eq!(total, 0);
    assert!(bins.iter().all(|&b| b == 0), "no pixel counts");
    free(img);
}

// ---------------------------------------------------------------- sample --

fn sample(img: *const RzImage, x: i32, y: i32, reach: u32) -> Option<[u8; 4]> {
    let mut out = [0u8; 4];
    unsafe { rz_image_sample(img, x, y, reach, out.as_mut_ptr()) }.then_some(out)
}

#[test]
fn sample_is_the_truncating_block_mean_the_eyedropper_uses() {
    let dir = TempDir::new().unwrap();
    let src = RgbaImage::from_fn(8, 8, |x, y| {
        Rgba([(x * 8) as u8, (y * 8) as u8, ((x + y) * 4) as u8, 255])
    });
    let img = open_pattern(&dir, "sample.png", &src);

    // reach 0 is the pixel itself.
    assert_eq!(sample(img, 3, 5, 0), Some([24, 40, 32, 255]));

    // The mean is over the whole block, with INTEGER division truncating.
    for (x, y, reach) in [(3i32, 5i32, 1u32), (4, 4, 2), (0, 0, 1), (7, 7, 2)] {
        let mut sum = [0u32; 4];
        let mut count = 0u32;
        let r = reach as i32;
        for dy in -r..=r {
            for dx in -r..=r {
                let (px, py) = (x + dx, y + dy);
                if px < 0 || py < 0 || px >= 8 || py >= 8 {
                    continue;
                }
                let p = src.get_pixel(px as u32, py as u32);
                for (slot, v) in sum.iter_mut().zip(p.0) {
                    *slot += u32::from(v);
                }
                count += 1;
            }
        }
        let want = [
            (sum[0] / count) as u8,
            (sum[1] / count) as u8,
            (sum[2] / count) as u8,
            (sum[3] / count) as u8,
        ];
        assert_eq!(
            sample(img, x, y, reach),
            Some(want),
            "({x},{y}) reach {reach}"
        );
    }

    // The CENTRE may be outside the image: a 5x5 at x = -1 is the mean of
    // the columns that ARE inside, which is what the eyedropper does today.
    let edge = sample(img, -1, 4, 2).expect("a partly in-bounds block still samples");
    let mut sum = 0u32;
    let mut count = 0u32;
    for dy in -2i32..=2 {
        for dx in -2i32..=2 {
            let (px, py) = (-1 + dx, 4 + dy);
            if px < 0 || py < 0 || px >= 8 || py >= 8 {
                continue;
            }
            sum += u32::from(src.get_pixel(px as u32, py as u32)[0]);
            count += 1;
        }
    }
    assert_eq!(edge[0], (sum / count) as u8);

    // Entirely outside is the only refusal, along with an unknown reach.
    assert_eq!(sample(img, -10, -10, 2), None);
    assert_eq!(sample(img, 3, 3, 3), None);
    free(img);
}

// ----------------------------------------------------------- auto levels --

fn auto_levels(img: *const RzImage, mask: Option<&[u8]>, mode: i32, clip: f32) -> Option<[f32; 9]> {
    let mut params = [0f32; 9];
    let mask_ptr = mask.map_or(ptr::null(), <[u8]>::as_ptr);
    unsafe { rz_image_auto_levels(img, mask_ptr, mode, clip, params.as_mut_ptr()) }
        .then_some(params)
}

/// A grey ramp from `lo` to `hi`, `n` codes wide, opaque.
fn ramp(lo: u8, hi: u8, n: u32) -> RgbaImage {
    RgbaImage::from_fn(n, 1, |x, _| {
        let v = lo + ((u32::from(hi - lo) * x) / (n - 1)) as u8;
        Rgba([v, v, v, 255])
    })
}

#[test]
fn auto_tone_stretches_each_channel_to_the_clipped_extremes() {
    let dir = TempDir::new().unwrap();
    // Red 64..192, green 100..100 (flat), blue 0..255.
    let src = RgbaImage::from_fn(129, 1, |x, _| {
        Rgba([(64 + x) as u8, 100, ((x * 255) / 128) as u8, 255])
    });
    let img = open_pattern(&dir, "auto-tone.png", &src);
    let p = auto_levels(img, None, AUTO_TONE, 0.0).expect("auto tone");
    assert!((p[0] - 64.0 / 255.0).abs() < 1e-6, "red black is 64/255");
    assert!((p[3] - 192.0 / 255.0).abs() < 1e-6, "red white is 192/255");
    // A flat channel has nothing to stretch and is left alone.
    assert_eq!(
        (p[1], p[4]),
        (0.0, 1.0),
        "the flat green channel is untouched"
    );
    assert_eq!((p[2], p[5]), (0.0, 1.0), "blue already spans the range");
    assert_eq!(&p[6..], &[1.0, 1.0, 1.0], "auto tone never changes gamma");
    free(img);
}

#[test]
fn auto_contrast_takes_one_pair_from_the_luma_plane() {
    let dir = TempDir::new().unwrap();
    // A warm ramp: the three channels have different ranges, but Auto
    // Contrast must give all three the SAME endpoints, so the cast stays.
    let src = RgbaImage::from_fn(65, 1, |x, _| {
        Rgba([(60 + x * 2) as u8, (40 + x) as u8, (20 + x) as u8, 255])
    });
    let img = open_pattern(&dir, "auto-contrast.png", &src);
    let p = auto_levels(img, None, AUTO_CONTRAST, 0.0).expect("auto contrast");
    assert_eq!(p[0], p[1], "one black point for all three channels");
    assert_eq!(p[1], p[2]);
    assert_eq!(p[3], p[4], "one white point for all three channels");
    assert_eq!(p[4], p[5]);
    assert_eq!(&p[6..], &[1.0, 1.0, 1.0]);

    // The pair IS the luma plane's extremes: compute them here.
    let luma_of = |p: &Rgba<u8>| {
        (0.2126f32 * f32::from(p[0]) + 0.7152 * f32::from(p[1]) + 0.0722 * f32::from(p[2])).round()
    };
    let lo = src.pixels().map(luma_of).fold(f32::MAX, f32::min);
    let hi = src.pixels().map(luma_of).fold(f32::MIN, f32::max);
    assert!(
        (p[0] - lo / 255.0).abs() < 1e-6,
        "{} vs {}",
        p[0] * 255.0,
        lo
    );
    assert!(
        (p[3] - hi / 255.0).abs() < 1e-6,
        "{} vs {}",
        p[3] * 255.0,
        hi
    );
    free(img);
}

#[test]
fn auto_levels_ignores_transparent_padding() {
    // The whole reason `ops_stats`' counting rule exists: an alpha-blind
    // scan of a padded layer would see a spike of (0,0,0) and pin the black
    // point at 0.
    let dir = TempDir::new().unwrap();
    let bare = ramp(64, 192, 129);
    let padded = RgbaImage::from_fn(258, 1, |x, _| {
        if x < 129 {
            Rgba([0, 0, 0, 0])
        } else {
            *bare.get_pixel(x - 129, 0)
        }
    });
    let a = open_pattern(&dir, "auto-bare.png", &bare);
    let b = open_pattern(&dir, "auto-padded.png", &padded);
    let want = auto_levels(a, None, AUTO_TONE, 0.001).expect("bare");
    let got = auto_levels(b, None, AUTO_TONE, 0.001).expect("padded");
    assert_eq!(got, want, "transparent padding must not move the endpoints");
    free(a);
    free(b);
}

#[test]
fn auto_levels_clipping_fraction_moves_the_endpoints_inward() {
    let dir = TempDir::new().unwrap();
    // 1000 pixels spread over 100..=156 with a single pixel at 10 and one
    // at 250. At clip 0 the two outliers ARE the endpoints; at 0.1 % —
    // 1.002 pixels, so exactly one at each end — they are clipped away and
    // the bulk's own range takes over. (Outliers at 0 and 255 would make
    // clip 0 the identity, which the op refuses outright.)
    let src = RgbaImage::from_fn(1002, 1, |x, _| {
        let v = match x {
            0 => 10,
            1001 => 250,
            _ => (100 + ((x - 1) * 56) / 999) as u8,
        };
        Rgba([v, v, v, 255])
    });
    let img = open_pattern(&dir, "auto-clip.png", &src);
    let wide = auto_levels(img, None, AUTO_TONE, 0.0).expect("clip 0");
    assert!(
        (wide[0] - 10.0 / 255.0).abs() < 1e-6 && (wide[3] - 250.0 / 255.0).abs() < 1e-6,
        "at clip 0 the two outliers ARE the endpoints: {wide:?}"
    );
    let tight = auto_levels(img, None, AUTO_TONE, 0.001).expect("clip 0.1%");
    assert!(
        (tight[0] - 100.0 / 255.0).abs() < 1e-6 && (tight[3] - 156.0 / 255.0).abs() < 1e-6,
        "0.1 % clips both single-pixel outliers back to the bulk: {tight:?}"
    );
    free(img);
}

#[test]
fn auto_color_snaps_the_midtones_only_where_neutrals_exist() {
    let dir = TempDir::new().unwrap();
    // A blue-cast neutral field: every pixel is near-grey after the
    // per-channel stretch, so the candidate test passes and blue's gamma
    // moves. Two codes per channel keep the stretch non-degenerate.
    let src = RgbaImage::from_fn(64, 64, |x, y| {
        let n = ((x + y) % 2) as u8;
        Rgba([100 + n, 100 + n, 140 + n, 255])
    });
    let img = open_pattern(&dir, "auto-color.png", &src);
    let p = auto_levels(img, None, AUTO_COLOR, 0.0).expect("auto color");
    assert!(
        p[6] >= 0.5 && p[6] <= 2.0 && p[7] >= 0.5 && p[7] <= 2.0 && p[8] >= 0.5 && p[8] <= 2.0,
        "every gamma stays inside the [0.5, 2] bound: {:?}",
        &p[6..]
    );

    // A saturated field with NO near-neutral pixel must leave every gamma
    // at 1 — the whole point of the neutral-candidate rule over gray-world.
    let vivid = RgbaImage::from_fn(64, 64, |x, y| {
        let n = ((x + y) % 2) as u8;
        Rgba([240 + n, 30 + n, 20 + n, 255])
    });
    let vivid_img = open_pattern(&dir, "auto-vivid.png", &vivid);
    let q = auto_levels(vivid_img, None, AUTO_COLOR, 0.0).expect("auto color on a vivid frame");
    assert_eq!(&q[6..], &[1.0, 1.0, 1.0], "no neutral candidate, no gamma");
    free(img);
    free(vivid_img);
}

#[test]
fn auto_levels_refuses_flat_images_and_bad_arguments() {
    let dir = TempDir::new().unwrap();
    for (tag, fill) in [("white", 255u8), ("black", 0)] {
        let src = RgbaImage::from_pixel(16, 16, Rgba([fill, fill, fill, 255]));
        let img = open_pattern(&dir, &format!("auto-{tag}.png"), &src);
        for mode in [AUTO_TONE, AUTO_CONTRAST, AUTO_COLOR] {
            assert_eq!(
                auto_levels(img, None, mode, 0.001),
                None,
                "an all-{tag} image has nothing to stretch (mode {mode})"
            );
        }
        free(img);
    }
    let img = open_pattern(&dir, "auto-args.png", &ramp(30, 220, 64));
    assert_eq!(
        auto_levels(img, None, AUTO_TONE, -0.001),
        None,
        "clip below 0"
    );
    assert_eq!(
        auto_levels(img, None, AUTO_TONE, 0.2),
        None,
        "clip above 0.1"
    );
    assert_eq!(
        auto_levels(img, None, AUTO_TONE, f32::NAN),
        None,
        "NaN clip"
    );
    assert_eq!(auto_levels(img, None, 9, 0.001), None, "unknown mode");
    let none = selection(64, 1, |_, _| 0);
    assert_eq!(
        auto_levels(img, Some(&none), AUTO_TONE, 0.001),
        None,
        "a mask that covers nothing counts nothing"
    );
    free(img);
}

// ------------------------------------------------------ levels_channels --

fn levels_channels(
    img: *const RzImage,
    black: [f32; 3],
    white: [f32; 3],
    gamma: [f32; 3],
) -> *mut RzImage {
    unsafe { rz_image_levels_channels(img, black.as_ptr(), white.as_ptr(), gamma.as_ptr()) }
}

#[test]
fn levels_channels_agrees_with_levels_and_refuses_per_channel() {
    let dir = TempDir::new().unwrap();
    let src = opaque_pattern(32, 24);
    let img = open_pattern(&dir, "lc.png", &src);

    // Repeated triples are exactly the single-value op.
    let one = unsafe { rz_image_levels(img, 0.1, 0.9, 1.8) };
    let three = levels_channels(img, [0.1; 3], [0.9; 3], [1.8; 3]);
    assert!(!one.is_null() && !three.is_null());
    assert_eq!(pixels(one), pixels(three), "the two spellings must agree");
    unsafe { rz_image_free(one) };
    unsafe { rz_image_free(three) };

    // Per-channel really is per channel: only red moves.
    let red_only = levels_channels(img, [0.2, 0.0, 0.0], [0.8, 1.0, 1.0], [1.0; 3]);
    assert!(!red_only.is_null());
    let got = pixels(red_only);
    for (i, px) in src.pixels().enumerate() {
        let t = ((f32::from(px[0]) / 255.0 - 0.2) / 0.6).clamp(0.0, 1.0);
        assert_eq!(got[i * 4], (t * 255.0).round() as u8, "red at {i}");
        assert_eq!(got[i * 4 + 1], px[1], "green untouched");
        assert_eq!(got[i * 4 + 2], px[2], "blue untouched");
        assert_eq!(got[i * 4 + 3], px[3], "alpha untouched");
    }
    unsafe { rz_image_free(red_only) };

    // One bad channel refuses the whole op.
    for (black, white, gamma) in [
        ([0.0, 0.9, 0.0], [1.0, 0.5, 1.0], [1.0; 3]),
        ([0.0; 3], [1.0; 3], [1.0, 0.05, 1.0]),
        ([0.0; 3], [1.0; 3], [1.0, 1.0, 11.0]),
        ([-0.1, 0.0, 0.0], [1.0; 3], [1.0; 3]),
    ] {
        assert!(
            levels_channels(img, black, white, gamma).is_null(),
            "{black:?}/{white:?}/{gamma:?} must be refused"
        );
    }
    assert!(
        unsafe { rz_image_levels_channels(img, ptr::null(), ptr::null(), ptr::null()) }.is_null()
    );
    free(img);
}

// ------------------------------------------------------------------ Lab --

const D50: [f64; 3] = [0.96422, 1.0, 0.82521];
const SRGB_TO_XYZ_D50: [[f64; 3]; 3] = [
    [0.4360747, 0.3850649, 0.1430804],
    [0.2225045, 0.7168786, 0.0606169],
    [0.0139322, 0.0971045, 0.7141733],
];
const P3_TO_XYZ_D50: [[f64; 3]; 3] = [
    [0.5150749, 0.2919397, 0.1571791],
    [0.2411702, 0.6922355, 0.0665899],
    [-0.0010486, 0.0418842, 0.7845459],
];

/// Lab from encoded RGB through a D50-adapted matrix, written from the CIE
/// formulas: linearize with the sRGB transfer function (both profiles use
/// it), matrix, then L*a*b* against the D50 PCS white.
fn lab_oracle(rgb: [u8; 3], matrix: [[f64; 3]; 3]) -> [f64; 3] {
    let lin = rgb.map(|v| {
        let v = f64::from(v) / 255.0;
        if v <= 0.04045 {
            v / 12.92
        } else {
            ((v + 0.055) / 1.055).powf(2.4)
        }
    });
    let xyz: [f64; 3] = matrix.map(|row| row[0] * lin[0] + row[1] * lin[1] + row[2] * lin[2]);
    let eps = 216.0 / 24389.0;
    let kappa = 24389.0 / 27.0;
    let f = |t: f64| {
        if t > eps {
            t.cbrt()
        } else {
            (kappa * t + 16.0) / 116.0
        }
    };
    let (fx, fy, fz) = (f(xyz[0] / D50[0]), f(xyz[1] / D50[1]), f(xyz[2] / D50[2]));
    [116.0 * fy - 16.0, 500.0 * (fx - fy), 200.0 * (fy - fz)]
}

fn doc_lab(doc: *const rasterize_core::doc::RzDocument, rgb: [u8; 3]) -> Option<[f32; 3]> {
    let mut out = [0f32; 3];
    unsafe { rz_doc_lab(doc, rgb[0], rgb[1], rgb[2], out.as_mut_ptr()) }.then_some(out)
}

#[test]
fn lab_is_read_through_the_documents_own_profile() {
    let dir = TempDir::new().unwrap();
    let doc = doc_from(&dir, "lab.png", &solid(4, 4, [10, 20, 30, 255]));

    // An untagged document is sRGB, and the readout is the D50 Lab of it.
    for rgb in [
        [255u8, 255, 255],
        [128, 128, 128],
        [255, 0, 0],
        [0, 255, 0],
        [0, 0, 255],
        [200, 150, 120],
        [0, 0, 0],
    ] {
        let got = doc_lab(doc, rgb).expect("sRGB document has a matrix/TRC model");
        let want = lab_oracle(rgb, SRGB_TO_XYZ_D50);
        for c in 0..3 {
            // 0.05 rather than 1e-6: the readout goes through the built-in
            // profile BLOB's own matrix columns and `para` curve, which
            // agree with Lindbloom's published sRGB numbers to about the
            // 7th decimal rather than exactly. That is two orders of
            // magnitude tighter than the sRGB/P3 gap this test cares about.
            assert!(
                (f64::from(got[c]) - want[c]).abs() < 5e-2,
                "{rgb:?} component {c}: {} vs {}",
                got[c],
                want[c]
            );
        }
    }
    // A neutral has a = b = 0 by construction of the matrix columns.
    let grey = doc_lab(doc, [128, 128, 128]).unwrap();
    assert!(grey[1].abs() < 5e-2 && grey[2].abs() < 5e-2, "{grey:?}");
    assert!((doc_lab(doc, [255, 255, 255]).unwrap()[0] - 100.0).abs() < 5e-2);

    // The pair spelled out, so the numbers a reader can look up are on the
    // page rather than only inside the oracle: the SAME bytes (200, 150,
    // 120) are L 66.408 a 16.507 b 23.547 in an sRGB document and L 66.743
    // a 21.179 b 27.018 in a Display P3 one. Photoshop's Info panel rounds
    // the first to L 66, a 17, b 24.
    let as_srgb = doc_lab(doc, [200, 150, 120]).expect("sRGB models");
    for (c, want) in [66.408f64, 16.507, 23.547].into_iter().enumerate() {
        assert!(
            (f64::from(as_srgb[c]) - want).abs() < 5e-2,
            "sRGB (200,150,120) component {c}: {} vs the published {want}",
            as_srgb[c]
        );
    }

    // The SAME bytes in a Display P3 document read differently — which is
    // the whole point of going through the profile. `assign` reinterprets:
    // the pixels do not move, only their meaning does. (`apply` consumes
    // the document it is handed, so nothing below may touch `doc` again.)
    let p3 = builtin_profile_bytes(1);
    let tagged = apply(doc, |d| unsafe {
        rz_doc_assign_profile(d, p3.as_ptr(), p3.len())
    });
    for rgb in [[255u8, 0, 0], [200, 150, 120]] {
        let got = doc_lab(tagged, rgb).expect("Display P3 is a matrix/TRC profile");
        let want = lab_oracle(rgb, P3_TO_XYZ_D50);
        for c in 0..3 {
            assert!(
                (f64::from(got[c]) - want[c]).abs() < 5e-2,
                "P3 {rgb:?} component {c}: {} vs {}",
                got[c],
                want[c]
            );
        }
        let srgb_value = lab_oracle(rgb, SRGB_TO_XYZ_D50);
        assert!(
            (f64::from(got[1]) - srgb_value[1]).abs() > 1.0,
            "{rgb:?} must NOT read as sRGB in a P3 document"
        );
    }

    let as_p3 = doc_lab(tagged, [200, 150, 120]).expect("Display P3 models");
    for (c, want) in [66.743f64, 21.179, 27.018].into_iter().enumerate() {
        assert!(
            (f64::from(as_p3[c]) - want).abs() < 5e-2,
            "P3 (200,150,120) component {c}: {} vs the published {want}",
            as_p3[c]
        );
    }
    unsafe { rz_doc_free(tagged) };
}

/// One of the built-in profile blobs (0 = sRGB, 1 = Display P3).
fn builtin_profile_bytes(which: i32) -> Vec<u8> {
    let len = rz_builtin_profile_len(which);
    assert!(len > 0);
    let mut out = vec![0u8; len];
    assert!(unsafe { rz_builtin_profile(which, out.as_mut_ptr(), len) });
    out
}

// ------------------------------------------------------- NULL tolerance --

#[test]
fn null_safety_for_the_statistics_exports() {
    let dir = TempDir::new().unwrap();
    let img = open_pattern(&dir, "null.png", &solid(4, 4, [1, 2, 3, 255]));
    let mut bins = [0u32; 1024];
    let mut total = 0u64;
    let mut rgba = [0u8; 4];
    let mut params = [0f32; 9];
    let mut lab = [0f32; 3];
    unsafe {
        assert!(!rz_image_histogram(
            ptr::null(),
            ptr::null(),
            1,
            bins.as_mut_ptr(),
            &mut total
        ));
        assert!(!rz_image_histogram(
            img,
            ptr::null(),
            1,
            ptr::null_mut(),
            &mut total
        ));
        // A NULL total pointer is tolerated: the bins still come back.
        assert!(rz_image_histogram(
            img,
            ptr::null(),
            1,
            bins.as_mut_ptr(),
            ptr::null_mut()
        ));
        assert!(!rz_image_sample(ptr::null(), 0, 0, 0, rgba.as_mut_ptr()));
        assert!(!rz_image_sample(img, 0, 0, 0, ptr::null_mut()));
        assert!(!rz_image_auto_levels(
            ptr::null(),
            ptr::null(),
            0,
            0.001,
            params.as_mut_ptr()
        ));
        assert!(!rz_image_auto_levels(
            img,
            ptr::null(),
            0,
            0.001,
            ptr::null_mut()
        ));
        assert!(rz_image_levels_channels(
            ptr::null(),
            [0.0f32; 3].as_ptr(),
            [1.0f32; 3].as_ptr(),
            [1.0f32; 3].as_ptr()
        )
        .is_null());
        assert!(!rz_doc_lab(ptr::null(), 0, 0, 0, lab.as_mut_ptr()));
    }
    let doc = doc_from(&dir, "null-doc.png", &solid(2, 2, [4, 5, 6, 255]));
    assert!(!unsafe { rz_doc_lab(doc, 0, 0, 0, ptr::null_mut()) });
    unsafe { rz_doc_free(doc) };
    free(img);
}

#[test]
fn adjust_op_error_string_is_optional() {
    // Every fallible export tolerates a NULL err_out: the refusal is still a
    // refusal, it simply has nowhere to put the message.
    let dir = TempDir::new().unwrap();
    let img = open_pattern(&dir, "no-err.png", &solid(2, 2, [1, 2, 3, 255]));
    let op = std::ffi::CString::new("no_such_op").unwrap();
    assert!(
        unsafe { rz_image_adjust_op(img, op.as_ptr(), ptr::null(), ptr::null_mut()) }.is_null()
    );
    let mut err: *mut c_char = ptr::null_mut();
    assert!(unsafe { rz_lut_parse_cube(ptr::null(), &mut err) }.is_null());
    assert!(take_err_string(err).contains("path"));
    assert!(unsafe { rz_lut_parse_cube(ptr::null(), ptr::null_mut()) }.is_null());
    free(img);
}
