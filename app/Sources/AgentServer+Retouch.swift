import AppKit

/// The retouch strokes and the straightening crop: the agent mirrors of the
/// Clone Stamp tool, the Dodge / Burn tool, and the Crop tool (straighten
/// included). The stroke handlers rasterize the same canvas-sized
/// premultiplied overlay the interactive stroke pipeline builds and hand it
/// to the same core ops, so identical inputs give identical pixels.
extension AgentServer {

    // MARK: - Shared stroke rasterization

    /// Builds a canvas-sized premultiplied RGBA8 overlay (row 0 = top,
    /// top-left-origin drawing — paintOverlay's exact context), clips it to
    /// the live selection the way every interactive stroke does, lets `draw`
    /// fill it, and hands the bytes to `commit` inside performPixelEdit —
    /// the pixel-rewrite chokepoint that silently drops a described layer's
    /// meta and reports it.
    private func retouchOverlay(
        _ document: ImageDocument, layer: Int, actionName: String,
        draw: (CGContext) -> Void,
        commit: (RasterDocument, UnsafePointer<UInt8>, Int, Int) -> RasterDocument?
    ) throws -> DroppedDescription? {
        guard let doc = document.doc else { throw ToolError(message: "Document has no image") }
        let width = doc.width
        let height = doc.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        return try performPixelEdit(document, actionName, pixelLayer: layer) { current in
            data.withUnsafeMutableBufferPointer { buffer -> RasterDocument? in
                guard let base = buffer.baseAddress,
                    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                    let context = CGContext(
                        data: base, width: width, height: height, bitsPerComponent: 8,
                        bytesPerRow: width * 4, space: colorSpace,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { return nil }
                context.translateBy(x: 0, y: CGFloat(height))
                context.scaleBy(x: 1, y: -1)
                // Strokes confine to the active selection, exactly like the
                // interactive tools.
                if let selection = editor(document)?.agentSelection {
                    selection.clip(context)
                }
                draw(context)
                return commit(current, base, width, height)
            }
        }
    }

    /// The stroke tools' optional `hardness` argument, 0–100, returned as
    /// the 0–1 fraction SoftBrush speaks; default 1 (the classic hard
    /// round). Internal: paint_stroke shares it.
    func strokeHardness(_ a: [String: Any]) throws -> CGFloat {
        let raw = doubleArg(a, "hardness") ?? 100
        guard raw.isFinite, raw >= 0, raw <= 100 else {
            throw ToolError(message: "hardness must be between 0 and 100 (percent)")
        }
        return CGFloat(raw / 100)
    }

    /// The stroke tools' shared tip arguments — hardness plus `flow`
    /// (1–100%, per-dab deposit), `spacing` (1–200% of the diameter),
    /// `angle` (degrees, counter-clockwise) and `roundness` (1–100%) —
    /// resolved to the fractions SoftBrush speaks. The defaults are the
    /// classic tip, whose strokes render exactly as they did before the
    /// tip options existed. Internal: all four stroke tools share it.
    func strokeTip(_ a: [String: Any]) throws -> BrushTip {
        let flow = doubleArg(a, "flow") ?? 100
        guard flow.isFinite, flow >= 1, flow <= 100 else {
            throw ToolError(message: "flow must be between 1 and 100 (percent)")
        }
        let spacing = doubleArg(a, "spacing") ?? Double(BrushTip.defaultSpacingPercent)
        guard spacing.isFinite, spacing >= 1, spacing <= 200 else {
            throw ToolError(
                message: "spacing must be between 1 and 200 (percent of the brush diameter)")
        }
        let angle = doubleArg(a, "angle") ?? 0
        guard angle.isFinite, angle >= -180, angle <= 180 else {
            throw ToolError(message: "angle must be between -180 and 180 (degrees)")
        }
        let roundness = doubleArg(a, "roundness") ?? 100
        guard roundness.isFinite, roundness >= 1, roundness <= 100 else {
            throw ToolError(message: "roundness must be between 1 and 100 (percent)")
        }
        return BrushTip(
            hardness: try strokeHardness(a), flow: CGFloat(flow / 100),
            spacingPercent: CGFloat(spacing), angleDegrees: CGFloat(angle),
            roundness: CGFloat(roundness / 100))
    }

    /// The optional `blend_mode` argument: a blend-mode display name,
    /// matched case-insensitively against the layer set (the exact
    /// vocabulary set_layer_properties speaks), nil when absent. Internal:
    /// brush_stroke, clone_stamp and set_layer_properties share it.
    func blendModeArg(_ a: [String: Any]) throws -> RzBlendMode? {
        guard let name = stringArg(a, "blend_mode") else { return nil }
        guard let mode = RzBlendMode.allBlendModes.first(where: {
            $0.1.caseInsensitiveCompare(name) == .orderedSame
        })?.0
        else {
            let names = RzBlendMode.allBlendModes.map { $0.1 }.joined(separator: ", ")
            throw ToolError(message: "Unknown blend mode \"\(name)\". One of: \(names)")
        }
        return mode
    }

    /// The stroke's coverage: the round-capped, round-joined outline of the
    /// polyline through `points`, `size` px wide — the same geometry a
    /// brush stroke paints. A single point gets an epsilon segment so it
    /// strokes as a round dot instead of an empty path.
    private static func strokeCoverage(points: [CGPoint], size: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.move(to: points[0])
        if points.count == 1 {
            path.addLine(to: CGPoint(x: points[0].x + 0.01, y: points[0].y))
        } else {
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
        }
        return path.copy(
            strokingWithWidth: size, lineCap: .round, lineJoin: .round, miterLimit: 10)
    }

    // MARK: - Clone stamp

    /// clone_stamp — mirrors the Clone Stamp tool: a snapshot of the CURRENT
    /// flattened composite, displaced by (first point − source), is painted
    /// onto the layer through the stroke's round coverage, so the pixel
    /// landing at p is the composite's p − offset — the classic aligned-clone
    /// rule the canvas's stampCloneDab stamps dab by dab.
    func cloneStamp(_ a: [String: Any]) throws -> String {
        let document = try target(a)
        let index = try paintLayerIndex(a, document)
        // The UI refuses clone strokes on an adjustment layer outright
        // (onStrokeBegin): there are no pixels to rewrite.
        try rejectAdjustmentPixelEdit(document, index)
        guard let sourceX = doubleArg(a, "source_x"), let sourceY = doubleArg(a, "source_y"),
            sourceX.isFinite, sourceY.isFinite
        else {
            throw ToolError(
                message: "clone_stamp requires source_x and source_y — the canvas point the "
                    + "pixels are cloned FROM (the stroke's first point paints what sits "
                    + "there).")
        }
        let points = try parsePoints(a)
        let rawSize = doubleArg(a, "size") ?? 24
        let rawOpacity = doubleArg(a, "opacity") ?? 1
        guard rawSize.isFinite, rawOpacity.isFinite else {
            throw ToolError(message: "size and opacity must be finite numbers")
        }
        let size = CGFloat(min(max(rawSize, 1), 200))
        let opacity = min(max(rawOpacity, 0), 1)
        let tip = try strokeTip(a)
        let blend = try blendModeArg(a)
        guard let doc = document.doc else { throw ToolError(message: "Document has no image") }
        let canvasHeight = doc.height
        // The snapshot is latched before the edit, like the interactive
        // stroke's mouse-down latch: nothing can change what is being
        // cloned mid-stroke.
        guard let snapshot = (document.projection ?? doc.flattened())?.makeCGImage() else {
            throw ToolError(message: "Could not snapshot the composite to clone from")
        }
        let offset = CGVector(dx: points[0].x - sourceX, dy: points[0].y - sourceY)

        let rasterized: DroppedDescription?
        // Latched when the PAINT OP ITSELF answers nil, so only that case
        // gets the friendlier message — any other failure stays an error.
        var opRefused = false
        do {
            rasterized = try retouchOverlay(
                document, layer: index, actionName: "Clone Stamp",
                draw: { context in
                    // The un-flip inside: the overlay context is flipped
                    // (row 0 = top), so the snapshot flips back locally to
                    // land right side up at the displaced position —
                    // stampCloneDab's rule.
                    let drawSnapshot: (CGContext) -> Void = { context in
                        context.translateBy(x: 0, y: CGFloat(canvasHeight))
                        context.scaleBy(x: 1, y: -1)
                        context.draw(
                            snapshot,
                            in: CGRect(
                                x: offset.dx, y: -offset.dy,
                                width: CGFloat(snapshot.width),
                                height: CGFloat(snapshot.height)))
                    }
                    // A non-default tip stamps the snapshot dab by dab —
                    // the canvas's stampCloneDab: the tip's footprint (gray
                    // falloff mask when soft, hard ellipse otherwise,
                    // squashed and rotated) clips, and each dab deposits at
                    // the tip's flow.
                    if SoftBrush.isStamped(tip: tip, size: size) {
                        let mask = SoftBrush.isSoft(hardness: tip.hardness, size: size)
                            ? SoftBrush.dabMask(diameter: size, hardness: tip.hardness)
                            : nil
                        let spacing = SoftBrush.spacing(
                            for: size, percent: tip.spacingPercent)
                        for center in SoftBrush.stampCenters(along: points, spacing: spacing) {
                            context.saveGState()
                            SoftBrush.clipDab(
                                in: context, at: center, diameter: size,
                                tip: tip, mask: mask)
                            if tip.flow < 0.995 { context.setAlpha(tip.flow) }
                            drawSnapshot(context)
                            context.restoreGState()
                        }
                        return
                    }
                    context.addPath(Self.strokeCoverage(points: points, size: size))
                    context.clip()
                    drawSnapshot(context)
                },
                commit: { current, base, w, h in
                    let out: RasterDocument?
                    if let blend = blend, blend != RZ_BLEND_NORMAL {
                        out = current.paintingLayerBlend(
                            index, overlay: base, w: w, h: h,
                            mode: blend, alpha: opacity)
                    } else {
                        out = current.paintingLayer(
                            index, overlay: base, w: w, h: h,
                            mode: RZ_COMPOSITE_OVER, alpha: opacity)
                    }
                    if out == nil { opRefused = true }
                    return out
                })
        } catch let error as ToolError {
            // The paint op answers nil when the stroke never touches the
            // layer's extent; name that instead of the generic edit failure.
            guard opRefused else { throw error }
            let blendCause = blend == nil
                ? ""
                : ", or blend mode \(RzBlendMode.displayName(for: blend ?? RZ_BLEND_NORMAL)) "
                    + "left every covered pixel exactly as it was (an identity blend, like "
                    + "multiplying white by white)"
            throw ToolError(
                message: "Clone Stamp changed nothing: the stroke never landed on layer "
                    + "\(index)'s pixels — its extent may not reach the points, the "
                    + "active selection clipped the whole stroke away\(blendCause).")
        }
        return try pixelEditResult(
            ["ok": true, "action": "Clone Stamp", "layer": index, "points": points.count],
            layer: index, rasterized: rasterized)
    }

    // MARK: - Dodge / burn

    /// dodge_burn — mirrors the Dodge / Burn tool: lightens (dodge) or
    /// darkens (burn) the layer's pixels where the stroke's coverage lands,
    /// weighted toward shadows, midtones or highlights — the same retouch op
    /// the interactive stroke drives, which reads only the overlay's alpha.
    func dodgeBurn(_ a: [String: Any]) throws -> String {
        let document = try target(a)
        let index = try paintLayerIndex(a, document)
        // The UI refuses dodge/burn strokes on an adjustment layer outright
        // (onStrokeBegin): there are no pixels to rewrite.
        try rejectAdjustmentPixelEdit(document, index)
        let points = try parsePoints(a)
        let rawSize = doubleArg(a, "size") ?? 24
        let rawExposure = doubleArg(a, "exposure") ?? 50
        guard rawSize.isFinite, rawExposure.isFinite else {
            throw ToolError(message: "size and exposure must be finite numbers")
        }
        let size = CGFloat(min(max(rawSize, 1), 200))
        let exposurePercent = min(max(rawExposure, 0), 100)
        let tip = try strokeTip(a)
        guard stringArg(a, "blend_mode") == nil else {
            throw ToolError(
                message: "dodge_burn has no blend_mode — it reshapes tones in place; "
                    + "blend modes apply to brush_stroke and clone_stamp.")
        }
        let burn = boolArg(a, "burn") ?? false
        let rangeName = stringArg(a, "range") ?? "midtones"
        let range: Int
        switch rangeName {
        case "shadows": range = 0
        case "midtones": range = 1
        case "highlights": range = 2
        case let other:
            throw ToolError(
                message: "range must be shadows, midtones, or highlights (got \"\(other)\")")
        }

        let rasterized: DroppedDescription?
        // Latched when the RETOUCH OP ITSELF answers nil, so only that case
        // reads as a no-op — any other failure stays an error.
        var opRefused = false
        do {
            rasterized = try retouchOverlay(
                document, layer: index, actionName: "Dodge / Burn",
                draw: { context in
                    // Pure coverage, like the interactive stroke: white —
                    // the exposure lives in the op, not the stroke. A
                    // non-default tip stamps white falloff dabs through the
                    // tip's footprint, each deposited at the tip's flow, so
                    // the coverage itself feathers and builds up.
                    let white = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
                    if SoftBrush.isStamped(tip: tip, size: size),
                        let dab = SoftBrush.dab(
                            color: white.withAlphaComponent(tip.flow),
                            diameter: size, hardness: tip.hardness) {
                        let spacing = SoftBrush.spacing(
                            for: size, percent: tip.spacingPercent)
                        for center in SoftBrush.stampCenters(along: points, spacing: spacing) {
                            SoftBrush.stamp(
                                dab, in: context, at: center, diameter: size, tip: tip)
                        }
                        return
                    }
                    context.setFillColor(white.cgColor)
                    context.addPath(Self.strokeCoverage(points: points, size: size))
                    context.fillPath()
                },
                commit: { current, base, w, h in
                    let out = current.dodgeBurnLayer(
                        index, overlay: base, w: w, h: h,
                        exposure: exposurePercent / 100, range: range, burn: burn)
                    if out == nil { opRefused = true }
                    return out
                })
        } catch let error as ToolError {
            // The op answers nil when nothing would change — the stroke
            // missed the layer, the selection clipped it away, or the
            // covered pixels are already at the end of their range. That is
            // a no-op, not a failure: no edit landed, no undo step opened.
            guard opRefused else { throw error }
            return try jsonResult([
                "ok": true, "changed": false, "layer": index,
                "note": "Nothing changed: the stroke never covered layer \(index)'s pixels, "
                    + "or the pixels under it are already fully "
                    + "\(burn ? "darkened" : "lightened"). No undo step was added.",
            ])
        }
        return try pixelEditResult(
            [
                "ok": true, "action": "Dodge / Burn", "layer": index,
                "points": points.count,
                "applied": [
                    "exposure": Self.transformNumber(exposurePercent),
                    "range": rangeName, "burn": burn,
                ],
            ], layer: index, rasterized: rasterized)
    }

    // MARK: - Crop (rect + straighten)

    /// crop — mirrors the Crop tool, straighten included: a nonzero `angle`
    /// first rotates EVERY layer, and every alpha channel, by −angle about
    /// the crop rect's center (the identical matrix
    /// EditorViewController+Crop.commitCropSession commits), then the canvas
    /// window moves to the rect — one undo step.
    /// Straightening resamples every layer's pixels, so described
    /// (text/shape/Live Photo) layers silently rasterize and the result
    /// reports which — the agent-side convention, since a modal prompt would
    /// block the MCP connection. A plain rect crop keeps every description
    /// valid.
    func crop(_ a: [String: Any]) throws -> String {
        let document = try target(a)
        guard let doc = document.doc else { throw ToolError(message: "Document has no image") }
        guard let x = intArg(a, "x"), let y = intArg(a, "y"),
            let w = intArg(a, "width"), let h = intArg(a, "height")
        else {
            throw ToolError(message: "crop requires x, y, width, height")
        }
        let angle = doubleArg(a, "angle") ?? 0
        guard angle.isFinite, abs(angle) <= 45 else {
            throw ToolError(message: "angle must be between -45 and 45 degrees")
        }
        guard angle != 0 else {
            // The plain rectangle crop: a canvas-window move only.
            try performGroupedEdit(document, "Crop") { $0.cropped(x: x, y: y, w: w, h: h) }
            return try jsonResult(["ok": true, "document": summary(document)])
        }
        // The layers whose descriptions the rotation's resample invalidates:
        // exactly the UI's layerDescribesSource set. Adjustment layers keep
        // their meta — it describes an op, not pixels, so rotation cannot
        // contradict it.
        let described = (0..<doc.layerCount).filter { document.layerDescribesSource($0) }
        // The identical matrix commitCropSession builds: rotate by −angle
        // about the crop rect's center.
        let center = CGPoint(x: Double(x) + Double(w) / 2, y: Double(y) + Double(h) / 2)
        let matrix = CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: CGFloat(-angle) * .pi / 180)
            .translatedBy(x: -center.x, y: -center.y)
        // A full-canvas rect means straighten-only: the core refuses a crop
        // that changes nothing, so chaining it would nil out the whole edit.
        let fullCanvas = x == 0 && y == 0 && w == doc.width && h == doc.height
        try performGroupedEdit(document, "Crop") { base in
            var current: RasterDocument? = base
            for idx in 0..<base.layerCount {
                current = current?.transformingLayer(
                    idx, matrix, sampler: RZ_FILTER_CATMULL_ROM)
            }
            // The channels ride the straighten too (the UI's commit does the
            // same): a saved selection that stayed put would no longer line
            // up with the picture it was saved from. nil = no channels.
            current = current?.transformingChannels(matrix, sampler: RZ_FILTER_CATMULL_ROM)
                ?? current
            for idx in described {
                current = current?.withLayerMeta(idx, nil) ?? current
            }
            guard !fullCanvas else { return current }
            return current?.cropped(x: x, y: y, w: w, h: h)
        }
        var result: [String: Any] = [
            "ok": true,
            "angle": Self.transformNumber(angle),
            "document": summary(document),
        ]
        if !described.isEmpty {
            let list = described.map(String.init).joined(separator: ", ")
            let plural = described.count == 1 ? "" : "s"
            result["rasterized_layers"] = described
            result["note"] =
                "Straightening rotated every layer's pixels, so layer\(plural) \(list) "
                + (described.count == 1 ? "is" : "are")
                + " no longer editable as text, shape or Live Photo: the descriptions the "
                + "pixels were rendered from were dropped. The pixels are intact; undo "
                + "restores them."
        }
        return try jsonResult(result)
    }
}
