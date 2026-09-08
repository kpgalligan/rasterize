//! Red-eye removal on the layered document: inside a canvas rectangle,
//! find the flash pupil and desaturate it without killing the catchlight.
//!
//! # Why `R > G` is worthless, measured
//!
//! Fifteen representative colours, all of which satisfy `R > G`. The
//! discriminating form is the RATIO `R/((G+B)/2)` — red-eye's signature is
//! that G and B COLLAPSE while R saturates, which is multiplicative — gated
//! by HSV saturation and hue:
//!
//! | sample | R,G,B | ratio | hue dist | HSV sat | coverage |
//! |---|---|---|---|---|---|
//! | red-eye bright | 220, 40, 45 | 5.18 | 1.7° | 0.82 | **1.000** |
//! | red-eye mid | 150, 25, 30 | 5.45 | 2.4° | 0.83 | **1.000** |
//! | red-eye saturated | 255, 60, 60 | 4.25 | 0.0° | 0.76 | **1.000** |
//! | red-eye dim | 95, 20, 22 | 4.52 | 1.6° | 0.79 | **1.000** |
//! | catchlight (specular) | 250, 248, 245 | 1.01 | 36.0° | 0.02 | 0.000 |
//! | skin light | 235, 190, 165 | 1.32 | 21.4° | 0.30 | 0.000 |
//! | skin medium | 200, 150, 125 | 1.45 | 20.0° | 0.38 | 0.000 |
//! | skin dark | 110, 75, 60 | 1.63 | 18.0° | 0.45 | 0.000 |
//! | lips natural | 185, 85, 95 | 2.06 | 6.0° | 0.54 | 0.009 |
//! | lipstick red | 170, 40, 55 | 3.58 | 6.9° | 0.76 | **1.000** |
//! | iris brown | 90, 60, 45 | 1.71 | 20.0° | 0.50 | 0.000 |
//! | eyelash | 30, 25, 25 | 1.20 | 0.0° | 0.17 | 0.000 |
//! | sclera | 240, 225, 225 | 1.07 | 0.0° | 0.06 | 0.000 |
//! | blood-shot sclera | 235, 180, 180 | 1.31 | 0.0° | 0.23 | 0.000 |
//! | red shirt | 190, 35, 40 | 5.07 | 1.9° | 0.82 | **1.000** |
//!
//! Skin sits at 1.3–1.7, natural lips at 2.06, red-eye at 4.2–5.5: a
//! threshold at 2→3 has a wide margin on both sides, and `R − max(G, B)`
//! does not separate nearly as well (skin 35–50 against a dim red-eye's 73).
//! But lipstick (3.58) and a red shirt (5.07) score like red-eye, so colour
//! alone CANNOT find a pupil. That is why this op takes a rectangle and why
//! it has a size gate: the colour test shapes the mask inside a pupil, the
//! geometry decides where a pupil is. There is deliberately no whole-image
//! mode.
//!
//! # The three gates
//!
//! ```text
//! ratio = R / max((G+B)/2, 1/255)      guard for black
//! S     = (max − min) / max            HSV saturation, 0 when max is 0
//! hue_d = angular distance of the HSV hue from 0°, in [0°, 180°]
//! c = smoothstep(2.0, 3.0, ratio) · smoothstep(0.35, 0.55, S)
//!     · (1 − smoothstep(20°, 40°, hue_d))
//! ```
//!
//! `c_ratio` kills all skin and natural lips (2.06 → 0.9 % coverage, an
//! invisible correction) while passing every red-eye sample at full
//! strength; `c_sat` kills the specular catchlight (S = 0.02) and the sclera
//! (0.06), which is the difference between a corrected eye and a dead one;
//! `c_hue` kills a warm-but-not-red pixel, and incidentally rejects animal
//! flash-eye, which is green or yellow — out of scope by design, since
//! widening the hue gate to cover it would re-admit skin. The three
//! multiply, so a sample must fail none.
//!
//! # The correction
//!
//! `R' = R + c·((G+B)/2 − R)` neutralises the red to the level of the other
//! two, then every channel darkens: `C'' = C'·(1 − c·(1 − d))` with
//! `d = 1 − 0.8·darken`, so `darken` 0.5 gives Photoshop's `d = 0.6` and
//! `darken` 0 neutralises only. `(G+B)/2` is the balanced neutral target;
//! `min(G, B)` is occasionally too dark and `G` alone biases a blue-cast
//! pupil green. Worked: (220, 40, 45) → (26, 24, 27) at `darken` 0.5 — a
//! believable dark grey pupil, not a flat black hole, because the residual
//! G/B difference survives — and (255, 60, 60) → (36, 36, 36). The
//! catchlight comes out BIT-IDENTICAL, because its `c` is 0.
//!
//! Not routed through `blend::LUMA_*`: this is `(G+B)/2`, the two channels
//! red-eye collapses, not a luminance.
//!
//! # The size gate
//!
//! Inside the rectangle, 4-connected components of `c > 0.2` are found, and
//! a component is corrected only if BOTH of these hold:
//!
//! 1. its bounding box's larger side is at most `pupil_size` times the
//!    rectangle's **shorter** side, and
//! 2. it does not reach all four sides of the rectangle.
//!
//! `pupil_size` defaults to 1.0 (100 %) at every caller: the documented
//! gesture is a TIGHT rectangle over one eye, where the red iris spans
//! 40–90 % of the short side, so a smaller default would reject the very
//! drag the tool asks for. Its job is to spare a red shirt or lipstick
//! caught by a sloppy rectangle — the user turns it DOWN when something red
//! got caught, and that is the only reason to touch it.
//!
//! Rule 2 is what keeps the default from being a no-op, and it was added
//! because it was one: a component is clipped to the rectangle, so its
//! larger side can never exceed the rectangle's LARGER side, and on a
//! square rectangle it can never exceed the shorter one either — measured,
//! a 70 x 70 rectangle dragged over a red cloud corrected 100 % of its
//! 4900 pixels at the default and left a hard-edged desaturated square
//! (mean |grad luma| across the rectangle's edge 2.9 before, 27 after,
//! against 1.9 inside it). Rule 2 refuses that case outright — a rectangle
//! wholly inside one red region is a window onto something bigger, and
//! there is no pupil in it to find — while it cannot reject a plausible
//! drag: a component reaching all four sides means the rectangle is inside
//! the red, not around it. It is deliberately the WEAKEST form of that
//! test. A red region that fills most but not all of the rectangle still
//! passes at 100 %, and turning Pupil Size down is how the user says so.
//!
//! Kept components are feathered 1 px so the corrected region has no
//! staircase.
//!
//! The colour numbers are the document's own stored values — a sampled
//! colour converts nowhere. Under a wide-gamut profile the thresholds shift
//! slightly; the margin between skin at 1.7 and red-eye at 4.2 absorbs it.

use crate::doc::RzDocument;
use crate::doc_lock::EditKind;
use crate::doc_select::feather_mask;

/// Coverage above which a pixel joins a pupil candidate component. Low
/// enough to catch a pupil's soft rim (where the ratio gate is ramping),
/// high enough that natural lips (0.009) can never seed one.
const SEED_COVERAGE: f32 = 0.2;

impl RzDocument {
    /// Desaturates flash red inside a canvas rect on layer `idx`.
    ///
    /// The rect is `(x, y, w, h)` in canvas pixels and is clipped to the
    /// canvas; `pupil_size` (a fraction of the clipped rect's shorter side,
    /// clamped to [0.01, 1.0], default 1.0) is the size gate above, and
    /// `darken` (clamped to [0, 1], 0.5 = Photoshop's default) is how far
    /// the corrected pixels drop toward black. Layer alpha is never touched
    /// and fully transparent pixels are skipped.
    ///
    /// Domain refusals (`None`): out-of-range `idx`; non-finite parameters;
    /// an empty rect or one entirely off-canvas; a layer extent that misses
    /// the rect; nothing red at all inside the rect; no red component the
    /// rect both CONTAINS and admits under `pupil_size` (a DISTINCT refusal
    /// from "nothing red" — the callers say so, naming `pupil_size`); no
    /// byte moving; or a GROUP index, which has no pixels of its own. A
    /// PIXELS edit under `doc_lock`.
    // The parameter list deliberately mirrors `rz_doc_red_eye_layer`'s C
    // signature one-for-one; bundling them into a struct would only move
    // the count somewhere else.
    #[allow(clippy::too_many_arguments)]
    pub fn red_eye_layer(
        &self,
        idx: usize,
        x: i32,
        y: i32,
        w: u32,
        h: u32,
        pupil_size: f32,
        darken: f32,
    ) -> Option<Self> {
        self.under_locks(idx, EditKind::Pixels, |doc| {
            doc.red_eye_layer_unlocked(idx, x, y, w, h, pupil_size, darken)
        })
    }

    /// The body of [`Self::red_eye_layer`], outside the lock gate. Split out
    /// only so the gate is one line; that method is its only caller.
    #[allow(clippy::too_many_arguments)]
    fn red_eye_layer_unlocked(
        &self,
        idx: usize,
        x: i32,
        y: i32,
        w: u32,
        h: u32,
        pupil_size: f32,
        darken: f32,
    ) -> Option<Self> {
        let layer = self.raster_layer(idx)?;
        if !pupil_size.is_finite() || !darken.is_finite() || w == 0 || h == 0 {
            return None;
        }
        // Clip the rect to the canvas, in i64 so an extreme origin cannot
        // wrap.
        let x0 = i64::from(x).max(0);
        let y0 = i64::from(y).max(0);
        let x1 = (i64::from(x) + i64::from(w)).min(i64::from(self.width));
        let y1 = (i64::from(y) + i64::from(h)).min(i64::from(self.height));
        if x0 >= x1 || y0 >= y1 {
            return None;
        }
        let (rw, rh) = ((x1 - x0) as usize, (y1 - y0) as usize);
        let pupil_size = pupil_size.clamp(0.01, 1.0);
        let darken = darken.clamp(0.0, 1.0);

        let (lw, lh) = layer.pixels.dimensions();
        let (off_x, off_y) = (i64::from(layer.offset.0), i64::from(layer.offset.1));
        let raw: &[u8] = &layer.pixels;
        // Rect pixel -> byte index of the layer pixel under it.
        let layer_byte = |rx: usize, ry: usize| -> Option<usize> {
            let lx = x0 + rx as i64 - off_x;
            let ly = y0 + ry as i64 - off_y;
            if lx < 0 || ly < 0 || lx >= i64::from(lw) || ly >= i64::from(lh) {
                return None;
            }
            Some(((ly as u64 * u64::from(lw) + lx as u64) * 4) as usize)
        };

        let mut coverage = vec![0f32; rw * rh];
        let mut any_red = false;
        for ry in 0..rh {
            for rx in 0..rw {
                let Some(di) = layer_byte(rx, ry) else {
                    continue;
                };
                if raw[di + 3] == 0 {
                    continue;
                }
                let c = redness(raw[di], raw[di + 1], raw[di + 2]);
                coverage[ry * rw + rx] = c;
                any_red |= c > SEED_COVERAGE;
            }
        }
        if !any_red {
            return None;
        }
        let mut mask = pupil_mask(&coverage, rw, rh, pupil_size);
        if !mask.iter().any(|v| *v > 0) {
            // Something was red, but nothing was pupil-shaped.
            return None;
        }
        // A 1 px feather so the corrected region has no staircase — the
        // same primitive selection feathering uses.
        feather_mask(&mut mask, rw as u32, rh as u32, 1.0);

        let d = 1.0 - 0.8 * darken;
        let mut pixels = (*layer.pixels).clone();
        let out: &mut [u8] = &mut pixels;
        let mut changed = false;
        for ry in 0..rh {
            for rx in 0..rw {
                let i = ry * rw + rx;
                let weight = coverage[i] * f32::from(mask[i]) / 255.0;
                if weight <= 0.0 {
                    continue;
                }
                let Some(di) = layer_byte(rx, ry) else {
                    continue;
                };
                if out[di + 3] == 0 {
                    continue;
                }
                let rgb = [
                    f32::from(out[di]),
                    f32::from(out[di + 1]),
                    f32::from(out[di + 2]),
                ];
                let neutral = (rgb[1] + rgb[2]) * 0.5;
                let corrected = [rgb[0] + weight * (neutral - rgb[0]), rgb[1], rgb[2]];
                for (c, value) in corrected.iter().enumerate() {
                    let darkened = value * (1.0 - weight * (1.0 - d));
                    let new = (darkened.clamp(0.0, 255.0) + 0.5).floor() as u8;
                    if new != out[di + c] {
                        out[di + c] = new;
                        changed = true;
                    }
                }
            }
        }
        if !changed {
            // Identity result: refuse rather than mint an unchanged copy.
            return None;
        }
        self.with_layer_pixels(idx, pixels)
    }
}

/// The three-gate red-eye coverage of one straight RGB byte triple, in
/// [0, 1]. See the module doc for the thresholds and the measurements
/// behind them.
fn redness(r: u8, g: u8, b: u8) -> f32 {
    let (r, g, b) = (
        f32::from(r) / 255.0,
        f32::from(g) / 255.0,
        f32::from(b) / 255.0,
    );
    let mean_gb = (g + b) * 0.5;
    let ratio = r / mean_gb.max(1.0 / 255.0);
    let max = r.max(g).max(b);
    let min = r.min(g).min(b);
    let chroma = max - min;
    let saturation = if max > 0.0 { chroma / max } else { 0.0 };
    // HSV hue in degrees, then its angular distance from pure red.
    let hue = if chroma <= 0.0 {
        0.0
    } else if max == r {
        60.0 * (((g - b) / chroma) % 6.0)
    } else if max == g {
        60.0 * ((b - r) / chroma + 2.0)
    } else {
        60.0 * ((r - g) / chroma + 4.0)
    };
    let hue_d = {
        let h = hue.rem_euclid(360.0);
        h.min(360.0 - h)
    };
    smoothstep(2.0, 3.0, ratio)
        * smoothstep(0.35, 0.55, saturation)
        * (1.0 - smoothstep(20.0, 40.0, hue_d))
}

/// Hermite ramp `t²(3 − 2t)` between `a` and `b`. The same remap
/// `doc_select::smooth_mask` applies to a coverage plane; that copy is a
/// byte-plane pass with `t = v/255` and no edge pair, so it cannot be called
/// with thresholds and this parametrized form is the deliberate second
/// spelling of the one curve.
fn smoothstep(a: f32, b: f32, x: f32) -> f32 {
    if b <= a {
        return if x >= b { 1.0 } else { 0.0 };
    }
    let t = ((x - a) / (b - a)).clamp(0.0, 1.0);
    t * t * (3.0 - 2.0 * t)
}

/// A 0/255 mask over the rect of every 4-connected component of
/// `coverage > SEED_COVERAGE` whose bounding box's larger side fits within
/// `pupil_size` times the rect's shorter side AND does not reach all four
/// sides of the rect (the module doc's two rules). The BFS mirrors
/// `doc_select::grow_region` (`doc_select.rs`), the master copy of this
/// walk; it differs only in its predicate (redness instead of colour
/// similarity).
fn pupil_mask(coverage: &[f32], rw: usize, rh: usize, pupil_size: f32) -> Vec<u8> {
    let limit = pupil_size * rw.min(rh) as f32;
    let mut seen = vec![false; rw * rh];
    let mut mask = vec![0u8; rw * rh];
    let mut queue = std::collections::VecDeque::new();
    let mut component: Vec<usize> = Vec::new();
    for start in 0..rw * rh {
        if seen[start] || coverage[start] <= SEED_COVERAGE {
            continue;
        }
        seen[start] = true;
        queue.push_back(start);
        component.clear();
        let (mut x0, mut y0) = (usize::MAX, usize::MAX);
        let (mut x1, mut y1) = (0usize, 0usize);
        while let Some(i) = queue.pop_front() {
            component.push(i);
            let (x, y) = (i % rw, i / rw);
            x0 = x0.min(x);
            y0 = y0.min(y);
            x1 = x1.max(x);
            y1 = y1.max(y);
            let neighbors = [
                (x > 0, i.wrapping_sub(1)),
                (x + 1 < rw, i + 1),
                (y > 0, i.wrapping_sub(rw)),
                (y + 1 < rh, i + rw),
            ];
            for (inside, q) in neighbors {
                if !inside || seen[q] || coverage[q] <= SEED_COVERAGE {
                    continue;
                }
                seen[q] = true;
                queue.push_back(q);
            }
        }
        let side = (x1 - x0 + 1).max(y1 - y0 + 1) as f32;
        if side > limit {
            continue;
        }
        // Rule 2 (module doc): a component that reaches all four sides of
        // the rect is not a pupil — the rect is a window onto something
        // bigger. Without this the default `pupil_size` of 1.0 could never
        // reject anything on a square rect, since a clipped component's
        // larger side is at most the rect's larger side.
        if x0 == 0 && y0 == 0 && x1 == rw - 1 && y1 == rh - 1 {
            continue;
        }
        for &i in &component {
            mask[i] = 255;
        }
    }
    mask
}
