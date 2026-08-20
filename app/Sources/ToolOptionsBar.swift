import AppKit

// MARK: - Descriptor model

/// One option control: how it renders and where its value lives. Bindings
/// are closures so the bar stays declarative — a control never stores a
/// value, it reads through `get` and writes through `set`.
enum OptionControlKind {
    /// Numeric field, mono 11: displays "<value><unit>" at rest ("24 px",
    /// "0.0°", "100%") and the bare number while editing. `decimals` is the
    /// display precision; the value is clamped to [min, max] on commit.
    case field(width: CGFloat, unit: String, decimals: Int, min: Double, max: Double,
               get: () -> Double, set: (Double) -> Void)
    /// Read-only mono text (the eyedropper's hex readout).
    case display(width: CGFloat, get: () -> String)
    /// Popup: mono 11 value plus a 13pt chevron.up.chevron.down in
    /// textMuted; click pops an NSMenu of `items`.
    case popup(width: CGFloat, items: [String], get: () -> Int, set: (Int) -> Void)
    /// 13×13pt checkbox with an 11pt sans label to its right.
    case checkbox(label: String, get: () -> Bool, set: (Bool) -> Void)
    /// Segmented control of 26×22pt cells with shared borders; 3pt outer
    /// radius on the end cells only. `segmentEnabled` nil = all enabled.
    case segmented(segments: [(symbol: String, fallback: String, tooltip: String)],
                   get: () -> Int, set: (Int) -> Void, segmentEnabled: ((Int) -> Bool)?)
    /// 22×22pt color swatch, 3pt radius, 1pt borderStrong border; click
    /// opens the shared NSColorPanel bound to this binding.
    case swatch(get: () -> NSColor, set: (NSColor) -> Void)
    /// Bordered 22pt-tall text button ("Fit", "100%"), 11pt sans title,
    /// horizontal padding 9.
    case button(title: String, action: () -> Void)
    /// Passive 36×12pt two-color linear gradient strip (the gradient
    /// preview), 1pt borderStrong border.
    case gradientPreview(get: () -> (start: NSColor, end: NSColor))
}

struct OptionDescriptor {
    let id: String
    /// Mono 10 uppercase micro-label drawn 6pt before the control
    /// (DS.microLabel); nil for none. Checkboxes carry their own label.
    let microLabel: String?
    /// The label its overflow-popover row uses ("Feather").
    let overflowLabel: String
    let kind: OptionControlKind
    /// Re-evaluated on every refresh; a disabled control dims to 42% and
    /// ignores input.
    let isEnabled: () -> Bool

    init(id: String, microLabel: String? = nil, overflowLabel: String,
         kind: OptionControlKind, isEnabled: @escaping () -> Bool = { true }) {
        self.id = id
        self.microLabel = microLabel
        self.overflowLabel = overflowLabel
        self.kind = kind
        self.isEnabled = isEnabled
    }
}

/// Descriptors laid out as one unit (6pt gaps inside); clusters separate by
/// 12pt and move to the overflow popover atomically.
struct OptionCluster {
    let descriptors: [OptionDescriptor]
    init(_ descriptors: [OptionDescriptor]) {
        self.descriptors = descriptors
    }
}

// MARK: - Overflow popover content

/// The overflow popover's flipped content canvas.
private final class OverflowContentView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("OverflowContentView does not support NSCoder")
    }

    override var isFlipped: Bool { true }
}

// MARK: - ToolOptionsBar

/// The fixed-height options bar under the title bar: an identity block for
/// the active tool, then the tool's option clusters laid left to right, and
/// everything that does not fit folded into the trailing More popover. The
/// bar is declarative — the editor presents descriptors, controls read and
/// write through their closures, and the bar itself never owns a value.
final class ToolOptionsBar: NSView, NSPopoverDelegate {
    /// A cluster's built views: the descriptors it came from, the live
    /// (micro-label, control) pairs in bar order, and the natural width the
    /// overflow pass measures against.
    private struct LiveCluster {
        let descriptors: [OptionDescriptor]
        let units: [(label: NSTextField?, control: OptionControl)]
        let width: CGFloat
    }

    /// Called after any control commits a value (the editor persists the
    /// tool's options through this).
    var onAnyEdit: (() -> Void)?

    private let moreButton = MoreButton()
    private var identityViews: [NSView] = []
    private var currentTitle = ""
    private var dividerX: CGFloat = 132
    private var liveClusters: [LiveCluster] = []
    private var overflowDescriptors: [OptionDescriptor] = []
    private var popover: NSPopover?
    private var popoverControls: [OptionControl] = []

    init() {
        super.init(frame: .zero)
        clipsToBounds = true
        addSubview(moreButton)
        moreButton.onPress = { [weak self] in self?.showOverflow() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ToolOptionsBar does not support NSCoder")
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: DS.optionsBarHeight)
    }

    // MARK: Public surface

    /// Rebuilds the bar for a tool (or a modal session like Free Transform).
    /// Options swap instantly — no animation.
    func present(icon: String, fallback: String, title: String, clusters: [OptionCluster]) {
        closeOverflow()
        currentTitle = title

        identityViews.forEach { $0.removeFromSuperview() }
        for cluster in liveClusters {
            for unit in cluster.units {
                unit.label?.removeFromSuperview()
                unit.control.removeFromSuperview()
            }
        }
        liveClusters = []
        overflowDescriptors = []

        let iconView: NSView
        if let image = NSImage(systemSymbolName: icon, accessibilityDescription: title)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 17, weight: .medium))
        {
            let imageView = NSImageView(image: image)
            imageView.contentTintColor = DS.accent
            iconView = imageView
        } else {
            let glyph = NSTextField(labelWithString: fallback)
            glyph.font = DS.sans(13, weight: .semibold)
            glyph.textColor = DS.accent
            iconView = glyph
        }
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = DS.sans(12, weight: .semibold)
        titleLabel.textColor = DS.textStrong
        addSubview(iconView)
        addSubview(titleLabel)
        identityViews = [iconView, titleLabel]

        for cluster in clusters {
            var units: [(label: NSTextField?, control: OptionControl)] = []
            var width: CGFloat = 0
            for (index, descriptor) in cluster.descriptors.enumerated() {
                if index > 0 { width += 6 }
                var microLabel: NSTextField?
                if let text = descriptor.microLabel {
                    let label = NSTextField(labelWithAttributedString: DS.microLabel(text))
                    addSubview(label)
                    microLabel = label
                    width += Self.microLabelWidth(label) + 6
                }
                let control = makeControl(for: descriptor)
                addSubview(control)
                width += control.intrinsicContentSize.width
                units.append((label: microLabel, control: control))
            }
            liveClusters.append(
                LiveCluster(descriptors: cluster.descriptors, units: units, width: width))
        }

        needsLayout = true
        needsDisplay = true
    }

    /// Re-reads every descriptor's value and enabled state into its control
    /// (options changed elsewhere: eyedropper sample, bracket keys, undo).
    func refreshValues() {
        for cluster in liveClusters {
            for unit in cluster.units {
                unit.control.refresh()
            }
        }
        popoverControls.forEach { $0.refresh() }
    }

    /// Closes the overflow popover if open (tool change, window resign).
    func closeOverflow() {
        popover?.close()
        popover = nil
        popoverControls = []
    }

    // MARK: Control building

    private func makeControl(for descriptor: OptionDescriptor) -> OptionControl {
        let onEdit: () -> Void = { [weak self] in self?.controlDidEdit() }
        let enabled = descriptor.isEnabled
        switch descriptor.kind {
        case let .field(width, unit, decimals, min, max, get, set):
            return OptionFieldControl(
                width: width, unit: unit, decimals: decimals, min: min, max: max,
                read: get, write: set, enabled: enabled, onEdit: onEdit)
        case let .display(width, get):
            return OptionDisplayControl(width: width, read: get, enabled: enabled)
        case let .popup(width, items, get, set):
            return OptionPopupControl(
                width: width, items: items, read: get, write: set,
                enabled: enabled, onEdit: onEdit)
        case let .checkbox(label, get, set):
            return OptionCheckboxControl(
                label: label, read: get, write: set, enabled: enabled, onEdit: onEdit)
        case let .segmented(segments, get, set, segmentEnabled):
            return OptionSegmentedControl(
                segments: segments, read: get, write: set,
                segmentEnabled: segmentEnabled, enabled: enabled, onEdit: onEdit)
        case let .swatch(get, set):
            return OptionSwatchControl(read: get, write: set, enabled: enabled, onEdit: onEdit)
        case let .button(title, action):
            return OptionButtonControl(
                title: title, action: action, enabled: enabled, onEdit: onEdit)
        case let .gradientPreview(get):
            return OptionGradientStrip(read: get, enabled: enabled)
        }
    }

    private func controlDidEdit() {
        refreshValues()
        onAnyEdit?()
    }

    /// A micro-label's real width: NSTextField's intrinsic width comes up
    /// short of the attributed string's tracking (the kern rides every
    /// glyph, the trailing one included), and the label cell insets the
    /// text ~2px per side — both together clip the last character. Measure
    /// the string itself and leave room for the insets and trailing kern.
    private static func microLabelWidth(_ label: NSTextField) -> CGFloat {
        ceil(label.attributedStringValue.size().width) + 6
    }

    /// A popover row already carries the descriptor's label on its left, so
    /// a checkbox there drops its own to avoid saying everything twice.
    private func makeOverflowControl(for descriptor: OptionDescriptor) -> OptionControl {
        guard case let .checkbox(_, get, set) = descriptor.kind else {
            return makeControl(for: descriptor)
        }
        return OptionCheckboxControl(
            label: "", read: get, write: set, enabled: descriptor.isEnabled,
            onEdit: { [weak self] in self?.controlDidEdit() })
    }

    // MARK: Layout and overflow

    override func layout() {
        super.layout()
        let moreSize = moreButton.intrinsicContentSize
        moreButton.frame = NSRect(
            x: bounds.width - 10 - moreSize.width,
            y: floor((bounds.height - moreSize.height) / 2),
            width: moreSize.width, height: moreSize.height)

        if identityViews.count == 2 {
            let icon = identityViews[0]
            let title = identityViews[1]
            let iconSize = icon.intrinsicContentSize
            icon.frame = NSRect(
                x: 10, y: floor((bounds.height - iconSize.height) / 2),
                width: iconSize.width, height: iconSize.height)
            let titleSize = title.intrinsicContentSize
            title.frame = NSRect(
                x: icon.frame.maxX + 7, y: floor((bounds.height - titleSize.height) / 2),
                width: ceil(titleSize.width), height: ceil(titleSize.height))
            dividerX = max(132, title.frame.maxX + 12)
        }

        var cursor = dividerX + 1 + 12
        let limit = moreButton.frame.minX - 12
        var overflowing = false
        var pending: [OptionDescriptor] = []
        for cluster in liveClusters {
            // The first cluster that would cross the More button takes every
            // later cluster with it — clusters never wrap or reorder.
            if !overflowing && cursor + cluster.width > limit { overflowing = true }
            if overflowing {
                for unit in cluster.units {
                    unit.label?.isHidden = true
                    unit.control.isHidden = true
                }
                pending.append(contentsOf: cluster.descriptors)
                continue
            }
            for (index, unit) in cluster.units.enumerated() {
                if index > 0 { cursor += 6 }
                if let label = unit.label {
                    label.isHidden = false
                    let size = label.intrinsicContentSize
                    label.frame = NSRect(
                        x: cursor, y: floor((bounds.height - size.height) / 2),
                        width: Self.microLabelWidth(label), height: ceil(size.height))
                    cursor = label.frame.maxX + 6
                }
                unit.control.isHidden = false
                let size = unit.control.intrinsicContentSize
                unit.control.frame = NSRect(
                    x: cursor, y: 7, width: size.width, height: size.height)
                cursor = unit.control.frame.maxX
            }
            cursor += 12
        }

        let changed = pending.map(\.id) != overflowDescriptors.map(\.id)
        overflowDescriptors = pending
        if changed, let popover = popover, popover.isShown { closeOverflow() }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        DS.chromeBackground.setFill()
        bounds.fill()
        DS.border.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        if !identityViews.isEmpty {
            NSRect(x: dividerX, y: (bounds.height - 18) / 2, width: 1, height: 18).fill()
        }
    }

    // MARK: Overflow popover

    private func showOverflow() {
        closeOverflow()
        let width = DS.popoverWidth
        let content = OverflowContentView(frame: NSRect(x: 0, y: 0, width: width, height: 0))

        let title = NSTextField(
            labelWithAttributedString: DS.microLabel("\(currentTitle) overflow"))
        let titleSize = title.intrinsicContentSize
        title.frame = NSRect(
            x: 10, y: 10, width: ceil(titleSize.width), height: ceil(titleSize.height))
        content.addSubview(title)
        var y = title.frame.maxY + 9

        if overflowDescriptors.isEmpty {
            let empty = NSTextField(labelWithString: "No further options")
            empty.font = DS.sans(12)
            empty.textColor = DS.textFaint
            let size = empty.intrinsicContentSize
            empty.frame = NSRect(
                x: 10, y: y, width: ceil(size.width), height: ceil(size.height))
            content.addSubview(empty)
            y = empty.frame.maxY
        } else {
            var controls: [OptionControl] = []
            for descriptor in overflowDescriptors {
                let control = makeOverflowControl(for: descriptor)
                let size = control.intrinsicContentSize
                let rowHeight = max(DS.controlHeight, size.height)
                control.frame = NSRect(
                    x: width - 10 - size.width, y: y + floor((rowHeight - size.height) / 2),
                    width: size.width, height: size.height)
                content.addSubview(control)
                controls.append(control)

                let label = NSTextField(labelWithString: descriptor.overflowLabel)
                label.font = DS.sans(12)
                label.textColor = DS.textMuted
                label.lineBreakMode = .byTruncatingTail
                let labelSize = label.intrinsicContentSize
                let available = max(0, control.frame.minX - 10 - 8)
                label.frame = NSRect(
                    x: 10, y: y + floor((rowHeight - labelSize.height) / 2),
                    width: min(ceil(labelSize.width), available),
                    height: ceil(labelSize.height))
                content.addSubview(label)
                y += rowHeight + 9
            }
            y -= 9
            popoverControls = controls
        }

        let height = y + 10
        content.frame = NSRect(x: 0, y: 0, width: width, height: height)

        let controller = NSViewController()
        controller.view = content
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.contentSize = NSSize(width: width, height: height)
        popover.delegate = self
        self.popover = popover
        popover.show(relativeTo: moreButton.bounds, of: moreButton, preferredEdge: .maxY)
    }

    func popoverDidClose(_ notification: Notification) {
        popover = nil
        popoverControls = []
    }
}
