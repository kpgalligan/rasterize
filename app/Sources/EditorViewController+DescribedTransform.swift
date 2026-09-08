import AppKit

// Free Transform on a DESCRIBED layer (text, shape, Live Photo): an affine
// session — a plain one, or a ⌘-corner box pulled back to a parallelogram,
// which is the exact affine it denotes — composes its matrix into the
// layer's description and the layer re-renders through it (crisp vector
// edges; rotating back is lossless) — no rasterize prompt. The frozen
// commit (EditorViewController.commitTransformSession) calls
// `commitDescribedTransform` first and falls through to the prompt-and-
// resample path for a true perspective quad, a description that cannot
// render right now, or a raster that is not its description's rendering.
// Mirrored for the agent by `transform_layer` and a parallelogram
// `distort_layer` (AgentServer+Distort.swift), which run the same pure op
// and fall through to their rasterizing path on nil. The composition rule,
// the anchor arithmetic, the raster tolerance and the mask re-crop are
// DescribedLayer.swift's; the parallelogram test is LayerTransform's;
// nothing numeric is decided here.

/// What a Free Transform commit on a described layer did.
enum DescribedTransformCommit {
    /// Composed and re-rendered as one undo step; the session may close.
    case committed
    /// The composed placement is one the core would refuse — a singular
    /// composed map, or a raster past the core's pixel cap: the very
    /// refusals the resampling path would make for the same extent. The
    /// session stays open so the drag can be pulled back (or Escape cancels
    /// it), today's rule for a refused commit. Never returned for a
    /// description that merely failed to render: that is `unrenderable`.
    case refused
    /// Not a described layer, a true perspective quad, a description that
    /// cannot render right now (a font family not installed here, a Live
    /// Photo whose source will not decode, a description whose anchor
    /// cannot be recovered), or a raster that is not its description's
    /// rendering (one an earlier build's Image Size resampled): the caller
    /// takes the rasterize prompt and resamples the real pixels — the
    /// pixels are the truth when the description is not.
    case unrenderable
}

/// The composition a transform of a described layer would commit, worked
/// out BEFORE anything renders: the resolved description (legacy box
/// materialized), the composed map and the moved anchor. Computed once by
/// `RasterDocument.describedTransformPlacement`, so the commit can tell a
/// refusal of the extent from a render that failed, and the Live Photo
/// probe behind `isRenderable` runs once per commit.
struct DescribedPlacement {
    let description: LayerDescription
    /// L′ = L ∘ M_lin, snapped.
    let map: LinearMap
    /// M·P exactly, then snapped.
    let anchor: CGPoint
    /// `description.sourceRect()`, measured ONCE by
    /// `describedTransformPlacement` — a text layout is the expensive part
    /// of a commit, linear in the string — and shared by the anchor
    /// recovery and `isCommittable`.
    let sourceRect: CGRect
    /// Whether the layer's raster is EXACTLY the rule's rect for the
    /// description as it stands — the precondition of the lossless
    /// shortcut in `transformingDescribedLayer`. A legacy raster that kept
    /// its anchor's fraction inside is a pixel larger and re-renders
    /// instead.
    let rasterOnRule: Bool

    /// Whether the composed placement is one the core would accept: an
    /// invertible map and a raster rect inside the pixel cap — the refusals
    /// the resampling path makes for the same extent.
    var isCommittable: Bool {
        map.isInvertible
            && map.rasterRect(of: sourceRect, fraction: DescribedLayer.anchorFraction(anchor))
                != nil
    }
}

/// A description resolved onto its raster (`RasterDocument.resolve`): the
/// raw description, the same with its legacy box materialized, the padded
/// source rect, the rule's rect for it, and the recovered anchor.
private struct ResolvedDescription {
    let description: LayerDescription
    let source: CGRect
    let rect: (originX: Int, originY: Int, width: Int, height: Int)
    let anchor: CGPoint
}

extension RasterDocument {
    /// `raw` (layer `info`'s decoded description) resolved onto the layer's
    /// raster: its legacy box materialized from the raster (an unspecified
    /// box may never coexist with a non-identity map, and the composed map
    /// is about to be one), its source laid out ONCE, the rule's rect for
    /// it, and the anchor recovered over that very rect rather than through
    /// `describedAnchor`, which would decode and lay out again (the raw
    /// description is the same payload as the resolved one unless a legacy
    /// box was just materialized — and then its raster origin is the
    /// width-free (−pad, −pad) rule, which needs no layout at all).
    ///
    /// nil for a source that cannot be measured, an anchor that cannot be
    /// recovered, or a raster that is NOT this description's rendering
    /// (`DescribedLayer.rasterAgrees`): a layer an earlier build's Image
    /// Size resampled while its description kept its original size.
    /// Composing into that description would re-render the layer at a size
    /// the user never saw, so it takes the rasterize prompt — and the
    /// raster's own pivot — exactly as any raster does.
    private static func resolve(_ raw: LayerDescription, info: LayerInfo) -> ResolvedDescription? {
        let description = raw.resolved(rasterWidth: info.width)
        guard let source = description.sourceRect(),
              let rect = description.transform.rasterRect(
                of: source, fraction: description.originFraction),
              DescribedLayer.rasterAgrees(width: info.width, height: info.height, with: rect),
              let anchor = raw.anchor(
                offsetX: info.offsetX, offsetY: info.offsetY,
                source: raw == description ? source : nil)
        else { return nil }
        return ResolvedDescription(
            description: description, source: source, rect: rect, anchor: anchor)
    }

    /// The placement Free Transform / transform_layer would give layer
    /// `idx`: the description resolved onto its raster (`resolve`),
    /// `matrix`'s linear part composed onto its map (DescribedLayer.swift,
    /// L′ = L ∘ M_lin, snapped), and the anchor moved by the FULL matrix,
    /// translation included, exactly, then 1e-9-snapped so a rotate-back
    /// returns it to the very same value. nil when there is nothing to
    /// compose: a plain raster layer, a description that cannot render
    /// right now (`isRenderable` — asked first, so a text family missing
    /// here is never laid out with the fallback face), an anchor that
    /// cannot be recovered, or a raster that is not the description's
    /// rendering.
    func describedTransformPlacement(
        _ idx: Int, _ matrix: CGAffineTransform
    ) -> DescribedPlacement? {
        guard let raw = layerDescription(idx), let info = layerInfo(idx), raw.isRenderable,
              let resolved = Self.resolve(raw, info: info)
        else { return nil }
        return DescribedPlacement(
            description: resolved.description,
            map: resolved.description.transform.concatenating(matrix).snapped(),
            anchor: DescribedLayer.snappedAnchor(resolved.anchor.applying(matrix)),
            sourceRect: resolved.source,
            rasterOnRule: resolved.rect.width == info.width && resolved.rect.height == info.height)
    }

    /// The pivot a Free Transform session — and transform_layer's default
    /// `around: "center"` — turns and scales a DESCRIBED layer about: the
    /// EXACT centre of the description's padded source rect under its map,
    /// P + L·centre(S). The raster rect's centre is not that point: the
    /// raster is the quad's outward-rounded bounding box (plus the 1 px
    /// slack of a non-exact map), so its centre sits a fraction of a pixel
    /// off the true one — a different fraction before and after a turn —
    /// and two sessions that undo each other would pivot on different
    /// points, composing (I − R⁻¹)(c₂ − c₁) into the anchor on every round
    /// trip: a whole-pixel creep for some source sizes, a permanent
    /// fraction (a sub-pixel re-render, a version-2 payload) for the rest.
    /// About the exact centre a rotation or scale leaves the centre itself
    /// fixed — c′ = M·P + (L ∘ M_lin)·centre(S) = M·(P + L·centre(S)) = c —
    /// so the next session's default pivot is the very point the last one
    /// turned about, and rotating back returns the anchor to its original
    /// value (then 1e-9-snapped). Shared by the UI session
    /// (EditorViewController.freeTransform) and the agent
    /// (AgentServer.transformLayer), so the two can undo each other too.
    ///
    /// nil for a plain raster layer, an anchor that cannot be recovered, a
    /// text description whose family is not installed here (its layout
    /// would be the fallback face's), or a raster that is not the
    /// description's rendering: such a layer takes the resampling path,
    /// whose pivot is the raster's centre as for any raster. A Live Photo's
    /// rect is its payload's own size, so no probe decode is needed to
    /// trust it.
    func describedPivot(_ idx: Int) -> CGPoint? {
        guard let raw = layerDescription(idx), let info = layerInfo(idx) else { return nil }
        if case .text = raw, !raw.isRenderable { return nil }
        guard let resolved = Self.resolve(raw, info: info) else { return nil }
        let centre = raw.transform.apply(
            CGPoint(x: resolved.source.midX, y: resolved.source.midY))
        return CGPoint(x: resolved.anchor.x + centre.x, y: resolved.anchor.y + centre.y)
    }

    /// Free Transform / transform_layer on a DESCRIBED layer: composes
    /// `matrix` into the description (`describedTransformPlacement`) and
    /// re-renders through the composed map — the mask resampled by the
    /// core's transform and re-cropped, the style scaled by it (Scale
    /// Effects), when the layer has either. nil for a plain raster layer, a
    /// description that cannot render, a map the composition makes
    /// singular, or a core refusal — the caller falls through to the
    /// resampling path.
    ///
    /// Landing guarantee: the re-rendered raster's rect is the outward-
    /// rounded bbox (plus the 1 px non-exact slack) of the exact source quad
    /// at the moved anchor — the very quad the session previewed — so the
    /// glyphs land where the preview drew them to within that rounding. The
    /// core's own mask extent (the bbox of M·oldRect) is within a pixel or
    /// two of it, which `DescribedLayer.recrop` absorbs with edge extension.
    /// Rotating back composes the inverse: the map snaps to the identity
    /// exactly (cos²θ + sin²θ lands within 1e-16 of 1, far inside the 1e-9
    /// snap), and the anchor returns to its original value exactly when
    /// both turns share a pivot. They do by default: a new interactive
    /// session and the agent's `around: "center"` both pivot on the
    /// description's exact centre (`describedPivot`), which a rotation or
    /// scale leaves fixed, so the second session finds the very point the
    /// first turned about; an explicit `pivot_x`/`pivot_y` pair passed to
    /// both calls does the same. (The RASTER rect's centre — the
    /// outward-rounded bbox of the turned quad — would not: it sits a
    /// different fraction of a pixel from the true centre before and after
    /// the turn, and the anchor absorbed that difference on every round
    /// trip.) The glyphs are re-rendered upright from the description
    /// either way, never resampled.
    ///
    /// Performance rule — the two cases that need no render at all come
    /// first, because a Live Photo's render is a full-resolution decode and
    /// a text layer's a layout pass, on every Return:
    ///   1. A whole-pixel MOVE (the linear part the identity, the translation
    ///      integral within 1e-9): translation is the core's layer offset,
    ///      never the description's (DescribedLayer.swift), so the meta does
    ///      not change at all — a pure offset change, the Move tool's edit.
    ///   2. A RESAMPLE-FREE matrix — one of the core's six exact linear forms
    ///      with a whole-pixel translation (`LinearMap.isResampleFree`) — on a
    ///      raster that is exactly the rule's (`rasterOnRule`): the core's
    ///      lossless copy of pixels and mask IS the composed description's
    ///      rendering at the rule's own offset — the argument
    ///      DescribedLayerGeometry.swift makes for the document ops holds
    ///      for any exact matrix with an integer translation — so only the
    ///      map and the anchor's fraction are patched, and the layer
    ///      commits exactly as the preview showed it. Mask and style ride
    ///      the core's exact path (scale 1: the style is kept).
    ///   3. Otherwise the description re-renders. When the layer has a mask
    ///      or a style, the core's `transformingLayer` runs first to harvest
    ///      the resampled mask and the scaled style at the transformed
    ///      extent — a full resample of a raster about to be replaced, the
    ///      documented cost of keeping the FFI to the one new export — and
    ///      the re-render lands over it; a bare layer composes and
    ///      re-renders directly.
    func transformingDescribedLayer(
        _ idx: Int, _ matrix: CGAffineTransform, sampler: RzResizeFilter
    ) -> RasterDocument? {
        guard let placement = describedTransformPlacement(idx, matrix) else { return nil }
        return transformingDescribedLayer(idx, matrix, placement: placement, sampler: sampler)
    }

    /// The op above for a placement already worked out (the UI commit
    /// computes it first to classify a failure).
    fileprivate func transformingDescribedLayer(
        _ idx: Int, _ matrix: CGAffineTransform, placement: DescribedPlacement,
        sampler: RzResizeFilter
    ) -> RasterDocument? {
        guard placement.map.isInvertible, let info = layerInfo(idx) else { return nil }
        let linear = LinearMap(
            a: Double(matrix.a), b: Double(matrix.b), c: Double(matrix.c), d: Double(matrix.d))
        let shift = (x: Double(matrix.tx), y: Double(matrix.ty))
        // Integral within the core's own epsilon, and inside the offsets it
        // can address (so the rounding below cannot trap).
        let wholePixelShift = shift.x.isFinite && shift.y.isFinite
            && abs(shift.x) <= Double(Int32.max) && abs(shift.y) <= Double(Int32.max)
            && abs(shift.x - shift.x.rounded()) <= LinearMap.epsilon
            && abs(shift.y - shift.y.rounded()) <= LinearMap.epsilon
        // 1. A whole-pixel move: a pure offset change (nil for no move at
        //    all, which the callers already refuse).
        if linear.isIdentity, wholePixelShift {
            return withLayerOffset(
                idx, info.offsetX + Int(shift.x.rounded()), info.offsetY + Int(shift.y.rounded()))
        }
        let composed = placement.description.withTransform(placement.map)
        // 2. A resample-free matrix on a raster that is the rule's: the
        //    core's lossless copy, then the meta patch.
        if linear.isResampleFree, wholePixelShift, placement.rasterOnRule,
           let copied = transformingLayer(idx, matrix, sampler: sampler),
           let meta = composed.withOriginFraction(
               DescribedLayer.anchorFraction(placement.anchor)).json()
        {
            return copied.withLayerMeta(idx, meta)
        }
        // 3. The re-render, over the core's transform when a mask or style
        //    must be carried through it.
        let base: RasterDocument
        if layerHasMask(idx) || layerHasStyle(idx) {
            guard let moved = transformingLayer(idx, matrix, sampler: sampler) else {
                return nil
            }
            base = moved
        } else {
            base = self
        }
        // `base`'s pixels are about to be replaced; its mask (at the core's
        // transformed rect) and its scaled style are what land, re-cropped
        // into the re-render's rect by rerenderingDescribedLayer.
        return base.rerenderingDescribedLayer(idx, composed, anchor: placement.anchor)
    }
}

extension EditorViewController {
    /// The commit branch commitTransformSession takes for a described
    /// layer: one undo step "Transform Layer", no rasterize prompt, for a
    /// plain affine session (`matrix`) or a warped box (`quad`, the
    /// ⌘-corner quad) that is still a parallelogram — the exact affine
    /// `LayerTransform.parallelogramAffine` recovers from it over the
    /// layer's rect, exactly what the agent's distort_layer composes for
    /// the same corners. A true perspective quad has no affine to compose
    /// and is `unrenderable` here: the caller's prompt-and-perspective path
    /// is the only one that can commit it.
    ///
    /// No prompt and no meta drop here: the frozen caller passes everything
    /// (the session stays private to it), and an unrenderable description
    /// hands back to its prompt path, where a missing font, a Live Photo
    /// whose source will not decode, or a raster that is not the
    /// description's rendering resamples the real pixels after the user
    /// agrees. The anchor must be recoverable too: a description whose
    /// source lays out to nothing, or a legacy text box under a non-identity
    /// map (which no writer produces), cannot re-render, and the prompt is
    /// the honest outcome — not a refusal that would leave the session
    /// stuck open. Likewise a render that fails AFTER the placement passed
    /// (a Live Photo whose source decodes no further than its probe): the
    /// prompt, not a beep on every Return. `.refused` is reserved for the
    /// placement the core would refuse — a singular composed map, an extent
    /// past its cap — where keeping the session open lets the drag be
    /// pulled back.
    func commitDescribedTransform(
        layer idx: Int, matrix: CGAffineTransform, quad: [CGPoint]?, sampler: RzResizeFilter
    ) -> DescribedTransformCommit {
        guard let document = document, let doc = document.doc, let info = doc.layerInfo(idx)
        else { return .unrenderable }
        var affine = matrix
        if let quad = quad {
            let rect = CGRect(
                x: CGFloat(info.offsetX), y: CGFloat(info.offsetY),
                width: CGFloat(info.width), height: CGFloat(info.height))
            guard let parallelogram = LayerTransform.parallelogramAffine(of: rect, onto: quad)
            else { return .unrenderable }
            affine = parallelogram
        }
        guard let placement = doc.describedTransformPlacement(idx, affine) else {
            return .unrenderable
        }
        guard placement.isCommittable else {
            NSSound.beep()
            return .refused
        }
        guard let composed = doc.transformingDescribedLayer(
            idx, affine, placement: placement, sampler: sampler)
        else { return .unrenderable }
        document.applyEdit("Transform Layer") { _ in composed }
        return .committed
    }
}
