import AppKit

/// The canvas's guide drawing and its hover cursor. The view is frozen, so
/// the drawing lives here and `draw` keeps only its one-line call — the
/// `CropTool` / `ShapeTool` arrangement.
extension ImageCanvasView {
    /// Every visible guide, one `1 / magnification` hairline each, in the
    /// preference colour; the guide currently under a drag draws DASHED, so
    /// a move reads as provisional.
    ///
    /// A guide cannot extend past the canvas edge: this view force-overrides
    /// `clipsToBounds` to true (text sessions must never show glyphs the
    /// image-sized commit would discard), so anything drawn here is
    /// invisible outside 0…width / 0…height. Photoshop draws its guides
    /// across the pasteboard too; doing that here would need a separate
    /// overlay view above the clip view. That is a stated design
    /// consequence, not an oversight to fix silently.
    ///
    /// The hairline is centred ON the coordinate rather than offset half a
    /// pixel, because a guide's position is a GRID-LINE coordinate, not a
    /// pixel index (`CanvasGuide`): at 800 % a guide at x = 250 draws down
    /// the boundary between pixel 249 and pixel 250, which is exactly the
    /// edge a `.wholePixels` snap lands a crop box or a marquee on.
    func drawGuides() {
        guard chrome.guidesVisible else { return }
        let scale = magnification
        let color = chrome.guideColor.color
        for guide in guides {
            // The guide under the drag is drawn from the SESSION below, at
            // its live position; drawing it here as well would leave a
            // ghost at the position it no longer has.
            if let drag = guideDrag, !drag.isNew, drag.guideID == guide.id { continue }
            strokeGuideLine(
                at: guide.position, orientation: guide.orientation, color: color,
                scale: scale, dashed: false)
        }
        // A guide on its way back into a ruler stops drawing — that IS the
        // feedback that releasing there deletes it.
        if let drag = guideDrag, !drag.willDelete {
            strokeGuideLine(
                at: drag.position, orientation: drag.orientation, color: color,
                scale: scale, dashed: true)
        }
    }

    /// While the ruler corner box is being dragged, a crosshair at the
    /// pending origin in the guide colour's accent — the drag's only live
    /// feedback on the canvas, alongside both strips' pointer marks, which
    /// move on the same tick because they describe the same point.
    ///
    /// Dashed and in the ACCENT colour, so it can never be mistaken for a
    /// guide it happens to sit on: it is a preview of a coordinate frame,
    /// not a line that will still be there when the mouse comes up.
    func drawRulerOriginCrosshair() {
        guard let origin = rulerOriginDrag else { return }
        let scale = magnification
        let path = NSBezierPath()
        path.move(to: CGPoint(x: origin.x, y: 0))
        path.line(to: CGPoint(x: origin.x, y: bounds.height))
        path.move(to: CGPoint(x: 0, y: origin.y))
        path.line(to: CGPoint(x: bounds.width, y: origin.y))
        path.lineWidth = 1 / scale
        let dash: [CGFloat] = [5 / scale, 3 / scale]
        path.setLineDash(dash, count: dash.count, phase: 0)
        chrome.guideColor.smartColor.setStroke()
        path.stroke()
    }

    /// One guide's line across the whole canvas.
    private func strokeGuideLine(
        at position: CGFloat, orientation: GuideOrientation, color: NSColor,
        scale: CGFloat, dashed: Bool
    ) {
        let path = NSBezierPath()
        switch orientation {
        case .vertical:
            path.move(to: CGPoint(x: position, y: 0))
            path.line(to: CGPoint(x: position, y: bounds.height))
        case .horizontal:
            path.move(to: CGPoint(x: 0, y: position))
            path.line(to: CGPoint(x: bounds.width, y: position))
        }
        path.lineWidth = 1 / scale
        if dashed {
            let dash: [CGFloat] = [4 / scale, 4 / scale]
            path.setLineDash(dash, count: dash.count, phase: 0)
        }
        color.setStroke()
        path.stroke()
    }

    /// Whether a press (or a hover) at this instant may take hold of a
    /// guide at all — the ONE predicate `mouseDown`'s intercept and
    /// `updateGuideHoverCursor` both read, so the cursor can never promise a
    /// grab the press will not honour.
    ///
    /// WHICH TOOLS OWN A GUIDE. Photoshop's rule: the MOVE tool grabs a
    /// guide, and any other tool borrows that grab while ⌘ is held. The
    /// alternative this replaced — every tool but zoom and hand — made a
    /// 5-screen-point dead band along every visible guide in which a brush
    /// stroke, a text click, a fill, a gradient or a marquee silently became
    /// a guide move (20 canvas pixels wide at 25 %), with no modifier to
    /// bypass it. Painting up against a guide is the workflow guides exist
    /// for, so it must be the press's default and the guide grab the one
    /// that asks. ⌘ is free on this view: no canvas mouse path reads it.
    ///
    /// The rest of the gate is unchanged. Hidden and LOCKED guides are not
    /// hit-tested (a line you cannot see must not move your drag; a locked
    /// guide simply is not there for the mouse, and the press falls through
    /// to the tool). Zoom and hand are never interrupted, ⌘ or not: they
    /// change what you see and never the document. A crop or shape-edit
    /// session owns the canvas's presses, and its handles sit exactly where
    /// a guide the user aligned them to would be.
    func canGrabGuide(_ modifiers: NSEvent.ModifierFlags) -> Bool {
        guard chrome.guidesVisible, !chrome.guidesLocked else { return false }
        // A Free Transform is modal over the tools — `mouseDown` returns to
        // it above this intercept, and `resetCursorRects` gives the box its
        // own arrow — so the answer here is no, and the two agree literally
        // rather than by the order two files happen to be written in.
        guard !isTransforming, cropOverlay == nil, shapeEditOverlay == nil else { return false }
        guard tool != .zoom, tool != .hand else { return false }
        return tool == .move || modifiers.contains(.command)
    }

    /// Sets `guideHoverCursor` from the guide (if any) under `point`, and
    /// invalidates the cursor rects ONLY when the value actually changed.
    ///
    /// This is the whole hover-cursor mechanism, and it has to work this way:
    /// every existing `NSCursor.set()` in the canvas is inside a
    /// `mouseDown`/`mouseDragged`, where AppKit is not re-applying cursor
    /// rects, while HOVERING is governed by `resetCursorRects` — which
    /// installs ONE cursor rect over the whole bounds and is re-applied by
    /// four existing `invalidateCursorRects` sites, any of which would put
    /// the tool's own cursor straight back over the guide. The
    /// change-guarded invalidation is `setHoverPoint`'s shape, for the same
    /// reason: an unguarded call on every mouse-moved event is a cursor-rect
    /// rebuild at pointer rate.
    func updateGuideHoverCursor(at point: CGPoint, modifiers: NSEvent.ModifierFlags) {
        let wanted: NSCursor?
        if canGrabGuide(modifiers), guideDrag == nil,
           let guide = GuideHitTest.guide(
               at: point, in: guides, magnification: magnification)
        {
            // The cursor shows which way the guide moves, so a vertical
            // (constant-x) guide gets the left-right arrows.
            wanted = guide.orientation == .vertical
                ? GuideCursors.vertical : GuideCursors.horizontal
        } else {
            // Every gate `mouseDown` applies is applied here through the one
            // predicate above: a guide that cannot be grabbed — hidden,
            // locked, under the wrong tool, behind a crop or shape-edit
            // session — must not change the cursor either, or the pointer
            // promises a grab the press will not honour. (⌘ is read from
            // the moved event's own flags, so the hand appears on the next
            // pointer move after the key goes down, and the press itself is
            // always decided by the flags it carries.)
            wanted = nil
        }
        guard wanted !== guideHoverCursor else { return }
        guideHoverCursor = wanted
        window?.invalidateCursorRects(for: self)
    }

    /// Drops the hover cursor when the pointer leaves the canvas altogether
    /// (`mouseExited`). A far-away point handed to the method above is NOT a
    /// substitute: at 100 % a guide on the canvas edge is still inside the
    /// 5-screen-point tolerance of a point just outside it, so the exit
    /// would install the grab cursor rather than clear it.
    func clearGuideHoverCursor() {
        guard guideHoverCursor != nil else { return }
        guideHoverCursor = nil
        window?.invalidateCursorRects(for: self)
    }
}

/// The two cursors a guide hover installs, held as `static let`s so the
/// change guard above can compare by IDENTITY.
///
/// `NSCursor.resizeLeftRight` is a class property, and nothing documents it
/// as returning one shared instance; if it minted a new object per call, a
/// `!==` guard against it would be true on every mouse-moved event and would
/// rebuild the window's cursor rects at pointer rate — the exact cost the
/// guard exists to avoid. Resolving each one exactly once removes the
/// question.
private enum GuideCursors {
    /// A vertical (constant-x) guide slides left and right.
    static let vertical = NSCursor.resizeLeftRight
    /// A horizontal (constant-y) guide slides up and down.
    static let horizontal = NSCursor.resizeUpDown
}
