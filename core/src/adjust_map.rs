//! `gradient_map`: the pixel's luma read as a position along a multi-stop
//! gradient. The payload, its `parse` and its kernel live here; `adjust`
//! keeps only the schema row and the dispatch.
//!
//! # One gradient spelling in the core
//!
//! The gradient is `style::GradientFill`, parsed by
//! `style_json::gradient` — the SAME object and the SAME parser a layer
//! style's Gradient Overlay carries, because a second gradient spelling in
//! one core is worth less than the one difference between them costs to
//! document. That difference: a style's stop colours are AUTHORED sRGB,
//! converted into the document's space by the compositor, while a map's are
//! the DOCUMENT's own numbers, converted nowhere (`adjust`'s colour note).
//!
//! A map has no geometry, so nothing else is reused — no `GradientSampler`,
//! no gradient box. Only `stops` and `reverse` are read; `style`, `angle`,
//! `scale` and `align_with_layer` are accepted and ignored, so one editor
//! and one JSON shape serve both places. The model has NO per-span midpoint
//! and no separate opacity stops (one stop carries position, colour and
//! opacity), which is why the editor has no midpoint diamond.
//!
//! # The kernel
//!
//! ```text
//! t = luma(rgb)                              # Rec. 709
//! t = clamp(t + (dissolve_threshold(x, y) - 0.5)/255, 0, 1)   # when dithering
//! t = 1 - t                                  # when the gradient is reversed
//! (colour, opacity) = gradient_color(fill, t)
//! out = rgb + (colour - rgb) * opacity
//! ```
//!
//! A stop's OPACITY blends between the ORIGINAL pixel (0) and the mapped
//! colour (1) — the meaning Photoshop's transparency stops have in a
//! gradient map, and the only one available to an adjustment, which may
//! never touch alpha.
//!
//! `reverse` is applied HERE: `style_gradient::gradient_color` does not
//! apply it (the sampler's `t` does, and a map has no sampler).
//!
//! **Dither**, on by default, is what stops an 8-bit map banding over a
//! smooth sky: a deterministic +/- half a code of jitter on `t`, keyed on
//! the pixel's canvas position through `blend::dissolve_threshold` — the
//! same primitive the Dissolve blend mode uses, so the core has one
//! position-keyed hash and not two. It is pure (the same pixel always gets
//! the same offset), which is what lets it live under a `.rz` round trip and
//! a cached composite.

use serde_json::{Map, Value};

use crate::adjust_math::luma;
use crate::adjust_parse::boolean;
use crate::blend::dissolve_threshold;
use crate::style::{GradientFill, Strictness};
use crate::style_gradient::gradient_color;
use crate::style_json;

/// A parsed `gradient_map` op.
#[derive(Clone)]
pub(crate) struct GradientMap {
    fill: GradientFill,
    dither: bool,
}

impl GradientMap {
    /// Parses the `gradient_map` params per the schema row in `adjust`.
    /// The gradient goes through the style parser in its LENIENT mode: an
    /// unknown `style` name is defaulted rather than refused, the way the
    /// `.rz` reader treats a file from a newer build, since a map ignores
    /// that key anyway. Structural mistakes (a non-object, a 33-stop list,
    /// a colour that is not `#rrggbb`) are still refusals.
    pub(crate) fn parse(params: &Map<String, Value>) -> Option<GradientMap> {
        Some(GradientMap {
            fill: style_json::gradient(params, "params", "gradient", Strictness::Lenient).ok()?,
            dither: boolean(params, "dither", true)?,
        })
    }

    /// One straight RGB triple in [0, 1] at canvas position `xy`.
    pub(crate) fn apply_at(&self, rgb: [f32; 3], xy: (i64, i64)) -> [f32; 3] {
        let mut t = luma(rgb);
        if self.dither {
            t += (dissolve_threshold(xy.0, xy.1) - 0.5) / 255.0;
        }
        t = t.clamp(0.0, 1.0);
        if self.fill.reverse {
            t = 1.0 - t;
        }
        let (mapped, opacity) = gradient_color(&self.fill, t);
        let opacity = opacity.clamp(0.0, 1.0);
        std::array::from_fn(|c| rgb[c] + (mapped[c] - rgb[c]) * opacity)
    }
}
