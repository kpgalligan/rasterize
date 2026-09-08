import AppKit

// The Crop tool (C): an interactive box over the canvas with aspect
// presets, a thirds grid and straighten, committed with Return or a
// double-click. The box starts as the whole canvas; the commit is
// rz_doc_crop — which only moves the canvas window, so a plain crop is
// non-destructive — preceded, when straightening, by the same per-layer
// affine rotate Free Transform uses, about the box's center, applied to
// every layer and to every alpha channel.
//
// Session geometry lives in CropTool.swift; the canvas draws the overlay
// and routes the gesture here. Mirrored for the agent by the `crop` MCP
// tool (rect today, `angle` for straighten).
extension EditorViewController {
    /// Aspect presets, in the ratio popup's order. nil aspect = free;
    /// "Original" resolves to the document's own aspect at use time.
    static let cropRatios: [(title: String, aspect: Double?)] = [
        ("Original", nil), ("Free", nil), ("1 : 1", 1),
        ("4 : 3", 4.0 / 3), ("3 : 2", 1.5), ("16 : 9", 16.0 / 9),
    ]

    /// Entering the crop tool: the box opens over the whole canvas.
    func beginCropSession() {
        guard let doc = document?.doc else { return }
        var session = CropSession(
            rect: CGRect(x: 0, y: 0, width: CGFloat(doc.width), height: CGFloat(doc.height)))
        session.ratio = currentCropAspect()
        cropSession = session
        pushCropOverlay()
    }

    /// Leaving the tool (or a canceled commit): the box just goes away —
    /// the document was never touched.
    func endCropSession() {
        cropSession = nil
        canvas.cropOverlay = nil
    }

    /// Escape: back to the full canvas, angle zeroed.
    func resetCropSession() {
        guard cropSession != nil else { return }
        beginCropSession()
        optionsBar.refreshValues()
    }

    /// The active ratio preset as an aspect (width / height); "Original"
    /// reads the document, "Free" is nil.
    private func currentCropAspect() -> Double? {
        let index = min(max(ToolOptionsStore.shared.crop.ratioIndex, 0),
                        Self.cropRatios.count - 1)
        if index == 0, let doc = document?.doc, doc.height > 0 {
            return Double(doc.width) / Double(doc.height)
        }
        return Self.cropRatios[index].aspect
    }

    private func pushCropOverlay() {
        guard let session = cropSession else {
            canvas.cropOverlay = nil
            return
        }
        canvas.cropOverlay = CropOverlay(
            rect: session.rect,
            angle: CGFloat(session.angle),
            showsThirds: ToolOptionsStore.shared.crop.gridIndex == 1)
    }

    // MARK: - Gesture

    func cropMouseDown(_ point: CGPoint) {
        guard var session = cropSession else { return }
        let slop = ImageCanvasView.transformHandleSize / canvas.magnification
        if let handle = CropSession.handleIndex(at: point, rect: session.rect, slop: slop) {
            session.drag = .handle(handle, start: session.rect)
        } else if session.rect.contains(point) {
            session.drag = .move(grab: point, start: session.rect)
        } else {
            session.drag = .draw(anchor: point)
        }
        cropSession = session
    }

    /// `modifiers` carries ⌃, which suspends snapping for this tick — read
    /// per tick, never latched, so it can be pressed and released mid-drag.
    ///
    /// The snap goes on the POINT, ahead of `resizing` and `clamped`, for
    /// `.handle` and `.draw` — so that chain runs unchanged and
    /// "snap → re-derive → clamp" falls out for free. `.move`'s point is a
    /// grab OFFSET, so it takes the delta form instead
    /// (`DragSnapping.snapCropPoint` / `snapCropDelta`).
    func cropMouseDragged(_ point: CGPoint, _ modifiers: NSEvent.ModifierFlags) {
        guard var session = cropSession, let drag = session.drag,
              let doc = document?.doc else { return }
        let canvasSize = CGSize(width: CGFloat(doc.width), height: CGFloat(doc.height))
        switch drag {
        case let .handle(index, start):
            // The POINT, before `resizing` — never `session.rect` after it.
            // `resizing` takes a point plus a handle index and cannot be
            // re-run from a rect, so a rect snapped here would have already
            // been through the ratio derivation and the canvas clamp, and
            // snapping it would break the very aspect ratio the ordering
            // rule protects.
            let snapped = snapCropPoint(point, drag: drag, modifiers: modifiers)
            session.rect = CropSession.clamped(
                CropSession.resizing(start, handle: index, to: snapped, ratio: session.ratio),
                to: canvasSize, ratio: session.ratio)
        case let .move(grab, start):
            // The point here is a grab OFFSET inside the box, not the moved
            // geometry, so what snaps is the DELTA against the press-time
            // box. `clamped` still has the final word, exactly as before.
            let delta = snapCropDelta(
                from: start, by: CGVector(dx: point.x - grab.x, dy: point.y - grab.y),
                modifiers: modifiers)
            session.rect = CropSession.clamped(
                start.offsetBy(dx: delta.dx, dy: delta.dy), to: canvasSize)
        case let .draw(anchor):
            // BOTH corners snap, and the fixed one is snapped on every tick
            // rather than at mouse-down: `onCropMouseDown` carries no
            // modifier flags, so an anchor snapped there could not be
            // suspended with ⌃ — and the anchor does not move, so its own
            // pull is the same answer on every tick.
            let corner = snapCropPoint(anchor, drag: drag, modifiers: modifiers)
            let moved = snapCropPoint(point, drag: drag, modifiers: modifiers)
            var rect = CGRect(
                x: min(corner.x, moved.x), y: min(corner.y, moved.y),
                width: max(abs(moved.x - corner.x), 1), height: max(abs(moved.y - corner.y), 1))
            if let ratio = session.ratio, ratio > 0 {
                let height = rect.width / CGFloat(ratio)
                // The re-derived height grows away from the ANCHOR: an
                // upward drag keeps the anchor as the bottom edge.
                if moved.y < corner.y {
                    rect.origin.y = corner.y - height
                }
                rect.size.height = height
            }
            session.rect = CropSession.clamped(rect, to: canvasSize, ratio: session.ratio)
        }
        cropSession = session
        pushCropOverlay()
        optionsBar.refreshValues()
    }

    func cropMouseUp(_ point: CGPoint) {
        cropSession?.drag = nil
    }

    // MARK: - Commit

    /// Return / double-click: straighten (a rotate about the box's center,
    /// over every layer and every alpha channel) then crop, as ONE undo
    /// step. A full-canvas box at angle 0 is a no-op and just keeps the
    /// session.
    func commitCropSession() {
        guard let session = cropSession, let document = document, let doc = document.doc
        else { return }
        // Round each edge rather than .integral (which rounds OUTWARD and
        // could commit one pixel more than the W/H fields displayed).
        let rounded = CGRect(
            x: session.rect.minX.rounded(), y: session.rect.minY.rounded(),
            width: session.rect.width.rounded(), height: session.rect.height.rounded())
        let rect = rounded.intersection(
            CGRect(x: 0, y: 0, width: CGFloat(doc.width), height: CGFloat(doc.height)))
        guard rect.width >= 1, rect.height >= 1 else {
            NSSound.beep()
            return
        }
        let angle = session.angle
        let fullCanvas = rect == CGRect(x: 0, y: 0, width: doc.width, height: doc.height)
        guard !fullCanvas || angle != 0 else { return }

        // Straightening resamples every layer, which rewrites the pixels a
        // described layer was rendered from: ask once, then drop those
        // descriptions inside the same edit. A plain crop only moves the
        // canvas window and keeps every description valid.
        var describedLayers: [Int] = []
        if angle != 0 {
            describedLayers = (0..<doc.layerCount).filter { document.layerDescribesSource($0) }
            if !describedLayers.isEmpty, !confirmStraightenRasterize(count: describedLayers.count) {
                return
            }
        }

        let sampler = transformSampler
        let before = document.doc
        document.applyEdit("Crop") { doc in
            var current: RasterDocument? = doc
            if angle != 0 {
                // The preview rotated the image by −angle about the box
                // center; the commit is the identical matrix per layer.
                let center = CGPoint(x: rect.midX, y: rect.midY)
                let matrix = CGAffineTransform(translationX: center.x, y: center.y)
                    .rotated(by: CGFloat(-angle) * .pi / 180)
                    .translatedBy(x: -center.x, y: -center.y)
                // ONE core call over the whole stack rather than a host loop,
                // exactly as the agent's crop does. A GROUP entry has no
                // pixels to resample — what follows the matrix is its
                // CANVAS-sized mask, which rides the channel path — and the
                // single-layer transform refuses a group outright, so a loop
                // would nil the entire straighten the moment the document
                // held one. It is also all-or-nothing, which a half-rotated
                // stack never is.
                //
                // `straightenLayers`, not `transformLayers` over every index:
                // that call is all-or-nothing under per-entry POSITION locks,
                // so one locked layer refused the whole crop with nothing but
                // a beep — after the user had already agreed to rasterize.
                // Straightening re-frames the picture rather than moving a
                // layer within it, which is why `cropped` beside it consults
                // no lock either.
                current = current?.straightenLayers(matrix, sampler: sampler)
                // The alpha channels are saved selections OF this picture, so
                // they ride the same matrix inside the same edit — otherwise
                // every one of them silently stops lining up with what it was
                // saved from. A document with no channels answers nil, hence
                // the fallthrough.
                current = current?.transformingChannels(matrix, sampler: sampler) ?? current
                for idx in describedLayers {
                    current = current?.withLayerMeta(idx, nil) ?? current
                }
            }
            // A full-canvas box means straighten-only: the core refuses a
            // crop that changes nothing, so chaining it would nil out the
            // whole edit.
            guard !fullCanvas else { return current }
            return current?.cropped(
                x: Int(rect.minX), y: Int(rect.minY),
                w: Int(rect.width), h: Int(rect.height))
        }
        guard document.doc !== before else { return }
        // The canvas is a new size; reopen the box over all of it.
        beginCropSession()
        optionsBar.refreshValues()
    }

    private func confirmStraightenRasterize(count: Int) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Rasterize described layers?"
        alert.informativeText =
            "Straightening rotates every layer's pixels, so \(count) layer\(count == 1 ? "" : "s") "
            + "will no longer be editable as text, shape or Live Photo. "
            + "The pixels themselves are kept."
        alert.addButton(withTitle: "Rasterize")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - Options bar bindings

    var cropRectWidth: Double {
        get { Double(cropSession?.rect.width ?? 0) }
        set {
            guard var session = cropSession, let doc = document?.doc, newValue >= 1 else { return }
            var rect = session.rect
            rect.size.width = CGFloat(newValue)
            if let ratio = session.ratio, ratio > 0 {
                rect.size.height = rect.width / CGFloat(ratio)
            }
            session.rect = CropSession.clamped(
                rect, to: CGSize(width: CGFloat(doc.width), height: CGFloat(doc.height)),
                ratio: session.ratio)
            cropSession = session
            pushCropOverlay()
        }
    }

    var cropRectHeight: Double {
        get { Double(cropSession?.rect.height ?? 0) }
        set {
            guard var session = cropSession, let doc = document?.doc, newValue >= 1 else { return }
            var rect = session.rect
            rect.size.height = CGFloat(newValue)
            if let ratio = session.ratio, ratio > 0 {
                rect.size.width = rect.height * CGFloat(ratio)
            }
            session.rect = CropSession.clamped(
                rect, to: CGSize(width: CGFloat(doc.width), height: CGFloat(doc.height)),
                ratio: session.ratio)
            cropSession = session
            pushCropOverlay()
        }
    }

    var cropStraightenDegrees: Double {
        get { cropSession?.angle ?? 0 }
        set {
            guard cropSession != nil else { return }
            cropSession?.angle = min(max(newValue, -45), 45)
            pushCropOverlay()
        }
    }

    /// The ratio popup changed: re-constrain the current box to it.
    func cropRatioChanged() {
        guard var session = cropSession, let doc = document?.doc else { return }
        session.ratio = currentCropAspect()
        if let ratio = session.ratio, ratio > 0 {
            var rect = session.rect
            rect.size.height = rect.width / CGFloat(ratio)
            session.rect = CropSession.clamped(
                rect, to: CGSize(width: CGFloat(doc.width), height: CGFloat(doc.height)),
                ratio: session.ratio)
        }
        cropSession = session
        pushCropOverlay()
        optionsBar.refreshValues()
    }

    /// The grid popup changed: redraw the overlay with/without thirds.
    func cropGridChanged() {
        pushCropOverlay()
    }
}
