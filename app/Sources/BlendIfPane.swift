import AppKit

/// Blending Options > Blend If: a channel popup over two split-slider
/// ramps — "This Layer" on the layer's own pixels, "Underlying" on the
/// composite beneath — each a `BlendIfRampView` with four handles under a
/// black→white bar and a "lo0 / lo1    hi0 / hi1" readout. The bound value
/// is nil for "no blend-if": the pane writes nil whenever both ramps are
/// full-weight and the channel is gray, so an untouched pane never stores
/// one (the core would clear an identity anyway — its rule; this keeps the
/// sheet's own unchanged/changed comparison honest too).
final class BlendIfPane: NSObject, LayerStylePane {
    let view: NSView
    private let rows: [PaneRow]

    init(binding: EffectBinding<BlendIf?>, context: LayerStylePaneContext) {
        let current = { binding.read() ?? BlendIf() }
        let write: (BlendIf) -> Void = { value in
            binding.write(value.isIdentity && value.channel == "gray" ? nil : value)
        }
        let channel = PaneRows.popup(
            "Channel:", titles: ["Gray", "Red", "Green", "Blue"], values: BlendIf.channels,
            get: { current().channel },
            set: { value in
                var next = current()
                next.channel = value
                write(next)
            })
        let thisLayer = BlendIfRampRow(
            label: "This Layer:",
            get: { current().thisLayer },
            set: { ramp in
                var next = current()
                next.thisLayer = ramp
                write(next)
            })
        let underlying = BlendIfRampRow(
            label: "Underlying:",
            get: { current().underlying },
            set: { ramp in
                var next = current()
                next.underlying = ramp
                write(next)
            })
        let note = PaneRows.note(
            "Pixels whose channel value falls outside This Layer's range are hidden, as are "
                + "those over a composite outside Underlying's. Drag a handle to set a range; "
                + "Option-drag a joined handle to split it into a soft ramp.")
        rows = [channel, thisLayer, underlying, note]
        let stack = NSStackView(views: [PaneRows.grid(rows)])
        stack.orientation = .vertical
        stack.alignment = .leading
        view = stack
        super.init()
    }

    func reload() {
        rows.forEach { $0.reload() }
    }
}

// MARK: - Ramp row

/// Label + a `BlendIfRampView` over its mono readout, bound to one
/// `[lo0, lo1, hi0, hi1]` ramp. The readout always shows both halves of
/// each pair, so a joined pair reads "100 / 100" — the cue that ⌥-drag
/// splits it.
final class BlendIfRampRow: NSObject, PaneRow {
    private let label: NSTextField
    private let ramp = BlendIfRampView()
    private let readout = NSTextField(labelWithString: "")
    private let column: NSStackView
    private let get: () -> [Int]
    private let set: ([Int]) -> Void

    var views: [NSView] { [label, column] }

    init(label: String, get: @escaping () -> [Int], set: @escaping ([Int]) -> Void) {
        self.label = fieldLabel(label)
        self.get = get
        self.set = set
        column = NSStackView(views: [ramp, readout])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        super.init()
        readout.font = DS.mono(12)
        readout.textColor = DS.textMuted
        ramp.onChange = { [weak self] values in
            self?.showReadout(values)
            self?.set(values)
        }
        reload()
    }

    func reload() {
        let values = get()
        ramp.ramp = values
        showReadout(values)
    }

    private func showReadout(_ values: [Int]) {
        guard values.count == 4 else {
            readout.stringValue = ""
            return
        }
        readout.stringValue = "\(values[0]) / \(values[1])    \(values[2]) / \(values[3])"
    }
}

// MARK: - Ramp view

/// A Blend If split slider: a 256 pt black→white bar with four triangular
/// handles beneath it — the low pair (black) and the high pair (white),
/// each drawn as two half-triangles that read as ONE handle while joined,
/// exactly as Photoshop draws them. A drag moves the nearest handle; a
/// joined pair moves as one; ⌥-drag on a joined pair splits it, taking the
/// half on the side of the click; the order lo0 ≤ lo1 ≤ hi0 ≤ hi1 is kept
/// by clamping each handle against its neighbours. The grab keeps the
/// handle's offset from the pointer, so a click never jumps a handle.
final class BlendIfRampView: NSView {
    /// One value per 256/255 pt — the bar is exactly as wide as the range it
    /// shows, so a handle can be read against the tone under it.
    static let barWidth: CGFloat = 256
    /// Room for the half-width of a handle sitting at 0 or 255.
    private static let inset: CGFloat = 8
    private static let barHeight: CGFloat = 12
    /// A full triangle's base and height; a half-triangle is half the base.
    private static let handleWidth: CGFloat = 10
    private static let handleHeight: CGFloat = 9
    /// Extra pointer slop around a handle, matching the curve editor's.
    private static let hitSlop: CGFloat = 8

    /// `[lo0, lo1, hi0, hi1]` in 0…255; anything but four values draws the
    /// bar alone and ignores the mouse.
    var ramp: [Int] = BlendIf.fullRamp {
        didSet { needsDisplay = true }
    }
    var onChange: (([Int]) -> Void)?

    private enum Drag {
        /// A joined pair moving as one: the low pair or the high pair.
        case pair(low: Bool)
        /// One handle by index.
        case single(Int)
    }

    private var drag: Drag? {
        didSet { needsDisplay = true }
    }
    /// Handle x minus pointer x at grab time, so the handle follows the
    /// pointer from where it was rather than snapping under it.
    private var grabOffset: CGFloat = 0

    init() {
        super.init(frame: .zero)
        toolTip = "Drag a handle to set the range. Option-drag a joined handle to split it "
            + "into a soft ramp."
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BlendIfRampView does not support NSCoder")
    }

    /// y-down, like the dialog: the bar on top, the handles hanging below.
    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: Self.barWidth + Self.inset * 2,
            height: Self.barHeight + Self.handleHeight + Self.inset * 2)
    }

    private var barRect: NSRect {
        NSRect(x: Self.inset, y: Self.inset, width: Self.barWidth, height: Self.barHeight)
    }

    /// The strip the handles occupy, with slop, for cursor and hit tests.
    private var handleStrip: NSRect {
        NSRect(
            x: 0, y: barRect.minY - Self.hitSlop, width: bounds.width,
            height: Self.barHeight + Self.handleHeight + Self.hitSlop * 2)
    }

    override func resetCursorRects() {
        addCursorRect(handleStrip, cursor: .resizeLeftRight)
    }

    // MARK: Coordinate mapping

    private func x(for value: Int) -> CGFloat {
        barRect.minX + CGFloat(min(max(value, 0), 255)) / 255 * barRect.width
    }

    private func value(at x: CGFloat) -> Int {
        let raw = (x - barRect.minX) / barRect.width * 255
        return min(max(Int(raw.rounded()), 0), 255)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let bar = barRect
        if let gradient = NSGradient(starting: .black, ending: .white) {
            gradient.draw(in: bar, angle: 0)
        }
        let frame = NSBezierPath(rect: bar.insetBy(dx: 0.5, dy: 0.5))
        frame.lineWidth = 1
        DS.borderStrong.setStroke()
        frame.stroke()

        guard ramp.count == 4 else { return }
        for index in 0..<4 {
            let path = handlePath(index)
            if isDragging(index) {
                DS.accent.setFill()
            } else if index < 2 {
                NSColor.black.setFill()
            } else {
                NSColor.white.setFill()
            }
            path.fill()
            path.lineWidth = 1
            DS.textStrong.setStroke()
            path.stroke()
        }
    }

    /// Even indices are the LEFT half of their pair's triangle, odd the
    /// RIGHT half; a joined pair's halves meet at one apex and read as a
    /// single triangle.
    private func handlePath(_ index: Int) -> NSBezierPath {
        let cx = x(for: ramp[index])
        let top = barRect.maxY
        let bottom = top + Self.handleHeight
        let half = Self.handleWidth / 2
        let path = NSBezierPath()
        path.move(to: NSPoint(x: cx, y: top))
        if index % 2 == 0 {
            path.line(to: NSPoint(x: cx - half, y: bottom))
            path.line(to: NSPoint(x: cx, y: bottom))
        } else {
            path.line(to: NSPoint(x: cx, y: bottom))
            path.line(to: NSPoint(x: cx + half, y: bottom))
        }
        path.close()
        return path
    }

    private func isDragging(_ index: Int) -> Bool {
        switch drag {
        case .none:
            return false
        case .pair(let low):
            return low ? index < 2 : index >= 2
        case .single(let dragged):
            return dragged == index
        }
    }

    // MARK: Interaction

    /// The handle under the pointer: the nearest by x within slop; among
    /// handles stacked at one x, the side of the click decides (left of
    /// the stack takes the lowest index, right of it the highest), so a
    /// pair joined against its neighbour still lets each side be grabbed.
    private func nearestHandle(at location: NSPoint) -> Int? {
        guard ramp.count == 4, handleStrip.contains(location) else { return nil }
        let reach = Self.handleWidth / 2 + Self.hitSlop
        var best: (index: Int, distance: CGFloat)?
        for index in 0..<4 {
            let handleX = x(for: ramp[index])
            let distance = abs(location.x - handleX)
            guard distance <= reach else { continue }
            if let current = best {
                if distance < current.distance {
                    best = (index, distance)
                } else if distance == current.distance, location.x >= handleX {
                    best = (index, distance)
                }
            } else {
                best = (index, distance)
            }
        }
        return best?.index
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard let index = nearestHandle(at: location) else { return }
        let low = index < 2
        let first = low ? 0 : 2
        let joined = ramp[first] == ramp[first + 1]
        if joined, event.modifierFlags.contains(.option) {
            // Split: take the half on the side of the click.
            drag = .single(location.x < x(for: ramp[first]) ? first : first + 1)
        } else if joined {
            drag = .pair(low: low)
        } else {
            drag = .single(index)
        }
        grabOffset = x(for: ramp[draggedIndex ?? index]) - location.x
    }

    override func mouseDragged(with event: NSEvent) {
        guard drag != nil else { return }
        apply(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        drag = nil
    }

    /// The handle whose position the pointer tracks (a pair tracks its
    /// first handle; both move together).
    private var draggedIndex: Int? {
        switch drag {
        case .none:
            return nil
        case .pair(let low):
            return low ? 0 : 2
        case .single(let index):
            return index
        }
    }

    private func apply(_ location: NSPoint) {
        guard let drag = drag, ramp.count == 4 else { return }
        let target = value(at: location.x + grabOffset)
        var next = ramp
        switch drag {
        case .pair(let low):
            // A joined pair stays joined and stops at the other pair.
            if low {
                let value = min(target, next[2])
                next[0] = value
                next[1] = value
            } else {
                let value = max(target, next[1])
                next[2] = value
                next[3] = value
            }
        case .single(let index):
            let lower = index == 0 ? 0 : next[index - 1]
            let upper = index == 3 ? 255 : next[index + 1]
            next[index] = min(max(target, lower), upper)
        }
        guard next != ramp else { return }
        ramp = next
        onChange?(next)
    }
}
