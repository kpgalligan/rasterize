//! PatchMatch inpainting: the ONE nearest-neighbour search, pyramid and vote
//! behind Content-Aware Fill and the Spot Healing Brush.
//!
//! Barnes, Shechtman, Finkelstein & Goldman, *PatchMatch* (SIGGRAPH 2009) for
//! the randomized correspondence search; Wexler, Shechtman & Irani, *Space-
//! Time Completion of Video* (PAMI 2007) for the EM formulation — search a
//! nearest-neighbour field for every patch that overlaps the hole, then vote
//! the hole's colours back from what those patches matched, and repeat.
//!
//! Free functions and plain buffers, no `RzDocument` knowledge: `doc_inpaint`
//! owns the document, the window, the caps and the composition with
//! `poisson`; this module owns the arithmetic. The half of that arithmetic
//! which moves per TARGET rather than per level — the field itself, its
//! propagation and random search, the patch distance and the vote — is
//! `patchmatch_nnf`; every parameter and every reason for one is here.
//!
//! # The parameters, and why each is what it is
//!
//! | parameter | value | why |
//! |---|---|---|
//! | patch side [`PATCH`] | 7 | Barnes' own inpainting value. Odd, so a patch has a centre. Larger keeps more structure and is `O(P²)` slower and needs a wider ring; 5 frees the fill to invent texture that is not in the picture. |
//! | distance | SSD over RGB, `u32` | exact in integers (`49·3·255² = 9.56e6` fits with room), and with the incumbent passed in for early termination (`patchmatch_nnf`) it is 3–5× cheaper than the naive form. Alpha is NOT in the distance: a source patch containing a pixel too transparent to carry colour (`doc_inpaint`'s 50 % rule) is inadmissible instead. |
//! | PatchMatch iterations | [`FIRST_ITERATIONS`] = 5, then [`WARM_ITERATIONS`] = 2 | the paper's field is largely converged after 4–5 sweeps, most of it in the first two; every later search at the same level starts from the previous field and an image that barely moved, so two suffice. |
//! | random-search ratio | [`SEARCH_ALPHA`] = 1/2 | the paper's value: radii `w, w/2, w/4 … 1`, `floor(log₂ w) + 1` samples. The large radii escape local minima, the small ones do the refinement propagation cannot. |
//! | pyramid factor | 2, at most [`MAX_LEVELS`] = 8 levels | √2 is smoother at twice the levels and buys nothing here. Coarsening stops while the hole is still `2·PATCH` across, the window is down to `4·PATCH`, or the hole's WIDEST margin to the window's edge is down to `2·PATCH` ([`should_coarsen`]) — below that the coarse problem is noise, and the hole must survive to BE the thing the coarsest level solves. |
//! | EM iterations | 10 coarsest / 5 middle / 3 finest ([`em_iterations`]) | the coarsest level decides the structure and is nearly free; the finest mostly refines and every iteration there is the expensive one. The finest count is a measured 3, not the customary 2 — see [`em_iterations`]. A single-level run is the coarsest, so it takes 10. |
//! | vote | similarity-weighted mean, always | see below. |
//!
//! # The vote is a weighted mean at every step — never winner-take-all
//!
//! Every pixel of the hole is covered by up to `P²` target patches, and its
//! new colour is `Σ wᵢ·Sᵢ / Σ wᵢ` with `wᵢ = exp(−Dᵢ / 2σ²)` and `σ²` the 25th
//! percentile of those patches' own distances (Wexler's rule), floored at 1
//! so a perfect match cannot divide by zero. The weights are computed
//! against the smallest distance at that pixel rather than against zero —
//! `exp(−(Dᵢ − D_min)/2σ²)` — which is the same weighted mean up to a common
//! factor and cannot underflow to an all-zero denominator.
//!
//! The tempting last step is winner-take-all on the finest level's final
//! iteration, "for crispness". It is not offered, and the reason is
//! structural: argmin voting hands adjacent hole pixels colours from
//! unrelated parts of the source, and the Poisson step that follows adds a
//! *harmonic* — hence maximally smooth — field, so by construction it cannot
//! remove an interior discontinuity. The crispness would be bought with
//! visible tearing inside the fill that nothing downstream can repair.
//!
//! # Sources: reject, never clamp
//!
//! A source patch origin is admissible only when every one of its `P × P`
//! pixels is valid — not part of any hole, solid enough to carry colour, and
//! inside the sampling ring — tested in `O(1)` per origin against the integral
//! image of the valid plane ([`sources`]). A propagation or random-search candidate that is not
//! admissible is SKIPPED, leaving the incumbent; clamping it to the nearest
//! admissible origin would pile candidates onto the ring's inner edge and
//! draw a visible seam along it.
//!
//! Two counts bound that list. Below [`min_origins`] — `max(256, area/16)`,
//! proportional because 256 is a floor for "can this run at all", not for
//! "will it look like anything" — `doc_inpaint` widens the ring and asks
//! again. Above [`MAX_ORIGINS`] the list is thinned by taking every `k`-th
//! entry, `k = ceil(n / MAX_ORIGINS)`; the stride is stated here because it
//! CHANGES RESULTS: it moves the random initialization, not the search, which
//! may still reach any admissible origin.
//!
//! # The coarsest level's initialization is the onion peel
//!
//! The masked reduction ([`reduce`]) erodes the hole by one coarse pixel a
//! level and the pyramid stops while the hole is still 7–14 px across, so the
//! hole is never erased and something has to put a first colour in it.
//! [`onion_peel`] does: unknown pixels are filled in increasing order of the
//! signed distance field — outermost first — each taking the mean of its
//! already-known 8-neighbours, and a component that reaches no known pixel at
//! all takes the ring's mean colour. The order is a total order on
//! `(distance, y, x)`, so this is deterministic, and since the coarsest level
//! decides the structure of the whole fill, that determinism is the whole
//! result's.
//!
//! # Determinism
//!
//! Every random draw comes from `rng::SplitMix64::at`, addressed by the caller's
//! seed and the position asking for it (level, sweep, target id), so no
//! value depends on how many draws came before it. The SWEEP is counted
//! across the level and not within one `Nnf::search` call: an EM iteration
//! that re-used its predecessor's address would re-test the identical
//! candidate offsets, which is a search that has stopped searching — the bug
//! that made nine of the coarsest level's ten iterations pure propagation.
//! Fixing it measurably improved the fill: over six seeds on a 200 px hole in
//! a structured field, the mean reconstruction error fell from 6.57 to 4.90
//! code values in the middle of the frame and 8.12 to 7.19 at its edge.
//! Distance ties are broken by the lowest `dy`, then `dx`. The same seed
//! therefore gives byte-identical output, which `content_aware_tests`
//! asserts.
//!
//! # Measured cost
//!
//! The search dominates: `targets × iterations × 13 candidates`, each
//! candidate an SSD over at most 147 channels with early termination. On this
//! machine (`--release`), inside `doc_inpaint`'s full driver, a 300 × 300 hole
//! in a 2000 × 1500 document costs 0.53 s of inpainting and a hole at the
//! one-megapixel cap costs 6.1 s; the full table, and the split against the
//! Poisson solve that follows, are in `doc_inpaint`'s module doc, which is
//! where the caps that bound them live.

/// Patch side in pixels. Odd, so a patch has a centre.
pub(crate) const PATCH: usize = 7;
/// `PATCH²`, the full sample count of an unclipped patch.
pub(crate) const PATCH_AREA: u32 = (PATCH * PATCH) as u32;
/// Hard ceiling on the pyramid depth.
pub(crate) const MAX_LEVELS: usize = 8;
/// Random initialization draws from at most this many admissible origins;
/// beyond it the list is strided (see the module doc).
pub(crate) const MAX_ORIGINS: usize = 1_000_000;

/// One pyramid level's image and masks. Everything is window-sized and in
/// window coordinates.
pub(crate) struct Plane {
    /// Width in pixels.
    pub(crate) w: usize,
    /// Height in pixels.
    pub(crate) h: usize,
    /// Straight RGB, 3 bytes a pixel: the current estimate, which the vote
    /// rewrites inside the hole and never touches outside it.
    pub(crate) rgb: Vec<u8>,
    /// The pixels this fill re-estimates.
    pub(crate) hole: Vec<bool>,
    /// The pixels carrying real colour: not part of ANY hole (another
    /// component's is unknown too) and solid in the sampled image — alpha at
    /// or over the coverage threshold, not necessarily 255, since alpha here
    /// only answers whether there is colour and the RGB beside it is
    /// straight.
    pub(crate) data: Vec<bool>,
}

impl Plane {
    /// The hole's bounding box as `(x0, y0, x1, y1)` inclusive, or `None`
    /// when the hole is empty at this level (the masked reduction can erode
    /// a thin hole away entirely, which is exactly what it is for).
    pub(crate) fn hole_box(&self) -> Option<(usize, usize, usize, usize)> {
        let (mut x0, mut y0) = (usize::MAX, usize::MAX);
        let (mut x1, mut y1) = (0usize, 0usize);
        let mut any = false;
        for (i, inside) in self.hole.iter().enumerate() {
            if !*inside {
                continue;
            }
            let (x, y) = (i % self.w, i / self.w);
            any = true;
            x0 = x0.min(x);
            y0 = y0.min(y);
            x1 = x1.max(x);
            y1 = y1.max(y);
        }
        any.then_some((x0, y0, x1, y1))
    }

    /// Raster-ordered indices of every pixel the mask marks — the write list
    /// the vote takes.
    pub(crate) fn indices(mask: &[bool]) -> Vec<u32> {
        mask.iter()
            .enumerate()
            .filter_map(|(i, m)| m.then_some(i as u32))
            .collect()
    }
}

/// Whether `plane` should be coarsened once more. Three conditions, and the
/// third is the one that is easy to get backwards:
///
/// - the hole must still be wider than two patches, or a coarse level cannot
///   see its shape at all;
/// - the window must still be wider than four, or there is no room for a
///   source patch to move;
/// - and the WIDEST margin between the hole's box and the window's edge must
///   still be wider than two patches. Halving it leaves one patch, which is
///   the last scale at which a complete source patch fits outside the hole —
///   below it the coarse level has no admissible origin whatever, and a
///   pyramid built past that point simply stops contributing.
///
/// The widest margin, emphatically not the narrowest. The window is the
/// hole's box padded by the ring and CLAMPED to the canvas, so a hole
/// touching an image border has a margin of zero on that side however wide
/// the band on the other three is. Taking the minimum therefore refused to
/// build a pyramid at all for anything within `2·PATCH` of an edge — every
/// corner and frame-edge fill — and, since a single-level run IS the coarsest
/// (see [`em_iterations`]), the finest and most expensive level then ran the
/// 10-iteration coarsest schedule. Measured on a structured texture at the
/// automatic ring: a 300 x 300 hole flush with the left edge of a
/// 1400 x 1400 canvas cost 1.66 s against 0.71 s for the same hole centred,
/// with 2.9x the mean reconstruction error, and the megapixel cap on a
/// 2600 x 2600 canvas cost 19.4 s against 8.5 s. With the widest margin those
/// pairs are 0.69 / 0.71 s and 8.1 / 8.5 s.
///
/// One margin wider than two patches is one band the whole length (or height)
/// of the window in which a complete coarse patch fits, which is exactly what
/// the justification above asks for; a level that turns out to be starved
/// anyway is handled where it is discovered, by
/// `inpaint_em::inpaint_plane` skipping it, because a coarse level is an
/// accelerator and never a requirement.
///
/// One shape still runs single-level at full resolution, and it is the only
/// one left: a hole within two patches of ALL FOUR borders — a selection
/// covering the whole picture but for a thin frame. There the ring has
/// almost nothing to sample from in any case, so the result is poor for a
/// reason no pyramid would fix.
pub(crate) fn should_coarsen(plane: &Plane) -> bool {
    let Some((x0, y0, x1, y1)) = plane.hole_box() else {
        return false;
    };
    let extent = (x1 - x0 + 1).max(y1 - y0 + 1);
    let margin = x0.max(y0).max(plane.w - 1 - x1).max(plane.h - 1 - y1);
    extent > 2 * PATCH && plane.w.min(plane.h) > 4 * PATCH && margin > 2 * PATCH
}

/// EM iterations for the level `from_coarsest` steps below the top of a
/// pyramid `levels` deep: 10 at the coarsest, 3 at the finest, 5 between. A
/// single-level run IS the coarsest and takes 10 — it has no coarser level to
/// have decided its structure.
///
/// The finest count is 3 and not the 2 this started with, and the reason is a
/// measurement. A box reduction can alias a high-frequency texture away
/// entirely — period-4 stripes reduce to a CONSTANT whenever the window's
/// origin is odd — and the finest level then has to invent the structure
/// itself. That takes three votes, not two: one to see the blurry
/// prolongation, one to commit the structure the first vote invented, and one
/// to settle the field against it. Measured on exactly that case (a 16 x 16
/// hole in period-4 stripes at an odd window origin): at 2 the fill comes back
/// visibly muddled, at 3 it is byte-exact, and 4 and 5 change nothing. The
/// finest level is the expensive one, so the count is 3 and not more.
pub(crate) fn em_iterations(from_coarsest: usize, levels: usize) -> u32 {
    if from_coarsest == 0 {
        10
    } else if from_coarsest + 1 == levels {
        3
    } else {
        5
    }
}

/// Halves a plane with a VALIDITY-WEIGHTED box mean: each coarse pixel is the
/// mean of its data-carrying children only, so the hole's filler colour never
/// contaminates a coarse pixel; a coarse pixel carries data when ANY child
/// does, and is hole only when EVERY child is hole. That asymmetry is the
/// point — it erodes the hole by one coarse pixel a level (which is what
/// makes a coarse level solvable) while keeping every scrap of real colour.
///
/// `doc_plane::box_reduced` is the master copy of the plain box mean and
/// documents the rounding; it cannot be called here — it is a single-channel
/// u8 reducer with no validity weighting and no mask to carry — so this is
/// the masked variant, named against it as the "one implementation per
/// algorithm" rule requires.
pub(crate) fn reduce(fine: &Plane) -> Plane {
    let (w, h) = (fine.w.div_ceil(2), fine.h.div_ceil(2));
    let mut rgb = vec![0u8; w * h * 3];
    let mut hole = vec![false; w * h];
    let mut data = vec![false; w * h];
    for cy in 0..h {
        for cx in 0..w {
            let i = cy * w + cx;
            let (mut children, mut with_data, mut in_hole) = (0u32, 0u32, 0u32);
            let mut sum = [0u32; 3];
            let mut any = [0u32; 3];
            for dy in 0..2 {
                for dx in 0..2 {
                    let (fx, fy) = (cx * 2 + dx, cy * 2 + dy);
                    if fx >= fine.w || fy >= fine.h {
                        continue;
                    }
                    let j = fy * fine.w + fx;
                    let px = &fine.rgb[j * 3..j * 3 + 3];
                    children += 1;
                    for (a, v) in any.iter_mut().zip(px) {
                        *a += u32::from(*v);
                    }
                    if fine.data[j] {
                        with_data += 1;
                        for (s, v) in sum.iter_mut().zip(px) {
                            *s += u32::from(*v);
                        }
                    }
                    if fine.hole[j] {
                        in_hole += 1;
                    }
                }
            }
            data[i] = with_data > 0;
            hole[i] = children > 0 && in_hole == children;
            // With no data-carrying child the mean of all of them is a
            // placeholder: the pixel is either hole (about to be
            // re-estimated) or has no colour at all (fully transparent), and
            // neither is ever read as a source.
            let (total, count) = if with_data > 0 {
                (sum, with_data)
            } else {
                (any, children.max(1))
            };
            for (v, t) in rgb[i * 3..i * 3 + 3].iter_mut().zip(&total) {
                *v = ((*t + count / 2) / count).min(255) as u8;
            }
        }
    }
    Plane {
        w,
        h,
        rgb,
        hole,
        data,
    }
}

/// Writes the bilinear upsample of `coarse`'s colours into `fine`'s hole
/// pixels, leaving every pixel that carries real data exactly as it is.
///
/// Coarse cell centres map as `xc = x/2 − 1/4` (the same mapping
/// `poisson::prolongate` uses). A coarse sample with neither data nor hole
/// carries no colour and is dropped, the remaining weights renormalized, so a
/// transparent corner of the window cannot drag the fill toward black.
pub(crate) fn prolongate(coarse: &Plane, fine: &mut Plane) {
    for y in 0..fine.h {
        for x in 0..fine.w {
            let i = y * fine.w + x;
            if !fine.hole[i] {
                continue;
            }
            let xc = x as f32 * 0.5 - 0.25;
            let yc = y as f32 * 0.5 - 0.25;
            let (x0, y0) = (xc.floor(), yc.floor());
            let (fx, fy) = (xc - x0, yc - y0);
            let (x0, y0) = (x0 as i64, y0 as i64);
            let mut acc = [0f32; 3];
            let mut weight = 0f32;
            for (dx, dy, wx, wy) in [
                (0i64, 0i64, 1.0 - fx, 1.0 - fy),
                (1, 0, fx, 1.0 - fy),
                (0, 1, 1.0 - fx, fy),
                (1, 1, fx, fy),
            ] {
                let (sx, sy) = (x0 + dx, y0 + dy);
                if sx < 0 || sy < 0 || sx >= coarse.w as i64 || sy >= coarse.h as i64 {
                    continue;
                }
                let j = sy as usize * coarse.w + sx as usize;
                if !(coarse.data[j] || coarse.hole[j]) {
                    continue;
                }
                let k = wx * wy;
                for (a, v) in acc.iter_mut().zip(&coarse.rgb[j * 3..j * 3 + 3]) {
                    *a += k * f32::from(*v);
                }
                weight += k;
            }
            if weight <= 0.0 {
                continue;
            }
            for (v, a) in fine.rgb[i * 3..i * 3 + 3].iter_mut().zip(&acc) {
                *v = (*a / weight + 0.5).floor().clamp(0.0, 255.0) as u8;
            }
        }
    }
}

/// Fills every hole pixel that carries no colour yet, outermost first: each
/// takes the mean of its already-known 8-neighbours, and a pixel that reaches
/// none at all takes `fallback` (the sampling ring's mean colour). See the
/// module doc — this is the coarsest level's initialization, not a fallback
/// path, and its determinism is the whole fill's.
///
/// `sdf` is the signed distance to the hole's contour, positive INSIDE
/// (`doc_select::signed_distance_field`'s convention), so ascending order
/// walks the hole from its rim to its middle.
pub(crate) fn onion_peel(plane: &mut Plane, sdf: &[f32], fallback: [u8; 3]) {
    let mut order = Plane::indices(&plane.hole);
    order.sort_unstable_by(|a, b| {
        let (sa, sb) = (sdf[*a as usize], sdf[*b as usize]);
        sa.partial_cmp(&sb)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then(a.cmp(b))
    });
    let mut known = plane.data.clone();
    for p in order {
        let i = p as usize;
        let (x, y) = (i % plane.w, i / plane.w);
        let mut sum = [0u32; 3];
        let mut count = 0u32;
        for dy in -1i64..=1 {
            for dx in -1i64..=1 {
                let (nx, ny) = (x as i64 + dx, y as i64 + dy);
                if (dx == 0 && dy == 0)
                    || nx < 0
                    || ny < 0
                    || nx >= plane.w as i64
                    || ny >= plane.h as i64
                {
                    continue;
                }
                let j = ny as usize * plane.w + nx as usize;
                if !known[j] {
                    continue;
                }
                count += 1;
                for (s, v) in sum.iter_mut().zip(&plane.rgb[j * 3..j * 3 + 3]) {
                    *s += u32::from(*v);
                }
            }
        }
        let out = if count > 0 {
            [
                ((sum[0] + count / 2) / count) as u8,
                ((sum[1] + count / 2) / count) as u8,
                ((sum[2] + count / 2) / count) as u8,
            ]
        } else {
            fallback
        };
        plane.rgb[i * 3..i * 3 + 3].copy_from_slice(&out);
        known[i] = true;
    }
}

/// The admissible source origins of one level.
pub(crate) struct Sources {
    /// `true` at every origin whose whole `PATCH × PATCH` window is valid.
    /// Indexed over the origin grid, `ow × oh`.
    admissible: Vec<bool>,
    /// The same set as a list, possibly strided (see [`MAX_ORIGINS`]), for
    /// the `O(1)` random draw the initialization needs.
    origins: Vec<(u32, u32)>,
    ow: usize,
    oh: usize,
}

impl Sources {
    /// How many origins the random initialization may draw from.
    pub(crate) fn len(&self) -> usize {
        self.origins.len()
    }

    /// Whether the level has no complete source patch at all — the one
    /// starvation a caller cannot fill from and must refuse.
    pub(crate) fn is_empty(&self) -> bool {
        self.origins.is_empty()
    }

    /// The `i`-th admissible origin, for the random initialization's `O(1)`
    /// draw. `i` must be below [`Self::len`].
    pub(crate) fn origin(&self, i: usize) -> (u32, u32) {
        self.origins[i]
    }

    /// Whether a complete source patch may start at `(x, y)`.
    pub(crate) fn contains(&self, x: i32, y: i32) -> bool {
        x >= 0
            && y >= 0
            && (x as usize) < self.ow
            && (y as usize) < self.oh
            && self.admissible[y as usize * self.ow + x as usize]
    }
}

/// The admissible origins over `valid`, from the integral image of that
/// plane: a window is admissible iff its `PATCH × PATCH` box sums to `P²`,
/// one add and two subtracts per origin whatever the patch size.
pub(crate) fn sources(valid: &[bool], w: usize, h: usize) -> Sources {
    if w < PATCH || h < PATCH {
        return Sources {
            admissible: Vec::new(),
            origins: Vec::new(),
            ow: 0,
            oh: 0,
        };
    }
    // Row-major (w+1) x (h+1) prefix sums; u32 is ample, the window is capped
    // far below 2^32 pixels.
    let stride = w + 1;
    let mut integral = vec![0u32; stride * (h + 1)];
    for y in 0..h {
        let mut row = 0u32;
        for x in 0..w {
            row += u32::from(valid[y * w + x]);
            integral[(y + 1) * stride + x + 1] = integral[y * stride + x + 1] + row;
        }
    }
    let (ow, oh) = (w - PATCH + 1, h - PATCH + 1);
    let mut admissible = vec![false; ow * oh];
    let mut origins = Vec::new();
    for y in 0..oh {
        for x in 0..ow {
            let sum = integral[(y + PATCH) * stride + x + PATCH] + integral[y * stride + x]
                - integral[y * stride + x + PATCH]
                - integral[(y + PATCH) * stride + x];
            if sum == PATCH_AREA {
                admissible[y * ow + x] = true;
                origins.push((x as u32, y as u32));
            }
        }
    }
    if origins.len() > MAX_ORIGINS {
        // Stride the LIST, never the plane: the search may still reach any
        // admissible origin, only the random draw is thinned.
        let k = origins.len().div_ceil(MAX_ORIGINS);
        origins = origins.into_iter().step_by(k).collect();
    }
    Sources {
        admissible,
        origins,
        ow,
        oh,
    }
}

/// The origin count below which `doc_inpaint` widens the ring and asks again:
/// proportional to the hole, because 256 is a floor for "can this run at
/// all", not for "will it look like anything".
pub(crate) fn min_origins(hole_area: usize) -> usize {
    256.max(hole_area / 16)
}
