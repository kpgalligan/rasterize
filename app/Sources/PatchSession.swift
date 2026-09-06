import AppKit

/// The Patch tool's drag, on the SubjectSession / TransformSession pattern:
/// the canvas owns one of these and only points it at events, all of the
/// geometry and drawing lives here.
///
/// The gesture has two halves. First a REGION: either an outline clicked out
/// vertex by vertex — the polygon lasso's own rule, a double-click or a click
/// back on the first vertex closes it — or the selection that is already on
/// the canvas, adopted when the press lands inside its bounds, so a magic
/// wand or a Select Subject mask can be patched without being re-drawn by
/// hand. Then a DRAG: the region is moved, and on release the outlined
/// region takes the texture it was dragged to (direction Source, the
/// default) or the pixels it was dragged onto take the outlined region's
/// texture (direction Destination). Either way the join is the Poisson blend
/// `rz_doc_heal_layer` performs, so the moved texture arrives wearing the
/// destination's illumination.
///
/// WHOLE PIXELS. The drag offset is rounded to integers the moment it is
/// read, in the preview and in the commit alike. A fractional offset would
/// resample the source through CoreGraphics — softening exactly the texture
/// the tool exists to move, and destroying the heal's byte-exactness on a
/// smooth gradient (the solve reproduces the destination exactly only when
/// the source arrives unresampled). Sub-pixel placement buys nothing here:
/// the source is a photograph, not a vector.
struct PatchSession {
    enum Phase { case idle, drawing, placed, dragging }

    /// The committed region and how far it was dragged. `region` is a
    /// CanvasSelection because an existing selection may be an ellipse or a
    /// `.mask` (magic wand, Select Subject) that no point list can carry, and
    /// because `maskBytes()` / `clip(_:)` are the ONE route to coverage and to
    /// a CG clip — so the UI commit and the agent's patch_region consume the
    /// same type.
    struct Result {
        var region: CanvasSelection
        var offset: CGVector
    }

    /// The two displacements every patch is: where the healed region sits,
    /// and where its pixels are read from. Canvas coordinates, y down.
    struct Geometry {
        /// How far Ω — the region that gets healed — is displaced from the
        /// outline. Zero in Source, the drag offset in Destination.
        var clip: CGVector
        /// How far the SOURCE image is displaced when it is drawn, so the
        /// pixel landing on canvas point p is the snapshot's p − image.
        var image: CGVector
    }

    private(set) var phase: Phase = .idle

    /// The outline being clicked out, in canvas px and click order.
    private var outline: [CGPoint] = []
    /// The canvas the outline is being drawn over, latched at its first
    /// vertex: a CanvasSelection cannot be built without it.
    private var canvasWidth = 0
    private var canvasHeight = 0

    /// The closed region, once there is one — outlined here or adopted from
    /// the canvas's selection.
    private var region: CanvasSelection?

    /// The pixels the drag PREVIEWS from when they are not the canvas's own
    /// composite, latched whenever a region becomes placed — the press that
    /// precedes every drag, so never a per-tick cost. nil means the composite
    /// the canvas hands `draw` anyway, which is what Sample All Layers ON —
    /// the default — takes, and it stays live that way.
    ///
    /// It exists for the option turned OFF: the commit then heals from the
    /// active layer's own pixels, so drawing the composite showed the upper
    /// layers' texture landing while the release took what was underneath
    /// it — and where that layer is transparent the release changed nothing
    /// at all. The drag has to show what will be taken.
    private var snapshot: CGImage?

    /// Where the press that owns the current drag went down, and where the
    /// pointer is now. Both canvas px.
    private var dragAnchor: CGPoint = .zero
    private var dragCurrent: CGPoint = .zero

    /// A click within this many SCREEN points of the first vertex closes the
    /// outline — the canvas's own lasso rule (`ImageCanvasView.mouseDown`'s
    /// `hypot(…) * magnification < 8`), verbatim, because the two tools draw
    /// the identical gesture and must answer it identically. Stating it in
    /// canvas px instead made the same click behave differently at every zoom:
    /// at 25 % it wanted a hit inside 2 screen points, which is unhittable, and
    /// at 400 % it closed on a click 32 screen points off the vertex.
    /// Double-clicking closes at any distance, which is the gesture that never
    /// depends on the zoom — and the one the README names.
    private static let closeScreenRadius: CGFloat = 8

    /// The drag offset, rounded to whole canvas pixels (see the type's note
    /// on why). Zero unless a drag is under way.
    private var offset: CGVector {
        guard phase == .dragging else { return .zero }
        return CGVector(
            dx: (dragCurrent.x - dragAnchor.x).rounded(),
            dy: (dragCurrent.y - dragAnchor.y).rounded())
    }

    /// The Direction option — Destination when set, Source (the default)
    /// otherwise — read where it is used rather than pushed in. THE one place
    /// the stored index becomes a direction: the drag's feedback and the
    /// commit (EditorViewController+Patch) both ask here, so they cannot
    /// disagree about which end of the drag is being healed.
    ///
    /// The canvas forwards `draw(in:image:magnification:)` with no direction
    /// — and it is frozen, so a pushed flag would cost an edit there and a
    /// second one in `syncCanvasPaintState` — while the option's setter
    /// (EditorViewController+ToolOptions.patchClusters) writes nowhere but
    /// this store. Reading it here is what lets the drag show what will
    /// actually be taken in BOTH directions, and nothing can change the
    /// option mid-press.
    static var isDestination: Bool {
        ToolOptionsStore.shared.patch.directionIndex == 1
    }

    /// `selection` is the canvas's current selection, forwarded so the tool
    /// can adopt an existing one instead of demanding a fresh outline;
    /// `magnification` is the canvas's, so the closing click is measured in
    /// the screen points the lasso measures it in. Returns true when the
    /// canvas must redraw.
    ///
    /// `sampling` answers with the pixels a drag would take when they are not
    /// the canvas's composite — the active layer's own, when Sample All
    /// Layers is off — and nil when they are. It is called ONLY where a
    /// region becomes placed, because it costs a canvas-sized copy.
    mutating func mouseDown(
        _ point: CGPoint, clickCount: Int, selection: CanvasSelection?, in image: CGImage?,
        magnification: CGFloat, sampling: () -> CGImage?
    ) -> Bool {
        switch phase {
        case .idle:
            // An existing selection is ADOPTED, not re-outlined: pressing
            // inside it starts the move straight away. Its bounds are the
            // hit target — the same box the marquee draws around a wand or
            // Select Subject mask, and cheaper than a coverage lookup that
            // would make the tool feel like it was ignoring presses near a
            // ragged edge.
            if let selection = selection, selection.bounds.contains(point) {
                region = selection
                canvasWidth = selection.canvasWidth
                canvasHeight = selection.canvasHeight
                dragAnchor = point
                dragCurrent = point
                snapshot = sampling()
                phase = .placed
                return true
            }
            return beginOutline(at: point, in: image)
        case .drawing:
            // The polygon lasso's two closing rules, restated (the canvas's
            // own closeLasso is private, and the plan keeps the Patch tool's
            // drawing and geometry in this file).
            if clickCount >= 2 { return closeOutline(at: point, sampling: sampling) }
            if let first = outline.first, outline.count >= 3,
                hypot(point.x - first.x, point.y - first.y) * max(magnification, 0.001)
                    < Self.closeScreenRadius
            {
                return closeOutline(at: point, sampling: sampling)
            }
            outline.append(point)
            return true
        case .placed, .dragging:
            guard let region = region else { return beginOutline(at: point, in: image) }
            // Inside the placed region: this press owns the move. The
            // snapshot is re-taken, not kept: an edit may have landed since
            // the outline was closed, and what the drag shows has to be what
            // the release will take.
            if region.bounds.contains(point) {
                dragAnchor = point
                dragCurrent = point
                snapshot = sampling()
                phase = .placed
                return false
            }
            // Outside it: the user is done with that region and is outlining
            // the next one, exactly as a fresh click does with the lasso.
            self.region = nil
            return beginOutline(at: point, in: image)
        }
    }

    /// True when the canvas must redraw.
    mutating func mouseDragged(_ point: CGPoint) -> Bool {
        switch phase {
        case .idle, .drawing:
            // The outline is clicked out vertex by vertex; a drag between
            // vertices is not a gesture this tool has.
            return false
        case .placed:
            guard region != nil else { return false }
            dragCurrent = point
            phase = .dragging
            return true
        case .dragging:
            guard dragCurrent != point else { return false }
            dragCurrent = point
            return true
        }
    }

    /// Non-nil only when the drag actually moved a placed region.
    mutating func mouseUp(_ point: CGPoint) -> Result? {
        guard phase == .dragging, let region = region else { return nil }
        dragCurrent = point
        let moved = offset
        // The region stays placed at rest, so a second patch from the same
        // outline is one more drag rather than one more outline.
        phase = .placed
        dragAnchor = point
        dragCurrent = point
        // A drag that rounds to no displacement at all would heal the region
        // from itself: the core would answer "nothing changed" and the
        // gesture would beep. Treat it as the misclick it is.
        guard moved.dx != 0 || moved.dy != 0 else { return nil }
        return Result(region: region, offset: moved)
    }

    mutating func cancel() {
        phase = .idle
        outline = []
        region = nil
        snapshot = nil
        canvasWidth = 0
        canvasHeight = 0
        dragAnchor = .zero
        dragCurrent = .zero
    }

    /// Closes the outline in progress from the keyboard — Return, which
    /// closes an in-progress lasso the same way (`ImageCanvasView.keyDown`'s
    /// `closeLasso` branch). True when there was an outline to close, so the
    /// canvas's branch is one line:
    ///
    ///     if event.keyCode == 36 || event.keyCode == 76, tool == .patch,
    ///        patchSession.closeOutlineFromKey() { needsDisplay = true; return }
    ///
    /// The last vertex anchors the drag that may follow, exactly as the
    /// closing click does.
    @discardableResult
    mutating func closeOutlineFromKey(sampling: () -> CGImage?) -> Bool {
        guard phase == .drawing, let last = outline.last else { return false }
        return closeOutline(at: last, sampling: sampling)
    }

    /// Starts a fresh outline at `point`. The canvas size is latched here
    /// because the closed region becomes a CanvasSelection, which needs it;
    /// with no image there is no canvas and no gesture.
    private mutating func beginOutline(at point: CGPoint, in image: CGImage?) -> Bool {
        guard let image = image, image.width > 0, image.height > 0 else {
            cancel()
            return false
        }
        canvasWidth = image.width
        canvasHeight = image.height
        outline = [point]
        phase = .drawing
        return true
    }

    /// Closes the outline into a placed region. `point` is the click that
    /// closed it, and it anchors the drag that may follow without lifting the
    /// mouse — a double-click that closes and then slides straight into a
    /// move is one gesture, not two.
    private mutating func closeOutline(at point: CGPoint, sampling: () -> CGImage?) -> Bool {
        let points = outline
        outline = []
        dragAnchor = point
        dragCurrent = point
        // The SAME .polygon shape the Lasso commits, through the same
        // initializer — which is also what rejects an outline of fewer than
        // three points or one that encloses no canvas pixel.
        guard let closed = CanvasSelection(
            shape: .polygon(points), canvasWidth: canvasWidth, canvasHeight: canvasHeight)
        else {
            region = nil
            phase = .idle
            return true
        }
        region = closed
        snapshot = sampling()
        phase = .placed
        return true
    }

    // MARK: - Geometry

    /// THE patch geometry, in one place: which region gets healed and how far
    /// the source is displaced to reach it.
    ///
    /// - Source (the default): Ω is the outlined region, and its pixels come
    ///   from the region translated by +offset — the place the user dragged
    ///   to. Drawing the snapshot displaced by −offset puts the sampled
    ///   pixels under the outline.
    /// - Destination: Ω is the region translated by +offset — the place the
    ///   user dragged onto — and its pixels come from the region as outlined,
    ///   so the snapshot moves WITH the outline, by +offset.
    ///
    /// One sign flip, both callers, no second copy of the arithmetic.
    static func geometry(offset: CGVector, destination: Bool) -> Geometry {
        destination
            ? Geometry(clip: offset, image: offset)
            : Geometry(clip: .zero, image: CGVector(dx: -offset.dx, dy: -offset.dy))
    }

    /// THE patch overlay builder — the polygon/mask clip, the ∓offset
    /// displacement and the Source/Destination sign flip, written once and
    /// called by BOTH EditorViewController+Patch and AgentServer+Patch.
    ///
    /// `data` must be `width * height * 4` bytes, zeroed: the result is the
    /// canvas-sized PREMULTIPLIED RGBA8 overlay `rz_doc_heal_layer` takes,
    /// whose alpha is the region's coverage and whose RGB is the already
    /// aligned source — the Clone Stamp's currency, so the healing ops need
    /// no offset parameter of their own (CoreGraphics does the alignment
    /// here). `space` is the document's DRAWING space, `snapshot` the pixels
    /// to take from, tagged with the document's own space, so the numbers
    /// move through unconverted (a sampled colour converts nowhere).
    ///
    /// Returns false when the patch cannot land: a region that does not match
    /// the canvas, an offset that rounds to nothing (the region would be
    /// healed from itself), or a displacement that carries the sampled area
    /// clean off the picture. The test is geometric — true does not promise
    /// the covered pixels differ from what is already there, which is the
    /// core's business and comes back as its "nothing changed" answer.
    static func buildOverlay(
        result: Result, snapshot: CGImage, destination: Bool, space: CGColorSpace,
        width: Int, height: Int, into data: UnsafeMutablePointer<UInt8>
    ) -> Bool {
        guard width > 0, height > 0,
            result.region.canvasWidth == width, result.region.canvasHeight == height
        else { return false }
        let offset = CGVector(dx: result.offset.dx.rounded(), dy: result.offset.dy.rounded())
        guard offset.dx != 0 || offset.dy != 0 else { return false }
        let geometry = geometry(offset: offset, destination: destination)
        let canvas = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        let healed = result.region.bounds
            .offsetBy(dx: geometry.clip.dx, dy: geometry.clip.dy)
            .intersection(canvas)
        // Where the sampled pixels land once displaced: outside this the
        // overlay would carry nothing but transparent black.
        let sampled = CGRect(
            x: geometry.image.dx, y: geometry.image.dy,
            width: CGFloat(snapshot.width), height: CGFloat(snapshot.height))
        guard !healed.intersection(sampled).isEmpty else { return false }
        guard let context = CGContext(
            data: data, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        // Overlay row 0 is the canvas's top row, so the context is flipped
        // and drawing coordinates are canvas coordinates — paintOverlay's
        // and retouchOverlay's exact frame.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        clipToRegion(result.region, shifted: geometry.clip, in: context)
        drawSnapshot(
            snapshot, displacedBy: geometry.image, canvasHeight: CGFloat(height), in: context)
        return true
    }

    /// Clips `context` — canvas coordinates, flipped — to the region, moved
    /// by `shift`. The CTM goes back where it was afterwards: a clip lives in
    /// device space, so it survives the restore and the snapshot that follows
    /// is drawn in plain canvas coordinates.
    private static func clipToRegion(
        _ region: CanvasSelection, shifted shift: CGVector, in context: CGContext
    ) {
        if shift.dx != 0 || shift.dy != 0 {
            context.translateBy(x: shift.dx, y: shift.dy)
            region.clip(context)
            context.translateBy(x: -shift.dx, y: -shift.dy)
            return
        }
        region.clip(context)
    }

    /// Draws `snapshot` into a flipped canvas-coordinate context so that the
    /// pixel landing on canvas point p is the snapshot's p − `shift`.
    ///
    /// The un-flip inside is `ImageCanvasView.stampCloneDab`'s rule, the same
    /// one AgentServer+Retouch's clone and heal handlers draw by: the context
    /// is flipped, so the image flips back locally to land right side up, and
    /// a +shift in canvas coordinates (y down) is a −shift.dy in the un-
    /// flipped frame. `canvasHeight` is passed rather than read off the
    /// context: on the canvas this draws into the VIEW's context, whose own
    /// height is the backing store's and not the picture's.
    private static func drawSnapshot(
        _ snapshot: CGImage, displacedBy shift: CGVector, canvasHeight: CGFloat,
        in context: CGContext
    ) {
        context.translateBy(x: 0, y: canvasHeight)
        context.scaleBy(x: 1, y: -1)
        context.draw(
            snapshot,
            in: CGRect(
                x: shift.dx, y: -shift.dy,
                width: CGFloat(snapshot.width), height: CGFloat(snapshot.height)))
    }

    // MARK: - Drawing

    /// Draws what will be TAKEN: the composite displaced by the live drag
    /// vector and clipped to the region that will be healed, plus the two
    /// outlines — dashed where the region was outlined, solid where it has
    /// been dragged to. In Source the filled one is the resting outline (the
    /// flaw, previewing the texture it is about to receive); in Destination
    /// it is the moving one (the good texture, carried onto the flaw).
    ///
    /// `image` is the canvas's composite, and it is the fallback: what the
    /// drag actually draws is the `snapshot` latched when the region was
    /// placed, which is the same choice the commit makes — the composite with
    /// Sample All Layers on, the active layer's own canvas-placed pixels with
    /// it off. Sampling once per press rather than per tick is what keeps
    /// that from costing a flatten a frame.
    func draw(in context: CGContext, image: CGImage?, magnification: CGFloat) {
        let scale = max(magnification, 0.001)
        switch phase {
        case .idle:
            return
        case .drawing:
            drawOutlineInProgress(scale: scale)
        case .placed:
            guard let region = region else { return }
            strokeRegion(region, shifted: .zero, dashed: true, scale: scale)
        case .dragging:
            guard let region = region else { return }
            let moved = offset
            let geometry = Self.geometry(offset: moved, destination: Self.isDestination)
            if let image = snapshot ?? image {
                drawTakenPixels(
                    image, region: region, geometry: geometry, in: context,
                    magnification: scale)
            }
            // The dashed outline stays where the region was outlined and the
            // solid one follows the pointer, in BOTH directions: together
            // they name the two places the patch joins, and the filled one
            // says which of them is being healed.
            strokeRegion(region, shifted: .zero, dashed: true, scale: scale)
            strokeRegion(region, shifted: moved, dashed: false, scale: scale)
        }
    }

    /// The pixels the release will take, drawn where they will land.
    private func drawTakenPixels(
        _ image: CGImage, region: CanvasSelection, geometry: Geometry,
        in context: CGContext, magnification: CGFloat
    ) {
        context.saveGState()
        // ImageCanvasView.imageInterpolation's rule, restated: crisp pixels
        // when zoomed in, smooth ones when zoomed out. The displacement is
        // integral, so at 1:1 nothing is resampled at all.
        context.interpolationQuality = magnification >= 1 ? .none : .high
        Self.clipToRegion(region, shifted: geometry.clip, in: context)
        Self.drawSnapshot(
            image, displacedBy: geometry.image, canvasHeight: CGFloat(image.height),
            in: context)
        context.restoreGState()
    }

    /// The region's marquee, optionally moved by the drag: dashed at rest,
    /// solid where it has been dragged to.
    private func strokeRegion(
        _ region: CanvasSelection, shifted shift: CGVector, dashed: Bool, scale: CGFloat
    ) {
        // A mask selection's marqueePath is its STORED contour, so it is
        // copied before being moved or re-dashed — and the dash a previous
        // stroke left on it is sticky, which is why both branches set it.
        // The bounds fallback is `ImageCanvasView.drawSelection`'s: a region
        // that draws nothing at all would be a region the user cannot see
        // themselves dragging.
        let path = (region.marqueePath?.copy() as? NSBezierPath)
            ?? NSBezierPath(rect: region.bounds)
        if shift.dx != 0 || shift.dy != 0 {
            path.transform(using: AffineTransform(translationByX: shift.dx, byY: shift.dy))
        }
        path.lineWidth = 2 / scale
        if dashed {
            let dash: [CGFloat] = [5 / scale, 4 / scale]
            path.setLineDash(dash, count: dash.count, phase: 0)
        } else {
            path.setLineDash(nil, count: 0, phase: 0)
        }
        DS.marquee.setStroke()
        path.stroke()
    }

    /// The outline being clicked out: the canvas's own lasso preview —
    /// dashed polyline, coral vertex dots — for a gesture that is the lasso's
    /// in everything but what it commits to.
    private func drawOutlineInProgress(scale: CGFloat) {
        guard let first = outline.first else { return }
        let path = NSBezierPath()
        path.move(to: first)
        for point in outline.dropFirst() {
            path.line(to: point)
        }
        path.lineWidth = 2 / scale
        let dash: [CGFloat] = [5 / scale, 4 / scale]
        path.setLineDash(dash, count: dash.count, phase: 0)
        DS.marquee.setStroke()
        path.stroke()
        let radius = 3 / scale
        DS.marquee.setFill()
        for point in outline {
            NSBezierPath(
                ovalIn: CGRect(
                    x: point.x - radius, y: point.y - radius,
                    width: radius * 2, height: radius * 2)
            ).fill()
        }
    }
}
