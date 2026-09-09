import AppKit

// The shape tools (R): drag out a rectangle, ellipse or line and it lands
// as a new parametric layer — pixels rendered by ShapeLayer through the
// layer's transform, description in the layer's meta, position in the
// layer's offset (the anchor rule in DescribedLayer.swift, so Move keeps
// the description honest). Double-clicking a shape layer in the layers
// panel reopens that description as an editable box (ShapeEditSession
// below). Mirrored for the agent by `add_shape_layer` and `edit_shape_layer`.
//
// RE-EDITING UNDER A MAP. A transformed shape reopens with its handles on
// the placed quad, and every re-box happens in the shape's OWN space: the
// pointer is inverse-mapped through the layer's 2×2 map, the local box
// resizes exactly as an axis-aligned one would, and the anchor is
// renormalized so the un-dragged corner stays pinned on the canvas — a
// rotated rectangle therefore grows along its own axes. The overlay draws
// the local path under the same placement the renderer uses, stroke
// width scaling with the map, so what is previewed is what commits.
extension EditorViewController {
    /// The canvas's drag committed: build the payload from the options
    /// bar's style and add the layer above the active one — the same
    /// addingDescribedLayer op a text commit uses.
    func commitShapeLayer(box: CGRect, flipped: Bool) {
        guard let document = document, document.doc != nil else { return }
        let kind: String
        switch currentTool {
        case .shapeEllipse: kind = "ellipse"
        case .shapeLine: kind = "line"
        default: kind = "rect"
        }
        let options = ToolOptionsStore.shared.shape
        let payload = ShapeLayerPayload(
            kind: kind,
            w: Double(box.width), h: Double(box.height),
            flipped: flipped,
            fill: TextLayer.color(fromHex: options.fill),
            stroke: TextLayer.color(fromHex: options.stroke),
            strokeWidth: options.strokeWidth,
            radius: options.radius)
        let name = ShapeLayer.layerName(for: payload)
        // The box's top-left lands on whole pixels (a new shape is never
        // transformed) — the placement rule every interactive commit follows.
        let anchor = DescribedLayer.placementAnchor(box.origin, transform: .identity)

        let below = document.activeLayerIndex
        let before = document.doc
        // Where the new entry lands is the CORE's answer: above a GROUP it
        // goes above the whole subtree, so `below + 1` would select the
        // wrong row (§4.5's one definition).
        let landing = before?.insertionIndex(above: below) ?? below + 1
        document.applyEdit(
            "Add \(name) Layer", record: .addShapeLayer(payload, at: anchor)
        ) {
            $0.addingDescribedLayer(above: below, .shape(payload), anchor: anchor, name: name)
        }
        guard document.doc !== before else { return }
        setActiveLayer(min(landing, document.doc.layerCount - 1))
    }

    /// The options bar's shape style, resolved for the canvas preview.
    func syncCanvasShapeStyle() {
        let options = ToolOptionsStore.shared.shape
        canvas.shapeStyle = ShapeToolStyle(
            fill: TextLayer.color(fromHex: options.fill),
            stroke: TextLayer.color(fromHex: options.stroke),
            strokeWidth: CGFloat(min(max(options.strokeWidth, 0), 200)),
            radius: CGFloat(min(max(options.radius, 0), 500)))
    }

    /// A shape option changed in the bar: the canvas preview follows, and
    /// an open edit session goes dirty and redraws with the new style —
    /// under the same placement, which is what the commit will render.
    func shapeStyleEdited() {
        syncCanvasShapeStyle()
        if shapeEditSession != nil {
            shapeEditSession?.dirty = true
            pushShapeEditOverlay()
        }
    }

    // MARK: - Re-editing (the layers panel's double-click)

    /// Double-clicking a SHAPE layer in the layers panel: switch to the
    /// matching shape tool and reopen the layer's description as an
    /// editable box — editTextLayer's shape-layer sibling. The options bar
    /// takes over the layer's own fill, stroke, weight and radius; handle
    /// and interior drags adjust the box in the shape's own space; Return,
    /// a double-click, a click away, a tool switch or Quick Mask commits;
    /// Escape cancels.
    func editShapeLayer(_ idx: Int) {
        guard let document = document, document.doc?.shapePayload(idx) != nil else {
            NSSound.beep()
            return
        }
        // A gesture landing with a session already open only commits it —
        // the text rule: `idx` could be stale after any commit. An open
        // TEXT session's commit may even insert a layer and renumber
        // everything above it, so it too only commits.
        if shapeEditSession != nil {
            commitShapeEditSession()
            return
        }
        if canvas.hasActiveTextSession {
            canvas.commitTextSession()
            return
        }
        guard let kind = document.doc?.shapePayload(idx)?.kind else { return }
        selectTool(Self.shapeTool(for: kind))
        // Re-read AFTER selectTool: it commits a pending Free Transform,
        // which replaces the document — and can even rasterize this very
        // layer, dropping the payload (then there is nothing to reopen).
        guard let doc = document.doc, let payload = doc.shapePayload(idx),
              let anchor = doc.describedAnchor(idx)
        else {
            NSSound.beep()
            return
        }
        // Editing a layer makes it the active one (the commit replaces its
        // content, and the panel should show what is being edited).
        if document.activeLayerIndex != idx {
            setActiveLayer(idx)
        }
        // The bar reflects what is being edited; edits there re-render on
        // commit (applyTextOptions' role for a reopened text layer).
        ToolOptionsStore.shared.shape.fill = payload.fill
        ToolOptionsStore.shared.shape.stroke = payload.stroke
        ToolOptionsStore.shared.shape.strokeWidth = payload.strokeWidth
        ToolOptionsStore.shared.shape.radius = payload.radius
        syncCanvasShapeStyle()
        optionsBar.refreshValues()
        // The layer's anchor IS the shape box's top-left — the commit's
        // placement rule, inverted (DescribedLayer.swift) — and the
        // session keeps it EXACT: a transformed shape's anchor is
        // fractional, and rounding it here would shift the reopened quad
        // off the layer's pixels and register a phantom edit on commit.
        shapeEditSession = ShapeEditSession(
            layer: idx, kind: payload.kind,
            anchor: anchor, openedAnchor: anchor,
            size: CGSize(width: CGFloat(payload.w), height: CGFloat(payload.h)),
            transform: payload.transform,
            flipped: payload.flipped)
        // Hide the layer's raster under the session, or the old shape
        // ghosts behind every adjustment — the text session's rule. An
        // already-hidden layer has nothing to hide (nil is correct).
        canvas.previewImage = doc.withLayerVisible(idx, false)?.flattened()?
            .makeCGImage(in: doc.colorSpace)
        pushShapeEditOverlay()
    }

    /// The shape tool a payload kind reopens with.
    static func shapeTool(for kind: String) -> EditorTool {
        switch kind {
        case "ellipse": return .shapeEllipse
        case "line": return .shapeLine
        default: return .shapeRect
        }
    }

    private func pushShapeEditOverlay() {
        guard let session = shapeEditSession else {
            canvas.shapeEditOverlay = nil
            return
        }
        canvas.shapeEditOverlay = ShapeToolPreview(
            kind: Self.shapeTool(for: session.kind), box: session.localBox,
            placement: session.placement, flipped: session.flipped, style: canvas.shapeStyle)
    }

    // MARK: - Re-edit gesture

    func shapeEditMouseDown(_ point: CGPoint) {
        guard var session = shapeEditSession else { return }
        let slop = ImageCanvasView.transformHandleSize / canvas.magnification
        let quad = session.quad
        if let handle = Self.shapeHandleIndex(at: point, quad: quad, slop: slop) {
            session.drag = .handle(handle, start: (session.anchor, session.size))
            session.pressPoint = point
            shapeEditSession = session
        } else if Self.quadGrabs(point, quad: quad, slop: slop) {
            session.drag = .move(grab: point, start: session.anchor)
            session.pressPoint = point
            shapeEditSession = session
        } else {
            // Clicking away commits, and only commits — the text session's
            // click-through rule (no new shape starts from this click).
            commitShapeEditSession()
        }
    }

    /// Which of the placed quad's eight handles a press at `point` grabs,
    /// within `slop` canvas px on each axis (the Free Transform box's
    /// square test) — nil for none. Index order is `CropSession.handles`'.
    static func shapeHandleIndex(at point: CGPoint, quad: [CGPoint], slop: CGFloat) -> Int? {
        for (index, handle) in ImageCanvasView.transformHandlePoints(quad).enumerated()
        where abs(point.x - handle.x) <= slop && abs(point.y - handle.y) <= slop {
            return index
        }
        return nil
    }

    /// Whether a press at `point` grabs the quad's interior: inside the
    /// polygon, or within `slop` canvas px of one of its edges. The edge
    /// margin is what keeps a hairline box grabbable — an axis-aligned
    /// line's box legitimately has a zero dimension, so its quad has no
    /// interior at all — and it is measured on the CANVAS rather than as an
    /// inset of the local box mapped through the placement, so the margin
    /// is the same handful of screen pixels whatever the map (a local inset
    /// would stretch to dozens of pixels along a scaled-up axis and vanish
    /// along a scaled-down one).
    static func quadGrabs(_ point: CGPoint, quad: [CGPoint], slop: CGFloat) -> Bool {
        guard quad.count == 4 else { return false }
        let polygon = NSBezierPath()
        polygon.move(to: quad[0])
        for corner in quad.dropFirst() {
            polygon.line(to: corner)
        }
        polygon.close()
        if polygon.contains(point) { return true }
        for index in 0..<4
        where distance(from: point, toSegment: quad[index], quad[(index + 1) % 4]) <= slop {
            return true
        }
        return false
    }

    /// Euclidean distance from `p` to the segment `a`–`b` (to `a` when the
    /// segment is a point).
    private static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        var t: CGFloat = 0
        if lengthSquared > 0 {
            t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared
            t = min(max(t, 0), 1)
        }
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    /// `modifiers` carries ⌃, which suspends snapping for this tick — read
    /// per tick, never latched, so it can be pressed and released mid-drag.
    ///
    /// The snap goes on the canvas point, before the inverse map — guides are
    /// canvas objects and the local box is derived from the canvas point —
    /// and a HANDLE is restricted exactly like a transform handle, to an
    /// identity placement (`DragSnapping.snapShapeEditPoint`, which carries
    /// the argument).
    func shapeEditMouseDragged(_ rawPoint: CGPoint, _ modifiers: NSEvent.ModifierFlags) {
        guard var session = shapeEditSession, let drag = session.drag else { return }
        // Sub-2-screen-point movement is a click, not a drag — the same
        // misclick threshold the other canvas gestures apply. Without it,
        // trackpad jitter inside a double-click would dirty the session
        // and commit a phantom edit. Measured on the RAW point: a snap can
        // move a coordinate by a whole pull radius, and a click that landed
        // beside a guide would otherwise cross the threshold on its own and
        // dirty the session nobody dragged.
        if !session.dirty, let press = session.pressPoint,
           hypot(rawPoint.x - press.x, rawPoint.y - press.y) * canvas.magnification < 2 {
            return
        }
        let point = snapShapeEditPoint(rawPoint, drag: drag, modifiers)
        switch drag {
        case let .handle(index, start):
            // The pointer goes into the shape's own space (relative to the
            // anchor, through the inverse map), where the box is still
            // axis-aligned and CropSession.resizing applies unchanged. No
            // canvas clamp, unlike the crop box: a shape may extend past
            // the canvas edge (only its on-canvas pixels composite). The
            // map is invertible by decode's contract; a session could only
            // lose that to a document change, which ends it first.
            guard let inverse = session.transform.inverted() else { return }
            let local = inverse.apply(
                CGPoint(x: point.x - start.anchor.x, y: point.y - start.anchor.y))
            var box = CropSession.resizing(
                CGRect(origin: .zero, size: start.size), handle: index, to: local, ratio: nil)
            // A degenerate axis is legitimate for a line: resizing's 1 px
            // floor would bend an axis-aligned line, so restore the axis
            // an edge-handle drag never moved (in local space, where the
            // axis is still an axis).
            if session.kind == "line" {
                if start.size.height == 0, index == 5 || index == 7 {
                    box.origin.y = 0
                    box.size.height = 0
                }
                if start.size.width == 0, index == 4 || index == 6 {
                    box.origin.x = 0
                    box.size.width = 0
                }
            }
            // Renormalize: the local box's origin moved when a top/left
            // handle was dragged (or a drag crossed the opposite edge), so
            // the anchor shifts by the MAPPED origin and the local box goes
            // back to (0, 0) — the un-dragged corner stays exactly where it
            // was on the canvas.
            let shift = session.transform.apply(box.origin)
            session.anchor = CGPoint(x: start.anchor.x + shift.x, y: start.anchor.y + shift.y)
            session.size = box.size
        case let .move(grab, start):
            // A move is a canvas-space translation of the anchor: the map
            // and the local box are untouched (Move-tool semantics).
            session.anchor = CGPoint(x: start.x + point.x - grab.x, y: start.y + point.y - grab.y)
        }
        session.dirty = true
        shapeEditSession = session
        pushShapeEditOverlay()
    }

    // MARK: - Re-edit commit

    /// Return, a double-click, a click away, a tool switch or Quick Mask:
    /// re-render the layer from the session's box, through the layer's
    /// own map, with the options bar's style — pixels, offset, description
    /// and the re-cropped mask in ONE undo step. An untouched session just
    /// closes; a style that renders nothing (fill and stroke both gone)
    /// refuses rather than commit an empty raster.
    func commitShapeEditSession() {
        guard let session = shapeEditSession, let document = document,
              let doc = document.doc
        else {
            endShapeEditSession()
            return
        }
        endShapeEditSession()
        guard session.dirty else { return }
        let idx = session.layer
        // The session cannot change the map — only a Free Transform does —
        // so the layer's own transform re-attaches to the edited box.
        let old = doc.shapePayload(idx)
        let transform = session.transform
        // The style the OVERLAY drew with — this window's canvas style,
        // not the app-global store, which another window's bar may have
        // changed since: what was previewed is what commits.
        let style = canvas.shapeStyle
        let payload = ShapeLayerPayload(
            kind: session.kind,
            w: Double(session.size.width), h: Double(session.size.height),
            flipped: session.flipped,
            fill: style.fill,
            stroke: style.stroke,
            strokeWidth: Double(style.strokeWidth),
            radius: Double(style.radius),
            transform: transform)
        // The layer's own EXACT anchor unless a drag moved it — a restyle
        // from the bar must not nudge the shape by the half pixel the
        // whole-pixel rule would round a fraction left by a Free Transform
        // (nor demote it to version 1); a drag's delta lands on whole pixels
        // for an untransformed shape and exactly under a map (a re-box on a
        // rotated shape keeps its un-dragged corner pinned exactly).
        let anchor = DescribedLayer.placementAnchor(
            from: session.openedAnchor, to: session.anchor, transform: transform)
        // Reopened and put back exactly as it was (dragged away and back,
        // a style nudged and reverted): no edit, no undo step — the text
        // commit's rule, on values rather than the intent flag. The
        // session's payload carries fraction [0, 0] by construction; the
        // anchor comparison covers the fraction.
        if let old = old, old.withOriginFraction(.zero) == payload,
           doc.describedAnchor(idx) == anchor {
            return
        }
        // A re-render REWRITES the layer's pixels, so it answers to the same
        // locks every other pixel path does; without it the core refused and
        // `applyEdit` beeped with nothing said.
        guard !refuseLockedEdit(layer: idx, kind: RZ_EDIT_PIXELS) else { return }
        let beforeEdit = document.doc
        document.applyEdit(
            "Edit Shape Layer",
            record: .editShapeLayer(
                payload, at: anchor, layerNamed: doc.layerInfo(idx)?.name)
        ) {
            $0.rerenderingDescribedLayer(idx, .shape(payload), anchor: anchor)
        }
        // A TRANSPARENCY lock refuses a re-layout that resizes the raster, and
        // only then — named here, after the fact, instead of a bare beep.
        if document.doc === beforeEdit { refuseLockedRerender(layer: idx) }
    }

    /// Escape: the layer never changed; the box just goes away.
    func cancelShapeEditSession() {
        endShapeEditSession()
    }

    /// Clears the session, its overlay and the hidden-layer preview.
    func endShapeEditSession() {
        shapeEditSession = nil
        canvas.shapeEditOverlay = nil
        canvas.previewImage = nil
    }
}
