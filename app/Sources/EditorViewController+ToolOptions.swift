import AppKit

// The options bar's content: one ordered cluster list per tool (plus the
// Free Transform takeover), declared as OptionDescriptor bindings into
// ToolOptionsStore and the editor's live state. Priority order IS the
// list order — the bar promotes clusters left to right and folds the rest
// into the More popover, so growth is mechanical: append to the tail.
//
// The full option set from the redesign ships deliberately, including
// options no core op backs yet; those are validation-disabled here
// (`isEnabled: { false }`), never omitted, so wiring one up later is a
// binding change rather than a layout change.
extension EditorViewController {
    // Quick-pick lists for the numeric fields' chevron menus. Pixel fields
    // share one 1–64 spread, percent fields step by ten, and radius-like
    // fields double; fields with special ranges declare their own inline.
    private static let quickPx: [Double] = [1, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48, 64]
    private static let quickPercent: [Double] = [10, 20, 30, 40, 50, 60, 70, 80, 90, 100]
    private static let quickRadius: [Double] = [0, 1, 2, 4, 8, 16, 32, 64, 128]
    private static let quickTolerance: [Double] = [0, 8, 16, 32, 64, 128, 255]

    /// Rebuilds the bar for the current tool or modal session.
    func presentToolOptions() {
        let bar = optionsBar
        if isTransforming {
            bar.present(
                icon: "arrow.triangle.2.circlepath", fallback: "FT",
                title: "Free Transform", clusters: transformClusters())
            return
        }
        let tool = currentTool
        bar.present(
            icon: tool.symbol, fallback: tool.fallbackGlyph, title: tool.displayName,
            clusters: optionClusters(for: tool))
    }

    private func optionClusters(for tool: EditorTool) -> [OptionCluster] {
        switch tool {
        case .select, .ellipseSelect, .lasso, .subject:
            return selectClusters(wand: false)
        case .wand:
            return selectClusters(wand: true)
        case .crop:
            return cropClusters()
        case .move:
            return moveClusters()
        case .brush, .eraser, .clone, .dodge:
            return paintClusters(tool)
        case .fill:
            return fillClusters()
        case .gradient:
            return gradientClusters()
        case .shapeRect, .shapeEllipse, .shapeLine:
            return shapeClusters(tool)
        case .text:
            return textClusters()
        case .eyedropper:
            return eyedropperClusters()
        case .zoom, .hand:
            return viewClusters()
        }
    }

    // MARK: - Select group

    private func selectClusters(wand: Bool) -> [OptionCluster] {
        let store = ToolOptionsStore.shared
        var clusters: [OptionCluster] = [
            OptionCluster([
                OptionDescriptor(
                    id: "select.mode", overflowLabel: "Mode",
                    kind: .segmented(
                        segments: [
                            ("square.dashed", "N", "New selection"),
                            ("plus", "+", "Add to selection"),
                            ("minus", "−", "Subtract from selection"),
                            ("square.on.square.intersection.dashed", "∩", "Intersect"),
                        ],
                        get: { ToolOptionsStore.shared.select.modeIndex },
                        set: { [weak self] index in
                            ToolOptionsStore.shared.select.modeIndex = index
                            self?.syncCanvasPaintState()
                        },
                        segmentEnabled: nil)),
            ]),
            OptionCluster([
                OptionDescriptor(
                    id: "select.feather", microLabel: "Feather", overflowLabel: "Feather",
                    kind: .field(
                        width: 52, unit: " px", decimals: 0, min: 0, max: 250,
                        quick: Self.quickRadius,
                        get: { ToolOptionsStore.shared.select.feather },
                        set: { [weak self] value in
                            ToolOptionsStore.shared.select.feather = value
                            self?.syncCanvasPaintState()
                        })),
            ]),
            OptionCluster([
                OptionDescriptor(
                    id: "select.antialias", overflowLabel: "Anti-alias",
                    kind: .checkbox(
                        label: "Anti-alias",
                        get: { ToolOptionsStore.shared.select.antiAlias },
                        set: { ToolOptionsStore.shared.select.antiAlias = $0 }),
                    // Geometric selections keep exact paths; there is no AA
                    // toggle in the pipeline yet.
                    isEnabled: { false }),
            ]),
        ]
        if wand {
            clusters.append(OptionCluster([
                OptionDescriptor(
                    id: "select.tolerance", microLabel: "Tolerance", overflowLabel: "Tolerance",
                    kind: .field(
                        width: 46, unit: "", decimals: 0, min: 0, max: 255,
                        quick: Self.quickTolerance,
                        get: { ToolOptionsStore.shared.select.tolerance },
                        set: { ToolOptionsStore.shared.select.tolerance = $0 })),
                OptionDescriptor(
                    id: "select.contiguous", overflowLabel: "Contiguous",
                    kind: .checkbox(
                        label: "Contiguous",
                        get: { ToolOptionsStore.shared.select.contiguous },
                        set: { ToolOptionsStore.shared.select.contiguous = $0 })),
                OptionDescriptor(
                    id: "select.sample", overflowLabel: "Sample",
                    kind: .popup(
                        width: 110, items: ["Current layer", "All layers"],
                        get: { ToolOptionsStore.shared.select.sampleAllLayers ? 1 : 0 },
                        set: { ToolOptionsStore.shared.select.sampleAllLayers = $0 == 1 }),
                    // The wand samples the composite; per-layer sampling is
                    // not in the core op yet.
                    isEnabled: { false }),
            ]))
        }
        // Overflow tail: morphology amounts that also APPLY to the current
        // selection when committed with one on canvas.
        clusters.append(contentsOf: [
            OptionCluster([
                OptionDescriptor(
                    id: "select.grow", microLabel: "Grow", overflowLabel: "Grow / Shrink",
                    kind: .field(
                        width: 52, unit: " px", decimals: 0, min: -250, max: 250,
                        quick: [-64, -32, -16, -8, -4, -2, -1, 1, 2, 4, 8, 16, 32, 64],
                        get: { ToolOptionsStore.shared.select.growAmount },
                        set: { [weak self] value in
                            ToolOptionsStore.shared.select.growAmount = value
                            self?.applySelectionMorph { selection in
                                value >= 0
                                    ? selection.grown(by: value)
                                    : selection.shrunk(by: -value)
                            }
                        })),
                OptionDescriptor(
                    id: "select.border", microLabel: "Border", overflowLabel: "Border width",
                    kind: .field(
                        width: 52, unit: " px", decimals: 0, min: 1, max: 250,
                        quick: [1, 2, 4, 8, 16, 32, 64],
                        get: { ToolOptionsStore.shared.select.borderWidth },
                        set: { [weak self] value in
                            ToolOptionsStore.shared.select.borderWidth = value
                            self?.applySelectionMorph { $0.bordered(width: value) }
                        })),
                OptionDescriptor(
                    id: "select.smooth", microLabel: "Smooth", overflowLabel: "Smooth",
                    kind: .field(
                        width: 52, unit: " px", decimals: 0, min: 1, max: 250,
                        quick: [1, 2, 4, 8, 16, 32, 64],
                        get: { ToolOptionsStore.shared.select.smoothRadius },
                        set: { [weak self] value in
                            ToolOptionsStore.shared.select.smoothRadius = value
                            self?.applySelectionMorph { $0.smoothed(by: value) }
                        })),
            ]),
            OptionCluster([
                OptionDescriptor(
                    id: "select.quickmask", overflowLabel: "Quick Mask",
                    kind: .checkbox(
                        label: "Quick Mask",
                        get: { [weak self] in self?.canvas.quickMaskActive ?? false },
                        set: { [weak self] _ in self?.toggleQuickMask(nil) })),
                OptionDescriptor(
                    id: "select.save", overflowLabel: "Save selection",
                    kind: .button(title: "Save…", action: {}),
                    // Named selection channels aren't in the model yet.
                    isEnabled: { false }),
            ]),
        ])
        return clusters
    }

    /// A morphology field committed with a selection on canvas: apply the
    /// op to it (the field's value is remembered either way).
    private func applySelectionMorph(_ transform: (CanvasSelection) -> CanvasSelection?) {
        guard let selection = canvas.selection, !canvas.quickMaskActive else { return }
        guard let changed = transform(selection) else {
            NSSound.beep()
            return
        }
        canvas.setSelection(changed)
    }

    // MARK: - Crop

    private func cropClusters() -> [OptionCluster] {
        [
            OptionCluster([
                OptionDescriptor(
                    id: "crop.ratio", microLabel: "Ratio", overflowLabel: "Ratio",
                    kind: .popup(
                        width: 92, items: Self.cropRatios.map { $0.title },
                        get: { ToolOptionsStore.shared.crop.ratioIndex },
                        set: { [weak self] index in
                            ToolOptionsStore.shared.crop.ratioIndex = index
                            self?.cropRatioChanged()
                        })),
            ]),
            OptionCluster([
                OptionDescriptor(
                    id: "crop.w", microLabel: "W", overflowLabel: "Width",
                    kind: .field(
                        width: 58, unit: "", decimals: 0, min: 1, max: 100_000,
                        quick: [],
                        get: { [weak self] in self?.cropRectWidth ?? 0 },
                        set: { [weak self] in self?.cropRectWidth = $0 })),
                OptionDescriptor(
                    id: "crop.h", microLabel: "H", overflowLabel: "Height",
                    kind: .field(
                        width: 58, unit: "", decimals: 0, min: 1, max: 100_000,
                        quick: [],
                        get: { [weak self] in self?.cropRectHeight ?? 0 },
                        set: { [weak self] in self?.cropRectHeight = $0 })),
            ]),
            OptionCluster([
                OptionDescriptor(
                    id: "crop.straighten", microLabel: "Straighten", overflowLabel: "Straighten",
                    kind: .field(
                        width: 52, unit: "°", decimals: 1, min: -45, max: 45,
                        quick: [-45, -30, -15, -5, -1, 0, 1, 5, 15, 30, 45],
                        get: { [weak self] in self?.cropStraightenDegrees ?? 0 },
                        set: { [weak self] in self?.cropStraightenDegrees = $0 })),
            ]),
            OptionCluster([
                OptionDescriptor(
                    id: "crop.delete", overflowLabel: "Delete cropped pixels",
                    kind: .checkbox(
                        label: "Delete cropped pixels",
                        get: { ToolOptionsStore.shared.crop.deleteCroppedPixels },
                        set: { ToolOptionsStore.shared.crop.deleteCroppedPixels = $0 }),
                    // The core's crop always retains content outside the
                    // canvas (it can be revealed later by moving layers).
                    isEnabled: { false }),
            ]),
            OptionCluster([
                OptionDescriptor(
                    id: "crop.grid", microLabel: "Grid", overflowLabel: "Grid overlay",
                    kind: .popup(
                        width: 84, items: ["None", "Thirds"],
                        get: { ToolOptionsStore.shared.crop.gridIndex },
                        set: { [weak self] index in
                            ToolOptionsStore.shared.crop.gridIndex = index
                            self?.cropGridChanged()
                        })),
                OptionDescriptor(
                    id: "crop.contentaware", overflowLabel: "Content-aware fill",
                    kind: .checkbox(
                        label: "Content-aware fill",
                        get: { ToolOptionsStore.shared.crop.contentAwareFill },
                        set: { ToolOptionsStore.shared.crop.contentAwareFill = $0 }),
                    isEnabled: { false }),
                OptionDescriptor(
                    id: "crop.snap", overflowLabel: "Snap to guides",
                    kind: .checkbox(
                        label: "Snap to guides",
                        get: { ToolOptionsStore.shared.crop.snapToGuides },
                        set: { ToolOptionsStore.shared.crop.snapToGuides = $0 }),
                    // There are no guides yet.
                    isEnabled: { false }),
            ]),
        ]
    }

    // MARK: - Move

    private func moveClusters() -> [OptionCluster] {
        [
            OptionCluster([
                OptionDescriptor(
                    id: "move.autoselect", microLabel: "Auto-select", overflowLabel: "Auto-select",
                    kind: .popup(
                        width: 76, items: ["Layer", "Group"],
                        get: { ToolOptionsStore.shared.move.autoSelectIndex },
                        set: { ToolOptionsStore.shared.move.autoSelectIndex = $0 }),
                    // Move always drags the active layer today.
                    isEnabled: { false }),
            ]),
            OptionCluster([
                OptionDescriptor(
                    id: "move.transformcontrols", overflowLabel: "Show transform controls",
                    kind: .checkbox(
                        label: "Show transform controls",
                        get: { ToolOptionsStore.shared.move.showTransformControls },
                        set: { ToolOptionsStore.shared.move.showTransformControls = $0 }),
                    // Free Transform is its own modal session (⌘T).
                    isEnabled: { false }),
            ]),
            OptionCluster([
                OptionDescriptor(
                    id: "move.align", overflowLabel: "Align",
                    kind: .segmented(
                        segments: [
                            ("align.horizontal.left", "⇤", "Align left edge"),
                            ("align.horizontal.center", "↔", "Align horizontal center"),
                            ("align.horizontal.right", "⇥", "Align right edge"),
                            ("align.vertical.top", "⤒", "Align top edge"),
                            ("align.vertical.center", "↕", "Align vertical center"),
                            ("align.vertical.bottom", "⤓", "Align bottom edge"),
                        ],
                        get: { -1 },
                        set: { [weak self] index in self?.alignActiveLayer(index) },
                        segmentEnabled: nil)),
            ]),
            OptionCluster([
                OptionDescriptor(
                    id: "move.distribute", overflowLabel: "Distribute",
                    kind: .button(title: "Distribute…", action: {}),
                    isEnabled: { false }),
                OptionDescriptor(
                    id: "move.snaplayers", overflowLabel: "Snap to layers",
                    kind: .checkbox(
                        label: "Snap to layers",
                        get: { ToolOptionsStore.shared.move.snapToLayers },
                        set: { ToolOptionsStore.shared.move.snapToLayers = $0 }),
                    isEnabled: { false }),
                OptionDescriptor(
                    id: "move.nudge", microLabel: "Nudge", overflowLabel: "Nudge step",
                    kind: .field(
                        width: 52, unit: " px", decimals: 0, min: 1, max: 100,
                        quick: Self.quickPx,
                        get: { ToolOptionsStore.shared.move.nudgeStep },
                        set: { ToolOptionsStore.shared.move.nudgeStep = $0 }),
                    // Arrow nudges are 1px (Shift: 10) for now.
                    isEnabled: { false }),
            ]),
        ]
    }

    /// One of the Move tool's six align buttons: pins the active layer's
    /// extent to the canvas edge (or centers it on that axis).
    private func alignActiveLayer(_ index: Int) {
        guard let document = document, let doc = document.doc,
              let info = doc.layerInfo(document.activeLayerIndex)
        else {
            NSSound.beep()
            return
        }
        let idx = document.activeLayerIndex
        var x = info.offsetX
        var y = info.offsetY
        switch index {
        case 0: x = 0
        case 1: x = (doc.width - info.width) / 2
        case 2: x = doc.width - info.width
        case 3: y = 0
        case 4: y = (doc.height - info.height) / 2
        default: y = doc.height - info.height
        }
        document.applyEdit("Align Layer") { doc in
            doc.withLayerOffset(idx, x, y)
        }
    }

    // MARK: - Paint tools (brush, eraser, clone, dodge)

    /// The Blend option the beginning stroke composites with: the active
    /// tool's stored mode for brush and clone (the strokes that paint
    /// layer pixels), Normal for everything else. Called from
    /// onStrokeBegin, which latches it for the stroke's lifetime.
    func paintStrokeBlendMode() -> RzBlendMode {
        guard currentTool == .brush || currentTool == .clone,
              let paint = ToolOptionsStore.shared.paintOptions(for: currentTool)
        else { return RZ_BLEND_NORMAL }
        return Self.blendMode(fromStored: paint.blendIndex)
    }

    /// The stored `blendIndex` — a raw RzBlendMode value, stable across
    /// releases — as a mode; Normal for anything unrecognized.
    static func blendMode(fromStored raw: Int) -> RzBlendMode {
        guard raw >= 0, raw <= Int(UInt32.max) else { return RZ_BLEND_NORMAL }
        let mode = RzBlendMode(rawValue: UInt32(raw))
        return RzBlendMode.allBlendModes.contains { $0.0 == mode } ? mode : RZ_BLEND_NORMAL
    }

    /// The flat blend-popup row for a stored raw mode (Normal for junk).
    private static func blendListIndex(of stored: Int) -> Int {
        let mode = blendMode(fromStored: stored)
        return RzBlendMode.allBlendModes.firstIndex { $0.0 == mode } ?? 0
    }

    private func paintClusters(_ tool: EditorTool) -> [OptionCluster] {
        let read: () -> PaintToolOptions = {
            ToolOptionsStore.shared.paintOptions(for: tool) ?? PaintToolOptions()
        }
        let write: (PaintToolOptions) -> Void = {
            ToolOptionsStore.shared.setPaintOptions($0, for: tool)
        }
        var clusters: [OptionCluster] = [
            OptionCluster([
                OptionDescriptor(
                    id: "paint.preset", overflowLabel: "Preset",
                    kind: .popup(
                        width: 100, items: BrushPreset.popupItems,
                        get: { BrushPreset.matchIndex(of: read()) },
                        set: { [weak self] index in
                            // Row 0 is "Custom" — what shows when the values
                            // match no preset; picking it changes nothing.
                            guard index >= 1,
                                  BrushPreset.builtIns.indices.contains(index - 1)
                            else { return }
                            // End any live field edit FIRST: a field editor
                            // skips value refreshes while active, and its
                            // stale text would commit right back over the
                            // preset at the next blur.
                            self?.view.window?.makeFirstResponder(nil)
                            write(BrushPreset.builtIns[index - 1].applied(to: read()))
                            self?.syncCanvasPaintState()
                        })),
            ]),
            OptionCluster([
                OptionDescriptor(
                    id: "paint.size", microLabel: "Size", overflowLabel: "Size",
                    kind: .field(
                        width: 56, unit: " px", decimals: 0, min: 1, max: 200,
                        quick: Self.quickPx,
                        get: { read().size },
                        set: { [weak self] value in
                            var options = read()
                            options.size = value
                            write(options)
                            self?.syncCanvasPaintState()
                        })),
            ]),
            OptionCluster([
                OptionDescriptor(
                    id: "paint.hardness", microLabel: "Hardness", overflowLabel: "Hardness",
                    kind: .field(
                        width: 48, unit: "%", decimals: 0, min: 0, max: 100,
                        quick: [0] + Self.quickPercent,
                        get: { read().hardness },
                        set: { [weak self] value in
                            var options = read()
                            options.hardness = value
                            write(options)
                            self?.syncCanvasPaintState()
                        })),
            ]),
            OptionCluster([
                OptionDescriptor(
                    id: "paint.opacity",
                    microLabel: tool == .dodge ? "Exposure" : "Opacity",
                    overflowLabel: tool == .dodge ? "Exposure" : "Opacity",
                    kind: .field(
                        width: 52, unit: "%", decimals: 0, min: 1, max: 100,
                        quick: Self.quickPercent,
                        get: { read().opacity },
                        set: { [weak self] value in
                            var options = read()
                            options.opacity = value
                            write(options)
                            self?.syncCanvasPaintState()
                        })),
            ]),
        ]
        if tool == .dodge {
            clusters.append(OptionCluster([
                OptionDescriptor(
                    id: "paint.mode", overflowLabel: "Mode",
                    kind: .popup(
                        width: 76, items: ["Dodge", "Burn"],
                        get: { read().burn ? 1 : 0 },
                        set: { index in
                            var options = read()
                            options.burn = index == 1
                            write(options)
                        })),
                OptionDescriptor(
                    id: "paint.range", microLabel: "Range", overflowLabel: "Range",
                    kind: .popup(
                        width: 96, items: ["Shadows", "Midtones", "Highlights"],
                        get: { read().rangeIndex },
                        set: { index in
                            var options = read()
                            options.rangeIndex = index
                            write(options)
                        })),
            ]))
        }
        clusters.append(contentsOf: [
            OptionCluster([
                OptionDescriptor(
                    id: "paint.flow", microLabel: "Flow", overflowLabel: "Flow",
                    kind: .field(
                        width: 52, unit: "%", decimals: 0, min: 1, max: 100,
                        quick: Self.quickPercent,
                        get: { read().flow },
                        set: { [weak self] value in
                            var options = read()
                            options.flow = value
                            write(options)
                            self?.syncCanvasPaintState()
                        })),
                OptionDescriptor(
                    id: "paint.blend", overflowLabel: "Blend",
                    kind: .popup(
                        width: 110, items: RzBlendMode.allBlendModes.map { $0.1 },
                        get: { Self.blendListIndex(of: read().blendIndex) },
                        set: { index in
                            guard RzBlendMode.allBlendModes.indices.contains(index)
                            else { return }
                            var options = read()
                            options.blendIndex =
                                Int(RzBlendMode.allBlendModes[index].0.rawValue)
                            write(options)
                        }),
                    // Blend applies where a stroke PAINTS layer pixels. The
                    // eraser is its own composite op and dodge a retouch op,
                    // so their popups stay pinned to Normal.
                    isEnabled: { tool == .brush || tool == .clone }),
            ]),
            OptionCluster([
                OptionDescriptor(
                    id: "paint.spacing", microLabel: "Spacing", overflowLabel: "Spacing",
                    kind: .field(
                        width: 48, unit: "%", decimals: 0, min: 1, max: 200,
                        quick: Self.quickPercent + [150, 200],
                        get: { read().spacing },
                        set: { [weak self] value in
                            var options = read()
                            options.spacing = value
                            write(options)
                            self?.syncCanvasPaintState()
                        })),
                OptionDescriptor(
                    id: "paint.angle", microLabel: "Angle", overflowLabel: "Angle",
                    kind: .field(
                        width: 48, unit: "°", decimals: 0, min: -180, max: 180,
                        quick: [-135, -90, -45, 0, 45, 90, 135, 180],
                        get: { read().angle },
                        set: { [weak self] value in
                            var options = read()
                            options.angle = value
                            write(options)
                            self?.syncCanvasPaintState()
                        })),
                OptionDescriptor(
                    id: "paint.roundness", microLabel: "Round", overflowLabel: "Roundness",
                    kind: .field(
                        width: 48, unit: "%", decimals: 0, min: 1, max: 100,
                        quick: Self.quickPercent,
                        get: { read().roundness },
                        set: { [weak self] value in
                            var options = read()
                            options.roundness = value
                            write(options)
                            self?.syncCanvasPaintState()
                        })),
                OptionDescriptor(
                    id: "paint.smoothing", microLabel: "Smooth", overflowLabel: "Smoothing",
                    kind: .field(
                        width: 48, unit: "%", decimals: 0, min: 0, max: 100,
                        quick: [0] + Self.quickPercent,
                        get: { read().smoothing },
                        set: { [weak self] value in
                            var options = read()
                            options.smoothing = value
                            write(options)
                            self?.syncCanvasPaintState()
                        })),
            ]),
            OptionCluster([
                OptionDescriptor(
                    id: "paint.pressure", overflowLabel: "Pressure size",
                    kind: .checkbox(
                        label: "Pressure size",
                        get: { read().pressureSize },
                        set: { [weak self] value in
                            var options = read()
                            options.pressureSize = value
                            write(options)
                            self?.syncCanvasPaintState()
                        })),
                OptionDescriptor(
                    id: "paint.airbrush", overflowLabel: "Airbrush",
                    kind: .checkbox(
                        label: "Airbrush",
                        get: { read().airbrush },
                        set: { [weak self] value in
                            var options = read()
                            options.airbrush = value
                            write(options)
                            self?.syncCanvasPaintState()
                        })),
            ]),
        ])
        return clusters
    }

    // MARK: - Fill

    private func fillClusters() -> [OptionCluster] {
        [
            OptionCluster([
                OptionDescriptor(
                    id: "fill.contents", overflowLabel: "Contents",
                    kind: .popup(
                        width: 104, items: ["Foreground"], get: { 0 }, set: { _ in }),
                    isEnabled: { false }),
            ]),
            OptionCluster([
                OptionDescriptor(
                    id: "fill.tolerance", microLabel: "Tolerance", overflowLabel: "Tolerance",
                    kind: .field(
                        width: 46, unit: "", decimals: 0, min: 0, max: 255,
                        quick: Self.quickTolerance,
                        get: { ToolOptionsStore.shared.fill.tolerance },
                        set: { ToolOptionsStore.shared.fill.tolerance = $0 })),
                OptionDescriptor(
                    id: "fill.contiguous", overflowLabel: "Contiguous",
                    kind: .checkbox(
                        label: "Contiguous",
                        get: { ToolOptionsStore.shared.fill.contiguous },
                        set: { ToolOptionsStore.shared.fill.contiguous = $0 })),
            ]),
            OptionCluster([
                OptionDescriptor(
                    id: "fill.opacity", microLabel: "Opacity", overflowLabel: "Opacity",
                    kind: .field(
                        width: 52, unit: "%", decimals: 0, min: 1, max: 100,
                        quick: Self.quickPercent,
                        get: { ToolOptionsStore.shared.fill.opacity },
                        set: { ToolOptionsStore.shared.fill.opacity = $0 })),
                OptionDescriptor(
                    id: "fill.blend", overflowLabel: "Blend",
                    kind: .popup(
                        width: 84, items: ["Normal"], get: { 0 }, set: { _ in }),
                    isEnabled: { false }),
            ]),
            OptionCluster([
                OptionDescriptor(
                    id: "fill.samplealllayers", overflowLabel: "Sample all layers",
                    kind: .checkbox(
                        label: "Sample all layers",
                        get: { ToolOptionsStore.shared.fill.sampleAllLayers },
                        set: { ToolOptionsStore.shared.fill.sampleAllLayers = $0 }),
                    isEnabled: { false }),
                OptionDescriptor(
                    id: "fill.antialias", overflowLabel: "Anti-alias",
                    kind: .checkbox(
                        label: "Anti-alias",
                        get: { ToolOptionsStore.shared.fill.antiAlias },
                        set: { ToolOptionsStore.shared.fill.antiAlias = $0 }),
                    isEnabled: { false }),
                OptionDescriptor(
                    id: "fill.pattern", overflowLabel: "Pattern",
                    kind: .popup(width: 84, items: ["None"], get: { 0 }, set: { _ in }),
                    isEnabled: { false }),
            ]),
        ]
    }

    // MARK: - Gradient

    private func gradientClusters() -> [OptionCluster] {
        [
            OptionCluster([
                OptionDescriptor(
                    id: "gradient.preview", overflowLabel: "Gradient",
                    kind: .gradientPreview(get: { [weak self] in
                        guard let self = self else { return (.black, .white) }
                        let reverse = ToolOptionsStore.shared.gradient.reverse
                        return reverse
                            ? (self.backgroundColor, self.paintColor)
                            : (self.paintColor, self.backgroundColor)
                    })),
            ]),
            OptionCluster([
                OptionDescriptor(
                    id: "gradient.type", overflowLabel: "Type",
                    kind: .segmented(
                        segments: [
                            ("circle.lefthalf.filled", "L", "Linear"),
                            ("smallcircle.filled.circle", "R", "Radial"),
                            ("arrow.trianglehead.2.clockwise.rotate.90", "A", "Angle"),
                            ("rectangle.split.2x1", "M", "Reflected"),
                            ("diamond", "D", "Diamond"),
                        ],
                        get: { min(ToolOptionsStore.shared.gradient.typeIndex, 1) },
                        set: { ToolOptionsStore.shared.gradient.typeIndex = $0 },
                        // Only linear and radial are core ops today.
                        segmentEnabled: { $0 < 2 })),
            ]),
            OptionCluster([
                OptionDescriptor(
                    id: "gradient.opacity", microLabel: "Opacity", overflowLabel: "Opacity",
                    kind: .field(
                        width: 52, unit: "%", decimals: 0, min: 1, max: 100,
                        quick: Self.quickPercent,
                        get: { ToolOptionsStore.shared.gradient.opacity },
                        set: { ToolOptionsStore.shared.gradient.opacity = $0 })),
                OptionDescriptor(
                    id: "gradient.reverse", overflowLabel: "Reverse",
                    kind: .checkbox(
                        label: "Reverse",
                        get: { ToolOptionsStore.shared.gradient.reverse },
                        set: { ToolOptionsStore.shared.gradient.reverse = $0 })),
                OptionDescriptor(
                    id: "gradient.dither", overflowLabel: "Dither",
                    kind: .checkbox(
                        label: "Dither",
                        get: { ToolOptionsStore.shared.gradient.dither },
                        set: { ToolOptionsStore.shared.gradient.dither = $0 }),
                    isEnabled: { false }),
            ]),
            OptionCluster([
                OptionDescriptor(
                    id: "gradient.stops", microLabel: "Stops", overflowLabel: "Stops",
                    kind: .display(width: 30, get: { "2" }),
                    // Gradients are two-stop until the multi-stop editor.
                    isEnabled: { false }),
                OptionDescriptor(
                    id: "gradient.midpoint", microLabel: "Mid", overflowLabel: "Midpoint",
                    kind: .field(
                        width: 48, unit: "%", decimals: 0, min: 1, max: 99,
                        quick: [10, 20, 30, 40, 50, 60, 70, 80, 90],
                        get: { ToolOptionsStore.shared.gradient.midpoint },
                        set: { ToolOptionsStore.shared.gradient.midpoint = $0 }),
                    isEnabled: { false }),
                OptionDescriptor(
                    id: "gradient.method", overflowLabel: "Method",
                    kind: .popup(
                        width: 100, items: ["Perceptual"], get: { 0 }, set: { _ in }),
                    isEnabled: { false }),
                OptionDescriptor(
                    id: "gradient.transparency", overflowLabel: "Transparency",
                    kind: .checkbox(label: "Transparency", get: { true }, set: { _ in }),
                    isEnabled: { false }),
            ]),
        ]
    }

    // MARK: - Shapes

    private func shapeClusters(_ tool: EditorTool) -> [OptionCluster] {
        [
            OptionCluster([
                OptionDescriptor(
                    id: "shape.fill", microLabel: "Fill", overflowLabel: "Fill",
                    kind: .swatch(
                        get: { TextLayer.color(fromHex: ToolOptionsStore.shared.shape.fill)
                            ?? .clear },
                        set: { [weak self] color in
                            ToolOptionsStore.shared.shape.fill = TextLayer.hex(color)
                            self?.shapeStyleEdited()
                        }),
                    // A line is stroke only.
                    isEnabled: { tool != .shapeLine }),
            ]),
            OptionCluster([
                OptionDescriptor(
                    id: "shape.stroke", microLabel: "Stroke", overflowLabel: "Stroke",
                    kind: .swatch(
                        get: { TextLayer.color(fromHex: ToolOptionsStore.shared.shape.stroke)
                            ?? .clear },
                        set: { [weak self] color in
                            ToolOptionsStore.shared.shape.stroke = TextLayer.hex(color)
                            self?.shapeStyleEdited()
                        })),
                OptionDescriptor(
                    id: "shape.weight", overflowLabel: "Stroke weight",
                    kind: .field(
                        width: 50, unit: " px", decimals: 0, min: 0, max: 200,
                        quick: Self.quickPx,
                        get: { ToolOptionsStore.shared.shape.strokeWidth },
                        set: { [weak self] value in
                            ToolOptionsStore.shared.shape.strokeWidth = value
                            self?.shapeStyleEdited()
                        })),
            ]),
            OptionCluster([
                OptionDescriptor(
                    id: "shape.radius", microLabel: "Radius", overflowLabel: "Corner radius",
                    kind: .field(
                        width: 50, unit: " px", decimals: 0, min: 0, max: 500,
                        quick: Self.quickRadius,
                        get: { ToolOptionsStore.shared.shape.radius },
                        set: { [weak self] value in
                            ToolOptionsStore.shared.shape.radius = value
                            self?.shapeStyleEdited()
                        }),
                    // Radius only rounds rectangles.
                    isEnabled: { tool == .shapeRect }),
            ]),
            OptionCluster([
                OptionDescriptor(
                    id: "shape.pathop", overflowLabel: "Path operation",
                    kind: .popup(
                        width: 96, items: ["New layer"], get: { 0 }, set: { _ in }),
                    isEnabled: { false }),
            ]),
            OptionCluster([
                OptionDescriptor(
                    id: "shape.cornerstyle", overflowLabel: "Corner style",
                    kind: .popup(width: 84, items: ["Round"], get: { 0 }, set: { _ in }),
                    isEnabled: { false }),
                OptionDescriptor(
                    id: "shape.dash", overflowLabel: "Dash pattern",
                    kind: .popup(width: 84, items: ["None"], get: { 0 }, set: { _ in }),
                    isEnabled: { false }),
                OptionDescriptor(
                    id: "shape.alignstroke", overflowLabel: "Align stroke",
                    kind: .popup(width: 84, items: ["Center"], get: { 0 }, set: { _ in }),
                    isEnabled: { false }),
            ]),
        ]
    }

    // MARK: - Text

    private static let textWeights: [(title: String, weight: Int)] = [
        ("Light", 3), ("Regular", 5), ("Medium", 6), ("Semibold", 8), ("Bold", 9),
    ]

    /// The popup row for an NSFontManager weight: the row whose weight is
    /// NEAREST, so a description carrying a weight the popup has no row for
    /// (an agent's `weight: 7`) reads as "Medium" rather than as "Regular"
    /// while the store keeps the exact value until the user picks a row.
    /// Ties go to the lighter row (the first in the table).
    private static func textWeightRow(_ weight: Int) -> Int {
        var best = 1
        var bestDistance = Int.max
        for (index, row) in textWeights.enumerated() where abs(row.weight - weight) < bestDistance {
            best = index
            bestDistance = abs(row.weight - weight)
        }
        return best
    }

    /// A typography toggle as a ONE-cell segmented control: the cell
    /// highlights when `get` returns its index (0) and nothing when it
    /// returns −1, and `set` fires on every click, so a single cell is a
    /// button-style toggle with no new control kind (OptionSegmentedControl).
    /// The setter writes the store only: the bar's onAnyEdit →
    /// `toolOptionsEdited()` rebuilds `canvas.textStyle` from the store
    /// (`currentTextStyle`) and restyles a live session, which is the one
    /// path every text option takes.
    private func textToggle(
        id: String, symbol: String, fallback: String, label: String,
        get: @escaping () -> Bool, toggle: @escaping () -> Void
    ) -> OptionDescriptor {
        OptionDescriptor(
            id: id, overflowLabel: label,
            kind: .segmented(
                segments: [(symbol, fallback, label)],
                get: { get() ? 0 : -1 },
                set: { _ in toggle() },
                segmentEnabled: nil))
    }

    private func textClusters() -> [OptionCluster] {
        let families = NSFontManager.shared.availableFontFamilies.sorted()
        return [
            OptionCluster([
                OptionDescriptor(
                    id: "text.font", overflowLabel: "Font",
                    kind: .popup(
                        width: 150, items: families,
                        get: { [weak self] in
                            guard let self = self else { return 0 }
                            return families.firstIndex(of: self.fontFamily) ?? 0
                        },
                        set: { [weak self] index in
                            guard let self = self, families.indices.contains(index)
                            else { return }
                            self.fontFamily = families[index]
                            ToolOptionsStore.shared.text.family = families[index]
                        })),
                OptionDescriptor(
                    id: "text.weight", overflowLabel: "Weight",
                    kind: .popup(
                        width: 92, items: Self.textWeights.map { $0.title },
                        get: { Self.textWeightRow(ToolOptionsStore.shared.text.weight) },
                        set: { index in
                            guard Self.textWeights.indices.contains(index) else { return }
                            ToolOptionsStore.shared.text.weight = Self.textWeights[index].weight
                        })),
            ]),
            // The style toggles sit right after the face they modify. A
            // family without an italic member previews and commits its
            // regular face for Italic (TextStyle.nsFont) — preview and
            // commit agree by construction, so the toggle stays live.
            OptionCluster([
                textToggle(
                    id: "text.italic", symbol: "italic", fallback: "I", label: "Italic",
                    get: { ToolOptionsStore.shared.text.italic },
                    toggle: { ToolOptionsStore.shared.text.italic.toggle() }),
                textToggle(
                    id: "text.underline", symbol: "underline", fallback: "U", label: "Underline",
                    get: { ToolOptionsStore.shared.text.underline },
                    toggle: { ToolOptionsStore.shared.text.underline.toggle() }),
                textToggle(
                    id: "text.strikethrough", symbol: "strikethrough", fallback: "S",
                    label: "Strikethrough",
                    get: { ToolOptionsStore.shared.text.strikethrough },
                    toggle: { ToolOptionsStore.shared.text.strikethrough.toggle() }),
            ]),
            OptionCluster([
                OptionDescriptor(
                    id: "text.size", microLabel: "Size", overflowLabel: "Size",
                    kind: .field(
                        width: 52, unit: " pt", decimals: 0, min: 6, max: 500,
                        quick: [9, 10, 12, 14, 18, 24, 36, 48, 72, 96, 144],
                        get: { [weak self] in Double(self?.fontSize ?? 48) },
                        set: { [weak self] value in
                            self?.fontSize = CGFloat(value)
                            ToolOptionsStore.shared.text.size = value
                        })),
                // Tracking is the `.kern` attribute in px (TextToolOptions):
                // it changes line breaks, which is why the session restyles
                // its whole storage on every edit rather than just the
                // typing attributes.
                OptionDescriptor(
                    id: "text.tracking", microLabel: "Track", overflowLabel: "Tracking",
                    kind: .field(
                        width: 46, unit: "", decimals: 0,
                        min: TextToolOptions.trackingRange.lowerBound,
                        max: TextToolOptions.trackingRange.upperBound,
                        quick: [-50, -25, -10, -5, 0, 5, 10, 25, 50],
                        get: { ToolOptionsStore.shared.text.tracking },
                        set: { ToolOptionsStore.shared.text.tracking = $0 })),
            ]),
            OptionCluster([
                OptionDescriptor(
                    id: "text.align", overflowLabel: "Alignment",
                    kind: .segmented(
                        segments: [
                            ("text.alignleft", "L", "Align left"),
                            ("text.aligncenter", "C", "Align center"),
                            ("text.alignright", "R", "Align right"),
                        ],
                        get: { [weak self] in
                            Self.alignmentIndex(self?.textAlignment ?? .left)
                        },
                        set: { [weak self] index in
                            let clamped = min(max(index, 0), 2)
                            self?.textAlignment = Self.alignmentSegmentValues[clamped]
                            ToolOptionsStore.shared.text.alignmentIndex = clamped
                        },
                        segmentEnabled: nil)),
                OptionDescriptor(
                    id: "text.color", overflowLabel: "Color",
                    kind: .swatch(
                        get: { [weak self] in self?.paintColor ?? .black },
                        set: { [weak self] color in self?.setPaintColor(color) })),
            ]),
            OptionCluster([
                // Leading is the line height in pt, 0 = the font's natural
                // height (TextStyle.leading); the quick list is the classic
                // headline spread. A leading tighter than the natural height
                // overlaps lines, and the renderer keeps the ascent that
                // then rises above the block (TextLayer.layout's ink-safe
                // rect).
                OptionDescriptor(
                    id: "text.leading", microLabel: "Leading", overflowLabel: "Leading",
                    kind: .field(
                        width: 52, unit: " pt", decimals: 0,
                        min: TextToolOptions.leadingRange.lowerBound,
                        max: TextToolOptions.leadingRange.upperBound,
                        quick: [0, 12, 14, 18, 24, 36, 48, 60, 72, 96, 144],
                        get: { ToolOptionsStore.shared.text.leading },
                        set: { ToolOptionsStore.shared.text.leading = $0 })),
                // Baseline shift in px, positive raises (`.baselineOffset`).
                OptionDescriptor(
                    id: "text.baseline", microLabel: "Baseline", overflowLabel: "Baseline shift",
                    kind: .field(
                        width: 46, unit: "", decimals: 0,
                        min: TextToolOptions.baselineShiftRange.lowerBound,
                        max: TextToolOptions.baselineShiftRange.upperBound,
                        quick: [-50, -25, -10, -5, 0, 5, 10, 25, 50],
                        get: { ToolOptionsStore.shared.text.baselineShift },
                        set: { ToolOptionsStore.shared.text.baselineShift = $0 })),
                OptionDescriptor(
                    id: "text.antialias", overflowLabel: "Anti-alias",
                    kind: .popup(width: 84, items: ["Smooth"], get: { 0 }, set: { _ in }),
                    isEnabled: { false }),
                OptionDescriptor(
                    id: "text.warp", overflowLabel: "Warp",
                    kind: .popup(width: 84, items: ["None"], get: { 0 }, set: { _ in }),
                    isEnabled: { false }),
            ]),
        ]
    }

    // MARK: - Eyedropper

    private func eyedropperClusters() -> [OptionCluster] {
        [
            OptionCluster([
                OptionDescriptor(
                    id: "sample.size", microLabel: "Sample", overflowLabel: "Sample size",
                    kind: .popup(
                        width: 76, items: ["Point", "3 × 3", "5 × 5"],
                        get: { ToolOptionsStore.shared.sample.sampleSizeIndex },
                        set: { ToolOptionsStore.shared.sample.sampleSizeIndex = $0 })),
                OptionDescriptor(
                    id: "sample.from", microLabel: "From", overflowLabel: "Sample from",
                    kind: .popup(
                        width: 110, items: ["Current layer", "All layers"],
                        get: { ToolOptionsStore.shared.sample.fromIndex },
                        set: { ToolOptionsStore.shared.sample.fromIndex = $0 }),
                    // Sampling reads the flattened composite.
                    isEnabled: { false }),
            ]),
            OptionCluster([
                OptionDescriptor(
                    id: "sample.ring", overflowLabel: "Show sampling ring",
                    kind: .checkbox(
                        label: "Show sampling ring",
                        get: { ToolOptionsStore.shared.sample.showRing },
                        set: { ToolOptionsStore.shared.sample.showRing = $0 }),
                    isEnabled: { false }),
            ]),
            OptionCluster([
                OptionDescriptor(
                    id: "sample.picked", microLabel: "Picked", overflowLabel: "Picked",
                    kind: .display(
                        width: 84, get: { [weak self] in self?.lastSampleText ?? "—" })),
            ]),
            OptionCluster([
                OptionDescriptor(
                    id: "sample.copy", overflowLabel: "Copy on pick",
                    kind: .checkbox(
                        label: "Copy on pick",
                        get: { ToolOptionsStore.shared.sample.copyOnPick },
                        set: { ToolOptionsStore.shared.sample.copyOnPick = $0 })),
                OptionDescriptor(
                    id: "sample.recent", overflowLabel: "Recent swatches",
                    kind: .display(width: 30, get: { "—" }),
                    isEnabled: { false }),
            ]),
        ]
    }

    // MARK: - View (zoom / hand)

    private func viewClusters() -> [OptionCluster] {
        [
            OptionCluster([
                OptionDescriptor(
                    id: "view.fit", overflowLabel: "Fit",
                    kind: .button(title: "Fit", action: { [weak self] in self?.zoomToFit() })),
                OptionDescriptor(
                    id: "view.actual", overflowLabel: "100%",
                    kind: .button(title: "100%", action: { [weak self] in self?.zoomActual() })),
                OptionDescriptor(
                    id: "view.fill", overflowLabel: "Fill",
                    kind: .button(title: "Fill", action: { [weak self] in self?.zoomToFill() })),
            ]),
            OptionCluster([
                OptionDescriptor(
                    id: "view.zoom", microLabel: "Zoom", overflowLabel: "Zoom",
                    kind: .field(
                        width: 56, unit: "%", decimals: 0, min: 2, max: 3200,
                        quick: [25, 50, 100, 200, 400, 800, 1600, 3200],
                        get: { [weak self] in self?.zoomPercent ?? 100 },
                        set: { [weak self] in self?.zoomPercent = $0 })),
            ]),
            OptionCluster([
                OptionDescriptor(
                    id: "view.scrubby", overflowLabel: "Scrubby zoom",
                    kind: .checkbox(
                        label: "Scrubby zoom",
                        get: { ToolOptionsStore.shared.view.scrubbyZoom },
                        set: { [weak self] value in
                            ToolOptionsStore.shared.view.scrubbyZoom = value
                            self?.syncCanvasPaintState()
                        })),
            ]),
            OptionCluster([
                OptionDescriptor(
                    id: "view.rulers", overflowLabel: "Rulers",
                    kind: .checkbox(
                        label: "Rulers",
                        get: { ToolOptionsStore.shared.view.rulers },
                        set: { ToolOptionsStore.shared.view.rulers = $0 }),
                    isEnabled: { false }),
                OptionDescriptor(
                    id: "view.guides", overflowLabel: "Guides",
                    kind: .checkbox(
                        label: "Guides",
                        get: { ToolOptionsStore.shared.view.guides },
                        set: { ToolOptionsStore.shared.view.guides = $0 }),
                    isEnabled: { false }),
                OptionDescriptor(
                    id: "view.pixelgrid", overflowLabel: "Pixel grid",
                    kind: .popup(
                        width: 76, items: ["Auto", "On", "Off"],
                        get: { ToolOptionsStore.shared.view.pixelGridIndex },
                        set: { ToolOptionsStore.shared.view.pixelGridIndex = $0 }),
                    isEnabled: { false }),
            ]),
        ]
    }

    // MARK: - Free Transform takeover

    private func transformClusters() -> [OptionCluster] {
        [
            OptionCluster([
                OptionDescriptor(
                    id: "transform.angle", microLabel: "Angle", overflowLabel: "Angle",
                    kind: .field(
                        width: 56, unit: "°", decimals: 2, min: -360, max: 360,
                        quick: [-90, -45, -30, -15, 0, 15, 30, 45, 90, 180],
                        get: { [weak self] in self?.transformDegrees ?? 0 },
                        set: { [weak self] in self?.transformDegrees = $0 })),
            ]),
            OptionCluster([
                OptionDescriptor(
                    id: "transform.scalex", microLabel: "Scale X", overflowLabel: "Scale X",
                    kind: .field(
                        width: 60, unit: "%", decimals: 2,
                        min: -Self.maxScalePercent, max: Self.maxScalePercent,
                        quick: [25, 50, 75, 100, 150, 200],
                        get: { [weak self] in self?.transformScaleXPercent ?? 100 },
                        set: { [weak self] in self?.transformScaleXPercent = $0 })),
                OptionDescriptor(
                    id: "transform.scaley", microLabel: "Y", overflowLabel: "Scale Y",
                    kind: .field(
                        width: 60, unit: "%", decimals: 2,
                        min: -Self.maxScalePercent, max: Self.maxScalePercent,
                        quick: [25, 50, 75, 100, 150, 200],
                        get: { [weak self] in self?.transformScaleYPercent ?? 100 },
                        set: { [weak self] in self?.transformScaleYPercent = $0 })),
            ]),
            OptionCluster([
                OptionDescriptor(
                    id: "transform.w", microLabel: "W", overflowLabel: "Width",
                    kind: .field(
                        width: 58, unit: "", decimals: 0, min: 1, max: 100_000_000,
                        quick: [],
                        get: { [weak self] in self?.transformWidthPixels ?? 0 },
                        set: { [weak self] in self?.transformWidthPixels = $0 })),
                OptionDescriptor(
                    id: "transform.h", microLabel: "H", overflowLabel: "Height",
                    kind: .field(
                        width: 58, unit: "", decimals: 0, min: 1, max: 100_000_000,
                        quick: [],
                        get: { [weak self] in self?.transformHeightPixels ?? 0 },
                        set: { [weak self] in self?.transformHeightPixels = $0 })),
            ]),
            OptionCluster([
                OptionDescriptor(
                    id: "transform.sampler", microLabel: "Sampler", overflowLabel: "Sampler",
                    kind: .popup(
                        width: 170, items: Self.transformSamplers.map { $0.title },
                        get: { [weak self] in self?.transformSamplerListIndex ?? 0 },
                        set: { [weak self] in self?.transformSamplerListIndex = $0 })),
            ]),
        ]
    }
}
