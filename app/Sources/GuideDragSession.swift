import AppKit

/// A guide drag in flight — dragged out of a ruler, or grabbed on the canvas
/// and moved. The `PatchSession` / `TransformSession` pattern: one stored
/// property on the canvas, all the geometry here.
///
/// WHOLE PIXELS. A guide created or moved BY A DRAG commits an INTEGER
/// position, and its own snapping runs `.wholePixels`, so the two always
/// agree. `rulerDragOut` turns a pointer into canvas space, so an unrounded
/// drag would place a guide at x = 250.37 — and then every `.wholePixels`
/// snap site (the crop box, the rect marquee, the Move drag) would pull to
/// 250, half a pixel off the line the user can see, which is plainly visible
/// at 800 % with the pixel grid on. `add_guide`, `move_guide` and the New
/// Guide sheet are deliberately NOT rounded: the core stores f64 precisely so
/// an Image Size round trip does not walk a guide off its feature, and a
/// typed or computed position is an exact request. (The argument is
/// `PatchSession`'s, one file over, for the same kind of decision.)
///
/// The document is NOT touched mid-gesture: the live position lives here and
/// the edit lands once, at mouse-up, through `ImageDocument.applyGuideEdit`.
/// Going through `beginLiveEdit`/`updateLiveEdit` would re-flatten the whole
/// document on every mouse-moved event for a change that moves no pixel.
struct GuideDragSession {
    /// Which way the dragged guide runs.
    let orientation: GuideOrientation
    /// The core's stable id of the guide being moved; 0 for a guide dragged
    /// out of a ruler, which does not exist yet. An index would not do: the
    /// list re-sorts by position on every edit.
    let guideID: UInt64
    /// True when the drag is creating a guide rather than moving one.
    let isNew: Bool
    /// The position the guide had when the drag began, in canvas
    /// coordinates on its own axis — what Escape restores.
    let startPosition: CGFloat
    /// Where the press landed, in canvas coordinates — the point the
    /// misclick threshold below is measured from.
    let pressPoint: CGPoint
    /// How far the PRESS sat from the guide's line, on the guide's own axis.
    ///
    /// The grab tolerance is 5 screen points, so a press is almost never
    /// exactly on the line; without this the guide would jump to the pointer
    /// the instant it was touched — up to 5 points at any zoom, and at 800 %
    /// that is most of a pixel. Every position below is therefore the
    /// GUIDE's, `pointer − grabOffset`, never the pointer's. Zero for a
    /// guide dragged out of a ruler: there is no line to have missed yet.
    let grabOffset: CGFloat
    /// The candidate lines this drag snaps against, gathered ONCE at
    /// mouse-down and held for the whole gesture — the engine's own rule
    /// (`DragSnapping.swift`: the content-bounds fold behind the layer
    /// target is a per-pixel sweep per leaf). It must EXCLUDE the guide
    /// being dragged; see `EditorViewController.guideSnapEngine`.
    var snap: SnapEngine = .inactive
    /// The live position, updated on every tick.
    var position: CGFloat
    /// True while the pointer is outside the canvas on the guide's own axis:
    /// releasing there deletes the guide (dragging it back into its ruler),
    /// and the preview says so by not drawing.
    var willDelete: Bool
    /// True once the pointer has travelled `moveScreenPoints` from the press
    /// — TRACKED, never inferred.
    ///
    /// `RulerCornerView.dragged` is the same latch for the same hazard, and
    /// the strips need it for a reason the initializer's note below cannot
    /// cover: `RulerView.canvasPoint` converts through the LIVE scroll
    /// transform, so on a canvas scrolled under the strip a press inside the
    /// strip maps to a positive, in-canvas coordinate. Inferring "did this
    /// gesture do anything?" from that coordinate made a bare click in a
    /// ruler create a guide, an undo step and a dirty document; a
    /// double-click created two.
    ///
    /// The THRESHOLD is why zero movement is not the test. AppKit sends a
    /// `mouseDragged` for a single point of trackpad drift, so a latch that
    /// tripped on any movement at all left the same click creating the same
    /// guide — one that a scrolled canvas then puts above the visible area,
    /// invisible, with the document dirty and an undo step registered. Every
    /// other gesture in the app guards a misclick with the same 2 screen
    /// points (`ImageCanvasView.marqueeClickScreenPoints`, the shape drag's
    /// own test), so this one does too.
    var moved = false

    /// The misclick threshold, in SCREEN POINTS, so it means the same thing
    /// at every zoom — the form every other test in the canvas takes
    /// (`hypot(…) * magnification < 8`).
    static let moveScreenPoints: CGFloat = 2

    init(
        orientation: GuideOrientation, guideID: UInt64, isNew: Bool, startPosition: CGFloat,
        pressPoint: CGPoint, grabOffset: CGFloat = 0
    ) {
        self.orientation = orientation
        self.guideID = guideID
        self.isNew = isNew
        self.startPosition = startPosition
        self.pressPoint = pressPoint
        self.grabOffset = grabOffset
        self.position = startPosition
        // A guide dragged out of a ruler starts in its "will delete" state
        // unconditionally, rather than by testing the press point: the press
        // is inside the STRIP, and only on an unscrolled canvas does that
        // convert to a coordinate outside the picture. Starting `true` —
        // together with `moved`, and with mouse-up reading this flag instead
        // of re-testing the release point — is what makes "press in the
        // ruler, release without moving" create nothing at all AT EVERY
        // SCROLL POSITION.
        self.willDelete = isNew
    }

    /// The snap axis this guide's position lives on. A VERTICAL guide is a
    /// constant-x line, which is what `SnapAxis.vertical` names.
    var axis: SnapAxis { orientation == .vertical ? .vertical : .horizontal }

    /// The position the edit commits: whole pixels, per the type's note.
    var committedPosition: Double { Double(position.rounded()) }

    /// True when the drag never moved the guide at all — a click on a guide,
    /// which must commit NOTHING: no undo step, and no beep either, because
    /// nothing was refused. (Deliberately an exact comparison against the
    /// press-time position rather than a rounded one: a guide at 250.5 that
    /// the pointer never touched must not be re-committed at 250 by a click.)
    var isUnmoved: Bool { position == startPosition && !willDelete }

    /// A canvas point's coordinate on this guide's own axis.
    func coordinate(of point: CGPoint) -> CGFloat {
        orientation == .horizontal ? point.y : point.x
    }

    /// Whether releasing here drops the guide back into its ruler.
    ///
    /// TWO TESTS, AND `inRuler` DECIDES WHICH IS IN FORCE. While the rulers
    /// are showing the answer is the POINTER's and nothing else: `inRuler`
    /// is the controller's report that the pointer has reached the strip
    /// that owns this guide's orientation, asked in WINDOW coordinates
    /// (`guidePointerInRuler`). With the rulers hidden there is no strip to
    /// drop into, so `inRuler` is nil and the fallback below applies: a
    /// guide dragged off the picture is deleted.
    ///
    /// The pointer test is not a refinement, it is the correction. Deciding
    /// this from the canvas COORDINATE the pointer maps to — the only test
    /// there used to be — is right only while the canvas's edge happens to
    /// sit next to the strip, because the canvas VIEW extends under both
    /// strips whenever the document is larger than the viewport. On a
    /// zoomed-in, scrolled document a pointer 9 pt into the 18 pt strip
    /// converts to a canvas coordinate comfortably inside `[0, extent]`, so
    /// the release took the MOVE branch: the delete gesture did nothing and
    /// the guide the user was throwing away moved to a position above the
    /// visible area, invisible until they scrolled back. The mirror case
    /// broke the drag-OUT cancel the same way, clearing `willDelete` for a
    /// press-jiggle-release that never left the strip.
    ///
    /// The fallback is measured on the RAW position, never the snapped one:
    /// the canvas edge is itself a snap target, so a snapped position would
    /// stick to 0 or to the extent and a guide could not be dragged off the
    /// canvas at all within the pull radius — the delete would silently stop
    /// working near the edges, which is where it is always made.
    func isOutside(_ point: CGPoint, extent: CGFloat, inRuler: Bool?) -> Bool {
        if let inRuler = inRuler { return inRuler }
        let raw = coordinate(of: point) - grabOffset
        return !(raw >= 0 && raw <= extent)
    }

    /// One drag tick: the guide follows the pointer, snaps `.wholePixels`
    /// against the engine captured at mouse-down, and stays inside the
    /// canvas while it is not being deleted.
    ///
    /// `context` carries the live modifiers — ⌃ suspends snapping and is
    /// read per TICK, never latched at mouse-down, so a user can suspend
    /// mid-drag (Photoshop's behaviour).
    ///
    /// The LIVE position rounds too, not only `committedPosition`: with a
    /// snap the two agree anyway (the candidates are quantized before the
    /// distance test), but with nothing in range the preview would be
    /// fractional while the commit rounded, and the guide would visibly jump
    /// by up to half a pixel on release — four screen points at 800 %, right
    /// where the pixel grid makes it obvious. Rounding here makes what is
    /// drawn what is written. The extent is a whole number of pixels, so
    /// rounding can never push a position out of the canvas.
    ///
    /// `inRuler` is where the POINTER is, not where the guide would land:
    /// see `isOutside`.
    mutating func update(
        to point: CGPoint, extent: CGFloat, inRuler: Bool?, context: SnapContext
    ) {
        if !moved,
           hypot(point.x - pressPoint.x, point.y - pressPoint.y)
               * max(context.magnification, 0.001) >= Self.moveScreenPoints
        {
            moved = true
        }
        let raw = coordinate(of: point) - grabOffset
        // ONE definition of "outside", shared with the release test.
        willDelete = isOutside(point, extent: extent, inRuler: inRuler)
        guard !willDelete else {
            // Outside, the guide is on its way back into the ruler: it stops
            // drawing, so there is nothing to snap and nothing to clamp.
            position = raw
            return
        }
        let pull = snap.pull([raw], axis: axis, in: context, quantize: .wholePixels)
        let snapped = (raw + (pull ?? 0)).rounded()
        position = min(max(snapped, 0), extent)
    }
}

/// Which guide a press lands on.
enum GuideHitTest {
    /// The grab radius in SCREEN POINTS. Smaller than the 8-point handle
    /// slop on purpose, so a transform or crop handle sitting on a guide
    /// still wins its press; larger than the 1-point line so the grab is
    /// comfortable. Held in screen points and turned into canvas pixels at
    /// the moment of use (`screenPoints / magnification`), which is what
    /// makes the grab zoom-independent — the same screen-space test the
    /// canvas's own `hypot(…) * magnification < 8` makes from the other
    /// side.
    static let screenPoints: CGFloat = 5

    /// The guide under `point`, nearest first, or nil for none. A LOCKED
    /// guide is never hit-tested at all — the caller does not call this —
    /// so the press falls through to the tool underneath, exactly as in
    /// Photoshop: it is not a beep and not a refusal, the guide simply is
    /// not there for the mouse.
    ///
    /// A crossing point sits inside two guides' radii at once; the nearer
    /// line wins, and an exact tie goes to the earlier entry, which is the
    /// core's own order (orientation, then position) and therefore stable
    /// across a redraw.
    static func guide(
        at point: CGPoint, in guides: [CanvasGuide], magnification: CGFloat
    ) -> CanvasGuide? {
        let scale = max(magnification, 0.001)
        let tolerance = screenPoints / scale
        var best: CanvasGuide?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for guide in guides {
            let coordinate = guide.orientation == .horizontal ? point.y : point.x
            let distance = abs(coordinate - guide.position)
            guard distance <= tolerance, distance < bestDistance else { continue }
            best = guide
            bestDistance = distance
        }
        return best
    }
}
