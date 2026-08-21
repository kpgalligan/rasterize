import AppKit

/// add_shape_layer and edit_shape_layer: the agent mirrors of the shape
/// tools (R) — EditorViewController+Shapes' commitShapeLayer and the
/// layers panel's double-click re-edit session — so a layer made or
/// re-rendered either way is identical: pixels rendered by
/// ShapeLayer.render, the description in the layer's meta, the position in
/// the layer's offset (which is what lets Move keep the description
/// honest).
extension AgentServer {
    /// Adds a re-editable shape layer above the active layer and selects
    /// it: the same payload → render → add-fill-move-describe chain the
    /// shape tools' commit runs, as one undo step.
    func addShapeLayer(_ a: [String: Any]) throws -> String {
        let document = try target(a)
        guard document.doc != nil else { throw ToolError(message: "Document has no image") }
        let kind = try requiredString(a, "kind")
        guard ShapeLayerPayload.kinds.contains(kind) else {
            throw ToolError(message: "kind must be rect, ellipse, or line (got \"\(kind)\")")
        }
        guard let x = doubleArg(a, "x"), let y = doubleArg(a, "y"),
            let w = doubleArg(a, "w"), let h = doubleArg(a, "h"),
            x.isFinite, y.isFinite, w.isFinite, h.isFinite
        else {
            throw ToolError(
                message: "add_shape_layer requires x, y (the shape box's top-left corner in "
                    + "canvas px) and w, h (the box size), all finite numbers")
        }
        try Self.validateShapeGeometry(kind: kind, x: x, y: y, w: w, h: h)

        let fill = try shapePaint(a, "fill")
        let stroke = try shapePaint(a, "stroke")
        let strokeWidth = doubleArg(a, "stroke_width") ?? 2
        let radius = doubleArg(a, "radius") ?? 0
        try Self.validateShapeStyle(
            kind: kind, fill: fill, stroke: stroke, strokeWidth: strokeWidth, radius: radius)

        let payload = ShapeLayerPayload(
            kind: kind, w: w, h: h, flipped: boolArg(a, "flipped") ?? false,
            fill: fill, stroke: stroke, strokeWidth: strokeWidth, radius: radius)
        guard let raster = ShapeLayer.render(payload), let meta = payload.json() else {
            throw ToolError(
                message: "Could not render the shape — the box is degenerate for the kind, "
                    + "nothing would be visible, or the raster would pass the core's 100 "
                    + "megapixel ceiling for one layer. Check w, h and stroke_width.")
        }
        let name = ShapeLayer.layerName(for: payload)
        // The shape box lands with its top-left at (x, y): the raster
        // carries `padding` px of stroke-overhang slack on every side, so
        // the layer's offset backs up by exactly that much —
        // commitShapeLayer's rule.
        let offsetX = Int(floor(x)) - raster.padding
        let offsetY = Int(floor(y)) - raster.padding

        let below = document.activeLayerIndex
        try performGroupedEdit(document, "Add \(name) Layer") { doc in
            let idx = below + 1
            guard let added = doc.addingLayer(above: below, name: name),
                let filled = added.withLayerPixels(
                    idx, rgba: raster.pixels, width: raster.width, height: raster.height),
                let moved = filled.withLayerOffset(idx, offsetX, offsetY)
            else { return nil }
            return moved.withLayerMeta(idx, meta)
        }
        let index = min(below + 1, (document.doc?.layerCount ?? 1) - 1)
        document.activeLayerIndex = index
        // The edit's own notification went out before the active layer
        // moved, so the panel and status bar need this one to catch up.
        NotificationCenter.default.post(
            name: .imageDocumentImageDidChange, object: document, userInfo: ["isLive": false])
        return try jsonResult(["ok": true, "layer": index, "name": name])
    }

    /// Re-renders an existing shape layer from a changed description — the
    /// agent mirror of the layers panel's double-click re-edit session
    /// (EditorViewController+Shapes.commitShapeEditSession): pixels, offset
    /// and meta replaced as one undo step. Omitted arguments keep the
    /// layer's current values; the kind is fixed at creation.
    func editShapeLayer(_ a: [String: Any]) throws -> String {
        let document = try target(a)
        let index = try paintLayerIndex(a, document)
        guard let doc = document.doc else { throw ToolError(message: "Document has no image") }
        guard let info = doc.layerInfo(index) else {
            throw ToolError(message: "Layer \(index) could not be read")
        }
        guard let current = doc.shapePayload(index) else {
            throw ToolError(
                message: "Layer \(index) (\"\(info.name)\") is not a shape layer — it is "
                    + "plain pixels with no description to re-render (get_document reports "
                    + "a \"shape\" object on the layers that have one). Make a re-editable "
                    + "shape with add_shape_layer.")
        }
        let kind = current.kind
        // Geometry: x/y name the shape box's top-left; the current one is
        // recovered from offset + padding (the commit's offset rule,
        // inverted — editShapeLayer's box on the UI side).
        let oldPad = ShapeLayer.padding(for: current)
        let x = doubleArg(a, "x") ?? Double(info.offsetX + oldPad)
        let y = doubleArg(a, "y") ?? Double(info.offsetY + oldPad)
        let w = doubleArg(a, "w") ?? current.w
        let h = doubleArg(a, "h") ?? current.h
        guard x.isFinite, y.isFinite, w.isFinite, h.isFinite else {
            throw ToolError(message: "x, y, w and h must be finite numbers")
        }
        try Self.validateShapeGeometry(kind: kind, x: x, y: y, w: w, h: h)

        // Paints: an ABSENT argument keeps the layer's paint; a present
        // empty string removes it ("" is the payload's own "none"). The
        // gate demands an actual string so JSON null or a mistyped value
        // reads as "keep" (the documented default), never as a silent
        // removal.
        let fill = a["fill"] is String ? try shapePaint(a, "fill") : current.fillColor
        let stroke = a["stroke"] is String ? try shapePaint(a, "stroke") : current.strokeColor
        let strokeWidth = doubleArg(a, "stroke_width") ?? current.strokeWidth
        let radius = doubleArg(a, "radius") ?? current.radius
        try Self.validateShapeStyle(
            kind: kind, fill: fill, stroke: stroke, strokeWidth: strokeWidth, radius: radius)

        let payload = ShapeLayerPayload(
            kind: kind, w: w, h: h, flipped: boolArg(a, "flipped") ?? current.flipped,
            fill: fill, stroke: stroke, strokeWidth: strokeWidth, radius: radius)
        guard let raster = ShapeLayer.render(payload), let meta = payload.json() else {
            throw ToolError(
                message: "Could not render the shape — the box is degenerate for the kind, "
                    + "nothing would be visible, or the raster would pass the core's 100 "
                    + "megapixel ceiling for one layer. Check w, h and stroke_width.")
        }
        let offsetX = Int(floor(x)) - raster.padding
        let offsetY = Int(floor(y)) - raster.padding
        try performGroupedEdit(document, "Edit Shape Layer") { doc in
            guard let filled = doc.withLayerPixels(
                    index, rgba: raster.pixels, width: raster.width, height: raster.height),
                let moved = filled.withLayerOffset(index, offsetX, offsetY)
            else { return nil }
            return moved.withLayerMeta(index, meta)
        }
        var shape: [String: Any] = [
            "kind": kind, "x": Self.transformNumber(x), "y": Self.transformNumber(y),
            "w": Self.transformNumber(w), "h": Self.transformNumber(h),
            "fill": payload.fill, "stroke": payload.stroke,
            "stroke_width": Self.transformNumber(strokeWidth),
        ]
        if kind == "rect" { shape["radius"] = Self.transformNumber(payload.radius) }
        if kind == "line" { shape["flipped"] = payload.flipped }
        return try jsonResult(["ok": true, "layer": index, "shape": shape])
    }

    /// The geometry rules both shape tools share: coordinates the core can
    /// address, and ShapeLayer.render's per-kind size floors (an
    /// axis-aligned line legitimately has a zero dimension).
    private static func validateShapeGeometry(
        kind: String, x: Double, y: Double, w: Double, h: Double
    ) throws {
        let int32Min = Double(Int32.min)
        let int32Max = Double(Int32.max)
        guard x >= int32Min, x <= int32Max, y >= int32Min, y <= int32Max else {
            throw ToolError(
                message: "x and y must land within the coordinates the core can address; "
                    + "keep the shape near the canvas.")
        }
        if kind == "line" {
            guard w >= 0, h >= 0, max(w, h) >= 1 else {
                throw ToolError(
                    message: "A line's box needs w and h of at least 0 px with at least one "
                        + "axis of 1 px or more (an axis-aligned line has a zero dimension).")
            }
        } else {
            guard w >= 1, h >= 1 else {
                throw ToolError(message: "\(kind) needs w and h of at least 1 px")
            }
        }
    }

    /// The style rules both shape tools share: ranges, the line's
    /// stroke-only nature, and "at least one visible paint" (a stroke of
    /// width 0 puts no ink down, so it does not count — refusing here names
    /// the fix instead of failing the render).
    private static func validateShapeStyle(
        kind: String, fill: NSColor?, stroke: NSColor?, strokeWidth: Double, radius: Double
    ) throws {
        guard strokeWidth.isFinite, strokeWidth >= 0, strokeWidth <= 200 else {
            throw ToolError(message: "stroke_width must be between 0 and 200 px")
        }
        guard radius.isFinite, radius >= 0 else {
            throw ToolError(message: "radius must be a non-negative number of px")
        }
        if kind == "line" {
            guard stroke != nil else {
                throw ToolError(
                    message: "A line is stroke-only — pass stroke (fill is ignored).")
            }
            guard strokeWidth >= 1 else {
                throw ToolError(message: "A line needs a stroke_width of at least 1 px")
            }
        }
        guard fill != nil || (stroke != nil && strokeWidth > 0) else {
            throw ToolError(
                message: "Pass at least one visible paint: fill, and/or stroke with a "
                    + "stroke_width above 0 (hex colors, #RRGGBB or #RRGGBBAA).")
        }
    }

    /// The `fill` / `stroke` arguments: a parsed hex paint, or nil when the
    /// caller passed nothing or the empty string — "no paint", never black.
    private func shapePaint(_ a: [String: Any], _ key: String) throws -> NSColor? {
        guard let hex = stringArg(a, key)?.trimmingCharacters(in: .whitespaces),
            !hex.isEmpty
        else { return nil }
        guard let color = TextLayer.color(fromHex: hex) else {
            throw ToolError(
                message: "\(key) must be a hex color like #RRGGBB or #RRGGBBAA "
                    + "(got \"\(hex)\")")
        }
        return color
    }
}
