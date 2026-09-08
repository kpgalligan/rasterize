//! `SplitMix64` — the crate's ONE pseudo-random generator.
//!
//! It began as a private helper inside `ops_filters` (the noise filter's
//! per-pixel stream) and moved here when the content-aware inpainter needed
//! the same generator: a second PRNG would have been a second implementation
//! of the same algorithm, and "shared constants have exactly one home" wants
//! the same of shared code. The noise filter's bytes are unchanged —
//! [`SplitMix64::new`] is the old tuple constructor and the two `next_*`
//! methods are copied verbatim.
//!
//! The algorithm is Steele/Lea/Flood's SplitMix64: a 64-bit Weyl sequence
//! (the golden-ratio increment) run through a strong avalanche finalizer. It
//! is a few lines, needs no dependency, and passes the statistical tests that
//! matter here — nothing in this crate is doing cryptography, and everything
//! it drives has to be reproducible from a seed.
//!
//! [`SplitMix64::at`] is the *positional* form: a stream addressed by a seed
//! plus up to three coordinates, so a value depends on WHERE it is asked for
//! and not on how many values were drawn before it. That is what lets the
//! inpainter's search be identical whatever order its targets are visited in
//! (`blend::dissolve_threshold` is the crate's other positional hash, and the
//! precedent for the idea).

/// SplitMix64: 64 bits of state, one Weyl step and a finalizer per draw.
pub(crate) struct SplitMix64(u64);

impl SplitMix64 {
    /// A stream seeded directly with `seed`. Successive draws depend on the
    /// number of draws before them, so this is for a sequential walk (the
    /// noise filter's row-major sweep).
    pub(crate) fn new(seed: u64) -> Self {
        SplitMix64(seed)
    }

    /// A stream addressed by `seed` and up to three coordinates.
    ///
    /// The three multipliers are the SplitMix64 increment and its two
    /// finalizer constants — odd, high-entropy, and already known to scatter
    /// well in this generator's own mixing. One multiply each is enough
    /// because the strong finalizer inside [`Self::next_u64`] does the real
    /// work; the multiply only has to make neighbouring coordinates land in
    /// unrelated parts of the state space, which a shift-and-xor of small
    /// integers would not.
    pub(crate) fn at(seed: u64, a: u64, b: u64, c: u64) -> Self {
        SplitMix64(
            seed ^ a.wrapping_mul(0x9E37_79B9_7F4A_7C15)
                ^ b.wrapping_mul(0xBF58_476D_1CE4_E5B9)
                ^ c.wrapping_mul(0x94D0_49BB_1331_11EB),
        )
    }

    /// The next 64 bits.
    pub(crate) fn next_u64(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    /// Uniform in [0, 1), built from the top 24 bits.
    pub(crate) fn next_unit_f32(&mut self) -> f32 {
        (self.next_u64() >> 40) as f32 / (1u64 << 24) as f32
    }

    /// Uniform in `0..n`, or 0 when `n` is 0.
    ///
    /// A plain modulo, so values below `2^64 % n` are very slightly more
    /// likely: at the sizes this is used for (an origin list of at most a
    /// million entries) the bias is under one part in 10^13 and no caller
    /// cares — a rejection loop would buy nothing but a branch that could
    /// spin.
    pub(crate) fn below(&mut self, n: usize) -> usize {
        if n == 0 {
            return 0;
        }
        (self.next_u64() % n as u64) as usize
    }
}
