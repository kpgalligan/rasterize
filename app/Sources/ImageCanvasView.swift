import AppKit

/// The document view inside the editor's scroll view. Flipped so that view
/// coordinates equal image pixel coordinates at 100% magnification. The
/// view's frame (pixel size in points) is managed by EditorViewController.
final class ImageCanvasView: NSView {
    var image: CGImage? {
        didSet { needsDisplay = true }
    }

    /// When non-nil, drawn instead of `image` (live-preview sheets).
    var previewImage: CGImage? {
        didSet { needsDisplay = true }
    }

    /// Current selection in image pixel coordinates; always integral and
    /// clamped to the image bounds.
    private(set) var selectionRect: CGRect?

    var onSelectionChange: ((CGRect?) -> Void)?

    private var dragAnchor: CGPoint?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private static let checkerboardColor: NSColor = {
        let tile = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            NSColor(white: 0.84, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 10, height: 10).fill()
            NSRect(x: 10, y: 10, width: 10, height: 10).fill()
            return true
        }
        return NSColor(patternImage: tile)
    }()

    private var magnification: CGFloat {
        max(enclosingScrollView?.magnification ?? 1, 0.001)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        // Checkerboard under the image rect (the view's bounds are exactly
        // the image rect).
        Self.checkerboardColor.setFill()
        bounds.intersection(dirtyRect).fill()

        if let cgImage = previewImage ?? image {
            let context = NSGraphicsContext.current!.cgContext
            context.saveGState()
            context.interpolationQuality = magnification >= 1.0 ? .none : .high
            // Un-flip the context so the CGImage is not drawn upside down.
            context.translateBy(x: 0, y: bounds.height)
            context.scaleBy(x: 1, y: -1)
            context.draw(cgImage, in: CGRect(origin: .zero, size: bounds.size))
            context.restoreGState()
        }

        if let selection = selectionRect {
            drawSelection(selection)
        }
    }

    private func drawSelection(_ selection: CGRect) {
        // Dim everything outside the selection.
        let dimPath = NSBezierPath(rect: bounds)
        dimPath.appendRect(selection)
        dimPath.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.35).setFill()
        dimPath.fill()

        // Hairline double stroke: dashed white over black, offset dash phase.
        let scale = magnification
        let lineWidth = 1 / scale
        let dashPattern: [CGFloat] = [4 / scale, 4 / scale]

        let blackPath = NSBezierPath(rect: selection)
        blackPath.lineWidth = lineWidth
        blackPath.setLineDash(dashPattern, count: dashPattern.count, phase: 0)
        NSColor.black.setStroke()
        blackPath.stroke()

        let whitePath = NSBezierPath(rect: selection)
        whitePath.lineWidth = lineWidth
        whitePath.setLineDash(dashPattern, count: dashPattern.count, phase: 4 / scale)
        NSColor.white.setStroke()
        whitePath.stroke()
    }

    // MARK: - Selection

    func setSelection(_ rect: CGRect?) {
        var clamped: CGRect? = nil
        if let rect = rect {
            let bounded = rect.integral.intersection(CGRect(origin: .zero, size: bounds.size))
            if !bounded.isEmpty, bounded.width >= 1, bounded.height >= 1 {
                clamped = bounded
            }
        }
        selectionRect = clamped
        needsDisplay = true
        onSelectionChange?(clamped)
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        dragAnchor = clamp(point: convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor = dragAnchor else { return }
        let point = clamp(point: convert(event.locationInWindow, from: nil))
        setSelection(rect(from: anchor, to: point))
    }

    override func mouseUp(with event: NSEvent) {
        guard let anchor = dragAnchor else { return }
        dragAnchor = nil
        let point = clamp(point: convert(event.locationInWindow, from: nil))
        let dragged = rect(from: anchor, to: point)
        // The click-vs-drag threshold is ~2 SCREEN points; `dragged` is in
        // image pixels, so scale by the current magnification. Otherwise a
        // deliberate 1-px-wide selection is impossible at high zoom, and at
        // low zoom a jittery click commits a many-pixel accidental selection.
        let scale = magnification
        if dragged.width * scale < 2 || dragged.height * scale < 2 {
            // Treat a tiny drag as click-to-deselect.
            setSelection(nil)
        } else {
            setSelection(dragged)
        }
    }

    private func clamp(point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, 0), bounds.width),
            y: min(max(point.y, 0), bounds.height))
    }

    private func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(a.x - b.x),
            height: abs(a.y - b.y))
    }

    // MARK: - Keyboard and cursor

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            setSelection(nil)
        } else {
            super.keyDown(with: event)
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }
}
