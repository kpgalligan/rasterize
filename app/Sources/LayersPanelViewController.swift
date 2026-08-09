import AppKit

/// Rounded accent-tinted selection behind the active layer's row.
final class LayerRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let rect = bounds.insetBy(dx: 6, dy: 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        DS.selectionFill.setFill()
        path.fill()
    }
}

/// One row of the layers table: 22px visibility eye, 34px framed thumbnail,
/// then a two-line stack — editable name over a mono meta line reading
/// "Soft Light · 62%". Callbacks route edits back to the panel controller.
final class LayerCellView: NSView, NSTextFieldDelegate {
    private let eyeButton = NSButton(title: "", target: nil, action: nil)
    private let thumbView = NSImageView()
    private let thumbFrame = NSView()
    private let nameField = NSTextField(string: "")
    private let metaLabel = NSTextField(labelWithString: "")
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

        thumbFrame.translatesAutoresizingMaskIntoConstraints = false
        thumbFrame.wantsLayer = true
        thumbFrame.layer?.cornerRadius = 5
        thumbFrame.layer?.borderWidth = 1
        thumbFrame.layer?.masksToBounds = true

        thumbView.translatesAutoresizingMaskIntoConstraints = false
        thumbView.imageScaling = .scaleProportionallyDown
        thumbView.imageFrameStyle = .none
        thumbFrame.addSubview(thumbView)

        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.isBordered = false
        nameField.drawsBackground = false
        nameField.isEditable = true
        nameField.usesSingleLineMode = true
        nameField.lineBreakMode = .byTruncatingTail
        nameField.font = DS.sans(13)
        nameField.delegate = self

        metaLabel.translatesAutoresizingMaskIntoConstraints = false
        metaLabel.font = DS.mono(10)
        metaLabel.textColor = DS.textFaint
        metaLabel.lineBreakMode = .byTruncatingTail

        addSubview(eyeButton)
        addSubview(thumbFrame)
        addSubview(nameField)
        addSubview(metaLabel)
        NSLayoutConstraint.activate([
            eyeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            eyeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            eyeButton.widthAnchor.constraint(equalToConstant: 22),

            thumbFrame.leadingAnchor.constraint(equalTo: eyeButton.trailingAnchor, constant: 9),
            thumbFrame.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumbFrame.widthAnchor.constraint(equalToConstant: 34),
            thumbFrame.heightAnchor.constraint(equalToConstant: 34),

            thumbView.topAnchor.constraint(equalTo: thumbFrame.topAnchor),
            thumbView.bottomAnchor.constraint(equalTo: thumbFrame.bottomAnchor),
            thumbView.leadingAnchor.constraint(equalTo: thumbFrame.leadingAnchor),
            thumbView.trailingAnchor.constraint(equalTo: thumbFrame.trailingAnchor),

            nameField.leadingAnchor.constraint(equalTo: thumbFrame.trailingAnchor, constant: 9),
            nameField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            nameField.bottomAnchor.constraint(equalTo: centerYAnchor, constant: 1),

            metaLabel.leadingAnchor.constraint(equalTo: nameField.leadingAnchor),
            metaLabel.trailingAnchor.constraint(equalTo: nameField.trailingAnchor),
            metaLabel.topAnchor.constraint(equalTo: centerYAnchor, constant: 2),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("LayerCellView does not support NSCoder")
    }

    func configure(info: RasterDocument.LayerInfo, thumbnail: NSImage?, selected: Bool) {
        committedName = info.name
        nameField.stringValue = info.name
        nameField.font = DS.sans(13, weight: selected ? .semibold : .regular)
        if !info.visible {
            nameField.textColor = DS.textFaint
        } else {
            nameField.textColor = selected ? DS.accent : DS.textStrong
        }
        let percent = Int((Double(info.opacity) * 100).rounded())
        metaLabel.stringValue = "\(RzBlendMode.displayName(for: info.blendMode)) · \(percent)%"
        thumbFrame.layer?.borderColor = DS.border.cgColor
        thumbView.image = thumbnail
        thumbView.alphaValue = info.visible ? 1.0 : 0.35
        let symbol = info.visible ? "eye" : "eye.slash"
        let label = info.visible ? "Visible" : "Hidden"
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) {
            eyeButton.image = image.tinted(with: info.visible ? DS.textMuted : DS.textFaint)
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
    private let blendContainer = NSView()
    private let opacitySlider = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let opacityValueLabel = NSTextField(labelWithString: "100%")
    private let layerCountLabel = NSTextField(labelWithString: "")
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
        let root = NSView(frame: NSRect(x: 0, y: 0, width: DS.panelWidth, height: 400))
        root.wantsLayer = true

        // "Layers" pill tab — the active-tab treatment from the design's
        // tab row. (The Adjust and Ask tabs are dropped: Adjust's sheets
        // stay as sheets, and the agent does not exist yet.)
        let tab = StickerButton(title: "Layers", style: .secondary, target: nil, action: nil)
        tab.translatesAutoresizingMaskIntoConstraints = false
        tab.isEnabled = true

        blendContainer.translatesAutoresizingMaskIntoConstraints = false
        blendContainer.wantsLayer = true
        blendContainer.layer?.cornerRadius = 7
        blendContainer.layer?.borderWidth = 1.5

        blendPopup.translatesAutoresizingMaskIntoConstraints = false
        blendPopup.isBordered = false
        blendPopup.font = DS.sans(13)
        // Separators mean item position != mode index, so every item carries
        // its RzBlendMode raw value in `tag`; selection goes through tags,
        // never item positions.
        let blendMenu = NSMenu()
        for (groupIndex, group) in RzBlendMode.blendModeGroups.enumerated() {
            if groupIndex > 0 {
                blendMenu.addItem(NSMenuItem.separator())
            }
            for (mode, title) in group {
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.tag = Int(mode.rawValue)
                blendMenu.addItem(item)
            }
        }
        blendPopup.menu = blendMenu
        blendPopup.target = self
        blendPopup.action = #selector(blendChanged(_:))

        blendContainer.addSubview(blendPopup)

        let opacityTitle = NSTextField(labelWithString: "")
        opacityTitle.translatesAutoresizingMaskIntoConstraints = false
        opacityTitle.attributedStringValue = DS.microLabel("Opacity")

        opacitySlider.translatesAutoresizingMaskIntoConstraints = false
        opacitySlider.isContinuous = true
        opacitySlider.controlSize = .small
        opacitySlider.target = self
        opacitySlider.action = #selector(opacityChanged(_:))

        opacityValueLabel.translatesAutoresizingMaskIntoConstraints = false
        opacityValueLabel.font = DS.mono(11)
        opacityValueLabel.textColor = DS.textMuted
        opacityValueLabel.alignment = .right

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("layer"))
        column.width = DS.panelWidth - 20
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

        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.style = .plain

        tableScroll.translatesAutoresizingMaskIntoConstraints = false
        tableScroll.documentView = tableView
        tableScroll.hasVerticalScroller = true
        tableScroll.autohidesScrollers = true
        tableScroll.drawsBackground = false

        // Footer: four 30x26 ghost icon buttons, mono layer count right.
        // nil targets: actions resolve through the responder chain to the
        // EditorViewController, the same handlers the Layer menu items use.
        addButton = GhostButton(
            symbol: "plus", fallback: "+", caption: nil, tooltip: "New Layer",
            action: #selector(EditorViewController.newLayer(_:)))
        removeButton = GhostButton(
            symbol: "minus", fallback: "−", caption: nil, tooltip: "Delete Layer",
            action: #selector(EditorViewController.deleteLayer(_:)))
        duplicateButton = GhostButton(
            symbol: "plus.square.on.square", fallback: "⧉", caption: nil,
            tooltip: "Duplicate Layer",
            action: #selector(EditorViewController.duplicateLayer(_:)))
        mergeButton = GhostButton(
            symbol: "arrow.triangle.merge", fallback: "⤵", caption: nil,
            tooltip: "Merge Down",
            action: #selector(EditorViewController.mergeDown(_:)))

        layerCountLabel.translatesAutoresizingMaskIntoConstraints = false
        layerCountLabel.font = DS.mono(10)
        layerCountLabel.textColor = DS.textFaint
        layerCountLabel.alignment = .right

        let footerSeparator = NSView()
        footerSeparator.translatesAutoresizingMaskIntoConstraints = false
        footerSeparator.wantsLayer = true

        let footerSpacer = NSView()
        let footer = NSStackView(views: [
            addButton, removeButton, duplicateButton, mergeButton,
            footerSpacer, layerCountLabel,
        ])
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.orientation = .horizontal
        footer.spacing = 2
        footer.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 12)

        root.addSubview(tab)
        root.addSubview(blendContainer)
        root.addSubview(opacityTitle)
        root.addSubview(opacitySlider)
        root.addSubview(opacityValueLabel)
        root.addSubview(tableScroll)
        root.addSubview(footerSeparator)
        root.addSubview(footer)

        NSLayoutConstraint.activate([
            tab.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            tab.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),

            blendContainer.topAnchor.constraint(equalTo: tab.bottomAnchor, constant: 12),
            blendContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            blendContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            blendContainer.heightAnchor.constraint(equalToConstant: 30),

            blendPopup.leadingAnchor.constraint(equalTo: blendContainer.leadingAnchor, constant: 8),
            blendPopup.trailingAnchor.constraint(
                equalTo: blendContainer.trailingAnchor, constant: -6),
            blendPopup.centerYAnchor.constraint(equalTo: blendContainer.centerYAnchor),

            opacityTitle.centerYAnchor.constraint(equalTo: opacitySlider.centerYAnchor),
            opacityTitle.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),

            opacitySlider.topAnchor.constraint(equalTo: blendContainer.bottomAnchor, constant: 10),
            opacitySlider.leadingAnchor.constraint(
                equalTo: opacityTitle.trailingAnchor, constant: 8),
            opacitySlider.trailingAnchor.constraint(
                equalTo: opacityValueLabel.leadingAnchor, constant: -6),

            opacityValueLabel.centerYAnchor.constraint(equalTo: opacitySlider.centerYAnchor),
            opacityValueLabel.trailingAnchor.constraint(
                equalTo: root.trailingAnchor, constant: -12),
            opacityValueLabel.widthAnchor.constraint(equalToConstant: 40),

            tableScroll.topAnchor.constraint(equalTo: opacitySlider.bottomAnchor, constant: 10),
            tableScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tableScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            footerSeparator.topAnchor.constraint(equalTo: tableScroll.bottomAnchor),
            footerSeparator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footerSeparator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footerSeparator.heightAnchor.constraint(equalToConstant: 1),

            footer.topAnchor.constraint(equalTo: footerSeparator.bottomAnchor),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 30),
        ])

        view = root
        applyPanelAppearance(separator: footerSeparator)
    }

    /// Colors that need explicit refresh on appearance changes (layer-backed
    /// borders resolve cgColor once).
    private func applyPanelAppearance(separator: NSView) {
        view.layer?.backgroundColor = DS.chromeBackground.cgColor
        blendContainer.layer?.borderColor = DS.borderStrong.cgColor
        blendContainer.layer?.backgroundColor = DS.chromeBackground.cgColor
        separator.layer?.backgroundColor = DS.border.cgColor
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
        blendPopup.selectItem(withTag: Int(info.blendMode.rawValue))
        // While the user is scrubbing, the slider and label already show the
        // in-flight value (opacityChanged set them); don't write the value
        // back into the slider mid-track.
        if !opacityDragActive {
            opacitySlider.doubleValue = info.opacity
            opacityValueLabel.stringValue = "\(Int((info.opacity * 100).rounded()))%"
        }
    }

    private func updateLayerCount() {
        let count = document?.doc?.layerCount ?? 0
        layerCountLabel.stringValue = count == 1 ? "1 layer" : "\(count) layers"
    }

    private func updateButtonStates() {
        updateLayerCount()
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
        guard let tag = blendPopup.selectedItem?.tag, tag >= 0 else { return }
        let mode = RzBlendMode(rawValue: UInt32(tag))
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
        if let thumb = doc.layerThumbnail(idx, maxSide: 34), let cgImage = thumb.makeCGImage() {
            thumbnail = NSImage(
                cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }
        cell.configure(
            info: info, thumbnail: thumbnail, selected: idx == document.activeLayerIndex)
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

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        LayerRowView(frame: .zero)
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
