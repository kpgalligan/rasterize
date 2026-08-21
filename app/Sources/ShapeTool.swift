import AppKit

/// The style a shape drags with — the options bar's fill, stroke, weight
/// and corner radius, resolved to native types and kept current on the
/// canvas by EditorViewController.
struct ShapeToolStyle {
    var fill: NSColor? = NSColor(srgbRed: 0xC9 / 255, green: 0x6F / 255, blue: 0x4A / 255, alpha: 1)
    var stroke: NSColor? = NSColor(srgbRed: 0xE8 / 255, green: 0xE2 / 255, blue: 0xD4 / 255, alpha: 1)
    var strokeWidth: CGFloat = 2
    var radius: CGFloat = 8
}

/// A shape drag in flight: the normalized box, the line's diagonal
/// direction, and the style to draw with. Built fresh on every drag tick;
/// the commit hands the box (and `flipped`) to the editor, which renders
/// the real layer through ShapeLayer.
struct ShapeToolPreview {
    let kind: EditorTool
    let box: CGRect
    /// Line only: true when it runs bottom-left → top-right.
    let flipped: Bool
    let style: ShapeToolStyle

    /// Geometry from a drag: Shift constrains rect/ellipse to a square and
    /// a line to the nearer of horizontal / vertical / 45°.
    init(kind: EditorTool, from anchor: CGPoint, to point: CGPoint,
         constrained: Bool, style: ShapeToolStyle) {
        self.kind = kind
        self.style = style
        var dx = point.x - anchor.x
        var dy = point.y - anchor.y
        if constrained {
            if kind == .shapeLine {
                // Snap to the nearest 45° step by flattening the smaller
                // component (or equalizing, for the diagonals).
                if abs(dx) > abs(dy) * 2 {
                    dy = 0
                } else if abs(dy) > abs(dx) * 2 {
                    dx = 0
                } else {
                    let side = max(abs(dx), abs(dy))
                    dx = dx < 0 ? -side : side
                    dy = dy < 0 ? -side : side
                }
            } else {
                let side = max(abs(dx), abs(dy))
                dx = dx < 0 ? -side : side
                dy = dy < 0 ? -side : side
            }
        }
        let end = CGPoint(x: anchor.x + dx, y: anchor.y + dy)
        box = CGRect(
            x: min(anchor.x, end.x), y: min(anchor.y, end.y),
            width: abs(dx), height: abs(dy))
        // Up-right and down-left drags run bottom-left → top-right.
        flipped = kind == .shapeLine && dx != 0 && dy != 0 && (dx < 0) != (dy < 0)
    }

    /// Direct geometry (no drag): the shape-edit session's overlay.
    init(kind: EditorTool, box: CGRect, flipped: Bool, style: ShapeToolStyle) {
        self.kind = kind
        self.box = box
        self.flipped = kind == .shapeLine ? flipped : false
        self.style = style
    }
}

/// A shape layer reopened for editing (the layers panel's double-click):
/// which layer, the box being adjusted in canvas coordinates, and the drag
/// in flight. Owned by EditorViewController (the +Shapes extension drives
/// it); the canvas draws `shapeEditOverlay` and routes the gesture, the
/// crop session's division of labor. Styling is deliberately NOT here — the
/// session reads the options bar's live shape style, which editShapeLayer
/// seeds from the layer's own payload on open.
struct ShapeEditSession {
    /// What a drag on the session does, decided at mouse-down.
    enum Drag {
        /// Dragging a handle; the raw value indexes `CropSession.handles`.
        case handle(Int, start: CGRect)
        /// Dragging the interior: moves the whole box.
        case move(grab: CGPoint, start: CGRect)
    }

    let layer: Int
    /// One of ShapeLayerPayload.kinds; a re-edit never changes it.
    let kind: String
    var box: CGRect
    var flipped: Bool
    var drag: Drag?
    /// Where the current drag pressed down, for the click-vs-drag slop
    /// test (jitter inside a double-click must not count as a drag).
    var pressPoint: CGPoint?
    /// True once the box or the style changed; an untouched session
    /// commits nothing (no phantom undo step).
    var dirty = false
}

// MARK: - Canvas drawing

extension ImageCanvasView {
    /// The live drag preview: the exact fill and stroke the commit will
    /// render, so what is dragged is what lands.
    func drawShapePreview(_ preview: ShapeToolPreview) {
        let path: NSBezierPath
        switch preview.kind {
        case .shapeEllipse:
            path = NSBezierPath(ovalIn: preview.box)
        case .shapeLine:
            path = NSBezierPath()
            let box = preview.box
            if preview.flipped {
                path.move(to: CGPoint(x: box.minX, y: box.maxY))
                path.line(to: CGPoint(x: box.maxX, y: box.minY))
            } else {
                path.move(to: CGPoint(x: box.minX, y: box.minY))
                path.line(to: CGPoint(x: box.maxX, y: box.maxY))
            }
        default:
            let radius = min(preview.style.radius, min(preview.box.width, preview.box.height) / 2)
            path = NSBezierPath(roundedRect: preview.box, xRadius: radius, yRadius: radius)
        }
        if preview.kind != .shapeLine, let fill = preview.style.fill {
            fill.setFill()
            path.fill()
        }
        if let stroke = preview.style.stroke, preview.style.strokeWidth > 0 {
            path.lineWidth = preview.style.strokeWidth
            path.lineCapStyle = .round
            stroke.setStroke()
            path.stroke()
        }
    }

    /// A reopened shape's editing chrome: the live preview plus a hairline
    /// box and the eight handles (the crop box's layout and style, so
    /// handles read the same everywhere).
    func drawShapeEditOverlay(_ preview: ShapeToolPreview) {
        drawShapePreview(preview)
        let scale = magnification
        let box = NSBezierPath(rect: preview.box)
        box.lineWidth = 3 / scale
        NSColor.black.withAlphaComponent(0.45).setStroke()
        box.stroke()
        box.lineWidth = 1 / scale
        NSColor.white.withAlphaComponent(0.95).setStroke()
        box.stroke()

        let size = ImageCanvasView.transformHandleSize / scale
        for point in CropSession.handles(of: preview.box) {
            let square = NSBezierPath(
                rect: CGRect(
                    x: point.x - size / 2, y: point.y - size / 2, width: size, height: size))
            NSColor.white.setFill()
            square.fill()
            square.lineWidth = 1 / scale
            NSColor.black.withAlphaComponent(0.65).setStroke()
            square.stroke()
        }
    }
}
