import AppKit

/// The toolbar's pill-shaped tool group: one icon-over-label segment per
/// entry in `EditorTool.toolbarGroups`, in a single bordered pill with the
/// sticker shadow. The selected segment takes an accent-tinted fill with
/// accent text; no border change on selection.
///
/// A segment standing for more than one tool (the four selection tools;
/// brush and eraser) draws whichever member is current and grows a chevron
/// zone on its right edge: clicking the icon picks that member, clicking the
/// chevron drops a menu of all of them. Each group remembers the member last
/// selected, so it returns to the tool the user actually works with — and
/// the toolbar keeps its width as tools are added to a group.
///
/// Both the segments and the dropdown items dispatch their tool's action up
/// the responder chain (nil target), exactly like the Tools menu, so the
/// editor's own validation enables the items and checks the active tool.
final class ToolPillControl: NSView {
    /// A hit zone: which segment the pointer is over, and whether it is on
    /// that segment's chevron rather than its icon.
    private struct Zone: Equatable {
        let group: Int
        let chevron: Bool
    }

    /// Left-to-right buttons; every EditorTool appears in exactly one.
    private let groups: [[EditorTool]]
    /// Per group, the member its segment currently stands for.
    private var currentMember: [EditorTool]
    private(set) var selectedTool: EditorTool
    private var hovered: Zone?

    private let mainWidth: CGFloat = 46
    private let chevronWidth: CGFloat = 15
    private let pillHeight: CGFloat = 46

    init(groups: [[EditorTool]]) {
        assert(!groups.contains { $0.isEmpty }, "a toolbar group needs at least one tool")
        assert(
            groups.flatMap { $0 }.count == EditorTool.allCases.count
                && Set(groups.flatMap { $0 }) == Set(EditorTool.allCases),
            "the toolbar groups must list every EditorTool exactly once")
        self.groups = groups
        self.currentMember = groups.map { $0.first ?? .select }
        self.selectedTool = groups.first?.first ?? .select
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ToolPillControl does not support NSCoder")
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: pillRect.width + 3, height: pillHeight + 3)
    }

    /// Mirrors the editor's tool into the pill: the tool's group becomes the
    /// selected segment and starts standing for that tool. Display only —
    /// nothing here re-dispatches an action.
    func setSelectedTool(_ tool: EditorTool) {
        guard tool != selectedTool else { return }
        selectedTool = tool
        let group = tool.toolbarGroupIndex
        if groups.indices.contains(group) {
            currentMember[group] = tool
        }
        needsDisplay = true
    }

    // MARK: - Geometry

    private func width(ofGroup index: Int) -> CGFloat {
        mainWidth + (groups[index].count > 1 ? chevronWidth : 0)
    }

    private var pillRect: NSRect {
        let total = groups.indices.reduce(CGFloat(0)) { $0 + width(ofGroup: $1) }
        return NSRect(x: 0, y: 0, width: total, height: pillHeight)
    }

    private func segmentRect(_ index: Int) -> NSRect {
        var x: CGFloat = 0
        for earlier in 0..<index { x += width(ofGroup: earlier) }
        return NSRect(x: x, y: 0, width: width(ofGroup: index), height: pillHeight)
    }

    /// The chevron's own rect — the right edge of a grouped segment, empty
    /// for a segment standing for a single tool.
    private func chevronRect(_ index: Int) -> NSRect {
        let rect = segmentRect(index)
        guard groups[index].count > 1 else { return .zero }
        return NSRect(
            x: rect.maxX - chevronWidth, y: rect.minY, width: chevronWidth, height: rect.height)
    }

    private func zone(at point: NSPoint) -> Zone? {
        guard pillRect.contains(point) else { return nil }
        for index in groups.indices where segmentRect(index).contains(point) {
            return Zone(group: index, chevron: chevronRect(index).contains(point))
        }
        return nil
    }

    // MARK: - Mouse

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
        setHovered(zone(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(nil)
    }

    private func setHovered(_ zone: Zone?) {
        guard zone != hovered else { return }
        hovered = zone
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard alphaValue > 0.5,
              let zone = zone(at: convert(event.locationInWindow, from: nil))
        else { return }
        if zone.chevron {
            showGroupMenu(zone.group)
            return
        }
        NSApp.sendAction(currentMember[zone.group].action, to: nil, from: self)
    }

    /// A grouped segment's dropdown. The bare tool keys ride along as key
    /// equivalents with an EMPTY modifier mask (the default would draw — and
    /// match — ⌘M); a popped-up menu is transient, so unlike a main-menu
    /// equivalent this can never steal a keystroke from text editing.
    private func showGroupMenu(_ index: Int) {
        // The pointer is about to leave for the menu, so drop the hover
        // rather than leaving the chevron lit behind it.
        setHovered(nil)
        let menu = NSMenu()
        for tool in groups[index] {
            let item = NSMenuItem(
                title: tool.displayName, action: tool.action, keyEquivalent: tool.keyCharacter)
            item.keyEquivalentModifierMask = []
            item.image = NSImage(
                systemSymbolName: tool.symbol, accessibilityDescription: tool.displayName)
            menu.addItem(item)
        }
        let rect = segmentRect(index)
        menu.popUp(positioning: nil, at: NSPoint(x: rect.minX, y: rect.maxY + 3), in: self)
    }

    // MARK: - Drawing

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
        for index in groups.indices {
            drawSegment(index)
        }
        NSGraphicsContext.current?.restoreGraphicsState()

        path.lineWidth = 1.5
        DS.borderStrong.setStroke()
        path.stroke()
    }

    private func drawSegment(_ index: Int) {
        let rect = segmentRect(index)
        let tool = currentMember[index]
        let selected = index == selectedTool.toolbarGroupIndex
        if selected {
            DS.selectionFill.setFill()
            rect.fill()
        } else if hovered?.group == index {
            DS.hoverFill.setFill()
            rect.fill()
        }
        // The chevron lights on its own, over whatever the segment already
        // has, so it reads as the second target it is.
        if hovered == Zone(group: index, chevron: true) {
            DS.hoverFill.setFill()
            chevronRect(index).fill()
        }
        if index > 0 {
            DS.border.setFill()
            NSRect(x: rect.minX, y: rect.minY, width: 1, height: rect.height).fill()
        }

        // Icon and label center on the ICON zone, not on the whole segment,
        // so a group's contents don't shift when its chevron appears.
        let tint = selected ? DS.accent : DS.textMuted
        let main = NSRect(x: rect.minX, y: rect.minY, width: mainWidth, height: rect.height)
        if let icon = NSImage(
            systemSymbolName: tool.symbol, accessibilityDescription: tool.displayName)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 15, weight: .medium))
        {
            let tinted = icon.tinted(with: tint)
            let size = tinted.size
            tinted.draw(
                in: NSRect(
                    x: main.midX - size.width / 2, y: main.minY + 6,
                    width: size.width, height: size.height))
        } else {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: DS.sans(15, weight: .medium), .foregroundColor: tint,
            ]
            let size = tool.fallbackGlyph.size(withAttributes: attributes)
            tool.fallbackGlyph.draw(
                at: NSPoint(x: main.midX - size.width / 2, y: main.minY + 6),
                withAttributes: attributes)
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: DS.sans(10, weight: selected ? .semibold : .regular),
            .foregroundColor: tint,
        ]
        let label = tool.shortLabel
        let textSize = label.size(withAttributes: attributes)
        label.draw(
            at: NSPoint(
                x: main.midX - textSize.width / 2, y: main.maxY - textSize.height - 4),
            withAttributes: attributes)

        guard groups[index].count > 1 else { return }
        drawChevron(in: chevronRect(index), tint: tint)
    }

    private func drawChevron(in rect: NSRect, tint: NSColor) {
        let color = tint.withAlphaComponent(0.75)
        if let icon = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "More")?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold))
        {
            let tinted = icon.tinted(with: color)
            let size = tinted.size
            tinted.draw(
                in: NSRect(
                    x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                    width: size.width, height: size.height))
            return
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: DS.sans(9, weight: .semibold), .foregroundColor: color,
        ]
        let size = "▾".size(withAttributes: attributes)
        "▾".draw(
            at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
            withAttributes: attributes)
    }
}
