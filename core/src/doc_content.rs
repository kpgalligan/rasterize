//! Atomic layer-content replacement: pixels, offset and mask in one pure
//! step — the re-render primitive behind the host's described layers
//! (text, shapes, Live Photos), whose raster, position and mask all change
//! together when a description is re-rendered.
//!
//! `with_layer_pixels` (doc.rs) deliberately DROPS a mask whose size no
//! longer matches the new pixels, because it cannot know what the mask
//! should become. A re-render that moves or rotates a description knows
//! exactly that — the host resampled the mask through the same map — so
//! this module lets it land the three together, keeping the mask invariant
//! (mask dimensions == pixel dimensions) by refusing anything else rather
//! than repairing it silently.

use std::sync::Arc;

use image::{GrayImage, RgbaImage};

use crate::doc::RzDocument;

impl RzDocument {
    /// Pure: layer `idx` takes `pixels` (any size), `offset`, and `mask`
    /// (`Some` must be exactly `pixels`' dimensions; `None` leaves the
    /// layer with no mask and resets `mask_enabled` to true, the
    /// `with_layer_pixels` convention). Name, opacity, blend, visibility,
    /// meta, style and clipped flag are kept; `mask_enabled` is kept when
    /// a mask is given (a disabled mask stays disabled through a
    /// re-render). `None` on an out-of-range index or a mask whose
    /// dimensions differ from the pixels' — the invariant is enforced
    /// here rather than repaired by dropping the mask, because the caller
    /// asked for that exact mask. Never an identical copy by intent (a
    /// replacement is always an edit), like `with_layer_pixels`.
    pub fn set_layer_content(
        &self,
        idx: usize,
        pixels: RgbaImage,
        offset: (i32, i32),
        mask: Option<GrayImage>,
    ) -> Option<Self> {
        self.layers.get(idx)?;
        if mask
            .as_ref()
            .is_some_and(|m| m.dimensions() != pixels.dimensions())
        {
            return None;
        }
        // Clone-then-mutate inline rather than through doc.rs's private
        // `with_layer`: that module is full, and this op sets three fields
        // the closure form would only obscure.
        let mut doc = self.clone();
        let layer = &mut doc.layers[idx];
        layer.pixels = Arc::new(pixels);
        layer.offset = offset;
        layer.mask = mask.map(Arc::new);
        if layer.mask.is_none() {
            layer.mask_enabled = true;
        }
        Some(doc)
    }
}
