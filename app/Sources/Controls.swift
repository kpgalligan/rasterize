import AppKit

// MARK: - StickerButton

/// The house button: a pill with a 1.5px border and the crisp
/// `2px 2px 0` sticker shadow. Hover lifts 1px up-left and grows the shadow
/// to 4px; press translates down-right and drops the shadow. Primary style
/// is the system accent with white text; secondary is the window background
/// with strong text.
final class StickerButton: NSButton {
    enum Style {
        case primary
        case secondary
    }

    private let style: Style
    private var hovered = false

    /// Body height 28 plus 2px top/left margin and 4px max shadow room.
    private static let bodyHeight: CGFloat = 28

    init(title: String, style: Style, target: AnyObject?, action: Selector?) {
        self.style = style
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        isBordered = false
        wantsLayer = true
        font = DS.sans(13, weight: .semibold)
        setButtonType(.momentaryChange)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("StickerButton does not support NSCoder")
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        let textWidth = title.size(withAttributes: [.font: font ?? DS.sans(13)]).width
        return NSSize(width: ceil(textWidth) + 32 + 6, height: Self.bodyHeight + 6)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow],
                owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let pressed = isHighlighted && isEnabled
        let rest = NSRect(
            x: 2, y: 2, width: bounds.width - 6, height: Self.bodyHeight)
        let body: NSRect
        let shadowGap: CGFloat
        if pressed {
            body = rest.offsetBy(dx: 3, dy: 3)
            shadowGap = 0
        } else if hovered && isEnabled {
            body = rest.offsetBy(dx: -1, dy: -1)
            shadowGap = 4
        } else {
            body = rest
            shadowGap = 2
        }
        let radius = body.height / 2
        let alpha: CGFloat = isEnabled ? 1 : 0.42

        if shadowGap > 0 && isEnabled {
            let shadowPath = NSBezierPath(
                roundedRect: body.offsetBy(dx: shadowGap, dy: shadowGap),
                xRadius: radius, yRadius: radius)
            DS.stickerShadow.setFill()
            shadowPath.fill()
        }

        let path = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
        (style == .primary ? DS.accent : DS.chromeBackground)
            .withAlphaComponent(alpha).setFill()
        path.fill()
        path.lineWidth = 1.5
        DS.borderStrong.withAlphaComponent(alpha).setStroke()
        path.stroke()

        let textColor = (style == .primary ? DS.onAccent : DS.textStrong)
            .withAlphaComponent(alpha)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? DS.sans(13, weight: .semibold),
            .foregroundColor: textColor,
        ]
        let size = title.size(withAttributes: attributes)
        title.draw(
            at: NSPoint(x: body.midX - size.width / 2, y: body.midY - size.height / 2),
            withAttributes: attributes)
    }
}

// MARK: - GhostButton

/// Borderless icon button used in the toolbar (icon over 10px label) and the
/// panel footer (icon only). Hover shows a faint fill; press scales
/// to 0.97; disabled dims to 42%.
final class GhostButton: NSButton {
    private let iconName: String
    private let fallbackGlyph: String
    private let caption: String?
    private var hovered = false

    init(
        symbol: String, fallback: String, caption: String?, tooltip: String,
        action: Selector?
    ) {
        self.iconName = symbol
        self.fallbackGlyph = fallback
        self.caption = caption
        super.init(frame: .zero)
        title = ""
        target = nil
        self.action = action
        isBordered = false
        wantsLayer = true
        setButtonType(.momentaryChange)
        toolTip = tooltip
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("GhostButton does not support NSCoder")
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        caption == nil ? NSSize(width: 30, height: 26) : NSSize(width: 52, height: 46)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow],
                owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if hovered && isEnabled {
            let path = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
            DS.hoverFill.setFill()
            path.fill()
        }

        let alpha: CGFloat = isEnabled ? 1.0 : 0.42
        let tint = DS.textStrong.withAlphaComponent(alpha)
        let context = NSGraphicsContext.current?.cgContext
        if isHighlighted && isEnabled {
            context?.saveGState()
            context?.translateBy(x: bounds.midX, y: bounds.midY)
            context?.scaleBy(x: 0.97, y: 0.97)
            context?.translateBy(x: -bounds.midX, y: -bounds.midY)
        }
        defer {
            if isHighlighted && isEnabled { context?.restoreGState() }
        }

        if let caption = caption {
            drawIcon(tint: tint, center: NSPoint(x: bounds.midX, y: 15))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: DS.sans(10), .foregroundColor: tint,
            ]
            let textSize = caption.size(withAttributes: attributes)
            caption.draw(
                at: NSPoint(x: bounds.midX - textSize.width / 2, y: 28),
                withAttributes: attributes)
        } else {
            drawIcon(tint: tint, center: NSPoint(x: bounds.midX, y: bounds.midY))
        }
    }

    private func drawIcon(tint: NSColor, center: NSPoint) {
        let icon = NSImage(systemSymbolName: iconName, accessibilityDescription: toolTip)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 15, weight: .medium))
        guard let icon = icon else {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: DS.sans(14), .foregroundColor: tint,
            ]
            let size = fallbackGlyph.size(withAttributes: attributes)
            fallbackGlyph.draw(
                at: NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2),
                withAttributes: attributes)
            return
        }
        let tinted = icon.tinted(with: tint)
        let size = tinted.size
        tinted.draw(
            in: NSRect(
                x: center.x - size.width / 2, y: center.y - size.height / 2,
                width: size.width, height: size.height))
    }
}

extension NSImage {
    /// Flat single-color rendering of a template/symbol image.
    func tinted(with color: NSColor) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            color.set()
            rect.fill()
            self.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1)
            return true
        }
        image.isTemplate = false
        return image
    }
}

// MARK: - Styled fields

enum DSField {
    /// Styles a text field as the design's 7px-radius bordered field with
    /// mono content ("a 7px rectangle means: type here").
    static func style(_ field: NSTextField) {
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.textColor = DS.textStrong
        field.font = DS.mono(13)
        field.wantsLayer = true
        field.layer?.borderWidth = 1
        field.layer?.borderColor = DS.borderStrong.cgColor
        field.layer?.cornerRadius = 7
        field.heightAnchor.constraint(equalToConstant: 26).isActive = true
    }
}

// MARK: - PanelTabsView

/// The right panel's tab row: full-width square tabs, equal widths, a 1px
/// divider between them and a 1px border under the whole row. The active tab
/// sits one step lighter than the chrome and wears a 2px accent rule along
/// its bottom edge; inactive tabs are flat and fill faintly on hover.
/// Selection is owned by the editor (each panel is built with its own tab
/// marked active).
final class PanelTabsView: NSView {
    private let titles: [String]
    private let activeIndex: Int
    private let onSelect: (Int) -> Void
    private var hoveredIndex: Int?

    init(titles: [String], activeIndex: Int, onSelect: @escaping (Int) -> Void) {
        self.titles = titles
        self.activeIndex = activeIndex
        self.onSelect = onSelect
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PanelTabsView does not support NSCoder")
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: DS.tabHeight)
    }

    /// Equal widths with the rounding remainder folded into the boundaries,
    /// so N tabs always tile the row exactly.
    private func tabRect(_ index: Int) -> NSRect {
        let width = bounds.width / CGFloat(max(titles.count, 1))
        let left = (CGFloat(index) * width).rounded()
        let right = (CGFloat(index + 1) * width).rounded()
        return NSRect(x: left, y: 0, width: right - left, height: bounds.height)
    }

    private func tabIndex(at point: NSPoint) -> Int? {
        titles.indices.first { tabRect($0).contains(point) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow],
                owner: self, userInfo: nil))
    }

    private func updateHover(with event: NSEvent) {
        let index = tabIndex(at: convert(event.locationInWindow, from: nil))
        let hovered = index == activeIndex ? nil : index
        if hovered != hoveredIndex {
            hoveredIndex = hovered
            needsDisplay = true
        }
    }

    override func mouseEntered(with event: NSEvent) { updateHover(with: event) }
    override func mouseMoved(with event: NSEvent) { updateHover(with: event) }

    override func mouseExited(with event: NSEvent) {
        guard hoveredIndex != nil else { return }
        hoveredIndex = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = tabIndex(at: point), index != activeIndex else { return }
        onSelect(index)
    }

    override func draw(_ dirtyRect: NSRect) {
        for (index, title) in titles.enumerated() {
            let rect = tabRect(index)
            if index == activeIndex || index == hoveredIndex {
                DS.hoverFill.setFill()
                rect.fill()
            }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: index == activeIndex ? DS.sans(12, weight: .semibold) : DS.sans(12),
                .foregroundColor: index == activeIndex ? DS.textStrong : DS.textMuted,
            ]
            let size = title.size(withAttributes: attributes)
            title.draw(
                at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                withAttributes: attributes)
        }

        DS.border.setFill()
        for index in 1..<max(titles.count, 1) {
            NSRect(x: tabRect(index).minX, y: 0, width: 1, height: bounds.height).fill()
        }
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()

        if titles.indices.contains(activeIndex) {
            let active = tabRect(activeIndex)
            DS.accent.setFill()
            NSRect(x: active.minX, y: bounds.height - 2, width: active.width, height: 2).fill()
        }
    }
}

// MARK: - Modal card control rows

/// One row of a modal card's control grid: a 106pt right-aligned label, the
/// control at 180pt, and — for a slider — a 52pt right-aligned mono readout,
/// spaced 12pt. Exactly the 106/12/180/12/52 metrics the sheets in
/// `Sheets.swift` lay out with `NSGridView`, but a stack view per row,
/// because a modal card hides whole rows (a control this OS is too old for)
/// and a hidden arranged subview simply detaches from a stack.
///
/// `AdjustmentSheet.sliderRow` is the instance-method twin of the slider
/// case and is deliberately left alone: it is a method on a controller that
/// owns the action, wired to that sheet's live preview, and folding the two
/// together would drag the sheet's state into a shared control.
///
/// The row OWNS its callback. A free builder function has no `@objc` target
/// to hang a control's action on, and the view hierarchy already owns the
/// row, so the row is the target and the closure lives exactly as long as
/// the card does.
final class CardControlRow: NSStackView {
    private let label: NSTextField
    private var format: ((Double) -> String)?
    private var readout: NSTextField?
    private var onSlide: ((Double) -> Void)?
    private var onToggle: ((Bool) -> Void)?
    private var onSelect: ((Int) -> Void)?

    private(set) var slider: NSSlider?
    private(set) var checkbox: NSButton?
    private(set) var popUp: NSPopUpButton?

    /// House metrics, in points.
    private static let labelWidth: CGFloat = 106
    private static let controlWidth: CGFloat = 180
    /// 64, not 52: "+0.00 EV" — the RAW Develop dialog's Exposure readout,
    /// and the Batch pane's — is eight glyphs of `DS.mono(12)` and clipped
    /// mid-glyph in the narrower column, because `NSTextField(labelWithString:)`
    /// breaks by CLIPPING (the same failure `sheetFootnote` carries a comment
    /// about). Both cards that use these rows are 560 pt wide with ~150 pt to
    /// spare beside the readout, and no other row's value grows.
    private static let readoutWidth: CGFloat = 64

    fileprivate init(label text: String) {
        label = fieldLabel(text)
        label.alignment = .right
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 12
        label.widthAnchor.constraint(equalToConstant: Self.labelWidth).isActive = true
        addArrangedSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("CardControlRow does not support NSCoder")
    }

    /// Enables or disables the whole row, dimming the label with the control
    /// so a value the file cannot use still reads as a value, not a blank.
    var isEnabled: Bool = true {
        didSet {
            slider?.isEnabled = isEnabled
            checkbox?.isEnabled = isEnabled
            popUp?.isEnabled = isEnabled
            label.textColor = isEnabled ? DS.textStrong : DS.textFaint
            readout?.textColor = isEnabled ? DS.textMuted : DS.textFaint
        }
    }

    fileprivate func addSlider(
        min: Double, max: Double, value: Double,
        format: @escaping (Double) -> String, onChange: @escaping (Double) -> Void
    ) {
        let slider = NSSlider(
            value: value, minValue: min, maxValue: max,
            target: self, action: #selector(sliderChanged(_:)))
        slider.isContinuous = true
        slider.widthAnchor.constraint(equalToConstant: Self.controlWidth).isActive = true
        let readout = NSTextField(labelWithString: format(value))
        readout.font = DS.mono(12)
        readout.textColor = DS.textMuted
        readout.alignment = .right
        readout.widthAnchor.constraint(equalToConstant: Self.readoutWidth).isActive = true
        self.slider = slider
        self.readout = readout
        self.format = format
        onSlide = onChange
        addArrangedSubview(slider)
        addArrangedSubview(readout)
    }

    fileprivate func addCheckbox(
        title: String, on: Bool, onChange: @escaping (Bool) -> Void
    ) {
        let button = NSButton(
            checkboxWithTitle: title, target: self, action: #selector(checkboxChanged(_:)))
        button.state = on ? .on : .off
        button.font = DS.sans(13)
        checkbox = button
        onToggle = onChange
        addArrangedSubview(button)
    }

    fileprivate func addPopUp(
        titles: [String], selected: Int, onChange: @escaping (Int) -> Void
    ) {
        let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
        popUp.addItems(withTitles: titles)
        popUp.selectItem(at: Swift.max(0, Swift.min(selected, titles.count - 1)))
        popUp.target = self
        popUp.action = #selector(popUpChanged(_:))
        popUp.widthAnchor.constraint(equalToConstant: Self.controlWidth).isActive = true
        self.popUp = popUp
        onSelect = onChange
        addArrangedSubview(popUp)
    }

    /// Moves the slider and its readout WITHOUT calling back — what a Reset
    /// button needs, so restoring twelve controls does not fire twelve
    /// changes.
    func setValue(_ value: Double) {
        slider?.doubleValue = value
        if let format = format { readout?.stringValue = format(value) }
    }

    /// The silent twin of `setValue` for a checkbox row.
    func setOn(_ on: Bool) {
        checkbox?.state = on ? .on : .off
    }

    /// The silent twin of `setValue` for a pop-up row.
    func setSelected(_ index: Int) {
        popUp?.selectItem(at: index)
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        let value = sender.doubleValue
        if let format = format { readout?.stringValue = format(value) }
        onSlide?(value)
    }

    @objc private func checkboxChanged(_ sender: NSButton) {
        onToggle?(sender.state == .on)
    }

    @objc private func popUpChanged(_ sender: NSPopUpButton) {
        onSelect?(sender.indexOfSelectedItem)
    }
}

/// A labelled slider row with a formatted readout (see `CardControlRow`).
func cardSliderRow(
    label: String, min: Double, max: Double, value: Double,
    format: @escaping (Double) -> String, onChange: @escaping (Double) -> Void
) -> CardControlRow {
    let row = CardControlRow(label: label)
    row.addSlider(min: min, max: max, value: value, format: format, onChange: onChange)
    return row
}

/// A labelled checkbox row (see `CardControlRow`).
func cardCheckboxRow(
    label: String, title: String, on: Bool, onChange: @escaping (Bool) -> Void
) -> CardControlRow {
    let row = CardControlRow(label: label)
    row.addCheckbox(title: title, on: on, onChange: onChange)
    return row
}

/// A labelled pop-up row (see `CardControlRow`).
func cardPopupRow(
    label: String, titles: [String], selected: Int, onChange: @escaping (Int) -> Void
) -> CardControlRow {
    let row = CardControlRow(label: label)
    row.addPopUp(titles: titles, selected: selected, onChange: onChange)
    return row
}
