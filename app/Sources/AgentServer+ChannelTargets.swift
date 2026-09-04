import AppKit

/// The shared channel pieces the FROZEN AgentServer.swift needs, so each of
/// its call sites stays one line: the widened paint `target` vocabulary and
/// its routing, the coverage commit, apply_filter on a plane, a plane
/// loaded as the selection, `render {channel:…}` and `get_document`'s
/// channel list.
///
/// Mirrors the Channels panel's row selection
/// (ChannelsPanelViewController) and the editor's paint target
/// (EditorViewController+Channels). The eleven channel TOOLS themselves
/// live in AgentServer+Channels.swift.
extension AgentServer {
    // MARK: - The target vocabulary

    /// The paint tools' `target` argument, widened from layer|mask to
    /// layer|mask|red|green|blue|alpha|channel:<name>. `allowMask` is false
    /// for apply_filter, whose vocabulary has no mask (filters on a mask
    /// are not a thing this build does).
    func paintTarget(
        _ a: [String: Any], _ document: ImageDocument, allowMask: Bool = true
    ) throws -> PaintTarget {
        let raw = stringArg(a, "target") ?? "layer"
        if raw == "layer" { return .layer }
        if raw == "mask" {
            guard allowMask else { throw Self.badTargetError(raw, allowMask: false) }
            return .mask
        }
        if let plane = RasterPlane.named(raw), PaintTarget.paintablePlanes.contains(plane) {
            return .plane(plane)
        }
        if raw.hasPrefix("channel:") {
            let name = String(raw.dropFirst("channel:".count))
            guard let doc = document.doc, let index = doc.channelIndex(named: name) else {
                throw ToolError(
                    message: "No channel named \"\(name)\" (list_channels shows them)")
            }
            return .channel(index)
        }
        throw Self.badTargetError(raw, allowMask: allowMask)
    }

    private static func badTargetError(_ got: String, allowMask: Bool) -> ToolError {
        let mask = allowMask ? "\"mask\", " : ""
        return ToolError(
            message: "target must be \"layer\", \(mask)\"red\", \"green\", \"blue\", "
                + "\"alpha\" or \"channel:<name>\" (got \"\(got)\")")
    }

    /// paintStroke's whole routing decision, lifted out of the frozen file:
    /// parses `target`, applies the ADJUSTMENT-LAYER forcing to PIXEL
    /// targets only (a `channel:` target is document state and is never
    /// retargeted — and it must not go through maskedLayerIndex, which
    /// validates a mask a channel has nothing to do with), picks the
    /// coverage colour (white brush / black eraser, opacity in the alpha),
    /// refuses `blend_mode` for every coverage target, and names the undo
    /// action. `note` is the in-band explanation when the adjustment
    /// routing moved a stroke the caller aimed elsewhere.
    func resolvePaintTarget(
        _ a: [String: Any], _ document: ImageDocument, requestedLayer: Int,
        erase: Bool, blend: RzBlendMode?
    ) throws -> (
        target: PaintTarget, layer: Int, actionName: String, color: NSColor, note: String?
    ) {
        let requested = try paintTarget(a, document)
        let isAdjustment = document.doc?.layerIsAdjustment(requestedLayer) == true
        // A CHANNEL edits document state, so an adjustment layer neither
        // forces it nor blocks it — the layer is not being painted at all.
        let forced = isAdjustment && !requested.isChannel
        if forced, document.doc?.layerHasMask(requestedLayer) != true {
            throw ToolError(
                message: "Layer \(requestedLayer) is an adjustment layer, so strokes paint "
                    + "its MASK — but its mask was deleted. Add one with add_layer_mask.")
        }
        let target: PaintTarget = forced ? .mask : requested
        let layer: Int
        if target == .mask {
            layer = try maskedLayerIndex(a, document, erase ? "erase" : "paint")
        } else {
            layer = requestedLayer
        }
        if case .plane = target {
            try rejectAdjustmentPixelEdit(document, layer)
        }
        if blend != nil, target.isCoverage {
            if forced, requested != .mask {
                // The caller DID target the layer; the adjustment routing
                // moved the stroke, so "use the layer target" would loop.
                throw ToolError(
                    message: "Layer \(layer) is an adjustment layer, so strokes always paint "
                        + "its MASK — blend_mode cannot apply there. Drop blend_mode, or "
                        + "stroke a pixel layer.")
            }
            throw ToolError(
                message: "blend_mode does not apply to a \(Self.coverageName(target)) stroke "
                    + "— coverage is not color. Stroke the layer target instead.")
        }
        // A coverage stroke carries its opacity in the stroke's own alpha:
        // the coverage ops take no separate alpha. Same clamp paintStroke
        // uses for the composite alpha, read from the same argument.
        let opacity = min(max(doubleArg(a, "opacity") ?? 1, 0), 1)
        let color: NSColor
        if target.isCoverage {
            let level: CGFloat = erase ? 0 : 1
            color = NSColor(srgbRed: level, green: level, blue: level, alpha: CGFloat(opacity))
        } else if erase {
            color = .black
        } else {
            color = try parseColor(a, "color", fallback: .black)
        }
        let actionName: String
        if target.isCoverage {
            actionName = target.strokeActionName(erasing: erase, in: document.doc)
        } else {
            actionName = erase ? "Eraser Stroke" : "Brush Stroke"
        }
        let note: String? =
            forced && requested != .mask
            ? "Layer \(layer) is an adjustment layer (no pixels to paint), so the stroke was "
                + "routed to its mask."
            : nil
        return (target, layer, actionName, color, note)
    }

    private static func coverageName(_ target: PaintTarget) -> String {
        switch target {
        case .mask: return "mask"
        case .plane(let plane): return plane.displayName.lowercased() + " plane"
        case .channel: return "channel"
        case .layer: return "layer"
        }
    }

    // MARK: - The commit

    /// Which layer's PIXELS an overlay edit rewrites — nil for a mask or a
    /// channel, where a text/shape/Live Photo description stays valid.
    func pixelLayer(for target: PaintTarget, layer: Int) -> Int? {
        switch target {
        case .layer, .plane: return layer
        case .mask, .channel: return nil
        }
    }

    /// The commit for a COVERAGE target — the branch paintOverlay used to
    /// spell as `if toMask`. All three take the same canvas-sized
    /// premultiplied overlay and the same lerp (white paints toward 255,
    /// black toward 0).
    ///
    /// A PLANE and a CHANNEL carry the core's `changed` latch: nil means no
    /// byte would move (white over white, or a selection that clipped the
    /// whole stroke away), which is a no-op to REPORT — `onRefusal` latches
    /// it so paintStroke answers `changed: false` instead of a parameter
    /// error. The MASK op has no such latch, so nil there is a real failure
    /// and is deliberately left to throw exactly as it does today.
    func commitCoverage(
        _ current: RasterDocument, target: PaintTarget, layer: Int,
        overlay: UnsafePointer<UInt8>, width: Int, height: Int,
        onRefusal: (() -> Void)? = nil
    ) -> RasterDocument? {
        switch target {
        case .layer:
            return nil
        case .mask:
            return current.paintingLayerMask(layer, overlay: overlay, w: width, h: height)
        case .plane(let plane):
            let out = current.paintingLayerPlane(
                layer, plane.rz, overlay: overlay, w: width, h: height)
            if out == nil { onRefusal?() }
            return out
        case .channel(let index):
            let out = current.paintingChannel(index, overlay: overlay, w: width, h: height)
            if out == nil { onRefusal?() }
            return out
        }
    }

    /// The in-band "nothing changed" result for a stroke the core refused
    /// because no pixel would move: an identity blend (Multiply by white), a
    /// coverage stroke that painted the coverage that was already there, or
    /// a stroke the active selection clipped away entirely. Never an error —
    /// `changed: false` says plainly that no undo step was added, which is
    /// what lets a model carry on instead of retrying the same call.
    func noOpStrokeResult(
        _ document: ImageDocument, target: PaintTarget, layer: Int, blend: RzBlendMode?
    ) throws -> String {
        let name = target.agentName(in: document.doc)
        let why: String
        if let blend = blend {
            why =
                "blend mode \(RzBlendMode.displayName(for: blend)) left every covered pixel "
                + "exactly as it was (an identity blend, like Multiply by white), or the "
                + "stroke never reached layer \(layer)'s pixels"
        } else {
            why =
                "the stroke painted \(name) exactly the coverage it already had, or the "
                + "active selection clipped it away entirely"
        }
        return try jsonResult([
            "ok": true, "changed": false, "layer": layer, "target": name,
            "note": "Nothing changed: \(why). No undo step was added.",
        ])
    }

    // MARK: - Filters on a plane

    /// apply_filter on a colour plane or an alpha channel, as the whole
    /// result the tool returns. The agent must NEVER reach
    /// ImageDocument.applyToActiveLayer / applyRasterizingEdit — they can
    /// raise a modal alert on this dispatched-to-main path — so this runs the
    /// plane round trip itself, inside performPixelEdit: extract the plane as
    /// an opaque grayscale image, run the SAME op, take the result's Rec. 709
    /// luma, write it back. Mirrors the UI's
    /// ImageDocument.applyToTargetPlane.
    ///
    /// A core refusal comes back as `changed: false` with a note, never as a
    /// parameter error: a filter that moves no byte (grayscale on a plane,
    /// which is gray already) is a legitimate answer to a legitimate call,
    /// and reporting it as an error would tell the model to fix arguments
    /// that were right — the `opRefused` latch paintStroke and applyImage
    /// already use.
    func applyPlaneFilter(
        _ document: ImageDocument, target: PaintTarget, layer: Int, filter: String,
        _ op: @escaping (RasterImage) -> RasterImage?
    ) throws -> String {
        let actionName = "Apply \(filter)"
        let name = target.agentName(in: document.doc)
        var refused = false
        let rasterized: DroppedDescription?
        do {
            rasterized = try applyPlaneFilterEdit(
                document, target: target, layer: layer, actionName: actionName,
                onRefusal: { refused = true }, op)
        } catch let error as ToolError {
            guard refused else { throw error }
            return try jsonResult([
                "ok": true, "changed": false, "filter": filter, "layer": layer,
                "target": name,
                "note": "Nothing changed: \(filter) left every byte of \(name) exactly as it "
                    + "was (an identity on this plane, the way grayscale is on a plane that "
                    + "is already gray). No undo step was added.",
            ])
        }
        return try pixelEditResult(
            ["ok": true, "filter": filter, "layer": layer, "target": name],
            layer: layer, rasterized: rasterized)
    }

    /// The edit half of `applyPlaneFilter`; `onRefusal` fires when the core
    /// answers nil (nothing would change), which the caller turns into an
    /// in-band `changed: false`.
    @discardableResult
    private func applyPlaneFilterEdit(
        _ document: ImageDocument, target: PaintTarget, layer: Int, actionName: String,
        onRefusal: @escaping () -> Void, _ op: @escaping (RasterImage) -> RasterImage?
    ) throws -> DroppedDescription? {
        switch target {
        case .layer, .mask:
            throw ToolError(
                message: "\(actionName) on \"\(target.agentName(in: document.doc))\" does not "
                    + "go through the plane path — this is a routing bug, not your call.")
        case .plane(let plane):
            // A plane write rewrites the layer's pixels, so an adjustment
            // layer refuses exactly as it does for the whole layer.
            try rejectAdjustmentPixelEdit(document, layer)
            return try performPixelEdit(document, actionName, pixelLayer: layer) { current in
                // Read at the LAYER's own size: a neighbourhood filter must
                // see the layer's pixels at its border, not the zeros a
                // canvas-sized read leaves outside its rect (PlanePlacement).
                // A nil from the READ or the op is a real failure (an
                // unreadable plane, a filter that refused its arguments) and
                // stays an error, exactly as it does on the whole-layer path;
                // only the WRITE's "no byte would change" is latched.
                guard let read = current.layerSpacePlaneImage(layer, plane.rz),
                      let filtered = op(read.image), let bytes = filtered.lumaPlane()
                else { return nil }
                // Written back in LAYER space, for the same reason it was
                // read there: the filter ran over every sample of the layer,
                // so every sample is written. A canvas-sized write would
                // leave this ONE plane unfiltered outside the canvas
                // (ImageDocument+Channels.writingPlaneResult).
                let out = current.withLayerSpacePlane(
                    layer, plane.rz, bytes,
                    width: read.placement.width, height: read.placement.height)
                if out == nil { onRefusal() }
                return out
            }
        case .channel(let index):
            // A channel is document state: no layer pixels change, so no
            // description is dropped.
            return try performPixelEdit(document, actionName, pixelLayer: nil) { current in
                guard let source = current.channelImage(index, maxSide: 0),
                      let filtered = op(source), let bytes = filtered.lumaPlane()
                else { return nil }
                let out = current.settingChannelData(index, bytes)
                if out == nil { onRefusal() }
                return out
            }
        }
    }

    // MARK: - Fill and gradient on a plane

    /// `fill`'s arguments, parsed once: the seed, the colour as straight
    /// RGBA bytes, and the region-grow options. Shared by the layer path in
    /// the frozen AgentServer and the plane path below, so the two spellings
    /// of `fill` can never drift.
    struct FillArguments {
        let x: Int
        let y: Int
        let rgba: [UInt8]
        let tolerance: Int
        let contiguous: Bool
    }

    func fillArguments(_ a: [String: Any]) throws -> FillArguments {
        guard let x = intArg(a, "x"), let y = intArg(a, "y") else {
            throw ToolError(message: "fill requires x and y (the seed point)")
        }
        return FillArguments(
            x: x, y: y, rgba: try colorRGBA(parseColor(a, "color", fallback: .black)),
            tolerance: intArg(a, "tolerance") ?? 32, contiguous: boolArg(a, "contiguous") ?? true)
    }

    /// `gradient`'s arguments, parsed once — same reason as `FillArguments`.
    struct GradientArguments {
        let from: CGPoint
        let to: CGPoint
        let start: [UInt8]
        let end: [UInt8]
        let kind: RzGradientKind
    }

    func gradientArguments(_ a: [String: Any]) throws -> GradientArguments {
        guard let x0 = doubleArg(a, "x0"), let y0 = doubleArg(a, "y0"),
            let x1 = doubleArg(a, "x1"), let y1 = doubleArg(a, "y1")
        else {
            throw ToolError(message: "gradient requires x0, y0, x1, y1")
        }
        let start = try colorRGBA(parseColor(a, "start_color", fallback: .black))
        let end: [UInt8]
        if stringArg(a, "end_color") != nil {
            end = try colorRGBA(parseColor(a, "end_color", fallback: .clear))
        } else {
            end = [0, 0, 0, 0] // fade to transparent
        }
        let kind: RzGradientKind
        switch stringArg(a, "shape") ?? "linear" {
        case "linear": kind = RZ_GRADIENT_LINEAR
        case "radial": kind = RZ_GRADIENT_RADIAL
        default: throw ToolError(message: "shape must be \"linear\" or \"radial\"")
        }
        return GradientArguments(
            from: CGPoint(x: x0, y: y0), to: CGPoint(x: x1, y: y1),
            start: start, end: end, kind: kind)
    }

    /// fill on a colour plane or an alpha channel — the MCP mirror of the
    /// Fill tool's redirect in EditorViewController+PlanePaint. The colour
    /// enters as coverage gray (`PlaneAlgebra.coverageColor`) and the region
    /// grow is the EXISTING `bucketFilled`, run on the scratch document the
    /// plane becomes.
    func fillPlane(
        _ document: ImageDocument, target: PaintTarget, layer: Int, _ f: FillArguments,
        mask: [UInt8]?
    ) throws -> String {
        guard let rgba = PlaneAlgebra.coverageColor(f.rgba) else {
            throw ToolError(message: "Could not read that color as coverage")
        }
        return try planeScratchEdit(
            document, target: target, layer: layer, actionName: "Fill",
            why: "the plane already held exactly that value everywhere the fill reached",
            mask: mask,
            .fill(
                x: f.x, y: f.y, rgba: rgba, tolerance: f.tolerance,
                contiguous: f.contiguous))
    }

    /// gradient on a colour plane or an alpha channel — the same mirror, for
    /// the Gradient tool's redirect.
    func gradientPlane(
        _ document: ImageDocument, target: PaintTarget, layer: Int, _ g: GradientArguments,
        mask: [UInt8]?
    ) throws -> String {
        guard let start = PlaneAlgebra.coverageColor(g.start),
              let end = PlaneAlgebra.coverageColor(g.end)
        else {
            throw ToolError(message: "Could not read those colors as coverage")
        }
        return try planeScratchEdit(
            document, target: target, layer: layer, actionName: "Gradient",
            why: "the plane already held exactly that ramp", mask: mask,
            .gradient(from: g.from, to: g.to, start: start, end: end, kind: g.kind))
    }

    /// The scratch-document round trip as an MCP result: read the target
    /// plane in ITS OWN space (a colour plane at the layer's size, a channel
    /// canvas-sized), run an existing document op on its one layer with the
    /// canvas geometry and the selection mask mapped into that space
    /// (`PlaneScratchOp`), write the result's luma back the same way — one
    /// undo step, with a core refusal reported in-band as `changed: false`
    /// exactly as the strokes and apply_filter report theirs.
    private func planeScratchEdit(
        _ document: ImageDocument, target: PaintTarget, layer: Int, actionName: String,
        why: String, mask: [UInt8]?, _ op: PlaneScratchOp
    ) throws -> String {
        let name = target.agentName(in: document.doc)
        var refused = false
        let rasterized: DroppedDescription?
        do {
            rasterized = try planeScratchCommit(
                document, target: target, layer: layer, actionName: actionName,
                onRefusal: { refused = true }, mask: mask, op)
        } catch let error as ToolError {
            guard refused else { throw error }
            return try jsonResult([
                "ok": true, "changed": false, "layer": layer, "target": name,
                "note": "Nothing changed: \(why). No undo step was added.",
            ])
        }
        return try pixelEditResult(
            ["ok": true, "layer": layer, "target": name],
            layer: layer, rasterized: rasterized)
    }

    private func planeScratchCommit(
        _ document: ImageDocument, target: PaintTarget, layer: Int, actionName: String,
        onRefusal: @escaping () -> Void, mask: [UInt8]?, _ op: PlaneScratchOp
    ) throws -> DroppedDescription? {
        switch target {
        case .layer, .mask:
            throw ToolError(
                message: "\(actionName) on \"\(target.agentName(in: document.doc))\" does not "
                    + "go through the plane path — this is a routing bug, not your call.")
        case .plane(let plane):
            // Writing a colour plane rewrites the layer's pixels, so an
            // adjustment layer refuses as it does for the whole layer.
            try rejectAdjustmentPixelEdit(document, layer)
            return try performPixelEdit(document, actionName, pixelLayer: layer) { current in
                // Read, run and write in the LAYER's own space, exactly as
                // apply_filter on a plane does above: a canvas-sized round
                // trip would grow a contiguous fill through the zeros outside
                // the layer's rect and leave this ONE plane at its old values
                // outside the canvas — a colour seam the next Canvas Size or
                // Move reveals (ImageDocument+Channels.writingPlaneResult).
                guard let read = current.layerSpacePlaneImage(layer, plane.rz),
                      let bytes = RasterDocument.planeThroughScratch(read.image, { scratch in
                          op.run(scratch, in: read.placement, mask: mask)
                      })
                else { return nil }
                let out = current.withLayerSpacePlane(
                    layer, plane.rz, bytes,
                    width: read.placement.width, height: read.placement.height)
                if out == nil { onRefusal() }
                return out
            }
        case .channel(let index):
            // A channel is canvas-sized document state: no placement, so the
            // canvas geometry and the selection mask pass through as they are.
            return try performPixelEdit(document, actionName, pixelLayer: nil) { current in
                guard let source = current.channelImage(index, maxSide: 0),
                      let bytes = RasterDocument.planeThroughScratch(source, { scratch in
                          op.run(scratch, in: nil, mask: mask)
                      })
                else { return nil }
                let out = current.settingChannelData(index, bytes)
                if out == nil { onRefusal() }
                return out
            }
        }
    }

    // MARK: - Selections from a plane

    /// A canvas-sized plane loaded as the selection. An ALL-ZERO plane is
    /// not an error: `CanvasSelection.init?` returns nil for it and
    /// applySelection would throw "The selection would be empty." — so this
    /// builds the selection itself and routes a nil straight to
    /// setCombined's `selection_empty` deselect, exactly as the UI's Load
    /// Selection does. Selections are never undoable.
    func applyPlaneSelection(
        _ document: ImageDocument, _ plane: [UInt8], mode: SelectionCombineMode,
        extra: [String: Any] = [:]
    ) throws -> String {
        guard let editorVC = editor(document) else {
            throw ToolError(message: "The document has no editor window to hold a selection.")
        }
        guard let doc = document.doc else { throw ToolError(message: "Document has no image") }
        guard
            let selection = CanvasSelection(
                shape: .mask(plane), canvasWidth: doc.width, canvasHeight: doc.height)
        else {
            // Nothing to combine with: replace and intersect empty the
            // selection, add and subtract leave it exactly as it was.
            switch mode {
            case .replace, .intersect:
                return try setCombined(editorVC, nil, extra: extra)
            case .add, .subtract:
                return try setCombined(editorVC, editorVC.agentSelection, extra: extra)
            }
        }
        return try setCombined(
            editorVC,
            CanvasSelection.combine(editorVC.agentSelection, with: selection, mode: mode),
            extra: extra)
    }

    // MARK: - Reporting

    /// `render`'s optional `channel` argument → that plane as an opaque
    /// grayscale image, plus the label the result is described by. With
    /// `layer` it is that layer's plane (canvas-sized, 0 outside the layer's
    /// rect); otherwise the flattened composite's.
    ///
    /// The label comes back from HERE because only this function knows what
    /// the string resolved to. `layer` selects a COLOUR plane's source layer
    /// and means nothing for an alpha channel — a channel is document state,
    /// the same plane whatever layer is named — so calling one "Sky plane of
    /// layer 0" and the next "Sky plane of layer 1" handed a model two
    /// identical PNGs described as two different layers' planes, from which
    /// "the layers are identical" is a reasonable conclusion.
    static func planeRenderImage(
        _ doc: RasterDocument, channel: String, layer: Int?
    ) throws -> (image: RasterImage?, what: String) {
        if let layer = layer, layer < 0 || layer >= doc.layerCount {
            throw ToolError(
                message: "Layer \(layer) is out of range (0..\(doc.layerCount - 1))")
        }
        if let plane = RasterPlane.named(channel), plane != .mask {
            if let layer = layer {
                return (
                    doc.layerPlaneImage(layer, plane.rz, maxSide: 0),
                    "\(channel) plane of layer \(layer)"
                )
            }
            return (doc.compositePlaneImage(plane.rz, maxSide: 0), "\(channel) plane")
        }
        guard let index = doc.channelIndex(named: channel) else {
            throw ToolError(
                message: "channel must be \"red\", \"green\", \"blue\", \"alpha\", \"luma\" or "
                    + "an alpha channel's name (list_channels shows them) — got "
                    + "\"\(channel)\"")
        }
        return (doc.channelImage(index, maxSide: 0), "channel \"\(channel)\"")
    }

    /// get_document's (and list_channels') channel list.
    static func channelFields(_ doc: RasterDocument) -> [[String: Any]] {
        (0..<doc.channelCount).compactMap { index -> [String: Any]? in
            guard let info = doc.channelInfo(index) else { return nil }
            return [
                "index": index,
                "name": info.name,
                "overlay_color": RasterImage.hexString(
                    (r: info.red, g: info.green, b: info.blue, a: 255)),
                "overlay_opacity": (info.opacity * 100).rounded() / 100,
                "color_indicates": info.colorIndicatesSelected ? "selected" : "masked",
            ]
        }
    }

    // MARK: - Shared argument parsing

    /// A `channel` argument: a channel NAME or an index, either spelling.
    ///
    /// The NAME is tried first. Channel names are free-form, so "7" is a
    /// legal one (`rename_channel` and `add_channel` both accept it), while
    /// `intArg` accepts the string form "7" as an index — parsing the index
    /// first made a channel named after a number reachable only by its
    /// position, and reported the failure as a range error that named the
    /// wrong problem. A real JSON number still means the index, and so does a
    /// string that names no channel, so `channel: "3"` keeps its meaning
    /// wherever nothing is called "3".
    func channelArgument(
        _ a: [String: Any], _ doc: RasterDocument, key: String = "channel"
    ) throws -> Int {
        if let name = stringArg(a, key), let index = doc.channelIndex(named: name) {
            return index
        }
        if let index = intArg(a, key) {
            guard index >= 0, index < doc.channelCount else {
                // An EMPTY list is the common case here and needs its own
                // sentence: the range form would read "(0..-1)", which sends a
                // model looking for the index that fits instead of telling it
                // there is no channel to address at all. Otherwise both
                // spellings are named, so the ambiguity is visible when
                // neither resolves.
                guard doc.channelCount > 0 else {
                    throw ToolError(
                        message: "This document has no alpha channels, so \(key) \(index) "
                            + "names nothing. Create one with add_channel or save_selection.")
                }
                throw ToolError(
                    message: "Channel \(index) is out of range (0..\(doc.channelCount - 1)), "
                        + "and no channel is named \"\(index)\" (list_channels shows them)")
            }
            return index
        }
        guard let name = stringArg(a, key) else {
            throw ToolError(message: "Missing required argument: \(key)")
        }
        throw ToolError(message: "No channel named \"\(name)\" (list_channels shows them)")
    }

    /// A source layer argument: an index, or nil for "merged" (the
    /// flattened composite) — the default when the key is absent.
    func sourceLayer(
        _ a: [String: Any], _ doc: RasterDocument, key: String
    ) throws -> Int? {
        if let index = intArg(a, key) {
            guard index >= 0, index < doc.layerCount else {
                throw ToolError(
                    message: "Layer \(index) is out of range (0..\(doc.layerCount - 1))")
            }
            return index
        }
        guard let name = stringArg(a, key) else { return nil }
        guard name == "merged" else {
            throw ToolError(
                message: "\(key) must be \"merged\" or a layer index (got \"\(name)\")")
        }
        return nil
    }

    /// A source-plane argument for apply_image / calculations: "rgb",
    /// a colour plane, or an alpha channel's name.
    func planeChoice(
        _ a: [String: Any], _ doc: RasterDocument, key: String
    ) throws -> PlaneChoice {
        guard let raw = stringArg(a, key) else { return .rgb }
        if raw == "rgb" { return .rgb }
        if let plane = RasterPlane.named(raw), plane != .mask { return .plane(plane) }
        guard let index = doc.channelIndex(named: raw) else {
            throw ToolError(
                message: "\(key) must be \"rgb\", \"red\", \"green\", \"blue\", \"luma\", "
                    + "\"alpha\" or an alpha channel's name (got \"\(raw)\")")
        }
        return .channel(index)
    }

    /// Where load_selection reads its plane from. `prefix` lets a tool with
    /// two source blocks spell them apart; load_selection passes "".
    func selectionSource(
        _ a: [String: Any], _ document: ImageDocument, prefix: String = ""
    ) throws -> SelectionSource {
        guard let doc = document.doc else { throw ToolError(message: "Document has no image") }
        let from = stringArg(a, prefix + "from") ?? "channel"
        switch from {
        case "channel":
            return .channel(try channelArgument(a, doc, key: prefix + "channel"))
        case "layer_alpha", "layer_mask":
            let index = intArg(a, prefix + "layer") ?? document.activeLayerIndex
            guard index >= 0, index < doc.layerCount else {
                throw ToolError(
                    message: "Layer \(index) is out of range (0..\(doc.layerCount - 1))")
            }
            if from == "layer_alpha" { return .layerAlpha(index) }
            guard doc.layerHasMask(index) else {
                throw ToolError(
                    message: "Layer \(index) has no mask to load. Add one with add_layer_mask.")
            }
            return .layerMask(index)
        case "plane":
            let name = stringArg(a, prefix + "plane") ?? "luma"
            guard let plane = RasterPlane.named(name), plane != .mask else {
                throw ToolError(
                    message: "plane must be \"red\", \"green\", \"blue\", \"alpha\" or "
                        + "\"luma\" (got \"\(name)\")")
            }
            return .compositePlane(plane)
        case let other:
            throw ToolError(
                message: "from must be \"channel\", \"layer_alpha\", \"layer_mask\" or "
                    + "\"plane\" (got \"\(other)\")")
        }
    }
}
