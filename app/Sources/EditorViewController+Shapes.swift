import AppKit

// The shape tools (R): drag out a rectangle, ellipse or line and it lands
// as a new parametric layer — pixels rendered by ShapeLayer, description
// in the layer's meta, position in the layer's offset (so Move keeps the
// description honest). Double-clicking a shape layer in the layers panel
// reopens that description as an editable box (ShapeEditSession below).
// Mirrored for the agent by `add_shape_layer` and `edit_shape_layer`.
extension EditorViewController {
    /// The canvas's drag committed: build the payload from the options
    /// bar's style and add the layer above the active one — the same
    /// add-fill-move-describe chain a text commit uses.
    func commitShapeLayer(box: CGRect, flipped: Bool) {
        guard let document = document, let doc = document.doc else { return }
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
        guard let raster = ShapeLayer.render(payload), let meta = payload.json() else {
            NSSound.beep()
            return
        }
        let name = ShapeLayer.layerName(for: payload)
        let offsetX = Int(floor(box.minX)) - raster.padding
        let offsetY = Int(floor(box.minY)) - raster.padding

        let below = document.activeLayerIndex
        let before = document.doc
        document.applyEdit("Add \(name) Layer") { doc in
            let idx = below + 1
            guard let added = doc.addingLayer(above: below, name: name),
                  let filled = added.withLayerPixels(
                    idx, rgba: raster.pixels, width: raster.width, height: raster.height),
                  let moved = filled.withLayerOffset(idx, offsetX, offsetY)
            else { return nil }
            return moved.withLayerMeta(idx, meta)
        }
        guard document.doc !== before else { return }
        setActiveLayer(min(below + 1, document.doc.layerCount - 1))
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
    /// an open edit session goes dirty and redraws with the new style.
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
    /// and interior drags adjust the box; Return, a double-click, a click
    /// away, a tool switch or Quick Mask commits; Escape cancels.
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
        guard let doc = document.doc, let info = doc.layerInfo(idx),
              let payload = doc.shapePayload(idx)
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
        // The layer's offset plus the render padding recovers the shape
        // box's top-left — the commit's offset rule, inverted.
        let pad = CGFloat(ShapeLayer.padding(for: payload))
        shapeEditSession = ShapeEditSession(
            layer: idx, kind: payload.kind,
            box: CGRect(
                x: CGFloat(info.offsetX) + pad, y: CGFloat(info.offsetY) + pad,
                width: CGFloat(payload.w), height: CGFloat(payload.h)),
            flipped: payload.flipped)
        // Hide the layer's raster under the session, or the old shape
        // ghosts behind every adjustment — the text session's rule. An
        // already-hidden layer has nothing to hide (nil is correct).
        canvas.previewImage = doc.withLayerVisible(idx, false)?.flattened()?.makeCGImage()
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
            kind: Self.shapeTool(for: session.kind), box: session.box,
            flipped: session.flipped, style: canvas.shapeStyle)
    }

    // MARK: - Re-edit gesture

    func shapeEditMouseDown(_ point: CGPoint) {
        guard var session = shapeEditSession else { return }
        let slop = ImageCanvasView.transformHandleSize / canvas.magnification
        if let handle = CropSession.handleIndex(at: point, rect: session.box, slop: slop) {
            session.drag = .handle(handle, start: session.box)
            session.pressPoint = point
            shapeEditSession = session
        } else if session.box.insetBy(dx: -slop, dy: -slop).contains(point) {
            // The inset keeps a hairline box grabbable — an axis-aligned
            // line's box legitimately has a zero dimension.
            session.drag = .move(grab: point, start: session.box)
            session.pressPoint = point
            shapeEditSession = session
        } else {
            // Clicking away commits, and only commits — the text session's
            // click-through rule (no new shape starts from this click).
            commitShapeEditSession()
        }
    }

    func shapeEditMouseDragged(_ point: CGPoint) {
        guard var session = shapeEditSession, let drag = session.drag else { return }
        // Sub-2-screen-point movement is a click, not a drag — the same
        // misclick threshold the other canvas gestures apply. Without it,
        // trackpad jitter inside a double-click would dirty the session
        // and commit a phantom edit.
        if !session.dirty, let press = session.pressPoint,
           hypot(point.x - press.x, point.y - press.y) * canvas.magnification < 2 {
            return
        }
        switch drag {
        case let .handle(index, start):
            // No canvas clamp, unlike the crop box: a shape may extend past
            // the canvas edge (only its on-canvas pixels composite).
            var box = CropSession.resizing(start, handle: index, to: point, ratio: nil)
            // A degenerate axis is legitimate for a line: resizing's 1 px
            // floor would bend an axis-aligned line, so restore the axis
            // an edge-handle drag never moved.
            if session.kind == "line" {
                if start.height == 0, index == 5 || index == 7 {
                    box.origin.y = start.origin.y
                    box.size.height = 0
                }
                if start.width == 0, index == 4 || index == 6 {
                    box.origin.x = start.origin.x
                    box.size.width = 0
                }
            }
            session.box = box
        case let .move(grab, start):
            session.box = start.offsetBy(dx: point.x - grab.x, dy: point.y - grab.y)
        }
        session.dirty = true
        shapeEditSession = session
        pushShapeEditOverlay()
    }

    // MARK: - Re-edit commit

    /// Return, a double-click, a click away, a tool switch or Quick Mask:
    /// re-render the layer from the session's box and the options bar's
    /// style — pixels, offset and description in ONE undo step. An
    /// untouched session just closes; a style that renders nothing (fill
    /// and stroke both gone) refuses rather than commit an empty raster.
    func commitShapeEditSession() {
        guard let session = shapeEditSession, let document = document,
              let doc = document.doc
        else {
            endShapeEditSession()
            return
        }
        endShapeEditSession()
        guard session.dirty else { return }
        // The style the OVERLAY drew with — this window's canvas style,
        // not the app-global store, which another window's bar may have
        // changed since: what was previewed is what commits.
        let style = canvas.shapeStyle
        let payload = ShapeLayerPayload(
            kind: session.kind,
            w: Double(session.box.width), h: Double(session.box.height),
            flipped: session.flipped,
            fill: style.fill,
            stroke: style.stroke,
            strokeWidth: Double(style.strokeWidth),
            radius: Double(style.radius))
        guard let raster = ShapeLayer.render(payload), let meta = payload.json() else {
            NSSound.beep()
            return
        }
        let idx = session.layer
        let offsetX = Int(floor(session.box.minX)) - raster.padding
        let offsetY = Int(floor(session.box.minY)) - raster.padding
        // Reopened and put back exactly as it was (dragged away and back,
        // a style nudged and reverted): no edit, no undo step — the text
        // commit's rule, on values rather than the intent flag.
        if let info = doc.layerInfo(idx), doc.shapePayload(idx) == payload,
           info.offsetX == offsetX, info.offsetY == offsetY {
            return
        }
        document.applyEdit("Edit Shape Layer") { doc in
            guard let filled = doc.withLayerPixels(
                    idx, rgba: raster.pixels, width: raster.width, height: raster.height),
                  let moved = filled.withLayerOffset(idx, offsetX, offsetY)
            else { return nil }
            return moved.withLayerMeta(idx, meta)
        }
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
