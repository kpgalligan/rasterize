import AppKit

// MARK: - Model

/// One control point of a curves channel, in the meta schema's integer
/// [0, 255] × [0, 255] space (an `[in, out]` pair; core/src/adjust.rs). The
/// editor keeps every channel's list sorted by `x` with distinct `x` values
/// and 2...16 points — exactly what the core's parser accepts.
struct CurvePoint: Equatable {
    var x: Int
    var y: Int

    /// The identity point list — what a channel the meta omits means.
    static let identity = [CurvePoint(x: 0, y: 0), CurvePoint(x: 255, y: 255)]
}

/// The four point lists of a curves op, keyed by the meta's params keys.
/// Application order in the core: the per-channel table first, then the
/// master `rgb` table.
enum CurveChannel: String, CaseIterable {
    case rgb = "rgb"
    case red = "r"
    case green = "g"
    case blue = "b"

    var displayName: String {
        switch self {
        case .rgb: return "RGB"
        case .red: return "Red"
        case .green: return "Green"
        case .blue: return "Blue"
        }
    }

    /// The plot's stroke for this channel's curve.
    var strokeColor: NSColor {
        switch self {
        case .rgb: return DS.textStrong
        case .red: return .systemRed
        case .green: return .systemGreen
        case .blue: return .systemBlue
        }
    }
}

/// Round-trips between a curves payload's `params` and per-channel point
/// lists. WRITING is strict — integer points in [0, 255], sorted by `x`,
/// distinct `x`s, identity channels omitted (the schema's "missing channel
/// = identity") — so the app never writes malformed meta. READING is
/// defensive: anything not shaped like a point list falls back to identity
/// (range truth stays in the core; the dialog only needs something sane to
/// prefill).
enum CurvesMeta {
    /// The meta `params` for the given channels: only channels whose points
    /// differ from identity are included; all-identity curves produce an
    /// empty params object (a valid identity adjustment).
    static func params(_ channelPoints: [CurveChannel: [CurvePoint]]) -> [String: Any] {
        var params: [String: Any] = [:]
        for channel in CurveChannel.allCases {
            let points = channelPoints[channel] ?? CurvePoint.identity
            guard points != CurvePoint.identity else { continue }
            params[channel.rawValue] = points.map { [$0.x, $0.y] }
        }
        return params
    }

    /// `channel`'s points out of a curves payload, for prefilling the
    /// editor: rounded to integers, clamped to [0, 255], stably sorted by
    /// `x` with later duplicate `x`s dropped (the core's own rule).
    /// Identity when the channel is missing or structurally not a point
    /// list.
    static func points(of channel: CurveChannel, in payload: AdjustmentLayerPayload) -> [CurvePoint] {
        guard let raw = payload.params[channel.rawValue] else { return CurvePoint.identity }
        guard let list = raw as? [[NSNumber]], (2...16).contains(list.count) else {
            return CurvePoint.identity
        }
        var points: [CurvePoint] = []
        for pair in list {
            guard pair.count == 2 else { return CurvePoint.identity }
            let x = pair[0].doubleValue
            let y = pair[1].doubleValue
            guard x.isFinite, y.isFinite else { return CurvePoint.identity }
            points.append(
                CurvePoint(
                    x: Int(min(max(x, 0), 255).rounded()),
                    y: Int(min(max(y, 0), 255).rounded())))
        }
        // Stable sort by x, first listed winning a duplicate — mirroring the
        // core's parse_points (integer rounding can create duplicates the
        // core's float compare kept apart; first-wins stays consistent).
        points = points.enumerated()
            .sorted { ($0.element.x, $0.offset) < ($1.element.x, $1.offset) }
            .map { $0.element }
        var deduped: [CurvePoint] = []
        for point in points where deduped.last?.x != point.x {
            deduped.append(point)
        }
        return deduped.count >= 2 ? deduped : CurvePoint.identity
    }
}

// MARK: - Monotone cubic (display twin of the core's LUT)

/// Fritsch–Carlson monotone cubic interpolant through the control points —
/// a Swift port of the core's `monotone_lut` (core/src/adjust.rs) so the
/// plotted curve visually matches the LUT the compositor applies (the core
/// additionally rounds each of its 256 entries to u8; that sub-pixel drift
/// is invisible at plot scale). Construction: secant slopes, averaged
/// tangents zeroed across sign changes and flat segments, then the circle
/// limit (alpha² + beta² ≤ 9) that guarantees monotonicity on monotone
/// data.
struct MonotoneCurve {
    private let xs: [Double]
    private let ys: [Double]
    private let tangents: [Double]

    /// `points` sorted by `x` with distinct `x`s (the editor's invariant);
    /// fewer than 2 points falls back to identity.
    init(points: [CurvePoint]) {
        let points = points.count >= 2 ? points : CurvePoint.identity
        let xs = points.map { Double($0.x) }
        let ys = points.map { Double($0.y) }
        let n = points.count
        var d = [Double](repeating: 0, count: n - 1)
        for k in 0..<(n - 1) {
            d[k] = (ys[k + 1] - ys[k]) / (xs[k + 1] - xs[k])
        }
        var m = [Double](repeating: 0, count: n)
        m[0] = d[0]
        m[n - 1] = d[n - 2]
        for k in 1..<(n - 1) {
            m[k] = d[k - 1] * d[k] <= 0 ? 0 : (d[k - 1] + d[k]) / 2
        }
        for k in 0..<(n - 1) {
            if d[k] == 0 {
                m[k] = 0
                m[k + 1] = 0
                continue
            }
            let alpha = m[k] / d[k]
            let beta = m[k + 1] / d[k]
            let s = alpha * alpha + beta * beta
            if s > 9 {
                let tau = 3.0 / s.squareRoot()
                m[k] = tau * alpha * d[k]
                m[k + 1] = tau * beta * d[k]
            }
        }
        self.xs = xs
        self.ys = ys
        self.tangents = m
    }

    /// The curve's value at `x`, exactly as the core's LUT samples it:
    /// outside the point range the nearest endpoint's value, inside it the
    /// cubic Hermite segment, clamped to [0, 255].
    func value(at x: Double) -> Double {
        if x <= xs[0] { return ys[0] }
        let last = xs.count - 1
        if x >= xs[last] { return ys[last] }
        var k = last - 1
        for i in 0..<last where x < xs[i + 1] {
            k = i
            break
        }
        let h = xs[k + 1] - xs[k]
        let t = (x - xs[k]) / h
        let t2 = t * t
        let t3 = t2 * t
        let y = ys[k] * (2 * t3 - 3 * t2 + 1)
            + h * tangents[k] * (t3 - 2 * t2 + t)
            + ys[k + 1] * (-2 * t3 + 3 * t2)
            + h * tangents[k + 1] * (t3 - t2)
        return min(max(y, 0), 255)
    }
}

// MARK: - CurveEditorView

/// The interactive curves plot: a ~256pt square with quarter gridlines, the
/// faint identity diagonal, and ONE channel's curve (the controller swaps
/// `points`/`curveColor` when the channel popup changes). Control points
/// snap to integers. Interactions: click on/near the curve adds a point
/// (max 16); dragging moves a point with `x` clamped strictly between its
/// neighbors and `y` to [0, 255]; dragging a point well outside the plot
/// removes it (endpoints never; minimum 2 points remain). The dragged
/// point highlights, and `onDragReadout` carries a live "in → out" string
/// (nil when the drag ends).
final class CurveEditorView: NSView {
    static let maxPoints = 16
    /// Side of the value plot itself; the view adds `inset` around it so
    /// edge points and their hit slop stay inside.
    static let plotSide: CGFloat = 256
    private static let inset: CGFloat = 8
    /// How far outside the plot a dragged point must go to be removed.
    private static let removeMargin: CGFloat = 32
    private static let pointHitRadius: CGFloat = 8
    private static let curveHitDistance: CGFloat = 6

    /// The current channel's points — sorted by `x`, distinct `x`s,
    /// 2...16 of them. The controller sets this on channel switches; the
    /// view mutates it (and fires `onPointsChanged`) on user edits.
    var points: [CurvePoint] = CurvePoint.identity {
        didSet { needsDisplay = true }
    }
    var curveColor: NSColor = DS.textStrong {
        didSet { needsDisplay = true }
    }
    var onPointsChanged: (([CurvePoint]) -> Void)?
    /// "in → out" while a point drags; nil when the drag ends.
    var onDragReadout: ((String?) -> Void)?

    private var dragIndex: Int? {
        didSet { needsDisplay = true }
    }

    override var intrinsicContentSize: NSSize {
        let side = Self.plotSide + Self.inset * 2
        return NSSize(width: side, height: side)
    }

    /// Value (0,0)..(255,255) maps across this rect, y upward (the view is
    /// not flipped, so plot space and view space agree).
    private var plotRect: NSRect {
        let side = min(bounds.width, bounds.height) - Self.inset * 2
        return NSRect(x: Self.inset, y: Self.inset, width: max(side, 0), height: max(side, 0))
    }

    override func resetCursorRects() {
        addCursorRect(plotRect, cursor: .crosshair)
    }

    // MARK: Coordinate mapping

    private func viewPoint(for point: CurvePoint) -> NSPoint {
        let rect = plotRect
        return NSPoint(
            x: rect.minX + CGFloat(point.x) / 255 * rect.width,
            y: rect.minY + CGFloat(point.y) / 255 * rect.height)
    }

    /// Unclamped value-space position of a view-space location.
    private func valuePosition(at location: NSPoint) -> (x: Double, y: Double)? {
        let rect = plotRect
        guard rect.width > 0, rect.height > 0 else { return nil }
        return (
            x: Double((location.x - rect.minX) / rect.width) * 255,
            y: Double((location.y - rect.minY) / rect.height) * 255
        )
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let rect = plotRect
        guard rect.width > 0 else { return }

        DS.canvasVoid.setFill()
        NSBezierPath(rect: rect).fill()

        // Light quarter gridlines.
        let grid = NSBezierPath()
        grid.lineWidth = 1
        for quarter in 1...3 {
            let f = CGFloat(quarter) / 4
            grid.move(to: NSPoint(x: rect.minX + f * rect.width, y: rect.minY))
            grid.line(to: NSPoint(x: rect.minX + f * rect.width, y: rect.maxY))
            grid.move(to: NSPoint(x: rect.minX, y: rect.minY + f * rect.height))
            grid.line(to: NSPoint(x: rect.maxX, y: rect.minY + f * rect.height))
        }
        DS.border.setStroke()
        grid.stroke()

        // Faint identity diagonal, the curve's reference.
        let diagonal = NSBezierPath()
        diagonal.lineWidth = 1
        diagonal.move(to: NSPoint(x: rect.minX, y: rect.minY))
        diagonal.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
        DS.textFaint.withAlphaComponent(0.5).setStroke()
        diagonal.stroke()

        // Plot frame.
        let frame = NSBezierPath(rect: rect)
        frame.lineWidth = 1
        DS.borderStrong.setStroke()
        frame.stroke()

        // The channel's curve, sampled at every integer input like the
        // core's 256-entry LUT.
        let curve = MonotoneCurve(points: points)
        let path = NSBezierPath()
        path.lineWidth = 1.5
        for i in 0...255 {
            let x = Double(i)
            let point = NSPoint(
                x: rect.minX + CGFloat(x) / 255 * rect.width,
                y: rect.minY + CGFloat(curve.value(at: x)) / 255 * rect.height)
            if i == 0 {
                path.move(to: point)
            } else {
                path.line(to: point)
            }
        }
        curveColor.setStroke()
        path.stroke()

        // Control points; the dragged one fills solid and slightly larger.
        for (index, point) in points.enumerated() {
            let center = viewPoint(for: point)
            let radius: CGFloat = index == dragIndex ? 4.5 : 3.5
            let dot = NSBezierPath(
                ovalIn: NSRect(
                    x: center.x - radius, y: center.y - radius,
                    width: radius * 2, height: radius * 2))
            if index == dragIndex {
                curveColor.setFill()
                dot.fill()
            } else {
                DS.chromeBackground.setFill()
                dot.fill()
                dot.lineWidth = 1.5
                curveColor.setStroke()
                dot.stroke()
            }
        }
    }

    // MARK: Interaction

    private func pointIndex(at location: NSPoint) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for (index, point) in points.enumerated() {
            let center = viewPoint(for: point)
            let distance = hypot(location.x - center.x, location.y - center.y)
            if distance <= Self.pointHitRadius, distance < (best?.distance ?? .infinity) {
                best = (index, distance)
            }
        }
        return best?.index
    }

    private func emitReadout() {
        guard let index = dragIndex, points.indices.contains(index) else { return }
        onDragReadout?("\(points[index].x) → \(points[index].y)")
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if let index = pointIndex(at: location) {
            dragIndex = index
            emitReadout()
            return
        }
        // Click on/near the curve adds a point ON the curve at that input.
        guard let value = valuePosition(at: location), points.count < Self.maxPoints else { return }
        let curve = MonotoneCurve(points: points)
        let rect = plotRect
        let curveY = rect.minY + CGFloat(curve.value(at: value.x)) / 255 * rect.height
        guard abs(location.y - curveY) <= Self.curveHitDistance,
              value.x > -1, value.x < 256
        else { return }
        let x = Int(min(max(value.x, 0), 255).rounded())
        // Distinct-x invariant: a click that rounds onto an existing
        // point's input adds nothing (that point was outside hit range).
        guard !points.contains(where: { $0.x == x }) else { return }
        let y = Int(min(max(curve.value(at: Double(x)), 0), 255).rounded())
        let insertAt = points.firstIndex { $0.x > x } ?? points.count
        points.insert(CurvePoint(x: x, y: y), at: insertAt)
        dragIndex = insertAt
        emitReadout()
        onPointsChanged?(points)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let index = dragIndex, points.indices.contains(index) else { return }
        let location = convert(event.locationInWindow, from: nil)
        let rect = plotRect

        // Well outside the plot removes the point — but never an endpoint,
        // and never below 2 points.
        let farOutside = location.x < rect.minX - Self.removeMargin
            || location.x > rect.maxX + Self.removeMargin
            || location.y < rect.minY - Self.removeMargin
            || location.y > rect.maxY + Self.removeMargin
        if farOutside, index != 0, index != points.count - 1, points.count > 2 {
            points.remove(at: index)
            dragIndex = nil
            onDragReadout?(nil)
            onPointsChanged?(points)
            return
        }

        guard let value = valuePosition(at: location) else { return }
        // x strictly between neighbors (integer space: at least 1 apart);
        // endpoints bound by the plot edge instead of a missing neighbor.
        let lower = index == 0 ? 0 : points[index - 1].x + 1
        let upper = index == points.count - 1 ? 255 : points[index + 1].x - 1
        let x = min(max(Int(value.x.rounded()), lower), upper)
        let y = min(max(Int(value.y.rounded()), 0), 255)
        guard points[index].x != x || points[index].y != y else { return }
        points[index] = CurvePoint(x: x, y: y)
        emitReadout()
        onPointsChanged?(points)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragIndex != nil else { return }
        dragIndex = nil
        onDragReadout?(nil)
    }
}
