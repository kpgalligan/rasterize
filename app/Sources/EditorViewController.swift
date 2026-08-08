import AppKit

/// Tools offered by the editor UI. Raw values are the toolbar group's
/// segment indices.
enum EditorTool: Int {
    case select = 0
    case brush
    case eraser
    case text
}

final class EditorViewController: NSViewController {
    private weak var document: ImageDocument?

    private let scrollView = NSScrollView()
    private let canvas = ImageCanvasView()
    private let statusLabel = NSTextField(labelWithString: "")
    private var zoomPopup: NSPopUpButton!
    private var zoomTitleItem: NSMenuItem!
    private var didRunInitialZoom = false

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
        let root = FileDropView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.02
        scrollView.maxMagnification = 32
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .underPageBackgroundColor
        scrollView.usesPredominantAxisScrolling = false
        scrollView.documentView = canvas

        if let image = document?.image {
            canvas.frame = NSRect(origin: .zero, size: image.pixelSize)
            canvas.image = image.makeCGImage()
        }
        canvas.onSelectionChange = { [weak self] _ in self?.updateStatus() }
        canvas.onCommitOverlay = { [weak self] data, mode, alpha, actionName in
            self?.performEdit(actionName) {
                $0.composited(
                    premultipliedOverlay: data, width: $0.width, height: $0.height,
                    mode: mode, alpha: alpha)
            }
        }
        canvas.onToolKey = { [weak self] tool in
            switch tool {
            case .select: self?.selectTool(.select)
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

        buildOptionsBar()
        canvas.brushSize = brushSize
        canvas.paintColor = paintColor
        canvas.brushOpacity = brushOpacity
        canvas.textFont = currentFont()

        let statusBar = NSView()
        statusBar.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = NSFont.monospacedDigitSystemFont(
            ofSize: NSFont.smallSystemFontSize, weight: .regular)
        statusLabel.lineBreakMode = .byTruncatingTail

        let popup = NSPopUpButton(frame: .zero, pullsDown: true)
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.controlSize = .small
        popup.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let zoomMenu = NSMenu()
        let titleItem = NSMenuItem(title: "100%", action: nil, keyEquivalent: "")
        zoomMenu.addItem(titleItem)
        for percent in [5, 10, 25, 50, 100, 200, 400, 800] {
            let item = NSMenuItem(
                title: "\(percent)%", action: #selector(zoomPresetSelected(_:)), keyEquivalent: "")
            item.target = self
            item.tag = percent
            zoomMenu.addItem(item)
        }
        let fitItem = NSMenuItem(
            title: "Fit", action: #selector(zoomPresetSelected(_:)), keyEquivalent: "")
        fitItem.target = self
        fitItem.tag = -1
        zoomMenu.addItem(fitItem)
        popup.menu = zoomMenu
        zoomPopup = popup
        zoomTitleItem = titleItem

        statusBar.addSubview(separator)
        statusBar.addSubview(statusLabel)
        statusBar.addSubview(popup)
        root.addSubview(optionsBar)
        root.addSubview(scrollView)
        root.addSubview(statusBar)

        NSLayoutConstraint.activate([
            optionsBar.topAnchor.constraint(equalTo: root.topAnchor),
            optionsBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            optionsBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            optionsBar.heightAnchor.constraint(equalToConstant: 30),

            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            statusBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 27),

            separator.topAnchor.constraint(equalTo: statusBar.topAnchor),
            separator.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor),

            statusLabel.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 12),
            statusLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            statusLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: popup.leadingAnchor, constant: -12),

            popup.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor, constant: -12),
            popup.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            popup.widthAnchor.constraint(greaterThanOrEqualToConstant: 76),
        ])
        // The scroll view's top swaps between the window content top (select
        // tool, bar hidden) and the options bar's bottom (all other tools).
        scrollTopToRoot = scrollView.topAnchor.constraint(equalTo: root.topAnchor)
        scrollTopToOptions = scrollView.topAnchor.constraint(equalTo: optionsBar.bottomAnchor)

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
        updateZoomLabel()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !didRunInitialZoom else { return }
        didRunInitialZoom = true
        guard let image = document?.image else { return }
        canvas.setFrameSize(image.pixelSize)
        let visible = scrollView.contentSize
        if image.pixelSize.width > visible.width || image.pixelSize.height > visible.height {
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
        case .brush: canvas.tool = .brush
        case .eraser: canvas.tool = .eraser
        case .text: canvas.tool = .text
        }
        updateOptionsBar()
        (view.window?.windowController as? EditorWindowController)?.reflectSelectedTool(tool)
    }

    @objc func selectSelectTool(_ sender: Any?) { selectTool(.select) }
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

        let barHidden = tool == .select
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
        guard let image = document?.image else { return }
        let size = image.pixelSize
        guard size.width > 0, size.height > 0 else { return }
        let margin: CGFloat = 16
        let available = NSSize(
            width: max(scrollView.contentSize.width - margin * 2, 1),
            height: max(scrollView.contentSize.height - margin * 2, 1))
        let scale = min(available.width / size.width, available.height / size.height)
        applyZoom(min(scale, 8)) // fit may exceed 100% for small images, capped at 8
    }

    // MARK: - Image change

    @objc private func imageDidChange(_ note: Notification) {
        guard let document = document,
              (note.object as? ImageDocument) === document,
              let image = document.image
        else { return }
        let newSize = image.pixelSize
        let dimensionsChanged = canvas.frame.size != newSize
        canvas.image = image.makeCGImage()
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
        view.window?.subtitle = "\(image.width) × \(image.height) px"
    }

    // MARK: - Status bar

    private func updateStatus() {
        guard let image = document?.image else {
            statusLabel.stringValue = ""
            return
        }
        var text = "\(image.width) × \(image.height) px"
        if let selection = canvas.selectionRect {
            text += " — sel \(Int(selection.width))×\(Int(selection.height))"
        }
        statusLabel.stringValue = text
    }

    private func updateZoomLabel() {
        let percent = Int((scrollView.magnification * 100).rounded())
        zoomTitleItem?.title = "\(percent)%"
    }

    @objc private func magnificationDidChange(_ note: Notification) {
        updateZoomLabel()
    }

    @objc private func zoomPresetSelected(_ sender: NSMenuItem) {
        if sender.tag == -1 {
            zoomToFit()
        } else if sender.tag > 0 {
            applyZoom(CGFloat(sender.tag) / 100)
        }
    }

    // MARK: - Edit actions (responder chain)

    private func performEdit(_ actionName: String, _ transform: (RasterImage) -> RasterImage?) {
        guard let document = document else {
            NSSound.beep()
            return
        }
        document.applyEdit(actionName, transform)
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
        document.applyEdit("Crop") { image in
            image.cropped(
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

    @objc func applyGrayscale(_ sender: Any?) {
        performEdit("Grayscale") { $0.grayscaled() }
    }

    @objc func applyInvert(_ sender: Any?) {
        performEdit("Invert") { $0.inverted() }
    }

    @objc func applySepia(_ sender: Any?) {
        performEdit("Sepia") { $0.sepia() }
    }

    @objc func applySharpen(_ sender: Any?) {
        performEdit("Sharpen") { $0.sharpened(amount: 1.5) }
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
        guard let image = document?.image else {
            NSSound.beep()
            return
        }
        let source: RasterImage?
        if let selection = canvas.selectionRect {
            source = image.cropped(
                x: Int(selection.minX), y: Int(selection.minY),
                w: Int(selection.width), h: Int(selection.height))
        } else {
            source = image
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

// MARK: - Validation

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

extension EditorViewController: NSUserInterfaceValidations {
    private static let toolActions: [Selector: EditorTool] = [
        #selector(selectSelectTool(_:)): .select,
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
        guard document?.image != nil else { return false }
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
