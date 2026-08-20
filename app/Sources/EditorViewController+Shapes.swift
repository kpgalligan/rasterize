import AppKit

// The shape tools (R): drag out a rectangle, ellipse or line and it lands
// as a new parametric layer — pixels rendered by ShapeLayer, description
// in the layer's meta, position in the layer's offset (so Move keeps the
// description honest). Mirrored for the agent by `add_shape_layer`.
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
}
