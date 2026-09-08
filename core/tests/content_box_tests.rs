//! The CONTENT box (`rz_doc_layer_bounds`) against the memo that fronts its
//! per-pixel scan (`doc_group_query`'s foot).
//!
//! The memo is keyed on the pixel and mask `Arc` allocations plus the offset,
//! so every one of these tests changes exactly one of those three and asks for
//! the box again: a stale answer — the failure a pointer-keyed cache can
//! actually have — is what they are here to catch. Black-box through the FFI,
//! like every other test in this crate.

use std::ffi::CString;

use image::{Rgba, RgbaImage};
use rasterize_core::doc::RzDocument;
use rasterize_core::ffi_doc::*;
use rasterize_core::ffi_group::*;
use tempfile::TempDir;

mod common;
use common::*;

fn bounds(doc: *const RzDocument, idx: usize) -> Option<(i32, i32, i32, i32)> {
    let mut out = [0i32; 4];
    unsafe { rz_doc_layer_bounds(doc, idx, out.as_mut_ptr()) }
        .then_some((out[0], out[1], out[2], out[3]))
}

/// A canvas-sized transparent buffer with one opaque rectangle — the sparse
/// shape a paste, a text layer or a shape layer produces, and the one whose
/// box costs a real scan.
fn sparse(w: u32, h: u32, rect: (u32, u32, u32, u32)) -> RgbaImage {
    let mut img = RgbaImage::new(w, h);
    for y in rect.1..rect.1 + rect.3 {
        for x in rect.0..rect.0 + rect.2 {
            img.put_pixel(x, y, Rgba([255, 0, 0, 255]));
        }
    }
    img
}

/// A canvas-sized premultiplied overlay with one opaque rectangle, for
/// `rz_doc_painting_layer`.
fn overlay(w: u32, h: u32, rect: (u32, u32, u32, u32)) -> Vec<u8> {
    let mut buf = vec![0u8; (w * h * 4) as usize];
    for y in rect.1..rect.1 + rect.3 {
        for x in rect.0..rect.0 + rect.2 {
            let i = ((y * w + x) * 4) as usize;
            buf[i..i + 4].copy_from_slice(&[0, 0, 255, 255]);
        }
    }
    buf
}

#[test]
fn repeated_reads_agree_with_the_first() {
    let dir = TempDir::new().unwrap();
    let mut doc = doc_from(&dir, "bg.png", &solid(24, 24, [0, 0, 0, 255]));
    doc = add_layer(
        &dir,
        "sp.png",
        doc,
        0,
        &sparse(24, 24, (4, 6, 8, 4)),
        "Sparse",
    );
    let first = bounds(doc, 1);
    assert_eq!(first, Some((4, 6, 8, 4)));
    for _ in 0..4 {
        assert_eq!(bounds(doc, 1), first, "the memo must answer what it stored");
    }
    // A second document holding the SAME pixels (the layer was cloned by the
    // op above) must read the same box through the same entry.
    let moved = apply(doc, |d| unsafe { rz_doc_with_layer_offset(d, 1, 3, 2) });
    assert_eq!(
        bounds(moved, 1),
        Some((7, 8, 8, 4)),
        "the offset is part of the key"
    );
    unsafe { rz_doc_free(moved) };
}

#[test]
fn painting_a_layer_moves_its_box() {
    let dir = TempDir::new().unwrap();
    let mut doc = doc_from(&dir, "bg.png", &solid(24, 24, [0, 0, 0, 0]));
    doc = add_layer(
        &dir,
        "sp.png",
        doc,
        0,
        &sparse(24, 24, (4, 6, 8, 4)),
        "Sparse",
    );
    assert_eq!(bounds(doc, 1), Some((4, 6, 8, 4)));
    // Paint a second patch well away from the first: the box has to grow to
    // cover both, which it cannot do from a stale entry.
    let paint = overlay(24, 24, (16, 18, 4, 4));
    doc = apply(doc, |d| unsafe {
        rz_doc_painting_layer(d, 1, paint.as_ptr(), 24, 24, COMPOSITE_OVER, 1.0)
    });
    assert_eq!(bounds(doc, 1), Some((4, 6, 16, 16)));
    // Erasing the original patch shrinks it back onto the painted one.
    let erase = overlay(24, 24, (4, 6, 8, 4));
    doc = apply(doc, |d| unsafe {
        rz_doc_painting_layer(d, 1, erase.as_ptr(), 24, 24, COMPOSITE_ERASE, 1.0)
    });
    assert_eq!(bounds(doc, 1), Some((16, 18, 4, 4)));
    unsafe { rz_doc_free(doc) };
}

#[test]
fn a_mask_and_its_enabled_flag_are_part_of_the_key() {
    let dir = TempDir::new().unwrap();
    let mut doc = doc_from(&dir, "bg.png", &solid(16, 16, [0, 0, 0, 0]));
    doc = add_layer(
        &dir,
        "sp.png",
        doc,
        0,
        &sparse(16, 16, (2, 2, 10, 10)),
        "Sparse",
    );
    assert_eq!(bounds(doc, 1), Some((2, 2, 10, 10)));
    // A mask that reveals only the left half cuts the box down …
    let mut sel = vec![0u8; 16 * 16];
    for y in 0..16 {
        for x in 0..6 {
            sel[y * 16 + x] = 255;
        }
    }
    doc = apply(doc, |d| unsafe {
        rz_doc_adding_layer_mask(d, 1, MASK_FROM_SELECTION, sel.as_ptr(), 16, 16)
    });
    assert_eq!(
        bounds(doc, 1),
        Some((2, 2, 4, 10)),
        "the enabled mask applies"
    );
    // … and disabling it, which changes no pixel and no offset, restores it.
    doc = apply(doc, |d| unsafe {
        rz_doc_with_layer_mask_enabled(d, 1, false)
    });
    assert_eq!(
        bounds(doc, 1),
        Some((2, 2, 10, 10)),
        "a disabled mask keys as no mask, exactly as it reads"
    );
    doc = apply(doc, |d| unsafe {
        rz_doc_with_layer_mask_enabled(d, 1, true)
    });
    assert_eq!(bounds(doc, 1), Some((2, 2, 4, 10)));
    unsafe { rz_doc_free(doc) };
}

#[test]
fn two_layers_sharing_pixels_answer_for_their_own_offsets() {
    let dir = TempDir::new().unwrap();
    let mut doc = doc_from(&dir, "bg.png", &solid(32, 32, [0, 0, 0, 0]));
    doc = add_layer(
        &dir,
        "sp.png",
        doc,
        0,
        &sparse(32, 32, (1, 1, 4, 4)),
        "Sparse",
    );
    // Duplicate shares the ORIGINAL's pixel `Arc`, so the two entries differ
    // only in their offset — the case a pixels-only key would get wrong.
    doc = apply(doc, |d| unsafe { rz_doc_duplicating_layer(d, 1) });
    doc = apply(doc, |d| unsafe { rz_doc_with_layer_offset(d, 2, 10, 20) });
    assert_eq!(bounds(doc, 1), Some((1, 1, 4, 4)));
    assert_eq!(bounds(doc, 2), Some((11, 21, 4, 4)));
    assert_eq!(bounds(doc, 1), Some((1, 1, 4, 4)), "and back again");
    // A group's box is still the union over its subtree — folded from the two
    // memoized answers above.
    let name = CString::new("G").unwrap();
    let cap = unsafe { rz_doc_layer_count(doc) } + 1;
    let mut group = usize::MAX;
    let mut cleared = vec![0usize; cap];
    let mut cleared_len = 0usize;
    let mut reordered = vec![0usize; cap];
    let mut reordered_len = 0usize;
    let grouped = unsafe {
        rz_doc_group_layers(
            doc,
            [1usize, 2].as_ptr(),
            2,
            name.as_ptr(),
            &mut group,
            cleared.as_mut_ptr(),
            &mut cleared_len,
            reordered.as_mut_ptr(),
            &mut reordered_len,
            cap,
        )
    };
    assert!(!grouped.is_null());
    unsafe { rz_doc_free(doc) };
    assert_eq!(bounds(grouped, group), Some((1, 1, 14, 24)));
    unsafe { rz_doc_free(grouped) };
}

#[test]
fn an_empty_layer_has_no_box_however_often_it_is_asked() {
    let dir = TempDir::new().unwrap();
    let mut doc = doc_from(&dir, "bg.png", &solid(12, 12, [0, 0, 0, 0]));
    doc = add_layer(&dir, "empty.png", doc, 0, &RgbaImage::new(12, 12), "Empty");
    for _ in 0..3 {
        assert_eq!(bounds(doc, 1), None, "a `None` box memoizes as `None`");
    }
    // Painting into it gives it one.
    let paint = overlay(12, 12, (5, 5, 2, 2));
    doc = apply(doc, |d| unsafe {
        rz_doc_painting_layer(d, 1, paint.as_ptr(), 12, 12, COMPOSITE_OVER, 1.0)
    });
    assert_eq!(bounds(doc, 1), Some((5, 5, 2, 2)));
    unsafe { rz_doc_free(doc) };
}
