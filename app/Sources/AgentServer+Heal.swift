import AppKit

/// heal_stroke and spot_heal_stroke: the agent mirrors of the Healing Brush
/// and the Spot Healing Brush. Both rasterize their footprint through the
/// shared `retouchOverlay` rasterizer — the same canvas-sized premultiplied
/// overlay the interactive stroke pipeline builds, clipped to the same
/// selection — and hand it to the same core ops, so a stroke driven from
/// here and the same stroke drawn by hand land identical pixels.
///
/// The one difference between the two is what the overlay carries. The
/// Healing Brush's holds the ALIGNED SOURCE premultiplied by the footprint's
/// coverage (the Clone Stamp's overlay, literally); the Spot Healing Brush's
/// holds pure white coverage, because there is no sampled source — the core
/// inpaints one — and the op ignores the overlay's RGB by contract.
extension AgentServer {

    // MARK: - Shared arguments

    /// The two healing brushes' shared stroke arguments: the stroke width in
    /// px, the heal's strength, and the tip.
    ///
    /// Two arguments the other stroke tools take are REFUSED rather than
    /// quietly ignored, because honoring them would break the op:
    ///
    /// - `flow` — the solve's domain is the overlay's coverage (alpha at or
    ///   above half), so a flowed-down dab would deposit less than that
    ///   everywhere and leave nothing to solve; the stroke always deposits
    ///   full coverage and `opacity` carries the strength instead. That is
    ///   the same rule the canvas applies by latching flow to 1 for these
    ///   two tools.
    /// - `blend_mode` — the heal replaces the covered pixels with a solved
    ///   result; there is no compositing step for a mode to change.
    private func healStrokeArgs(_ a: [String: Any], _ tool: String) throws
        -> (size: CGFloat, strength: Double, tip: BrushTip)
    {
        guard a["flow"] == nil else {
            throw ToolError(
                message: "\(tool) has no flow: the heal solves over the stroke's COVERAGE, so "
                    + "a flowed-down dab would leave nothing to solve. The stroke always "
                    + "deposits full coverage and opacity (1-100) is the heal's strength.")
        }
        guard stringArg(a, "blend_mode") == nil else {
            throw ToolError(
                message: "\(tool) has no blend_mode — it replaces the covered pixels with the "
                    + "blended result; blend modes apply to brush_stroke and clone_stamp.")
        }
        let rawSize = doubleArg(a, "size") ?? 24
        let rawOpacity = doubleArg(a, "opacity") ?? 100
        guard rawSize.isFinite, rawOpacity.isFinite else {
            throw ToolError(message: "size and opacity must be finite numbers")
        }
        var tip = try strokeTip(a)
        // The canvas's own latch, restated: BrushTip carries flow through to
        // every dab's alpha, and the covered set is what the solve runs over.
        tip.flow = 1
        return (
            // The floor is the tool's, not the paint family's: a healing
            // footprint under three pixels is entirely boundary and the op
            // answers "changed nothing" (EditorTool.minimumBrushSize says
            // why). Both healing brushes share it.
            size: CGFloat(min(max(rawSize, EditorTool.heal.minimumBrushSize), 200)),
            strength: min(max(rawOpacity, 1), 100) / 100,
            tip: tip
        )
    }

    /// The refusal both handlers report when the op itself answers "nothing
    /// would change" — a no-op, not a failure: no edit landed and no undo
    /// step opened, which is exactly what the tools do when they beep and
    /// roll a stroke back.
    private func healNoOpResult(_ tool: String, layer: Int, extra: String) throws -> String {
        try jsonResult([
            "ok": true, "changed": false, "layer": layer,
            "note": "\(tool) changed nothing. Either the stroke never covered layer "
                + "\(layer)'s pixels — the layer's extent may not reach the points, the "
                + "active selection may have clipped the whole stroke away, or a very soft "
                + "tip left the footprint below the half coverage the solve needs — or "
                + "\(extra) No undo step was added.",
        ])
    }

    // MARK: - Healing brush

    /// heal_stroke — mirrors the Healing Brush tool: a snapshot displaced by
    /// (first point − source) is painted into the stroke's coverage, and the
    /// pixels under the WHOLE footprint are Poisson-blended into the layer
    /// once, so the healed patch keeps the source's texture and the
    /// destination's illumination. The interactive tool commits the identical
    /// overlay through the identical op at mouse-up
    /// (EditorViewController+Heal.commitHealOverlay).
    func healStroke(_ a: [String: Any]) throws -> String {
        let document = try target(a)
        let index = try paintLayerIndex(a, document)
        // The UI refuses a healing stroke on an adjustment layer outright
        // (onStrokeBegin): there are no pixels to rewrite.
        try rejectAdjustmentPixelEdit(document, index)
        guard let sourceX = doubleArg(a, "source_x"), let sourceY = doubleArg(a, "source_y"),
            sourceX.isFinite, sourceY.isFinite
        else {
            throw ToolError(
                message: "heal_stroke requires source_x and source_y — the canvas point the "
                    + "texture is healed FROM (what sits there lands under the stroke's "
                    + "first point). Use spot_heal_stroke when there is no clean source to "
                    + "name.")
        }
        let points = try parsePoints(a)
        let stroke = try healStrokeArgs(a, "heal_stroke")
        guard let doc = document.doc else { throw ToolError(message: "Document has no image") }
        let canvasHeight = doc.height
        // Sample All Layers picks the SNAPSHOT and nothing else, exactly as
        // the tool does (EditorViewController+Heal.strokeSourceImage): on,
        // the flattened composite; off, the layer's own pixels already
        // placed in canvas space and transparent elsewhere, so a dab over
        // the layer's emptiness deposits no coverage. The core never learns
        // which was chosen.
        let sampleAll = boolArg(a, "sample_all_layers") ?? true
        // Latched before the edit, like the interactive stroke's mouse-down
        // latch: nothing can change what is being healed from mid-stroke.
        // The snapshot and the overlay it is stamped into share the
        // document's space, so a zero-offset heal samples the same numbers.
        let sampled = sampleAll
            ? (document.projection ?? doc.flattened())
            : doc.layerCanvasImage(index)
        guard let snapshot = sampled?.makeCGImage(in: doc.colorSpace) else {
            throw ToolError(
                message: sampleAll
                    ? "Could not snapshot the composite to heal from"
                    : "Layer \(index) has no pixels to heal from. Pass sample_all_layers "
                        + "true to sample the flattened composite instead.")
        }
        let offset = CGVector(dx: points[0].x - sourceX, dy: points[0].y - sourceY)

        let rasterized: DroppedDescription?
        // Latched when the HEAL OP ITSELF answers nil, so only that case
        // reads as a no-op — any other failure stays an error.
        var opRefused = false
        // …and latched when it REFUSES WITH A MESSAGE (a documented memory
        // limit). The commit closure cannot throw, so the message rides out
        // here rather than being swallowed or replaced by the generic
        // "failed — check the parameters".
        var thrown: String?
        do {
            rasterized = try retouchOverlay(
                document, layer: index, actionName: "Healing Brush",
                draw: { context in
                    // The un-flip inside: the overlay context is flipped
                    // (row 0 = top), so the snapshot flips back locally to
                    // land right side up at the displaced position — the
                    // canvas's stampCloneDab rule, which the Healing Brush
                    // shares with the Clone Stamp (the same closure body as
                    // AgentServer+Retouch.cloneStamp's, which owns it: the
                    // healing brush IS the clone stamp with a different op
                    // at commit).
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
                    // A non-default tip stamps the snapshot dab by dab: the
                    // tip's footprint (gray falloff mask when soft, hard
                    // ellipse otherwise, squashed and rotated) clips each
                    // dab. Flow is 1 here by construction, so no dab is
                    // deposited at reduced alpha — hardness SHRINKS the
                    // healed footprint inside the brush circle rather than
                    // fading the heal, which the join makes seamless anyway.
                    if SoftBrush.isStamped(tip: stroke.tip, size: stroke.size) {
                        let mask = SoftBrush.isSoft(
                            hardness: stroke.tip.hardness, size: stroke.size)
                            ? SoftBrush.dabMask(
                                diameter: stroke.size, hardness: stroke.tip.hardness)
                            : nil
                        let spacing = SoftBrush.spacing(
                            for: stroke.size, percent: stroke.tip.spacingPercent)
                        for center in SoftBrush.stampCenters(along: points, spacing: spacing) {
                            context.saveGState()
                            SoftBrush.clipDab(
                                in: context, at: center, diameter: stroke.size,
                                tip: stroke.tip, mask: mask)
                            drawSnapshot(context)
                            context.restoreGState()
                        }
                        return
                    }
                    context.addPath(
                        Self.strokeCoverage(points: points, size: stroke.size))
                    context.clip()
                    drawSnapshot(context)
                },
                commit: { current, base, w, h in
                    do {
                        let out = try current.healLayer(
                            index, overlay: base, w: w, h: h, strength: stroke.strength)
                        if out == nil { opRefused = true }
                        return out
                    } catch let error as RasterCoreError {
                        thrown = error.message
                        return nil
                    } catch {
                        thrown = error.localizedDescription
                        return nil
                    }
                })
        } catch let error as ToolError {
            // A documented limit, reported with its own numbers and its own
            // instruction — never the generic edit failure.
            if let message = thrown { throw ToolError(message: message) }
            guard opRefused else { throw error }
            return try healNoOpResult(
                "heal_stroke", layer: index,
                extra: "the sampled texture is already what sits under the stroke.")
        }
        return try pixelEditResult(
            [
                "ok": true, "action": "Healing Brush", "layer": index,
                "points": points.count,
                "applied": [
                    "size": Self.transformNumber(Double(stroke.size)),
                    "opacity": Self.transformNumber(stroke.strength * 100),
                    "sample_all_layers": sampleAll,
                    "source_x": Self.transformNumber(sourceX),
                    "source_y": Self.transformNumber(sourceY),
                ],
            ], layer: index, rasterized: rasterized)
    }

    // MARK: - Spot healing brush

    /// spot_heal_stroke — mirrors the Spot Healing Brush tool: the same
    /// stroke with no source point. The overlay carries pure white coverage
    /// (the dodge_burn shape — the core reads only its alpha), the core
    /// inpaints the footprint content-aware from a ring of valid pixels
    /// around it, and blends the result in exactly as heal_stroke's sampled
    /// patch is blended. The interactive tool commits the identical overlay
    /// through the identical op at mouse-up
    /// (EditorViewController+Heal.commitHealOverlay).
    func spotHealStroke(_ a: [String: Any]) throws -> String {
        let document = try target(a)
        let index = try paintLayerIndex(a, document)
        // The UI refuses a healing stroke on an adjustment layer outright
        // (onStrokeBegin): there are no pixels to rewrite.
        try rejectAdjustmentPixelEdit(document, index)
        let points = try parsePoints(a)
        let stroke = try healStrokeArgs(a, "spot_heal_stroke")
        let rawRing = intArg(a, "ring") ?? 0
        guard rawRing >= 0, rawRing <= 512 else {
            throw ToolError(
                message: "ring must be between 0 and 512 px (0 = automatic, which is the "
                    + "default). Anything from 1 to 20 is raised to 21 — three patch widths, "
                    + "the narrowest band a source patch has room to move in.")
        }
        let rawSeed = intArg(a, "seed") ?? 0
        guard rawSeed >= 0 else {
            throw ToolError(message: "seed must be a non-negative integer (default 0)")
        }
        // Unlike the Healing Brush's, this flag is the CORE's: the core
        // generates the source, so it is the side that has to know where to
        // sample from — the overlay carries coverage and nothing else.
        // Default off, like the tool's: spot healing is used on the layer it
        // is used on, and sampling the composite would inpaint from pixels
        // that layer does not own.
        let sampleAll = boolArg(a, "sample_all_layers") ?? false

        let rasterized: DroppedDescription?
        // Latched when the OP ITSELF answers nil (a no-op) …
        var opRefused = false
        // … and when it refuses with a message (a documented cap, or nothing
        // to sample from). See healStroke: the commit closure cannot throw.
        var thrown: String?
        do {
            rasterized = try retouchOverlay(
                document, layer: index, actionName: "Spot Healing",
                draw: { context in
                    // Pure coverage: white at full alpha, since the op reads
                    // only the overlay's alpha and there is no sampled
                    // source to place. Flow is 1 by construction, so a
                    // stamped tip deposits full-alpha dabs and hardness
                    // shrinks the footprint rather than fading it.
                    let white = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
                    if SoftBrush.isStamped(tip: stroke.tip, size: stroke.size),
                        let dab = SoftBrush.dab(
                            color: white, diameter: stroke.size,
                            hardness: stroke.tip.hardness, space: document.drawingSpace) {
                        let spacing = SoftBrush.spacing(
                            for: stroke.size, percent: stroke.tip.spacingPercent)
                        for center in SoftBrush.stampCenters(along: points, spacing: spacing) {
                            SoftBrush.stamp(
                                dab, in: context, at: center, diameter: stroke.size,
                                tip: stroke.tip)
                        }
                        return
                    }
                    context.setFillColor(white.cgColor)
                    context.addPath(
                        Self.strokeCoverage(points: points, size: stroke.size))
                    context.fillPath()
                },
                commit: { current, base, w, h in
                    do {
                        let out = try current.spotHealLayer(
                            index, overlay: base, w: w, h: h, strength: stroke.strength,
                            ring: rawRing, seed: UInt64(rawSeed),
                            sampleAllLayers: sampleAll, preview: false)
                        if out == nil { opRefused = true }
                        return out
                    } catch let error as RasterCoreError {
                        thrown = error.message
                        return nil
                    } catch {
                        thrown = error.localizedDescription
                        return nil
                    }
                })
        } catch let error as ToolError {
            // A cap or a starved sampling region, reported with the core's
            // own numbers and instruction — never the generic edit failure.
            if let message = thrown { throw ToolError(message: message) }
            guard opRefused else { throw error }
            return try healNoOpResult(
                "spot_heal_stroke", layer: index,
                extra: "the inpainted texture is already what sits under the stroke.")
        }
        return try pixelEditResult(
            [
                "ok": true, "action": "Spot Healing", "layer": index,
                "points": points.count,
                "applied": [
                    "size": Self.transformNumber(Double(stroke.size)),
                    "opacity": Self.transformNumber(stroke.strength * 100),
                    "sample_all_layers": sampleAll,
                    "ring": rawRing, "seed": rawSeed,
                ],
            ], layer: index, rasterized: rasterized)
    }
}
