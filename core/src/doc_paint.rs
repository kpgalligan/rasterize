//! Painting through layer blend modes: the paint tools' Blend option.
//!
//! The classic source-over / erase paint path lives in `doc.rs`'s
//! `painting_layer` and stays byte-for-byte what it was; this module adds
//! the variant that pushes every covered pixel through the SAME W3C kernel
//! the layer projection uses (`blend::composite_source_into`), so a brush
//! set to Multiply lands exactly what a Multiply layer holding the stroke
//! would flatten to against the layer's current pixels. Erase has no blend
//! counterpart — the eraser never blends.

use crate::blend::{blend_kind, composite_source_into, BlendMode};
use crate::doc::RzDocument;
use crate::ops::CompositeMode;

impl RzDocument {
    /// Paints a canvas-frame PREMULTIPLIED RGBA8 overlay (`src`, exactly
    /// canvas w*h*4 bytes) onto layer `idx` through blend mode `mode`,
    /// scaled by `alpha` (clamped to [0, 1]).
    ///
    /// `BlendMode::Normal` IS source-over, so it delegates to
    /// [`RzDocument::painting_layer`] — keeping the classic path the single
    /// implementation and the two byte-identical. Every other mode
    /// un-premultiplies each covered overlay pixel back to straight color
    /// and composites it with the W3C formula (`sa*(1-ab)*Cs + sa*ab*B(Cb,
    /// Cs) + (1-sa)*ab*Cb`, all in f32) onto the layer's straight pixel;
    /// Dissolve keeps its canvas-absolute deterministic dither, so a
    /// dissolve stroke lands the same speckle a dissolve layer would.
    ///
    /// Domain refusals (`None`): `idx` out of range; NaN `alpha`; `src` not
    /// exactly canvas-sized; a layer extent that misses the canvas; or no
    /// pixel actually changing (e.g. multiply by white) — an identical copy
    /// would register a phantom undo step in the app. (`pub(crate)` like
    /// `painting_layer`; the public surface is `rz_doc_painting_layer_blend`.)
    pub(crate) fn painting_layer_blend(
        &self,
        idx: usize,
        src: &[u8],
        mode: BlendMode,
        alpha: f32,
    ) -> Option<Self> {
        if mode == BlendMode::Normal {
            return self.painting_layer(idx, src, CompositeMode::Over, alpha);
        }
        let layer = self.layers.get(idx)?;
        if alpha.is_nan() {
            return None;
        }
        let expected = (self.width as usize)
            .checked_mul(self.height as usize)?
            .checked_mul(4)?;
        if src.len() != expected {
            return None;
        }
        let a = alpha.clamp(0.0, 1.0);
        // The offset-mapped overlay walk below mirrors `painting_layer`
        // (doc.rs), the master copy of this clipping.
        let (lw, lh) = layer.pixels.dimensions();
        let (off_x, off_y) = (i64::from(layer.offset.0), i64::from(layer.offset.1));
        let lx0 = (-off_x).max(0);
        let ly0 = (-off_y).max(0);
        let lx1 = (i64::from(self.width) - off_x).min(i64::from(lw));
        let ly1 = (i64::from(self.height) - off_y).min(i64::from(lh));
        if lx0 >= lx1 || ly0 >= ly1 {
            return None;
        }
        let kind = blend_kind(mode);
        let mut pixels = (*layer.pixels).clone();
        let raw: &mut [u8] = &mut pixels;
        let mut changed = false;
        for ly in ly0..ly1 {
            for lx in lx0..lx1 {
                let cx = (lx + off_x) as u64;
                let cy = (ly + off_y) as u64;
                let si = ((cy * u64::from(self.width) + cx) * 4) as usize;
                let sp = [src[si], src[si + 1], src[si + 2], src[si + 3]];
                if sp[3] == 0 {
                    // Nothing painted here; note a fully transparent pixel
                    // with junk color bytes still contributes nothing (its
                    // effective alpha is 0 whatever the bytes say).
                    continue;
                }
                let sa = (f32::from(sp[3]) / 255.0) * a;
                if sa <= 0.0 {
                    continue;
                }
                // Straight source color: divide the premultiplied bytes by
                // their own alpha (min guards malformed color > alpha).
                let cs = [
                    (f32::from(sp[0]) / f32::from(sp[3])).min(1.0),
                    (f32::from(sp[1]) / f32::from(sp[3])).min(1.0),
                    (f32::from(sp[2]) / f32::from(sp[3])).min(1.0),
                ];
                let di = ((ly as u64 * u64::from(lw) + lx as u64) * 4) as usize;
                let dp: &mut [u8] = &mut raw[di..di + 4];
                let mut acc = [[
                    f32::from(dp[0]) / 255.0,
                    f32::from(dp[1]) / 255.0,
                    f32::from(dp[2]) / 255.0,
                    f32::from(dp[3]) / 255.0,
                ]];
                composite_source_into(&mut acc, 0, cs, sa, kind, (cx as i64, cy as i64));
                for c in 0..4 {
                    let v = (acc[0][c].clamp(0.0, 1.0) * 255.0).round() as u8;
                    if dp[c] != v {
                        dp[c] = v;
                        changed = true;
                    }
                }
            }
        }
        if !changed {
            return None;
        }
        self.with_layer_pixels(idx, pixels)
    }
}
