//! Layer-mask tests: the model's mask semantics and the `rz_doc_*_mask`
//! FFI entry points, the masks-and-meta completeness sweep, layer metadata,
//! and clipping masks. Shared fixtures live in `tests/common`.

use std::ffi::{c_char, CString};
use std::ptr;

use image::{Rgba, RgbaImage};
use rasterize_core::doc::{BlendMode, MaskKind, RzDocument};
use rasterize_core::ffi::*;
use rasterize_core::ffi_doc::*;
use tempfile::TempDir;

mod common;
use common::*;

// -------------------------------------------------------------- layer masks --
//
// The model's own semantics, driven through the safe Rust API on
// `RzDocument`; the `rz_doc_*_mask` entry points that wrap it get their own
// section at the end of this file.

/// Normal-mode source-over of an opaque source onto an opaque backdrop at
/// effective alpha `sa`, quantized exactly like the compositor.
fn over_opaque(bg: [u8; 4], src: [u8; 4], sa: f32) -> [u8; 4] {
    let mut out = [0u8; 4];
    for c in 0..3 {
        let v = sa * f32::from(src[c]) / 255.0 + (1.0 - sa) * f32::from(bg[c]) / 255.0;
        out[c] = (v.clamp(0.0, 1.0) * 255.0).round() as u8;
    }
    out[3] = 255;
    out
}

fn flat(doc: &RzDocument, x: u32, y: u32) -> [u8; 4] {
    doc.flattened().get_pixel(x, y).0
}

#[test]
fn mask_gates_layer_coverage() {
    // 4x2 canvas, full-canvas blue layer, mask columns 0/0/128/255.
    let doc = mask_fixture((4, 2), (4, 2), (0, 0));
    let sel = selection(4, 2, |x, _| match x {
        2 => 128,
        3 => 255,
        _ => 0,
    });
    let masked = doc
        .add_mask(1, MaskKind::FromSelection(&sel))
        .expect("mask");
    assert_eq!(mask_bytes(&masked, 1), sel, "mask copies the selection 1:1");

    for y in 0..2 {
        assert_eq!(flat(&masked, 0, y), RED, "hidden half shows the backdrop");
        assert_eq!(flat(&masked, 1, y), RED, "hidden half shows the backdrop");
        assert_eq!(
            flat(&masked, 2, y),
            over_opaque(RED, BLUE, 128.0 / 255.0),
            "intermediate mask value is partial coverage"
        );
        assert_eq!(flat(&masked, 3, y), BLUE, "revealed half shows the layer");
    }
    // Adding a mask replaces any earlier one.
    let hidden = masked.add_mask(1, MaskKind::HideAll).expect("hide all");
    assert_eq!(mask_bytes(&hidden, 1), vec![0u8; 8]);
    assert!(hidden.layers[1].mask_enabled);
    for x in 0..4 {
        assert_eq!(flat(&hidden, x, 0), RED, "hide-all mask hides everything");
    }
    let shown = hidden.add_mask(1, MaskKind::RevealAll).expect("reveal all");
    assert_eq!(mask_bytes(&shown, 1), vec![255u8; 8]);
    assert_eq!(flat(&shown, 0, 0), BLUE, "reveal-all mask changes nothing");

    // A canvas-sized selection is required.
    assert!(doc
        .add_mask(1, MaskKind::FromSelection(&sel[..7]))
        .is_none());
    assert!(doc.add_mask(9, MaskKind::RevealAll).is_none());
}

#[test]
fn disabled_mask_composites_like_no_mask() {
    // Non-trivial layer properties so the comparison covers the whole kernel.
    let plain = mask_fixture((4, 2), (4, 2), (0, 0));
    let plain = plain.with_layer_opacity(1, 0.6).unwrap();
    let plain = plain
        .with_layer_blend_mode(1, rasterize_core::doc::BlendMode::Multiply)
        .unwrap();
    let sel = selection(4, 2, |x, _| if x < 2 { 0 } else { 200 });
    let masked = plain.add_mask(1, MaskKind::FromSelection(&sel)).unwrap();
    assert_ne!(
        masked.flattened().into_raw(),
        plain.flattened().into_raw(),
        "the enabled mask must change the projection"
    );

    let disabled = masked.set_mask_enabled(1, false).expect("disable");
    assert!(!disabled.layers[1].mask_enabled);
    assert!(disabled.layers[1].mask.is_some(), "mask is retained");
    assert_eq!(
        disabled.flattened().into_raw(),
        plain.flattened().into_raw(),
        "a disabled mask composites exactly like no mask at all"
    );
    // Re-enabling restores the masked projection.
    let reenabled = disabled.set_mask_enabled(1, true).unwrap();
    assert_eq!(
        reenabled.flattened().into_raw(),
        masked.flattened().into_raw()
    );
    // No mask: nothing to enable.
    assert!(plain.set_mask_enabled(1, false).is_none());
    assert!(plain.set_mask_enabled(9, true).is_none());
}

#[test]
fn mask_and_layer_opacity_multiply() {
    let doc = mask_fixture((3, 1), (3, 1), (0, 0));
    let doc = doc.with_layer_opacity(1, 0.5).unwrap();
    let sel = selection(3, 1, |x, _| [0, 128, 255][x as usize]);
    let masked = doc.add_mask(1, MaskKind::FromSelection(&sel)).unwrap();
    for (x, cov) in [0u8, 128, 255].into_iter().enumerate() {
        let sa = f32::from(cov) / 255.0 * 0.5;
        assert_eq!(
            flat(&masked, x as u32, 0),
            over_opaque(RED, BLUE, sa),
            "coverage {cov} times opacity 0.5"
        );
    }
}

#[test]
fn add_mask_from_selection_crops_to_the_layer_rect() {
    // 5x3 canvas; a 4x2 layer at (-1, 1) hangs off the left edge and its
    // bottom row sits on the canvas' last row.
    let doc = mask_fixture((5, 3), (4, 2), (-1, 1));
    // Distinctive per-canvas-pixel values so a mis-mapping cannot pass.
    let sel = selection(5, 3, |x, y| (x * 10 + y + 1) as u8);
    let masked = doc.add_mask(1, MaskKind::FromSelection(&sel)).unwrap();
    let mask = mask_bytes(&masked, 1);
    assert_eq!(mask.len(), 4 * 2, "mask is exactly the layer's size");
    for ly in 0..2u32 {
        for lx in 0..4u32 {
            let cx = lx as i64 - 1;
            let cy = ly as i64 + 1;
            let expected = if !(0..5).contains(&cx) || cy >= 3 {
                0
            } else {
                sel[cy as usize * 5 + cx as usize]
            };
            assert_eq!(
                mask[(ly * 4 + lx) as usize],
                expected,
                "layer pixel ({lx},{ly}) -> canvas ({cx},{cy})"
            );
        }
    }
    // Column 0 is off-canvas, so it is hidden; the rest follows the selection.
    assert_eq!(mask[0], 0);
    assert_eq!(mask[1], sel[5], "layer (1,0) -> canvas (0,1)");
}

#[test]
fn remove_mask_applies_or_discards() {
    let doc = mask_fixture((4, 2), (4, 2), (0, 0));
    let sel = selection(4, 2, |x, _| (x * 85) as u8);
    let masked = doc.add_mask(1, MaskKind::FromSelection(&sel)).unwrap();
    let masked_flat = masked.flattened().into_raw();

    // apply: the coverage is baked into the layer's alpha and the projection
    // is byte-identical to the masked one.
    let applied = masked.remove_mask(1, true).expect("apply");
    assert!(applied.layers[1].mask.is_none());
    assert!(applied.layers[1].mask_enabled);
    for (i, &cov) in sel.iter().enumerate() {
        assert_eq!(
            applied.layers[1].pixels.as_raw()[i * 4 + 3],
            cov,
            "alpha {i} baked from coverage"
        );
    }
    assert_eq!(
        applied.flattened().into_raw(),
        masked_flat,
        "applying a mask must not change the projection"
    );

    // apply also bakes a DISABLED mask (the flag only affects compositing).
    let disabled = masked.set_mask_enabled(1, false).unwrap();
    let applied_disabled = disabled.remove_mask(1, true).expect("apply disabled");
    assert_eq!(
        applied_disabled.layers[1].pixels.as_raw(),
        applied.layers[1].pixels.as_raw()
    );

    // no apply: the layer is revealed in full again.
    let dropped = masked.remove_mask(1, false).expect("drop");
    assert!(dropped.layers[1].mask.is_none());
    assert_eq!(
        dropped.flattened().into_raw(),
        doc.flattened().into_raw(),
        "dropping a mask reveals the layer"
    );
    assert_eq!(
        dropped.layers[1].pixels.as_raw(),
        doc.layers[1].pixels.as_raw(),
        "dropping must not touch pixels"
    );

    // No mask, nothing to remove.
    assert!(doc.remove_mask(1, true).is_none());
    assert!(doc.remove_mask(9, false).is_none());
}

#[test]
fn paint_mask_lerps_overlay_luma_by_alpha() {
    // 5x2 canvas, 4x2 layer at (1, 0): mask row 0 starts hidden, row 1 shown.
    let doc = mask_fixture((5, 2), (4, 2), (1, 0));
    let sel = selection(5, 2, |_, y| if y == 0 { 0 } else { 255 });
    let masked = doc.add_mask(1, MaskKind::FromSelection(&sel)).unwrap();
    assert_eq!(mask_bytes(&masked, 1), vec![0, 0, 0, 0, 255, 255, 255, 255]);

    // Canvas-frame PREMULTIPLIED overlay, one behavior per canvas column:
    // 0 opaque white (outside the layer), 1 opaque white, 2 half black,
    // 3 transparent, 4 half white.
    let mut overlay = vec![0u8; 5 * 2 * 4];
    for y in 0..2usize {
        for (x, px) in [
            [255u8, 255, 255, 255],
            [255, 255, 255, 255],
            [0, 0, 0, 128],
            [0, 0, 0, 0],
            [128, 128, 128, 128],
        ]
        .into_iter()
        .enumerate()
        {
            let i = (y * 5 + x) * 4;
            overlay[i..i + 4].copy_from_slice(&px);
        }
    }
    let painted = masked.paint_mask(1, &overlay).expect("paint");
    assert_eq!(
        mask_bytes(&painted, 1),
        vec![
            // row 0, from 0: white reveals, half black stays, transparent
            // keeps, half white lands mid-way.
            255, 0, 0, 128, // row 1, from 255: white keeps, half black lands
            // mid-way, transparent keeps, half white keeps.
            255, 127, 255, 255,
        ]
    );

    // The revealed footprint is exactly what the flattened image shows.
    assert_eq!(flat(&painted, 1, 0), BLUE, "painted white reveals");
    assert_eq!(flat(&painted, 2, 0), RED, "unpainted stays hidden");
    assert_eq!(
        flat(&painted, 3, 0),
        RED,
        "transparent overlay changes nothing"
    );
    assert_eq!(
        flat(&painted, 4, 0),
        over_opaque(RED, BLUE, 128.0 / 255.0),
        "half-alpha white is half coverage"
    );
    assert_eq!(
        flat(&painted, 2, 1),
        over_opaque(RED, BLUE, 127.0 / 255.0),
        "half-alpha black halves an already-revealed pixel"
    );

    // Painting an opaque white overlay over a hide-all mask reveals exactly
    // the painted footprint and nothing else.
    let hidden = doc.add_mask(1, MaskKind::HideAll).unwrap();
    let mut stroke = vec![0u8; 5 * 2 * 4];
    let i = 2 * 4; // canvas (2, 0) -> layer (1, 0)
    stroke[i..i + 4].copy_from_slice(&[255, 255, 255, 255]);
    let stroked = hidden.paint_mask(1, &stroke).expect("stroke");
    assert_eq!(mask_bytes(&stroked, 1), vec![0, 255, 0, 0, 0, 0, 0, 0]);
    assert_eq!(flat(&stroked, 2, 0), BLUE);
    assert_eq!(flat(&stroked, 1, 0), RED);

    // Guards: no mask, wrong buffer size, layer entirely off-canvas.
    assert!(doc.paint_mask(1, &overlay).is_none());
    assert!(masked.paint_mask(1, &overlay[..39]).is_none());
    assert!(masked.paint_mask(9, &overlay).is_none());
    let off = masked.with_layer_offset(1, 50, 50).unwrap();
    assert!(off.paint_mask(1, &overlay).is_none());
}

#[test]
fn mask_image_is_opaque_grayscale() {
    let doc = mask_fixture((3, 1), (3, 1), (0, 0));
    let sel = selection(3, 1, |x, _| [0, 128, 255][x as usize]);
    let masked = doc.add_mask(1, MaskKind::FromSelection(&sel)).unwrap();
    let img = masked.mask_image(1).expect("mask image");
    assert_eq!(img.dimensions(), (3, 1));
    assert_eq!(img.get_pixel(0, 0).0, [0, 0, 0, 255]);
    assert_eq!(img.get_pixel(1, 0).0, [128, 128, 128, 255]);
    assert_eq!(img.get_pixel(2, 0).0, [255, 255, 255, 255]);
    assert!(doc.mask_image(1).is_none(), "no mask, no image");
    assert!(masked.mask_image(9).is_none());
}

#[test]
fn duplicating_layer_copies_mask_enabled_and_meta() {
    let doc = mask_fixture((4, 2), (4, 2), (1, 0));
    let sel = selection(4, 2, |x, y| (x + y * 4) as u8);
    let mut masked = doc.add_mask(1, MaskKind::FromSelection(&sel)).unwrap();
    masked = masked.set_mask_enabled(1, false).unwrap();
    masked.layers[1].meta = Some("{\"type\":\"text\",\"string\":\"hi\"}".to_string());

    let dup = masked.duplicating_layer(1).expect("duplicate");
    assert_eq!(dup.layers.len(), 3);
    assert_eq!(dup.layers[2].name, "Top copy");
    assert_eq!(mask_bytes(&dup, 2), mask_bytes(&masked, 1));
    assert!(!dup.layers[2].mask_enabled, "enabled flag copies");
    assert_eq!(dup.layers[2].meta, masked.layers[1].meta, "meta copies");
}

#[test]
fn masks_follow_layer_geometry_and_scaling() {
    let doc = mask_fixture((4, 2), (4, 2), (0, 0));
    let sel = selection(4, 2, |x, y| if x == 0 && y == 0 { 255 } else { 0 });
    let masked = doc.add_mask(1, MaskKind::FromSelection(&sel)).unwrap();

    // Rotating the document rotates the mask with the pixels, so the mask
    // keeps the layer's dimensions and the projection commutes.
    let rotated = masked.rotate90();
    assert_eq!(
        rotated.layers[1].mask.as_ref().unwrap().dimensions(),
        (2, 4)
    );
    assert_eq!(
        rotated.flattened().into_raw(),
        image::imageops::rotate90(&masked.flattened()).into_raw(),
        "rotate90 must commute with the masked projection"
    );
    let flipped = masked.flip_horizontal();
    assert_eq!(mask_bytes(&flipped, 1), vec![0, 0, 0, 255, 0, 0, 0, 0]);

    // Scaling scales the mask alongside the pixels.
    let resized = masked
        .resize(8, 4, image::imageops::FilterType::Nearest)
        .unwrap();
    let mask = resized.layers[1].mask.as_ref().unwrap();
    assert_eq!(mask.dimensions(), (8, 4));
    assert_eq!(mask.get_pixel(0, 0).0[0], 255);
    assert_eq!(mask.get_pixel(7, 3).0[0], 0);

    // Replacing the pixels with a differently sized buffer drops the mask
    // rather than leaving a mismatched one behind.
    let same = masked.with_layer_pixels(1, solid(4, 2, BLUE)).unwrap();
    assert!(same.layers[1].mask.is_some(), "same size keeps the mask");
    let smaller = masked.with_layer_pixels(1, solid(2, 1, BLUE)).unwrap();
    assert!(smaller.layers[1].mask.is_none(), "resize drops the mask");

    // Merging down bakes an enabled mask into the pixels and drops it.
    let merged = masked.merging_down(1).expect("merge");
    assert_eq!(merged.layers.len(), 1);
    assert!(merged.layers[0].mask.is_none());
    assert_eq!(
        merged.flattened().into_raw(),
        masked.flattened().into_raw(),
        "merging a masked layer preserves the projection"
    );
}

#[test]
fn rzdc_round_trips_masks_and_meta() {
    let dir = TempDir::new().unwrap();
    let doc = mask_fixture((5, 3), (4, 2), (-1, 1));
    // Layer 1: a disabled mask plus meta. Layer 2: an enabled mask.
    let sel = selection(5, 3, |x, y| (x * 17 + y * 3) as u8);
    let mut doc = doc.add_mask(1, MaskKind::FromSelection(&sel)).unwrap();
    doc = doc.set_mask_enabled(1, false).unwrap();
    doc.layers[1].meta = Some("{\"type\":\"text\",\"string\":\"héllo 层\"}".to_string());
    let doc = doc
        .adding_image_layer(1, solid(3, 3, [10, 200, 30, 128]), "Top2")
        .unwrap();
    let doc = doc.add_mask(2, MaskKind::HideAll).unwrap();
    let doc = doc.add_mask(2, MaskKind::FromSelection(&sel)).unwrap();

    let path = dir.path().join("masked.rzdc");
    let spath = path.to_str().unwrap().to_string();
    doc.save_native(&spath).expect("save");
    let bytes = std::fs::read(&path).unwrap();
    assert_eq!(&bytes[..4], b"RZDC");
    assert_eq!(
        u32::from_le_bytes(bytes[4..8].try_into().unwrap()),
        3,
        "the writer always writes the current version"
    );

    let back = RzDocument::open(&spath).expect("reopen");
    assert_eq!(back.layers.len(), 3);
    assert!(
        back.layers[0].mask.is_none(),
        "unmasked layer stays unmasked"
    );
    assert!(back.layers[0].mask_enabled);
    assert_eq!(back.layers[0].meta, None);
    for idx in [1usize, 2] {
        assert_eq!(
            mask_bytes(&back, idx),
            mask_bytes(&doc, idx),
            "layer {idx} mask"
        );
        assert_eq!(
            back.layers[idx].mask_enabled, doc.layers[idx].mask_enabled,
            "layer {idx} mask_enabled"
        );
        assert_eq!(
            back.layers[idx].meta, doc.layers[idx].meta,
            "layer {idx} meta"
        );
    }
    assert!(!back.layers[1].mask_enabled);
    assert!(back.layers[2].mask_enabled);
    assert_eq!(
        back.flattened().into_raw(),
        doc.flattened().into_raw(),
        "projection survives the round trip"
    );

    // Saving the reopened document reproduces the file byte for byte.
    let again = dir.path().join("again.rzdc");
    back.save_native(again.to_str().unwrap()).expect("resave");
    assert_eq!(std::fs::read(&again).unwrap(), bytes);
}

#[test]
fn rzdc_version_1_files_still_load_without_masks() {
    let dir = TempDir::new().unwrap();
    let mut png = Vec::new();
    solid(2, 2, [1, 2, 3, 255])
        .write_to(&mut std::io::Cursor::new(&mut png), image::ImageFormat::Png)
        .unwrap();
    // A hand-built version-1 file: the layer record ends after the PNG.
    let mut v1 = Vec::new();
    v1.extend_from_slice(b"RZDC");
    v1.extend_from_slice(&1u32.to_le_bytes()); // version
    v1.extend_from_slice(&2u32.to_le_bytes()); // width
    v1.extend_from_slice(&2u32.to_le_bytes()); // height
    v1.extend_from_slice(&1u32.to_le_bytes()); // layer count
    v1.extend_from_slice(&3u32.to_le_bytes()); // name len
    v1.extend_from_slice(b"Old");
    v1.extend_from_slice(&0i32.to_le_bytes());
    v1.extend_from_slice(&0i32.to_le_bytes());
    v1.extend_from_slice(&1.0f32.to_le_bytes());
    v1.extend_from_slice(&0u32.to_le_bytes()); // blend
    v1.push(1); // visible
    v1.extend_from_slice(&(png.len() as u32).to_le_bytes());
    v1.extend_from_slice(&png);
    let path = dir.path().join("v1.rzdc");
    std::fs::write(&path, &v1).unwrap();

    let doc = RzDocument::open(path.to_str().unwrap()).expect("version 1 must still load");
    assert_eq!(doc.layers.len(), 1);
    assert_eq!(doc.layers[0].name, "Old");
    assert!(doc.layers[0].mask.is_none(), "version 1 has no masks");
    assert!(doc.layers[0].mask_enabled, "enabled defaults to true");
    assert_eq!(doc.layers[0].meta, None, "version 1 has no meta");

    // A future version is refused by number.
    let mut v4 = v1.clone();
    v4[4..8].copy_from_slice(&4u32.to_le_bytes());
    let future = dir.path().join("v4.rzdc");
    std::fs::write(&future, &v4).unwrap();
    let err = RzDocument::open(future.to_str().unwrap())
        .err()
        .expect("a future version must be refused");
    assert!(err.contains("unsupported RZDC version 4"), "got: {err}");

    // A version-2 file whose mask length disagrees with the layer's pixel
    // count is rejected instead of trusted.
    let mut bad = v1.clone();
    bad[4..8].copy_from_slice(&2u32.to_le_bytes());
    bad.push(1); // mask present
    bad.push(1); // mask enabled
    bad.extend_from_slice(&3u32.to_le_bytes()); // 3 bytes for a 2x2 layer
    bad.extend_from_slice(&[255, 255, 255]);
    bad.push(0); // no meta
    let bad_path = dir.path().join("bad-mask.rzdc");
    std::fs::write(&bad_path, &bad).unwrap();
    let err = RzDocument::open(bad_path.to_str().unwrap())
        .err()
        .expect("a mismatched mask length must be refused");
    assert!(err.contains("mask length"), "got: {err}");
}

// ------------------------------ masks & meta across every remaining path --
//
// Completeness pass over the paths that move a layer, change the canvas, or
// rebuild the stack. Two things are checked everywhere: the hard invariant
// (a mask is always exactly its layer's pixel size) and ALIGNMENT — the mask
// must go on hiding the same visible pixels, which only a comparison against
// the projection can show.

/// Runs the canvas-frame paint path over a safe document. `painting_layer`
/// is crate-private, so the FFI entry point is the only way in from here.
fn paint_over(doc: &RzDocument, idx: usize, overlay: &[u8]) -> RzDocument {
    let handle = Box::into_raw(Box::new(doc.clone()));
    let out = unsafe {
        rz_doc_painting_layer(
            handle,
            idx,
            overlay.as_ptr(),
            doc.width,
            doc.height,
            COMPOSITE_OVER,
            1.0,
        )
    };
    unsafe { rz_doc_free(handle) };
    assert!(!out.is_null(), "painting_layer must succeed");
    *unsafe { Box::from_raw(out) }
}

#[test]
fn crop_keeps_the_mask_aligned_with_its_layer() {
    // 6x4 canvas, 4x3 blue layer at (1, 1) over a red background.
    let doc = checkerboard_masked((6, 4), (4, 3), (1, 1));
    let before = doc.flattened();
    let mask_before = mask_bytes(&doc, 1);

    // Crop only moves the canvas window: pixels, mask and meta ride along
    // with the layer, so every surviving canvas pixel looks identical.
    let cropped = doc.crop(1, 1, 4, 3).expect("crop");
    assert_mask_invariant(&cropped, "crop");
    assert_eq!((cropped.width, cropped.height), (4, 3));
    assert_eq!(cropped.layers[1].offset, (0, 0));
    assert_eq!(cropped.layers[0].offset, (-1, -1));
    assert_eq!(
        mask_bytes(&cropped, 1),
        mask_before,
        "the mask is layer-space, so a window move must not touch it"
    );
    assert!(cropped.layers[1].mask_enabled);
    assert_eq!(cropped.layers[1].meta.as_deref(), Some(META));
    let after = cropped.flattened();
    for y in 0..3 {
        for x in 0..4 {
            assert_eq!(
                after.get_pixel(x, y).0,
                before.get_pixel(x + 1, y + 1).0,
                "cropped ({x},{y}) must hide/show exactly what it did before"
            );
        }
    }

    // A crop that leaves the masked layer entirely outside the window still
    // keeps a consistent mask (the layer is merely off-canvas now).
    let away = doc.crop(0, 0, 1, 1).expect("corner crop");
    assert_mask_invariant(&away, "crop to a corner");
    assert_eq!(mask_bytes(&away, 1), mask_before);
}

#[test]
fn canvas_resize_grow_and_shrink_keep_the_mask_aligned() {
    let doc = checkerboard_masked((6, 4), (4, 3), (1, 1));
    let before = doc.flattened();
    let mask_before = mask_bytes(&doc, 1);

    // Grow with the old canvas anchored at (2, 3) in the new one.
    let grown = doc.canvas_resize(10, 8, (2, 3)).expect("grow");
    assert_mask_invariant(&grown, "canvas grow");
    assert_eq!((grown.width, grown.height), (10, 8));
    assert_eq!(grown.layers[1].offset, (3, 4));
    assert_eq!(mask_bytes(&grown, 1), mask_before, "growing moves nothing");
    assert_eq!(grown.layers[1].meta.as_deref(), Some(META));
    let after = grown.flattened();
    for y in 0..8 {
        for x in 0..10 {
            let inside = (2..8).contains(&x) && (3..7).contains(&y);
            let expected = if inside {
                before.get_pixel(x - 2, y - 3).0
            } else {
                [0, 0, 0, 0]
            };
            assert_eq!(
                after.get_pixel(x, y).0,
                expected,
                "grown ({x},{y}) must match the anchored old canvas"
            );
        }
    }

    // Shrink around the same content: a negative origin, i.e. exactly a crop.
    let shrunk = doc.canvas_resize(3, 2, (-2, -1)).expect("shrink");
    assert_mask_invariant(&shrunk, "canvas shrink");
    assert_eq!((shrunk.width, shrunk.height), (3, 2));
    assert_eq!(shrunk.layers[1].offset, (-1, 0));
    assert_eq!(
        mask_bytes(&shrunk, 1),
        mask_before,
        "shrinking moves nothing"
    );
    let after = shrunk.flattened();
    for y in 0..2 {
        for x in 0..3 {
            assert_eq!(
                after.get_pixel(x, y).0,
                before.get_pixel(x + 2, y + 1).0,
                "shrunk ({x},{y}) must hide/show exactly what it did before"
            );
        }
    }
    assert_eq!(
        after.into_raw(),
        doc.crop(2, 1, 3, 2).unwrap().flattened().into_raw(),
        "a shrink with a negative origin is the matching crop, masks included"
    );
}

#[test]
fn whole_document_transforms_preserve_meta_and_the_invariant() {
    let doc = checkerboard_masked((6, 4), (4, 3), (1, 1));
    let variants = [
        ("rotate90", doc.rotate90()),
        ("rotate180", doc.rotate180()),
        ("rotate270", doc.rotate270()),
        ("flip_horizontal", doc.flip_horizontal()),
        ("flip_vertical", doc.flip_vertical()),
        ("crop", doc.crop(1, 1, 4, 3).expect("crop")),
        (
            "canvas_resize",
            doc.canvas_resize(9, 7, (2, 2)).expect("canvas resize"),
        ),
        (
            "resize",
            doc.resize(12, 8, image::imageops::FilterType::Nearest)
                .expect("resize"),
        ),
        (
            // A scale whose per-layer rounding is not exact: pixels and mask
            // must round to the SAME dimensions, not merely to close ones.
            "resize (fractional)",
            doc.resize(7, 5, image::imageops::FilterType::Triangle)
                .expect("fractional resize"),
        ),
    ];
    for (name, out) in variants {
        assert_mask_invariant(&out, name);
        assert!(out.layers[1].mask.is_some(), "{name} must keep the mask");
        assert!(
            out.layers[1].mask_enabled,
            "{name} must keep the enabled flag"
        );
        assert_eq!(
            out.layers[1].meta.as_deref(),
            Some(META),
            "{name} must keep the layer's meta"
        );
    }

    // Chaining them cannot drift either.
    let chained = doc
        .rotate90()
        .crop(0, 1, 4, 4)
        .expect("crop the rotated canvas")
        .resize(3, 3, image::imageops::FilterType::Nearest)
        .expect("resize the cropped canvas");
    assert_mask_invariant(&chained, "rotate90 -> crop -> resize");

    // A downscale that collapses the layer to a single pixel clamps pixels
    // and mask to the same 1x1, not to different sizes.
    let tiny = doc
        .resize(1, 1, image::imageops::FilterType::Nearest)
        .expect("collapse");
    assert_mask_invariant(&tiny, "collapse to 1x1");
    assert_eq!(tiny.layers[1].pixels.dimensions(), (1, 1));
}

#[test]
fn flattening_bakes_enabled_masks_and_drops_them() {
    // Background red; a masked blue layer; a half-opaque green layer whose
    // mask is DISABLED (so it must not be baked); a hidden masked layer.
    let doc = checkerboard_masked((4, 2), (3, 2), (1, 0));
    let doc = doc
        .adding_image_layer(1, solid(4, 2, GREEN), "Green")
        .unwrap();
    let doc = doc.with_layer_opacity(2, 0.5).unwrap();
    let doc = doc.add_mask(2, MaskKind::HideAll).unwrap();
    let doc = doc.set_mask_enabled(2, false).unwrap();
    let doc = doc
        .adding_image_layer(2, solid(4, 2, WHITE), "Hidden")
        .unwrap();
    let doc = doc.with_layer_visible(3, false).unwrap();
    let mut doc = doc.add_mask(3, MaskKind::RevealAll).unwrap();
    doc.layers[3].meta = Some(META.to_string());
    let projection = doc.flattened();

    let flat = doc.flattening();
    assert_mask_invariant(&flat, "flattening");
    assert_eq!(flat.layers.len(), 1);
    assert_eq!((flat.width, flat.height), (4, 2));
    assert_eq!(flat.layers[0].name, "Background");
    assert_eq!(flat.layers[0].offset, (0, 0));
    assert_eq!(flat.layers[0].pixels.dimensions(), (4, 2));
    assert!(
        flat.layers[0].mask.is_none(),
        "the composite has no mask left to apply"
    );
    assert!(
        flat.layers[0].mask_enabled,
        "the flag resets to the default"
    );
    assert_eq!(
        flat.layers[0].meta, None,
        "meta cannot describe a composite"
    );
    assert_eq!(
        flat.layers[0].pixels.as_raw(),
        projection.as_raw(),
        "the single layer IS the projection, enabled masks baked in"
    );
    assert_eq!(
        flat.flattened().into_raw(),
        projection.into_raw(),
        "flattening must not change what the document looks like"
    );

    // The enabled mask really participated: dropping it first changes the
    // result, so the equality above is not vacuous.
    let unmasked = doc.remove_mask(1, false).unwrap();
    assert_ne!(
        unmasked.flattening().layers[0].pixels.as_raw(),
        flat.layers[0].pixels.as_raw(),
        "the blue layer's enabled mask must affect the flattened pixels"
    );
}

#[test]
fn fill_gradient_and_paint_keep_the_layer_mask() {
    // 4x2 canvas and layer: columns 0-1 hidden by the mask, 2-3 revealed.
    let doc = mask_fixture((4, 2), (4, 2), (0, 0));
    let sel = selection(4, 2, |x, _| if x < 2 { 0 } else { 255 });
    let masked = doc.add_mask(1, MaskKind::FromSelection(&sel)).unwrap();
    let mask_before = mask_bytes(&masked, 1);

    // Bucket fill replaces the layer's pixels at the same size: the mask
    // survives and still gates exactly the same columns.
    let filled = masked
        .bucket_fill(1, 3, 0, 0, GREEN, true, None)
        .expect("bucket fill");
    assert_mask_invariant(&filled, "bucket_fill");
    assert_eq!(mask_bytes(&filled, 1), mask_before, "fill keeps the mask");
    assert!(filled.layers[1].mask_enabled);
    assert_eq!(
        filled.layers[1].pixels.get_pixel(0, 0).0,
        GREEN,
        "the fill itself is not gated by the mask, only the projection is"
    );
    for y in 0..2 {
        assert_eq!(flat(&filled, 0, y), RED, "hidden column shows the backdrop");
        assert_eq!(flat(&filled, 1, y), RED, "hidden column shows the backdrop");
        assert_eq!(flat(&filled, 2, y), GREEN, "revealed column shows the fill");
        assert_eq!(flat(&filled, 3, y), GREEN, "revealed column shows the fill");
    }

    // Gradients take the same same-size replacement path.
    let graded = masked
        .gradient(1, (0.0, 0.0), (4.0, 0.0), GREEN, WHITE, false, None)
        .expect("gradient");
    assert_mask_invariant(&graded, "gradient");
    assert_eq!(
        mask_bytes(&graded, 1),
        mask_before,
        "gradient keeps the mask"
    );
    for y in 0..2 {
        assert_eq!(flat(&graded, 0, y), RED, "hidden column shows the backdrop");
        assert_ne!(flat(&graded, 3, y), RED, "revealed column shows the ramp");
    }

    // So does the canvas-frame paint overlay (opaque white everywhere).
    let overlay = vec![255u8; 4 * 2 * 4];
    let painted = paint_over(&masked, 1, &overlay);
    assert_mask_invariant(&painted, "painting_layer");
    assert_eq!(mask_bytes(&painted, 1), mask_before, "paint keeps the mask");
    for y in 0..2 {
        assert_eq!(flat(&painted, 0, y), RED, "hidden column stays hidden");
        assert_eq!(flat(&painted, 3, y), WHITE, "revealed column takes paint");
    }

    // A DISABLED mask is retained across the same paths, flag included.
    let disabled = masked.set_mask_enabled(1, false).unwrap();
    let filled = disabled
        .bucket_fill(1, 3, 0, 0, GREEN, true, None)
        .expect("bucket fill");
    assert_eq!(mask_bytes(&filled, 1), mask_before);
    assert!(!filled.layers[1].mask_enabled, "the disabled flag survives");
}

#[test]
fn stack_ops_carry_masks_and_meta_with_their_layer() {
    let doc = checkerboard_masked((4, 2), (4, 2), (0, 0));
    let doc = doc.set_mask_enabled(1, false).expect("disable");
    let mask = mask_bytes(&doc, 1);

    // Inserting a fresh transparent layer below the masked one: the new layer
    // arrives unmasked, the masked one just shifts index.
    let added = doc.adding_layer(0, "New").expect("add layer");
    assert_mask_invariant(&added, "adding_layer");
    assert_eq!(added.layers.len(), 3);
    assert!(added.layers[1].mask.is_none(), "a new layer has no mask");
    assert_eq!(added.layers[1].meta, None, "a new layer has no meta");
    assert_eq!(mask_bytes(&added, 2), mask);
    assert!(!added.layers[2].mask_enabled);
    assert_eq!(added.layers[2].meta.as_deref(), Some(META));

    // Pasting pixels as a new layer above the masked one: same story.
    let pasted = doc
        .adding_image_layer(1, solid(2, 2, GREEN), "Pasted")
        .expect("paste layer");
    assert_mask_invariant(&pasted, "adding_image_layer");
    assert!(
        pasted.layers[2].mask.is_none(),
        "pasted layers are unmasked"
    );
    assert_eq!(pasted.layers[2].meta, None);
    assert_eq!(
        mask_bytes(&pasted, 1),
        mask,
        "the masked layer is untouched"
    );

    // Reordering and removal move the whole layer, mask and meta included.
    let moved = doc.moving_layer(1, 0).expect("reorder");
    assert_mask_invariant(&moved, "moving_layer");
    assert_eq!(mask_bytes(&moved, 0), mask);
    assert!(!moved.layers[0].mask_enabled);
    assert_eq!(moved.layers[0].meta.as_deref(), Some(META));

    let removed = doc.removing_layer(0).expect("remove the background");
    assert_mask_invariant(&removed, "removing_layer");
    assert_eq!(removed.layers.len(), 1);
    assert_eq!(mask_bytes(&removed, 0), mask);
    assert_eq!(removed.layers[0].meta.as_deref(), Some(META));
}

#[test]
fn merge_down_with_a_hidden_upper_keeps_the_lower_mask() {
    // An invisible upper layer contributes nothing, so the lower layer is not
    // rewritten and keeps its mask, its enabled flag and its meta.
    let doc = checkerboard_masked((4, 2), (4, 2), (0, 0));
    let doc = doc
        .adding_image_layer(1, solid(4, 2, GREEN), "Hidden")
        .unwrap();
    let doc = doc.with_layer_visible(2, false).unwrap();

    let merged = doc.merging_down(2).expect("merge a hidden upper");
    assert_mask_invariant(&merged, "merging_down with a hidden upper");
    assert_eq!(merged.layers.len(), 2);
    assert_eq!(mask_bytes(&merged, 1), mask_bytes(&doc, 1));
    assert!(merged.layers[1].mask_enabled);
    assert_eq!(merged.layers[1].meta.as_deref(), Some(META));
    assert_eq!(
        merged.flattened().into_raw(),
        doc.flattened().into_raw(),
        "dropping an invisible layer cannot change the projection"
    );
}

// -------------------------------------------------------- layer masks (FFI) --
//
// The same operations through the C entry points: handle lifetimes, the
// mask-kind mapping, buffer validation and the two queries.

#[test]
fn ffi_adding_layer_mask_kinds_queries_and_projection() {
    let dir = TempDir::new().unwrap();
    let doc = ffi_mask_fixture(&dir, "kinds", (4, 2), (4, 2), (0, 0));
    let unmasked_flat = flat_pixels(doc);
    assert_eq!(ffi_mask_flags(doc, 1), (false, false), "no mask to start");
    assert!(
        unsafe { rz_doc_layer_mask_image(doc, 1) }.is_null(),
        "no mask, no mask image"
    );

    // Reveal-all: present and enabled, projection unchanged.
    let reveal = unsafe { rz_doc_adding_layer_mask(doc, 1, MASK_REVEAL_ALL, ptr::null(), 0, 0) };
    assert!(!reveal.is_null());
    assert_eq!(ffi_mask_flags(reveal, 1), (true, true));
    assert_eq!(ffi_mask_bytes(reveal, 1), vec![255u8; 8]);
    assert_eq!(
        flat_pixels(reveal),
        unmasked_flat,
        "a reveal-all mask changes nothing"
    );
    assert_eq!(
        ffi_mask_flags(doc, 1),
        (false, false),
        "the operation is pure: the input document is untouched"
    );

    // Hide-all: the backdrop shows everywhere.
    let hide = unsafe { rz_doc_adding_layer_mask(doc, 1, MASK_HIDE_ALL, ptr::null(), 0, 0) };
    assert!(!hide.is_null());
    assert_eq!(ffi_mask_bytes(hide, 1), vec![0u8; 8]);
    let flat = flat_pixels(hide);
    for x in 0..4 {
        assert_eq!(pixel(&flat, 4, x, 0), RED, "hide-all shows the backdrop");
    }

    // From-selection: columns 0/0/128/255 gate the layer's coverage.
    let sel = selection(4, 2, |x, _| match x {
        2 => 128,
        3 => 255,
        _ => 0,
    });
    let from_sel =
        unsafe { rz_doc_adding_layer_mask(doc, 1, MASK_FROM_SELECTION, sel.as_ptr(), 4, 2) };
    assert!(!from_sel.is_null());
    assert_eq!(
        ffi_mask_bytes(from_sel, 1),
        sel,
        "a canvas-sized layer copies the selection 1:1"
    );
    assert_eq!(ffi_mask_flags(from_sel, 1), (true, true));
    let flat = flat_pixels(from_sel);
    for y in 0..2 {
        assert_eq!(pixel(&flat, 4, 0, y), RED, "hidden column");
        assert_eq!(
            pixel(&flat, 4, 2, y),
            over_opaque(RED, BLUE, 128.0 / 255.0),
            "an intermediate coverage value is partial coverage"
        );
        assert_eq!(pixel(&flat, 4, 3, y), BLUE, "revealed column");
    }

    // Adding a mask replaces any earlier one.
    let replaced = apply(unsafe { rz_doc_clone(from_sel) }, |d| unsafe {
        rz_doc_adding_layer_mask(d, 1, MASK_REVEAL_ALL, ptr::null(), 0, 0)
    });
    assert_eq!(ffi_mask_bytes(replaced, 1), vec![255u8; 8]);

    for d in [reveal, hide, from_sel, replaced, doc] {
        unsafe { rz_doc_free(d) };
    }
}

#[test]
fn ffi_adding_layer_mask_from_selection_crops_to_the_layer() {
    let dir = TempDir::new().unwrap();
    // 5x3 canvas; a 4x2 layer at (-1, 1) hangs off the left edge.
    let doc = ffi_mask_fixture(&dir, "crop", (5, 3), (4, 2), (-1, 1));
    // Distinctive per-canvas-pixel values so a mis-mapping cannot pass.
    let sel = selection(5, 3, |x, y| (x * 10 + y + 1) as u8);
    let masked =
        unsafe { rz_doc_adding_layer_mask(doc, 1, MASK_FROM_SELECTION, sel.as_ptr(), 5, 3) };
    assert!(!masked.is_null());
    let mask = ffi_mask_bytes(masked, 1);
    assert_eq!(mask.len(), 4 * 2, "the mask is exactly the layer's size");
    for ly in 0..2u32 {
        for lx in 0..4u32 {
            let cx = lx as i64 - 1;
            let cy = ly as i64 + 1;
            let expected = if cx < 0 {
                0
            } else {
                sel[cy as usize * 5 + cx as usize]
            };
            assert_eq!(
                mask[(ly * 4 + lx) as usize],
                expected,
                "layer pixel ({lx},{ly}) -> canvas ({cx},{cy})"
            );
        }
    }
    assert_eq!(mask[0], 0, "the off-canvas column is hidden");
    assert_eq!(mask[1], sel[5], "layer (1,0) -> canvas (0,1)");

    unsafe { rz_doc_free(masked) };
    unsafe { rz_doc_free(doc) };
}

#[test]
fn ffi_removing_layer_mask_applies_or_discards() {
    let dir = TempDir::new().unwrap();
    let doc = ffi_mask_fixture(&dir, "remove", (4, 2), (4, 2), (0, 0));
    let unmasked_flat = flat_pixels(doc);
    let unmasked_pixels = layer_pixels(doc, 1);
    let sel = selection(4, 2, |x, _| (x * 85) as u8);
    let masked =
        unsafe { rz_doc_adding_layer_mask(doc, 1, MASK_FROM_SELECTION, sel.as_ptr(), 4, 2) };
    assert!(!masked.is_null());
    let masked_flat = flat_pixels(masked);

    // apply: the coverage is baked into the layer's alpha and the projection
    // is byte-identical to the masked one.
    let applied = unsafe { rz_doc_removing_layer_mask(masked, 1, true) };
    assert!(!applied.is_null());
    assert_eq!(ffi_mask_flags(applied, 1), (false, false));
    assert!(unsafe { rz_doc_layer_mask_image(applied, 1) }.is_null());
    let baked = layer_pixels(applied, 1);
    for (i, &cov) in sel.iter().enumerate() {
        assert_eq!(baked[i * 4 + 3], cov, "alpha {i} baked from coverage");
    }
    assert_eq!(
        flat_pixels(applied),
        masked_flat,
        "applying a mask must not change the projection"
    );

    // A disabled mask composites like none at all, but apply still bakes it.
    let disabled = unsafe { rz_doc_with_layer_mask_enabled(masked, 1, false) };
    assert!(!disabled.is_null());
    assert_eq!(
        ffi_mask_flags(disabled, 1),
        (true, false),
        "the mask is retained, merely ignored"
    );
    assert_eq!(flat_pixels(disabled), unmasked_flat);
    let applied_disabled = unsafe { rz_doc_removing_layer_mask(disabled, 1, true) };
    assert!(!applied_disabled.is_null());
    assert_eq!(
        layer_pixels(applied_disabled, 1),
        baked,
        "apply bakes regardless of the enabled flag"
    );

    // No apply: pixels untouched, the layer is revealed in full again.
    let dropped = unsafe { rz_doc_removing_layer_mask(masked, 1, false) };
    assert!(!dropped.is_null());
    assert_eq!(ffi_mask_flags(dropped, 1), (false, false));
    assert_eq!(layer_pixels(dropped, 1), unmasked_pixels);
    assert_eq!(flat_pixels(dropped), unmasked_flat);

    // Re-enabling restores the masked projection.
    let reenabled = unsafe { rz_doc_with_layer_mask_enabled(disabled, 1, true) };
    assert!(!reenabled.is_null());
    assert_eq!(ffi_mask_flags(reenabled, 1), (true, true));
    assert_eq!(flat_pixels(reenabled), masked_flat);

    // Nothing to remove or toggle on a layer without a mask.
    unsafe {
        assert!(rz_doc_removing_layer_mask(dropped, 1, true).is_null());
        assert!(rz_doc_removing_layer_mask(dropped, 1, false).is_null());
        assert!(rz_doc_with_layer_mask_enabled(dropped, 1, false).is_null());
    }

    for d in [
        masked,
        applied,
        disabled,
        applied_disabled,
        dropped,
        reenabled,
        doc,
    ] {
        unsafe { rz_doc_free(d) };
    }
}

#[test]
fn ffi_painting_layer_mask_reveals_the_stroke() {
    let dir = TempDir::new().unwrap();
    // 5x2 canvas, 4x2 layer at (1, 0), starting fully hidden.
    let doc = ffi_mask_fixture(&dir, "paint", (5, 2), (4, 2), (1, 0));
    let hidden = unsafe { rz_doc_adding_layer_mask(doc, 1, MASK_HIDE_ALL, ptr::null(), 0, 0) };
    assert!(!hidden.is_null());

    // Canvas-frame PREMULTIPLIED overlay: opaque white at canvas (2, 0),
    // half-alpha white at (3, 1), transparent everywhere else.
    let mut overlay = vec![0u8; 5 * 2 * 4];
    let put = |buf: &mut Vec<u8>, x: usize, y: usize, px: [u8; 4]| {
        let i = (y * 5 + x) * 4;
        buf[i..i + 4].copy_from_slice(&px);
    };
    put(&mut overlay, 2, 0, [255, 255, 255, 255]);
    put(&mut overlay, 3, 1, [128, 128, 128, 128]);

    let painted = unsafe { rz_doc_painting_layer_mask(hidden, 1, overlay.as_ptr(), 5, 2) };
    assert!(!painted.is_null());
    assert_eq!(
        ffi_mask_bytes(painted, 1),
        // canvas (2,0) -> layer (1,0); canvas (3,1) -> layer (2,1).
        vec![0, 255, 0, 0, 0, 0, 128, 0],
        "white reveals in full, half alpha lands mid-way"
    );
    let flat = flat_pixels(painted);
    assert_eq!(pixel(&flat, 5, 2, 0), BLUE, "the painted pixel is revealed");
    assert_eq!(pixel(&flat, 5, 1, 0), RED, "the rest stays hidden");
    assert_eq!(
        pixel(&flat, 5, 3, 1),
        over_opaque(RED, BLUE, 128.0 / 255.0),
        "half alpha is half coverage"
    );
    assert_eq!(
        layer_pixels(painted, 1),
        layer_pixels(hidden, 1),
        "painting a mask never touches the layer's pixels"
    );

    // A wrongly sized overlay is REJECTED against the canvas, not read.
    unsafe {
        assert!(rz_doc_painting_layer_mask(hidden, 1, overlay.as_ptr(), 4, 2).is_null());
        assert!(rz_doc_painting_layer_mask(hidden, 1, overlay.as_ptr(), 5, 1).is_null());
        assert!(rz_doc_painting_layer_mask(hidden, 1, overlay.as_ptr(), 5, 3).is_null());
        assert!(rz_doc_painting_layer_mask(hidden, 1, overlay.as_ptr(), 0, 0).is_null());
        assert!(rz_doc_painting_layer_mask(hidden, 1, ptr::null(), 5, 2).is_null());
        assert!(
            rz_doc_painting_layer_mask(doc, 1, overlay.as_ptr(), 5, 2).is_null(),
            "no mask, nothing to paint"
        );
    }

    // A layer whose extent misses the canvas has no mask pixel to change.
    let away = apply(unsafe { rz_doc_clone(hidden) }, |d| unsafe {
        rz_doc_with_layer_offset(d, 1, 50, 50)
    });
    assert!(unsafe { rz_doc_painting_layer_mask(away, 1, overlay.as_ptr(), 5, 2) }.is_null());

    for d in [hidden, painted, away, doc] {
        unsafe { rz_doc_free(d) };
    }
}

#[test]
fn ffi_layer_image_and_thumbnail_ignore_the_mask() {
    let dir = TempDir::new().unwrap();
    let doc = ffi_mask_fixture(&dir, "unmasked", (4, 2), (4, 2), (0, 0));
    let hidden = unsafe { rz_doc_adding_layer_mask(doc, 1, MASK_HIDE_ALL, ptr::null(), 0, 0) };
    assert!(!hidden.is_null());

    // Photoshop/GIMP behavior: the layer thumbnail shows CONTENT and the mask
    // has its own thumbnail beside it, so neither getter applies the mask.
    assert_eq!(
        layer_pixels(hidden, 1),
        layer_pixels(doc, 1),
        "rz_doc_layer_image stays unmasked"
    );
    let masked_thumb = unsafe { rz_doc_layer_thumbnail(hidden, 1, 4) };
    let plain_thumb = unsafe { rz_doc_layer_thumbnail(doc, 1, 4) };
    assert!(!masked_thumb.is_null() && !plain_thumb.is_null());
    assert_eq!(
        img_pixels(masked_thumb),
        img_pixels(plain_thumb),
        "rz_doc_layer_thumbnail stays unmasked"
    );

    // Only the projection applies it — so the equalities above are not vacuous.
    let flat = flat_pixels(hidden);
    for x in 0..4 {
        for y in 0..2 {
            assert_eq!(
                pixel(&flat, 4, x, y),
                RED,
                "the projection applies the mask"
            );
        }
    }

    unsafe { rz_image_free(masked_thumb) };
    unsafe { rz_image_free(plain_thumb) };
    unsafe { rz_doc_free(hidden) };
    unsafe { rz_doc_free(doc) };
}

#[test]
fn ffi_layer_mask_null_and_range_guards() {
    let null_doc: *const RzDocument = ptr::null();
    let buffer = [0u8; 16]; // a 2x2 canvas' worth of either buffer
    unsafe {
        assert!(
            rz_doc_adding_layer_mask(null_doc, 0, MASK_REVEAL_ALL, ptr::null(), 0, 0).is_null()
        );
        assert!(
            rz_doc_adding_layer_mask(null_doc, 0, MASK_FROM_SELECTION, buffer.as_ptr(), 2, 2)
                .is_null()
        );
        assert!(rz_doc_removing_layer_mask(null_doc, 0, true).is_null());
        assert!(rz_doc_with_layer_mask_enabled(null_doc, 0, true).is_null());
        assert!(rz_doc_painting_layer_mask(null_doc, 0, buffer.as_ptr(), 2, 2).is_null());
        assert!(rz_doc_layer_mask_image(null_doc, 0).is_null());
        assert!(!rz_doc_layer_has_mask(null_doc, 0));
        assert!(!rz_doc_layer_mask_enabled(null_doc, 0));
    }

    let dir = TempDir::new().unwrap();
    let doc = ffi_mask_fixture(&dir, "guards", (2, 2), (2, 2), (0, 0));
    let sel = selection(2, 2, |_, _| 255);
    let hidden = unsafe {
        // Out-of-range indices.
        assert!(rz_doc_adding_layer_mask(doc, 9, MASK_REVEAL_ALL, ptr::null(), 0, 0).is_null());
        assert!(
            rz_doc_adding_layer_mask(doc, 9, MASK_FROM_SELECTION, sel.as_ptr(), 2, 2).is_null()
        );
        assert!(rz_doc_removing_layer_mask(doc, 9, true).is_null());
        assert!(rz_doc_with_layer_mask_enabled(doc, 9, true).is_null());
        assert!(rz_doc_painting_layer_mask(doc, 9, buffer.as_ptr(), 2, 2).is_null());
        assert!(rz_doc_layer_mask_image(doc, 9).is_null());
        assert!(!rz_doc_layer_has_mask(doc, 9));
        assert!(!rz_doc_layer_mask_enabled(doc, 9));

        // Unknown kinds, and a selection buffer that is not canvas-sized:
        // rejected against the canvas rather than read at the caller's word.
        assert!(rz_doc_adding_layer_mask(doc, 1, 3, ptr::null(), 0, 0).is_null());
        assert!(rz_doc_adding_layer_mask(doc, 1, -1, ptr::null(), 0, 0).is_null());
        assert!(
            rz_doc_adding_layer_mask(doc, 1, MASK_FROM_SELECTION, sel.as_ptr(), 1, 2).is_null()
        );
        assert!(
            rz_doc_adding_layer_mask(doc, 1, MASK_FROM_SELECTION, sel.as_ptr(), 2, 3).is_null()
        );
        assert!(
            rz_doc_adding_layer_mask(doc, 1, MASK_FROM_SELECTION, sel.as_ptr(), 0, 0).is_null()
        );
        assert!(rz_doc_adding_layer_mask(doc, 1, MASK_FROM_SELECTION, ptr::null(), 2, 2).is_null());

        // The kinds that never read the buffer accept a NULL one.
        rz_doc_adding_layer_mask(doc, 1, MASK_HIDE_ALL, ptr::null(), 0, 0)
    };
    assert!(!hidden.is_null());
    assert_eq!(ffi_mask_flags(hidden, 1), (true, true));

    unsafe { rz_doc_free(hidden) };
    unsafe { rz_doc_free(doc) };
}

// ---------------------------------------------------- layer metadata (FFI) --
//
// `meta` is an opaque host blob: the core stores, copies and serializes it but
// never looks inside. These drive the two entry points that surface it, plus
// the raw-buffer pixel replacement a re-render chains with them.

/// A 4x3 red background under a 2x2 blue "Top" layer (index 1).
fn meta_fixture(dir: &TempDir, tag: &str) -> *mut RzDocument {
    let doc = doc_from(dir, &format!("{tag}-bg.png"), &solid(4, 3, RED));
    add_layer(
        dir,
        &format!("{tag}-top.png"),
        doc,
        0,
        &solid(2, 2, BLUE),
        "Top",
    )
}

#[test]
fn ffi_layer_meta_round_trips_sets_and_clears() {
    let dir = TempDir::new().unwrap();
    let doc = meta_fixture(&dir, "roundtrip");
    assert_eq!(ffi_meta(doc, 0), None, "a fresh layer has no metadata");
    assert_eq!(ffi_meta(doc, 1), None);

    let c = CString::new(TEXT_META).unwrap();
    let tagged = unsafe { rz_doc_with_layer_meta(doc, 1, c.as_ptr()) };
    assert!(!tagged.is_null());
    assert_eq!(
        ffi_meta(tagged, 1).as_deref(),
        Some(TEXT_META),
        "the blob comes back verbatim, non-ASCII and all"
    );
    assert_eq!(ffi_meta(tagged, 0), None, "only the named layer is touched");
    assert_eq!(ffi_meta(doc, 1), None, "the setter is pure");

    // Setting again replaces; NULL clears.
    const SECOND: &str = "{\"type\":\"text\",\"string\":\"second\"}";
    let replaced = set_meta(tagged, 1, SECOND);
    assert_eq!(ffi_meta(replaced, 1).as_deref(), Some(SECOND));
    let cleared = unsafe { rz_doc_with_layer_meta(replaced, 1, ptr::null()) };
    assert!(!cleared.is_null(), "NULL clears rather than failing");
    assert_eq!(ffi_meta(cleared, 1), None);
    assert!(ffi_meta(replaced, 1).is_some(), "clearing is pure too");

    // Getting past the end of the stack is NULL, like every other getter.
    assert_eq!(ffi_meta(cleared, 2), None);
    assert_eq!(ffi_meta(cleared, usize::MAX), None);

    unsafe { rz_doc_free(cleared) };
    unsafe { rz_doc_free(replaced) };
    unsafe { rz_doc_free(doc) };
}

#[test]
fn ffi_layer_meta_rejects_invalid_utf8_and_over_long_payloads() {
    // The cap the RZDC writer enforces: accepting more here would let a
    // document hold metadata that rz_doc_save_native would then refuse.
    const META_CAP: usize = 16 * 1024 * 1024;

    let dir = TempDir::new().unwrap();
    let doc = meta_fixture(&dir, "reject");

    // A lone 0xFF is not valid UTF-8: refused outright, never lossily
    // converted into replacement characters behind the host's back.
    let invalid = CString::new(vec![0x7bu8, 0xff, 0xfe, 0x7d]).unwrap();
    assert!(unsafe { rz_doc_with_layer_meta(doc, 1, invalid.as_ptr()) }.is_null());

    let at_cap = CString::new("a".repeat(META_CAP)).unwrap();
    let big = unsafe { rz_doc_with_layer_meta(doc, 1, at_cap.as_ptr()) };
    assert!(!big.is_null(), "a payload exactly at the cap is accepted");
    assert_eq!(ffi_meta(big, 1).map(|s| s.len()), Some(META_CAP));
    unsafe { rz_doc_free(big) };

    let over_cap = CString::new("a".repeat(META_CAP + 1)).unwrap();
    assert!(unsafe { rz_doc_with_layer_meta(doc, 1, over_cap.as_ptr()) }.is_null());
    assert_eq!(ffi_meta(doc, 1), None, "a refused set changes nothing");

    unsafe { rz_doc_free(doc) };
}

#[test]
fn ffi_layer_meta_survives_a_native_save_and_reopen() {
    let dir = TempDir::new().unwrap();
    let doc = meta_fixture(&dir, "save");
    let doc = set_meta(doc, 1, TEXT_META);

    let path = dir.path().join("meta.rzdc");
    let c = cpath(&path);
    let mut err: *mut c_char = ptr::null_mut();
    assert!(
        unsafe { rz_doc_save_native(doc, c.as_ptr(), &mut err) },
        "save failed: {}",
        take_err_string(err)
    );

    let mut err: *mut c_char = ptr::null_mut();
    let back = unsafe { rz_doc_open(c.as_ptr(), &mut err) };
    assert!(!back.is_null(), "reopen failed: {}", take_err_string(err));
    assert_eq!(unsafe { rz_doc_layer_count(back) }, 2);
    assert_eq!(
        ffi_meta(back, 1).as_deref(),
        Some(TEXT_META),
        "metadata round-trips through the version-2 format"
    );
    assert_eq!(ffi_meta(back, 0), None, "a layer without stays without");

    unsafe { rz_doc_free(back) };
    unsafe { rz_doc_free(doc) };
}

#[test]
fn ffi_re_render_replaces_content_and_keeps_metadata() {
    let dir = TempDir::new().unwrap();
    let doc = meta_fixture(&dir, "rerender");
    let doc = set_meta(doc, 1, TEXT_META);
    assert_eq!(layer_dims(doc, 1), (2, 2));

    // The chain a text re-render uses: new pixels, then a new offset. Both
    // are pure, so the host commits only the final handle — one undo step.
    let green = solid(2, 2, GREEN).into_raw();
    let repainted = unsafe { rz_doc_with_layer_pixels_rgba(doc, 1, green.as_ptr(), 2, 2) };
    assert!(!repainted.is_null());
    let moved = apply(repainted, |d| unsafe {
        rz_doc_with_layer_offset(d, 1, 2, 1)
    });
    assert_eq!(layer_dims(moved, 1), (2, 2));
    assert_eq!(layer_pixels(moved, 1), green, "the buffer landed verbatim");
    assert_eq!(layer_offset(moved, 1), (2, 1));
    assert_eq!(
        ffi_meta(moved, 1).as_deref(),
        Some(TEXT_META),
        "metadata survives a pixel replacement and an offset change"
    );
    assert_eq!(
        layer_pixels(doc, 1),
        solid(2, 2, BLUE).into_raw(),
        "the input document is untouched"
    );
    assert_eq!(layer_offset(doc, 1), (0, 0));

    // The re-rendered content shows at its new position in the projection.
    let flat = flat_pixels(moved);
    assert_eq!(pixel(&flat, 4, 2, 1), GREEN);
    assert_eq!(pixel(&flat, 4, 3, 2), GREEN);
    assert_eq!(pixel(&flat, 4, 0, 0), RED);
    assert_eq!(pixel(&flat, 4, 1, 1), RED, "the old position is exposed");

    // A re-render at a different size resizes the layer and keeps the blob.
    let wide = solid(3, 1, WHITE).into_raw();
    let resized = apply(moved, |d| unsafe {
        rz_doc_with_layer_pixels_rgba(d, 1, wide.as_ptr(), 3, 1)
    });
    assert_eq!(layer_dims(resized, 1), (3, 1));
    assert_eq!(layer_pixels(resized, 1), wide);
    assert_eq!(ffi_meta(resized, 1).as_deref(), Some(TEXT_META));

    unsafe { rz_doc_free(resized) };
    unsafe { rz_doc_free(doc) };
}

#[test]
fn ffi_with_layer_pixels_rgba_keeps_a_mask_only_at_the_same_size() {
    let dir = TempDir::new().unwrap();
    let doc = ffi_mask_fixture(&dir, "rgba-mask", (4, 2), (4, 2), (0, 0));
    let sel = selection(4, 2, |x, _| if x < 2 { 255 } else { 0 });
    let masked = apply(doc, |d| unsafe {
        rz_doc_adding_layer_mask(d, 1, MASK_FROM_SELECTION, sel.as_ptr(), 4, 2)
    });
    assert_eq!(ffi_mask_flags(masked, 1), (true, true));

    let same = solid(4, 2, GREEN).into_raw();
    let kept = unsafe { rz_doc_with_layer_pixels_rgba(masked, 1, same.as_ptr(), 4, 2) };
    assert!(!kept.is_null());
    assert_eq!(
        ffi_mask_flags(kept, 1),
        (true, true),
        "a same-size re-render keeps the mask"
    );
    assert_eq!(ffi_mask_bytes(kept, 1), ffi_mask_bytes(masked, 1));

    let smaller = solid(2, 2, GREEN).into_raw();
    let dropped = unsafe { rz_doc_with_layer_pixels_rgba(masked, 1, smaller.as_ptr(), 2, 2) };
    assert!(!dropped.is_null());
    assert_eq!(layer_dims(dropped, 1), (2, 2));
    assert_eq!(
        ffi_mask_flags(dropped, 1),
        (false, false),
        "a differently sized re-render drops it (the mask is layer-sized)"
    );

    unsafe { rz_doc_free(dropped) };
    unsafe { rz_doc_free(kept) };
    unsafe { rz_doc_free(masked) };
}

#[test]
fn ffi_layer_meta_and_pixels_rgba_null_and_range_guards() {
    let null_doc: *const RzDocument = ptr::null();
    let meta = CString::new("{}").unwrap();
    let px = [0u8; 16]; // a 2x2 RGBA8 buffer

    unsafe {
        assert!(rz_doc_layer_meta(null_doc, 0).is_null());
        assert!(rz_doc_with_layer_meta(null_doc, 0, meta.as_ptr()).is_null());
        assert!(rz_doc_with_layer_meta(null_doc, 0, ptr::null()).is_null());
        assert!(rz_doc_with_layer_pixels_rgba(null_doc, 0, px.as_ptr(), 2, 2).is_null());
    }

    let dir = TempDir::new().unwrap();
    let doc = meta_fixture(&dir, "guards");
    unsafe {
        // Out-of-range indices on every entry point.
        assert!(rz_doc_layer_meta(doc, 2).is_null());
        assert!(rz_doc_with_layer_meta(doc, 2, meta.as_ptr()).is_null());
        assert!(rz_doc_with_layer_meta(doc, 2, ptr::null()).is_null());
        assert!(rz_doc_with_layer_pixels_rgba(doc, 2, px.as_ptr(), 2, 2).is_null());

        // A NULL buffer, a zero dimension, or dimensions past the pixel
        // ceiling are refused before any slice is built from them.
        assert!(rz_doc_with_layer_pixels_rgba(doc, 1, ptr::null(), 2, 2).is_null());
        assert!(rz_doc_with_layer_pixels_rgba(doc, 1, px.as_ptr(), 0, 2).is_null());
        assert!(rz_doc_with_layer_pixels_rgba(doc, 1, px.as_ptr(), 2, 0).is_null());
        assert!(rz_doc_with_layer_pixels_rgba(doc, 1, px.as_ptr(), 100_001, 1_000).is_null());
        assert!(rz_doc_with_layer_pixels_rgba(doc, 1, px.as_ptr(), u32::MAX, u32::MAX).is_null());
        assert_eq!(ffi_meta(doc, 1), None, "no refused call changed anything");
        assert_eq!(layer_dims(doc, 1), (2, 2));
    }
    unsafe { rz_doc_free(doc) };
}

// ------------------------------------------------------------ clipping masks --
//
// A layer flagged CLIPPED is confined to the alpha footprint of the first
// unclipped layer beneath it — its BASE — and the base plus its consecutive
// run of clipped layers blend as one group, which then reaches the backdrop
// through the base's blend mode and opacity. Group structure is positional
// and re-derived at every composite; a clipped layer at the bottom of the
// stack has no base and composites as if unclipped.

#[test]
fn clipped_flag_ffi_default_purity_and_duplicate() {
    let dir = TempDir::new().unwrap();
    let doc = doc_from(&dir, "cf-bg.png", &solid(3, 3, RED));
    let doc = add_layer(&dir, "cf-top.png", doc, 0, &solid(2, 2, BLUE), "Top");
    unsafe {
        assert!(!rz_doc_layer_clipped(doc, 0), "default is unclipped");
        assert!(!rz_doc_layer_clipped(doc, 1), "default is unclipped");

        let flagged = rz_doc_with_layer_clipped(doc, 1, true);
        assert!(!flagged.is_null());
        assert!(rz_doc_layer_clipped(flagged, 1));
        assert!(!rz_doc_layer_clipped(doc, 1), "the setter is pure");

        // Duplicating copies the flag like every other property.
        let dup = rz_doc_duplicating_layer(flagged, 1);
        assert!(!dup.is_null());
        assert!(rz_doc_layer_clipped(dup, 2), "duplicate keeps the flag");

        let cleared = rz_doc_with_layer_clipped(flagged, 1, false);
        assert!(!cleared.is_null());
        assert!(!rz_doc_layer_clipped(cleared, 1));

        // NULL and out-of-range guards.
        let null_doc: *const RzDocument = ptr::null();
        assert!(!rz_doc_layer_clipped(null_doc, 0));
        assert!(rz_doc_with_layer_clipped(null_doc, 0, true).is_null());
        assert!(!rz_doc_layer_clipped(doc, 9));
        assert!(rz_doc_with_layer_clipped(doc, 9, true).is_null());

        rz_doc_free(cleared);
        rz_doc_free(dup);
        rz_doc_free(flagged);
        rz_doc_free(doc);
    }
}

/// A layered fixture exercising opacity, blend mode, offset, a mask and an
/// adjustment layer — everything the plain (unclipped) walk composites.
fn clip_regression_doc() -> RzDocument {
    let doc = RzDocument::from_pixels(opaque_pattern(6, 4));
    let doc = doc
        .adding_image_layer(0, solid(4, 3, [30, 200, 120, 180]), "Mid")
        .unwrap()
        .with_layer_offset(1, 1, 1)
        .unwrap()
        .with_layer_opacity(1, 0.7)
        .unwrap()
        .with_layer_blend_mode(1, BlendMode::Multiply)
        .unwrap();
    let sel = selection(6, 4, |x, y| if (x + y) % 2 == 0 { 255 } else { 90 });
    let doc = doc.add_mask(1, MaskKind::FromSelection(&sel)).unwrap();
    let mut doc = doc
        .adding_image_layer(1, solid(1, 1, MAGENTA), "Adjust")
        .unwrap()
        .with_layer_opacity(2, 0.5)
        .unwrap();
    doc.layers[2].meta = Some(adjust_meta("invert", "{}"));
    doc
}

#[test]
fn unflagged_documents_composite_byte_identically() {
    // The reference: a document that never saw a clipped flag.
    let reference = clip_regression_doc().flattened().into_raw();

    // The same document with flags set and cleared again must not differ by
    // a single byte: with every group empty, the group machinery never
    // engages and the plain walk composites exactly as before.
    let mut toggled = clip_regression_doc();
    for idx in 0..toggled.layers.len() {
        toggled = toggled.with_layer_clipped(idx, true).unwrap();
    }
    for idx in 0..toggled.layers.len() {
        toggled = toggled.with_layer_clipped(idx, false).unwrap();
    }
    assert!(toggled.layers.iter().all(|l| !l.clipped));
    assert_eq!(
        toggled.flattened().into_raw(),
        reference,
        "an unflagged stack must composite exactly as before clipping existed"
    );
}

#[test]
fn clipped_layer_confined_to_base_footprint() {
    // Opaque red canvas; base (idx 1): 3x2 at (1, 0) with columns at alpha
    // 255 / 128 / 0; canvas-wide clipped green (idx 2) above it.
    let base = RgbaImage::from_fn(3, 2, |x, _| Rgba([0, 0, 255, [255u8, 128, 0][x as usize]]));
    let doc = RzDocument::from_pixels(solid(6, 2, RED));
    let doc = doc
        .adding_image_layer(0, base, "Base")
        .unwrap()
        .with_layer_offset(1, 1, 0)
        .unwrap()
        .adding_image_layer(1, solid(6, 2, GREEN), "Clip")
        .unwrap()
        .with_layer_clipped(2, true)
        .unwrap();

    for y in 0..2 {
        assert_eq!(flat(&doc, 0, y), RED, "left of the base: backdrop only");
        assert_eq!(flat(&doc, 1, y), GREEN, "opaque base: the clip in full");
        assert_eq!(
            flat(&doc, 2, y),
            over_opaque(RED, GREEN, 128.0 / 255.0),
            "semi-transparent base edge scales the clipped contribution"
        );
        for x in 3..6 {
            assert_eq!(
                flat(&doc, x, y),
                RED,
                "({x},{y}): base alpha 0 confines the clip"
            );
        }
    }

    // Flatten walks the same grouped path: one layer, same projection.
    let flattened = doc.flattening();
    assert_eq!(flattened.layers.len(), 1);
    assert_eq!(
        flattened.flattened().into_raw(),
        doc.flattened().into_raw(),
        "rz_doc_flattening needs no clipping code of its own"
    );
}

#[test]
fn group_alpha_equals_base_alpha_even_under_an_opaque_clip() {
    // No backdrop: the base's own alpha pattern IS the projection's alpha,
    // even though the clipped layer above it is opaque everywhere.
    let base = RgbaImage::from_fn(3, 2, |x, _| {
        Rgba([255, 255, 0, [0u8, 128, 255][x as usize]])
    });
    let doc = RzDocument::from_pixels(base);
    let doc = doc
        .adding_image_layer(0, solid(3, 2, GREEN), "Clip")
        .unwrap()
        .with_layer_clipped(1, true)
        .unwrap();
    let flat_img = doc.flattened();
    for y in 0..2 {
        assert_eq!(
            flat_img.get_pixel(0, y).0,
            [0, 0, 0, 0],
            "a transparent base pixel stays fully transparent"
        );
        assert_eq!(
            flat_img.get_pixel(1, y).0,
            [GREEN[0], GREEN[1], GREEN[2], 128],
            "alpha follows the base, color the clip"
        );
        assert_eq!(flat_img.get_pixel(2, y).0, GREEN, "opaque base pixel");
    }
}

#[test]
fn clipped_blend_mode_blends_against_the_base_content() {
    // Multiply blends against the BASE's color — the red backdrop below the
    // group must never enter the product.
    let base_px = [200u8, 100, 50, 255];
    let clip_px = [100u8, 150, 200, 255];
    let doc = RzDocument::from_pixels(solid(2, 2, RED));
    let doc = doc
        .adding_image_layer(0, solid(2, 2, base_px), "Base")
        .unwrap()
        .adding_image_layer(1, solid(2, 2, clip_px), "Clip")
        .unwrap()
        .with_layer_blend_mode(2, BlendMode::Multiply)
        .unwrap()
        .with_layer_clipped(2, true)
        .unwrap();
    let mut expected = [0u8; 4];
    for c in 0..3 {
        let v = f32::from(base_px[c]) / 255.0 * (f32::from(clip_px[c]) / 255.0);
        expected[c] = (v * 255.0).round() as u8;
    }
    expected[3] = 255;
    assert_eq!(
        flat(&doc, 0, 0),
        expected,
        "multiply of clip over base; red never enters"
    );
}

#[test]
fn group_composites_with_the_base_mode_and_opacity() {
    // The base is fully covered by an opaque Normal clip, so the GROUP's
    // content is the clip's color — but it must reach the backdrop through
    // the BASE's Multiply at 0.6.
    let clip_px = [220u8, 180, 40, 255];
    let backdrop = opaque_pattern(4, 3);
    let doc = RzDocument::from_pixels(backdrop.clone());
    let doc = doc
        .adding_image_layer(0, solid(4, 3, [50, 100, 150, 255]), "Base")
        .unwrap()
        .with_layer_blend_mode(1, BlendMode::Multiply)
        .unwrap()
        .with_layer_opacity(1, 0.6)
        .unwrap()
        .adding_image_layer(1, solid(4, 3, clip_px), "Clip")
        .unwrap()
        .with_layer_clipped(2, true)
        .unwrap();
    let flat_img = doc.flattened();
    for (x, y, px) in backdrop.enumerate_pixels() {
        let expected = ref_composite(to_unit(px.0), to_unit(clip_px), 0.6, BLEND_MULTIPLY);
        let got = flat_img.get_pixel(x, y).0;
        for c in 0..4 {
            let want = (expected[c].clamp(0.0, 1.0) * 255.0).round() as u8;
            assert!(
                (i32::from(got[c]) - i32::from(want)).abs() <= 1,
                "({x},{y}) channel {c}: {} vs {want}",
                got[c]
            );
        }
    }
}

#[test]
fn solo_clipped_layer_over_an_opaque_base_matches_unclipped() {
    // The pinned equivalence: one clipped layer whose base is fully opaque
    // everywhere the clipped layer has pixels must composite exactly like
    // the unclipped stack of the same two layers.
    let build = || {
        let doc = RzDocument::from_pixels(opaque_pattern(6, 4));
        doc.adding_image_layer(0, solid(3, 2, [30, 200, 120, 140]), "Top")
            .unwrap()
            .with_layer_offset(1, 2, 1)
            .unwrap()
            .with_layer_opacity(1, 0.7)
            .unwrap()
            .with_layer_blend_mode(1, BlendMode::Screen)
            .unwrap()
    };
    let unclipped = build().flattened().into_raw();
    let clipped = build()
        .with_layer_clipped(1, true)
        .unwrap()
        .flattened()
        .into_raw();
    assert_eq!(
        clipped, unclipped,
        "solo equivalence over an opaque base must be byte-identical"
    );
}

#[test]
fn clipped_adjustment_layer_reaches_only_the_base_footprint() {
    // Red backdrop, blue base over the left half, a clipped UNMASKED invert
    // adjustment above: unmasked adjustments normally reach the whole
    // canvas, but clipped one may only invert the base's footprint.
    let build = || {
        let doc = RzDocument::from_pixels(solid(6, 4, RED));
        let mut doc = doc
            .adding_image_layer(0, solid(3, 4, BLUE), "Base")
            .unwrap()
            .adding_image_layer(1, solid(1, 1, MAGENTA), "Adjust")
            .unwrap();
        doc.layers[2].meta = Some(adjust_meta("invert", "{}"));
        doc
    };
    let doc = build().with_layer_clipped(2, true).unwrap();
    let yellow = [255, 255, 0, 255]; // invert(BLUE)
    for y in 0..4 {
        for x in 0..3 {
            assert_eq!(flat(&doc, x, y), yellow, "({x},{y}): base content inverted");
        }
        for x in 3..6 {
            assert_eq!(
                flat(&doc, x, y),
                RED,
                "({x},{y}): backdrop untouched outside the base"
            );
        }
    }
    // Sanity: unclipped, the same adjustment inverts the backdrop too.
    let unclipped = build();
    assert_eq!(
        flat(&unclipped, 4, 0),
        [0, 255, 255, 255],
        "unclipped, the adjustment reaches the red backdrop"
    );
}

#[test]
fn bottom_of_stack_clipped_layers_composite_as_unclipped() {
    // No unclipped layer below: the flag is ignored, even for a run of
    // clipped layers at the bottom of the stack.
    let build = || {
        let doc = RzDocument::from_pixels(solid(4, 3, [0, 0, 255, 128]));
        doc.adding_image_layer(0, solid(2, 2, GREEN), "Second")
            .unwrap()
            .with_layer_offset(1, 1, 1)
            .unwrap()
    };
    let reference = build().flattened().into_raw();
    let flagged = build()
        .with_layer_clipped(0, true)
        .unwrap()
        .with_layer_clipped(1, true)
        .unwrap()
        .flattened()
        .into_raw();
    assert_eq!(
        flagged, reference,
        "baseless clipped layers composite as if unclipped"
    );
}

#[test]
fn invisible_base_hides_its_clipped_layers() {
    let build = || {
        let doc = RzDocument::from_pixels(solid(4, 3, RED));
        doc.adding_image_layer(0, solid(4, 3, BLUE), "Base")
            .unwrap()
            .adding_image_layer(1, solid(4, 3, GREEN), "Clip")
            .unwrap()
            .with_layer_clipped(2, true)
            .unwrap()
    };
    // Sanity: with the base visible the clip shows.
    assert_eq!(flat(&build(), 0, 0), GREEN);
    // Hiding the BASE hides the whole group: not just the base's pixels but
    // its clipped layer too.
    let hidden = build().with_layer_visible(1, false).unwrap();
    let flat_img = hidden.flattened();
    for (_, _, px) in flat_img.enumerate_pixels() {
        assert_eq!(px.0, RED, "the clipped layer must vanish with its base");
    }
    // An invisible clipped layer is skipped without taking the group down.
    let clip_hidden = build().with_layer_visible(2, false).unwrap();
    assert_eq!(flat(&clip_hidden, 0, 0), BLUE, "the base still shows");
}

#[test]
fn merge_down_bakes_the_clipping_and_keeps_the_lower_flag() {
    // Red backdrop, opaque blue base 3x2 at (1, 1), canvas-wide clipped
    // green above it.
    let doc = RzDocument::from_pixels(solid(6, 4, RED));
    let doc = doc
        .adding_image_layer(0, solid(3, 2, BLUE), "Base")
        .unwrap()
        .with_layer_offset(1, 1, 1)
        .unwrap()
        .adding_image_layer(1, solid(6, 4, GREEN), "Clip")
        .unwrap()
        .with_layer_clipped(2, true)
        .unwrap();
    let before = doc.flattened().into_raw();
    let merged = doc.merging_down(2).expect("merge");
    assert_eq!(merged.layers.len(), 2);
    assert!(
        !merged.layers[1].clipped,
        "the merged layer keeps the LOWER layer's flag"
    );
    assert_eq!(
        merged.flattened().into_raw(),
        before,
        "the projection must not change when a clipped layer merges down"
    );
    // The bake is alpha-limited to the base's footprint: green exactly where
    // the base was, transparent everywhere else in the union extent.
    assert_eq!(merged.layers[1].offset, (0, 0), "union origin");
    assert_eq!(merged.layers[1].pixels.dimensions(), (6, 4), "union extent");
    for (x, y, px) in merged.layers[1].pixels.enumerate_pixels() {
        if (1..4).contains(&x) && (1..3).contains(&y) {
            assert_eq!(px.0, GREEN, "({x},{y}): clipped green baked over the base");
        } else {
            assert_eq!(px.0, [0, 0, 0, 0], "({x},{y}): outside the base footprint");
        }
    }

    // Merging INSIDE a group: the merged layer keeps the lower layer's
    // CLIPPED flag, so the shrunk group stays intact and the projection is
    // preserved.
    let doc = RzDocument::from_pixels(solid(6, 4, RED));
    let doc = doc
        .adding_image_layer(0, solid(3, 2, BLUE), "Base")
        .unwrap()
        .with_layer_offset(1, 1, 1)
        .unwrap()
        .adding_image_layer(1, solid(6, 4, GREEN), "ClipA")
        .unwrap()
        .with_layer_clipped(2, true)
        .unwrap()
        .adding_image_layer(2, solid(2, 2, [255, 255, 0, 255]), "ClipB")
        .unwrap()
        .with_layer_clipped(3, true)
        .unwrap();
    let before = doc.flattened().into_raw();
    let merged = doc.merging_down(3).expect("merge inside the group");
    assert_eq!(merged.layers.len(), 3);
    assert!(merged.layers[2].clipped, "the merged layer stays clipped");
    assert_eq!(
        merged.flattened().into_raw(),
        before,
        "merging inside a clip group preserves the projection"
    );
}

#[test]
fn rzdc_v3_round_trips_clipped_flags() {
    let dir = TempDir::new().unwrap();
    let doc = RzDocument::from_pixels(solid(4, 3, RED));
    let doc = doc
        .adding_image_layer(0, solid(2, 2, BLUE), "Base")
        .unwrap()
        .adding_image_layer(1, solid(4, 3, GREEN), "Clip")
        .unwrap()
        .with_layer_clipped(2, true)
        .unwrap();
    let path = dir.path().join("clipped.rzdc");
    let spath = path.to_str().unwrap().to_string();
    doc.save_native(&spath).expect("save");
    let bytes = std::fs::read(&path).unwrap();
    assert_eq!(&bytes[..4], b"RZDC");
    assert_eq!(
        u32::from_le_bytes(bytes[4..8].try_into().unwrap()),
        3,
        "the clipped flag bumped the format to version 3"
    );

    let back = RzDocument::open(&spath).expect("reopen");
    assert_eq!(back.layers.len(), 3);
    assert!(!back.layers[0].clipped);
    assert!(!back.layers[1].clipped);
    assert!(
        back.layers[2].clipped,
        "clipped flag survives the round trip"
    );
    assert_eq!(
        back.flattened().into_raw(),
        doc.flattened().into_raw(),
        "projection survives the round trip"
    );

    // Saving the reopened document reproduces the file byte for byte.
    let again = dir.path().join("again.rzdc");
    back.save_native(again.to_str().unwrap()).expect("resave");
    assert_eq!(std::fs::read(&again).unwrap(), bytes);
}

#[test]
fn rzdc_version_1_and_2_records_load_with_clipped_false() {
    let dir = TempDir::new().unwrap();
    let mut png = Vec::new();
    solid(2, 2, [1, 2, 3, 255])
        .write_to(&mut std::io::Cursor::new(&mut png), image::ImageFormat::Png)
        .unwrap();
    // A version-1 record stops after the pixel PNG; the version-2 fields
    // (mask, meta) and the version-3 field (clipped) are appended after it,
    // each older record a strict prefix of the next.
    let record_v1 = |version: u32| {
        let mut buf = Vec::new();
        buf.extend_from_slice(b"RZDC");
        buf.extend_from_slice(&version.to_le_bytes());
        buf.extend_from_slice(&2u32.to_le_bytes()); // width
        buf.extend_from_slice(&2u32.to_le_bytes()); // height
        buf.extend_from_slice(&1u32.to_le_bytes()); // layer count
        buf.extend_from_slice(&3u32.to_le_bytes()); // name len
        buf.extend_from_slice(b"Old");
        buf.extend_from_slice(&0i32.to_le_bytes()); // offset x
        buf.extend_from_slice(&0i32.to_le_bytes()); // offset y
        buf.extend_from_slice(&1.0f32.to_le_bytes()); // opacity
        buf.extend_from_slice(&0u32.to_le_bytes()); // blend
        buf.push(1); // visible
        buf.extend_from_slice(&(png.len() as u32).to_le_bytes());
        buf.extend_from_slice(&png);
        buf
    };

    let v1_path = dir.path().join("v1.rzdc");
    std::fs::write(&v1_path, record_v1(1)).unwrap();
    let v1 = RzDocument::open(v1_path.to_str().unwrap()).expect("v1 must load");
    assert!(!v1.layers[0].clipped, "v1 defaults to unclipped");

    // The same record with the version-2 fields appended (no mask, mask
    // enabled, no meta) — still no clipped byte.
    let mut v2 = record_v1(2);
    v2.push(0); // mask present
    v2.push(1); // mask enabled
    v2.push(0); // meta present
    let v2_path = dir.path().join("v2.rzdc");
    std::fs::write(&v2_path, &v2).unwrap();
    let v2 = RzDocument::open(v2_path.to_str().unwrap()).expect("v2 must load");
    assert!(!v2.layers[0].clipped, "v2 defaults to unclipped");

    // The same record with the clipped byte appended parses as version 3.
    let mut v3 = record_v1(3);
    v3.push(0); // mask present
    v3.push(1); // mask enabled
    v3.push(0); // meta present
    v3.push(1); // clipped
    let v3_path = dir.path().join("v3.rzdc");
    std::fs::write(&v3_path, &v3).unwrap();
    let v3 = RzDocument::open(v3_path.to_str().unwrap()).expect("v3 must load");
    assert!(
        v3.layers[0].clipped,
        "the appended v3 byte is the clipped flag"
    );

    // A version-3 record missing the clipped byte is truncated, not lenient.
    let mut short = record_v1(3);
    short.push(0);
    short.push(1);
    short.push(0);
    let short_path = dir.path().join("short.rzdc");
    std::fs::write(&short_path, &short).unwrap();
    assert!(
        RzDocument::open(short_path.to_str().unwrap()).is_err(),
        "a v3 record without the clipped byte must be refused"
    );
}
