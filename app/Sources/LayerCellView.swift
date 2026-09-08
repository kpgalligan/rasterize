import AppKit

/// Rounded accent-tinted selection behind a selected row, ringed by a 1px
/// accent border — plus, opt in, the two things the LAYERS panel needs that
/// the Channels panel must not get:
///
/// * `isPrimarySelection` — with a multi-selection every selected row draws,
///   but exactly one of them is the PRIMARY (the layer the header controls
///   and every single-layer tool describe). A non-primary member gets the
///   same shape at half strength and no accent ring, so "the layer tools act
///   on" is still readable at a glance.
/// * `depth` — faint vertical rules down the indent gutters, one per
///   enclosing group, so a nested stack stays readable when the group rows
///   themselves have scrolled away.
///
/// **Both default to today's exact drawing** (`isPrimarySelection` true,
/// `depth` zero) because this class is shared with
/// `ChannelsPanelViewController`, which has neither a tree nor a
/// multi-selection and configures neither property.
///
/// They are set by the panel from the same `LayerRowModel` the cell is built
/// from (`LayersPanelViewController.tableView(_:rowViewForRow:)`), not by the
/// cell: AppKit builds a row view BEFORE the cell that goes in it and draws
/// this background whether or not a cell has landed, so the row has to know
/// its own depth without asking one.
final class LayerRowView: NSTableRowView {
    /// False draws the weaker "also selected" treatment. True — the default —
    /// is exactly the drawing every row had before multi-selection existed.
    var isPrimarySelection = true {
        didSet {
            if isPrimarySelection != oldValue { needsDisplay = true }
        }
    }

    /// The row's nesting depth; 0 — the default — draws no guides at all.
    var depth = 0 {
        didSet {
            if depth != oldValue { needsDisplay = true }
        }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard depth > 0 else { return }
        DS.border.setFill()
        for level in 0..<depth {
            // 2px shy of the row's edges top and bottom, so consecutive rows
            // read as one dashed rule rather than a solid bar.
            let rule = NSRect(
                x: LayerCellView.guideX(level: level), y: bounds.minY + 2,
                width: 1, height: max(bounds.height - 4, 0))
            NSBezierPath(rect: rule).fill()
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        // Half-pixel inset keeps the 1px stroke crisp.
        let rect = bounds.insetBy(dx: 6, dy: 2).insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        if isPrimarySelection {
            DS.selectionFill.setFill()
            path.fill()
            path.lineWidth = 1
            DS.accent.setStroke()
            path.stroke()
            return
        }
        // Half the fill and a faded ring: present, clearly selected, and
        // clearly not the row the header describes.
        DS.selectionFill.withAlphaComponent(0.11).setFill()
        path.fill()
        path.lineWidth = 1
        DS.accent.withAlphaComponent(0.45).setStroke()
        path.stroke()
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
    /// ⌘-click: load what this well shows as the selection (Photoshop). It
    /// takes precedence over the double-click, which would otherwise eat
    /// the second press of a ⌘-double-click.
    var onCommandClick: ((NSEvent) -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), let onCommandClick = onCommandClick {
            onCommandClick(event)
            return
        }
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

/// A GROUP row's disclosure triangle: the chevron that opens and closes the
/// group in the panel.
///
/// It copies `ThumbnailWellView`'s swallow-without-`super` pattern exactly,
/// for the same two reasons and one more:
///
/// * no `super.mouseDown` on the handled path, so clicking the chevron never
///   starts the table's row drag and never moves the selection — Photoshop's
///   triangle behaves the same way;
/// * **a ⌘-click is swallowed too**, because ⌘-click on a row is AppKit's
///   toggle-membership gesture and a triangle that let it through would
///   silently add or drop a layer from the selection every time the group was
///   opened with ⌘ held.
///
/// Toggling is not an undo step but IS a document change: `open` is persisted
/// in the `.rz` layer record, so the click routes to
/// `ImageDocument.setGroupExpanded` (which counts a change and registers no
/// undo).
final class DisclosureView: NSView {
    var onClick: (() -> Void)?

    /// Drawn open (chevron down) or closed (chevron right).
    var expanded = true {
        didSet {
            if expanded != oldValue { needsDisplay = true }
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let onClick = onClick else {
            super.mouseDown(with: event)
            return
        }
        onClick()
    }

    override func draw(_ dirtyRect: NSRect) {
        let symbol = expanded ? "chevron.down" : "chevron.right"
        let label = expanded ? "Expanded" : "Collapsed"
        // The symbol is present on every system this build runs on; the text
        // glyph is the codebase's established belt-and-braces fallback (the
        // eye and the tool rail do the same), never a force unwrap.
        if let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold))
        {
            let tinted = icon.tinted(with: DS.textMuted)
            let size = tinted.size
            tinted.draw(
                in: NSRect(
                    x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                    width: size.width, height: size.height))
            return
        }
        let glyph = expanded ? "▾" : "▸"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: DS.sans(11, weight: .semibold), .foregroundColor: DS.textMuted,
        ]
        let size = glyph.size(withAttributes: attributes)
        glyph.draw(
            at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
            withAttributes: attributes)
    }
}

/// The row's trailing status badges: a LOCK glyph naming that the entry is
/// locked, and a LINK glyph for an entry in a link group.
///
/// One view that draws both rather than two image views in a stack, so a row
/// with no badges costs exactly zero width and the name field keeps every
/// point it has today. It deliberately does NOT override `mouseDown`: these
/// are decoration, so a click on one must fall through the responder chain to
/// the row and still select or drag it — the opposite of `ThumbnailWellView`
/// and `DisclosureView`, which swallow because they have their own gesture.
final class LayerBadgeView: NSView {
    /// One badge's box. 14pt matches the thumbnail chips' plate height, so
    /// the row's small marks are all one size.
    private static let side: CGFloat = 14
    private static let gap: CGFloat = 3

    var locks: LockFlags = [] {
        didSet {
            if locks != oldValue { badgesChanged() }
        }
    }

    var linked = false {
        didSet {
            if linked != oldValue { badgesChanged() }
        }
    }

    private var badgeCount: Int { (locks.isEmpty ? 0 : 1) + (linked ? 1 : 0) }

    override var intrinsicContentSize: NSSize {
        let count = badgeCount
        guard count > 0 else { return NSSize(width: 0, height: Self.side) }
        return NSSize(
            width: CGFloat(count) * Self.side + CGFloat(count - 1) * Self.gap,
            height: Self.side)
    }

    private func badgesChanged() {
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        var x = bounds.minX
        if !locks.isEmpty {
            // A CLOSED padlock only for Lock All; a partial lock draws the
            // open one, so "everything is frozen" and "one thing is" do not
            // look the same at 14pt.
            drawBadge(
                symbol: locks == .all ? "lock.fill" : "lock.open",
                fallback: locks == .all ? "▪" : "▫",
                description: "Locked", at: x,
                tint: locks == .all ? DS.textStrong : DS.textMuted)
            x += Self.side + Self.gap
        }
        if linked {
            drawBadge(
                symbol: "link", fallback: "⧉", description: "Linked", at: x, tint: DS.textMuted)
        }
    }

    /// One badge, symbol-first with the established text-glyph fallback.
    private func drawBadge(
        symbol: String, fallback: String, description: String, at x: CGFloat, tint: NSColor
    ) {
        let box = NSRect(
            x: x, y: bounds.midY - Self.side / 2, width: Self.side, height: Self.side)
        if let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: description)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .regular))
        {
            let tinted = icon.tinted(with: tint)
            let size = tinted.size
            tinted.draw(
                in: NSRect(
                    x: box.midX - size.width / 2, y: box.midY - size.height / 2,
                    width: size.width, height: size.height))
            return
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: DS.sans(11), .foregroundColor: tint,
        ]
        let size = fallback.size(withAttributes: attributes)
        fallback.draw(
            at: NSPoint(x: box.midX - size.width / 2, y: box.midY - size.height / 2),
            withAttributes: attributes)
    }
}

/// Draws a thumbnail aspect-fit (never upscaled) inside a well, plus — for a
/// DISABLED layer mask — a diagonal slash across it, and — for a layer that
/// carries a description — a corner badge naming its kind ("T" for text,
/// "◐" for an adjustment layer; a layer is one OR the other, never both),
/// and — for a styled layer — an "fx" chip in the opposite corner (a text
/// layer can carry a style, so the two chips coexist).
///
/// With no image it can instead draw a centred SYMBOL: that is what a GROUP
/// row shows, since a group has no pixels of its own and rendering its
/// projection for a 34pt well would composite the whole subtree once per row
/// on every reload.
final class ThumbnailImageView: NSView {
    /// A symbol drawn in place of a thumbnail, with the established text
    /// fallback for a system that does not carry it.
    struct Glyph: Equatable {
        let symbol: String
        let fallback: String
        let description: String
    }

    var image: NSImage? {
        didSet { needsDisplay = true }
    }

    /// Drawn only when `image` is nil — a group's folder, never a substitute
    /// for a layer whose thumbnail simply has not been resampled yet.
    var glyph: Glyph? {
        didSet {
            if glyph != oldValue { needsDisplay = true }
        }
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

    /// The layer-style chip ("fx"), top-right; nil for an unstyled layer.
    var styleBadge: String? {
        didSet {
            if styleBadge != oldValue { needsDisplay = true }
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
        } else if let glyph = glyph {
            drawGlyph(glyph)
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
        if let badge = badge {
            drawChip(badge, atTop: false)
        }
        if let styleBadge = styleBadge {
            drawChip(styleBadge, atTop: true)
        }
    }

    /// The centred stand-in for pixels: half the well's height, so a folder
    /// reads as an icon rather than as a picture of one.
    private func drawGlyph(_ glyph: Glyph) {
        let side = min(bounds.width, bounds.height)
        if let icon = NSImage(
            systemSymbolName: glyph.symbol, accessibilityDescription: glyph.description)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: side * 0.5, weight: .regular))
        {
            let tinted = icon.tinted(with: DS.textMuted)
            let size = tinted.size
            tinted.draw(
                in: NSRect(
                    x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                    width: size.width, height: size.height))
            return
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: DS.sans(side * 0.5, weight: .regular), .foregroundColor: DS.textMuted,
        ]
        let size = glyph.fallback.size(withAttributes: attributes)
        glyph.fallback.draw(
            at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
            withAttributes: attributes)
    }

    /// A badge chip in the right corner — bottom for the kind badge, top for
    /// the style chip: a filled, bordered plate — the slash's halo idea as a
    /// solid — so the letters read over any thumbnail.
    private func drawChip(_ text: String, atTop: Bool) {
        guard !text.isEmpty else { return }
        let label = NSAttributedString(
            string: text,
            attributes: [.font: DS.sans(10, weight: .semibold), .foregroundColor: DS.textStrong])
        let labelSize = label.size()
        let chip = NSRect(
            x: bounds.maxX - max(labelSize.width + 7, 14) - 2,
            y: atTop ? bounds.maxY - 16 : bounds.minY + 2,
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

/// One row of the layers table: 22px visibility eye, a disclosure column, a
/// framed thumbnail (plus a second one for the layer's mask), then a two-line
/// stack — editable name over a mono meta line naming the layer's kind (or,
/// for a plain raster layer, its pixel size) — and the lock/link badges at the
/// trailing edge. A row inside a GROUP indents its thumbnail block one step
/// per enclosing level; a CLIPPED layer indents it once more, behind a "↳"
/// arrow — it rides on the layer below. A GROUP row draws a folder instead of
/// a thumbnail and a chevron in the disclosure column. The active layer rings
/// whichever thumbnail brush/eraser currently edit. Callbacks route edits back
/// to the panel controller.
///
/// **Any new hit-testable subview here must swallow ⌘-clicks**, the way
/// `ThumbnailWellView` and `DisclosureView` do. ⌘-click on a row is AppKit's
/// toggle-membership gesture for the multi-selection, and ⌘-click on a
/// thumbnail well already means "load this layer's transparency as the
/// selection": a subview that lets the event through to `super` silently
/// steals one of the two.
final class LayerCellView: NSView, NSTextFieldDelegate {
    /// Thumbnail well side: 34 on its own, smaller once a mask thumbnail
    /// sits beside it — the row height never grows.
    static let thumbSide: CGFloat = 34
    static let pairedThumbSide: CGFloat = 28
    private static let thumbGap: CGFloat = 5
    /// Extra leading on a clipped row's thumbnail block; the "↳" arrow sits
    /// in the gap this opens up.
    private static let clipIndent: CGFloat = 16
    /// One nesting level's indent. 14 is a shade under the clip indent's 16
    /// and is what fits: at the 304pt panel width the name field still holds
    /// a readable name at depth 3, which is deeper than a real document
    /// nests.
    fileprivate static let depthIndent: CGFloat = 14
    /// The disclosure column: a chevron's width, present on EVERY row (empty
    /// on a raster one) so siblings line up whether or not one of them is a
    /// group — Photoshop's dedicated triangle column. It indents with the
    /// row, so a group's chevron always sits just left of its own folder.
    fileprivate static let disclosureSide: CGFloat = 13
    /// Where the depth-0 disclosure column starts, measured from the cell's
    /// leading edge: the 10pt leading inset, the 22pt eye gutter (the eye
    /// deliberately does NOT indent — it stays scannable at depth), 1pt of
    /// air.
    fileprivate static let disclosureOriginX: CGFloat = 10 + 22 + 1
    /// The thumbnail block's leading at depth 0, from the eye's trailing
    /// edge: 1pt of air, the disclosure column, 2pt more.
    private static let thumbBaseLeading: CGFloat = 1 + disclosureSide + 2

    /// The x of the vertical guide rule standing for nesting LEVEL `level`,
    /// from the row's leading edge — the centre of that level's disclosure
    /// column, so the rule runs straight through the chevron of the group it
    /// belongs to. Read by `LayerRowView`, which draws the guides.
    fileprivate static func guideX(level: Int) -> CGFloat {
        disclosureOriginX + depthIndent * CGFloat(level) + disclosureSide / 2
    }

    private let eyeButton = NSButton(title: "", target: nil, action: nil)
    private let disclosure = DisclosureView()
    private let clipLabel = NSTextField(labelWithString: "↳")
    private let thumbView = ThumbnailImageView()
    private let thumbFrame = ThumbnailWellView()
    private let maskView = ThumbnailImageView()
    private let maskFrame = ThumbnailWellView()
    private let nameField = NSTextField(string: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private let badgeView = LayerBadgeView()
    private var committedName = ""
    private var hasMask = false
    /// A group has no pixels of its own, so the paint-target ring must never
    /// land on its folder — remembered here because `refreshTargetRings`
    /// re-rings rows without re-configuring them.
    private var isGroupRow = false
    private var thumbLeading: NSLayoutConstraint!
    private var thumbWidth: NSLayoutConstraint!
    private var thumbHeight: NSLayoutConstraint!
    private var maskWidth: NSLayoutConstraint!
    private var maskHeight: NSLayoutConstraint!
    private var maskLeading: NSLayoutConstraint!
    private var disclosureLeading: NSLayoutConstraint!
    private var nameTrailing: NSLayoutConstraint!

    var onToggleVisible: (() -> Void)?
    var onRename: ((String) -> Void)?
    /// Clicking either thumbnail selects this layer and points brush/eraser
    /// at the clicked target.
    var onSelectTarget: ((PaintTarget) -> Void)?
    /// ⌘-click on either thumbnail: load the layer's transparency
    /// (`.layer`) or its mask (`.mask`) as the selection, with the selection
    /// tools' modifier convention (Shift adds, Option subtracts, both
    /// intersect).
    var onLoadSelection: ((PaintTarget, SelectionCombineMode) -> Void)?
    /// Double-clicking the layer's own thumbnail (the badged one, not the
    /// mask's) reopens whatever the layer was made from — a text layer's
    /// on-canvas editor, an adjustment layer's options dialog. Unset on a
    /// plain raster layer, which has no source to reopen.
    var onEditSource: (() -> Void)?

    /// A GROUP row's disclosure was clicked. Not an undo step, but a real
    /// document change (`ImageDocument.setGroupExpanded`), because `open` is
    /// persisted in the `.rz` layer record.
    var onToggleExpanded: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        eyeButton.translatesAutoresizingMaskIntoConstraints = false
        eyeButton.isBordered = false
        eyeButton.setButtonType(.momentaryChange)
        eyeButton.target = self
        eyeButton.action = #selector(eyeClicked(_:))

        // The chevron swallows its own clicks (including ⌘-clicks), so it
        // never starts the row drag and never toggles row membership.
        disclosure.translatesAutoresizingMaskIntoConstraints = false
        disclosure.isHidden = true
        disclosure.onClick = { [weak self] in self?.onToggleExpanded?() }

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
        thumbFrame.onCommandClick = { [weak self] event in
            self?.onLoadSelection?(.layer, Self.combineMode(for: event))
        }
        maskFrame.onCommandClick = { [weak self] event in
            self?.onLoadSelection?(.mask, Self.combineMode(for: event))
        }
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

        badgeView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(eyeButton)
        addSubview(disclosure)
        addSubview(clipLabel)
        addSubview(thumbFrame)
        addSubview(maskFrame)
        addSubview(nameField)
        addSubview(metaLabel)
        addSubview(badgeView)

        // The mask well collapses to zero (and hides) on a layer without a
        // mask, so the name field's leading edge follows either way. The
        // whole thumbnail block indents one depthIndent per enclosing group
        // and once more on a clipped layer (thumbLeading carries both), the
        // "↳" arrow fills the clip gap, and the chevron rides the same
        // indent one column to the left. The badges own the trailing edge
        // and are zero-wide when the row has none, so an unlocked, unlinked
        // row keeps exactly today's name width.
        thumbLeading = thumbFrame.leadingAnchor.constraint(
            equalTo: eyeButton.trailingAnchor, constant: Self.thumbBaseLeading)
        thumbWidth = thumbFrame.widthAnchor.constraint(equalToConstant: Self.thumbSide)
        thumbHeight = thumbFrame.heightAnchor.constraint(equalToConstant: Self.thumbSide)
        maskWidth = maskFrame.widthAnchor.constraint(equalToConstant: 0)
        maskHeight = maskFrame.heightAnchor.constraint(equalToConstant: 0)
        maskLeading = maskFrame.leadingAnchor.constraint(
            equalTo: thumbFrame.trailingAnchor, constant: 0)
        disclosureLeading = disclosure.leadingAnchor.constraint(
            equalTo: eyeButton.trailingAnchor, constant: 1)
        nameTrailing = nameField.trailingAnchor.constraint(
            equalTo: badgeView.leadingAnchor, constant: 0)

        NSLayoutConstraint.activate([
            eyeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            eyeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            eyeButton.widthAnchor.constraint(equalToConstant: 22),

            disclosureLeading,
            disclosure.widthAnchor.constraint(equalToConstant: Self.disclosureSide),
            disclosure.topAnchor.constraint(equalTo: topAnchor),
            disclosure.bottomAnchor.constraint(equalTo: bottomAnchor),

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

            badgeView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            badgeView.centerYAnchor.constraint(equalTo: centerYAnchor),

            nameField.leadingAnchor.constraint(equalTo: maskFrame.trailingAnchor, constant: 9),
            nameTrailing,
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

    /// Fills the row in from its model.
    ///
    /// One value argument, not seventeen positional ones: the row gained a
    /// depth, a kind, a lock badge, a link marker and a disclosure state in
    /// this phase (`LayerRowModel`), and the panel builds every one of them
    /// once per reload so a cell never asks the core anything.
    func configure(_ model: LayerRowModel) {
        let info = model.info
        let hasMask = model.hasMask
        let maskThumbnail = model.maskThumbnail
        let maskEnabled = model.maskEnabled
        let isText = model.isText
        let isAdjustment = model.isAdjustment
        let isLivePhoto = model.isLivePhoto
        let isShape = model.isShape
        let clipped = model.clipped
        let hasStyle = model.hasStyle
        let thumbnail = model.thumbnail
        let paintTarget = model.paintTarget
        // The PRIMARY entry gets the accent treatment; the other members of a
        // multi-selection get a middle weight and the row view's weaker fill,
        // so exactly one row reads as the one the header controls describe.
        let primary = model.isPrimary
        isGroupRow = model.isGroup
        committedName = info.name
        nameField.stringValue = info.name
        nameField.font = DS.sans(
            13, weight: primary ? .semibold : (model.isSelected ? .medium : .regular))
        if !info.visible {
            nameField.textColor = DS.textFaint
        } else {
            nameField.textColor = primary ? DS.accent : DS.textStrong
        }
        // The meta line names the layer's KIND — blend and opacity already
        // sit in the header above for the selected layer. A plain raster
        // layer reports its pixel size instead.
        if isAdjustment {
            metaLabel.stringValue = "adjustment"
        } else if isText {
            metaLabel.stringValue = "text"
        } else if isLivePhoto {
            metaLabel.stringValue = "live photo"
        } else if isShape {
            metaLabel.stringValue = "shape"
        } else if model.isGroup {
            // A group has no pixel rect of its own, so it reports what it
            // holds instead — which is what a COLLAPSED group most needs to
            // say.
            metaLabel.stringValue =
                model.childCount == 1 ? "group · 1 item" : "group · \(model.childCount) items"
        } else {
            metaLabel.stringValue = "\(info.width) × \(info.height)"
        }
        // A styled layer says so on the meta line too — the chip is small.
        // Locks and links do NOT: they have their own badges at the trailing
        // edge, and saying it twice on a 304pt row costs the name field
        // characters it needs more.
        if hasStyle {
            metaLabel.stringValue += " · fx"
        }
        metaLabel.textColor = primary ? DS.accent : DS.textFaint

        badgeView.locks = model.locks
        badgeView.linked = model.isLinked
        badgeView.toolTip = Self.badgeTooltip(locks: model.locks, linked: model.isLinked)
        // Zero-wide with no badges, so the name keeps its full width; 6pt of
        // air once one shows.
        nameTrailing.constant = model.locks.isEmpty && !model.isLinked ? 0 : -6

        disclosure.isHidden = !model.isGroup
        disclosure.expanded = model.expanded
        disclosure.toolTip = model.expanded ? "Collapse Group" : "Expand Group"

        self.hasMask = hasMask
        // The depth and clip indents shift the whole thumbnail block (name
        // and meta follow their leading anchors); the arrow shows in the clip
        // gap and the chevron rides one column to the left of the block.
        clipLabel.isHidden = !clipped
        let indent = CGFloat(max(model.depth, 0)) * Self.depthIndent
        thumbLeading.constant =
            Self.thumbBaseLeading + indent + (clipped ? Self.clipIndent : 0)
        disclosureLeading.constant = 1 + indent
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
        setTargetHighlight(layerActive: primary, target: paintTarget)

        thumbView.image = thumbnail
        // A GROUP shows a folder, never its own projection: the panel leaves
        // its thumbnail nil precisely so a reload never composites a subtree
        // per row.
        thumbView.glyph =
            model.isGroup
            ? ThumbnailImageView.Glyph(symbol: "folder", fallback: "▤", description: "Group")
            : nil
        thumbView.alphaValue = info.visible ? 1.0 : 0.35
        // A text layer is still editable as text: say so on the thumbnail,
        // and the badge goes away the moment the description is dropped. An
        // adjustment layer badges ◐ and a live photo layer ▶ the same way
        // (the three are mutually exclusive — one meta slot, one type). Any
        // of them double-clicks back to its source; a plain raster layer has
        // none.
        let described = isText || isAdjustment || isLivePhoto
        thumbView.badge = isText ? "T" : (isAdjustment ? "◐" : (isLivePhoto ? "▶" : nil))
        // The style chip is independent of the kind: a styled text layer
        // shows both. The badge is driven by the cheap has-style query only
        // (listing the effects would need the style decoded per row).
        thumbView.styleBadge = hasStyle ? "fx" : nil
        thumbFrame.onDoubleClick = described ? { [weak self] in self?.onEditSource?() } : nil
        if model.isGroup {
            // A group has no pixels to paint and no source to reopen; the
            // well is still a click target, because clicking it selects the
            // group like any other row.
            thumbFrame.toolTip = "Layer group"
        } else if isText {
            thumbFrame.toolTip =
                "Text layer — double-click to edit the text (painting rasterizes it)"
        } else if isAdjustment {
            thumbFrame.toolTip = "Adjustment layer — double-click for options"
        } else if isLivePhoto {
            thumbFrame.toolTip =
                "Live Photo layer — double-click to select a frame (painting rasterizes it)"
        } else {
            thumbFrame.toolTip = "Paint on the layer"
        }
        if hasStyle {
            thumbFrame.toolTip = (thumbFrame.toolTip ?? "") + " — has layer effects"
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

    /// What the trailing badges mean, in the lock vocabulary the menu and the
    /// agent share (`LockFlags.displayName`), so a badge never has to be
    /// guessed at.
    private static func badgeTooltip(locks: LockFlags, linked: Bool) -> String? {
        var parts: [String] = []
        if locks == .all {
            parts.append("Locked (Lock All)")
        } else if !locks.isEmpty {
            parts.append("Locked: " + locks.names.joined(separator: ", "))
        }
        if linked {
            parts.append("Linked — moves and transforms with its link group")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The selection tools' modifier convention (the one copy lives on
    /// `SelectionCombineMode`), with Replace as the no-modifier base: a panel
    /// click carries no options-bar mode.
    private static func combineMode(for event: NSEvent) -> SelectionCombineMode {
        SelectionCombineMode.from(event.modifierFlags)
    }

    /// Rings the thumbnail brush/eraser would hit — but only on the active
    /// layer, where the paint target means anything. Three explicit tests,
    /// not "layer unless mask": with a COLOUR PLANE or a CHANNEL targeted
    /// neither well is the target, and ringing the layer would lie.
    ///
    /// A GROUP never rings its folder — it has no pixels to paint — but it
    /// DOES ring its mask well: a group's mask is canvas-sized and paintable
    /// like any other.
    func setTargetHighlight(layerActive: Bool, target: PaintTarget) {
        let maskRinged = layerActive && hasMask && target == .mask
        let layerRinged = layerActive && !isGroupRow && target == .layer
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
