import AppKit

/// The editor's left tool rail: one 34pt icon slot per entry in the groups
/// passed at init (`EditorTool.railGroups`), stacked top to bottom, with the
/// foreground/background color swatches pinned at the bottom.
///
/// A slot standing for more than one tool draws whichever member is current
/// plus a small solid triangle in its bottom-right corner: clicking the slot
/// picks that member, clicking the 10×10pt zone around the triangle drops a
/// menu of all of them. Each group remembers the member last selected, so it
/// returns to the tool the user actually works with — and the rail keeps its
/// height as tools are added to a group.
///
/// Both the slots and the dropdown items dispatch their tool's action up the
/// responder chain (nil target), exactly like the Tools menu, so the
/// editor's own validation enables the items and checks the active tool.
final class ToolRailView: NSView {
    /// A hit zone: which slot the pointer is over, and whether it is in
    /// that slot's triangle zone rather than on its icon.
    private struct Zone: Equatable {
        let slot: Int
        let triangle: Bool
    }

    /// Top-to-bottom slots; every EditorTool appears in exactly one.
    private let groups: [[EditorTool]]
    /// Per group, the member its slot currently stands for.
    private var currentMember: [EditorTool]
    private(set) var selectedTool: EditorTool
    private var hovered: Zone?

    var foregroundSwatchColor: NSColor = .black {
        didSet { needsDisplay = true }
    }
    var backgroundSwatchColor: NSColor = .white {
        didSet { needsDisplay = true }
    }
    var onPickForeground: (() -> Void)?
    var onPickBackground: (() -> Void)?

    private let slotGap: CGFloat = 3
    private let slotTopPadding: CGFloat = 8
    private let iconPointSize: CGFloat = 19
    private let triangleLeg: CGFloat = 5
    private let triangleInset: CGFloat = 1
    private let triangleZoneSize: CGFloat = 10
    private let swatchSize: CGFloat = 28
    private let swatchRadius: CGFloat = 4
    private let swatchLeading: CGFloat = 5
    private let swatchBottomInset: CGFloat = 10
    /// The background swatch sits this far down and right of the foreground.
    private let swatchStagger = NSSize(width: 10, height: 14)

    /// Kept alive because `addToolTip` does not retain its string owners.
    private var toolTipOwners: [NSString] = []

    init(groups: [[EditorTool]]) {
        assert(!groups.contains { $0.isEmpty }, "a rail group needs at least one tool")
        assert(
            groups.flatMap { $0 }.count == EditorTool.allCases.count
                && Set(groups.flatMap { $0 }) == Set(EditorTool.allCases),
            "the rail groups must list every EditorTool exactly once")
        self.groups = groups
        self.currentMember = groups.map { $0.first ?? .select }
        self.selectedTool = groups.first?.first ?? .select
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ToolRailView does not support NSCoder")
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: DS.railWidth, height: NSView.noIntrinsicMetric)
    }

    /// Mirrors the editor's tool into the rail: the tool's slot becomes the
    /// selected one and starts standing for that tool. Display only —
    /// nothing here re-dispatches an action.
    func setSelectedTool(_ tool: EditorTool) {
        guard tool != selectedTool else { return }
        selectedTool = tool
        if let group = groups.firstIndex(where: { $0.contains(tool) }) {
            currentMember[group] = tool
        }
        rebuildToolTips()
        needsDisplay = true
    }

    // MARK: - Geometry

    private func slotRect(_ index: Int) -> NSRect {
        NSRect(
            x: (DS.railWidth - DS.railSlot) / 2,
            y: slotTopPadding + CGFloat(index) * (DS.railSlot + slotGap),
            width: DS.railSlot, height: DS.railSlot)
    }

    /// The triangle's click zone — the bottom-right corner of a grouped
    /// slot, empty for a slot standing for a single tool.
    private func triangleZoneRect(_ index: Int) -> NSRect {
        guard groups[index].count > 1 else { return .zero }
        let slot = slotRect(index)
        return NSRect(
            x: slot.maxX - triangleZoneSize, y: slot.maxY - triangleZoneSize,
            width: triangleZoneSize, height: triangleZoneSize)
    }

    private var backgroundSwatchRect: NSRect {
        NSRect(
            x: swatchLeading + swatchStagger.width,
            y: bounds.height - swatchBottomInset - swatchSize,
            width: swatchSize, height: swatchSize)
    }

    private var foregroundSwatchRect: NSRect {
        backgroundSwatchRect.offsetBy(dx: -swatchStagger.width, dy: -swatchStagger.height)
    }

    /// False when the rail is too short for the swatches to sit clear of
    /// the slots (a small window): they then neither draw nor take clicks,
    /// rather than painting over — and stealing clicks from — the bottom
    /// slots. The color panel stays reachable through the options bar's
    /// swatches.
    private var swatchesFit: Bool {
        let lastSlotMaxY = slotTopPadding
            + CGFloat(groups.count) * (DS.railSlot + slotGap) - slotGap
        return foregroundSwatchRect.minY >= lastSlotMaxY + 8
    }

    private func zone(at point: NSPoint) -> Zone? {
        for index in groups.indices where slotRect(index).contains(point) {
            return Zone(slot: index, triangle: triangleZoneRect(index).contains(point))
        }
        return nil
    }

    // MARK: - Tooltips

    /// Slot tooltips name each slot's CURRENT member, so they are rebuilt on
    /// geometry changes and whenever selection rewrites a group's memory.
    private func rebuildToolTips() {
        removeAllToolTips()
        toolTipOwners.removeAll()
        for index in groups.indices {
            let tool = currentMember[index]
            addToolTip("\(tool.displayName) (\(tool.keyCharacter.uppercased()))",
                in: slotRect(index))
        }
        guard swatchesFit else { return }
        // Background first: the foreground swatch overlaps it on top, so it
        // should win the overlap for clicks and tips alike.
        addToolTip("Background Color", in: backgroundSwatchRect)
        addToolTip("Foreground Color", in: foregroundSwatchRect)
    }

    private func addToolTip(_ text: String, in rect: NSRect) {
        let owner = text as NSString
        toolTipOwners.append(owner)
        addToolTip(rect, owner: owner, userData: nil)
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
        rebuildToolTips()
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
        let point = convert(event.locationInWindow, from: nil)
        if swatchesFit {
            if foregroundSwatchRect.contains(point) {
                onPickForeground?()
                return
            }
            if backgroundSwatchRect.contains(point) {
                onPickBackground?()
                return
            }
        }
        guard let zone = zone(at: point) else { return }
        if zone.triangle {
            showGroupMenu(zone.slot)
            return
        }
        let member = currentMember[zone.slot]
        guard !member.planned else {
            NSSound.beep()
            return
        }
        NSApp.sendAction(member.action, to: nil, from: self)
    }

    /// A grouped slot's dropdown. The bare tool keys ride along as key
    /// equivalents with an EMPTY modifier mask (the default would draw — and
    /// match — ⌘M); a popped-up menu is transient, so unlike a main-menu
    /// equivalent this can never steal a keystroke from text editing.
    private func showGroupMenu(_ index: Int) {
        // The pointer is about to leave for the menu, so drop the hover
        // rather than leaving the slot lit behind it.
        setHovered(nil)
        let menu = NSMenu()
        menu.minimumWidth = DS.menuMinWidth
        for tool in groups[index] {
            let item = NSMenuItem(
                title: tool.displayName, action: tool.action, keyEquivalent: tool.keyCharacter)
            item.keyEquivalentModifierMask = []
            item.image = NSImage(
                systemSymbolName: tool.symbol, accessibilityDescription: tool.displayName)
            if tool.planned {
                item.attributedTitle = Self.plannedTitle(tool.displayName)
            }
            menu.addItem(item)
        }
        let slot = slotRect(index)
        menu.popUp(positioning: nil, at: NSPoint(x: bounds.maxX + 4, y: slot.minY), in: self)
    }

    /// "Name   SOON" for a tool that hasn't landed. The item stays enabled
    /// here; the editor's validation disables it through the responder chain
    /// like every other tool item.
    private static func plannedTitle(_ name: String) -> NSAttributedString {
        let title = NSMutableAttributedString(
            string: name, attributes: [.font: NSFont.menuFont(ofSize: 0)])
        title.append(
            NSAttributedString(
                string: "   SOON",
                attributes: [.font: DS.mono(9), .foregroundColor: DS.textFaint]))
        return title
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        DS.chromeBackground.setFill()
        bounds.fill()
        DS.border.setFill()
        NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill()
        for index in groups.indices {
            drawSlot(index)
        }
        // Background first so the foreground swatch overlaps it on top.
        if swatchesFit {
            drawSwatch(backgroundSwatchColor, in: backgroundSwatchRect)
            drawSwatch(foregroundSwatchColor, in: foregroundSwatchRect)
        }
    }

    private func drawSlot(_ index: Int) {
        let rect = slotRect(index)
        let tool = currentMember[index]
        let selected = groups[index].contains(selectedTool)
        var tint = DS.textMuted
        if selected {
            let path = NSBezierPath(
                roundedRect: rect, xRadius: DS.railSlotRadius, yRadius: DS.railSlotRadius)
            DS.selectionFill.setFill()
            path.fill()
            let border = NSBezierPath(
                roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                xRadius: DS.railSlotRadius, yRadius: DS.railSlotRadius)
            border.lineWidth = 1
            DS.accent.withAlphaComponent(0.6).setStroke()
            border.stroke()
            tint = DS.accent
        } else if hovered?.slot == index {
            // The triangle zone shares the slot's hover fill — the whole
            // slot lights as one; the zone only decides what a click does.
            let path = NSBezierPath(
                roundedRect: rect, xRadius: DS.railSlotRadius, yRadius: DS.railSlotRadius)
            DS.hoverFill.setFill()
            path.fill()
            tint = DS.textStrong
        }
        if tool.planned {
            tint = tint.withAlphaComponent(0.42)
        }

        if let icon = NSImage(
            systemSymbolName: tool.symbol, accessibilityDescription: tool.displayName)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: iconPointSize, weight: .regular))
        {
            let tinted = icon.tinted(with: tint)
            let size = tinted.size
            tinted.draw(
                in: NSRect(
                    x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                    width: size.width, height: size.height))
        } else {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: DS.sans(15, weight: .medium), .foregroundColor: tint,
            ]
            let size = tool.fallbackGlyph.size(withAttributes: attributes)
            tool.fallbackGlyph.draw(
                at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                withAttributes: attributes)
        }

        guard groups[index].count > 1 else { return }
        drawTriangle(in: rect)
    }

    /// The dropdown affordance: a solid right triangle tucked into the
    /// slot's bottom-right corner, hypotenuse from top-right to bottom-left.
    private func drawTriangle(in slot: NSRect) {
        let corner = NSPoint(x: slot.maxX - triangleInset, y: slot.maxY - triangleInset)
        let path = NSBezierPath()
        path.move(to: corner)
        path.line(to: NSPoint(x: corner.x, y: corner.y - triangleLeg))
        path.line(to: NSPoint(x: corner.x - triangleLeg, y: corner.y))
        path.close()
        DS.textMuted.setFill()
        path.fill()
    }

    private func drawSwatch(_ color: NSColor, in rect: NSRect) {
        let path = NSBezierPath(roundedRect: rect, xRadius: swatchRadius, yRadius: swatchRadius)
        color.setFill()
        path.fill()
        let border = NSBezierPath(
            roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
            xRadius: swatchRadius, yRadius: swatchRadius)
        border.lineWidth = 1
        DS.borderStrong.setStroke()
        border.stroke()
    }
}
