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

/// A framed thumbnail well. It handles its own clicks (choosing the paint
/// target) and deliberately swallows them, so clicking a thumbnail never
/// starts the table's row drag; the handler selects the layer itself.
final class ThumbnailWellView: NSView {
    var onClick: (() -> Void)?
    /// Optional second level: a double-click (an adjustment layer's re-edit
    /// affordance — the name field keeps click-to-rename, so re-edit lives
    /// on the thumbnail). Unset, a double-click's second press falls through
    /// to onClick like any other.
    var onDoubleClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, let onDoubleClick = onDoubleClick {
            onDoubleClick()
            return
        }
        guard let onClick = onClick else {
            super.mouseDown(with: event)
            return
        }
        onClick()
    }
}

/// Draws a thumbnail aspect-fit (never upscaled) inside a well, plus — for a
/// DISABLED layer mask — a diagonal slash across it, and — for a layer that
/// carries a description — a corner badge naming its kind ("T" for text,
/// "◐" for an adjustment layer; a layer is one OR the other, never both).
final class ThumbnailImageView: NSView {
    var image: NSImage? {
        didSet { needsDisplay = true }
    }

    /// Struck through: the mask is retained but ignored while compositing.
    var slashed = false {
        didSet { needsDisplay = true }
    }

    /// One or two characters in a corner chip; nil for a plain raster layer.
    var badge: String? {
        didSet {
            if badge != oldValue { needsDisplay = true }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if let image = image, image.size.width > 0, image.size.height > 0 {
            let scale = min(
                bounds.width / image.size.width, bounds.height / image.size.height, 1)
            let size = NSSize(
                width: image.size.width * scale, height: image.size.height * scale)
            image.draw(
                in: NSRect(
                    x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                    width: size.width, height: size.height))
        }
        if slashed {
            let slash = NSBezierPath()
            slash.move(to: NSPoint(x: bounds.minX + 4, y: bounds.minY + 4))
            slash.line(to: NSPoint(x: bounds.maxX - 4, y: bounds.maxY - 4))
            // Halo underneath so the slash reads over any coverage.
            slash.lineWidth = 3
            DS.chromeBackground.setStroke()
            slash.stroke()
            slash.lineWidth = 1.5
            DS.textStrong.setStroke()
            slash.stroke()
        }
        drawBadge()
    }

    /// The badge chip, bottom-right: a filled, bordered plate — the slash's
    /// halo idea as a solid — so the letter reads over any thumbnail.
    private func drawBadge() {
        guard let badge = badge, !badge.isEmpty else { return }
        let label = NSAttributedString(
            string: badge,
            attributes: [.font: DS.sans(10, weight: .semibold), .foregroundColor: DS.textStrong])
        let labelSize = label.size()
        let chip = NSRect(
            x: bounds.maxX - max(labelSize.width + 7, 14) - 2,
            y: bounds.minY + 2,
            width: max(labelSize.width + 7, 14),
            height: 14)
        let plate = NSBezierPath(roundedRect: chip, xRadius: 4, yRadius: 4)
        DS.chromeBackground.withAlphaComponent(0.94).setFill()
        plate.fill()
        plate.lineWidth = 1
        DS.border.setStroke()
        plate.stroke()
        label.draw(
            at: NSPoint(
                x: chip.midX - labelSize.width / 2, y: chip.midY - labelSize.height / 2))
    }
}

/// One row of the layers table: 22px visibility eye, framed thumbnail (plus
/// a second one for the layer's mask), then a two-line stack — editable name
/// over a mono meta line reading "Soft Light · 62%". A CLIPPED layer indents
/// its thumbnail block behind a "↳" arrow — it rides on the layer below. The
/// active layer rings whichever thumbnail brush/eraser currently edit.
/// Callbacks route edits back to the panel controller.
final class LayerCellView: NSView, NSTextFieldDelegate {
    /// Thumbnail well side: 34 on its own, smaller once a mask thumbnail
    /// sits beside it — the row height never grows.
    static let thumbSide: CGFloat = 34
    static let pairedThumbSide: CGFloat = 28
    private static let thumbGap: CGFloat = 5
    /// Extra leading on a clipped row's thumbnail block; the "↳" arrow sits
    /// in the gap this opens up.
    private static let clipIndent: CGFloat = 16

    private let eyeButton = NSButton(title: "", target: nil, action: nil)
    private let clipLabel = NSTextField(labelWithString: "↳")
    private let thumbView = ThumbnailImageView()
    private let thumbFrame = ThumbnailWellView()
    private let maskView = ThumbnailImageView()
    private let maskFrame = ThumbnailWellView()
    private let nameField = NSTextField(string: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private var committedName = ""
    private var hasMask = false

    private var thumbLeading: NSLayoutConstraint!
    private var thumbWidth: NSLayoutConstraint!
    private var thumbHeight: NSLayoutConstraint!
    private var maskWidth: NSLayoutConstraint!
    private var maskHeight: NSLayoutConstraint!
    private var maskLeading: NSLayoutConstraint!

    var onToggleVisible: (() -> Void)?
    var onRename: ((String) -> Void)?
    /// Clicking either thumbnail selects this layer and points brush/eraser
    /// at the clicked target.
    var onSelectTarget: ((PaintTarget) -> Void)?
    /// Double-clicking an ADJUSTMENT layer's thumbnail (the ◐-badged one,
    /// not the mask's) reopens its options dialog; unset for other layers.
    var onAdjustmentEdit: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        eyeButton.translatesAutoresizingMaskIntoConstraints = false
        eyeButton.isBordered = false
        eyeButton.setButtonType(.momentaryChange)
        eyeButton.target = self
        eyeButton.action = #selector(eyeClicked(_:))

        // The clip arrow: a plain label, so clicks fall through to the row
        // (selection and drag-reorder keep working over it).
        clipLabel.translatesAutoresizingMaskIntoConstraints = false
        clipLabel.font = DS.sans(12, weight: .semibold)
        clipLabel.textColor = DS.textMuted
        clipLabel.toolTip = "Clipped to the layer below"
        clipLabel.isHidden = true

        for well in [thumbFrame, maskFrame] {
            well.translatesAutoresizingMaskIntoConstraints = false
            well.wantsLayer = true
            well.layer?.cornerRadius = 5
            well.layer?.borderWidth = 1
            well.layer?.masksToBounds = true
        }
        thumbFrame.onClick = { [weak self] in self?.onSelectTarget?(.layer) }
        maskFrame.onClick = { [weak self] in self?.onSelectTarget?(.mask) }
        thumbFrame.toolTip = "Paint on the layer"

        for view in [thumbView, maskView] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        thumbFrame.addSubview(thumbView)
        maskFrame.addSubview(maskView)

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
        addSubview(clipLabel)
        addSubview(thumbFrame)
        addSubview(maskFrame)
        addSubview(nameField)
        addSubview(metaLabel)

        // The mask well collapses to zero (and hides) on a layer without a
        // mask, so the name field's leading edge follows either way. The
        // whole thumbnail block indents on a clipped layer (thumbLeading
        // grows by clipIndent) and the "↳" arrow fills the opened gap.
        thumbLeading = thumbFrame.leadingAnchor.constraint(
            equalTo: eyeButton.trailingAnchor, constant: 9)
        thumbWidth = thumbFrame.widthAnchor.constraint(equalToConstant: Self.thumbSide)
        thumbHeight = thumbFrame.heightAnchor.constraint(equalToConstant: Self.thumbSide)
        maskWidth = maskFrame.widthAnchor.constraint(equalToConstant: 0)
        maskHeight = maskFrame.heightAnchor.constraint(equalToConstant: 0)
        maskLeading = maskFrame.leadingAnchor.constraint(
            equalTo: thumbFrame.trailingAnchor, constant: 0)

        NSLayoutConstraint.activate([
            eyeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            eyeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            eyeButton.widthAnchor.constraint(equalToConstant: 22),

            clipLabel.trailingAnchor.constraint(equalTo: thumbFrame.leadingAnchor, constant: -3),
            clipLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            thumbLeading,
            thumbFrame.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumbWidth,
            thumbHeight,

            thumbView.topAnchor.constraint(equalTo: thumbFrame.topAnchor),
            thumbView.bottomAnchor.constraint(equalTo: thumbFrame.bottomAnchor),
            thumbView.leadingAnchor.constraint(equalTo: thumbFrame.leadingAnchor),
            thumbView.trailingAnchor.constraint(equalTo: thumbFrame.trailingAnchor),

            maskLeading,
            maskFrame.centerYAnchor.constraint(equalTo: centerYAnchor),
            maskWidth,
            maskHeight,

            maskView.topAnchor.constraint(equalTo: maskFrame.topAnchor),
            maskView.bottomAnchor.constraint(equalTo: maskFrame.bottomAnchor),
            maskView.leadingAnchor.constraint(equalTo: maskFrame.leadingAnchor),
            maskView.trailingAnchor.constraint(equalTo: maskFrame.trailingAnchor),

            nameField.leadingAnchor.constraint(equalTo: maskFrame.trailingAnchor, constant: 9),
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

    func configure(
        info: RasterDocument.LayerInfo, thumbnail: NSImage?, hasMask: Bool,
        maskThumbnail: NSImage?, maskEnabled: Bool, isText: Bool, isAdjustment: Bool,
        clipped: Bool, selected: Bool, paintTarget: PaintTarget
    ) {
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

        self.hasMask = hasMask
        // The clip indent shifts the whole thumbnail block (name and meta
        // follow their leading anchors); the arrow shows in the gap.
        clipLabel.isHidden = !clipped
        thumbLeading.constant = clipped ? 9 + Self.clipIndent : 9
        let side = hasMask ? Self.pairedThumbSide : Self.thumbSide
        thumbWidth.constant = side
        thumbHeight.constant = side
        maskWidth.constant = hasMask ? side : 0
        maskHeight.constant = hasMask ? side : 0
        maskLeading.constant = hasMask ? Self.thumbGap : 0
        maskFrame.isHidden = !hasMask
        maskView.image = maskThumbnail
        maskView.slashed = hasMask && !maskEnabled
        maskView.alphaValue = maskEnabled ? 1.0 : 0.4
        maskFrame.toolTip =
            maskEnabled ? "Paint on the layer mask" : "Paint on the layer mask (disabled)"
        setTargetHighlight(layerActive: selected, target: paintTarget)

        thumbView.image = thumbnail
        thumbView.alphaValue = info.visible ? 1.0 : 0.35
        // A text layer is still editable as text: say so on the thumbnail,
        // and the badge goes away the moment the description is dropped. An
        // adjustment layer badges ◐ the same way (the two are mutually
        // exclusive — one meta slot, one type), and its double-click reopens
        // the options dialog.
        thumbView.badge = isText ? "T" : (isAdjustment ? "◐" : nil)
        thumbFrame.onDoubleClick =
            isAdjustment ? { [weak self] in self?.onAdjustmentEdit?() } : nil
        if isText {
            thumbFrame.toolTip = "Paint on the layer (text layer — painting rasterizes it)"
        } else if isAdjustment {
            thumbFrame.toolTip = "Adjustment layer — double-click for options"
        } else {
            thumbFrame.toolTip = "Paint on the layer"
        }
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

    /// Rings the thumbnail brush/eraser would hit — but only on the active
    /// layer, where the paint target means anything.
    func setTargetHighlight(layerActive: Bool, target: PaintTarget) {
        let maskRinged = layerActive && hasMask && target == .mask
        let layerRinged = layerActive && !maskRinged
        thumbFrame.layer?.borderWidth = layerRinged ? 2 : 1
        thumbFrame.layer?.borderColor = (layerRinged ? DS.accent : DS.border).cgColor
        maskFrame.layer?.borderWidth = maskRinged ? 2 : 1
        maskFrame.layer?.borderColor = (maskRinged ? DS.accent : DS.border).cgColor
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

    /// Called when the user clicks the Assistant tab.
    var onShowAssistant: (() -> Void)?

    /// Called when the user clicks a layer's own thumbnail or its mask
    /// thumbnail: the editor points brush/eraser at that target.
    var onPaintTargetChange: ((PaintTarget) -> Void)?

    /// Called when the user double-clicks an adjustment layer's thumbnail
    /// (layer index attached): the editor reopens its options dialog.
    var onAdjustmentEdit: ((Int) -> Void)?

    /// What brush/eraser currently edit on the active layer, pushed in by the
    /// editor and drawn as a focus ring around the matching thumbnail.
    private(set) var paintTarget: PaintTarget = .layer

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

        // Panel tab row: Layers active here, Assistant switches over.
        let tab = PanelTabsView(titles: ["Layers", "Assistant"], activeIndex: 0) {
            [weak self] index in
            if index == 1 { self?.onShowAssistant?() }
        }
        tab.translatesAutoresizingMaskIntoConstraints = false

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

    // MARK: - Paint target

    /// Mirrors the editor's paint target into the rows' focus rings.
    func setPaintTarget(_ target: PaintTarget) {
        paintTarget = target
        refreshTargetRings()
    }

    /// Re-rings the visible rows in place — cheaper than a reload, which
    /// would re-resample every thumbnail.
    private func refreshTargetRings() {
        guard isViewLoaded, let document = document else { return }
        let active = document.activeLayerIndex
        for row in 0..<tableView.numberOfRows {
            guard
                let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
                    as? LayerCellView
            else { continue }
            cell.setTargetHighlight(
                layerActive: layerIndex(forRow: row) == active, target: paintTarget)
        }
    }

    /// A click on one of a row's thumbnails: make that layer active, then
    /// point brush/eraser at the clicked target.
    private func selectPaintTarget(_ target: PaintTarget, layer idx: Int) {
        guard let document = document, document.doc != nil else { return }
        if document.activeLayerIndex != idx {
            // Panel selection only retargets future edits: no undo, no dirty.
            document.activeLayerIndex = idx
            let row = row(forLayerIndex: idx)
            if row >= 0, row < tableView.numberOfRows {
                isReloading = true
                tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                isReloading = false
            }
            updateHeaderControls()
            updateButtonStates()
            // Resets the editor's paint target for the new layer; the
            // requested target lands right after.
            onActiveLayerChange?()
        }
        onPaintTargetChange?(target)
        refreshTargetRings()
    }

    /// The mask's grayscale image scaled down for its thumbnail well. Masks
    /// come back at the LAYER's full size, so the scaling happens in the core
    /// rather than at draw time.
    private func maskThumbnail(_ doc: RasterDocument, _ idx: Int, maxSide: Int) -> NSImage? {
        guard let mask = doc.layerMaskImage(idx), mask.width > 0, mask.height > 0 else {
            return nil
        }
        let longest = max(mask.width, mask.height)
        let scale = min(CGFloat(maxSide) / CGFloat(longest), 1)
        let w = max(Int((CGFloat(mask.width) * scale).rounded()), 1)
        let h = max(Int((CGFloat(mask.height) * scale).rounded()), 1)
        let scaled =
            (w == mask.width && h == mask.height)
            ? mask : (mask.resized(w: w, h: h, filter: RZ_FILTER_BILINEAR) ?? mask)
        guard let cgImage = scaled.makeCGImage() else { return nil }
        return NSImage(
            cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
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
        let hasMask = doc.layerHasMask(idx)
        let side = Int(hasMask ? LayerCellView.pairedThumbSide : LayerCellView.thumbSide)
        var thumbnail: NSImage? = nil
        if let thumb = doc.layerThumbnail(idx, maxSide: side), let cgImage = thumb.makeCGImage() {
            thumbnail = NSImage(
                cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }
        cell.configure(
            info: info, thumbnail: thumbnail, hasMask: hasMask,
            maskThumbnail: hasMask ? maskThumbnail(doc, idx, maxSide: side) : nil,
            maskEnabled: doc.layerMaskEnabled(idx),
            isText: doc.textPayload(idx) != nil,
            isAdjustment: doc.layerIsAdjustment(idx),
            clipped: doc.layerClipped(idx),
            selected: idx == document.activeLayerIndex, paintTarget: paintTarget)
        cell.onSelectTarget = { [weak self] target in
            self?.selectPaintTarget(target, layer: idx)
        }
        cell.onAdjustmentEdit = { [weak self] in
            self?.onAdjustmentEdit?(idx)
        }
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
        // The paint-target ring follows the active layer (and the editor has
        // just dropped any mask target the old layer had).
        refreshTargetRings()
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
