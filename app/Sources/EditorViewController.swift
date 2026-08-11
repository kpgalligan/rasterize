import AppKit

/// Tools offered by the editor UI. Raw values are the toolbar group's
/// segment indices.
enum EditorTool: Int {
    case select = 0
    case ellipseSelect
    case lasso
    case wand
    case move
    case brush
    case eraser
    case fill
    case gradient
    case text
}

/// What brush and eraser edit on the active layer: its pixels, or its layer
/// mask. Pure UI state owned by EditorViewController — not undoable, not
/// persisted, and reset to `.layer` whenever the active layer changes, its
/// mask goes away, or the document is replaced.
enum PaintTarget {
    case layer
    case mask
}

final class EditorViewController: NSViewController {
    private weak var document: ImageDocument?

    private let scrollView = NSScrollView()
    private let canvas = ImageCanvasView()
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
    private let toleranceLabel = NSTextField(labelWithString: "Tolerance")
    private let toleranceSlider = NSSlider(
        value: 32, minValue: 0, maxValue: 255, target: nil, action: nil)
    private let toleranceValueLabel = NSTextField(labelWithString: "32")
    private let contiguousCheck = NSButton(
        checkboxWithTitle: "Contiguous", target: nil, action: nil)
    private let gradientShapePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let gradientEndLabel = NSTextField(labelWithString: "End")
    private let gradientEndWell = NSColorWell()

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
            // Decided once per stroke so a target change mid-drag can never
            // split it across the layer and its mask.
            let targetsMask = self.paintsActiveMask
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
            // A stroke that actually landed on a text layer contradicts the
            // description its pixels were rendered from. Ask at mouse-up
            // rather than mouse-down: a modal alert during mouse-down would
            // swallow the drag. Rasterize drops the description inside this
            // same gesture (one undo step); Cancel rolls the stroke back to
            // the pre-stroke snapshot, which makes endLiveEdit a same-handle
            // no-op — no undo step, no pixels changed.
            let idx = document.activeLayerIndex
            if let base = base, document.doc !== base, document.doc?.textPayload(idx) != nil {
                if document.confirmTextRasterize(layer: idx) {
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
        canvas.onToolKey = { [weak self] tool in
            switch tool {
            case .select: self?.selectTool(.select)
            case .ellipseSelect: self?.selectTool(.ellipseSelect)
            case .lasso: self?.selectTool(.lasso)
            case .wand: self?.selectTool(.wand)
            case .move: self?.selectTool(.move)
            case .brush: self?.selectTool(.brush)
            case .eraser: self?.selectTool(.eraser)
            case .fill: self?.selectTool(.fill)
            case .gradient: self?.selectTool(.gradient)
            case .text: self?.selectTool(.text)
            }
        }
        canvas.onWandClick = { [weak self] point, mode in self?.wandClicked(point, mode: mode) }
        canvas.onFillClick = { [weak self] point in self?.fillClicked(point) }
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

        buildOptionsBar()
        canvas.brushSize = brushSize
        canvas.paintColor = paintColor
        canvas.brushOpacity = brushOpacity
        canvas.textFont = currentFont()

        // Toolbar: pill tool group left, ghost zoom cluster, crop pinned
        // right, on a card bar with a subtle bottom border.
        toolbarBar.translatesAutoresizingMaskIntoConstraints = false
        toolPill = ToolPillControl(segments: [
            .init(symbol: "cursorarrow", fallback: "S", label: "Select",
                  action: #selector(selectSelectTool(_:))),
            .init(symbol: "circle.dashed", fallback: "O", label: "Ellipse",
                  action: #selector(selectEllipseTool(_:))),
            .init(symbol: "lasso", fallback: "L", label: "Lasso",
                  action: #selector(selectLassoTool(_:))),
            .init(symbol: "wand.and.stars", fallback: "W", label: "Wand",
                  action: #selector(selectWandTool(_:))),
            .init(symbol: "arrow.up.and.down.and.arrow.left.and.right", fallback: "M",
                  label: "Move", action: #selector(selectMoveTool(_:))),
            .init(symbol: "paintbrush.pointed", fallback: "B", label: "Brush",
                  action: #selector(selectBrushTool(_:))),
            .init(symbol: "eraser", fallback: "E", label: "Eraser",
                  action: #selector(selectEraserTool(_:))),
            .init(symbol: "drop.fill", fallback: "K", label: "Fill",
                  action: #selector(selectFillTool(_:))),
            .init(symbol: "circle.lefthalf.filled", fallback: "G", label: "Grad",
                  action: #selector(selectGradientTool(_:))),
            .init(symbol: "textformat", fallback: "T", label: "Text",
                  action: #selector(selectTextTool(_:))),
        ])
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
        let cropButton = GhostButton(
            symbol: "crop", fallback: "⌗", caption: "Crop",
            tooltip: "Crop to Selection", action: #selector(cropToSelection(_:)))
        let toolbarStack = NSStackView(views: [
            toolPill, zoomOutButton, zoomInButton, fitButton, actualButton,
            NSView(), cropButton,
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
            self?.syncPaintTarget()
            self?.updateStatus()
            self?.updateActiveLayerRect()
        }
        layersPanel.onPaintTargetChange = { [weak self] target in
            self?.setPaintTarget(target)
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

        for label in [sizeLabel, opacityLabel, fontLabel] {
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

        let controls: [NSView] = [
            sizeLabel, sizeSlider, sizeField,
            opacityLabel, opacitySlider, opacityValueLabel,
            colorWell,
            toleranceLabel, toleranceSlider, toleranceValueLabel, contiguousCheck,
            gradientShapePopup, gradientEndLabel, gradientEndWell,
            fontLabel, fontPopup, fontSizeField,
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
        if currentTool == .text, tool != .text {
            canvas.commitTextSession()
        }
        currentTool = tool
        switch tool {
        case .select: canvas.tool = .select
        case .ellipseSelect: canvas.tool = .ellipseSelect
        case .lasso: canvas.tool = .lasso
        case .wand: canvas.tool = .wand
        case .move: canvas.tool = .move
        case .brush: canvas.tool = .brush
        case .eraser: canvas.tool = .eraser
        case .fill: canvas.tool = .fill
        case .gradient: canvas.tool = .gradient
        case .text: canvas.tool = .text
        }
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
    /// the canvas and the layers panel's focus ring.
    func setPaintTarget(_ target: PaintTarget) {
        let idx = document?.activeLayerIndex ?? 0
        var target = target
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
    /// underneath it, or its mask was deleted, applied, or undone away.
    private func syncPaintTarget() {
        let idx = document?.activeLayerIndex ?? 0
        guard paintTarget == .mask else {
            paintTargetLayer = idx
            return
        }
        if idx != paintTargetLayer || document?.doc?.layerHasMask(idx) != true {
            setPaintTarget(.layer)
        }
    }

    /// Mirrors tool selection into the toolbar pill (display only).
    func reflectSelectedTool(_ tool: EditorTool) {
        toolPill?.setSelectedIndex(tool.rawValue)
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

    private func updateOptionsBar() {
        let tool = currentTool
        let paintTool = tool == .brush || tool == .eraser
        let toleranceTool = tool == .wand || tool == .fill
        for control in [sizeLabel, sizeSlider, sizeField] as [NSView] {
            control.isHidden = !paintTool
        }
        for control in [opacityLabel, opacitySlider, opacityValueLabel] as [NSView] {
            control.isHidden = !paintTool
        }
        colorWell.isHidden = !(tool == .brush || tool == .text || tool == .fill
            || tool == .gradient)
        fontLabel.isHidden = tool != .text
        fontPopup.isHidden = tool != .text
        fontSizeField.isHidden = tool != .text
        for control in [toleranceLabel, toleranceSlider, toleranceValueLabel] as [NSView] {
            control.isHidden = !toleranceTool
        }
        contiguousCheck.isHidden = !toleranceTool
        gradientShapePopup.isHidden = tool != .gradient
        gradientEndLabel.isHidden = tool != .gradient
        gradientEndWell.isHidden = tool != .gradient

        let barHidden =
            tool == .select || tool == .ellipseSelect || tool == .lasso || tool == .move
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

    private func gradientCommitted(_ a: CGPoint, _ b: CGPoint) {
        guard let document = document else { return }
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
        guard let document = document, let doc = document.doc,
              let idx = topmostTextLayer(at: point, in: doc),
              let info = doc.layerInfo(idx), let payload = doc.textPayload(idx)
        else {
            canvas.beginTextSession(at: point)
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
        // glyphs ghost behind every edit to the string.
        canvas.previewImage = doc.withLayerVisible(idx, false)?.flattened()?.makeCGImage()
        canvas.beginTextSession(
            at: TextLayer.editorOrigin(
                offsetX: info.offsetX, offsetY: info.offsetY, payload: payload),
            string: payload.string, editingLayer: idx)
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
        canvas.textFont = font
        canvas.paintColor = paintColor
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
        document.activeLayerIndex = min(below + 1, document.doc.layerCount - 1)
        // The active layer moved: any mask paint target goes with it.
        syncPaintTarget()
        layersPanel.reload()
        updateStatus()
        updateActiveLayerRect()
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
        paintColor = colorWell.color
        canvas.paintColor = paintColor
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
        if let selection = canvas.selectionRect {
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
        statusTool.text = toolDisplayName(currentTool)
        updateZoomLabel()
    }

    private func toolDisplayName(_ tool: EditorTool) -> String {
        switch tool {
        case .select: return "Select"
        case .ellipseSelect: return "Ellipse Select"
        case .lasso: return "Lasso"
        case .wand: return "Magic Wand"
        case .move: return "Move"
        case .brush: return "Brush"
        case .eraser: return "Eraser"
        case .fill: return "Fill"
        case .gradient: return "Gradient"
        case .text: return "Text"
        }
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

    /// Edit > Invert Selection: the complement over the full canvas.
    /// Selections are not undoable; the result simply replaces the
    /// current one (nil — a selection covering everything — deselects).
    @objc func invertSelection(_ sender: Any?) {
        guard let selection = canvas.selection else {
            NSSound.beep()
            return
        }
        canvas.setSelection(selection.inverted())
    }

    /// Edit > Feather Selection…: radius sheet, then a Gaussian feather
    /// of the selection's coverage mask.
    @objc func featherSelection(_ sender: Any?) {
        guard canvas.selection != nil else {
            NSSound.beep()
            return
        }
        presentAsSheet(FeatherSheetController(canvas: canvas))
    }

    @objc func copy(_ sender: Any?) {
        guard let projection = document?.projection else {
            NSSound.beep()
            return
        }
        let source: RasterImage?
        if let selection = canvas.selectionRect {
            source = projection.cropped(
                x: Int(selection.minX), y: Int(selection.minY),
                w: Int(selection.width), h: Int(selection.height))
        } else {
            source = projection
        }
        guard let cgImage = source?.makeCGImage() else {
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

    /// Called by ImageDocument on save/close/export so an in-progress text
    /// session is never silently dropped from the written file.
    func commitPendingTextSession() {
        canvas.commitTextSession()
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
    ]

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

        // While a text session is active, only tool switching (which commits
        // the session) and zooming are safe; edit/filter/clipboard actions
        // must not mutate the image underneath the session.
        if canvas.hasActiveTextSession {
            if let action = item.action, Self.zoomActions.contains(action) {
                return true
            }
            return false
        }

        switch item.action {
        case #selector(cropToSelection(_:)), #selector(deselect(_:)),
            #selector(invertSelection(_:)), #selector(featherSelection(_:)):
            return canvas.selectionRect != nil
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
