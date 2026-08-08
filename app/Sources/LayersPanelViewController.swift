import AppKit

/// One row of the layers table: visibility eye, 40px thumbnail, editable
/// name. Callbacks route the edits back to the panel controller.
final class LayerCellView: NSView, NSTextFieldDelegate {
    private let eyeButton = NSButton(title: "", target: nil, action: nil)
    private let thumbView = NSImageView()
    private let nameField = NSTextField(string: "")
    private var committedName = ""

    var onToggleVisible: (() -> Void)?
    var onRename: ((String) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        eyeButton.translatesAutoresizingMaskIntoConstraints = false
        eyeButton.isBordered = false
        eyeButton.setButtonType(.momentaryChange)
        eyeButton.target = self
        eyeButton.action = #selector(eyeClicked(_:))

        thumbView.translatesAutoresizingMaskIntoConstraints = false
        thumbView.imageScaling = .scaleProportionallyDown
        thumbView.imageFrameStyle = .none

        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.isBordered = false
        nameField.drawsBackground = false
        nameField.isEditable = true
        nameField.usesSingleLineMode = true
        nameField.lineBreakMode = .byTruncatingTail
        nameField.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        nameField.delegate = self

        addSubview(eyeButton)
        addSubview(thumbView)
        addSubview(nameField)
        NSLayoutConstraint.activate([
            eyeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            eyeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            eyeButton.widthAnchor.constraint(equalToConstant: 24),

            thumbView.leadingAnchor.constraint(equalTo: eyeButton.trailingAnchor, constant: 4),
            thumbView.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumbView.widthAnchor.constraint(equalToConstant: 40),
            thumbView.heightAnchor.constraint(equalToConstant: 40),

            nameField.leadingAnchor.constraint(equalTo: thumbView.trailingAnchor, constant: 6),
            nameField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            nameField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("LayerCellView does not support NSCoder")
    }

    func configure(info: RasterDocument.LayerInfo, thumbnail: NSImage?) {
        committedName = info.name
        nameField.stringValue = info.name
        nameField.textColor = info.visible ? .labelColor : .secondaryLabelColor
        thumbView.image = thumbnail
        let symbol = info.visible ? "eye" : "eye.slash"
        let label = info.visible ? "Visible" : "Hidden"
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) {
            eyeButton.image = image
            eyeButton.title = ""
        } else {
            eyeButton.image = nil
            eyeButton.title = info.visible ? "●" : "○"
        }
        eyeButton.toolTip = info.visible ? "Hide Layer" : "Show Layer"
    }

    @objc private func eyeClicked(_ sender: Any?) {
        onToggleVisible?()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        let name = nameField.stringValue
        if name.isEmpty {
            nameField.stringValue = committedName
        } else if name != committedName {
            onRename?(name)
        }
    }
}

/// Right-hand layers panel: blend mode + opacity for the active layer on
/// top, the layer stack (row 0 = TOPMOST layer) in the middle, and the
/// add/delete/duplicate/merge buttons below. All edits route through
/// ImageDocument.applyEdit (or the live-edit API for opacity scrubs); the
/// footer buttons send the same nil-target actions the Layer menu uses, so
/// EditorViewController handles both.
final class LayersPanelViewController: NSViewController {
    weak var document: ImageDocument?

    /// Called when the user changes the active layer via the table selection
    /// (the editor updates its status bar).
    var onActiveLayerChange: (() -> Void)?

    private let blendPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let opacitySlider = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let opacityValueLabel = NSTextField(labelWithString: "100%")
    private let tableView = NSTableView()
    private let tableScroll = NSScrollView()
    private var addButton: NSButton!
    private var removeButton: NSButton!
    private var duplicateButton: NSButton!
    private var mergeButton: NSButton!

    private var isReloading = false
    private var opacityDragActive = false

    private static let layerRowType = NSPasteboard.PasteboardType("com.kgalligan.rasterize.layerrow")

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("LayersPanelViewController does not support NSCoder")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - View construction

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 236, height: 400))

        blendPopup.translatesAutoresizingMaskIntoConstraints = false
        blendPopup.controlSize = .small
        blendPopup.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        blendPopup.addItems(withTitles: RzBlendMode.allBlendModes.map { $0.1 })
        blendPopup.target = self
        blendPopup.action = #selector(blendChanged(_:))

        opacitySlider.translatesAutoresizingMaskIntoConstraints = false
        opacitySlider.isContinuous = true
        opacitySlider.controlSize = .small
        opacitySlider.target = self
        opacitySlider.action = #selector(opacityChanged(_:))

        opacityValueLabel.translatesAutoresizingMaskIntoConstraints = false
        opacityValueLabel.font = NSFont.monospacedDigitSystemFont(
            ofSize: NSFont.smallSystemFontSize, weight: .regular)
        opacityValueLabel.alignment = .right

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("layer"))
        column.width = 216
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        // Keep keyboard focus on the canvas: clicks still select rows, and
        // inline rename focuses its own field editor, but arrow keys must
        // keep nudging/tool keys working instead of walking the layer list.
        tableView.refusesFirstResponder = true
        tableView.rowHeight = 48
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.registerForDraggedTypes([Self.layerRowType])
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)

        tableScroll.translatesAutoresizingMaskIntoConstraints = false
        tableScroll.documentView = tableView
        tableScroll.hasVerticalScroller = true
        tableScroll.autohidesScrollers = true
        tableScroll.drawsBackground = true

        addButton = makeFooterButton(
            symbol: "plus", fallback: "+", tooltip: "New Layer",
            action: #selector(EditorViewController.newLayer(_:)))
        removeButton = makeFooterButton(
            symbol: "minus", fallback: "−", tooltip: "Delete Layer",
            action: #selector(EditorViewController.deleteLayer(_:)))
        duplicateButton = makeFooterButton(
            symbol: "plus.square.on.square", fallback: "⧉", tooltip: "Duplicate Layer",
            action: #selector(EditorViewController.duplicateLayer(_:)))
        mergeButton = makeFooterButton(
            symbol: "arrow.triangle.merge", fallback: "⤵", tooltip: "Merge Down",
            action: #selector(EditorViewController.mergeDown(_:)))

        let footerSeparator = NSBox()
        footerSeparator.boxType = .separator
        footerSeparator.translatesAutoresizingMaskIntoConstraints = false

        let footer = NSStackView(views: [addButton, removeButton, duplicateButton, mergeButton])
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.orientation = .horizontal
        footer.spacing = 2
        footer.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)

        root.addSubview(blendPopup)
        root.addSubview(opacitySlider)
        root.addSubview(opacityValueLabel)
        root.addSubview(tableScroll)
        root.addSubview(footerSeparator)
        root.addSubview(footer)

        NSLayoutConstraint.activate([
            blendPopup.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            blendPopup.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            blendPopup.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),

            opacitySlider.topAnchor.constraint(equalTo: blendPopup.bottomAnchor, constant: 8),
            opacitySlider.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            opacitySlider.trailingAnchor.constraint(
                equalTo: opacityValueLabel.leadingAnchor, constant: -6),

            opacityValueLabel.centerYAnchor.constraint(equalTo: opacitySlider.centerYAnchor),
            opacityValueLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            opacityValueLabel.widthAnchor.constraint(equalToConstant: 38),

            tableScroll.topAnchor.constraint(equalTo: opacitySlider.bottomAnchor, constant: 8),
            tableScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tableScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            footerSeparator.topAnchor.constraint(equalTo: tableScroll.bottomAnchor),
            footerSeparator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footerSeparator.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            footer.topAnchor.constraint(equalTo: footerSeparator.bottomAnchor),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footer.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 26),
        ])

        view = root
    }

    private func makeFooterButton(
        symbol: String, fallback: String, tooltip: String, action: Selector
    ) -> NSButton {
        // nil target: the action resolves through the responder chain to the
        // EditorViewController, the same handler the Layer menu items use.
        let button = NSButton(title: "", target: nil, action: action)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.setButtonType(.momentaryChange)
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip) {
            button.image = image
        } else {
            button.title = fallback
        }
        button.toolTip = tooltip
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return button
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(
            self, selector: #selector(documentDidChange(_:)),
            name: .imageDocumentImageDidChange, object: document)
        reload()
    }

    @objc private func documentDidChange(_ note: Notification) {
        // Live-edit ticks (Move drags, opacity scrubs) arrive per mouse
        // event; nothing structural changes mid-gesture, so rebuilding the
        // table (and re-resampling every layer's thumbnail) each tick only
        // burns CPU. Refresh the cheap header controls and wait for the
        // gesture's final non-live post to do the one full reload. If the
        // userInfo key is absent (older sender), fall back to the document's
        // flag and, failing that, our own scrub state.
        let isLive = (note.userInfo?["isLive"] as? Bool)
            ?? document?.isLiveEditing
            ?? false
        if isLive || opacityDragActive {
            updateHeaderControls()
            return
        }
        reload()
    }

    // MARK: - Row/layer mapping (row 0 = TOPMOST layer)

    private func layerIndex(forRow row: Int) -> Int {
        (document?.doc?.layerCount ?? 0) - 1 - row
    }

    private func row(forLayerIndex idx: Int) -> Int {
        (document?.doc?.layerCount ?? 0) - 1 - idx
    }

    // MARK: - Reload

    /// Rebuilds the table (regenerating the cheap 40px thumbnails), restores
    /// the selection from activeLayerIndex, and refreshes header + buttons.
    func reload() {
        guard isViewLoaded else { return }
        isReloading = true
        tableView.reloadData()
        if let document = document, let doc = document.doc {
            let row = doc.layerCount - 1 - document.activeLayerIndex
            if row >= 0, row < doc.layerCount {
                tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        }
        isReloading = false
        updateHeaderControls()
        updateButtonStates()
    }

    private func updateHeaderControls() {
        guard let document = document, let doc = document.doc,
              let info = doc.layerInfo(document.activeLayerIndex)
        else {
            blendPopup.isEnabled = false
            opacitySlider.isEnabled = false
            opacityValueLabel.stringValue = "—"
            return
        }
        blendPopup.isEnabled = true
        opacitySlider.isEnabled = true
        if let index = RzBlendMode.allBlendModes.firstIndex(where: {
            $0.0.rawValue == info.blendMode.rawValue
        }) {
            blendPopup.selectItem(at: index)
        }
        // While the user is scrubbing, the slider and label already show the
        // in-flight value (opacityChanged set them); don't write the value
        // back into the slider mid-track.
        if !opacityDragActive {
            opacitySlider.doubleValue = info.opacity
            opacityValueLabel.stringValue = "\(Int((info.opacity * 100).rounded()))%"
        }
    }

    private func updateButtonStates() {
        let doc = document?.doc
        let count = doc?.layerCount ?? 0
        let active = document?.activeLayerIndex ?? 0
        let hasDoc = count > 0
        addButton.isEnabled = hasDoc
        duplicateButton.isEnabled = hasDoc
        removeButton.isEnabled = count > 1
        // Merge Down needs a VISIBLE layer below the active one; the core
        // refuses to merge into a hidden layer.
        mergeButton.isEnabled = hasDoc && active >= 1
            && (doc?.layerInfo(active - 1)?.visible ?? false)
    }

    // MARK: - Header actions

    @objc private func blendChanged(_ sender: Any?) {
        guard let document = document else { return }
        let idx = document.activeLayerIndex
        let selected = blendPopup.indexOfSelectedItem
        guard selected >= 0, selected < RzBlendMode.allBlendModes.count else { return }
        let mode = RzBlendMode.allBlendModes[selected].0
        document.applyEdit("Layer Blend Mode") { $0.withLayerBlendMode(idx, mode) }
    }

    @objc private func opacityChanged(_ sender: Any?) {
        guard let document = document, document.doc != nil else { return }
        let idx = document.activeLayerIndex
        let value = opacitySlider.doubleValue
        opacityValueLabel.stringValue = "\(Int((value * 100).rounded()))%"
        // Continuous slider ticks swap the doc live (no undo); the tick
        // delivered with the mouse-up event commits the whole scrub as ONE
        // undo step. Non-drag changes (keyboard) commit immediately.
        let eventType = NSApp.currentEvent?.type
        let stillDragging = eventType == .leftMouseDragged || eventType == .leftMouseDown
        // A no-move click reproduces the slider's assigned value exactly;
        // don't register a phantom undo step for it.
        if !opacityDragActive, !stillDragging,
           let current = document.doc.layerInfo(idx)?.opacity,
           Double(current) == value {
            return
        }
        if !opacityDragActive {
            document.beginLiveEdit()
            opacityDragActive = true
        }
        if let updated = document.doc.withLayerOpacity(idx, value) {
            document.updateLiveEdit(updated)
        }
        if !stillDragging {
            opacityDragActive = false
            document.endLiveEdit("Layer Opacity")
        }
    }
}

// MARK: - Table data source / delegate

extension LayersPanelViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        document?.doc?.layerCount ?? 0
    }

    func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        guard let document = document, let doc = document.doc else { return nil }
        let idx = layerIndex(forRow: row)
        guard let info = doc.layerInfo(idx) else { return nil }

        let cell = LayerCellView(frame: .zero)
        var thumbnail: NSImage? = nil
        if let thumb = doc.layerThumbnail(idx, maxSide: 40), let cgImage = thumb.makeCGImage() {
            thumbnail = NSImage(
                cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }
        cell.configure(info: info, thumbnail: thumbnail)
        cell.onToggleVisible = { [weak self] in
            guard let document = self?.document else { return }
            document.applyEdit(info.visible ? "Hide Layer" : "Show Layer") {
                $0.withLayerVisible(idx, !info.visible)
            }
        }
        cell.onRename = { [weak self] newName in
            guard let document = self?.document else { return }
            document.applyEdit("Rename Layer") { $0.withLayerName(idx, newName) }
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isReloading, let document = document, document.doc != nil else { return }
        let row = tableView.selectedRow
        guard row >= 0 else { return }
        let idx = layerIndex(forRow: row)
        guard idx != document.activeLayerIndex else { return }
        // Panel selection only retargets future edits: no undo, no dirty.
        document.activeLayerIndex = idx
        updateHeaderControls()
        updateButtonStates()
        onActiveLayerChange?()
    }

    // MARK: - Drag reorder

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.layerRowType)
        return item
    }

    func tableView(
        _ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard info.draggingPasteboard.availableType(from: [Self.layerRowType]) != nil else {
            return []
        }
        if dropOperation == .on {
            tableView.setDropRow(row, dropOperation: .above)
        }
        return .move
    }

    func tableView(
        _ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard let document = document, let doc = document.doc,
              let rowString = info.draggingPasteboard.string(forType: Self.layerRowType),
              let sourceRow = Int(rowString)
        else { return false }
        let count = doc.layerCount
        guard sourceRow >= 0, sourceRow < count else { return false }
        // `row` is the insertion point in the current (top-first) table
        // order; remove the dragged row first to get its final table row.
        var targetRow = row
        if targetRow > sourceRow { targetRow -= 1 }
        guard targetRow != sourceRow, targetRow >= 0, targetRow < count else { return false }
        let from = count - 1 - sourceRow
        let to = count - 1 - targetRow
        let before = document.doc
        document.applyEdit("Reorder Layer") { $0.movingLayer(from: from, to: to) }
        guard document.doc !== before else { return false }
        // Keep the moved layer selected.
        document.activeLayerIndex = to
        reload()
        onActiveLayerChange?()
        return true
    }
}
