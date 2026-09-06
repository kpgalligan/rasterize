//! The pyramid and EM loop one component's fill runs through: build the
//! levels, solve coarse to fine, and hand back the inpainted window and the
//! region the membrane solve is to run over.
//!
//! `doc_inpaint` owns the document, the window and the caps; `patchmatch` owns
//! the arithmetic and every parameter; this is the loop that puts them
//! together, split out of `doc_inpaint` because a driver and a policy are two
//! things. Nothing here knows about `RzDocument`.

use crate::doc_inpaint::{narrow_band_message, nothing_to_sample_message, Caller};
use crate::doc_select::{grow_mask, signed_distance_field};
use crate::inpaint_plan::RING_MIN;
use crate::patchmatch::{self, Plane};
use crate::patchmatch_nnf::Nnf;
use crate::poisson::COVERED_THRESHOLD;

/// The EM driver: a pyramid over `plane`, solved coarse to fine, returning
/// the inpainted RGB and the solve region (the hole grown by one pixel).
///
/// The returned RGB carries the hole AND that one-pixel outer ring, both
/// written by the vote. The ring is what makes the colour adaptation
/// possible: the membrane's boundary condition is `destination − source` on
/// the region's contour, so the source has to carry the inpaint's own
/// extension there, or the mismatch would be zero and the solve would have
/// nothing to correct.
pub(crate) fn inpaint_plane(
    plane: Plane,
    ring: f32,
    seed: u64,
    mut fine_sdf: Option<Vec<f32>>,
    caller: Caller,
) -> Result<(Vec<u8>, Vec<u8>), String> {
    let mut levels = vec![plane];
    while levels.len() < patchmatch::MAX_LEVELS {
        let last = &levels[levels.len() - 1];
        if !patchmatch::should_coarsen(last) {
            break;
        }
        let coarse = patchmatch::reduce(last);
        levels.push(coarse);
    }
    let depth = levels.len();
    let mut coarser: Option<Nnf> = None;
    let mut voted: Vec<[u8; 3]> = Vec::new();
    for level in (0..depth).rev() {
        let (fine, rest) = levels.split_at_mut(level + 1);
        let plane = &mut fine[level];
        // The caller has already measured the finest level's contour; every
        // coarser one is its own. The loop runs coarsest FIRST, so the take
        // has to be guarded rather than filtered — taking unconditionally and
        // filtering afterwards dropped the caller's vector on the first
        // iteration and recomputed the full-resolution transform at level 0.
        let sdf = if level == 0 { fine_sdf.take() } else { None }
            .unwrap_or_else(|| hole_distance(&plane.hole, plane.w, plane.h));
        // The ring is measured in THIS level's pixels and never narrower than
        // three patches: a band thinner than a patch has no admissible origin
        // at all, so the coarse levels of a deep pyramid would starve.
        let level_ring = (ring / (1 << level) as f32).max(RING_MIN);
        let (sources, valid) = build_sources(plane, &sdf, level_ring);
        if level + 1 == depth {
            let fallback = mean_colour(plane, &valid);
            patchmatch::onion_peel(plane, &sdf, fallback);
        } else {
            patchmatch::prolongate(&rest[0], plane);
        }
        if sources.is_empty() && level == 0 {
            // Two different nothings, and the caller can act on the
            // difference: no pixel to copy from at all, or pixels whose band
            // is thinner than one patch. `valid` is the plane the ring
            // widening ended on — by here it has already grown to the whole
            // window — so a non-empty one means the second.
            return Err(if valid.iter().any(|v| *v) {
                narrow_band_message(caller)
            } else {
                nothing_to_sample_message(caller)
            });
        }
        let Some(mut nnf) = Nnf::new(plane, sources, seed, level as u32, coarser.as_ref()) else {
            // Nothing to do at this level: either the reduction erased the
            // hole, or the hole leaves no room for a complete source patch at
            // this scale. Either way its estimate — the masked mean, or the
            // onion peel — is what the next finer level starts from, and a
            // COARSE level is an accelerator, never a requirement.
            coarser = None;
            continue;
        };
        let hole = Plane::indices(&plane.hole);
        voted.resize(hole.len(), [0u8; 3]);
        for _ in 0..patchmatch::em_iterations(depth - 1 - level, depth) {
            nnf.search(plane);
            nnf.vote(plane, &hole, &mut voted[..hole.len()]);
            for (k, &p) in hole.iter().enumerate() {
                let i = p as usize * 3;
                plane.rgb[i..i + 3].copy_from_slice(&voted[k]);
            }
        }
        coarser = Some(nnf);
    }

    let plane = &levels[0];
    let mut region: Vec<u8> = plane
        .hole
        .iter()
        .map(|c| if *c { 255 } else { 0 })
        .collect();
    grow_mask(&mut region, plane.w as u32, plane.h as u32, 1.0);
    let mut source = plane.rgb.clone();
    if let Some(nnf) = coarser.as_ref() {
        let write: Vec<u32> = region
            .iter()
            .enumerate()
            .filter_map(|(i, r)| (*r >= COVERED_THRESHOLD).then_some(i as u32))
            .collect();
        voted.resize(write.len(), [0u8; 3]);
        nnf.vote(plane, &write, &mut voted[..write.len()]);
        for (k, &p) in write.iter().enumerate() {
            let i = p as usize * 3;
            source[i..i + 3].copy_from_slice(&voted[k]);
        }
    }
    Ok((source, region))
}

/// The signed distance to the hole's contour over a window: positive inside,
/// negative outside, from `doc_select::signed_distance_field` — the crate's
/// ONE exact Euclidean transform, and the reason neither the ring nor the
/// onion peel needs a second one.
pub(crate) fn hole_distance(hole: &[bool], w: usize, h: usize) -> Vec<f32> {
    let mask: Vec<u8> = hole.iter().map(|c| if *c { 255 } else { 0 }).collect();
    signed_distance_field(&mask, w, h)
}

/// The admissible sources of one level, widening the ring while the origins
/// are starved (rule 3 of `doc_inpaint`'s ring rules), with the valid plane it came
/// from. The set can come back EMPTY — a coarse level whose hole leaves no
/// room for a complete patch — which only the finest level may refuse on.
fn build_sources(plane: &Plane, sdf: &[f32], ring: f32) -> (patchmatch::Sources, Vec<bool>) {
    let floor = patchmatch::min_origins(plane.hole.iter().filter(|h| **h).count());
    let span = (plane.w + plane.h) as f32;
    let mut ring = ring;
    loop {
        let valid: Vec<bool> = plane
            .data
            .iter()
            .zip(sdf)
            .map(|(d, s)| *d && *s >= -ring)
            .collect();
        let sources = patchmatch::sources(&valid, plane.w, plane.h);
        if sources.len() >= floor || ring >= span {
            return (sources, valid);
        }
        ring *= 2.0;
    }
}

/// The mean colour of the pixels a mask marks — the onion peel's last resort
/// for a hole that reaches no known pixel at all.
fn mean_colour(plane: &Plane, mask: &[bool]) -> [u8; 3] {
    let mut sum = [0u64; 3];
    let mut count = 0u64;
    for (i, inside) in mask.iter().enumerate() {
        if !*inside {
            continue;
        }
        count += 1;
        for (s, v) in sum.iter_mut().zip(&plane.rgb[i * 3..i * 3 + 3]) {
            *s += u64::from(*v);
        }
    }
    if count == 0 {
        return [0, 0, 0];
    }
    [
        ((sum[0] + count / 2) / count) as u8,
        ((sum[1] + count / 2) / count) as u8,
        ((sum[2] + count / 2) / count) as u8,
    ]
}
