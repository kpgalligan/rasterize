import AppKit

/// One ruler strip — the horizontal one above the canvas well, the vertical
/// one beside it — plus the corner box the two meet in.
///
/// THE STRIP NEVER DOES ITS OWN MAGNIFICATION ARITHMETIC. It maps canvas
/// coordinates through AppKit view conversion (`convert(_:from: canvas)`),
/// because `CenteringClipView` offsets a small canvas inside the well: the
/// clip origin is not the canvas origin, and any hand-rolled
/// `x * magnification + something` would be right only while the document
/// fills the viewport. Two converted reference points give the affine map
/// (the conversion is scale + translation, never a rotation), and every tick
/// interpolates along it.
///
/// THE RULER ORIGIN MOVES LABELS AND NOTHING ELSE. A label reads 0 at the
/// origin and goes negative to its left or above it — but the grid, every
/// snap target and every coordinate any other API reports are measured from
/// canvas (0, 0). The only other place the origin is honoured is the New
/// Guide sheet, whose typed number is one the user read off a ruler.
final class RulerView: NSView {
    enum Orientation {
        case horizontal
        case vertical
    }

    let orientation: Orientation

    /// The canvas this strip measures. Weak: the editor owns both.
    weak var canvas: ImageCanvasView?

    var unit: CanvasUnit = .pixels {
        didSet { if unit != oldValue { needsDisplay = true } }
    }

    /// The ruler's zero point on THIS axis, in canvas coordinates.
    var origin: CGFloat = 0 {
        didSet { if origin != oldValue { needsDisplay = true } }
    }

    /// Canvas pixels per one of `unit` on this strip's axis — already
    /// resolved per axis from the document's ppi by the controller.
    var pixelsPerUnit: Double = 1 {
        didSet { if pixelsPerUnit != oldValue { needsDisplay = true } }
    }

    /// The pointer's position on this axis, in CANVAS coordinates; nil when
    /// the cursor is off the canvas.
    private(set) var pointer: CGFloat?

    /// A press inside the strip: the receiver opens a new guide drag. The
    /// point is in CANVAS coordinates — the strip converts, because AppKit
    /// delivers the whole drag to the view that took the mouse-down.
    ///
    /// Dragging out of the HORIZONTAL (top) strip makes a HORIZONTAL guide
    /// and out of the vertical strip a vertical one, which is Photoshop's
    /// rule and the only one that matches the gesture: the pointer leaves
    /// the top strip travelling down, along the axis a horizontal guide
    /// moves on.
    var onDragOut: ((GuideOrientation, CGPoint) -> Void)?
    /// Each drag tick, canvas coordinates plus the live modifiers (⌃
    /// suspends snapping and must be read per tick, never latched).
    var onDragUpdate: ((CGPoint, NSEvent.ModifierFlags) -> Void)?
    /// Mouse-up. No point: the guide drag commits what its last tick
    /// previewed, and reading the release event as well let the two disagree
    /// (EditorViewController+Guides.guideMouseUp).
    var onDragEnd: (() -> Void)?

    /// The guide a drag out of this strip creates.
    var guideOrientation: GuideOrientation {
        orientation == .horizontal ? .horizontal : .vertical
    }

    init(orientation: Orientation) {
        self.orientation = orientation
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("RulerView does not support NSCoder")
    }

    /// Flipped like the canvas and like `BarView`, so the vertical strip's y
    /// runs the same direction as the canvas's.
    override var isFlipped: Bool { true }

    // MARK: - The pointer mark

    /// Moves the pointer mark, redrawing only the two small rectangles it
    /// leaves and enters.
    ///
    /// It must NEVER touch the canvas's `needsDisplay`: `onCursorMove`'s
    /// contract is that "the handler must never set `needsDisplay`, or every
    /// mouse-moved event would redraw the canvas", and this rides that same
    /// notification. `draw(_:)` honours the two rectangles: its tick loop is
    /// clipped to the dirty band (`labelReach`), so a pointer move costs a
    /// handful of ticks and a label or two rather than the whole ladder and
    /// every label on both strips.
    func setPointer(_ position: CGFloat?) {
        guard position != pointer else { return }
        let before = markerRect(pointer)
        pointer = position
        let after = markerRect(position)
        if let before = before { setNeedsDisplay(before) }
        if let after = after { setNeedsDisplay(after) }
    }

    private func markerRect(_ position: CGFloat?) -> CGRect? {
        guard let position = position, let point = stripPoint(canvas: position) else {
            return nil
        }
        switch orientation {
        case .horizontal:
            return CGRect(x: point - 1.5, y: 0, width: 3, height: bounds.height)
        case .vertical:
            return CGRect(x: 0, y: point - 1.5, width: bounds.width, height: 3)
        }
    }

    // MARK: - Canvas ↔ strip

    /// The mapping the strip was last marked for display with; nil until it
    /// has been asked once.
    private var refreshedMapping: (offset: CGFloat, scale: CGFloat)?

    /// Marks the strip for display only when what it draws can actually have
    /// changed.
    ///
    /// The three values a ladder is computed from — `unit`, `origin`,
    /// `pixelsPerUnit` — invalidate through their own `didSet`s, so the only
    /// other input is the canvas→strip MAPPING, which moves with zoom,
    /// scroll, a window resize and a canvas-size change without any stored
    /// value changing. Asking it costs two view conversions; the
    /// unconditional `needsDisplay` this replaced re-laid the whole tick
    /// ladder and every CoreText label on BOTH strips on every live drag
    /// tick — `imageDidChange` fires one per mouse-moved event during a
    /// paint stroke and a Move — for a picture that cannot have moved a tick.
    func refreshForMapping() {
        let map = mapping()
        guard map?.offset != refreshedMapping?.offset
            || map?.scale != refreshedMapping?.scale
        else { return }
        refreshedMapping = map
        needsDisplay = true
    }

    /// The affine map from canvas coordinates on this axis to points inside
    /// the strip: `(offset, scale)`, from two converted reference points.
    /// nil while the strip has no canvas or the two views are not in one
    /// window yet.
    private func mapping() -> (offset: CGFloat, scale: CGFloat)? {
        guard let canvas = canvas, canvas.window != nil, window != nil else { return nil }
        let zero = convert(CGPoint.zero, from: canvas)
        let one = convert(CGPoint(x: 1, y: 1), from: canvas)
        switch orientation {
        case .horizontal:
            let scale = one.x - zero.x
            return scale.isFinite && scale > 0 ? (zero.x, scale) : nil
        case .vertical:
            let scale = one.y - zero.y
            return scale.isFinite && scale > 0 ? (zero.y, scale) : nil
        }
    }

    private func stripPoint(canvas coordinate: CGFloat) -> CGFloat? {
        guard let map = mapping() else { return nil }
        return map.offset + coordinate * map.scale
    }

    /// A point inside the strip, in canvas coordinates. Both components come
    /// from the canvas so a drag out of the top strip carries a real x as
    /// well as the y it is placing.
    private func canvasPoint(_ event: NSEvent) -> CGPoint? {
        guard let canvas = canvas else { return nil }
        return canvas.convert(convert(event.locationInWindow, from: nil), from: self)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        // Surface and edge hairline, exactly like BarView: the strips are
        // chrome and must read as part of the same bar family.
        DS.chromeBackground.setFill()
        bounds.fill()
        DS.border.setFill()
        switch orientation {
        case .horizontal:
            NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        case .vertical:
            NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill()
        }
        drawTicks(in: dirtyRect)
        drawPointerMark()
    }

    /// How far BACK along the strip a label can reach from its own tick, in
    /// points. Both strips draw a label in the direction the coordinate
    /// increases (see `drawLabel`), so a tick this far behind the redrawn
    /// band is the last one whose label can still paint into it.
    ///
    /// The widest label the ladder can write is a signed five-figure
    /// coordinate with `RulerTicks.maxDecimals` decimals — eleven glyphs at
    /// a 9 pt monospaced advance, about 60 pt — and this is the number that
    /// has to be generous rather than tight: too small clips a label on a
    /// marker-only repaint, while too large only draws a few more ticks
    /// nobody can see. At a typical 10 pt minor spacing 96 pt of margin is
    /// ten extra ticks and one extra label, against the ~160 ticks and ~16
    /// labels a full-width pass costs.
    private static let labelReach: CGFloat = 96

    private func drawTicks(in dirtyRect: NSRect) {
        guard let map = mapping(), pixelsPerUnit.isFinite, pixelsPerUnit > 0 else { return }
        let thickness = orientation == .horizontal ? bounds.height : bounds.width
        let extent = orientation == .horizontal ? bounds.width : bounds.height
        guard thickness > 4, extent > 0 else { return }

        // One screen point covers this much of the unit — the quantity the
        // tick ladder is chosen from.
        let unitsPerPoint = 1 / (Double(map.scale) * pixelsPerUnit)
        let schedule = RulerTicks.schedule(unitsPerPoint: unitsPerPoint, unit: unit)
        let divisions = max(1, schedule.minorDivisions)
        let minor = schedule.step / Double(divisions)
        guard minor.isFinite, minor > 0 else { return }
        // The tick cap is measured over the WHOLE strip, from the ladder's
        // density, and never over the band below: a marker-only repaint must
        // not paint ticks into its own 3 points that a full redraw refuses
        // to draw at all.
        let minorPoints = minor * pixelsPerUnit * Double(map.scale)
        guard minorPoints.isFinite, minorPoints > 0,
              Double(extent) / minorPoints <= Double(RulerTicks.maxTicks)
        else { return }

        // The band of the strip actually being redrawn, then the canvas range
        // it covers, then the same range in units measured FROM THE RULER
        // ORIGIN.
        //
        // The DIRTY RECT, not the whole strip: `setPointer` invalidates two
        // 3-point rectangles per pointer move, and a tick loop run over the
        // full width would lay out every label on both strips on every
        // mouse-moved event — AppKit clips the ink away afterwards but pays
        // for the CoreText layout regardless. The band is widened backwards
        // by `labelReach` so a label whose tick sits just before it still
        // paints; forwards it needs nothing, since no label reaches back.
        let bandStart = orientation == .horizontal ? dirtyRect.minX : dirtyRect.minY
        let bandEnd = orientation == .horizontal ? dirtyRect.maxX : dirtyRect.maxY
        let low = max(min(bandStart, extent) - Self.labelReach, 0)
        let high = min(max(bandEnd, 0), extent)
        guard high >= low else { return }
        let lowCanvas = (low - map.offset) / map.scale
        let highCanvas = (high - map.offset) / map.scale
        let lowUnit = unit.value(
            canvas: min(lowCanvas, highCanvas), origin: origin, pixelsPerUnit: pixelsPerUnit)
        let highUnit = unit.value(
            canvas: max(lowCanvas, highCanvas), origin: origin, pixelsPerUnit: pixelsPerUnit)
        // The tick INDICES are bounded before they become Ints: a degenerate
        // ppi or magnification can make the ratio exceed what an Int holds,
        // and `Int(_ :Double)` traps rather than saturating. 1e9 is far past
        // the 2000-tick cap the ladder already passed, so nothing legible is
        // lost.
        let firstRatio = (lowUnit / minor).rounded(.down)
        let lastRatio = (highUnit / minor).rounded(.up)
        guard lowUnit.isFinite, highUnit.isFinite, firstRatio.isFinite, lastRatio.isFinite,
              abs(firstRatio) < 1e9, abs(lastRatio) < 1e9
        else { return }
        let firstIndex = Int(firstRatio)
        let lastIndex = Int(lastRatio)
        guard lastIndex >= firstIndex, lastIndex - firstIndex <= RulerTicks.maxTicks else {
            return
        }

        let major = thickness - 3
        let medium = thickness * 0.6
        let small = thickness * 0.35
        DS.borderStrong.setFill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: DS.mono(9), .foregroundColor: DS.textFaint,
        ]

        for index in firstIndex...lastIndex {
            let value = Double(index) * minor
            let coordinate = unit.canvas(
                value: value, origin: origin, pixelsPerUnit: pixelsPerUnit)
            let position = (map.offset + coordinate * map.scale).rounded()
            guard position >= -1, position <= extent + 1 else { continue }
            let isMajor = index % divisions == 0
            let isMedium = divisions % 2 == 0 && index % (divisions / 2) == 0
            let length = isMajor ? major : (isMedium ? medium : small)
            fillTick(at: position, length: length, thickness: thickness)
            guard isMajor else { continue }
            let text = unit.label(value, step: schedule.step) as NSString
            drawLabel(text, at: position, attributes: attributes)
        }
    }

    /// One tick, measured from the strip's INNER edge — the one the canvas
    /// is on, so the ticks point at what they measure.
    private func fillTick(at position: CGFloat, length: CGFloat, thickness: CGFloat) {
        switch orientation {
        case .horizontal:
            NSRect(x: position, y: thickness - length - 1, width: 1, height: length).fill()
        case .vertical:
            NSRect(x: thickness - length - 1, y: position, width: length, height: 1).fill()
        }
    }

    /// Labels sit 2 pt clear of the OUTER edge and start 2 pt AFTER their own
    /// tick, so both strips read the same way: the number belongs to the tick
    /// it follows.
    ///
    /// THE ROTATION IS NEGATIVE BECAUSE THE VIEW IS FLIPPED. `draw(at:)`
    /// lays a glyph run out along local +x with the box below the anchor,
    /// and in this flipped context a +90 turn sends local +y to view -x — so
    /// the whole label landed at NEGATIVE x, outside the 18 pt strip, where
    /// the clip discarded it: the left ruler drew ticks and never a numeral.
    /// -90 sends local +y to view +x, which puts the glyph box at x 1…12
    /// inside the strip and runs the text bottom-to-top, the direction every
    /// editor's vertical ruler reads in. Measured, not reasoned: rendering
    /// "1200" through each transform into a flipped 18 × 140 strip gives NO
    /// INK for +90 and ink at x 3.5…9.5 for -90.
    ///
    /// Because the text then advances towards -y, the anchor carries the
    /// label's own WIDTH: without it the number would run UP from its tick
    /// (the mirror image of the horizontal strip, and the ruler's first
    /// label would be clipped off the top of the strip).
    private func drawLabel(
        _ text: NSString, at position: CGFloat, attributes: [NSAttributedString.Key: Any]
    ) {
        switch orientation {
        case .horizontal:
            text.draw(at: CGPoint(x: position + 2, y: 1), withAttributes: attributes)
        case .vertical:
            guard let context = NSGraphicsContext.current else { return }
            context.saveGraphicsState()
            let width = text.size(withAttributes: attributes).width
            let transform = NSAffineTransform()
            transform.translateX(by: 1, yBy: position + 2 + width)
            transform.rotate(byDegrees: -90)
            transform.concat()
            text.draw(at: .zero, withAttributes: attributes)
            context.restoreGraphicsState()
        }
    }

    private func drawPointerMark() {
        guard let position = pointer, let point = stripPoint(canvas: position) else { return }
        DS.textStrong.withAlphaComponent(0.7).setFill()
        switch orientation {
        case .horizontal:
            NSRect(x: point.rounded(), y: 0, width: 1, height: bounds.height).fill()
        case .vertical:
            NSRect(x: 0, y: point.rounded(), width: bounds.width, height: 1).fill()
        }
    }

    // MARK: - Dragging a guide out

    override func mouseDown(with event: NSEvent) {
        guard let point = canvasPoint(event) else { return }
        // The canvas takes the keyboard, exactly as `ImageCanvasView`'s own
        // `mouseDown` does and for the same reason: the drag this press
        // starts is cancelled with Escape and deleted with ⌫, and BOTH are
        // implemented in `ImageCanvasView.keyDown`. Without this the first
        // responder stays wherever it was — an options-bar number field
        // after any options edit, or a fresh window's initial key view — and
        // a bare ⌫ edits that field's text instead of deleting the guide.
        // The strip itself keeps the mouse-down, so the rest of the drag
        // still arrives here.
        canvas?.window?.makeFirstResponder(canvas)
        onDragOut?(guideOrientation, point)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let point = canvasPoint(event) else { return }
        onDragUpdate?(point, event.modifierFlags)
    }

    override func mouseUp(with event: NSEvent) {
        onDragEnd?()
    }

    override func resetCursorRects() {
        // The cursor shows which way the guide this drag would create moves:
        // out of the top strip comes a horizontal guide, which slides up and
        // down.
        addCursorRect(
            bounds, cursor: orientation == .horizontal ? .resizeUpDown : .resizeLeftRight)
    }
}

// MARK: - The corner box

/// The square where the two strips meet: DRAG to set the ruler origin,
/// DOUBLE-CLICK to reset it to the canvas's top-left. Photoshop's gesture,
/// and the only place either is offered.
final class RulerCornerView: NSView {
    weak var canvas: ImageCanvasView?

    /// A drag tick (`committing` false) or the mouse-up that lands it
    /// (`committing` true), in canvas coordinates.
    var onOriginDrag: ((CGPoint, Bool) -> Void)?
    /// Double-click: back to (0, 0).
    var onReset: (() -> Void)?

    init() {
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("RulerCornerView does not support NSCoder")
    }

    /// True for the rest of a gesture that began as a double-click, so the
    /// reset is not immediately overwritten by a stray drag.
    private var resetting = false

    /// True once the pointer has actually MOVED since the press. A bare
    /// click in the corner box must set no origin: the press point converts
    /// to a canvas coordinate above and left of the canvas, so committing it
    /// would ask for an origin the document has to refuse — a beep, or an
    /// undo step, for a gesture the user did not make. The preview starts on
    /// the first movement for the same reason: there is nothing to show
    /// while nothing has moved.
    private var dragged = false

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        DS.chromeBackground.setFill()
        bounds.fill()
        DS.border.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill()
        // A small corner wedge, so the box reads as a handle rather than as
        // a gap between the two strips.
        DS.borderStrong.withAlphaComponent(0.6).setFill()
        let inset = bounds.insetBy(dx: bounds.width * 0.32, dy: bounds.height * 0.32)
        let wedge = NSBezierPath()
        wedge.move(to: CGPoint(x: inset.minX, y: inset.maxY))
        wedge.line(to: CGPoint(x: inset.maxX, y: inset.maxY))
        wedge.line(to: CGPoint(x: inset.maxX, y: inset.minY))
        wedge.close()
        wedge.fill()
    }

    private func canvasPoint(_ event: NSEvent) -> CGPoint? {
        guard let canvas = canvas else { return nil }
        return canvas.convert(convert(event.locationInWindow, from: nil), from: self)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            resetting = true
            onReset?()
            return
        }
        resetting = false
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !resetting, let point = canvasPoint(event) else { return }
        dragged = true
        onOriginDrag?(point, false)
    }

    override func mouseUp(with event: NSEvent) {
        guard !resetting, dragged, let point = canvasPoint(event) else { return }
        dragged = false
        onOriginDrag?(point, true)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }
}
