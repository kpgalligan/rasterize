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

// MARK: - ToolPillControl

/// The toolbar's pill-shaped tool group: five icon-over-label segments in a
/// single bordered pill with the sticker shadow. The selected segment takes
/// an accent-tinted fill with accent text; no border change on selection.
final class ToolPillControl: NSView {
    struct Segment {
        let symbol: String
        let fallback: String
        let label: String
        let action: Selector
    }

    private let segments: [Segment]
    private(set) var selectedIndex = 0
    private var hoveredIndex: Int?

    private let segmentWidth: CGFloat = 56
    private let pillHeight: CGFloat = 46

    init(segments: [Segment]) {
        self.segments = segments
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ToolPillControl does not support NSCoder")
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: segmentWidth * CGFloat(segments.count) + 3, height: pillHeight + 3)
    }

    func setSelectedIndex(_ index: Int) {
        guard index != selectedIndex, segments.indices.contains(index) else { return }
        selectedIndex = index
        needsDisplay = true
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

    override func mouseMoved(with event: NSEvent) {
        let index = segmentIndex(at: convert(event.locationInWindow, from: nil))
        if index != hoveredIndex {
            hoveredIndex = index
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hoveredIndex = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard alphaValue > 0.5,
              let index = segmentIndex(at: convert(event.locationInWindow, from: nil))
        else { return }
        NSApp.sendAction(segments[index].action, to: nil, from: self)
    }

    private var pillRect: NSRect {
        NSRect(x: 0, y: 0, width: segmentWidth * CGFloat(segments.count), height: pillHeight)
    }

    private func segmentIndex(at point: NSPoint) -> Int? {
        guard pillRect.contains(point) else { return nil }
        let index = Int((point.x - pillRect.minX) / segmentWidth)
        return segments.indices.contains(index) ? index : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let pill = pillRect
        let radius = pill.height / 2

        let shadow = NSBezierPath(
            roundedRect: pill.offsetBy(dx: 2, dy: 2), xRadius: radius, yRadius: radius)
        DS.stickerShadow.setFill()
        shadow.fill()

        let path = NSBezierPath(roundedRect: pill, xRadius: radius, yRadius: radius)
        DS.chromeBackground.setFill()
        path.fill()

        NSGraphicsContext.current?.saveGraphicsState()
        path.addClip()
        for (index, segment) in segments.enumerated() {
            let rect = NSRect(
                x: pill.minX + CGFloat(index) * segmentWidth, y: pill.minY,
                width: segmentWidth, height: pill.height)
            let selected = index == selectedIndex
            if selected {
                DS.selectionFill.setFill()
                rect.fill()
            } else if index == hoveredIndex {
                DS.hoverFill.setFill()
                rect.fill()
            }
            if index > 0 {
                DS.border.setFill()
                NSRect(x: rect.minX, y: rect.minY, width: 1, height: rect.height).fill()
            }

            let tint = selected ? DS.accent : DS.textMuted
            if let icon = NSImage(
                systemSymbolName: segment.symbol, accessibilityDescription: segment.label)?
                .withSymbolConfiguration(
                    NSImage.SymbolConfiguration(pointSize: 15, weight: .medium))
            {
                let tinted = icon.tinted(with: tint)
                let size = tinted.size
                tinted.draw(
                    in: NSRect(
                        x: rect.midX - size.width / 2, y: rect.minY + 6,
                        width: size.width, height: size.height))
            }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: DS.sans(10, weight: selected ? .semibold : .regular),
                .foregroundColor: tint,
            ]
            let textSize = segment.label.size(withAttributes: attributes)
            segment.label.draw(
                at: NSPoint(
                    x: rect.midX - textSize.width / 2,
                    y: rect.maxY - textSize.height - 4),
                withAttributes: attributes)
        }
        NSGraphicsContext.current?.restoreGraphicsState()

        path.lineWidth = 1.5
        DS.borderStrong.setStroke()
        path.stroke()
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
