import AppKit

/// Text view used for in-canvas text sessions: ⌘Return commits the session.
final class CanvasTextView: NSTextView {
    var onCommandReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        // 36 = Return, 76 = keypad Enter.
        if event.modifierFlags.contains(.command), event.keyCode == 36 || event.keyCode == 76 {
            onCommandReturn?()
        } else {
            super.keyDown(with: event)
        }
    }
}

/// The document view inside the editor's scroll view. Flipped so that view
/// coordinates equal image pixel coordinates at 100% magnification. The
/// view's frame (pixel size in points) is managed by EditorViewController.
final class ImageCanvasView: NSView {
    var image: CGImage? {
        didSet {
            // The overlay lives at the image's pixel size: throw it away on a
            // size change, otherwise clear it — EXCEPT mid-stroke, where the
            // projection updates on every live-edit tick and the overlay is
            // still accumulating the stroke's geometry.
            if let image = image, image.width == overlayWidth, image.height == overlayHeight {
                if !strokeActive { clearOverlay() }
            } else {
                destroyOverlay()
            }
            // A selection made at a different canvas size is meaningless.
            if let selection = selection,
                selection.canvasWidth != (image?.width ?? 0)
                    || selection.canvasHeight != (image?.height ?? 0)
            {
                setSelection(nil)
            }
            // So is a clone source: it is a canvas coordinate, and a crop
            // or resize moved the ground out from under it.
            if image?.width != oldValue?.width || image?.height != oldValue?.height {
                cloneSource = nil
            }
            // A Quick Mask buffer made at a different canvas size is
            // meaningless: discard the session (no selection comes back —
            // there is nothing valid to convert). Same-size doc swaps
            // (undo of a paint edit, agent edits) keep the session.
            if quickMaskActive,
               (image?.width ?? 0) != quickMaskWidth
                   || (image?.height ?? 0) != quickMaskHeight
            {
                discardQuickMask()
            }
            // An outline describes the composite it was traced from; the
            // analysis behind it re-runs on identity, but the drawn path has
            // to go now (an agent edit can land mid-press).
            subjectSession.cancel()
            // The patch outline is the exception, and it follows the
            // selection's rule three blocks up: it is canvas GEOMETRY, not a
            // reading of the pixels, so only a size change invalidates it.
            // Cancelling unconditionally meant the patch's own commit
            // destroyed the region it had just placed — `mouseUp` leaves it
            // placed precisely so a second patch from the same outline is one
            // more drag — and so did undoing one.
            if image?.width != oldValue?.width || image?.height != oldValue?.height {
                patchSession.cancel()
                // Same rule for a guide drag and a pending ruler origin:
                // both are canvas GEOMETRY, not a reading of the pixels, so
                // a same-size doc swap (undo, an agent edit landing
                // mid-press) leaves them alone and only a resize ends them.
                guideDrag = nil
                rulerOriginDrag = nil
            }
            redEyeSession.cancel()
            needsDisplay = true
        }
    }

    /// The colour space to DRAW the document in, pushed in by the editor
    /// beside `image` — `RasterDocument.drawingSpace`, which is the
    /// document's own space for every profile that can be a rendering
    /// destination and sRGB for the LUT profiles that cannot (drawing into
    /// one of those produces opaque black). The stroke overlay is built in
    /// it and the clone snapshot is `image` itself, so for every profile but
    /// that one the two agree and a cloned pixel round-trips unchanged (on a
    /// LUT-profile document the clone converts into sRGB with everything
    /// else painted there); the stroke colour is normalized
    /// into it at mouse-down, so an authored swatch converts exactly once
    /// and a swatch sampled from the document converts not at all. A profile
    /// change makes the cached overlay wrong, so it is thrown away here the
    /// same way a size change throws it away above.
    var documentColorSpace: CGColorSpace = ColorProfile.sRGB {
        didSet {
            guard !CFEqual(documentColorSpace, oldValue) else { return }
            documentNSColorSpace = NSColorSpace(cgColorSpace: documentColorSpace) ?? .sRGB
            // MID-STROKE the overlay is still accumulating this stroke's
            // geometry, exactly as it is for the `image` setter above — an
            // agent's assign_profile lands like any other live edit — so
            // freeing it here would make every later drag event return early
            // and silently drop the rest of the stroke, a mask or Quick Mask
            // stroke whole. The stroke finishes in the space it started in
            // (its colour was latched at mouse-down, into that space), and
            // `clearOverlay` throws the stale buffer away at stroke end.
            overlayColorSpaceIsStale = true
            if !strokeActive { clearOverlay() }
        }
    }

    /// True once a profile change has made the overlay's colour space wrong
    /// — set by `documentColorSpace`, acted on by `clearOverlay`, which is
    /// the one place every stroke path finishes with the buffer.
    private var overlayColorSpaceIsStale = false

    /// `documentColorSpace` as an NSColorSpace, kept beside it so a stroke
    /// normalizes its colour into the DOCUMENT's space once per mouse-down
    /// instead of into sRGB: an authored swatch converts here, a sampled one
    /// is already there and converts nowhere.
    private var documentNSColorSpace: NSColorSpace = .sRGB

    /// The Subject tool's press-and-hold: the segmentation it caches and
    /// the outline currently under the pointer. Logic lives in
    /// SubjectSelection.swift; this view only points it at events.
    var subjectSession = SubjectSession()

    /// The Patch and Red Eye drags, on the same pattern: their own files own
    /// the geometry and the drawing, this view only points them at events.
    var patchSession = PatchSession()
    var redEyeSession = RedEyeSession()

    // Guides, the grid and snapping — the same arrangement again: the values
    // are pushed in, the geometry and the drawing live in Guides.swift,
    // SnapEngine.swift, ImageCanvasView+Guides.swift and
    // ImageCanvasView+Grid.swift.

    /// The whole of the view chrome's preferences as ONE value, so this
    /// frozen file gains one stored property and one assignment in
    /// syncCanvasPaintState rather than nine of each (CanvasChromeSettings
    /// carries the argument). The canvas still never reads ToolOptionsStore.
    var chrome = CanvasChromeSettings() {
        didSet { needsDisplay = true }
    }
    /// The document's guides, cached on every document change so a redraw
    /// and a hit test cross the FFI boundary not at all.
    var guides: [CanvasGuide] = []
    /// The guide drag in flight (GuideDragSession.swift).
    var guideDrag: GuideDragSession?
    /// The cursor a guide under the pointer asks for, or nil. It has to be a
    /// property rather than an NSCursor.set(): hovering is governed by
    /// resetCursorRects, which four existing invalidateCursorRects sites
    /// re-apply.
    var guideHoverCursor: NSCursor?
    /// The pending ruler origin while the corner box is being dragged.
    var rulerOriginDrag: CGPoint?
    /// The alignment lines and equal-gap bars a live Move or Free Transform
    /// drag produced, computed from the CORRECTED box (SnapEngine.swift).
    var smartGuides: [SmartGuideLine] = []
    /// The engine this canvas's own point drags snap against — asked for at
    /// mouse-DOWN through `onSnapEngine` and then held unchanged for the
    /// whole gesture, never rebuilt mid-drag.
    var snapEngine = SnapEngine.inactive
    /// Builds the engine above. It is a closure rather than a stored value a
    /// sync pushes because a guide dragged out of a ruler must be a target
    /// for the very next marquee, without a tool switch in between — and
    /// rebuilding on every document change instead would run the
    /// content-bounds fold per brush stroke (DragSnapping.swift).
    var onSnapEngine: (() -> SnapEngine)?

    /// The guide gestures. `onGuideMouseDown` returns true when it took the
    /// press, which is what keeps it from reaching the active tool.
    var onGuideMouseDown: ((CGPoint, NSEvent.ModifierFlags) -> Bool)?
    var onGuideMouseDragged: ((CGPoint, NSEvent.ModifierFlags) -> Void)?
    /// Mouse-up takes no point: the drag's own state decides both what is
    /// committed and whether the guide is being dropped back into its ruler,
    /// so that one release event cannot disagree with the last tick the user
    /// actually saw (EditorViewController+Guides.guideMouseUp).
    var onGuideMouseUp: (() -> Void)?
    /// ⌫ while a guide is grabbed.
    var onGuideDelete: (() -> Void)?
    /// Escape while a guide is grabbed.
    var onGuideCancel: (() -> Void)?

    /// When non-nil, drawn instead of `image` (live-preview sheets).
    var previewImage: CGImage? {
        didSet { needsDisplay = true }
    }

    /// Everything the canvas needs to draw a free-transform session: the rest
    /// of the layer stack as two cached composites, the transformed layer's
    /// own pixels, and the box the handles hang off. The document is NOT
    /// touched during a session — this is a pure CoreGraphics preview of a
    /// matrix the core only ever runs once, at commit.
    struct TransformPreview {
        /// The stack below the transformed layer, canvas-sized.
        var below: CGImage?
        /// The stack above it, canvas-sized (transparent where nothing is).
        var above: CGImage?
        /// The transformed layer's own pixels, at the layer's size; nil for a
        /// hidden layer (the box still shows, the pixels don't).
        var layer: CGImage?
        /// The layer's enabled mask as a DeviceGray image at the same size,
        /// or nil. The core resamples a mask with the very same matrix, so
        /// clipping the preview through it is exactly what commits.
        var mask: CGImage?
        /// The layer's untransformed canvas rect — where `layer` starts.
        var sourceRect: CGRect
        /// Canvas-space matrix (the very one the commit hands to the core).
        var matrix: CGAffineTransform
        var opacity: CGFloat
        /// `sourceRect`'s four transformed corners: the box to draw.
        var quad: [CGPoint]
        /// Where the pivot landed, marked so rotation reads as deliberate.
        var pivot: CGPoint
        /// False for the nearest-neighbour sampler, so the preview shows the
        /// hard pixel edges the commit will produce.
        var interpolate: Bool
        /// True when corner offsets are live: `quad` is then no longer the
        /// affine image of `sourceRect`, and the layer previews through the
        /// Core Image warp instead of the CTM concat.
        var warped: Bool
    }

    /// Non-nil for the duration of a Free Transform session; the canvas then
    /// draws the preview instead of the projection and routes mouse and key
    /// events to the session's callbacks.
    var transformPreview: TransformPreview? {
        didSet {
            needsDisplay = true
            if (transformPreview == nil) != (oldValue == nil) {
                window?.invalidateCursorRects(for: self)
            }
            // The warp preview's mask bake is keyed to this session's
            // images; ending the preview is what makes them garbage.
            if transformPreview == nil {
                PerspectivePreview.invalidate()
            }
        }
    }

    var isTransforming: Bool { transformPreview != nil }

    /// The active layer's extent in image pixel coordinates, kept current by
    /// the view controller. Paint tools draw its boundary when it differs
    /// from the canvas rect, since paint outside it cannot land.
    var activeLayerRect: CGRect? {
        didSet {
            if activeLayerRect != oldValue { needsDisplay = true }
        }
    }

    /// The active tool. The view controller commits any pending text session
    /// before flipping this; the setter only abandons stroke/drag state.
    var tool: EditorTool = .select {
        didSet {
            cancelStroke()
            cancelLasso()
            subjectSession.cancel()
            patchSession.cancel()
            redEyeSession.cancel()
            gradientAnchor = nil
            gradientCurrent = nil
            eyedropperDragActive = false
            shapeAnchor = nil
            shapePreview = nil
            zoomAnchor = nil
            zoomAnchorWindow = nil
            zoomMarquee = nil
            handPanAnchorWindow = nil
            handPanScrollOrigin = nil
            if moveDragOrigin != nil {
                // A tool switch mid-drag must still close the live edit so
                // the drag-so-far becomes one undo step.
                moveDragOrigin = nil
                onMoveEnd?()
            }
            // The guide grab cursor belongs to the OLD tool's answer to
            // `canGrabGuide`, and the pointer has not moved, so nothing will
            // re-derive it: without this the invalidation below would put
            // the guide's arrows straight back over a guide the new tool
            // cannot grab (picking crop while hovering one, say), and the
            // pointer would promise a grab the press will not honour. The
            // next `mouseMoved` re-derives it through the predicate
            // (ImageCanvasView+Guides.swift).
            clearGuideHoverCursor()
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }
    }

    // Paint parameters, kept current by EditorViewController.
    var brushSize: CGFloat = 24
    var paintColor: NSColor = .black
    var brushOpacity: CGFloat = 1.0
    /// Edge hardness, 0–1. Below 1 the stroke stamps SoftBrush dabs instead
    /// of stroking a hard path; the dab images below are latched per stroke.
    var brushHardness: CGFloat = 1
    /// The rest of the tip (per-dab deposit, dab rhythm, squashed/rotated
    /// footprint) plus the stroke behaviors: any non-default tip value also
    /// swaps the stroke onto the stamped pipeline (SoftBrush.isStamped).
    var brushFlow: CGFloat = 1
    var brushSpacingPercent: CGFloat = BrushTip.defaultSpacingPercent
    var brushAngle: CGFloat = 0
    var brushRoundness: CGFloat = 1
    /// Smoothing, 0–1: the pulled-string leash's length as a fraction of
    /// 32 screen px (converted to canvas px per stroke at the live zoom).
    var brushSmoothing: CGFloat = 0
    var brushPressureSize = false
    var brushAirbrush = false
    private var strokeSoftDab: CGImage?
    private var cloneDabMask: CGImage?
    /// Latched per stroke with the dab images: an options edit mid-drag
    /// cannot bend a live stroke.
    ///
    /// `private(set)`, not private: the Actions recorder reads the LATCHED
    /// tip (`EditorViewController+Actions.strokeRecord`) so a recorded stroke
    /// carries the hardness, flow, spacing, angle and roundness the stroke
    /// actually dabbed with rather than whatever the options bar holds later.
    private(set) var strokeTip = BrushTip()

    /// The stroke's FLATTENED vertices, in canvas pixels — exactly the
    /// polyline `renderStroke` dabbed along, which is exactly what the
    /// agent's stroke tools take. Accumulated here rather than rebuilt from
    /// the spline afterwards: the spline is consumed span by span, and a
    /// pixel-brush stroke never goes through it at all.
    private(set) var recordedStrokePoints: [CGPoint] = []

    /// The canvas point a clone or heal stroke sampled FROM — the source the
    /// stroke's offset was latched against, which is what `clone_stamp` and
    /// `heal_stroke` take. Not `cloneSource`: with Aligned on, the offset
    /// outlives the ⌥-click and the real source moves with the brush.
    private(set) var strokeCloneSource: CGPoint?
    private var strokeLeash = StrokeLeash(position: .zero, radius: 0)
    /// True when Pressure size is on AND the stroke came from a tablet:
    /// dab diameters then track the pen's pressure. Mouse strokes stay
    /// constant-size whatever the checkbox says.
    private var strokeUsesPressure = false
    /// The latest (leashed) brush position and pressure — where an
    /// airbrush tick deposits while the hand rests.
    private var strokeCursor = CGPoint.zero
    private var strokeCursorPressure: CGFloat = 1
    private var strokeLastPressure: CGFloat = 1
    private var airbrushTimer: Timer?
    /// Stamped COVERAGE strokes (mask / Quick Mask) stamp dabs at the
    /// tip's FLOW alpha (full by default) and apply the stroke's opacity
    /// once, here, where the overlay is consumed — per-dab opacity would
    /// compound where dabs overlap, pushing a 50% stroke's core toward
    /// 100%. 1 for every other stroke.
    private var strokeCoverageScale: CGFloat = 1

    // Selection options, kept current by EditorViewController: the options
    // bar's combine mode (a gesture's modifiers still override it) and the
    // feather applied as a gesture commits.
    var selectionCombineBase: SelectionCombineMode = .replace
    var selectionFeather: Double = 0

    // Clone stamp: the ⌥-clicked source point, and the projection snapshot
    // plus source offset the active stroke stamps from — both latched at
    // mouse-down so nothing can change what is being cloned mid-drag.
    var cloneSource: CGPoint? {
        didSet {
            if cloneSource != oldValue { needsDisplay = true }
            // A new source point starts a new alignment (see strokeAligned).
            cloneOffsetTool = nil
        }
    }
    private var cloneSnapshot: CGImage?
    private var cloneOffset = CGVector.zero
    /// The pointer's last canvas position, or nil while it is outside. The
    /// clone/heal source marker needs it: with an Aligned offset latched the
    /// point being sampled MOVES with the brush, so a marker parked on the
    /// ⌥-clicked source would name pixels the tool is not reading. See
    /// `cloneSourceMarkerPoint`.
    private var hoverPoint: CGPoint?
    /// Aligned (Healing Brush): the first stroke's offset survives later
    /// ones. Toggling it moves the source marker — with an offset latched the
    /// marker tracks the pointer, without one it sits on the ⌥-clicked point
    /// (`cloneSourceMarkerPoint`) — so the canvas redraws.
    var strokeAligned = false {
        didSet {
            if strokeAligned != oldValue, tool == .clone || tool == .heal,
                cloneSource != nil, !isTransforming
            {
                needsDisplay = true
            }
        }
    }
    /// The tool that established `cloneOffset`, or nil when nothing is
    /// latched. The LATCH IS PER TOOL, not per canvas: the Clone Stamp and
    /// the Healing Brush share one source point and one offset, and the Clone
    /// Stamp recomputes the offset on every mouse-down (it has no Aligned
    /// option), so a clone stroke in between two aligned heals used to
    /// re-aim the heal's alignment silently — the marker still drew at the
    /// source the user picked while the heal sampled through the clone's
    /// offset. An offset latched by a different tool is treated as unlatched.
    private var cloneOffsetTool: EditorTool?

    // The View options' scrubby-zoom preference, kept current by
    // EditorViewController: a zoom-tool drag scrubs instead of marqueeing.
    var scrubbyZoom = false

    // Crop session overlay: owned by EditorViewController+Crop, which does
    // the geometry; the canvas draws it and routes the gesture.
    var cropOverlay: CropOverlay? {
        didSet { needsDisplay = true }
    }
    var onCropMouseDown: ((CGPoint) -> Void)?
    /// The modifiers ride along because ⌃ suspends snapping and must be read
    /// on every tick, never latched at mouse-down: the user may suspend
    /// mid-drag, and the crop box is one of the three drags that could not
    /// see the flag at all before this phase.
    var onCropMouseDragged: ((CGPoint, NSEvent.ModifierFlags) -> Void)?
    var onCropMouseUp: ((CGPoint) -> Void)?
    /// Return, keypad Enter, or a double-click.
    var onCropCommit: (() -> Void)?
    /// Escape.
    var onCropCancel: (() -> Void)?

    // Shape tools: the live drag preview (geometry in ShapeTool.swift) and
    // the style it draws with, kept current by EditorViewController.
    var shapePreview: ShapeToolPreview? {
        didSet { needsDisplay = true }
    }
    var shapeStyle = ShapeToolStyle()
    /// Fired when a shape drag commits: the shape's box and, for a line,
    /// whether it runs bottom-left → top-right.
    var onShapeCommit: ((_ box: CGRect, _ flipped: Bool) -> Void)?
    private var shapeAnchor: CGPoint?

    // A shape layer reopened for editing: owned by EditorViewController's
    // +Shapes extension, which does the geometry; the canvas draws the
    // overlay and routes the gesture — the crop session's arrangement.
    // While non-nil, shape-tool mouse events go to the onShapeEdit*
    // closures instead of rubber-banding a new shape.
    var shapeEditOverlay: ShapeToolPreview? {
        didSet { needsDisplay = true }
    }
    var onShapeEditMouseDown: ((CGPoint) -> Void)?
    /// With the modifiers, for the reason onCropMouseDragged gives.
    var onShapeEditMouseDragged: ((CGPoint, NSEvent.ModifierFlags) -> Void)?
    var onShapeEditMouseUp: (() -> Void)?
    /// Return, keypad Enter, or a double-click.
    var onShapeEditCommit: (() -> Void)?
    /// Escape.
    var onShapeEditCancel: (() -> Void)?

    // Zoom and hand gestures. Zoom reports; the editor owns magnification.
    var onZoomClick: ((_ point: CGPoint, _ out: Bool) -> Void)?
    /// Scrubby target magnification (absolute, from the drag's start value).
    var onZoomTo: ((CGFloat) -> Void)?
    var onZoomRect: ((CGRect) -> Void)?
    private var zoomAnchor: CGPoint?
    private var zoomAnchorWindow: NSPoint?
    private var zoomStartMagnification: CGFloat = 1
    private var zoomMarquee: CGRect?
    /// True once a scrubby drag actually scrubbed, so a plain click with
    /// scrubby on still steps the ladder instead of doing nothing.
    private var zoomDidScrub = false
    private var handPanAnchorWindow: NSPoint?
    private var handPanScrollOrigin: NSPoint?

    /// The typography a text session draws with — exactly the attributes
    /// the commit renders with (TextStyle.attributes), so what is previewed
    /// is what lands. The live session aligns within its editing box; the
    /// commit aligns within the laid-out block (TextLayer.render), which
    /// matches once the text wraps to fill it.
    var textStyle = TextStyle(family: "Helvetica Neue", size: 48)

    /// The editor's edit target, mirrored down — the layer's pixels, its
    /// mask, one of its colour planes or a document channel. Kept current by
    /// EditorViewController; the canvas reads it for the coverage stroke
    /// pipeline (`paintsMask`) and for the two things it must draw honestly:
    /// the active-layer boundary (only the LAYER-clipped targets have one)
    /// and the rubylith washes (a sheet previewing an op on the target plane
    /// paints over them).
    var paintTarget: PaintTarget = .layer {
        didSet {
            if paintTarget != oldValue { needsDisplay = true }
        }
    }

    /// True while brush and eraser edit the active layer's MASK, one of its
    /// colour PLANES, or one of the document's alpha CHANNELS instead of its
    /// pixels — every COVERAGE target (the layers and channels panels' edit
    /// target). Coverage is not color: the stroke paints white (brush,
    /// reveals) or black (eraser, hides), it previews as a translucent ghost
    /// rather than through the projection, and the whole overlay commits on
    /// mouse-up via onCommitMaskOverlay. Derived from `paintTarget`, so the
    /// stroke pipeline and the drawing can never disagree about the target.
    var paintsMask: Bool { paintTarget.isCoverage }

    // Brush/eraser stroke pipeline. The overlay accumulates the stroke's
    // geometry; every tick hands the WHOLE overlay to the receiver, which
    // routes it through the document's live-edit machinery so the canvas
    // previews the true projection (stacking, opacity, blend mode, per-layer
    // erase) during the drag.

    /// Fired before a stroke starts; return false to refuse it (hidden
    /// layer) — the canvas beeps and never begins.
    var onStrokeBegin: (() -> Bool)?
    /// Fired after the initial stamp and after every drag tick with the
    /// overlay's canvas-sized premultiplied RGBA8 bytes (top row first).
    var onStrokeUpdate: ((_ data: UnsafePointer<UInt8>, _ mode: RzCompositeMode, _ alpha: Double) -> Void)?
    var onStrokeEnd: ((_ actionName: String) -> Void)?
    /// Fired when an in-progress stroke is abandoned (tool switch, Escape,
    /// window close); the receiver rolls the live edit back.
    var onStrokeCancel: (() -> Void)?

    /// Fired once at the END of a mask stroke with the overlay's canvas-sized
    /// premultiplied RGBA8 bytes; the receiver routes them through
    /// ImageDocument.applyEdit as a single undo step. Mask strokes take this
    /// path instead of onStrokeUpdate's live-edit round trip (see
    /// drawMaskStrokeGhost).
    var onCommitMaskOverlay: ((_ data: UnsafePointer<UInt8>, _ actionName: String) -> Void)?

    /// The retouching tools' four seams: each body is a one-line forward into
    /// an EditorViewController extension (+Heal / +Patch / +RedEye.swift).
    var onCommitStrokeOverlay: ((_ data: UnsafePointer<UInt8>, _ actionName: String) -> Void)?
    var onStrokeSourceImage: (() -> CGImage?)?
    /// The Patch tool's twin of `onStrokeSourceImage`: the pixels the drag
    /// previews from, nil meaning the canvas's own composite. It is asked
    /// only when a region is placed or a drag starts, never per tick — see
    /// PatchSession's `snapshot`.
    var onPatchSourceImage: (() -> CGImage?)?
    var onPatchCommit: ((PatchSession.Result) -> Void)?
    var onRedEyeCommit: ((CGRect) -> Void)?

    /// Fired on a text-tool click (image pixel coordinates). The receiver
    /// owns the document, so it decides whether the click re-opens an
    /// existing text layer or starts a new entry, then calls
    /// beginTextSession.
    var onTextClick: ((CGPoint) -> Void)?

    /// Called once per text-session commit with the session's description
    /// (its wrap width rides inside it as the box), the canvas-space origin
    /// of the text block, and the text layer being re-edited (nil when the
    /// session is new). The receiver renders the description into a text
    /// LAYER; the canvas itself paints nothing.
    var onCommitText: ((_ payload: TextLayerPayload, _ origin: CGPoint, _ editingLayer: Int?) -> Void)?

    /// Fired whenever a text session goes away, committed or cancelled (the
    /// receiver drops any preview it put up for the session).
    var onTextSessionEnd: (() -> Void)?

    var onToolKey: ((EditorTool) -> Void)?
    var onBrushSizeKey: ((CGFloat) -> Void)?
    /// Bare Q, handled with the tool keys (deliberately not a menu key
    /// equivalent): toggles Quick Mask mode.
    var onQuickMaskKey: (() -> Void)?

    // Free Transform. The canvas owns none of the geometry: it reports the
    // gesture in image pixel coordinates (unclamped — handles are routinely
    // dragged off-canvas) and the view controller turns that into the
    // session's parameters.
    var onTransformMouseDown: ((CGPoint, NSEvent.ModifierFlags) -> Void)?
    var onTransformMouseDragged: ((CGPoint, NSEvent.ModifierFlags) -> Void)?
    var onTransformMouseUp: ((CGPoint, NSEvent.ModifierFlags) -> Void)?
    /// Return, keypad Enter, or a double-click.
    var onTransformCommit: (() -> Void)?
    /// Escape.
    var onTransformCancel: (() -> Void)?
    /// Arrow keys (Shift: 10px), in image pixels.
    var onTransformNudge: ((_ dx: CGFloat, _ dy: CGFloat) -> Void)?

    // Move tool: the view only reports gestures; the view controller owns
    // the selected entries' offsets and the document's live-edit session.
    // The BEGIN carries the click point and its modifiers, because
    // Auto-Select decides which entry the drag moves from where the press
    // landed (EditorViewController+Groups.swift).
    var onMoveBegin: ((_ point: CGPoint, _ modifiers: NSEvent.ModifierFlags) -> Void)?
    /// The TOTAL delta from the press, plus the live modifiers — ⌃ suspends
    /// snapping and must be read on every tick (see onCropMouseDragged).
    var onMoveUpdate: ((_ dx: Int, _ dy: Int, _ modifiers: NSEvent.ModifierFlags) -> Void)?
    var onMoveEnd: (() -> Void)?
    var onMoveNudge: ((_ dx: Int, _ dy: Int) -> Void)?

    /// The active selection (rect, ellipse, polygon, or wand mask).
    private(set) var selection: CanvasSelection?

    /// Bounding box of the selection in image pixel coordinates (what
    /// rectangle-shaped consumers like Crop use).
    var selectionRect: CGRect? { selection?.bounds }

    var onSelectionChange: ((CGRect?) -> Void)?

    /// Fired on a wand-tool click (image pixel coordinates, plus the
    /// combine mode read from the click's modifiers).
    var onWandClick: ((CGPoint, SelectionCombineMode) -> Void)?
    /// Fired on a fill-tool click.
    var onFillClick: ((CGPoint) -> Void)?
    /// Fired on every eyedropper sample tick — the mouse-down and each drag
    /// tick of the eyedropper tool, or of Option-click borrowing it from
    /// brush/fill/gradient. The point is UNCLAMPED image pixels: samples
    /// outside the canvas are the receiver's no-op, not an edge pin.
    var onEyedropper: ((CGPoint) -> Void)?
    /// Fired on every cursor move over the canvas (UNCLAMPED image pixels)
    /// and once with nil when the cursor leaves — the Info panel's readout.
    /// Pure reporting: the handler must never set `needsDisplay`, or every
    /// mouse-moved event would redraw the canvas.
    var onCursorMove: ((CGPoint?) -> Void)?
    /// Fired when a gradient drag commits (start, end in image pixels).
    var onGradientCommit: ((CGPoint, CGPoint) -> Void)?

    // Lasso state: committed vertices of the in-progress polygon.
    private var lassoPoints: [CGPoint] = []

    // Selection-combine state, decided at gesture start (mouse-down for
    // marquee drags, the click that starts a new lasso polygon): Shift =
    // add, Option = subtract, Shift+Option = intersect. Marquee drags
    // also stash the pre-drag selection, since the live drag preview
    // replaces it on every tick.
    private var dragCombineMode: SelectionCombineMode = .replace
    private var dragBaseSelection: CanvasSelection?
    private var lassoCombineMode: SelectionCombineMode = .replace

    // Gradient drag state.
    private var gradientAnchor: CGPoint?
    private var gradientCurrent: CGPoint?

    var hasActiveTextSession: Bool { activeTextView != nil }

    private var dragAnchor: CGPoint?

    /// The last marquee drag tick's SNAPPED rect — what the user is looking
    /// at — latched so that is what commits, the way `shapePreview` latches
    /// the shape drag's. nil until the first tick, and again after the
    /// commit.
    private var marqueePreview: CGRect?

    // Move-drag state: the unclamped image-space point the drag started at.
    private var moveDragOrigin: CGPoint?

    // True from an eyedropper mouse-down (the tool, or Option borrowing it)
    // to its mouse-up: the whole gesture samples, whatever the tool's own
    // drag would otherwise do.
    private var eyedropperDragActive = false

    // Stroke state (brush/eraser). `strokeOnMask` latches paintsMask at
    // mouse-down so nothing (an agent edit landing on the main thread, a
    // panel click) can switch a stroke's target halfway through it.
    // `strokeOnQuickMask` latches the mode the same way: a Quick Mask
    // stroke edits ONLY the mode's coverage buffer — no document edit, no
    // undo step, no callbacks.
    private var strokeActive = false
    /// Non-nil while a HEALING stroke is in flight, latched at mouse-down.
    private var strokeHealKind: EditorTool?
    private var strokeOnMask = false
    private var strokeOnQuickMask = false
    private var strokeLastPoint: CGPoint?
    private var strokeSpline = StrokeSpline()

    // Quick Mask mode: the selection as an editable canvas-sized coverage
    // buffer under a rubylith tint. Pure per-editor VIEW state — it never
    // touches the document, and entering/leaving is not undoable, exactly
    // like the selection it stands in for. `quickMaskImage` is the tint's
    // alpha source (grayscale 255 − coverage), rebuilt whenever the
    // coverage on display changes.
    /// A colour plane or an alpha channel on display (ChannelDisplay.swift):
    /// its base replaces the projection and its overlays wash over it. Pure
    /// VIEW state pushed in by EditorViewController+Channels; nil = the
    /// normal composite.
    var channelDisplay: ChannelDisplay? {
        didSet { needsDisplay = true }
    }

    private(set) var quickMaskActive = false
    private var quickMaskBuffer: [UInt8] = []
    private var quickMaskWidth = 0
    private var quickMaskHeight = 0
    private var quickMaskImage: CGImage?

    // Full-image premultiplied overlay accumulating stroke geometry. Never
    // drawn directly: the projection previews strokes via the live-edit
    // round trip.
    private var overlayData: UnsafeMutableRawPointer?
    private var overlayContext: CGContext?
    private var overlayWidth = 0
    private var overlayHeight = 0

    private var activeTextView: CanvasTextView?
    /// The text layer the active session re-edits; nil for a new one.
    private var textSessionLayer: Int?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // Text sessions must never display glyphs the image-sized commit overlay
    // will discard (apps linked against macOS 14+ stop clipping subviews by
    // default).
    override var clipsToBounds: Bool {
        get { true }
        set {}
    }

    deinit {
        overlayContext = nil
        overlayData?.deallocate()
    }

    private static let checkerboardColor: NSColor = {
        let tile = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
            DS.checkerB.setFill()
            rect.fill()
            DS.checkerA.setFill()
            NSRect(x: 0, y: 0, width: 10, height: 10).fill()
            NSRect(x: 10, y: 10, width: 10, height: 10).fill()
            return true
        }
        return NSColor(patternImage: tile)
    }()

    /// Current zoom factor: image pixels are drawn this many screen points
    /// wide, so `1 / magnification` is the image-space size of one screen
    /// point (what every on-canvas hairline and hit slop is expressed in).
    var magnification: CGFloat {
        max(enclosingScrollView?.magnification ?? 1, 0.001)
    }

    // MARK: - Overlay

    /// Lazily creates the overlay buffer + context at the current image pixel
    /// size. The context is flipped so overlay row 0 is the image's top row
    /// and drawing coordinates match the flipped view coordinates.
    private func ensureOverlayContext() -> CGContext? {
        if let context = overlayContext { return context }
        guard let image = image, image.width > 0, image.height > 0 else { return nil }
        let width = image.width
        let height = image.height
        let byteCount = width * height * 4
        let data = UnsafeMutableRawPointer.allocate(
            byteCount: byteCount, alignment: MemoryLayout<UInt8>.alignment)
        data.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
        guard let context = CGContext(
                data: data,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: documentColorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            data.deallocate()
            return nil
        }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        overlayData = data
        overlayContext = context
        overlayWidth = width
        overlayHeight = height
        return context
    }

    /// Empties the overlay for reuse — or throws it away outright when a
    /// profile change arrived while it was in use, since its bytes are then
    /// in the space the document has left. Every path that finishes with the
    /// buffer (both stroke ends, the `image` setter) comes through here, so
    /// the deferred teardown needs no second site.
    private func clearOverlay() {
        if overlayColorSpaceIsStale {
            destroyOverlay()
            return
        }
        guard let context = overlayContext else { return }
        context.clear(CGRect(x: 0, y: 0, width: overlayWidth, height: overlayHeight))
    }

    private func destroyOverlay() {
        // The next context is built in whatever space the document has now,
        // so the staleness goes with the buffer — every teardown path,
        // including the `image` setter's size change, clears it here.
        overlayColorSpaceIsStale = false
        overlayContext = nil
        overlayData?.deallocate()
        overlayData = nil
        overlayWidth = 0
        overlayHeight = 0
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        // Checkerboard under the image rect (the view's bounds are exactly
        // the image rect).
        Self.checkerboardColor.setFill()
        bounds.intersection(dirtyRect).fill()

        // Live strokes preview through the projection itself (the live-edit
        // round trip), so the image is always the truth; the overlay is
        // never composited here.
        let context = NSGraphicsContext.current!.cgContext
        if let preview = transformPreview {
            drawTransformPreview(preview, in: context)
        } else if cropOverlay == nil, channelDisplay?.replacesComposite == true {
            // A plane, a channel or the mask on display draws instead of the
            // projection — and with every eye off, nothing draws at all and
            // the checkerboard is what is left. Never during a crop, whose
            // straighten preview rotates the real image. previewImage still
            // wins inside drawBase, so a sheet previewing an op ON this
            // plane shows through.
            channelDisplay?.drawBase(
                in: context, bounds: bounds, preview: previewImage,
                quality: imageInterpolation)
        } else if let cgImage = previewImage ?? image {
            if let crop = cropOverlay, crop.angle != 0 {
                // Straighten preview: the image rotates about the crop
                // box's center while the box stays axis-aligned — the same
                // matrix (sign included) the commit hands the core.
                context.saveGState()
                let center = CGPoint(x: crop.rect.midX, y: crop.rect.midY)
                context.translateBy(x: center.x, y: center.y)
                context.rotate(by: -crop.angle * .pi / 180)
                context.translateBy(x: -center.x, y: -center.y)
                drawFlipped(cgImage, in: context)
                context.restoreGState()
            } else {
                drawFlipped(cgImage, in: context)
            }
        }

        // Quick Mask mode: the rubylith tint over the whole image. During
        // a stroke the tint is rebuilt per tick (emitStrokeUpdate), so this
        // is always the buffer-plus-stroke on display.
        if quickMaskActive {
            drawQuickMaskOverlay(in: context)
        }

        // Channel rubyliths: one wash per visible alpha channel (and the
        // layer mask), in row order, over whatever the base turned out to be
        // — but never over a sheet's preview OF that same plane, which the
        // canvas is drawing full-frame in grayscale (ChannelDisplay), and
        // never during a crop, which the whole channel display stands down
        // for: the straighten preview rotates the picture while a wash would
        // stay axis-aligned on top of it, showing the channel where it will
        // NOT land (commitCropSession rotates every channel through the very
        // same matrix). The washes return when the crop commits or cancels,
        // exactly as the base does.
        if cropOverlay == nil {
            channelDisplay?.drawOverlays(
                in: context, bounds: bounds,
                previewingPlane: previewImage != nil && paintTarget.targetsPlaneOrChannel)
        }

        // The document grid and the one-pixel lattice: above the base image
        // and its washes, below every overlay being manipulated (the slot's
        // reasoning is in ImageCanvasView+Grid.swift). Both stand down
        // during a crop STRAIGHTEN — `gridsStandDown`, which is the angle
        // and not the session — for the reason the washes just above give:
        // the preview rotates the picture while an axis-aligned grid would
        // not, showing the grid where it will not land. An axis-aligned crop
        // keeps its grid, because cropping to the grid is what having both
        // on is for.
        if !gridsStandDown {
            drawDocumentGrid(in: context, dirty: dirtyRect)
            drawPixelGrid(in: context, dirty: dirtyRect)
        }

        // A coverage stroke in progress: the projection has not moved, so the
        // overlay itself is ghosted on top until the stroke commits — ABOVE
        // the washes, since a wash drawn over it hid the very stroke that is
        // about to change that wash (drawMaskStrokeGhost picks the colour).
        drawMaskStrokeGhost(in: context)

        // Paint can only land inside the active layer's extent; when that is
        // smaller than the canvas, show the boundary so strokes and text
        // outside it don't silently vanish. Gated on the TARGET, not on what
        // is being displayed: a layer, its mask and its colour planes are all
        // clipped to that extent, while a Quick Mask stroke and a channel
        // stroke land on a canvas-sized buffer the layer says nothing about,
        // so the boundary would mislead there. Nothing else can reach a
        // channel: clone and dodge strokes are refused by `onStrokeBegin` and
        // a text session by `refuseChannelTargetEdit`, so there is no edit
        // left for the guide to place.
        if tool.usesBrushTip || tool == .text || tool == .patch || tool == .redEye,
           !isTransforming,
           !quickMaskActive, !paintTarget.isChannel,
           let layerRect = activeLayerRect,
           layerRect != CGRect(origin: .zero, size: bounds.size) {
            drawActiveLayerBounds(layerRect)
        }

        // A transform ignores the selection entirely, and its dimming wash
        // and marquee would fight the box: the selection survives the
        // session, it just stops drawing for it.
        // A plane or channel on display is NOT such a case: the selection is
        // live there and still clips every stroke, fill and gradient, so
        // hiding it would confine an edit with nothing on screen to say why.
        // (Quick Mask is different — it consumed the selection on entry.)
        if let selection = selection, !isTransforming {
            drawSelection(selection)
        }

        // Guides sit ABOVE the selection: drawSelection washes everything
        // outside the selection with 0.35 black, and a guide drawn under it
        // would be visibly dimmed inside the same document depending on
        // whether a selection happened to exist.
        drawGuides()
        drawRulerOriginCrosshair()

        // Both of these belong to a tool gesture the session has suspended;
        // like the selection, they survive it without drawing over the box.
        if !lassoPoints.isEmpty, !isTransforming {
            drawLassoPreview()
        }

        if let anchor = gradientAnchor, let current = gradientCurrent, !isTransforming {
            drawGradientPreview(from: anchor, to: current)
        }

        if let outline = subjectSession.outline, !isTransforming {
            drawSubjectOutline(outline)
        }

        if !isTransforming {
            patchSession.draw(in: context, image: image, magnification: magnification)
            redEyeSession.draw(in: context, magnification: magnification)
        }

        if let textView = activeTextView {
            drawTextSessionBorder(textView.frame)
        }

        if let crop = cropOverlay, !isTransforming {
            drawCropOverlay(crop)
        }

        if let preview = shapePreview, !isTransforming {
            drawShapePreview(preview)
        }

        if let overlay = shapeEditOverlay, !isTransforming {
            drawShapeEditOverlay(overlay)
        }

        if tool == .clone || tool == .heal, let source = cloneSource, !isTransforming {
            drawCloneSourceMarker(cloneSourceMarkerPoint(source))
        }

        if let marquee = zoomMarquee {
            drawZoomMarquee(marquee)
        }

        // Deliberately NOT gated on !isTransforming, unlike the overlays
        // above: a Free Transform drag is one of the two gestures that
        // produce smart guides.
        drawSmartGuides()

        if let preview = transformPreview {
            drawTransformBox(preview)
        }
    }

    /// Where the source marker belongs: the point the next dab will sample
    /// from, which is not always the ⌥-clicked one.
    ///
    /// With no latched offset — the Clone Stamp always, the Healing Brush
    /// with Aligned off — every stroke re-aims from the source point, so the
    /// marker IS the source point. With an Aligned offset latched the offset
    /// is what persists and the sampled point tracks the brush; a marker left
    /// on the source point then sits on pixels the tool is not reading (and
    /// happily keeps sitting there while the sampled point has walked off the
    /// canvas and the heal refuses with a beep). Falls back to the source
    /// point when the pointer is outside the canvas and there is nothing to
    /// aim from.
    private func cloneSourceMarkerPoint(_ source: CGPoint) -> CGPoint {
        guard strokeAligned, cloneOffsetTool == tool,
            let brush = strokeActive ? Optional(strokeCursor) : hoverPoint
        else { return source }
        return CGPoint(x: brush.x - cloneOffset.dx, y: brush.y - cloneOffset.dy)
    }

    /// The clone tool's ⌥-set source point: a small crosshair ring, scaled
    /// to keep its screen size at any zoom.
    private func drawCloneSourceMarker(_ source: CGPoint) {
        let scale = magnification
        let radius = 5 / scale
        let ring = NSBezierPath(
            ovalIn: CGRect(
                x: source.x - radius, y: source.y - radius,
                width: radius * 2, height: radius * 2))
        let arms = NSBezierPath()
        for (dx, dy) in [(1.0, 0.0), (-1.0, 0.0), (0.0, 1.0), (0.0, -1.0)] {
            arms.move(to: CGPoint(x: source.x + dx * radius, y: source.y + dy * radius))
            arms.line(to: CGPoint(
                x: source.x + dx * radius * 1.9, y: source.y + dy * radius * 1.9))
        }
        for (path, width) in [(ring, 2.5 / scale), (arms, 2.5 / scale)] {
            path.lineWidth = width
            NSColor.black.withAlphaComponent(0.45).setStroke()
            path.stroke()
        }
        for (path, width) in [(ring, 1 / scale), (arms, 1 / scale)] {
            path.lineWidth = width
            NSColor.white.withAlphaComponent(0.95).setStroke()
            path.stroke()
        }
    }

    /// The zoom tool's drag rectangle: a plain dashed hairline (not the
    /// coral marquee — this is a view gesture, not a selection).
    private func drawZoomMarquee(_ rect: CGRect) {
        let scale = magnification
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 1 / scale
        let dash: [CGFloat] = [4 / scale, 3 / scale]
        path.setLineDash(dash, count: dash.count, phase: 0)
        NSColor.white.withAlphaComponent(0.9).setStroke()
        path.stroke()
    }

    /// Un-flips the context so the CGImage is not drawn upside down, then
    /// draws it over the full image rect.
    /// How the image on the canvas is resampled, in one place: nearest
    /// neighbour at 100% and above, so a zoomed-in pixel reads as a square,
    /// smooth below. A plane or channel base draws by the same rule
    /// (`ChannelDisplay.drawBase` takes it), or the picture would turn crisp
    /// and its own colour plane blurry at the same zoom.
    var imageInterpolation: CGInterpolationQuality {
        magnification >= 1.0 ? .none : .high
    }

    private func drawFlipped(_ cgImage: CGImage, in context: CGContext) {
        context.saveGState()
        context.interpolationQuality = imageInterpolation
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(cgImage, in: CGRect(origin: .zero, size: bounds.size))
        context.restoreGState()
    }

    /// Quick-mask-style ghost of an in-progress MASK stroke: a translucent
    /// red wash wherever the overlay has coverage. Painting a mask changes
    /// coverage, not color, so previewing the overlay's own white/black
    /// pixels would read as paint; and re-compositing the masked projection
    /// on every tick is deliberately not attempted. The true result appears
    /// when the stroke commits on mouse-up.
    private func drawMaskStrokeGhost(in context: CGContext) {
        guard strokeActive, let overlay = overlayContext?.makeImage(),
              strokeOnMask || strokeHealKind == .spotHeal else { return }
        // The ghost's colour depends on what is underneath. Over the PICTURE
        // (a mask stroke with no wash on, the default) red at half alpha is
        // just "you painted here". But when the canvas is already showing the
        // very coverage being painted — a channel's rubylith, or that plane
        // or channel drawn as the grayscale base — red is the wash's own
        // colour, and a red stroke there reads as MORE mask exactly where the
        // brush is ADDING coverage. So the ghost is then drawn as the
        // coverage it paints: white for the brush, black for the eraser, the
        // vocabulary this whole feature uses. It sits over the wash rather
        // than under it, and commits into it at mouse-up.
        let onCoverage = channelDisplay?.shows(paintTarget) == true
        // A spot-heal footprint ghosts BLUE: not coverage being painted, but
        // the region the inpaint replaces at mouse-up.
        let color: NSColor = strokeHealKind == .spotHeal ? .systemBlue
            : (onCoverage ? (tool == .eraser ? .black : .white) : .systemRed)
        context.saveGState()
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        let rect = CGRect(origin: .zero, size: bounds.size)
        // A coverage ghost has to read over a 50% wash, so it is drawn more
        // opaque than the ghost over a plain picture.
        context.setAlpha(onCoverage ? 0.85 : 0.5)
        // Draw the stroke, then flood its alpha with the colour: sourceIn
        // keeps the fill only where the overlay covered something.
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.draw(overlay, in: rect)
        context.setBlendMode(.sourceIn)
        context.setFillColor(color.cgColor)
        context.fill(rect)
        context.endTransparencyLayer()
        context.restoreGState()
    }

    /// A free-transform session's canvas: the stack below the layer, the
    /// layer's cached pixels pushed through the session's matrix, then the
    /// stack above it. No core call is involved — this is the cheap preview
    /// of a resample that happens exactly once, at commit.
    private func drawTransformPreview(_ preview: TransformPreview, in context: CGContext) {
        if let below = preview.below {
            drawFlipped(below, in: context)
        }
        if preview.warped {
            // A distorted quad is beyond the CTM (affine-only): the Core
            // Image warp in PerspectivePreview draws the layer instead.
            PerspectivePreview.drawLayer(preview, in: context, visible: bounds)
        } else if let layer = preview.layer, preview.sourceRect.width > 0,
                  preview.sourceRect.height > 0 {
            context.saveGState()
            context.interpolationQuality = preview.interpolate ? .high : .none
            context.setAlpha(preview.opacity)
            // The matrix is in CANVAS coordinates, which is this flipped
            // view's own space, so it concatenates as-is; the image then
            // needs the usual local un-flip to land right side up in the
            // layer's rect.
            context.concatenate(preview.matrix)
            context.translateBy(x: preview.sourceRect.minX, y: preview.sourceRect.maxY)
            context.scaleBy(x: 1, y: -1)
            let local = CGRect(origin: .zero, size: preview.sourceRect.size)
            // The mask is the layer's own size and rides along with it, so
            // it clips in this same local space (white shows, black hides).
            if let mask = preview.mask {
                context.clip(to: local, mask: mask)
            }
            context.draw(layer, in: local)
            context.restoreGState()
        }
        if let above = preview.above {
            drawFlipped(above, in: context)
        }
    }

    /// The transform box: a hairline through the four transformed corners,
    /// the eight handles that scale it, and a marker on the pivot every
    /// rotation turns around. Scaled by 1/magnification so it keeps its
    /// SCREEN size at any zoom, exactly like the marquee.
    private func drawTransformBox(_ preview: TransformPreview) {
        let corners = preview.quad
        guard corners.count == 4 else { return }
        let scale = magnification

        let path = NSBezierPath()
        path.move(to: corners[0])
        for corner in corners.dropFirst() {
            path.line(to: corner)
        }
        path.close()
        path.lineWidth = 3 / scale
        NSColor.black.withAlphaComponent(0.45).setStroke()
        path.stroke()
        path.lineWidth = 1 / scale
        NSColor.white.withAlphaComponent(0.95).setStroke()
        path.stroke()

        // Pivot marker: a small hollow ring, drawn under the handles.
        let pivotRadius = 4 / scale
        let pivot = NSBezierPath(
            ovalIn: CGRect(
                x: preview.pivot.x - pivotRadius, y: preview.pivot.y - pivotRadius,
                width: pivotRadius * 2, height: pivotRadius * 2))
        pivot.lineWidth = 2.5 / scale
        NSColor.black.withAlphaComponent(0.45).setStroke()
        pivot.stroke()
        pivot.lineWidth = 1 / scale
        NSColor.white.withAlphaComponent(0.95).setStroke()
        pivot.stroke()

        let size = Self.transformHandleSize / scale
        for point in Self.transformHandlePoints(corners) {
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

    /// Side of a transform handle in SCREEN points.
    static let transformHandleSize: CGFloat = 8

    /// The eight handle positions of a transform box, derived from its four
    /// transformed corners: the corners themselves, then the midpoint of
    /// each edge (an affine image of a rectangle is a parallelogram, so the
    /// midpoints are exactly the transformed edge midpoints).
    static func transformHandlePoints(_ corners: [CGPoint]) -> [CGPoint] {
        guard corners.count == 4 else { return [] }
        var points = corners
        for index in 0..<4 {
            let a = corners[index]
            let b = corners[(index + 1) % 4]
            points.append(CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2))
        }
        return points
    }

    private func drawSelection(_ selection: CanvasSelection) {
        // Dim everything outside the selected region.
        if let outline = selection.path {
            let dimPath = NSBezierPath(rect: bounds)
            dimPath.append(outline)
            dimPath.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.35).setFill()
            dimPath.fill()
        } else if let context = NSGraphicsContext.current?.cgContext {
            // Mask (wand) selection: clip to the inverse coverage.
            context.saveGState()
            selection.clipOutside(context)
            context.setFillColor(NSColor.black.withAlphaComponent(0.35).cgColor)
            context.fill(bounds)
            context.restoreGState()
        }

        // 2px dashed coral marquee — one of the design's two sanctioned
        // coral elements. Scaled by 1/magnification to stay 2 screen px.
        // Mask selections get the marquee on their traced contour.
        let path = selection.marqueePath ?? NSBezierPath(rect: selection.bounds)
        strokeMarquee(path)
    }

    private func strokeMarquee(_ path: NSBezierPath) {
        let scale = magnification
        path.lineWidth = 2 / scale
        let dashPattern: [CGFloat] = [5 / scale, 4 / scale]
        path.setLineDash(dashPattern, count: dashPattern.count, phase: 0)
        DS.marquee.setStroke()
        path.stroke()
    }

    /// In-progress lasso polygon: dashed polyline plus vertex dots.
    private func drawLassoPreview() {
        let scale = magnification
        let path = NSBezierPath()
        path.move(to: lassoPoints[0])
        for point in lassoPoints.dropFirst() {
            path.line(to: point)
        }
        strokeMarquee(path)
        let radius = 3 / scale
        DS.marquee.setFill()
        for point in lassoPoints {
            NSBezierPath(
                ovalIn: CGRect(
                    x: point.x - radius, y: point.y - radius,
                    width: radius * 2, height: radius * 2)
            ).fill()
        }
    }

    /// Gradient drag rubber band: a line with endpoint dots.
    private func drawGradientPreview(from a: CGPoint, to b: CGPoint) {
        let scale = magnification
        let line = NSBezierPath()
        line.move(to: a)
        line.line(to: b)
        line.lineWidth = 2 / scale
        DS.marquee.setStroke()
        line.stroke()
        let radius = 4 / scale
        DS.marquee.setFill()
        for point in [a, b] {
            NSBezierPath(
                ovalIn: CGRect(
                    x: point.x - radius, y: point.y - radius,
                    width: radius * 2, height: radius * 2)
            ).fill()
        }
    }

    /// The subject under the pointer while the Subject tool is held.
    ///
    /// SOLID, unlike every other overlay here, and that is the point: a
    /// dashed line would read as a committed selection, and this one is a
    /// proposal that vanishes if the mouse comes up somewhere else. Drawn
    /// dark-then-light so it survives both a white shirt and a black one.
    private func drawSubjectOutline(_ path: NSBezierPath) {
        let scale = magnification
        // setLineDash is sticky on NSBezierPath and this same path object
        // becomes the marquee once the selection commits, so the dash the
        // marquee left behind has to be cleared rather than inherited.
        path.setLineDash(nil, count: 0, phase: 0)
        // Each pass carries the contrast on one kind of image — the dark
        // halo on a light subject, the light core on a dark one — so both
        // have to be heavy enough to read alone, not merely to edge the
        // other. A thin pair vanishes into a pale background.
        path.lineWidth = 5 / scale
        NSColor.black.withAlphaComponent(0.65).setStroke()
        path.stroke()
        path.lineWidth = 2.5 / scale
        NSColor.white.setStroke()
        path.stroke()
    }

    /// Subtle dashed outline (selection stroke style, thinner) marking the
    /// active layer's extent for the paint tools.
    private func drawActiveLayerBounds(_ rect: CGRect) {
        let scale = magnification
        let lineWidth = 0.5 / scale
        let dashPattern: [CGFloat] = [4 / scale, 4 / scale]

        let blackPath = NSBezierPath(rect: rect)
        blackPath.lineWidth = lineWidth
        blackPath.setLineDash(dashPattern, count: dashPattern.count, phase: 0)
        NSColor.black.withAlphaComponent(0.6).setStroke()
        blackPath.stroke()

        let whitePath = NSBezierPath(rect: rect)
        whitePath.lineWidth = lineWidth
        whitePath.setLineDash(dashPattern, count: dashPattern.count, phase: 4 / scale)
        NSColor.white.withAlphaComponent(0.6).setStroke()
        whitePath.stroke()
    }

    /// Dashed hairline border (selection style) around the active text
    /// session's frame.
    private func drawTextSessionBorder(_ frame: NSRect) {
        let scale = magnification
        let rect = frame.insetBy(dx: -2, dy: -2)
        let lineWidth = 1 / scale
        let dashPattern: [CGFloat] = [4 / scale, 4 / scale]

        let blackPath = NSBezierPath(rect: rect)
        blackPath.lineWidth = lineWidth
        blackPath.setLineDash(dashPattern, count: dashPattern.count, phase: 0)
        NSColor.black.setStroke()
        blackPath.stroke()

        let whitePath = NSBezierPath(rect: rect)
        whitePath.lineWidth = lineWidth
        whitePath.setLineDash(dashPattern, count: dashPattern.count, phase: 4 / scale)
        NSColor.white.setStroke()
        whitePath.stroke()
    }

    // MARK: - Selection

    func setSelection(_ new: CanvasSelection?) {
        // A selection arriving from outside the mode (an agent select_*
        // call — the UI's selection paths are inert while it is active)
        // supersedes a Quick Mask session: end it rather than leave a
        // stale buffer under a live marquee. Exit passes through here with
        // quickMaskActive already false, and entry only ever passes nil.
        if quickMaskActive, new != nil {
            discardQuickMask()
        }
        selection = new
        needsDisplay = true
        onSelectionChange?(new?.bounds)
    }

    /// A canvas rect as `select_rect` / `select_ellipse` spell it. Absolute
    /// canvas pixels, never remapped — see `ActionSymbol`.
    private static func rectArguments(_ rect: CGRect) -> [String: Any] {
        [
            "x": Int(rect.minX.rounded()), "y": Int(rect.minY.rounded()),
            "width": max(Int(rect.width.rounded()), 1),
            "height": max(Int(rect.height.rounded()), 1),
        ]
    }

    /// Rectangle convenience used by Select All and the marquee drag.
    /// (Named distinctly: setSelection(nil) must stay unambiguous.)
    func setSelectionRect(_ rect: CGRect?) {
        guard let rect = rect else {
            setSelection(nil)
            return
        }
        setSelection(shapeSelection(.rect(rect.integral)))
    }

    /// Builds a CanvasSelection at the current image size.
    private func shapeSelection(_ shape: CanvasSelection.Shape) -> CanvasSelection? {
        CanvasSelection(
            shape: shape, canvasWidth: Int(bounds.width), canvasHeight: Int(bounds.height))
    }

    /// Applies a completed selection gesture: feathers the new shape by the
    /// options bar's radius, then combines it with the gesture's base
    /// selection under `mode`. A nil (empty) new shape deselects in replace
    /// mode and keeps the base otherwise.
    ///
    /// `record` is what this gesture is, as an action step. It is a
    /// PARAMETER because only the caller knows which shape it committed —
    /// and because `setSelection` below is not a command boundary: it fires
    /// on every mouseDragged tick of a marquee (a few hundred times per
    /// gesture) and again as a pure side effect whenever the canvas size
    /// changes, so hooking it would record noise.
    ///
    /// An empty new shape records nothing: in replace mode it is the
    /// click-to-deselect case, which the caller records itself, and in the
    /// combine modes it restores the base and changes nothing at all.
    ///
    /// `record` is an `@autoclosure` for `closeLasso`'s sake: a lasso's step
    /// carries the whole outline through `ActionArgs.points`, and it was
    /// built on every closed lasso whether or not anyone was recording. A
    /// selection gesture is never one of the `lastRepeatable` tools, which is
    /// what lets `recordGesture` skip it entirely (it asserts as much).
    private func commitSelection(
        _ new: CanvasSelection?, mode: SelectionCombineMode, base: CanvasSelection?,
        record: @autoclosure () -> [ActionStep]
    ) {
        guard var new = new else {
            setSelection(mode == .replace ? nil : base)
            return
        }
        if selectionFeather > 0, let feathered = new.feathered(by: selectionFeather) {
            new = feathered
        }
        setSelection(CanvasSelection.combine(base, with: new, mode: mode))
        ActionRecorder.shared.recordGesture(record())
    }

    /// Reads a gesture's combine mode: an explicit modifier wins, otherwise
    /// the options bar's mode applies. The convention itself lives on
    /// `SelectionCombineMode` (EditorViewController+SelectionIO), shared with
    /// the two panels' ⌘-clicks.
    private func combineMode(for event: NSEvent) -> SelectionCombineMode {
        SelectionCombineMode.from(event.modifierFlags, base: selectionCombineBase)
    }

    /// Discards the lasso in progress (Escape, tool switch).
    private func cancelLasso() {
        guard !lassoPoints.isEmpty else { return }
        lassoPoints = []
        needsDisplay = true
    }

    /// Closes the lasso polygon into a selection, combining under the
    /// mode read when the polygon was started.
    private func closeLasso() {
        let points = lassoPoints
        lassoPoints = []
        let mode = lassoCombineMode
        lassoCombineMode = .replace
        if points.count >= 3 {
            commitSelection(
                shapeSelection(.polygon(points)), mode: mode, base: selection,
                record: .selectShape(
                    "select_polygon", ["points": ActionArgs.points(points)],
                    mode: mode.agentName, feather: selectionFeather))
        } else {
            needsDisplay = true
        }
    }

    // MARK: - Quick Mask mode

    func toggleQuickMask() {
        // Mid-stroke the buffer (or the selection) is in flux; ignore the
        // toggle rather than tear the stroke's target out from under it.
        guard !strokeActive else {
            NSSound.beep()
            return
        }
        if quickMaskActive {
            exitQuickMask()
        } else {
            enterQuickMask()
        }
    }

    /// Entering: the current selection rasterizes into the coverage buffer
    /// (no selection ⇒ all zeros), the marquee hides (the selection is
    /// consumed — it comes back, edited, on exit), and any transient tool
    /// gesture is dropped the way a tool switch drops it.
    private func enterQuickMask() {
        guard let image = image, image.width > 0, image.height > 0 else {
            NSSound.beep()
            return
        }
        cancelLasso()
        gradientAnchor = nil
        gradientCurrent = nil
        dragAnchor = nil
        marqueePreview = nil
        // A shape drag caught mid-flight (Q lands during it) must not
        // commit a document edit into the mode.
        shapeAnchor = nil
        shapePreview = nil
        quickMaskWidth = image.width
        quickMaskHeight = image.height
        quickMaskBuffer =
            selection?.maskBytes()
            ?? [UInt8](repeating: 0, count: image.width * image.height)
        setSelection(nil)
        quickMaskActive = true
        rebuildQuickMaskImage(from: quickMaskBuffer)
        needsDisplay = true
    }

    /// Exiting: the buffer becomes the selection via the mask-kind path —
    /// contour, bounds, and marquee recompute; an all-zero buffer comes
    /// back nil and deselects.
    private func exitQuickMask() {
        guard quickMaskActive else { return }
        quickMaskActive = false
        let buffer = quickMaskBuffer
        let width = quickMaskWidth
        let height = quickMaskHeight
        clearQuickMaskState()
        setSelection(
            CanvasSelection(shape: .mask(buffer), canvasWidth: width, canvasHeight: height))
        // Quick Mask hands back a raw canvas-sized coverage mask, and no
        // catalog tool can express one — every `select_*` takes geometry. So
        // the whole session records ONE visible placeholder at its exit,
        // naming the gap rather than leaving a silent hole in the action.
        ActionRecorder.shared.record(.unrecorded("Quick Mask"))
    }

    /// Ends the session without converting the buffer (canvas size changed
    /// underneath it — the coverage is meaningless at the new size).
    private func discardQuickMask() {
        guard quickMaskActive else { return }
        quickMaskActive = false
        clearQuickMaskState()
        needsDisplay = true
    }

    private func clearQuickMaskState() {
        quickMaskBuffer = []
        quickMaskWidth = 0
        quickMaskHeight = 0
        quickMaskImage = nil
    }

    /// Rebuilds the rubylith's alpha source from `coverage`: grayscale
    /// 255 − coverage, so UNSELECTED areas carry the red tint (classic
    /// Photoshop) once drawQuickMaskOverlay scales it by 0.5.
    private func rebuildQuickMaskImage(from coverage: [UInt8]) {
        quickMaskImage = CanvasSelection.grayImage(
            coverage.map { 255 - $0 }, quickMaskWidth, quickMaskHeight)
    }

    /// The buffer with the in-progress stroke's overlay composited over it
    /// (source-over on coverage): the premultiplied gray channel is the
    /// source term — white brush = alpha, black eraser = 0 — so a brush
    /// stroke pulls coverage toward 255 and an eraser stroke toward 0,
    /// scaled by the stroke's own alpha (brush opacity). Used per tick for
    /// the live tint and once at mouse-up to land the stroke.
    private func quickMaskComposited() -> [UInt8] {
        var result = quickMaskBuffer
        guard let data = overlayData,
              overlayWidth == quickMaskWidth, overlayHeight == quickMaskHeight
        else { return result }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        // Soft strokes stamp full-alpha dabs; their opacity applies here,
        // once (strokeCoverageScale is 1 for the hard path, which bakes
        // opacity into the stroke color).
        let scale = Int((strokeCoverageScale * 255).rounded())
        for i in 0..<result.count {
            var alpha = Int(bytes[i * 4 + 3])
            var source = Int(bytes[i * 4])
            if scale < 255 {
                alpha = alpha * scale / 255
                source = source * scale / 255
            }
            guard alpha > 0 else { continue }
            let kept = Int(result[i]) * (255 - alpha) + 127
            result[i] = UInt8(min(255, source + kept / 255))
        }
        return result
    }

    /// The rubylith: red tint with per-pixel alpha 0.5 × (1 − coverage/255)
    /// — unselected areas red, selected areas clear. The grayscale mask
    /// multiplies the clip's alpha per pixel (the clipOutside convention),
    /// and the 0.5 rides in the fill color.
    private func drawQuickMaskOverlay(in context: CGContext) {
        guard let mask = quickMaskImage else { return }
        context.saveGState()
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        let rect = CGRect(origin: .zero, size: bounds.size)
        context.clip(to: rect, mask: mask)
        context.setFillColor(NSColor.systemRed.withAlphaComponent(0.5).cgColor)
        context.fill(rect)
        context.restoreGState()
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        // A free-transform session is modal over the tools: every click on
        // the canvas belongs to it until it commits or cancels.
        if isTransforming {
            if event.clickCount >= 2 {
                onTransformCommit?()
                return
            }
            onTransformMouseDown?(
                convert(event.locationInWindow, from: nil), event.modifierFlags)
            return
        }
        if hasActiveTextSession {
            commitTextSession()
            // With the text tool, this click only ends the session; the user
            // clicks again to start a new one.
            if tool == .text { return }
        }
        // A guide grab, intercepted ABOVE the Quick Mask gate and above the
        // eyedropper latch. Above the gate deliberately: that gate RETURNS
        // for every tool but zoom and hand (brush/eraser stroke and return,
        // the default arm beeps), so an intercept below it could never fire
        // in the mode and attempting a guide drag would beep — while a guide
        // drag reads and writes no pixel and never touches the mode's
        // buffer, so there is nothing here for Quick Mask to protect. WHICH
        // presses may take a guide — the Move tool's, and any tool's with ⌘
        // held — is `canGrabGuide`'s, in ImageCanvasView+Guides.swift, so
        // the hover cursor and this press cannot disagree.
        if canGrabGuide(event.modifierFlags),
           onGuideMouseDown?(
               convert(event.locationInWindow, from: nil), event.modifierFlags) == true
        {
            return
        }
        // Quick Mask mode: only brush (add coverage) and eraser (remove)
        // strokes are live — they edit the mode's buffer. The view tools
        // stay live too (they change what you see, never the document,
        // exactly like the scroll view's own pan and pinch); every other
        // tool's canvas interaction is inert.
        if quickMaskActive {
            switch tool {
            case .brush, .eraser:
                beginStroke(
                    at: clamp(point: convert(event.locationInWindow, from: nil)),
                    pressure: Self.tabletPressure(of: event))
                return
            case .zoom, .hand:
                break
            default:
                NSSound.beep()
                return
            }
        }
        // Eyedropper: the tool itself, or Option temporarily borrowing it
        // from brush/fill/gradient (whose Option is otherwise free — unlike
        // the selection tools, where Option means subtract). The gesture
        // latches so the drag keeps sampling, and the point stays UNCLAMPED
        // so a sample off the canvas is a no-op rather than an edge pin.
        // Sampling is not an edit: nothing here touches the document.
        if tool == .eyedropper
            || (event.modifierFlags.contains(.option)
                && (tool == .brush || tool == .fill || tool == .gradient)) {
            eyedropperDragActive = true
            onEyedropper?(convert(event.locationInWindow, from: nil))
            return
        }
        let point = clamp(point: convert(event.locationInWindow, from: nil))
        // The four gestures this view snaps by itself ask for their engine
        // HERE, once, and hold it for the press (DragSnapping.swift's
        // build-once rule). Only these four: every other tool's mouse-down
        // would be paying for a list it never reads.
        if Self.snappingCanvasTools.contains(tool), let engine = onSnapEngine?() {
            snapEngine = engine
        }
        switch tool {
        case .select, .ellipseSelect:
            // The RAW press point: `snappedMarqueeRect` snaps BOTH corners on
            // every tick with that tick's own ⌃ flag. Snapping the anchor
            // here instead pinned it to whatever it landed on at mouse-down,
            // so pressing ⌃ mid-drag freed the moving corner and left the
            // fixed one stuck on a line the user was trying to get off. The
            // anchor does not move, so its own pull answers identically on
            // every tick — the same argument the crop box and the shape drag
            // already make for snapping their fixed corner per tick.
            dragAnchor = point
            // Cleared here as well as at the commit, so the latch's life is
            // exactly this gesture's: a drag that never reaches `mouseUp`
            // (a tool switched mid-drag, a window closed) would otherwise
            // leave a rect behind for the NEXT press to commit on a click.
            marqueePreview = nil
            dragCombineMode = combineMode(for: event)
            dragBaseSelection = selection
        case .lasso:
            if event.clickCount >= 2 {
                closeLasso()
            } else if let first = lassoPoints.first,
                hypot(point.x - first.x, point.y - first.y) * magnification < 8,
                lassoPoints.count >= 3
            {
                // Clicking back on the first vertex closes the polygon.
                closeLasso()
            } else {
                if lassoPoints.isEmpty {
                    // The click that starts a new polygon decides the mode.
                    lassoCombineMode = combineMode(for: event)
                }
                // Clamped after the snap for the reason the marquee anchor
                // is: a lasso vertex is a canvas coordinate and every other
                // one in this file is inside the canvas.
                lassoPoints.append(
                    clamp(
                        point: snapEngine.snapped(
                            point: point,
                            in: SnapContext(
                                magnification: magnification,
                                suspended: event.modifierFlags.contains(.control)))))
                needsDisplay = true
            }
        case .wand:
            onWandClick?(point, combineMode(for: event))
        case .subject:
            // Same modifier conventions as the marquee gestures, decided
            // at mouse-down and held for the whole press.
            dragCombineMode = combineMode(for: event)
            dragBaseSelection = selection
            if subjectSession.hover(point, in: image) { needsDisplay = true }
            // Nothing salient in the picture at all is worth saying;
            // merely missing a subject is an ordinary miss, and silent.
            if subjectSession.subjectCount == 0 { NSSound.beep() }
        case .fill:
            onFillClick?(point)
        case .gradient:
            gradientAnchor = point
            gradientCurrent = point
            needsDisplay = true
        case .move:
            // Unclamped: deltas stay honest when the drag leaves the canvas.
            moveDragOrigin = convert(event.locationInWindow, from: nil)
            NSCursor.closedHand.set()
            onMoveBegin?(point, event.modifierFlags)
        case .brush, .eraser:
            beginStroke(at: point, pressure: Self.tabletPressure(of: event))
        case .text:
            // Deliberately unsnapped (DragSnapping.swift's table): this is a
            // click, not a drag — the insertion point is placed by the
            // layout, and snapping it would move a baseline the user never
            // aimed at.
            onTextClick?(point)
        case .eyedropper:
            break // handled before the switch
        case .crop:
            if event.clickCount >= 2 {
                onCropCommit?()
            } else {
                onCropMouseDown?(point)
            }
        case .clone, .heal:
            // ⌥ sets the source; a stroke without one has nothing to stamp.
            if event.modifierFlags.contains(.option) {
                cloneSource = point
            } else if cloneSource == nil {
                NSSound.beep()
            } else {
                beginStroke(at: point, pressure: Self.tabletPressure(of: event))
            }
        case .dodge, .spotHeal:
            beginStroke(at: point, pressure: Self.tabletPressure(of: event))
        case .patch:
            if patchSession.mouseDown(point, clickCount: event.clickCount,
                selection: selection, in: image, magnification: magnification,
                sampling: { self.onPatchSourceImage?() }) {
                needsDisplay = true
            }
        case .redEye:
            redEyeSession.mouseDown(point)
        case .shapeRect, .shapeEllipse, .shapeLine:
            if shapeEditOverlay != nil {
                if event.clickCount >= 2 {
                    onShapeEditCommit?()
                } else {
                    // Unclamped: a reopened shape (and its handles) may
                    // legitimately sit beyond the canvas edge.
                    onShapeEditMouseDown?(convert(event.locationInWindow, from: nil))
                }
            } else {
                shapeAnchor = point
            }
        case .zoom:
            zoomAnchor = point
            zoomAnchorWindow = event.locationInWindow
            zoomStartMagnification = magnification
            zoomDidScrub = false
        case .hand:
            handPanAnchorWindow = event.locationInWindow
            handPanScrollOrigin = enclosingScrollView?.contentView.bounds.origin
            NSCursor.closedHand.set()
        }
    }

    /// Mouse tracking exists for ONE reason — reporting the cursor's pixel
    /// to the Info panel — so it is the cheapest area that can do it.
    /// `.inVisibleRect` is the one deviation from ToolRailView's template:
    /// the canvas is a scroll view's document view and can be far larger
    /// than the window, and an area sized to `bounds` would both cover
    /// scrolled-away pixels and need rebuilding on every zoom.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [
                    .mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeInKeyWindow,
                ],
                owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        let raw = convert(event.locationInWindow, from: nil)
        // Clamped for the marker, because that is what `beginStroke` would
        // use as the dab's centre; the Info panel wants the raw point, which
        // is what `onCursorMove` has always carried.
        setHoverPoint(clamp(point: raw))
        // The hand-over-a-guide cursor. It invalidates the cursor rects only
        // when the value actually changes, and reads the same `canGrabGuide`
        // predicate mouseDown does — ⌘ included, which is why the event's
        // flags come with it (ImageCanvasView+Guides.swift).
        updateGuideHoverCursor(at: raw, modifiers: event.modifierFlags)
        onCursorMove?(raw)
    }

    override func mouseExited(with event: NSEvent) {
        setHoverPoint(nil)
        onCursorMove?(nil)
        // A guide's grab cursor belongs to the pointer being over the guide
        // (ImageCanvasView+Guides.swift).
        clearGuideHoverCursor()
    }

    /// Latches the pointer position, redrawing only the source marker's own
    /// two rectangles when it actually moves. An aligned source marker is the
    /// only overlay that tracks the pointer, and `needsDisplay` per
    /// mouse-moved event would be a whole-canvas repaint at pointer rate.
    private func setHoverPoint(_ point: CGPoint?) {
        guard strokeAligned, cloneOffsetTool == tool, let source = cloneSource,
            !isTransforming
        else {
            hoverPoint = point
            return
        }
        let before = cloneSourceMarkerPoint(source)
        hoverPoint = point
        let after = cloneSourceMarkerPoint(source)
        guard before != after else { return }
        setNeedsDisplay(markerBounds(before))
        setNeedsDisplay(markerBounds(after))
    }

    /// The source marker's dirty rect: the crosshair arms' outer reach plus
    /// the halo stroke, in canvas units, so it stays the same on screen at
    /// any zoom exactly as the marker itself does.
    private func markerBounds(_ point: CGPoint) -> CGRect {
        let reach = (5 * 1.9 + 3) / magnification
        return CGRect(
            x: point.x - reach, y: point.y - reach, width: reach * 2, height: reach * 2)
    }

    override func mouseDragged(with event: NSEvent) {
        let raw = convert(event.locationInWindow, from: nil)
        onCursorMove?(raw)
        if isTransforming {
            // Unclamped: transform handles are routinely dragged past the
            // canvas edges, and a layer may legitimately land outside it.
            onTransformMouseDragged?(raw, event.modifierFlags)
            return
        }
        if eyedropperDragActive {
            onEyedropper?(raw)
            return
        }
        // A guide drag owns the canvas until it is released.
        if guideDrag != nil {
            onGuideMouseDragged?(raw, event.modifierFlags)
            return
        }
        let suspended = event.modifierFlags.contains(.control)
        switch tool {
        case .select:
            guard let anchor = dragAnchor else { return }
            let rect = snappedMarqueeRect(
                from: anchor, to: raw, quantize: .wholePixels, suspended: suspended)
            marqueePreview = rect
            setSelectionRect(rect)
        case .ellipseSelect:
            guard let anchor = dragAnchor else { return }
            let rect = snappedMarqueeRect(
                from: anchor, to: raw, quantize: .exact, suspended: suspended)
            marqueePreview = rect
            setSelection(shapeSelection(.ellipse(rect)))
        case .lasso, .wand, .fill, .eyedropper:
            break
        case .subject:
            // The hit test is a byte read, so dragging across the photo
            // re-outlines whichever subject is under the pointer.
            if subjectSession.hover(clamp(point: raw), in: image) { needsDisplay = true }
        case .gradient:
            guard gradientAnchor != nil else { return }
            gradientCurrent = clamp(point: raw)
            needsDisplay = true
        case .move:
            guard let origin = moveDragOrigin else { return }
            NSCursor.closedHand.set()
            onMoveUpdate?(
                Int((raw.x - origin.x).rounded()), Int((raw.y - origin.y).rounded()),
                event.modifierFlags)
        case .brush, .eraser, .clone, .dodge, .heal, .spotHeal:
            // No clamping: the image-sized overlay context clips naturally,
            // so a stroke that leaves the canvas paints up to the edge and
            // stops instead of smearing along the border.
            //
            // And NO SNAPPING, deliberately (DragSnapping.swift's table): a
            // stroke is freehand, and pulling one dab to a guide would break
            // the spacing engine's arc length, leaving a gap or a blot at
            // the guide.
            continueStroke(to: raw, pressure: Self.tabletPressure(of: event))
        case .patch:
            if patchSession.mouseDragged(clamp(point: raw)) { needsDisplay = true }
        case .redEye:
            redEyeSession.mouseDragged(clamp(point: raw))
            needsDisplay = true
        case .text:
            break
        case .crop:
            onCropMouseDragged?(clamp(point: raw), event.modifierFlags)
        case .shapeRect, .shapeEllipse, .shapeLine:
            if shapeEditOverlay != nil {
                onShapeEditMouseDragged?(raw, event.modifierFlags)
                return
            }
            guard let anchor = shapeAnchor else { return }
            shapePreview = ShapeToolPreview(
                kind: tool, from: anchor, to: clamp(point: raw),
                constrained: event.modifierFlags.contains(.shift), style: shapeStyle,
                snap: snapEngine,
                context: SnapContext(magnification: magnification, suspended: suspended))
        case .zoom:
            guard let anchorWindow = zoomAnchorWindow, let anchor = zoomAnchor else { return }
            if scrubbyZoom {
                // Right scrubs in, left scrubs out; a full doubling per
                // 120 screen points feels like Photoshop's pace. A couple
                // of points of jitter is still a click, not a scrub.
                let dx = event.locationInWindow.x - anchorWindow.x
                guard zoomDidScrub || abs(dx) > 2 else { return }
                zoomDidScrub = true
                onZoomTo?(zoomStartMagnification * pow(2, dx / 120))
            } else {
                zoomMarquee = rect(from: anchor, to: clamp(point: raw))
                needsDisplay = true
            }
        case .hand:
            guard let anchorWindow = handPanAnchorWindow,
                  let origin = handPanScrollOrigin,
                  let scrollView = enclosingScrollView
            else { return }
            NSCursor.closedHand.set()
            // The clip view scrolls in the flipped document space, so a
            // window-up drag is a negative flipped-y delta; the content
            // follows the pointer.
            let scale = magnification
            let dx = (event.locationInWindow.x - anchorWindow.x) / scale
            let dy = (event.locationInWindow.y - anchorWindow.y) / scale
            scrollView.contentView.setBoundsOrigin(
                NSPoint(x: origin.x - dx, y: origin.y + dy))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if isTransforming {
            onTransformMouseUp?(
                convert(event.locationInWindow, from: nil), event.modifierFlags)
            return
        }
        if eyedropperDragActive {
            eyedropperDragActive = false
            return
        }
        if guideDrag != nil {
            onGuideMouseUp?()
            return
        }
        switch tool {
        case .select, .ellipseSelect:
            guard let anchor = dragAnchor else { return }
            dragAnchor = nil
            let mode = dragCombineMode
            let base = dragBaseSelection
            dragBaseSelection = nil
            // The LAST TICK'S rect, latched, so what commits is exactly what
            // was previewed — and so the 2-screen-point click threshold
            // below is measured on it too. Re-deriving here instead read the
            // ⌃ flag off the MOUSE-UP event: letting go of ⌃ a fraction of a
            // second before lifting the mouse snapped a rect the preview had
            // just shown free, and pressing it discarded a snap the preview
            // had shown, either way moving an edge by up to a pull radius at
            // the last instant. `guideMouseUp` refuses to consult mouse-up
            // flags for the same reason, and the shape drag and the crop box
            // are immune because they commit their last tick's geometry.
            // No tick means no preview: a press and release in one place is
            // a click, whose raw rect is degenerate and takes the click
            // branch below.
            let dragged = marqueePreview
                ?? rect(
                    from: clamp(point: anchor),
                    to: clamp(point: convert(event.locationInWindow, from: nil)))
            marqueePreview = nil
            // The click-vs-drag threshold is ~2 SCREEN points; `dragged` is in
            // image pixels, so scale by the current magnification. Otherwise a
            // deliberate 1-px-wide selection is impossible at high zoom, and at
            // low zoom a jittery click commits a many-pixel accidental selection.
            // The same number bounds how far `snappedMarqueeRect` may pull a
            // band, so it is named once (DragSnapping.swift).
            let scale = magnification
            let threshold = Self.marqueeClickScreenPoints
            if dragged.width * scale < threshold || dragged.height * scale < threshold {
                // Treat a tiny drag as click-to-deselect; with a combine
                // modifier held it restores the base selection instead.
                setSelection(mode == .replace ? nil : base)
                // A replace-mode click on empty canvas IS Deselect; with a
                // combine modifier held the base comes back unchanged, which
                // is not a command at all.
                if mode == .replace { ActionRecorder.shared.record(.deselect) }
            } else if tool == .ellipseSelect {
                commitSelection(
                    shapeSelection(.ellipse(dragged)), mode: mode, base: base,
                    record: .selectShape(
                        "select_ellipse", Self.rectArguments(dragged),
                        mode: mode.agentName, feather: selectionFeather))
            } else {
                let rect = dragged.integral
                commitSelection(
                    shapeSelection(.rect(rect)), mode: mode, base: base,
                    record: .selectShape(
                        "select_rect", Self.rectArguments(rect),
                        mode: mode.agentName, feather: selectionFeather))
            }
        case .lasso, .wand, .fill, .eyedropper:
            break
        case .subject:
            let mode = dragCombineMode
            let base = dragBaseSelection
            dragBaseSelection = nil
            // Releasing over the background keeps the selection as it was
            // rather than clearing it: with this tool a miss is usually
            // the segmentation's, not the user's.
            // Read BEFORE `end()`, which clears the session: the instance is
            // 1-based and is exactly what `select_subject` takes.
            let instance = subjectSession.subject
            if let found = subjectSession.end() {
                commitSelection(
                    found, mode: mode, base: base,
                    record: .selectSubject(instance: instance, mode: mode.agentName))
            }
            needsDisplay = true
        case .gradient:
            guard let anchor = gradientAnchor else { return }
            let end = clamp(point: convert(event.locationInWindow, from: nil))
            gradientAnchor = nil
            gradientCurrent = nil
            needsDisplay = true
            // A tiny drag is a misclick, not a gradient.
            if hypot(end.x - anchor.x, end.y - anchor.y) * magnification >= 4 {
                onGradientCommit?(anchor, end)
            }
        case .move:
            guard moveDragOrigin != nil else { return }
            moveDragOrigin = nil
            window?.invalidateCursorRects(for: self)
            onMoveEnd?()
        case .brush, .eraser, .clone, .dodge, .heal, .spotHeal:
            endStroke(at: convert(event.locationInWindow, from: nil))
        case .patch:
            let up = clamp(point: convert(event.locationInWindow, from: nil))
            needsDisplay = true
            if let result = patchSession.mouseUp(up) { onPatchCommit?(result) }
        case .redEye:
            let up = clamp(point: convert(event.locationInWindow, from: nil))
            needsDisplay = true
            if let rect = redEyeSession.mouseUp(up) { onRedEyeCommit?(rect) }
        case .text:
            break
        case .crop:
            onCropMouseUp?(clamp(point: convert(event.locationInWindow, from: nil)))
        case .shapeRect, .shapeEllipse, .shapeLine:
            if shapeEditOverlay != nil {
                onShapeEditMouseUp?()
                return
            }
            guard let anchor = shapeAnchor else { return }
            shapeAnchor = nil
            let preview = shapePreview
            shapePreview = nil
            needsDisplay = true
            // A tiny drag is a misclick, not a shape (~2 screen points,
            // like the marquee's click threshold).
            guard let preview = preview,
                  max(preview.box.width, preview.box.height) * magnification >= 2
            else { return }
            onShapeCommit?(preview.box, preview.flipped)
        case .zoom:
            let anchor = zoomAnchor
            let marquee = zoomMarquee
            zoomAnchor = nil
            zoomAnchorWindow = nil
            zoomMarquee = nil
            if marquee != nil { needsDisplay = true }
            guard let anchor = anchor else { return }
            // With scrubby on, the drag already zoomed — but a plain click
            // still steps the ladder rather than doing nothing.
            if scrubbyZoom {
                if !zoomDidScrub {
                    onZoomClick?(anchor, event.modifierFlags.contains(.option))
                }
                return
            }
            // A real drag zooms to the marquee; a click steps the ladder.
            if let marquee = marquee, marquee.width * magnification >= 4,
               marquee.height * magnification >= 4 {
                onZoomRect?(marquee)
            } else {
                onZoomClick?(anchor, event.modifierFlags.contains(.option))
            }
        case .hand:
            handPanAnchorWindow = nil
            handPanScrollOrigin = nil
            window?.invalidateCursorRects(for: self)
        }
    }

    private func clamp(point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, 0), bounds.width),
            y: min(max(point.y, 0), bounds.height))
    }

    /// The marquee's box, snapped — the ONE place a marquee rect is built,
    /// called on every drag tick and latched into `marqueePreview`, which is
    /// what the commit then uses. The commit does NOT call it again: a rect
    /// re-derived at mouse-up would carry the release event's ⌃ flag, not
    /// the last tick's, and could differ from the preview by a pull radius.
    ///
    /// BOTH corners snap, on every tick, under this tick's own `suspended`
    /// flag: the anchor is the raw press point, and a fixed corner snapped
    /// once at mouse-down could never be released by ⌃ for the rest of the
    /// gesture. Each result is re-clamped because a grid line just outside
    /// the canvas can be inside the pull of a point on its edge, and every
    /// other marquee coordinate is clamped.
    ///
    /// A SNAP THAT WOULD COLLAPSE THE BAND IS DROPPED, PER AXIS. The two
    /// corners snap INDEPENDENTLY, so a drag whose whole width (or height)
    /// fits inside one line's pull sends both corners to that line and the
    /// extent becomes zero — and `mouseUp` then reads its own click
    /// threshold on the latched rect and treats the drag as a click,
    /// CLEARING the user's selection instead of making the thin one they
    /// dragged. The dead band is the pull radius either side of every guide,
    /// grid line, layer edge and canvas edge, and it grows as the zoom drops
    /// (32 canvas px at 25 %). So each axis keeps its snapped coordinates
    /// only while they leave a band the commit will still call a drag; a
    /// deliberate thin drag falls back to the raw one and stays a drag. The
    /// crop box's rubber band has the same problem and answers it with a
    /// `max(abs(…), 1)` floor (`EditorViewController+Crop`, `.draw`); a
    /// per-axis fallback is the marquee's form of the same rule, and it
    /// keeps the OTHER axis's snap.
    func snappedMarqueeRect(
        from anchor: CGPoint, to point: CGPoint, quantize: SnapQuantize, suspended: Bool
    ) -> CGRect {
        let context = SnapContext(magnification: magnification, suspended: suspended)
        let raw = rect(from: clamp(point: anchor), to: clamp(point: point))
        let from = clamp(
            point: snapEngine.snapped(
                point: clamp(point: anchor), in: context, quantize: quantize))
        let to = clamp(
            point: snapEngine.snapped(
                point: clamp(point: point), in: context, quantize: quantize))
        let snapped = rect(from: from, to: to)
        let scale = magnification
        let threshold = Self.marqueeClickScreenPoints
        let keepX = !(raw.width * scale >= threshold && snapped.width * scale < threshold)
        let keepY = !(raw.height * scale >= threshold && snapped.height * scale < threshold)
        return CGRect(
            x: keepX ? snapped.minX : raw.minX, y: keepY ? snapped.minY : raw.minY,
            width: keepX ? snapped.width : raw.width,
            height: keepY ? snapped.height : raw.height)
    }

    private func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(a.x - b.x),
            height: abs(a.y - b.y))
    }

    // MARK: - Brush / eraser strokes

    /// Tablet pressure for a stroke event; nil for a plain mouse (or any
    /// event without tablet data), which strokes at constant full size.
    private static func tabletPressure(of event: NSEvent) -> CGFloat? {
        guard event.subtype == .tabletPoint else { return nil }
        return CGFloat(min(max(event.pressure, 0), 1))
    }

    private func beginStroke(at point: CGPoint, pressure: CGFloat? = nil) {
        // A Quick Mask stroke never touches the document: no begin
        // callback (which would open a live-edit session, or refuse for
        // reasons — hidden layer, adjustment routing — that only apply to
        // document strokes), no selection confinement (the mode consumed
        // the selection on entry), and the layer-vs-mask paint target is
        // ignored — the stroke can only hit the mode's buffer.
        strokeOnQuickMask = quickMaskActive
        guard let context = ensureOverlayContext(),
              strokeOnQuickMask || onStrokeBegin?() == true
        else {
            strokeOnQuickMask = false
            NSSound.beep()
            return
        }
        context.saveGState()
        if let selection = selection, !strokeOnQuickMask {
            // Strokes and erases confine to the active selection (exact
            // shape, not just the bounding box).
            selection.clip(context)
        }
        // For the eraser only alpha matters, so an opaque paint color works
        // for both tools. Painting a MASK ignores the color well entirely —
        // coverage, not color: white reveals, black hides — and carries the
        // opacity in the stroke's own alpha, since the mask-painting FFI
        // takes no separate alpha the way rz_doc_painting_layer does. A
        // Quick Mask stroke is coverage the same way: brush white (adds),
        // eraser black (removes), paint color ignored.
        strokeHealKind = (tool == .heal || tool == .spotHeal) ? tool : nil
        strokeOnMask = strokeOnQuickMask ? false : paintsMask
        let onCoverage = strokeOnMask || strokeOnQuickMask
        // A dodge/burn stroke is pure coverage too: the retouch op reads
        // only the overlay's alpha, so it paints white at full alpha (the
        // exposure lives in the op, not the stroke).
        let coverageWhite = onCoverage || tool == .dodge
        let base: NSColor = coverageWhite ? (tool == .eraser ? .black : .white) : paintColor
        let color = (base.usingColorSpace(documentNSColorSpace) ?? base)
            .withAlphaComponent(onCoverage ? brushOpacity : 1)
        context.setStrokeColor(color.cgColor)
        context.setFillColor(color.cgColor)
        context.setLineWidth(brushSize)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        var point = point
        if brushSize <= 1 {
            // Pixel work: snap to the pixel center and defeat antialiasing so
            // a size-1 brush paints (or erases) whole solid pixels instead of
            // a ~78%-alpha fuzzy blob. The flag lives in the gstate saved
            // above and restored when the stroke ends.
            context.setShouldAntialias(false)
            point = CGPoint(
                x: min(floor(point.x), CGFloat(overlayWidth - 1)) + 0.5,
                y: min(floor(point.y), CGFloat(overlayHeight - 1)) + 0.5)
        }
        // Any non-default tip swaps the pipeline: the stroke stamps dabs
        // (SoftBrush's falloff through the tip's spacing, angle and
        // roundness, each dab deposited at the tip's flow) instead of
        // stroking one hard path — as do pressure-tracking and airbrush
        // strokes, which need per-dab control. The tip and dab images are
        // latched for the stroke's lifetime. Coverage dabs stamp at FLOW
        // alpha with the stroke's opacity deferred to strokeCoverageScale
        // (see its comment); a hard coverage stroke is one path fill, so
        // it keeps carrying opacity in the color.
        strokeCoverageScale = 1
        strokeTip = BrushTip(
            hardness: brushHardness,
            // Healing solves over the overlay's COVERAGE (alpha >= 128): a
            // flowed-down dab would empty it, so strength lives in the op.
            flow: strokeHealKind == nil ? brushFlow : 1,
            spacingPercent: brushSpacingPercent, angleDegrees: brushAngle,
            roundness: brushRoundness)
        strokeUsesPressure = brushPressureSize && pressure != nil && brushSize > 1
        // The leash length is a screen-space feel (hand jitter is screen
        // px), converted to the canvas px the stroke pipeline speaks.
        strokeLeash = StrokeLeash(
            position: point, radius: brushSmoothing * 32 / max(magnification, 0.01))
        let stamped = SoftBrush.isStamped(tip: strokeTip, size: brushSize)
            || ((strokeUsesPressure || brushAirbrush) && brushSize > 1)
        if tool == .clone || tool == .heal {
            if SoftBrush.isSoft(hardness: brushHardness, size: brushSize) {
                cloneDabMask = SoftBrush.dabMask(
                    diameter: brushSize, hardness: brushHardness)
            }
        } else if stamped {
            if onCoverage { strokeCoverageScale = brushOpacity }
            strokeSoftDab = SoftBrush.dab(
                color: color.withAlphaComponent(strokeTip.flow),
                diameter: brushSize, hardness: brushHardness, space: documentColorSpace)
        }
        strokeActive = true
        strokeLastPoint = point
        recordedStrokePoints = [point]
        strokeCloneSource = nil
        strokeLastPressure = pressure ?? 1
        strokeCursor = point
        strokeCursorPressure = pressure ?? 1
        strokeSpline.begin(at: point, pressure: pressure ?? 1)
        if tool == .clone || tool == .heal {
            // Latched here so an agent edit landing mid-drag cannot change
            // what is being cloned; the offset is the classic aligned-clone
            // rule (first stamp − source), which Aligned then keeps.
            // A nil ANSWER means the canvas's own projection — the Clone
            // Stamp's, and the Healing Brush's with Sample All Layers on.
            // flatMap: `?? image` on the double optional takes the inner nil.
            cloneSnapshot = onStrokeSourceImage.flatMap { $0() } ?? image
            if let source = cloneSource, !(strokeAligned && cloneOffsetTool == tool) {
                cloneOffset = CGVector(dx: point.x - source.x, dy: point.y - source.y)
                cloneOffsetTool = tool
            }
            // The source the stroke really samples from, derived from the
            // latched offset: `points[0] - offset`, which is the inverse of
            // the tools' own `offset = points[0] - source`.
            strokeCloneSource = CGPoint(
                x: point.x - cloneOffset.dx, y: point.y - cloneOffset.dy)
            stampCloneDab(in: context, at: point, pressure: strokeLastPressure)
        } else if let dab = strokeSoftDab {
            stampSoftDab(dab, in: context, at: point, pressure: strokeLastPressure)
        } else {
            // Starting dot so a plain click leaves a mark.
            let dot = CGRect(
                x: point.x - brushSize / 2, y: point.y - brushSize / 2,
                width: brushSize, height: brushSize)
            context.fillEllipse(in: dot)
        }
        if brushAirbrush, tool == .clone || tool == .heal || strokeSoftDab != nil {
            // Airbrush: keep depositing at the (possibly resting) brush
            // position while the button is down. A main-run-loop Timer —
            // plain AppKit, no GCD (see the app hygiene rules).
            airbrushTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) {
                [weak self] _ in self?.airbrushTick()
            }
        }
        emitStrokeUpdate()
    }

    /// One airbrush deposit at the resting brush position.
    private func airbrushTick() {
        guard strokeActive, let context = overlayContext else { return }
        if tool == .clone || tool == .heal {
            stampCloneDab(in: context, at: strokeCursor, pressure: strokeCursorPressure)
        } else if let dab = strokeSoftDab {
            stampSoftDab(dab, in: context, at: strokeCursor, pressure: strokeCursorPressure)
        } else {
            return
        }
        emitStrokeUpdate()
    }

    private func continueStroke(to cursor: CGPoint, pressure: CGFloat?) {
        guard strokeActive, let last = strokeLastPoint, let context = overlayContext else { return }
        // The leash (Smoothing) damps hand jitter before anything else
        // sees the point — the pixel pencil included.
        let point = strokeLeash.radius > 0 ? strokeLeash.pull(toward: cursor) : cursor
        strokeCursor = point
        if let pressure = pressure { strokeCursorPressure = pressure }
        if brushSize <= 1 {
            // Same pixel-center snapping as beginStroke; no clamping, so
            // off-canvas points still exit cleanly instead of edge-pinning.
            // Pixel strokes stay exact chords between snapped centers — a
            // spline would wander off the pixel grid.
            let snapped = CGPoint(x: floor(point.x) + 0.5, y: floor(point.y) + 0.5)
            context.move(to: last)
            context.addLine(to: snapped)
            context.strokePath()
            strokeLastPoint = snapped
            recordedStrokePoints.append(snapped)
            emitStrokeUpdate()
            return
        }
        // Straight chords between drag samples read as a polygon on a fast
        // flick (drags arrive at most once per frame), so every other
        // stroke renders through the spline, one sample behind the cursor;
        // endStroke flushes the tail span.
        let vertices = strokeSpline.add(point, pressure: strokeCursorPressure)
        guard !vertices.isEmpty else { return }
        renderStroke(through: vertices, in: context)
        emitStrokeUpdate()
    }

    /// Extends the stroke through `vertices` — one flattened spline span.
    /// Stamped strokes (clone always, the others whenever a dab is
    /// latched) walk dabs at the tip's spacing; the walk's origin and
    /// pressure advance per STAMP, so the rhythm carries across spans
    /// instead of resetting at each one, and spacing tracks the local
    /// (pressure-scaled) diameter. Hard strokes extend the path itself,
    /// joined and capped round by the stroke's gstate.
    private func renderStroke(through vertices: [StrokeVertex], in context: CGContext) {
        guard var from = strokeLastPoint, !vertices.isEmpty else { return }
        recordedStrokePoints.append(contentsOf: vertices.map { $0.point })
        if tool == .clone || tool == .heal || strokeSoftDab != nil {
            var pressure = strokeLastPressure
            for vertex in vertices {
                var distance = hypot(vertex.point.x - from.x, vertex.point.y - from.y)
                var spacing = SoftBrush.spacing(
                    for: dabDiameter(pressure), percent: strokeTip.spacingPercent)
                while distance >= spacing {
                    let step = spacing / distance
                    from = CGPoint(
                        x: from.x + (vertex.point.x - from.x) * step,
                        y: from.y + (vertex.point.y - from.y) * step)
                    pressure += (vertex.pressure - pressure) * step
                    if let dab = strokeSoftDab {
                        stampSoftDab(dab, in: context, at: from, pressure: pressure)
                    } else {
                        stampCloneDab(in: context, at: from, pressure: pressure)
                    }
                    distance = hypot(vertex.point.x - from.x, vertex.point.y - from.y)
                    spacing = SoftBrush.spacing(
                        for: dabDiameter(pressure), percent: strokeTip.spacingPercent)
                }
            }
            strokeLastPoint = from
            strokeLastPressure = pressure
        } else {
            context.move(to: from)
            for vertex in vertices {
                context.addLine(to: vertex.point)
            }
            context.strokePath()
            strokeLastPoint = vertices.last?.point
            strokeLastPressure = vertices.last?.pressure ?? strokeLastPressure
        }
    }

    /// The dab's diameter at `pressure`: a pressure-tracking stroke scales
    /// the tip (floored at 1 px); everything else stamps at brush size.
    private func dabDiameter(_ pressure: CGFloat) -> CGFloat {
        strokeUsesPressure ? max(brushSize * min(max(pressure, 0), 1), 1) : brushSize
    }

    /// Stamps the clone snapshot through a round dab at `point`: the whole
    /// snapshot drawn displaced by the stroke's offset and clipped to the
    /// dab, so the pixel that lands at p is the snapshot's p − offset.
    private func stampCloneDab(in context: CGContext, at point: CGPoint, pressure: CGFloat = 1) {
        guard let snapshot = cloneSnapshot else { return }
        context.saveGState()
        // The tip's footprint clips — the gray falloff mask when soft
        // (white passes paint, black blocks), a hard ellipse otherwise —
        // rotated and squashed by the tip; the dab deposits at the tip's
        // flow so overlapping dabs build up within the stroke.
        SoftBrush.clipDab(
            in: context, at: point, diameter: dabDiameter(pressure),
            tip: strokeTip, mask: cloneDabMask)
        if strokeTip.flow < 0.995 { context.setAlpha(strokeTip.flow) }
        // The overlay context is flipped (row 0 = top); flip back locally
        // so the snapshot lands right side up at the displaced position.
        context.translateBy(x: 0, y: CGFloat(overlayHeight))
        context.scaleBy(x: 1, y: -1)
        context.draw(snapshot, in: CGRect(
            x: cloneOffset.dx, y: -cloneOffset.dy,
            width: CGFloat(snapshot.width), height: CGFloat(snapshot.height)))
        context.restoreGState()
    }

    /// Stamps one dab: the pre-rendered falloff image drawn through the
    /// tip's rotation and roundness, scaled by pressure when the stroke
    /// tracks it.
    private func stampSoftDab(
        _ dab: CGImage, in context: CGContext, at point: CGPoint, pressure: CGFloat = 1
    ) {
        SoftBrush.stamp(
            dab, in: context, at: point, diameter: dabDiameter(pressure), tip: strokeTip)
    }

    /// Hands the accumulated overlay to the receiver, which repaints it onto
    /// the pre-stroke document and swaps in the resulting projection (which
    /// is what redraws the canvas — the overlay itself is never drawn).
    private func emitStrokeUpdate() {
        // A Quick Mask stroke stays entirely in the view: refresh the
        // rubylith from the buffer-plus-overlay composite so the tint
        // tracks the stroke live; the buffer itself changes at mouse-up.
        if strokeOnQuickMask {
            rebuildQuickMaskImage(from: quickMaskComposited())
            needsDisplay = true
            return
        }
        // A mask stroke never round-trips through the document mid-drag: it
        // ghosts on top of the unchanged projection and commits once.
        guard !strokeOnMask, strokeHealKind != .spotHeal else {
            needsDisplay = true
            return
        }
        guard let data = overlayData else { return }
        let erasing = tool == .eraser
        onStrokeUpdate?(
            UnsafePointer(data.assumingMemoryBound(to: UInt8.self)),
            erasing ? RZ_COMPOSITE_ERASE : RZ_COMPOSITE_OVER,
            Double(brushOpacity))
    }

    private func endStroke(at cursor: CGPoint? = nil) {
        guard strokeActive else { return }
        airbrushTimer?.invalidate()
        airbrushTimer = nil
        if let cursor = cursor, strokeLeash.radius > 0 {
            // Stroke catch-up: the leash trails the cursor by up to its
            // radius, but the release point is where the hand actually
            // stopped — drop the leash and finish the stroke there.
            strokeLeash.radius = 0
            continueStroke(to: cursor, pressure: nil)
        }
        if let context = overlayContext {
            // The spline runs one sample behind the cursor; its tail span
            // lands now, while the stroke's gstate (color, width, the
            // selection clip) is still in force.
            let tail = strokeSpline.finish()
            if !tail.isEmpty {
                renderStroke(through: tail, in: context)
                if !strokeOnQuickMask, !strokeOnMask {
                    // Those two consume the overlay directly below, tail
                    // included; the layer live edit consumed it at the
                    // LAST DRAG EVENT, so without this the endLiveEdit
                    // commit would silently drop the tail.
                    emitStrokeUpdate()
                }
            }
        }
        overlayContext?.restoreGState()
        strokeActive = false
        strokeLastPoint = nil
        cloneSnapshot = nil
        strokeSoftDab = nil
        cloneDabMask = nil
        if strokeOnQuickMask {
            // The stroke lands in the Quick Mask buffer and nowhere else:
            // no document edit, no undo step, no stroke-end callback (there
            // is no live-edit session to close).
            quickMaskBuffer = quickMaskComposited()
            rebuildQuickMaskImage(from: quickMaskBuffer)
            strokeOnQuickMask = false
            clearOverlay()
            needsDisplay = true
            return
        }
        let actionName = strokeActionName()
        if strokeOnMask, let data = overlayData {
            if strokeCoverageScale < 1 {
                // The soft pipeline stamped full-alpha dabs; the stroke's
                // opacity lands here, once, on the premultiplied bytes.
                let bytes = data.assumingMemoryBound(to: UInt8.self)
                let scale = Int((strokeCoverageScale * 255).rounded())
                for i in 0..<(overlayWidth * overlayHeight * 4) {
                    bytes[i] = UInt8(Int(bytes[i]) * scale / 255)
                }
            }
            // The receiver's applyEdit consumes the bytes synchronously.
            onCommitMaskOverlay?(
                UnsafePointer(data.assumingMemoryBound(to: UInt8.self)), actionName)
        } else if strokeHealKind != nil, let data = overlayData {
            // The overlay holds the WHOLE footprint (tail included) and the
            // live-edit session is still open, so the solve runs once against
            // the pre-stroke handle: the drag's preview and this result are
            // ONE undo step. The mask branch's coverage premultiply must NOT
            // run here — a layer stroke's opacity is the op's own strength.
            onCommitStrokeOverlay?(
                UnsafePointer(data.assumingMemoryBound(to: UInt8.self)), actionName)
        }
        clearOverlay()
        strokeHealKind = nil
        strokeOnMask = false
        needsDisplay = true
        // Always fires once a stroke began: the live-edit session must
        // close even if the whole stroke missed the layer.
        onStrokeEnd?(actionName)
    }

    private func strokeActionName() -> String {
        if strokeOnMask {
            return tool == .eraser ? "Erase Mask" : "Paint Mask"
        }
        switch tool {
        case .eraser: return "Erase"
        case .clone: return "Clone Stamp"
        case .dodge: return "Dodge / Burn"
        case .heal: return "Healing Brush"
        case .spotHeal: return "Spot Healing"
        default: return "Brush Stroke"
        }
    }

    /// Abandons any in-progress stroke without committing (tool switches,
    /// Escape, window close); the receiver rolls the live edit back.
    private func cancelStroke() {
        airbrushTimer?.invalidate()
        airbrushTimer = nil
        strokeLastPoint = nil
        strokeSpline = StrokeSpline()
        cloneSnapshot = nil
        strokeSoftDab = nil
        cloneDabMask = nil
        guard strokeActive else { return }
        overlayContext?.restoreGState()
        strokeActive = false
        strokeHealKind = nil
        strokeOnMask = false
        clearOverlay()
        if strokeOnQuickMask {
            // The buffer never changed mid-stroke; dropping the overlay and
            // restoring the tint from the buffer is the whole rollback (no
            // live-edit session to unwind).
            strokeOnQuickMask = false
            rebuildQuickMaskImage(from: quickMaskBuffer)
            needsDisplay = true
            return
        }
        onStrokeCancel?()
        needsDisplay = true
    }

    // MARK: - Text sessions

    /// Opens the on-canvas editor at `point` (the text block's top-left in
    /// image pixels — a re-edit's anchor), pre-filled with `string` and
    /// `width` wide (nil = the legacy default, `TextLayer.legacyBoxWidth`).
    /// `editingLayer` marks the session as a re-edit of that text layer: the
    /// commit replaces its content instead of adding a layer. The session
    /// always draws with the canvas's current textStyle/paintColor, so the
    /// caller restores those from the layer's description first.
    /// `selectAll` opens with the whole string selected — the layers panel's
    /// double-click, which has no click position to put a caret at, so
    /// typing replaces the text.
    ///
    /// A NEW session is shifted left rather than letting the box overhang
    /// the right edge, where committed glyphs would be clipped. A RE-EDIT
    /// is clamped into the canvas on both axes and scrolled into view: the
    /// commit takes the layer's anchor from the document, never from the
    /// editor's origin (EditorViewController.commitTextLayer), so the shift
    /// can neither register a phantom edit nor displace the layer — and
    /// without it a transformed layer, whose anchor is the block's origin
    /// (a half turn puts that at the raster's far corner), or one nudged
    /// off-canvas would open an editor nobody can see.
    func beginTextSession(
        at point: CGPoint, width: CGFloat? = nil, string: String = "",
        editingLayer: Int? = nil, selectAll: Bool = false
    ) {
        let width = width.map { min(max($0, 1), CGFloat(TextLayer.maxBoxWidth)) }
            ?? TextLayer.legacyBoxWidth(canvasWidth: bounds.width, anchorX: point.x)
        let height = textStyle.nsFont.pointSize * 1.5
        let x = max(0, min(point.x, bounds.width - width))
        let y = editingLayer == nil ? point.y : max(0, min(point.y, bounds.height - height))
        let textView = CanvasTextView(
            frame: NSRect(x: x, y: y, width: width, height: height))
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = false
        textView.font = textStyle.nsFont
        textView.string = string
        textView.textColor = paintColor
        textView.insertionPointColor = paintColor
        textView.typingAttributes = textStyle.attributes(color: paintColor)
        textView.defaultParagraphStyle = TextStyle.paragraphStyle(
            alignment: textStyle.alignment, leading: textStyle.leading)
        textView.alignment = textStyle.alignment
        textView.minSize = NSSize(width: width, height: height)
        textView.maxSize = NSSize(width: width, height: 10_000_000)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: width, height: 10_000_000)
        // Zero padding so the live session lines up with the committed text.
        textView.textContainer?.lineFragmentPadding = 0
        textView.delegate = self
        textView.onCommandReturn = { [weak self] in self?.commitTextSession() }
        addSubview(textView)
        activeTextView = textView
        textSessionLayer = editingLayer
        // Pre-filled text arrives with the typing attributes, and the box is
        // still one line tall: restyle and refit it exactly as an edit would.
        if !string.isEmpty {
            updateActiveTextSessionStyle()
        }
        textView.scrollToVisible(textView.bounds)
        needsDisplay = true
        window?.makeFirstResponder(textView)
        // Last, so the restyling above (which rewrites the storage) cannot
        // collapse the selection again.
        if selectAll, !string.isEmpty {
            textView.setSelectedRange(NSRange(location: 0, length: (string as NSString).length))
        }
    }

    /// Applies the current textStyle/paintColor to the whole active session
    /// (called by the view controller when the options change).
    func updateActiveTextSessionStyle() {
        guard let textView = activeTextView else { return }
        let attributes = textStyle.attributes(color: paintColor)
        textView.font = textStyle.nsFont
        textView.textColor = paintColor
        textView.insertionPointColor = paintColor
        textView.defaultParagraphStyle = TextStyle.paragraphStyle(
            alignment: textStyle.alignment, leading: textStyle.leading)
        textView.alignment = textStyle.alignment
        textView.typingAttributes = attributes
        if let storage = textView.textStorage, storage.length > 0 {
            storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
        }
        resizeActiveTextSession()
    }

    private func resizeActiveTextSession() {
        guard let textView = activeTextView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer
        else { return }
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        let minHeight = (textView.font ?? textStyle.nsFont).pointSize * 1.5
        let height = max(used.height + textView.textContainerInset.height * 2 + 2, minHeight)
        if abs(textView.frame.height - height) > 0.5 {
            var frame = textView.frame
            frame.size.height = height
            textView.frame = frame
        }
        needsDisplay = true
    }

    /// Hands the session's text off as a DESCRIPTION — string, typography,
    /// color and the box it wrapped in, plus the origin it was laid out at —
    /// so the receiver can render it into a re-editable text layer. An
    /// all-whitespace session cancels instead.
    func commitTextSession() {
        guard let textView = activeTextView else { return }
        let string = textView.string
        guard !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            cancelTextSession()
            return
        }
        let sessionColor = textView.textColor ?? paintColor
        let origin = textView.frame.origin
        let width = textView.frame.width
        let editingLayer = textSessionLayer
        removeTextSessionView()

        // A NEW session pushed fully outside the image (e.g. the canvas
        // shrank underneath it) has nothing to contribute; skip the empty
        // undo step. A re-edit whose anchor sits off-canvas is still the
        // user's edit — an unchanged one is caught by the commit's no-op
        // guard.
        guard editingLayer != nil
            || (origin.x < bounds.width && origin.y < bounds.height && origin.x + width > 0)
        else { return }

        onCommitText?(
            TextLayerPayload(
                string: string, style: textStyle, color: sessionColor,
                box: .width(Double(width))),
            origin, editingLayer)
        needsDisplay = true
    }

    /// Removes the session's text view without committing anything.
    func cancelTextSession() {
        removeTextSessionView()
    }

    private func removeTextSessionView() {
        guard let textView = activeTextView else { return }
        activeTextView = nil
        textSessionLayer = nil
        textView.delegate = nil
        textView.removeFromSuperview()
        window?.makeFirstResponder(self)
        needsDisplay = true
        onTextSessionEnd?()
    }

    // MARK: - Keyboard and cursor

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        // A window closing mid-drag never delivers mouseUp; the live edit
        // must still roll back and close.
        if newWindow == nil {
            cancelStroke()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func keyDown(with event: NSEvent) {
        // The transform session swallows the keyboard: Return commits,
        // Escape cancels, arrows nudge. Everything else is dropped rather
        // than allowed to switch tools or resize the brush underneath it
        // (menu key equivalents never reach keyDown, so ⌘-anything still
        // goes through the usual validation).
        if isTransforming {
            switch event.keyCode {
            case 53: // Escape
                onTransformCancel?()
            case 36, 76: // Return, keypad Enter
                onTransformCommit?()
            case 123, 124, 125, 126: // arrows
                let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
                switch event.keyCode {
                case 123: onTransformNudge?(-step, 0)
                case 124: onTransformNudge?(step, 0)
                case 125: onTransformNudge?(0, step)
                default: onTransformNudge?(0, -step)
                }
            default:
                NSSound.beep()
            }
            return
        }
        // A grabbed guide owns Escape and Delete, and it owns them AHEAD of
        // the crop and shape-edit sessions below: a crop session exists from
        // the moment the tool is picked, so a guide dragged out of a ruler to
        // line the crop box up against — the workflow the crop tool's own
        // "Snap to guides" option exists for — would otherwise have its
        // Escape eaten, resetting the crop box to the whole canvas while the
        // guide drag carried on and still committed on mouse-up. A guide drag
        // is also the more transient gesture, so it is the one the keystroke
        // is aimed at.
        //
        // ⌫ reaches keyDown at all only because Edit ▸ Clear stands down
        // while `guideDrag != nil`: Clear carries a BARE ⌫ key equivalent,
        // and a modifier-less key equivalent is resolved ahead of the first
        // responder, so without that guard this branch would be dead whenever
        // a selection existed — and the keystroke would clear the selection's
        // PIXELS instead (EditorViewController.validateUserInterfaceItem).
        if guideDrag != nil {
            switch event.keyCode {
            case 53: // Escape
                onGuideCancel?()
                return
            case 51, 117: // Delete, forward delete
                onGuideDelete?()
                return
            default:
                break
            }
        }
        // A crop session's keys: Return commits, Escape resets the box.
        // Inert in Quick Mask mode, like the crop clicks — a commit is a
        // document edit, and only the mode's buffer may change there.
        if tool == .crop, cropOverlay != nil, !quickMaskActive {
            switch event.keyCode {
            case 53:
                onCropCancel?()
                return
            case 36, 76:
                onCropCommit?()
                return
            default:
                break
            }
        }
        // A shape-edit session's keys mirror the crop session's: Return
        // commits, Escape cancels — and the same Quick Mask gate, since the
        // commit is a document edit.
        if shapeEditOverlay != nil, !quickMaskActive {
            switch event.keyCode {
            case 53:
                onShapeEditCancel?()
                return
            case 36, 76:
                onShapeEditCommit?()
                return
            default:
                break
            }
        }
        if event.keyCode == 53 { // Escape
            if strokeActive {
                // Abandon the in-progress stroke; the live edit rolls back.
                cancelStroke()
                return
            }
            if !lassoPoints.isEmpty {
                cancelLasso()
                return
            }
            patchSession.cancel()
            redEyeSession.cancel()
            // Escape on the canvas IS Deselect, and records like the other
            // two spellings of it (the mouse-up click-to-deselect above,
            // Select ▸ Deselect in the editor): `setSelection` is a per-tick
            // setter and is deliberately not hooked, so each selection
            // COMMAND records for itself. Recording nothing here left a
            // replay running the rest of the action with the marquee from
            // an earlier step still live.
            if selection != nil { ActionRecorder.shared.record(.deselect) }
            setSelection(nil)
            return
        }
        // Return closes an in-progress lasso, or a Patch outline.
        if (event.keyCode == 36 || event.keyCode == 76), !lassoPoints.isEmpty {
            closeLasso()
            return
        }
        if event.keyCode == 36 || event.keyCode == 76, tool == .patch,
           patchSession.closeOutlineFromKey(sampling: { self.onPatchSourceImage?() })
        { needsDisplay = true; return }
        // Arrow-key nudges for the move tool (Shift: 10px). Down is +y in the
        // flipped image coordinate space. Inert in Quick Mask mode — a nudge
        // is a document edit, and only the mode's buffer may change there.
        if tool == .move, !hasActiveTextSession, !quickMaskActive,
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            // The Move tool's Nudge option, pushed in with the rest of the
            // chrome — never a ToolOptionsStore read from the canvas.
            let base = chrome.moveNudgeStep
            let step = event.modifierFlags.contains(.shift) ? base * 10 : base
            switch event.keyCode {
            case 123: onMoveNudge?(-step, 0); return // left
            case 124: onMoveNudge?(step, 0); return // right
            case 125: onMoveNudge?(0, step); return // down
            case 126: onMoveNudge?(0, -step); return // up
            default:
                break
            }
        }
        // Bare tool keys (Photoshop-style), handled here only (never as menu
        // key equivalents — they would steal keystrokes from text editing).
        // The text view is first responder during sessions anyway.
        if !hasActiveTextSession,
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           let characters = event.charactersIgnoringModifiers?.lowercased() {
            if let keyTool = EditorTool(keyCharacter: characters) {
                onToolKey?(keyTool)
                return
            }
            switch characters {
            case "q":
                // Quick Mask toggle rides with the tool keys for the same
                // reason they live here: a menu key equivalent would steal
                // the letter from every text field.
                onQuickMaskKey?()
                return
            case "[" where tool.usesBrushTip:
                onBrushSizeKey?(min(max(brushSize * 0.8, 1), 200))
                return
            case "]" where tool.usesBrushTip:
                onBrushSizeKey?(min(max(brushSize * 1.25, 1), 200))
                return
            default:
                break
            }
        }
        super.keyDown(with: event)
    }

    override func resetCursorRects() {
        // The transform box is dragged with the arrow, whatever tool the
        // session was entered from.
        guard !isTransforming else {
            addCursorRect(bounds, cursor: .arrow)
            return
        }
        // A guide under the pointer takes the cursor. This branch is the
        // ONLY way a hover cursor survives: four existing
        // invalidateCursorRects sites re-apply the whole-bounds rect below,
        // and every NSCursor.set() in this file is inside a
        // mouseDown/mouseDragged, where AppKit is not re-applying rects.
        if let cursor = guideHoverCursor {
            addCursorRect(bounds, cursor: cursor)
            return
        }
        // The enum knows each tool's resting cursor; the move and hand
        // tools' hands close while a drag is in flight.
        let dragging = (tool == .move && moveDragOrigin != nil)
            || (tool == .hand && handPanAnchorWindow != nil)
        addCursorRect(bounds, cursor: dragging ? .closedHand : tool.cursor)
    }
}

// MARK: - NSTextViewDelegate (text sessions)

extension ImageCanvasView: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        resizeActiveTextSession()
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelTextSession()
            return true
        }
        return false
    }
}
