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
    /// Optional second level: a double-click (the layer's re-edit affordance
    /// — the name field keeps click-to-rename, so re-edit lives on the
    /// thumbnail). Unset, a double-click's second press falls through to
    /// onClick like any other.
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
    /// Double-clicking the layer's own thumbnail (the badged one, not the
    /// mask's) reopens whatever the layer was made from — a text layer's
    /// on-canvas editor, an adjustment layer's options dialog. Unset on a
    /// plain raster layer, which has no source to reopen.
    var onEditSource: (() -> Void)?

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
        // exclusive — one meta slot, one type). Either kind's double-click
        // reopens its source; a plain raster layer has none.
        thumbView.badge = isText ? "T" : (isAdjustment ? "◐" : nil)
        thumbFrame.onDoubleClick =
            (isText || isAdjustment) ? { [weak self] in self?.onEditSource?() } : nil
        if isText {
            thumbFrame.toolTip =
                "Text layer — double-click to edit the text (painting rasterizes it)"
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

    /// Puts the keyboard in the name field with the whole name selected —
    /// what the row menu's Rename does. It is the same edit a click on the
    /// name starts, so it commits through controlTextDidEndEditing like any
    /// other rename.
    func beginRename() {
        guard window?.makeFirstResponder(nameField) == true else { return }
        nameField.currentEditor()?.selectAll(nil)
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
