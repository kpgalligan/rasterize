import AppKit

/// One row of the Actions window's step table.
///
/// Five things, left to right: the step NUMBER (the report says "stopped at
/// step 7", so the number has to be readable off the list), the enabled
/// checkbox, the step's one-line display name over a mono meta line, and —
/// pinned right — the `continue` badge.
///
/// The meta line is where a step's honesty lives: the catalog tool name (the
/// exact key a JSON edit has to spell), the recorder's own `note` — which is
/// how the Move-drag caveat reaches the reader, "recorded as an absolute
/// position; the drag was a relative move" — and an advisory word for the
/// tools whose result depends on there being a selection.
///
/// Built from the Layers panel's own pieces (`LayerRowView` draws the
/// selection behind it, `DS.layerRow` is the height) so the list reads like
/// the panels it sits beside.
final class ActionStepCellView: NSView {
    /// The checkbox was clicked. The controller owns what "enabled" means
    /// for the subject on screen — a saved action's file, or the live
    /// recording — so the cell only reports the click.
    var onToggleEnabled: (() -> Void)?

    private let indexLabel = NSTextField(labelWithString: "")
    private let enabledBox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let titleLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private let badge = StepBadgeView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        indexLabel.font = DS.mono(10)
        indexLabel.textColor = DS.textFaint
        indexLabel.alignment = .right

        enabledBox.target = self
        enabledBox.action = #selector(enabledClicked(_:))
        enabledBox.title = ""

        titleLabel.font = DS.sans(13)
        titleLabel.textColor = DS.textStrong
        titleLabel.lineBreakMode = .byTruncatingTail

        metaLabel.font = DS.mono(10)
        metaLabel.textColor = DS.textFaint
        metaLabel.lineBreakMode = .byTruncatingTail

        for subview in [indexLabel, enabledBox, titleLabel, metaLabel, badge] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }

        // 12 / 18 / 8 / 16 / 10: the gutter matches the 6 pt inset
        // `LayerRowView` draws its selection rectangle at, plus enough room
        // for a three-digit step number in mono 10.
        NSLayoutConstraint.activate([
            indexLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            indexLabel.widthAnchor.constraint(equalToConstant: 18),
            indexLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            enabledBox.leadingAnchor.constraint(equalTo: indexLabel.trailingAnchor, constant: 8),
            enabledBox.centerYAnchor.constraint(equalTo: centerYAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: enabledBox.trailingAnchor, constant: 10),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: badge.leadingAnchor, constant: -8),

            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            badge.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),

            metaLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            metaLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            metaLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
        ])
        // The title yields before the badge does: a long "Add Adjustment
        // Layer: brightness contrast" must truncate rather than push
        // `continue` off the row, which is the one thing on the line that
        // changes what a run DOES.
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ActionStepCellView does not support NSCoder")
    }

    /// Fills the row in. `number` is 1-based, matching every message an
    /// `ActionRunReport` produces.
    func configure(number: Int, step: ActionStep) {
        indexLabel.stringValue = String(number)
        enabledBox.state = step.enabled ? .on : .off
        enabledBox.toolTip =
            step.enabled ? "Skip this step when the action runs" : "Run this step again"

        if step.isUnrecorded {
            // The §0.4 placeholder: a user command with no MCP twin. It can
            // never run, and the player refuses it by name, so the row says
            // so in the amber the histogram's clipping wedge and the channel
            // mixer's Total already use — `DS` has no warning token and
            // inventing one for two call sites would be a worse kind of
            // drift.
            titleLabel.stringValue = "Not recorded — \(step.unrecordedName)"
            titleLabel.textColor = .systemOrange
        } else {
            titleLabel.stringValue = ActionCatalogFacts.displayName(
                for: step.tool, arguments: step.arguments)
            titleLabel.textColor = DS.textStrong
        }

        var meta: [String] = step.isUnrecorded ? [] : [step.tool]
        if ActionCatalogFacts.selectionSensitive.contains(step.tool) {
            // Advisory, never a failure: these tools read the selection, so a
            // reader who replays the action on a document with a different
            // selection can see why the result differed.
            meta.append("uses the selection")
        }
        if let note = step.note, !note.isEmpty { meta.append(note) }
        if !step.enabled { meta.append("disabled") }
        let line = meta.joined(separator: " · ")
        metaLabel.stringValue = line
        // The line truncates by design; the tooltip carries the whole of it,
        // the same bargain `sheetFootnote` strikes.
        metaLabel.toolTip = line.isEmpty ? nil : line

        badge.text = step.onError == .continueRun ? "continue" : ""
        badge.toolTip =
            step.onError == .continueRun
            ? "If this step fails the run carries on to the next one." : nil
        alphaValue = step.enabled ? 1 : 0.55
    }

    @objc private func enabledClicked(_ sender: Any?) {
        onToggleEnabled?()
    }
}

// MARK: - The on-error badge

/// The small `continue` pill. A view rather than a styled `NSTextField`
/// because a field has no way to pad its text inside its own background, and
/// the pill's whole job is to be legible at a glance.
private final class StepBadgeView: NSView {
    var text = "" {
        didSet {
            guard text != oldValue else { return }
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    private var attributes: [NSAttributedString.Key: Any] {
        [.font: DS.mono(9), .foregroundColor: DS.textMuted]
    }

    override var intrinsicContentSize: NSSize {
        guard !text.isEmpty else { return NSSize(width: 0, height: 0) }
        let size = text.size(withAttributes: attributes)
        // 14 pt tall with 6 pt of side padding: the same weight as the
        // options bar's 22 pt controls, one step down.
        return NSSize(width: (size.width).rounded(.up) + 12, height: 14)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !text.isEmpty else { return }
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        DS.hoverFill.setFill()
        path.fill()
        DS.border.setStroke()
        path.lineWidth = 1
        path.stroke()
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
            withAttributes: attributes)
    }
}
