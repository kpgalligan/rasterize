import AppKit

/// THE RECORDED VOCABULARY: one factory per user command that has an MCP
/// twin, plus the two "nothing to record" spellings.
///
/// Every commit entry point on `ImageDocument` takes a `record: [ActionStep]`
/// parameter, so every one of the app's ~100 edit sites must name something
/// from this file or say explicitly that it records nothing. That is the
/// whole design: the step is a PARAMETER, not a global slot armed before the
/// call, so (1) a new feature's edit path does not compile until it states a
/// step, (2) a path that refuses AFTER arming — `performLayerEdit` has three
/// such guards — carries its step away with it instead of leaving a stale
/// one for the next unrelated edit to consume, and (3) the gaps are
/// greppable in a diff rather than discovered at runtime.
///
/// Two invariants, both consequences of measured differences between the UI
/// and the agent paths:
///
/// - **A recorded step is fully explicit.** Never rely on a catalog default;
///   they deliberately differ from the UI's (menu Sharpen is amount 1.5, the
///   catalog default 1.0; the blur sheet starts at sigma 2, the catalog at
///   4). A recorded UI Sharpen therefore emits `amount: 1.5`.
/// - **The ambient target is serialised.** Any filter, fill, gradient or
///   stroke step writes `target` explicitly from
///   `ImageDocument.planeEditTarget`, spelled the way `AgentServer.paintTarget`
///   parses it, because the UI reads that ambient value where the agent
///   reads an argument.
///
/// The file is meant to be reviewed against the catalog's argument table in
/// one pass — every factory names its tool, and `ActionStep.init` asserts in
/// debug builds that the name is a live dispatch key.
extension Array where Element == ActionStep {
    /// NOT a user command: an internal re-entry, a helper, an undo/redo
    /// restore, or the agent's own path (which records once, centrally, in
    /// `AgentServer.execute`).
    static var notACommand: [ActionStep] { [] }

    /// A user command with NO MCP twin. Appended as a visible placeholder so
    /// the gap lands in the action — named, listed in the Actions window and
    /// refused at replay — instead of being a silent hole in a recording
    /// that otherwise looks complete.
    static func unrecorded(_ name: String) -> [ActionStep] {
        [ActionStep(tool: ActionStep.unrecordedTool, arguments: ["action": name])]
    }

    /// One step, spelled out. The general form behind every factory below;
    /// used directly only where a command's arguments are too one-off to
    /// deserve a name of their own.
    static func step(_ tool: String, _ arguments: [String: Any] = [:], note: String? = nil)
        -> [ActionStep]
    {
        [ActionStep(tool: tool, arguments: arguments, note: note)]
    }

    // MARK: - Whole-document geometry

    /// Image ▸ Rotate. `degrees` is one of 90/180/270/−90.
    static func rotate(_ degrees: Int) -> [ActionStep] {
        step("rotate", ["degrees": degrees], note: "Image ▸ Rotate")
    }

    /// Image ▸ Flip Canvas.
    static func flip(_ axis: String) -> [ActionStep] {
        step("flip", ["axis": axis], note: "Image ▸ Flip Canvas")
    }

    /// Image ▸ Crop, and the Crop tool's commit. ABSOLUTE canvas pixels: a
    /// crop is not remapped onto a differently sized document, and
    /// `Action.recordedCanvas` is what lets the player SAY the sizes differ.
    ///
    /// `sampler` is recorded whenever the crop STRAIGHTENS, because that is
    /// the one thing about a crop that resamples: the tool straightens with
    /// the editor's shared Free Transform sampler, so an action recorded
    /// with Nearest selected has to replay through Nearest or it reproduces
    /// smoothed pixels the user never saw. A plain rectangle crop moves the
    /// canvas window and samples nothing, so it records no sampler at all.
    static func crop(_ rect: CGRect, angle: Double = 0, sampler: String? = nil)
        -> [ActionStep]
    {
        var arguments: [String: Any] = [
            "x": Int(rect.minX.rounded()), "y": Int(rect.minY.rounded()),
            "width": Int(rect.width.rounded()), "height": Int(rect.height.rounded()),
        ]
        if angle != 0 {
            arguments["angle"] = ActionArgs.number(angle)
            if let sampler = sampler { arguments["sampler"] = sampler }
        }
        return step("crop", arguments, note: "Image ▸ Crop")
    }

    /// Image ▸ Image Size…
    static func imageSize(width: Int, height: Int, filter: String) -> [ActionStep] {
        step(
            "image_size", ["width": width, "height": height, "filter": filter],
            note: "Image ▸ Image Size…")
    }

    /// Image ▸ Canvas Size…, from the anchor grid's own cell.
    ///
    /// Row 0 is the TOP row — the sheet's `row / 2` fraction puts none of a
    /// height increase above the old origin there, which is what "top"
    /// means — and the mapping lives here rather than in the sheet so the
    /// catalog's vocabulary stays in the vocabulary file.
    static func canvasSize(
        width: Int, height: Int, anchor: (col: Int, row: Int)
    ) -> [ActionStep] {
        let rows = ["top", "", "bottom"]
        let cols = ["left", "", "right"]
        let row = rows[Swift.min(Swift.max(anchor.row, 0), 2)]
        let col = cols[Swift.min(Swift.max(anchor.col, 0), 2)]
        let name: String
        switch (row.isEmpty, col.isEmpty) {
        case (true, true): name = "center"
        case (true, false): name = col
        case (false, true): name = row
        case (false, false): name = "\(row)-\(col)"
        }
        return step(
            "canvas_size", ["width": width, "height": height, "anchor": name],
            note: "Image ▸ Canvas Size…")
    }

    /// Layer ▸ Flatten Image.
    static var flattenImage: [ActionStep] {
        step("flatten_image", note: "Layer ▸ Flatten Image")
    }

    // MARK: - Layers

    /// Layer ▸ New ▸ Layer.
    static func newLayer(name: String) -> [ActionStep] {
        step("new_layer", ["name": name], note: "Layer ▸ New ▸ Layer")
    }

    /// Layer ▸ Duplicate / Delete / Merge over the panel's whole selection.
    /// The set is symbolic — `{"$layers": "selected"}` — so a replay acts on
    /// whatever the target document has selected.
    static func selectedLayersCommand(_ tool: String, note: String) -> [ActionStep] {
        step(tool, ["layers": ActionArgs.selectedLayers], note: note)
    }

    /// Layer ▸ Merge Down, the single-layer form.
    static var mergeDown: [ActionStep] {
        step("merge_down", ["index": ActionArgs.activeLayer], note: "Layer ▸ Merge Down")
    }

    /// Layer ▸ Merge Visible / Stamp Visible.
    static var mergeVisible: [ActionStep] {
        step("merge_visible", note: "Layer ▸ Merge Visible")
    }

    static func stampVisible(name: String) -> [ActionStep] {
        step("stamp_visible", ["name": name], note: "Layer ▸ Stamp Visible")
    }

    /// Layer ▸ New ▸ Layer Via Copy / Via Cut.
    static func layerVia(cut: Bool, name: String) -> [ActionStep] {
        step(
            cut ? "layer_via_cut" : "layer_via_copy",
            ["layer": ActionArgs.activeLayer, "name": name],
            note: cut ? "Layer ▸ New ▸ Layer Via Cut" : "Layer ▸ New ▸ Layer Via Copy")
    }

    /// One property of the ACTIVE layer — the panel header's blend mode and
    /// opacity, the eye toggle, an inline rename, a group's disclosure.
    ///
    /// `set_layer_properties` writes ONE layer, and the panel header writes
    /// the whole selection; a multi-entry write therefore has no twin and
    /// records `.unrecorded` at its site rather than pretending here.
    static func layerProperty(_ key: String, _ value: Any, note: String) -> [ActionStep] {
        step("set_layer_properties", ["index": ActionArgs.activeLayer, key: value], note: note)
    }

    /// The same write aimed at a layer the user picked by row rather than at
    /// the ambient active one (the panel's per-row eye, rename and
    /// disclosure controls address their own row).
    static func layerProperty(
        _ key: String, _ value: Any, layerNamed name: String?, note: String
    ) -> [ActionStep] {
        step(
            "set_layer_properties",
            ["index": ActionArgs.layer(named: name), key: value], note: note)
    }

    /// A property write the layers panel's HEADER fans out across the whole
    /// selection (blend mode, opacity, the lock set).
    ///
    /// One selected layer records the real write; several record the visible
    /// placeholder, because `set_layer_properties` writes ONE layer and there
    /// is no set form of it. Splitting the write into N steps by name was
    /// rejected: two layers may share a name, and a step that silently wrote
    /// the same layer twice would be worse than a stated gap.
    static func selectionProperty(
        _ key: String, _ value: Any, selectionCount: Int, note: String
    ) -> [ActionStep] {
        guard selectionCount == 1 else { return unrecorded(note) }
        return layerProperty(key, value, note: note)
    }

    /// A Move drag or nudge that ended on ONE layer.
    ///
    /// The note is not decoration: `set_layer_properties` writes an ABSOLUTE
    /// offset while the drag was a RELATIVE move, so replaying this snaps the
    /// layer to a fixed canvas position instead of nudging it by the same
    /// amount. A relative form of the tool is the follow-up that would fix
    /// it; until then the difference is stated rather than implied.
    static func layerOffset(x: Int, y: Int, layerNamed name: String?) -> [ActionStep] {
        step(
            "set_layer_properties",
            ["index": ActionArgs.layer(named: name), "offset_x": x, "offset_y": y],
            note: "Move: recorded as an absolute position; the drag was a relative move")
    }

    /// A panel drag that moved ONE entry. `to` is in the core's own
    /// remove-then-insert numbering (the stack with this entry's subtree
    /// already taken out), which is what the tool documents and what
    /// `dragReorder` computes.
    static func reorderLayer(from: Int, to: Int, depth: Int) -> [ActionStep] {
        step(
            "reorder_layer", ["from": from, "to": to, "depth": depth],
            note: "Layers panel: drag to reorder")
    }

    /// Layer ▸ Arrange ▸ …
    static func arrangeLayer(to position: String) -> [ActionStep] {
        step(
            "arrange_layer", ["layer": ActionArgs.activeLayer, "to": position],
            note: "Layer ▸ Arrange")
    }

    /// Layer ▸ Align / Distribute, over the panel's selection.
    static func alignLayers(edge: String, to reference: String) -> [ActionStep] {
        step(
            "align_layers",
            ["layers": ActionArgs.selectedLayers, "edge": edge, "to": reference],
            note: "Layer ▸ Align")
    }

    static func distributeLayers(axis: String) -> [ActionStep] {
        step(
            "distribute_layers", ["layers": ActionArgs.selectedLayers, "axis": axis],
            note: "Layer ▸ Distribute")
    }

    static func linkLayers(unlink: Bool) -> [ActionStep] {
        step(
            unlink ? "unlink_layers" : "link_layers", ["layers": ActionArgs.selectedLayers],
            note: unlink ? "Layer ▸ Unlink Layers" : "Layer ▸ Link Layers")
    }

    /// Layer ▸ Group Layers / Ungroup Layers.
    static func groupLayers(name: String) -> [ActionStep] {
        step(
            "group_layers", ["layers": ActionArgs.selectedLayers, "name": name],
            note: "Layer ▸ Group Layers")
    }

    static var ungroupLayers: [ActionStep] {
        step(
            "ungroup_layers", ["index": ActionArgs.activeLayer],
            note: "Layer ▸ Ungroup Layers")
    }

    /// Layer ▸ Lock — one layer's lock set, as the tool's `locks` array.
    static func setLayerLock(_ locks: [String]) -> [ActionStep] {
        step(
            "set_layer_lock", ["layer": ActionArgs.activeLayer, "locks": locks],
            note: "Layer ▸ Lock")
    }

    /// Layer ▸ Create/Release Clipping Mask.
    static func setLayerClipped(_ clipped: Bool) -> [ActionStep] {
        step(
            "set_layer_clipped", ["layer": ActionArgs.activeLayer, "clipped": clipped],
            note: "Layer ▸ Clipping Mask")
    }

    /// A layer picked in the panel, or by the Move tool's Auto-Select.
    ///
    /// By NAME, because "the third row" means nothing on another document
    /// while "the layer called Sky" is exactly what the user pointed at. A
    /// name that is missing at replay fails the step with that name in the
    /// message.
    static func selectLayer(named name: String?) -> [ActionStep] {
        step(
            "set_active_layer", ["index": ActionArgs.layer(named: name)],
            note: "Layers panel: select a layer")
    }

    /// A multi-row panel selection: every member by name, with the primary
    /// named too. Duplicate names resolve to the same layer and the tool
    /// then refuses the duplicate, which is a visible failure rather than a
    /// silent wrong answer.
    static func selectLayers(named names: [String?], primary: String?) -> [ActionStep] {
        step(
            "set_selected_layers",
            [
                "layers": names.map { ActionArgs.layer(named: $0) },
                "primary": ActionArgs.layer(named: primary),
            ],
            note: "Layers panel: select several layers")
    }

    /// The Move tool's Auto-Select click — geometric, so it replays on a
    /// different document with no layer name to miss.
    static func autoSelectLayer(at point: CGPoint, group: Bool) -> [ActionStep] {
        step(
            "auto_select_layer",
            ["x": ActionArgs.number(point.x), "y": ActionArgs.number(point.y), "group": group],
            note: "Move tool: Auto-Select")
    }

    // MARK: - Layer masks, styles and clipping

    static func addLayerMask(kind: String) -> [ActionStep] {
        step(
            "add_layer_mask", ["layer": ActionArgs.activeLayer, "kind": kind],
            note: "Layer ▸ Layer Mask")
    }

    static func removeLayerMask(apply: Bool) -> [ActionStep] {
        step(
            "remove_layer_mask", ["layer": ActionArgs.activeLayer, "apply": apply],
            note: apply ? "Layer ▸ Layer Mask ▸ Apply" : "Layer ▸ Layer Mask ▸ Delete")
    }

    static func setLayerMaskEnabled(_ enabled: Bool) -> [ActionStep] {
        step(
            "set_layer_mask_enabled", ["layer": ActionArgs.activeLayer, "enabled": enabled],
            note: "Layer ▸ Layer Mask ▸ Enable/Disable")
    }

    /// Layer ▸ Layer Style. `json` is the style's own canonical JSON — what
    /// `LayerStyle.json()` writes and what `set_layer_style` parses — or nil
    /// to clear the layer's style.
    static func setLayerStyle(json: String?, layerNamed name: String?, note: String)
        -> [ActionStep]
    {
        // Stored as an OBJECT rather than as the string the handler would
        // also accept, so the recorded step matches the catalog's own schema
        // and reads properly in the JSON editor.
        let object: Any = json
            .flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }
            .flatMap { $0 as? [String: Any] } ?? NSNull()
        return step(
            "set_layer_style",
            ["layer": ActionArgs.layer(named: name), "style": object], note: note)
    }

    static func setGlobalLight(angle: Double, altitude: Double) -> [ActionStep] {
        step(
            "set_global_light",
            ["angle": ActionArgs.number(angle), "altitude": ActionArgs.number(altitude)],
            note: "Layer ▸ Layer Style ▸ Global Light")
    }

    // MARK: - Filters and adjustments

    /// Filters ▸ … and Image ▸ Adjustments ▸ … (the destructive halves).
    /// `extra` carries the filter's own parameters; `target` is the ambient
    /// plane/channel target, always written out.
    static func filter(_ name: String, _ extra: [String: Any] = [:], target: String)
        -> [ActionStep]
    {
        var arguments: [String: Any] = ["filter": name, "layer": ActionArgs.activeLayer]
        arguments.merge(extra) { _, new in new }
        arguments["target"] = target
        return step("apply_filter", arguments, note: "Filters / Image ▸ Adjustments")
    }

    /// Image ▸ Auto Tone / Auto Contrast / Auto Color.
    static func autoAdjust(_ tool: String) -> [ActionStep] {
        step(tool, ["layer": ActionArgs.activeLayer], note: "Image ▸ Auto…")
    }

    /// Layer ▸ New Adjustment Layer ▸ …, from the very meta the dialog is
    /// about to store, so the recorded parameters cannot drift from the
    /// committed ones.
    static func addAdjustmentLayer(meta: String, name: String) -> [ActionStep] {
        guard let payload = AdjustmentLayerPayload.decode(meta) else {
            return unrecorded("New \(name) Layer")
        }
        return step(
            "add_adjustment_layer",
            ["op": payload.op, "name": name, "params": payload.params],
            note: lutNote(payload) ?? "Layer ▸ New Adjustment Layer")
    }

    /// Re-editing an existing adjustment layer's parameters.
    static func editAdjustmentLayer(meta: String, layerNamed name: String?) -> [ActionStep] {
        guard let payload = AdjustmentLayerPayload.decode(meta) else {
            return unrecorded("Edit Adjustment Layer")
        }
        var params = payload.params
        // A Color Lookup layer's stored LUT is up to ~575 KB of base64, and
        // an EDIT does not need it: `edit_adjustment_layer` carries the
        // layer's own table forward when the call names no replacement
        // (`AgentServer+Adjustments.mergingStoredLut`, which exists for
        // exactly this flow). So the table keys are dropped and only what the
        // dialog actually changes — `strength` — is recorded.
        if payload.op == AdjustmentLayerOp.colorLookup.rawValue {
            for key in AgentServer.lutTableKeys { params.removeValue(forKey: key) }
        }
        return step(
            "edit_adjustment_layer",
            ["layer": ActionArgs.layer(named: name), "op": payload.op, "params": params],
            note: "Layer ▸ Adjustment Options…")
    }

    /// The one place a recorded adjustment step is allowed to be large, and
    /// the note that says so.
    ///
    /// A NEW Color Lookup layer has nowhere to get its table from but the
    /// step itself: the layer stores no .cube path (that is stated in
    /// `mergingStoredLut`'s own comment), so there is no `file` form to
    /// record and the honest choice is a big step that replays correctly
    /// over a small one that cannot.
    private static func lutNote(_ payload: AdjustmentLayerPayload) -> String? {
        guard payload.op == AdjustmentLayerOp.colorLookup.rawValue,
              (payload.params["table"] as? String)?.isEmpty == false
        else { return nil }
        return "Layer ▸ New Adjustment Layer — carries the whole colour LUT, "
            + "because the layer keeps no path to the .cube it came from"
    }

    // MARK: - Painting

    /// One paint/retouch stroke, replayed as the SAME polyline through the
    /// SAME `SoftBrush` engine the canvas dabs with.
    ///
    /// This is exact for geometry and tip, and honestly lossy in two places,
    /// both of which are limits of the catalog rather than of the recorder:
    /// PRESSURE is flattened (no stroke tool takes a per-point pressure, and
    /// the canvas modulates both diameter and spacing with it, so a
    /// pressure-varied stroke replays at the constant tip size), and an
    /// AIRBRUSH hold replays as a single dab (the repeats are timer ticks at
    /// a stationary point, and there is nothing in the argument list that
    /// says "keep depositing").
    static func stroke(_ tool: String, _ arguments: [String: Any]) -> [ActionStep] {
        step(tool, arguments, note: "Canvas: a brush stroke")
    }

    /// The paint bucket's click (Fill tool), on the layer or on a plane.
    static func fill(
        at point: CGPoint, color: NSColor, tolerance: Int, contiguous: Bool, target: String
    ) -> [ActionStep] {
        step(
            "fill",
            [
                "x": Int(point.x.rounded(.down)), "y": Int(point.y.rounded(.down)),
                "color": ActionArgs.hex(color), "tolerance": tolerance,
                "contiguous": contiguous, "layer": ActionArgs.activeLayer, "target": target,
            ],
            note: "Fill tool: click to fill")
    }

    /// The gradient tool's drag.
    static func gradient(
        from a: CGPoint, to b: CGPoint, start: NSColor, end: NSColor, radial: Bool,
        target: String
    ) -> [ActionStep] {
        step(
            "gradient",
            [
                "x0": ActionArgs.number(a.x), "y0": ActionArgs.number(a.y),
                "x1": ActionArgs.number(b.x), "y1": ActionArgs.number(b.y),
                "start_color": ActionArgs.hex(start), "end_color": ActionArgs.hex(end),
                "shape": radial ? "radial" : "linear",
                "layer": ActionArgs.activeLayer, "target": target,
            ],
            note: "Gradient tool: drag")
    }

    /// Edit ▸ Clear, and the document half of Edit ▸ Cut.
    static func clearSelection(note: String) -> [ActionStep] {
        step("clear_selection", ["layer": ActionArgs.activeLayer], note: note)
    }

    // MARK: - Described layers

    /// The Text tool's commit, from the very payload the layer is rendered
    /// from — so the recorded typography cannot drift from the committed one.
    /// `anchor` is the block's top-left in canvas pixels.
    static func addTextLayer(_ payload: TextLayerPayload, at anchor: CGPoint) -> [ActionStep] {
        var arguments = textArguments(payload)
        arguments["x"] = ActionArgs.number(anchor.x)
        arguments["y"] = ActionArgs.number(anchor.y)
        return step("add_text_layer", arguments, note: "Text tool: new text layer")
    }

    /// Re-editing an existing text layer. No `x`/`y`: a re-edit never moves
    /// the origin (the editor opens at the layer's own anchor), and the tool
    /// has no such argument.
    static func editTextLayer(_ payload: TextLayerPayload, layerNamed name: String?)
        -> [ActionStep]
    {
        var arguments = textArguments(payload)
        arguments["layer"] = ActionArgs.layer(named: name)
        return step("edit_text_layer", arguments, note: "Text tool: edit a text layer")
    }

    /// The typography both text tools share, spelled with the catalog's key
    /// names. `origin_frac` is deliberately absent: it is written only by the
    /// core's own placement and is not an argument of either tool.
    private static func textArguments(_ payload: TextLayerPayload) -> [String: Any] {
        var arguments: [String: Any] = [
            "text": payload.string,
            "font": payload.font,
            "size": ActionArgs.number(payload.size),
            "color": payload.color,
            "alignment": payload.alignment,
            "weight": payload.weight,
            "italic": payload.italic,
            "underline": payload.underline,
            "strikethrough": payload.strikethrough,
            "tracking": ActionArgs.number(payload.tracking),
            "leading": ActionArgs.number(payload.leading),
            "baseline_shift": ActionArgs.number(payload.baselineShift),
            "transform": [
                ActionArgs.number(payload.transform.a), ActionArgs.number(payload.transform.b),
                ActionArgs.number(payload.transform.c), ActionArgs.number(payload.transform.d),
            ],
        ]
        if case .width(let width) = payload.box {
            arguments["wrap_width"] = ActionArgs.number(width)
        }
        return arguments
    }

    /// The Shape tool's commit, from the payload the layer renders from.
    /// `anchor` is the shape box's top-left in canvas pixels.
    static func addShapeLayer(_ payload: ShapeLayerPayload, at anchor: CGPoint) -> [ActionStep] {
        var arguments = shapeArguments(payload)
        arguments["kind"] = payload.kind
        arguments["x"] = ActionArgs.number(anchor.x)
        arguments["y"] = ActionArgs.number(anchor.y)
        return step("add_shape_layer", arguments, note: "Shape tool: new shape layer")
    }

    /// A shape re-edit — the options bar's style, or a drag on the box. `x`
    /// and `y` ride along because a re-edit CAN move the box, unlike a text
    /// re-edit.
    static func editShapeLayer(
        _ payload: ShapeLayerPayload, at anchor: CGPoint, layerNamed name: String?
    ) -> [ActionStep] {
        var arguments = shapeArguments(payload)
        arguments["layer"] = ActionArgs.layer(named: name)
        arguments["x"] = ActionArgs.number(anchor.x)
        arguments["y"] = ActionArgs.number(anchor.y)
        return step("edit_shape_layer", arguments, note: "Shape tool: edit a shape layer")
    }

    /// The geometry and style both shape tools share. `kind` is absent —
    /// `edit_shape_layer` cannot change it, and `addShapeLayer` adds it.
    private static func shapeArguments(_ payload: ShapeLayerPayload) -> [String: Any] {
        [
            "w": ActionArgs.number(payload.w),
            "h": ActionArgs.number(payload.h),
            "flipped": payload.flipped,
            "fill": payload.fill,
            "stroke": payload.stroke,
            "stroke_width": ActionArgs.number(payload.strokeWidth),
            "radius": ActionArgs.number(payload.radius),
            "transform": [
                ActionArgs.number(payload.transform.a), ActionArgs.number(payload.transform.b),
                ActionArgs.number(payload.transform.c), ActionArgs.number(payload.transform.d),
            ],
        ]
    }

    static func addLivePhotoLayer(path: String, name: String, time: Double) -> [ActionStep] {
        step(
            "add_live_photo_layer",
            ["path": path, "name": name, "time": ActionArgs.number(time)],
            note: "Layer ▸ New ▸ Live Photo Layer…")
    }

    static func setLivePhotoFrame(time: Double, layerNamed name: String?) -> [ActionStep] {
        step(
            "set_live_photo_frame",
            ["layer": ActionArgs.layer(named: name), "time": ActionArgs.number(time)],
            note: "Layer ▸ Select Frame…")
    }

    // MARK: - Retouching

    /// The Patch tool's commit. The region has to be a POLYGON — that is
    /// what `patch_region` takes and what the tool's outline always is — so a
    /// region of any other shape records the visible placeholder instead of a
    /// step that would patch the wrong area.
    static func patchRegion(
        region: CanvasSelection, offset: CGVector, direction: String, sampleAllLayers: Bool
    ) -> [ActionStep] {
        guard case .polygon(let points) = region.shape else {
            return unrecorded("Patch")
        }
        return patchRegion(
            points: points, offset: offset, direction: direction,
            sampleAllLayers: sampleAllLayers)
    }

    static func patchRegion(
        points: [CGPoint], offset: CGVector, direction: String, sampleAllLayers: Bool
    ) -> [ActionStep] {
        step(
            "patch_region",
            [
                "layer": ActionArgs.activeLayer, "points": ActionArgs.points(points),
                "offset_x": ActionArgs.number(offset.dx),
                "offset_y": ActionArgs.number(offset.dy),
                "direction": direction, "sample_all_layers": sampleAllLayers,
            ],
            note: "Patch tool")
    }

    static func contentAwareFill(ring: Int, seed: Int, sampleAllLayers: Bool) -> [ActionStep] {
        step(
            "content_aware_fill",
            [
                "layer": ActionArgs.activeLayer, "ring": ring, "seed": seed,
                "sample_all_layers": sampleAllLayers,
            ],
            note: "Edit ▸ Content-Aware Fill…")
    }

    static func redEye(rect: CGRect, pupilSize: Double, darken: Double) -> [ActionStep] {
        step(
            "red_eye",
            [
                "layer": ActionArgs.activeLayer,
                "x": ActionArgs.number(rect.minX), "y": ActionArgs.number(rect.minY),
                "width": ActionArgs.number(rect.width),
                "height": ActionArgs.number(rect.height),
                "pupil_size": ActionArgs.number(pupilSize),
                "darken": ActionArgs.number(darken),
            ],
            note: "Red Eye tool")
    }

    /// Filters ▸ Remove Red Eye. The eyes are recorded EXPLICITLY, as the
    /// discs Vision found, rather than left for the replay to re-detect: a
    /// recording is a record of what happened, and re-running the detector
    /// on another document would silently correct different pixels. The tool
    /// takes exactly this list.
    static func redEyeAuto(eyes: [RedEye.Eye], pupilSize: Double, darken: Double)
        -> [ActionStep]
    {
        step(
            "red_eye_auto",
            [
                "layer": ActionArgs.activeLayer,
                "eyes": eyes.map {
                    [
                        "x": ActionArgs.number($0.center.x),
                        "y": ActionArgs.number($0.center.y),
                        "radius": ActionArgs.number($0.radius),
                    ]
                },
                "pupil_size": ActionArgs.number(pupilSize),
                "darken": ActionArgs.number(darken),
            ],
            note: "Filters ▸ Remove Red Eye")
    }

    // MARK: - Selection

    /// A marquee, ellipse or closed lasso, with the options bar's Feather as
    /// a SECOND step: `select_*` has no feather argument, so a one-step
    /// recording would replay a hard edge.
    static func selectShape(
        _ tool: String, _ arguments: [String: Any], mode: String, feather: Double
    ) -> [ActionStep] {
        guard let feathering = featherSteps(radius: feather, mode: mode) else {
            return unrecorded("Feathered \(mode) selection")
        }
        var arguments = arguments
        arguments["mode"] = mode
        return step(tool, arguments, note: "Canvas: a selection gesture") + feathering
    }

    /// What the options bar's Feather adds to a recorded selection gesture —
    /// or nil when the gesture cannot be recorded honestly at all, which the
    /// caller answers with the visible placeholder.
    ///
    /// **The two orders only agree in `replace` mode.** The UI feathers the
    /// NEW shape and then combines it with what was already selected
    /// (`ImageCanvasView.commitSelection`, and the wand's own commit does the
    /// same); the recorded pair replays the other way round, because
    /// `modify_selection` feathers whatever the selection has BECOME. So a
    /// ⇧-drag with Feather 10 over a crisp rectangle leaves that rectangle
    /// crisp in the session and softens it — and the seam — on replay, and a
    /// following fill or clear then fades along edges that were sharp. In
    /// `replace` mode there is nothing to combine with, so feather-then-combine
    /// and combine-then-feather are the same selection.
    static func featherSteps(radius: Double, mode: String) -> [ActionStep]? {
        guard radius > 0 else { return [] }
        guard mode == "replace" else { return nil }
        return modifySelection(operation: "feather", radius: radius)
    }

    /// Select ▸ All — a real tool (added with this phase) precisely so a
    /// recorded Select All is canvas-RELATIVE and batches correctly.
    static func selectAll(mode: String) -> [ActionStep] {
        step("select_all", ["mode": mode], note: "Select ▸ All")
    }

    static var deselect: [ActionStep] {
        step("deselect", note: "Select ▸ Deselect")
    }

    static func modifySelection(operation: String, radius: Double? = nil, width: Double? = nil)
        -> [ActionStep]
    {
        var arguments: [String: Any] = ["operation": operation]
        if let radius = radius { arguments["radius"] = ActionArgs.number(radius) }
        if let width = width { arguments["width"] = ActionArgs.number(width) }
        return step("modify_selection", arguments, note: "Select ▸ Modify")
    }

    static func selectMagicWand(
        at point: CGPoint, tolerance: Int, contiguous: Bool, mode: String
    ) -> [ActionStep] {
        step(
            "select_magic_wand",
            [
                "x": Int(point.x.rounded(.down)), "y": Int(point.y.rounded(.down)),
                "tolerance": tolerance, "contiguous": contiguous, "mode": mode,
            ],
            note: "Magic Wand")
    }

    static func selectSubject(instance: Int?, mode: String) -> [ActionStep] {
        var arguments: [String: Any] = ["mode": mode]
        if let instance = instance { arguments["instance"] = instance }
        return step("select_subject", arguments, note: "Select ▸ Select Subject")
    }

    /// Select ▸ Load Selection, and the two ⌘-click gestures that share its
    /// path. Channels travel by NAME — names survive the renumbering every
    /// channel add or delete causes, which an index does not.
    static func loadSelection(
        from source: SelectionSource, mode: String, invert: Bool, in doc: RasterDocument
    ) -> [ActionStep] {
        var arguments: [String: Any] = ["mode": mode, "invert": invert]
        switch source {
        case .channel(let index):
            guard let name = doc.channelInfo(index)?.name else {
                return unrecorded("Load Selection")
            }
            arguments["from"] = "channel"
            arguments["channel"] = name
        case .layerAlpha(let index):
            arguments["from"] = "layer_alpha"
            arguments["layer"] = ActionArgs.layer(named: doc.layerInfo(index)?.name)
        case .layerMask(let index):
            arguments["from"] = "layer_mask"
            arguments["layer"] = ActionArgs.layer(named: doc.layerInfo(index)?.name)
        case .compositePlane(let plane):
            arguments["from"] = "plane"
            arguments["plane"] = plane.agentName
        }
        return step("load_selection", arguments, note: "Select ▸ Load Selection")
    }

    /// Select ▸ Save Selection. A NEW channel is named; an existing one is
    /// combined into, by name.
    static func saveSelection(
        to destination: SelectionDestination, mode: String, in doc: RasterDocument
    ) -> [ActionStep] {
        switch destination {
        case .newChannel(let name):
            return step(
                "save_selection", ["name": name], note: "Select ▸ Save Selection (new channel)")
        case .channel(let index):
            guard let name = doc.channelInfo(index)?.name else {
                return unrecorded("Save Selection")
            }
            return step(
                "save_selection", ["channel": name, "mode": mode],
                note: "Select ▸ Save Selection")
        }
    }

    // MARK: - Channels

    static func channelCommand(_ tool: String, _ arguments: [String: Any], note: String)
        -> [ActionStep]
    {
        step(tool, arguments, note: note)
    }

    /// Image ▸ Apply Image…
    static func applyImage(_ p: ApplyImageParameters, in doc: RasterDocument) -> [ActionStep] {
        step(
            "apply_image",
            [
                "source": ActionArgs.sourceLayer(p.source, in: doc),
                "source_plane": ActionArgs.planeChoice(p.sourcePlane, in: doc),
                "invert": p.invert,
                "blend_mode": RzBlendMode.displayName(for: p.blend),
                "opacity": ActionArgs.number(p.opacity),
                "target": p.target.agentName(in: doc),
                "layer": ActionArgs.layer(named: doc.layerInfo(p.targetLayer)?.name),
            ],
            note: "Image ▸ Apply Image…")
    }

    /// Image ▸ Calculations… — the new-channel result. The SELECTION result
    /// is recorded at its own site, because it makes no undo step at all.
    static func calculations(
        _ p: CalculationsParameters, result: String, in doc: RasterDocument
    ) -> [ActionStep] {
        step(
            "calculations",
            [
                "source1": ActionArgs.sourceLayer(p.source1.layer, in: doc),
                "source1_plane": ActionArgs.planeChoice(p.source1.plane, in: doc),
                "invert1": p.source1.invert,
                "source2": ActionArgs.sourceLayer(p.source2.layer, in: doc),
                "source2_plane": ActionArgs.planeChoice(p.source2.plane, in: doc),
                "invert2": p.source2.invert,
                "blend_mode": RzBlendMode.displayName(for: p.blend),
                "opacity": ActionArgs.number(p.opacity),
                "result": result,
                "name": p.name,
            ],
            note: "Image ▸ Calculations…")
    }

    static var addLuminosityMasks: [ActionStep] {
        step("add_luminosity_masks", note: "Channels ▸ Add Luminosity Masks")
    }

    // MARK: - Guides and rulers

    static func addGuide(orientation: String, position: Double) -> [ActionStep] {
        step(
            "add_guide",
            ["orientation": orientation, "position": ActionArgs.number(position)],
            note: "View ▸ New Guide")
    }

    /// Deleting a guide names it by POSITION, not by list index: an index
    /// would delete a different guide after any earlier guide edit in the
    /// same action.
    static func removeGuide(orientation: String, position: Double) -> [ActionStep] {
        step(
            "remove_guide", ["guide": ActionArgs.guide(orientation, position)],
            note: "Canvas: drag a guide off the canvas")
    }

    /// A guide DRAG is one commit and two calls — the reason the record
    /// parameter is an ARRAY rather than a single step.
    static func moveGuide(orientation: String, from: Double, to: Double) -> [ActionStep] {
        removeGuide(orientation: orientation, position: from)
            + addGuide(orientation: orientation, position: to)
    }

    static var clearGuides: [ActionStep] {
        step("clear_guides", note: "View ▸ Clear Guides")
    }

    static func setRulerOrigin(x: Double, y: Double) -> [ActionStep] {
        step(
            "set_ruler_origin",
            ["x": ActionArgs.number(x), "y": ActionArgs.number(y)],
            note: "Rulers: drag the origin")
    }

    // MARK: - Colour management

    /// Image ▸ Assign Profile… / Convert to Profile…
    ///
    /// A built-in profile records by name. A profile the user LOADED FROM A
    /// FILE records the visible placeholder instead: `ProfileChoice.file`
    /// carries the bytes and a display name but not the path the tool would
    /// need, and inventing one would produce a step that opens the wrong
    /// file — or none — on replay.
    static func profileCommand(_ tool: String, _ choice: ProfileChoice, note: String)
        -> [ActionStep]
    {
        switch choice {
        case .builtin(let space):
            return step(
                tool, ["profile": space == .displayP3 ? "display_p3" : "srgb"], note: note)
        case .file:
            return unrecorded(note)
        }
    }

    static func setResolution(x: Double, y: Double) -> [ActionStep] {
        step(
            "set_resolution",
            ["ppi_x": ActionArgs.number(x), "ppi_y": ActionArgs.number(y)],
            note: "Image ▸ Image Size… (resolution)")
    }

    // MARK: - Free Transform

    static func transformLayer(_ transform: LayerTransform, sampler: String) -> [ActionStep] {
        step(
            "transform_layer",
            [
                "layer": ActionArgs.activeLayer,
                "pivot_x": ActionArgs.number(transform.pivot.x),
                "pivot_y": ActionArgs.number(transform.pivot.y),
                "translate_x": ActionArgs.number(transform.translation.dx),
                "translate_y": ActionArgs.number(transform.translation.dy),
                "rotate": ActionArgs.number(transform.degrees),
                "scale_x": ActionArgs.number(transform.scaleX),
                "scale_y": ActionArgs.number(transform.scaleY),
                "sampler": sampler,
            ],
            note: "Edit ▸ Free Transform")
    }

    static func distortLayer(corners: [CGPoint], sampler: String) -> [ActionStep] {
        step(
            "distort_layer",
            [
                "layer": ActionArgs.activeLayer, "corners": ActionArgs.points(corners),
                "sampler": sampler,
            ],
            note: "Edit ▸ Free Transform (perspective)")
    }
}

extension GuideOrientation {
    /// The agent's spelling — `add_guide`'s `orientation` argument, and the
    /// `$guide` symbol's. Here for the same reason `SelectionCombineMode`'s
    /// is: it is a fact about the catalog's vocabulary.
    var agentName: String { self == .horizontal ? "horizontal" : "vertical" }
}

extension SelectionCombineMode {
    /// The agent's spelling of a combine mode — the `mode` argument every
    /// `select_*`, `load_selection` and `save_selection` call takes.
    ///
    /// It lives here rather than on the enum because it is a fact about the
    /// CATALOG, not about the selection model, and the vocabulary file is
    /// where the catalog's spellings are reviewed in one pass.
    var agentName: String {
        switch self {
        case .replace: return "replace"
        case .add: return "add"
        case .subtract: return "subtract"
        case .intersect: return "intersect"
        }
    }
}

// MARK: - Argument spellings

/// The small shared spellings every factory above uses: the three symbol
/// forms, points, colours and numbers.
enum ActionArgs {
    /// "whatever layer is active on the replay document" — the default for
    /// the `layer`/`index` argument of 43 tools, and the one symbol that can
    /// never fail to resolve.
    static let activeLayer: [String: Any] = ["$layer": "active"]

    /// "the replay document's own layer selection" — for the nine tools that
    /// take a `layers` array.
    static let selectedLayers: [String: Any] = ["$layers": "selected"]

    /// A layer the user picked explicitly, by name. A nil name (a layer that
    /// could not be read at record time) degrades to the active layer rather
    /// than recording a symbol that can never resolve.
    static func layer(named name: String?) -> [String: Any] {
        guard let name = name, !name.isEmpty else { return activeLayer }
        return ["$layer": name]
    }

    /// An Apply Image / Calculations source: "merged", or the layer by name
    /// (the tools read an integer, and a `$layer` symbol resolves to one).
    static func sourceLayer(_ index: Int?, in doc: RasterDocument) -> Any {
        guard let index = index else { return "merged" }
        return layer(named: doc.layerInfo(index)?.name)
    }

    /// A source-plane choice as `apply_image` / `calculations` spell it.
    static func planeChoice(_ choice: PlaneChoice, in doc: RasterDocument) -> String {
        switch choice {
        case .rgb: return "rgb"
        case .plane(let plane): return plane.agentName
        case .channel(let index): return doc.channelInfo(index)?.name ?? "rgb"
        }
    }

    static func guide(_ orientation: String, _ position: Double) -> [String: Any] {
        ["$guide": ["orientation": orientation, "position": number(position)]]
    }

    /// A colour as the AUTHORED sRGB hex both `AgentServer.parseColor` and
    /// the app's colour wells mean — never the document's own numbers, which
    /// are what the same colour looks like in whatever profile is assigned.
    static func hex(_ color: NSColor) -> String {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        let byte: (CGFloat) -> UInt8 = { UInt8(max(0, min(255, ($0 * 255).rounded()))) }
        return RasterImage.hexString(
            (
                r: byte(srgb.redComponent), g: byte(srgb.greenComponent),
                b: byte(srgb.blueComponent), a: byte(srgb.alphaComponent)
            ))
    }

    /// A canvas polyline as the `[[x, y], …]` every stroke tool parses.
    static func points(_ points: [CGPoint]) -> [[Double]] {
        points.map { [number($0.x), number($0.y)] }
    }

    /// A coordinate or amount, rounded to 4 decimals.
    ///
    /// Two reasons, both about the FILE rather than the pixels: a raw
    /// `CGFloat` writes 17 significant digits into the JSON, which makes a
    /// recorded stroke unreadable in the editor and enormous on disk; and a
    /// quarter of a thousandth of a pixel is far below anything a gesture or
    /// a slider can mean. It is the same quantization the layer-style writer
    /// applies for the same reason.
    static func number<T: BinaryFloatingPoint>(_ value: T) -> Double {
        let double = Double(value)
        guard double.isFinite else { return 0 }
        return (double * 10000).rounded() / 10000
    }
}

// MARK: - Facts about the catalog the Actions feature needs

/// The three small classifications of catalog tools that the recorder, the
/// player and the menus ask for, plus the one-line display name the Actions
/// window and the Repeat Last menu item show.
///
/// It lives beside the vocabulary deliberately: every set here is a
/// statement about the SAME tool names the factories above emit, and keeping
/// them in one file is what makes a review of both possible in one pass.
enum ActionCatalogFacts {
    /// What Filters ▸ Repeat Last (⌃F) can repeat: the destructive filter
    /// and adjustment family, and nothing else.
    ///
    /// Adjustment LAYERS are excluded on purpose — they are non-destructive
    /// and they stack, so "repeat" for them would mean "make a second one",
    /// which is not what the command promises.
    static let repeatableTools: Set<String> = [
        "apply_filter", "auto_tone", "auto_contrast", "auto_color",
    ]

    /// The repeatable tools that take a `target` — the plane, the channel or
    /// the layer an edit lands on.
    ///
    /// ⌃F re-aims a latched step at the document's CURRENT ambient target
    /// (`EditorViewController.repeatLastFilter`), and this is the half of
    /// `repeatableTools` it can do that to. The other three take no `target`
    /// at all, which is why a repeat of one is refused outright while a plane
    /// or a channel is selected rather than silently running over the whole
    /// layer.
    static let targetedRepeatableTools: Set<String> = ["apply_filter"]

    /// Tools a recording deliberately drops: they read, they undo, they
    /// write a file, they OPEN one, or they are the Actions machinery
    /// itself. Recording any of them would put a step in the action that
    /// changes no picture — and recording `run_action` inside a recording
    /// would nest a replay.
    ///
    /// `open_document` is here because a step that CREATES a document is
    /// meaningless in an action: an action is by definition replayed on a
    /// document that already exists and, in Batch, on a different file every
    /// time. A session that began by opening a file — the normal shape, and
    /// the one `start_recording`'s own catalog text advertises — otherwise
    /// baked that absolute path in as step 1, so every replay popped the
    /// recorded file open as a second visible document beside the run's real
    /// target, and every Batch file did it again; once the recorded file had
    /// moved, step 1 threw and the default `on_error: "stop"` failed all 200
    /// files without writing anything. A deliberate open inside an action is
    /// still possible — `Action.decode` accepts the step — it just may not
    /// arrive as a recording artefact.
    static let nonRecordable: Set<String> = [
        "list_documents", "get_document", "render", "sample_color", "sample_pixel",
        "histogram", "get_color_profile", "get_metadata", "list_channels", "list_guides",
        "undo", "redo", "save_copy", "open_document",
        "list_actions", "run_action", "save_action", "delete_action",
        "start_recording", "stop_recording",
    ]

    /// ADVISORY only, and never a failure: tools whose result depends on
    /// there being a selection. The Actions window annotates these rows so a
    /// reader can see why a step behaved differently on another document.
    ///
    /// It is not a pre-check. The four tools that genuinely REQUIRE a
    /// selection — `clear_selection`, `modify_selection`, `save_selection`,
    /// `content_aware_fill` — already throw their own in-band error with a
    /// better message than the player could invent, and that error becomes
    /// the step's failure through the ordinary path. `layer_via_copy` and
    /// `layer_via_cut` are here for the opposite reason: with no selection
    /// they copy the WHOLE layer and say so in a note, so annotating them is
    /// the only warning a reader gets.
    static let selectionSensitive: Set<String> = [
        "clear_selection", "modify_selection", "save_selection", "content_aware_fill",
        "layer_via_copy", "layer_via_cut", "fill", "gradient", "add_adjustment_layer",
        "add_layer_mask", "crop",
    ]

    /// A one-line human name for a step: the tool, plus the one argument
    /// that says WHICH one it is. Shown in the Actions window's rows and in
    /// the Repeat Last menu item's title.
    static func displayName(for tool: String, arguments: [String: Any]) -> String {
        if tool == ActionStep.unrecordedTool {
            return arguments["action"] as? String ?? "an unrecorded command"
        }
        // The tools whose identity lives in an argument rather than in their
        // name — a bare "apply_filter" tells a reader nothing.
        let discriminator: String?
        switch tool {
        case "apply_filter": discriminator = arguments["filter"] as? String
        case "add_adjustment_layer", "edit_adjustment_layer": discriminator =
            arguments["op"] as? String
        case "modify_selection": discriminator = arguments["operation"] as? String
        case "rotate": discriminator = (arguments["degrees"] as? NSNumber).map { "\($0)°" }
        case "flip", "arrange_layer": discriminator =
            (arguments["axis"] ?? arguments["to"]) as? String
        default: discriminator = nil
        }
        let title = tool.replacingOccurrences(of: "_", with: " ").capitalized
        guard let discriminator = discriminator else { return title }
        return "\(title): \(discriminator.replacingOccurrences(of: "_", with: " "))"
    }
}
