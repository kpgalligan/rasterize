//! `rz_doc_set_layer_content` — the atomic pixels + offset + mask
//! replacement behind the host's described-layer re-renders. Exercised
//! through the FFI wherever a C-visible surface exists; the one safe-API
//! test covers the refusal the shim cannot reach (it always builds a mask
//! at the pixels' own dimensions).

mod common;

use std::ptr;

use common::*;
use image::GrayImage;
use rasterize_core::doc::{MaskKind, RzDocument};
use rasterize_core::ffi_doc::*;
use tempfile::TempDir;

/// The fixture every test starts from: a 6-wide, `rows`-tall red canvas
/// under a 4x2 blue layer at (1, 1) whose mask reveals the canvas's left
/// half (x < 3), with metadata attached — every property a replacement must
/// carry across.
fn masked_fixture(dir: &TempDir, tag: &str, rows: u32) -> *mut RzDocument {
    let doc = ffi_mask_fixture(dir, tag, (6, rows), (4, 2), (1, 1));
    let sel = selection(6, rows, |x, _| if x < 3 { 255 } else { 0 });
    let doc = apply(doc, |d| unsafe {
        rz_doc_adding_layer_mask(d, 1, MASK_FROM_SELECTION, sel.as_ptr(), 6, rows)
    });
    set_meta(doc, 1, TEXT_META)
}

#[test]
fn set_layer_content_replaces_pixels_offset_and_mask_atomically() {
    let dir = TempDir::new().unwrap();
    let doc = masked_fixture(&dir, "content", 4);
    // A DISABLED mask must stay disabled through the replacement.
    let doc = apply(doc, |d| unsafe {
        rz_doc_with_layer_mask_enabled(d, 1, false)
    });
    assert_eq!(ffi_mask_flags(doc, 1), (true, false));

    let green = solid(3, 2, GREEN).into_raw();
    let mask: [u8; 6] = [255, 0, 255, 0, 255, 0];
    let out =
        unsafe { rz_doc_set_layer_content(doc, 1, green.as_ptr(), 3, 2, 2, 1, mask.as_ptr()) };
    assert!(!out.is_null(), "a well-formed replacement succeeds");

    assert_eq!(layer_dims(out, 1), (3, 2));
    assert_eq!(layer_offset(out, 1), (2, 1));
    assert_eq!(layer_pixels(out, 1), green, "the buffer landed verbatim");
    assert_eq!(
        ffi_mask_bytes(out, 1),
        mask.to_vec(),
        "the given mask landed verbatim"
    );
    assert_eq!(
        ffi_mask_flags(out, 1),
        (true, false),
        "a disabled mask stays disabled when a mask is given"
    );
    assert_eq!(
        ffi_meta(out, 1).as_deref(),
        Some(TEXT_META),
        "meta survives"
    );
    assert_eq!(layer_name(out, 1), "Top", "the name survives");

    // Re-enabled, the mask gates exactly the pixels it says: a checker of
    // green (255) and red-through (0) at the new position.
    let shown = apply(out, |d| unsafe {
        rz_doc_with_layer_mask_enabled(d, 1, true)
    });
    let flat = flat_pixels(shown);
    assert_eq!(pixel(&flat, 6, 2, 1), GREEN);
    assert_eq!(pixel(&flat, 6, 3, 1), RED, "mask 0 hides the layer");
    assert_eq!(pixel(&flat, 6, 4, 1), GREEN);
    assert_eq!(pixel(&flat, 6, 2, 2), RED);
    assert_eq!(pixel(&flat, 6, 3, 2), GREEN);
    assert_eq!(pixel(&flat, 6, 4, 2), RED);
    assert_eq!(pixel(&flat, 6, 1, 1), RED, "the old position is exposed");
    assert_eq!(pixel(&flat, 6, 5, 1), RED, "nothing past the new extent");

    // The input document is untouched.
    assert_eq!(layer_dims(doc, 1), (4, 2));
    assert_eq!(layer_offset(doc, 1), (1, 1));
    assert_eq!(layer_pixels(doc, 1), solid(4, 2, BLUE).into_raw());
    assert_eq!(ffi_mask_flags(doc, 1), (true, false));

    unsafe { rz_doc_free(shown) };
    unsafe { rz_doc_free(doc) };
}

#[test]
fn set_layer_content_with_null_mask_leaves_no_mask() {
    let dir = TempDir::new().unwrap();
    let doc = masked_fixture(&dir, "nomask", 4);
    // Disable first, so the reset of mask_enabled is observable afterwards.
    let doc = apply(doc, |d| unsafe {
        rz_doc_with_layer_mask_enabled(d, 1, false)
    });

    let white = solid(2, 2, WHITE).into_raw();
    let out = unsafe { rz_doc_set_layer_content(doc, 1, white.as_ptr(), 2, 2, 0, 0, ptr::null()) };
    assert!(!out.is_null());
    assert_eq!(
        ffi_mask_flags(out, 1),
        (false, false),
        "a NULL mask leaves the layer with no mask (and nothing to enable)"
    );
    assert_eq!(layer_dims(out, 1), (2, 2));
    assert_eq!(layer_offset(out, 1), (0, 0));
    assert_eq!(ffi_meta(out, 1).as_deref(), Some(TEXT_META));
    // The whole layer shows: nothing gates it any more.
    let flat = flat_pixels(out);
    assert_eq!(pixel(&flat, 6, 0, 0), WHITE);
    assert_eq!(pixel(&flat, 6, 1, 1), WHITE);

    // mask_enabled was reset to true along with the drop: a fresh
    // same-size mask arrives enabled, not inheriting the old disabled flag.
    let revealed = apply(out, |d| unsafe {
        rz_doc_adding_layer_mask(d, 1, MASK_REVEAL_ALL, ptr::null(), 0, 0)
    });
    assert_eq!(ffi_mask_flags(revealed, 1), (true, true));

    unsafe { rz_doc_free(revealed) };
    unsafe { rz_doc_free(doc) };
}

#[test]
fn set_layer_content_refuses_a_mismatched_mask() {
    // The shim builds its mask at the pixels' dimensions by construction,
    // so the domain refusal is only reachable through the safe API.
    let doc = mask_fixture((6, 4), (4, 2), (1, 1));
    let sel = selection(6, 4, |x, _| if x < 3 { 255 } else { 0 });
    let doc = doc
        .add_mask(1, MaskKind::FromSelection(&sel))
        .expect("mask from selection");

    let refused = doc.set_layer_content(1, solid(3, 2, GREEN), (0, 0), Some(GrayImage::new(2, 2)));
    assert!(
        refused.is_none(),
        "a mask whose dimensions differ from the pixels' is refused, not repaired"
    );
    let out_of_range = doc.set_layer_content(2, solid(3, 2, GREEN), (0, 0), None);
    assert!(out_of_range.is_none(), "an out-of-range index is refused");

    // The exact-size mask goes through, and the invariant holds afterwards.
    let accepted = doc
        .set_layer_content(1, solid(3, 2, GREEN), (0, 0), Some(GrayImage::new(3, 2)))
        .expect("a same-size mask is accepted");
    assert_mask_invariant(&accepted, "after set_layer_content");
    assert_mask_invariant(&doc, "the input");
    assert_eq!(doc.layers[1].pixels.dimensions(), (4, 2), "input untouched");
}

#[test]
fn set_layer_content_null_and_range_guards() {
    let null_doc: *const RzDocument = ptr::null();
    let px = [0u8; 16]; // a 2x2 RGBA8 buffer
    let mask = [255u8; 4];

    unsafe {
        assert!(
            rz_doc_set_layer_content(null_doc, 0, px.as_ptr(), 2, 2, 0, 0, ptr::null()).is_null()
        );
        assert!(
            rz_doc_set_layer_content(null_doc, 0, px.as_ptr(), 2, 2, 0, 0, mask.as_ptr()).is_null()
        );
    }

    let dir = TempDir::new().unwrap();
    let doc = masked_fixture(&dir, "guards", 4);
    unsafe {
        // Out-of-range index.
        assert!(rz_doc_set_layer_content(doc, 2, px.as_ptr(), 2, 2, 0, 0, ptr::null()).is_null());
        // A NULL buffer, a zero dimension, or dimensions past the pixel
        // ceiling are refused before any slice is built from them.
        assert!(rz_doc_set_layer_content(doc, 1, ptr::null(), 2, 2, 0, 0, ptr::null()).is_null());
        assert!(rz_doc_set_layer_content(doc, 1, px.as_ptr(), 0, 2, 0, 0, ptr::null()).is_null());
        assert!(rz_doc_set_layer_content(doc, 1, px.as_ptr(), 2, 0, 0, 0, ptr::null()).is_null());
        assert!(
            rz_doc_set_layer_content(doc, 1, px.as_ptr(), 100_001, 1_000, 0, 0, ptr::null())
                .is_null()
        );
        assert!(rz_doc_set_layer_content(
            doc,
            1,
            px.as_ptr(),
            u32::MAX,
            u32::MAX,
            0,
            0,
            ptr::null()
        )
        .is_null());
        // No refused call changed anything.
        assert_eq!(layer_dims(doc, 1), (4, 2));
        assert_eq!(layer_offset(doc, 1), (1, 1));
        assert_eq!(ffi_mask_flags(doc, 1), (true, true));
        assert_eq!(ffi_meta(doc, 1).as_deref(), Some(TEXT_META));
    }
    unsafe { rz_doc_free(doc) };
}

#[test]
fn set_layer_content_pairs_with_transform_layer_for_a_re_render() {
    // The described-layer scenario the export exists for: the host runs the
    // core's transform to obtain the resampled mask at the transformed rect,
    // then lands its OWN re-rendered pixels together with that mask at that
    // rect, and the mask must still gate the same canvas pixels.
    let dir = TempDir::new().unwrap();
    // Six rows: the turned layer reaches canvas row 4, which must exist for
    // the hidden-row check below.
    let doc = masked_fixture(&dir, "rerender", 6);

    // An exact quarter turn: (x, y) -> (-y + 4, x). The 4x2 layer at (1, 1)
    // lands as 2x4 at (1, 1); its mask (source columns 0 and 1 revealed)
    // becomes destination rows 0 and 1 revealed.
    let quarter = [0.0f64, 1.0, -1.0, 0.0, 4.0, 0.0];
    let turned = apply(doc, |d| unsafe {
        rz_doc_transform_layer(d, 1, quarter.as_ptr(), FILTER_NEAREST)
    });
    assert_eq!(layer_dims(turned, 1), (2, 4));
    assert_eq!(layer_offset(turned, 1), (1, 1));
    let mask = ffi_mask_bytes(turned, 1);
    assert_eq!(mask, vec![255, 255, 255, 255, 0, 0, 0, 0]);

    let green = solid(2, 4, GREEN).into_raw();
    let rerendered =
        unsafe { rz_doc_set_layer_content(turned, 1, green.as_ptr(), 2, 4, 1, 1, mask.as_ptr()) };
    assert!(!rerendered.is_null());
    assert_eq!(ffi_mask_flags(rerendered, 1), (true, true));
    assert_eq!(ffi_meta(rerendered, 1).as_deref(), Some(TEXT_META));

    // Independent oracle: a same-size pixel swap through the OTHER setter
    // keeps the core's own resampled mask in place — the two projections
    // must agree everywhere.
    let swapped = unsafe { rz_doc_with_layer_pixels_rgba(turned, 1, green.as_ptr(), 2, 4) };
    assert!(!swapped.is_null());
    assert_eq!(flat_pixels(rerendered), flat_pixels(swapped));

    // And the mask gates the canvas pixels the quarter turn says it should.
    let flat = flat_pixels(rerendered);
    for x in 1..3 {
        assert_eq!(pixel(&flat, 6, x, 1), GREEN, "revealed row");
        assert_eq!(pixel(&flat, 6, x, 2), GREEN, "revealed row");
        assert_eq!(
            pixel(&flat, 6, x, 3),
            RED,
            "hidden row shows the red canvas"
        );
        assert_eq!(
            pixel(&flat, 6, x, 4),
            RED,
            "hidden row shows the red canvas"
        );
    }

    unsafe { rz_doc_free(swapped) };
    unsafe { rz_doc_free(rerendered) };
    unsafe { rz_doc_free(turned) };
}

/// Grouping is a pure RE-PARENT, so a described layer must come out of it with
/// its description byte for byte — the host's whole re-render contract rests on
/// the meta describing the CURRENT pixels, and a group that quietly rasterized
/// or re-rendered its children would break it silently. And a GROUP is never a
/// described layer, so the re-render primitive refuses one outright rather than
/// writing pixels a group does not have.
#[test]
fn grouping_a_described_layer_keeps_its_description_and_a_group_has_none() {
    let dir = TempDir::new().unwrap();
    let doc = masked_fixture(&dir, "grouped", 4);
    let before_pixels = layer_pixels(doc, 1);
    let before_mask = ffi_mask_bytes(doc, 1);
    assert_eq!(ffi_meta(doc, 1).as_deref(), Some(TEXT_META));

    let set = [1usize];
    let cname = std::ffi::CString::new("G").unwrap();
    let mut group_idx = usize::MAX;
    let grouped = apply(doc, |d| unsafe {
        rasterize_core::ffi_group::rz_doc_group_layers(
            d,
            set.as_ptr(),
            1,
            cname.as_ptr(),
            &mut group_idx,
            ptr::null_mut(),
            ptr::null_mut(),
            ptr::null_mut(),
            ptr::null_mut(),
            0,
        )
    });
    assert_eq!(group_idx, 2, "the group closes its child's run");
    assert_eq!(
        ffi_meta(grouped, 1).as_deref(),
        Some(TEXT_META),
        "the description survives the re-parent unchanged"
    );
    assert_eq!(layer_pixels(grouped, 1), before_pixels, "so do the pixels");
    assert_eq!(ffi_mask_bytes(grouped, 1), before_mask, "and the mask");
    assert_eq!(
        ffi_meta(grouped, group_idx),
        None,
        "the group itself carries no description"
    );
    assert!(
        !unsafe { rz_doc_layer_is_adjustment(grouped, group_idx) },
        "and the core never reads a group's metadata as an adjustment"
    );

    // The re-render primitive refuses the group: it has no pixels to replace.
    let green = solid(3, 2, GREEN).into_raw();
    assert!(
        unsafe {
            rz_doc_set_layer_content(grouped, group_idx, green.as_ptr(), 3, 2, 0, 0, ptr::null())
        }
        .is_null(),
        "set_layer_content refuses a group index"
    );
    // ...and ungrouping gives the described layer back, still described.
    let dissolved = apply(grouped, |d| unsafe {
        rasterize_core::ffi_group::rz_doc_ungroup_layer(
            d,
            group_idx,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            0,
        )
    });
    assert_eq!(ffi_meta(dissolved, 1).as_deref(), Some(TEXT_META));
    assert_eq!(layer_pixels(dissolved, 1), before_pixels);
    unsafe { rz_doc_free(dissolved) };
}
