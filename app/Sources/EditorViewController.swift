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

    // Design chrome: fixed 36px options bar under the title bar, 48px left
    // tool rail, floating zoom pill, 26px status bar with mono segments.
    // Not private, like `canvas`: the +ToolOptions extension file builds the
    // bar's descriptor clusters and the rail mirrors its swatches.
    var toolRail: ToolRailView!
    let optionsBar = ToolOptionsBar()
    private let zoomPill = ZoomPillView(frame: .zero)
    private let statusDims = StatusSegment(separator: false)
    private let statusMode = StatusSegment(separator: true)
    private let statusSelection = StatusSegment(separator: true)
    private let statusTool = StatusSegment(separator: false)

    private(set) var currentTool: EditorTool = .select

    // Eyedropper readout shown in the options bar: the last sampled pixel.
    // Display only — the sample itself lands in the shared paint color.
    var lastSampleColor: NSColor?
    var lastSampleText = "—"

    // True after a rail swatch pointed the shared color panel at this
    // editor; deinit then clears the panel's (unretained) target.
    private var colorPanelTargetsSelf = false

    // Right panel (Layers/Assistant tabs, toggled by View > Show/Hide Layers).
    var layersPanel: LayersPanelViewController!
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
    // The tool the stroke began with, so ticks route to the right op
    // (dodge/burn is a retouch op, everything else paints the overlay).
    private var strokeTool: EditorTool = .brush
    // The Blend option, latched at stroke begin (brush and clone only):
    // non-Normal ticks composite through the core's blend-mode paint op.
    private var strokeBlendMode = RZ_BLEND_NORMAL

    // The open crop session (logic in EditorViewController+Crop.swift; the
    // canvas draws its overlay and routes the gesture).
    var cropSession: CropSession?
    var shapeEditSession: ShapeEditSession?

    // What brush/eraser edit (see PaintTarget), plus the layer it was chosen
    // for: selecting a different layer drops the choice back to .layer.
    private(set) var paintTarget: PaintTarget = .layer
    private var paintTargetLayer = 0

    // Live copies of the shared colors and text parameters — the canvas and
    // payload builders read these as native types; ToolOptionsStore keeps
    // the persisted form. Internal: the +ToolOptions descriptors bind them.
    var paintColor: NSColor =
        TextLayer.color(fromHex: ToolOptionsStore.shared.sharedState.foreground) ?? .black
    var backgroundColor: NSColor =
        TextLayer.color(fromHex: ToolOptionsStore.shared.sharedState.background) ?? .white
    var fontFamily = ToolOptionsStore.shared.text.family
    var fontSize = CGFloat(min(max(ToolOptionsStore.shared.text.size, 6), 500))
    /// Text-tool line alignment, in the options bar's segment order
    /// (0 left, 1 center, 2 right).
    var textAlignment: NSTextAlignment = EditorViewController.alignmentSegmentValues[
        min(max(ToolOptionsStore.shared.text.alignmentIndex, 0), 2)]
    /// Sampler a Free Transform commit resamples with; remembered between
    /// sessions, like the paint options above.
    var transformSampler = RZ_FILTER_CATMULL_ROM

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
        // The shared color panel's target is unretained: if a rail swatch
        // pointed it at this editor, a pick after the window closes would
        // message a freed controller. There is no target getter, so the
        // guard is the flag set when this editor took the panel over.
        if colorPanelTargetsSelf {
            NSColorPanel.shared.setTarget(nil)
            NSColorPanel.shared.setAction(nil)
        }
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
            self.strokeTool = self.currentTool
            // An adjustment layer's pixels are ignored by the compositor, so
            // strokes ALWAYS land on its mask; with the mask deleted there
            // is nothing left to paint — refuse (the canvas beeps). Clone
            // and dodge rewrite pixels, which an adjustment layer hasn't
            // got, so they refuse outright.
            let idx = document.activeLayerIndex
            let isAdjustment = doc.layerIsAdjustment(idx)
            if self.strokeTool == .clone || self.strokeTool == .dodge, isAdjustment {
                return false
            }
            if isAdjustment, !doc.layerHasMask(idx) { return false }
            // Decided once per stroke so a target change mid-drag can never
            // split it across the layer and its mask. Only brush and eraser
            // ever target a mask.
            let paintsMaskTool = self.strokeTool == .brush || self.strokeTool == .eraser
            let targetsMask = isAdjustment || (paintsMaskTool && self.paintsActiveMask)
            self.strokeTargetsMask = targetsMask
            self.canvas.paintsMask = targetsMask
            guard !targetsMask else {
                // Mask strokes ghost on the canvas and commit in one step
                // from onCommitMaskOverlay: no live-edit session.
                self.strokeBase = nil
                return true
            }
            self.strokeBase = doc
            // Blend applies to strokes that PAINT layer pixels: brush and
            // clone. The eraser is its own composite op and dodge is a
            // retouch op, so both stay Normal whatever their store says.
            self.strokeBlendMode = self.paintStrokeBlendMode()
            document.beginLiveEdit()
            return true
        }
        canvas.onStrokeUpdate = { [weak self] data, mode, alpha in
            guard let self = self, let document = self.document, let base = self.strokeBase
            else { return }
            let idx = document.activeLayerIndex
            // nil = the stroke has missed the layer's extent entirely so far;
            // skip the tick (the projection is already correct).
            let updated: RasterDocument?
            if self.strokeTool == .dodge {
                // The overlay is coverage here; exposure/range/burn come
                // from the tool's options.
                let options = ToolOptionsStore.shared.dodge
                updated = base.dodgeBurnLayer(
                    idx, overlay: data, w: base.width, h: base.height,
                    exposure: min(max(options.opacity, 0), 100) / 100,
                    range: min(max(options.rangeIndex, 0), 2), burn: options.burn)
            } else if mode == RZ_COMPOSITE_OVER, self.strokeBlendMode != RZ_BLEND_NORMAL {
                updated = base.paintingLayerBlend(
                    idx, overlay: data, w: base.width, h: base.height,
                    mode: self.strokeBlendMode, alpha: alpha)
            } else {
                updated = base.paintingLayer(
                    idx, overlay: data, w: base.width, h: base.height, mode: mode, alpha: alpha)
            }
            if let updated = updated {
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
        canvas.onCommitText = { [weak self] payload, origin, editingLayer in
            self?.commitTextLayer(payload, origin: origin, editing: editingLayer)
        }
        canvas.onTextSessionEnd = { [weak self] in
            // Drops the layer-hidden preview a re-edit session put up.
            self?.canvas.previewImage = nil
        }
        canvas.onToolKey = { [weak self] tool in self?.selectToolForKey(tool) }
        canvas.onQuickMaskKey = { [weak self] in self?.toggleQuickMask(nil) }
        canvas.onWandClick = { [weak self] point, mode in self?.wandClicked(point, mode: mode) }
        canvas.onFillClick = { [weak self] point in self?.fillClicked(point) }
        canvas.onEyedropper = { [weak self] point in self?.sampleColor(at: point) }
        canvas.onGradientCommit = { [weak self] a, b in self?.gradientCommitted(a, b) }
        canvas.onBrushSizeKey = { [weak self] newSize in self?.brushSizeKeyChanged(newSize) }
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
        canvas.onCropMouseDown = { [weak self] point in self?.cropMouseDown(point) }
        canvas.onCropMouseDragged = { [weak self] point in self?.cropMouseDragged(point) }
        canvas.onCropMouseUp = { [weak self] point in self?.cropMouseUp(point) }
        canvas.onCropCommit = { [weak self] in self?.commitCropSession() }
        canvas.onCropCancel = { [weak self] in self?.resetCropSession() }
        canvas.onShapeCommit = { [weak self] box, flipped in
            self?.commitShapeLayer(box: box, flipped: flipped)
        }
        canvas.onShapeEditMouseDown = { [weak self] point in self?.shapeEditMouseDown(point) }
        canvas.onShapeEditMouseDragged = { [weak self] point in
            self?.shapeEditMouseDragged(point)
        }
        canvas.onShapeEditMouseUp = { [weak self] in self?.shapeEditSession?.drag = nil }
        canvas.onShapeEditCommit = { [weak self] in self?.commitShapeEditSession() }
        canvas.onShapeEditCancel = { [weak self] in self?.cancelShapeEditSession() }
        canvas.onZoomClick = { [weak self] point, out in self?.zoomStep(at: point, out: out) }
        canvas.onZoomTo = { [weak self] target in self?.applyZoom(target) }
        canvas.onZoomRect = { [weak self] rect in self?.zoomToRect(rect) }

        canvas.paintColor = paintColor
        canvas.textStyle = currentTextStyle()
        syncCanvasPaintState()

        // Fixed-height options bar under the title bar; the +ToolOptions
        // extension builds its per-tool clusters.
        optionsBar.translatesAutoresizingMaskIntoConstraints = false
        optionsBar.onAnyEdit = { [weak self] in self?.toolOptionsEdited() }

        // Left tool rail: the slots — including which tools share one —
        // come from EditorTool.railGroups; its swatches are the shared
        // foreground/background colors.
        toolRail = ToolRailView(groups: EditorTool.railGroups)
        toolRail.translatesAutoresizingMaskIntoConstraints = false
        toolRail.foregroundSwatchColor = paintColor
        toolRail.backgroundSwatchColor = backgroundColor
        toolRail.onPickForeground = { [weak self] in self?.pickForegroundColor() }
        toolRail.onPickBackground = { [weak self] in self?.pickBackgroundColor() }

        let statusBar = BarView(border: .top)
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        let statusLeft = NSStackView(views: [statusDims, statusMode, statusSelection])
        statusLeft.translatesAutoresizingMaskIntoConstraints = false
        statusLeft.orientation = .horizontal
        statusLeft.spacing = 14
        let statusRight = NSStackView(views: [statusTool])
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
        layersPanel.onShapeEdit = { [weak self] idx in
            self?.editShapeLayer(idx)
        }
        layersPanel.onLivePhotoEdit = { [weak self] idx in
            self?.editLivePhotoLayer(idx)
        }
        layersPanel.onLayerStyleEdit = { [weak self] idx in
            self?.editLayerStyle(idx)
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

        root.addSubview(optionsBar)
        root.addSubview(toolRail)
        root.addSubview(scrollView)
        root.addSubview(zoomPill)
        root.addSubview(panelSeparator)
        root.addSubview(panelView)
        root.addSubview(assistantView)
        root.addSubview(statusBar)

        NSLayoutConstraint.activate([
            // The bar is fixed-height and always present, so the canvas
            // well's frame never depends on which tool is active.
            optionsBar.topAnchor.constraint(equalTo: root.topAnchor),
            optionsBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            optionsBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            optionsBar.heightAnchor.constraint(equalToConstant: DS.optionsBarHeight),

            toolRail.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolRail.topAnchor.constraint(equalTo: optionsBar.bottomAnchor),
            toolRail.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            toolRail.widthAnchor.constraint(equalToConstant: DS.railWidth),

            scrollView.leadingAnchor.constraint(equalTo: toolRail.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: optionsBar.bottomAnchor),
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
        // The scroll view's trailing swaps between the panel separator
        // (layers visible) and the window edge (layers hidden).
        scrollTrailingToRoot = scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor)
        scrollTrailingToPanel = scrollView.trailingAnchor.constraint(
            equalTo: panelSeparator.leadingAnchor)
        scrollTrailingToPanel.isActive = true

        view = root
        updateOptionsBar()
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
        // A planned tool has no behavior yet; menu validation already
        // disables its items, this backstops the rail and bare keys.
        guard !tool.planned else {
            NSSound.beep()
            return
        }
        // Switching tools leaves the transform session, which commits it
        // rather than silently dropping the drag; leaving the crop tool
        // quietly drops its (uncommitted) box.
        commitPendingTransform()
        if currentTool == .text, tool != .text {
            canvas.commitTextSession()
        }
        if currentTool == .crop, tool != .crop {
            endCropSession()
        }
        // Leaving a reopened shape commits it (the text session's rule);
        // an untouched session commits nothing.
        if shapeEditSession != nil, tool != currentTool {
            commitShapeEditSession()
        }
        currentTool = tool
        canvas.tool = tool
        // Only brush and eraser edit masks; picking one of the other paint
        // tools silently points the target back at the layer rather than
        // blocking the tool or painting the wrong thing.
        if tool == .fill || tool == .gradient || tool == .text
            || tool == .clone || tool == .dodge {
            setPaintTarget(.layer)
        }
        if tool == .crop {
            beginCropSession()
        }
        syncCanvasPaintState()
        updateOptionsBar()
        reflectSelectedTool(tool)
        updateStatus()
    }

    /// A bare tool key. A key shared by several tools (the shape group's R)
    /// cycles them on repeated presses; a key owned by one tool just selects
    /// it, exactly as before.
    func selectToolForKey(_ tool: EditorTool) {
        let peers = EditorTool.allCases.filter {
            $0.keyCharacter == tool.keyCharacter && !$0.planned
        }
        guard let first = peers.first else {
            NSSound.beep()
            return
        }
        if let index = peers.firstIndex(of: currentTool), peers.count > 1 {
            selectTool(peers[(index + 1) % peers.count])
        } else {
            selectTool(first)
        }
    }

    /// Pushes the options-store state the canvas consumes — the active
    /// paint tool's size and opacity, the shared color, the selection
    /// gesture options, the shape style, scrubby zoom — into the canvas.
    func syncCanvasPaintState() {
        let store = ToolOptionsStore.shared
        canvas.paintColor = paintColor
        if let paint = store.paintOptions(for: currentTool) {
            canvas.brushSize = CGFloat(min(max(paint.size, 1), 200))
            canvas.brushOpacity = CGFloat(min(max(paint.opacity, 0), 100) / 100)
            canvas.brushHardness = CGFloat(min(max(paint.hardness, 0), 100) / 100)
            canvas.brushFlow = CGFloat(min(max(paint.flow, 1), 100) / 100)
            canvas.brushSpacingPercent = CGFloat(min(max(paint.spacing, 1), 200))
            canvas.brushAngle = CGFloat(min(max(paint.angle, -180), 180))
            canvas.brushRoundness = CGFloat(min(max(paint.roundness, 1), 100) / 100)
            canvas.brushSmoothing = CGFloat(min(max(paint.smoothing, 0), 100) / 100)
            canvas.brushPressureSize = paint.pressureSize
            canvas.brushAirbrush = paint.airbrush
        }
        let modes: [SelectionCombineMode] = [.replace, .add, .subtract, .intersect]
        canvas.selectionCombineBase = modes[min(max(store.select.modeIndex, 0), 3)]
        canvas.selectionFeather = max(store.select.feather, 0)
        canvas.scrubbyZoom = store.view.scrubbyZoom
        syncCanvasShapeStyle()
    }

    /// Bare [ and ] on the canvas: steps the active paint tool's size and
    /// mirrors it into the store, the canvas and the options bar.
    func brushSizeKeyChanged(_ newSize: CGFloat) {
        guard var paint = ToolOptionsStore.shared.paintOptions(for: currentTool) else { return }
        paint.size = Double(newSize)
        ToolOptionsStore.shared.setPaintOptions(paint, for: currentTool)
        canvas.brushSize = newSize
        optionsBar.refreshValues()
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
    func syncPaintTarget() {
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

    /// Mirrors tool selection into the rail (display only). A grouped slot
    /// also starts standing for this tool, so the group remembers what was
    /// last used in it.
    func reflectSelectedTool(_ tool: EditorTool) {
        toolRail?.setSelectedTool(tool)
    }

    @objc func selectSelectTool(_ sender: Any?) { selectTool(.select) }
    @objc func selectEllipseTool(_ sender: Any?) { selectTool(.ellipseSelect) }
    @objc func selectLassoTool(_ sender: Any?) { selectTool(.lasso) }
    @objc func selectWandTool(_ sender: Any?) { selectTool(.wand) }
    @objc func selectSubjectTool(_ sender: Any?) { selectTool(.subject) }
    @objc func selectMoveTool(_ sender: Any?) { selectTool(.move) }
    @objc func selectBrushTool(_ sender: Any?) { selectTool(.brush) }
    @objc func selectEraserTool(_ sender: Any?) { selectTool(.eraser) }
    @objc func selectFillTool(_ sender: Any?) { selectTool(.fill) }
    @objc func selectGradientTool(_ sender: Any?) { selectTool(.gradient) }
    @objc func selectTextTool(_ sender: Any?) { selectTool(.text) }
    @objc func selectEyedropperTool(_ sender: Any?) { selectTool(.eyedropper) }
    @objc func selectCropTool(_ sender: Any?) { selectTool(.crop) }
    @objc func selectCloneTool(_ sender: Any?) { selectTool(.clone) }
    @objc func selectDodgeTool(_ sender: Any?) { selectTool(.dodge) }
    @objc func selectShapeRectTool(_ sender: Any?) { selectTool(.shapeRect) }
    @objc func selectShapeEllipseTool(_ sender: Any?) { selectTool(.shapeEllipse) }
    @objc func selectShapeLineTool(_ sender: Any?) { selectTool(.shapeLine) }
    @objc func selectZoomTool(_ sender: Any?) { selectTool(.zoom) }
    @objc func selectHandTool(_ sender: Any?) { selectTool(.hand) }

    /// Rebuilds the fixed-height options bar for the current state. The
    /// descriptor lists live in EditorViewController+ToolOptions.swift; a
    /// Free Transform session takes the whole bar over (it is modal on the
    /// canvas, so the active tool's own options cannot be used).
    func updateOptionsBar() {
        presentToolOptions()
    }

    // MARK: - Agent access to the selection

    /// The canvas selection, for the agent's fill/gradient/crop tools.
    var agentSelection: CanvasSelection? { canvas.selection }

    func agentSetSelection(_ selection: CanvasSelection?) {
        canvas.setSelection(selection)
    }

    // MARK: - Wand, fill, gradient actions

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
        let options = ToolOptionsStore.shared.select
        guard let doc = document?.doc,
            let mask = doc.magicWand(
                x: Int(point.x), y: Int(point.y),
                tolerance: Int(options.tolerance.rounded()),
                contiguous: options.contiguous),
            var selection = CanvasSelection(
                shape: .mask(mask), canvasWidth: doc.width, canvasHeight: doc.height)
        else {
            NSSound.beep()
            return
        }
        // The bar's Feather applies here too — the wand commits outside the
        // canvas's commitSelection, so it feathers its own result.
        if options.feather > 0, let feathered = selection.feathered(by: options.feather) {
            selection = feathered
        }
        // An all-zero combination comes back nil and deselects.
        canvas.setSelection(CanvasSelection.combine(canvas.selection, with: selection, mode: mode))
    }

    private func fillClicked(_ point: CGPoint) {
        guard let document = document else { return }
        // A canvas click can't be blocked by menu validation: refuse a fill
        // aimed at an adjustment layer's (ignored) pixels with the alert.
        guard !refuseAdjustmentPixelEdit() else { return }
        let options = ToolOptionsStore.shared.fill
        let idx = document.activeLayerIndex
        // The bar's opacity rides in the fill color's own alpha.
        let opacity = min(max(options.opacity, 0), 100) / 100
        let rgba = colorBytes(paintColor.withAlphaComponent(
            paintColor.alphaComponent * CGFloat(opacity)))
        let mask = canvas.selection?.maskBytes()
        document.applyRasterizingEdit("Fill", layer: idx) { doc in
            doc.bucketFilled(
                idx, x: Int(point.x), y: Int(point.y),
                tolerance: Int(options.tolerance.rounded()),
                rgba: rgba, contiguous: options.contiguous, mask: mask)
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
              let projection = document.projection ?? document.doc?.flattened()
        else { return }
        let options = ToolOptionsStore.shared.sample
        // Sample size: a point, or the plain mean of the 3×3 / 5×5 window
        // (out-of-bounds pixels just drop out of the mean).
        let reach = [0, 1, 2][min(max(options.sampleSizeIndex, 0), 2)]
        let px = Int(floor(point.x))
        let py = Int(floor(point.y))
        var sum = (r: 0, g: 0, b: 0, a: 0)
        var count = 0
        for dy in -reach...reach {
            for dx in -reach...reach {
                guard let pixel = projection.pixelRGBA(x: px + dx, y: py + dy) else { continue }
                sum.r += Int(pixel.r)
                sum.g += Int(pixel.g)
                sum.b += Int(pixel.b)
                sum.a += Int(pixel.a)
                count += 1
            }
        }
        guard count > 0 else { return }
        let sample = (
            r: UInt8(sum.r / count), g: UInt8(sum.g / count),
            b: UInt8(sum.b / count), a: UInt8(sum.a / count))
        setPaintColor(NSColor(
            srgbRed: CGFloat(sample.r) / 255, green: CGFloat(sample.g) / 255,
            blue: CGFloat(sample.b) / 255, alpha: CGFloat(sample.a) / 255))
        lastSampleColor = paintColor
        lastSampleText = RasterImage.hexString(sample)
        if options.copyOnPick {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(lastSampleText, forType: .string)
        }
        optionsBar.refreshValues()
    }

    private func gradientCommitted(_ a: CGPoint, _ b: CGPoint) {
        guard let document = document else { return }
        // Same rule as fillClicked: a gradient drag ends on the canvas,
        // outside menu validation's reach.
        guard !refuseAdjustmentPixelEdit() else { return }
        let options = ToolOptionsStore.shared.gradient
        let idx = document.activeLayerIndex
        // Foreground → background (the rail's swatches); Reverse swaps them
        // and the bar's opacity rides in both colors' alpha.
        let opacity = CGFloat(min(max(options.opacity, 0), 100) / 100)
        let fade: (NSColor) -> [UInt8] = { [weak self] color in
            self?.colorBytes(color.withAlphaComponent(color.alphaComponent * opacity))
                ?? [0, 0, 0, 0]
        }
        let start = fade(options.reverse ? backgroundColor : paintColor)
        let end = fade(options.reverse ? paintColor : backgroundColor)
        let kind: RzGradientKind =
            options.typeIndex == 1 ? RZ_GRADIENT_RADIAL : RZ_GRADIENT_LINEAR
        let mask = canvas.selection?.maskBytes()
        document.applyRasterizingEdit("Gradient", layer: idx) { doc in
            doc.gradiented(idx, from: a, to: b, start: start, end: end, kind: kind, mask: mask)
        }
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
        case distort(corner: Int, start: LayerTransform)
    }

    /// Samplers offered for the commit-time resample, in popup order.
    /// Internal: the +ToolOptions descriptors list the titles.
    static let transformSamplers: [(title: String, value: RzResizeFilter)] = [
        ("Nearest", RZ_FILTER_NEAREST),
        ("Bilinear", RZ_FILTER_BILINEAR),
        ("Bicubic (Catmull-Rom)", RZ_FILTER_CATMULL_ROM),
        ("Lanczos", RZ_FILTER_LANCZOS3),
    ]

    /// Widest scale the numeric fields accept, mirroring
    /// LayerTransform.maxScaleMagnitude.
    static let maxScalePercent = Double(LayerTransform.maxScaleMagnitude) * 100

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
            // A described layer pivots on its description's exact centre
            // (EditorViewController+DescribedTransform.swift), a raster on
            // its rect's.
            transform: LayerTransform(
                pivot: doc.describedPivot(idx) ?? CGPoint(x: rect.midX, y: rect.midY)),
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
        canvas.transformPreview = ImageCanvasView.TransformPreview(
            below: session.below,
            above: session.above,
            layer: session.layerImage,
            mask: session.maskImage,
            sourceRect: session.sourceRect,
            matrix: session.transform.matrix,
            opacity: session.opacity,
            quad: session.transform.warpedQuad(of: session.sourceRect),
            pivot: session.transform.pivotInCanvas,
            interpolate: session.sampler != RZ_FILTER_NEAREST,
            warped: session.transform.hasCornerOffsets)
    }

    /// The parameters → controls half of the binding (the descriptors'
    /// setters are the other half): the bar re-reads every binding.
    private func updateTransformFields() {
        optionsBar.refreshValues()
    }

    // MARK: Free Transform gestures

    /// What a press at `point` grabs: a handle (⌘ on a corner pulls that
    /// corner alone — distort/perspective — otherwise scale), the ring just
    /// outside a corner (rotate), or the body (move). A press beyond all of
    /// them does nothing — clicking away must not silently commit.
    private func transformDrag(
        at point: CGPoint, session: TransformSession, modifiers: NSEvent.ModifierFlags
    ) -> TransformDrag? {
        let scale = canvas.magnification
        let slop = ImageCanvasView.transformHandleSize / scale
        for handle in TransformHandle.allCases {
            let world = session.transform.warpedHandlePoint(handle, of: session.sourceRect)
            if abs(point.x - world.x) <= slop, abs(point.y - world.y) <= slop {
                if modifiers.contains(.command), handle.isCorner,
                   let corner = handle.quadCorners.first {
                    return .distort(corner: corner, start: session.transform)
                }
                return .scale(handle: handle, start: session.transform)
            }
        }
        let corners = session.transform.warpedQuad(of: session.sourceRect)
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
        transformSession?.drag = transformDrag(at: point, session: session, modifiers: modifiers)
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
        case let .distort(corner, start):
            updated = LayerTransform.distorting(
                start, corner: corner, to: point, in: session.sourceRect)
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

    // MARK: Free Transform options bar (descriptor bindings)

    // The session and its struct stay private; the +ToolOptions descriptors
    // read and write the parameters through these. Every setter re-renders
    // the preview and lets the bar re-read the whole set, so W tracks a
    // scale edit and vice versa. W = |scaleX| × base width, so typing W
    // sets scaleX = W / base width — preserving the current sign, so a
    // mirrored layer stays mirrored — through the same clamp the scale
    // setters use; bad input just snaps back to the current value.

    var transformDegrees: Double {
        get { transformSession?.transform.degrees ?? 0 }
        set {
            guard transformSession != nil else { return }
            transformSession?.transform.degrees = min(max(newValue, -360), 360)
            refreshTransformPreview()
        }
    }

    var transformScaleXPercent: Double {
        get { Double(transformSession?.transform.scaleX ?? 1) * 100 }
        set {
            guard transformSession != nil else { return }
            transformSession?.transform.scaleX = LayerTransform.clampScale(CGFloat(newValue / 100))
            refreshTransformPreview()
        }
    }

    var transformScaleYPercent: Double {
        get { Double(transformSession?.transform.scaleY ?? 1) * 100 }
        set {
            guard transformSession != nil else { return }
            transformSession?.transform.scaleY = LayerTransform.clampScale(CGFloat(newValue / 100))
            refreshTransformPreview()
        }
    }

    var transformWidthPixels: Double {
        get {
            guard let session = transformSession else { return 0 }
            return Double((abs(session.transform.scaleX) * session.sourceRect.width).rounded())
        }
        set {
            guard let session = transformSession, newValue > 0,
                  session.sourceRect.width > 0 else { return }
            let sign: CGFloat = session.transform.scaleX < 0 ? -1 : 1
            transformSession?.transform.scaleX = LayerTransform.clampScale(
                sign * CGFloat(newValue) / session.sourceRect.width)
            refreshTransformPreview()
        }
    }

    var transformHeightPixels: Double {
        get {
            guard let session = transformSession else { return 0 }
            return Double((abs(session.transform.scaleY) * session.sourceRect.height).rounded())
        }
        set {
            guard let session = transformSession, newValue > 0,
                  session.sourceRect.height > 0 else { return }
            let sign: CGFloat = session.transform.scaleY < 0 ? -1 : 1
            transformSession?.transform.scaleY = LayerTransform.clampScale(
                sign * CGFloat(newValue) / session.sourceRect.height)
            refreshTransformPreview()
        }
    }

    var transformSamplerListIndex: Int {
        get { Self.transformSamplerIndex(transformSession?.sampler ?? transformSampler) }
        set {
            let index = min(max(newValue, 0), Self.transformSamplers.count - 1)
            transformSampler = Self.transformSamplers[index].value
            transformSession?.sampler = transformSampler
            // Nearest previews without smoothing, so the box shows the hard
            // pixel edges the commit will produce.
            refreshTransformPreview()
        }
    }

    // MARK: Free Transform commit / cancel

    /// Runs the session's matrix through the core as ONE undo step named
    /// "Transform Layer" — composed into a described layer's description
    /// (no prompt) when the session is a plain affine, resampled otherwise.
    /// Returns false when the commit did NOT happen and the session must
    /// stay open: the core refused the matrix, or the user cancelled the
    /// rasterize prompt.
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
        let describesSource = document.layerDescribesSource(idx)
        // A distorted box commits through the perspective op with its warped
        // corners; a plain affine keeps the matrix path and its lossless
        // exact forms.
        let quad = session.transform.hasCornerOffsets
            ? session.transform.warpedQuad(of: session.sourceRect) : nil
        let matrix = session.transform.matrix
        // An affine on a described layer — plain, or a warped box that is
        // still a parallelogram — composes into the description and
        // re-renders (EditorViewController+DescribedTransform.swift): no
        // prompt. A true perspective quad, or a description that cannot
        // render right now (a missing font, a Live Photo whose source will
        // not decode), takes the rasterize prompt below as before —
        // resampling the real pixels is what the prompt gates. Taken here
        // rather than through applyRasterizingEdit: Cancel has to keep the
        // session open instead of abandoning the whole gesture.
        if describesSource {
            isCommittingTransform = true
            let outcome = commitDescribedTransform(
                layer: idx, matrix: matrix, quad: quad, sampler: session.sampler)
            isCommittingTransform = false
            switch outcome {
            case .committed:
                endTransformSession()
                return true
            case .refused:
                return false
            case .unrenderable:
                break
            }
        }
        if describesSource,
           !document.confirmRasterize(layer: idx, reason: document.unrenderableReason(layer: idx))
        { return false }
        let sampler = session.sampler
        let before = document.doc
        isCommittingTransform = true
        document.applyEdit("Transform Layer") { doc in
            let transformed = quad.map { doc.perspectiveLayer(idx, quad: $0, sampler: sampler) }
                ?? doc.transformingLayer(idx, matrix, sampler: sampler)
            guard let transformed else { return nil }
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

    // MARK: - Options bar and rail plumbing

    /// The single write path for the shared paint color (options-bar
    /// swatches, eyedropper samples, the rail's foreground swatch): brush,
    /// fill, gradient start, and text all read `paintColor`, and the rail,
    /// store and canvas mirror it.
    func setPaintColor(_ color: NSColor) {
        paintColor = color
        toolRail?.foregroundSwatchColor = color
        canvas.paintColor = color
        canvas.updateActiveTextSessionStyle()
        var shared = ToolOptionsStore.shared.sharedState
        shared.foreground = TextLayer.hex(color)
        ToolOptionsStore.shared.sharedState = shared
    }

    /// The background color's write path (the rail's second swatch): the
    /// gradient tool's end color.
    func setBackgroundColor(_ color: NSColor) {
        backgroundColor = color
        toolRail?.backgroundSwatchColor = color
        var shared = ToolOptionsStore.shared.sharedState
        shared.background = TextLayer.hex(color)
        ToolOptionsStore.shared.sharedState = shared
    }

    /// Rail swatch clicks: the shared color panel, retargeted at whichever
    /// swatch was clicked last.
    func pickForegroundColor() {
        openColorPanel(action: #selector(colorPanelPickedForeground(_:)))
    }

    func pickBackgroundColor() {
        openColorPanel(action: #selector(colorPanelPickedBackground(_:)))
    }

    private func openColorPanel(action: Selector) {
        let panel = NSColorPanel.shared
        panel.showsAlpha = true
        panel.setTarget(self)
        panel.setAction(action)
        colorPanelTargetsSelf = true
        panel.color = action == #selector(colorPanelPickedForeground(_:))
            ? paintColor : backgroundColor
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func colorPanelPickedForeground(_ sender: Any?) {
        setPaintColor(NSColorPanel.shared.color)
        optionsBar.refreshValues()
    }

    @objc private func colorPanelPickedBackground(_ sender: Any?) {
        setBackgroundColor(NSColorPanel.shared.color)
        optionsBar.refreshValues()
    }

    /// Fired by the options bar after any control commits a value: mirror
    /// whatever may have changed into the canvas and the status line.
    func toolOptionsEdited() {
        syncCanvasPaintState()
        canvas.textStyle = currentTextStyle()
        canvas.updateActiveTextSessionStyle()
        toolRail?.foregroundSwatchColor = paintColor
        toolRail?.backgroundSwatchColor = backgroundColor
        updateStatus()
    }

    /// Segment order of the alignment control, which is also the payload's
    /// `alignments` order.
    static let alignmentSegmentValues: [NSTextAlignment] = [.left, .center, .right]

    static func alignmentIndex(_ alignment: NSTextAlignment) -> Int {
        alignmentSegmentValues.firstIndex(of: alignment) ?? 0
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

    /// The zoom tool's click: one ladder step in (or out, with ⌥), keeping
    /// the clicked point where it is.
    func zoomStep(at point: CGPoint, out: Bool) {
        let current = scrollView.magnification
        let next: CGFloat
        if out {
            guard let below = Self.zoomLadder.last(where: { $0 < current - 0.0001 }) else { return }
            next = below
        } else {
            next = Self.zoomLadder.first { $0 > current + 0.0001 } ?? Self.zoomLadder.last ?? 1
        }
        scrollView.setMagnification(
            min(max(next, scrollView.minMagnification), scrollView.maxMagnification),
            centeredAt: point)
        updateZoomLabel()
    }

    /// The zoom tool's marquee: fill the viewport with the dragged rect.
    func zoomToRect(_ rect: CGRect) {
        guard rect.width > 0, rect.height > 0 else { return }
        scrollView.magnify(toFit: rect)
        updateZoomLabel()
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
        // Same for an open shape-edit session: an external edit (agent,
        // undo) may have renumbered or rewritten the layer it describes,
        // so it closes without committing. The session's own commit ends
        // it before applying, so a commit never lands here.
        if shapeEditSession != nil {
            endShapeEditSession()
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
            // A crop box measured against the old canvas is meaningless:
            // reopen it over the new one.
            if currentTool == .crop {
                beginCropSession()
            }
        }
        canvas.needsDisplay = true
        syncPaintTarget()
        updateStatus()
        updateActiveLayerRect()
        view.window?.subtitle = "\(doc.width) × \(doc.height) px"
    }

    // MARK: - Status bar

    // The redesign's reduced segment set: dimensions, mode, selection on
    // the left; the active tool and its key on the right. Layer name, blend
    // mode, opacity and the zoom percentage were deliberately dropped —
    // all visible in the Layers panel or the zoom pill.
    func updateStatus() {
        guard let document = document, let doc = document.doc else {
            statusDims.text = "No document open"
            statusMode.text = ""
            statusSelection.text = ""
            statusTool.text = "Drop a file, or ⌘O"
            return
        }
        statusDims.text = "\(doc.width) × \(doc.height) px"
        statusMode.text = "RGB · 8-bit"
        if canvas.quickMaskActive {
            // The selection segment's slot: the mode holds the selection as
            // its editable buffer, so this is what "selected" currently is.
            statusSelection.text = "Quick Mask"
        } else if let selection = canvas.selectionRect {
            statusSelection.text =
                "Selection: \(Int(selection.width)) × \(Int(selection.height)) px"
        } else {
            statusSelection.text = "Selection: none"
        }
        // Brush and eraser hit the mask when it is the paint target; say
        // so, alongside the panel's focus ring.
        let maskSuffix = paintTarget == .mask ? " · Mask" : ""
        statusTool.text = isTransforming
            ? "Free Transform"
            : "\(currentTool.displayName) · \(currentTool.keyCharacter.uppercased())\(maskSuffix)"
        updateZoomLabel()
    }

    /// Pushes the active layer's extent (image-pixel coordinates) to the
    /// canvas, which shows the boundary while a paint tool is active and
    /// the layer doesn't cover the whole canvas.
    func updateActiveLayerRect() {
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
        // The zoom tool's options show the same number.
        if currentTool == .zoom || currentTool == .hand {
            optionsBar.refreshValues()
        }
    }

    /// The magnification as the options bar's percentage field, applied
    /// through the same clamp the menu actions use.
    var zoomPercent: Double {
        get { Double(scrollView.magnification) * 100 }
        set { applyZoom(CGFloat(newValue / 100)) }
    }

    /// Fill the viewport: the larger of the two fit scales, so the canvas
    /// covers the well with no letterboxing.
    func zoomToFill() {
        guard let doc = document?.doc else { return }
        let size = doc.canvasSize
        guard size.width > 0, size.height > 0 else { return }
        let available = scrollView.contentSize
        let scale = max(available.width / size.width, available.height / size.height)
        applyZoom(min(scale, 32))
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

    // Whole-document geometry goes through applyingDocumentGeometry
    // (DescribedLayerGeometry.swift), which composes the op into every text,
    // shape and Live Photo description so a later re-edit lands in place.
    @objc func rotateCW(_ sender: Any?) {
        performGeometry(.rotate90)
    }

    @objc func rotateCCW(_ sender: Any?) {
        performGeometry(.rotate270)
    }

    @objc func rotate180(_ sender: Any?) {
        performGeometry(.rotate180)
    }

    @objc func flipH(_ sender: Any?) {
        performGeometry(.flipHorizontal)
    }

    @objc func flipV(_ sender: Any?) {
        performGeometry(.flipVertical)
    }

    private func performGeometry(_ op: DocumentGeometry) {
        performEdit(op.actionName) { $0.applyingDocumentGeometry(op) }
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
        // The panel's double-click bypasses menu validation, so an open
        // shape session commits here — its hidden-layer preview and the
        // sheet's live preview would otherwise fight over previewImage.
        commitShapeEditSession()
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
        // A reopened shape commits before the mode takes the canvas — the
        // same click-away rule the canvas applies.
        if shapeEditSession != nil {
            commitShapeEditSession()
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

    /// Edit > Cut (⌘X): Copy then Clear as one step — the ACTIVE LAYER's
    /// pixels within the selection go to the clipboard exactly as Copy takes
    /// them, then the selected region is cleared out of the layer as one
    /// undoable "Cut" edit. The copy lands first, and only a copy that
    /// succeeded lets the clear proceed, so pixels are never deleted without
    /// having been captured; a Cancel on the rasterize prompt then degrades
    /// to a plain Copy.
    @objc func cut(_ sender: Any?) {
        guard let document = document, let doc = document.doc,
              let selection = canvas.selection
        else {
            NSSound.beep()
            return
        }
        // Validation disables the menu item on an adjustment layer; this
        // backstop covers any path around it.
        guard !refuseAdjustmentPixelEdit() else { return }
        let idx = document.activeLayerIndex
        guard copyToPasteboard(doc.layerCanvasImage(idx)) else { return }
        let mask = selection.maskBytes()
        document.applyRasterizingEdit("Cut", layer: idx) { doc in
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

    /// Shared tail of Cut and both copies: multiply the canvas-sized
    /// source's alpha by the selection's coverage — only the SELECTED pixels
    /// come along, so anything inside the bounding box but outside the shape
    /// goes transparent, and a feathered or anti-aliased edge fades out
    /// across the fringe, exactly as Clear removes it — then crop to the
    /// selection's BOUNDS (the whole canvas without a selection) and write
    /// TIFF + PNG. True when the clipboard was written — Cut clears only on
    /// success.
    @discardableResult
    private func copyToPasteboard(_ source: RasterImage?) -> Bool {
        var image = source
        if let selection = canvas.selection {
            let bounds = selection.bounds
            image = image?.masked(by: selection.maskBytes())
            image = image?.cropped(
                x: Int(bounds.minX), y: Int(bounds.minY),
                w: Int(bounds.width), h: Int(bounds.height))
        }
        guard let cgImage = image?.makeCGImage() else {
            NSSound.beep()
            return false
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        let item = NSPasteboardItem()
        if let tiffData = rep.representation(using: .tiff, properties: [:]) {
            item.setData(tiffData, forType: .tiff)
        }
        if let pngData = rep.representation(using: .png, properties: [:]) {
            item.setData(pngData, forType: .png)
        }
        // The success return is load-bearing (Cut deletes on it), so an item
        // both encodes failed to fill, or a write the pasteboard refuses,
        // must report failure — not fall through as a silent success.
        guard !item.types.isEmpty else {
            NSSound.beep()
            return false
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
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
    /// session — text entry, a reopened shape, or a Free Transform — is
    /// never silently dropped from the written file.
    func commitPendingSessions() {
        canvas.commitTextSession()
        commitShapeEditSession()
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
        #selector(selectSubjectTool(_:)): .subject,
        #selector(selectMoveTool(_:)): .move,
        #selector(selectBrushTool(_:)): .brush,
        #selector(selectEraserTool(_:)): .eraser,
        #selector(selectFillTool(_:)): .fill,
        #selector(selectGradientTool(_:)): .gradient,
        #selector(selectTextTool(_:)): .text,
        #selector(selectEyedropperTool(_:)): .eyedropper,
        #selector(selectCropTool(_:)): .crop,
        #selector(selectCloneTool(_:)): .clone,
        #selector(selectDodgeTool(_:)): .dodge,
        #selector(selectShapeRectTool(_:)): .shapeRect,
        #selector(selectShapeEllipseTool(_:)): .shapeEllipse,
        #selector(selectShapeLineTool(_:)): .shapeLine,
        #selector(selectZoomTool(_:)): .zoom,
        #selector(selectHandTool(_:)): .hand,
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
            // A planned tool stays visible with its "Soon" affordance but
            // never enabled — in menus, the rail's dropdowns, anywhere.
            return !tool.planned
        }

        // While a text session, a shape-edit session or a Free Transform is
        // active, only tool switching (handled above — it commits the
        // session) and zooming are safe; edit/filter/clipboard actions must
        // not mutate the image underneath the session, and Free Transform
        // must not re-enter.
        if canvas.hasActiveTextSession || isTransforming || shapeEditSession != nil {
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
        case #selector(cut(_:)):
            // Cut is Copy + Clear in one step, so it needs what Clear needs:
            // a selection and an active layer with pixels. No text-editing
            // guard — ⌘X reaches a field editor first, which claims cut:
            // itself, exactly as ⌘C does for copy.
            guard canvas.selection != nil, !activeLayerIsAdjustment else { return false }
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
        case #selector(layerStyle(_:)), #selector(layerStyleEffect(_:)):
            return canEditLayerStyle
        case #selector(pasteLayerStyle(_:)):
            return canPasteLayerStyle
        case #selector(copyLayerStyle(_:)), #selector(clearLayerStyle(_:)):
            return activeLayerHasStyle
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
