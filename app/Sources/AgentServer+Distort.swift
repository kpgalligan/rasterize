import AppKit

/// distort_layer: the agent mirror of ⌘-dragging a Free Transform corner —
/// the layer's rect mapped corner-for-corner onto an explicit quad
/// (perspective/distort), committed through the same perspective op the
/// interactive session uses, so identical corners give identical pixels.
extension AgentServer {
    /// Maps layer's rect onto four canvas corners in ONE resample. Mirrors
    /// the UI's ⌘-corner Free Transform drag: same core op, same refusal
    /// surface (pre-named here so the model can self-correct), one undo
    /// step, described-layer meta dropped silently in the same edit, and —
    /// like transform_layer — adjustment layers are allowed: moving their
    /// mask footprint is meaningful.
    func distortLayer(_ a: [String: Any]) throws -> String {
        let document = try target(a)
        let index = try paintLayerIndex(a, document)
        guard let doc = document.doc, let info = doc.layerInfo(index) else {
            throw ToolError(message: "Layer \(index) could not be read")
        }
        guard info.width > 0, info.height > 0 else {
            throw ToolError(
                message: "Layer \(index) (\"\(info.name)\") has no pixels to distort.")
        }
        let rect = CGRect(
            x: CGFloat(info.offsetX), y: CGFloat(info.offsetY),
            width: CGFloat(info.width), height: CGFloat(info.height))
        let corners = try cornerPoints(a)

        let samplerName = (stringArg(a, "sampler") ?? "bicubic").lowercased()
        guard let sampler = Self.transformSamplers[samplerName] else {
            throw ToolError(
                message: "Unknown sampler \"\(samplerName)\". Use nearest, bilinear, "
                    + "bicubic, or lanczos.")
        }

        // The same live checks the interactive drag clamp enforces, named:
        // the core answers only NULL, so every refusal it would give is
        // diagnosed here first.
        let identity = zip(corners, LayerTransform.rectCorners(rect)).allSatisfy {
            abs($0.x - $1.x) <= LayerTransform.cornerEpsilon
                && abs($0.y - $1.y) <= LayerTransform.cornerEpsilon
        }
        guard !identity else {
            throw ToolError(
                message: "The corners match the layer's current rect — nothing to change.")
        }
        guard LayerTransform.isUsableQuad(corners) else {
            throw ToolError(
                message: "The corners must form a convex quad in the order top-left, "
                    + "top-right, bottom-right, bottom-left: a concave, self-crossing or "
                    + "collapsed arrangement folds the mapping and the core refuses it.")
        }
        let extent = LayerTransform.boundingExtent(of: corners)
        guard LayerTransform.extentIsCommittable(extent) else {
            throw ToolError(
                message: "The distorted layer would be \(Int(extent.width))×"
                    + "\(Int(extent.height)) px — collapsed, outside the coordinates the "
                    + "core can address, or past its 100 megapixel ceiling for one layer. "
                    + "Keep the corners nearer the canvas.")
        }

        let rasterized: DroppedDescription?
        do {
            rasterized = try performPixelEdit(document, "Distort Layer", pixelLayer: index) {
                doc in
                doc.perspectiveLayer(index, quad: corners, sampler: sampler.filter)
            }
        } catch is ToolError {
            throw ToolError(
                message: "The core refused this distortion: the quad is too close to "
                    + "degenerate. Move the corners apart and keep the quad convex.")
        }

        let after = document.doc?.layerInfo(index)
        return try pixelEditResult(
            [
                "ok": true,
                "layer": index,
                // Where the layer landed: the outward-rounded bounding box
                // of the corners, so a render can be checked against it.
                "bounds": [
                    "x": after?.offsetX ?? 0, "y": after?.offsetY ?? 0,
                    "width": after?.width ?? 0, "height": after?.height ?? 0,
                ],
                "applied": [
                    "corners": corners.map {
                        [Self.transformNumber(Double($0.x)), Self.transformNumber(Double($0.y))]
                    },
                    "sampler": sampler.name,
                ],
            ], layer: index, rasterized: rasterized)
    }

    /// The `corners` argument: four [x, y] pairs (numbers, or the string
    /// forms every argument helper accepts), in the source rect's corner
    /// order TL, TR, BR, BL.
    private func cornerPoints(_ a: [String: Any]) throws -> [CGPoint] {
        let usage =
            "corners must be four [x, y] canvas points — the destinations of the layer "
            + "rect's top-left, top-right, bottom-right and bottom-left corners, e.g. "
            + "[[0, 0], [80, 10], [75, 60], [5, 50]]."
        guard let raw = a["corners"] as? [Any], raw.count == 4 else {
            throw ToolError(message: usage)
        }
        return try raw.map { entry in
            guard let pair = entry as? [Any], pair.count == 2,
                  let x = Self.finiteNumber(pair[0]), let y = Self.finiteNumber(pair[1])
            else { throw ToolError(message: usage) }
            return CGPoint(x: x, y: y)
        }
    }

    /// A finite Double out of a JSON number or its string form — the nested
    /// twin of doubleArg, which only reads top-level keys.
    private static func finiteNumber(_ value: Any) -> Double? {
        let number: Double?
        if let d = value as? Double {
            number = d
        } else if let i = value as? Int {
            number = Double(i)
        } else if let s = value as? String {
            number = Double(s)
        } else {
            number = nil
        }
        guard let number, number.isFinite else { return nil }
        return number
    }
}
