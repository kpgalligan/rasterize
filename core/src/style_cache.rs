//! The rendered-plane cache that lives inside each `Arc<LayerStyle>`
//! (`style_render` is the renderer it fronts).
//!
//! # Keys
//!
//! A bounded LRU of `CACHE_CAPACITY` entries most-recent-first, keyed on the
//! layer's pixel and mask `Arc` ALLOCATIONS plus the mask-enabled flag, the
//! global light (only when the style reads it) and the canvas/offset (only
//! for canvas-aligned gradients). Capacity > 1 because Duplicate Layer
//! shares ONE `Arc<LayerStyle>` between two layers whose pixels diverge after
//! the first edit; a single entry would re-blur both every frame.
//!
//! Keys hold `Weak` pointers and compare by address: a `Weak` keeps the
//! `ArcInner` allocation alive (only the payload is dropped when the last
//! strong reference goes), so its address CANNOT be reused by another `Arc`
//! while the entry lives — pointer equality is exact, and a dead entry never
//! matches a live `Arc`. `Weak` rather than strong so the cache never pins
//! old pixel buffers (a 12 MP layer is 48 MB per entry). Entries whose
//! pixel `Arc` has died are pruned whenever a new entry is stored: nothing
//! can match them by pointer any more, and the shape they hold is covered
//! by the entry being stored. Each entry also remembers the full render
//! context it was rendered under, so a style inheriting the entry (below)
//! can re-key it for its own dependencies and re-render single effects
//! over the same shape.
//!
//! # Misses that are not full renders
//!
//! When no entry matches by pointer, the new shape is built (a render needs
//! it anyway) and compared with the most recent entry of the same layer
//! size and context:
//!
//! - **Identical coverage** — painting colour on an opaque layer, a mask
//!   toggle that hides nothing: a SECOND entry keyed to the new pointers
//!   is stored over the same `Arc` of planes, and the entry that matched
//!   keeps its key. After Duplicate Layer, two layers with one coverage
//!   and pixels of their own therefore each hit by pointer from then on;
//!   moving the one entry between them instead would cost every composite
//!   two shape builds and two coverage compares. The LRU still bounds the
//!   memory, because the planes are shared. Exact by construction — every
//!   effect is a function of the shape, the style and the context, never
//!   of the pixel colours — with one exception: a layer-aligned gradient
//!   spans the shape's `bounds`, the box of the ALPHA (the mask left out),
//!   which can change while the coverage does not (Layer > Mask > Apply
//!   bakes a mask into the alpha; painting under a masked-out region
//!   changes alpha the mask hides). Such a style refreshes only when the
//!   bounds match too, else renders in full; and when the bounds differ
//!   the new entry takes them into a COPY of the planes with its own
//!   shape, so the matched entry keeps its bounds — a style inheriting
//!   either entry later (below) renders its new effects over that entry's
//!   shape, and each must span the box of the layer it is keyed to.
//! - **A local difference** — a brush dab, an eraser tick, a mask stroke:
//!   the bounding box of the changed coverage is padded by the style's
//!   `pad` (the farthest any effect's output moves for an input change)
//!   to the OUTPUT window, padded by `pad` again to the INPUT window the
//!   outputs depend on, aligned to `SUB_PLANE_ALIGN`, and rendered as a
//!   sub-plane (`Shape::sub`); the output window is then copied over a
//!   clone of the cached planes. Every effect is local to its reach
//!   (`style_render`'s plane model — the same property that makes the pad
//!   exact), so the patched planes are bit-identical to a full render;
//!   the tests pin that. A layer-aligned gradient is the one non-local
//!   input (its box is the shape's bounds), so a change to the bounds
//!   under such a style, an input window over half the plane, a pad that
//!   is the `MAX_PAD` cap rather than the effects' reach (an inner shadow
//!   or satin whose distance moves outputs farther than the windows
//!   span — `LayerStyle::pad_is_capped`), or a sub-render whose
//!   contribution list differs from the cached one (an effect that emits
//!   nothing over an empty window and something over a filled one) falls
//!   back to a full render. This is what keeps the brush and eraser
//!   interactive on a photo-sized styled layer: a stroke tick costs a
//!   shape build, a row-wise compare, one render the size of the dab plus
//!   twice the pad, and a copy of the planes — not a re-blur of every
//!   plane.
//!
//! # Inheritance: a replaced style hands over its planes
//!
//! `RzDocument::set_layer_style` mints a new `Arc<LayerStyle>` for every
//! edit — each Layer Style sheet tick, each MCP `set_layer_style`. Left
//! alone, the old `Arc` would keep its planes for as long as any document
//! held it (an undo snapshot: tens of full plane sets of a photo-sized
//! layer, gigabytes nothing but Undo could read), and the new one would
//! re-blur every plane even when only a colour changed. So the setter
//! calls [`LayerStyle::inherit_planes`]: the old cache is DRAINED
//! (a document that still holds the old style re-renders once if it is
//! ever projected again), and when the two styles share a `pad` — the
//! plane size — every live entry is carried over AS IT IS, marked with
//! the effect stack its planes were rendered for, and nothing is
//! rendered. The adoption happens in [`LayerStyle::rendered`], on the
//! first read of each carried entry and only then: per enabled effect,
//! the cached contributions are kept and re-stamped with the new colour,
//! blend, opacity, shift and knock-out when the effect's plane parameters
//! are unchanged (`style_reuse::same_planes` / `restamp`), else that one
//! effect is re-rendered over the entry's shape; every entry sharing the
//! planes settles on the result. The cache holds up to `CACHE_CAPACITY`
//! entries — the pixel buffers of a few brush ticks kept alive by undo
//! snapshots — but a composite reads ONE of them, the layer's current
//! pixels, so a Layer Style sheet tick that moves a satin's angle or a
//! bevel's depth costs one render of that effect however deep the undo
//! stack, not one per entry; an entry never read is never adopted, and a
//! further replacement carries it on still marked with the stack it was
//! actually rendered for. Planes rendered for an EQUAL enabled stack (a
//! fill-opacity or Blend If edit) are the new style's own outright. A
//! pad change is a plane of another size (and, for the downsampled blur,
//! another sampling lattice), so the new cache starts empty and the next
//! composite renders in full.
//!
//! Lookups hold the lock briefly; renders happen outside it, and the
//! candidate entry is read through its `Arc` so a concurrent lookup on the
//! same style can proceed. Poison-tolerant.

use std::sync::{Arc, Mutex, PoisonError, Weak};

use image::{GrayImage, RgbaImage};

use crate::doc::Layer;
use crate::style::{Effect, GlobalLight, LayerStyle};
use crate::style_render::{
    ranked, render_effect, render_effects, Contribution, RenderContext, RenderedEffects, Shape,
    SUB_PLANE_ALIGN,
};
use crate::style_reuse::{restamp, same_planes};

/// Entries kept per style (module doc: > 1 for Duplicate Layer, small
/// because each entry holds every rendered plane of one layer).
pub(crate) const CACHE_CAPACITY: usize = 4;

/// The per-style plane cache (module doc). `Clone` yields a FRESH cache and
/// `PartialEq` is always true, so `LayerStyle` can derive both and two
/// styles compare by their content alone.
#[derive(Default)]
pub(crate) struct RenderCache(Mutex<Vec<CacheEntry>>);

impl Clone for RenderCache {
    fn clone(&self) -> Self {
        RenderCache::default()
    }
}

impl std::fmt::Debug for RenderCache {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("RenderCache")
    }
}

impl PartialEq for RenderCache {
    fn eq(&self, _other: &Self) -> bool {
        true
    }
}

impl RenderCache {
    fn lock(&self) -> std::sync::MutexGuard<'_, Vec<CacheEntry>> {
        self.0.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Drops every entry (module doc: a style that is no longer current
    /// keeps no planes).
    pub(crate) fn clear(&self) {
        self.lock().clear();
    }
}

struct CacheEntry {
    key: CacheKey,
    /// The context the planes were rendered under, in full — the key keeps
    /// only the parts this style depends on.
    ctx: RenderContext,
    planes: Arc<RenderedEffects>,
    /// `Some` while `planes` are still the ones rendered for the enabled
    /// effect stack of a style this one replaced (module doc,
    /// "Inheritance"): they are adopted — re-stamped or re-rendered per
    /// effect against that stack — the first time this entry is read,
    /// and never before. `None` once they are this style's own.
    rendered_for: Option<Arc<[Effect]>>,
}

impl CacheEntry {
    /// What a lookup takes out of an entry under the lock, so the
    /// adoption or render that may follow happens outside it.
    fn found(&self) -> Found {
        Found {
            planes: Arc::clone(&self.planes),
            ctx: self.ctx,
            rendered_for: self.rendered_for.clone(),
        }
    }
}

/// A [`CacheEntry`] read out for use outside the lock (its key aside).
struct Found {
    planes: Arc<RenderedEffects>,
    ctx: RenderContext,
    rendered_for: Option<Arc<[Effect]>>,
}

struct CacheKey {
    pixels: Weak<RgbaImage>,
    mask: Option<Weak<GrayImage>>,
    mask_enabled: bool,
    light: Option<GlobalLight>,
    canvas: Option<(u32, u32)>,
    offset: Option<(i32, i32)>,
}

impl CacheKey {
    fn of(style: &LayerStyle, layer: &Layer, ctx: &RenderContext) -> Self {
        CacheKey {
            pixels: Arc::downgrade(&layer.pixels),
            mask: layer.mask.as_ref().map(Arc::downgrade),
            mask_enabled: layer.mask_enabled,
            light: None,
            canvas: None,
            offset: None,
        }
        .rekeyed(style, ctx)
    }

    /// This key's layer identity with the context parts `style` depends
    /// on taken from `ctx`.
    fn rekeyed(&self, style: &LayerStyle, ctx: &RenderContext) -> Self {
        let aligned = style.needs_canvas_alignment();
        CacheKey {
            pixels: self.pixels.clone(),
            mask: self.mask.clone(),
            mask_enabled: self.mask_enabled,
            light: style.uses_global_light().then_some(ctx.light),
            canvas: aligned.then_some(ctx.canvas),
            offset: aligned.then_some(ctx.layer_offset),
        }
    }

    /// Pointer equality on the `Weak`s, value equality on the rest.
    fn matches(&self, other: &CacheKey) -> bool {
        let mask_same = match (&self.mask, &other.mask) {
            (None, None) => true,
            (Some(a), Some(b)) => std::ptr::eq(a.as_ptr(), b.as_ptr()),
            _ => false,
        };
        std::ptr::eq(self.pixels.as_ptr(), other.pixels.as_ptr())
            && mask_same
            && self.mask_enabled == other.mask_enabled
            && self.same_context(other)
    }

    /// Value equality on the light and the canvas alignment alone.
    fn same_context(&self, other: &CacheKey) -> bool {
        self.light == other.light && self.canvas == other.canvas && self.offset == other.offset
    }

    /// Whether the pixel buffer this entry was rendered for no longer
    /// exists anywhere.
    fn is_dead(&self) -> bool {
        self.pixels.strong_count() == 0
    }
}

impl LayerStyle {
    /// The rendered planes for `layer` under `ctx`: from the cache when the
    /// key matches, shared or patched from the most recent entry of the
    /// same shape size when only the coverage changed (module doc), else
    /// rendered outside the lock and stored most-recent-first. An entry
    /// inherited from a replaced style is adopted here, on its first read
    /// (module doc, "Inheritance"). `None` when the padded plane would
    /// exceed `MAX_PIXELS` (the style then renders no effects).
    pub(crate) fn rendered(
        &self,
        layer: &Layer,
        ctx: &RenderContext,
    ) -> Option<Arc<RenderedEffects>> {
        let key = CacheKey::of(self, layer, ctx);
        let hit = {
            let mut entries = self.cache.lock();
            entries.iter().position(|e| key.matches(&e.key)).map(|i| {
                let entry = entries.remove(i);
                entries.insert(0, entry);
                entries[0].found()
            })
        };
        if let Some(found) = hit {
            return Some(self.settled(found));
        }
        let shape = Shape::of_layer(layer, self.pad())?;
        let candidate = {
            let entries = self.cache.lock();
            entries
                .iter()
                .find(|e| {
                    key.same_context(&e.key)
                        && e.planes.shape.lw == shape.lw
                        && e.planes.shape.lh == shape.lh
                })
                .map(CacheEntry::found)
        };
        let planes = match candidate {
            Some(found) => {
                // Adopted first when inherited: what is shared or patched
                // below must be this style's own planes.
                let old = self.settled(found);
                match old.shape.diff_bounds(&shape) {
                    // The same shape: the entry describes this layer too —
                    // unless a layer-aligned gradient spans bounds that
                    // moved under an unchanged coverage (module doc).
                    None if !self.needs_shape_bounds() || old.shape.bounds == shape.bounds => {
                        // A second key over the same planes; the matched
                        // entry keeps its own. The stored shape follows
                        // this layer's bounds: a style that inherits the
                        // entry renders its NEW effects over that shape
                        // (`adopted`), and a layer-aligned gradient among
                        // them spans the shape's `bounds` — which this
                        // style does not read, and which can move under an
                        // unchanged coverage (module doc). A copy with the
                        // new shape only when they did, so the matched
                        // entry keeps the bounds of the layer it is keyed
                        // to.
                        let planes = if old.shape.bounds == shape.bounds {
                            old
                        } else {
                            Arc::new(RenderedEffects {
                                shape,
                                below: old.below.clone(),
                                interior: old.interior.clone(),
                            })
                        };
                        self.store(key, ctx, Arc::clone(&planes));
                        return Some(planes);
                    }
                    None => Arc::new(render_effects(self, shape, ctx)),
                    Some(diff) => match self.patched(&old, shape, diff, ctx) {
                        Ok(patched) => Arc::new(patched),
                        Err(shape) => Arc::new(render_effects(self, shape, ctx)),
                    },
                }
            }
            None => Arc::new(render_effects(self, shape, ctx)),
        };
        self.store(key, ctx, Arc::clone(&planes));
        Some(planes)
    }

    /// Stores `planes` for `key` most-recent-first as this style's own,
    /// pruning the entries whose pixel buffer has died (module doc).
    fn store(&self, key: CacheKey, ctx: &RenderContext, planes: Arc<RenderedEffects>) {
        let mut entries = self.cache.lock();
        entries.retain(|e| !e.key.is_dead());
        entries.insert(
            0,
            CacheEntry {
                key,
                ctx: *ctx,
                planes,
                rendered_for: None,
            },
        );
        entries.truncate(CACHE_CAPACITY);
    }

    /// `found`'s planes as this style's own: as they are when rendered for
    /// it, else adopted now (module doc, "Inheritance") under the context
    /// they were rendered in — the light a resolved angle is compared
    /// under, which the key pins only when this style reads it — and
    /// every entry still holding them settled on the result, so the
    /// adoption happens once.
    fn settled(&self, found: Found) -> Arc<RenderedEffects> {
        let Some(previous) = found.rendered_for else {
            return found.planes;
        };
        let adopted = Arc::new(self.adopted(&previous, &found.planes, &found.ctx));
        let mut entries = self.cache.lock();
        for entry in entries
            .iter_mut()
            .filter(|e| Arc::ptr_eq(&e.planes, &found.planes))
        {
            entry.planes = Arc::clone(&adopted);
            entry.rendered_for = None;
        }
        adopted
    }

    /// `old`'s planes re-rendered over the window `diff` changed (module
    /// doc): the output window is `diff` padded by `pad`, rendered from a
    /// sub-plane padded by `pad` again and aligned to `SUB_PLANE_ALIGN`.
    /// `Err(shape)` hands the shape back when a full render is needed
    /// instead: a bounds change under a layer-aligned gradient, a capped
    /// pad, an input window over half the plane, or a contribution list
    /// that differs.
    fn patched(
        &self,
        old: &RenderedEffects,
        shape: Shape,
        diff: (u32, u32, u32, u32),
        ctx: &RenderContext,
    ) -> Result<RenderedEffects, Shape> {
        if self.needs_shape_bounds() && old.shape.bounds != shape.bounds {
            return Err(shape);
        }
        // The windows below are sized by `pad`; a capped pad is smaller
        // than the farthest an output can move (`pad_is_capped`).
        if self.pad_is_capped() {
            return Err(shape);
        }
        let pad = i64::from(self.pad());
        let (w, h) = (i64::from(shape.w), i64::from(shape.h));
        let align = i64::from(SUB_PLANE_ALIGN);
        // Output window: where any effect's plane can differ.
        let ox0 = (i64::from(diff.0) - pad).max(0);
        let oy0 = (i64::from(diff.1) - pad).max(0);
        let ox1 = (i64::from(diff.2) + pad).min(w);
        let oy1 = (i64::from(diff.3) + pad).min(h);
        // Input window: what those outputs depend on, on the blur lattice.
        let ix0 = (ox0 - pad).max(0) / align * align;
        let iy0 = (oy0 - pad).max(0) / align * align;
        let ix1 = ((ox1 + pad).min(w) + align - 1) / align * align;
        let iy1 = ((oy1 + pad).min(h) + align - 1) / align * align;
        let (ix1, iy1) = (ix1.min(w), iy1.min(h));
        if (ix1 - ix0) * (iy1 - iy0) * 2 > w * h {
            return Err(shape);
        }
        let sub = shape.sub(ix0 as u32, iy0 as u32, ix1 as u32, iy1 as u32);
        let fresh = render_effects(self, sub, ctx);
        let same_slots = |a: &[Contribution], b: &[Contribution]| {
            a.len() == b.len() && a.iter().zip(b).all(|(x, y)| x.same_slot(y))
        };
        if !same_slots(&old.below, &fresh.below) || !same_slots(&old.interior, &fresh.interior) {
            return Err(shape);
        }
        let sub_w = fresh.shape.w as usize;
        let len = (ox1 - ox0) as usize;
        let patch = |cached: &Contribution, window: &Contribution| -> Contribution {
            let mut c = cached.clone();
            for y in oy0..oy1 {
                let src = ((y - iy0) as usize) * sub_w + (ox0 - ix0) as usize;
                let dst = (y as usize) * (w as usize) + ox0 as usize;
                c.coverage[dst..dst + len].copy_from_slice(&window.coverage[src..src + len]);
            }
            c
        };
        Ok(RenderedEffects {
            shape,
            below: old
                .below
                .iter()
                .zip(&fresh.below)
                .map(|(a, b)| patch(a, b))
                .collect(),
            interior: old
                .interior
                .iter()
                .zip(&fresh.interior)
                .map(|(a, b)| patch(a, b))
                .collect(),
        })
    }

    /// Takes over `previous`'s cache (module doc, "Inheritance"):
    /// `previous` is drained unconditionally; when the two styles share a
    /// pad, every live entry is re-keyed for this style and carried over
    /// as it is, ahead of anything this cache already held — marked with
    /// the enabled stack its planes were rendered for (`previous`'s, or an
    /// earlier style's when `previous` never read the entry; none when
    /// that stack equals this style's), to be adopted on its first read.
    /// Renders nothing.
    pub(crate) fn inherit_planes(&self, previous: &LayerStyle) {
        let taken = std::mem::take(&mut *previous.cache.lock());
        if !self.has_enabled_effects() || self.pad() != previous.pad() {
            return;
        }
        let stack: Option<Arc<[Effect]>> = (!previous.enabled_effects().eq(self.enabled_effects()))
            .then(|| previous.enabled_effects().cloned().collect());
        let carried: Vec<CacheEntry> = taken
            .into_iter()
            .filter(|e| !e.key.is_dead())
            .take(CACHE_CAPACITY)
            .map(|e| CacheEntry {
                key: e.key.rekeyed(self, &e.ctx),
                ctx: e.ctx,
                planes: e.planes,
                rendered_for: e.rendered_for.or_else(|| stack.clone()),
            })
            .collect();
        let mut entries = self.cache.lock();
        entries.splice(0..0, carried);
        entries.truncate(CACHE_CAPACITY);
    }

    /// `old` (rendered for the enabled stack `previous` under `ctx`) as
    /// this style's planes over the same shape: per enabled effect,
    /// `previous`'s cached contributions re-stamped when the planes are
    /// the same, else a fresh render of that effect alone.
    fn adopted(
        &self,
        previous: &[Effect],
        old: &RenderedEffects,
        ctx: &RenderContext,
    ) -> RenderedEffects {
        let mut all = Vec::new();
        for effect in self.enabled_effects() {
            let kind = effect.kind();
            let reusable = previous
                .iter()
                .find(|p| p.kind() == kind)
                .is_some_and(|p| same_planes(p, effect, ctx.light));
            if reusable {
                all.extend(
                    old.below
                        .iter()
                        .chain(&old.interior)
                        .filter(|c| c.kind == kind)
                        .map(|c| restamp(c, effect, ctx.light)),
                );
            } else {
                all.extend(render_effect(effect, &old.shape, ctx));
            }
        }
        let (below, interior) = ranked(all);
        RenderedEffects {
            shape: old.shape.clone(),
            below,
            interior,
        }
    }
}
