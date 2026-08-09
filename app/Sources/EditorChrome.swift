import AppKit

// MARK: - BarView

/// A chrome bar: card surface with an optional 1px subtle border on the
/// top or bottom edge. Used for the toolbar, options bar, and status bar.
final class BarView: NSView {
    enum Border {
        case top
        case bottom
    }

    private let border: Border

    init(border: Border) {
        self.border = border
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BarView does not support NSCoder")
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        DS.chromeBackground.setFill()
        bounds.fill()
        DS.border.setFill()
        let line: NSRect
        switch border {
        case .top:
            line = NSRect(x: 0, y: 0, width: bounds.width, height: 1)
        case .bottom:
            line = NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
        }
        line.fill()
    }
}

// MARK: - CenteringClipView

/// Centers the document view inside the scroll area when it is smaller than
/// the visible rect, so the canvas floats in the middle of the well.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return rect }
        let docFrame = doc.frame
        if docFrame.width < rect.width {
            rect.origin.x = docFrame.minX - (rect.width - docFrame.width) / 2
        }
        if docFrame.height < rect.height {
            rect.origin.y = docFrame.minY - (rect.height - docFrame.height) / 2
        }
        return rect
    }
}

// MARK: - ZoomPillView

/// The floating zoom control at the canvas well's bottom-left: a dark
/// translucent pill with a mono percentage between two round steppers.
/// One of the design's two sanctioned uses of blur.
final class ZoomPillView: NSView {
    private let label = NSTextField(labelWithString: "100%")
    private let effect = NSVisualEffectView()

    var onZoomIn: (() -> Void)?
    var onZoomOut: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        effect.translatesAutoresizingMaskIntoConstraints = false
        effect.material = .hudWindow
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.appearance = NSAppearance(named: .darkAqua)
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 16
        effect.layer?.masksToBounds = true
        effect.layer?.backgroundColor =
            NSColor(srgbRed: 11 / 255, green: 18 / 255, blue: 15 / 255, alpha: 0.4).cgColor
        addSubview(effect)

        let minus = stepper(glyph: "−", action: #selector(minusClicked(_:)))
        let plus = stepper(glyph: "+", action: #selector(plusClicked(_:)))

        label.font = DS.mono(11)
        label.textColor = NSColor(srgbRed: 0.98, green: 0.97, blue: 0.94, alpha: 1)
        label.alignment = .center

        let stack = NSStackView(views: [minus, label, plus])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        addSubview(stack)

        NSLayoutConstraint.activate([
            effect.topAnchor.constraint(equalTo: topAnchor),
            effect.bottomAnchor.constraint(equalTo: bottomAnchor),
            effect.leadingAnchor.constraint(equalTo: leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.widthAnchor.constraint(greaterThanOrEqualToConstant: 42),
            heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ZoomPillView does not support NSCoder")
    }

    func setZoomText(_ text: String) {
        label.stringValue = text
    }

    private func stepper(glyph: String, action: Selector) -> NSButton {
        let button = NSButton(title: glyph, target: self, action: action)
        button.isBordered = false
        button.font = DS.mono(13, weight: .medium)
        button.contentTintColor = NSColor(srgbRed: 0.98, green: 0.97, blue: 0.94, alpha: 1)
        button.setButtonType(.momentaryChange)
        button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        button.wantsLayer = true
        button.layer?.cornerRadius = 12
        return button
    }

    @objc private func minusClicked(_ sender: Any?) { onZoomOut?() }
    @objc private func plusClicked(_ sender: Any?) { onZoomIn?() }
}

// MARK: - Status segments

/// One status-bar segment: 11px mono faint text with an optional 1px
/// leading separator, per the design's border-separated segments.
final class StatusSegment: NSView {
    private let label = NSTextField(labelWithString: "")
    private let showsSeparator: Bool

    init(separator: Bool) {
        self.showsSeparator = separator
        super.init(frame: .zero)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = DS.mono(11)
        label.textColor = DS.textFaint
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: separator ? 14 : 0),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setContentHuggingPriority(.defaultHigh, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("StatusSegment does not support NSCoder")
    }

    var text: String {
        get { label.stringValue }
        set {
            label.stringValue = newValue
            isHidden = newValue.isEmpty
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard showsSeparator, !isHidden else { return }
        DS.border.setFill()
        NSRect(x: 0, y: (bounds.height - 14) / 2, width: 1, height: 14).fill()
    }
}
