import AppKit

extension AgentServer.DroppedDescription {
    /// The report's name for the kind a layer's meta claims — what
    /// `performPixelEdit` drops, decodable or not (DescribedLayer.swift,
    /// `LayerDescription.claimedKind`).
    init(_ kind: DescribedKind) {
        switch kind {
        case .text: self = .text
        case .shape: self = .shape
        case .livePhoto: self = .livePhoto
        }
    }
}

/// The agent's Free Transform commits, affine and perspective, on plain and
/// described layers: distort_layer (the mirror of ⌘-dragging a Free
/// Transform corner — the layer's rect mapped corner-for-corner onto an
/// explicit quad, committed through the same perspective op the interactive
/// session uses, so identical corners give identical pixels; a
/// PARALLELOGRAM quad is the exact affine it denotes and, on a described
/// layer, composes like transform_layer) and the described-layer compose
/// path transform_layer (AgentServer.swift) takes first — the mirror of
/// EditorViewController+DescribedTransform.swift's commit, the branch
/// commitTransformSession takes for a plain affine session on a text,
/// shape or Live Photo layer.
extension AgentServer {
    /// transform_layer on a DESCRIBED layer: composes `matrix` into the
    /// description and re-renders (RasterDocument.transformingDescribedLayer)
    /// as one undo step, reporting `rasterized: false` with the new bounds,
    /// transform and origin. FALL-THROUGH contract: returns nil — and never
    /// throws for a refusal — whenever it did not compose (no description,
    /// a source that cannot render right now, a singular composed map, a
    /// raster past the core's cap); the caller then runs the rasterizing
    /// path, which reports as before. `try` covers only the result's JSON
    /// serialization.
    func transformDescribedLayer(
        _ document: ImageDocument, layer index: Int, matrix: CGAffineTransform,
        sampler: (name: String, filter: RzResizeFilter), applied: [String: Any]
    ) throws -> String? {
        guard let doc = document.doc,
              let composed = doc.transformingDescribedLayer(
                index, matrix, sampler: sampler.filter)
        else { return nil }
        // Cannot throw for a refusal: `composed` is already the result.
        try performGroupedEdit(document, "Transform Layer") { _ in composed }
        let after = document.doc
        let info = after?.layerInfo(index)
        var result: [String: Any] = [
            "ok": true,
            "layer": index,
            // Where the layer landed: the outward-rounded box of the source
            // quad under the composed map, so a render can be checked
            // against it.
            "bounds": [
                "x": info?.offsetX ?? 0, "y": info?.offsetY ?? 0,
                "width": info?.width ?? 0, "height": info?.height ?? 0,
            ],
            "applied": applied,
            "rasterized": false,
            "note": "The layer stays re-editable: its description absorbed the transform.",
        ]
        // The transform and origin read back from the committed document —
        // what get_document will report.
        if let description = after?.layerDescription(index) {
            result["transform"] = description.transform.array
        }
        if let origin = after?.describedAnchor(index) {
            result["origin"] = ["x": Double(origin.x), "y": Double(origin.y)]
        }
        return try jsonResult(result)
    }

    /// Why a transform on a described layer had to rasterize, when it was
    /// because the description could not render right now (a text family
    /// not installed here, a Live Photo whose source will not decode) or
    /// because the pixels are not its rendering any more (an earlier
    /// version's Image Size resampled them, `describedRasterIsStale`) —
    /// appended to the rasterization note, so the model learns the layer
    /// was not resampled on a whim. nil for a plain layer, a shape that
    /// could render, or a description that could render over its own
    /// raster — then the compose path was refused for a reason the note
    /// already words (a singular map, a raster past the cap) or the quad
    /// was a true perspective.
    static func unrenderableReason(
        _ document: ImageDocument, layer idx: Int, before doc: RasterDocument
    ) -> String? {
        guard let description = doc.layerDescription(idx) else { return nil }
        guard !description.isRenderable else {
            guard doc.describedRasterIsStale(idx) else { return nil }
            return "It rasterized because its pixels were no longer the rendering of its "
                + "description (an earlier version's Image Size resampled them while the "
                + "description kept its original size), so composing into the description "
                + "would have re-rendered the layer at a size nobody saw."
        }
        switch description {
        case let .text(payload):
            return "It rasterized because its font family “\(payload.font)” is not installed "
                + "here, so re-rendering it would have substituted a face."
        case .shape:
            return nil
        case let .livePhoto(payload):
            return "It rasterized because the source its frame is drawn from cannot be "
                + "decoded right now (\(payload.renderSource) — moved, deleted or damaged)."
        }
    }

    /// Maps layer's rect onto four canvas corners in ONE resample. Mirrors
    /// the UI's ⌘-corner Free Transform drag: same core op, same refusal
    /// surface (pre-named here so the model can self-correct), one undo
    /// step, and — like transform_layer — adjustment layers are allowed:
    /// moving their mask footprint is meaningful. A PARALLELOGRAM quad on a
    /// described layer is the exact affine it denotes and composes into the
    /// description like transform_layer (`rasterized: false`, the layer
    /// stays re-editable); a true perspective quad — or a description that
    /// cannot render right now — resamples the pixels and drops the
    /// description silently in the same edit, reported with the reason.
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

        let applied: [String: Any] = [
            "corners": corners.map {
                [Self.transformNumber(Double($0.x)), Self.transformNumber(Double($0.y))]
            },
            "sampler": sampler.name,
        ]
        // A parallelogram on a described layer composes as the exact affine
        // it is — the same compose-or-fall-through rule as transform_layer:
        // nil means it did not compose (a plain layer needs no Swift-side
        // help, since the core's perspective op already delegates a
        // parallelogram to its lossless affine path; a description that
        // cannot render, a singular map or a core refusal fall through) and
        // the rasterizing path below applies and reports as before.
        if Self.description(of: document, layer: index) != nil,
           let affine = LayerTransform.parallelogramAffine(of: rect, onto: corners),
           let composed = try transformDescribedLayer(
               document, layer: index, matrix: affine, sampler: sampler, applied: applied) {
            return composed
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
                "applied": applied,
            ], layer: index, rasterized: rasterized,
            reason: Self.unrenderableReason(document, layer: index, before: doc))
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
    /// twin of doubleArg, which only reads top-level keys. Shared with the
    /// `transform` argument parser (AgentServer+Text.swift).
    static func finiteNumber(_ value: Any) -> Double? {
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
