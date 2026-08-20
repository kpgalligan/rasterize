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
pub mod doc_perspective;
pub mod doc_select;
pub mod doc_transform;
pub mod ffi;
pub mod ffi_agent;
pub mod ffi_assistant;
pub mod ffi_doc;
pub mod ffi_filters;
mod ffi_util;
mod ops;
mod ops_filters;
mod psd;
mod rz_image;
mod rzdc;

pub(crate) use rz_image::Format;
pub use rz_image::RzImage;
