//! rasterize-core: the image-processing core behind the C FFI declared in
//! `include/rasterize_core.h`.
//!
//! The safe internal API lives in the implementation modules; all unsafe
//! code is confined to the `ffi*` modules, whose shared plumbing lives in
//! `ffi_util`. This file declares modules and re-exports only.

mod adjust;
mod adjust_color;
mod adjust_curves;
mod adjust_lut;
mod adjust_map;
mod adjust_math;
mod adjust_mix;
mod adjust_parse;
mod adjust_tone;
mod adjust_white_balance;
pub mod agent;
pub mod assistant;
mod blend;
pub mod doc;
pub mod doc_channel;
pub mod doc_color;
pub mod doc_content;
pub mod doc_heal;
pub mod doc_inpaint;
pub mod doc_paint;
pub mod doc_perspective;
pub mod doc_plane;
pub mod doc_redeye;
pub mod doc_retouch;
pub mod doc_select;
pub mod doc_transform;
pub mod ffi;
pub mod ffi_adjust;
pub mod ffi_agent;
pub mod ffi_assistant;
pub mod ffi_channel;
pub mod ffi_color;
pub mod ffi_doc;
pub mod ffi_filters;
pub mod ffi_heal;
pub mod ffi_style;
mod ffi_util;
pub mod icc;
mod icc_builtin;
pub mod icc_transform;
mod inpaint_em;
mod inpaint_plan;
mod inpaint_preview;
mod lab;
pub mod metadata;
mod metadata_write;
mod metadata_xmp;
mod ops;
mod ops_auto;
mod ops_filters;
mod ops_stats;
mod patchmatch;
mod patchmatch_nnf;
pub mod poisson;
mod psd;
mod rng;
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
