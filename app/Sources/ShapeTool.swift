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
///
/// `box` is in the space `placement` maps FROM: a fresh drag's box is in
/// canvas coordinates under the identity, a reopened layer's is its LOCAL
/// box `(0, 0, w, h)` under the layer's placement (its 2×2 map with the
/// anchor as translation). Drawing the local path under the placement's
/// CTM is exactly what ShapeLayer.render does, stroke width included (a
/// source-space width scaled by the map), so the overlay is the commit.
struct ShapeToolPreview {
    let kind: EditorTool
    let box: CGRect
    /// Maps `box`'s space onto the canvas.
    let placement: CGAffineTransform
    /// Line only: true when it runs bottom-left → top-right.
    let flipped: Bool
    let style: ShapeToolStyle

    /// Geometry from a drag: Shift constrains rect/ellipse to a square and
    /// a line to the nearer of horizontal / vertical / 45°.
    init(kind: EditorTool, from anchor: CGPoint, to point: CGPoint,
         constrained: Bool, style: ShapeToolStyle) {
        self.kind = kind
        self.style = style
        self.placement = .identity
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

    /// Direct geometry (no drag): the shape-edit session's overlay — the
    /// LOCAL box under the session's placement.
    init(kind: EditorTool, box: CGRect, placement: CGAffineTransform, flipped: Bool,
         style: ShapeToolStyle) {
        self.kind = kind
        self.box = box
        self.placement = placement
        self.flipped = kind == .shapeLine ? flipped : false
        self.style = style
    }
}

/// A shape layer reopened for editing (the layers panel's double-click):
/// which layer, the box being adjusted, and the drag in flight. Owned by
/// EditorViewController (the +Shapes extension drives it); the canvas
/// draws `shapeEditOverlay` and routes the gesture, the crop session's
/// division of labor. Styling is deliberately NOT here — the session reads
/// the options bar's live shape style, which editShapeLayer seeds from the
/// layer's own payload on open.
///
/// The box lives in the shape's OWN space: `size` is the payload's
/// `w × h`, `transform` its 2×2 map, and `anchor` the exact canvas point
/// the box's top-left sits at (the layer's described anchor,
/// DescribedLayer.swift). The canvas quad is `anchor + transform·corner`,
/// so a rotated rectangle shows a rotated box, and a handle drag is
/// inverse-mapped into local space so the rectangle resizes along its own
/// axes (EditorViewController+Shapes.swift). A re-edit never changes the
/// map — only a Free Transform does.
struct ShapeEditSession {
    /// What a drag on the session does, decided at mouse-down. Both cases
    /// snapshot the geometry at mouse-down, so every tick recomputes from
    /// the snapshot rather than accumulating deltas (the crop and Free
    /// Transform rule).
    enum Drag {
        /// Dragging a handle; the raw value indexes
        /// `ImageCanvasView.transformHandlePoints(quad)` — the same
        /// TL, TR, BR, BL, T, R, B, L order as `CropSession.handles`, so
        /// `CropSession.resizing`'s index switch applies in local space.
        case handle(Int, start: (anchor: CGPoint, size: CGSize))
        /// Dragging the interior: moves the anchor by the canvas delta.
        case move(grab: CGPoint, start: CGPoint)
    }

    let layer: Int
    /// One of ShapeLayerPayload.kinds; a re-edit never changes it.
    let kind: String
    /// The exact canvas position of the local box's top-left.
    var anchor: CGPoint
    /// The anchor the session opened with — the layer's own, exact. A
    /// commit whose drags never moved it keeps it byte-for-byte
    /// (`DescribedLayer.placementAnchor(from:to:transform:)`).
    let openedAnchor: CGPoint
    /// The shape box's size in its own space (the payload's `w`, `h`).
    var size: CGSize
    /// The layer's 2×2 map, fixed for the session.
    let transform: LinearMap
    var flipped: Bool
    var drag: Drag?
    /// Where the current drag pressed down, for the click-vs-drag slop
    /// test (jitter inside a double-click must not count as a drag).
    var pressPoint: CGPoint?
    /// True once the box or the style changed; an untouched session
    /// commits nothing (no phantom undo step).
    var dirty = false

    /// The local box: the origin is the anchor by construction.
    var localBox: CGRect {
        CGRect(origin: .zero, size: size)
    }

    /// Local space → canvas: the map with the anchor as its translation —
    /// the CTM the overlay draws under and the one ShapeLayer.render
    /// effectively uses.
    var placement: CGAffineTransform {
        var placement = transform.cgAffine
        placement.tx = anchor.x
        placement.ty = anchor.y
        return placement
    }

    /// The local box's corners on the canvas (TL, TR, BR, BL).
    var quad: [CGPoint] {
        transform.quad(of: localBox, anchor: anchor)
    }
}

// MARK: - Canvas drawing

extension ImageCanvasView {
    /// The live drag preview: the exact fill and stroke the commit will
    /// render, so what is dragged is what lands. The path is built in the
    /// preview's own space and drawn under its placement, so a reopened
    /// rotated shape previews rotated — and its stroke width scales with
    /// the map exactly as the renderer's does.
    func drawShapePreview(_ preview: ShapeToolPreview) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.concatenate(preview.placement)

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
    /// box through the placed quad and the eight handles at its corners and
    /// edge midpoints (the Free Transform box's layout and style, so
    /// handles read the same everywhere). The chrome is drawn in CANVAS
    /// space, not under the placement, so the handle squares keep their
    /// screen size whatever the map.
    func drawShapeEditOverlay(_ preview: ShapeToolPreview) {
        drawShapePreview(preview)
        let corners = preview.placement.quad(of: preview.box)
        guard corners.count == 4 else { return }
        let scale = magnification
        let box = NSBezierPath()
        box.move(to: corners[0])
        for corner in corners.dropFirst() {
            box.line(to: corner)
        }
        box.close()
        box.lineWidth = 3 / scale
        NSColor.black.withAlphaComponent(0.45).setStroke()
        box.stroke()
        box.lineWidth = 1 / scale
        NSColor.white.withAlphaComponent(0.95).setStroke()
        box.stroke()

        let size = ImageCanvasView.transformHandleSize / scale
        for point in ImageCanvasView.transformHandlePoints(corners) {
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
