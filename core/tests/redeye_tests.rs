//! Red-eye tests: `rz_doc_red_eye_layer`. The oracle is an independently
//! written scalar reference of the documented three-gate score and its
//! correction, plus the fifteen-colour classification table the thresholds
//! were chosen against — never a golden image. Every application runs
//! through the FFI on documents built from the safe constructors; shared
//! fixtures live in `tests/common`.

use std::ptr;

use image::{Rgba, RgbaImage};
use rasterize_core::doc::RzDocument;
use rasterize_core::ffi_doc::rz_doc_free;
use rasterize_core::ffi_heal::rz_doc_red_eye_layer;

mod common;
use common::*;

// ------------------------------------------------------------- plumbing --

/// Runs the op through its FFI entry point on a copy of `doc`; `None` when
/// it refuses.
fn red_eye(
    doc: &RzDocument,
    idx: usize,
    rect: (i32, i32, u32, u32),
    pupil_size: f32,
    darken: f32,
) -> Option<RzDocument> {
    let handle = Box::into_raw(Box::new(doc.clone()));
    let out = unsafe {
        rz_doc_red_eye_layer(
            handle, idx, rect.0, rect.1, rect.2, rect.3, pupil_size, darken,
        )
    };
    unsafe { rz_doc_free(handle) };
    if out.is_null() {
        None
    } else {
        Some(*unsafe { Box::from_raw(out) })
    }
}

fn layer_bytes(doc: &RzDocument, idx: usize) -> Vec<u8> {
    let handle = Box::into_raw(Box::new(doc.clone()));
    let out = layer_pixels(handle, idx);
    unsafe { rz_doc_free(handle) };
    out
}

fn doc_of(w: u32, h: u32, f: impl Fn(u32, u32) -> [u8; 4]) -> RzDocument {
    RzDocument::from_pixels(RgbaImage::from_fn(w, h, |x, y| Rgba(f(x, y))))
}

// ------------------------------------------------------------ the oracle --

fn smoothstep(a: f64, b: f64, x: f64) -> f64 {
    let t = ((x - a) / (b - a)).clamp(0.0, 1.0);
    t * t * (3.0 - 2.0 * t)
}

/// The documented score, rebuilt from the contract: the ratio
/// `R/((G+B)/2)` gated by HSV saturation and by hue distance from pure red,
/// all three multiplied. Shares no code with the core.
fn coverage(rgb: [u8; 3]) -> f64 {
    let [r, g, b] = [
        f64::from(rgb[0]) / 255.0,
        f64::from(rgb[1]) / 255.0,
        f64::from(rgb[2]) / 255.0,
    ];
    let mean_gb = (g + b) / 2.0;
    let ratio = r / mean_gb.max(1.0 / 255.0);
    let max = r.max(g).max(b);
    let min = r.min(g).min(b);
    let saturation = if max > 0.0 { (max - min) / max } else { 0.0 };
    let chroma = max - min;
    let hue = if chroma <= 0.0 {
        0.0
    } else if max == r {
        60.0 * (((g - b) / chroma) % 6.0)
    } else if max == g {
        60.0 * ((b - r) / chroma + 2.0)
    } else {
        60.0 * ((r - g) / chroma + 4.0)
    };
    let hue_wrapped = hue.rem_euclid(360.0);
    let hue_distance = hue_wrapped.min(360.0 - hue_wrapped);
    smoothstep(2.0, 3.0, ratio)
        * smoothstep(0.35, 0.55, saturation)
        * (1.0 - smoothstep(20.0, 40.0, hue_distance))
}

/// The documented correction at full mask weight: red drops to `(G+B)/2`,
/// then every channel darkens by `d = 1 - 0.8 * darken`.
fn corrected(rgb: [u8; 3], darken: f64) -> [u8; 3] {
    let c = coverage(rgb);
    let d = 1.0 - 0.8 * darken;
    let v = [f64::from(rgb[0]), f64::from(rgb[1]), f64::from(rgb[2])];
    let neutral = (v[1] + v[2]) / 2.0;
    let after = [v[0] + c * (neutral - v[0]), v[1], v[2]];
    let mut out = [0u8; 3];
    for (i, value) in after.iter().enumerate() {
        let darkened = value * (1.0 - c * (1.0 - d));
        out[i] = (darkened.clamp(0.0, 255.0) + 0.5).floor() as u8;
    }
    out
}

/// The fifteen representative colours the thresholds were measured against,
/// with the sample name and whether the tool must move it.
const SAMPLES: [(&str, [u8; 3], bool); 15] = [
    ("red-eye bright", [220, 40, 45], true),
    ("red-eye mid", [150, 25, 30], true),
    ("red-eye saturated", [255, 60, 60], true),
    ("red-eye dim", [95, 20, 22], true),
    ("catchlight", [250, 248, 245], false),
    ("skin light", [235, 190, 165], false),
    ("skin medium", [200, 150, 125], false),
    ("skin dark", [110, 75, 60], false),
    ("lips natural", [185, 85, 95], false),
    ("lipstick red", [170, 40, 55], true),
    ("iris brown", [90, 60, 45], false),
    ("eyelash", [30, 25, 25], false),
    ("sclera", [240, 225, 225], false),
    ("blood-shot sclera", [235, 180, 180], false),
    ("red shirt", [190, 35, 40], true),
];

/// The samples laid out as 5x5 patches on a 3px neutral grid, so no two
/// patches are within a feather of each other.
const PATCH: u32 = 5;
const PITCH: u32 = 8;
const COLUMNS: u32 = 5;

fn sample_doc() -> RzDocument {
    let rows = SAMPLES.len() as u32 / COLUMNS;
    doc_of(COLUMNS * PITCH, rows * PITCH, |x, y| {
        let (cx, cy) = (x / PITCH, y / PITCH);
        let (ix, iy) = (x % PITCH, y % PITCH);
        if ix >= PATCH || iy >= PATCH {
            return [128, 128, 128, 255];
        }
        let index = (cy * COLUMNS + cx) as usize;
        match SAMPLES.get(index) {
            Some((_, rgb, _)) => [rgb[0], rgb[1], rgb[2], 255],
            None => [128, 128, 128, 255],
        }
    })
}

fn patch_centre(index: usize) -> (u32, u32) {
    let (cx, cy) = (index as u32 % COLUMNS, index as u32 / COLUMNS);
    (cx * PITCH + PATCH / 2, cy * PITCH + PATCH / 2)
}

// ------------------------------------------------------------ the tests --

/// The classification table: flash red moves, and everything a face is
/// actually made of does not. `R > G` holds for every one of these fifteen
/// colours, which is why the score is the RATIO gated by saturation and hue
/// — and why the catchlight, at saturation 0.02, comes out bit-identical.
#[test]
fn the_fifteen_colour_table_classifies_correctly() {
    let doc = sample_doc();
    let rows = SAMPLES.len() as u32 / COLUMNS;
    let width = COLUMNS * PITCH;
    let before = layer_bytes(&doc, 0);
    let out = red_eye(&doc, 0, (0, 0, width, rows * PITCH), 1.0, 0.5)
        .expect("the red samples must be corrected");
    let after = layer_bytes(&out, 0);
    for (index, (name, rgb, moves)) in SAMPLES.iter().enumerate() {
        let (x, y) = patch_centre(index);
        let got = pixel(&after, width, x, y);
        let was = pixel(&before, width, x, y);
        if *moves {
            assert_ne!(got, was, "{name} must be corrected");
            let want = corrected(*rgb, 0.5);
            assert_eq!(
                [got[0], got[1], got[2]],
                want,
                "{name}: coverage {:.4}",
                coverage(*rgb)
            );
        } else {
            assert_eq!(
                got,
                was,
                "{name} must be bit-identical (coverage {:.4})",
                coverage(*rgb)
            );
        }
    }
}

/// The published worked outputs: (220, 40, 45) -> (26, 24, 27) and
/// (255, 60, 60) -> (36, 36, 36) at the default Darken Amount. A corrected
/// pupil is a believable near-neutral dark grey, not a flat black hole,
/// because the residual G/B difference survives.
#[test]
fn the_corrected_pupil_matches_the_published_numbers() {
    assert_eq!(corrected([220, 40, 45], 0.5), [26, 24, 27], "oracle");
    assert_eq!(corrected([255, 60, 60], 0.5), [36, 36, 36], "oracle");
    // Two pupil-sized red squares in a skin field, well inside the rect so
    // the size gate is not what this test is about.
    let doc = doc_of(32, 32, |x, y| {
        if (4..12).contains(&x) && (12..20).contains(&y) {
            [220, 40, 45, 255]
        } else if (20..28).contains(&x) && (12..20).contains(&y) {
            [255, 60, 60, 255]
        } else {
            [200, 150, 125, 255]
        }
    });
    let out = red_eye(&doc, 0, (0, 0, 32, 32), 1.0, 0.5).expect("both squares are red");
    let after = layer_bytes(&out, 0);
    assert_eq!(pixel(&after, 32, 7, 15), [26, 24, 27, 255]);
    assert_eq!(pixel(&after, 32, 23, 15), [36, 36, 36, 255]);
}

/// `darken` 0 neutralises only: red drops to the level of the other two and
/// nothing gets darker.
#[test]
fn darken_zero_neutralises_without_darkening() {
    let doc = doc_of(16, 16, |x, y| {
        if (4..12).contains(&x) && (4..12).contains(&y) {
            [220, 40, 45, 255]
        } else {
            [200, 150, 125, 255]
        }
    });
    let out = red_eye(&doc, 0, (0, 0, 16, 16), 1.0, 0.0).expect("red");
    let after = layer_bytes(&out, 0);
    assert_eq!(pixel(&after, 16, 8, 8), [43, 40, 45, 255]);
    assert_eq!(corrected([220, 40, 45], 0.0), [43, 40, 45], "oracle");
}

/// The gesture the tool documents: a tight rectangle over one eye, whose red
/// iris spans about 70 % of the shorter side, IS corrected at the shipped
/// default of 100 %. (A 50 % default would refuse exactly this drag.)
#[test]
fn a_tight_rectangle_over_one_eye_is_corrected() {
    let doc = eye_doc();
    let out = red_eye(&doc, 0, (10, 10, 40, 40), 1.0, 0.5).expect("the iris must be corrected");
    let after = layer_bytes(&out, 0);
    let centre = pixel(&after, 60, 30, 30);
    assert_eq!(
        [centre[0], centre[1], centre[2]],
        corrected([220, 40, 45], 0.5)
    );
}

/// Turning Pupil Size down is how the user spares something red that a
/// sloppy rectangle caught: at 50 % the same 70 %-of-the-rect iris is
/// rejected, and since nothing else in the rect is red the op refuses
/// outright — the "no red region small enough to be a pupil" case, distinct
/// from "nothing red at all".
#[test]
fn the_size_gate_rejects_a_component_over_the_limit() {
    let doc = eye_doc();
    assert!(red_eye(&doc, 0, (10, 10, 40, 40), 0.5, 0.5).is_none());

    // And at the default, a red band wider than the rectangle's SHORTER side
    // is still rejected: the reference length is the short axis, so a
    // careless wide drag does not license correcting a red shirt.
    let banded = doc_of(140, 100, |x, y| {
        if (20..80).contains(&x) && (40..56).contains(&y) {
            [190, 35, 40, 255]
        } else {
            [200, 150, 125, 255]
        }
    });
    assert!(red_eye(&banded, 0, (0, 38, 120, 20), 1.0, 0.5).is_none());
    // The same band inside a rectangle whose short side is long enough IS
    // corrected, which is what makes the gate a size test and not a refusal.
    assert!(red_eye(&banded, 0, (0, 0, 140, 100), 1.0, 0.5).is_some());
}

/// A rectangle dropped WHOLLY inside a red region is refused at the shipped
/// default, and this is the case that used to slip through: a component is
/// clipped to the rectangle, so on a square one its larger side can never
/// exceed the rectangle's shorter side and the size gate alone could never
/// fire. The old behaviour desaturated every pixel of the rectangle and left
/// a hard-edged square; the four-sides rule refuses instead.
#[test]
fn a_rectangle_inside_one_red_region_is_refused() {
    let cloud = doc_of(200, 200, |x, y| {
        // A red field big enough that a 70 x 70 rectangle anywhere near the
        // middle sits inside it, with skin around the outside.
        let (dx, dy) = (x as f32 - 100.0, y as f32 - 100.0);
        if dx * dx + dy * dy <= 80.0 * 80.0 {
            [220, 40, 45, 255]
        } else {
            [200, 150, 125, 255]
        }
    });
    assert!(
        red_eye(&cloud, 0, (65, 65, 70, 70), 1.0, 0.5).is_none(),
        "a rectangle inside the red cloud has no pupil in it to find"
    );
    // A NON-square rectangle inside the same cloud was already refused by
    // the size gate; it still is, so the two rules agree where they overlap.
    assert!(red_eye(&cloud, 0, (50, 80, 100, 40), 1.0, 0.5).is_none());
    // And the rule is about the RECTANGLE, not the picture: the same cloud
    // with a rectangle around the whole of it is corrected, because the red
    // region ends inside the rectangle.
    assert!(
        red_eye(&cloud, 0, (0, 0, 200, 200), 1.0, 0.5).is_some(),
        "a red region the rectangle contains is still a candidate"
    );
}

/// The four-sides rule must not cost the documented gesture: a tight
/// rectangle whose iris touches its left and right edges — the drag the
/// README asks for, at the extreme end of "40-90 % of the shorter side" —
/// is still corrected, because the iris ends inside the rectangle
/// vertically.
#[test]
fn an_iris_touching_two_sides_is_still_corrected() {
    let doc = doc_of(60, 60, |x, y| {
        let (dx, dy) = (x as f32 - 30.0, y as f32 - 30.0);
        if dx * dx + dy * dy <= 10.0 * 10.0 {
            [220, 40, 45, 255]
        } else {
            [200, 150, 125, 255]
        }
    });
    // 21 px wide, 40 tall: the disc (21 px across) spans the full width and
    // stops well short of the top and bottom.
    let out = red_eye(&doc, 0, (20, 10, 21, 40), 1.0, 0.5).expect("the iris must be corrected");
    let after = layer_bytes(&out, 0);
    assert_eq!(
        [
            pixel(&after, 60, 30, 30)[0],
            pixel(&after, 60, 30, 30)[1],
            pixel(&after, 60, 30, 30)[2]
        ],
        corrected([220, 40, 45], 0.5)
    );
}

/// A 60x60 skin field with a red iris disc of diameter 28 centred at
/// (30, 30) — 70 % of the 40x40 rectangle the tests drag over it.
fn eye_doc() -> RzDocument {
    doc_of(60, 60, |x, y| {
        let (dx, dy) = (x as f32 - 30.0, y as f32 - 30.0);
        if dx * dx + dy * dy <= 14.0 * 14.0 {
            [220, 40, 45, 255]
        } else {
            [200, 150, 125, 255]
        }
    })
}

/// Layer alpha is never touched, and a fully transparent pixel is skipped
/// even where its colour bytes say red — they are latent garbage, not
/// colour.
#[test]
fn alpha_and_transparent_pixels_survive() {
    let doc = doc_of(16, 16, |x, y| {
        if x == 8 && y == 8 {
            [220, 40, 45, 0]
        } else if (4..12).contains(&x) && (4..12).contains(&y) {
            [220, 40, 45, 200]
        } else {
            [200, 150, 125, 255]
        }
    });
    let before = layer_bytes(&doc, 0);
    let out = red_eye(&doc, 0, (0, 0, 16, 16), 1.0, 0.5).expect("red");
    let after = layer_bytes(&out, 0);
    assert_eq!(
        pixel(&after, 16, 8, 8),
        [220, 40, 45, 0],
        "a transparent pixel keeps every byte"
    );
    for i in 0..16 * 16 {
        assert_eq!(before[i * 4 + 3], after[i * 4 + 3], "alpha moved at {i}");
    }
}

/// The correction is confined to the rectangle: red outside it is untouched,
/// which is the whole reason the op takes a rectangle at all (colour alone
/// cannot tell a pupil from a red shirt).
#[test]
fn nothing_outside_the_rectangle_moves() {
    let doc = doc_of(40, 20, |x, y| {
        let left = (2..10).contains(&x) && (6..14).contains(&y);
        let right = (30..38).contains(&x) && (6..14).contains(&y);
        if left || right {
            [220, 40, 45, 255]
        } else {
            [200, 150, 125, 255]
        }
    });
    let before = layer_bytes(&doc, 0);
    let out = red_eye(&doc, 0, (0, 0, 12, 20), 1.0, 0.5).expect("the left blob is inside");
    let after = layer_bytes(&out, 0);
    for y in 0..20u32 {
        for x in 12..40u32 {
            assert_eq!(
                pixel(&after, 40, x, y),
                pixel(&before, 40, x, y),
                "pixel ({x}, {y}) is outside the rectangle"
            );
        }
    }
    assert_ne!(pixel(&after, 40, 5, 10), pixel(&before, 40, 5, 10));
}

#[test]
fn refusals_are_null() {
    let red = doc_of(20, 20, |_, _| [220, 40, 45, 255]);
    let grey = doc_of(20, 20, |_, _| [128, 128, 128, 255]);
    assert!(
        red_eye(&red, 0, (0, 0, 0, 10), 1.0, 0.5).is_none(),
        "empty rect"
    );
    assert!(
        red_eye(&red, 0, (0, 0, 10, 0), 1.0, 0.5).is_none(),
        "empty rect"
    );
    assert!(
        red_eye(&red, 0, (500, 500, 10, 10), 1.0, 0.5).is_none(),
        "rect entirely off-canvas"
    );
    assert!(
        red_eye(&red, 7, (0, 0, 20, 20), 1.0, 0.5).is_none(),
        "bad index"
    );
    assert!(
        red_eye(&red, 0, (0, 0, 20, 20), f32::NAN, 0.5).is_none(),
        "non-finite pupil size"
    );
    assert!(
        red_eye(&red, 0, (0, 0, 20, 20), 1.0, f32::INFINITY).is_none(),
        "non-finite darken"
    );
    assert!(
        red_eye(&grey, 0, (0, 0, 20, 20), 1.0, 0.5).is_none(),
        "nothing red at all"
    );
    // A rect that reaches past the canvas is clipped, not refused. The blob
    // has to END inside the clipped rect: an all-red canvas is the
    // four-sides case and is refused on purpose
    // (`a_rectangle_inside_one_red_region_is_refused`).
    let blob = doc_of(20, 20, |x, y| {
        if (6..14).contains(&x) && (6..14).contains(&y) {
            [220, 40, 45, 255]
        } else {
            [200, 150, 125, 255]
        }
    });
    assert!(red_eye(&blob, 0, (-8, -8, 40, 40), 1.0, 0.5).is_some());
}

#[test]
fn null_safety() {
    unsafe {
        assert!(rz_doc_red_eye_layer(ptr::null(), 0, 0, 0, 4, 4, 1.0, 0.5).is_null());
    }
}

/// The extreme rect the Swift wrapper's clamp now hands down. `red_eye` and
/// `red_eye_auto` both take caller-supplied numbers, and
/// `RasterDocument.redEyeLayer` used to convert them with Swift's `Int(_:)`,
/// which TRAPS rather than saturating on a finite Double outside Int64's
/// range — `red_eye {"x": 1e300, …}` killed the app. That is fixed on the
/// Swift side by clamping in Double space first, and this is the other half
/// of the contract: the widest rect the clamp can produce (an i32::MIN
/// origin, a near-u32::MAX extent) must be clipped to the canvas in i64 and
/// answered, never panic and never wrap.
#[test]
fn an_extreme_rect_is_clipped_rather_than_wrapped() {
    let doc = doc_of(48, 48, |x, y| {
        if (18..30).contains(&x) && (18..30).contains(&y) {
            [220, 40, 45, 255]
        } else {
            [180, 150, 140, 255]
        }
    });
    // Wholly off the canvas in both directions: a plain refusal, no panic.
    for rect in [
        (i32::MIN, i32::MIN, 1u32, 1u32),
        (i32::MAX, i32::MAX, u32::MAX, u32::MAX),
        (-2_000_000_000, 0, 1, 48),
    ] {
        assert!(
            red_eye(&doc, 0, rect, 1.0, 0.5).is_none(),
            "an off-canvas rect must refuse: {rect:?}"
        );
    }
    // Covering the canvas many times over: clipped to it, and then the
    // four-sides rule refuses, because a rectangle that big is inside
    // nothing — it CONTAINS everything, red patch included, so this must
    // answer rather than run away.
    let huge = red_eye(&doc, 0, (i32::MIN, i32::MIN, u32::MAX, u32::MAX), 1.0, 0.5);
    let clipped = red_eye(&doc, 0, (0, 0, 48, 48), 1.0, 0.5);
    assert_eq!(
        huge.map(|d| layer_bytes(&d, 0)),
        clipped.map(|d| layer_bytes(&d, 0)),
        "a rect clipped to the canvas must behave as the canvas rect"
    );
}
