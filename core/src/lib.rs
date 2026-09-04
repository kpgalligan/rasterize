//! rasterize-core: the image-processing core behind the C FFI declared in
//! `include/rasterize_core.h`.
//!
//! The safe internal API lives in the implementation modules; all unsafe
//! code is confined to the `ffi*` modules, whose shared plumbing lives in
//! `ffi_util`. This file declares modules and re-exports only.

mod adjust;
pub mod agent;
pub mod assistant;
mod blend;
pub mod doc;
pub mod doc_channel;
pub mod doc_color;
pub mod doc_content;
pub mod doc_paint;
pub mod doc_perspective;
pub mod doc_plane;
pub mod doc_retouch;
pub mod doc_select;
pub mod doc_transform;
pub mod ffi;
pub mod ffi_agent;
pub mod ffi_assistant;
pub mod ffi_channel;
pub mod ffi_color;
pub mod ffi_doc;
pub mod ffi_filters;
pub mod ffi_style;
mod ffi_util;
pub mod icc;
mod icc_builtin;
pub mod icc_transform;
pub mod metadata;
mod metadata_write;
mod metadata_xmp;
mod ops;
mod ops_filters;
mod psd;
mod rz_image;
mod rzdc;
pub mod style;
mod style_blend_if;
mod style_cache;
mod style_composite;
mod style_effects;
mod style_fx_bevel_emboss;
mod style_fx_color_overlay;
mod style_fx_drop_shadow;
mod style_fx_gradient_overlay;
mod style_fx_inner_glow;
mod style_fx_inner_shadow;
mod style_fx_outer_glow;
mod style_fx_satin;
mod style_fx_stroke;
mod style_gradient;
mod style_json;
mod style_json_write;
mod style_model;
mod style_names;
mod style_render;
mod style_reuse;

pub(crate) use rz_image::Format;
pub use rz_image::RzImage;
