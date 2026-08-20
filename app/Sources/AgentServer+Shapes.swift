import AppKit

/// add_shape_layer: the agent mirror of the shape tools (R) —
/// EditorViewController+Shapes.commitShapeLayer — so a layer made either
/// way is identical: pixels rendered by ShapeLayer.render, the description
/// in the layer's meta, the position in the layer's offset (which is what
/// lets Move keep the description honest).
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
        let int32Min = Double(Int32.min)
        let int32Max = Double(Int32.max)
        guard x >= int32Min, x <= int32Max, y >= int32Min, y <= int32Max else {
            throw ToolError(
                message: "x and y must land within the coordinates the core can address; "
                    + "keep the shape near the canvas.")
        }
        // Per-kind size floors, the ones ShapeLayer.render enforces: an
        // axis-aligned line legitimately has a zero dimension.
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

        let fill = try shapePaint(a, "fill")
        let stroke = try shapePaint(a, "stroke")
        let strokeWidth = doubleArg(a, "stroke_width") ?? 2
        guard strokeWidth.isFinite, strokeWidth >= 0, strokeWidth <= 200 else {
            throw ToolError(message: "stroke_width must be between 0 and 200 px")
        }
        let radius = doubleArg(a, "radius") ?? 0
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
        // A stroke of width 0 puts no ink down, so it does not count as a
        // paint; refusing here names the fix instead of failing the render.
        guard fill != nil || (stroke != nil && strokeWidth > 0) else {
            throw ToolError(
                message: "Pass at least one visible paint: fill, and/or stroke with a "
                    + "stroke_width above 0 (hex colors, #RRGGBB or #RRGGBBAA).")
        }

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
