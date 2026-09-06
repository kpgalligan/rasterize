//! The nearest-neighbour field itself: the sparse target list, the
//! propagation-and-random-search sweep, the patch distance, and the
//! similarity-weighted vote that turns a field into pixels.
//!
//! The algorithm, its parameters and the reasons for them are documented once,
//! in `patchmatch`'s module doc; this module is the half of it that moves per
//! target rather than per level, split out because the two halves are the
//! natural banner sections of one 900-line file. [`Nnf`] is what a caller
//! holds: build it over a level's [`Plane`], [`Nnf::search`] it, and
//! [`Nnf::vote`] the result into the pixels it decides.

use crate::patchmatch::{Plane, Sources, PATCH, PATCH_AREA};
use crate::rng::SplitMix64;

/// PatchMatch iterations the first time a level is searched.
const FIRST_ITERATIONS: u32 = 5;
/// PatchMatch iterations for every later search at the same level, where the
/// field is already warm.
const WARM_ITERATIONS: u32 = 2;
/// The random search's radius ratio: `w, w/2, w/4, …, 1`.
const SEARCH_ALPHA: f32 = 0.5;

/// Target patch origins, sorted by `(y, x)`.
///
/// A target is any patch position whose window overlaps the hole. Its origin
/// may be as far as `PATCH − 1` above and left of the window, because a hole
/// against the canvas edge must still be covered: only the overlapping part
/// of such a patch is compared and its distance is scaled by
/// `P² / overlap`, while a SOURCE patch is always a complete window.
struct Targets {
    origins: Vec<(i32, i32)>,
    /// `[start, end)` in `origins` for extended row `y + PATCH − 1`.
    rows: Vec<(u32, u32)>,
    h_ext: usize,
}

impl Targets {
    /// Every patch origin whose window meets `hole`, found with two separable
    /// running counts (one horizontal, one vertical) rather than a `P × P`
    /// test per position.
    fn new(hole: &[bool], w: usize, h: usize) -> Targets {
        let (w_ext, h_ext) = (w + PATCH - 1, h + PATCH - 1);
        let mut row_any = vec![false; w_ext * h];
        for y in 0..h {
            let mut count = 0usize;
            for ex in 0..w_ext {
                if ex < w && hole[y * w + ex] {
                    count += 1;
                }
                if ex >= PATCH && hole[y * w + ex - PATCH] {
                    count -= 1;
                }
                row_any[y * w_ext + ex] = count > 0;
            }
        }
        let mut origins = Vec::new();
        let mut rows = vec![(0u32, 0u32); h_ext];
        let mut column = vec![0u32; w_ext];
        for (ey, row) in rows.iter_mut().enumerate() {
            if ey < h {
                for (c, any) in column
                    .iter_mut()
                    .zip(&row_any[ey * w_ext..(ey + 1) * w_ext])
                {
                    *c += u32::from(*any);
                }
            }
            if ey >= PATCH {
                let gone = (ey - PATCH) * w_ext;
                for (c, any) in column.iter_mut().zip(&row_any[gone..gone + w_ext]) {
                    *c -= u32::from(*any);
                }
            }
            let start = origins.len() as u32;
            let offset = PATCH as i32 - 1;
            for (ex, c) in column.iter().enumerate() {
                if *c > 0 {
                    origins.push((ex as i32 - offset, ey as i32 - offset));
                }
            }
            *row = (start, origins.len() as u32);
        }
        Targets {
            origins,
            rows,
            h_ext,
        }
    }

    fn len(&self) -> usize {
        self.origins.len()
    }

    /// The id of the target at `(x, y)`, if there is one.
    fn find(&self, x: i32, y: i32) -> Option<usize> {
        let ey = y + PATCH as i32 - 1;
        if ey < 0 || ey as usize >= self.h_ext {
            return None;
        }
        let (start, end) = self.rows[ey as usize];
        let slice = &self.origins[start as usize..end as usize];
        slice
            .binary_search_by(|o| o.0.cmp(&x))
            .ok()
            .map(|k| start as usize + k)
    }
}

/// The nearest-neighbour field of one pyramid level: one offset and its
/// distance per target patch, stored SPARSELY by target id.
///
/// Sparse and not a window-sized plane on purpose: a three-pixel scratch
/// running corner to corner has a bounding box of the whole photograph and a
/// few thousand targets, and this is what keeps the field's memory
/// proportional to the work rather than to the box.
pub(crate) struct Nnf {
    w: usize,
    h: usize,
    sources: Sources,
    targets: Targets,
    /// Offset from the target's origin to its matched source origin.
    off: Vec<(i32, i32)>,
    /// The offset's patch distance, scaled to a full patch.
    dist: Vec<u32>,
    seed: u64,
    level: u32,
    searches: u32,
}

impl Nnf {
    /// A field over `plane`'s hole, initialized either by upscaling `coarse`
    /// (`f_fine(2a) = 2·f_coarse(a)`, validated, random where it does not
    /// survive the finer scale) or, with no coarser level, entirely at
    /// random. `None` when the hole has no target patches or the level has no
    /// admissible source at all.
    pub(crate) fn new(
        plane: &Plane,
        sources: Sources,
        seed: u64,
        level: u32,
        coarse: Option<&Nnf>,
    ) -> Option<Nnf> {
        if sources.is_empty() {
            return None;
        }
        let targets = Targets::new(&plane.hole, plane.w, plane.h);
        if targets.origins.is_empty() {
            return None;
        }
        let off = targets
            .origins
            .iter()
            .enumerate()
            .map(|(id, &(tx, ty))| {
                let upscaled = coarse.and_then(|c| c.upscaled(tx, ty)).filter(|off| {
                    let (sx, sy) = (tx + off.0, ty + off.1);
                    sources.contains(sx, sy)
                });
                upscaled.unwrap_or_else(|| {
                    // Draw from the admissible list: O(1), never invalid, and
                    // no rejection loop that could spin.
                    let mut rng = SplitMix64::at(seed, u64::from(level), 0, id as u64);
                    let (ox, oy) = sources.origin(rng.below(sources.len()));
                    (ox as i32 - tx, oy as i32 - ty)
                })
            })
            .collect::<Vec<_>>();
        let mut nnf = Nnf {
            w: plane.w,
            h: plane.h,
            sources,
            targets,
            off,
            dist: Vec::new(),
            seed,
            level,
            searches: 0,
        };
        let dist = (0..nnf.targets.len())
            .map(|id| nnf.measure(plane, id, nnf.off[id]))
            .collect();
        nnf.dist = dist;
        Some(nnf)
    }

    /// This field's offset for the coarse target covering fine `(x, y)`,
    /// doubled — `None` when there is no such coarse target.
    fn upscaled(&self, x: i32, y: i32) -> Option<(i32, i32)> {
        let id = self.targets.find(x.div_euclid(2), y.div_euclid(2))?;
        let (dx, dy) = self.off[id];
        Some((dx * 2, dy * 2))
    }

    /// One E-step: refresh the distances against the image the last vote
    /// left, then propagate and random-search. Five iterations the first
    /// time this level is searched, two on every later call.
    pub(crate) fn search(&mut self, plane: &Plane) {
        // Owned for the refresh so the measurement can borrow the field it is
        // about to overwrite.
        let mut dist = std::mem::take(&mut self.dist);
        for (id, d) in dist.iter_mut().enumerate() {
            *d = self.measure(plane, id, self.off[id]);
        }
        self.dist = dist;
        let iterations = if self.searches == 0 {
            FIRST_ITERATIONS
        } else {
            WARM_ITERATIONS
        };
        // The sweep this search starts at, in the stream's own coordinate.
        // Every EM iteration at a level calls `search`, and each of them must
        // draw its OWN candidates: addressing the stream by `(level, it, id)`
        // alone gave iterations 2..10 of the coarsest level byte-identical
        // draws to iterations 0 and 1, so nine tenths of the schedule's random
        // search re-tested offsets that had already lost — exactly where the
        // module doc says the exploration matters most. Striding by
        // FIRST_ITERATIONS keeps every search's block of the stream disjoint
        // (no search runs more sweeps than that), and the address stays
        // positional, so the seed still fixes every draw.
        let sweep = u64::from(self.searches) * u64::from(FIRST_ITERATIONS);
        self.searches += 1;
        for it in 0..iterations {
            self.iterate(plane, it, sweep + u64::from(it) + 1);
        }
    }

    /// One PatchMatch sweep. Even iterations run in raster order and take
    /// candidates from the left and upper neighbours, odd ones run in reverse
    /// and take them from the right and lower — alternating, or information
    /// only ever flows down and right. Because the field stores OFFSETS, a
    /// neighbour's candidate is used verbatim: if the patch to my left
    /// matched somewhere good, the same offset here lands one pixel to the
    /// right of it, which is where a coherent region continues.
    /// `it` is the sweep's index WITHIN this search, which sets the scan
    /// direction; `draw` is its index within the level, which addresses the
    /// random search's stream (see [`Nnf::search`]).
    fn iterate(&mut self, plane: &Plane, it: u32, draw: u64) {
        let n = self.targets.len();
        let forward = it.is_multiple_of(2);
        for k in 0..n {
            let id = if forward { k } else { n - 1 - k };
            let (tx, ty) = self.targets.origins[id];
            let step = if forward { -1 } else { 1 };
            for (nx, ny) in [(tx + step, ty), (tx, ty + step)] {
                if let Some(neighbour) = self.targets.find(nx, ny) {
                    let candidate = self.off[neighbour];
                    self.consider(plane, id, candidate);
                }
            }
            // Random search: a geometric sequence of shrinking radii around
            // the CURRENT match, `w, w/2, … 1`. The wide draws escape a local
            // minimum; the narrow ones refine where propagation cannot.
            let mut rng = SplitMix64::at(self.seed, u64::from(self.level), draw, id as u64);
            let (vx, vy) = self.off[id];
            let (cx, cy) = ((tx + vx) as f32, (ty + vy) as f32);
            let mut radius = self.w.max(self.h) as f32;
            while radius >= 1.0 {
                let ox = cx + (rng.next_unit_f32() * 2.0 - 1.0) * radius;
                let oy = cy + (rng.next_unit_f32() * 2.0 - 1.0) * radius;
                self.consider(plane, id, (ox.floor() as i32 - tx, oy.floor() as i32 - ty));
                radius *= SEARCH_ALPHA;
            }
        }
    }

    /// Takes `off` for target `id` when it is admissible and strictly closer,
    /// or equally close with the lower `(dy, dx)` — a fixed tie-break, so the
    /// result cannot depend on the order candidates arrived in. An
    /// inadmissible candidate is skipped, never clamped (see the module doc).
    fn consider(&mut self, plane: &Plane, id: usize, off: (i32, i32)) {
        if off == self.off[id] {
            return;
        }
        let (tx, ty) = self.targets.origins[id];
        let (sx, sy) = (tx + off.0, ty + off.1);
        if !self.sources.contains(sx, sy) {
            return;
        }
        // +1 so an EQUAL distance is returned rather than early-terminated,
        // which is what makes the tie-break reachable.
        let limit = self.dist[id].saturating_add(1);
        let d = distance(plane, (tx, ty), (sx as usize, sy as usize), limit);
        let current = self.off[id];
        if d < self.dist[id] || (d == self.dist[id] && (off.1, off.0) < (current.1, current.0)) {
            self.off[id] = off;
            self.dist[id] = d;
        }
    }

    fn measure(&self, plane: &Plane, id: usize, off: (i32, i32)) -> u32 {
        let (tx, ty) = self.targets.origins[id];
        let (sx, sy) = (tx + off.0, ty + off.1);
        distance(plane, (tx, ty), (sx as usize, sy as usize), u32::MAX)
    }

    /// One M-step: the similarity-weighted mean of what every covering patch
    /// says about each pixel of `write` (a raster-ordered index list), into
    /// `out` — one RGB triple per entry, so the caller decides when the
    /// estimate replaces the image it was computed from.
    pub(crate) fn vote(&self, plane: &Plane, write: &[u32], out: &mut [[u8; 3]]) {
        let mut k = 0;
        while k < write.len() {
            let y = write[k] as usize / plane.w;
            let mut end = k + 1;
            while end < write.len() && write[end] as usize / plane.w == y {
                end += 1;
            }
            self.vote_row(plane, y, &write[k..end], &mut out[k..end]);
            k = end;
        }
    }

    /// One row of the vote. The `PATCH` contributing target rows are walked
    /// with a cursor pair each: origins are sorted by `x` within a row and
    /// the write list increases in `x`, so both ends only ever move forward
    /// and each pixel costs its own contributors and nothing more.
    fn vote_row(&self, plane: &Plane, y: usize, write: &[u32], out: &mut [[u8; 3]]) {
        // (first, past-the-last, row end) per contributing target row.
        let mut cursor = [(0u32, 0u32, 0u32); PATCH];
        for (j, c) in cursor.iter_mut().enumerate() {
            let (start, stop) = self.targets.rows[y + j];
            *c = (start, start, stop);
        }
        let mut dists = [0u32; PATCH * PATCH];
        let mut samples = [0u32; PATCH * PATCH];
        let mut sorted = [0u32; PATCH * PATCH];
        for (slot, &p) in write.iter().enumerate() {
            let x = (p as usize % plane.w) as i32;
            let mut count = 0usize;
            let mut lowest = u32::MAX;
            for (lo, hi, end) in cursor.iter_mut() {
                while *lo < *end && self.targets.origins[*lo as usize].0 < x - (PATCH as i32 - 1) {
                    *lo += 1;
                }
                *hi = (*hi).max(*lo);
                while *hi < *end && self.targets.origins[*hi as usize].0 <= x {
                    *hi += 1;
                }
                for id in *lo as usize..*hi as usize {
                    let (dx, dy) = self.off[id];
                    // The pixel this patch votes with is the one its offset
                    // maps THIS pixel to; the patch's own origin cancels.
                    let sample = (y as i32 + dy) as usize * plane.w + (x + dx) as usize;
                    dists[count] = self.dist[id];
                    samples[count] = sample as u32;
                    lowest = lowest.min(self.dist[id]);
                    count += 1;
                }
            }
            if count == 0 {
                out[slot].copy_from_slice(&plane.rgb[p as usize * 3..p as usize * 3 + 3]);
                continue;
            }
            sorted[..count].copy_from_slice(&dists[..count]);
            let quarter = count / 4;
            sorted[..count].select_nth_unstable(quarter);
            let inv = 1.0 / (2.0 * (sorted[quarter] as f32).max(1.0));
            let mut acc = [0f32; 3];
            let mut weight = 0f32;
            for (d, s) in dists[..count].iter().zip(&samples[..count]) {
                // Relative to the closest patch at this pixel: the same
                // weighted mean up to a common factor, and it cannot
                // underflow to an all-zero denominator.
                let t = (*d - lowest) as f32 * inv;
                if t > 30.0 {
                    continue;
                }
                let w = if t <= 0.0 { 1.0 } else { (-t).exp() };
                let at = *s as usize * 3;
                for (a, v) in acc.iter_mut().zip(&plane.rgb[at..at + 3]) {
                    *a += w * f32::from(*v);
                }
                weight += w;
            }
            for (v, a) in out[slot].iter_mut().zip(&acc) {
                *v = (*a / weight + 0.5).floor().clamp(0.0, 255.0) as u8;
            }
        }
    }
}

/// SSD over RGB between the target patch at `t` (which may hang off the
/// window; only the overlap is compared and the sum is scaled by
/// `P² / overlap` so distances stay comparable) and the complete source patch
/// at `s`, returning `u32::MAX` as soon as the running sum can no longer beat
/// `limit`. That early termination is the single biggest constant-factor win
/// in the whole search.
fn distance(plane: &Plane, t: (i32, i32), s: (usize, usize), limit: u32) -> u32 {
    let (tx, ty) = t;
    // Defensive: every assignment to the field validates its source origin
    // against the admissible plane first, so this can only fire on a future
    // edit that forgets to — but an out-of-range origin would index past the
    // buffer, and no input may panic.
    if plane.w < PATCH || plane.h < PATCH || s.0 > plane.w - PATCH || s.1 > plane.h - PATCH {
        return u32::MAX;
    }
    let x0 = (-tx).max(0) as usize;
    let y0 = (-ty).max(0) as usize;
    let x1 = (plane.w as i32 - tx).clamp(0, PATCH as i32) as usize;
    let y1 = (plane.h as i32 - ty).clamp(0, PATCH as i32) as usize;
    if x1 <= x0 || y1 <= y0 {
        return u32::MAX;
    }
    let count = ((x1 - x0) * (y1 - y0)) as u32;
    let raw_limit = if limit == u32::MAX {
        u32::MAX
    } else {
        (u64::from(limit) * u64::from(count))
            .div_ceil(u64::from(PATCH_AREA))
            .min(u64::from(u32::MAX)) as u32
    };
    let span = (x1 - x0) * 3;
    let mut acc = 0u32;
    for j in y0..y1 {
        let target = (((ty + j as i32) as usize) * plane.w + (tx + x0 as i32) as usize) * 3;
        let source = ((s.1 + j) * plane.w + s.0 + x0) * 3;
        let a = &plane.rgb[target..target + span];
        let b = &plane.rgb[source..source + span];
        for (p, q) in a.iter().zip(b) {
            let d = i32::from(*p) - i32::from(*q);
            acc += (d * d) as u32;
        }
        if acc >= raw_limit {
            return u32::MAX;
        }
    }
    if count == PATCH_AREA {
        acc
    } else {
        ((u64::from(acc) * u64::from(PATCH_AREA)) / u64::from(count)) as u32
    }
}
