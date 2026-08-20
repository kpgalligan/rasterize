import AppKit

// MARK: - OptionControl

/// Shared surface of the options-bar controls: a fixed intrinsic size, and a
/// `refresh()` that re-reads the descriptor closures (value and enabled
/// state). A disabled control dims to 42% and ignores input; the closures
/// stay the single source of truth — no control stores a value.
protocol OptionControl: NSView {
    func refresh()
}

// MARK: - OptionFieldControl

/// A borderless NSTextField gives no focus callback; this one reports
/// becoming first responder so its owner can swap the formatted rest
/// display ("24 px") for the bare editable number.
private final class FocusReportingTextField: NSTextField {
    var onFocus: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("FocusReportingTextField does not support NSCoder")
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?() }
        return accepted
    }
}

/// Numeric option field: a bordered container around an embedded borderless
/// mono field. At rest it shows the formatted value plus unit; while editing
/// it shows the bare number. Enter and end-editing commit (clamped to the
/// descriptor's range), Escape reverts.
final class OptionFieldControl: NSView, NSTextFieldDelegate, OptionControl {
    private let fixedWidth: CGFloat
    private let unit: String
    private let decimals: Int
    private let lower: Double
    private let upper: Double
    private let read: () -> Double
    private let write: (Double) -> Void
    private let enabled: () -> Bool
    private let onEdit: () -> Void
    private let field = FocusReportingTextField(frame: .zero)
    private var isActive = true
    /// True while an Enter/Escape hand-off is resigning first responder, so
    /// the resulting end-editing notification doesn't commit a second time.
    private var finishing = false

    init(
        width: CGFloat, unit: String, decimals: Int, min: Double, max: Double,
        read: @escaping () -> Double, write: @escaping (Double) -> Void,
        enabled: @escaping () -> Bool, onEdit: @escaping () -> Void
    ) {
        self.fixedWidth = width
        self.unit = unit
        self.decimals = decimals
        self.lower = min
        self.upper = max
        self.read = read
        self.write = write
        self.enabled = enabled
        self.onEdit = onEdit
        super.init(frame: .zero)
        wantsLayer = true
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = DS.mono(11)
        field.textColor = DS.textStrong
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.delegate = self
        field.onFocus = { [weak self] in self?.beginBareEditing() }
        addSubview(field)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("OptionFieldControl does not support NSCoder")
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: fixedWidth, height: DS.controlHeight)
    }

    override func layout() {
        super.layout()
        let height = ceil(DS.mono(11).boundingRectForFont.height)
        field.frame = NSRect(
            x: 7, y: floor((bounds.height - height) / 2),
            width: max(0, bounds.width - 14), height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: DS.controlRadius, yRadius: DS.controlRadius)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        DS.border.setStroke()
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        // The 7pt margins around the embedded field still read as the
        // control; a click anywhere on it starts editing.
        guard isActive else { return }
        window?.makeFirstResponder(field)
    }

    func refresh() {
        isActive = enabled()
        alphaValue = isActive ? 1 : 0.42
        field.isEditable = isActive
        field.isSelectable = isActive
        guard field.currentEditor() == nil else { return }
        field.stringValue = restText()
    }

    // MARK: Editing

    private func restText() -> String {
        bareText() + unit
    }

    private func bareText() -> String {
        String(format: "%.\(decimals)f", read())
    }

    private func beginBareEditing() {
        field.stringValue = bareText()
        if let editor = field.currentEditor() as? NSTextView {
            editor.drawsBackground = false
        }
        field.currentEditor()?.selectAll(nil)
    }

    private func parsedValue(_ text: String) -> Double? {
        var trimmed = text.trimmingCharacters(in: .whitespaces)
        let bareUnit = unit.trimmingCharacters(in: .whitespaces)
        if !bareUnit.isEmpty, trimmed.hasSuffix(bareUnit) {
            trimmed = String(trimmed.dropLast(bareUnit.count))
                .trimmingCharacters(in: .whitespaces)
        }
        return Double(trimmed)
    }

    private func commitCurrentText() {
        guard let value = parsedValue(field.stringValue) else { return }
        let clamped = Swift.min(upper, Swift.max(lower, value))
        // An unchanged value is not an edit: some setters do real work on
        // write (the selection-morphology fields apply their op), so merely
        // focusing a field and tabbing away must not fire them.
        guard abs(clamped - read()) > 0.0001 else { return }
        write(clamped)
        onEdit()
    }

    private func finishEditing(commit: Bool) {
        finishing = true
        if commit { commitCurrentText() }
        window?.makeFirstResponder(nil)
        finishing = false
        field.stringValue = restText()
    }

    func control(
        _ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector
    ) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            finishEditing(commit: true)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            finishEditing(commit: false)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        // Click-away and Tab land here directly; Enter/Escape came through
        // finishEditing and already handled the commit.
        guard !finishing else { return }
        commitCurrentText()
        field.stringValue = restText()
    }
}

// MARK: - OptionDisplayControl

/// Read-only mono readout (the eyedropper's hex value): no chrome, just the
/// text vertically centered in the control height.
final class OptionDisplayControl: NSView, OptionControl {
    private let fixedWidth: CGFloat
    private let read: () -> String
    private let enabled: () -> Bool
    private var text = ""

    init(width: CGFloat, read: @escaping () -> String, enabled: @escaping () -> Bool) {
        self.fixedWidth = width
        self.read = read
        self.enabled = enabled
        super.init(frame: .zero)
        wantsLayer = true
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("OptionDisplayControl does not support NSCoder")
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: fixedWidth, height: DS.controlHeight)
    }

    func refresh() {
        text = read()
        alphaValue = enabled() ? 1 : 0.42
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: DS.mono(11), .foregroundColor: DS.textStrong,
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(x: 0, y: (bounds.height - size.height) / 2),
            withAttributes: attributes)
    }
}

// MARK: - OptionPopupControl

/// Field-styled popup: the current item in mono with an up/down chevron at
/// the right; clicking pops an NSMenu with a checkmark on the current item.
final class OptionPopupControl: NSView, OptionControl {
    private let fixedWidth: CGFloat
    private let items: [String]
    private let read: () -> Int
    private let write: (Int) -> Void
    private let enabled: () -> Bool
    private let onEdit: () -> Void
    private var isActive = true
    private var hovered = false

    init(
        width: CGFloat, items: [String], read: @escaping () -> Int,
        write: @escaping (Int) -> Void, enabled: @escaping () -> Bool,
        onEdit: @escaping () -> Void
    ) {
        self.fixedWidth = width
        self.items = items
        self.read = read
        self.write = write
        self.enabled = enabled
        self.onEdit = onEdit
        super.init(frame: .zero)
        wantsLayer = true
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("OptionPopupControl does not support NSCoder")
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: fixedWidth, height: DS.controlHeight)
    }

    func refresh() {
        isActive = enabled()
        alphaValue = isActive ? 1 : 0.42
        needsDisplay = true
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

    override func mouseDown(with event: NSEvent) {
        guard isActive else { return }
        let menu = NSMenu()
        let current = read()
        for (index, title) in items.enumerated() {
            let item = NSMenuItem(title: title, action: #selector(itemPicked(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = index == current ? .on : .off
            menu.addItem(item)
        }
        menu.minimumWidth = bounds.width
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 2), in: self)
    }

    @objc private func itemPicked(_ sender: NSMenuItem) {
        write(sender.tag)
        onEdit()
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: DS.controlRadius, yRadius: DS.controlRadius)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        if hovered && isActive {
            DS.hoverFill.setFill()
            path.fill()
        }
        DS.border.setStroke()
        path.stroke()

        let index = read()
        let text = items.indices.contains(index) ? items[index] : ""
        let attributes: [NSAttributedString.Key: Any] = [
            .font: DS.mono(11), .foregroundColor: DS.textStrong,
        ]
        let textSize = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(x: 7, y: (bounds.height - textSize.height) / 2),
            withAttributes: attributes)

        if let icon = NSImage(
            systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: "Choose")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .medium))
        {
            let tinted = icon.tinted(with: DS.textMuted)
            let size = tinted.size
            tinted.draw(
                in: NSRect(
                    x: bounds.width - 7 - size.width, y: (bounds.height - size.height) / 2,
                    width: size.width, height: size.height))
        } else {
            let fallbackAttributes: [NSAttributedString.Key: Any] = [
                .font: DS.sans(10), .foregroundColor: DS.textMuted,
            ]
            let size = "↕".size(withAttributes: fallbackAttributes)
            "↕".draw(
                at: NSPoint(
                    x: bounds.width - 7 - size.width, y: (bounds.height - size.height) / 2),
                withAttributes: fallbackAttributes)
        }
    }
}

// MARK: - OptionCheckboxControl

/// Custom 13×13 checkbox with its label to the right; the whole control is
/// the click target. Checked wears the selection fill, accent border, and an
/// accent checkmark.
final class OptionCheckboxControl: NSView, OptionControl {
    private let label: String
    private let read: () -> Bool
    private let write: (Bool) -> Void
    private let enabled: () -> Bool
    private let onEdit: () -> Void
    private var isActive = true

    private static let boxSize: CGFloat = 13

    init(
        label: String, read: @escaping () -> Bool, write: @escaping (Bool) -> Void,
        enabled: @escaping () -> Bool, onEdit: @escaping () -> Void
    ) {
        self.label = label
        self.read = read
        self.write = write
        self.enabled = enabled
        self.onEdit = onEdit
        super.init(frame: .zero)
        wantsLayer = true
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("OptionCheckboxControl does not support NSCoder")
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        let textWidth = ceil(label.size(withAttributes: [.font: DS.sans(11)]).width)
        return NSSize(width: Self.boxSize + 6 + textWidth, height: DS.controlHeight)
    }

    func refresh() {
        isActive = enabled()
        alphaValue = isActive ? 1 : 0.42
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard isActive else { return }
        write(!read())
        onEdit()
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = NSRect(
            x: 0, y: (bounds.height - Self.boxSize) / 2,
            width: Self.boxSize, height: Self.boxSize)
        let path = NSBezierPath(
            roundedRect: box.insetBy(dx: 0.5, dy: 0.5),
            xRadius: DS.controlRadius, yRadius: DS.controlRadius)
        if read() {
            DS.selectionFill.setFill()
            path.fill()
            DS.accent.setStroke()
            path.stroke()
            drawCheckmark(in: box)
        } else {
            NSColor.controlBackgroundColor.setFill()
            path.fill()
            DS.border.setStroke()
            path.stroke()
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: DS.sans(11), .foregroundColor: DS.textMuted,
        ]
        let size = label.size(withAttributes: attributes)
        label.draw(
            at: NSPoint(x: box.maxX + 6, y: (bounds.height - size.height) / 2),
            withAttributes: attributes)
    }

    private func drawCheckmark(in box: NSRect) {
        if let icon = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Checked")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold))
        {
            let tinted = icon.tinted(with: DS.accent)
            let size = tinted.size
            tinted.draw(
                in: NSRect(
                    x: box.midX - size.width / 2, y: box.midY - size.height / 2,
                    width: size.width, height: size.height))
            return
        }
        // Flipped coordinates: the check's low vertex has the larger y.
        let path = NSBezierPath()
        path.lineWidth = 1.5
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: NSPoint(x: box.minX + 3, y: box.minY + 6.5))
        path.line(to: NSPoint(x: box.minX + 5.5, y: box.minY + 9))
        path.line(to: NSPoint(x: box.maxX - 3, y: box.minY + 4))
        DS.accent.setStroke()
        path.stroke()
    }
}

// MARK: - OptionSegmentedControl

/// Custom segmented control of 26×22 cells sharing 1px borders inside a
/// 3pt-radius silhouette. The selected cell takes the selection fill, an
/// accent border, and an accent-tinted symbol; per-segment enablement dims
/// individual cells.
final class OptionSegmentedControl: NSView, OptionControl, NSViewToolTipOwner {
    private let segments: [(symbol: String, fallback: String, tooltip: String)]
    private let read: () -> Int
    private let write: (Int) -> Void
    private let segmentEnabled: ((Int) -> Bool)?
    private let enabled: () -> Bool
    private let onEdit: () -> Void
    private var isActive = true
    private var hovered: Int?

    private static let cellWidth: CGFloat = 26

    init(
        segments: [(symbol: String, fallback: String, tooltip: String)],
        read: @escaping () -> Int, write: @escaping (Int) -> Void,
        segmentEnabled: ((Int) -> Bool)?, enabled: @escaping () -> Bool,
        onEdit: @escaping () -> Void
    ) {
        self.segments = segments
        self.read = read
        self.write = write
        self.segmentEnabled = segmentEnabled
        self.enabled = enabled
        self.onEdit = onEdit
        super.init(frame: .zero)
        wantsLayer = true
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("OptionSegmentedControl does not support NSCoder")
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: CGFloat(segments.count) * Self.cellWidth, height: DS.controlHeight)
    }

    private func cellRect(_ index: Int) -> NSRect {
        NSRect(
            x: CGFloat(index) * Self.cellWidth, y: 0,
            width: Self.cellWidth, height: bounds.height)
    }

    private func cellIsEnabled(_ index: Int) -> Bool {
        segmentEnabled?(index) ?? true
    }

    func refresh() {
        isActive = enabled()
        alphaValue = isActive ? 1 : 0.42
        needsDisplay = true
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow],
                owner: self, userInfo: nil))
        removeAllToolTips()
        for index in segments.indices {
            addToolTip(cellRect(index), owner: self, userData: nil)
        }
    }

    func view(
        _ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
        userData data: UnsafeMutableRawPointer?
    ) -> String {
        let index = Int(point.x / Self.cellWidth)
        return segments.indices.contains(index) ? segments[index].tooltip : ""
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = Int(point.x / Self.cellWidth)
        let next = segments.indices.contains(index) ? index : nil
        if next != hovered {
            hovered = next
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard isActive else { return }
        let point = convert(event.locationInWindow, from: nil)
        let index = Int(point.x / Self.cellWidth)
        guard segments.indices.contains(index), cellIsEnabled(index) else { return }
        write(index)
        onEdit()
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let silhouette = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: DS.controlRadius, yRadius: DS.controlRadius)
        NSColor.controlBackgroundColor.setFill()
        silhouette.fill()

        let selected = read()
        NSGraphicsContext.current?.saveGraphicsState()
        NSBezierPath(roundedRect: bounds, xRadius: DS.controlRadius, yRadius: DS.controlRadius)
            .addClip()
        for index in segments.indices {
            let rect = cellRect(index)
            if index == selected {
                DS.selectionFill.setFill()
                rect.fill()
            } else if hovered == index && isActive && cellIsEnabled(index) {
                DS.hoverFill.setFill()
                rect.fill()
            }
        }
        for index in 1..<max(1, segments.count) {
            DS.border.setFill()
            NSRect(x: cellRect(index).minX, y: 0, width: 1, height: bounds.height).fill()
        }
        // The accent border strokes the raw cell rect; the clip squares it
        // off to the rounded silhouette on the end cells.
        if segments.indices.contains(selected) {
            DS.accent.setStroke()
            NSBezierPath(rect: cellRect(selected).insetBy(dx: 0.5, dy: 0.5)).stroke()
        }
        NSGraphicsContext.current?.restoreGraphicsState()

        DS.border.setStroke()
        silhouette.stroke()

        for index in segments.indices {
            drawSymbol(index, selected: index == selected)
        }
    }

    private func drawSymbol(_ index: Int, selected: Bool) {
        let rect = cellRect(index)
        var tint = selected ? DS.accent : DS.textMuted
        if !cellIsEnabled(index) { tint = tint.withAlphaComponent(0.42) }
        let segment = segments[index]
        if let icon = NSImage(
            systemSymbolName: segment.symbol, accessibilityDescription: segment.tooltip)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .medium))
        {
            let tinted = icon.tinted(with: tint)
            let size = tinted.size
            tinted.draw(
                in: NSRect(
                    x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                    width: size.width, height: size.height))
            return
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: DS.sans(12, weight: .medium), .foregroundColor: tint,
        ]
        let size = segment.fallback.size(withAttributes: attributes)
        segment.fallback.draw(
            at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
            withAttributes: attributes)
    }
}

// MARK: - OptionSwatchControl

/// The shared color panel keeps a bare target reference, so the panel aims
/// at this stable relay and the relay holds the most recently clicked swatch
/// weakly — a rebuilt bar can never leave the panel pointing at a freed
/// control, and only one swatch is bound at a time.
private final class SwatchColorRelay: NSObject {
    static let shared = SwatchColorRelay()
    weak var swatch: OptionSwatchControl?

    @objc func colorChanged(_ sender: Any?) {
        swatch?.colorPanelDidPick(NSColorPanel.shared.color)
    }
}

/// 22×22 color swatch over a tiny checkerboard so alpha reads; clicking
/// binds the shared NSColorPanel to this swatch's descriptor closures.
final class OptionSwatchControl: NSView, OptionControl {
    private let read: () -> NSColor
    private let write: (NSColor) -> Void
    private let enabled: () -> Bool
    private let onEdit: () -> Void
    private var isActive = true

    init(
        read: @escaping () -> NSColor, write: @escaping (NSColor) -> Void,
        enabled: @escaping () -> Bool, onEdit: @escaping () -> Void
    ) {
        self.read = read
        self.write = write
        self.enabled = enabled
        self.onEdit = onEdit
        super.init(frame: .zero)
        wantsLayer = true
        toolTip = "Color"
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("OptionSwatchControl does not support NSCoder")
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: DS.controlHeight, height: DS.controlHeight)
    }

    func refresh() {
        isActive = enabled()
        alphaValue = isActive ? 1 : 0.42
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard isActive else { return }
        let panel = NSColorPanel.shared
        panel.showsAlpha = true
        panel.isContinuous = true
        panel.color = read()
        SwatchColorRelay.shared.swatch = self
        panel.setTarget(SwatchColorRelay.shared)
        panel.setAction(#selector(SwatchColorRelay.colorChanged(_:)))
        panel.makeKeyAndOrderFront(nil)
    }

    fileprivate func colorPanelDidPick(_ color: NSColor) {
        write(color)
        onEdit()
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: DS.controlRadius, yRadius: DS.controlRadius)
        NSGraphicsContext.current?.saveGraphicsState()
        path.addClip()
        DS.checkerA.setFill()
        bounds.fill()
        DS.checkerB.setFill()
        let half = bounds.width / 2
        NSRect(x: half, y: 0, width: half, height: half).fill()
        NSRect(x: 0, y: half, width: half, height: half).fill()
        read().setFill()
        bounds.fill()
        NSGraphicsContext.current?.restoreGraphicsState()
        DS.borderStrong.setStroke()
        path.stroke()
    }
}

// MARK: - OptionButtonControl

/// Bordered 22pt text button ("Fit", "100%"): field-style border, hover
/// fill, and the descriptor's action on click.
final class OptionButtonControl: NSView, OptionControl {
    private let title: String
    private let action: () -> Void
    private let enabled: () -> Bool
    private let onEdit: () -> Void
    private var isActive = true
    private var hovered = false

    init(
        title: String, action: @escaping () -> Void,
        enabled: @escaping () -> Bool, onEdit: @escaping () -> Void
    ) {
        self.title = title
        self.action = action
        self.enabled = enabled
        self.onEdit = onEdit
        super.init(frame: .zero)
        wantsLayer = true
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("OptionButtonControl does not support NSCoder")
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        let textWidth = ceil(title.size(withAttributes: [.font: DS.sans(11)]).width)
        return NSSize(width: textWidth + 18, height: DS.controlHeight)
    }

    func refresh() {
        isActive = enabled()
        alphaValue = isActive ? 1 : 0.42
        needsDisplay = true
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

    override func mouseDown(with event: NSEvent) {
        guard isActive else { return }
        action()
        onEdit()
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: DS.controlRadius, yRadius: DS.controlRadius)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        if hovered && isActive {
            DS.hoverFill.setFill()
            path.fill()
        }
        DS.border.setStroke()
        path.stroke()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: DS.sans(11), .foregroundColor: DS.textStrong,
        ]
        let size = title.size(withAttributes: attributes)
        title.draw(
            at: NSPoint(
                x: bounds.midX - size.width / 2, y: (bounds.height - size.height) / 2),
            withAttributes: attributes)
    }
}

// MARK: - OptionGradientStrip

/// Passive 36×12 two-color gradient preview, vertically centered in the
/// control height.
final class OptionGradientStrip: NSView, OptionControl {
    private let read: () -> (start: NSColor, end: NSColor)
    private let enabled: () -> Bool

    init(
        read: @escaping () -> (start: NSColor, end: NSColor),
        enabled: @escaping () -> Bool
    ) {
        self.read = read
        self.enabled = enabled
        super.init(frame: .zero)
        wantsLayer = true
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("OptionGradientStrip does not support NSCoder")
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 36, height: DS.controlHeight)
    }

    func refresh() {
        alphaValue = enabled() ? 1 : 0.42
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let strip = NSRect(x: 0, y: (bounds.height - 12) / 2, width: bounds.width, height: 12)
        let colors = read()
        if let gradient = NSGradient(starting: colors.start, ending: colors.end) {
            gradient.draw(in: strip, angle: 0)
        } else {
            colors.start.setFill()
            strip.fill()
        }
        DS.borderStrong.setStroke()
        NSBezierPath(rect: strip.insetBy(dx: 0.5, dy: 0.5)).stroke()
    }
}

// MARK: - MoreButton

/// The options bar's trailing "More …" button: always present, opens the
/// overflow popover (an empty-state popover when nothing overflows).
final class MoreButton: NSView {
    var onPress: (() -> Void)?
    private var hovered = false
    private let textWidth: CGFloat
    private let iconWidth: CGFloat

    private static func iconImage() -> NSImage? {
        NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "More")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .medium))
    }

    init() {
        textWidth = ceil("More".size(withAttributes: [.font: DS.sans(11)]).width)
        if let icon = Self.iconImage() {
            iconWidth = ceil(icon.size.width)
        } else {
            iconWidth = ceil("…".size(withAttributes: [.font: DS.sans(11)]).width)
        }
        super.init(frame: .zero)
        wantsLayer = true
        toolTip = "More options"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MoreButton does not support NSCoder")
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 9 + textWidth + 5 + iconWidth + 9, height: 24)
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

    override func mouseDown(with event: NSEvent) {
        onPress?()
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        if hovered {
            DS.hoverFill.setFill()
            path.fill()
        }
        DS.border.setStroke()
        path.stroke()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: DS.sans(11), .foregroundColor: DS.textMuted,
        ]
        let size = "More".size(withAttributes: attributes)
        "More".draw(
            at: NSPoint(x: 9, y: (bounds.height - size.height) / 2), withAttributes: attributes)

        let iconX = 9 + textWidth + 5
        if let icon = Self.iconImage() {
            let tinted = icon.tinted(with: DS.textMuted)
            let iconSize = tinted.size
            tinted.draw(
                in: NSRect(
                    x: iconX, y: (bounds.height - iconSize.height) / 2,
                    width: iconSize.width, height: iconSize.height))
        } else {
            let fallbackSize = "…".size(withAttributes: attributes)
            "…".draw(
                at: NSPoint(x: iconX, y: (bounds.height - fallbackSize.height) / 2),
                withAttributes: attributes)
        }
    }
}
