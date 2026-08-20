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
}
