import AppKit

/// What the canvas draws for a crop session: the box, the straighten angle
/// (the image rotates behind the box in the preview), and whether the
/// thirds grid shows. The session's geometry lives in
/// EditorViewController+Crop; this is only its picture.
struct CropOverlay {
    var rect: CGRect
    /// Straighten, degrees. Positive rotates the HORIZON clockwise — i.e.
    /// the image rotates counter-clockwise behind the fixed box.
    var angle: CGFloat
    var showsThirds: Bool
}

/// The crop tool's session state and geometry: the box being adjusted, the
/// drag in flight, and the ratio it is constrained to. Owned by
/// EditorViewController (the +Crop extension drives it); pure math here.
struct CropSession {
    /// What a crop drag does, decided at mouse-down.
    enum Drag {
        /// Dragging a handle; the raw value indexes `CropSession.handles`.
        case handle(Int, start: CGRect)
        /// Dragging the interior: moves the whole box.
        case move(grab: CGPoint, start: CGRect)
        /// Dragging outside the box: rubber-bands a fresh one.
        case draw(anchor: CGPoint)
    }

    var rect: CGRect
    var angle: Double = 0
    var drag: Drag?
    /// The aspect (width / height) the box is constrained to; nil is free.
    var ratio: Double?

    /// Handle order: corners TL, TR, BR, BL, then edge midpoints T, R, B, L.
    static func handles(of rect: CGRect) -> [CGPoint] {
        [
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.midY),
            CGPoint(x: rect.midX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.midY),
        ]
    }

    /// Which handle a press at `point` grabs, within `slop` image pixels;
    /// nil for none.
    static func handleIndex(at point: CGPoint, rect: CGRect, slop: CGFloat) -> Int? {
        for (index, handle) in handles(of: rect).enumerated()
        where abs(point.x - handle.x) <= slop && abs(point.y - handle.y) <= slop {
            return index
        }
        return nil
    }

    /// The box after dragging handle `index` to `point`, constrained to
    /// `ratio` (corner handles preserve it exactly; edge handles resize
    /// their axis and re-derive the other about the box's center line).
    /// Never smaller than 1×1; the caller clamps to the canvas.
    static func resizing(
        _ start: CGRect, handle index: Int, to point: CGPoint, ratio: Double?
    ) -> CGRect {
        var minX = start.minX
        var minY = start.minY
        var maxX = start.maxX
        var maxY = start.maxY
        switch index {
        case 0: minX = point.x; minY = point.y
        case 1: maxX = point.x; minY = point.y
        case 2: maxX = point.x; maxY = point.y
        case 3: minX = point.x; maxY = point.y
        case 4: minY = point.y
        case 5: maxX = point.x
        case 6: maxY = point.y
        default: minX = point.x
        }
        var rect = CGRect(
            x: min(minX, maxX), y: min(minY, maxY),
            width: max(abs(maxX - minX), 1), height: max(abs(maxY - minY), 1))
        guard let ratio = ratio, ratio > 0 else { return rect }

        // Re-derive the dependent dimension, anchored so the dragged
        // handle's opposite edge (or the center line, for edge handles)
        // stays put.
        switch index {
        case 4, 6: // top/bottom edges drive height
            let width = rect.height * ratio
            rect.origin.x = rect.midX - width / 2
            rect.size.width = width
        case 5, 7: // left/right edges drive width
            let height = rect.width / ratio
            rect.origin.y = rect.midY - height / 2
            rect.size.height = height
        default: // corners: keep the dragged width, re-derive height
            let height = rect.width / ratio
            // Anchor vertically on whichever edge the corner did not move.
            if index == 0 || index == 1 {
                rect.origin.y = rect.maxY - height
            }
            rect.size.height = height
        }
        return rect
    }

    /// `rect` pinned inside the canvas, preserving size where possible.
    /// With a `ratio`, an oversize box scales down UNIFORMLY to fit rather
    /// than clamping each axis on its own (which would silently break the
    /// constraint the box was just built to).
    static func clamped(_ rect: CGRect, to canvas: CGSize, ratio: Double? = nil) -> CGRect {
        var rect = rect
        if ratio != nil, rect.width > 0, rect.height > 0 {
            let scale = min(canvas.width / rect.width, canvas.height / rect.height, 1)
            rect.size.width *= scale
            rect.size.height *= scale
        }
        rect.size.width = min(max(rect.width, 1), canvas.width)
        rect.size.height = min(max(rect.height, 1), canvas.height)
        rect.origin.x = min(max(rect.origin.x, 0), canvas.width - rect.width)
        rect.origin.y = min(max(rect.origin.y, 0), canvas.height - rect.height)
        return rect
    }
}

// MARK: - Canvas drawing

extension ImageCanvasView {
    /// The crop overlay: everything outside the box dimmed, a hairline box,
    /// eight handles (the transform box's style, so handles read the same
    /// everywhere), and the thirds grid when asked for.
    func drawCropOverlay(_ overlay: CropOverlay) {
        let rect = overlay.rect
        let dim = NSBezierPath(rect: bounds)
        dim.append(NSBezierPath(rect: rect))
        dim.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.5).setFill()
        dim.fill()

        let scale = magnification
        let box = NSBezierPath(rect: rect)
        box.lineWidth = 3 / scale
        NSColor.black.withAlphaComponent(0.45).setStroke()
        box.stroke()
        box.lineWidth = 1 / scale
        NSColor.white.withAlphaComponent(0.95).setStroke()
        box.stroke()

        if overlay.showsThirds {
            let thirds = NSBezierPath()
            for third in [1.0, 2.0] {
                let x = rect.minX + rect.width * third / 3
                let y = rect.minY + rect.height * third / 3
                thirds.move(to: CGPoint(x: x, y: rect.minY))
                thirds.line(to: CGPoint(x: x, y: rect.maxY))
                thirds.move(to: CGPoint(x: rect.minX, y: y))
                thirds.line(to: CGPoint(x: rect.maxX, y: y))
            }
            thirds.lineWidth = 1 / scale
            NSColor.white.withAlphaComponent(0.35).setStroke()
            thirds.stroke()
        }

        let size = ImageCanvasView.transformHandleSize / scale
        for point in CropSession.handles(of: rect) {
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
