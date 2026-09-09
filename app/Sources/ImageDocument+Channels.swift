import AppKit

/// The ONE generic hook that routes a destructive filter or an adjustment
/// onto a single plane: `applyToActiveLayer` asks `applyToTargetPlane`
/// first, and when a colour plane or an alpha channel is the edit target
/// the same op runs on that plane alone — extract it as an opaque grayscale
/// image, run the op, take the result's Rec. 709 luma, write it back. No
/// per-filter code anywhere.
///
/// The same round trip is what fill and gradient use
/// (`EditorViewController+PlanePaint`), through `applyPlaneScratchEdit`:
/// the plane becomes a one-layer document, the EXISTING
/// `bucketFilled`/`gradiented` runs on it, and its luma comes back as the
/// new plane. That is the whole reason this feature adds no region grow, no
/// gradient and no filter code of its own.
///
/// Both routes read and write a colour plane in the LAYER's own space
/// (`PlanePlacement`) and an alpha channel in canvas space — one pair, so
/// no plane edit can leave an oversized layer's off-canvas ring behind.
///
/// "Take the result's gray" is DEFINED as the result's Rec. 709 luma
/// (`RasterImage.lumaPlane`). For the gray image an op was handed luma is
/// the identity, so a filter that stays gray round-trips byte for byte; an
/// op that un-grays it (a sepia, a hue rotate) reduces the one honest way.
extension ImageDocument {
    // MARK: - The filter and adjustment hook

    /// Returns false when the target is `.layer` or `.mask` — the caller
    /// runs its normal whole-layer path. A `.mask` target deliberately
    /// keeps today's behaviour: filters run on the layer's pixels, and
    /// changing that is out of scope for this phase.
    ///
    /// A nil result from `op` (or a write the core refuses because no byte
    /// would change) beeps and mints no undo step, exactly as `applyEdit`'s
    /// own nil path does — but it still returns true, because the target
    /// WAS a plane: falling back to the whole-layer path would silently
    /// paint the colour image the user did not aim at.
    func applyToTargetPlane(
        _ actionName: String, record: [ActionStep], _ op: (RasterImage) -> RasterImage?
    ) -> Bool {
        let target = planeEditTarget
        guard target.targetsPlaneOrChannel else { return false }
        applyPlaneRewrite(actionName, target, record: record) { current in
            guard let source = targetPlaneSource(current, target),
                  let filtered = op(source.image), let bytes = filtered.lumaPlane()
            else { return nil }
            return writingPlaneResult(current, target, source.placement, bytes)
        }
        return true
    }

    /// The write-back for a plane result that came out of the target's OWN
    /// space — a filter, an adjustment, a fill or a gradient alike.
    ///
    /// A colour plane's result is LAYER-SIZED (`targetPlaneSource` read it
    /// that way), and it is written back in LAYER space — every sample the op
    /// ran over, the part of an oversized layer that hangs off the canvas
    /// included. Routing it through a canvas-sized buffer instead would
    /// rewrite that one plane only inside the canvas and leave the ring at
    /// its old values, which the next Canvas Size or Move turns into a
    /// colour seam. An alpha channel carries no placement: it is canvas-sized
    /// document state and takes the ordinary writer.
    private func writingPlaneResult(
        _ doc: RasterDocument, _ target: PaintTarget, _ placement: PlanePlacement?,
        _ bytes: [UInt8]
    ) -> RasterDocument? {
        guard let placement = placement else {
            guard case .channel(let index) = target else { return nil }
            return doc.settingChannelData(index, bytes)
        }
        guard case .plane(let plane) = target else { return nil }
        return doc.withLayerSpacePlane(
            activeLayerIndex, plane.rz, bytes,
            width: placement.width, height: placement.height)
    }

    /// The plane an op runs on, plus where it sits — the reader every plane
    /// route shares.
    ///
    /// A colour plane is read at the LAYER's own size (`PlanePlacement` says
    /// why: a neighbourhood filter must see the layer's own pixels at its
    /// border, not the zeros a canvas-sized read puts outside the layer's
    /// rect, and a contiguous fill must not grow through those zeros). An
    /// alpha channel is canvas-sized document state and carries no
    /// placement. nil for `.layer` and `.mask`.
    func targetPlaneSource(
        _ doc: RasterDocument, _ target: PaintTarget
    ) -> (image: RasterImage, placement: PlanePlacement?)? {
        switch target {
        case .layer, .mask:
            return nil
        case .plane(let plane):
            guard let read = doc.layerSpacePlaneImage(activeLayerIndex, plane.rz) else {
                return nil
            }
            return (read.image, read.placement)
        case .channel(let index):
            guard let image = doc.channelImage(index, maxSide: 0) else { return nil }
            return (image, nil)
        }
    }

    // MARK: - The plane round trip

    /// Fill or gradient on a plane target, committed as ONE undo step: the
    /// target plane becomes a one-layer scratch document IN ITS OWN SPACE,
    /// `op` runs the existing `bucketFilled`/`gradiented` on it with the
    /// canvas geometry and `mask` mapped into that space (`PlaneScratchOp`),
    /// and the result's luma is written back the same way — layer space for
    /// a colour plane, canvas space for an alpha channel.
    ///
    /// A nil anywhere (an unreadable plane, a seed outside it, a write the
    /// core refuses because no byte would change) beeps and mints no undo
    /// step, exactly as `applyEdit`'s own nil path does.
    func applyPlaneScratchEdit(
        _ actionName: String, _ target: PaintTarget, _ op: PlaneScratchOp, mask: [UInt8]?,
        record: [ActionStep]
    ) {
        applyPlaneRewrite(actionName, target, record: record) { current in
            guard let source = targetPlaneSource(current, target) else { return nil }
            let placement = source.placement
            guard let bytes = RasterDocument.planeThroughScratch(source.image, { scratch in
                op.run(scratch, in: placement, mask: mask)
            }) else { return nil }
            return writingPlaneResult(current, target, placement, bytes)
        }
    }

    /// The entry point a plane edit belongs in, chosen once:
    /// `applyRasterizingEdit` for a colour plane — writing it rewrites the
    /// layer's pixels, so it contradicts a text/shape/Live-Photo description
    /// exactly as a brush stroke does — and `applyEdit` for a channel, which
    /// is document state and describes nothing.
    func applyPlaneRewrite(
        _ actionName: String, _ target: PaintTarget, record: [ActionStep],
        _ rewrite: (RasterDocument) -> RasterDocument?
    ) {
        switch target {
        case .plane:
            applyRasterizingEdit(actionName, layer: activeLayerIndex, record: record, rewrite)
        case .channel:
            applyEdit(actionName, record: record, rewrite)
        case .layer, .mask:
            // Not a plane target: the caller asked for something this path
            // cannot do, so refuse rather than edit the wrong pixels.
            NSSound.beep()
        }
    }

    // MARK: - Live preview

    /// The plane a live preview must run on, captured on the MAIN thread
    /// before a PreviewRenderer closure goes to its background queue. nil
    /// when the target is `.layer` or `.mask` — the caller previews its
    /// normal way.
    ///
    /// The capture reads ONE layer (or one channel) and never re-composites,
    /// so it costs a canvas-sized plane and its grayscale image per request
    /// — the price of running the op itself, not of a projection — and the
    /// sheets ask for it once per slider tick, before their debounce.
    func targetPlanePreview() -> PlanePreview? {
        let target = planeEditTarget
        guard target.targetsPlaneOrChannel, let doc = doc,
              let source = targetPlaneSource(doc, target)
        else { return nil }
        return PlanePreview(base: source.image, placement: source.placement)
    }
}

/// A captured plane plus the recipe for showing an op's result on it. The
/// handles are immutable, exactly like the baseDoc/baseLayer the sheets'
/// existing preview closures capture, so running the op on
/// PreviewRenderer's background queue is safe.
struct PlanePreview {
    /// The target plane as an opaque grayscale image — the op's input. For a
    /// colour plane it is the layer's own size, which is what the commit
    /// filters too.
    let base: RasterImage
    /// Where `base` sits on the canvas, for a colour plane; nil for an alpha
    /// channel, which is canvas-sized already.
    let placement: PlanePlacement?

    /// `op(base)` as the grayscale CGImage the canvas draws while a plane
    /// or a channel is on display (ChannelDisplay.drawBase draws
    /// `previewImage ?? base`).
    ///
    /// The result goes through the SAME "take the result's gray" reduction
    /// the commit does — `RZ_PLANE_LUMA` — so a sheet previews byte for
    /// byte what its Apply will write, even for an op that un-grays its
    /// input. For a result that is already gray that read is the identity,
    /// so it costs one image copy and nothing else.
    ///
    /// NOTE: for a `.plane` target this is the ACTIVE LAYER's plane, while
    /// the canvas's own base is the COMPOSITE's — identical on the
    /// single-layer documents this is used on, an approximation elsewhere,
    /// which is the same display-vs-edit split the whole feature carries.
    func preview(_ op: (RasterImage) -> RasterImage?) -> CGImage? {
        guard let result = op(base) else { return nil }
        guard let placement = placement else {
            return result.planeImage(RZ_PLANE_LUMA, maxSide: 0)?.makeCGImage(in: ColorProfile.sRGB)
        }
        // A layer-space result is expanded onto the canvas to be DRAWN: the
        // canvas can only show canvas pixels, and 0 outside the layer's rect
        // is what a canvas-sized read of that plane shows there anyway. The
        // commit writes the same bytes in layer space (`writingPlaneResult`),
        // so everything on screen here is byte for byte what Apply lands —
        // plus the off-canvas ring, which nothing can show.
        guard let bytes = result.lumaPlane(),
              let canvas = placement.canvasPlane(from: bytes)
        else { return nil }
        return CanvasSelection.grayImage(canvas, placement.canvasWidth, placement.canvasHeight)
    }
}
