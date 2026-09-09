import AppKit

/// The editor's half of Actions: the validation table for every menu item
/// the phase adds, and the two record helpers whose inputs only the editor
/// has (a Free Transform session, and the latched stroke).
///
/// The validation table follows `EditorViewController+Locks.swift`'s
/// contract: ONE method, returning `Bool?` — nil for "not one of mine" — so
/// the frozen `validateUserInterfaceItem` gains one early-out line rather
/// than a case per item.
extension EditorViewController {
    /// Enablement and titles for the phase's own menu items. nil when the
    /// item belongs to somebody else.
    ///
    /// Only ⌃F lives here; the four File ▸ Automate items and the command
    /// palette are on `AppDelegate`, because
    /// `validateUserInterfaceItem` returns false at its first line when
    /// there is no document and all five must work with none open.
    func validateActionsItem(_ item: NSValidatedUserInterfaceItem) -> Bool? {
        guard item.action == #selector(repeatLastFilter(_:)) else { return nil }
        let step = ActionRecorder.shared.lastRepeatable
        if let menuItem = item as? NSMenuItem {
            menuItem.title = Self.repeatTitle(for: step)
        }
        guard step != nil, document?.doc != nil else { return false }
        // ⌃F is a TEXT-EDITING hazard and is handled exactly as Edit ▸ Clear's
        // bare ⌫ is: NSTextView binds ⌃F to `moveForward:`, and a menu key
        // equivalent is resolved AHEAD of the first responder, so an enabled
        // item would swallow every Control-F typed into the options bar, a
        // layer-name field or the assistant's input. Disabled while a canvas
        // text session is open and while the field editor is first responder,
        // which is the union of those cases.
        //
        // The responder is read off the KEY window, not off this controller's
        // own: the command palette is a borderless `NSPanel` that becomes key
        // while the document window stays MAIN, so `NSApp.target(forAction:)`
        // still resolves ⌃F to this controller and this controller's own
        // first responder is still the canvas. Asking the editor's window
        // alone therefore enabled the item — and swallowed the ⌃F — while the
        // caret sat in the palette's query field, which is the exact trap the
        // guard exists for. Both windows are asked, so a field editor in
        // either one disables it.
        guard !canvas.hasActiveTextSession else { return false }
        for window in [NSApp.keyWindow, view.window] {
            if let responder = window?.firstResponder as? NSText, responder.isFieldEditor {
                return false
            }
        }
        return true
    }

    // MARK: - Record helpers the editor owns

    /// What a Free Transform commit records.
    ///
    /// A single-layer affine is a real `transform_layer` built from the
    /// session's own parameters (pivot, translation, degrees, the two
    /// scales) — the very values `transform_layer` reassembles into a
    /// `LayerTransform`, so the replay composes the identical matrix. A
    /// warped box becomes `distort_layer` with the warped quad in canvas
    /// coordinates. A SET has no twin at all: both tools transform one layer
    /// (a group and its links excepted), and there is no multi-layer form.
    func transformRecord(_ session: TransformSession, quad: [CGPoint]?) -> [ActionStep] {
        guard session.isSingleLayer else { return .unrecorded("Transform Layers") }
        let sampler = Self.samplerAgentName(session.sampler)
        if let quad = quad {
            return .distortLayer(corners: quad, sampler: sampler)
        }
        return .transformLayer(session.transform, sampler: sampler)
    }

    /// The resampling filter as `transform_layer` / `distort_layer` spell it.
    /// The catalog accepts two spellings for two of them; this writes the
    /// canonical one `AgentServer.transformSamplers` reports back.
    static func samplerAgentName(_ filter: RzResizeFilter) -> String {
        switch filter {
        case RZ_FILTER_NEAREST: return "nearest"
        case RZ_FILTER_BILINEAR: return "bilinear"
        case RZ_FILTER_LANCZOS3: return "lanczos"
        default: return "bicubic"
        }
    }

    /// What a paint or retouch stroke records, built from the canvas's
    /// latched tip and the flattened vertices it actually dabbed along.
    ///
    /// The vertices are the SAME polyline the canvas rendered — the spline
    /// is flattened into vertex spans before any dab is stamped — and the
    /// agent's stroke tools walk a caller's polyline through the identical
    /// `SoftBrush` engine, so a replay lands the same dabs in the same
    /// places. Two honest losses, both catalogue limits: pressure is
    /// flattened to the tip's own size (no stroke tool takes per-point
    /// pressure) and an airbrush hold replays as a single dab. A third, for
    /// a very long stroke only: the polyline is thinned to the stroke tools'
    /// own point limit (`recordablePoints`).
    func strokeRecord(_ actionName: String) -> [ActionStep] {
        let points = Self.recordablePoints(canvas.recordedStrokePoints)
        guard points.count >= 1 else { return .notACommand }
        let tip = canvas.strokeTip
        let target = strokeTarget.agentName(in: document?.doc)
        var arguments: [String: Any] = [
            "layer": ActionArgs.activeLayer,
            "points": ActionArgs.points(points),
            "size": ActionArgs.number(canvas.brushSize),
            "hardness": ActionArgs.number(tip.hardness * 100),
            "flow": ActionArgs.number(max(tip.flow * 100, 1)),
            "spacing": ActionArgs.number(tip.spacingPercent),
            "angle": ActionArgs.number(tip.angleDegrees),
            "roundness": ActionArgs.number(max(tip.roundness * 100, 1)),
        ]
        switch strokeTool {
        case .brush:
            arguments["opacity"] = ActionArgs.number(canvas.brushOpacity)
            arguments["color"] = ActionArgs.hex(canvas.paintColor)
            arguments["target"] = target
            // Only for a LAYER stroke. A mask, a colour plane and a channel
            // are coverage, not colour, and `brush_stroke` refuses a
            // blend_mode on one outright ("blend_mode does not apply to a
            // mask stroke") — so writing it unconditionally made every
            // recorded mask stroke, the commonest coverage gesture there is,
            // a step that could never replay. The eraser case below omits it
            // for the same kind of reason.
            if !strokeTarget.isCoverage {
                arguments["blend_mode"] = RzBlendMode.displayName(for: strokeBlendMode)
            }
            return .stroke("brush_stroke", arguments)
        case .eraser:
            arguments["opacity"] = ActionArgs.number(canvas.brushOpacity)
            arguments["target"] = target
            // eraser_stroke refuses a blend_mode by design (erasing removes
            // alpha), so it is not written even though the tip carries one.
            return .stroke("eraser_stroke", arguments)
        case .clone:
            guard let source = canvas.strokeCloneSource else { return .unrecorded("Clone Stamp") }
            arguments["opacity"] = ActionArgs.number(canvas.brushOpacity)
            arguments["source_x"] = ActionArgs.number(source.x)
            arguments["source_y"] = ActionArgs.number(source.y)
            arguments["blend_mode"] = RzBlendMode.displayName(for: strokeBlendMode)
            return .stroke("clone_stamp", arguments)
        case .dodge:
            let options = ToolOptionsStore.shared.dodge
            arguments["burn"] = options.burn
            arguments["exposure"] = ActionArgs.number(options.opacity)
            arguments["range"] = Self.dodgeRangeNames[
                min(max(options.rangeIndex, 0), Self.dodgeRangeNames.count - 1)]
            return .stroke("dodge_burn", arguments)
        case .heal:
            guard let source = canvas.strokeCloneSource else {
                return .unrecorded("Healing Brush")
            }
            let options = ToolOptionsStore.shared.heal
            // `flow` is REFUSED by heal_stroke, not ignored — the solve runs
            // over the stroke's coverage, so a flowed-down dab would leave it
            // nothing to work on, and the canvas latches flow to 1 for these
            // two tools for the same reason. Inheriting the shared tip
            // dictionary's key made every recorded healing stroke a step that
            // failed on the first replay.
            arguments.removeValue(forKey: "flow")
            // heal_stroke's opacity is the heal's STRENGTH in percent (1-100),
            // not the 0-1 alpha brush_stroke takes: the overlay is coverage
            // and the strength lives in the op.
            arguments["opacity"] = ActionArgs.number(min(max(options.opacity, 1), 100))
            arguments["source_x"] = ActionArgs.number(source.x)
            arguments["source_y"] = ActionArgs.number(source.y)
            arguments["sample_all_layers"] = options.sampleAllLayers
            return .stroke("heal_stroke", arguments)
        case .spotHeal:
            let options = ToolOptionsStore.shared.spotHeal
            // Refused here too, for the reason the .heal case gives.
            arguments.removeValue(forKey: "flow")
            // Percent, like heal_stroke's.
            arguments["opacity"] = ActionArgs.number(min(max(options.opacity, 1), 100))
            arguments["sample_all_layers"] = options.sampleAllLayers
            // The tool exposes neither dial; the commit passes 0 for both
            // (EditorViewController+Heal), and a replay must do the same or
            // it would inpaint with a different ring and a different seed.
            arguments["ring"] = 0
            arguments["seed"] = 0
            return .stroke("spot_heal_stroke", arguments)
        default:
            return .unrecorded(actionName)
        }
    }

    /// `dodge_burn`'s `range` vocabulary, in the options bar's segment order.
    private static let dodgeRangeNames = ["shadows", "midtones", "highlights"]

    /// The most points a recorded stroke may carry — the stroke tools' own
    /// limit (`AgentServer.parsePoints`: "Too many points (10,000 max)").
    private static let maxRecordedStrokePoints = 10_000

    /// `points` thinned, uniformly and keeping both ends, to something the
    /// stroke tools will accept.
    ///
    /// The canvas flattens a spline at roughly one vertex per 1.5 px of arc
    /// and appends every one of them, so a path longer than ~15,000 px — three
    /// diagonal sweeps across a 4000 px canvas — produced more points than
    /// any stroke tool takes: the step was ~200 KB of JSON that failed on its
    /// first replay and, with the default `on_error: "stop"`, took the rest
    /// of the action down with it. Thinning is the honest repair rather than
    /// a refusal to record: the flattening step is far below the dab spacing
    /// of any tip, so the same dabs land in the same places.
    static func recordablePoints(_ points: [CGPoint]) -> [CGPoint] {
        guard points.count > maxRecordedStrokePoints else { return points }
        // One less than the cap, so re-adding the final point cannot push the
        // result back over it.
        let step = Int(
            (Double(points.count) / Double(maxRecordedStrokePoints - 1)).rounded(.up))
        var thinned: [CGPoint] = []
        thinned.reserveCapacity(maxRecordedStrokePoints)
        var index = 0
        while index < points.count {
            thinned.append(points[index])
            index += step
        }
        if let last = points.last, thinned.last != last { thinned.append(last) }
        return thinned
    }

    // MARK: - The rest of the editor's record builders

    /// A one-shot filter step with the ambient plane target written out.
    /// Every Filters-menu command goes through this rather than naming its
    /// target itself.
    func filterRecord(_ name: String, _ extra: [String: Any] = [:]) -> [ActionStep] {
        .filter(name, extra, target: paintTarget.layerEditAgentName(in: document?.doc))
    }

    /// The Fill tool's click, from the options it actually used. The colour
    /// is the AUTHORED one with the bar's opacity folded into its alpha,
    /// which is exactly what the tool itself passes to the core.
    func fillRecord(
        at point: CGPoint, color: NSColor, opacity: Double, options: FillToolOptions
    ) -> [ActionStep] {
        .fill(
            at: point,
            color: color.withAlphaComponent(color.alphaComponent * CGFloat(opacity)),
            tolerance: Int(options.tolerance.rounded()), contiguous: options.contiguous,
            target: paintTarget.layerEditAgentName(in: document?.doc))
    }

    /// The Gradient tool's drag. Reverse swaps the two swatches, and the
    /// bar's opacity rides in both colours' alpha — the same two rules the
    /// commit itself applies.
    func gradientRecord(
        from a: CGPoint, to b: CGPoint, foreground: NSColor, background: NSColor,
        opacity: CGFloat, options: GradientToolOptions
    ) -> [ActionStep] {
        let fade: (NSColor) -> NSColor = { $0.withAlphaComponent($0.alphaComponent * opacity) }
        return .gradient(
            from: a, to: b,
            start: fade(options.reverse ? background : foreground),
            end: fade(options.reverse ? foreground : background),
            radial: options.typeIndex == 1,
            target: paintTarget.layerEditAgentName(in: document?.doc))
    }

    /// The `rotate` or `flip` step a whole-document geometry command is.
    /// `.resize` never reaches here — Image Size records its own two steps —
    /// so it answers with the visible placeholder rather than a wrong tool.
    static func geometryRecord(_ op: DocumentGeometry) -> [ActionStep] {
        switch op {
        case .rotate90: return .rotate(90)
        case .rotate180: return .rotate(180)
        case .rotate270: return .rotate(270)
        case .flipHorizontal: return .flip("horizontal")
        case .flipVertical: return .flip("vertical")
        case .resize: return .unrecorded(op.actionName)
        }
    }

    /// `add_layer_mask`'s `kind` vocabulary.
    static func layerMaskKindName(_ kind: RzMaskKind) -> String {
        switch kind {
        case RZ_MASK_HIDE_ALL: return "hide_all"
        case RZ_MASK_FROM_SELECTION: return "from_selection"
        default: return "reveal_all"
        }
    }

    /// What a finished Move gesture records. The drag's ticks already moved
    /// the layers, so the offsets in the document ARE the result and the
    /// deltas are zero; one layer becomes an absolute `set_layer_properties`
    /// that says so in its note, and a set has no twin at all.
    static func moveEndRecord(_ document: ImageDocument) -> [ActionStep] {
        guard let doc = document.doc else { return .notACommand }
        return moveRecord(doc, document.selectedLayerIndices, dx: 0, dy: 0)
    }
}
