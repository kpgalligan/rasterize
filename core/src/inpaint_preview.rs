//! Everything the `preview` flag needs and nothing else uses: how far to
//! reduce, the reductions themselves, the bilinear upsample back, and the
//! two window helpers that read the destination and paste the result.
//!
//! Why the whole pipeline reduces rather than just the pyramid, and what the
//! preview is and is not right about, are in `doc_inpaint`'s module doc.

use image::RgbaImage;

use crate::doc_plane::box_reduced;
use crate::patchmatch::PATCH;

/// A preview reduces until its hole is under this. 40 000 covered pixels is
/// the measured knee: the whole pipeline runs in well under a tenth of a
/// second there, and the structure of the fill — which is all a preview has
/// to be right about — is already settled at that scale.
pub(crate) const PREVIEW_HOLE_PIXELS: u64 = 40_000;

/// The most separate parts a preview will actually fill; the rest are left
/// showing the untouched original.
///
/// [`PREVIEW_HOLE_PIXELS`] bounds the reduced targets of ONE call's worth of
/// searching, and that is the whole story for a compact selection. It is not
/// the story for a scattered one, because a component costs a fixed amount
/// however few pixels it holds — its window planes, its distance transform,
/// its pyramid, its integral image and one membrane solve over the window —
/// and because a small component cannot be reduced at all
/// ([`MIN_PREVIEW_SIDE`]). Measured, the smallest window the ring rules
/// produce (43 x 43, a single-pixel component at
/// [`crate::inpaint_plan::RING_MIN`]) previews in ~3.4 ms whether it holds
/// one target or a hundred, so the part COUNT is what bounds the time:
/// 200 parts is 0.6-0.7 s on every shape that reaches it, which is what the
/// 1 000 000-pixel single hole costs to preview.
///
/// Without it a preview cost what the fill cost, which is the one thing a
/// preview must not do: 900 12-px specks previewed in 2.30 s against a
/// 2.30 s fill, and 2 888 one-pixel specks — the most the work cap admits —
/// would have previewed in the 9.8 s the fill takes, with the sheet's Cancel
/// blocking the main thread on it.
pub(crate) const PREVIEW_MAX_PARTS: usize = 200;

/// The shortest side a reduced window may have. A window narrower than four
/// patches has no room to move a source patch — `patchmatch::should_coarsen`
/// stops the pyramid at the same number for the same reason — so a component
/// whose window would reduce past this previews at a finer factor than the
/// call's. That is the one place the call-level reduction gives ground, and
/// it gives it where the alternative is a preview that refuses a fill which
/// succeeds.
pub(crate) const MIN_PREVIEW_SIDE: usize = 4 * PATCH;

/// The most reduced WORKING AREA a preview will search, vote and solve over
/// — the whole call's windows, added up and divided by the reduction.
///
/// This is the quantity that decides what a preview costs, and choosing the
/// reduction from the covered count alone was wrong for exactly the shape
/// `doc_inpaint`'s own module doc calls content-aware fill's most common use.
/// A three-pixel scratch running corner to corner on a 5000 x 5000 scan
/// covers 15 000 pixels — under [`PREVIEW_HOLE_PIXELS`], so it previewed at
/// factor 1 — while its window is the whole 25-megapixel picture, and the
/// "preview" ran the identical full-resolution pipeline as the commit:
/// measured 4.27 s against a 4.10 s fill. Since the sheet's Cancel blocks the
/// main thread on the render in flight and every edited field arms another,
/// that is the one thing a preview must not do.
///
/// One megapixel is the measured knee: `doc_inpaint`'s cost model is about
/// 0.1 s per megapixel of window plus 1.2 s per megapixel of dilated region,
/// so a megapixel of reduced window is a fraction of a second whatever shape
/// it has.
pub(crate) const PREVIEW_WINDOW_PIXELS: u64 = 1_000_000;

/// A preview reduces until its hole is under [`PREVIEW_HOLE_PIXELS`] AND its
/// working area under [`PREVIEW_WINDOW_PIXELS`].
///
/// Both are the whole CALL's, not one component's: the preview is a statement
/// about what the sheet's re-render costs. `windows` is the sum of the
/// windows `inpaint_plan` sized for the components the preview will actually
/// fill (the part cap has already been applied), and `area` the covered
/// count — the hole rule stays as a floor, because a hole that is huge in a
/// small window still costs its own search.
///
/// A component that cannot survive the factor climbs back down on its own in
/// `doc_inpaint::preview_plane`; this is the ceiling, not a promise.
pub(crate) fn preview_factor(area: u64, windows: u64) -> usize {
    [1usize, 2, 4, 8, 16]
        .into_iter()
        .find(|k| {
            let scale = *k as u64 * *k as u64;
            area / scale <= PREVIEW_HOLE_PIXELS && windows / scale <= PREVIEW_WINDOW_PIXELS
        })
        .unwrap_or(16)
}

/// The layer's pixels over the window, transparent where the window falls off
/// the layer or off the canvas. `canvas` is the document's size and `offset`
/// the layer's; the canvas -> layer mapping is `RzDocument::painting_layer`'s
/// (`doc.rs`, the master copy), in i64 so an extreme offset cannot wrap.
///
/// It takes the pixel buffer rather than the document because the inpaint
/// driver threads ONE clone of it through every component; reading the
/// document instead would mean a fresh document per component, which is the
/// cost `doc_heal::heal_layer` is written to avoid.
pub(crate) fn dest_window(
    canvas: (u32, u32),
    pixels: &RgbaImage,
    offset: (i32, i32),
    win: (i64, i64, usize, usize),
) -> RgbaImage {
    let (wx, wy, ww, wh) = win;
    let mut out = RgbaImage::new(ww as u32, wh as u32);
    let (lw, lh) = pixels.dimensions();
    let (off_x, off_y) = (i64::from(offset.0), i64::from(offset.1));
    for y in 0..wh {
        for x in 0..ww {
            let (cx, cy) = (wx + x as i64, wy + y as i64);
            if cx < 0 || cy < 0 || cx >= i64::from(canvas.0) || cy >= i64::from(canvas.1) {
                continue;
            }
            let (lx, ly) = (cx - off_x, cy - off_y);
            if lx < 0 || ly < 0 || lx >= i64::from(lw) || ly >= i64::from(lh) {
                continue;
            }
            out.put_pixel(x as u32, y as u32, *pixels.get_pixel(lx as u32, ly as u32));
        }
    }
    out
}

/// The preview's write-back: `out = dst + w·(f − dst)`, the rule
/// `doc_heal::heal_window_into_pixels` owns and this repeats for the one case
/// it cannot serve — the preview's membrane solve already ran, on a reduced
/// copy, and re-solving at full resolution is precisely the cost the preview
/// exists to avoid. Alpha is untouched and a transparent destination pixel is
/// skipped, exactly as there; and like there it writes into the caller's one
/// pixel buffer and returns whether any byte moved.
#[allow(clippy::too_many_arguments)]
pub(crate) fn paste_window_into_pixels(
    canvas: (u32, u32),
    pixels: &mut RgbaImage,
    offset: (i32, i32),
    win: (i64, i64, usize, usize),
    rgb: &[u8],
    write: &[u8],
    strength: f32,
) -> bool {
    let (wx, wy, ww, wh) = win;
    let (lw, lh) = pixels.dimensions();
    let (off_x, off_y) = (i64::from(offset.0), i64::from(offset.1));
    let strength = strength.clamp(0.0, 1.0);
    let mut changed = false;
    for y in 0..wh {
        for x in 0..ww {
            let i = y * ww + x;
            if write[i] == 0 {
                continue;
            }
            let (cx, cy) = (wx + x as i64, wy + y as i64);
            if cx < 0 || cy < 0 || cx >= i64::from(canvas.0) || cy >= i64::from(canvas.1) {
                continue;
            }
            let (lx, ly) = (cx - off_x, cy - off_y);
            if lx < 0 || ly < 0 || lx >= i64::from(lw) || ly >= i64::from(lh) {
                continue;
            }
            let px = pixels.get_pixel_mut(lx as u32, ly as u32);
            if px.0[3] == 0 {
                continue;
            }
            let weight = f32::from(write[i]) / 255.0 * strength;
            for (c, v) in px.0[..3].iter_mut().enumerate() {
                let out = f32::from(*v) + weight * (f32::from(rgb[i * 3 + c]) - f32::from(*v));
                let new = (out.clamp(0.0, 255.0) + 0.5).floor() as u8;
                if new != *v {
                    *v = new;
                    changed = true;
                }
            }
        }
    }
    changed
}

/// Three planes through `doc_plane::box_reduced`, the master copy of the
/// rounded box mean, and re-interleaved.
pub(crate) fn reduce_rgb(rgb: &[u8], w: usize, h: usize, k: usize) -> Vec<u8> {
    let n = w * h;
    let (rw, rh) = (w.div_ceil(k), h.div_ceil(k));
    let mut out = vec![0u8; rw * rh * 3];
    for c in 0..3 {
        let plane: Vec<u8> = (0..n).map(|i| rgb[i * 3 + c]).collect();
        let Some((small, _, _)) = box_reduced(&plane, w as u32, h as u32, k as u32) else {
            continue;
        };
        for (i, v) in small.iter().enumerate() {
            out[i * 3 + c] = *v;
        }
    }
    out
}

/// The window's destination pixels reduced, channel by channel, for the
/// preview's one-layer working document.
pub(crate) fn reduce_rgba(image: &RgbaImage, w: usize, h: usize, k: usize) -> RgbaImage {
    let (rw, rh) = (w.div_ceil(k), h.div_ceil(k));
    let mut out = RgbaImage::new(rw as u32, rh as u32);
    for c in 0..4 {
        let plane: Vec<u8> = image.pixels().map(|p| p.0[c]).collect();
        let Some((small, _, _)) = box_reduced(&plane, w as u32, h as u32, k as u32) else {
            continue;
        };
        for (i, v) in small.iter().enumerate() {
            out.get_pixel_mut((i % rw) as u32, (i / rw) as u32).0[c] = *v;
        }
    }
    out
}

/// A boolean plane reduced by OR: the preview's hole must never be LOST, or
/// a thin scratch would vanish at the reduced scale and preview as nothing.
pub(crate) fn reduce_any(src: &[bool], w: usize, h: usize, k: usize) -> Vec<bool> {
    reduce_bool(src, w, h, k, false)
}

/// A boolean plane reduced by AND: a coarse pixel carries data only when
/// every child does, so no reduced source patch can hold an invented colour.
pub(crate) fn reduce_all(src: &[bool], w: usize, h: usize, k: usize) -> Vec<bool> {
    reduce_bool(src, w, h, k, true)
}

fn reduce_bool(src: &[bool], w: usize, h: usize, k: usize, all: bool) -> Vec<bool> {
    let (rw, rh) = (w.div_ceil(k), h.div_ceil(k));
    let mut out = vec![all; rw * rh];
    for y in 0..h {
        for x in 0..w {
            let i = (y / k) * rw + x / k;
            if all {
                out[i] &= src[y * w + x];
            } else {
                out[i] |= src[y * w + x];
            }
        }
    }
    out
}

/// Bilinear upsample of a reduced window back to full size. Reduced pixel
/// `c` covers `[c·k, c·k + k)`, so its centre is at `c·k + (k − 1)/2` and a
/// full-resolution `x` samples at `(x − (k − 1)/2) / k`.
pub(crate) fn upsample_rgb(
    rgb: &[u8],
    rw: usize,
    rh: usize,
    k: usize,
    w: usize,
    h: usize,
) -> Vec<u8> {
    let mut out = vec![0u8; w * h * 3];
    let half = (k as f32 - 1.0) * 0.5;
    for y in 0..h {
        let v = ((y as f32 - half) / k as f32).clamp(0.0, rh as f32 - 1.0);
        let (y0, fy) = (v.floor() as usize, v - v.floor());
        let y1 = (y0 + 1).min(rh - 1);
        for x in 0..w {
            let u = ((x as f32 - half) / k as f32).clamp(0.0, rw as f32 - 1.0);
            let (x0, fx) = (u.floor() as usize, u - u.floor());
            let x1 = (x0 + 1).min(rw - 1);
            let corners = [
                (y0 * rw + x0, (1.0 - fx) * (1.0 - fy)),
                (y0 * rw + x1, fx * (1.0 - fy)),
                (y1 * rw + x0, (1.0 - fx) * fy),
                (y1 * rw + x1, fx * fy),
            ];
            let i = (y * w + x) * 3;
            for c in 0..3 {
                let acc: f32 = corners
                    .iter()
                    .map(|(j, weight)| weight * f32::from(rgb[j * 3 + c]))
                    .sum();
                out[i + c] = (acc + 0.5).floor().clamp(0.0, 255.0) as u8;
            }
        }
    }
    out
}
