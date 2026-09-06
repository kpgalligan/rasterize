//! Poisson (membrane) blending: the ONE solver behind every healing op —
//! the healing brush, the patch tool, spot healing and content-aware fill.
//! Free functions over plain window-sized buffers, with no `RzDocument`
//! knowledge, so every caller shares this arithmetic.
//!
//! # The formulation, and why the correction form
//!
//! Pérez/Gangnet/Blake's seamless cloning solves `Δf = Δg` over Ω with
//! `f|∂Ω = f*|∂Ω` (source texture, destination illumination). Writing
//! `f = g + ũ` turns that into the LAPLACE equation
//!
//! ```text
//! Δũ = 0 over Ω,     ũ|∂Ω = (f* − g)|∂Ω
//! ```
//!
//! — the same solution, reached with a zero right-hand side. That is the
//! form implemented here, for five reasons: the update is a plain neighbour
//! average (no divergence term to accumulate, no RHS rounding); `ũ` is
//! bounded by the mismatch (±255) rather than the image range, so f32 is
//! comfortable; `ũ` is harmonic, hence smooth, which is what makes the
//! coarse grids below meaningful; seamlessness is automatic (`ũ = f* − g` on
//! ∂Ω gives `f = f*` there exactly, so a hard-edged footprint needs no
//! feather); and the exactness cases fall straight out of the discrete
//! maximum principle. Mixing gradients (Pérez §3.2) is the one variant this
//! form does not cover; it needs a non-zero RHS at the finest level and is
//! not in this build.
//!
//! # The region, binarized once
//!
//! Callers hand coverage bytes; **covered means byte ≥ 128**
//! ([`COVERED_THRESHOLD`]), the same 50 % contour `doc_select`'s morphology
//! resolves masks at. The classification rule is stated once, on [`Region`],
//! and nowhere else.
//!
//! # The solver: red-black multigrid
//!
//! A geometric multigrid: a coarse-to-fine cascade for the initial guess,
//! then V(2,2) cycles at full resolution — [`V_CYCLES`] of them whatever
//! happens, and up to [`MAX_V_CYCLES`] while the MEASURED residual is still
//! above [`RESIDUAL_TOL`]. Levels halve until the larger side is ≤
//! [`COARSEST_SIDE`], at most [`MAX_LEVELS`] of them.
//!
//! Four details decide whether this works at all, and each was measured:
//!
//! 1. **Coarsening the CLASSIFICATION, not the coverage.** The obvious rule
//!    — a coarse cell is covered iff ≥ 2 of its 4 fine children are — dilates
//!    a straight edge by one fine pixel and so SWALLOWS the one-pixel
//!    Dirichlet ring: the coarse problem then has zero-flux edges where the
//!    fine one has data, and its answer is unrelated. Measured on a 300²
//!    region with step-discontinuous boundary data, that rule left 3.0 code
//!    values of error at the seam and made the V-cycle diverge outright.
//!    [`restrict`] instead coarsens the classification — any fine boundary
//!    child makes a coarse boundary cell, carrying the mean of those
//!    children's `b` — so the ring survives at the right place with the right
//!    data. Same schedule, same cost: 1.14 code values instead of 3.0.
//! 2. **The smoother inside a cycle is ω = 1 red-black Gauss-Seidel, not
//!    SOR.** SOR at ω_opt is a fast solver and a poor smoother — near the
//!    optimum its eigenvalues all have modulus ω−1, so it damps every
//!    frequency alike, which is exactly what a coarse-grid correction cannot
//!    use. RB-GS kills the oscillatory half of the spectrum in a couple of
//!    sweeps, which is what makes each V-cycle worth ~10× error reduction.
//!    SOR at the level's own ω is still used for the cascade's initial guess
//!    and for the coarsest grid, where it IS the solver.
//! 3. **The coarse right-hand side is `4 · mean(residual)`.** The stencil is
//!    the UNSCALED 5-point Laplacian (`d·u − Σu = −h²Δu`), so at mesh spacing
//!    2 it represents `−4Δ`; the error equation must be scaled to match.
//!    Measured at 300²: scale 4 → 0.013 code values after two cycles,
//!    scale 2 → 0.40, scale 1 → 0.70, and (with the old restriction) scale 4
//!    diverged, which is what sent this back to first principles.
//! 4. **The correction is applied at the step length that minimizes the
//!    error's energy, not at 1.** See the next section: rule 3's scale is
//!    right for a smooth residual in the interior and wrong by enough to
//!    DIVERGE on a region whose boundary is mostly zero-flux. [`correct`]
//!    computes `α = ⟨e, r⟩ / ⟨e, Ae⟩` — two passes over the unknowns — which
//!    is exact for any scale and cannot increase the error, whatever the
//!    coarse grid says.
//!
//! # Zero-flux boundaries, and why a fixed cycle count is not convergence
//!
//! A region whose contour is mostly the WINDOW's edge rather than the
//! destination's pixels — a frame flush with all four canvas edges (magic-wand
//! the black border of a scan and fill it), a U along three, a patch dragged
//! around the border of the picture — is a nearly pure Neumann problem: its
//! only Dirichlet data is one inner contour, and the operator's smallest
//! eigenvalue is tiny. On such a region the fixed-scale coarse correction of
//! rule 3 is over-driven, because on a near-singular coarse grid `A⁻¹` is
//! enormous and a 4× right-hand side produces a correction bigger than the
//! error it was meant to remove. It did not converge slowly — it DIVERGED.
//! Measured on a 161 px window with a 40 px frame flush with every edge,
//! against a Jacobi-preconditioned f64 CG reference converged to residual
//! 1e-10:
//!
//! | levels | residual after 1, 2, 4, 8 cycles | error at 4 cycles |
//! |---|---|---|
//! | 2 | 0.92 → 0.11 → 0.0027 → 1.5e-5 | 0.000 |
//! | 4 | 0.95 → 0.15 → 0.012 → 0.0088 | 0.57 |
//! | 6 (shipped depth) | 0.94 → 0.16 → 0.66 → 15 | **53** |
//!
//! — the deeper the hierarchy, the worse, because each level's own
//! over-driven correction is prolongated into the next. 35 599 of that
//! region's 58 080 solved channel samples were off by more than 4 code
//! values, and nothing in the module noticed: the schedule was a fixed four
//! cycles and the residual was never looked at.
//!
//! Both halves of that are fixed here. [`correct`]'s step length makes every
//! cycle non-expansive in the energy norm — `A` restricted to the unknowns is
//! symmetric positive definite, so the minimizing step cannot increase the
//! error however bad the direction — and the loop then keeps cycling while
//! the residual it measures is above [`RESIDUAL_TOL`], up to
//! [`MAX_V_CYCLES`]. The same frame now lands at 0.073 code values in six
//! cycles, and the ceiling has never been reached by any geometry measured.
//!
//! A residual is not an error bound and is not claimed as one: on this
//! geometry a residual of 0.098 came with 69 code values of error before the
//! fix. What the tolerance rests on is measurement — the table below — plus
//! the guarantee that the sequence it stops is monotone.
//!
//! # Why not the plain cascade
//!
//! A cascade with a fixed sweep count per level (the shape this module had
//! first: 40 coarse, 48 a level, 32 extra at the finest — 96 updates per
//! unknown) is NOT a solver of fixed accuracy: the finest level's SOR rate
//! is `1 − 2π/n`, so a fixed sweep count buys less and less as the region
//! grows. Measured against an f64 reference, same geometry, same data:
//!
//! | schedule | updates/unknown | seam error n=300 | seam error n=1000 |
//! |---|---|---|---|
//! | cascade 40/48/32 | 96 | 1.14 | 3.00 |
//! | cascade doubled | 192 | 0.13 | 1.15 |
//! | **cascade 8 + V(2,2) cycles** | **32–80** | **0.0003** | **0.0021** |
//!
//! (The two cascade rows come from a testbed carrying that schedule; the
//! shipped row is `heal_tests`' own measurement.)
//!
//! The V-cycle is three times CHEAPER and a thousand times more accurate,
//! and — the property that matters — its accuracy does not decay with the
//! region's size. Banding is visible at 1 code value; a cascade-only solve
//! is at that threshold for a patch-sized region.
//!
//! # Measured cost and accuracy
//!
//! Boundary data carrying step discontinuities every ~15 px (the honest
//! shape of `b = dest − source` where texture edges cross the contour),
//! against independently written f64 references run to convergence — SOR for
//! the square rows, Jacobi-preconditioned CG (residual ≤ 1e-10) for the
//! geometry sweep. This machine, `--release`:
//!
//! | region | unknowns | cycles | s/channel | seam ≤ 2 px | 3–10 px | interior |
//! |---|---|---|---|---|---|---|
//! | 300² square | 90 k | 4 | 0.012 | 0.0003 | 0.0012 | 0.0026 |
//! | 1000² square | 1 M | 4 | 0.139 | 0.0021 | 0.0068 | 0.0089 |
//! | 3000² square | 9 M | 4 | 1.23 (137 ns/unknown) | — | — | — |
//!
//! and the geometry sweep in a 161 px window, max error over the whole
//! region — the numbers the tolerance is justified by, all six asserted by
//! `heal_tests::the_accuracy_holds_on_every_geometry`, each solved in four
//! to six cycles:
//!
//! | region | unknowns | max error |
//! |---|---|---|
//! | 80² block well inside the window | 6 k | 0.010 |
//! | disc | 9 k | 0.005 |
//! | L | 8 k | 0.006 |
//! | strip flush with one window edge | 6 k | 0.018 |
//! | **U flush with three edges** | 16 k | **0.061** |
//! | **40 px frame flush with all four** | 19 k | **0.117** |
//!
//! The last two are the shapes that used to diverge. Accuracy does not decay
//! with size on them either: the same frame measured 0.023 in a 401 px
//! window (120 k unknowns) and 0.065 in an 801 px one (479 k).
//!
//! Errors are code values in 0..255, so every row is more than an order
//! below the quantization step: the healed patch is the exact discrete
//! solution as far as a byte can tell, on a zero-flux-dominated region as
//! well as a Dirichlet one. That second half is the claim this module used
//! to make without having measured it.
//!
//! Cost is a constant times the unknown count — 137 ns at the scheduled four
//! cycles, 166 ns at six, and [`sweep_budget`] quotes the ceiling — so the
//! 32-megapixel window [`crate::doc_heal::MAX_SOLVE_WINDOW_PIXELS`] allows
//! is ~13 s of solve for three channels at four cycles and ~16 s at six.
//! That is why the two tools that can reach it commit behind a busy cursor
//! and say so in their catalog entries.
//!
//! A **reduced-resolution solve is not offered**, and the reason is the same
//! boundary layer that makes the cascade weak: solving at n/8 and
//! prolongating leaves 58 code values of error within 2 px of the seam — a
//! bright or dark rim around every heal — because `b` is not smooth where a
//! texture edge crosses the contour.
//!
//! Nothing in this module is exported through the C header. It is `pub` only
//! because `core/tests/` is black-box: the worked examples with known
//! closed-form answers are asserted against the solver directly.

use std::collections::VecDeque;

/// Coverage byte at or above which a pixel is inside the solve region.
pub const COVERED_THRESHOLD: u8 = 128;

/// Coarsen while the level's larger side exceeds this. 8 is small enough
/// that [`COARSE_SWEEPS`] solves it to machine accuracy and large enough
/// that the restricted geometry still resembles the region.
const COARSEST_SIDE: usize = 8;
/// Hard ceiling on the pyramid depth, so a pathological window cannot build
/// an unbounded level list. 12 levels reach a 32 768-px side.
const MAX_LEVELS: usize = 12;
/// Sweeps on the coarsest grid, where SOR at its own ω is the solver rather
/// than a smoother: at ≤ 8×8 unknowns it cuts the error by 10³ in ~10
/// sweeps, so 40 is machine accuracy for at most 40·64 = 2 560 updates.
const COARSE_SWEEPS: u32 = 40;
/// Sweeps a level during the initial cascade. The cascade only has to put
/// the V-cycles inside their asymptotic regime; 8 does that for a fraction
/// of the cost of solving each level.
const CASCADE_SWEEPS: u32 = 8;
/// Pre-smoothing sweeps in a V-cycle. (2, 2) is the standard choice for the
/// 5-point stencil with red-black Gauss-Seidel and the one measured above;
/// (1, 1) costs half as much and lands 20× worse.
const NU_PRE: u32 = 2;
/// Post-smoothing sweeps in a V-cycle. See [`NU_PRE`].
const NU_POST: u32 = 2;
/// V-cycles always run at full resolution, before the residual is consulted
/// at all. On a Dirichlet-dominated region each is worth roughly a factor of
/// 10, so four take a ~100-code-value initial error to ~0.001; on the
/// zero-flux-dominated shapes below the factor is nearer 2, which is what
/// [`MAX_V_CYCLES`] and the residual test are for.
const V_CYCLES: u32 = 4;
/// The hard ceiling on V-cycles: past [`V_CYCLES`] the loop keeps cycling
/// only while the measured residual is still above tolerance, and stops
/// either way here. Sixteen bounds the solve at four times the scheduled
/// cost — the property `sweep_budget` states and a test asserts — and no
/// geometry measured needs more than six.
const MAX_V_CYCLES: u32 = 12;
/// The residual tolerance, RELATIVE to the boundary data's own magnitude
/// (`max |b|` over the Dirichlet contour), since the solution is bounded by
/// that by the maximum principle and a bare absolute number would mean
/// something different for every image.
///
/// It is not a bound on the error — no residual is, and on a mostly-Neumann
/// region the two are far apart because the smallest eigenvalue is tiny —
/// so the number comes from measurement, not from theory: across every
/// geometry in `heal_tests`' accuracy sweep (square, disc, L, strip, a frame
/// flush with all four window edges, a U along three) a residual at this
/// tolerance came with at most 0.09 code values of error against an f64
/// reference, and the byte quantization step is 1.
const RESIDUAL_TOL: f32 = 1e-4;
/// The coarse error equation's scale: the stencil is the unscaled 5-point
/// Laplacian, which at mesh spacing 2 represents `−4Δ`. See the module doc.
const COARSE_RHS_SCALE: f32 = 4.0;
/// ω is clamped here. 1.995 is ω_opt for a ~1250-px region; below 1.0 the
/// iteration would under-relax for no reason.
const OMEGA_RANGE: (f32, f32) = (1.0, 1.995);

/// The region a membrane solve runs over, in WINDOW coordinates.
///
/// # The one classification rule
///
/// A **candidate** is `covered ∧ usable`. For a candidate, a 4-neighbour is
/// *skipped* when it is off-window, off-layer, or `covered ∧ ¬usable` — it
/// contributes nothing and reduces the divisor, a zero-flux (homogeneous
/// Neumann) edge. A neighbour that is `usable ∧ ¬covered` makes the
/// candidate a **Dirichlet boundary** pixel (`u = b`, fixed). Everything
/// else is a stencil neighbour. A candidate with no Dirichlet-making
/// neighbour and a divisor ≥ 1 is an **unknown**; a candidate with divisor 0
/// is **inert** and keeps `u = 0` — an isolated opaque pixel in a
/// transparent sea heals as a plain clone, which is the only defensible
/// answer when there is no neighbourhood to match.
///
/// Dividing by the actual neighbour count rather than a constant 4 is what
/// keeps a footprint that touches the canvas edge from growing a dark rim
/// there.
pub struct Region<'a> {
    /// Window width in pixels.
    pub w: usize,
    /// Window height in pixels.
    pub h: usize,
    /// Coverage ≥ [`COVERED_THRESHOLD`]. See the classification rule above.
    pub covered: &'a [bool],
    /// Inside the canvas AND inside the layer's extent AND layer alpha > 0.
    pub usable: &'a [bool],
}

/// What a window pixel is to the solve.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Kind {
    /// Takes part in nothing and keeps `u = 0`: a non-candidate, or an
    /// INERT candidate (divisor 0), which the caller then writes back as the
    /// plain clone.
    Skip,
    /// A candidate next to an uncovered usable pixel; `u = b`, fixed.
    Boundary,
    /// A candidate solved by relaxation.
    Unknown,
    /// An unknown in a component with no boundary at all: fixed at the
    /// pure-Neumann constant gauge (see [`Level::gauge`]).
    Gauge,
}

/// One grid of the multigrid hierarchy.
struct Level {
    w: usize,
    h: usize,
    kind: Vec<Kind>,
    b: Vec<f32>,
    /// Unknowns of each red-black colour, packed as `(index << 4) | stencil`
    /// — the window is capped well below 2²⁸ pixels, so the index fits in
    /// the upper 28 bits and the 4 stencil bits in the lower. Packing halves
    /// this list's memory, which at a 32-megapixel window is the difference
    /// between 128 MB and 256 MB.
    red: Vec<u32>,
    black: Vec<u32>,
    /// `(index, value)` for every pixel of a component that has no Dirichlet
    /// boundary. A pure-Neumann system has the constant as its only harmonic
    /// solution and zero as a fixed point of the iteration, so relaxing it
    /// would silently commit the RAW source; these pixels take `mean(b)` over
    /// their own component instead — the gauge that matches illumination on
    /// average — and are excluded from every sweep so the value is exact.
    gauge: Vec<(u32, f32)>,
    /// SOR factor for this level, from its hydraulic diameter.
    omega: f32,
    /// Unknowns actually solved here, gauge pixels included.
    unknowns: usize,
}

/// Solves Δũ = 0 over the unknowns of `region` with ũ = `b` on its Dirichlet
/// boundary, writing ũ into `u`.
///
/// `b[p]` is `(destination − source)[p]` in 0..255 units, read only at
/// candidate pixels. `u` must be at least `w * h` long and is expected to
/// arrive zeroed: this writes the boundary values, the solved unknowns and
/// the constant gauge, and leaves inert pixels and non-candidates exactly as
/// it found them.
///
/// `max_diameter` is the CEILING on ω's characteristic size — the caller's
/// window side. Each level's ω comes from that level's own hydraulic
/// diameter `4A/P`: `A` is its unknown + boundary count and `P` its boundary
/// count, one counting pass over the classification. That estimate is exact
/// for the two shapes healing produces most — a disc of radius `r` gives
/// `2r`, a strip of width `w` gives `2w` whatever its length — where the
/// bounding box would hand a long thin stroke `ω ≈ 1.995` and a rate of
/// 0.995. Only the classification can know `P`, so the caller supplies the
/// clamp rather than the diameter.
///
/// Returns the number of unknowns solved. 0 means every candidate was a
/// boundary pixel or inert; `u` is still filled at the boundary, where the
/// correction is exactly `b` and the healed pixel is therefore exactly the
/// destination.
pub fn solve_membrane(region: &Region, b: &[f32], max_diameter: usize, u: &mut [f32]) -> usize {
    let n = match region.w.checked_mul(region.h) {
        Some(n) if n > 0 => n,
        _ => return 0,
    };
    if region.covered.len() < n || region.usable.len() < n || b.len() < n || u.len() < n {
        return 0;
    }
    let mut levels = vec![classify(region, b, max_diameter)];
    while levels.len() < MAX_LEVELS {
        let last = &levels[levels.len() - 1];
        if last.w.max(last.h) <= COARSEST_SIDE || last.unknowns == 0 {
            break;
        }
        let coarse = restrict(last, max_diameter >> levels.len());
        levels.push(coarse);
    }
    let top = levels.len() - 1;

    // Cascade: a coarse-to-fine initial guess, SOR at each level's own ω.
    let mut coarse_u: Vec<f32> = Vec::new();
    for level in (1..levels.len()).rev() {
        let grid = &levels[level];
        let mut level_u = vec![0f32; grid.w * grid.h];
        if level < top {
            prolongate(&levels[level + 1], &coarse_u, grid, &mut level_u);
        }
        seed(grid, &mut level_u);
        let sweeps = if level == top {
            COARSE_SWEEPS
        } else {
            CASCADE_SWEEPS
        };
        smooth(grid, sweeps, grid.omega, &mut level_u, None);
        coarse_u = level_u;
    }
    let fine = &levels[0];
    if top > 0 {
        prolongate(&levels[1], &coarse_u, fine, u);
    }
    seed(fine, u);
    if top == 0 {
        // A single level IS the coarsest grid: SOR solves it outright.
        smooth(fine, COARSE_SWEEPS, fine.omega, u, None);
        return fine.unknowns;
    }
    // The stopping rule: [`V_CYCLES`] cycles whatever happens, then as many
    // more as the MEASURED residual asks for, up to [`MAX_V_CYCLES`]. A
    // fixed cycle count is a cost guarantee and was mistaken here for a
    // convergence guarantee: see the module doc's zero-flux section for the
    // geometry that made a scheduled four cycles wrong by 53 code values.
    // The residual `vcycle` hands back is its own — measured after the
    // pre-smoothing of the cycle that returns it, so it describes the state
    // one post-smoothing STALE and the test is conservative by one cycle.
    let tolerance = RESIDUAL_TOL * boundary_scale(fine);
    for cycle in 0..MAX_V_CYCLES {
        let residual = vcycle(&levels, 0, u, None);
        if cycle + 1 >= V_CYCLES && residual <= tolerance {
            break;
        }
    }
    fine.unknowns
}

/// `max |b|` over the level's Dirichlet boundary — the magnitude the whole
/// solution is bounded by (the maximum principle), and so the scale
/// [`RESIDUAL_TOL`] is relative to. Floored at 1 code value so a region
/// whose mismatch is everywhere tiny cannot ask for an unreachable
/// tolerance.
fn boundary_scale(level: &Level) -> f32 {
    let mut scale = 1.0f32;
    for (i, kind) in level.kind.iter().enumerate() {
        if *kind == Kind::Boundary {
            scale = scale.max(level.b[i].abs());
        }
    }
    scale
}

/// The WORST-CASE pixel-update budget for a finest level with `unknowns`
/// unknowns — the schedule at its ceiling, which is what a cost bound has to
/// quote.
///
/// The hierarchy's levels shrink geometrically, so every fine sweep costs
/// `4/3` fine-level equivalents once its coarser echoes are counted: the
/// cascade contributes [`CASCADE_SWEEPS`] and each V-cycle
/// `NU_PRE + NU_POST` plus the correction's own two passes over the
/// unknowns, and the coarsest grid adds at most `COARSEST_SIDE²` cells per
/// visit. At [`MAX_V_CYCLES`] that is `106 · unknowns + 33 280`; the
/// scheduled [`V_CYCLES`] alone are 42 an unknown, and every geometry
/// measured lands between the two.
///
/// The point of this function is the SHAPE, not the constant: the budget is
/// a constant times the unknown count and never a function of the region's
/// diameter. That is what makes a residual-driven stopping rule affordable —
/// it may spend up to the ceiling, and the ceiling is still linear.
pub fn sweep_budget(unknowns: usize) -> u64 {
    // The correction step reads the prolongated field once for its energy
    // and writes it once into the solution: two passes over the unknowns,
    // costed here as two sweeps.
    let per_cycle = NU_PRE + NU_POST + 2;
    let per_unknown = u64::from(CASCADE_SWEEPS + MAX_V_CYCLES * per_cycle) * 4 / 3;
    let coarsest = u64::from(COARSE_SWEEPS)
        * (COARSEST_SIDE * COARSEST_SIDE) as u64
        * u64::from(MAX_V_CYCLES + 1);
    unknowns as u64 * per_unknown + coarsest
}

/// The finest level, straight from the caller's coverage and usability
/// planes (the [`Region`] rule).
fn classify(region: &Region, b: &[f32], max_diameter: usize) -> Level {
    let (w, h) = (region.w, region.h);
    let mut kind = vec![Kind::Skip; w * h];
    for y in 0..h {
        for x in 0..w {
            let i = y * w + x;
            if !(region.covered[i] && region.usable[i]) {
                continue;
            }
            let mut divisor = 0u32;
            let mut dirichlet = false;
            for (inside, q) in neighbors(i, x, y, w, h) {
                // Off-window and unusable neighbours are both skipped: they
                // contribute nothing and reduce the divisor.
                if !inside || !region.usable[q] {
                    continue;
                }
                divisor += 1;
                if !region.covered[q] {
                    dirichlet = true;
                }
            }
            kind[i] = if divisor == 0 {
                Kind::Skip // inert: no neighbourhood to match, u stays 0
            } else if dirichlet {
                Kind::Boundary
            } else {
                Kind::Unknown
            };
        }
    }
    finish(w, h, kind, b[..w * h].to_vec(), max_diameter)
}

/// Halves a level by coarsening its CLASSIFICATION (see the module doc): any
/// fine boundary child makes a coarse boundary cell carrying the mean of
/// those children's `b`, so the Dirichlet ring survives coarsening at the
/// right place; otherwise two unknown children make a coarse unknown, and
/// everything else — including a whole gauge component, which is already
/// solved and touches no unknown — drops out.
fn restrict(fine: &Level, max_diameter: usize) -> Level {
    let (cw, ch) = (fine.w.div_ceil(2), fine.h.div_ceil(2));
    let mut kind = vec![Kind::Skip; cw * ch];
    let mut b = vec![0f32; cw * ch];
    for cy in 0..ch {
        for cx in 0..cw {
            let (mut boundary, mut unknown) = (0u32, 0u32);
            let (mut boundary_sum, mut unknown_sum) = (0f32, 0f32);
            for dy in 0..2 {
                for dx in 0..2 {
                    let (fx, fy) = (cx * 2 + dx, cy * 2 + dy);
                    if fx >= fine.w || fy >= fine.h {
                        continue;
                    }
                    let j = fy * fine.w + fx;
                    match fine.kind[j] {
                        Kind::Boundary => {
                            boundary += 1;
                            boundary_sum += fine.b[j];
                        }
                        Kind::Unknown => {
                            unknown += 1;
                            unknown_sum += fine.b[j];
                        }
                        Kind::Skip | Kind::Gauge => {}
                    }
                }
            }
            let i = cy * cw + cx;
            if boundary > 0 {
                kind[i] = Kind::Boundary;
                b[i] = boundary_sum / boundary as f32;
            } else if unknown >= 2 {
                kind[i] = Kind::Unknown;
                b[i] = unknown_sum / unknown as f32;
            }
        }
    }
    finish(cw, ch, kind, b, max_diameter)
}

/// Completes a level from its kind plane: the stencil masks, the red and
/// black unknown lists, the pure-Neumann gauge and ω.
fn finish(w: usize, h: usize, mut kind: Vec<Kind>, b: Vec<f32>, max_diameter: usize) -> Level {
    let mut masks = vec![0u8; w * h];
    let (mut area, mut perimeter) = (0usize, 0usize);
    for y in 0..h {
        for x in 0..w {
            let i = y * w + x;
            if kind[i] == Kind::Skip {
                continue;
            }
            area += 1;
            if kind[i] == Kind::Boundary {
                perimeter += 1;
            }
            let mut mask = 0u8;
            for (bit, (inside, q)) in neighbors(i, x, y, w, h).into_iter().enumerate() {
                if inside && kind[q] != Kind::Skip {
                    mask |= 1 << bit;
                }
            }
            masks[i] = mask;
        }
    }
    let gauge = gauge_components(&mut kind, &masks, &b, w, h);
    let (mut red, mut black) = (Vec::new(), Vec::new());
    for y in 0..h {
        for x in 0..w {
            let i = y * w + x;
            if kind[i] != Kind::Unknown || masks[i] == 0 {
                continue;
            }
            let packed = (i as u32) << 4 | u32::from(masks[i]);
            if (x + y) % 2 == 0 {
                red.push(packed);
            } else {
                black.push(packed);
            }
        }
    }
    let unknowns = red.len() + black.len() + gauge.len();
    Level {
        w,
        h,
        kind,
        b,
        red,
        black,
        gauge,
        omega: omega_for(area, perimeter, max_diameter),
        unknowns,
    }
}

/// The four 4-neighbours of `i` as `(inside the window, index)`, in the
/// order the stencil mask's bits run: left, right, up, down. An
/// out-of-window neighbour's index is meaningless and must not be used —
/// every caller tests the flag first.
fn neighbors(i: usize, x: usize, y: usize, w: usize, h: usize) -> [(bool, usize); 4] {
    [
        (x > 0, i.wrapping_sub(1)),
        (x + 1 < w, i + 1),
        (y > 0, i.wrapping_sub(w)),
        (y + 1 < h, i + w),
    ]
}

/// Young's optimal ω for a square of side `4A/P` (the hydraulic diameter,
/// clamped to `[2, max_diameter]`), itself clamped to [`OMEGA_RANGE`].
fn omega_for(area: usize, perimeter: usize, max_diameter: usize) -> f32 {
    let ceiling = max_diameter.max(2);
    let diameter = if perimeter == 0 {
        ceiling
    } else {
        (4 * area / perimeter).clamp(2, ceiling)
    };
    let rho = (std::f32::consts::PI / (diameter as f32 + 1.0)).cos();
    let omega = 2.0 / (1.0 + (1.0 - rho * rho).max(0.0).sqrt());
    omega.clamp(OMEGA_RANGE.0, OMEGA_RANGE.1)
}

/// Finds the connected components of the solve domain (walking stencil
/// neighbours) and, for every component with no Dirichlet boundary, returns
/// `mean(b)` over it for each of its pixels — retagging them [`Kind::Gauge`]
/// so no sweep touches them again. The BFS mirrors
/// `doc_select::grow_region`, the master copy of this walk; it differs only
/// in its predicate (stencil adjacency instead of colour similarity).
fn gauge_components(
    kind: &mut [Kind],
    masks: &[u8],
    b: &[f32],
    w: usize,
    h: usize,
) -> Vec<(u32, f32)> {
    let mut seen = vec![false; w * h];
    let mut out = Vec::new();
    let mut component: Vec<u32> = Vec::new();
    let mut queue: VecDeque<u32> = VecDeque::new();
    for start in 0..w * h {
        if seen[start] || !matches!(kind[start], Kind::Boundary | Kind::Unknown) {
            continue;
        }
        seen[start] = true;
        queue.push_back(start as u32);
        component.clear();
        let mut has_boundary = false;
        let mut sum = 0f64;
        while let Some(i) = queue.pop_front() {
            let i = i as usize;
            component.push(i as u32);
            has_boundary |= kind[i] == Kind::Boundary;
            sum += f64::from(b[i]);
            let mask = masks[i];
            for (bit, (_, q)) in neighbors(i, i % w, i / w, w, h).into_iter().enumerate() {
                if mask & (1 << bit) != 0 && !seen[q] {
                    seen[q] = true;
                    queue.push_back(q as u32);
                }
            }
        }
        if has_boundary {
            continue;
        }
        let mean = (sum / component.len() as f64) as f32;
        for &i in &component {
            kind[i as usize] = Kind::Gauge;
            out.push((i, mean));
        }
    }
    out
}

/// Writes the fixed values: `b` at every Dirichlet boundary pixel and the
/// constant gauge over every boundary-free component.
fn seed(level: &Level, u: &mut [f32]) {
    for (i, k) in level.kind.iter().enumerate() {
        if *k == Kind::Boundary {
            u[i] = level.b[i];
        }
    }
    for &(i, value) in &level.gauge {
        u[i as usize] = value;
    }
}

/// `sweeps` red-black sweeps of `u_p ← u_p + ω·((Σ u_q + rhs_p)/d_p − u_p)`.
/// Each colour reads only the other, so the result is independent of the
/// order within a colour — bit-identical under any scheduling. `rhs` is the
/// coarse error equation's right-hand side, `None` at the finest level
/// (where the membrane's own right-hand side is zero).
fn smooth(level: &Level, sweeps: u32, omega: f32, u: &mut [f32], rhs: Option<&[f32]>) {
    // Reciprocals of the only divisors a stencil mask can produce.
    let inv = [0.0f32, 1.0, 0.5, 1.0 / 3.0, 0.25];
    let w = level.w;
    for _ in 0..sweeps {
        for list in [&level.red, &level.black] {
            for packed in list {
                let i = (packed >> 4) as usize;
                let mask = packed & 15;
                let mut sum = rhs.map_or(0.0, |r| r[i]);
                if mask & 1 != 0 {
                    sum += u[i - 1];
                }
                if mask & 2 != 0 {
                    sum += u[i + 1];
                }
                if mask & 4 != 0 {
                    sum += u[i - w];
                }
                if mask & 8 != 0 {
                    sum += u[i + w];
                }
                let average = sum * inv[mask.count_ones() as usize];
                u[i] += omega * (average - u[i]);
            }
        }
    }
}

/// `r = rhs − (d·u − Σ u_q)` at the unknowns, zero everywhere else.
fn residual(level: &Level, u: &[f32], rhs: Option<&[f32]>, out: &mut [f32]) {
    out.iter_mut().for_each(|v| *v = 0.0);
    let w = level.w;
    for list in [&level.red, &level.black] {
        for packed in list {
            let i = (packed >> 4) as usize;
            let mask = packed & 15;
            let mut sum = rhs.map_or(0.0, |r| r[i]);
            if mask & 1 != 0 {
                sum += u[i - 1];
            }
            if mask & 2 != 0 {
                sum += u[i + 1];
            }
            if mask & 4 != 0 {
                sum += u[i - w];
            }
            if mask & 8 != 0 {
                sum += u[i + w];
            }
            out[i] = sum - mask.count_ones() as f32 * u[i];
        }
    }
}

/// The coarse grid's right-hand side: [`COARSE_RHS_SCALE`] times the mean of
/// the fine residual over each coarse cell's children.
fn restrict_residual(fine: &Level, r: &[f32], coarse: &Level) -> Vec<f32> {
    let mut out = vec![0f32; coarse.w * coarse.h];
    for cy in 0..coarse.h {
        for cx in 0..coarse.w {
            let i = cy * coarse.w + cx;
            if coarse.kind[i] != Kind::Unknown {
                continue;
            }
            let (mut count, mut sum) = (0u32, 0f32);
            for dy in 0..2 {
                for dx in 0..2 {
                    let (fx, fy) = (cx * 2 + dx, cy * 2 + dy);
                    if fx >= fine.w || fy >= fine.h {
                        continue;
                    }
                    sum += r[fy * fine.w + fx];
                    count += 1;
                }
            }
            if count > 0 {
                out[i] = COARSE_RHS_SCALE * sum / count as f32;
            }
        }
    }
    out
}

/// Bilinearly interpolates a coarse field into the fine level's unknowns
/// (only — boundary and gauge pixels are fixed and must not be disturbed).
/// The one caller that does not replace what it finds is the V-cycle's
/// correction, which needs the interpolated field itself and so walks
/// [`sample_coarse`] on its own.
fn prolongate(coarse: &Level, coarse_u: &[f32], fine: &Level, u: &mut [f32]) {
    for y in 0..fine.h {
        for x in 0..fine.w {
            let i = y * fine.w + x;
            if fine.kind[i] != Kind::Unknown {
                continue;
            }
            u[i] = sample_coarse(coarse, coarse_u, x, y);
        }
    }
}

/// The bilinear sample of `coarse_u` under fine pixel `(x, y)` — the ONE
/// interpolation the cascade and the V-cycle's correction share. Cell
/// centres map as `xc = x/2 − 1/4`; samples that fall outside the coarse
/// solve domain are dropped and the weights renormalized, so a fine unknown
/// near the region's edge is not dragged toward the zero sitting outside it.
/// With no usable sample at all the answer is 0, which leaves the caller's
/// field as it was.
fn sample_coarse(coarse: &Level, coarse_u: &[f32], x: usize, y: usize) -> f32 {
    let xc = x as f32 * 0.5 - 0.25;
    let yc = y as f32 * 0.5 - 0.25;
    let x0 = xc.floor();
    let y0 = yc.floor();
    let (fx, fy) = (xc - x0, yc - y0);
    let (x0, y0) = (x0 as i64, y0 as i64);
    let (mut acc, mut weight) = (0f32, 0f32);
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
        if coarse.kind[j] == Kind::Skip {
            continue;
        }
        let k = wx * wy;
        acc += k * coarse_u[j];
        weight += k;
    }
    if weight > 0.0 {
        acc / weight
    } else {
        0.0
    }
}

/// One V-cycle: pre-smooth, restrict the residual, solve the coarse error
/// equation (recursively, with zero as its Dirichlet data — the error is 0
/// wherever the value is fixed), add the interpolated correction back at the
/// step length that minimizes the error's energy, and post-smooth.
///
/// Returns `max |r|` over this level's unknowns, measured between the pre-
/// smoothing and the correction. At the finest level that is the number the
/// stopping rule reads.
fn vcycle(levels: &[Level], level: usize, u: &mut [f32], rhs: Option<&[f32]>) -> f32 {
    let fine = &levels[level];
    if level + 1 >= levels.len() || fine.unknowns == 0 {
        smooth(fine, COARSE_SWEEPS, fine.omega, u, rhs);
        return 0.0;
    }
    smooth(fine, NU_PRE, 1.0, u, rhs);
    let mut r = vec![0f32; fine.w * fine.h];
    residual(fine, u, rhs, &mut r);
    let worst = r.iter().fold(0f32, |m, v| m.max(v.abs()));
    let coarse = &levels[level + 1];
    let coarse_rhs = restrict_residual(fine, &r, coarse);
    let mut error = vec![0f32; coarse.w * coarse.h];
    vcycle(levels, level + 1, &mut error, Some(&coarse_rhs));
    correct(fine, coarse, &error, &mut r, u);
    smooth(fine, NU_POST, 1.0, u, rhs);
    worst
}

/// Adds the coarse level's correction to `u` at the step length that
/// minimizes the remaining error's energy: `α = ⟨e, r⟩ / ⟨e, Ae⟩`, the
/// stationary point of `‖e_err − α·e‖²_A`.
///
/// **This is what keeps the cycle from diverging**, and it replaces a
/// tuning constant with a measurement. [`COARSE_RHS_SCALE`] is the right
/// factor for a smooth residual in the interior; it is not the right factor
/// for the near-null-space direction of a coarse grid whose boundary is
/// mostly zero-flux, where `A⁻¹` is enormous and a 4x-overdriven right-hand
/// side produced a correction bigger than the error it was meant to remove.
/// Measured on a 161 px window healed over a 40 px frame flush with all four
/// edges, the residual GREW by 2.2x a cycle and four cycles landed 53 code
/// values from the exact discrete solution. With α the same geometry lands
/// at 0.24, and — the property that matters — no geometry can diverge at
/// all: A is symmetric positive definite over the unknowns, so the energy
/// cannot increase along the minimizing step whatever the coarse grid says.
///
/// `r` arrives holding the residual and LEAVES holding the correction: it
/// has done its job by then, and a second window-sized buffer per level is
/// exactly what [`crate::doc_heal::MAX_SOLVE_WINDOW_PIXELS`] is a bound on.
fn correct(fine: &Level, coarse: &Level, error: &[f32], r: &mut [f32], u: &mut [f32]) {
    let w = fine.w;
    // Pass one: interpolate the correction over `r`, accumulating ⟨e, r⟩
    // before each residual is overwritten.
    let mut numerator = 0f64;
    for list in [&fine.red, &fine.black] {
        for packed in list {
            let i = (packed >> 4) as usize;
            let e = sample_coarse(coarse, error, i % w, i / w);
            numerator += f64::from(e) * f64::from(r[i]);
            r[i] = e;
        }
    }
    // Pass two: ⟨e, Ae⟩, with `r` now the correction and zero everywhere it
    // is not an unknown — so the stencil sum is the operator restricted to
    // the unknowns, which is the positive definite block.
    let mut denominator = 0f64;
    for list in [&fine.red, &fine.black] {
        for packed in list {
            let i = (packed >> 4) as usize;
            let mask = packed & 15;
            let mut sum = 0f32;
            if mask & 1 != 0 {
                sum += r[i - 1];
            }
            if mask & 2 != 0 {
                sum += r[i + 1];
            }
            if mask & 4 != 0 {
                sum += r[i - w];
            }
            if mask & 8 != 0 {
                sum += r[i + w];
            }
            let ae = mask.count_ones() as f32 * r[i] - sum;
            denominator += f64::from(r[i]) * f64::from(ae);
        }
    }
    // A zero denominator means the correction is identically zero (or has
    // underflowed): there is no step to take, and dividing would invent one.
    // A NaN falls through to the finite test on `alpha` below.
    if denominator < f64::MIN_POSITIVE {
        return;
    }
    let alpha = (numerator / denominator) as f32;
    if !alpha.is_finite() {
        return;
    }
    for list in [&fine.red, &fine.black] {
        for packed in list {
            let i = (packed >> 4) as usize;
            u[i] += alpha * r[i];
        }
    }
}
