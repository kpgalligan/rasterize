import AppKit

/// Tools offered by the editor UI. Raw values are the toolbar group's
/// segment indices.
enum EditorTool: Int {
    case select = 0
    case move
    case brush
    case eraser
    case text
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
    // live projection always shows the committed result.
    private var strokeBase: RasterDocument?

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
        canvas.onStrokeEnd = { [weak self] actionName in
            guard let self = self, let document = self.document else { return }
            self.strokeBase = nil
            // endLiveEdit no-ops when the handle never changed, so a stroke
            // that entirely missed the layer registers no undo step.
            document.endLiveEdit(actionName)
        }
        canvas.onStrokeCancel = { [weak self] in
            guard let self = self, let document = self.document,
                  let base = self.strokeBase
            else { return }
            self.strokeBase = nil
            // Restoring the snapshot makes endLiveEdit a same-handle no-op:
            // the abandoned stroke leaves no undo step and no image change.
            document.updateLiveEdit(base)
            document.endLiveEdit("Cancel Stroke")
        }
        canvas.onCommitTextOverlay = { [weak self] data, mode, alpha, actionName in
            guard let self = self, let document = self.document else { return }
            let idx = document.activeLayerIndex
            // The session is already torn down; committing onto a hidden
            // layer would invisibly dirty the document, so refuse.
            guard document.doc?.layerInfo(idx)?.visible == true else {
                NSSound.beep()
                return
            }
            document.applyEdit(actionName) { doc in
                doc.paintingLayer(idx, overlay: data, w: doc.width, h: doc.height,
                                  mode: mode, alpha: alpha)
            }
        }
        canvas.onToolKey = { [weak self] tool in
            switch tool {
            case .select: self?.selectTool(.select)
            case .move: self?.selectTool(.move)
            case .brush: self?.selectTool(.brush)
            case .eraser: self?.selectTool(.eraser)
            case .text: self?.selectTool(.text)
            }
        }
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
            .init(symbol: "arrow.up.and.down.and.arrow.left.and.right", fallback: "M",
                  label: "Move", action: #selector(selectMoveTool(_:))),
            .init(symbol: "paintbrush.pointed", fallback: "B", label: "Brush",
                  action: #selector(selectBrushTool(_:))),
            .init(symbol: "eraser", fallback: "E", label: "Eraser",
                  action: #selector(selectEraserTool(_:))),
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
            self?.updateStatus()
            self?.updateActiveLayerRect()
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

        let controls: [NSView] = [
            sizeLabel, sizeSlider, sizeField,
            opacityLabel, opacitySlider, opacityValueLabel,
            colorWell,
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
        case .move: canvas.tool = .move
        case .brush: canvas.tool = .brush
        case .eraser: canvas.tool = .eraser
        case .text: canvas.tool = .text
        }
        updateOptionsBar()
        reflectSelectedTool(tool)
        updateStatus()
    }

    /// Mirrors tool selection into the toolbar pill (display only).
    func reflectSelectedTool(_ tool: EditorTool) {
        toolPill?.setSelectedIndex(tool.rawValue)
    }

    @objc func selectSelectTool(_ sender: Any?) { selectTool(.select) }
    @objc func selectMoveTool(_ sender: Any?) { selectTool(.move) }
    @objc func selectBrushTool(_ sender: Any?) { selectTool(.brush) }
    @objc func selectEraserTool(_ sender: Any?) { selectTool(.eraser) }
    @objc func selectTextTool(_ sender: Any?) { selectTool(.text) }

    private func updateOptionsBar() {
        let tool = currentTool
        let paintTool = tool == .brush || tool == .eraser
        for control in [sizeLabel, sizeSlider, sizeField] as [NSView] {
            control.isHidden = !paintTool
        }
        for control in [opacityLabel, opacitySlider, opacityValueLabel] as [NSView] {
            control.isHidden = !paintTool
        }
        colorWell.isHidden = !(tool == .brush || tool == .text)
        fontLabel.isHidden = tool != .text
        fontPopup.isHidden = tool != .text
        fontSizeField.isHidden = tool != .text

        let barHidden = tool == .select || tool == .move
        optionsBar.isHidden = barHidden
        scrollTopToRoot.isActive = false
        scrollTopToOptions.isActive = false
        (barHidden ? scrollTopToRoot : scrollTopToOptions).isActive = true
    }

    private func currentFont() -> NSFont {
        NSFontManager.shared.font(withFamily: fontFamily, traits: [], weight: 5, size: fontSize)
            ?? .systemFont(ofSize: fontSize)
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
            canvas.setSelection(nil)
            zoomToFit()
        } else if let selection = canvas.selectionRect {
            canvas.setSelection(selection) // re-clamp
        }
        canvas.needsDisplay = true
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
            statusLayer.text = info.name
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
        case .move: return "Move"
        case .brush: return "Brush"
        case .eraser: return "Eraser"
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
        canvas.setSelection(CGRect(origin: .zero, size: canvas.bounds.size))
    }

    @objc func deselect(_ sender: Any?) {
        canvas.setSelection(nil)
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
        #selector(selectMoveTool(_:)): .move,
        #selector(selectBrushTool(_:)): .brush,
        #selector(selectEraserTool(_:)): .eraser,
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
        case #selector(cropToSelection(_:)), #selector(deselect(_:)):
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
