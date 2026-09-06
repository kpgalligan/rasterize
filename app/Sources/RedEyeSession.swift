import AppKit

/// The Red Eye tool's drag, on the TransformSession / SubjectSession pattern:
/// the canvas owns one and only points it at events, so the frozen view takes
/// four forwarding lines instead of two stored properties, a marquee draw and
/// a threshold test. The rectangle it hands back goes to
/// `EditorViewController+RedEye.redEyeRectDragged`, which is the only place
/// that knows what a rectangle means.
///
/// Photoshop's gesture, and the one the README documents: drag a TIGHT
/// rectangle over one eye. The rect is the core op's whole domain — the
/// redness test shapes the mask inside it and the pupil-size gate measures
/// against its shorter side — so the feedback while dragging is simply the
/// rectangle itself, in the canvas's own dashed-marquee vocabulary.
struct RedEyeSession {
    /// Where the drag started and where the pointer is now, both in canvas
    /// coordinates (the canvas clamps them, so the rect never leaves the
    /// image). nil between drags, which is also what makes `draw` inert.
    private var anchor: CGPoint?
    private var current: CGPoint?

    /// A drag shorter than this on either side is a misclick, not a
    /// rectangle. Measured in CANVAS pixels rather than screen points — the
    /// signature carries no magnification, and canvas pixels are the right
    /// unit anyway: a rectangle under 2 px on a side cannot contain a pupil
    /// at any zoom, and at 100 % (where the canvas's coordinates are screen
    /// points) this is the same ~2-point threshold the gradient and shape
    /// gestures use.
    private static let minimumSide: CGFloat = 2

    mutating func mouseDown(_ point: CGPoint) {
        anchor = point
        current = point
    }

    mutating func mouseDragged(_ point: CGPoint) {
        guard anchor != nil else { return }
        current = point
    }

    /// nil when the drag never exceeded the ~2-screen-point threshold.
    mutating func mouseUp(_ point: CGPoint) -> CGRect? {
        guard let anchor = anchor else { return nil }
        let box = Self.rect(from: anchor, to: point)
        cancel()
        guard box.width >= Self.minimumSide, box.height >= Self.minimumSide else { return nil }
        return box
    }

    mutating func cancel() {
        anchor = nil
        current = nil
    }

    /// The rectangle under the pointer, in the selection marquee's own style:
    /// a black dashed hairline with a white one dashed out of phase on top,
    /// both scaled by 1/magnification so they stay the same width on screen
    /// at any zoom (drawSelection's rule, and drawActiveLayerBounds's exact
    /// dash pattern).
    func draw(in context: CGContext, magnification: CGFloat) {
        guard let anchor = anchor, let current = current else { return }
        let box = Self.rect(from: anchor, to: current)
        guard box.width > 0 || box.height > 0 else { return }
        let scale = max(magnification, 0.001)
        let dash: [CGFloat] = [4 / scale, 4 / scale]
        context.saveGState()
        context.setLineWidth(1 / scale)
        context.setLineDash(phase: 0, lengths: dash)
        context.setStrokeColor(NSColor.black.cgColor)
        context.stroke(box)
        context.setLineDash(phase: 4 / scale, lengths: dash)
        context.setStrokeColor(NSColor.white.cgColor)
        context.stroke(box)
        context.restoreGState()
    }

    /// The normalized box between two corners — the canvas's own `rect(from:
    /// to:)`, which is private to that file; two lines rather than widening
    /// a frozen file's surface for them.
    private static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(
            x: min(a.x, b.x), y: min(a.y, b.y),
            width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}
