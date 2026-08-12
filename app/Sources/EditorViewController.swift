import AppKit

/// What brush and eraser edit on the active layer: its pixels, or its layer
/// mask. Pure UI state owned by EditorViewController — not undoable, not
/// persisted, and reset to `.layer` whenever the active layer changes, its
/// mask goes away, or the document is replaced.
enum PaintTarget {
    case layer
    case mask
}

final class EditorViewController: NSViewController {
    // Not private: the per-feature extension files (EditorViewController+…)
    // are handlers of this controller and need the document they act on.
    weak var document: ImageDocument?

    private let scrollView = NSScrollView()
    // Not private, like `document` above: the extension files need the two
    // things every editor command works against.
    let canvas = ImageCanvasView()
    private var didRunInitialZoom = false

    // Design chrome: 58px toolbar, floating zoom pill, 30px status bar with
    // border-separated mono segments.
    private var toolPill: ToolPillControl!
    private let toolbarBar = BarView(border: .bottom)
    private let zoomPill = ZoomPillView(frame: .zero)
    private let statusDims = StatusSegment(separator: false)
    private let statusLayer = StatusSegment(separator: true)
    private let statusBlend = StatusSegment(separator: true)
    private let statusTool = StatusSegment(separator: false)
    private let statusZoom = StatusSegment(separator: true)

    private(set) var currentTool: EditorTool = .select

    // Options bar (between the window content top and the scroll view).
    private let optionsBar = NSStackView()
    private let sizeLabel = NSTextField(labelWithString: "Size")
    private let sizeSlider = NSSlider(value: 24, minValue: 1, maxValue: 200, target: nil, action: nil)
    private let sizeField = NSTextField(string: "24")
    private let opacityLabel = NSTextField(labelWithString: "Opacity")
    private let opacitySlider = NSSlider(
        value: 1.0, minValue: 0.05, maxValue: 1.0, target: nil, action: nil)
    private let opacityValueLabel = NSTextField(labelWithString: "100%")
    private let colorWell = NSColorWell()
    private let fontLabel = NSTextField(labelWithString: "Font")
    private let fontPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let fontSizeField = NSTextField(string: "48")
    private let alignmentControl = NSSegmentedControl(frame: .zero)
    private let toleranceLabel = NSTextField(labelWithString: "Tolerance")
    private let toleranceSlider = NSSlider(
        value: 32, minValue: 0, maxValue: 255, target: nil, action: nil)
    private let toleranceValueLabel = NSTextField(labelWithString: "32")
    private let contiguousCheck = NSButton(
        checkboxWithTitle: "Contiguous", target: nil, action: nil)
    private let gradientShapePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let gradientEndLabel = NSTextField(labelWithString: "End")
    private let gradientEndWell = NSColorWell()
    // Eyedropper readout: a swatch of the last sampled color plus its hex
    // and R G B A values. Display only — the sample itself lands in the
    // shared paint color.
    private let sampleSwatch = NSBox()
    private let sampleValueLabel = NSTextField(labelWithString: "Click to sample")
    // Free Transform: numerics bound both ways to the session's parameters,
    // plus the sampler the single commit-time resample will use.
    private let transformAngleLabel = NSTextField(labelWithString: "Angle°")
    private let transformAngleField = NSTextField(string: "0")
    private let transformScaleXLabel = NSTextField(labelWithString: "Scale X%")
    private let transformScaleXField = NSTextField(string: "100")
    private let transformScaleYLabel = NSTextField(labelWithString: "Y%")
    private let transformScaleYField = NSTextField(string: "100")
    private let transformSizeLabel = NSTextField(labelWithString: "W")
    private let transformSizeWField = NSTextField(string: "0")
    private let transformSizeHLabel = NSTextField(labelWithString: "H")
    private let transformSizeHField = NSTextField(string: "0")
    private let transformSamplerLabel = NSTextField(labelWithString: "Sampler")
    private let transformSamplerPopup = NSPopUpButton(frame: .zero, pullsDown: false)

    /// Magic wand / bucket fill color tolerance (max per-channel diff).
    private var tolerance = 32
    private var scrollTopToRoot: NSLayoutConstraint!
    private var scrollTopToOptions: NSLayoutConstraint!

    // Right panel (Layers/Assistant tabs, toggled by View > Show/Hide Layers).
    private var layersPanel: LayersPanelViewController!
    private var assistantPanel: AssistantPanelViewController!
    private var panelSeparator: NSBox!
    private var scrollTrailingToRoot: NSLayoutConstraint!
    private var scrollTrailingToPanel: NSLayoutConstraint!
    private var layersPanelVisible = true
    /// 0 = Layers, 1 = Assistant.
    private var panelTab = 0

    // Move-tool drag state: the active layer's offset when the drag began.
    private var moveStartOffset: (x: Int, y: Int)?

    // The open Free Transform session (see TransformSession), and the flag
    // that marks the document change its own commit causes — every OTHER
    // change under an open session ends it.
    private var transformSession: TransformSession?
    private var isCommittingTransform = false

    // Brush/eraser drag state: the document handle when the stroke began.
    // Every stroke tick repaints the whole overlay onto this base, so the
    // live projection always shows the committed result. Mask strokes leave
    // it nil — they never live-edit, they commit once on mouse-up.
    private var strokeBase: RasterDocument?
    private var strokeTargetsMask = false

    // What brush/eraser edit (see PaintTarget), plus the layer it was chosen
    // for: selecting a different layer drops the choice back to .layer.
    private(set) var paintTarget: PaintTarget = .layer
    private var paintTargetLayer = 0

    // Last-used paint options (session-only; no persistence).
    private var brushSize: CGFloat = 24
    private var brushOpacity: CGFloat = 1.0
    private var paintColor: NSColor = .black
    private var fontFamily = "Helvetica Neue"
    private var fontSize: CGFloat = 48
    /// Text-tool line alignment, in the options bar's segment order
    /// (0 left, 1 center, 2 right).
    private var textAlignment: NSTextAlignment = .left
    /// Sampler a Free Transform commit resamples with; remembered between
    /// sessions, like the paint options above.
    private var transformSampler = RZ_FILTER_CATMULL_ROM

    private static let zoomLadder: [CGFloat] = [
        0.05, 0.1, 0.25, 0.33, 0.5, 0.67, 1.0, 1.5, 2, 3, 4, 6, 8, 12, 16, 24, 32,
    ]

    init(document: ImageDocument) {
        self.document = document
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("EditorViewController does not support NSCoder")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - View construction

    override func loadView() {
        let root = FileDropView(frame: NSRect(x: 0, y: 0, width: 1040, height: 600))

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.02
        scrollView.maxMagnification = 32
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = DS.canvasVoid
        scrollView.usesPredominantAxisScrolling = false
        scrollView.contentView = CenteringClipView()
        scrollView.documentView = canvas
        // Soft ambient shadow beneath the image, over the canvas void.
        canvas.wantsLayer = true
        canvas.layer?.masksToBounds = false
        canvas.shadow = {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
            shadow.shadowBlurRadius = 24
            shadow.shadowOffset = NSSize(width: 0, height: -9)
            return shadow
        }()

        if let document = document, let doc = document.doc {
            canvas.frame = NSRect(origin: .zero, size: doc.canvasSize)
            canvas.image = document.projection?.makeCGImage()
        }
        canvas.onSelectionChange = { [weak self] _ in self?.updateStatus() }
        canvas.onStrokeBegin = { [weak self] in
            guard let self = self, let document = self.document, let doc = document.doc,
                  doc.layerInfo(document.activeLayerIndex)?.visible == true
            else { return false } // hidden layer: refuse instead of painting invisibly
            // An adjustment layer's pixels are ignored by the compositor, so
            // strokes ALWAYS land on its mask; with the mask deleted there
            // is nothing left to paint — refuse (the canvas beeps).
            let idx = document.activeLayerIndex
            let isAdjustment = doc.layerIsAdjustment(idx)
            if isAdjustment, !doc.layerHasMask(idx) { return false }
            // Decided once per stroke so a target change mid-drag can never
            // split it across the layer and its mask.
            let targetsMask = isAdjustment || self.paintsActiveMask
            self.strokeTargetsMask = targetsMask
            self.canvas.paintsMask = targetsMask
            guard !targetsMask else {
                // Mask strokes ghost on the canvas and commit in one step
                // from onCommitMaskOverlay: no live-edit session.
                self.strokeBase = nil
                return true
            }
            self.strokeBase = doc
            document.beginLiveEdit()
            return true
        }
        canvas.onStrokeUpdate = { [weak self] data, mode, alpha in
            guard let self = self, let document = self.document, let base = self.strokeBase
            else { return }
            let idx = document.activeLayerIndex
            // nil = the stroke has missed the layer's extent entirely so far;
            // skip the tick (the projection is already correct).
            if let updated = base.paintingLayer(idx, overlay: data, w: base.width, h: base.height,
                                                mode: mode, alpha: alpha) {
                document.updateLiveEdit(updated)
            }
        }
        canvas.onCommitMaskOverlay = { [weak self] data, actionName in
            guard let self = self, let document = self.document else { return }
            let idx = document.activeLayerIndex
            guard document.doc?.layerHasMask(idx) == true else {
                NSSound.beep()
                return
            }
            document.applyEdit(actionName) { doc in
                doc.paintingLayerMask(idx, overlay: data, w: doc.width, h: doc.height)
            }
        }
        canvas.onStrokeEnd = { [weak self] actionName in
            guard let self = self, let document = self.document else { return }
            let wasMask = self.strokeTargetsMask
            let base = self.strokeBase
            self.strokeTargetsMask = false
            self.strokeBase = nil
            // A mask stroke already committed itself (onCommitMaskOverlay)
            // and never opened a live-edit session.
            guard !wasMask else { return }
            // A stroke that actually landed on a DESCRIBED layer — text, a
            // Live Photo frame — contradicts the description its pixels were
            // rendered from. Ask at mouse-up rather than mouse-down: a modal
            // alert during mouse-down would swallow the drag. Rasterize drops
            // the description inside this same gesture (one undo step);
            // Cancel rolls the stroke back to the pre-stroke snapshot, which
            // makes endLiveEdit a same-handle no-op — no undo step, no pixels
            // changed.
            let idx = document.activeLayerIndex
            if let base = base, document.doc !== base, document.layerDescribesSource(idx) {
                if document.confirmRasterize(layer: idx) {
                    if let cleared = document.doc?.withLayerMeta(idx, nil) {
                        document.updateLiveEdit(cleared)
                    }
                } else {
                    document.updateLiveEdit(base)
                }
            }
            // endLiveEdit no-ops when the handle never changed, so a stroke
            // that entirely missed the layer registers no undo step.
            document.endLiveEdit(actionName)
        }
        canvas.onStrokeCancel = { [weak self] in
            guard let self = self, let document = self.document else { return }
            self.strokeTargetsMask = false
            // An abandoned mask stroke never touched the document (strokeBase
            // is nil): dropping the overlay is the whole rollback.
            guard let base = self.strokeBase else { return }
            self.strokeBase = nil
            // Restoring the snapshot makes endLiveEdit a same-handle no-op:
            // the abandoned stroke leaves no undo step and no image change.
            document.updateLiveEdit(base)
            document.endLiveEdit("Cancel Stroke")
        }
        canvas.onTextClick = { [weak self] point in self?.textClicked(point) }
        canvas.onCommitText = { [weak self] payload, origin, wrapWidth, editingLayer in
            self?.commitTextLayer(payload, origin: origin, wrapWidth: wrapWidth,
                                  editing: editingLayer)
        }
        canvas.onTextSessionEnd = { [weak self] in
            // Drops the layer-hidden preview a re-edit session put up.
            self?.canvas.previewImage = nil
        }
        canvas.onToolKey = { [weak self] tool in self?.selectTool(tool) }
        canvas.onQuickMaskKey = { [weak self] in self?.toggleQuickMask(nil) }
        canvas.onWandClick = { [weak self] point, mode in self?.wandClicked(point, mode: mode) }
        canvas.onFillClick = { [weak self] point in self?.fillClicked(point) }
        canvas.onEyedropper = { [weak self] point in self?.sampleColor(at: point) }
        canvas.onGradientCommit = { [weak self] a, b in self?.gradientCommitted(a, b) }
        canvas.onBrushSizeKey = { [weak self] newSize in
            guard let self = self else { return }
            self.brushSize = newSize
            self.sizeSlider.doubleValue = Double(newSize)
            self.sizeField.integerValue = Int(newSize.rounded())
            self.canvas.brushSize = newSize
        }
        canvas.onMoveBegin = { [weak self] in
            guard let self = self, let document = self.document, let doc = document.doc,
                  let info = doc.layerInfo(document.activeLayerIndex)
            else { return }
            self.moveStartOffset = (info.offsetX, info.offsetY)
            document.beginLiveEdit()
        }
        canvas.onMoveUpdate = { [weak self] dx, dy in
            guard let self = self, let document = self.document, let doc = document.doc,
                  let start = self.moveStartOffset
            else { return }
            let idx = document.activeLayerIndex
            if let updated = doc.withLayerOffset(idx, start.x + dx, start.y + dy) {
                document.updateLiveEdit(updated)
            }
        }
        canvas.onMoveEnd = { [weak self] in
            guard let self = self, let document = self.document else { return }
            self.moveStartOffset = nil
            document.endLiveEdit("Move Layer")
        }
        canvas.onMoveNudge = { [weak self] dx, dy in
            guard let self = self, let document = self.document else { return }
            let idx = document.activeLayerIndex
            document.applyEdit("Move Layer") { doc in
                guard let info = doc.layerInfo(idx) else { return nil }
                return doc.withLayerOffset(idx, info.offsetX + dx, info.offsetY + dy)
            }
        }
        canvas.onTransformMouseDown = { [weak self] point, modifiers in
            self?.transformMouseDown(point, modifiers)
        }
        canvas.onTransformMouseDragged = { [weak self] point, modifiers in
            self?.transformMouseDragged(point, modifiers)
        }
        canvas.onTransformMouseUp = { [weak self] _, _ in
            self?.transformSession?.drag = nil
        }
        canvas.onTransformCommit = { [weak self] in self?.commitTransformSession() }
        canvas.onTransformCancel = { [weak self] in self?.endTransformSession() }
        canvas.onTransformNudge = { [weak self] dx, dy in self?.transformNudge(dx, dy) }

        buildOptionsBar()
        canvas.brushSize = brushSize
        canvas.paintColor = paintColor
        canvas.brushOpacity = brushOpacity
        canvas.textFont = currentFont()
        canvas.textAlignment = textAlignment

        // Toolbar: pill tool group left, ghost zoom cluster, on a card bar
        // with a subtle bottom border. The pill's contents — including
        // which tools share a button — come from EditorTool.toolbarGroups.
        toolbarBar.translatesAutoresizingMaskIntoConstraints = false
        toolPill = ToolPillControl(groups: EditorTool.toolbarGroups)
        toolPill.translatesAutoresizingMaskIntoConstraints = false
        let zoomOutButton = GhostButton(
            symbol: "minus.magnifyingglass", fallback: "−", caption: "Zoom Out",
            tooltip: "Zoom Out", action: #selector(zoomOutAction(_:)))
        let zoomInButton = GhostButton(
            symbol: "plus.magnifyingglass", fallback: "+", caption: "Zoom In",
            tooltip: "Zoom In", action: #selector(zoomInAction(_:)))
        let fitButton = GhostButton(
            symbol: "arrow.up.left.and.down.right.magnifyingglass", fallback: "⤢",
            caption: "Fit", tooltip: "Zoom to Fit", action: #selector(zoomFitAction(_:)))
        let actualButton = GhostButton(
            symbol: "1.magnifyingglass", fallback: "1", caption: "Actual",
            tooltip: "Actual Size", action: #selector(zoomActualAction(_:)))
        let toolbarStack = NSStackView(views: [
            toolPill, zoomOutButton, zoomInButton, fitButton, actualButton,
            NSView(),
        ])
        toolbarStack.translatesAutoresizingMaskIntoConstraints = false
        toolbarStack.orientation = .horizontal
        toolbarStack.alignment = .centerY
        toolbarStack.spacing = 14
        toolbarStack.setCustomSpacing(20, after: toolPill)
        toolbarBar.addSubview(toolbarStack)

        let statusBar = BarView(border: .top)
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        let statusLeft = NSStackView(views: [statusDims, statusLayer, statusBlend])
        statusLeft.translatesAutoresizingMaskIntoConstraints = false
        statusLeft.orientation = .horizontal
        statusLeft.spacing = 14
        let statusRight = NSStackView(views: [statusTool, statusZoom])
        statusRight.translatesAutoresizingMaskIntoConstraints = false
        statusRight.orientation = .horizontal
        statusRight.spacing = 14
        statusBar.addSubview(statusLeft)
        statusBar.addSubview(statusRight)

        zoomPill.translatesAutoresizingMaskIntoConstraints = false
        zoomPill.onZoomIn = { [weak self] in self?.zoomIn() }
        zoomPill.onZoomOut = { [weak self] in self?.zoomOut() }

        // Right panel (Layers + Assistant tabs) + its 1px separator line.
        layersPanel = LayersPanelViewController()
        layersPanel.document = document
        layersPanel.onActiveLayerChange = { [weak self] in
            // Retargeting the panel leaves the transform session: commit it
            // (it carries its own layer index, so it still lands correctly).
            self?.commitPendingTransform()
            self?.syncPaintTarget()
            self?.updateStatus()
            self?.updateActiveLayerRect()
        }
        layersPanel.onPaintTargetChange = { [weak self] target in
            self?.setPaintTarget(target)
        }
        layersPanel.onAdjustmentEdit = { [weak self] idx in
            self?.editAdjustmentLayer(idx)
        }
        layersPanel.onTextEdit = { [weak self] idx in
            self?.editTextLayer(idx)
        }
        layersPanel.onLivePhotoEdit = { [weak self] idx in
            self?.editLivePhotoLayer(idx)
        }
        layersPanel.onShowAssistant = { [weak self] in
            self?.panelTab = 1
            self?.updatePanelVisibility()
        }
        addChild(layersPanel)
        let panelView = layersPanel.view
        panelView.translatesAutoresizingMaskIntoConstraints = false

        assistantPanel = AssistantPanelViewController()
        assistantPanel.document = document
        assistantPanel.onShowLayers = { [weak self] in
            self?.panelTab = 0
            self?.updatePanelVisibility()
        }
        addChild(assistantPanel)
        let assistantView = assistantPanel.view
        assistantView.translatesAutoresizingMaskIntoConstraints = false
        assistantView.isHidden = true

        panelSeparator = NSBox()
        panelSeparator.boxType = .separator
        panelSeparator.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(toolbarBar)
        root.addSubview(optionsBar)
        root.addSubview(scrollView)
        root.addSubview(zoomPill)
        root.addSubview(panelSeparator)
        root.addSubview(panelView)
        root.addSubview(assistantView)
        root.addSubview(statusBar)

        guard let toolbarStackView = toolbarBar.subviews.first else {
            fatalError("toolbar stack missing")
        }
        NSLayoutConstraint.activate([
            toolbarBar.topAnchor.constraint(equalTo: root.topAnchor),
            toolbarBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbarBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbarBar.heightAnchor.constraint(equalToConstant: DS.toolbarHeight),

            toolbarStackView.leadingAnchor.constraint(
                equalTo: toolbarBar.leadingAnchor, constant: 14),
            toolbarStackView.trailingAnchor.constraint(
                equalTo: toolbarBar.trailingAnchor, constant: -14),
            toolbarStackView.centerYAnchor.constraint(equalTo: toolbarBar.centerYAnchor),

            optionsBar.topAnchor.constraint(equalTo: toolbarBar.bottomAnchor),
            optionsBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            optionsBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            optionsBar.heightAnchor.constraint(equalToConstant: 30),

            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            zoomPill.leadingAnchor.constraint(
                equalTo: scrollView.leadingAnchor, constant: 16),
            zoomPill.bottomAnchor.constraint(
                equalTo: scrollView.bottomAnchor, constant: -16),

            panelView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            panelView.widthAnchor.constraint(equalToConstant: DS.panelWidth),
            panelView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            panelView.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            assistantView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            assistantView.widthAnchor.constraint(equalToConstant: DS.panelWidth),
            assistantView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            assistantView.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            panelSeparator.trailingAnchor.constraint(equalTo: panelView.leadingAnchor),
            panelSeparator.widthAnchor.constraint(equalToConstant: 1),
            panelSeparator.topAnchor.constraint(equalTo: scrollView.topAnchor),
            panelSeparator.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            statusBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: DS.statusBarHeight),

            statusLeft.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 14),
            statusLeft.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            statusLeft.trailingAnchor.constraint(
                lessThanOrEqualTo: statusRight.leadingAnchor, constant: -14),

            statusRight.trailingAnchor.constraint(
                equalTo: statusBar.trailingAnchor, constant: -14),
            statusRight.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
        ])
        // The scroll view's top swaps between the toolbar's bottom (select/
        // move tools, options bar hidden) and the options bar's bottom.
        scrollTopToRoot = scrollView.topAnchor.constraint(equalTo: toolbarBar.bottomAnchor)
        scrollTopToOptions = scrollView.topAnchor.constraint(equalTo: optionsBar.bottomAnchor)
        // The scroll view's trailing swaps between the panel separator
        // (layers visible) and the window edge (layers hidden).
        scrollTrailingToRoot = scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor)
        scrollTrailingToPanel = scrollView.trailingAnchor.constraint(
            equalTo: panelSeparator.leadingAnchor)
        scrollTrailingToPanel.isActive = true

        view = root
        updateOptionsBar()
    }

    private func buildOptionsBar() {
        optionsBar.translatesAutoresizingMaskIntoConstraints = false
        optionsBar.orientation = .horizontal
        optionsBar.alignment = .centerY
        optionsBar.spacing = 8
        optionsBar.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)

        for label in [
            sizeLabel, opacityLabel, fontLabel, transformAngleLabel, transformScaleXLabel,
            transformScaleYLabel, transformSizeLabel, transformSizeHLabel,
            transformSamplerLabel,
        ] {
            label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        }

        sizeSlider.isContinuous = true
        sizeSlider.controlSize = .small
        sizeSlider.target = self
        sizeSlider.action = #selector(sizeSliderChanged(_:))
        sizeSlider.widthAnchor.constraint(equalToConstant: 120).isActive = true
        sizeSlider.doubleValue = Double(brushSize)

        let sizeFormatter = NumberFormatter()
        sizeFormatter.numberStyle = .none
        sizeFormatter.allowsFloats = false
        sizeFormatter.minimum = 1
        sizeFormatter.maximum = 200
        sizeField.formatter = sizeFormatter
        sizeField.controlSize = .small
        sizeField.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        sizeField.integerValue = Int(brushSize)
        sizeField.target = self
        sizeField.action = #selector(sizeFieldChanged(_:))
        sizeField.widthAnchor.constraint(equalToConstant: 44).isActive = true

        opacitySlider.isContinuous = true
        opacitySlider.controlSize = .small
        opacitySlider.target = self
        opacitySlider.action = #selector(opacitySliderChanged(_:))
        opacitySlider.widthAnchor.constraint(equalToConstant: 100).isActive = true
        opacitySlider.doubleValue = Double(brushOpacity)

        opacityValueLabel.font = NSFont.monospacedDigitSystemFont(
            ofSize: NSFont.smallSystemFontSize, weight: .regular)
        opacityValueLabel.alignment = .right
        opacityValueLabel.widthAnchor.constraint(equalToConstant: 40).isActive = true

        colorWell.color = paintColor
        colorWell.target = self
        colorWell.action = #selector(colorChanged(_:))
        colorWell.widthAnchor.constraint(equalToConstant: 44).isActive = true
        colorWell.heightAnchor.constraint(equalToConstant: 24).isActive = true

        let families = NSFontManager.shared.availableFontFamilies.sorted()
        fontPopup.controlSize = .small
        fontPopup.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        fontPopup.addItems(withTitles: families)
        if !families.contains(fontFamily) {
            fontFamily = families.first ?? NSFont.systemFont(ofSize: fontSize).fontName
        }
        fontPopup.selectItem(withTitle: fontFamily)
        fontPopup.target = self
        fontPopup.action = #selector(fontFamilyChanged(_:))
        fontPopup.widthAnchor.constraint(equalToConstant: 160).isActive = true

        let fontSizeFormatter = NumberFormatter()
        fontSizeFormatter.numberStyle = .none
        fontSizeFormatter.allowsFloats = false
        fontSizeFormatter.minimum = 6
        fontSizeFormatter.maximum = 500
        fontSizeField.formatter = fontSizeFormatter
        fontSizeField.controlSize = .small
        fontSizeField.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        fontSizeField.integerValue = Int(fontSize)
        fontSizeField.target = self
        fontSizeField.action = #selector(fontSizeChanged(_:))
        fontSizeField.widthAnchor.constraint(equalToConstant: 44).isActive = true

        // Alignment: a compact 3-segment control in the payload's order
        // (left, center, right). SF Symbols on the systems that have them,
        // short labels otherwise.
        alignmentControl.segmentCount = 3
        alignmentControl.trackingMode = .selectOne
        alignmentControl.controlSize = .small
        alignmentControl.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let alignmentSegments = [
            ("text.alignleft", "Left"), ("text.aligncenter", "Center"),
            ("text.alignright", "Right"),
        ]
        for (segment, (symbol, label)) in alignmentSegments.enumerated() {
            if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) {
                alignmentControl.setImage(image, forSegment: segment)
            } else {
                alignmentControl.setLabel(label, forSegment: segment)
            }
            alignmentControl.setToolTip("Align \(label.lowercased())", forSegment: segment)
        }
        alignmentControl.selectedSegment = Self.alignmentIndex(textAlignment)
        alignmentControl.target = self
        alignmentControl.action = #selector(alignmentChanged(_:))

        toleranceSlider.isContinuous = true
        toleranceSlider.controlSize = .small
        toleranceSlider.target = self
        toleranceSlider.action = #selector(toleranceChanged(_:))
        toleranceSlider.widthAnchor.constraint(equalToConstant: 120).isActive = true

        toleranceValueLabel.font = NSFont.monospacedDigitSystemFont(
            ofSize: NSFont.smallSystemFontSize, weight: .regular)
        toleranceValueLabel.alignment = .right
        toleranceValueLabel.widthAnchor.constraint(equalToConstant: 32).isActive = true

        contiguousCheck.state = .on
        contiguousCheck.controlSize = .small
        contiguousCheck.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)

        gradientShapePopup.controlSize = .small
        gradientShapePopup.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        gradientShapePopup.addItems(withTitles: ["Linear", "Radial"])
        gradientShapePopup.widthAnchor.constraint(equalToConstant: 90).isActive = true

        // Default end color: fade to transparent.
        gradientEndWell.color = .clear
        gradientEndWell.widthAnchor.constraint(equalToConstant: 44).isActive = true
        gradientEndWell.heightAnchor.constraint(equalToConstant: 24).isActive = true

        // Eyedropper readout: swatch + monospaced hex / R G B A values of the
        // last sampled pixel. A plain bordered box, not a color well — it
        // displays the sample, it is not an editable color.
        sampleSwatch.boxType = .custom
        sampleSwatch.titlePosition = .noTitle
        sampleSwatch.borderWidth = 1
        sampleSwatch.borderColor = NSColor.separatorColor
        sampleSwatch.cornerRadius = 3
        sampleSwatch.fillColor = .clear
        sampleSwatch.widthAnchor.constraint(equalToConstant: 24).isActive = true
        sampleSwatch.heightAnchor.constraint(equalToConstant: 16).isActive = true
        sampleValueLabel.font = NSFont.monospacedSystemFont(
            ofSize: NSFont.smallSystemFontSize, weight: .regular)

        // Free Transform numerics: the session's parameters, editable. Angle
        // in degrees (clockwise), scales in percent, and the layer's own
        // scaled pixel size — W/H write the scales through the base size.
        let angleFormatter = NumberFormatter()
        angleFormatter.numberStyle = .decimal
        angleFormatter.usesGroupingSeparator = false
        angleFormatter.maximumFractionDigits = 2
        angleFormatter.minimum = -360
        angleFormatter.maximum = 360
        transformAngleField.formatter = angleFormatter
        transformAngleField.controlSize = .small
        transformAngleField.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        transformAngleField.target = self
        transformAngleField.action = #selector(transformAngleChanged(_:))
        transformAngleField.widthAnchor.constraint(equalToConstant: 56).isActive = true

        for field in [transformScaleXField, transformScaleYField] {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.usesGroupingSeparator = false
            formatter.maximumFractionDigits = 2
            formatter.minimum = NSNumber(value: -Self.maxScalePercent)
            formatter.maximum = NSNumber(value: Self.maxScalePercent)
            field.formatter = formatter
            field.controlSize = .small
            field.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            field.target = self
            field.widthAnchor.constraint(equalToConstant: 60).isActive = true
        }
        transformScaleXField.action = #selector(transformScaleXChanged(_:))
        transformScaleYField.action = #selector(transformScaleYChanged(_:))

        // W/H: the layer's OWN scaled dimensions (|scale| × base pixel
        // size), not the rotated bounding box — that is what keeps them
        // cleanly two-way bindable. Whole pixels; the scale clamp bounds
        // them, so the formatter only rules out empty/zero/negative input.
        for field in [transformSizeWField, transformSizeHField] {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.usesGroupingSeparator = false
            formatter.maximumFractionDigits = 0
            formatter.minimum = 1
            field.formatter = formatter
            field.controlSize = .small
            field.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            field.target = self
            field.widthAnchor.constraint(equalToConstant: 60).isActive = true
        }
        transformSizeWField.action = #selector(transformSizeWChanged(_:))
        transformSizeHField.action = #selector(transformSizeHChanged(_:))

        transformSamplerPopup.controlSize = .small
        transformSamplerPopup.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        transformSamplerPopup.addItems(withTitles: Self.transformSamplers.map { $0.title })
        transformSamplerPopup.selectItem(at: Self.transformSamplerIndex(transformSampler))
        transformSamplerPopup.target = self
        transformSamplerPopup.action = #selector(transformSamplerChanged(_:))
        transformSamplerPopup.widthAnchor.constraint(equalToConstant: 170).isActive = true

        let controls: [NSView] = [
            sizeLabel, sizeSlider, sizeField,
            opacityLabel, opacitySlider, opacityValueLabel,
            colorWell,
            toleranceLabel, toleranceSlider, toleranceValueLabel, contiguousCheck,
            gradientShapePopup, gradientEndLabel, gradientEndWell,
            sampleSwatch, sampleValueLabel,
            fontLabel, fontPopup, fontSizeField, alignmentControl,
            transformAngleLabel, transformAngleField,
            transformScaleXLabel, transformScaleXField,
            transformScaleYLabel, transformScaleYField,
            transformSizeLabel, transformSizeWField,
            transformSizeHLabel, transformSizeHField,
            transformSamplerLabel, transformSamplerPopup,
        ]
        for control in controls {
            optionsBar.addArrangedSubview(control)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.contentView.postsFrameChangedNotifications = true
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(magnificationDidChange(_:)),
            name: NSScrollView.didEndLiveMagnifyNotification, object: scrollView)
        center.addObserver(
            self, selector: #selector(magnificationDidChange(_:)),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        center.addObserver(
            self, selector: #selector(magnificationDidChange(_:)),
            name: NSView.frameDidChangeNotification, object: scrollView.contentView)
        center.addObserver(
            self, selector: #selector(imageDidChange(_:)),
            name: .imageDocumentImageDidChange, object: document)
        updateStatus()
        updateActiveLayerRect()
        updateZoomLabel()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !didRunInitialZoom else { return }
        didRunInitialZoom = true
        guard let doc = document?.doc else { return }
        canvas.setFrameSize(doc.canvasSize)
        let visible = scrollView.contentSize
        if doc.canvasSize.width > visible.width || doc.canvasSize.height > visible.height {
            zoomToFit()
        } else {
            applyZoom(1.0)
        }
        updateStatus()
    }

    // MARK: - Tools

    func selectTool(_ tool: EditorTool) {
        // Switching tools leaves the transform session, which commits it
        // rather than silently dropping the drag.
        commitPendingTransform()
        if currentTool == .text, tool != .text {
            canvas.commitTextSession()
        }
        currentTool = tool
        canvas.tool = tool
        // Only brush and eraser edit masks; picking one of the other paint
        // tools silently points the target back at the layer rather than
        // blocking the tool or painting the wrong thing.
        if tool == .fill || tool == .gradient || tool == .text {
            setPaintTarget(.layer)
        }
        updateOptionsBar()
        reflectSelectedTool(tool)
        updateStatus()
    }

    // MARK: - Paint target (layer vs. its mask)

    /// True when brush/eraser strokes should land on the active layer's
    /// mask: the chosen target, confirmed against the live document.
    private var paintsActiveMask: Bool {
        guard paintTarget == .mask, let document = document, let doc = document.doc else {
            return false
        }
        return doc.layerHasMask(document.activeLayerIndex)
    }

    /// Points brush/eraser at the layer or at its mask (a mask target falls
    /// back to the layer when there is no mask), and mirrors the choice into
    /// the canvas and the layers panel's focus ring. An adjustment layer's
    /// PIXEL target is never selectable — the compositor ignores its pixels
    /// — so any request lands on the mask while one exists.
    func setPaintTarget(_ target: PaintTarget) {
        let idx = document?.activeLayerIndex ?? 0
        var target = target
        if document?.doc?.layerIsAdjustment(idx) == true,
           document?.doc?.layerHasMask(idx) == true {
            target = .mask
        }
        if target == .mask, document?.doc?.layerHasMask(idx) != true {
            target = .layer
        }
        let changed = target != paintTarget
        paintTarget = target
        paintTargetLayer = idx
        canvas.paintsMask = target == .mask
        layersPanel?.setPaintTarget(target)
        if changed { updateStatus() }
    }

    /// Drops a mask target that no longer applies — the active layer changed
    /// underneath it, or its mask was deleted, applied, or undone away — and
    /// forces the mask target whenever the active layer is an adjustment
    /// layer (its pixels are pointless to paint).
    private func syncPaintTarget() {
        let idx = document?.activeLayerIndex ?? 0
        if document?.doc?.layerIsAdjustment(idx) == true,
           document?.doc?.layerHasMask(idx) == true {
            setPaintTarget(.mask)
            return
        }
        guard paintTarget == .mask else {
            paintTargetLayer = idx
            return
        }
        if idx != paintTargetLayer || document?.doc?.layerHasMask(idx) != true {
            setPaintTarget(.layer)
        }
    }

    /// Mirrors tool selection into the toolbar pill (display only). A
    /// grouped segment also starts standing for this tool, so the group
    /// remembers what was last used in it.
    func reflectSelectedTool(_ tool: EditorTool) {
        toolPill?.setSelectedTool(tool)
    }

    @objc func selectSelectTool(_ sender: Any?) { selectTool(.select) }
    @objc func selectEllipseTool(_ sender: Any?) { selectTool(.ellipseSelect) }
    @objc func selectLassoTool(_ sender: Any?) { selectTool(.lasso) }
    @objc func selectWandTool(_ sender: Any?) { selectTool(.wand) }
    @objc func selectMoveTool(_ sender: Any?) { selectTool(.move) }
    @objc func selectBrushTool(_ sender: Any?) { selectTool(.brush) }
    @objc func selectEraserTool(_ sender: Any?) { selectTool(.eraser) }
    @objc func selectFillTool(_ sender: Any?) { selectTool(.fill) }
    @objc func selectGradientTool(_ sender: Any?) { selectTool(.gradient) }
    @objc func selectTextTool(_ sender: Any?) { selectTool(.text) }
    @objc func selectEyedropperTool(_ sender: Any?) { selectTool(.eyedropper) }

    private func updateOptionsBar() {
        // A Free Transform session takes the whole bar over: it is modal on
        // the canvas, so the active tool's own options cannot be used.
        let transforming = isTransforming
        let tool = currentTool
        let paintTool = !transforming && (tool == .brush || tool == .eraser)
        let toleranceTool = !transforming && (tool == .wand || tool == .fill)
        for control in [sizeLabel, sizeSlider, sizeField] as [NSView] {
            control.isHidden = !paintTool
        }
        for control in [opacityLabel, opacitySlider, opacityValueLabel] as [NSView] {
            control.isHidden = !paintTool
        }
        colorWell.isHidden = transforming
            || !(tool == .brush || tool == .text || tool == .fill || tool == .gradient)
        let textTool = !transforming && tool == .text
        fontLabel.isHidden = !textTool
        fontPopup.isHidden = !textTool
        fontSizeField.isHidden = !textTool
        alignmentControl.isHidden = !textTool
        for control in [toleranceLabel, toleranceSlider, toleranceValueLabel] as [NSView] {
            control.isHidden = !toleranceTool
        }
        contiguousCheck.isHidden = !toleranceTool
        let gradientTool = !transforming && tool == .gradient
        gradientShapePopup.isHidden = !gradientTool
        gradientEndLabel.isHidden = !gradientTool
        gradientEndWell.isHidden = !gradientTool
        let eyedropperTool = !transforming && tool == .eyedropper
        sampleSwatch.isHidden = !eyedropperTool
        sampleValueLabel.isHidden = !eyedropperTool
        for control in [
            transformAngleLabel, transformAngleField, transformScaleXLabel, transformScaleXField,
            transformScaleYLabel, transformScaleYField, transformSizeLabel, transformSizeWField,
            transformSizeHLabel, transformSizeHField, transformSamplerLabel, transformSamplerPopup,
        ] as [NSView] {
            control.isHidden = !transforming
        }

        let barHidden = !transforming
            && (tool == .select || tool == .ellipseSelect || tool == .lasso || tool == .move)
        optionsBar.isHidden = barHidden
        scrollTopToRoot.isActive = false
        scrollTopToOptions.isActive = false
        (barHidden ? scrollTopToRoot : scrollTopToOptions).isActive = true
    }

    // MARK: - Agent access to the selection

    /// The canvas selection, for the agent's fill/gradient/crop tools.
    var agentSelection: CanvasSelection? { canvas.selection }

    func agentSetSelection(_ selection: CanvasSelection?) {
        canvas.setSelection(selection)
    }

    // MARK: - Wand, fill, gradient actions

    @objc private func toleranceChanged(_ sender: Any?) {
        tolerance = Int(toleranceSlider.doubleValue.rounded())
        toleranceValueLabel.stringValue = "\(tolerance)"
    }

    private var contiguous: Bool { contiguousCheck.state == .on }

    /// sRGB bytes of a color (straight alpha).
    private func colorBytes(_ color: NSColor) -> [UInt8] {
        let c = color.usingColorSpace(.sRGB) ?? .black
        return [
            UInt8((c.redComponent * 255).rounded()),
            UInt8((c.greenComponent * 255).rounded()),
            UInt8((c.blueComponent * 255).rounded()),
            UInt8((c.alphaComponent * 255).rounded()),
        ]
    }

    private func wandClicked(_ point: CGPoint, mode: SelectionCombineMode) {
        guard let doc = document?.doc,
            let mask = doc.magicWand(
                x: Int(point.x), y: Int(point.y), tolerance: tolerance,
                contiguous: contiguous),
            let selection = CanvasSelection(
                shape: .mask(mask), canvasWidth: doc.width, canvasHeight: doc.height)
        else {
            NSSound.beep()
            return
        }
        // An all-zero combination comes back nil and deselects.
        canvas.setSelection(CanvasSelection.combine(canvas.selection, with: selection, mode: mode))
    }

    private func fillClicked(_ point: CGPoint) {
        guard let document = document else { return }
        // A canvas click can't be blocked by menu validation: refuse a fill
        // aimed at an adjustment layer's (ignored) pixels with the alert.
        guard !refuseAdjustmentPixelEdit() else { return }
        let idx = document.activeLayerIndex
        let rgba = colorBytes(paintColor)
        let mask = canvas.selection?.maskBytes()
        let tolerance = tolerance
        let contiguous = contiguous
        document.applyRasterizingEdit("Fill", layer: idx) { doc in
            doc.bucketFilled(
                idx, x: Int(point.x), y: Int(point.y), tolerance: tolerance,
                rgba: rgba, contiguous: contiguous, mask: mask)
        }
    }

    /// Eyedropper sample (tool click/drag tick, or Option borrowing it from
    /// brush/fill/gradient): reads the pixel under the cursor from the
    /// FLATTENED COMPOSITE — the same projection the canvas draws and the
    /// magic wand samples — and routes it into the shared paint color.
    /// Points outside the canvas no-op. Sampling is NOT an edit: no undo
    /// step, no change counting.
    private func sampleColor(at point: CGPoint) {
        guard let document = document,
              let projection = document.projection ?? document.doc?.flattened(),
              let sample = projection.pixelRGBA(
                x: Int(floor(point.x)), y: Int(floor(point.y)))
        else { return }
        setPaintColor(NSColor(
            srgbRed: CGFloat(sample.r) / 255, green: CGFloat(sample.g) / 255,
            blue: CGFloat(sample.b) / 255, alpha: CGFloat(sample.a) / 255))
        sampleSwatch.fillColor = paintColor
        sampleValueLabel.stringValue =
            "\(RasterImage.hexString(sample))  \(sample.r) \(sample.g) \(sample.b) \(sample.a)"
    }

    private func gradientCommitted(_ a: CGPoint, _ b: CGPoint) {
        guard let document = document else { return }
        // Same rule as fillClicked: a gradient drag ends on the canvas,
        // outside menu validation's reach.
        guard !refuseAdjustmentPixelEdit() else { return }
        let idx = document.activeLayerIndex
        let start = colorBytes(paintColor)
        let end = colorBytes(gradientEndWell.color)
        let kind: RzGradientKind =
            gradientShapePopup.indexOfSelectedItem == 1
            ? RZ_GRADIENT_RADIAL : RZ_GRADIENT_LINEAR
        let mask = canvas.selection?.maskBytes()
        document.applyRasterizingEdit("Gradient", layer: idx) { doc in
            doc.gradiented(idx, from: a, to: b, start: start, end: end, kind: kind, mask: mask)
        }
    }

    private func currentFont() -> NSFont {
        NSFontManager.shared.font(withFamily: fontFamily, traits: [], weight: 5, size: fontSize)
            ?? .systemFont(ofSize: fontSize)
    }

    // MARK: - Text layers

    /// A text-tool click: re-open the topmost VISIBLE text layer under the
    /// point, or start a new text entry there.
    private func textClicked(_ point: CGPoint) {
        guard let doc = document?.doc, let idx = topmostTextLayer(at: point, in: doc) else {
            canvas.beginTextSession(at: point)
            return
        }
        // A click puts the caret where it landed, so nothing is preselected.
        openTextSession(layer: idx, selectAll: false)
    }

    /// Double-clicking a TEXT layer in the layers panel: switch to the text
    /// tool and reopen the layer's description with the whole string
    /// selected, so typing replaces it and the options bar exposes the font,
    /// size, color and alignment. The layer needn't be under the cursor or
    /// even visible — the panel already said which one.
    func editTextLayer(_ idx: Int) {
        guard let doc = document?.doc, doc.textPayload(idx) != nil else {
            NSSound.beep()
            return
        }
        // A click that ends an open session only ends it — the rule the
        // canvas follows too — because committing may insert a layer and
        // renumber everything above it, `idx` included.
        if canvas.hasActiveTextSession {
            canvas.commitTextSession()
            return
        }
        // The session belongs to the text tool; entering it also drops any
        // mask paint target and swaps the options bar over.
        selectTool(.text)
        openTextSession(layer: idx, selectAll: true)
    }

    /// Opens the on-canvas editor on text layer `idx`, restoring its
    /// description into the options bar and the session. Shared by the
    /// text-tool click and the layers panel's double-click.
    private func openTextSession(layer idx: Int, selectAll: Bool) {
        guard let document = document, let doc = document.doc,
              let info = doc.layerInfo(idx), let payload = doc.textPayload(idx)
        else {
            NSSound.beep()
            return
        }
        // Editing a layer makes it the active one (the commit replaces its
        // content, and the panel should show what is being edited).
        if document.activeLayerIndex != idx {
            document.activeLayerIndex = idx
            syncPaintTarget()
            layersPanel.reload()
            updateStatus()
            updateActiveLayerRect()
        }
        // The options bar reflects what is being edited, and the session
        // draws with those very parameters.
        applyTextOptions(payload)
        // Hide the layer's own raster underneath the session, or the old
        // glyphs ghost behind every edit to the string. An already-hidden
        // layer has nothing to hide: the pure op returns nil and the session
        // runs over the unmodified canvas, which is correct.
        canvas.previewImage = doc.withLayerVisible(idx, false)?.flattened()?.makeCGImage()
        canvas.beginTextSession(
            at: TextLayer.editorOrigin(
                offsetX: info.offsetX, offsetY: info.offsetY, payload: payload),
            string: payload.string, editingLayer: idx, selectAll: selectAll)
    }

    /// The topmost visible layer that carries a text description and whose
    /// extent contains `point` (image pixel coordinates). Plain raster layers
    /// above it do not block the hit.
    private func topmostTextLayer(at point: CGPoint, in doc: RasterDocument) -> Int? {
        for idx in stride(from: doc.layerCount - 1, through: 0, by: -1) {
            guard let info = doc.layerInfo(idx), info.visible else { continue }
            let rect = CGRect(
                x: CGFloat(info.offsetX), y: CGFloat(info.offsetY),
                width: CGFloat(info.width), height: CGFloat(info.height))
            guard rect.contains(point), doc.textPayload(idx) != nil else { continue }
            return idx
        }
        return nil
    }

    /// Restores a layer's text parameters into the options bar and the
    /// canvas. The session deliberately draws with the description's OWN
    /// face, so a family that is not installed here still previews exactly
    /// what the re-render will produce.
    private func applyTextOptions(_ payload: TextLayerPayload) {
        let font = payload.nsFont
        if let family = font.familyName, fontPopup.itemTitles.contains(family) {
            fontFamily = family
            fontPopup.selectItem(withTitle: family)
        }
        fontSize = min(max(font.pointSize, 6), 500)
        fontSizeField.integerValue = Int(fontSize.rounded())
        paintColor = payload.nsColor
        colorWell.color = paintColor
        textAlignment = payload.nsAlignment
        alignmentControl.selectedSegment = Self.alignmentIndex(textAlignment)
        canvas.textFont = font
        canvas.paintColor = paintColor
        canvas.textAlignment = textAlignment
    }

    /// Commits a text session: a NEW text layer above the active one, or the
    /// re-render of the layer the session was editing. Both chain their
    /// per-layer ops into a single document handle, so each is one undo step.
    private func commitTextLayer(
        _ payload: TextLayerPayload, origin: CGPoint, wrapWidth: CGFloat, editing: Int?
    ) {
        guard let document = document, let doc = document.doc,
              let raster = TextLayer.render(payload, origin: origin, wrapWidth: wrapWidth),
              let meta = payload.json()
        else {
            NSSound.beep()
            return
        }
        let name = TextLayer.layerName(for: payload.string)

        if let idx = editing, let info = doc.layerInfo(idx), let old = doc.textPayload(idx) {
            // Opening a text layer and closing it unchanged (⌘Return, or a
            // tool switch) must not register an undo step or dirty the file.
            guard old != payload || info.offsetX != raster.offsetX
                || info.offsetY != raster.offsetY || info.width != raster.width
                || info.height != raster.height
            else { return }
            // The name follows the text only while it still IS the text: a
            // name the user typed themselves survives the re-edit.
            let nameFollowsText = info.name == TextLayer.layerName(for: old.string)
            document.applyEdit("Edit Text Layer") { doc in
                guard let filled = doc.withLayerPixels(
                        idx, rgba: raster.pixels, width: raster.width, height: raster.height),
                      let moved = filled.withLayerOffset(idx, raster.offsetX, raster.offsetY),
                      let described = moved.withLayerMeta(idx, meta)
                else { return nil }
                guard nameFollowsText else { return described }
                return described.withLayerName(idx, name) ?? described
            }
            // The active layer is unchanged, so the change notification alone
            // refreshes the panel, the status bar and the layer boundary.
            return
        }

        let below = document.activeLayerIndex
        let before = document.doc
        document.applyEdit("Add Text Layer") { doc in
            // The core has no "layer from a buffer" constructor: add an empty
            // layer, then give it the rendered pixels, its offset and its
            // description — all pure, all in one handle.
            let idx = below + 1
            guard let added = doc.addingLayer(above: below, name: name),
                  let filled = added.withLayerPixels(
                    idx, rgba: raster.pixels, width: raster.width, height: raster.height),
                  let moved = filled.withLayerOffset(idx, raster.offsetX, raster.offsetY)
            else { return nil }
            return moved.withLayerMeta(idx, meta)
        }
        guard document.doc !== before else { return }
        // The active layer moves to the new text layer; any mask paint target
        // goes with it.
        setActiveLayer(min(below + 1, document.doc.layerCount - 1))
    }

    // MARK: - Free Transform

    /// A modal free-transform session on ONE layer. The document is NOT
    /// touched while it runs: the canvas draws the layer's cached pixels
    /// through the composed matrix, and the core resamples exactly once, at
    /// commit. The parameters (see LayerTransform) are the source of truth —
    /// handle drags and the options-bar numerics are two ways of writing
    /// them, and the matrix is always composed, never decomposed.
    private struct TransformSession {
        /// The layer being transformed; the session outlives changes to the
        /// document's active layer, so it carries its own index.
        let layer: Int
        /// The layer's canvas rect when the session opened.
        let sourceRect: CGRect
        let layerImage: CGImage?
        let maskImage: CGImage?
        let below: CGImage?
        let above: CGImage?
        let opacity: CGFloat
        var transform: LayerTransform
        var sampler: RzResizeFilter
        var drag: TransformDrag?
    }

    /// What the current mouse drag does, captured at mouse-down together
    /// with the parameters it started from: every tick recomputes from that
    /// snapshot, so a drag never accumulates rounding error.
    private enum TransformDrag {
        case move(start: LayerTransform, grab: CGPoint)
        case scale(handle: TransformHandle, start: LayerTransform)
        case rotate(start: LayerTransform, grab: CGPoint)
    }

    /// Samplers offered for the commit-time resample, in popup order.
    private static let transformSamplers: [(title: String, value: RzResizeFilter)] = [
        ("Nearest", RZ_FILTER_NEAREST),
        ("Bilinear", RZ_FILTER_BILINEAR),
        ("Bicubic (Catmull-Rom)", RZ_FILTER_CATMULL_ROM),
        ("Lanczos", RZ_FILTER_LANCZOS3),
    ]

    /// Widest scale the numeric fields accept, mirroring
    /// LayerTransform.maxScaleMagnitude.
    private static let maxScalePercent = Double(LayerTransform.maxScaleMagnitude) * 100

    /// How far from a corner (SCREEN points) the rotation ring reaches. The
    /// handles are tested first, so the ring is what is left of this radius
    /// outside the box.
    private static let transformRotateBand: CGFloat = 36

    private static func transformSamplerIndex(_ sampler: RzResizeFilter) -> Int {
        transformSamplers.firstIndex { $0.value == sampler } ?? 0
    }

    var isTransforming: Bool { transformSession != nil }

    /// Layer > Free Transform (⌘T). Opens the session on the active layer;
    /// Return commits it, Escape restores the untouched layer.
    @objc func freeTransform(_ sender: Any?) {
        guard transformSession == nil, let document = document else {
            NSSound.beep()
            return
        }
        // Never leave a text session hanging underneath the box.
        canvas.commitTextSession()
        let idx = document.activeLayerIndex
        guard let doc = document.doc, let info = doc.layerInfo(idx),
              info.width > 0, info.height > 0
        else {
            NSSound.beep()
            return
        }
        let rect = CGRect(
            x: CGFloat(info.offsetX), y: CGFloat(info.offsetY),
            width: CGFloat(info.width), height: CGFloat(info.height))
        let stack = transformStackComposites(doc, around: idx)
        transformSession = TransformSession(
            layer: idx,
            sourceRect: rect,
            // A hidden layer still transforms; there are simply no pixels to
            // preview, only the box.
            layerImage: info.visible ? doc.layerImage(idx)?.makeCGImage() : nil,
            // Layer pixels come back UNMASKED, so an enabled mask has to
            // clip the preview the way the projection would.
            maskImage: doc.layerMaskEnabled(idx)
                ? doc.layerMaskImage(idx).flatMap(Self.grayMaskImage) : nil,
            below: stack.below,
            above: stack.above,
            opacity: CGFloat(info.opacity),
            transform: LayerTransform(pivot: CGPoint(x: rect.midX, y: rect.midY)),
            sampler: transformSampler,
            drag: nil)
        updateOptionsBar()
        refreshTransformPreview()
        updateTransformFields()
        updateStatus()
        view.window?.makeFirstResponder(canvas)
    }

    /// A mask image (opaque RGBA grayscale, the layer's size) redrawn into a
    /// DeviceGray bitmap, which is the only form CGContext.clip(to:mask:)
    /// accepts. White shows and black hides, matching the core's coverage.
    private static func grayMaskImage(_ mask: RasterImage) -> CGImage? {
        guard let source = mask.makeCGImage(), source.width > 0, source.height > 0,
              let context = CGContext(
                data: nil, width: source.width, height: source.height,
                bitsPerComponent: 8, bytesPerRow: source.width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        context.draw(
            source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
        return context.makeImage()
    }

    /// The two composites the preview draws the transformed layer between:
    /// the stack below it and the stack above it. Built once per session, so
    /// the drag itself never calls the core.
    private func transformStackComposites(_ doc: RasterDocument, around idx: Int)
        -> (below: CGImage?, above: CGImage?)
    {
        var belowDoc: RasterDocument? = doc
        for layer in idx..<doc.layerCount {
            belowDoc = belowDoc?.withLayerVisible(layer, false)
        }
        var aboveDoc: RasterDocument? = doc
        for layer in 0...idx {
            aboveDoc = aboveDoc?.withLayerVisible(layer, false)
        }
        return (
            belowDoc?.flattened()?.makeCGImage(),
            idx >= doc.layerCount - 1 ? nil : aboveDoc?.flattened()?.makeCGImage())
    }

    /// Pushes the session's current matrix (and the box derived from it) to
    /// the canvas. Cheap enough to run on every drag tick.
    private func refreshTransformPreview() {
        guard let session = transformSession else {
            canvas.transformPreview = nil
            return
        }
        let matrix = session.transform.matrix
        canvas.transformPreview = ImageCanvasView.TransformPreview(
            below: session.below,
            above: session.above,
            layer: session.layerImage,
            mask: session.maskImage,
            sourceRect: session.sourceRect,
            matrix: matrix,
            opacity: session.opacity,
            quad: matrix.quad(of: session.sourceRect),
            pivot: session.transform.pivotInCanvas,
            interpolate: session.sampler != RZ_FILTER_NEAREST)
    }

    /// The parameters → fields half of the binding (the fields' actions are
    /// the other half). W/H are the layer's own scaled dimensions (|scale| ×
    /// base pixel size, whole pixels) — not the rotated bounding box — so
    /// they read straight off the scales without decomposing anything.
    private func updateTransformFields() {
        guard let session = transformSession else { return }
        transformAngleField.stringValue = Self.transformNumber(session.transform.degrees)
        transformScaleXField.stringValue = Self.transformNumber(
            Double(session.transform.scaleX) * 100)
        transformScaleYField.stringValue = Self.transformNumber(
            Double(session.transform.scaleY) * 100)
        transformSizeWField.stringValue = String(
            Int((abs(session.transform.scaleX) * session.sourceRect.width).rounded()))
        transformSizeHField.stringValue = String(
            Int((abs(session.transform.scaleY) * session.sourceRect.height).rounded()))
        transformSamplerPopup.selectItem(at: Self.transformSamplerIndex(session.sampler))
    }

    /// Two decimals with trailing zeros dropped: "45", "-12.5", "133.33".
    private static func transformNumber(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        guard rounded != rounded.rounded() else { return String(Int(rounded)) }
        return String(format: "%.2f", rounded)
    }

    // MARK: Free Transform gestures

    /// What a press at `point` grabs: a handle (scale), the ring just
    /// outside a corner (rotate), or the body (move). A press beyond all of
    /// them does nothing — clicking away must not silently commit.
    private func transformDrag(at point: CGPoint, session: TransformSession) -> TransformDrag? {
        let scale = canvas.magnification
        let matrix = session.transform.matrix
        let slop = ImageCanvasView.transformHandleSize / scale
        for handle in TransformHandle.allCases {
            let world = handle.point(in: session.sourceRect).applying(matrix)
            if abs(point.x - world.x) <= slop, abs(point.y - world.y) <= slop {
                return .scale(handle: handle, start: session.transform)
            }
        }
        let corners = matrix.quad(of: session.sourceRect)
        guard corners.count == 4 else { return nil }
        let box = NSBezierPath()
        box.move(to: corners[0])
        for corner in corners.dropFirst() {
            box.line(to: corner)
        }
        box.close()
        if box.contains(point) {
            return .move(start: session.transform, grab: point)
        }
        let band = Self.transformRotateBand / scale
        for corner in corners where hypot(point.x - corner.x, point.y - corner.y) <= band {
            return .rotate(start: session.transform, grab: point)
        }
        return nil
    }

    private func transformMouseDown(_ point: CGPoint, _ modifiers: NSEvent.ModifierFlags) {
        guard let session = transformSession else { return }
        transformSession?.drag = transformDrag(at: point, session: session)
    }

    private func transformMouseDragged(_ point: CGPoint, _ modifiers: NSEvent.ModifierFlags) {
        guard let session = transformSession, let drag = session.drag else { return }
        let proportional = modifiers.contains(.shift)
        let aboutPivot = modifiers.contains(.option)
        let updated: LayerTransform
        switch drag {
        case let .move(start, grab):
            updated = LayerTransform.moving(
                start, by: CGVector(dx: point.x - grab.x, dy: point.y - grab.y),
                constrained: proportional)
        case let .scale(handle, start):
            updated = LayerTransform.scaling(
                start, in: session.sourceRect, handle: handle, to: point,
                proportional: proportional, aboutPivot: aboutPivot)
        case let .rotate(start, grab):
            updated = LayerTransform.rotating(
                start, from: grab, to: point, snap: proportional)
        }
        guard updated.isFinite else { return }
        transformSession?.transform = updated
        refreshTransformPreview()
        updateTransformFields()
    }

    /// Arrow-key nudge of the whole box (Shift: 10px).
    private func transformNudge(_ dx: CGFloat, _ dy: CGFloat) {
        guard let session = transformSession else { return }
        transformSession?.transform = LayerTransform.moving(
            session.transform, by: CGVector(dx: dx, dy: dy), constrained: false)
        refreshTransformPreview()
        updateTransformFields()
    }

    // MARK: Free Transform options bar

    @objc private func transformAngleChanged(_ sender: Any?) {
        guard transformSession != nil else { return }
        transformSession?.transform.degrees = min(
            max(transformAngleField.doubleValue, -360), 360)
        refreshTransformPreview()
        updateTransformFields()
    }

    @objc private func transformScaleXChanged(_ sender: Any?) {
        guard transformSession != nil else { return }
        transformSession?.transform.scaleX = LayerTransform.clampScale(
            CGFloat(transformScaleXField.doubleValue / 100))
        refreshTransformPreview()
        updateTransformFields()
    }

    @objc private func transformScaleYChanged(_ sender: Any?) {
        guard transformSession != nil else { return }
        transformSession?.transform.scaleY = LayerTransform.clampScale(
            CGFloat(transformScaleYField.doubleValue / 100))
        refreshTransformPreview()
        updateTransformFields()
    }

    /// W = |scaleX| × base width, so typing W sets scaleX = W / base width —
    /// preserving the current sign, so a mirrored layer stays mirrored — and
    /// runs through the same clamp the scale fields use. Bad input (the
    /// formatter rejects non-numbers; a zero base cannot happen, the session
    /// refuses empty layers) just snaps the field back to the current value.
    @objc private func transformSizeWChanged(_ sender: Any?) {
        guard let session = transformSession else { return }
        let typed = CGFloat(transformSizeWField.doubleValue)
        let base = session.sourceRect.width
        if typed > 0, base > 0 {
            let sign: CGFloat = session.transform.scaleX < 0 ? -1 : 1
            transformSession?.transform.scaleX = LayerTransform.clampScale(sign * typed / base)
            refreshTransformPreview()
        }
        updateTransformFields()
    }

    @objc private func transformSizeHChanged(_ sender: Any?) {
        guard let session = transformSession else { return }
        let typed = CGFloat(transformSizeHField.doubleValue)
        let base = session.sourceRect.height
        if typed > 0, base > 0 {
            let sign: CGFloat = session.transform.scaleY < 0 ? -1 : 1
            transformSession?.transform.scaleY = LayerTransform.clampScale(sign * typed / base)
            refreshTransformPreview()
        }
        updateTransformFields()
    }

    @objc private func transformSamplerChanged(_ sender: Any?) {
        let index = min(
            max(transformSamplerPopup.indexOfSelectedItem, 0), Self.transformSamplers.count - 1)
        transformSampler = Self.transformSamplers[index].value
        transformSession?.sampler = transformSampler
        // Nearest previews without smoothing, so the box shows the hard
        // pixel edges the commit will produce.
        refreshTransformPreview()
    }

    // MARK: Free Transform commit / cancel

    /// Runs the session's matrix through the core as ONE undo step named
    /// "Transform Layer". Returns false when the commit did NOT happen and
    /// the session must stay open: the core refused the matrix, or the user
    /// cancelled the rasterize prompt.
    @discardableResult
    private func commitTransformSession() -> Bool {
        guard let session = transformSession, let document = document, let doc = document.doc
        else {
            endTransformSession()
            return true
        }
        // Nothing actually moved (or the layer is gone): no edit, no undo
        // step, no dirty flag — just close the session.
        guard !session.transform.isIdentity, session.layer < doc.layerCount else {
            endTransformSession()
            return true
        }
        let idx = session.layer
        // A free transform rewrites the pixels a described layer — text, a
        // Live Photo frame — was rendered from. Same prompt as every other
        // rasterizing edit, but taken here rather than through
        // applyRasterizingEdit: Cancel has to keep the session open instead
        // of abandoning the whole gesture.
        let describesSource = document.layerDescribesSource(idx)
        if describesSource, !document.confirmRasterize(layer: idx) { return false }
        let matrix = session.transform.matrix
        let sampler = session.sampler
        let before = document.doc
        isCommittingTransform = true
        document.applyEdit("Transform Layer") { doc in
            guard let transformed = doc.transformingLayer(idx, matrix, sampler: sampler) else {
                return nil
            }
            guard describesSource else { return transformed }
            return transformed.withLayerMeta(idx, nil) ?? transformed
        }
        isCommittingTransform = false
        // applyEdit already beeped if the core refused (a degenerate scale, an
        // extent past its cap): keep the session up so the drag can be pulled
        // back, rather than losing it.
        guard document.doc !== before else { return false }
        endTransformSession()
        return true
    }

    /// Escape, and the teardown every other exit funnels through. The
    /// document was never touched during the session, so cancelling is
    /// nothing more than dropping the preview.
    private func endTransformSession() {
        guard transformSession != nil else { return }
        transformSession = nil
        canvas.transformPreview = nil
        updateOptionsBar()
        updateStatus()
        updateActiveLayerRect()
    }

    /// Closes an open session by COMMITTING it — the rule for every way of
    /// leaving one except Escape (tool switches, a new active layer, save,
    /// close). A commit the core or the user refuses leaves the session open,
    /// which is the safe direction.
    func commitPendingTransform() {
        guard transformSession != nil else { return }
        commitTransformSession()
    }

    // MARK: - Options bar actions

    @objc private func sizeSliderChanged(_ sender: Any?) {
        brushSize = CGFloat(sizeSlider.doubleValue)
        sizeField.integerValue = Int(sizeSlider.doubleValue.rounded())
        canvas.brushSize = brushSize
    }

    @objc private func sizeFieldChanged(_ sender: Any?) {
        let clamped = min(max(sizeField.integerValue, 1), 200)
        sizeField.integerValue = clamped
        brushSize = CGFloat(clamped)
        sizeSlider.doubleValue = Double(clamped)
        canvas.brushSize = brushSize
    }

    @objc private func opacitySliderChanged(_ sender: Any?) {
        brushOpacity = CGFloat(opacitySlider.doubleValue)
        opacityValueLabel.stringValue = "\(Int((opacitySlider.doubleValue * 100).rounded()))%"
        canvas.brushOpacity = brushOpacity
    }

    @objc private func colorChanged(_ sender: Any?) {
        setPaintColor(colorWell.color)
    }

    /// The single write path for the shared paint color (color well changes,
    /// eyedropper samples): brush, fill, gradient start, and text all read
    /// `paintColor`, and the well and canvas mirror it.
    private func setPaintColor(_ color: NSColor) {
        paintColor = color
        colorWell.color = color
        canvas.paintColor = color
        canvas.updateActiveTextSessionStyle()
    }

    @objc private func fontFamilyChanged(_ sender: Any?) {
        if let family = fontPopup.titleOfSelectedItem {
            fontFamily = family
        }
        canvas.textFont = currentFont()
        canvas.updateActiveTextSessionStyle()
    }

    @objc private func fontSizeChanged(_ sender: Any?) {
        let clamped = min(max(fontSizeField.integerValue, 6), 500)
        fontSizeField.integerValue = clamped
        fontSize = CGFloat(clamped)
        canvas.textFont = currentFont()
        canvas.updateActiveTextSessionStyle()
    }

    /// Segment order of the alignment control, which is also the payload's
    /// `alignments` order.
    private static let alignmentSegmentValues: [NSTextAlignment] = [.left, .center, .right]

    private static func alignmentIndex(_ alignment: NSTextAlignment) -> Int {
        alignmentSegmentValues.firstIndex(of: alignment) ?? 0
    }

    @objc private func alignmentChanged(_ sender: Any?) {
        let segment = min(max(alignmentControl.selectedSegment, 0), 2)
        textAlignment = Self.alignmentSegmentValues[segment]
        canvas.textAlignment = textAlignment
        canvas.updateActiveTextSessionStyle()
    }

    // MARK: - Zoom

    private var visibleCenterInCanvas: NSPoint {
        // The clip view's bounds are expressed in the document view's
        // coordinate space, so its midpoint is the visible center.
        let clipBounds = scrollView.contentView.bounds
        return NSPoint(x: clipBounds.midX, y: clipBounds.midY)
    }

    private func applyZoom(_ magnification: CGFloat) {
        let clamped = min(max(magnification, scrollView.minMagnification), scrollView.maxMagnification)
        scrollView.setMagnification(clamped, centeredAt: visibleCenterInCanvas)
        updateZoomLabel()
    }

    func zoomIn() {
        let current = scrollView.magnification
        let next = Self.zoomLadder.first { $0 > current + 0.0001 } ?? Self.zoomLadder.last!
        applyZoom(next)
    }

    func zoomOut() {
        let current = scrollView.magnification
        // Below the ladder floor (fit of a huge image, pinch to minimum) there
        // is no smaller stop; do nothing rather than jump UP to the floor.
        guard let next = Self.zoomLadder.last(where: { $0 < current - 0.0001 }) else { return }
        applyZoom(next)
    }

    func zoomActual() {
        applyZoom(1.0)
    }

    func zoomToFit() {
        guard let doc = document?.doc else { return }
        let size = doc.canvasSize
        guard size.width > 0, size.height > 0 else { return }
        let margin: CGFloat = 16
        let available = NSSize(
            width: max(scrollView.contentSize.width - margin * 2, 1),
            height: max(scrollView.contentSize.height - margin * 2, 1))
        let scale = min(available.width / size.width, available.height / size.height)
        applyZoom(min(scale, 8)) // fit may exceed 100% for small images, capped at 8
    }

    // MARK: - Document change

    @objc private func imageDidChange(_ note: Notification) {
        guard let document = document,
              (note.object as? ImageDocument) === document,
              let doc = document.doc
        else { return }
        // The document moved underneath an open transform session — only an
        // agent edit can do this, since every user-driven edit is blocked
        // while the session runs. Its matrix describes the layer rect the
        // session opened on, so replaying it against a changed stack would be
        // wrong: drop the session instead. The session's own commit sets the
        // flag and is exempt.
        if transformSession != nil, !isCommittingTransform {
            endTransformSession()
        }
        let newSize = doc.canvasSize
        let dimensionsChanged = canvas.frame.size != newSize
        canvas.image = document.projection?.makeCGImage()
        canvas.previewImage = nil
        canvas.setFrameSize(newSize)
        if dimensionsChanged {
            // The canvas.image setter also drops selections when the size
            // changes; same-size doc swaps keep the selection as-is.
            canvas.setSelection(nil)
            zoomToFit()
        }
        canvas.needsDisplay = true
        syncPaintTarget()
        updateStatus()
        updateActiveLayerRect()
        view.window?.subtitle = "\(doc.width) × \(doc.height) px"
    }

    // MARK: - Status bar

    private func updateStatus() {
        guard let document = document, let doc = document.doc else {
            statusDims.text = "No document open"
            statusLayer.text = ""
            statusBlend.text = ""
            statusTool.text = "Drop a file, or ⌘O"
            statusZoom.text = ""
            return
        }
        var dims = "\(doc.width) × \(doc.height) px"
        if canvas.quickMaskActive {
            // The selection segment's slot: the mode holds the selection as
            // its editable buffer, so this is what "selected" currently is.
            dims += " · Quick Mask"
        } else if let selection = canvas.selectionRect {
            dims += " · sel \(Int(selection.width)) × \(Int(selection.height))"
        }
        statusDims.text = dims
        if let info = doc.layerInfo(document.activeLayerIndex) {
            // Brush and eraser hit the mask when it is the paint target; say
            // so, alongside the panel's focus ring.
            statusLayer.text = paintTarget == .mask ? "\(info.name) · Mask" : info.name
            let percent = Int((Double(info.opacity) * 100).rounded())
            statusBlend.text =
                "\(RzBlendMode.displayName(for: info.blendMode)) · \(percent)%"
        } else {
            statusLayer.text = ""
            statusBlend.text = ""
        }
        statusTool.text = isTransforming ? "Free Transform" : currentTool.displayName
        updateZoomLabel()
    }

    /// Pushes the active layer's extent (image-pixel coordinates) to the
    /// canvas, which shows the boundary while a paint tool is active and
    /// the layer doesn't cover the whole canvas.
    private func updateActiveLayerRect() {
        guard let document = document, let doc = document.doc,
              let info = doc.layerInfo(document.activeLayerIndex)
        else {
            canvas.activeLayerRect = nil
            return
        }
        canvas.activeLayerRect = CGRect(
            x: CGFloat(info.offsetX), y: CGFloat(info.offsetY),
            width: CGFloat(info.width), height: CGFloat(info.height))
    }

    private func updateZoomLabel() {
        let percent = Int((scrollView.magnification * 100).rounded())
        zoomPill.setZoomText("\(percent)%")
        statusZoom.text = "\(percent)%"
    }

    @objc private func magnificationDidChange(_ note: Notification) {
        updateZoomLabel()
    }

    // MARK: - Edit actions (responder chain)

    private func performEdit(_ actionName: String, _ transform: (RasterDocument) -> RasterDocument?) {
        guard let document = document else {
            NSSound.beep()
            return
        }
        document.applyEdit(actionName, transform)
    }

    private func performLayerEdit(_ actionName: String, _ op: (RasterImage) -> RasterImage?) {
        guard let document = document else {
            NSSound.beep()
            return
        }
        // Menu validation already disables the one-shot filters on an
        // adjustment layer; this backstop covers any path around it.
        guard !refuseAdjustmentPixelEdit() else { return }
        document.applyToActiveLayer(actionName, op)
    }

    @objc func rotateCW(_ sender: Any?) {
        performEdit("Rotate 90° CW") { $0.rotated90() }
    }

    @objc func rotateCCW(_ sender: Any?) {
        performEdit("Rotate 90° CCW") { $0.rotated270() }
    }

    @objc func rotate180(_ sender: Any?) {
        performEdit("Rotate 180°") { $0.rotated180() }
    }

    @objc func flipH(_ sender: Any?) {
        performEdit("Flip Horizontal") { $0.flippedH() }
    }

    @objc func flipV(_ sender: Any?) {
        performEdit("Flip Vertical") { $0.flippedV() }
    }

    @objc func cropToSelection(_ sender: Any?) {
        guard let document = document, let selection = canvas.selectionRect else {
            NSSound.beep()
            return
        }
        document.applyEdit("Crop") { doc in
            doc.cropped(
                x: Int(selection.minX), y: Int(selection.minY),
                w: Int(selection.width), h: Int(selection.height))
        }
        canvas.setSelection(nil)
    }

    @objc func resizeImage(_ sender: Any?) {
        guard let document = document else {
            NSSound.beep()
            return
        }
        presentAsSheet(ResizeSheetController(document: document))
    }

    @objc func showCanvasSize(_ sender: Any?) {
        guard let document = document else {
            NSSound.beep()
            return
        }
        presentAsSheet(CanvasSizeSheetController(document: document))
    }

    // MARK: - Layer actions (Layer menu + panel footer buttons)

    @objc func newLayer(_ sender: Any?) {
        guard let document = document, let doc = document.doc else {
            NSSound.beep()
            return
        }
        let idx = document.activeLayerIndex
        let name = "Layer \(doc.layerCount + 1)"
        let before = document.doc
        document.applyEdit("New Layer") { $0.addingLayer(above: idx, name: name) }
        guard document.doc !== before else { return }
        document.activeLayerIndex = min(idx + 1, document.doc.layerCount - 1)
        // The active layer moved: any mask paint target goes with it.
        syncPaintTarget()
        layersPanel.reload()
        updateStatus()
        updateActiveLayerRect()
    }

    @objc func duplicateLayer(_ sender: Any?) {
        guard let document = document else {
            NSSound.beep()
            return
        }
        let idx = document.activeLayerIndex
        let before = document.doc
        document.applyEdit("Duplicate Layer") { $0.duplicatingLayer(idx) }
        guard document.doc !== before else { return }
        document.activeLayerIndex = min(idx + 1, document.doc.layerCount - 1)
        // The active layer moved: any mask paint target goes with it.
        syncPaintTarget()
        layersPanel.reload()
        updateStatus()
        updateActiveLayerRect()
    }

    @objc func deleteLayer(_ sender: Any?) {
        guard let document = document else {
            NSSound.beep()
            return
        }
        let idx = document.activeLayerIndex
        document.applyEdit("Delete Layer") { $0.removingLayer(idx) }
        // applyEdit re-clamps activeLayerIndex; the layer below (same index,
        // or the new top) ends up selected.
        // The active layer moved: any mask paint target goes with it.
        syncPaintTarget()
        layersPanel.reload()
        updateStatus()
        updateActiveLayerRect()
    }

    @objc func mergeDown(_ sender: Any?) {
        guard let document = document, document.activeLayerIndex >= 1 else {
            NSSound.beep()
            return
        }
        let idx = document.activeLayerIndex
        let before = document.doc
        document.applyEdit("Merge Down") { $0.mergingDown(idx) }
        guard document.doc !== before else { return }
        document.activeLayerIndex = idx - 1
        // The active layer moved: any mask paint target goes with it.
        syncPaintTarget()
        layersPanel.reload()
        updateStatus()
        updateActiveLayerRect()
    }

    @objc func flattenImage(_ sender: Any?) {
        guard let document = document else {
            NSSound.beep()
            return
        }
        document.applyEdit("Flatten Image") { $0.flattening() }
        // The active layer moved: any mask paint target goes with it.
        syncPaintTarget()
        layersPanel.reload()
        updateStatus()
        updateActiveLayerRect()
    }

    @objc func pasteAsNewLayer(_ sender: Any?) {
        guard let document = document else {
            NSSound.beep()
            return
        }
        document.pasteAsNewLayer()
        // The active layer moved: any mask paint target goes with it.
        syncPaintTarget()
        layersPanel.reload()
        updateStatus()
        updateActiveLayerRect()
    }

    // Bound to ⌘V through the responder chain, so a focused field editor
    // (layer rename, sheet fields, canvas text session) claims paste: first
    // and pastes text normally; canvas focus pastes as a new layer.
    @objc func paste(_ sender: Any?) {
        pasteAsNewLayer(sender)
    }

    // MARK: - Layer mask actions (Layer > Mask)

    /// Whether the active layer carries a mask, and whether that mask is
    /// enabled (menu validation, paint-target rules).
    private var activeLayerHasMask: Bool {
        guard let document = document, let doc = document.doc else { return false }
        return doc.layerHasMask(document.activeLayerIndex)
    }

    private var activeLayerMaskEnabled: Bool {
        guard let document = document, let doc = document.doc else { return false }
        return doc.layerMaskEnabled(document.activeLayerIndex)
    }

    @objc func addLayerMaskRevealAll(_ sender: Any?) {
        addLayerMask(kind: RZ_MASK_REVEAL_ALL, selection: nil)
    }

    @objc func addLayerMaskHideAll(_ sender: Any?) {
        addLayerMask(kind: RZ_MASK_HIDE_ALL, selection: nil)
    }

    @objc func addLayerMaskFromSelection(_ sender: Any?) {
        guard let selection = canvas.selection else {
            NSSound.beep()
            return
        }
        // The core crops the canvas-sized coverage to the layer's rect.
        addLayerMask(kind: RZ_MASK_FROM_SELECTION, selection: selection.maskBytes())
    }

    private func addLayerMask(kind: RzMaskKind, selection: [UInt8]?) {
        guard let document = document, document.doc != nil else {
            NSSound.beep()
            return
        }
        let idx = document.activeLayerIndex
        document.applyEdit("Add Layer Mask") {
            $0.addingLayerMask(idx, kind: kind, selection: selection)
        }
        updateStatus()
    }

    @objc func deleteLayerMask(_ sender: Any?) {
        guard let document = document, document.doc != nil else {
            NSSound.beep()
            return
        }
        let idx = document.activeLayerIndex
        document.applyEdit("Delete Layer Mask") { $0.removingLayerMask(idx, apply: false) }
        updateStatus()
    }

    @objc func applyLayerMask(_ sender: Any?) {
        guard let document = document, document.doc != nil else {
            NSSound.beep()
            return
        }
        let idx = document.activeLayerIndex
        document.applyEdit("Apply Layer Mask") { $0.removingLayerMask(idx, apply: true) }
        updateStatus()
    }

    @objc func toggleLayerMaskEnabled(_ sender: Any?) {
        guard let document = document, let doc = document.doc,
              doc.layerHasMask(document.activeLayerIndex)
        else {
            NSSound.beep()
            return
        }
        let idx = document.activeLayerIndex
        let enabled = !doc.layerMaskEnabled(idx)
        document.applyEdit(enabled ? "Enable Layer Mask" : "Disable Layer Mask") {
            $0.withLayerMaskEnabled(idx, enabled)
        }
        updateStatus()
    }

    // MARK: - Clipping masks (Layer > Create/Release Clipping Mask)

    /// Whether the ACTIVE layer is clipped to the layer below (drives the
    /// menu item's Create/Release retitle).
    private var activeLayerClipped: Bool {
        guard let document = document, let doc = document.doc else { return false }
        return doc.layerClipped(document.activeLayerIndex)
    }

    /// One toggling action, Photoshop-style: clips the active layer to the
    /// layer below, or releases it. The bottom layer has nothing below to
    /// clip to (validation disables the item; the core would composite it as
    /// unclipped anyway). Grouping is positional in the core, so this flag
    /// flip is the whole edit — one undo step.
    @objc func toggleClippingMask(_ sender: Any?) {
        guard let document = document, let doc = document.doc,
              document.activeLayerIndex >= 1
        else {
            NSSound.beep()
            return
        }
        let idx = document.activeLayerIndex
        let clipped = !doc.layerClipped(idx)
        document.applyEdit(clipped ? "Create Clipping Mask" : "Release Clipping Mask") {
            $0.withLayerClipped(idx, clipped: clipped)
        }
        updateStatus()
    }

    // MARK: - Adjustment layers (Layer > New Adjustment Layer / Adjustment Options)

    /// Whether the ACTIVE layer composites as an adjustment (asked of the
    /// core — the authoritative parse). Gates every pixel-destructive path:
    /// an adjustment layer's pixels are ignored, so editing them is
    /// meaningless.
    private var activeLayerIsAdjustment: Bool {
        guard let document = document, let doc = document.doc else { return false }
        return doc.layerIsAdjustment(document.activeLayerIndex)
    }

    /// Refuses a pixel edit aimed at the active adjustment layer with a
    /// brief app-modal alert (the canvas-click paths — fill, gradient — are
    /// outside menu validation's reach); true when refused. Move and Free
    /// Transform deliberately do NOT come through here: they move the mask
    /// footprint, which is meaningful.
    private func refuseAdjustmentPixelEdit() -> Bool {
        guard activeLayerIsAdjustment else { return false }
        let alert = NSAlert()
        alert.messageText = "Adjustment layers have no pixels to edit."
        alert.informativeText = "Paint on the layer's mask instead, or target another layer."
        alert.runModal()
        return true
    }

    @objc func newAdjustmentLayerBCS(_ sender: Any?) { newAdjustmentLayer(.bcs) }
    @objc func newAdjustmentLayerCurves(_ sender: Any?) { newAdjustmentLayer(.curves) }
    @objc func newAdjustmentLayerLevels(_ sender: Any?) { newAdjustmentLayer(.levels) }
    @objc func newAdjustmentLayerHueRotate(_ sender: Any?) { newAdjustmentLayer(.hueRotate) }
    @objc func newAdjustmentLayerPosterize(_ sender: Any?) { newAdjustmentLayer(.posterize) }
    @objc func newAdjustmentLayerThreshold(_ sender: Any?) { newAdjustmentLayer(.threshold) }
    @objc func newAdjustmentLayerInvert(_ sender: Any?) { newAdjustmentLayer(.invert) }
    @objc func newAdjustmentLayerGrayscale(_ sender: Any?) { newAdjustmentLayer(.grayscale) }
    @objc func newAdjustmentLayerSepia(_ sender: Any?) { newAdjustmentLayer(.sepia) }

    /// Layer > New Adjustment Layer > <op>. Parameterless ops create
    /// immediately (one undo step); parameterized ops open their live-preview
    /// sheet, and only its Apply commits. Either way the new layer's mask
    /// captures the CURRENT selection (marquee left up, exactly like
    /// Layer > Mask > From Selection) or is reveal-all.
    private func newAdjustmentLayer(_ op: AdjustmentLayerOp) {
        guard let document = document, document.doc != nil else {
            NSSound.beep()
            return
        }
        let selection = canvas.selection?.maskBytes()
        guard op.isParameterless else {
            guard let sheet = AdjustmentLayerSheetController.make(
                op: op, document: document, canvas: canvas,
                mode: .create(selection: selection),
                onCommitted: { [weak self] idx in self?.didCommitAdjustmentLayer(idx) })
            else {
                NSSound.beep()
                return
            }
            presentAsSheet(sheet)
            return
        }
        guard let meta = AdjustmentLayerPayload(op: op).json() else {
            NSSound.beep()
            return
        }
        let below = document.activeLayerIndex
        let before = document.doc
        document.applyEdit("New \(op.displayName) Layer") {
            $0.addingAdjustmentLayer(
                above: below, name: op.displayName, meta: meta, selection: selection)
        }
        guard document.doc !== before else { return }
        didCommitAdjustmentLayer(min(below + 1, document.doc.layerCount - 1))
    }

    /// Post-commit bookkeeping shared by every adjustment-layer commit (the
    /// steps newLayer takes): select the layer, then refresh. syncPaintTarget
    /// lands brush/eraser on the layer's mask.
    private func didCommitAdjustmentLayer(_ idx: Int) {
        guard let document = document, document.doc != nil else { return }
        document.activeLayerIndex = min(max(idx, 0), document.doc.layerCount - 1)
        syncPaintTarget()
        layersPanel.reload()
        updateStatus()
        updateActiveLayerRect()
    }

    /// Layer > Adjustment Options… — enabled only when the active layer is
    /// an adjustment layer whose op has a dialog.
    @objc func adjustmentOptions(_ sender: Any?) {
        guard let document = document else {
            NSSound.beep()
            return
        }
        editAdjustmentLayer(document.activeLayerIndex)
    }

    /// Makes `idx` the layer edits target and refreshes everything that
    /// follows it — the paint target, the panel, the status line, the
    /// on-canvas layer boundary. Like the panel's own selection this only
    /// retargets future edits: no undo step, no dirty flag. A no-op when
    /// `idx` is already active or out of range.
    func setActiveLayer(_ idx: Int) {
        guard let document = document, let doc = document.doc,
              idx >= 0, idx < doc.layerCount, idx != document.activeLayerIndex
        else { return }
        document.activeLayerIndex = idx
        syncPaintTarget()
        layersPanel.reload()
        updateStatus()
        updateActiveLayerRect()
    }

    /// Reopens layer `idx`'s dialog pre-filled from its meta (the menu item
    /// and the layers panel's thumbnail double-click both land here). OK
    /// replaces only the meta as one undo step; Cancel leaves the document
    /// untouched.
    func editAdjustmentLayer(_ idx: Int) {
        guard let document = document, let doc = document.doc,
              doc.layerIsAdjustment(idx),
              let payload = doc.adjustmentPayload(idx),
              let op = payload.knownOp
        else {
            NSSound.beep()
            return
        }
        // Editing a layer makes it the active one, like re-opening a text
        // layer does.
        setActiveLayer(idx)
        guard let sheet = AdjustmentLayerSheetController.make(
            op: op, document: document, canvas: canvas,
            mode: .edit(layer: idx, original: payload))
        else {
            NSSound.beep()
            return
        }
        presentAsSheet(sheet)
    }

    @objc func toggleLayersPanel(_ sender: Any?) {
        layersPanelVisible.toggle()
        updatePanelVisibility()
    }

    /// View > Assistant (also the panel's Assistant tab).
    @objc func showAssistant(_ sender: Any?) {
        layersPanelVisible = true
        panelTab = 1
        updatePanelVisibility()
    }

    private func updatePanelVisibility() {
        layersPanel.view.isHidden = !layersPanelVisible || panelTab != 0
        assistantPanel.view.isHidden = !layersPanelVisible || panelTab != 1
        panelSeparator.isHidden = !layersPanelVisible
        scrollTrailingToRoot.isActive = false
        scrollTrailingToPanel.isActive = false
        (layersPanelVisible ? scrollTrailingToPanel : scrollTrailingToRoot).isActive = true
    }

    // MARK: - Filter sheets

    @objc func showAdjustments(_ sender: Any?) {
        guard let document = document else {
            NSSound.beep()
            return
        }
        presentAsSheet(AdjustSheetController(document: document, canvas: canvas))
    }

    @objc func showBlur(_ sender: Any?) {
        guard let document = document else {
            NSSound.beep()
            return
        }
        presentAsSheet(BlurSheetController(document: document, canvas: canvas))
    }

    @objc func showHueRotate(_ sender: Any?) {
        guard let document = document else {
            NSSound.beep()
            return
        }
        presentAsSheet(SliderSheetController.hueRotate(document: document, canvas: canvas))
    }

    @objc func showLevels(_ sender: Any?) {
        guard let document = document else {
            NSSound.beep()
            return
        }
        presentAsSheet(SliderSheetController.levels(document: document, canvas: canvas))
    }

    @objc func showThreshold(_ sender: Any?) {
        guard let document = document else {
            NSSound.beep()
            return
        }
        presentAsSheet(SliderSheetController.threshold(document: document, canvas: canvas))
    }

    @objc func showPosterize(_ sender: Any?) {
        guard let document = document else {
            NSSound.beep()
            return
        }
        presentAsSheet(SliderSheetController.posterize(document: document, canvas: canvas))
    }

    @objc func showPixelate(_ sender: Any?) {
        guard let document = document else {
            NSSound.beep()
            return
        }
        presentAsSheet(SliderSheetController.pixelate(document: document, canvas: canvas))
    }

    @objc func showAddNoise(_ sender: Any?) {
        guard let document = document else {
            NSSound.beep()
            return
        }
        presentAsSheet(SliderSheetController.addNoise(document: document, canvas: canvas))
    }

    // MARK: - One-shot filters (active layer)

    @objc func applyGrayscale(_ sender: Any?) {
        performLayerEdit("Grayscale") { $0.grayscaled() }
    }

    @objc func applyInvert(_ sender: Any?) {
        performLayerEdit("Invert") { $0.inverted() }
    }

    @objc func applySepia(_ sender: Any?) {
        performLayerEdit("Sepia") { $0.sepia() }
    }

    @objc func applySharpen(_ sender: Any?) {
        performLayerEdit("Sharpen") { $0.sharpened(amount: 1.5) }
    }

    @objc func applyEdgeDetect(_ sender: Any?) {
        performLayerEdit("Edge Detect") { $0.edgeDetected() }
    }

    @objc func applyEmboss(_ sender: Any?) {
        performLayerEdit("Emboss") { $0.embossed() }
    }

    // MARK: - Zoom actions

    @objc func zoomInAction(_ sender: Any?) { zoomIn() }
    @objc func zoomOutAction(_ sender: Any?) { zoomOut() }
    @objc func zoomActualAction(_ sender: Any?) { zoomActual() }
    @objc func zoomFitAction(_ sender: Any?) { zoomToFit() }

    // MARK: - Selection and clipboard

    override func selectAll(_ sender: Any?) {
        canvas.setSelectionRect(CGRect(origin: .zero, size: canvas.bounds.size))
    }

    @objc func deselect(_ sender: Any?) {
        canvas.setSelection(nil)
    }

    /// Select > Invert Selection: the complement over the full canvas.
    /// Selections are not undoable; the result simply replaces the
    /// current one (nil — a selection covering everything — deselects).
    @objc func invertSelection(_ sender: Any?) {
        guard let selection = canvas.selection else {
            NSSound.beep()
            return
        }
        canvas.setSelection(selection.inverted())
    }

    /// Select > Feather Selection…: radius sheet, then a Gaussian feather
    /// of the selection's coverage mask.
    @objc func featherSelection(_ sender: Any?) {
        guard canvas.selection != nil else {
            NSSound.beep()
            return
        }
        presentAsSheet(FeatherSheetController(canvas: canvas))
    }

    // Select > Grow/Shrink/Border/Smooth Selection…: Feather's numeric
    // dialog over the core's morphology ops. Like every selection change,
    // not undoable — the result simply replaces the current selection.

    @objc func growSelection(_ sender: Any?) {
        presentSelectionMorphSheet(
            title: "Grow selection", label: "Radius:",
            hint: "Expands the selection outward by the radius, rounding "
                + "corners into circular arcs.") { $0.grown(by: $1) }
    }

    @objc func shrinkSelection(_ sender: Any?) {
        presentSelectionMorphSheet(
            title: "Shrink selection", label: "Radius:",
            hint: "Contracts the selection inward by the radius; a shrink "
                + "past the middle deselects.") { $0.shrunk(by: $1) }
    }

    @objc func borderSelection(_ sender: Any?) {
        presentSelectionMorphSheet(
            title: "Border selection", label: "Width:",
            hint: "Replaces the selection with a band of this width "
                + "straddling its edge.") { $0.bordered(width: $1) }
    }

    @objc func smoothSelection(_ sender: Any?) {
        presentSelectionMorphSheet(
            title: "Smooth selection", label: "Radius:",
            hint: "Rounds corners and evens out jagged edges; long straight "
                + "edges stay put.") { $0.smoothed(by: $1) }
    }

    private func presentSelectionMorphSheet(
        title: String, label: String, hint: String,
        transform: @escaping (CanvasSelection, Double) -> CanvasSelection?
    ) {
        guard canvas.selection != nil else {
            NSSound.beep()
            return
        }
        presentAsSheet(
            SelectionMorphSheetController(
                canvas: canvas, title: title, label: label, hint: hint,
                transform: transform))
    }

    /// Select > Quick Mask Mode (or the bare Q on the canvas): the
    /// selection becomes an editable coverage buffer under a rubylith tint
    /// — brush adds, eraser removes — and converts back on exit. Pure view
    /// state on the canvas: no document edit, no undo step, exactly like
    /// the selection changes it stands in for.
    @objc func toggleQuickMask(_ sender: Any?) {
        guard document?.doc != nil else {
            NSSound.beep()
            return
        }
        canvas.toggleQuickMask()
        updateStatus()
    }

    /// Edit > Clear (⌫): erases the selected region out of the ACTIVE layer,
    /// in proportion to the selection's coverage — the pixels lose their
    /// color and become transparent, a feathered or anti-aliased edge fading
    /// out across the fringe. Nothing selected means nothing to clear (the
    /// menu item is disabled, so ⌫ stays free for whoever else wants it).
    @objc func clearSelection(_ sender: Any?) {
        guard let document = document, let selection = canvas.selection else {
            NSSound.beep()
            return
        }
        // Validation disables the menu item on an adjustment layer; this
        // backstop covers any path around it.
        guard !refuseAdjustmentPixelEdit() else { return }
        let idx = document.activeLayerIndex
        let mask = selection.maskBytes()
        // Rewriting pixels invalidates a text layer's description, so this
        // goes through the rasterize prompt (Cancel abandons the edit).
        document.applyRasterizingEdit("Clear", layer: idx) { doc in
            doc.clearingSelection(idx, mask: mask)
        }
    }

    /// Edit > Copy: the ACTIVE LAYER's pixels within the selection, the way
    /// Photoshop's Copy works — raw layer pixels, so opacity, blend mode and
    /// the layer mask stay out of it and the copy round-trips through Paste
    /// as New Layer unchanged. Everything the layer does not reach inside the
    /// selection comes out transparent.
    @objc func copy(_ sender: Any?) {
        guard let doc = document?.doc else {
            NSSound.beep()
            return
        }
        copyToPasteboard(doc.layerCanvasImage(document?.activeLayerIndex ?? 0))
    }

    /// Edit > Copy Merged: the same region of the flattened composite —
    /// every visible layer, with opacity, blend modes, masks, clipping and
    /// adjustment layers all applied, as one image.
    @objc func copyMerged(_ sender: Any?) {
        copyToPasteboard(document?.projection)
    }

    /// Shared tail of both copies: crop the canvas-sized source to the
    /// selection's BOUNDS (the whole canvas without a selection) and write it
    /// as TIFF + PNG. Non-rectangular selections copy their bounding box —
    /// the pixels outside the shape come along, as they always have.
    private func copyToPasteboard(_ source: RasterImage?) {
        var image = source
        if let selection = canvas.selectionRect {
            image = image?.cropped(
                x: Int(selection.minX), y: Int(selection.minY),
                w: Int(selection.width), h: Int(selection.height))
        }
        guard let cgImage = image?.makeCGImage() else {
            NSSound.beep()
            return
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        let item = NSPasteboardItem()
        if let tiffData = rep.representation(using: .tiff, properties: [:]) {
            item.setData(tiffData, forType: .tiff)
        }
        if let pngData = rep.representation(using: .png, properties: [:]) {
            item.setData(pngData, forType: .png)
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }
}

// MARK: - Undo plumbing

extension EditorViewController {
    // Intercept the nil-target undo:/redo: menu actions ahead of NSWindow so
    // the text-session and preview-sheet guards in validateUserInterfaceItem
    // apply to them; otherwise Cmd-Z reaches the document's undo manager
    // directly and mutates the image underneath an open session or sheet.
    @objc func undo(_ sender: Any?) { activeUndoManager?.undo() }
    @objc func redo(_ sender: Any?) { activeUndoManager?.redo() }

    /// Mirrors NSWindow's resolution: a focused field editor (options-bar and
    /// sheet text fields) keeps its own typing undo; everything else gets the
    /// document's manager.
    private var activeUndoManager: UndoManager? {
        view.window?.firstResponder?.undoManager ?? document?.undoManager
    }

    /// Called by ImageDocument on save/close/export so an in-progress canvas
    /// session — text entry, or a Free Transform — is never silently dropped
    /// from the written file.
    func commitPendingSessions() {
        canvas.commitTextSession()
        commitPendingTransform()
    }
}

// MARK: - Validation

extension EditorViewController: NSUserInterfaceValidations {
    private static let toolActions: [Selector: EditorTool] = [
        #selector(selectSelectTool(_:)): .select,
        #selector(selectEllipseTool(_:)): .ellipseSelect,
        #selector(selectLassoTool(_:)): .lasso,
        #selector(selectWandTool(_:)): .wand,
        #selector(selectMoveTool(_:)): .move,
        #selector(selectBrushTool(_:)): .brush,
        #selector(selectEraserTool(_:)): .eraser,
        #selector(selectFillTool(_:)): .fill,
        #selector(selectGradientTool(_:)): .gradient,
        #selector(selectTextTool(_:)): .text,
        #selector(selectEyedropperTool(_:)): .eyedropper,
    ]

    /// True while a text-editing responder owns the keyboard: a field
    /// editor (every NSTextField in the window edits through one) or the
    /// canvas text session's own text view — both are NSText subclasses.
    private var isEditingText: Bool {
        view.window?.firstResponder is NSText
    }

    private static let zoomActions: Set<Selector> = [
        #selector(zoomInAction(_:)),
        #selector(zoomOutAction(_:)),
        #selector(zoomActualAction(_:)),
        #selector(zoomFitAction(_:)),
    ]

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        guard document?.doc != nil else { return false }
        // While a preview sheet is up, its captured base and the document must
        // not diverge: block every edit action delivered via key equivalents.
        guard view.window?.attachedSheet == nil else { return false }

        if let action = item.action, let tool = Self.toolActions[action] {
            if let menuItem = item as? NSMenuItem {
                menuItem.state = currentTool == tool ? .on : .off
            }
            return true
        }

        // While a text session or a Free Transform is active, only tool
        // switching (handled above — it commits the session) and zooming are
        // safe; edit/filter/clipboard actions must not mutate the image
        // underneath the session, and Free Transform must not re-enter.
        if canvas.hasActiveTextSession || isTransforming {
            if let action = item.action, Self.zoomActions.contains(action) {
                return true
            }
            return false
        }

        switch item.action {
        case #selector(freeTransform(_:)):
            // Needs a layer with pixels to transform.
            let active = document?.activeLayerIndex ?? 0
            guard let info = document?.doc?.layerInfo(active) else { return false }
            return info.width > 0 && info.height > 0
        case #selector(toggleQuickMask(_:)):
            // The one Select-menu item that stays live inside the mode (it
            // is the way out); checked while active.
            if let menuItem = item as? NSMenuItem {
                menuItem.state = canvas.quickMaskActive ? .on : .off
            }
            return true
        case #selector(selectAll(_:)):
            // Every other Select-menu item is disabled inside Quick Mask
            // mode: the selection lives in the mode's buffer until exit.
            return !canvas.quickMaskActive
        case #selector(selectSubject(_:)):
            // Segmentation reads the composite, so an image is all it needs
            // — unlike the modify-the-selection items, it makes a selection
            // from nothing.
            return !canvas.quickMaskActive && document?.doc != nil
        case #selector(deselect(_:)),
            #selector(invertSelection(_:)), #selector(featherSelection(_:)),
            #selector(growSelection(_:)), #selector(shrinkSelection(_:)),
            #selector(borderSelection(_:)), #selector(smoothSelection(_:)):
            return !canvas.quickMaskActive && canvas.selectionRect != nil
        case #selector(cropToSelection(_:)):
            // Crop needs a selection that would actually shrink the canvas.
            // Selection BOUNDS are what it crops to, so a selection already
            // spanning the image — Select All, or a lasso whose extent
            // covers it — leaves nothing to do; the core refuses that crop
            // as a no-op, so the item would be dead anyway.
            guard !canvas.quickMaskActive, let rect = canvas.selectionRect,
                  let doc = document?.doc
            else { return false }
            return rect.integral
                != CGRect(x: 0, y: 0, width: doc.width, height: doc.height)
        case #selector(clearSelection(_:)):
            // Clear's key equivalent is a BARE ⌫: while it is enabled the
            // menu eats every Delete keystroke before the first responder
            // sees it (key equivalents are resolved ahead of keyDown). So it
            // is enabled only with something to clear — a selection and an
            // active layer — and never while text is being edited: the
            // canvas text session is already excluded by the session guard
            // above, and this also covers the window's field editors (the
            // options bar, the layer name field, the assistant's input),
            // where ⌫ must keep deleting characters. An adjustment layer has
            // no pixels worth clearing.
            guard !isEditingText, canvas.selection != nil, !activeLayerIsAdjustment
            else { return false }
            return document?.doc?.layerInfo(document?.activeLayerIndex ?? 0) != nil
        case #selector(showAdjustments(_:)), #selector(showBlur(_:)),
            #selector(showHueRotate(_:)), #selector(showLevels(_:)),
            #selector(showThreshold(_:)), #selector(showPosterize(_:)),
            #selector(showPixelate(_:)), #selector(showAddNoise(_:)),
            #selector(applyGrayscale(_:)), #selector(applyInvert(_:)),
            #selector(applySepia(_:)), #selector(applySharpen(_:)),
            #selector(applyEdgeDetect(_:)), #selector(applyEmboss(_:)):
            // Destructive filters rewrite the active layer's PIXELS, which
            // an adjustment layer doesn't meaningfully have; its parameters
            // re-open through Adjustment Options… instead.
            return !activeLayerIsAdjustment
        case #selector(selectLivePhotoFrame(_:)):
            // Only a layer that still says which Live Photo it came from can
            // show a different frame of it; a missing clip is reported when
            // the picker opens, not by disabling the item, so the reason is
            // visible rather than mysterious.
            guard let document = document, let doc = document.doc else { return false }
            return doc.livePhotoPayload(document.activeLayerIndex) != nil
        case #selector(adjustmentOptions(_:)):
            guard let document = document, let doc = document.doc else { return false }
            let idx = document.activeLayerIndex
            guard doc.layerIsAdjustment(idx),
                  let op = doc.adjustmentPayload(idx)?.knownOp
            else { return false }
            return AdjustmentLayerSheetController.opHasDialog(op)
        case #selector(deleteLayer(_:)):
            return (document?.doc?.layerCount ?? 1) > 1
        case #selector(mergeDown(_:)):
            // The core refuses to merge into a hidden layer; mirror that
            // here (and match the panel's merge button).
            let active = document?.activeLayerIndex ?? 0
            return active >= 1 && document?.doc?.layerInfo(active - 1)?.visible == true
        case #selector(flattenImage(_:)):
            return (document?.doc?.layerCount ?? 1) > 1
        case #selector(addLayerMaskRevealAll(_:)), #selector(addLayerMaskHideAll(_:)):
            return !activeLayerHasMask
        case #selector(addLayerMaskFromSelection(_:)):
            return !activeLayerHasMask && canvas.selection != nil
        case #selector(deleteLayerMask(_:)), #selector(applyLayerMask(_:)):
            return activeLayerHasMask
        case #selector(toggleLayerMaskEnabled(_:)):
            // Checkmark state, fixed title: a mask is enabled or it isn't.
            if let menuItem = item as? NSMenuItem {
                menuItem.state = activeLayerMaskEnabled ? .on : .off
            }
            return activeLayerHasMask
        case #selector(toggleClippingMask(_:)):
            // One item, retitled (Photoshop convention). The bottom layer has
            // no layer below to clip to, so it stays disabled there; the
            // no-document case is the guard at the top.
            if let menuItem = item as? NSMenuItem {
                menuItem.title =
                    activeLayerClipped ? "Release Clipping Mask" : "Create Clipping Mask"
            }
            return (document?.activeLayerIndex ?? 0) >= 1
        case #selector(copy(_:)):
            // Copy takes the ACTIVE LAYER's pixels, and an adjustment layer
            // has none worth copying — its effect lives in the composite, so
            // Copy Merged is the one that captures it and stays enabled.
            return !activeLayerIsAdjustment
        case #selector(pasteAsNewLayer(_:)), #selector(paste(_:)):
            return NSPasteboard.general.canReadObject(forClasses: [NSImage.self], options: nil)
        case #selector(toggleLayersPanel(_:)):
            if let menuItem = item as? NSMenuItem {
                menuItem.title = layersPanelVisible ? "Hide Layers" : "Show Layers"
            }
            return true
        case #selector(undo(_:)):
            if let menuItem = item as? NSMenuItem, let manager = activeUndoManager {
                menuItem.title = manager.undoMenuItemTitle
            }
            return activeUndoManager?.canUndo ?? false
        case #selector(redo(_:)):
            if let menuItem = item as? NSMenuItem, let manager = activeUndoManager {
                menuItem.title = manager.redoMenuItemTitle
            }
            return activeUndoManager?.canRedo ?? false
        default:
            return true
        }
    }
}
